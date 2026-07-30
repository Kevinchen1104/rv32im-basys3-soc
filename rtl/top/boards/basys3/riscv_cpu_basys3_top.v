`timescale 1ns / 1ps

// Module: RISCVCPU_basys3_top
// Role: Basys3-oriented FPGA wrapper around the CPU/SoC top-level signals.
// Interface: Board clock/reset, UART pins, LEDs, switches/buttons, and debug/status outputs.
// Key behavior: Adapts reset polarity and board-facing I/O while preserving the core SoC behavior underneath.
// Non-goals: This wrapper does not by itself claim timing closure or physical-board validation.

module RISCVCPU_basys3_top #(
    parameter MEMORY_WORD_COUNT = 1024,
    parameter UART_RX_CLKS_PER_BIT = 868,
    parameter UART_TX_CLKS_PER_BIT = 868,
    parameter HEARTBEAT_COUNTER_BIT = 23
) (
    input clk,
    input btnC,
    input RsRx,
    output RsTx,
    input [15:0] sw,
    output [15:0] led
);

    wire [7:0] runtime_leds;
    wire [31:0] gpio_outputs;
    wire done;
    wire smoke_pass;
    wire smoke_fail;
    wire heartbeat;
    (* ASYNC_REG = "TRUE" *) reg [15:0] sw_meta = 16'h0000;
    (* ASYNC_REG = "TRUE" *) reg [15:0] sw_sync = 16'h0000;

    // Each asynchronous board switch is synchronized independently before it
    // enters the GPIO register path. Software must still treat simultaneous
    // multi-switch changes as non-atomic.
    always @(posedge clk or posedge btnC) begin
        if (btnC) begin
            sw_meta <= 16'h0000;
            sw_sync <= 16'h0000;
        end else begin
            sw_meta <= sw;
            sw_sync <= sw_meta;
        end
    end

    RISCVCPU_uart_boot_runtime_soc_top #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
        .RESET_ACTIVE_LOW(0),
        .LEDS_ACTIVE_LOW(0),
        .LEDS_SHOW_DEBUG_FLAGS(1),
        .HEARTBEAT_COUNTER_BIT(HEARTBEAT_COUNTER_BIT),
        .UART_RX_CLKS_PER_BIT(UART_RX_CLKS_PER_BIT),
        .UART_TX_CLKS_PER_BIT(UART_TX_CLKS_PER_BIT)
    ) soc (
        .clock(clk),
        .reset(btnC),
        .uart_rx(RsRx),
        .uart_tx(RsTx),
        .leds(runtime_leds),
        .gpio_inputs({16'h0000, sw_sync}),
        .gpio_outputs(gpio_outputs),
        .done(done),
        .boot_waiting(),
        .loader_done(),
        .boot_error(),
        .smoke_pass(smoke_pass),
        .smoke_fail(smoke_fail),
        .heartbeat(heartbeat),
        .debug_flags(),
        .debug_status(),
        .debug_pc(),
        .runtime_uart_rx_valid(),
        .runtime_uart_rx_overrun(),
        .external_dmem_read_seen(),
        .external_dmem_write_seen()
    );

    assign led[0] = smoke_pass;
    assign led[1] = smoke_fail;
    assign led[2] = done;
    assign led[3] = heartbeat;
    assign led[7:4] = runtime_leds[3:0];
    assign led[15:8] = gpio_outputs[7:0];

endmodule
