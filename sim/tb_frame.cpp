// The frame bench's driver (sim/run_frames.sh): for each state_<f>.bin of a directory (tools/lua/dump_state.lua), the video chip is
// reset, the state is written through the CPU's port during the first frame, the snapshot at vblank takes it, and the next picture is
// written as out_<f>.ppm. The chip shows a frame's sprite list one frame late (rabbit_video.sv), so the state is written for two frames:
// the picture is then the state's own, the one MAME draws. SEQ=1: consecutive frames, as the machine runs them: no reset between the
// states, and each state written while the picture before it is drawn, so that every vblank's snapshot takes the next state (one
// snapshot a state); the picture of state N then has the sprite list of state N-1, as on the board. NOFLASH=1: KO flash Off.
//   Vtb_frame_top +SDRAM=<rabbit.sdram> -- <state dir> <frame> [<frame> ...]
#include "Vtb_frame_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <deque>
#include <string>
#include <vector>

static Vtb_frame_top *t;
static uint64_t cyc = 0;

// the CPU port's writes, queued and served one at a time after every clock (the port waits during the snapshot)
struct Wr { bool mem; uint32_t a; uint16_t d; };
static std::deque<Wr> wq;
static bool wbusy = false;
static void serve() {
    if (wbusy) { if (t->v_ack) { t->v_req = 0; wbusy = false; wq.pop_front(); } return; }
    if (!wq.empty()) {
        const Wr &w = wq.front();
        t->v_req = 1; t->v_we = 1; t->v_mem = w.mem; t->v_addr = (w.a >> 1) & 0x1ffff; t->v_be = 3; t->v_wdata = w.d;
        wbusy = true;
    }
}
static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); cyc++; serve(); }
static void wr32(bool mem, uint32_t a, uint32_t d) { wq.push_back({mem, a, (uint16_t)(d >> 16)}); wq.push_back({mem, a + 2, (uint16_t)d}); }
static void drain() { while (!wq.empty() || wbusy) tick(); }
static void wait_vbl() { while (!t->vbl_irq) tick(); tick(); }

struct State { std::vector<uint8_t> b; size_t n = 0; };
static bool load(const std::string &dir, const std::string &fr, State &s) {
    FILE *f = fopen((dir + "/state_" + fr + ".bin").c_str(), "rb");
    if (!f) { fprintf(stderr, "no state %s\n", fr.c_str()); return false; }
    s.b.assign(200000, 0);
    s.n = fread(s.b.data(), 1, s.b.size(), f); fclose(f);
    if (s.n < (4 * 4096 + 4096 + 16384 + 24 + 7) * 4) { fprintf(stderr, "short state %s\n", fr.c_str()); return false; }
    return true;
}
static void enqueue(const State &s) {
    auto dw = [&](size_t i) { return (uint32_t)s.b[4*i] << 24 | (uint32_t)s.b[4*i+1] << 16 | (uint32_t)s.b[4*i+2] << 8 | s.b[4*i+3]; };
    size_t k = 0;
    for (int i = 0; i < 4 * 4096; i++) wr32(true, 0x480000 + 4 * i, dw(k++));
    for (int i = 0; i < 4096; i++)     wr32(true, 0x494000 + 4 * i, dw(k++));
    for (int i = 0; i < 16384; i++)    wr32(true, 0x4a0000 + 4 * i, dw(k++));
    for (int l = 0; l < 4; l++) for (int r = 0; r < 6; r++) wr32(false, 0x400100 + 0x20 * l + 4 * r, dw(k++));
    for (int r = 0; r < 7; r++)        wr32(false, 0x400200 + 4 * r, dw(k++));
    // viewregs6 (0x400400-0x400413) when the dump has them (older dumps: zeros, MAME's picture)
    const bool vr = s.n >= (4 * 4096 + 4096 + 16384 + 24 + 7 + 5) * 4;
    for (int r = 0; r < 5; r++)        wr32(false, 0x400400 + 4 * r, vr ? dw(k++) : 0);
}
static void reset() {
    t->reset_in = 1; t->v_req = 0; wq.clear(); wbusy = false;
    for (int i = 0; i < 16; i++) tick();
    t->reset_in = 0;
    while (!t->ready) tick();
}
// the picture after the last snapshot, to the start of the next vblank (whose snapshot takes what the CPU port holds then)
static void capture(const std::string &dir, const std::string &fr) {
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
    if (!wq.empty() || wbusy) fprintf(stderr, "frame %s: the next state's writes did not finish within the picture\n", fr.c_str());
    FILE *o = fopen((dir + "/out_" + fr + ".ppm").c_str(), "wb");
    fprintf(o, "P6\n320 224\n255\n"); fwrite(fb.data(), 1, fb.size(), o); fclose(o);
    printf("frame %s: rendered, overruns A %u B %u\n", fr.c_str(), t->dbg_overrun_a, t->dbg_overrun_b);
    fflush(stdout);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> pos;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') pos.push_back(argv[i]);
    if (pos.size() < 2) { fprintf(stderr, "usage: Vtb_frame_top +SDRAM=f -- <dir> <frame>...\n"); return 2; }
    std::string dir = pos[0];
    std::vector<std::string> frames(pos.begin() + 1, pos.end());
    t = new Vtb_frame_top;
    t->no_flash = getenv("NOFLASH") && atoi(getenv("NOFLASH"));
    const bool seq = getenv("SEQ") && atoi(getenv("SEQ"));
    State s;
    if (!seq) {
        for (auto &fr : frames) {
            if (!load(dir, fr, s)) continue;
            reset();
            for (int pass = 0; pass < 2; pass++) { enqueue(s); drain(); wait_vbl(); }
            capture(dir, fr);
        }
    } else {
        // the first state for two frames (its own sprite list), then each next state written while the picture before it is drawn
        size_t i = 0;
        while (i < frames.size() && !load(dir, frames[i], s)) i++;
        if (i == frames.size()) return 1;
        reset();
        for (int pass = 0; pass < 2; pass++) { enqueue(s); drain(); wait_vbl(); }
        for (; i < frames.size(); i++) {
            State nx;
            if (i + 1 < frames.size() && load(dir, frames[i + 1], nx)) enqueue(nx);
            capture(dir, frames[i]);
        }
    }
    t->final();
    delete t;
    return 0;
}
