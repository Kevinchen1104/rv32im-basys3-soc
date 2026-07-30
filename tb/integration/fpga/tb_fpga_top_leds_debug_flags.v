`timescale 1ns / 1ps

// Testbench: tb_fpga_top_leds_debug_flags
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: FPGA top maps debug flags onto LED outputs.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Wrapper LED debug mapping only.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_leds_debug_flags;

    reg clock = 0;
    reg reset = 0;

    wire [7:0] pass_leds;
    wire [3:0] pass_debug_flags;
    wire [31:0] pass_debug_status;
    wire [31:0] pass_debug_pc;

    wire [7:0] fail_leds;
    wire [3:0] fail_debug_flags;
    wire [31:0] fail_debug_status;
    wire [31:0] fail_debug_pc;

    RISCVCPU_fpga_top #(
        .LEDS_SHOW_DEBUG_FLAGS(1)
    ) pass_dut (
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
        .leds(pass_leds),
        .done(),
        .smoke_pass(),
        .smoke_fail(),
        .debug_flags(pass_debug_flags),
        .debug_status(pass_debug_status),
        .debug_pc(pass_debug_pc)
    );

    RISCVCPU_fpga_top #(
        .LEDS_SHOW_DEBUG_FLAGS(1),
        .EXPECTED_STATUS(32'hdead_beef)
    ) fail_dut (
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
        .leds(fail_leds),
        .done(),
        .smoke_pass(),
        .smoke_fail(),
        .debug_flags(fail_debug_flags),
        .debug_status(fail_debug_status),
        .debug_pc(fail_debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("wave/tb_fpga_top_leds_debug_flags.vcd");
        $dumpvars(0, tb_fpga_top_leds_debug_flags);

        reset = 1'b1;
        #1;

        if (pass_leds !== 8'h08 || fail_leds !== 8'h08) begin
            $display("FAIL: debug flag LEDs should show reset-only state");
            $fatal;
        end

        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (pass_debug_status !== 32'h600d_cafe || pass_debug_pc !== 32'd24) begin
            $display("FAIL: pass debug flag LED DUT did not reach expected smoke state");
            $fatal;
        end

        if (pass_debug_flags !== 4'b0110 || pass_leds !== 8'h06) begin
            $display("FAIL: pass debug flag LEDs expected flags=%b leds=%h, got flags=%b leds=%h",
                     4'b0110, 8'h06, pass_debug_flags, pass_leds);
            $fatal;
        end

        if (fail_debug_status !== 32'h600d_cafe || fail_debug_pc !== 32'd24) begin
            $display("FAIL: fail debug flag LED DUT did not reach expected smoke state");
            $fatal;
        end

        if (fail_debug_flags !== 4'b0101 || fail_leds !== 8'h05) begin
            $display("FAIL: fail debug flag LEDs expected flags=%b leds=%h, got flags=%b leds=%h",
                     4'b0101, 8'h05, fail_debug_flags, fail_leds);
            $fatal;
        end

        $display("PASS: fpga top mapped debug flags onto LED outputs");
        $display("PASS: tb_fpga_top_leds_debug_flags passed");
        $finish;
    end

endmodule
