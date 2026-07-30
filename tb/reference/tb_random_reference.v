`timescale 1ns / 1ps

// Testbench: tb_random_reference
// Purpose: Compares DUT behavior against deterministic local reference or signature fixtures.
// Checks: Compares CPU architectural register state against a generated branch-free random reference program.
// Pass condition: DUT outputs match the generated expected fixture or signature and no mismatch or timeout occurs.
// Does not prove: Branch-free register/ALU focused; not broad constrained-random verification.

module tb_random_reference;

`include "tb_common.vh"

    reg [31:0] expected_regs[0:31];
    integer i;

    localparam PROGRAM_WORD_COUNT = 170;

    initial begin
        $dumpfile("wave/tb_random_reference.vcd");
        $dumpvars(0, tb_random_reference);

        reset_cpu();
        $readmemh("fixtures/generated/reference/random_reference.hex", dut.IMemory, 0, PROGRAM_WORD_COUNT - 1);
        $readmemh("fixtures/generated/reference/random_reference_expected.hex", expected_regs, 0, 31);

        run_cycles(520);

        for (i = 0; i < 32; i = i + 1) begin
            if (dut.Regs[i] !== expected_regs[i]) begin
                $display("FAIL: random reference x%0d expected %h, got %h",
                         i, expected_regs[i], dut.Regs[i]);
                $fatal;
            end
        end

        $display("PASS: random reference model matched CPU register state");
        $display("PASS: tb_random_reference passed");
        $finish;
    end

endmodule
