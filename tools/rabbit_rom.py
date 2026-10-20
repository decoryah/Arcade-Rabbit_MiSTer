#!/usr/bin/env python3
"""Rabbit ROM images from a MAME 0.289 romset (rabbit.zip, merged or split).

    python3 tools/rabbit_rom.py <rabbit.zip> <set> <out.rom> [--sdram out.sdram] [--eeprom out.nv]

<set> is rabbit, rabbita, rabbitj or rabbitjt. out.rom is the image the MRA assembles (rtl/rabbit_loader.sv, tools/make_mra.py):

    0x0000000  maincpu   2 MB  ROM_LOAD32_BYTE of the four program ROMs (byte 4i + k = ROM k's byte i)
    0x0200000  gfx1     16 MB  ROM_LOAD32_WORD: jfv1 / jfv0 interleaved by words (jfv1 first), then jfv3 / jfv2
    0x1200000  gfx2      6 MB  jbg0, jbg1, jbg2
    0x1800000  i5000snd  4 MB  jsn0 from its byte 0x18 (MAME's ROM_CONTINUE over the header), the last 0x18 bytes zero
    0x1C00000  eeprom  128 B   rabbit.nv

--sdram writes what the SDRAM holds after the load (the bench's backdoor): the image without the EEPROM, gfx1's halves interleaved by
sprite row (SDRAM byte 0x200000 + {b[22:2], b[23], b[1:0]} for gfx1 byte b). --eeprom writes the EEPROM's default (128 bytes).
Every part's CRC is checked against MAME's.
"""
import sys, zipfile, zlib, argparse

PROG = {
    'rabbit':   [('jpr0.0', 0x52bb18c0), ('jpr1.1', 0x38299d0d), ('jpr2.2', 0xfa3fd91a), ('jpr3.3', 0xd22727ca)],
    'rabbita':  [('pv00_mst.u82', 0xe23e738e), ('pv01_mst.u84', 0x8c7ff335), ('pv02_mst.u83', 0xc4bee278), ('pv03_mst.u85', 0x062f524e)],
    'rabbitj':  [('pvo0.u82', 0x56ee441b), ('pvo1.u84', 0x7d8addc5), ('pvo2.u83', 0x4a333d89), ('pvo3.u85', 0x791bf835)],
    'rabbitjt': [('pvo0_mst_1-28.u82', 0xa1c30c91), ('pvo1_mst_1-28.u84', 0x9b7697e6), ('pvo2_mst_1-28.u83', 0x9809b825), ('pvo3_mst_1-28.u85', 0xce8ebb82)],
}
COMMON = {
    'jfv0.00': 0xb2a4d3d3, 'jfv1.01': 0x83f3926e, 'jfv2.02': 0xb264bfb5, 'jfv3.03': 0x3e1a9be2,
    'jbg0.40': 0x89662944, 'jbg1.50': 0x1fc7f6e0, 'jbg2.60': 0xaee265fc,
    'jsn0.11': 0xe1f726e8, 'rabbit.nv': 0x73d471ed,
}
IMG_LEN = 0x1C00080


def find(z, name, crc, setname):
    """A file of the zip by name (the set's folder first, then anywhere), checked against its CRC."""
    names = z.namelist()
    cands = [n for n in names if n == f'{setname}/{name}'] + [n for n in names if n == name] + \
            [n for n in names if n.split('/')[-1] == name]
    for n in cands:
        d = z.read(n)
        if zlib.crc32(d) & 0xffffffff == crc:
            return d
    # by CRC alone (renamed files)
    for info in z.infolist():
        if info.CRC == crc:
            return z.read(info.filename)
    sys.exit(f'{name} (crc {crc:08x}) not found in the zip')


def build(zpath, setname):
    z = zipfile.ZipFile(zpath)
    img = bytearray(IMG_LEN)
    prog = [find(z, n, c, setname) for n, c in PROG[setname]]
    for k in range(4):
        img[k:0x200000:4] = prog[k]
    f = {n: find(z, n, c, setname) for n, c in COMMON.items()}
    g = 0x200000
    for half, (a, b) in enumerate((('jfv1.01', 'jfv0.00'), ('jfv3.03', 'jfv2.02'))):
        base = g + half * 0x800000
        A, B = f[a], f[b]
        out = bytearray(0x800000)
        out[0::4] = A[0::2]; out[1::4] = A[1::2]
        out[2::4] = B[0::2]; out[3::4] = B[1::2]
        img[base:base + 0x800000] = out
    img[0x1200000:0x1400000] = f['jbg0.40']
    img[0x1400000:0x1600000] = f['jbg1.50']
    img[0x1600000:0x1800000] = f['jbg2.60']
    img[0x1800000:0x1800000 + 0x3fffe8] = f['jsn0.11'][0x18:]
    img[0x1C00000:0x1C00080] = f['rabbit.nv']
    return img


def sdram_of(img):
    sd = bytearray(img[:0x1C00000])
    g = img[0x200000:0x1200000]
    out = bytearray(0x1000000)
    # SDRAM byte {b[22:2], b[23], b[1:0]}: 4-byte groups of the two halves alternate
    v_lo = memoryview(g)[:0x800000]
    v_hi = memoryview(g)[0x800000:]
    for i in range(4):
        out[i::8] = v_lo[i::4]
        out[4 + i::8] = v_hi[i::4]
    sd[0x200000:0x1200000] = out
    return sd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('zip'); ap.add_argument('set', choices=sorted(PROG)); ap.add_argument('out')
    ap.add_argument('--sdram'); ap.add_argument('--eeprom')
    a = ap.parse_args()
    img = build(a.zip, a.set)
    open(a.out, 'wb').write(img)
    print(f'{a.out}: {len(img):#x} bytes, crc32 {zlib.crc32(img) & 0xffffffff:08x}')
    if a.sdram:
        open(a.sdram, 'wb').write(sdram_of(img))
        print(f'{a.sdram}: SDRAM layout')
    if a.eeprom:
        open(a.eeprom, 'wb').write(img[0x1C00000:0x1C00080])


if __name__ == '__main__':
    main()
