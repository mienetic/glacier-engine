// Successor experiment for Prism: two independently addressable 2-bit ranges.
//
// `prefix2` stores (b3:b2) and `residual2` stores (b1:b0), both as four
// little-lane 2-bit codes per byte over the established rows4/K16 physical
// order. P2 has no residual pointer. P4 reconstructs prefix+residual in signed
// integer space before SDOT. This file is deliberately benchmark-only.

#include <arm_neon.h>

#define main prism_rows4_1x1x2_harness_main
#include "prism_rows4_kernel.c"
#undef main

typedef struct Prism2x2Vectors {
    int8x16_t w0;
    int8x16_t w1;
    int8x16_t w2;
    int8x16_t w3;
} Prism2x2Vectors;

static const int8_t prism_2x2_p2_first[16] = {
    -6, -2, 2, 6, -6, -2, 2, 6,
    -6, -2, 2, 6, -6, -2, 2, 6,
};

static const int8_t prism_2x2_p2_second[16] = {
    -6, -6, -6, -6, -2, -2, -2, -2,
    2, 2, 2, 2, 6, 6, 6, 6,
};

static const int8_t prism_2x2_fine_first[16] = {
    -1, 0, 1, 2, -1, 0, 1, 2,
    -1, 0, 1, 2, -1, 0, 1, 2,
};

static const int8_t prism_2x2_fine_second[16] = {
    -1, -1, -1, -1, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
};

static inline Prism2x2Vectors prism_2x2_expand(
    const uint8_t *packed2,
    const int8_t *first_table,
    const int8_t *second_table)
{
    const uint8x16_t packed = vld1q_u8(packed2);
    const uint8x16_t low = vandq_u8(packed, vdupq_n_u8(15));
    const uint8x16_t high = vshrq_n_u8(packed, 4);
    const int8x16_t first = vld1q_s8(first_table);
    const int8x16_t second = vld1q_s8(second_table);
    const int8x16_t low_first = vqtbl1q_s8(first, low);
    const int8x16_t low_second = vqtbl1q_s8(second, low);
    const int8x16_t high_first = vqtbl1q_s8(first, high);
    const int8x16_t high_second = vqtbl1q_s8(second, high);
    const int8x16_t low_pairs0 = vzip1q_s8(low_first, low_second);
    const int8x16_t low_pairs1 = vzip2q_s8(low_first, low_second);
    const int8x16_t high_pairs0 = vzip1q_s8(high_first, high_second);
    const int8x16_t high_pairs1 = vzip2q_s8(high_first, high_second);
    return (Prism2x2Vectors){
        .w0 = vreinterpretq_s8_u16(vzip1q_u16(
            vreinterpretq_u16_s8(low_pairs0),
            vreinterpretq_u16_s8(high_pairs0))),
        .w1 = vreinterpretq_s8_u16(vzip2q_u16(
            vreinterpretq_u16_s8(low_pairs0),
            vreinterpretq_u16_s8(high_pairs0))),
        .w2 = vreinterpretq_s8_u16(vzip1q_u16(
            vreinterpretq_u16_s8(low_pairs1),
            vreinterpretq_u16_s8(high_pairs1))),
        .w3 = vreinterpretq_s8_u16(vzip2q_u16(
            vreinterpretq_u16_s8(low_pairs1),
            vreinterpretq_u16_s8(high_pairs1))),
    };
}

static inline Prism2x2Vectors prism_2x2_decode_p2(const uint8_t *prefix2)
{
    return prism_2x2_expand(
        prefix2, prism_2x2_p2_first, prism_2x2_p2_second);
}

