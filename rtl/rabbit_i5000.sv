//------------------------------------------------------------------------------
// The Imagetek I5000's sound side as MAME 0.289 emulates it (src/devices/sound/i5000.cpp, hap): 16 ADPCM channels (OKI ADPCM, 4-bit or
// 3-bit codes) read from a 4 MB sample ROM, with an 8-bit volume per side. Two modes (OSD Sound, the input enhanced):
//   MAME (enhanced = 0): MAME's device: a fixed 40 MHz / 1024 = 39062.5 Hz, the register 0x46 ignored, the 16-bit mix out.
//   Enhanced (enhanced = 1): the sample rate the game sets in register 0x46 (47,962 Hz, the board's pitch: MAME plays every sound 23 %
//   slow), see the sample clock below, and the mix through rabbit_sndflt (rumble below 150 Hz and hiss above 11 kHz cut).
//
// Registers (16-bit, at 400900 + 2 * reg; only whole-word writes count):
//   ch * 4 + 0 / 1   the sample's address (word address in the ROM: low / high word), used at key on
//   ch * 4 + 2       frequency: the channel decodes a code every (0x1ff - d[7:0]) << (~d[9:8] & 3) / freq_min samples
//   ch * 4 + 3       volume: right d[7:0], left d[15:8], each through MAME's table (2047 / 1.032^v, 255 = silent)
//   0x42             key on (write: the set channels that are not playing start), playing channels (read)
//   0x43             key off
//   0x46             the sample rate: 40 MHz / (2 * (d[9:0] + 1)) (inferred: the game's only value, 0x85a0, and a board recording)
// A sample starts with 7f7f and a format word (0104 / 0304: 3-bit codes, else 4-bit), its data from the fourth word on (little-endian
// words, codes from the low bits up), and ends with a word 7f7f (and one more word).
//
// MAME starts a channel at the instant of the key-on write; here the write marks it and the state machine starts it (three ROM words)
// in the next microseconds; meanwhile it reads as playing. The ROM words come from the SDRAM, one at a time.
//------------------------------------------------------------------------------
`default_nettype none

module rabbit_i5000 #(
    parameter logic [23:0] SND_W = 24'hC00000       // the sample ROM's first word in the SDRAM
) (
    input  logic        clk,                // 96 MHz
    input  logic        reset,
    input  logic        enhanced,           // 1: the game's sample rate and the output filter; 0: MAME's device

    input  logic        wr,
    input  logic  [6:0] rreg,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,              // the register rreg (combinational)

    // the SDRAM client (one word)
    output logic        req,
    output logic [23:0] addr,
    output logic  [4:0] len,
    input  logic        ack,
    input  logic        valid,
    input  logic [15:0] data,

    output logic signed [15:0] out_l,
    output logic signed [15:0] out_r
);
    `include "rabbit_i5000_tables.svh"

    localparam logic [20:0] ROM_MASK = 21'h1fffff;

    // ------------------------------------------------------------------ the channels
    logic        playing [16];
    logic        konp    [16];              // a key on not yet carried out
    logic [15:0] a_lo [16], a_hi [16];      // the address registers
    logic [31:0] kon_a   [16];              // the address at the key on
    logic signed [11:0] sig [16];           // ADPCM signal
    logic  [5:0] stp     [16];              // ADPCM step
    logic [20:0] adr     [16];
    logic signed [13:0] ftm [16];           // freq_timer
    logic [11:0] fbase   [16];
    logic  [8:0] fmin    [16];
    logic [15:0] smp     [16];
    logic  [3:0] spos    [16];
    logic        bits3   [16];              // 3-bit codes (shift_amount 3, mask 0xe)
    logic [11:0] volr [16], voll [16];
    logic signed [15:0] outr [16], outl [16];

    always_comb begin
        rdata = 16'h0000;
        if (rreg == 7'h42) for (int c = 0; c < 16; c++) rdata[c] = playing[c] | konp[c];
    end

    // ------------------------------------------------------------------ the sample clock: a sample every 2 * (N + 1) clocks of the chip's
    // 40 MHz, N = register 0x46 bits 9:0 (counted here in 96 MHz clocks * 5 / 12). MAME runs the chip at 40 MHz / 1024 (N = 511) and
    // ignores the register; the game writes 0x85a0 at boot (N = 416: 47,962 Hz), which is the rate a recording of a real board plays
    // its samples at (to 0.01 %). Until the register is written the rate is MAME's; in the MAME mode it always is.
    logic [15:0] tacc;
    logic [15:0] tlim;
    logic  [9:0] n46;                       // register 0x46 bits 9:0 (511 until written: MAME's rate)
    logic        tick_pend;

    // ------------------------------------------------------------------ the state machine
    typedef enum logic [4:0] { F_IDLE, F_CH, F_RD, F_RDW, F_GOT, F_ADPCM, F_ADP2, F_MUL, F_ACC, F_NEXT, F_OUT,
                               F_KON, F_KGOT, F_TX1, F_TX2, F_TX3, F_TX4, F_TX5, F_TX6, F_TX7, F_TX8, F_TX9, F_TX10 } fst_t;
    fst_t        fs, ret;
    logic  [3:0] ch;
    logic signed [20:0] mixr, mixl;
    logic [20:0] rd_a;
    logic [15:0] rd_q;
    logic        taken;
    // the channel being worked on
    logic signed [13:0] c_ft;               // freq_timer - freq_min
    logic  [4:0] c_sp;                      // shift_pos after the step (before the wrap)
    logic  [4:0] w_sp;                      // c_sp, kept for the ROM word's arrival
    logic [31:0] cat;                       // the code across the word boundary
    always_comb begin
        c_ft = ftm[ch] - 14'(fmin[ch]);
        c_sp = {1'b0, spos[ch]} + (bits3[ch] ? 5'd3 : 5'd4);
        cat  = 32'(smp[ch] >> spos[ch]) | (32'(rd_q) << ((bits3[ch] ? 5'd3 : 5'd4) - {1'b0, w_sp[3:0]}));
    end
    logic  [3:0] w_nib;
    logic  [1:0] k_n;                       // key on: which word is being read (0 start, 1 format, 2 first data)
    logic [20:0] k_a;
    logic        k_ok;

    // the lowest channel with a key on waiting
    logic        kany;
    logic  [3:0] kch;
    always_comb begin
        kany = 1'b0; kch = 4'd0;
        for (int c = 15; c >= 0; c--) if (konp[c]) begin kany = 1'b1; kch = 4'(c); end
    end

    // ADPCM (oki_adpcm_state::clock), over four clocks: the step's size (F_ADP1), the new signal and step (F_ADP2), the volumes
    // (F_MUL), the outputs and the mix (F_ACC)
    logic [10:0] r_sv;
    logic signed [13:0] r_sig;
    logic signed [25:0] r_pr, r_pl;
    logic [12:0] dmag;
    logic signed [13:0] dsig, nsig;
    logic signed [7:0] nstp;
    logic [25:0] apr, apl;
    logic signed [15:0] o_r, o_l;
    always_comb begin
        dmag = {2'b00, (w_nib[2] ? r_sv : 11'd0)} + {3'b000, (w_nib[1] ? r_sv[10:1] : 10'd0)} + {4'b0000, (w_nib[0] ? r_sv[10:2] : 9'd0)} + {5'b00000, r_sv[10:3]};
        dsig = $signed({1'b0, dmag});
        if (w_nib[3]) dsig = -dsig;
        nsig = $signed({{2{sig[ch][11]}}, sig[ch]}) + dsig;
        if (nsig > 14'sd2047) nsig = 14'sd2047;
        else if (nsig < -14'sd2048) nsig = -14'sd2048;
        case (w_nib[2:0])
            3'd4: nstp = $signed({2'b00, stp[ch]}) + 8'sd2;
            3'd5: nstp = $signed({2'b00, stp[ch]}) + 8'sd4;
            3'd6: nstp = $signed({2'b00, stp[ch]}) + 8'sd6;
            3'd7: nstp = $signed({2'b00, stp[ch]}) + 8'sd8;
            default: nstp = $signed({2'b00, stp[ch]}) - 8'sd1;
        endcase
        if (nstp > 8'sd48) nstp = 8'sd48;
        else if (nstp < 8'sd0) nstp = 8'sd0;
        // output = signal * volume / 128, C's division (towards zero)
        apr = r_pr[25] ? 26'(-r_pr) : 26'(r_pr);
        apl = r_pl[25] ? 26'(-r_pl) : 26'(r_pl);
        o_r = r_pr[25] ? -$signed(apr[22:7]) : $signed(apr[22:7]);
        o_l = r_pl[25] ? -$signed(apl[22:7]) : $signed(apl[22:7]);
    end

    // the output: MAME's 16-bit mix, or the same mix through the Enhanced mode's filter
    logic signed [15:0] raw_l, raw_r, flt_l, flt_r;
    logic signed [16:0] mx_l, mx_r;         // the mix at the output's scale before the 16-bit limit (it never reaches it: 16 x 32,736 / 16)
    logic        mx_stb;
    rabbit_sndflt u_flt (.clk(clk), .reset(reset), .stb(mx_stb), .in_l(mx_l), .in_r(mx_r), .out_l(flt_l), .out_r(flt_r));
    always_ff @(posedge clk) begin
        out_l <= enhanced ? flt_l : raw_l;
        out_r <= enhanced ? flt_r : raw_r;
    end

    // ------------------------------------------------------------------ the Enhanced mode's per-note tail expander (music channels
    // 0-11; tools/txref.py is this bit for bit). On each code: the note's slow mean dc, x = s - dc, a peak follower env on |x| (instant
    // up, down 1/512 a code), the note's peak so far; x is scaled by (env / peak)^4, worked in log2 (1/64 octave), floored at -60 dB.
    // The board's notes die away much faster than MAME's decoding lets them, and the gaps between notes are where its noise sits.
    localparam logic [5:0]  TX_LOG2 [64] = '{6'd0, 6'd1, 6'd3, 6'd4, 6'd6, 6'd7, 6'd8, 6'd10, 6'd11, 6'd12, 6'd13, 6'd15, 6'd16, 6'd17, 6'd18, 6'd19, 6'd21, 6'd22, 6'd23, 6'd24, 6'd25, 6'd26, 6'd27, 6'd28, 6'd29, 6'd30, 6'd31, 6'd32, 6'd34, 6'd35, 6'd35, 6'd36, 6'd37, 6'd38, 6'd39, 6'd40, 6'd41, 6'd42, 6'd43, 6'd44, 6'd45, 6'd46, 6'd47, 6'd47, 6'd48, 6'd49, 6'd50, 6'd51, 6'd52, 6'd52, 6'd53, 6'd54, 6'd55, 6'd56, 6'd56, 6'd57, 6'd58, 6'd59, 6'd60, 6'd60, 6'd61, 6'd62, 6'd63, 6'd63};
    localparam logic [16:0] TX_EXP2 [64] = '{17'd65536, 17'd64830, 17'd64132, 17'd63441, 17'd62757, 17'd62081, 17'd61413, 17'd60751, 17'd60097, 17'd59449, 17'd58809, 17'd58176, 17'd57549, 17'd56929, 17'd56316, 17'd55709, 17'd55109, 17'd54515, 17'd53928, 17'd53347, 17'd52773, 17'd52204, 17'd51642, 17'd51085, 17'd50535, 17'd49991, 17'd49452, 17'd48920, 17'd48393, 17'd47871, 17'd47356, 17'd46846, 17'd46341, 17'd45842, 17'd45348, 17'd44859, 17'd44376, 17'd43898, 17'd43425, 17'd42958, 17'd42495, 17'd42037, 17'd41584, 17'd41136, 17'd40693, 17'd40255, 17'd39821, 17'd39392, 17'd38968, 17'd38548, 17'd38133, 17'd37722, 17'd37316, 17'd36914, 17'd36516, 17'd36123, 17'd35734, 17'd35349, 17'd34968, 17'd34591, 17'd34219, 17'd33850, 17'd33486, 17'd33125};
    logic signed [20:0] tx_dc   [12];       // 8 fraction bits
    logic        [20:0] tx_env  [12];
    logic        [20:0] tx_peak [12];
    logic signed [21:0] tx_x;
    logic        [20:0] tx_ax, tx_dec, tx_envr, tx_peakr;
    logic        [10:0] tx_lp, tx_le;
    logic        [12:0] tx_e;
    logic        [16:0] tx_g;
    logic signed [38:0] tx_p;
    function automatic logic [10:0] log2q(input logic [20:0] v);    // log2 of v (v >= 1) in 1/64 octave
        logic [4:0] pp;
        logic [20:0] mv;
        pp = 5'd0;
        for (int i = 0; i < 21; i++) if (v[i]) pp = 5'(i);
        mv = (pp >= 5'd6) ? (v >> (pp - 5'd6)) : (v << (5'd6 - pp));
        return (11'(pp) << 6) + 11'(TX_LOG2[mv[5:0]]);
    endfunction
    // for the sound bench (sim/tb_snd_top.sv, tools/txref.py): each key on and each expanded code
    logic        dbg_kon_stb, dbg_tx_stb;
    logic  [3:0] dbg_ch;
    logic signed [13:0] dbg_tx_in, dbg_tx_out;
    logic        [12:0] tx_d4;
    always_comb tx_d4 = {tx_lp - tx_le, 2'b00};

    function automatic logic signed [15:0] sat16(input logic signed [20:0] v);
        logic signed [20:0] s;
        s = v >>> 4;                        // MAME's full scale is 32768 * 16
        if (s > 21'sd32767) return 16'sd32767;
        if (s < -21'sd32768) return -16'sd32768;
        return s[15:0];
    endfunction

    always_ff @(posedge clk) begin
        if (ack) req <= 1'b0;
        if (reset) begin
            fs <= F_IDLE; req <= 1'b0; tacc <= '0; tlim <= 16'd12288; n46 <= 10'd511; tick_pend <= 1'b0; raw_l <= '0; raw_r <= '0;
            mx_stb <= 1'b0;
            for (int c = 0; c < 16; c++) begin
                playing[c] <= 1'b0; konp[c] <= 1'b0; a_lo[c] <= '0; a_hi[c] <= '0; fbase[c] <= 12'h1ff << 3;
                volr[c] <= 12'd2047; voll[c] <= 12'd2047; outr[c] <= '0; outl[c] <= '0;
                fmin[c] <= 9'h100; bits3[c] <= 1'b0; sig[c] <= '0; stp[c] <= '0; ftm[c] <= '0; spos[c] <= '0; smp[c] <= '0; adr[c] <= '0;
                if (c < 12) begin tx_dc[c] <= '0; tx_env[c] <= '0; tx_peak[c] <= 21'd256; end
            end
        end else begin
            // the sample clock
            tlim   <= enhanced ? ({6'd0, n46} + 16'd1) * 16'd24 : 16'd12288;        // 12 * 2 * (N + 1)
            dbg_kon_stb <= 1'b0; dbg_tx_stb <= 1'b0;
            mx_stb <= 1'b0;
            if (tacc + 16'd5 >= tlim) begin tacc <= tacc + 16'd5 - tlim; tick_pend <= 1'b1; end
            else tacc <= tacc + 16'd5;

            case (fs)
                F_IDLE: begin
                    if (tick_pend) begin tick_pend <= 1'b0; ch <= 4'd0; mixr <= '0; mixl <= '0; fs <= F_CH; end
                    else if (kany) begin ch <= kch; k_n <= 2'd0; k_a <= kon_a[kch][20:0] & ROM_MASK; fs <= F_KON; end
                end

                // ---------------------------------------------------- one sample of channel ch (sound_stream_update)
                F_CH: begin
                    if (!playing[ch]) fs <= F_NEXT;
                    else begin
                        if (c_ft > 14'sd0) begin
                            ftm[ch] <= c_ft;
                            mixr <= mixr + {{5{outr[ch][15]}}, outr[ch]}; mixl <= mixl + {{5{outl[ch][15]}}, outl[ch]};
                            fs <= F_NEXT;
                        end else begin
                            ftm[ch] <= c_ft + 14'(fbase[ch]);
                            w_sp <= c_sp;
                            if (c_sp[4]) begin
                                rd_a <= adr[ch]; ret <= F_GOT; fs <= F_RD;
                            end else begin
                                w_nib <= 4'((smp[ch] >> spos[ch])) & (bits3[ch] ? 4'he : 4'hf);
                                spos[ch] <= c_sp[3:0];
                                fs <= F_ADPCM;
                            end
                        end
                    end
                end
                F_GOT: begin
                    // read_sample: the next word, or the end
                    if (rd_q == 16'h7f7f) begin
                        adr[ch] <= (adr[ch] + 21'd2) & ROM_MASK;        // the end word and the command word after it
                        smp[ch] <= rd_q;
                        playing[ch] <= 1'b0;
                        fs <= F_NEXT;
                    end else begin
                        adr[ch] <= (adr[ch] + 21'd1) & ROM_MASK;
                        w_nib <= cat[3:0] & (bits3[ch] ? 4'he : 4'hf);
                        smp[ch] <= rd_q;
                        spos[ch] <= w_sp[3:0];
                        fs <= F_ADPCM;
                    end
                end
                F_ADPCM: begin
                    r_sv <= i5k_step(stp[ch]);
                    fs <= F_ADP2;
                end
                F_ADP2: begin
                    sig[ch] <= nsig[11:0]; r_sig <= nsig;
                    stp[ch] <= nstp[5:0];
                    fs <= (enhanced && ch < 4'd12) ? F_TX1 : F_MUL;
                end
                // the tail expander (Enhanced, music channels): ten clocks, one step of tools/txref.py's Tx.clock each
                F_TX1: begin        // the mean
                    tx_dc[ch] <= tx_dc[ch] + (((21'(r_sig) <<< 8) - tx_dc[ch]) >>> 7);
                    fs <= F_TX2;
                end
                F_TX2: begin        // x
                    tx_x <= 22'((21'(r_sig) <<< 8)) - 22'(tx_dc[ch]);
                    fs <= F_TX3;
                end
                F_TX3: begin        // |x|, the follower's decay
                    tx_ax  <= tx_x[21] ? 21'(-tx_x) : 21'(tx_x);
                    tx_dec <= tx_env[ch] - (tx_env[ch] >> 9);
                    fs <= F_TX4;
                end
                F_TX4: begin        // the follower
                    tx_envr <= (tx_ax > tx_env[ch]) ? tx_ax : tx_dec;
                    tx_env[ch] <= (tx_ax > tx_env[ch]) ? tx_ax : tx_dec;
                    fs <= F_TX5;
                end
                F_TX5: begin        // the note's peak
                    tx_peakr <= (tx_envr > tx_peak[ch]) ? tx_envr : tx_peak[ch];
                    tx_peak[ch] <= (tx_envr > tx_peak[ch]) ? tx_envr : tx_peak[ch];
                    fs <= F_TX6;
                end
                F_TX6: begin        // both in log2
                    tx_lp <= log2q(tx_peakr);
                    tx_le <= log2q((tx_envr == 21'd0) ? 21'd1 : tx_envr);
                    fs <= F_TX7;
                end
                F_TX7: begin        // the gain's log2, floored at -10 octaves
                    tx_e <= (tx_d4 > 13'd640) ? 13'd640 : tx_d4;
                    fs <= F_TX8;
                end
                F_TX8: begin        // the gain
                    tx_g <= TX_EXP2[tx_e[5:0]] >> tx_e[12:6];
                    fs <= F_TX9;
                end
                F_TX9: begin
                    tx_p <= 39'(tx_x) * $signed({22'd0, tx_g});
                    fs <= F_TX10;
                end
                F_TX10: begin
                    r_sig <= 14'((39'(tx_dc[ch]) + (tx_p >>> 16)) >>> 8);
                    dbg_tx_stb <= 1'b1; dbg_ch <= ch; dbg_tx_in <= r_sig; dbg_tx_out <= 14'((39'(tx_dc[ch]) + (tx_p >>> 16)) >>> 8);
                    fs <= F_MUL;
                end
                F_MUL: begin
                    r_pr <= $signed({{12{r_sig[13]}}, r_sig}) * $signed({14'd0, volr[ch]});
                    r_pl <= $signed({{12{r_sig[13]}}, r_sig}) * $signed({14'd0, voll[ch]});
                    fs <= F_ACC;
                end
                F_ACC: begin
                    outr[ch] <= o_r; outl[ch] <= o_l;
                    mixr <= mixr + {{5{o_r[15]}}, o_r}; mixl <= mixl + {{5{o_l[15]}}, o_l};
                    fs <= F_NEXT;
                end
                F_NEXT: begin
                    if (ch == 4'd15) fs <= F_OUT;
                    else begin ch <= ch + 4'd1; fs <= F_CH; end
                end
                F_OUT: begin
                    raw_r <= sat16(mixr); raw_l <= sat16(mixl);
                    mx_r <= 17'(mixr >>> 4); mx_l <= 17'(mixl >>> 4); mx_stb <= 1'b1;
                    fs <= F_IDLE;
                end

                // ---------------------------------------------------- a key on
                F_KON: begin rd_a <= (k_n == 2'd2) ? k_a : ((k_n == 2'd0) ? k_a : (k_a + 21'd1) & ROM_MASK); ret <= F_KGOT; fs <= F_RD; end
                F_KGOT: begin
                    case (k_n)
                        2'd0: begin
                            k_ok <= (rd_q == 16'h7f7f);
                            if (rd_q != 16'h7f7f) begin konp[ch] <= 1'b0; fs <= F_IDLE; end      // not a sample: nothing starts
                            else begin k_n <= 2'd1; fs <= F_KON; end
                        end
                        2'd1: begin
                            bits3[ch] <= (rd_q == 16'h0104) || (rd_q == 16'h0304);
                            fmin[ch]  <= ((rd_q == 16'h0104) || (rd_q == 16'h0304)) ? 9'h140 : 9'h100;
                            k_a <= (k_a + 21'd4) & ROM_MASK;
                            k_n <= 2'd2; fs <= F_KON;
                        end
                        default: begin
                            ftm[ch] <= '0; spos[ch] <= '0; sig[ch] <= '0; stp[ch] <= '0;
                            if (ch < 4'd12) begin tx_dc[ch] <= '0; tx_env[ch] <= '0; tx_peak[ch] <= 21'd256; end
                            dbg_kon_stb <= 1'b1; dbg_ch <= ch;
                            smp[ch] <= rd_q;
                            if (rd_q == 16'h7f7f) adr[ch] <= (k_a + 21'd2) & ROM_MASK;
                            else                  adr[ch] <= (k_a + 21'd1) & ROM_MASK;
                            // a key off that came meanwhile wins
                            if (konp[ch]) playing[ch] <= (rd_q != 16'h7f7f);
                            konp[ch] <= 1'b0;
                            fs <= F_IDLE;
                        end
                    endcase
                end

                // ---------------------------------------------------- one ROM word (little-endian in the ROM: the SDRAM word's bytes swapped)
                F_RD: begin
                    req <= 1'b1; addr <= SND_W + 24'(rd_a); len <= 5'd1; taken <= 1'b0; fs <= F_RDW;
                end
                F_RDW: begin
                    if (ack) taken <= 1'b1;
                    if (valid && taken) begin rd_q <= {data[7:0], data[15:8]}; fs <= ret; end
                end
                default: fs <= F_IDLE;
            endcase

            // ---------------------------------------------------- the CPU's writes (write_reg16)
            if (wr) begin
                if (rreg < 7'h40) begin
                    case (rreg[1:0])
                        2'd0: a_lo[rreg[5:2]] <= wdata;
                        2'd1: a_hi[rreg[5:2]] <= wdata;
                        2'd2: fbase[rreg[5:2]] <= 12'(9'h1ff - {1'b0, wdata[7:0]}) << (~wdata[9:8]);
                        default: begin volr[rreg[5:2]] <= i5k_vol(wdata[7:0]); voll[rreg[5:2]] <= i5k_vol(wdata[15:8]); end
                    endcase
                end else if (rreg == 7'h42) begin
                    for (int c = 0; c < 16; c++) if (wdata[c] && !playing[c] && !konp[c]) begin
                        konp[c] <= 1'b1; kon_a[c] <= {a_hi[c], a_lo[c]};
                    end
                end else if (rreg == 7'h43) begin
                    for (int c = 0; c < 16; c++) if (wdata[c]) begin playing[c] <= 1'b0; konp[c] <= 1'b0; end
                end else if (rreg == 7'h46) begin
                    n46 <= wdata[9:0];
                    if (enhanced) tacc <= '0;
                end
            end
        end
    end
endmodule
`default_nettype wire
