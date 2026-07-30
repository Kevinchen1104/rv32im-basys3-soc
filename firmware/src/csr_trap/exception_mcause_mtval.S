# Program: exception_mcause_mtval
# Purpose: Checks selected synchronous exception cause, PC, and mtval reporting.
# Exercises: mtvec, mcause, mepc, mtval, environment, illegal-instruction, and memory access-fault cases.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_exception_mcause_mtval

# Directed synchronous exception cause, PC, and mtval checks.

    li   t0, 0
    sw   t0, 0(zero)      # phase
    sw   t0, 12(zero)     # completed handler count
    la   t0, trap_handler
    csrrw x0, mtvec, t0

ecall_site:
    ecall
after_ecall:
    li   t0, 1
    sw   t0, 0(zero)

ebreak_site:
    ebreak
after_ebreak:
    li   t0, 2
    sw   t0, 0(zero)

illegal_site:
    .word 0xffffffff
after_illegal:
    lw   t0, 12(zero)
    li   t1, 3
    bne  t0, t1, fail

    li   t0, 3
    sw   t0, 0(zero)
    li   t3, 4096
load_access_site:
    lw   t0, 0(t3)
after_load_access:
    li   t0, 4
    sw   t0, 0(zero)
store_access_site:
    sw   t0, 0(t3)
after_store_access:
    li   t0, 5
    sw   t0, 0(zero)
instruction_access_site:
    jalr zero, 0(t3)
after_instruction_access:
    lw   t0, 12(zero)
    li   t1, 6
    bne  t0, t1, fail

    li   t3, 256
    li   t4, 0xc5e20002
    sw   t4, 0(t3)
    j    done

trap_handler:
    lw   t0, 0(zero)
    beq  t0, zero, handle_ecall
    li   t1, 1
    beq  t0, t1, handle_ebreak
    li   t1, 2
    beq  t0, t1, handle_illegal
    li   t1, 3
    beq  t0, t1, handle_load_access
    li   t1, 4
    beq  t0, t1, handle_store_access
    li   t1, 5
    beq  t0, t1, handle_instruction_access
    j    fail

handle_ecall:
    csrrs t1, mcause, zero
    li   t2, 11
    bne  t1, t2, fail
    sw   t1, 16(zero)
    csrrs t1, mepc, zero
    la   t2, ecall_site
    bne  t1, t2, fail
    sw   t1, 20(zero)
    csrrs t1, mtval, zero
    bne  t1, zero, fail
    sw   t1, 24(zero)
    li   t1, 1
    sw   t1, 12(zero)
    la   t1, after_ecall
    csrrw x0, mepc, t1
    mret

handle_ebreak:
    csrrs t1, mcause, zero
    li   t2, 3
    bne  t1, t2, fail
    sw   t1, 28(zero)
    csrrs t1, mepc, zero
    la   t2, ebreak_site
    bne  t1, t2, fail
    sw   t1, 32(zero)
    csrrs t1, mtval, zero
    bne  t1, zero, fail
    sw   t1, 36(zero)
    li   t1, 2
    sw   t1, 12(zero)
    la   t1, after_ebreak
    csrrw x0, mepc, t1
    mret

handle_illegal:
    csrrs t1, mcause, zero
    li   t2, 2
    bne  t1, t2, fail
    sw   t1, 40(zero)
    csrrs t1, mepc, zero
    la   t2, illegal_site
    bne  t1, t2, fail
    sw   t1, 44(zero)
    csrrs t1, mtval, zero
    li   t2, 0xffffffff
    bne  t1, t2, fail
    sw   t1, 48(zero)
    li   t1, 3
    sw   t1, 12(zero)
    la   t1, after_illegal
    csrrw x0, mepc, t1
    mret

handle_load_access:
    csrrs t1, mcause, zero
    li   t2, 5
    bne  t1, t2, fail
    csrrs t1, mepc, zero
    la   t2, load_access_site
    bne  t1, t2, fail
    csrrs t1, mtval, zero
    li   t2, 4096
    bne  t1, t2, fail
    li   t1, 4
    sw   t1, 12(zero)
    la   t1, after_load_access
    csrrw x0, mepc, t1
    mret

handle_store_access:
    csrrs t1, mcause, zero
    li   t2, 7
    bne  t1, t2, fail
    csrrs t1, mepc, zero
    la   t2, store_access_site
    bne  t1, t2, fail
    csrrs t1, mtval, zero
    li   t2, 4096
    bne  t1, t2, fail
    li   t1, 5
    sw   t1, 12(zero)
    la   t1, after_store_access
    csrrw x0, mepc, t1
    mret

handle_instruction_access:
    csrrs t1, mcause, zero
    li   t2, 1
    bne  t1, t2, fail
    csrrs t1, mepc, zero
    li   t2, 4096
    bne  t1, t2, fail
    csrrs t1, mtval, zero
    bne  t1, t2, fail
    li   t1, 6
    sw   t1, 12(zero)
    la   t1, after_instruction_access
    csrrw x0, mepc, t1
    mret

fail:
    li   t3, 256
    li   t4, 0xbad50002
    sw   t4, 0(t3)

done:
    beq  zero, zero, done
