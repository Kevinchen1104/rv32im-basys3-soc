# Program: uart_rx_back_to_back
# Purpose: Checks that each UART RX data read consumes exactly one queued byte.
# Exercises: RXDATA loads on consecutive cycles and a status load issued on the cycle after the last byte is read.
# Observable result: Public debug_status pass/fail signature is checked by the program testbench.
# Used by: tb_program_uart_rx_back_to_back

# The testbench queues 0x11, 0x22 and 0x33 before releasing CPU reset.
    li   s0, 768          # UART MMIO base 0x300
    lbu  a0, 4(s0)        # RXDATA: first byte
    lbu  a1, 4(s0)        # RXDATA on the next cycle: second byte
    lw   a2, 8(s0)        # status: one byte remains
    nop
    lbu  a3, 4(s0)        # RXDATA: last byte
    lw   a4, 8(s0)        # status on the next cycle: queue is empty

    li   t0, 0x11
    bne  a0, t0, fail
    li   t0, 0x22
    bne  a1, t0, fail
    andi t1, a2, 1
    li   t0, 1
    bne  t1, t0, fail
    li   t0, 0x33
    bne  a3, t0, fail
    andi t1, a4, 1
    bne  t1, zero, fail

    li   t3, 256
    li   t4, 0xc5e3a0b0
    sw   t4, 0(t3)
    j    done

fail:
    li   t3, 256
    li   t4, 0xbad5a0b0
    sw   t4, 0(t3)

done:
    beq  zero, zero, done
