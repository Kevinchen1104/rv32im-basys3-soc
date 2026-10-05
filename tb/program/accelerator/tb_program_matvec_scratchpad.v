`timescale 1ns / 1ps

// Testbench: tb_program_matvec_scratchpad
// Purpose: Runs CPU firmware through accelerator-facing MMIO or DMA-lite paths.
// Checks: CPU drives the MATVEC Scratchpad accelerator through MMIO, programs vector and multiple rows, starts the
//   accelerator, polls done, selects and reads results, checks exact y0..y3 values in assembly, and exposes a
//   pass/fail signature through debug_status.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/accelerator/matvec_scratchpad_demo.hex

module tb_program_matvec_scratchpad;

    localparam [31:0] PASS_MARKER = 32'hacce_2004;
    localparam [31:0] FAIL_MARKER = 32'hbad0_2004;
    localparam integer TIMEOUT_CYCLES = 2500;

    localparam PROGRAM_HEX = "firmware/hex/accelerator/matvec_scratchpad_demo.hex";
    localparam integer PROGRAM_WORD_COUNT = 74;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_matvec_scratchpad.vcd");
        $dumpvars(0, tb_program_matvec_scratchpad);

        run_firmware();

        $display("PASS: tb_program_matvec_scratchpad passed");
        $finish;
    end

endmodule
