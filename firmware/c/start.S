/* Bare-metal entry: initialize the stack and BSS, then call C main. */
    .section .text.boot,"ax",@progbits
    .globl _start
_start:
    la sp, __stack_top
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:
    call main
    .globl program_done
program_done:
    j program_done
