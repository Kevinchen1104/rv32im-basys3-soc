`timescale 1ns / 1ps

// Testbench: tb_assert_matvec_dma_descriptor_overlap
// Purpose: Checks CPU-visible rejection of an overlapping MATVEC DMA-lite descriptor.
// Checks: A matrix/output overlap reports error bit 9 through MMIO, completes without becoming busy,
//   issues no DMA memory transaction, and leaves all DMA performance counters unchanged.
// Pass condition: The CPU reads the overlap error and every no-side-effect condition remains true.
// Does not prove: General DMA correctness, cache coherence, timing closure, or physical-board behavior.

module tb_assert_matvec_dma_descriptor_overlap;

`include "tb_common.vh"

    integer dma_request_count = 0;

    always @(posedge clock) begin
        if (dut.matvec_dma_dmem_request) begin
            dma_request_count <= dma_request_count + 1;
        end
    end

    initial begin
        $dumpfile("wave/tb_assert_matvec_dma_descriptor_overlap.vcd");
        $dumpvars(0, tb_assert_matvec_dma_descriptor_overlap);

        reset_cpu();

        dut.IMemory[0] = 32'h0000_10b7;                                      // lui x1, 0x1
        dut.IMemory[1] = i_type(12'h900, 5'd1, 3'b000, 5'd1, 7'b0010011);    // x1 = 0x900
        dut.IMemory[2] = i_type(12'h040, 5'd0, 3'b000, 5'd2, 7'b0010011);    // vector = 0x40
        dut.IMemory[3] = s_type(12'd0, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[4] = i_type(12'h050, 5'd0, 3'b000, 5'd2, 7'b0010011);    // matrix = 0x50
        dut.IMemory[5] = s_type(12'd4, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[6] = i_type(12'h054, 5'd0, 3'b000, 5'd2, 7'b0010011);    // output = 0x54
        dut.IMemory[7] = s_type(12'd8, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[8] = i_type(12'd2, 5'd0, 3'b000, 5'd2, 7'b0010011);      // rows = 2
        dut.IMemory[9] = s_type(12'd12, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[10] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);     // start
        dut.IMemory[11] = s_type(12'd16, 5'd2, 5'd1, 3'b010, 7'b0100011);
        dut.IMemory[12] = i_type(12'd20, 5'd1, 3'b010, 5'd4, 7'b0000011);    // status MMIO
        dut.IMemory[13] = i_type(12'd2, 5'd4, 3'b111, 5'd4, 7'b0010011);     // done bit
        dut.IMemory[14] = b_type(-8, 5'd0, 5'd4, 3'b000, 7'b1100011);       // wait for done
        dut.IMemory[15] = i_type(12'd24, 5'd1, 3'b010, 5'd3, 7'b0000011);   // error MMIO
        dut.IMemory[16] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        run_cycles(100);

        check_reg(3, 32'h0000_0200);
        if (dut.gen_accelerators.accel_matvec_dma.busy !== 1'b0 ||
            dut.gen_accelerators.accel_matvec_dma.done !== 1'b1 ||
            dut.gen_accelerators.accel_matvec_dma.error !== 1'b1 ||
            dut.matvec_dma_error_read_data !== 32'h0000_0200 ||
            dut.matvec_dma_perf_read_data !== 32'h0000_0000 ||
            dma_request_count != 0) begin
            $display("FAIL: overlap descriptor status=%h error=%h perf=%h requests=%0d",
                     dut.matvec_dma_status_read_data,
                     dut.matvec_dma_error_read_data,
                     dut.matvec_dma_perf_read_data,
                     dma_request_count);
            $fatal;
        end

        $display("PASS: overlapping MATVEC DMA descriptor was rejected without DMEM traffic");
        $display("PASS: tb_assert_matvec_dma_descriptor_overlap passed");
        $finish;
    end
endmodule
