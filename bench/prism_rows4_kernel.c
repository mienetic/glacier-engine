// Isolated Apple-M1 production-kernel gate for Prism rows4/K16 P2/P4.
//
// Build directly so this experiment cannot be confused with runtime wiring:
//   clang -O3 -mcpu=apple-m1 -Wall -Wextra -Werror \
//     bench/prism_rows4_kernel.c src/backends/cpu/int4_neon.c \
//     src/backends/cpu/progressive_int4_neon.c -o /tmp/prism-rows4
//
// The harness first requires byte-identical output against the established
// production kernel.  P4 uses the original packed nibbles; P2 uses an
// independently materialized packed stream with coefficients {-6,-2,2,6}.
// Timings then compare both split tiers with the current full-P4 producer via
// independently balanced ABBA/BAAB blocks.

#include <inttypes.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BENCH_OUT_FEATURES 4864u
#define BENCH_IN_FEATURES 896u

void glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *, const float *, const uint8_t *, const __fp16 *,
    const float *, float *, size_t, size_t, size_t);

void glacier_prism_matvec_p2_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *, const float *, const uint8_t *, const uint8_t *,
    const __fp16 *, const float *, float *, size_t, size_t, size_t);

void glacier_prism_matvec_p4_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *, const float *, const uint8_t *, const uint8_t *,
    const uint8_t *, const __fp16 *, const float *, float *, size_t, size_t,
    size_t);

typedef struct PrismCase {
    size_t out_features;
    size_t in_features;
    size_t group_size;
    size_t activation_scale_count;
    uint8_t *packed_p4;
    uint8_t *packed_p2;
    uint8_t *coarse1;
    uint8_t *middle1;
    uint8_t *fine2;
    __fp16 *scales_rows4;
    float *bias;
    int8_t *q_input;
    float *activation_scales;
    float *legacy_output;
    float *prism_output;
} PrismCase;

typedef enum BenchMethod {
    METHOD_LEGACY,
    METHOD_P2,
    METHOD_P4,
} BenchMethod;

static uint64_t rng_state = UINT64_C(0x243f6a8885a308d3);
static uint64_t run_id;
static volatile uint64_t output_sink;
static mach_timebase_info_data_t timebase;

static uint64_t splitmix64(void)
{
    uint64_t z = (rng_state += UINT64_C(0x9e3779b97f4a7c15));
    z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
    return z ^ (z >> 31);
}

static float random_unit(void)
{
    return (float)((splitmix64() >> 40) * (1.0 / 16777216.0));
}

static void *aligned_alloc64(size_t bytes)
{
    void *result = NULL;
    if (posix_memalign(&result, 64, bytes) != 0 || result == NULL) {
        fprintf(stderr, "allocation failed for %zu bytes\n", bytes);
        exit(2);
    }
    return result;
}

static void set_packed_nibble(uint8_t *packed, size_t physical, uint8_t nibble)
{
    packed[physical >> 1] |= (uint8_t)(nibble << (4 * (physical & 1)));
}

static void set_plane_bit(uint8_t *plane, size_t physical, uint8_t bit)
{
    plane[physical >> 3] |= (uint8_t)(bit << (physical & 7));
}

static void set_plane_pair(uint8_t *plane, size_t physical, uint8_t pair)
{
    plane[physical >> 2] |= (uint8_t)(pair << (2 * (physical & 3)));
}

