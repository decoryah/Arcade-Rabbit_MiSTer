## Rabbit for MiSTer - 20261021

Aorn / Electronic Arts' **Rabbit** (1997), the one-on-one fighting game on the VG5330-B board (68EC020 and the Imagetek
I5000), with four MRAs: Asia 3-6 (the parent), Asia 1-28, Japan 3-6 and Japan 1-28 (location test).

**The 20261020 release was tested on a real MiSTer by the repository owner: the game and all four versions work, and so do
CRT Adjust, the button names and the scandoubler modes.** This build replaces the first 20261021 build (the one with the
fitted "Enhanced" sound) and has not been on a MiSTer yet; it was checked in simulation against MAME 0.289 (below).

New:
- **The fighters no longer vanish in a KO's slow motion** (MAME Testers 04883, "Missing sprites during KO", open in MAME
  since 0.146). The game ends its sprite list with a count of 0 on every other frame there; MAME then draws no sprites. The
  game's own data shows the chip draws its sprites one frame late, and the core now shows the frame before's sprites on such a
  frame, which gives the fighters on every normal frame of the slow motion between the game's flash frames. Every other frame
  is unchanged (MAME's to the pixel).
- The OSD option **Sound: Enhanced / MAME**. **MAME** is MAME's sound exactly: its 39,062.5 Hz (every sound 23 % slow, 3.5
  semitones flat), its decoding, nothing else; with "Refresh rate: 60 Hz (MAME)" too, the game also plays at MAME's tempo.
  **Enhanced** (the default) is the board's pitch (the rate the game sets, 47,962 Hz) and a filter that cuts the decoder's
  rumble below 150 Hz (up to 42 dB above a real board's recording) and the hiss above 11 kHz: the "D2" version, chosen by
  ear over a fitted version with a per-note expander and an eight-band EQ (the first 20261021 build).

The decoding itself is still MAME's, which is not the board's: see "Known differences". Since 20261020: CRT Adjust (OSD
page "CRT Adjust"), the buttons named as the game uses them (Light Punch, Heavy Punch, Light Kick, Heavy Kick), every
Scandoubler Fx setting and MiSTer.ini's `forced_scandoubler` checked (none freezes the picture), the board's 57.6 Hz
refresh by default.

### Install

1. Unzip `Rabbit_MiSTer_20261021.zip` over the root of the SD card. It adds `Rabbit (Asia 3-6).mra` to `_Arcade/`, the
   other three to `_Arcade/_alternatives/_Rabbit/` and `_Arcade/cores/rabbit_20261021.rbf`.
2. Put your own MAME 0.289 romset `rabbit.zip` (the merged set holds all four versions) in `games/mame/`. No ROMs are
   included.
3. Start the game from the Arcade menu. The ROM image is 28 MB: with a recent Main_MiSTer it is copied to the DDR3 in one
   go and the core loads it from there in about 1.4 s (the MRAs' `address=` attribute); an older one streams it, with the
   same RBF and MRAs. The game's power-on RAM / ROM test then runs and its warning screen stays for two seconds, as on
   the board. Its settings and high scores are kept in the EEPROM, which MiSTer saves (`nvram`).

The OSD's version line reads `v261021`.

### Checked

- **ROM path:** `tools/make_mra.py` builds every MRA's image by the MiSTer MRA rules and compares it with the image
  `tools/rabbit_rom.py` builds by MAME's loading rules: identical for all four sets. The program, gfx1, gfx2 and sample
  regions are byte-identical to MAME's own memory regions.
- **The video chip against MAME 0.289** (`sim/run_frames.sh`, MAME's video state dumped by a Lua probe and rendered by the
  core's video pipeline with the real SDRAM path): **584 of 584 frames pixel-identical** to MAME's snapshots (240 of the
  attract mode to frame 6,000, 344 of scripted play to frame 9,000 with coin, start, the character select, fights with
  special moves and summoned beasts; 29 of them zoomed, down to MAME's full zoom-out). No line ran out of time. The KO
  fix on consecutive frames (`SEQ=1`), two knockouts (the computer's 17-hit beast combo, the player's last hit), every frame
  of their slow motion: each frame with sprites MAME's to the pixel, each count-0 frame the frame before's sprites over its
  own picture.
- **The sound chip** (`sim/run_snd.sh`, the game's register writes replayed). Sound: MAME, over 100 s of the attract mode
  against MAME's own `-wavwrite` recording: loudness envelopes correlate 0.9999 on both channels, level within 0.7 %, and all
  9,145 reads of the channel status answer what MAME answered. Sound: Enhanced: the chip at the game's rate against
  `tools/i5000_ref.py` (MAME's device in Python at that rate): 0.9999, level within 0.2 %; the filter bit for bit against its
  integer model (`tools/sndflt_ref.py`; 1.4 million samples a side, no difference). The rate is the one a recording of a real
  board plays its samples at (to 0.05 %).
- **The whole machine** (`sim/run_sys.sh`: the 68020 running the game's program, blitter, sound and video behind the SDRAM
  controller and a behavioural SDRAM that checks its timing): it boots, reads its EEPROM and runs on MAME's timeline frame
  for frame: the work RAM at vblank is byte for byte MAME's at the same frame (the attract mode at 130-800, scripted play
  at every frame to 305), and the pictures are MAME's of the same frame (every frame of the attract mode 600-820 and of
  scripted play 291-421, every 50th of scripted play to 1600); its sound over those 1600 frames against MAME's recording
  of the same inputs: envelope correlation 0.99, level within 1 %. No SDRAM timing violation, no renderer overrun. (Those
  runs use Sound: MAME; with this build the attract mode's work RAM is MAME's at every dump from frame 130 to 820. With
  Sound: Enhanced the attract mode is MAME's frame for frame to frame 650, then runs a few frames ahead of MAME in the same
  scenes, as the game waits for its sounds, which end sooner, as on the board.)
- **The MiSTer top level** (`sim/emu/run_emu.sh`, `Rabbit.sv` with the framework's video path): the fast load and the
  streamed load both put the image in the SDRAM byte-identical to the expected layout, and the pictures the scaler gets
  are MAME's. The video modes (`sim/emu/run_modes.sh`, 24 runs): Scandoubler Fx HQ2x, CRT 25 / 50 / 75 % and MiSTer.ini's
  `forced_scandoubler` at both refresh rates give 448 rows in 524 lines with every frame whole and the same pictures; CRT Adjust
  sizes and moves the picture exactly as set (H-Size +2 / -16, H-Position +16 / -48, V-Shift +5 / -16) with no frame of the wrong
  length and no pixel lost; Scale asks the HDMI scaler for the sizes the framework's rule gives.
- **Quartus 17.0.2:** 47 % of the ALMs (19,556), 446 of 553 M10K, 44 DSPs; every clock's slack positive (the 96 MHz
  machine clock +0.295 ns setup, +0.252 ns hold; the framework's HDMI scaler +0.234 ns setup, +0.252 ns hold; fitter seed 4).
  `releases/rabbit_20261021.fit.summary` / `.sta.summary`.

### Controls

Per player: Light Punch (A), Heavy Punch (B), Light Kick (C), Heavy Kick (D), Start, Coin, Service. A to D are the game's own
names; which is which was measured in MAME. A pad's default layout puts the punches on the top face buttons and the kicks on the
bottom ones (Y X / B A), as the Saturn version has them. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test switch (the
game's settings; the board has no DIP switches).

### OSD

Aspect ratio, Scale (Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+), Scandoubler Fx (None, HQ2x, CRT 25 / 50 /
75 %), CRT Adjust (rmonic79's: H-Size, H-Position, V-Shift for a 15 kHz analog output), Sound (Enhanced / MAME), Volume, Swap stereo, Refresh rate (57.6 Hz
board / 60 Hz MAME), Autosave EEPROM, Save EEPROM, Reset. Scandoubler Fx and MiSTer.ini's `forced_scandoubler` work without freezing
the picture. See the README.

### Known differences / open points

- **The sound's decoding is still MAME's.** The samples are decoded with MAME's OKI ADPCM, which their data does not fit (the
  signal sits at its limit 43 % of the time: the harsh, crunchy sound). The board's real decoding is unknown (MAME flags the
  game's sound as imperfect). Sound: Enhanced only filters MAME's decoding; `docs/hardware.md` "Sound" has what a recording
  of a real board shows. A clean recording of single sounds from a board would settle the decoding.
- The KO fix follows the game's data, not a recording of a real board's KO (none at hand).
- The board's frame rate is measured, not documented: a recording of a real board runs the attract mode 4.1 % slower than
  MAME's 60 Hz, and the board's 40 MHz video clock gives 57.61 Hz for a 263-line raster. The core's default is 57.61 Hz;
  "Refresh rate: 60 Hz (MAME)" gives MAME's speed. The comparisons with MAME above were made at 60 Hz.
- The 68020 is TG68K.C, paced to MAME's speed by a token bucket calibrated on the power-on test; in stall-free game code
  it is about 10 % faster than MAME's. Where the game races itself (from frame 306 of scripted play its blit queue starts
  some blits a frame earlier than in MAME) a queue index and 16 marker words in the work RAM differ from MAME's; those
  blits rewrite the same tiles every frame and the pictures are MAME's.
- The gfx ROM readback window the test mode's ROM check uses is not banked, as in MAME, so the check reports what it
  reports in MAME.

### Credits

MAME (the rabbit driver by David Haywood, the I5000 sound device by hap), TG68K.C (Tobias Gubener),
decoryah/Arcade-Metro_MiSTer (the SDRAM protocol and model, the fast load, the 93C46, the standby raster), and the MiSTer
framework.
