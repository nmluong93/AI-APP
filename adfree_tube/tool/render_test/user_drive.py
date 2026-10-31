"""Plays the part of a user in the macOS user test: moves the real mouse over
the video so the controls show, and clicks Play/Pause and the seek bar or
drags it, like a person would. Run by run_macos.sh once the video plays.

Usage: user_drive.py <render test log> <mouse binary>
The app (`_seekTest` in lib/main.dart, PLAYER_TEST_USER=1) logs where its
controls are; this writes the PHASE lines into the same log, and
seek_check.py then checks each phase: a pause holds still, and a seek lands
where the user clicked and plays on from there."""
import re
import subprocess
import sys
import time

log_path, mouse = sys.argv[1], sys.argv[2]


def lines():
    with open(log_path, encoding="utf-8", errors="replace") as f:
        return [l.split(" RENDER_TEST ", 1)[1].strip() for l in f if " RENDER_TEST " in l]


def last(prefix):
    for line in reversed(lines()):
        if line.startswith(prefix):
            return line
    sys.exit(f"user_drive: the app never logged '{prefix}'")


def phase(text):
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(f"{time.time():.2f} RENDER_TEST PHASE {text}\n")
    print("PHASE", text, flush=True)


def run(*args):
    out = subprocess.run([mouse, *map(str, args)], capture_output=True, text=True)
    if out.returncode:
        sys.exit(f"user_drive: mouse {args[0]} failed: {out.stderr or out.stdout}")
    return out.stdout


def rect(text, name):
    m = re.search(name + r"=([\d.,]+)", text)
    if not m:
        sys.exit(f"user_drive: no '{name}' on screen: {text}")
    return [float(v) for v in m.group(1).split(",")]


ui = last("ui ")
seek, play, view = rect(ui, "seek"), rect(ui, "play"), rect(ui, "view")
wx, wy, ww, wh = map(float, run("window", "AdFree Tube").split())
# The window's content (the Flutter view) sits below its title bar.
ox, oy = wx, wy + wh - view[1]
duration = float(re.search(r"\bd=(\d+)", last("pos ")).group(1))
print(f"window {wx},{wy} {ww}x{wh}, view {view}, seek bar {seek}, "
      f"play {play}, duration {duration}s", flush=True)


def screen(x, y):
    return ox + x, oy + y


def reveal():
    """Moves the mouse over the video, as a user does to bring back the
    controls, and waits for them to fade in."""
    x, y = screen(view[0] * 0.3, view[1] * 0.3)
    run("move", x, y)
    time.sleep(0.2)
    run("move", x + 15, y + 10)
    time.sleep(0.8)


# Material's seek bar keeps its track this far in from each end.
PAD = 24


def bar_x(fraction):
    return screen(seek[0] + PAD + (seek[2] - 2 * PAD) * fraction, seek[1] + seek[3] / 2)


def position():
    m = re.search(r"\bt=([\d.]+)", last("pos "))
    return float(m.group(1)) if m else 0.0


def click_play():
    reveal()
    run("click", *screen(play[0] + play[2] / 2, play[1] + play[3] / 2))


# Where a click on the bar lands is only known to within a few pixels.
tol = max(3, round(duration * 0.04))

click_play()
phase("paused_click")
time.sleep(6)

click_play()
phase("play_click")
time.sleep(8)

reveal()
target = round(duration / 3)
phase(f"seek_click target={target} tol={tol}")
run("click", *bar_x(1 / 3))
time.sleep(10)

reveal()
target = round(duration * 2 / 3)
phase(f"seek_drag target={target} tol={tol}")
run("drag", *bar_x(position() / duration), *bar_x(2 / 3))
time.sleep(10)

reveal()
target = round(duration / 6)
phase(f"seek_back_click target={target} tol={tol}")
run("click", *bar_x(1 / 6))
time.sleep(10)

# Pause, seek while paused, then play from there.
click_play()
time.sleep(1)
reveal()
target = round(duration / 2)
phase(f"paused_seek target={target} tol={tol}")
run("click", *bar_x(1 / 2))
time.sleep(6)
click_play()
phase(f"play_after_seek target={target} tol={tol + 8}")
time.sleep(10)

phase("end")
