`timescale 1ns / 1ps

// Testbench: tb_uart_packet_boot_reject
// Purpose: Exercises the UART boot/loading path around instruction memory release.
// Checks: Packetized UART boot rejects malformed and zero-length packets, scrubs checksum-failed payloads, supports a clean shorter retry, and elaborates at one-word capacity.
// Pass condition: The boot/load path accepts the expected data and reaches the checked release, status, or rejection
//   condition.

module tb_uart_packet_boot_reject;

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
    reg tiny_external_reset = 1'b0;
    reg [7:0] tiny_rx_data = 8'h00;
    reg tiny_rx_valid = 1'b0;
    wire tiny_rx_ready;
    wire tiny_cpu_reset;
    wire tiny_loader_done;
    wire tiny_loader_busy;
    wire tiny_boot_error;
    wire zero_capacity_rx_ready;
    wire zero_capacity_cpu_reset;
    wire zero_capacity_loader_done;
    wire zero_capacity_loader_busy;
    wire zero_capacity_boot_error;

    uart_packet_boot_imem #(
        .MEMORY_WORD_COUNT(8)
    ) dut (
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
        .imem_addr(32'h0),
        .imem_read(1'b0),
        .imem_rdata(),
        .imem_ready()
    );

    uart_packet_boot_imem #(
        .MEMORY_WORD_COUNT(1)
    ) tiny_dut (
        .clock(clock),
        .external_reset(tiny_external_reset),
        .rx_data(tiny_rx_data),
        .rx_valid(tiny_rx_valid),
        .rx_ready(tiny_rx_ready),
        .cpu_reset(tiny_cpu_reset),
        .boot_waiting(),
        .loader_done(tiny_loader_done),
        .loader_busy(tiny_loader_busy),
        .boot_error(tiny_boot_error),
        .imem_addr(32'h0),
        .imem_read(1'b0),
        .imem_rdata(),
        .imem_ready()
    );

    uart_packet_boot_imem #(
        .MEMORY_WORD_COUNT(0)
    ) zero_capacity_dut (
        .clock(clock),
        .external_reset(external_reset),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_ready(zero_capacity_rx_ready),
        .cpu_reset(zero_capacity_cpu_reset),
        .boot_waiting(),
        .loader_done(zero_capacity_loader_done),
        .loader_busy(zero_capacity_loader_busy),
        .boot_error(zero_capacity_boot_error),
        .imem_addr(32'h0),
        .imem_read(1'b0),
        .imem_rdata(),
        .imem_ready()
    );

    always #5 clock = ~clock;

    task reset_loader;
        begin
            rx_valid = 1'b0;
            rx_data = 8'h00;
            external_reset = 1'b1;
            repeat (3) @(posedge clock);
            #1;
            external_reset = 1'b0;
            @(posedge clock);
            #1;

            if (cpu_reset !== 1'b1 || boot_waiting !== 1'b1 || loader_done !== 1'b0 || boot_error !== 1'b0) begin
                $display("FAIL: loader did not reset to waiting state");
                $fatal;
            end
        end
    endtask

    task send_byte;
        input [7:0] value;
        begin
            if (rx_ready !== 1'b1) begin
                $display("FAIL: loader was not ready for byte %h", value);
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

    task reset_tiny_loader;
        begin
            tiny_rx_valid = 1'b0;
            tiny_rx_data = 8'h00;
            tiny_external_reset = 1'b1;
            repeat (3) @(posedge clock);
            #1;
            tiny_external_reset = 1'b0;
            @(posedge clock);
            #1;
            if (!tiny_cpu_reset || tiny_loader_done || tiny_boot_error ||
                !tiny_loader_busy || !tiny_rx_ready) begin
                $display("FAIL: one-word loader did not reset to waiting state");
                $fatal;
            end
        end
    endtask

    task send_tiny_byte;
        input [7:0] value;
        begin
            if (!tiny_rx_ready) begin
                $display("FAIL: one-word loader was not ready for byte %h", value);
                $fatal;
            end
            @(negedge clock);
            tiny_rx_data = value;
            tiny_rx_valid = 1'b1;
            @(posedge clock);
            #1;
            tiny_rx_valid = 1'b0;
        end
    endtask

    task send_tiny_word;
        input [31:0] value;
        begin
            send_tiny_byte(value[7:0]);
            send_tiny_byte(value[15:8]);
            send_tiny_byte(value[23:16]);
            send_tiny_byte(value[31:24]);
        end
    endtask

    task expect_reject;
        input [255:0] name;
        integer cycles;
        begin
            cycles = 0;
            while (!boot_error && cycles < 32) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end
            if (boot_error !== 1'b1 || loader_done !== 1'b0 || cpu_reset !== 1'b1 ||
                boot_waiting !== 1'b1 || loader_busy !== 1'b0 || rx_ready !== 1'b0) begin
                $display("FAIL: %0s reject state error=%b done=%b reset=%b waiting=%b busy=%b ready=%b",
                         name, boot_error, loader_done, cpu_reset, boot_waiting, loader_busy, rx_ready);
                $fatal;
            end
        end
    endtask

    task wait_for_done;
        integer cycles;
        begin
            cycles = 0;
            while (!loader_done && !boot_error && cycles < 32) begin
                @(posedge clock);
                #1;
                cycles = cycles + 1;
            end
            if (!loader_done || boot_error || cpu_reset || boot_waiting || loader_busy || rx_ready) begin
                $display("FAIL: valid retry did not complete cleanly");
                $fatal;
            end
        end
    endtask

    task check_memory_nops;
        input integer first;
        integer index;
        begin
            for (index = first; index < 8; index = index + 1) begin
                if (dut.memory[index] !== 32'h0000_0013) begin
                    $display("FAIL: memory[%0d] was not scrubbed to NOP: %h", index, dut.memory[index]);
                    $fatal;
                end
            end
        end
    endtask

    initial begin
        $dumpfile("wave/tb_uart_packet_boot_reject.vcd");
        $dumpvars(0, tb_uart_packet_boot_reject);

        reset_loader();
        if (!zero_capacity_cpu_reset || zero_capacity_loader_done ||
            zero_capacity_loader_busy || zero_capacity_rx_ready ||
            !zero_capacity_boot_error) begin
            $display("FAIL: zero-capacity loader did not reject its configuration");
            $fatal;
        end
        send_word(32'h1234_5678);
        expect_reject("bad magic");

        reset_loader();
        send_word(MAGIC_WORD);
        send_word(VERSION_WORD);
        send_word(START_WORD_ADDR);
        send_word(32'd1);
        send_word(32'h0000_0002);
        send_word(32'h0000_0001);
        expect_reject("bad checksum");
        check_memory_nops(0);

        reset_loader();
        send_word(MAGIC_WORD);
        send_word(VERSION_WORD);
        send_word(START_WORD_ADDR);
        send_word(32'd3);
        send_word(32'h6666_6666);
        send_word(32'h1111_1111);

        // Reset aborts the incomplete packet. The next successful shorter
        // packet overwrites its payload and clears every stale tail word before
        // releasing the CPU.
        reset_loader();
        send_word(MAGIC_WORD);
        send_word(VERSION_WORD);
        send_word(START_WORD_ADDR);
        send_word(32'd1);
        send_word(32'h2222_2222);
        send_word(32'h2222_2222);
        wait_for_done();
        if (dut.memory[0] !== 32'h2222_2222) begin
            $display("FAIL: shorter retry did not replace word zero");
            $fatal;
        end
        check_memory_nops(1);

        reset_loader();
        send_word(MAGIC_WORD);
        send_word(VERSION_WORD);
        send_word(START_WORD_ADDR);
        send_word(32'd9);
        expect_reject("word_count too large");

        reset_loader();
        send_word(MAGIC_WORD);
        send_word(VERSION_WORD);
        send_word(START_WORD_ADDR);
        send_word(32'd0);
        expect_reject("zero-length image");

        reset_tiny_loader();
        send_tiny_word(MAGIC_WORD);
        send_tiny_word(VERSION_WORD);
        send_tiny_word(START_WORD_ADDR);
        send_tiny_word(32'd1);
        send_tiny_word(32'h89ab_cdef);
        send_tiny_word(32'h89ab_cdef);
        if (!tiny_loader_done || tiny_boot_error || tiny_cpu_reset ||
            tiny_loader_busy || tiny_rx_ready ||
            (tiny_dut.memory[0] !== 32'h89ab_cdef)) begin
            $display(
                "FAIL: one-word boot contract done=%b error=%b reset=%b busy=%b ready=%b memory=%h",
                tiny_loader_done,
                tiny_boot_error,
                tiny_cpu_reset,
                tiny_loader_busy,
                tiny_rx_ready,
                tiny_dut.memory[0]
            );
            $fatal;
        end

        $display("PASS: packetized UART boot rejected malformed/empty packets and supported one-word capacity");
        $display("PASS: tb_uart_packet_boot_reject passed");
        $finish;
    end

endmodule
