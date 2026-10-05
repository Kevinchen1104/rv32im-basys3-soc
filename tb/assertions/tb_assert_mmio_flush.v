`timescale 1ns / 1ps

// Checks: A branch-flushed wrong-path GPIO MMIO store does not reach MEM and does not change external GPIO state.

module tb_assert_mmio_flush;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            (dut.EXMEMPC == 32'd4)) begin
            $display("FAIL: wrong-path MMIO store at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_mmio_flush.vcd");
        $dumpvars(0, tb_assert_mmio_flush);
        reset_cpu();

        dut.IMemory[0] = b_type(12, 5'd0, 5'd0, 3'b000, 7'b1100011);       // beq taken to PC 12
        dut.IMemory[1] = s_type(12'h200, 5'd2, 5'd0, 3'b010, 7'b0100011);  // wrong-path sw x2, GPIO output
        dut.IMemory[2] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);   // wrong-path register write
        dut.IMemory[3] = i_type(12'd44, 5'd0, 3'b000, 5'd4, 7'b0010011);   // branch target
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(140);

        if (dut.GPIOOutput !== 32'h0 || gpio_outputs !== 32'h0) begin
            $display(
                "FAIL: wrong-path MMIO store changed GPIOOutput=%h gpio_outputs=%h",
                dut.GPIOOutput,
                gpio_outputs
            );
            $fatal;
        end

        check_reg(4, 32'd44);
        check_reg(6, 32'd6);
        $display("PASS: GPIO output remained %h", gpio_outputs);
        $display("PASS: tb_assert_mmio_flush passed");
        $finish;
    end

endmodule
