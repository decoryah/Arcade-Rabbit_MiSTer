"""txref.py: the Enhanced sound's per-note tail expander (rtl/rabbit_i5000.sv, music channels 0-11) in integer arithmetic, bit for bit.

On each code a music channel decodes (MAME's 12-bit signal s), with 8 fraction bits:
  dc   += ((s << 8) - dc) >> DCK            the note's slow mean (DCK 7: about 27 Hz at 22 kcodes/s)
  x     = (s << 8) - dc
  env   = |x| if |x| > env else env - (env >> RK)      a peak follower (RK 9: about 23 ms at 22 kcodes/s)
  peak  = max(peak, env)                    the note's loudest so far (reset at the key on)
  g     = (env / peak) ^ EXP, in log2 with 6 fraction bits (LOG2 / EXP2 tables), floored at -FLOOR octaves
  s'    = (dc + ((x * g) >> 16)) >> 8       the note with its tail made to fade faster, back at 12 bits (s' never exceeds s's range)
The board's notes die away much faster than MAME's decoding lets them (bass notes about -14 dB in 125 ms on a recording of a real
board); the gaps between notes are where MAME's decoding leaves its noise. Against the board's recording this brings the short-term
dynamics of the attract mode to the board's (docs/hardware.md "Sound")."""
DCK, RK, EXP, FLOOR = 7, 9, 4, 10
LOG2 = [round(64 * __import__('math').log2(1 + m / 64)) for m in range(64)]          # log2(1 + m/64) in 1/64 octave
EXP2 = [round(65536 * 2 ** (-f / 64)) for f in range(64)]                            # 2^(-f/64), 1.0 = 65536


def log2q(v):
    """log2 of a positive integer in 1/64 octave (v >= 1)"""
    p = v.bit_length() - 1
    m = ((v << 6) >> p) & 63 if p < 6 else (v >> (p - 6)) & 63
    return (p << 6) + LOG2[m]


class Tx:
    def __init__(self): self.reset()

    def reset(self):
        self.dc = 0; self.env = 0; self.peak = 1 << 8

    def clock(self, s):
        xs = s << 8
        self.dc += (xs - self.dc) >> DCK
        x = xs - self.dc
        ax = abs(x)
        self.env = ax if ax > self.env else self.env - (self.env >> RK)
        if self.env > self.peak: self.peak = self.env
        d = log2q(self.peak) - log2q(max(self.env, 1))
        e = min(d * EXP, FLOOR << 6)
        g = EXP2[e & 63] >> (e >> 6)
        return (self.dc + ((x * g) >> 16)) >> 8


if __name__ == '__main__':
    # txref.py <out.tx>: the sound bench's record of the expander (sim/run_snd.sh with ENH=1: per event int32 type 0 key on / 1 code,
    # channel, in, out) replayed per channel and compared bit for bit
    import struct, sys
    d = open(sys.argv[1], 'rb').read()
    rec = struct.unpack('<%di' % (len(d) // 4), d)
    tx = [Tx() for _ in range(16)]
    n = bad = kons = 0
    for i in range(0, len(rec) - 3, 4):
        typ, ch, xin, xout = rec[i:i + 4]
        if typ == 0:
            tx[ch].reset(); kons += 1; continue
        n += 1
        y = tx[ch].clock(xin)
        if y != xout:
            if bad < 5: print('code %d, channel %d: in %d, model %d, RTL %d' % (n, ch, xin, y, xout))
            bad += 1
    print('%d key ons, %d codes expanded, %d differ' % (kons, n, bad))
    sys.exit(1 if bad else 0)
