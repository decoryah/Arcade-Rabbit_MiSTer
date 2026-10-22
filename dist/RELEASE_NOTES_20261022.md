## Rabbit for MiSTer - 20261022

Aorn / Electronic Arts' **Rabbit** (1997), the one-on-one fighting game on the VG5330-B board (68EC020 and the Imagetek
I5000), with four MRAs: Asia 3-6 (the parent), Asia 1-28, Japan 3-6 and Japan 1-28 (location test).

**The 20261021 build was tested on a real MiSTer by the repository owner: its features work, and its KO fix kept the fighters
on screen, with a flashing the owner reported.** This build has not been on a MiSTer yet. It fixes three things MAME gets wrong,
each found in the game's own data and checked against a recording of a real board (YouTube, "[Arcade PCB] Rabbit Just play
(Not MAME)", 1080p at 60 fps), and was checked in simulation against MAME 0.289 everywhere else (below).

New:
- **The KO flash is the board's** (MAME Testers 04883, "Missing sprites during KO"). After a knockout the game flashes the
  screen for 0.75 s before the slow-motion fall. On the board a normal frame (the fighters, the life bars, the stage)
  alternates with a flash frame (the stage a flat light grey, no fighters, the life bars and the hit counter on top). MAME shows
  neither (the fighters vanish, and the stage covers the life bars every other frame); the 20261021 build showed the fighters but
  the stage instead of the grey, which made them blink. Three things MAME does not emulate give the board's picture, and the
  core now does all three: the chip shows a frame's sprites one frame late (it draws them into a bitmap during one frame and shows
  it in the next), compares the layers' priorities on 3 bits, and fills everything behind the sprites with the colour the game
  writes to 0x400406-0x400409 (light grey on the flash frames).
- The OSD option **KO flash: Board / Off**. Board (the default) is the flashing above, as the board does it. Off shows the flash
  frames like the frames between (the fighters over the stage): the knockout without the flashing.
- **The fades.** The logos at power-on and in the attract mode fade in and out, and the title comes out of a white screen in 16
  steps, as on the board (the core's steps within 3 % of the recording's). MAME draws the fade's cover tile opaque and ignores
  the fade register (0x400405), so the logos vanish for the length of every fade.
- **The test mode's MEMORY TEST passes** (MAME, and the earlier builds, report every graphics and sound ROM as ERROR: MAME does not
  bank the ROM readback window the test reads them through). The MRAs now load the sound ROM's 24-byte header at the end of its
  region, where MAME leaves zeros (the test sums it).
