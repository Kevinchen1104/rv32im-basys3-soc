`timescale 1ns / 1ps

// Checks: Runs a reusable simulation assertion monitor across generated hazard, generated call/return, and directed
//   trap/mret scenarios to check x0 stability, PC alignment, valid-gated commit and side effects, trace commit
//   consistency, reset cleanup, and bounded wrong-path poison safety.

module tb_pipeline_invariants;

    localparam NOP = 32'h00000013;
    localparam HAZARD_PROGRAM_WORDS = 45;
    localparam CALL_PROGRAM_WORDS = 54;
    localparam TRAP_PROGRAM_WORDS = 15;
    localparam INITIAL_DMEM_WORD_COUNT = 128;

    reg clock = 0;
    reg reset = 1;
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
    wire trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] trace_instruction;
    wire [4:0] trace_rd;
    wire trace_reg_write;
    wire [31:0] trace_writeback_value;

    integer i;

    RISCVCPU dut (
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
        .trace_valid(trace_valid),
        .trace_pc(trace_pc),
        .trace_instruction(trace_instruction),
        .trace_rd(trace_rd),
        .trace_reg_write(trace_reg_write),
        .trace_writeback_value(trace_writeback_value),
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

`include "tb_pipeline_invariants.vh"

    task reset_and_clear_cpu;
        begin
            #1;
            for (i = 0; i < 1024; i = i + 1) begin
                dut.IMemory[i] = NOP;
                dut.DMemory[i] = 32'h0;
            end

            reset = 1'b1;
            repeat (2) @(posedge clock);
            @(negedge clock);
            reset = 1'b0;
        end
    endtask

    task run_cycles;
        input integer count;
        begin
            repeat (count) @(posedge clock);
            #1;
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_pipeline_invariants.vcd");
        $dumpvars(0, tb_pipeline_invariants);

        reset_and_clear_cpu();
        $readmemh("fixtures/generated/reference/random_hazard_reference.hex", dut.IMemory, 0, HAZARD_PROGRAM_WORDS - 1);
        $readmemh("fixtures/generated/reference/random_hazard_reference_dmem_init.hex", dut.DMemory, 0, INITIAL_DMEM_WORD_COUNT - 1);
        run_cycles(900);
        if (dut.Regs[30] !== 32'h0000_07ab) begin
            $display("FAIL: pipeline invariant hazard scenario completion marker expected 000007ab, got %h",
                     dut.Regs[30]);
            $fatal;
        end

        reset_and_clear_cpu();
        $readmemh("fixtures/generated/reference/random_call_reference.hex", dut.IMemory, 0, CALL_PROGRAM_WORDS - 1);
        $readmemh("fixtures/generated/reference/random_call_reference_dmem_init.hex", dut.DMemory, 0, INITIAL_DMEM_WORD_COUNT - 1);
        run_cycles(900);
        if (dut.Regs[30] !== 32'h0000_07ac) begin
            $display("FAIL: pipeline invariant call scenario completion marker expected 000007ac, got %h",
                     dut.Regs[30]);
            $fatal;
        end
        if (dut.RASCount !== 4'd0) begin
            $display("FAIL: pipeline invariant call scenario expected final RASCount 0, got %0d", dut.RASCount);
            $fatal;
        end

        reset_and_clear_cpu();
        $readmemh("fixtures/generated/reference/trace_trap_reference.hex", dut.IMemory, 0, TRAP_PROGRAM_WORDS - 1);
        run_cycles(260);
        if (dut.Regs[30] !== 32'h0000_07ad) begin
            $display("FAIL: pipeline invariant trap scenario completion marker expected 000007ad, got %h",
                     dut.Regs[30]);
            $fatal;
        end

        $display("PASS: pipeline invariants held across monitored scenario");
        $display("PASS: tb_pipeline_invariants passed");
        $finish;
    end

endmodule
