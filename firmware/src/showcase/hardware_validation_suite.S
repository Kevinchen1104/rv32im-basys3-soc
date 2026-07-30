# Program: hardware_validation_suite
# Purpose: Runs a packet-bootable Basys3 hardware self-check across RV32M, timer interrupts, and MATVEC DMA-lite.
# Exercises: Selected RV32M arithmetic, machine timer CSR/trap/mret behavior, external-DMEM MATVEC DMA-lite, UART TX,
#   GPIO phase markers, and the public pass/fail status latch.
# Observable result: Exact UART transcript, GPIO phases, timer/DMA snapshots, and 0x600dcafe/0xbad0a5a5 status.
# Used by: tb_program_hardware_validation_suite, tb_fpga_uart_boot_hardware_validation_suite
# Does not claim: Selected directed hardware validation only; not official compliance, exhaustive ISA coverage,
#   direct-100-MHz timing closure, benchmark speedup, production DMA, or power/performance signoff.

    li   s0, 0x300        # UART TX data
    li   s1, 0x308        # UART status: bit 1 is TX ready
    li   s2, 0x200        # GPIO output latch
    li   s3, 0x800        # machine timer MMIO base
    li   s4, 0x900        # MATVEC DMA-lite MMIO base
    li   s5, 0x100        # public debug_status byte address
    li   s6, 0x140        # timer/DMA snapshot base
    li   s7, 0x180        # DMA vector word
    li   s8, 0x190        # DMA matrix rows
    li   s9, 0x1a0        # DMA output words

    li   t0, 0x10
    sw   t0, 0(s2)
    call print_banner

    call test_rv32m
    bne  a0, zero, rv32m_fail
    li   t0, 0x21
    sw   t0, 0(s2)
    call print_rv32m_pass

    call test_timer_irq
    bne  a0, zero, timer_fail
    li   t0, 0x32
    sw   t0, 0(s2)
    call print_timer_pass

    call test_matvec_dma
    bne  a0, zero, dma_fail
    li   t0, 0x43
    sw   t0, 0(s2)
    call print_dma_pass

    lw   t1, 0(s8)        # 0x190 conflicts with and writes back the 0x150 snapshot line

    li   t0, 0xa6
    sw   t0, 0(s2)
    call print_final_pass
    li   t0, 0x600dcafe
    sw   t0, 0(s5)
    lw   t1, 0(s6)        # conflicting line evicts the status line to external DMem
    j    done

rv32m_fail:
    li   t0, 1
    sw   t0, 24(s6)
    call print_rv32m_fail
    j    fail_common

timer_fail:
    li   t0, 2
    sw   t0, 24(s6)
    call print_timer_fail
    j    fail_common

dma_fail:
    li   t0, 3
    sw   t0, 24(s6)
    call print_dma_fail

fail_common:
    li   t0, 0xee
    sw   t0, 0(s2)
    li   t0, 0xbad0a5a5
    sw   t0, 0(s5)
    lw   t1, 0(s6)

done:
    beq  zero, zero, done

test_rv32m:
    li   t0, 7
    li   t1, -3
    mul  t2, t0, t1
    li   t3, -21
    bne  t2, t3, test_rv32m_bad
    mulh t2, t0, t1
    li   t3, -1
    bne  t2, t3, test_rv32m_bad
    mulhsu t2, t1, t0
    bne  t2, t3, test_rv32m_bad
    mulhu t2, t0, t1
    li   t3, 6
    bne  t2, t3, test_rv32m_bad

    div  t2, t0, t1
    li   t3, -2
    bne  t2, t3, test_rv32m_bad
    rem  t2, t0, t1
    li   t3, 1
    bne  t2, t3, test_rv32m_bad
    divu t2, t0, t1
    bne  t2, zero, test_rv32m_bad
    remu t2, t0, t1
    li   t3, 7
    bne  t2, t3, test_rv32m_bad

    li   t0, -7
    li   t1, 0
    div  t2, t0, t1
    li   t3, -1
    bne  t2, t3, test_rv32m_bad
    divu t2, t0, t1
    bne  t2, t3, test_rv32m_bad
    rem  t2, t0, t1
    li   t3, -7
    bne  t2, t3, test_rv32m_bad
    remu t2, t0, t1
    bne  t2, t3, test_rv32m_bad

    li   t0, 0x80000000
    li   t1, -1
    div  t2, t0, t1
    bne  t2, t0, test_rv32m_bad
    rem  t2, t0, t1
    bne  t2, zero, test_rv32m_bad

    li   t0, 0xffffffff
    li   t1, 2
    divu t2, t0, t1
    li   t3, 0x7fffffff
    bne  t2, t3, test_rv32m_bad
    remu t2, t0, t1
    li   t3, 1
    bne  t2, t3, test_rv32m_bad

    li   a0, 0
    ret

