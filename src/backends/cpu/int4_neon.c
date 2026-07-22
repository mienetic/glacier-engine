#include <arm_neon.h>
#include <float.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    float value;
    size_t index;
    int valid;
    int saw_nan;
} glacier_argmax_result;

_Static_assert(sizeof(glacier_argmax_result) == 24, "argmax result ABI size");
_Static_assert(offsetof(glacier_argmax_result, value) == 0, "argmax value ABI");
_Static_assert(offsetof(glacier_argmax_result, index) == 8, "argmax index ABI");
_Static_assert(offsetof(glacier_argmax_result, valid) == 16, "argmax valid ABI");
_Static_assert(offsetof(glacier_argmax_result, saw_nan) == 20, "argmax NaN ABI");

size_t glacier_argmax_f32_neon(const float *values, size_t count)
{
    if (count < 4) {
        size_t best_index = 0;
        for (size_t i = 1; i < count; ++i)
            if (values[i] > values[best_index]) best_index = i;
        return best_index;
    }
    float32x4_t best_values = vld1q_f32(values);
    uint32x4_t best_indices = { 0, 1, 2, 3 };
    uint32x4_t indices = { 4, 5, 6, 7 };
    const uint32x4_t step = vdupq_n_u32(4);
    size_t i = 4;
    for (; i + 3 < count; i += 4) {
        const float32x4_t candidates = vld1q_f32(values + i);
        const uint32x4_t better = vcgtq_f32(candidates, best_values);
        best_values = vbslq_f32(better, candidates, best_values);
        best_indices = vbslq_u32(better, indices, best_indices);
        indices = vaddq_u32(indices, step);
    }
    float lane_values[4];
    uint32_t lane_indices[4];
    vst1q_f32(lane_values, best_values);
    vst1q_u32(lane_indices, best_indices);
    size_t best_index = lane_indices[0];
    float best_value = lane_values[0];
    for (size_t lane = 1; lane < 4; ++lane) {
        if (lane_values[lane] > best_value ||
            (lane_values[lane] == best_value && lane_indices[lane] < best_index)) {
            best_value = lane_values[lane];
            best_index = lane_indices[lane];
        }
    }
    for (; i < count; ++i) {
        if (values[i] > best_value) {
            best_value = values[i];
            best_index = i;
        }
    }
    return best_index;
}

// Q8 quantization is undefined for NaN and infinity (infinity produces an
// infinite scale and then an unordered infinity * 0 conversion). Strict
// logitless decoding calls this before touching shared quantization scratch so
// malformed activations fail deterministically and leave the executor reusable.
int glacier_all_finite_f32_neon(const float *values, size_t count)
{
    const float32x4_t finite_max = vdupq_n_f32(FLT_MAX);
    size_t i = 0;
    for (; i + 3 < count; i += 4) {
        const float32x4_t candidates = vld1q_f32(values + i);
        const uint32x4_t finite = vcleq_f32(vabsq_f32(candidates), finite_max);
        if (vminvq_u32(finite) != UINT32_MAX) return 0;
    }
    for (; i < count; ++i) {
        if (!isfinite(values[i])) return 0;
    }
    return 1;
}

#if defined(__ARM_FEATURE_DOTPROD)
static inline void glacier_argmax_rows4_vector_update(
    float32x4_t values,
    size_t row0,
    float32x4_t *best_values,
    uint32x4_t *best_indices,
    uint32x4_t *nan_mask,
    int *valid)
{
    const uint32x4_t lane_indices = { 0, 1, 2, 3 };
    const uint32x4_t indices = vaddq_u32(
        vdupq_n_u32((uint32_t)row0), lane_indices);
    *nan_mask = vorrq_u32(
        *nan_mask, vmvnq_u32(vceqq_f32(values, values)));
    if (!*valid) {
        *best_values = values;
        *best_indices = indices;
        *valid = 1;
        return;
    }
    const uint32x4_t better = vcgtq_f32(values, *best_values);
    *best_values = vbslq_f32(better, values, *best_values);
    *best_indices = vbslq_u32(better, indices, *best_indices);
}
#endif

// Convert eight unsigned INT4 nibbles to two FP32 vectors in [-7, 8].
static inline void nibbles_to_f32(
    uint8x8_t nibbles,
    float32x4_t *low,
    float32x4_t *high)
{
    const uint16x8_t widened = vmovl_u8(nibbles);
    const int16x8_t centered = vsubq_s16(
        vreinterpretq_s16_u16(widened),
        vdupq_n_s16(7));
    *low = vcvtq_f32_s32(vmovl_s16(vget_low_s16(centered)));
    *high = vcvtq_f32_s32(vmovl_high_s16(centered));
}

static inline void accumulate_int4_block(
    const float *input,
    const uint8_t *packed,
    const float *scales,
    const __fp16 *scales_f16,
    size_t row_start,
    size_t col,
    unsigned group_shift,
    size_t next_scale,
    float32x4_t *acc0,
    float32x4_t *acc1,
    float32x4_t *acc2,
    float32x4_t *acc3)
{
    const uint8x8_t nibble_mask = vdup_n_u8(0x0f);
    const uint8x8_t bytes = vld1_u8(packed + ((row_start + col) >> 1));
    const uint8x8_t low = vand_u8(bytes, nibble_mask);
    const uint8x8_t high = vshr_n_u8(bytes, 4);
    const uint8x8x2_t interleaved = vzip_u8(low, high);

    float32x4_t weights0;
    float32x4_t weights1;
    float32x4_t weights2;
    float32x4_t weights3;
    nibbles_to_f32(interleaved.val[0], &weights0, &weights1);
    nibbles_to_f32(interleaved.val[1], &weights2, &weights3);

    const size_t scale_idx = (row_start + col) >> group_shift;
    const float scale0 = scales_f16 ? (float)scales_f16[scale_idx] : scales[scale_idx];
    const float scale1 = scales_f16 ? (float)scales_f16[scale_idx + next_scale] : scales[scale_idx + next_scale];
    *acc0 = vfmaq_n_f32(*acc0, vmulq_f32(weights0, vld1q_f32(input + col)), scale0);
    *acc1 = vfmaq_n_f32(*acc1, vmulq_f32(weights1, vld1q_f32(input + col + 4)), scale0);
    *acc2 = vfmaq_n_f32(*acc2, vmulq_f32(weights2, vld1q_f32(input + col + 8)), scale1);
    *acc3 = vfmaq_n_f32(*acc3, vmulq_f32(weights3, vld1q_f32(input + col + 12)), scale1);
}

static inline void accumulate_int4_block_direct(
    const float *input,
    const uint8_t *packed,
    float scale0,
    float scale1,
    float32x4_t *acc0,
    float32x4_t *acc1,
    float32x4_t *acc2,
    float32x4_t *acc3)
{
    const uint8x8_t bytes = vld1_u8(packed);
    const uint8x8_t low = vand_u8(bytes, vdup_n_u8(0x0f));
    const uint8x8_t high = vshr_n_u8(bytes, 4);
    const uint8x8x2_t interleaved = vzip_u8(low, high);
    float32x4_t weights0;
    float32x4_t weights1;
    float32x4_t weights2;
    float32x4_t weights3;
    nibbles_to_f32(interleaved.val[0], &weights0, &weights1);
    nibbles_to_f32(interleaved.val[1], &weights2, &weights3);
    *acc0 = vfmaq_n_f32(*acc0, vmulq_f32(weights0, vld1q_f32(input)), scale0);
    *acc1 = vfmaq_n_f32(*acc1, vmulq_f32(weights1, vld1q_f32(input + 4)), scale0);
    *acc2 = vfmaq_n_f32(*acc2, vmulq_f32(weights2, vld1q_f32(input + 8)), scale1);
    *acc3 = vfmaq_n_f32(*acc3, vmulq_f32(weights3, vld1q_f32(input + 12)), scale1);
}

static inline float load_scale_value(
    const float *scales,
    const __fp16 *scales_f16,
    size_t index)
{
    return scales_f16 ? (float)scales_f16[index] : scales[index];
}

#if defined(__ARM_FEATURE_DOTPROD)
static inline int32_t dot_i8x8(int8x8_t weights, int8x8_t activations)
{
    const int32x2_t dots = vdot_s32(vdup_n_s32(0), weights, activations);
    return vaddv_s32(dots);
}
#endif

// Fused AArch64 decode projection for group sizes 8 and 16. The Zig caller
// validates all shapes and payload lengths before entering this function.
// Each iteration loads eight packed bytes (16 weights), unpacks with NEON,
// applies the one or two group scales, and accumulates four independent lanes.
static void glacier_int4_matvec_neon_impl(
    const float *input,
    const uint8_t *packed,
    const float *scales,
    const __fp16 *scales_f16,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const unsigned group_shift = group_size == 8 ? 3 : 4;
    const size_t next_scale = group_size == 8;

    for (size_t row = 0; row < out_features; ++row) {
        float32x4_t acc0 = vdupq_n_f32(0.0f);
        float32x4_t acc1 = vdupq_n_f32(0.0f);
        float32x4_t acc2 = vdupq_n_f32(0.0f);
        float32x4_t acc3 = vdupq_n_f32(0.0f);
        float32x4_t acc4 = vdupq_n_f32(0.0f);
        float32x4_t acc5 = vdupq_n_f32(0.0f);
        float32x4_t acc6 = vdupq_n_f32(0.0f);
        float32x4_t acc7 = vdupq_n_f32(0.0f);
        const size_t row_start = row * in_features;

        size_t col = 0;
        for (; col + 32 <= in_features; col += 32) {
            accumulate_int4_block(input, packed, scales, scales_f16, row_start, col, group_shift, next_scale, &acc0, &acc1, &acc2, &acc3);
            accumulate_int4_block(input, packed, scales, scales_f16, row_start, col + 16, group_shift, next_scale, &acc4, &acc5, &acc6, &acc7);
        }
        for (; col < in_features; col += 16) {
            accumulate_int4_block(input, packed, scales, scales_f16, row_start, col, group_shift, next_scale, &acc0, &acc1, &acc2, &acc3);
        }

        const float32x4_t pair01 = vaddq_f32(acc0, acc1);
        const float32x4_t pair23 = vaddq_f32(acc2, acc3);
        const float pair45 = vaddvq_f32(vaddq_f32(acc4, acc5));
        const float pair67 = vaddvq_f32(vaddq_f32(acc6, acc7));
        const float dot = vaddvq_f32(vaddq_f32(pair01, pair23)) + pair45 + pair67;
        output[row] = dot + (bias ? bias[row] : 0.0f);
    }
}

// Pointer-increment version for the regular row-major g8/g16 layouts.  It
// avoids recomputing packed/scales indices for every 16-element block; the
// quantizer guarantees that rows and groups are aligned for these kernels.
static void glacier_int4_matvec_neon_contiguous(
    const float *input,
    const uint8_t *packed,
    const float *scales,
    const __fp16 *scales_f16,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    if ((group_size != 8 && group_size != 16) || in_features % 16 != 0) {
        glacier_int4_matvec_neon_impl(
            input, packed, scales, scales_f16, bias, output,
            out_features, in_features, group_size);
        return;
    }

    const int g8 = group_size == 8;
    for (size_t row = 0; row < out_features; ++row) {
        float32x4_t acc0 = vdupq_n_f32(0.0f);
        float32x4_t acc1 = vdupq_n_f32(0.0f);
        float32x4_t acc2 = vdupq_n_f32(0.0f);
        float32x4_t acc3 = vdupq_n_f32(0.0f);
        float32x4_t acc4 = vdupq_n_f32(0.0f);
        float32x4_t acc5 = vdupq_n_f32(0.0f);
        float32x4_t acc6 = vdupq_n_f32(0.0f);
        float32x4_t acc7 = vdupq_n_f32(0.0f);
        const uint8_t *packed_row = packed + row * (in_features >> 1);
        const size_t scales_per_row = in_features / group_size;
        const float *scales_row = scales ? scales + row * scales_per_row : NULL;
        const __fp16 *scales_f16_row = scales_f16 ? scales_f16 + row * scales_per_row : NULL;

        size_t col = 0;
        size_t scale = 0;
        for (; col + 32 <= in_features; col += 32) {
            const float s0 = load_scale_value(scales_row, scales_f16_row, scale);
            const float s1 = load_scale_value(scales_row, scales_f16_row, scale + (g8 ? 1 : 0));
            accumulate_int4_block_direct(input + col, packed_row + (col >> 1), s0, s1, &acc0, &acc1, &acc2, &acc3);
            const float s2 = load_scale_value(scales_row, scales_f16_row, scale + (g8 ? 2 : 1));
            const float s3 = load_scale_value(scales_row, scales_f16_row, scale + (g8 ? 3 : 1));
            accumulate_int4_block_direct(input + col + 16, packed_row + (col >> 1) + 8, s2, s3, &acc4, &acc5, &acc6, &acc7);
            scale += g8 ? 4 : 2;
        }
        for (; col < in_features; col += 16) {
            const float s0 = load_scale_value(scales_row, scales_f16_row, scale);
            const float s1 = load_scale_value(scales_row, scales_f16_row, scale + (g8 ? 1 : 0));
            accumulate_int4_block_direct(input + col, packed_row + (col >> 1), s0, s1, &acc0, &acc1, &acc2, &acc3);
            scale += g8 ? 2 : 1;
        }
        const float pair45 = vaddvq_f32(vaddq_f32(acc4, acc5));
        const float pair67 = vaddvq_f32(vaddq_f32(acc6, acc7));
        const float dot = vaddvq_f32(vaddq_f32(vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3))) + pair45 + pair67;
        output[row] = dot + (bias ? bias[row] : 0.0f);
    }
}

