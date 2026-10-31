#!/usr/bin/env bash
# Runs on the CI Mac (soak-macos in .github/workflows/adfree_tube_soak.yml).
# The macOS counterpart of run.sh: opens the render-test build of the app on
# the YouTube-like test page and does what a Mac user does over a longer
# session, then check.py checks the positions the app wrote
# (_macSoakTest in lib/main.dart).
#
# Usage: run_macos.sh [scenario ...]   (default: all of them)
#   pause_resume  pause and resume from the system media controls (as the
#                 keyboard's media keys, AirPods or Control Center do), also
#                 with the app hidden and with the display off
#   lock_unlock   the display off for 1 and 5 minutes while it plays
#   app_switch    other apps in front, or the app hidden, and back, 8 times
#   long          plays for SOAK_MINUTES minutes (default 10)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
name="AdFree Tube"
app="$here/../../build/macos/Build/Products/Release/$name.app/Contents/MacOS/$name"
out="$here/out"
rm -rf "$out" && mkdir -p "$out/shots"
scenarios=("$@")
[ ${#scenarios[@]} -eq 0 ] && scenarios=(pause_resume lock_unlock app_switch long)
minutes=${SOAK_MINUTES:-10}
log="$out/positions.txt"
commands="$out/commands.txt"
started=$(date +%s)

python3 -m http.server 8000 --bind 127.0.0.1 --directory "$here/../page_script_test" </dev/null >/dev/null 2>&1 &
server=$!
trap 'kill $server ${pid:-} 2>/dev/null' EXIT
mediactl="${RUNNER_TEMP:-/tmp}/mediactl"
swiftc -O -o "$mediactl" "$here/mediactl.swift" || echo "mediactl did not build: media commands go through the test hook"

now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
# Phase names, as in run.sh: play:<name>, pause:<name>, gap:<name>.
mark() { echo "$(now) RENDER_TEST PHASE $1" >> "$log"; echo "phase: $1"; }
# Screenshots are for information only: CI Macs don't always let a script
# capture another app's window.
shot() {
  sleep "${2:-3}"
  screencapture -x "$out/shots/$1.png" 2>/dev/null &&
    echo "SHOT $1: $(python3 "$here/../render_test/measure.py" "$out/shots/$1.png" | head -1)" | tee -a "$out/shots_info.txt"
}
# AppleScript, given 15 s at most: a permission prompt nobody can answer
# would otherwise hang the run.
osa() {
  osascript -e "$1" >>"$out/osascript.txt" 2>&1 &
  local p=$!
  ( sleep 15; kill $p 2>/dev/null ) &
  wait $p
}
foreground() { osa "tell application \"$name\" to activate"; }
hide_app() {
  osa "tell application \"System Events\" to set visible of process \"$name\" to false" ||
    { echo "could not hide the app; bringing Finder to the front instead"; osa 'tell application "Finder" to activate'; }
}
display_off() { pmset displaysleepnow; }
display_on() { caffeinate -u -t 2; }
media_states() { grep -c "MEDIA_STATE" "$out/app.log"; }
# A system media command. If the app's state doesn't change, the command
# didn't reach it, and the test hook sends it instead (the app then calls
# what its media handler would have); media.txt records which was used.
# The gap mark keeps the time this takes out of the phases either side.
media() {
  local before
  mark "gap:send_$1"
  before=$(media_states)
  [ -x "$mediactl" ] && "$mediactl" "$1"
  sleep 2
  if [ "$(media_states)" -gt "$before" ]; then
    echo "MEDIA $1: system media command" | tee -a "$out/media.txt"
  else
    echo "$1" >> "$commands"
    sleep 1
    echo "MEDIA $1: no effect, sent through the test hook" | tee -a "$out/media.txt"
  fi
}
rss() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' '; }
memory() {
  local web=0 p kb
  for p in $(pgrep -f com.apple.WebKit.WebContent); do
    kb=$(rss "$p"); web=$((web + ${kb:-0}))
  done
  kb=$(rss "$pid")
  echo "MEMORY $(date +%s) app=${kb:-0} webview=$web" | tee -a "$out/memory.txt"
}

pause_resume() {
  for d in 10 60 300; do
    mark "play:before_pause_$d"; sleep 15
    media pause
    mark "pause:paused_${d}s"; sleep "$d"
    media play
    mark "play:resumed_after_${d}s"; sleep 20
  done
  hide_app
  mark "play:hidden_before_pause"; sleep 15
  media pause
  mark "pause:paused_hidden"; sleep 30
  media play
  mark "play:resumed_hidden"; sleep 20
  foreground
  mark "play:back_after_hidden_pause"; sleep 10
  display_off
  mark "play:display_off_before_pause"; sleep 20
  media pause
  mark "pause:paused_display_off"; sleep 60
  media play
  mark "play:resumed_display_off"; sleep 30
  display_on; foreground
  mark "play:display_on_after_pause"; shot display_on_after_pause; sleep 15
}

lock_unlock() {
  for d in 60 300; do
    mark "play:before_display_off_$d"; sleep 15
    display_off
    mark "play:display_off_${d}s"; sleep "$d"
    display_on; foreground
    mark "play:display_on_after_${d}s"; shot "display_on_after_${d}s"; sleep 20
  done
}

app_switch() {
  for i in $(seq 1 8); do
    case $((i % 4)) in
      1) open -a "System Settings" ;;
      2) hide_app ;;
      3) open -a Calculator ;;
      0) osa 'tell application "Finder" to activate' ;;
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

PLAYER_TEST_URL=http://127.0.0.1:8000/youtube_like.html SOAK_TEST_LOG="$log" SOAK_TEST_CMD="$commands" \
  "$app" >"$out/app.log" 2>&1 &
pid=$!
mark "gap:start"
sleep 5
foreground
sleep 25
shot start 0
echo "app pid at start: $pid"
memory

for s in "${scenarios[@]}"; do
  echo "==== scenario $s ===="
  "$s"
  memory
done
mark end
pid_end=$(kill -0 "$pid" 2>/dev/null && echo "$pid")
echo "PROCESS pid_start=$pid pid_end=$pid_end" | tee "$out/process.txt"
kill "$pid" 2>/dev/null

# Crash reports macOS wrote for the app during the run.
: > "$out/crash.log"
for f in "$HOME"/Library/Logs/DiagnosticReports/*; do
  case "$f" in *"$name"*) [ "$(stat -f %m "$f")" -ge "$started" ] && cat "$f" >> "$out/crash.log" ;; esac
done
grep -E "Unhandled Exception|Fatal error" "$out/app.log" > "$out/problems.log"
echo "---- media commands ----"; cat "$out/media.txt" 2>/dev/null
echo "---- screenshots (information only) ----"; cat "$out/shots_info.txt" 2>/dev/null
echo "---- end of the app's output ----"; tail -30 "$out/app.log"
SOAK_PLATFORM=macOS python3 "$here/check.py" "$out"
