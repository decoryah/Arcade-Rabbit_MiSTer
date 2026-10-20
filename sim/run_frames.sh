#!/bin/sh
# The frame bench: MAME's dumped states (tools/lua/dump_state.lua) through the video chip, each picture compared with MAME's snapshot.
#   sim/run_frames.sh <state dir> <rabbit.sdram> [frames...]     (all the dir's states when no frames are given)
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
DIR="$1"; SD="$2"; shift 2
OBJ=${OBJ:-obj_frame}
if [ ! -x $OBJ/Vtb_frame_top ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build -j ${JOBS:-16} -O3 -CFLAGS "-O2 -march=native" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSINIT -Wno-BLKSEQ \
    -I../rtl --top-module tb_frame_top --prefix Vtb_frame_top -Mdir $OBJ \
    ../rtl/rabbit_video.sv ../rtl/rabbit_tilegen.sv ../rtl/rabbit_sprgen.sv ../rtl/rabbit_ram.sv ../rtl/rabbit_sdram.sv \
    sdram_model.sv tb_frame_top.sv tb_frame.cpp > $OBJ.log 2>&1 || { tail -30 $OBJ.log; exit 1; }
fi
if [ $# -eq 0 ]; then set -- $(ls "$DIR" | sed -n 's/^state_\([0-9]*\)\.bin$/\1/p' | sort -n); fi
./$OBJ/Vtb_frame_top +SDRAM="$SD" "$DIR" "$@"
for f in "$@"; do
    printf "frame %s vs MAME: " "$f"
    python3 ../tools/cmp_frame.py "$DIR/out_$f.ppm" "$DIR/snap_$f.png" "$DIR/diff_$f.png"
done
