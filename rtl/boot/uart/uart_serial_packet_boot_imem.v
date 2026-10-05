`timescale 1ns / 1ps

// Module: uart_serial_packet_boot_imem
// Role: Serial UART packet boot bridge for loading instruction memory.
// Interface: Clock/reset, serial RX input, memory write port, loader status, and optional debug outputs.
// Key behavior: Deserializes UART bytes, checks the packet format, writes program words, and marks the boot image complete.

module uart_serial_packet_boot_imem #(
    parameter MEMORY_WORD_COUNT = 1024,
    parameter UART_CLKS_PER_BIT = 4
) (
    input clock,
    input external_reset,
    input uart_rx_pin,
    output cpu_reset,
    output boot_waiting,
    output loader_done,
    output loader_busy,
    output boot_error,
    output rx_busy,
    output rx_framing_error,
    input [31:0] imem_addr,
    input imem_read,
    output [127:0] imem_rdata,
    output imem_ready
);

    wire [7:0] rx_data;
    wire rx_valid;
    wire loader_rx_ready;
    wire packet_boot_error;

    // The serial layer only performs UART framing; packet validity and memory
    // writes are handled by the byte-parallel packet loader below.
    uart_rx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) serial_rx (
        .clock(clock),
        .reset(external_reset),
        .rx(uart_rx_pin),
        .data_out(rx_data),
        .valid(rx_valid),
        .busy(rx_busy),
        .framing_error(rx_framing_error)
    );

    uart_packet_boot_imem #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT)
    ) packet_boot_imem (
        .clock(clock),
        .external_reset(external_reset),
        .rx_data(rx_data),
        .rx_valid(rx_valid && loader_rx_ready),
        .rx_ready(loader_rx_ready),
        .cpu_reset(cpu_reset),
        .boot_waiting(boot_waiting),
        .loader_done(loader_done),
        .loader_busy(loader_busy),
        .boot_error(packet_boot_error),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(imem_rdata),
        .imem_ready(imem_ready)
    );

    assign boot_error = packet_boot_error || (UART_CLKS_PER_BIT < 3);

endmodule
