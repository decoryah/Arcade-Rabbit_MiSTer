# Rabbit for MiSTer

A MiSTer FPGA core for **Rabbit** (Aorn / Electronic Arts, 1997), the one-on-one fighting game on the VG5330-B board: a 68EC020 and
the Imagetek I5000, which is the video chip (four zooming tilemaps, a zooming sprite layer), a blitter and a 16-channel ADPCM sound chip
in one. Written from MAME 0.289's driver (`src/mame/metro/rabbit.cpp`, `src/devices/sound/i5000.cpp`), with MAME as the reference for
everything; the platform layer follows the Metro core ([decoryah/Arcade-Metro_MiSTer](https://github.com/decoryah/Arcade-Metro_MiSTer))
and the owner's Mystic Warriors core.

No ROMs or other copyrighted data are in this repository; you supply your own MAME `rabbit.zip`.

**Status.** Runs on a MiSTer: tested by the repository owner, the game and all four versions work. Simulated with the game's real program and compared with MAME 0.289 (see "What is verified"). The sound is not yet the board's (see "Known differences").

## Install

1. Copy the RBF (`releases/rabbit_<date>.rbf`) to `/media/fat/_Arcade/cores/` and the contents of `mra/` to `/media/fat/_Arcade/`
   (the other versions are in `_alternatives/_Rabbit/`). Keep the RBF's `rabbit_` name: MiSTer finds the core by the MRA's `<rbf>`.
2. Put your MAME 0.289 `rabbit.zip` (the merged set holds all four versions) in `/media/fat/games/mame/`.
3. Start `Rabbit (Asia 3-6)` (or another version) from the Arcade menu. The image is 28 MB; a recent Main_MiSTer copies it to the DDR3
   in one go (the MRAs' `address=`) and the core loads it from there in about 1.5 seconds; an older one streams it.

| Set | MRA |
|---|---|
| `rabbit` | Rabbit (Asia 3-6) |
| `rabbita` | Rabbit (Asia 1-28) |
| `rabbitj` | Rabbit (Japan 3-6) |
| `rabbitjt` | Rabbit (Japan 1-28, location test) |

## Controls and OSD

Four buttons per player, Start, Coin, Service. The buttons are named as the game uses them: **Light Punch (A), Heavy Punch (B), Light
Kick (C), Heavy Kick (D)**; A to D are the game's own names (its input test, and texts such as the beast attack's "A, B, and C buttons
at the same time"), and which is which was measured in MAME 0.289: Wu-Ling's umbrella strikes on A and B, her kicks on C and D, the
damage on an idle opponent 4, 10, 5 and 11 pixels of the health bar. A pad's default layout puts the punches on the top face buttons and
the kicks on the bottom ones (Y X / B A), as the Saturn version has them. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test
switch (the game's settings: it has no DIP switches). The settings and the high scores are kept in the board's EEPROM, which MiSTer saves
to the SD card (`<nvram>`): automatically when the OSD is opened after the game wrote it (Autosave EEPROM On) or with Save EEPROM. The
file is MAME's `nvram/rabbit/eeprom`, so settings can be copied between MAME and the core.

| Option | Values |
|---|---|
| Aspect ratio | Original (4:3), Full Screen, [ARC1], [ARC2] |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ (the framework's integer scaling for HDMI) |
| Scandoubler Fx | None, HQ2x, CRT 25 / 50 / 75 % (and MiSTer.ini's `forced_scandoubler`: the core gives the scandoubler the horizontal blank on every line, vertical blank lines included, so its picture does not freeze) |
| CRT Adjust (page) | Off, On; H-Size 0 to +2 and -16 to -1, H-Position -48 to +16, V-Shift -16 to +15. rmonic79's CRT Adjust (`modules/crt-adjust`) for a 15 kHz analog output: the picture's size and place on the tube are changed through a line buffer while the sync pulses keep their timing, so the monitor stays locked. A size step is 1/60 of a dot (5.3 dots across the picture); +2 and +16 are the most that fit before the next hsync pulse. At 60 Hz the picture's left edge meets the hsync pulse past H-Position -39 (at 57.6 Hz past -56) and is cut there. It does nothing while the scandoubler is on (31 kHz) |
| Sound | Enhanced (the default), MAME: see "Known differences". MAME is MAME's sound exactly (for MAME's tempo too, set Refresh rate to 60 Hz) |
| Volume | Normal, -6 dB, -12 dB, +6 dB |
| Swap stereo | No, Yes |
| Refresh rate | 57.6 Hz (board, the default), 60 Hz (MAME): see "Known differences" |
| Autosave EEPROM, Save EEPROM | see above |

## What is verified

| | |
|---|---|
| ROM image | `tools/make_mra.py rabbit.zip` assembles every MRA's image (`tools/mra_build.py`, the MiSTer MRA rules) and compares it with the image `tools/rabbit_rom.py` builds by MAME's loading rules: identical for all four sets. The image's program, gfx1, gfx2 and sample regions are byte-identical to MAME's own memory regions (dumped from a running MAME with Lua) |
| Video against MAME 0.289 | `sim/run_frames.sh`: MAME's video state (tilemaps, sprite RAM, palette, registers) dumped at a frame by `tools/lua/dump_state.lua` and rendered by the core's video chip with the real SDRAM path, compared with MAME's snapshot of that frame: **584 of 584 frames pixel-identical**: 240 of the attract mode (every 25th frame to 6,000: the logos, the story, the demo fights) and 344 of scripted play (coin, start, character select, fights with special moves and the summoned beasts, to frame 9,000), 29 of them zoomed (down to MAME's full zoom-out). No line ran out of time. The KO fix, on consecutive frames (`SEQ=1`): two knockouts in MAME (one by the computer's 17-hit beast combo, one by the player's last hit), every frame of their slow motion: each frame with sprites is MAME's to the pixel, each count-0 frame shows the frame before's sprite list over its own picture |
| Sound: MAME mode | MAME's I5000 exactly (its fixed 39,062.5 Hz). `sim/run_snd.sh`: every write the game made to the I5000's registers in 100 s of the attract mode (`tools/lua/snd_log.lua`, with their times) replayed into the core's sound chip with the real SDRAM path, its output against MAME's `-wavwrite` recording of the same run (`tools/audio_cmp.py`): the loudness envelopes (RMS per frame) correlate **0.9999** on both channels with no lag, the level is within 0.7 %, and all **9,145** reads of the channel status answer what MAME answered |
| Sound: Enhanced mode | The same chip at the rate the game sets in register 0x46 (47,962 Hz, the board's pitch) and its mix through a filter: two 2-pole high-passes at 150 Hz and a 2-pole low-pass at 11 kHz (`rtl/rabbit_sndflt.sv`). The filter is checked bit for bit against its integer model in the sound bench (`ENH=1`, `tools/sndflt_ref.py`: 1.4 million samples a side in 30 s, no difference); the chip at this rate against `tools/i5000_ref.py` (MAME's device in Python with the game's rate): envelope correlation 0.9999, level within 0.2 %. Against a recording of a real board, 95 s of the attract mode: within 1.5 dB of the board's spectrum from 160 Hz to 2.5 kHz, the decoder's wander below 150 Hz cut by up to 30 dB (it stays 3-10 dB above the board's below 130 Hz) |
| Whole machine | `sim/run_sys.sh`: the 68020 running the game's program, the blitter, the sound chip and the video chip behind the SDRAM controller and a behavioural SDRAM (which checks the timing: no tRC, tRP, tRRD, tRFC or tRAS violation in billions of clocks). It boots, reads its EEPROM and runs on MAME's timeline frame for frame: the work RAM at vblank is byte for byte MAME's at the same frame number (`tools/cmp_ram.py`; the attract mode at frames 130-800, scripted play at every frame to 305), and the pictures are pixel-identical to MAME's of the same frame (`tools/cmp_lag.py`, lag 0): every frame of the attract mode 600-820 and of scripted play 291-421 (coin, start, the character select), and every 50th of scripted play to 1600. Its sound over those 1600 frames against MAME's `-wavwrite` recording of the same inputs: envelope correlation 0.99, level within 1 %. These runs use Sound: MAME (the bench's default; `ENH=1` for Enhanced); with this build the attract mode's work RAM is byte for byte MAME's at every dump from frame 130 to 820. With Enhanced (the game's rate) the attract mode is MAME's frame for frame up to frame 650; then the game, which waits for its sounds to finish, runs a few frames ahead of MAME in the same scenes (the samples end 23 % sooner, as on the board). At the board's 57.61 Hz (the default; `BOARD=1` in the bench) the frame period is 1,666,320 clocks and the run is the same: MAME's frame for frame (work RAM byte-identical at 130-600, pictures at every 50th frame to 650) |
| MiSTer top level | `sim/emu/run_emu.sh`: `Rabbit.sv` with the framework's video path (`arcade_video`, scaler input), `hps_io` and the PLL stubbed, the DDR3 and SDRAM modelled: both the MRA's fast load (the image in the DDR3 at 0x32000000) and the streamed load leave the SDRAM byte-identical to the expected layout (1.39 s of machine time, the SDRAM's write rate), and the pictures the scaler gets are MAME's. `sim/emu/run_modes.sh`, the video modes (24 runs, each checking every frame's period, the rows and lines of the raster, where the rows sit and the size asked of the scaler, and its pictures against the plain run's of the same frame): both refresh rates; Scandoubler Fx HQ2x, CRT 25 / 50 / 75 % and MiSTer.ini's `forced_scandoubler` at both rates give 448 rows in 524 lines, every frame whole, the same pictures (HQ2x's interpolated edges aside); CRT Adjust On is the plain picture to the clock, H-Size +2 and -16, H-Position +16 and -48, V-Shift +5 and -16 move and size the rows exactly as set with every frame whole and no pixel lost, and it stands aside under the scandoubler; Scale's five settings ask the scaler for the size the framework's rule gives (1920 x 1080 and 1280 x 720, Original and Full Screen, with HQ2x). Runs of 200 frames, into the attract mode where the picture changes, with `forced_scandoubler`, HQ2x and CRT Adjust (H-Size +1, H-Position -8, V-Shift +2): every frame whole, the pictures the plain run's at every 20th frame (CRT Adjust's one frame along in the bench's count, as its V-Shift moves the sync earlier; the first picture of the game appears at the same moment in every mode: CRT Adjust adds a line of delay, not a frame) |
| Quartus 17.0.2 | 47 % of the ALMs (19,556), 446 of 553 M10K, 44 DSPs; every clock's slack positive (the 96 MHz machine clock +0.295 ns setup, +0.252 ns hold; the framework's HDMI scaler +0.234 ns setup; fitter seed 4): `releases/rabbit_20261021.fit.summary` / `.sta.summary` |
| Lint | Verilator `-Wall` (`sim/lint.sh`) |

## Known differences / open points

* **The sound's decoding is still MAME's** (MAME flags Rabbit's sound as imperfect; `docs/hardware.md` "Sound" has the details):
  OKI ADPCM, which the sample data does not fit (the signal sits at its clamp 43 % of the time: the harsh, crunchy sound, a large
  wander below 150 Hz, and noise where the board's notes have died away). The real decoding is not known; a clean recording of single
  sounds from a board (the test mode's sound test, line out) would settle it. Meanwhile the OSD's Sound option offers two versions:
  **MAME**, MAME's device exactly (its 39,062.5 Hz: every sound 23 % slow, 3.5 semitones flat), and **Enhanced** (the default): the rate
  the game sets in register 0x46 (47,962 Hz, which a recording of a real board confirms to 0.05 %) and a filter that cuts the decoder's
  rumble below 150 Hz and the hiss above 11 kHz. Enhanced is still MAME's decoding, not the board's.
* **Sprites in a KO's slow motion** (MAME Testers 04883, "Missing sprites during KO"). In MAME the fighters vanish during the slow
  motion after a knockout: the game ends its sprite list with a count of 0 on every other frame there, and MAME then draws no sprites.
  The core shows the frame before's sprites on such a frame (once: a second 0 in a row is no sprites). The game's own data says why:
  in the slow motion it alternates its normal picture with a flash frame (the stage's layers put in front of everything) and writes the
  count of 0 on the frames before the flash frames, which only makes sense if the chip shows its sprites one frame late (a
  double-buffered sprite frame buffer). The fix gives exactly that picture here, and changes no other frame (`docs/hardware.md`
  "Sprites"). Not checked against a real board.
* **The frame rate.** MAME runs the game at 60 Hz, a placeholder (its screen for this driver is a made-up 1024-line one). The board's
  video comes from the I5000's 40 MHz oscillator (it has only that and the 68020's 24 MHz), and in a recording of a real board the
  attract mode runs 4.1 % slower than in MAME: about 57.6 Hz, which a 40 MHz raster of 263 lines gives as 57.61 Hz. The core runs at
  57.61 Hz by default (424 dots a line, 15.09 kHz) and at 60.02 Hz with "Refresh rate: 60 Hz (MAME)" (407 dots, 15.72 kHz). The game
  counts frames, so it is the same frame for frame at either rate, only slower in time at the board's; the comparisons with MAME in
  "What is verified" were made at 60 Hz.
* The 68020 is TG68K.C, which is not cycle exact. Its pacing (a token bucket, `docs/hardware.md` "CPU") is calibrated on the power-on
  RAM / ROM test, the one stretch where the game has no slack and whose end fixes the game's whole timeline; elsewhere the core's 68020 is
  not MAME's to the microsecond (in the game code after vblank in scripted play about 10 % faster). That shows where the game races
  itself: from frame 306 of scripted play its blit queue (`docs/hardware.md` "Blitter") sometimes starts a frame's two blits from the
  previous blit's interrupt instead of after the next vblank, so a queue index and 16 marker words in the work RAM differ from MAME's.
  Those blits rewrite the same tiles every frame, and the pictures are MAME's.
* The snapshot of the video state at vblank (43 us) holds the CPU's video accesses, so the game's post-vblank work starts about 22 us
  later than in MAME.
* The ROM check of the test mode reads the graphics ROMs through a banked window at 440000; MAME does not implement the bank (it shows
  bank 0 always), and neither does the core, so the check reports the same as in MAME.

## Repository layout

| Path | |
|---|---|
| `Rabbit.sv`, `Rabbit.q*`, `Rabbit.sdc`, `files.qip` | the MiSTer top level (`emu`), Quartus project, timing constraints |
| `rtl/` | the machine: `rabbit_core` (the board), `rabbit_main` (68020 bus), `rabbit_video` (the video chip: snapshot, mixing, raster) with `rabbit_tilegen` and `rabbit_sprgen`, `rabbit_blitter`, `rabbit_i5000` (sound), `rabbit_eeprom`, `rabbit_cache` (program cache); the platform: `rabbit_sdram`, `rabbit_loader`, `rabbit_fastload`, `rabbit_standby` |
| `modules/` | vendored: TG68K.C (with its GHDL conversion `gen/tg68k.v`), rmonic79's CRT Adjust (`modules/VENDOR.md`) |
| `sys/` | the MiSTer framework |
| `mra/` | the MRAs (`tools/make_mra.py`) |
| `sim/` | Verilator benches: the whole machine (`run_sys.sh`), the frozen-state frame bench (`run_frames.sh`), the sound replay bench (`run_snd.sh`), the MiSTer top level (`emu/run_emu.sh`, and its video modes `emu/run_modes.sh`), lint |
| `tools/` | ROM image builder (`rabbit_rom.py`), MRA writer, MAME Lua probes (`lua/dump_state.lua` states and snapshots, `lua/snd_log.lua` sound register log, `lua/watch.lua` write watch) and the runner (`mame_dump.sh`), Python reference renderer (`rabbit_ref.py`), comparisons (`cmp_frame.py`, `cmp_lag.py`, `cmp_ram.py`, `audio_cmp.py`), MAME's I5000 in Python with the game's sample rate (`i5000_ref.py`), the Enhanced sound's filter bit for bit (`sndflt_ref.py`, which also generates its coefficients), release zip (`package.py`) |
| `docs/hardware.md` | the hardware as MAME describes it, the game's timing, and the core's design |

## Building

Quartus Prime Lite 17.0.2:

    quartus_sh --flow compile Rabbit

Copy `output_files/Rabbit.rbf` to `releases/rabbit_<YYYYMMDD>.rbf`; `python3 tools/package.py` then writes the SD card zip
(`dist/Rabbit_MiSTer_<YYYYMMDD>.zip`: the RBF and the MRAs in MiSTer's folders).

The benches need Verilator 5 (in WSL), Python 3 and your romset:

    python3 tools/rabbit_rom.py rabbit.zip rabbit rabbit.rom --sdram rabbit.sdram --eeprom rabbit.nv
    SNAPEVERY=50 TRACE=1 sim/run_sys.sh rabbit.sdram rabbit.nv 600 out/r      # pictures out/r.f<frame>.ppm
    tools/mame_dump.sh corpus "250,600,1500"                                    # MAME's states and snapshots (Git Bash)
    sim/run_frames.sh corpus rabbit.sdram                                       # render them, compare with MAME

## Credits

* **MAME**: the rabbit driver (David Haywood), the I5000 sound device (hap), the OKI ADPCM decoder; the hardware knowledge and the
  reference for every comparison.
* **Tobias Gubener**: TG68K.C (LGPL-3.0).
* **rmonic79 (Umberto Parisi)**, with Andrea Bogazzi (asturur): CRT Adjust (GPL-3.0-or-later).
* **decoryah/Arcade-Metro_MiSTer**: the SDRAM protocol and its simulation model (from searchsolved's Arcade-HyperDuel_MiSTer), the fast
  load, the 93C46 EEPROM, the standby raster.
* The owner's Mystic Warriors core: the TG68K bus sequencing and its timing constraints, the program cache, the bench conventions, the
  CRT Adjust glue and the scandoubler's blanking rule.
* The MiSTer framework (Sorgelig and contributors).

## Licence

GPL-3.0-or-later (`LICENSE`); vendored modules keep their own licences.
