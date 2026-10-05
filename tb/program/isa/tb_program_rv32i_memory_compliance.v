`timescale 1ns / 1ps

// Checks: Selected local RV32I compliance-style load/store behavior for lb/lbu/lh/lhu/lw/sb/sh/sw, little-endian byte
//   lanes, sign/zero extension, and overlapping subword stores using a public debug_status pass/fail signature.
// Firmware: firmware/hex/isa/rv32i_memory_compliance.hex

module tb_program_rv32i_memory_compliance;

    localparam [31:0] PASS_MARKER = 32'hc0a1_0003;
    localparam [31:0] FAIL_MARKER = 32'hbad1_0003;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/isa/rv32i_memory_compliance.hex";
    localparam integer PROGRAM_WORD_COUNT = 106;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_rv32i_memory_compliance.vcd");
        $dumpvars(0, tb_program_rv32i_memory_compliance);

        run_firmware();

        $display("PASS: tb_program_rv32i_memory_compliance passed");
        $finish;
    end

endmodule
