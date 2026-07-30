`timescale 1ns / 1ps

// Testbench: tb_cache
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Cache refill and dirty D-cache write-back behavior through architectural loads.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_cache;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_cache.vcd");
        $dumpvars(0, tb_cache);
        reset_cpu();

        dut.DMemory[0]  = 32'h1111_1111;
        dut.DMemory[16] = 32'h2222_2222;  // address 64, same cache index as address 0

        dut.IMemory[0] = i_type(12'd99, 5'd0, 3'b000, 5'd1, 7'b0010011);  // x1 = 99
        dut.IMemory[1] = s_type(12'd0, 5'd1, 5'd0, 3'b010, 7'b0100011);  // sw x1, 0(x0)
        dut.IMemory[2] = i_type(12'd64, 5'd0, 3'b010, 5'd2, 7'b0000011);  // lw x2, 64(x0), evict
        dut.IMemory[3] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        run_cycles(150);

        check_reg(1, 32'd99);
        check_reg(2, 32'h2222_2222);
        if (dut.DMemory[0] !== 32'd99) begin
            $display("FAIL: write-back expected DMemory[0] = %h, got %h", 32'd99, dut.DMemory[0]);
            $fatal;
        end
        $display("PASS: dirty cache line written back on eviction");
        $display("PASS: tb_cache passed");
        $finish;
    end

endmodule
