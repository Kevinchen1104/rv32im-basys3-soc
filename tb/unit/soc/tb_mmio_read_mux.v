`timescale 1ns / 1ps

// Testbench: tb_mmio_read_mux
// Purpose: Checks readback selection for every active MMIO page.
// Checks: Register markers, low-bit aliases, 0x0400..0x05ff fallback, invalid
//   addresses, and shared byte/halfword load formatting.
// Pass condition: Each active register returns its marker and unmapped/invalid
//   addresses return the ordinary-memory fallback with correct load formatting.

module tb_mmio_read_mux;
    localparam [31:0] FALLBACK_WORD = 32'hf00d_ba5e;

    reg [31:0] addr;
    reg [31:0] gpio_input_read_data;
    reg [2:0] funct3;
    wire [31:0] read_word;
    wire [31:0] formatted_load;
    wire [31:0] unused_store_merged;
    integer errors;

    mmio_read_mux dut (
        .addr(addr),
        .gpio_output_read_data(FALLBACK_WORD),
        .gpio_input_read_data(gpio_input_read_data),
        .uart_rx_read_data(32'h3000_0001),
        .uart_status_read_data(32'h3000_0002),
        .perf_cycle_count_read_data(32'h6000_0000),
        .perf_retired_count_read_data(32'h6000_0001),
        .perf_branch_miss_count_read_data(32'h6000_0002),
        .perf_icache_miss_count_read_data(32'h6000_0003),
        .perf_dcache_miss_count_read_data(32'h6000_0004),
        .perf_stall_cycle_count_read_data(32'h6000_0005),
        .perf_matvec_start_count_read_data(32'h6000_0006),
        .perf_matvec_done_count_read_data(32'h6000_0007),
        .perf_matvec_busy_cycle_count_read_data(32'h6000_0008),
        .matvec_status_read_data(32'h7000_0001),
        .matvec_config_read_data(32'h7000_0002),
        .matvec_vector_read_data(32'h7000_0003),
        .matvec_row_index_read_data(32'h7000_0004),
        .matvec_row_data_read_data(32'h7000_0005),
        .matvec_result_index_read_data(32'h7000_0006),
        .matvec_result_data_read_data(32'h7000_0007),
        .matvec_perf_read_data(32'h7000_0008),
        .timer_mtime_low_read_data(32'h8000_0000),
        .timer_mtime_high_read_data(32'h8000_0001),
        .timer_mtimecmp_low_read_data(32'h8000_0002),
        .timer_mtimecmp_high_read_data(32'h8000_0003),
        .matvec_dma_vec_addr_read_data(32'h9000_0000),
        .matvec_dma_matrix_addr_read_data(32'h9000_0001),
        .matvec_dma_out_addr_read_data(32'h9000_0002),
        .matvec_dma_rows_read_data(32'h9000_0003),
        .matvec_dma_ctrl_read_data(32'h9000_0004),
        .matvec_dma_status_read_data(32'h9000_0005),
        .matvec_dma_error_read_data(32'h9000_0006),
        .matvec_dma_perf_read_data(32'h9000_0007),
        .read_word(read_word)
    );

    load_store_format_unit load_formatter (
        .word_data(read_word),
        .store_data(32'h0),
        .byte_offset(addr[1:0]),
        .funct3(funct3),
        .load_value(formatted_load),
        .store_merged_value(unused_store_merged)
    );

    task check_register;
        input [31:0] base_addr;
        input [31:0] expected;
        input [8*48-1:0] label;
        integer lane;
        begin
            for (lane = 0; lane < 4; lane = lane + 1) begin
                addr = base_addr + lane;
                #1;
                if (read_word !== expected) begin
                    $display("FAIL: %0s alias=%0d expected=%08x actual=%08x",
                             label, lane, expected, read_word);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task check_formatted;
        input [31:0] test_addr;
        input [2:0] test_funct3;
        input [31:0] expected;
        input [8*48-1:0] label;
        begin
            addr = test_addr;
            funct3 = test_funct3;
            #1;
            if (formatted_load !== expected) begin
                $display("FAIL: %0s expected=%08x actual=%08x", label, expected, formatted_load);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        addr = 32'h0;
        funct3 = 3'b010;
        gpio_input_read_data = 32'h2000_0001;

        check_register(32'h0000_0200, FALLBACK_WORD, "GPIO output");
        check_register(32'h0000_0204, 32'h2000_0001, "GPIO input");
        check_register(32'h0000_0300, FALLBACK_WORD, "UART TX write-only");
        check_register(32'h0000_0304, 32'h3000_0001, "UART RX");
        check_register(32'h0000_0308, 32'h3000_0002, "UART status");

        check_register(32'h0000_0600, 32'h6000_0000, "cycle count");
        check_register(32'h0000_0604, 32'h6000_0001, "retired count");
        check_register(32'h0000_0608, 32'h6000_0002, "branch miss count");
        check_register(32'h0000_060c, 32'h6000_0003, "I-cache miss count");
        check_register(32'h0000_0610, 32'h6000_0004, "D-cache miss count");
        check_register(32'h0000_0614, 32'h6000_0005, "stall cycle count");
        check_register(32'h0000_0618, 32'h6000_0006, "MATVEC start count");
        check_register(32'h0000_061c, 32'h6000_0007, "MATVEC done count");
        check_register(32'h0000_0620, 32'h6000_0008, "MATVEC busy count");

        check_register(32'h0000_0700, FALLBACK_WORD, "MATVEC control");
        check_register(32'h0000_0704, 32'h7000_0001, "MATVEC status");
        check_register(32'h0000_0708, 32'h7000_0002, "MATVEC config");
        check_register(32'h0000_070c, 32'h7000_0003, "MATVEC vector");
        check_register(32'h0000_0710, 32'h7000_0004, "MATVEC row index");
        check_register(32'h0000_0714, 32'h7000_0005, "MATVEC row data");
        check_register(32'h0000_0718, 32'h7000_0006, "MATVEC result index");
        check_register(32'h0000_071c, 32'h7000_0007, "MATVEC result data");
        check_register(32'h0000_0720, 32'h7000_0008, "MATVEC perf");

        check_register(32'h0000_0800, 32'h8000_0000, "mtime low");
        check_register(32'h0000_0804, 32'h8000_0001, "mtime high");
        check_register(32'h0000_0808, 32'h8000_0002, "mtimecmp low");
        check_register(32'h0000_080c, 32'h8000_0003, "mtimecmp high");
        check_register(32'h0000_0900, 32'h9000_0000, "DMA vector address");
        check_register(32'h0000_0904, 32'h9000_0001, "DMA matrix address");
        check_register(32'h0000_0908, 32'h9000_0002, "DMA output address");
        check_register(32'h0000_090c, 32'h9000_0003, "DMA rows");
        check_register(32'h0000_0910, 32'h9000_0004, "DMA control");
        check_register(32'h0000_0914, 32'h9000_0005, "DMA status");
        check_register(32'h0000_0918, 32'h9000_0006, "DMA error");
        check_register(32'h0000_091c, 32'h9000_0007, "DMA perf");

        // These addresses are not MMIO, so the mux returns ordinary-memory data.
        check_register(32'h0000_0400, FALLBACK_WORD, "ordinary memory 0x0400");
        check_register(32'h0000_0500, FALLBACK_WORD, "ordinary memory 0x0500");
        check_register(32'h0000_0724, FALLBACK_WORD, "invalid MATVEC offset");
        check_register(32'h0000_0920, FALLBACK_WORD, "invalid DMA offset");
        check_register(32'h1000_0204, FALLBACK_WORD, "high address alias");

        addr = 32'h0000_0204;
        gpio_input_read_data = 32'h1234_5678;
        #1;
        if (read_word !== 32'h1234_5678)
            errors = errors + 1;

        gpio_input_read_data = 32'h80ff_7f01;
        check_formatted(32'h0000_0204, 3'b010, 32'h80ff_7f01, "LW");
        check_formatted(32'h0000_0204, 3'b000, 32'h0000_0001, "LB lane 0");
        check_formatted(32'h0000_0205, 3'b000, 32'h0000_007f, "LB lane 1");
        check_formatted(32'h0000_0206, 3'b000, 32'hffff_ffff, "LB lane 2");
        check_formatted(32'h0000_0207, 3'b000, 32'hffff_ff80, "LB lane 3");
        check_formatted(32'h0000_0206, 3'b100, 32'h0000_00ff, "LBU lane 2");
        check_formatted(32'h0000_0207, 3'b100, 32'h0000_0080, "LBU lane 3");
        check_formatted(32'h0000_0204, 3'b001, 32'h0000_7f01, "LH low");
        check_formatted(32'h0000_0206, 3'b001, 32'hffff_80ff, "LH high");
        check_formatted(32'h0000_0206, 3'b101, 32'h0000_80ff, "LHU high");

        if (errors != 0) begin
            $display("FAIL: tb_mmio_read_mux had %0d errors", errors);
            $fatal(1);
        end
        $display("PASS: tb_mmio_read_mux passed");
        $finish;
    end
endmodule
