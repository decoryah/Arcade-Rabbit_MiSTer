// Block RAMs in the form Quartus infers (simple dual port: one write port, one registered read port; old data on a read of the address
// being written). rabbit_ram_be has byte enables, written lane by lane as in Intel's template (a loop over the lanes is not inferred).
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
    (* ramstyle = "no_rw_check" *) logic [DW-1:0] mem [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we) mem[wa] <= d;
        q <= mem[ra];
    end
endmodule

module rabbit_ram_be #(
    parameter int AW = 12,
    parameter int NB = 4                  // bytes: 2 or 4
) (
    input  logic            clk,
    input  logic            we,
    input  logic [AW-1:0]   wa,
    input  logic [NB-1:0]   be,
    input  logic [NB*8-1:0] d,
    input  logic [AW-1:0]   ra,
    output logic [NB*8-1:0] q
);
    (* ramstyle = "no_rw_check" *) logic [NB-1:0][7:0] mem [0:(1 << AW) - 1] /*verilator public_flat_rd*/;
    generate if (NB == 4) begin : g4
        always_ff @(posedge clk) begin
            if (we) begin
                if (be[0]) mem[wa][0] <= d[7:0];
                if (be[1]) mem[wa][1] <= d[15:8];
                if (be[2]) mem[wa][2] <= d[23:16];
                if (be[3]) mem[wa][3] <= d[31:24];
            end
            q <= mem[ra];
        end
    end else begin : g2
        always_ff @(posedge clk) begin
            if (we) begin
                if (be[0]) mem[wa][0] <= d[7:0];
                if (be[1]) mem[wa][1] <= d[15:8];
            end
            q <= mem[ra];
        end
    end endgenerate
endmodule
`default_nettype wire
