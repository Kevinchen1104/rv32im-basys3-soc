# Program: byte_array_sum
# Purpose: Sums packed byte data using unsigned byte loads.
# Exercises: lbu, pointer increments, branch loop control, and DMemory storeback.
# Observable result: Final byte sum in registers/DMemory is checked by the program testbench.
# Used by: tb_program_byte_array

# Sum four packed bytes through lbu and a byte-incrementing pointer.

    la   t0, bytes
    li   t1, 4
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
    .word 0x04030201      # little-endian byte sequence: 1, 2, 3, 4
result:
    .word 0
