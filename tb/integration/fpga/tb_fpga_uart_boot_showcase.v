`timescale 1ns / 1ps

// Testbench: tb_fpga_uart_boot_showcase
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: Packetized UART boot loads showcase_demo through the FPGA-facing top, releases CPU execution, captures the
//   full UART transcript, observes GPIO phases/final value, checks MATVEC/counter snapshots, and sees the public pass
//   signature.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Simulation-tested packet UART boot to CPU execution only; not physical board evidence, timing
//   evidence, or benchmark evidence.
// Firmware: firmware/hex/showcase/showcase_demo.hex
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_uart_boot_showcase;

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer PROGRAM_WORD_COUNT = 269;
    localparam integer MESSAGE_LEN = 64;
    localparam integer TIMEOUT_CYCLES = 200000;
    localparam [31:0] MAGIC_WORD = 32'h5256_4254;
    localparam [31:0] VERSION_WORD = 32'h0000_0001;
    localparam [31:0] START_WORD_ADDR = 32'h0000_0000;
    localparam [31:0] PASS_MARKER = 32'h5a5e_cafe;
    localparam [31:0] FAIL_MARKER = 32'hbad0_5a5e;

    reg clock = 0;
    reg reset = 0;
    reg uart_rx = 1'b1;
    wire uart_tx;
    wire [7:0] leds;
    wire [31:0] gpio_outputs;
    wire done;
    wire boot_waiting;
    wire loader_done;
    wire boot_error;
    wire smoke_pass;
    wire smoke_fail;
    wire heartbeat;
    wire [3:0] debug_flags;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    reg [31:0] program_words[0:PROGRAM_WORD_COUNT-1];
    reg [31:0] checksum = 32'h0;
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

    RISCVCPU_uart_boot_fpga_top #(
        .MEMORY_WORD_COUNT(512),
        .UART_RX_CLKS_PER_BIT(UART_CLKS_PER_BIT),
        .UART_TX_CLKS_PER_BIT(UART_CLKS_PER_BIT),
        .HEARTBEAT_COUNTER_BIT(4),
        .EXPECTED_STATUS(PASS_MARKER),
        .FAIL_STATUS(FAIL_MARKER)
    ) dut (
        .clock(clock),
        .reset(reset),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .leds(leds),
        .gpio_inputs(32'h0),
        .gpio_outputs(gpio_outputs),
        .done(done),
        .boot_waiting(boot_waiting),
        .loader_done(loader_done),
        .boot_error(boot_error),
        .smoke_pass(smoke_pass),
        .smoke_fail(smoke_fail),
        .heartbeat(heartbeat),
        .debug_flags(debug_flags),
        .debug_status(debug_status),
        .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    function [7:0] expected_byte;
        input integer index;
        begin
            expected_byte = expected_message[(MESSAGE_LEN - index) * 8 - 1 -: 8];
        end
    endfunction

    task drive_serial_bit;
        input value;
        integer bit_cycle;
        begin
            uart_rx = value;
            for (bit_cycle = 0; bit_cycle < UART_CLKS_PER_BIT; bit_cycle = bit_cycle + 1) begin
                @(posedge clock);
            end
            #1;
        end
    endtask

    task send_serial_byte;
        input [7:0] value;
        integer bit_index;
        begin
            drive_serial_bit(1'b0);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                drive_serial_bit(value[bit_index]);
            end
            drive_serial_bit(1'b1);
        end
    endtask

    task send_serial_word;
        input [31:0] value;
        begin
            send_serial_byte(value[7:0]);
            send_serial_byte(value[15:8]);
            send_serial_byte(value[23:16]);
            send_serial_byte(value[31:24]);
        end
    endtask

    task capture_serial_byte;
        reg [7:0] value;
        integer bit_index;
        begin
            value = 8'h00;
            @(negedge uart_tx);
            repeat (UART_CLKS_PER_BIT) @(posedge clock);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #1;
                value[bit_index] = uart_tx;
                repeat (UART_CLKS_PER_BIT) @(posedge clock);
            end
            #1;
            if (uart_tx !== 1'b1) begin
                $display("FAIL: UART TX stop bit expected 1, got %b", uart_tx);
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
            if (dut.cpu.DMemory[word_index] !== expected) begin
                $display("FAIL: CPU DMemory[%0d] expected %h, got %h",
                         word_index, expected, dut.cpu.DMemory[word_index]);
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

            if (dut.cpu.DMemory[5] === 32'h0 || dut.cpu.DMemory[7] < dut.cpu.DMemory[5]) begin
                $display("FAIL: cycle counter snapshot invalid before=%h after=%h",
                         dut.cpu.DMemory[5], dut.cpu.DMemory[7]);
                $fatal;
            end
            if (dut.cpu.DMemory[8] === 32'h0) begin
                $display("FAIL: retired counter snapshot should be nonzero");
                $fatal;
            end
            if (dut.cpu.DMemory[9] < dut.cpu.DMemory[6]) begin
                $display("FAIL: stall counter snapshot regressed before=%h after=%h",
                         dut.cpu.DMemory[6], dut.cpu.DMemory[9]);
                $fatal;
            end
            if (^dut.cpu.DMemory[10] === 1'bx ||
                ^dut.cpu.DMemory[11] === 1'bx ||
                ^dut.cpu.DMemory[12] === 1'bx) begin
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
        wait (loader_done === 1'b1);
        forever begin
            capture_serial_byte();
        end
    end

    initial begin
        expected_message = "RV32IM SHOWCASE\nUART OK\nMATVEC PASS\nCOUNTERS PASS\nSHOWCASE PASS\n";

        $dumpfile("wave/tb_fpga_uart_boot_showcase.vcd");
        $dumpvars(0, tb_fpga_uart_boot_showcase);
        $readmemh("firmware/hex/showcase/showcase_demo.hex", program_words, 0, PROGRAM_WORD_COUNT - 1);

        checksum = 32'h0;
        for (i = 0; i < PROGRAM_WORD_COUNT; i = i + 1) begin
            checksum = checksum + program_words[i];
        end

        reset = 1'b1;
        repeat (4) @(posedge clock);
        #1;
        reset = 1'b0;
        repeat (4) @(posedge clock);
        #1;

        if (boot_waiting !== 1'b1 || loader_done !== 1'b0 || boot_error !== 1'b0) begin
            $display("FAIL: boot top should wait for showcase packet after reset");
            $fatal;
        end

        send_serial_word(MAGIC_WORD);
        send_serial_word(VERSION_WORD);
        send_serial_word(START_WORD_ADDR);
        send_serial_word(PROGRAM_WORD_COUNT);
        send_serial_word(checksum);
        for (i = 0; i < PROGRAM_WORD_COUNT; i = i + 1) begin
            send_serial_word(program_words[i]);
        end

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;

            if (boot_error === 1'b1 || smoke_fail === 1'b1 || debug_status === FAIL_MARKER) begin
                $display("FAIL: showcase packet boot reported failure error=%b smoke_fail=%b status=%h",
                         boot_error, smoke_fail, debug_status);
                $fatal;
            end

            if (done === 1'b1 && smoke_pass === 1'b1 && captured_count >= MESSAGE_LEN) begin
                cycle = TIMEOUT_CYCLES;
            end
        end

        if (loader_done !== 1'b1 || boot_waiting !== 1'b0 || boot_error !== 1'b0) begin
            $display("FAIL: showcase boot packet did not complete cleanly waiting=%b done=%b error=%b",
                     boot_waiting, loader_done, boot_error);
            $fatal;
        end
        if (done !== 1'b1 || smoke_pass !== 1'b1 || debug_status !== PASS_MARKER) begin
            $display("FAIL: expected showcase pass signature done=%b pass=%b status=%h pc=%h",
                     done, smoke_pass, debug_status, debug_pc);
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
            $display("FAIL: expected %0d UART TX bytes, got %0d overflow=%0d",
                     MESSAGE_LEN, captured_count, capture_overflow);
            $fatal;
        end

        for (i = 0; i < MESSAGE_LEN; i = i + 1) begin
            if (captured[i] !== expected_byte(i)) begin
                $display("FAIL: UART TX byte %0d expected %h, got %h",
                         i, expected_byte(i), captured[i]);
                $fatal;
            end
        end

        check_showcase_snapshot();

        if (debug_flags !== {boot_waiting, loader_done, smoke_pass, smoke_fail}) begin
            $display("FAIL: debug_flags did not match boot flags");
            $fatal;
        end

        $display("PASS: packetized FPGA UART boot showcase loaded program, emitted transcript, and drove GPIO");
        $display("PASS: tb_fpga_uart_boot_showcase passed");
        $finish;
    end

endmodule
