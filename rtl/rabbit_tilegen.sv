//------------------------------------------------------------------------------
// The tilemaps' fetch stage (rabbit_video.sv, stage A): for one output line, the tiles of each enabled layer that the line's 320 pixels
// sample are read from the tilemap (the frame's snapshot) and their pixel rows from the SDRAM, decoded and written into the layer's source
// line buffer (srcbuf: 1024 pixels a layer, indexed by the tilemap column modulo 1024).
//
// MAME draws each layer with draw_roz (rabbit_state::drawtilemap): output pixel (x, y) shows tilemap pixel
//     column ((sx * 128 + x * incxx) >> 11) mod width,   row ((sy * 128 + y * incyy) >> 11) mod height
// (sx, sy: the scroll register's 12.4 values, incxx / incyy: 1.11 zoom steps; layers 0-2 are 128 x 32 tiles of 16 x 16, layer 3 of 8 x 8).
// One row of the tilemap per line, so this stage only needs the columns [sx*128 >> 11, (sx*128 + 319*incxx) >> 11]: at most 640 pixels.
//
// Tile entry (get_tilemap_info): bit 31 colour mask, 30:29 TILE_FLIPXY (which swaps them: 30 flip X, 29 flip Y), 28 depth (8bpp),
// 27:20 colour, 19:16 bank, 15:0 tile.
// Bank 8 adds 0x10000 to the tile number, bank C 0x20000, the others nothing. 4bpp tiles: palette 0x2000 + colour*16 + pen (colour & 0x3f
// with the colour mask), pen 15 transparent; 8bpp tiles: 0x2000 + (colour & 0xf)*256 + pen, pen 255 transparent. The tile number counts
// 32-byte units: the row of a tile is at byte  (code & ~mask) * 32 + row * rowbytes  of gfx2 (rowbytes 8 / 16 / 4 / 8 for 16x16x4, 16x16x8,
// 8x8x4, 8x8x8). A pixel in srcbuf is {translucent, opaque, idx[11:0]}: the palette entry 0x2000 + idx. Translucent: an 8bpp tile with
// bit 31 set, which MAME draws opaque; the board blends it over what is beneath (rabbit_video.sv, the fade).
//------------------------------------------------------------------------------
`default_nettype none

module rabbit_tilegen #(
    parameter logic [23:0] GFX2_W = 24'h900000     // gfx2's first word in the SDRAM
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,              // one clock: fetch line `line`
    input  logic  [7:0] line,
    output logic        busy,

    // the snapshot's registers
    input  logic  [3:0] en,                 // layer enabled (priority != 0)
    input  logic [15:0] sx    [4],
    input  logic [15:0] sy    [4],
    input  logic [11:0] incxx [4],
    input  logic [11:0] incyy [4],

    // the tilemaps (the snapshot), one read port shared by the four: entry tm_addr, registered output one clock later
    output logic [11:0] tm_addr,
    input  logic [31:0] tm_q [4],

    // the SDRAM client
    output logic        req,
    output logic [23:0] addr,
    output logic  [4:0] len,
    input  logic        ack,
    input  logic        valid,
    input  logic [15:0] data,

    // srcbuf: four lanes (pixel position mod 4), entry {layer, parity, position[9:2]}
    output logic  [3:0] sb_we,
    output logic [10:0] sb_addr [4],
    output logic [13:0] sb_d    [4]
);
    // ------------------------------------------------------------------ the request side
    typedef enum logic [2:0] { R_IDLE, R_SETUP, R_ROW, R_RD, R_DEC, R_REQ, R_NEXT, R_WAIT } rst_t;
    rst_t        rs;
    logic  [1:0] lyr;
    logic        par;
    logic  [7:0] ln;
    logic [23:0] cy, cxl;
    logic  [8:0] srow;                       // source row within the map (512 / 256 rows)
    logic  [9:0] t, t_last;                  // tile column (not wrapped)
    logic  [3:0] trow_r;                     // row within the tile (unflipped)

    wire         ts16 = (lyr != 2'd3);

    // the descriptor of each request in flight
    typedef struct packed {
        logic  [1:0] lyr;
        logic  [9:0] pos;                    // the tile's first pixel in srcbuf
        logic        flipx;
        logic        depth;                  // 8bpp
        logic        tr;                     // translucent (8bpp, bit 31)
        logic        ts16;
        logic  [7:0] col;                    // 4bpp: the colour (masked); 8bpp: colour & 0xf in 3:0
        logic  [3:0] nw;                     // words - 1
    } desc_t;
    desc_t       dq [4];
    logic  [2:0] dq_wp, dq_rp;
    wire   [2:0] dq_n = dq_wp - dq_rp;
    desc_t       nd;                         // the request being prepared

    // tile entry decode
    logic [31:0] e;
    logic [17:0] eff;
    logic [23:0] baddr;                      // byte address in gfx2
    always_comb begin
        e = tm_q[lyr];
        case (e[19:16])
            4'h8:    eff = {2'b00, e[15:0]} + 18'h10000;
            4'hc:    eff = {2'b00, e[15:0]} + 18'h20000;
            default: eff = {2'b00, e[15:0]};
        endcase
        // the row inside the tile, flipped
        if (ts16) begin
            if (e[28]) baddr = {1'b0, eff[17:3], 8'd0} + {16'd0, (e[29] ? ~trow_r : trow_r), 4'd0};          // 16x16x8: 256 B, rows of 16
            else       baddr = {1'b0, eff[17:2], 7'd0} + {17'd0, (e[29] ? ~trow_r : trow_r), 3'd0};          // 16x16x4: 128 B, rows of 8
        end else begin
            if (e[28]) baddr = {1'b0, eff[17:1], 6'd0} + {18'd0, (e[29] ? ~trow_r[2:0] : trow_r[2:0]), 3'd0};  // 8x8x8: 64 B, rows of 8
            else       baddr = {1'b0, eff[17:0], 5'd0} + {19'd0, (e[29] ? ~trow_r[2:0] : trow_r[2:0]), 2'd0};  // 8x8x4: 32 B, rows of 4
        end
    end

    logic        land_done;                  // every descriptor has landed (dq empty)
    assign land_done = (dq_n == 3'd0);

    always_ff @(posedge clk) begin
        if (ack) req <= 1'b0;
        if (reset) begin
            rs <= R_IDLE; busy <= 1'b0; req <= 1'b0; dq_wp <= '0;
        end else case (rs)
            R_IDLE: if (start) begin
                busy <= 1'b1; ln <= line; par <= line[0]; lyr <= 2'd0; rs <= R_SETUP;
            end
            R_SETUP: begin
                // the layer's row and column span
                if (!en[lyr]) rs <= R_NEXT;
                else begin
                    cy  <= {1'b0, sy[lyr], 7'd0} + 24'(ln) * 24'(incyy[lyr]);
                    cxl <= {1'b0, sx[lyr], 7'd0} + 24'd319 * 24'(incxx[lyr]);
                    rs  <= R_ROW;
                end
            end
            R_ROW: begin
                srow <= ts16 ? cy[19:11] : {1'b0, cy[18:11]};
                trow_r <= ts16 ? cy[14:11] : {1'b0, cy[13:11]};
                // first and last tile column (sx * 128 >> 11 = sx >> 4)
                t      <= ts16 ? {2'b00, sx[lyr][15:8]} : {1'b0, sx[lyr][15:7]};
                t_last <= ts16 ? {1'b0, cxl[23:15]} : cxl[23:14];
                rs <= R_RD;
            end
            R_RD: begin
                // the tile entry: row srow / tile size, column t mod 128
                tm_addr <= ts16 ? {srow[8:4], t[6:0]} : {srow[7:3], t[6:0]};
                rs <= R_DEC;
            end
            R_DEC: rs <= R_REQ;                                 // tm_q is the entry now (registered read)
            R_REQ: begin
                if (!req && dq_n < 3'd4) begin
                    req  <= 1'b1;
                    addr <= GFX2_W + baddr[23:1];
                    len  <= ts16 ? (e[28] ? 5'd8 : 5'd4) : (e[28] ? 5'd4 : 5'd2);
                    nd.lyr   <= lyr;
                    nd.pos   <= ts16 ? {t[5:0], 4'd0} : {t[6:0], 3'd0};
                    nd.flipx <= e[30];
                    nd.depth <= e[28];
                    nd.tr    <= e[28] & e[31];
                    nd.ts16  <= ts16;
                    nd.col   <= e[28] ? {4'd0, e[23:20]} : (e[31] ? {2'b00, e[25:20]} : e[27:20]);
                    nd.nw    <= ts16 ? (e[28] ? 4'd7 : 4'd3) : (e[28] ? 4'd3 : 4'd1);
                    rs <= R_WAIT;
                end
            end
            R_WAIT: if (ack) begin
                dq[dq_wp[1:0]] <= nd; dq_wp <= dq_wp + 3'd1;
                if (t == t_last) rs <= R_NEXT;
                else begin t <= t + 10'd1; rs <= R_RD; end
            end
            R_NEXT: begin
                if (lyr == 2'd3) begin
                    if (land_done) begin busy <= 1'b0; rs <= R_IDLE; end
                end else begin
                    lyr <= lyr + 2'd1; rs <= R_SETUP;
                end
            end
            default: rs <= R_IDLE;
        endcase
    end

    // ------------------------------------------------------------------ the landing side
    logic [3:0] wi;                          // word of the head descriptor
    desc_t      h;
    assign h = dq[dq_rp[1:0]];

    // the four lanes a word writes: 4bpp = 4 pixels (pens w[11:8], w[15:12], w[3:0], w[7:4]), 8bpp = 2 (w[15:8], w[7:0])
    logic  [3:0] l_we;
    logic [10:0] l_addr [4];
    logic [13:0] l_d    [4];
    always_comb begin
        for (int i = 0; i < 4; i++) begin l_we[i] = 1'b0; l_addr[i] = '0; l_d[i] = '0; end
        for (int m = 0; m < 4; m++) begin : px
            logic [9:0]  j;                  // pixel of the tile row
            logic [9:0]  p;                  // its srcbuf position
            logic [7:0]  pen;
            logic        opq;
            logic [11:0] idx;
            if (!h.depth) begin
                j = {4'd0, wi[1:0], 2'd0} + 10'(m);
                case (m)
                    0: pen = {4'd0, data[11:8]};
                    1: pen = {4'd0, data[15:12]};
                    2: pen = {4'd0, data[3:0]};
                    default: pen = {4'd0, data[7:4]};
                endcase
                opq = (pen[3:0] != 4'hf);
                idx = {h.col, pen[3:0]};
            end else begin
                j = {5'd0, wi[2:0], 1'b0} + 10'(m & 1);
                pen = m[0] ? data[7:0] : data[15:8];
                opq = (pen != 8'hff);
                idx = {h.col[3:0], pen};
            end
            if (h.flipx) p = h.pos + (h.ts16 ? 10'd15 : 10'd7) - j;
            else         p = h.pos + j;
            if (!h.depth || m < 2) begin
                l_we[p[1:0]]   = 1'b1;
                l_addr[p[1:0]] = {h.lyr, par, p[9:2]};
                l_d[p[1:0]]    = {h.tr, opq, idx};
            end
        end
    end

    always_ff @(posedge clk) begin
        sb_we <= 4'b0000;
        if (reset) begin
            dq_rp <= '0; wi <= '0;
        end else if (valid) begin
            sb_we <= l_we;
            for (int i = 0; i < 4; i++) begin sb_addr[i] <= l_addr[i]; sb_d[i] <= l_d[i]; end
            if (wi == h.nw) begin wi <= '0; dq_rp <= dq_rp + 3'd1; end
            else wi <= wi + 4'd1;
        end
    end
endmodule
`default_nettype wire
