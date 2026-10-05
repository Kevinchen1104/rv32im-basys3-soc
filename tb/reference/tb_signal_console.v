`timescale 1ns / 1ps

// Boot compiled C and exchange real UART bits through the complete board top.
module tb_signal_console;
    parameter FAST_MULTIPLY = 1;
    parameter ICACHE_BYTES = 64;
    parameter ICACHE_PARALLEL_LOOKUP = 1;
    parameter DCACHE_BYTES = 64;
    parameter DCACHE_VICTIM_LINES = 0;
    localparam BIT_CLOCKS = 8;
    reg clock = 0;
    reg reset = 1;
    reg rx = 1;
    wire tx;
    wire [15:0] leds;
    reg [2047:0] packet_path, script_path, output_path;
    reg [7:0] received [0:32767];
    integer received_count = 0;
    integer consumed = 0;
    integer script_file, output_file, token, scan;
    integer burst_count = 0;
    integer max_rx_occupancy = 0;
    reg [7:0] byte_value;

    RISCVCPU_basys3_top #(
        .FAST_MULTIPLY(FAST_MULTIPLY),
        .ICACHE_BYTES(ICACHE_BYTES), .ICACHE_PARALLEL_LOOKUP(ICACHE_PARALLEL_LOOKUP),
        .DCACHE_BYTES(DCACHE_BYTES), .DCACHE_VICTIM_LINES(DCACHE_VICTIM_LINES),
        .ENABLE_MATVEC_SCRATCHPAD(0), .ENABLE_MATVEC_DMA(0),
        .UART_RX_CLKS_PER_BIT(BIT_CLOCKS), .UART_TX_CLKS_PER_BIT(BIT_CLOCKS)
    ) dut (.clk(clock), .btnC(reset), .RsRx(rx), .RsTx(tx),
           .sw(16'ha55a), .led(leds));

    always #5 clock = ~clock;
    always @(negedge clock)
        if (!reset && dut.soc.runtime_rx_buffer.count > max_rx_occupancy)
            max_rx_occupancy = dut.soc.runtime_rx_buffer.count;
    initial begin
        repeat (20000000) @(posedge clock);
        $fatal(1, "signal console watchdog");
    end

    initial forever begin : capture
        reg [7:0] value;
        integer bit_index;
        @(negedge tx);
        repeat (BIT_CLOCKS / 2) @(negedge clock);
        if (tx !== 0) $fatal(1, "UART start bit");
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            repeat (BIT_CLOCKS) @(negedge clock);
            value[bit_index] = tx;
        end
        repeat (BIT_CLOCKS) @(negedge clock);
        if (tx !== 1) $fatal(1, "UART stop bit");
        if (received_count == 32768) $fatal(1, "capture overflow");
        received[received_count] = value;
        received_count = received_count + 1;
    end

    task send_byte(input [7:0] value);
        integer bit_index;
        begin
            @(negedge clock);
            rx = 0;
            repeat (BIT_CLOCKS) @(negedge clock);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                rx = value[bit_index];
                repeat (BIT_CLOCKS) @(negedge clock);
            end
            rx = 1;
            repeat (BIT_CLOCKS) @(negedge clock);
        end
    endtask

    task get_byte(output [7:0] value);
        integer cycles;
        begin
            cycles = 0;
            while (consumed == received_count && cycles < 500000) begin
                @(negedge clock);
                cycles = cycles + 1;
            end
            if (consumed == received_count) $fatal(1, "UART response timeout");
            value = received[consumed];
            consumed = consumed + 1;
        end
    endtask

    task boot;
        integer packet_file, value, index;
        reg [39:0] greeting;
        begin
            @(negedge clock);
            reset = 1;
            rx = 1;
            repeat (20) @(negedge clock);
            consumed = received_count;
            reset = 0;
            repeat (20) @(negedge clock);
            packet_file = $fopen(packet_path, "rb");
            if (!packet_file) $fatal(1, "missing packet");
            value = $fgetc(packet_file);
            while (value != -1) begin
                send_byte(value[7:0]);
                value = $fgetc(packet_file);
            end
            $fclose(packet_file);
            greeting = 0;
            for (index = 0; index < 5; index = index + 1) begin
                get_byte(byte_value);
                greeting = {greeting[31:0], byte_value};
            end
            if (greeting !== "FIR2\n") $fatal(1, "incorrect greeting %h", greeting);
            burst_count = 0;
        end
    endtask

    initial begin
        if (!$value$plusargs("packet=%s", packet_path) ||
            !$value$plusargs("script=%s", script_path) ||
            !$value$plusargs("output=%s", output_path)) $fatal(1, "missing paths");
        script_file = $fopen(script_path, "r");
        output_file = $fopen(output_path, "w");
        if (!script_file || !output_file) $fatal(1, "cannot open simulation files");
        boot();
        while (!$feof(script_file)) begin
            scan = $fscanf(script_file, "%h\n", token);
            if (scan == 0) $fatal(1, "malformed hexadecimal test token");
            if (scan == 1) begin
                if (^token === 1'bx || token < 0) $fatal(1, "invalid test token");
                if (token == 'h101) begin
                    boot();
                end else if (token == 'h100) begin
                    get_byte(byte_value);
                    if (byte_value !== 8'h7e) $fatal(1, "missing response delimiter");
                    $fwrite(output_file, "%02x", byte_value);
                    get_byte(byte_value);
                    while (byte_value !== 8'h7e) begin
                        if (^byte_value === 1'bx) $fatal(1, "unknown response byte");
                        $fwrite(output_file, "%02x", byte_value);
                        get_byte(byte_value);
                    end
                    $fwrite(output_file, "7e %02x\n", leds[15:8]);
                end else if (token <= 255) begin
                    send_byte(token[7:0]);
                    burst_count = burst_count + 1;
                    if (token == 'h7e || burst_count == 32) begin
                        get_byte(byte_value);
                        if (byte_value !== 8'h06) $fatal(1, "missing burst ACK: %h", byte_value);
                        burst_count = 0;
                    end
                end else $fatal(1, "invalid test token");
                if (dut.soc.runtime_uart_rx_overrun !== 1'b0 || dut.soc.boot_error !== 1'b0)
                    $fatal(1, "UART overrun or boot failure");
            end
        end
        $fclose(script_file);
        $fclose(output_file);
        $display("PASS: compiled FIR firmware, serial boot, commands, LEDs and reset");
        $display("Maximum RX FIFO occupancy: %0d / 64", max_rx_occupancy);
        $finish;
    end
endmodule
