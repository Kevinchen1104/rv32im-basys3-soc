`timescale 1ns / 1ps

// Purpose: Checks the integrated core's trap metadata capture/commit timing.
// Checks: Accepted exceptions and interrupts redirect and clear mstatus.MIE immediately, register one metadata
//   event, commit aligned mepc/mcause/full mtval one edge later, expose committed values to the first handler CSR
//   reads, preserve mret behavior, suppress wrong-path CSR writes, and accept a stalled interrupt exactly once.
// Pass condition: All directed exception, interrupt, priority, handler-read, mret, and reset phases pass.
// Standalone CSR tests check back-to-back metadata capture and commit.

module tb_assert_registered_trap_metadata_commit;

`include "tb_common.vh"

    localparam [6:0] LOAD = 7'b0000011;
    localparam [6:0] STORE = 7'b0100011;
    localparam [6:0] OP_IMM = 7'b0010011;
    localparam [6:0] BRANCH = 7'b1100011;
    localparam [6:0] SYSTEM = 7'b1110011;
    localparam [31:0] ILLEGAL = 32'hffff_ffff;
    localparam [31:0] ECALL = 32'h0000_0073;
    localparam [31:0] EBREAK = 32'h0010_0073;
    localparam [31:0] MRET = 32'h3020_0073;
    localparam [31:0] HANDLER_PC = 32'd64;

    integer trap_pulses = 0;
    integer wait_cycles = 0;
    reg monitor_traps = 1'b0;
    reg previous_trap = 1'b0;

    always @(posedge clock) begin
        if (reset) begin
            previous_trap <= 1'b0;
        end else begin
            if (monitor_traps && dut.trap_taken)
                trap_pulses = trap_pulses + 1;
            if (monitor_traps && previous_trap && dut.trap_taken) begin
                $display("FAIL: integrated core accepted traps on consecutive cycles");
                $fatal;
            end
            previous_trap <= dut.trap_taken;
        end
    end

    task fail;
        input [511:0] message;
        begin
            $display("FAIL: %0s", message);
            $fatal;
        end
    endtask

    task check32;
        input [511:0] label;
        input [31:0] actual;
        input [31:0] expected;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected=%08x actual=%08x", label, expected, actual);
                $fatal;
            end
        end
    endtask

    task wait_for_trap_request;
        begin
            wait_cycles = 0;
            while (!dut.trap_taken && (wait_cycles < 160)) begin
                @(negedge clock);
                wait_cycles = wait_cycles + 1;
            end
            if (!dut.trap_taken)
                fail("timeout waiting for accepted trap");
            #1;
            if (!dut.if_redirect || !dut.redirect_taken ||
                (dut.redirect_pc !== HANDLER_PC))
                fail("accepted trap did not request immediate handler redirect");
        end
    endtask

    task check_trap_capture_commit;
        input [31:0] expected_mepc;
        input [31:0] expected_mcause;
        input [31:0] expected_mtval;
        reg [31:0] old_mepc;
        reg [31:0] old_mcause;
        reg [31:0] old_mtval;
        begin
            wait_for_trap_request();
            old_mepc = dut.CSRmepc;
            old_mcause = dut.CSRmcause;
            old_mtval = dut.CSRmtval;

            @(posedge clock);
            #1;
            check32("trap edge redirects PC", dut.PC, HANDLER_PC);
            if (dut.CSRmstatus[3] !== 1'b0)
                fail("trap edge did not clear mstatus.MIE immediately");
            if (dut.csr_unit_inst.trap_metadata_pending !== 1'b1)
                fail("trap edge did not register metadata pending");
            check32("trap edge preserves old mepc", dut.CSRmepc, old_mepc);
            check32("trap edge preserves old mcause", dut.CSRmcause, old_mcause);
            check32("trap edge preserves old mtval", dut.CSRmtval, old_mtval);

            @(posedge clock);
            #1;
            if (dut.csr_unit_inst.trap_metadata_pending !== 1'b0)
                fail("metadata pipeline did not drain after one commit edge");
            check32("registered commit mepc", dut.CSRmepc, expected_mepc);
            check32("registered commit mcause", dut.CSRmcause, expected_mcause);
            check32("registered commit mtval", dut.CSRmtval, expected_mtval);
        end
    endtask

    task seed_handler_loop;
        begin
            dut.IMemory[HANDLER_PC >> 2] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
        end
    endtask

    task run_illegal_handler_read_mret;
        begin
            reset_cpu();
            // Configure mtvec, trap on an illegal instruction, and place a
            // wrong-path mcause write behind it. The handler reads metadata as
            // its first three instructions, writes a resume mepc, then mret.
            dut.IMemory[0] = i_type(HANDLER_PC[11:0], 5'd0, 3'b000, 5'd1, OP_IMM);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, SYSTEM);
            dut.IMemory[2] = ILLEGAL;
            dut.IMemory[3] = i_type(12'd99, 5'd0, 3'b000, 5'd5, OP_IMM);
            dut.IMemory[4] = i_type(12'h342, 5'd5, 3'b001, 5'd0, SYSTEM);
            dut.IMemory[5] = i_type(12'd88, 5'd0, 3'b000, 5'd15, OP_IMM);
            dut.IMemory[6] = i_type(12'd77, 5'd0, 3'b000, 5'd14, OP_IMM);
            dut.IMemory[7] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);

            dut.IMemory[16] = i_type(12'h341, 5'd0, 3'b010, 5'd10, SYSTEM);
            dut.IMemory[17] = i_type(12'h342, 5'd0, 3'b010, 5'd11, SYSTEM);
            dut.IMemory[18] = i_type(12'h343, 5'd0, 3'b010, 5'd12, SYSTEM);
            dut.IMemory[19] = i_type(12'd24, 5'd0, 3'b000, 5'd13, OP_IMM);
            dut.IMemory[20] = i_type(12'h341, 5'd13, 3'b001, 5'd0, SYSTEM);
            dut.IMemory[21] = MRET;

            trap_pulses = 0;
            monitor_traps = 1'b1;
            check_trap_capture_commit(32'd8, 32'd2, ILLEGAL);
            run_cycles(120);
            monitor_traps = 1'b0;

            check32("handler first read mepc", dut.Regs[10], 32'd8);
            check32("handler second read mcause", dut.Regs[11], 32'd2);
            check32("handler third read mtval", dut.Regs[12], ILLEGAL);
            check32("mret resumed at programmed mepc", dut.Regs[14], 32'd77);
            check32("wrong-path addi remained suppressed", dut.Regs[5], 32'd5);
            check32("wrong-path instruction after CSR remained suppressed", dut.Regs[15], 32'd15);
            check32("wrong-path mcause write remained suppressed", dut.CSRmcause, 32'd2);
            if (trap_pulses != 1)
                fail("illegal trap retriggered or was not accepted exactly once");
        end
    endtask

    task run_simple_exception;
        input [31:0] instruction;
        input [31:0] expected_cause;
        input [31:0] expected_tval;
        begin
            reset_cpu();
            dut.csr_unit_inst.mtvec = HANDLER_PC;
            dut.IMemory[0] = instruction;
            seed_handler_loop();
            trap_pulses = 0;
            monitor_traps = 1'b1;
            check_trap_capture_commit(32'd0, expected_cause, expected_tval);
            run_cycles(20);
            monitor_traps = 1'b0;
            if (trap_pulses != 1)
                fail("simple exception was not accepted exactly once");
        end
    endtask

    task run_misaligned_load;
        begin
            reset_cpu();
            dut.csr_unit_inst.mtvec = HANDLER_PC;
            dut.IMemory[0] = 32'h8000_0437; // lui x8, 0x80000
            dut.IMemory[1] = i_type(12'd2, 5'd8, 3'b010, 5'd9, LOAD);
            seed_handler_loop();
            check_trap_capture_commit(32'd4, 32'd4, 32'h8000_0002);
            check32("misaligned load destination suppressed", dut.Regs[9], 32'd9);
        end
    endtask

    task run_misaligned_store;
        begin
            reset_cpu();
            dut.csr_unit_inst.mtvec = HANDLER_PC;
            dut.IMemory[0] = 32'h8000_0437; // lui x8, 0x80000
            dut.IMemory[1] = s_type(12'd2, 5'd5, 5'd8, 3'b010, STORE);
            seed_handler_loop();
            check_trap_capture_commit(32'd4, 32'd6, 32'h8000_0002);
        end
    endtask

    task run_timer_stall_release;
        integer stall_index;
        reg [31:0] accepted_pc;
        begin
            reset_cpu();
            dut.csr_unit_inst.mstatus = 32'h0000_1808;
            dut.csr_unit_inst.mie = 32'h0000_0080;
            dut.csr_unit_inst.mtvec = HANDLER_PC;
            seed_handler_loop();

            wait_cycles = 0;
            while (!dut.IDEXValid && (wait_cycles < 100)) begin
                @(negedge clock);
                wait_cycles = wait_cycles + 1;
            end
            if (!dut.IDEXValid)
                fail("timer phase did not reach a valid execute instruction");
            force dut.cache_miss = 1'b1;
            #1;
            if (!dut.dcache_pipeline_stall)
                fail("timer phase failed to establish D-cache pipeline stall");
            force dut.timer_irq_pending = 1'b1;

            wait_cycles = 0;
            while (!dut.interrupt_eligible && (wait_cycles < 100)) begin
                @(negedge clock);
                wait_cycles = wait_cycles + 1;
            end
            if (!dut.interrupt_eligible)
                fail("timer interrupt did not become eligible during D-cache stall");
            for (stall_index = 0; stall_index < 3; stall_index = stall_index + 1) begin
                @(posedge clock);
                #1;
                if (dut.interrupt_taken || dut.csr_unit_inst.trap_metadata_pending)
                    fail("D-cache stall accepted interrupt or metadata early");
            end

            @(negedge clock);
            accepted_pc = dut.IDEXPC;
            release dut.cache_miss;
            #1;
            trap_pulses = 0;
            monitor_traps = 1'b1;
            check_trap_capture_commit({accepted_pc[31:2], 2'b00}, 32'h8000_0007, 32'h0);
            release dut.timer_irq_pending;
            run_cycles(20);
            monitor_traps = 1'b0;
            if (trap_pulses != 1)
                fail("timer interrupt was not accepted exactly once after stall release");
        end
    endtask

    task run_external_priority;
        reg [31:0] accepted_pc;
        begin
            reset_cpu();
            dut.csr_unit_inst.mstatus = 32'h0000_1808;
            dut.csr_unit_inst.mie = 32'h0000_0880;
            dut.csr_unit_inst.mtvec = HANDLER_PC;
            seed_handler_loop();
            force dut.timer_irq_pending = 1'b1;
            force dut.matvec_irq_pending = 1'b1;
            trap_pulses = 0;
            monitor_traps = 1'b1;
            wait_for_trap_request();
            check32("MEIP priority cause before capture", dut.trap_cause, 32'h8000_000b);
            accepted_pc = dut.IDEXPC;
            @(posedge clock);
            #1;
            if (dut.CSRmstatus[3] ||
                (dut.csr_unit_inst.trap_metadata_pending !== 1'b1))
                fail("external interrupt did not update status/register pending immediately");
            @(posedge clock);
            #1;
            check32("external interrupt mepc", dut.CSRmepc, {accepted_pc[31:2], 2'b00});
            check32("MEIP wins over MTIP", dut.CSRmcause, 32'h8000_000b);
            check32("external interrupt mtval", dut.CSRmtval, 32'h0);
            release dut.timer_irq_pending;
            release dut.matvec_irq_pending;
            run_cycles(20);
            monitor_traps = 1'b0;
            if (trap_pulses != 1)
                fail("external interrupt retriggered or was not accepted exactly once");
        end
    endtask

    task run_reset_cancels_pending;
        begin
            reset_cpu();
            dut.csr_unit_inst.mtvec = HANDLER_PC;
            dut.IMemory[0] = ILLEGAL;
            seed_handler_loop();
            wait_for_trap_request();
            @(posedge clock);
            #1;
            if (dut.csr_unit_inst.trap_metadata_pending !== 1'b1)
                fail("reset phase did not create pending metadata");
            reset = 1'b1;
            @(posedge clock);
            #1;
            reset = 1'b0;
            if (dut.csr_unit_inst.trap_metadata_pending !== 1'b0)
                fail("reset did not clear pending metadata event");
            check32("reset clears mepc", dut.CSRmepc, 32'h0);
            check32("reset clears mcause", dut.CSRmcause, 32'h0);
            check32("reset clears mtval", dut.CSRmtval, 32'h0);
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_registered_trap_metadata_commit.vcd");
        $dumpvars(0, tb_assert_registered_trap_metadata_commit);

        run_illegal_handler_read_mret();
        run_simple_exception(ECALL, 32'd11, 32'h0);
        run_simple_exception(EBREAK, 32'd3, 32'h0);
        run_misaligned_load();
        run_misaligned_store();
        run_timer_stall_release();
        run_external_priority();
        run_reset_cancels_pending();

        $display("PASS: registered trap metadata capture/commit remained precise");
        $display("PASS: tb_assert_registered_trap_metadata_commit passed");
        $finish;
    end

endmodule
