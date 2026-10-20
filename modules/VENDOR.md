# Vendored modules

Third-party HDL copied into the tree (no submodules, so the build is self-contained and reproducible). Each keeps its own
licence alongside.

| module | upstream | licence |
|---|---|---|
| cpu-tg68k | https://github.com/TobiFlex/TG68K.C @ ade33e396a1e647c2de9daf71ff9d5b3979639b2, with the GHDL conversion `gen/tg68k.v` (as in the owner's Mystic Warriors core) | LGPL-3.0 |
| crt-adjust | https://github.com/rmonic79/MiSTer-CRT-Adjust @ c682de9f4acc61d8f4c7779efb48149d3baa3a8e (upstream's `rtl/crt_adjust.sv`; one local fix, below), by rmonic79 (Umberto Parisi) with Andrea Bogazzi (asturur); copied from the owner's Mystic Warriors core | GPL-3.0 or later |

To update one: re-copy from upstream at the new commit and record it here.

Local change to `crt-adjust/crt_adjust.sv` (one line, `hoff_s`): the conditional mixes `$signed(hoffset)` with an unsigned
replication, so by the Verilog rules (and in Verilator) the result is unsigned and a negative H-Position is zero-extended
(-1 becomes 511), which moves the picture window out of the line and blanks the picture. The line sign-extends `hoffset`
explicitly, which is what the module is meant to do and gives the same result in every tool. Nothing else differs from
upstream.
