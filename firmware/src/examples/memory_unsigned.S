# Program: memory_unsigned
# Purpose: Runs a compact memory and unsigned-branch example.
# Exercises: Byte/halfword/word loads and stores plus unsigned branch behavior.
# Observable result: Final registers and DMemory values are checked by the program testbench.
# Used by: tb_program_memory

# Exercise subword memory operations and unsigned control flow from a loaded program.

    lb   x1, 2(x0)        # 0xff sign-extends to 0xffffffff
    lbu  x2, 2(x0)        # 0xff zero-extends to 255
    lh   x3, 2(x0)        # 0x80ff sign-extends to 0xffff80ff
    lhu  x4, 2(x0)        # 0x80ff zero-extends to 0x000080ff

    sb   x2, 20(x0)       # build output word byte 0 = 0xff
    sh   x4, 22(x0)       # build output word upper half = 0x80ff
    lw   x5, 20(x0)       # output is now 0x80ff00ff in the cache

    bltu x2, x1, less_unsigned
    addi x6, x0, 99       # wrong path: must be flushed

less_unsigned:
    bgeu x1, x2, passed
    addi x7, x0, 88       # wrong path: must be flushed

passed:
    addi x10, x0, 1
    lw   x9, 84(x0)       # evict the dirty output line at address 20

done:
    beq  x0, x0, done
