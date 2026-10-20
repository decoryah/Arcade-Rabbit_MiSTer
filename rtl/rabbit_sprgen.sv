//------------------------------------------------------------------------------
// The sprites' fetch stage (rabbit_video.sv, stage A).
//
// MAME (rabbit_state::draw_sprites / draw_sprite_bitmap) draws the sprite list into a 4096 x 4096 bitmap and then copies a window of it to
// the screen, scaled: window column i (0 .. ncols-1) is bitmap column (startx + i) & 0xfff and goes to screen x = (i * xstep) >> 16, window
// row j (0 .. nrows-1) is bitmap row (starty + j) & 0xfff and goes to screen y = (j * ystep) >> 16, a later pixel overwriting an earlier
// one where it is not 0. The window and steps come from the sprite registers (rabbit_video.sv computes them at the snapshot).
//
// So an output line y is made of the bitmap rows j with (j * ystep) >> 16 == y: none, one, or (zoomed out) up to three. For each of them
// this stage draws the bitmap row's window columns into a line of spbuf (1024 pixels, four lanes by column mod 4): every sprite of the
// list, from the last to the first (the first ends up on top), that covers the row, pens != 15 written as colour * 16 + pen.
//
// Sprite (two dwords): dword 0 bits 11:0 x (signed), 27:16 y, 15 flip X (drawn mirrored when clear: MAME's "!xflip"), 14 flip Y;
// dword 1 bits 16:0 tile, 27:20 colour. It covers bitmap columns x + 24 .. +15 and rows y - 24 .. +15, clipped to the bitmap.
// A tile is 16 x 16 4bpp, 64 bytes in each half of gfx1 (sprite_16x16x4_layout): pixels 0-7 of a row in the upper half, 8-15 in the lower;
// rabbit_loader.sv puts both halves of a row next to each other: the row is the 4 SDRAM words GFX1_W + {tile, row, 00}: pixels 8-11, 12-15,
// 0-3, 4-7, each word's pens w[7:4], w[3:0], w[15:12], w[11:8].
//------------------------------------------------------------------------------
`default_nettype none

module rabbit_sprgen #(
    parameter logic [23:0] GFX1_W = 24'h100000
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,              // one clock: fetch line `line`
    input  logic  [7:0] line,
    output logic        busy,
    output logic  [1:0] nj,                 // bitmap rows drawn for the line (valid when !busy)

    // the frame's window (rabbit_video)
    input  logic [11:0] startx,
    input  logic [11:0] starty,
    input  logic  [9:0] ncols,
    input  logic  [9:0] nrows,
    input  logic [31:0] ystep,
    input  logic [11:0] todraw,

    // the sprite list (the snapshot): sprite spr_addr's two dwords, registered output one clock after the address
    output logic [10:0] spr_addr,
    input  logic [31:0] spr_q0,
    input  logic [31:0] spr_q1,

    // the SDRAM client
    output logic        req,
    output logic [23:0] addr,
    output logic  [4:0] len,
    input  logic        ack,
    input  logic        valid,
    input  logic [15:0] data,

    // spbuf: four lanes (column mod 4), entry {parity, row k, column[9:2]}
    output logic  [3:0] sp_we,
    output logic [10:0] sp_addr [4],
    output logic [11:0] sp_d    [4]
);
    typedef enum logic [2:0] { S_IDLE, S_J, S_CLR, S_SCAN, S_DRAIN } st_t;
    st_t         st;
    logic        par;
    logic  [7:0] ln;
    logic  [9:0] j_next;
    logic [31:0] acc;
    logic [11:0] sl [3];                     // the bitmap rows of the line
    logic  [1:0] k_clr;
    logic  [7:0] e_clr;
    wire   [7:0] n_ent = 8'((ncols + 10'd3) >> 2);   // window entries per lane

    // ------------------------------------------------------------------ the draw queue: one entry per (sprite, row) to fetch
    logic  [1:0] wq_k    [8];
    logic [16:0] wq_tile [8];
    logic  [3:0] wq_r    [8];
    logic [13:0] wq_dx   [8];
    logic        wq_flip [8];
    logic  [7:0] wq_colr [8];
    logic  [3:0] wq_wp, wq_rp;
    wire   [3:0] wq_n = wq_wp - wq_rp;

    // ------------------------------------------------------------------ the scan
    // A pipeline: the sprite's address goes out (v0), its two dwords are on spr_q (v1), then two registered decode stages (v2: the
    // positions; v3: the rows and the hits), and a sprite that covers any of the line's rows goes into a small FIFO, from which its rows
    // go into the draw queue one a clock. The issue pauses while the FIFO could not take what is in flight; the order is kept.
    logic [11:0] s_cnt;                      // sprites still to issue (the next is s_cnt - 1)
    logic        v0, v1, v2, v3;
    logic [13:0] d1_dx, d1_dy;               // stage 2: from spr_q
    logic [16:0] d1_tile;
    logic        d1_flip, d1_yflip;
    logic  [7:0] d1_colr;
    logic  [2:0] d2_hit;                     // stage 3
    logic  [3:0] d2_row [3];
    logic [13:0] d2_dx;
    logic [16:0] d2_tile;
    logic        d2_flip;
    logic  [7:0] d2_colr;
    // the decode of stage 3 (from stage 2's registers)
    logic [13:0] row_k [3];
    logic  [2:0] hit;
    logic        vis;
    logic [11:0] dwin;
    always_comb begin
        dwin = d1_dx[11:0] - startx;
        // some of its 16 columns fall in the window (the bitmap's own edges are clipped at the landing)
        vis  = (dwin < 12'(ncols)) || (dwin >= 12'd4081);
        for (int k = 0; k < 3; k++) begin
            row_k[k] = {2'b00, sl[k]} - d1_dy;
            hit[k]   = (2'(k) < nj) && (row_k[k][13:4] == 10'd0) && vis;
        end
    end
    // the FIFO of sprites with hits
    logic  [2:0] hf_hit  [8];
    logic  [3:0] hf_row  [8][3];
    logic [13:0] hf_dx   [8];
    logic [16:0] hf_tile [8];
    logic        hf_flip [8];
    logic  [7:0] hf_colr [8];
    logic  [3:0] hf_wp, hf_rp;
    wire   [3:0] hf_n = hf_wp - hf_rp;
    // the sprite whose rows are being queued
    logic  [2:0] xp;
    logic  [3:0] x_row [3];
    logic [13:0] x_dx;
    logic [16:0] x_tile;
    logic        x_flip;
    logic  [7:0] x_colr;
    logic  [1:0] x_k;                        // its lowest row still to queue
    always_comb x_k = xp[0] ? 2'd0 : xp[1] ? 2'd1 : 2'd2;

    logic  [2:0] ld_n;                       // fetches in flight (the landing side)
    wire         scanning = (st == S_SCAN);

    always_ff @(posedge clk) begin
        if (reset) begin
            st <= S_IDLE; busy <= 1'b0; nj <= 2'd0; j_next <= '0; acc <= '0; wq_wp <= '0; s_cnt <= '0;
            v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; hf_wp <= '0; hf_rp <= '0; xp <= 3'b000;
        end else begin
            // ---------------------------------------------------- the scan pipeline (runs in S_SCAN)
            v0 <= 1'b0;
            v1 <= v0; v2 <= v1; v3 <= v2;
            if (scanning && s_cnt != 12'd0 && hf_n < 4'd4) begin
                spr_addr <= 11'(s_cnt - 12'd1);
                s_cnt <= s_cnt - 12'd1;
                v0 <= 1'b1;
            end
            if (v1) begin
                d1_dx    <= {{2{spr_q0[11]}}, spr_q0[11:0]} + 14'd24;
                d1_dy    <= {2'b00, spr_q0[27:16]} - 14'd24;
                d1_tile  <= spr_q1[16:0];
                d1_flip  <= ~spr_q0[15];
                d1_yflip <= spr_q0[14];
                d1_colr  <= spr_q1[27:20];
            end
            if (v2) begin
                d2_hit <= hit;
                for (int k = 0; k < 3; k++) d2_row[k] <= d1_yflip ? ~row_k[k][3:0] : row_k[k][3:0];
                d2_dx <= d1_dx; d2_tile <= d1_tile; d2_flip <= d1_flip; d2_colr <= d1_colr;
            end
            if (v3 && d2_hit != 3'b000) begin
                hf_hit[hf_wp[2:0]] <= d2_hit;
                for (int k = 0; k < 3; k++) hf_row[hf_wp[2:0]][k] <= d2_row[k];
                hf_dx[hf_wp[2:0]] <= d2_dx; hf_tile[hf_wp[2:0]] <= d2_tile; hf_flip[hf_wp[2:0]] <= d2_flip; hf_colr[hf_wp[2:0]] <= d2_colr;
                hf_wp <= hf_wp + 4'd1;
            end
            // ---------------------------------------------------- the rows of the FIFO's sprites into the draw queue, one a clock
            if (xp == 3'b000) begin
                if (hf_n != 4'd0) begin
                    xp <= hf_hit[hf_rp[2:0]];
                    for (int k = 0; k < 3; k++) x_row[k] <= hf_row[hf_rp[2:0]][k];
                    x_dx <= hf_dx[hf_rp[2:0]]; x_tile <= hf_tile[hf_rp[2:0]]; x_flip <= hf_flip[hf_rp[2:0]]; x_colr <= hf_colr[hf_rp[2:0]];
                    hf_rp <= hf_rp + 4'd1;
                end
            end else if (wq_n < 4'd8) begin
                wq_k[wq_wp[2:0]]    <= x_k;
                wq_tile[wq_wp[2:0]] <= x_tile;
                wq_r[wq_wp[2:0]]    <= x_row[x_k];
                wq_dx[wq_wp[2:0]]   <= x_dx;
                wq_flip[wq_wp[2:0]] <= x_flip;
                wq_colr[wq_wp[2:0]] <= x_colr;
                wq_wp <= wq_wp + 4'd1;
                xp[x_k] <= 1'b0;
            end

            case (st)
                S_IDLE: if (start) begin
                    busy <= 1'b1; ln <= line; par <= line[0]; nj <= 2'd0;
                    if (line == 8'd0) begin j_next <= '0; acc <= '0; end
                    st <= S_J;
                end
                S_J: begin
                    // the next bitmap row belongs to this line: take it (at most three)
                    if (nj != 2'd3 && j_next < nrows && acc[31:16] == {8'd0, ln}) begin
                        sl[nj] <= starty + 12'(j_next);
                        nj <= nj + 2'd1; j_next <= j_next + 10'd1; acc <= acc + ystep;
                    end else begin
                        k_clr <= 2'd0; e_clr <= 8'd0;
                        st <= (nj == 2'd0) ? S_DRAIN : S_CLR;
                    end
                end
                S_CLR: begin
                    // clear the window of each of the line's rows (the writes are in the landing block)
                    if (e_clr + 8'd1 >= n_ent) begin
                        e_clr <= 8'd0;
                        if (k_clr == nj - 2'd1) begin
                            s_cnt <= (todraw > 12'd2048) ? 12'd2048 : todraw;
                            st <= S_SCAN;
                        end else k_clr <= k_clr + 2'd1;
                    end else e_clr <= e_clr + 8'd1;
                end
                S_SCAN: begin
                    // everything issued has gone through the pipeline and the FIFO
                    if (s_cnt == 12'd0 && !v0 && !v1 && !v2 && !v3 && hf_n == 4'd0 && xp == 3'b000) st <= S_DRAIN;
                end
                S_DRAIN: begin
                    if (wq_n == 4'd0 && !req && ld_n == 3'd0) begin busy <= 1'b0; st <= S_IDLE; end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------ the fetch requests
    logic  [1:0] lq_k    [4];
    logic [13:0] lq_dx   [4];
    logic        lq_flip [4];
    logic  [7:0] lq_colr [4];
    logic  [2:0] lq_wp, lq_rp;
    assign ld_n = lq_wp - lq_rp;
    logic  [1:0] n_k;
    logic [13:0] n_dx;
    logic        n_flip;
    logic  [7:0] n_colr;
    wire   [2:0] wr = wq_rp[2:0];

    always_ff @(posedge clk) begin
        if (ack) req <= 1'b0;
        if (reset) begin
            req <= 1'b0; wq_rp <= '0; lq_wp <= '0;
        end else begin
            if (!req && wq_n != 4'd0 && ld_n < 3'd3) begin
                req    <= 1'b1;
                addr   <= GFX1_W + 24'({wq_tile[wr], wq_r[wr], 2'b00});
                len    <= 5'd4;
                n_k    <= wq_k[wr]; n_dx <= wq_dx[wr]; n_flip <= wq_flip[wr]; n_colr <= wq_colr[wr];
                wq_rp  <= wq_rp + 4'd1;
            end
            if (ack) begin
                lq_k[lq_wp[1:0]] <= n_k; lq_dx[lq_wp[1:0]] <= n_dx; lq_flip[lq_wp[1:0]] <= n_flip; lq_colr[lq_wp[1:0]] <= n_colr;
                lq_wp <= lq_wp + 3'd1;
            end
        end
    end

    // ------------------------------------------------------------------ the landing
    logic  [1:0] wi;
    wire   [1:0] lr = lq_rp[1:0];

    logic  [3:0] l_we;
    logic [10:0] l_addr [4];
    logic [11:0] l_d    [4];
    always_comb begin
        for (int i = 0; i < 4; i++) begin l_we[i] = 1'b0; l_addr[i] = '0; l_d[i] = '0; end
        for (int m = 0; m < 4; m++) begin : px
            logic [3:0]  i;                  // pixel of the sprite row
            logic [3:0]  pen;
            logic [13:0] col;
            logic [11:0] ib;
            case (wi)
                2'd0:    i = 4'd8  + 4'(m);
                2'd1:    i = 4'd12 + 4'(m);
                2'd2:    i = 4'd0  + 4'(m);
                default: i = 4'd4  + 4'(m);
            endcase
            case (m)
                0:       pen = data[7:4];
                1:       pen = data[3:0];
                2:       pen = data[15:12];
                default: pen = data[11:8];
            endcase
            col = lq_dx[lr] + 14'(lq_flip[lr] ? 4'd15 - i : i);
            ib  = col[11:0] - startx;
            if (pen != 4'hf && col[13:12] == 2'b00 && ib < 12'(ncols)) begin
                l_we[ib[1:0]]   = 1'b1;
                l_addr[ib[1:0]] = {par, lq_k[lr], ib[9:2]};
                l_d[ib[1:0]]    = {lq_colr[lr], pen};
            end
        end
    end

    always_ff @(posedge clk) begin
        sp_we <= 4'b0000;
        if (reset) begin
            lq_rp <= '0; wi <= '0;
        end else begin
            if (st == S_CLR) begin
                sp_we <= 4'b1111;
                for (int i = 0; i < 4; i++) begin sp_addr[i] <= {par, k_clr, e_clr}; sp_d[i] <= 12'd0; end
            end else if (valid) begin
                sp_we <= l_we;
                for (int i = 0; i < 4; i++) begin sp_addr[i] <= l_addr[i]; sp_d[i] <= l_d[i]; end
                wi <= wi + 2'd1;
                if (wi == 2'd3) lq_rp <= lq_rp + 3'd1;
            end
        end
    end
endmodule
`default_nettype wire
