`timescale 1ns / 1ps

// Testbench: tb_fpga_top_reset_sync
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: FPGA top reset synchronizer releases the CPU cleanly.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Simulation reset check only; no timing closure claim.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_reset_sync;

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
        $dumpfile("wave/tb_fpga_top_reset_sync.vcd");
        $dumpvars(0, tb_fpga_top_reset_sync);

        #2;
        reset = 1'b1;
        #1;

        if (dut.reset_sync !== 1'b1) begin
            $display("FAIL: reset_sync should assert immediately with external reset");
            $fatal;
        end

        #5;
        reset = 1'b0;  // release away from a clock edge
        #1;

        if (dut.reset_sync !== 1'b1) begin
            $display("FAIL: reset_sync should stay high before synchronized release");
            $fatal;
        end

        @(posedge clock);
        #1;

        if (dut.reset_sync !== 1'b1) begin
            $display("FAIL: reset_sync should remain high for first release clock");
            $fatal;
        end

        @(posedge clock);
        #1;

        if (dut.reset_sync !== 1'b0) begin
            $display("FAIL: reset_sync should deassert on second release clock");
            $fatal;
        end

        repeat (260) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: reset sync test expected debug_status = %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (leds !== 8'hfe) begin
            $display("FAIL: reset sync test expected leds = %h, got %h", 8'hfe, leds);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: reset sync test expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        $display("PASS: fpga top reset synchronizer released CPU cleanly");
        $display("PASS: tb_fpga_top_reset_sync passed");
        $finish;
    end

endmodule
