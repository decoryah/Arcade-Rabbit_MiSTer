#!/usr/bin/env python3
"""crop.py <in.png|ppm> <out.png> x0 y0 w h scale: a magnified piece of a picture (to look at differences)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio
p = sys.argv[1]
if p.endswith('.ppm'):
    d = open(p, 'rb').read(); parts = d.split(b'\n', 3); w, h = map(int, parts[1].split()); px = parts[3]
else:
    w, h, px = pngio.read(p)
x0, y0, cw, ch, s = map(int, sys.argv[3:8])
out = bytearray()
for y in range(y0, y0 + ch):
    row = bytearray()
    for x in range(x0, x0 + cw):
        i = (y * w + x) * 3
        row += bytes(px[i:i + 3]) * s
    out += row * s
pngio.write(sys.argv[2], cw * s, ch * s, out)
