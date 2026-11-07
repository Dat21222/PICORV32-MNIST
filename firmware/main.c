#include <stdint.h>
#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#define MLP_BASE 0x10000000u
#define CONTROL REG32(MLP_BASE + 0x00u)
#define STATUS REG32(MLP_BASE + 0x04u)
#define PIXEL_DATA REG32(MLP_BASE + 0x08u)
#define PIXEL_COUNT REG32(MLP_BASE + 0x0cu)
#define RESULT REG32(MLP_BASE + 0x10u)
#define RESULT_MAILBOX REG32(0x2000u)
#define DONE_MAILBOX REG32(0x2004u)

int main(void)
{
    const volatile uint8_t *image = (const volatile uint8_t *)0x1000u;
    RESULT_MAILBOX = 0;
    /* Completion mailbox remains zero from COE initialization until finish. */
    CONTROL = 2; /* CLEAR */
    for (uint32_t i = 0; i < 784; ++i)
        PIXEL_DATA = image[i]; /* GCC generates byte load and MMIO word store. */
    if (PIXEL_COUNT != 784) {
        DONE_MAILBOX = 0xffffffffu;
        for (;;) { }
    }
    CONTROL = 1; /* START; weights_loaded must already be high. */
    while ((STATUS & 2u) == 0) { }
    RESULT_MAILBOX = RESULT;
    DONE_MAILBOX = 0x600d0001u;
    for (;;) { }
}
