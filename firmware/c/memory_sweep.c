#include "platform.h"

/* One executable; the host changes only these data words for each scenario. */
volatile uint32_t memory_config[4] = {8, 16, 0, 0};
static volatile uint32_t data[256] __attribute__((aligned(64)));

int main(void)
{
    for (unsigned i = 0; i < 256; ++i) {
        data[i] = i * 37 + 11;
    }
    unsigned lines = memory_config[0];
    unsigned stride = memory_config[1];
    unsigned offset = memory_config[2];
    unsigned write_period = memory_config[3];
    uint32_t answer = 0;
    __asm__ volatile(".global benchmark_begin\nbenchmark_begin:\n nop" ::: "memory");
    for (unsigned i = 0; i < 1024; ++i) {
        unsigned index = offset + (i & (lines - 1)) * stride;
        if (write_period && !(i & (write_period - 1))) {
            data[index] += i;
        }
        answer += data[index];
    }
    signature[0] = answer;
    __asm__ volatile(".global benchmark_end\nbenchmark_end:\n nop" ::: "memory");
    return 0;
}
