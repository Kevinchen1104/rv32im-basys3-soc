`timescale 1ns / 1ps

// Testbench: tb_uart_packet_boot_imem
// Purpose: Exercises the UART boot/loading path around instruction memory release.
// Checks: A valid packetized UART boot image loads IMEM, clears the unused tail before release, and runs board_smoke.
// Pass condition: The boot/load path accepts the expected data and reaches the checked release, status, or rejection
//   condition.
// Firmware: firmware/hex/showcase/board_smoke.hex

module tb_uart_packet_boot_imem;

    localparam WORD_COUNT = 7;
    localparam MAGIC_WORD = 32'h5256_4254;
    localparam VERSION_WORD = 32'h0000_0001;
    localparam START_WORD_ADDR = 32'h0000_0000;

    reg clock = 0;
    reg external_reset = 0;
    reg [7:0] rx_data = 8'h00;
    reg rx_valid = 1'b0;
    wire rx_ready;
    wire cpu_reset;
    wire boot_waiting;
    wire loader_done;
    wire loader_busy;
    wire boot_error;
    wire [31:0] imem_addr;
    wire imem_read;
    wire [127:0] imem_rdata;
    wire imem_ready;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    reg [31:0] program_words[0:WORD_COUNT-1];
    reg [31:0] checksum = 32'h0;
    integer i;

    uart_packet_boot_imem #(
        .MEMORY_WORD_COUNT(128)
    ) boot_imem (
        .clock(clock),
        .external_reset(external_reset),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_ready(rx_ready),
        .cpu_reset(cpu_reset),
        .boot_waiting(boot_waiting),
        .loader_done(loader_done),
        .loader_busy(loader_busy),
        .boot_error(boot_error),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(imem_rdata),
        .imem_ready(imem_ready)
    );

    RISCVCPU #(
        .MEMORY_WORD_COUNT(128),
        .USE_EXTERNAL_IMEM(1)
    ) cpu (
        .clock(clock),
        .reset(cpu_reset),
        .imem_addr(imem_addr),
        .imem_read(imem_read),
        .imem_rdata(imem_rdata),
        .imem_ready(imem_ready),
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
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(),
        .perf_matvec_start_count(),
        .perf_matvec_done_count(),
        .perf_matvec_busy_cycle_count()
    );

    always #5 clock = ~clock;

    task send_byte;
        input [7:0] value;
        begin
            if (rx_ready !== 1'b1) begin
                $display("FAIL: packet boot loader was not ready for byte %h", value);
                $fatal;
            end
            @(negedge clock);
            rx_data = value;
            rx_valid = 1'b1;
            @(posedge clock);
            #1;
            rx_valid = 1'b0;
        end
    endtask

    task send_word;
        input [31:0] value;
        begin
            send_byte(value[7:0]);
            send_byte(value[15:8]);
            send_byte(value[23:16]);
            send_byte(value[31:24]);
        end
    endtask

    task wait_for_loader_done;
        integer cycles;
        begin
            cycles = 0;
            while (!loader_done && !boot_error && cycles < 256) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end
            if (!loader_done || boot_error) begin
                $display("FAIL: loader did not complete tail cleanup done=%b error=%b", loader_done, boot_error);
                $fatal;
            end
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_uart_packet_boot_imem.vcd");
        $dumpvars(0, tb_uart_packet_boot_imem);
        $readmemh("firmware/hex/showcase/board_smoke.hex", program_words, 0, WORD_COUNT - 1);

        checksum = 32'h0;
        for (i = 0; i < WORD_COUNT; i = i + 1) begin
            checksum = checksum + program_words[i];
        end

        external_reset = 1'b1;
        repeat (3) @(posedge clock);
        #1;
        external_reset = 1'b0;

        if (cpu_reset !== 1'b1 || boot_waiting !== 1'b1 || loader_done !== 1'b0 || boot_error !== 1'b0) begin
            $display("FAIL: CPU should wait in reset before valid packet");
            $fatal;
        end

        send_word(MAGIC_WORD);
        send_word(VERSION_WORD);
        send_word(START_WORD_ADDR);
        send_word(WORD_COUNT);
        send_word(checksum);
        for (i = 0; i < WORD_COUNT; i = i + 1) begin
            send_word(program_words[i]);
        end

        wait_for_loader_done();
        if (loader_done !== 1'b1 || boot_waiting !== 1'b0 || cpu_reset !== 1'b0 || boot_error !== 1'b0) begin
            $display("FAIL: valid packet should release CPU reset done=%b waiting=%b reset=%b error=%b",
                     loader_done, boot_waiting, cpu_reset, boot_error);
            $fatal;
        end
        if (loader_busy !== 1'b0 || rx_ready !== 1'b0) begin
            $display("FAIL: packet loader should stop accepting bytes after done");
            $fatal;
        end
        force imem_addr = WORD_COUNT * 4;
        #1;
        if (imem_rdata[32*(WORD_COUNT % 4) +: 32] !== 32'h0000_0013) begin
            $display("FAIL: successful packet did not clear the first unused IMEM word");
            $fatal;
        end
        force imem_addr = 32'd508;
        #1;
        if (imem_rdata[127:96] !== 32'h0000_0013) begin
            $display("FAIL: successful packet did not clear the last IMEM word");
            $fatal;
        end

        force imem_addr = 32'h0000_1000;
        force imem_read = 1'b1;
        #1;
        if (imem_rdata !== {4{32'h0000_0013}} || imem_ready !== 1'b1) begin
            $display("FAIL: out-of-range packet IMEM read did not return NOPs");
            $fatal;
        end
        release imem_read;
        release imem_addr;

        repeat (280) @(posedge clock);
        #1;

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: expected debug_status 600dcafe, got %h", debug_status);
            $fatal;
        end
        if (debug_pc !== 32'd24) begin
            $display("FAIL: expected debug_pc 24, got %0d", debug_pc);
            $fatal;
        end

        $display("PASS: packetized UART boot IMEM loaded board smoke and released CPU");
        $display("PASS: tb_uart_packet_boot_imem passed");
        $finish;
    end

endmodule
