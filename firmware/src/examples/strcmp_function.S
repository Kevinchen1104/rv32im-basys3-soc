# Program: strcmp_function
# Purpose: Compares byte strings through a simple function.
# Exercises: String traversal, byte loads, branch flow, and equal/different return values.
# Observable result: Final compare results and DMemory markers are checked by the program testbench.
# Used by: tb_program_strcmp

# Compare two zero-terminated byte strings through a leaf strcmp-style function.

    la   a0, left          # first argument: left string pointer
    la   a1, right_same    # second argument: matching string pointer
    call strcmp            # return value: 0 when equal
    la   t4, result_equal
    sw   a0, 0(t4)

    la   a0, left
    la   a1, right_diff
    call strcmp            # return value: 1 when a byte differs
    la   t5, result_diff
    sw   a0, 0(t5)

    lw   s0, 208(zero)     # conflicting block writes dirty results back
    j    done

done:
    beq  zero, zero, done

strcmp:
    mv   t0, a0
    mv   t1, a1

loop:
    lbu  t2, 0(t0)
    lbu  t3, 0(t1)
    bne  t2, t3, different
    beq  t2, zero, equal
    addi t0, t0, 1
    addi t1, t1, 1
    j    loop

different:
    li   a0, 1
    ret

equal:
    li   a0, 0
    ret

left:
    .string "LINUX"
    .align 2
right_same:
    .string "LINUX"
    .align 2
right_diff:
    .string "LINUY"
    .align 2
result_equal:
    .word 0
result_diff:
    .word 0
