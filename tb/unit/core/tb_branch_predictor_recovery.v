`timescale 1ns / 1ps

// Testbench: tb_branch_predictor_recovery
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Direct predictor-state recovery cases, wrong targets, BTB alias gating, and correct-prediction no-miss
//   behavior.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_branch_predictor_recovery;

`include "tb_common.vh"

    reg saw_not_taken_recovery;
    reg saw_target_recovery;
    reg saw_alias_non_branch;
    reg saw_correct_prediction;
    reg await_not_taken_recovery;
    reg await_target_recovery;
    reg [31:0] miss_count_at_correct_prediction;

    always @(posedge clock) begin
        if (!reset && dut.control_resolution_accept &&
            dut.IDEXValid && dut.IDEXBranch && (dut.IDEXPC == 32'd0)) begin
            if (!dut.branch_mispredict || dut.redirect_taken || dut.ControlRedirectPending) begin
                $display("FAIL: not-taken recovery was not captured before registered redirect");
                $fatal;
            end
            await_not_taken_recovery = 1'b1;
        end

        if (!reset && dut.control_resolution_accept &&
            dut.IDEXValid && dut.IDEXBranch && (dut.IDEXPC == 32'd32)) begin
            if (!dut.branch_mispredict || dut.redirect_taken || dut.ControlRedirectPending) begin
                $display("FAIL: wrong-target recovery was not captured before registered redirect");
                $fatal;
            end
            await_target_recovery = 1'b1;
        end

        if (!reset && await_not_taken_recovery && dut.ControlRedirectPending) begin
            if (!dut.redirect_taken || (dut.redirect_pc !== 32'd4)) begin
                $display("FAIL: registered not-taken recovery did not redirect to PC+4");
                $fatal;
            end
            await_not_taken_recovery = 1'b0;
            saw_not_taken_recovery = 1'b1;
        end

        if (!reset && await_target_recovery && dut.ControlRedirectPending) begin
            if (!dut.redirect_taken || (dut.redirect_pc !== 32'd48)) begin
                $display("FAIL: registered wrong-target recovery did not use correct target");
                $fatal;
            end
            await_target_recovery = 1'b0;
            saw_target_recovery = 1'b1;
        end

        if (!reset && dut.IFIDValid && (dut.IFIDPC == 32'd64)) begin
            if (dut.IFIDPredTaken !== 1'b0) begin
                $display("FAIL: BTB alias made a non-branch predict taken");
                $fatal;
            end
            saw_alias_non_branch = 1'b1;
        end

        if (!reset && dut.control_resolution_accept &&
            dut.IDEXValid && dut.IDEXBranch && (dut.IDEXPC == 32'd80)) begin
            if (!dut.IDEXPredTaken ||
                (dut.IDEXPredPC !== 32'd88) ||
                dut.branch_mispredict ||
                dut.redirect_taken) begin
                $display("FAIL: correctly predicted taken branch misreported redirect/miss");
                $fatal;
            end
            saw_correct_prediction = 1'b1;
            miss_count_at_correct_prediction = dut.BranchMissCount;
        end
    end

    initial begin
        $dumpfile("wave/tb_branch_predictor_recovery.vcd");
        $dumpvars(0, tb_branch_predictor_recovery);
        saw_not_taken_recovery = 1'b0;
        saw_target_recovery = 1'b0;
        saw_alias_non_branch = 1'b0;
        saw_correct_prediction = 1'b0;
        await_not_taken_recovery = 1'b0;
        await_target_recovery = 1'b0;
        miss_count_at_correct_prediction = 32'h0;
        reset_cpu();

        dut.gen_branch_predictor.branch_predictor_inst.BHT[0] = 2'b11;
        dut.gen_branch_predictor.branch_predictor_inst.BTBValid[0] = 1'b1;
        dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[0] = 32'd16;

        dut.gen_branch_predictor.branch_predictor_inst.BHT[8] = 2'b11;
        dut.gen_branch_predictor.branch_predictor_inst.BTBValid[8] = 1'b1;
        dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[8] = 32'd44;

        dut.gen_branch_predictor.branch_predictor_inst.BHT[4] = 2'b11;
        dut.gen_branch_predictor.branch_predictor_inst.BTBValid[4] = 1'b1;
        dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[4] = 32'd88;

        dut.IMemory[0]  = b_type(16, 5'd1, 5'd0, 3'b000, 7'b1100011);      // beq x0, x1, wrong_target; actual not taken
        dut.IMemory[1]  = i_type(12'd22, 5'd0, 3'b000, 5'd2, 7'b0010011); // recovery path
        dut.IMemory[2]  = j_type(24, 5'd0, 7'b1101111);                   // jump to PC 32
        dut.IMemory[4]  = i_type(12'd99, 5'd0, 3'b000, 5'd5, 7'b0010011); // wrong branch target

        dut.IMemory[8]  = b_type(16, 5'd0, 5'd0, 3'b000, 7'b1100011);     // beq x0, x0, PC 48; predicted target PC 44
        dut.IMemory[11] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011); // wrong predicted target
        dut.IMemory[12] = i_type(12'd33, 5'd0, 3'b000, 5'd3, 7'b0010011); // correct target
        dut.IMemory[13] = j_type(12, 5'd0, 7'b1101111);                   // jump to PC 64

        dut.IMemory[16] = i_type(12'd44, 5'd0, 3'b000, 5'd4, 7'b0010011); // non-branch aliases BHT/BTB index 0
        dut.IMemory[17] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);
        dut.IMemory[18] = j_type(8, 5'd0, 7'b1101111);                    // jump to PC 80

        dut.IMemory[20] = b_type(8, 5'd0, 5'd0, 3'b000, 7'b1100011);      // correctly predicted taken to PC 88
        dut.IMemory[21] = i_type(12'd55, 5'd0, 3'b000, 5'd9, 7'b0010011); // wrong path
        dut.IMemory[22] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);      // halt

        run_cycles(240);

        if (!saw_not_taken_recovery || !saw_target_recovery ||
            !saw_alias_non_branch || !saw_correct_prediction) begin
            $display("FAIL: missing recovery observations not_taken=%0d target=%0d alias=%0d correct=%0d",
                     saw_not_taken_recovery,
                     saw_target_recovery,
                     saw_alias_non_branch,
                     saw_correct_prediction);
            $fatal;
        end

        check_reg(2, 32'd22);
        check_reg(3, 32'd33);
        check_reg(4, 32'd44);
        check_reg(7, 32'd77);
        check_reg(5, 32'd5);
        check_reg(6, 32'd6);
        check_reg(9, 32'd9);

        if (dut.BranchMissCount < miss_count_at_correct_prediction) begin
            $display("FAIL: branch miss count moved backwards");
            $fatal;
        end

        $display("PASS: branch predictor recovery and alias behavior checked");
        $display("PASS: tb_branch_predictor_recovery passed");
        $finish;
    end

endmodule
