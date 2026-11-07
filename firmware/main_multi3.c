#include <stdint.h>
#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))
#define MLP_BASE 0x10000000u
#define CONTROL REG32(MLP_BASE + 0x00u)
#define STATUS REG32(MLP_BASE + 0x04u)
#define PIXEL_DATA REG32(MLP_BASE + 0x08u)
#define PIXEL_COUNT REG32(MLP_BASE + 0x0cu)
#define RESULT REG32(MLP_BASE + 0x10u)

#define RESULT_MAILBOX_BASE 0x2000u
#define DONE_MAILBOX        REG32(0x200cu)
#define IMAGE_BASE          0x1000u
#define IMAGE_STRIDE        0x0400u
#define NUM_IMAGES          3u

int main(void)
{
    for (uint32_t img_idx = 0; img_idx < NUM_IMAGES; ++img_idx) {
        REG32(RESULT_MAILBOX_BASE + (img_idx << 2)) = 0;
    }

    /* Classify all 3 images (0x1000, 0x1400, 0x1800) back-to-back. */
    for (uint32_t img_idx = 0; img_idx < NUM_IMAGES; ++img_idx) {
        const volatile uint8_t *image =
            (const volatile uint8_t *)(uintptr_t)(IMAGE_BASE + img_idx * IMAGE_STRIDE);

        CONTROL = 2; /* CLEAR */
        for (uint32_t i = 0; i < 784; ++i)
            PIXEL_DATA = image[i]; /* GCC generates byte load and MMIO word store. */

        if (PIXEL_COUNT != 784) {
            DONE_MAILBOX = 0xffffffffu;
            for (;;) { }
        }

        CONTROL = 1; /* START; weights_loaded must already be high. */
        while ((STATUS & 2u) == 0) { }

        REG32(RESULT_MAILBOX_BASE + (img_idx << 2)) = RESULT;
    }

    DONE_MAILBOX = 0x600d0003u;
    for (;;) { }
}
