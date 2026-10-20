//------------------------------------------------------------------------------
// The I5000's blitter as MAME 0.289 does it (rabbit_state::do_blit): a list of commands in gfx1 writes 16-bit halves of tilemap entries.
//
//   regs[0] & 0xfffff  the list's first word (gfx1 word index; words are little-endian: the even byte is the low one)
//   regs[1] 23:16      the start column (8 bits; after a write the column counts modulo 128)      regs[1] 7:0  the start line
//   regs[2] 15:13      the tilemap                                                                  regs[2] 0    1: the entries' low halves (the tile
//                                                                                                                 number), 0: the high halves
//   a command word: low byte = count, high byte = command
//     00, count 0: the end;  00: copy `count` words;  02: write the next word `count` times;  03: back to the start column, next line;
//     anything else: nothing.  An entry is (line * 128 + column); only tilemaps 0-3 and entries 0-4095 exist (MAME's larger buffer is
//     never shown).
//
// MAME does the whole list at the instant of the write that starts it (a word write to 40070e) and raises IRQ 4 500 us later. Here the
// list is read from the SDRAM a pair of words at a time (both halves of a pair are next to each other: rabbit_loader.sv), a write a clock;
// the interrupt comes 500 us after the start as in MAME. A start while the video chip copies its frame (`hold`) waits for the copy.
//------------------------------------------------------------------------------
`default_nettype none

module rabbit_blitter #(
    parameter logic [23:0] GFX1_W = 24'h100000,
    parameter int          IRQ_CLOCKS = 48000         // 500 us at 96 MHz
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] regs [3],
    input  logic        hold,
    output logic        active,             // working through a list
    output logic        busy,               // active, or a start waiting (the status bit the game polls)
    output logic        irq,                // one clock: the blit-done interrupt

    // the SDRAM client
    output logic        req,
    output logic [23:0] addr,
    output logic  [4:0] len,
    input  logic        ack,
    input  logic        valid,
    input  logic [15:0] data,

    // the tilemap writes
    output logic        b_we,
    output logic  [1:0] b_layer,
    output logic [11:0] b_idx,
    output logic        b_hi,
    output logic [15:0] b_data
);
    // ------------------------------------------------------------------ the interrupt timer
    logic [15:0] tmr;
    logic        tmr_on;
    always_ff @(posedge clk) begin
        irq <= 1'b0;
        if (reset) tmr_on <= 1'b0;
        else if (start) begin tmr_on <= 1'b1; tmr <= 16'(IRQ_CLOCKS - 1); end
        else if (tmr_on) begin
            if (tmr == 16'd0) begin tmr_on <= 1'b0; irq <= 1'b1; end
            else tmr <= tmr - 16'd1;
        end
    end

    // ------------------------------------------------------------------ the word prefetch: pairs of gfx1 words into an 8-word FIFO
    logic [22:0] fp;                         // the next pair's first word (even)
    logic        skip1;                      // drop the first word of the first pair (the list starts at an odd word)
    logic [15:0] fifo [8];
    logic  [3:0] f_wp, f_rp;
    wire   [3:0] f_n = f_wp - f_rp;
    logic  [2:0] inflight;                   // words requested, not yet landed
    logic        fetch_on;

    always_ff @(posedge clk) begin
        if (ack) req <= 1'b0;
        if (reset) begin
            req <= 1'b0; f_wp <= '0; inflight <= '0;
        end else begin
            // request the next pair when the FIFO has room for it and for what is in flight
            if (fetch_on && !st_begin && !req && (5'(f_n) + 5'(inflight) + 5'd2 <= 5'd8)) begin
                req <= 1'b1; addr <= GFX1_W + {1'b0, fp[21:1], fp[22], 1'b0}; len <= 5'd2;
                fp <= fp + 23'd2;
            end
            inflight <= inflight + ((req && ack) ? 3'd2 : 3'd0) - (valid ? 3'd1 : 3'd0);
            // the words land in order; after a list's end they still land (the next list starts with an empty FIFO)
            if (valid) begin
                if (skip1) skip1 <= 1'b0;
                else begin fifo[f_wp[2:0]] <= data; f_wp <= f_wp + 4'd1; end
            end
            if (st_begin) begin f_wp <= '0; skip1 <= regs[0][0]; fp <= {3'd0, regs[0][19:1], 1'b0}; end
        end
    end
    wire [15:0] w = fifo[f_rp[2:0]];
    wire        have = (f_n != 4'd0);

    // ------------------------------------------------------------------ the list
    typedef enum logic [2:0] { L_IDLE, L_WAIT, L_CMD, L_COPY, L_FILLV, L_FILL, L_FLUSH } lst_t;
    lst_t        ls;
    logic        pend;
    logic  [7:0] col0, col;
    logic [15:0] lineoff;
    logic  [2:0] tmap;
    logic        hi;
    logic  [7:0] n;
    logic [15:0] fillv;
    logic        st_begin, st_end;
    // st_begin: a list starts (the prefetch restarts at regs[0]); st_end: its end command was read
    wire  [15:0] woff = lineoff + {8'd0, col};

    assign active = (ls != L_IDLE);
    assign busy   = active || pend;

    always_ff @(posedge clk) begin
        b_we <= 1'b0;
        st_begin <= 1'b0; st_end <= 1'b0;
        if (reset) begin
            ls <= L_IDLE; pend <= 1'b0; fetch_on <= 1'b0; f_rp <= '0;
        end else begin
            if (start) pend <= 1'b1;
            case (ls)
                L_IDLE: if (pend && !hold && inflight == 3'd0 && !req) begin
                    pend <= 1'b0;
                    col0 <= regs[1][23:16]; col <= regs[1][23:16];
                    lineoff <= {1'b0, regs[1][7:0], 7'd0};
                    tmap <= regs[2][15:13];
                    hi <= !regs[2][0];
                    f_rp <= '0; st_begin <= 1'b1; fetch_on <= 1'b1;
                    ls <= L_WAIT;
                end
                L_WAIT: ls <= L_CMD;                               // the prefetch has restarted (st_begin)
                L_CMD: if (have) begin
                    f_rp <= f_rp + 4'd1;
                    n <= w[15:8];                                  // the count: the word's even (low) byte
                    case (w[7:0])                                  // the command: its odd (high) byte
                        8'h00: begin
                            if (w[15:8] == 8'd0) begin st_end <= 1'b1; fetch_on <= 1'b0; ls <= L_FLUSH; end
                            else ls <= L_COPY;
                        end
                        8'h02: ls <= L_FILLV;
                        8'h03: begin col <= col0; lineoff <= lineoff + 16'd128; end
                        default: ;
                    endcase
                end
                L_COPY: if (have) begin
                    f_rp <= f_rp + 4'd1;
                    if (tmap[2] == 1'b0 && woff < 16'd4096) begin
                        b_we <= 1'b1; b_layer <= tmap[1:0]; b_idx <= woff[11:0]; b_hi <= hi; b_data <= {w[7:0], w[15:8]};
                    end
                    col <= (col + 8'd1) & 8'h7f;
                    n <= n - 8'd1;
                    if (n == 8'd1) ls <= L_CMD;
                end
                L_FILLV: if (have) begin
                    f_rp <= f_rp + 4'd1;
                    fillv <= {w[7:0], w[15:8]};
                    ls <= (n == 8'd0) ? L_CMD : L_FILL;
                end
                L_FILL: begin
                    if (tmap[2] == 1'b0 && woff < 16'd4096) begin
                        b_we <= 1'b1; b_layer <= tmap[1:0]; b_idx <= woff[11:0]; b_hi <= hi; b_data <= fillv;
                    end
                    col <= (col + 8'd1) & 8'h7f;
                    n <= n - 8'd1;
                    if (n == 8'd1) ls <= L_CMD;
                end
                L_FLUSH: if (inflight == 3'd0 && !req) ls <= L_IDLE;
                default: ls <= L_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
