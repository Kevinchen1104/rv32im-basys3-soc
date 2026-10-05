`timescale 1ns / 1ps

// Testbench: tb_program_stack
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Stack-call program restores sp and returns the expected result.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/stack_call.hex

module tb_program_stack;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_stack.vcd");
        $dumpvars(0, tb_program_stack);
        reset_cpu();
        max_ras_count = 0;

        $readmemh("firmware/hex/examples/stack_call.hex", dut.IMemory, 0, 20);
        dut.DMemory[16] = 32'hfeed_1234;

        run_cycles(420);

        check_reg(2, 32'd48);
        check_reg(10, 32'd12);
        check_reg(4, 32'hfeed_1234);

        if (dut.DMemory[0] !== 32'd12) begin
            $display("FAIL: stack-call result expected DMemory[0] = %h, got %h", 32'd12, dut.DMemory[0]);
            $fatal;
        end

        if (max_ras_count !== 4'd2 || dut.RASCount !== 4'd0) begin
            $display("FAIL: RAS depth expected peak 2 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: stack-call program restored sp and returned value = %0d", dut.DMemory[0]);
        $display("PASS: tb_program_stack passed");
        $finish;
    end

endmodule
