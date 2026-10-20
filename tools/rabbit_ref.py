#!/usr/bin/env python3
"""rabbit_ref.py <state_<f>.bin> <image.rom> <out.png> [--layers 0123s]: MAME 0.289's rabbit screen_update in Python.

Draws a state dumped by tools/lua/dump_state.lua the way rabbit_state::screen_update does (drawtilemap's draw_roz, draw_sprites into the
4096 x 4096 bitmap, draw_sprite_bitmap's scaled copy), with the ROMs of an image from tools/rabbit_rom.py. --layers limits what is
drawn (digits = tilemaps, s = sprites), to isolate a layer when the core's picture differs from MAME's.
"""
import sys, struct, os, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio

ap = argparse.ArgumentParser()
ap.add_argument('state'); ap.add_argument('rom'); ap.add_argument('out')
ap.add_argument('--layers', default='0123s')
a = ap.parse_args()

d = open(a.state, 'rb').read()
dw = struct.unpack('>%dI' % (len(d) // 4), d)
tm = [dw[4096 * l:4096 * (l + 1)] for l in range(4)]
spr = dw[4 * 4096:5 * 4096]
pal = dw[5 * 4096:5 * 4096 + 16384]
o = 5 * 4096 + 16384
regs = [dw[o + 6 * l:o + 6 * l + 6] for l in range(4)]
sr = dw[o + 24:o + 31]
img = open(a.rom, 'rb').read()
gfx1 = img[0x200000:0x1200000]
gfx2 = img[0x1200000:0x1800000]

BLACK = None
bm = [[BLACK] * 320 for _ in range(224)]


def tile_pixel(L, col, row):
    """(pen, palette index, opaque) of tilemap L's pixel (col, row)."""
    ts = 16 if L < 3 else 8
    e = tm[L][(row // ts) * 128 + (col // ts) % 128]
    depth = (e >> 28) & 1
    tileno = e & 0xffff
    bank = (e >> 16) & 0xf
    colour = (e >> 20) & 0xff
    cmask = (e >> 31) & 1
    flipx = (e >> 30) & 1          # TILE_FLIPXY swaps the bits
    flipy = (e >> 29) & 1
    if bank == 8: tileno += 0x10000
    elif bank == 0xc: tileno += 0x20000
    px, py = col % ts, row % ts
    if flipx: px = ts - 1 - px
    if flipy: py = ts - 1 - py
    tsz = 1 if ts == 16 else 0
    if depth:
        code = tileno >> (1 + tsz * 2)
        c = (colour & 0x0f) + 0x20
        # 8bpp: a byte a pixel, rows of ts bytes
        base = code * ts * ts
        pen = gfx2[(base + py * ts + px) % len(gfx2)]
        return pen != 255, c * 256 + pen
    else:
        code = tileno >> (tsz * 2)
        if cmask: colour &= 0x3f
        c = colour + 0x200
        base = code * ts * ts // 2
        byte = gfx2[(base + py * ts // 2 + px // 2) % len(gfx2)]
        pen = (byte >> 4) if (px & 1) else (byte & 15)
        return pen != 15, c * 16 + pen


def drawtilemap(L):
    r = regs[L]
    sx, sy = r[1] & 0xffff, r[1] >> 16
    incxx, incyy = r[3] & 0xfff, (r[4] >> 16) & 0xfff
    W, H = (2048, 512) if L < 3 else (1024, 256)
    for y in range(224):
        row = ((sy * 128 + y * incyy) >> 11) & (H - 1)
        for x in range(320):
            col = ((sx * 128 + x * incxx) >> 11) & (W - 1)
            opq, idx = tile_pixel(L, col, row)
            if opq:
                bm[y][x] = idx


def sprites():
    todraw = (sr[5] >> 16) & 0xfff
    sb = {}                                   # the 4096 x 4096 bitmap: (y, x) -> value (cleared region implied)
    for s in range(todraw - 1, -1, -1):
        e0, e1 = spr[2 * s], spr[2 * s + 1]
        xpos = e0 & 0xfff
        ypos = (e0 >> 16) & 0xfff
        xflip = (e0 >> 15) & 1
        yflip = (e0 >> 14) & 1
        tileno = e1 & 0x1ffff
        colr = (e1 >> 20) & 0xff
        if xpos & 0x800: xpos -= 0x1000
        dx, dy = xpos + 0x20 - 8, ypos - 24
        fx = not xflip
        for ry in range(16):
            gy = 15 - ry if yflip else ry
            by = dy + ry
            if not 0 <= by < 4096: continue
            for rx in range(16):
                gx = 15 - rx if fx else rx
                # sprite_16x16x4_layout: pixels 0-7 in the upper half of gfx1, 8-15 in the lower; within a row's 4 bytes
                # the pixel order is byte 1 hi, lo, byte 0 hi, lo, byte 3 hi, lo, byte 2 hi, lo
                half = 0x800000 if gx < 8 else 0
                k = gx & 7
                byte = gfx1[half + tileno * 64 + gy * 4 + [1, 1, 0, 0, 3, 3, 2, 2][k]]
                pen = (byte >> 4) if k % 2 == 0 else (byte & 15)
                if pen == 15: continue
                bx = dx + rx
                if 0 <= bx < 4096:
                    sb[(by, bx)] = colr * 16 + pen
    startx = (sr[0] & 0xfff) - ((sr[1] & 0x1ff) >> 1)
    starty = ((sr[1] >> 16) & 0xfff) - ((sr[1] & 0x1ff) >> 1)
    xsize = (sr[2] & 0xffff) + 0x80
    ysize = (sr[3] & 0xffff) + 0x80
    xstep = ((320 * 128) << 16) // xsize
    ystep = ((224 * 128) << 16) // ysize
    for y in range(0, ysize, 0x80):
        yd = ((y >> 7) * ystep) >> 16
        if 0 <= yd < 224:
            srow = (starty + (y >> 7)) & 0xfff
            for x in range(0, xsize, 0x80):
                xd = ((x >> 7) * xstep) >> 16
                v = sb.get((srow, (startx + (x >> 7)) & 0xfff), 0)
                if v and 0 <= xd < 320:
                    bm[yd][xd] = v


for lvl in range(15, 0, -1):
    for L in (3, 2, 1, 0):
        if str(L) in a.layers and ((regs[L][0] >> 24) & 0xf) == lvl:
            drawtilemap(L)
    if lvl == 9 and 's' in a.layers:
        sprites()

out = bytearray()
for y in range(224):
    for x in range(320):
        v = bm[y][x]
        if v is None:
            out += b'\0\0\0'
        else:
            p = pal[v]
            out += bytes(((p >> 8) & 0xff, (p >> 16) & 0xff, p & 0xff))     # xGRB_888
pngio.write(a.out, 320, 224, out)
