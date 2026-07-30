`timescale 1ns / 1ps

// Testbench: tb_branch
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Branch decisions and unsigned branch behavior through architectural results.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_branch;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_branch.vcd");
        $dumpvars(0, tb_branch);
        reset_cpu();

        dut.DMemory[0] = 32'd42;
        dut.IMemory[0]  = i_type(12'd0, 5'd0, 3'b010, 5'd1, 7'b0000011);  // lw x1, 0(x0)
        dut.IMemory[1]  = i_type(12'd42, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 42
        dut.IMemory[2]  = NOP;
        dut.IMemory[3]  = b_type(8, 5'd2, 5'd1, 3'b000, 7'b1100011);  // beq taken
        dut.IMemory[4]  = i_type(12'd77, 5'd0, 3'b000, 5'd3, 7'b0010011);  // skipped
        dut.IMemory[5]  = i_type(12'hfff, 5'd0, 3'b000, 5'd4, 7'b0010011);  // x4 = -1
        dut.IMemory[6]  = i_type(12'd1, 5'd0, 3'b000, 5'd5, 7'b0010011);  // x5 = 1
        dut.IMemory[7]  = NOP;
        dut.IMemory[8]  = b_type(8, 5'd5, 5'd4, 3'b111, 7'b1100011);  // bgeu taken
        dut.IMemory[9]  = i_type(12'd88, 5'd0, 3'b000, 5'd6, 7'b0010011);  // skipped
        dut.IMemory[10] = i_type(12'd99, 5'd0, 3'b000, 5'd7, 7'b0010011);
        dut.IMemory[11] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        run_cycles(180);

        check_reg(1, 32'd42);
        check_reg(2, 32'd42);
        check_reg(3, 32'd3);
        check_reg(6, 32'd6);
        check_reg(7, 32'd99);
        $display("PASS: tb_branch passed");
        $finish;
    end

endmodule
