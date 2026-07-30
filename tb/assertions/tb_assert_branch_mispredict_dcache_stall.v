`timescale 1ns / 1ps

// Testbench: tb_assert_branch_mispredict_dcache_stall
// Purpose: Exercises a focused pipeline, trap, or side-effect invariant with a directed simulation scenario.
// Checks: A taken branch mispredict overlapping a D-cache miss/stall is captured once, is not applied until
//   backpressure clears, redirects to the correct path, and suppresses wrong-path side effects.
// Pass condition: The directed scenario reaches the expected invariant/pass point without a mismatch, timeout, or
//   $fatal.
// Does not prove: Directed branch-mispredict plus D-cache-miss interaction only; does not cover all predictor states,
//   dirty write-back patterns, or external-memory timing.
// Assertion focus: Directed check for branch mispredict dcache stall behavior or side-effect suppression.

module tb_assert_branch_mispredict_dcache_stall;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;
    reg saw_overlap = 1'b0;
    reg saw_accept = 1'b0;
    reg saw_pending = 1'b0;
    integer accepted_miss_count = 0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.dcache_pipeline_stall &&
            dut.IDEXValid &&
            (dut.IDEXPC == 32'd8) &&
            dut.branch_mispredict_raw) begin
            if (dut.branch_mispredict || dut.ControlRedirectPending) begin
                $display("FAIL: stalled branch captured or applied redirect early");
                $fatal;
            end
            saw_overlap <= 1'b1;
        end

        if (checking_enabled && dut.branch_mispredict && (dut.IDEXPC == 32'd8)) begin
            saw_accept <= 1'b1;
            accepted_miss_count <= accepted_miss_count + 1;
        end

        if (checking_enabled &&
            dut.ControlRedirectPending &&
            (dut.ControlRedirectPC == 32'd28)) begin
            saw_pending <= 1'b1;
        end

        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            ((dut.MEMWBPC == 32'd12) || (dut.MEMWBPC == 32'd24))) begin
            $display(
                "FAIL: wrong-path register write at PC %h reached writeback for x%0d",
                dut.MEMWBPC,
                dut.MEMWBrd
            );
            $fatal;
        end

        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == 32'd16) || (dut.EXMEMPC == 32'd20))) begin
            $display("FAIL: wrong-path side-effect at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_branch_mispredict_dcache_stall.vcd");
        $dumpvars(0, tb_assert_branch_mispredict_dcache_stall);
        reset_cpu();

        dut.DMemory[0] = 32'h1234_abcd;
        dut.DMemory[16] = 32'h600d_cafe;                                   // load address 64
        dut.IMemory[0] = i_type(12'd55, 5'd0, 3'b000, 5'd2, 7'b0010011);    // x2 = side-effect data
        dut.IMemory[1] = i_type(12'd64, 5'd0, 3'b010, 5'd10, 7'b0000011);   // lw x10, 64(x0), D-cache miss
        dut.IMemory[2] = b_type(20, 5'd0, 5'd0, 3'b000, 7'b1100011);        // taken beq to PC 28
        dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);    // wrong-path register marker
        dut.IMemory[4] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);     // wrong-path sw x2, 0(x0)
        dut.IMemory[5] = s_type(12'h200, 5'd2, 5'd0, 3'b010, 7'b0100011);   // wrong-path sw x2, GPIO output
        dut.IMemory[6] = i_type(12'd88, 5'd0, 3'b000, 5'd8, 7'b0010011);    // extra wrong-path marker
        dut.IMemory[7] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);    // correct-path marker
        dut.IMemory[8] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);         // hold final state

        checking_enabled = 1'b1;
        run_cycles(220);

        if (!saw_overlap || !saw_accept || !saw_pending || (accepted_miss_count != 1)) begin
            $display("FAIL: registered recovery observations overlap=%0b accept=%0b pending=%0b accepts=%0d",
                     saw_overlap, saw_accept, saw_pending, accepted_miss_count);
            $fatal;
        end
        if (dut.DCacheMissCount < 32'd1 || dut.perf_dcache_miss_count < 32'd1) begin
            $display(
                "FAIL: expected D-cache miss count, got internal=%0d perf=%0d",
                dut.DCacheMissCount,
                dut.perf_dcache_miss_count
            );
            $fatal;
        end
        if (dut.BranchMissCount < 32'd1 || dut.perf_branch_miss_count < 32'd1) begin
            $display(
                "FAIL: expected branch miss count, got internal=%0d perf=%0d",
                dut.BranchMissCount,
                dut.perf_branch_miss_count
            );
            $fatal;
        end
        if (dut.DMemory[0] !== 32'h1234_abcd) begin
            $display("FAIL: wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end
        if (dut.GPIOOutput !== 32'h0 || gpio_outputs !== 32'h0) begin
            $display(
                "FAIL: wrong-path MMIO changed GPIOOutput=%h gpio_outputs=%h",
                dut.GPIOOutput,
                gpio_outputs
            );
            $fatal;
        end

        check_reg(2, 32'd55);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        check_reg(8, 32'd8);
        check_reg(10, 32'h600d_cafe);
        $display("PASS: stalled branch recovery was captured once, held, and applied after backpressure cleared");
        $display("PASS: wrong-path register, memory, and MMIO markers were suppressed");
        $display("PASS: tb_assert_branch_mispredict_dcache_stall passed");
        $finish;
    end

endmodule
