`timescale 1ns / 1ps

// Testbench: tb_program_exception_mcause_mtval
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: Environment, illegal-instruction, and instruction/load/store access-fault handlers observe the expected
//   mcause, mepc, and mtval values, resume through mret, and publish a public debug_status pass/fail signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/exception_mcause_mtval.hex

module tb_program_exception_mcause_mtval;

    localparam [31:0] PASS_MARKER = 32'hc5e2_0002;
    localparam [31:0] FAIL_MARKER = 32'hbad5_0002;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/csr_trap/exception_mcause_mtval.hex";
    localparam integer PROGRAM_WORD_COUNT = 157;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_exception_mcause_mtval.vcd");
        $dumpvars(0, tb_program_exception_mcause_mtval);

        run_firmware();

        if (dut.CSRmcause !== 32'd1 || dut.CSRmtval !== 32'h0000_1000 ||
            dut.DMemory[3] !== 32'd6) begin
            $display("FAIL: final exception evidence mcause=%h mtval=%h count=%h",
                     dut.CSRmcause,
                     dut.CSRmtval,
                     dut.DMemory[3]);
            $fatal;
        end

        $display("PASS: tb_program_exception_mcause_mtval passed");
        $finish;
    end

endmodule
