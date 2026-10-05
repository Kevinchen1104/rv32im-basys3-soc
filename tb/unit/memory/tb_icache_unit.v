`timescale 1ns / 1ps

// Testbench: tb_icache_unit
// Purpose: Checks a local memory-system block with directed transactions.
// Checks: Standalone instruction cache covers grouped tag lookup, balanced word selection, replacement,
//   captured refills, redirect cancellation, reset, and external instruction-memory waits.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_icache_unit;

    reg clock;
    reg reset;

    reg [31:0] pc_int;
    reg [127:0] internal_line_data;
    reg cancel_refill_int;
    wire [31:0] instruction_int;
    wire return_hint_int;
    wire return_hint_ext;
    wire miss_int;
    wire busy_int;
    wire external_read_int;
    wire [31:0] refill_addr_int;
    wire [1:0] state_debug_int;
    wire [1:0] stall_debug_int;
    wire lru_set0_int;
    wire lru_set1_int;

    reg [31:0] pc_ext;
    reg [127:0] external_line_data;
    reg external_ready;
    reg cancel_refill_ext;
    wire [31:0] instruction_ext;
    wire miss_ext;
    wire busy_ext;
    wire external_read_ext;
    wire [31:0] refill_addr_ext;
    wire [1:0] state_debug_ext;
    wire [1:0] stall_debug_ext;
    wire lru_set0_ext;
    wire lru_set1_ext;

    icache_unit #(
        .USE_EXTERNAL_IMEM(0)
    ) internal_cache (
        .clock(clock),
        .reset(reset),
        .pc(pc_int),
        .internal_line_data(internal_line_data),
        .external_line_data(128'h0),
        .external_ready(1'b0),
        .cancel_refill(cancel_refill_int),
        .instruction(instruction_int),
        .return_hint(return_hint_int),
        .miss(miss_int),
        .busy(busy_int),
        .external_read(external_read_int),
        .refill_addr(refill_addr_int),
        .state_debug(state_debug_int),
        .stall_debug(stall_debug_int),
        .lru_set0_debug(lru_set0_int),
        .lru_set1_debug(lru_set1_int)
    );

    icache_unit #(
        .USE_EXTERNAL_IMEM(1)
    ) external_cache (
        .clock(clock),
        .reset(reset),
        .pc(pc_ext),
        .internal_line_data(128'h0),
        .external_line_data(external_line_data),
        .external_ready(external_ready),
        .cancel_refill(cancel_refill_ext),
        .instruction(instruction_ext),
        .return_hint(return_hint_ext),
        .miss(miss_ext),
        .busy(busy_ext),
        .external_read(external_read_ext),
        .refill_addr(refill_addr_ext),
        .state_debug(state_debug_ext),
        .stall_debug(stall_debug_ext),
        .lru_set0_debug(lru_set0_ext),
        .lru_set1_debug(lru_set1_ext)
    );

    initial begin
        clock = 1'b0;
        forever #5 clock = ~clock;
    end

    function [127:0] line;
        input [31:0] word0;
        input [31:0] word1;
        input [31:0] word2;
        input [31:0] word3;
    begin
        line = {word3, word2, word1, word0};
    end
    endfunction

    function [31:0] cache_pc;
        input [26:0] tag_value;
        input set_value;
        input [1:0] word_value;
    begin
        cache_pc = {tag_value, set_value, word_value, 2'b00};
    end
    endfunction

    task tick;
    begin
        @(posedge clock);
        #1;
    end
    endtask

    // Check metadata against the selected instruction throughout hits,
    // refills, replacement, redirects, and reset transitions.
    always @(negedge clock) begin
        if (reset === 1'b0) begin
            if (return_hint_int !== ((instruction_int & 32'hffff_8fff) == 32'h0000_8067) ||
                return_hint_ext !== ((instruction_ext & 32'hffff_8fff) == 32'h0000_8067))
                $fatal(1, "return predecode differs from selected instruction");
        end
    end

    task check_bool;
        input [255:0] name;
        input actual;
        input expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %0d got %0d", name, expected, actual);
            $fatal;
        end
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

    task wait_internal_refill;
    begin
        tick();
        check_bool("internal cache busy after miss accept", busy_int, 1'b1);
        check_word("internal refill stall starts at 2", {30'h0, stall_debug_int}, 32'd2);
        tick();
        tick();
        tick();
        check_bool("internal cache idle after refill", busy_int, 1'b0);
        check_bool("internal hit clears miss", miss_int, 1'b0);
    end
    endtask

    task wait_external_refill;
    begin
        tick();
        check_bool("external cache busy after miss accept", busy_ext, 1'b1);
        check_bool("external read asserted while waiting", external_read_ext, 1'b1);
        external_ready = 1'b0;
        tick();
        check_bool("external cache holds while not ready", busy_ext, 1'b1);
        check_bool("external read remains asserted", external_read_ext, 1'b1);
        external_ready = 1'b1;
        tick();
        check_bool("external cache idle after refill", busy_ext, 1'b0);
        check_bool("external hit clears miss", miss_ext, 1'b0);
    end
    endtask

    initial begin
        pc_int = 32'h0000_0000;
        pc_ext = 32'h0000_0080;
        internal_line_data = line(32'h1111_0000, 32'h1111_0001, 32'h1111_0002, 32'h1111_0003);
        external_line_data = line(32'heeee_0000, 32'heeee_0001, 32'heeee_0002, 32'heeee_0003);
        external_ready = 1'b0;
        cancel_refill_int = 1'b0;
        cancel_refill_ext = 1'b0;
        reset = 1'b1;

        tick();
        check_word("reset internal instruction is NOP", instruction_int, 32'h0000_0013);
        check_bool("reset internal miss with empty cache", miss_int, 1'b1);
        check_bool("reset internal busy low", busy_int, 1'b0);
        check_word("reset internal state", {30'h0, state_debug_int}, 32'd0);
        check_word("reset internal stall", {30'h0, stall_debug_int}, 32'd0);
        check_bool("reset internal lru set0", lru_set0_int, 1'b0);
        check_bool("reset internal lru set1", lru_set1_int, 1'b0);

        reset = 1'b0;
        #1;
        check_bool("internal initial miss", miss_int, 1'b1);
        check_word("internal miss returns NOP", instruction_int, 32'h0000_0013);
        wait_internal_refill();
        check_bool("first invalid selection filled set0 way0", internal_cache.valid[0][0], 1'b1);
        check_bool("set0 way1 remains invalid", internal_cache.valid[0][1], 1'b0);
        check_word("internal offset 0", instruction_int, 32'h1111_0000);

        pc_int = 32'h0000_0004;
        #1;
        check_word("internal offset 1", instruction_int, 32'h1111_0001);
        pc_int = 32'h0000_0008;
        #1;
        check_word("internal offset 2", instruction_int, 32'h1111_0002);
        pc_int = 32'h0000_000c;
        #1;
        check_word("internal offset 3", instruction_int, 32'h1111_0003);
        check_bool("hit does not assert miss", miss_int, 1'b0);

        pc_int = 32'h0000_0020;
        internal_line_data = line(32'h2222_0000, 32'h2222_0001, 32'h2222_0002, 32'h2222_0003);
        #1;
        check_bool("same-set second tag misses", miss_int, 1'b1);
        wait_internal_refill();
        check_bool("second invalid selection filled set0 way1", internal_cache.valid[0][1], 1'b1);
        check_word("same-set second tag hits", instruction_int, 32'h2222_0000);

        pc_int = 32'h0000_0000;
        #1;
        check_word("first tag still hits in other way", instruction_int, 32'h1111_0000);
        tick();
        check_bool("way0 hit makes lru set0 choose way1", lru_set0_int, 1'b1);

        pc_int = 32'h0000_0020;
        #1;
        check_word("second tag still hits", instruction_int, 32'h2222_0000);
        tick();
        check_bool("way1 hit makes lru set0 choose way0", lru_set0_int, 1'b0);

        pc_int = 32'h0000_0040;
        internal_line_data = line(32'h3333_0000, 32'h3333_0001, 32'h3333_0002, 32'h3333_0003);
        #1;
        check_bool("third same-set tag misses", miss_int, 1'b1);
        wait_internal_refill();
        check_word("third tag hits after LRU refill", instruction_int, 32'h3333_0000);

        pc_int = 32'h0000_0000;
        #1;
        check_bool("LRU replaced first tag", miss_int, 1'b1);
        pc_int = 32'h0000_0020;
        #1;
        check_word("second tag survived LRU refill", instruction_int, 32'h2222_0000);

        reset = 1'b1;
        tick();
        reset = 1'b0;
        pc_int = 32'h0000_0020;
        #1;
        check_word("reset clears previous valid lines", instruction_int, 32'h0000_0013);
        check_bool("reset makes previous line miss", miss_int, 1'b1);

        pc_ext = 32'h0000_0080;
        external_ready = 1'b0;
        external_line_data = line(32'heeee_0000, 32'heeee_0001, 32'heeee_0002, 32'heeee_0003);
        #1;
        check_bool("external initial miss", miss_ext, 1'b1);
        check_word("external miss returns NOP", instruction_ext, 32'h0000_0013);
        tick();
        check_bool("external cache busy after miss accept", busy_ext, 1'b1);
        check_bool("external read asserted while waiting", external_read_ext, 1'b1);
        check_word("external refill captures request address", refill_addr_ext, 32'h0000_0080);
        pc_ext = 32'h0000_00a0;
        external_ready = 1'b0;
        #1;
        check_word("external refill address ignores live PC", refill_addr_ext, 32'h0000_0080);
        check_bool("miss remains low outside idle", miss_ext, 1'b0);
        check_word("changed PC during miss still returns NOP", instruction_ext, 32'h0000_0013);
        tick();
        check_bool("external cache holds while not ready", busy_ext, 1'b1);
        check_bool("external read remains asserted", external_read_ext, 1'b1);
        check_word("external refill address remains stable", refill_addr_ext, 32'h0000_0080);
        external_ready = 1'b1;
        tick();
        check_bool("external cache idle after refill", busy_ext, 1'b0);
        check_bool("new live PC misses after original refill", miss_ext, 1'b1);
        pc_ext = 32'h0000_0080;
        #1;
        check_bool("original refill address subsequently hits", miss_ext, 1'b0);
        check_word("external refill word 0", instruction_ext, 32'heeee_0000);
        pc_ext = 32'h0000_008c;
        #1;
        check_word("external refill word 3", instruction_ext, 32'heeee_0003);

        pc_ext = 32'h0000_0100;
        external_ready = 1'b0;
        #1;
        check_bool("redirected external request starts as miss", miss_ext, 1'b1);
        tick();
        cancel_refill_ext = 1'b1;
        pc_ext = 32'h0000_0120;
        tick();
        cancel_refill_ext = 1'b0;
        external_ready = 1'b1;
        tick();
        check_bool("redirected external refill is discarded", miss_ext, 1'b1);
        pc_ext = 32'h0000_0100;
        #1;
        check_bool("cancelled line remains invalid", miss_ext, 1'b1);

        reset = 1'b1;
        tick();
        reset = 1'b0;
        internal_cache.valid[0][0] = 1'b1;
        internal_cache.valid[0][1] = 1'b1;
        internal_cache.valid[1][0] = 1'b1;
        internal_cache.valid[1][1] = 1'b1;
        internal_cache.tag[0][0] = 27'h0123456;
        internal_cache.tag[0][1] = 27'h0123457;
        internal_cache.tag[1][0] = 27'h0223456;
        internal_cache.tag[1][1] = 27'h0223457;
        internal_cache.data[0][0][2] = 32'ha000_0002;
        internal_cache.data[0][1][1] = 32'hb000_0001;
        internal_cache.data[1][0][3] = 32'hc000_0003;
        internal_cache.data[1][1][0] = 32'hd000_0000;

        pc_int = cache_pc(27'h0123456, 1'b0, 2'd2);
        #1;
        check_word("set0 way0 hit", instruction_int, 32'ha000_0002);
        pc_int = cache_pc(27'h0123457, 1'b0, 2'd1);
        #1;
        check_word("set0 way1 hit", instruction_int, 32'hb000_0001);
        pc_int = cache_pc(27'h0223456, 1'b1, 2'd3);
        #1;
        check_word("set1 way0 hit", instruction_int, 32'hc000_0003);
        pc_int = cache_pc(27'h0223457, 1'b1, 2'd0);
        #1;
        check_word("set1 way1 hit", instruction_int, 32'hd000_0000);

        internal_cache.valid[0][1] = 1'b0;
        pc_int = cache_pc(27'h0123456 ^ 27'h4000000, 1'b0, 2'd0);
        #1;
        check_bool("high tag group mismatch", miss_int, 1'b1);
        pc_int = cache_pc(27'h0123456 ^ 27'h0002000, 1'b0, 2'd0);
        #1;
        check_bool("middle tag group mismatch", miss_int, 1'b1);
        pc_int = cache_pc(27'h0123456 ^ 27'h0000001, 1'b0, 2'd0);
        #1;
        check_bool("low tag group mismatch", miss_int, 1'b1);

        internal_cache.valid[0][1] = 1'b1;
        internal_cache.tag[0][1] = 27'h0123456;
        internal_cache.data[0][0][0] = 32'haaaa_0000;
        internal_cache.data[0][1][0] = 32'hbbbb_0000;
        pc_int = cache_pc(27'h0123456, 1'b0, 2'd0);
        #1;
        check_word("duplicate tag preserves way1 priority", instruction_int, 32'hbbbb_0000);
        tick();
        check_bool("duplicate way1 hit preserves LRU behavior", lru_set0_int, 1'b0);

        reset = 1'b1;
        tick();
        check_bool("final reset clears set0 way0", internal_cache.valid[0][0], 1'b0);
        check_bool("final reset clears set0 way1", internal_cache.valid[0][1], 1'b0);
        check_bool("final reset clears set1 way0", internal_cache.valid[1][0], 1'b0);
        check_bool("final reset clears set1 way1", internal_cache.valid[1][1], 1'b0);
        check_word("final reset clears captured refill address", refill_addr_int, 32'h0);

        reset = 1'b0;
        pc_int = 32'h0;
        internal_line_data = line(32'h0000_8067, 32'h0000_0013, 32'h0000_f067, 32'h0000_80e7);
        #1;
        wait_internal_refill();
        check_bool("canonical return metadata", return_hint_int, 1'b1);
        pc_int = 32'h4; #1;
        check_bool("NOP metadata", return_hint_int, 1'b0);
        pc_int = 32'h8; #1;
        check_bool("return query preserves funct3 handling", return_hint_int, 1'b1);
        pc_int = 32'hc; #1;
        check_bool("JALR with link is not return", return_hint_int, 1'b0);

        $display("PASS: tb_icache_unit passed");
        $finish;
    end

endmodule
