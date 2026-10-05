#ifndef COMPILED_PROGRAM_PLATFORM_H
#define COMPILED_PROGRAM_PLATFORM_H

#include <stdint.h>

/* A fixed, ordinary-RAM result area inspected after main returns. */
volatile uint32_t signature[16] __attribute__((section(".signature")));

#endif
