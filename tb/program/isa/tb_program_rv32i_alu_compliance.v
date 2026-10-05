`timescale 1ns / 1ps

// Checks: Selected local RV32I compliance-style ALU behavior for register and immediate arithmetic, logic,
//   comparisons, shifts, sign-bit/zero/-1 cases, shift 0/31, and x0 write suppression using a public debug_status
//   pass/fail signature.
// Firmware: firmware/hex/isa/rv32i_alu_compliance.hex

module tb_program_rv32i_alu_compliance;

    localparam [31:0] PASS_MARKER = 32'hc0a1_0001;
    localparam [31:0] FAIL_MARKER = 32'hbad1_0001;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/isa/rv32i_alu_compliance.hex";
    localparam integer PROGRAM_WORD_COUNT = 105;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_rv32i_alu_compliance.vcd");
        $dumpvars(0, tb_program_rv32i_alu_compliance);

        run_firmware();

        $display("PASS: tb_program_rv32i_alu_compliance passed");
        $finish;
    end

endmodule
