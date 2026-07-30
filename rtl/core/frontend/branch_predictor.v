`timescale 1ns / 1ps

// Module: branch_predictor
// Role: Small branch target/prediction table for frontend fetch prediction.
// Interface: Fetch PC/instruction query, predicted taken/target outputs, and typed execute-stage update feedback.
// Key behavior: Conditional branches use BHT+BTB, direct JAL uses BTB only, and one registered update commits per cycle.

module branch_predictor (
    input clock,
    input reset,
    input [31:0] fetch_pc,
    input [31:0] fetch_instruction,
    output predict_taken,
    output [31:0] predicted_pc,
    input update_valid,
    input update_suppress,
    input update_is_conditional,
    input [31:0] update_pc,
    input update_taken,
    input [31:0] update_target
);
    localparam [6:0] BRANCH_OPCODE = 7'b1100011;
    localparam [6:0] JAL_OPCODE = 7'b1101111;

    reg [1:0] BHT[0:15];
    reg [31:0] BTBTarget[0:15];
    reg BTBValid[0:15];

    reg update_pending_valid;
    reg update_pending_is_conditional;
    reg [3:0] update_pending_index;
    reg update_pending_taken;
    reg [31:0] update_pending_target;

    wire [3:0] fetch_index = fetch_pc[5:2];
    wire [3:0] update_index = update_pc[5:2];
    wire is_conditional_branch = (fetch_instruction[6:0] == BRANCH_OPCODE);
    wire is_direct_jal = (fetch_instruction[6:0] == JAL_OPCODE);
    wire btb_hit = BTBValid[fetch_index];

    assign predict_taken =
        btb_hit &&
        (is_direct_jal || (is_conditional_branch && BHT[fetch_index][1]));
    assign predicted_pc = predict_taken ? BTBTarget[fetch_index] : (fetch_pc + 4);

    integer i;

    initial begin
        update_pending_valid = 1'b0;
        update_pending_is_conditional = 1'b0;
        update_pending_index = 4'h0;
        update_pending_taken = 1'b0;
        update_pending_target = 32'h0;
        for (i = 0; i < 16; i = i + 1) begin
            BHT[i] = 2'b01;
            BTBTarget[i] = 32'h0;
            BTBValid[i] = 1'b0;
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            update_pending_valid <= 1'b0;
            update_pending_is_conditional <= 1'b0;
            update_pending_index <= 4'h0;
            update_pending_taken <= 1'b0;
            update_pending_target <= 32'h0;
            for (i = 0; i < 16; i = i + 1) begin
                BHT[i] <= 2'b01;
                BTBTarget[i] <= 32'h0;
                BTBValid[i] <= 1'b0;
            end
        end else begin
            // The registered bundle isolates execute/control resolution from
            // BHT/BTB write enables, indices, direction, and target data.
            update_pending_valid <= update_valid;
            // Payload bits capture every cycle. update_pending_valid is the
            // sole validity contract, so invalid-cycle payload values are
            // harmless while the payload flops no longer inherit the late
            // accepted-resolution clock-enable cone.
            update_pending_is_conditional <= update_is_conditional;
            update_pending_index <= update_index;
            update_pending_taken <= update_taken;
            update_pending_target <= update_target;

            // The suppress event is registered by the core on the same edge
            // as this pending bundle. A misaligned control transfer therefore
            // reaches neither BHT nor BTB without extending update_valid's
            // execute-stage timing cone.
            if (update_pending_valid && !update_suppress) begin
                if (update_pending_is_conditional) begin
                    if (update_pending_taken) begin
                        if (BHT[update_pending_index] != 2'b11) begin
                            BHT[update_pending_index] <= BHT[update_pending_index] + 2'b01;
                        end
                        BTBTarget[update_pending_index] <= update_pending_target;
                        BTBValid[update_pending_index] <= 1'b1;
                    end else if (BHT[update_pending_index] != 2'b00) begin
                        BHT[update_pending_index] <= BHT[update_pending_index] - 2'b01;
                    end
                end else begin
                    // Direct JAL is always taken. Its target trains the BTB,
                    // but it must not perturb conditional-branch direction state.
                    BTBTarget[update_pending_index] <= update_pending_target;
                    BTBValid[update_pending_index] <= 1'b1;
                end
            end
        end
    end

`ifdef FORMAL
    reg formal_past_valid = 1'b0;
    integer formal_i;
    always @(posedge clock) begin
        formal_past_valid <= 1'b1;
        if (formal_past_valid) begin
            if ($past(reset)) begin
                assert(update_pending_valid == 1'b0);
                assert(update_pending_is_conditional == 1'b0);
                assert(update_pending_index == 4'h0);
                assert(update_pending_taken == 1'b0);
                assert(update_pending_target == 32'h0);
            end else begin
                assert(update_pending_valid == $past(update_valid));
                assert(update_pending_is_conditional == $past(update_is_conditional));
                assert(update_pending_index == $past(update_index));
                assert(update_pending_taken == $past(update_taken));
                assert(update_pending_target == $past(update_target));

                // A cycle with no prior pending update cannot modify either
                // predictor table, regardless of the payload being captured.
                if (!$past(update_pending_valid && !update_suppress)) begin
                    for (formal_i = 0; formal_i < 16; formal_i = formal_i + 1) begin
                        assert(BHT[formal_i] == $past(BHT[formal_i]));
                        assert(BTBTarget[formal_i] == $past(BTBTarget[formal_i]));
                        assert(BTBValid[formal_i] == $past(BTBValid[formal_i]));
                    end
                end
            end
        end
    end
`endif
endmodule
