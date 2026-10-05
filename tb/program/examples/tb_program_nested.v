`timescale 1ns / 1ps

// Testbench: tb_program_nested
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Nested calls execute and return correctly with RAS depth behavior.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/nested_call.hex

module tb_program_nested;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_nested.vcd");
        $dumpvars(0, tb_program_nested);
        reset_cpu();
        max_ras_count = 0;

        $readmemh("firmware/hex/examples/nested_call.hex", dut.IMemory, 0, 14);
        dut.DMemory[16] = 32'hface_cafe;

        run_cycles(320);

        check_reg(10, 32'd12);
        check_reg(4, 32'hface_cafe);

        if (dut.DMemory[0] !== 32'd12) begin
            $display("FAIL: nested result expected DMemory[0] = %h, got %h", 32'd12, dut.DMemory[0]);
            $fatal;
        end

        if (max_ras_count !== 4'd2) begin
            $display("FAIL: maximum RASCount expected 2, got %0d", max_ras_count);
            $fatal;
        end

        if (dut.RASCount !== 4'd0) begin
            $display("FAIL: final RASCount expected 0, got %0d", dut.RASCount);
            $fatal;
        end

        $display("PASS: nested call reached RAS depth %0d and returned value = %0d", max_ras_count, dut.DMemory[0]);
        $display("PASS: tb_program_nested passed");
        $finish;
    end

endmodule
