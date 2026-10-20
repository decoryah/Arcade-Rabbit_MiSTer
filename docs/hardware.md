# Rabbit: the hardware as MAME 0.289 describes it, and how the core implements it

Everything here comes from MAME 0.289's `src/mame/metro/rabbit.cpp` (David Haywood) and `src/devices/sound/i5000.cpp` (hap), from the
game's program (disassembled with MAME's `unidasm`) and from MAME runs probed with Lua. MAME is the reference for every behaviour,
including the ones it marks as guesses; where the core departs from it, this file says so.

## 1. The board

| | |
|---|---|
| CPU | MC68EC020 at 24 MHz (24-bit address bus) |
| Video, blitter, sound | Imagetek I5000 (40 MHz) |
| EEPROM | 93C46, 16-bit organisation |
| PCB | VG5330-B; the program in four byte-wide 512 KB ROMs (JPR0-3), sprites + blitter data in four 4 MB ROMs (JFV0-3), tiles in three 2 MB ROMs (JBG0-2), samples in a 4 MB ROM (JSN0) |

MAME's screen is 60 Hz with a 1024-line frame (a placeholder: vblank time 0, visible area 320 x 224 at the top), and the whole picture is
drawn at the start of vblank (`screen_update`), after which the vblank interrupt is raised.

## 2. The 68EC020's map (`rabbit_map`)

| Address | | |
|---|---|---|
| 000000-1fffff | R | program ROM |
| 200000-200003 | R | INPUTS: bit 0 the EEPROM's DO (active high), 1 unknown, 2 / 3 start 1 / 2, 4 service 1, 5 the test switch, 6 / 7 coin 1 / 2, 15:8 player 1 (up, down, left, right, buttons 1-4), 23:16 player 2, all active low |
| 200000 | W | EEPROM: only a write of the top byte alone (`mem_mask == ff000000`): DI bit 24, CLK bit 25, CS bit 26 |
| 400010-400013 | R | MAME returns `machine().rand()`. The game reads only 400012 and only bit 7, in the blit-done handler (5e6c): it waits for the bit to clear before starting the next blit. The core returns the blitter's busy flag there and 0 elsewhere |
| 400010 / 400012 | W | written by the game as an interrupt enable mask / acknowledge (the vblank handler writes 8 to 400012, the blit-done handler 0x20); MAME ignores both, so does the core |
| 400100-400177 | W | tilemap registers, 6 dwords per layer at 400100 + 0x20 * layer (write-only: reads give 0) |
| 400200-40021b | W | sprite registers, 7 dwords |
| 400300 | W | ROM bank of the readback window (MAME: not hooked up, bank 0 always; so is the core) |
| 400400-400413, 400500, 400800-40080f, 479700-479713 | W | registers with no known use (ignored) |
| 400700-40070f | W | blitter registers; a write to the fourth dword starts a blit (the game writes a word to 40070e) |
| 400900-4009ff | RW | I5000 sound registers (16-bit, only whole-word writes) |
| 440000-47ffff | R | gfx1 readback window: bank 0 of the region, read as MAME's little-endian host sees it (the CPU's high word = bytes 3, 2) |
| 480000-48ffff | RW | tilemaps 0-3, 16 KB (4096 entries) each |
| 494000-497fff | RW | sprite RAM |
| 4a0000-4affff | RW | palette, 16384 xGRB_888 dwords |
| ff0000-ffffff | RW | work RAM |

Interrupts (autovectored, held until acknowledged as MAME's HOLD_LINE): level 6 at the start of vblank, level 4 500 us after a blit was
started. MAME's comment lists 5 and 1 as "also valid": the game's vectors for them exist, nothing raises them.

## 3. Tilemaps

Four layers of 128 x 32 tiles: 0-2 of 16 x 16 pixels (2048 x 512), 3 of 8 x 8 (1024 x 256). An entry (`get_tilemap_info`):

| bits | |
|---|---|
| 31 | colour mask: a 4bpp tile's colour & 0x3f (the health bars) |
| 30:29 | `TILE_FLIPXY`, which swaps them: **30 = flip X, 29 = flip Y** |
| 28 | depth: 8bpp |
| 27:20 | colour |
| 19:16 | bank: 8 adds 0x10000 to the tile number, C adds 0x20000, the others nothing |
| 15:0 | tile |

The tile number counts 32-byte units of gfx2: a tile's row is at `(code & ~(units - 1)) * 32 + row * rowbytes` (16x16x4: 128 bytes, rows of
8; 16x16x8: 256 / 16; 8x8x4: 32 / 4; 8x8x8: 64 / 8). 4bpp tiles: nibble-packed, the low nibble first; pen 15 transparent; palette
`0x2000 + colour * 16 + pen`. 8bpp tiles: a byte a pixel; pen 255 transparent; palette `0x2000 + (colour & 0xf) * 256 + pen`.

