`timescale 1ns / 1ps

// Module: dcache_unit
// Role: Small direct-mapped data cache with MMIO bypass and MATVEC DMA-lite snoop support.
// Interface: CPU memory request, internal/external refill/writeback line ports, DMA snoop port, and cache status/debug outputs.
// Key behavior: Handles hits, dirty writeback, refill, subword store merging, MMIO bypass, and DMA writes into cached words.

module dcache_unit #(
    parameter USE_EXTERNAL_DMEM = 0,
    parameter MEMORY_WORD_COUNT = 1024
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
    output [3:0] dirty_debug
);

    localparam CACHE_IDLE      = 2'b00;
    localparam CACHE_WRITEBACK = 2'b01;
    localparam CACHE_MISS_WAIT = 2'b10;
    localparam CACHE_REFILL    = 2'b11;

    reg [31:0] cache_data[0:3][0:3];
    reg [25:0] cache_tag_store[0:3];
    reg cache_valid[0:3];
    reg cache_dirty[0:3];

    reg [1:0] cache_stall;
    reg [1:0] cache_state;

    reg [31:0] pending_line_addr;
    reg [31:0] pending_victim_addr;
    reg [25:0] pending_tag;
    reg [1:0] pending_cache_index;
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
    wire [1:0] cache_index;
    wire [25:0] request_tag;
    wire [31:0] selected_victim_addr;
    wire [127:0] refill_line;
    wire [31:0] hit_word_data;
    wire [31:0] refill_selected_word;
    wire [31:0] pending_store_old_word;
    wire [31:0] hit_store_merged_value;
    wire [31:0] pending_store_merged_value;
    wire refill_ready;
    wire [1:0] dma_snoop_word_offset;
    wire [1:0] dma_snoop_index;
    wire [25:0] dma_snoop_tag;
    wire selected_line_hit;
    wire tag_match0;
    wire tag_match1;
    wire tag_match2;
    wire tag_match3;

    // Preserve explicit compare groups so the four tags are checked in
    // parallel instead of selecting one 26-bit tag before equality logic.
    (* keep = "true" *) wire [25:0] request_tag_xor0;
    (* keep = "true" *) wire [25:0] request_tag_xor1;
    (* keep = "true" *) wire [25:0] request_tag_xor2;
    (* keep = "true" *) wire [25:0] request_tag_xor3;
    (* keep = "true" *) wire [4:0] request_tag_mismatch0;
    (* keep = "true" *) wire [4:0] request_tag_mismatch1;
    (* keep = "true" *) wire [4:0] request_tag_mismatch2;
    (* keep = "true" *) wire [4:0] request_tag_mismatch3;

    integer i;
    integer k;

    assign cache_byte_offset = request_addr[1:0];
    assign cache_word_offset = request_addr[3:2];
    assign cache_index = request_addr[5:4];
    assign request_tag = request_addr[31:6];
    assign selected_victim_addr = {cache_tag_store[cache_index], cache_index, 4'b0000};
    assign refill_line = USE_EXTERNAL_DMEM ? external_rdata : pending_internal_refill_line;
    assign dma_snoop_word_offset = dma_snoop_addr[3:2];
    assign dma_snoop_index = dma_snoop_addr[5:4];
    assign dma_snoop_tag = dma_snoop_addr[31:6];

    assign request_tag_xor0 = cache_tag_store[0] ^ request_tag;
    assign request_tag_xor1 = cache_tag_store[1] ^ request_tag;
    assign request_tag_xor2 = cache_tag_store[2] ^ request_tag;
    assign request_tag_xor3 = cache_tag_store[3] ^ request_tag;
    assign request_tag_mismatch0 = {
        |request_tag_xor0[25:24], |request_tag_xor0[23:18],
        |request_tag_xor0[17:12], |request_tag_xor0[11:6],
        |request_tag_xor0[5:0]
    };
    assign request_tag_mismatch1 = {
        |request_tag_xor1[25:24], |request_tag_xor1[23:18],
        |request_tag_xor1[17:12], |request_tag_xor1[11:6],
        |request_tag_xor1[5:0]
    };
    assign request_tag_mismatch2 = {
        |request_tag_xor2[25:24], |request_tag_xor2[23:18],
        |request_tag_xor2[17:12], |request_tag_xor2[11:6],
        |request_tag_xor2[5:0]
    };
    assign request_tag_mismatch3 = {
        |request_tag_xor3[25:24], |request_tag_xor3[23:18],
        |request_tag_xor3[17:12], |request_tag_xor3[11:6],
        |request_tag_xor3[5:0]
    };
    assign tag_match0 = ~|request_tag_mismatch0;
    assign tag_match1 = ~|request_tag_mismatch1;
    assign tag_match2 = ~|request_tag_mismatch2;
    assign tag_match3 = ~|request_tag_mismatch3;
    assign selected_line_hit =
        ((cache_index == 2'd0) && cache_valid[0] && tag_match0) ||
        ((cache_index == 2'd1) && cache_valid[1] && tag_match1) ||
        ((cache_index == 2'd2) && cache_valid[2] && tag_match2) ||
        ((cache_index == 2'd3) && cache_valid[3] && tag_match3);

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
    assign request_complete = hit || refill_ready;
    assign busy = (cache_state != CACHE_IDLE) && !refill_ready;
    assign external_wait =
        USE_EXTERNAL_DMEM &&
        !external_ready &&
        ((cache_state == CACHE_WRITEBACK) || (cache_state == CACHE_REFILL));

    assign hit_word_data = cache_data[cache_index][cache_word_offset];
    assign refill_selected_word = refill_line[(pending_word_offset * 32) +: 32];
    assign pending_store_old_word = refill_line[(pending_store_offset * 32) +: 32];
    assign refill_ready = (cache_state == CACHE_REFILL) && (!USE_EXTERNAL_DMEM || external_ready);

    assign load_word_data = hit ? hit_word_data : refill_selected_word;
    assign load_word_valid =
        (hit && request_read) ||
        (refill_ready && pending_read_valid && !pending_store_valid);
    assign dma_snoop_hit =
        cache_valid[dma_snoop_index] &&
        (cache_tag_store[dma_snoop_index] == dma_snoop_tag);
    assign dma_snoop_read_word = cache_data[dma_snoop_index][dma_snoop_word_offset];

    assign external_addr =
        (cache_state == CACHE_WRITEBACK) ?
        pending_victim_addr :
        pending_line_addr;
    assign external_read = USE_EXTERNAL_DMEM && (cache_state == CACHE_REFILL);
    assign external_write = USE_EXTERNAL_DMEM && (cache_state == CACHE_WRITEBACK);
    assign external_wdata = {
        cache_data[pending_cache_index][3],
        cache_data[pending_cache_index][2],
        cache_data[pending_cache_index][1],
        cache_data[pending_cache_index][0]
    };
    assign external_byte_enable = 16'hffff;

    assign internal_writeback_valid = !USE_EXTERNAL_DMEM && (cache_state == CACHE_WRITEBACK);
    assign internal_writeback_addr = pending_victim_addr;
    assign internal_writeback_line = external_wdata;

    assign state_debug = cache_state;
    assign stall_debug = cache_stall;
    assign dirty_debug = {
        cache_dirty[3],
        cache_dirty[2],
        cache_dirty[1],
        cache_dirty[0]
    };

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
        cache_stall = 2'b00;
        cache_state = CACHE_IDLE;
        pending_line_addr = 32'h0;
        pending_victim_addr = 32'h0;
        pending_tag = 26'h0;
        pending_cache_index = 2'b00;
        pending_word_offset = 2'b00;
        pending_read_valid = 1'b0;
        pending_internal_refill_line = 128'h0;
        pending_store_data = 32'h0;
        pending_store_offset = 2'b00;
        pending_store_byte_offset = 2'b00;
        pending_store_funct3 = 3'b000;
        pending_store_valid = 1'b0;

        for (i = 0; i < 4; i = i + 1) begin
            for (k = 0; k < 4; k = k + 1) begin
                cache_data[i][k] = 32'h0;
            end
            cache_tag_store[i] = 26'h0;
            cache_valid[i] = 1'b0;
            cache_dirty[i] = 1'b0;
        end
    end

    // Miss handling is intentionally small: dirty victims write back first,
    // then a refill line is accepted, and a pending store merges into the new
    // line before the cache returns to IDLE.
    always @(posedge clock) begin
        if (reset) begin
            cache_stall <= 2'b00;
            cache_state <= CACHE_IDLE;
            pending_line_addr <= 32'h0;
            pending_victim_addr <= 32'h0;
            pending_tag <= 26'h0;
            pending_cache_index <= 2'b00;
            pending_word_offset <= 2'b00;
            pending_read_valid <= 1'b0;
            pending_internal_refill_line <= 128'h0;
            pending_store_data <= 32'h0;
            pending_store_offset <= 2'b00;
            pending_store_byte_offset <= 2'b00;
            pending_store_funct3 <= 3'b000;
            pending_store_valid <= 1'b0;

            for (i = 0; i < 4; i = i + 1) begin
                for (k = 0; k < 4; k = k + 1) begin
                    cache_data[i][k] <= 32'h0;
                end
                cache_tag_store[i] <= 26'h0;
                cache_valid[i] <= 1'b0;
                cache_dirty[i] <= 1'b0;
            end
        end else begin
            case (cache_state)
                CACHE_IDLE: begin
                    if (hit && request_write) begin
                        cache_data[cache_index][cache_word_offset] <= hit_store_merged_value;
                        cache_dirty[cache_index] <= 1'b1;
                    end else if (miss) begin
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

                        if (cache_valid[cache_index] && cache_dirty[cache_index]) begin
                            cache_state <= CACHE_WRITEBACK;
                        end else begin
                            cache_state <= CACHE_MISS_WAIT;
                            cache_stall <= USE_EXTERNAL_DMEM ? 2'b00 : 2'b10;
                        end
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
                        cache_data[pending_cache_index][0] <= refill_line[31:0];
                        cache_data[pending_cache_index][1] <= refill_line[63:32];
                        cache_data[pending_cache_index][2] <= refill_line[95:64];
                        cache_data[pending_cache_index][3] <= refill_line[127:96];
                        cache_tag_store[pending_cache_index] <= pending_tag;
                        cache_valid[pending_cache_index] <= 1'b1;

                        if (pending_store_valid) begin
                            cache_data[pending_cache_index][pending_store_offset] <= pending_store_merged_value;
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
        end

        // DMA-lite writes update a resident cached word through this snoop
        // hook; this is a local repair path, not a general coherency protocol.
        if (!reset && dma_snoop_write && dma_snoop_hit) begin
            cache_data[dma_snoop_index][dma_snoop_word_offset] <= dma_snoop_write_data;
            cache_dirty[dma_snoop_index] <= 1'b1;
        end
    end

endmodule
