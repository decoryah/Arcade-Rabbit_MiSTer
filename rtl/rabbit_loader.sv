//------------------------------------------------------------------------------
// The ROM image's way in: the HPS download (or the fast load's replay of it) arrives a byte at a time at its image offset; this module
// routes each byte to its place in the SDRAM, or to the EEPROM's initial contents.
//
// The image (mra/*.mra, tools/make_mra.py):
//   0x0000000  maincpu  2 MB   the 68020 program, as MAME's region (big-endian: the four byte-wide ROMs interleaved)
//   0x0200000  gfx1    16 MB   sprites and the blitter's data, as MAME's region (ROM_LOAD32_WORD of jfv1 / jfv0, then jfv3 / jfv2)
//   0x1200000  gfx2     6 MB   the tilemaps' tiles (jbg0, jbg1, jbg2)
//   0x1800000  i5000snd 4 MB   the sound ROM as MAME loads it (jsn0 from its byte 0x18, the last 0x18 bytes zero)
//   0x1C00000  eeprom 128 B    the 93C46's default contents (rabbit.nv, big-endian words)
//
// The SDRAM holds the image at byte address = image offset, with one exception: inside gfx1 the bit that selects the region's half (byte
// offset bit 23) moves down next to bit 2, so a sprite's 16-pixel row (4 bytes in each half: its right and its left eight pixels) is
// 8 consecutive bytes, one 4-word burst:  SDRAM byte = 0x200000 + {b[22:2], b[23], b[1:0]}  for gfx1 offset b. Byte pairs stay pairs.
//------------------------------------------------------------------------------
`default_nettype none
module rabbit_loader (
    input  logic        clk,
    input  logic        dl_wr,                 // one clock per byte
    input  logic [25:0] dl_addr,               // image offset
    input  logic  [7:0] dl_data,
    output logic        o_wr,                  // to the SDRAM's download port
    output logic [24:0] o_addr,
    output logic  [7:0] o_data,
    output logic        ee_wr,                 // the EEPROM's initial contents
    output logic  [6:0] ee_addr,
    output logic  [7:0] ee_data
);
    localparam logic [25:0] GFX1 = 26'h0200000, GFX2 = 26'h1200000, EEP = 26'h1C00000;

    wire [25:0] b = dl_addr - GFX1;
    always_ff @(posedge clk) begin
        o_wr <= 1'b0; ee_wr <= 1'b0;
        if (dl_wr) begin
            if (dl_addr >= EEP) begin
                ee_wr   <= (dl_addr < EEP + 26'd128);
                ee_addr <= dl_addr[6:0];
                ee_data <= dl_data;
            end else begin
                o_wr   <= 1'b1;
                o_data <= dl_data;
                if (dl_addr >= GFX1 && dl_addr < GFX2) o_addr <= 25'h0200000 + {1'b0, b[22:2], b[23], b[1:0]};
                else                                   o_addr <= dl_addr[24:0];
            end
        end
    end
endmodule
`default_nettype wire
