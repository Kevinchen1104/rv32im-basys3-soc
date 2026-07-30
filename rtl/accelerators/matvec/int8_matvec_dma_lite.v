`timescale 1ns / 1ps

// Module: int8_matvec_dma_lite
// Role: DMA-lite signed int8 MATVEC accelerator that reads vector/matrix data from DMEM and writes results back.
// Interface: MMIO register writes/readbacks, status/error/perf outputs, and a 128-bit DMEM line request port with cache snoop input.
// Key behavior: Validates a small job descriptor, owns DMEM while busy, and pipelines each row through read, multiply, reduce, and write stages.
// Non-goals: No coherent DMA protocol, deployment DMA engine, or deployment accelerator behavior is claimed.

`ifndef INT8_MATVEC_DMA_LITE_V
`define INT8_MATVEC_DMA_LITE_V

module int8_matvec_dma_lite #(
    parameter DMEM_WORD_COUNT = 1024
) (
    input clock,
    input reset,

    input vec_addr_write,
    input matrix_addr_write,
    input out_addr_write,
    input rows_write,
    input ctrl_write,
    input [31:0] write_data,

    output [31:0] vec_addr_read_data,
    output [31:0] matrix_addr_read_data,
    output [31:0] out_addr_read_data,
    output [31:0] rows_read_data,
    output [31:0] ctrl_read_data,
    output [31:0] status_read_data,
    output [31:0] error_read_data,
    output [31:0] perf_read_data,

    output busy,
    output done,
    output error,
    output irq_pending,

    output dmem_read,
    output dmem_write,
    output [31:0] dmem_addr,
    output [31:0] dmem_word_addr,
    output [127:0] dmem_wdata,
    output [15:0] dmem_byte_enable,
    input [127:0] dmem_rdata,
    input dmem_ready,
    input dmem_snoop_hit,
    input [31:0] dmem_snoop_word
);
    localparam STATE_IDLE = 3'd0;
    localparam STATE_READ_VECTOR = 3'd1;
    localparam STATE_READ_ROW = 3'd2;
    localparam STATE_MULTIPLY = 3'd3;
    localparam STATE_REDUCE = 3'd4;
    localparam STATE_WRITE_RESULT = 3'd5;
    localparam STATE_VALIDATE = 3'd6;

    localparam [31:0] ERROR_INVALID_ROWS = 32'h0000_0001;
    localparam [31:0] ERROR_UNALIGNED_VEC = 32'h0000_0002;
    localparam [31:0] ERROR_UNALIGNED_MATRIX = 32'h0000_0004;
    localparam [31:0] ERROR_UNALIGNED_OUT = 32'h0000_0008;
    localparam [31:0] ERROR_START_WHILE_BUSY = 32'h0000_0010;
    localparam [31:0] ERROR_WRITE_WHILE_BUSY = 32'h0000_0020;
    localparam [31:0] ERROR_VEC_OUT_OF_RANGE = 32'h0000_0040;
    localparam [31:0] ERROR_MATRIX_OUT_OF_RANGE = 32'h0000_0080;
    localparam [31:0] ERROR_OUT_OUT_OF_RANGE = 32'h0000_0100;
    localparam [31:0] ERROR_MATRIX_OUT_OVERLAP = 32'h0000_0200;
    localparam [32:0] DMEM_BYTE_COUNT = DMEM_WORD_COUNT * 4;

    reg [31:0] vec_addr_reg;
    reg [31:0] matrix_addr_reg;
    reg [31:0] out_addr_reg;
    reg [31:0] rows_reg;
    reg [2:0] state;
    reg busy_reg;
    reg done_reg;
    reg [31:0] error_reg;
    reg [2:0] active_rows;
    reg [1:0] active_row;
    reg [31:0] active_matrix_addr;
    reg [31:0] active_out_addr;
    reg [31:0] transaction_word_addr;
    reg [31:0] vector_word;
    reg [31:0] row_word;
    reg signed [15:0] product0;
    reg signed [15:0] product1;
    reg signed [15:0] product2;
    reg signed [15:0] product3;
    reg [31:0] result_word;
    reg [7:0] jobs_started;
    reg [7:0] jobs_completed;
    reg [7:0] dmem_reads;
    reg [7:0] dmem_writes;
    reg validation_rows_valid;
    reg [2:0] validation_alignment_errors;
    reg [32:0] validation_vec_end_address;
    reg [32:0] validation_matrix_start_address;
    reg [32:0] validation_matrix_end_address;
    reg [32:0] validation_out_start_address;
    reg [32:0] validation_out_end_address;

    wire start_request = ctrl_write && write_data[0];
    wire clear_request = ctrl_write && write_data[2];
    wire config_write_request =
        vec_addr_write ||
        matrix_addr_write ||
        out_addr_write ||
        rows_write;
    wire rows_valid =
        (rows_reg >= 32'd1) &&
        (rows_reg <= 32'd4);
    wire [32:0] row_span_bytes =
        ({1'b0, rows_reg} - 33'd1) << 2;
    wire matrix_out_overlap =
        validation_rows_valid &&
        (validation_matrix_start_address <= validation_out_end_address) &&
        (validation_out_start_address <= validation_matrix_end_address);
    // Job descriptors are accepted only when idle, word-aligned, and wholly
    // contained in DMEM. Matrix and output ranges must be disjoint because
    // each result write precedes the next row read. Start captures 33-bit end
    // addresses first so wraparound arithmetic and range comparisons occupy
    // separate cycles.
    wire [31:0] validation_error =
        (!validation_rows_valid ? ERROR_INVALID_ROWS : 32'h0) |
        (validation_alignment_errors[0] ? ERROR_UNALIGNED_VEC : 32'h0) |
        (validation_alignment_errors[1] ? ERROR_UNALIGNED_MATRIX : 32'h0) |
        (validation_alignment_errors[2] ? ERROR_UNALIGNED_OUT : 32'h0) |
        (validation_vec_end_address >= DMEM_BYTE_COUNT ?
            ERROR_VEC_OUT_OF_RANGE : 32'h0) |
        ((validation_rows_valid &&
          (validation_matrix_end_address >= DMEM_BYTE_COUNT)) ?
            ERROR_MATRIX_OUT_OF_RANGE : 32'h0) |
        ((validation_rows_valid &&
          (validation_out_end_address >= DMEM_BYTE_COUNT)) ?
            ERROR_OUT_OUT_OF_RANGE : 32'h0) |
        (matrix_out_overlap ? ERROR_MATRIX_OUT_OVERLAP : 32'h0);
    wire [31:0] active_read_word =
        dmem_snoop_hit ? dmem_snoop_word : select_line_word(dmem_rdata, transaction_word_addr[3:2]);

    wire signed [7:0] row_lane0 = row_word[7:0];
    wire signed [7:0] row_lane1 = row_word[15:8];
    wire signed [7:0] row_lane2 = row_word[23:16];
    wire signed [7:0] row_lane3 = row_word[31:24];
    wire signed [7:0] vector_lane0 = vector_word[7:0];
    wire signed [7:0] vector_lane1 = vector_word[15:8];
    wire signed [7:0] vector_lane2 = vector_word[23:16];
    wire signed [7:0] vector_lane3 = vector_word[31:24];
    wire signed [16:0] product_sum01 =
        $signed({product0[15], product0}) +
        $signed({product1[15], product1});
    wire signed [16:0] product_sum23 =
        $signed({product2[15], product2}) +
        $signed({product3[15], product3});
    wire signed [17:0] product_sum_all =
        $signed({product_sum01[16], product_sum01}) +
        $signed({product_sum23[16], product_sum23});

    assign vec_addr_read_data = vec_addr_reg;
    assign matrix_addr_read_data = matrix_addr_reg;
    assign out_addr_read_data = out_addr_reg;
    assign rows_read_data = rows_reg;
    assign ctrl_read_data = 32'h0;
    assign status_read_data = {
        24'h0,
        2'b00,
        active_row,
        1'b0,
        error,
        done_reg,
        busy_reg
    };
    assign error_read_data = error_reg;
    assign perf_read_data = {dmem_writes, dmem_reads, jobs_completed, jobs_started};
    assign busy = busy_reg;
    assign done = done_reg;
    assign error = (error_reg != 32'h0);
    assign irq_pending = 1'b0;
    assign dmem_read = busy_reg && ((state == STATE_READ_VECTOR) || (state == STATE_READ_ROW));
    assign dmem_write = busy_reg && (state == STATE_WRITE_RESULT);
    assign dmem_addr = {transaction_word_addr[31:4], 4'b0000};
    assign dmem_word_addr = transaction_word_addr;
    assign dmem_wdata = place_line_word(result_word, transaction_word_addr[3:2]);
    assign dmem_byte_enable = word_byte_enable(transaction_word_addr[3:2]);

    function [31:0] select_line_word;
        input [127:0] line_data;
        input [1:0] word_index;
        begin
            case (word_index)
                2'd0: select_line_word = line_data[31:0];
                2'd1: select_line_word = line_data[63:32];
                2'd2: select_line_word = line_data[95:64];
                default: select_line_word = line_data[127:96];
            endcase
        end
    endfunction

    function [127:0] place_line_word;
        input [31:0] word_data;
        input [1:0] word_index;
        begin
            case (word_index)
                2'd0: place_line_word = {96'h0, word_data};
                2'd1: place_line_word = {64'h0, word_data, 32'h0};
                2'd2: place_line_word = {32'h0, word_data, 64'h0};
                default: place_line_word = {word_data, 96'h0};
            endcase
        end
    endfunction

    function [15:0] word_byte_enable;
        input [1:0] word_index;
        begin
            case (word_index)
                2'd0: word_byte_enable = 16'h000f;
                2'd1: word_byte_enable = 16'h00f0;
                2'd2: word_byte_enable = 16'h0f00;
                default: word_byte_enable = 16'hf000;
            endcase
        end
    endfunction

    function [7:0] sat_inc8;
        input [7:0] value;
        begin
            sat_inc8 = (value == 8'hff) ? 8'hff : (value + 8'd1);
        end
    endfunction

    always @(posedge clock) begin
        if (reset) begin
            vec_addr_reg <= 32'h0;
            matrix_addr_reg <= 32'h0;
            out_addr_reg <= 32'h0;
            rows_reg <= 32'd0;
            state <= STATE_IDLE;
            busy_reg <= 1'b0;
            done_reg <= 1'b0;
            error_reg <= 32'h0;
            active_rows <= 3'd0;
            active_row <= 2'd0;
            active_matrix_addr <= 32'h0;
            active_out_addr <= 32'h0;
            transaction_word_addr <= 32'h0;
            vector_word <= 32'h0;
            row_word <= 32'h0;
            product0 <= 16'sh0;
            product1 <= 16'sh0;
            product2 <= 16'sh0;
            product3 <= 16'sh0;
            result_word <= 32'h0;
            jobs_started <= 8'h0;
            jobs_completed <= 8'h0;
            dmem_reads <= 8'h0;
            dmem_writes <= 8'h0;
            validation_rows_valid <= 1'b0;
            validation_alignment_errors <= 3'b000;
            validation_vec_end_address <= 33'h0;
            validation_matrix_start_address <= 33'h0;
            validation_matrix_end_address <= 33'h0;
            validation_out_start_address <= 33'h0;
            validation_out_end_address <= 33'h0;
        end else begin
            if (clear_request) begin
                done_reg <= 1'b0;
                error_reg <= 32'h0;
            end

            // Configuration registers are owned by software only while idle;
            // writes during an active job are ignored and reflected in error.
            if (busy_reg && config_write_request) begin
                error_reg <= error_reg | ERROR_WRITE_WHILE_BUSY;
            end else if (!busy_reg) begin
                if (vec_addr_write) begin
                    vec_addr_reg <= write_data;
                end
                if (matrix_addr_write) begin
                    matrix_addr_reg <= write_data;
                end
                if (out_addr_write) begin
                    out_addr_reg <= write_data;
                end
                if (rows_write) begin
                    rows_reg <= write_data;
                end
            end

            if (start_request) begin
                if (busy_reg) begin
                    error_reg <= error_reg | ERROR_START_WHILE_BUSY;
                end else begin
                    busy_reg <= 1'b1;
                    done_reg <= 1'b0;
                    error_reg <= 32'h0;
                    state <= STATE_VALIDATE;
                    active_rows <= rows_reg[2:0];
                    active_row <= 2'd0;
                    active_matrix_addr <= matrix_addr_reg;
                    active_out_addr <= out_addr_reg;
                    transaction_word_addr <= vec_addr_reg;
                    validation_rows_valid <= rows_valid;
                    validation_alignment_errors <= {
                        out_addr_reg[1:0] != 2'b00,
                        matrix_addr_reg[1:0] != 2'b00,
                        vec_addr_reg[1:0] != 2'b00
                    };
                    validation_vec_end_address <=
                        {1'b0, vec_addr_reg} + 33'd3;
                    validation_matrix_start_address <=
                        {1'b0, matrix_addr_reg};
                    validation_matrix_end_address <=
                        {1'b0, matrix_addr_reg} + row_span_bytes + 33'd3;
                    validation_out_start_address <=
                        {1'b0, out_addr_reg};
                    validation_out_end_address <=
                        {1'b0, out_addr_reg} + row_span_bytes + 33'd3;
                end
            end

            if (busy_reg) begin
                // The job FSM retains DMEM ownership across compute-only
                // stages, but requests the memory port only for reads/writes.
                case (state)
                    STATE_VALIDATE: begin
                        if (validation_error != 32'h0) begin
                            busy_reg <= 1'b0;
                            done_reg <= 1'b1;
                            error_reg <=
                                validation_error |
                                (start_request ? ERROR_START_WHILE_BUSY : 32'h0) |
                                (config_write_request ? ERROR_WRITE_WHILE_BUSY : 32'h0);
                            state <= STATE_IDLE;
                        end else begin
                            // Every memory request is driven from the captured
                            // address; later FSM states prepare the next one.
                            state <= STATE_READ_VECTOR;
                            jobs_started <= sat_inc8(jobs_started);
                        end
                    end
                    STATE_READ_VECTOR: begin
                        if (dmem_ready) begin
                            vector_word <= active_read_word;
                            dmem_reads <= sat_inc8(dmem_reads);
                            transaction_word_addr <= active_matrix_addr;
                            state <= STATE_READ_ROW;
                        end
                    end
                    STATE_READ_ROW: begin
                        if (dmem_ready) begin
                            row_word <= active_read_word;
                            dmem_reads <= sat_inc8(dmem_reads);
                            transaction_word_addr <=
                                active_out_addr + {28'h0, active_row, 2'b00};
                            state <= STATE_MULTIPLY;
                        end
                    end
                    STATE_MULTIPLY: begin
                        // Registering the four 8x8 products separates operand
                        // selection and cache snoop logic from reduction.
                        product0 <= row_lane0 * vector_lane0;
                        product1 <= row_lane1 * vector_lane1;
                        product2 <= row_lane2 * vector_lane2;
                        product3 <= row_lane3 * vector_lane3;
                        state <= STATE_REDUCE;
                    end
                    STATE_REDUCE: begin
                        // Two pair sums feed one signed final add; the 18-bit
                        // range covers every four-lane signed int8 dot product.
                        result_word <= {{14{product_sum_all[17]}}, product_sum_all};
                        state <= STATE_WRITE_RESULT;
                    end
                    STATE_WRITE_RESULT: begin
                        if (dmem_ready) begin
                            dmem_writes <= sat_inc8(dmem_writes);
                            if ({1'b0, active_row} == (active_rows - 3'd1)) begin
                                busy_reg <= 1'b0;
                                done_reg <= 1'b1;
                                state <= STATE_IDLE;
                                jobs_completed <= sat_inc8(jobs_completed);
                            end else begin
                                active_row <= active_row + 2'd1;
                                transaction_word_addr <=
                                    active_matrix_addr +
                                    {28'h0, active_row, 2'b00} + 32'd4;
                                state <= STATE_READ_ROW;
                            end
                        end
                    end
                    default: begin
                        state <= STATE_IDLE;
                    end
                endcase
            end
        end
    end
endmodule

`endif
