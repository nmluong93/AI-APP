import Foundation
import AppKit

/// One video in the download queue. All mutation happens on the main queue.
final class DownloadJob: ObservableObject, Identifiable {
    let id = UUID()
    let entry: VideoEntry
    let options: DownloadOptions

    @Published var state: JobState = .queued
    @Published var progress: Double = 0
    @Published var detail: String = ""
    @Published var outputFile: URL?

    private var runner: ProcessRunner?
    private var lastError: String?
    private var cancelRequested = false
    private var downloadPass = 0

    init(entry: VideoEntry, options: DownloadOptions) {
        self.entry = entry
        self.options = options
    }

    func start(tools: Tools, completion: @escaping () -> Void) {
        guard let ytdlp = tools.ytdlp else {
            state = .failed("yt-dlp is not installed")
            completion()
            return
        }
        cancelRequested = false
        lastError = nil
        downloadPass = 0
        progress = 0
        detail = "Starting…"
        state = .downloading

        let runner = ProcessRunner()
        self.runner = runner
        let args = YTDLP.downloadArguments(entry: entry, options: options, tools: tools)
        do {
            try runner.start(executable: ytdlp, arguments: args,
                             onLine: { [weak self] line in self?.handle(line: line) },
                             onExit: { [weak self] status in
                                 self?.finish(status: status)
                                 completion()
                             })
        } catch {
            state = .failed(error.localizedDescription)
            completion()
        }
    }

    func cancel() {
        cancelRequested = true
        if state == .queued {
            state = .cancelled
        } else {
            runner?.interrupt()
        }
    }

    func resetForRetry() {
        guard state.isFinished else { return }
        state = .queued
        progress = 0
        detail = ""
        outputFile = nil
    }

    private func handle(line: String) {
        if line.hasPrefix("PROG|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5 else { return }
            let status = parts[1], percent = parts[2], speed = parts[3], eta = parts[4]
            if status == "finished" {
                progress = 1
                detail = "Finishing…"
                return
            }
            if let value = Double(percent.replacingOccurrences(of: "%", with: "")) {
                // A video download is two passes (video, then audio). Restarting from 0 is expected.
                if value / 100 < progress - 0.5 { downloadPass += 1 }
                progress = min(max(value / 100, 0), 1)
            }
            state = .downloading
            var bits = [percent]
            if !speed.isEmpty, speed != "NA", !speed.hasPrefix("Unknown") { bits.append(speed) }
            if !eta.isEmpty, eta != "NA", !eta.hasPrefix("Unknown") { bits.append("ETA \(eta)") }
            if options.kind == .video { bits.insert(downloadPass == 0 ? "Video" : "Audio", at: 0) }
            detail = bits.joined(separator: " · ")
        } else if line.hasPrefix("PP|") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let name = parts.count > 2 ? parts[2] : ""
            state = .processing(Self.describe(postprocessor: name))
            detail = ""
        } else if line.hasPrefix("FILE|") {
            outputFile = URL(fileURLWithPath: String(line.dropFirst(5)))
        } else if line.hasPrefix("ERROR:") {
            lastError = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        }
    }

    private func finish(status: Int32) {
        runner = nil
        if cancelRequested {
            state = .cancelled
            detail = ""
        } else if status == 0 {
            state = .done
            progress = 1
            detail = outputFile?.lastPathComponent ?? ""
        } else {
            state = .failed(lastError ?? "yt-dlp exited with code \(status)")
            detail = ""
        }
    }

    private static func describe(postprocessor: String) -> String {
        switch postprocessor {
        case "Merger": return "Merging video and audio…"
        case "ExtractAudio": return "Converting to MP3…"
        case "EmbedThumbnail": return "Adding cover art…"
        case "FFmpegMetadata", "Metadata": return "Writing tags…"
        case "MoveFiles": return "Saving…"
        default: return "Processing…"
        }
    }
}

/// Holds the download queue and runs one job at a time.
final class DownloadManager: ObservableObject {
    @Published private(set) var jobs: [DownloadJob] = []
    @Published private(set) var tools = Tools.locate()
    @Published private(set) var ytdlpVersion: String?

    private var activeJob: DownloadJob?
    private var terminateObserver: NSObjectProtocol?

    init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cancelAll()
        }
        refreshTools()
    }

    func refreshTools() {
        tools = Tools.locate()
        let snapshot = tools
        DispatchQueue.global(qos: .utility).async {
            let version = YTDLP.version(tools: snapshot)
            DispatchQueue.main.async { self.ytdlpVersion = version }
        }
        startNextIfIdle()
    }

    func enqueue(_ entries: [VideoEntry], options: DownloadOptions) {
        jobs.append(contentsOf: entries.map { DownloadJob(entry: $0, options: options) })
        startNextIfIdle()
    }

    func cancel(_ job: DownloadJob) {
        job.cancel()
        objectWillChange.send()
    }

    func cancelAll() {
        jobs.filter { !$0.state.isFinished }.forEach { $0.cancel() }
        objectWillChange.send()
    }

    func retry(_ job: DownloadJob) {
        job.resetForRetry()
        startNextIfIdle()
    }

    func remove(_ job: DownloadJob) {
        guard job.state.isFinished else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    var hasUnfinishedJobs: Bool { jobs.contains { !$0.state.isFinished } }

    private func startNextIfIdle() {
        guard activeJob == nil,
              tools.ytdlp != nil,
              let next = jobs.first(where: { $0.state == .queued }) else { return }
        activeJob = next
        next.start(tools: tools) { [weak self] in
            guard let self else { return }
            self.activeJob = nil
            self.objectWillChange.send()
            self.startNextIfIdle()
        }
    }
}
