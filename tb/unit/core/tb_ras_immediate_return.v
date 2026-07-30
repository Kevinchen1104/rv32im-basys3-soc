`timescale 1ns / 1ps

// Testbench: tb_ras_immediate_return
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Immediate return architectural correctness and final empty RAS state.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_ras_immediate_return;

`include "tb_common.vh"

    integer return_resolves;
    integer return_mispredicts;

    always @(posedge clock) begin
        if (!reset && dut.control_resolution_accept &&
            dut.IDEXValid &&
            (dut.IDEXop == 7'b1100111) &&
            (dut.IDEXrd == 5'd0) &&
            (dut.IDEXrs1 == 5'd1) &&
            (dut.IDEXIR[31:20] == 12'd0)) begin

            return_resolves = return_resolves + 1;

            if (dut.jump_mispredict) begin
                return_mispredicts = return_mispredicts + 1;
            end
        end
    end

    initial begin
        $dumpfile("wave/tb_ras_immediate_return.vcd");
        $dumpvars(0, tb_ras_immediate_return);
        return_resolves = 0;
        return_mispredicts = 0;
        reset_cpu();

        dut.IMemory[0] = j_type(16, 5'd1, 7'b1101111);                   // jal x1, function
        dut.IMemory[1] = i_type(12'd11, 5'd0, 3'b000, 5'd5, 7'b0010011); // returned path
        dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);      // halt
        dut.IMemory[4] = i_type(12'd0, 5'd1, 3'b000, 5'd0, 7'b1100111);  // function: ret immediately
        dut.IMemory[5] = i_type(12'd99, 5'd0, 3'b000, 5'd6, 7'b0010011); // wrong path

        run_cycles(160);

        check_reg(1, 32'd4);
        check_reg(5, 32'd11);
        check_reg(6, 32'd6);

        if (dut.RASCount !== 4'd0) begin
            $display("FAIL: RASCount expected 0, got %0d", dut.RASCount);
            $fatal;
        end

        if (return_resolves !== 1) begin
            $display("FAIL: expected one immediate return resolve, got %0d", return_resolves);
            $fatal;
        end

        if (return_mispredicts == 0) begin
            $display("INFO: immediate return was predicted by RAS");
        end else begin
            $display("INFO: immediate return corrected by jump_mispredict; RAS update is safe but not complete immediate-return prediction");
        end

        $display("PASS: immediate return executed correctly and left RAS empty");
        $display("PASS: tb_ras_immediate_return passed");
        $finish;
    end

endmodule
