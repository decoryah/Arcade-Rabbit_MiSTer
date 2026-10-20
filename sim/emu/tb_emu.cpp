// The MiSTer top-level bench's driver (sim/emu/run_emu.sh): plays the HPS for Rabbit.sv.
//   Vtb_emu_top <image.rom> <expected.sdram> <frames after the load> <out prefix>
// FAST=1: the MRA's address= fast load (the image put into the DDR3 at byte 0x32000000, then a download that carries only the length);
// otherwise the image is streamed through the ioctl port a byte at a time, honouring ioctl_wait. After the load every byte of the SDRAM
// is compared with the expected layout (tools/rabbit_rom.py --sdram); then the machine runs and every SNAPEVERY-th picture the scaler gets
// (VGA_* on CE_PIXEL with VGA_DE) is written as <prefix>.f<n>.ppm, n counted from the machine's start, and the raster is checked: the
// frame period, the rows and lines of a frame, where the rows sit, and the size the core asks of the HDMI scaler (Scale).
// PRELOAD=1: no load at all, the SDRAM and the EEPROM hold what a load leaves from the start (the video-mode runs, run_modes.sh).
// The OSD and the framework's settings, set before the load (after the Mystic Warriors core's bench):
//   MAME=1        Refresh rate 60 Hz (MAME); otherwise the board's 57.6 Hz
//   FX=n          Scandoubler Fx (0 None, 1 HQ2x, 2-4 CRT 25/50/75 %); FSD=1 MiSTer.ini's forced_scandoubler
//   CRT=1 HSIZE=n HPOS=n VSHIFT=n   CRT Adjust and its values as the OSD menu counts them
//   SCALE=n (0 Normal, 1 V-Integer, 2 HV-Integer, 3 Narrower HV-Integer, 4 HV-Integer+), AR=n (Aspect ratio), HW / HH the scaler's size
#include "Vtb_emu_top.h"
#include "Vtb_emu_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>

static Vtb_emu_top *t;
static uint64_t cyc = 0;
static void tick() { t->CLK_50M = 1; t->eval(); t->CLK_50M = 0; t->eval(); cyc++; }
#define HPSV(n) t->rootp->tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__##n

static const int VIS_W = 320, VIS_H = 224;

