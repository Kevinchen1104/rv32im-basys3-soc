`timescale 1ns / 1ps

// Module: uart_tx
// Role: Minimal MMIO-facing UART transmitter for board-facing serial output.
// Interface: Clock/reset, byte data plus start strobe, busy/ready status, and one serial tx line.
// Key behavior: Emits idle-high 8N1 frames using a parameterized clock divisor and holds busy until the stop bit completes.

module uart_tx #(
    parameter CLKS_PER_BIT = 4
) (
    input clock,
    input reset,
    input [7:0] data_in,
    input valid,
    output ready,
    output reg tx,
    output busy
);

    localparam STATE_IDLE = 2'd0;
    localparam STATE_START = 2'd1;
    localparam STATE_DATA = 2'd2;
    localparam STATE_STOP = 2'd3;
    localparam CONFIG_VALID = (CLKS_PER_BIT >= 1);
    localparam SAFE_CLKS_PER_BIT = CONFIG_VALID ? CLKS_PER_BIT : 1;

    reg [1:0] state = STATE_IDLE;
    reg [31:0] clk_count = 32'd0;
    reg [2:0] bit_index = 3'd0;
    reg [7:0] shift_data = 8'h00;

    assign ready = CONFIG_VALID && (state == STATE_IDLE);
    assign busy = CONFIG_VALID && (state != STATE_IDLE);

    always @(posedge clock) begin
        if (reset || !CONFIG_VALID) begin
            state <= STATE_IDLE;
            clk_count <= 32'd0;
            bit_index <= 3'd0;
            shift_data <= 8'h00;
            tx <= 1'b1;
        end else begin
            // 8N1 framing: one low start bit, eight LSB-first data bits, and
            // one high stop bit. The line remains high when idle.
            case (state)
                STATE_IDLE: begin
                    tx <= 1'b1;
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;

                    if (valid) begin
                        shift_data <= data_in;
                        tx <= 1'b0;
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    tx <= 1'b0;
                    if (clk_count == SAFE_CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        tx <= shift_data[0];
                        state <= STATE_DATA;
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                STATE_DATA: begin
                    tx <= shift_data[bit_index];
                    if (clk_count == SAFE_CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            tx <= 1'b1;
                            state <= STATE_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                            tx <= shift_data[bit_index + 3'd1];
                        end
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                STATE_STOP: begin
                    tx <= 1'b1;
                    if (clk_count == SAFE_CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        state <= STATE_IDLE;
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    tx <= 1'b1;
                end
            endcase
        end
    end

endmodule
