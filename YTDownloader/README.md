# YT Downloader (macOS)

A small native macOS app (SwiftUI) for downloading a YouTube video, or any videos from a playlist, as **MP4 video** or **MP3 audio**.

Paste a link, press **Fetch**, tick the videos you want (for playlists), pick Video or Audio and a quality, choose a folder, and press **Download**. Downloads run one at a time with live progress, and each can be cancelled, retried, or shown in Finder.

> **Please use responsibly.** Downloading from YouTube can break YouTube's Terms of Service. Only download content you own, content that is licensed for download (e.g. Creative Commons), or content you otherwise have permission to save.

## How it works

The app is a friendly front end for two well-known command line tools:

- **yt-dlp** reads links and does the downloading.
- **ffmpeg** merges video and audio into one MP4 and converts audio to MP3.
- **deno** is a JavaScript runtime that recent versions of yt-dlp need to handle YouTube.

Keeping these as separate tools means you can update yt-dlp on its own (`brew upgrade yt-dlp`) whenever YouTube changes something, without rebuilding the app.

## 1. Install the requirements (one time)

You need macOS 13 Ventura or newer.

1. Install Apple's developer tools (gives you the Swift compiler):
   ```bash
   xcode-select --install
   ```
   Full Xcode from the App Store also works.
2. Install [Homebrew](https://brew.sh) if you don't have it, then:
   ```bash
   brew install yt-dlp ffmpeg deno
   ```

## 2. Build the app

In Terminal, from this folder:

```bash
chmod +x build-app.sh
./build-app.sh
open "build/YT Downloader.app"
```

That creates `build/YT Downloader.app`. Drag it into `/Applications` if you want to keep it. Use `./build-app.sh --universal` for one app that runs on both Apple Silicon and Intel Macs. It compiles each chip type separately and joins them with `lipo`, so it works with just the Command Line Tools (no full Xcode needed). You only need this if you plan to copy the app to a Mac with a different chip; plain `./build-app.sh` is enough for your own Mac.

The script compiles the Swift files directly with `swiftc`, so it doesn't depend on Swift Package Manager. Add `--spm` to build through SwiftPM instead.

**Using Xcode instead:** `open Package.swift`, pick the *YTDownloader* scheme and *My Mac*, then press ⌘R.

## Options

| Option | What it does |
| --- | --- |
| Video (MP4) / Audio (MP3) | What to save. |
| Max quality | Highest video resolution to grab (falls back to the best below it). |
| Prefer H.264 | On by default so files play in QuickTime and on iPhone/iPad. Turn off to allow VP9/AV1, which YouTube uses for most 1440p/4K streams. |
| MP3 bitrate | 128 to 320 kbps. Cover art and title/artist tags are embedded. |
| Put playlist in its own folder | Saves a playlist into a subfolder named after it. |
| Number files by playlist order | Prefixes files with `001 - `, `002 - `… |

## Troubleshooting

- **"Missing yt-dlp / ffmpeg / deno" at the bottom of the window:** run the `brew install …` command shown there, then press **Recheck tools**. The app looks in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.deno/bin` and `~/.local/bin`.
- **Downloads suddenly fail or say "Sign in to confirm you're not a bot" / "format not available":** YouTube changed something. Run `brew upgrade yt-dlp` and try again.
- **`Invalid manifest` / `Undefined symbols … PackageDescription` or other odd compiler errors:** your Command Line Tools install is out of sync (common after a macOS update). The current `build-app.sh` avoids the part that breaks, but if `swiftc` itself fails, reinstall the tools:
  ```bash
  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install
  ```
- **`error: xcbuild executable … does not exist`:** you're on an older copy of `build-app.sh`. The current script no longer needs full Xcode for `--universal`.
- **Private or deleted playlist videos** are shown greyed out and skipped.
- **macOS says the app can't be opened:** right-click the app and choose **Open** once. Builds made on your own Mac normally open without this.

## Shipping the tools inside the app (optional)

To make an app that works on a Mac without Homebrew, create a `bin/` folder next to `build-app.sh` and put standalone `yt-dlp` (the `yt-dlp_macos` release from GitHub, renamed), `ffmpeg` and `deno` binaries in it before building. The script copies them into the app and the app uses them first.

## Project layout

```
Package.swift                 Swift package (macOS 13+)
build-app.sh                  Compiles with swiftc, builds and ad-hoc signs "YT Downloader.app"
Sources/YTDownloader/
  YTDownloaderApp.swift       App entry point
  ContentView.swift           The window: link bar, playlist list, options, downloads
  DownloadManager.swift       Download queue and per-download progress/state
  YTDLP.swift                 Builds yt-dlp commands, reads link info, parses progress
  Tools.swift                 Finds yt-dlp, ffmpeg and deno
  Models.swift                Small data types and helpers
```
