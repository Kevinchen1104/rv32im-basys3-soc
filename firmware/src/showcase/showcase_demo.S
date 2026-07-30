# Program: showcase_demo
# Purpose: Runs the bootable AI SoC showcase transcript.
# Exercises: UART TX, GPIO phases, MATVEC Scratchpad, performance-counter MMIO, and public debug_status storage.
# Observable result: UART transcript, GPIO phase/final values, MATVEC results, counters, and pass signature are
#   checked by program/FPGA testbenches.
# Used by: tb_fpga_uart_boot_bram_soc_showcase, tb_fpga_uart_boot_showcase, tb_program_showcase_demo
# Does not claim: Simulation-tested showcase firmware only; not production firmware, benchmark evidence, timing
#   evidence, or physical board validation.

# Bootable showcase program:
# UART transcript, GPIO phase markers, MATVEC Scratchpad, and counter sample.

    li   s0, 0x300        # UART TX data
    li   s1, 0x308        # UART status: bit 1 is TX ready
    li   s2, 0x200        # GPIO output latch
    li   s3, 0x700        # MATVEC Scratchpad MMIO base
    li   s4, 0x600        # performance-counter MMIO base
    li   s5, 256          # public debug_status byte address 0x100

    li   t0, 0x01
    sw   t0, 0(s2)        # phase: start

    lw   s6, 0(s4)        # cycle_count before showcase body
    lw   s7, 20(s4)       # stall_cycle_count before showcase body

    call print_banner
    call print_uart_ok

    li   t0, 0x02
    sw   t0, 0(s2)        # phase: UART transcript started

    li   t0, 0x04
    sw   t0, 0(s2)        # phase: MATVEC Scratchpad running
    call run_matvec_case

    li   t0, 0x08
    sw   t0, 0(s2)        # phase: MATVEC Scratchpad pass
    call print_matvec_pass

    call sample_counters

    li   t0, 0x10
    sw   t0, 0(s2)        # phase: counter sample pass
    call print_counters_pass

    li   t0, 0x000000a5
    sw   t0, 0(s2)        # final GPIO pass marker
    call print_showcase_pass

pass:
    li   t4, 0x5a5ecafe
    sw   t4, 0(s5)
    call evict_showcase_results
    j    done

fail:
    li   t0, 0x000000ee
    sw   t0, 0(s2)
    li   t4, 0xbad05a5e
    sw   t4, 0(s5)
    call evict_showcase_results

done:
    beq  zero, zero, done

run_matvec_case:
    li   t1, 3            # CONFIG row_count_minus1 = 3, so 4 rows
    sw   t1, 8(s3)

    li   t1, 0xfc03fe01   # VECTOR = {x3, x2, x1, x0} = {-4, 3, -2, 1}
    sw   t1, 12(s3)

    li   t2, 0
    sw   t2, 16(s3)
    li   t1, 0x04030201   # ROW0 = {4, 3, 2, 1}
    sw   t1, 20(s3)

    li   t2, 1
    sw   t2, 16(s3)
    li   t1, 0x020100ff   # ROW1 = {2, 1, 0, -1}
    sw   t1, 20(s3)

    li   t2, 2
    sw   t2, 16(s3)
    li   t1, 0x0001807f   # ROW2 = {0, 1, -128, 127}
    sw   t1, 20(s3)

    li   t2, 3
    sw   t2, 16(s3)
    li   t1, 0xf807fa05   # ROW3 = {-8, 7, -6, 5}
    sw   t1, 20(s3)

    li   t1, 1
    sw   t1, 0(s3)        # CTRL start

matvec_poll:
    lw   t2, 4(s3)        # STATUS
    andi t2, t2, 2
    beq  t2, zero, matvec_poll

    li   t2, 0
    sw   t2, 24(s3)
    lw   a0, 28(s3)
    sw   a0, 0(zero)
    li   t3, 0xfffffff6
    bne  a0, t3, fail

    li   t2, 1
    sw   t2, 24(s3)
    lw   a1, 28(s3)
    sw   a1, 4(zero)
    li   t3, 0xfffffffa
    bne  a1, t3, fail

    li   t2, 2
    sw   t2, 24(s3)
    lw   a2, 28(s3)
    sw   a2, 8(zero)
    li   t3, 0x00000182
    bne  a2, t3, fail

    li   t2, 3
    sw   t2, 24(s3)
    lw   a3, 28(s3)
    sw   a3, 12(zero)
    li   t3, 0x00000046
    bne  a3, t3, fail

    lw   a4, 32(s3)       # MATVEC_PERF
    sw   a4, 16(zero)
    andi t5, a4, 255
    li   t6, 1
    bne  t5, t6, fail
    ret

