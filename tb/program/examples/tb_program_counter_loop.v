`timescale 1ns / 1ps

// Testbench: tb_program_counter_loop
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: A small counter-loop workload stores a sum and emits performance counter INFO rows.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/counter_loop.hex

module tb_program_counter_loop;

`include "tb_common.vh"

    localparam DONE_PC = 32'd40;

    reg sampled;
    reg [31:0] sampled_cycles;
    reg [31:0] sampled_retired;
    reg [31:0] sampled_branch_miss;
    reg [31:0] sampled_icache_miss;
    reg [31:0] sampled_dcache_miss;
    reg [31:0] sampled_stall_cycles;

    always @(posedge clock) begin
        if (reset) begin
            sampled <= 1'b0;
            sampled_cycles <= 32'd0;
            sampled_retired <= 32'd0;
            sampled_branch_miss <= 32'd0;
            sampled_icache_miss <= 32'd0;
            sampled_dcache_miss <= 32'd0;
            sampled_stall_cycles <= 32'd0;
        end else if (!sampled &&
                     (dut.PC == DONE_PC) &&
                     (dut.DMemory[64] == 32'd136) &&
                     (debug_status == 32'd136)) begin
            sampled <= 1'b1;
            sampled_cycles <= dut.CycleCount;
            sampled_retired <= dut.RetiredCount;
            sampled_branch_miss <= dut.BranchMissCount;
            sampled_icache_miss <= dut.ICacheMissCount;
            sampled_dcache_miss <= dut.DCacheMissCount;
            sampled_stall_cycles <= dut.StallCycleCount;
        end
    end

    initial begin
        $dumpfile("wave/tb_program_counter_loop.vcd");
        $dumpvars(0, tb_program_counter_loop);
        reset_cpu();

        $readmemh("firmware/hex/examples/counter_loop.hex", dut.IMemory, 0, 10);

        run_cycles(700);

        if (!sampled) begin
            $display("FAIL: counter loop did not reach sampled done condition");
            $fatal;
        end

        check_reg(5, 32'd136);        // t0 = 1 + ... + 16
        check_reg(6, 32'd0);          // t1 loop counter exhausted
        check_reg(7, 32'd17);         // t2 advanced past the final addend
        check_reg(8, 32'h0);          // s0 = conflicting block load from cleared memory
        check_reg(28, 32'd256);       // t3 = status address

        if (dut.DMemory[64] !== 32'd136) begin
            $display("FAIL: counter loop expected DMemory[64] = %h, got %h",
                     32'd136, dut.DMemory[64]);
            $fatal;
        end

        if (debug_status !== 32'd136) begin
            $display("FAIL: counter loop expected debug_status = %h, got %h",
                     32'd136, debug_status);
            $fatal;
        end

        if (sampled_retired < 32'd70) begin
            $display("FAIL: counter loop expected at least 70 retired instructions, got %0d",
                     sampled_retired);
            $fatal;
        end

        if (sampled_branch_miss < 32'd1) begin
            $display("FAIL: counter loop expected at least one branch miss, got %0d",
                     sampled_branch_miss);
            $fatal;
        end

        if (sampled_icache_miss < 32'd1) begin
            $display("FAIL: counter loop expected at least one I-cache miss, got %0d",
                     sampled_icache_miss);
            $fatal;
        end

        if (sampled_dcache_miss < 32'd1) begin
            $display("FAIL: counter loop expected at least one D-cache miss, got %0d",
                     sampled_dcache_miss);
            $fatal;
        end

        if (sampled_stall_cycles < 32'd1) begin
            $display("FAIL: counter loop expected at least one stall cycle, got %0d",
                     sampled_stall_cycles);
            $fatal;
        end

        $display("INFO: counter_loop cycles=%0d retired=%0d branch_miss=%0d icache_miss=%0d dcache_miss=%0d stall_cycles=%0d",
                 sampled_cycles,
                 sampled_retired,
                 sampled_branch_miss,
                 sampled_icache_miss,
                 sampled_dcache_miss,
                 sampled_stall_cycles);
        $display("PASS: counter loop benchmark stored sum and produced counter events");
        $display("PASS: tb_program_counter_loop passed");
        $finish;
    end

endmodule
