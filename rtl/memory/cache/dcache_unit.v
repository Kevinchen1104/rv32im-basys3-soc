`timescale 1ns / 1ps

// Module: dcache_unit
// Role: Small direct-mapped data cache with MMIO bypass and MATVEC DMA-lite snoop support.
// Interface: CPU memory request, internal/external refill/writeback line ports, DMA snoop port, and cache status/debug outputs.
// Key behavior: Handles hits, dirty writeback, refill, subword store merging, MMIO bypass, and DMA writes into cached words.

module dcache_unit #(
    parameter USE_EXTERNAL_DMEM = 0,
    parameter MEMORY_WORD_COUNT = 1024,
    parameter CACHE_BYTES = 64,
    parameter VICTIM_LINES = 0
) (
    input clock,
    input reset,

    input request_valid,
    input request_read,
    input request_write,
    input [31:0] request_addr,
    input [2:0] request_funct3,
    input [31:0] request_store_data,
    input request_mmio,

    input [127:0] internal_refill_line,
    output internal_writeback_valid,
    output [31:0] internal_writeback_addr,
    output [127:0] internal_writeback_line,

    input [127:0] external_rdata,
    input external_ready,
    input [31:0] dma_snoop_addr,
    input dma_snoop_write,
    input [31:0] dma_snoop_write_data,
    output dma_snoop_hit,
    output [31:0] dma_snoop_read_word,
    output hit,
    output miss,
    output request_complete,
    output busy,
    output external_wait,
    output [31:0] load_word_data,
    output load_word_valid,
    output [31:0] external_addr,
    output external_read,
    output external_write,
    output [127:0] external_wdata,
    output [15:0] external_byte_enable,
    output [1:0] state_debug,
    output [1:0] stall_debug,
    output [(CACHE_BYTES == 128 ? 8 : 4)-1:0] dirty_debug
);

    localparam CACHE_IDLE      = 3'b000;
    localparam CACHE_WRITEBACK = 3'b001;
    localparam CACHE_MISS_WAIT = 3'b010;
    localparam CACHE_REFILL    = 3'b011;
    localparam CACHE_VICTIM    = 3'b100;
    localparam VICTIM_STORAGE = VICTIM_LINES > 0 ? VICTIM_LINES : 1;
    localparam VICTIM_INDEX_WIDTH = VICTIM_STORAGE > 1 ? $clog2(VICTIM_STORAGE) : 1;
    localparam PRIMARY_LINES = CACHE_BYTES == 128 ? 8 : 4;
    localparam INDEX_WIDTH = $clog2(PRIMARY_LINES);
    localparam TAG_WIDTH = 28 - INDEX_WIDTH;

    reg [31:0] cache_data[0:PRIMARY_LINES-1][0:3];
    reg [TAG_WIDTH-1:0] cache_tag_store[0:PRIMARY_LINES-1];
    reg cache_valid[0:PRIMARY_LINES-1];
    reg cache_dirty[0:PRIMARY_LINES-1];

    reg [1:0] cache_stall;
    reg [2:0] cache_state;

    // Fully associative, exclusive victim buffer. Data stays in physical ways;
    // only the small MRU-to-LRU order vector moves when a line is replaced.
    reg [127:0] victim_data[0:VICTIM_STORAGE-1];
    reg [27:0] victim_tag[0:VICTIM_STORAGE-1];
    reg victim_valid[0:VICTIM_STORAGE-1];
    reg victim_dirty[0:VICTIM_STORAGE-1];
    reg [VICTIM_INDEX_WIDTH-1:0] victim_order[0:VICTIM_STORAGE-1];
    wire [VICTIM_STORAGE-1:0] victim_match;
    reg [VICTIM_STORAGE-1:0] pending_victim_match;
    reg victim_found, victim_snoop_found;
    reg [VICTIM_INDEX_WIDTH-1:0] victim_hit_index, victim_snoop_index;
    reg [VICTIM_INDEX_WIDTH-1:0] victim_hit_rank;
    wire [VICTIM_INDEX_WIDTH-1:0] victim_lru_index;
    wire [VICTIM_INDEX_WIDTH-1:0] victim_replace_index;
    wire victim_complete;
    wire victim_insert;
    wire [127:0] primary_victim_line;
    wire [127:0] incoming_line;
    wire primary_snoop_hit;
    integer lookup_entry, snoop_entry, order_entry, victim_entry;
    genvar victim_way, victim_word, primary_line, primary_word;

    reg [31:0] pending_line_addr;
    reg [31:0] pending_victim_addr;
    reg [TAG_WIDTH-1:0] pending_tag;
    reg [INDEX_WIDTH-1:0] pending_cache_index;
    reg [1:0] pending_word_offset;
    reg pending_read_valid;
    reg [127:0] pending_internal_refill_line;
    reg [31:0] pending_store_data;
    reg [1:0] pending_store_offset;
    reg [1:0] pending_store_byte_offset;
    reg [2:0] pending_store_funct3;
    reg pending_store_valid;

    wire [1:0] cache_byte_offset;
    wire [1:0] cache_word_offset;
    wire [INDEX_WIDTH-1:0] cache_index;
    wire [TAG_WIDTH-1:0] request_tag;
    wire [31:0] selected_victim_addr;
    wire [127:0] refill_line;
    wire [31:0] hit_word_data;
    wire [31:0] refill_selected_word;
    wire [31:0] pending_store_old_word;
    wire [31:0] hit_store_merged_value;
    wire [31:0] pending_store_merged_value;
    wire refill_ready;
    wire [1:0] dma_snoop_word_offset;
    wire [INDEX_WIDTH-1:0] dma_snoop_index;
    wire [TAG_WIDTH-1:0] dma_snoop_tag;
    wire selected_line_hit;
    wire [PRIMARY_LINES-1:0] primary_matches;

    integer i;

    assign cache_byte_offset = request_addr[1:0];
    assign cache_word_offset = request_addr[3:2];
    assign cache_index = request_addr[INDEX_WIDTH+3:4];
    assign request_tag = request_addr[31:INDEX_WIDTH+4];
    assign selected_victim_addr = {cache_tag_store[cache_index], cache_index, 4'b0000};
    assign refill_line = USE_EXTERNAL_DMEM ? external_rdata : pending_internal_refill_line;
    assign dma_snoop_word_offset = dma_snoop_addr[3:2];
    assign dma_snoop_index = dma_snoop_addr[INDEX_WIDTH+3:4];
    assign dma_snoop_tag = dma_snoop_addr[31:INDEX_WIDTH+4];

    generate
        if (VICTIM_LINES > 0) begin : victim_lookup
            // Compare in parallel with primary lookup, then capture on a miss.
            // Primary hits do not wait for these comparisons. The following
            // victim state consumes registered matches without another cycle.
            for (victim_way = 0; victim_way < VICTIM_LINES; victim_way = victim_way + 1) begin : way_compare
                assign victim_match[victim_way] = victim_valid[victim_way] &&
                    (victim_tag[victim_way] == request_addr[31:4]);
            end
            always @* begin
                victim_found = 1'b0;
                victim_hit_index = 0;
                victim_snoop_found = 1'b0;
                victim_snoop_index = 0;
                for (lookup_entry = 0; lookup_entry < VICTIM_LINES; lookup_entry = lookup_entry + 1) begin
                    if (pending_victim_match[lookup_entry]) begin
                        victim_found = 1'b1;
                        victim_hit_index = lookup_entry[VICTIM_INDEX_WIDTH-1:0];
                    end
                end
                victim_hit_rank = 0;
                for (order_entry = 0; order_entry < VICTIM_LINES; order_entry = order_entry + 1) begin
                    if (victim_order[order_entry] == victim_hit_index)
                        victim_hit_rank = order_entry[VICTIM_INDEX_WIDTH-1:0];
                end
                for (snoop_entry = 0; snoop_entry < VICTIM_LINES; snoop_entry = snoop_entry + 1) begin
                    if (victim_valid[snoop_entry] && victim_tag[snoop_entry] == dma_snoop_addr[31:4]) begin
                        victim_snoop_found = 1'b1;
                        victim_snoop_index = snoop_entry[VICTIM_INDEX_WIDTH-1:0];
                    end
                end
            end
        end else begin : no_victim_lookup
            assign victim_match = 0;
            assign victim_found = 1'b0;
            assign victim_hit_index = 0;
            assign victim_hit_rank = 0;
            assign victim_snoop_found = 1'b0;
            assign victim_snoop_index = 0;
        end
    endgenerate

    // Each physical way has decoded write enables. In particular, a DMA
    // word update does not read/merge/rewrite a dynamically indexed line.
    generate
        for (victim_way = 0; victim_way < VICTIM_STORAGE; victim_way = victim_way + 1) begin : victim_storage
            wire replace_way = (victim_complete || victim_insert) &&
                               (victim_replace_index == victim_way);
            wire snoop_way = dma_snoop_write && victim_snoop_found &&
                             (victim_snoop_index == victim_way);
            initial begin
                victim_valid[victim_way] = 1'b0;
                victim_dirty[victim_way] = 1'b0;
            end
            always @(posedge clock) begin
                if (reset) begin
                    victim_valid[victim_way] <= 1'b0;
                    victim_dirty[victim_way] <= 1'b0;
                end else begin
                    if (replace_way) begin
                        victim_tag[victim_way] <= {cache_tag_store[pending_cache_index], pending_cache_index};
                        victim_valid[victim_way] <= cache_valid[pending_cache_index];
                        victim_dirty[victim_way] <= cache_dirty[pending_cache_index];
                    end
                    if (snoop_way)
                        victim_dirty[victim_way] <= 1'b1;
                end
            end
            for (victim_word = 0; victim_word < 4; victim_word = victim_word + 1) begin : word_write
                always @(posedge clock) begin
                    if (!reset) begin
                        if (snoop_way && (dma_snoop_word_offset == victim_word))
                            victim_data[victim_way][32*victim_word +: 32] <= dma_snoop_write_data;
                        else if (replace_way)
                            victim_data[victim_way][32*victim_word +: 32] <= primary_victim_line[32*victim_word +: 32];
                    end
                end
            end
        end
    endgenerate

    // Share the refill/store merge across all primary lines, then write only
    // the selected word registers. DMA repair retains priority over CPU writes.
    generate
        for (primary_word = 0; primary_word < 4; primary_word = primary_word + 1) begin : primary_words
            wire [31:0] filled_word = pending_store_valid && (pending_store_offset == primary_word) ?
                pending_store_merged_value : incoming_line[32*primary_word +: 32];
            for (primary_line = 0; primary_line < PRIMARY_LINES; primary_line = primary_line + 1) begin : line_write
                initial cache_data[primary_line][primary_word] = 32'b0;
                always @(posedge clock) begin
                    if (reset)
                        cache_data[primary_line][primary_word] <= 32'b0;
                    else if (dma_snoop_write && primary_snoop_hit &&
                             (dma_snoop_index == primary_line) && (dma_snoop_word_offset == primary_word))
                        cache_data[primary_line][primary_word] <= dma_snoop_write_data;
                    else if ((refill_ready || victim_complete) && (pending_cache_index == primary_line))
                        cache_data[primary_line][primary_word] <= filled_word;
                    else if (hit && request_write && (cache_index == primary_line) && (cache_word_offset == primary_word))
                        cache_data[primary_line][primary_word] <= hit_store_merged_value;
                end
            end
        end
    endgenerate
    assign victim_lru_index = victim_order[VICTIM_STORAGE-1];
    assign victim_replace_index = victim_complete ? victim_hit_index : victim_lru_index;
    assign victim_complete = (VICTIM_LINES > 0) && (cache_state == CACHE_VICTIM) && victim_found;
    assign victim_insert = (VICTIM_LINES > 0) && cache_valid[pending_cache_index] &&
        (((cache_state == CACHE_VICTIM) && !victim_found &&
          !(victim_valid[victim_lru_index] && victim_dirty[victim_lru_index])) ||
         ((cache_state == CACHE_WRITEBACK) && (!USE_EXTERNAL_DMEM || external_ready)));
    assign primary_victim_line = {cache_data[pending_cache_index][3], cache_data[pending_cache_index][2],
                                  cache_data[pending_cache_index][1], cache_data[pending_cache_index][0]};
    // Select payload by state; validity/completion qualifies its consumption.
    assign incoming_line = (cache_state == CACHE_VICTIM) ? victim_data[victim_hit_index] : refill_line;

    // Compare tags in parallel rather than putting an indexed tag mux before
    // equality. Zero extension keeps the same LUT-sized groups at both sizes.
    generate
        for (primary_line = 0; primary_line < PRIMARY_LINES; primary_line = primary_line + 1) begin : primary_lookup
            (* keep = "true" *) wire [25:0] tag_xor;
            (* keep = "true" *) wire [4:0] tag_mismatch;
            assign tag_xor = {{(26-TAG_WIDTH){1'b0}}, (cache_tag_store[primary_line] ^ request_tag)};
            assign tag_mismatch = {|tag_xor[25:24], |tag_xor[23:18],
                                   |tag_xor[17:12], |tag_xor[11:6], |tag_xor[5:0]};
            assign primary_matches[primary_line] = (cache_index == primary_line) &&
                cache_valid[primary_line] && !(|tag_mismatch);
            assign dirty_debug[primary_line] = cache_dirty[primary_line];
        end
    endgenerate
    assign selected_line_hit = |primary_matches;

    // MMIO requests bypass this cache entirely; they are formatted and served
    // by the CPU MMIO path so peripheral side effects stay outside cache state.
    assign hit =
        request_valid &&
        !request_mmio &&
        (cache_state == CACHE_IDLE) &&
        selected_line_hit;
    // Miss is an acceptance event, while busy covers the full transaction.
    assign miss =
        request_valid &&
        !request_mmio &&
        (cache_state == CACHE_IDLE) &&
        !selected_line_hit;
    // Refill data, MEM/WB metadata, and pipeline advance share one completion
    // edge so a miss is not replayed as a second hit in the next IDLE cycle.
    assign request_complete = hit || refill_ready || victim_complete;
    assign busy = (cache_state != CACHE_IDLE) && !refill_ready && !victim_complete;
    assign external_wait =
        USE_EXTERNAL_DMEM &&
        !external_ready &&
        ((cache_state == CACHE_WRITEBACK) || (cache_state == CACHE_REFILL));

    assign hit_word_data = cache_data[cache_index][cache_word_offset];
    assign refill_selected_word = incoming_line[(pending_word_offset * 32) +: 32];
    assign pending_store_old_word = incoming_line[(pending_store_offset * 32) +: 32];
    assign refill_ready = (cache_state == CACHE_REFILL) && (!USE_EXTERNAL_DMEM || external_ready);

    // Data can be selected before tag/MMIO qualification arrives. Only IDLE
    // hits and accepted refill/victim reads assert load_word_valid; other payloads
    // are not consumed by the CPU.
    assign load_word_data = ((cache_state == CACHE_REFILL) || (cache_state == CACHE_VICTIM)) ?
                            refill_selected_word : hit_word_data;
    assign load_word_valid =
        (hit && request_read) ||
        ((refill_ready || victim_complete) && pending_read_valid && !pending_store_valid);
    assign primary_snoop_hit =
        cache_valid[dma_snoop_index] &&
        (cache_tag_store[dma_snoop_index] == dma_snoop_tag);
    assign dma_snoop_hit = primary_snoop_hit || victim_snoop_found;
    assign dma_snoop_read_word = ((VICTIM_LINES == 0) || primary_snoop_hit) ? cache_data[dma_snoop_index][dma_snoop_word_offset] :
        victim_data[victim_snoop_index][32*dma_snoop_word_offset +: 32];

    assign external_addr =
        (cache_state == CACHE_WRITEBACK) ?
        pending_victim_addr :
        pending_line_addr;
    assign external_read = USE_EXTERNAL_DMEM && (cache_state == CACHE_REFILL);
    assign external_write = USE_EXTERNAL_DMEM && (cache_state == CACHE_WRITEBACK);
    assign external_wdata = (VICTIM_LINES > 0) ? victim_data[victim_lru_index] : primary_victim_line;
    assign external_byte_enable = 16'hffff;

    assign internal_writeback_valid = !USE_EXTERNAL_DMEM && (cache_state == CACHE_WRITEBACK);
    assign internal_writeback_addr = pending_victim_addr;
    assign internal_writeback_line = external_wdata;

    // The existing two-bit debug interface groups victim lookup with miss wait.
    assign state_debug = (cache_state == CACHE_VICTIM) ? CACHE_MISS_WAIT[1:0] : cache_state[1:0];
    assign stall_debug = cache_stall;

    load_store_format_unit hit_store_format (
        .word_data(hit_word_data),
        .store_data(request_store_data),
        .byte_offset(cache_byte_offset),
        .funct3(request_funct3),
        .load_value(),
        .store_merged_value(hit_store_merged_value)
    );

    load_store_format_unit pending_store_format (
        .word_data(pending_store_old_word),
        .store_data(pending_store_data),
        .byte_offset(pending_store_byte_offset),
        .funct3(pending_store_funct3),
        .load_value(),
        .store_merged_value(pending_store_merged_value)
    );

    initial begin
        if (CACHE_BYTES != 64 && CACHE_BYTES != 128) $error("unsupported primary cache size");
        if (VICTIM_LINES != 0 && VICTIM_LINES != 1 && VICTIM_LINES != 2 &&
            VICTIM_LINES != 4 && VICTIM_LINES != 8) $error("unsupported victim cache size");
        for (victim_entry = 0; victim_entry < VICTIM_STORAGE; victim_entry = victim_entry + 1) begin
            victim_order[victim_entry] = victim_entry[VICTIM_INDEX_WIDTH-1:0];
        end
        pending_victim_match = 0;
        cache_stall = 2'b00;
        cache_state = CACHE_IDLE;
        pending_line_addr = 32'h0;
        pending_victim_addr = 32'h0;
        pending_tag = 0;
        pending_cache_index = 0;
        pending_word_offset = 2'b00;
        pending_read_valid = 1'b0;
        pending_internal_refill_line = 128'h0;
        pending_store_data = 32'h0;
        pending_store_offset = 2'b00;
        pending_store_byte_offset = 2'b00;
        pending_store_funct3 = 3'b000;
        pending_store_valid = 1'b0;

        for (i = 0; i < PRIMARY_LINES; i = i + 1) begin
            cache_tag_store[i] = 0;
            cache_valid[i] = 1'b0;
            cache_dirty[i] = 1'b0;
        end
    end

    // Miss handling is intentionally small: dirty victims write back first,
    // then a refill line is accepted, and a pending store merges into the new
    // line before the cache returns to IDLE.
    always @(posedge clock) begin
        if (reset) begin
            for (victim_entry = 0; victim_entry < VICTIM_STORAGE; victim_entry = victim_entry + 1) begin
                victim_order[victim_entry] <= victim_entry[VICTIM_INDEX_WIDTH-1:0];
            end
            pending_victim_match <= 0;
            cache_stall <= 2'b00;
            cache_state <= CACHE_IDLE;
            pending_line_addr <= 32'h0;
            pending_victim_addr <= 32'h0;
            pending_tag <= 0;
            pending_cache_index <= 0;
            pending_word_offset <= 2'b00;
            pending_read_valid <= 1'b0;
            pending_internal_refill_line <= 128'h0;
            pending_store_data <= 32'h0;
            pending_store_offset <= 2'b00;
            pending_store_byte_offset <= 2'b00;
            pending_store_funct3 <= 3'b000;
            pending_store_valid <= 1'b0;

            for (i = 0; i < PRIMARY_LINES; i = i + 1) begin
                cache_tag_store[i] <= 0;
                cache_valid[i] <= 1'b0;
                cache_dirty[i] <= 1'b0;
            end
        end else begin
            case (cache_state)
                CACHE_IDLE: begin
                    if (hit && request_write) begin
                        cache_dirty[cache_index] <= 1'b1;
                    end else if (miss) begin
                        pending_victim_match <= victim_match;
                        pending_line_addr <= {request_addr[31:4], 4'b0000};
                        pending_victim_addr <= selected_victim_addr;
                        pending_tag <= request_tag;
                        pending_cache_index <= cache_index;
                        pending_word_offset <= cache_word_offset;
                        pending_read_valid <= request_read;
                        pending_internal_refill_line <= internal_refill_line;
                        pending_store_data <= request_store_data;
                        pending_store_offset <= cache_word_offset;
                        pending_store_byte_offset <= cache_byte_offset;
                        pending_store_funct3 <= request_funct3;
                        pending_store_valid <= request_write;

                        if (VICTIM_LINES > 0) begin
                            cache_state <= CACHE_VICTIM;
                        end else if (cache_valid[cache_index] && cache_dirty[cache_index]) begin
                            cache_state <= CACHE_WRITEBACK;
                        end else begin
                            cache_state <= CACHE_MISS_WAIT;
                            cache_stall <= USE_EXTERNAL_DMEM ? 2'b00 : 2'b10;
                        end
                    end
                end

                CACHE_VICTIM: begin
                    if (victim_found) begin
                        cache_tag_store[pending_cache_index] <= pending_tag;
                        cache_valid[pending_cache_index] <= 1'b1;
                        cache_dirty[pending_cache_index] <= victim_dirty[victim_hit_index] || pending_store_valid;
                        pending_read_valid <= 1'b0;
                        pending_store_valid <= 1'b0;
                        cache_state <= CACHE_IDLE;
                    end else if (cache_valid[pending_cache_index] &&
                                 victim_valid[victim_lru_index] && victim_dirty[victim_lru_index]) begin
                        pending_victim_addr <= {victim_tag[victim_lru_index], 4'b0};
                        cache_state <= CACHE_WRITEBACK;
                    end else begin
                        cache_state <= CACHE_MISS_WAIT;
                        cache_stall <= USE_EXTERNAL_DMEM ? 2'b00 : 2'b10;
                    end
                end

                CACHE_WRITEBACK: begin
                    if (!USE_EXTERNAL_DMEM || external_ready) begin
                        cache_dirty[pending_cache_index] <= 1'b0;
                        cache_state <= CACHE_MISS_WAIT;
                        cache_stall <= USE_EXTERNAL_DMEM ? 2'b00 : 2'b10;
                    end
                end

                CACHE_MISS_WAIT: begin
                    if (cache_stall == 2'b01) begin
                        cache_state <= CACHE_REFILL;
                    end else if (USE_EXTERNAL_DMEM) begin
                        cache_state <= CACHE_REFILL;
                    end else begin
                        cache_stall <= cache_stall - 1'b1;
                    end
                end

                CACHE_REFILL: begin
                    if (!USE_EXTERNAL_DMEM || external_ready) begin
                        cache_tag_store[pending_cache_index] <= pending_tag;
                        cache_valid[pending_cache_index] <= 1'b1;

                        if (pending_store_valid) begin
                            cache_dirty[pending_cache_index] <= 1'b1;
                        end else begin
                            cache_dirty[pending_cache_index] <= 1'b0;
                        end

                        pending_read_valid <= 1'b0;
                        pending_store_valid <= 1'b0;
                        cache_state <= CACHE_IDLE;
                        cache_stall <= 2'b00;
                    end
                end

                default: begin
                    cache_state <= CACHE_IDLE;
                    cache_stall <= 2'b00;
                    pending_read_valid <= 1'b0;
                    pending_store_valid <= 1'b0;
                end
            endcase

            if (victim_complete || victim_insert) begin
                // Replace a hit way or the LRU way with L1's outgoing line.
                // Move that way to MRU without shifting 128-bit payloads.
                for (victim_entry = VICTIM_STORAGE-1; victim_entry > 0; victim_entry = victim_entry - 1) begin
                    if (victim_insert || victim_entry <= victim_hit_rank)
                        victim_order[victim_entry] <= victim_order[victim_entry-1];
                end
                victim_order[0] <= victim_replace_index;
            end
        end

        // DMA-lite repairs a resident word and marks its primary line dirty.
        // This is a local snoop path, not a general coherency protocol.
        if (!reset && dma_snoop_write && primary_snoop_hit) begin
            cache_dirty[dma_snoop_index] <= 1'b1;
        end
    end

endmodule
