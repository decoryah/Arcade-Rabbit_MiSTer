#!/usr/bin/env python3
"""cmp_ram.py <bench prefix> <MAME dir> <frames...> [--show N] [--stack]: the work RAM (ff0000-ffffff) the system bench dumped at vblank
(<prefix>.wram_<f>.bin, sim/tb_rabbit.cpp DUMPRAM) against MAME's at the same frame (<dir>/wram_<f>.bin, dump_state.lua WORKRAM=1).
The stack (ffe000-fff2ff: the interrupt's entry has pushed a few words by the time the bench dumps) is left out unless --stack."""
import sys, os, argparse

ap = argparse.ArgumentParser()
ap.add_argument('prefix'); ap.add_argument('dir'); ap.add_argument('frames', nargs='+', type=int)
ap.add_argument('--show', type=int, default=8); ap.add_argument('--stack', action='store_true')
a = ap.parse_args()

for f in a.frames:
    p, q = f'{a.prefix}.wram_{f}.bin', os.path.join(a.dir, f'wram_{f}.bin')
    if not (os.path.exists(p) and os.path.exists(q)):
        continue
    x, y = open(p, 'rb').read(), open(q, 'rb').read()
    diff = [i for i in range(len(x)) if x[i] != y[i] and (a.stack or not (0xe000 <= i < 0xf300))]
    line = f'frame {f}: {len(diff)} bytes differ'
    if diff:
        line += ': ' + ' '.join(f'{0xff0000 + i:06x}:{x[i]:02x}/{y[i]:02x}' for i in diff[:a.show])
    print(line)
