//------------------------------------------------------------------------------
// The Rabbit board (MAME 0.289 rabbit.cpp): the 68EC020 with its program cache, the Imagetek I5000 (video, blitter, sound) and the
// 93C46 EEPROM. Everything it reads from ROM comes through six SDRAM read clients (rabbit_sdram.sv), in priority order:
//   0 the sound's sample words   1 the program cache's line fills   2 the CPU's gfx1 readback   3 tile rows   4 sprite rows   5 the blitter
// SDRAM word addresses (rabbit_loader.sv): program 0x000000, gfx1 0x100000 (rows interleaved), gfx2 0x900000, sound 0xC00000.
//------------------------------------------------------------------------------
`default_nettype none

module rabbit_core #(
    parameter int STEP_COST_BUS = 47,
    parameter int STEP_COST_INT = 40,
    parameter int STEP_GAIN     = 8
) (
    input  logic        clk,
    input  logic        reset,              // the machine
    input  logic        cache_flush,        // a new image is loading
    input  logic        board_rate,         // the raster: 1 = the board's 57.61 Hz, 0 = MAME's 60 Hz (rabbit_video)
    input  logic        snd_enh,            // the sound: 1 = Enhanced (the game's sample rate, the output filter), 0 = MAME's (rabbit_i5000)
    input  logic        no_flash,           // 1: a frame the game fills with a colour (the KO's flash) shows the frame before's sprites, no fill

    // the SDRAM's read clients
    output logic        m_req   [6],
    output logic [23:0] m_addr  [6],
    output logic  [4:0] m_len   [6],
    input  logic        m_ack   [6],
    input  logic        m_valid [6],
    input  logic [15:0] m_rdata,

    // inputs: MAME's INPUTS port, active low, bit 0 ignored (the EEPROM's DO)
    input  logic [31:0] in_port,

    // the EEPROM's contents: the image's default, the saved file, the save
    input  logic        ee_ld_wr,
    input  logic  [6:0] ee_ld_addr,
    input  logic  [7:0] ee_ld_data,
    input  logic        ee_nv_wr,
    input  logic  [6:0] ee_nv_addr,
    input  logic  [7:0] ee_nv_data,
    input  logic  [6:0] ee_nv_raddr,
    output logic  [7:0] ee_nv_rdata,
    output logic        ee_written,

    // the picture
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic        vblank_next,
    output logic        hs,
    output logic        vs,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,

    // the sound
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,

    // diagnostics
    output logic        dbg_frame,
    output logic [15:0] dbg_overrun_a,
    output logic [15:0] dbg_overrun_b,
    output logic [23:0] dbg_addr,
    output logic        dbg_step,
    output logic        dbg_rd,
    output logic [23:0] dbg_rd_addr,
    output logic        dbg_blt_busy,
    output logic        dbg_blt_irq
);
    // ------------------------------------------------------------------ the program cache
    logic        cache_ready;
    logic        rom_req, rom_ack;
    logic [19:0] rom_addr;
    logic [15:0] rom_q;
    rabbit_cache #(.AW(20), .IDX(11), .BASE(24'h000000)) u_cache (
        .clk(clk), .reset(cache_flush), .ready(cache_ready),
        .req(rom_req), .addr(rom_addr), .ack(rom_ack), .q(rom_q),
        .m_req(m_req[1]), .m_addr(m_addr[1]), .m_len(m_len[1]), .m_ack(m_ack[1]), .m_valid(m_valid[1]), .m_data(m_rdata)
    );

    wire cpu_reset = reset || !cache_ready;

    // ------------------------------------------------------------------ the CPU and its bus
    logic        v_req, v_we, v_mem, v_ack;
    logic [17:1] v_addr;
    logic  [1:0] v_be;
    logic [15:0] v_wdata, v_rdata;
    logic        blt_start, blt_busy, blt_active, blt_irq, snap_hold, vbl_irq;
    logic [31:0] blt_regs [3];
    logic        snd_wr;
    logic  [6:0] snd_reg;
    logic [15:0] snd_wdata, snd_rdata;
    logic        eep_wr, eep_cs, eep_clk, eep_di, eep_do;

    rabbit_main #(.STEP_COST_BUS(STEP_COST_BUS), .STEP_COST_INT(STEP_COST_INT), .STEP_GAIN(STEP_GAIN)) u_main (
        .clk(clk), .reset(cpu_reset),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ack(rom_ack), .rom_q(rom_q),
        .gr_req(m_req[2]), .gr_addr(m_addr[2]), .gr_ack(m_ack[2]), .gr_valid(m_valid[2]), .gr_data(m_rdata),
        .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_mem(v_mem), .v_be(v_be), .v_wdata(v_wdata), .v_ack(v_ack), .v_rdata(v_rdata),
        .blt_start(blt_start), .blt_regs(blt_regs), .blt_busy(blt_busy),
        .snd_wr(snd_wr), .snd_reg(snd_reg), .snd_wdata(snd_wdata), .snd_rdata(snd_rdata),
        .vbl_irq(vbl_irq), .blt_irq(blt_irq),
        .in_port(in_port),
        .eep_wr(eep_wr), .eep_cs(eep_cs), .eep_clk(eep_clk), .eep_di(eep_di), .eep_do(eep_do),
        .dbg_pc_addr(dbg_addr), .dbg_step(dbg_step), .dbg_rd(dbg_rd), .dbg_rd_addr(dbg_rd_addr)
    );
    assign m_len[2] = 5'd1;

    // ------------------------------------------------------------------ the video side
    logic        b_we, b_hi;
    logic  [1:0] b_layer;
    logic [11:0] b_idx;
    logic [15:0] b_data;

    rabbit_video u_video (
        .clk(clk), .reset(reset), .board_rate(board_rate), .no_flash(no_flash),
        .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_mem(v_mem), .v_be(v_be), .v_wdata(v_wdata), .v_ack(v_ack), .v_rdata(v_rdata),
        .b_we(b_we), .b_layer(b_layer), .b_idx(b_idx), .b_hi(b_hi), .b_data(b_data), .blt_active(blt_active), .snap_hold(snap_hold),
        .t_req(m_req[3]), .t_addr(m_addr[3]), .t_len(m_len[3]), .t_ack(m_ack[3]), .t_valid(m_valid[3]),
        .s_req(m_req[4]), .s_addr(m_addr[4]), .s_len(m_len[4]), .s_ack(m_ack[4]), .s_valid(m_valid[4]), .sd_data(m_rdata),
        .vbl_irq(vbl_irq), .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .vblank_next(vblank_next), .hs(hs), .vs(vs), .r(r), .g(g), .b(b),
        .dbg_overrun_a(dbg_overrun_a), .dbg_overrun_b(dbg_overrun_b), .dbg_frame(dbg_frame)
    );

    assign dbg_blt_busy = blt_busy;
    assign dbg_blt_irq  = blt_irq;
    rabbit_blitter u_blit (
        .clk(clk), .reset(reset), .start(blt_start), .regs(blt_regs), .hold(snap_hold),
        .active(blt_active), .busy(blt_busy), .irq(blt_irq),
        .req(m_req[5]), .addr(m_addr[5]), .len(m_len[5]), .ack(m_ack[5]), .valid(m_valid[5]), .data(m_rdata),
        .b_we(b_we), .b_layer(b_layer), .b_idx(b_idx), .b_hi(b_hi), .b_data(b_data)
    );

    // ------------------------------------------------------------------ the sound
    rabbit_i5000 u_snd (
        .clk(clk), .reset(reset), .enhanced(snd_enh),
        .wr(snd_wr), .rreg(snd_reg), .wdata(snd_wdata), .rdata(snd_rdata),
        .req(m_req[0]), .addr(m_addr[0]), .len(m_len[0]), .ack(m_ack[0]), .valid(m_valid[0]), .data(m_rdata),
        .out_l(audio_l), .out_r(audio_r)
    );

    // ------------------------------------------------------------------ the EEPROM
    rabbit_eeprom u_eep (
        .clk(clk), .i_wr(eep_wr), .i_di(eep_di), .i_cs(eep_cs), .i_clk(eep_clk), .o_do(eep_do),
        .i_ld_wr(ee_ld_wr), .i_ld_addr(ee_ld_addr), .i_ld_data(ee_ld_data),
        .i_nv_wr(ee_nv_wr), .i_nv_addr(ee_nv_addr), .i_nv_data(ee_nv_data),
        .i_nv_raddr(ee_nv_raddr), .o_nv_rdata(ee_nv_rdata), .o_written(ee_written)
    );
endmodule
`default_nettype wire
