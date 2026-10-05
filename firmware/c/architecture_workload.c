#include "platform.h"

/* Small deterministic workloads, with initialization outside the interval. */
static volatile int32_t data[128] __attribute__((aligned(64)));
#if WORKLOAD == 0
static const int32_t coefficients[8] = {3, -2, 7, 1, -5, 4, -1, 2};
static volatile int32_t output[64];
#endif

int main(void)
{
    for (unsigned i = 0; i < 128; ++i) {
        data[i] = (int32_t)((i * 37 + 11) & 255) - 128;
    }
    uint32_t answer = 0;
    __asm__ volatile(".global benchmark_begin\nbenchmark_begin:\n nop" ::: "memory");
#if WORKLOAD == 0
    /* Eight-tap FIR: bounded integer arithmetic, zero initial history. */
    for (unsigned i = 0; i < 64; ++i) {
        int32_t sum = 0;
        for (unsigned tap = 0; tap < 8; ++tap) {
            if (i >= tap) {
                sum += coefficients[tap] * data[i - tap];
            }
        }
        output[i] = sum;
        answer += (uint32_t)sum;
    }
#elif WORKLOAD == 1
    /* Reflected CRC-32, polynomial 0xedb88320, 128 input bytes. */
    answer = UINT32_C(0xffffffff);
    for (unsigned i = 0; i < 128; ++i) {
        answer ^= (uint8_t)data[i];
        for (unsigned bit = 0; bit < 8; ++bit) {
            answer = (answer >> 1) ^ ((answer & 1) ? UINT32_C(0xedb88320) : 0);
        }
    }
    answer ^= UINT32_C(0xffffffff);
#elif WORKLOAD == 2
    /* Data-dependent branches, loads and stores in insertion sort. */
    for (unsigned i = 1; i < 64; ++i) {
        int32_t value = data[i];
        unsigned j = i;
        while (j != 0 && data[j - 1] > value) {
            data[j] = data[j - 1];
            --j;
        }
        data[j] = value;
    }
    for (unsigned i = 0; i < 64; ++i) {
        answer = (answer << 1) ^ (uint32_t)data[i];
    }
#elif WORKLOAD == 3 || WORKLOAD == 4 || WORKLOAD == 5
    /* Same number of loads: resident, sequential, and conflicting addresses. */
    for (unsigned i = 0; i < 1024; ++i) {
#if WORKLOAD == 3
        unsigned index = i & 15;
#elif WORKLOAD == 4
        unsigned index = i & 127;
#else
        unsigned index = (i & 7) << 4;
#endif
        answer += (uint32_t)data[index];
    }
#else
#error Unknown workload
#endif
    signature[0] = answer;
    __asm__ volatile(".global benchmark_end\nbenchmark_end:\n nop" ::: "memory");
    return 0;
}
