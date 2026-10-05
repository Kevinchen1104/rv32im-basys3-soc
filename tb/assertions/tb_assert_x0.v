`timescale 1ns / 1ps

// Checks: Attempted writes through several paths neither change architectural
// x0 nor create a forwarding producer for it.

module tb_assert_x0;

`include "tb_common.vh"

    reg checking_enabled = 1'b0;

    function [31:0] u_type;
        input [19:0] imm;
        input [4:0] rd;
        input [6:0] opcode;
        begin
            u_type = {imm, rd, opcode};
        end
    endfunction

    always @(posedge clock) begin
        if (checking_enabled && dut.Regs[0] !== 32'h0) begin
            $display("FAIL: x0 changed to %h", dut.Regs[0]);
            $fatal;
        end
        if (checking_enabled &&
            ((dut.EXMEMForwardRegWrite || dut.EXMEMWritebackRegWrite) &&
             dut.EXMEMForwardRd == 5'd0)) begin
            $display("FAIL: attempted x0 write entered EX/MEM write metadata");
            $fatal;
        end
        if (checking_enabled && dut.MEMWBForwardRegWrite &&
            (!dut.MEMWBValid || dut.MEMWBForwardRd == 5'd0)) begin
            $display("FAIL: attempted x0/invalid write entered MEM/WB write metadata");
            $fatal;
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_assert_x0.vcd");
        $dumpvars(0, tb_assert_x0);
        reset_cpu();
        checking_enabled = 1'b1;

        dut.DMemory[0] = 32'hdead_beef;
        dut.IMemory[0] = i_type(12'd123, 5'd0, 3'b000, 5'd0, 7'b0010011);  // addi x0, x0, 123
        dut.IMemory[1] = i_type(12'd5, 5'd0, 3'b000, 5'd1, 7'b0010011);    // addi x1, x0, 5
        dut.IMemory[2] = r_type(7'b0000000, 5'd1, 5'd1, 3'b000, 5'd0, 7'b0110011);  // add x0, x1, x1
        dut.IMemory[3] = i_type(12'd0, 5'd0, 3'b010, 5'd0, 7'b0000011);    // lw x0, 0(x0)
        dut.IMemory[4] = u_type(20'h12345, 5'd0, 7'b0110111);              // lui x0, 0x12345
        dut.IMemory[5] = j_type(8, 5'd0, 7'b1101111);                      // jal x0, target
        dut.IMemory[6] = i_type(12'd77, 5'd0, 3'b000, 5'd2, 7'b0010011);   // skipped
        dut.IMemory[7] = i_type(12'd9, 5'd0, 3'b000, 5'd3, 7'b0010011);    // target
        dut.IMemory[8] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);        // loop

        run_cycles(180);

        check_reg(0, 32'h0);
        check_reg(1, 32'd5);
        check_reg(2, 32'd2);
        check_reg(3, 32'd9);
        $display("PASS: tb_assert_x0 passed");
        $finish;
    end

endmodule