Each layer is drawn with `draw_roz` from its registers: dword 1 = Y scroll (high half) / X scroll (low half), both 12.4 fixed point;
dword 3 bits 11:0 = the X step, dword 4 bits 27:16 = the Y step, 1.11 fixed point (0x800 = 1:1; the game zooms out to 0xC60). Screen pixel
(x, y) shows map pixel

    column ((sx * 128 + x * incxx) >> 11) mod width,   row ((sy * 128 + y * incyy) >> 11) mod height

(MAME takes the plain tilemap path when both steps are 0x800, which draws the same pixels). dword 0 bits 27:24 are the layer's priority.

## 4. Sprites

Sprite RAM holds pairs of dwords: dword 0 bits 11:0 x (signed), 27:16 y, 15 flip X, 14 flip Y; dword 1 bits 16:0 tile, 27:20 colour.
Sprite register 5 bits 27:16 is the number of sprites; MAME draws them from the last to the first (the first is on top) into a 4096 x 4096
bitmap at (x + 24, y - 24), mirrored when the flip X bit is **clear** (MAME's `!xflip`, marked "wrongdecode?"), with pen 15 transparent and
the value `colour * 16 + pen` (0 counts as transparent later: a pen 0 of colour 0 erases what is below it). A tile is 16 x 16 4bpp
(`sprite_16x16x4_layout`): 64 bytes in each half of gfx1, pixels 0-7 of a row from the upper half, 8-15 from the lower, each 4-byte group's
pixels in the order byte 1 high / low, byte 0 high / low, byte 3, byte 2.

The bitmap is copied to the screen through a window (`draw_sprite_bitmap`): with zc = (sprite reg 1 & 0x1ff) >> 1,

    startx = (reg0 & 0xfff) - zc,  starty = ((reg1 >> 16) & 0xfff) - zc,  xsize = (reg2 & 0xffff) + 0x80,  ysize = (reg3 & 0xffff) + 0x80
    xstep = 0xa0000000 / xsize,  ystep = 0x70000000 / ysize

window column i (0 .. ceil(xsize / 128) - 1) is bitmap column (startx + i) & 0xfff and lands on screen x = (i * xstep) >> 16, window row j
on y = (j * ystep) >> 16, every non-zero pixel over what was there (so zoomed out, the last of the window pixels that land on one screen
pixel wins). Unzoomed the registers are 9f80 / 6f80 (a 320 x 224 window); the game zooms out to f6ba / ac7a.

MAME clears only a 650 x 600 part of its bitmap each frame (around the window's corner); every window the game uses lies inside it, so
the stale pixels outside never show. The core draws only the window.

## 5. Mixing and palette

`screen_update` fills the screen with black, then for each priority level from 15 down to 1 draws the tilemaps of that level in the order
3, 2, 1, 0, and at level 9 (after the tilemaps of level 9) the sprites; a layer of priority 0 is never drawn. The game uses layers 0-2 at
10, layer 3 (the text) at 8 or 14. The palette is xGRB_888: G in bits 23:16, R in 15:8, B in 7:0. Only entries 0x0000-0x0fff (sprites) and
0x2000-0x2fff (tiles) can be shown.

## 6. Blitter (`do_blit`)

Registers: dword 0 bits 19:0 the command list's first word in gfx1; dword 1 bits 23:16 the start column, 7:0 the start line; dword 2 bits
15:13 the tilemap, bit 0: 1 = write the entries' low halves (the tile number), 0 = the high halves. A word of gfx1 is little-endian (the
even byte is the low one). A command word's low byte is a count, its high byte the command: 00 with count 0 ends the list (and arms the
500 us timer of IRQ 4); 00 copies `count` words; 02 writes the next word `count` times; 03 returns to the start column of the next line;
anything else does nothing. The entry written is line * 128 + column; after each write the column counts on modulo 128 (the start column
itself is 8 bits). MAME does the whole list at the moment of the starting write.

The game queues blits and starts each from the previous one's interrupt, so with MAME's fixed 500 us a frame's tilemap updates are spread
over several milliseconds after vblank.

