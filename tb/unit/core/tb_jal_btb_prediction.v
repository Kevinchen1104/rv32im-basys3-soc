`timescale 1ns / 1ps

// Testbench: tb_jal_btb_prediction
// Purpose: Checks cold-to-warm direct JAL prediction through the BTB with RAS return prediction retained.
// Checks: Cold correction, registered BTB training, warm hit, RAS push/pop, exact retirement, and wrong-path suppression.
// Pass condition: Two calls complete, only the first JAL mispredicts, trained metadata matches, and architectural markers are exact.

module tb_jal_btb_prediction;

`include "tb_common.vh"

    localparam [31:0] CALL_PC = 32'd12;
    localparam [31:0] CALL_TARGET = 32'd44;

    integer call_resolutions;
    integer cold_call_mispredicts;
    integer warm_call_predictions;
    integer continuation_retires;
    integer wrong_path_retires;

    always @(posedge clock) begin
        if (!reset && dut.control_resolution_accept && dut.IDEXValid &&
            dut.is_jal && (dut.IDEXPC == CALL_PC)) begin
            if (call_resolutions == 0) begin
                if (dut.IDEXPredTaken !== 1'b0 || dut.jump_mispredict !== 1'b1) begin
                    $display("FAIL: cold JAL was not corrected from sequential prediction");
                    $fatal;
                end
                cold_call_mispredicts = cold_call_mispredicts + 1;
            end else if (call_resolutions == 1) begin
                if (dut.IDEXPredTaken !== 1'b1 ||
                    dut.IDEXPredPC !== CALL_TARGET ||
                    dut.jump_mispredict !== 1'b0) begin
                    $display("FAIL: warm JAL did not use the trained BTB target");
                    $fatal;
                end
                warm_call_predictions = warm_call_predictions + 1;
            end else begin
                $display("FAIL: call site resolved more than twice");
                $fatal;
            end
            call_resolutions = call_resolutions + 1;
        end

        if (!reset && dut.trace_valid) begin
            if (dut.trace_pc == 32'd16) begin
                continuation_retires = continuation_retires + 1;
            end
            if ((dut.trace_pc == 32'd28) || (dut.trace_pc == 32'd52)) begin
                wrong_path_retires = wrong_path_retires + 1;
            end
        end
    end

    initial begin
        $dumpfile("wave/tb_jal_btb_prediction.vcd");
        $dumpvars(0, tb_jal_btb_prediction);
        call_resolutions = 0;
        cold_call_mispredicts = 0;
        warm_call_predictions = 0;
        continuation_retires = 0;
        wrong_path_retires = 0;
        reset_cpu();

        dut.IMemory[0]  = i_type(12'd0, 5'd0, 3'b000, 5'd10, 7'b0010011);  // calls completed = 0
        dut.IMemory[1]  = i_type(12'd2, 5'd0, 3'b000, 5'd11, 7'b0010011);  // call limit = 2
        dut.IMemory[2]  = i_type(12'd0, 5'd0, 3'b000, 5'd12, 7'b0010011);  // function executions = 0
        dut.IMemory[3]  = j_type(32, 5'd1, 7'b1101111);                    // call function at 0x2c
        dut.IMemory[4]  = i_type(12'd1, 5'd10, 3'b000, 5'd10, 7'b0010011); // return continuation
        dut.IMemory[5]  = b_type(-8, 5'd11, 5'd10, 3'b100, 7'b1100011);   // blt x10, x11, call
        dut.IMemory[6]  = j_type(36, 5'd0, 7'b1101111);                    // jump to done at 0x3c
        dut.IMemory[7]  = i_type(12'd99, 5'd0, 3'b000, 5'd14, 7'b0010011); // wrong final-JAL path
        dut.IMemory[11] = i_type(12'd1, 5'd12, 3'b000, 5'd12, 7'b0010011); // function body
        dut.IMemory[12] = i_type(12'd0, 5'd1, 3'b000, 5'd0, 7'b1100111);   // ret
        dut.IMemory[13] = i_type(12'd99, 5'd0, 3'b000, 5'd13, 7'b0010011); // wrong return path
        dut.IMemory[15] = i_type(12'd77, 5'd0, 3'b000, 5'd15, 7'b0010011); // done marker
        dut.IMemory[16] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);       // halt

        run_cycles(280);

        check_reg(1, 32'd16);
        check_reg(10, 32'd2);
        check_reg(12, 32'd2);
        check_reg(13, 32'd13);
        check_reg(14, 32'd14);
        check_reg(15, 32'd77);

        if (call_resolutions !== 2 ||
            cold_call_mispredicts !== 1 ||
            warm_call_predictions !== 1) begin
            $display("FAIL: call prediction counts resolves=%0d cold_miss=%0d warm_hits=%0d",
                     call_resolutions, cold_call_mispredicts, warm_call_predictions);
            $fatal;
        end

        if (continuation_retires !== 2 || wrong_path_retires !== 0) begin
            $display("FAIL: retired trace continuation=%0d wrong_path=%0d",
                     continuation_retires, wrong_path_retires);
            $fatal;
        end

        if (dut.gen_branch_predictor.branch_predictor_inst.BHT[3] !== 2'b01 ||
            dut.gen_branch_predictor.branch_predictor_inst.BTBValid[3] !== 1'b1 ||
            dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[3] !== CALL_TARGET) begin
            $display("FAIL: JAL training changed BHT or stored incorrect BTB metadata");
            $fatal;
        end

        if (dut.RASCount !== 4'd0) begin
            $display("FAIL: RAS did not return to empty state, count=%0d", dut.RASCount);
            $fatal;
        end

        $display("PASS: cold JAL corrected once, warm JAL used BTB, and RAS returns remained precise");
        $display("PASS: tb_jal_btb_prediction passed");
        $finish;
    end
endmodule
