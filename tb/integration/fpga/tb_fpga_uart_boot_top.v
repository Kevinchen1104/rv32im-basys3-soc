`timescale 1ns / 1ps

// Testbench: tb_fpga_uart_boot_top
// Purpose: Exercises an FPGA-facing simulation wrapper or UART boot path.
// Checks: The packetized UART boot FPGA top accepts a serial boot packet for uart_gpio_demo, releases CPU execution
//   from external IMEM, reconstructs UART TX output, observes GPIO 0xa5, and sees the public pass signature.
// Pass condition: Wrapper outputs, UART transcript, GPIO/status signals, or boot markers match expected values before
//   timeout.
// Does not prove: Simulation-tested serial boot packet flow and board-facing top-level ports only; not physically
//   board-validated, not timing evidence, and not a deploy-ready boot ROM.
// Firmware: firmware/hex/soc_io/uart_gpio_demo.hex
// Boundary: Simulation wrapper evidence only; not timing closure or physical board validation.

module tb_fpga_uart_boot_top;

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer PROGRAM_WORD_COUNT = 54;
    localparam integer MESSAGE_LEN = 14;
    localparam integer TIMEOUT_CYCLES = 50000;
    localparam [31:0] MAGIC_WORD = 32'h5256_4254;
    localparam [31:0] VERSION_WORD = 32'h0000_0001;
    localparam [31:0] START_WORD_ADDR = 32'h0000_0000;
    localparam [31:0] PASS_MARKER = 32'h10c0_a5a5;
    localparam [31:0] FAIL_MARKER = 32'hbad0_a5a5;

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
    reg [7:0] captured [0:MESSAGE_LEN-1];
    integer captured_count = 0;
    integer capture_overflow = 0;
    integer i;
    integer cycle;

    RISCVCPU_uart_boot_fpga_top #(
        .MEMORY_WORD_COUNT(256),
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
            case (index)
                0: expected_byte = 8'h52;
                1: expected_byte = 8'h56;
                2: expected_byte = 8'h33;
                3: expected_byte = 8'h32;
                4: expected_byte = 8'h49;
                5: expected_byte = 8'h4d;
                6: expected_byte = 8'h20;
                7: expected_byte = 8'h43;
                8: expected_byte = 8'h50;
                9: expected_byte = 8'h55;
                10: expected_byte = 8'h20;
                11: expected_byte = 8'h4f;
                12: expected_byte = 8'h4b;
                13: expected_byte = 8'h0a;
                default: expected_byte = 8'hxx;
            endcase
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

    initial begin : capture_thread
        wait (loader_done === 1'b1);
        forever begin
            capture_serial_byte();
        end
    end

    initial begin
        $dumpfile("wave/tb_fpga_uart_boot_top.vcd");
        $dumpvars(0, tb_fpga_uart_boot_top);
        $readmemh("firmware/hex/soc_io/uart_gpio_demo.hex", program_words, 0, PROGRAM_WORD_COUNT - 1);

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
            $display("FAIL: boot top should wait for packet after reset");
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
                $display("FAIL: packet boot top reported failure error=%b smoke_fail=%b status=%h",
                         boot_error, smoke_fail, debug_status);
                $fatal;
            end

            if (done === 1'b1 && smoke_pass === 1'b1 && captured_count >= MESSAGE_LEN) begin
                cycle = TIMEOUT_CYCLES;
            end
        end

        if (loader_done !== 1'b1 || boot_waiting !== 1'b0 || boot_error !== 1'b0) begin
            $display("FAIL: boot packet did not complete cleanly waiting=%b done=%b error=%b",
                     boot_waiting, loader_done, boot_error);
            $fatal;
        end
        if (done !== 1'b1 || smoke_pass !== 1'b1 || debug_status !== PASS_MARKER) begin
            $display("FAIL: expected pass signature done=%b pass=%b status=%h pc=%h",
                     done, smoke_pass, debug_status, debug_pc);
            $fatal;
        end
        if (gpio_outputs !== 32'h0000_00a5) begin
            $display("FAIL: GPIO output expected 000000a5, got %h", gpio_outputs);
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

        if (debug_flags !== {boot_waiting, loader_done, smoke_pass, smoke_fail}) begin
            $display("FAIL: debug_flags did not match boot flags");
            $fatal;
        end

        $display("PASS: packetized FPGA UART boot top loaded uart_gpio_demo, emitted UART string, and drove GPIO");
        $display("PASS: tb_fpga_uart_boot_top passed");
        $finish;
    end

endmodule
