# Program: nested_call
# Purpose: Runs nested function calls and returns.
# Exercises: Nested jal/jalr flow and return-address stack behavior.
# Observable result: Final return value and RAS-related state are checked by the program testbench.
# Used by: tb_program_nested

# Nested calls: main -> func1 -> func2 -> func1 -> main.
# func1 saves its caller's return address before issuing another jal.

    addi x10, x0, 7       # argument = 7
    jal  x1, func1

    sw   x10, 0(x0)       # result = 7 + 2 + 3 = 12
    lw   x4, 64(x0)       # force dirty write-back

done:
    beq  x0, x0, done
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0

func1:
    addi x5, x1, 0        # save main return address
    jal  x1, func2
    addi x1, x5, 0        # restore main return address
    addi x10, x10, 3
    jalr x0, 0(x1)

func2:
    addi x10, x10, 2
    jalr x0, 0(x1)
