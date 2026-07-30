# Program: half_directive_sum
# Purpose: Checks .half data layout and alignment through a halfword-sum program.
# Exercises: .half, .align, lhu, pointer loop control, and DMemory storeback.
# Observable result: Final aligned halfword sum is checked by the program testbench.
# Used by: tb_program_half_directive

# Sum individually emitted unsigned halfwords, then align a word result.

    la   t0, halves
    li   t1, 3
    li   a0, 0

loop:
    lhu  t2, 0(t0)
    add  a0, a0, t2
    addi t0, t0, 2
    addi t1, t1, -1
    bne  t1, zero, loop

    la   t3, result
    sw   a0, 0(t3)
    lw   s0, 128(zero)   # conflicting block writes dirty result back

done:
    beq  zero, zero, done

halves:
    .half 1
    .half 0xffff
    .half 0x8000
    .align 2             # pad addresses 62-63 so result begins at 64
result:
    .word 0
