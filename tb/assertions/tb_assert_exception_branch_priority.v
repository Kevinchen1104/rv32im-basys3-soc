`timescale 1ns / 1ps

// Testbench: tb_assert_exception_branch_priority
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: An ecall trap redirects to mtvec and wins over a younger JAL path, including suppression of branch-target,
//   fall-through, data-memory, and GPIO MMIO wrong-path markers.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Directed exception-versus-jump priority slice only; does not cover every exception source, branch
//   type, interrupt, or cache-stall interaction.
// Assertion focus: Directed check for exception branch priority behavior or side-effect suppression.

module tb_assert_exception_branch_priority;

`include "tb_common.vh"

    localparam ECALL = 32'h00000073;

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            ((dut.MEMWBPC == 32'd16) ||
             (dut.MEMWBPC == 32'd20) ||
             (dut.MEMWBPC == 32'd32))) begin
            $display(
                "FAIL: wrong-path register write at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end

        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == 32'd24) || (dut.EXMEMPC == 32'd28))) begin
            $display("FAIL: wrong-path side-effect at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_exception_branch_priority.vcd");
        $dumpvars(0, tb_assert_exception_branch_priority);
        reset_cpu();

        dut.DMemory[0] = 32'h1234_abcd;
        dut.IMemory[0] = i_type(12'd55, 5'd0, 3'b000, 5'd2, 7'b0010011);   // x2 = side-effect data
        dut.IMemory[1] = i_type(12'd44, 5'd0, 3'b000, 5'd5, 7'b0010011);   // x5 = trap handler PC
        dut.IMemory[2] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011);  // csrrw x0, mtvec, x5
        dut.IMemory[3] = ECALL;                                             // trap at PC 12
        dut.IMemory[4] = j_type(16, 5'd1, 7'b1101111);                      // wrong-path jal x1, PC 32
        dut.IMemory[5] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);    // fall-through wrong-path marker
        dut.IMemory[6] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);     // wrong-path sw x2, 0(x0)
        dut.IMemory[7] = s_type(12'h200, 5'd2, 5'd0, 3'b010, 7'b0100011);   // wrong-path sw x2, GPIO output
        dut.IMemory[8] = i_type(12'd88, 5'd0, 3'b000, 5'd8, 7'b0010011);    // wrong-path jump target marker
        dut.IMemory[9] = i_type(12'd99, 5'd0, 3'b000, 5'd9, 7'b0010011);    // extra wrong-path target marker
        dut.IMemory[11] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);   // trap handler marker
        dut.IMemory[12] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);        // hold final state

        checking_enabled = 1'b1;
        run_cycles(220);

        if (dut.CSRmtvec !== 32'd44) begin
            $display("FAIL: mtvec expected 0000002c, got %h", dut.CSRmtvec);
            $fatal;
        end
        if (dut.CSRmepc !== 32'd12 || dut.CSRmcause !== 32'd11) begin
            $display("FAIL: trap state mepc=%h mcause=%h", dut.CSRmepc, dut.CSRmcause);
            $fatal;
        end
        if (dut.DMemory[0] !== 32'h1234_abcd) begin
            $display("FAIL: wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end
        if (dut.GPIOOutput !== 32'h0 || gpio_outputs !== 32'h0) begin
            $display(
                "FAIL: wrong-path MMIO changed GPIOOutput=%h gpio_outputs=%h",
                dut.GPIOOutput,
                gpio_outputs
            );
            $fatal;
        end

        check_reg(1, 32'd1);
        check_reg(2, 32'd55);
        check_reg(5, 32'd44);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        check_reg(8, 32'd8);
        check_reg(9, 32'd9);
        $display("PASS: exception redirect took priority over younger jump path");
        $display("PASS: wrong-path branch/jump target, fall-through, memory, and MMIO markers were suppressed");
        $display("PASS: tb_assert_exception_branch_priority passed");
        $finish;
    end

endmodule
