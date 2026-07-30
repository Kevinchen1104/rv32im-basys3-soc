`timescale 1ns / 1ps

// Module: mmio_read_mux
// Role: Hierarchical combinational read-data selection for the CPU/SoC MMIO map.
// Interface: Accepts a byte address and the current readback word from each implemented MMIO register group.
// Key behavior: Decodes page and word offset separately while preserving word-aligned subword aliases.

module mmio_read_mux (
    input [31:0] addr,

    input [31:0] gpio_output_read_data,
    input [31:0] gpio_input_read_data,
    input [31:0] uart_rx_read_data,
    input [31:0] uart_status_read_data,

    input [31:0] perf_cycle_count_read_data,
    input [31:0] perf_retired_count_read_data,
    input [31:0] perf_branch_miss_count_read_data,
    input [31:0] perf_icache_miss_count_read_data,
    input [31:0] perf_dcache_miss_count_read_data,
    input [31:0] perf_stall_cycle_count_read_data,
    input [31:0] perf_matvec_start_count_read_data,
    input [31:0] perf_matvec_done_count_read_data,
    input [31:0] perf_matvec_busy_cycle_count_read_data,

    input [31:0] matvec_status_read_data,
    input [31:0] matvec_config_read_data,
    input [31:0] matvec_vector_read_data,
    input [31:0] matvec_row_index_read_data,
    input [31:0] matvec_row_data_read_data,
    input [31:0] matvec_result_index_read_data,
    input [31:0] matvec_result_data_read_data,
    input [31:0] matvec_perf_read_data,

    input [31:0] timer_mtime_low_read_data,
    input [31:0] timer_mtime_high_read_data,
    input [31:0] timer_mtimecmp_low_read_data,
    input [31:0] timer_mtimecmp_high_read_data,

    input [31:0] matvec_dma_vec_addr_read_data,
    input [31:0] matvec_dma_matrix_addr_read_data,
    input [31:0] matvec_dma_out_addr_read_data,
    input [31:0] matvec_dma_rows_read_data,
    input [31:0] matvec_dma_ctrl_read_data,
    input [31:0] matvec_dma_status_read_data,
    input [31:0] matvec_dma_error_read_data,
    input [31:0] matvec_dma_perf_read_data,

    output reg [31:0] read_word
);
    wire [5:0] word_offset = addr[7:2];

    reg [31:0] gpio_page_word;
    reg [31:0] uart_page_word;
    reg [31:0] perf_page_word;
    reg [31:0] matvec_page_word;
    reg [31:0] timer_page_word;
    reg [31:0] matvec_dma_page_word;

    // GPIO output remains the deterministic fallback for write-only or
    // unmapped reads. The decoder prevents those addresses from bypassing
    // normal memory when no MMIO register exists.
    always @(*) begin
        gpio_page_word = gpio_output_read_data;
        case (word_offset)
            6'h00: gpio_page_word = gpio_output_read_data;
            6'h01: gpio_page_word = gpio_input_read_data;
            default: gpio_page_word = gpio_output_read_data;
        endcase
    end

    always @(*) begin
        uart_page_word = gpio_output_read_data;
        case (word_offset)
            6'h00: uart_page_word = gpio_output_read_data;
            6'h01: uart_page_word = uart_rx_read_data;
            6'h02: uart_page_word = uart_status_read_data;
            default: uart_page_word = gpio_output_read_data;
        endcase
    end

    always @(*) begin
        perf_page_word = gpio_output_read_data;
        case (word_offset)
            6'h00: perf_page_word = perf_cycle_count_read_data;
            6'h01: perf_page_word = perf_retired_count_read_data;
            6'h02: perf_page_word = perf_branch_miss_count_read_data;
            6'h03: perf_page_word = perf_icache_miss_count_read_data;
            6'h04: perf_page_word = perf_dcache_miss_count_read_data;
            6'h05: perf_page_word = perf_stall_cycle_count_read_data;
            6'h06: perf_page_word = perf_matvec_start_count_read_data;
            6'h07: perf_page_word = perf_matvec_done_count_read_data;
            6'h08: perf_page_word = perf_matvec_busy_cycle_count_read_data;
            default: perf_page_word = gpio_output_read_data;
        endcase
    end

    always @(*) begin
        matvec_page_word = gpio_output_read_data;
        case (word_offset)
            6'h00: matvec_page_word = gpio_output_read_data;
            6'h01: matvec_page_word = matvec_status_read_data;
            6'h02: matvec_page_word = matvec_config_read_data;
            6'h03: matvec_page_word = matvec_vector_read_data;
            6'h04: matvec_page_word = matvec_row_index_read_data;
            6'h05: matvec_page_word = matvec_row_data_read_data;
            6'h06: matvec_page_word = matvec_result_index_read_data;
            6'h07: matvec_page_word = matvec_result_data_read_data;
            6'h08: matvec_page_word = matvec_perf_read_data;
            default: matvec_page_word = gpio_output_read_data;
        endcase
    end

    always @(*) begin
        timer_page_word = gpio_output_read_data;
        case (word_offset)
            6'h00: timer_page_word = timer_mtime_low_read_data;
            6'h01: timer_page_word = timer_mtime_high_read_data;
            6'h02: timer_page_word = timer_mtimecmp_low_read_data;
            6'h03: timer_page_word = timer_mtimecmp_high_read_data;
            default: timer_page_word = gpio_output_read_data;
        endcase
    end

    always @(*) begin
        matvec_dma_page_word = gpio_output_read_data;
        case (word_offset)
            6'h00: matvec_dma_page_word = matvec_dma_vec_addr_read_data;
            6'h01: matvec_dma_page_word = matvec_dma_matrix_addr_read_data;
            6'h02: matvec_dma_page_word = matvec_dma_out_addr_read_data;
            6'h03: matvec_dma_page_word = matvec_dma_rows_read_data;
            6'h04: matvec_dma_page_word = matvec_dma_ctrl_read_data;
            6'h05: matvec_dma_page_word = matvec_dma_status_read_data;
            6'h06: matvec_dma_page_word = matvec_dma_error_read_data;
            6'h07: matvec_dma_page_word = matvec_dma_perf_read_data;
            default: matvec_dma_page_word = gpio_output_read_data;
        endcase
    end

    always @(*) begin
        read_word = gpio_output_read_data;
        if (addr[31:12] == 20'h0) begin
            case (addr[11:8])
                4'h2: read_word = gpio_page_word;
                4'h3: read_word = uart_page_word;
                4'h6: read_word = perf_page_word;
                4'h7: read_word = matvec_page_word;
                4'h8: read_word = timer_page_word;
                4'h9: read_word = matvec_dma_page_word;
                default: read_word = gpio_output_read_data;
            endcase
        end
    end
endmodule
