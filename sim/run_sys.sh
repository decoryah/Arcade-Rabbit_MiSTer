#!/bin/sh
# The whole-machine bench: rabbit_core behind rabbit_sdram and a behavioural SDRAM loaded with the image's SDRAM layout.
#   sim/run_sys.sh <rabbit.sdram> <rabbit.nv> <frames> <out prefix>
# (tools/rabbit_rom.py <rabbit.zip> rabbit x.rom --sdram rabbit.sdram --eeprom rabbit.nv makes the two files.)
# Environment: see sim/tb_rabbit.cpp (SNAPEVERY, SNAPFRAMES, SCHED, AUDIO, TRACE); REBUILD=1 rebuilds the model; THREADS=n.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
SD="$1"; NV="$2"
[ -f "$SD" ] && [ -n "$3" ] && [ -n "$4" ] || { echo "usage: $0 <rabbit.sdram> <rabbit.nv> <frames> <prefix>" >&2; exit 2; }
OBJ=${OBJ:-obj_sys}
if [ ! -x $OBJ/Vtb_top ] || [ -n "$REBUILD" ]; then
verilator --cc --exe --build -j ${JOBS:-16} -O3 ${THREADS:+--threads $THREADS} -CFLAGS "-O2 -march=native" -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME \
    -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE \
    -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSINIT -Wno-SYNCASYNCNET -Wno-BLKSEQ \
    +1364-2005ext+v waivers.vlt $VFLAGS -I../rtl --top-module tb_top --prefix Vtb_top -Mdir $OBJ \
    ../rtl/rabbit_core.sv ../rtl/rabbit_main.sv ../rtl/rabbit_cache.sv ../rtl/rabbit_video.sv ../rtl/rabbit_tilegen.sv \
    ../rtl/rabbit_sprgen.sv ../rtl/rabbit_ram.sv ../rtl/rabbit_blitter.sv ../rtl/rabbit_i5000.sv ../rtl/rabbit_eeprom.sv ../rtl/rabbit_sdram.sv \
    ../modules/cpu-tg68k/gen/tg68k.v sdram_model.sv tb_top.sv tb_rabbit.cpp > $OBJ.log 2>&1 || { tail -30 $OBJ.log; exit 1; }
fi
mkdir -p "$(dirname "$4")"
./$OBJ/Vtb_top +SDRAM="$SD" +EEPROM="$NV" "$3" "$4"
