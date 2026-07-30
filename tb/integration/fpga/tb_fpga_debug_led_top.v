`timescale 1ns / 1ps

// Testbench: tb_fpga_debug_led_top
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: Debug LED top displays board-smoke debug flags.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Debug wrapper simulation only; no board-specific constraint proof.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_debug_led_top;

    reg clock = 0;
    reg reset = 0;
    wire [7:0] leds;
    wire done;
    wire smoke_pass;
    wire smoke_fail;
    wire heartbeat;
    wire [3:0] debug_flags;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    RISCVCPU_fpga_debug_led_top #(
        .HEARTBEAT_COUNTER_BIT(2)
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
        .heartbeat(heartbeat),
        .debug_flags(debug_flags),
        .debug_status(debug_status),
        .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("wave/tb_fpga_debug_led_top.vcd");
        $dumpvars(0, tb_fpga_debug_led_top);

        reset = 1'b1;
        #1;

        if (leds !== 8'h08 || debug_flags !== 4'b1000) begin
            $display("FAIL: debug LED top should show reset flag while reset is asserted");
            $fatal;
        end

        if (heartbeat !== 1'b0) begin
            $display("FAIL: debug LED top heartbeat should be low while reset is asserted");
            $fatal;
        end

        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (4) @(posedge clock);
        #1;

        if (heartbeat !== 1'b0) begin
            $display("FAIL: debug LED top heartbeat should stay low through synchronized reset release");
            $fatal;
        end

        repeat (4) @(posedge clock);
        #1;

        if (heartbeat !== 1'b1) begin
            $display("FAIL: debug LED top heartbeat should toggle high after reset release");
            $fatal;
        end

        repeat (4) @(posedge clock);
        #1;

        if (heartbeat !== 1'b0) begin
            $display("FAIL: debug LED top heartbeat should toggle low as the counter continues");
            $fatal;
        end

        repeat (248) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: debug LED top expected debug_status = %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: debug LED top expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        if (done !== 1'b1 || smoke_pass !== 1'b1 || smoke_fail !== 1'b0) begin
            $display("FAIL: debug LED top expected done/pass/fail = 1/1/0");
            $fatal;
        end

        if (debug_flags !== 4'b0110 || leds !== 8'h06) begin
            $display("FAIL: debug LED top expected flags=%b leds=%h, got flags=%b leds=%h",
                     4'b0110, 8'h06, debug_flags, leds);
            $fatal;
        end

        $display("PASS: fpga debug LED top displayed board smoke debug flags");
        $display("PASS: tb_fpga_debug_led_top passed");
        $finish;
    end

endmodule
