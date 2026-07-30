# Program: halfword_array_sum
# Purpose: Sums packed halfword data using unsigned halfword loads.
# Exercises: lhu, pointer increments, branch loop control, and DMemory storeback.
# Observable result: Final halfword sum in registers/DMemory is checked by the program testbench.
# Used by: tb_program_halfword_array

# Sum four packed halfwords through lhu and a two-byte pointer stride.

    la   t0, halves
    li   t1, 4
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
    .word 0x00020001      # little-endian halfwords: 1, 2
    .word 0x8000ffff      # unsigned halfwords: 65535, 32768
result:
    .word 0
