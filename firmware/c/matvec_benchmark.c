#include "platform.h"

/* The runner supplies packed RAM operands and {rows, jobs, reuse_matrix}. */
volatile uint32_t benchmark_config[3] = {4, 1, 0};
volatile uint32_t benchmark_matrix[128] __attribute__((aligned(64))) = {1};
volatile uint32_t benchmark_vectors[8] __attribute__((aligned(64))) = {1};
volatile int32_t benchmark_output[128] __attribute__((aligned(64)));

#define REG(address) (*(volatile uint32_t *)(address))

#if METHOD == 0
/* Load each packed row once; keep all four vector lanes in registers. */
__attribute__((noinline))
static void software_matvec(volatile uint32_t *matrix, uint32_t vector,
                            volatile int32_t *output, unsigned rows)
{
    int32_t x0 = (int8_t)vector;
    int32_t x1 = (int8_t)(vector >> 8);
    int32_t x2 = (int8_t)(vector >> 16);
    int32_t x3 = (int8_t)(vector >> 24);
    for (unsigned row = 0; row < rows; ++row) {
        uint32_t packed = matrix[row];
        output[row] = (int8_t)packed * x0
                    + (int8_t)(packed >> 8) * x1
                    + (int8_t)(packed >> 16) * x2
                    + (int8_t)(packed >> 24) * x3;
    }
}
#elif METHOD == 1
__attribute__((noinline))
static void upload_matrix(volatile uint32_t *matrix, unsigned rows)
{
    for (unsigned row = 0; row < rows; ++row) {
        REG(0x0710) = row;
        REG(0x0714) = matrix[row];
    }
}
#elif METHOD != 2
#error Unknown benchmark method
#endif

int main(void)
{
    unsigned rows = benchmark_config[0];
    unsigned jobs = benchmark_config[1];
    unsigned reuse = benchmark_config[2];
    /* The comparison matrix uses 1, 2, 4, 8 or 16 rows in complete DMA blocks. */
    if (rows == 0 || rows > 16 || (rows & (rows - 1)) != 0 ||
        jobs == 0 || jobs > 8 || reuse > 1) {
        return 1;
    }

    /* Retired marker PCs delimit RAM-to-RAM work, including driver setup. */
    __asm__ volatile(".global benchmark_begin\nbenchmark_begin:\n nop" ::: "memory");
#if METHOD == 1
    REG(0x0708) = rows - 1;
    if (reuse) {
        upload_matrix(benchmark_matrix, rows);
    }
#elif METHOD == 2
    unsigned block_rows = rows < 4 ? rows : 4;
    REG(0x090c) = block_rows;
    if (reuse && rows <= 4) {
        REG(0x0904) = (uintptr_t)benchmark_matrix;
    }
#endif
    for (unsigned job = 0; job < jobs; ++job) {
        volatile uint32_t *matrix = benchmark_matrix + (reuse ? 0 : job * rows);
        volatile int32_t *output = benchmark_output + job * rows;
#if METHOD == 0
        software_matvec(matrix, benchmark_vectors[job], output, rows);
#elif METHOD == 1
        if (!reuse) {
            upload_matrix(matrix, rows);
        }
        REG(0x070c) = benchmark_vectors[job];
        REG(0x0700) = 3; /* Clear the previous sticky done flag and start. */
        while (!(REG(0x0704) & 2)) {
        }
        for (unsigned row = 0; row < rows; ++row) {
            REG(0x0718) = row;
            output[row] = (int32_t)REG(0x071c);
        }
#else
        REG(0x0900) = (uintptr_t)&benchmark_vectors[job];
        for (unsigned first = 0; first < rows; first += 4) {
            if (!reuse || rows > 4) {
                REG(0x0904) = (uintptr_t)&matrix[first];
            }
            REG(0x0908) = (uintptr_t)&output[first];
            REG(0x0910) = 1;
            uint32_t status;
            do {
                status = REG(0x0914);
            } while (!(status & 2));
            if (status & 4) {
                return 2;
            }
        }
#endif
    }
    __asm__ volatile(".global benchmark_end\nbenchmark_end:\n nop" ::: "memory");
    signature[0] = 0x600dcafe;
    return 0;
}
