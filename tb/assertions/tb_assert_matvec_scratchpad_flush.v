`timescale 1ns / 1ps

// Checks: Branch, jump, and trap redirects suppress younger wrong-path stores to MATVEC Scratchpad CTRL so the scratchpad
//   accelerator does not start or update busy, done, perf, row, or result state.

module tb_assert_matvec_scratchpad_flush;

`include "tb_common.vh"

    localparam ECALL = 32'h00000073;

    reg checking_enabled = 1'b0;
    reg [31:0] wrong_path_store_pc = 32'hffff_ffff;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            (dut.EXMEMPC == wrong_path_store_pc)) begin
            $display("FAIL: wrong-path MATVEC_CTRL store at PC %h reached MEM stage", dut.EXMEMPC);
            $fatal;
        end
    end

    task check_matvec_reset_state;
        input [8*80-1:0] label;
        integer row;
        begin
            if (dut.gen_accelerators.accel_matvec.busy !== 1'b0 ||
                dut.gen_accelerators.accel_matvec.done !== 1'b0 ||
                dut.gen_accelerators.accel_matvec.start_ignored !== 1'b0 ||
                dut.gen_accelerators.accel_matvec.write_ignored_while_busy !== 1'b0 ||
                dut.gen_accelerators.accel_matvec.active_row !== 4'h0 ||
                dut.gen_accelerators.accel_matvec.row_count_minus1 !== 4'h0 ||
                dut.gen_accelerators.accel_matvec.selected_row_index !== 4'h0 ||
                dut.gen_accelerators.accel_matvec.selected_result_index !== 4'h0 ||
                dut.gen_accelerators.accel_matvec.vector_reg !== 32'h0 ||
                dut.gen_accelerators.accel_matvec.completed_ops !== 8'h0 ||
                dut.gen_accelerators.accel_matvec.ignored_starts !== 8'h0 ||
                dut.gen_accelerators.accel_matvec.ignored_busy_writes !== 8'h0 ||
                dut.matvec_perf_read_data !== 32'h0 ||
                dut.matvec_status_read_data !== 32'h0) begin
                $display(
                    "FAIL: %0s changed MATVEC Scratchpad state status=%h config=%h vector=%h row_index=%h result_index=%h perf=%h",
                    label,
                    dut.matvec_status_read_data,
                    dut.matvec_config_read_data,
                    dut.gen_accelerators.accel_matvec.vector_reg,
                    dut.gen_accelerators.accel_matvec.selected_row_index,
                    dut.gen_accelerators.accel_matvec.selected_result_index,
                    dut.matvec_perf_read_data
                );
                $fatal;
            end

            for (row = 0; row < 16; row = row + 1) begin
                if (dut.gen_accelerators.accel_matvec.row_scratchpad[row] !== 32'h0 ||
                    dut.gen_accelerators.accel_matvec.result_scratchpad[row] !== 32'h0) begin
                    $display(
                        "FAIL: %0s changed MATVEC Scratchpad row %0d row=%h result=%h",
                        label,
                        row,
                        dut.gen_accelerators.accel_matvec.row_scratchpad[row],
                        dut.gen_accelerators.accel_matvec.result_scratchpad[row]
                    );
                    $fatal;
                end
            end
        end
    endtask

    task run_branch_case;
        begin
            reset_cpu();
            wrong_path_store_pc = 32'd12;

            dut.IMemory[0] = i_type(12'd1792, 5'd0, 3'b000, 5'd1, 7'b0010011);  // x1 = MATVEC Scratchpad base
            dut.IMemory[1] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);     // x2 = start value
            dut.IMemory[2] = b_type(8, 5'd0, 5'd0, 3'b000, 7'b1100011);         // taken branch to PC 16
            dut.IMemory[3] = s_type(12'd0, 5'd2, 5'd1, 3'b010, 7'b0100011);     // wrong-path MATVEC_CTRL start
            dut.IMemory[4] = i_type(12'd11, 5'd0, 3'b000, 5'd10, 7'b0010011);   // branch target marker
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            checking_enabled = 1'b1;
            run_cycles(180);
            checking_enabled = 1'b0;

            check_reg(10, 32'd11);
            check_matvec_reset_state("branch taken flush");
        end
    endtask

    task run_jal_case;
        begin
            reset_cpu();
            wrong_path_store_pc = 32'd12;

            dut.IMemory[0] = i_type(12'd1792, 5'd0, 3'b000, 5'd1, 7'b0010011);  // x1 = MATVEC Scratchpad base
            dut.IMemory[1] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);     // x2 = start value
            dut.IMemory[2] = j_type(8, 5'd0, 7'b1101111);                       // jal x0, target PC 16
            dut.IMemory[3] = s_type(12'd0, 5'd2, 5'd1, 3'b010, 7'b0100011);     // wrong-path MATVEC_CTRL start
            dut.IMemory[4] = i_type(12'd22, 5'd0, 3'b000, 5'd11, 7'b0010011);   // jump target marker
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            checking_enabled = 1'b1;
            run_cycles(180);
            checking_enabled = 1'b0;

            check_reg(11, 32'd22);
            check_matvec_reset_state("jal flush");
        end
    endtask

    task run_trap_case;
        begin
            reset_cpu();
            wrong_path_store_pc = 32'd20;

            dut.IMemory[0] = i_type(12'd1792, 5'd0, 3'b000, 5'd1, 7'b0010011);  // x1 = MATVEC Scratchpad base
            dut.IMemory[1] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);     // x2 = start value
            dut.IMemory[2] = i_type(12'd32, 5'd0, 3'b000, 5'd5, 7'b0010011);    // x5 = trap handler PC
            dut.IMemory[3] = i_type(12'h305, 5'd5, 3'b001, 5'd0, 7'b1110011);   // csrrw x0, mtvec, x5
            dut.IMemory[4] = ECALL;                                             // trap at PC 16
            dut.IMemory[5] = s_type(12'd0, 5'd2, 5'd1, 3'b010, 7'b0100011);     // wrong-path MATVEC_CTRL start
            dut.IMemory[6] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);    // wrong-path marker
            dut.IMemory[8] = i_type(12'd33, 5'd0, 3'b000, 5'd12, 7'b0010011);   // trap handler marker
            dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            checking_enabled = 1'b1;
            run_cycles(220);
            checking_enabled = 1'b0;

            if (dut.CSRmtvec !== 32'd32 ||
                dut.CSRmepc !== 32'd16 ||
                dut.CSRmcause !== 32'd11) begin
                $display("FAIL: trap state mtvec=%h mepc=%h mcause=%h", dut.CSRmtvec, dut.CSRmepc, dut.CSRmcause);
                $fatal;
            end
            check_reg(6, 32'd6);
            check_reg(12, 32'd33);
            check_matvec_reset_state("trap redirect flush");
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_matvec_scratchpad_flush.vcd");
        $dumpvars(0, tb_assert_matvec_scratchpad_flush);

        run_branch_case();
        run_jal_case();
        run_trap_case();

        $display("PASS: tb_assert_matvec_scratchpad_flush passed");
        $finish;
    end

endmodule
