# Program: sum
# Purpose: Runs a minimal arithmetic/control-flow bring-up program.
# Exercises: Integer addition, branch-to-self halt, and a DMemory-observable result.
# Observable result: Final register and DMemory state are checked by the program testbench.
# Used by: tb_program

# Sum integers from 1 through 10, store the result, then evict the dirty line.

    addi x1, x0, 1       # i = 1
    addi x2, x0, 0       # sum = 0
    addi x3, x0, 11      # exclusive limit

loop:
    add  x2, x2, x1      # sum += i
    addi x1, x1, 1       # i += 1
    blt  x1, x3, loop

    sw   x2, 0(x0)       # cached result = 55
    lw   x4, 64(x0)      # same D-cache index, forcing dirty write-back

done:
    beq  x0, x0, done
