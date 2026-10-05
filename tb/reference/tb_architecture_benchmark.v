`timescale 1ns / 1ps

// Non-intrusive, simulation-only profiling. Sample stall causes on the same
// edge as the hardware counters; delimit intervals using retired marker PCs.
module tb_architecture_benchmark #(
    parameter FAST_MULTIPLY = 0,
    parameter ICACHE = 1,
    parameter ICACHE_BYTES = 64,
    parameter ICACHE_PARALLEL_LOOKUP = 1,
    parameter DCACHE = 1,
    parameter DCACHE_BYTES = 64,
    parameter DCACHE_VICTIM_LINES = 0,
    parameter PREDICTION = 1,
    parameter SCRATCHPAD = 0,
    parameter DMA = 0,
    parameter EXTERNAL_DMEM = 0,
    parameter EXTERNAL_IMEM = 0,
    parameter DMEM_EXTRA_WAIT = 0
);
    reg clock = 0;
    reg reset = 1;
    wire trace_valid, trace_write;
    wire [31:0] trace_pc, trace_instruction, trace_value;
    wire [4:0] trace_rd;
    wire [31:0] cycles, retired, stalls, imisses, dmisses, branch_misses;
    reg [2047:0] image_path, memory_path, trace_path;
    reg [31:0] begin_pc, end_pc, done_pc;
    reg measuring = 0;
    reg completed = 0;
    integer histogram [0:63];
    reg [5:0] sampled_mask;
    reg sampled_stall, sampled_retire, sampled_busy, sampled_compute;
    reg sampled_fill, sampled_writeback, sampled_victim;
    wire data_fill, data_writeback, victim_hit;
    integer data_line_fills = 0, data_writebacks = 0, victim_hits = 0;
    integer start_cycles, start_retired, start_stalls, start_imisses, start_dmisses, start_branches;
    integer sample_count = 0;
    integer no_retire_no_stall = 0;
    integer retire_with_stall = 0;
    integer busy_cycles = 0;
    integer compute_cycles = 0;
    integer elapsed = 0;
    integer trace_file, memory_file, index, address;
    wire [31:0] visible_word;
    wire accelerator_compute;
    wire [31:0] dmem_address;
    wire dmem_read, dmem_write, dmem_ready;
    wire [127:0] dmem_rdata, dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire backing_ready;
    integer request_wait = 0;
    wire release_request = request_wait == DMEM_EXTRA_WAIT;
    assign dmem_ready = release_request && backing_ready;
    // Delay acceptance, not the response of an already accepted write. The
    // unchanged request reaches BRAM only after this many extra clock edges.
    always @(posedge clock) begin
        if (reset || !(dmem_read || dmem_write) || dmem_ready)
            request_wait <= 0;
        else if (!release_request)
            request_wait <= request_wait + 1;
    end
    wire [31:0] imem_address;
    wire imem_read;
    reg [31:0] program_words [0:4095];
    wire [127:0] imem_line = imem_address < 16384 ?
        {program_words[{imem_address[13:4], 2'b11}], program_words[{imem_address[13:4], 2'b10}],
         program_words[{imem_address[13:4], 2'b01}], program_words[{imem_address[13:4], 2'b00}]} :
        {4{32'h0000_0013}};
    wire [31:0] backing_word = EXTERNAL_DMEM ? memory.memory[address >> 2] :
                                                         dut.DMemory[address >> 2];

    RISCVCPU #(
        .MEMORY_WORD_COUNT(4096), .FAST_MULTIPLY(FAST_MULTIPLY),
        .USE_EXTERNAL_DMEM(EXTERNAL_DMEM),
        .USE_EXTERNAL_IMEM(EXTERNAL_IMEM),
        .ENABLE_ICACHE(ICACHE), .ENABLE_DCACHE(DCACHE),
        .DCACHE_BYTES(DCACHE_BYTES), .DCACHE_VICTIM_LINES(DCACHE_VICTIM_LINES),
        .ICACHE_BYTES(ICACHE_BYTES), .ICACHE_PARALLEL_LOOKUP(ICACHE_PARALLEL_LOOKUP),
        .ENABLE_BRANCH_PREDICTOR(PREDICTION),
        .ENABLE_MATVEC_SCRATCHPAD(SCRATCHPAD), .ENABLE_MATVEC_DMA(DMA)
    ) dut (
        .clock(clock), .reset(reset),
        .imem_addr(imem_address), .imem_read(imem_read), .imem_rdata(imem_line), .imem_ready(imem_read),
        .dmem_addr(dmem_address), .dmem_read(dmem_read), .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata), .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
        .gpio_inputs(32'b0), .gpio_outputs(),
        .uart_tx_ready(1'b1), .uart_rx_data(8'b0), .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0), .uart_tx_data(), .uart_tx_valid(), .uart_rx_ready(),
        .config_error(), .debug_status(), .debug_pc(),
        .trace_valid(trace_valid), .trace_pc(trace_pc), .trace_instruction(trace_instruction),
        .trace_rd(trace_rd), .trace_reg_write(trace_write), .trace_writeback_value(trace_value),
        .perf_cycle_count(cycles), .perf_retired_count(retired),
        .perf_stall_cycle_count(stalls), .perf_icache_miss_count(imisses),
        .perf_dcache_miss_count(dmisses), .perf_branch_miss_count(branch_misses),
        .perf_matvec_start_count(), .perf_matvec_done_count(), .perf_matvec_busy_cycle_count()
    );
    external_dmem_bram #(.WORD_COUNT(4096)) memory (
        .clock(clock), .reset(reset), .dmem_addr(dmem_address),
        .dmem_read(dmem_read && release_request), .dmem_write(dmem_write && release_request), .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable), .dmem_rdata(dmem_rdata), .dmem_ready(backing_ready),
        .config_error(), .read_seen(), .write_seen()
    );
    generate
        if (DCACHE) begin : cache_snapshot
            reg victim_present;
            reg [31:0] victim_word;
            integer entry;
            always @* begin
                victim_present = 0;
                victim_word = 0;
                for (entry = 0; entry < DCACHE_VICTIM_LINES; entry = entry + 1) begin
                    if (dut.gen_dcache.dcache.victim_valid[entry] &&
                        dut.gen_dcache.dcache.victim_tag[entry] == (address >> 4)) begin
                        victim_present = 1;
                        victim_word = dut.gen_dcache.dcache.victim_data[entry][32*((address >> 2) & 3) +: 32];
                    end
                end
            end
            assign visible_word =
                dut.gen_dcache.dcache.cache_valid[(address / 16) % (DCACHE_BYTES / 16)] &&
                dut.gen_dcache.dcache.cache_tag_store[(address / 16) % (DCACHE_BYTES / 16)] == (address / DCACHE_BYTES) ?
                dut.gen_dcache.dcache.cache_data[(address / 16) % (DCACHE_BYTES / 16)][(address >> 2) & 3] :
                victim_present ? victim_word : backing_word;
            assign data_fill = dut.gen_dcache.dcache.refill_ready;
            assign data_writeback = dut.gen_dcache.dcache.cache_state == 1 &&
                                    (!EXTERNAL_DMEM || dmem_ready);
            assign victim_hit = dut.gen_dcache.dcache.victim_complete;
        end else begin : ram_snapshot
            assign visible_word = backing_word;
            assign data_fill = 0;
            assign data_writeback = 0;
            assign victim_hit = 0;
        end
        if (SCRATCHPAD) begin : sp_activity
            assign accelerator_compute = dut.gen_accelerators.accel_matvec.compute_state == 2 ||
                                         dut.gen_accelerators.accel_matvec.compute_state == 3;
        end else if (DMA) begin : dma_activity
            assign accelerator_compute = dut.gen_dma_accelerator.accel_matvec_dma.state == 3 ||
                                         dut.gen_dma_accelerator.accel_matvec_dma.state == 4;
        end else begin : no_activity
            assign accelerator_compute = 1'b0;
        end
    endgenerate
    always #5 clock = ~clock;

    initial begin
        for (index = 0; index < 64; index = index + 1) histogram[index] = 0;
        if (!$value$plusargs("image=%s", image_path) ||
            !$value$plusargs("memory=%s", memory_path) ||
            !$value$plusargs("trace=%s", trace_path) ||
            !$value$plusargs("begin_pc=%h", begin_pc) ||
            !$value$plusargs("end_pc=%h", end_pc) ||
            !$value$plusargs("done_pc=%h", done_pc)) $fatal(1, "missing architecture arguments");
        trace_file = $fopen(trace_path, "w");
        if (!trace_file) $fatal(1, "cannot open trace");
        #1;
        $readmemh(image_path, program_words, 0, 4095);
        if (!EXTERNAL_IMEM) $readmemh(image_path, dut.IMemory, 0, 4095);
        if (!EXTERNAL_DMEM) $readmemh(image_path, dut.DMemory, 0, 4095);
        $readmemh(image_path, memory.memory, 0, 4095);
        for (index = 0; index < 1024; index = index + 1)
            memory.line_memory[index] = {memory.memory[4*index+3], memory.memory[4*index+2],
                                         memory.memory[4*index+1], memory.memory[4*index]};
        repeat (3) @(negedge clock);
        reset = 0;
    end

    always @(posedge clock) begin
        // Bit ordering also defines the documented exclusive attribution:
        // UART > DMA ownership > D-cache > M unit > I-cache > load-use.
        sampled_mask = {dut.load_use_hazard, dut.icache_pipeline_stall,
                        dut.rv32m_execute_stall, (dut.cache_busy || dut.cache_miss),
                        dut.matvec_dma_cpu_memory_stall, dut.uart_tx_pipeline_stall};
        sampled_stall = dut.stall_event;
        sampled_retire = dut.retire_event;
        sampled_busy = dut.matvec_busy || dut.matvec_dma_busy;
        sampled_compute = accelerator_compute;
        sampled_fill = data_fill;
        sampled_writeback = data_writeback;
        sampled_victim = victim_hit;
        #1;
        if (!reset) begin
            elapsed = elapsed + 1;
            if (measuring) begin
                if ((|sampled_mask) !== sampled_stall) $fatal(1, "unclassified stall");
                histogram[sampled_mask] = histogram[sampled_mask] + 1;
                sample_count = sample_count + 1;
                if (!sampled_retire && !sampled_stall) no_retire_no_stall = no_retire_no_stall + 1;
                if (sampled_retire && sampled_stall) retire_with_stall = retire_with_stall + 1;
                if (sampled_busy) busy_cycles = busy_cycles + 1;
                if (sampled_compute) compute_cycles = compute_cycles + 1;
                if (sampled_fill) data_line_fills = data_line_fills + 1;
                if (sampled_writeback) data_writebacks = data_writebacks + 1;
                if (sampled_victim) victim_hits = victim_hits + 1;
            end
            if (trace_valid) begin
                $fwrite(trace_file, "%08x %08x %02x %08x\n", trace_pc, trace_instruction,
                        {26'b0, trace_write, trace_rd}, trace_write ? trace_value : 32'b0);
                if (trace_pc == begin_pc) begin
                    if (measuring || completed) $fatal(1, "repeated begin marker");
                    measuring = 1;
                    start_cycles = cycles;
                    start_retired = retired;
                    start_stalls = stalls;
                    start_imisses = imisses;
                    start_dmisses = dmisses;
                    start_branches = branch_misses;
                end
                if (trace_pc == end_pc) begin
                    if (!measuring || completed) $fatal(1, "unexpected end marker");
                    if (sample_count != cycles - start_cycles) $fatal(1, "clock interval mismatch");
                    if (sample_count - histogram[0] != stalls - start_stalls) $fatal(1, "stall union mismatch");
                    measuring = 0;
                    completed = 1;
                    $display("PROFILE cycles=%0d retired=%0d stalls=%0d icache_misses=%0d dcache_misses=%0d branch_misses=%0d no_retire_no_stall=%0d retire_with_stall=%0d busy_cycles=%0d compute_cycles=%0d data_line_fills=%0d data_writebacks=%0d victim_hits=%0d",
                             cycles-start_cycles, retired-start_retired, stalls-start_stalls,
                             imisses-start_imisses, dmisses-start_dmisses, branch_misses-start_branches,
                             no_retire_no_stall, retire_with_stall, busy_cycles, compute_cycles,
                             data_line_fills, data_writebacks, victim_hits);
                    for (index = 0; index < 64; index = index + 1)
                        $display("MASK %0d %0d", index, histogram[index]);
                end
                if (trace_pc == done_pc) begin
                    if (!completed) $fatal(1, "missing measurement");
                    $fclose(trace_file);
                    memory_file = $fopen(memory_path, "w");
                    if (!memory_file) $fatal(1, "cannot open memory");
                    for (address = 'h3000; address < 'h4000; address = address + 4) begin
                        #1;
                        $fwrite(memory_file, "%08x\n", visible_word);
                    end
                    $fclose(memory_file);
                    $display("PASS: architecture workload completed");
                    $finish;
                end
            end
            if (elapsed >= 500000) $fatal(1, "architecture workload timed out");
        end
    end
endmodule
