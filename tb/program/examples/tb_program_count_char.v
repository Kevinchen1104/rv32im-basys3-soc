`timescale 1ns / 1ps

// Testbench: tb_program_count_char
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Count-char function over string data with matching and absent-byte cases.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/count_char_function.hex

module tb_program_count_char;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("wave/tb_program_count_char.vcd");
        $dumpvars(0, tb_program_count_char);
        reset_cpu();
        max_ras_count = 0;

        $readmemh("firmware/hex/examples/count_char_function.hex", dut.IMemory, 0, 33);
        $readmemh("firmware/hex/examples/count_char_function.hex", dut.DMemory, 0, 33);
        dut.DMemory[64] = 32'hc041_cafe;

        run_cycles(900);

        check_reg(1, 32'd44);          // ra = second return address
        check_reg(5, 32'd127);         // t0 stopped at the zero terminator
        check_reg(6, 32'd90);          // t1 = searched byte for the second call
        check_reg(7, 32'd0);           // t2 observed the terminator
        check_reg(8, 32'hc041cafe);    // s0
        check_reg(10, 32'd0);          // a0 = count_char(message, 'Z')
        check_reg(29, 32'd128);        // t4 = &result_a
        check_reg(30, 32'd132);        // t5 = &result_z

        if (dut.DMemory[32] !== 32'd8 || dut.DMemory[33] !== 32'd0) begin
            $display("FAIL: count_char expected DMemory[32] = 8 and DMemory[33] = 0, got %h and %h",
                     dut.DMemory[32], dut.DMemory[33]);
            $fatal;
        end

        if (max_ras_count !== 4'd1 || dut.RASCount !== 4'd0) begin
            $display("FAIL: count_char RAS expected peak 1 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: count_char returned matching byte count and zero for absent byte");
        $display("PASS: tb_program_count_char passed");
        $finish;
    end

endmodule
