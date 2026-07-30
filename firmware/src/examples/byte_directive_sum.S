# Program: byte_directive_sum
# Purpose: Checks .byte data layout and alignment through a byte-sum program.
# Exercises: .byte, .align, lbu, pointer loop control, and DMemory storeback.
# Observable result: Final aligned byte sum is checked by the program testbench.
# Used by: tb_program_byte_directive

# Sum byte-sized static data emitted individually, then align a word result.

    la   t0, bytes
    li   t1, 3
    li   a0, 0

loop:
    lbu  t2, 0(t0)
    add  a0, a0, t2
    addi t0, t0, 1
    addi t1, t1, -1
    bne  t1, zero, loop

    la   t3, result
    sw   a0, 0(t3)
    lw   s0, 124(zero)   # conflicting block writes dirty result back

done:
    beq  zero, zero, done

bytes:
    .byte 1
    .byte 2
    .byte 0xff
    .align 2             # pad byte address 59 so result begins at 60
result:
    .word 0