// Four-row GEMV microkernel.  The ordinary decode kernel walks one output
// row at a time, which reloads the same activation vectors for every row.
// Decode has batch=1, so the activation is the reusable operand: keep four
// rows live and feed them from one set of input loads.  Weight bytes remain
// streamed once per row, while the input-side NEON loads are shared 4:1.
// This is deliberately a separate fast path; the scalar-row implementation
// above remains the defensive fallback for unusual layouts.
static void glacier_int4_matvec_neon_rows4(
    const float *input,
    const uint8_t *packed,
    const float *scales,
    const __fp16 *scales_f16,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    if (group_size != 8 && group_size != 16) {
        glacier_int4_matvec_neon_contiguous(
            input, packed, scales, scales_f16, bias, output,
            out_features, in_features, group_size);
        return;
    }

    const size_t row_bytes = in_features >> 1;
    const size_t scales_per_row = in_features / group_size;
    const size_t row_groups = out_features / 4;
    const size_t g8 = group_size == 8;
    for (size_t tile = 0; tile < row_groups; ++tile) {
        float32x4_t acc[4][4];
        for (size_t r = 0; r < 4; ++r)
            for (size_t lane = 0; lane < 4; ++lane)
                acc[r][lane] = vdupq_n_f32(0.0f);

        const size_t row0 = tile * 4;
        const uint8_t *row_packed[4] = {
            packed + (row0 + 0) * row_bytes,
            packed + (row0 + 1) * row_bytes,
            packed + (row0 + 2) * row_bytes,
            packed + (row0 + 3) * row_bytes,
        };
        const float *row_scales[4] = {
            scales ? scales + (row0 + 0) * scales_per_row : NULL,
            scales ? scales + (row0 + 1) * scales_per_row : NULL,
            scales ? scales + (row0 + 2) * scales_per_row : NULL,
            scales ? scales + (row0 + 3) * scales_per_row : NULL,
        };
        const __fp16 *row_scales_f16[4] = {
            scales_f16 ? scales_f16 + (row0 + 0) * scales_per_row : NULL,
            scales_f16 ? scales_f16 + (row0 + 1) * scales_per_row : NULL,
            scales_f16 ? scales_f16 + (row0 + 2) * scales_per_row : NULL,
            scales_f16 ? scales_f16 + (row0 + 3) * scales_per_row : NULL,
        };

        for (size_t col = 0; col < in_features; col += 16) {
            const float32x4_t in0 = vld1q_f32(input + col + 0);
            const float32x4_t in1 = vld1q_f32(input + col + 4);
            const float32x4_t in2 = vld1q_f32(input + col + 8);
            const float32x4_t in3 = vld1q_f32(input + col + 12);
            const size_t scale_col = col / group_size;

            for (size_t r = 0; r < 4; ++r) {
                const uint8x8_t bytes = vld1_u8(row_packed[r] + (col >> 1));
                const uint8x8_t low = vand_u8(bytes, vdup_n_u8(0x0f));
                const uint8x8_t high = vshr_n_u8(bytes, 4);
                const uint8x8x2_t interleaved = vzip_u8(low, high);
                float32x4_t weights0;
                float32x4_t weights1;
                float32x4_t weights2;
                float32x4_t weights3;
                nibbles_to_f32(interleaved.val[0], &weights0, &weights1);
                nibbles_to_f32(interleaved.val[1], &weights2, &weights3);
                const float s0 = load_scale_value(row_scales[r], row_scales_f16[r], scale_col);
                const float s1 = load_scale_value(row_scales[r], row_scales_f16[r], scale_col + (g8 ? 1 : 0));
                acc[r][0] = vfmaq_n_f32(acc[r][0], vmulq_f32(weights0, in0), s0);
                acc[r][1] = vfmaq_n_f32(acc[r][1], vmulq_f32(weights1, in1), s0);
                acc[r][2] = vfmaq_n_f32(acc[r][2], vmulq_f32(weights2, in2), s1);
                acc[r][3] = vfmaq_n_f32(acc[r][3], vmulq_f32(weights3, in3), s1);
            }
        }
        for (size_t r = 0; r < 4; ++r) {
            const float sum = vaddvq_f32(acc[r][0]) + vaddvq_f32(acc[r][1]) +
                vaddvq_f32(acc[r][2]) + vaddvq_f32(acc[r][3]);
            output[row0 + r] = sum + (bias ? bias[row0 + r] : 0.0f);
        }
    }

    // A handful of matrices have a row count that is not divisible by four.
    // Reuse the existing kernel for the tail; its row pointers are still
    // valid and this path is outside the common Qwen decode shapes.
    const size_t tail_start = row_groups * 4;
    if (tail_start < out_features) {
        const size_t tail_packed = tail_start * row_bytes;
        const size_t tail_scales = tail_start * scales_per_row;
        glacier_int4_matvec_neon_contiguous(
            input,
            packed + tail_packed,
            scales ? scales + tail_scales : NULL,
            scales_f16 ? scales_f16 + tail_scales : NULL,
            bias ? bias + tail_start : NULL,
            output + tail_start,
            out_features - tail_start,
            in_features,
            group_size);
    }
}

void glacier_int4_matvec_neon_f32(
    const float *input,
    const uint8_t *packed,
    const float *scales,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    glacier_int4_matvec_neon_rows4(
        input, packed, scales, NULL, bias, output, out_features, in_features, group_size);
}

void glacier_int4_matvec_neon_f16scale(
    const float *input,
    const uint8_t *packed,
    const __fp16 *scales,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    glacier_int4_matvec_neon_rows4(
        input, packed, NULL, scales, bias, output, out_features, in_features, group_size);
}

// Q8 activation variant of the fused INT4 projection.  The activation is
// quantized independently for each weight group, so the only approximation
// is the symmetric int8 rounding; the original per-group INT4 scales remain
// unchanged.  This mirrors the blockwise integer dot-product strategy used
// by high-throughput local inference engines while retaining Glacier's
// simple on-disk format.
//
// The temporary Q8 activation and scales are shared by every output row.
// They are intentionally stack allocated: decode is one token at a time and
// in_features is bounded by the model's hidden width (not vocabulary size).
void glacier_q8_activation_quantize(
    const float *input,
    int8_t *q_input,
    float *activation_scales,
    size_t in_features,
    size_t group_size)
{
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t activation_groups =
        (in_features + activation_group_size - 1) / activation_group_size;
    for (size_t group = 0; group < activation_groups; ++group) {
        const size_t start = group * activation_group_size;
        const size_t end = start + activation_group_size < in_features
            ? start + activation_group_size : in_features;
        float max_abs = 0.0f;
        for (size_t col = start; col < end; ++col) {
            const float a = fabsf(input[col]);
            if (a > max_abs) max_abs = a;
        }
        const float scale = max_abs / 127.0f;
        activation_scales[group] = scale;
        if (scale == 0.0f) {
            memset(q_input + start, 0, end - start);
            continue;
        }
        const float inv_scale = 1.0f / scale;
        for (size_t col = start; col < end; ++col) {
            long q = lroundf(input[col] * inv_scale);
            if (q > 127) q = 127;
            if (q < -127) q = -127;
            q_input[col] = (int8_t)q;
        }
    }
}

