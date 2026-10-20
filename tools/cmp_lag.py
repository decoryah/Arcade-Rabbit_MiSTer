#!/usr/bin/env python3
"""cmp_lag.py <bench prefix> <MAME dir> <frames...> [--window N]: for each of the bench's pictures <prefix>.f<frame>.ppm, the MAME snapshot
(<dir>/snap_<g>.png, g within frame +- N) it equals or comes closest to, and the core's lag behind MAME's timeline.

The bench writes the picture of frame f when vblank f begins: the picture the raster has just shown, which the core drew from its
snapshot of vblank f - 1. MAME's snapshot g is drawn at vblank g. So a core in step with MAME (the same state at the same vblank, as
tools/cmp_ram.py checks) shows MAME's g = f - 1: lag 0. A positive lag = the core is behind."""
import sys, os, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio

ap = argparse.ArgumentParser()
ap.add_argument('prefix'); ap.add_argument('dir'); ap.add_argument('frames', nargs='+', type=int)
ap.add_argument('--window', type=int, default=8)
a = ap.parse_args()


def ppm(p):
    d = open(p, 'rb').read(); parts = d.split(b'\n', 3); return bytes(parts[3])


cache = {}
def snap(g):
    if g not in cache:
        p = os.path.join(a.dir, f'snap_{g}.png')
        cache[g] = bytes(pngio.read(p)[2]) if os.path.exists(p) else None
    return cache[g]


def diff(x, y):
    return sum(1 for i in range(0, len(x), 3) if x[i:i + 3] != y[i:i + 3])


for f in a.frames:
    p = f'{a.prefix}.f{f}.ppm'
    if not os.path.exists(p):
        continue
    ours = ppm(p)
    best = None
    for g in range(f - a.window, f + a.window + 1):
        s = snap(g)
        if s is None: continue
        n = diff(ours, s) if s != ours else 0
        if best is None or n < best[1] or (n == best[1] and abs(g - f + 1) < abs(best[0] - f + 1)):
            best = (g, n)
        if n == 0 and g == f - 1: break
    if best:
        print(f'frame {f}: MAME frame {best[0]} ({best[1]} pixels differ), lag {f - 1 - best[0]:+d}')
