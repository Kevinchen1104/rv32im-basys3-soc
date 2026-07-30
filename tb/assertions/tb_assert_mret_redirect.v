`timescale 1ns / 1ps

// Testbench: tb_assert_mret_redirect
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: Mret redirects to mepc and suppresses post-mret wrong-path register writes.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Focused mret redirect slice only; mstatus trap-return side effects are covered by separate
//   CSR/program tests and no full privilege stack is claimed.
// Assertion focus: Directed check for mret redirect behavior or side-effect suppression.

module tb_assert_mret_redirect;

`include "tb_common.vh"

    localparam MRET = 32'h30200073;

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            (dut.MEMWBPC == 32'd12)) begin
            $display(
                "FAIL: post-mret wrong-path instruction at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_mret_redirect.vcd");
        $dumpvars(0, tb_assert_mret_redirect);
        reset_cpu();

        dut.IMemory[0] = i_type(12'd20, 5'd0, 3'b000, 5'd5, 7'b0010011);  // x5 = return PC
        dut.IMemory[1] = i_type(12'h341, 5'd5, 3'b001, 5'd0, 7'b1110011); // csrrw x0, mepc, x5
        dut.IMemory[2] = MRET;
        dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);  // wrong path
        dut.IMemory[4] = i_type(12'd88, 5'd0, 3'b000, 5'd8, 7'b0010011);  // also wrong path
        dut.IMemory[5] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);  // mret target
        dut.IMemory[6] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(180);

        if (dut.CSRmepc !== 32'd20) begin
            $display("FAIL: mepc expected 00000014, got %h", dut.CSRmepc);
            $fatal;
        end

        check_reg(5, 32'd20);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        check_reg(8, 32'd8);
        $display("PASS: mret redirected to mepc and suppressed wrong-path writes");
        $display("PASS: tb_assert_mret_redirect passed");
        $finish;
    end

endmodule
