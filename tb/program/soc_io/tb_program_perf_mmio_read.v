`timescale 1ns / 1ps

// Testbench: tb_program_perf_mmio_read
// Purpose: Runs CPU firmware through board-facing MMIO observability and I/O paths.
// Checks: CPU program reads performance counters through the 0x600 MMIO window, proves cycle and retired counters are
//   nonzero, checks MATVEC counters remain zero before any MATVEC start, verifies a store to the read-only counter
//   window is ignored, and exposes a public pass/fail signature through debug_status.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/soc_io/perf_mmio_read.hex

module tb_program_perf_mmio_read;

    localparam [31:0] PASS_MARKER = 32'hacce_6000;
    localparam [31:0] FAIL_MARKER = 32'hbad0_6000;
    localparam integer TIMEOUT_CYCLES = 1800;

    localparam PROGRAM_HEX = "firmware/hex/soc_io/perf_mmio_read.hex";
    localparam integer PROGRAM_WORD_COUNT = 44;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_perf_mmio_read.vcd");
        $dumpvars(0, tb_program_perf_mmio_read);

        run_firmware();

        $display("PASS: tb_program_perf_mmio_read passed");
        $finish;
    end

endmodule
