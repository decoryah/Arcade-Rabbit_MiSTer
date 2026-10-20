//============================================================================
//
//  Rabbit (Aorn / Electronic Arts, 1997: 68EC020 + Imagetek I5000) for MiSTer.
//
//  Written for MiSTer from MAME 0.289's driver (src/mame/metro/rabbit.cpp, src/devices/sound/i5000.cpp). The 68020 is TG68K.C
//  (Tobias Gubener) in its 68020 mode; the platform layer (SDRAM protocol, fast load, EEPROM save, standby raster) follows the Metro
//  core (decoryah/Arcade-Metro_MiSTer) and the Mystic Warriors core (the program cache, the TG68K bus sequencing).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S   = 1;       // signed samples
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire         direct_video;
wire  [21:0] gamma_bus;

wire  [1:0] ar = status[122:121];

`include "build_id.v"
localparam CONF_STR = {
	"Rabbit;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[34:32],Scale,Normal,V-Integer,HV-Integer,Narrower HV-Integer,HV-Integer+;",
	"O[5:3],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"O[9:8],Volume,Normal,-6 dB,-12 dB,+6 dB;",
	"O[10],Swap stereo,No,Yes;",
	"O[12],Autosave EEPROM,On,Off;",
	"T[13],Save EEPROM;",
	"-;",
	"R0,Reset;",
	"J1,Button 1,Button 2,Button 3,Button 4,Start,Coin,Service;",
	"jn,A,B,X,Y,Start,Select,L;",
	"V,v",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_sys;           // 96 MHz: the machine
wire clk_sdram;         // 96 MHz, shifted: the SDRAM chip's clock pin
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);

assign SDRAM_CLK = clk_sdram;

///////////////////////////////////////////////////

wire         ioctl_download;
wire         ioctl_wr;
wire  [15:0] ioctl_index;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire         dl_busy;
wire         ioctl_upload;
wire   [7:0] ioctl_din;
reg          nv_req = 1'b0;
localparam [7:0] NV_INDEX = 8'd4;    // the EEPROM's file: the MRA's <nvram index="4" size="128"/>

wire  [31:0] joystick_0, joystick_1;
wire  [10:0] ps2_key;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.forced_scandoubler(forced_scandoubler),
	.direct_video(direct_video),
	.gamma_bus(gamma_bus),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(dl_busy),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nv_req),
	.ioctl_upload_index(NV_INDEX),
	.ioctl_din(ioctl_din),
	.ioctl_rd(),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CONTROLS   ///////////////////////

// keyboard: 1 / 2 start, 5 / 6 coin, 9 service, F2 the test switch (MAME's defaults)
reg key_start1, key_start2, key_coin1, key_coin2, key_service, key_test;
always @(posedge clk_sys) begin
	reg old_stb;
	old_stb <= ps2_key[10];
	if (old_stb != ps2_key[10]) begin
		case (ps2_key[8:0])
			9'h016: key_start1  <= ps2_key[9];
			9'h01E: key_start2  <= ps2_key[9];
			9'h02E: key_coin1   <= ps2_key[9];
			9'h036: key_coin2   <= ps2_key[9];
			9'h046: key_service <= ps2_key[9];
			9'h006: key_test    <= ps2_key[9];      // F2
			default: ;
		endcase
	end
end

// joystick bits: 0 right, 1 left, 2 down, 3 up, 4-7 buttons 1-4, 8 start, 9 coin, 10 service (the J1 line above)
wire [7:0] p1 = {joystick_0[7:4], joystick_0[0], joystick_0[1], joystick_0[2], joystick_0[3]};   // b4 b3 b2 b1 right left down up
wire [7:0] p2 = {joystick_1[7:4], joystick_1[0], joystick_1[1], joystick_1[2], joystick_1[3]};
wire start1 = joystick_0[8] | key_start1, coin1 = joystick_0[9] | key_coin1;
wire start2 = joystick_1[8] | key_start2, coin2 = joystick_1[9] | key_coin2;
wire service = joystick_0[10] | joystick_1[10] | key_service;

// MAME's INPUTS (0x200000), active low: bit 0 the EEPROM (the core), 1 unknown, 2 / 3 start 1 / 2, 4 service 1, 5 the test switch,
// 6 / 7 coin 1 / 2, 15:8 player 1 (up, down, left, right, buttons 1-4), 23:16 player 2, 31:24 unused
wire [31:0] in_port = ~{8'h00, p2, p1, coin2, coin1, key_test, service, start2, start1, 2'b00};

///////////////////////   MEMORY   ///////////////////////

// the ROM image: MRA index 0
wire        rom_dl = ioctl_download && (ioctl_index[7:0] == 8'd0);

// Fast load (the MRA's address= attribute): Main_MiSTer copies the image into the DDR3 (byte 0x32000000) and ends a download that
// carries only a start address, the image's length; rabbit_fastload reads it back and plays it into the loader. An older Main_MiSTer
// streams the bytes as before (as in the Metro core).
reg         rom_dl_d;
always @(posedge clk_sys) rom_dl_d <= rom_dl;
wire        dl_start = rom_dl && !rom_dl_d;
wire        dl_done  = !rom_dl && rom_dl_d;
reg         fast_dl = 1'b0;
reg  [26:0] fast_len;
wire        fl_go    = fast_dl && dl_done;
wire        fl_done, fl_busy_unused;
always @(posedge clk_sys) begin
	if (dl_start) begin fast_dl <= (ioctl_addr != 27'd0); fast_len <= ioctl_addr; end
	else if (fl_done || !pll_locked) fast_dl <= 1'b0;
end
wire        fl_wr;
wire [25:0] fl_addr;
wire  [7:0] fl_data;
wire        fl_ddr_rd;
wire [24:0] fl_ddr_addr;
wire  [7:0] fl_ddr_burst;

rabbit_fastload u_fastload
(
	.clk(clk_sys), .rst(~pll_locked), .go(fl_go), .len(fast_len), .busy(fl_busy_unused), .done(fl_done),
	.ddr_rd(fl_ddr_rd), .ddr_addr(fl_ddr_addr), .ddr_burst(fl_ddr_burst), .ddr_busy(DDRAM_BUSY), .ddr_dout(DDRAM_DOUT), .ddr_dready(DDRAM_DOUT_READY),
	.o_wr(fl_wr), .o_addr(fl_addr), .o_data(fl_data), .hold(dl_busy)
);
assign DDRAM_CLK      = clk_sys;
assign DDRAM_ADDR     = {4'd3, fl_ddr_addr};
assign DDRAM_BURSTCNT = fl_ddr_burst;
assign DDRAM_RD       = fl_ddr_rd;
assign DDRAM_WE       = 1'b0;
assign DDRAM_DIN      = 64'd0;
assign DDRAM_BE       = 8'hFF;

wire        ld_wr;
wire [24:0] ld_addr;
wire  [7:0] ld_data;
wire        ee_ld_wr;
wire  [6:0] ee_ld_addr;
wire  [7:0] ee_ld_data;

rabbit_loader u_loader
(
	.clk(clk_sys),
	.dl_wr(fl_wr || (ioctl_wr && rom_dl)), .dl_addr(fl_wr ? fl_addr : ioctl_addr[25:0]), .dl_data(fl_wr ? fl_data : ioctl_dout),
	.o_wr(ld_wr), .o_addr(ld_addr), .o_data(ld_data),
	.ee_wr(ee_ld_wr), .ee_addr(ee_ld_addr), .ee_data(ee_ld_data)
);

// The 93C46 EEPROM (the game's settings and high scores) to the SD card: the MRA's <nvram index="4" size="128"/>. Main_MiSTer sends the
// saved file after the ROMs (a download with index 4, the machine held in reset meanwhile) and reads it back (an upload with index 4)
// when the core asks (ioctl_upload_req): when the OSD opens after the game wrote its EEPROM (Autosave EEPROM On) and on Save EEPROM.
// The file is MAME's nvram/<set>/eeprom (128 bytes, little-endian words). Once a saved file has come, the image's default contents
// are not written over it (as in the Metro core).
wire        ee_written;
wire        nv_dl = ioctl_download && (ioctl_index[7:0] == NV_INDEX);
wire        nv_ul = ioctl_upload && (ioctl_index[7:0] == NV_INDEX);
wire        nv_wr = nv_dl && ioctl_wr && (ioctl_addr[26:7] == 20'd0);
reg         nv_loaded = 1'b0;
reg         nv_dirty = 1'b0, nv_ul_d = 1'b0, osd_d = 1'b0, save_d = 1'b0;
always @(posedge clk_sys) begin
	if (dl_start) nv_loaded <= 1'b0;
	else if (nv_wr) nv_loaded <= 1'b1;
	nv_ul_d <= nv_ul;
	osd_d   <= OSD_STATUS;
	save_d  <= status[13];
	nv_req  <= (nv_dirty && !status[12] && OSD_STATUS && !osd_d) || (status[13] && !save_d);
	if (ee_written) nv_dirty <= 1'b1;
	else if (rom_dl || nv_dl || (nv_ul && !nv_ul_d)) nv_dirty <= 1'b0;
end

// the SDRAM and its six read clients (rtl/rabbit_core.sv)
wire        m_req [6], m_ack [6], m_valid [6];
wire [23:0] m_addr [6];
wire  [4:0] m_len [6];
wire [15:0] m_rdata;
wire        mem_ready;

rabbit_sdram #(.NC(6)) u_sdram
(
	.clk(clk_sys), .rst_n(pll_locked), .o_ready(mem_ready), .i_rd_late(1'b0),
	.i_dl_wr(ld_wr), .i_dl_addr(ld_addr), .i_dl_data(ld_data), .o_dl_busy(dl_busy),
	.c_req(m_req), .c_addr(m_addr), .c_len(m_len), .c_ack(m_ack), .c_valid(m_valid), .o_rdata(m_rdata),
	.SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_CKE(SDRAM_CKE)
);

///////////////////////   THE MACHINE   ///////////////////////

wire        reset_sw = RESET | status[0] | buttons[1];
// held while a ROM loads and until the memory is up; registered, it fans out to the whole core
reg         mc_rst = 1'b1;
always @(posedge clk_sys) mc_rst <= reset_sw | rom_dl | fast_dl | dl_busy | nv_dl | ~mem_ready | ~pll_locked;
reg         c_flush = 1'b1;
always @(posedge clk_sys) c_flush <= rom_dl | fast_dl | ~pll_locked;

wire        ce_pix, hs, vs, hblank, vblank;
wire  [7:0] r, g, b;
wire signed [15:0] snd_l, snd_r;
wire        frame_tick;

rabbit_core u_core
(
	.clk(clk_sys), .reset(mc_rst), .cache_flush(c_flush),
	.m_req(m_req), .m_addr(m_addr), .m_len(m_len), .m_ack(m_ack), .m_valid(m_valid), .m_rdata(m_rdata),
	.in_port(in_port),
	.ee_ld_wr(ee_ld_wr && !nv_loaded && !nv_wr), .ee_ld_addr(ee_ld_addr), .ee_ld_data(ee_ld_data),
	.ee_nv_wr(nv_wr), .ee_nv_addr(ioctl_addr[6:0]), .ee_nv_data(ioctl_dout), .ee_nv_raddr(ioctl_addr[6:0]), .ee_nv_rdata(ioctl_din),
	.ee_written(ee_written),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hs(hs), .vs(vs), .r(r), .g(g), .b(b),
	.audio_l(snd_l), .audio_r(snd_r),
	.dbg_frame(frame_tick), .dbg_overrun_a(), .dbg_overrun_b(), .dbg_addr(), .dbg_step()
);

///////////////////////   AUDIO   ///////////////////////

// the OSD's volume steps on MAME's own level
function automatic signed [15:0] f_vol(input signed [15:0] v, input [1:0] st);
	reg signed [16:0] gv;
	begin
		gv = (st == 2'd0) ? {v[15], v} : (st == 2'd1) ? {{2{v[15]}}, v[15:1]} : (st == 2'd2) ? {{3{v[15]}}, v[15:2]} : {v, 1'b0};
		f_vol = (gv > 17'sd32767) ? 16'sd32767 : (gv < -17'sd32768) ? -16'sd32768 : gv[15:0];
	end
endfunction
assign AUDIO_L = f_vol(status[10] ? snd_r : snd_l, status[9:8]);
assign AUDIO_R = f_vol(status[10] ? snd_l : snd_r, status[9:8]);

///////////////////////   VIDEO   ///////////////////////

// while the machine is held in reset the core's raster does not run: a blank one of the same timing keeps the OSD's "Loading" pop-up alive
wire        sb_ce, sb_hblank, sb_vblank, sb_hs, sb_vs;
rabbit_standby u_standby (.clk(clk_sys), .o_ce(sb_ce), .o_hblank(sb_hblank), .o_vblank(sb_vblank), .o_hs(sb_hs), .o_vs(sb_vs));
reg         sb_on = 1'b1;
always @(posedge clk_sys) sb_on <= mc_rst;

wire        vga_de_i;
arcade_video #(.WIDTH(320), .DW(24)) arcade_video
(
	.*,
	.VGA_DE(vga_de_i),
	.clk_video(clk_sys),
	.ce_pix(sb_on ? sb_ce : ce_pix),
	.RGB_in(sb_on ? 24'd0 : {r, g, b}),
	.HBlank(sb_on ? sb_hblank : hblank),
	.VBlank(sb_on ? sb_vblank : vblank),
	.HSync(sb_on ? sb_hs : hs),
	.VSync(sb_on ? sb_vs : vs),
	.fx(status[5:3])
);

// Scale: the framework's video_freak; its SCALE input counts 0 Normal, 1 V-Integer, 2 Narrower HV-Integer, 3 HV-Integer+, 4 HV-Integer
reg   [2:0] scale_sel;
always @* begin
	case (status[34:32])
		3'd1:    scale_sel = 3'd1;
		3'd2:    scale_sel = 3'd4;
		3'd3:    scale_sel = 3'd2;
		3'd4:    scale_sel = 3'd3;
		default: scale_sel = 3'd0;
	endcase
end
wire fs_int = (ar == 2'd1) && (scale_sel != 3'd0) && (HDMI_WIDTH != 12'd0) && (HDMI_HEIGHT != 12'd0);

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de_i),
	.ARX(fs_int ? HDMI_WIDTH  : (ar == 2'd0) ? 12'd4 : {10'd0, ar - 2'd1}),
	.ARY(fs_int ? HDMI_HEIGHT : (ar == 2'd0) ? 12'd3 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale_sel)
);

///////////////////////   LEDs   ///////////////////////

// user LED: on while a load / reset holds the machine, then a blink every frame
reg led_frame = 1'b0;
always @(posedge clk_sys) if (frame_tick) led_frame <= ~led_frame;
assign LED_USER = mc_rst ? 1'b1 : led_frame;

endmodule
