`timescale 1ns / 1ps

// Testbench: tb_branch_predictor_update_pipeline
// Purpose: Checks the registered branch-predictor update path independently of the CPU pipeline.
// Checks: Typed branch/JAL updates, one-cycle latency, registered suppression, BHT saturation, BTB writes, ordering, reset cancellation, and query/write overlap.
// Pass condition: Every table, pending-bundle, and prediction check completes without $fatal.

module tb_branch_predictor_update_pipeline;
    reg clock;
    reg reset;
    reg [31:0] fetch_pc;
    reg [31:0] fetch_instruction;
    wire predict_taken;
    wire [31:0] predicted_pc;
    reg update_valid;
    reg update_suppress;
    reg update_is_conditional;
    reg [31:0] update_pc;
    reg update_taken;
    reg [31:0] update_target;

    localparam [31:0] BRANCH_INSTRUCTION = 32'h0000_0063;
    localparam [31:0] JAL_INSTRUCTION = 32'h0000_006f;

    branch_predictor dut (
        .clock(clock),
        .reset(reset),
        .fetch_pc(fetch_pc),
        .fetch_instruction(fetch_instruction),
        .predict_taken(predict_taken),
        .predicted_pc(predicted_pc),
        .update_valid(update_valid),
        .update_suppress(update_suppress),
        .update_is_conditional(update_is_conditional),
        .update_pc(update_pc),
        .update_taken(update_taken),
        .update_target(update_target)
    );

    always #5 clock = ~clock;

    task fail;
        input [8*120-1:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal;
        end
    endtask

    task check_table;
        input integer index;
        input [1:0] expected_bht;
        input expected_valid;
        input [31:0] expected_target;
        begin
            if (dut.BHT[index] !== expected_bht ||
                dut.BTBValid[index] !== expected_valid ||
                dut.BTBTarget[index] !== expected_target) begin
                $display("FAIL: index %0d expected bht=%b valid=%b target=%h got bht=%b valid=%b target=%h",
                         index, expected_bht, expected_valid, expected_target,
                         dut.BHT[index], dut.BTBValid[index], dut.BTBTarget[index]);
                $fatal;
            end
        end
    endtask

    task pulse_update;
        input [31:0] pc;
        input taken;
        input [31:0] target;
        begin
            @(negedge clock);
            update_valid = 1'b1;
            update_is_conditional = 1'b1;
            update_pc = pc;
            update_taken = taken;
            update_target = target;
            @(posedge clock);
            #1;
            if (!dut.update_pending_valid ||
                dut.update_pending_is_conditional !== 1'b1 ||
                dut.update_pending_index !== pc[5:2] ||
                dut.update_pending_taken !== taken ||
                dut.update_pending_target !== target) begin
                fail("accepted update bundle was not captured");
            end
            @(negedge clock);
            update_valid = 1'b0;
        end
    endtask

    task issue_and_commit;
        input [31:0] pc;
        input taken;
        input [31:0] target;
        begin
            pulse_update(pc, taken, target);
            @(posedge clock);
            #1;
        end
    endtask

    task reset_predictor;
        begin
            @(negedge clock);
            reset = 1'b1;
            update_valid = 1'b0;
            update_suppress = 1'b0;
            update_is_conditional = 1'b1;
            repeat (2) @(posedge clock);
            @(negedge clock);
            reset = 1'b0;
            @(posedge clock);
            #1;
        end
    endtask

    integer i;
    initial begin
        $dumpfile("wave/tb_branch_predictor_update_pipeline.vcd");
        $dumpvars(0, tb_branch_predictor_update_pipeline);

        clock = 1'b0;
        reset = 1'b0;
        fetch_pc = 32'h0;
        fetch_instruction = BRANCH_INSTRUCTION;
        update_valid = 1'b0;
        update_suppress = 1'b0;
        update_is_conditional = 1'b1;
        update_pc = 32'h0;
        update_taken = 1'b0;
        update_target = 32'h0;

        reset_predictor();
        for (i = 0; i < 16; i = i + 1) begin
            check_table(i, 2'b01, 1'b0, 32'h0);
        end

        // Invalid cycles still refresh payload flops, but pending-valid keeps
        // those arbitrary values from changing either predictor table.
        @(negedge clock);
        update_valid = 1'b0;
        update_is_conditional = 1'b0;
        update_pc = 32'h0000_0024;
        update_taken = 1'b1;
        update_target = 32'hdead_beef;
        @(posedge clock);
        #1;
        if (dut.update_pending_valid !== 1'b0 ||
            dut.update_pending_is_conditional !== 1'b0 ||
            dut.update_pending_index !== 4'd9 ||
            dut.update_pending_taken !== 1'b1 ||
            dut.update_pending_target !== 32'hdead_beef) begin
            fail("invalid-cycle payload was not captured without validity");
        end
        check_table(9, 2'b01, 1'b0, 32'h0);

        @(negedge clock);
        update_is_conditional = 1'b1;
        update_pc = 32'h0000_0028;
        update_taken = 1'b0;
        update_target = 32'hcafe_babe;
        @(posedge clock);
        #1;
        if (dut.update_pending_valid !== 1'b0 ||
            dut.update_pending_index !== 4'd10 ||
            dut.update_pending_target !== 32'hcafe_babe) begin
            fail("consecutive invalid payload capture was not harmless");
        end
        check_table(9, 2'b01, 1'b0, 32'h0);
        check_table(10, 2'b01, 1'b0, 32'h0);

        // The core presents its registered instruction-misaligned event on
        // the commit cycle. Suppression cancels table side effects without
        // changing capture latency or the pending payload.
        pulse_update(32'h0000_000c, 1'b1, 32'h0000_0100);
        update_suppress = 1'b1;
        @(posedge clock);
        #1;
        check_table(3, 2'b01, 1'b0, 32'h0);
        @(negedge clock);
        update_suppress = 1'b0;

        // Capture does not modify tables; the following rising edge commits.
        fetch_pc = 32'h0000_0008;
        pulse_update(32'h0000_0008, 1'b1, 32'h0000_0100);
        check_table(2, 2'b01, 1'b0, 32'h0);
        if (predict_taken !== 1'b0 || predicted_pc !== 32'h0000_000c) begin
            fail("query observed a captured update before its commit edge");
        end
        @(posedge clock);
        #1;
        check_table(2, 2'b10, 1'b1, 32'h0000_0100);
        if (predict_taken !== 1'b1 || predicted_pc !== 32'h0000_0100) begin
            fail("query did not observe the committed taken update");
        end

        // Taken and not-taken updates saturate without clearing BTB metadata.
        issue_and_commit(32'h0000_0004, 1'b1, 32'h0000_0200);
        check_table(1, 2'b10, 1'b1, 32'h0000_0200);
        issue_and_commit(32'h0000_0004, 1'b1, 32'h0000_0204);
        check_table(1, 2'b11, 1'b1, 32'h0000_0204);
        issue_and_commit(32'h0000_0004, 1'b1, 32'h0000_0208);
        check_table(1, 2'b11, 1'b1, 32'h0000_0208);
        issue_and_commit(32'h0000_0004, 1'b0, 32'hdead_beef);
        check_table(1, 2'b10, 1'b1, 32'h0000_0208);
        issue_and_commit(32'h0000_0004, 1'b0, 32'hdead_beef);
        check_table(1, 2'b01, 1'b1, 32'h0000_0208);
        issue_and_commit(32'h0000_0004, 1'b0, 32'hdead_beef);
        check_table(1, 2'b00, 1'b1, 32'h0000_0208);
        issue_and_commit(32'h0000_0004, 1'b0, 32'hdead_beef);
        check_table(1, 2'b00, 1'b1, 32'h0000_0208);

        reset_predictor();

        // Back-to-back updates to one index commit in accepted order.
        @(negedge clock);
        update_valid = 1'b1;
        update_pc = 32'h0000_0008;
        update_taken = 1'b1;
        update_target = 32'h0000_0300;
        @(posedge clock);
        #1;
        check_table(2, 2'b01, 1'b0, 32'h0);
        @(negedge clock);
        update_target = 32'h0000_0304;
        @(posedge clock);
        #1;
        check_table(2, 2'b10, 1'b1, 32'h0000_0300);
        @(negedge clock);
        update_valid = 1'b0;
        @(posedge clock);
        #1;
        check_table(2, 2'b11, 1'b1, 32'h0000_0304);

        // Different indices can also be accepted on consecutive cycles.
        @(negedge clock);
        update_valid = 1'b1;
        update_pc = 32'h0000_000c;
        update_target = 32'h0000_0400;
        @(posedge clock);
        #1;
        @(negedge clock);
        update_pc = 32'h0000_0010;
        update_target = 32'h0000_0500;
        @(posedge clock);
        #1;
        check_table(3, 2'b10, 1'b1, 32'h0000_0400);
        check_table(4, 2'b01, 1'b0, 32'h0);
        @(negedge clock);
        update_valid = 1'b0;
        @(posedge clock);
        #1;
        check_table(4, 2'b10, 1'b1, 32'h0000_0500);

        // Valid/invalid/valid traffic commits only the two valid updates. The
        // invalid payload is captured between them but never reaches a table.
        reset_predictor();
        @(negedge clock);
        update_valid = 1'b1;
        update_is_conditional = 1'b1;
        update_pc = 32'h0000_0024;
        update_taken = 1'b1;
        update_target = 32'h0000_0900;
        @(posedge clock);
        @(negedge clock);
        update_valid = 1'b0;
        update_pc = 32'h0000_0028;
        update_target = 32'hdead_000a;
        @(posedge clock);
        #1;
        check_table(9, 2'b10, 1'b1, 32'h0000_0900);
        check_table(10, 2'b01, 1'b0, 32'h0);
        if (dut.update_pending_valid !== 1'b0 ||
            dut.update_pending_index !== 4'd10) begin
            fail("invalid middle cycle did not clear pending validity");
        end
        @(negedge clock);
        update_valid = 1'b1;
        update_pc = 32'h0000_002c;
        update_target = 32'h0000_0b00;
        @(posedge clock);
        #1;
        check_table(10, 2'b01, 1'b0, 32'h0);
        @(negedge clock);
        update_valid = 1'b0;
        @(posedge clock);
        #1;
        check_table(11, 2'b10, 1'b1, 32'h0000_0b00);

        // Same-index taken/not-taken updates commit on consecutive cycles in
        // order; the second direction update retains the older BTB target.
        reset_predictor();
        @(negedge clock);
        update_valid = 1'b1;
        update_is_conditional = 1'b1;
        update_pc = 32'h0000_0030;
        update_taken = 1'b1;
        update_target = 32'h0000_0c00;
        @(posedge clock);
        @(negedge clock);
        update_taken = 1'b0;
        update_target = 32'hdead_000c;
        @(posedge clock);
        #1;
        check_table(12, 2'b10, 1'b1, 32'h0000_0c00);
        @(negedge clock);
        update_valid = 1'b0;
        @(posedge clock);
        #1;
        check_table(12, 2'b01, 1'b1, 32'h0000_0c00);

        // Reset between capture and commit cancels the pending update.
        pulse_update(32'h0000_0014, 1'b1, 32'h0000_0600);
        reset = 1'b1;
        @(posedge clock);
        #1;
        if (dut.update_pending_valid !== 1'b0) fail("reset did not clear pending update");
        @(negedge clock);
        reset = 1'b0;
        @(posedge clock);
        #1;
        check_table(5, 2'b01, 1'b0, 32'h0);

        // A query sees old state before the commit edge and new state after it.
        issue_and_commit(32'h0000_0018, 1'b1, 32'h0000_0700);
        fetch_pc = 32'h0000_0018;
        #1;
        if (!predict_taken || predicted_pc !== 32'h0000_0700) begin
            fail("trained query did not predict taken");
        end
        pulse_update(32'h0000_0018, 1'b0, 32'hdead_beef);
        if (!predict_taken || predicted_pc !== 32'h0000_0700) begin
            fail("query changed before pending update commit");
        end
        @(posedge clock);
        #1;
        check_table(6, 2'b01, 1'b1, 32'h0000_0700);
        if (predict_taken || predicted_pc !== 32'h0000_001c) begin
            fail("query did not observe committed not-taken state");
        end

        // A cold direct JAL falls through until its registered update commits.
        reset_predictor();
        fetch_pc = 32'h0000_0020;
        fetch_instruction = JAL_INSTRUCTION;
        #1;
        if (predict_taken || predicted_pc !== 32'h0000_0024) begin
            fail("cold JAL predicted without a valid BTB entry");
        end

        @(negedge clock);
        update_valid = 1'b1;
        update_is_conditional = 1'b0;
        update_pc = 32'h0000_0020;
        update_taken = 1'b1;
        update_target = 32'h0000_0100;
        @(posedge clock);
        #1;
        check_table(8, 2'b01, 1'b0, 32'h0);
        if (!dut.update_pending_valid || dut.update_pending_is_conditional !== 1'b0) begin
            fail("JAL update kind was not captured");
        end
        @(negedge clock);
        update_valid = 1'b0;
        update_is_conditional = 1'b1;
        @(posedge clock);
        #1;
        check_table(8, 2'b01, 1'b1, 32'h0000_0100);
        if (!predict_taken || predicted_pc !== 32'h0000_0100) begin
            fail("warm JAL did not use its trained BTB target");
        end

        // Consecutive branch and JAL updates commit in accepted order.
        reset_predictor();
        @(negedge clock);
        update_valid = 1'b1;
        update_is_conditional = 1'b1;
        update_pc = 32'h0000_0004;
        update_taken = 1'b1;
        update_target = 32'h0000_0200;
        @(posedge clock);
        @(negedge clock);
        update_is_conditional = 1'b0;
        update_pc = 32'h0000_0008;
        update_target = 32'h0000_0300;
        @(posedge clock);
        #1;
        check_table(1, 2'b10, 1'b1, 32'h0000_0200);
        check_table(2, 2'b01, 1'b0, 32'h0);
        @(negedge clock);
        update_valid = 1'b0;
        update_is_conditional = 1'b1;
        @(posedge clock);
        #1;
        check_table(2, 2'b01, 1'b1, 32'h0000_0300);

        // A same-index JAL follows the older branch update without changing BHT.
        reset_predictor();
        @(negedge clock);
        update_valid = 1'b1;
        update_is_conditional = 1'b1;
        update_pc = 32'h0000_000c;
        update_taken = 1'b1;
        update_target = 32'h0000_0400;
        @(posedge clock);
        @(negedge clock);
        update_is_conditional = 1'b0;
        update_target = 32'h0000_0500;
        @(posedge clock);
        #1;
        check_table(3, 2'b10, 1'b1, 32'h0000_0400);
        @(negedge clock);
        update_valid = 1'b0;
        update_is_conditional = 1'b1;
        @(posedge clock);
        #1;
        check_table(3, 2'b10, 1'b1, 32'h0000_0500);

        // JAL prediction ignores a strongly not-taken BHT entry.
        reset_predictor();
        issue_and_commit(32'h0000_0010, 1'b0, 32'hdead_beef);
        check_table(4, 2'b00, 1'b0, 32'h0);
        @(negedge clock);
        update_valid = 1'b1;
        update_is_conditional = 1'b0;
        update_pc = 32'h0000_0010;
        update_taken = 1'b1;
        update_target = 32'h0000_0600;
        @(posedge clock);
        @(negedge clock);
        update_valid = 1'b0;
        update_is_conditional = 1'b1;
        @(posedge clock);
        #1;
        check_table(4, 2'b00, 1'b1, 32'h0000_0600);
        fetch_pc = 32'h0000_0010;
        fetch_instruction = JAL_INSTRUCTION;
        #1;
        if (!predict_taken || predicted_pc !== 32'h0000_0600) begin
            fail("JAL prediction incorrectly depended on BHT direction state");
        end

        // Reset between JAL capture and commit cancels the pending target write.
        @(negedge clock);
        update_valid = 1'b1;
        update_is_conditional = 1'b0;
        update_pc = 32'h0000_001c;
        update_target = 32'h0000_0700;
        @(posedge clock);
        @(negedge clock);
        reset = 1'b1;
        update_valid = 1'b0;
        @(posedge clock);
        #1;
        if (dut.update_pending_valid !== 1'b0) begin
            fail("reset did not cancel pending JAL update");
        end
        @(negedge clock);
        reset = 1'b0;
        update_is_conditional = 1'b1;
        @(posedge clock);
        #1;
        check_table(7, 2'b01, 1'b0, 32'h0);

        $display("PASS: predictor payload capture preserved valid-only commits, latency, BHT semantics, BTB ordering, reset, and query behavior");
        $display("PASS: tb_branch_predictor_update_pipeline passed");
        $finish;
    end
endmodule