void glacier_int4_matvec_neon_q8(
    const float *input,
    const uint8_t *packed,
    const float *scales,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    // A wider activation block amortizes scale calculation while preserving
    // the weight's finer g8 scales.  Q8_K-style blocks are especially useful
    // for the g8 quality profile; g16 naturally uses its own group size.
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t groups = (in_features + group_size - 1) / group_size;
    const size_t activation_groups =
        (in_features + activation_group_size - 1) / activation_group_size;
    int8_t q_input[in_features];
    float activation_scales[activation_groups];

    // Quantize once per input group. Every output row reuses this vector.
    glacier_q8_activation_quantize(
        input, q_input, activation_scales, in_features, group_size);

#if defined(__ARM_FEATURE_DOTPROD)
    // g16 is the quality profile's dominant format. Keep four output rows
    // live so each 16-lane activation vector is loaded once, while each row
    // still streams only its own eight packed weight bytes. This preserves
    // the exact Q8 arithmetic and removes the repeated activation loads from
    // the one-row kernel below.
    if ((group_size == 8 || group_size == 16) && in_features % 16 == 0 && out_features >= 4) {
        const size_t row_groups = out_features / 4;
        const size_t scales_per_row = in_features / group_size;
        for (size_t tile = 0; tile < row_groups; ++tile) {
            float acc[4] = {
                bias ? bias[tile * 4 + 0] : 0.0f,
                bias ? bias[tile * 4 + 1] : 0.0f,
                bias ? bias[tile * 4 + 2] : 0.0f,
                bias ? bias[tile * 4 + 3] : 0.0f,
            };
            const size_t row0 = tile * 4;
            for (size_t col = 0; col < in_features; col += 16) {
                const int8x16_t q_act = vld1q_s8(q_input + col);
                for (size_t r = 0; r < 4; ++r) {
                    const size_t row_start = (row0 + r) * in_features + col;
                    const uint8x8_t bytes = vld1_u8(packed + (row_start >> 1));
                    const uint8x8_t low = vand_u8(bytes, vdup_n_u8(0x0f));
                    const uint8x8_t high = vshr_n_u8(bytes, 4);
                    const uint8x8x2_t interleaved = vzip_u8(low, high);
                    const int8x16_t q_weight = vsubq_s8(
                        vreinterpretq_s8_u8(vcombine_u8(interleaved.val[0], interleaved.val[1])),
                        vdupq_n_s8(7));
                    const size_t scale_base = (row0 + r) * scales_per_row + col / group_size;
                    if (group_size == 8) {
                        const int32_t lo = dot_i8x8(vget_low_s8(q_weight), vget_low_s8(q_act));
                        const int32_t hi = dot_i8x8(vget_high_s8(q_weight), vget_high_s8(q_act));
                        acc[r] += (float)lo * scales[scale_base] * activation_scales[col / 32];
                        acc[r] += (float)hi * scales[scale_base + 1] * activation_scales[(col + 8) / 32];
                    } else {
                        const int32x4_t dots = vdotq_s32(vdupq_n_s32(0), q_weight, q_act);
                        acc[r] += (float)vaddvq_s32(dots) * scales[scale_base] *
                            activation_scales[col / 16];
                    }
                }
            }
            for (size_t r = 0; r < 4; ++r) output[row0 + r] = acc[r];
        }
        const size_t tail_start = row_groups * 4;
        for (size_t row = tail_start; row < out_features; ++row) {
            float acc = bias ? bias[row] : 0.0f;
            const size_t row_start = row * in_features;
            for (size_t col = 0; col < in_features; col += 16) {
                const uint8x8_t bytes = vld1_u8(packed + ((row_start + col) >> 1));
                const uint8x8_t low = vand_u8(bytes, vdup_n_u8(0x0f));
                const uint8x8_t high = vshr_n_u8(bytes, 4);
                const uint8x8x2_t interleaved = vzip_u8(low, high);
                const int8x16_t q_weight = vsubq_s8(
                    vreinterpretq_s8_u8(vcombine_u8(interleaved.val[0], interleaved.val[1])),
                    vdupq_n_s8(7));
                const size_t scale_base = row * scales_per_row + col / group_size;
                const int8x16_t q_act = vld1q_s8(q_input + col);
                if (group_size == 8) {
                    const int32_t lo = dot_i8x8(vget_low_s8(q_weight), vget_low_s8(q_act));
                    const int32_t hi = dot_i8x8(vget_high_s8(q_weight), vget_high_s8(q_act));
                    acc += (float)lo * scales[scale_base] * activation_scales[col / 32];
                    acc += (float)hi * scales[scale_base + 1] * activation_scales[(col + 8) / 32];
                } else {
                    const int32x4_t dots = vdotq_s32(vdupq_n_s32(0), q_weight, q_act);
                    acc += (float)vaddvq_s32(dots) * scales[scale_base] * activation_scales[col / 16];
                }
            }
            output[row] = acc;
        }
        return;
    }
#endif

#if defined(__ARM_FEATURE_DOTPROD)
    const uint8x8_t nibble_mask = vdup_n_u8(0x0f);

    // g8 is the dominant quality-profile format.  Consume four groups at a
    // time so one 16-byte packed load feeds two 16-lane nibble vectors.  The
    // previous implementation repeated the unpack/load sequence for every
    // pair of groups; this keeps the same per-group scales while reducing
    // loop and unpack overhead in the hot row loop.
    if (group_size == 8) {
        for (size_t row = 0; row < out_features; ++row) {
            float acc = bias ? bias[row] : 0.0f;
            const size_t row_start = row * in_features;
            size_t col = 0;
            for (; col + 32 <= in_features; col += 32) {
                const uint8x16_t bytes = vld1q_u8(packed + ((row_start + col) >> 1));
                const uint8x16_t low = vandq_u8(bytes, vdupq_n_u8(0x0f));
                const uint8x16_t high = vshrq_n_u8(bytes, 4);
                const int8x16_t weights0 = vsubq_s8(
                    vreinterpretq_s8_u8(vzip1q_u8(low, high)), vdupq_n_s8(7));
                const int8x16_t weights1 = vsubq_s8(
                    vreinterpretq_s8_u8(vzip2q_u8(low, high)), vdupq_n_s8(7));
                const int8x16_t activations0 = vld1q_s8(q_input + col);
                const int8x16_t activations1 = vld1q_s8(q_input + col + 16);
                const size_t scale_base = (row_start + col) >> 3;
                const float activation_scale = activation_scales[col >> 5];
                acc += (float)dot_i8x8(vget_low_s8(weights0), vget_low_s8(activations0)) *
                    scales[scale_base] * activation_scale;
                acc += (float)dot_i8x8(vget_high_s8(weights0), vget_high_s8(activations0)) *
                    scales[scale_base + 1] * activation_scale;
                acc += (float)dot_i8x8(vget_low_s8(weights1), vget_low_s8(activations1)) *
                    scales[scale_base + 2] * activation_scale;
                acc += (float)dot_i8x8(vget_high_s8(weights1), vget_high_s8(activations1)) *
                    scales[scale_base + 3] * activation_scale;
            }
            for (; col + 16 <= in_features; col += 16) {
                const uint8x8_t bytes = vld1_u8(packed + ((row_start + col) >> 1));
                const uint8x8_t low = vand_u8(bytes, nibble_mask);
                const uint8x8_t high = vshr_n_u8(bytes, 4);
                const uint8x8x2_t interleaved = vzip_u8(low, high);
                const int8x16_t weights = vsubq_s8(
                    vreinterpretq_s8_u8(vcombine_u8(interleaved.val[0], interleaved.val[1])),
                    vdupq_n_s8(7));
                const int8x16_t activations = vld1q_s8(q_input + col);
                const size_t scale_base = (row_start + col) >> 3;
                const float activation_scale = activation_scales[col >> 5];
                acc += (float)dot_i8x8(vget_low_s8(weights), vget_low_s8(activations)) *
                    scales[scale_base] * activation_scale;
                acc += (float)dot_i8x8(vget_high_s8(weights), vget_high_s8(activations)) *
                    scales[scale_base + 1] * activation_scale;
            }
            // C callers validate a multiple-of-16 width; retain a scalar
            // tail for the standalone kernel's defensive use.
            for (; col < in_features; ++col) {
                const size_t idx = row_start + col;
                const uint8_t packed_byte = packed[idx >> 1];
                const int8_t weight = (int8_t)((idx & 1) ?
                    ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                acc += (float)weight * (float)q_input[col] *
                    scales[idx >> 3] * activation_scales[col >> 5];
            }
            output[row] = acc;
        }
        return;
    }
#endif

    for (size_t row = 0; row < out_features; ++row) {
        float acc = bias ? bias[row] : 0.0f;
        const size_t row_start = row * in_features;
        size_t group = 0;
        while (group < groups) {
            const size_t col_start = group * group_size;
            const size_t count = col_start + group_size < in_features
                ? group_size : in_features - col_start;

            // Fast block path: one 16-element load produces all nibbles for
            // g16, or two independently scaled halves for g8.  Apple M1 and
            // newer ARM64 targets expose SDOT, which accumulates four signed
            // int8 products per lane in one instruction.
            if ((group_size == 16 && count >= 16) ||
                (group_size == 8 && group + 1 < groups)) {
#if defined(__ARM_FEATURE_DOTPROD)
                const size_t packed_off = (row_start + col_start) >> 1;
                const uint8x8_t bytes = vld1_u8(packed + packed_off);
                const uint8x8_t low = vand_u8(bytes, nibble_mask);
                const uint8x8_t high = vshr_n_u8(bytes, 4);
                const uint8x8x2_t interleaved = vzip_u8(low, high);
                const int8x16_t q_weight = vsubq_s8(
                    vreinterpretq_s8_u8(vcombine_u8(interleaved.val[0], interleaved.val[1])),
                    vdupq_n_s8(7));
                const int8x16_t q_act = vld1q_s8(q_input + col_start);
                if (group_size == 16) {
                    const int32x4_t dot_vec = vdotq_s32(vdupq_n_s32(0), q_weight, q_act);
                    const int32_t dot = vaddvq_s32(dot_vec);
                    acc += (float)dot * scales[(row_start + col_start) / group_size] *
                        activation_scales[col_start / activation_group_size];
                } else {
                    const int32x2_t dot_lo_vec = vdot_s32(vdup_n_s32(0), vget_low_s8(q_weight), vget_low_s8(q_act));
                    const int32x2_t dot_hi_vec = vdot_s32(vdup_n_s32(0), vget_high_s8(q_weight), vget_high_s8(q_act));
                    const int32_t dot_lo = vaddv_s32(dot_lo_vec);
                    const int32_t dot_hi = vaddv_s32(dot_hi_vec);
                    acc += (float)dot_lo * scales[(row_start + col_start) / group_size] *
                        activation_scales[col_start / activation_group_size];
                    acc += (float)dot_hi * scales[(row_start + col_start + 8) / group_size] *
                        activation_scales[(col_start + 8) / activation_group_size];
                }
                group += group_size == 16 ? 1 : 2;
                continue;
#else
                int32_t dot = 0;
                for (size_t lane = 0; lane < 16; ++lane) {
                    const size_t idx = row_start + col_start + lane;
                    const uint8_t packed_byte = packed[idx >> 1];
                    const int8_t q_weight = (int8_t)((idx & 1) ?
                        ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                    dot += (int32_t)q_weight * (int32_t)q_input[col_start + lane];
                }
                if (group_size == 16) {
                    acc += (float)dot * scales[(row_start + col_start) / group_size] *
                        activation_scales[col_start / activation_group_size];
                } else {
                    // The portable fallback cannot cheaply split the two
                    // scales from one 16-lane block; use the scalar path for
                    // g8 when SDOT is unavailable.
                    for (size_t lane = 0; lane < 16; ++lane) {
                        const size_t idx = row_start + col_start + lane;
                        const uint8_t packed_byte = packed[idx >> 1];
                        const int8_t q_weight = (int8_t)((idx & 1) ?
                            ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                        const float term = (float)q_weight * (float)q_input[col_start + lane];
                        acc += term * scales[(row_start + col_start + lane) / group_size] *
                            activation_scales[(col_start + lane) / activation_group_size];
                    }
                }
                group += group_size == 16 ? 1 : 2;
                continue;
#endif
            }

            // Scalar/vector fallback for a final partial group.
            int32_t dot = 0;
            for (size_t col = 0; col < count; ++col) {
                const size_t idx = row_start + col_start + col;
                const uint8_t packed_byte = packed[idx >> 1];
                const int8_t q_weight = (int8_t)((idx & 1) ?
                    ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                dot += (int32_t)q_weight * (int32_t)q_input[col_start + col];
            }
            acc += (float)dot * scales[(row_start + col_start) / group_size] *
                activation_scales[col_start / activation_group_size];
            ++group;
        }
        output[row] = acc;
    }
}

// Packed projection with an activation that was quantized by the caller.
// A projection batch can share q_input/scales across Q/K/V instead of paying
// the conversion three times on every worker shard.
static void glacier_int4_matvec_neon_q8_prequant_impl(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *packed,
    const float *scales,
    const __fp16 *scales_f16,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
#if defined(__ARM_FEATURE_DOTPROD)
    if ((group_size == 8 || group_size == 16) && in_features % 16 == 0) {
        const size_t row_groups = out_features / 4;
        const size_t scales_per_row = in_features / group_size;
        for (size_t tile = 0; tile < row_groups; ++tile) {
            const size_t row0 = tile * 4;
            float acc[4] = {
                bias ? bias[tile * 4 + 0] : 0.0f,
                bias ? bias[tile * 4 + 1] : 0.0f,
                bias ? bias[tile * 4 + 2] : 0.0f,
                bias ? bias[tile * 4 + 3] : 0.0f,
            };
            for (size_t col = 0; col < in_features; col += 16) {
                const int8x16_t q_act = vld1q_s8(q_input + col);
                for (size_t r = 0; r < 4; ++r) {
                    const size_t row_start = (row0 + r) * in_features + col;
                    const uint8x8_t bytes = vld1_u8(packed + (row_start >> 1));
                    const uint8x8_t low = vand_u8(bytes, vdup_n_u8(0x0f));
                    const uint8x8_t high = vshr_n_u8(bytes, 4);
                    const uint8x8x2_t interleaved = vzip_u8(low, high);
                    const int8x16_t q_weight = vsubq_s8(
                        vreinterpretq_s8_u8(vcombine_u8(interleaved.val[0], interleaved.val[1])),
                        vdupq_n_s8(7));
                    const size_t scale_base = (row0 + r) * scales_per_row + col / group_size;
                    if (group_size == 8) {
                        const int32_t lo = dot_i8x8(vget_low_s8(q_weight), vget_low_s8(q_act));
                        const int32_t hi = dot_i8x8(vget_high_s8(q_weight), vget_high_s8(q_act));
                        acc[r] += (float)lo * load_scale_value(scales, scales_f16, scale_base) *
                            activation_scales[col / 32];
                        acc[r] += (float)hi * load_scale_value(scales, scales_f16, scale_base + 1) *
                            activation_scales[(col + 8) / 32];
                    } else {
                        const int32x4_t dots = vdotq_s32(vdupq_n_s32(0), q_weight, q_act);
                        acc[r] += (float)vaddvq_s32(dots) *
                            load_scale_value(scales, scales_f16, scale_base) *
                            activation_scales[col / 16];
                    }
                }
            }
            for (size_t r = 0; r < 4; ++r) output[row0 + r] = acc[r];
        }
        const size_t tail_start = row_groups * 4;
        for (size_t row = tail_start; row < out_features; ++row) {
            float acc = bias ? bias[row] : 0.0f;
            const size_t row_start = row * in_features;
            for (size_t col = 0; col < in_features; col += 16) {
                const uint8x8_t bytes = vld1_u8(packed + ((row_start + col) >> 1));
                const uint8x8_t low = vand_u8(bytes, vdup_n_u8(0x0f));
                const uint8x8_t high = vshr_n_u8(bytes, 4);
                const uint8x8x2_t interleaved = vzip_u8(low, high);
                const int8x16_t q_weight = vsubq_s8(
                    vreinterpretq_s8_u8(vcombine_u8(interleaved.val[0], interleaved.val[1])),
                    vdupq_n_s8(7));
                const size_t scale_base = row * scales_per_row + col / group_size;
                const int8x16_t q_act = vld1q_s8(q_input + col);
                if (group_size == 8) {
                    const int32_t lo = dot_i8x8(vget_low_s8(q_weight), vget_low_s8(q_act));
                    const int32_t hi = dot_i8x8(vget_high_s8(q_weight), vget_high_s8(q_act));
                    acc += (float)lo * load_scale_value(scales, scales_f16, scale_base) *
                        activation_scales[col / 32];
                    acc += (float)hi * load_scale_value(scales, scales_f16, scale_base + 1) *
                        activation_scales[(col + 8) / 32];
                } else {
                    const int32x4_t dots = vdotq_s32(vdupq_n_s32(0), q_weight, q_act);
                    acc += (float)vaddvq_s32(dots) *
                        load_scale_value(scales, scales_f16, scale_base) *
                        activation_scales[col / 16];
                }
            }
            output[row] = acc;
        }
        return;
    }
#endif
    // Generic AArch64 fallback for CPUs compiled without the dot-product
    // extension. Keep the prepared-activation API numerically valid instead
    // of making executor correctness depend on a compile-time SDOT feature.
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t groups = (in_features + group_size - 1) / group_size;
    for (size_t row = 0; row < out_features; ++row) {
        float acc = bias ? bias[row] : 0.0f;
        const size_t row_start = row * in_features;
        for (size_t group = 0; group < groups; ++group) {
            const size_t col_start = group * group_size;
            const size_t count = col_start + group_size < in_features
                ? group_size : in_features - col_start;
            int32_t dot = 0;
            for (size_t col = 0; col < count; ++col) {
                const size_t idx = row_start + col_start + col;
                const uint8_t packed_byte = packed[idx >> 1];
                const int8_t q_weight = (int8_t)((idx & 1) ?
                    ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                dot += (int32_t)q_weight * (int32_t)q_input[col_start + col];
            }
            acc += (float)dot *
                load_scale_value(scales, scales_f16, (row_start + col_start) / group_size) *
                activation_scales[col_start / activation_group_size];
        }
        output[row] = acc;
    }
}

void glacier_int4_matvec_neon_q8_prequant(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *packed,
    const float *scales,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    glacier_int4_matvec_neon_q8_prequant_impl(
        q_input, activation_scales, packed, scales, NULL, bias, output,
        out_features, in_features, group_size);
}

void glacier_int4_matvec_neon_q8_prequant_f16scale(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *packed,
    const __fp16 *scales,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    glacier_int4_matvec_neon_q8_prequant_impl(
        q_input, activation_scales, packed, NULL, scales, bias, output,
        out_features, in_features, group_size);
}

// FP16 scales interleaved as [row_tile][k_group][row_lane]. Packed weights
// stay row-major, preserving the on-disk representation; only the much
// smaller scale stream is reshaped so four row scales become one vector load.
void glacier_int4_matvec_neon_q8_prequant_f16scale_rows4(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *packed,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t scales_per_row = in_features / group_size;
    size_t processed_rows = 0;
#if defined(__ARM_FEATURE_DOTPROD)
    const size_t row_groups = out_features / 4;
    if ((group_size == 8 || group_size == 16) && in_features % 16 == 0) {
        for (size_t tile = 0; tile < row_groups; ++tile) {
            const size_t row0 = tile * 4;
            float32x4_t acc = bias ? vld1q_f32(bias + row0) : vdupq_n_f32(0.0f);
            for (size_t col = 0; col < in_features; col += 16) {
                const int8x16_t q_act = vld1q_s8(q_input + col);
                int32_t dots0[4];
                int32_t dots1[4];
                for (size_t r = 0; r < 4; ++r) {
                    const size_t row_start = (row0 + r) * in_features + col;
                    const uint8x8_t bytes = vld1_u8(packed + (row_start >> 1));
                    const uint8x8_t low = vand_u8(bytes, vdup_n_u8(0x0f));
                    const uint8x8_t high = vshr_n_u8(bytes, 4);
                    const uint8x8x2_t interleaved = vzip_u8(low, high);
                    const int8x16_t q_weight = vsubq_s8(
                        vreinterpretq_s8_u8(vcombine_u8(interleaved.val[0], interleaved.val[1])),
                        vdupq_n_s8(7));
                    if (group_size == 8) {
                        dots0[r] = dot_i8x8(vget_low_s8(q_weight), vget_low_s8(q_act));
                        dots1[r] = dot_i8x8(vget_high_s8(q_weight), vget_high_s8(q_act));
                    } else {
                        dots0[r] = vaddvq_s32(vdotq_s32(
                            vdupq_n_s32(0), q_weight, q_act));
                    }
                }
                const size_t scale_group = col / group_size;
                const float32x4_t weight_scales0 = vcvt_f32_f16(vld1_f16(
                    scales_rows4 + (tile * scales_per_row + scale_group) * 4));
                const float32x4_t values0 = vmulq_f32(
                    vcvtq_f32_s32(vld1q_s32(dots0)), weight_scales0);
                acc = vfmaq_n_f32(
                    acc,
                    values0,
                    activation_scales[col / (group_size == 8 ? 32 : 16)]);
                if (group_size == 8) {
                    const float32x4_t weight_scales1 = vcvt_f32_f16(vld1_f16(
                        scales_rows4 + (tile * scales_per_row + scale_group + 1) * 4));
                    const float32x4_t values1 = vmulq_f32(
                        vcvtq_f32_s32(vld1q_s32(dots1)), weight_scales1);
                    acc = vfmaq_n_f32(
                        acc, values1, activation_scales[(col + 8) / 32]);
                }
            }
            vst1q_f32(output + row0, acc);
        }
        processed_rows = row_groups * 4;
    }
#endif

    // Defensive tail and non-SDOT fallback. The layout remains valid for
    // scalar access; normal projection shards are multiples of four rows.
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t groups = (in_features + group_size - 1) / group_size;
    const size_t tail_start = processed_rows;
    for (size_t row = tail_start; row < out_features; ++row) {
        float acc = bias ? bias[row] : 0.0f;
        const size_t row_start = row * in_features;
        for (size_t group = 0; group < groups; ++group) {
            const size_t col_start = group * group_size;
            const size_t count = col_start + group_size < in_features
                ? group_size : in_features - col_start;
            int32_t dot = 0;
            for (size_t col = 0; col < count; ++col) {
                const size_t idx = row_start + col_start + col;
                const uint8_t packed_byte = packed[idx >> 1];
                const int8_t q_weight = (int8_t)((idx & 1) ?
                    ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                dot += (int32_t)q_weight * (int32_t)q_input[col_start + col];
            }
            const size_t scale_index =
                ((row / 4) * scales_per_row + group) * 4 + row % 4;
            acc += (float)dot * (float)scales_rows4[scale_index] *
                activation_scales[col_start / activation_group_size];
        }
        output[row] = acc;
    }
}

#if defined(__ARM_FEATURE_DOTPROD)
static inline void unpack_rows4_k16_pair(
    const uint8_t *packed,
    int8x16_t *first,
    int8x16_t *second)
{
    const uint8x16_t bytes = vld1q_u8(packed);
    const uint8x16_t low = vandq_u8(bytes, vdupq_n_u8(0x0f));
    const uint8x16_t high = vshrq_n_u8(bytes, 4);
    const int8x16_t offset = vdupq_n_s8(7);
    *first = vsubq_s8(vreinterpretq_s8_u8(vzip1q_u8(low, high)), offset);
    *second = vsubq_s8(vreinterpretq_s8_u8(vzip2q_u8(low, high)), offset);
}

static inline float32x4_t accumulate_rows4_k16_g8(
    float32x4_t acc,
    int8x16_t q_act,
    const uint8_t *block,
    const __fp16 *scales,
    float activation_scale0,
    float activation_scale1)
{
    int8x16_t weights0;
    int8x16_t weights1;
    int8x16_t weights2;
    int8x16_t weights3;
    unpack_rows4_k16_pair(block, &weights0, &weights1);
    unpack_rows4_k16_pair(block + 16, &weights2, &weights3);
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

static inline float32x4_t accumulate_rows4_k16_g16(
    float32x4_t acc,
    int8x16_t q_act,
    const uint8_t *block,
    const __fp16 *scales,
    float activation_scale)
{
    int8x16_t weights0;
    int8x16_t weights1;
    int8x16_t weights2;
    int8x16_t weights3;
    unpack_rows4_k16_pair(block, &weights0, &weights1);
    unpack_rows4_k16_pair(block + 16, &weights2, &weights3);
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

static inline size_t rows4_k16_nibble_index(
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

// Weight layout: [row_tile][K16 block][K4 chunk][row_lane][K4]. Each K4
// chunk becomes one SDOT operand and each activation K4 is selected as a
// lane. Four output rows are therefore accumulated in one int32x4 vector.
int glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16_v2(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *packed,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size,
    glacier_argmax_result *argmax)
{
    // V2 is deliberately argmax-only. Keeping the materialized kernel below
    // separate preserves its established branch-free hot loop and lets this
    // kernel keep the winner entirely in registers until final reduction.
    if (output != NULL || argmax == NULL || out_features > UINT32_MAX) return 0;
    float best_value = -INFINITY;
    size_t best_index = 0;
    int best_valid = 0;
    int saw_nan = 0;
    float32x4_t lane_best_values = vdupq_n_f32(-INFINITY);
    uint32x4_t lane_best_indices = vdupq_n_u32(0);
    uint32x4_t lane_nan_mask = vdupq_n_u32(0);
    int lane_best_valid = 0;
    const size_t scales_per_row = in_features / group_size;
    size_t processed_rows = 0;
#if defined(__ARM_FEATURE_DOTPROD)
    if ((group_size == 8 || group_size == 16) &&
        out_features % 4 == 0 && in_features % 16 == 0) {
        const size_t row_tiles = out_features / 4;
        size_t tile = 0;
        if (group_size == 8) {
            // Four independent K accumulators expose enough instruction-level
            // parallelism to overlap nibble unpack, SDOT, half conversion,
            // and packed-weight loads on Apple performance cores.
            for (; tile < row_tiles; ++tile) {
                const size_t row0 = tile * 4;
                float32x4_t acc0 = bias ? vld1q_f32(bias + row0) : vdupq_n_f32(0.0f);
                float32x4_t acc1 = vdupq_n_f32(0.0f);
                float32x4_t acc2 = vdupq_n_f32(0.0f);
                float32x4_t acc3 = vdupq_n_f32(0.0f);
                const uint8_t *tile_weights = packed + tile * (2 * in_features);
                const __fp16 *tile_scales = scales_rows4 + tile * scales_per_row * 4;
                size_t col = 0;
                for (; col + 63 < in_features; col += 64) {
                    acc0 = accumulate_rows4_k16_g8(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 8) * 4,
                        activation_scales[col / 32], activation_scales[(col + 8) / 32]);
                    acc1 = accumulate_rows4_k16_g8(
                        acc1, vld1q_s8(q_input + col + 16),
                        tile_weights + (col + 16) * 2, tile_scales + ((col + 16) / 8) * 4,
                        activation_scales[(col + 16) / 32], activation_scales[(col + 24) / 32]);
                    acc2 = accumulate_rows4_k16_g8(
                        acc2, vld1q_s8(q_input + col + 32),
                        tile_weights + (col + 32) * 2, tile_scales + ((col + 32) / 8) * 4,
                        activation_scales[(col + 32) / 32], activation_scales[(col + 40) / 32]);
                    acc3 = accumulate_rows4_k16_g8(
                        acc3, vld1q_s8(q_input + col + 48),
                        tile_weights + (col + 48) * 2, tile_scales + ((col + 48) / 8) * 4,
                        activation_scales[(col + 48) / 32], activation_scales[(col + 56) / 32]);
                }
                for (; col < in_features; col += 16) {
                    acc0 = accumulate_rows4_k16_g8(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 8) * 4,
                        activation_scales[col / 32], activation_scales[(col + 8) / 32]);
                }
                const float32x4_t result = vaddq_f32(
                    vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3));
                glacier_argmax_rows4_vector_update(
                    result, row0, &lane_best_values, &lane_best_indices,
                    &lane_nan_mask, &lane_best_valid);
            }
        } else {
            for (; tile < row_tiles; ++tile) {
                const size_t row0 = tile * 4;
                float32x4_t acc0 = bias ? vld1q_f32(bias + row0) : vdupq_n_f32(0.0f);
                float32x4_t acc1 = vdupq_n_f32(0.0f);
                float32x4_t acc2 = vdupq_n_f32(0.0f);
                float32x4_t acc3 = vdupq_n_f32(0.0f);
                const uint8_t *tile_weights = packed + tile * (2 * in_features);
                const __fp16 *tile_scales = scales_rows4 + tile * scales_per_row * 4;
                size_t col = 0;
                for (; col + 63 < in_features; col += 64) {
                    acc0 = accumulate_rows4_k16_g16(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 16) * 4,
                        activation_scales[col / 16]);
                    acc1 = accumulate_rows4_k16_g16(
                        acc1, vld1q_s8(q_input + col + 16),
                        tile_weights + (col + 16) * 2, tile_scales + ((col + 16) / 16) * 4,
                        activation_scales[(col + 16) / 16]);
                    acc2 = accumulate_rows4_k16_g16(
                        acc2, vld1q_s8(q_input + col + 32),
                        tile_weights + (col + 32) * 2, tile_scales + ((col + 32) / 16) * 4,
                        activation_scales[(col + 32) / 16]);
                    acc3 = accumulate_rows4_k16_g16(
                        acc3, vld1q_s8(q_input + col + 48),
                        tile_weights + (col + 48) * 2, tile_scales + ((col + 48) / 16) * 4,
                        activation_scales[(col + 48) / 16]);
                }
                for (; col < in_features; col += 16) {
                    acc0 = accumulate_rows4_k16_g16(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 16) * 4,
                        activation_scales[col / 16]);
                }
                const float32x4_t result = vaddq_f32(
                    vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3));
                glacier_argmax_rows4_vector_update(
                    result, row0, &lane_best_values, &lane_best_indices,
                    &lane_nan_mask, &lane_best_valid);
            }
        }
        processed_rows = out_features;
    }
#endif

    // Portable correctness fallback for generic AArch64 builds without
    // dot-product support. Production Apple Silicon always takes SDOT above.
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t groups = (in_features + group_size - 1) / group_size;
    for (size_t row = processed_rows; row < out_features; ++row) {
        float acc = bias ? bias[row] : 0.0f;
        for (size_t group = 0; group < groups; ++group) {
            const size_t col_start = group * group_size;
            const size_t count = col_start + group_size < in_features
                ? group_size : in_features - col_start;
            int32_t dot = 0;
            for (size_t col = 0; col < count; ++col) {
                const size_t nibble_index = rows4_k16_nibble_index(
                    row, col_start + col, in_features);
                const uint8_t packed_byte = packed[nibble_index >> 1];
                const int8_t q_weight = (int8_t)((nibble_index & 1) ?
                    ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                dot += (int32_t)q_weight * (int32_t)q_input[col_start + col];
            }
            const size_t scale_index =
                ((row / 4) * scales_per_row + group) * 4 + row % 4;
            acc += (float)dot * (float)scales_rows4[scale_index] *
                activation_scales[col_start / activation_group_size];
        }
        if (isnan(acc)) {
            saw_nan = 1;
        } else if (!best_valid || acc > best_value ||
                   (acc == best_value && row < best_index)) {
            best_value = acc;
            best_index = row;
            best_valid = 1;
        }
    }
    if (lane_best_valid) {
        float lane_values[4];
        uint32_t lane_indices[4];
        vst1q_f32(lane_values, lane_best_values);
        vst1q_u32(lane_indices, lane_best_indices);
        saw_nan = vmaxvq_u32(lane_nan_mask) != 0;
        best_value = lane_values[0];
        best_index = lane_indices[0];
        best_valid = 1;
        for (size_t lane = 1; lane < 4; ++lane) {
            if (lane_values[lane] > best_value ||
                (lane_values[lane] == best_value &&
                 lane_indices[lane] < best_index)) {
                best_value = lane_values[lane];
                best_index = lane_indices[lane];
            }
        }
    }
    argmax->value = best_value;
    argmax->index = best_index;
    argmax->valid = best_valid;
    argmax->saw_nan = saw_nan;
    return best_valid && !saw_nan;
}

// Preserve the established nine-argument C ABI and branch-free hot loop for
// materialized, prepared, and sealed callers. Strict logitless decoding binds
// the separate versioned v2 symbol above, so neither mode pays the other's
// per-row branch and stale callers cannot cross the ABI boundary accidentally.
void glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *packed,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t scales_per_row = in_features / group_size;
    size_t processed_rows = 0;
#if defined(__ARM_FEATURE_DOTPROD)
    if ((group_size == 8 || group_size == 16) &&
        out_features % 4 == 0 && in_features % 16 == 0) {
        const size_t row_tiles = out_features / 4;
        size_t tile = 0;
        if (group_size == 8) {
            // Four independent K accumulators expose enough instruction-level
            // parallelism to overlap nibble unpack, SDOT, half conversion,
            // and packed-weight loads on Apple performance cores.
            for (; tile < row_tiles; ++tile) {
                const size_t row0 = tile * 4;
                float32x4_t acc0 = bias ? vld1q_f32(bias + row0) : vdupq_n_f32(0.0f);
                float32x4_t acc1 = vdupq_n_f32(0.0f);
                float32x4_t acc2 = vdupq_n_f32(0.0f);
                float32x4_t acc3 = vdupq_n_f32(0.0f);
                const uint8_t *tile_weights = packed + tile * (2 * in_features);
                const __fp16 *tile_scales = scales_rows4 + tile * scales_per_row * 4;
                size_t col = 0;
                for (; col + 63 < in_features; col += 64) {
                    acc0 = accumulate_rows4_k16_g8(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 8) * 4,
                        activation_scales[col / 32], activation_scales[(col + 8) / 32]);
                    acc1 = accumulate_rows4_k16_g8(
                        acc1, vld1q_s8(q_input + col + 16),
                        tile_weights + (col + 16) * 2, tile_scales + ((col + 16) / 8) * 4,
                        activation_scales[(col + 16) / 32], activation_scales[(col + 24) / 32]);
                    acc2 = accumulate_rows4_k16_g8(
                        acc2, vld1q_s8(q_input + col + 32),
                        tile_weights + (col + 32) * 2, tile_scales + ((col + 32) / 8) * 4,
                        activation_scales[(col + 32) / 32], activation_scales[(col + 40) / 32]);
                    acc3 = accumulate_rows4_k16_g8(
                        acc3, vld1q_s8(q_input + col + 48),
                        tile_weights + (col + 48) * 2, tile_scales + ((col + 48) / 8) * 4,
                        activation_scales[(col + 48) / 32], activation_scales[(col + 56) / 32]);
                }
                for (; col < in_features; col += 16) {
                    acc0 = accumulate_rows4_k16_g8(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 8) * 4,
                        activation_scales[col / 32], activation_scales[(col + 8) / 32]);
                }
                vst1q_f32(output + row0, vaddq_f32(
                    vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3)));
            }
        } else {
            for (; tile < row_tiles; ++tile) {
                const size_t row0 = tile * 4;
                float32x4_t acc0 = bias ? vld1q_f32(bias + row0) : vdupq_n_f32(0.0f);
                float32x4_t acc1 = vdupq_n_f32(0.0f);
                float32x4_t acc2 = vdupq_n_f32(0.0f);
                float32x4_t acc3 = vdupq_n_f32(0.0f);
                const uint8_t *tile_weights = packed + tile * (2 * in_features);
                const __fp16 *tile_scales = scales_rows4 + tile * scales_per_row * 4;
                size_t col = 0;
                for (; col + 63 < in_features; col += 64) {
                    acc0 = accumulate_rows4_k16_g16(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 16) * 4,
                        activation_scales[col / 16]);
                    acc1 = accumulate_rows4_k16_g16(
                        acc1, vld1q_s8(q_input + col + 16),
                        tile_weights + (col + 16) * 2, tile_scales + ((col + 16) / 16) * 4,
                        activation_scales[(col + 16) / 16]);
                    acc2 = accumulate_rows4_k16_g16(
                        acc2, vld1q_s8(q_input + col + 32),
                        tile_weights + (col + 32) * 2, tile_scales + ((col + 32) / 16) * 4,
                        activation_scales[(col + 32) / 16]);
                    acc3 = accumulate_rows4_k16_g16(
                        acc3, vld1q_s8(q_input + col + 48),
                        tile_weights + (col + 48) * 2, tile_scales + ((col + 48) / 16) * 4,
                        activation_scales[(col + 48) / 16]);
                }
                for (; col < in_features; col += 16) {
                    acc0 = accumulate_rows4_k16_g16(
                        acc0, vld1q_s8(q_input + col),
                        tile_weights + col * 2, tile_scales + (col / 16) * 4,
                        activation_scales[col / 16]);
                }
                vst1q_f32(output + row0, vaddq_f32(
                    vaddq_f32(acc0, acc1), vaddq_f32(acc2, acc3)));
            }
        }
        processed_rows = out_features;
    }
