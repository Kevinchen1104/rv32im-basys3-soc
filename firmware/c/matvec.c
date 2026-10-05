#include "platform.h"

static volatile int8_t matrix[4][4] = {
    {1, -2, 3, -4},
    {-128, 127, 0, 1},
    {7, 11, -13, 17},
    {-5, -9, 21, 4}
};
static volatile int8_t vector[4] = {-3, 5, -7, 11};

int main(void)
{
    for (unsigned row = 0; row < 4; ++row) {
        int32_t sum = 0;
        for (unsigned column = 0; column < 4; ++column) {
            sum += matrix[row][column] * vector[column];
        }
        signature[row] = (uint32_t)sum;
    }
    return 0;
}
