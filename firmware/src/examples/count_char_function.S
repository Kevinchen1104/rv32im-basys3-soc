# Program: count_char_function
# Purpose: Counts matching bytes in strings through a reusable function.
# Exercises: String byte loads, function calls, pointer traversal, and zero-count behavior.
# Observable result: Final count results and DMemory markers are checked by the program testbench.
# Used by: tb_program_count_char

# Count matching bytes in a zero-terminated string through a leaf function.

    la   a0, message       # first argument: pointer to the string
    li   a1, 65            # second argument: 'A'
    call count_char        # return value: number of matching bytes
    la   t4, result_a
    sw   a0, 0(t4)

    la   a0, message
    li   a1, 90            # 'Z' is not present
    call count_char
    la   t5, result_z
    sw   a0, 0(t5)

    lw   s0, 256(zero)     # conflicting block writes dirty results back
    j    done

done:
    beq  zero, zero, done

count_char:
    mv   t0, a0
    mv   t1, a1
    li   a0, 0

loop:
    lbu  t2, 0(t0)
    beq  t2, zero, finish
    bne  t2, t1, skip_count
    addi a0, a0, 1

skip_count:
    addi t0, t0, 1
    j    loop

finish:
    ret

message:
    .string "BANANA BANDANA DATA"
    .align 2
result_a:
    .word 0
result_z:
    .word 0
