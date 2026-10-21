// The frame bench's driver (sim/run_frames.sh): for each state_<f>.bin of a directory (tools/lua/dump_state.lua), the video chip is
// reset, the state is written through the CPU's port during the first frame, the snapshot at vblank takes it, and the next picture is
// written as out_<f>.ppm. SEQ=1: no reset between the states (consecutive frames, for what the chip carries from one frame to the next).
//   Vtb_frame_top +SDRAM=<rabbit.sdram> -- <state dir> <frame> [<frame> ...]
#include "Vtb_frame_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>

static Vtb_frame_top *t;
static uint64_t cyc = 0;
static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++; }

static void wr16(bool mem, uint32_t a, uint16_t d) {
    t->v_req = 1; t->v_we = 1; t->v_mem = mem; t->v_addr = (a >> 1) & 0x1ffff; t->v_be = 3; t->v_wdata = d;
    int n = 0;
    do { tick(); } while (!t->v_ack && ++n < 100000);
    t->v_req = 0; tick();
}
static void wr32(bool mem, uint32_t a, uint32_t d) { wr16(mem, a, d >> 16); wr16(mem, a + 2, d & 0xffff); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> pos;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') pos.push_back(argv[i]);
    if (pos.size() < 2) { fprintf(stderr, "usage: Vtb_frame_top +SDRAM=f -- <dir> <frame>...\n"); return 2; }
    std::string dir = pos[0];
    t = new Vtb_frame_top;
    const bool seq = getenv("SEQ") && atoi(getenv("SEQ"));
    for (size_t fi = 1; fi < pos.size(); fi++) {
        std::string fr = pos[fi];
        FILE *f = fopen((dir + "/state_" + fr + ".bin").c_str(), "rb");
        if (!f) { fprintf(stderr, "no state %s\n", fr.c_str()); continue; }
        std::vector<uint8_t> st(200000);
        size_t n = fread(st.data(), 1, st.size(), f); fclose(f);
        auto dw = [&](size_t i) { return (uint32_t)st[4*i] << 24 | (uint32_t)st[4*i+1] << 16 | (uint32_t)st[4*i+2] << 8 | st[4*i+3]; };
        if (n < (4 * 4096 + 4096 + 16384 + 24 + 7) * 4) { fprintf(stderr, "short state %s\n", fr.c_str()); continue; }

        // reset, wait for the SDRAM, then write the state while the first frame runs
        if (!seq || fi == 1) {
            t->reset_in = 1; t->v_req = 0;
            for (int i = 0; i < 16; i++) tick();
            t->reset_in = 0;
            while (!t->ready) tick();
        }
        size_t k = 0;
        for (int i = 0; i < 4 * 4096; i++) wr32(true, 0x480000 + 4 * i, dw(k++));
        for (int i = 0; i < 4096; i++)     wr32(true, 0x494000 + 4 * i, dw(k++));
        for (int i = 0; i < 16384; i++)    wr32(true, 0x4a0000 + 4 * i, dw(k++));
        for (int l = 0; l < 4; l++) for (int r = 0; r < 6; r++) wr32(false, 0x400100 + 0x20 * l + 4 * r, dw(k++));
        for (int r = 0; r < 7; r++)        wr32(false, 0x400200 + 4 * r, dw(k++));
        // the first vblank takes the snapshot; the picture after it is the state's
        while (!t->vbl_irq) tick();
        std::vector<uint8_t> fb(320 * 224 * 3, 0);
        int x = 0, y = 0; bool pv = true, ph = true, started = false;
        while (true) {
            tick();
            if (!t->ce_pix) continue;
            bool vb = t->vblank, hb = t->hblank;
            if (!vb && pv) started = true;                  // the picture begins
            if (started) {
                if (!vb && !hb && x < 320 && y < 224) { uint8_t *p = &fb[(y * 320 + x) * 3]; p[0] = t->r; p[1] = t->g; p[2] = t->b; x++; }
                if (hb && !ph) { if (x > 0) y++; x = 0; }
                if (vb && !pv) break;
            }
            pv = vb; ph = hb;
        }
        FILE *o = fopen((dir + "/out_" + fr + ".ppm").c_str(), "wb");
        fprintf(o, "P6\n320 224\n255\n"); fwrite(fb.data(), 1, fb.size(), o); fclose(o);
        printf("frame %s: rendered, overruns A %u B %u\n", fr.c_str(), t->dbg_overrun_a, t->dbg_overrun_b);
        fflush(stdout);
    }
    t->final();
    delete t;
    return 0;
}
