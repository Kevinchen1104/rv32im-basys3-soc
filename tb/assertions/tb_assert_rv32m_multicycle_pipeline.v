`timescale 1ns / 1ps

// Testbench: tb_assert_rv32m_multicycle_pipeline
// Purpose: Exercises multicycle RV32M execution through the CPU pipeline with hazards and an interrupt.
// Checks: Back-to-back and dependent M operations, load/store forwarding, x0, single retirement, and deferred timer interrupt entry.
// Pass condition: Architectural registers, memory round-trip, trace counts, and timer trap state match the directed expectations.
// Does not prove: Selected pipeline interactions only; not exhaustive RV32M arithmetic, interrupt, cache, or timing proof.
// Assertion focus: A held M instruction completes once, retires once, and is not displaced by a pending timer interrupt.

module tb_assert_rv32m_multicycle_pipeline;

`include "tb_common.vh"

    localparam [31:0] DIV_PC = 32'd32;
    localparam [31:0] INTERRUPTED_PC = 32'd36;
    localparam [31:0] HANDLER_PC = 32'd48;

    integer m_retire_count;
    integer mul_pc8_retire_count;
    integer mul_pc8_writeback_count;
    integer timer_div_retire_count;
    reg timer_phase = 1'b0;
    reg timer_forced = 1'b0;
    reg timer_released = 1'b0;

    always @(posedge clock) begin
        if (dut.trace_valid && (dut.trace_instruction[6:0] == 7'b0110011) &&
            (dut.trace_instruction[31:25] == 7'b0000001)) begin
            m_retire_count = m_retire_count + 1;
            if (dut.trace_pc == 32'd8) begin
                mul_pc8_retire_count = mul_pc8_retire_count + 1;
                if (dut.trace_reg_write && (dut.trace_rd == 5'd3)) begin
                    mul_pc8_writeback_count = mul_pc8_writeback_count + 1;
                end
            end
            if (timer_phase && (dut.trace_pc == DIV_PC)) begin
                timer_div_retire_count = timer_div_retire_count + 1;
            end
        end

        if (timer_phase && dut.IDEXMExtension && dut.interrupt_taken) begin
            $display("FAIL: timer interrupt displaced an in-flight M instruction");
            $fatal;
        end

        if (timer_phase && timer_forced && !timer_released && dut.interrupt_taken) begin
            #1;
            release dut.timer_irq_pending;
            timer_released = 1'b1;
        end
    end

    always @(negedge clock) begin
        if (timer_phase && !timer_forced && dut.rv32m_busy &&
            dut.IDEXMExtension && (dut.IDEXPC == DIV_PC)) begin
            force dut.timer_irq_pending = 1'b1;
            timer_forced = 1'b1;
        end
    end

    task run_hazard_phase;
        begin
            reset_cpu();
            m_retire_count = 0;
            mul_pc8_retire_count = 0;
            mul_pc8_writeback_count = 0;

            dut.IMemory[0] = i_type(12'd6, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'd7, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.IMemory[2] = r_type(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011);
            dut.IMemory[3] = r_type(7'b0000001, 5'd2, 5'd3, 3'b000, 5'd4, 7'b0110011);
            dut.IMemory[4] = s_type(12'd0, 5'd4, 5'd0, 3'b010, 7'b0100011);
            dut.IMemory[5] = i_type(12'd0, 5'd0, 3'b010, 5'd5, 7'b0000011);
            dut.IMemory[6] = r_type(7'b0000001, 5'd1, 5'd5, 3'b000, 5'd6, 7'b0110011);
            dut.IMemory[7] = s_type(12'd4, 5'd6, 5'd0, 3'b010, 7'b0100011);
            dut.IMemory[8] = i_type(12'd4, 5'd0, 3'b010, 5'd8, 7'b0000011);
            dut.IMemory[9] = r_type(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd0, 7'b0110011);
            dut.IMemory[10] = i_type(12'd1, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[11] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            run_cycles(520);

            check_reg(3, 32'd42);
            check_reg(4, 32'd294);
            check_reg(5, 32'd294);
            check_reg(6, 32'd1764);
            check_reg(8, 32'd1764);
            check_reg(0, 32'h0);
            check_reg(7, 32'd1);
            if (m_retire_count != 4 ||
                mul_pc8_retire_count != 1 ||
                mul_pc8_writeback_count != 1) begin
                $display("FAIL: M counts total_retire=%0d pc8_retire=%0d pc8_writeback=%0d",
                         m_retire_count, mul_pc8_retire_count, mul_pc8_writeback_count);
                $fatal;
            end
        end
    endtask

    task run_timer_phase;
        begin
            reset_cpu();
            m_retire_count = 0;
            timer_div_retire_count = 0;
            timer_forced = 1'b0;
            timer_released = 1'b0;

            dut.IMemory[0] = i_type(HANDLER_PC[11:0], 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[2] = i_type(12'h080, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[3] = i_type(12'h304, 5'd5, 3'b010, 5'd0, 7'b1110011);
            dut.IMemory[4] = i_type(12'd8, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[5] = i_type(12'h300, 5'd5, 3'b010, 5'd0, 7'b1110011);
            dut.IMemory[6] = i_type(12'd100, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[7] = i_type(12'd3, 5'd0, 3'b000, 5'd2, 7'b0010011);
            dut.IMemory[8] = r_type(7'b0000001, 5'd2, 5'd1, 3'b100, 5'd3, 7'b0110011);
            dut.IMemory[9] = i_type(12'd1, 5'd3, 3'b000, 5'd4, 7'b0010011);
            dut.IMemory[10] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);
            dut.IMemory[12] = i_type(12'h342, 5'd0, 3'b010, 5'd10, 7'b1110011);
            dut.IMemory[13] = i_type(12'h341, 5'd0, 3'b010, 5'd11, 7'b1110011);
            dut.IMemory[14] = 32'h30200073;

            timer_phase = 1'b1;
            run_cycles(520);
            timer_phase = 1'b0;

            if (!timer_forced || !timer_released) begin
                $display("FAIL: timer interrupt was not forced and released around division");
                $fatal;
            end
            if (timer_div_retire_count != 1) begin
                $display("FAIL: division retired %0d times during timer phase", timer_div_retire_count);
                $fatal;
            end
            if (dut.CSRmcause !== 32'h8000_0007 || dut.CSRmepc !== INTERRUPTED_PC) begin
                $display("FAIL: timer trap mcause=%h mepc=%h", dut.CSRmcause, dut.CSRmepc);
                $fatal;
            end
            check_reg(3, 32'd33);
            check_reg(4, 32'd34);
            check_reg(10, 32'h8000_0007);
            check_reg(11, INTERRUPTED_PC);
        end
    endtask

    initial begin
        $dumpfile("wave/tb_assert_rv32m_multicycle_pipeline.vcd");
        $dumpvars(0, tb_assert_rv32m_multicycle_pipeline);

        run_hazard_phase();
        run_timer_phase();

        $display("PASS: tb_assert_rv32m_multicycle_pipeline passed");
        $finish;
    end

endmodule
