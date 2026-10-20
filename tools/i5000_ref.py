#!/usr/bin/env python3
"""i5000_ref.py <rabbit.sdram> <snd.log> <out.wav> [t0] [t1] [--mame-rate]: MAME 0.289's I5000 sound device (src/devices/sound/i5000.cpp) in Python,
replayed from a register log (tools/lua/snd_log.lua), with the core's one difference: the sample rate is the one the game sets in register
0x46, 40 MHz / (2 * (d[9:0] + 1)) (MAME: a fixed 40 MHz / 1024 until then and always). The reference the core's sound chip is checked
against (sim/run_snd.sh, tools/audio_cmp.py) now that MAME's own recording plays at the other rate.

Writes a 16-bit stereo WAV at the chip's rate (rounded to a whole Hz), from t0 to t1 seconds (default: all of the log)."""
import sys, struct, math

args = [a for a in sys.argv[1:] if not a.startswith('--')]
sd, logf, outf = args[0:3]
T0 = float(args[3]) if len(args) > 3 else 0.0
T1 = float(args[4]) if len(args) > 4 else 1e9
d = open(sd, 'rb').read()
ROM = struct.unpack('<%dH' % 0x200000, d[0x1800000:0x1800000 + 0x400000])     # the sample ROM's words (rabbit_rom.py --sdram layout)
MASK = 0x1fffff

VOL = [int(2047.0 / (1.032 ** i) + 0.5) for i in range(255)] + [0]           # m_lut_volume
NB = [[1 if not (n & 8) else -1, (n >> 2) & 1, (n >> 1) & 1, n & 1] for n in range(16)]
DIFF = []                                                                        # oki_adpcm_state's diff_lookup
for st in range(49):
    sv = int(math.floor(16.0 * (11.0 / 10.0) ** st))
    for n in range(16):
        s, b2, b1, b0 = NB[n]
        DIFF.append(s * (sv * b2 + sv // 2 * b1 + sv // 4 * b0 + sv // 8))
IDX = [-1, -1, -1, -1, 2, 4, 6, 8]


class Ch:
    def __init__(self):
        self.playing = False; self.address = 0; self.sample = 0; self.shift_pos = 0; self.shift_amount = 4; self.shift_mask = 0xf
        self.freq_timer = 0; self.freq_base = 0; self.freq_min = 0x100; self.vol_r = self.vol_l = 0; self.out_r = self.out_l = 0
        self.sig = -2; self.step = 0


chs = [Ch() for _ in range(16)]
regs = [0] * 0x80
rate = [40e6 / 1024]
MAME_RATE = '--mame-rate' in sys.argv          # MAME's fixed rate: register 0x46 ignored (to check this against MAME's own recording)


def read_sample(c):
    c.shift_pos &= 0xf
    c.sample = ROM[c.address]; c.address = (c.address + 1) & MASK
    if c.sample == 0x7f7f:
        c.address = (c.address + 1) & MASK
        return False
    return True


def write(r, v):
    if r < 0x40:
        c = chs[r >> 2]
        if r & 3 == 2: c.freq_base = (0x1ff - (v & 0xff)) << ((~v >> 8) & 3)
        elif r & 3 == 3: c.vol_r = VOL[v & 0xff]; c.vol_l = VOL[v >> 8 & 0xff]
    elif r == 0x42:
        for i in range(16):
            c = chs[i]
            if v >> i & 1 and not c.playing:
                a = (regs[i * 4 + 1] << 16 | regs[i * 4]) & MASK
                if ROM[a] != 0x7f7f: continue
                p = ROM[(a + 1) & MASK]
                if p in (0x0104, 0x0304): c.freq_min, c.shift_amount, c.shift_mask = 0x140, 3, 0xe
                else: c.freq_min, c.shift_amount, c.shift_mask = 0x100, 4, 0xf
                c.address = (a + 4) & MASK; c.freq_timer = 0; c.shift_pos = 0; c.sig = -2; c.step = 0
                c.playing = read_sample(c)
    elif r == 0x43:
        for i in range(16):
            if v >> i & 1: chs[i].playing = False
    elif r == 0x46 and not MAME_RATE:
        rate[0] = 40e6 / (2 * ((v & 0x3ff) + 1))
    regs[r] = v


events = []
for line in open(logf):
    f = line.split()
    if f[0] == 'R': continue
    events.append((float(f[0].replace(',', '.')), int(f[1]), int(f[2], 16)))
events.sort(key=lambda e: e[0])
tend = min(T1, events[-1][0] + 1.0)
# the WAV's rate is the last one the game sets (it sets it once, at boot); samples are placed at their times in it
w46 = [v for _, r, v in events if r == 0x46 and not MAME_RATE]
out_rate = int(round(40e6 / (2 * ((w46[-1] & 0x3ff) + 1)))) if w46 else 39062
out = bytearray()
t = 0.0
ei = 0
while t < tend:
    while ei < len(events) and events[ei][0] <= t:
        write(events[ei][1], events[ei][2]); ei += 1
    mr = ml = 0
    for c in chs:
        if not c.playing: continue
        c.freq_timer -= c.freq_min
        if c.freq_timer > 0:
            mr += c.out_r; ml += c.out_l; continue
        c.freq_timer += c.freq_base
        a = c.sample >> c.shift_pos
        c.shift_pos += c.shift_amount
        if c.shift_pos & 0x10:
            if not read_sample(c):
                c.playing = False; continue
            a |= c.sample << (c.shift_amount - c.shift_pos)
        n = a & c.shift_mask
        c.sig = max(-2048, min(2047, c.sig + DIFF[c.step * 16 + n]))
        c.step = max(0, min(48, c.step + IDX[n & 7]))
        c.out_r = int(c.sig * c.vol_r / 128); c.out_l = int(c.sig * c.vol_l / 128)
        mr += c.out_r; ml += c.out_l
    if t >= T0:
        while len(out) // 4 < int((t - T0) * out_rate): out += b'\0\0\0\0'
        out += struct.pack('<hh', max(-32768, min(32767, int(ml / 16))), max(-32768, min(32767, int(mr / 16))))
    t += 1.0 / rate[0]
hdr = b'RIFF' + struct.pack('<I', 36 + len(out)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, 2, out_rate, out_rate * 4, 4, 16) + \
      b'data' + struct.pack('<I', len(out))
open(outf, 'wb').write(hdr + out)
print('%s: %.2f s at %d Hz' % (outf, len(out) / 4 / out_rate, out_rate))
