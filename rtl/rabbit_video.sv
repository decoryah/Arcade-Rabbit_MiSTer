//------------------------------------------------------------------------------
// The Imagetek I5000's video side as MAME 0.289 draws it (src/mame/metro/rabbit.cpp: screen_update, drawtilemap, draw_sprites,
// draw_sprite_bitmap): four zooming tilemaps and a sprite layer drawn through a scaled bitmap window, mixed in the order of the layers'
// priority registers, through a 16K-entry xGRB_888 palette. Four things MAME does not do, each from a recording of a real board
// (docs/hardware.md, "Video: what MAME leaves out"):
//   - a frame's sprite list (the sprite RAM and the count) is shown one frame later than the rest of the frame: the chip draws the
//     sprites into a bitmap during one frame and shows that bitmap in the next (MAME draws them into a bitmap too, in the same frame).
//     The window the bitmap is shown through (spriteregs 0-3) is the frame's own. The game is written for it: in a KO's flash it ends
//     its sprite list with a count of 0 one frame before each flash frame, which then has no fighters (MAME: no fighters on any frame,
//     MAME Testers 04883);
//   - the layers' priority is compared on its low 3 bits (MAME: all 4). The game clears bit 3 on the stage layers (0x2228) on every
//     other frame of a KO's flash, where MAME then draws the stage over the fighters and the board does not; every other value the game
//     writes has bit 3 set, and there both orders are the same;
//   - the colour at 0x400406-0x400409 (xGRB, the palette's layout; 0 = off) fills everything behind the sprites: the KO's flash frames;
//   - 8bpp tiles with bit 31 set are translucent, blended over what is beneath them with the weight 0x400405 / 0xf0 (0 = the tile, 0xf0 =
//     what is beneath): the fades, in which the game lays such a tile over the whole screen and steps 0x400405.
//
// MAME renders a whole frame at the start of vblank from the state at that instant, and the game writes its next frame's sprites,
// tilemaps and palette a few milliseconds after the vblank interrupt (in MAME's own raster that is still vblank; in a 15 kHz raster it is
// the middle of the picture). So this core keeps two copies of everything the picture is made of: the CPU's (read and written by the
// 68020 and the blitter) and the display's (read by the renderers), and copies the one to the other at the start of vblank, all memories
// at once, 4096 clocks (43 us). Meanwhile, and from vblank start until a blit that is running has finished, the CPU's accesses to the
// video chip wait. Every line of the picture is then drawn from the copy: the same frame MAME shows.
//
// The raster: 96 MHz / 15 = 6.4 MHz dots, 262 lines, 320 x 224 visible (MAME's visible area); a line of 424 dots (board_rate: 15.09 kHz,
// 57.61 Hz, the board's rate as a recording of one plays) or 407 (15.72 kHz, 60.02 Hz, MAME's 60 Hz).
// A line is made in three steps, one line time each:
//   stage A (line y-2): the tile rows each layer samples into srcbuf (rabbit_tilegen), the sprite rows into spbuf (rabbit_sprgen);
//   stage B (line y-1): the layers and the sprites drawn into comp in MAME's order (priority 15 first, layer 3, 2, 1, 0 within a level,
//                       the sprites after the layers of level 9; level 0 is never drawn; a layer's level is 8 + its priority's low 3
//                       bits), each over the other where opaque; before the sprites the fill colour, when it is on, over everything;
//                       a translucent pixel goes into cov (the pixel beneath stays in comp), anything drawn over it clears cov;
//   stage C (line y):   comp through the palette to the screen, cov blended over it.
//------------------------------------------------------------------------------
`default_nettype none

module rabbit_video (
    input  logic        clk,
    input  logic        reset,
    input  logic        board_rate,         // 1: 424 dots a line (57.61 Hz), 0: 407 (60.02 Hz)
    input  logic        no_flash,           // 1 (OSD "KO flash: Off"): a frame with the fill colour on shows no fill and the frame before's
                                            // sprites again (the KO's flash frames then look like the frames between: no flashing)

    // the CPU's port (rabbit_main)
    input  logic        v_req,
    input  logic        v_we,
    input  logic [17:1] v_addr,
    input  logic        v_mem,
    input  logic  [1:0] v_be,
    input  logic [15:0] v_wdata,
    output logic        v_ack,
    output logic [15:0] v_rdata,

    // the blitter's writes into the CPU's tilemaps (one 16-bit half of an entry)
    input  logic        b_we,
    input  logic  [1:0] b_layer,
    input  logic [11:0] b_idx,
    input  logic        b_hi,
    input  logic [15:0] b_data,
    input  logic        blt_active,         // a blit is running: the snapshot waits for it
    output logic        snap_hold,          // no blit may start

    // the SDRAM: tiles and sprites
    output logic        t_req,
    output logic [23:0] t_addr,
    output logic  [4:0] t_len,
    input  logic        t_ack,
    input  logic        t_valid,
    output logic        s_req,
    output logic [23:0] s_addr,
    output logic  [4:0] s_len,
    input  logic        s_ack,
    input  logic        s_valid,
    input  logic [15:0] sd_data,

    // the picture
    output logic        vbl_irq,            // one clock at the start of vblank (IRQ 6)
    output logic        ce_pix,
    output logic        hblank,
    output logic        vblank,
    output logic        vblank_next,        // the vertical blank of the line after the current one (CRT Adjust's line buffer wants it)
    output logic        hs,
    output logic        vs,
    output logic  [7:0] r,
    output logic  [7:0] g,
    output logic  [7:0] b,

    // diagnostics
    output logic [15:0] dbg_overrun_a,      // lines whose stage A was not done in time (saturating)
    output logic [15:0] dbg_overrun_b,
    output logic        dbg_frame           // one clock per frame (the snapshot's end)
);
    // ================================================================== the CPU's copies
    // simple dual-port RAMs (rabbit_ram.sv): a write port with byte enables, shared by the CPU and the blitter (the blitter first),
    // and a registered read port for the CPU's reads or the snapshot's
    logic        cw_en;
    logic  [3:0] cw_sel;                     // 0-3 tilemaps, 4 sprites, 8-11 palette banks
    logic [11:0] cw_idx;
    logic  [3:0] cw_be;
    logic [31:0] cw_d;
    logic [11:0] cr_idx;
    logic [31:0] tmc_q [4];
    logic [31:0] spc_q;
    logic [31:0] palc_q [4];
    genvar gi;
    generate for (gi = 0; gi < 4; gi++) begin : g_cpu
        rabbit_ram_be #(.AW(12), .NB(4)) u_tmc  (.clk(clk), .we(cw_en && cw_sel == 4'(gi)),     .wa(cw_idx), .be(cw_be), .d(cw_d), .ra(cr_idx), .q(tmc_q[gi]));
        rabbit_ram_be #(.AW(12), .NB(4)) u_palc (.clk(clk), .we(cw_en && cw_sel == 4'(8 + gi)), .wa(cw_idx), .be(cw_be), .d(cw_d), .ra(cr_idx), .q(palc_q[gi]));
    end endgenerate
    rabbit_ram_be #(.AW(12), .NB(4)) u_spc (.clk(clk), .we(cw_en && cw_sel == 4'd4), .wa(cw_idx), .be(cw_be), .d(cw_d), .ra(cr_idx), .q(spc_q));

    // the registers: tilemap_regs[4][6], spriteregs[7], and of MAME's viewregs6 (0x400400-0x400413, write-only, unused in MAME) the two
    // dwords at 0x400404 (405: the fade weight; 406-407) and 0x400408 (408-409): with 406-409 the fill colour
    logic [31:0] tmr  [4][6];
    logic [31:0] sprr [7];
    logic [31:0] vr   [2];

    // ================================================================== the display's copies
    // written by the snapshot, read by the renderers (rabbit_ram.sv)
    logic        sw_en;
    logic [11:0] sw_idx;
    logic [11:0] tm_addr;                    // the tilemaps' read address (stage A)
    logic [31:0] tm_q [4];
    logic [10:0] spr_addr;                   // the sprite list's (stage A)
    logic        sp_wb;                      // the sprite list buffer the snapshot writes; the renderer reads the other (the frame before's)
    logic [31:0] spr_q0, spr_q1;
    logic [11:0] c_idx;                      // the palette's (stage C)
    logic [23:0] pal_q0, pal_q1;
    generate for (gi = 0; gi < 4; gi++) begin : g_disp
        rabbit_ram #(.AW(12), .DW(32)) u_tmd (.clk(clk), .we(sw_en), .wa(sw_idx), .d(tmc_q[gi]), .ra(tm_addr), .q(tm_q[gi]));
    end endgenerate
    rabbit_ram #(.AW(12), .DW(32)) u_spd0 (.clk(clk), .we(sw_en && !sw_idx[0]), .wa({sp_wb, sw_idx[11:1]}), .d(spc_q), .ra({!sp_wb, spr_addr}), .q(spr_q0));   // dword 0 of each sprite
    rabbit_ram #(.AW(12), .DW(32)) u_spd1 (.clk(clk), .we(sw_en &&  sw_idx[0]), .wa({sp_wb, sw_idx[11:1]}), .d(spc_q), .ra({!sp_wb, spr_addr}), .q(spr_q1));   // dword 1
    rabbit_ram #(.AW(12), .DW(24)) u_pald0 (.clk(clk), .we(sw_en), .wa(sw_idx), .d(palc_q[0][23:0]), .ra(c_idx), .q(pal_q0));   // palette 0x0000-0x0fff (sprites)
    rabbit_ram #(.AW(12), .DW(24)) u_pald1 (.clk(clk), .we(sw_en), .wa(sw_idx), .d(palc_q[2][23:0]), .ra(c_idx), .q(pal_q1));   // palette 0x2000-0x2fff (tiles)
    logic [31:0] dtmr  [4][6];
    logic [31:0] dsprr [7];
    logic [31:0] dvr   [2];

    // ================================================================== the snapshot
    logic        snap_pend, snap_act;
    logic [12:0] sc;                         // the copy's read address (bit 12: done)
    assign snap_hold = snap_pend || snap_act;

    // ================================================================== the CPU's port
    typedef enum logic [1:0] { V_IDLE, V_RD1, V_RD2 } vst_t;
    vst_t        vst;
    // decode of the live request
    wire  [1:0]  lyr   = v_addr[15:14];
    wire  [3:0]  m_sel = (v_addr[17:16] == 2'b00) ? {2'b00, lyr} :          // 480000-48ffff: the tilemaps
                         (v_addr[17:16] == 2'b01) ? 4'd4 :                   // 494000-497fff: the sprites
                                                    {2'b10, v_addr[15:14]};  // 4a0000-4affff: the palette
    wire [11:0]  m_idx = v_addr[13:2];
    wire  [3:0]  be32  = v_addr[1] ? {2'b00, v_be} : {v_be, 2'b00};
    // the registers: 400100 + 0x20 * layer + 4 * n (n < 6), 400200 + 4 * n (n < 7)
    wire         r_tm  = (v_addr[15:8] == 8'h01) && (v_addr[7] == 1'b0) && (v_addr[4:2] < 3'd6);
    wire         r_spr = (v_addr[15:8] == 8'h02) && (v_addr[7:5] == 3'd0) && (v_addr[4:2] < 3'd7);
    wire         r_vr  = (v_addr[15:8] == 8'h04) && (v_addr[7:5] == 3'd0) && (v_addr[4:2] == 3'd1 || v_addr[4:2] == 3'd2);   // 400404, 400408
    logic  [3:0] rd_sel;
    logic        rd_hi;                      // the high half of the dword (A1 = 0)
    logic        rd_reg;

    always_comb begin
        cw_en = 1'b0; cw_sel = m_sel; cw_idx = m_idx; cw_be = be32; cw_d = {v_wdata, v_wdata};
        if (b_we) begin
            cw_en = 1'b1; cw_sel = {2'b00, b_layer}; cw_idx = b_idx; cw_be = b_hi ? 4'b1100 : 4'b0011; cw_d = {b_data, b_data};
        end else if (vst == V_IDLE && v_req && v_we && v_mem && !snap_hold && !v_ack) begin
            cw_en = 1'b1;
        end
        cr_idx = snap_act ? sc[11:0] : m_idx;
    end

    function automatic logic [31:0] merge(input logic [31:0] old, input logic [3:0] be, input logic [15:0] d);
        logic [31:0] n;
        n = old;
        if (be[3]) n[31:24] = d[15:8];
        if (be[2]) n[23:16] = d[7:0];
        if (be[1]) n[15:8]  = d[15:8];
        if (be[0]) n[7:0]   = d[7:0];
        return n;
    endfunction

    // ================================================================== the raster
    logic  [3:0] sub;
    logic  [8:0] hcnt, vcnt;
    wire  [8:0]  hlast = board_rate ? 9'd423 : 9'd406;
    wire         line_start = (sub == 4'd0) && (hcnt == 9'd0);
    wire  [8:0]  va = (vcnt >= 9'd260) ? vcnt - 9'd260 : vcnt + 9'd2;     // stage A's line
    wire  [8:0]  vb = (vcnt == 9'd261) ? 9'd0 : vcnt + 9'd1;               // stage B's line
    always_ff @(posedge clk) begin
        if (reset) begin sub <= '0; hcnt <= '0; vcnt <= '0; end
        else begin
            sub <= (sub == 4'd14) ? 4'd0 : sub + 4'd1;
            if (sub == 4'd14) begin
                if (hcnt == hlast) begin hcnt <= '0; vcnt <= (vcnt == 9'd261) ? 9'd0 : vcnt + 9'd1; end
                else hcnt <= hcnt + 9'd1;
            end
        end
    end

    // ================================================================== the frame's sprite window (computed at the snapshot)
    logic [11:0] w_startx, w_starty, w_todraw;
    logic [11:0] w_todraw_n;                 // this frame's count, drawn next frame
    logic        nf_hold;                    // KO flash Off and this frame fills: the sprites shown stay the frame before's
    logic  [9:0] w_ncols, w_nrows;
    logic [16:0] xsize, ysize;
    logic [31:0] xstep, ystep;
    // two restoring dividers: 0xa0000000 / xsize, 0x70000000 / ysize
    logic  [5:0] dv_n;
    logic [31:0] dvx_q, dvy_q;
    logic [32:0] dvx_r, dvy_r;
    logic        dv_run;
    logic [31:0] q;                          // the CPU's read: the dword of rd_sel (the registers are write-only: MAME's writeonly)
    logic  [8:0] zc;                         // the sprite window's zoom compensation
    logic [32:0] tx, ty;                     // the dividers' shifted remainders
    always_comb begin
        case (rd_sel)
            4'd0, 4'd1, 4'd2, 4'd3: q = tmc_q[rd_sel[1:0]];
            4'd4:                   q = spc_q;
            default:                q = palc_q[rd_sel[1:0]];
        endcase
        if (rd_reg) q = 32'd0;
        zc = {1'b0, dsprr[1][8:1]};
        tx = {dvx_r[31:0], dvx_q[31]};
        ty = {dvy_r[31:0], dvy_q[31]};
    end

    always_ff @(posedge clk) begin
        v_ack <= 1'b0;
        vbl_irq <= 1'b0;
        dbg_frame <= 1'b0;
        sw_en <= 1'b0;
        if (reset) begin
            vst <= V_IDLE; snap_pend <= 1'b0; snap_act <= 1'b0; dv_run <= 1'b0; dv_n <= 6'd33;
            xstep <= 32'h10000; ystep <= 32'h10000; w_ncols <= 10'd320; w_nrows <= 10'd224; w_todraw <= '0; w_todraw_n <= '0; sp_wb <= 1'b0; nf_hold <= 1'b0; w_startx <= '0; w_starty <= '0;
            for (int l = 0; l < 4; l++) for (int n = 0; n < 6; n++) begin tmr[l][n] <= '0; dtmr[l][n] <= '0; end
            for (int n = 0; n < 7; n++) begin sprr[n] <= '0; dsprr[n] <= '0; end
            for (int n = 0; n < 2; n++) begin vr[n] <= '0; dvr[n] <= '0; end
        end else begin
            // vblank starts: MAME's frame update, then the vblank interrupt
            if (vcnt == 9'd224 && line_start) begin snap_pend <= 1'b1; vbl_irq <= 1'b1; end

            // ---------------------------------------------------- the CPU's accesses
            case (vst)
                V_IDLE: if (v_req && !v_ack && !snap_hold) begin
                    if (v_we) begin
                        if (!v_mem) begin
                            if (r_tm)  tmr[v_addr[6:5]][v_addr[4:2]] <= merge(tmr[v_addr[6:5]][v_addr[4:2]], be32, v_wdata);
                            if (r_spr) sprr[v_addr[4:2]] <= merge(sprr[v_addr[4:2]], be32, v_wdata);
                            if (r_vr)  vr[v_addr[3]] <= merge(vr[v_addr[3]], be32, v_wdata);
                            v_ack <= 1'b1;
                        end else if (!b_we) v_ack <= 1'b1;       // the write port was ours this clock (cw_en)
                    end else begin
                        rd_sel <= m_sel; rd_hi <= !v_addr[1]; rd_reg <= !v_mem;
                        vst <= V_RD1;
                    end
                end
                V_RD1: vst <= V_RD2;                              // the RAM's registered read
                V_RD2: begin
                    v_rdata <= rd_hi ? q[31:16] : q[15:0];
                    v_ack <= 1'b1; vst <= V_IDLE;
                end
                default: vst <= V_IDLE;
            endcase

            // ---------------------------------------------------- the snapshot
            if (snap_pend && !snap_act && vst == V_IDLE && !blt_active && !b_we) begin
                snap_pend <= 1'b0; snap_act <= 1'b1; sc <= '0;
                // the list copied last frame becomes the one drawn (KO flash Off, on a frame that fills: the one drawn stays, the
                // new list goes over the one copied last frame, and the next frame draws it)
                nf_hold <= no_flash && ({vr[0][7:0], vr[1][31:16]} != 24'd0);
                if (!(no_flash && ({vr[0][7:0], vr[1][31:16]} != 24'd0))) sp_wb <= !sp_wb;
                for (int l = 0; l < 4; l++) for (int n = 0; n < 6; n++) dtmr[l][n] <= tmr[l][n];
                for (int n = 0; n < 7; n++) dsprr[n] <= sprr[n];
                for (int n = 0; n < 2; n++) dvr[n] <= vr[n];
            end
            if (snap_act) begin
                sc <= sc + 13'd1;
                sw_en <= !sc[12]; sw_idx <= sc[11:0];             // the read of address sc lands next clock
                if (sc[12]) begin snap_act <= 1'b0; dbg_frame <= 1'b1; dv_run <= 1'b1; dv_n <= '0; end
            end

            // ---------------------------------------------------- the window, from the copied registers
            if (snap_act && sc == 13'd1) begin
                w_startx <= dsprr[0][11:0] - 12'(zc);
                w_starty <= dsprr[1][27:16] - 12'(zc);
                xsize <= {1'b0, dsprr[2][15:0]} + 17'h80;
                ysize <= {1'b0, dsprr[3][15:0]} + 17'h80;
                w_todraw_n <= dsprr[5][27:16];
                if (!nf_hold) w_todraw <= w_todraw_n;
            end
            if (snap_act && sc == 13'd2) begin
                w_ncols <= 10'((xsize + 17'd127) >> 7);
                w_nrows <= 10'((ysize + 17'd127) >> 7);
                dvx_r <= '0; dvy_r <= '0; dvx_q <= 32'ha0000000; dvy_q <= 32'h70000000;
            end
            if (dv_run) begin
                // one quotient bit a clock, 32 clocks
                if (tx >= {16'd0, xsize}) begin dvx_r <= tx - {16'd0, xsize}; dvx_q <= {dvx_q[30:0], 1'b1}; end
                else begin dvx_r <= tx; dvx_q <= {dvx_q[30:0], 1'b0}; end
                if (ty >= {16'd0, ysize}) begin dvy_r <= ty - {16'd0, ysize}; dvy_q <= {dvy_q[30:0], 1'b1}; end
                else begin dvy_r <= ty; dvy_q <= {dvy_q[30:0], 1'b0}; end
                dv_n <= dv_n + 6'd1;
                if (dv_n == 6'd31) dv_run <= 1'b0;
            end
            if (!dv_run && dv_n == 6'd32) begin xstep <= dvx_q; ystep <= dvy_q; dv_n <= 6'd33; end
        end
    end

    // the fill colour (xGRB: 407 G, 408 R, 409 B) and the translucent tiles' weight (405's high nibble: 0-15)
    wire  [23:0] fill_rgb = {dvr[0][7:0], dvr[1][31:24], dvr[1][23:16]};
    wire         fill_on  = (fill_rgb != 24'd0) && !nf_hold;
    wire   [3:0] fade_w   = dvr[0][23:20];

    // ================================================================== stage A
    logic        ta_busy, sa_busy;
    logic  [3:0] l_en;
    logic [15:0] l_sx [4], l_sy [4];
    logic [11:0] l_incxx [4], l_incyy [4];
    logic  [3:0] l_pri [4];
    always_comb for (int l = 0; l < 4; l++) begin
        l_pri[l]   = dtmr[l][0][27:24];
        l_en[l]    = (l_pri[l] != 4'd0);
        l_sx[l]    = dtmr[l][1][15:0];
        l_sy[l]    = dtmr[l][1][31:16];
        l_incxx[l] = dtmr[l][3][11:0];
        l_incyy[l] = dtmr[l][4][27:16];
    end

    wire a_go = line_start && (va < 9'd224);
    logic [3:0]  sb_we;
    logic [10:0] sb_waddr [4];
    logic [13:0] sb_wd [4];

    rabbit_tilegen u_tile (
        .clk(clk), .reset(reset), .start(a_go && !ta_busy), .line(va[7:0]), .busy(ta_busy),
        .en(l_en), .sx(l_sx), .sy(l_sy), .incxx(l_incxx), .incyy(l_incyy),
        .tm_addr(tm_addr), .tm_q(tm_q),
        .req(t_req), .addr(t_addr), .len(t_len), .ack(t_ack), .valid(t_valid), .data(sd_data),
        .sb_we(sb_we), .sb_addr(sb_waddr), .sb_d(sb_wd)
    );

    logic  [3:0] sp_we;
    logic [10:0] sp_waddr [4];
    logic [11:0] sp_wd [4];
    logic  [1:0] nj_now;
    logic  [1:0] nj_par [2];

    rabbit_sprgen u_spr (
        .clk(clk), .reset(reset), .start(a_go && !sa_busy), .line(va[7:0]), .busy(sa_busy), .nj(nj_now),
        .startx(w_startx), .starty(w_starty), .ncols(w_ncols), .nrows(w_nrows), .ystep(ystep), .todraw(w_todraw),
        .spr_addr(spr_addr), .spr_q0(spr_q0), .spr_q1(spr_q1),
        .req(s_req), .addr(s_addr), .len(s_len), .ack(s_ack), .valid(s_valid), .data(sd_data),
        .sp_we(sp_we), .sp_addr(sp_waddr), .sp_d(sp_wd)
    );

    // the number of bitmap rows of each parity's line, kept when stage A ends
    logic sa_busy_d;
    logic a_par;
    always_ff @(posedge clk) begin
        sa_busy_d <= sa_busy;
        if (a_go) a_par <= va[0];
        if (sa_busy_d && !sa_busy) nj_par[a_par] <= nj_now;
        if (reset) begin nj_par[0] <= 2'd0; nj_par[1] <= 2'd0; end
    end

    // the line buffers: srcbuf (4 lanes x {layer, parity, position[9:2]}), spbuf (4 lanes x {parity, row, column[9:2]})
    logic [10:0] srb_ra, spb_ra;
    logic [13:0] srb_q [4];
    logic [11:0] spb_q [4];
    generate for (gi = 0; gi < 4; gi++) begin : g_lbuf
        rabbit_ram #(.AW(11), .DW(14)) u_srcb (.clk(clk), .we(sb_we[gi]), .wa(sb_waddr[gi]), .d(sb_wd[gi]), .ra(srb_ra), .q(srb_q[gi]));
        rabbit_ram #(.AW(11), .DW(12)) u_spb  (.clk(clk), .we(sp_we[gi]), .wa(sp_waddr[gi]), .d(sp_wd[gi]), .ra(spb_ra), .q(spb_q[gi]));
    end endgenerate

    // ================================================================== stage B
    // comp: {parity, x}: {valid, tile (palette 0x2000 + idx) / sprite (0x0000 + idx), idx[11:0]}; {0, 1, 0}: the fill colour
    // cov:  {parity, x}: {valid, idx[11:0]}: a translucent tile pixel (palette 0x2000 + idx) over comp's
    logic        cmp_we, cov_we;
    logic  [9:0] cmp_wa, cov_wa;
    logic [13:0] cmp_wd;
    logic [12:0] cov_wd;
    logic  [9:0] cmp_ra;
    logic [13:0] cmp_q;
    logic [12:0] cov_q;
    rabbit_ram #(.AW(10), .DW(14)) u_comp (.clk(clk), .we(cmp_we), .wa(cmp_wa), .d(cmp_wd), .ra(cmp_ra), .q(cmp_q));
    rabbit_ram #(.AW(10), .DW(13)) u_cov  (.clk(clk), .we(cov_we), .wa(cov_wa), .d(cov_wd), .ra(cmp_ra), .q(cov_q));

    typedef enum logic [2:0] { B_IDLE, B_CLR, B_SEL, B_LAY, B_SPR, B_FILL, B_FLUSH } bst_t;
    bst_t        bs;
    logic        bpar;
    logic  [3:0] lvl;
    logic  [2:0] slot;
    logic  [1:0] blyr;
    logic  [9:0] bx;                         // output x (layer) / window column (sprites)
    logic [23:0] bcx;
    logic  [1:0] bk;
    logic [31:0] bax;
    // the read-data stage: what was read last clock, and where it goes
    logic        p1_v, p2_v;
    logic        p1_spr, p2_spr;
    logic  [1:0] p1_lane, p2_lane;
    logic  [8:0] p1_x, p2_x;
    logic        p1_in, p2_in;               // xd on the screen
    logic  [1:0] bnj;
    logic  [3:0] bflush;

    always_ff @(posedge clk) begin
        cmp_we <= 1'b0;
        cov_we <= 1'b0;
        // the pipeline: p1 = address presented (the RAM reads it at this edge), p2 = data on srb_q / spb_q
        p2_v <= p1_v; p2_spr <= p1_spr; p2_lane <= p1_lane; p2_x <= p1_x; p2_in <= p1_in;
        p1_v <= 1'b0;
        cmp_wa <= {bpar, p2_x}; cov_wa <= {bpar, p2_x}; cov_wd <= '0;
        if (p2_v) begin
            if (!p2_spr) begin
                if (srb_q[p2_lane][12]) begin
                    // a translucent pixel into cov (comp keeps what is beneath), an opaque one into comp (and over any cov)
                    cov_we <= 1'b1;
                    if (srb_q[p2_lane][13]) cov_wd <= {1'b1, srb_q[p2_lane][11:0]};
                    else begin cmp_we <= 1'b1; cmp_wd <= {1'b1, 1'b1, srb_q[p2_lane][11:0]}; end
                end
            end else begin
                if (spb_q[p2_lane] != 12'd0 && p2_in) begin cmp_we <= 1'b1; cov_we <= 1'b1; cmp_wd <= {1'b1, 1'b0, spb_q[p2_lane]}; end
            end
        end
        if (reset) begin
            bs <= B_IDLE; p1_v <= 1'b0; p2_v <= 1'b0;
        end else case (bs)
            B_IDLE: if (line_start && vb < 9'd224) begin
                bpar <= vb[0]; bx <= '0; bs <= B_CLR;
            end
            B_CLR: begin
                cmp_we <= 1'b1; cmp_wa <= {bpar, bx[8:0]}; cmp_wd <= 14'd0;
                cov_we <= 1'b1; cov_wa <= {bpar, bx[8:0]};
                if (bx == 10'd319) begin lvl <= 4'd15; slot <= 3'd0; bs <= B_SEL; end
                else bx <= bx + 10'd1;
            end
            B_SEL: begin
                // MAME's order: for each level from 15 down to 1, layers 3, 2, 1, 0 of that level, then (level 9) the fill colour and the
                // sprites; a layer's level is 8 + its priority's low 3 bits
                if (lvl == 4'd0) begin bflush <= 4'd0; bs <= B_FLUSH; end
                else begin
                    if (slot == 3'd4) begin slot <= 3'd0; lvl <= lvl - 4'd1; end
                    else slot <= slot + 3'd1;
                    if (slot < 3'd4) begin
                        if (l_en[2'd3 - slot[1:0]] && {1'b1, l_pri[2'd3 - slot[1:0]][2:0]} == lvl) begin
                            blyr <= 2'd3 - slot[1:0]; bx <= '0;
                            bcx <= {1'b0, l_sx[2'd3 - slot[1:0]], 7'd0};
                            bs <= B_LAY;
                        end
                    end else if (lvl == 4'd9 && (fill_on || nj_par[bpar] != 2'd0)) begin
                        bk <= 2'd0; bx <= '0; bax <= '0; bnj <= nj_par[bpar];
                        bs <= fill_on ? B_FILL : B_SPR;
                    end
                end
            end
            B_LAY: begin
                // pixel bx: tilemap column (sx * 128 + bx * incxx) >> 11, its srcbuf position mod 1024
                srb_ra <= {blyr, bpar, bcx[20:13]};
                p1_v <= 1'b1; p1_spr <= 1'b0; p1_lane <= bcx[12:11]; p1_x <= bx[8:0]; p1_in <= 1'b1;
                bcx <= bcx + 24'(l_incxx[blyr]);
                if (bx == 10'd319) bs <= B_SEL;
                else bx <= bx + 10'd1;
            end
            B_SPR: begin
                // window column bx of bitmap row bk: screen x = (bx * xstep) >> 16
                spb_ra <= {bpar, bk, bx[9:2]};
                p1_v <= 1'b1; p1_spr <= 1'b1; p1_lane <= bx[1:0]; p1_x <= bax[24:16]; p1_in <= (bax[31:16] < 16'd320);
                bax <= bax + xstep;
                if (bx == w_ncols - 10'd1) begin
                    bx <= '0; bax <= '0;
                    if (bk == bnj - 2'd1) bs <= B_SEL;
                    else bk <= bk + 2'd1;
                end else bx <= bx + 10'd1;
            end
            B_FILL: begin
                // the fill colour over everything drawn so far (the levels behind the sprites), then the sprites
                cmp_we <= 1'b1; cmp_wa <= {bpar, bx[8:0]}; cmp_wd <= 14'h1000;
                cov_we <= 1'b1; cov_wa <= {bpar, bx[8:0]};
                if (bx == 10'd319) begin bx <= '0; bs <= (bnj != 2'd0) ? B_SPR : B_SEL; end
                else bx <= bx + 10'd1;
            end
            B_FLUSH: begin
                bflush <= bflush + 4'd1;
                if (bflush == 4'd3) bs <= B_IDLE;
            end
            default: bs <= B_IDLE;
        endcase
    end

    // ================================================================== stage C: scan-out
    // during dot h (sub 1..3) the next dot's pixel is fetched: comp, then the palette; it is shown from the next dot's ce
    logic  [8:0] nh, nv;
    always_comb begin
        nh = (hcnt == hlast) ? 9'd0 : hcnt + 9'd1;
        nv = (hcnt == hlast) ? ((vcnt == 9'd261) ? 9'd0 : vcnt + 9'd1) : vcnt;
    end
    logic        n_vis;
    logic        c_sel, c_valid, c_fill, cv_valid;
    logic [11:0] cv_idx;
    logic [23:0] rgb_below, rgb_cov, rgb_next;
    logic [11:0] bl_s [3];                   // the blend's sums per channel (B, R, G), at most 255 * 15
    // x / 15 for x = 0..3825, exact on multiples of 15: (x * 273 + 2048) >> 12, 273 = 256 + 16 + 1
    function automatic logic [7:0] div15(input logic [11:0] x);
        logic [20:0] m;
        m = {1'b0, x, 8'd0} + {5'd0, x, 4'd0} + {9'd0, x} + 21'd2048;
        return m[19:12];
    endfunction
    always_ff @(posedge clk) begin
        ce_pix <= 1'b0;
        if (sub == 4'd0) begin
            cmp_ra <= {nv[0], nh};
            n_vis  <= (nh < 9'd320) && (nv < 9'd224);
        end
        if (sub == 4'd2) begin
            c_valid <= cmp_q[13] && n_vis; c_fill <= !cmp_q[13] && cmp_q[12] && n_vis; c_sel <= cmp_q[12]; c_idx <= cmp_q[11:0];
            cv_valid <= cov_q[12] && n_vis; cv_idx <= cov_q[11:0];
        end
        // the pixel beneath, then (palette 0x2000) the translucent one, blended: (cov * (15 - w) + beneath * w) / 15
        if (sub == 4'd4) begin rgb_below <= c_fill ? fill_rgb : !c_valid ? 24'd0 : c_sel ? pal_q1 : pal_q0; c_idx <= cv_idx; end
        if (sub == 4'd6) rgb_cov <= pal_q1;
        if (sub == 4'd7) for (int ch = 0; ch < 3; ch++)
            bl_s[ch] <= 12'(rgb_cov[8*ch +: 8]) * 12'(4'd15 - fade_w) + 12'(rgb_below[8*ch +: 8]) * 12'(fade_w);
        if (sub == 4'd8) rgb_next <= cv_valid ? {div15(bl_s[2]), div15(bl_s[1]), div15(bl_s[0])} : rgb_below;
        if (sub == 4'd14) begin
            // the next dot begins: show what was fetched for it
            ce_pix <= 1'b1;
            // xGRB_888: G in 23:16, R in 15:8, B in 7:0
            r <= rgb_next[15:8]; g <= rgb_next[23:16]; b <= rgb_next[7:0];
            hblank <= !(nh < 9'd320);
            vblank <= !(nv < 9'd224);
            vblank_next <= (nv >= 9'd223) && (nv != 9'd261);
            hs     <= (nh >= 9'd336) && (nh < 9'd368);
            vs     <= (nv >= 9'd232) && (nv < 9'd235);
        end
    end

    // ================================================================== diagnostics: a stage still busy when its next line starts
    always_ff @(posedge clk) begin
        if (reset) begin dbg_overrun_a <= '0; dbg_overrun_b <= '0; end
        else if (line_start) begin
            if (va < 9'd224 && (ta_busy || sa_busy) && dbg_overrun_a != 16'hffff) dbg_overrun_a <= dbg_overrun_a + 16'd1;
            if (vb < 9'd224 && bs != B_IDLE && dbg_overrun_b != 16'hffff) dbg_overrun_b <= dbg_overrun_b + 16'd1;
        end
    end
endmodule
`default_nettype wire
