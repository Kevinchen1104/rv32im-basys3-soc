`timescale 1ns / 1ps

// Testbench: tb_branch_jump_unit
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Standalone EX-stage branch/jump resolve unit computes branch decisions, jump targets, correct redirect PCs,
//   and prediction mismatch signals.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_branch_jump_unit;

    localparam [6:0] BRANCH = 7'b1100011;
    localparam [6:0] JAL    = 7'b1101111;
    localparam [6:0] JALR   = 7'b1100111;
    localparam [6:0] ALUI   = 7'b0010011;

    reg [6:0] opcode;
    reg [2:0] funct3;
    reg [31:0] pc;
    reg [31:0] operand_a;
    reg [31:0] operand_b;
    reg [31:0] imm_b;
    reg [31:0] imm_j;
    reg [31:0] imm_i;
    reg pred_taken;
    reg [31:0] pred_pc;

    wire is_branch;
    wire is_jal;
    wire is_jalr;
    wire is_jump;
    wire branch_taken;
    wire branch_mispredict;
    wire jump_mispredict;
    wire [31:0] branch_target;
    wire [31:0] correct_branch_pc;
    wire [31:0] jal_target;
    wire [31:0] jalr_target;
    wire [31:0] jump_target;

    branch_jump_unit dut (
        .opcode(opcode),
        .funct3(funct3),
        .pc(pc),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .imm_b(imm_b),
        .imm_j(imm_j),
        .imm_i(imm_i),
        .pred_taken(pred_taken),
        .pred_pc(pred_pc),
        .is_branch(is_branch),
        .is_jal(is_jal),
        .is_jalr(is_jalr),
        .is_jump(is_jump),
        .branch_taken(branch_taken),
        .branch_mispredict(branch_mispredict),
        .jump_mispredict(jump_mispredict),
        .branch_target(branch_target),
        .correct_branch_pc(correct_branch_pc),
        .jal_target(jal_target),
        .jalr_target(jalr_target),
        .jump_target(jump_target)
    );

    task defaults;
    begin
        opcode = ALUI;
        funct3 = 3'b000;
        pc = 32'h0000_1000;
        operand_a = 32'h0000_0001;
        operand_b = 32'h0000_0002;
        imm_b = 32'h0000_0020;
        imm_j = 32'h0000_0040;
        imm_i = 32'h0000_0004;
        pred_taken = 1'b0;
        pred_pc = 32'h0000_0000;
    end
    endtask

    task check_bool;
        input [255:0] name;
        input actual;
        input expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %0d got %0d", name, expected, actual);
            $fatal;
        end
    end
    endtask

    task check_word;
        input [255:0] name;
        input [31:0] actual;
        input [31:0] expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %h got %h", name, expected, actual);
            $fatal;
        end
    end
    endtask

    initial begin
        defaults();
        opcode = BRANCH;
        funct3 = 3'b000;
        operand_a = 32'd7;
        operand_b = 32'd7;
        #1;
        check_bool("beq taken", branch_taken, 1'b1);

        operand_b = 32'd8;
        #1;
        check_bool("beq not taken", branch_taken, 1'b0);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b001;
        operand_a = 32'd7;
        operand_b = 32'd8;
        #1;
        check_bool("bne taken", branch_taken, 1'b1);

        operand_b = 32'd7;
        #1;
        check_bool("bne not taken", branch_taken, 1'b0);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b100;
        operand_a = 32'hffff_fffe;
        operand_b = 32'd1;
        #1;
        check_bool("blt signed negative", branch_taken, 1'b1);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b101;
        operand_a = 32'hffff_ffff;
        operand_b = 32'hffff_fffe;
        #1;
        check_bool("bge signed", branch_taken, 1'b1);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b110;
        operand_a = 32'd1;
        operand_b = 32'hffff_ffff;
        #1;
        check_bool("bltu unsigned", branch_taken, 1'b1);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b111;
        operand_a = 32'hffff_ffff;
        operand_b = 32'd1;
        #1;
        check_bool("bgeu unsigned", branch_taken, 1'b1);

        defaults();
        opcode = BRANCH;
        funct3 = 3'b000;
        operand_a = 32'd3;
        operand_b = 32'd3;
        pred_taken = 1'b0;
        #1;
        check_bool("actual taken predicted not taken", branch_mispredict, 1'b1);
        check_word("branch target", branch_target, 32'h0000_1020);
        check_word("correct taken pc", correct_branch_pc, 32'h0000_1020);

        pred_taken = 1'b1;
        pred_pc = 32'h0000_1020;
        #1;
        check_bool("predicted taken correct target", branch_mispredict, 1'b0);

        pred_pc = 32'h0000_1024;
        #1;
        check_bool("predicted taken wrong target", branch_mispredict, 1'b1);

        operand_b = 32'd4;
        pred_taken = 1'b1;
        pred_pc = 32'h0000_1020;
        #1;
        check_bool("predicted taken actual not taken", branch_mispredict, 1'b1);
        check_word("correct not-taken pc", correct_branch_pc, 32'h0000_1004);

        defaults();
        opcode = JAL;
        imm_j = 32'h0000_0080;
        pred_taken = 1'b0;
        #1;
        check_bool("jal is jump", is_jump, 1'b1);
        check_word("jal target", jal_target, 32'h0000_1080);
        check_word("jal jump target", jump_target, 32'h0000_1080);
        check_bool("jal predicted not taken", jump_mispredict, 1'b1);

        defaults();
        opcode = JALR;
        operand_a = 32'h0000_2003;
        imm_i = 32'h0000_0004;
        #1;
        check_word("jalr clears bit zero", jalr_target, 32'h0000_2006);
        check_word("jalr jump target", jump_target, 32'h0000_2006);

        pred_taken = 1'b1;
        pred_pc = 32'h0000_2006;
        #1;
        check_bool("jalr predicted correct target", jump_mispredict, 1'b0);

        pred_pc = 32'h8000_2006;
        #1;
        check_bool("jalr predicted wrong target", jump_mispredict, 1'b1);

        pred_taken = 1'b0;
        pred_pc = 32'h0000_2006;
        #1;
        check_bool("jalr predicted not taken", jump_mispredict, 1'b1);

        defaults();
        #1;
        check_bool("non branch is_branch", is_branch, 1'b0);
        check_bool("non jump is_jal", is_jal, 1'b0);
        check_bool("non jump is_jalr", is_jalr, 1'b0);
        check_bool("non jump is_jump", is_jump, 1'b0);
        check_bool("non branch branch_taken", branch_taken, 1'b0);
        check_bool("non branch mispredict", branch_mispredict, 1'b0);
        check_bool("non jump mispredict", jump_mispredict, 1'b0);
        check_word("non branch correct pc", correct_branch_pc, 32'h0000_1004);

        $display("PASS: tb_branch_jump_unit passed");
        $finish;
    end

endmodule
