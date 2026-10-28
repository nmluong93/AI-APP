import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager

    @State private var link = ""
    @State private var media: FetchedMedia?
    @State private var isFetching = false
    @State private var fetchError: String?

    @AppStorage("inputMode") private var modeRaw = InputMode.link.rawValue
    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var searchResults: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var requestedCount = 0
    @State private var queuedResultIDs: Set<String> = []

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
    private var mode: InputMode { InputMode(rawValue: modeRaw) ?? .link }
    private var selectedEntries: [VideoEntry] { media?.entries.filter { $0.isSelected && $0.isAvailable } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Picker("", selection: $modeRaw) {
                    ForEach(InputMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                if mode == .link {
                    linkBar
                } else {
                    searchBar
                }
            }
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

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search YouTube", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search() }
            Button { search() } label: {
                if isSearching {
                    ProgressView().controlSize(.small).frame(width: 50)
                } else {
                    Text("Search").frame(width: 50)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty || manager.tools.ytdlp == nil)
        }
    }

    @ViewBuilder
    private var searchPane: some View {
        if let error = searchError {
            placeholder(systemImage: "exclamationmark.triangle", title: "Search failed", message: error)
        } else if isSearching && searchResults.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Searching YouTube…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            placeholder(systemImage: "magnifyingglass",
                        title: searchedQuery.isEmpty ? "Search YouTube" : "No videos found",
                        message: searchedQuery.isEmpty
                            ? "Type what you're looking for, then click the download button on a video. It uses the options on the right."
                            : "Try different words.")
        } else {
            List {
                ForEach(searchResults) { result in
                    SearchResultRow(
                        result: result,
                        isQueued: queuedResultIDs.contains(result.id),
                        canDownload: canDownload,
                        onDownload: { download(result) }
                    )
                }
                if canLoadMore || isSearching {
                    HStack {
                        Spacer()
                        Button(isSearching ? "Loading…" : "Show more results") { search(more: true) }
                            .disabled(isSearching)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
        }
    }

    private var canDownload: Bool { manager.tools.ytdlp != nil && manager.tools.ffmpeg != nil }

    private var canLoadMore: Bool {
        !searchResults.isEmpty && searchResults.count >= requestedCount && requestedCount < 100
    }

    // MARK: Items

    @ViewBuilder
    private var itemsPane: some View {
        if mode == .search {
            searchPane
        } else if let error = fetchError {
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
                if mode == .link && media?.isPlaylist == true {
                    Toggle("Put playlist in its own folder", isOn: $playlistSubfolder)
                    Toggle("Number files by playlist order", isOn: $numberPlaylistFiles)
                }
            }

            if mode == .link {
                Section {
                    Button(action: startDownload) {
                        Label(downloadButtonTitle, systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedEntries.isEmpty || !canDownload)
                }
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
        let options = downloadOptions(playlistTitle: media.isPlaylist ? media.title : nil)
        manager.enqueue(selectedEntries, options: options)
    }

    /// Runs a new search, or with `more` fetches a longer list for the same query.
    private func search(more: Bool = false) {
        let text = more ? searchedQuery : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSearching else { return }
        let count = more ? searchResults.count + YTDLP.searchPageSize : YTDLP.searchPageSize
        searchError = nil
        if !more {
            searchResults = []
            searchedQuery = ""
        }
        isSearching = true
        let tools = manager.tools
        Task {
            do {
                let results = try await YTDLP.search(query: text, count: count, tools: tools)
                await MainActor.run {
                    searchResults = results
                    searchedQuery = text
                    requestedCount = count
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    private func download(_ result: SearchResult) {
        manager.enqueue([result.entry], options: downloadOptions(playlistTitle: nil))
        queuedResultIDs.insert(result.id)
    }

    /// The current options. `playlistTitle` is set when downloading from a playlist.
    private func downloadOptions(playlistTitle: String?) -> DownloadOptions {
        var folder = URL(fileURLWithPath: outputFolderPath)
        if let playlistTitle, playlistSubfolder {
            folder.appendPathComponent(sanitizedFolderName(playlistTitle), isDirectory: true)
        }
        return DownloadOptions(
            kind: kind,
            videoQuality: VideoQuality(rawValue: qualityRaw) ?? .p1080,
            preferH264: preferH264,
            audioKbps: audioKbps,
            outputFolder: folder,
            numberFiles: playlistTitle != nil && numberPlaylistFiles
        )
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

private struct SearchResultRow: View {
    let result: SearchResult
    let isQueued: Bool
    let canDownload: Bool
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: result.thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.secondary.opacity(0.15)
                }
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                let duration = formatDuration(result.duration)
                if !duration.isEmpty {
                    Text(duration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .fontWeight(.medium)
                    .lineLimit(2)
                if let channel = result.channel {
                    Text(channel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onDownload) {
                Image(systemName: isQueued ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!canDownload)
            .help(isQueued ? "Added to downloads. Click to download again." : "Download")
        }
        .padding(.vertical, 4)
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
