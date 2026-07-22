#include <stddef.h>
#include <stdint.h>
#include <string.h>

#if defined(__aarch64__)
#include <arm_acle.h>
#endif

// IEEE CRC-32, matching std.hash.Crc32. Apple Silicon implements the IEEE
// polynomial directly in the ARMv8 CRC extension; consume 64 bytes per loop
// so page verification does not become the model-loader bottleneck.
uint32_t glacier_crc32_ieee_arm_extend(uint32_t previous, const uint8_t *data, size_t len)
{
    uint32_t crc = ~previous;

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32)
    while (len != 0 && ((uintptr_t)data & 7u) != 0) {
        crc = __crc32b(crc, *data++);
        --len;
    }
    while (len >= 64) {
        uint64_t words[8];
        memcpy(words, data, sizeof(words));
        crc = __crc32d(crc, words[0]);
        crc = __crc32d(crc, words[1]);
        crc = __crc32d(crc, words[2]);
        crc = __crc32d(crc, words[3]);
        crc = __crc32d(crc, words[4]);
        crc = __crc32d(crc, words[5]);
        crc = __crc32d(crc, words[6]);
        crc = __crc32d(crc, words[7]);
        data += sizeof(words);
        len -= sizeof(words);
    }
    while (len >= 8) {
        uint64_t word;
        memcpy(&word, data, sizeof(word));
        crc = __crc32d(crc, word);
        data += sizeof(word);
        len -= sizeof(word);
    }
    if (len >= 4) {
        uint32_t word;
        memcpy(&word, data, sizeof(word));
        crc = __crc32w(crc, word);
        data += sizeof(word);
        len -= sizeof(word);
    }
    if (len >= 2) {
        uint16_t half;
        memcpy(&half, data, sizeof(half));
        crc = __crc32h(crc, half);
        data += sizeof(half);
        len -= sizeof(half);
    }
    if (len != 0) crc = __crc32b(crc, *data);
    return ~crc;
#else
    // The object is also built for generic AArch64 targets. Keep a correct
    // fallback there; Zig selects this symbol only on AArch64 and the native
    // Apple build enables the hardware branch above.
    while (len-- != 0) {
        crc ^= *data++;
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)-(int32_t)(crc & 1u));
    }
    return ~crc;
#endif
}

uint32_t glacier_crc32_ieee_arm(const uint8_t *data, size_t len)
{
    return glacier_crc32_ieee_arm_extend(0, data, len);
}