#endif

    // Portable correctness fallback for generic AArch64 builds without
    // dot-product support. Production Apple Silicon always takes SDOT above.
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t groups = (in_features + group_size - 1) / group_size;
    for (size_t row = processed_rows; row < out_features; ++row) {
        float acc = bias ? bias[row] : 0.0f;
        for (size_t group = 0; group < groups; ++group) {
            const size_t col_start = group * group_size;
            const size_t count = col_start + group_size < in_features
                ? group_size : in_features - col_start;
            int32_t dot = 0;
            for (size_t col = 0; col < count; ++col) {
                const size_t nibble_index = rows4_k16_nibble_index(
                    row, col_start + col, in_features);
                const uint8_t packed_byte = packed[nibble_index >> 1];
                const int8_t q_weight = (int8_t)((nibble_index & 1) ?
                    ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                dot += (int32_t)q_weight * (int32_t)q_input[col_start + col];
            }
            const size_t scale_index =
                ((row / 4) * scales_per_row + group) * 4 + row % 4;
            acc += (float)dot * (float)scales_rows4[scale_index] *
                activation_scales[col_start / activation_group_size];
        }
        output[row] = acc;
    }
}

#if defined(__ARM_FEATURE_DOTPROD)
static inline float32x4_t accumulate_rows4_k16_g8_unpacked(
    float32x4_t acc,
    int8x16_t q_act,
    int8x16_t weights0,
    int8x16_t weights1,
    int8x16_t weights2,
    int8x16_t weights3,
    float32x4_t weight_scales0,
    float32x4_t weight_scales1,
    float activation_scale0,
    float activation_scale1)
{
    int32x4_t dots0 = vdotq_laneq_s32(
        vdupq_n_s32(0), weights0, q_act, 0);
    dots0 = vdotq_laneq_s32(dots0, weights1, q_act, 1);
    int32x4_t dots1 = vdotq_laneq_s32(
        vdupq_n_s32(0), weights2, q_act, 2);
    dots1 = vdotq_laneq_s32(dots1, weights3, q_act, 3);
    acc = vfmaq_n_f32(
        acc,
        vmulq_f32(vcvtq_f32_s32(dots0), weight_scales0),
        activation_scale0);
    return vfmaq_n_f32(
        acc,
        vmulq_f32(vcvtq_f32_s32(dots1), weight_scales1),
        activation_scale1);
}

static inline float32x4_t accumulate_rows4_k16_g16_unpacked(
    float32x4_t acc,
    int8x16_t q_act,
    int8x16_t weights0,
    int8x16_t weights1,
    int8x16_t weights2,
    int8x16_t weights3,
    float32x4_t weight_scales,
    float activation_scale)
{
    int32x4_t dots = vdotq_laneq_s32(
        vdupq_n_s32(0), weights0, q_act, 0);
    dots = vdotq_laneq_s32(dots, weights1, q_act, 1);
    dots = vdotq_laneq_s32(dots, weights2, q_act, 2);
    dots = vdotq_laneq_s32(dots, weights3, q_act, 3);
    return vfmaq_n_f32(
        acc,
        vmulq_f32(vcvtq_f32_s32(dots), weight_scales),
        activation_scale);
}
#endif

