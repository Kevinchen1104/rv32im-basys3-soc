`timescale 1ns / 1ps

// Checks: FPGA top debug flags summarize reset, done, pass, and fail state.

module tb_fpga_top_debug_flags;

    reg clock = 0;
    reg reset = 0;

    wire [7:0] pass_leds;
    wire pass_done;
    wire pass_smoke_pass;
    wire pass_smoke_fail;
    wire [3:0] pass_debug_flags;
    wire [31:0] pass_debug_status;
    wire [31:0] pass_debug_pc;

    wire [7:0] fail_leds;
    wire fail_done;
    wire fail_smoke_pass;
    wire fail_smoke_fail;
    wire [3:0] fail_debug_flags;
    wire [31:0] fail_debug_status;
    wire [31:0] fail_debug_pc;

    RISCVCPU_fpga_top pass_dut (
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
        .done(pass_done),
        .smoke_pass(pass_smoke_pass),
        .smoke_fail(pass_smoke_fail),
        .debug_flags(pass_debug_flags),
        .debug_status(pass_debug_status),
        .debug_pc(pass_debug_pc)
    );

    RISCVCPU_fpga_top #(
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
        .done(fail_done),
        .smoke_pass(fail_smoke_pass),
        .smoke_fail(fail_smoke_fail),
        .debug_flags(fail_debug_flags),
        .debug_status(fail_debug_status),
        .debug_pc(fail_debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("results/waveforms/tb_fpga_top_debug_flags.vcd");
        $dumpvars(0, tb_fpga_top_debug_flags);

        reset = 1'b1;
        #1;

        if (pass_debug_flags !== 4'b1000 || fail_debug_flags !== 4'b1000) begin
            $display("FAIL: debug_flags should show reset-only while reset is asserted");
            $fatal;
        end

        repeat (2) @(negedge clock);
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (pass_debug_status !== 32'h600d_cafe || pass_debug_pc !== 32'd24) begin
            $display("FAIL: pass debug_flags DUT did not reach expected smoke state");
            $fatal;
        end

        if (pass_debug_flags !== 4'b0110) begin
            $display("FAIL: pass debug_flags expected %b, got %b",
                     4'b0110, pass_debug_flags);
            $fatal;
        end

        if (fail_debug_status !== 32'h600d_cafe || fail_debug_pc !== 32'd24) begin
            $display("FAIL: fail debug_flags DUT did not reach expected smoke state");
            $fatal;
        end

        if (fail_debug_flags !== 4'b0101) begin
            $display("FAIL: fail debug_flags expected %b, got %b",
                     4'b0101, fail_debug_flags);
            $fatal;
        end

        if (pass_leds !== 8'hfe || fail_leds !== 8'hfe) begin
            $display("FAIL: debug_flags test expected both LED outputs to remain status low byte");
            $fatal;
        end

        $display("PASS: fpga top debug flags summarized reset/done/pass/fail state");
        $display("PASS: tb_fpga_top_debug_flags passed");
        $finish;
    end

endmodule
