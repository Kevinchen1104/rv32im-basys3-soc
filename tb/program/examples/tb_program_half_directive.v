`timescale 1ns / 1ps

// Testbench: tb_program_half_directive
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: .half data, .align padding, and aligned loaded sum behavior.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/half_directive_sum.hex

module tb_program_half_directive;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_half_directive.vcd");
        $dumpvars(0, tb_program_half_directive);
        reset_cpu();

        $readmemh("firmware/hex/examples/half_directive_sum.hex", dut.IMemory, 0, 16);
        $readmemh("firmware/hex/examples/half_directive_sum.hex", dut.DMemory, 0, 16);
        dut.DMemory[32] = 32'h16b1_cafe;  // address 128 evicts result block

        run_cycles(400);

        check_reg(5, 32'd62);          // t0 advanced across three halfwords
        check_reg(6, 32'd0);           // t1 loop counter exhausted
        check_reg(10, 32'h0001_8000);  // a0 = 1 + 65535 + 32768
        check_reg(28, 32'd64);         // t3 = aligned &result
        check_reg(8, 32'h16b1_cafe);   // s0

        if (dut.DMemory[16] !== 32'h0001_8000) begin
            $display("FAIL: half directive sum expected DMemory[16] = %h, got %h",
                     32'h0001_8000, dut.DMemory[16]);
            $fatal;
        end

        $display("PASS: .half data and .align padding produced an aligned stored sum");
        $display("PASS: tb_program_half_directive passed");
        $finish;
    end

endmodule
