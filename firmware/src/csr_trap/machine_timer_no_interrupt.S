# Program: machine_timer_no_interrupt
# Purpose: Checks the machine timer pending path while the interrupt source remains masked.
# Exercises: mtime/mtimecmp MMIO, mip.MTIP polling, mstatus.MIE, and disabled mie.MTIE behavior.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_machine_timer_no_interrupt

# Machine timer negative interrupt smoke.
# The timer is allowed to become pending, but mie.MTIE is kept disabled.

    li   t0, 0x800
    la   t5, unexpected_timer_irq
    csrrw x0, mtvec, t5

    li   s1, 0
    li   t1, 0
    sw   t1, 0(zero)      # handler flag

    li   t1, 0xffffffff
    sw   t1, 12(t0)
    sw   t1, 8(t0)
    li   t1, 0
    sw   t1, 4(t0)
    sw   t1, 0(t0)
    sw   t1, 12(t0)
    li   t1, 12
    sw   t1, 8(t0)        # timer will become pending soon

    li   t5, 0x80
    csrrc x0, mie, t5     # keep MTIE disabled
    li   t5, 0x8
    csrrs x0, mstatus, t5 # global MIE enabled but source masked

    li   t4, 120
wait_pending:
    csrrs t1, mip, zero
    andi t2, t1, 128
    bne  t2, zero, pending_seen
    addi t4, t4, -1
    bne  t4, zero, wait_pending
    j    fail

pending_seen:
    li   t4, 64
bounded_loop:
    bne  s1, zero, fail
    lw   t1, 0(t0)        # MMIO polling is allowed while pending
    addi t4, t4, -1
    bne  t4, zero, bounded_loop

    lw   t1, 0(zero)
    bne  t1, zero, fail

    li   t3, 256
    li   t4, 0x71ce8000
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)
    j    done

unexpected_timer_irq:
    li   s1, 1
    sw   s1, 0(zero)

fail:
    li   t3, 256
    li   t4, 0xbad08000
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
