`timescale 1ns / 1ps

// Testbench: tb_assert_rv32m_trap_squash
// Purpose: Verifies that an older memory access fault squashes a younger RV32M operation.
// Checks: Out-of-range load/store traps cannot start the adjacent MUL/DIV, leave no in-flight
//   or ready state, and cannot feed a stale result to a different M instruction after mret.
// Pass condition: Both fault phases trap once, suppress the younger M instruction, and retire
//   the post-handler M instruction exactly once with its independently expected result.
// Does not prove: Directed load/store access-fault interactions only; not exhaustive trap,
//   RV32M arithmetic, cache, formal, timing, or physical-board evidence.

module tb_assert_rv32m_trap_squash;

`include "tb_common.vh"

    localparam [31:0] FAULT_PC = 32'd32;
    localparam [31:0] SQUASHED_M_PC = 32'd36;
    localparam [31:0] RESUMED_M_PC = 32'd40;
    localparam [31:0] HANDLER_PC = 32'd128;

    integer phase;
    integer squashed_m_retire_count;
    integer resumed_m_retire_count;

    always @(posedge clock) begin
        if (dut.trace_valid &&
            (dut.trace_instruction[6:0] == 7'b0110011) &&
            (dut.trace_instruction[31:25] == 7'b0000001)) begin
            if (dut.trace_pc == SQUASHED_M_PC) begin
                squashed_m_retire_count = squashed_m_retire_count + 1;
            end
            if (dut.trace_pc == RESUMED_M_PC) begin
                resumed_m_retire_count = resumed_m_retire_count + 1;
            end
        end
    end

    task install_common_program;
        begin
            dut.IMemory[0] = i_type(HANDLER_PC[11:0], 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[2] = {20'h00001, 5'd2, 7'b0110111}; // lui x2, 1 -> 0x1000
            dut.IMemory[3] = i_type(12'd6, 5'd0, 3'b000, 5'd3, 7'b0010011);
            dut.IMemory[4] = i_type(12'd7, 5'd0, 3'b000, 5'd4, 7'b0010011);
            dut.IMemory[5] = i_type(12'd0, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[6] = i_type(12'd100, 5'd0, 3'b000, 5'd8, 7'b0010011);
            dut.IMemory[7] = i_type(12'd5, 5'd0, 3'b000, 5'd9, 7'b0010011);

            // Skip both the faulting instruction and the squashed younger M
            // instruction, then execute a different M operation after mret.
            dut.IMemory[32] = i_type(12'h341, 5'd0, 3'b010, 5'd10, 7'b1110011);
            dut.IMemory[33] = i_type(12'd8, 5'd10, 3'b000, 5'd10, 7'b0010011);
            dut.IMemory[34] = i_type(12'h341, 5'd10, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[35] = i_type(12'd0, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[36] = 32'h3020_0073;
        end
    endtask

    task observe_fault_squash;
        input [31:0] expected_cause;
        begin
            while (!(dut.memory_access_fault_taken &&
                     dut.IDEXMExtension &&
                     (dut.IDEXPC == SQUASHED_M_PC))) begin
                @(negedge clock);
            end

            if (dut.cache_miss !== 1'b0) begin
                $display("FAIL: phase %0d out-of-range access also raised cache_miss", phase);
                $fatal;
            end
            if (dut.rv32m_start !== 1'b0) begin
                $display("FAIL: phase %0d started younger RV32M on trap acceptance", phase);
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dut.RV32MInFlight !== 1'b0 ||
                dut.RV32MResultReady !== 1'b0 ||
                dut.rv32m_busy !== 1'b0) begin
                $display("FAIL: phase %0d retained squashed RV32M state inflight=%b ready=%b busy=%b",
                         phase, dut.RV32MInFlight, dut.RV32MResultReady, dut.rv32m_busy);
                $fatal;
            end

            run_cycles(260);

            if (dut.CSRmcause !== expected_cause) begin
                $display("FAIL: phase %0d mcause expected %h got %h",
                         phase, expected_cause, dut.CSRmcause);
                $fatal;
            end
            if (dut.Regs[10] !== RESUMED_M_PC) begin
                $display("FAIL: phase %0d handler observed/advanced mepc to %h",
                         phase, dut.Regs[10]);
                $fatal;
            end
            if (squashed_m_retire_count != 0 || resumed_m_retire_count != 1) begin
                $display("FAIL: phase %0d M retire counts squashed=%0d resumed=%0d",
                         phase, squashed_m_retire_count, resumed_m_retire_count);
                $fatal;
            end
            if (dut.RV32MInFlight !== 1'b0 || dut.RV32MResultReady !== 1'b0) begin
                $display("FAIL: phase %0d ended with stale RV32M tracking state", phase);
                $fatal;
            end
        end
    endtask

    task run_load_fault_phase;
        begin
            phase = 1;
            squashed_m_retire_count = 0;
            resumed_m_retire_count = 0;
            reset_cpu();
            install_common_program();

            dut.IMemory[8] = i_type(12'd0, 5'd2, 3'b010, 5'd5, 7'b0000011);
            dut.IMemory[9] = r_type(7'b0000001, 5'd4, 5'd3, 3'b000, 5'd6, 7'b0110011);
            dut.IMemory[10] = r_type(7'b0000001, 5'd9, 5'd8, 3'b100, 5'd7, 7'b0110011);
            dut.IMemory[11] = i_type(12'd1, 5'd0, 3'b000, 5'd11, 7'b0010011);
            dut.IMemory[12] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            observe_fault_squash(32'd5);
            check_reg(6, 32'd0);
            check_reg(7, 32'd20);
            check_reg(11, 32'd1);
        end
    endtask

    task run_store_fault_phase;
        begin
            phase = 2;
            squashed_m_retire_count = 0;
            resumed_m_retire_count = 0;
            reset_cpu();
            install_common_program();

            dut.IMemory[8] = s_type(12'd0, 5'd3, 5'd2, 3'b010, 7'b0100011);
            dut.IMemory[9] = r_type(7'b0000001, 5'd9, 5'd8, 3'b100, 5'd7, 7'b0110011);
            dut.IMemory[10] = r_type(7'b0000001, 5'd4, 5'd3, 3'b000, 5'd6, 7'b0110011);
            dut.IMemory[11] = i_type(12'd1, 5'd0, 3'b000, 5'd11, 7'b0010011);
            dut.IMemory[12] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            observe_fault_squash(32'd7);
            check_reg(6, 32'd42);
            check_reg(7, 32'd0);
            check_reg(11, 32'd1);
        end
    endtask

    initial begin
        $dumpfile("wave/tb_assert_rv32m_trap_squash.vcd");
        $dumpvars(0, tb_assert_rv32m_trap_squash);

        run_load_fault_phase();
        run_store_fault_phase();

        $display("PASS: tb_assert_rv32m_trap_squash passed");
        $finish;
    end

endmodule
