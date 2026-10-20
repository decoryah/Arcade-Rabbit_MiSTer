// The whole-machine bench's driver: sim/run_sys.sh builds it.
//   Vtb_top +SDRAM=<rabbit.sdram> +EEPROM=<rabbit.nv> -- <frames> <out prefix>
// Environment: SNAPEVERY=n (a picture every n frames), SNAPFRAMES=a,b,c, SCHED=coin (a coin at frame 300, start at 400, ...),
// AUDIO=1 (<prefix>.wav), TRACE=1 (a line per frame: the CPU's address, overruns).
// Pictures are written as <prefix>.f<frame>.ppm (320 x 224).
#include "Vtb_top.h"
#include "Vtb_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <set>
#include <string>
#include <vector>

static std::set<int> parse_list(const char *s) {
    std::set<int> r;
    if (!s) return r;
    const char *p = s;
    while (*p) { r.insert(atoi(p)); while (*p && *p != ',') p++; if (*p) p++; }
    return r;
}

static void write_ppm(const std::string &fn, const std::vector<uint8_t> &fb) {
    FILE *f = fopen(fn.c_str(), "wb");
    if (!f) return;
    fprintf(f, "P6\n320 224\n255\n");
    fwrite(fb.data(), 1, fb.size(), f);
    fclose(f);
}

// the scripted inputs, the same as tools/lua/dump_state.lua's sched(): MAME takes the values set in frame f's frame_done from the
// vblank that ends frame f on, which is when `frame` here becomes f. Active low: bit 6 coin 1, bit 2 start 1, P1 bits 8-15 (up, down,
// left, right, buttons 1-4).
static uint32_t sched_in(const char *sched, int f) {
    uint32_t in = 0xffffffff;
    if (!sched) return in;
    auto press = [&](int bit) { in &= ~(1u << bit); };
    if (f >= 300 && f < 306) press(6);
    if (f >= 400 && f < 406) press(2);
    if (!strcmp(sched, "coin")) {
        if (f >= 600 && (f / 30) % 2 == 1) press(12);
    } else if (!strcmp(sched, "play") && f >= 600) {
        if ((f / 8) % 4 == 0) press(12);                       // button 1
        if ((f / 8) % 4 == 2) press(13);                       // button 2
        if ((f / 12) % 5 == 1) press(14);                      // button 3
        if ((f / 60) % 3 != 2) press(11);                      // right
        if ((f / 60) % 3 == 2) press(10);                      // left
        if ((f / 90) % 4 == 3 && f % 90 < 10) press(8);        // up
    }
    return in;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int nframes = 60;
    std::string prefix = "out/rabbit";
    std::vector<std::string> pos;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') pos.push_back(argv[i]);
    if (pos.size() >= 1) nframes = atoi(pos[0].c_str());
    if (pos.size() >= 2) prefix = pos[1];
    int snapevery = getenv("SNAPEVERY") ? atoi(getenv("SNAPEVERY")) : 0;
    std::set<int> snapframes = parse_list(getenv("SNAPFRAMES"));
    std::set<int> ramframes = parse_list(getenv("DUMPRAM"));      // the work RAM at these frames: <prefix>.wram_<f>.bin (big-endian, as MAME dumps it)
    const char *sched = getenv("SCHED");
    bool trace = getenv("TRACE") && atoi(getenv("TRACE"));
    bool audio = getenv("AUDIO") && atoi(getenv("AUDIO"));

    Vtb_top *t = new Vtb_top;
    t->clk = 0; t->reset_in = 1; t->in_port = 0xffffffff;
    t->board_rate = getenv("BOARD") && atoi(getenv("BOARD"));    // BOARD=1: the board's 57.61 Hz raster (default: MAME's 60 Hz)
    t->eval();

    std::vector<uint8_t> fb(320 * 224 * 3, 0);
    int x = 0, y = 0, frame = 0;
    bool prev_hb = true, prev_vb = true;
    uint64_t cyc = 0;
    FILE *wav = nullptr;
    std::vector<int16_t> abuf;
    if (audio) wav = fopen((prefix + ".raw").c_str(), "wb");
    int acnt = 0;
    uint64_t idle_reads = 0, blt_run = 0, blt_max = 0;
    uint32_t idle_addr = getenv("IDLEADDR") ? strtoul(getenv("IDLEADDR"), nullptr, 16) : 0xff53c6;   // the wait loop counted (101f2: ff53c6; the boot's 287c: ffff5a)
    int nirq = 0, late_irq = 0;
    FILE *idlef = getenv("IDLE") ? fopen(getenv("IDLE"), "w") : nullptr;

    while (frame < nframes && !Verilated::gotFinish()) {
        if (cyc == 64) t->reset_in = 0;
        t->in_port = sched_in(sched, frame);

        t->clk = 1; t->eval();
        t->clk = 0; t->eval();
        cyc++;
        if (t->dbg_rd && t->dbg_rd_addr == idle_addr) idle_reads++;
        if (t->dbg_blt_busy) { blt_run++; if (blt_run > blt_max) blt_max = blt_run; } else blt_run = 0;
        if (t->dbg_blt_irq) { nirq++; if (t->dbg_blt_busy) late_irq++; }     // the idle loop's flag (tst.b at 101f2): the CPU's slack

        if (audio && ++acnt == 2000) {     // 48 kHz
            acnt = 0;
            int16_t s[2] = { (int16_t)t->audio_l, (int16_t)t->audio_r };
            fwrite(s, 2, 2, wav);
        }

        if (t->ce_pix) {
            bool hb = t->hblank, vb = t->vblank;
            if (!hb && !vb && x < 320 && y < 224) {
                uint8_t *p = &fb[(y * 320 + x) * 3];
                p[0] = t->r; p[1] = t->g; p[2] = t->b;
                x++;
            }
            if (hb && !prev_hb) { if (x > 0) y++; x = 0; }
            if (vb && !prev_vb) {
                frame++;
                if ((snapevery && frame % snapevery == 0) || snapframes.count(frame)) {
                    char fn[64]; snprintf(fn, sizeof fn, ".f%d.ppm", frame);
                    write_ppm(prefix + fn, fb);
                }
                if (ramframes.count(frame)) {
                    char fn[64]; snprintf(fn, sizeof fn, ".wram_%d.bin", frame);
                    FILE *w = fopen((prefix + fn).c_str(), "wb");
                    auto &m = t->rootp->tb_top__DOT__u_core__DOT__u_main__DOT__u_wram__DOT__mem;
                    for (int i = 0; i < 32768; i++) { uint16_t v = m[i]; uint8_t b2[2] = { (uint8_t)(v >> 8), (uint8_t)v }; fwrite(b2, 1, 2, w); }
                    fclose(w);
                }
                if (trace)
                    printf("frame %d cyc %llu addr %06x overrun A %u B %u running %d\n", frame, (unsigned long long)cyc,
                           t->dbg_addr, t->dbg_overrun_a, t->dbg_overrun_b, t->running);
                fflush(stdout);
                if (idlef) { fprintf(idlef, "%d %llu blit_max %llu irq %d late %d\n", frame, (unsigned long long)idle_reads, (unsigned long long)blt_max, nirq, late_irq); fflush(idlef); blt_max = 0; nirq = 0; late_irq = 0; }
                idle_reads = 0;
                y = 0; x = 0;
            }
            prev_hb = hb; prev_vb = vb;
        }
    }
    printf("done: %d frames, %llu clocks, overruns A %u B %u\n", frame, (unsigned long long)cyc, t->dbg_overrun_a, t->dbg_overrun_b);
    if (wav) fclose(wav);
    t->final();
    delete t;
    return 0;
}
