`timescale 1ns / 1ps

// Testbench: tb_program_debug_status_victim_store
// Purpose: Runs CPU firmware with a four-line D-cache victim buffer to check the public debug_status mirror.
// Checks: A store to the debug_status word that completes through a victim-buffer hit updates debug_status; a
//   monitor requires that store to complete through the victim path.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/soc_io/debug_status_victim_store.hex

module tb_program_debug_status_victim_store;

    localparam [31:0] PASS_MARKER = 32'hc5e3_7c40;
    localparam integer TIMEOUT_CYCLES = 2000;

    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/soc_io/debug_status_victim_store.hex"),
        .INIT_PROGRAM_WORD_COUNT(10),
        .DCACHE_VICTIM_LINES(4)
    ) dut (
        .clock(clock), .reset(reset),
        .imem_rdata(128'h0), .imem_ready(1'b0),
        .dmem_rdata(128'h0), .dmem_ready(1'b0),
        .gpio_inputs(32'h0), .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00), .uart_rx_valid(1'b0), .uart_rx_overrun(1'b0),
        .debug_status(debug_status), .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    // Require the debug_status store itself to complete as a victim hit, so
    // the test cannot silently fall back to the primary hit or refill path.
    reg victim_store_seen = 1'b0;
    always @(negedge clock) begin
        if (!reset && dut.gen_dcache.dcache.victim_complete &&
            dut.EXMEMStoreValid && ({dut.EXMEMALUOut[31:2], 2'b00} == 32'h0000_0100))
            victim_store_seen <= 1'b1;
    end

    integer cycles;

    initial begin
        $dumpfile("results/waveforms/tb_program_debug_status_victim_store.vcd");
        $dumpvars(0, tb_program_debug_status_victim_store);

        @(posedge clock);
        #1;
        reset = 1'b0;
        cycles = 0;
        while (cycles < TIMEOUT_CYCLES && debug_status !== PASS_MARKER) begin
            @(posedge clock);
            #1;
            cycles = cycles + 1;
        end

        if (!victim_store_seen) begin
            $display("FAIL: the debug_status store never completed through the victim buffer");
            $fatal;
        end
        if (debug_status !== PASS_MARKER)
            $fatal(1, "FAIL: debug_status=%h after a victim-hit store; expected %h", debug_status, PASS_MARKER);

        $display("PASS: tb_program_debug_status_victim_store passed");
        $finish;
    end

endmodule
