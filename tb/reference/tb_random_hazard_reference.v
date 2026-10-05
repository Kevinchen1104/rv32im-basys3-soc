`timescale 1ns / 1ps

// Checks: Compares CPU final architectural register and DMemory state against a fixed-seed hazard-biased generated
//   reference program covering load-use, ALU forwarding, store-data forwarding, load-to-store, branch operand
//   forwarding, branch-after-load, not-taken fallthrough, and taken-branch wrong-path suppression.
// Fixed-seed program without loops; compares final architectural state.

module tb_random_hazard_reference;

`include "tb_common.vh"

    reg [31:0] expected_regs[0:31];
    reg [31:0] expected_dmem[0:31];
    integer i;

    localparam PROGRAM_WORD_COUNT = 45;
    localparam INITIAL_DMEM_WORD_COUNT = 128;
    localparam CHECKED_DMEM_WORD_COUNT = 32;

    initial begin
        $dumpfile("results/waveforms/tb_random_hazard_reference.vcd");
        $dumpvars(0, tb_random_hazard_reference);

        reset_cpu();
        $readmemh(reference_path("random_hazard_reference.hex"), dut.IMemory, 0, reference_word_count(PROGRAM_WORD_COUNT) - 1);
        $readmemh(reference_path("random_hazard_reference_dmem_init.hex"), dut.DMemory, 0, INITIAL_DMEM_WORD_COUNT - 1);
        $readmemh(reference_path("random_hazard_reference_expected_regs.hex"), expected_regs, 0, 31);
        $readmemh(reference_path("random_hazard_reference_expected_dmem.hex"), expected_dmem, 0, CHECKED_DMEM_WORD_COUNT - 1);

        run_cycles(900);

        for (i = 0; i < 32; i = i + 1) begin
            if (dut.Regs[i] !== expected_regs[i]) begin
                $display("FAIL: random hazard reference x%0d expected %h, got %h",
                         i, expected_regs[i], dut.Regs[i]);
                $fatal;
            end
        end

        for (i = 0; i < CHECKED_DMEM_WORD_COUNT; i = i + 1) begin
            if (dut.DMemory[i] !== expected_dmem[i]) begin
                $display("FAIL: random hazard reference DMemory[%0d] expected %h, got %h",
                         i, expected_dmem[i], dut.DMemory[i]);
                $fatal;
            end
        end

        if (dut.Regs[30] !== 32'h000007ab) begin
            $display("FAIL: random hazard reference completion marker expected 000007ab, got %h",
                     dut.Regs[30]);
            $fatal;
        end

        $display("PASS: random hazard reference matched CPU register and DMemory state");
        $display("PASS: tb_random_hazard_reference passed");
        $finish;
    end

endmodule
