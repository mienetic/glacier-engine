#include <arm_neon.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OUT_FEATURES 4864u
#define IN_FEATURES 896u

void glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *, const float *, const uint8_t *, const __fp16 *,
    const float *, float *, size_t, size_t, size_t);

void glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
    const int8_t *, const float *, const uint8_t *, const __fp16 *,
    const float *, float *, size_t, size_t, size_t, size_t, size_t);

void glacier_pair_nibble_matvec_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *, const float *, const uint8_t *, const __fp16 *,
    const float *, const float *, float *, float *, size_t, size_t, size_t);

void glacier_pair_nibble_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
    const int8_t *, const float *, const uint8_t *, const __fp16 *,
    const float *, const float *, float *, float *, size_t, size_t, size_t,
    size_t, size_t);

typedef struct BenchCase {
    size_t group_size;
    size_t batch;
    size_t activation_scale_stride;
    uint8_t *gate_packed;
    uint8_t *up_packed;
    uint8_t *paired;
    __fp16 *gate_scales;
    __fp16 *up_scales;
    __fp16 *paired_scales;
    float *gate_bias;
    float *up_bias;
    int8_t *q_inputs;
    float *activation_scales;
    float *canonical_gate;
    float *canonical_up;
    float *pair_gate;
    float *pair_up;
} BenchCase;

static uint64_t rng_state;
static volatile uint64_t output_sink;
static mach_timebase_info_data_t timebase;
static FILE *verification_log;
static uint64_t benchmark_run_id;

static void verification_printf(const char *format, ...)
{
    va_list stderr_args;
    va_list log_args;
    va_start(stderr_args, format);
    va_copy(log_args, stderr_args);
    vfprintf(stderr, format, stderr_args);
    vfprintf(verification_log, format, log_args);
    va_end(log_args);
    va_end(stderr_args);
    fflush(verification_log);
}

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

static void build_case(BenchCase *c, size_t group_size, size_t batch)
{
    memset(c, 0, sizeof(*c));
    c->group_size = group_size;
    c->batch = batch;
    c->activation_scale_stride = group_size == 8
        ? IN_FEATURES / 32 : IN_FEATURES / 16;

    const size_t coefficients = OUT_FEATURES * IN_FEATURES;
    const size_t packed_bytes = coefficients / 2;
    const size_t groups = IN_FEATURES / group_size;
    const size_t branch_scale_count = OUT_FEATURES * groups;
    const size_t pair_scale_count = branch_scale_count * 2;
    const size_t output_count = batch * OUT_FEATURES;

    c->gate_packed = aligned_alloc64(packed_bytes);
    c->up_packed = aligned_alloc64(packed_bytes);
    c->paired = aligned_alloc64(coefficients);
    c->gate_scales = aligned_alloc64(branch_scale_count * sizeof(__fp16));
    c->up_scales = aligned_alloc64(branch_scale_count * sizeof(__fp16));
    c->paired_scales = aligned_alloc64(pair_scale_count * sizeof(__fp16));
    c->gate_bias = aligned_alloc64(OUT_FEATURES * sizeof(float));
    c->up_bias = aligned_alloc64(OUT_FEATURES * sizeof(float));
    c->q_inputs = aligned_alloc64(batch * IN_FEATURES * sizeof(int8_t));
    c->activation_scales = aligned_alloc64(
        batch * c->activation_scale_stride * sizeof(float));
    c->canonical_gate = aligned_alloc64(output_count * sizeof(float));
    c->canonical_up = aligned_alloc64(output_count * sizeof(float));
    c->pair_gate = aligned_alloc64(output_count * sizeof(float));
    c->pair_up = aligned_alloc64(output_count * sizeof(float));

    memset(c->gate_packed, 0, packed_bytes);
    memset(c->up_packed, 0, packed_bytes);
    for (size_t i = 0; i < coefficients; ++i) {
        const uint8_t gate = (uint8_t)(splitmix64() & 0x0f);
        const uint8_t up = (uint8_t)(splitmix64() & 0x0f);
        c->paired[i] = (uint8_t)(gate | (up << 4));
        c->gate_packed[i >> 1] |= (uint8_t)(gate << (4 * (i & 1)));
        c->up_packed[i >> 1] |= (uint8_t)(up << (4 * (i & 1)));
    }

    // Separate scale streams are [tile][group][lane]. Pair scales are
    // [tile][group][branch][lane], preserving the exact half bit patterns.
    for (size_t tile = 0; tile < OUT_FEATURES / 4; ++tile) {
        for (size_t group = 0; group < groups; ++group) {
            for (size_t lane = 0; lane < 4; ++lane) {
                const size_t separate_index =
                    (tile * groups + group) * 4 + lane;
                const size_t pair_base =
                    (tile * groups + group) * 8 + lane;
                const __fp16 gate_scale = (__fp16)(
                    0.001f + random_unit() * 0.079f);
                const __fp16 up_scale = (__fp16)(
                    0.001f + random_unit() * 0.079f);
                c->gate_scales[separate_index] = gate_scale;
                c->up_scales[separate_index] = up_scale;
                c->paired_scales[pair_base] = gate_scale;
                c->paired_scales[pair_base + 4] = up_scale;
            }
        }
    }

    for (size_t row = 0; row < OUT_FEATURES; ++row) {
        c->gate_bias[row] = (random_unit() - 0.5f) * 0.1f;
        c->up_bias[row] = (random_unit() - 0.5f) * 0.1f;
    }
    // Generate each token's Q8 values and activation scales together. This
    // makes token zero byte-identical between the M1 and M4 configurations,
    // rather than merely sharing weights, branch scales, and biases.
    for (size_t token = 0; token < batch; ++token) {
        for (size_t col = 0; col < IN_FEATURES; ++col) {
            c->q_inputs[token * IN_FEATURES + col] =
                (int8_t)((int)(splitmix64() % 255) - 127);
        }
        for (size_t group = 0; group < c->activation_scale_stride; ++group) {
            c->activation_scales[token * c->activation_scale_stride + group] =
                0.001f + random_unit() * 0.099f;
        }
    }
    memset(c->canonical_gate, 0, output_count * sizeof(float));
    memset(c->canonical_up, 0, output_count * sizeof(float));
    memset(c->pair_gate, 0, output_count * sizeof(float));
    memset(c->pair_up, 0, output_count * sizeof(float));
}

