`timescale 1ns / 1ps

// Testbench: tb_ras_unit
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Standalone return-address stack predicts returns only and updates an 8-entry stack on resolved call/return events.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_ras_unit;

    localparam [6:0] JAL  = 7'b1101111;
    localparam [6:0] JALR = 7'b1100111;
    localparam [6:0] ALUI = 7'b0010011;

    reg clock;
    reg reset;
    reg [31:0] fetch_instruction;
    reg update_valid;
    reg update_is_call;
    reg update_is_return;
    reg [31:0] update_return_pc;

    wire ras_predict_taken;
    wire [31:0] ras_predicted_pc;
    wire [3:0] ras_count_debug;
    wire [2:0] ras_top_debug;

    ras_unit dut (
        .clock(clock),
        .reset(reset),
        .fetch_is_return((fetch_instruction & 32'hffff_8fff) == 32'h0000_8067),
        .ras_predict_taken(ras_predict_taken),
        .ras_predicted_pc(ras_predicted_pc),
        .update_valid(update_valid),
        .update_is_call(update_is_call),
        .update_is_return(update_is_return),
        .update_return_pc(update_return_pc),
        .ras_count_debug(ras_count_debug),
        .ras_top_debug(ras_top_debug)
    );

    initial begin
        clock = 1'b0;
        forever #5 clock = ~clock;
    end

    function [31:0] j_type;
        input integer imm;
        input [4:0] rd;
        reg [20:0] jimm;
    begin
        jimm = imm[20:0];
        j_type = {
            jimm[20],
            jimm[10:1],
            jimm[11],
            jimm[19:12],
            rd,
            JAL
        };
    end
    endfunction

    function [31:0] i_type;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
    begin
        i_type = {imm, rs1, funct3, rd, opcode};
    end
    endfunction

    task clear_update;
    begin
        update_valid = 1'b0;
        update_is_call = 1'b0;
        update_is_return = 1'b0;
        update_return_pc = 32'h0;
    end
    endtask

    task tick;
    begin
        @(posedge clock);
        #2;
    end
    endtask

    task settle;
    begin
        #2;
    end
    endtask

    task push_call;
        input [31:0] return_pc;
    begin
        update_valid = 1'b1;
        update_is_call = 1'b1;
        update_is_return = 1'b0;
        update_return_pc = return_pc;
        tick();
        clear_update();
    end
    endtask

    task pop_return;
    begin
        update_valid = 1'b1;
        update_is_call = 1'b0;
        update_is_return = 1'b1;
        update_return_pc = 32'h0;
        tick();
        clear_update();
    end
    endtask

    task check_bool;
        input [255:0] name;
        input actual;
        input expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %0d got %0d", name, expected, actual);
            $fatal;
        end
    end
    endtask

    task check_word;
        input [255:0] name;
        input [31:0] actual;
        input [31:0] expected;
    begin
        if (actual !== expected) begin
            $display("FAIL: %0s expected %h got %h", name, expected, actual);
            $fatal;
        end
    end
    endtask

    task check_count_top;
        input [3:0] count;
        input [2:0] top;
    begin
        check_word("ras_count_debug", {28'h0, ras_count_debug}, {28'h0, count});
        check_word("ras_top_debug", {29'h0, ras_top_debug}, {29'h0, top});
    end
    endtask

    integer i;

    initial begin
        fetch_instruction = i_type(12'd0, 5'd0, 3'b000, 5'd0, ALUI);
        clear_update();
        reset = 1'b1;
        tick();
        check_count_top(4'd0, 3'd0);
        fetch_instruction = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
        settle();
        check_bool("empty return no prediction", ras_predict_taken, 1'b0);

        reset = 1'b0;
        fetch_instruction = j_type(32'd16, 5'd1);
        settle();
        check_bool("jal x1 call is not predicted by RAS", ras_predict_taken, 1'b0);
        check_word("empty RAS target remains zero", ras_predicted_pc, 32'h0);

        fetch_instruction = j_type(32'd16, 5'd0);
        settle();
        check_bool("jal x0 no call prediction", ras_predict_taken, 1'b0);

        push_call(32'h0000_2004);
        check_count_top(4'd1, 3'd1);
        fetch_instruction = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
        settle();
        check_bool("return predicts after push", ras_predict_taken, 1'b1);
        check_word("return predicted pc", ras_predicted_pc, 32'h0000_2004);

        pop_return();
        check_count_top(4'd0, 3'd0);
        settle();
        check_bool("return no prediction after pop", ras_predict_taken, 1'b0);

        pop_return();
        check_count_top(4'd0, 3'd0);

        push_call(32'h0000_3004);
        push_call(32'h0000_4004);
        check_count_top(4'd2, 3'd2);
        fetch_instruction = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
        settle();
        check_bool("nested return predicts taken", ras_predict_taken, 1'b1);
        check_word("nested predicts latest return", ras_predicted_pc, 32'h0000_4004);

        pop_return();
        check_count_top(4'd1, 3'd1);
        settle();
        check_word("nested pop exposes previous return", ras_predicted_pc, 32'h0000_3004);

        reset = 1'b1;
        tick();
        reset = 1'b0;

        for (i = 0; i < 10; i = i + 1) begin
            push_call(32'h0000_5000 + i);
        end
        check_count_top(4'd8, 3'd0);

        fetch_instruction = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
        settle();
        check_bool("full stack return predicts", ras_predict_taken, 1'b1);
        check_word("overflow kept eighth return on top", ras_predicted_pc, 32'h0000_5007);

        reset = 1'b1;
        tick();
        reset = 1'b0;
        fetch_instruction = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
        settle();
        check_bool("empty stack return no predict", ras_predict_taken, 1'b0);

        fetch_instruction = i_type(12'd1, 5'd0, 3'b000, 5'd2, ALUI);
        settle();
        check_bool("normal instruction no prediction", ras_predict_taken, 1'b0);

        $display("PASS: tb_ras_unit passed");
        $finish;
    end

endmodule
