`timescale 1ns / 1ps

// Module: RISCVCPU_uart_boot_bram_soc_top
// Role: BRAM-backed SoC top for packetized UART boot with external-style instruction and data memories.
// Interface: Clock/reset, UART, GPIO, debug/status, and BRAM-backed memory integration signals.
// Key behavior: Loads the program image through UART boot logic and runs the CPU against BRAM-backed memory adapters.
// Non-goals: The BRAM integration is not a cache-coherent memory fabric or physical-board validation claim.

module RISCVCPU_uart_boot_bram_soc_top #(
    parameter MEMORY_WORD_COUNT = 1024,
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
        (UART_RX_CLKS_PER_BIT >= 1) && (UART_TX_CLKS_PER_BIT >= 1);

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

    uart_serial_packet_boot_imem #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
        .UART_CLKS_PER_BIT(UART_RX_CLKS_PER_BIT)
    ) boot_imem (
        .clock(clock),
        .external_reset(reset_sync),
        .uart_rx_pin(uart_rx),
        .cpu_reset(packet_cpu_reset),
        .boot_waiting(boot_waiting),
        .loader_done(loader_done),
        .loader_busy(),
        .boot_error(loader_boot_error),
        .rx_busy(),
        .rx_framing_error(),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(imem_rdata),
        .imem_ready(imem_ready)
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
        .USE_EXTERNAL_DMEM(1)
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
        .gpio_inputs(gpio_inputs),
        .gpio_outputs(cpu_gpio_outputs),
        .uart_tx_data(cpu_uart_tx_data),
        .uart_tx_valid(cpu_uart_tx_valid),
        .uart_tx_ready(cpu_uart_tx_ready),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(),
        .perf_matvec_start_count(),
        .perf_matvec_done_count(),
        .perf_matvec_busy_cycle_count(),
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
