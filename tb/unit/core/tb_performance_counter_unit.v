`timescale 1ns / 1ps

// Testbench: tb_performance_counter_unit
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Standalone performance counter unit increments cycle, retired, miss, stall, and MATVEC event counters from
//   explicit event inputs; branch misses use a one-cycle registered capture with back-to-back, reset, and rollover checks.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.
//   behavior, or accelerator behavior.

module tb_performance_counter_unit;

    reg clock;
    reg reset;
    reg retire_event;
    reg branch_mispredict_event;
    reg icache_miss_event;
    reg dcache_miss_event;
    reg stall_event;
    reg matvec_start_accepted_event;
    reg matvec_done_rise_event;
    reg matvec_busy;

    wire [31:0] cycle_count;
    wire [31:0] retired_count;
    wire [31:0] branch_miss_count;
    wire [31:0] icache_miss_count;
    wire [31:0] dcache_miss_count;
    wire [31:0] stall_cycle_count;
    wire [31:0] matvec_start_count;
    wire [31:0] matvec_done_count;
    wire [31:0] matvec_busy_cycle_count;

    performance_counter_unit dut (
        .clock(clock),
        .reset(reset),
        .retire_event(retire_event),
        .branch_mispredict_event(branch_mispredict_event),
        .icache_miss_event(icache_miss_event),
        .dcache_miss_event(dcache_miss_event),
        .stall_event(stall_event),
        .matvec_start_accepted_event(matvec_start_accepted_event),
        .matvec_done_rise_event(matvec_done_rise_event),
        .matvec_busy(matvec_busy),
        .cycle_count(cycle_count),
        .retired_count(retired_count),
        .branch_miss_count(branch_miss_count),
        .icache_miss_count(icache_miss_count),
        .dcache_miss_count(dcache_miss_count),
        .stall_cycle_count(stall_cycle_count),
        .matvec_start_count(matvec_start_count),
        .matvec_done_count(matvec_done_count),
        .matvec_busy_cycle_count(matvec_busy_cycle_count)
    );

    initial begin
        clock = 1'b0;
        forever #5 clock = ~clock;
    end

    task clear_events;
    begin
        retire_event = 1'b0;
        branch_mispredict_event = 1'b0;
        icache_miss_event = 1'b0;
        dcache_miss_event = 1'b0;
        stall_event = 1'b0;
        matvec_start_accepted_event = 1'b0;
        matvec_done_rise_event = 1'b0;
        matvec_busy = 1'b0;
    end
    endtask

    task tick;
    begin
        @(posedge clock);
        #1;
    end
    endtask

    task check_word;
        input [255:0] name;
        input [31:0] actual;
        input [31:0] expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %h got %h", name, expected, actual);
            $fatal;
        end
    end
    endtask

    task check_all;
        input [31:0] exp_cycle;
        input [31:0] exp_retired;
        input [31:0] exp_branch;
        input [31:0] exp_icache;
        input [31:0] exp_dcache;
        input [31:0] exp_stall;
        input [31:0] exp_matvec_start;
        input [31:0] exp_matvec_done;
        input [31:0] exp_matvec_busy;
    begin
        check_word("cycle_count", cycle_count, exp_cycle);
        check_word("retired_count", retired_count, exp_retired);
        check_word("branch_miss_count", branch_miss_count, exp_branch);
        check_word("icache_miss_count", icache_miss_count, exp_icache);
        check_word("dcache_miss_count", dcache_miss_count, exp_dcache);
        check_word("stall_cycle_count", stall_cycle_count, exp_stall);
        check_word("matvec_start_count", matvec_start_count, exp_matvec_start);
        check_word("matvec_done_count", matvec_done_count, exp_matvec_done);
        check_word("matvec_busy_cycle_count", matvec_busy_cycle_count, exp_matvec_busy);
    end
    endtask

    initial begin
        clear_events();
        reset = 1'b1;

        tick();
        check_all(32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);

        reset = 1'b0;
        tick();
        check_all(32'd1, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);

        retire_event = 1'b1;
        tick();
        clear_events();
        check_all(32'd2, 32'd1, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);

        branch_mispredict_event = 1'b1;
        tick();
        clear_events();
        check_all(32'd3, 32'd1, 32'd1, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        if (dut.branch_mispredict_event_capture !== 1'b1) begin
            $display("FAIL: accepted branch miss was not captured for the next counter cycle");
            $fatal;
        end

        icache_miss_event = 1'b1;
        tick();
        clear_events();
        check_all(32'd4, 32'd1, 32'd1, 32'd1, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        if (dut.branch_mispredict_event_capture !== 1'b0) begin
            $display("FAIL: branch miss capture did not clear after a one-cycle event");
            $fatal;
        end

        dcache_miss_event = 1'b1;
        tick();
        clear_events();
        check_all(32'd5, 32'd1, 32'd1, 32'd1, 32'd1, 32'd0, 32'd0, 32'd0, 32'd0);

        stall_event = 1'b1;
        tick();
        clear_events();
        check_all(32'd6, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd0, 32'd0, 32'd0);

        matvec_start_accepted_event = 1'b1;
        tick();
        clear_events();
        check_all(32'd7, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd0, 32'd0);

        matvec_done_rise_event = 1'b1;
        tick();
        clear_events();
        check_all(32'd8, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd0);

        matvec_busy = 1'b1;
        tick();
        tick();
        clear_events();
        check_all(32'd10, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd1, 32'd2);

        retire_event = 1'b1;
        branch_mispredict_event = 1'b1;
        icache_miss_event = 1'b1;
        dcache_miss_event = 1'b1;
        stall_event = 1'b1;
        matvec_start_accepted_event = 1'b1;
        matvec_done_rise_event = 1'b1;
        matvec_busy = 1'b1;
        tick();
        clear_events();
        check_all(32'd11, 32'd2, 32'd2, 32'd2, 32'd2, 32'd2, 32'd2, 32'd2, 32'd3);

        tick();
        check_all(32'd12, 32'd2, 32'd2, 32'd2, 32'd2, 32'd2, 32'd2, 32'd2, 32'd3);

        // Consecutive registered events remain consecutive increments; no
        // edge is collapsed into a level.
        branch_mispredict_event = 1'b1;
        tick();
        check_word("back_to_back first increment", branch_miss_count, 32'd3);
        tick();
        check_word("back_to_back second increment", branch_miss_count, 32'd4);
        clear_events();
        tick();
        check_word("back_to_back drained", branch_miss_count, 32'd4);

        // The registered event preserves ordinary 32-bit rollover semantics.
        dut.branch_miss_count = 32'hffff_ffff;
        branch_mispredict_event = 1'b1;
        tick();
        check_word("rollover increment", branch_miss_count, 32'h0000_0000);
        clear_events();

        // Reset clears both the visible count and the assertion mirror.
        branch_mispredict_event = 1'b1;
        tick();
        if (dut.branch_mispredict_event_capture !== 1'b1) begin
            $display("FAIL: reset precondition did not capture pending branch miss");
            $fatal;
        end

        reset = 1'b1;
        tick();
        check_all(32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0);
        if (dut.branch_mispredict_event_capture !== 1'b0) begin
            $display("FAIL: reset did not clear pending branch miss capture");
            $fatal;
        end

        $display("PASS: tb_performance_counter_unit passed");
        $finish;
    end

endmodule