static inline Prism2x2Vectors prism_2x2_decode_p4(
    const uint8_t *prefix2,
    const uint8_t *residual2)
{
    const Prism2x2Vectors prefix = prism_2x2_decode_p2(prefix2);
    const Prism2x2Vectors residual = prism_2x2_expand(
        residual2, prism_2x2_fine_first, prism_2x2_fine_second);
    return (Prism2x2Vectors){
        .w0 = vaddq_s8(prefix.w0, residual.w0),
        .w1 = vaddq_s8(prefix.w1, residual.w1),
        .w2 = vaddq_s8(prefix.w2, residual.w2),
        .w3 = vaddq_s8(prefix.w3, residual.w3),
    };
}

static inline float32x4_t prism_2x2_accumulate_g8(
    float32x4_t acc,
    int8x16_t q_act,
    Prism2x2Vectors weights,
    const __fp16 *scales,
    float activation_scale0,
    float activation_scale1)
{
    int32x4_t dots0 = vdotq_laneq_s32(
        vdupq_n_s32(0), weights.w0, q_act, 0);
    dots0 = vdotq_laneq_s32(dots0, weights.w1, q_act, 1);
    int32x4_t dots1 = vdotq_laneq_s32(
        vdupq_n_s32(0), weights.w2, q_act, 2);
    dots1 = vdotq_laneq_s32(dots1, weights.w3, q_act, 3);
    const float16x8_t scale_pair = vld1q_f16(scales);
    acc = vfmaq_n_f32(
        acc,
        vmulq_f32(
            vcvtq_f32_s32(dots0),
            vcvt_f32_f16(vget_low_f16(scale_pair))),
        activation_scale0);
    return vfmaq_n_f32(
        acc,
        vmulq_f32(
            vcvtq_f32_s32(dots1), vcvt_high_f32_f16(scale_pair)),
        activation_scale1);
}

static inline float32x4_t prism_2x2_accumulate_g16(
    float32x4_t acc,
    int8x16_t q_act,
    Prism2x2Vectors weights,
    const __fp16 *scales,
    float activation_scale)
{
    int32x4_t dots = vdotq_laneq_s32(
        vdupq_n_s32(0), weights.w0, q_act, 0);
    dots = vdotq_laneq_s32(dots, weights.w1, q_act, 1);
    dots = vdotq_laneq_s32(dots, weights.w2, q_act, 2);
    dots = vdotq_laneq_s32(dots, weights.w3, q_act, 3);
    return vfmaq_n_f32(
        acc,
        vmulq_f32(
            vcvtq_f32_s32(dots), vcvt_f32_f16(vld1_f16(scales))),
        activation_scale);
}

#define PRISM_2X2_STEP_P2_G8(ACC, COLUMN)                                      \
    (ACC) = prism_2x2_accumulate_g8(                                           \
        (ACC), vld1q_s8(q_input + (COLUMN)),                                  \
        prism_2x2_decode_p2(prefix_tile + (COLUMN)),                           \
        tile_scales + ((COLUMN) / 8) * 4,                                     \
        activation_scales[(COLUMN) / 32],                                     \
        activation_scales[((COLUMN) + 8) / 32])

#define PRISM_2X2_STEP_P2_G16(ACC, COLUMN)                                     \
    (ACC) = prism_2x2_accumulate_g16(                                          \
        (ACC), vld1q_s8(q_input + (COLUMN)),                                  \
        prism_2x2_decode_p2(prefix_tile + (COLUMN)),                           \
        tile_scales + ((COLUMN) / 16) * 4,                                    \
        activation_scales[(COLUMN) / 16])

#define PRISM_2X2_STEP_P4_G8(ACC, COLUMN)                                      \
    (ACC) = prism_2x2_accumulate_g8(                                           \
        (ACC), vld1q_s8(q_input + (COLUMN)),                                  \
        prism_2x2_decode_p4(                                                   \
            prefix_tile + (COLUMN), residual_tile + (COLUMN)),                \
        tile_scales + ((COLUMN) / 8) * 4,                                     \
        activation_scales[(COLUMN) / 32],                                     \
        activation_scales[((COLUMN) + 8) / 32])

