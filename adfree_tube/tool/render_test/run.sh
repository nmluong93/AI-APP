#!/usr/bin/env bash
# Runs inside the CI emulator. Serves the YouTube-like test page, opens the
# render-test build of the app on it, and checks that:
#   1. the video shows (screenshot, measure.py), and
#   2. it keeps playing on the player, after leaving the player screen,
#      in the background (home button) and with the screen off
#      (positions logged by the app, background.py).
# Exits non-zero (failing the build) if anything doesn't hold.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 -m http.server 8000 --directory "$here/../page_script_test" </dev/null >/dev/null 2>&1 &
server=$!
# The server must not outlive the script, or the CI step never finishes.
trap 'kill $server 2>/dev/null' EXIT
adb reverse tcp:8000 tcp:8000
adb install -r "$here/../../build/app/outputs/flutter-apk/app-release.apk"
# Background audio needs the app's media notification; allow it up front.
adb shell pm grant com.luong.adfree_tube android.permission.POST_NOTIFICATIONS 2>/dev/null
mark() { adb shell log -t RENDER_TEST "PHASE $1"; echo "phase: $1"; }

# A fresh emulator sometimes puts a system dialog (e.g. "Google isn't
# responding") over the app, so close system dialogs, check the app is in
# front, and try a second time before calling it a failure.
for attempt in 1 2; do
  adb logcat -c
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null
  adb shell am start -n com.luong.adfree_tube/.MainActivity
  mark start
  sleep 14
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null
  echo "attempt $attempt, focused window: $(adb shell dumpsys window | grep -m1 mCurrentFocus)"
  adb exec-out screencap -p > "$here/shot.png"
  python3 "$here/measure.py" "$here/shot.png" > "$here/result.txt"
  render=$?
  [ $render -eq 0 ] && break
  cat "$here/result.txt"
  adb shell am force-stop com.luong.adfree_tube
done

# The app itself leaves the player screen at ~20 s and comes back at ~40 s.
sleep 36
mark home
adb shell input keyevent KEYCODE_HOME
sleep 30
mark screen_off
adb shell input keyevent KEYCODE_SLEEP
sleep 30
mark end
adb shell input keyevent KEYCODE_WAKEUP

adb logcat -d | grep -E "chromium|cr_|flutter|AudioService" | tail -60
adb logcat -d -v epoch | grep "RENDER_TEST" > "$here/positions.txt"
python3 "$here/background.py" "$here/positions.txt" >> "$here/result.txt"
background=$?
# Print the results last (and as annotations) so they're easy to find.
echo "---- positions ----"
cat "$here/positions.txt"
echo "---- results ----"
cat "$here/result.txt"
while read -r line; do echo "::notice::$line"; done < <(grep -E "verdict|PHASE_RESULT" "$here/result.txt")
[ $render -eq 0 ] && [ $background -eq 0 ]