static void initialize_case(
    PrismCase *c,
    size_t out_features,
    size_t in_features,
    size_t group_size,
    uint64_t seed)
{
    memset(c, 0, sizeof(*c));
    c->out_features = out_features;
    c->in_features = in_features;
    c->group_size = group_size;
    c->activation_scale_count = group_size == 8
        ? (in_features + 31) / 32 : in_features / 16;
    rng_state = seed;

    const size_t weights = out_features * in_features;
    const size_t packed_bytes = weights / 2;
    const size_t one_bit_bytes = weights / 8;
    const size_t two_bit_bytes = weights / 4;
    const size_t scale_count = weights / group_size;
    c->packed_p4 = aligned_alloc64(packed_bytes);
    c->packed_p2 = aligned_alloc64(packed_bytes);
    c->coarse1 = aligned_alloc64(one_bit_bytes);
    c->middle1 = aligned_alloc64(one_bit_bytes);
    c->fine2 = aligned_alloc64(two_bit_bytes);
    c->scales_rows4 = aligned_alloc64(scale_count * sizeof(__fp16));
    c->bias = aligned_alloc64(out_features * sizeof(float));
    c->q_input = aligned_alloc64(in_features);
    c->activation_scales = aligned_alloc64(
        c->activation_scale_count * sizeof(float));
    c->legacy_output = aligned_alloc64(out_features * sizeof(float));
    c->prism_output = aligned_alloc64(out_features * sizeof(float));
    memset(c->packed_p4, 0, packed_bytes);
    memset(c->packed_p2, 0, packed_bytes);
    memset(c->coarse1, 0, one_bit_bytes);
    memset(c->middle1, 0, one_bit_bytes);
    memset(c->fine2, 0, two_bit_bytes);

    for (size_t physical = 0; physical < weights; ++physical) {
        // The deterministic term exhausts all nibbles even in the smallest
        // fixture; the random term breaks repeating vector-lane patterns.
        const uint8_t nibble = (uint8_t)(
            (physical + (splitmix64() & 15)) & 15);
        const uint8_t p2_nibble = (nibble & 12) | 1;
        set_packed_nibble(c->packed_p4, physical, nibble);
        set_packed_nibble(c->packed_p2, physical, p2_nibble);
        set_plane_bit(c->coarse1, physical, nibble >> 3);
        set_plane_bit(c->middle1, physical, (nibble >> 2) & 1);
        set_plane_pair(c->fine2, physical, nibble & 3);
    }
    for (size_t index = 0; index < scale_count; ++index) {
        c->scales_rows4[index] = (__fp16)(
            0.0005f + random_unit() * 0.0995f);
    }
    for (size_t index = 0; index < out_features; ++index) {
        c->bias[index] = (random_unit() - 0.5f) * 0.25f;
    }
    for (size_t index = 0; index < in_features; ++index) {
        const uint64_t random = splitmix64();
        c->q_input[index] = index % 31 == 0
            ? (index & 1 ? INT8_MIN : INT8_MAX)
            : (int8_t)((int)(random % 255) - 127);
    }
    for (size_t index = 0; index < c->activation_scale_count; ++index) {
        c->activation_scales[index] = 0.0005f + random_unit() * 0.1245f;
    }
}

static void destroy_case(PrismCase *c)
{
    free(c->packed_p4);
    free(c->packed_p2);
    free(c->coarse1);
    free(c->middle1);
    free(c->fine2);
    free(c->scales_rows4);
    free(c->bias);
    free(c->q_input);
    free(c->activation_scales);
    free(c->legacy_output);
    free(c->prism_output);
}

static void run_legacy(PrismCase *c, const uint8_t *packed, const float *bias)
{
    glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
        c->q_input, c->activation_scales, packed, c->scales_rows4, bias,
        c->legacy_output, c->out_features, c->in_features, c->group_size);
}

static void run_p2(PrismCase *c, const float *bias)
{
    glacier_prism_matvec_p2_neon_q8_prequant_f16scale_rows4_k16(
        c->q_input, c->activation_scales, c->coarse1, c->middle1,
        c->scales_rows4, bias, c->prism_output, c->out_features,
        c->in_features, c->group_size);
}

static void run_p4(PrismCase *c, const float *bias)
{
    glacier_prism_matvec_p4_neon_q8_prequant_f16scale_rows4_k16(
        c->q_input, c->activation_scales, c->coarse1, c->middle1, c->fine2,
        c->scales_rows4, bias, c->prism_output, c->out_features,
        c->in_features, c->group_size);
}

