`timescale 1ns / 1ps

// Module: forwarding_unit
// Role: Operand forwarding selector for the pipelined core.
// Interface: Source register numbers, downstream destination/writeback controls, and forwarding select outputs.
// Key behavior: Chooses EX/MEM or MEM/WB bypass sources to reduce RAW dependency stalls.

module forwarding_unit (
    input [31:0] idex_a,
    input [31:0] idex_b,
    input [4:0] idex_rs1,
    input [4:0] idex_rs2,

    // Producer-valid inputs already include pipeline validity, architectural
    // RegWrite, and rd!=x0. Keeping that ownership at the pipeline boundary
    // leaves only the source-register equality in this timing-sensitive cone.
    input exmem_producer_valid,
    input [4:0] exmem_rd,
    input [31:0] exmem_forward_value,

    input memwb_producer_valid,
    input [4:0] memwb_rd,
    input [31:0] memwb_value,

    input [31:0] exmem_b,
    input [4:0] exmem_rs2,

    output reg [31:0] forward_a,
    output [1:0] forward_a_address_low,
    output reg [31:0] forward_b,
    output reg [31:0] store_data
);

    wire exmem_forward_rs1 = exmem_producer_valid && (exmem_rd == idex_rs1);
    wire memwb_forward_rs1 = memwb_producer_valid && (memwb_rd == idex_rs1);
    wire exmem_forward_rs2 = exmem_producer_valid && (exmem_rd == idex_rs2);
    wire memwb_forward_rs2 = memwb_producer_valid && (memwb_rd == idex_rs2);
    wire memwb_forward_store = memwb_producer_valid && (memwb_rd == exmem_rs2);

    // Preserve only the tiny mux boundary. The compare/select wires remain
    // shared, while the full execute operand stays free for normal optimization.
    (* keep_hierarchy = "yes" *) forwarding_address_low_unit address_low_mux (
        .exmem_select(exmem_forward_rs1),
        .memwb_select(memwb_forward_rs1),
        .idex_low(idex_a[1:0]),
        .exmem_low(exmem_forward_value[1:0]),
        .memwb_low(memwb_value[1:0]),
        .forwarded_low(forward_a_address_low)
    );

    always @(*) begin
        forward_a = idex_a;
        forward_b = idex_b;
        store_data = exmem_b;

        if (exmem_forward_rs1) begin
            forward_a = exmem_forward_value;
        end else if (memwb_forward_rs1) begin
            forward_a = memwb_value;
        end

        if (exmem_forward_rs2) begin
            forward_b = exmem_forward_value;
        end else if (memwb_forward_rs2) begin
            forward_b = memwb_value;
        end

        if (memwb_forward_store) begin
            store_data = memwb_value;
        end
    end

endmodule

// Module: forwarding_address_low_unit
// Role: Local two-bit rs1 forwarding datapath for load/store alignment decode.
// Interface: Shared EX/MEM and MEM/WB selects plus the three candidate low-bit values.
// Key behavior: Preserves EX/MEM priority, then MEM/WB, then the ID/EX register value.

module forwarding_address_low_unit (
    input exmem_select,
    input memwb_select,
    input [1:0] idex_low,
    input [1:0] exmem_low,
    input [1:0] memwb_low,
    output [1:0] forwarded_low
);

    assign forwarded_low =
        exmem_select ? exmem_low :
        memwb_select ? memwb_low :
        idex_low;

endmodule
