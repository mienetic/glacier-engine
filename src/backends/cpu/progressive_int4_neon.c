#include <arm_neon.h>
#include <stddef.h>
#include <stdint.h>

// Apple/AArch64 reference SIMD kernels for Prism's physically split 1+1+2
// bitplanes.  The public functions deliberately take only the planes needed
// by their tier: a P1 call cannot accidentally touch middle/fine bytes, and a
// P2 call has no fine pointer to speculate through.

static inline int8x8_t prism_signed_bit(uint8_t packed, int8_t magnitude)
{
    const uint8x8_t lane_bits = { 1, 2, 4, 8, 16, 32, 64, 128 };
    const uint8x8_t set = vtst_u8(vdup_n_u8(packed), lane_bits);
    return vbsl_s8(
        set,
        vdup_n_s8(magnitude),
        vdup_n_s8((int8_t)-magnitude));
}

static inline int8x8_t prism_p1_weights(const uint8_t *coarse1, size_t index)
{
    return prism_signed_bit(coarse1[index >> 3], 4);
}

static inline int8x8_t prism_p2_weights(
    const uint8_t *coarse1,
    const uint8_t *middle1,
    size_t index)
{
    return vadd_s8(
        prism_signed_bit(coarse1[index >> 3], 4),
        prism_signed_bit(middle1[index >> 3], 2));
}

static inline int8x8_t prism_fine_weights(const uint8_t *fine2, size_t index)
{
    // Each fine byte contains four little-lane two-bit values.  Duplicate
    // the two bytes covering this eight-weight block, then use per-lane right
    // shifts to unpack all lanes without a lookup table or scalar gather.
    const uint8_t low = fine2[index >> 2];
    const uint8_t high = fine2[(index >> 2) + 1];
    const uint8x8_t repeated = { low, low, low, low, high, high, high, high };
    const int8x8_t shifts = { 0, -2, -4, -6, 0, -2, -4, -6 };
    const uint8x8_t lanes = vand_u8(
        vshl_u8(repeated, shifts),
        vdup_n_u8(0x03));
    return vsub_s8(vreinterpret_s8_u8(lanes), vdup_n_s8(1));
}

static inline int8x8_t prism_p4_weights(
    const uint8_t *coarse1,
    const uint8_t *middle1,
    const uint8_t *fine2,
    size_t index)
{
    // Add in integer space first.  This reconstructs u - 7 exactly for every
    // nibble before any scale or activation arithmetic is performed.
    return vadd_s8(
        prism_p2_weights(coarse1, middle1, index),
        prism_fine_weights(fine2, index));
}

static inline void prism_accumulate_eight(
    const float *activations,
    int8x8_t weights,
    float scale,
    float32x4_t *acc_low,
    float32x4_t *acc_high)
{
    const int16x8_t weights16 = vmovl_s8(weights);
    const float32x4_t weights_low = vcvtq_f32_s32(
        vmovl_s16(vget_low_s16(weights16)));
    const float32x4_t weights_high = vcvtq_f32_s32(
        vmovl_high_s16(weights16));
    *acc_low = vfmaq_n_f32(
        *acc_low,
        vmulq_f32(vld1q_f32(activations), weights_low),
        scale);
    *acc_high = vfmaq_n_f32(
        *acc_high,
        vmulq_f32(vld1q_f32(activations + 4), weights_high),
        scale);
}

static inline int8_t prism_scalar_bit(
    const uint8_t *plane,
    size_t index,
    int8_t magnitude)
{
    const uint8_t bit = (plane[index >> 3] >> (index & 7)) & 1;
    return bit ? magnitude : (int8_t)-magnitude;
}

static inline int8_t prism_scalar_fine(const uint8_t *fine2, size_t index)
{
    const unsigned shift = (unsigned)((index & 3) << 1);
    return (int8_t)((fine2[index >> 2] >> shift) & 3) - 1;
}

