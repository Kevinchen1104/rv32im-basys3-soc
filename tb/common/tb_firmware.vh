// Shared harness for firmware tests that report PASS/FAIL through debug_status.
// The including module supplies PROGRAM_HEX, PROGRAM_WORD_COUNT, PASS_MARKER,
// FAIL_MARKER and TIMEOUT_CYCLES; test-specific checks stay in that module.
reg clock = 0;
reg reset = 1;
wire [31:0] debug_status;
wire [31:0] debug_pc;

RISCVCPU #(
    .INIT_PROGRAM_HEX(PROGRAM_HEX),
    .INIT_PROGRAM_WORD_COUNT(PROGRAM_WORD_COUNT)
) dut (
    .clock(clock), .reset(reset),
    .imem_rdata(128'h0), .imem_ready(1'b0),
    .dmem_rdata(128'h0), .dmem_ready(1'b0),
    .gpio_inputs(32'h0), .uart_tx_ready(1'b1),
    .uart_rx_data(8'h00), .uart_rx_valid(1'b0), .uart_rx_overrun(1'b0),
    .debug_status(debug_status), .debug_pc(debug_pc)
);

always #5 clock = ~clock;

task run_firmware;
    integer cycles;
    begin
        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;
        cycles = 0;
        while (cycles < TIMEOUT_CYCLES &&
               debug_status !== PASS_MARKER && debug_status !== FAIL_MARKER) begin
            @(posedge clock);
            #1;
            cycles = cycles + 1;
        end
        if (debug_status === FAIL_MARKER)
            $fatal(1, "%0s reported failure %h at pc=%h", PROGRAM_HEX, debug_status, debug_pc);
        if (debug_status !== PASS_MARKER)
            $fatal(1, "%0s timed out after %0d cycles; status=%h pc=%h",
                   PROGRAM_HEX, cycles, debug_status, debug_pc);
    end
endtask
