OUTPUT_ARCH(riscv)
ENTRY(_start)
/* Only the first 4 KiB may hold code/static data.
   The COE packer inserts the image at 0x1000 and mailboxes at 0x2000.
   The stack occupies 0xF000..0xFFFF (startup sets SP=0x10000). */
MEMORY { CODE (rwx) : ORIGIN = 0x00000000, LENGTH = 0x1000 }
SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > CODE
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > CODE
    .data : { *(.data .data.* .sdata .sdata.*) } > CODE
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > CODE
    ASSERT(__bss_end <= 0x1000, "Firmware overlaps image at 0x1000")
    /DISCARD/ : { *(.comment) *(.eh_frame*) }
}