static std::vector<uint8_t> slurp(const char *fn) {
    std::vector<uint8_t> v;
    FILE *f = fopen(fn, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", fn); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(v.data(), 1, v.size(), f) != v.size()) exit(2);
    fclose(f);
    return v;
}
static int env(const char *n, int d = 0) { return getenv(n) ? atoi(getenv(n)) : d; }
static void set_status(int bit, int v) {
    int w = bit / 32, b = bit % 32;
    unsigned x = HPSV(r_status)[w];
    HPSV(r_status)[w] = v ? (x | (1u << b)) : (x & ~(1u << b));
}
static void set_field(int lo, int w, int v) { for (int i = 0; i < w; i++) set_status(lo + i, (v >> i) & 1); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: Vtb_emu_top <image.rom> <expected.sdram> <frames> <prefix>\n"); return 2; }
    std::vector<uint8_t> img = slurp(argv[1]), sd = slurp(argv[2]);
    int frames = atoi(argv[3]);
    std::string prefix = argv[4];
    bool fast = env("FAST");
    int snapevery = env("SNAPEVERY", 10);
    unsigned errors = 0;
    t = new Vtb_emu_top;
    auto &R = *t->rootp;
    t->HDMI_WIDTH = env("HW", 1920); t->HDMI_HEIGHT = env("HH", 1080);
    t->eval();   // the first evaluation applies the initial values (the stub's status word among them): the settings go in after it

    // ---------------------------------------------------------------- the OSD and the framework's settings
    const bool mame = env("MAME");
    if (mame) set_status(14, 1);                                    // Refresh rate: 60 Hz (MAME)
    const int fx = env("FX"); const bool fsd = env("FSD");
    set_field(3, 3, fx);                                            // Scandoubler Fx
    if (fsd) HPSV(r_fsd) = 1;                                       // MiSTer.ini's forced_scandoubler
    const bool sd_on = fx || fsd, sd_hq = fx == 1;
    const int sd_mul = sd_on ? (sd_hq ? 4 : 2) : 1;                 // the scandoubler: every line twice, HQ2x also twice as wide
    const bool crt = env("CRT"), vshift = crt && env("VSHIFT");
    if (crt) set_status(35, 1);                                     // CRT Adjust: [40:36] H-Size, [47:41] H-Position, [52:48] V-Shift
    if (getenv("HSIZE")) { int v = env("HSIZE"); set_field(36, 5, v >= 0 ? v : 19 + v); }
    if (getenv("HPOS"))  { int v = env("HPOS");  set_field(41, 7, v >= 0 ? v : 65 + v); }
    if (getenv("VSHIFT")) set_field(48, 5, env("VSHIFT") & 31);
    if (getenv("SCALE")) set_field(32, 3, env("SCALE"));
    if (getenv("AR")) set_field(121, 2, env("AR"));
    printf("settings: %s, Scandoubler Fx %d, forced_scandoubler %d, CRT Adjust %s (H-Size %d, H-Position %d, V-Shift %d), Scale %d, Aspect %d\n",
           mame ? "60 Hz (MAME)" : "57.6 Hz (board)", fx, (int)fsd, crt ? "On" : "Off", env("HSIZE"), env("HPOS"), env("VSHIFT"), env("SCALE"), env("AR"));

    // PRELOAD=1 (the video-mode runs, sim/emu/run_modes.sh): no load; the SDRAM chip and the EEPROM hold what a load leaves in them
    // (the expected layout, the image's EEPROM default) from before the memory comes up, and the machine starts as soon as it is up
    const bool preload = env("PRELOAD");
    if (preload) {
        auto &mb = R.tb_emu_top__DOT__chip__DOT__mem_b;
        for (size_t i = 0; i < sd.size(); i++) mb[i] = sd[i];
        auto &ee = R.tb_emu_top__DOT__u_emu__DOT__u_core__DOT__u_eep__DOT__mem;
        const size_t EEP = 0x1c00000;
        if (img.size() >= EEP + 128) for (int i = 0; i < 64; i++) ee[i] = (img[EEP + 2 * i] << 8) | img[EEP + 2 * i + 1];
    }

    t->RESET = 1;
    for (int i = 0; i < 64; i++) tick();
    t->RESET = 0;
    for (int i = 0; i < 2000; i++) tick();
    printf("status word %08x %08x, forced_scandoubler %d\n", (unsigned)HPSV(r_status)[1], (unsigned)HPSV(r_status)[0], (int)HPSV(r_fsd));

    // ---------------------------------------------------------------- the load
    uint64_t t0 = cyc;
    HPSV(r_index) = 0;
    if (preload) {
    } else if (fast) {
        auto &mem = R.tb_emu_top__DOT__ddr__DOT__mem;
        const size_t base = 0x400000;                 // byte 0x32000000 in the client's window at 0x30000000
        for (size_t i = 0; i < img.size(); i += 8) {
            uint64_t w = 0;
            for (int b = 0; b < 8 && i + b < img.size(); b++) w |= (uint64_t)img[i + b] << (8 * b);
            mem[base + i / 8] = w;
        }
        HPSV(r_addr) = img.size();
        HPSV(r_download) = 1;
        for (int i = 0; i < 100; i++) tick();
        HPSV(r_download) = 0;
    } else {
        HPSV(r_download) = 1;
        for (int i = 0; i < 20; i++) tick();
        for (size_t i = 0; i < img.size(); i++) {
            while (HPSV(r_wait_seen)) tick();
            HPSV(r_addr) = i;
            HPSV(r_dout) = img[i];
            HPSV(r_wr) = 1; tick();
            HPSV(r_wr) = 0; tick();
            if ((i & 0xfffff) == 0) { printf("load %zu MB\n", i >> 20); fflush(stdout); }
        }
        for (int i = 0; i < 20; i++) tick();
        HPSV(r_download) = 0;
    }
    // the machine leaves reset when the load (and the SDRAM's write queue) is done
    while (R.tb_emu_top__DOT__u_emu__DOT__mc_rst) tick();
    printf("load done after %.3f s of machine time (%s)\n", (cyc - t0) / 96e6, preload ? "preloaded" : fast ? "fast load" : "streamed");

    // ---------------------------------------------------------------- the SDRAM against the expected layout
    {
        auto &mb = R.tb_emu_top__DOT__chip__DOT__mem_b;
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < sd.size(); i++) if (mb[i] != sd[i]) { if (!bad) first = i; bad++; }
        printf("SDRAM: %zu of %zu bytes differ from the expected layout", bad, sd.size());
        if (bad) { printf(" (first at %#zx)", first); errors++; }
        printf("\n");
    }

    // ---------------------------------------------------------------- the pictures and the raster
    const unsigned long long LINE_CLK = 15ull * (mame ? 407 : 424), FRAME_CLK = LINE_CLK * 262;
    std::vector<uint8_t> fb(VIS_W * VIS_H * 3, 0), last(VIS_W * VIS_H * 3, 0);
    int de_count = 0, de_last = -1, frame = 0;
    bool pvs = false;
    unsigned long long last_vs = 0;
    std::vector<unsigned long long> periods;
    // the geometry of the analog picture as the monitor gets it, at clock level: lines from the vsync pulse to the first row with
    // picture, the number of rows and lines, where each row starts (clocks from the hsync pulse before it) and how wide it is
    bool g_phs = false, g_pde = false;
    unsigned long long g_hs = 0, g_de = 0, g_vs = 0;
    int g_rows = 0, g_lines = 0; long g_first = -1, g_smin = 1L << 30, g_smax = -1, g_wmin = 1L << 30, g_wmax = -1;
    int geo_rows = 0, geo_lines = 0; long geo_first = -1, geo_smin = 0, geo_smax = 0, geo_wmin = 0, geo_wmax = 0;
    const uint64_t run0 = cyc;
    while (frame < frames) {
        tick();
        if (cyc - (last_vs ? last_vs : run0) > 4 * FRAME_CLK) {   // a scandoubler that lost the line timing stops the vertical sync
            printf("  FAIL: no vertical sync for %llu clocks after frame %d\n", 4 * FRAME_CLK, frame); errors++;
            break;
        }
        {
            bool hs = t->VGA_HS, de = t->VGA_DE;
            if (hs && !g_phs) { g_lines++; g_hs = cyc; }
            if (de && !g_pde) {
                long s = (long)(cyc - g_hs); g_de = cyc; g_rows++;
                if (g_first < 0) g_first = (long)(cyc - g_vs);
                if (s < g_smin) g_smin = s;
                if (s > g_smax) g_smax = s;
            }
            if (!de && g_pde) { long w = (long)(cyc - g_de); if (w < g_wmin) g_wmin = w; if (w > g_wmax) g_wmax = w; }
            g_phs = hs; g_pde = de;
        }
        bool vs = t->VGA_VS;
        if (vs && !pvs) {                       // a frame ends
            geo_rows = g_rows; geo_lines = g_lines; geo_first = g_first; geo_smin = g_smin; geo_smax = g_smax; geo_wmin = g_wmin; geo_wmax = g_wmax;
            g_vs = cyc; g_lines = 0; g_first = -1; g_rows = 0; g_smin = 1L << 30; g_smax = -1; g_wmin = 1L << 30; g_wmax = -1;
            if (last_vs) periods.push_back(cyc - last_vs);
            last_vs = cyc;
            frame++;
            last = fb; de_last = de_count; de_count = 0;
            if (frame % snapevery == 0) {
                char fn[64]; snprintf(fn, sizeof fn, ".f%d.ppm", frame);
                FILE *o = fopen((prefix + fn).c_str(), "wb");
                fprintf(o, "P6\n%d %d\n255\n", VIS_W, VIS_H); fwrite(fb.data(), 1, fb.size(), o); fclose(o);
                printf("frame %d\n", frame); fflush(stdout);
            }
        }
        pvs = vs;
        if (t->CE_PIXEL && t->VGA_DE) {
            int idx = -1;
            if (sd_mul == 1) idx = de_count < VIS_W * VIS_H ? de_count : -1;
            else {   // scandoubled: the even rows (and the even columns of HQ2x's double width) as the 320 x 224 picture
                int w2 = VIS_W * (sd_hq ? 2 : 1), row = de_count / w2, col = de_count % w2;
                if (!(row & 1) && !(sd_hq && (col & 1)) && row / 2 < VIS_H) idx = (row / 2) * VIS_W + (sd_hq ? col / 2 : col);
            }
            if (idx >= 0) { uint8_t *p = &fb[idx * 3]; p[0] = t->VGA_R; p[1] = t->VGA_G; p[2] = t->VGA_B; }
            de_count++;
        }
    }
    printf("done: %d frames after the load; the last had %d visible pixels (expect %d)\n", frame, de_last, VIS_W * VIS_H * sd_mul);
    if (de_last != VIS_W * VIS_H * sd_mul) { printf("  FAIL: visible pixel count\n"); errors++; }
    {   // the raster's period: 15 clocks a dot, 424 (57.6 Hz) or 407 (60 Hz) dots a line, 262 lines. The first period after the
        // load spans the switch from the standby raster to the machine's; V-Shift moves the vertical sync by whole lines, so the
        // frame in which it takes effect is a different length
        printf("frame period %llu clocks (expect %llu = %.4f Hz)\n", periods.empty() ? 0ull : periods.back(), FRAME_CLK, 96e6 / (double)FRAME_CLK);
        int ok = 0, bad = 0, trans = 0;
        for (size_t i = 1; i < periods.size(); i++) {
            if (periods[i] == FRAME_CLK) ok++;
            else if (vshift && i <= 3) { trans++; printf("  frame %zu: period %llu clocks = %.3f lines (V-Shift taking effect)\n", i, periods[i], periods[i] / (double)LINE_CLK); }
            else { bad++; printf("  frame %zu: period %llu clocks = %.3f lines\n", i, periods[i], periods[i] / (double)LINE_CLK); }
        }
        printf("frame periods after the load: %d whole, %d at a V-Shift step, %d other\n", ok, trans, bad);
        if (bad || ok == 0) { printf("  FAIL: a frame of the wrong length\n"); errors++; }
    }
    unsigned nonblack = 0;
    for (int i = 0; i < VIS_W * VIS_H; i++) if (last[i * 3] | last[i * 3 + 1] | last[i * 3 + 2]) nonblack++;
    printf("last frame: %u non-black pixels\n", nonblack);
    if (nonblack == 0) {   // the game's first frames are black while it starts
        if (frame >= 10) { printf("  FAIL: the picture is blank\n"); errors++; }
        else printf("  (blank: the game is still starting; run 10 frames or more to see its first picture)\n");
    }
    printf("geometry (last frame): %d rows with picture, %d lines a frame; first row %ld clocks after the vsync pulse (%.3f lines);"
           " rows start %ld..%ld clocks after hsync, %ld..%ld clocks wide\n",
           geo_rows, geo_lines, geo_first, geo_first / (double)LINE_CLK, geo_smin, geo_smax, geo_wmin, geo_wmax);
    if (geo_rows != VIS_H * (sd_on ? 2 : 1) || geo_lines != 262 * (sd_on ? 2 : 1)) {
        printf("  FAIL: the raster should be %d rows in %d lines\n", VIS_H * (sd_on ? 2 : 1), 262 * (sd_on ? 2 : 1)); errors++;
    }
    {   // Scale: the size the core asks the scaler for, worked out from the picture as it leaves arcade_video (rows, pixels in a row),
        // the OSD settings and the scaler's size by the framework's rule (video_freak): the picture scaled up by the largest whole
        // factor that fits the scaler's height; its width follows the aspect ratio (V-Integer) or is a whole multiple of the pixel
        // row (narrower = the multiple below the aspect width, wider = the one above it, HV-Integer = whichever is nearer, the
        // wider one only if it still fits)
        const int menu = env("SCALE"), ar = env("AR");
        const int HW = t->HDMI_WIDTH, HH = t->HDMI_HEIGHT;
        const int rows = geo_rows, w = VIS_W * (sd_hq ? 2 : 1);
        static const int map[5] = {0, 1, 4, 2, 3};                    // the OSD's order -> video_freak's SCALE
        const int sel = (menu >= 0 && menu <= 4) ? map[menu] : 0;
        const bool fs_int = ar == 1 && sel != 0 && HW != 0 && HH != 0;   // Rabbit.sv's fs_int
        const int arx_in = fs_int ? HW : (ar == 0 ? 4 : ar - 1), ary_in = fs_int ? HH : (ar == 0 ? 3 : 0);
        int ex = arx_in, ey = ary_in; bool eabs = false, checked = true;
        if (sel && !(!ary_in && arx_in) && rows && HH / rows > 0) {
            int oh = rows * (HH / rows), ht = 0, hi, dn;
            if (!ary_in) { int m = HW / w ? HW / w : 1; hi = w * m; oh = rows * m; dn = HW; checked = false; }
            else {
                ht = (int)((long)oh * arx_in / ary_in); int m0 = ht / w ? ht / w : 1; hi = w * m0; dn = ht;
                if (hi > HW) { int m1 = HW / w ? HW / w : 1; hi = w * m1; oh = rows * m1; dn = HW; }
            }
            const int wide = hi + w;
            const bool narrow = (((ht - hi) & 0xfff) <= ((wide - ht) & 0xfff)) || wide > HW;
            const int wres = hi == ht ? hi : wide;
            switch (sel) {
                case 2: ex = hi; break;
                case 3: ex = wres > HW ? hi : wres; break;
                case 4: ex = narrow ? hi : wres; break;
                default: ex = dn;
            }
            ey = oh; eabs = true;
        }
        const int gx = t->VIDEO_ARX & 0xfff, gy = t->VIDEO_ARY & 0xfff, gax = (t->VIDEO_ARX >> 12) & 1, gay = (t->VIDEO_ARY >> 12) & 1;
        printf("scale: Scale %d (SCALE %d) Aspect %d, picture %d rows of %d pixels, scaler %d x %d: core asks for %s%d x %s%d; rule gives %s%d x %s%d%s\n",
               menu, sel, ar, rows, w, HW, HH, gax ? "" : "ratio ", gx, gay ? "" : "ratio ", gy, eabs ? "" : "ratio ", ex, eabs ? "" : "ratio ", ey,
               checked ? "" : " (not checked)");
        if (checked && (gx != ex || gy != ey || gax != (int)eabs || gay != (int)eabs)) { printf("  FAIL: the size asked of the scaler\n"); errors++; }
    }
    printf("%s: %u errors\n", errors ? "FAIL" : "PASS", errors);
    t->final();
    delete t;
    return errors ? 1 : 0;
}
