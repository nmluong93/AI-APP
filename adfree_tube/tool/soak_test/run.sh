#!/usr/bin/env bash
# Runs inside the CI emulator (.github/workflows/adfree_tube_soak.yml).
# Opens the render-test build of the app on the YouTube-like test page and
# does what a user does over a longer session: pauses and resumes from the
# headset/notification controls, locks and unlocks the phone, switches to
# other apps (Settings, Home, Recents) and back as from the launcher, and lets it play for a long time. check.py then
# checks the positions the app logs every second.
#
# Usage: run.sh [scenario ...]   (default: all of them)
#   pause_resume  lock_unlock  app_switch  long
# SOAK_MINUTES sets how long the long scenario plays (default 10).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
pkg=com.luong.adfree_tube
out="$here/out"
rm -rf "$out" && mkdir -p "$out/shots"
scenarios=("$@")
[ ${#scenarios[@]} -eq 0 ] && scenarios=(pause_resume lock_unlock app_switch long)
minutes=${SOAK_MINUTES:-10}

python3 -m http.server 8000 --directory "$here/../page_script_test" </dev/null >/dev/null 2>&1 &
server=$!
trap 'kill $server ${logger:-} 2>/dev/null' EXIT
adb reverse tcp:8000 tcp:8000
adb install -r "$here/../../build/app/outputs/flutter-apk/app-release.apk"
adb shell pm grant $pkg android.permission.POST_NOTIFICATIONS 2>/dev/null
# Keep the screen from timing out on its own; the scenarios turn it off.
adb shell settings put system screen_off_timeout 2147483647

# Phase names tell check.py what to expect:
#   play:<name>   the video should play at about real time
#   pause:<name>  the video should stay where it is
#   gap:<name>    don't check (things are changing over)
mark() { adb shell log -t RENDER_TEST "PHASE $1"; echo "phase: $1"; }
# Screenshot that must show the green video (not a black frame).
shot() {
  sleep "${2:-3}"
  adb exec-out screencap -p > "$out/shots/$1.png"
  if python3 "$here/../render_test/measure.py" "$out/shots/$1.png" > "$out/shots/$1.txt"; then
    echo "SHOT $1: PASS, video visible" | tee -a "$out/shots.txt"
  else
    echo "SHOT $1: FAIL, video not visible ($(head -1 "$out/shots/$1.txt"))" | tee -a "$out/shots.txt"
  fi
}
app_pid() { adb shell pidof $pkg | tr -d '\r'; }
# Memory of the app and its WebView renderer, in KB.
memory() {
  local app web
  app=$(adb shell dumpsys meminfo $pkg | awk '/TOTAL PSS:/ {print $3; exit} /^ *TOTAL / {print $2; exit}')
  web=0
  for p in $(adb shell pgrep -f sandboxed_process | tr -d '\r'); do
    web=$((web + $(adb shell dumpsys meminfo "$p" | awk '/TOTAL PSS:/ {print $3; exit} /^ *TOTAL / {print $2; exit}' || echo 0)))
  done
  echo "MEMORY $(date +%s) app=${app:-0} webview=$web" | tee -a "$out/memory.txt"
}
foreground() { adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; }

pause_resume() {
  for d in 10 60 300; do
    mark "play:before_pause_$d"; sleep 15
    adb shell input keyevent KEYCODE_MEDIA_PAUSE
    mark "pause:paused_${d}s"; sleep "$d"
    adb shell input keyevent KEYCODE_MEDIA_PLAY
    mark "play:resumed_after_${d}s"; sleep 20
  done
  # Pause and resume from the background with the screen off, as from a
  # headset while the phone is in a pocket.
  adb shell input keyevent KEYCODE_SLEEP
  mark "play:locked_before_pause"; sleep 20
  adb shell input keyevent KEYCODE_MEDIA_PAUSE
  mark "pause:paused_while_locked"; sleep 60
  adb shell input keyevent KEYCODE_MEDIA_PLAY
  mark "play:resumed_while_locked"; sleep 30
  adb shell input keyevent KEYCODE_WAKEUP
  adb shell wm dismiss-keyguard
  mark "play:unlocked_after_pause"; shot unlocked_after_pause; sleep 15
}

lock_unlock() {
  for d in 60 300; do
    mark "play:before_lock_$d"; sleep 15
    adb shell input keyevent KEYCODE_SLEEP
    mark "play:locked_${d}s"; sleep "$d"
    adb shell input keyevent KEYCODE_WAKEUP
    adb shell wm dismiss-keyguard
    mark "play:unlocked_after_${d}s"; shot "unlocked_after_${d}s"; sleep 20
  done
}

app_switch() {
  for i in $(seq 1 8); do
    case $((i % 4)) in
      1) adb shell am start -a android.settings.SETTINGS >/dev/null ;;
      2) adb shell input keyevent KEYCODE_HOME ;;
      3) adb shell input keyevent KEYCODE_APP_SWITCH ;;
      0) adb shell am start -a android.settings.DISPLAY_SETTINGS >/dev/null ;;
    esac
    mark "play:away_$i"; sleep 20
    foreground
    mark "play:back_$i"; shot "back_$i"; sleep 10
  done
}

long() {
  mark "play:long_${minutes}min"
  for _ in $(seq 1 "$minutes"); do
    memory
    sleep 60
  done
  memory
  shot long_end 0
}

adb logcat -c
adb logcat -b crash -c
adb logcat -v epoch > "$out/full.log" 2>/dev/null &
logger=$!
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null
adb shell am start -n $pkg/.MainActivity
mark "gap:start"
# The app leaves the player screen at ~20 s and comes back at ~40 s on its
# own (see _renderTest in main.dart); start once that is over.
sleep 50
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null
shot start 0
pid_start=$(app_pid)
echo "app pid at start: $pid_start"
memory

for s in "${scenarios[@]}"; do
  echo "==== scenario $s ===="
  "$s"
  memory
done
mark end
pid_end=$(app_pid)
echo "PROCESS pid_start=$pid_start pid_end=$pid_end" | tee "$out/process.txt"

kill $logger 2>/dev/null
adb logcat -d -b crash > "$out/crash.log"
grep -E "ANR in $pkg|FATAL EXCEPTION|Process $pkg .*(died|has died)|lowmemorykiller.*$pkg" "$out/full.log" > "$out/problems.log"
grep "RENDER_TEST" "$out/full.log" > "$out/positions.txt"
grep -E "MEDIA_STATE|flutter|$pkg|Exception" "$out/full.log" | grep -v RENDER_TEST | tail -200 > "$out/app.log"
python3 "$here/check.py" "$out"
