#include "platform.h"

static volatile int32_t signed_a = -1234567;
static volatile int32_t signed_b = 97;
static volatile uint32_t unsigned_a = UINT32_C(0xfffffffe);
static volatile uint32_t unsigned_b = 3;

int main(void)
{
    int32_t a = signed_a;
    int32_t b = signed_b;
    uint32_t u = unsigned_a;
    uint32_t v = unsigned_b;

    signature[0] = (uint32_t)(a + b);
    signature[1] = (uint32_t)(a - b);
    signature[2] = (uint32_t)(a * b);
    signature[3] = (uint32_t)(a / b);
    signature[4] = (uint32_t)(a % b);
    signature[5] = u * v;
    signature[6] = u / v;
    signature[7] = u % v;
    signature[8] = (u >> 5) ^ (u << 7);
    signature[9] = (uint32_t)(a < b);
    signature[10] = (uint32_t)(u < v);
    signature[11] = (u & UINT32_C(0x55aa55aa)) | UINT32_C(0x10001);
    return 0;
}
