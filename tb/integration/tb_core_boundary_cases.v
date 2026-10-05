`timescale 1ns / 1ps

// Consecutive UART stores and partial final cache-line writeback, with real handshakes.
module core_boundary_case #(
    parameter CACHED = 0,
    parameter MEMORY_WORDS = 128,
    parameter UART_CASE = 1
)(output reg done = 0);
    reg clock = 0;
    reg reset = 1;
    wire [7:0] tx_data;
    wire tx_valid, tx_ready, config_error;
    integer accepted = 0;
    localparam LAST_WORD = MEMORY_WORDS - 1;
    always #5 clock = ~clock;

    RISCVCPU #(.MEMORY_WORD_COUNT(MEMORY_WORDS), .ENABLE_ICACHE(CACHED)) dut (
        .clock(clock), .reset(reset), .imem_rdata(128'b0), .imem_ready(1'b0),
        .dmem_rdata(128'b0), .dmem_ready(1'b0), .gpio_inputs(32'b0),
        .uart_tx_data(tx_data), .uart_tx_valid(tx_valid), .uart_tx_ready(tx_ready),
        .uart_rx_data(8'b0), .uart_rx_valid(1'b0), .uart_rx_overrun(1'b0),
        .config_error(config_error)
    );
    uart_tx #(.CLKS_PER_BIT(4)) transmitter (
        .clock(clock), .reset(reset), .data_in(tx_data), .valid(tx_valid),
        .ready(tx_ready), .tx(), .busy()
    );
    always @(posedge clock) begin
        if (!reset && tx_valid && tx_ready) begin
            if (accepted >= 2 || tx_data !== (8'h41 + accepted))
                $fatal(1, "UART cache=%0d byte %0d: got %h", CACHED, accepted, tx_data);
            accepted = accepted + 1;
        end
    end
    initial begin
        #1; // Run after the DUT's memory initialization.
        if (UART_CASE) begin
            dut.IMemory[0] = 32'h30000093; // addi x1,x0,0x300
            dut.IMemory[1] = 32'h04100113; // addi x2,x0,'A'
            dut.IMemory[2] = 32'h04200193; // addi x3,x0,'B'
            dut.IMemory[3] = 32'h00000013;
            dut.IMemory[4] = 32'h0020a023; // adjacent stores in one I-cache line
            dut.IMemory[5] = 32'h0030a023;
            dut.IMemory[6] = 32'h0000006f;
        end else begin
            dut.IMemory[0] = ((LAST_WORD * 4) << 20) | 32'h00000093;
            dut.IMemory[1] = 32'h02a00113; // addi x2,x0,42
            dut.IMemory[2] = 32'h0020a023; // sw x2,0(x1)
            dut.IMemory[3] = 32'h00002203; // conflict miss evicts the partial last line
            dut.IMemory[4] = 32'h0000a183; // reload last legal word
            dut.IMemory[5] = 32'h0000006f;
        end
        repeat (4) @(negedge clock);
        reset = 0;
        repeat (250) @(negedge clock);
        if (config_error !== 0) $fatal(1, "Legal memory configuration was rejected");
        if (UART_CASE) begin
            if (accepted != 2) $fatal(1, "UART cache=%0d accepted %0d bytes", CACHED, accepted);
        end else if (dut.Regs[3] !== 42 || dut.DMemory[LAST_WORD] !== 42) begin
            $fatal(1, "Memory=%0d lost final-word writeback", MEMORY_WORDS);
        end
        done = 1;
    end
endmodule

module tb_core_boundary_cases;
    wire [4:0] done;
    core_boundary_case #(.CACHED(0)) uart_uncached(done[0]);
    core_boundary_case #(.CACHED(1)) uart_cached(done[1]);
    core_boundary_case #(.UART_CASE(0), .MEMORY_WORDS(65)) memory65(done[2]);
    core_boundary_case #(.UART_CASE(0), .MEMORY_WORDS(66)) memory66(done[3]);
    core_boundary_case #(.UART_CASE(0), .MEMORY_WORDS(67)) memory67(done[4]);
    initial begin
        $dumpfile("results/waveforms/tb_core_boundary_cases.vcd");
        $dumpvars(0, tb_core_boundary_cases);
        wait (&done);
        $display("PASS: tb_core_boundary_cases (2 UART modes, 3 partial memory sizes)");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "Core boundary tests timed out");
    end
endmodule
