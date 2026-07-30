# Program: string_escape_sum
# Purpose: Checks escaped string data emitted by the assembler.
# Exercises: .string escape handling, byte loads, string length, and sum calculation.
# Observable result: Final ASCII sum and string length are checked by the program testbench.
# Used by: tb_program_string_escape

# Scan a zero-terminated string with escapes and sum its emitted byte values.

    la   t0, message
    li   a0, 0             # byte sum
    li   a1, 0             # string length

loop:
    lbu  t1, 0(t0)
    beq  t1, zero, finish  # terminator is appended by .string
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
    .string "A#\n\t\"\\Z"    # '#' inside the quotes is string data
    .align 2
result:
    .word 0
