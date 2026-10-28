# AdFree Tube

A personal YouTube player for **macOS** and **Android**, written in
[Flutter](https://flutter.dev). It searches YouTube and plays videos **without
ads**, keeps playing in the background, and has a sleep timer.

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
12. [Troubleshooting](#troubleshooting)

---

## Features

| Feature | Details |
| --- | --- |
| Search | YouTube search with infinite scroll |
| Open by link | Paste any YouTube URL (`youtube.com/watch?v=…`, `youtu.be/…`, Shorts) or an 11-character video id |
| No ads | YouTube's web player is never loaded, so no ad requests are ever made |
| Quality picker | Every resolution YouTube offers for the video, plus *Audio only* |
| Default quality | Chosen in Settings and remembered between launches |
| Background playback | Keeps playing when you leave the player screen, switch apps, or lock the phone |
| System controls | Android notification and lock screen, headset buttons, macOS media keys and Control Center |
| Mini player | A small bar at the bottom of other screens showing what's playing |
| Sleep timer | Pauses after 5 min to 2 h (or a custom time), fading out the volume first |
| History | The last 200 videos you opened |
| Up next | Related videos under the player |
| Adaptive layout | Side-by-side layout on wide windows (Mac), stacked on phones |
| Theme | Light/dark, following the system |

---

## How it works

A normal YouTube embed loads YouTube's own web player, and that player is
what shows ads. This app skips it entirely:

```
 ┌──────────────┐  search / metadata / stream URLs   ┌──────────────┐
 │  Flutter UI  │ ─────────────────────────────────▶ │   YouTube    │
 │ (lib/*.dart) │ ◀───────────────────────────────── │  (internal   │
 └──────┬───────┘   JSON + direct googlevideo.com    │    APIs)     │
        │           media URLs                        └──────────────┘
        │ open(url)
        ▼
 ┌──────────────┐   decoded video frames  ┌──────────────────────┐
 │  media_kit   │ ──────────────────────▶ │ Video widget on screen│
 │  (libmpv)    │   audio ──▶ speakers    └──────────────────────┘
 └──────┬───────┘
        │ play/pause/position
        ▼
 ┌──────────────┐
 │audio_service │ ──▶ Android notification, lock screen, macOS media keys
 └──────────────┘
```

1. **Finding videos.** The
   [`youtube_explode_dart`](https://pub.dev/packages/youtube_explode_dart)
   package talks to YouTube's internal APIs, the same ones YouTube's own apps
   use, to search, read video details, and get a *stream manifest*.
2. **Picking a stream.** The manifest lists many streams. YouTube serves
   high resolutions as **separate video-only and audio-only streams**, and
   only 360p as a single "muxed" (video + audio) stream.
   `lib/youtube_service.dart` turns the manifest into a simple list of
   `PlaybackSource`s (one per resolution), each with a video URL and an
   optional separate audio URL.
3. **Proxying.** YouTube stalls or refuses stream downloads that are
   requested in one huge piece or with unexpected headers. So the player never
   opens YouTube's URLs directly. `lib/stream_proxy.dart` runs a tiny HTTP
   server on `127.0.0.1`, and the player reads from it. For each request it
   fetches the data from YouTube in chunks of at most 10 MB, using the same
   headers and range style that `youtube_explode_dart` uses for its own
   downloads. It also records YouTube's HTTP errors (e.g. 403) so the app can
   show them.
4. **Solving YouTube's JavaScript challenges.** Stream URLs come with
   scrambled parameters (`n` and the signature) that have to be unscrambled
   with YouTube's own player JavaScript. Without that, the web client returns
   no usable URLs and the others are throttled. `lib/js_solver.dart` runs
   yt-dlp's solver scripts (shipped with `youtube_explode_dart`) inside an
   invisible WebView (`webview_flutter`), which gives the app a full
   JavaScript engine on both Android and macOS.
5. **Choosing a YouTube client.** YouTube hands out stream URLs per "client"
   (Android app, VR app, TV, iOS, web). Some clients' URLs need extra tokens
   only the official apps can make. `YoutubeService.clientOrder` lists the
   clients to try. If no stream from one client plays, `PlaybackController`
   fetches fresh URLs from the next client and tries again.
6. **Playing.** [`media_kit`](https://pub.dev/packages/media_kit) wraps
   **libmpv**, a powerful native media player. We open the video URL and,
   if there's a separate audio stream, attach it as an *external audio
   track*. mpv keeps the two in sync.
7. **Background and system controls.**
   [`audio_service`](https://pub.dev/packages/audio_service) runs an Android
   *foreground service* (so Android doesn't kill the app when it's hidden)
   and publishes the "now playing" info and buttons to the OS.

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
| `youtube_explode_dart` | Search, video details, and stream URLs from YouTube |
| `media_kit`, `media_kit_video`, `media_kit_libs_video` | Native video playback (libmpv) and the `Video` widget with built-in controls |
| `audio_service` | Background playback service and OS media controls |
| `shared_preferences` | Small key-value storage for settings and history |
| `webview_flutter` | Hidden WebView used as a JavaScript engine for YouTube's challenges |

---

## Project structure

```
adfree_tube/
├── lib/                          ← all the app's Dart code
│   ├── main.dart                 App entry point: initialises libraries, sets the theme
│   ├── home_page.dart            Search screen, History screen, Settings screen
│   ├── player_page.dart          Player screen: video, quality picker, description, Up next
│   ├── mini_player.dart          Bottom "now playing" bar shown on other screens
│   ├── sleep_timer.dart          Sleep-timer button and picker sheet
│   ├── playback.dart             PlaybackController (the one app-wide player),
│   │                             background handling, sleep timer, OS media controls
│   ├── youtube_service.dart      Everything that talks to YouTube; builds PlaybackSources
│   ├── stream_proxy.dart         Local HTTP proxy the player reads streams through (see below)
│   ├── js_solver.dart            Solves YouTube's JavaScript challenges in a hidden WebView
│   ├── settings.dart             Saved preferences (default quality) and watch history
│   └── widgets.dart              Shared VideoTile widget and number/duration formatting
├── android/                      Android project (Gradle)
│   └── app/src/main/
│       ├── AndroidManifest.xml   Permissions, background media service declaration
│       └── kotlin/.../MainActivity.kt   Extends AudioServiceActivity (needed by audio_service)
├── macos/                        macOS project (Xcode)
│   └── Runner/
│       ├── DebugProfile.entitlements   Sandbox permissions (network access) for debug builds
│       ├── Release.entitlements        Same, for release builds
│       └── Configs/AppInfo.xcconfig    App name and bundle id
├── test/                         Unit tests (`flutter test`), e.g. for the stream proxy
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
                              │ returns video info + List<PlaybackSource>
                              ▼
                       Player (media_kit) plays the chosen source
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

**Find something to watch.** Type in the search bar at the top and press
Enter. Scroll down to load more results. You can also paste a YouTube link or
video id into the same bar, and it opens the video directly.

**The player.**
- Tap or click the video to show the controls (play/pause, seek bar, volume,
  fullscreen).
- On **macOS**: `Space` plays/pauses, `←`/`→` seek, `↑`/`↓` change volume,
  `F` toggles fullscreen and `Esc` leaves it.
- **Quality button:** choose a resolution, or *Audio only* (much less data, handy for music and podcasts).
  Playback continues from the same spot.
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

**History** (clock icon, top right) lists the videos you've opened. Use
*Clear* to wipe it.

**Settings** (gear icon) sets the **default quality**. The app picks the
best stream at or below that resolution, so choose a lower value to save
mobile data.

---

## Continuous integration (GitHub Actions)

The workflow is in `.github/workflows/adfree_tube.yml` at the repo root. It
runs when files under `adfree_tube/` (or the workflow itself) change, on
pushes and pull requests, and can be started by hand from the Actions tab
(*Run workflow*).

| Job | Runner | Steps |
| --- | --- | --- |
| `android` | Ubuntu | `flutter pub get` → `flutter analyze` → `flutter test` → load signing key (if set) → `flutter build apk --target-platform android-arm64` → upload `AdFreeTube.apk` |
| `macos` | macOS | `flutter pub get` → `flutter build macos` → zip the `.app` → upload |

Every `run:` step runs inside `adfree_tube/` (set by `defaults.run.working-directory`).
Note that `actions/upload-artifact` paths are relative to the **repo root**,
which is why they start with `adfree_tube/`.

Artifacts are kept for 90 days by default.

---

## Maintaining the app

### When playback stops working

> **Note:** the app currently uses a **patched copy** of `youtube_explode_dart`
> in `third_party/youtube_explode_dart/` (see its `PATCHES.md`), wired in with
> `dependency_overrides` in `pubspec.yaml`. While that override exists,
> `flutter pub upgrade youtube_explode_dart` has no effect. To upgrade,
> replace that folder with the new release and re-apply the patches if they
> are still needed, or remove the folder and the override once upstream
> includes the fix.

YouTube changes its internals regularly, and when it does, search or playback
can fail with errors like *"Could not load streams"*, HTTP 403, or videos
that load forever. This is almost always fixed by updating
`youtube_explode_dart`, whose maintainers keep up with those changes:

```bash
flutter pub upgrade youtube_explode_dart
flutter run -d macos     # check it works
```

If a new **major** version is out (e.g. 3.x → 4.x), `pub upgrade` won't take
it automatically. Bump it with `flutter pub add youtube_explode_dart`, then
fix any compile errors (`flutter analyze` lists them). All the code that uses
this package is in `lib/youtube_service.dart` (plus the `yt.Video` type used
for display), so that's the only place that should need changes. Check the
package's [changelog](https://pub.dev/packages/youtube_explode_dart/changelog)
and [GitHub issues](https://github.com/Hexer10/youtube_explode_dart/issues)
for known problems.

`YoutubeService.clientOrder` lists the YouTube "clients" the app asks for
streams, in order (currently `safari` (web, HLS), `tv`, `androidVr`, `ios`, then the
library default). When a video fails, the error box under the player lists every
client and stream that was tried and why it failed (tap **Copy** to share
it). If one client starts working better than the others, move it to the
front of that list. yt-dlp's
[PO token guide](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide) is a
good, current reference on which clients need what.

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
| `macos/Runner/*.entitlements` | `com.apple.security.network.client` | The sandboxed Mac app can't make network requests without it |

---

## Making changes: a guided tour

A few common changes, showing where to look.

**Change the sleep timer presets.** Edit `_presets` in
`lib/sleep_timer.dart`. The fade-out length is the loop in
`PlaybackController._fadeOutAndPause()` (`lib/playback.dart`): 10 steps of
500 ms.

**Change the default quality or the quality list.** `AppSettings.qualities`
and the `?? 1080` default in `preferredHeight` (`lib/settings.dart`).

**Change how streams are picked** (e.g. prefer VP9/WebM over H.264).
`YoutubeService.sources()` and `_better()` in `lib/youtube_service.dart`.
H.264 (mp4) is preferred today because nearly every device can decode it in
hardware, which saves battery.

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

**Add autoplay of the next video.** In `PlaybackController`, the constructor
already listens to `player.stream.completed`. When it fires and `related` is
not empty, call `load(related.first.id.value)`. Remember to respect an
active sleep timer.

**Add a feature that needs the player.** Use `PlaybackController.instance`.
Its `player` field is a media_kit
[`Player`](https://pub.dev/documentation/media_kit/latest/media_kit/Player-class.html)
with `play()`, `pause()`, `seek()`, `setRate()`, `setVolume()` and so on, and
`player.stream.*` lets you listen to changes.

### Things to know before you change playback code

- **Separate audio track.** For most resolutions the audio is attached with
  `player.setAudioTrack(AudioTrack.uri(...))` *after* the video has loaded
  (`play()` waits for a non-zero duration first). If you change the open
  sequence, keep that order, or the audio may be missing.
- **Android background.** When the app goes to the background, Android
  destroys the video surface. `didChangeAppLifecycleState()` turns off the
  video track (`VideoTrack.no()`) so only audio is decoded, and turns it back
  on (`VideoTrack.auto()`) when you come back.
- **`Video` widget flags.** `pauseUponEnteringBackgroundMode: false` in
  `player_page.dart` is what stops media_kit from pausing when the app is
  hidden. Don't remove it.
- **Stream URLs expire** after a few hours. If you add something like
  "resume later", re-fetch the sources rather than storing the URLs.

### Debugging tips

- `debugPrint('...')` writes to the `flutter run` console.
- `flutter run` then press `v` (or use the Flutter extension) to open
  **DevTools**, which has a widget inspector, network log and performance view.
- Android native logs: `adb logcat | grep -i -E "flutter|mpv|audioservice"`.
- To test stream picking without the UI, write a small Dart script that calls
  `YoutubeService.instance.sources('dQw4w9WgXcQ')` and prints the result, and
  run it with `dart run path/to/script.dart`.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| *"Could not load streams"*, 403 errors, or videos stuck loading | Update `youtube_explode_dart` (see [When playback stops working](#when-playback-stops-working)) |
| Search shows *"Search failed"* | Check your internet connection. If it persists, update `youtube_explode_dart` |
| No sound at high resolutions, but 360p works | The separate audio track failed to attach. Try another quality. If it's consistent, check `PlaybackController.play()` |
| Playback stops a few minutes after locking the phone | The phone's battery saver is killing the app. *Settings → Apps → AdFree Tube → Battery → Unrestricted* (wording varies by brand; <https://dontkillmyapp.com> has per-brand steps) |
| No notification controls on Android | Make sure notifications are allowed for the app in Android settings |
| macOS: *"AdFree Tube can't be opened"* | Right-click → **Open**, or allow it in *System Settings → Privacy & Security* |
| macOS: thumbnails and videos don't load | The `network.client` entitlement is missing from `macos/Runner/*.entitlements` |
| Android: *"App not installed"* | Either the APK is for the wrong processor type (a 32-bit `armeabi-v7a` APK on a 64-bit-only phone such as the S23), or an existing copy was signed with a different key. Uninstall the old copy first; see [Signing](#signing-why-updates-sometimes-say-app-not-installed) |
| `flutter build macos` fails with CocoaPods errors | `cd macos && pod repo update && cd .. && flutter clean && flutter pub get` |
| Odd build errors after updating packages | `flutter clean && flutter pub get`, then build again |
| `flutter doctor` complains about Android licences | `flutter doctor --android-licenses` and accept all |
