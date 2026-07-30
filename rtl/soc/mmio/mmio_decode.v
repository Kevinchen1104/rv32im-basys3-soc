`timescale 1ns / 1ps

// Module: mmio_decode
// Role: Central address decoder for CPU/SoC MMIO windows.
// Interface: 32-bit byte address input and one-hot selects for GPIO, UART, counters, MATVEC, timer, and DMA-lite registers.
// Key behavior: Decodes only implemented word offsets; 0x0400..0x05ff remains ordinary memory.

module mmio_decode (
    input [31:0] addr,

    output gpio_output_sel,
    output gpio_input_sel,
    output uart_tx_sel,
    output uart_rx_sel,
    output uart_status_sel,

    output matvec_ctrl_sel,
    output matvec_status_sel,
    output matvec_config_sel,
    output matvec_vector_sel,
    output matvec_row_index_sel,
    output matvec_row_data_sel,
    output matvec_result_index_sel,
    output matvec_result_data_sel,
    output matvec_perf_sel,

    output matvec_dma_vec_addr_sel,
    output matvec_dma_matrix_addr_sel,
    output matvec_dma_out_addr_sel,
    output matvec_dma_rows_sel,
    output matvec_dma_ctrl_sel,
    output matvec_dma_status_sel,
    output matvec_dma_error_sel,
    output matvec_dma_perf_sel,

    output perf_cycle_count_sel,
    output perf_retired_count_sel,
    output perf_branch_miss_count_sel,
    output perf_icache_miss_count_sel,
    output perf_dcache_miss_count_sel,
    output perf_stall_cycle_count_sel,
    output perf_matvec_start_count_sel,
    output perf_matvec_done_count_sel,
    output perf_matvec_busy_cycle_count_sel,

    output timer_mtime_low_sel,
    output timer_mtime_high_sel,
    output timer_mtimecmp_low_sel,
    output timer_mtimecmp_high_sel,

    output matvec_sel,
    output matvec_dma_sel,
    output perf_counter_sel,
    output timer_sel,
    output any_mmio_sel
);
    localparam [31:0] GPIO_OUTPUT_ADDR = 32'h0000_0200;
    localparam [31:0] GPIO_INPUT_ADDR = 32'h0000_0204;
    localparam [31:0] UART_TXDATA_ADDR = 32'h0000_0300;
    localparam [31:0] UART_RXDATA_ADDR = 32'h0000_0304;
    localparam [31:0] UART_STATUS_ADDR = 32'h0000_0308;

    localparam [31:0] PERF_CYCLE_COUNT_ADDR = 32'h0000_0600;
    localparam [31:0] PERF_RETIRED_COUNT_ADDR = 32'h0000_0604;
    localparam [31:0] PERF_BRANCH_MISS_COUNT_ADDR = 32'h0000_0608;
    localparam [31:0] PERF_ICACHE_MISS_COUNT_ADDR = 32'h0000_060c;
    localparam [31:0] PERF_DCACHE_MISS_COUNT_ADDR = 32'h0000_0610;
    localparam [31:0] PERF_STALL_CYCLE_COUNT_ADDR = 32'h0000_0614;
    localparam [31:0] PERF_MATVEC_START_COUNT_ADDR = 32'h0000_0618;
    localparam [31:0] PERF_MATVEC_DONE_COUNT_ADDR = 32'h0000_061c;
    localparam [31:0] PERF_MATVEC_BUSY_CYCLE_COUNT_ADDR = 32'h0000_0620;

    localparam [31:0] MATVEC_CTRL_ADDR = 32'h0000_0700;
    localparam [31:0] MATVEC_STATUS_ADDR = 32'h0000_0704;
    localparam [31:0] MATVEC_CONFIG_ADDR = 32'h0000_0708;
    localparam [31:0] MATVEC_VECTOR_ADDR = 32'h0000_070c;
    localparam [31:0] MATVEC_ROW_INDEX_ADDR = 32'h0000_0710;
    localparam [31:0] MATVEC_ROW_DATA_ADDR = 32'h0000_0714;
    localparam [31:0] MATVEC_RESULT_INDEX_ADDR = 32'h0000_0718;
    localparam [31:0] MATVEC_RESULT_DATA_ADDR = 32'h0000_071c;
    localparam [31:0] MATVEC_PERF_ADDR = 32'h0000_0720;

    localparam [31:0] TIMER_MTIME_LOW_ADDR = 32'h0000_0800;
    localparam [31:0] TIMER_MTIME_HIGH_ADDR = 32'h0000_0804;
    localparam [31:0] TIMER_MTIMECMP_LOW_ADDR = 32'h0000_0808;
    localparam [31:0] TIMER_MTIMECMP_HIGH_ADDR = 32'h0000_080c;

    localparam [31:0] MATVEC_DMA_VEC_ADDR_ADDR = 32'h0000_0900;
    localparam [31:0] MATVEC_DMA_MATRIX_ADDR_ADDR = 32'h0000_0904;
    localparam [31:0] MATVEC_DMA_OUT_ADDR_ADDR = 32'h0000_0908;
    localparam [31:0] MATVEC_DMA_ROWS_ADDR = 32'h0000_090c;
    localparam [31:0] MATVEC_DMA_CTRL_ADDR = 32'h0000_0910;
    localparam [31:0] MATVEC_DMA_STATUS_ADDR = 32'h0000_0914;
    localparam [31:0] MATVEC_DMA_ERROR_ADDR = 32'h0000_0918;
    localparam [31:0] MATVEC_DMA_PERF_ADDR = 32'h0000_091c;

    wire [31:0] word_addr = {addr[31:2], 2'b00};
    wire [3:0] mmio_page = addr[11:8];
    wire [5:0] mmio_word_offset = addr[7:2];
    reg mmio_offset_valid;

    // Only implemented offsets bypass the D-cache. Addresses 0x0400..0x05ff
    // have no MMIO selects and use the ordinary data-memory path.
    always @(*) begin
        mmio_offset_valid = 1'b0;
        case (mmio_page)
            4'h2: begin
                case (mmio_word_offset)
                    6'd0, 6'd1: mmio_offset_valid = 1'b1;
                    default: mmio_offset_valid = 1'b0;
                endcase
            end
            4'h3: begin
                case (mmio_word_offset)
                    6'd0, 6'd1, 6'd2: mmio_offset_valid = 1'b1;
                    default: mmio_offset_valid = 1'b0;
                endcase
            end
            4'h6, 4'h7: begin
                case (mmio_word_offset)
                    6'd0, 6'd1, 6'd2, 6'd3, 6'd4,
                    6'd5, 6'd6, 6'd7, 6'd8:
                        mmio_offset_valid = 1'b1;
                    default: mmio_offset_valid = 1'b0;
                endcase
            end
            4'h8: begin
                case (mmio_word_offset)
                    6'd0, 6'd1, 6'd2, 6'd3:
                        mmio_offset_valid = 1'b1;
                    default: mmio_offset_valid = 1'b0;
                endcase
            end
            4'h9: begin
                case (mmio_word_offset)
                    6'd0, 6'd1, 6'd2, 6'd3,
                    6'd4, 6'd5, 6'd6, 6'd7:
                        mmio_offset_valid = 1'b1;
                    default: mmio_offset_valid = 1'b0;
                endcase
            end
            default: mmio_offset_valid = 1'b0;
        endcase
    end

    assign gpio_output_sel = (word_addr == GPIO_OUTPUT_ADDR);
    assign gpio_input_sel = (word_addr == GPIO_INPUT_ADDR);

    assign uart_tx_sel = (word_addr == UART_TXDATA_ADDR);
    assign uart_rx_sel = (word_addr == UART_RXDATA_ADDR);
    assign uart_status_sel = (word_addr == UART_STATUS_ADDR);

    assign perf_cycle_count_sel = (word_addr == PERF_CYCLE_COUNT_ADDR);
    assign perf_retired_count_sel = (word_addr == PERF_RETIRED_COUNT_ADDR);
    assign perf_branch_miss_count_sel = (word_addr == PERF_BRANCH_MISS_COUNT_ADDR);
    assign perf_icache_miss_count_sel = (word_addr == PERF_ICACHE_MISS_COUNT_ADDR);
    assign perf_dcache_miss_count_sel = (word_addr == PERF_DCACHE_MISS_COUNT_ADDR);
    assign perf_stall_cycle_count_sel = (word_addr == PERF_STALL_CYCLE_COUNT_ADDR);
    assign perf_matvec_start_count_sel = (word_addr == PERF_MATVEC_START_COUNT_ADDR);
    assign perf_matvec_done_count_sel = (word_addr == PERF_MATVEC_DONE_COUNT_ADDR);
    assign perf_matvec_busy_cycle_count_sel = (word_addr == PERF_MATVEC_BUSY_CYCLE_COUNT_ADDR);
    assign perf_counter_sel =
        perf_cycle_count_sel ||
        perf_retired_count_sel ||
        perf_branch_miss_count_sel ||
        perf_icache_miss_count_sel ||
        perf_dcache_miss_count_sel ||
        perf_stall_cycle_count_sel ||
        perf_matvec_start_count_sel ||
        perf_matvec_done_count_sel ||
        perf_matvec_busy_cycle_count_sel;

    assign matvec_ctrl_sel = (word_addr == MATVEC_CTRL_ADDR);
    assign matvec_status_sel = (word_addr == MATVEC_STATUS_ADDR);
    assign matvec_config_sel = (word_addr == MATVEC_CONFIG_ADDR);
    assign matvec_vector_sel = (word_addr == MATVEC_VECTOR_ADDR);
    assign matvec_row_index_sel = (word_addr == MATVEC_ROW_INDEX_ADDR);
    assign matvec_row_data_sel = (word_addr == MATVEC_ROW_DATA_ADDR);
    assign matvec_result_index_sel = (word_addr == MATVEC_RESULT_INDEX_ADDR);
    assign matvec_result_data_sel = (word_addr == MATVEC_RESULT_DATA_ADDR);
    assign matvec_perf_sel = (word_addr == MATVEC_PERF_ADDR);
    assign matvec_sel =
        matvec_ctrl_sel ||
        matvec_status_sel ||
        matvec_config_sel ||
        matvec_vector_sel ||
        matvec_row_index_sel ||
        matvec_row_data_sel ||
        matvec_result_index_sel ||
        matvec_result_data_sel ||
        matvec_perf_sel;

    assign timer_mtime_low_sel = (word_addr == TIMER_MTIME_LOW_ADDR);
    assign timer_mtime_high_sel = (word_addr == TIMER_MTIME_HIGH_ADDR);
    assign timer_mtimecmp_low_sel = (word_addr == TIMER_MTIMECMP_LOW_ADDR);
    assign timer_mtimecmp_high_sel = (word_addr == TIMER_MTIMECMP_HIGH_ADDR);
    assign timer_sel =
        timer_mtime_low_sel ||
        timer_mtime_high_sel ||
        timer_mtimecmp_low_sel ||
        timer_mtimecmp_high_sel;

    assign matvec_dma_vec_addr_sel = (word_addr == MATVEC_DMA_VEC_ADDR_ADDR);
    assign matvec_dma_matrix_addr_sel = (word_addr == MATVEC_DMA_MATRIX_ADDR_ADDR);
    assign matvec_dma_out_addr_sel = (word_addr == MATVEC_DMA_OUT_ADDR_ADDR);
    assign matvec_dma_rows_sel = (word_addr == MATVEC_DMA_ROWS_ADDR);
    assign matvec_dma_ctrl_sel = (word_addr == MATVEC_DMA_CTRL_ADDR);
    assign matvec_dma_status_sel = (word_addr == MATVEC_DMA_STATUS_ADDR);
    assign matvec_dma_error_sel = (word_addr == MATVEC_DMA_ERROR_ADDR);
    assign matvec_dma_perf_sel = (word_addr == MATVEC_DMA_PERF_ADDR);
    assign matvec_dma_sel =
        matvec_dma_vec_addr_sel ||
        matvec_dma_matrix_addr_sel ||
        matvec_dma_out_addr_sel ||
        matvec_dma_rows_sel ||
        matvec_dma_ctrl_sel ||
        matvec_dma_status_sel ||
        matvec_dma_error_sel ||
        matvec_dma_perf_sel;

    assign any_mmio_sel = (addr[31:12] == 20'h0) && mmio_offset_valid;
endmodule
