`timescale 1ns / 1ps

// Checks: CPU software configures mtvec, mie.MEIE, mstatus.MIE, enables MATVEC Scratchpad interrupts, starts the accelerator,
//   handles the completion interrupt, reads status/results in the handler, clears irq/done, returns with mret, and
//   exposes a public debug_status pass/fail signature.
// Firmware: firmware/hex/accelerator/matvec_scratchpad_interrupt.hex

module tb_program_matvec_scratchpad_interrupt;

    localparam [31:0] PASS_MARKER = 32'hacce_2104;
    localparam [31:0] FAIL_MARKER = 32'hbad0_2104;
    localparam integer TIMEOUT_CYCLES = 3000;

    localparam PROGRAM_HEX = "firmware/hex/accelerator/matvec_scratchpad_interrupt.hex";
    localparam integer PROGRAM_WORD_COUNT = 65;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_matvec_scratchpad_interrupt.vcd");
        $dumpvars(0, tb_program_matvec_scratchpad_interrupt);

        run_firmware();

        $display("PASS: tb_program_matvec_scratchpad_interrupt passed");
        $finish;
    end

endmodule
