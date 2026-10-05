`timescale 1ns / 1ps

// Module: icache_unit
// Role: Small two-way instruction cache for the fetch stage.
// Interface: Clock/reset, PC, internal/external line refill inputs, external read handshake, instruction output, and debug state.
// Key behavior: Returns NOP on miss, refills a cache line after fixed/internal or external latency, and updates per-set LRU state.

module icache_unit #(
    parameter USE_EXTERNAL_IMEM = 0,
    parameter CACHE_BYTES = 64,
    parameter PARALLEL_LOOKUP = 1
) (
    input clock,
    input reset,

    input [31:0] pc,
    input [127:0] internal_line_data,
    input [127:0] external_line_data,
    input external_ready,
    input cancel_refill,

    output [31:0] instruction,
    output return_hint,
    output miss,
    output busy,
    output external_read,
    output [31:0] refill_addr,

    output [1:0] state_debug,
    output [1:0] stall_debug,
    output lru_set0_debug,
    output lru_set1_debug
);

    localparam [31:0] NOP = 32'h0000_0013;
    localparam [1:0] IC_IDLE = 2'b00;
    localparam [1:0] IC_MISS = 2'b01;
    // Two ways and four words per line remain fixed. The small parallel
    // implementation is retained as the default timing reference.
    localparam GEOMETRY_VALID = (CACHE_BYTES >= 64) && (CACHE_BYTES <= 4096) &&
        ((CACHE_BYTES & (CACHE_BYTES - 1)) == 0) &&
        ((PARALLEL_LOOKUP == 0) || ((PARALLEL_LOOKUP == 1) && (CACHE_BYTES == 64)));
    // Invalid profiles are rejected by RISCVCPU.config_error. Safe bounds
    // also keep those elaborations well-defined for integration tests.
    localparam SET_COUNT = GEOMETRY_VALID ? CACHE_BYTES / 32 : 2;
    localparam INDEX_BITS = $clog2(SET_COUNT);
    localparam TAG_BITS = 28 - INDEX_BITS;

    reg [31:0] data[0:SET_COUNT-1][0:1][0:3];
    reg return_word[0:SET_COUNT-1][0:1][0:3];
    reg [TAG_BITS-1:0] tag[0:SET_COUNT-1][0:1];
    reg valid[0:SET_COUNT-1][0:1];
    reg [1:0] state;
    reg [1:0] stall;
    reg replace_way;
    reg [31:0] miss_line_addr;
    reg refill_cancelled;
    reg lru[0:SET_COUNT-1];

    wire [1:0] word_offset;
    wire [INDEX_BITS-1:0] set;
    wire [INDEX_BITS-1:0] refill_set = miss_line_addr[4 +: INDEX_BITS];
    wire [TAG_BITS-1:0] pc_tag;
    wire hit_way0;
    wire hit_way1;
    wire hit;
    wire hit_way;
    wire [127:0] refill_line_data;
    wire tag_match00;
    wire tag_match01;
    wire tag_match10;
    wire tag_match11;
    (* keep = "true" *) wire [26:0] tag_xor00;
    (* keep = "true" *) wire [26:0] tag_xor01;
    (* keep = "true" *) wire [26:0] tag_xor10;
    (* keep = "true" *) wire [26:0] tag_xor11;
    (* keep = "true" *) wire [4:0] tag_mismatch00;
    (* keep = "true" *) wire [4:0] tag_mismatch01;
    (* keep = "true" *) wire [4:0] tag_mismatch10;
    (* keep = "true" *) wire [4:0] tag_mismatch11;
    wire [31:0] word00_low;
    wire [31:0] word00_high;
    wire [31:0] word01_low;
    wire [31:0] word01_high;
    wire [31:0] word10_low;
    wire [31:0] word10_high;
    wire [31:0] word11_low;
    wire [31:0] word11_high;
    wire [31:0] word00;
    wire [31:0] word01;
    wire [31:0] word10;
    wire [31:0] word11;
    wire [31:0] selected_way0_word;
    wire [31:0] selected_way1_word;
    wire selected_way0_hint;
    wire selected_way1_hint;
    wire [31:0] hit_word;

    integer i;
    integer j;
    integer k;

    assign word_offset = pc[3:2];
    assign set = pc[4 +: INDEX_BITS];
    assign pc_tag = pc[31:4+INDEX_BITS];

    generate if (PARALLEL_LOOKUP) begin : parallel_lookup
    // Compare all physical tags in parallel before selecting the PC set.
    assign tag_xor00 = tag[0][0] ^ pc_tag;
    assign tag_xor01 = tag[0][1] ^ pc_tag;
    assign tag_xor10 = tag[1][0] ^ pc_tag;
    assign tag_xor11 = tag[1][1] ^ pc_tag;
    assign tag_mismatch00 = {
        |tag_xor00[26:24], |tag_xor00[23:18], |tag_xor00[17:12],
        |tag_xor00[11:6], |tag_xor00[5:0]
    };
    assign tag_mismatch01 = {
        |tag_xor01[26:24], |tag_xor01[23:18], |tag_xor01[17:12],
        |tag_xor01[11:6], |tag_xor01[5:0]
    };
    assign tag_mismatch10 = {
        |tag_xor10[26:24], |tag_xor10[23:18], |tag_xor10[17:12],
        |tag_xor10[11:6], |tag_xor10[5:0]
    };
    assign tag_mismatch11 = {
        |tag_xor11[26:24], |tag_xor11[23:18], |tag_xor11[17:12],
        |tag_xor11[11:6], |tag_xor11[5:0]
    };
    assign tag_match00 = ~|tag_mismatch00;
    assign tag_match01 = ~|tag_mismatch01;
    assign tag_match10 = ~|tag_mismatch10;
    assign tag_match11 = ~|tag_mismatch11;

    assign hit_way0 = set ?
        (valid[1][0] && tag_match10) :
        (valid[0][0] && tag_match00);
    assign hit_way1 = set ?
        (valid[1][1] && tag_match11) :
        (valid[0][1] && tag_match01);

    // Balance each line's word mux before the set/way selection.
    assign word00_low = word_offset[0] ? data[0][0][1] : data[0][0][0];
    assign word00_high = word_offset[0] ? data[0][0][3] : data[0][0][2];
    assign word01_low = word_offset[0] ? data[0][1][1] : data[0][1][0];
    assign word01_high = word_offset[0] ? data[0][1][3] : data[0][1][2];
    assign word10_low = word_offset[0] ? data[1][0][1] : data[1][0][0];
    assign word10_high = word_offset[0] ? data[1][0][3] : data[1][0][2];
    assign word11_low = word_offset[0] ? data[1][1][1] : data[1][1][0];
    assign word11_high = word_offset[0] ? data[1][1][3] : data[1][1][2];
    assign word00 = word_offset[1] ? word00_high : word00_low;
    assign word01 = word_offset[1] ? word01_high : word01_low;
    assign word10 = word_offset[1] ? word10_high : word10_low;
    assign word11 = word_offset[1] ? word11_high : word11_low;
    assign selected_way0_word = set ? word10 : word00;
    assign selected_way1_word = set ? word11 : word01;
    assign selected_way0_hint = return_word[set][0][word_offset];
    assign selected_way1_hint = return_word[set][1][word_offset];
    end else begin : indexed_lookup
        // Each way/word bank has one write port and one asynchronous read
        // port. Explicit banking permits distributed-RAM inference instead
        // of expanding a multi-write three-dimensional array into flops.
        wire [1:0] way_hit;
        wire [32:0] way_word [0:1];
        genvar way, word;
        for (way = 0; way < 2; way = way + 1) begin : ways
            reg [TAG_BITS-1:0] tags [0:SET_COUNT-1];
            wire [32:0] words [0:3];
            wire write_line = !reset && (state == IC_MISS) && (stall == 0) &&
                (!USE_EXTERNAL_IMEM || external_ready) && !refill_cancelled &&
                (replace_way == way);
            always @(posedge clock) begin
                if (write_line) tags[refill_set] <= miss_line_addr[31:4+INDEX_BITS];
            end
            assign way_hit[way] = valid[set][way] && tags[set] == pc_tag;
            for (word = 0; word < 4; word = word + 1) begin : banks
                reg [32:0] entries [0:SET_COUNT-1];
                wire [31:0] refill_word = refill_line_data[word*32 +: 32];
                always @(posedge clock) begin
                    if (write_line) entries[refill_set] <= {
                        ((refill_word & 32'hffff_8fff) == 32'h0000_8067), refill_word};
                end
                assign words[word] = entries[set];
            end
            assign way_word[way] = words[word_offset];
        end
        assign hit_way0 = way_hit[0];
        assign hit_way1 = way_hit[1];
        assign selected_way0_word = way_word[0][31:0];
        assign selected_way1_word = way_word[1][31:0];
        assign selected_way0_hint = way_word[0][32];
        assign selected_way1_hint = way_word[1][32];
    end endgenerate
    assign hit = hit_way0 || hit_way1;
    // Preserve way1 priority if both ways contain one tag.
    assign hit_way = hit_way1;
    assign hit_word = hit_way1 ? selected_way1_word : selected_way0_word;
    assign instruction = hit ? hit_word : NOP;
    // Decode on refill, so the tag-to-PC path selects one bit rather than
    // selecting a 32-bit instruction and then decoding a return.
    assign return_hint = hit_way1 ? selected_way1_hint :
                         (hit_way0 && selected_way0_hint);
    assign miss = !hit && (state == IC_IDLE);
    assign busy = (state != IC_IDLE);
    assign external_read = USE_EXTERNAL_IMEM && (state == IC_MISS) && (stall == 2'd0);
    assign refill_addr = miss_line_addr;
    assign refill_line_data = USE_EXTERNAL_IMEM ? external_line_data : internal_line_data;

    assign state_debug = state;
    assign stall_debug = stall;
    assign lru_set0_debug = lru[0];
    assign lru_set1_debug = lru[1];

    always @(posedge clock) begin
        if (reset) begin
            state <= IC_IDLE;
            stall <= 2'd0;
            replace_way <= 1'b0;
            miss_line_addr <= 32'h0;
            refill_cancelled <= 1'b0;
            for (i = 0; i < SET_COUNT; i = i + 1) begin
                lru[i] <= 1'b0;
                for (j = 0; j < 2; j = j + 1) begin
                    valid[i][j] <= 1'b0;
                    if (PARALLEL_LOOKUP) begin
                        tag[i][j] <= 0;
                        for (k = 0; k < 4; k = k + 1) begin
                            data[i][j][k] <= 32'h0;
                            return_word[i][j][k] <= 1'b0;
                        end
                    end
                end
            end
        end else begin
            // On a miss, choose an invalid way first and fall back to the
            // per-set LRU bit. External IMEM waits here until ready asserts.
            case (state)
                IC_IDLE: begin
                    if (miss) begin
                        miss_line_addr <= {pc[31:4], 4'b0000};
                        refill_cancelled <= 1'b0;
                        if (!valid[set][0]) begin
                            replace_way <= 1'b0;
                        end else if (!valid[set][1]) begin
                            replace_way <= 1'b1;
                        end else begin
                            replace_way <= lru[set];
                        end

                        state <= IC_MISS;
                        stall <= USE_EXTERNAL_IMEM ? 2'd0 : 2'd2;
                    end
                end

                IC_MISS: begin
                    if (cancel_refill) begin
                        refill_cancelled <= 1'b1;
                    end

                    if (stall > 2'd0) begin
                        stall <= stall - 2'd1;
                    end else if (USE_EXTERNAL_IMEM && !external_ready) begin
                        state <= IC_MISS;
                    end else begin
                        // A prior redirect discards the response without touching the victim.
                        if (!refill_cancelled) begin
                            if (PARALLEL_LOOKUP) begin
                                for (k = 0; k < 4; k = k + 1) begin
                                    // Preserve the existing RAS query predicate;
                                    // funct3 legality is resolved by the decoder.
                                    return_word[refill_set][replace_way][k] <=
                                        (refill_line_data[(k * 32) +: 32] & 32'hffff_8fff) == 32'h0000_8067;
                                end
                                data[refill_set][replace_way][0] <= refill_line_data[31:0];
                                data[refill_set][replace_way][1] <= refill_line_data[63:32];
                                data[refill_set][replace_way][2] <= refill_line_data[95:64];
                                data[refill_set][replace_way][3] <= refill_line_data[127:96];
                                tag[refill_set][replace_way] <= miss_line_addr[31:4+INDEX_BITS];
                            end
                            // A same-cycle redirect may overwrite storage, but never validates it.
                            valid[refill_set][replace_way] <= !cancel_refill;
                        end
                        state <= IC_IDLE;
                    end
                end

                default: begin
                    state <= IC_IDLE;
                    stall <= 2'd0;
                end
            endcase

            // A hit flips the per-set replacement hint toward the other way.
            if (hit) begin
                if (hit_way == 1'b0) begin
                    lru[set] <= 1'b1;
                end else begin
                    lru[set] <= 1'b0;
                end
            end
        end
    end

endmodule