test_rv32m_bad:
    li   a0, 1
    ret

test_timer_irq:
    li   t0, 0
    sw   t0, 0(s6)        # mcause
    sw   t0, 4(s6)        # mepc
    sw   t0, 8(s6)        # handler-time mip
    sw   t0, 12(s6)       # handler flag: 1 pass, 2 fail
    sw   t0, 16(s6)       # post-mret mstatus
    sw   t0, 20(s6)       # DMA PERF snapshot

    la   t0, timer_handler
    csrrw zero, mtvec, t0

    li   t0, -1
    sw   t0, 12(s3)       # mtimecmp high far future
    sw   t0, 8(s3)
    li   t0, 0
    sw   t0, 4(s3)        # mtime high
    sw   t0, 0(s3)        # mtime low
    sw   t0, 12(s3)       # mtimecmp high = 0
    li   t0, 80
    sw   t0, 8(s3)        # mtimecmp low

    li   t0, 0x80
    csrrs zero, mie, t0
    li   t0, 0x8
    csrrs zero, mstatus, t0

    li   t6, 10000
timer_wait:
    lw   t4, 12(s6)
    bne  t4, zero, timer_returned
    addi t6, t6, -1
    bne  t6, zero, timer_wait
    j    test_timer_bad

timer_returned:
    li   t5, 1
    bne  t4, t5, test_timer_bad
    lw   t1, 0(s6)
    li   t2, 0x80000007
    bne  t1, t2, test_timer_bad
    lw   t1, 4(s6)
    beq  t1, zero, test_timer_bad
    andi t2, t1, 3
    bne  t2, zero, test_timer_bad
    lw   t1, 8(s6)
    andi t2, t1, 0x80
    beq  t2, zero, test_timer_bad
    csrrs t1, mip, zero
    andi t2, t1, 0x80
    bne  t2, zero, test_timer_bad
    csrrs t1, mstatus, zero
    sw   t1, 16(s6)
    andi t2, t1, 0x88
    li   t3, 0x88
    bne  t2, t3, test_timer_bad
    li   t0, 0x8
    csrrc zero, mstatus, t0
    li   a0, 0
    ret

test_timer_bad:
    li   t0, 0x80
    csrrc zero, mie, t0
    li   t0, 0x8
    csrrc zero, mstatus, t0
    li   a0, 1
    ret

timer_handler:
    csrrs t1, mcause, zero
    sw   t1, 0(s6)
    csrrs t1, mepc, zero
    sw   t1, 4(s6)
    csrrs t1, mip, zero
    sw   t1, 8(s6)

    li   t2, 1
    li   t0, 0x80000007
timer_check_cause:
    lw   t1, 0(s6)
    beq  t1, t0, timer_check_pending
    li   t2, 2
timer_check_pending:
    lw   t1, 8(s6)
    andi t1, t1, 0x80
    bne  t1, zero, timer_postpone
    li   t2, 2

timer_postpone:
    li   t0, -1
    sw   t0, 12(s3)
    sw   t0, 8(s3)
    li   t0, 0x80
    csrrc zero, mie, t0
    sw   t2, 12(s6)
    mret

test_matvec_dma:
    li   t0, 0xfc03fe01
    sw   t0, 0(s7)

    li   t0, 0x01ff0201
    sw   t0, 0(s8)
    li   t0, 0x00000504
    sw   t0, 4(s8)
    li   t0, 0x0001807f
    sw   t0, 8(s8)
    li   t0, 0x000aec00
    sw   t0, 12(s8)

    sw   s7, 0(s4)
    sw   s8, 4(s4)
    sw   s9, 8(s4)
    li   t0, 4
    sw   t0, 12(s4)
    li   t0, 1
    sw   t0, 16(s4)

    li   t6, 10000
