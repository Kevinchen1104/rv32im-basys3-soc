`timescale 1ns / 1ps

// Purpose: Checks that held execute-stage CSR and exception instructions have side effects only when D-cache backpressure releases.
// Checks: Real multi-cycle load misses, one-shot CSR writes with pre-write readback, and one-shot illegal-instruction trap entry.
// Pass condition: Held instructions remain inert during the miss and commit exactly once at the execute acceptance boundary.

module tb_assert_execute_acceptance_dcache_stall;

`include "tb_common.vh"

    localparam [6:0] LOAD = 7'b0000011;
    localparam [6:0] OP_IMM = 7'b0010011;
    localparam [6:0] SYSTEM = 7'b1110011;
    localparam [6:0] BRANCH = 7'b1100011;

    integer phase;
    integer csr_stall_cycles;
    integer csr_accept_pulses;
    integer exception_stall_cycles;
    integer exception_accept_pulses;

    always @(posedge clock) begin
        if (!reset && (phase == 1)) begin
            if (dut.IDEXValid && (dut.IDEXPC == 32'd20) &&
                dut.dcache_pipeline_stall) begin
                csr_stall_cycles = csr_stall_cycles + 1;
                if (dut.csr_write_enable) begin
                    $display("FAIL: held CSR instruction wrote during D-cache stall");
                    $fatal;
                end
            end
            if (dut.IDEXValid && (dut.IDEXPC == 32'd20) &&
                dut.csr_write_enable) begin
                csr_accept_pulses = csr_accept_pulses + 1;
            end
        end

        if (!reset && (phase == 2)) begin
            if (dut.IDEXValid && (dut.IDEXPC == 32'd24) &&
                dut.dcache_pipeline_stall) begin
                exception_stall_cycles = exception_stall_cycles + 1;
                if (!dut.exception_pending || !dut.redirect_taken ||
                    dut.if_redirect || (dut.pc_next_value !== dut.PC) ||
                    (dut.redirect_pc !== dut.CSRmtvec) ||
                    dut.immediate_exception_taken ||
                    dut.trap_taken ||
                    dut.csr_unit_inst.trap_metadata_pending ||
                    (dut.CSRmstatus !== 32'h0000_1808)) begin
                    $display("FAIL: held illegal instruction trapped during D-cache stall");
                    $fatal;
                end
            end
            if (dut.IDEXValid && (dut.IDEXPC == 32'd24) &&
                dut.immediate_exception_taken) begin
                exception_accept_pulses = exception_accept_pulses + 1;
            end
        end
    end

    task run_csr_after_load_miss;
        begin
            reset_cpu();
            phase = 1;
            csr_stall_cycles = 0;
            csr_accept_pulses = 0;

            dut.IMemory[0] = i_type(12'd8, 5'd0, 3'b000, 5'd6, OP_IMM);
            dut.IMemory[1] = i_type(12'h300, 5'd6, 3'b001, 5'd0, SYSTEM);
            dut.IMemory[2] = i_type(12'd0, 5'd0, 3'b000, 5'd6, OP_IMM);
            dut.IMemory[3] = i_type(12'd160, 5'd0, 3'b000, 5'd1, OP_IMM);
            dut.IMemory[4] = i_type(12'd0, 5'd1, 3'b010, 5'd2, LOAD);
            dut.IMemory[5] = i_type(12'h300, 5'd6, 3'b001, 5'd5, SYSTEM);
            dut.IMemory[6] = i_type(12'd0, 5'd5, 3'b000, 5'd7, OP_IMM);
            dut.IMemory[7] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.DMemory[40] = 32'h1234_5678;

            run_cycles(180);
            phase = 0;

            if (csr_stall_cycles < 2) begin
                $display("FAIL: CSR scenario did not observe a multi-cycle D-cache stall");
                $fatal;
            end
            if (csr_accept_pulses != 1) begin
                $display("FAIL: CSR write accepted %0d times", csr_accept_pulses);
                $fatal;
            end
            check_reg(2, 32'h1234_5678);
            check_reg(5, 32'h0000_1808);
            check_reg(7, 32'h0000_1808);
            if (dut.CSRmstatus !== 32'h0000_1800) begin
                $display("FAIL: final mstatus expected 00001800, got %h", dut.CSRmstatus);
                $fatal;
            end
        end
    endtask

    task run_exception_after_load_miss;
        begin
            reset_cpu();
            phase = 2;
            exception_stall_cycles = 0;
            exception_accept_pulses = 0;

            dut.IMemory[0] = i_type(12'd64, 5'd0, 3'b000, 5'd6, OP_IMM);
            dut.IMemory[1] = i_type(12'h305, 5'd6, 3'b001, 5'd0, SYSTEM);
            dut.IMemory[2] = i_type(12'd8, 5'd0, 3'b000, 5'd6, OP_IMM);
            dut.IMemory[3] = i_type(12'h300, 5'd6, 3'b001, 5'd0, SYSTEM);
            dut.IMemory[4] = i_type(12'd192, 5'd0, 3'b000, 5'd1, OP_IMM);
            dut.IMemory[5] = i_type(12'd0, 5'd1, 3'b010, 5'd2, LOAD);
            dut.IMemory[6] = 32'hffff_ffff;
            dut.IMemory[7] = i_type(12'h055, 5'd0, 3'b000, 5'd9, OP_IMM);
            dut.IMemory[16] = i_type(12'd1, 5'd0, 3'b000, 5'd10, OP_IMM);
            dut.IMemory[17] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.DMemory[48] = 32'h89ab_cdef;

            run_cycles(220);
            phase = 0;

            if (exception_stall_cycles < 2) begin
                $display(
                    "FAIL: exception scenario did not observe a multi-cycle D-cache stall PC=%h x1=%h x2=%h",
                    dut.PC,
                    dut.Regs[1],
                    dut.Regs[2]
                );
                $fatal;
            end
            if (exception_accept_pulses != 1) begin
                $display("FAIL: exception accepted %0d times", exception_accept_pulses);
                $fatal;
            end
            check_reg(2, 32'h89ab_cdef);
            check_reg(9, 32'd9);
            check_reg(10, 32'd1);
            if ((dut.CSRmstatus !== 32'h0000_1880) ||
                (dut.CSRmepc !== 32'd24) ||
                (dut.CSRmcause !== 32'd2) ||
                (dut.CSRmtval !== 32'hffff_ffff)) begin
                $display(
                    "FAIL: trap state mstatus=%h mepc=%h mcause=%h mtval=%h",
                    dut.CSRmstatus,
                    dut.CSRmepc,
                    dut.CSRmcause,
                    dut.CSRmtval
                );
                $fatal;
            end
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_execute_acceptance_dcache_stall.vcd");
        $dumpvars(0, tb_assert_execute_acceptance_dcache_stall);
        phase = 0;
        csr_stall_cycles = 0;
        csr_accept_pulses = 0;
        exception_stall_cycles = 0;
        exception_accept_pulses = 0;

        run_csr_after_load_miss();
        run_exception_after_load_miss();

        $display("PASS: execute-stage CSR and exception acceptance remained precise across D-cache stalls");
        $display("PASS: tb_assert_execute_acceptance_dcache_stall passed");
        $finish;
    end

endmodule
