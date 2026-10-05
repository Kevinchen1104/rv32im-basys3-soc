`timescale 1ns / 1ps

// Testbench: tb_program_nested_sum
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Non-leaf nested function calls restore frame state and return array-sum result.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/nested_sum_function.hex

module tb_program_nested_sum;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_nested_sum.vcd");
        $dumpvars(0, tb_program_nested_sum);
        reset_cpu();
        max_ras_count = 0;

        $readmemh("firmware/hex/examples/nested_sum_function.hex", dut.IMemory, 0, 34);
        $readmemh("firmware/hex/examples/nested_sum_function.hex", dut.DMemory, 0, 34);
        dut.DMemory[48] = 32'h5a5a_cafe;  // address 192 evicts result block

        run_cycles(700);

        if (dut.DMemory[61] !== 32'd9 ||
            dut.DMemory[62] !== 32'd8 ||
            dut.DMemory[63] !== 32'd20) begin
            $display("FAIL: saved frame expected s1/s0/ra = %h/%h/%h, got %h/%h/%h; old-sp words = %h/%h",
                     32'd9, 32'd8, 32'd20,
                     dut.DMemory[61], dut.DMemory[62], dut.DMemory[63],
                     dut.DMemory[64], dut.DMemory[65]);
            $fatal;
        end

        check_reg(2, 32'd256);         // sp restored after stack frame
        check_reg(8, 32'd8);           // s0 restored
        check_reg(9, 32'd9);           // s1 restored
        check_reg(10, 32'd36);         // a0 = returned sum
        check_reg(18, 32'h5a5a_cafe); // s2
        check_reg(28, 32'd136);        // t3 = &result
        check_reg(1, 32'd20);          // ra restored for main return

        if (dut.DMemory[34] !== 32'd36) begin
            $display("FAIL: nested sum expected DMemory[34] = %h, got %h",
                     32'd36, dut.DMemory[34]);
            $fatal;
        end

        if (max_ras_count !== 4'd2 || dut.RASCount !== 4'd0) begin
            $display("FAIL: nested sum RAS expected peak 2 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: non-leaf sum function restored its frame and returned array sum = 36");
        $display("PASS: tb_program_nested_sum passed");
        $finish;
    end

endmodule