// Four-token packed GEMM microkernel. It preserves the one-token kernel's
// four-way K64 accumulation tree, but unpacks each rows4/K16 weight block once
// and applies it to four independent Q8 activation rows. Output rows may be a
// shard of a larger row-major matrix; output_stride is measured in floats.
void glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
    const int8_t *q_inputs,
    const float *activation_scales,
    const uint8_t *packed,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t batch,
    size_t out_features,
    size_t in_features,
    size_t group_size,
    size_t output_stride)
{
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t activation_scale_stride =
        (in_features + activation_group_size - 1) / activation_group_size;
    size_t token = 0;

#if defined(__ARM_FEATURE_DOTPROD)
    const size_t scales_per_row = in_features / group_size;
    if ((group_size == 8 || group_size == 16) &&
        out_features % 4 == 0 && in_features % 16 == 0) {
        for (; token + 3 < batch; token += 4) {
            const int8_t *q0 = q_inputs + (token + 0) * in_features;
            const int8_t *q1 = q_inputs + (token + 1) * in_features;
            const int8_t *q2 = q_inputs + (token + 2) * in_features;
            const int8_t *q3 = q_inputs + (token + 3) * in_features;
            const float *as0 = activation_scales + (token + 0) * activation_scale_stride;
            const float *as1 = activation_scales + (token + 1) * activation_scale_stride;
            const float *as2 = activation_scales + (token + 2) * activation_scale_stride;
            const float *as3 = activation_scales + (token + 3) * activation_scale_stride;

            for (size_t tile = 0; tile < out_features / 4; ++tile) {
                const size_t row0 = tile * 4;
                const uint8_t *tile_weights = packed + tile * (2 * in_features);
                const __fp16 *tile_scales =
                    scales_rows4 + tile * scales_per_row * 4;
                const float32x4_t initial = bias
                    ? vld1q_f32(bias + row0)
                    : vdupq_n_f32(0.0f);
                const float32x4_t zero = vdupq_n_f32(0.0f);

                // Keep the same K64 reduction tree as the existing matvec:
                // four independent phase accumulators, pairwise-added at end.
                float32x4_t t0a0 = initial, t0a1 = zero, t0a2 = zero, t0a3 = zero;
                float32x4_t t1a0 = initial, t1a1 = zero, t1a2 = zero, t1a3 = zero;
                float32x4_t t2a0 = initial, t2a1 = zero, t2a2 = zero, t2a3 = zero;
                float32x4_t t3a0 = initial, t3a1 = zero, t3a2 = zero, t3a3 = zero;

                size_t col = 0;
                for (; col + 63 < in_features; col += 64) {
                    int8x16_t w0, w1, w2, w3;

#define GLACIER_ACCUM_M4_G16(PHASE, OFFSET) do { \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2, &w0, &w1); \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2 + 16, &w2, &w3); \
    const float32x4_t ws = vcvt_f32_f16(vld1_f16( \
        tile_scales + ((col + (OFFSET)) / 16) * 4)); \
    t0a##PHASE = accumulate_rows4_k16_g16_unpacked(t0a##PHASE, \
        vld1q_s8(q0 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as0[(col + (OFFSET)) / 16]); \
    t1a##PHASE = accumulate_rows4_k16_g16_unpacked(t1a##PHASE, \
        vld1q_s8(q1 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as1[(col + (OFFSET)) / 16]); \
    t2a##PHASE = accumulate_rows4_k16_g16_unpacked(t2a##PHASE, \
        vld1q_s8(q2 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as2[(col + (OFFSET)) / 16]); \
    t3a##PHASE = accumulate_rows4_k16_g16_unpacked(t3a##PHASE, \
        vld1q_s8(q3 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as3[(col + (OFFSET)) / 16]); \
} while (0)

#define GLACIER_ACCUM_M4_G8(PHASE, OFFSET) do { \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2, &w0, &w1); \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2 + 16, &w2, &w3); \
    const float16x8_t ws_pair = vld1q_f16( \
        tile_scales + ((col + (OFFSET)) / 8) * 4); \
    const float32x4_t ws0 = vcvt_f32_f16(vget_low_f16(ws_pair)); \
    const float32x4_t ws1 = vcvt_high_f32_f16(ws_pair); \
    t0a##PHASE = accumulate_rows4_k16_g8_unpacked(t0a##PHASE, \
        vld1q_s8(q0 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as0[(col + (OFFSET)) / 32], as0[(col + (OFFSET) + 8) / 32]); \
    t1a##PHASE = accumulate_rows4_k16_g8_unpacked(t1a##PHASE, \
        vld1q_s8(q1 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as1[(col + (OFFSET)) / 32], as1[(col + (OFFSET) + 8) / 32]); \
    t2a##PHASE = accumulate_rows4_k16_g8_unpacked(t2a##PHASE, \
        vld1q_s8(q2 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as2[(col + (OFFSET)) / 32], as2[(col + (OFFSET) + 8) / 32]); \
    t3a##PHASE = accumulate_rows4_k16_g8_unpacked(t3a##PHASE, \
        vld1q_s8(q3 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as3[(col + (OFFSET)) / 32], as3[(col + (OFFSET) + 8) / 32]); \
} while (0)

                    if (group_size == 8) {
                        GLACIER_ACCUM_M4_G8(0, 0);
                        GLACIER_ACCUM_M4_G8(1, 16);
                        GLACIER_ACCUM_M4_G8(2, 32);
                        GLACIER_ACCUM_M4_G8(3, 48);
                    } else {
                        GLACIER_ACCUM_M4_G16(0, 0);
                        GLACIER_ACCUM_M4_G16(1, 16);
                        GLACIER_ACCUM_M4_G16(2, 32);
                        GLACIER_ACCUM_M4_G16(3, 48);
                    }
                }

                // Match the old kernel's short K tail by accumulating it into
                // phase zero rather than changing the reduction tree.
                for (; col < in_features; col += 16) {
                    int8x16_t w0, w1, w2, w3;
                    unpack_rows4_k16_pair(tile_weights + col * 2, &w0, &w1);
                    unpack_rows4_k16_pair(tile_weights + col * 2 + 16, &w2, &w3);
                    if (group_size == 8) {
                        const float16x8_t ws_pair = vld1q_f16(
                            tile_scales + (col / 8) * 4);
                        const float32x4_t ws0 = vcvt_f32_f16(vget_low_f16(ws_pair));
                        const float32x4_t ws1 = vcvt_high_f32_f16(ws_pair);
                        t0a0 = accumulate_rows4_k16_g8_unpacked(t0a0,
                            vld1q_s8(q0 + col), w0, w1, w2, w3, ws0, ws1,
                            as0[col / 32], as0[(col + 8) / 32]);
                        t1a0 = accumulate_rows4_k16_g8_unpacked(t1a0,
                            vld1q_s8(q1 + col), w0, w1, w2, w3, ws0, ws1,
                            as1[col / 32], as1[(col + 8) / 32]);
                        t2a0 = accumulate_rows4_k16_g8_unpacked(t2a0,
                            vld1q_s8(q2 + col), w0, w1, w2, w3, ws0, ws1,
                            as2[col / 32], as2[(col + 8) / 32]);
                        t3a0 = accumulate_rows4_k16_g8_unpacked(t3a0,
                            vld1q_s8(q3 + col), w0, w1, w2, w3, ws0, ws1,
                            as3[col / 32], as3[(col + 8) / 32]);
                    } else {
                        const float32x4_t ws = vcvt_f32_f16(vld1_f16(
                            tile_scales + (col / 16) * 4));
                        t0a0 = accumulate_rows4_k16_g16_unpacked(t0a0,
                            vld1q_s8(q0 + col), w0, w1, w2, w3, ws,
                            as0[col / 16]);
                        t1a0 = accumulate_rows4_k16_g16_unpacked(t1a0,
                            vld1q_s8(q1 + col), w0, w1, w2, w3, ws,
                            as1[col / 16]);
                        t2a0 = accumulate_rows4_k16_g16_unpacked(t2a0,
                            vld1q_s8(q2 + col), w0, w1, w2, w3, ws,
                            as2[col / 16]);
                        t3a0 = accumulate_rows4_k16_g16_unpacked(t3a0,
                            vld1q_s8(q3 + col), w0, w1, w2, w3, ws,
                            as3[col / 16]);
                    }
                }

#undef GLACIER_ACCUM_M4_G16
#undef GLACIER_ACCUM_M4_G8

                vst1q_f32(output + (token + 0) * output_stride + row0,
                    vaddq_f32(vaddq_f32(t0a0, t0a1), vaddq_f32(t0a2, t0a3)));
                vst1q_f32(output + (token + 1) * output_stride + row0,
                    vaddq_f32(vaddq_f32(t1a0, t1a1), vaddq_f32(t1a2, t1a3)));
                vst1q_f32(output + (token + 2) * output_stride + row0,
                    vaddq_f32(vaddq_f32(t2a0, t2a1), vaddq_f32(t2a2, t2a3)));
                vst1q_f32(output + (token + 3) * output_stride + row0,
                    vaddq_f32(vaddq_f32(t3a0, t3a1), vaddq_f32(t3a2, t3a3)));
            }
        }
    }
#endif

    // Batch tails and non-SDOT builds retain the exact old-kernel path. This
    // also makes batch sizes 1..3 a useful differential oracle for the API.
    for (; token < batch; ++token) {
        glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
            q_inputs + token * in_features,
            activation_scales + token * activation_scale_stride,
            packed,
            scales_rows4,
            bias,
            output + token * output_stride,
            out_features,
            in_features,
            group_size);
    }
}

// Versioned fixed-M4 decision kernel. Unlike the materialized M4 ABI above,
// this consumes one complete contiguous row shard and publishes only the four
// shard winners. The arithmetic and final four-way K64 reduction are kept
// identical to the materialized producer; winner state is scalar/register
// state whose only externally visible write is the final result array.
int glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4_argmax_v2(
    const int8_t *q_inputs,
    const float *activation_scales,
    const uint8_t *packed,
    const __fp16 *scales_rows4,
    const float *bias,
    size_t out_features,
    size_t in_features,
    size_t group_size,
    size_t row_offset,
    glacier_argmax_result *argmax)
{
    if (q_inputs == NULL || activation_scales == NULL || packed == NULL ||
        scales_rows4 == NULL || argmax == NULL || out_features == 0 ||
        out_features % 4 != 0 || in_features == 0 || in_features % 16 != 0 ||
        (group_size != 8 && group_size != 16) ||
        in_features % group_size != 0 ||
        row_offset > SIZE_MAX - out_features) return 0;

    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t activation_scale_stride =
        (in_features + activation_group_size - 1) / activation_group_size;
    const size_t scales_per_row = in_features / group_size;
    const int8_t *q0 = q_inputs + 0 * in_features;
    const int8_t *q1 = q_inputs + 1 * in_features;
    const int8_t *q2 = q_inputs + 2 * in_features;
    const int8_t *q3 = q_inputs + 3 * in_features;
    const float *as0 = activation_scales + 0 * activation_scale_stride;
    const float *as1 = activation_scales + 1 * activation_scale_stride;
    const float *as2 = activation_scales + 2 * activation_scale_stride;
    const float *as3 = activation_scales + 3 * activation_scale_stride;

    float best0 = -INFINITY, best1 = -INFINITY;
    float best2 = -INFINITY, best3 = -INFINITY;
    size_t index0 = 0, index1 = 0, index2 = 0, index3 = 0;
    int valid0 = 0, valid1 = 0, valid2 = 0, valid3 = 0;
    int nan0 = 0, nan1 = 0, nan2 = 0, nan3 = 0;
    size_t processed_rows = 0;

#define GLACIER_M4_ARGMAX_FINITE(TOKEN, VALUE, INDEX) do { \
    const float glacier_finite_candidate = (VALUE); \
    const size_t glacier_finite_index = row_offset + (INDEX); \
    if (!valid##TOKEN || glacier_finite_candidate > best##TOKEN || \
               (glacier_finite_candidate == best##TOKEN && \
                glacier_finite_index < index##TOKEN)) { \
        best##TOKEN = glacier_finite_candidate; \
        index##TOKEN = glacier_finite_index; \
        valid##TOKEN = 1; \
    } \
} while (0)

#define GLACIER_M4_ARGMAX_SCALAR(TOKEN, VALUE, INDEX) do { \
    const float glacier_candidate = (VALUE); \
    if (isnan(glacier_candidate)) { \
        nan##TOKEN = 1; \
    } else { \
        GLACIER_M4_ARGMAX_FINITE(TOKEN, glacier_candidate, INDEX); \
    } \
} while (0)

#define GLACIER_M4_ARGMAX_VECTOR(TOKEN, RESULT, ROW0) do { \
    const uint32x4_t glacier_ordered = vceqq_f32((RESULT), (RESULT)); \
    if (vminvq_u32(glacier_ordered) != UINT32_MAX) { \
        nan##TOKEN = 1; \
    } else { \
        const float glacier_tile_best = vmaxvq_f32((RESULT)); \
        const uint32x4_t glacier_equal = vceqq_f32( \
            (RESULT), vdupq_n_f32(glacier_tile_best)); \
        const size_t glacier_lane = vgetq_lane_u32(glacier_equal, 0) ? 0 : \
            vgetq_lane_u32(glacier_equal, 1) ? 1 : \
            vgetq_lane_u32(glacier_equal, 2) ? 2 : 3; \
        GLACIER_M4_ARGMAX_FINITE( \
            TOKEN, glacier_tile_best, (ROW0) + glacier_lane); \
    } \
} while (0)

#if defined(__ARM_FEATURE_DOTPROD)
    for (size_t tile = 0; tile < out_features / 4; ++tile) {
        const size_t row0 = tile * 4;
        const uint8_t *tile_weights = packed + tile * (2 * in_features);
        const __fp16 *tile_scales =
            scales_rows4 + tile * scales_per_row * 4;
        const float32x4_t initial = bias
            ? vld1q_f32(bias + row0)
            : vdupq_n_f32(0.0f);
        const float32x4_t zero = vdupq_n_f32(0.0f);

        float32x4_t t0a0 = initial, t0a1 = zero, t0a2 = zero, t0a3 = zero;
        float32x4_t t1a0 = initial, t1a1 = zero, t1a2 = zero, t1a3 = zero;
        float32x4_t t2a0 = initial, t2a1 = zero, t2a2 = zero, t2a3 = zero;
        float32x4_t t3a0 = initial, t3a1 = zero, t3a2 = zero, t3a3 = zero;

        size_t col = 0;
        for (; col + 63 < in_features; col += 64) {
            int8x16_t w0, w1, w2, w3;

#define GLACIER_ARGMAX_ACCUM_M4_G16(PHASE, OFFSET) do { \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2, &w0, &w1); \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2 + 16, &w2, &w3); \
    const float32x4_t ws = vcvt_f32_f16(vld1_f16( \
        tile_scales + ((col + (OFFSET)) / 16) * 4)); \
    t0a##PHASE = accumulate_rows4_k16_g16_unpacked(t0a##PHASE, \
        vld1q_s8(q0 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as0[(col + (OFFSET)) / 16]); \
    t1a##PHASE = accumulate_rows4_k16_g16_unpacked(t1a##PHASE, \
        vld1q_s8(q1 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as1[(col + (OFFSET)) / 16]); \
    t2a##PHASE = accumulate_rows4_k16_g16_unpacked(t2a##PHASE, \
        vld1q_s8(q2 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as2[(col + (OFFSET)) / 16]); \
    t3a##PHASE = accumulate_rows4_k16_g16_unpacked(t3a##PHASE, \
        vld1q_s8(q3 + col + (OFFSET)), w0, w1, w2, w3, ws, \
        as3[(col + (OFFSET)) / 16]); \
} while (0)

#define GLACIER_ARGMAX_ACCUM_M4_G8(PHASE, OFFSET) do { \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2, &w0, &w1); \
    unpack_rows4_k16_pair(tile_weights + (col + (OFFSET)) * 2 + 16, &w2, &w3); \
    const float16x8_t ws_pair = vld1q_f16( \
        tile_scales + ((col + (OFFSET)) / 8) * 4); \
    const float32x4_t ws0 = vcvt_f32_f16(vget_low_f16(ws_pair)); \
    const float32x4_t ws1 = vcvt_high_f32_f16(ws_pair); \
    t0a##PHASE = accumulate_rows4_k16_g8_unpacked(t0a##PHASE, \
        vld1q_s8(q0 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as0[(col + (OFFSET)) / 32], as0[(col + (OFFSET) + 8) / 32]); \
    t1a##PHASE = accumulate_rows4_k16_g8_unpacked(t1a##PHASE, \
        vld1q_s8(q1 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as1[(col + (OFFSET)) / 32], as1[(col + (OFFSET) + 8) / 32]); \
    t2a##PHASE = accumulate_rows4_k16_g8_unpacked(t2a##PHASE, \
        vld1q_s8(q2 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as2[(col + (OFFSET)) / 32], as2[(col + (OFFSET) + 8) / 32]); \
    t3a##PHASE = accumulate_rows4_k16_g8_unpacked(t3a##PHASE, \
        vld1q_s8(q3 + col + (OFFSET)), w0, w1, w2, w3, ws0, ws1, \
        as3[(col + (OFFSET)) / 32], as3[(col + (OFFSET) + 8) / 32]); \
} while (0)

            if (group_size == 8) {
                GLACIER_ARGMAX_ACCUM_M4_G8(0, 0);
                GLACIER_ARGMAX_ACCUM_M4_G8(1, 16);
                GLACIER_ARGMAX_ACCUM_M4_G8(2, 32);
                GLACIER_ARGMAX_ACCUM_M4_G8(3, 48);
            } else {
                GLACIER_ARGMAX_ACCUM_M4_G16(0, 0);
                GLACIER_ARGMAX_ACCUM_M4_G16(1, 16);
                GLACIER_ARGMAX_ACCUM_M4_G16(2, 32);
                GLACIER_ARGMAX_ACCUM_M4_G16(3, 48);
            }
        }

        for (; col < in_features; col += 16) {
            int8x16_t w0, w1, w2, w3;
            unpack_rows4_k16_pair(tile_weights + col * 2, &w0, &w1);
            unpack_rows4_k16_pair(tile_weights + col * 2 + 16, &w2, &w3);
            if (group_size == 8) {
                const float16x8_t ws_pair = vld1q_f16(
                    tile_scales + (col / 8) * 4);
                const float32x4_t ws0 = vcvt_f32_f16(vget_low_f16(ws_pair));
                const float32x4_t ws1 = vcvt_high_f32_f16(ws_pair);
                t0a0 = accumulate_rows4_k16_g8_unpacked(t0a0,
                    vld1q_s8(q0 + col), w0, w1, w2, w3, ws0, ws1,
                    as0[col / 32], as0[(col + 8) / 32]);
                t1a0 = accumulate_rows4_k16_g8_unpacked(t1a0,
                    vld1q_s8(q1 + col), w0, w1, w2, w3, ws0, ws1,
                    as1[col / 32], as1[(col + 8) / 32]);
                t2a0 = accumulate_rows4_k16_g8_unpacked(t2a0,
                    vld1q_s8(q2 + col), w0, w1, w2, w3, ws0, ws1,
                    as2[col / 32], as2[(col + 8) / 32]);
                t3a0 = accumulate_rows4_k16_g8_unpacked(t3a0,
                    vld1q_s8(q3 + col), w0, w1, w2, w3, ws0, ws1,
                    as3[col / 32], as3[(col + 8) / 32]);
            } else {
                const float32x4_t ws = vcvt_f32_f16(vld1_f16(
                    tile_scales + (col / 16) * 4));
                t0a0 = accumulate_rows4_k16_g16_unpacked(t0a0,
                    vld1q_s8(q0 + col), w0, w1, w2, w3, ws,
                    as0[col / 16]);
                t1a0 = accumulate_rows4_k16_g16_unpacked(t1a0,
                    vld1q_s8(q1 + col), w0, w1, w2, w3, ws,
                    as1[col / 16]);
                t2a0 = accumulate_rows4_k16_g16_unpacked(t2a0,
                    vld1q_s8(q2 + col), w0, w1, w2, w3, ws,
                    as2[col / 16]);
                t3a0 = accumulate_rows4_k16_g16_unpacked(t3a0,
                    vld1q_s8(q3 + col), w0, w1, w2, w3, ws,
                    as3[col / 16]);
            }
        }

