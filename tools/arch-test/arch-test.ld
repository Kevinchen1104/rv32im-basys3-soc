ENTRY(rvtest_entry_point)

MEMORY
{
    ram (rwx) : ORIGIN = 0x00000000, LENGTH = 512K
}

SECTIONS
{
    . = ORIGIN(ram);

    .text.init : {
        *(.text.init)
    } > ram

    .text.rvtest : {
        *(.text.rvtest)
        *(.text.rvtest.*)
    } > ram

    .text : {
        *(.text)
        *(.text.*)
    } > ram

    . = ALIGN(4);
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    } > ram

    . = ALIGN(4);
    .data : {
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
    } > ram

    . = ALIGN(4);
    .bss : {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } > ram

    .text.rvmodel : {
        *(.text.rvmodel)
        *(.text.rvmodel.*)
    } > ram
}
