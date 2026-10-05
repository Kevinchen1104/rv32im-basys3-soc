#include "platform.h"

static volatile uint32_t input = 13;

static __attribute__((noinline)) uint32_t mix(uint32_t a, uint32_t b)
{
    return (a * 17) ^ (b + 5);
}

static __attribute__((noinline)) uint32_t accumulate(uint32_t count)
{
    uint32_t sum = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (i & 1) {
            sum += mix(i, sum);
        } else {
            sum ^= mix(sum, i);
        }
    }
    return sum;
}

int main(void)
{
    uint32_t (*volatile operation)(uint32_t, uint32_t) = mix;
    uint32_t sum = accumulate(input);
    signature[0] = sum;
    signature[1] = operation(sum, 29);
    signature[2] = accumulate(0);
    return 0;
}
