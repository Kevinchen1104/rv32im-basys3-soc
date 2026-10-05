`timescale 1ns / 1ps

// Testbench: tb_perf_counters
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Performance counters reset and count runtime events on a directed workload.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_perf_counters;

    reg clock = 0;
    reg reset = 1;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire [31:0] perf_cycle_count;
    wire [31:0] perf_retired_count;
    wire [31:0] perf_branch_miss_count;
    wire [31:0] perf_icache_miss_count;
    wire [31:0] perf_dcache_miss_count;
    wire [31:0] perf_stall_cycle_count;

    RISCVCPU dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(),
        .dmem_read(),
        .dmem_write(),
        .dmem_wdata(),
        .dmem_byte_enable(),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_rx_ready(),
        .debug_status(debug_status),
        .debug_pc(debug_pc),
        .trace_valid(),
        .trace_pc(),
        .trace_instruction(),
        .trace_rd(),
        .trace_reg_write(),
        .trace_writeback_value(),
        .perf_cycle_count(perf_cycle_count),
        .perf_retired_count(perf_retired_count),
        .perf_branch_miss_count(perf_branch_miss_count),
        .perf_icache_miss_count(perf_icache_miss_count),
        .perf_dcache_miss_count(perf_dcache_miss_count),
        .perf_stall_cycle_count(perf_stall_cycle_count)
    );

    always #5 clock = ~clock;

    function [31:0] i_type;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            i_type = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] s_type;
        input [11:0] imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            s_type = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
        end
    endfunction

    function [31:0] b_type;
        input integer imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        reg [12:0] bimm;
        begin
            bimm = imm[12:0];
            b_type = {bimm[12], bimm[10:5], rs2, rs1, funct3, bimm[4:1], bimm[11], opcode};
        end
    endfunction

    initial begin
        $dumpfile("results/waveforms/tb_perf_counters.vcd");
        $dumpvars(0, tb_perf_counters);
        #1; // Initialize test memory after the DUT initial block.

        dut.IMemory[0] = i_type(12'd1, 5'd0, 3'b000, 5'd1, 7'h13); // addi x1, x0, 1
        dut.IMemory[1] = b_type(12, 5'd1, 5'd1, 3'b000, 7'h63);    // beq x1, x1, target
        dut.IMemory[2] = i_type(12'd2, 5'd0, 3'b000, 5'd2, 7'h13); // wrong path
        dut.IMemory[3] = i_type(12'd3, 5'd0, 3'b000, 5'd2, 7'h13); // wrong path
        dut.IMemory[4] = s_type(12'd0, 5'd1, 5'd0, 3'b010, 7'h23); // target: sw x1, 0(x0)
        dut.IMemory[5] = i_type(12'd0, 5'd0, 3'b010, 5'd3, 7'h03); // lw x3, 0(x0)

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;

        if (perf_cycle_count !== 32'd0 ||
            perf_retired_count !== 32'd0 ||
            perf_branch_miss_count !== 32'd0 ||
            perf_icache_miss_count !== 32'd0 ||
            perf_dcache_miss_count !== 32'd0 ||
            perf_stall_cycle_count !== 32'd0) begin
            $display("FAIL: performance counters should reset to zero");
            $fatal;
        end

        reset = 1'b0;
        repeat (120) @(posedge clock);
        #1;

        if (^{perf_cycle_count, perf_retired_count, perf_branch_miss_count,
              perf_icache_miss_count, perf_dcache_miss_count, perf_stall_cycle_count} === 1'bx)
            $fatal(1, "performance counter contains an unknown value");

        if (perf_cycle_count !== 32'd120) begin
            $display("FAIL: expected cycle count 120, got %0d", perf_cycle_count);
            $fatal;
        end

        if (perf_retired_count < 32'd5) begin
            $display("FAIL: expected at least 5 retired instructions, got %0d", perf_retired_count);
            $fatal;
        end

        if (perf_branch_miss_count < 32'd1) begin
            $display("FAIL: expected at least one branch miss, got %0d", perf_branch_miss_count);
            $fatal;
        end

        if (perf_icache_miss_count < 32'd1) begin
            $display("FAIL: expected at least one I-cache miss, got %0d", perf_icache_miss_count);
            $fatal;
        end

        if (perf_dcache_miss_count < 32'd1) begin
            $display("FAIL: expected at least one D-cache miss, got %0d", perf_dcache_miss_count);
            $fatal;
        end

        if (perf_stall_cycle_count < 32'd1) begin
            $display("FAIL: expected at least one stall cycle, got %0d", perf_stall_cycle_count);
            $fatal;
        end

        $display("INFO: perf counters cycles=%0d retired=%0d branch_miss=%0d icache_miss=%0d dcache_miss=%0d stall_cycles=%0d",
                 perf_cycle_count,
                 perf_retired_count,
                 perf_branch_miss_count,
                 perf_icache_miss_count,
                 perf_dcache_miss_count,
                 perf_stall_cycle_count);
        $display("PASS: performance counters reset and counted runtime events");
        $display("PASS: tb_perf_counters passed");
        $finish;
    end

endmodule
