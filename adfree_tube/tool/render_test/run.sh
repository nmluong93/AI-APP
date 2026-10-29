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
# A fresh emulator sometimes puts a system dialog (e.g. "Google isn't
# responding") over the app, so close system dialogs, check the app is in
# front, and try a second time before calling it a failure.
for attempt in 1 2; do
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null
  adb shell am start -n com.luong.adfree_tube/.MainActivity
  sleep 40
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null
  sleep 2
  echo "attempt $attempt, focused window: $(adb shell dumpsys window | grep -m1 mCurrentFocus)"
  adb exec-out screencap -p > "$here/shot.png"
  python3 "$here/measure.py" "$here/shot.png" > "$here/result.txt"
  status=$?
  [ $status -eq 0 ] && break
  cat "$here/result.txt"
  adb shell am force-stop com.luong.adfree_tube
done
adb logcat -d | grep -E "chromium|cr_|flutter" | tail -60
adb logcat -d | grep "RENDER_TEST" >> "$here/result.txt"
# Print the results last (and as annotations) so they're easy to find.
echo "---- results ----"
cat "$here/result.txt"
while read -r line; do echo "::notice::$line"; done < "$here/result.txt"
exit $status
