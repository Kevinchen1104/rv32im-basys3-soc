# Program: stack_call
# Purpose: Calls through a stack-using function and restores the stack pointer.
# Exercises: Stack pointer adjustment, call/return flow, and return-value handling.
# Observable result: Final stack pointer, return value, and marker registers are checked by the program testbench.
# Used by: tb_program_stack

# Nested calls using a stack pointer and stack frames to preserve ra (x1).

    addi x2, x0, 48      # sp = 48
    addi x10, x0, 7      # argument = 7
    jal  x1, func1

    sw   x10, 0(x0)      # result = 7 + 2 + 3 = 12
    lw   x4, 64(x0)      # force dirty result write-back

done:
    beq  x0, x0, done
    addi x0, x0, 0
    addi x0, x0, 0

func1:
    addi x2, x2, -4      # allocate one stack word
    sw   x1, 0(x2)       # save ra = return to main
    jal  x1, func2
    lw   x1, 0(x2)       # restore ra
    addi x2, x2, 4       # release stack word
    addi x10, x10, 3
    jalr x0, 0(x1)

func2:
    addi x2, x2, -4      # allocate one stack word
    sw   x1, 0(x2)       # save ra = return to func1
    addi x10, x10, 2
    lw   x1, 0(x2)       # restore ra
    addi x2, x2, 4       # release stack word
    jalr x0, 0(x1)
