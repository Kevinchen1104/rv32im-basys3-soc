# Program: csr_trap
# Purpose: Records selected synchronous trap causes and trap PCs.
# Exercises: mtvec, mcause, mepc, trap redirect, and mret return flow in the local machine-mode subset.
# Observable result: DMemory cause/PC records are checked by the program testbench.
# Used by: tb_program_csr_trap

la x5, trap_handler
csrrw x0, mtvec, x5
li x10, 0
ecall
ebreak
.word 0xffffffff
lh x6, 1(x0)
sh x6, 3(x0)
lw x0, 64(x0)
lw x0, 80(x0)
lw x0, 96(x0)
done:
j done

trap_handler:
csrrs x6, mcause, x0
csrrs x7, mepc, x0
sw x6, 0(x10)
sw x7, 4(x10)
addi x10, x10, 8
addi x7, x7, 4
jalr x0, 0(x7)
