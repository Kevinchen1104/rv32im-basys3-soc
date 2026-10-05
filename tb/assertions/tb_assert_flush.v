`timescale 1ns / 1ps

// Checks: Taken-branch redirect suppresses younger wrong-path register writeback.
// Memory and MMIO side effects are checked by the store/MMIO flush tests.

module tb_assert_flush;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            ((dut.MEMWBPC == 32'd4) || (dut.MEMWBPC == 32'd8))) begin
            $display(
                "FAIL: wrong-path instruction at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_flush.vcd");
        $dumpvars(0, tb_assert_flush);
        reset_cpu();

        dut.IMemory[0] = b_type(12, 5'd0, 5'd0, 3'b000, 7'b1100011);       // beq taken to PC 12
        dut.IMemory[1] = i_type(12'd55, 5'd0, 3'b000, 5'd5, 7'b0010011);   // wrong path
        dut.IMemory[2] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);   // wrong path
        dut.IMemory[3] = i_type(12'd44, 5'd0, 3'b000, 5'd4, 7'b0010011);   // branch target
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(120);

        check_reg(4, 32'd44);
        check_reg(5, 32'd5);
        check_reg(6, 32'd6);
        $display("PASS: tb_assert_flush passed");
        $finish;
    end

endmodule
