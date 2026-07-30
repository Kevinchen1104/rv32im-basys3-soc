# Program: misaligned_exception
# Purpose: Checks selected misaligned load/store exception reporting.
# Exercises: mtvec, mcause, mepc, mtval, and mret recovery for misaligned memory cases.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_misaligned_exception

# Misaligned load/store precise exception checks.

    li   t0, 0
    sw   t0, 0(zero)      # phase
    sw   t0, 12(zero)     # completed handler count
    la   t0, trap_handler
    csrrw x0, mtvec, t0

    li   t0, 0x11223344
    sw   t0, 64(zero)
    li   s0, 0x5555aaaa

    li   t0, 1
    sw   t0, 0(zero)
misaligned_load_site:
    lw   s0, 66(zero)
after_load:
    li   t1, 0x5555aaaa
    bne  s0, t1, fail
    lw   t2, 64(zero)
    li   t3, 0x11223344
    bne  t2, t3, fail

    li   t0, 2
    sw   t0, 0(zero)
    li   t4, 0xa5a5a5a5
misaligned_store_site:
    sw   t4, 66(zero)
after_store:
    lw   t2, 64(zero)
    li   t3, 0x11223344
    bne  t2, t3, fail
    lw   t0, 12(zero)
    li   t1, 2
    bne  t0, t1, fail

    li   t3, 256
    li   t4, 0xc5e30003
    sw   t4, 0(t3)
    j    done

trap_handler:
    lw   t0, 0(zero)
    li   t1, 1
    beq  t0, t1, handle_load
    li   t1, 2
    beq  t0, t1, handle_store
    j    fail

handle_load:
    csrrs t1, mcause, zero
    li   t2, 4
    bne  t1, t2, fail
    sw   t1, 16(zero)
    csrrs t1, mepc, zero
    la   t2, misaligned_load_site
    bne  t1, t2, fail
    sw   t1, 20(zero)
    csrrs t1, mtval, zero
    li   t2, 66
    bne  t1, t2, fail
    sw   t1, 24(zero)
    li   t1, 1
    sw   t1, 12(zero)
    la   t1, after_load
    csrrw x0, mepc, t1
    mret

handle_store:
    csrrs t1, mcause, zero
    li   t2, 6
    bne  t1, t2, fail
    sw   t1, 28(zero)
    csrrs t1, mepc, zero
    la   t2, misaligned_store_site
    bne  t1, t2, fail
    sw   t1, 32(zero)
    csrrs t1, mtval, zero
    li   t2, 66
    bne  t1, t2, fail
    sw   t1, 36(zero)
    li   t1, 2
    sw   t1, 12(zero)
    la   t1, after_store
    csrrw x0, mepc, t1
    mret

fail:
    li   t3, 256
    li   t4, 0xbad50003
    sw   t4, 0(t3)

done:
    beq  zero, zero, done