#define PRISM_2X2_STEP_P4_G16(ACC, COLUMN)                                     \
    (ACC) = prism_2x2_accumulate_g16(                                          \
        (ACC), vld1q_s8(q_input + (COLUMN)),                                  \
        prism_2x2_decode_p4(                                                   \
            prefix_tile + (COLUMN), residual_tile + (COLUMN)),                \
        tile_scales + ((COLUMN) / 16) * 4,                                    \
        activation_scales[(COLUMN) / 16])

#define PRISM_2X2_TILE_LOOP(TIER, GROUP)                                       \
    for (size_t tile = 0; tile < out_features / 4; ++tile) {                   \
        const size_t row0 = tile * 4;                                          \
        float32x4_t acc0 = bias ? vld1q_f32(bias + row0)                       \
                                 : vdupq_n_f32(0.0f);                          \
        float32x4_t acc1 = vdupq_n_f32(0.0f);                                  \
        float32x4_t acc2 = vdupq_n_f32(0.0f);                                  \
        float32x4_t acc3 = vdupq_n_f32(0.0f);                                  \
        const uint8_t *prefix_tile = prefix2 + tile * in_features;             \
        PRISM_2X2_RESIDUAL_TILE_##TIER                                         \
        const __fp16 *tile_scales = scales_rows4 +                             \
            tile * scales_per_row * 4;                                         \
        size_t col = 0;                                                        \
        for (; col + 63 < in_features; col += 64) {                            \
            PRISM_2X2_STEP_##TIER##_##GROUP(acc0, col);                        \
            PRISM_2X2_STEP_##TIER##_##GROUP(acc1, col + 16);                   \
            PRISM_2X2_STEP_##TIER##_##GROUP(acc2, col + 32);                   \
            PRISM_2X2_STEP_##TIER##_##GROUP(acc3, col + 48);                   \
        }                                                                      \
        for (; col < in_features; col += 16) {                                 \
            PRISM_2X2_STEP_##TIER##_##GROUP(acc0, col);                        \
        }                                                                      \
        vst1q_f32(output + row0, vaddq_f32(                                    \
            vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3)));                    \
    }

#define PRISM_2X2_RESIDUAL_TILE_P2
#define PRISM_2X2_RESIDUAL_TILE_P4                                             \
    const uint8_t *residual_tile = residual2 + tile * in_features;

void glacier_prism_2x2_matvec_p2_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *prefix2,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t scales_per_row = in_features / group_size;
    if (group_size == 8) {
        PRISM_2X2_TILE_LOOP(P2, G8)
    } else {
        PRISM_2X2_TILE_LOOP(P2, G16)
    }
}

void glacier_prism_2x2_matvec_p4_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *prefix2,
    const uint8_t *residual2,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t scales_per_row = in_features / group_size;
    if (group_size == 8) {
        PRISM_2X2_TILE_LOOP(P4, G8)
    } else {
        PRISM_2X2_TILE_LOOP(P4, G16)
    }
}

// Alternative P2 execution architecture: build one 256-entry signed-dot LUT
// for every activation K4, then use the four row-local prefix bytes as scalar
// indices. The 114 KiB LUT is activation-owned and shared by all output tiles;
// its preparation cost is reported separately from the producer timing.
static void prism_2x2_prepare_p2_lut(
    const int8_t *q_input,
    size_t in_features,
    int16_t *lut)
{
    for (size_t chunk = 0; chunk < in_features / 4; ++chunk) {
        const int8_t *q = q_input + chunk * 4;
        int16_t *table = lut + chunk * 256;
        for (size_t code_byte = 0; code_byte < 256; ++code_byte) {
            int32_t dot = 0;
            for (size_t lane = 0; lane < 4; ++lane) {
                const int32_t code = (code_byte >> (lane * 2)) & 3;
                dot += (int32_t)q[lane] * (4 * code - 6);
            }
            table[code_byte] = (int16_t)dot;
        }
    }
}

