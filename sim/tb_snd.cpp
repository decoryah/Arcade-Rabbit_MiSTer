// The sound bench's driver (sim/run_snd.sh): the I5000 register writes MAME made (tools/lua/snd_log.lua: "<seconds> <reg> <data> <mask>"
// a line; whole-word writes only count, as in i5000snd_device::write) replayed at their times; the output sampled at 48 kHz into
// <out>.raw (16-bit stereo), as the system bench's AUDIO=1.
//   Vtb_snd_top +SDRAM=<rabbit.sdram> -- <snd.log> <out prefix> [seconds]
#include "Vtb_snd_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

struct Wr { uint64_t clk; int reg; uint16_t data; bool rd; };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::vector<std::string> pos;
    for (int i = 1; i < argc; i++) if (argv[i][0] != '+') pos.push_back(argv[i]);
    if (pos.size() < 2) { fprintf(stderr, "usage: Vtb_snd_top +SDRAM=f -- <snd.log> <prefix> [seconds]\n"); return 2; }
    double secs = pos.size() > 2 ? atof(pos[2].c_str()) : 1e9;
    std::vector<Wr> wr;
    FILE *f = fopen(pos[0].c_str(), "r");
    if (!f) { fprintf(stderr, "no log %s\n", pos[0].c_str()); return 2; }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        for (char *p = line; *p; p++) if (*p == ',') *p = '.';      // a decimal comma (the locale MAME's Lua ran in)
        double t; int reg; unsigned d, m;
        if (line[0] == 'R') {
            if (sscanf(line + 1, "%lf %d %x", &t, &reg, &d) == 3) wr.push_back({ (uint64_t)(t * 96e6), reg, (uint16_t)d, true });
            continue;
        }
        if (sscanf(line, "%lf %d %x %x", &t, &reg, &d, &m) != 4) continue;
        if (m != 0xffff) continue;
        wr.push_back({ (uint64_t)(t * 96e6), reg, (uint16_t)d, false });
    }
    fclose(f);
    printf("%zu writes\n", wr.size());

    Vtb_snd_top *t = new Vtb_snd_top;
    FILE *o = fopen((pos[1] + ".raw").c_str(), "wb");
    uint64_t cyc = 0, end = (uint64_t)(secs * 96e6);
    size_t wi = 0;
    int acnt = 0;
    int nrd = 0, nbad = 0;
    t->reset_in = 1; t->wr = 0;
    auto tick = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); };
    for (int i = 0; i < 16; i++) tick();
    t->reset_in = 0;
    while (!t->ready) tick();
    while (cyc < end && (wi < wr.size() || cyc < wr.back().clk + 96000000ull)) {
        t->wr = 0;
        if (wi < wr.size() && cyc >= wr[wi].clk) {
            if (wr[wi].rd) {
                // a read MAME's game made: does the chip answer the same?
                t->rreg = wr[wi].reg; t->eval();
                nrd++;
                if (t->rdata != wr[wi].data) {
                    if (nbad < 20) printf("read t=%.6f reg %02x: MAME %04x, here %04x\n", cyc / 96e6, wr[wi].reg, wr[wi].data, t->rdata);
                    nbad++;
                }
            } else { t->wr = 1; t->rreg = wr[wi].reg; t->wdata = wr[wi].data; }
            wi++;
        }
        tick();
        cyc++;
        if (++acnt == 2000) {
            acnt = 0;
            int16_t s[2] = { (int16_t)t->out_l, (int16_t)t->out_r };
            fwrite(s, 2, 2, o);
        }
    }
    fclose(o);
    printf("done: %.2f s, %d reads compared, %d differ\n", cyc / 96e6, nrd, nbad);
    t->final();
    delete t;
    return 0;
}
