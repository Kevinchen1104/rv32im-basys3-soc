`timescale 1ns / 1ps

// Testbench: tb_program_access_fault_misaligned_control
// Purpose: Runs CPU firmware from external IMEM to check trap behavior when a control transfer is fetched
//   beyond MEMORY_WORD_COUNT.
// Checks: A JAL with a misaligned target at an out-of-range PC raises exactly one trap, an instruction-access
//   fault with mepc=mtval=0x400, and the handler observes mstatus=0x1880; the testbench also counts accepted
//   trap entries.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/csr_trap/access_fault_misaligned_control.hex

module tb_program_access_fault_misaligned_control;

    localparam [31:0] PASS_MARKER = 32'hc5e3_000a;
    localparam [31:0] FAIL_MARKER = 32'hbad5_000a;
    localparam integer TIMEOUT_CYCLES = 3000;
    localparam integer PROGRAM_WORD_COUNT = 50;
    // jal x0, +6 at byte 0x400, the first word beyond MEMORY_WORD_COUNT=256.
    localparam [31:0] OUT_OF_RANGE_JAL = 32'h0060_006f;

    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] imem_addr;
    wire imem_read;

    // External IMEM larger than the core's bound, so the out-of-range fetch
    // returns a real instruction rather than a NOP.
    reg [31:0] rom [0:511];
    wire [8:0] line_word = {imem_addr[10:4], 2'b00};
    wire [127:0] imem_rdata = {rom[line_word + 3], rom[line_word + 2], rom[line_word + 1], rom[line_word]};
    wire imem_ready = imem_read;

    RISCVCPU #(
        .MEMORY_WORD_COUNT(256),
        .USE_EXTERNAL_IMEM(1)
    ) dut (
        .clock(clock), .reset(reset),
        .imem_addr(imem_addr), .imem_read(imem_read), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
        .dmem_rdata(128'h0), .dmem_ready(1'b0),
        .gpio_inputs(32'h0), .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00), .uart_rx_valid(1'b0), .uart_rx_overrun(1'b0),
        .debug_status(debug_status), .debug_pc(debug_pc)
    );

    always #5 clock = ~clock;

    integer trap_count = 0;
    always @(posedge clock) begin
        if (!reset && dut.trap_taken) trap_count <= trap_count + 1;
    end

    integer i;
    integer cycles;

    initial begin
        $dumpfile("results/waveforms/tb_program_access_fault_misaligned_control.vcd");
        $dumpvars(0, tb_program_access_fault_misaligned_control);

        for (i = 0; i < 512; i = i + 1) rom[i] = 32'h0000_0013;
        $readmemh("firmware/hex/csr_trap/access_fault_misaligned_control.hex", rom, 0, PROGRAM_WORD_COUNT - 1);
        rom[256] = OUT_OF_RANGE_JAL;

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
            $fatal(1, "FAIL: firmware check failed: traps=%0d mcause=%h mepc=%h mtval=%h entry mstatus=%h",
                   dut.DMemory[16], dut.DMemory[17], dut.DMemory[18], dut.DMemory[19], dut.DMemory[20]);
        if (debug_status !== PASS_MARKER)
            $fatal(1, "FAIL: timed out after %0d cycles; status=%h pc=%h", cycles, debug_status, debug_pc);
        if (trap_count !== 1) begin
            $display("FAIL: expected one accepted trap, saw %0d", trap_count);
            $fatal;
        end

        $display("PASS: tb_program_access_fault_misaligned_control passed");
        $finish;
    end

endmodule
