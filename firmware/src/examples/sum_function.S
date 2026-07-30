# Program: sum_function
# Purpose: Calls a leaf function to sum an array.
# Exercises: Function arguments, pointer traversal, loop control, and return-value handling.
# Observable result: Final array sum and marker registers are checked by the program testbench.
# Used by: tb_program_sum_function

# Pass an array pointer and length to a leaf sum function through ABI registers.

    la   a0, values        # first argument: pointer to word array
    li   a1, 4             # second argument: element count
    call sum_words         # return value is placed back in a0

    la   t3, result
    sw   a0, 0(t3)
    lw   s0, 152(zero)    # conflicting block writes dirty result back
    j    done

done:
    beq  zero, zero, done

sum_words:
    mv   t0, a0
    li   a0, 0

loop:
    lw   t1, 0(t0)
    add  a0, a0, t1
    addi t0, t0, 4
    addi a1, a1, -1
    bne  a1, zero, loop
    ret

values:
    .word 5
    .word 7
    .word 11
    .word 13
result:
    .word 0
