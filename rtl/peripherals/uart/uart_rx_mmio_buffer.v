`timescale 1ns / 1ps

// Module: uart_rx_mmio_buffer
// Role: Small MMIO-readable holding register for UART RX bytes.
// Interface: UART byte-valid/data input, CPU read/clear strobes, and packed status/data readback.
// Key behavior: Latches one received byte, reports valid and overrun state, and clears the valid flag on CPU acknowledge.

module uart_rx_mmio_buffer (
    input clock,
    input reset,
    input [7:0] rx_data_in,
    input rx_valid_in,
    input cpu_ready,
    output reg [7:0] rx_data,
    output reg rx_valid,
    output reg overrun
);

    always @(posedge clock) begin
        if (reset) begin
            rx_data <= 8'h00;
            rx_valid <= 1'b0;
            overrun <= 1'b0;
        end else begin
            if (cpu_ready) begin
                rx_valid <= 1'b0;
            end

            if (rx_valid_in) begin
                if (rx_valid && !cpu_ready) begin
                    overrun <= 1'b1;
                end else begin
                    rx_data <= rx_data_in;
                    rx_valid <= 1'b1;
                end
            end
        end
    end

endmodule
