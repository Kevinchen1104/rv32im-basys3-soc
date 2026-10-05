`timescale 1ns / 1ps

// Module: ras_unit
// Role: Return address stack for call/return prediction support.
// Interface: Clock/reset, predecoded return query, resolved call/return updates, and stack debug state.
// Key behavior: Predicts returns only, while resolved calls push return PCs and resolved returns pop the stack.

module ras_unit (
    input clock,
    input reset,

    input fetch_is_return,

    output ras_predict_taken,
    output [31:0] ras_predicted_pc,

    input update_valid,
    input update_is_call,
    input update_is_return,
    input [31:0] update_return_pc,

    output [3:0] ras_count_debug,
    output [2:0] ras_top_debug
);

    reg [31:0] ras_stack[0:7];
    reg [2:0] ras_top;
    reg [3:0] ras_count;

    wire ras_can_pop;
    wire [31:0] ras_return_pc;

    integer i;

    assign ras_can_pop = (ras_count != 4'd0);
    assign ras_return_pc = ras_can_pop ? ras_stack[ras_top - 3'd1] : 32'h0;
    assign ras_predict_taken = fetch_is_return && ras_can_pop;
    assign ras_predicted_pc = ras_return_pc;

    assign ras_count_debug = ras_count;
    assign ras_top_debug = ras_top;

    always @(posedge clock) begin
        if (reset) begin
            ras_top <= 3'd0;
            ras_count <= 4'd0;
            for (i = 0; i < 8; i = i + 1) begin
                ras_stack[i] <= 32'h0;
            end
        end else if (update_valid && update_is_call) begin
            if (ras_count != 4'd8) begin
                ras_stack[ras_top] <= update_return_pc;
                ras_count <= ras_count + 4'd1;
                ras_top <= ras_top + 3'd1;
            end
        end else if (update_valid && update_is_return && (ras_count != 4'd0)) begin
            ras_top <= ras_top - 3'd1;
            ras_count <= ras_count - 4'd1;
        end
    end

endmodule
