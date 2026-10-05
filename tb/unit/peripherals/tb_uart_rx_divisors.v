`timescale 1ns / 1ps

module uart_rx_divisor_case #(
    parameter DIVISOR = 3,
    parameter PHASE = 1
)(output reg done = 0);
    reg clock = 0;
    reg reset = 1;
    reg rx = 1;
    wire [7:0] data;
    wire valid, framing_error;
    integer value, bit_number;
    integer received = 0;
    always #5 clock = ~clock;
    uart_rx #(.CLKS_PER_BIT(DIVISOR)) dut (
        .clock(clock), .reset(reset), .rx(rx), .data_out(data),
        .valid(valid), .busy(), .framing_error(framing_error)
    );
    always @(posedge clock) begin
        if (!reset && valid) begin
            if (received >= 256 || data !== received[7:0] || framing_error)
                $fatal(1, "RX divisor=%0d phase=%0d byte=%0d got=%h", DIVISOR, PHASE, received, data);
            received = received + 1;
        end
    end
    initial begin
        repeat (4) @(negedge clock);
        reset = 0;
        #(20 + PHASE);
        for (value = 0; value < 256; value = value + 1) begin
            rx = 0;
            #(DIVISOR * 10);
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                rx = (value >> bit_number) & 1;
                #(DIVISOR * 10);
            end
            rx = 1;
            #(DIVISOR * 30);
        end
        if (received != 256) $fatal(1, "RX divisor=%0d phase=%0d received=%0d", DIVISOR, PHASE, received);
        done = 1;
    end
endmodule

module tb_uart_rx_divisors;
    wire [15:0] done;
    genvar d, p;
    generate
        for (d = 0; d < 4; d = d + 1) begin : divisors
            for (p = 0; p < 4; p = p + 1) begin : phases
                uart_rx_divisor_case #(
                    .DIVISOR(d == 3 ? 8 : d + 3), .PHASE(1 + p * 2)
                ) test_case(done[d * 4 + p]);
            end
        end
        for (d = 0; d < 3; d = d + 1) begin : invalid_divisors
            reg clock = 0;
            wire valid, busy, error;
            always #5 clock = ~clock;
            uart_rx #(.CLKS_PER_BIT(d)) invalid_rx (
                .clock(clock), .reset(1'b0), .rx(1'b0), .data_out(),
                .valid(valid), .busy(busy), .framing_error(error)
            );
            always @(negedge clock)
                if (valid !== 0 || busy !== 0 || error !== 1)
                    $fatal(1, "Invalid RX divisor %0d was not rejected", d);
        end
    endgenerate
    initial begin
        $dumpfile("results/waveforms/tb_uart_rx_divisors.vcd");
        $dumpvars(0, tb_uart_rx_divisors);
        wait (&done);
        $display("PASS: tb_uart_rx_divisors (4096 bytes, 3 invalid divisors)");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "RX divisor tests timed out");
    end
endmodule
