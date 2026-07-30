# Program: machine_timer_interrupt
# Purpose: Checks the machine timer interrupt path with the source enabled.
# Exercises: mtime/mtimecmp MMIO, mstatus.MIE, mie.MTIE, mip.MTIP, mtvec redirect, mcause, mepc, and mret.
# Observable result: Public debug_status pass/fail signature and handler snapshots are checked by the program
#   testbench.
# Used by: tb_program_machine_timer_interrupt
#   claim.

# Machine timer interrupt smoke.
# Uses the local CLINT-like timer window plus the minimal machine interrupt
# slice: mstatus.MIE, mie.MTIE, mip.MTIP, mtvec redirect, and mret.

    li   t0, 0x800        # machine timer MMIO base
    la   t5, timer_handler
    csrrw x0, mtvec, t5

    li   t1, 0
    sw   t1, 0(zero)      # recorded mcause
    sw   t1, 4(zero)      # recorded mepc
    sw   t1, 8(zero)      # recorded mip
    sw   t1, 12(zero)     # handler flag

    li   t1, 0xffffffff
    sw   t1, 12(t0)       # mtimecmp high far future
    sw   t1, 8(t0)        # mtimecmp low far future
    li   t1, 0
    sw   t1, 4(t0)        # mtime high = 0
    sw   t1, 0(t0)        # mtime low = 0
    sw   t1, 12(t0)       # mtimecmp high = 0
    li   t1, 80
    sw   t1, 8(t0)        # mtimecmp low, timer will become pending

    li   s1, 0
    li   t5, 0x80         # mie.MTIE
    csrrs x0, mie, t5
    li   t5, 0x8          # mstatus.MIE
    csrrs x0, mstatus, t5

wait_irq:
    lw   t2, 12(zero)
    beq  t2, zero, wait_irq

    li   t1, 1
    bne  s1, t1, fail
    lw   t2, 0(zero)
    li   t3, 0x80000007
    bne  t2, t3, fail
    lw   t2, 8(zero)
    andi t3, t2, 128
    beq  t3, zero, fail
    csrrs t2, mip, zero
    andi t3, t2, 128
    bne  t3, zero, fail

    li   t3, 256
    li   t4, 0x71ce8007
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)
    j    done

timer_handler:
    csrrs t1, mcause, zero
    sw   t1, 0(zero)
    li   t2, 0x80000007
    bne  t1, t2, fail
    csrrs t1, mepc, zero
    sw   t1, 4(zero)
    csrrs t1, mip, zero
    sw   t1, 8(zero)
    andi t2, t1, 128
    beq  t2, zero, fail

    li   t1, 0xffffffff
    sw   t1, 12(t0)       # postpone timer before returning
    sw   t1, 8(t0)
    li   t2, 0x80
    csrrc x0, mie, t2
    li   s1, 1
    sw   s1, 12(zero)
    mret

fail:
    li   t3, 256
    li   t4, 0xbad08007
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
