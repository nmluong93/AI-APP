#!/usr/bin/env bash
# Runs on the CI Mac. Usage: run_macos.sh <name> <url> <canvas true|false>
# Starts the render-test build of the app on <url> (the YouTube-like test
# page or a real YouTube video), lets it play and seek (`_seekTest` in
# lib/main.dart), takes a screenshot while it plays, and checks the logged
# positions with seek_check.py. Exits non-zero if seeking or playback fails.
set -u
name=$1 url=$2 canvas=$3
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out/$name"
mkdir -p "$out"
app="$here/../../build/macos/Build/Products/Release/AdFree Tube.app/Contents/MacOS/AdFree Tube"
python3 -m http.server 8000 --bind 127.0.0.1 --directory "$here/../page_script_test" </dev/null >/dev/null 2>&1 &
server=$!
trap 'kill $server ${pid:-} 2>/dev/null' EXIT
sleep 1

rm -f "$out/render_test.log"
PLAYER_TEST_URL="$url" PLAYER_CANVAS="$canvas" RENDER_TEST_LOG="$out/render_test.log" \
  "$app" >"$out/app.log" 2>&1 &
pid=$!
sleep 3
osascript -e 'tell application "AdFree Tube" to activate' 2>/dev/null

# Screenshot once the video is playing; then wait for the app to finish
# (it quits by itself after the last seek).
shot=0
for _ in $(seq 1 150); do
  if [ $shot -eq 0 ] && grep -q "PHASE play" "$out/render_test.log" 2>/dev/null; then
    sleep 4
    screencapture -x "$out/shot.png" && shot=1
  fi
  kill -0 $pid 2>/dev/null || break
  sleep 1
done
kill $pid 2>/dev/null

echo "---- app output ----"
tail -40 "$out/app.log"
echo "---- readings ----"
cat "$out/render_test.log"
echo "---- results ($name) ----"
# The screenshot is for information: CI Macs don't always let an app's
# window be captured.
[ -f "$out/shot.png" ] && python3 "$here/measure.py" "$out/shot.png" | tee "$out/result.txt"
python3 "$here/seek_check.py" "$out/render_test.log" | tee -a "$out/result.txt"
ok=${PIPESTATUS[0]}
while read -r line; do echo "::notice::$name: $line"; done < <(grep -E "verdict|PHASE_RESULT" "$out/result.txt")
exit "$ok"
