`timescale 1ns / 1ps

// Testbench: tb_program_string_escape
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: .string escapes emit expected bytes and a terminator.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/string_escape_sum.hex

module tb_program_string_escape;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_program_string_escape.vcd");
        $dumpvars(0, tb_program_string_escape);
        reset_cpu();

        $readmemh("firmware/hex/examples/string_escape_sum.hex", dut.IMemory, 0, 17);
        $readmemh("firmware/hex/examples/string_escape_sum.hex", dut.DMemory, 0, 17);
        dut.DMemory[32] = 32'he5ca_cafe;  // address 128 evicts result block

        run_cycles(460);

        check_reg(5, 32'd67);          // t0 points at the appended terminator
        check_reg(6, 32'd0);           // t1 observed the terminator
        check_reg(8, 32'he5cacafe);    // s0
        check_reg(10, 32'd335);        // a0 = 'A' + '#' + newline + tab + '"' + '\' + 'Z'
        check_reg(11, 32'd7);          // a1 = escaped string length in bytes
        check_reg(28, 32'd68);         // t3 = &result

        if (dut.DMemory[17] !== 32'd335) begin
            $display("FAIL: escaped string sum expected DMemory[17] = %h, got %h",
                     32'd335, dut.DMemory[17]);
            $fatal;
        end

        $display("PASS: .string escapes emitted bytes and appended one terminator");
        $display("PASS: tb_program_string_escape passed");
        $finish;
    end

endmodule
