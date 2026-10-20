# Rabbit for MiSTer

A MiSTer FPGA core for **Rabbit** (Aorn / Electronic Arts, 1997), the one-on-one fighting game on the VG5330-B board: a 68EC020 and
the Imagetek I5000, which is the video chip (four zooming tilemaps, a zooming sprite layer), a blitter and a 16-channel ADPCM sound chip
in one. Written from MAME 0.289's driver (`src/mame/metro/rabbit.cpp`, `src/devices/sound/i5000.cpp`), with MAME as the reference for
everything; the platform layer follows the Metro core ([decoryah/Arcade-Metro_MiSTer](https://github.com/decoryah/Arcade-Metro_MiSTer))
and the owner's Mystic Warriors core.

No ROMs or other copyrighted data are in this repository; you supply your own MAME `rabbit.zip`.

**Status.** Not yet run on a MiSTer. Simulated with the game's real program and compared with MAME 0.289 (see "What is verified").

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

Four buttons (the game's A, B, C and D) per player, Start, Coin, Service. Keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test
switch (the game's settings: it has no DIP switches). The settings and the high scores are kept in the board's EEPROM, which MiSTer saves
to the SD card (`<nvram>`): automatically when the OSD is opened after the game wrote it (Autosave EEPROM On) or with Save EEPROM. The
file is MAME's `nvram/rabbit/eeprom`, so settings can be copied between MAME and the core.

| Option | Values |
|---|---|
| Aspect ratio | Original (4:3), Full Screen, [ARC1], [ARC2] |
| Scale | Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ (the framework's integer scaling for HDMI) |
| Scandoubler Fx | None, HQ2x, CRT 25 / 50 / 75 % |
| Volume | Normal, -6 dB, -12 dB, +6 dB |
| Swap stereo | No, Yes |
| Autosave EEPROM, Save EEPROM | see above |

## What is verified

| | |
|---|---|
| ROM image | `tools/make_mra.py rabbit.zip` assembles every MRA's image (`tools/mra_build.py`, the MiSTer MRA rules) and compares it with the image `tools/rabbit_rom.py` builds by MAME's loading rules: identical for all four sets. The image's program, gfx1, gfx2 and sample regions are byte-identical to MAME's own memory regions (dumped from a running MAME with Lua) |
| Video against MAME 0.289 | `sim/run_frames.sh`: MAME's video state (tilemaps, sprite RAM, palette, registers) dumped at a frame by `tools/lua/dump_state.lua` and rendered by the core's video chip with the real SDRAM path, compared with MAME's snapshot of that frame: **584 of 584 frames pixel-identical**: 240 of the attract mode (every 25th frame to 6,000: the logos, the story, the demo fights) and 344 of scripted play (coin, start, character select, fights with special moves and the summoned beasts, to frame 9,000), 29 of them zoomed (down to MAME's full zoom-out). No line ran out of time |
| Sound against MAME 0.289 | `sim/run_snd.sh`: every write the game made to the I5000's registers in 3,000 frames of scripted play (`tools/lua/snd_log.lua`, with their times) replayed into the core's sound chip with the real SDRAM path, its output compared with MAME's `-wavwrite` recording of the same run (`tools/audio_cmp.py`): the loudness envelopes (RMS per frame) correlate **0.9997** on both channels with no lag, the level is within 0.6 %. In 1,000 frames of the attract mode every one of the game's 788 reads of the channel status gets the same value as in MAME |
| Whole machine | `sim/run_sys.sh`: the 68020 running the game's program, the blitter, the sound chip and the video chip behind the SDRAM controller and a behavioural SDRAM (which checks the timing: no tRC, tRP, tRRD, tRFC or tRAS violation in billions of clocks). It boots, reads its EEPROM and runs on MAME's timeline frame for frame: the work RAM at vblank is byte for byte MAME's at the same frame number (`tools/cmp_ram.py`; the attract mode at frames 130-800, scripted play at every frame to 305), and the pictures are pixel-identical to MAME's of the same frame (`tools/cmp_lag.py`, lag 0): every frame of the attract mode 600-820 and of scripted play 291-421 (coin, start, the character select), and every 50th of scripted play to 1600. Its sound over those 1600 frames against MAME's `-wavwrite` recording of the same inputs: envelope correlation 0.99, level within 1 % |
| MiSTer top level | `sim/emu/run_emu.sh`: `Rabbit.sv` with the framework's video path (`arcade_video`, scaler input), `hps_io` and the PLL stubbed, the DDR3 and SDRAM modelled: both the MRA's fast load (the image in the DDR3 at 0x32000000) and the streamed load leave the SDRAM byte-identical to the expected layout (1.39 s of machine time, the SDRAM's write rate), and the pictures the scaler gets are MAME's |
| Quartus 17.0.2 | 45 % of the ALMs (18,929), 443 of 553 M10K, 43 DSPs; every clock's slack positive (the 96 MHz machine clock +0.800 ns setup, +0.026 ns hold; the tightest, +0.686 ns, is the framework's HDMI scaler): `releases/rabbit_20261020.fit.summary` / `.sta.summary` |
| Lint | Verilator `-Wall` (`sim/lint.sh`) |

## Known differences / open points

* Not yet tested on a MiSTer.
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
| `modules/` | TG68K.C (vendored, with its GHDL conversion `gen/tg68k.v`) |
| `sys/` | the MiSTer framework |
| `mra/` | the MRAs (`tools/make_mra.py`) |
| `sim/` | Verilator benches: the whole machine (`run_sys.sh`), the frozen-state frame bench (`run_frames.sh`), the sound replay bench (`run_snd.sh`), the MiSTer top level (`emu/run_emu.sh`), lint |
| `tools/` | ROM image builder (`rabbit_rom.py`), MRA writer, MAME Lua probes (`lua/dump_state.lua` states and snapshots, `lua/snd_log.lua` sound register log, `lua/watch.lua` write watch) and the runner (`mame_dump.sh`), Python reference renderer (`rabbit_ref.py`), comparisons (`cmp_frame.py`, `cmp_lag.py`, `cmp_ram.py`, `audio_cmp.py`), release zip (`package.py`) |
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
* **decoryah/Arcade-Metro_MiSTer**: the SDRAM protocol and its simulation model (from searchsolved's Arcade-HyperDuel_MiSTer), the fast
  load, the 93C46 EEPROM, the standby raster.
* The owner's Mystic Warriors core: the TG68K bus sequencing and its timing constraints, the program cache, the bench conventions.
* The MiSTer framework (Sorgelig and contributors).

## Licence

GPL-3.0-or-later (`LICENSE`); vendored modules keep their own licences.
