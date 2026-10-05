`timescale 1ns / 1ps

// Testbench: tb_main
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Covers the baseline five-stage CPU smoke path: ALU, load/store, branches, jumps, cache stalls, and RAS
//   call/return behavior.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_main;

    reg clock = 0;
    reg reset = 1;

    RISCVCPU dut (
        .clock(clock),
        .reset(reset),
        .imem_addr(),
        .imem_read(),
        .imem_rdata(128'h0),
        .imem_ready(1'b0),
        .dmem_addr(),
        .dmem_read(),
        .dmem_write(),
        .dmem_wdata(),
        .dmem_byte_enable(),
        .dmem_rdata(128'h0),
        .dmem_ready(1'b0),
        .gpio_inputs(32'h0),
        .gpio_outputs(),
        .uart_tx_data(),
        .uart_tx_valid(),
        .uart_tx_ready(1'b1),
        .uart_rx_data(8'h00),
        .uart_rx_valid(1'b0),
        .uart_rx_overrun(1'b0),
        .uart_rx_ready()
    );

    always #5 clock = ~clock;

    localparam NOP = 32'h00000013;

    function [31:0] r_type;
        input [6:0] funct7;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            r_type = {funct7, rs2, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] i_type;
        input [11:0] imm;
        input [4:0] rs1;
        input [2:0] funct3;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            i_type = {imm, rs1, funct3, rd, opcode};
        end
    endfunction

    function [31:0] s_type;
        input [11:0] imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        begin
            s_type = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
        end
    endfunction

    function [31:0] b_type;
        input integer imm;
        input [4:0] rs2;
        input [4:0] rs1;
        input [2:0] funct3;
        input [6:0] opcode;
        reg [12:0] bimm;
        begin
            bimm   = imm[12:0];
            b_type = {bimm[12], bimm[10:5], rs2, rs1, funct3, bimm[4:1], bimm[11], opcode};
        end
    endfunction

    function [31:0] j_type;
        input integer imm;
        input [4:0] rd;
        input [6:0] opcode;
        reg [20:0] jimm;
        begin
            jimm   = imm[20:0];
            j_type = {jimm[20], jimm[10:1], jimm[11], jimm[19:12], rd, opcode};
        end
    endfunction

    task check_reg;
        input [4:0] reg_id;
        input [31:0] expected;
        begin
            if (dut.Regs[reg_id] !== expected) begin
                $display("FAIL: x%0d expected %h, got %h", reg_id, expected, dut.Regs[reg_id]);
                $fatal;
            end
            $display("PASS: x%0d = %h", reg_id, dut.Regs[reg_id]);
        end
    endtask

    task clear_cpu;
        integer i;
        begin
            for (i = 0; i < 1024; i = i + 1) begin
                dut.IMemory[i] = NOP;
                dut.DMemory[i] = 32'h0;
            end

            reset = 1'b1;
            @(posedge clock);
            @(negedge clock);
            reset = 1'b0;
        end
    endtask

    task run_cycles;
        input integer count;
        begin
            repeat (count) @(posedge clock);
            #1;
        end
    endtask

    task test_addi;
        begin
            $display("TEST: addi");
            clear_cpu();

            dut.IMemory[0] = i_type(12'd12, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 12
            dut.IMemory[1] = i_type(12'd34, 5'd1, 3'b000, 5'd2, 7'b0010011);  // addi x2, x1, 34
            dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(80);

            check_reg(1, 32'd12);
            check_reg(2, 32'd46);
        end
    endtask

    task test_forwarding;
        begin
            $display("TEST: R-type dependency forwarding");
            clear_cpu();

            dut.IMemory[0] = i_type(12'd10, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 10
            dut.IMemory[1] = i_type(12'd20, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 20
            dut.IMemory[2] =
                r_type(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011);  // add x3, x2, x1
            dut.IMemory[3] =
                r_type(7'b0100000, 5'd1, 5'd3, 3'b000, 5'd4, 7'b0110011);  // sub x4, x3, x1
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(90);

            check_reg(3, 32'd30);
            check_reg(4, 32'd20);
        end
    endtask

    task test_unsigned_set_less_than;
        begin
            $display("TEST: sltu / sltiu");
            clear_cpu();

            dut.IMemory[0] = i_type(12'hfff, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, -1
            dut.IMemory[1] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 1
            dut.IMemory[2] = r_type(7'b0000000, 5'd2, 5'd1, 3'b010, 5'd3,
                                    7'b0110011);  // slt x3, x1, x2 should be 1 because -1 < 1
            dut.IMemory[3] = r_type(7'b0000000, 5'd2, 5'd1, 3'b011, 5'd4, 7'b0110011)
                ;  // sltu x4, x1, x2 should be 0 because 0xffff_ffff is not < 1 unsigned
            dut.IMemory[4] = i_type(12'd1, 5'd1, 3'b010, 5'd5,
                                    7'b0010011);  // slti x5, x1, 1 should be 1 because -1 < 1
            dut.IMemory[5] = i_type(12'd1, 5'd1, 3'b011, 5'd6, 7'b0010011)
                ;  // sltiu x6, x1, 1 should be 0 because 0xffff_ffff is not < 1 unsigned
            dut.IMemory[6] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(110);

            check_reg(1, 32'hffff_ffff);
            check_reg(2, 32'd1);
            check_reg(3, 32'd1);
            check_reg(4, 32'd0);
            check_reg(5, 32'd1);
            check_reg(6, 32'd0);
        end
    endtask

    task test_load_use;
        begin
            $display("TEST: lw load-use stall");
            clear_cpu();

            dut.DMemory[0] = 32'd55;

            dut.IMemory[0] = i_type(12'd0, 5'd0, 3'b010, 5'd1, 7'b0000011);  // lw x1, 0(x0)
            dut.IMemory[1] = i_type(12'd7, 5'd1, 3'b000, 5'd2, 7'b0010011);  // addi x2, x1, 7
            dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(110);

            check_reg(1, 32'd55);
            check_reg(2, 32'd62);
        end
    endtask

    task test_store_load;
        begin
            $display("TEST: sw / lw");
            clear_cpu();

            dut.IMemory[0] = i_type(12'd99, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 99
            dut.IMemory[1] = s_type(12'd16, 5'd1, 5'd0, 3'b010, 7'b0100011);  // sw x1, 16(x0)
            dut.IMemory[2] = i_type(12'd16, 5'd0, 3'b010, 5'd2, 7'b0000011);  // lw x2, 16(x0)
            dut.IMemory[3] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(120);

            check_reg(1, 32'd99);
            check_reg(2, 32'd99);
            if (dut.DCacheDirty[1] !== 1'b1) begin
                $display("FAIL: expected D-cache line 1 to be dirty after sw");
                $fatal;
            end
            $display("PASS: D-cache line 1 dirty after sw");
        end
    endtask

    task test_byte_halfword_memory;
        begin
            $display("TEST: byte / halfword load-store");
            clear_cpu();

            dut.DMemory[0]  = 32'h80ff_7f01;
            dut.DMemory[1]  = 32'h1234_5678;
            dut.DMemory[2]  = 32'h1122_3344;

            dut.IMemory[0]  = i_type(12'd2, 5'd0, 3'b000, 5'd10, 7'b0010011);  // addi x10, x0, 2
            dut.IMemory[1]  = i_type(12'd0, 5'd0, 3'b000, 5'd1, 7'b0000011);  // lb x1, 0(x0)
            dut.IMemory[2]  = i_type(12'd2, 5'd0, 3'b000, 5'd2, 7'b0000011);  // lb x2, 2(x0)
            dut.IMemory[3]  = i_type(12'd2, 5'd0, 3'b100, 5'd3, 7'b0000011);  // lbu x3, 2(x0)
            dut.IMemory[4]  = i_type(12'd0, 5'd0, 3'b001, 5'd4, 7'b0000011);  // lh x4, 0(x0)
            dut.IMemory[5]  = i_type(12'd2, 5'd0, 3'b001, 5'd5, 7'b0000011);  // lh x5, 2(x0)
            dut.IMemory[6]  = i_type(12'd2, 5'd0, 3'b101, 5'd6, 7'b0000011);  // lhu x6, 2(x0)
            dut.IMemory[7]  = s_type(12'd5, 5'd10, 5'd0, 3'b000, 7'b0100011);  // sb x10, 5(x0)
            dut.IMemory[8]  = i_type(12'd4, 5'd0, 3'b010, 5'd7, 7'b0000011);  // lw x7, 4(x0)
            dut.IMemory[9]  = s_type(12'd8, 5'd10, 5'd0, 3'b001, 7'b0100011);  // sh x10, 8(x0)
            dut.IMemory[10] = i_type(12'd8, 5'd0, 3'b010, 5'd8, 7'b0000011);  // lw x8, 8(x0)
            dut.IMemory[11] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            run_cycles(180);

            check_reg(1, 32'h0000_0001);
            check_reg(2, 32'hffff_ffff);
            check_reg(3, 32'h0000_00ff);
            check_reg(4, 32'h0000_7f01);
            check_reg(5, 32'hffff_80ff);
            check_reg(6, 32'h0000_80ff);
            check_reg(7, 32'h1234_0278);
            check_reg(8, 32'h1122_0002);
        end
    endtask

    task test_stall_flush_priority;
        begin
            $display("TEST: cache stall / load-use / branch priority");
            clear_cpu();

            dut.DMemory[0] = 32'd41;
            dut.DMemory[4] = 32'd42;

            dut.IMemory[0]  = i_type(12'd0, 5'd0, 3'b010, 5'd1,
                                     7'b0000011);  // lw x1, 0(x0), D-cache miss
            dut.IMemory[1]  = i_type(12'd1, 5'd1, 3'b000, 5'd2,
                                     7'b0010011);  // addi x2, x1, 1, load-use
            dut.IMemory[2]  = i_type(12'd42, 5'd0, 3'b000, 5'd3,
                                     7'b0010011);  // addi x3, x0, 42
            dut.IMemory[3]  = NOP;
            dut.IMemory[4]  = b_type(8, 5'd3, 5'd2, 3'b000,
                                     7'b1100011);  // beq x2, x3, 8
            dut.IMemory[5]  = i_type(12'd77, 5'd0, 3'b000, 5'd4,
                                     7'b0010011);  // addi x4, x0, 77 should be skipped
            dut.IMemory[6]  = i_type(12'd16, 5'd0, 3'b010, 5'd5,
                                     7'b0000011);  // lw x5, 16(x0), D-cache miss
            dut.IMemory[7]  = b_type(8, 5'd2, 5'd5, 3'b000,
                                     7'b1100011);  // beq x5, x2, 8, load-use after miss
            dut.IMemory[8]  = i_type(12'd88, 5'd0, 3'b000, 5'd6,
                                     7'b0010011);  // addi x6, x0, 88 should be skipped
            dut.IMemory[9]  = i_type(12'd99, 5'd0, 3'b000, 5'd7,
                                     7'b0010011);  // addi x7, x0, 99
            dut.IMemory[10] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            run_cycles(200);

            check_reg(1, 32'd41);
            check_reg(2, 32'd42);
            check_reg(3, 32'd42);
            check_reg(4, 32'd4);
            check_reg(5, 32'd42);
            check_reg(6, 32'd6);
            check_reg(7, 32'd99);
        end
    endtask

    task test_branch;
        begin
            $display("TEST: beq taken / not taken");
            clear_cpu();

            dut.IMemory[0] = i_type(12'd5, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 5
            dut.IMemory[1] = i_type(12'd5, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 5
            dut.IMemory[2] = i_type(12'd7, 5'd0, 3'b000, 5'd3, 7'b0010011);  // addi x3, x0, 7
            dut.IMemory[3] = NOP;
            dut.IMemory[4] = NOP;
            dut.IMemory[5] = b_type(8, 5'd2, 5'd1, 3'b000, 7'b1100011);  // beq x2, x1, 8
            dut.IMemory[6] = i_type(12'd111, 5'd0, 3'b000, 5'd4,
                                    7'b0010011);  // addi x4, x0, 111 should be skipped
            dut.IMemory[7] = b_type(8, 5'd3, 5'd1, 3'b000, 7'b1100011);  // beq x3, x1, 8
            dut.IMemory[8] = i_type(12'd88, 5'd0, 3'b000, 5'd8,
                                    7'b0010011);  // addi x8, x0, 88 should be executed
            dut.IMemory[9] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(120);

            check_reg(1, 32'd5);
            check_reg(2, 32'd5);
            check_reg(3, 32'd7);
            check_reg(4, 32'd4);
            check_reg(8, 32'd88);
        end
    endtask

    task test_unsigned_branch;
        begin
            $display("TEST: bltu / bgeu unsigned branch");
            clear_cpu();

            dut.IMemory[0] =
                i_type(12'hfff, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, -1 (0xffff_ffff)
            dut.IMemory[1] = i_type(12'd1, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 1
            dut.IMemory[2] = NOP;
            dut.IMemory[3] = NOP;
            dut.IMemory[4] = NOP;
            dut.IMemory[5] =
                b_type(8, 5'd2, 5'd1, 3'b110, 7'b1100011);  // bltu x1, x2, 8 should not branch
            dut.IMemory[6] = i_type(12'd33, 5'd0, 3'b000, 5'd3, 7'b0010011);  // addi x3, x0, 33
            dut.IMemory[7] =
                b_type(8, 5'd2, 5'd1, 3'b111, 7'b1100011);  // bgeu x1, x2, 8 should branch
            dut.IMemory[8] = i_type(12'd44, 5'd0, 3'b000, 5'd4,
                                    7'b0010011);  // addi x4, x0, 44 should be skipped
            dut.IMemory[9] =
                b_type(8, 5'd1, 5'd2, 3'b110, 7'b1100011);  // bltu x2, x1, 8 should branch
            dut.IMemory[10] = i_type(12'd55, 5'd0, 3'b000, 5'd5,
                                     7'b0010011);  // addi x5, x0, 55 should be skipped
            dut.IMemory[11] = i_type(12'd66, 5'd0, 3'b000, 5'd6, 7'b0010011);  // addi x6, x0, 66
            dut.IMemory[12] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);

            run_cycles(160);

            check_reg(1, 32'hffff_ffff);
            check_reg(2, 32'd1);
            check_reg(3, 32'd33);
            check_reg(4, 32'd4);
            check_reg(5, 32'd5);
            check_reg(6, 32'd66);
        end
    endtask

    task test_jal;
        begin
            $display("TEST: jal");
            clear_cpu();

            dut.IMemory[0] = j_type(12, 5'd5, 7'b1101111);  // jal x5, 12
            dut.IMemory[1] = i_type(12'd99, 5'd0, 3'b000, 5'd6,
                                    7'b0010011);  // addi x6, x0, 99 should be skipped
            dut.IMemory[2] = NOP;
            dut.IMemory[3] = i_type(12'd42, 5'd0, 3'b000, 5'd7,
                                    7'b0010011);  // addi x7, x0, 42 should be executed
            dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(90);

            check_reg(5, 32'd4);
            check_reg(6, 32'd6);
            check_reg(7, 32'd42);
        end
    endtask

    task test_jalr;
        begin
            $display("TEST: jalr");
            clear_cpu();

            dut.IMemory[0] = i_type(12'd16, 5'd0, 3'b000, 5'd1, 7'b0010011);  // addi x1, x0, 16
            dut.IMemory[1] = i_type(12'd0, 5'd1, 3'b000, 5'd5, 7'b1100111);  // jalr x5, 0(x1)
            dut.IMemory[2] = i_type(12'd99, 5'd0, 3'b000, 5'd6,
                                    7'b0010011);  // addi x6, x0, 99 should be skipped
            dut.IMemory[3] = NOP;
            dut.IMemory[4] = i_type(12'd77, 5'd0, 3'b000, 5'd7,
                                    7'b0010011);  // addi x7, x0, 77 should be executed
            dut.IMemory[5] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0

            run_cycles(100);

            check_reg(5, 32'd8);
            check_reg(6, 32'd6);
            check_reg(7, 32'd77);
        end
    endtask

    task test_ras_call_return;
        begin
            $display("TEST: RAS call / return");
            clear_cpu();

            dut.IMemory[0] = j_type(16, 5'd1, 7'b1101111);  // jal x1, 16
            dut.IMemory[1] = i_type(12'd22, 5'd0, 3'b000, 5'd3,
                                    7'b0010011);  // addi x3, x0, 22 should be executed after return
            dut.IMemory[2] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);  // beq x0, x0, 0
            dut.IMemory[3] = NOP;
            dut.IMemory[4] = i_type(12'd11, 5'd0, 3'b000, 5'd2, 7'b0010011);  // addi x2, x0, 11
            dut.IMemory[5] = i_type(12'd0, 5'd1, 3'b000, 5'd0, 7'b1100111);  // jalr x0, 0(x1)
            dut.IMemory[6] = i_type(12'd66, 5'd0, 3'b000, 5'd7, 7'b0010011)
                ;  // Wrong-path instruction after JALR; must be flushed.
            dut.IMemory[7] = NOP;
            dut.IMemory[8] = NOP;
            dut.IMemory[9] = NOP;

            run_cycles(140);

            check_reg(1, 32'd4);
            check_reg(2, 32'd11);
            check_reg(3, 32'd22);
            check_reg(7, 32'd7);

            if (dut.RASCount !== 4'd0) begin
                $display("FAIL: RASCount expected 0, got %0d", dut.RASCount);
                $fatal;
            end
            $display("PASS: RASCount returned to 0");
        end
    endtask

    initial begin
        $dumpfile("results/waveforms/dump.vcd");
        $dumpvars(0, tb_main);
        #1; // Initialize test memory after the DUT initial block.

        test_addi();
        test_forwarding();
        test_unsigned_set_less_than();
        test_load_use();
        test_store_load();
        test_byte_halfword_memory();
        test_stall_flush_priority();
        test_branch();
        test_unsigned_branch();
        test_jal();
        test_jalr();
        test_ras_call_return();

        $display("----------------------------------------");
        $display("PASS: CPU self-checking testbench passed");
        $display("----------------------------------------");

        $finish;
    end

endmodule
