`timescale 1ns / 1ps

// Testbench: tb_program_machine_timer_interrupt
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: CPU software programs the machine timer compare value, enables mstatus.MIE and mie.MTIE, takes an MTIP
//   interrupt through mtvec, records mcause/mepc/mip in the handler, postpones the timer, returns with mret, and
//   exposes a public debug_status pass/fail signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/machine_timer_interrupt.hex

module tb_program_machine_timer_interrupt;

    localparam [31:0] PASS_MARKER = 32'h71ce_8007;
    localparam [31:0] FAIL_MARKER = 32'hbad0_8007;
    localparam [31:0] WAIT_LW_PC = 32'd96;
    localparam [31:0] WAIT_BRANCH_PC = 32'd100;
    localparam integer TIMEOUT_CYCLES = 4000;

    localparam PROGRAM_HEX = "firmware/hex/csr_trap/machine_timer_interrupt.hex";
    localparam integer PROGRAM_WORD_COUNT = 71;
    `include "tb/common/tb_firmware.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_machine_timer_interrupt.vcd");
        $dumpvars(0, tb_program_machine_timer_interrupt);

        run_firmware();

        if (dut.CSRmcause !== 32'h8000_0007) begin
            $display("FAIL: expected timer interrupt mcause, got %h", dut.CSRmcause);
            $fatal;
        end

        if (dut.CSRmepc !== WAIT_LW_PC && dut.CSRmepc !== WAIT_BRANCH_PC) begin
            $display("FAIL: expected mepc in wait loop (%h or %h), got %h",
                     WAIT_LW_PC,
                     WAIT_BRANCH_PC,
                     dut.CSRmepc);
            $fatal;
        end

        if (dut.CSRmip[7] !== 1'b0) begin
            $display("FAIL: handler should postpone timer and clear effective MTIP, mip=%h", dut.CSRmip);
            $fatal;
        end

        if (dut.CSRmie[7] !== 1'b0) begin
            $display("FAIL: handler should disable MTIE before mret, mie=%h", dut.CSRmie);
            $fatal;
        end

        if (dut.Regs[9] !== 32'd1) begin
            $display("FAIL: handler flag register s1 expected 1, got %h", dut.Regs[9]);
            $fatal;
        end

        $display("PASS: tb_program_machine_timer_interrupt passed");
        $finish;
    end
endmodule
