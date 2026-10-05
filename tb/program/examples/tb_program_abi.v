`timescale 1ns / 1ps

// Testbench: tb_program_abi
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: ABI-style call/return behavior and register aliases in an assembled program.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/abi_call.hex

module tb_program_abi;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_abi.vcd");
        $dumpvars(0, tb_program_abi);
        reset_cpu();
        max_ras_count = 0;

        $readmemh("firmware/hex/examples/abi_call.hex", dut.IMemory, 0, 14);
        dut.DMemory[16] = 32'h89ab_cdef;

        run_cycles(320);

        check_reg(2, 32'd48);          // sp
        check_reg(5, 32'h89ab_cdef);   // t0
        check_reg(6, 32'd12);          // t1
        check_reg(10, 32'd12);         // a0

        if (dut.DMemory[0] !== 32'd12) begin
            $display("FAIL: ABI call expected DMemory[0] = %h, got %h", 32'd12, dut.DMemory[0]);
            $fatal;
        end

        if (max_ras_count !== 4'd1 || dut.RASCount !== 4'd0) begin
            $display("FAIL: ABI call RAS expected peak 1 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: ABI-style program called a function and returned value = %0d", dut.DMemory[0]);
        $display("PASS: tb_program_abi passed");
        $finish;
    end

endmodule
