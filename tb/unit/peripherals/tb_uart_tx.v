`timescale 1ns / 1ps

// Testbench: tb_uart_tx
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: UART TX serialization, ready/busy behavior, ignored busy attempts, and invalid clock-divisor handling.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_uart_tx;
    initial begin
        #100000;
        $fatal(1, "UART TX test timed out");
    end

    localparam integer CLKS_PER_BIT = 4;

    reg clock = 0;
    reg reset = 0;
    reg [7:0] data_in = 8'h00;
    reg valid = 0;
    wire ready;
    wire tx;
    wire busy;
    wire invalid_ready;
    wire invalid_tx;
    wire invalid_busy;

    reg [7:0] captured0 = 8'h00;
    reg [7:0] captured1 = 8'h00;

    uart_tx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) dut (
        .clock(clock),
        .reset(reset),
        .data_in(data_in),
        .valid(valid),
        .ready(ready),
        .tx(tx),
        .busy(busy)
    );

    uart_tx #(
        .CLKS_PER_BIT(0)
    ) invalid_divisor_dut (
        .clock(clock),
        .reset(reset),
        .data_in(8'ha5),
        .valid(1'b1),
        .ready(invalid_ready),
        .tx(invalid_tx),
        .busy(invalid_busy)
    );

    always #5 clock = ~clock;

    task send_byte;
        input [7:0] value;
        begin
            @(negedge clock);
            data_in = value;
            valid = 1'b1;
            @(posedge clock);
            #1;
            valid = 1'b0;
            data_in = 8'h00;
            if (ready !== 1'b0 || busy !== 1'b1 || tx !== 1'b0) begin
                $display("FAIL: UART TX should accept byte %h and enter start bit", value);
                $fatal;
            end
        end
    endtask

    task try_busy_byte;
        input [7:0] value;
        begin
            @(negedge clock);
            data_in = value;
            valid = 1'b1;
            @(posedge clock);
            #1;
            valid = 1'b0;
            data_in = 8'h00;
            if (ready !== 1'b0 || busy !== 1'b1) begin
                $display("FAIL: UART TX should remain busy while byte %h is ignored", value);
                $fatal;
            end
        end
    endtask

    task capture_byte;
        output [7:0] value;
        integer bit_index;
        begin
            value = 8'h00;
            @(negedge tx);
            repeat (CLKS_PER_BIT) @(posedge clock);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #1;
                value[bit_index] = tx;
                repeat (CLKS_PER_BIT) @(posedge clock);
            end
            #1;
            if (tx !== 1'b1) begin
                $display("FAIL: UART TX stop bit expected 1, got %b", tx);
                $fatal;
            end
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_uart_tx.vcd");
        $dumpvars(0, tb_uart_tx);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        repeat (3) @(posedge clock);
        #1;
        if (invalid_ready !== 1'b0 ||
            invalid_busy !== 1'b0 ||
            invalid_tx !== 1'b1) begin
            $display("FAIL: CLKS_PER_BIT=0 UART TX should remain inactive and idle high");
            $fatal;
        end

        if (ready !== 1'b1 || busy !== 1'b0 || tx !== 1'b1) begin
            $display("FAIL: UART TX should reset to idle-high ready state");
            $fatal;
        end

        fork
            begin
                capture_byte(captured0);
                capture_byte(captured1);
            end
            begin
                send_byte(8'ha6);
                repeat (2) @(posedge clock);
                #1;
                try_busy_byte(8'h5a);
                wait (ready === 1'b1);
                send_byte(8'h3c);
                wait (ready === 1'b1);
            end
        join

        if (captured0 !== 8'ha6) begin
            $display("FAIL: first UART byte expected a6, got %h", captured0);
            $fatal;
        end

        if (captured1 !== 8'h3c) begin
            $display("FAIL: second UART byte expected 3c, got %h", captured1);
            $fatal;
        end

        if (ready !== 1'b1 || busy !== 1'b0 || tx !== 1'b1) begin
            $display("FAIL: UART TX should return to idle after multiple bytes");
            $fatal;
        end

        $display("PASS: tb_uart_tx passed");
        $finish;
    end

endmodule
