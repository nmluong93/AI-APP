"""Checks a soak test run (run.sh) from what it saved in its output folder:
the video positions the app logged every second, split into the phases
run.sh marked, plus screenshots, memory, crashes and the app's process id.

  play:<name>   must play at >= 75% of real time with no stall over 6 s;
                play:resumed_* must also start moving within 5 s
  pause:<name>  must stay paused (moves less than 1 s)
  gap:<name>    not checked

Writes results.txt, metrics.json and summary.md (also added to the GitHub
job summary), and exits 1 if anything failed.
Usage: check.py <output folder>"""
import json
import os
import re
import sys

out = sys.argv[1]
MIN_RATIO = 0.75
MAX_STALL = 6
MAX_RESUME = 5
MAX_GAP = 8  # seconds without any reading: the app was frozen or killed
DROP_WARN = 0.10


def read(name):
    path = os.path.join(out, name)
    if not os.path.exists(path):
        return []
    return open(path, encoding="utf-8", errors="replace").read().splitlines()


def num(text, key):
    m = re.search(rf"\b{key}=([\d.]+)", text)
    return float(m.group(1)) if m else None


phases = []   # (name, start time)
samples = []  # dicts: time, pos, paused, dur, frames, dropped
for line in read("positions.txt"):
    m = re.match(r"\s*(\d+\.\d+)", line)
    if not m:
        continue
    t = float(m.group(1))
    p = re.search(r"PHASE (\S+)", line)
    if p:
        phases.append((p.group(1), t))
        continue
    s = re.search(r"RENDER_TEST pos (.*)", line)
    if s:
        body = s.group(1)
        samples.append({
            "time": t,
            "pos": num(body, "t"),
            "paused": "paused=true" in body,
            "dur": num(body, "d"),
            "frames": num(body, "frames"),
            "dropped": num(body, "dropped"),
        })
phases.sort(key=lambda x: x[1])


def advance(a, b):
    """Media seconds played from sample a to b, across the test video's loop."""
    d = b["pos"] - a["pos"]
    if d < -1 and b["dur"]:
        d += b["dur"]
    return d


failures, warnings, results, metrics = [], [], [], {"phases": []}


def fail(msg):
    failures.append(msg)
    results.append("FAIL " + msg)


for i, (name, start) in enumerate(phases):
    if name == "end" or name.startswith("gap:"):
        continue
    kind, _, label = name.partition(":")
    end = phases[i + 1][1] if i + 1 < len(phases) else samples[-1]["time"] if samples else start
    window = [s for s in samples if start <= s["time"] <= end]
    known = [s for s in window if s["pos"] is not None]
    m = {"phase": name, "seconds": round(end - start, 1), "readings": len(known)}
    metrics["phases"].append(m)
    if len(known) < 2:
        fail(f"{name}: no position readings ({len(window)} samples)")
        continue
    times = [start] + [s["time"] for s in window] + [end]
    gap = max(b - a for a, b in zip(times, times[1:]))
    m["longest_gap_s"] = round(gap, 1)
    if gap > MAX_GAP:
        fail(f"{name}: no readings for {gap:.0f}s (app frozen or killed)")
    frames = [s for s in known if s["frames"] is not None]
    if len(frames) >= 2:
        total = frames[-1]["frames"] - frames[0]["frames"]
        dropped = frames[-1]["dropped"] - frames[0]["dropped"]
        if total > 0:
            m["dropped_frames_pct"] = round(100 * dropped / total, 1)
            if dropped / total > DROP_WARN and kind == "play":
                warnings.append(f"{name}: dropped {dropped:.0f} of {total:.0f} frames")

    if kind == "pause":
        settled = [s for s in known if s["time"] >= start + 3]
        moved = sum(max(advance(a, b), 0) for a, b in zip(settled, settled[1:]))
        m["moved_s"] = round(moved, 1)
        # The position is what the user sees; the paused flag can read false
        # for a moment while the page settles, so only the last reading counts.
        ok = moved < 1 and bool(settled) and settled[-1]["paused"]
        if not ok:
            fail(f"{name}: should stay paused but moved {moved:.1f}s")
        else:
            results.append(f"PASS {name}: stayed paused")
        continue

    # play
    if label.startswith("resumed"):
        moving = next((b for a, b in zip(known, known[1:]) if advance(a, b) > 0.3), None)
        if moving is None:
            fail(f"{name}: never started playing again")
            continue
        latency = moving["time"] - start
        m["resume_latency_s"] = round(latency, 1)
        if latency > MAX_RESUME:
            fail(f"{name}: took {latency:.1f}s to start playing again")
        settled = [s for s in known if s["time"] >= moving["time"]]
    else:
        settled = [s for s in known if s["time"] >= start + 3]
    if len(settled) < 2:
        fail(f"{name}: too few readings to check")
        continue
    wall = settled[-1]["time"] - settled[0]["time"]
    media = sum(advance(a, b) for a, b in zip(settled, settled[1:]))
    ratio = media / wall if wall > 0 else 0
    stall, since = 0.0, settled[0]["time"]
    for a, b in zip(settled, settled[1:]):
        if advance(a, b) > 0.2:
            since = b["time"]
        stall = max(stall, b["time"] - since)
    m.update(ratio=round(ratio, 3), longest_stall_s=round(stall, 1))
    detail = f"played {media:.0f}s in {wall:.0f}s ({ratio:.0%} of real time), longest stall {stall:.1f}s"
    if "resume_latency_s" in m:
        detail += f", resumed in {m['resume_latency_s']}s"
    if ratio < MIN_RATIO or stall > MAX_STALL:
        fail(f"{name}: {detail}")
    else:
        results.append(f"PASS {name}: {detail}")

