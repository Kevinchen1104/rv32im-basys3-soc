`timescale 1ns / 1ps

// Checks: Illegal-instruction, misaligned-load, and misaligned-store traps are precise: faulting register writes are
//   blocked, faulting/wrong-path stores do not reach MEM, wrong-path register writes are suppressed, and
//   mepc/mcause/mtval capture the documented values.
// tb_assert_control_transfer_legality_alignment checks instruction-address alignment.

module tb_assert_precise_exception_commit;

`include "tb_common.vh"

    localparam [31:0] ILLEGAL_WITH_RD5 = 32'h0000_028b;
    localparam [31:0] SENTINEL = 32'h1122_3344;

    reg checking_enabled = 1'b0;
    reg [31:0] fault_pc = 32'h0;
    reg [31:0] wrong_store_pc = 32'h0;
    reg [31:0] wrong_reg_pc = 32'h0;

    always @(posedge clock) begin
        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            (dut.MEMWBPC == fault_pc)) begin
            $display("FAIL: faulting instruction at PC %h reached writeback", dut.MEMWBPC);
            $fatal;
        end

        if (checking_enabled &&
            dut.MEMWBValid &&
            dut.MEMWBRegWrite &&
            (dut.MEMWBPC == wrong_reg_pc)) begin
            $display("FAIL: wrong-path register write at PC %h reached writeback", dut.MEMWBPC);
            $fatal;
        end

        if (checking_enabled &&
            dut.EXMEMValid &&
            dut.EXMEMMemWrite &&
            ((dut.EXMEMPC == fault_pc) || (dut.EXMEMPC == wrong_store_pc))) begin
            $display("FAIL: faulting/wrong-path store at PC %h reached MEM", dut.EXMEMPC);
            $fatal;
        end
    end

    task run_illegal_phase;
        begin
            reset_cpu();
            dut.DMemory[0] = SENTINEL;
            dut.IMemory[0] = i_type(12'd24, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[2] = ILLEGAL_WITH_RD5;
            dut.IMemory[3] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[4] = s_type(12'd0, 5'd6, 5'd0, 3'b010, 7'b0100011);
            dut.IMemory[5] = NOP;
            dut.IMemory[6] = i_type(12'd77, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[7] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd8;
            wrong_reg_pc = 32'd12;
            wrong_store_pc = 32'd16;
            checking_enabled = 1'b1;
            run_cycles(180);
            checking_enabled = 1'b0;

            if (dut.CSRmepc !== 32'd8 ||
                dut.CSRmcause !== 32'd2 ||
                dut.CSRmtval !== ILLEGAL_WITH_RD5) begin
                $display("FAIL: illegal trap evidence mepc=%h mcause=%h mtval=%h",
                         dut.CSRmepc,
                         dut.CSRmcause,
                         dut.CSRmtval);
                $fatal;
            end
            check_reg(5, 32'd5);
            check_reg(6, 32'd6);
            check_reg(7, 32'd77);
            if (dut.DMemory[0] !== SENTINEL) begin
                $display("FAIL: illegal wrong-path store changed DMemory[0] to %h", dut.DMemory[0]);
                $fatal;
            end
        end
    endtask

    task run_misaligned_load_phase;
        begin
            reset_cpu();
            dut.DMemory[16] = SENTINEL;
            dut.IMemory[0] = i_type(12'd32, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[2] = i_type(12'd99, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[3] = 32'h8000_0437;  // lui x8, 0x80000
            dut.IMemory[4] = i_type(12'd2, 5'd8, 3'b010, 5'd5, 7'b0000011);
            dut.IMemory[5] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[6] = s_type(12'd64, 5'd6, 5'd0, 3'b010, 7'b0100011);
            dut.IMemory[7] = NOP;
            dut.IMemory[8] = i_type(12'd88, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd16;
            wrong_reg_pc = 32'd20;
            wrong_store_pc = 32'd24;
            checking_enabled = 1'b1;
            run_cycles(200);
            checking_enabled = 1'b0;

            if (dut.CSRmepc !== 32'd16 ||
                dut.CSRmcause !== 32'd4 ||
                dut.CSRmtval !== 32'h8000_0002) begin
                $display("FAIL: misaligned load evidence mepc=%h mcause=%h mtval=%h",
                         dut.CSRmepc,
                         dut.CSRmcause,
                         dut.CSRmtval);
                $fatal;
            end
            check_reg(5, 32'd99);
            check_reg(6, 32'd6);
            check_reg(7, 32'd88);
            if (dut.DMemory[16] !== SENTINEL) begin
                $display("FAIL: load wrong-path store changed DMemory[16] to %h", dut.DMemory[16]);
                $fatal;
            end
        end
    endtask

    task run_misaligned_store_phase;
        begin
            reset_cpu();
            dut.DMemory[16] = SENTINEL;
            dut.IMemory[0] = i_type(12'd36, 5'd0, 3'b000, 5'd1, 7'b0010011);
            dut.IMemory[1] = i_type(12'h305, 5'd1, 3'b001, 5'd0, 7'b1110011);
            dut.IMemory[2] = i_type(12'd55, 5'd0, 3'b000, 5'd5, 7'b0010011);
            dut.IMemory[3] = 32'h8000_0437;  // lui x8, 0x80000
            dut.IMemory[4] = NOP;
            dut.IMemory[5] = s_type(12'd2, 5'd5, 5'd8, 3'b010, 7'b0100011);
            dut.IMemory[6] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);
            dut.IMemory[7] = s_type(12'd64, 5'd6, 5'd0, 3'b010, 7'b0100011);
            dut.IMemory[8] = NOP;
            dut.IMemory[9] = i_type(12'd99, 5'd0, 3'b000, 5'd7, 7'b0010011);
            dut.IMemory[10] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            fault_pc = 32'd20;
            wrong_reg_pc = 32'd24;
            wrong_store_pc = 32'd28;
            checking_enabled = 1'b1;
            run_cycles(200);
            checking_enabled = 1'b0;

            if (dut.CSRmepc !== 32'd20 ||
                dut.CSRmcause !== 32'd6 ||
                dut.CSRmtval !== 32'h8000_0002) begin
                $display("FAIL: misaligned store evidence mepc=%h mcause=%h mtval=%h",
                         dut.CSRmepc,
                         dut.CSRmcause,
                         dut.CSRmtval);
                $fatal;
            end
            check_reg(5, 32'd55);
            check_reg(6, 32'd6);
            check_reg(7, 32'd99);
            if (dut.DMemory[16] !== SENTINEL) begin
                $display("FAIL: faulting/wrong-path store changed DMemory[16] to %h", dut.DMemory[16]);
                $fatal;
            end
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/tb_assert_precise_exception_commit.vcd");
        $dumpvars(0, tb_assert_precise_exception_commit);

        run_illegal_phase();
        run_misaligned_load_phase();
        run_misaligned_store_phase();

        $display("PASS: tb_assert_precise_exception_commit passed");
        $finish;
    end

endmodule
