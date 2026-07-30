# Program: matvec_scratchpad_interrupt
# Purpose: Drives MATVEC Scratchpad with its local completion interrupt enabled.
# Exercises: MATVEC Scratchpad MMIO, mstatus.MIE, mie.MEIE, mip.MEIP, mtvec redirect, and mret return.
# Observable result: Public debug_status pass/fail signature plus handler/result state are checked by the program
#   testbench.
# Used by: tb_program_matvec_scratchpad_interrupt
#   accelerator, or speedup claim.

# MATVEC Scratchpad interrupt-driven smoke.
# Uses the minimal machine external interrupt slice: mstatus.MIE, mie.MEIE,
# MATVEC irq_pending -> mip.MEIP, mtvec redirect, and mret back to mepc.

    li   t0, 0x700        # MATVEC Scratchpad MMIO base
    la   t5, irq_handler
    csrrw x0, mtvec, t5
    li   t5, 0x800        # mie.MEIE
    csrrs x0, mie, t5
    li   t5, 0x8          # mstatus.MIE
    csrrs x0, mstatus, t5

    li   s1, 0            # handler sets this before mret

    li   t1, 0            # CONFIG row_count_minus1 = 0, one row
    sw   t1, 8(t0)
    li   t1, 0x01010101   # VECTOR = [1, 1, 1, 1]
    sw   t1, 12(t0)
    li   t2, 0
    sw   t2, 16(t0)       # ROW_INDEX = 0
    li   t1, 0x04030201   # ROW0 dot vector = 10
    sw   t1, 20(t0)

    li   t1, 4            # CTRL interrupt_enable set
    sw   t1, 0(t0)
    li   t1, 1            # CTRL start
    sw   t1, 0(t0)

wait_irq:
    beq  s1, zero, wait_irq

    li   t1, 1
    bne  s1, t1, fail
    lw   t2, 4(t0)        # STATUS after handler clear
    li   t3, 0x102        # done | irq_pending must both be clear
    and  t2, t2, t3
    bne  t2, zero, fail

    lw   a1, 0(zero)      # handler marker
    li   t3, 0x1ace0001
    bne  a1, t3, fail

    li   t3, 256
    li   t4, 0xacce2104
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)
    j    done

irq_handler:
    lw   t2, 4(t0)        # STATUS should have done and irq_pending set
    li   t3, 0x102
    and  t4, t2, t3
    bne  t4, t3, fail

    li   t2, 0
    sw   t2, 24(t0)       # RESULT_INDEX = 0
    lw   a0, 28(t0)       # RESULT_DATA
    li   t3, 10
    bne  a0, t3, fail

    li   t2, 18           # CTRL clear_done | clear_irq
    sw   t2, 0(t0)
    li   t3, 0x1ace0001
    sw   t3, 0(zero)
    li   s1, 1
    mret

fail:
    li   t3, 256
    li   t4, 0xbad02104
    sw   t4, 0(t3)
    lw   s2, 336(zero)
    lw   s0, 320(zero)

done:
    beq  zero, zero, done
