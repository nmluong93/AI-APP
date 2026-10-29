"""Measures how much of a screenshot is the test page's green video.
Exits 1 if the video isn't visible, which fails the CI job."""
import sys

from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
w, h = img.size
green = black = 0
for r, g, b in img.getdata():
    if r < 60 and g > 150 and b < 60:
        green += 1
    elif r < 20 and g < 20 and b < 20:
        black += 1
total = w * h
visible = green > total * 0.02
print(f"RENDER_TEST screen {w}x{h}: green video {100 * green / total:.1f}%, "
      f"black {100 * black / total:.1f}%")
print("RENDER_TEST verdict: video " + ("VISIBLE" if visible else "NOT visible"))
sys.exit(0 if visible else 1)
