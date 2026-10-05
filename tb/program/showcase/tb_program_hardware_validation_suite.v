`timescale 1ns / 1ps

// Testbench: tb_program_hardware_validation_suite
// Purpose: Runs the combined RV32M, machine-timer, and MATVEC DMA-lite validation firmware directly on the CPU.
// Checks: Exact UART transcript, GPIO phases, timer trap snapshots, DMA results/PERF/clear state, and public status.
// Pass condition: Every firmware self-check completes, all public/snapshot evidence matches, and no fail marker appears.
// Firmware: firmware/hex/showcase/hardware_validation_suite.hex

module tb_program_hardware_validation_suite;
    initial begin : watchdog
        repeat (2000000) @(posedge clock);
        $fatal(1, "Testbench watchdog expired");
    end

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer PROGRAM_WORD_COUNT = 508;
    localparam integer MESSAGE_LEN = 82;
    localparam integer TIMEOUT_CYCLES = 180000;
    localparam [31:0] PASS_MARKER = 32'h600d_cafe;
    localparam [31:0] FAIL_MARKER = 32'hbad0_a5a5;

    reg clock = 1'b0;
    reg reset = 1'b0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    wire [7:0] cpu_uart_tx_data;
    wire cpu_uart_tx_valid;
    wire uart_tx_ready;
    wire uart_tx_line;
    wire uart_tx_busy;

    reg [8*MESSAGE_LEN-1:0] expected_message;
    reg [7:0] captured [0:MESSAGE_LEN-1];
    integer captured_count = 0;
    integer capture_overflow = 0;
    integer cycle;
    integer i;
    reg seen_start = 1'b0;
    reg seen_rv32m = 1'b0;
    reg seen_timer = 1'b0;
    reg seen_dma = 1'b0;
    reg seen_final = 1'b0;

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/showcase/hardware_validation_suite.hex"),
        .INIT_PROGRAM_WORD_COUNT(PROGRAM_WORD_COUNT)
    ) dut (
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
        .gpio_inputs(32'h0),
        .gpio_outputs(gpio_outputs),
        .uart_tx_data(cpu_uart_tx_data),
        .uart_tx_valid(cpu_uart_tx_valid),
        .uart_tx_ready(uart_tx_ready),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready()
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
                #1 value[bit_index] = uart_tx_line;
                repeat (UART_CLKS_PER_BIT) @(posedge clock);
            end
            #1;
            if (uart_tx_line !== 1'b1) begin
                $display("FAIL: UART stop bit expected high");
                $fatal;
            end
            if (captured_count < MESSAGE_LEN)
                captured[captured_count] = value;
            else
                capture_overflow = 1;
            captured_count = captured_count + 1;
        end
    endtask

    task check_word;
        input integer index;
        input [31:0] expected;
        begin
            if (dut.DMemory[index] !== expected) begin
                $display("FAIL: DMemory[%0d] expected %h got %h", index, expected, dut.DMemory[index]);
                $fatal;
            end
        end
    endtask

    always @(posedge clock) begin
        case (gpio_outputs)
            32'h10: seen_start <= 1'b1;
            32'h21: seen_rv32m <= 1'b1;
            32'h32: seen_timer <= 1'b1;
            32'h43: seen_dma <= 1'b1;
            32'ha6: seen_final <= 1'b1;
            32'hee: begin
                $display("FAIL: hardware validation firmware raised GPIO failure marker");
                $fatal;
            end
            default: begin end
        endcase
    end

    initial begin : capture_thread
        wait (reset === 1'b0);
        forever capture_serial_byte();
    end

    initial begin
        expected_message = "RV32IM HW VALIDATION\nRV32M PASS\nTIMER IRQ PASS\nMATVEC DMA PASS\nHW VALIDATION PASS\n";
        $dumpfile("results/waveforms/tb_program_hardware_validation_suite.vcd");
        $dumpvars(0, tb_program_hardware_validation_suite);

        reset = 1'b1;
        repeat (3) @(posedge clock);
        #1 reset = 1'b0;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;
            if (debug_status === FAIL_MARKER) begin
                $display("FAIL: firmware stored fail marker at pc=%h", debug_pc);
                $fatal;
            end
            if (debug_status === PASS_MARKER && captured_count >= MESSAGE_LEN && !uart_tx_busy)
                cycle = TIMEOUT_CYCLES;
        end

        if (debug_status !== PASS_MARKER || gpio_outputs !== 32'ha6) begin
            $display("FAIL: final status/gpio mismatch status=%h gpio=%h pc=%h", debug_status, gpio_outputs, debug_pc);
            $fatal;
        end
        if (!seen_start || !seen_rv32m || !seen_timer || !seen_dma || !seen_final) begin
            $display("FAIL: missing GPIO phase start=%b m=%b timer=%b dma=%b final=%b",
                     seen_start, seen_rv32m, seen_timer, seen_dma, seen_final);
            $fatal;
        end
        if (capture_overflow || captured_count !== MESSAGE_LEN) begin
            $display("FAIL: UART length expected %0d got %0d overflow=%0d", MESSAGE_LEN, captured_count, capture_overflow);
            $fatal;
        end
        for (i = 0; i < MESSAGE_LEN; i = i + 1) begin
            if (captured[i] !== expected_byte(i)) begin
                $display("FAIL: UART byte %0d expected %h got %h", i, expected_byte(i), captured[i]);
                $fatal;
            end
        end

        check_word(80, 32'h8000_0007);
        if (^dut.DMemory[81] === 1'bx || dut.DMemory[81] === 32'h0 || dut.DMemory[81][1:0] !== 2'b00) begin
            $display("FAIL: timer mepc snapshot invalid %h", dut.DMemory[81]);
            $fatal;
        end
        if (dut.DMemory[82][7] !== 1'b1 || dut.DMemory[83] !== 32'h1 ||
            (dut.DMemory[84] & 32'h88) !== 32'h88) begin
            $display("FAIL: timer snapshots mip=%h flag=%h mstatus=%h",
                     dut.DMemory[82], dut.DMemory[83], dut.DMemory[84]);
            $fatal;
        end
        check_word(85, 32'h0405_0101);
        check_word(86, 32'h0);
        check_word(104, 32'hffff_fff6);
        check_word(105, 32'hffff_fffa);
        check_word(106, 32'h0000_0182);
        check_word(107, 32'h0000_0046);
        check_word(64, PASS_MARKER);

        if (dut.CSRmip[7] !== 1'b0 || dut.CSRmie[7] !== 1'b0 ||
            dut.matvec_dma_status_read_data[2:1] !== 2'b00) begin
            $display("FAIL: timer/DMA clear state mip=%h mie=%h dma_status=%h",
                     dut.CSRmip, dut.CSRmie, dut.matvec_dma_status_read_data);
            $fatal;
        end

        $display("PASS: combined RV32M, timer IRQ, and MATVEC DMA firmware evidence matched");
        $display("PASS: tb_program_hardware_validation_suite passed");
        $finish;
    end

endmodule
