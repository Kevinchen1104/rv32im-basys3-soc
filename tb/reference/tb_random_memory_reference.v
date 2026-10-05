`timescale 1ns / 1ps

// Checks: Compares CPU register and data-memory state against a fixed-seed generated memory reference program; final
//   DMemory checking covers every generated memory operation word while JSON metadata records load results, store
//   values, widths, affected words, and checksum progress.
// Branch-free, fixed-seed memory program.

module tb_random_memory_reference;

`include "tb_common.vh"

    reg [31:0] expected_regs[0:31];
    reg [31:0] expected_dmem[0:31];
    integer i;

    localparam PROGRAM_WORD_COUNT = 133;
    localparam INITIAL_DMEM_WORD_COUNT = 128;
    localparam CHECKED_DMEM_WORD_COUNT = 32;

    initial begin
        $dumpfile("results/waveforms/tb_random_memory_reference.vcd");
        $dumpvars(0, tb_random_memory_reference);

        reset_cpu();
        $readmemh(reference_path("random_memory_reference.hex"), dut.IMemory, 0, reference_word_count(PROGRAM_WORD_COUNT) - 1);
        $readmemh(reference_path("random_memory_reference_dmem_init.hex"), dut.DMemory, 0, INITIAL_DMEM_WORD_COUNT - 1);
        $readmemh(reference_path("random_memory_reference_expected_regs.hex"), expected_regs, 0, 31);
        $readmemh(reference_path("random_memory_reference_expected_dmem.hex"), expected_dmem, 0, CHECKED_DMEM_WORD_COUNT - 1);

        run_cycles(900);

        for (i = 0; i < 32; i = i + 1) begin
            if (dut.Regs[i] !== expected_regs[i]) begin
                $display("FAIL: random memory reference x%0d expected %h, got %h",
                         i, expected_regs[i], dut.Regs[i]);
                $fatal;
            end
        end

        for (i = 0; i < CHECKED_DMEM_WORD_COUNT; i = i + 1) begin
            if (dut.DMemory[i] !== expected_dmem[i]) begin
                $display("FAIL: random memory reference DMemory[%0d] expected %h, got %h",
                         i, expected_dmem[i], dut.DMemory[i]);
                $fatal;
            end
        end

        $display("PASS: random memory reference matched CPU register and DMemory state");
        $display("PASS: tb_random_memory_reference passed");
        $finish;
    end

endmodule
