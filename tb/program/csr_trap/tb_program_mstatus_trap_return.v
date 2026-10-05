`timescale 1ns / 1ps

// Testbench: tb_program_mstatus_trap_return
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: An assembled ecall handler observes trap-entry mstatus.MIE=0 and MPIE=1, returns with mret, observes
//   post-return MIE=1 and MPIE=1, and exposes a public debug_status pass/fail signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/mstatus_trap_return.hex

module tb_program_mstatus_trap_return;

    localparam [31:0] PASS_MARKER = 32'h517a_900d;
    localparam [31:0] FAIL_MARKER = 32'hbad0_900d;
    localparam [31:0] ECALL_PC = 32'd40;
    localparam [31:0] RETURN_PC = 32'd48;
    localparam integer TIMEOUT_CYCLES = 3000;

    localparam PROGRAM_HEX = "firmware/hex/csr_trap/mstatus_trap_return.hex";
    localparam integer PROGRAM_WORD_COUNT = 56;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_mstatus_trap_return.vcd");
        $dumpvars(0, tb_program_mstatus_trap_return);

        run_firmware();

        if (dut.DMemory[0] !== 32'd1) begin
            $display("FAIL: handler flag expected 1, got %h", dut.DMemory[0]);
            $fatal;
        end

        if (dut.DMemory[1][3] !== 1'b0 || dut.DMemory[1][7] !== 1'b1) begin
            $display("FAIL: handler mstatus expected MIE=0 MPIE=1, got %h", dut.DMemory[1]);
            $fatal;
        end

        if (dut.DMemory[2] !== 32'd11 || dut.DMemory[3] !== ECALL_PC) begin
            $display("FAIL: handler trap state mcause=%h mepc=%h", dut.DMemory[2], dut.DMemory[3]);
            $fatal;
        end

        if (dut.CSRmcause !== 32'd11 || dut.CSRmepc !== RETURN_PC) begin
            $display("FAIL: final CSR trap state mcause=%h mepc=%h", dut.CSRmcause, dut.CSRmepc);
            $fatal;
        end

        if (dut.CSRmstatus[3] !== 1'b1 || dut.CSRmstatus[7] !== 1'b1) begin
            $display("FAIL: final mstatus expected MIE=1 MPIE=1, got %h", dut.CSRmstatus);
            $fatal;
        end

        $display("PASS: tb_program_mstatus_trap_return passed");
        $finish;
    end
endmodule