static inline int32x4_t prism_2x2_lookup_rows4(
    const int16_t *table,
    const uint8_t *codes)
{
    uint32_t packed;
    memcpy(&packed, codes, sizeof(packed));
    int32x4_t result = vdupq_n_s32(0);
    result = vsetq_lane_s32(table[packed & 255], result, 0);
    result = vsetq_lane_s32(table[(packed >> 8) & 255], result, 1);
    result = vsetq_lane_s32(table[(packed >> 16) & 255], result, 2);
    return vsetq_lane_s32(table[packed >> 24], result, 3);
}

static inline float32x4_t prism_2x2_lut_accumulate_g8(
    float32x4_t acc,
    const uint8_t *prefix_block,
    const int16_t *lut,
    const __fp16 *scales,
    float activation_scale0,
    float activation_scale1)
{
    const int32x4_t dots0 = vaddq_s32(
        prism_2x2_lookup_rows4(lut, prefix_block),
        prism_2x2_lookup_rows4(lut + 256, prefix_block + 4));
    const int32x4_t dots1 = vaddq_s32(
        prism_2x2_lookup_rows4(lut + 512, prefix_block + 8),
        prism_2x2_lookup_rows4(lut + 768, prefix_block + 12));
    const float16x8_t scale_pair = vld1q_f16(scales);
    acc = vfmaq_n_f32(
        acc,
        vmulq_f32(
            vcvtq_f32_s32(dots0),
            vcvt_f32_f16(vget_low_f16(scale_pair))),
        activation_scale0);
    return vfmaq_n_f32(
        acc,
        vmulq_f32(
            vcvtq_f32_s32(dots1), vcvt_high_f32_f16(scale_pair)),
        activation_scale1);
}

static inline float32x4_t prism_2x2_lut_accumulate_g16(
    float32x4_t acc,
    const uint8_t *prefix_block,
    const int16_t *lut,
    const __fp16 *scales,
    float activation_scale)
{
    const int32x4_t dots01 = vaddq_s32(
        prism_2x2_lookup_rows4(lut, prefix_block),
        prism_2x2_lookup_rows4(lut + 256, prefix_block + 4));
    const int32x4_t dots23 = vaddq_s32(
        prism_2x2_lookup_rows4(lut + 512, prefix_block + 8),
        prism_2x2_lookup_rows4(lut + 768, prefix_block + 12));
    return vfmaq_n_f32(
        acc,
        vmulq_f32(
            vcvtq_f32_s32(vaddq_s32(dots01, dots23)),
            vcvt_f32_f16(vld1_f16(scales))),
        activation_scale);
}

