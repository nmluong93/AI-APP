#!/usr/bin/env bash
# Runs inside the CI emulator. Serves sample.mp4, opens the download-test
# build of the app (lib/main.dart, _downloadTest), which downloads it as a
# video and as an MP3 with the app's own yt-dlp and ffmpeg, then checks the
# files saved in Movies/ and Music/ "AdFree Tube" are a playable MP4 (H.264
# and AAC) and an MP3.
# Exits non-zero (failing the build) if anything doesn't hold.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 -m http.server 8000 --directory "$here" </dev/null >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
adb reverse tcp:8000 tcp:8000
adb install -r "$here/../../build/app/outputs/flutter-apk/app-release.apk"
adb shell pm grant com.luong.adfree_tube android.permission.POST_NOTIFICATIONS 2>/dev/null
adb logcat -c
adb shell am start -n com.luong.adfree_tube/.MainActivity

# The first launch unpacks Python, yt-dlp and ffmpeg and updates yt-dlp,
# so allow several minutes.
for i in $(seq 1 60); do
  sleep 10
  done_count=$(adb logcat -d | grep -c "DOWNLOAD_TEST finished")
  echo "after $((i * 10)) s: $done_count of 2 finished"
  [ "$done_count" -ge 2 ] && break
done
adb logcat -d | grep -E "DOWNLOAD_TEST|youtubedl|AndroidRuntime" | tail -80
adb exec-out screencap -p > "$here/downloads.png"

fail=0
check() { # check <state line pattern>
  if adb logcat -d | grep "DOWNLOAD_TEST finished" | grep -q "$1"; then
    echo "::notice::PASS $1"
  else
    echo "::error::FAIL $1"; fail=1
  fi
}
check "kind=video state=done"
check "kind=audio state=done"

rm -rf "$here/pulled"; mkdir -p "$here/pulled"
adb pull "/sdcard/Movies/AdFree Tube" "$here/pulled/video"
adb pull "/sdcard/Music/AdFree Tube" "$here/pulled/audio"
ls -laR "$here/pulled"
probe() { ffprobe -v error -show_entries stream=codec_name -of csv=p=0 "$1" | sort | tr '\n' ' '; }
video=$(find "$here/pulled/video" -name '*.mp4' | head -1)
audio=$(find "$here/pulled/audio" -name '*.mp3' | head -1)
if [ -n "$video" ] && [ "$(probe "$video")" = "aac h264 " ]; then
  echo "::notice::PASS saved video $(basename "$video"): $(probe "$video")"
else
  echo "::error::FAIL saved video '${video}': ${video:+$(probe "$video")}"; fail=1
fi
if [ -n "$audio" ] && probe "$audio" | grep -qw mp3; then
  echo "::notice::PASS saved audio $(basename "$audio"): $(probe "$audio")"
else
  echo "::error::FAIL saved audio '${audio}': ${audio:+$(probe "$audio")}"; fail=1
fi
exit $fail
