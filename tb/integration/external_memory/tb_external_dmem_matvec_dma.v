`timescale 1ns / 1ps

// Testbench: tb_external_dmem_matvec_dma
// Purpose: Exercises the CPU external-memory integration boundary in simulation.
// Checks: Runs matvec_dma_demo with USE_EXTERNAL_DMEM=1, checks public debug_status pass/fail, observes external DMem
//   read/write traffic, verifies DMA-written output words in the external DMem BRAM, and confirms internal DMemory is
//   not the observation point.
// Pass condition: Observed external-memory traffic, public status, and checked memory contents match expectations.
//   subsystem, timing result, or board validation.
// Firmware: firmware/hex/accelerator/matvec_dma_demo.hex

module tb_external_dmem_matvec_dma;
    reg clock = 0;
    reg reset = 0;
    wire [31:0] dmem_addr;
    wire dmem_read;
    wire dmem_write;
    wire [127:0] dmem_wdata;
    wire [15:0] dmem_byte_enable;
    wire [127:0] dmem_rdata;
    wire dmem_ready;
    wire [31:0] debug_status;
    wire [31:0] debug_pc;
    wire external_read_seen;
    wire external_write_seen;

    localparam [31:0] PASS_MARKER = 32'hd1a0_2016;
    localparam [31:0] FAIL_MARKER = 32'hbad0_2016;
    localparam integer TIMEOUT_CYCLES = 4000;
    localparam integer OUT_WORD = 32'h0000_01a0 >> 2;

    integer cycle;
    integer dmem_read_count = 0;
    integer dmem_write_count = 0;
    integer partial_write_seen = 0;
    integer dma_read_accept_count = 0;
    integer dma_write_accept_count = 0;
    integer completion_cycle = -1;

    RISCVCPU #(
        .MEMORY_WORD_COUNT(256),
        .INIT_PROGRAM_HEX("firmware/hex/accelerator/matvec_dma_demo.hex"),
        .INIT_PROGRAM_WORD_COUNT(61),
        .USE_EXTERNAL_DMEM(1)
    ) cpu (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
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
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready()
    );

    external_dmem_bram #(
        .WORD_COUNT(256)
    ) dmem (
        .clock(clock),
        .reset(reset),
        .dmem_addr(dmem_addr),
        .dmem_read(dmem_read),
        .dmem_write(dmem_write),
        .dmem_wdata(dmem_wdata),
        .dmem_byte_enable(dmem_byte_enable),
        .dmem_rdata(dmem_rdata),
        .dmem_ready(dmem_ready),
        .read_seen(external_read_seen),
        .write_seen(external_write_seen)
    );

    always #5 clock = ~clock;

    always @(posedge clock) begin
        if (dmem_read) begin
            dmem_read_count <= dmem_read_count + 1;
        end
        if (dmem_write) begin
            dmem_write_count <= dmem_write_count + 1;
            if (dmem_byte_enable != 16'hffff) begin
                partial_write_seen <= partial_write_seen + 1;
            end
        end
        if (cpu.matvec_dma_dmem_read && cpu.matvec_dma_dmem_ready) begin
            dma_read_accept_count <= dma_read_accept_count + 1;
        end
        if (cpu.matvec_dma_dmem_write && cpu.matvec_dma_dmem_ready) begin
            dma_write_accept_count <= dma_write_accept_count + 1;
        end
    end

    initial begin
        $dumpfile("wave/tb_external_dmem_matvec_dma.vcd");
        $dumpvars(0, tb_external_dmem_matvec_dma);

        reset = 1'b1;
        repeat (2) @(posedge clock);
        #1;
        reset = 1'b0;

        for (cycle = 0; cycle < TIMEOUT_CYCLES; cycle = cycle + 1) begin
            @(posedge clock);
            #1;
            if (debug_status === PASS_MARKER || debug_status === FAIL_MARKER) begin
                completion_cycle = cycle;
                cycle = TIMEOUT_CYCLES;
            end
        end

        if (debug_status === FAIL_MARKER) begin
            $display("FAIL: external DMEM matvec DMA demo stored fail marker %h", debug_status);
            $fatal;
        end

        if (debug_status !== PASS_MARKER) begin
            $display("FAIL: timed out waiting for pass marker, debug_status=%h debug_pc=%h", debug_status, debug_pc);
            $fatal;
        end

        // The MATVEC results must appear in external DMem when USE_EXTERNAL_DMEM is enabled.
        if (dmem.memory[OUT_WORD + 0] !== 32'hffff_fff6 ||
            dmem.memory[OUT_WORD + 1] !== 32'hffff_fffa ||
            dmem.memory[OUT_WORD + 2] !== 32'h0000_0182 ||
            dmem.memory[OUT_WORD + 3] !== 32'h0000_0046) begin
            $display("FAIL: external DMem output mismatch %h %h %h %h",
                     dmem.memory[OUT_WORD + 0],
                     dmem.memory[OUT_WORD + 1],
                     dmem.memory[OUT_WORD + 2],
                     dmem.memory[OUT_WORD + 3]);
            $fatal;
        end

        // Keep internal DMemory as a guard against accidentally observing the wrong storage domain.
        if (cpu.DMemory[OUT_WORD + 0] !== 32'h0 ||
            cpu.DMemory[OUT_WORD + 1] !== 32'h0 ||
            cpu.DMemory[OUT_WORD + 2] !== 32'h0 ||
            cpu.DMemory[OUT_WORD + 3] !== 32'h0) begin
            $display("FAIL: internal DMemory changed under USE_EXTERNAL_DMEM=1");
            $fatal;
        end

        if (!external_read_seen || !external_write_seen ||
            dmem_read_count == 0 || dmem_write_count == 0 ||
            partial_write_seen < 4 || dma_read_accept_count != 5 ||
            dma_write_accept_count != 4 ||
            cpu.matvec_dma_perf_read_data !== 32'h0405_0101) begin
            $display("FAIL: external DMA evidence seen=%0b/%0b request_cycles=%0d/%0d accepted=%0d/%0d partial=%0d perf=%h",
                     external_read_seen,
                     external_write_seen,
                     dmem_read_count,
                     dmem_write_count,
                     dma_read_accept_count,
                     dma_write_accept_count,
                     partial_write_seen,
                     cpu.matvec_dma_perf_read_data);
            $fatal;
        end

        $display("INFO: synchronous external DMEM completed at cycle %0d with DMA accepted reads=%0d writes=%0d",
                 completion_cycle, dma_read_accept_count, dma_write_accept_count);
        $display("PASS: tb_external_dmem_matvec_dma passed");
        $finish;
    end
endmodule
