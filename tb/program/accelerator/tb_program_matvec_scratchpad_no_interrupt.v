`timescale 1ns / 1ps

// Testbench: tb_program_matvec_scratchpad_no_interrupt
// Purpose: Runs CPU firmware through accelerator-facing MMIO or DMA-lite paths.
// Checks: With CPU interrupt CSRs enabled but MATVEC Scratchpad interrupt_enable left clear, accelerator completion does not
//   trap; software polls done, reads the result, clears status, and exposes a public debug_status pass/fail
//   signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/accelerator/matvec_scratchpad_no_interrupt.hex

module tb_program_matvec_scratchpad_no_interrupt;

    localparam [31:0] PASS_MARKER = 32'hacce_2105;
    localparam [31:0] FAIL_MARKER = 32'hbad0_2105;
    localparam integer TIMEOUT_CYCLES = 3000;

    localparam PROGRAM_HEX = "firmware/hex/accelerator/matvec_scratchpad_no_interrupt.hex";
    localparam integer PROGRAM_WORD_COUNT = 57;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_matvec_scratchpad_no_interrupt.vcd");
        $dumpvars(0, tb_program_matvec_scratchpad_no_interrupt);

        run_firmware();

        $display("PASS: tb_program_matvec_scratchpad_no_interrupt passed");
        $finish;
    end

endmodule
