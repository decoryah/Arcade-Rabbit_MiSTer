## Rabbit for MiSTer - 20261020

Aorn / Electronic Arts' **Rabbit** (1997), the one-on-one fighting game on the VG5330-B board (68EC020 and the Imagetek
I5000), with four MRAs: Asia 3-6 (the parent), Asia 1-28, Japan 3-6 and Japan 1-28 (location test).

**Tested on a real MiSTer by the repository owner: the game and all four versions work.** It was also checked in
simulation against MAME 0.289, frame for frame (below).

This RBF replaces the first build of the day: the sound now plays at the rate the game sets (47,962 Hz) instead of
MAME's 39,062.5 Hz, so every sound is at the board's pitch (MAME plays them 23 % slow, 3.5 semitones flat). The
decoding is still MAME's, which is not the board's: see "Known differences".

### Install

1. Unzip `Rabbit_MiSTer_20261020.zip` over the root of the SD card. It adds `Rabbit (Asia 3-6).mra` to `_Arcade/`, the
   other three to `_Arcade/_alternatives/_Rabbit/` and `_Arcade/cores/rabbit_20261020.rbf`.
2. Put your own MAME 0.289 romset `rabbit.zip` (the merged set holds all four versions) in `games/mame/`. No ROMs are
   included.
3. Start the game from the Arcade menu. The ROM image is 28 MB: with a recent Main_MiSTer it is copied to the DDR3 in one
   go and the core loads it from there in about 1.4 s (the MRAs' `address=` attribute); an older one streams it, with the
   same RBF and MRAs. The game's power-on RAM / ROM test then runs and its warning screen stays for two seconds, as on
   the board. Its settings and high scores are kept in the EEPROM, which MiSTer saves (`nvram`).

The OSD's version line reads `v261020`.

### Checked

- **ROM path:** `tools/make_mra.py` builds every MRA's image by the MiSTer MRA rules and compares it with the image
  `tools/rabbit_rom.py` builds by MAME's loading rules: identical for all four sets. The program, gfx1, gfx2 and sample
  regions are byte-identical to MAME's own memory regions.
- **The video chip against MAME 0.289** (`sim/run_frames.sh`, MAME's video state dumped by a Lua probe and rendered by the
  core's video pipeline with the real SDRAM path): **584 of 584 frames pixel-identical** to MAME's snapshots (240 of the
  attract mode to frame 6,000, 344 of scripted play to frame 9,000 with coin, start, the character select, fights with
  special moves and summoned beasts; 29 of them zoomed, down to MAME's full zoom-out). No line ran out of time.
- **The sound chip** (`sim/run_snd.sh`, the game's register writes in scripted play replayed): MAME's I5000 except for
  the sample rate, which it takes from register 0x46 as the game sets it. Against `tools/i5000_ref.py` (MAME's device in
  Python at the game's rate): loudness envelopes correlate 0.9999 on both channels, level within 0.2 %, every frequency
  band within 0.2 dB; the reference at MAME's rate against MAME's own `-wavwrite` recording: 0.9998, level within 0.6 %.
  The rate is the one a recording of a real board plays its samples at (to 0.05 %).
- **The whole machine** (`sim/run_sys.sh`: the 68020 running the game's program, blitter, sound and video behind the SDRAM
  controller and a behavioural SDRAM that checks its timing): it boots, reads its EEPROM and runs on MAME's timeline frame
  for frame: the work RAM at vblank is byte for byte MAME's at the same frame (the attract mode at 130-800, scripted play
  at every frame to 305), and the pictures are MAME's of the same frame (every frame of the attract mode 600-820 and of
  scripted play 291-421, every 50th of scripted play to 1600); its sound over those 1600 frames against MAME's recording
  of the same inputs: envelope correlation 0.99, level within 1 %. No SDRAM timing violation, no renderer overrun. (Those
  runs used MAME's sample rate; with the game's rate the attract mode is MAME's frame for frame to frame 650, then runs a
  few frames ahead of MAME in the same scenes, as the game waits for its sounds, which now end sooner, as on the board.)
- **The MiSTer top level** (`sim/emu/run_emu.sh`, `Rabbit.sv` with the framework's video path): the fast load and the
  streamed load both put the image in the SDRAM byte-identical to the expected layout, and the pictures the scaler gets
  are MAME's.
- **Quartus 17.0.2:** 45 % of the ALMs (18,976), 443 of 553 M10K, 43 DSPs; every clock's slack positive (the 96 MHz
  machine clock +0.827 ns setup, +0.034 ns hold; the tightest, +0.159 ns, is in the framework's HDMI scaler).
  `releases/rabbit_20261020.fit.summary` / `.sta.summary`.

### Controls

Four buttons (the game's A, B, C, D), Start, Coin, Service per player. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the
test switch (the game's settings; the board has no DIP switches).

### OSD

Aspect ratio, Scale, Scandoubler Fx, Volume, Swap stereo, Autosave EEPROM, Save EEPROM, Reset. See the README.

### Known differences / open points

- **The sound is not yet the board's.** The pitch is now right, but the samples are still decoded with MAME's OKI ADPCM,
  which their data does not fit (the signal sits at its limit 43 % of the time: the harsh, crunchy sound). The board's
  real decoding is unknown (MAME flags the game's sound as imperfect); `docs/hardware.md` "Sound" has what a recording
  of a real board shows. A clean recording of single sounds from a board would settle it.
- The board's frame rate seems to be about 57.6 Hz (the recording's attract mode runs 4.1 % slower than MAME's); the core,
  like MAME, runs at 60 Hz.
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
