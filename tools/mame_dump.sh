#!/bin/sh
# MAME 0.289 runs with tools/lua/dump_state.lua (Git Bash on Windows): a fresh EEPROM every run (MAME's nvram is deleted first), so runs repeat.
#   tools/mame_dump.sh <out dir> <frames "a,b,c"> [play|coin]
# MAME, its ROM path and a work directory are taken from MAME / ROMPATH / WORK (defaults: the owner's MAME; the ROMs and the
# work directory in the scratch folder work/ next to the repository).
HERE=$(cd "$(dirname "$0")" && pwd)
SCRATCH=$(cd "$HERE/../.." && pwd)/work
MAME=${MAME:-/c/repos/mame0289/mame.exe}
ROMPATH=${ROMPATH:-$(cygpath -m "$SCRATCH/roms" 2>/dev/null || echo "$SCRATCH/roms")}
WORK=${WORK:-$SCRATCH/mame_run}
OUT="$1"; FR="$2"; SCHED="$3"
mkdir -p "$OUT" "$WORK"
OUT=$(cd "$OUT" && pwd)
cd "$WORK" && rm -rf nvram/rabbit
DUMPFRAMES="$FR" DUMPDIR="$(cygpath -m "$OUT" 2>/dev/null || echo "$OUT")" SCHED="$SCHED" "$MAME" rabbit -rompath "$ROMPATH" -video none -sound none -nothrottle \
    -skip_gameinfo -window -cfg_directory cfg -nvram_directory nvram -autoboot_script "$(cygpath -m "$HERE/lua/dump_state.lua")" -seconds_to_run 100000 2>&1 | tail -2
