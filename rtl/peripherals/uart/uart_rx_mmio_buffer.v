`timescale 1ns / 1ps

// Module: uart_rx_mmio_buffer
// MMIO RX queue. A read consumes the oldest byte; overflow drops the new byte.
// DEPTH=1 preserves the original holding-register behavior.

module uart_rx_mmio_buffer #(
    parameter DEPTH = 1
) (
    input clock,
    input reset,
    input [7:0] rx_data_in,
    input rx_valid_in,
    input cpu_ready,
    output [7:0] rx_data,
    output rx_valid,
    output reg overrun
);

    localparam PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam LAST_ENTRY = DEPTH - 1;
    reg [7:0] memory [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] read_pointer, write_pointer;
    reg [COUNT_WIDTH-1:0] count;
    reg [7:0] last_read;
    wire pop = cpu_ready && rx_valid;
    wire push = rx_valid_in && ((count < DEPTH) || pop);

    assign rx_valid = (count != 0);
    assign rx_data = rx_valid ? memory[read_pointer] : last_read;

    always @(posedge clock) begin
        if (reset) begin
            read_pointer <= 0;
            write_pointer <= 0;
            count <= 0;
            last_read <= 0;
            overrun <= 1'b0;
        end else begin
            if (pop) begin
                last_read <= memory[read_pointer];
                read_pointer <= (read_pointer == LAST_ENTRY[PTR_WIDTH-1:0]) ? 0 : read_pointer + 1'b1;
            end
            if (push) begin
                memory[write_pointer] <= rx_data_in;
                write_pointer <= (write_pointer == LAST_ENTRY[PTR_WIDTH-1:0]) ? 0 : write_pointer + 1'b1;
            end
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: count <= count;
            endcase
            if (rx_valid_in && !push)
                overrun <= 1'b1;
        end
    end

endmodule
