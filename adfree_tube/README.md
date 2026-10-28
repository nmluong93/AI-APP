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
| No ads | Video ads are skipped the instant they start, and ad banners are hidden |
| Quality picker | Every resolution YouTube's player offers for the video, plus *Auto* |
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
│   ├── home_page.dart            Search screen, History screen, Settings screen
│   ├── player_page.dart          Player screen: video, quality picker, description, Up next
│   ├── player_view.dart          VideoSurface (WebView + app controls) and fullscreen
│   ├── yt_web_player.dart        YtWebPlayer: the YouTube page, injected CSS/JS, state
│   ├── mini_player.dart          Bottom "now playing" bar shown on other screens
│   ├── sleep_timer.dart          Sleep-timer button and picker sheet
│   ├── playback.dart             PlaybackController (the one app-wide player),
│   │                             background handling, sleep timer, OS media controls
│   ├── youtube_service.dart      Search, video details, related videos
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
├── test/                         Unit tests (`flutter test`)
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

## Troubleshooting

| Problem | Fix |
| --- | --- |
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
