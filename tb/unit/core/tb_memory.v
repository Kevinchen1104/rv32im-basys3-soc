`timescale 1ns / 1ps

// Testbench: tb_memory
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Word, byte, and halfword load/store behavior plus load-use memory interaction.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_memory;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_memory.vcd");
        $dumpvars(0, tb_memory);
        reset_cpu();

        dut.DMemory[0] = 32'h80ff_7f01;
        dut.DMemory[1] = 32'h1234_5678;
        dut.DMemory[2] = 32'h1122_3344;

        dut.IMemory[0]  = i_type(12'd2, 5'd0, 3'b000, 5'd10, 7'b0010011);  // addi x10, x0, 2
        dut.IMemory[1]  = i_type(12'd2, 5'd0, 3'b000, 5'd1, 7'b0000011);  // lb x1, 2(x0)
        dut.IMemory[2]  = i_type(12'd2, 5'd0, 3'b100, 5'd2, 7'b0000011);  // lbu x2, 2(x0)
        dut.IMemory[3]  = i_type(12'd2, 5'd0, 3'b001, 5'd3, 7'b0000011);  // lh x3, 2(x0)
        dut.IMemory[4]  = i_type(12'd2, 5'd0, 3'b101, 5'd4, 7'b0000011);  // lhu x4, 2(x0)
        dut.IMemory[5]  = s_type(12'd5, 5'd10, 5'd0, 3'b000, 7'b0100011);  // sb x10, 5(x0)
        dut.IMemory[6]  = i_type(12'd4, 5'd0, 3'b010, 5'd5, 7'b0000011);  // lw x5, 4(x0)
        dut.IMemory[7]  = s_type(12'd8, 5'd10, 5'd0, 3'b001, 7'b0100011);  // sh x10, 8(x0)
        dut.IMemory[8]  = i_type(12'd8, 5'd0, 3'b010, 5'd6, 7'b0000011);  // lw x6, 8(x0)
        dut.IMemory[9]  = i_type(12'd7, 5'd6, 3'b000, 5'd7, 7'b0010011);  // load-use addi
        dut.IMemory[10] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        run_cycles(190);

        check_reg(1, 32'hffff_ffff);
        check_reg(2, 32'h0000_00ff);
        check_reg(3, 32'hffff_80ff);
        check_reg(4, 32'h0000_80ff);
        check_reg(5, 32'h1234_0278);
        check_reg(6, 32'h1122_0002);
        check_reg(7, 32'h1122_0009);
        $display("PASS: tb_memory passed");
        $finish;
    end

endmodule
