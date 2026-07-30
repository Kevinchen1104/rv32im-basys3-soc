`timescale 1ns / 1ps

// Testbench: tb_jump_ras
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Jump and return-address-stack call/return behavior.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_jump_ras;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_jump_ras.vcd");
        $dumpvars(0, tb_jump_ras);
        reset_cpu();

        dut.IMemory[0] = j_type(16, 5'd1, 7'b1101111);  // jal x1, func
        dut.IMemory[1] = i_type(12'd22, 5'd0, 3'b000, 5'd3, 7'b0010011);  // returned path
        dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);
        dut.IMemory[3] = NOP;
        dut.IMemory[4] = i_type(12'd11, 5'd0, 3'b000, 5'd2, 7'b0010011);  // func body
        dut.IMemory[5] = i_type(12'd0, 5'd1, 3'b000, 5'd0, 7'b1100111);  // jalr x0, 0(x1)
        dut.IMemory[6] = i_type(12'd66, 5'd0, 3'b000, 5'd4, 7'b0010011);  // wrong path

        run_cycles(140);

        check_reg(1, 32'd4);
        check_reg(2, 32'd11);
        check_reg(3, 32'd22);
        check_reg(4, 32'd4);

        if (dut.RASCount !== 4'd0) begin
            $display("FAIL: RASCount expected 0, got %0d", dut.RASCount);
            $fatal;
        end
        $display("PASS: tb_jump_ras passed");
        $finish;
    end

endmodule
