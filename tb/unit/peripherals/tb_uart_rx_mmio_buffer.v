`timescale 1ns / 1ps

// Testbench: tb_uart_rx_mmio_buffer
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: Runtime UART RX FIFO depths 1, 3, and 64 preserve byte order, handle
//   simultaneous push/pop, report sticky overflow when full, and clear on reset.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_uart_rx_mmio_buffer;

    reg clock = 0;
    reg reset = 0;
    reg [7:0] rx_data_in = 8'h00;
    reg rx_valid_in = 1'b0;
    reg cpu_ready = 1'b0;
    wire [7:0] rx_data;
    wire rx_valid;
    wire overrun;
    wire fifo1_done, fifo3_done, fifo64_done;
    uart_fifo_check #(.DEPTH(1)) fifo1(clock, fifo1_done);
    uart_fifo_check #(.DEPTH(3)) fifo3(clock, fifo3_done);
    uart_fifo_check #(.DEPTH(64)) fifo64(clock, fifo64_done);

    uart_rx_mmio_buffer dut (
        .clock(clock),
        .reset(reset),
        .rx_data_in(rx_data_in),
        .rx_valid_in(rx_valid_in),
        .cpu_ready(cpu_ready),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .overrun(overrun)
    );

    always #5 clock = ~clock;

    task pulse_byte;
        input [7:0] value;
        begin
            rx_data_in = value;
            rx_valid_in = 1'b1;
            @(posedge clock);
            #1;
            rx_valid_in = 1'b0;
        end
    endtask

    task pulse_ready;
        begin
            cpu_ready = 1'b1;
            @(posedge clock);
            #1;
            cpu_ready = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_uart_rx_mmio_buffer.vcd");
        $dumpvars(0, tb_uart_rx_mmio_buffer);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        if (rx_valid !== 1'b0 || rx_data !== 8'h00 || overrun !== 1'b0) begin
            $display("FAIL: buffer reset state invalid valid=%b data=%h overrun=%b",
                     rx_valid, rx_data, overrun);
            $fatal;
        end

        pulse_byte(8'ha6);
        repeat (3) @(posedge clock);
        #1;
        if (rx_valid !== 1'b1 || rx_data !== 8'ha6 || overrun !== 1'b0) begin
            $display("FAIL: first byte should remain buffered valid=%b data=%h overrun=%b",
                     rx_valid, rx_data, overrun);
            $fatal;
        end

        pulse_ready();
        if (rx_valid !== 1'b0 || rx_data !== 8'ha6 || overrun !== 1'b0) begin
            $display("FAIL: CPU ready should clear valid only valid=%b data=%h overrun=%b",
                     rx_valid, rx_data, overrun);
            $fatal;
        end

        pulse_byte(8'h11);
        pulse_byte(8'h22);
        if (rx_valid !== 1'b1 || rx_data !== 8'h11 || overrun !== 1'b1) begin
            $display("FAIL: second byte before read should set sticky overrun valid=%b data=%h overrun=%b",
                     rx_valid, rx_data, overrun);
            $fatal;
        end

        pulse_ready();
        if (rx_valid !== 1'b0 || overrun !== 1'b1) begin
            $display("FAIL: ready should not clear sticky overrun valid=%b overrun=%b",
                     rx_valid, overrun);
            $fatal;
        end

        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;
        if (rx_valid !== 1'b0 || rx_data !== 8'h00 || overrun !== 1'b0) begin
            $display("FAIL: reset should clear buffered data and overrun valid=%b data=%h overrun=%b",
                     rx_valid, rx_data, overrun);
            $fatal;
        end

        wait (fifo1_done && fifo3_done && fifo64_done);
        $display("PASS: UART RX MMIO FIFO depths 1, 3, 64; wrap, full, simultaneous I/O, reset and random stalls");
        $display("PASS: tb_uart_rx_mmio_buffer passed");
        $finish;
    end

endmodule

module uart_fifo_check #(parameter DEPTH = 64) (input clock, output reg done = 0);
    reg reset = 1;
    reg [7:0] input_data = 0;
    reg input_valid = 0, ready = 0;
    wire [7:0] data;
    wire valid, overrun;
    reg [7:0] expected [0:8191];
    integer head = 0, tail = 0;
    integer index;
    integer seed = 20261001 + DEPTH;
    reg expected_overrun = 0;
    reg take, put;
    uart_rx_mmio_buffer #(.DEPTH(DEPTH)) dut(
        .clock(clock), .reset(reset), .rx_data_in(input_data), .rx_valid_in(input_valid),
        .cpu_ready(ready), .rx_data(data), .rx_valid(valid), .overrun(overrun));

    task step(input send, input consume, input [7:0] value);
        begin
            @(negedge clock);
            input_valid = send;
            ready = consume;
            input_data = value;
            take = consume && (tail != head);
            put = send && ((tail - head < DEPTH) || take);
            if (take) head = head + 1;
            if (put) begin
                expected[tail] = value;
                tail = tail + 1;
            end
            if (send && !put) expected_overrun = 1;
            @(posedge clock);
            #1;
            if (valid !== (tail != head) || overrun !== expected_overrun ||
                (valid && data !== expected[head]))
                $fatal(1, "FIFO depth %0d mismatch head=%0d tail=%0d data=%h", DEPTH, head, tail, data);
        end
    endtask

    initial begin
        repeat (2) @(negedge clock);
        reset = 0;
        step(1, 1, 8'h7e); // Empty read cannot consume the newly arriving byte.
        step(0, 1, 0);
        for (index = 0; index < DEPTH; index = index + 1) step(1, 0, index);
        step(1, 1, 8'hab); // Full FIFO replaces the popped slot without overrun.
        step(1, 0, 8'hff); // Drop newest while full, preserving queued data.
        for (index = 0; index < DEPTH; index = index + 1) step(0, 1, 0);
        for (index = 0; index < 2000; index = index + 1)
            step(($random(seed) & 3) != 0, ($random(seed) & 3) != 0, $random(seed));
        @(negedge clock);
        reset = 1;
        input_valid = 0;
        ready = 0;
        @(posedge clock);
        #1;
        if (valid !== 0 || overrun !== 0 || data !== 0) $fatal(1, "FIFO reset depth %0d", DEPTH);
        @(negedge clock);
        reset = 0;
        head = 0;
        tail = 0;
        expected_overrun = 0;
        step(1, 0, 8'h55);
        step(0, 1, 0);
        done = 1;
    end
endmodule
