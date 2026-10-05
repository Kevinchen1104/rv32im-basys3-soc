`timescale 1ns / 1ps

// Measure retired-marker intervals; save cache-visible RAM for the host oracle.
module tb_matvec_benchmark;
    reg clock = 0;
    reg reset = 1;
    wire trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] cycles, retired, stalls, icache_misses, dcache_misses;
    reg [2047:0] image_path, memory_path;
    reg [31:0] begin_pc, end_pc, done_pc;
    reg measuring = 0;
    reg completed = 0;
    reg previous_sp_busy = 0;
    reg previous_dma_busy = 0;
    integer starts = 0;
    integer start_cycles, start_retired, start_stalls, start_icache, start_dcache;
    integer start_elapsed;
    integer busy_cycles = 0;
    integer arithmetic_cycles = 0;
    integer elapsed = 0;
    integer memory_file, address, cache_index;
    reg [31:0] memory_word;

    RISCVCPU #(.MEMORY_WORD_COUNT(4096)) dut (
        .clock(clock), .reset(reset),
        .imem_addr(), .imem_read(), .imem_rdata(128'b0), .imem_ready(1'b0),
        .dmem_addr(), .dmem_read(), .dmem_write(), .dmem_wdata(),
        .dmem_byte_enable(), .dmem_rdata(128'b0), .dmem_ready(1'b0),
        .gpio_inputs(32'b0), .gpio_outputs(),
        .uart_tx_ready(1'b1), .uart_rx_data(8'b0), .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0), .uart_tx_data(), .uart_tx_valid(), .uart_rx_ready(),
        .config_error(), .debug_status(), .debug_pc(),
        .trace_valid(trace_valid), .trace_pc(trace_pc), .trace_instruction(),
        .trace_rd(), .trace_reg_write(), .trace_writeback_value(),
        .perf_cycle_count(cycles), .perf_retired_count(retired),
        .perf_stall_cycle_count(stalls), .perf_icache_miss_count(icache_misses),
        .perf_dcache_miss_count(dcache_misses), .perf_branch_miss_count(),
        .perf_matvec_start_count(), .perf_matvec_done_count(), .perf_matvec_busy_cycle_count()
    );
    always #5 clock = ~clock;

    initial begin
        if (!$value$plusargs("image=%s", image_path) ||
            !$value$plusargs("memory=%s", memory_path) ||
            !$value$plusargs("begin_pc=%h", begin_pc) ||
            !$value$plusargs("end_pc=%h", end_pc) ||
            !$value$plusargs("done_pc=%h", done_pc)) $fatal(1, "missing benchmark arguments");
        #1;
        $readmemh(image_path, dut.IMemory, 0, 4095);
        $readmemh(image_path, dut.DMemory, 0, 4095);
        repeat (3) @(negedge clock);
        reset = 0;
    end

    always @(posedge clock) begin
        #1;
        if (!reset) begin
            elapsed = elapsed + 1;
            if (trace_valid && trace_pc == begin_pc) begin
                if (measuring || completed) $fatal(1, "repeated begin marker");
                measuring = 1;
                start_cycles = cycles;
                start_elapsed = elapsed;
                start_retired = retired;
                start_stalls = stalls;
                start_icache = icache_misses;
                start_dcache = dcache_misses;
            end
            if (measuring) begin
                if (dut.matvec_busy || dut.matvec_dma_busy) busy_cycles = busy_cycles + 1;
                if ((dut.matvec_busy && !previous_sp_busy) ||
                    (dut.matvec_dma_busy && !previous_dma_busy)) starts = starts + 1;
                if (dut.gen_accelerators.accel_matvec.compute_state == 2 ||
                    dut.gen_accelerators.accel_matvec.compute_state == 3 ||
                    dut.gen_dma_accelerator.accel_matvec_dma.state == 3 ||
                    dut.gen_dma_accelerator.accel_matvec_dma.state == 4)
                    arithmetic_cycles = arithmetic_cycles + 1;
            end
            previous_sp_busy = dut.matvec_busy;
            previous_dma_busy = dut.matvec_dma_busy;
            if (trace_valid && trace_pc == end_pc) begin
                if (!measuring || completed) $fatal(1, "unexpected end marker");
                if (dut.matvec_busy || dut.matvec_dma_busy) $fatal(1, "work still active at end");
                if (cycles-start_cycles != elapsed-start_elapsed) $fatal(1, "cycle counter disagrees with testbench clock");
                measuring = 0;
                completed = 1;
                $display("METRICS cycles=%0d retired=%0d stalls=%0d icache_misses=%0d dcache_misses=%0d busy_cycles=%0d arithmetic_cycles=%0d starts=%0d",
                         cycles-start_cycles, retired-start_retired, stalls-start_stalls,
                         icache_misses-start_icache, dcache_misses-start_dcache,
                         busy_cycles, arithmetic_cycles, starts);
            end
            if (trace_valid && trace_pc == done_pc) begin
                if (!completed) $fatal(1, "program returned before end marker");
                memory_file = $fopen(memory_path, "w");
                if (!memory_file) $fatal(1, "cannot open memory output");
                for (address = 'h3000; address < 'h4000; address = address + 4) begin
                    cache_index = (address >> 4) & 3;
                    memory_word = dut.DMemory[address >> 2];
                    if (dut.gen_dcache.dcache.cache_valid[cache_index] &&
                        dut.gen_dcache.dcache.cache_tag_store[cache_index] == (address >> 6))
                        memory_word = dut.gen_dcache.dcache.cache_data[cache_index][(address >> 2) & 3];
                    $fwrite(memory_file, "%08x\n", memory_word);
                end
                $fclose(memory_file);
                $display("PASS: benchmark interval completed");
                $finish;
            end
            if (elapsed >= 200000) $fatal(1, "benchmark timed out");
        end
    end
endmodule
