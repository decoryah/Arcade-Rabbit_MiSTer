// The MiSTer top-level bench's driver (sim/emu/run_emu.sh): plays the HPS for Rabbit.sv.
//   Vtb_emu_top <image.rom> <expected.sdram> <frames after the load> <out prefix>
// FAST=1: the MRA's address= fast load (the image put into the DDR3 at byte 0x32000000, then a download that carries only the length);
// otherwise the image is streamed through the ioctl port a byte at a time, honouring ioctl_wait. After the load every byte of the SDRAM
// is compared with the expected layout (tools/rabbit_rom.py --sdram); then the machine runs and every SNAPEVERY-th picture the scaler gets
// (VGA_* on CE_PIXEL with VGA_DE) is written as <prefix>.f<n>.ppm, n counted from the machine's start.
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

static std::vector<uint8_t> slurp(const char *fn) {
    std::vector<uint8_t> v;
    FILE *f = fopen(fn, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", fn); exit(2); }
    fseek(f, 0, SEEK_END); v.resize(ftell(f)); fseek(f, 0, SEEK_SET);
    if (fread(v.data(), 1, v.size(), f) != v.size()) exit(2);
    fclose(f);
    return v;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 5) { fprintf(stderr, "usage: Vtb_emu_top <image.rom> <expected.sdram> <frames> <prefix>\n"); return 2; }
    std::vector<uint8_t> img = slurp(argv[1]), sd = slurp(argv[2]);
    int frames = atoi(argv[3]);
    std::string prefix = argv[4];
    bool fast = getenv("FAST") && atoi(getenv("FAST"));
    int snapevery = getenv("SNAPEVERY") ? atoi(getenv("SNAPEVERY")) : 10;
    t = new Vtb_emu_top;
    auto &R = *t->rootp;
    t->HDMI_WIDTH = 1920; t->HDMI_HEIGHT = 1080;
    t->RESET = 1;
    for (int i = 0; i < 64; i++) tick();
    t->RESET = 0;
    for (int i = 0; i < 2000; i++) tick();

    // ---------------------------------------------------------------- the load
    uint64_t t0 = cyc;
    R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_index = 0;
    if (fast) {
        auto &mem = R.tb_emu_top__DOT__ddr__DOT__mem;
        const size_t base = 0x400000;                 // byte 0x32000000 in the client's window at 0x30000000
        for (size_t i = 0; i < img.size(); i += 8) {
            uint64_t w = 0;
            for (int b = 0; b < 8 && i + b < img.size(); b++) w |= (uint64_t)img[i + b] << (8 * b);
            mem[base + i / 8] = w;
        }
        R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_addr = img.size();
        R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_download = 1;
        for (int i = 0; i < 100; i++) tick();
        R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_download = 0;
    } else {
        R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_download = 1;
        for (int i = 0; i < 20; i++) tick();
        for (size_t i = 0; i < img.size(); i++) {
            while (R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_wait_seen) tick();
            R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_addr = i;
            R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_dout = img[i];
            R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_wr = 1; tick();
            R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_wr = 0; tick();
            if ((i & 0xfffff) == 0) { printf("load %zu MB\n", i >> 20); fflush(stdout); }
        }
        for (int i = 0; i < 20; i++) tick();
        R.tb_emu_top__DOT__u_emu__DOT__hps_io__DOT__r_download = 0;
    }
    // the machine leaves reset when the load (and the SDRAM's write queue) is done
    while (R.tb_emu_top__DOT__u_emu__DOT__mc_rst) tick();
    printf("load done after %.3f s of machine time (%s)\n", (cyc - t0) / 96e6, fast ? "fast load" : "streamed");

    // ---------------------------------------------------------------- the SDRAM against the expected layout
    {
        auto &mb = R.tb_emu_top__DOT__chip__DOT__mem_b;
        size_t bad = 0, first = 0;
        for (size_t i = 0; i < sd.size(); i++) if (mb[i] != sd[i]) { if (!bad) first = i; bad++; }
        printf("SDRAM: %zu of %zu bytes differ from the expected layout", bad, sd.size());
        if (bad) printf(" (first at %#zx)", first);
        printf("\n");
    }

    // ---------------------------------------------------------------- the pictures
    std::vector<uint8_t> fb(320 * 224 * 3, 0);
    int x = 0, y = 0, frame = 0;
    bool pde = false, pvs = false;
    while (frame < frames) {
        tick();
        if (!t->CE_PIXEL) continue;
        bool de = t->VGA_DE, vs = t->VGA_VS;
        if (de) {
            if (x < 320 && y < 224) { uint8_t *p = &fb[(y * 320 + x) * 3]; p[0] = t->VGA_R; p[1] = t->VGA_G; p[2] = t->VGA_B; }
            x++;
        } else if (pde) { y++; x = 0; }
        if (vs && !pvs) {
            frame++;
            if (frame % snapevery == 0) {
                char fn[64]; snprintf(fn, sizeof fn, ".f%d.ppm", frame);
                FILE *o = fopen((prefix + fn).c_str(), "wb");
                fprintf(o, "P6\n320 224\n255\n"); fwrite(fb.data(), 1, fb.size(), o); fclose(o);
            }
            x = 0; y = 0;
        }
        pde = de; pvs = vs;
    }
    printf("done: %d frames after the load\n", frame);
    t->final();
    delete t;
    return 0;
}
