`timescale 1ns / 1ps

// Testbench: tb_mmio_decode
// Purpose: Exhaustively checks the public SoC MMIO register map.
// Checks: Exact one-hot selects, byte aliases, aggregate selects, and that
//   0x0400..0x05ff uses ordinary memory rather than MMIO bypass.
// Pass condition: All active registers decode exactly once and every byte alias
//   in 0x0400..0x05ff leaves both aggregate selects deasserted.

module tb_mmio_decode;
    reg [31:0] addr;

    wire gpio_output_sel;
    wire gpio_input_sel;
    wire uart_tx_sel;
    wire uart_rx_sel;
    wire uart_status_sel;
    wire matvec_ctrl_sel;
    wire matvec_status_sel;
    wire matvec_config_sel;
    wire matvec_vector_sel;
    wire matvec_row_index_sel;
    wire matvec_row_data_sel;
    wire matvec_result_index_sel;
    wire matvec_result_data_sel;
    wire matvec_perf_sel;
    wire perf_cycle_count_sel;
    wire perf_retired_count_sel;
    wire perf_branch_miss_count_sel;
    wire perf_icache_miss_count_sel;
    wire perf_dcache_miss_count_sel;
    wire perf_stall_cycle_count_sel;
    wire perf_matvec_start_count_sel;
    wire perf_matvec_done_count_sel;
    wire perf_matvec_busy_cycle_count_sel;
    wire timer_mtime_low_sel;
    wire timer_mtime_high_sel;
    wire timer_mtimecmp_low_sel;
    wire timer_mtimecmp_high_sel;
    wire matvec_dma_vec_addr_sel;
    wire matvec_dma_matrix_addr_sel;
    wire matvec_dma_out_addr_sel;
    wire matvec_dma_rows_sel;
    wire matvec_dma_ctrl_sel;
    wire matvec_dma_status_sel;
    wire matvec_dma_error_sel;
    wire matvec_dma_perf_sel;
    wire matvec_sel;
    wire matvec_dma_sel;
    wire perf_counter_sel;
    wire timer_sel;
    wire any_mmio_sel;

    integer offset_index;

    localparam integer SEL_NONE = -1;
    localparam integer SEL_GPIO_OUTPUT = 0;
    localparam integer SEL_GPIO_INPUT = 1;
    localparam integer SEL_UART_TX = 2;
    localparam integer SEL_UART_RX = 3;
    localparam integer SEL_UART_STATUS = 4;
    localparam integer SEL_MATVEC_CTRL = 5;
    localparam integer SEL_MATVEC_STATUS = 6;
    localparam integer SEL_MATVEC_CONFIG = 7;
    localparam integer SEL_MATVEC_VECTOR = 8;
    localparam integer SEL_MATVEC_ROW_INDEX = 9;
    localparam integer SEL_MATVEC_ROW_DATA = 10;
    localparam integer SEL_MATVEC_RESULT_INDEX = 11;
    localparam integer SEL_MATVEC_RESULT_DATA = 12;
    localparam integer SEL_MATVEC_PERF = 13;
    localparam integer SEL_PERF_CYCLE_COUNT = 14;
    localparam integer SEL_PERF_RETIRED_COUNT = 15;
    localparam integer SEL_PERF_BRANCH_MISS_COUNT = 16;
    localparam integer SEL_PERF_ICACHE_MISS_COUNT = 17;
    localparam integer SEL_PERF_DCACHE_MISS_COUNT = 18;
    localparam integer SEL_PERF_STALL_CYCLE_COUNT = 19;
    localparam integer SEL_PERF_MATVEC_START_COUNT = 20;
    localparam integer SEL_PERF_MATVEC_DONE_COUNT = 21;
    localparam integer SEL_PERF_MATVEC_BUSY_CYCLE_COUNT = 22;
    localparam integer SEL_TIMER_MTIME_LOW = 23;
    localparam integer SEL_TIMER_MTIME_HIGH = 24;
    localparam integer SEL_TIMER_MTIMECMP_LOW = 25;
    localparam integer SEL_TIMER_MTIMECMP_HIGH = 26;
    localparam integer SEL_MATVEC_DMA_VEC_ADDR = 27;
    localparam integer SEL_MATVEC_DMA_MATRIX_ADDR = 28;
    localparam integer SEL_MATVEC_DMA_OUT_ADDR = 29;
    localparam integer SEL_MATVEC_DMA_ROWS = 30;
    localparam integer SEL_MATVEC_DMA_CTRL = 31;
    localparam integer SEL_MATVEC_DMA_STATUS = 32;
    localparam integer SEL_MATVEC_DMA_ERROR = 33;
    localparam integer SEL_MATVEC_DMA_PERF = 34;

    mmio_decode dut (
        .addr(addr),
        .gpio_output_sel(gpio_output_sel),
        .gpio_input_sel(gpio_input_sel),
        .uart_tx_sel(uart_tx_sel),
        .uart_rx_sel(uart_rx_sel),
        .uart_status_sel(uart_status_sel),
        .matvec_ctrl_sel(matvec_ctrl_sel),
        .matvec_status_sel(matvec_status_sel),
        .matvec_config_sel(matvec_config_sel),
        .matvec_vector_sel(matvec_vector_sel),
        .matvec_row_index_sel(matvec_row_index_sel),
        .matvec_row_data_sel(matvec_row_data_sel),
        .matvec_result_index_sel(matvec_result_index_sel),
        .matvec_result_data_sel(matvec_result_data_sel),
        .matvec_perf_sel(matvec_perf_sel),
        .perf_cycle_count_sel(perf_cycle_count_sel),
        .perf_retired_count_sel(perf_retired_count_sel),
        .perf_branch_miss_count_sel(perf_branch_miss_count_sel),
        .perf_icache_miss_count_sel(perf_icache_miss_count_sel),
        .perf_dcache_miss_count_sel(perf_dcache_miss_count_sel),
        .perf_stall_cycle_count_sel(perf_stall_cycle_count_sel),
        .perf_matvec_start_count_sel(perf_matvec_start_count_sel),
        .perf_matvec_done_count_sel(perf_matvec_done_count_sel),
        .perf_matvec_busy_cycle_count_sel(perf_matvec_busy_cycle_count_sel),
        .timer_mtime_low_sel(timer_mtime_low_sel),
        .timer_mtime_high_sel(timer_mtime_high_sel),
        .timer_mtimecmp_low_sel(timer_mtimecmp_low_sel),
        .timer_mtimecmp_high_sel(timer_mtimecmp_high_sel),
        .matvec_dma_vec_addr_sel(matvec_dma_vec_addr_sel),
        .matvec_dma_matrix_addr_sel(matvec_dma_matrix_addr_sel),
        .matvec_dma_out_addr_sel(matvec_dma_out_addr_sel),
        .matvec_dma_rows_sel(matvec_dma_rows_sel),
        .matvec_dma_ctrl_sel(matvec_dma_ctrl_sel),
        .matvec_dma_status_sel(matvec_dma_status_sel),
        .matvec_dma_error_sel(matvec_dma_error_sel),
        .matvec_dma_perf_sel(matvec_dma_perf_sel),
        .matvec_sel(matvec_sel),
        .matvec_dma_sel(matvec_dma_sel),
        .perf_counter_sel(perf_counter_sel),
        .timer_sel(timer_sel),
        .any_mmio_sel(any_mmio_sel)
    );

    function [34:0] exact_selects;
        begin
            exact_selects = {
                matvec_dma_perf_sel,
                matvec_dma_error_sel,
                matvec_dma_status_sel,
                matvec_dma_ctrl_sel,
                matvec_dma_rows_sel,
                matvec_dma_out_addr_sel,
                matvec_dma_matrix_addr_sel,
                matvec_dma_vec_addr_sel,
                timer_mtimecmp_high_sel,
                timer_mtimecmp_low_sel,
                timer_mtime_high_sel,
                timer_mtime_low_sel,
                perf_matvec_busy_cycle_count_sel,
                perf_matvec_done_count_sel,
                perf_matvec_start_count_sel,
                perf_stall_cycle_count_sel,
                perf_dcache_miss_count_sel,
                perf_icache_miss_count_sel,
                perf_branch_miss_count_sel,
                perf_retired_count_sel,
                perf_cycle_count_sel,
                matvec_perf_sel,
                matvec_result_data_sel,
                matvec_result_index_sel,
                matvec_row_data_sel,
                matvec_row_index_sel,
                matvec_vector_sel,
                matvec_config_sel,
                matvec_status_sel,
                matvec_ctrl_sel,
                uart_status_sel,
                uart_rx_sel,
                uart_tx_sel,
                gpio_input_sel,
                gpio_output_sel
            };
        end
    endfunction

    function integer selected_count;
        integer bit_index;
        reg [34:0] bits;
        begin
            bits = exact_selects();
            selected_count = 0;
            for (bit_index = 0; bit_index < 35; bit_index = bit_index + 1)
                selected_count = selected_count + bits[bit_index];
        end
    endfunction

    task check_one;
        input [31:0] test_addr;
        input integer expected_bit;
        input expected_matvec;
        input expected_perf;
        input expected_timer;
        input expected_dma;
        reg [34:0] expected;
        begin
            expected = 35'h0;
            if (expected_bit >= 0)
                expected[expected_bit] = 1'b1;
            addr = test_addr;
            #1;
            if (exact_selects() !== expected) begin
                $display("FAIL: addr=%08x expected=%09x actual=%09x",
                         test_addr, expected, exact_selects());
                $fatal(1);
            end
            if ((matvec_sel !== expected_matvec) ||
                (perf_counter_sel !== expected_perf) ||
                (timer_sel !== expected_timer) ||
                (matvec_dma_sel !== expected_dma) ||
                (any_mmio_sel !== (expected_bit >= 0))) begin
                $display("FAIL: aggregate select mismatch at addr=%08x", test_addr);
                $fatal(1);
            end
            if (selected_count() !== ((expected_bit >= 0) ? 1 : 0)) begin
                $display("FAIL: exact select count mismatch at addr=%08x", test_addr);
                $fatal(1);
            end
        end
    endtask

    task check_valid_aliases;
        input [31:0] register_addr;
        integer lane;
        begin
            for (lane = 0; lane < 4; lane = lane + 1) begin
                addr = register_addr + lane;
                #1;
                if (!any_mmio_sel || (selected_count() !== 1)) begin
                    $display("FAIL: valid MMIO alias addr=%08x", addr);
                    $fatal(1);
                end
            end
        end
    endtask

    task check_invalid_aliases;
        input [31:0] word_addr;
        integer lane;
        begin
            for (lane = 0; lane < 4; lane = lane + 1) begin
                addr = word_addr + lane;
                #1;
                if (any_mmio_sel || (selected_count() !== 0)) begin
                    $display("FAIL: ordinary-memory address decoded as MMIO addr=%08x", addr);
                    $fatal(1);
                end
            end
        end
    endtask

    initial begin
        check_one(32'h0000_0200, SEL_GPIO_OUTPUT, 0, 0, 0, 0);
        check_one(32'h0000_0204, SEL_GPIO_INPUT, 0, 0, 0, 0);
        check_one(32'h0000_0300, SEL_UART_TX, 0, 0, 0, 0);
        check_one(32'h0000_0304, SEL_UART_RX, 0, 0, 0, 0);
        check_one(32'h0000_0308, SEL_UART_STATUS, 0, 0, 0, 0);

        check_one(32'h0000_0600, SEL_PERF_CYCLE_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_0604, SEL_PERF_RETIRED_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_0608, SEL_PERF_BRANCH_MISS_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_060c, SEL_PERF_ICACHE_MISS_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_0610, SEL_PERF_DCACHE_MISS_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_0614, SEL_PERF_STALL_CYCLE_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_0618, SEL_PERF_MATVEC_START_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_061c, SEL_PERF_MATVEC_DONE_COUNT, 0, 1, 0, 0);
        check_one(32'h0000_0620, SEL_PERF_MATVEC_BUSY_CYCLE_COUNT, 0, 1, 0, 0);

        check_one(32'h0000_0700, SEL_MATVEC_CTRL, 1, 0, 0, 0);
        check_one(32'h0000_0704, SEL_MATVEC_STATUS, 1, 0, 0, 0);
        check_one(32'h0000_0708, SEL_MATVEC_CONFIG, 1, 0, 0, 0);
        check_one(32'h0000_070c, SEL_MATVEC_VECTOR, 1, 0, 0, 0);
        check_one(32'h0000_0710, SEL_MATVEC_ROW_INDEX, 1, 0, 0, 0);
        check_one(32'h0000_0714, SEL_MATVEC_ROW_DATA, 1, 0, 0, 0);
        check_one(32'h0000_0718, SEL_MATVEC_RESULT_INDEX, 1, 0, 0, 0);
        check_one(32'h0000_071c, SEL_MATVEC_RESULT_DATA, 1, 0, 0, 0);
        check_one(32'h0000_0720, SEL_MATVEC_PERF, 1, 0, 0, 0);

        check_one(32'h0000_0800, SEL_TIMER_MTIME_LOW, 0, 0, 1, 0);
        check_one(32'h0000_0804, SEL_TIMER_MTIME_HIGH, 0, 0, 1, 0);
        check_one(32'h0000_0808, SEL_TIMER_MTIMECMP_LOW, 0, 0, 1, 0);
        check_one(32'h0000_080c, SEL_TIMER_MTIMECMP_HIGH, 0, 0, 1, 0);

        check_one(32'h0000_0900, SEL_MATVEC_DMA_VEC_ADDR, 0, 0, 0, 1);
        check_one(32'h0000_0904, SEL_MATVEC_DMA_MATRIX_ADDR, 0, 0, 0, 1);
        check_one(32'h0000_0908, SEL_MATVEC_DMA_OUT_ADDR, 0, 0, 0, 1);
        check_one(32'h0000_090c, SEL_MATVEC_DMA_ROWS, 0, 0, 0, 1);
        check_one(32'h0000_0910, SEL_MATVEC_DMA_CTRL, 0, 0, 0, 1);
        check_one(32'h0000_0914, SEL_MATVEC_DMA_STATUS, 0, 0, 0, 1);
        check_one(32'h0000_0918, SEL_MATVEC_DMA_ERROR, 0, 0, 0, 1);
        check_one(32'h0000_091c, SEL_MATVEC_DMA_PERF, 0, 0, 0, 1);

        for (offset_index = 0; offset_index <= 1; offset_index = offset_index + 1)
            check_valid_aliases(32'h0000_0200 + (offset_index * 4));
        for (offset_index = 0; offset_index <= 2; offset_index = offset_index + 1)
            check_valid_aliases(32'h0000_0300 + (offset_index * 4));
        for (offset_index = 0; offset_index <= 8; offset_index = offset_index + 1) begin
            check_valid_aliases(32'h0000_0600 + (offset_index * 4));
            check_valid_aliases(32'h0000_0700 + (offset_index * 4));
        end
        for (offset_index = 0; offset_index <= 3; offset_index = offset_index + 1)
            check_valid_aliases(32'h0000_0800 + (offset_index * 4));
        for (offset_index = 0; offset_index <= 7; offset_index = offset_index + 1)
            check_valid_aliases(32'h0000_0900 + (offset_index * 4));

        // Every word and byte alias in 0x0400..0x05ff must use ordinary memory
        // behavior. This guards the D-cache bypass boundary directly.
        for (offset_index = 0; offset_index < 64; offset_index = offset_index + 1) begin
            check_invalid_aliases(32'h0000_0400 + (offset_index * 4));
            check_invalid_aliases(32'h0000_0500 + (offset_index * 4));
        end

        check_invalid_aliases(32'h0000_0208);
        check_invalid_aliases(32'h0000_030c);
        check_invalid_aliases(32'h0000_0624);
        check_invalid_aliases(32'h0000_0724);
        check_invalid_aliases(32'h0000_0810);
        check_invalid_aliases(32'h0000_0920);
        check_one(32'h0000_0000, SEL_NONE, 0, 0, 0, 0);
        check_one(32'h0001_0200, SEL_NONE, 0, 0, 0, 0);
        check_one(32'hffff_ffff, SEL_NONE, 0, 0, 0, 0);

        $display("PASS: tb_mmio_decode passed");
        $finish;
    end
endmodule
