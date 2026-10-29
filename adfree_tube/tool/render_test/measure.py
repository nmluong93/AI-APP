"""Prints how much of a screenshot is the test page's orange marker and
how much is its green video, so CI logs show what actually rendered."""
import sys

from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size
orange = green = black = 0
for r, g, b in img.getdata():
    if r > 220 and 100 < g < 180 and b < 60:
        orange += 1
    elif r < 60 and g > 150 and b < 60:
        green += 1
    elif r < 20 and g < 20 and b < 20:
        black += 1
total = w * h
print(f"RENDER_TEST screen {w}x{h}: orange marker {100 * orange / total:.1f}%, "
      f"green video {100 * green / total:.1f}%, black {100 * black / total:.1f}%")
print("RENDER_TEST verdict: webview " + ("VISIBLE" if orange > total * 0.005 else "NOT visible")
      + ", video " + ("VISIBLE" if green > total * 0.02 else "NOT visible"))
