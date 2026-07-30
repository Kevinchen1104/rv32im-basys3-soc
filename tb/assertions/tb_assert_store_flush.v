`timescale 1ns / 1ps

// Testbench: tb_assert_store_flush
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: A branch-flushed wrong-path store does not reach MEM and does not modify data memory.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Directed branch store side-effect case only.
// Assertion focus: Directed check for store flush behavior or side-effect suppression.

module tb_assert_store_flush;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    // Catch the forbidden store at MEM-stage entry before the final memory-value check.
    always @(posedge clock) begin
        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            (dut.EXMEMPC == 32'd4)) begin
            $display("FAIL: wrong-path store at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_store_flush.vcd");
        $dumpvars(0, tb_assert_store_flush);
        reset_cpu();

        dut.DMemory[0] = 32'h1234_abcd;
        dut.IMemory[0] = b_type(12, 5'd0, 5'd0, 3'b000, 7'b1100011);      // beq taken to PC 12
        // These two instructions are deliberately on the flushed path.
        dut.IMemory[1] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);   // wrong-path sw x2, 0(x0)
        dut.IMemory[2] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);  // wrong-path register write
        dut.IMemory[3] = i_type(12'd44, 5'd0, 3'b000, 5'd4, 7'b0010011);  // branch target
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(140);

        if (dut.DMemory[0] !== 32'h1234_abcd) begin
            $display("FAIL: wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end

        check_reg(4, 32'd44);
        check_reg(6, 32'd6);
        $display("PASS: DMemory[0] remained %h", dut.DMemory[0]);
        $display("PASS: tb_assert_store_flush passed");
        $finish;
    end

endmodule