static int require_equal(
    const PrismCase *c,
    const char *tier,
    const char *bias_mode)
{
    if (memcmp(
            c->legacy_output,
            c->prism_output,
            c->out_features * sizeof(float)) == 0) {
        return 1;
    }
    for (size_t index = 0; index < c->out_features; ++index) {
        uint32_t expected;
        uint32_t actual;
        memcpy(&expected, c->legacy_output + index, sizeof(expected));
        memcpy(&actual, c->prism_output + index, sizeof(actual));
        if (expected != actual) {
            fprintf(
                stderr,
                "VERIFY_FAIL,%s,%s,out=%zu,in=%zu,g=%zu,index=%zu,%08x,%08x,"
                "run_id=%" PRIu64 "\n",
                tier, bias_mode, c->out_features, c->in_features,
                c->group_size, index, expected, actual, run_id);
            return 0;
        }
    }
    return 0;
}

static int verify_case(PrismCase *c, const char *when)
{
    const float *biases[2] = { c->bias, NULL };
    const char *bias_names[2] = { "bias", "no_bias" };
    for (size_t mode = 0; mode < 2; ++mode) {
        run_legacy(c, c->packed_p4, biases[mode]);
        run_p4(c, biases[mode]);
        if (!require_equal(c, "p4", bias_names[mode])) return 0;
        run_legacy(c, c->packed_p2, biases[mode]);
        run_p2(c, biases[mode]);
        if (!require_equal(c, "p2", bias_names[mode])) return 0;
    }
    fprintf(
        stderr,
        "VERIFY_PASS,%s,out=%zu,in=%zu,g=%zu,p2+p4,bit_exact,run_id=%" PRIu64
        "\n",
        when, c->out_features, c->in_features, c->group_size, run_id);
    return 1;
}

static int verify_geometry_matrix(void)
{
    static const size_t geometries[][2] = {
        { 4, 16 }, { 12, 64 }, { 20, 80 }, { 36, 896 },
    };
    for (size_t geometry = 0;
         geometry < sizeof(geometries) / sizeof(geometries[0]);
         ++geometry) {
        for (size_t group_size = 8; group_size <= 16; group_size *= 2) {
            PrismCase c;
            initialize_case(
                &c, geometries[geometry][0], geometries[geometry][1],
                group_size,
                UINT64_C(0x13198a2e03707344) ^ (geometry << 8) ^ group_size);
            const int valid = verify_case(&c, "matrix");
            destroy_case(&c);
            if (!valid) return 0;
        }
    }
    return 1;
}

static uint64_t ticks_now(void)
{
    __asm__ volatile("" ::: "memory");
    const uint64_t ticks = mach_continuous_time();
    __asm__ volatile("" ::: "memory");
    return ticks;
}

static double ticks_to_ns(uint64_t ticks)
{
    return (double)ticks * (double)timebase.numer / (double)timebase.denom;
}

static void run_method(PrismCase *c, BenchMethod method)
{
    switch (method) {
    case METHOD_LEGACY:
        run_legacy(c, c->packed_p4, c->bias);
        break;
    case METHOD_P2:
        run_p2(c, c->bias);
        break;
    case METHOD_P4:
        run_p4(c, c->bias);
        break;
    }
}

static double measure(
    PrismCase *c,
    BenchMethod method,
    size_t inner_iterations)
{
    const uint64_t start = ticks_now();
    for (size_t iteration = 0; iteration < inner_iterations; ++iteration) {
        run_method(c, method);
    }
    const uint64_t end = ticks_now();
    const float *sample = method == METHOD_LEGACY
        ? c->legacy_output : c->prism_output;
    uint32_t bits;
    memcpy(&bits, sample + (splitmix64() % c->out_features), sizeof(bits));
    output_sink ^= bits;
    return ticks_to_ns(end - start) / (double)inner_iterations;
}

