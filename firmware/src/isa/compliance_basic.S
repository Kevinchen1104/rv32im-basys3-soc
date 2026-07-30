# Program: compliance_basic
# Purpose: Runs a selected local RV32I compliance-style smoke program.
# Exercises: Arithmetic, logical, shift, branch, and word load/store behavior.
# Observable result: Public pass/fail signature is checked by the program testbench.
# Used by: tb_program_compliance_basic
# Does not claim: Not an official compliance suite or exhaustive ISA proof.

# Selected RV32I compliance-style smoke.
# This is a local directed test, not a full RISC-V compliance suite.

    li   t0, 7
    li   t1, 3
    add  t2, t0, t1        # 10

    li   s0, 16
    sub  s1, s0, t1        # 13

    li   s2, -4
    slt  s3, s2, t1        # signed -4 < 3
    sltu s4, s2, t1        # unsigned 0xffff_fffc > 3

    li   s5, 1
    sll  s6, s5, t1        # 8

    li   s7, -16
    srl  s8, s7, t1        # 0x1fff_fffe
    sra  s9, s7, t1        # 0xffff_fffe

    addi s10, s1, 5        # 18

    li   s11, 0x00000f0f
    li   t3, 0x000000f0
    and  t4, s11, t3       # 0
    or   t5, s11, t3       # 0x00000fff
    xor  t6, s11, t3       # 0x00000fff

    li   a0, 10
    beq  t2, a0, beq_taken
    j    fail

beq_taken:
    bne  t2, a0, fail      # not taken
    li   a1, 17
    bne  s10, a1, bne_taken
    j    fail

bne_taken:
    li   a2, 0x12345678
    sw   a2, 0x1bc(zero)
    lw   a3, 0x1bc(zero)
    bne  a2, a3, fail
    lw   a5, 0x1fc(zero)   # evict the dirty 0x1b0 cache line

    li   a4, 0x1ce0ffee
    sw   a4, 0x1c0(zero)
    lw   a5, 0x240(zero)   # evict the dirty 0x1c0 cache line
    j    done

fail:
    li   a4, 0xbad00bad
    sw   a4, 0x1c0(zero)

done:
    beq  zero, zero, done
