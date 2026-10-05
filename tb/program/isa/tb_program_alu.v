`timescale 1ns / 1ps

// Checks: Assembled register/immediate ALU operations across shifts, compares, and logic.
// Firmware: firmware/hex/examples/alu_ops.hex

module tb_program_alu;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_alu.vcd");
        $dumpvars(0, tb_program_alu);
        reset_cpu();

        $readmemh("firmware/hex/examples/alu_ops.hex", dut.IMemory, 0, 21);
        dut.DMemory[16] = 32'h55aa_aa55;

        run_cycles(320);

        check_reg(1, 32'hffff_fff0);
        check_reg(2, 32'd3);
        check_reg(3, 32'd19);
        check_reg(4, 32'd0);
        check_reg(5, 32'hffff_fff3);
        check_reg(6, 32'hffff_fff3);
        check_reg(7, 32'd24);
        check_reg(8, 32'h1fff_fffe);
        check_reg(9, 32'hffff_fffe);
        check_reg(10, 32'd1);
        check_reg(11, 32'd0);
        check_reg(12, 32'd1);
        check_reg(13, 32'd0);
        check_reg(14, 32'd6);
        check_reg(15, 32'd11);
        check_reg(16, 32'd3);
        check_reg(17, 32'd48);
        check_reg(18, 32'h0fff_ffff);
        check_reg(19, 32'hffff_ffff);
        check_reg(20, 32'h55aa_aa55);

        if (dut.DMemory[0] !== 32'd19) begin
            $display("FAIL: ALU result expected DMemory[0] = %h, got %h", 32'd19, dut.DMemory[0]);
            $fatal;
        end

        $display("PASS: loaded ALU program executed register and immediate operations");
        $display("PASS: tb_program_alu passed");
        $finish;
    end

endmodule
