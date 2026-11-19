`timescale 1ns / 1ps

// Testbench: tb_program_uart_rx_back_to_back
// Purpose: Runs CPU firmware against the runtime UART RX queue to check that each RXDATA read consumes one byte.
// Checks: With 0x11, 0x22 and 0x33 queued, RXDATA loads on consecutive cycles return 0x11 then 0x22, a status
//   load still reports one byte, and a status load on the cycle after reading 0x33 reports an empty queue; the
//   queue sees exactly three pops and no overrun, and a monitor confirms the back-to-back MEM-stage accesses.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/soc_io/uart_rx_back_to_back.hex

module tb_program_uart_rx_back_to_back;

    localparam [31:0] PASS_MARKER = 32'hc5e3_a0b0;
    localparam [31:0] FAIL_MARKER = 32'hbad5_a0b0;
    localparam integer TIMEOUT_CYCLES = 2000;

    reg clock = 0;
    reg cpu_reset = 1;
    reg queue_reset = 1;
    reg [7:0] queue_in_data = 8'h00;
    reg queue_in_valid = 1'b0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire cpu_uart_rx_ready;
    wire [7:0] queue_rx_data;
    wire queue_rx_valid;
    wire queue_overrun;

    uart_rx_mmio_buffer #(
        .DEPTH(4)
    ) rx_queue (
        .clock(clock),
        .reset(queue_reset),
        .rx_data_in(queue_in_data),
        .rx_valid_in(queue_in_valid),
        .cpu_ready(cpu_uart_rx_ready),
        .rx_data(queue_rx_data),
        .rx_valid(queue_rx_valid),
        .overrun(queue_overrun)
    );

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/soc_io/uart_rx_back_to_back.hex"),
        .INIT_PROGRAM_WORD_COUNT(28)
    ) dut (
        .clock(clock), .reset(cpu_reset),
        .imem_rdata(128'h0), .imem_ready(1'b0),
        .dmem_rdata(128'h0), .dmem_ready(1'b0),
        .gpio_inputs(32'h0), .uart_tx_ready(1'b1),
        .uart_rx_data(queue_rx_data), .uart_rx_valid(queue_rx_valid),
        .uart_rx_overrun(queue_overrun), .uart_rx_ready(cpu_uart_rx_ready),
        .debug_status(debug_status), .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    // Count accepted pops and confirm the firmware produced the intended
    // MEM-stage adjacency: two RXDATA reads, then RXDATA followed by status.
    integer pop_count = 0;
    reg previous_rx_data_read = 1'b0;
    reg rx_data_pair_seen = 1'b0;
    reg rx_data_then_status_seen = 1'b0;

    wire mem_rx_data_read =
        dut.EXMEMLoadValid && dut.EXMEMMmioAccess && dut.EXMEMUartRxDataAccess;
    wire mem_status_read =
        dut.EXMEMLoadValid && dut.EXMEMMmioAccess && dut.EXMEMUartStatusAccess;

    always @(negedge clock) begin
        if (!cpu_reset) begin
            if (cpu_uart_rx_ready && queue_rx_valid) pop_count = pop_count + 1;
            if (previous_rx_data_read && mem_rx_data_read) rx_data_pair_seen = 1'b1;
            if (previous_rx_data_read && mem_status_read) rx_data_then_status_seen = 1'b1;
            previous_rx_data_read = mem_rx_data_read;
        end
    end

    task push_byte;
        input [7:0] value;
        begin
            queue_in_data = value;
            queue_in_valid = 1'b1;
            @(posedge clock);
            #1;
            queue_in_valid = 1'b0;
        end
    endtask

    integer cycles;

    initial begin
        $dumpfile("results/waveforms/tb_program_uart_rx_back_to_back.vcd");
        $dumpvars(0, tb_program_uart_rx_back_to_back);

        @(posedge clock);
        #1;
        queue_reset = 1'b0;
        push_byte(8'h11);
        push_byte(8'h22);
        push_byte(8'h33);
        if (rx_queue.count !== 3) begin
            $display("FAIL: RX queue holds %0d bytes before CPU start", rx_queue.count);
            $fatal;
        end

        cpu_reset = 1'b0;
        cycles = 0;
        while (cycles < TIMEOUT_CYCLES &&
               debug_status !== PASS_MARKER && debug_status !== FAIL_MARKER) begin
            @(posedge clock);
            #1;
            cycles = cycles + 1;
        end
        if (debug_status === FAIL_MARKER)
            $fatal(1, "FAIL: firmware saw a0=%h a1=%h status=%h a3=%h status=%h",
                   dut.Regs[10], dut.Regs[11], dut.Regs[12], dut.Regs[13], dut.Regs[14]);
        if (debug_status !== PASS_MARKER)
            $fatal(1, "FAIL: timed out after %0d cycles; status=%h pc=%h", cycles, debug_status, debug_pc);

        if (!rx_data_pair_seen || !rx_data_then_status_seen) begin
            $display("FAIL: intended MEM-stage adjacency not exercised pair=%0b status_after=%0b",
                     rx_data_pair_seen, rx_data_then_status_seen);
            $fatal;
        end
        if (pop_count !== 3 || rx_queue.count !== 0 || queue_overrun !== 1'b0) begin
            $display("FAIL: RX queue pops=%0d count=%0d overrun=%0b", pop_count, rx_queue.count, queue_overrun);
            $fatal;
        end

        $display("PASS: tb_program_uart_rx_back_to_back passed");
        $finish;
    end

endmodule
