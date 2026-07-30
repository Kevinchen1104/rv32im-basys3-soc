`timescale 1ns / 1ps

// Module: RISCVCPU_basys3_full_lowfreq_top
// Role: Runs the complete Basys3 UART boot/runtime SoC at a timing-oriented 6.25 MHz clock.
// Interface: Preserves the Basys3 clock, reset button, USB-UART, switches, and LED port contract.
// Key behavior: Holds the existing full SoC in reset until the MMCM locks, then forwards all board I/O unchanged.
// Non-goals: Timing closure for this target does not imply 100 MHz full-top closure or physical-board validation.

module RISCVCPU_basys3_full_lowfreq_top #(
    parameter MEMORY_WORD_COUNT = 1024,
    parameter UART_RX_CLKS_PER_BIT = 54,
    parameter UART_TX_CLKS_PER_BIT = 54,
    parameter HEARTBEAT_COUNTER_BIT = 21
) (
    input clk,
    input btnC,
    input RsRx,
    output RsTx,
    input [15:0] sw,
    output [15:0] led
);

    wire soc_clk;
    wire clock_locked;
    wire soc_reset;

    basys3_lowfreq_clock_gen clock_gen (
        .clk(clk),
        .reset(btnC),
        .soc_clk(soc_clk),
        .locked(clock_locked)
    );

    assign soc_reset = btnC || !clock_locked;

    RISCVCPU_basys3_top #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
        .UART_RX_CLKS_PER_BIT(UART_RX_CLKS_PER_BIT),
        .UART_TX_CLKS_PER_BIT(UART_TX_CLKS_PER_BIT),
        .HEARTBEAT_COUNTER_BIT(HEARTBEAT_COUNTER_BIT)
    ) full_soc (
        .clk(soc_clk),
        .btnC(soc_reset),
        .RsRx(RsRx),
        .RsTx(RsTx),
        .sw(sw),
        .led(led)
    );

endmodule
