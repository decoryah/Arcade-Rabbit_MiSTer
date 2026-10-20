derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about half a period (rtl/pll/pll_0002.v); as in the owner's other
# cores the pin's clock is modelled as the machine clock inverted, and the read data -- launched by the chip's edge, captured by
# rabbit_sdram's input register a few edges after the READ command -- gets a two-cycle path. sys/sys.tcl puts the SDRAM pins' registers
# in the IO cells.
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# ==============================================================================
# TG68K: the kernel steps on a clock enable, never closer than four clocks apart (rabbit_main's step_gap), so its internal paths have
# four clocks; its address, data and bus-state outputs settle after a step and the board samples them only after the three-clock gap
# (keepers, not registers: the kernel's register file and the board's RAMs are M10K cells). The same constraints as the Mystic Warriors
# core, whose TG68K is sequenced the same way.
# ==============================================================================
set_multicycle_path -setup 4 -from [get_registers {*|TG68KdotC_Kernel:*|*}] -to [get_registers {*|TG68KdotC_Kernel:*|*}]
set_multicycle_path -hold  3 -from [get_registers {*|TG68KdotC_Kernel:*|*}] -to [get_registers {*|TG68KdotC_Kernel:*|*}]
set_multicycle_path -setup 3 -from [get_keepers {*|TG68KdotC_Kernel:*|*}] -to [get_keepers {*|rabbit_main:*|*}]
set_multicycle_path -hold  2 -from [get_keepers {*|TG68KdotC_Kernel:*|*}] -to [get_keepers {*|rabbit_main:*|*}]

# ==============================================================================
# The framework's HQ2x (sys/hq2x.sv) updates its datapath on the scandoubler's ce_x4i, four times per input pixel: for this core's
# 15-clock pixels at least three clocks apart. The framework does not constrain it (as in the Mystic Warriors core).
# ==============================================================================
set HQ [get_registers -nowarn {*|Blend:*|*}]
foreach n {cyc nextpatt pattern Prev0 Prev1 Prev2 Curr0 Curr1 Curr2 Next0 Next1 Next2 A B D F G H
           curbuf prevbuf offs wrdata wrdata_finished waddr wrout_addr wrpix wrin_addr2
           old_reset_line old_reset_frame} {
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s} $n]]]
    set HQ [add_to_collection $HQ [get_registers -nowarn [format {*|Hq2x:*|%s[*]} $n]]]
}
set_multicycle_path -setup 3 -from $HQ -to $HQ
set_multicycle_path -hold  2 -from $HQ -to $HQ
