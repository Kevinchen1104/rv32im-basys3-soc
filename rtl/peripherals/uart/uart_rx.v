`timescale 1ns / 1ps

// Module: uart_rx
// Role: Minimal UART receiver used by boot and runtime serial paths.
// Interface: Clock/reset, serial rx input, byte data output, valid pulse, and busy/framing status.
// Key behavior: Synchronizes the asynchronous pin, samples idle-high 8N1 frames at a parameterized divisor, and presents one byte when the stop bit is accepted.

module uart_rx #(
    parameter CLKS_PER_BIT = 4
) (
    input clock,
    input reset,
    input rx,
    output reg [7:0] data_out,
    output reg valid,
    output busy,
    output framing_error
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
    reg framing_error_reg = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg rx_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rx_sync = 1'b1;

    assign busy = CONFIG_VALID && (state != STATE_IDLE);
    assign framing_error = CONFIG_VALID ? framing_error_reg : 1'b1;

    always @(posedge clock) begin
        if (reset || !CONFIG_VALID) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
            state <= STATE_IDLE;
            clk_count <= 32'd0;
            bit_index <= 3'd0;
            shift_data <= 8'h00;
            data_out <= 8'h00;
            valid <= 1'b0;
            framing_error_reg <= 1'b0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            valid <= 1'b0;

            // 8N1 receive framing waits through the middle of the start bit
            // before sampling each LSB-first data bit.
            case (state)
                STATE_IDLE: begin
                    clk_count <= 32'd0;
                    bit_index <= 3'd0;
                    framing_error_reg <= 1'b0;

                    if (rx_sync == 1'b0) begin
                        state <= STATE_START;
                    end
                end

                STATE_START: begin
                    if (clk_count == (SAFE_CLKS_PER_BIT / 2)) begin
                        if (rx_sync == 1'b0) begin
                            clk_count <= 32'd0;
                            state <= STATE_DATA;
                        end else begin
                            state <= STATE_IDLE;
                        end
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                STATE_DATA: begin
                    if (clk_count == SAFE_CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        shift_data[bit_index] <= rx_sync;

                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            state <= STATE_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                        end
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                STATE_STOP: begin
                    if (clk_count == SAFE_CLKS_PER_BIT - 1) begin
                        clk_count <= 32'd0;
                        data_out <= shift_data;
                        valid <= rx_sync;
                        framing_error_reg <= !rx_sync;
                        state <= STATE_IDLE;
                    end else begin
                        clk_count <= clk_count + 32'd1;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