void glacier_prism_2x2_lut_matvec_p2_f16scale_rows4_k16(
    const float *activation_scales,
    const int16_t *activation_lut,
    const uint8_t *prefix2,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t scales_per_row = in_features / group_size;
    for (size_t tile = 0; tile < out_features / 4; ++tile) {
        const size_t row0 = tile * 4;
        float32x4_t acc0 = bias ? vld1q_f32(bias + row0)
                                 : vdupq_n_f32(0.0f);
        float32x4_t acc1 = vdupq_n_f32(0.0f);
        float32x4_t acc2 = vdupq_n_f32(0.0f);
        float32x4_t acc3 = vdupq_n_f32(0.0f);
        const uint8_t *prefix_tile = prefix2 + tile * in_features;
        const __fp16 *tile_scales = scales_rows4 + tile * scales_per_row * 4;
        size_t col = 0;
        if (group_size == 8) {
            for (; col + 63 < in_features; col += 64) {
#define PRISM_2X2_LUT_G8(ACC, COLUMN)                                          \
                (ACC) = prism_2x2_lut_accumulate_g8(                           \
                    (ACC), prefix_tile + (COLUMN),                             \
                    activation_lut + ((COLUMN) / 4) * 256,                     \
                    tile_scales + ((COLUMN) / 8) * 4,                         \
                    activation_scales[(COLUMN) / 32],                         \
                    activation_scales[((COLUMN) + 8) / 32])
                PRISM_2X2_LUT_G8(acc0, col);
                PRISM_2X2_LUT_G8(acc1, col + 16);
                PRISM_2X2_LUT_G8(acc2, col + 32);
                PRISM_2X2_LUT_G8(acc3, col + 48);
#undef PRISM_2X2_LUT_G8
            }
            for (; col < in_features; col += 16) {
                acc0 = prism_2x2_lut_accumulate_g8(
                    acc0, prefix_tile + col,
                    activation_lut + (col / 4) * 256,
                    tile_scales + (col / 8) * 4,
                    activation_scales[col / 32],
                    activation_scales[(col + 8) / 32]);
            }
        } else {
            for (; col + 63 < in_features; col += 64) {
#define PRISM_2X2_LUT_G16(ACC, COLUMN)                                         \
                (ACC) = prism_2x2_lut_accumulate_g16(                          \
                    (ACC), prefix_tile + (COLUMN),                             \
                    activation_lut + ((COLUMN) / 4) * 256,                     \
                    tile_scales + ((COLUMN) / 16) * 4,                        \
                    activation_scales[(COLUMN) / 16])
                PRISM_2X2_LUT_G16(acc0, col);
                PRISM_2X2_LUT_G16(acc1, col + 16);
                PRISM_2X2_LUT_G16(acc2, col + 32);
                PRISM_2X2_LUT_G16(acc3, col + 48);
#undef PRISM_2X2_LUT_G16
            }
            for (; col < in_features; col += 16) {
                acc0 = prism_2x2_lut_accumulate_g16(
                    acc0, prefix_tile + col,
                    activation_lut + (col / 4) * 256,
                    tile_scales + (col / 16) * 4,
                    activation_scales[col / 16]);
            }
        }
        vst1q_f32(output + row0, vaddq_f32(
            vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3)));
    }
}

static void build_prefix2(const PrismCase *c, uint8_t *prefix2)
{
    const size_t weights = c->out_features * c->in_features;
    memset(prefix2, 0, weights / 4);
    for (size_t physical = 0; physical < weights; ++physical) {
        const uint8_t nibble =
            (c->packed_p4[physical >> 1] >> (4 * (physical & 1))) & 15;
        set_plane_pair(prefix2, physical, nibble >> 2);
    }
}

static void run_2x2_p2(PrismCase *c, const uint8_t *prefix2, const float *bias)
{
    glacier_prism_2x2_matvec_p2_neon_q8_prequant_f16scale_rows4_k16(
        c->q_input, c->activation_scales, prefix2, c->scales_rows4, bias,
        c->prism_output, c->out_features, c->in_features, c->group_size);
}

static void run_2x2_p4(PrismCase *c, const uint8_t *prefix2, const float *bias)
{
    glacier_prism_2x2_matvec_p4_neon_q8_prequant_f16scale_rows4_k16(
        c->q_input, c->activation_scales, prefix2, c->fine2, c->scales_rows4,
        bias, c->prism_output, c->out_features, c->in_features, c->group_size);
}

static void run_2x2_p2_lut(
    PrismCase *c,
    const uint8_t *prefix2,
    const int16_t *activation_lut,
    const float *bias)
{
    glacier_prism_2x2_lut_matvec_p2_f16scale_rows4_k16(
        c->activation_scales, activation_lut, prefix2, c->scales_rows4, bias,
        c->prism_output, c->out_features, c->in_features, c->group_size);
}

