import Foundation

enum MediaKind: String, CaseIterable, Identifiable {
    case video
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Video (MP4)"
        case .audio: return "Audio (MP3)"
        }
    }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case best, p2160, p1440, p1080, p720, p480, p360

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Best available"
        case .p2160: return "2160p (4K)"
        case .p1440: return "1440p"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        case .p360: return "360p"
        }
    }

    var maxHeight: Int? {
        switch self {
        case .best: return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        }
    }
}

let audioBitrates = [320, 256, 192, 128]

struct VideoEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let duration: Double?
    let url: String
    /// 1-based position in the playlist, nil for a single video.
    let playlistIndex: Int?
    let isAvailable: Bool
    var isSelected: Bool
}

/// Whether the window downloads from a pasted link or from YouTube search results.
enum InputMode: String, CaseIterable, Identifiable {
    case link
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .link: return "Paste link"
        case .search: return "Search YouTube"
        }
    }
}

struct SearchResult: Identifiable, Hashable {
    let id: String
    let title: String
    let channel: String?
    let duration: Double?
    let url: String
    let thumbnailURL: URL?

    var entry: VideoEntry {
        VideoEntry(id: id, title: title, duration: duration, url: url,
                   playlistIndex: nil, isAvailable: true, isSelected: true)
    }
}

struct FetchedMedia {
    let title: String
    let isPlaylist: Bool
    var entries: [VideoEntry]
}

struct DownloadOptions {
    var kind: MediaKind
    var videoQuality: VideoQuality
    var preferH264: Bool
    var audioKbps: Int
    var outputFolder: URL
    var numberFiles: Bool
}

enum JobState: Equatable {
    case queued
    case downloading
    case processing(String)
    case done
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    var isActive: Bool {
        switch self {
        case .downloading, .processing: return true
        default: return false
        }
    }
}

func formatDuration(_ seconds: Double?) -> String {
    guard let seconds, seconds > 0 else { return "" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// Makes a string safe to use as a single folder name.
func sanitizedFolderName(_ name: String) -> String {
    let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
    let cleaned = name.components(separatedBy: bad).joined(separator: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return cleaned.isEmpty ? "Playlist" : String(cleaned.prefix(120))
}
