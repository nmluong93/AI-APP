#!/usr/bin/env bash
# Runs inside the CI emulator: serves the YouTube-like test page, opens the
# render-test build of the app on it, screenshots it and checks the video
# shows. Exits non-zero (failing the build) if it doesn't.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 -m http.server 8000 --directory "$here/../page_script_test" </dev/null >/dev/null 2>&1 &
server=$!
# The server must not outlive the script, or the CI step never finishes.
trap 'kill $server 2>/dev/null' EXIT
adb reverse tcp:8000 tcp:8000
adb install -r "$here/../../build/app/outputs/flutter-apk/app-release.apk"
adb logcat -c
adb shell am start -n com.luong.adfree_tube/.MainActivity
sleep 40
adb exec-out screencap -p > "$here/shot.png"
python3 "$here/measure.py" "$here/shot.png" > "$here/result.txt"
status=$?
adb logcat -d | grep -E "chromium|cr_|flutter" | tail -60
adb logcat -d | grep "RENDER_TEST" >> "$here/result.txt"
# Print the results last (and as annotations) so they're easy to find.
echo "---- results ----"
cat "$here/result.txt"
while read -r line; do echo "::notice::$line"; done < "$here/result.txt"
exit $status
