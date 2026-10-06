`timescale 1ns / 1ps

// Module: exception_decode_unit
// Role: Combinational execute-stage classifier for the selected machine-mode trap subset.
// Interface: Instruction fields, an optional RV32M enable parameter, memory/control-transfer metadata, and classification outputs.
// Key behavior: Identifies ecall/ebreak/mret/CSR accesses, illegal instructions, and misaligned instruction/load/store exceptions.

module exception_decode_unit #(
    parameter ENABLE_RV32M = 1
) (
    input valid,
    input [31:0] instruction,
    input [6:0] opcode,
    input [2:0] funct3,
    input [6:0] funct7,
    input [11:0] csr_addr,
    input mem_read,
    input mem_write,
    input [1:0] load_address_low,
    input [1:0] store_address_low,
    input control_transfer_taken,
    input [1:0] control_target_address_low,

    output is_ecall,
    output is_ebreak,
    output is_mret,
    output is_csr_access,
    output is_valid_csr,
    output is_misaligned_load,
    output is_misaligned_store,
    output is_misaligned_access,
    output is_misaligned_instruction,
    output is_legal_instruction
);

    localparam [6:0] ALURop   = 7'b0110011;
    localparam [6:0] ALUIop   = 7'b0010011;
    localparam [6:0] LOADop   = 7'b0000011;
    localparam [6:0] STOREop  = 7'b0100011;
    localparam [6:0] BRANCHop = 7'b1100011;
    localparam [6:0] JALop    = 7'b1101111;
    localparam [6:0] JALRop   = 7'b1100111;
    localparam [6:0] LUIop    = 7'b0110111;
    localparam [6:0] AUIPCop  = 7'b0010111;
    localparam [6:0] SYSTEMop = 7'b1110011;

    wire is_legal_rtype;
    wire is_legal_itype;
    wire is_legal_load;
    wire is_legal_store;
    wire is_legal_branch;
    wire is_legal_jalr;
    wire is_legal_system;
    wire is_legal_m_extension;

    assign is_ecall = (instruction == 32'h0000_0073);
    assign is_ebreak = (instruction == 32'h0010_0073);
    assign is_mret = (opcode == SYSTEMop) && (instruction == 32'h3020_0073);
    assign is_csr_access =
        (opcode == SYSTEMop) &&
        (
            (funct3 == 3'b001) ||
            (funct3 == 3'b010) ||
            (funct3 == 3'b011)
        );
    assign is_valid_csr =
        (csr_addr == 12'h300) ||
        (csr_addr == 12'h304) ||
        (csr_addr == 12'h305) ||
        (csr_addr == 12'h341) ||
        (csr_addr == 12'h342) ||
        (csr_addr == 12'h343) ||
        (csr_addr == 12'h344);

    assign is_misaligned_load =
        mem_read &&
        (
            (((funct3 == 3'b001) || (funct3 == 3'b101)) && load_address_low[0]) ||
            ((funct3 == 3'b010) && (load_address_low != 2'b00))
        );
    assign is_misaligned_store =
        mem_write &&
        (
            ((funct3 == 3'b001) && store_address_low[0]) ||
            ((funct3 == 3'b010) && (store_address_low != 2'b00))
        );
    assign is_misaligned_access = is_misaligned_load || is_misaligned_store;

    assign is_legal_m_extension = ENABLE_RV32M && (funct7 == 7'b0000001);
    assign is_legal_rtype =
        (opcode == ALURop) &&
        (
            ({funct7, funct3} == {7'b0000000, 3'b000}) ||
            ({funct7, funct3} == {7'b0100000, 3'b000}) ||
            ({funct7, funct3} == {7'b0000000, 3'b001}) ||
            ({funct7, funct3} == {7'b0000000, 3'b010}) ||
            ({funct7, funct3} == {7'b0000000, 3'b011}) ||
            ({funct7, funct3} == {7'b0000000, 3'b100}) ||
            ({funct7, funct3} == {7'b0000000, 3'b101}) ||
            ({funct7, funct3} == {7'b0100000, 3'b101}) ||
            ({funct7, funct3} == {7'b0000000, 3'b110}) ||
            ({funct7, funct3} == {7'b0000000, 3'b111}) ||
            is_legal_m_extension
        );
    assign is_legal_itype =
        (opcode == ALUIop) &&
        (
            (funct3 == 3'b000) ||
            (funct3 == 3'b010) ||
            (funct3 == 3'b011) ||
            (funct3 == 3'b100) ||
            ((funct3 == 3'b001) && (funct7 == 7'b0000000)) ||
            ((funct3 == 3'b101) && ((funct7 == 7'b0000000) || (funct7 == 7'b0100000))) ||
            (funct3 == 3'b110) ||
            (funct3 == 3'b111)
        );
    assign is_legal_load =
        (opcode == LOADop) &&
        (
            (funct3 == 3'b000) ||
            (funct3 == 3'b001) ||
            (funct3 == 3'b010) ||
            (funct3 == 3'b100) ||
            (funct3 == 3'b101)
        );
    assign is_legal_store =
        (opcode == STOREop) &&
        (
            (funct3 == 3'b000) ||
            (funct3 == 3'b001) ||
            (funct3 == 3'b010)
        );
    assign is_legal_branch =
        (opcode == BRANCHop) &&
        (
            (funct3 == 3'b000) ||
            (funct3 == 3'b001) ||
            (funct3 == 3'b100) ||
            (funct3 == 3'b101) ||
            (funct3 == 3'b110) ||
            (funct3 == 3'b111)
        );
    assign is_legal_jalr = (opcode == JALRop) && (funct3 == 3'b000);
    // Legality is intentionally bounded to the implemented RV32IM-style
    // integer operations and selected machine-mode SYSTEM instructions.
    assign is_legal_system = is_ecall || is_ebreak || is_mret || (is_csr_access && is_valid_csr);
    assign is_legal_instruction =
        !valid ||
        is_legal_rtype ||
        is_legal_itype ||
        is_legal_load ||
        is_legal_store ||
        is_legal_branch ||
        (opcode == JALop) ||
        is_legal_jalr ||
        (opcode == LUIop) ||
        (opcode == AUIPCop) ||
        is_legal_system;
    // RV32I without the compressed extension uses IALIGN=32. A taken control
    // transfer to an address whose low two bits are nonzero traps on the
    // branch or jump instruction; an untaken branch does not trap.
    assign is_misaligned_instruction =
        valid &&
        is_legal_instruction &&
        control_transfer_taken &&
        (control_target_address_low != 2'b00);
endmodule
