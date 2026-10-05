`timescale 1ns / 1ps

// Testbench: tb_program_sum_function
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Function call with pointer/count arguments and array-sum return value.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/sum_function.hex

module tb_program_sum_function;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_sum_function.vcd");
        $dumpvars(0, tb_program_sum_function);
        reset_cpu();
        max_ras_count = 0;

        $readmemh("firmware/hex/examples/sum_function.hex", dut.IMemory, 0, 22);
        $readmemh("firmware/hex/examples/sum_function.hex", dut.DMemory, 0, 22);
        dut.DMemory[38] = 32'hca11_ab1e;  // address 152 evicts result block

        run_cycles(500);

        check_reg(1, 32'd16);          // ra = instruction after call
        check_reg(5, 32'd88);          // t0 advanced past values to result
        check_reg(8, 32'hca11_ab1e);   // s0
        check_reg(10, 32'd36);         // a0 = returned sum
        check_reg(11, 32'd0);          // a1 length exhausted
        check_reg(28, 32'd88);         // t3 = &result

        if (dut.DMemory[22] !== 32'd36) begin
            $display("FAIL: sum function expected DMemory[22] = %h, got %h",
                     32'd36, dut.DMemory[22]);
            $fatal;
        end

        if (max_ras_count !== 4'd1 || dut.RASCount !== 4'd0) begin
            $display("FAIL: sum function RAS expected peak 1 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: function received pointer/count arguments and returned array sum = 36");
        $display("PASS: tb_program_sum_function passed");
        $finish;
    end

endmodule
