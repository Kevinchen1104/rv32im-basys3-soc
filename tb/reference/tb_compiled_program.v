`timescale 1ns / 1ps

// Executes a GCC image with both caches enabled. The Python driver compares
// retired instructions and the cache-visible data RAM against Unicorn.
module tb_compiled_program;
    localparam MEMORY_WORDS = 4096;
    reg clock = 0;
    reg reset = 1;
    wire trace_valid;
    wire [31:0] trace_pc;
    wire [31:0] trace_instruction;
    wire [4:0] trace_rd;
    wire trace_reg_write;
    wire [31:0] trace_value;
    wire [31:0] cycles;
    wire [31:0] retired;
    wire [31:0] stalls;
    wire [31:0] icache_misses;
    wire [31:0] dcache_misses;
    reg [2047:0] image_path;
    reg [2047:0] trace_path;
    reg [2047:0] memory_path;
    reg [31:0] done_pc;
    integer timeout_cycles;
    integer trace_file;
    integer memory_file;
    integer address;
    integer cache_index;
    reg [31:0] memory_word;
    integer elapsed = 0;

    RISCVCPU #(.MEMORY_WORD_COUNT(MEMORY_WORDS)) dut (
        .clock(clock), .reset(reset),
        .imem_addr(), .imem_read(), .imem_rdata(128'b0), .imem_ready(1'b0),
        .dmem_addr(), .dmem_read(), .dmem_write(), .dmem_wdata(),
        .dmem_byte_enable(), .dmem_rdata(128'b0), .dmem_ready(1'b0),
        .gpio_inputs(32'b0), .gpio_outputs(),
        .uart_tx_ready(1'b1), .uart_rx_data(8'b0), .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0), .uart_tx_data(), .uart_tx_valid(), .uart_rx_ready(),
        .config_error(), .debug_status(), .debug_pc(),
        .trace_valid(trace_valid), .trace_pc(trace_pc),
        .trace_instruction(trace_instruction), .trace_rd(trace_rd),
        .trace_reg_write(trace_reg_write), .trace_writeback_value(trace_value),
        .perf_cycle_count(cycles), .perf_retired_count(retired),
        .perf_stall_cycle_count(stalls), .perf_icache_miss_count(icache_misses),
        .perf_dcache_miss_count(dcache_misses), .perf_branch_miss_count(),
        .perf_matvec_start_count(), .perf_matvec_done_count(), .perf_matvec_busy_cycle_count()
    );
    always #5 clock = ~clock;

    task dump_data_ram;
        begin
            memory_file = $fopen(memory_path, "w");
            if (memory_file == 0) $fatal(1, "cannot open memory output");
            for (address = 'h3000; address < 'h4000; address = address + 4) begin
                cache_index = (address >> 4) & 3;
                memory_word = dut.DMemory[address >> 2];
                // Dirty resident lines can be newer than backing DMemory.
                if (dut.gen_dcache.dcache.cache_valid[cache_index] &&
                    dut.gen_dcache.dcache.cache_tag_store[cache_index] == (address >> 6)) begin
                    memory_word = dut.gen_dcache.dcache.cache_data[cache_index][(address >> 2) & 3];
                end
                $fwrite(memory_file, "%08x\n", memory_word);
            end
            $fclose(memory_file);
        end
    endtask

    initial begin
        if (!$value$plusargs("image=%s", image_path) ||
            !$value$plusargs("trace=%s", trace_path) ||
            !$value$plusargs("memory=%s", memory_path) ||
            !$value$plusargs("done_pc=%h", done_pc)) begin
            $fatal(1, "missing compiled-program arguments");
        end
        if (!$value$plusargs("timeout_cycles=%d", timeout_cycles)) timeout_cycles = 200000;
        trace_file = $fopen(trace_path, "w");
        if (trace_file == 0) $fatal(1, "cannot open trace output");
        // Let the CPU's initial memory setup finish before loading the image.
        #1;
        $readmemh(image_path, dut.IMemory, 0, MEMORY_WORDS - 1);
        $readmemh(image_path, dut.DMemory, 0, MEMORY_WORDS - 1);
        repeat (3) @(negedge clock);
        reset = 0;
    end

    always @(posedge clock) begin
        #1;
        if (!reset) begin
            elapsed = elapsed + 1;
            if (trace_valid) begin
                $fwrite(trace_file, "%08x %08x %02x %08x\n", trace_pc,
                        trace_instruction, {26'b0, trace_reg_write, trace_rd},
                        trace_reg_write ? trace_value : 32'b0);
                if (trace_pc == done_pc) begin
                    $fclose(trace_file);
                    dump_data_ram();
                    $display("METRICS cycles=%0d retired=%0d stalls=%0d icache_misses=%0d dcache_misses=%0d",
                             cycles, retired, stalls, icache_misses, dcache_misses);
                    $display("PASS: compiled program reached its retired completion loop");
                    $finish;
                end
            end
            if (elapsed >= timeout_cycles) $fatal(1, "compiled program timed out");
        end
    end
endmodule