#undef GLACIER_ARGMAX_ACCUM_M4_G16
#undef GLACIER_ARGMAX_ACCUM_M4_G8

        const float32x4_t result0 = vaddq_f32(
            vaddq_f32(t0a0, t0a1), vaddq_f32(t0a2, t0a3));
        const float32x4_t result1 = vaddq_f32(
            vaddq_f32(t1a0, t1a1), vaddq_f32(t1a2, t1a3));
        const float32x4_t result2 = vaddq_f32(
            vaddq_f32(t2a0, t2a1), vaddq_f32(t2a2, t2a3));
        const float32x4_t result3 = vaddq_f32(
            vaddq_f32(t3a0, t3a1), vaddq_f32(t3a2, t3a3));
        GLACIER_M4_ARGMAX_VECTOR(0, result0, row0);
        GLACIER_M4_ARGMAX_VECTOR(1, result1, row0);
        GLACIER_M4_ARGMAX_VECTOR(2, result2, row0);
        GLACIER_M4_ARGMAX_VECTOR(3, result3, row0);
    }
    processed_rows = out_features;
#endif

    // Generic AArch64 fallback duplicates the materialized matvec's scalar
    // row formula for each token. It remains an allocation-free differential
    // oracle for toolchains that do not define DOTPROD.
    const size_t groups = (in_features + group_size - 1) / group_size;
    for (size_t row = processed_rows; row < out_features; ++row) {
        float acc0 = bias ? bias[row] : 0.0f;
        float acc1 = acc0, acc2 = acc0, acc3 = acc0;
        for (size_t group = 0; group < groups; ++group) {
            const size_t col_start = group * group_size;
            const size_t count = col_start + group_size < in_features
                ? group_size : in_features - col_start;
            int32_t dot0 = 0, dot1 = 0, dot2 = 0, dot3 = 0;
            for (size_t col = 0; col < count; ++col) {
                const size_t nibble_index = rows4_k16_nibble_index(
                    row, col_start + col, in_features);
                const uint8_t packed_byte = packed[nibble_index >> 1];
                const int8_t q_weight = (int8_t)((nibble_index & 1) ?
                    ((packed_byte >> 4) & 0x0f) : (packed_byte & 0x0f)) - 7;
                dot0 += (int32_t)q_weight * (int32_t)q0[col_start + col];
                dot1 += (int32_t)q_weight * (int32_t)q1[col_start + col];
                dot2 += (int32_t)q_weight * (int32_t)q2[col_start + col];
                dot3 += (int32_t)q_weight * (int32_t)q3[col_start + col];
            }
            const size_t scale_index =
                ((row / 4) * scales_per_row + group) * 4 + row % 4;
            const float weight_scale = (float)scales_rows4[scale_index];
            acc0 += (float)dot0 * weight_scale *
                as0[col_start / activation_group_size];
            acc1 += (float)dot1 * weight_scale *
                as1[col_start / activation_group_size];
            acc2 += (float)dot2 * weight_scale *
                as2[col_start / activation_group_size];
            acc3 += (float)dot3 * weight_scale *
                as3[col_start / activation_group_size];
        }
        GLACIER_M4_ARGMAX_SCALAR(0, acc0, row);
        GLACIER_M4_ARGMAX_SCALAR(1, acc1, row);
        GLACIER_M4_ARGMAX_SCALAR(2, acc2, row);
        GLACIER_M4_ARGMAX_SCALAR(3, acc3, row);
    }

    argmax[0] = (glacier_argmax_result){ best0, index0, valid0, nan0 };
    argmax[1] = (glacier_argmax_result){ best1, index1, valid1, nan1 };
    argmax[2] = (glacier_argmax_result){ best2, index2, valid2, nan2 };
    argmax[3] = (glacier_argmax_result){ best3, index3, valid3, nan3 };

#undef GLACIER_M4_ARGMAX_VECTOR
#undef GLACIER_M4_ARGMAX_SCALAR
#undef GLACIER_M4_ARGMAX_FINITE
    return 1;
}

#if defined(__ARM_FEATURE_DOTPROD)
// PairNibble stores the gate coefficient in the low nibble and the up
// coefficient in the high nibble. Unlike the ordinary packed-INT4 stream,
// every byte already occupies its final rows4/K16 [row_lane][K4] position.
static inline void unpack_pair_nibble_rows4_k16_chunk(
    const uint8_t *paired,
    int8x16_t *gate,
    int8x16_t *up)
{
    const uint8x16_t bytes = vld1q_u8(paired);
    const int8x16_t offset = vdupq_n_s8(7);
    *gate = vsubq_s8(vreinterpretq_s8_u8(
        vandq_u8(bytes, vdupq_n_u8(0x0f))), offset);
    *up = vsubq_s8(vreinterpretq_s8_u8(vshrq_n_u8(bytes, 4)), offset);
}

static inline void accumulate_pair_nibble_rows4_k16_g8(
    float32x4_t *gate_acc,
    float32x4_t *up_acc,
    int8x16_t q_act,
    const uint8_t *paired,
    const __fp16 *paired_scales,
    float activation_scale0,
    float activation_scale1)
{
    int8x16_t gate0, gate1, gate2, gate3;
    int8x16_t up0, up1, up2, up3;
    unpack_pair_nibble_rows4_k16_chunk(paired + 0, &gate0, &up0);
    unpack_pair_nibble_rows4_k16_chunk(paired + 16, &gate1, &up1);
    unpack_pair_nibble_rows4_k16_chunk(paired + 32, &gate2, &up2);
    unpack_pair_nibble_rows4_k16_chunk(paired + 48, &gate3, &up3);

    int32x4_t gate_dots0 = vdotq_laneq_s32(
        vdupq_n_s32(0), gate0, q_act, 0);
    gate_dots0 = vdotq_laneq_s32(gate_dots0, gate1, q_act, 1);
    int32x4_t gate_dots1 = vdotq_laneq_s32(
        vdupq_n_s32(0), gate2, q_act, 2);
    gate_dots1 = vdotq_laneq_s32(gate_dots1, gate3, q_act, 3);

    int32x4_t up_dots0 = vdotq_laneq_s32(
        vdupq_n_s32(0), up0, q_act, 0);
    up_dots0 = vdotq_laneq_s32(up_dots0, up1, q_act, 1);
    int32x4_t up_dots1 = vdotq_laneq_s32(
        vdupq_n_s32(0), up2, q_act, 2);
    up_dots1 = vdotq_laneq_s32(up_dots1, up3, q_act, 3);

    const float16x8_t scale_group0 = vld1q_f16(paired_scales);
    const float16x8_t scale_group1 = vld1q_f16(paired_scales + 8);
    const float32x4_t gate_scales0 = vcvt_f32_f16(
        vget_low_f16(scale_group0));
    const float32x4_t up_scales0 = vcvt_high_f32_f16(scale_group0);
    const float32x4_t gate_scales1 = vcvt_f32_f16(
        vget_low_f16(scale_group1));
    const float32x4_t up_scales1 = vcvt_high_f32_f16(scale_group1);

    *gate_acc = vfmaq_n_f32(
        *gate_acc,
        vmulq_f32(vcvtq_f32_s32(gate_dots0), gate_scales0),
        activation_scale0);
    *gate_acc = vfmaq_n_f32(
        *gate_acc,
        vmulq_f32(vcvtq_f32_s32(gate_dots1), gate_scales1),
        activation_scale1);
    *up_acc = vfmaq_n_f32(
        *up_acc,
        vmulq_f32(vcvtq_f32_s32(up_dots0), up_scales0),
        activation_scale0);
    *up_acc = vfmaq_n_f32(
        *up_acc,
        vmulq_f32(vcvtq_f32_s32(up_dots1), up_scales1),
        activation_scale1);
}

static inline void accumulate_pair_nibble_rows4_k16_g16(
    float32x4_t *gate_acc,
    float32x4_t *up_acc,
    int8x16_t q_act,
    const uint8_t *paired,
    const __fp16 *paired_scales,
    float activation_scale)
{
    int8x16_t gate0, gate1, gate2, gate3;
    int8x16_t up0, up1, up2, up3;
    unpack_pair_nibble_rows4_k16_chunk(paired + 0, &gate0, &up0);
    unpack_pair_nibble_rows4_k16_chunk(paired + 16, &gate1, &up1);
    unpack_pair_nibble_rows4_k16_chunk(paired + 32, &gate2, &up2);
    unpack_pair_nibble_rows4_k16_chunk(paired + 48, &gate3, &up3);

    int32x4_t gate_dots = vdotq_laneq_s32(
        vdupq_n_s32(0), gate0, q_act, 0);
    gate_dots = vdotq_laneq_s32(gate_dots, gate1, q_act, 1);
    gate_dots = vdotq_laneq_s32(gate_dots, gate2, q_act, 2);
    gate_dots = vdotq_laneq_s32(gate_dots, gate3, q_act, 3);

    int32x4_t up_dots = vdotq_laneq_s32(
        vdupq_n_s32(0), up0, q_act, 0);
    up_dots = vdotq_laneq_s32(up_dots, up1, q_act, 1);
    up_dots = vdotq_laneq_s32(up_dots, up2, q_act, 2);
    up_dots = vdotq_laneq_s32(up_dots, up3, q_act, 3);

    const float16x8_t scale_group = vld1q_f16(paired_scales);
    const float32x4_t gate_scales = vcvt_f32_f16(
        vget_low_f16(scale_group));
    const float32x4_t up_scales = vcvt_high_f32_f16(scale_group);
    *gate_acc = vfmaq_n_f32(
        *gate_acc,
        vmulq_f32(vcvtq_f32_s32(gate_dots), gate_scales),
        activation_scale);
    *up_acc = vfmaq_n_f32(
        *up_acc,
        vmulq_f32(vcvtq_f32_s32(up_dots), up_scales),
        activation_scale);
}

#endif

// Internal unchecked dual-output PairNibble matvec. The public Zig edge owns
// exact extents, output/read disjointness, and shape validation before calling
// this symbol. paired is one byte per logical coefficient (gate low nibble, up
// high nibble). paired_scales is [row_tile][k_group][branch][row_lane], with
// branch 0 = gate and 1 = up.
void glacier_pair_nibble_matvec_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *q_input,
    const float *activation_scales,
    const uint8_t *paired,
    const __fp16 *paired_scales,
    const float *gate_bias,
    const float *up_bias,
    float *gate_output,
    float *up_output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    if ((group_size != 8 && group_size != 16) ||
        out_features % 4 != 0 || in_features % 16 != 0) return;

    const size_t scales_per_row = in_features / group_size;
    size_t processed_rows = 0;
#if defined(__ARM_FEATURE_DOTPROD)
    const size_t row_tiles = out_features / 4;
    for (size_t tile = 0; tile < row_tiles; ++tile) {
        const size_t row0 = tile * 4;
        float32x4_t gate_acc0 = gate_bias
            ? vld1q_f32(gate_bias + row0) : vdupq_n_f32(0.0f);
        float32x4_t gate_acc1 = vdupq_n_f32(0.0f);
        float32x4_t gate_acc2 = vdupq_n_f32(0.0f);
        float32x4_t gate_acc3 = vdupq_n_f32(0.0f);
        float32x4_t up_acc0 = up_bias
            ? vld1q_f32(up_bias + row0) : vdupq_n_f32(0.0f);
        float32x4_t up_acc1 = vdupq_n_f32(0.0f);
        float32x4_t up_acc2 = vdupq_n_f32(0.0f);
        float32x4_t up_acc3 = vdupq_n_f32(0.0f);
        const uint8_t *tile_pairs = paired + tile * (4 * in_features);
        const __fp16 *tile_scales =
            paired_scales + tile * scales_per_row * 8;

        size_t col = 0;
        for (; col + 63 < in_features; col += 64) {
            if (group_size == 8) {
                accumulate_pair_nibble_rows4_k16_g8(
                    &gate_acc0, &up_acc0, vld1q_s8(q_input + col),
                    tile_pairs + col * 4, tile_scales + (col / 8) * 8,
                    activation_scales[col / 32],
                    activation_scales[(col + 8) / 32]);
                accumulate_pair_nibble_rows4_k16_g8(
                    &gate_acc1, &up_acc1, vld1q_s8(q_input + col + 16),
                    tile_pairs + (col + 16) * 4,
                    tile_scales + ((col + 16) / 8) * 8,
                    activation_scales[(col + 16) / 32],
                    activation_scales[(col + 24) / 32]);
                accumulate_pair_nibble_rows4_k16_g8(
                    &gate_acc2, &up_acc2, vld1q_s8(q_input + col + 32),
                    tile_pairs + (col + 32) * 4,
                    tile_scales + ((col + 32) / 8) * 8,
                    activation_scales[(col + 32) / 32],
                    activation_scales[(col + 40) / 32]);
                accumulate_pair_nibble_rows4_k16_g8(
                    &gate_acc3, &up_acc3, vld1q_s8(q_input + col + 48),
                    tile_pairs + (col + 48) * 4,
                    tile_scales + ((col + 48) / 8) * 8,
                    activation_scales[(col + 48) / 32],
                    activation_scales[(col + 56) / 32]);
            } else {
                accumulate_pair_nibble_rows4_k16_g16(
                    &gate_acc0, &up_acc0, vld1q_s8(q_input + col),
                    tile_pairs + col * 4, tile_scales + (col / 16) * 8,
                    activation_scales[col / 16]);
                accumulate_pair_nibble_rows4_k16_g16(
                    &gate_acc1, &up_acc1, vld1q_s8(q_input + col + 16),
                    tile_pairs + (col + 16) * 4,
                    tile_scales + ((col + 16) / 16) * 8,
                    activation_scales[(col + 16) / 16]);
                accumulate_pair_nibble_rows4_k16_g16(
                    &gate_acc2, &up_acc2, vld1q_s8(q_input + col + 32),
                    tile_pairs + (col + 32) * 4,
                    tile_scales + ((col + 32) / 16) * 8,
                    activation_scales[(col + 32) / 16]);
                accumulate_pair_nibble_rows4_k16_g16(
                    &gate_acc3, &up_acc3, vld1q_s8(q_input + col + 48),
                    tile_pairs + (col + 48) * 4,
                    tile_scales + ((col + 48) / 16) * 8,
                    activation_scales[(col + 48) / 16]);
            }
        }
        for (; col < in_features; col += 16) {
            if (group_size == 8) {
                accumulate_pair_nibble_rows4_k16_g8(
                    &gate_acc0, &up_acc0, vld1q_s8(q_input + col),
                    tile_pairs + col * 4, tile_scales + (col / 8) * 8,
                    activation_scales[col / 32],
                    activation_scales[(col + 8) / 32]);
            } else {
                accumulate_pair_nibble_rows4_k16_g16(
                    &gate_acc0, &up_acc0, vld1q_s8(q_input + col),
                    tile_pairs + col * 4, tile_scales + (col / 16) * 8,
                    activation_scales[col / 16]);
            }
        }

        vst1q_f32(gate_output + row0, vaddq_f32(
            vaddq_f32(gate_acc0, gate_acc1),
            vaddq_f32(gate_acc2, gate_acc3)));
        vst1q_f32(up_output + row0, vaddq_f32(
            vaddq_f32(up_acc0, up_acc1),
            vaddq_f32(up_acc2, up_acc3)));
    }
    processed_rows = out_features;
