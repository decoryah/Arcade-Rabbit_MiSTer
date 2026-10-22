// The frame bench: rabbit_video alone, with its SDRAM (the image's layout, +SDRAM=<file>); the C++ driver (sim/tb_frame.cpp) writes a
// state MAME dumped (tools/lua/dump_state.lua) through the CPU's port, lets the vblank snapshot take it and captures the next picture.
`default_nettype none
module tb_frame_top (
    input  logic        clk,
    input  logic        reset_in,
    input  logic        no_flash,           // KO flash Off (rabbit_video)
    input  logic        v_req,
    input  logic        v_we,
    input  logic [17:1] v_addr,
    input  logic        v_mem,
    input  logic  [1:0] v_be,
    input  logic [15:0] v_wdata,
    output logic        v_ack,
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic        hs,
    output logic        vs,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic        vbl_irq,
    output logic [15:0] dbg_overrun_a,
    output logic [15:0] dbg_overrun_b,
    output logic        ready
);
    logic        m_req [2], m_ack [2], m_valid [2];
    logic [23:0] m_addr [2];
    logic  [4:0] m_len [2];
    logic [15:0] m_rdata;
    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic  [1:0] SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CKE;

    rabbit_sdram #(.P_SHORT_INIT(1'b1), .NC(2)) u_sdram (
        .clk(clk), .rst_n(!reset_in), .o_ready(ready), .i_rd_late(1'b0),
        .i_dl_wr(1'b0), .i_dl_addr('0), .i_dl_data('0), .o_dl_busy(),
        .c_req(m_req), .c_addr(m_addr), .c_len(m_len), .c_ack(m_ack), .c_valid(m_valid), .o_rdata(m_rdata),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
    );
    sdram_model u_sdr (
        .clk(clk), .A(SDRAM_A), .BA(SDRAM_BA), .DQ(SDRAM_DQ), .DQML(SDRAM_DQML), .DQMH(SDRAM_DQMH),
        .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE), .CKE(SDRAM_CKE)
    );

    logic [15:0] v_rdata_unused;
    logic        snap_hold_unused, frame_unused;
    rabbit_video u_video (
        .clk(clk), .reset(reset_in || !ready), .board_rate(1'b0), .no_flash(no_flash),
        .v_req(v_req), .v_we(v_we), .v_addr(v_addr), .v_mem(v_mem), .v_be(v_be), .v_wdata(v_wdata), .v_ack(v_ack), .v_rdata(v_rdata_unused),
        .b_we(1'b0), .b_layer(2'd0), .b_idx(12'd0), .b_hi(1'b0), .b_data(16'd0), .blt_active(1'b0), .snap_hold(snap_hold_unused),
        .t_req(m_req[0]), .t_addr(m_addr[0]), .t_len(m_len[0]), .t_ack(m_ack[0]), .t_valid(m_valid[0]),
        .s_req(m_req[1]), .s_addr(m_addr[1]), .s_len(m_len[1]), .s_ack(m_ack[1]), .s_valid(m_valid[1]), .sd_data(m_rdata),
        .vbl_irq(vbl_irq), .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hs(hs), .vs(vs), .r(r), .g(g), .b(b),
        .dbg_overrun_a(dbg_overrun_a), .dbg_overrun_b(dbg_overrun_b), .dbg_frame(frame_unused)
    );
endmodule
`default_nettype wire
