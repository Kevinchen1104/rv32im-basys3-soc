`timescale 1ns / 1ps

// Testbench: tb_fpga_uart_boot_hardware_validation_suite
// Purpose: Packet-boots the combined hardware validation suite through the runtime SoC external-memory wrapper.
// Checks: Serial packet loading, exact UART transcript, GPIO/public status, external-DMem snapshots, and DMA traffic.
// Pass condition: Loader, CPU, timer interrupt, DMA-lite, external memory, and UART evidence all complete cleanly.
// Does not prove: Simulation wrapper evidence only; not physical-board validation or exhaustive feature coverage.
// Firmware: firmware/hex/showcase/hardware_validation_suite.hex

module tb_fpga_uart_boot_hardware_validation_suite;

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer PROGRAM_WORD_COUNT = 508;
    localparam integer MESSAGE_LEN = 82;
    localparam integer TIMEOUT_CYCLES = 360000;
    localparam [31:0] MAGIC_WORD = 32'h5256_4254;
    localparam [31:0] VERSION_WORD = 32'h1;
    localparam [31:0] PASS_MARKER = 32'h600d_cafe;
    localparam [31:0] FAIL_MARKER = 32'hbad0_a5a5;

    reg clock = 1'b0;
    reg reset = 1'b0;
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
    wire runtime_uart_rx_valid;
    wire runtime_uart_rx_overrun;
    wire external_dmem_read_seen;
    wire external_dmem_write_seen;

    reg [31:0] program_words [0:PROGRAM_WORD_COUNT-1];
    reg [31:0] checksum = 32'h0;
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

    RISCVCPU_uart_boot_runtime_soc_top #(
        .MEMORY_WORD_COUNT(1024),
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
        .debug_pc(debug_pc),
        .runtime_uart_rx_valid(runtime_uart_rx_valid),
        .runtime_uart_rx_overrun(runtime_uart_rx_overrun),
        .external_dmem_read_seen(external_dmem_read_seen),
        .external_dmem_write_seen(external_dmem_write_seen)
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
            for (bit_cycle = 0; bit_cycle < UART_CLKS_PER_BIT; bit_cycle = bit_cycle + 1)
                @(posedge clock);
            #1;
        end
    endtask

    task send_serial_byte;
        input [7:0] value;
        integer bit_index;
        begin
            drive_serial_bit(1'b0);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                drive_serial_bit(value[bit_index]);
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
                #1 value[bit_index] = uart_tx;
                repeat (UART_CLKS_PER_BIT) @(posedge clock);
            end
            #1;
            if (uart_tx !== 1'b1) begin
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

    task check_external_word;
        input integer index;
        input [31:0] expected;
        begin
            if (dut.dmem.memory[index] !== expected) begin
                $display("FAIL: external DMem[%0d] expected %h got %h", index, expected, dut.dmem.memory[index]);
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
                $display("FAIL: integration firmware raised GPIO failure marker");
                $fatal;
            end
            default: begin end
        endcase
    end

    initial begin : capture_thread
        wait (loader_done === 1'b1);
        forever capture_serial_byte();
    end

    initial begin
        expected_message = "RV32IM HW VALIDATION\nRV32M PASS\nTIMER IRQ PASS\nMATVEC DMA PASS\nHW VALIDATION PASS\n";
        $dumpfile("wave/tb_fpga_uart_boot_hardware_validation_suite.vcd");
        $dumpvars(0, tb_fpga_uart_boot_hardware_validation_suite);
        $readmemh("firmware/hex/showcase/hardware_validation_suite.hex", program_words, 0, PROGRAM_WORD_COUNT - 1);

        for (i = 0; i < PROGRAM_WORD_COUNT; i = i + 1)
            checksum = checksum + program_words[i];

        reset = 1'b1;
        repeat (4) @(posedge clock);
        #1 reset = 1'b0;
        repeat (4) @(posedge clock);
        #1;
        if (!boot_waiting || loader_done || boot_error) begin
            $display("FAIL: runtime SoC should wait for validation packet");
            $fatal;
        end

        send_serial_word(MAGIC_WORD);
        send_serial_word(VERSION_WORD);
        send_serial_word(32'h0);
        send_serial_word(PROGRAM_WORD_COUNT);
        send_serial_word(checksum);
        for (i = 0; i < PROGRAM_WORD_COUNT; i = i + 1)
            send_serial_word(program_words[i]);

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;
            if (boot_error || smoke_fail || debug_status === FAIL_MARKER) begin
                $display("FAIL: runtime validation reported error=%b fail=%b status=%h pc=%h",
                         boot_error, smoke_fail, debug_status, debug_pc);
                $fatal;
            end
            if (done && smoke_pass && captured_count >= MESSAGE_LEN)
                cycle = TIMEOUT_CYCLES;
        end

        if (!loader_done || boot_waiting || boot_error || !done || !smoke_pass || smoke_fail ||
            debug_status !== PASS_MARKER || gpio_outputs !== 32'ha6) begin
            $display("FAIL: final public outputs waiting=%b load=%b error=%b done=%b pass=%b fail=%b status=%h gpio=%h",
                     boot_waiting, loader_done, boot_error, done, smoke_pass, smoke_fail, debug_status, gpio_outputs);
            $fatal;
        end
        if (!seen_start || !seen_rv32m || !seen_timer || !seen_dma || !seen_final) begin
            $display("FAIL: missing integration GPIO phase start=%b m=%b timer=%b dma=%b final=%b",
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

        check_external_word(80, 32'h8000_0007);
        if (dut.dmem.memory[81] === 32'h0 || dut.dmem.memory[81][1:0] !== 2'b00 ||
            !dut.dmem.memory[82][7] || dut.dmem.memory[83] !== 32'h1 ||
            (dut.dmem.memory[84] & 32'h88) !== 32'h88) begin
            $display("FAIL: external timer snapshots mepc=%h mip=%h flag=%h mstatus=%h",
                     dut.dmem.memory[81], dut.dmem.memory[82], dut.dmem.memory[83], dut.dmem.memory[84]);
            $fatal;
        end
        check_external_word(85, 32'h0405_0101);
        check_external_word(86, 32'h0);
        check_external_word(104, 32'hffff_fff6);
        check_external_word(105, 32'hffff_fffa);
        check_external_word(106, 32'h0000_0182);
        check_external_word(107, 32'h0000_0046);
        check_external_word(64, PASS_MARKER);

        if (!external_dmem_read_seen || !external_dmem_write_seen ||
            dut.cpu.DMemory[64] !== 32'h0 || dut.cpu.matvec_dma_status_read_data[2:1] !== 2'b00) begin
            $display("FAIL: external ownership/clear evidence read=%b write=%b internal=%h dma_status=%h",
                     external_dmem_read_seen, external_dmem_write_seen,
                     dut.cpu.DMemory[64], dut.cpu.matvec_dma_status_read_data);
            $fatal;
        end

        $display("PASS: packet-boot hardware validation used external memory and matched all evidence");
        $display("PASS: tb_fpga_uart_boot_hardware_validation_suite passed");
        $finish;
    end

endmodule
