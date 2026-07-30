# Program: rv32i_alu_compliance
# Purpose: Runs selected local RV32I ALU compliance-style checks.
# Exercises: Register/immediate arithmetic, logic, comparisons, shifts, sign-bit/zero/-1 cases, shift 0/31, and x0
#   suppression.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_rv32i_alu_compliance
# Does not claim: Not an official compliance suite or exhaustive ISA proof.

# Selected local RV32I ALU compliance-style test.
# This is not an official compliance suite.

    li   t0, 10
    li   t1, -3
    add  t2, t0, t1
    li   t3, 7
    bne  t2, t3, fail

    sub  t2, t0, t1
    li   t3, 13
    bne  t2, t3, fail

    li   t0, 0x0f0f0f0f
    li   t1, 0x00ff00ff
    and  t2, t0, t1
    li   t3, 0x000f000f
    bne  t2, t3, fail
    or   t2, t0, t1
    li   t3, 0x0fff0fff
    bne  t2, t3, fail
    xor  t2, t0, t1
    li   t3, 0x0ff00ff0
    bne  t2, t3, fail

    li   t0, -1
    li   t1, 1
    slt  t2, t0, t1
    li   t3, 1
    bne  t2, t3, fail
    sltu t2, t0, t1
    bne  t2, zero, fail
    sltu t2, t1, t0
    li   t3, 1
    bne  t2, t3, fail

    li   t0, 1
    li   t1, 31
    sll  t2, t0, t1
    li   t3, 0x80000000
    bne  t2, t3, fail
    srl  t2, t3, t1
    li   t4, 1
    bne  t2, t4, fail
    sra  t2, t3, t1
    li   t4, -1
    bne  t2, t4, fail
    li   t1, 0
    sll  t2, t3, t1
    bne  t2, t3, fail
    srl  t2, t3, t1
    bne  t2, t3, fail

    li   t0, 5
    addi t1, t0, -6
    li   t2, -1
    bne  t1, t2, fail

    li   t0, 0x123
    andi t1, t0, 255
    li   t2, 0x23
    bne  t1, t2, fail
    ori  t1, t0, 127
    li   t2, 0x17f
    bne  t1, t2, fail
    xori t1, t0, -1
    li   t2, 0xfffffedc
    bne  t1, t2, fail

    li   t0, -1
    slti t1, t0, 0
    li   t2, 1
    bne  t1, t2, fail
    sltiu t1, t0, 1
    bne  t1, zero, fail
    li   t0, 1
    sltiu t1, t0, -1
    li   t2, 1
    bne  t1, t2, fail

    li   t0, 1
    slli t1, t0, 31
    li   t2, 0x80000000
    bne  t1, t2, fail
    srli t1, t2, 31
    li   t3, 1
    bne  t1, t3, fail
    srai t1, t2, 31
    li   t3, -1
    bne  t1, t3, fail
    slli t1, t2, 0
    bne  t1, t2, fail

    li   t0, 123
    add  zero, t0, t0
    addi zero, t0, 5
    li   t1, 0
    bne  zero, t1, fail

pass:
    li   t5, 256
    li   t6, 0xc0a10001
    sw   t6, 0(t5)
    lw   s0, 320(zero)
    j    done

fail:
    li   t5, 256
    li   t6, 0xbad10001
    sw   t6, 0(t5)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
