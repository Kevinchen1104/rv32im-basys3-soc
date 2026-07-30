`timescale 1ns / 1ps

// Testbench: tb_program_string
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Zero-terminated string data scanning in an assembled program.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/string_sum.hex

module tb_program_string;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_program_string.vcd");
        $dumpvars(0, tb_program_string);
        reset_cpu();

        $readmemh("firmware/hex/examples/string_sum.hex", dut.IMemory, 0, 16);
        $readmemh("firmware/hex/examples/string_sum.hex", dut.DMemory, 0, 16);
        dut.DMemory[32] = 32'h57a1_cafe;  // address 128 evicts result block

        run_cycles(420);

        check_reg(5, 32'd63);          // t0 points at the zero terminator
        check_reg(6, 32'd0);           // t1 observed the terminator
        check_reg(10, 32'd232);        // a0 = 'C' + 'P' + 'U'
        check_reg(11, 32'd3);          // a1 = string length
        check_reg(28, 32'd64);         // t3 = &result
        check_reg(8, 32'h57a1_cafe);   // s0

        if (dut.DMemory[16] !== 32'd232) begin
            $display("FAIL: string sum expected DMemory[16] = %h, got %h",
                     32'd232, dut.DMemory[16]);
            $fatal;
        end

        $display("PASS: zero-terminated byte scan found length 3 and ASCII sum = 232");
        $display("PASS: tb_program_string passed");
        $finish;
    end

endmodule
