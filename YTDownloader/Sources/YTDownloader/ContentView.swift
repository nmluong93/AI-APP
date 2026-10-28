import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager

    @State private var link = ""
    @State private var media: FetchedMedia?
    @State private var isFetching = false
    @State private var fetchError: String?

    @AppStorage("mediaKind") private var kindRaw = MediaKind.video.rawValue
    @AppStorage("videoQuality") private var qualityRaw = VideoQuality.p1080.rawValue
    @AppStorage("preferH264") private var preferH264 = true
    @AppStorage("audioKbps") private var audioKbps = 320
    @AppStorage("playlistSubfolder") private var playlistSubfolder = true
    @AppStorage("numberPlaylistFiles") private var numberPlaylistFiles = true
    @AppStorage("outputFolder") private var outputFolderPath =
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        ?? NSHomeDirectory()

    private var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .video }
    private var selectedEntries: [VideoEntry] { media?.entries.filter { $0.isSelected && $0.isAvailable } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            linkBar
                .padding(16)
            Divider()
            VSplitView {
                HStack(alignment: .top, spacing: 0) {
                    itemsPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    optionsPane
                        .frame(width: 280)
                }
                .frame(minHeight: 260)

                DownloadsPane()
                    .frame(minHeight: 160)
            }
            Divider()
            toolStatusBar
        }
    }

    // MARK: Link bar

    private var linkBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField("Paste a YouTube video or playlist link", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(fetch)
            Button("Paste") {
                if let text = NSPasteboard.general.string(forType: .string) {
                    link = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    fetch()
                }
            }
            Button(action: fetch) {
                if isFetching {
                    ProgressView().controlSize(.small).frame(width: 40)
                } else {
                    Text("Fetch").frame(width: 40)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isFetching || link.trimmingCharacters(in: .whitespaces).isEmpty || manager.tools.ytdlp == nil)
        }
    }

    // MARK: Items

    @ViewBuilder
    private var itemsPane: some View {
        if let error = fetchError {
            placeholder(systemImage: "exclamationmark.triangle", title: "Couldn't read that link", message: error)
        } else if isFetching {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading link… large playlists can take a moment.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if media != nil {
            VStack(alignment: .leading, spacing: 0) {
                itemsHeader
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                List {
                    ForEach(Binding(get: { media?.entries ?? [] },
                                    set: { media?.entries = $0 })) { $entry in
                        EntryRow(entry: $entry, showIndex: media?.isPlaylist == true)
                    }
                }
                .listStyle(.inset)
            }
        } else {
            placeholder(systemImage: "arrow.down.circle", title: "Paste a link to get started",
                        message: "Works with single videos and playlists. You can pick which playlist videos to download.")
        }
    }

    private var itemsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(media?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                if let media, media.isPlaylist {
                    Text("Playlist · \(media.entries.count) videos · \(selectedEntries.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if media?.isPlaylist == true {
                Button("Select All") { setAllSelected(true) }
                Button("Select None") { setAllSelected(false) }
            }
        }
    }

    private func setAllSelected(_ value: Bool) {
        guard var current = media else { return }
        for i in current.entries.indices where current.entries[i].isAvailable {
            current.entries[i].isSelected = value
        }
        media = current
    }

    private func placeholder(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Options

    private var optionsPane: some View {
        Form {
            Section("Format") {
                Picker("Download as", selection: $kindRaw) {
                    ForEach(MediaKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)

                if kind == .video {
                    Picker("Max quality", selection: $qualityRaw) {
                        ForEach(VideoQuality.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Toggle("Prefer H.264 (plays everywhere)", isOn: $preferH264)
                        .help("H.264 plays in QuickTime and on every Apple device. Turn off to allow VP9/AV1, which can reach higher resolutions.")
                } else {
                    Picker("MP3 bitrate", selection: $audioKbps) {
                        ForEach(audioBitrates, id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
            }

            Section("Save to") {
                HStack {
                    Image(systemName: "folder")
                    Text((outputFolderPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(outputFolderPath)
                }
                HStack {
                    Button("Choose…", action: chooseFolder)
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: outputFolderPath)) }
                }
                if media?.isPlaylist == true {
                    Toggle("Put playlist in its own folder", isOn: $playlistSubfolder)
                    Toggle("Number files by playlist order", isOn: $numberPlaylistFiles)
                }
            }

            Section {
                Button(action: startDownload) {
                    Label(downloadButtonTitle, systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntries.isEmpty || manager.tools.ytdlp == nil || manager.tools.ffmpeg == nil)
            }
        }
        .formStyle(.grouped)
    }

    private var downloadButtonTitle: String {
        let count = selectedEntries.count
        return count > 1 ? "Download \(count) items" : "Download"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolderPath)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }

    // MARK: Actions

    private func fetch() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isFetching else { return }
        fetchError = nil
        media = nil
        isFetching = true
        let tools = manager.tools
        Task {
            do {
                let result = try await YTDLP.fetchInfo(link: text, tools: tools)
                await MainActor.run {
                    media = result
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    fetchError = error.localizedDescription
                    isFetching = false
                }
            }
        }
    }

    private func startDownload() {
        guard let media else { return }
        var folder = URL(fileURLWithPath: outputFolderPath)
        if media.isPlaylist && playlistSubfolder {
            folder.appendPathComponent(sanitizedFolderName(media.title), isDirectory: true)
        }
        let options = DownloadOptions(
            kind: kind,
            videoQuality: VideoQuality(rawValue: qualityRaw) ?? .p1080,
            preferH264: preferH264,
            audioKbps: audioKbps,
            outputFolder: folder,
            numberFiles: media.isPlaylist && numberPlaylistFiles
        )
        manager.enqueue(selectedEntries, options: options)
    }

    // MARK: Tool status

    private var toolStatusBar: some View {
        HStack(spacing: 8) {
            let missing = manager.tools.missing
            if missing.isEmpty {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("yt-dlp \(manager.ytdlpVersion ?? "") · ffmpeg · deno ready")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Missing \(missing.joined(separator: ", ")). In Terminal run:")
                Text("brew install \(missing.joined(separator: " "))")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install \(missing.joined(separator: " "))", forType: .string)
                }
            }
            Spacer()
            Button("Recheck tools") { manager.refreshTools() }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct EntryRow: View {
    @Binding var entry: VideoEntry
    let showIndex: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $entry.isSelected)
                .labelsHidden()
                .disabled(!entry.isAvailable)
            if showIndex, let index = entry.playlistIndex {
                Text("\(index)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
            Text(entry.title)
                .lineLimit(1)
                .foregroundStyle(entry.isAvailable ? .primary : .secondary)
            Spacer()
            Text(formatDuration(entry.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { if entry.isAvailable { entry.isSelected.toggle() } }
    }
}

private struct DownloadsPane: View {
    @EnvironmentObject private var manager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                Button("Cancel All") { manager.cancelAll() }
                    .disabled(!manager.hasUnfinishedJobs)
                Button("Clear Finished") { manager.clearFinished() }
                    .disabled(manager.jobs.allSatisfy { !$0.state.isFinished })
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if manager.jobs.isEmpty {
                Text("Nothing downloading yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(manager.jobs) { job in
                    JobRow(job: job)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct JobRow: View {
    @EnvironmentObject private var manager: DownloadManager
    @ObservedObject var job: DownloadJob

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.options.kind == .audio ? "music.note" : "film")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.entry.title).lineLimit(1)
                switch job.state {
                case .downloading:
                    ProgressView(value: job.progress)
                    Text(job.detail).font(.caption).foregroundStyle(.secondary)
                case .processing(let message):
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                case .queued:
                    Text("Waiting…").font(.caption).foregroundStyle(.secondary)
                case .done:
                    Text("Done · \(job.detail)").font(.caption).foregroundStyle(.green).lineLimit(1)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            actions
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .queued, .downloading, .processing:
            Button { manager.cancel(job) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .help("Cancel")
        case .done:
            if let file = job.outputFile {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            Button { manager.remove(job) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove from list")
        case .failed, .cancelled:
            Button { manager.retry(job) } label: { Image(systemName: "arrow.clockwise.circle") }
                .buttonStyle(.borderless)
                .help("Retry")
            Button { manager.remove(job) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove from list")
        }
    }
}
