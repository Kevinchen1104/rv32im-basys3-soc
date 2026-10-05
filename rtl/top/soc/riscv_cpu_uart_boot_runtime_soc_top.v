`timescale 1ns / 1ps

// Module: RISCVCPU_uart_boot_runtime_soc_top
// Role: SoC top that boots through packetized UART and then hands the UART RX path to runtime firmware.
// Interface: Clock/reset, serial UART RX/TX, GPIO, debug/status, and boot/runtime observability outputs.
// Key behavior: Holds the CPU in reset during boot loading, releases it on a valid packet image, then routes serial RX to the running CPU.
// Non-goals: This is a simulation-tested boot/runtime integration path, not a secure boot ROM or physical-board validation claim.

module RISCVCPU_uart_boot_runtime_soc_top #(
    parameter MEMORY_WORD_COUNT = 1024,
    parameter FAST_MULTIPLY = 0,
    parameter ICACHE_BYTES = 64,
    parameter ICACHE_PARALLEL_LOOKUP = 1,
    parameter DCACHE_BYTES = 64,
    parameter DCACHE_VICTIM_LINES = 0,
    parameter ENABLE_MATVEC_SCRATCHPAD = 1,
    parameter ENABLE_MATVEC_DMA = 1,
    parameter RESET_ACTIVE_LOW = 0,
    parameter LEDS_ACTIVE_LOW = 0,
    parameter LEDS_SHOW_DEBUG_FLAGS = 1,
    parameter HEARTBEAT_COUNTER_BIT = 23,
    parameter UART_RX_CLKS_PER_BIT = 868,
    parameter UART_TX_CLKS_PER_BIT = 868,
    parameter [31:0] EXPECTED_STATUS = 32'h600d_cafe,
    parameter [31:0] FAIL_STATUS = 32'hbad0_a5a5
) (
    input clock,
    input reset,
    input uart_rx,
    output uart_tx,
    output [7:0] leds,
    input [31:0] gpio_inputs,
    output [31:0] gpio_outputs,
    output done,
    output boot_waiting,
    output loader_done,
    output boot_error,
    output smoke_pass,
    output smoke_fail,
    output heartbeat,
    output [3:0] debug_flags,
    output [31:0] debug_status,
    output [31:0] debug_pc,
    output runtime_uart_rx_valid,
    output runtime_uart_rx_overrun,
    output external_dmem_read_seen,
    output external_dmem_write_seen
);

    (* ASYNC_REG = "TRUE" *) reg reset_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg reset_sync = 1'b1;
    reg [31:0] heartbeat_counter = 32'd0;

    localparam DEBUG_STATUS_WORD = 64;
    localparam HEARTBEAT_CONFIG_VALID =
        (HEARTBEAT_COUNTER_BIT >= 0) && (HEARTBEAT_COUNTER_BIT <= 31);
    localparam SAFE_HEARTBEAT_COUNTER_BIT =
        HEARTBEAT_CONFIG_VALID ? HEARTBEAT_COUNTER_BIT : 0;
    localparam UART_CONFIG_VALID =
        (UART_RX_CLKS_PER_BIT >= 3) && (UART_TX_CLKS_PER_BIT >= 1);

    wire reset_asserted = RESET_ACTIVE_LOW ? ~reset : reset;
    wire packet_cpu_reset;
    wire [31:0] imem_addr;
    wire imem_read;
    wire [127:0] imem_rdata;
    wire imem_ready;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire [127:0] dmem_rdata;
    wire dmem_ready;
    wire [31:0] cpu_debug_status;
    wire [31:0] cpu_debug_pc;
    wire [31:0] cpu_gpio_outputs;
    wire [7:0] cpu_uart_tx_data;
    wire cpu_uart_tx_valid;
    wire cpu_uart_tx_ready;
    wire [7:0] serial_rx_data;
    wire serial_rx_valid;
    wire serial_rx_framing_error;
    wire boot_rx_ready;
    wire runtime_enabled;
    wire [7:0] buffered_uart_rx_data;
    wire buffered_uart_rx_valid;
    wire cpu_uart_rx_ready;
    wire loader_boot_error;
    wire cpu_config_error;
    wire dmem_config_error;
    wire wrapper_config_error =
        (MEMORY_WORD_COUNT <= DEBUG_STATUS_WORD) ||
        !HEARTBEAT_CONFIG_VALID ||
        !UART_CONFIG_VALID;
    wire integration_config_error =
        wrapper_config_error || cpu_config_error || dmem_config_error;
    wire soc_cpu_reset = packet_cpu_reset || integration_config_error;
    wire [3:0] debug_flag_value;
    wire [7:0] led_value = LEDS_SHOW_DEBUG_FLAGS ? {4'b0000, debug_flag_value} : debug_status[7:0];

    // Both assertion and release cross the board-reset boundary through
    // synchronous flops. The power-up values hold reset until two clean clock
    // samples have propagated, and no async-reset register drives BRAM control.
    always @(posedge clock) begin
        reset_meta <= reset_asserted;
        reset_sync <= reset_meta;
    end

    always @(posedge clock) begin
        if (reset_sync) begin
            heartbeat_counter <= 32'd0;
        end else begin
            heartbeat_counter <= heartbeat_counter + 32'd1;
        end
    end

    uart_rx #(
        .CLKS_PER_BIT(UART_RX_CLKS_PER_BIT)
    ) serial_rx (
        .clock(clock),
        .reset(reset_sync),
        .rx(uart_rx),
        .data_out(serial_rx_data),
        .valid(serial_rx_valid),
        .busy(),
        .framing_error(serial_rx_framing_error)
    );

    assign runtime_enabled = loader_done && !boot_error;

    uart_packet_boot_imem #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT)
    ) boot_imem (
        .clock(clock),
        .external_reset(reset_sync),
        .rx_data(serial_rx_data),
        .rx_valid(serial_rx_valid && !runtime_enabled && boot_rx_ready),
        .rx_ready(boot_rx_ready),
        .cpu_reset(packet_cpu_reset),
        .boot_waiting(boot_waiting),
        .loader_done(loader_done),
        .loader_busy(),
        .boot_error(loader_boot_error),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(imem_rdata),
        .imem_ready(imem_ready)
    );

    uart_rx_mmio_buffer #(.DEPTH(64)) runtime_rx_buffer (
        .clock(clock),
        .reset(reset_sync),
        .rx_data_in(serial_rx_data),
        .rx_valid_in(serial_rx_valid && runtime_enabled && !serial_rx_framing_error),
        .cpu_ready(cpu_uart_rx_ready),
        .rx_data(buffered_uart_rx_data),
        .rx_valid(buffered_uart_rx_valid),
        .overrun(runtime_uart_rx_overrun)
    );

    external_dmem_bram #(
        .WORD_COUNT(MEMORY_WORD_COUNT)
    ) dmem (
        .clock(clock),
        .reset(soc_cpu_reset),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
        .config_error(dmem_config_error),
        .read_seen(external_dmem_read_seen),
        .write_seen(external_dmem_write_seen)
    );

    RISCVCPU #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
        .USE_EXTERNAL_IMEM(1),
        .USE_EXTERNAL_DMEM(1),
        .FAST_MULTIPLY(FAST_MULTIPLY),
        .ICACHE_BYTES(ICACHE_BYTES),
        .ICACHE_PARALLEL_LOOKUP(ICACHE_PARALLEL_LOOKUP),
        .DCACHE_BYTES(DCACHE_BYTES),
        .DCACHE_VICTIM_LINES(DCACHE_VICTIM_LINES),
        .ENABLE_MATVEC_SCRATCHPAD(ENABLE_MATVEC_SCRATCHPAD),
        .ENABLE_MATVEC_DMA(ENABLE_MATVEC_DMA)
    ) cpu (
        .clock(clock),
        .reset(soc_cpu_reset),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(imem_rdata),
        .imem_ready(imem_ready),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
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
        .perf_matvec_start_count(),
        .perf_matvec_done_count(),
        .perf_matvec_busy_cycle_count(),
        .gpio_inputs(gpio_inputs),
        .gpio_outputs(cpu_gpio_outputs),
        .uart_tx_data(cpu_uart_tx_data),
        .uart_tx_valid(cpu_uart_tx_valid),
        .uart_tx_ready(cpu_uart_tx_ready),
        .uart_rx_data(buffered_uart_rx_data),
        .uart_rx_valid(buffered_uart_rx_valid),
        .uart_rx_overrun(runtime_uart_rx_overrun),
        .uart_rx_ready(cpu_uart_rx_ready),
        .config_error(cpu_config_error)
    );

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

    assign debug_status = cpu_debug_status;
    assign debug_pc = cpu_debug_pc;
    assign gpio_outputs = cpu_gpio_outputs;
    assign runtime_uart_rx_valid = buffered_uart_rx_valid;
    assign boot_error = loader_boot_error || integration_config_error;
    assign done = loader_done && !boot_error &&
                  ((debug_status == EXPECTED_STATUS) || (debug_status == FAIL_STATUS));
    assign smoke_pass = loader_done && !boot_error && (debug_status == EXPECTED_STATUS);
    assign smoke_fail = boot_error || (loader_done && (debug_status == FAIL_STATUS));
    assign heartbeat = HEARTBEAT_CONFIG_VALID ?
        heartbeat_counter[SAFE_HEARTBEAT_COUNTER_BIT] : 1'b0;
    assign debug_flag_value = {boot_waiting, loader_done, smoke_pass, smoke_fail};
    assign debug_flags = debug_flag_value;
    assign leds = LEDS_ACTIVE_LOW ? ~led_value : led_value;

endmodule
