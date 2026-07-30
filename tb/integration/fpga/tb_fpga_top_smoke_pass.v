`timescale 1ns / 1ps

// Testbench: tb_fpga_top_smoke_pass
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: FPGA top smoke_pass assertion for matching status values.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Status comparator simulation only.
// Firmware: firmware/hex/showcase/led_smoke.hex
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_smoke_pass;

    reg clock = 0;
    reg reset = 0;

    wire [7:0] default_leds;
    wire default_done;
    wire default_smoke_pass;
    wire [31:0] default_debug_status;
    wire [31:0] default_debug_pc;

    wire [7:0] override_leds;
    wire override_done;
    wire override_smoke_pass;
    wire [31:0] override_debug_status;
    wire [31:0] override_debug_pc;

    RISCVCPU_fpga_top default_dut (
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
        .leds(default_leds),
        .done(default_done),
        .smoke_pass(default_smoke_pass),
        .debug_status(default_debug_status),
        .debug_pc(default_debug_pc)
    );

    RISCVCPU_fpga_top #(
        .PROGRAM_HEX("firmware/hex/showcase/led_smoke.hex"),
        .PROGRAM_WORD_COUNT(7),
        .EXPECTED_STATUS(32'h1234_56a5)
    ) override_dut (
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
        .leds(override_leds),
        .done(override_done),
        .smoke_pass(override_smoke_pass),
        .debug_status(override_debug_status),
        .debug_pc(override_debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("wave/tb_fpga_top_smoke_pass.vcd");
        $dumpvars(0, tb_fpga_top_smoke_pass);

        reset = 1'b1;
        #1;

        if (default_smoke_pass !== 1'b0 || override_smoke_pass !== 1'b0) begin
            $display("FAIL: smoke_pass should stay low while reset is asserted");
            $fatal;
        end

        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (default_debug_status !== 32'h600d_cafe) begin
            $display("FAIL: default smoke_pass test expected debug_status = %h, got %h",
                     32'h600d_cafe, default_debug_status);
            $fatal;
        end

        if (default_debug_pc !== 32'd24 || default_done !== 1'b1 || default_smoke_pass !== 1'b1) begin
            $display("FAIL: default smoke_pass did not assert at final loop with expected status");
            $fatal;
        end

        if (default_leds !== 8'hfe) begin
            $display("FAIL: default smoke_pass test expected leds = %h, got %h",
                     8'hfe, default_leds);
            $fatal;
        end

        if (override_debug_status !== 32'h1234_56a5) begin
            $display("FAIL: override smoke_pass test expected debug_status = %h, got %h",
                     32'h1234_56a5, override_debug_status);
            $fatal;
        end

        if (override_debug_pc !== 32'd24 || override_done !== 1'b1 || override_smoke_pass !== 1'b1) begin
            $display("FAIL: override smoke_pass did not assert at final loop with expected status");
            $fatal;
        end

        if (override_leds !== 8'ha5) begin
            $display("FAIL: override smoke_pass test expected leds = %h, got %h",
                     8'ha5, override_leds);
            $fatal;
        end

        $display("PASS: fpga top smoke_pass asserted for matching status values");
        $display("PASS: tb_fpga_top_smoke_pass passed");
        $finish;
    end

endmodule
