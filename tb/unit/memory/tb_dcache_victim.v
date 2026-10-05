`timescale 1ns / 1ps

// Interface-driven scoreboard; each instance owns an independent backing RAM.
module dcache_victim_case #(
    parameter VICTIMS = 4,
    parameter PRIMARY_BYTES = 64,
    parameter WAIT_CYCLES = 3,
    parameter EXTERNAL = 1
)(output reg done = 0);
    reg clock = 0, reset = 1;
    always #5 clock = ~clock;
    reg valid = 0, reading = 0, writing = 0, mmio = 0;
    reg [31:0] addr = 0, store = 0;
    reg [2:0] funct3 = 2;
    wire complete, hit, miss, busy, load_valid;
    wire [31:0] loaded, ext_addr, wb_addr;
    wire ext_read, ext_write, wb_valid;
    wire [127:0] ext_wdata, wb_line;
    reg [127:0] ext_rdata = 0;
    reg ext_ready = 0;
    reg [31:0] snoop_addr = 0, snoop_data = 0;
    reg snoop_write = 0;
    wire snoop_hit;
    wire [31:0] snoop_word;
    reg [31:0] backing[0:4095];
    reg [31:0] expected[0:4095];
    wire [127:0] internal_line = {backing[{addr[13:4],2'b11}], backing[{addr[13:4],2'b10}],
                                  backing[{addr[13:4],2'b01}], backing[{addr[13:4],2'b00}]};
    integer backend_state = 0, delay_left = 0;
    reg [31:0] captured_addr;
    reg [127:0] captured_data;
    reg captured_write;
    integer i, j, probe_bit, accesses = 0, reads = 0, writes = 0;
    reg [31:0] random_state = 32'hbd917a35;
    reg [31:0] random_addr, random_value;
    reg [2:0] random_size;
    integer order_a, order_b;

    dcache_unit #(.USE_EXTERNAL_DMEM(EXTERNAL), .MEMORY_WORD_COUNT(4096),
                  .CACHE_BYTES(PRIMARY_BYTES), .VICTIM_LINES(VICTIMS)) dut (
        .clock(clock), .reset(reset), .request_valid(valid), .request_read(reading),
        .request_write(writing), .request_addr(addr), .request_funct3(funct3),
        .request_store_data(store), .request_mmio(mmio), .internal_refill_line(internal_line),
        .internal_writeback_valid(wb_valid), .internal_writeback_addr(wb_addr),
        .internal_writeback_line(wb_line), .external_rdata(ext_rdata), .external_ready(ext_ready),
        .dma_snoop_addr(snoop_addr), .dma_snoop_write(snoop_write),
        .dma_snoop_write_data(snoop_data), .dma_snoop_hit(snoop_hit), .dma_snoop_read_word(snoop_word),
        .hit(hit), .miss(miss), .request_complete(complete), .busy(busy), .external_wait(),
        .load_word_data(loaded), .load_word_valid(load_valid), .external_addr(ext_addr),
        .external_read(ext_read), .external_write(ext_write), .external_wdata(ext_wdata),
        .external_byte_enable(), .state_debug(), .stall_debug(), .dirty_debug()
    );

    always @(posedge clock) begin
        if (!reset && VICTIMS > 0) begin
            for (order_a = 0; order_a < VICTIMS; order_a = order_a + 1) begin
                if ((^dut.victim_order[order_a]) === 1'bx || dut.victim_order[order_a] >= VICTIMS)
                    $fatal(1, "LRU way unknown or out of range");
                for (order_b = order_a+1; order_b < VICTIMS; order_b = order_b+1)
                    if (dut.victim_order[order_a] == dut.victim_order[order_b])
                        $fatal(1, "LRU order contains a duplicate way");
                if (dut.cache_state == 4 && dut.pending_victim_match[order_a] !==
                    (dut.victim_valid[order_a] && dut.victim_tag[order_a] == dut.pending_line_addr[31:4]))
                    $fatal(1, "captured victim match differs from pending request");
            end
        end
        if (reset) begin
            backend_state <= 0;
            ext_ready <= 0;
        end else begin
            if (wb_valid) begin
                for (j = 0; j < 4; j = j + 1)
                    backing[(wb_addr >> 2)+j] <= wb_line[32*j +: 32];
                writes <= writes + 1;
            end
            case (backend_state)
                0: if (ext_read || ext_write) begin
                    if (ext_read && ext_write) $fatal(1, "simultaneous backend read/write");
                    captured_addr <= ext_addr;
                    captured_data <= ext_wdata;
                    captured_write <= ext_write;
                    delay_left <= WAIT_CYCLES;
                    backend_state <= 1;
                end
                1: begin
                    if (ext_addr !== captured_addr || ext_write !== captured_write ||
                        (!ext_read && !ext_write) || (captured_write && ext_wdata !== captured_data))
                        $fatal(1, "backend request changed under backpressure");
                    if (delay_left != 0) delay_left <= delay_left - 1;
                    else begin
                        if (captured_write) begin
                            for (j = 0; j < 4; j = j + 1)
                                backing[(captured_addr >> 2)+j] <= captured_data[32*j +: 32];
                            writes <= writes + 1;
                        end else begin
                            ext_rdata <= {backing[(captured_addr >> 2)+3], backing[(captured_addr >> 2)+2],
                                          backing[(captured_addr >> 2)+1], backing[captured_addr >> 2]};
                            reads <= reads + 1;
                        end
                        ext_ready <= 1;
                        backend_state <= 2;
                    end
                end
                2: begin
                    ext_ready <= 0;
                    backend_state <= 0;
                end
            endcase
        end
    end

    task initialize;
        begin
            @(negedge clock);
            reset = 1;
            valid = 0;
            snoop_write = 0;
            repeat (3) @(negedge clock);
            for (i = 0; i < 4096; i = i + 1) begin
                backing[i] = 32'h193a578b ^ (i * 32'h10203);
                expected[i] = backing[i];
            end
            reset = 0;
        end
    endtask

    task access;
        input [31:0] a;
        input wr;
        input [2:0] size;
        input [31:0] value;
        integer wait_count, byte_count, byte_index;
        reg accepted;
        begin
            @(negedge clock);
            valid = 1;
            reading = !wr;
            writing = wr;
            addr = a;
            funct3 = size;
            store = value;
            accepted = 0;
            wait_count = 0;
            while (!accepted) begin
                @(posedge clock);
                if (complete) begin
                    if (!wr && (!load_valid || loaded !== expected[a >> 2]))
                        $fatal(1, "read mismatch victims=%0d ext=%0d address=%h expected=%h actual=%h",
                               VICTIMS, EXTERNAL, a, expected[a >> 2], loaded);
                    accepted = 1;
                end
                wait_count = wait_count + 1;
                if (wait_count > 100) $fatal(1, "request timeout");
            end
            if (wr) begin
                byte_count = 1 << size;
                for (byte_index = 0; byte_index < byte_count; byte_index = byte_index + 1)
                    expected[a >> 2][8*(a[1:0]+byte_index) +: 8] = value[8*byte_index +: 8];
            end
            accesses = accesses + 1;
            @(negedge clock);
            valid = 0;
            reading = 0;
            writing = 0;
        end
    endtask

    task dma_write;
        input [31:0] a;
        input [31:0] value;
        begin
            @(negedge clock);
            snoop_addr = a;
            #1;
            if (snoop_hit !== 1'b0 && snoop_hit !== 1'b1) $fatal(1, "unknown DMA snoop hit");
            if (snoop_hit && snoop_word !== expected[a >> 2]) $fatal(1, "DMA read sees stale cached data");
            if (!snoop_hit && backing[a >> 2] !== expected[a >> 2]) $fatal(1, "unreported dirty cached line");
            snoop_write = 1;
            snoop_data = value;
            @(posedge clock);
            #1;
            backing[a >> 2] = value;
            expected[a >> 2] = value;
            @(negedge clock);
            snoop_write = 0;
        end
    endtask

    initial begin
        initialize();
        // Fill every primary set, then confirm all are resident simultaneously.
        // In particular, index bit 6 must distinguish the upper four 128-B sets.
        for (i = 0; i < PRIMARY_BYTES/16; i = i + 1) access(i*16, 1, 2, 32'ha0000000+i);
        for (i = 0; i < PRIMARY_BYTES/16; i = i + 1) begin
            @(negedge clock);
            addr = i*16;
            valid = 1;
            reading = 1;
            #1;
            if (!hit || loaded !== 32'ha0000000+i) $fatal(1, "primary set alias at %h", addr);
            @(negedge clock);
            valid = 0;
            reading = 0;
        end
        // Every tag bit participates in both CPU and DMA lookup. Withdraw the
        // probes before a clock edge; this test does not allocate a 4-GiB RAM.
        for (probe_bit = $clog2(PRIMARY_BYTES); probe_bit < 32; probe_bit = probe_bit + 1) begin
            @(negedge clock);
            addr = 32'b1 << probe_bit;
            snoop_addr = addr;
            valid = 1;
            reading = 1;
            #1;
            if (hit || snoop_hit) $fatal(1, "tag bit %0d was ignored", probe_bit);
            valid = 0;
            reading = 0;
        end
        // Dirty swap, mixed store widths, and DMA to a line displaced from L1.
        access(0, 1, 2, 32'haabbccdd);
        access(PRIMARY_BYTES, 1, 2, 32'h12345678);
        dma_write(0, 32'h87654321);
        access(1, 1, 0, 32'haa);
        access(2, 1, 1, 32'hbeef);
        access(0, 0, 2, 0);
        for (i = 0; i < 16; i = i + 1) access(i*PRIMARY_BYTES, 1, 2, i*77);
        for (i = 15; i >= 0; i = i - 1) access(i*PRIMARY_BYTES, 0, 2, 0);
        for (i = 0; i < 600; i = i + 1) begin
            random_state = {random_state[30:0], random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            random_addr = (random_state[9:0] * 4);
            random_value = random_state ^ 32'hc891567a;
            random_size = i % 3;
            if (random_size == 0) random_addr = random_addr + (i % 4);
            if (random_size == 1) random_addr = random_addr + ((i % 2) * 2);
            access(random_addr, i % 4 != 0, random_size, random_value);
            if (i % 17 == 0) dma_write(random_addr & 32'hfffffffc, ~random_value);
            access(random_addr & 32'hfffffffc, 0, 2, 0);
        end
        for (i = 0; i < 1024; i = i + 1) access(i*4, 0, 2, 0);
        // MMIO must never touch either cache or issue a backend request.
        @(negedge clock);
        valid = 1;
        writing = 1;
        mmio = 1;
        repeat (3) begin
            @(posedge clock);
            if (hit || miss || complete || ext_read || ext_write) $fatal(1, "MMIO entered cache");
        end
        @(negedge clock);
        valid = 0;
        mmio = 0;
        // Abort an outstanding refill by reset; no old response may complete it.
        addr = 32'h2000;
        valid = 1;
        reading = 1;
        writing = 0;
        @(posedge clock);
        @(negedge clock);
        if (!busy) $fatal(1, "expected pending transaction before reset");
        initialize();
        access(32'h2000, 0, 2, 0);
        $display("PASS victim case primary=%0d lines=%0d external=%0d wait=%0d accesses=%0d reads=%0d writes=%0d",
                 PRIMARY_BYTES, VICTIMS, EXTERNAL, WAIT_CYCLES, accesses, reads, writes);
        done = 1;
    end
endmodule

module tb_dcache_victim;
    wire [11:0] done;
    dcache_victim_case #(.VICTIMS(0), .WAIT_CYCLES(0)) base(done[0]);
    dcache_victim_case #(.VICTIMS(1), .WAIT_CYCLES(1)) one(done[1]);
    dcache_victim_case #(.VICTIMS(2), .WAIT_CYCLES(3)) two(done[2]);
    dcache_victim_case #(.VICTIMS(4), .WAIT_CYCLES(7)) four(done[3]);
    dcache_victim_case #(.VICTIMS(8), .WAIT_CYCLES(2)) eight(done[4]);
    dcache_victim_case #(.VICTIMS(4), .EXTERNAL(0)) internal_ram(done[5]);
    dcache_victim_case #(.PRIMARY_BYTES(128), .VICTIMS(0), .WAIT_CYCLES(0)) large_base(done[6]);
    dcache_victim_case #(.PRIMARY_BYTES(128), .VICTIMS(1), .WAIT_CYCLES(1)) large_one(done[7]);
    dcache_victim_case #(.PRIMARY_BYTES(128), .VICTIMS(2), .WAIT_CYCLES(3)) large_two(done[8]);
    dcache_victim_case #(.PRIMARY_BYTES(128), .VICTIMS(4), .WAIT_CYCLES(7)) large_four(done[9]);
    dcache_victim_case #(.PRIMARY_BYTES(128), .VICTIMS(8), .WAIT_CYCLES(2)) large_eight(done[10]);
    dcache_victim_case #(.PRIMARY_BYTES(128), .VICTIMS(0), .EXTERNAL(0)) large_internal(done[11]);
    initial begin
        wait (&done);
        $display("PASS: victim cache widths, dirty swaps, LRU, waits, MMIO, DMA and reset");
        $finish;
    end
    initial begin
        #4000000;
        $fatal(1, "victim suite timeout");
    end
endmodule
