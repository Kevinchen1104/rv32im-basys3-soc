`timescale 1ns / 1ps

// Testbench: tb_branch_prediction
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Warmed taken branches use BHT/BTB prediction without another redirect flush.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_branch_prediction;

`include "tb_common.vh"

    integer correct_taken_predictions;
    reg [31:0] branch_miss_at_first_correct_prediction;

    always @(posedge clock) begin
        if (!reset &&
            dut.IDEXValid &&
            dut.IDEXBranch &&
            (dut.IDEXPC == 32'd8) &&
            dut.branch_taken &&
            dut.IDEXPredTaken &&
            (dut.IDEXPredPC == dut.branch_target)) begin

            if (dut.branch_mispredict !== 1'b0) begin
                $display("FAIL: correctly predicted taken branch reported a mispredict");
                $fatal;
            end

            if (dut.redirect_taken !== 1'b0) begin
                $display("FAIL: correctly predicted taken branch triggered redirect/flush");
                $fatal;
            end

            if (correct_taken_predictions == 0) begin
                branch_miss_at_first_correct_prediction = dut.BranchMissCount;
            end else if (dut.BranchMissCount !== branch_miss_at_first_correct_prediction) begin
                $display("FAIL: branch miss count changed after warm correctly predicted taken branches");
                $fatal;
            end

            correct_taken_predictions = correct_taken_predictions + 1;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_branch_prediction.vcd");
        $dumpvars(0, tb_branch_prediction);
        correct_taken_predictions = 0;
        branch_miss_at_first_correct_prediction = 32'h0;
        reset_cpu();

        dut.IMemory[0] = i_type(12'd9, 5'd0, 3'b000, 5'd1, 7'b0010011);        // addi x1, x0, 9
        dut.IMemory[1] = i_type(12'hfff, 5'd1, 3'b000, 5'd1, 7'b0010011);      // loop: addi x1, x1, -1
        dut.IMemory[2] = b_type(-4, 5'd0, 5'd1, 3'b001, 7'b1100011);           // bne x1, x0, loop
        dut.IMemory[3] = i_type(12'd77, 5'd0, 3'b000, 5'd5, 7'b0010011);       // done
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);            // halt

        run_cycles(260);

        check_reg(1, 32'd0);
        check_reg(5, 32'd77);

        if (correct_taken_predictions < 2) begin
            $display("FAIL: expected at least two warm correctly predicted taken branches, got %0d",
                     correct_taken_predictions);
            $fatal;
        end

        $display("PASS: warm taken branches predicted without redirect/flush");
        $display("PASS: tb_branch_prediction passed");
        $finish;
    end

endmodule
