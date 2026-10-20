// 93C46 serial EEPROM, 16-bit organisation (64 words), as MAME 0.289 emulates it (src/devices/machine/eepromser.cpp, eeprom.cpp:
// eeprom_serial_93cxx_device, streaming disabled), driven the way rabbit_state::eeprom_write drives it: each CPU write of the top byte
// sets DI, then CS, then CLK, the events taken in that order.
//
//   states: in reset (CS low) -> wait for a start bit -> 2-bit opcode + 6-bit address -> reading / waiting for 16 data bits /
//           waiting for completion; CS falling returns to reset from anywhere
//   READ    DO 0 (the dummy bit), then at each CLK rising edge the next bit, MSB first; after 16 bits the register shifts in (no
//           sequential read)
//   WRITE   16 data bits, then the word is written (if write-enabled)          ERASE  the word becomes FFFF
//   00 11.. EWEN (unlock)  00 00.. EWDS (lock)  00 10.. ERAL  00 01.. WRAL (16 data bits)
//   A write, an erase, ERAL / WRAL keep the chip busy for 1.75 / 1 / 8 / 8 ms (MAME's operation times): DO reads 0 in the start-bit
//   state until it is ready, and a start bit is not taken meanwhile. A CLK edge in the same write as the CS rising edge is ignored.
//   The chip powers up write-disabled. DO is 1 (the pull-up) except while reading data or busy.
// The contents at power-up come from the image (i_ld_*: big-endian words, MAME's "eeprom" region); the saved file (the MRA's <nvram>)
// is MAME's nvram/<set>/eeprom: little-endian words (i_nv_* writes it in, o_nv_rdata reads it back, o_written marks a write of the game).
// Replaces the Metro core's metro_eeprom.sv (which this file's ports follow).
`default_nettype none
module rabbit_eeprom #(
    parameter int CLK_HZ = 96000000
) (
    input  logic        clk,
    input  logic        i_wr,             // one clock: the CPU wrote the lines
    input  logic        i_di,
    input  logic        i_cs,
    input  logic        i_clk,
    output logic        o_do,
    input  logic        i_ld_wr,
    input  logic [6:0]  i_ld_addr,
    input  logic [7:0]  i_ld_data,
    input  logic        i_nv_wr,
    input  logic [6:0]  i_nv_addr,
    input  logic [7:0]  i_nv_data,
    input  logic [6:0]  i_nv_raddr,
    output logic [7:0]  o_nv_rdata,
    output logic        o_written
);
    localparam int T_WRITE = CLK_HZ / 1000000 * 1750;
    localparam int T_ERASE = CLK_HZ / 1000000 * 1000;
    localparam int T_ALL   = CLK_HZ / 1000000 * 8000;

    logic [15:0] mem [0:63];
    initial for (int i = 0; i < 64; i++) mem[i] = 16'hFFFF;

    typedef enum logic [2:0] { S_RESET, S_START, S_CMD, S_READ, S_WDATA, S_DONE } st_e;
    st_e         st = S_RESET;
    logic        cs_q = 1'b0, clk_q = 1'b0;
    logic  [3:0] nbits;
    logic  [7:0] cmd;                     // opcode and address as they come
    logic [31:0] sh;                      // MAME's 32-bit shift register
    logic  [4:0] rbits;                   // bits clocked out of a read
    logic  [5:0] addr;
    logic  [1:0] wkind;                   // 0 WRITE, 1 WRAL
    logic        locked = 1'b1;
    logic [19:0] busy = '0;
    wire         ready = (busy == 20'd0);

    // DO (eeprom_serial_93cxx_device::do_read): the ready line while waiting for a start bit, the data while reading, else the pull-up
    assign o_do = (st == S_START) ? ready : (st == S_READ) ? sh[31] : 1'b1;

    always_ff @(posedge clk) o_nv_rdata <= i_nv_raddr[0] ? mem[i_nv_raddr[6:1]][15:8] : mem[i_nv_raddr[6:1]][7:0];

    always_ff @(posedge clk) begin : seq
        st_e         s;
        logic        cs_rise;
        logic  [7:0] c;
        o_written <= 1'b0;
        if (busy != 20'd0) busy <= busy - 20'd1;
        if (i_ld_wr) begin
            if (!i_ld_addr[0]) mem[i_ld_addr[6:1]][15:8] <= i_ld_data;
            else               mem[i_ld_addr[6:1]][7:0]  <= i_ld_data;
        end
        if (i_nv_wr) begin
            if (i_nv_addr[0]) mem[i_nv_addr[6:1]][15:8] <= i_nv_data;
            else              mem[i_nv_addr[6:1]][7:0]  <= i_nv_data;
        end
        if (i_wr) begin
            s = st;
            // CS (cs_write): a falling edge resets from any state, a rising edge starts waiting for a start bit
            cs_rise = 1'b0;
            if (cs_q && !i_cs) s = S_RESET;
            else if (!cs_q && i_cs) begin cs_rise = 1'b1; if (s == S_RESET) s = S_START; end
            cs_q <= i_cs;
            // CLK (clk_write): a rising edge
            clk_q <= i_clk;
            if (!clk_q && i_clk && i_cs) begin
                case (s)
                    S_START: if (i_di && ready && !cs_rise) begin s = S_CMD; nbits <= 4'd0; end
                    S_CMD: begin
                        c = {cmd[6:0], i_di};
                        cmd <= c;
                        nbits <= nbits + 4'd1;
                        if (nbits == 4'd7) begin
                            addr <= c[5:0];
                            case (c[7:6])
                                2'b10: begin sh <= 32'd0; rbits <= 5'd0; s = S_READ; end                       // READ: the dummy 0
                                2'b01: begin sh <= 32'd0; nbits <= 4'd0; wkind <= 2'd0; s = S_WDATA; end       // WRITE
                                2'b11: begin                                                                   // ERASE
                                    if (locked) s = S_RESET;
                                    else begin mem[c[5:0]] <= 16'hFFFF; o_written <= 1'b1; busy <= 20'(T_ERASE); s = S_DONE; end
                                end
                                default: case (c[5:4])
                                    2'b00: begin locked <= 1'b1; s = S_RESET; end                              // EWDS
                                    2'b11: begin locked <= 1'b0; s = S_RESET; end                              // EWEN
                                    2'b10: begin                                                               // ERAL
                                        if (locked) s = S_RESET;
                                        else begin for (int i = 0; i < 64; i++) mem[i] <= 16'hFFFF; o_written <= 1'b1; busy <= 20'(T_ALL); s = S_DONE; end
                                    end
                                    default: begin sh <= 32'd0; nbits <= 4'd0; wkind <= 2'd1; s = S_WDATA; end // WRAL
                                endcase
                            endcase
                        end
                    end
                    S_READ: begin
                        // the first edge loads the word, the next ones shift (with ones) -- no sequential read
                        rbits <= (rbits == 5'd31) ? rbits : rbits + 5'd1;
                        if (rbits == 5'd0) sh <= {mem[addr], 16'h0000};
                        else               sh <= {sh[30:0], 1'b1};
                    end
                    S_WDATA: begin
                        sh <= {sh[30:0], i_di};
                        nbits <= nbits + 4'd1;
                        if (nbits == 4'd15) begin
                            if (locked) s = S_RESET;
                            else begin
                                if (wkind == 2'd1) begin for (int i = 0; i < 64; i++) mem[i] <= mem[i] & {sh[14:0], i_di}; busy <= 20'(T_ALL); end
                                else begin mem[addr] <= {sh[14:0], i_di}; busy <= 20'(T_WRITE); end
                                o_written <= 1'b1;
                                s = S_DONE;
                            end
                        end
                    end
                    default: ;
                endcase
            end
            st <= s;
        end
    end
endmodule
`default_nettype wire
