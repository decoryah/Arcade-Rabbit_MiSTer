#!/usr/bin/env python3
"""state_info.py <state_<f>.bin>: the registers of a dumped state (tools/lua/dump_state.lua), decoded."""
import sys, struct
d = open(sys.argv[1], 'rb').read()
dw = struct.unpack('>%dI' % (len(d) // 4), d)
o = 4 * 4096 + 4096 + 16384
tm = [dw[o + 6 * l:o + 6 * l + 6] for l in range(4)]
sr = dw[o + 24:o + 31]
for l in range(4):
    r = tm[l]
    print(f'layer {l}: ' + ' '.join(f'{v:08x}' for v in r) +
          f'  pri {(r[0] >> 24) & 15}  sx {r[1] & 0xffff:#06x} ({(r[1] & 0xffff) / 16:.2f})  sy {r[1] >> 16:#06x} ({(r[1] >> 16) / 16:.2f})'
          f'  incxx {r[3] & 0xfff:#05x}  incyy {(r[4] >> 16) & 0xfff:#05x}')
print('sprites: ' + ' '.join(f'{v:08x}' for v in sr) + f'  todraw {(sr[5] >> 16) & 0xfff}')
