#!/bin/sh
# Verilator lint of the machine and the SDRAM controller: sim/lint.sh [max lines]
cd "$(dirname "$0")"
export PATH="$HOME/tools/oss-cad-suite/bin:$PATH"
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET \
    +1364-2005ext+v waivers.vlt -I../rtl --top-module rabbit_core \
    ../rtl/rabbit_core.sv ../rtl/rabbit_main.sv ../rtl/rabbit_cache.sv ../rtl/rabbit_video.sv ../rtl/rabbit_tilegen.sv \
    ../rtl/rabbit_sprgen.sv ../rtl/rabbit_ram.sv ../rtl/rabbit_blitter.sv ../rtl/rabbit_i5000.sv ../rtl/rabbit_eeprom.sv \
    ../modules/cpu-tg68k/gen/tg68k.v 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-80}
echo "--- sdram"
verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME --top-module rabbit_sdram ../rtl/rabbit_sdram.sv 2>&1 | grep -E "^%(Error|Warning)" | head -${1:-40}
