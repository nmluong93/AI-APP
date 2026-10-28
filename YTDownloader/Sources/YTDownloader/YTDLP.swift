import Foundation

enum YTDLPError: LocalizedError {
    case toolMissing
    case invalidURL
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing: return "yt-dlp was not found. Install it with: brew install yt-dlp"
        case .invalidURL: return "Please paste a link that starts with http:// or https://"
        case .failed(let message): return message
        }
    }
}

enum YTDLP {
    static func isValidLink(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    static func version(tools: Tools) -> String? {
        guard let ytdlp = tools.ytdlp else { return nil }
        let p = Process()
        p.executableURL = ytdlp
        p.arguments = ["--version"]
        p.environment = Tools.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the title and the list of videos for a video or playlist link without downloading.
    static func fetchInfo(link: String, tools: Tools) async throws -> FetchedMedia {
        guard let ytdlp = tools.ytdlp else { throw YTDLPError.toolMissing }
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidLink(link) else { throw YTDLPError.invalidURL }

        let (status, out, err) = try await runToCompletion(
            ytdlp,
            arguments: ["-J", "--flat-playlist", "--no-warnings", "--color", "never", "--", link]
        )
        guard status == 0 else {
            let message = err.split(separator: "\n").last(where: { $0.hasPrefix("ERROR") })
                .map(String.init) ?? "yt-dlp could not read this link (exit code \(status))."
            throw YTDLPError.failed(message)
        }
        guard let json = try JSONSerialization.jsonObject(with: out) as? [String: Any] else {
            throw YTDLPError.failed("Unexpected response from yt-dlp.")
        }
        return parse(json: json, originalLink: link)
    }

    static func parse(json: [String: Any], originalLink: String) -> FetchedMedia {
        let title = json["title"] as? String ?? "Untitled"
        if (json["_type"] as? String) == "playlist" {
            let rawEntries = json["entries"] as? [[String: Any]] ?? []
            var entries: [VideoEntry] = []
            for (offset, e) in rawEntries.enumerated() {
                guard let id = e["id"] as? String else { continue }
                let entryTitle = e["title"] as? String ?? id
                let unavailable = entryTitle == "[Private video]" || entryTitle == "[Deleted video]"
                let url = (e["url"] as? String) ?? "https://www.youtube.com/watch?v=\(id)"
                entries.append(VideoEntry(
                    id: "\(offset)-\(id)",
                    title: entryTitle,
                    duration: e["duration"] as? Double,
                    url: url,
                    playlistIndex: (e["playlist_index"] as? Int) ?? offset + 1,
                    isAvailable: !unavailable,
                    isSelected: !unavailable
                ))
            }
            return FetchedMedia(title: title, isPlaylist: true, entries: entries)
        }

        let id = json["id"] as? String ?? UUID().uuidString
        let url = json["webpage_url"] as? String ?? originalLink
        let entry = VideoEntry(id: id, title: title, duration: json["duration"] as? Double,
                               url: url, playlistIndex: nil, isAvailable: true, isSelected: true)
        return FetchedMedia(title: title, isPlaylist: false, entries: [entry])
    }

    static func downloadArguments(entry: VideoEntry, options: DownloadOptions, tools: Tools) -> [String] {
        var args = [
            "--newline", "--no-playlist", "--color", "never", "--no-mtime",
            "--progress",
            "--progress-template", "download:PROG|%(progress.status)s|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--progress-template", "postprocess:PP|%(progress.status)s|%(progress.postprocessor)s",
            // --print implies --quiet, which keeps the output to the lines parsed above.
            "--print", "after_move:FILE|%(filepath)s",
            "-P", options.outputFolder.path,
        ]

        var name = "%(title)s.%(ext)s"
        if options.numberFiles, let index = entry.playlistIndex {
            name = String(format: "%03d", index) + " - " + name
        }
        args += ["-o", name]

        if let ffmpeg = tools.ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.path]
        }

        switch options.kind {
        case .video:
            var sort: [String] = []
            if let height = options.videoQuality.maxHeight { sort.append("res:\(height)") }
            if options.preferH264 { sort.append("vcodec:h264") }
            sort.append("ext:mp4:m4a")
            args += ["-f", "bv*+ba/b", "-S", sort.joined(separator: ","),
                     "--merge-output-format", "mp4", "--embed-metadata"]
        case .audio:
            args += ["-f", "ba/b", "-x", "--audio-format", "mp3",
                     "--audio-quality", "\(options.audioKbps)K",
                     "--embed-metadata", "--embed-thumbnail"]
        }

        args += ["--", entry.url]
        return args
    }

    private static func runToCompletion(_ executable: URL, arguments: [String]) async throws -> (Int32, Data, String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = executable
                p.arguments = arguments
                p.environment = Tools.environment
                let outPipe = Pipe(), errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe

                // Drain stderr concurrently so a chatty process can't block on a full pipe.
                let lock = NSLock()
                var errData = Data()
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil; return }
                    lock.lock(); errData.append(chunk); lock.unlock()
                }

                do {
                    try p.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                errPipe.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let err = String(data: errData, encoding: .utf8) ?? ""
                lock.unlock()
                continuation.resume(returning: (p.terminationStatus, out, err))
            }
        }
    }
}

/// Runs a process and reports its combined output line by line on the main queue.
final class ProcessRunner {
    private let process = Process()
    private let queue = DispatchQueue(label: "ProcessRunner.output")
    private var buffer = Data()

    var isRunning: Bool { process.isRunning }

    func start(executable: URL, arguments: [String],
               onLine: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws {
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Tools.environment
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(data, onLine: onLine) }
        }
        process.terminationHandler = { [weak self] p in
            handle.readabilityHandler = nil
            let rest = handle.readDataToEndOfFile()
            let status = p.terminationStatus
            guard let self else { return }
            self.queue.async {
                self.consume(rest, onLine: onLine)
                if !self.buffer.isEmpty {
                    self.emit(self.buffer, onLine: onLine)
                    self.buffer.removeAll()
                }
                DispatchQueue.main.async { onExit(status) }
            }
        }
        try process.run()
    }

    /// Sends SIGINT, which lets yt-dlp stop ffmpeg and clean up.
    func interrupt() {
        if process.isRunning { process.interrupt() }
    }

    private func consume(_ data: Data, onLine: @escaping (String) -> Void) {
        buffer.append(data)
        while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            emit(Data(lineData), onLine: onLine)
        }
    }

    private func emit(_ data: Data, onLine: @escaping (String) -> Void) {
        guard let line = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty else { return }
        DispatchQueue.main.async { onLine(line) }
    }
}
