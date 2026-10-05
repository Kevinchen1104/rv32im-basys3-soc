`timescale 1ns / 1ps

// Testbench: tb_program_li
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Expanded li pseudo-instructions load full-width constants and preserve label targets.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/li_constants.hex

module tb_program_li;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_li.vcd");
        $dumpvars(0, tb_program_li);
        reset_cpu();

        $readmemh("firmware/hex/examples/li_constants.hex", dut.IMemory, 0, 10);
        dut.DMemory[16] = 32'h0bad_f00d;

        run_cycles(300);

        check_reg(5, 32'h1234_5678);   // t0
        check_reg(6, 32'h89ab_cdef);   // t1
        check_reg(7, 32'd7);           // t2, wrong path was flushed
        check_reg(8, 32'h0bad_f00d);   // s0
        check_reg(10, 32'h1234_5678);  // a0

        if (dut.DMemory[0] !== 32'h89ab_cdef) begin
            $display("FAIL: full-width li result expected DMemory[0] = %h, got %h",
                     32'h89ab_cdef, dut.DMemory[0]);
            $fatal;
        end

        $display("PASS: expanded li pseudos loaded full-width values and preserved label targets");
        $display("PASS: tb_program_li passed");
        $finish;
    end

endmodule