float glacier_prism_dot_p1_neon(
    const float *activations,
    const uint8_t *coarse1,
    const float *scales,
    size_t num_weights,
    size_t group_size)
{
    float32x4_t acc_low = vdupq_n_f32(0.0f);
    float32x4_t acc_high = vdupq_n_f32(0.0f);
    size_t index = 0;
    float tail = 0.0f;
    size_t scale_index = 0;
    while (index < num_weights) {
        const size_t remaining = num_weights - index;
        const size_t group_end = group_size < remaining
            ? index + group_size : num_weights;
        const float scale = scales[scale_index++];
        for (; index + 8 <= group_end; index += 8) {
            prism_accumulate_eight(
                activations + index,
                prism_p1_weights(coarse1, index),
                scale,
                &acc_low,
                &acc_high);
        }
        for (; index < group_end; ++index) {
            const float weight = (float)prism_scalar_bit(coarse1, index, 4);
            tail += activations[index] * (weight * scale);
        }
    }
    return vaddvq_f32(acc_low) + vaddvq_f32(acc_high) + tail;
}

float glacier_prism_dot_p2_neon(
    const float *activations,
    const uint8_t *coarse1,
    const uint8_t *middle1,
    const float *scales,
    size_t num_weights,
    size_t group_size)
{
    float32x4_t acc_low = vdupq_n_f32(0.0f);
    float32x4_t acc_high = vdupq_n_f32(0.0f);
    size_t index = 0;
    float tail = 0.0f;
    size_t scale_index = 0;
    while (index < num_weights) {
        const size_t remaining = num_weights - index;
        const size_t group_end = group_size < remaining
            ? index + group_size : num_weights;
        const float scale = scales[scale_index++];
        for (; index + 8 <= group_end; index += 8) {
            prism_accumulate_eight(
                activations + index,
                prism_p2_weights(coarse1, middle1, index),
                scale,
                &acc_low,
                &acc_high);
        }
        for (; index < group_end; ++index) {
            const int8_t weight = prism_scalar_bit(coarse1, index, 4) +
                prism_scalar_bit(middle1, index, 2);
            tail += activations[index] * ((float)weight * scale);
        }
    }
    return vaddvq_f32(acc_low) + vaddvq_f32(acc_high) + tail;
}

float glacier_prism_dot_p4_neon(
    const float *activations,
    const uint8_t *coarse1,
    const uint8_t *middle1,
    const uint8_t *fine2,
    const float *scales,
    size_t num_weights,
    size_t group_size)
{
    float32x4_t acc_low = vdupq_n_f32(0.0f);
    float32x4_t acc_high = vdupq_n_f32(0.0f);
    size_t index = 0;
    float tail = 0.0f;
    size_t scale_index = 0;
    while (index < num_weights) {
        const size_t remaining = num_weights - index;
        const size_t group_end = group_size < remaining
            ? index + group_size : num_weights;
        const float scale = scales[scale_index++];
        for (; index + 8 <= group_end; index += 8) {
            prism_accumulate_eight(
                activations + index,
                prism_p4_weights(coarse1, middle1, fine2, index),
                scale,
                &acc_low,
                &acc_high);
        }
        for (; index < group_end; ++index) {
            const int8_t weight = prism_scalar_bit(coarse1, index, 4) +
                prism_scalar_bit(middle1, index, 2) +
                prism_scalar_fine(fine2, index);
            tail += activations[index] * ((float)weight * scale);
        }
    }
    return vaddvq_f32(acc_low) + vaddvq_f32(acc_high) + tail;
}

// Production-Q8 feasibility kernels for the rows4/K16 physical layout.
//
// A K16 block contains 64 weights in the same physical order as the existing
// packed-INT4 SDOT kernel:
//
//   [K4 chunk][output-row lane][K4 weight]
//
// The dense planes therefore occupy 8 coarse bytes, 8 middle bytes and 16
// fine bytes per block.  The P2 ABI intentionally has no fine pointer.  This
// is both a smaller hot-call contract and an enforceable proof that a P2 run
// cannot fetch the fine range speculatively.

static inline size_t prism_rows4_k16_index(
    size_t row,
    size_t col,
    size_t in_features)
{
    const size_t tile = row / 4;
    const size_t lane = row % 4;
    const size_t block = col / 16;
    const size_t chunk = (col % 16) / 4;
    const size_t inner = col % 4;
    return tile * (4 * in_features) + block * 64 + chunk * 16 + lane * 4 + inner;
}

static inline int8_t prism_rows4_scalar_p2(
    const uint8_t *coarse1,
    const uint8_t *middle1,
    size_t physical)
{
    const int8_t coarse = ((coarse1[physical >> 3] >> (physical & 7)) & 1)
        ? 4 : -4;
    const int8_t middle = ((middle1[physical >> 3] >> (physical & 7)) & 1)
        ? 2 : -2;
    return (int8_t)(coarse + middle);
}

