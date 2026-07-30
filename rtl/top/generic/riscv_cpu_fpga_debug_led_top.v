`timescale 1ns / 1ps

// Module: RISCVCPU_fpga_debug_led_top
// Role: Debug LED wrapper for FPGA smoke and bring-up visibility.
// Interface: Clock/reset, optional board inputs, LED outputs, and selected CPU status/debug signals.
// Key behavior: Runs the CPU wrapper and maps reset/done/pass/fail style debug flags onto LED-visible outputs.
// Non-goals: LED indications are bring-up aids, not timing or physical-board validation evidence by themselves.

module RISCVCPU_fpga_debug_led_top #(
    parameter MEMORY_WORD_COUNT = 1024,
    parameter PROGRAM_HEX = "firmware/hex/showcase/board_smoke.hex",
    parameter PROGRAM_WORD_COUNT = 7,
    parameter RESET_ACTIVE_LOW = 0,
    parameter LEDS_ACTIVE_LOW = 0,
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

    RISCVCPU_fpga_top #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
        .PROGRAM_HEX(PROGRAM_HEX),
        .PROGRAM_WORD_COUNT(PROGRAM_WORD_COUNT),
        .RESET_ACTIVE_LOW(RESET_ACTIVE_LOW),
        .LEDS_ACTIVE_LOW(LEDS_ACTIVE_LOW),
        .LEDS_SHOW_DEBUG_FLAGS(1),
        .HEARTBEAT_COUNTER_BIT(HEARTBEAT_COUNTER_BIT),
        .UART_TX_CLKS_PER_BIT(UART_TX_CLKS_PER_BIT),
        .DONE_PC(DONE_PC),
        .EXPECTED_STATUS(EXPECTED_STATUS)
    ) wrapper (
        .clock(clock),
        .reset(reset),
        .gpio_inputs(gpio_inputs),
        .uart_tx_ready(uart_tx_ready),
        .uart_rx_data(uart_rx_data),
        .uart_rx_valid(uart_rx_valid),
        .leds(leds),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(uart_tx_data),
        .uart_tx_valid(uart_tx_valid),
        .uart_tx(uart_tx),
        .uart_rx_ready(uart_rx_ready),
        .done(done),
        .smoke_pass(smoke_pass),
        .smoke_fail(smoke_fail),
        .heartbeat(heartbeat),
        .config_error(config_error),
        .debug_flags(debug_flags),
        .debug_status(debug_status),
        .debug_pc(debug_pc)
    );

endmodule
