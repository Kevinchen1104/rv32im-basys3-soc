# Program: strlen_function
# Purpose: Computes string length through a leaf function.
# Exercises: Function call/return flow, byte loads, and zero-terminated string traversal.
# Observable result: Final length, pointer, and marker registers are checked by the program testbench.
# Used by: tb_program_strlen

# Pass a zero-terminated byte string pointer to a leaf strlen-style function.

    la   a0, message       # first argument: pointer to the string
    call strlen            # return value: byte length in a0

    la   t3, result
    sw   a0, 0(t3)
    lw   s0, 128(zero)     # conflicting block writes dirty result back
    j    done

done:
    beq  zero, zero, done

strlen:
    mv   t0, a0
    li   a0, 0

loop:
    lbu  t1, 0(t0)
    beq  t1, zero, finish
    addi a0, a0, 1
    addi t0, t0, 1
    j    loop

finish:
    ret

message:
    .string "HELLO"
    .align 2
result:
    .word 0
