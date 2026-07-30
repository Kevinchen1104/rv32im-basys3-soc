`timescale 1ns / 1ps

// Testbench: tb_rv32m_multicycle_unit
// Purpose: Exercises the iterative RV32M arithmetic unit independently of the CPU pipeline.
// Checks: All eight RV32M operations, architectural edge cases, busy rejection, reset cancellation, and completion timing.
// Pass condition: Every operation returns the expected result after one registered launch cycle and 32 iterations, then done pulses for one cycle.

module tb_rv32m_multicycle_unit;
    reg clock = 1'b0;
    reg reset = 1'b0;
    reg start = 1'b0;
    reg [2:0] funct3 = 3'b000;
    reg [31:0] lhs = 32'h0;
    reg [31:0] rhs = 32'h0;
    wire busy;
    wire done;
    wire [31:0] result;

    rv32m_multicycle_unit dut (
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

            if (cycles != 33 || !done || result !== expected) begin
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

            repeat (5) @(posedge clock);
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
        $dumpfile("wave/tb_rv32m_multicycle_unit.vcd");
        $dumpvars(0, tb_rv32m_multicycle_unit);

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

        $display("PASS: tb_rv32m_multicycle_unit passed");
        $finish;
    end
endmodule
