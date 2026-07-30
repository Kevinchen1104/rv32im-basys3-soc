`timescale 1ns / 1ps

// Testbench: tb_fpga_top_leds_active_low
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: Active-low LED output inversion in the FPGA top.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: LED polarity simulation only.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_leds_active_low;

    reg clock = 0;
    reg reset = 0;
    wire [7:0] leds;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    RISCVCPU_fpga_top #(
        .LEDS_ACTIVE_LOW(1)
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
        .debug_status(debug_status),
        .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("wave/tb_fpga_top_leds_active_low.vcd");
        $dumpvars(0, tb_fpga_top_leds_active_low);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: active-low LEDs expected debug_status = %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (leds !== 8'h01) begin
            $display("FAIL: active-low LEDs expected leds = %h, got %h", 8'h01, leds);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: active-low LEDs expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        $display("PASS: fpga top inverted LED outputs for active-low board LEDs");
        $display("PASS: tb_fpga_top_leds_active_low passed");
        $finish;
    end

endmodule
