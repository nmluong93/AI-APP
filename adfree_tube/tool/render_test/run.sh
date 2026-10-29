#!/usr/bin/env bash
# Runs inside the CI emulator. Serves the YouTube-like test page, opens the
# render-test build of the app on it, and checks that:
#   1. the video shows (screenshot, measure.py), and
#   2. it keeps playing on the player, after leaving the player screen,
#      in the background (home button), with the screen off, and after
#      the screen comes back on (positions logged by the app, background.py).
# Exits non-zero (failing the build) if anything doesn't hold.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
python3 -m http.server 8000 --directory "$here/../page_script_test" </dev/null >/dev/null 2>&1 &
server=$!
# The server must not outlive the script, or the CI step never finishes.
trap 'kill $server ${logger:-} 2>/dev/null' EXIT
adb reverse tcp:8000 tcp:8000
adb install -r "$here/../../build/app/outputs/flutter-apk/app-release.apk"
# Background audio needs the app's media notification; allow it up front.
adb shell pm grant com.luong.adfree_tube android.permission.POST_NOTIFICATIONS 2>/dev/null
adb logcat -c
# Keep the whole log in a file: the emulator's own buffer is small and other
# apps fill it.
adb logcat -v epoch > "$here/full.log" 2>/dev/null &
logger=$!
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

# What Android thinks of the app: alive, foreground service, priority
# (oom_score_adj: 0 = on screen, 200 = foreground service, 900+ = cached and
# about to be frozen or killed).
state() {
  echo "-- state ($1) --"
  adb shell dumpsys activity services com.luong.adfree_tube/com.ryanheise.audioservice.AudioService | grep -E "ServiceRecord|isForeground|foregroundId|startRequested|createdFromFg" | head -8
  adb shell dumpsys notification --noredact | grep -E "pkg=com.luong.adfree_tube" | head -3
  for p in $(adb shell pidof com.luong.adfree_tube) $(adb shell pgrep -f sandboxed_process); do
    echo "pid $p $(adb shell cat /proc/$p/cmdline | tr '\0' ' ' | cut -c1-60) adj=$(adb shell cat /proc/$p/oom_score_adj)"
  done
}

# The app itself leaves the player screen ~20 s after the page loads and
# comes back ~20 s later. How long the page takes to load varies, so wait
# for the app to say it's back rather than a fixed time, then give that
# phase 12 s of readings before going home.
for _ in $(seq 1 90); do
  adb logcat -d | grep -q "RENDER_TEST PHASE back_on_player" && break
  sleep 1
done
sleep 12
state player
mark home
adb shell input keyevent KEYCODE_HOME
sleep 15
state home
sleep 15
mark screen_off
adb shell input keyevent KEYCODE_SLEEP
sleep 30
state screen_off
sleep 30
mark awake
adb shell input keyevent KEYCODE_WAKEUP
sleep 12
state awake
mark end

kill $logger 2>/dev/null
grep -E "MEDIA_STATE|AudioService|ForegroundService|startForeground|flutter|adfree_tube|System.err|Exception" "$here/full.log" | grep -v RENDER_TEST | tail -120
# Crashes go to their own log buffer, which other apps' chatter can't push
# out of the way.
echo "---- crashes ----"
adb logcat -d -b crash | tail -60
echo "---- system log about the app ----"
adb logcat -d | grep -E "ActivityManager|AndroidRuntime|DEBUG|libc|Freezer|freez|adfree_tube|sandboxed_process|lowmemorykiller" | grep -v RENDER_TEST | tail -60
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
