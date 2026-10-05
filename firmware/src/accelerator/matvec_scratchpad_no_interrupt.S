# Program: matvec_scratchpad_no_interrupt
# Purpose: Checks MATVEC Scratchpad completes without taking an interrupt when interrupt_enable remains reset.
# Exercises: MATVEC Scratchpad MMIO, machine external-interrupt gating, polling, and done clearing.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_matvec_scratchpad_no_interrupt

# MATVEC Scratchpad negative interrupt smoke.
# CPU interrupt CSRs are enabled, but MATVEC interrupt_enable stays reset.
# Completion must not trap; software polls done and checks the result.

    li   t0, 0x700
    la   t5, unexpected_irq
    csrrw x0, mtvec, t5
    li   t5, 0x800
    csrrs x0, mie, t5
    li   t5, 0x8
    csrrs x0, mstatus, t5

    li   t1, 0
    sw   t1, 8(t0)        # one row
    li   t1, 0x01010101
    sw   t1, 12(t0)
    li   t2, 0
    sw   t2, 16(t0)
    li   t1, 0x04030201
    sw   t1, 20(t0)

    li   t1, 1
    sw   t1, 0(t0)        # start without CTRL interrupt_enable

poll:
    lw   t2, 4(t0)
    andi t3, t2, 2
    beq  t3, zero, poll
    andi t3, t2, 256
    bne  t3, zero, fail

    li   t2, 0
    sw   t2, 24(t0)
    lw   a0, 28(t0)
    li   t3, 10
    bne  a0, t3, fail

    li   t1, 2
    sw   t1, 0(t0)
    lw   t2, 4(t0)
    andi t3, t2, 258
    bne  t3, zero, fail

    li   t3, 256
    li   t4, 0xacce2105
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)
    j    done

unexpected_irq:
    li   t3, 256
    li   t4, 0xbad02105
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)
    j    done

fail:
    li   t3, 256
    li   t4, 0xbad02105
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
