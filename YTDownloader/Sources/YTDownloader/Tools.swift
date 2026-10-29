import Foundation

/// Locates the command line tools the app drives: yt-dlp (downloads), ffmpeg (merging and
/// MP3 conversion) and deno (JavaScript runtime yt-dlp needs for YouTube).
struct Tools {
    let ytdlp: URL?
    let ffmpeg: URL?
    let deno: URL?

    static let searchDirectories: [String] = [
        Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.deno/bin",
        NSHomeDirectory() + "/.local/bin",
        "/usr/bin",
    ].compactMap { $0 }

    static func locate() -> Tools {
        Tools(ytdlp: find("yt-dlp"), ffmpeg: find("ffmpeg"), deno: find("deno"))
    }

    static func find(_ name: String) -> URL? {
        for dir in searchDirectories {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Apps launched from Finder get a minimal PATH, so add the usual install locations.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (searchDirectories + [existing]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }

    var missing: [String] {
        var names: [String] = []
        if ytdlp == nil { names.append("yt-dlp") }
        if ffmpeg == nil { names.append("ffmpeg") }
        if deno == nil { names.append("deno") }
        return names
    }
}
