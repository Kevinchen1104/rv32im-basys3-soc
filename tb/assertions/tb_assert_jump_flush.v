`timescale 1ns / 1ps

// Testbench: tb_assert_jump_flush
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: Jal redirect links PC+4, reaches the target, and suppresses younger wrong-path writeback.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: JAL directed slice only; JALR is separate.
// Assertion focus: Directed check for jump flush behavior or side-effect suppression.

module tb_assert_jump_flush;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            ((dut.MEMWBPC == 32'd4) || (dut.MEMWBPC == 32'd8))) begin
            $display(
                "FAIL: post-jump wrong-path instruction at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_jump_flush.vcd");
        $dumpvars(0, tb_assert_jump_flush);
        reset_cpu();

        dut.IMemory[0] = j_type(12, 5'd1, 7'b1101111);                    // jal x1, target
        dut.IMemory[1] = i_type(12'd55, 5'd0, 3'b000, 5'd5, 7'b0010011);  // wrong path
        dut.IMemory[2] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);  // wrong path
        dut.IMemory[3] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);  // jump target
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(140);

        check_reg(1, 32'd4);
        check_reg(5, 32'd5);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        $display("PASS: tb_assert_jump_flush passed");
        $finish;
    end

endmodule