static inline int8_t prism_rows4_scalar_p4(
    const uint8_t *coarse1,
    const uint8_t *middle1,
    const uint8_t *fine2,
    size_t physical)
{
    const uint8_t b3 = (coarse1[physical >> 3] >> (physical & 7)) & 1;
    const uint8_t b2 = (middle1[physical >> 3] >> (physical & 7)) & 1;
    const uint8_t fine = (fine2[physical >> 2] >> ((physical & 3) * 2)) & 3;
    return (int8_t)((b3 << 3) | (b2 << 2) | fine) - 7;
}

#if defined(__ARM_FEATURE_DOTPROD)
// TBL duplicates the two source bytes for one physical K4/rows4 chunk.  TST
// then exposes each bit as an all-zero/all-one byte mask.  Keeping the
// compressed plane resident in one vector lets four chunk decodes reuse the
// same 8-byte load.
static const uint8_t prism_rows4_bit_indices[4][16] = {
    { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 },
    { 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3 },
    { 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5 },
    { 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7 },
};

static const uint8_t prism_rows4_fine_indices[4][16] = {
    { 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 },
    { 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7 },
    { 8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 11 },
    { 12, 12, 12, 12, 13, 13, 13, 13, 14, 14, 14, 14, 15, 15, 15, 15 },
};

static inline uint8x16_t prism_rows4_repeat_plane(uint8x8_t plane)
{
    return vcombine_u8(plane, plane);
}

static inline int8x16_t prism_rows4_decode_p2_chunk(
    uint8x16_t coarse,
    uint8x16_t middle,
    size_t chunk)
{
    const uint8x16_t indices = vld1q_u8(prism_rows4_bit_indices[chunk]);
    const uint8x16_t lane_bits = {
        1, 2, 4, 8, 16, 32, 64, 128,
        1, 2, 4, 8, 16, 32, 64, 128,
    };
    const uint8x16_t coarse_set = vtstq_u8(
        vqtbl1q_u8(coarse, indices), lane_bits);
    const uint8x16_t middle_set = vtstq_u8(
        vqtbl1q_u8(middle, indices), lane_bits);
    const uint8x16_t unsigned_code = vorrq_u8(
        vandq_u8(coarse_set, vdupq_n_u8(8)),
        vandq_u8(middle_set, vdupq_n_u8(4)));
    // code - 6 gives exactly {-6,-2,+2,+6} == (b3 ? 4 : -4) +
    // (b2 ? 2 : -2); SDOT therefore consumes the centered P2 coefficient.
    return vsubq_s8(vreinterpretq_s8_u8(unsigned_code), vdupq_n_s8(6));
}

static inline int8x16_t prism_rows4_decode_p4_chunk(
    uint8x16_t coarse,
    uint8x16_t middle,
    uint8x16_t fine,
    size_t chunk)
{
    const uint8x16_t bit_indices = vld1q_u8(prism_rows4_bit_indices[chunk]);
    const uint8x16_t lane_bits = {
        1, 2, 4, 8, 16, 32, 64, 128,
        1, 2, 4, 8, 16, 32, 64, 128,
    };
    const uint8x16_t coarse_set = vtstq_u8(
        vqtbl1q_u8(coarse, bit_indices), lane_bits);
    const uint8x16_t middle_set = vtstq_u8(
        vqtbl1q_u8(middle, bit_indices), lane_bits);
    const uint8x16_t fine_repeated = vqtbl1q_u8(
        fine, vld1q_u8(prism_rows4_fine_indices[chunk]));
    const int8x16_t fine_shifts = {
        0, -2, -4, -6, 0, -2, -4, -6,
        0, -2, -4, -6, 0, -2, -4, -6,
    };
    const uint8x16_t fine_values = vandq_u8(
        vshlq_u8(fine_repeated, fine_shifts), vdupq_n_u8(3));
    const uint8x16_t unsigned_nibbles = vorrq_u8(
        vorrq_u8(
            vandq_u8(coarse_set, vdupq_n_u8(8)),
            vandq_u8(middle_set, vdupq_n_u8(4))),
        fine_values);
    // Reconstruct the complete unsigned nibble before centering.  This is
    // integer-identical to the legacy unpacker's `(u & 15) - 7` contract.
    return vsubq_s8(
        vreinterpretq_s8_u8(unsigned_nibbles), vdupq_n_s8(7));
}

