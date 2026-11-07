.section .text.start,"ax",@progbits
.globl _start
.type _start, @function
_start:
    /* Stack grows down in the top 4 KiB of the 64 KiB CPU RAM. */
    li sp, 0x10000
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sw zero, 0(t0)
    addi t0, t0, 4
    j 1b
2:
    call main
3:
    j 3b
.size _start, .-_start