dma_poll:
    lw   t1, 20(s4)
    andi t2, t1, 4
    bne  t2, zero, test_dma_bad
    andi t2, t1, 2
    bne  t2, zero, dma_done
    addi t6, t6, -1
    bne  t6, zero, dma_poll
    j    test_dma_bad

dma_done:
    lw   a1, 0(s9)
    li   t3, -10
    bne  a1, t3, test_dma_bad
    lw   a2, 4(s9)
    li   t3, -6
    bne  a2, t3, test_dma_bad
    lw   a3, 8(s9)
    li   t3, 386
    bne  a3, t3, test_dma_bad
    lw   a4, 12(s9)
    li   t3, 70
    bne  a4, t3, test_dma_bad
    lw   a5, 28(s4)
    sw   a5, 20(s6)
    li   t3, 0x04050101
    bne  a5, t3, test_dma_bad
    li   t0, 4
    sw   t0, 16(s4)
    lw   t1, 20(s4)
    andi t2, t1, 6
    bne  t2, zero, test_dma_bad
    li   a0, 0
    ret

test_dma_bad:
    li   a0, 1
    ret

send_char:
    lw   t6, 0(s1)
    andi t6, t6, 2
    beq  t6, zero, send_char
    sw   a0, 0(s0)
    ret

print_banner:
    addi s11, ra, 0
    li a0, 0x52
    call send_char
    li a0, 0x56
    call send_char
    li a0, 0x33
    call send_char
    li a0, 0x32
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x4d
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x48
    call send_char
    li a0, 0x57
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x56
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x4c
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x44
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x54
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x4f
    call send_char
    li a0, 0x4e
    call send_char
    li a0, 0x0a
    call send_char
    jalr zero, 0(s11)

print_rv32m_pass:
    addi s11, ra, 0
    li a0, 0x52
    call send_char
    li a0, 0x56
    call send_char
    li a0, 0x33
    call send_char
    li a0, 0x32
    call send_char
    li a0, 0x4d
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x50
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x0a
    call send_char
    jalr zero, 0(s11)

print_timer_pass:
    addi s11, ra, 0
    li a0, 0x54
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x4d
    call send_char
    li a0, 0x45
    call send_char
    li a0, 0x52
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x52
    call send_char
    li a0, 0x51
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x50
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x0a
    call send_char
    jalr zero, 0(s11)

print_dma_pass:
    addi s11, ra, 0
    li a0, 0x4d
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x54
    call send_char
    li a0, 0x56
    call send_char
    li a0, 0x45
    call send_char
    li a0, 0x43
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x44
    call send_char
    li a0, 0x4d
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x50
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x0a
    call send_char
    jalr zero, 0(s11)

print_final_pass:
    addi s11, ra, 0
    li a0, 0x48
    call send_char
    li a0, 0x57
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x56
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x4c
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x44
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x54
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x4f
    call send_char
    li a0, 0x4e
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x50
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x53
    call send_char
    li a0, 0x0a
    call send_char
    jalr zero, 0(s11)

print_rv32m_fail:
    addi s11, ra, 0
    li a0, 0x52
    call send_char
    li a0, 0x56
    call send_char
    li a0, 0x33
    call send_char
    li a0, 0x32
    call send_char
    li a0, 0x4d
    call send_char
    li a0, 0x20
    call send_char
    call print_fail_tail
    jalr zero, 0(s11)

print_timer_fail:
    addi s11, ra, 0
    li a0, 0x54
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x4d
    call send_char
    li a0, 0x45
    call send_char
    li a0, 0x52
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x52
    call send_char
    li a0, 0x51
    call send_char
    li a0, 0x20
    call send_char
    call print_fail_tail
    jalr zero, 0(s11)

print_dma_fail:
    addi s11, ra, 0
    li a0, 0x4d
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x54
    call send_char
    li a0, 0x56
    call send_char
    li a0, 0x45
    call send_char
    li a0, 0x43
    call send_char
    li a0, 0x20
    call send_char
    li a0, 0x44
    call send_char
    li a0, 0x4d
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x20
    call send_char
    call print_fail_tail
    jalr zero, 0(s11)

print_fail_tail:
    addi t5, ra, 0
    li a0, 0x46
    call send_char
    li a0, 0x41
    call send_char
    li a0, 0x49
    call send_char
    li a0, 0x4c
    call send_char
    li a0, 0x0a
    call send_char
    jalr zero, 0(t5)
