#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(address))
static volatile uint32_t matrix[128] __attribute__((aligned(64)));
static volatile uint32_t vectors[8];
static volatile int32_t output[128];

static void putc_uart(unsigned byte)
{
    while (!(REG(0x0308) & 2)) {
    }
    REG(0x0300) = byte;
}

static void hex_uart(uint32_t value)
{
    putc_uart(' ');
    for (int shift = 28; shift >= 0; shift -= 4) {
        unsigned digit = (value >> shift) & 15;
        putc_uart(digit < 10 ? '0' + digit : 'a' + digit - 10);
    }
}

/* Deterministic operands match the existing host's signed dot-product oracle. */
static void prepare(unsigned rows, unsigned jobs, unsigned reuse)
{
    for (unsigned j = 0; j < (reuse ? 1 : jobs); ++j) {
        for (unsigned r = 0; r < rows; ++r) {
            uint32_t packed = 0;
            for (unsigned k = 0; k < 4; ++k) {
                packed |= ((j * 11 + r * 17 + k * 29 - 128) & 255) << (8 * k);
            }
            matrix[j * rows + r] = packed;
        }
    }
    for (unsigned j = 0; j < jobs; ++j) {
        uint32_t packed = 0;
        for (unsigned k = 0; k < 4; ++k) {
            packed |= ((j * 37 + k * 83 - 128) & 255) << (8 * k);
        }
        vectors[j] = packed;
    }
    for (unsigned r = 0; r < jobs * rows; ++r) {
        output[r] = (int32_t)0xa5a5a5a5;
    }
}

__attribute__((noinline))
static void software_matvec(volatile uint32_t *a, uint32_t x,
                            volatile int32_t *y, unsigned rows)
{
    int32_t x0 = (int8_t)x;
    int32_t x1 = (int8_t)(x >> 8);
    int32_t x2 = (int8_t)(x >> 16);
    int32_t x3 = (int8_t)(x >> 24);
    for (unsigned r = 0; r < rows; ++r) {
        uint32_t packed = a[r];
        y[r] = (int8_t)packed * x0 + (int8_t)(packed >> 8) * x1
             + (int8_t)(packed >> 16) * x2 + (int8_t)(packed >> 24) * x3;
    }
}

static void upload(volatile uint32_t *a, unsigned rows)
{
    for (unsigned r = 0; r < rows; ++r) {
        REG(0x0710) = r;
        REG(0x0714) = a[r];
    }
}

__attribute__((noinline))
static uint32_t measure(unsigned method, unsigned rows, unsigned jobs, unsigned reuse)
{
    __asm__ volatile("" ::: "memory");
    uint32_t begin = REG(0x0600);
    if (method == 1) {
        REG(0x0708) = rows - 1;
        if (reuse) {
            upload(matrix, rows);
        }
    } else if (method == 2) {
        REG(0x090c) = rows < 4 ? rows : 4;
        if (reuse && rows <= 4) {
            REG(0x0904) = (uintptr_t)matrix;
        }
    }
    for (unsigned j = 0; j < jobs; ++j) {
        volatile uint32_t *a = matrix + (reuse ? 0 : j * rows);
        volatile int32_t *y = output + j * rows;
        if (method == 0) {
            software_matvec(a, vectors[j], y, rows);
        } else if (method == 1) {
            if (!reuse) {
                upload(a, rows);
            }
            REG(0x070c) = vectors[j];
            REG(0x0700) = 3;
            while (!(REG(0x0704) & 2)) {
            }
            for (unsigned r = 0; r < rows; ++r) {
                REG(0x0718) = r;
                y[r] = (int32_t)REG(0x071c);
            }
        } else {
            REG(0x0900) = (uintptr_t)&vectors[j];
            for (unsigned first = 0; first < rows; first += 4) {
                if (!reuse || rows > 4) {
                    REG(0x0904) = (uintptr_t)&a[first];
                }
                REG(0x0908) = (uintptr_t)&y[first];
                REG(0x0910) = 1;
                uint32_t status;
                do {
                    status = REG(0x0914);
                } while (!(status & 2));
                if (status & 4) {
                    return 0;
                }
            }
        }
    }
    uint32_t end = REG(0x0600);
    __asm__ volatile("" ::: "memory");
    return end - begin;
}

int main(void)
{
    unsigned count = 0;
    putc_uart('B');
    hex_uart(1);
    putc_uart('\n');
    for (unsigned reuse = 0; reuse < 2; ++reuse) {
        for (unsigned rows = 1; rows <= 16; rows *= 2) {
            for (unsigned jobs = 1; jobs <= 8; jobs = jobs == 1 ? 4 : jobs * 2) {
                for (unsigned method = 0; method < 3; ++method) {
                    prepare(rows, jobs, reuse);
                    uint32_t cycles = measure(method, rows, jobs, reuse);
                    putc_uart('M');
                    hex_uart(reuse);
                    hex_uart(rows);
                    hex_uart(jobs);
                    hex_uart(method);
                    hex_uart(cycles);
                    for (unsigned r = 0; r < rows * jobs; ++r) {
                        hex_uart((uint32_t)output[r]);
                    }
                    putc_uart('\n');
                    ++count;
                }
            }
        }
    }
    putc_uart('E');
    hex_uart(count);
    putc_uart('\n');
    REG(0x0200) = 0x5a;
    REG(0x0100) = 0x600dcafe;
    (void)REG(0x0140); /* Evict the dirty public-status line into external DMEM. */
    return 0;
}