static inline void prism_rows4_decode_p2_block(
    const uint8_t *coarse1,
    const uint8_t *middle1,
    int8x16_t *weights0,
    int8x16_t *weights1,
    int8x16_t *weights2,
    int8x16_t *weights3)
{
    const uint8x16_t coarse = prism_rows4_repeat_plane(vld1_u8(coarse1));
    const uint8x16_t middle = prism_rows4_repeat_plane(vld1_u8(middle1));
    *weights0 = prism_rows4_decode_p2_chunk(coarse, middle, 0);
    *weights1 = prism_rows4_decode_p2_chunk(coarse, middle, 1);
    *weights2 = prism_rows4_decode_p2_chunk(coarse, middle, 2);
    *weights3 = prism_rows4_decode_p2_chunk(coarse, middle, 3);
}

static inline void prism_rows4_decode_p4_block(
    const uint8_t *coarse1,
    const uint8_t *middle1,
    const uint8_t *fine2,
    int8x16_t *weights0,
    int8x16_t *weights1,
    int8x16_t *weights2,
    int8x16_t *weights3)
{
    const uint8x16_t coarse = prism_rows4_repeat_plane(vld1_u8(coarse1));
    const uint8x16_t middle = prism_rows4_repeat_plane(vld1_u8(middle1));
    const uint8x16_t fine = vld1q_u8(fine2);
    *weights0 = prism_rows4_decode_p4_chunk(coarse, middle, fine, 0);
    *weights1 = prism_rows4_decode_p4_chunk(coarse, middle, fine, 1);
    *weights2 = prism_rows4_decode_p4_chunk(coarse, middle, fine, 2);
    *weights3 = prism_rows4_decode_p4_chunk(coarse, middle, fine, 3);
}

static inline float32x4_t prism_rows4_accumulate_g8(
    float32x4_t acc,
    int8x16_t q_act,
    int8x16_t weights0,
    int8x16_t weights1,
    int8x16_t weights2,
    int8x16_t weights3,
    const __fp16 *scales,
    float activation_scale0,
    float activation_scale1)
{
    int32x4_t dots0 = vdotq_laneq_s32(
        vdupq_n_s32(0), weights0, q_act, 0);
    dots0 = vdotq_laneq_s32(dots0, weights1, q_act, 1);
    int32x4_t dots1 = vdotq_laneq_s32(
        vdupq_n_s32(0), weights2, q_act, 2);
    dots1 = vdotq_laneq_s32(dots1, weights3, q_act, 3);
    const float16x8_t scale_pair = vld1q_f16(scales);
    const float32x4_t weight_scales0 = vcvt_f32_f16(vget_low_f16(scale_pair));
    const float32x4_t weight_scales1 = vcvt_high_f32_f16(scale_pair);
    acc = vfmaq_n_f32(
        acc,
        vmulq_f32(vcvtq_f32_s32(dots0), weight_scales0),
        activation_scale0);
    return vfmaq_n_f32(
        acc,
        vmulq_f32(vcvtq_f32_s32(dots1), weight_scales1),
        activation_scale1);
}

static inline float32x4_t prism_rows4_accumulate_g16(
    float32x4_t acc,
    int8x16_t q_act,
    int8x16_t weights0,
    int8x16_t weights1,
    int8x16_t weights2,
    int8x16_t weights3,
    const __fp16 *scales,
    float activation_scale)
{
    int32x4_t dots = vdotq_laneq_s32(
        vdupq_n_s32(0), weights0, q_act, 0);
    dots = vdotq_laneq_s32(dots, weights1, q_act, 1);
    dots = vdotq_laneq_s32(dots, weights2, q_act, 2);
    dots = vdotq_laneq_s32(dots, weights3, q_act, 3);
    const float32x4_t weight_scales = vcvt_f32_f16(vld1_f16(scales));
    return vfmaq_n_f32(
        acc,
        vmulq_f32(vcvtq_f32_s32(dots), weight_scales),
        activation_scale);
}
#endif

#define PRISM_ROWS4_DECODE_TIER(TIER, COLUMN)                                  \
        int8x16_t weights0;                                                    \
        int8x16_t weights1;                                                    \
        int8x16_t weights2;                                                    \
        int8x16_t weights3;                                                    \
        PRISM_ROWS4_DECODE_CALL_##TIER(COLUMN)

