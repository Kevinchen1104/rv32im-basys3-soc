`timescale 1ns / 1ps

// Testbench: tb_program_misaligned_exception
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: Assembled misaligned lw and sw traps observe mcause=4/6, mepc at the faulting instruction, mtval as the
//   faulting data address, load destination suppression, store side-effect suppression, and public debug_status
//   pass/fail.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/misaligned_exception.hex

module tb_program_misaligned_exception;

    localparam [31:0] PASS_MARKER = 32'hc5e3_0003;
    localparam [31:0] FAIL_MARKER = 32'hbad5_0003;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/csr_trap/misaligned_exception.hex";
    localparam integer PROGRAM_WORD_COUNT = 87;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_misaligned_exception.vcd");
        $dumpvars(0, tb_program_misaligned_exception);

        run_firmware();

        if (dut.CSRmcause !== 32'd6 || dut.CSRmtval !== 32'd66 || dut.DMemory[3] !== 32'd2) begin
            $display("FAIL: final misaligned evidence mcause=%h mtval=%h count=%h",
                     dut.CSRmcause,
                     dut.CSRmtval,
                     dut.DMemory[3]);
            $fatal;
        end

        $display("PASS: tb_program_misaligned_exception passed");
        $finish;
    end

endmodule
