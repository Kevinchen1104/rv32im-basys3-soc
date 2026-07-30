`timescale 1ns / 1ps

// Testbench: tb_program_showcase_demo
// Purpose: Runs showcase firmware and observes public status, I/O, or transcript outputs.
// Checks: CPU program emits the showcase UART transcript, drives GPIO phase markers, runs the MATVEC Scratchpad
//   case, stores MATVEC results and counter snapshots, and exposes a public pass/fail signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
//   or performance claims.
// Firmware: firmware/hex/showcase/showcase_demo.hex

module tb_program_showcase_demo;

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer MESSAGE_LEN = 64;
    localparam integer TIMEOUT_CYCLES = 120000;
    localparam integer PROGRAM_WORD_COUNT = 269;
    localparam [31:0] PASS_MARKER = 32'h5a5e_cafe;
    localparam [31:0] FAIL_MARKER = 32'hbad0_5a5e;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    wire [31:0] gpio_inputs = 32'h0;
    wire [7:0] cpu_uart_tx_data;
    wire cpu_uart_tx_valid;
    wire uart_tx_ready;
    wire uart_tx_line;
    wire uart_tx_busy;
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

    reg [8*MESSAGE_LEN-1:0] expected_message;
    reg [7:0] captured [0:MESSAGE_LEN-1];
    integer captured_count = 0;
    integer capture_overflow = 0;
    integer i;
    integer cycle;

    reg seen_phase_start = 1'b0;
    reg seen_phase_uart = 1'b0;
    reg seen_phase_matvec_running = 1'b0;
    reg seen_phase_matvec_pass = 1'b0;
    reg seen_phase_counter_pass = 1'b0;
    reg seen_phase_final = 1'b0;

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/showcase/showcase_demo.hex"),
        .INIT_PROGRAM_WORD_COUNT(PROGRAM_WORD_COUNT)
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
        .perf_matvec_start_count(),
        .perf_matvec_done_count(),
        .perf_matvec_busy_cycle_count(),
        .gpio_inputs(gpio_inputs),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(cpu_uart_tx_data),
        .uart_tx_valid(cpu_uart_tx_valid),
        .uart_tx_ready(uart_tx_ready),
        .uart_rx_data(uart_rx_data),
        .uart_rx_valid(uart_rx_valid),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(uart_rx_ready)
    );

    uart_tx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) serial_tx (
        .clock(clock),
        .reset(reset),
        .data_in(cpu_uart_tx_data),
        .valid(cpu_uart_tx_valid),
        .ready(uart_tx_ready),
        .tx(uart_tx_line),
        .busy(uart_tx_busy)
    );

    always #5 clock = ~clock;

    function [7:0] expected_byte;
        input integer index;
        begin
            expected_byte = expected_message[(MESSAGE_LEN - index) * 8 - 1 -: 8];
        end
    endfunction

    task capture_serial_byte;
        reg [7:0] value;
        integer bit_index;
        begin
            value = 8'h00;
            @(negedge uart_tx_line);
            repeat (UART_CLKS_PER_BIT) @(posedge clock);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #1;
                value[bit_index] = uart_tx_line;
                repeat (UART_CLKS_PER_BIT) @(posedge clock);
            end
            #1;
            if (uart_tx_line !== 1'b1) begin
                $display("FAIL: UART stop bit expected 1, got %b", uart_tx_line);
                $fatal;
            end
            if (captured_count < MESSAGE_LEN) begin
                captured[captured_count] = value;
            end else begin
                capture_overflow = 1;
            end
            captured_count = captured_count + 1;
        end
    endtask

    task check_dmemory_word;
        input integer word_index;
        input [31:0] expected;
        begin
            if (dut.DMemory[word_index] !== expected) begin
                $display("FAIL: DMemory[%0d] expected %h, got %h",
                         word_index, expected, dut.DMemory[word_index]);
                $fatal;
            end
        end
    endtask

    task check_showcase_snapshot;
        begin
            check_dmemory_word(0, 32'hffff_fff6);
            check_dmemory_word(1, 32'hffff_fffa);
            check_dmemory_word(2, 32'h0000_0182);
            check_dmemory_word(3, 32'h0000_0046);
            check_dmemory_word(4, 32'h0000_0001);

            if (dut.DMemory[5] === 32'h0 || dut.DMemory[7] < dut.DMemory[5]) begin
                $display("FAIL: cycle counter snapshot invalid before=%h after=%h",
                         dut.DMemory[5], dut.DMemory[7]);
                $fatal;
            end
            if (dut.DMemory[8] === 32'h0) begin
                $display("FAIL: retired counter snapshot should be nonzero");
                $fatal;
            end
            if (dut.DMemory[9] < dut.DMemory[6]) begin
                $display("FAIL: stall counter snapshot regressed before=%h after=%h",
                         dut.DMemory[6], dut.DMemory[9]);
                $fatal;
            end
            if (^dut.DMemory[10] === 1'bx ||
                ^dut.DMemory[11] === 1'bx ||
                ^dut.DMemory[12] === 1'bx) begin
                $display("FAIL: MATVEC counter snapshot contains unknown values");
                $fatal;
            end
        end
    endtask

    always @(posedge clock) begin
        case (gpio_outputs)
            32'h0000_0001: seen_phase_start <= 1'b1;
            32'h0000_0002: seen_phase_uart <= 1'b1;
            32'h0000_0004: seen_phase_matvec_running <= 1'b1;
            32'h0000_0008: seen_phase_matvec_pass <= 1'b1;
            32'h0000_0010: seen_phase_counter_pass <= 1'b1;
            32'h0000_00a5: seen_phase_final <= 1'b1;
            default: begin
            end
        endcase
    end

    initial begin : capture_thread
        wait (reset === 1'b0);
        forever begin
            capture_serial_byte();
        end
    end

    initial begin
        expected_message = "RV32IM SHOWCASE\nUART OK\nMATVEC PASS\nCOUNTERS PASS\nSHOWCASE PASS\n";

        $dumpfile("wave/tb_program_showcase_demo.vcd");
        $dumpvars(0, tb_program_showcase_demo);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;

            if (debug_status === FAIL_MARKER) begin
                $display("FAIL: showcase_demo stored fail marker %h", debug_status);
                $fatal;
            end

            if (debug_status === PASS_MARKER &&
                captured_count >= MESSAGE_LEN &&
                uart_tx_busy === 1'b0) begin
                cycle = TIMEOUT_CYCLES;
            end
        end

        if (debug_status !== PASS_MARKER) begin
            $display("FAIL: timed out waiting for pass marker, debug_status=%h debug_pc=%h", debug_status, debug_pc);
            $fatal;
        end

        if (gpio_outputs !== 32'h0000_00a5) begin
            $display("FAIL: final GPIO output expected 000000a5, got %h", gpio_outputs);
            $fatal;
        end
        if (!seen_phase_start || !seen_phase_uart || !seen_phase_matvec_running ||
            !seen_phase_matvec_pass || !seen_phase_counter_pass || !seen_phase_final) begin
            $display("FAIL: missing GPIO phase start=%b uart=%b matvec_run=%b matvec_pass=%b counter=%b final=%b",
                     seen_phase_start, seen_phase_uart, seen_phase_matvec_running,
                     seen_phase_matvec_pass, seen_phase_counter_pass, seen_phase_final);
            $fatal;
        end

        if (capture_overflow !== 0 || captured_count !== MESSAGE_LEN) begin
            $display("FAIL: expected %0d UART bytes, got %0d overflow=%0d",
                     MESSAGE_LEN, captured_count, capture_overflow);
            $fatal;
        end

        for (i = 0; i < MESSAGE_LEN; i = i + 1) begin
            if (captured[i] !== expected_byte(i)) begin
                $display("FAIL: UART byte %0d expected %h, got %h",
                         i, expected_byte(i), captured[i]);
                $fatal;
            end
        end

        check_showcase_snapshot();

        if (uart_tx_line !== 1'b1 || uart_tx_ready !== 1'b1) begin
            $display("FAIL: UART TX should be idle and ready after showcase");
            $fatal;
        end

        $display("PASS: showcase_demo transcript, GPIO phases, MATVEC Scratchpad, counters, and signature matched");
        $display("PASS: tb_program_showcase_demo passed");
        $finish;
    end

endmodule
