`timescale 1ns / 1ps

// An uncached CPU must wait for DMA ownership before completing a RAM access.
// Use real instructions; a premature store corrupts a matrix row not yet read.
module uncached_dma_case #(
    parameter ICACHE_ENABLED = 1,
    parameter PARALLEL_LOOKUP = 1
)(output reg done = 0);
    reg clock = 0;
    reg reset = 1;
    integer scenario, cycle, word_index;
    integer blocked_cycles, completions, retirements;

    RISCVCPU #(
        .ENABLE_DCACHE(0),
        .ENABLE_ICACHE(ICACHE_ENABLED),
        .ICACHE_PARALLEL_LOOKUP(PARALLEL_LOOKUP)
    ) dut (
        .clock(clock), .reset(reset),
        .imem_rdata(128'b0), .imem_ready(1'b0),
        .dmem_rdata(128'b0), .dmem_ready(1'b0),
        .gpio_inputs(32'b0), .uart_tx_ready(1'b1),
        .uart_rx_data(8'b0), .uart_rx_valid(1'b0), .uart_rx_overrun(1'b0)
    );
    always #5 clock = ~clock;

    function [31:0] addi;
        input [11:0] immediate;
        input [4:0] rs1, rd;
        addi = {immediate, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function [31:0] store_word;
        input [11:0] immediate;
        input [4:0] rs1, rs2;
        store_word = {immediate[11:5], rs2, rs1, 3'b010,
                      immediate[4:0], 7'b0100011};
    endfunction

    initial begin
        for (scenario = 0; scenario < 3; scenario = scenario + 1) begin
            reset = 1;
            repeat (2) @(posedge clock);
            @(negedge clock);
            for (word_index = 0; word_index < 1024; word_index = word_index + 1) begin
                dut.IMemory[word_index] = 32'h00000013;
                dut.DMemory[word_index] = 0;
            end
            dut.DMemory[16] = 32'h01010101;
            for (word_index = 20; word_index < 24; word_index = word_index + 1)
                dut.DMemory[word_index] = 32'h01010101;

            dut.IMemory[0] = 32'h000010b7;             // lui x1, 1
            dut.IMemory[1] = addi(12'h900, 1, 1);     // DMA registers at 0x900
            dut.IMemory[2] = addi(12'h040, 0, 2);     // vector
            dut.IMemory[3] = store_word(0, 1, 2);
            dut.IMemory[4] = addi(12'h050, 0, 2);     // matrix
            dut.IMemory[5] = store_word(4, 1, 2);
            dut.IMemory[6] = addi(12'h080, 0, 2);     // output
            dut.IMemory[7] = store_word(8, 1, 2);
            dut.IMemory[8] = addi(4, 0, 2);          // four rows
            dut.IMemory[9] = store_word(12, 1, 2);
            dut.IMemory[10] = addi(77, 0, 3);
            dut.IMemory[11] = addi(1, 0, 2);
            dut.IMemory[12] = store_word(16, 1, 2);  // start DMA
            case (scenario)
                0: dut.IMemory[13] = store_word(12'h05c, 0, 3);
                1: dut.IMemory[13] = 32'h08002203;   // lw x4, 128(x0)
                2: dut.IMemory[13] = store_word(12'h100, 0, 3);
            endcase
            dut.IMemory[14] = 32'h00000063;          // hold endpoint
            blocked_cycles = 0;
            completions = 0;
            retirements = 0;
            reset = 0;

            for (cycle = 0; cycle < 180; cycle = cycle + 1) begin
                @(posedge clock);
                if (dut.matvec_dma_cpu_memory_stall) begin
                    blocked_cycles = blocked_cycles + 1;
                    if (dut.dcache_request_complete || dut.dcache_load_word_valid ||
                        dut.retire_event || dut.debug_status_store_commit)
                        $fatal(1, "Uncached memory operation completed during DMA ownership");
                end
                if (dut.EXMEMValid && dut.EXMEMPC == 52 && dut.dcache_request_complete)
                    completions = completions + 1;
                if (dut.trace_valid && dut.trace_pc == 52)
                    retirements = retirements + 1;
                #1;
                if (dut.matvec_dma_busy &&
                    (dut.DMemory[23] !== 32'h01010101 || dut.DebugStatus !== 0))
                    $fatal(1, "Uncached store changed state before DMA released memory");
            end

            if (blocked_cycles == 0 || completions != 1 || retirements != 1)
                $fatal(1, "Missing stall or duplicated completion: scenario=%0d blocked=%0d complete=%0d retire=%0d",
                       scenario, blocked_cycles, completions, retirements);
            for (word_index = 32; word_index < 36; word_index = word_index + 1)
                if (dut.DMemory[word_index] !== 4)
                    $fatal(1, "CPU store corrupted DMA output row %0d", word_index - 32);
            if (scenario == 0 && dut.DMemory[23] !== 77)
                $fatal(1, "Delayed CPU RAM store did not complete");
            if (scenario == 1 && dut.Regs[4] !== 4)
                $fatal(1, "Delayed CPU load did not see DMA output");
            if (scenario == 2 && (dut.DebugStatus !== 77 || dut.DMemory[64] !== 77))
                $fatal(1, "Delayed debug-status store did not complete");
            @(negedge clock);
        end
        $display("PASS: uncached DMA arbitration, I-cache enabled=%0d parallel=%0d",
                 ICACHE_ENABLED, PARALLEL_LOOKUP);
        done = 1;
    end
endmodule

module tb_assert_uncached_dma_arbitration;
    wire [2:0] done;
    uncached_dma_case #(0, 1) no_icache(done[0]);
    uncached_dma_case #(1, 1) parallel_icache(done[1]);
    uncached_dma_case #(1, 0) indexed_icache(done[2]);
    initial begin
        $dumpfile("results/waveforms/tb_assert_uncached_dma_arbitration.vcd");
        $dumpvars(0, tb_assert_uncached_dma_arbitration);
        wait (&done);
        $display("PASS: tb_assert_uncached_dma_arbitration passed");
        $finish;
    end
    initial begin
        #30000;
        $fatal(1, "Uncached DMA arbitration test timed out");
    end
endmodule
