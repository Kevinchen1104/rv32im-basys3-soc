`timescale 1ns / 1ps

// Testbench: tb_matvec_perf_counters
// Purpose: Checks a local accelerator block or its MMIO/performance-counter integration.
// Checks: CPU top-level MATVEC counters report Scratchpad accepted starts, done rises, and busy cycles for one
//   four-row operation.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.
// Firmware: firmware/hex/accelerator/matvec_scratchpad_demo.hex

module tb_matvec_perf_counters;

    reg clock = 0;
    reg reset = 1;
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
    integer lane;
    reg [31:0] injected_address;
    reg [31:0] injected_data;
    reg [2:0] injected_funct3;
    reg injected_valid;
    reg [31:0] expected_word;

    // Inject an accepted MEM-stage store to exercise the real address decoder
    // and byte-lane wiring independently of instruction scheduling.
    task mmio_store;
        input [31:0] address;
        input [31:0] value;
        input [2:0] width;
        begin
            @(negedge clock);
            injected_address = address;
            injected_data = value;
            injected_funct3 = width;
            injected_valid = 1'b1;
            @(posedge clock);
            #1;
            injected_valid = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_matvec_perf_counters.vcd");
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

        @(negedge clock);
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
        @(negedge clock);
        reset = 1'b1;
        @(negedge clock);
        reset = 1'b0;
        injected_valid = 1'b0;
        force dut.EXMEMStoreValid = injected_valid;
        force dut.EXMEMALUOut = injected_address;
        force dut.EXMEMfunct3 = injected_funct3;
        force dut.StoreData = injected_data;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            mmio_store(32'h70c, 32'h1234_5678, 3'b010);
            mmio_store(32'h70c + lane, 32'ha0 + lane, 3'b000);
            expected_word = (32'h1234_5678 & ~(32'hff << (8 * lane))) |
                            ((32'ha0 + lane) << (8 * lane));
            if (dut.matvec_vector_read_data !== expected_word)
                $fatal(1, "MATVEC MMIO byte lane %0d", lane);
        end
        for (lane = 0; lane < 4; lane = lane + 2) begin
            mmio_store(32'h710, 32'd3, 3'b010);
            mmio_store(32'h714, 32'h1234_5678, 3'b010);
            mmio_store(32'h714 + lane, 32'hbeef, 3'b001);
            expected_word = (32'h1234_5678 & ~(32'hffff << (8 * lane))) |
                            (32'hbeef << (8 * lane));
            if (dut.matvec_row_data_read_data !== expected_word)
                $fatal(1, "MATVEC MMIO halfword lane %0d", lane);
        end
        mmio_store(32'h711, 32'd9, 3'b000);
        if (dut.matvec_row_index_read_data !== 32'd3)
            $fatal(1, "MATVEC upper index byte changed index");
        mmio_store(32'h701, 32'd1, 3'b000);
        if (dut.matvec_status_read_data[0] !== 1'b0)
            $fatal(1, "MATVEC upper control byte started operation");
        if (perf_matvec_start_count !== 0 || perf_matvec_done_count !== 0)
            $fatal(1, "MATVEC upper control byte changed operation counters");
        release dut.EXMEMStoreValid;
        release dut.EXMEMALUOut;
        release dut.EXMEMfunct3;
        release dut.StoreData;
        $display("PASS: MATVEC MMIO byte and halfword lanes preserve untouched data");
        $display("PASS: tb_matvec_perf_counters passed");
        $finish;
    end

endmodule