- No Service button in the pad mapping any more (the keyboard's 9 still is the service button).

Unchanged since 20261021: Sound Enhanced (the default: the board's pitch and the "D2" filter) or MAME, CRT Adjust (OSD page "CRT
Adjust"), the buttons named as the game uses them, every Scandoubler Fx setting and MiSTer.ini's `forced_scandoubler`, the board's
57.6 Hz refresh by default.

### Install

1. Unzip `Rabbit_MiSTer_20261022.zip` over the root of the SD card. It adds `Rabbit (Asia 3-6).mra` to `_Arcade/`, the
   other three to `_Arcade/_alternatives/_Rabbit/` and `_Arcade/cores/rabbit_20261022.rbf`. Replace the MRAs of earlier
   releases (they load the sound ROM's header differently; the game runs either way, only the MEMORY TEST's SOUND line differs).
2. Put your own MAME 0.289 romset `rabbit.zip` (the merged set holds all four versions) in `games/mame/`. No ROMs are
   included.
3. Start the game from the Arcade menu. The ROM image is 28 MB: with a recent Main_MiSTer it is copied to the DDR3 in one
   go and the core loads it from there in about 1.4 s (the MRAs' `address=` attribute); an older one streams it, with the
   same RBF and MRAs. The game's power-on RAM / ROM test then runs and its warning screen stays for two seconds, as on
   the board. Its settings and high scores are kept in the EEPROM, which MiSTer saves (`nvram`).

The OSD's version line reads `v261022`.

### Checked

- **ROM path:** `tools/make_mra.py` builds every MRA's image by the MiSTer MRA rules and compares it with the image
  `tools/rabbit_rom.py` builds by MAME's loading rules: identical for all four sets. The program, gfx1 and gfx2 regions are
  byte-identical to MAME's own memory regions, the sample region too except its last 24 bytes (the header, above).
- **Against the board recording:** the KO flash frame for frame (a KO at 4:46 of the recording against two KOs dumped from MAME:
  the core's frames alternate as the board's, the grey under the life bars, the fighters on the frames between); the white
  screen's fade into the title within 0.03 of the full swing at every one of its 16 steps; the EA logo's fade to black in 16
  frames with the credit text unchanged. The test mode's MEMORY TEST: every expected sum in the program is the byte sum of one ROM
  file, which fixes how the window maps the ROMs. The test run on the whole machine (`sim/run_sys.sh`, SCHED=test: the
  test switch, then up, up, A, as `tools/lua/testmode.lua` presses them in MAME): all twelve lines OK (PV00-PV03, FV01-FV04,
  BG00-BG02, SOUND), where MAME shows FV01-FV04, BG00-BG02 and SOUND as ERROR.
- **The video chip against MAME 0.289** (`sim/run_frames.sh`, MAME's video state rendered by the core's video pipeline with the
  real SDRAM path): every frame of the earlier corpora pixel-identical to MAME's snapshot (583 of 584 of the attract mode and
  scripted play, the other a KO flash frame of the attract mode's demo fight; and 696 more: 241 consecutive frames of the attract
  mode, 269 of play, 101 of a fight, 85 of the attract mode's first 1,000 frames), except, by design, the KO's flash frames and
  the fades. On consecutive frames (`SEQ=1`, one snapshot a frame
  as the machine runs) the pictures are MAME's layers with MAME's sprites of the frame before; KO flash Off shows every frame of a
  KO's flash with the fighters.
- **The whole machine** (`sim/run_sys.sh`: the 68020 running the game's program, blitter, sound and video behind the SDRAM
  controller and a behavioural SDRAM): it runs on MAME's timeline frame for frame. The work RAM at vblank is MAME's byte for byte
  outside the stack at every dump of the attract mode (70 dumps, frames 130 to 820) and of scripted play to frame 305 (from 306 the
  blit-queue race documented since 20261020); in the stack (fff000-fff2ff) some words differ with where an interrupt landed (the
  CPU now waits for the video chip at the fade and fill registers, a few microseconds). The pictures of scripted play, frames
  401-560 (the character select and a fight), are every one MAME's layers with MAME's sprites of the frame before (159 of 159
  pixel-identical to the frame bench's render of exactly that); no SDRAM timing violation, no line late.
- **The MiSTer top level** (`sim/emu/run_emu.sh`): the fast load of this build's image (the sound ROM's header at the end of its
  region) leaves the SDRAM byte-identical to the expected layout in 1.39 s of machine time, every frame whole at 57.61 Hz; with
  KO flash Off the OSD's bit reaches the core (status 0x8000), every frame whole. The video modes are 20261021's (unchanged).
- **The sound** is 20261021's (`sim/run_snd.sh`): Sound: MAME is MAME's I5000 exactly; Enhanced is the chip at the game's rate and
  the filter, bit for bit against its integer model.
- **Quartus 17.0.2:** 48 % of the ALMs (19,944), 463 of 553 M10K, 47 DSPs; every clock's slack positive (the 96 MHz machine clock +0.364 ns setup, +0.242 ns hold; the framework's HDMI scaler +0.592 ns setup, +0.258 ns hold; fitter seed 8). `releases/rabbit_20261022.fit.summary` / `.sta.summary`.

### Controls

Per player: Light Punch (A), Heavy Punch (B), Light Kick (C), Heavy Kick (D), Start, Coin. A to D are the game's own
names; which is which was measured in MAME. A pad's default layout puts the punches on the top face buttons and the kicks on the
bottom ones (Y X / B A), as the Saturn version has them. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test switch (the
game's settings; the board has no DIP switches).

### OSD

Aspect ratio, Scale (Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+), Scandoubler Fx (None, HQ2x, CRT 25 / 50 /
75 %), CRT Adjust (rmonic79's: H-Size, H-Position, V-Shift for a 15 kHz analog output), Sound (Enhanced / MAME), Volume, Swap
stereo, Refresh rate (57.6 Hz board / 60 Hz MAME), KO flash (Board / Off), Autosave EEPROM, Save EEPROM, Reset. See the README.

### Known differences / open points

- **The sound's decoding is still MAME's.** The samples are decoded with MAME's OKI ADPCM, which their data does not fit (the
  signal sits at its limit 43 % of the time: the harsh, crunchy sound). The board's real decoding is unknown (MAME flags the
  game's sound as imperfect). Sound: Enhanced only filters MAME's decoding; `docs/hardware.md` "Sound" has what a recording of a
  real board shows. 31 samples end with a loop command that MAME and the core treat as their end (in the logged play the game
  stops every such note before its end).
- The sprites one frame late are the board's in the KO's flash; elsewhere the core applies the same rule, which the recording
  cannot check frame by frame (its attract-mode demo fight is another fight: the game picks the opponent at random). Whether the
  fill colour lies behind or in front of the sprites is not known (the flash frames have none).
- The board's frame rate is measured, not documented: a recording of a real board runs the attract mode 4.1 % slower than
  MAME's 60 Hz, and the board's 40 MHz video clock gives 57.61 Hz for a 263-line raster. The core's default is 57.61 Hz;
  "Refresh rate: 60 Hz (MAME)" gives MAME's speed. The comparisons with MAME above were made at 60 Hz.
- The 68020 is TG68K.C, paced to MAME's speed by a token bucket calibrated on the power-on test; in stall-free game code
  it is about 10 % faster than MAME's. Where the game races itself (from frame 306 of scripted play its blit queue starts
  some blits a frame earlier than in MAME) a queue index and 16 marker words in the work RAM differ from MAME's; those
  blits rewrite the same tiles every frame and the pictures are MAME's.

### Credits

MAME (the rabbit driver by David Haywood, the I5000 sound device by hap), TG68K.C (Tobias Gubener),
decoryah/Arcade-Metro_MiSTer (the SDRAM protocol and model, the fast load, the 93C46, the standby raster), and the MiSTer
framework.
