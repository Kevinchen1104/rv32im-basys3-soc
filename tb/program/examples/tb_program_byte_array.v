`timescale 1ns / 1ps

// Testbench: tb_program_byte_array
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Lbu pointer loop over packed byte data.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/byte_array_sum.hex

module tb_program_byte_array;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_program_byte_array.vcd");
        $dumpvars(0, tb_program_byte_array);
        reset_cpu();

        $readmemh("firmware/hex/examples/byte_array_sum.hex", dut.IMemory, 0, 15);
        $readmemh("firmware/hex/examples/byte_array_sum.hex", dut.DMemory, 0, 15);
        dut.DMemory[31] = 32'hbead_cafe;  // address 124 evicts result block

        run_cycles(400);

        check_reg(5, 32'd60);          // t0 advanced across four bytes
        check_reg(6, 32'd0);           // t1 loop counter exhausted
        check_reg(10, 32'd10);         // a0 = 1 + 2 + 3 + 4
        check_reg(28, 32'd60);         // t3 = &result
        check_reg(8, 32'hbead_cafe);   // s0

        if (dut.DMemory[15] !== 32'd10) begin
            $display("FAIL: byte array sum expected DMemory[15] = %h, got %h",
                     32'd10, dut.DMemory[15]);
            $fatal;
        end

        $display("PASS: lbu pointer loop summed packed byte data and stored result = 10");
        $display("PASS: tb_program_byte_array passed");
        $finish;
    end

endmodule
