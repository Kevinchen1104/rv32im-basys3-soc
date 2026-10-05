#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(address))
#define FRAME_SIZE 160
#define MAX_TAPS 8
#define MAX_SAMPLES 32
#define RX_CHUNK 32

static uint8_t frame[FRAME_SIZE];
static int32_t coefficients[MAX_TAPS];
static int32_t history[MAX_TAPS];
static int32_t outputs[MAX_SAMPLES];
static unsigned taps, scale;
static int32_t threshold;
static uint32_t samples_seen, events_seen, leds;
static uint16_t tx_crc;

static void uart_put(unsigned value)
{
    while (!(REG(0x0308) & 2)) {
    }
    REG(0x0300) = value;
}

static uint16_t crc_byte(uint16_t crc, unsigned value)
{
    crc ^= value << 8;
    for (unsigned bit = 0; bit < 8; ++bit) {
        crc = (crc << 1) ^ ((crc & 0x8000) ? 0x1021 : 0);
    }
    return crc;
}

static void escaped_put(unsigned value)
{
    if (value == 0x7e || value == 0x7d) {
        uart_put(0x7d);
        value ^= 0x20;
    }
    uart_put(value);
}

static void reply_byte(unsigned value)
{
    value &= 255;
    tx_crc = crc_byte(tx_crc, value);
    escaped_put(value);
}

static void reply_word(uint32_t value)
{
    for (unsigned byte = 0; byte < 4; ++byte) {
        reply_byte(value);
        value >>= 8;
    }
}

static void reply_begin(unsigned seq, unsigned command, unsigned status, unsigned length)
{
    uart_put(0x7e);
    tx_crc = 0xffff;
    reply_byte(seq);
    reply_byte(command);
    reply_byte(status);
    reply_byte(length);
}

static void reply_end(void)
{
    uint16_t checksum = tx_crc;
    escaped_put(checksum & 255);
    escaped_put(checksum >> 8);
    uart_put(0x7e);
}

static void clear_history(void)
{
    for (unsigned i = 0; i < MAX_TAPS; ++i) {
        history[i] = 0;
    }
    samples_seen = 0;
    events_seen = 0;
    leds &= 0xfe;
    REG(0x0200) = leds;
}

static void handle_frame(unsigned length, unsigned damaged)
{
    unsigned seq = length > 0 ? frame[0] : 0;
    unsigned command = length > 1 ? frame[1] : 0;
    unsigned status = 0;
    uint16_t checksum = 0xffff;
    if (damaged || length < 5 || length != (unsigned)frame[2] + 5) {
        status = 1;
    } else {
        for (unsigned i = 0; i < length - 2; ++i) {
            checksum = crc_byte(checksum, frame[i]);
        }
        if (checksum != (unsigned)(frame[length - 2] | (frame[length - 1] << 8))) {
            status = 1;
        }
    }
    unsigned count = 0;
    uint32_t cycles = 0;
    uint32_t events = 0;
    unsigned payload = frame[2];
    if (!status) {
        if (command == 'C') {
            if (payload < 7 || frame[3] < 1 || frame[3] > MAX_TAPS ||
                frame[4] > 15 || payload != 6u + frame[3]) {
                status = 2;
            } else {
                taps = frame[3];
                scale = frame[4];
                threshold = (int32_t)((uint32_t)frame[5] | ((uint32_t)frame[6] << 8) |
                            ((uint32_t)frame[7] << 16) | ((uint32_t)frame[8] << 24));
                for (unsigned i = 0; i < taps; ++i) {
                    coefficients[i] = (int8_t)frame[9 + i];
                }
                clear_history();
            }
        } else if (command == 'D') {
            if (!payload || payload > MAX_SAMPLES * 2 || (payload & 1)) {
                status = 2;
            } else {
                count = payload / 2;
                uint32_t start = REG(0x0600);
                for (unsigned i = 0; i < count; ++i) {
                    for (unsigned k = taps - 1; k > 0; --k) {
                        history[k] = history[k - 1];
                    }
                    history[0] = (int16_t)(frame[3 + 2 * i] | (frame[4 + 2 * i] << 8));
                    int32_t sum = 0;
                    for (unsigned k = 0; k < taps; ++k) {
                        sum += coefficients[k] * history[k];
                    }
                    /* C division truncates toward zero, including negative outputs. */
                    outputs[i] = sum / (int32_t)(1u << scale);
                    events += outputs[i] >= threshold;
                }
                cycles = REG(0x0600) - start;
                samples_seen += count;
                events_seen += events;
                leds = (leds & 0xfe) | (events != 0);
                REG(0x0200) = leds;
            }
        } else if (command == 'S' || command == 'R') {
            if (payload) {
                status = 2;
            } else if (command == 'R') {
                clear_history();
            }
        } else if (command == 'L') {
            if (payload != 1) {
                status = 2;
            } else {
                leds = (leds & 1) | (frame[3] & 0xfe);
                REG(0x0200) = leds;
            }
        } else {
            status = 3;
        }
    }
    unsigned response_size = status ? 0 : command == 'D' ? 13 + 4 * count : 31 + taps;
    reply_begin(seq, command, status, response_size);
    if (!status && command == 'D') {
        reply_byte(count);
        reply_word(cycles);
        reply_word(events);
        reply_word(leds);
        for (unsigned i = 0; i < count; ++i) {
            reply_word((uint32_t)outputs[i]);
        }
    } else if (!status) {
        reply_byte(2);
        reply_byte(taps);
        reply_byte(scale);
        reply_word((uint32_t)threshold);
        reply_word(samples_seen);
        reply_word(events_seen);
        reply_word(leds);
        reply_word(REG(0x0204));
        reply_word(REG(0x0308));
        reply_word(MAX_SAMPLES);
        for (unsigned i = 0; i < taps; ++i) {
            reply_byte((uint32_t)coefficients[i]);
        }
    }
    reply_end();
}

int main(void)
{
    taps = 4;
    scale = 2;
    threshold = 1000;
    for (unsigned i = 0; i < taps; ++i) {
        coefficients[i] = 1;
    }
    clear_history();
    uart_put('F');
    uart_put('I');
    uart_put('R');
    uart_put('2');
    uart_put('\n');
    unsigned used = 0;
    unsigned escaped = 0;
    unsigned damaged = 0;
    unsigned active = 0;
    unsigned chunk_bytes = 0;
    for (;;) {
        while (!(REG(0x0308) & 1)) {
        }
        unsigned value = REG(0x0304) & 255;
        /* Delimiters and each 32-byte burst return one credit to the host.
           The 64-byte RX FIFO holds the next burst while parsing continues. */
        ++chunk_bytes;
        if (value == 0x7e || chunk_bytes == RX_CHUNK) {
            uart_put(0x06);
            chunk_bytes = 0;
        }
        if (value == 0x7e) {
            if (used || damaged || escaped) {
                handle_frame(used, damaged || escaped);
            }
            used = 0;
            escaped = 0;
            damaged = 0;
            active = 1;
        } else if (!active) {
            /* Ignore line noise until the first framing delimiter. */
        } else if (value == 0x7d && !escaped) {
            escaped = 1;
        } else {
            if (escaped) {
                value ^= 0x20;
            }
            escaped = 0;
            if (used < FRAME_SIZE) {
                frame[used++] = value;
            } else {
                damaged = 1;
            }
        }
    }
}
