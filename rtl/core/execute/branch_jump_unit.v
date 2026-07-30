`timescale 1ns / 1ps

// Module: branch_jump_unit
// Role: Branch and jump decision unit for the execute stage.
// Interface: Current PC, operands, immediates, branch/jump decode controls, and predicted PC/taken inputs.
// Key behavior: Computes branch condition results, jump targets, link values, and redirect/mispredict information.

module branch_jump_unit (
    input [6:0] opcode,
    input [2:0] funct3,
    input [31:0] pc,
    input [31:0] operand_a,
    input [31:0] operand_b,
    input [31:0] imm_b,
    input [31:0] imm_j,
    input [31:0] imm_i,
    input pred_taken,
    input [31:0] pred_pc,

    output is_branch,
    output is_jal,
    output is_jalr,
    output is_jump,
    output branch_taken,
    output branch_mispredict,
    output jump_mispredict,
    output [31:0] branch_target,
    output [31:0] correct_branch_pc,
    output [31:0] jal_target,
    output [31:0] jalr_target,
    output [31:0] jump_target
);

    localparam [6:0] BRANCH = 7'b1100011;
    localparam [6:0] JAL    = 7'b1101111;
    localparam [6:0] JALR   = 7'b1100111;

    wire is_beq;
    wire is_bne;
    wire is_blt;
    wire is_bge;
    wire is_bltu;
    wire is_bgeu;
    wire [31:0] jump_target_xor;
    wire [7:0] jump_target_mismatch_nibbles;
    wire [1:0] jump_target_mismatch_quarters;
    wire jump_target_mismatch;

    assign is_branch = (opcode == BRANCH);
    assign is_jal = (opcode == JAL);
    assign is_jalr = (opcode == JALR);
    assign is_jump = is_jal || is_jalr;

    assign is_beq = is_branch && (funct3 == 3'b000);
    assign is_bne = is_branch && (funct3 == 3'b001);
    assign is_blt = is_branch && (funct3 == 3'b100);
    assign is_bge = is_branch && (funct3 == 3'b101);
    assign is_bltu = is_branch && (funct3 == 3'b110);
    assign is_bgeu = is_branch && (funct3 == 3'b111);

    assign branch_target = pc + imm_b;
    assign branch_taken =
        (is_beq && (operand_a == operand_b)) ||
        (is_bne && (operand_a != operand_b)) ||
        (is_blt && ($signed(operand_a) < $signed(operand_b))) ||
        (is_bge && ($signed(operand_a) >= $signed(operand_b))) ||
        (is_bltu && (operand_a < operand_b)) ||
        (is_bgeu && (operand_a >= operand_b));

    assign correct_branch_pc = branch_taken ? branch_target : (pc + 32'd4);
    assign branch_mispredict =
        is_branch &&
        (
            (branch_taken != pred_taken) ||
            (branch_taken && pred_taken && (branch_target != pred_pc))
        );

    assign jal_target = pc + imm_j;
    assign jalr_target = (operand_a + imm_i) & 32'hffff_fffe;
    assign jump_target = is_jal ? jal_target : jalr_target;

    // Keep target comparison as a shallow XOR/reduction tree.
    assign jump_target_xor = jump_target ^ pred_pc;
    assign jump_target_mismatch_nibbles = {
        |jump_target_xor[31:28],
        |jump_target_xor[27:24],
        |jump_target_xor[23:20],
        |jump_target_xor[19:16],
        |jump_target_xor[15:12],
        |jump_target_xor[11:8],
        |jump_target_xor[7:4],
        |jump_target_xor[3:0]
    };
    assign jump_target_mismatch_quarters = {
        |jump_target_mismatch_nibbles[7:4],
        |jump_target_mismatch_nibbles[3:0]
    };
    assign jump_target_mismatch = |jump_target_mismatch_quarters;
    assign jump_mispredict =
        is_jump &&
        (
            !pred_taken ||
            jump_target_mismatch
        );

endmodule
