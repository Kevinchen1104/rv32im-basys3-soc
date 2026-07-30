`timescale 1ns / 1ps

// Testbench: tb_assert_reset
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: Reset restores core control state, counters, CSR state, RAS state, cache FSMs, and outputs.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Directed reset-state snapshot; not all mid-transaction reset timings are covered.
// Assertion focus: Directed check for reset behavior or side-effect suppression.

module tb_assert_reset;

`include "tb_common.vh"

    task check_reset_state;
        begin
            if (dut.PC !== 32'd0 ||
                dut.IFIDValid !== 1'b0 ||
                dut.IDEXValid !== 1'b0 ||
                dut.EXMEMValid !== 1'b0 ||
                dut.MEMWBValid !== 1'b0 ||
                dut.CycleCount !== 32'd0 ||
                dut.RetiredCount !== 32'd0 ||
                dut.BranchMissCount !== 32'd0 ||
                dut.ICacheMissCount !== 32'd0 ||
                dut.DCacheMissCount !== 32'd0 ||
                dut.StallCycleCount !== 32'd0 ||
                dut.CSRmstatus !== 32'd0 ||
                dut.CSRmtvec !== 32'd0 ||
                dut.CSRmepc !== 32'd0 ||
                dut.CSRmcause !== 32'd0 ||
                dut.GPIOOutput !== 32'd0 ||
                dut.UARTTxValid !== 1'b0 ||
                dut.UARTRxReady !== 1'b0 ||
                dut.RASCount !== 4'd0 ||
                dut.cache_state !== dut.CACHE_IDLE ||
                dut.icache_state !== dut.IC_IDLE) begin
                $display("FAIL: reset did not restore core control state");
                $fatal;
            end

            check_reg(0, 32'd0);
            check_reg(1, 32'd1);
            check_reg(31, 32'd31);
            $display("PASS: reset restored core control state");
        end
    endtask

    initial begin
        $dumpfile("wave/tb_assert_reset.vcd");
        $dumpvars(0, tb_assert_reset);
        reset_cpu();

        dut.IMemory[0] = i_type(12'd7, 5'd0, 3'b000, 5'd1, 7'b0010011);
        dut.IMemory[1] = i_type(12'd8, 5'd0, 3'b000, 5'd2, 7'b0010011);
        dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        run_cycles(80);

        if (dut.CycleCount == 32'd0 || dut.PC == 32'd0) begin
            $display("FAIL: pre-reset activity did not dirty observable state");
            $fatal;
        end

        reset = 1'b1;
        @(posedge clock);
        #1;
        check_reset_state();

        reset = 1'b0;
        run_cycles(80);
        check_reg(1, 32'd7);
        check_reg(2, 32'd8);

        $display("PASS: tb_assert_reset passed");
        $finish;
    end

endmodule
