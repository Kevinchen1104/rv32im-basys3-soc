`timescale 1ns / 1ps

// Testbench: tb_program_halfword_array
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: Lhu pointer loop over packed halfword data.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/halfword_array_sum.hex

module tb_program_halfword_array;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_halfword_array.vcd");
        $dumpvars(0, tb_program_halfword_array);
        reset_cpu();

        $readmemh("firmware/hex/examples/halfword_array_sum.hex", dut.IMemory, 0, 16);
        $readmemh("firmware/hex/examples/halfword_array_sum.hex", dut.DMemory, 0, 16);
        dut.DMemory[32] = 32'h51de_cafe;  // address 128 evicts result block

        run_cycles(400);

        check_reg(5, 32'd64);          // t0 advanced across four halfwords
        check_reg(6, 32'd0);           // t1 loop counter exhausted
        check_reg(10, 32'h0001_8002);  // 1 + 2 + 65535 + 32768
        check_reg(28, 32'd64);         // t3 = &result
        check_reg(8, 32'h51de_cafe);   // s0

        if (dut.DMemory[16] !== 32'h0001_8002) begin
            $display("FAIL: halfword sum expected DMemory[16] = %h, got %h",
                     32'h0001_8002, dut.DMemory[16]);
            $fatal;
        end

        $display("PASS: lhu pointer loop summed packed halfword data and stored result");
        $display("PASS: tb_program_halfword_array passed");
        $finish;
    end

endmodule
