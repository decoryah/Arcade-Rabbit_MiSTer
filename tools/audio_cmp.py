#!/usr/bin/env python3
"""audio_cmp.py <bench.raw> <mame.wav> [--from F] [--to F]: the core's sound (the system bench's AUDIO=1 output: 48 kHz, 16-bit stereo,
from the machine's reset) against MAME's -wavwrite recording of the same scripted run.

Per frame (1/60 s) the RMS of each channel is computed for both; the two envelopes are aligned by the lag (in frames, -30 .. +30) that
correlates best, and their ratio and correlation reported, per channel, over frames F .. T."""
import sys, struct, math, argparse

ap = argparse.ArgumentParser()
ap.add_argument('raw'); ap.add_argument('wav')
ap.add_argument('--from', dest='f0', type=int, default=60); ap.add_argument('--to', dest='f1', type=int, default=0)
a = ap.parse_args()


def read_wav(p):
    d = open(p, 'rb').read()
    i = 12
    rate = ch = None
    while i < len(d):
        cid, ln = d[i:i + 4], struct.unpack('<I', d[i + 4:i + 8])[0]
        if cid == b'fmt ':
            _, ch, rate = struct.unpack('<HHI', d[i + 8:i + 16])
        elif cid == b'data':
            return rate, ch, d[i + 8:i + 8 + ln]
        i += 8 + ln
    sys.exit('no data chunk')


def env(samples, rate):
    """RMS per 1/60 s of interleaved stereo int16 -> ([L], [R])"""
    n = len(samples) // 2
    per = rate / 60.0
    L, R = [], []
    f = 0
    while int((f + 1) * per) <= n:
        s0, s1 = int(f * per), int((f + 1) * per)
        sl = sr = 0
        for k in range(s0, s1):
            l, r = samples[2 * k], samples[2 * k + 1]
            sl += l * l; sr += r * r
        L.append(math.sqrt(sl / (s1 - s0))); R.append(math.sqrt(sr / (s1 - s0)))
        f += 1
    return L, R


rb = open(a.raw, 'rb').read()
ours = struct.unpack('<%dh' % (len(rb) // 2), rb)
rate, ch, md = read_wav(a.wav)
mame = struct.unpack('<%dh' % (len(md) // 2), md)
oL, oR = env(ours, 48000)
mL, mR = env(mame, rate)
f1 = a.f1 or min(len(oL), len(mL))


def corr(x, y):
    n = len(x)
    if n == 0: return 0
    mx, my = sum(x) / n, sum(y) / n
    sxy = sum((p - mx) * (q - my) for p, q in zip(x, y))
    sxx = sum((p - mx) ** 2 for p in x); syy = sum((q - my) ** 2 for q in y)
    return sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else 0


for name, o, m in (('left', oL, mL), ('right', oR, mR)):
    best = None
    for lag in range(-30, 31):
        xs = [o[f] for f in range(a.f0, f1) if 0 <= f + lag < len(m) and f < len(o)]
        ys = [m[f + lag] for f in range(a.f0, f1) if 0 <= f + lag < len(m) and f < len(o)]
        c = corr(xs, ys)
        if best is None or c > best[0]: best = (c, lag, xs, ys)
    c, lag, xs, ys = best
    ratio = (sum(xs) / sum(ys)) if sum(ys) > 0 else float('nan')
    print(f'{name}: frames {a.f0}-{f1}, best lag {lag:+d} frames (MAME later when +), envelope correlation {c:.4f}, '
          f'level ours/MAME {ratio:.3f}, mean RMS ours {sum(xs)/max(1,len(xs)):.0f} MAME {sum(ys)/max(1,len(ys)):.0f}')
