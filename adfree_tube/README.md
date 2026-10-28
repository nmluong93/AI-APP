# AdFree Tube

A personal YouTube player for **macOS** and **Android**, built with Flutter.
It searches YouTube and plays videos with no ads, because it never loads
YouTube's web player. It fetches the video's media streams directly (via
[`youtube_explode_dart`](https://pub.dev/packages/youtube_explode_dart)) and
plays them with [`media_kit`](https://pub.dev/packages/media_kit) (libmpv).

> **Heads up:** playing YouTube this way is against YouTube's Terms of Service.
> It's meant for personal use only. YouTube Premium is the official way to get
> ad-free playback. YouTube also changes its internals from time to time; when
> playback suddenly breaks, update `youtube_explode_dart`
> (`flutter pub upgrade youtube_explode_dart`) and rebuild.

## Features

- Search with infinite scroll, or paste any YouTube link / video id
- Quality picker up to 4K (separate video + audio streams), plus 360p muxed,
  HLS "Auto", and an **Audio only** mode
- Remembers your preferred default quality
- **Background playback**: keeps playing when you leave the player screen,
  switch apps, or lock the phone. A mini player sits at the bottom of the app,
  and you get play/pause/seek controls in the Android notification and lock
  screen, on headset buttons, and in macOS Control Center / media keys
- **Sleep timer**: pause automatically after 5 min to 2 hours (or a custom
  time), with a gentle volume fade-out
- Watch history, "Up next" related videos
- Keyboard shortcuts on macOS (space, arrows, F for fullscreen), gestures on Android
- Light/dark theme following the system

## Code layout

| File | What it does |
| --- | --- |
| `lib/main.dart` | App entry, theme |
| `lib/home_page.dart` | Search, history and settings screens |
| `lib/player_page.dart` | Player screen, quality picker, description, related videos |
| `lib/playback.dart` | App-wide player, background playback, system media controls, sleep timer |
| `lib/sleep_timer.dart` | Sleep timer button and picker |
| `lib/mini_player.dart` | Mini player bar shown on other screens |
| `lib/youtube_service.dart` | Search, metadata, stream selection |
| `lib/settings.dart` | Saved quality preference and history |

## Build it yourself

### 1. One-time setup (on a Mac)

1. Install Flutter: <https://docs.flutter.dev/get-started/install/macos>
   (or `brew install --cask flutter`).
2. For macOS builds: install **Xcode** from the App Store, then
   `sudo xcodebuild -license accept` and `sudo gem install cocoapods`
   (or `brew install cocoapods`).
3. For Android builds: install **Android Studio**, open it once so it installs
   the Android SDK, then run `flutter doctor --android-licenses`.
4. Run `flutter doctor` and fix anything it marks with ✗ for the platform you want.

Then, in this folder:

```bash
flutter pub get
```

### 2. macOS

Run it directly:

```bash
flutter run -d macos
```

Or build a standalone app:

```bash
flutter build macos --release
open "build/macos/Build/Products/Release"
```

Drag **AdFree Tube.app** into `/Applications`. The app isn't signed with an
Apple Developer ID, so the first time, right-click it → **Open** → **Open**
(or allow it in System Settings → Privacy & Security).

### 3. Android

Build the APK:

```bash
flutter build apk --release --split-per-abi
```

The APKs land in `build/app/outputs/flutter-apk/`. Most modern phones use
`app-arm64-v8a-release.apk`.

Install it either way:

- **USB:** enable *Developer options → USB debugging* on the phone, plug it in, and run
  `flutter install` (or `adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`).
- **File copy:** send the APK to the phone (Google Drive, email, cable), tap it,
  and allow "Install unknown apps" for the app you opened it from.

The release APK is signed with the debug key, which is fine for personal use.

If playback stops after a while with the screen off, your phone's battery saver
is killing the app: go to *Settings → Apps → AdFree Tube → Battery* and choose
*Unrestricted* (wording varies by phone brand).

### 4. No Mac setup? Let GitHub build it

The workflow `.github/workflows/adfree_tube.yml` (at the root of the AI-APP
repo) builds both the Android APKs and the macOS app whenever `adfree_tube/`
changes, or on demand from the Actions tab → **AdFree Tube build** →
*Run workflow*.
Download them from the run's **Artifacts** section.
