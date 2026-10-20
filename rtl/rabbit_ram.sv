// Block RAMs in the form Quartus infers (simple dual port: one write port, one registered read port; old data on a read of the address
// being written). rabbit_ram_be has byte enables.
`default_nettype none

module rabbit_ram #(
    parameter int AW = 12,
    parameter int DW = 32
) (
    input  logic          clk,
    input  logic          we,
    input  logic [AW-1:0] wa,
    input  logic [DW-1:0] d,
    input  logic [AW-1:0] ra,
    output logic [DW-1:0] q
);
    (* ramstyle = "no_rw_check" *) logic [DW-1:0] mem [1 << AW];
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= d;
        q <= mem[ra];
    end
endmodule

module rabbit_ram_be #(
    parameter int AW = 12,
    parameter int NB = 4                  // bytes
) (
    input  logic            clk,
    input  logic            we,
    input  logic [AW-1:0]   wa,
    input  logic [NB-1:0]   be,
    input  logic [NB*8-1:0] d,
    input  logic [AW-1:0]   ra,
    output logic [NB*8-1:0] q
);
    (* ramstyle = "no_rw_check" *) logic [NB-1:0][7:0] mem [1 << AW];
    always_ff @(posedge clk) begin
        if (we) for (int i = 0; i < NB; i++) if (be[i]) mem[wa][i] <= d[8*i +: 8];
        q <= mem[ra];
    end
endmodule
`default_nettype wire
