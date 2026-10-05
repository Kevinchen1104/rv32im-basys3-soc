`timescale 1ns / 1ps

// Checks: Mret redirect suppresses younger wrong-path data-memory and GPIO MMIO stores while the return target
//   executes.

module tb_assert_mret_side_effect_flush;

`include "tb_common.vh"

    localparam MRET = 32'h30200073;

    reg checking_enabled = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == 32'd16) || (dut.EXMEMPC == 32'd20))) begin
            $display("FAIL: post-mret wrong-path side-effect at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_mret_side_effect_flush.vcd");
        $dumpvars(0, tb_assert_mret_side_effect_flush);
        reset_cpu();

        dut.DMemory[0] = 32'h1234_abcd;
        dut.IMemory[0] = i_type(12'd55, 5'd0, 3'b000, 5'd2, 7'b0010011);   // x2 = side-effect data
        dut.IMemory[1] = i_type(12'd28, 5'd0, 3'b000, 5'd5, 7'b0010011);   // x5 = mret target PC
        dut.IMemory[2] = i_type(12'h341, 5'd5, 3'b001, 5'd0, 7'b1110011);  // csrrw x0, mepc, x5
        dut.IMemory[3] = MRET;                                             // redirect to mepc at PC 28
        dut.IMemory[4] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);     // wrong-path sw x2, 0(x0)
        dut.IMemory[5] = s_type(12'h200, 5'd2, 5'd0, 3'b010, 7'b0100011);   // wrong-path sw x2, GPIO output
        dut.IMemory[6] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);    // wrong-path register write
        dut.IMemory[7] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);    // mret target
        dut.IMemory[8] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(200);

        if (dut.CSRmepc !== 32'd28) begin
            $display("FAIL: mepc expected 0000001c, got %h", dut.CSRmepc);
            $fatal;
        end
        if (dut.DMemory[0] !== 32'h1234_abcd) begin
            $display("FAIL: post-mret wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end
        if (dut.GPIOOutput !== 32'h0 || gpio_outputs !== 32'h0) begin
            $display(
                "FAIL: post-mret wrong-path MMIO changed GPIOOutput=%h gpio_outputs=%h",
                dut.GPIOOutput,
                gpio_outputs
            );
            $fatal;
        end

        check_reg(2, 32'd55);
        check_reg(5, 32'd28);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        $display("PASS: mret redirect suppressed younger memory and MMIO side effects");
        $display("PASS: tb_assert_mret_side_effect_flush passed");
        $finish;
    end

endmodule
