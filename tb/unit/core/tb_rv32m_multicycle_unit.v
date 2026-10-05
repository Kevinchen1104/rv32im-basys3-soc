`timescale 1ns / 1ps

// Testbench: tb_rv32m_multicycle_unit
// Purpose: Exercises both multiplier implementations and the shared divider.
// Checks: All eight RV32M operations, architectural edge cases, busy rejection, reset cancellation, and completion timing.
// Pass condition: Exact arithmetic, latency, request ownership and reset behavior.

module rv32m_unit_test_case #(
    parameter FAST_MULTIPLY = 0
)(output reg complete = 0);
    reg clock = 1'b0;
    reg reset = 1'b0;
    reg start = 1'b0;
    reg [2:0] funct3 = 3'b000;
    reg [31:0] lhs = 32'h0;
    reg [31:0] rhs = 32'h0;
    wire busy;
    wire done;
    wire [31:0] result;
    integer sample, operation, left_index, right_index;
    reg [31:0] left_random, right_random;
    reg [31:0] edge_values [0:7];
    reg signed [32:0] reference_lhs, reference_rhs;
    reg signed [65:0] reference_product;
    integer seed = 20261001;

    rv32m_multicycle_unit #(.FAST_MULTIPLY(FAST_MULTIPLY)) dut (
        .clock(clock),
        .reset(reset),
        .start(start),
        .funct3(funct3),
        .lhs(lhs),
        .rhs(rhs),
        .busy(busy),
        .done(done),
        .result(result)
    );

    always #5 clock = ~clock;

    task reset_unit;
        begin
            reset = 1'b1;
            @(posedge clock);
            #1;
            reset = 1'b0;
        end
    endtask

    task run_operation;
        input [2:0] operation;
        input [31:0] operand_lhs;
        input [31:0] operand_rhs;
        input [31:0] expected;
        input [8*32-1:0] label;
        integer cycles;
        begin
            @(negedge clock);
            funct3 = operation;
            lhs = operand_lhs;
            rhs = operand_rhs;
            start = 1'b1;
            @(posedge clock);
            #1;
            start = 1'b0;

            if (!busy || done) begin
                $display("FAIL: %0s was not accepted", label);
                $fatal;
            end

            cycles = 0;
            while (busy && (cycles < 40)) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end

            if (cycles != ((FAST_MULTIPLY && !operation[2]) ? 3 : 33) ||
                !done || result !== expected) begin
                $display("FAIL: %0s cycles=%0d done=%b expected=%h got=%h",
                         label, cycles, done, expected, result);
                $fatal;
            end

            @(posedge clock);
            #1;
            if (done) begin
                $display("FAIL: %0s done was not a one-cycle pulse", label);
                $fatal;
            end
        end
    endtask

    task check_start_ignored_while_busy;
        integer cycles;
        begin
            @(negedge clock);
            funct3 = 3'b000;
            lhs = 32'd9;
            rhs = 32'd7;
            start = 1'b1;
            @(posedge clock);
            #1;
            start = 1'b0;

            @(negedge clock);
            funct3 = 3'b100;
            lhs = 32'd100;
            rhs = 32'd4;
            start = 1'b1;
            @(posedge clock);
            #1;
            start = 1'b0;

            cycles = 0;
            while (busy && (cycles < 40)) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end

            if (!done || result !== 32'd63) begin
                $display("FAIL: start while busy replaced the accepted operation, result=%h", result);
                $fatal;
            end
            @(posedge clock);
            #1;
        end
    endtask

    task check_reset_cancels_operation;
        begin
            @(negedge clock);
            funct3 = 3'b101;
            lhs = 32'hffff_ffff;
            rhs = 32'd3;
            start = 1'b1;
            @(posedge clock);
            #1;
            start = 1'b0;
            repeat (4) @(posedge clock);
            @(negedge clock);
            reset = 1'b1;
            @(posedge clock);
            #1;
            reset = 1'b0;
            if (busy || done || result !== 32'h0) begin
                $display("FAIL: reset did not cancel the active operation");
                $fatal;
            end
        end
    endtask

    initial begin
        reset_unit();
        run_operation(3'b000, 32'hffff_fffe, 32'd3, 32'hffff_fffa, "mul low signed bits");
        run_operation(3'b001, 32'hffff_fffe, 32'd3, 32'hffff_ffff, "mulh signed");
        run_operation(3'b010, 32'hffff_fffe, 32'hffff_ffff, 32'hffff_fffe, "mulhsu mixed signedness");
        run_operation(3'b011, 32'hffff_ffff, 32'd2, 32'h0000_0001, "mulhu unsigned");
        run_operation(3'b100, 32'hffff_fff9, 32'd3, 32'hffff_fffe, "div signed");
        run_operation(3'b101, 32'hffff_ffff, 32'd2, 32'h7fff_ffff, "divu unsigned");
        run_operation(3'b110, 32'hffff_fff9, 32'd3, 32'hffff_ffff, "rem signed");
        run_operation(3'b111, 32'hffff_ffff, 32'd2, 32'h0000_0001, "remu unsigned");
        run_operation(3'b100, 32'd123, 32'd0, 32'hffff_ffff, "div by zero");
        run_operation(3'b110, 32'hffff_ff85, 32'd0, 32'hffff_ff85, "rem by zero");
        run_operation(3'b100, 32'h8000_0000, 32'hffff_ffff, 32'h8000_0000, "div overflow");
        run_operation(3'b110, 32'h8000_0000, 32'hffff_ffff, 32'h0000_0000, "rem overflow");
        check_start_ignored_while_busy();
        check_reset_cancels_operation();
        run_operation(3'b000, 32'd11, 32'd13, 32'd143, "back-to-back after reset");

        // Cancel at each of the three fast-multiplier pipeline boundaries.
        for (sample = 0; sample < 3; sample = sample + 1) begin
            @(negedge clock);
            funct3 = 3'b001;
            lhs = 32'h80000000;
            rhs = 32'hffffffff;
            start = 1;
            @(posedge clock);
            #1;
            start = 0;
            repeat (sample) @(posedge clock);
            @(negedge clock);
            reset = 1;
            @(posedge clock);
            #1;
            if (busy || done || result !== 0) $fatal(1, "reset failed at multiplier stage %0d", sample);
            @(negedge clock);
            reset = 0;
        end

        edge_values[0] = 0;
        edge_values[1] = 1;
        edge_values[2] = 32'hffffffff;
        edge_values[3] = 32'h80000000;
        edge_values[4] = 32'h7fffffff;
        edge_values[5] = 32'h0000ffff;
        edge_values[6] = 32'hffff0000;
        edge_values[7] = 32'haaaa5555;
        // 64 edge pairs plus 2,048 fixed-seed random pairs, all four products.
        for (sample = 0; sample < 2112; sample = sample + 1) begin
            if (sample < 64) begin
                left_index = sample / 8;
                right_index = sample % 8;
                left_random = edge_values[left_index];
                right_random = edge_values[right_index];
            end else begin
                left_random = $random(seed);
                right_random = $random(seed);
            end
            for (operation = 0; operation < 4; operation = operation + 1) begin
                reference_lhs = {((operation == 1 || operation == 2) && left_random[31]), left_random};
                reference_rhs = {((operation == 1) && right_random[31]), right_random};
                reference_product = reference_lhs * reference_rhs;
                run_operation(operation[2:0], left_random, right_random,
                              operation == 0 ? reference_product[31:0] : reference_product[63:32],
                              "product reference");
            end
        end

        $display("PASS: RV32M unit FAST_MULTIPLY=%0d passed", FAST_MULTIPLY);
        complete = 1;
    end
endmodule

module tb_rv32m_multicycle_unit;
    wire iterative_complete, fast_complete;
    rv32m_unit_test_case #(.FAST_MULTIPLY(0)) iterative_test(iterative_complete);
    rv32m_unit_test_case #(.FAST_MULTIPLY(1)) fast_test(fast_complete);
    initial begin
        $dumpfile("results/waveforms/tb_rv32m_multicycle_unit.vcd");
        $dumpvars(0, tb_rv32m_multicycle_unit);
        wait (iterative_complete && fast_complete);
        $display("PASS: tb_rv32m_multicycle_unit passed");
        $finish;
    end
endmodule
