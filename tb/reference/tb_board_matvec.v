`timescale 1ns / 1ps

// Run the board firmware with external DMEM and a byte-level UART sink.
module tb_board_matvec;
    reg clock = 0;
    reg reset = 1;
    wire [31:0] address, status;
    wire read_request, write_request, ready;
    wire [127:0] write_data, read_data;
    wire [15:0] byte_enable;
    wire [7:0] uart_data;
    wire uart_valid;
    reg [2047:0] image_path, output_path;
    integer file_handle;
    integer elapsed = 0;

    RISCVCPU #(.MEMORY_WORD_COUNT(1024), .USE_EXTERNAL_DMEM(1)) dut (
        .clock(clock), .reset(reset),
        .imem_rdata(128'b0), .imem_ready(1'b0),
        .dmem_addr(address), .dmem_read(read_request), .dmem_write(write_request),
        .dmem_wdata(write_data), .dmem_byte_enable(byte_enable),
        .dmem_rdata(read_data), .dmem_ready(ready),
        .gpio_inputs(32'b0), .uart_tx_ready(1'b1), .uart_rx_data(8'b0),
        .uart_rx_valid(1'b0), .uart_rx_overrun(1'b0),
        .uart_tx_data(uart_data), .uart_tx_valid(uart_valid), .debug_status(status)
    );
    external_dmem_bram #(.WORD_COUNT(1024)) memory (
        .clock(clock), .reset(reset), .dmem_addr(address),
        .dmem_read(read_request), .dmem_write(write_request), .dmem_wdata(write_data),
        .dmem_byte_enable(byte_enable), .dmem_rdata(read_data), .dmem_ready(ready)
    );
    always #5 clock = ~clock;
    initial begin
        if (!$value$plusargs("image=%s", image_path) ||
            !$value$plusargs("output=%s", output_path)) $fatal(1, "missing board firmware paths");
        file_handle = $fopen(output_path, "w");
        if (!file_handle) $fatal(1, "cannot open UART transcript");
        #1;
        $readmemh(image_path, dut.IMemory, 0, 1023);
        repeat (3) @(negedge clock);
        reset = 0;
    end
    always @(posedge clock) begin
        if (!reset) begin
            if (uart_valid) $fwrite(file_handle, "%c", uart_data);
            elapsed = elapsed + 1;
            if (status == 32'h600dcafe) begin
                $fclose(file_handle);
                $display("PASS: board firmware finished in %0d simulated clocks", elapsed);
                $finish;
            end
            if (elapsed >= 2000000) $fatal(1, "board firmware timeout");
        end
    end
endmodule
