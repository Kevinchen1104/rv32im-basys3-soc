`timescale 1ns / 1ps

// Testbench: tb_random_control_reference
// Purpose: Compares DUT behavior against deterministic local reference or signature fixtures.
// Checks: Compares CPU final architectural register and sentinel DMemory state against a fixed-seed generated
//   control-flow program interpreted by a PC-driven software reference model; metadata records static instructions,
//   executed rows, execution order, branch/jump targets, and wrong-path side-effect suppression.
// Pass condition: DUT outputs match the generated expected fixture or signature and no mismatch or timeout occurs.
// Does not prove: Fixed-seed, no-loop, final-state control-flow slice; not broad constrained-random verification,
//   full ISA/control-flow compliance, cycle-accurate pipeline modeling, or formal verification.

module tb_random_control_reference;

`include "tb_common.vh"

    reg [31:0] expected_regs[0:31];
    reg [31:0] expected_dmem[0:7];
    integer i;

    localparam PROGRAM_WORD_COUNT = 63;
    localparam CHECKED_DMEM_WORD_COUNT = 8;
    localparam SENTINEL_WORD = 7;

    initial begin
        $dumpfile("wave/tb_random_control_reference.vcd");
        $dumpvars(0, tb_random_control_reference);

        reset_cpu();
        dut.DMemory[SENTINEL_WORD] = 32'h1234_abcd;
        $readmemh("fixtures/generated/reference/random_control_reference.hex", dut.IMemory, 0, PROGRAM_WORD_COUNT - 1);
        $readmemh("fixtures/generated/reference/random_control_reference_expected_regs.hex", expected_regs, 0, 31);
        $readmemh("fixtures/generated/reference/random_control_reference_expected_dmem.hex", expected_dmem, 0, CHECKED_DMEM_WORD_COUNT - 1);

        run_cycles(900);

        for (i = 0; i < 32; i = i + 1) begin
            if (dut.Regs[i] !== expected_regs[i]) begin
                $display("FAIL: random control reference x%0d expected %h, got %h",
                         i, expected_regs[i], dut.Regs[i]);
                $fatal;
            end
        end

        for (i = 0; i < CHECKED_DMEM_WORD_COUNT; i = i + 1) begin
            if (dut.DMemory[i] !== expected_dmem[i]) begin
                $display("FAIL: random control reference DMemory[%0d] expected %h, got %h",
                         i, expected_dmem[i], dut.DMemory[i]);
                $fatal;
            end
        end

        $display("PASS: random control reference matched CPU register and DMemory state");
        $display("PASS: tb_random_control_reference passed");
        $finish;
    end

endmodule
