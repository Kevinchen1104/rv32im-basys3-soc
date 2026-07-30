`timescale 1ns / 1ps

// Testbench: tb_program_interactive_showcase_demo
// Purpose: Runs showcase firmware and observes public status, I/O, or transcript outputs.
// Checks: CPU program emits the interactive UART transcript, waits for runtime UART RX command M through the MMIO RX
//   buffer, drives GPIO phases, runs the MATVEC Scratchpad case, stores MATVEC/counter snapshots, and exposes a
//   public pass/fail signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
//   timing, CPI, speedup, or physical board evidence.
// Firmware: firmware/hex/showcase/interactive_showcase_demo.hex

module tb_program_interactive_showcase_demo;

    localparam integer UART_CLKS_PER_BIT = 4;
    localparam integer MESSAGE_LEN = 74;
    localparam integer READY_PREFIX_LEN = 25;
    localparam integer TIMEOUT_CYCLES = 160000;
    localparam integer PROGRAM_WORD_COUNT = 320;
    localparam [31:0] PASS_MARKER = 32'h1ace_cafe;
    localparam [31:0] FAIL_MARKER = 32'hbad1_cafe;

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
    wire [7:0] buffered_uart_rx_data;
    wire buffered_uart_rx_valid;
    wire buffered_uart_rx_overrun;
    wire cpu_uart_rx_ready;
    wire [31:0] imem_addr;
    wire imem_read;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;

    reg [7:0] runtime_rx_data = 8'h00;
    reg runtime_rx_valid = 1'b0;
    reg [8*MESSAGE_LEN-1:0] expected_message;
    reg [7:0] captured [0:MESSAGE_LEN-1];
    integer captured_count = 0;
    integer capture_overflow = 0;
    integer rx_ready_count = 0;
    integer i;
    integer cycle;
    reg command_sent = 1'b0;

    reg seen_phase_booted = 1'b0;
    reg seen_phase_ready = 1'b0;
    reg seen_phase_command = 1'b0;
    reg seen_phase_matvec = 1'b0;
    reg seen_phase_counter = 1'b0;
    reg seen_phase_final = 1'b0;

    uart_rx_mmio_buffer runtime_rx_buffer (
        .clock(clock),
        .reset(reset),
        .rx_data_in(runtime_rx_data),
        .rx_valid_in(runtime_rx_valid),
        .cpu_ready(cpu_uart_rx_ready),
        .rx_data(buffered_uart_rx_data),
        .rx_valid(buffered_uart_rx_valid),
        .overrun(buffered_uart_rx_overrun)
    );

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/showcase/interactive_showcase_demo.hex"),
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
        .uart_rx_data(buffered_uart_rx_data),
        .uart_rx_valid(buffered_uart_rx_valid),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(cpu_uart_rx_ready)
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

    task pulse_runtime_byte;
        input [7:0] value;
        begin
            runtime_rx_data = value;
            runtime_rx_valid = 1'b1;
            @(posedge clock);
            #1;
            runtime_rx_valid = 1'b0;
        end
    endtask

    // Reconstruct the UART transcript from the serial line instead of trusting internal byte events.
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

    task check_interactive_snapshot;
        begin
            check_dmemory_word(0, 32'hffff_fff6);
            check_dmemory_word(1, 32'hffff_fffa);
            check_dmemory_word(2, 32'h0000_0182);
            check_dmemory_word(3, 32'h0000_0046);
            check_dmemory_word(4, 32'h0000_0001);
            check_dmemory_word(13, 32'h0000_004d);
            check_dmemory_word(64, PASS_MARKER);

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
        if (cpu_uart_rx_ready) begin
            rx_ready_count <= rx_ready_count + 1;
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
        wait (reset === 1'b0);
        forever begin
            capture_serial_byte();
        end
    end

    initial begin
        expected_message = "RV32IM INTERACTIVE\nREADY\nCMD M\nMATVEC PASS\nCOUNTERS PASS\nINTERACTIVE PASS\n";

        $dumpfile("wave/tb_program_interactive_showcase_demo.vcd");
        $dumpvars(0, tb_program_interactive_showcase_demo);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;

            // Send the runtime command only after the READY prefix has appeared on UART TX.
            if (!command_sent && captured_count >= READY_PREFIX_LEN) begin
                pulse_runtime_byte(8'h4d);
                command_sent = 1'b1;
            end

            if (debug_status === FAIL_MARKER) begin
                $display("FAIL: interactive_showcase_demo stored fail marker %h", debug_status);
                $fatal;
            end

            if (debug_status === PASS_MARKER &&
                captured_count >= MESSAGE_LEN &&
                uart_tx_busy === 1'b0) begin
                cycle = TIMEOUT_CYCLES;
            end
        end

        repeat (1000) @(posedge clock);
        #1;

        if (!command_sent || rx_ready_count != 1) begin
            $display("FAIL: expected one runtime command read sent=%b rx_ready_count=%0d",
                     command_sent, rx_ready_count);
            $fatal;
        end
        if (debug_status !== PASS_MARKER) begin
            $display("FAIL: timed out waiting for pass marker, debug_status=%h debug_pc=%h", debug_status, debug_pc);
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
        if (buffered_uart_rx_valid !== 1'b0 || buffered_uart_rx_overrun !== 1'b0) begin
            $display("FAIL: runtime RX buffer should be empty with no overrun valid=%b overrun=%b",
                     buffered_uart_rx_valid, buffered_uart_rx_overrun);
            $fatal;
        end

        check_interactive_snapshot();

        $display("PASS: interactive_showcase_demo accepted command M and completed transcript");
        $display("PASS: tb_program_interactive_showcase_demo passed");
        $finish;
    end

endmodule
