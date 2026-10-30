"""Checks the readings the macOS render test (`_seekTest` in lib/main.dart)
logs: the video plays, and after each seek it lands where it was sent and
plays on from there instead of loading forever (bug 20).
Input: the RENDER_TEST log the app writes. Exits 1 if any phase fails."""
import re
import sys

phases = []   # (name, target or None, start time)
samples = []  # (time, position or None, line)
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = re.match(r"\s*(\d+\.\d+) RENDER_TEST (.*)", line)
    if not m:
        continue
    t, rest = float(m.group(1)), m.group(2)
    p = re.match(r"PHASE (\w+)(?: target=(\d+))?", rest)
    if p:
        phases.append((p.group(1), int(p.group(2)) if p.group(2) else None, t))
        continue
    if rest.startswith("pos "):
        pos = re.search(r"\bt=([\d.]+)", rest)
        samples.append((t, float(pos.group(1)) if pos else None, rest))

# A seek must land within this many seconds, and the video must then play
# at least this fast for the rest of the phase.
LAND_WITHIN = 6
MIN_RATE = 0.6
failed = not any(name == "end" for name, _, _ in phases)
if failed:
    print("PHASE_RESULT run: FAIL, the test didn't finish (no PHASE end)")
for i, (name, target, start) in enumerate(phases):
    if name == "end":
        break
    end = phases[i + 1][2] if i + 1 < len(phases) else float("inf")
    window = [s for s in samples if start < s[0] <= end and s[1] is not None]
    if target is not None:
        landed = [s for s in window
                  if s[0] <= start + LAND_WITHIN and target - 1 <= s[1] <= target + LAND_WITHIN]
        if not landed:
            last = window[-1][2] if window else "no readings"
            print(f"PHASE_RESULT {name}: FAIL, never reached {target}s within "
                  f"{LAND_WITHIN}s (last: {last})")
            failed = True
            continue
        window = [s for s in window if s[0] >= landed[0][0]]
    else:
        window = [s for s in window if s[0] >= start + 2]
    if len(window) < 3:
        print(f"PHASE_RESULT {name}: FAIL, only {len(window)} readings")
        failed = True
        continue
    wall = window[-1][0] - window[0][0]
    media = window[-1][1] - window[0][1]
    rate = media / wall if wall > 0 else 0
    ok = rate >= MIN_RATE
    failed |= not ok
    where = f"landed at {window[0][1]:.1f}s, " if target is not None else ""
    print(f"PHASE_RESULT {name}: {'PASS' if ok else 'FAIL'}, {where}played "
          f"{media:.1f}s in {wall:.1f}s ({rate:.0%} of real time); last: {window[-1][2]}")
print("RENDER_TEST verdict: seeking " + ("FAILED" if failed else "OK"))
sys.exit(1 if failed else 0)
