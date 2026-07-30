`timescale 1ns / 1ps

// Testbench: tb_assert_jump_side_effect_flush
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: Jal redirect suppresses younger wrong-path data-memory and GPIO MMIO stores while the target path executes.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Directed JAL side-effect case only; does not cover all indirect redirects.
// Assertion focus: Directed check for jump side effect flush behavior or side-effect suppression.

module tb_assert_jump_side_effect_flush;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == 32'd8) || (dut.EXMEMPC == 32'd12))) begin
            $display("FAIL: post-jump wrong-path side-effect at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_jump_side_effect_flush.vcd");
        $dumpvars(0, tb_assert_jump_side_effect_flush);
        reset_cpu();

        dut.DMemory[0] = 32'h1234_abcd;
        dut.IMemory[0] = i_type(12'd55, 5'd0, 3'b000, 5'd2, 7'b0010011);   // x2 = side-effect data
        dut.IMemory[1] = j_type(20, 5'd1, 7'b1101111);                     // jal x1, target PC 24
        dut.IMemory[2] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);     // wrong-path sw x2, 0(x0)
        dut.IMemory[3] = s_type(12'h200, 5'd2, 5'd0, 3'b010, 7'b0100011);   // wrong-path sw x2, GPIO output
        dut.IMemory[4] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);    // wrong-path register write
        dut.IMemory[5] = i_type(12'd88, 5'd0, 3'b000, 5'd8, 7'b0010011);    // also wrong path
        dut.IMemory[6] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);    // jump target
        dut.IMemory[7] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(200);

        if (dut.DMemory[0] !== 32'h1234_abcd) begin
            $display("FAIL: post-jump wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end
        if (dut.GPIOOutput !== 32'h0 || gpio_outputs !== 32'h0) begin
            $display(
                "FAIL: post-jump wrong-path MMIO changed GPIOOutput=%h gpio_outputs=%h",
                dut.GPIOOutput,
                gpio_outputs
            );
            $fatal;
        end

        check_reg(1, 32'd8);
        check_reg(2, 32'd55);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        check_reg(8, 32'd8);
        $display("PASS: jump redirect suppressed younger memory and MMIO side effects");
        $display("PASS: tb_assert_jump_side_effect_flush passed");
        $finish;
    end

endmodule
