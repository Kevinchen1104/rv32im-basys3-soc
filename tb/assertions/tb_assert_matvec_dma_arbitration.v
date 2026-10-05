`timescale 1ns / 1ps

// Checks: The local DMA-lite ownership policy: while MATVEC DMA owns the single DMEM port, a CPU ordinary memory
//   store is stalled through read and compute-only stages, D-cache request_valid is blocked, D-cache external/internal
//   writeback requests do not overlap DMA requests, and every output row is written exactly once.

module tb_assert_matvec_dma_arbitration;

`define CORE_DCACHE_VICTIM_LINES 4
`include "tb_common.vh"

    reg checking_enabled = 1'b0;
    reg saw_dma_busy = 1'b0;
    reg saw_cpu_memory_stall = 1'b0;
    reg saw_blocked_store = 1'b0;
    reg saw_dma_read = 1'b0;
    reg saw_dma_write = 1'b0;
    reg saw_compute_gap = 1'b0;
    reg saw_compute_owned_gap = 1'b0;
    integer dma_write_count = 0;

    localparam [2:0] STATE_MULTIPLY = 3'd3;
    localparam [2:0] STATE_REDUCE = 3'd4;

    always @(posedge clock) begin
        if (checking_enabled) begin
            if (dut.gen_dma_accelerator.accel_matvec_dma.busy) begin
                saw_dma_busy <= 1'b1;
            end
            if (dut.matvec_dma_cpu_memory_stall) begin
                saw_cpu_memory_stall <= 1'b1;
            end
            if (dut.matvec_dma_cpu_memory_stall &&
                dut.EXMEMValid &&
                dut.EXMEMMemWrite &&
                !dut.EXMEMMmioAccess) begin
                saw_blocked_store <= 1'b1;
            end
            if (dut.matvec_dma_dmem_read) begin
                saw_dma_read <= 1'b1;
            end
            if (dut.matvec_dma_dmem_write) begin
                saw_dma_write <= 1'b1;
                if (dut.matvec_dma_dmem_ready) begin
                    dma_write_count <= dma_write_count + 1;
                end
            end

            if ((dut.gen_dma_accelerator.accel_matvec_dma.state == STATE_MULTIPLY) ||
                (dut.gen_dma_accelerator.accel_matvec_dma.state == STATE_REDUCE)) begin
                saw_compute_gap <= 1'b1;
                if (dut.matvec_dma_dmem_request) begin
                    $display("FAIL: MATVEC DMA issued a DMEM request during compute-only state");
                    $fatal;
                end
                if (dut.matvec_dma_cpu_memory_stall) begin
                    saw_compute_owned_gap <= 1'b1;
                end
            end

            if (dut.gen_dma_accelerator.accel_matvec_dma.busy &&
                dut.gen_dcache.dcache.request_valid &&
                dut.EXMEMMemAccess &&
                !dut.EXMEMMmioAccess) begin
                $display("FAIL: D-cache accepted CPU memory request while MATVEC DMA owned DMEM");
                $fatal;
            end

            if (dut.matvec_dma_dmem_request &&
                (dut.dcache_external_read || dut.dcache_external_write)) begin
                $display("FAIL: D-cache external request overlapped MATVEC DMA DMEM request");
                $fatal;
            end

            if (dut.matvec_dma_dmem_request && dut.dcache_internal_writeback_valid) begin
                $display("FAIL: internal D-cache writeback overlapped MATVEC DMA DMEM request");
                $fatal;
            end
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_matvec_dma_arbitration.vcd");
        $dumpvars(0, tb_assert_matvec_dma_arbitration);

        reset_cpu();

        dut.DMemory[32'h0000_0040 >> 2] = 32'hfc03_fe01;
        dut.DMemory[32'h0000_0050 >> 2] = 32'h01ff_0201;
        dut.DMemory[(32'h0000_0050 >> 2) + 1] = 32'h0000_0504;
        dut.DMemory[(32'h0000_0050 >> 2) + 2] = 32'h0001_807f;
        dut.DMemory[(32'h0000_0050 >> 2) + 3] = 32'h000a_ec00;

        dut.IMemory[0] = 32'h0000_10b7;                                      // lui x1, 0x1
        dut.IMemory[1] = i_type(12'h900, 5'd1, 3'b000, 5'd1, 7'b0010011);    // x1 = 0x900
        dut.IMemory[2] = i_type(12'h040, 5'd0, 3'b000, 5'd2, 7'b0010011);    // x2 = vector addr
        dut.IMemory[3] = s_type(12'd0, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[4] = i_type(12'h050, 5'd0, 3'b000, 5'd2, 7'b0010011);    // x2 = matrix addr
        dut.IMemory[5] = s_type(12'd4, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[6] = i_type(12'h080, 5'd0, 3'b000, 5'd2, 7'b0010011);    // x2 = output addr
        dut.IMemory[7] = s_type(12'd8, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[8] = i_type(12'd4, 5'd0, 3'b000, 5'd2, 7'b0010011);      // rows = 4
        dut.IMemory[9] = s_type(12'd12, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[10] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);     // start = 1
        dut.IMemory[11] = s_type(12'd16, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[12] = i_type(12'h07b, 5'd0, 3'b000, 5'd3, 7'b0010011);   // marker data
        dut.IMemory[13] = s_type(12'h0c0, 5'd3, 5'd0, 3'b010, 7'b0100011);   // CPU DMEM store while DMA busy
        dut.IMemory[14] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        checking_enabled = 1'b1;
        run_cycles(260);
        checking_enabled = 1'b0;

        if (!saw_dma_busy || !saw_cpu_memory_stall || !saw_blocked_store ||
            !saw_dma_read || !saw_dma_write || !saw_compute_gap ||
            !saw_compute_owned_gap || (dma_write_count != 4)) begin
            $display("FAIL: arbitration evidence busy=%0b stall=%0b blocked=%0b read=%0b write=%0b compute=%0b compute_owned=%0b writes=%0d",
                     saw_dma_busy,
                     saw_cpu_memory_stall,
                     saw_blocked_store,
                     saw_dma_read,
                     saw_dma_write,
                     saw_compute_gap,
                     saw_compute_owned_gap,
                     dma_write_count);
            $fatal;
        end

        if (dut.gen_dma_accelerator.accel_matvec_dma.done !== 1'b1 ||
            dut.gen_dma_accelerator.accel_matvec_dma.error !== 1'b0) begin
            $display("FAIL: DMA did not complete cleanly status=%h error=%h",
                     dut.matvec_dma_status_read_data,
                     dut.matvec_dma_error_read_data);
            $fatal;
        end

        check_reg(3, 32'h0000_007b);
        $display("PASS: MATVEC DMA owned DMEM while CPU memory store was stalled");
        $display("PASS: tb_assert_matvec_dma_arbitration passed");
        $finish;
    end
endmodule
