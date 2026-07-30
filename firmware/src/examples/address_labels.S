# Program: address_labels
# Purpose: Checks assembler label-address pseudo expansion for forward and backward labels.
# Exercises: la-style address materialization and label arithmetic in a small CPU program.
# Observable result: Final registers and DMemory values are checked by the program testbench.
# Used by: tb_program_address

# Load forward and backward code-label addresses with the la pseudo.

start:
    la   t0, selected      # expands to auipc/addi; selected is at byte address 36
    la   t1, start         # backward reference: current PC plus -8 = 0
    li   t2, 0x13579bdf   # expanded li contributes two instruction words
    j    selected
    li   t2, 0x76543210   # wrong path, also contributes two words to selected

selected:
    sub  t3, t0, t1       # distance from start to selected = 36 bytes
    sw   t0, 0(zero)
    lw   s0, 64(zero)     # force dirty write-back for test observation

done:
    beq  zero, zero, done