The queue: 128 entries of 16 bytes at ff5cee (the three blitter dwords, a word, the starting word), ff5cec the next entry to start, ff5ced
the next free one. 5ef4 queues an entry (its word +12 cleared). IRQ 4's handler (5e60) waits for the busy bit, then starts the next entry
if there is one; when the queue has run dry the chain stops, and the main loop restarts it once after the next vblank (1023a:
`jsr $5eba` if the queue is not empty, without looking at the blitter; 5eba also sets the entry's word +12 to 1). So the frame a blit is
done in can hang on the CPU's speed: when the game queues its blits shortly after the chain's last interrupt, they wait for the next
frame; shortly before, the interrupt starts them in this one.

## 7. Sound (`i5000snd_device`)

16 channels at 40 MHz / 1024 = 39062.5 samples per second. Per channel: the sample's address (registers 4n, 4n + 1), frequency (4n + 2:
a code is decoded every `(0x1ff - d[7:0]) << (~d[9:8] & 3)` / freq_min samples, freq_min = 0x100 for 4-bit and 0x140 for 3-bit codes),
volume (4n + 3: right d[7:0], left d[15:8] through `2047 / 1.032^v`, 255 silent). 0x42 written: key on (channels not playing); read: the
playing channels. 0x43: key off. A sample is `7f7f`, a format word (0104 / 0304: 3-bit codes, else 4-bit), two more words, then the data
(little-endian words, codes from the low bits up, OKI ADPCM), ended by a `7f7f` word. A channel's output is `signal * volume / 128`
(C division), the mix is scaled by 32768 * 16 to full range. Output 0 is the right speaker, output 1 the left.

MAME flags the game's sound as imperfect, and its device notes the ADPCM type and the volume balance as unverified. Compared with a
recording of a real board (the attract mode on YouTube, "[Arcade PCB] Rabbit Just play (Not MAME)", AAC 44.1 kHz, matched against MAME's
register log of the same attract mode):

* **The sample rate** (used by the core). At boot the game writes `0x85a0` to register 0x46 (its sound driver at 1fc85a builds it as
  0x8000 + (1 << 10) + 416), and the other global registers 0x40 = `000c`, 0x41 = `0020`, 0x45 = `ffff`; MAME ignores them. With
  rate = 40 MHz / (2 * (d[9:0] + 1)) = 47,962 Hz the board's samples line up with the ROM data: a solo sample's harmonic structure
  correlates 0.95 with the recording at 1.2280 x MAME's rate, which is 47,970 Hz (the capture's own clock limits it to about 0.05 %);
  MAME's 39,062.5 Hz plays every sound 23 % slow, 3.5 semitones flat. The music's other frequency settings scale the same way, so the
  frequency formula is otherwise MAME's. The core takes the rate from register 0x46 (MAME's until the game writes it). Register 0x41
  reads as a busy flag (bit 15) that the driver waits on; MAME's 0 is fine.
