`timescale 1ns / 1ps

// Module: int8_matvec_scratchpad_accelerator
// Role: Scratchpad-register signed int8 MATVEC accelerator behind the MATVEC MMIO window.
// Interface: MMIO register write selects/data, row/result index readbacks, status/perf readbacks, and interrupt-pending output.
// Key behavior: Pipelines each selected row through load, multiply, balanced reduction, and commit stages while preserving clear/ignore/interrupt semantics.

`ifndef INT8_MATVEC_SCRATCHPAD_ACCELERATOR_V
`define INT8_MATVEC_SCRATCHPAD_ACCELERATOR_V

module int8_matvec_scratchpad_accelerator (
    input clock,
    input reset,

    input ctrl_write,
    input config_write,
    input vector_write,
    input row_index_write,
    input row_data_write,
    input result_index_write,
    input clear_done,

    input [31:0] write_data,
    input [3:0] write_byte_enable,

    output [31:0] status_read_data,
    output [31:0] config_read_data,
    output [31:0] vector_read_data,
    output [31:0] row_index_read_data,
    output [31:0] row_data_read_data,
    output [31:0] result_index_read_data,
    output [31:0] result_data_read_data,
    output [31:0] perf_read_data,
    output irq_pending
);
    reg [3:0] row_count_minus1;
    reg [31:0] vector_reg;
    reg [3:0] selected_row_index;
    reg [3:0] selected_result_index;
    reg [31:0] selected_row_data_readback;
    reg [31:0] selected_result_data_readback;
    reg [31:0] row_scratchpad [0:15];
    reg [31:0] result_scratchpad [0:15];

    reg [31:0] active_vector;
    reg [3:0] active_row_count_minus1;
    reg [3:0] active_row;

    reg busy;
    reg done;
    reg start_ignored;
    reg write_ignored_while_busy;
    reg interrupt_enable;
    reg irq_pending_reg;

    reg [7:0] completed_ops;
    reg [7:0] ignored_starts;
    reg [7:0] ignored_busy_writes;

    localparam [2:0] STATE_IDLE = 3'd0;
    localparam [2:0] STATE_LOAD_ROW = 3'd1;
    localparam [2:0] STATE_MULTIPLY = 3'd2;
    localparam [2:0] STATE_REDUCE = 3'd3;
    localparam [2:0] STATE_COMMIT = 3'd4;

    reg [2:0] compute_state;
    reg [31:0] row_word;
    reg [3:0] compute_row_index;
    reg [15:0] commit_mask;
    reg signed [15:0] product0;
    reg signed [15:0] product1;
    reg signed [15:0] product2;
    reg signed [15:0] product3;
    reg signed [31:0] result_word;

    // The scratchpad register model lets software stage operands while idle;
    // busy writes are ignored so the active vector/row count remain stable.
    wire start_request = ctrl_write && write_byte_enable[0] && write_data[0];
    wire clear_request = clear_done || (ctrl_write && write_byte_enable[0] && write_data[1]);
    wire interrupt_enable_set_request = ctrl_write && write_byte_enable[0] && write_data[2];
    wire interrupt_enable_clear_request = ctrl_write && write_byte_enable[0] && write_data[3];
    wire clear_irq_request = clear_request || (ctrl_write && write_byte_enable[0] && write_data[4]);
    wire [31:0] write_mask = {{8{write_byte_enable[3]}}, {8{write_byte_enable[2]}},
                             {8{write_byte_enable[1]}}, {8{write_byte_enable[0]}}};
    wire [31:0] merged_row_data = (selected_row_data_readback & ~write_mask) |
                                 (write_data & write_mask);
    wire [3:0] next_row_index = write_byte_enable[0] ? write_data[3:0] : selected_row_index;
    wire [3:0] next_result_index = write_byte_enable[0] ? write_data[3:0] : selected_result_index;
    wire busy_write_request =
        config_write ||
        vector_write ||
        row_index_write ||
        row_data_write ||
        result_index_write;

    wire signed [7:0] row_lane0 = row_word[7:0];
    wire signed [7:0] row_lane1 = row_word[15:8];
    wire signed [7:0] row_lane2 = row_word[23:16];
    wire signed [7:0] row_lane3 = row_word[31:24];
    wire signed [7:0] vector_lane0 = active_vector[7:0];
    wire signed [7:0] vector_lane1 = active_vector[15:8];
    wire signed [7:0] vector_lane2 = active_vector[23:16];
    wire signed [7:0] vector_lane3 = active_vector[31:24];

    wire signed [31:0] product0_extended = {{16{product0[15]}}, product0};
    wire signed [31:0] product1_extended = {{16{product1[15]}}, product1};
    wire signed [31:0] product2_extended = {{16{product2[15]}}, product2};
    wire signed [31:0] product3_extended = {{16{product3[15]}}, product3};
    wire signed [31:0] partial_sum01 = product0_extended + product1_extended;
    wire signed [31:0] partial_sum23 = product2_extended + product3_extended;

    integer i;
    integer lane;

    assign status_read_data = {
        22'h0,
        interrupt_enable,
        irq_pending_reg,
        active_row,
        write_ignored_while_busy,
        start_ignored,
        done,
        busy
    };
    assign config_read_data = {28'h0, row_count_minus1};
    assign vector_read_data = vector_reg;
    assign row_index_read_data = {28'h0, selected_row_index};
    assign row_data_read_data = selected_row_data_readback;
    assign result_index_read_data = {28'h0, selected_result_index};
    assign result_data_read_data = selected_result_data_readback;
    assign perf_read_data = {8'h0, ignored_busy_writes, ignored_starts, completed_ops};
    assign irq_pending = irq_pending_reg;

    always @(posedge clock) begin
        if (reset) begin
            row_count_minus1 <= 4'h0;
            vector_reg <= 32'h0;
            selected_row_index <= 4'h0;
            selected_result_index <= 4'h0;
            selected_row_data_readback <= 32'h0;
            selected_result_data_readback <= 32'h0;
            active_vector <= 32'h0;
            active_row_count_minus1 <= 4'h0;
            active_row <= 4'h0;
            busy <= 1'b0;
            done <= 1'b0;
            start_ignored <= 1'b0;
            write_ignored_while_busy <= 1'b0;
            interrupt_enable <= 1'b0;
            irq_pending_reg <= 1'b0;
            completed_ops <= 8'h0;
            ignored_starts <= 8'h0;
            ignored_busy_writes <= 8'h0;
            compute_state <= STATE_IDLE;
            row_word <= 32'h0;
            compute_row_index <= 4'h0;
            commit_mask <= 16'h0;
            product0 <= 16'sh0;
            product1 <= 16'sh0;
            product2 <= 16'sh0;
            product3 <= 16'sh0;
            result_word <= 32'sh0;

            for (i = 0; i < 16; i = i + 1) begin
                row_scratchpad[i] <= 32'h0;
                result_scratchpad[i] <= 32'h0;
            end
        end else begin
            if (clear_request) begin
                done <= 1'b0;
                start_ignored <= 1'b0;
                write_ignored_while_busy <= 1'b0;
            end
            if (clear_irq_request) begin
                irq_pending_reg <= 1'b0;
            end
            if (interrupt_enable_set_request) begin
                interrupt_enable <= 1'b1;
            end
            if (interrupt_enable_clear_request) begin
                interrupt_enable <= 1'b0;
            end

            if (busy && busy_write_request) begin
                write_ignored_while_busy <= 1'b1;
                if (ignored_busy_writes != 8'hff) begin
                    ignored_busy_writes <= ignored_busy_writes + 8'd1;
                end
            end else if (!busy) begin
                if (config_write && write_byte_enable[0]) begin
                    row_count_minus1 <= write_data[3:0];
                end
                if (vector_write) begin
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        if (write_byte_enable[lane])
                            vector_reg[lane*8 +: 8] <= write_data[lane*8 +: 8];
                    end
                end
                if (row_index_write) begin
                    selected_row_index <= next_row_index;
                end
                if (row_data_write) begin
                    for (lane = 0; lane < 4; lane = lane + 1) begin
                        if (write_byte_enable[lane])
                            row_scratchpad[selected_row_index][lane*8 +: 8] <= write_data[lane*8 +: 8];
                    end
                end
                if (row_index_write) begin
                    selected_row_data_readback <=
                        (row_data_write && next_row_index == selected_row_index) ?
                        merged_row_data : row_scratchpad[next_row_index];
                end else if (row_data_write) begin
                    selected_row_data_readback <= merged_row_data;
                end
                if (result_index_write) begin
                    selected_result_index <= next_result_index;
                    selected_result_data_readback <= result_scratchpad[next_result_index];
                end
            end

            if (busy && start_request) begin
                start_ignored <= 1'b1;
                if (ignored_starts != 8'hff) begin
                    ignored_starts <= ignored_starts + 8'd1;
                end
            end

            if (busy) begin
                case (compute_state)
                    STATE_LOAD_ROW: begin
                        // Row selection terminates at registers before any
                        // signed arithmetic or result-scratchpad write logic.
                        row_word <= row_scratchpad[active_row];
                        compute_row_index <= active_row;
                        commit_mask <= 16'h0001 << active_row;
                        compute_state <= STATE_MULTIPLY;
                    end

                    STATE_MULTIPLY: begin
                        product0 <= row_lane0 * vector_lane0;
                        product1 <= row_lane1 * vector_lane1;
                        product2 <= row_lane2 * vector_lane2;
                        product3 <= row_lane3 * vector_lane3;
                        compute_state <= STATE_REDUCE;
                    end

                    STATE_REDUCE: begin
                        // The registered products feed a balanced two-level
                        // signed adder tree whose output is registered here.
                        result_word <= partial_sum01 + partial_sum23;
                        compute_state <= STATE_COMMIT;
                    end

                    STATE_COMMIT: begin
                        // Only registered result/index metadata reaches the
                        // one-hot result scratchpad write enables.
                        for (i = 0; i < 16; i = i + 1) begin
                            if (commit_mask[i]) begin
                                result_scratchpad[i] <= result_word;
                            end
                        end
                        if (compute_row_index == selected_result_index) begin
                            selected_result_data_readback <= result_word;
                        end

                        if (compute_row_index == active_row_count_minus1) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            compute_state <= STATE_IDLE;
                            if (interrupt_enable) begin
                                irq_pending_reg <= 1'b1;
                            end
                            if (completed_ops != 8'hff) begin
                                completed_ops <= completed_ops + 8'd1;
                            end
                        end else begin
                            active_row <= active_row + 4'd1;
                            compute_state <= STATE_LOAD_ROW;
                        end
                    end

                    default: begin
                        busy <= 1'b0;
                        compute_state <= STATE_IDLE;
                    end
                endcase
            end else if (start_request) begin
                busy <= 1'b1;
                active_vector <= vector_reg;
                active_row_count_minus1 <= row_count_minus1;
                active_row <= 4'h0;
                compute_state <= STATE_LOAD_ROW;
            end
        end
    end

`ifdef FORMAL
    reg formal_seen_reset = 1'b0;
    always @(posedge clock) begin
        if (reset)
            formal_seen_reset <= 1'b1;
        // The shadow supplies preserved bytes without a second scratchpad read port.
        if (formal_seen_reset)
            assert(selected_row_data_readback == row_scratchpad[selected_row_index]);
    end
`endif
endmodule

`endif
