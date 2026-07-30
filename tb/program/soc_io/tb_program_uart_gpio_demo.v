`timescale 1ns / 1ps

// Testbench: tb_program_uart_gpio_demo
// Purpose: Runs CPU firmware through board-facing MMIO observability and I/O paths.
// Checks: CPU program polls UART TX ready through MMIO, emits RV32IM CPU OK newline through the synthesizable UART TX
//   serializer, writes GPIO output pattern 0xa5, reads GPIO back in software, and exposes a public debug_status
//   pass/fail signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
//   timing/baud tolerance proof, or physical board validation.
// Firmware: firmware/hex/soc_io/uart_gpio_demo.hex

module tb_program_uart_gpio_demo;

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer MESSAGE_LEN = 14;
    localparam integer TIMEOUT_CYCLES = 20000;
    localparam [31:0] PASS_MARKER = 32'h10c0_a5a5;
    localparam [31:0] FAIL_MARKER = 32'hbad0_a5a5;

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

    reg [7:0] captured [0:MESSAGE_LEN-1];
    integer captured_count = 0;
    integer capture_overflow = 0;

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/soc_io/uart_gpio_demo.hex"),
        .INIT_PROGRAM_WORD_COUNT(54)
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
            case (index)
                0: expected_byte = 8'h52;  // R
                1: expected_byte = 8'h56;  // V
                2: expected_byte = 8'h33;  // 3
                3: expected_byte = 8'h32;  // 2
                4: expected_byte = 8'h49;  // I
                5: expected_byte = 8'h4d;  // M
                6: expected_byte = 8'h20;  // space
                7: expected_byte = 8'h43;  // C
                8: expected_byte = 8'h50;  // P
                9: expected_byte = 8'h55;  // U
                10: expected_byte = 8'h20;  // space
                11: expected_byte = 8'h4f;  // O
                12: expected_byte = 8'h4b;  // K
                13: expected_byte = 8'h0a;  // newline
                default: expected_byte = 8'hxx;
            endcase
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

    integer cycle;
    integer i;

    initial begin : capture_thread
        wait (reset === 1'b0);
        forever begin
            capture_serial_byte();
        end
    end

    initial begin
        $dumpfile("wave/tb_program_uart_gpio_demo.vcd");
        $dumpvars(0, tb_program_uart_gpio_demo);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;

            if (debug_status === FAIL_MARKER) begin
                $display("FAIL: uart_gpio_demo stored fail marker %h", debug_status);
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
            $display("FAIL: GPIO output expected 000000a5, got %h", gpio_outputs);
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

        if (uart_tx_line !== 1'b1 || uart_tx_ready !== 1'b1) begin
            $display("FAIL: UART TX should be idle and ready after demo");
            $fatal;
        end

        $display("PASS: uart_gpio_demo emitted RV32IM CPU OK\\n and GPIO 0xa5");
        $display("PASS: tb_program_uart_gpio_demo passed");
        $finish;
    end

endmodule
