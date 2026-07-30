`timescale 1ns / 1ps

// Testbench: tb_program_machine_timer_no_interrupt
// Purpose: Runs CPU firmware to exercise the selected machine-mode CSR/trap subset.
// Checks: CPU software lets the machine timer become pending while mie.MTIE remains disabled, observes MTIP by
//   polling, proves the handler does not run within a bounded loop, and exposes a public debug_status pass/fail
//   signature.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
//   priority, nesting, or pending-source combination.
// Firmware: firmware/hex/csr_trap/machine_timer_no_interrupt.hex

module tb_program_machine_timer_no_interrupt;

    reg clock = 0;
    reg reset = 0;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] gpio_outputs;
    wire [31:0] gpio_inputs = 32'h0;
    wire [7:0] uart_tx_data;
    wire uart_tx_valid;
    wire uart_tx_ready = 1'b1;
    wire [7:0] uart_rx_data = 8'h00;
    wire uart_rx_valid = 1'b0;
    wire uart_rx_ready;
    wire [31:0] imem_addr;
    wire imem_read;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;

    localparam [31:0] PASS_MARKER = 32'h71ce_8000;
    localparam [31:0] FAIL_MARKER = 32'hbad0_8000;
    localparam integer TIMEOUT_CYCLES = 5000;

    RISCVCPU #(
        .INIT_PROGRAM_HEX("firmware/hex/csr_trap/machine_timer_no_interrupt.hex"),
        .INIT_PROGRAM_WORD_COUNT(51)
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
        .uart_tx_data(uart_tx_data),
        .uart_tx_valid(uart_tx_valid),
        .uart_tx_ready(uart_tx_ready),
        .uart_rx_data(uart_rx_data),
        .uart_rx_valid(uart_rx_valid),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready(uart_rx_ready)
    );

    always #5 clock = ~clock;

    integer cycle;

    initial begin
        $dumpfile("wave/tb_program_machine_timer_no_interrupt.vcd");
        $dumpvars(0, tb_program_machine_timer_no_interrupt);

        reset = 1'b1;
        @(posedge clock);
        #1;
        reset = 1'b0;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;
            if (debug_status === PASS_MARKER || debug_status === FAIL_MARKER) begin
                cycle = TIMEOUT_CYCLES;
            end
        end

        if (debug_status === FAIL_MARKER) begin
            $display("FAIL: machine_timer_no_interrupt stored fail marker %h", debug_status);
            $fatal;
        end

        if (debug_status !== PASS_MARKER) begin
            $display("FAIL: timed out waiting for no-interrupt pass marker, debug_status=%h debug_pc=%h", debug_status, debug_pc);
            $fatal;
        end

        if (dut.CSRmip[7] !== 1'b1) begin
            $display("FAIL: timer should be pending while source is masked, mip=%h", dut.CSRmip);
            $fatal;
        end

        if (dut.CSRmie[7] !== 1'b0) begin
            $display("FAIL: MTIE should remain disabled in no-interrupt test, mie=%h", dut.CSRmie);
            $fatal;
        end

        if (dut.CSRmcause === 32'h8000_0007 || dut.Regs[9] !== 32'h0) begin
            $display("FAIL: unexpected timer handler state mcause=%h s1=%h", dut.CSRmcause, dut.Regs[9]);
            $fatal;
        end

        $display("PASS: tb_program_machine_timer_no_interrupt passed");
        $finish;
    end
endmodule
