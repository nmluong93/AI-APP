"""Checks from the app's logged video positions that playback kept going in
each phase of the render test: on the player, after leaving the player
screen, back on it, in the background, and with the screen off.
Input: `adb logcat -v epoch` lines containing RENDER_TEST.
Exits 1 if any phase played at less than 70% of real time, or if the
readings stop before the phase ends (the app was frozen or killed)."""
import re
import sys

phases = []   # (name, start time)
samples = []  # (time, media position or None, video duration or 0)
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"\s*(\d+\.\d+)", line)
    if not m:
        continue
    t = float(m.group(1))
    p = re.search(r"PHASE (\w+)", line)
    if p:
        phases.append((p.group(1), t))
        continue
    s = re.search(r"RENDER_TEST pos (.*)", line)
    if s:
        pos = re.search(r"t=([\d.]+)", s.group(1))
        dur = re.search(r"d=([\d.]+)", s.group(1))
        samples.append((t, float(pos.group(1)) if pos else None,
                        float(dur.group(1)) if dur else 0))

phases.sort(key=lambda x: x[1])
# The first window starts once the page has had time to load.
names = {"start": "on_player"}
# Readings come every 3 s; a longer gap at the end of a phase means the app
# stopped running.
MAX_GAP = 8
failed = False
for i, (name, start) in enumerate(phases):
    if name == "end":
        break
    end = phases[i + 1][1] if i + 1 < len(phases) else float("inf")
    # Skip the first few seconds of each phase while things change over.
    lo = start + (8 if name == "start" else 4)
    window = [s for s in samples if lo <= s[0] <= end]
    known = [s for s in window if s[1] is not None]
    label = names.get(name, name)
    if len(known) < 2:
        print(f"PHASE_RESULT {label}: FAIL, no position readings ({len(window)} samples)")
        failed = True
        continue
    wall = known[-1][0] - known[0][0]
    # The test video loops, so add up each step, counting a jump back to
    # the start as playing on through the end.
    media = 0.0
    for a, b in zip(known, known[1:]):
        step = b[1] - a[1]
        media += step + b[2] if step < -1 and b[2] else step
    ratio = media / wall if wall > 0 else 0
    silent = end - known[-1][0] if end != float("inf") else 0
    ok = ratio >= 0.7 and silent <= MAX_GAP
    failed |= not ok
    note = f", but no readings for the last {silent:.0f}s" if silent > MAX_GAP else ""
    print(f"PHASE_RESULT {label}: {'PASS' if ok else 'FAIL'}, video advanced "
          f"{media:.1f}s in {wall:.1f}s ({ratio:.0%} of real time, {len(known)} readings){note}")
print("RENDER_TEST verdict: background playback " + ("FAILED" if failed else "OK"))
sys.exit(1 if failed else 0)
