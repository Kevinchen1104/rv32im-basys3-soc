`timescale 1ns / 1ps

// Checks: Compares CPU final architectural register and DMemory state against a fixed-seed PC-driven generated
//   call/return reference program covering nested JAL/JALR calls, return-address links, stack save/restore, stack
//   memory load/store, callee dependencies, and wrong-path side-effect suppression after returns.
// Fixed-seed program with bounded execution; compares final registers and data memory.

module tb_random_call_reference;

`include "tb_common.vh"

    reg [31:0] expected_regs[0:31];
    reg [31:0] expected_dmem[0:31];
    reg [3:0] max_ras_count;
    integer i;

    localparam PROGRAM_WORD_COUNT = 54;
    localparam INITIAL_DMEM_WORD_COUNT = 128;
    localparam CHECKED_DMEM_WORD_COUNT = 32;
    localparam SENTINEL_WORD = 3;

    always @(negedge clock) begin
        if (dut.RASCount > max_ras_count) begin
            max_ras_count = dut.RASCount;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_random_call_reference.vcd");
        $dumpvars(0, tb_random_call_reference);

        max_ras_count = 0;
        reset_cpu();
        $readmemh(reference_path("random_call_reference.hex"), dut.IMemory, 0, reference_word_count(PROGRAM_WORD_COUNT) - 1);
        $readmemh(reference_path("random_call_reference_dmem_init.hex"), dut.DMemory, 0, INITIAL_DMEM_WORD_COUNT - 1);
        $readmemh(reference_path("random_call_reference_expected_regs.hex"), expected_regs, 0, 31);
        $readmemh(reference_path("random_call_reference_expected_dmem.hex"), expected_dmem, 0, CHECKED_DMEM_WORD_COUNT - 1);

        run_cycles(900);

        for (i = 0; i < 32; i = i + 1) begin
            if (dut.Regs[i] !== expected_regs[i]) begin
                $display("FAIL: random call reference x%0d expected %h, got %h",
                         i, expected_regs[i], dut.Regs[i]);
                $fatal;
            end
        end

        for (i = 0; i < CHECKED_DMEM_WORD_COUNT; i = i + 1) begin
            if (dut.DMemory[i] !== expected_dmem[i]) begin
                $display("FAIL: random call reference DMemory[%0d] expected %h, got %h",
                         i, expected_dmem[i], dut.DMemory[i]);
                $fatal;
            end
        end

        if (dut.Regs[30] !== 32'h000007ac) begin
            $display("FAIL: random call reference completion marker expected 000007ac, got %h",
                     dut.Regs[30]);
            $fatal;
        end

        if (dut.Regs[2] !== 32'h00000040) begin
            $display("FAIL: random call reference stack pointer expected 00000040, got %h",
                     dut.Regs[2]);
            $fatal;
        end

        if (dut.DMemory[SENTINEL_WORD] !== 32'h1234_abcd) begin
            $display("FAIL: random call reference sentinel DMemory[%0d] expected 1234abcd, got %h",
                     SENTINEL_WORD, dut.DMemory[SENTINEL_WORD]);
            $fatal;
        end

        if (max_ras_count < 4'd2 || dut.RASCount !== 4'd0) begin
            $display("FAIL: random call reference RAS depth expected peak >=2 and final 0, got peak %0d final %0d",
                     max_ras_count, dut.RASCount);
            $fatal;
        end

        $display("PASS: random call reference matched CPU register and DMemory state");
        $display("PASS: tb_random_call_reference passed");
        $finish;
    end

endmodule
