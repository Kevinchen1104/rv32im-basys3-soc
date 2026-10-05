`timescale 1ns / 1ps

// Checks: FPGA top exposes board-smoke status on LED outputs.

module tb_fpga_top_board_smoke;

    reg clock = 0;
    reg reset = 0;
    wire [7:0] leds;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    RISCVCPU_fpga_top dut (
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
        $dumpfile("results/waveforms/tb_fpga_top_board_smoke.vcd");
        $dumpvars(0, tb_fpga_top_board_smoke);

        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: fpga top expected debug_status = %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (leds !== 8'hfe) begin
            $display("FAIL: fpga top expected leds = %h, got %h", 8'hfe, leds);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: fpga top expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        $display("PASS: fpga top exposed board smoke status on LEDs");
        $display("PASS: tb_fpga_top_board_smoke passed");
        $finish;
    end

endmodule