* **The decoding** (not solved; the core keeps MAME's). MAME's OKI ADPCM sits at its 12-bit clamp for 43 % of every decoded sample: the
  data's codes are not OKI's. They are differential (their autocorrelation is +0.56 at lag 1, 0.07 at lag 2, negative at 3-5, not that
  of PCM), sign-magnitude with code 8 the smallest negative step, and magnitude 7 piles up in same-sign runs (15 % of all codes, 45 % of
  them followed by another 7; slope overload). No integrating decoder of the OKI family (step tables with ratios 1.05-1.2 and 49 or 89
  entries, index tables from (-1, 2, 4, 6, 8) down to (-1, 1, 1, 2, 2) and with larger decrements, 16-bit signal) rebuilds the samples
  cleanly: each either clips 5-10 % of the time or wanders (90 % of the energy below 40 Hz). Fitting the recording's waveform with a free
  filter does not separate the candidates either (R^2 0.73-0.79 for all of them on the recording's cleaner right channel). A clean
  recording of single sounds from a board (the test mode's sound test, line out) would decide it.
* **The decoding, with the Saturn version as a reference.** The Saturn port (1997, CD) has the music as CD audio: track 13 is the
  attract intro, the arcade's single sample 0bbc77, as a clean 16-bit mono recording (its spectrogram matches the board recording's
  intro at 0.90; it plays 0.2 % slower). It is not the arcade data's source sample for sample (codes and waveform agree in sign 55 % of
  the time), but as a clean reference it settles two things. (1) The prediction: the spectrum of the code values over the CD's
  spectrum follows |1 - z^-1|^2 from 400 Hz to 10 kHz to 1-2 dB (+5.6 dB at 1.9 kHz, +14 dB at 4.8 kHz, re 1 kHz): the codes are
  first-order differences, as in MAME (and not PCM). (2) The step: per 20 ms window, the level of the reference's x[n] - x[n-1]
  minus the codes' level is the chip's step over time. On the board recording (the real chip) it rises 7 dB in the first 0.2 s, holds
  within +-2 dB from 0.2 to 3.2 s while the code mix varies, then falls 12 dB by 3.85 s with the codes' sizes unchanged; where the CD
  is silent MAME's decoding is 2 dB below full scale. Not found: a step rule of the OKI kind that fits. Of 158,160 first-order
  decoders (index tables for magnitudes 0-7, step ratios 1.03-1.2, 24-88 steps, no clamp on the sum) every one wanders over the
  ROM's samples (at least 91 % of the energy below 40 Hz); rules that hold the jingle steady cannot also give the board's bass notes
  their decay (about -14 dB in 125 ms). Something structural is still unknown (a leak in the sum, or a step that depends on more than
  the code). The Saturn disc's voice files (16-bit PCM) and sound banks do not hold the arcade samples sample for sample either
  (sign searches at chance level).
* **The output**. The I5000 feeds a Toshiba TC9250P (photographs of boards): a 16-bit two-channel resistor-string DAC taking serial
  data at 1-8 fs, with no digital filter, so the chip's output is 16-bit stereo and all smoothing is analog. The board low-passes it,
  roughly two poles at about 3 kHz (the recording against the decoded data: flat to 2.5 kHz, -8 dB at 3.2 kHz, -12 dB at 4 kHz), with a
  bass cut below about 200 Hz (possibly the recording's), into a Toshiba power amplifier for the JAMMA speaker.
* **The frame rate**. The recording's attract mode runs 4.1 % slower than MAME's 60 Hz (the attract loop: 69.5 s against 67 s), so the
  board's vblank is about 57.6 Hz (57.64 +- 0.1); MAME's screen for this driver is a placeholder. The board has two oscillators, 40 MHz
  next to the I5000 and 24 MHz for the 68020, so its raster comes from 40 MHz: any 15 kHz layout of 263 lines that fits (40 MHz / 6 x
  440 dots, / 4 x 660, / 5 x 528) gives 57.61 Hz. The core's raster offers both (see "Clocks and raster").
* 31 of the 485 samples end with `7f7f`, a command word `xx07` and a negative word (`febc` etc.), then the usual `7f7f 0000`: probably
  a loop back by that many words (MAME and the core end the sample there). In scripted play one of them is played (01dbc6, 87 times in
  3,000 frames).

## 8. The game's timing, and why the core keeps two copies of the video state

Probed in MAME (a write tap on every video memory and register, with the beam line): the game writes its video registers and most of the
palette right after the vblank interrupt, but the sprite list 4-8 ms later and the tilemaps (by blitter and by CPU) 0.5-8 ms later. In
MAME's 1024-line frame that is all still vblank, and the frame is drawn at the next vblank start from whatever is there. On a 262-line
raster the same writes would land in the middle of the picture. So the core keeps the CPU's copies of the tilemaps, sprite RAM, palette and
registers and the display's copies, and at the start of vblank copies the one to the other (all memories at once, 4096 clocks = 43 us,
after a running blit has finished; the CPU's accesses to the video chip and new blits wait meanwhile). Every line of the next picture is
drawn from the copy: the frame MAME shows.

The 68020 spends about half of each frame in its idle loop (101f2: `tst.b (-$2c3a,A5); bne`; MAME counts ~17,000 iterations a frame in the
attract mode).

## 9. The core

### Clocks and raster

96 MHz everywhere. Dots of 15 clocks (6.4 MHz), 262 lines, 320 x 224 visible, hsync dots 336-367, vsync lines 232-234; a line is
424 dots with "Refresh rate: 57.6 Hz (board)", the default (15.09 kHz, 57.61 Hz, the board's rate), or 407 with "60 Hz (MAME)"
(15.72 kHz, 60.02 Hz). IRQ 6 and the snapshot at the start of line 224. The game's logic counts frames, so it is the same frame for
frame at either rate; the longer line only gives the renderer's stages more time.

### Rendering (rtl/rabbit_video.sv)

A line is made in three steps of one line time (6105 clocks) each:

* stage A (two lines ahead): `rabbit_tilegen` reads, for each enabled layer, the tilemap row the line samples and the tiles of the span of
  columns the 320 pixels sample (at most 640 pixels at full zoom-out), fetches their rows from the SDRAM and writes them, decoded, into
  the layer's source line (1024 pixels by map column mod 1024). `rabbit_sprgen` finds the window rows that land on the line (none, one,
  or up to three zoomed out), clears their window, scans the sprite list from the last sprite to the first and draws the rows of every
  sprite that covers them (4-word SDRAM bursts, 4 pixels a clock).
* stage B (one line ahead): the layers and the sprite rows are drawn into the line in MAME's order, each opaque pixel over what is there:
  a layer by stepping its source line at its zoom step (a pixel a clock), the sprites by MAME's forward mapping of window columns.
* stage C: the line through the palette to the screen.

The benches count lines whose stage A or B was not finished in time; none has been seen.

### Memory (rtl/rabbit_sdram.sv, rtl/rabbit_loader.sv)

The image (`tools/rabbit_rom.py`, the MRAs) is 0x1C00080 bytes: program 2 MB, gfx1 16 MB, gfx2 6 MB, samples 4 MB, the EEPROM's 128
bytes. The SDRAM (32 MB) holds it at byte address = image offset, except that in gfx1 the bit that selects the half moves next to bit 2, so
a sprite row (4 bytes from each half) is one 4-word burst. The controller is the Metro core's protocol (close page, CAS latency 2, READs
one a clock in the open row, a refresh every 7.8 us) with six read clients, in priority order: sound words, the program cache's 8-word line
fills, the CPU's gfx1 readback, tile rows, sprite rows, the blitter's word pairs. The 68020's program goes through a 32 KB direct-mapped
cache (`rabbit_cache.sv`).

Block RAM: work RAM 64 KB; the CPU's tilemaps, sprites, palette (64 + 16 + 64 KB) and the display's copies (64 + 16 + 24 KB); line
buffers; the cache.

### CPU (rtl/rabbit_main.sv)

TG68K.C with `CPU = 11` (68020: 32-bit multiply / divide, bit fields, the extended addressing modes the game uses everywhere; a trace
of MAME shows `mulu.l`, `muls.l`, `divs.l`, `divu.l`, `extb.l`, `bfextu`, `bfins` executed). Its bus is 16 bits wide, so a long
access is two word cycles. The kernel steps at most once every four clocks (the multicycle constraint); the program cache answers a hit
in the clock after the step's request; and a token bucket paces the steps: a bus step costs 47/8 clocks, an internal one 40/8.

The pacing is calibrated on the only stretch where the game's 68020 has no slack: the power-on RAM / ROM test (MAME frames 0 - 7). After
it the game waits out a fixed 120-frame warning screen, so the frame in which the test ends fixes the game's whole timeline. MAME's ends
76 % into frame 6 (the wait loop at 287c counts 6,629 of a full frame's 27,675 iterations there); with this pacing the core's ends 73 %
into frame 6, and the work RAM is then byte for byte MAME's at the same frame numbers (`tools/cmp_ram.py`). Without the cache's fast
answer the test ended a frame late and every later frame of the core was one behind MAME; at full speed it ended a frame early. Elsewhere
the game waits for vblank in its idle loop at 101f2 about half of every frame in MAME (~17,000 iterations; the core ~28,800).

Where the core is not MAME's (measured with the write watches, `tools/lua/watch.lua` and `sim/tb_top.sv` `+WATCHLO/+WATCHHI`, and the
bench's `+STEPSTATS` step counts): in scripted play, frame 305, the game code from the blit start at 5eea to the queueing at 5f1a takes
the core 995 us (13,917 steps: 58 % opcode fetches, 15 % reads, 12 % writes, 15 % internal; 71 % of the clocks waiting for tokens, 14 % for
the bus) and MAME 1,109 us: the core is 10 % fast there. The calibration stretch is different: the ROM checksum misses the program cache
all the time, so 21-27 % of the core's clocks there wait for the SDRAM (2.8 % of its steps are writes), while MAME's memory has no
latency at all. The step costs that make the core's power-on test as long as MAME's therefore make stall-free game code a little short.
A closer fit needs a second calibration point in game code (or a cache that hides its fills), which would move the costs: the
timeline (the frame the power-on test ends in) has only ~0.5 % of slack. The blit-queue race of section 6 is where this shows.
