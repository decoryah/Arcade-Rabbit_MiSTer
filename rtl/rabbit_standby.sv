// A blank raster of the core's own timing (15 clocks a dot, 424 or 407 dots a line as rabbit_video, 262 lines, 320 x 224 picture) for the time
// the machine is held in reset (the ROM image streaming in, the OSD's Reset): the framework draws its "Loading" pop-up on the OSD, which needs a
// video signal with sync to sit on. After the Metro core's metro_standby.sv (decoryah/Arcade-Metro_MiSTer, GPL-3.0-or-later).
`default_nettype none
module rabbit_standby (
    input  wire clk,
    input  wire board_rate,
    output reg  o_ce,
    output reg  o_hblank,
    output reg  o_vblank,
    output reg  o_hs,
    output reg  o_vs
);
    reg [3:0] dv = 4'd0;
    reg [8:0] hc = 9'd0, vc = 9'd0;
    initial begin o_ce = 1'b0; o_hblank = 1'b1; o_vblank = 1'b1; o_hs = 1'b0; o_vs = 1'b0; end
    always @(posedge clk) begin
        o_ce <= 1'b0;
        dv   <= (dv == 4'd14) ? 4'd0 : dv + 4'd1;
        if (dv == 4'd14) begin
            o_ce <= 1'b1;
            if (hc == (board_rate ? 9'd423 : 9'd406)) begin
                hc <= 9'd0;
                vc <= (vc == 9'd261) ? 9'd0 : vc + 9'd1;
            end else
                hc <= hc + 9'd1;
            o_hblank <= (hc >= 9'd320);
            o_hs     <= (hc >= 9'd336) && (hc < 9'd368);
            o_vblank <= (vc >= 9'd224);
            o_vs     <= (vc >= 9'd232) && (vc < 9'd235);
        end
    end
endmodule
`default_nettype wire
