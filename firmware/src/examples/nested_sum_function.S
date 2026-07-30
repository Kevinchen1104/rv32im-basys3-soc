# Program: nested_sum_function
# Purpose: Runs a non-leaf array-sum function using a stack frame.
# Exercises: Nested calls, stack frame save/restore, pointer traversal, and DMemory storeback.
# Observable result: Final sum, stack pointer, and marker registers are checked by the program testbench.
# Used by: tb_program_nested_sum

# Sum a word array in a non-leaf function that calls a helper per element.

    li   sp, 256
    la   a0, values        # first argument: pointer to word array
    li   a1, 4             # second argument: element count
    call sum_words

    la   t3, result
    sw   a0, 0(t3)
    lw   s2, 192(zero)    # conflicting block writes dirty result back
    j    done

done:
    beq  zero, zero, done

sum_words:
    addi sp, sp, -12
    sw   ra, 8(sp)        # non-leaf function must preserve its return address
    sw   s0, 4(sp)
    sw   s1, 0(sp)
    mv   s0, a0           # callee-saved pointer across helper calls
    mv   s1, a1           # callee-saved remaining count
    li   a0, 0

loop:
    lw   a1, 0(s0)        # helper's element argument
    call add_element
    addi s0, s0, 4
    addi s1, s1, -1
    bne  s1, zero, loop

    lw   s1, 0(sp)
    lw   s0, 4(sp)
    lw   ra, 8(sp)
    addi sp, sp, 12
    ret

add_element:
    add  a0, a0, a1
    ret

values:
    .word 5
    .word 7
    .word 11
    .word 13
result:
    .word 0
