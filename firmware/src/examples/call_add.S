# Program: call_add
# Purpose: Calls a small add function and returns a value.
# Exercises: jal/jalr call-return flow and argument/result registers.
# Observable result: Final return value and marker registers are checked by the program testbench.
# Used by: tb_program_call

# Call a function through jal/jalr, store the returned value, then evict it.

    addi x10, x0, 7       # argument = 7
    jal  x1, add_five     # x1 = return address

    sw   x10, 0(x0)       # returned value = 12
    lw   x4, 64(x0)       # force dirty write-back

done:
    beq  x0, x0, done
    addi x0, x0, 0

add_five:
    addi x10, x10, 5
    jalr x0, 0(x1)