#endif

    // Scalar/no-DOTPROD path follows the same per-group accumulation order as
    // two canonical separate kernels, while fetching each coefficient once.
    const size_t activation_group_size = group_size == 8 ? 32 : 16;
    const size_t groups = in_features / group_size;
    for (size_t row = processed_rows; row < out_features; ++row) {
        float gate_acc = gate_bias ? gate_bias[row] : 0.0f;
        float up_acc = up_bias ? up_bias[row] : 0.0f;
        for (size_t group = 0; group < groups; ++group) {
            const size_t col_start = group * group_size;
            int32_t gate_dot = 0;
            int32_t up_dot = 0;
            for (size_t col = 0; col < group_size; ++col) {
                const size_t pair_index = rows4_k16_nibble_index(
                    row, col_start + col, in_features);
                const uint8_t pair = paired[pair_index];
                gate_dot += (int32_t)((int8_t)(pair & 0x0f) - 7) *
                    (int32_t)q_input[col_start + col];
                up_dot += (int32_t)((int8_t)(pair >> 4) - 7) *
                    (int32_t)q_input[col_start + col];
            }
            const size_t scale_base =
                ((row / 4) * scales_per_row + group) * 8 + row % 4;
            const float activation_scale =
                activation_scales[col_start / activation_group_size];
            gate_acc += (float)gate_dot * (float)paired_scales[scale_base] *
                activation_scale;
            up_acc += (float)up_dot * (float)paired_scales[scale_base + 4] *
                activation_scale;
        }
        gate_output[row] = gate_acc;
        up_output[row] = up_acc;
    }
}

#if defined(__ARM_FEATURE_DOTPROD)
// The M4 producer preserves the canonical four-way K64 reduction tree while
// decoding every PairNibble coefficient once across all four tokens. g16
// keeps two phases live at a time; g8 uses an explicit phase scratch because
// its two independently scaled K8 halves need more temporary registers.
#define GLACIER_PAIR_M4_DOT_CHUNK(OFFSET, LANE) do { \
    const uint8x16_t raw = vld1q_u8(tile_pairs + col * 4 + (OFFSET)); \
    const int8x16_t gw = vsubq_s8(vreinterpretq_s8_u8( \
        vandq_u8(raw, mask)), seven); \
    const int8x16_t uw = vsubq_s8(vreinterpretq_s8_u8( \
        vshrq_n_u8(raw, 4)), seven); \
    gd0 = vdotq_laneq_s32(gd0, gw, qv0, (LANE)); \
    gd1 = vdotq_laneq_s32(gd1, gw, qv1, (LANE)); \
    gd2 = vdotq_laneq_s32(gd2, gw, qv2, (LANE)); \
    gd3 = vdotq_laneq_s32(gd3, gw, qv3, (LANE)); \
    ud0 = vdotq_laneq_s32(ud0, uw, qv0, (LANE)); \
    ud1 = vdotq_laneq_s32(ud1, uw, qv1, (LANE)); \
    ud2 = vdotq_laneq_s32(ud2, uw, qv2, (LANE)); \
    ud3 = vdotq_laneq_s32(ud3, uw, qv3, (LANE)); \
} while (0)

#define GLACIER_PAIR_M4_FMA(AS_INDEX) do { \
    ga0 = vfmaq_n_f32(ga0, vmulq_f32(vcvtq_f32_s32(gd0), gws), \
        as0[(AS_INDEX)]); \
    ga1 = vfmaq_n_f32(ga1, vmulq_f32(vcvtq_f32_s32(gd1), gws), \
        as1[(AS_INDEX)]); \
    ga2 = vfmaq_n_f32(ga2, vmulq_f32(vcvtq_f32_s32(gd2), gws), \
        as2[(AS_INDEX)]); \
    ga3 = vfmaq_n_f32(ga3, vmulq_f32(vcvtq_f32_s32(gd3), gws), \
        as3[(AS_INDEX)]); \
    ua0 = vfmaq_n_f32(ua0, vmulq_f32(vcvtq_f32_s32(ud0), uws), \
        as0[(AS_INDEX)]); \
    ua1 = vfmaq_n_f32(ua1, vmulq_f32(vcvtq_f32_s32(ud1), uws), \
        as1[(AS_INDEX)]); \
    ua2 = vfmaq_n_f32(ua2, vmulq_f32(vcvtq_f32_s32(ud2), uws), \
        as2[(AS_INDEX)]); \
    ua3 = vfmaq_n_f32(ua3, vmulq_f32(vcvtq_f32_s32(ud3), uws), \
        as3[(AS_INDEX)]); \
} while (0)

