`timescale 1ns / 1ps

// Checks: Packetized UART boot loads interactive_showcase_demo through RISCVCPU_uart_boot_runtime_soc_top, releases
//   CPU execution with external IMEM and external DMem enabled, waits for READY, sends runtime command M on the same
//   UART RX pin, captures the transcript, observes GPIO phases/final value, checks external DMem MATVEC/counter
//   snapshots and read/write traffic, sees the public pass signature, and stress-checks synchronous board reset
//   propagation plus external-BRAM retention.
// Firmware: firmware/hex/showcase/interactive_showcase_demo.hex

module tb_fpga_uart_boot_runtime_rx_showcase;
    initial begin : watchdog
        repeat (2000000) @(posedge clock);
        $fatal(1, "Testbench watchdog expired");
    end

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer PROGRAM_WORD_COUNT = 320;
    localparam integer MEMORY_WORD_COUNT = 512;
    localparam integer LAST_DMEM_LINE = (MEMORY_WORD_COUNT / 4) - 1;
    localparam integer MESSAGE_LEN = 74;
    localparam integer READY_PREFIX_LEN = 25;
    localparam integer TIMEOUT_CYCLES = 300000;
    localparam [31:0] MAGIC_WORD = 32'h5256_4254;
    localparam [31:0] VERSION_WORD = 32'h0000_0001;
    localparam [31:0] START_WORD_ADDR = 32'h0000_0000;
    localparam [31:0] PASS_MARKER = 32'h1ace_cafe;
    localparam [31:0] FAIL_MARKER = 32'hbad1_cafe;
    localparam [127:0] RESET_RETAINED_LINE =
        128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210;

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
    wire runtime_uart_rx_valid;
    wire runtime_uart_rx_overrun;
    wire external_dmem_read_seen;
    wire external_dmem_write_seen;

    reg [31:0] program_words[0:PROGRAM_WORD_COUNT-1];
    reg [31:0] checksum = 32'h0;
    reg [8*MESSAGE_LEN-1:0] expected_message;
    reg [7:0] captured [0:MESSAGE_LEN-1];
    integer captured_count = 0;
    integer capture_overflow = 0;
    integer i;
    integer cycle;
    reg command_sent = 1'b0;
    reg seen_runtime_rx_valid = 1'b0;

    reg seen_phase_booted = 1'b0;
    reg seen_phase_ready = 1'b0;
    reg seen_phase_command = 1'b0;
    reg seen_phase_matvec = 1'b0;
    reg seen_phase_counter = 1'b0;
    reg seen_phase_final = 1'b0;

    RISCVCPU_uart_boot_runtime_soc_top #(
        .MEMORY_WORD_COUNT(MEMORY_WORD_COUNT),
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

    task check_external_dmemory_word;
        input integer word_index;
        input [31:0] expected;
        begin
            if (dut.dmem.memory[word_index] !== expected) begin
                $display("FAIL: external DMem[%0d] expected %h, got %h",
                         word_index, expected, dut.dmem.memory[word_index]);
                $fatal;
            end
        end
    endtask

    task check_interactive_snapshot;
        begin
            check_external_dmemory_word(0, 32'hffff_fff6);
            check_external_dmemory_word(1, 32'hffff_fffa);
            check_external_dmemory_word(2, 32'h0000_0182);
            check_external_dmemory_word(3, 32'h0000_0046);
            check_external_dmemory_word(4, 32'h0000_0001);
            check_external_dmemory_word(13, 32'h0000_004d);
            check_external_dmemory_word(64, PASS_MARKER);

            if (dut.dmem.memory[5] === 32'h0 || dut.dmem.memory[7] < dut.dmem.memory[5]) begin
                $display("FAIL: cycle counter snapshot invalid before=%h after=%h",
                         dut.dmem.memory[5], dut.dmem.memory[7]);
                $fatal;
            end
            if (dut.dmem.memory[8] === 32'h0) begin
                $display("FAIL: retired counter snapshot should be nonzero");
                $fatal;
            end
            if (dut.dmem.memory[9] < dut.dmem.memory[6]) begin
                $display("FAIL: stall counter snapshot regressed before=%h after=%h",
                         dut.dmem.memory[6], dut.dmem.memory[9]);
                $fatal;
            end
            if (^{dut.dmem.memory[5], dut.dmem.memory[6], dut.dmem.memory[7], dut.dmem.memory[8],
                  dut.dmem.memory[9], dut.dmem.memory[10], dut.dmem.memory[11], dut.dmem.memory[12]} === 1'bx) begin
                $display("FAIL: performance counter snapshot contains unknown values");
                $fatal;
            end
            if (dut.cpu.DMemory[64] !== 32'h0) begin
                $display("FAIL: internal CPU DMemory should not back debug_status in this top, got %h",
                         dut.cpu.DMemory[64]);
                $fatal;
            end
        end
    endtask

    always @(posedge clock) begin
        if (runtime_uart_rx_valid) begin
            seen_runtime_rx_valid <= 1'b1;
        end

        case (gpio_outputs)
            32'h0000_0011: seen_phase_booted <= 1'b1;
            32'h0000_0022: seen_phase_ready <= 1'b1;
            32'h0000_0033: seen_phase_command <= 1'b1;
            32'h0000_0044: seen_phase_matvec <= 1'b1;
            32'h0000_0055: seen_phase_counter <= 1'b1;
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
        expected_message = "RV32IM INTERACTIVE\nREADY\nCMD M\nMATVEC PASS\nCOUNTERS PASS\nINTERACTIVE PASS\n";

        $dumpfile("results/waveforms/tb_fpga_uart_boot_runtime_rx_showcase.vcd");
        $dumpvars(0, tb_fpga_uart_boot_runtime_rx_showcase);
        $readmemh("firmware/hex/showcase/interactive_showcase_demo.hex", program_words, 0, PROGRAM_WORD_COUNT - 1);

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
            $display("FAIL: runtime SoC top should wait for interactive packet after reset");
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

        wait (loader_done === 1'b1);
        repeat (UART_CLKS_PER_BIT * 12) @(posedge clock);
        #1;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;

            if (!command_sent && captured_count >= READY_PREFIX_LEN) begin
                send_serial_byte(8'h4d);
                command_sent = 1'b1;
            end

            if (boot_error === 1'b1 || smoke_fail === 1'b1 || debug_status === FAIL_MARKER) begin
                $display("FAIL: runtime SoC showcase reported failure error=%b smoke_fail=%b status=%h",
                         boot_error, smoke_fail, debug_status);
                $fatal;
            end

            if (done === 1'b1 && smoke_pass === 1'b1 && captured_count >= MESSAGE_LEN) begin
                cycle = TIMEOUT_CYCLES;
            end
        end

        repeat (1000) @(posedge clock);
        #1;

        if (!command_sent || !seen_runtime_rx_valid) begin
            $display("FAIL: runtime command was not observed sent=%b rx_valid_seen=%b",
                     command_sent, seen_runtime_rx_valid);
            $fatal;
        end
        if (loader_done !== 1'b1 || boot_waiting !== 1'b0 || boot_error !== 1'b0) begin
            $display("FAIL: interactive boot packet did not complete cleanly waiting=%b done=%b error=%b",
                     boot_waiting, loader_done, boot_error);
            $fatal;
        end
        if (done !== 1'b1 || smoke_pass !== 1'b1 || debug_status !== PASS_MARKER) begin
            $display("FAIL: expected interactive pass signature done=%b pass=%b status=%h pc=%h",
                     done, smoke_pass, debug_status, debug_pc);
            $fatal;
        end
        if (runtime_uart_rx_overrun !== 1'b0) begin
            $display("FAIL: runtime UART RX overrun should stay clear");
            $fatal;
        end
        if (gpio_outputs !== 32'h0000_00a5) begin
            $display("FAIL: final GPIO output expected 000000a5, got %h", gpio_outputs);
            $fatal;
        end
        if (!seen_phase_booted || !seen_phase_ready || !seen_phase_command ||
            !seen_phase_matvec || !seen_phase_counter || !seen_phase_final) begin
            $display("FAIL: missing GPIO phase booted=%b ready=%b command=%b matvec=%b counter=%b final=%b",
                     seen_phase_booted, seen_phase_ready, seen_phase_command,
                     seen_phase_matvec, seen_phase_counter, seen_phase_final);
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
        if (!external_dmem_read_seen || !external_dmem_write_seen) begin
            $display("FAIL: expected external DMem read/write traffic, read_seen=%b write_seen=%b",
                     external_dmem_read_seen, external_dmem_write_seen);
            $fatal;
        end

        check_interactive_snapshot();

        if (debug_flags !== {boot_waiting, loader_done, smoke_pass, smoke_fail}) begin
            $display("FAIL: debug_flags did not match boot flags");
            $fatal;
        end

        // The board reset input is sampled synchronously so no async-reset FF
        // drives BRAM controls. The external data memory retains contents while
        // protocol/control state returns to boot waiting.
        @(negedge clock);
        dut.dmem.line_memory[LAST_DMEM_LINE] = RESET_RETAINED_LINE;
        reset = 1'b1;
        #1;
        if (dut.reset_meta !== 1'b0 || dut.reset_sync !== 1'b0 ||
            dut.dmem.line_memory[LAST_DMEM_LINE] !== RESET_RETAINED_LINE) begin
            $display("FAIL: board reset asserted asynchronously or changed BRAM before a clock edge");
            $fatal;
        end
        @(posedge clock);
        #1;
        if (dut.reset_meta !== 1'b1 || dut.reset_sync !== 1'b0) begin
            $display("FAIL: first reset synchronizer stage did not capture assertion");
            $fatal;
        end
        @(posedge clock);
        #1;
        if (dut.reset_sync !== 1'b1 ||
            dut.dmem.line_memory[LAST_DMEM_LINE] !== RESET_RETAINED_LINE) begin
            $display("FAIL: synchronized reset assertion or BRAM retention mismatch");
            $fatal;
        end
        @(posedge clock);
        #1;
        if (dut.dmem.state !== dut.dmem.STATE_IDLE ||
            dut.dmem.line_memory[LAST_DMEM_LINE] !== RESET_RETAINED_LINE) begin
            $display("FAIL: synchronized reset did not clear protocol state while retaining BRAM");
            $fatal;
        end
        @(negedge clock);
        reset = 1'b0;
        repeat (3) @(posedge clock);
        #1;
        if (dut.reset_sync !== 1'b0 || boot_waiting !== 1'b1 ||
            loader_done !== 1'b0 ||
            dut.dmem.line_memory[LAST_DMEM_LINE] !== RESET_RETAINED_LINE) begin
            $display("FAIL: reset release did not return to boot waiting with BRAM retained");
            $fatal;
        end

        $display("PASS: runtime RX handoff accepted command M after packet boot");
        $display("PASS: synchronous board reset retained external BRAM and restarted boot waiting");
        $display("PASS: tb_fpga_uart_boot_runtime_rx_showcase passed");
        $finish;
    end

endmodule
