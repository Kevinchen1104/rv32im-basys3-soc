`timescale 1ns / 1ps

// Testbench: tb_uart_packet_boot_banks
// Purpose: Checks banked instruction memory through its byte-stream and line-read ports.
// Checks: Every word/lane, partial lines, reload tails, checksum scrubbing, and read bounds.
// Pass condition: All ten capacity cases complete without a mismatch or timeout.

module boot_bank_case #(parameter WORDS = 1) (output reg done = 1'b0);
    localparam NOP = 32'h0000_0013;
    reg clock = 1'b0;
    reg reset = 1'b1;
    reg [7:0] rx_data = 8'h0;
    reg rx_valid = 1'b0;
    wire rx_ready, cpu_reset, loader_done, loader_busy, boot_error;
    reg [31:0] imem_addr = 32'h0;
    reg imem_read = 1'b0;
    wire [127:0] imem_rdata;
    wire imem_ready;

    uart_packet_boot_imem #(.MEMORY_WORD_COUNT(WORDS)) dut (
        .clock(clock), .external_reset(reset),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .cpu_reset(cpu_reset), .boot_waiting(), .loader_done(loader_done),
        .loader_busy(loader_busy), .boot_error(boot_error),
        .imem_addr(imem_addr), .imem_read(imem_read),
        .imem_rdata(imem_rdata), .imem_ready(imem_ready)
    );
    always #5 clock = ~clock;

    function [31:0] pattern;
        input integer index;
        input [31:0] salt;
        begin
            pattern = 32'h6d5a_0000 ^ (index * 32'h0102_0409) ^ salt;
        end
    endfunction

    task reset_loader;
    begin
        @(negedge clock);
        reset = 1'b1;
        rx_valid = 1'b0;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;
        #1;
        if (!cpu_reset || !rx_ready || loader_done || boot_error)
            $fatal(1, "capacity %0d: incorrect reset state", WORDS);
    end
    endtask

    task send_word;
        input [31:0] value;
        integer byte_number;
    begin
        for (byte_number = 0; byte_number < 4; byte_number = byte_number + 1) begin
            @(negedge clock);
            if (!rx_ready)
                $fatal(1, "capacity %0d: loader not ready", WORDS);
            rx_data = value[8*byte_number +: 8];
            rx_valid = 1'b1;
            @(posedge clock);
            #1;
            rx_valid = 1'b0;
        end
    end
    endtask

    task load_image;
        input integer count;
        input [31:0] salt;
        input corrupt_checksum;
        reg [31:0] checksum;
        integer index;
        integer cycles;
    begin
        reset_loader();
        checksum = 32'h0;
        for (index = 0; index < count; index = index + 1)
            checksum = checksum + pattern(index, salt);
        send_word(32'h5256_4254);
        send_word(32'h1);
        send_word(32'h0);
        send_word(count);
        send_word(checksum ^ {31'h0, corrupt_checksum});
        for (index = 0; index < count; index = index + 1)
            send_word(pattern(index, salt));
        cycles = 0;
        while (!loader_done && !boot_error && cycles < WORDS + 4) begin
            @(posedge clock);
            #1;
            cycles = cycles + 1;
        end
        if (loader_done !== !corrupt_checksum || boot_error !== corrupt_checksum ||
            cpu_reset !== corrupt_checksum || loader_busy || rx_ready)
            $fatal(1, "capacity %0d: incorrect packet completion", WORDS);
    end
    endtask

    task check_image;
        input integer count;
        input [31:0] salt;
        integer base;
        integer offset;
        integer lane;
        reg [127:0] expected_line;
    begin
        // Every byte address in a line must return the same aligned four words.
        // The last line may mix valid words and out-of-capacity NOP lanes.
        for (base = 0; base < WORDS + 4; base = base + 4) begin
            for (lane = 0; lane < 4; lane = lane + 1)
                expected_line[32*lane +: 32] =
                    (base + lane < count) ? pattern(base + lane, salt) : NOP;
            for (offset = 0; offset < 16; offset = offset + 1) begin
                imem_addr = base * 4 + offset;
                imem_read = 1'b1;
                #1;
                if (imem_rdata !== expected_line || imem_ready !== loader_done)
                    $fatal(1, "capacity %0d: addr %h expected %h got %h ready=%b",
                           WORDS, imem_addr, expected_line, imem_rdata, imem_ready);
            end
        end
        imem_addr = 32'hffff_ffff;
        #1;
        if (imem_rdata !== {4{NOP}})
            $fatal(1, "capacity %0d: high address aliased into memory", WORDS);
        imem_read = 1'b0;
        #1;
        if (imem_ready)
            $fatal(1, "capacity %0d: ready asserted without read", WORDS);
    end
    endtask

    initial begin
        #1;
        check_image(0, 32'h0);
        load_image(WORDS, 32'h1234_5678, 1'b0);
        check_image(WORDS, 32'h1234_5678);
        load_image((WORDS + 1) / 2, 32'hfedc_ba98, 1'b0);
        check_image((WORDS + 1) / 2, 32'hfedc_ba98);
        load_image(WORDS, 32'h1357_9bdf, 1'b1);
        check_image(0, 32'h0);
        load_image(1, 32'h2468_ace0, 1'b0);
        check_image(1, 32'h2468_ace0);
        done = 1'b1;
        $display("PASS: banked IMEM capacity %0d", WORDS);
    end
endmodule

module tb_uart_packet_boot_banks;
    wire [9:0] done;
    boot_bank_case #(1) c1(done[0]);
    boot_bank_case #(2) c2(done[1]);
    boot_bank_case #(3) c3(done[2]);
    boot_bank_case #(4) c4(done[3]);
    boot_bank_case #(5) c5(done[4]);
    boot_bank_case #(7) c7(done[5]);
    boot_bank_case #(9) c9(done[6]);
    boot_bank_case #(17) c17(done[7]);
    boot_bank_case #(1024) c1024(done[8]);
    boot_bank_case #(1025) c1025(done[9]);
    initial begin
        $dumpfile("results/waveforms/tb_uart_packet_boot_banks.vcd");
        $dumpvars(2, tb_uart_packet_boot_banks);
        wait (&done);
        $display("PASS: tb_uart_packet_boot_banks passed");
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "banked IMEM test timed out");
    end
endmodule