sample_counters:
    sw   s6, 20(zero)     # cycle_count before
    sw   s7, 24(zero)     # stall_cycle_count before

    lw   t1, 0(s4)        # cycle_count after
    sw   t1, 28(zero)
    bltu t1, s6, fail

    lw   t2, 4(s4)        # retired_count after
    sw   t2, 32(zero)
    beq  t2, zero, fail

    lw   t3, 20(s4)       # stall_cycle_count after
    sw   t3, 36(zero)
    bltu t3, s7, fail

    lw   t4, 24(s4)       # existing global MATVEC start counter
    sw   t4, 40(zero)
    lw   t5, 28(s4)       # existing global MATVEC done counter
    sw   t5, 44(zero)
    lw   t6, 32(s4)       # existing global MATVEC busy-cycle counter
    sw   t6, 48(zero)
    ret

evict_showcase_results:
    li   t5, 336          # evict line with DMemory words 4..7
    lw   s8, 0(t5)
    li   t5, 352          # evict line with DMemory words 8..11
    lw   s8, 0(t5)
    li   t5, 368          # evict line with DMemory words 12..15
    lw   s8, 0(t5)
    li   t5, 320          # evict line with DMemory[64] debug_status
    lw   s8, 0(t5)
    ret

print_banner:
    addi s11, ra, 0
    li   a0, 0x52         # R
    call send_char
    li   a0, 0x56         # V
    call send_char
    li   a0, 0x33         # 3
    call send_char
    li   a0, 0x32         # 2
    call send_char
    li   a0, 0x49         # I
    call send_char
    li   a0, 0x4d         # M
    call send_char
    li   a0, 0x20         # space
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x48         # H
    call send_char
    li   a0, 0x4f         # O
    call send_char
    li   a0, 0x57         # W
    call send_char
    li   a0, 0x43         # C
    call send_char
    li   a0, 0x41         # A
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x45         # E
    call send_char
    li   a0, 0x0a         # newline
    call send_char
    jalr zero, 0(s11)

print_uart_ok:
    addi s11, ra, 0
    li   a0, 0x55         # U
    call send_char
    li   a0, 0x41         # A
    call send_char
    li   a0, 0x52         # R
    call send_char
    li   a0, 0x54         # T
    call send_char
    li   a0, 0x20         # space
    call send_char
    li   a0, 0x4f         # O
    call send_char
    li   a0, 0x4b         # K
    call send_char
    li   a0, 0x0a         # newline
    call send_char
    jalr zero, 0(s11)

print_matvec_pass:
    addi s11, ra, 0
    li   a0, 0x4d         # M
    call send_char
    li   a0, 0x41         # A
    call send_char
    li   a0, 0x54         # T
    call send_char
    li   a0, 0x56         # V
    call send_char
    li   a0, 0x45         # E
    call send_char
    li   a0, 0x43         # C
    call send_char
    li   a0, 0x20         # space
    call send_char
    li   a0, 0x50         # P
    call send_char
    li   a0, 0x41         # A
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x0a         # newline
    call send_char
    jalr zero, 0(s11)

print_counters_pass:
    addi s11, ra, 0
    li   a0, 0x43         # C
    call send_char
    li   a0, 0x4f         # O
    call send_char
    li   a0, 0x55         # U
    call send_char
    li   a0, 0x4e         # N
    call send_char
    li   a0, 0x54         # T
    call send_char
    li   a0, 0x45         # E
    call send_char
    li   a0, 0x52         # R
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x20         # space
    call send_char
    li   a0, 0x50         # P
    call send_char
    li   a0, 0x41         # A
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x0a         # newline
    call send_char
    jalr zero, 0(s11)

print_showcase_pass:
    addi s11, ra, 0
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x48         # H
    call send_char
    li   a0, 0x4f         # O
    call send_char
    li   a0, 0x57         # W
    call send_char
    li   a0, 0x43         # C
    call send_char
    li   a0, 0x41         # A
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x45         # E
    call send_char
    li   a0, 0x20         # space
    call send_char
    li   a0, 0x50         # P
    call send_char
    li   a0, 0x41         # A
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x53         # S
    call send_char
    li   a0, 0x0a         # newline
    call send_char
    jalr zero, 0(s11)

send_char:
    lw   t0, 0(s1)
    andi t0, t0, 2
    beq  t0, zero, send_char
    sw   a0, 0(s0)
    ret
