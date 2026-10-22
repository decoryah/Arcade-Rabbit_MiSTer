#!/usr/bin/env python3
"""Writes the Rabbit MRAs (mra/*.mra) from MAME 0.289's ROM lists (src/mame/metro/rabbit.cpp).

    python3 tools/make_mra.py [<rabbit.zip>]

With the romset given, every MRA is assembled by tools/mra_build.py and compared with the image tools/rabbit_rom.py builds by MAME's
loading rules (the image the simulations run); they must be identical. The layout is rtl/rabbit_loader.sv's.
"""
import os, sys, subprocess, tempfile, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..')
sys.path.insert(0, HERE)

SETS = [
    # set, name, year, program ROMs (byte 0..3 of each 32-bit word), parent zip
    ('rabbit',   'Rabbit (Asia 3-6)',                  '1997', [('jpr0.0', '52bb18c0'), ('jpr1.1', '38299d0d'), ('jpr2.2', 'fa3fd91a'), ('jpr3.3', 'd22727ca')]),
    ('rabbita',  'Rabbit (Asia 1-28)',                 '1996', [('pv00_mst.u82', 'e23e738e'), ('pv01_mst.u84', '8c7ff335'), ('pv02_mst.u83', 'c4bee278'), ('pv03_mst.u85', '062f524e')]),
    ('rabbitj',  'Rabbit (Japan 3-6)',                 '1997', [('pvo0.u82', '56ee441b'), ('pvo1.u84', '7d8addc5'), ('pvo2.u83', '4a333d89'), ('pvo3.u85', '791bf835')]),
    ('rabbitjt', 'Rabbit (Japan 1-28, location test)', '1996', [('pvo0_mst_1-28.u82', 'a1c30c91'), ('pvo1_mst_1-28.u84', '9b7697e6'), ('pvo2_mst_1-28.u83', '9809b825'), ('pvo3_mst_1-28.u85', 'ce8ebb82')]),
]

TEMPLATE = '''<misterromdescription>
    <name>{name}</name>
    <setname>{setname}</setname>
    <mameversion>0289</mameversion>
    <year>{year}</year>
    <manufacturer>Aorn / Electronic Arts</manufacturer>
    <players>2</players>
    <joystick>8</joystick>
    <rotation>horizontal</rotation>
    <rbf>rabbit</rbf>
    <platform>Rabbit</platform>

    <!--
      The image of the Rabbit core (rtl/rabbit_loader.sv, tools/rabbit_rom.py), the same layout for every set:
        0x0000000  0x0200000  maincpu   ROM_LOAD32_BYTE of the four program ROMs
        0x0200000  0x1000000  gfx1      ROM_LOAD32_WORD: jfv1 / jfv0, then jfv3 / jfv2
        0x1200000  0x0600000  gfx2      jbg0, jbg1, jbg2
        0x1800000  0x0400000  i5000snd  jsn0 from its byte 0x18 (MAME's ROM_CONTINUE over the header), then the header (MAME: 0x18 zero bytes)
        0x1C00000  0x0000080  eeprom    rabbit.nv (the EEPROM's default; a saved .nvm takes its place)
      Expects the MAME 0.289 merged romset or the split sets: parts are found by name and CRC.
      The game has no DIP switches: its settings are in the EEPROM (the test mode: F2, or Service + Start on a pad).
    -->

    <buttons names="Light Punch (A),Heavy Punch (B),Light Kick (C),Heavy Kick (D),Start,Coin,Service" default="Y,X,B,A,Start,Select,L"/>

    <rom index="0" zip="{zips}" md5="None" address="0x32000000">
        <!-- maincpu -->
        <interleave output="32">
            <part name="{p0}" crc="{c0}" map="0001"/>
            <part name="{p1}" crc="{c1}" map="0010"/>
            <part name="{p2}" crc="{c2}" map="0100"/>
            <part name="{p3}" crc="{c3}" map="1000"/>
        </interleave>

        <!-- gfx1: sprites and the blitter's lists -->
        <interleave output="32">
            <part name="jfv1.01" crc="83f3926e" map="0021"/>
            <part name="jfv0.00" crc="b2a4d3d3" map="2100"/>
        </interleave>
        <interleave output="32">
            <part name="jfv3.03" crc="3e1a9be2" map="0021"/>
            <part name="jfv2.02" crc="b264bfb5" map="2100"/>
        </interleave>

        <!-- gfx2: the tilemaps' tiles -->
        <part name="jbg0.40" crc="89662944"/>
        <part name="jbg1.50" crc="1fc7f6e0"/>
        <part name="jbg2.60" crc="aee265fc"/>

        <!-- i5000snd -->
        <part name="jsn0.11" crc="e1f726e8" offset="0x18" length="0x3FFFE8"/>
        <part name="jsn0.11" crc="e1f726e8" offset="0" length="0x18"/>

        <!-- eeprom -->
        <part name="rabbit.nv" crc="73d471ed"/>
    </rom>

    <nvram index="4" size="128"/>
</misterromdescription>
'''


def mra_text(s):
    setname, name, year, prog = s
    zips = f'{setname}.zip' if setname == 'rabbit' else f'{setname}.zip|rabbit.zip'
    d = dict(name=name, setname=setname, year=year, zips=zips)
    for i, (p, c) in enumerate(prog):
        d[f'p{i}'] = p; d[f'c{i}'] = c
    return TEMPLATE.format(**d)


def path_of(s):
    if s[0] == 'rabbit':
        return os.path.join(ROOT, 'mra', f'{s[1]}.mra')
    return os.path.join(ROOT, 'mra', '_alternatives', '_Rabbit', f'{s[1]}.mra')


def main():
    for s in SETS:
        p = path_of(s)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w', newline='\n').write(mra_text(s))
        print('wrote', os.path.relpath(p, ROOT))
    if len(sys.argv) > 1:
        import rabbit_rom
        z = sys.argv[1]
        for s in SETS:
            with tempfile.TemporaryDirectory() as td:
                out = os.path.join(td, 'x.rom')
                r = subprocess.run([sys.executable, os.path.join(HERE, 'mra_build.py'), path_of(s), z, out], capture_output=True, text=True)
                if r.returncode != 0:
                    sys.exit(f'{s[0]}: mra_build failed: {r.stdout}{r.stderr}')
                a = open(out, 'rb').read()
            b = bytes(rabbit_rom.build(z, s[0]))
            ok = (a == b)
            print(f'{s[0]}: MRA image {len(a):#x} bytes, md5 {hashlib.md5(a).hexdigest()}: ' + ('identical to rabbit_rom.py' if ok else 'DIFFERS from rabbit_rom.py'))
            if not ok:
                n = sum(1 for i in range(min(len(a), len(b))) if a[i] != b[i])
                sys.exit(f'{n} bytes differ')


if __name__ == '__main__':
    main()
