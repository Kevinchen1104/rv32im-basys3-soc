`timescale 1ns / 1ps

// Checks: The WB-stage trace port reports retired writeback events.
// The reference testbenches compare the visible trace against expected instruction behavior.

module tb_trace;

    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] trace_instruction;
    wire [4:0] trace_rd;
    wire trace_reg_write;
    wire [31:0] trace_writeback_value;

    integer trace_writes = 0;

    RISCVCPU dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(),
        .dmem_read(),
        .dmem_write(),
        .dmem_wdata(),
        .dmem_byte_enable(),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_rx_ready(),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .trace_valid(trace_valid),
        .trace_pc(trace_pc),
        .trace_instruction(trace_instruction),
        .trace_rd(trace_rd),
        .trace_reg_write(trace_reg_write),
        .trace_writeback_value(trace_writeback_value)
    );

    always #5 clock = ~clock;

    task check_trace_write;
        input integer index;
        input [31:0] expected_pc;
        input [31:0] expected_instruction;
        input [4:0] expected_rd;
        input [31:0] expected_value;
        begin
            if (trace_pc !== expected_pc ||
                trace_instruction !== expected_instruction ||
                trace_rd !== expected_rd ||
                trace_writeback_value !== expected_value) begin
                $display("FAIL: trace[%0d] expected pc=%h ir=%h rd=%0d value=%h, got pc=%h ir=%h rd=%0d value=%h",
                         index,
                         expected_pc,
                         expected_instruction,
                         expected_rd,
                         expected_value,
                         trace_pc,
                         trace_instruction,
                         trace_rd,
                         trace_writeback_value);
                $fatal;
            end
        end
    endtask

    always @(posedge clock) begin
        #1;
        if (!reset && trace_valid && trace_reg_write) begin
            case (trace_writes)
                0: check_trace_write(0, 32'd0, 32'h0050_0093, 5'd1, 32'd5);
                1: check_trace_write(1, 32'd4, 32'h0070_8113, 5'd2, 32'd12);
                2: begin
                    check_trace_write(2, 32'd8, 32'h0020_81b3, 5'd3, 32'd17);
                    $display("PASS: trace port reported retired writeback events");
                    $display("PASS: tb_trace passed");
                    $finish;
                end
                default: begin
                    $display("FAIL: unexpected extra trace writeback event");
                    $fatal;
                end
            endcase

            trace_writes = trace_writes + 1;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_trace.vcd");
        $dumpvars(0, tb_trace);
        #1; // Initialize test memory after the DUT initial block.

        dut.IMemory[0] = 32'h0050_0093; // addi x1, x0, 5
        dut.IMemory[1] = 32'h0070_8113; // addi x2, x1, 7
        dut.IMemory[2] = 32'h0020_81b3; // add x3, x1, x2

        reset = 1'b1;
        repeat (2) @(negedge clock);
        reset = 1'b0;

        repeat (120) @(posedge clock);

        $display("FAIL: expected 3 trace writeback events, got %0d", trace_writes);
        $fatal;
    end

endmodule
