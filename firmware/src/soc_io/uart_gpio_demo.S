# Program: uart_gpio_demo
# Purpose: Emits a short UART TX string and writes a GPIO output pattern through MMIO.
# Exercises: UART TX ready/data MMIO, GPIO output/readback MMIO, and public debug_status storage.
# Observable result: UART transcript "RV32IM CPU OK\n", GPIO 0xa5, and debug_status signature are checked by
#   testbenches.
# Used by: tb_fpga_uart_boot_top, tb_program_uart_gpio_demo

# Board-facing MMIO UART TX and GPIO output demo.
# Emits "RV32IM CPU OK\n" through UART TX and leaves GPIO output at 0xa5.

    li   s0, 0x300        # UART TX data
    li   s1, 0x308        # UART status: bit 1 is TX ready
    li   s2, 0x200        # GPIO output latch

    li   s3, 0x55
    sw   s3, 0(s2)

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
    li   a0, 0x43         # C
    call send_char
    li   a0, 0x50         # P
    call send_char
    li   a0, 0x55         # U
    call send_char
    li   a0, 0x20         # space
    call send_char
    li   a0, 0x4f         # O
    call send_char
    li   a0, 0x4b         # K
    call send_char
    li   a0, 0x0a         # newline
    call send_char

after_message:
    li   s3, 0x000000a5
    sw   s3, 0(s2)
    lw   t2, 0(s2)
    bne  t2, s3, fail

pass:
    li   t3, 256
    li   t4, 0x10c0a5a5
    sw   t4, 0(t3)
    lw   s5, 320(zero)
    j    done

fail:
    li   t3, 256
    li   t4, 0xbad0a5a5
    sw   t4, 0(t3)
    lw   s5, 320(zero)

done:
    beq  zero, zero, done

send_char:
    lw   t0, 0(s1)
    andi t0, t0, 2
    beq  t0, zero, send_char
    sw   a0, 0(s0)
    ret
