`timescale 1ns / 1ps

// Checks: Jalr clears target bit 0, writes the link value, and suppresses younger wrong-path writeback.
// JALR store and MMIO side effects are checked by tb_assert_jalr_side_effect_flush.

module tb_assert_jalr_flush;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            ((dut.MEMWBPC == 32'd8) || (dut.MEMWBPC == 32'd12))) begin
            $display(
                "FAIL: post-jalr wrong-path instruction at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_jalr_flush.vcd");
        $dumpvars(0, tb_assert_jalr_flush);
        reset_cpu();

        dut.IMemory[0] = i_type(12'd17, 5'd0, 3'b000, 5'd5, 7'b0010011);  // x5 = odd target
        dut.IMemory[1] = i_type(12'd0, 5'd5, 3'b000, 5'd1, 7'b1100111);   // jalr x1, 0(x5)
        dut.IMemory[2] = i_type(12'd55, 5'd0, 3'b000, 5'd6, 7'b0010011);  // wrong path
        dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd7, 7'b0010011);  // wrong path
        dut.IMemory[4] = i_type(12'd88, 5'd0, 3'b000, 5'd8, 7'b0010011);  // aligned target
        dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(160);

        check_reg(1, 32'd8);
        check_reg(5, 32'd17);
        check_reg(6, 32'd6);
        check_reg(7, 32'd7);
        check_reg(8, 32'd88);
        $display("PASS: tb_assert_jalr_flush passed");
        $finish;
    end

endmodule
