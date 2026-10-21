// The sound bench: rabbit_i5000 with its SDRAM (the image's layout, +SDRAM=<file>); sim/tb_snd.cpp replays the register writes MAME
// made (tools/lua/snd_log.lua) at their times and records the output.
`default_nettype none
module tb_snd_top (
    input  logic        clk,
    input  logic        reset_in,
    input  logic        enhanced,           // OSD Sound: 1 Enhanced, 0 MAME
    input  logic        wr,
    input  logic  [6:0] rreg,
    input  logic [15:0] wdata,
    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r,
    output logic [15:0] rdata,
    output logic        ready,
    // the output filter's input and output at each chip sample (the filter's result for the sample before), for tools/sndflt_ref.py
    output logic        dbg_stb,
    output logic signed [16:0] dbg_mx_l,
    output logic signed [16:0] dbg_mx_r,
    output logic signed [15:0] dbg_f_l,
    output logic signed [15:0] dbg_f_r,
    // the tail expander's key ons and codes (tools/txref.py)
    output logic        dbg_kon,
    output logic        dbg_tx,
    output logic  [3:0] dbg_ch,
    output logic signed [13:0] dbg_tx_in,
    output logic signed [13:0] dbg_tx_out
);
    assign dbg_kon = u_snd.dbg_kon_stb; assign dbg_tx = u_snd.dbg_tx_stb; assign dbg_ch = u_snd.dbg_ch;
    assign dbg_tx_in = u_snd.dbg_tx_in; assign dbg_tx_out = u_snd.dbg_tx_out;
    assign dbg_stb = u_snd.mx_stb;
    assign dbg_mx_l = u_snd.mx_l; assign dbg_mx_r = u_snd.mx_r;
    assign dbg_f_l = u_snd.flt_l; assign dbg_f_r = u_snd.flt_r;
    logic        m_req [1], m_ack [1], m_valid [1];
    logic [23:0] m_addr [1];
    logic  [4:0] m_len [1];
    logic [15:0] m_rdata;
    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic  [1:0] SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CKE;

    rabbit_sdram #(.P_SHORT_INIT(1'b1), .NC(1)) u_sdram (
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
    rabbit_i5000 u_snd (
        .clk(clk), .reset(reset_in || !ready), .enhanced(enhanced),
        .wr(wr), .rreg(rreg), .wdata(wdata), .rdata(rdata),
        .req(m_req[0]), .addr(m_addr[0]), .len(m_len[0]), .ack(m_ack[0]), .valid(m_valid[0]), .data(m_rdata),
        .out_l(out_l), .out_r(out_r)
    );
endmodule
`default_nettype wire
