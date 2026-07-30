`timescale 1ns / 1ps

// Module: hazard_unit
// Role: Load-use hazard detector for the decode/execute boundary.
// Interface: Decode source registers, execute-stage destination/control fields, and a stall request output.
// Key behavior: Requests a pipeline interlock when a consumer would read data before a load can produce it.

module hazard_unit (
    input [6:0] ifid_opcode,
    input [2:0] ifid_funct3,
    input [4:0] ifid_rs1,
    input [4:0] ifid_rs2,
    input idex_mem_read,
    input [4:0] idex_rd,
    output load_use_hazard
);
    localparam [6:0] ALUR_OPCODE = 7'b0110011;
    localparam [6:0] ALUI_OPCODE = 7'b0010011;
    localparam [6:0] LOAD_OPCODE = 7'b0000011;
    localparam [6:0] STORE_OPCODE = 7'b0100011;
    localparam [6:0] BRANCH_OPCODE = 7'b1100011;
    localparam [6:0] JALR_OPCODE = 7'b1100111;
    localparam [6:0] SYSTEM_OPCODE = 7'b1110011;

    wire ifid_uses_rs1 =
        (ifid_opcode == ALUR_OPCODE) ||
        (ifid_opcode == ALUI_OPCODE) ||
        (ifid_opcode == LOAD_OPCODE) ||
        (ifid_opcode == STORE_OPCODE) ||
        (ifid_opcode == BRANCH_OPCODE) ||
        (ifid_opcode == JALR_OPCODE) ||
        ((ifid_opcode == SYSTEM_OPCODE) && (ifid_funct3 != 3'b000) && (ifid_funct3[2] == 1'b0));

    wire ifid_uses_rs2 =
        (ifid_opcode == ALUR_OPCODE) ||
        (ifid_opcode == STORE_OPCODE) ||
        (ifid_opcode == BRANCH_OPCODE);

    assign load_use_hazard =
        idex_mem_read &&
        (idex_rd != 5'd0) &&
        (
            (ifid_uses_rs1 && (idex_rd == ifid_rs1)) ||
            (ifid_uses_rs2 && (idex_rd == ifid_rs2))
        );
endmodule
