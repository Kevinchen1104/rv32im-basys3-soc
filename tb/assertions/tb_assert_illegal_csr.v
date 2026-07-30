`timescale 1ns / 1ps

// Testbench: tb_assert_illegal_csr
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: Invalid CSR access traps with mcause/mepc state and suppresses destination writeback and wrong-path
//   execution.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Invalid CSR negative test only; not all CSR privilege rules are implemented.
// Assertion focus: Directed check for illegal csr behavior or side-effect suppression.

module tb_assert_illegal_csr;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            (dut.MEMWBPC == 32'd12)) begin
            $display(
                "FAIL: post-illegal-CSR wrong-path instruction at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_illegal_csr.vcd");
        $dumpvars(0, tb_assert_illegal_csr);
        reset_cpu();

        dut.IMemory[0] = i_type(12'd16, 5'd0, 3'b000, 5'd5, 7'b0010011);  // x5 = trap handler PC
        dut.IMemory[1] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011); // csrrw x0, mtvec, x5
        dut.IMemory[2] = i_type(12'h999, 5'd5, 3'b001, 5'd8, 7'b1110011); // invalid CSR address
        dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);  // wrong path
        dut.IMemory[4] = i_type(12'd55, 5'd0, 3'b000, 5'd7, 7'b0010011);  // trap handler
        dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(160);

        if (dut.CSRmtvec !== 32'd16) begin
            $display("FAIL: mtvec expected 00000010, got %h", dut.CSRmtvec);
            $fatal;
        end
        if (dut.CSRmepc !== 32'd8 || dut.CSRmcause !== 32'd2) begin
            $display("FAIL: illegal CSR trap state mepc=%h mcause=%h", dut.CSRmepc, dut.CSRmcause);
            $fatal;
        end

        check_reg(5, 32'd16);
        check_reg(6, 32'd6);
        check_reg(7, 32'd55);
        check_reg(8, 32'd8);
        $display("PASS: illegal CSR access trapped without wrong-path or destination writeback");
        $display("PASS: tb_assert_illegal_csr passed");
        $finish;
    end

endmodule