for line in read("shots.txt"):
    if ": FAIL" in line:
        fail(line)
    elif line.strip():
        results.append(line)

process = " ".join(read("process.txt"))
pids = dict(re.findall(r"(pid_\w+)=(\S*)", process))
if not pids.get("pid_start") or pids.get("pid_start") != pids.get("pid_end"):
    fail(f"app process changed or died during the run ({process.strip()})")
crashes = [line for line in read("crash.log") if line.strip() and not line.startswith("---")]
if crashes:
    fail(f"crash log is not empty: {crashes[0][:200]}")
for line in read("problems.log")[:5]:
    fail("system log: " + line[:200])

mem = []
for line in read("memory.txt"):
    v = re.search(r"app=(\d+) webview=(\d+)", line)
    if v:
        mem.append(int(v.group(1)) + int(v.group(2)))
if mem:
    metrics["memory_kb"] = {"first": mem[0], "last": mem[-1], "max": max(mem)}
    growth = mem[-1] - mem[0]
    if mem[0] and growth > 100_000 and growth / mem[0] > 0.5:
        warnings.append(f"memory grew from {mem[0] // 1024} MB to {mem[-1] // 1024} MB")

metrics["failures"] = failures
metrics["warnings"] = warnings
verdict = "FAILED" if failures else "OK"
lines = results + ["WARN " + w for w in warnings] + [f"SOAK_TEST verdict: {verdict}"]
open(os.path.join(out, "results.txt"), "w").write("\n".join(lines) + "\n")
json.dump(metrics, open(os.path.join(out, "metrics.json"), "w"), indent=2)

md = [f"## Soak test: {verdict}", "",
      "| Phase | Result | Played | Longest stall | Resume | Dropped frames |",
      "|---|---|---|---|---|---|"]
failed_phases = {f.split(": ")[0] for f in failures}
for m in metrics["phases"]:
    res = "❌" if m["phase"] in failed_phases else "✅"
    md.append("| {} | {} | {} | {} | {} | {} |".format(
        m["phase"], res,
        f"{m['ratio']:.0%}" if "ratio" in m else ("moved %ss" % m["moved_s"] if "moved_s" in m else "-"),
        f"{m['longest_stall_s']}s" if "longest_stall_s" in m else "-",
        f"{m['resume_latency_s']}s" if "resume_latency_s" in m else "-",
        f"{m['dropped_frames_pct']}%" if "dropped_frames_pct" in m else "-"))
if mem:
    md += ["", f"Memory (app + WebView): {mem[0] // 1024} MB at start, "
           f"{mem[-1] // 1024} MB at the end, {max(mem) // 1024} MB peak."]
for title, items in (("Failures", failures), ("Warnings", warnings)):
    if items:
        md += ["", f"**{title}**", ""] + [f"- {x}" for x in items]
summary = "\n".join(md) + "\n"
open(os.path.join(out, "summary.md"), "w").write(summary)
if os.environ.get("GITHUB_STEP_SUMMARY"):
    open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(summary)

print("\n".join(lines))
for f in failures:
    print(f"::error::{f}")
for w in warnings:
    print(f"::warning::{w}")
sys.exit(1 if failures else 0)
