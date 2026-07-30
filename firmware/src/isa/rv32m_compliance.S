# Program: rv32m_compliance
# Purpose: Runs selected local RV32M compliance-style checks.
# Exercises: mul/mulh/mulhsu/mulhu/div/divu/rem/remu, divide-by-zero, INT_MIN/-1, and signed/unsigned edge cases.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_rv32m_compliance
# Does not claim: Not an official compliance suite, exhaustive arithmetic proof, or timing/performance claim.

# Selected local RV32M compliance-style test.
# This is not an official compliance suite.

    li   t0, 7
    li   t1, -3
    mul  t2, t0, t1
    li   t3, 0xffffffeb
    bne  t2, t3, fail
    mulh t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail
    mulhsu t2, t1, t0
    li   t3, -1
    bne  t2, t3, fail
    mulhu t2, t0, t1
    li   t3, 6
    bne  t2, t3, fail

    div  t2, t0, t1
    li   t3, -2
    bne  t2, t3, fail
    rem  t2, t0, t1
    li   t3, 1
    bne  t2, t3, fail
    divu t2, t0, t1
    bne  t2, zero, fail
    remu t2, t0, t1
    li   t3, 7
    bne  t2, t3, fail

    li   t0, -7
    li   t1, 3
    div  t2, t0, t1
    li   t3, -2
    bne  t2, t3, fail
    rem  t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail

    li   t0, 0xffffffff
    li   t1, 2
    divu t2, t0, t1
    li   t3, 0x7fffffff
    bne  t2, t3, fail
    remu t2, t0, t1
    li   t3, 1
    bne  t2, t3, fail

    li   t0, -7
    li   t1, 0
    div  t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail
    divu t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail
    rem  t2, t0, t1
    li   t3, -7
    bne  t2, t3, fail
    remu t2, t0, t1
    li   t3, -7
    bne  t2, t3, fail

    li   t0, 0x80000000
    li   t1, -1
    div  t2, t0, t1
    li   t3, 0x80000000
    bne  t2, t3, fail
    rem  t2, t0, t1
    bne  t2, zero, fail

    li   t0, 0x80000000
    li   t1, 2
    mul  t2, t0, t1
    bne  t2, zero, fail
    mulh t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail
    mulhsu t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail
    mulhu t2, t0, t1
    li   t3, 1
    bne  t2, t3, fail

    li   t0, -1
    li   t1, -1
    mul  t2, t0, t1
    li   t3, 1
    bne  t2, t3, fail
    mulh t2, t0, t1
    bne  t2, zero, fail
    mulhsu t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail
    mulhu t2, t0, t1
    li   t3, 0xfffffffe
    bne  t2, t3, fail

pass:
    li   t5, 256
    li   t6, 0xc0a10004
    sw   t6, 0(t5)
    lw   s0, 320(zero)
    j    done

fail:
    li   t5, 256
    li   t6, 0xbad10004
    sw   t6, 0(t5)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
