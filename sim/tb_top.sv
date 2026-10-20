// The whole-machine bench: rabbit_core behind rabbit_sdram and the behavioural SDRAM (sim/sdram_model.sv), which is loaded at time 0
// with the image's SDRAM layout (+SDRAM=<file>, tools/rabbit_rom.py --sdram). The EEPROM's default comes from +EEPROM=<file> (128 bytes)
// through the loader port, before the machine leaves reset. Driven by sim/tb_rabbit.cpp.
`default_nettype none
module tb_top #(
    parameter int CB = 47,               // rabbit_main STEP_COST_BUS / STEP_COST_INT / STEP_GAIN (calibration runs: -GCB=..)
    parameter int CI = 40,
    parameter int GN = 8
) (
    input  logic        clk,
    input  logic        reset_in,
    input  logic        board_rate,          // the raster (rabbit_video): 0 = MAME's 60 Hz (the benches' default), 1 = the board's 57.61 Hz
    input  logic [31:0] in_port,
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic        hs,
    output logic        vs,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic        dbg_frame,
    output logic [15:0] dbg_overrun_a,
    output logic [15:0] dbg_overrun_b,
    output logic [23:0] dbg_addr,
    output logic        dbg_step,
    output logic        dbg_rd,
    output logic [23:0] dbg_rd_addr,
    output logic        dbg_blt_busy,
    output logic        dbg_blt_irq,
    output logic        running
);
    // ------------------------------------------------------------------ the SDRAM
    logic        m_req [6], m_ack [6], m_valid [6];
    logic [23:0] m_addr [6];
    logic  [4:0] m_len [6];
    logic [15:0] m_rdata;
    logic        sd_ready;
    wire  [15:0] SDRAM_DQ;
    logic [12:0] SDRAM_A;
    logic  [1:0] SDRAM_BA;
    logic        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE, SDRAM_CKE;

    rabbit_sdram #(.P_SHORT_INIT(1'b1), .NC(6)) u_sdram (
        .clk(clk), .rst_n(!reset_in), .o_ready(sd_ready), .i_rd_late(1'b0),
        .i_dl_wr(1'b0), .i_dl_addr('0), .i_dl_data('0), .o_dl_busy(),
        .c_req(m_req), .c_addr(m_addr), .c_len(m_len), .c_ack(m_ack), .c_valid(m_valid), .o_rdata(m_rdata),
        .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
    );
    sdram_model u_sdr (
        .clk(clk), .A(SDRAM_A), .BA(SDRAM_BA), .DQ(SDRAM_DQ), .DQML(SDRAM_DQML), .DQMH(SDRAM_DQMH),
        .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE), .CKE(SDRAM_CKE)
    );

    // ------------------------------------------------------------------ the EEPROM's default
    logic [7:0] ee [128];
    initial begin
        string f;
        int fd, n;
        for (int i = 0; i < 128; i++) ee[i] = 8'hff;
        if ($value$plusargs("EEPROM=%s", f)) begin
            fd = $fopen(f, "rb");
            if (fd != 0) begin n = $fread(ee, fd); $fclose(fd); $display("tb: EEPROM %0d bytes from %s", n, f); end
        end
    end
    logic [7:0] ee_i = 8'd0;
    logic       ee_wr;
    always_ff @(posedge clk) begin
        ee_wr <= 1'b0;
        if (!reset_in && ee_i < 8'd128) begin ee_wr <= 1'b1; ee_i <= ee_i + 8'd1; end
    end
    logic [6:0] ee_wa;
    logic [7:0] ee_wd;
    always_ff @(posedge clk) begin ee_wa <= ee_i[6:0]; ee_wd <= ee[ee_i[6:0]]; end

    // ------------------------------------------------------------------ the machine
    logic mc_reset;
    always_ff @(posedge clk) mc_reset <= reset_in || !sd_ready || (ee_i < 8'd128) || ee_wr;
    assign running = !mc_reset;

    rabbit_core #(.STEP_COST_BUS(CB), .STEP_COST_INT(CI), .STEP_GAIN(GN)) u_core (
        .clk(clk), .reset(mc_reset), .cache_flush(reset_in), .board_rate(board_rate),
        .m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack), .m_valid(m_valid), .m_rdata(m_rdata),
        .in_port(in_port),
        .ee_ld_wr(ee_wr), .ee_ld_addr(ee_wa), .ee_ld_data(ee_wd),
        .ee_nv_wr(1'b0), .ee_nv_addr('0), .ee_nv_data('0), .ee_nv_raddr('0), .ee_nv_rdata(), .ee_written(),
        .ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hs(hs), .vs(vs), .r(r), .g(g), .b(b),
        .audio_l(audio_l), .audio_r(audio_r),
        .dbg_frame(dbg_frame), .dbg_overrun_a(dbg_overrun_a), .dbg_overrun_b(dbg_overrun_b), .dbg_addr(dbg_addr), .dbg_step(dbg_step), .dbg_rd(dbg_rd), .dbg_rd_addr(dbg_rd_addr), .dbg_blt_busy(dbg_blt_busy), .dbg_blt_irq(dbg_blt_irq)
    );

    // ------------------------------------------------------------------ the write watch: +WATCHLO=<hex> +WATCHHI=<hex> [+WATCHFROM=f
    // +WATCHTO=f] print every CPU write into the range as "W <frame> <us since vblank> <PC> <address> <data> <uds lds>", the core's side
    // of tools/lua/watch.lua (frames counted as sim/tb_rabbit.cpp counts them)
    logic [23:0] w_lo = 24'hffffff, w_hi = 24'h000000;
    int          w_from = 0, w_to = 1 << 30;
    initial begin
        void'($value$plusargs("WATCHLO=%h", w_lo));
        void'($value$plusargs("WATCHHI=%h", w_hi));
        void'($value$plusargs("WATCHFROM=%d", w_from));
        void'($value$plusargs("WATCHTO=%d", w_to));
    end
    int          w_frame = 0;
    longint      w_cyc = 0, w_vb = 0;
    logic        w_pvb = 1'b1;
    wire  [23:0] w_a = {u_core.u_main.A, 1'b0};
    // +STEPSTATS: the CPU's steps counted by kind (opcode fetch, data read, data write, internal) and its clocks by what held it (the
    // token bucket, a bus cycle in progress), printed cumulatively at every vblank ("S ...") and with every watched write
    bit          w_stats = 1'b0;
    initial w_stats = $test$plusargs("STEPSTATS");
    longint      n_fetch = 0, n_read = 0, n_write = 0, n_int = 0, n_tok = 0, n_bus = 0;
    always_ff @(posedge clk) begin
        w_cyc <= w_cyc + 1;
        w_pvb <= vblank;
        if (vblank && !w_pvb) begin
            w_frame <= w_frame + 1; w_vb <= w_cyc;
            if (w_stats) $display("S %0d %0d %0d %0d %0d %0d %0d %0d", w_frame + 1, w_cyc, n_fetch, n_read, n_write, n_int, n_tok, n_bus);
        end
        if (!mc_reset) begin
            if (u_core.u_main.cpu_step) begin
                if (u_core.u_main.is_int) n_int <= n_int + 1;
                else case (u_core.u_main.busstate)
                    2'b00:   n_fetch <= n_fetch + 1;
                    2'b10:   n_read  <= n_read + 1;
                    default: n_write <= n_write + 1;
                endcase
            end else if (u_core.u_main.bst != 0) n_bus <= n_bus + 1;
            else if (u_core.u_main.tok < u_core.u_main.step_cost) n_tok <= n_tok + 1;
        end
        if (u_core.u_main.cpu_wr && w_a >= w_lo && w_a <= w_hi && w_frame >= w_from && w_frame <= w_to) begin
            $display("W %0d %0.1f %06x %06x %04x %b%b", w_frame, real'(w_cyc - w_vb) / 96.0, u_core.u_main.cpu.exe_pc[23:0], w_a,
                     u_core.u_main.wdat, u_core.u_main.uds, u_core.u_main.lds);
            if (w_stats) $display("S - %0d %0d %0d %0d %0d %0d %0d", w_cyc, n_fetch, n_read, n_write, n_int, n_tok, n_bus);
        end
    end
endmodule
`default_nettype wire
