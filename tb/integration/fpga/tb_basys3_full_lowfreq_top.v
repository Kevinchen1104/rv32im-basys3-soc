`timescale 1ns / 1ps

// Purpose: Exercises the complete Basys3 SoC through the portable 6.25 MHz clock-generator model.
// Checks: Divide-by-16 clocking, lock-gated reset, serial packet boot, public pass/done LEDs, heartbeat, and reset restart.
// Pass condition: The checked-in board-smoke packet reaches the public LED pass state and reset returns the top to boot waiting.
// Firmware: fixtures/generated/boot/board_smoke.boot.bin

module tb_basys3_full_lowfreq_top;
    initial begin : watchdog
        repeat (2000000) @(posedge clk);
        $fatal(1, "Testbench watchdog expired");
    end

    localparam integer UART_CLKS_PER_BIT = 54;
    localparam integer PACKET_BYTE_COUNT = 48;
    localparam integer TIMEOUT_SOC_CYCLES = 5000;

    reg clk = 1'b0;
    reg btnC = 1'b1;
    reg RsRx = 1'b1;
    reg [15:0] sw = 16'h0000;
    wire RsTx;
    wire [15:0] led;

    reg [7:0] packet_bytes [0:PACKET_BYTE_COUNT-1];
    integer packet_file;
    integer bytes_read;
    integer input_edge_count = 0;
    integer first_soc_edge;
    integer second_soc_edge;
    integer byte_index;
    integer cycle;
    reg heartbeat_seen_low = 1'b0;
    reg heartbeat_seen_high = 1'b0;

    RISCVCPU_basys3_full_lowfreq_top #(
        .MEMORY_WORD_COUNT(128),
        .UART_RX_CLKS_PER_BIT(UART_CLKS_PER_BIT),
        .UART_TX_CLKS_PER_BIT(UART_CLKS_PER_BIT),
        .HEARTBEAT_COUNTER_BIT(3)
    ) dut (
        .clk(clk),
        .btnC(btnC),
        .RsRx(RsRx),
        .RsTx(RsTx),
        .sw(sw),
        .led(led)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        input_edge_count = input_edge_count + 1;
    end

    always @(posedge dut.soc_clk) begin
        if (led[3]) begin
            heartbeat_seen_high <= 1'b1;
        end else begin
            heartbeat_seen_low <= 1'b1;
        end
    end

    task drive_serial_bit;
        input value;
        integer bit_cycle;
        begin
            RsRx = value;
            for (bit_cycle = 0; bit_cycle < UART_CLKS_PER_BIT; bit_cycle = bit_cycle + 1) begin
                @(posedge dut.soc_clk);
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

    initial begin
        $dumpfile("results/waveforms/tb_basys3_full_lowfreq_top.vcd");
        $dumpvars(0, tb_basys3_full_lowfreq_top);

        packet_file = $fopen("fixtures/generated/boot/board_smoke.boot.bin", "rb");
        if (packet_file == 0) begin
            $display("FAIL: could not open board_smoke.boot.bin");
            $fatal;
        end
        bytes_read = $fread(packet_bytes, packet_file);
        $fclose(packet_file);
        if (bytes_read != PACKET_BYTE_COUNT) begin
            $display("FAIL: expected %0d packet bytes, read %0d", PACKET_BYTE_COUNT, bytes_read);
            $fatal;
        end

        repeat (8) @(posedge clk);
        if (dut.clock_locked !== 1'b0 || dut.soc_reset !== 1'b1) begin
            $display("FAIL: reset must hold clock unlocked and SoC reset asserted");
            $fatal;
        end

        @(negedge clk);
        btnC = 1'b0;
        wait (dut.clock_locked === 1'b1);
        #1;
        if (dut.soc_reset !== 1'b0) begin
            $display("FAIL: SoC reset should release after clock lock");
            $fatal;
        end

        @(posedge dut.soc_clk);
        first_soc_edge = input_edge_count;
        @(posedge dut.soc_clk);
        second_soc_edge = input_edge_count;
        if ((second_soc_edge - first_soc_edge) != 16) begin
            $display("FAIL: expected divide-by-16 SoC clock, measured %0d input cycles",
                     second_soc_edge - first_soc_edge);
            $fatal;
        end

        repeat (6) @(posedge dut.soc_clk);
        #1;
        if (led[7:4] !== 4'h8 || led[2:0] !== 3'b000) begin
            $display("FAIL: expected boot-wait LEDs before packet, got %h", led);
            $fatal;
        end

        for (byte_index = 0; byte_index < PACKET_BYTE_COUNT; byte_index = byte_index + 1) begin
            send_serial_byte(packet_bytes[byte_index]);
        end

        for (cycle = 0; cycle < TIMEOUT_SOC_CYCLES; cycle = cycle + 1) begin
            @(posedge dut.soc_clk);
            #1;
            if (led[1] === 1'b1) begin
                $display("FAIL: full low-frequency top asserted fail LED, leds=%h", led);
                $fatal;
            end
            if (led[0] === 1'b1 && led[2] === 1'b1) begin
                cycle = TIMEOUT_SOC_CYCLES;
            end
        end

        if (led[0] !== 1'b1 || led[1] !== 1'b0 || led[2] !== 1'b1 || led[7:4] !== 4'h6) begin
            $display("FAIL: expected pass/done/debug LEDs after boot, got %h", led);
            $fatal;
        end
        if (RsTx !== 1'b1) begin
            $display("FAIL: board-smoke firmware should leave UART TX idle high");
            $fatal;
        end
        if (!heartbeat_seen_low || !heartbeat_seen_high) begin
            $display("FAIL: heartbeat did not toggle low/high");
            $fatal;
        end

        @(negedge clk);
        btnC = 1'b1;
        repeat (4) @(posedge clk);
        if (dut.clock_locked !== 1'b0 || dut.soc_reset !== 1'b1) begin
            $display("FAIL: btnC should reset the clock generator and SoC");
            $fatal;
        end

        @(negedge clk);
        btnC = 1'b0;
        wait (dut.clock_locked === 1'b1);
        repeat (6) @(posedge dut.soc_clk);
        #1;
        if (led[7:4] !== 4'h8 || led[2:0] !== 3'b000) begin
            $display("FAIL: reset release should restart packet boot waiting, got %h", led);
            $fatal;
        end

        $display("PASS: full low-frequency Basys3 top packet-booted board_smoke and restarted after reset");
        $display("PASS: tb_basys3_full_lowfreq_top passed");
        $finish;
    end

endmodule
