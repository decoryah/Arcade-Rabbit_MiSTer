#!/bin/sh
# MAME 0.289 runs with tools/lua/dump_state.lua (Git Bash on Windows): a fresh EEPROM every run (MAME's nvram is deleted first), so runs repeat.
#   tools/mame_dump.sh <out dir> <frames "a,b,c"> [play|coin]
# MAME, its ROM path and a work directory are taken from MAME / ROMPATH / WORK (defaults: the owner's).
MAME=${MAME:-/c/repos/mame0289/mame.exe}
ROMPATH=${ROMPATH:-C:/repos/rabbit_work/roms}
WORK=${WORK:-/c/repos/rabbit_work/mame_run}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$1"; FR="$2"; SCHED="$3"
mkdir -p "$OUT" "$WORK"
cd "$WORK" && rm -rf nvram/rabbit
DUMPFRAMES="$FR" DUMPDIR="$(cygpath -m "$OUT" 2>/dev/null || echo "$OUT")" SCHED="$SCHED" "$MAME" rabbit -rompath "$ROMPATH" -video none -sound none -nothrottle \
    -skip_gameinfo -window -cfg_directory cfg -nvram_directory nvram -autoboot_script "$(cygpath -m "$HERE/lua/dump_state.lua")" -seconds_to_run 100000 2>&1 | tail -2
