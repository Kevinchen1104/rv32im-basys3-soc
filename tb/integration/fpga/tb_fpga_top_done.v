`timescale 1ns / 1ps

// Testbench: tb_fpga_top_done
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: FPGA top asserts done at the board-smoke final loop.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Done flag simulation only.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_done;

    reg clock = 0;
    reg reset = 0;
    wire [7:0] leds;
    wire done;
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
        .done(done),
        .debug_status(debug_status),
        .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("wave/tb_fpga_top_done.vcd");
        $dumpvars(0, tb_fpga_top_done);

        reset = 1'b1;
        #1;

        if (done !== 1'b0) begin
            $display("FAIL: done should stay low while reset is asserted");
            $fatal;
        end

        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: done test expected debug_status = %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: done test expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        if (done !== 1'b1) begin
            $display("FAIL: done should assert when debug_pc reaches DONE_PC");
            $fatal;
        end

        if (leds !== 8'hfe) begin
            $display("FAIL: done test expected leds = %h, got %h", 8'hfe, leds);
            $fatal;
        end

        $display("PASS: fpga top asserted done at the board smoke final loop");
        $display("PASS: tb_fpga_top_done passed");
        $finish;
    end

endmodule
