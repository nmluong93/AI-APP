# YT Downloader (Android)

The Android version of the YT Downloader Mac app, made for the Samsung Galaxy S23 (works on any arm64 phone running Android 10 or newer).

Paste a YouTube video or playlist link (or tap **Share → YT Downloader** in the YouTube app), tick the videos you want, pick **Video (MP4)** or **Audio (MP3)**, and tap **Download**. Downloads run one at a time with live progress, keep going when the screen is off, and land in your phone's normal folders:

| Save to | Videos | MP3s |
| --- | --- | --- |
| Movies / Music (default) | `Movies/YT Downloader` | `Music/YT Downloader` |
| Download | `Download/YT Downloader` | `Download/YT Downloader` |

They show up in Samsung Gallery, Samsung Music, My Files and any other player. Playlists can go into their own subfolder, with files numbered `001 - `, `002 - `…

> **Please use responsibly.** Downloading from YouTube can break YouTube's Terms of Service. Only download content you own, content licensed for download (e.g. Creative Commons), or content you otherwise have permission to save.

## How it works

Like the Mac app, this is a front end for **yt-dlp** and **ffmpeg**. On Android they come from the [youtubedl-android](https://github.com/yausername/youtubedl-android) library, which bundles Python, yt-dlp, ffmpeg and a small JavaScript engine (QuickJS, which recent yt-dlp needs for YouTube) inside the app. Nothing else needs to be installed on the phone.

YouTube changes things often. When downloads start failing, open the **⋮** menu and tap **Update yt-dlp**. That downloads the newest yt-dlp straight onto the phone, no rebuild needed.

---

## 1. Build the APK on your Mac

You only need **Android Studio**. It brings its own Java and Android SDK, so there is no Xcode or Homebrew involved.

1. Download Android Studio from <https://developer.android.com/studio> (pick *Mac with Apple chip* or *Mac with Intel chip*), drag it into Applications and open it.
2. Click through the setup wizard with the **Standard** options. It downloads the Android SDK (a few GB, takes a while once).
3. Choose **Open** and select the `YTDownloaderAndroid` folder (the one with `settings.gradle.kts` in it).
4. Wait for the **Gradle sync** at the bottom of the window to finish. The first sync downloads the build tools and libraries; give it a few minutes.
   - If Android Studio offers to upgrade the "Android Gradle Plugin", you can say yes or ignore it. Both work.
   - If it says an SDK platform is missing, click the blue **Install** link in the message.
5. Build the APK: menu **Build → Build App Bundle(s) / APK(s) → Build APK(s)**. When it finishes, click **locate** in the popup. The file is:

   ```
   YTDownloaderAndroid/app/build/outputs/apk/debug/app-debug.apk
   ```

   It's about 60–70 MB because Python and ffmpeg are inside.

### Or from Terminal

Once Android Studio has been set up once (steps 1–2 above), you can build without opening it:

```bash
cd path/to/YTDownloaderAndroid
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties
chmod +x gradlew
./gradlew assembleDebug
```

The APK appears at `app/build/outputs/apk/debug/app-debug.apk`.

## 2. Install it on the Galaxy S23

Pick one of the two ways.

### Option A: USB cable (easiest if Android Studio is open)

1. On the phone, turn on Developer options: **Settings → About phone → Software information**, then tap **Build number** 7 times and enter your PIN.
2. Go to **Settings → Developer options** and turn on **USB debugging**.
3. **Samsung Auto Blocker** blocks USB installs. If it's on, turn it off for now: **Settings → Security and privacy → Auto Blocker**. You can turn it back on after installing.
4. Plug the phone into the Mac and tap **Allow** on the "Allow USB debugging?" prompt (tick *Always allow from this computer*).
5. In Android Studio, pick your phone (e.g. *Samsung SM-S911B*) in the device menu at the top and press the green **▶ Run** button. The app installs and opens.

   From Terminal instead: `~/Library/Android/sdk/platform-tools/adb install -r app/build/outputs/apk/debug/app-debug.apk`

### Option B: copy the APK to the phone (no developer mode)

1. Get `app-debug.apk` onto the phone: upload it to Google Drive and open it there on the phone, email it to yourself, or connect by cable and copy it into the phone's *Download* folder.
2. If **Auto Blocker** is on (**Settings → Security and privacy → Auto Blocker**), turn it off; it blocks apps from outside the Play Store and Galaxy Store.
3. On the phone, open **My Files → Downloads** (or Drive) and tap the APK.
4. Android asks to allow installs from that app (My Files, Drive or Chrome). Tap **Settings**, turn on **Allow from this source**, go back and tap **Install**.
5. Google Play Protect may warn that the app is unknown. Tap **More details → Install anyway**. That's expected for any app you build yourself.

To update later, build again and install the new APK the same way. Your settings are kept.

## 3. Using the app

- **First launch** shows "Setting up yt-dlp…" for a few seconds while it unpacks Python and ffmpeg.
- **Allow notifications** when asked. Progress then shows in the notification shade with a **Cancel all** button, and you get a "Downloads finished" notification at the end. Downloads keep running if you switch apps or turn the screen off.
- **From the YouTube app:** tap **Share** under a video or playlist and choose **YT Downloader**. The link is filled in and read automatically.
- **Paste & fetch** reads the link on your clipboard.
- For playlists, use **All / None** and the checkboxes to choose videos. Private and deleted videos are greyed out and skipped.
- Each download can be cancelled, retried, removed from the list, or opened with **Open** when finished.

| Option | What it does |
| --- | --- |
| Video (MP4) / Audio (MP3) | What to save. |
| Max quality | Highest video resolution to grab (falls back to the best below it). |
| Prefer H.264 | On by default so files play in every app and on TVs. Turn off to allow VP9/AV1, which YouTube uses for most 1440p/4K streams (the S23 plays those fine). |
| MP3 bitrate | 128 to 320 kbps. Cover art and title/artist tags are embedded. |
| Put playlist in its own folder | Saves a playlist into a subfolder named after it. |
| Number files by playlist order | Prefixes files with `001 - `, `002 - `… |
| Save to | Movies/Music or the Download folder (see the table at the top). |

## Troubleshooting

- **"Sign in to confirm you're not a bot", "format not available", or downloads suddenly fail:** tap **⋮ → Update yt-dlp** and try again. Switching from mobile data to Wi‑Fi (or the other way) can also help with the bot check.
- **Gradle sync fails with "SDK location not found":** open the project from Android Studio (it fixes this itself), or create `local.properties` with `sdk.dir=/Users/YOUR_NAME/Library/Android/sdk`.
- **"Unsupported class file major version" or other Java errors in Terminal:** run the `export JAVA_HOME=…` line from the Terminal section so Gradle uses Android Studio's Java.
- **"App not installed" / "package conflicts with an existing package":** uninstall the old YT Downloader first (long‑press the icon → Uninstall), then install again.
- **Phone doesn't appear in Android Studio:** use a data cable (not a charge-only one), unlock the phone, check the USB debugging prompt, and make sure Auto Blocker is off.
- **Downloads stop when the phone is idle for a long time:** **Settings → Apps → YT Downloader → Battery → Unrestricted**.

## Project layout

```
settings.gradle.kts, build.gradle.kts   Gradle project (Android Gradle Plugin 8.7, Kotlin 2.0)
gradlew, gradle/wrapper/                Gradle wrapper (downloads Gradle 8.11.1 on first build)
app/build.gradle.kts                    App settings: arm64 only, Android 10+, libraries
app/src/main/AndroidManifest.xml        Permissions, Share target, download service
app/src/main/java/com/ytdownloader/
  App.kt                 Starts yt-dlp setup and the queue when the app launches
  Engine.kt              Unpacks yt-dlp/Python/ffmpeg, updates yt-dlp
  YtDlp.kt               Reads link info, builds yt-dlp commands (same options as the Mac app)
  DownloadQueue.kt       Download queue, runs one job at a time, parses progress
  DownloadService.kt     Foreground service + progress notification
  MediaStoreSaver.kt     Copies finished files into Movies / Music / Download
  MainViewModel.kt       Screen state and saved options
  MainActivity.kt        Entry point, handles links shared from other apps
  Models.kt              Small data types and helpers
  ui/MainScreen.kt       The screen (Jetpack Compose, Material 3)
  ui/Theme.kt            Uses your phone's Material You colours
```
