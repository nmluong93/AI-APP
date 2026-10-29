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
python3 measure.py shot.png > result.txt
adb logcat -d | grep -E "RENDER_TEST|chromium|cr_|Impeller|flutter" | tail -60
adb logcat -d | grep "RENDER_TEST" >> result.txt
# Print the results last (and as annotations) so they're easy to find.
echo "---- results ----"
cat result.txt
while read -r line; do echo "::notice::$line"; done < result.txt
