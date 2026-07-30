`timescale 1ns / 1ps

// Module: RISCVCPU_fpga_top
// Role: Generic FPGA-facing wrapper around the CPU/SoC core and local memories.
// Interface: Board-style clock/reset inputs, LED/debug/status outputs, GPIO, and UART pins.
// Key behavior: Instantiates the CPU with selectable program image parameters and maps public status/debug signals to top-level ports.
// Non-goals: This wrapper does not claim timing closure or physical-board validation.

module RISCVCPU_fpga_top #(
    parameter MEMORY_WORD_COUNT = 1024,
    parameter PROGRAM_HEX = "firmware/hex/showcase/board_smoke.hex",
    parameter PROGRAM_WORD_COUNT = 7,
    parameter RESET_ACTIVE_LOW = 0,
    parameter LEDS_ACTIVE_LOW = 0,
    parameter LEDS_SHOW_DEBUG_FLAGS = 0,
    parameter HEARTBEAT_COUNTER_BIT = 23,
    parameter UART_TX_CLKS_PER_BIT = 0,
    parameter [31:0] DONE_PC = 32'd24,
    parameter [31:0] EXPECTED_STATUS = 32'h600d_cafe
) (
    input clock,
    input reset,
    input [31:0] gpio_inputs,
    input uart_tx_ready,
    input [7:0] uart_rx_data,
    input uart_rx_valid,
    output [7:0] leds,
    output [31:0] gpio_outputs,
    output [7:0] uart_tx_data,
    output uart_tx_valid,
    output uart_tx,
    output uart_rx_ready,
    output done,
    output smoke_pass,
    output smoke_fail,
    output heartbeat,
    output config_error,
    output [3:0] debug_flags,
    output [31:0] debug_status,
    output [31:0] debug_pc
);

    localparam DEBUG_STATUS_WORD = 64;
    localparam HEARTBEAT_CONFIG_VALID =
        (HEARTBEAT_COUNTER_BIT >= 0) && (HEARTBEAT_COUNTER_BIT <= 31);
    localparam SAFE_HEARTBEAT_COUNTER_BIT =
        HEARTBEAT_CONFIG_VALID ? HEARTBEAT_COUNTER_BIT : 0;
    localparam CONFIG_VALID =
        (MEMORY_WORD_COUNT > DEBUG_STATUS_WORD) &&
        (PROGRAM_WORD_COUNT <= MEMORY_WORD_COUNT) &&
        HEARTBEAT_CONFIG_VALID;

    (* ASYNC_REG = "TRUE" *) reg reset_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg reset_sync = 1'b1;
    reg [31:0] heartbeat_counter = 32'd0;
    wire reset_asserted = RESET_ACTIVE_LOW ? ~reset : reset;
    wire [3:0] debug_flag_value;
    wire [31:0] cpu_debug_status;
    wire [31:0] cpu_debug_pc;
    wire [31:0] cpu_gpio_outputs;
    wire [7:0] cpu_uart_tx_data;
    wire cpu_uart_tx_valid;
    wire cpu_uart_tx_ready;
    wire cpu_uart_rx_ready;
    wire cpu_config_error;
    wire [31:0] cpu_perf_matvec_start_count;
    wire [31:0] cpu_perf_matvec_done_count;
    wire [31:0] cpu_perf_matvec_busy_cycle_count;
    wire [7:0] led_value = LEDS_SHOW_DEBUG_FLAGS ? {4'b0000, debug_flag_value} : debug_status[7:0];

    // Board-facing wrappers synchronize the external reset before it reaches
    // the CPU core; this wrapper still relies on separate timing constraints.
    always @(posedge clock or posedge reset_asserted) begin
        if (reset_asserted) begin
            reset_meta <= 1'b1;
            reset_sync <= 1'b1;
        end else begin
            reset_meta <= 1'b0;
            reset_sync <= reset_meta;
        end
    end

    always @(posedge clock or posedge reset_asserted) begin
        if (reset_asserted) begin
            heartbeat_counter <= 32'd0;
        end else if (reset_sync) begin
            heartbeat_counter <= 32'd0;
        end else begin
            heartbeat_counter <= heartbeat_counter + 32'd1;
        end
    end

    // Invalid parameter combinations elaborate to a visible error wrapper
    // instead of silently building a CPU with too little memory.
    generate
        if (CONFIG_VALID) begin : valid_config
            RISCVCPU #(
                .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
                .INIT_PROGRAM_HEX(PROGRAM_HEX),
                .INIT_PROGRAM_WORD_COUNT(PROGRAM_WORD_COUNT)
            ) cpu (
                .clock(clock),
                .reset(reset_sync),
                .imem_addr(),
                .imem_read(),
                .imem_rdata(128'h0),
                .imem_ready(1'b0),
                .dmem_addr(),
                .dmem_read(),
                .dmem_write(),
                .dmem_wdata(),
                .dmem_byte_enable(),
                .dmem_rdata(128'h0),
                .dmem_ready(1'b0),
                .debug_status(cpu_debug_status),
                .debug_pc(cpu_debug_pc),
                .trace_valid(),
                .trace_pc(),
                .trace_instruction(),
                .trace_rd(),
                .trace_reg_write(),
                .trace_writeback_value(),
                .perf_cycle_count(),
                .perf_retired_count(),
                .perf_branch_miss_count(),
                .perf_icache_miss_count(),
                .perf_dcache_miss_count(),
                .perf_stall_cycle_count(),
                .gpio_inputs(gpio_inputs),
                .gpio_outputs(cpu_gpio_outputs),
                .uart_tx_data(cpu_uart_tx_data),
                .uart_tx_valid(cpu_uart_tx_valid),
                .uart_tx_ready(cpu_uart_tx_ready),
                .uart_rx_data(uart_rx_data),
                .uart_rx_valid(uart_rx_valid),
                .uart_rx_overrun(1'b0),
                .uart_rx_ready(cpu_uart_rx_ready),
                .perf_matvec_start_count(cpu_perf_matvec_start_count),
                .perf_matvec_done_count(cpu_perf_matvec_done_count),
                .perf_matvec_busy_cycle_count(cpu_perf_matvec_busy_cycle_count),
                .config_error(cpu_config_error)
            );
        end else begin : invalid_config
            assign cpu_debug_status = 32'h0;
            assign cpu_debug_pc = 32'h0;
            assign cpu_gpio_outputs = 32'h0;
            assign cpu_uart_tx_data = 8'h00;
            assign cpu_uart_tx_valid = 1'b0;
            assign cpu_uart_rx_ready = 1'b0;
            assign cpu_perf_matvec_start_count = 32'h0;
            assign cpu_perf_matvec_done_count = 32'h0;
            assign cpu_perf_matvec_busy_cycle_count = 32'h0;
            assign cpu_config_error = 1'b1;
        end
    endgenerate

    generate
        if (UART_TX_CLKS_PER_BIT > 0) begin : internal_uart_tx
            uart_tx #(
                .CLKS_PER_BIT(UART_TX_CLKS_PER_BIT)
            ) tx_unit (
                .clock(clock),
                .reset(reset_sync),
                .data_in(cpu_uart_tx_data),
                .valid(cpu_uart_tx_valid),
                .ready(cpu_uart_tx_ready),
                .tx(uart_tx),
                .busy()
            );
        end else begin : external_uart_tx
            assign cpu_uart_tx_ready = uart_tx_ready;
            assign uart_tx = 1'b1;
        end
    endgenerate

    assign config_error = !CONFIG_VALID || cpu_config_error;
    assign debug_status = cpu_debug_status;
    assign debug_pc = cpu_debug_pc;
    assign gpio_outputs = cpu_gpio_outputs;
    assign uart_tx_data = cpu_uart_tx_data;
    assign uart_tx_valid = cpu_uart_tx_valid;
    assign uart_rx_ready = cpu_uart_rx_ready;
    assign leds = LEDS_ACTIVE_LOW ? ~led_value : led_value;
    assign done = !config_error && !reset_sync && (debug_pc == DONE_PC);
    assign smoke_pass = done && (debug_status == EXPECTED_STATUS);
    assign smoke_fail = !config_error && done && (debug_status != EXPECTED_STATUS);
    assign heartbeat = HEARTBEAT_CONFIG_VALID ?
        heartbeat_counter[SAFE_HEARTBEAT_COUNTER_BIT] : 1'b0;
    assign debug_flag_value = {reset_sync, done, smoke_pass, smoke_fail};
    assign debug_flags = debug_flag_value;

endmodule
