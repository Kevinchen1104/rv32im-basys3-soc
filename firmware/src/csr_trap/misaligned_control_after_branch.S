# Program: misaligned_control_after_branch
# Purpose: Checks instruction-address-misaligned traps when two control transfers resolve on consecutive cycles.
# Exercises: an isolated misaligned JALR and the same JALR entering execute right after a not-taken branch.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_misaligned_control_after_branch

    li   t0, 0
    sw   t0, 0(zero)      # completed handler count
    li   ra, 0
    la   t0, trap_handler
    csrrw x0, mtvec, t0
    la   t0, wrong_path   # word-aligned; every JALR below adds 2

    # Case 1: isolated JALR to a misaligned target.
isolated_site:
    jalr ra, 2(t0)
after_isolated:
    bne  ra, zero, fail   # the faulting JALR must not write its link register
    lw   t1, 0(zero)
    li   t2, 1
    bne  t1, t2, fail

    # Case 2: a correctly predicted, not-taken branch is in execute on the
    # cycle before the same JALR. The padding keeps the branch, the JALR and
    # the following fetch in one 16-byte I-cache line so no miss separates them.
    li   a0, 1
    li   a1, 2
    nop
    nop
branch_site:
    beq  a0, a1, fail
back_to_back_site:
    jalr ra, 2(t0)
after_back_to_back:
    bne  ra, zero, fail
    lw   t1, 0(zero)
    li   t2, 2
    bne  t1, t2, fail

    li   t3, 256
    li   t4, 0xc5e30009
    sw   t4, 0(t3)
    j    done

# Reached only if a misaligned target is followed instead of trapping. It uses
# no PC-relative instruction before publishing failure.
wrong_path:
    li   t3, 256
    li   t4, 0xbad5a009
    sw   t4, 0(t3)
wrong_path_stop:
    beq  zero, zero, wrong_path_stop

trap_handler:
    csrrs t1, mcause, zero
    bne  t1, zero, fail
    la   t3, wrong_path
    addi t3, t3, 2
    csrrs t2, mtval, zero
    bne  t2, t3, fail
    lw   t1, 0(zero)
    bne  t1, zero, second_trap

    csrrs t2, mepc, zero
    la   t3, isolated_site
    bne  t2, t3, fail
    li   t1, 1
    sw   t1, 0(zero)
    la   t1, after_isolated
    csrrw x0, mepc, t1
    mret

second_trap:
    li   t2, 1
    bne  t1, t2, fail
    csrrs t2, mepc, zero
    la   t3, back_to_back_site
    bne  t2, t3, fail
    li   t1, 2
    sw   t1, 0(zero)
    la   t1, after_back_to_back
    csrrw x0, mepc, t1
    mret

fail:
    li   t3, 256
    li   t4, 0xbad50009
    sw   t4, 0(t3)

done:
    beq  zero, zero, done
