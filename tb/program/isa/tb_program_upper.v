`timescale 1ns / 1ps

// Checks: Upper-immediate constants and signed branch selections in an assembled program.
// Firmware: firmware/hex/examples/upper_branch.hex

module tb_program_upper;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_upper.vcd");
        $dumpvars(0, tb_program_upper);
        reset_cpu();

        $readmemh("firmware/hex/examples/upper_branch.hex", dut.IMemory, 0, 14);
        dut.DMemory[16] = 32'h2468_ace0;

        run_cycles(300);

        check_reg(1, 32'h1234_5067);
        check_reg(2, 32'h0000_1008);
        check_reg(3, 32'hffff_ffff);
        check_reg(4, 32'd44);
        check_reg(5, 32'd5);
        check_reg(6, 32'd6);
        check_reg(7, 32'h2468_ace0);

        if (dut.DMemory[0] !== 32'h1234_5067) begin
            $display("FAIL: upper-immediate result expected DMemory[0] = %h, got %h",
                     32'h1234_5067, dut.DMemory[0]);
            $fatal;
        end

        $display("PASS: loaded upper-immediate program constructed constants and selected signed branches");
        $display("PASS: tb_program_upper passed");
        $finish;
    end

endmodule
