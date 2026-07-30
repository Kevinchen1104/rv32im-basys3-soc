# Program: upper_branch
# Purpose: Constructs upper-immediate constants and follows signed branch flow.
# Exercises: lui/addi constants plus signed branch behavior.
# Observable result: Final constants and branch-selected values are checked by the program testbench.
# Used by: tb_program_upper

# Build a large constant, observe PC-relative arithmetic, and take signed branches.

    lui   x1, 74565       # x1 = 0x12345000
    addi  x1, x1, 103     # x1 = 0x12345067
    auipc x2, 1           # PC is 8, so x2 = 0x00001008
    addi  x3, x0, -1      # x3 = -1

    bge   x3, x2, wrong_signed  # signed: -1 >= positive is false
    addi  x4, x0, 44

    bne   x1, x0, nonzero
    addi  x5, x0, 55      # wrong path: must be flushed

nonzero:
    bge   x2, x0, passed
    addi  x6, x0, 66      # wrong path: must be flushed

passed:
    sw    x1, 0(x0)
    lw    x7, 64(x0)      # force dirty write-back of the large constant

done:
    beq   x0, x0, done

wrong_signed:
    addi  x4, x0, 99
    beq   x0, x0, done
