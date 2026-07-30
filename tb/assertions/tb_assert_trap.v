`timescale 1ns / 1ps

// Testbench: tb_assert_trap
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: Ecall trap redirect state and post-trap wrong-path register write suppression.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Focused machine-mode trap slice; not a full privileged architecture test.
// Assertion focus: Directed check for trap behavior or side-effect suppression.

module tb_assert_trap;

`include "tb_common.vh"

    localparam ECALL = 32'h00000073;

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            (dut.MEMWBPC == 32'd12)) begin
            $display(
                "FAIL: post-trap wrong-path instruction at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_trap.vcd");
        $dumpvars(0, tb_assert_trap);
        reset_cpu();

        dut.IMemory[0] = i_type(12'd16, 5'd0, 3'b000, 5'd5, 7'b0010011);  // x5 = trap handler PC
        dut.IMemory[1] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011); // csrrw x0, mtvec, x5
        dut.IMemory[2] = ECALL;
        dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);  // wrong path
        dut.IMemory[4] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);  // trap handler
        dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(160);

        if (dut.CSRmtvec !== 32'd16) begin
            $display("FAIL: mtvec expected 00000010, got %h", dut.CSRmtvec);
            $fatal;
        end
        if (dut.CSRmepc !== 32'd8 || dut.CSRmcause !== 32'd11) begin
            $display("FAIL: trap state mepc=%h mcause=%h", dut.CSRmepc, dut.CSRmcause);
            $fatal;
        end

        check_reg(5, 32'd16);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        $display("PASS: tb_assert_trap passed");
        $finish;
    end

endmodule
