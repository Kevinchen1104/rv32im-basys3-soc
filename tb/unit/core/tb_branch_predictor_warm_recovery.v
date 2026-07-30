`timescale 1ns / 1ps

// Testbench: tb_branch_predictor_warm_recovery
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Natural loop warm-up and predicted-taken/actual-not-taken recovery to PC+4.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_branch_predictor_warm_recovery;

`include "tb_common.vh"

    integer correct_taken_predictions;
    reg saw_not_taken_recovery;
    reg await_not_taken_recovery;
    reg [31:0] branch_miss_at_first_correct_prediction;

    always @(posedge clock) begin
        if (!reset &&
            dut.IDEXValid &&
            dut.IDEXBranch &&
            (dut.IDEXPC == 32'd8)) begin

            if (dut.branch_taken &&
                dut.IDEXPredTaken &&
                (dut.IDEXPredPC == dut.branch_target)) begin

                if (dut.branch_mispredict !== 1'b0) begin
                    $display("FAIL: warm correctly predicted taken branch reported a mispredict");
                    $fatal;
                end

                if (dut.redirect_taken !== 1'b0) begin
                    $display("FAIL: warm correctly predicted taken branch triggered redirect/flush");
                    $fatal;
                end

                if (correct_taken_predictions == 0) begin
                    branch_miss_at_first_correct_prediction = dut.BranchMissCount;
                end else if (dut.BranchMissCount !== branch_miss_at_first_correct_prediction) begin
                    $display("FAIL: branch miss count changed across stable correct predictions");
                    $fatal;
                end

                correct_taken_predictions = correct_taken_predictions + 1;
            end

            if (!dut.branch_taken && dut.IDEXPredTaken) begin
                if (dut.branch_mispredict !== 1'b1) begin
                    $display("FAIL: warm predicted-taken/actual-not-taken branch missed recovery");
                    $fatal;
                end

                if (dut.redirect_taken || dut.ControlRedirectPending) begin
                    $display("FAIL: warm mispredict directly drove frontend redirect");
                    $fatal;
                end

                await_not_taken_recovery = 1'b1;
            end
        end

        if (!reset && await_not_taken_recovery && dut.ControlRedirectPending) begin
            if (!dut.redirect_taken || (dut.redirect_pc !== 32'd12)) begin
                $display("FAIL: registered warm not-taken recovery did not redirect to PC+4");
                $fatal;
            end
            await_not_taken_recovery = 1'b0;
            saw_not_taken_recovery = 1'b1;
        end
    end

    initial begin
        $dumpfile("wave/tb_branch_predictor_warm_recovery.vcd");
        $dumpvars(0, tb_branch_predictor_warm_recovery);
        correct_taken_predictions = 0;
        saw_not_taken_recovery = 1'b0;
        await_not_taken_recovery = 1'b0;
        branch_miss_at_first_correct_prediction = 32'h0;
        reset_cpu();

        dut.IMemory[0] = i_type(12'd9, 5'd0, 3'b000, 5'd1, 7'b0010011);        // addi x1, x0, 9
        dut.IMemory[1] = i_type(12'hfff, 5'd1, 3'b000, 5'd1, 7'b0010011);      // loop: addi x1, x1, -1
        dut.IMemory[2] = b_type(-4, 5'd0, 5'd1, 3'b001, 7'b1100011);           // bne x1, x0, loop
        dut.IMemory[3] = i_type(12'd55, 5'd0, 3'b000, 5'd5, 7'b0010011);       // recovery path
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);            // halt

        run_cycles(260);

        check_reg(1, 32'd0);
        check_reg(5, 32'd55);

        if (correct_taken_predictions < 2) begin
            $display("FAIL: expected at least two natural warm correct taken predictions, got %0d",
                     correct_taken_predictions);
            $fatal;
        end

        if (!saw_not_taken_recovery) begin
            $display("FAIL: did not observe natural warm predicted-taken/actual-not-taken recovery");
            $fatal;
        end

        $display("PASS: natural warm predictor recovery redirected to PC+4 and kept stable hits clean");
        $display("PASS: tb_branch_predictor_warm_recovery passed");
        $finish;
    end

endmodule
