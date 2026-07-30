# Program: li_constants
# Purpose: Checks pseudo-immediate expansion for representative constants.
# Exercises: li pseudo expansion, full-width constants, and label-safe flow.
# Observable result: Final loaded constants are checked by the program testbench.
# Used by: tb_program_li

# Load full-width constants through expanded li pseudos and branch across them.

    li   t0, 0x12345678   # expands to lui/addi
    li   t1, 0x89abcdef   # low 12 bits require a negative addi correction
    beq  t0, t0, selected
    li   t2, 0x76543210   # wrong path: expands to two instructions

selected:
    mv   a0, t0
    sw   t1, 0(zero)
    lw   s0, 64(zero)     # force dirty write-back of the full-width constant

done:
    beq  zero, zero, done
