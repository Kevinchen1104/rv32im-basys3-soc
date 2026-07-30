`timescale 1ns / 1ps

// Testbench: tb_program_compliance_basic
// Purpose: Runs CPU firmware as selected local ISA/compliance-style directed simulation evidence.
// Checks: A selected RV32I compliance-style instruction smoke program covering arithmetic, logical, shift, branch,
//   and word load/store behavior.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Does not prove: Selected local compliance-style smoke only; not an official compliance suite.
// Firmware: firmware/hex/isa/compliance_basic.hex

module tb_program_compliance_basic;

`include "tb_common.vh"

    localparam integer MEMORY_RESULT_WORD = 111;    // byte address 0x1bc
    localparam integer SIGNATURE_WORD = 112;        // byte address 0x1c0
    localparam [31:0] MEMORY_RESULT = 32'h1234_5678;
    localparam [31:0] PASS_SIGNATURE = 32'h1ce0_ffee;

    initial begin
        $dumpfile("wave/tb_program_compliance_basic.vcd");
        $dumpvars(0, tb_program_compliance_basic);
        reset_cpu();

        $readmemh("firmware/hex/isa/compliance_basic.hex", dut.IMemory, 0, 41);

        run_cycles(500);

        check_reg(7, 32'd10);              // t2 = add result
        check_reg(9, 32'd13);              // s1 = sub result
        check_reg(19, 32'd1);              // s3 = slt signed result
        check_reg(20, 32'd0);              // s4 = sltu unsigned result
        check_reg(22, 32'd8);              // s6 = sll result
        check_reg(24, 32'h1fff_fffe);      // s8 = srl result
        check_reg(25, 32'hffff_fffe);      // s9 = sra result
        check_reg(26, 32'd18);             // s10 = addi result
        check_reg(29, 32'd0);              // t4 = and result
        check_reg(30, 32'h0000_0fff);      // t5 = or result
        check_reg(31, 32'h0000_0fff);      // t6 = xor result
        check_reg(13, MEMORY_RESULT);      // a3 = lw result
        check_reg(14, PASS_SIGNATURE);     // a4 = pass signature

        if (dut.DMemory[MEMORY_RESULT_WORD] !== MEMORY_RESULT) begin
            $display(
                "FAIL: compliance basic expected DMemory[%0d] = %h, got %h",
                MEMORY_RESULT_WORD,
                MEMORY_RESULT,
                dut.DMemory[MEMORY_RESULT_WORD]
            );
            $fatal;
        end

        if (dut.DMemory[SIGNATURE_WORD] !== PASS_SIGNATURE) begin
            $display(
                "FAIL: compliance basic expected pass signature DMemory[%0d] = %h, got %h",
                SIGNATURE_WORD,
                PASS_SIGNATURE,
                dut.DMemory[SIGNATURE_WORD]
            );
            $fatal;
        end

        $display("PASS: selected RV32I compliance-style program completed with pass signature %h", PASS_SIGNATURE);
        $display("PASS: tb_program_compliance_basic passed");
        $finish;
    end

endmodule
