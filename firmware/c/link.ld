ENTRY(_start)

/* The boot stub fits below MMIO. C code/data live above all MMIO windows. */
SECTIONS
{
    .text.boot 0 : { KEEP(*(.text.boot)) }
    ASSERT(SIZEOF(.text.boot) <= 0x100, "boot stub overlaps reserved addresses")
    .text 0x1000 : { *(.text .text.*) }
    __text_end = .;
    ASSERT(__text_end <= 0x3000, "program exceeds instruction region")
    .data 0x3000 : {
        *(.rodata .rodata.*)
        . = ALIGN(4);
        *(.data .data.* .sdata .sdata.*)
    }
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_data_end = .;
    }
    ASSERT(__bss_data_end <= 0x3800, "data overlaps signature")
    .signature 0x3800 (NOLOAD) : { *(.signature) }
    __bss_end = .;
    ASSERT(SIZEOF(.signature) == 64, "expected sixteen result words")
    __stack_top = 0x4000;
    /DISCARD/ : { *(.comment .eh_frame .riscv.attributes) }
}
