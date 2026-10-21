#!/bin/sh
# The sound bench: MAME's I5000 register writes (tools/lua/snd_log.lua) replayed into rabbit_i5000, the output compared with MAME's
# -wavwrite recording of the same run (tools/audio_cmp.py).
#   sim/run_snd.sh <snd.log> <rabbit.sdram> <out prefix> [seconds] [mame.wav]
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
OBJ=${OBJ:-obj_snd}
if [ ! -x $OBJ/Vtb_snd_top ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build -j ${JOBS:-16} -O3 -CFLAGS "-O2 -march=native" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-PROCASSINIT -Wno-BLKSEQ \
    -I../rtl --top-module tb_snd_top --prefix Vtb_snd_top -Mdir $OBJ \
    ../rtl/rabbit_i5000.sv ../rtl/rabbit_sndflt.sv ../rtl/rabbit_sdram.sv sdram_model.sv tb_snd_top.sv tb_snd.cpp > $OBJ.log 2>&1 || { tail -30 $OBJ.log; exit 1; }
fi
./$OBJ/Vtb_snd_top +SDRAM="$2" "$1" "$3" ${4:-1000000000}
if [ -n "$5" ]; then python3 ../tools/audio_cmp.py "$3.raw" "$5"; fi
