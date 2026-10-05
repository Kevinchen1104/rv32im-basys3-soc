`timescale 1ns / 1ps

// Testbench: tb_program_strlen
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Leaf strlen-style function returns byte length from string data.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/strlen_function.hex

module tb_program_strlen;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_strlen.vcd");
        $dumpvars(0, tb_program_strlen);
        reset_cpu();
        max_ras_count = 0;

        $readmemh("firmware/hex/examples/strlen_function.hex", dut.IMemory, 0, 19);
        $readmemh("firmware/hex/examples/strlen_function.hex", dut.DMemory, 0, 19);
        dut.DMemory[32] = 32'h51e1_cafe;  // address 128 evicts result block

        run_cycles(520);

        check_reg(1, 32'd12);          // ra = instruction after call
        check_reg(5, 32'd73);          // t0 points at the zero terminator
        check_reg(6, 32'd0);           // t1 observed the terminator
        check_reg(10, 32'd5);          // a0 = strlen("HELLO")
        check_reg(28, 32'd76);         // t3 = aligned &result
        check_reg(8, 32'h51e1_cafe);   // s0

        if (dut.DMemory[19] !== 32'd5) begin
            $display("FAIL: strlen expected DMemory[19] = %h, got %h",
                     32'd5, dut.DMemory[19]);
            $fatal;
        end

        if (max_ras_count !== 4'd1 || dut.RASCount !== 4'd0) begin
            $display("FAIL: strlen RAS expected peak 1 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: leaf strlen function returned byte length = 5");
        $display("PASS: tb_program_strlen passed");
        $finish;
    end

endmodule
