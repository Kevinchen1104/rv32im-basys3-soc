# Program: string_sum
# Purpose: Scans a zero-terminated string and sums its bytes.
# Exercises: Byte loads, zero terminator detection, loop control, and DMemory storeback.
# Observable result: Final string length and ASCII sum are checked by the program testbench.
# Used by: tb_program_string

# Scan a zero-terminated byte string and sum its ASCII values.

    la   t0, message
    li   a0, 0             # ASCII byte sum
    li   a1, 0             # string length

loop:
    lbu  t1, 0(t0)
    beq  t1, zero, finish  # terminator is not part of the string
    add  a0, a0, t1
    addi a1, a1, 1
    addi t0, t0, 1
    j    loop

finish:
    la   t3, result
    sw   a0, 0(t3)
    lw   s0, 128(zero)     # conflicting block writes dirty result back

done:
    beq  zero, zero, done

message:
    .string "CPU"
result:
    .word 0
