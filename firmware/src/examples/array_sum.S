# Program: array_sum
# Purpose: Sums word data through a pointer loop.
# Exercises: Loads, pointer arithmetic, branch loop control, and DMemory storeback.
# Observable result: Final sum in registers/DMemory is checked by the program testbench.
# Used by: tb_program_array

# Sum four static words through a pointer formed from a data label.

    la   t0, values
    li   t1, 4
    li   a0, 0

loop:
    lw   t2, 0(t0)
    add  a0, a0, t2
    addi t0, t0, 4
    addi t1, t1, -1
    bne  t1, zero, loop

    la   t3, result
    sw   a0, 0(t3)
    lw   s0, 128(zero)   # conflicting block writes dirty result back

done:
    beq  zero, zero, done

values:
    .word 5
    .word 7
    .word 11
    .word 13
result:
    .word 0