#define PRISM_ROWS4_DECODE_CALL_p2(COLUMN)                                     \
        prism_rows4_decode_p2_block(                                           \
            coarse_tile + (COLUMN) / 2, middle_tile + (COLUMN) / 2,            \
            &weights0, &weights1, &weights2, &weights3)

#define PRISM_ROWS4_DECODE_CALL_p4(COLUMN)                                     \
        prism_rows4_decode_p4_block(                                           \
            coarse_tile + (COLUMN) / 2, middle_tile + (COLUMN) / 2,            \
            fine_tile + (COLUMN),                                              \
            &weights0, &weights1, &weights2, &weights3)

#define PRISM_ROWS4_ACCUMULATE_G8(TIER, ACCUMULATOR, COLUMN)                   \
    do {                                                                       \
        PRISM_ROWS4_DECODE_TIER(TIER, COLUMN);                                 \
        (ACCUMULATOR) = prism_rows4_accumulate_g8(                             \
            (ACCUMULATOR), vld1q_s8(q_input + (COLUMN)), weights0, weights1,   \
            weights2, weights3, tile_scales + ((COLUMN) / 8) * 4,              \
            activation_scales[(COLUMN) / 32],                                 \
            activation_scales[((COLUMN) + 8) / 32]);                          \
    } while (0)

#define PRISM_ROWS4_ACCUMULATE_G16(TIER, ACCUMULATOR, COLUMN)                  \
    do {                                                                       \
        PRISM_ROWS4_DECODE_TIER(TIER, COLUMN);                                 \
        (ACCUMULATOR) = prism_rows4_accumulate_g16(                            \
            (ACCUMULATOR), vld1q_s8(q_input + (COLUMN)), weights0, weights1,   \
            weights2, weights3, tile_scales + ((COLUMN) / 16) * 4,             \
            activation_scales[(COLUMN) / 16]);                                \
    } while (0)

#define PRISM_ROWS4_DEFINE_MATVEC(TIER, FINE_PARAMETER, FINE_TILE)             \
void glacier_prism_matvec_##TIER##_neon_q8_prequant_f16scale_rows4_k16(        \
    const int8_t *q_input,                                                     \
    const float *activation_scales,                                            \
    const uint8_t *coarse1,                                                    \
    const uint8_t *middle1,                                                    \
    FINE_PARAMETER                                                             \
    const __fp16 *scales_rows4,                                                \
    const float *bias,                                                         \
    float *output,                                                             \
    size_t out_features,                                                       \
    size_t in_features,                                                        \
    size_t group_size)                                                         \
{                                                                              \
    const size_t scales_per_row = in_features / group_size;                    \
    size_t processed_rows = 0;                                                 \
    (void)processed_rows;                                                      \
    (void)scales_per_row;                                                      \
    FINE_TILE                                                                  \
    /* The typed caller guarantees this geometry.  Keeping the predicate     \
       defensive preserves a correct scalar fallback for direct C callers. */\
    /* NOLINTNEXTLINE(bugprone-branch-clone) */                                 \
    PRISM_ROWS4_FAST_##TIER                                                     \
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;    \
    const size_t groups = in_features / group_size;                            \
    for (size_t row = processed_rows; row < out_features; ++row) {             \
        float acc = bias ? bias[row] : 0.0f;                                   \
        for (size_t group = 0; group < groups; ++group) {                      \
            const size_t col_start = group * group_size;                       \
            int32_t dot = 0;                                                   \
            for (size_t col = 0; col < group_size; ++col) {                    \
                const size_t physical = prism_rows4_k16_index(                 \
                    row, col_start + col, in_features);                        \
                dot += (int32_t)prism_rows4_scalar_##TIER(                     \
                    coarse1, middle1, PRISM_ROWS4_SCALAR_FINE_##TIER           \
                    physical) * (int32_t)q_input[col_start + col];             \
            }                                                                  \
            const size_t scale_index =                                         \
                ((row / 4) * scales_per_row + group) * 4 + row % 4;            \
            acc += (float)dot * (float)scales_rows4[scale_index] *             \
                activation_scales[col_start / activation_group_size];          \
        }                                                                      \
        output[row] = acc;                                                     \
    }                                                                          \
}

