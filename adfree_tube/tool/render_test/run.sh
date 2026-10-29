#!/usr/bin/env bash
# Runs inside the CI emulator: serves the test page, opens the render-test
# build of the app, screenshots it and measures what shows up.
set -u
cd "$(dirname "$0")"
python3 -m http.server 8000 >/dev/null 2>&1 &
adb reverse tcp:8000 tcp:8000
adb install -r ../../build/app/outputs/flutter-apk/app-release.apk
adb logcat -c
adb shell am start -n com.luong.adfree_tube/.MainActivity
sleep 40
adb exec-out screencap -p > shot.png
python3 measure.py shot.png
adb logcat -d | grep -E "RENDER_TEST|chromium|cr_|Impeller|flutter" | tail -60
