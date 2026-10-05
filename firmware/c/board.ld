ENTRY(_start)

/* The board has separate 4-KiB IMEM and DMEM address spaces. All data is
   initialized at run time; no data reads from instruction memory are needed. */
SECTIONS
{
    .text 0 : { KEEP(*(.text.boot)) *(.text .text.*) }
    ASSERT(SIZEOF(.text) <= 0x1000, "board program exceeds 4-KiB IMEM")
    .data : { *(.data .data.* .sdata .sdata.* .rodata .rodata.*) }
    ASSERT(SIZEOF(.data) == 0, "board startup cannot load initialized data")
    .bss 0x0a00 (NOLOAD) : {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    }
    ASSERT(__bss_end <= 0x0e80, "leave at least 384 bytes for the stack")
    __stack_top = 0x1000;
    /DISCARD/ : { *(.comment .eh_frame .riscv.attributes) }
}