static void destroy_case(BenchCase *c)
{
    free(c->gate_packed);
    free(c->up_packed);
    free(c->paired);
    free(c->gate_scales);
    free(c->up_scales);
    free(c->paired_scales);
    free(c->gate_bias);
    free(c->up_bias);
    free(c->q_inputs);
    free(c->activation_scales);
    free(c->canonical_gate);
    free(c->canonical_up);
    free(c->pair_gate);
    free(c->pair_up);
}

static void run_canonical(BenchCase *c)
{
    if (c->batch == 1) {
        glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
            c->q_inputs, c->activation_scales, c->gate_packed,
            c->gate_scales, c->gate_bias, c->canonical_gate,
            OUT_FEATURES, IN_FEATURES, c->group_size);
        glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
            c->q_inputs, c->activation_scales, c->up_packed,
            c->up_scales, c->up_bias, c->canonical_up,
            OUT_FEATURES, IN_FEATURES, c->group_size);
    } else {
        glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
            c->q_inputs, c->activation_scales, c->gate_packed,
            c->gate_scales, c->gate_bias, c->canonical_gate,
            c->batch, OUT_FEATURES, IN_FEATURES, c->group_size, OUT_FEATURES);
        glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
            c->q_inputs, c->activation_scales, c->up_packed,
            c->up_scales, c->up_bias, c->canonical_up,
            c->batch, OUT_FEATURES, IN_FEATURES, c->group_size, OUT_FEATURES);
    }
}

static void run_pair(BenchCase *c)
{
    if (c->batch == 1) {
        glacier_pair_nibble_matvec_neon_q8_prequant_f16scale_rows4_k16(
            c->q_inputs, c->activation_scales, c->paired, c->paired_scales,
            c->gate_bias, c->up_bias, c->pair_gate, c->pair_up,
            OUT_FEATURES, IN_FEATURES, c->group_size);
    } else {
        glacier_pair_nibble_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
            c->q_inputs, c->activation_scales, c->paired, c->paired_scales,
            c->gate_bias, c->up_bias, c->pair_gate, c->pair_up,
            c->batch, OUT_FEATURES, IN_FEATURES, c->group_size, OUT_FEATURES);
    }
}

