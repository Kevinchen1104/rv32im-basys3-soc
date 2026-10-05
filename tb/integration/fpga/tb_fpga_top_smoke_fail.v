`timescale 1ns / 1ps

// Checks: FPGA top smoke_fail assertion for mismatched status values.

module tb_fpga_top_smoke_fail;

    reg clock = 0;
    reg reset = 0;
    wire [7:0] leds;
    wire done;
    wire smoke_pass;
    wire smoke_fail;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    RISCVCPU_fpga_top #(
        .EXPECTED_STATUS(32'hdead_beef)
    ) dut (
        .clock(clock),
        .reset(reset),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_rx_ready(),
        .leds(leds),
        .done(done),
        .smoke_pass(smoke_pass),
        .smoke_fail(smoke_fail),
        .debug_status(debug_status),
        .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("results/waveforms/tb_fpga_top_smoke_fail.vcd");
        $dumpvars(0, tb_fpga_top_smoke_fail);

        reset = 1'b1;
        #1;

        if (smoke_fail !== 1'b0) begin
            $display("FAIL: smoke_fail should stay low while reset is asserted");
            $fatal;
        end

        repeat (2) @(negedge clock);
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: smoke_fail test expected actual debug_status = %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (debug_pc !== 32'd24 || done !== 1'b1) begin
            $display("FAIL: smoke_fail test expected CPU to reach final loop");
            $fatal;
        end

        if (smoke_pass !== 1'b0) begin
            $display("FAIL: smoke_pass should stay low when expected status is wrong");
            $fatal;
        end

        if (smoke_fail !== 1'b1) begin
            $display("FAIL: smoke_fail should assert when done is high and status mismatches");
            $fatal;
        end

        if (leds !== 8'hfe) begin
            $display("FAIL: smoke_fail test expected leds = %h, got %h", 8'hfe, leds);
            $fatal;
        end

        $display("PASS: fpga top smoke_fail asserted for mismatched status value");
        $display("PASS: tb_fpga_top_smoke_fail passed");
        $finish;
    end

endmodule
