# Program: rv32i_control_compliance
# Purpose: Runs selected local RV32I control-flow compliance-style checks.
# Exercises: Taken/not-taken branches, signed/unsigned branch boundaries, jal link, jalr bit-0 clearing, return flow,
#   and wrong-path suppression.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_rv32i_control_compliance
# Does not claim: Not an official compliance suite, complete predictor proof, or full flush proof.

# Selected local RV32I control-flow compliance-style test.
# This is not an official compliance suite.

    li   t0, 5
    li   t1, 5
    beq  t0, t1, beq_taken
    j    fail
beq_taken:
    beq  t0, zero, fail

    li   t1, 6
    bne  t0, t1, bne_taken
    j    fail
bne_taken:
    bne  t0, t0, fail

    li   t0, -1
    li   t1, 1
    blt  t0, t1, blt_taken
    j    fail
blt_taken:
    blt  t1, t0, fail

    bge  t1, t0, bge_taken
    j    fail
bge_taken:
    bge  t0, t1, fail

    bltu t1, t0, bltu_taken
    j    fail
bltu_taken:
    bltu t0, t1, fail

    bgeu t0, t1, bgeu_taken
    j    fail
bgeu_taken:
    bgeu t1, t0, fail

    li   s0, 0
    beq  zero, zero, branch_flush_target
    li   s0, 1
    j    fail
branch_flush_target:
    bne  s0, zero, fail

    li   s0, 0
    jal  ra, jal_target
after_jal:
    li   s0, 2
    j    fail
jal_target:
    la   t2, after_jal
    bne  ra, t2, fail
    bne  s0, zero, fail

    li   s0, 0
    la   t0, jalr_target
    addi t0, t0, 1
    jalr t1, 0(t0)
after_jalr:
    li   s0, 3
    j    fail
jalr_target:
    la   t2, after_jalr
    bne  t1, t2, fail
    bne  s0, zero, fail

    li   s1, 0
    jal  ra, return_function
after_return:
    li   t0, 1
    bne  s1, t0, fail
    j    pass

return_function:
    li   s1, 1
    ret
    li   s1, 2
    j    fail

pass:
    li   t5, 256
    li   t6, 0xc0a10002
    sw   t6, 0(t5)
    lw   s0, 320(zero)
    j    done

fail:
    li   t5, 256
    li   t6, 0xbad10002
    sw   t6, 0(t5)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