// g16 evaluates phase pairs (0,1) then (2,3). The first pair is published
// into the final outputs, and the second pair completes the exact tree.
static __attribute__((noinline)) void pair_nibble_rows4_k16_phase_pair_g16_m4(
    const int8_t *q0, const int8_t *q1, const int8_t *q2, const int8_t *q3,
    const float *as0, const float *as1, const float *as2, const float *as3,
    const uint8_t *paired, const __fp16 *paired_scales,
    const float *gate_bias, const float *up_bias,
    float *gate_out0, float *gate_out1, float *gate_out2, float *gate_out3,
    float *up_out0, float *up_out1, float *up_out2, float *up_out3,
    size_t out_features, size_t in_features)
{
    const uint8x16_t mask = vdupq_n_u8(0x0f);
    const int8x16_t seven = vdupq_n_s8(7);
    const size_t scales_per_row = in_features / 16;
    const size_t full_k64 = in_features - in_features % 64;

    for (size_t tile = 0; tile < out_features / 4; ++tile) {
        const size_t row0 = tile * 4;
        const uint8_t *tile_pairs = paired + tile * (4 * in_features);
        const __fp16 *tile_scales =
            paired_scales + tile * scales_per_row * 8;
        for (size_t phase_pair = 0; phase_pair < 2; ++phase_pair) {
            const size_t phase0 = phase_pair * 2;
            const size_t phase1 = phase0 + 1;
            const float32x4_t gate_initial = phase0 == 0 && gate_bias
                ? vld1q_f32(gate_bias + row0) : vdupq_n_f32(0.0f);
            const float32x4_t up_initial = phase0 == 0 && up_bias
                ? vld1q_f32(up_bias + row0) : vdupq_n_f32(0.0f);
            float32x4_t g0a0 = gate_initial, g0a1 = gate_initial;
            float32x4_t g0a2 = gate_initial, g0a3 = gate_initial;
            float32x4_t u0a0 = up_initial, u0a1 = up_initial;
            float32x4_t u0a2 = up_initial, u0a3 = up_initial;

#define GLACIER_PAIR_M4_PHASEPAIR_DECODE(COL) \
    const uint8x16_t b0 = vld1q_u8(tile_pairs + (COL) * 4 + 0); \
    const uint8x16_t b1 = vld1q_u8(tile_pairs + (COL) * 4 + 16); \
    const uint8x16_t b2 = vld1q_u8(tile_pairs + (COL) * 4 + 32); \
    const uint8x16_t b3 = vld1q_u8(tile_pairs + (COL) * 4 + 48); \
    const int8x16_t gw0 = vsubq_s8(vreinterpretq_s8_u8( \
        vandq_u8(b0, mask)), seven); \
    const int8x16_t gw1 = vsubq_s8(vreinterpretq_s8_u8( \
        vandq_u8(b1, mask)), seven); \
    const int8x16_t gw2 = vsubq_s8(vreinterpretq_s8_u8( \
        vandq_u8(b2, mask)), seven); \
    const int8x16_t gw3 = vsubq_s8(vreinterpretq_s8_u8( \
        vandq_u8(b3, mask)), seven); \
    const int8x16_t uw0 = vsubq_s8(vreinterpretq_s8_u8( \
        vshrq_n_u8(b0, 4)), seven); \
    const int8x16_t uw1 = vsubq_s8(vreinterpretq_s8_u8( \
        vshrq_n_u8(b1, 4)), seven); \
    const int8x16_t uw2 = vsubq_s8(vreinterpretq_s8_u8( \
        vshrq_n_u8(b2, 4)), seven); \
    const int8x16_t uw3 = vsubq_s8(vreinterpretq_s8_u8( \
        vshrq_n_u8(b3, 4)), seven); \
    const float16x8_t scale_pair = \
        vld1q_f16(tile_scales + ((COL) / 16) * 8); \
    const float32x4_t gws = vcvt_f32_f16(vget_low_f16(scale_pair)); \
    const float32x4_t uws = vcvt_high_f32_f16(scale_pair)
#define GLACIER_PAIR_M4_PHASEPAIR_APPLY(GACC, UACC, QPTR, ASPTR, COL) do { \
    const int8x16_t qv = vld1q_s8((QPTR) + (COL)); \
    int32x4_t gd = vdotq_laneq_s32(vdupq_n_s32(0), gw0, qv, 0); \
    gd = vdotq_laneq_s32(gd, gw1, qv, 1); \
    gd = vdotq_laneq_s32(gd, gw2, qv, 2); \
    gd = vdotq_laneq_s32(gd, gw3, qv, 3); \
    int32x4_t ud = vdotq_laneq_s32(vdupq_n_s32(0), uw0, qv, 0); \
    ud = vdotq_laneq_s32(ud, uw1, qv, 1); \
    ud = vdotq_laneq_s32(ud, uw2, qv, 2); \
    ud = vdotq_laneq_s32(ud, uw3, qv, 3); \
    (GACC) = vfmaq_n_f32((GACC), \
        vmulq_f32(vcvtq_f32_s32(gd), gws), (ASPTR)[(COL) / 16]); \
    (UACC) = vfmaq_n_f32((UACC), \
        vmulq_f32(vcvtq_f32_s32(ud), uws), (ASPTR)[(COL) / 16]); \
} while (0)
#define GLACIER_PAIR_M4_PHASEPAIR_BLOCK(GPREFIX, UPREFIX, COL) do { \
    GLACIER_PAIR_M4_PHASEPAIR_DECODE(COL); \
    GLACIER_PAIR_M4_PHASEPAIR_APPLY(GPREFIX##0, UPREFIX##0, q0, as0, COL); \
    GLACIER_PAIR_M4_PHASEPAIR_APPLY(GPREFIX##1, UPREFIX##1, q1, as1, COL); \
    GLACIER_PAIR_M4_PHASEPAIR_APPLY(GPREFIX##2, UPREFIX##2, q2, as2, COL); \
    GLACIER_PAIR_M4_PHASEPAIR_APPLY(GPREFIX##3, UPREFIX##3, q3, as3, COL); \
} while (0)
            size_t col = phase0 * 16;
            for (; col + 64 < full_k64; col += 128) {
                { GLACIER_PAIR_M4_PHASEPAIR_BLOCK(g0a, u0a, col); }
                { GLACIER_PAIR_M4_PHASEPAIR_BLOCK(g0a, u0a, col + 64); }
            }
            for (; col < full_k64; col += 64) {
                GLACIER_PAIR_M4_PHASEPAIR_BLOCK(g0a, u0a, col);
            }
            if (phase0 == 0) {
                for (col = full_k64; col < in_features; col += 16) {
                    GLACIER_PAIR_M4_PHASEPAIR_BLOCK(g0a, u0a, col);
                }
            }

            const float32x4_t zero = vdupq_n_f32(0.0f);
            float32x4_t g1a0 = zero, g1a1 = zero, g1a2 = zero, g1a3 = zero;
            float32x4_t u1a0 = zero, u1a1 = zero, u1a2 = zero, u1a3 = zero;
            col = phase1 * 16;
            for (; col + 64 < full_k64; col += 128) {
                { GLACIER_PAIR_M4_PHASEPAIR_BLOCK(g1a, u1a, col); }
                { GLACIER_PAIR_M4_PHASEPAIR_BLOCK(g1a, u1a, col + 64); }
            }
            for (; col < full_k64; col += 64) {
                GLACIER_PAIR_M4_PHASEPAIR_BLOCK(g1a, u1a, col);
            }
#undef GLACIER_PAIR_M4_PHASEPAIR_DECODE
#undef GLACIER_PAIR_M4_PHASEPAIR_APPLY
#undef GLACIER_PAIR_M4_PHASEPAIR_BLOCK

#define GLACIER_PAIR_M4_PHASEPAIR_STORE(TOKEN) do { \
    const float32x4_t gs = vaddq_f32(g0a##TOKEN, g1a##TOKEN); \
    const float32x4_t us = vaddq_f32(u0a##TOKEN, u1a##TOKEN); \
    if (phase_pair == 0) { \
        vst1q_f32(gate_out##TOKEN + row0, gs); \
        vst1q_f32(up_out##TOKEN + row0, us); \
    } else { \
        vst1q_f32(gate_out##TOKEN + row0, vaddq_f32( \
            vld1q_f32(gate_out##TOKEN + row0), gs)); \
        vst1q_f32(up_out##TOKEN + row0, vaddq_f32( \
            vld1q_f32(up_out##TOKEN + row0), us)); \
    } \
} while (0)
            GLACIER_PAIR_M4_PHASEPAIR_STORE(0);
            GLACIER_PAIR_M4_PHASEPAIR_STORE(1);
            GLACIER_PAIR_M4_PHASEPAIR_STORE(2);
            GLACIER_PAIR_M4_PHASEPAIR_STORE(3);
#undef GLACIER_PAIR_M4_PHASEPAIR_STORE
        }
    }
}

// g8 materializes four eight-vector phase results only after each complete
// strided dot loop, keeping the hot loop free of accumulator spills.
static __attribute__((noinline)) void pair_nibble_rows4_k16_phase_g8_m4(
    const int8_t *q0, const int8_t *q1, const int8_t *q2, const int8_t *q3,
    const float *as0, const float *as1, const float *as2, const float *as3,
    const uint8_t *paired, const __fp16 *paired_scales,
    const float *gate_bias, const float *up_bias,
    float *gate_out0, float *gate_out1, float *gate_out2, float *gate_out3,
    float *up_out0, float *up_out1, float *up_out2, float *up_out3,
    size_t out_features, size_t in_features)
{
    const uint8x16_t mask = vdupq_n_u8(0x0f);
    const int8x16_t seven = vdupq_n_s8(7);
    const size_t scales_per_row = in_features / 8;
    const size_t full_k64 = in_features - in_features % 64;

    for (size_t tile = 0; tile < out_features / 4; ++tile) {
        const size_t row0 = tile * 4;
        const uint8_t *tile_pairs = paired + tile * (4 * in_features);
        const __fp16 *tile_scales =
            paired_scales + tile * scales_per_row * 8;
        volatile float32x4_t gate_phase[4][4];
        volatile float32x4_t up_phase[4][4];

        for (size_t phase = 0; phase < 4; ++phase) {
            const float32x4_t gate_initial = phase == 0 && gate_bias
                ? vld1q_f32(gate_bias + row0) : vdupq_n_f32(0.0f);
            const float32x4_t up_initial = phase == 0 && up_bias
                ? vld1q_f32(up_bias + row0) : vdupq_n_f32(0.0f);
            float32x4_t ga0 = gate_initial, ga1 = gate_initial;
            float32x4_t ga2 = gate_initial, ga3 = gate_initial;
            float32x4_t ua0 = up_initial, ua1 = up_initial;
            float32x4_t ua2 = up_initial, ua3 = up_initial;

            size_t col = phase * 16;
            for (; col < full_k64; col += 64) {
                const int8x16_t qv0 = vld1q_s8(q0 + col);
                const int8x16_t qv1 = vld1q_s8(q1 + col);
                const int8x16_t qv2 = vld1q_s8(q2 + col);
                const int8x16_t qv3 = vld1q_s8(q3 + col);
                int32x4_t gd0 = vdupq_n_s32(0), gd1 = vdupq_n_s32(0);
                int32x4_t gd2 = vdupq_n_s32(0), gd3 = vdupq_n_s32(0);
                int32x4_t ud0 = vdupq_n_s32(0), ud1 = vdupq_n_s32(0);
                int32x4_t ud2 = vdupq_n_s32(0), ud3 = vdupq_n_s32(0);
                GLACIER_PAIR_M4_DOT_CHUNK(0, 0);
                GLACIER_PAIR_M4_DOT_CHUNK(16, 1);
                const float16x8_t scale_pair0 =
                    vld1q_f16(tile_scales + (col / 8) * 8);
                const float32x4_t gws =
                    vcvt_f32_f16(vget_low_f16(scale_pair0));
                const float32x4_t uws = vcvt_high_f32_f16(scale_pair0);
                GLACIER_PAIR_M4_FMA(col / 32);

                gd0 = vdupq_n_s32(0); gd1 = vdupq_n_s32(0);
                gd2 = vdupq_n_s32(0); gd3 = vdupq_n_s32(0);
                ud0 = vdupq_n_s32(0); ud1 = vdupq_n_s32(0);
                ud2 = vdupq_n_s32(0); ud3 = vdupq_n_s32(0);
                GLACIER_PAIR_M4_DOT_CHUNK(32, 2);
                GLACIER_PAIR_M4_DOT_CHUNK(48, 3);
                const float16x8_t scale_pair1 =
                    vld1q_f16(tile_scales + ((col / 8) + 1) * 8);
                const float32x4_t gws1 =
                    vcvt_f32_f16(vget_low_f16(scale_pair1));
                const float32x4_t uws1 = vcvt_high_f32_f16(scale_pair1);
#define gws gws1
#define uws uws1
                GLACIER_PAIR_M4_FMA((col + 8) / 32);
#undef gws
#undef uws
            }
            if (phase == 0) {
                for (col = full_k64; col < in_features; col += 16) {
                    const int8x16_t qv0 = vld1q_s8(q0 + col);
                    const int8x16_t qv1 = vld1q_s8(q1 + col);
                    const int8x16_t qv2 = vld1q_s8(q2 + col);
                    const int8x16_t qv3 = vld1q_s8(q3 + col);
                    int32x4_t gd0 = vdupq_n_s32(0), gd1 = vdupq_n_s32(0);
                    int32x4_t gd2 = vdupq_n_s32(0), gd3 = vdupq_n_s32(0);
                    int32x4_t ud0 = vdupq_n_s32(0), ud1 = vdupq_n_s32(0);
                    int32x4_t ud2 = vdupq_n_s32(0), ud3 = vdupq_n_s32(0);
                    GLACIER_PAIR_M4_DOT_CHUNK(0, 0);
                    GLACIER_PAIR_M4_DOT_CHUNK(16, 1);
                    const float16x8_t scale_pair0 =
                        vld1q_f16(tile_scales + (col / 8) * 8);
                    const float32x4_t gws =
                        vcvt_f32_f16(vget_low_f16(scale_pair0));
                    const float32x4_t uws = vcvt_high_f32_f16(scale_pair0);
                    GLACIER_PAIR_M4_FMA(col / 32);

                    gd0 = vdupq_n_s32(0); gd1 = vdupq_n_s32(0);
                    gd2 = vdupq_n_s32(0); gd3 = vdupq_n_s32(0);
                    ud0 = vdupq_n_s32(0); ud1 = vdupq_n_s32(0);
                    ud2 = vdupq_n_s32(0); ud3 = vdupq_n_s32(0);
                    GLACIER_PAIR_M4_DOT_CHUNK(32, 2);
                    GLACIER_PAIR_M4_DOT_CHUNK(48, 3);
                    const float16x8_t scale_pair1 =
                        vld1q_f16(tile_scales + ((col / 8) + 1) * 8);
                    const float32x4_t gws1 =
                        vcvt_f32_f16(vget_low_f16(scale_pair1));
                    const float32x4_t uws1 = vcvt_high_f32_f16(scale_pair1);
#define gws gws1
#define uws uws1
                    GLACIER_PAIR_M4_FMA((col + 8) / 32);
#undef gws
#undef uws
                }
            }
            gate_phase[phase][0] = ga0;
            gate_phase[phase][1] = ga1;
            gate_phase[phase][2] = ga2;
            gate_phase[phase][3] = ga3;
            up_phase[phase][0] = ua0;
            up_phase[phase][1] = ua1;
            up_phase[phase][2] = ua2;
            up_phase[phase][3] = ua3;
        }

#define GLACIER_PAIR_M4_PHASE_STORE_TOKEN(TOKEN) do { \
    const float32x4_t g01 = vaddq_f32( \
        gate_phase[0][TOKEN], gate_phase[1][TOKEN]); \
    const float32x4_t g23 = vaddq_f32( \
        gate_phase[2][TOKEN], gate_phase[3][TOKEN]); \
    const float32x4_t u01 = vaddq_f32( \
        up_phase[0][TOKEN], up_phase[1][TOKEN]); \
    const float32x4_t u23 = vaddq_f32( \
        up_phase[2][TOKEN], up_phase[3][TOKEN]); \
    vst1q_f32(gate_out##TOKEN + row0, vaddq_f32(g01, g23)); \
    vst1q_f32(up_out##TOKEN + row0, vaddq_f32(u01, u23)); \
} while (0)
        GLACIER_PAIR_M4_PHASE_STORE_TOKEN(0);
        GLACIER_PAIR_M4_PHASE_STORE_TOKEN(1);
        GLACIER_PAIR_M4_PHASE_STORE_TOKEN(2);
        GLACIER_PAIR_M4_PHASE_STORE_TOKEN(3);
#undef GLACIER_PAIR_M4_PHASE_STORE_TOKEN
    }
}

#undef GLACIER_PAIR_M4_DOT_CHUNK
#undef GLACIER_PAIR_M4_FMA
#endif

// Internal unchecked four-token dual-output entry point. The checked Zig
// edge owns lengths, stride, shape, and alias validation. Batch tails and
// non-DOTPROD targets retain the exact M1 implementation below.
void glacier_pair_nibble_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
    const int8_t *q_inputs, const float *activation_scales,
    const uint8_t *paired, const __fp16 *paired_scales,
    const float *gate_bias, const float *up_bias,
    float *gate_output, float *up_output,
    size_t batch, size_t out_features, size_t in_features,
    size_t group_size, size_t output_stride)
{
    if ((group_size != 8 && group_size != 16) ||
        out_features % 4 != 0 || in_features % 16 != 0) return;
    const size_t activation_group_size = group_size == 8 ? 32 : 16;
    const size_t as_stride =
        (in_features + activation_group_size - 1) / activation_group_size;
    size_t token = 0;
#if defined(__ARM_FEATURE_DOTPROD)
    for (; token + 3 < batch; token += 4) {
        const int8_t *q0 = q_inputs + (token + 0) * in_features;
        const int8_t *q1 = q_inputs + (token + 1) * in_features;
        const int8_t *q2 = q_inputs + (token + 2) * in_features;
        const int8_t *q3 = q_inputs + (token + 3) * in_features;
        const float *as0 = activation_scales + (token + 0) * as_stride;
        const float *as1 = activation_scales + (token + 1) * as_stride;
        const float *as2 = activation_scales + (token + 2) * as_stride;
        const float *as3 = activation_scales + (token + 3) * as_stride;
        float *go0 = gate_output + (token + 0) * output_stride;
        float *go1 = gate_output + (token + 1) * output_stride;
        float *go2 = gate_output + (token + 2) * output_stride;
        float *go3 = gate_output + (token + 3) * output_stride;
        float *uo0 = up_output + (token + 0) * output_stride;
        float *uo1 = up_output + (token + 1) * output_stride;
        float *uo2 = up_output + (token + 2) * output_stride;
        float *uo3 = up_output + (token + 3) * output_stride;
        if (group_size == 8) {
            pair_nibble_rows4_k16_phase_g8_m4(q0, q1, q2, q3, as0, as1, as2, as3,
                paired, paired_scales, gate_bias, up_bias,
                go0, go1, go2, go3, uo0, uo1, uo2, uo3,
                out_features, in_features);
        } else {
            pair_nibble_rows4_k16_phase_pair_g16_m4(q0, q1, q2, q3, as0, as1, as2, as3,
                paired, paired_scales, gate_bias, up_bias,
                go0, go1, go2, go3, uo0, uo1, uo2, uo3,
                out_features, in_features);
        }
    }
#endif
    for (; token < batch; ++token) {
        glacier_pair_nibble_matvec_neon_q8_prequant_f16scale_rows4_k16(
            q_inputs + token * in_features,
            activation_scales + token * as_stride,
            paired, paired_scales, gate_bias, up_bias,
            gate_output + token * output_stride,
            up_output + token * output_stride,
            out_features, in_features, group_size);
    }
}
void glacier_int4_matvec_neon_q8_f16scale_rows4_k16(
    const float *input,
    const uint8_t *packed,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t activation_groups =
        (in_features + activation_group_size - 1) / activation_group_size;
    int8_t q_input[in_features];
    float activation_scales[activation_groups];
    glacier_q8_activation_quantize(
        input, q_input, activation_scales, in_features, group_size);
    glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
        q_input, activation_scales, packed, scales_rows4, bias, output,
        out_features, in_features, group_size);
}

void glacier_int4_matvec_neon_q8_f16scale_rows4(
    const float *input,
    const uint8_t *packed,
    const __fp16 *scales_rows4,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t activation_groups =
        (in_features + activation_group_size - 1) / activation_group_size;
    int8_t q_input[in_features];
    float activation_scales[activation_groups];
    glacier_q8_activation_quantize(
        input, q_input, activation_scales, in_features, group_size);
    glacier_int4_matvec_neon_q8_prequant_f16scale_rows4(
        q_input, activation_scales, packed, scales_rows4, bias, output,
        out_features, in_features, group_size);
}

void glacier_int4_matvec_neon_q8_f16scale(
    const float *input,
    const uint8_t *packed,
    const __fp16 *scales,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t activation_groups =
        (in_features + activation_group_size - 1) / activation_group_size;
    int8_t q_input[in_features];
    float activation_scales[activation_groups];
    glacier_q8_activation_quantize(
        input, q_input, activation_scales, in_features, group_size);
    glacier_int4_matvec_neon_q8_prequant_f16scale(
        q_input, activation_scales, packed, scales, bias, output,
        out_features, in_features, group_size);
}

// INT8-expanded weight path.  It is the same blockwise-Q8 numerical scheme
// as the packed kernel above, but the nibble decode has been moved to model
// load time.  This trades 0.5 byte/weight of resident memory for a much
// shorter decode loop on the large MLP matrices.
void glacier_int8_matvec_neon_q8(
    const float *input,
    const int8_t *weights,
    const float *scales,
    const float *bias,
    float *output,
    size_t out_features,
    size_t in_features,
    size_t group_size)
{
    const size_t activation_group_size = group_size == 8 ? 32 : group_size;
    const size_t activation_groups =
        (in_features + activation_group_size - 1) / activation_group_size;
    int8_t q_input[in_features];
    float activation_scales[activation_groups];

    for (size_t group = 0; group < activation_groups; ++group) {
        const size_t start = group * activation_group_size;
        const size_t end = start + activation_group_size < in_features
            ? start + activation_group_size : in_features;
        float max_abs = 0.0f;
        for (size_t col = start; col < end; ++col) {
            const float a = fabsf(input[col]);
            if (a > max_abs) max_abs = a;
        }
        const float scale = max_abs / 127.0f;
        activation_scales[group] = scale;
        if (scale == 0.0f) {
            memset(q_input + start, 0, end - start);
        } else {
            const float inv_scale = 1.0f / scale;
            for (size_t col = start; col < end; ++col) {
                long q = lroundf(input[col] * inv_scale);
                if (q > 127) q = 127;
                if (q < -127) q = -127;
                q_input[col] = (int8_t)q;
            }
        }
    }

    const size_t row_groups = out_features / 4;
    const size_t scales_per_row = in_features / group_size;
    for (size_t tile = 0; tile < row_groups; ++tile) {
        float acc[4] = {
            bias ? bias[tile * 4 + 0] : 0.0f,
            bias ? bias[tile * 4 + 1] : 0.0f,
            bias ? bias[tile * 4 + 2] : 0.0f,
            bias ? bias[tile * 4 + 3] : 0.0f,
        };
        const size_t row0 = tile * 4;
        for (size_t col = 0; col < in_features; col += 16) {
            const int8x16_t q_act = vld1q_s8(q_input + col);
            for (size_t r = 0; r < 4; ++r) {
                const size_t row_offset = (row0 + r) * in_features + col;
                const int8x16_t q_weight = vld1q_s8(weights + row_offset);
                const size_t scale_base = (row0 + r) * scales_per_row + col / group_size;
#if defined(__ARM_FEATURE_DOTPROD)
                if (group_size == 8) {
                    const int32_t lo = dot_i8x8(vget_low_s8(q_weight), vget_low_s8(q_act));
                    const int32_t hi = dot_i8x8(vget_high_s8(q_weight), vget_high_s8(q_act));
                    acc[r] += (float)lo * scales[scale_base] * activation_scales[col / 32];
                    acc[r] += (float)hi * scales[scale_base + 1] * activation_scales[(col + 8) / 32];
                } else {
                    const int32x4_t dots = vdotq_s32(vdupq_n_s32(0), q_weight, q_act);
                    acc[r] += (float)vaddvq_s32(dots) * scales[scale_base] * activation_scales[col / group_size];
                }
#else
                int8_t w_tmp[16];
                int8_t a_tmp[16];
                vst1q_s8(w_tmp, q_weight);
                vst1q_s8(a_tmp, q_act);
                if (group_size == 8) {
                    int32_t lo = 0;
                    int32_t hi = 0;
                    for (size_t lane = 0; lane < 8; ++lane) {
                        lo += (int32_t)w_tmp[lane] * a_tmp[lane];
                        hi += (int32_t)w_tmp[lane + 8] * a_tmp[lane + 8];
                    }
                    acc[r] += (float)lo * scales[scale_base] * activation_scales[col / 32];
                    acc[r] += (float)hi * scales[scale_base + 1] * activation_scales[(col + 8) / 32];
                } else {
                    int32_t dot = 0;
                    for (size_t lane = 0; lane < 16; ++lane) dot += (int32_t)w_tmp[lane] * a_tmp[lane];
                    acc[r] += (float)dot * scales[scale_base] * activation_scales[col / group_size];
                }
#endif
            }
        }
        for (size_t r = 0; r < 4; ++r) output[row0 + r] = acc[r];
    }

    const size_t tail_start = row_groups * 4;
    for (size_t row = tail_start; row < out_features; ++row) {
        float acc = bias ? bias[row] : 0.0f;
        const size_t row_start_tail = row * in_features;
        for (size_t col = 0; col < in_features; ++col) {
            acc += (float)weights[row_start_tail + col] * (float)q_input[col] *
                scales[row * scales_per_row + col / group_size] *
                activation_scales[col / activation_group_size];
        }
        output[row] = acc;
    }
}
