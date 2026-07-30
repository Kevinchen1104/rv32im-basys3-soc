# Program: mret_trap
# Purpose: Checks mret returns through mepc after selected traps.
# Exercises: mtvec, mcause, mepc, and mret return behavior.
# Observable result: DMemory cause/PC records and final registers are checked by the program testbench.
# Used by: tb_program_mret_trap

la x5, trap_handler
csrrw x0, mtvec, x5
li x10, 0
ecall
ebreak
.word 0xffffffff
lw x0, 64(x0)
lw x0, 80(x0)
done:
j done

trap_handler:
csrrs x6, mcause, x0
csrrs x7, mepc, x0
sw x6, 0(x10)
sw x7, 4(x10)
addi x10, x10, 8
addi x7, x7, 4
csrrw x0, mepc, x7
mret
