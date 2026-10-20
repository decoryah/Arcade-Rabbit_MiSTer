//------------------------------------------------------------------------------
// Rabbit main board: the 68EC020 @ 24 MHz and everything on its bus (MAME 0.289 src/mame/metro/rabbit.cpp, rabbit_map).
//
// The CPU is TG68K.C in its 68020 mode, paced by a token bucket (the scheme of the owner's Mystic Warriors / Gaiapolis cores): every kernel
// step that runs a bus cycle costs STEP_COST_BUS tokens, an internal step STEP_COST_INT, and STEP_GAIN tokens arrive every clock; the kernel
// never steps closer than four clocks apart (the multicycle constraint of Rabbit.sdc). The kernel's bus is 16 bits wide: a long access is two
// word cycles, which is how the 32-bit registers of the video chip see byte enables per word here.
//
//   000000-1fffff  program ROM (through rabbit_cache)            400900-4009ff  I5000 sound registers (16-bit)
//   200000-200003  inputs (read), EEPROM (byte write at 200000)  440000-47ffff  gfx1 readback window (MAME: bank 0)
//   400010-400013  status (read: bit 7 of 400012 = blitter busy)  480000-48ffff  tilemaps 0-3 \
//   400100-400177  tilemap registers  \                          494000-497fff  sprite RAM    } the video port (rabbit_video)
//   400200-40021b  sprite registers    } the video port           4a0000-4affff  palette      /
//   400700-40070f  blitter registers (a write to 40070e starts it) ff0000-ffffff  work RAM
//
// Interrupts are MAME's: level 6 at the start of vblank and level 4 500 us after a blit was started, each held until the CPU's
// interrupt acknowledge cycle (HOLD_LINE), autovectored. The game's enable / acknowledge writes to 400010 / 400012 change nothing (as in MAME).
//------------------------------------------------------------------------------
`default_nettype none

module rabbit_main #(
    parameter int STEP_COST_BUS = 4,
    parameter int STEP_COST_INT = 4,
    parameter int STEP_GAIN     = 1
) (
    input  logic        clk,
    input  logic        reset,

    // program ROM (rabbit_cache)
    output logic        rom_req,
    output logic [19:0] rom_addr,        // word address
    input  logic        rom_ack,
    input  logic [15:0] rom_q,

    // gfx1 readback: one SDRAM word, uncached
    output logic        gr_req,
    output logic [23:0] gr_addr,         // SDRAM word address
    input  logic        gr_ack,
    input  logic        gr_valid,
    input  logic [15:0] gr_data,

    // the video chip: registers and memories, request / ack
    output logic        v_req,
    output logic        v_we,
    output logic [17:1] v_addr,          // A17:1: the registers at 4001xx / 4002xx (v_mem = 0), the memories at 48xxxx / 494000 / 4axxxx (v_mem = 1)
    output logic        v_mem,
    output logic  [1:0] v_be,            // {uds, lds}
    output logic [15:0] v_wdata,
    input  logic        v_ack,
    input  logic [15:0] v_rdata,

    // the blitter
    output logic        blt_start,       // one clock: 40070e written
    output logic [31:0] blt_regs [3],
    input  logic        blt_busy,

    // the I5000's registers
    output logic        snd_wr,
    output logic  [6:0] snd_reg,
    output logic [15:0] snd_wdata,
    input  logic [15:0] snd_rdata,       // the register snd_reg reads (combinational)

    // interrupts
    input  logic        vbl_irq,         // one clock: vblank starts
    input  logic        blt_irq,         // one clock: the blit-done timer expired

    // inputs, as MAME's INPUTS port without bit 0 (active low)
    input  logic [31:0] in_port,

    // EEPROM (93C46)
    output logic        eep_wr,          // one clock: the lines below were written (rabbit_eeprom takes the edges)
    output logic        eep_cs,
    output logic        eep_clk,
    output logic        eep_di,
    input  logic        eep_do,

    // diagnostics
    output logic [23:0] dbg_pc_addr,
    output logic        dbg_step,
    output logic        dbg_rd,          // one clock: a data read starts at dbg_rd_addr (benches)
    output logic [23:0] dbg_rd_addr
);
    // ------------------------------------------------------------ TG68K
    logic        clkena;
    logic [15:0] data_in;
    logic  [2:0] ipl_n;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] addr_out;
    logic        nResetOut, longword, clr_berr;
    logic [31:0] regin_out, vbr_out;
    logic  [3:0] cacr_out;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] data_write;
    logic        nWr, nUDS, nLDS;
    logic  [1:0] busstate;
    logic  [2:0] fc;
    logic        skipFetch;
    logic  [2:0] step_gap;

    TG68KdotC_Kernel cpu (
        .clk            ( clk ),
        .nReset         ( ~reset ),
        .clkena_in      ( clkena ),
        .data_in        ( data_in ),
        .IPL            ( ipl_n ),
        .IPL_autovector ( 1'b1 ),
        .berr           ( 1'b0 ),
        .CPU            ( 2'b11 ),          // 68020
        .addr_out       ( addr_out ),
        .data_write     ( data_write ),
        .nWr            ( nWr ),
        .nUDS           ( nUDS ),
        .nLDS           ( nLDS ),
        .busstate       ( busstate ),
        .longword       ( longword ),
        .nResetOut      ( nResetOut ),
        .FC             ( fc ),
        .clr_berr       ( clr_berr ),
        .skipFetch      ( skipFetch ),
        .regin_out      ( regin_out ),
        .CACR_out       ( cacr_out ),
        .VBR_out        ( vbr_out )
    );

    wire [23:1] A     = addr_out[23:1];      // the 68EC020's 24-bit bus
    wire        is_wr = (busstate == 2'b11);
    wire        is_int = (busstate == 2'b01) || skipFetch;
    wire        uds   = ~nUDS;
    wire        lds   = ~nLDS;
    wire [15:0] wdat  = data_write;
    assign dbg_pc_addr = {A, 1'b0};

    // ------------------------------------------------------------ decode
    wire sel_rom    = (A[23:21] == 3'b000);                      // 000000-1fffff
    wire sel_in     = (A[23:2]  == 22'h080000);                  // 200000-200003
    wire sel_stat   = (A[23:2]  == 22'h100004);                  // 400010-400013
    wire sel_vreg   = (A[23:8]  == 16'h4001) || (A[23:8] == 16'h4002);   // 400100-4002ff: tilemap and sprite registers
    wire sel_blt    = (A[23:4]  == 20'h40070);                   // 400700-40070f
    wire sel_snd    = (A[23:8]  == 16'h4009);                    // 400900-4009ff
    wire sel_grom   = (A[23:18] == 6'b010001);                   // 440000-47ffff
    wire sel_vmem   = (A[23:16] == 8'h48) || (A[23:14] == 10'b0100_1001_01) || (A[23:16] == 8'h4a);   // 480000-48ffff, 494000-497fff, 4a0000-4affff
    wire sel_wram   = (A[23:16] == 8'hff);                       // ff0000-ffffff

    // ------------------------------------------------------------ work RAM, 32K x 16
    logic [15:0] wram_q;
    rabbit_ram_be #(.AW(15), .NB(2)) u_wram (
        .clk(clk), .we(cpu_wr && sel_wram), .wa(A[15:1]), .be({uds, lds}), .d(wdat), .ra(A[15:1]), .q(wram_q)
    );

    // ------------------------------------------------------------ interrupts
    logic irq6_pend, irq4_pend;
    assign ipl_n = irq6_pend ? 3'b001 : irq4_pend ? 3'b011 : 3'b111;

    // ------------------------------------------------------------ the read multiplexer of the one-clock sources
    logic [15:0] rd_mux;
    always_comb begin
        rd_mux = 16'h0000;
        if (sel_wram)      rd_mux = wram_q;
        else if (sel_in)   rd_mux = A[1] ? {in_port[15:1], eep_do} : in_port[31:16];
        else if (sel_stat) rd_mux = A[1] ? {8'h00, blt_busy, 7'h00} : 16'h0000;
        else if (sel_snd)  rd_mux = snd_rdata;
    end
    assign snd_reg = A[7:1];

    // ------------------------------------------------------------ the bus sequencer
    typedef enum logic [2:0] { B_IDLE, B_RAM_RD, B_WAIT_ROM, B_WAIT_GR, B_WAIT_V } bst_t;
    bst_t bst;
    logic [6:0] tok;
    logic       gr_taken;

    wire [6:0] step_cost = is_int ? 7'(STEP_COST_INT) : 7'(STEP_COST_BUS);
    wire cpu_step = (bst == B_IDLE) && (tok >= step_cost) && !clkena && (step_gap == 3'd0);
    wire cpu_wr   = cpu_step && (fc != 3'b111) && !is_int && is_wr;

    // gfx1 byte offset of the readback word (bank 0 of MAME's region, the window's u32s read as MAME's little-endian host does: the CPU's
    // high word is region bytes 3, 2 and its low word bytes 1, 0); its SDRAM word: 0x100000 + {b[22:2], b[23], b[1]} (rabbit_loader.sv)
    wire [17:0] gb = {A[17:2], ~A[1], 1'b0};

    always_ff @(posedge clk) begin
        clkena   <= 1'b0;
        dbg_step <= 1'b0;
        blt_start <= 1'b0;
        snd_wr   <= 1'b0;
        eep_wr   <= 1'b0;
        step_gap <= {step_gap[1:0], clkena};
        if (gr_ack) gr_req <= 1'b0;
        dbg_rd <= cpu_step && (busstate == 2'b10) && (fc != 3'b111);
        dbg_rd_addr <= {A, 1'b0};

        if (reset) begin
            bst <= B_IDLE; tok <= '0; step_gap <= '0;
            irq6_pend <= 1'b0; irq4_pend <= 1'b0;
            rom_req <= 1'b0; gr_req <= 1'b0; v_req <= 1'b0;
            eep_cs <= 1'b0; eep_di <= 1'b0; eep_clk <= 1'b0;
            for (int i = 0; i < 3; i++) blt_regs[i] <= '0;
        end else begin
            if (tok < 7'd64) tok <= tok + 7'(STEP_GAIN);
            if (vbl_irq) irq6_pend <= 1'b1;
            if (blt_irq) irq4_pend <= 1'b1;

            case (bst)
                B_IDLE: if (cpu_step) begin
                    if (fc == 3'b111 && !is_int) begin
                        // interrupt acknowledge: the level being taken drops (HOLD_LINE); the vector is the autovector
                        clkena <= 1'b1; dbg_step <= 1'b1; tok <= tok - step_cost;
                        if (A[3:1] == 3'd6) irq6_pend <= 1'b0;
                        if (A[3:1] == 3'd4) irq4_pend <= 1'b0;
                    end else if (is_int) begin
                        clkena <= 1'b1; dbg_step <= 1'b1; tok <= tok - step_cost;
                    end else if (is_wr) begin
                        tok <= tok - step_cost;
                        if (sel_vreg || sel_vmem) begin
                            v_req <= 1'b1; v_we <= 1'b1; v_mem <= sel_vmem; v_addr <= A[17:1];
                            v_be <= {uds, lds}; v_wdata <= wdat;
                            bst <= B_WAIT_V;
                        end else begin
                            clkena <= 1'b1; dbg_step <= 1'b1;     // posted
                        end
                    end else begin
                        tok <= tok - step_cost;
                        if (sel_rom) begin
                            rom_req <= 1'b1; rom_addr <= A[20:1]; bst <= B_WAIT_ROM;
                        end else if (sel_grom) begin
                            gr_req <= 1'b1; gr_addr <= 24'h100000 + 24'({gb[17:2], 1'b0, gb[1]}); gr_taken <= 1'b0; bst <= B_WAIT_GR;
                        end else if (sel_vreg || sel_vmem) begin
                            v_req <= 1'b1; v_we <= 1'b0; v_mem <= sel_vmem; v_addr <= A[17:1]; v_be <= {uds, lds};
                            bst <= B_WAIT_V;
                        end else bst <= B_RAM_RD;
                    end
                end
                B_RAM_RD: begin
                    data_in <= rd_mux; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_ROM: if (rom_ack) begin
                    rom_req <= 1'b0; data_in <= rom_q; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                B_WAIT_GR: begin
                    if (gr_ack) gr_taken <= 1'b1;
                    if (gr_valid && gr_taken) begin
                        data_in <= {gr_data[7:0], gr_data[15:8]};
                        clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                    end
                end
                B_WAIT_V: if (v_ack) begin
                    v_req <= 1'b0; data_in <= v_rdata; clkena <= 1'b1; dbg_step <= 1'b1; bst <= B_IDLE;
                end
                default: bst <= B_IDLE;
            endcase

            // ------------------------------------------------ the posted writes
            if (cpu_wr) begin
                if (sel_in) begin
                    // eeprom_write: only a write of the top byte alone (mem_mask ff000000): DI bit 24, CLK bit 25, CS bit 26
                    if (!A[1] && uds && !lds) begin
                        eep_wr <= 1'b1; eep_di <= wdat[8]; eep_cs <= wdat[10]; eep_clk <= wdat[9];
                    end
                end else if (sel_blt) begin
                    for (int i = 0; i < 3; i++) if (A[3:2] == 2'(i)) begin
                        if (!A[1]) begin
                            if (uds) blt_regs[i][31:24] <= wdat[15:8];
                            if (lds) blt_regs[i][23:16] <= wdat[7:0];
                        end else begin
                            if (uds) blt_regs[i][15:8] <= wdat[15:8];
                            if (lds) blt_regs[i][7:0]  <= wdat[7:0];
                        end
                    end
                    // blitter_w: a write to the fourth dword starts the blit. On this 16-bit bus a long write to 40070c is two word cycles;
                    // the blit starts with the one at 40070e, which every write of the game is (a word write there)
                    if (A[3:1] == 3'b111) blt_start <= 1'b1;
                end else if (sel_snd) begin
                    // i5000snd_device::write ignores anything but a whole word
                    if (uds && lds) begin snd_wr <= 1'b1; snd_wdata <= wdat; end
                end
                // anything else (ROM, the status / IRQ registers, the other write-only registers): ignored
            end
        end
    end

endmodule
`default_nettype wire
