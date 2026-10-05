`timescale 1ns / 1ps

// Testbench: tb_program_privileged_csr_edges
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: An assembled program observes mtvec direct-mode alignment, mepc IALIGN=32 alignment, mstatus machine-only
//   MPP plus MIE/MPIE WARL behavior, mie/mip implemented-bit masking, mtval read/write, and aligned mret return
//   through a public debug_status pass/fail signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/privileged_csr_edges.hex

module tb_program_privileged_csr_edges;

    localparam [31:0] PASS_MARKER = 32'hc5e1_0001;
    localparam [31:0] FAIL_MARKER = 32'hbad5_0001;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/csr_trap/privileged_csr_edges.hex";
    localparam integer PROGRAM_WORD_COUNT = 85;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_privileged_csr_edges.vcd");
        $dumpvars(0, tb_program_privileged_csr_edges);

        run_firmware();

        if (dut.CSRmstatus !== 32'h0000_1888 ||
            dut.CSRmcause !== 32'd11 ||
            dut.CSRmtval !== 32'h0) begin
            $display("FAIL: final CSR state mstatus=%h mcause=%h mtval=%h",
                     dut.CSRmstatus,
                     dut.CSRmcause,
                     dut.CSRmtval);
            $fatal;
        end

        $display("PASS: tb_program_privileged_csr_edges passed");
        $finish;
    end

endmodule
