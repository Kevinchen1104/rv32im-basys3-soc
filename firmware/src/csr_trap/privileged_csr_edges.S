# Program: privileged_csr_edges
# Purpose: Checks selected machine-mode CSR readback and masking edges.
# Exercises: mtvec, mepc, mstatus.MIE/MPIE/MPP, the mie mask, read-only mip, mtval, mcause, and mret return behavior.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_privileged_csr_edges

# Selected machine-mode CSR edge checks for the local privileged subset.

    la   t0, trap_handler
    li   t1, 3
    or   t2, t0, t1
    csrrw x0, mtvec, t2
    csrrs t3, mtvec, zero
    bne  t3, t0, fail

    la   t0, return_from_mret
    addi t1, t0, 3
    csrrw x0, mepc, t1
    csrrs t2, mepc, zero
    bne  t2, t0, fail

    li   t0, 0xffffffff
    csrrw x0, mstatus, t0
    csrrs t1, mstatus, zero
    li   t2, 0x1888
    bne  t1, t2, fail

    li   t0, 0
    csrrw x0, mstatus, t0
    csrrs t1, mstatus, zero
    li   t2, 0x1800
    bne  t1, t2, fail

    li   t0, 0xffffffff
    csrrw x0, mie, t0
    csrrs t1, mie, zero
    li   t2, 0x880
    bne  t1, t2, fail

    li   t0, 0xffffffff
    csrrw x0, mip, t0     # MTIP and MEIP are read-only
    csrrs t1, mip, zero
    bne  t1, zero, fail

    li   t0, 0
    csrrw x0, mip, t0
    csrrs t1, mip, zero
    bne  t1, zero, fail

    li   t0, 0x12345678
    csrrw x0, mtval, t0
    csrrs t1, mtval, zero
    bne  t1, t0, fail

    li   t0, 8
    csrrs x0, mstatus, t0
ecall_site:
    ecall
    j    fail

return_from_mret:
    csrrs t1, mstatus, zero
    li   t2, 0x1888
    bne  t1, t2, fail
    csrrs t1, mcause, zero
    li   t2, 11
    bne  t1, t2, fail
    csrrs t1, mepc, zero
    la   t2, return_from_mret
    bne  t1, t2, fail

    li   t3, 256
    li   t4, 0xc5e10001
    sw   t4, 0(t3)
    j    done

trap_handler:
    csrrs t1, mstatus, zero
    li   t2, 0x1880
    bne  t1, t2, fail
    csrrs t1, mcause, zero
    li   t2, 11
    bne  t1, t2, fail
    csrrs t1, mtval, zero
    bne  t1, zero, fail

    la   t1, return_from_mret
    addi t1, t1, 3
    csrrw x0, mepc, t1
    mret

fail:
    li   t3, 256
    li   t4, 0xbad50001
    sw   t4, 0(t3)

done:
    beq  zero, zero, done
