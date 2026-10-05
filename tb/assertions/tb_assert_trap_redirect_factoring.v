`timescale 1ns / 1ps

// Purpose: Checks factored precise trap, interrupt-entry, and redirect control.
// Checks: Stall-independent eligibility, accepted-entry guards, redirect application equivalence, MEIP priority, precise mtval, and single interrupt entry.
// Pass condition: Requested versus accepted redirect semantics match their contracts and CPU-level concurrent trap cases preserve exact CSR state.
// Assertion focus: Short-path redirect factoring must preserve accepted trap priority and one-shot CSR side effects.

module tb_assert_trap_redirect_factoring;

`include "tb_common.vh"

    localparam [6:0] STORE = 7'b0100011;
    localparam [6:0] BRANCH = 7'b1100011;

    reg factor_reset;
    reg factor_valid;
    reg factor_pending;
    reg factor_control_pending;
    reg factor_deferred;
    reg factor_is_control;
    reg factor_is_m_extension;
    reg factor_dcache_stall;
    reg factor_exception;
    reg factor_mret;
    wire factor_eligible;
    wire factor_interrupt;
    wire factor_redirect;
    wire factor_if_redirect = !factor_dcache_stall && factor_redirect;

    integer interrupt_pulses;
    integer exception_pulses;
    integer trap_pulses;
    reg monitor_cpu;
    reg [12:0] frontend_inputs;
    wire frontend_stall = frontend_inputs[4] | frontend_inputs[5];
    wire frontend_legal = !frontend_inputs[8];
    wire frontend_valid = frontend_inputs[0];
    wire frontend_control = frontend_inputs[1];
    wire frontend_busy = frontend_inputs[2];
    wire frontend_memory_fault = frontend_inputs[3];
    wire frontend_memory_hold = frontend_inputs[4];
    wire frontend_alignment = frontend_inputs[6];
    wire frontend_cancel = frontend_inputs[7];
    wire frontend_mret = frontend_inputs[9];
    wire frontend_interrupt = frontend_inputs[10];
    wire frontend_fetch_hold = frontend_inputs[11];
    wire frontend_load_use = frontend_inputs[12];

    // Exercise the integrated combinational cone with independent boundary
    // inputs. The reference below retains the pre-factoring equations.
    task check_frontend_equivalence;
        integer combination;
        reg stalled;
        reg old_exception;
        reg old_mret;
        reg old_eligible;
        reg old_interrupt;
        reg old_redirect;
        reg [31:0] old_target;
        reg [31:0] old_next_pc;
        begin
            reset_cpu();
            @(negedge clock);
            force clock = 1'b0;
            force dut.IDEXValid = frontend_valid;
            force dut.ControlRedirectPending = frontend_control;
            force dut.rv32m_execute_stall = frontend_busy;
            force dut.memory_access_fault_detect = frontend_memory_fault;
            force dut.memory_access_fault_stall = frontend_memory_hold;
            force dut.dcache_pipeline_stall = frontend_stall;
            force dut.InstructionMisalignPending = frontend_alignment;
            force dut.InstructionMisalignCancel = frontend_cancel;
            force dut.is_legal_instruction = frontend_legal;
            force dut.is_mret = frontend_mret;
            force dut.machine_interrupt_pending = frontend_interrupt;
            force dut.icache_pipeline_stall = frontend_fetch_hold;
            force dut.load_use_hazard = frontend_load_use;
            force dut.IDEXBranch = 1'b0;
            force dut.IDEXJump = 1'b0;
            force dut.IDEXMExtension = 1'b0;
            force dut.instruction_access_fault = 1'b0;
            force dut.is_ecall = 1'b0;
            force dut.is_ebreak = 1'b0;
            force dut.is_misaligned_access = 1'b0;
            force dut.CSRmtvec = 32'h100;
            force dut.CSRmepc = 32'h200;
            force dut.ControlRedirectPC = 32'h300;
            force dut.final_predicted_pc = 32'h400;
            force dut.PC = 32'h500;
            for (combination = 0; combination < 8192; combination = combination + 1) begin
                frontend_inputs = combination;
                #1;
                stalled = frontend_inputs[4] || frontend_inputs[5];
                old_exception =
                    (frontend_inputs[3] && !frontend_inputs[4]) ||
                    (frontend_inputs[0] && !frontend_inputs[1] && !stalled &&
                     !frontend_inputs[2] && !frontend_inputs[3] && frontend_inputs[8]) ||
                    (frontend_inputs[6] && !frontend_inputs[7] && !stalled);
                old_mret = !frontend_inputs[1] && !frontend_inputs[3] &&
                           frontend_inputs[0] && frontend_inputs[9];
                old_eligible = frontend_inputs[0] && !frontend_inputs[1] && frontend_inputs[10];
                old_interrupt = old_eligible && !stalled && !old_exception && !old_mret;
                old_redirect = old_exception || old_mret || old_eligible || frontend_inputs[1];
                old_target = old_exception ? 32'h100 :
                             old_interrupt ? 32'h100 :
                             old_mret ? 32'h200 : 32'h300;
                old_next_pc = stalled ? 32'h500 : old_redirect ? old_target :
                              (frontend_inputs[2] || frontend_inputs[11] || frontend_inputs[12]) ?
                              32'h500 : 32'h400;
                if (dut.exception_taken !== old_exception ||
                    dut.interrupt_taken !== old_interrupt ||
                    dut.if_redirect !== (!stalled && old_redirect) ||
                    dut.pc_next_value !== old_next_pc ||
                    dut.id_hold !== (stalled || (!old_redirect && frontend_inputs[2])) ||
                    dut.id_bubble !== (!stalled && (old_redirect ||
                        (!frontend_inputs[2] && (frontend_inputs[11] || frontend_inputs[12])))) ||
                    dut.id_advance !== (!stalled && !old_redirect && !frontend_inputs[2] &&
                        !frontend_inputs[11] && !frontend_inputs[12])) begin
                    $display("FAIL: frontend factoring differs at input combination %h", frontend_inputs);
                    $fatal;
                end
            end
            release dut.IDEXValid;
            release dut.ControlRedirectPending;
            release dut.rv32m_execute_stall;
            release dut.memory_access_fault_detect;
            release dut.memory_access_fault_stall;
            release dut.dcache_pipeline_stall;
            release dut.InstructionMisalignPending;
            release dut.InstructionMisalignCancel;
            release dut.is_legal_instruction;
            release dut.is_mret;
            release dut.machine_interrupt_pending;
            release dut.icache_pipeline_stall;
            release dut.load_use_hazard;
            release dut.IDEXBranch;
            release dut.IDEXJump;
            release dut.IDEXMExtension;
            release dut.instruction_access_fault;
            release dut.is_ecall;
            release dut.is_ebreak;
            release dut.is_misaligned_access;
            release dut.CSRmtvec;
            release dut.CSRmepc;
            release dut.ControlRedirectPC;
            release dut.final_predicted_pc;
            release dut.PC;
            release clock;
            $display("PASS: 8192 frontend input combinations match the prior acceptance and PC equations");
        end
    endtask

    trap_redirect_control_unit factor_dut (
        .reset(factor_reset),
        .instruction_valid(factor_valid),
        .machine_interrupt_pending(factor_pending),
        .control_redirect_pending(factor_control_pending),
        .control_interrupt_deferred(factor_deferred),
        .instruction_is_control(factor_is_control),
        .instruction_is_m_extension(factor_is_m_extension),
        .dcache_pipeline_stall(factor_dcache_stall),
        .exception_taken(factor_exception),
        .exception_pending(factor_exception),
        .mret_taken(factor_mret),
        .interrupt_eligible(factor_eligible),
        .interrupt_taken(factor_interrupt),
        .redirect_taken(factor_redirect)
    );

    always @(posedge clock) begin
        if (!reset && monitor_cpu) begin
            if (dut.interrupt_taken) interrupt_pulses = interrupt_pulses + 1;
            if (dut.exception_taken) exception_pulses = exception_pulses + 1;
            if (dut.trap_taken) trap_pulses = trap_pulses + 1;
        end
    end

    task factor_defaults;
    begin
        factor_reset = 1'b0;
        factor_valid = 1'b1;
        factor_pending = 1'b0;
        factor_control_pending = 1'b0;
        factor_deferred = 1'b0;
        factor_is_control = 1'b0;
        factor_is_m_extension = 1'b0;
        factor_dcache_stall = 1'b0;
        factor_exception = 1'b0;
        factor_mret = 1'b0;
    end
    endtask

    task check_factor;
        input [8*48-1:0] name;
        input expected_eligible;
        input expected_interrupt;
        input expected_redirect;
        input expected_if_redirect;
        reg old_eligible;
        reg old_interrupt;
        reg old_if_redirect;
    begin
        #1;
        old_eligible =
            !factor_reset && factor_valid && factor_pending &&
            !factor_control_pending &&
            (!factor_is_control || factor_deferred) &&
            !factor_is_m_extension;
        old_interrupt =
            old_eligible && !factor_dcache_stall &&
            !factor_exception && !factor_mret;
        old_if_redirect =
            !factor_dcache_stall &&
            (factor_exception || factor_mret || old_interrupt || factor_control_pending);

        if (factor_eligible !== expected_eligible ||
            factor_interrupt !== expected_interrupt ||
            factor_redirect !== expected_redirect ||
            factor_if_redirect !== expected_if_redirect) begin
            $display("FAIL: %0s got eligible=%0b interrupt=%0b request=%0b apply=%0b",
                     name, factor_eligible, factor_interrupt,
                     factor_redirect, factor_if_redirect);
            $fatal;
        end
        if (factor_eligible !== old_eligible ||
            factor_interrupt !== old_interrupt ||
            factor_if_redirect !== old_if_redirect) begin
            $display("FAIL: %0s differs from accepted interrupt/redirect formula", name);
            $fatal;
        end
    end
    endtask

    task clear_cpu_counts;
    begin
        interrupt_pulses = 0;
        exception_pulses = 0;
        trap_pulses = 0;
    end
    endtask

    task run_interrupt_priority_once;
        reg [31:0] captured_mepc;
    begin
        reset_cpu();
        dut.IMemory[16] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
        dut.csr_unit_inst.mstatus = 32'h0000_1808;
        dut.csr_unit_inst.mie = 32'h0000_0880;
        dut.csr_unit_inst.mtvec = 32'd64;
        clear_cpu_counts();
        monitor_cpu = 1'b1;
        force dut.timer_irq_pending = 1'b1;
        force dut.matvec_irq_pending = 1'b1;

        while (!dut.interrupt_taken) @(negedge clock);
        #1;
        if (!dut.interrupt_eligible ||
            (dut.machine_interrupt_cause !== 32'h8000_000b) ||
            !dut.redirect_taken || (dut.redirect_pc !== 32'd64)) begin
            $display("FAIL: simultaneous MEIP/MTIP did not select external interrupt");
            $fatal;
        end

        @(posedge clock);
        #1;
        captured_mepc = dut.CSRmepc;
        repeat (8) @(posedge clock);
        #1;
        if (interrupt_pulses != 1 || exception_pulses != 0 || trap_pulses != 1 ||
            (dut.CSRmcause !== 32'h8000_000b) ||
            (dut.CSRmtval !== 32'h0) ||
            (dut.CSRmepc !== captured_mepc)) begin
            $display("FAIL: accepted interrupt side effects repeated or changed CSR state");
            $fatal;
        end

        release dut.timer_irq_pending;
        release dut.matvec_irq_pending;
        monitor_cpu = 1'b0;
    end
    endtask

    task run_misaligned_store_beats_interrupt;
    begin
        reset_cpu();
        dut.Regs[1] = 32'h1234_5fff;
        dut.Regs[2] = 32'hfeed_cafe;
        dut.IMemory[0] = s_type(12'd2, 5'd2, 5'd1, 3'b010, STORE);
        dut.IMemory[16] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
        dut.csr_unit_inst.mstatus = 32'h0000_1808;
        dut.csr_unit_inst.mie = 32'h0000_0800;
        dut.csr_unit_inst.mtvec = 32'd64;
        clear_cpu_counts();
        monitor_cpu = 1'b1;
        force dut.matvec_irq_pending = 1'b1;

        while (!(dut.IDEXValid && (dut.IDEXPC == 32'd0))) @(negedge clock);
        #1;
        if ((dut.store_address_low !== 2'b01) ||
            !dut.interrupt_eligible || !dut.exception_taken ||
            dut.interrupt_taken || !dut.redirect_taken ||
            (dut.redirect_pc !== 32'd64) ||
            (dut.exception_tval !== 32'h1234_6001)) begin
            $display("FAIL: misaligned store did not retain exception priority over interrupt");
            $fatal;
        end

        @(posedge clock);
        #1;
        release dut.matvec_irq_pending;
        repeat (5) @(posedge clock);
        #1;
        monitor_cpu = 1'b0;
        if (exception_pulses != 1 || interrupt_pulses != 0 || trap_pulses != 1 ||
            (dut.CSRmepc !== 32'd0) || (dut.CSRmcause !== 32'd6) ||
            (dut.CSRmtval !== 32'h1234_6001) || (dut.DMemory[0] !== 32'h0)) begin
            $display("FAIL: concurrent misaligned-store trap lost precise CSR/store state");
            $fatal;
        end
    end
    endtask

    initial begin
        #100000;
        $fatal(1, "Timed out waiting for trap/interrupt acceptance");
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_trap_redirect_factoring.vcd");
        $dumpvars(0, tb_assert_trap_redirect_factoring);
        monitor_cpu = 1'b0;
        clear_cpu_counts();

        factor_defaults();
        check_factor("no exception or interrupt", 0, 0, 0, 0);

        factor_defaults();
        factor_exception = 1'b1;
        check_factor("exception only", 0, 0, 1, 1);

        factor_defaults();
        factor_pending = 1'b1;
        check_factor("interrupt request only", 1, 1, 1, 1);

        factor_defaults();
        factor_mret = 1'b1;
        check_factor("mret only", 0, 0, 1, 1);

        factor_defaults();
        factor_pending = 1'b1;
        factor_exception = 1'b1;
        check_factor("exception beats interrupt request", 1, 0, 1, 1);

        factor_defaults();
        factor_pending = 1'b1;
        factor_mret = 1'b1;
        check_factor("mret beats interrupt request", 1, 0, 1, 1);

        factor_defaults();
        factor_pending = 1'b1;
        factor_control_pending = 1'b1;
        check_factor("pending redirect blocks interrupt", 0, 0, 1, 1);

        factor_defaults();
        factor_pending = 1'b1;
        factor_is_control = 1'b1;
        check_factor("unresolved control blocks interrupt", 0, 0, 0, 0);

        factor_deferred = 1'b1;
        check_factor("deferred control permits interrupt", 1, 1, 1, 1);

        factor_defaults();
        factor_pending = 1'b1;
        factor_dcache_stall = 1'b1;
        check_factor("dcache stall defers interrupt acceptance", 1, 0, 1, 0);

        factor_exception = 1'b1;
        check_factor("stalled exception retains priority", 1, 0, 1, 0);

        factor_exception = 1'b0;
        factor_mret = 1'b1;
        check_factor("stalled mret retains priority", 1, 0, 1, 0);

        factor_defaults();
        factor_pending = 1'b1;
        factor_is_m_extension = 1'b1;
        check_factor("multicycle M instruction blocks interrupt", 0, 0, 0, 0);

        factor_defaults();
        factor_pending = 1'b1;
        factor_reset = 1'b1;
        check_factor("reset blocks interrupt", 0, 0, 0, 0);

        check_frontend_equivalence();
        run_interrupt_priority_once();
        run_misaligned_store_beats_interrupt();

        $display("PASS: factored trap redirect preserved truth table, priority, and precise CSR effects");
        $display("PASS: tb_assert_trap_redirect_factoring passed");
        $finish;
    end

endmodule