static int verify_2x2(
    PrismCase *c,
    const uint8_t *prefix2,
    const int16_t *activation_lut,
    const char *phase)
{
    const float *biases[2] = { c->bias, NULL };
    const char *bias_names[2] = { "bias", "no_bias" };
    for (size_t mode = 0; mode < 2; ++mode) {
        run_legacy(c, c->packed_p2, biases[mode]);
        run_2x2_p2(c, prefix2, biases[mode]);
        if (!require_equal(c, "2x2_p2", bias_names[mode])) return 0;
        run_legacy(c, c->packed_p2, biases[mode]);
        run_2x2_p2_lut(c, prefix2, activation_lut, biases[mode]);
        if (!require_equal(c, "2x2_p2_lut", bias_names[mode])) return 0;
        run_legacy(c, c->packed_p4, biases[mode]);
        run_2x2_p4(c, prefix2, biases[mode]);
        if (!require_equal(c, "2x2_p4", bias_names[mode])) return 0;
    }
    fprintf(
        stderr,
        "VERIFY_2X2_PASS,%s,out=%zu,in=%zu,g=%zu,bit_exact\n",
        phase, c->out_features, c->in_features, c->group_size);
    return 1;
}

static double measure_2x2_lut(
    PrismCase *c,
    const uint8_t *prefix2,
    const int16_t *activation_lut,
    int legacy,
    size_t inner_iterations)
{
    const uint64_t start = ticks_now();
    for (size_t iteration = 0; iteration < inner_iterations; ++iteration) {
        if (legacy) run_legacy(c, c->packed_p4, c->bias);
        else run_2x2_p2_lut(c, prefix2, activation_lut, c->bias);
    }
    const uint64_t end = ticks_now();
    const float *sample = legacy ? c->legacy_output : c->prism_output;
    uint32_t bits;
    memcpy(&bits, sample + (splitmix64() % c->out_features), sizeof(bits));
    output_sink ^= bits;
    return ticks_to_ns(end - start) / (double)inner_iterations;
}

static void summarize_2x2_lut(
    PrismCase *c,
    const uint8_t *prefix2,
    int16_t *activation_lut,
    size_t samples,
    size_t inner_iterations,
    FILE *raw)
{
    double legacy[64];
    double prism[64];
    double prepare[64];
    if (samples > 64) samples = 64;
    for (size_t warmup = 0; warmup < 12; ++warmup) {
        (void)measure_2x2_lut(
            c, prefix2, activation_lut, warmup & 1, 1);
    }
    for (size_t sample = 0; sample < samples; ++sample) {
        const uint64_t prepare_start = ticks_now();
        prism_2x2_prepare_p2_lut(
            c->q_input, c->in_features, activation_lut);
        prepare[sample] = ticks_to_ns(ticks_now() - prepare_start);
        if (sample & 1) {
            prism[sample] = measure_2x2_lut(
                c, prefix2, activation_lut, 0, inner_iterations);
            legacy[sample] = measure_2x2_lut(
                c, prefix2, activation_lut, 1, inner_iterations);
            fprintf(
                raw, "%" PRIu64 ",p2_lut,%zu,%zu,BA,0,B,%.3f,%.3f\n",
                run_id, c->group_size, sample, prism[sample], prepare[sample]);
            fprintf(
                raw, "%" PRIu64 ",p2_lut,%zu,%zu,BA,1,A,%.3f,%.3f\n",
                run_id, c->group_size, sample, legacy[sample], prepare[sample]);
        } else {
            legacy[sample] = measure_2x2_lut(
                c, prefix2, activation_lut, 1, inner_iterations);
            prism[sample] = measure_2x2_lut(
                c, prefix2, activation_lut, 0, inner_iterations);
            fprintf(
                raw, "%" PRIu64 ",p2_lut,%zu,%zu,AB,0,A,%.3f,%.3f\n",
                run_id, c->group_size, sample, legacy[sample], prepare[sample]);
            fprintf(
                raw, "%" PRIu64 ",p2_lut,%zu,%zu,AB,1,B,%.3f,%.3f\n",
                run_id, c->group_size, sample, prism[sample], prepare[sample]);
        }
    }
#define PRISM_SORT_2X2(ARRAY)                                                  \
    for (size_t i = 1; i < samples; ++i) {                                    \
        for (size_t j = i; j > 0 && (ARRAY)[j] < (ARRAY)[j - 1]; --j) {       \
            const double swap = (ARRAY)[j];                                   \
            (ARRAY)[j] = (ARRAY)[j - 1];                                      \
            (ARRAY)[j - 1] = swap;                                            \
        }                                                                      \
    }
    PRISM_SORT_2X2(legacy)
    PRISM_SORT_2X2(prism)
    PRISM_SORT_2X2(prepare)
#undef PRISM_SORT_2X2
    const double legacy_median = legacy[samples / 2];
    const double prism_median = prism[samples / 2];
    const double prepare_median = prepare[samples / 2];
    printf(
        "2x2,p2_lut,g%zu,legacy_ns=%.3f,prism_ns=%.3f,prepare_ns=%.3f,"
        "producer_speedup=%.6f,one_projection_speedup=%.6f\n",
        c->group_size, legacy_median, prism_median, prepare_median,
        legacy_median / prism_median,
        legacy_median / (prism_median + prepare_median));
}

