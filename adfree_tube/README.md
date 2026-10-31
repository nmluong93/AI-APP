# AdFree Tube

A personal YouTube player for **macOS** and **Android**, written in
[Flutter](https://flutter.dev). It searches YouTube and plays videos **without
ads**, keeps playing in the background, has a sleep timer, and downloads
videos as **MP4** or their sound as **MP3**.

This README covers two kinds of readers:

- **Users** who just want to install and use the app → see
  [Using the app](#using-the-app) and [Building and installing](#building-and-installing).
- **Developers** who are new to Flutter and want to maintain or extend it →
  read it top to bottom. No prior Flutter or Dart experience is assumed.

> **Important:** playing YouTube this way goes against YouTube's Terms of
> Service, so keep the app for personal use only. YouTube Premium is the
> official way to get ad-free playback. YouTube also changes its internals
> regularly, so expect the app to break now and then. See
> [When playback stops working](#when-playback-stops-working) for the usual fix.

---

## Table of contents

1. [Features](#features)
2. [How it works](#how-it-works)
3. [The tech stack in five minutes](#the-tech-stack-in-five-minutes)
4. [Project structure](#project-structure)
5. [Setting up your machine](#setting-up-your-machine)
6. [Running the app while developing](#running-the-app-while-developing)
7. [Building and installing](#building-and-installing)
8. [Using the app](#using-the-app)
9. [Continuous integration (GitHub Actions)](#continuous-integration-github-actions)
10. [Maintaining the app](#maintaining-the-app)
11. [Making changes: a guided tour](#making-changes-a-guided-tour)
12. [Known bugs and workarounds](#known-bugs-and-workarounds)
13. [Troubleshooting](#troubleshooting)

---

## Features

| Feature | Details |
| --- | --- |
| Latest from your topics | Home shows the newest videos for topics you pick (saved on the device), loading in the background each time the app opens; the last feed shows instantly meanwhile. Filter by topic and sort by newest, most viewed or length |
| Search | YouTube search with infinite scroll |
| Open by link | Paste any YouTube URL (`youtube.com/watch?v=…`, `youtu.be/…`, Shorts) or an 11-character video id |
| No ads | Video ads are skipped the instant they start, and ad banners are hidden |
| Quality picker | Every resolution YouTube's player offers for the video, plus *Auto* |
| Default quality | Chosen in Settings and remembered between launches |
| Background playback | Keeps playing when you leave the player screen, switch apps, or lock the phone (checked on an Android emulator by every build) |
| Downloads | Save the video as MP4 (Best, 1080p, 720p, 480p or 360p) or the sound as MP3 (320, 192 or 128 kbps), with a Downloads screen showing progress, cancel, retry and open |
| System controls | Android notification and lock screen, headset buttons, macOS media keys and Control Center |
| Mini player | A small bar at the bottom of other screens showing what's playing |
| Sleep timer | Pauses after 5 min to 2 h (or a custom time), fading out the volume first |
| History | The last 200 videos you opened |
| Up next | Related videos under the player |
| Adaptive layout | Side-by-side layout on wide windows (Mac), stacked on phones |
| Theme | Light/dark, following the system |

---

## How it works

YouTube only serves video to **its own players**. They pass an anti-bot
check (a "PO token") that third-party players can't. Earlier versions of this
app fetched the video files directly, and YouTube blocked every one of those
routes (HTTP 403, "Sign in to confirm you're not a bot", no streams). So the
app now lets **YouTube's real mobile web player** play the video, inside a
WebView, and strips everything else away:

```
 ┌──────────────────┐  search, details, related   ┌──────────────┐
 │  Flutter UI      │ ──────────────────────────▶ │   YouTube    │
 │  (lib/*.dart)    │ ◀────── youtube_explode ─── │              │
 └───┬──────────▲───┘                             └──────▲───────┘
     │ commands │ state (JSON, 4×/s)                      │ video
     ▼          │                                         │
 ┌──────────────┴───────────────────────────────┐        │
 │ WebView: m.youtube.com/watch?v=…             │ ───────┘
 │  + injected CSS: video fills the view,       │
 │    site / YouTube controls / ad banners hidden│
 │  + injected JS: skips ads, reports state,     │
 │    keeps playing when the app is hidden       │
 └───────────────────────────────────────────────┘
```

1. **Finding videos.** The
   [`youtube_explode_dart`](https://pub.dev/packages/youtube_explode_dart)
   package searches YouTube and reads video details and related videos.
   (It is no longer used for playback.)
2. **Playing.** `lib/yt_web_player.dart` (`YtWebPlayer`) owns a
   [`webview_flutter`](https://pub.dev/packages/webview_flutter) WebView that
   opens `https://m.youtube.com/watch?v=<id>` with a mobile browser user
   agent, so the same mobile site loads on Android and macOS.
3. **Cleaning up the page.** On every page load it injects:
   - **CSS** that makes the `<video>` fill the WebView and hides the rest of
     the site, YouTube's own player controls, and ad banners/overlays.
   - **JavaScript** (`window.__adfree`) that, 4 times a second:
     - skips video ads: when the player has the `ad-showing` class it mutes,
       jumps to the end of the ad and clicks any *Skip* button, then restores
       the sound;
     - posts the player state (playing, position, duration, quality, errors)
       to Dart through a JavaScript channel called `AdFreeBridge`;
     - resumes playback if YouTube pauses it by itself.
   It also overrides `document.hidden`/`visibilityState` and swallows
   `visibilitychange` events, so YouTube never notices the app is in the
   background.
4. **The app's own controls.** `lib/player_view.dart` (`VideoSurface`) shows
   the WebView with a transparent gesture layer on top, so nothing on the page
   can be tapped (no accidental ad clicks), and draws Flutter controls:
   play/pause, ±10 s, seek bar, fullscreen. Commands go to the page as
   JavaScript calls such as `window.__adfree.seek(42)`.
5. **Background and system controls.**
   [`audio_service`](https://pub.dev/packages/audio_service) runs an Android
   *foreground service* (so Android doesn't kill the app when it's hidden)
   and publishes the "now playing" info and buttons to the OS. The WebView
   keeps playing because the page thinks it's still visible.

---

## The tech stack in five minutes

If you've never used Flutter, here's what you need to know to read this code.

**Dart** is the language. It looks like a mix of Java/Kotlin and
TypeScript: classes, static types, `async`/`await`, `final` (a variable that
can't be reassigned), and `?` for nullable types (`String?` can be null,
`String` can't). `_name` (a leading underscore) means *private to this file*.

**Flutter** is the UI framework. Everything on screen is a **widget**, and
widgets nest inside each other to build the UI:

- A `StatelessWidget` just draws itself from its inputs.
- A `StatefulWidget` has a `State` object holding data that changes. Calling
  `setState(() { ... })` tells Flutter to redraw it.
- `ChangeNotifier` + `ListenableBuilder` is the app's simple shared-state
  pattern. A `ChangeNotifier` object (like `PlaybackController`) calls
  `notifyListeners()` when its data changes, and every `ListenableBuilder`
  listening to it rebuilds. No extra state-management library is needed.
- `Navigator.of(context).push(MaterialPageRoute(...))` opens a new screen.
  The back button pops it.

**Hot reload**: while the app is running with `flutter run`, saving a `.dart`
file and pressing `r` in the terminal updates the running app in about a
second, keeping its state. Press `R` for a full restart. Changes to native
files (Android manifest, macOS entitlements) or new packages need a full
rebuild (stop and `flutter run` again).

**Packages** come from [pub.dev](https://pub.dev) and are listed in
`pubspec.yaml`. `flutter pub get` downloads them. `pubspec.lock` pins the
exact versions, so commit it.

**Platform folders.** `android/` and `macos/` are real native projects
(Gradle and Xcode) that Flutter generates and builds for you. You rarely touch
them, except for permissions and settings, which are covered below.

The main packages used:

| Package | Why it's here |
| --- | --- |
| `youtube_explode_dart` | Search, video details and related videos |
| `webview_flutter` (+ `_android`, `_wkwebview`) | The WebView that runs YouTube's player |
| `audio_service` | Background playback service and OS media controls |
| `shared_preferences` | Small key-value storage for settings and history |

---

## Project structure

```
adfree_tube/
├── lib/                          ← all the app's Dart code
│   ├── main.dart                 App entry point: initialises libraries, sets the theme
│   ├── home_page.dart            Home (topic feed + search), History screen, Settings screen
│   ├── topic_feed.dart           TopicFeed: newest videos for the saved topics, cached between launches
│   ├── topics_page.dart          "Your topics" screen: add, remove and suggested topics
│   ├── player_page.dart          Player screen: video, quality picker, description, Up next
│   ├── player_view.dart          VideoSurface (WebView + app controls) and fullscreen
│   ├── yt_web_player.dart        YtWebPlayer: the YouTube page, injected CSS/JS, state
│   ├── mini_player.dart          Bottom "now playing" bar shown on other screens
│   ├── sleep_timer.dart          Sleep-timer button and picker sheet
│   ├── playback.dart             PlaybackController (the one app-wide player),
│   │                             background handling, sleep timer, OS media controls
│   ├── youtube_service.dart      Search, video details, related videos
│   ├── search_input.dart         What the search bar text means: a link/id to open or words to search
│   ├── settings.dart             Saved preferences (default quality), watch history, topics, feed cache
│   ├── downloads/                Downloads: queue (Downloader), Android and Mac versions,
│   │                             yt-dlp options, Downloads screen and download sheet
│   └── widgets.dart              Shared VideoTile widget and number/duration formatting
├── android/                      Android project (Gradle)
│   └── app/src/main/
│       ├── AndroidManifest.xml   Permissions, background media service declaration
│       └── kotlin/.../
│           ├── MainActivity.kt   Extends AudioServiceActivity; keeps the WebView playing in the background
│           └── downloads/        yt-dlp download queue, foreground service, saving to Movies/Music
├── macos/                        macOS project (Xcode)
│   └── Runner/
│       ├── DebugProfile.entitlements   Permissions (network access, no sandbox) for debug builds
│       ├── Release.entitlements        Same, for release builds
│       └── Configs/AppInfo.xcconfig    App name and bundle id
├── test/                         Unit tests (`flutter test`)
├── third_party/youtube_explode_dart/  Patched copy of the search library (bug 13)
├── tool/page_script_test/       Browser test of the injected page script + YouTube-like test page
├── tool/render_test/            Emulator video and background-playback check (`render` CI job), and the Mac play-and-seek check (`macos-render`)
├── tool/download_test/          Sample video and the emulator download check (`downloads-android` CI job)
├── tool/soak_test/              Longer real-user playback scenarios on the emulator (soak workflow)
├── pubspec.yaml                  Dependencies and app version
├── pubspec.lock                  Exact resolved dependency versions (commit it)
└── analysis_options.yaml         Lint rules used by `flutter analyze`
```

The build workflow lives at the **repo root**:
`.github/workflows/adfree_tube.yml` (GitHub only reads workflows from there).

### How the pieces talk to each other

```
HomePage ──tap a video──▶ PlayerPage(videoId)
                              │ calls
                              ▼
                       PlaybackController.instance.load(id)   (lib/playback.dart)
                              │ uses
                              ▼
                       YoutubeService.instance                (lib/youtube_service.dart)
                              │ returns video info + related videos
                              ▼
                       YtWebPlayer loads m.youtube.com/watch?v=… and plays it
                              │ state changes
                              ▼
     PlayerPage / MiniPlayer / OS media controls all redraw from the controller
```

`PlaybackController` is a **singleton**: there's exactly one player for the
whole app. That's what makes background playback and the mini player work,
because closing the player screen doesn't destroy the player.

---

## Setting up your machine

You need a **Mac** to build the macOS app. The Android app can be built on
macOS, Windows or Linux.

### 1. Install Flutter

- macOS: `brew install --cask flutter`, or follow
  <https://docs.flutter.dev/get-started/install/macos>
- Windows / Linux: <https://docs.flutter.dev/get-started/install>

Check it works with `flutter --version`. The app is developed against the
current **stable** channel (Dart 3.x).

### 2. For macOS builds

1. Install **Xcode** from the App Store and open it once.
2. Run:
   ```bash
   sudo xcodebuild -license accept
   brew install cocoapods
   ```
3. For **downloads** on the Mac, install the tools the app runs:
   ```bash
   brew install yt-dlp ffmpeg deno
   ```
   (The Android app carries its own copy of these, so the phone needs
   nothing extra.)

### 3. For Android builds

1. Install **Android Studio** (<https://developer.android.com/studio>) and open
   it once. Its setup wizard installs the Android SDK.
2. In Android Studio go to *Settings → Languages & Frameworks → Android SDK →
   SDK Tools* and tick **Android SDK Command-line Tools**.
3. Accept the licences:
   ```bash
   flutter doctor --android-licenses
   ```
4. Recommended: install the **Flutter** plugin in Android Studio, or the
   **Flutter** extension in VS Code. Either gives you autocomplete, a debugger
   and a hot-reload button.

### 4. Check everything

```bash
flutter doctor
```

Fix anything marked ✗ for the platform you care about. A ✗ next to *Chrome*,
*Linux* or *Visual Studio* doesn't matter for this app.

### 5. Get the code and its packages

```bash
git clone https://github.com/nmluong93/AI-APP.git
cd AI-APP/adfree_tube
flutter pub get
```

---

## Running the app while developing

All commands are run from the `adfree_tube/` folder.

```bash
flutter devices            # list what you can run on
flutter run -d macos       # run on your Mac
flutter run -d <device-id> # run on a connected phone or emulator
```

To run on an **Android phone**: on the phone, open *Settings → About phone*
and tap *Build number* 7 times to unlock *Developer options*. Then turn on
*Developer options → USB debugging* and plug it in. To use an **emulator**
instead, create one in Android Studio's *Device Manager*.

While it's running:

| Key | Action |
| --- | --- |
| `r` | Hot reload (apply code changes, keep state) |
| `R` | Hot restart (apply changes, reset state) |
| `q` | Quit |

Before committing, run the same checks CI runs:

```bash
flutter analyze            # static analysis / lints, must say "No issues found!"
dart format lib            # formats code in the standard style
flutter test               # runs the unit tests in test/
```

---

## Building and installing

### macOS

```bash
flutter build macos --release
open build/macos/Build/Products/Release
```

Drag **AdFree Tube.app** into `/Applications`. The app isn't signed with a
paid Apple Developer ID, so macOS will block it the first time. Right-click
it, choose **Open**, then **Open** again (or allow it under *System Settings →
Privacy & Security*). You only need to do this once.

### Android

```bash
flutter build apk --release --target-platform android-arm64
```

This creates `build/app/outputs/flutter-apk/app-release.apk` for 64-bit ARM
phones (arm64), which covers practically every Android phone from the last
~8 years. Many recent phones, such as the Galaxy S23, **can't run 32-bit
apps at all**, which is why the build skips the 32-bit variant. To build for
an emulator, use `--target-platform android-x64`. To build one large APK
that runs everywhere, leave out `--target-platform`.

To install:

- **USB:** `flutter install`, or
  `adb install build/app/outputs/flutter-apk/app-release.apk`
- **Without a cable:** copy the APK to the phone (Google Drive, email,
  Quick Share…), tap it, and allow *Install unknown apps* when asked.

#### Signing (why updates sometimes say "App not installed")

Android only installs an update over an existing app when both are signed
with the **same key**.

- **Local builds** are signed with your machine's Flutter debug key. That's
  fine for personal use, but a build from another machine can't update it.
- **CI builds** use a fixed release key when these four repository secrets
  are set (*GitHub → Settings → Secrets and variables → Actions*):

  | Secret | Value |
  | --- | --- |
  | `ANDROID_KEYSTORE_BASE64` | The `.jks` keystore file, base64-encoded (`base64 -i release.jks`) |
  | `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
  | `ANDROID_KEY_ALIAS` | Key alias |
  | `ANDROID_KEY_PASSWORD` | Key password |

  Create a keystore once with:
  ```bash
  keytool -genkeypair -v -keystore release.jks -alias adfreetube \
    -keyalg RSA -keysize 2048 -validity 10000
  ```
  Keep the file and passwords safe and **never commit them**. If the secrets
  are missing, CI falls back to a throwaway debug key that's different on
  every run (the run shows a warning), so each new APK has to be installed
  after uninstalling the previous one.

The signing setup is in `android/app/build.gradle.kts`, which reads the
`ANDROID_KEYSTORE_PATH`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD` environment variables.

### Don't want to install anything? Let GitHub build it

Every push that changes `adfree_tube/` triggers the
[CI workflow](#continuous-integration-github-actions), which builds both
apps. Open the repo's **Actions** tab, click the latest **AdFree Tube build**
run, and download **adfree-tube-android** (contains `AdFreeTube.apk`) or
**adfree-tube-macos** from the *Artifacts* section at the bottom.

---

## Using the app

**Latest videos from your topics.** The first time, Home asks you to
*Choose topics*: tap suggestions such as *Music* or *Football*, or type
any words (a subject, a channel, a game) and press Enter. From then on,
every time you open the app Home shows the newest videos for those topics,
newest first. The feed you saw last time appears straight away and the
fresh one loads in the background (a thin bar at the top shows it's
refreshing), so the app stays responsive. Tap a topic chip to see only
that topic, use **Sort** (right of the chips) to order by *Newest*, *Most
viewed*, *Shortest* or *Longest* (remembered between launches; it sorts the
~20 newest videos loaded per topic, it doesn't search for the most viewed of
all time), pull down to refresh, and use **Edit** (or the topics icon at
the top) to change them. Coming back to the app after 30 minutes or more
refreshes it too.

**Find something to watch.** Type in the search bar at the top and press
Enter. Scroll down to load more results. You can also paste a YouTube link or
video id into the same bar, and it opens the video directly. Tap **✕** in
the bar (or Back on Android) to return to your topic feed.

**The player.**
- Tap or click the video to show or hide the controls: play/pause, back or
  forward 10 seconds, seek bar and fullscreen. Double-tap to play/pause.
- If an ad starts, you'll briefly see *Skipping ad…* while the app jumps past
  it.
- **Quality button:** choose a resolution or *Auto*. Playback continues from
  the same spot.
- Tap the **description** to expand it. **Up next** shows related videos.

**Background playback.** Just leave the player: go back to search, switch
apps, or lock the screen, and playback continues.
- A **mini player** appears at the bottom of the search and history screens.
  Tap it to return to the full player, or tap **✕** to stop.
- On **Android**, control playback from the notification or the lock screen,
  or use headset buttons.
- On **macOS**, use the keyboard media keys or the *Now Playing* widget in
  Control Center.

**Sleep timer.** Tap the **moon** button (on the player screen or the mini
player) and pick a duration, or *Custom…* to enter hours and minutes. The
button shows a countdown. When it reaches zero, the volume fades out over
about five seconds and playback pauses. Open the timer again and choose *Turn
off timer* to cancel it.

**Downloads.** On the player screen tap **Download**, choose *Video (MP4)*
with a quality or *Audio (MP3)* with a bitrate, and tap *Download*. The
**download icon** at the top of the search screen opens the Downloads
screen, with a badge counting running downloads. There you can watch
progress, cancel, retry a failed one, and tap a finished one to open it.
- On **Android** files go to *Movies/AdFree Tube* and *Music/AdFree Tube*,
  so they show up in Gallery, Samsung Music and My Files. Downloads keep
  going with the app in the background (there's a notification).
- On **macOS** files go to *~/Downloads/AdFree Tube*; tapping one shows it in
  Finder.
- If downloads start failing with *HTTP 403*, YouTube has changed: tap
  **Update yt-dlp** (top right of the Downloads screen) and retry. Android
  also updates yt-dlp by itself once a day and on a 403.

**History** (clock icon, top right) lists the videos you've opened. Use
*Clear* to wipe it.

**Settings** (gear icon) sets the **default quality**. The app picks the
best quality at or below that resolution, so choose a lower value to save
mobile data.

---

## Continuous integration (GitHub Actions)

The workflow is in `.github/workflows/adfree_tube.yml` at the repo root. It
runs when files under `adfree_tube/` (or the workflow itself) change, on
pushes and pull requests, and can be started by hand from the Actions tab
(*Run workflow*).

Tests gate the builds: no APK or Mac app is produced unless they pass.

| Job | Runner | Needs | Steps |
| --- | --- | --- | --- |
| `test` | Ubuntu | | `flutter analyze` → install yt-dlp and ffmpeg → `flutter test` → page script browser test (`tool/page_script_test/test.mjs`) |
| `render` | Ubuntu + Android emulator | `test` | Builds a test version of the app, runs it on an emulator against a YouTube-like page, and fails if a screenshot doesn't show the video or if it stops playing after leaving the player, pressing Home, or turning the screen off (see [Tests](#tests)) |
| `downloads-android` | Ubuntu + Android emulator | `test` | Builds a test version that downloads `tool/download_test/sample.mp4` as MP4 and MP3 with the app's own yt-dlp, and fails unless both files land in Movies/ and Music/ and `ffprobe` finds H.264+AAC and MP3 in them |
| `android` | Ubuntu | `test`, `render`, `downloads-android` | load signing key (if set) → `flutter build apk --target-platform android-arm64` → upload `AdFreeTube.apk` |
| `macos-render` | macOS | `test` | Builds a test version of the Mac app and runs it against the YouTube-like page with the canvas on and off, failing unless the video plays and, after each seek (one seek, a burst of 30, a seek back), lands where it was sent and plays on. Then once more as a user: the real mouse pauses, clicks and drags the seek bar, and plays again. Then the same on a real YouTube video, for information only. Logs and screenshots are uploaded as *macos-render-results* |
| `macos` | macOS | `test`, `macos-render` | `flutter build macos` → zip the `.app` → upload |

### Tests

| Test | What it protects | Run it locally |
| --- | --- | --- |
| `test/player_state_test.dart` | Parsing the player state the page sends | `flutter test` |
| `test/settings_test.dart` | Setting defaults (black-video workarounds on), saving, history, and the Settings screen switches | `flutter test` |
| `test/video_hosts_test.dart` | The WebView moves between screens through a gap (bug 12) | `flutter test` |
| `test/player_controls_test.dart` | On macOS the gesture layer over the video paints (so clicks reach the app, bug 19), a click brings faded controls back and moving the mouse shows them; Android keeps a gesture layer that paints nothing; dragging the seek bar seeks once, where the drag ends (bug 20) | `flutter test` |
| `test/search_input_test.dart` | What the search bar does with what you type: about 70 cases of links (watch, youtu.be, shorts, live, embed, music, with extra parameters), bare ids, 11-letter words that aren't ids, other sites, symbols, Vietnamese text, odd spaces, blank input | `flutter test` |
| `test/search_parsing_test.dart` | Reading YouTube's results page from a fake YouTube: ordinary results, the query sent, and every odd result we know of (streamed, premiered, scheduled, live, missing fields, unreadable results) without failing the search (bug 13) | `flutter test` |
| `test/search_screen_test.dart` | The search screen end to end with a fake YouTube: results show, spaces tidied, blank input ignored, errors show *Try again*, which repeats the search | `flutter test` |
| `test/page_script_contract_test.dart` | The page script still has every command the app calls, the workarounds are wired in, and Impeller stays off | `flutter test` |
| `tool/page_script_test/test.mjs` | The injected page script in a real Chromium on `youtube_like.html` (same element ids as m.youtube.com, video through Media Source Extensions like YouTube): plays unmuted, fills the view, hides the site, reports state, canvas drawing, test square, pause/play, no forced play while YouTube's player is buffering (bug 20), with the canvas on and off | `node tool/page_script_test/test.mjs` (needs Node and Playwright) |
| `test/downloads_test.dart` | yt-dlp options, progress and error parsing, the Android job format, and the Mac/desktop download queue (with a fake yt-dlp: saving, naming, errors, retry, cancel), plus real yt-dlp downloads of a local sample to MP4 and MP3 | `flutter test` (the real-yt-dlp part is skipped unless `yt-dlp` and `ffmpeg` are installed) |
| `render` CI job (`tool/render_test/`) | The whole app on an Android emulator: the video really appears on screen, in both display modes, and keeps playing (`background.py` requires the position to advance at least 0.7 s per second) on the player, after leaving it, after Home, and with the screen off. A run with the fix switched off (`bgfix=false`) shows the bug | CI only (needs KVM) |
| `macos-render` CI job (`tool/render_test/run_macos.sh`) | The whole app on a Mac: the video plays, and after a seek, a burst of 30 seeks (what dragging the seek bar used to send) and a seek back, it lands where it was sent within 6 s and plays on at least 0.6 s per second (`seek_check.py`). Runs on the test page with the canvas on and off (must pass), and on a real YouTube video (information only). The *page-user* run does it as a person would: `user_drive.py` moves the real mouse over the video so the controls show (through `mouse.swift`), clicks Play/Pause, clicks and drags the seek bar, and seeks while paused; each pause must hold still and each seek must land where it was clicked and play on | CI only (needs a Mac runner) |
| `downloads-android` CI job (`tool/download_test/`) | The app's own yt-dlp and ffmpeg download and save an MP4 and an MP3 on Android | CI only (needs KVM) |
| Soak workflow (`adfree_tube_soak.yml`, `tool/soak_test/`) | Real-user sessions on an Android emulator: pause and resume from the headset/notification controls (10 s, 1 min, 5 min, and while locked), lock and unlock (1 and 5 min), switching to Settings, Home and Recents and back 8 times, and a long play (10 min by default). `check.py` fails a run if the video doesn't keep up (75% of real time), stalls over 6 s, takes over 5 s to resume, moves while paused, shows a black frame after unlocking or coming back, or the app crashes or restarts. It also reports dropped frames and memory. The job summary has a table of every phase; logs, screenshots and `metrics.json` are in the `soak-test-results` artifact | Actions tab > **AdFree Tube soak test** > Run workflow (CI only, needs KVM) |

Add a test with every bug fix, so the bug can't come back unnoticed.

Every `run:` step runs inside `adfree_tube/` (set by `defaults.run.working-directory`).
Note that `actions/upload-artifact` paths are relative to the **repo root**,
which is why they start with `adfree_tube/`.

Artifacts are kept for 90 days by default.

---

## Maintaining the app

### When playback stops working

YouTube changes its site regularly. Because the app uses YouTube's own
player, most changes don't affect it, but a few can:

| Symptom | Likely cause | Where to fix |
| --- | --- | --- |
| Ads play instead of being skipped | YouTube renamed the CSS classes it uses during ads | The `ad-showing` / skip-button selectors in `skipAds()` in `lib/yt_web_player.dart` |
| Site elements or YouTube's own controls show over the video | YouTube renamed page elements | The `_css` block in `lib/yt_web_player.dart` |
| Controls show 0:00 or play/pause does nothing | The player element or its API changed | `video()`, `player()` and the `api.*` functions in the injected script |
| Playback stops in the background | YouTube found another way to detect that the page is hidden | The visibility overrides at the top of the injected script |
| Search, details or related videos fail | YouTube changed its internal APIs | Update `youtube_explode_dart` (below) |

**Debugging the page.** The quickest way to see what YouTube changed is to
open `https://m.youtube.com/watch?v=…` in desktop Chrome with device
emulation (DevTools → *Toggle device toolbar*), inspect the player while an
ad plays, and compare the class names with the ones in the script. On
Android you can also inspect the app's WebView itself: enable WebView
debugging (`WebViewController.setWebContentsDebuggingEnabled(true)` in a
debug build), then open `chrome://inspect` on your computer.

**Updating `youtube_explode_dart`:**

```bash
flutter pub upgrade youtube_explode_dart
```

If a new **major** version is out (e.g. 3.x → 4.x), bump it with
`flutter pub add youtube_explode_dart` and fix any compile errors
(`flutter analyze` lists them). All code that uses it is in
`lib/youtube_service.dart`, plus the `yt.Video` type used for display.

### Updating other packages and Flutter

```bash
flutter upgrade              # newest stable Flutter
flutter pub outdated         # see what's out of date
flutter pub upgrade          # update within the allowed version ranges
flutter pub upgrade --major-versions   # also take breaking major versions
flutter analyze              # fix anything that broke
```

Test on both platforms after updating, and commit `pubspec.yaml` and
`pubspec.lock` together.

### Changing the version number

In `pubspec.yaml`: `version: 1.0.0+1`. The part before `+` is the version
users see. The number after `+` is the build number, which must go up for
Android to install an update over an older build.

### Changing the app name, id or icon

- **Name:** `android:label` in `android/app/src/main/AndroidManifest.xml`, and
  `PRODUCT_NAME` in `macos/Runner/Configs/AppInfo.xcconfig`. If you change the
  macOS name, also update the `.app` name in the workflow's zip step.
- **Application id** (`com.luong.adfree_tube`): `applicationId` in
  `android/app/build.gradle.kts`, and `PRODUCT_BUNDLE_IDENTIFIER` in
  `AppInfo.xcconfig`.
- **Icon:** the easiest way is the
  [`flutter_launcher_icons`](https://pub.dev/packages/flutter_launcher_icons)
  package.

### Platform configuration you shouldn't remove

| File | Setting | Why |
| --- | --- | --- |
| `AndroidManifest.xml` | `INTERNET` permission | Release builds can't go online without it |
| `AndroidManifest.xml` | `WAKE_LOCK`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PLAYBACK`, the `AudioService` `<service>` and `MediaButtonReceiver` `<receiver>` | Background playback and media buttons (`audio_service`) |
| `MainActivity.kt` | `extends AudioServiceActivity` | Required by `audio_service` |
| `AndroidManifest.xml` | `io.flutter.embedding.android.EnableImpeller` = `false` | With Flutter's Impeller renderer the WebView's video shows black (sound still plays). If a future Flutter removes this opt-out, try `io.flutter.embedding.android.ImpellerBackend` = `opengles` instead |
| `macos/Runner/*.entitlements` | `com.apple.security.network.client`, and **no** `com.apple.security.app-sandbox` | Network access; and a sandboxed app can't run the Homebrew `yt-dlp` for downloads |
| `AndroidManifest.xml` | `FOREGROUND_SERVICE_DATA_SYNC` and the `DownloadService` `<service>` | Downloads keep running in the background |
| `android/app/build.gradle.kts` | `minSdk` 29, `useLegacyPackaging = true`, the `youtubedl-android` dependencies | Saving to Movies/Music needs Android 10; youtubedl-android runs Python and ffmpeg from the unpacked native library folder |

---

## Making changes: a guided tour

A few common changes, showing where to look.

**Change the sleep timer presets.** Edit `_presets` in
`lib/sleep_timer.dart`. The fade-out length is the loop in
`PlaybackController._fadeOutAndPause()` (`lib/playback.dart`): 10 steps of
500 ms.

**Change the default quality or the quality list.** `AppSettings.qualities`
and the `?? 1080` default in `preferredHeight` (`lib/settings.dart`).

**Change what gets hidden or how ads are skipped.** Everything that touches
the YouTube page lives in `lib/yt_web_player.dart`: `_css` (what is hidden and
how the video is stretched to fill the view) and `_script` (`skipAds()`, the
skip-button selectors, and the state that `tick()` reports). YouTube renames
its CSS classes from time to time, so this is the part most likely to need
updates. See [Debugging tips](#debugging-tips) for how to inspect the live
page.

**Change the seek-button step in the notification.** `fastForwardInterval` /
`rewindInterval` in `PlaybackController.initSystemControls()`.

**Add a new screen.** Create `lib/my_page.dart` with a `StatelessWidget` or
`StatefulWidget` that returns a `Scaffold`, then open it with
`Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyPage()))`.
Add `bottomNavigationBar: const MiniPlayer()` to its `Scaffold` if it should
show the mini player.

**Store a new setting.** Add a getter/setter pair to `AppSettings`
(`lib/settings.dart`) that reads and writes `_prefs`, and calls
`notifyListeners()` in the setter. Read it anywhere with
`AppSettings.instance.yourSetting`.

**Add autoplay of the next video.** In `PlaybackController._onPlayerState()`
(`lib/playback.dart`), check `s.ended && !_last.ended`. When that is true and
`related` is not empty, call `load(related.first.id.value)`. Remember to
respect an active sleep timer.

**Add a feature that needs the player.** Use `PlaybackController.instance`.
Its `player` field is a `YtWebPlayer` (`lib/yt_web_player.dart`) with
`play()`, `pause()`, `playOrPause()`, `seek()`, `setQuality()` and
`setVolume()`. It is also a `ValueNotifier<YtPlayerState>`, so wrap a widget
in `ValueListenableBuilder(valueListenable: c.player, ...)` to redraw it as
the position, buffering or ad state changes. To add a new command, add a
function to `api` in `_script` and a Dart method that calls it through
`_cmd()`.

### Things to know before you change playback code

- **One WebView, one place.** The same `WebViewController` can only be shown
  by one `WebViewWidget` at a time. `VideoSurface.fullscreenActive` makes the
  normal player page step aside while the fullscreen page shows the video. If
  you add another place that shows the video, follow the same pattern.
- **The page never gets touches.** `VideoSurface` puts an opaque
  `GestureDetector` over the WebView, so nothing on YouTube's page (ads,
  links, its own buttons) can be tapped. Keep it that way, and draw any new
  control in Flutter instead.
- **Background playback** relies on two things: the script tells the page it
  is always visible (it overrides `document.hidden` and swallows
  `visibilitychange`), and `audio_service` runs a foreground service so
  Android doesn't kill the app. Remove either and playback stops when the
  screen locks.
- **State comes from the page.** `tick()` runs every 250 ms and posts JSON to
  the `AdFreeBridge` channel only when something changed. `YtPlayerState.fromJson`
  turns it into Dart. If you add a field, add it on both sides and to
  `test/player_state_test.dart`.
- **Navigation is locked down.** `onNavigationRequest` only allows YouTube and
  Google hosts in the main frame, so ad clicks and app-store links go nowhere.

### Debugging tips

- `debugPrint('...')` writes to the `flutter run` console.
- `flutter run` then press `v` (or use the Flutter extension) to open
  **DevTools**, which has a widget inspector, network log and performance view.
- Android native logs: `adb logcat | grep -i -E "flutter|chromium|audioservice"`.
- **Long-press the video** in any build (including release) to get a
  copyable report of the page's player: muted state, volume, which `<video>`
  elements exist, their size on screen and decode state. It comes from
  `api.debug()` in `_script`.
- **Inspect the YouTube page itself.** Debug builds let Chrome on your
  computer attach to the app's WebView: connect the phone with USB debugging
  on, open `chrome://inspect` in desktop Chrome, and click **inspect** under
  the app. You get the full DevTools (elements, console, network) for the
  page, which is the fastest way to find new ad or skip-button class names.
  On macOS, Safari's **Develop** menu does the same.
- Without a phone, open <https://m.youtube.com> in desktop Chrome with device
  emulation (DevTools → toggle device toolbar) and paste the contents of
  `_script` into the console to try changes.

---

## Known bugs and workarounds

Problems we hit while building the app, what caused them, and what the code
does about them. Each workaround has a comment starting with
`Workaround:` at the place in the code where it lives, so search for that
word before you change or remove anything.

| # | Symptom | Root cause | Workaround (where) |
| --- | --- | --- | --- |
| 1 | Android says *"App not installed"* on a Galaxy S23 | The APK was built for 32-bit ARM; the S23 can only run 64-bit apps | CI builds one arm64 APK (`.github/workflows/adfree_tube.yml`) |
| 2 | *"App not installed"* when updating over an older build | Each CI build signs with a new throwaway debug key, and Android refuses an update signed by a different key | Uninstall first, or add the signing secrets ([Signing](#signing-why-updates-sometimes-say-app-not-installed)) |
| 3 | Video stuck loading; errors such as 403, *"Sign in to confirm you're not a bot"*, *"The page needs to be reloaded"* | YouTube now only serves video to its own players, which pass an anti-bot check (PO tokens) that third-party players can't | Play with YouTube's own mobile player inside a WebView instead of fetching streams (`lib/yt_web_player.dart`) |
| 4 | Android build fails in `flutter_inappwebview` (*"getDefaultProguardFile('proguard-android.txt') is no longer supported"*) | That plugin isn't updated for the current Android Gradle Plugin | Use the official `webview_flutter` instead (`pubspec.yaml`) |
| 5 | Time moves but no sound | YouTube's mobile site starts videos muted and waits for a tap on *"Tap to unmute"*, and the app never lets taps reach the page | `unmute()` in `_script` (`lib/yt_web_player.dart`) |
| 6 | Controls act on the wrong video | The page can contain more than one `<video>` | `video()` in `_script` picks the one inside `#movie_player` |
| 7 | Sound plays but the picture is black on Android | Under investigation; see below | See below |
| 8 | YouTube pauses when the app goes to the background or the screen locks | The page sees `visibilitychange` / `document.hidden` and pauses | `_script` reports the page as always visible; `audio_service` keeps the app alive (`lib/playback.dart`) |
| 9 | The video disappears from one screen when shown on another | One `WebViewController` can only be shown by one `WebViewWidget` at a time | `VideoHosts`: the newest screen that wants the video shows it (`lib/player_view.dart`) |
| 10 | Playback stops when you press Home or the screen turns off (Android) | Android tells the WebView its window is hidden; Chromium then pauses the page's media and lowers the renderer's priority, so hiding it from the page (bug 8) isn't enough | `MainActivity.kt` keeps every WebView marked visible, resumed and at important priority while the app is in the background; the `render` CI job checks it |
| 11 | Playback stops when you leave the player screen for search or history | A WebView that isn't on screen at all counts as hidden too | `BackgroundVideoHost` keeps the WebView attached as a 1x1 pixel view while no player screen is open (`lib/player_view.dart`) |
| 12 | The app closes when the video moves between screens (player, fullscreen, the background view) in hybrid display mode | Android can't add the WebView to its new place while it still has its old parent | `VideoHosts` takes the WebView out first and puts it in its new place 150 ms later (`lib/player_view.dart`); `test/video_hosts_test.dart` checks it |
| 13 | Some searches fail with *"FormatException: Invalid radix-10 number … Streamed"* | youtube_explode_dart 3.1.0 can't read some dates YouTube puts on results (e.g. *"Streamed 2 weeks ago"* with a non-breaking space) or the view count of live videos, and one bad result failed the whole search | A patched copy of the package in `third_party/youtube_explode_dart` (`dependency_overrides` in `pubspec.yaml`; search for *AdFree Tube patch*): odd dates and lengths give null, and a result that still can't be read is skipped. Remove it when a fixed version is on pub.dev |
| 14 | The app closes as soon as it opens (builds with downloads) | Flutter shrinks release builds with R8, which removed or renamed classes the yt-dlp library loads by name; and the engine only caught `Exception`, so the resulting `Error` crashed the app | Keep rules in `android/app/proguard-rules.pro`, and the download engine catches every `Throwable`, so a broken engine only disables downloads (`Engine.kt`, `DownloadQueue.kt`) |
| 15 | Playback stops a minute after the screen goes off (Android 13+ release builds) | audio_service looks its notification icons up by name, so the release build's resource shrinker removed them; Android 13+ rejects the media controls without an icon, so the playback service never became a foreground service and Android froze the app | `android/app/src/main/res/raw/keep.xml` keeps those icons; the emulator test now reports whether the service is in the foreground |
| 16 | Video stutters after switching away from the app and back (reported on a Galaxy S23; not yet confirmed fixed) | Not certain. Android briefly hides the WebView before the bug 10 workaround answers, and Chromium's video pipeline seems to stay out of step afterwards | When the app is back in front, `PlaybackController` calls `api.refresh()`, which seeks the video to where it already is to reset it. The player diagnostics report (long-press the video) now has a `perf` section (page fps, canvas copy time, dropped frames, buffering) to tell where any remaining lag comes from |
| 17 | After switching away and back, the player shows 0:00 / 0:00 and won't play (Galaxy S23) | Not certain: the page's YouTube player loses its video. The first bug 16 reset went through YouTube's own `seekTo`, which may have triggered it | `api.refresh()` now only nudges the `<video>` itself when the spot is buffered. `ResumePoint` (`lib/yt_web_player.dart`) remembers the position; if the video is lost, coming back to the app or pressing Play loads it again from there (`PlaybackController` in `lib/playback.dart`); `test/resume_point_test.dart` |
| 18 | The media notification can't be closed, even after leaving the app | Stop waited for the page to clear before removing the notification, so a page that didn't answer blocked it; and the playback service is kept in the foreground on purpose (bug 8), so it outlived the app | Stop clears the app and the notification first and gives up on the page after 3 s; swiping the app away from Recents stops playback (`_MediaHandler.onTaskRemoved`) |
| 19 | macOS: the progress bar and Play/Pause button disappear a few seconds into a video and never come back, so the video can't be paused | On macOS, Flutter sends a click over a platform view (the WebView) to that view unless Flutter painted something at that spot. The full-size gesture layer paints nothing, so once the controls faded out every click went to the YouTube page instead of the app | On macOS the gesture layer paints a practically invisible tint (`clickShieldColor`), and moving the mouse over the video shows the controls (`VideoSurface` in `lib/player_view.dart`); `test/player_controls_test.dart` |
| 20 | macOS: after a seek the video keeps loading, or plays slowly with no sound; sometimes sound but a black picture | Most likely the app told YouTube it was Chrome on Android while the page really runs in Safari's engine (WebKit). The diagnostics showed the `<video>` stuck at `readyState` 1 with no decoded frames, before and after a seek, while YouTube's player said it was buffering. Other suspects: dragging the seek bar sent the page a seek on every step of the drag, dozens a second; the page script forced the `<video>` to play while YouTube was still loading the new spot; and the Android-only black-video workarounds (canvas copy, 0.99 opacity and a tiny rotation) can make WebKit draw video the slow way | On macOS the app now says it is Safari on an iPhone (`_userAgent` in `lib/yt_web_player.dart`), so YouTube streams the way it does for WebKit. The seek bar only seeks where the drag ends; the script no longer forces play while the video is seeking or YouTube's player is buffering (state 3; `tick()` in `_script`, checked by `tool/page_script_test/test.mjs`). Turning the canvas and *Keep video drawn in the page* off on macOS made real YouTube videos black there, so they stay on (`VideoSurface` in `lib/player_view.dart`; `test/player_controls_test.dart`). The `macos-render` CI job plays and seeks on a real Mac, including a burst of seeks like the old drag, with the canvas on and off, on the test page and (for information) on a real YouTube video (`_seekTest` in `lib/main.dart`, `tool/render_test/run_macos.sh`), and once as a user with the real mouse on the controls (`user_drive.py`) |

### Bug 7: black picture with sound on Android

Diagnostics from a Galaxy S23 show the page itself is fine: the `<video>`
decodes frames (e.g. 1920x1080), is visible, and fills the view. The picture
is lost after that, when the WebView is put on screen. The same setup shows
the video correctly on an Android emulator (see the render test below), so
the cause is specific to real phones' graphics hardware.

The suspects, and what the code does about each:

| Suspect | Workaround | Where | Result on the S23 |
| --- | --- | --- | --- |
| Anything about how the phone puts the video layer on screen | Each video frame is copied into a `<canvas>` over the video, which is drawn like any other page content (**Settings → Draw video through a canvas**, on by default) | `drawFrame()` in `_script`, `AppSettings.canvasVideo` | Not yet tried |
| Android's way of embedding the WebView | Two modes, switchable in **Settings → Video display**: hybrid composition (default) or texture | `_webViewFor()` in `lib/player_view.dart`, `AppSettings.videoDisplay` | Texture (first build) and hybrid both black, but not yet tried with the other workarounds |
| The WebView moving video to a separate hardware layer that Flutter doesn't show | Video drawn 0.99 opaque and rotated 0.001 degrees, which disqualifies it; **Settings → Keep video drawn in the page** turns it off | `keepVisible()` in `_script`, `AppSettings.pageDrawnVideo` | Opacity alone: still black. With rotation: not yet tried |
| Flutter's Impeller renderer | Turned off | `EnableImpeller` in `AndroidManifest.xml` | Still black on its own |
| Our CSS hiding a parent of the video | Parents of the video are forced visible | `keepVisible()` in `_script` | Diagnostics show every parent visible, so not the cause |

The long-press diagnostics report starts with the display mode and option
in use, so reports can be matched to settings.

The `render` CI job (see [Tests](#tests)) runs a test build on an Android
emulator against `tool/page_script_test/youtube_like.html` (a green video),
screenshots it, and fails if the green video isn't on screen. Its results are
the lines starting with `RENDER_TEST` at the end of the *Run on emulator*
step. The emulator shows the video even without the canvas, so it can't
reproduce the S23 bug itself; it guards against breaking the video
completely. On a phone, long-press the video and use **Test square** in the
diagnostics dialog: if the orange square shows but the video doesn't, the
WebView is on screen and only the video is lost.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| Time moves but there's no picture or sound | Long-press the video, tap **Copy** in *Player diagnostics*, and look at the `videos` list: `muted`, `size` (0x0 means no frames decoded) and `rect`/`display` (whether it's on screen) |
| Video stuck loading, or a YouTube error shows under the player | Copy the error text and see [When playback stops working](#when-playback-stops-working). Try another video first: some are blocked from playing outside youtube.com |
| Ads play instead of being skipped, or parts of the YouTube site show over the video | YouTube changed its page. Update the selectors in `_css` / `skipAds()` in `lib/yt_web_player.dart` (see [Debugging tips](#debugging-tips)) |
| Search shows *"Search failed"* | Check your internet connection. If it persists, update `youtube_explode_dart` |
| Playback stops a few minutes after locking the phone | The phone's battery saver is killing the app. *Settings → Apps → AdFree Tube → Battery → Unrestricted* (wording varies by brand; <https://dontkillmyapp.com> has per-brand steps) |
| No notification controls on Android | Make sure notifications are allowed for the app in Android settings |
| macOS: *"AdFree Tube can't be opened"* | Right-click → **Open**, or allow it in *System Settings → Privacy & Security* |
| macOS: thumbnails and videos don't load | The `network.client` entitlement is missing from `macos/Runner/*.entitlements` |
| Android: *"App not installed"* | Either the APK is for the wrong processor type (a 32-bit `armeabi-v7a` APK on a 64-bit-only phone such as the S23), or an existing copy was signed with a different key. Uninstall the old copy first; see [Signing](#signing-why-updates-sometimes-say-app-not-installed) |
| `flutter build macos` fails with CocoaPods errors | `cd macos && pod repo update && cd .. && flutter clean && flutter pub get` |
| Odd build errors after updating packages | `flutter clean && flutter pub get`, then build again |
| `flutter doctor` complains about Android licences | `flutter doctor --android-licenses` and accept all |
