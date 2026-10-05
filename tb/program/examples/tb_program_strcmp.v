`timescale 1ns / 1ps

// Testbench: tb_program_strcmp
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Strcmp-style function returns expected equality/difference results.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/strcmp_function.hex

module tb_program_strcmp;

`include "tb_common.vh"

    reg [3:0] max_ras_count = 0;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_program_strcmp.vcd");
        $dumpvars(0, tb_program_strcmp);
        reset_cpu();
        max_ras_count = 0;
        $readmemh("firmware/hex/examples/strcmp_function.hex", dut.IMemory, 0, 39);
        $readmemh("firmware/hex/examples/strcmp_function.hex", dut.DMemory, 0, 39);
        dut.DMemory[52] = 32'h5a7e_cafe;

        run_cycles(820);

        check_reg(1, 32'd52);          // ra = second return address
        check_reg(5, 32'd132);         // t0 stopped at mismatching left byte
        check_reg(6, 32'd148);         // t1 stopped at mismatching right byte
        check_reg(7, 32'd88);          // t2 = left mismatch byte
        check_reg(8, 32'h5a7ecafe);    // s0
        check_reg(10, 32'd1);          // a0 = mismatch return value
        check_reg(28, 32'd89);         // t3 = right mismatch byte
        check_reg(29, 32'd152);        // t4 = equal result address
        check_reg(30, 32'd156);        // t5 = mismatch result address

        if (dut.DMemory[38] !== 32'd0 || dut.DMemory[39] !== 32'd1) begin
            $display("FAIL: strcmp expected DMemory[38] = 0 and DMemory[39] = 1, got %h and %h",
                     dut.DMemory[38], dut.DMemory[39]);
            $fatal;
        end

        if (max_ras_count !== 4'd1 || dut.RASCount !== 4'd0) begin
            $display("FAIL: strcmp RAS expected peak 1 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: strcmp program returned equal=0 and different=1");
        $display("PASS: tb_program_strcmp passed");
        $finish;
    end
endmodule