static double measure_2x2(
    PrismCase *c,
    const uint8_t *prefix2,
    BenchMethod method,
    size_t inner_iterations)
{
    const uint64_t start = ticks_now();
    for (size_t iteration = 0; iteration < inner_iterations; ++iteration) {
        if (method == METHOD_LEGACY) run_legacy(c, c->packed_p4, c->bias);
        else if (method == METHOD_P2) run_2x2_p2(c, prefix2, c->bias);
        else run_2x2_p4(c, prefix2, c->bias);
    }
    const uint64_t end = ticks_now();
    const float *sample = method == METHOD_LEGACY
        ? c->legacy_output : c->prism_output;
    uint32_t bits;
    memcpy(&bits, sample + (splitmix64() % c->out_features), sizeof(bits));
    output_sink ^= bits;
    return ticks_to_ns(end - start) / (double)inner_iterations;
}

static void summarize_2x2(
    PrismCase *c,
    const uint8_t *prefix2,
    BenchMethod method,
    size_t samples,
    size_t inner_iterations,
    FILE *raw)
{
    double legacy[64];
    double prism[64];
    if (samples > 64) samples = 64;
    for (size_t warmup = 0; warmup < 12; ++warmup) {
        (void)measure_2x2(
            c, prefix2, warmup & 1 ? method : METHOD_LEGACY, 1);
    }
    for (size_t sample = 0; sample < samples; ++sample) {
        const int reverse = sample & 1;
        if (reverse) {
            prism[sample] = measure_2x2(c, prefix2, method, inner_iterations);
            legacy[sample] = measure_2x2(
                c, prefix2, METHOD_LEGACY, inner_iterations);
            fprintf(
                raw, "%" PRIu64 ",%s,%zu,%zu,BA,0,B,%.3f,\n",
                run_id, method == METHOD_P2 ? "p2" : "p4", c->group_size,
                sample, prism[sample]);
            fprintf(
                raw, "%" PRIu64 ",%s,%zu,%zu,BA,1,A,%.3f,\n",
                run_id, method == METHOD_P2 ? "p2" : "p4", c->group_size,
                sample, legacy[sample]);
        } else {
            legacy[sample] = measure_2x2(
                c, prefix2, METHOD_LEGACY, inner_iterations);
            prism[sample] = measure_2x2(c, prefix2, method, inner_iterations);
            fprintf(
                raw, "%" PRIu64 ",%s,%zu,%zu,AB,0,A,%.3f,\n",
                run_id, method == METHOD_P2 ? "p2" : "p4", c->group_size,
                sample, legacy[sample]);
            fprintf(
                raw, "%" PRIu64 ",%s,%zu,%zu,AB,1,B,%.3f,\n",
                run_id, method == METHOD_P2 ? "p2" : "p4", c->group_size,
                sample, prism[sample]);
        }
    }
    for (size_t i = 1; i < samples; ++i) {
        for (size_t j = i; j > 0 && legacy[j] < legacy[j - 1]; --j) {
            const double swap = legacy[j];
            legacy[j] = legacy[j - 1];
            legacy[j - 1] = swap;
        }
        for (size_t j = i; j > 0 && prism[j] < prism[j - 1]; --j) {
            const double swap = prism[j];
            prism[j] = prism[j - 1];
            prism[j - 1] = swap;
        }
    }
    const double legacy_median = legacy[samples / 2];
    const double prism_median = prism[samples / 2];
    printf(
        "2x2,%s,g%zu,legacy_ns=%.3f,prism_ns=%.3f,speedup=%.6f,"
        "prism_over_legacy=%.6f\n",
        method == METHOD_P2 ? "p2" : "p4", c->group_size,
        legacy_median, prism_median, legacy_median / prism_median,
        prism_median / legacy_median);
}

