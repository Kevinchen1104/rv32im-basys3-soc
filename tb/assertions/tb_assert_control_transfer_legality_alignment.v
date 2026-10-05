`timescale 1ns / 1ps

// Purpose: Verify JALR legality and IALIGN=32 control-transfer trap behavior in the integrated pipeline.
// Checks: Taken branch/JAL/JALR target alignment, untaken-branch behavior, illegal JALR priority, precise N/N+1/N+2
//   trap sequencing, deferred-interrupt boundaries, D-cache backpressure, pending reset, wrong-path isolation, and predictor/RAS suppression.
// Pass condition: Every directed phase reaches its handler or fallthrough endpoint with the expected state.

module tb_assert_control_transfer_legality_alignment;

`include "tb_common.vh"

    localparam [6:0] JALR_OPCODE = 7'b1100111;
    localparam [31:0] SENTINEL = 32'h4a4c_5230;
    localparam [31:0] ILLEGAL_RETURN =
        {12'd0, 5'd1, 3'b111, 5'd0, JALR_OPCODE};

    reg checking_enabled = 1'b0;
    reg [31:0] fault_pc = 32'hffff_ffff;
    reg [31:0] wrong_reg_pc = 32'hffff_ffff;
    reg [31:0] wrong_store_pc = 32'hffff_ffff;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            ((dut.MEMWBPC == fault_pc) || (dut.MEMWBPC == wrong_reg_pc))) begin
            $display("FAIL: faulting/wrong-path instruction at PC %h reached writeback", dut.MEMWBPC);
            $fatal;
        end

        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == fault_pc) || (dut.EXMEMPC == wrong_store_pc))) begin
            $display("FAIL: faulting/wrong-path store at PC %h reached MEM", dut.EXMEMPC);
            $fatal;
        end

        if (checking_enabled &&
            dut.IDEXValid &&
            dut.is_jalr &&
            (dut.IDEXfunct3 != 3'b000) &&
            (dut.control_resolution_accept || dut.ras_update_accept)) begin
            $display("FAIL: illegal JALR resolved control flow or updated RAS");
            $fatal;
        end

        if (checking_enabled &&
            dut.is_misaligned_instruction &&
            (dut.branch_mispredict ||
             dut.jump_mispredict ||
             dut.ras_update_accept)) begin
            $display("FAIL: misaligned control transfer updated predictor/RAS state");
            $fatal;
        end
    end

    task prepare_trap_phase;
        input [31:0] handler_pc;
        begin
            reset_cpu();
            dut.DMemory[16] = SENTINEL;
            dut.IMemory[0] = i_type(handler_pc[11:0], 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
        end
    endtask

    task check_trap_metadata;
        input [31:0] expected_pc;
        input [31:0] expected_cause;
        input [31:0] expected_tval;
        begin
            if (dut.CSRmepc !== expected_pc ||
                dut.CSRmcause !== expected_cause ||
                dut.CSRmtval !== expected_tval) begin
                $display("FAIL: trap metadata mepc=%h mcause=%h mtval=%h",
                         dut.CSRmepc, dut.CSRmcause, dut.CSRmtval);
                $fatal;
            end
        end
    endtask

    task run_misaligned_jal;
        begin
            prepare_trap_phase(32'd40);
            dut.IMemory[2] = i_type(12'd55, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[3] = j_type(2, 5'd5, 7'b1101111);
            dut.IMemory[4] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[5] = s_type(12'd64, 5'd6, 5'd0, 3'b010, 7'b0100011);
            dut.IMemory[10] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[11] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd12;
            wrong_reg_pc = 32'd16;
            wrong_store_pc = 32'd20;
            checking_enabled = 1'b1;
            run_cycles(220);
            checking_enabled = 1'b0;

            check_trap_metadata(32'd12, 32'd0, 32'd14);
            check_reg(5, 32'd55);
            check_reg(6, 32'd6);
            check_reg(7, 32'd77);
            if (dut.DMemory[16] !== SENTINEL) begin
                $display("FAIL: misaligned JAL changed wrong-path memory");
                $fatal;
            end
        end
    endtask

    task run_misaligned_jalr;
        begin
            prepare_trap_phase(32'd48);
            dut.IMemory[2] = i_type(12'd55, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[3] = i_type(12'd18, 5'd0, 3'b000, 5'd8, 7'b0010011);
            dut.IMemory[4] = i_type(12'd0, 5'd8, 3'b000, 5'd5, JALR_OPCODE);
            dut.IMemory[5] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[6] = s_type(12'd64, 5'd6, 5'd0, 3'b010, 7'b0100011);
            dut.IMemory[12] = i_type(12'd88, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[13] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd16;
            wrong_reg_pc = 32'd20;
            wrong_store_pc = 32'd24;
            checking_enabled = 1'b1;
            run_cycles(220);
            checking_enabled = 1'b0;

            check_trap_metadata(32'd16, 32'd0, 32'd18);
            check_reg(5, 32'd55);
            check_reg(6, 32'd6);
            check_reg(7, 32'd88);
            if (dut.DMemory[16] !== SENTINEL) begin
                $display("FAIL: misaligned JALR changed wrong-path memory");
                $fatal;
            end
        end
    endtask

    task run_taken_branch;
        begin
            prepare_trap_phase(32'd32);
            dut.IMemory[2] = b_type(2, 5'd0, 5'd0, 3'b000, 7'b1100011);
            dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[8] = i_type(12'd99, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd8;
            wrong_reg_pc = 32'd12;
            wrong_store_pc = 32'hffff_ffff;
            checking_enabled = 1'b1;
            run_cycles(200);
            checking_enabled = 1'b0;

            check_trap_metadata(32'd8, 32'd0, 32'd10);
            check_reg(6, 32'd6);
            check_reg(7, 32'd99);
        end
    endtask

    task run_untaken_branch;
        begin
            reset_cpu();
            dut.IMemory[0] = i_type(12'd1, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = b_type(2, 5'd1, 5'd0, 3'b000, 7'b1100011);
            dut.IMemory[2] = i_type(12'd44, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[3] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);
            run_cycles(160);

            if (dut.CSRmepc !== 32'd0 || dut.CSRmcause !== 32'd0) begin
                $display("FAIL: untaken branch raised instruction-address-misaligned trap");
                $fatal;
            end
            check_reg(6, 32'd44);
        end
    endtask

    task run_illegal_jalr;
        begin
            prepare_trap_phase(32'd32);
            dut.IMemory[2] = ILLEGAL_RETURN;
            dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[8] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd8;
            wrong_reg_pc = 32'd12;
            wrong_store_pc = 32'hffff_ffff;
            checking_enabled = 1'b1;
            run_cycles(200);
            checking_enabled = 1'b0;

            check_trap_metadata(32'd8, 32'd2, ILLEGAL_RETURN);
            check_reg(6, 32'd6);
            check_reg(7, 32'd77);
    end
    endtask

    task setup_pending_jal_phase;
        input [31:0] handler_pc;
        begin
            prepare_trap_phase(handler_pc);
            dut.IMemory[2] = j_type(2, 5'd5, 7'b1101111);
            dut.IMemory[handler_pc >> 2] =
                b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);
            fault_pc = 32'd8;
            wrong_reg_pc = 32'hffff_ffff;
            wrong_store_pc = 32'hffff_ffff;
        end
    endtask

    task wait_for_pending_jal_detect;
        integer timeout;
        begin
            timeout = 0;
            while (!(dut.IDEXValid &&
                     (dut.IDEXPC == 32'd8) &&
                     dut.instruction_misaligned_detect)) begin
                @(negedge clock);
                timeout = timeout + 1;
                if (timeout > 100) begin
                    $display("FAIL: timed out waiting for misaligned JAL detect");
                    $fatal;
                end
            end
            #1;
        end
    endtask

    task run_pending_handoff_timeline;
        begin
            setup_pending_jal_phase(32'd40);
            wait_for_pending_jal_detect();

            if (dut.InstructionMisalignPending ||
                dut.CSRTrapMetadataPending ||
                dut.CSRmepc !== 32'h0) begin
                $display("FAIL: trap state changed before capture edge N");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (!dut.InstructionMisalignPending ||
                dut.CSRTrapMetadataPending ||
                dut.CSRmepc !== 32'h0) begin
                $display("FAIL: edge N did not isolate instruction-misalignment capture");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dut.InstructionMisalignPending ||
                !dut.CSRTrapMetadataPending ||
                (dut.PC !== 32'd40) ||
                dut.CSRmepc !== 32'h0) begin
                $display("FAIL: edge N+1 did not redirect and capture CSR shadow");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dut.CSRTrapMetadataPending) begin
                $display("FAIL: trap metadata pending did not drain at edge N+2");
                $fatal;
            end
            check_trap_metadata(32'd8, 32'd0, 32'd10);
        end
    endtask

    task run_pending_interrupt_priority;
        begin
            setup_pending_jal_phase(32'd40);
            wait_for_pending_jal_detect();

            force dut.machine_interrupt_pending = 1'b1;
            #1;
            if (dut.interrupt_eligible ||
                dut.interrupt_taken ||
                !dut.instruction_misaligned_capture ||
                dut.redirect_taken) begin
                $display("FAIL: unresolved control transfer did not defer a newly pending interrupt");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (!dut.InstructionMisalignPending) begin
                $display("FAIL: pending-interrupt phase did not capture misaligned target");
                $fatal;
            end
            release dut.machine_interrupt_pending;

            @(posedge clock);
            #1;
            if (!dut.CSRTrapMetadataPending || dut.interrupt_taken) begin
                $display("FAIL: captured synchronous trap lost priority at acceptance");
                $fatal;
            end

            @(posedge clock);
            #1;
            check_trap_metadata(32'd8, 32'd0, 32'd10);
        end
    endtask

    task run_deferred_interrupt_priority;
        begin
            setup_pending_jal_phase(32'd40);
            wait_for_pending_jal_detect();

            // A deferred interrupt belongs to the boundary after an earlier
            // resolved control instruction. It is accepted before the current
            // IDEX instruction executes, so that instruction is replayed from
            // mepc after mret rather than raising an exception concurrently.
            force dut.ControlInterruptDeferred = 1'b1;
            force dut.machine_interrupt_pending = 1'b1;
            #1;
            if (!dut.interrupt_eligible ||
                !dut.interrupt_taken ||
                dut.instruction_misaligned_capture ||
                !dut.redirect_taken) begin
                $display("FAIL: deferred interrupt was not accepted at its precise boundary");
                $fatal;
            end

            @(posedge clock);
            #1;
            release dut.ControlInterruptDeferred;
            release dut.machine_interrupt_pending;
            if (dut.InstructionMisalignPending ||
                !dut.CSRTrapMetadataPending ||
                (dut.PC !== 32'd40)) begin
                $display("FAIL: deferred interrupt did not preempt current instruction cleanly");
                $fatal;
            end

            @(posedge clock);
            #1;
            check_trap_metadata(32'd8, 32'h8000_0007, 32'h0);
        end
    endtask

    task run_dcache_stall_release;
        begin
            setup_pending_jal_phase(32'd40);
            wait_for_pending_jal_detect();

            force dut.dcache_pipeline_stall = 1'b1;
            #1;
            if (dut.instruction_misaligned_capture) begin
                $display("FAIL: D-cache stall allowed misaligned-target capture");
                $fatal;
            end
            repeat (2) begin
                @(posedge clock);
                #1;
                if (dut.InstructionMisalignPending ||
                    !dut.IDEXValid ||
                    (dut.IDEXPC !== 32'd8)) begin
                    $display("FAIL: D-cache stall did not preserve faulting control transfer");
                    $fatal;
                end
            end

            @(negedge clock);
            release dut.dcache_pipeline_stall;
            #1;
            if (!dut.instruction_misaligned_capture) begin
                $display("FAIL: released D-cache stall did not accept delayed exception");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (!dut.InstructionMisalignPending) begin
                $display("FAIL: released D-cache stall lost pending exception");
                $fatal;
            end
            repeat (2) @(posedge clock);
            #1;
            check_trap_metadata(32'd8, 32'd0, 32'd10);
        end
    endtask

    task run_pending_reset;
        begin
            setup_pending_jal_phase(32'd40);
            wait_for_pending_jal_detect();
            @(posedge clock);
            #1;
            if (!dut.InstructionMisalignPending) begin
                $display("FAIL: reset phase did not create pending exception");
                $fatal;
            end

            reset = 1'b1;
            @(posedge clock);
            #1;
            if (dut.InstructionMisalignPending ||
                dut.CSRTrapMetadataPending ||
                dut.CSRmepc !== 32'h0 ||
                dut.CSRmcause !== 32'h0 ||
                dut.CSRmtval !== 32'h0) begin
                $display("FAIL: reset did not clear pending trap pipeline");
                $fatal;
            end
            reset = 1'b0;
        end
    endtask

    task run_older_memory_fault_cancels_younger_misalignment;
        integer timeout;
        begin
            prepare_trap_phase(32'd40);
            dut.IMemory[2] = {20'h00001, 5'd8, 7'b0110111};
            dut.IMemory[3] = i_type(12'd0, 5'd8, 3'b010, 5'd9, 7'b0000011);
            dut.IMemory[4] = j_type(2, 5'd5, 7'b1101111);
            dut.IMemory[5] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[10] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd12;
            wrong_reg_pc = 32'd16;
            wrong_store_pc = 32'hffff_ffff;
            checking_enabled = 1'b1;

            timeout = 0;
            while (!(dut.memory_access_fault_taken &&
                      dut.instruction_misaligned_capture)) begin
                @(negedge clock);
                timeout = timeout + 1;
                if (timeout > 100)
                    $fatal(1, "Timed out waiting for overlapping memory fault and misalignment");
            end
            @(posedge clock);
            #1;
            if (!dut.InstructionMisalignPending ||
                !dut.InstructionMisalignCancel ||
                !dut.CSRTrapMetadataPending) begin
                $display("FAIL: older memory fault did not register cancellation of younger misalignment");
                $fatal;
            end

            @(posedge clock);
            #1;
            if (dut.InstructionMisalignPending ||
                dut.InstructionMisalignCancel ||
                dut.CSRTrapMetadataPending) begin
                $display("FAIL: cancelled younger misalignment did not drain cleanly");
                $fatal;
            end
            check_trap_metadata(32'd12, 32'd5, 32'h0000_1000);

            run_cycles(80);
            checking_enabled = 1'b0;
            check_trap_metadata(32'd12, 32'd5, 32'h0000_1000);
            check_reg(5, 32'd5);
            check_reg(6, 32'd6);
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_control_transfer_legality_alignment.vcd");
        $dumpvars(0, tb_assert_control_transfer_legality_alignment);

        run_misaligned_jal();
        run_misaligned_jalr();
        run_taken_branch();
        run_untaken_branch();
        run_illegal_jalr();
        run_pending_handoff_timeline();
        run_pending_interrupt_priority();
        run_deferred_interrupt_priority();
        run_dcache_stall_release();
        run_pending_reset();
        run_older_memory_fault_cancels_younger_misalignment();

        $display("PASS: tb_assert_control_transfer_legality_alignment passed");
        $finish;
    end

endmodule