static int verify_case(BenchCase *c, const char *when)
{
    run_canonical(c);
    run_pair(c);
    const size_t count = c->batch * OUT_FEATURES;
    const float *expected[2] = { c->canonical_gate, c->canonical_up };
    const float *actual[2] = { c->pair_gate, c->pair_up };
    const char *branch[2] = { "gate", "up" };
    for (size_t b = 0; b < 2; ++b) {
        if (memcmp(expected[b], actual[b], count * sizeof(float)) != 0) {
            for (size_t i = 0; i < count; ++i) {
                uint32_t expected_bits, actual_bits;
                memcpy(&expected_bits, expected[b] + i, sizeof(expected_bits));
                memcpy(&actual_bits, actual[b] + i, sizeof(actual_bits));
                if (expected_bits != actual_bits) {
                    verification_printf(
                        "VERIFY_FAIL,%s,g%zu,b%zu,%s,index=%zu,%08x,%08x,"
                        "run_id=%" PRIu64 "\n",
                        when, c->group_size, c->batch, branch[b], i,
                        expected_bits, actual_bits, benchmark_run_id);
                    return 0;
                }
            }
        }
    }
    verification_printf(
        "VERIFY_PASS,%s,g%zu,b%zu,bit_exact,run_id=%" PRIu64 "\n",
        when, c->group_size, c->batch, benchmark_run_id);
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

static double measure(BenchCase *c, char method, size_t inner_iterations)
{
    const uint64_t start = ticks_now();
    for (size_t i = 0; i < inner_iterations; ++i) {
        if (method == 'A') run_canonical(c);
        else run_pair(c);
    }
    const uint64_t end = ticks_now();
    const float *sample = method == 'A' ? c->canonical_gate : c->pair_gate;
    uint32_t bits;
    memcpy(&bits, sample + (splitmix64() % (c->batch * OUT_FEATURES)), 4);
    output_sink ^= bits;
    return ticks_to_ns(end - start) / (double)inner_iterations;
}

static void shuffle_patterns(uint8_t *patterns, size_t blocks)
{
    for (size_t i = 0; i < blocks; ++i) patterns[i] = i >= blocks / 2;
    for (size_t i = blocks; i > 1; --i) {
        const size_t j = splitmix64() % i;
        const uint8_t temporary = patterns[i - 1];
        patterns[i - 1] = patterns[j];
        patterns[j] = temporary;
    }
}

static int benchmark_case(
    FILE *raw,
    size_t group_size,
    size_t batch,
    size_t blocks,
    size_t inner_iterations)
{
    BenchCase c;
    // Batch 1 and 4 use identical weights, scales, biases, and first-token
    // activations within each group-size configuration.
    rng_state = UINT64_C(0x6a09e667f3bcc909) ^ (group_size << 16);
    build_case(&c, group_size, batch);
    if (!verify_case(&c, "before")) return 0;

    for (size_t warmup = 0; warmup < 10; ++warmup) {
        if (warmup & 1) {
            run_pair(&c);
            run_canonical(&c);
        } else {
            run_canonical(&c);
            run_pair(&c);
        }
    }

    uint8_t *patterns = aligned_alloc64(blocks);
    rng_state = UINT64_C(0xbb67ae8584caa73b) ^
        (group_size << 24) ^ (batch << 8) ^ blocks;
    shuffle_patterns(patterns, blocks);
    const char *sequences[2] = { "ABBA", "BAAB" };
    for (size_t block = 0; block < blocks; ++block) {
        const char *sequence = sequences[patterns[block]];
        for (size_t position = 0; position < 4; ++position) {
            const char method = sequence[position];
            const double ns = measure(&c, method, inner_iterations);
            fprintf(raw, "%" PRIu64 ",%zu,%zu,%zu,%s,%zu,%c,%.3f\n",
                benchmark_run_id, group_size, batch, block, sequence,
                position, method, ns);
        }
    }
    fflush(raw);
    free(patterns);

    const int valid = verify_case(&c, "after");
    destroy_case(&c);
    return valid;
}

int main(int argc, char **argv)
{
    if (argc != 6) {
        fprintf(stderr,
            "usage: %s RAW_CSV VERIFY_LOG BLOCKS INNER_M1 INNER_M4\n",
            argv[0]);
        return 2;
    }
    const size_t blocks = strtoull(argv[3], NULL, 10);
    const size_t inner_m1 = strtoull(argv[4], NULL, 10);
    const size_t inner_m4 = strtoull(argv[5], NULL, 10);
    if (blocks < 2 || (blocks & 1) || inner_m1 == 0 || inner_m4 == 0) {
        fprintf(stderr, "blocks must be positive/even; inner counts nonzero\n");
        return 2;
    }

    mach_timebase_info(&timebase);
    benchmark_run_id = mach_continuous_time();
    if (benchmark_run_id == 0) benchmark_run_id = 1;
    const int qos_status =
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    if (qos_status != 0) {
        fprintf(stderr, "QOS_FAIL,status=%d\n", qos_status);
        return 2;
    }
    verification_log = fopen(argv[2], "w");
    if (verification_log == NULL) {
        perror("fopen verification log");
        return 2;
    }
    FILE *raw = fopen(argv[1], "w");
    if (raw == NULL) {
        perror("fopen raw CSV");
        fclose(verification_log);
        return 2;
    }
    fprintf(raw,
        "run_id,group_size,batch,block,pattern,position,method,"
        "ns_per_producer\n");

    const size_t groups[2] = { 8, 16 };
    const size_t batches[2] = { 1, 4 };
    int valid = 1;
    for (size_t gi = 0; gi < 2; ++gi) {
        for (size_t bi = 0; bi < 2; ++bi) {
            const size_t inner = batches[bi] == 1 ? inner_m1 : inner_m4;
            valid &= benchmark_case(
                raw, groups[gi], batches[bi], blocks, inner);
        }
    }
    fclose(raw);
    verification_printf(
        "BENCH_DONE,blocks=%zu,inner_m1=%zu,inner_m4=%zu,"
        "qos=user_interactive,sink=%" PRIu64 ",run_id=%" PRIu64 "\n",
        blocks, inner_m1, inner_m4, output_sink, benchmark_run_id);
    fclose(verification_log);
    verification_log = NULL;
    return valid ? 0 : 1;
}
