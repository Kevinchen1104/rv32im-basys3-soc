`timescale 1ns / 1ps

// Testbench: tb_dcache_unit
// Purpose: Checks a local memory-system block with directed transactions.
// Checks: Standalone data cache unit handles four-index full-tag lookup, read misses, hits, captured miss metadata,
//   store merging, dirty writeback, pending-store refill, MMIO bypass, DMA snoops, and external data-memory waits.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_dcache_unit;
    localparam CACHE_IDLE = 2'b00;
    localparam CACHE_WRITEBACK = 2'b01;
    localparam CACHE_MISS_WAIT = 2'b10;
    localparam CACHE_REFILL = 2'b11;

    reg clock;
    reg reset;
    reg request_valid;
    reg request_read;
    reg request_write;
    reg [31:0] request_addr;
    reg [2:0] request_funct3;
    reg [31:0] request_store_data;
    reg request_mmio;
    reg [127:0] internal_refill_line;
    reg [127:0] external_rdata;
    reg external_ready;
    reg [31:0] dma_snoop_addr;
    reg dma_snoop_write;
    reg [31:0] dma_snoop_write_data;

    wire internal_writeback_valid;
    wire [31:0] internal_writeback_addr;
    wire [127:0] internal_writeback_line;
    wire hit;
    wire miss;
    wire request_complete;
    wire busy;
    wire external_wait;
    wire [31:0] load_word_data;
    wire load_word_valid;
    wire [31:0] external_addr;
    wire external_read;
    wire external_write;
    wire [127:0] external_wdata;
    wire [15:0] external_byte_enable;
    wire [1:0] state_debug;
    wire [1:0] stall_debug;
    wire [3:0] dirty_debug;
    wire dma_snoop_hit;
    wire [31:0] dma_snoop_read_word;

    reg ext_request_valid;
    reg ext_request_read;
    reg ext_request_write;
    reg [31:0] ext_request_addr;
    reg [2:0] ext_request_funct3;
    reg [31:0] ext_request_store_data;
    reg ext_request_mmio;
    reg [127:0] ext_external_rdata;
    reg ext_external_ready;

    wire ext_hit;
    wire ext_miss;
    wire ext_request_complete;
    wire ext_busy;
    wire ext_external_wait;
    wire [31:0] ext_load_word_data;
    wire ext_load_word_valid;
    wire [31:0] ext_external_addr;
    wire ext_external_read;
    wire ext_external_write;
    wire [127:0] ext_external_wdata;
    wire [15:0] ext_external_byte_enable;
    wire [1:0] ext_state_debug;
    wire [1:0] ext_stall_debug;
    wire [3:0] ext_dirty_debug;
    integer ext_miss_pulse_count;
    integer start_miss_count;

    dcache_unit #(
        .USE_EXTERNAL_DMEM(0),
        .MEMORY_WORD_COUNT(1024)
    ) dut (
        .clock(clock),
        .reset(reset),
        .request_valid(request_valid),
        .request_read(request_read),
        .request_write(request_write),
        .request_addr(request_addr),
        .request_funct3(request_funct3),
        .request_store_data(request_store_data),
        .request_mmio(request_mmio),
        .internal_refill_line(internal_refill_line),
        .internal_writeback_valid(internal_writeback_valid),
        .internal_writeback_addr(internal_writeback_addr),
        .internal_writeback_line(internal_writeback_line),
        .external_rdata(external_rdata),
        .external_ready(external_ready),
        .dma_snoop_addr(dma_snoop_addr),
        .dma_snoop_write(dma_snoop_write),
        .dma_snoop_write_data(dma_snoop_write_data),
        .dma_snoop_hit(dma_snoop_hit),
        .dma_snoop_read_word(dma_snoop_read_word),
        .hit(hit),
        .miss(miss),
        .request_complete(request_complete),
        .busy(busy),
        .external_wait(external_wait),
        .load_word_data(load_word_data),
        .load_word_valid(load_word_valid),
        .external_addr(external_addr),
        .external_read(external_read),
        .external_write(external_write),
        .external_wdata(external_wdata),
        .external_byte_enable(external_byte_enable),
        .state_debug(state_debug),
        .stall_debug(stall_debug),
        .dirty_debug(dirty_debug)
    );

    dcache_unit #(
        .USE_EXTERNAL_DMEM(1),
        .MEMORY_WORD_COUNT(1024)
    ) ext_dut (
        .clock(clock),
        .reset(reset),
        .request_valid(ext_request_valid),
        .request_read(ext_request_read),
        .request_write(ext_request_write),
        .request_addr(ext_request_addr),
        .request_funct3(ext_request_funct3),
        .request_store_data(ext_request_store_data),
        .request_mmio(ext_request_mmio),
        .internal_refill_line(128'h0),
        .internal_writeback_valid(),
        .internal_writeback_addr(),
        .internal_writeback_line(),
        .external_rdata(ext_external_rdata),
        .external_ready(ext_external_ready),
        .dma_snoop_addr(32'h0),
        .dma_snoop_write(1'b0),
        .dma_snoop_write_data(32'h0),
        .dma_snoop_hit(),
        .dma_snoop_read_word(),
        .hit(ext_hit),
        .miss(ext_miss),
        .request_complete(ext_request_complete),
        .busy(ext_busy),
        .external_wait(ext_external_wait),
        .load_word_data(ext_load_word_data),
        .load_word_valid(ext_load_word_valid),
        .external_addr(ext_external_addr),
        .external_read(ext_external_read),
        .external_write(ext_external_write),
        .external_wdata(ext_external_wdata),
        .external_byte_enable(ext_external_byte_enable),
        .state_debug(ext_state_debug),
        .stall_debug(ext_stall_debug),
        .dirty_debug(ext_dirty_debug)
    );

    always #5 clock = ~clock;

    always @(posedge clock) begin
        if (reset)
            ext_miss_pulse_count <= 0;
        else if (ext_miss)
            ext_miss_pulse_count <= ext_miss_pulse_count + 1;
    end

    task fail;
        input [8*160-1:0] msg;
        begin
            $display("FAIL: %0s", msg);
            $fatal(1);
        end
    endtask

    task tick;
        begin
            @(posedge clock);
            #1;
        end
    endtask

    task clear_internal_request;
        begin
            request_valid = 1'b0;
            request_read = 1'b0;
            request_write = 1'b0;
            request_mmio = 1'b0;
            request_funct3 = 3'b010;
            request_store_data = 32'h0;
        end
    endtask

    task clear_external_request;
        begin
            ext_request_valid = 1'b0;
            ext_request_read = 1'b0;
            ext_request_write = 1'b0;
            ext_request_mmio = 1'b0;
            ext_request_funct3 = 3'b010;
            ext_request_store_data = 32'h0;
        end
    endtask

    task wait_internal_fill;
        integer guard;
        begin
            guard = 0;
            while (load_word_valid !== 1'b1 && guard < 20) begin
                tick();
                guard = guard + 1;
            end
            if (load_word_valid !== 1'b1) begin
                fail("internal fill timed out");
            end
            tick();
        end
    endtask

    task wait_internal_idle;
        integer guard;
        begin
            guard = 0;
            while (state_debug !== CACHE_IDLE && guard < 20) begin
                tick();
                guard = guard + 1;
            end
            if (state_debug !== CACHE_IDLE) begin
                fail("internal cache idle wait timed out");
            end
        end
    endtask

    task wait_external_state;
        input [1:0] expected_state;
        integer guard;
        begin
            guard = 0;
            while (ext_state_debug !== expected_state && guard < 20) begin
                tick();
                guard = guard + 1;
            end
            if (ext_state_debug !== expected_state) begin
                fail("external state wait timed out");
            end
        end
    endtask

    task fill_internal_read;
        input [31:0] addr;
        input [127:0] line;
        begin
            internal_refill_line = line;
            request_addr = addr;
            request_valid = 1'b1;
            request_read = 1'b1;
            request_write = 1'b0;
            request_mmio = 1'b0;
            #1;
            wait_internal_fill();
        end
    endtask

    task request_write_hit;
        input [31:0] addr;
        input [31:0] data;
        input [2:0] funct3;
        begin
            request_addr = addr;
            request_store_data = data;
            request_funct3 = funct3;
            request_valid = 1'b1;
            request_read = 1'b0;
            request_write = 1'b1;
            request_mmio = 1'b0;
            #1;
            if (hit !== 1'b1) begin
                fail("expected write hit");
            end
            tick();
        end
    endtask

    task check_read_hit_word;
        input [31:0] addr;
        input [31:0] expected_word;
        begin
            request_addr = addr;
            request_valid = 1'b1;
            request_read = 1'b1;
            request_write = 1'b0;
            request_mmio = 1'b0;
            #1;
            if (hit !== 1'b1 || request_complete !== 1'b1 || load_word_valid !== 1'b1 || load_word_data !== expected_word) begin
                $display("INFO: read hit addr=%h expected=%h hit=%0b valid=%0b data=%h state=%0d",
                         addr, expected_word, hit, load_word_valid, load_word_data, state_debug);
                fail("read hit word mismatch");
            end
        end
    endtask

    task reset_both;
        begin
            reset = 1'b1;
            clear_internal_request();
            clear_external_request();
            request_addr = 32'h0;
            ext_request_addr = 32'h0;
            internal_refill_line = 128'h0;
            external_rdata = 128'h0;
            external_ready = 1'b1;
            dma_snoop_addr = 32'h0;
            dma_snoop_write = 1'b0;
            dma_snoop_write_data = 32'h0;
            ext_external_rdata = 128'h0;
            ext_external_ready = 1'b0;
            tick();
            tick();
            reset = 1'b0;
            tick();
        end
    endtask

    initial begin
        clock = 1'b0;
        reset = 1'b0;
        clear_internal_request();
        clear_external_request();
        request_addr = 32'h0;
        ext_request_addr = 32'h0;
        internal_refill_line = 128'h0;
        external_rdata = 128'h0;
        external_ready = 1'b1;
        dma_snoop_addr = 32'h0;
        dma_snoop_write = 1'b0;
        dma_snoop_write_data = 32'h0;
        ext_external_rdata = 128'h0;
        ext_external_ready = 1'b0;
        ext_miss_pulse_count = 0;

        reset_both();
        if (busy || state_debug !== CACHE_IDLE || stall_debug !== 2'b00 || dirty_debug !== 4'b0000) begin
            fail("reset did not leave internal cache idle and clean");
        end
        if (ext_busy || ext_state_debug !== CACHE_IDLE || ext_dirty_debug !== 4'b0000) begin
            fail("reset did not leave external cache idle and clean");
        end

        fill_internal_read(32'h0000_0000, 128'h4444_4444_3333_3333_2222_2222_1111_1111);
        check_read_hit_word(32'h0000_0000, 32'h1111_1111);
        check_read_hit_word(32'h0000_0008, 32'h3333_3333);

        request_write_hit(32'h0000_0004, 32'haaaa_5555, 3'b010);
        if (dirty_debug[0] !== 1'b1) begin
            fail("write hit did not set dirty");
        end
        check_read_hit_word(32'h0000_0004, 32'haaaa_5555);

        request_write_hit(32'h0000_0004, 32'h0000_00ee, 3'b000);
        check_read_hit_word(32'h0000_0004, 32'haaaa_55ee);

        request_write_hit(32'h0000_0006, 32'h0000_beef, 3'b001);
        check_read_hit_word(32'h0000_0004, 32'hbeef_55ee);

        internal_refill_line = 128'hdddd_dddd_cccc_cccc_bbbb_bbbb_aaaa_aaaa;
        request_addr = 32'h0000_0040;
        request_valid = 1'b1;
        request_read = 1'b1;
        request_write = 1'b0;
        request_mmio = 1'b0;
        tick();
        if (state_debug !== CACHE_WRITEBACK || !internal_writeback_valid) begin
            fail("dirty eviction did not enter writeback");
        end
        if (internal_writeback_addr !== 32'h0000_0000) begin
            fail("dirty eviction writeback address mismatch");
        end
        if (internal_writeback_line !== 128'h4444_4444_3333_3333_beef_55ee_1111_1111) begin
            fail("dirty eviction writeback line mismatch");
        end
        wait_internal_fill();
        check_read_hit_word(32'h0000_0040, 32'haaaa_aaaa);

        clear_internal_request();
        tick();
        internal_refill_line = 128'h0000_0004_0000_0003_0000_0002_0000_0001;
        request_addr = 32'h0000_0088;
        request_store_data = 32'hffff_0000;
        request_funct3 = 3'b010;
        request_valid = 1'b1;
        request_read = 1'b0;
        request_write = 1'b1;
        request_mmio = 1'b0;
        tick();
        wait_internal_idle();
        check_read_hit_word(32'h0000_0088, 32'hffff_0000);
        if (dirty_debug[0] !== 1'b1) begin
            fail("write miss pending store did not set dirty after refill");
        end

        clear_internal_request();
        tick();
        request_addr = 32'h0000_0200;
        request_valid = 1'b1;
        request_read = 1'b1;
        request_write = 1'b0;
        request_mmio = 1'b1;
        #1;
        if (hit || miss || busy || load_word_valid) begin
            fail("MMIO request affected internal cache");
        end

        reset_both();
        ext_external_rdata = 128'h4444_0004_3333_0003_2222_0002_1111_0001;
        ext_request_addr = 32'h0000_0000;
        ext_request_valid = 1'b1;
        ext_request_read = 1'b1;
        ext_request_write = 1'b0;
        ext_request_mmio = 1'b0;
        tick();
        wait_external_state(CACHE_REFILL);
        if (ext_miss_pulse_count != 1) begin
            fail("external miss did not pulse exactly once per accepted transaction");
        end
        if (!ext_external_read || !ext_external_wait || ext_load_word_valid) begin
            fail("external read miss did not wait for ready");
        end
        ext_external_ready = 1'b1;
        #1;
        if (!ext_load_word_valid || ext_load_word_data !== 32'h1111_0001) begin
            fail("external refill did not expose load word");
        end
        tick();
        if (ext_busy) begin
            fail("external refill did not return idle");
        end

        ext_request_store_data = 32'hdead_beef;
        ext_request_funct3 = 3'b010;
        ext_request_read = 1'b0;
        ext_request_write = 1'b1;
        ext_request_addr = 32'h0000_0004;
        if (!ext_hit) begin
            fail("external write hit setup failed");
        end
        tick();
        ext_external_ready = 1'b0;
        ext_external_rdata = 128'h8888_0004_7777_0003_6666_0002_5555_0001;
        ext_request_addr = 32'h0000_0040;
        ext_request_read = 1'b1;
        ext_request_write = 1'b0;
        tick();
        wait_external_state(CACHE_WRITEBACK);
        if (!ext_external_write || !ext_external_wait) begin
            fail("external dirty writeback did not wait for ready");
        end
        if (ext_external_wdata !== 128'h4444_0004_3333_0003_dead_beef_1111_0001) begin
            fail("external dirty writeback line mismatch");
        end
        ext_external_ready = 1'b1;
        tick();
        wait_external_state(CACHE_REFILL);
        #1;
        if (!ext_external_read) begin
            fail("external dirty eviction did not advance to refill");
        end
        tick();

        // Fill all four direct-mapped indices with the same tag. Parallel tag
        // matches must still select data only from the requested index.
        reset_both();
        fill_internal_read(32'h0000_0000, 128'h0000_0004_0000_0003_0000_0002_0000_0001);
        fill_internal_read(32'h0000_0010, 128'h0000_0014_0000_0013_0000_0012_0000_0011);
        fill_internal_read(32'h0000_0020, 128'h0000_0024_0000_0023_0000_0022_0000_0021);
        fill_internal_read(32'h0000_0030, 128'h0000_0034_0000_0033_0000_0032_0000_0031);
        check_read_hit_word(32'h0000_0000, 32'h0000_0001);
        check_read_hit_word(32'h0000_0014, 32'h0000_0012);
        check_read_hit_word(32'h0000_0028, 32'h0000_0023);
        check_read_hit_word(32'h0000_003c, 32'h0000_0034);

        // A different full 26-bit tag at the same index, including a high tag
        // bit, must not alias an existing line.
        request_addr = 32'h0000_0040;
        #1;
        if (hit || !miss) begin
            fail("same-index different tag did not miss");
        end
        request_addr = 32'h8000_0000;
        #1;
        if (hit || !miss) begin
            fail("high tag bit aliased a resident cache line");
        end
        clear_internal_request();
        tick();

        // DMA snoop lookup uses the complete tag and updates only a resident
        // matching word.
        dma_snoop_addr = 32'h0000_0024;
        #1;
        if (!dma_snoop_hit || dma_snoop_read_word !== 32'h0000_0022) begin
            fail("DMA snoop tag hit/read mismatch");
        end
        dma_snoop_write_data = 32'hfeed_cafe;
        dma_snoop_write = 1'b1;
        tick();
        dma_snoop_write = 1'b0;
        check_read_hit_word(32'h0000_0024, 32'hfeed_cafe);
        dma_snoop_addr = 32'h8000_0024;
        #1;
        if (dma_snoop_hit) begin
            fail("DMA snoop high-tag miss aliased a resident line");
        end

        // A clean external miss captures its address, read type, and word
        // offset. Live CPU request changes while busy must not redirect it.
        reset_both();
        start_miss_count = ext_miss_pulse_count;
        ext_external_rdata = 128'h4444_0004_3333_0003_2222_0002_1111_0001;
        ext_external_ready = 1'b0;
        ext_request_addr = 32'h0000_0008;
        ext_request_valid = 1'b1;
        ext_request_read = 1'b1;
        ext_request_write = 1'b0;
        tick();
        ext_request_addr = 32'h0000_0033;
        ext_request_read = 1'b0;
        ext_request_write = 1'b1;
        ext_request_store_data = 32'haaaa_aaaa;
        ext_request_funct3 = 3'b000;
        wait_external_state(CACHE_REFILL);
        repeat (3) begin
            if (!ext_external_read || ext_external_addr !== 32'h0000_0000 ||
                ext_request_complete || ext_load_word_valid ||
                ext_miss_pulse_count != start_miss_count + 1) begin
                fail("clean external miss did not retain captured metadata or one-shot miss");
            end
            tick();
        end
        ext_external_ready = 1'b1;
        #1;
        if (!ext_request_complete || !ext_load_word_valid ||
            ext_load_word_data !== 32'h3333_0003) begin
            fail("clean external miss returned live-request word instead of captured word");
        end
        tick();
        clear_external_request();
        ext_external_ready = 1'b0;
        ext_request_addr = 32'h0000_0008;
        ext_request_valid = 1'b1;
        ext_request_read = 1'b1;
        #1;
        if (!ext_hit || !ext_request_complete ||
            ext_load_word_data !== 32'h3333_0003) begin
            fail("captured clean refill did not update the original index/tag");
        end

        // Dirty writeback and refill addresses/data must use accepted-miss
        // metadata even when all live request fields change during the wait.
        ext_request_addr = 32'h0000_0004;
        ext_request_read = 1'b0;
        ext_request_write = 1'b1;
        ext_request_store_data = 32'hdead_beef;
        ext_request_funct3 = 3'b010;
        tick();
        start_miss_count = ext_miss_pulse_count;
        ext_external_rdata = 128'h8888_0004_7777_0003_6666_0002_5555_0001;
        ext_external_ready = 1'b0;
        ext_request_addr = 32'h0000_0040;
        ext_request_read = 1'b1;
        ext_request_write = 1'b0;
        tick();
        ext_request_addr = 32'h0000_0093;
        ext_request_read = 1'b0;
        ext_request_write = 1'b1;
        ext_request_store_data = 32'h0000_00aa;
        ext_request_funct3 = 3'b000;
        if (!ext_external_write || ext_request_complete ||
            ext_external_addr !== 32'h0000_0000 ||
            ext_external_wdata !== 128'h4444_0004_3333_0003_dead_beef_1111_0001) begin
            fail("dirty victim writeback did not use captured address/index/data");
        end
        repeat (2) begin
            if (ext_miss_pulse_count != start_miss_count + 1) begin
                fail("dirty external miss pulsed more than once while busy");
            end
            tick();
        end
        ext_external_ready = 1'b1;
        tick();
        ext_external_ready = 1'b0;
        wait_external_state(CACHE_REFILL);
        if (!ext_external_read || ext_external_addr !== 32'h0000_0040) begin
            fail("dirty miss refill address followed live request");
        end
        repeat (2) tick();
        ext_external_ready = 1'b1;
        #1;
        if (!ext_request_complete || !ext_load_word_valid ||
            ext_load_word_data !== 32'h5555_0001) begin
            fail("dirty miss refill did not preserve accepted read metadata");
        end
        tick();
        clear_external_request();
        ext_external_ready = 1'b0;

        // A store miss captures byte offset, funct3, and data independently of
        // later live request values.
        start_miss_count = ext_miss_pulse_count;
        ext_external_rdata = 128'h0000_0004_0000_0003_0000_0002_1122_3344;
        ext_request_addr = 32'h0000_0093;
        ext_request_store_data = 32'h0000_00aa;
        ext_request_funct3 = 3'b000;
        ext_request_valid = 1'b1;
        ext_request_read = 1'b0;
        ext_request_write = 1'b1;
        tick();
        ext_request_addr = 32'h0000_0020;
        ext_request_store_data = 32'hffff_ffff;
        ext_request_funct3 = 3'b010;
        wait_external_state(CACHE_REFILL);
        if (ext_external_addr !== 32'h0000_0090 ||
            ext_miss_pulse_count != start_miss_count + 1) begin
            fail("store miss did not retain line address or one-shot miss");
        end
        repeat (2) tick();
        ext_external_ready = 1'b1;
        #1;
        if (!ext_request_complete) begin
            fail("store miss did not complete with accepted refill");
        end
        tick();
        clear_external_request();
        ext_external_ready = 1'b0;
        ext_request_addr = 32'h0000_0090;
        ext_request_valid = 1'b1;
        ext_request_read = 1'b1;
        #1;
        if (!ext_hit || !ext_request_complete ||
            ext_load_word_data !== 32'haa22_3344) begin
            fail("captured byte store miss merge mismatch");
        end

        // Back-to-back accepted transactions remain ordered, and reset can
        // cancel a delayed pending refill without emitting a response.
        clear_external_request();
        start_miss_count = ext_miss_pulse_count;
        ext_request_addr = 32'h0000_00a0;
        ext_request_valid = 1'b1;
        ext_request_read = 1'b1;
        tick();
        wait_external_state(CACHE_REFILL);
        if (ext_miss_pulse_count != start_miss_count + 1) begin
            fail("back-to-back transaction was not accepted exactly once");
        end
        clear_external_request();
        reset = 1'b1;
        tick();
        if (ext_busy || ext_miss || ext_load_word_valid || ext_state_debug !== CACHE_IDLE) begin
            fail("reset did not cancel pending external miss");
        end
        clear_external_request();
        reset = 1'b0;
        tick();

        ext_request_addr = 32'h0000_0200;
        ext_request_valid = 1'b1;
        ext_request_read = 1'b1;
        ext_request_mmio = 1'b1;
        #1;
        if (ext_hit || ext_miss || ext_busy || ext_load_word_valid) begin
            fail("external MMIO request affected cache state or miss count");
        end

        $display("PASS: tb_dcache_unit passed");
        $finish;
    end
endmodule
