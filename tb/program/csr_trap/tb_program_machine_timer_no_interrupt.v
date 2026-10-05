`timescale 1ns / 1ps

// Testbench: tb_program_machine_timer_no_interrupt
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: CPU software lets the machine timer become pending while mie.MTIE remains disabled, observes MTIP by
//   polling, proves the handler does not run within a bounded loop, and exposes a public debug_status pass/fail
//   signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/machine_timer_no_interrupt.hex

module tb_program_machine_timer_no_interrupt;

    localparam [31:0] PASS_MARKER = 32'h71ce_8000;
    localparam [31:0] FAIL_MARKER = 32'hbad0_8000;
    localparam integer TIMEOUT_CYCLES = 5000;

    localparam PROGRAM_HEX = "firmware/hex/csr_trap/machine_timer_no_interrupt.hex";
    localparam integer PROGRAM_WORD_COUNT = 51;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_machine_timer_no_interrupt.vcd");
        $dumpvars(0, tb_program_machine_timer_no_interrupt);

        run_firmware();

        if (dut.CSRmip[7] !== 1'b1) begin
            $display("FAIL: timer should be pending while source is masked, mip=%h", dut.CSRmip);
            $fatal;
        end

        if (dut.CSRmie[7] !== 1'b0) begin
            $display("FAIL: MTIE should remain disabled in no-interrupt test, mie=%h", dut.CSRmie);
            $fatal;
        end

        if (dut.CSRmcause === 32'h8000_0007 || dut.Regs[9] !== 32'h0) begin
            $display("FAIL: unexpected timer handler state mcause=%h s1=%h", dut.CSRmcause, dut.Regs[9]);
            $fatal;
        end

        $display("PASS: tb_program_machine_timer_no_interrupt passed");
        $finish;
    end
endmodule
