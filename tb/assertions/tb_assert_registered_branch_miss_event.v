`timescale 1ns / 1ps

// Testbench: tb_assert_registered_branch_miss_event
// Purpose: Checks that accepted branch misses become one registered pulse before counter increment.
// Checks: Registered-event/counter cycle timing, stalled raw mismatch rejection, single acceptance on release, correctly
//   predicted branch exclusion, JAL miss exclusion, and unchanged visible branch-miss totals.
// Pass condition: Every cycle matches capture(t)=accepted_branch_miss(t-1) and count increments only from capture.
// Does not prove: Directed CPU scenario plus cycle monitor only; separate bounded formal covers arbitrary event inputs.
// Assertion focus: Registered accepted branch-miss performance-counter event semantics.

module tb_assert_registered_branch_miss_event;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;
    reg sampled_accept;
    reg sampled_registered_event;
    reg sampled_capture;
    reg sampled_raw;
    reg sampled_stall;
    reg sampled_control_accept;
    reg sampled_branch;
    reg sampled_jump;
    reg sampled_jump_raw;
    reg [31:0] sampled_count;
    reg [31:0] sampled_pc;
    integer accepted_branch_miss_count = 0;
    integer registered_branch_miss_event_count = 0;
    integer counter_increment_count = 0;
    reg saw_stalled_raw = 1'b0;
    reg saw_release_accept = 1'b0;
    reg saw_correct_prediction = 1'b0;
    reg saw_jump_miss = 1'b0;

    always @(posedge clock) begin
        if (checking_enabled) begin
            sampled_accept = dut.branch_mispredict;
            sampled_registered_event = dut.branch_mispredict_event;
            sampled_capture =
                dut.gen_performance_counters.performance_counter_inst.branch_mispredict_event_capture;
            sampled_raw = dut.branch_mispredict_raw;
            sampled_stall = dut.dcache_pipeline_stall;
            sampled_control_accept = dut.control_resolution_accept;
            sampled_branch = dut.IDEXBranch;
            sampled_jump = dut.IDEXJump;
            sampled_jump_raw = dut.jump_mispredict_raw;
            sampled_count = dut.BranchMissCount;
            sampled_pc = dut.IDEXPC;

            #1;

            if (dut.gen_performance_counters.performance_counter_inst.branch_mispredict_event_capture !==
                sampled_registered_event) begin
                $display("FAIL: capture expected registered event=%0b got %0b at PC %h",
                    sampled_registered_event,
                    dut.gen_performance_counters.performance_counter_inst.branch_mispredict_event_capture,
                    sampled_pc);
                $fatal;
            end

            if (dut.BranchMissCount !==
                (sampled_count + (sampled_registered_event ? 32'd1 : 32'd0))) begin
                $display("FAIL: counter timing old=%0d event=%0b new=%0d at PC %h",
                    sampled_count, sampled_registered_event,
                    dut.BranchMissCount, sampled_pc);
                $fatal;
            end

            if (sampled_accept) begin
                accepted_branch_miss_count = accepted_branch_miss_count + 1;
                if (sampled_pc == 32'd8) begin
                    saw_release_accept = 1'b1;
                end
            end
            if (sampled_registered_event) begin
                registered_branch_miss_event_count =
                    registered_branch_miss_event_count + 1;
            end
            if (sampled_registered_event) begin
                counter_increment_count = counter_increment_count + 1;
            end

            if (sampled_raw && sampled_stall && !sampled_accept && (sampled_pc == 32'd8)) begin
                saw_stalled_raw = 1'b1;
            end

            if (sampled_control_accept && sampled_branch && !sampled_raw) begin
                saw_correct_prediction = 1'b1;
                if (sampled_accept) begin
                    $display("FAIL: correctly predicted branch generated a miss event");
                    $fatal;
                end
            end

            if (sampled_control_accept && sampled_jump && sampled_jump_raw) begin
                saw_jump_miss = 1'b1;
                if (sampled_accept) begin
                    $display("FAIL: JAL/JALR prediction miss changed branch-only counter meaning");
                    $fatal;
                end
            end
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_registered_branch_miss_event.vcd");
        $dumpvars(0, tb_assert_registered_branch_miss_event);
        reset_cpu();

        if (dut.BranchMissCount !== 32'd0 ||
            dut.gen_performance_counters.performance_counter_inst.branch_mispredict_event_capture !== 1'b0) begin
            $display("FAIL: reset did not clear branch-miss count/capture");
            $fatal;
        end

        dut.DMemory[16] = 32'h600d_cafe;
        dut.IMemory[0] = i_type(12'd55, 5'd0, 3'b000, 5'd2, 7'b0010011);    // x2 = marker
        dut.IMemory[1] = i_type(12'd64, 5'd0, 3'b010, 5'd10, 7'b0000011);   // lw miss/stall
        dut.IMemory[2] = b_type(20, 5'd0, 5'd0, 3'b000, 7'b1100011);        // cold taken branch -> PC 28
        dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);    // wrong branch path
        dut.IMemory[4] = s_type(12'd0, 5'd2, 5'd0, 3'b010, 7'b0100011);     // wrong branch store
        dut.IMemory[5] = i_type(12'd5, 5'd0, 3'b000, 5'd5, 7'b0010011);     // wrong branch marker
        dut.IMemory[6] = i_type(12'd6, 5'd0, 3'b000, 5'd6, 7'b0010011);     // wrong branch marker
        dut.IMemory[7] = j_type(8, 5'd0, 7'b1101111);                       // cold JAL -> PC 36
        dut.IMemory[8] = i_type(12'd88, 5'd0, 3'b000, 5'd8, 7'b0010011);    // wrong jump path
        dut.IMemory[9] = i_type(12'd3, 5'd0, 3'b000, 5'd3, 7'b0010011);     // loop count = 3
        dut.IMemory[10] = i_type(12'hfff, 5'd3, 3'b000, 5'd3, 7'b0010011);  // x3--
        dut.IMemory[11] = b_type(-4, 5'd0, 5'd3, 3'b001, 7'b1100011);       // warmed bne -> PC 40
        dut.IMemory[12] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);   // final marker

        checking_enabled = 1'b1;
        run_cycles(240);
        checking_enabled = 1'b0;

        if (!saw_stalled_raw || !saw_release_accept ||
            !saw_correct_prediction || !saw_jump_miss) begin
            $display("FAIL: missing observations stalled_raw=%0b release=%0b correct=%0b jump=%0b",
                saw_stalled_raw, saw_release_accept, saw_correct_prediction, saw_jump_miss);
            $fatal;
        end
        if (accepted_branch_miss_count != registered_branch_miss_event_count ||
            registered_branch_miss_event_count != counter_increment_count ||
            dut.BranchMissCount !== accepted_branch_miss_count ||
            dut.perf_branch_miss_count !== accepted_branch_miss_count) begin
            $display("FAIL: totals accepted=%0d registered=%0d increments=%0d internal=%0d public=%0d",
                accepted_branch_miss_count, registered_branch_miss_event_count,
                counter_increment_count,
                dut.BranchMissCount, dut.perf_branch_miss_count);
            $fatal;
        end

        check_reg(2, 32'd55);
        check_reg(3, 32'd0);
        check_reg(6, 32'd6);
        check_reg(7, 32'd77);
        check_reg(8, 32'd8);
        check_reg(10, 32'h600d_cafe);
        if (dut.DMemory[0] !== 32'h0) begin
            $display("FAIL: wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
            $fatal;
        end

        $display("PASS: accepted branch misses became registered pulses and counted exactly one cycle later");
        $display("PASS: stalled raw mismatch, correct prediction, and jump miss did not add branch counts");
        $display("PASS: tb_assert_registered_branch_miss_event passed");
        $finish;
    end

endmodule