static int benchmark_gate(
    FILE *raw,
    PrismCase *c,
    const char *gate,
    BenchMethod prism_method,
    size_t blocks,
    size_t inner_iterations)
{
    for (size_t warmup = 0; warmup < 12; ++warmup) {
        run_method(c, warmup & 1 ? prism_method : METHOD_LEGACY);
    }
    for (size_t block = 0; block < blocks; ++block) {
        const int abba = (block + c->group_size / 8) & 1;
        const char *pattern = abba ? "ABBA" : "BAAB";
        const BenchMethod methods[4] = {
            abba ? METHOD_LEGACY : prism_method,
            abba ? prism_method : METHOD_LEGACY,
            abba ? prism_method : METHOD_LEGACY,
            abba ? METHOD_LEGACY : prism_method,
        };
        for (size_t position = 0; position < 4; ++position) {
            const double ns = measure(c, methods[position], inner_iterations);
            const char method = methods[position] == METHOD_LEGACY ? 'A' : 'B';
            if (fprintf(
                    raw,
                    "%" PRIu64 ",%s,%zu,%zu,%s,%zu,%c,%.3f\n",
                    run_id, gate, c->group_size, block, pattern, position,
                    method, ns) < 0) {
                return 0;
            }
        }
    }
    return fflush(raw) == 0;
}

static size_t parse_positive(const char *text, const char *name)
{
    char *end = NULL;
    const unsigned long long parsed = strtoull(text, &end, 10);
    if (end == text || *end != '\0' || parsed == 0 || parsed > SIZE_MAX) {
        fprintf(stderr, "invalid %s: %s\n", name, text);
        exit(2);
    }
    return (size_t)parsed;
}

int main(int argc, char **argv)
{
    const size_t blocks = argc > 1 ? parse_positive(argv[1], "blocks") : 256;
    const size_t inner_iterations = argc > 2
        ? parse_positive(argv[2], "inner iterations") : 3;
    const char *raw_path = argc > 3 ? argv[3] : "/tmp/prism-rows4-raw.csv";
    if ((blocks & 1) != 0 || argc > 4) {
        fprintf(stderr, "usage: %s [even-blocks] [inner] [raw.csv]\n", argv[0]);
        return 2;
    }
    mach_timebase_info(&timebase);
    run_id = mach_continuous_time() ^ ((uint64_t)getpid() << 32);
    if (pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) != 0) {
        fprintf(stderr, "warning: failed to set user-interactive QoS\n");
    }
    if (!verify_geometry_matrix()) return 1;

    FILE *raw = fopen(raw_path, "w");
    if (raw == NULL) {
        perror(raw_path);
        return 2;
    }
    fprintf(raw, "run_id,gate,group_size,block,pattern,position,method,ns\n");
    for (size_t group_size = 8; group_size <= 16; group_size *= 2) {
        PrismCase c;
        initialize_case(
            &c, BENCH_OUT_FEATURES, BENCH_IN_FEATURES, group_size,
            UINT64_C(0xa4093822299f31d0) ^ group_size);
        if (!verify_case(&c, "before") ||
            !benchmark_gate(
                raw, &c, "p2", METHOD_P2, blocks, inner_iterations) ||
            !benchmark_gate(
                raw, &c, "p4", METHOD_P4, blocks, inner_iterations) ||
            !verify_case(&c, "after")) {
            destroy_case(&c);
            fclose(raw);
            return 1;
        }
        destroy_case(&c);
    }
    if (fclose(raw) != 0) return 2;
    fprintf(
        stderr,
        "BENCH_DONE,blocks=%zu,inner=%zu,weights=%u,"
        "p2_bytes_per_weight=0.25,p4_bytes_per_weight=0.5,sink=%" PRIu64
        ",run_id=%" PRIu64 "\n",
        blocks, inner_iterations, BENCH_OUT_FEATURES * BENCH_IN_FEATURES,
        output_sink, run_id);
    return 0;
}
