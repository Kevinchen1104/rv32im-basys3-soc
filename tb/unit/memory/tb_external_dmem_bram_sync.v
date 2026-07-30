`timescale 1ns / 1ps

// Testbench: tb_external_dmem_bram_sync
// Purpose: Checks the one-outstanding synchronous external-DMEM line-memory protocol.
// Checks: Initialization packing, request/response latency, held requests, byte enables, partial writes, reset cancellation, and simulation mirror consistency.
// Pass condition: Every transaction produces one correctly timed response and all line/mirror data checks match.

module tb_external_dmem_bram_sync;

    localparam WORD_COUNT = 16;

    reg clock = 1'b0;
    reg reset = 1'b0;
    reg [31:0] dmem_addr = 32'h0;
    reg dmem_read = 1'b0;
    reg dmem_write = 1'b0;
    reg [127:0] dmem_wdata = 128'h0;
    reg [15:0] dmem_byte_enable = 16'h0;
    wire [127:0] dmem_rdata;
    wire dmem_ready;
    wire read_seen;
    wire write_seen;

    integer accepted_count = 0;
    integer accepted_reads = 0;
    integer accepted_writes = 0;
    integer lane;
    integer start_count;
    reg [127:0] expected_line;
    reg [127:0] lane_data;
    reg [15:0] lane_enable;

    external_dmem_bram #(
        .WORD_COUNT(WORD_COUNT),
        .SIM_INIT_HEX("fixtures/memory/bram_init.hex"),
        .SIM_INIT_WORD_COUNT(4)
    ) dut (
        .clock(clock),
        .reset(reset),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
        .read_seen(read_seen),
        .write_seen(write_seen)
    );

    always #5 clock = ~clock;

    always @(posedge clock) begin
        if (!reset && (dut.state == dut.STATE_IDLE) && (dmem_read || dmem_write)) begin
            accepted_count = accepted_count + 1;
            if (dmem_write)
                accepted_writes = accepted_writes + 1;
            else
                accepted_reads = accepted_reads + 1;
        end
    end

    task reset_interface;
        begin
            dmem_read = 1'b0;
            dmem_write = 1'b0;
            dmem_addr = 32'h0;
            dmem_wdata = 128'h0;
            dmem_byte_enable = 16'h0;
            reset = 1'b1;
            repeat (2) @(posedge clock);
            #1;
            if (dmem_ready || read_seen || write_seen) begin
                $display("FAIL: reset did not clear protocol state ready=%0b read_seen=%0b write_seen=%0b",
                         dmem_ready, read_seen, write_seen);
                $fatal;
            end
            reset = 1'b0;
            repeat (2) @(posedge clock);
            #1;
            if (dmem_ready || read_seen || write_seen) begin
                $display("FAIL: idle cycles changed ready/seen state");
                $fatal;
            end
        end
    endtask

    task read_line;
        input [31:0] address;
        input [127:0] expected;
        begin
            @(negedge clock);
            start_count = accepted_count;
            dmem_addr = address;
            dmem_read = 1'b1;
            dmem_write = 1'b0;
            dmem_byte_enable = 16'h0;
            #1;
            if (dmem_ready) begin
                $display("FAIL: read request asserted ready before acceptance");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dmem_ready || !read_seen || (accepted_count != start_count + 1)) begin
                $display("FAIL: read acceptance timing ready=%0b seen=%0b accepted=%0d",
                         dmem_ready, read_seen, accepted_count - start_count);
                $fatal;
            end

            @(posedge clock);
            #1;
            if (!dmem_ready || (dmem_rdata !== expected)) begin
                $display("FAIL: read response expected %h got ready=%0b data=%h",
                         expected, dmem_ready, dmem_rdata);
                $fatal;
            end

            // Keep request asserted through the response-consumption edge.
            // The memory must not accept it a second time.
            @(posedge clock);
            #1;
            if (dmem_ready || (accepted_count != start_count + 1)) begin
                $display("FAIL: read ready width or held-request suppression mismatch");
                $fatal;
            end
            @(negedge clock);
            dmem_read = 1'b0;
        end
    endtask

    task write_line;
        input [31:0] address;
        input [127:0] data;
        input [15:0] byte_enable;
        begin
            @(negedge clock);
            start_count = accepted_count;
            dmem_addr = address;
            dmem_wdata = data;
            dmem_byte_enable = byte_enable;
            dmem_read = 1'b0;
            dmem_write = 1'b1;
            #1;
            if (dmem_ready) begin
                $display("FAIL: write request asserted ready before acceptance");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dmem_ready || !write_seen || (accepted_count != start_count + 1)) begin
                $display("FAIL: write acceptance timing ready=%0b seen=%0b accepted=%0d",
                         dmem_ready, write_seen, accepted_count - start_count);
                $fatal;
            end

            @(posedge clock);
            #1;
            if (!dmem_ready) begin
                $display("FAIL: write response was not asserted on schedule");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dmem_ready || (accepted_count != start_count + 1)) begin
                $display("FAIL: write ready width or held-request suppression mismatch");
                $fatal;
            end
            @(negedge clock);
            dmem_write = 1'b0;
            dmem_byte_enable = 16'h0;
        end
    endtask

    initial begin
        $dumpfile("wave/tb_external_dmem_bram_sync.vcd");
        $dumpvars(0, tb_external_dmem_bram_sync);

        reset_interface();

        // SIM_INIT_HEX word ordering maps word zero to the low 32 bits.
        expected_line = 128'hffff_ffff_0000_0000_aabb_ccdd_1122_3344;
        read_line(32'h0000_0000, expected_line);
        if (dut.memory[0] !== 32'h1122_3344 ||
            dut.memory[1] !== 32'haabb_ccdd ||
            dut.memory[2] !== 32'h0000_0000 ||
            dut.memory[3] !== 32'hffff_ffff ||
            dut.line_memory[0] !== expected_line) begin
            $display("FAIL: SIM_INIT_HEX line packing or simulation mirror mismatch");
            $fatal;
        end

        // Consecutive completed requests may target a different line without
        // stale response data leaking from the prior line.
        write_line(32'h0000_0010, 128'h4444_4444_3333_3333_2222_2222_1111_1111, 16'hffff);
        read_line(32'h0000_0010, 128'h4444_4444_3333_3333_2222_2222_1111_1111);
        read_line(32'h0000_0000, expected_line);

        // High address bits must not alias an existing BRAM line. Out-of-range
        // reads complete with zero and writes are ignored.
        write_line(32'h0000_1000, 128'hffff_ffff_eeee_eeee_dddd_dddd_cccc_cccc, 16'hffff);
        read_line(32'h0000_1000, 128'h0);
        read_line(32'h0000_0000, expected_line);
        if (dut.line_memory[0] !== expected_line ||
            dut.memory[0] !== expected_line[31:0]) begin
            $display("FAIL: out-of-range write aliased line zero");
            $fatal;
        end

        // Exercise every byte lane independently on line two.
        write_line(32'h0000_0020, 128'h0, 16'hffff);
        expected_line = 128'h0;
        for (lane = 0; lane < 16; lane = lane + 1) begin
            lane_data = 128'h0;
            lane_data[(lane * 8) +: 8] = 8'h80 + lane;
            lane_enable = 16'h0001 << lane;
            write_line(32'h0000_0020, lane_data, lane_enable);
            expected_line[(lane * 8) +: 8] = 8'h80 + lane;
        end
        read_line(32'h0000_0020, expected_line);
        if (dut.memory[8] !== expected_line[31:0] ||
            dut.memory[9] !== expected_line[63:32] ||
            dut.memory[10] !== expected_line[95:64] ||
            dut.memory[11] !== expected_line[127:96]) begin
            $display("FAIL: 16-lane byte writes diverged from simulation mirror");
            $fatal;
        end

        // Multiple nonadjacent bytes merge into one existing line.
        lane_data = 128'h0;
        lane_data[7:0] = 8'haa;
        lane_data[47:40] = 8'hbb;
        lane_data[87:80] = 8'hcc;
        lane_data[127:120] = 8'hdd;
        expected_line[7:0] = 8'haa;
        expected_line[47:40] = 8'hbb;
        expected_line[87:80] = 8'hcc;
        expected_line[127:120] = 8'hdd;
        write_line(32'h0000_0020, lane_data, 16'h8421);
        read_line(32'h0000_0020, expected_line);

        // Reset cancels an accepted read before EXECUTE without clearing RAM.
        @(negedge clock);
        dmem_addr = 32'h0000_0020;
        dmem_read = 1'b1;
        @(posedge clock);
        #1;
        if (!read_seen || dmem_ready) begin
            $display("FAIL: pending read was not accepted before reset");
            $fatal;
        end
        @(negedge clock);
        reset = 1'b1;
        @(posedge clock);
        #1;
        if (dmem_ready || read_seen || write_seen ||
            (dut.line_memory[2] !== expected_line)) begin
            $display("FAIL: reset did not cancel response cleanly or changed memory");
            $fatal;
        end
        @(negedge clock);
        dmem_read = 1'b0;
        reset = 1'b0;
        read_line(32'h0000_0020, expected_line);

        // Simultaneous read/write is explicitly write-priority and counts as
        // one accepted write transaction.
        reset_interface();
        @(negedge clock);
        start_count = accepted_count;
        dmem_addr = 32'h0000_0030;
        dmem_wdata = 128'hdddd_dddd_cccc_cccc_bbbb_bbbb_aaaa_aaaa;
        dmem_byte_enable = 16'hffff;
        dmem_read = 1'b1;
        dmem_write = 1'b1;
        @(posedge clock);
        #1;
        if (read_seen || !write_seen || (accepted_count != start_count + 1)) begin
            $display("FAIL: simultaneous read/write did not use write priority");
            $fatal;
        end
        @(posedge clock);
        #1;
        if (!dmem_ready) begin
            $display("FAIL: write-priority transaction did not respond");
            $fatal;
        end
        @(posedge clock);
        #1;
        @(negedge clock);
        dmem_read = 1'b0;
        dmem_write = 1'b0;
        read_line(32'h0000_0030, 128'hdddd_dddd_cccc_cccc_bbbb_bbbb_aaaa_aaaa);

        if (accepted_reads == 0 || accepted_writes < 20) begin
            $display("FAIL: accepted transaction monitor counts reads=%0d writes=%0d",
                     accepted_reads, accepted_writes);
            $fatal;
        end

        $display("PASS: synchronous external DMEM handshake, byte lanes, initialization, and mirror matched");
        $display("PASS: tb_external_dmem_bram_sync passed");
        $finish;
    end

endmodule
