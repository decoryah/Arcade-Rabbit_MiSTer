#!/bin/bash
# The video modes on the MiSTer top level (sim/emu/run_emu.sh, built once), several runs at a time: the refresh rates, Scandoubler Fx
# (HQ2x, the CRT filters), MiSTer.ini's forced_scandoubler, CRT Adjust and Scale. Each run checks its own raster (sim/emu/tb_emu.cpp:
# frame period, rows and lines, the size asked of the scaler); this script then compares its pictures with the plain run's of the same
# frame (the scandoubled ones by their even rows, as the bench keeps them), which shows a frozen or shifted picture.
#   sim/emu/run_modes.sh <image.rom> <expected.sdram> <out dir> [frames, default 40]
# The memories are preloaded (PRELOAD=1: the loads are checked by run_emu.sh's own runs); JOBS runs at a time (default 6).
cd "$(dirname "$0")"
IMG="$1"; SD="$2"; OUT="$3"; FR="${4:-40}"
[ -f "$IMG" ] && [ -f "$SD" ] && [ -n "$OUT" ] || { echo "usage: $0 <image.rom> <expected.sdram> <out dir> [frames]" >&2; exit 2; }
mkdir -p "$OUT"
[ -x obj_emu/Vtb_emu_top ] || { echo "build the bench first: sim/emu/run_emu.sh (REBUILD=1)" >&2; exit 2; }
# name and settings; the pictures of every run but the 60 Hz ones are compared with "base", those with "mame"
MODES=(
  "base:"
  "mame:MAME=1"
  "hq2x:FX=1"
  "crt25:FX=2"
  "crt75:FX=4"
  "fsd:FSD=1"
  "fsd_mame:FSD=1 MAME=1"
  "fsd_crt50:FSD=1 FX=3"
  "crt_on:CRT=1"
  "crt_on_mame:CRT=1 MAME=1"
  "crt_size2:CRT=1 HSIZE=2"
  "crt_size-16:CRT=1 HSIZE=-16"
  "crt_pos16:CRT=1 HPOS=16"
  "crt_pos-48:CRT=1 HPOS=-48"
  "crt_vs5:CRT=1 VSHIFT=5"
  "crt_vs-16:CRT=1 VSHIFT=-16"
  "crt_under_sd:CRT=1 HSIZE=2 HPOS=10 VSHIFT=3 FX=2"
  "scale_v:SCALE=1"
  "scale_hv:SCALE=2"
  "scale_nhv:SCALE=3"
  "scale_hvp:SCALE=4"
  "scale_hv_fs:SCALE=2 AR=1"
  "scale_hv_1280:SCALE=2 HW=1280 HH=720"
  "scale_hvp_hq2x:SCALE=4 FX=1"
)
run_one() {
  local name="${1%%:*}" set="${1#*:}"
  env PRELOAD=1 SNAPEVERY=10 $set ./obj_emu/Vtb_emu_top "$IMG" "$SD" "$FR" "$OUT/$name" > "$OUT/$name.log" 2>&1
  echo "$name: $(grep -E "^(PASS|FAIL)" "$OUT/$name.log" | tail -1)"
}
export -f run_one; export IMG SD FR OUT
printf '%s\n' "${MODES[@]}" | xargs -P "${JOBS:-6}" -I{} bash -c 'run_one "$@"' _ {}
# the pictures against the plain run's of the same frame: pictures identical, and the pixels that differ in the others (HQ2x
# interpolates at edges, so its even columns are not the source's everywhere). A V-Shift that moves the sync earlier makes the
# bench count the frame the machine starts in one sooner, so its pictures are the plain run's of the next frame (which shows only
# where the picture changes from frame to frame; the picture itself is one line later, not a frame)
echo "--- pictures"
for m in "${MODES[@]}"; do
  name="${m%%:*}"; [ "$name" = base ] || [ "$name" = mame ] && continue
  case "$m" in *MAME=1*) ref=mame ;; *) ref=base ;; esac
  python3 - "$OUT" "$name" "$ref" <<'PY'
import glob, os, sys
out, run, ref = sys.argv[1:4]
n = same = 0; worst = 0
for f in sorted(glob.glob(os.path.join(out, ref + '.f*.ppm'))):
    g = os.path.join(out, run + f[len(os.path.join(out, ref)):])
    if not os.path.exists(g): continue
    a, b = open(f, 'rb').read(), open(g, 'rb').read()
    n += 1
    if a == b: same += 1; continue
    h = len(a) - 320 * 224 * 3
    d = sum(1 for i in range(h, len(a), 3) if a[i:i + 3] != b[i:i + 3])
    worst = max(worst, d)
print(f"{run}: {same} of {n} pictures identical to {ref}'s" + (f"; the others differ in at most {worst} pixels" if same < n else ""))
PY
done
