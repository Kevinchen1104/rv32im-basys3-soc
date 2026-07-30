`timescale 1ns / 1ps

// Testbench: tb_uart_rx
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: UART RX serial sampling, framing behavior, and invalid clock-divisor handling.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_uart_rx;

    reg clock = 0;
    reg reset = 0;
    reg rx = 1'b1;
    wire [7:0] data_out;
    wire valid;
    wire busy;
    wire framing_error;
    wire invalid_valid;
    wire invalid_busy;
    wire invalid_framing_error;

    uart_rx #(
        .CLKS_PER_BIT(4)
    ) dut (
        .clock(clock),
        .reset(reset),
        .rx(rx),
        .data_out(data_out),
        .valid(valid),
        .busy(busy),
        .framing_error(framing_error)
    );

    uart_rx #(
        .CLKS_PER_BIT(0)
    ) invalid_divisor_dut (
        .clock(clock),
        .reset(reset),
        .rx(1'b0),
        .data_out(),
        .valid(invalid_valid),
        .busy(invalid_busy),
        .framing_error(invalid_framing_error)
    );

    always #5 clock = ~clock;

    task drive_bit;
        input value;
        integer i;
        begin
            rx = value;
            for (i = 0; i < 4; i = i + 1) begin
                @(posedge clock);
            end
            #1;
        end
    endtask

    task send_byte;
        input [7:0] value;
        input stop_bit;
        integer i;
        begin
            drive_bit(1'b0);
            for (i = 0; i < 8; i = i + 1) begin
                drive_bit(value[i]);
            end
            drive_bit(stop_bit);
        end
    endtask

    task check_byte;
        input [7:0] expected;
        integer wait_cycles;
        begin
            wait_cycles = 0;
            while ((valid !== 1'b1) && (wait_cycles < 8)) begin
                @(posedge clock);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            if (valid !== 1'b1 || data_out !== expected || framing_error !== 1'b0) begin
                $display("FAIL: expected valid byte %h, got valid=%b data=%h framing_error=%b",
                         expected, valid, data_out, framing_error);
                $fatal;
            end
            @(posedge clock);
            #1;
            if (valid !== 1'b0 || busy !== 1'b0) begin
                $display("FAIL: UART RX should return to idle after valid pulse");
                $fatal;
            end
            $display("PASS: UART RX byte = %h", expected);
        end
    endtask

    initial begin
        integer framing_wait_cycles;
        $dumpfile("wave/tb_uart_rx.vcd");
        $dumpvars(0, tb_uart_rx);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        repeat (3) @(posedge clock);
        #1;
        if (invalid_valid !== 1'b0 ||
            invalid_busy !== 1'b0 ||
            invalid_framing_error !== 1'b1) begin
            $display("FAIL: CLKS_PER_BIT=0 UART RX should stay inactive and report invalid framing");
            $fatal;
        end

        send_byte(8'ha6, 1'b1);
        check_byte(8'ha6);

        send_byte(8'h3c, 1'b1);
        check_byte(8'h3c);

        send_byte(8'h55, 1'b0);
        framing_wait_cycles = 0;
        while ((framing_error !== 1'b1) && (framing_wait_cycles < 8)) begin
            @(posedge clock);
            #1;
            framing_wait_cycles = framing_wait_cycles + 1;
        end
        if (valid !== 1'b0 || framing_error !== 1'b1 || data_out !== 8'h55) begin
            $display("FAIL: expected framing error for bad stop bit, got valid=%b data=%h framing_error=%b",
                     valid, data_out, framing_error);
            $fatal;
        end

        $display("PASS: tb_uart_rx passed");
        $finish;
    end

endmodule
