`timescale 1ns / 1ps

// Testbench: tb_program
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: An assembled sum program executes and stores the expected architectural result.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/sum.hex

module tb_program;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program.vcd");
        $dumpvars(0, tb_program);
        reset_cpu();

        $readmemh("firmware/hex/examples/sum.hex", dut.IMemory, 0, 8);
        dut.DMemory[16] = 32'hcafe_babe;  // address 64, same D-cache index as address 0

        run_cycles(300);

        check_reg(1, 32'd11);
        check_reg(2, 32'd55);
        check_reg(4, 32'hcafe_babe);

        if (dut.DMemory[0] !== 32'd55) begin
            $display("FAIL: program result expected DMemory[0] = %h, got %h", 32'd55, dut.DMemory[0]);
            $fatal;
        end

        $display("PASS: loaded program stored sum = %0d", dut.DMemory[0]);
        $display("PASS: tb_program passed");
        $finish;
    end

endmodule