int main(int argc, char **argv)
{
    const size_t samples = argc > 1 ? parse_positive(argv[1], "samples") : 64;
    const size_t inner = argc > 2 ? parse_positive(argv[2], "inner") : 3;
    const char *raw_path = argc > 3
        ? argv[3] : "/tmp/prism-rows4-2x2-screen.raw.csv";
    if (argc > 4 || samples > 64 || (samples & 1) != 0) {
        fprintf(
            stderr,
            "usage: %s [even-samples<=64] [inner] [raw.csv]\n",
            argv[0]);
        return 2;
    }
    mach_timebase_info(&timebase);
    run_id = mach_continuous_time() ^ ((uint64_t)getpid() << 32);
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    FILE *raw = fopen(raw_path, "w");
    if (raw == NULL) {
        perror(raw_path);
        return 2;
    }
    fprintf(
        raw,
        "run_id,variant,group_size,sample,pattern,position,method,ns,"
        "prepare_ns\n");
    for (size_t group_size = 8; group_size <= 16; group_size *= 2) {
        PrismCase c;
        initialize_case(
            &c, BENCH_OUT_FEATURES, BENCH_IN_FEATURES, group_size,
            UINT64_C(0x082efa98ec4e6c89) ^ group_size);
        uint8_t *prefix2 = aligned_alloc64(
            c.out_features * c.in_features / 4);
        int16_t *activation_lut = aligned_alloc64(
            (c.in_features / 4) * 256 * sizeof(int16_t));
        build_prefix2(&c, prefix2);
        prism_2x2_prepare_p2_lut(c.q_input, c.in_features, activation_lut);
        if (!verify_2x2(&c, prefix2, activation_lut, "before")) return 1;
        summarize_2x2(&c, prefix2, METHOD_P2, samples, inner, raw);
        summarize_2x2(&c, prefix2, METHOD_P4, samples, inner, raw);
        summarize_2x2_lut(
            &c, prefix2, activation_lut, samples, inner, raw);
        if (!verify_2x2(&c, prefix2, activation_lut, "after")) return 1;
        free(activation_lut);
        free(prefix2);
        destroy_case(&c);
    }
    if (fclose(raw) != 0) return 2;
    fprintf(
        stderr,
        "SCREEN_2X2_DONE,samples=%zu,inner=%zu,sink=%" PRIu64
        ",run_id=%" PRIu64 "\n",
        samples, inner, output_sink, run_id);
    return 0;
}

#undef PRISM_2X2_RESIDUAL_TILE_P2
#undef PRISM_2X2_RESIDUAL_TILE_P4
#undef PRISM_2X2_TILE_LOOP
#undef PRISM_2X2_STEP_P2_G8
#undef PRISM_2X2_STEP_P2_G16
#undef PRISM_2X2_STEP_P4_G8
#undef PRISM_2X2_STEP_P4_G16
