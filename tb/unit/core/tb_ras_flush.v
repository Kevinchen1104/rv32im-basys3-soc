`timescale 1ns / 1ps

// Testbench: tb_ras_flush
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Wrong-path call/return fetches do not permanently pollute RAS state.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_ras_flush;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_ras_flush.vcd");
        $dumpvars(0, tb_ras_flush);
        reset_cpu();

        dut.IMemory[0] = b_type(12, 5'd0, 5'd0, 3'b000, 7'b1100011);      // beq taken to target
        dut.IMemory[1] = j_type(16, 5'd1, 7'b1101111);                   // wrong-path call, must flush
        dut.IMemory[2] = i_type(12'd0, 5'd1, 3'b000, 5'd0, 7'b1100111);  // wrong-path return, must flush
        dut.IMemory[3] = i_type(12'd11, 5'd0, 3'b000, 5'd5, 7'b0010011); // target
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);      // halt
        dut.IMemory[5] = i_type(12'd99, 5'd0, 3'b000, 5'd6, 7'b0010011); // wrong call target

        run_cycles(160);

        check_reg(5, 32'd11);
        check_reg(6, 32'd6);

        if (dut.RASCount !== 4'd0) begin
            $display("FAIL: wrong-path call/return polluted RASCount, got %0d", dut.RASCount);
            $fatal;
        end

        if (dut.Regs[1] !== 32'd1) begin
            $display("FAIL: wrong-path call wrote x1 = %h", dut.Regs[1]);
            $fatal;
        end

        $display("PASS: wrong-path call/return did not pollute RAS");
        $display("PASS: tb_ras_flush passed");
        $finish;
    end

endmodule
