`timescale 1ns / 1ps

// Testbench: tb_alu
// Purpose: Checks the shared execute-result datapath directly and through focused CPU dependencies.
// Checks: Raw arithmetic/address output, result selection, forwarding, subword addresses, and architectural results.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_alu;

`include "tb_common.vh"

    reg [6:0] result_opcode;
    reg [2:0] result_funct3;
    reg [6:0] result_funct7;
    reg [31:0] result_lhs;
    reg [31:0] result_rhs;
    reg [31:0] result_imm_i;
    reg [31:0] result_imm_s;
    reg [31:0] result_imm_u;
    reg [31:0] result_pc;
    reg [31:0] result_rv32m;
    reg [31:0] result_csr;
    wire [31:0] arithmetic_result;
    wire arithmetic_result_selected;
    wire [31:0] execute_result;

    reg address_check_enabled = 1'b0;
    reg address_check_pending = 1'b0;
    reg [31:0] expected_memory_address = 32'h0;
    integer rv32m_funct3_index;

    riscv_alu result_path_dut (
        .opcode(result_opcode),
        .funct3(result_funct3),
        .funct7(result_funct7),
        .lhs(result_lhs),
        .rhs(result_rhs),
        .imm_i(result_imm_i),
        .imm_s(result_imm_s),
        .imm_u(result_imm_u),
        .pc(result_pc),
        .rv32m_result(result_rv32m),
        .csr_result(result_csr),
        .arithmetic_result(arithmetic_result),
        .arithmetic_result_selected(arithmetic_result_selected),
        .result(execute_result)
    );

    task set_result_defaults;
    begin
        result_opcode = 7'b0110011;
        result_funct3 = 3'b000;
        result_funct7 = 7'b0000000;
        result_lhs = 32'h0;
        result_rhs = 32'h0;
        result_imm_i = 32'h0;
        result_imm_s = 32'h0;
        result_imm_u = 32'h0;
        result_pc = 32'h0;
        result_rv32m = 32'h0;
        result_csr = 32'h0;
    end
    endtask

    task check_result_class;
        input [255:0] name;
        input expected_arithmetic_class;
        input [31:0] expected_arithmetic;
        input [31:0] expected_execute;
    begin
        #1;
        if (result_path_dut.is_arithmetic_result_instruction !== expected_arithmetic_class ||
            arithmetic_result_selected !== expected_arithmetic_class ||
            arithmetic_result !== expected_arithmetic ||
            execute_result !== expected_execute) begin
            $display("FAIL: %0s expected class=%b arithmetic=%h execute=%h, got class=%b selected=%b arithmetic=%h execute=%h",
                     name, expected_arithmetic_class, expected_arithmetic, expected_execute,
                     result_path_dut.is_arithmetic_result_instruction,
                     arithmetic_result_selected,
                     arithmetic_result, execute_result);
            $fatal;
        end
        if (expected_arithmetic_class && (execute_result !== arithmetic_result)) begin
            $display("FAIL: %0s arithmetic class did not select arithmetic_result", name);
            $fatal;
        end
        if (!expected_arithmetic_class &&
            (execute_result !== result_path_dut.non_arithmetic_result)) begin
            $display("FAIL: %0s non-arithmetic class selected the arithmetic cone", name);
            $fatal;
        end
    end
    endtask

    task check_arithmetic_outputs;
        input [255:0] name;
        input [31:0] expected_arithmetic;
        input [31:0] expected_execute;
    begin
        #1;
        if (arithmetic_result !== expected_arithmetic ||
            execute_result !== expected_execute) begin
            $display("FAIL: %0s expected arithmetic=%h execute=%h, got arithmetic=%h execute=%h",
                     name, expected_arithmetic, expected_execute,
                     arithmetic_result, execute_result);
            $fatal;
        end
    end
    endtask

    always @(posedge clock) begin
        if (reset || !address_check_enabled) begin
            address_check_pending <= 1'b0;
            expected_memory_address <= 32'h0;
        end else begin
            if (address_check_pending &&
                (dut.EXMEMALUOut !== expected_memory_address)) begin
                $display("FAIL: EX/MEM address expected %h, got %h",
                         expected_memory_address, dut.EXMEMALUOut);
                $fatal;
            end

            address_check_pending <=
                dut.ex_advance &&
                !dut.rv32m_execute_stall &&
                !dut.exception_taken &&
                !dut.interrupt_taken &&
                !dut.control_redirect_apply &&
                dut.IDEXValid &&
                (dut.IDEXMemRead || dut.IDEXMemWrite);
            expected_memory_address <= dut.execute_arithmetic_result;

            if (dut.IDEXValid && dut.IDEXMemRead &&
                (dut.load_address_low !== dut.execute_arithmetic_result[1:0])) begin
                $display("FAIL: load alignment-low path %h disagrees with full address %h",
                         dut.load_address_low, dut.execute_arithmetic_result);
                $fatal;
            end
            if (dut.IDEXValid && dut.IDEXMemWrite &&
                (dut.store_address_low !== dut.execute_arithmetic_result[1:0])) begin
                $display("FAIL: store alignment-low path %h disagrees with full address %h",
                         dut.store_address_low, dut.execute_arithmetic_result);
                $fatal;
            end
        end
    end

    task check_execute_result;
        input [255:0] name;
        input [31:0] expected;
    begin
        #1;
        if (execute_result !== expected) begin
            $display("FAIL: %0s expected %h, got %h", name, expected, execute_result);
            $fatal;
        end
    end
    endtask

    initial begin
        $dumpfile("wave/tb_alu.vcd");
        $dumpvars(0, tb_alu);

        set_result_defaults();
        result_lhs = 32'hffff_ffff;
        result_rhs = 32'h0000_0001;
        check_execute_result("ADD wraparound", 32'h0000_0000);

        set_result_defaults();
        result_funct7 = 7'b0100000;
        result_lhs = 32'h0000_0000;
        result_rhs = 32'h0000_0001;
        check_execute_result("SUB wraparound", 32'hffff_ffff);

        set_result_defaults();
        result_opcode = 7'b0010011;
        result_lhs = 32'hffff_ffff;
        result_imm_i = 32'h0000_0001;
        check_execute_result("ADDI shared adder", 32'h0000_0000);

        set_result_defaults();
        result_opcode = 7'b0010111;
        result_pc = 32'hffff_f004;
        result_imm_u = 32'h0000_1000;
        check_execute_result("AUIPC shared adder", 32'h0000_0004);

        set_result_defaults();
        result_opcode = 7'b0110111;
        result_imm_u = 32'h1234_5000;
        check_execute_result("LUI", 32'h1234_5000);

        set_result_defaults();
        result_funct3 = 3'b111;
        result_lhs = 32'ha5a5_0ff0;
        result_rhs = 32'h0ff0_f0f0;
        check_execute_result("AND", 32'h05a0_00f0);

        result_funct3 = 3'b110;
        check_execute_result("OR", 32'haff5_fff0);

        result_funct3 = 3'b100;
        check_execute_result("XOR", 32'haa55_ff00);

        set_result_defaults();
        result_funct3 = 3'b001;
        result_lhs = 32'h0000_0001;
        result_rhs = 32'h0000_001f;
        check_execute_result("SLL", 32'h8000_0000);

        result_funct3 = 3'b101;
        result_funct7 = 7'b0100000;
        result_lhs = 32'h8000_0000;
        result_rhs = 32'h0000_0001;
        check_execute_result("SRA", 32'hc000_0000);

        set_result_defaults();
        result_funct3 = 3'b010;
        result_lhs = 32'hffff_ffff;
        result_rhs = 32'h0000_0001;
        check_execute_result("SLT", 32'h0000_0001);

        result_funct3 = 3'b011;
        check_execute_result("SLTU", 32'h0000_0000);

        set_result_defaults();
        result_opcode = 7'b0000011;
        result_lhs = 32'h0000_1000;
        result_imm_i = 32'hffff_ffff;
        check_arithmetic_outputs("load negative immediate", 32'h0000_0fff, 32'h0000_0fff);

        result_lhs = 32'h0000_1000;
        result_imm_i = 32'h0000_0002;
        check_arithmetic_outputs("load positive immediate", 32'h0000_1002, 32'h0000_1002);

        set_result_defaults();
        result_opcode = 7'b0100011;
        result_lhs = 32'hffff_fffc;
        result_imm_s = 32'h0000_0004;
        check_arithmetic_outputs("store address wraparound", 32'h0000_0000, 32'h0000_0000);

        result_lhs = 32'h0000_1000;
        result_imm_s = 32'hffff_fffc;
        check_arithmetic_outputs("store negative immediate", 32'h0000_0ffc, 32'h0000_0ffc);

        set_result_defaults();
        result_funct7 = 7'b0000001;
        result_rv32m = 32'h89ab_cdef;
        check_execute_result("RV32M result mux", 32'h89ab_cdef);

        set_result_defaults();
        result_opcode = 7'b1110011;
        result_lhs = 32'h1111_1111;
        result_imm_i = 32'h0000_0001;
        result_csr = 32'h1357_9bdf;
        check_arithmetic_outputs("CSR bypasses raw arithmetic output", 32'h1111_1112, 32'h1357_9bdf);

        // Arithmetic class: one shared add/sub result and one final class select.
        set_result_defaults();
        result_lhs = 32'hffff_ffff;
        result_rhs = 32'h0000_0001;
        check_result_class("ADD arithmetic class wraparound", 1'b1, 32'h0, 32'h0);

        set_result_defaults();
        result_funct7 = 7'b0100000;
        result_lhs = 32'h8000_0000;
        result_rhs = 32'h0000_0001;
        check_result_class("SUB arithmetic class signed wraparound", 1'b1,
                           32'h7fff_ffff, 32'h7fff_ffff);

        set_result_defaults();
        result_opcode = 7'b0010011;
        result_lhs = 32'h0102_0304;
        result_imm_i = 32'hffff_ff80;
        check_result_class("ADDI arithmetic class negative immediate", 1'b1,
                           32'h0102_0284, 32'h0102_0284);

        set_result_defaults();
        result_opcode = 7'b0010111;
        result_pc = 32'hffff_f004;
        result_imm_u = 32'h0000_1000;
        check_result_class("AUIPC arithmetic class", 1'b1, 32'h0000_0004, 32'h0000_0004);

        set_result_defaults();
        result_opcode = 7'b0000011;
        result_lhs = 32'h0000_0001;
        result_imm_i = 32'hffff_ffff;
        result_funct3 = 3'b000;
        check_result_class("LB effective address", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b001;
        check_result_class("LH effective address", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b010;
        check_result_class("LW effective address", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b100;
        check_result_class("LBU effective address", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b101;
        check_result_class("LHU effective address", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b011;
        check_result_class("unsupported load funct3", 1'b0, 32'h0, 32'h0);

        set_result_defaults();
        result_opcode = 7'b0100011;
        result_lhs = 32'hffff_fffc;
        result_imm_s = 32'h0000_0004;
        result_funct3 = 3'b000;
        check_result_class("SB effective address wraparound", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b001;
        check_result_class("SH effective address wraparound", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b010;
        check_result_class("SW effective address wraparound", 1'b1, 32'h0, 32'h0);
        result_funct3 = 3'b011;
        check_result_class("unsupported store funct3", 1'b0, 32'h0, 32'h0);

        set_result_defaults();
        result_lhs = 32'h1020_3040;
        result_rhs = 32'h0102_0304;
        check_result_class("forwarded lhs/rhs ADD", 1'b1,
                           32'h1122_3344, 32'h1122_3344);

        // Non-arithmetic classes must use their dedicated result mux.
        set_result_defaults();
        result_lhs = 32'h8000_0001;
        result_rhs = 32'h0000_0000;
        result_funct3 = 3'b001;
        check_result_class("SLL shift 0", 1'b0, 32'h8000_0001, 32'h8000_0001);
        result_rhs = 32'h0000_001f;
        check_result_class("SLL shift 31", 1'b0, 32'h8000_0020, 32'h8000_0000);

        set_result_defaults();
        result_lhs = 32'h8000_0001;
        result_funct3 = 3'b101;
        result_rhs = 32'h0;
        check_result_class("SRL shift 0", 1'b0, 32'h8000_0001, 32'h8000_0001);
        result_rhs = 32'h1f;
        check_result_class("SRL shift 31", 1'b0, 32'h8000_0020, 32'h1);
        result_funct7 = 7'b0100000;
        result_rhs = 32'h1f;
        check_result_class("SRA shift 31", 1'b0, 32'h8000_0020, 32'hffff_ffff);

        set_result_defaults();
        result_opcode = 7'b0010011;
        result_lhs = 32'hffff_ffff;
        result_imm_i = 32'h1;
        result_funct3 = 3'b010;
        check_result_class("SLTI", 1'b0, 32'h0, 32'h1);
        result_funct3 = 3'b011;
        check_result_class("SLTIU", 1'b0, 32'h0, 32'h0);
        result_funct3 = 3'b100;
        check_result_class("XORI", 1'b0, 32'h0, 32'hffff_fffe);
        result_funct3 = 3'b110;
        check_result_class("ORI", 1'b0, 32'h0, 32'hffff_ffff);
        result_funct3 = 3'b111;
        check_result_class("ANDI", 1'b0, 32'h0, 32'h1);

        set_result_defaults();
        result_opcode = 7'b0010011;
        result_lhs = 32'h0000_0001;
        result_imm_i = 32'h0000_001f;
        result_funct3 = 3'b001;
        result_funct7 = 7'b0000000;
        check_result_class("SLLI", 1'b0, 32'h20, 32'h8000_0000);
        result_lhs = 32'h8000_0000;
        result_funct3 = 3'b101;
        check_result_class("SRLI", 1'b0, 32'h8000_001f, 32'h1);
        result_funct7 = 7'b0100000;
        check_result_class("SRAI", 1'b0, 32'h8000_001f, 32'hffff_ffff);

        set_result_defaults();
        result_opcode = 7'b0110111;
        result_imm_u = 32'h1234_5000;
        check_result_class("LUI non-arithmetic class", 1'b0, 32'h0, 32'h1234_5000);

        set_result_defaults();
        result_opcode = 7'b1110011;
        result_csr = 32'hcafe_babe;
        check_result_class("CSR non-arithmetic class", 1'b0, 32'h0, 32'hcafe_babe);

        for (rv32m_funct3_index = 0; rv32m_funct3_index < 8;
             rv32m_funct3_index = rv32m_funct3_index + 1) begin
            set_result_defaults();
            result_funct7 = 7'b0000001;
            result_funct3 = rv32m_funct3_index[2:0];
            result_rv32m = 32'h9000_0000 + rv32m_funct3_index;
            check_result_class("RV32M funct3 non-arithmetic class", 1'b0,
                               32'h0, 32'h9000_0000 + rv32m_funct3_index);
        end

        set_result_defaults();
        result_funct7 = 7'b0100000;
        result_funct3 = 3'b111;
        result_lhs = 32'h1111_1111;
        result_rhs = 32'h2222_2222;
        check_result_class("unsupported ALUR funct combination", 1'b0,
                           32'h3333_3333, 32'h0);

        reset_cpu();

        dut.IMemory[0] = i_type(12'hfff, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, -1
        dut.IMemory[1] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 1
        dut.IMemory[2] = r_type(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011);  // add
        dut.IMemory[3] = i_type(12'd7, 5'd3, 3'b000, 5'd4, 7'b0010011);  // dependent addi
        dut.IMemory[4] = r_type(7'b0000000, 5'd2, 5'd4, 3'b000, 5'd5, 7'b0110011);  // dependent add
        dut.IMemory[5] = r_type(7'b0100000, 5'd5, 5'd2, 3'b000, 5'd6, 7'b0110011);  // sub
        dut.IMemory[6] = i_type(12'd127, 5'd0, 3'b000, 5'd10, 7'b0010011);
        dut.IMemory[7] = i_type(12'd64, 5'd0, 3'b000, 5'd9, 7'b0010011);
        dut.IMemory[8] = s_type(12'd3, 5'd10, 5'd9, 3'b000, 7'b0100011);  // forwarded store address
        dut.IMemory[9] = i_type(12'd3, 5'd9, 3'b100, 5'd11, 7'b0000011);
        dut.IMemory[10] = i_type(12'd4, 5'd9, 3'b000, 5'd12, 7'b0010011);
        dut.IMemory[11] = i_type(12'hfff, 5'd12, 3'b100, 5'd13, 7'b0000011);  // forwarded load address
        dut.IMemory[12] = i_type(12'h7ff, 5'd0, 3'b000, 5'd16, 7'b0010011);
        dut.IMemory[13] = i_type(12'd2, 5'd9, 3'b000, 5'd17, 7'b0010011);
        dut.IMemory[14] = s_type(12'd0, 5'd16, 5'd17, 3'b001, 7'b0100011);  // halfword address
        dut.IMemory[15] = i_type(12'd2, 5'd9, 3'b101, 5'd18, 7'b0000011);
        dut.IMemory[16] = j_type(4, 5'd19, 7'b1101111);
        dut.IMemory[17] = i_type(12'd1, 5'd19, 3'b000, 5'd20, 7'b0010011);  // PC+4 dependency
        dut.IMemory[18] = i_type(12'd80, 5'd0, 3'b000, 5'd21, 7'b0010011);
        dut.IMemory[19] = NOP;
        dut.IMemory[20] = s_type(12'd0, 5'd10, 5'd21, 3'b010, 7'b0100011);  // MEM/WB-forwarded store base
        dut.IMemory[21] = i_type(12'd84, 5'd0, 3'b000, 5'd23, 7'b0010011);
        dut.IMemory[22] = i_type(12'hffc, 5'd23, 3'b010, 5'd22, 7'b0000011);  // EX/MEM-forwarded load base
        dut.IMemory[23] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

        address_check_enabled = 1'b1;
        run_cycles(220);
        address_check_enabled = 1'b0;

        check_reg(1, 32'hffff_ffff);
        check_reg(2, 32'd1);
        check_reg(3, 32'd0);
        check_reg(4, 32'd7);
        check_reg(5, 32'd8);
        check_reg(6, 32'hffff_fff9);
        check_reg(11, 32'd127);
        check_reg(13, 32'd127);
        check_reg(18, 32'h0000_07ff);
        check_reg(19, 32'd68);
        check_reg(20, 32'd69);
        check_reg(22, 32'd127);
        $display("PASS: tb_alu passed");
        $finish;
    end

endmodule
