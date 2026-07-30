`timescale 1ns / 1ps

// Testbench: tb_program_array
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Pointer loop over .word data and stored sum result.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/array_sum.hex

module tb_program_array;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_program_array.vcd");
        $dumpvars(0, tb_program_array);
        reset_cpu();

        $readmemh("firmware/hex/examples/array_sum.hex", dut.IMemory, 0, 18);
        $readmemh("firmware/hex/examples/array_sum.hex", dut.DMemory, 0, 18);
        dut.DMemory[32] = 32'h0cab_005e;  // address 128 evicts result block

        run_cycles(400);

        check_reg(5, 32'd72);          // t0 advanced past four values
        check_reg(6, 32'd0);           // t1 loop counter exhausted
        check_reg(10, 32'd36);         // a0 = 5 + 7 + 11 + 13
        check_reg(28, 32'd72);         // t3 = &result
        check_reg(8, 32'h0cab_005e);   // s0

        if (dut.DMemory[18] !== 32'd36) begin
            $display("FAIL: array sum expected DMemory[18] = %h, got %h",
                     32'd36, dut.DMemory[18]);
            $fatal;
        end

        $display("PASS: la pointer loop summed .word data and stored result = 36");
        $display("PASS: tb_program_array passed");
        $finish;
    end

endmodule
