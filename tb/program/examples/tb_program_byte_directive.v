`timescale 1ns / 1ps

// Testbench: tb_program_byte_directive
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: .byte data, .align padding, and aligned loaded sum behavior.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/byte_directive_sum.hex

module tb_program_byte_directive;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_byte_directive.vcd");
        $dumpvars(0, tb_program_byte_directive);
        reset_cpu();

        $readmemh("firmware/hex/examples/byte_directive_sum.hex", dut.IMemory, 0, 15);
        $readmemh("firmware/hex/examples/byte_directive_sum.hex", dut.DMemory, 0, 15);
        dut.DMemory[31] = 32'hb17e_cafe;  // address 124 evicts result block

        run_cycles(400);

        check_reg(5, 32'd59);          // t0 advanced across three bytes
        check_reg(6, 32'd0);           // t1 loop counter exhausted
        check_reg(10, 32'd258);        // a0 = 1 + 2 + 255
        check_reg(28, 32'd60);         // t3 = aligned &result
        check_reg(8, 32'hb17e_cafe);   // s0

        if (dut.DMemory[15] !== 32'd258) begin
            $display("FAIL: byte directive sum expected DMemory[15] = %h, got %h",
                     32'd258, dut.DMemory[15]);
            $fatal;
        end

        $display("PASS: .byte data and .align padding produced an aligned stored sum = 258");
        $display("PASS: tb_program_byte_directive passed");
        $finish;
    end

endmodule
