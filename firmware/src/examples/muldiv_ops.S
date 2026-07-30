# Program: muldiv_ops
# Purpose: Runs a compact RV32M multiply/divide example.
# Exercises: mul/div/rem signed and unsigned operations on representative values.
# Observable result: Final arithmetic results are checked by the program testbench.
# Used by: tb_program_muldiv

li x1, 7
li x2, -3
mul x3, x1, x2
mulh x4, x1, x2
mulhsu x5, x2, x1
mulhu x6, x1, x2
div x7, x1, x2
divu x8, x1, x2
rem x9, x1, x2
remu x10, x1, x2
li x11, -2147483648
li x12, -1
div x13, x11, x12
rem x14, x11, x12
li x15, 0
div x16, x1, x15
divu x17, x1, x15
rem x18, x1, x15
remu x19, x1, x15
sw x3, 0(x0)
lw x20, 0(x0)
