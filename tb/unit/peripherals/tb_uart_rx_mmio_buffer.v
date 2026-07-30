`timescale 1ns / 1ps

// Testbench: tb_uart_rx_mmio_buffer
// Purpose: Checks a local MMIO peripheral, UART, timer, GPIO, or decoder block.
// Checks: The runtime UART RX MMIO buffer latches one received byte until the CPU RXDATA read pulse, preserves valid
//   while unread, reports sticky overrun for a second unread byte, and clears state on reset.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.
//   robustness claim.

module tb_uart_rx_mmio_buffer;

    reg clock = 0;
    reg reset = 0;
    reg [7:0] rx_data_in = 8'h00;
    reg rx_valid_in = 1'b0;
    reg cpu_ready = 1'b0;
    wire [7:0] rx_data;
    wire rx_valid;
    wire overrun;

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
        $dumpfile("wave/tb_uart_rx_mmio_buffer.vcd");
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

        $display("PASS: UART RX MMIO buffer latches, clears, and reports overrun");
        $display("PASS: tb_uart_rx_mmio_buffer passed");
        $finish;
    end

endmodule
