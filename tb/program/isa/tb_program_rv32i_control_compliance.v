`timescale 1ns / 1ps

// Checks: Selected local RV32I compliance-style control-flow behavior for taken and not-taken branches,
//   signed/unsigned branch boundaries, JAL link, JALR bit-0 clearing, return flow, and wrong-path suppression using a
//   public debug_status pass/fail signature.
// Firmware: firmware/hex/isa/rv32i_control_compliance.hex

module tb_program_rv32i_control_compliance;

    localparam [31:0] PASS_MARKER = 32'hc0a1_0002;
    localparam [31:0] FAIL_MARKER = 32'hbad1_0002;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/isa/rv32i_control_compliance.hex";
    localparam integer PROGRAM_WORD_COUNT = 68;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_rv32i_control_compliance.vcd");
        $dumpvars(0, tb_program_rv32i_control_compliance);

        run_firmware();

        $display("PASS: tb_program_rv32i_control_compliance passed");
        $finish;
    end

endmodule
