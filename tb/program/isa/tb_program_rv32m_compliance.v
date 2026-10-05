`timescale 1ns / 1ps

// Checks: Selected local RV32M compliance-style multiply/divide/remainder behavior for
//   mul/mulh/mulhsu/mulhu/div/divu/rem/remu, division by zero, INT_MIN/-1, and signed/unsigned edge cases using a
//   public debug_status pass/fail signature.
// Firmware: firmware/hex/isa/rv32m_compliance.hex

module tb_program_rv32m_compliance;

    localparam [31:0] PASS_MARKER = 32'hc0a1_0004;
    localparam [31:0] FAIL_MARKER = 32'hbad1_0004;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/isa/rv32m_compliance.hex";
    localparam integer PROGRAM_WORD_COUNT = 104;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_rv32m_compliance.vcd");
        $dumpvars(0, tb_program_rv32m_compliance);

        run_firmware();

        $display("PASS: tb_program_rv32m_compliance passed");
        $finish;
    end

endmodule
