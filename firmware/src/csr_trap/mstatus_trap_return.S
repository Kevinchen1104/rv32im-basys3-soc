# Program: mstatus_trap_return
# Purpose: Checks minimal mstatus trap-entry and mret side effects.
# Exercises: mstatus.MIE/MPIE, mcause, mepc, mtvec redirect, and mret return behavior.
# Observable result: Public debug_status pass/fail signature and DMemory snapshots are checked by the program
#   testbench.
# Used by: tb_program_mstatus_trap_return

# Minimal mstatus trap-return side-effect smoke.
# Trap entry should clear mstatus.MIE and save the old MIE value in MPIE.
# mret should restore MIE from MPIE and set MPIE.

    la   t0, trap_handler
    csrrw x0, mtvec, t0

    li   t1, 0
    sw   t1, 0(zero)      # handler flag
    sw   t1, 4(zero)      # mstatus observed in handler
    sw   t1, 8(zero)      # mcause observed in handler
    sw   t1, 12(zero)     # mepc observed in handler

    li   t1, 8            # mstatus.MIE
    csrrs x0, mstatus, t1
    ecall
    j    fail             # handler must return to return_path instead

return_path:
    csrrs t2, mstatus, zero
    andi t3, t2, 8
    beq  t3, zero, fail
    andi t3, t2, 128
    beq  t3, zero, fail

    lw   t4, 0(zero)
    li   t5, 1
    bne  t4, t5, fail
    lw   t4, 4(zero)
    andi t5, t4, 8
    bne  t5, zero, fail
    andi t5, t4, 128
    beq  t5, zero, fail
    lw   t4, 8(zero)
    li   t5, 11
    bne  t4, t5, fail

    li   t3, 256
    li   t4, 0x517a900d
    sw   t4, 0(t3)
    j    done

trap_handler:
    csrrs t1, mstatus, zero
    sw   t1, 4(zero)
    andi t2, t1, 8
    bne  t2, zero, fail
    andi t2, t1, 128
    beq  t2, zero, fail

    csrrs t1, mcause, zero
    sw   t1, 8(zero)
    li   t2, 11
    bne  t1, t2, fail

    csrrs t1, mepc, zero
    sw   t1, 12(zero)
    la   t1, return_path
    csrrw x0, mepc, t1

    li   t1, 1
    sw   t1, 0(zero)
    mret

fail:
    li   t3, 256
    li   t4, 0xbad0900d
    sw   t4, 0(t3)

done:
    beq  zero, zero, done
