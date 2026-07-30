`timescale 1ns / 1ps

// Testbench: tb_fpga_top_program_override
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: FPGA top program parameters select an alternate smoke image.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Parameter simulation only; no board image flow claim.
// Firmware: firmware/hex/showcase/led_smoke.hex
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_program_override;

    reg clock = 0;
    reg reset = 0;
    wire [7:0] leds;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    RISCVCPU_fpga_top #(
        .PROGRAM_HEX("firmware/hex/showcase/led_smoke.hex"),
        .PROGRAM_WORD_COUNT(7)
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
        $dumpfile("wave/tb_fpga_top_program_override.vcd");
        $dumpvars(0, tb_fpga_top_program_override);

        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;

        repeat (260) @(posedge clock);
        #1;

        if (debug_status !== 32'h1234_56a5) begin
            $display("FAIL: fpga top override expected debug_status = %h, got %h",
                     32'h1234_56a5, debug_status);
            $fatal;
        end

        if (leds !== 8'ha5) begin
            $display("FAIL: fpga top override expected leds = %h, got %h", 8'ha5, leds);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: fpga top override expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        $display("PASS: fpga top program parameters selected alternate smoke image");
        $display("PASS: tb_fpga_top_program_override passed");
        $finish;
    end

endmodule
