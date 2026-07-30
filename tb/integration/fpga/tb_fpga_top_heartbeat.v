`timescale 1ns / 1ps

// Testbench: tb_fpga_top_heartbeat
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: Heartbeat toggles after synchronized reset release.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Simulation heartbeat only; no board clock claim.
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_top_heartbeat;

    reg clock = 0;
    reg reset = 0;
    wire heartbeat;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    RISCVCPU_fpga_top #(
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
        .leds(),
        .done(),
        .smoke_pass(),
        .smoke_fail(),
        .heartbeat(heartbeat),
        .debug_flags(),
        .debug_status(debug_status),
        .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    initial begin
        $dumpfile("wave/tb_fpga_top_heartbeat.vcd");
        $dumpvars(0, tb_fpga_top_heartbeat);

        reset = 1'b1;
        #1;

        if (heartbeat !== 1'b0) begin
            $display("FAIL: heartbeat should be low while reset is asserted");
            $fatal;
        end

        repeat (2) @(posedge clock);
        reset = 1'b0;

        repeat (4) @(posedge clock);
        #1;

        if (heartbeat !== 1'b0) begin
            $display("FAIL: heartbeat should stay low through synchronized reset release");
            $fatal;
        end

        repeat (4) @(posedge clock);
        #1;

        if (heartbeat !== 1'b1) begin
            $display("FAIL: heartbeat should toggle high after the post-reset counter advances");
            $fatal;
        end

        repeat (4) @(posedge clock);
        #1;

        if (heartbeat !== 1'b0) begin
            $display("FAIL: heartbeat should toggle low again as the counter continues");
            $fatal;
        end

        repeat (252) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe || debug_pc !== 32'd24) begin
            $display("FAIL: heartbeat DUT did not preserve board smoke execution");
            $fatal;
        end

        $display("PASS: fpga top heartbeat toggled after synchronized reset release");
        $display("PASS: tb_fpga_top_heartbeat passed");
        $finish;
    end

endmodule
