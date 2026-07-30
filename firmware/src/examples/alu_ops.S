# Program: alu_ops
# Purpose: Runs a compact RV32I ALU instruction example.
# Exercises: Register/immediate arithmetic, logic, shifts, and comparisons.
# Observable result: Final architectural registers are checked by the program testbench.
# Used by: tb_program_alu

# Exercise register and immediate ALU operations from an assembled program.

    addi  x1, x0, -16     # x1 = 0xfffffff0
    addi  x2, x0, 3
    sub   x3, x2, x1      # 3 - (-16) = 19
    and   x4, x1, x2      # 0
    or    x5, x1, x2      # 0xfffffff3
    xor   x6, x1, x2      # 0xfffffff3
    sll   x7, x2, x2      # 3 << 3 = 24
    srl   x8, x1, x2      # logical shift = 0x1ffffffe
    sra   x9, x1, x2      # arithmetic shift = 0xfffffffe
    slt   x10, x1, x2     # signed: -16 < 3
    sltu  x11, x1, x2     # unsigned: 0xfffffff0 < 3 is false

    slti  x12, x2, 4
    sltiu x13, x1, 4
    xori  x14, x2, 5
    ori   x15, x2, 8
    andi  x16, x5, 15
    slli  x17, x2, 4
    srli  x18, x1, 4
    srai  x19, x1, 4

    sw    x3, 0(x0)
    lw    x20, 64(x0)     # force dirty write-back of the arithmetic result

done:
    beq   x0, x0, done
