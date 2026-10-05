#include "platform.h"

static volatile uint8_t bytes[80];
static volatile uint16_t halves[40];
static volatile int8_t signed_bytes[4] = {-128, -1, 0, 127};
static volatile int16_t signed_halves[4] = {-32768, -1, 0, 32767};

int main(void)
{
    uint32_t zero_sum = 0;
    uint32_t byte_sum = 0;
    uint32_t half_sum = 0;
    int32_t signed_sum = 0;

    for (unsigned i = 0; i < 80; ++i) {
        zero_sum += bytes[i];
        bytes[i] = (uint8_t)(i * 7 + 3);
    }
    for (unsigned i = 0; i < 40; ++i) {
        zero_sum += halves[i];
        halves[i] = (uint16_t)(i * 1703 + 0x8001);
    }
    for (unsigned i = 0; i < 80; ++i) {
        byte_sum += bytes[i];
    }
    for (unsigned i = 0; i < 40; ++i) {
        half_sum += halves[i];
    }
    for (unsigned i = 0; i < 4; ++i) {
        signed_sum += signed_bytes[i] + signed_halves[i];
    }
    signature[0] = zero_sum;
    signature[1] = byte_sum;
    signature[2] = half_sum;
    signature[3] = (uint32_t)signed_sum;
    signature[4] = bytes[79];
    signature[5] = halves[39];
    return 0;
}
