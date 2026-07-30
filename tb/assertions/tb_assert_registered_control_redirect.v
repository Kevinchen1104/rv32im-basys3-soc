`timescale 1ns / 1ps

// Testbench: tb_assert_registered_control_redirect
// Purpose: Exercises registered branch/jump recovery and its precise side-effect boundary.
// Checks: Independent target/fallthrough/outcome capture, accepted target/RAS-update equivalence,
//   recovery separation, branch/JAL/JALR targets and predictions, forwarding, back-to-back resolutions,
//   stalled/deferred-interrupt call acceptance, non-RAS trap exclusion, RV32M dependencies,
//   single retirement/update/count events, and wrong-path register/memory/MMIO/CSR/trap/M-start suppression.
// Pass condition: Every directed phase reaches its target with exactly one accepted/apply event and no forbidden side effect.
// Does not prove: Directed pipeline scenarios only; not exhaustive control flow, interrupt timing, or formal correctness.
// Assertion focus: Raw EX mispredicts register one recovery request; only the pending request can flush the frontend.

module tb_assert_registered_control_redirect;

`include "tb_common.vh"

    localparam [6:0] ALUR = 7'b0110011;
    localparam [6:0] ALUI = 7'b0010011;
    localparam [6:0] BRANCH = 7'b1100011;
    localparam [6:0] JAL = 7'b1101111;
    localparam [6:0] JALR = 7'b1100111;
    localparam [6:0] LOAD = 7'b0000011;
    localparam [6:0] STORE = 7'b0100011;
    localparam [6:0] SYSTEM = 7'b1110011;

    localparam integer WRONG_STORE = 1;
    localparam integer WRONG_GPIO = 2;
    localparam integer WRONG_CSR = 3;
    localparam integer WRONG_ILLEGAL = 4;
    localparam integer WRONG_RV32M = 5;

    reg monitoring = 1'b0;
    reg timer_phase = 1'b0;
    reg timer_forced = 1'b0;
    reg timer_released = 1'b0;
    reg check_operands = 1'b0;
    reg [31:0] tracked_pc;
    reg [31:0] tracked_pc_secondary;
    reg [31:0] tracked_target;
    reg [31:0] wrong_pc;
    reg [31:0] expected_a;
    reg [31:0] expected_b;
    integer capture_count;
    integer apply_count;
    integer retire_count;
    integer resolution_count;
    integer secondary_resolution_count;
    integer secondary_retire_count;
    integer predictor_update_count;
    integer ras_call_update_count;
    integer ras_return_update_count;
    integer ras_update_accept_count;
    integer wrong_rv32m_start_count;
    reg saw_pending;
    reg saw_counter_increment;
    reg saw_target_capture;
    reg target_capture_check_pending;
    reg candidate_capture_check_pending;
    reg [31:0] expected_target_candidate;
    reg [31:0] expected_fallthrough_candidate;
    reg [31:0] expected_redirect_pc;
    reg expected_use_fallthrough;
    integer candidate_capture_count;
    integer candidate_check_count;
    reg primary_was_previous_resolution;
    reg saw_back_to_back_resolution;
    reg [31:0] branch_miss_before;
    reg branch_counter_check_pending;
    reg [31:0] timer_interrupt_pc;

    always @(posedge clock) begin
        if (!reset &&
            (dut.ras_update_accept !==
             (dut.control_resolution_accept &&
              (dut.ras_update_is_call || dut.ras_update_is_return) &&
              (dut.control_target_address[1:0] == 2'b00)))) begin
            $display("FAIL: dedicated RAS acceptance diverged from accepted call/return semantics");
            $fatal;
        end

        if (monitoring) begin
            if (candidate_capture_check_pending) begin
                if ((dut.ControlRedirectTargetPC !== expected_target_candidate) ||
                    (dut.ControlRedirectFallthroughPC !== expected_fallthrough_candidate) ||
                    (dut.ControlRedirectUseFallthrough !== expected_use_fallthrough) ||
                    (dut.ControlRedirectPC !== expected_redirect_pc)) begin
                    $display("FAIL: redirect candidate capture target=%h/%h fallthrough=%h/%h use=%0b/%0b final=%h/%h",
                             expected_target_candidate, dut.ControlRedirectTargetPC,
                             expected_fallthrough_candidate, dut.ControlRedirectFallthroughPC,
                             expected_use_fallthrough, dut.ControlRedirectUseFallthrough,
                             expected_redirect_pc, dut.ControlRedirectPC);
                    $fatal;
                end
                candidate_capture_check_pending = 1'b0;
                candidate_check_count = candidate_check_count + 1;
            end

            if (target_capture_check_pending) begin
                if (dut.ControlRedirectPC !== tracked_target) begin
                    $display("FAIL: resolved target capture expected %h got %h",
                             tracked_target, dut.ControlRedirectPC);
                    $fatal;
                end
                target_capture_check_pending = 1'b0;
                saw_target_capture = 1'b1;
            end

            if (dut.control_resolution_accept && (dut.IDEXPC == tracked_pc)) begin
                resolution_count = resolution_count + 1;
                target_capture_check_pending = 1'b1;

                if (check_operands && ((dut.Ain !== expected_a) || (dut.Bin !== expected_b))) begin
                    $display("FAIL: forwarding at PC %h expected A=%h B=%h got A=%h B=%h",
                             tracked_pc, expected_a, expected_b, dut.Ain, dut.Bin);
                    $fatal;
                end

                if (dut.control_mispredict_accept) begin
                    capture_count = capture_count + 1;
                    if (dut.redirect_taken || dut.ControlRedirectPending) begin
                        $display("FAIL: raw control resolution directly drove redirect at PC %h", tracked_pc);
                        $fatal;
                    end
                end

                if (dut.IDEXBranch) begin
                    predictor_update_count = predictor_update_count + 1;
                    if (dut.branch_mispredict) begin
                        branch_miss_before = dut.BranchMissCount;
                        branch_counter_check_pending = 1'b1;
                    end
                end

            end

            if (dut.control_resolution_accept &&
                ((dut.IDEXPC == tracked_pc) ||
                 (dut.IDEXPC == tracked_pc_secondary))) begin
                expected_target_candidate = dut.IDEXJump ? dut.jump_target : dut.branch_target;
                expected_fallthrough_candidate = dut.IDEXPC + 32'd4;
                expected_use_fallthrough = dut.IDEXBranch && !dut.branch_taken;
                expected_redirect_pc = expected_use_fallthrough ?
                                       expected_fallthrough_candidate :
                                       expected_target_candidate;
                candidate_capture_count = candidate_capture_count + 1;
                candidate_capture_check_pending = 1'b1;
            end

            if (dut.control_resolution_accept && (dut.IDEXPC == tracked_pc_secondary)) begin
                secondary_resolution_count = secondary_resolution_count + 1;
                if (primary_was_previous_resolution) begin
                    saw_back_to_back_resolution = 1'b1;
                end
            end

            // Back-to-back refers to the accepted-control event stream; idle
            // pipeline cycles between the two resolutions do not break it.
            if (dut.control_resolution_accept) begin
                primary_was_previous_resolution = (dut.IDEXPC == tracked_pc);
            end

            if (dut.ras_update_accept) begin
                ras_update_accept_count = ras_update_accept_count + 1;
            end
            if (dut.ras_update_accept && dut.ras_update_is_call) begin
                ras_call_update_count = ras_call_update_count + 1;
            end
            if (dut.ras_update_accept && dut.ras_update_is_return) begin
                ras_return_update_count = ras_return_update_count + 1;
            end

            if (branch_counter_check_pending &&
                (dut.BranchMissCount == (branch_miss_before + 32'd1))) begin
                branch_counter_check_pending = 1'b0;
                saw_counter_increment = 1'b1;
            end

            if (dut.ControlRedirectPending &&
                (dut.ControlRedirectPC == tracked_target)) begin
                saw_pending = 1'b1;
                if (!dut.redirect_taken || (dut.redirect_pc !== tracked_target)) begin
                    $display("FAIL: pending redirect target mismatch expected %h got %h",
                             tracked_target, dut.redirect_pc);
                    $fatal;
                end
            end

            if (dut.control_redirect_apply &&
                (dut.ControlRedirectPC == tracked_target)) begin
                apply_count = apply_count + 1;
            end

            if (dut.trace_valid && (dut.trace_pc == tracked_pc)) begin
                retire_count = retire_count + 1;
            end

            if (dut.trace_valid && (dut.trace_pc == tracked_pc_secondary)) begin
                secondary_retire_count = secondary_retire_count + 1;
            end

            if ((wrong_pc != 32'hffff_ffff) &&
                dut.EXMEMValid &&
                (dut.EXMEMPC == wrong_pc)) begin
                $display("FAIL: wrong-path instruction at PC %h reached EX/MEM", wrong_pc);
                $fatal;
            end

            if ((wrong_pc != 32'hffff_ffff) &&
                dut.trace_valid &&
                (dut.trace_pc == wrong_pc)) begin
                $display("FAIL: wrong-path instruction at PC %h retired", wrong_pc);
                $fatal;
            end

            if (dut.rv32m_start && (dut.IDEXPC == wrong_pc)) begin
                wrong_rv32m_start_count = wrong_rv32m_start_count + 1;
                $display("FAIL: wrong-path RV32M operation started at PC %h", wrong_pc);
                $fatal;
            end

            if (timer_phase && dut.interrupt_taken) begin
                timer_interrupt_pc = dut.IDEXPC;
                if (dut.ControlRedirectPending) begin
                    $display("FAIL: timer interrupt entered during pending control recovery");
                    $fatal;
                end
                if (timer_forced && !timer_released) begin
                    #1;
                    release dut.timer_irq_pending;
                    timer_released = 1'b1;
                end
            end
        end
    end

    task begin_phase;
        input [31:0] control_pc;
        input [31:0] target_pc;
        input [31:0] wrong_path_pc;
        begin
            monitoring = 1'b0;
            timer_phase = 1'b0;
            timer_forced = 1'b0;
            timer_released = 1'b0;
            reset_cpu();
            tracked_pc = control_pc;
            tracked_pc_secondary = 32'hffff_ffff;
            tracked_target = target_pc;
            wrong_pc = wrong_path_pc;
            capture_count = 0;
            apply_count = 0;
            retire_count = 0;
            resolution_count = 0;
            secondary_resolution_count = 0;
            secondary_retire_count = 0;
            predictor_update_count = 0;
            ras_call_update_count = 0;
            ras_return_update_count = 0;
            ras_update_accept_count = 0;
            wrong_rv32m_start_count = 0;
            saw_pending = 1'b0;
            saw_counter_increment = 1'b0;
            saw_target_capture = 1'b0;
            target_capture_check_pending = 1'b0;
            candidate_capture_check_pending = 1'b0;
            expected_target_candidate = 32'h0;
            expected_fallthrough_candidate = 32'h0;
            expected_redirect_pc = 32'h0;
            expected_use_fallthrough = 1'b0;
            candidate_capture_count = 0;
            candidate_check_count = 0;
            primary_was_previous_resolution = 1'b0;
            saw_back_to_back_resolution = 1'b0;
            branch_counter_check_pending = 1'b0;
            branch_miss_before = dut.BranchMissCount;
            timer_interrupt_pc = 32'hffff_ffff;
            check_operands = 1'b0;
            expected_a = 32'h0;
            expected_b = 32'h0;
        end
    endtask

    task expect_forwarded_operands;
        input [31:0] value_a;
        input [31:0] value_b;
        begin
            check_operands = 1'b1;
            expected_a = value_a;
            expected_b = value_b;
        end
    endtask

    task check_redirect_phase;
        input [8*80-1:0] label;
        input integer expect_predictor_update;
        input integer expect_branch_counter;
        begin
            if ((capture_count != 1) ||
                (apply_count != 1) ||
                (retire_count != 1) ||
                (resolution_count != 1) ||
                !saw_pending ||
                !saw_target_capture ||
                target_capture_check_pending ||
                candidate_capture_check_pending ||
                (candidate_capture_count != 1) ||
                (candidate_check_count != 1)) begin
                $display("FAIL: %0s capture=%0d apply=%0d retire=%0d resolve=%0d pending=%0b target=%0b target_pending=%0b candidate=%0d checked=%0d candidate_pending=%0b",
                         label, capture_count, apply_count, retire_count,
                         resolution_count, saw_pending, saw_target_capture,
                         target_capture_check_pending, candidate_capture_count,
                         candidate_check_count, candidate_capture_check_pending);
                $fatal;
            end
            if (predictor_update_count != expect_predictor_update) begin
                $display("FAIL: %0s predictor updates expected %0d got %0d",
                         label, expect_predictor_update, predictor_update_count);
                $fatal;
            end
            if (expect_branch_counter && !saw_counter_increment) begin
                $display("FAIL: %0s branch miss counter did not increment once", label);
                $fatal;
            end
            if (branch_counter_check_pending) begin
                $display("FAIL: %0s branch miss counter update remained pending", label);
                $fatal;
            end
        end
    endtask

    task run_correct_jalr_prediction;
        begin
            begin_phase(32'd0, 32'd16, 32'd4);
            dut.Regs[1] = 32'd17;
            dut.gen_return_address_stack.return_address_stack.ras_count = 4'd1;
            dut.gen_return_address_stack.return_address_stack.ras_top = 3'd1;
            dut.gen_return_address_stack.return_address_stack.ras_stack[0] = 32'd16;
            dut.IMemory[0] = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
            dut.IMemory[1] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[4] = i_type(12'd77, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd17, 32'd0);
            monitoring = 1'b1;
            run_cycles(120);
            monitoring = 1'b0;
            if ((resolution_count != 1) ||
                (capture_count != 0) ||
                (apply_count != 0) ||
                saw_pending ||
                !saw_target_capture ||
                target_capture_check_pending ||
                candidate_capture_check_pending ||
                (candidate_capture_count != 1) ||
                (candidate_check_count != 1) ||
                (retire_count != 1) ||
                (ras_return_update_count != 1)) begin
                $display("FAIL: correct JALR resolve=%0d capture=%0d apply=%0d pending=%0b target=%0b candidate=%0d checked=%0d retire=%0d ras_return=%0d",
                         resolution_count, capture_count, apply_count, saw_pending,
                         saw_target_capture, candidate_capture_count,
                         candidate_check_count, retire_count, ras_return_update_count);
                $fatal;
            end
            check_reg(6, 32'd77);
            check_reg(10, 32'd10);
        end
    endtask

    task run_wrong_jalr_prediction;
        begin
            begin_phase(32'd0, 32'd16, 32'd8);
            dut.Regs[1] = 32'd17;
            dut.gen_return_address_stack.return_address_stack.ras_count = 4'd1;
            dut.gen_return_address_stack.return_address_stack.ras_top = 3'd1;
            dut.gen_return_address_stack.return_address_stack.ras_stack[0] = 32'd8;
            dut.IMemory[0] = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
            dut.IMemory[2] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[4] = i_type(12'd88, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd17, 32'd0);
            monitoring = 1'b1;
            run_cycles(140);
            monitoring = 1'b0;
            check_redirect_phase("JALR wrong predicted target", 0, 0);
            if (ras_return_update_count != 1) begin
                $display("FAIL: wrong-target JALR RAS return updates=%0d",
                         ras_return_update_count);
                $fatal;
            end
            check_reg(6, 32'd88);
            check_reg(10, 32'd10);
        end
    endtask

    task run_taken_branch_exmem_forward;
        begin
            begin_phase(32'd4, 32'd16, 32'd8);
            dut.IMemory[0] = i_type(12'd1, 5'd0, 3'b000, 5'd1, ALUI);
            dut.IMemory[1] = b_type(12, 5'd1, 5'd1, 3'b000, BRANCH);
            dut.IMemory[2] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[4] = i_type(12'd22, 5'd0, 3'b000, 5'd2, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd1, 32'd1);
            monitoring = 1'b1;
            run_cycles(120);
            monitoring = 1'b0;
            check_redirect_phase("taken branch EX/MEM forwarding", 1, 1);
            check_reg(2, 32'd22);
            check_reg(10, 32'd10);
        end
    endtask

    task run_not_taken_branch_memwb_forward;
        begin
            begin_phase(32'd8, 32'd12, 32'd20);
            dut.gen_branch_predictor.branch_predictor_inst.BHT[2] = 2'b11;
            dut.gen_branch_predictor.branch_predictor_inst.BTBValid[2] = 1'b1;
            dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[2] = 32'd20;
            dut.IMemory[0] = i_type(12'd5, 5'd0, 3'b000, 5'd3, ALUI);
            dut.IMemory[1] = NOP;
            dut.IMemory[2] = b_type(12, 5'd0, 5'd3, 3'b000, BRANCH);
            dut.IMemory[3] = i_type(12'd33, 5'd0, 3'b000, 5'd4, ALUI);
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[5] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            expect_forwarded_operands(32'd5, 32'd0);
            monitoring = 1'b1;
            run_cycles(140);
            monitoring = 1'b0;
            check_redirect_phase("not-taken branch MEM/WB forwarding", 1, 1);
            check_reg(4, 32'd33);
            check_reg(10, 32'd10);
        end
    endtask

    task run_correct_prediction;
        begin
            begin_phase(32'd0, 32'd8, 32'd4);
            dut.gen_branch_predictor.branch_predictor_inst.BHT[0] = 2'b11;
            dut.gen_branch_predictor.branch_predictor_inst.BTBValid[0] = 1'b1;
            dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[0] = 32'd8;
            dut.IMemory[0] = b_type(8, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[1] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[2] = i_type(12'd44, 5'd0, 3'b000, 5'd5, ALUI);
            dut.IMemory[3] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            run_cycles(100);
            monitoring = 1'b0;
            if ((resolution_count != 1) ||
                (predictor_update_count != 1) ||
                (capture_count != 0) ||
                (apply_count != 0) ||
                saw_pending ||
                candidate_capture_check_pending ||
                (candidate_capture_count != 1) ||
                (candidate_check_count != 1) ||
                (retire_count != 1)) begin
                $display("FAIL: correct prediction resolve=%0d predictor=%0d capture=%0d apply=%0d pending=%0b candidate=%0d checked=%0d retire=%0d",
                         resolution_count, predictor_update_count, capture_count,
                         apply_count, saw_pending, candidate_capture_count,
                         candidate_check_count, retire_count);
                $fatal;
            end
            check_reg(5, 32'd44);
            check_reg(10, 32'd10);
        end
    endtask

    task run_branch_condition_case;
        input [2:0] branch_funct3;
        input [31:0] lhs;
        input [31:0] rhs;
        input actual_taken;
        input [8*80-1:0] label;
        begin
            begin_phase(32'd0,
                        actual_taken ? 32'd12 : 32'd4,
                        actual_taken ? 32'd4 : 32'd12);
            dut.Regs[1] = lhs;
            dut.Regs[2] = rhs;
            dut.IMemory[0] = b_type(12, 5'd2, 5'd1, branch_funct3, BRANCH);
            if (actual_taken) begin
                // Cold predictor chooses fallthrough; only the target is valid.
                dut.IMemory[1] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
                dut.IMemory[3] = i_type(12'd77, 5'd0, 3'b000, 5'd5, ALUI);
                dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            end else begin
                // Force a taken prediction so recovery must select PC+4.
                dut.gen_branch_predictor.branch_predictor_inst.BHT[0] = 2'b11;
                dut.gen_branch_predictor.branch_predictor_inst.BTBValid[0] = 1'b1;
                dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[0] = 32'd12;
                dut.IMemory[1] = i_type(12'd77, 5'd0, 3'b000, 5'd5, ALUI);
                dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
                dut.IMemory[3] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            end
            expect_forwarded_operands(lhs, rhs);
            monitoring = 1'b1;
            run_cycles(110);
            monitoring = 1'b0;
            check_redirect_phase(label, 1, 1);
            check_reg(5, 32'd77);
            check_reg(10, 32'd10);
        end
    endtask

    task run_branch_target_mismatch;
        begin
            begin_phase(32'd0, 32'd8, 32'd16);
            dut.Regs[1] = 32'd7;
            dut.Regs[2] = 32'd7;
            dut.gen_branch_predictor.branch_predictor_inst.BHT[0] = 2'b11;
            dut.gen_branch_predictor.branch_predictor_inst.BTBValid[0] = 1'b1;
            dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[0] = 32'd16;
            dut.IMemory[0] = b_type(8, 5'd2, 5'd1, 3'b000, BRANCH);
            dut.IMemory[2] = j_type(16, 5'd0, JAL);
            dut.IMemory[4] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[6] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd7, 32'd7);
            monitoring = 1'b1;
            run_cycles(110);
            monitoring = 1'b0;
            check_redirect_phase("branch predicted target mismatch", 1, 1);
            check_reg(10, 32'd10);
        end
    endtask

    task run_back_to_back_correct_resolutions;
        begin
            begin_phase(32'd0, 32'd8, 32'hffff_ffff);
            tracked_pc_secondary = 32'd8;
            dut.gen_branch_predictor.branch_predictor_inst.BHT[0] = 2'b11;
            dut.gen_branch_predictor.branch_predictor_inst.BTBValid[0] = 1'b1;
            dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[0] = 32'd8;
            dut.gen_branch_predictor.branch_predictor_inst.BHT[2] = 2'b11;
            dut.gen_branch_predictor.branch_predictor_inst.BTBValid[2] = 1'b1;
            dut.gen_branch_predictor.branch_predictor_inst.BTBTarget[2] = 32'd16;
            dut.IMemory[0] = b_type(8, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[2] = b_type(8, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[4] = i_type(12'd55, 5'd0, 3'b000, 5'd5, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            run_cycles(110);
            monitoring = 1'b0;
            if ((resolution_count != 1) ||
                (secondary_resolution_count != 1) ||
                (retire_count != 1) ||
                (secondary_retire_count != 1) ||
                !saw_back_to_back_resolution ||
                (capture_count != 0) ||
                (apply_count != 0) ||
                saw_pending ||
                !saw_target_capture ||
                target_capture_check_pending ||
                candidate_capture_check_pending ||
                (candidate_capture_count != 2) ||
                (candidate_check_count != 2)) begin
                $display("FAIL: back-to-back primary=%0d secondary=%0d retire=%0d/%0d adjacent=%0b capture=%0d apply=%0d pending=%0b target=%0b candidate=%0d checked=%0d",
                         resolution_count, secondary_resolution_count,
                         retire_count, secondary_retire_count,
                         saw_back_to_back_resolution, capture_count, apply_count,
                         saw_pending, saw_target_capture, candidate_capture_count,
                         candidate_check_count);
                $fatal;
            end
            check_reg(5, 32'd55);
        end
    endtask

    task run_jal_recovery;
        begin
            begin_phase(32'd0, 32'd12, 32'd4);
            dut.IMemory[0] = j_type(12, 5'd5, JAL);
            dut.IMemory[1] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            run_cycles(100);
            monitoring = 1'b0;
            check_redirect_phase("JAL recovery", 0, 0);
            check_reg(5, 32'd4);
            check_reg(6, 32'd66);
            check_reg(10, 32'd10);
        end
    endtask

    task run_jalr_exmem_forward;
        begin
            begin_phase(32'd4, 32'd16, 32'd8);
            dut.IMemory[0] = i_type(12'd17, 5'd0, 3'b000, 5'd7, ALUI);
            dut.IMemory[1] = i_type(12'd0, 5'd7, 3'b000, 5'd8, JALR);
            dut.IMemory[2] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[4] = i_type(12'd77, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd17, 32'd0);
            monitoring = 1'b1;
            run_cycles(120);
            monitoring = 1'b0;
            check_redirect_phase("JALR EX/MEM forwarding", 0, 0);
            check_reg(8, 32'd8);
            check_reg(6, 32'd77);
            check_reg(10, 32'd10);
        end
    endtask

    task run_jalr_memwb_forward;
        begin
            begin_phase(32'd8, 32'd20, 32'd12);
            dut.IMemory[0] = i_type(12'd21, 5'd0, 3'b000, 5'd9, ALUI);
            dut.IMemory[1] = NOP;
            dut.IMemory[2] = i_type(12'd0, 5'd9, 3'b000, 5'd10, JALR);
            dut.IMemory[3] = i_type(12'd99, 5'd0, 3'b000, 5'd11, ALUI);
            dut.IMemory[5] = i_type(12'd88, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[6] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd21, 32'd0);
            monitoring = 1'b1;
            run_cycles(130);
            monitoring = 1'b0;
            check_redirect_phase("JALR MEM/WB forwarding", 0, 0);
            check_reg(10, 32'd12);
            check_reg(6, 32'd88);
            check_reg(11, 32'd11);
        end
    endtask

    task run_rv32m_branch_dependency;
        begin
            begin_phase(32'd16, 32'd28, 32'd20);
            dut.IMemory[0] = i_type(12'd6, 5'd0, 3'b000, 5'd1, ALUI);
            dut.IMemory[1] = i_type(12'd7, 5'd0, 3'b000, 5'd2, ALUI);
            dut.IMemory[2] = i_type(12'd42, 5'd0, 3'b000, 5'd12, ALUI);
            dut.IMemory[3] = r_type(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd11, ALUR);
            dut.IMemory[4] = b_type(12, 5'd12, 5'd11, 3'b000, BRANCH);
            dut.IMemory[5] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[7] = i_type(12'd77, 5'd0, 3'b000, 5'd13, ALUI);
            dut.IMemory[8] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd42, 32'd42);
            monitoring = 1'b1;
            run_cycles(240);
            monitoring = 1'b0;
            check_redirect_phase("RV32M-to-branch forwarding", 1, 1);
            check_reg(11, 32'd42);
            check_reg(13, 32'd77);
            check_reg(10, 32'd10);
        end
    endtask

    task run_rv32m_jalr_dependency;
        begin
            begin_phase(32'd12, 32'd20, 32'd16);
            dut.IMemory[0] = i_type(12'd5, 5'd0, 3'b000, 5'd1, ALUI);
            dut.IMemory[1] = i_type(12'd4, 5'd0, 3'b000, 5'd2, ALUI);
            dut.IMemory[2] = r_type(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd14, ALUR);
            dut.IMemory[3] = i_type(12'd0, 5'd14, 3'b000, 5'd15, JALR);
            dut.IMemory[4] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[5] = i_type(12'd66, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[6] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            expect_forwarded_operands(32'd20, 32'd0);
            monitoring = 1'b1;
            run_cycles(220);
            monitoring = 1'b0;
            check_redirect_phase("RV32M-to-JALR forwarding", 0, 0);
            check_reg(14, 32'd20);
            check_reg(15, 32'd16);
            check_reg(6, 32'd66);
            check_reg(10, 32'd10);
        end
    endtask

    task run_wrong_path_case;
        input [31:0] wrong_instruction;
        input integer kind;
        begin
            begin_phase(32'd0, 32'd12, 32'd4);
            dut.Regs[1] = 32'd6;
            dut.Regs[2] = 32'd7;
            dut.Regs[3] = 32'h0000_0200;
            dut.Regs[7] = 32'd13;
            dut.IMemory[0] = i_type(12'd0, 5'd7, 3'b000, 5'd5, JALR);
            dut.IMemory[1] = wrong_instruction;
            dut.IMemory[2] = i_type(12'd98, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            run_cycles(140);
            monitoring = 1'b0;
            check_redirect_phase("wrong-path suppression", 0, 0);
            if (dut.DMemory[0] !== 32'h0) begin
                $display("FAIL: wrong-path case changed DMemory[0] to %h", dut.DMemory[0]);
                $fatal;
            end
            if (dut.GPIOOutput !== 32'h0) begin
                $display("FAIL: wrong-path case changed GPIO to %h", dut.GPIOOutput);
                $fatal;
            end
            if (kind == WRONG_CSR && dut.CSRmtvec !== 32'h0) begin
                $display("FAIL: wrong-path CSR write changed mtvec to %h", dut.CSRmtvec);
                $fatal;
            end
            if (kind == WRONG_ILLEGAL && dut.CSRmcause !== 32'h0) begin
                $display("FAIL: wrong-path illegal instruction trapped with mcause %h", dut.CSRmcause);
                $fatal;
            end
            if (kind == WRONG_RV32M &&
                (wrong_rv32m_start_count != 0 || dut.RV32MInFlight)) begin
                $display("FAIL: wrong-path RV32M state start_count=%0d inflight=%0b",
                         wrong_rv32m_start_count, dut.RV32MInFlight);
                $fatal;
            end
            check_reg(5, 32'd4);
            check_reg(6, 32'd66);
            check_reg(10, 32'd10);
        end
    endtask

    task run_stalled_ras_call;
        begin
            begin_phase(32'd0, 32'd12, 32'd4);
            dut.IMemory[0] = j_type(12, 5'd1, JAL);
            dut.IMemory[1] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            while (!(dut.IDEXValid && (dut.IDEXPC == 32'd0))) begin
                @(negedge clock);
            end
            force dut.cache_busy = 1'b1;
            force dut.cache_stall = 2'b01;
            repeat (3) begin
                @(posedge clock);
                #1;
                if (dut.ras_update_accept ||
                    (ras_update_accept_count != 0) ||
                    (ras_call_update_count != 0) ||
                    (ras_return_update_count != 0) ||
                    (dut.RASCount !== 4'd0)) begin
                    $display("FAIL: stalled call updated RAS before release commit");
                    $fatal;
                end
            end
            @(negedge clock);
            release dut.cache_busy;
            release dut.cache_stall;
            run_cycles(120);
            monitoring = 1'b0;
            check_redirect_phase("stalled RAS call", 0, 0);
            if ((ras_update_accept_count != 1) ||
                (ras_call_update_count != 1) ||
                (ras_return_update_count != 0) ||
                (dut.RASCount !== 4'd1)) begin
                $display("FAIL: stalled call accept=%0d call=%0d return=%0d count=%0d",
                         ras_update_accept_count, ras_call_update_count,
                         ras_return_update_count, dut.RASCount);
                $fatal;
            end
            check_reg(1, 32'd4);
            check_reg(6, 32'd66);
        end
    endtask

    task run_pending_interrupt_ras_call;
        begin
            begin_phase(32'd0, 32'd16, 32'd4);
            dut.csr_unit_inst.mstatus = 32'h0000_1808;
            dut.csr_unit_inst.mie = 32'h0000_0080;
            dut.csr_unit_inst.mtvec = 32'd64;
            dut.IMemory[0] = j_type(16, 5'd1, JAL);
            dut.IMemory[1] = 32'hffff_ffff;
            dut.IMemory[4] = i_type(12'd77, 5'd0, 3'b000, 5'd7, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[16] = i_type(12'd88, 5'd0, 3'b000, 5'd8, ALUI);
            dut.IMemory[17] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            force dut.timer_irq_pending = 1'b1;
            timer_forced = 1'b1;
            timer_phase = 1'b1;
            monitoring = 1'b1;
            run_cycles(180);
            timer_phase = 1'b0;
            monitoring = 1'b0;
            if (!timer_released ||
                (timer_interrupt_pc !== 32'd16) ||
                (dut.CSRmepc !== 32'd16) ||
                (dut.CSRmcause !== 32'h8000_0007) ||
                (ras_update_accept_count != 1) ||
                (ras_call_update_count != 1) ||
                (ras_return_update_count != 0) ||
                (dut.RASCount !== 4'd1)) begin
                $display("FAIL: call/interrupt released=%0b pc=%h mepc=%h mcause=%h accept=%0d call=%0d return=%0d count=%0d",
                         timer_released, timer_interrupt_pc, dut.CSRmepc,
                         dut.CSRmcause, ras_update_accept_count,
                         ras_call_update_count, ras_return_update_count,
                         dut.RASCount);
                $fatal;
            end
            check_redirect_phase("interrupt deferred across RAS call", 0, 0);
            check_reg(7, 32'd7);
            check_reg(8, 32'd88);
        end
    endtask

    task run_non_ras_instruction;
        input [31:0] instruction;
        input [8*80-1:0] label;
        begin
            begin_phase(32'hffff_ffff, 32'h0, 32'hffff_ffff);
            dut.Regs[1] = 32'd1;
            dut.Regs[2] = 32'd16;
            dut.csr_unit_inst.mtvec = 32'd64;
            dut.csr_unit_inst.mepc = 32'd16;
            dut.csr_unit_inst.mstatus = 32'h0000_1800;
            dut.gen_return_address_stack.return_address_stack.ras_count = 4'd1;
            dut.gen_return_address_stack.return_address_stack.ras_top = 3'd1;
            dut.gen_return_address_stack.return_address_stack.ras_stack[0] = 32'h1234_5678;
            dut.IMemory[0] = instruction;
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[16] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            run_cycles(100);
            monitoring = 1'b0;
            if ((ras_update_accept_count != 0) ||
                (dut.RASCount !== 4'd1) ||
                (dut.RASTop !== 3'd1) ||
                (dut.gen_return_address_stack.return_address_stack.ras_stack[0] !== 32'h1234_5678)) begin
                $display("FAIL: %0s changed RAS accept=%0d count=%0d top=%0d entry=%h",
                         label, ras_update_accept_count, dut.RASCount, dut.RASTop,
                         dut.gen_return_address_stack.return_address_stack.ras_stack[0]);
                $fatal;
            end
        end
    endtask

    task run_pending_dcache_stall;
        begin
            begin_phase(32'd4, 32'd16, 32'd8);
            dut.IMemory[0] = i_type(12'd17, 5'd0, 3'b000, 5'd9, ALUI);
            dut.IMemory[1] = i_type(12'd0, 5'd9, 3'b000, 5'd5, JALR);
            dut.IMemory[2] = s_type(12'd0, 5'd2, 5'd0, 3'b010, STORE);
            dut.IMemory[4] = i_type(12'd77, 5'd0, 3'b000, 5'd6, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            while (!dut.ControlRedirectPending) begin
                @(negedge clock);
            end
            force dut.cache_busy = 1'b1;
            force dut.cache_stall = 2'b01;
            repeat (3) begin
                @(posedge clock);
                #1;
                if (!dut.ControlRedirectPending || dut.if_redirect || dut.control_redirect_apply) begin
                    $display("FAIL: pending redirect did not hold through forced D-cache stall");
                    $fatal;
                end
                if ((dut.ControlRedirectTargetPC !== 32'd16) ||
                    (dut.ControlRedirectFallthroughPC !== 32'd8) ||
                    dut.ControlRedirectUseFallthrough ||
                    (dut.ControlRedirectPC !== 32'd16)) begin
                    $display("FAIL: pending redirect metadata changed during D-cache stall target=%h fallthrough=%h use=%0b final=%h",
                             dut.ControlRedirectTargetPC,
                             dut.ControlRedirectFallthroughPC,
                             dut.ControlRedirectUseFallthrough,
                             dut.ControlRedirectPC);
                    $fatal;
                end
            end
            @(negedge clock);
            release dut.cache_busy;
            release dut.cache_stall;
            run_cycles(100);
            monitoring = 1'b0;
            check_redirect_phase("pending redirect D-cache hold", 0, 0);
            if (dut.DMemory[0] !== 32'h0) begin
                $display("FAIL: held wrong-path store changed DMemory[0]");
                $fatal;
            end
            check_reg(6, 32'd77);
        end
    endtask

    task run_pending_timer_interrupt;
        begin
            begin_phase(32'd4, 32'd16, 32'd8);
            dut.csr_unit_inst.mstatus = 32'h0000_1808;
            dut.csr_unit_inst.mie = 32'h0000_0080;
            dut.csr_unit_inst.mtvec = 32'd64;
            dut.IMemory[0] = i_type(12'd17, 5'd0, 3'b000, 5'd9, ALUI);
            dut.IMemory[1] = i_type(12'd0, 5'd9, 3'b000, 5'd5, JALR);
            dut.IMemory[2] = 32'hffff_ffff;
            dut.IMemory[4] = i_type(12'd77, 5'd0, 3'b000, 5'd7, ALUI);
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[16] = i_type(12'd88, 5'd0, 3'b000, 5'd8, ALUI);
            dut.IMemory[17] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            monitoring = 1'b1;
            timer_phase = 1'b1;
            while (!dut.ControlRedirectPending) begin
                @(negedge clock);
            end
            force dut.timer_irq_pending = 1'b1;
            timer_forced = 1'b1;
            run_cycles(180);
            timer_phase = 1'b0;
            monitoring = 1'b0;
            if (!timer_released ||
                (timer_interrupt_pc !== 32'd16) ||
                (dut.CSRmepc !== 32'd16) ||
                (dut.CSRmcause !== 32'h8000_0007)) begin
                $display("FAIL: delayed timer evidence released=%0b interrupt_pc=%h mepc=%h mcause=%h",
                         timer_released, timer_interrupt_pc, dut.CSRmepc, dut.CSRmcause);
                $fatal;
            end
            check_redirect_phase("timer deferred across recovery", 0, 0);
            check_reg(7, 32'd7);
            check_reg(8, 32'd88);
        end
    endtask

    task run_ras_once;
        begin
            begin_phase(32'd0, 32'd16, 32'd20);
            dut.IMemory[0] = j_type(16, 5'd1, JAL);
            dut.IMemory[1] = i_type(12'd55, 5'd0, 3'b000, 5'd5, ALUI);
            dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, BRANCH);
            dut.IMemory[4] = i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR);
            dut.IMemory[5] = i_type(12'd99, 5'd0, 3'b000, 5'd6, ALUI);
            monitoring = 1'b1;
            run_cycles(140);
            monitoring = 1'b0;
            if ((ras_call_update_count != 1) ||
                (ras_return_update_count != 1) ||
                (dut.RASCount !== 4'd0)) begin
                $display("FAIL: tracked RAS call updates=%0d return_updates=%0d final_count=%0d",
                         ras_call_update_count, ras_return_update_count, dut.RASCount);
                $fatal;
            end
            check_reg(1, 32'd4);
            check_reg(5, 32'd55);
            check_reg(6, 32'd6);
        end
    endtask

    task run_reset_pending;
        begin
            begin_phase(32'd0, 32'd12, 32'd4);
            dut.gen_return_address_stack.return_address_stack.ras_count = 4'd1;
            dut.gen_return_address_stack.return_address_stack.ras_top = 3'd1;
            dut.gen_return_address_stack.return_address_stack.ras_stack[0] = 32'h1234_5678;
            dut.IMemory[0] = j_type(12, 5'd5, JAL);
            dut.IMemory[1] = i_type(12'd99, 5'd0, 3'b000, 5'd10, ALUI);
            dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, ALUI);
            monitoring = 1'b1;
            while (!dut.ControlRedirectPending) begin
                @(negedge clock);
            end
            dut.ControlInterruptDeferred = 1'b1;
            reset = 1'b1;
            @(posedge clock);
            #1;
            if (dut.ControlRedirectPending ||
                dut.ControlInterruptDeferred ||
                (dut.ControlRedirectPC !== 32'h0) ||
                (dut.ControlRedirectTargetPC !== 32'h0) ||
                (dut.ControlRedirectFallthroughPC !== 32'h0) ||
                dut.ControlRedirectUseFallthrough ||
                (dut.RASCount !== 4'd0) ||
                (dut.RASTop !== 3'd0)) begin
                $display("FAIL: reset did not clear pending control/RAS metadata");
                $fatal;
            end
            reset = 1'b0;
            monitoring = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("wave/tb_assert_registered_control_redirect.vcd");
        $dumpvars(0, tb_assert_registered_control_redirect);

        run_taken_branch_exmem_forward();
        run_not_taken_branch_memwb_forward();
        run_correct_prediction();
        run_branch_condition_case(3'b000, 32'd5, 32'd5, 1'b1, "BEQ taken");
        run_branch_condition_case(3'b000, 32'd5, 32'd6, 1'b0, "BEQ not taken");
        run_branch_condition_case(3'b001, 32'd5, 32'd6, 1'b1, "BNE taken");
        run_branch_condition_case(3'b001, 32'd5, 32'd5, 1'b0, "BNE not taken");
        run_branch_condition_case(3'b100, 32'h8000_0000, 32'h0000_0000, 1'b1, "BLT signed boundary taken");
        run_branch_condition_case(3'b100, 32'h7fff_ffff, 32'h8000_0000, 1'b0, "BLT signed boundary not taken");
        run_branch_condition_case(3'b101, 32'h7fff_ffff, 32'h8000_0000, 1'b1, "BGE signed boundary taken");
        run_branch_condition_case(3'b101, 32'h8000_0000, 32'h0000_0000, 1'b0, "BGE signed boundary not taken");
        run_branch_condition_case(3'b110, 32'h0000_0000, 32'hffff_ffff, 1'b1, "BLTU boundary taken");
        run_branch_condition_case(3'b110, 32'hffff_ffff, 32'h0000_0000, 1'b0, "BLTU boundary not taken");
        run_branch_condition_case(3'b111, 32'hffff_ffff, 32'h0000_0000, 1'b1, "BGEU boundary taken");
        run_branch_condition_case(3'b111, 32'h0000_0000, 32'hffff_ffff, 1'b0, "BGEU boundary not taken");
        run_branch_target_mismatch();
        run_back_to_back_correct_resolutions();
        run_jal_recovery();
        run_correct_jalr_prediction();
        run_wrong_jalr_prediction();
        run_jalr_exmem_forward();
        run_jalr_memwb_forward();
        run_rv32m_branch_dependency();
        run_rv32m_jalr_dependency();

        run_wrong_path_case(s_type(12'd0, 5'd2, 5'd0, 3'b010, STORE), WRONG_STORE);
        run_wrong_path_case(s_type(12'd0, 5'd2, 5'd3, 3'b010, STORE), WRONG_GPIO);
        run_wrong_path_case(i_type(12'h305, 5'd2, 3'b001, 5'd0, SYSTEM), WRONG_CSR);
        run_wrong_path_case(32'hffff_ffff, WRONG_ILLEGAL);
        run_wrong_path_case(r_type(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, ALUR), WRONG_RV32M);
        run_wrong_path_case(j_type(8, 5'd1, JAL), 0);
        run_wrong_path_case(i_type(12'd0, 5'd1, 3'b000, 5'd0, JALR), 0);

        run_non_ras_instruction(i_type(12'd0, 5'd1, 3'b010, 5'd2, LOAD), "misaligned load");
        run_non_ras_instruction(s_type(12'd0, 5'd2, 5'd1, 3'b010, STORE), "misaligned store");
        run_non_ras_instruction(32'h0000_0073, "ecall");
        run_non_ras_instruction(32'h0010_0073, "ebreak");
        run_non_ras_instruction(32'hffff_ffff, "illegal instruction");
        run_non_ras_instruction(32'h3020_0073, "mret");
        run_non_ras_instruction(r_type(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd3, ALUR), "RV32M");
        run_non_ras_instruction(i_type(12'd0, 5'd2, 3'b000, 5'd5, JALR), "noncanonical JALR");

        run_stalled_ras_call();
        run_pending_dcache_stall();
        run_pending_timer_interrupt();
        run_pending_interrupt_ras_call();
        run_ras_once();
        run_reset_pending();

        $display("PASS: registered control recovery preserved targets, forwarding, precise side effects, and single events");
        $display("PASS: tb_assert_registered_control_redirect passed");
        $finish;
    end

endmodule
