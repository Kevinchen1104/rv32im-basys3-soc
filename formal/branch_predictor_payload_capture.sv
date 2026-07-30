`default_nettype none

module branch_predictor_payload_capture_formal;
    (* gclk *) reg clock;
    reg reset = 1'b1;
    (* anyseq *) reg [31:0] fetch_pc;
    (* anyseq *) reg [31:0] fetch_instruction;
    (* anyseq *) reg update_valid;
    (* anyseq *) reg update_suppress;
    (* anyseq *) reg update_is_conditional;
    (* anyseq *) reg [31:0] update_pc;
    (* anyseq *) reg update_taken;
    (* anyseq *) reg [31:0] update_target;

    wire predict_taken;
    wire [31:0] predicted_pc;
    reg past_valid = 1'b0;

    branch_predictor dut (
        .clock(clock),
        .reset(reset),
        .fetch_pc(fetch_pc),
        .fetch_instruction(fetch_instruction),
        .predict_taken(predict_taken),
        .predicted_pc(predicted_pc),
        .update_valid(update_valid),
        .update_suppress(update_suppress),
        .update_is_conditional(update_is_conditional),
        .update_pc(update_pc),
        .update_taken(update_taken),
        .update_target(update_target)
    );

    always @(posedge clock) begin
        past_valid <= 1'b1;
        if (!past_valid) begin
            reset <= 1'b1;
        end else begin
            reset <= 1'b0;
        end
    end
endmodule

`default_nettype wire