#define PRISM_ROWS4_SCALAR_FINE_p2
#define PRISM_ROWS4_SCALAR_FINE_p4 fine2,

#if defined(__ARM_FEATURE_DOTPROD)
#define PRISM_ROWS4_TILE_LOOP(TIER, GROUP)                                     \
        for (size_t tile = 0; tile < row_tiles; ++tile) {                      \
            const size_t row0 = tile * 4;                                      \
            float32x4_t acc0 = bias ? vld1q_f32(bias + row0)                   \
                                     : vdupq_n_f32(0.0f);                      \
            float32x4_t acc1 = vdupq_n_f32(0.0f);                              \
            float32x4_t acc2 = vdupq_n_f32(0.0f);                              \
            float32x4_t acc3 = vdupq_n_f32(0.0f);                              \
            const uint8_t *coarse_tile = coarse1 + tile * (in_features / 2);  \
            const uint8_t *middle_tile = middle1 + tile * (in_features / 2);  \
            PRISM_ROWS4_FINE_TILE_##TIER                                       \
            const __fp16 *tile_scales = scales_rows4 +                        \
                tile * scales_per_row * 4;                                     \
            size_t col = 0;                                                    \
            for (; col + 63 < in_features; col += 64) {                        \
                PRISM_ROWS4_ACCUMULATE_##GROUP(TIER, acc0, col);               \
                PRISM_ROWS4_ACCUMULATE_##GROUP(TIER, acc1, col + 16);          \
                PRISM_ROWS4_ACCUMULATE_##GROUP(TIER, acc2, col + 32);          \
                PRISM_ROWS4_ACCUMULATE_##GROUP(TIER, acc3, col + 48);          \
            }                                                                  \
            for (; col < in_features; col += 16) {                             \
                PRISM_ROWS4_ACCUMULATE_##GROUP(TIER, acc0, col);               \
            }                                                                  \
            vst1q_f32(output + row0, vaddq_f32(                                \
                vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3)));                \
        }

#define PRISM_ROWS4_FAST_BODY(TIER)                                            \
    if ((group_size == 8 || group_size == 16) &&                               \
        out_features % 4 == 0 && in_features % 16 == 0) {                      \
        const size_t row_tiles = out_features / 4;                             \
        if (group_size == 8) {                                                 \
            PRISM_ROWS4_TILE_LOOP(TIER, G8)                                    \
        } else {                                                               \
            PRISM_ROWS4_TILE_LOOP(TIER, G16)                                   \
        }                                                                      \
        processed_rows = out_features;                                         \
    }

#define PRISM_ROWS4_FAST_p2 PRISM_ROWS4_FAST_BODY(p2)
#define PRISM_ROWS4_FAST_p4 PRISM_ROWS4_FAST_BODY(p4)
#define PRISM_ROWS4_FINE_TILE_p2
#define PRISM_ROWS4_FINE_TILE_p4                                                \
    const uint8_t *fine_tile = fine2 + tile * in_features;
#else
#define PRISM_ROWS4_FAST_p2
#define PRISM_ROWS4_FAST_p4
#endif

PRISM_ROWS4_DEFINE_MATVEC(p2, , )
#define PRISM_ROWS4_P4_FINE_PARAMETER const uint8_t *fine2,
PRISM_ROWS4_DEFINE_MATVEC(p4, PRISM_ROWS4_P4_FINE_PARAMETER, (void)fine2;)
#undef PRISM_ROWS4_P4_FINE_PARAMETER

#undef PRISM_ROWS4_DEFINE_MATVEC
#undef PRISM_ROWS4_TILE_LOOP
#undef PRISM_ROWS4_FAST_BODY
#undef PRISM_ROWS4_FAST_p2
#undef PRISM_ROWS4_FAST_p4
#undef PRISM_ROWS4_FINE_TILE_p2
#undef PRISM_ROWS4_FINE_TILE_p4
#undef PRISM_ROWS4_SCALAR_FINE_p2
#undef PRISM_ROWS4_SCALAR_FINE_p4
#undef PRISM_ROWS4_DECODE_CALL_p2
#undef PRISM_ROWS4_DECODE_CALL_p4
#undef PRISM_ROWS4_ACCUMULATE_G8
#undef PRISM_ROWS4_ACCUMULATE_G16
#undef PRISM_ROWS4_DECODE_TIER
