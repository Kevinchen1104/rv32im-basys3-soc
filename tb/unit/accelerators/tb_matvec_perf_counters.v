`timescale 1ns / 1ps

// Testbench: tb_matvec_perf_counters
// Purpose: Checks a local accelerator block or its MMIO/performance-counter integration.
// Checks: CPU top-level MATVEC counters report Scratchpad accepted starts, done rises, and busy cycles for one
//   four-row operation.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.
// Firmware: firmware/hex/accelerator/matvec_scratchpad_demo.hex

module tb_matvec_perf_counters;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] perf_matvec_start_count;
    wire [31:0] perf_matvec_done_count;
    wire [31:0] perf_matvec_busy_cycle_count;
    wire [31:0] gpio_outputs;
    wire [31:0] gpio_inputs = 32'h0;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;
    wire uart_tx_ready = 1'b1;
    wire [7:0] uart_rx_data = 8'h00;
    wire uart_rx_valid = 1'b0;
    wire uart_rx_ready;
    wire [31:0] imem_addr;
    wire imem_read;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;

    localparam [31:0] PASS_MARKER = 32'hacce_2004;
    localparam [31:0] FAIL_MARKER = 32'hbad0_2004;
    localparam integer TIMEOUT_CYCLES = 2500;

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/accelerator/matvec_scratchpad_demo.hex"),
        .INIT_PROGRAM_WORD_COUNT(74)
    ) dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .trace_valid(),
        .trace_pc(),
        .trace_instruction(),
        .trace_rd(),
        .trace_reg_write(),
        .trace_writeback_value(),
        .perf_cycle_count(),
        .perf_retired_count(),
        .perf_branch_miss_count(),
        .perf_icache_miss_count(),
        .perf_dcache_miss_count(),
        .perf_stall_cycle_count(),
        .perf_matvec_start_count(perf_matvec_start_count),
        .perf_matvec_done_count(perf_matvec_done_count),
        .perf_matvec_busy_cycle_count(perf_matvec_busy_cycle_count),
        .gpio_inputs(gpio_inputs),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(uart_tx_data),
        .uart_tx_valid(uart_tx_valid),
        .uart_tx_ready(uart_tx_ready),
        .uart_rx_data(uart_rx_data),
        .uart_rx_valid(uart_rx_valid),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(uart_rx_ready)
    );

    always #5 clock = ~clock;

    integer cycle;

    initial begin
        $dumpfile("wave/tb_matvec_perf_counters.vcd");
        $dumpvars(0, tb_matvec_perf_counters);

        reset = 1'b1;
        @(posedge clock);
        #1;

        if (perf_matvec_start_count !== 32'd0 ||
            perf_matvec_done_count !== 32'd0 ||
            perf_matvec_busy_cycle_count !== 32'd0) begin
            $display(
                "FAIL: MATVEC counters should reset to zero start=%0d done=%0d busy=%0d",
                perf_matvec_start_count,
                perf_matvec_done_count,
                perf_matvec_busy_cycle_count
            );
            $fatal;
        end

        reset = 1'b0;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;
            if (debug_status === PASS_MARKER || debug_status === FAIL_MARKER) begin
                cycle = TIMEOUT_CYCLES;
            end
        end

        if (debug_status === FAIL_MARKER) begin
            $display("FAIL: matvec_scratchpad_demo stored fail marker %h", debug_status);
            $fatal;
        end

        if (debug_status !== PASS_MARKER) begin
            $display("FAIL: timed out waiting for pass marker, debug_status=%h debug_pc=%h", debug_status, debug_pc);
            $fatal;
        end

        if (perf_matvec_start_count !== 32'd1) begin
            $display("FAIL: expected MATVEC accepted starts = 1, got %0d", perf_matvec_start_count);
            $fatal;
        end

        if (perf_matvec_done_count !== 32'd1) begin
            $display("FAIL: expected MATVEC done events = 1, got %0d", perf_matvec_done_count);
            $fatal;
        end

        if (perf_matvec_busy_cycle_count !== 32'd16) begin
            $display("FAIL: expected MATVEC Scratchpad busy cycles = 16, got %0d", perf_matvec_busy_cycle_count);
            $fatal;
        end

        $display(
            "PASS: MATVEC counters start=%0d done=%0d busy_cycles=%0d",
            perf_matvec_start_count,
            perf_matvec_done_count,
            perf_matvec_busy_cycle_count
        );
        $display("PASS: tb_matvec_perf_counters passed");
        $finish;
    end

endmodule
