//! INT4 on-the-fly matmul — the load-bearing optimization.
//!
//! Instead of dequantizing all weights to f32 upfront (which costs
//! 4x memory and 4x bandwidth), this kernel reads INT4-packed bytes
//! directly and dequantizes inside the dot-product inner loop. Each
//! nibble is unpacked to f32 via a lookup table + scale multiply, then
//! immediately multiplied by the activation and accumulated. The intermediate
//! f32 weight is never stored to memory.
//!
//! This is the single most impactful optimization for Glacier's thesis:
//! it cuts weight memory traffic by 8x (4-bit vs 32-bit) while keeping
//! the same numerics as the full-dequant path.

const std = @import("std");
const builtin = @import("builtin");
const tensor = @import("core").tensor;
const int4_weights = @import("../../int4_weights.zig");
const kernels = @import("kernels.zig");
pub const Tensor = tensor.Tensor;
pub const TensorError = tensor.TensorError;

/// Lookup table: maps a 4-bit value [0..15] to the dequantized offset
/// (value - 7), so 0→-7, 1→-6, ..., 7→0, ..., 15→8.
const NIBBLE_TO_OFFSET = [_]f32{
    -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7, 8,
};
const Vec8 = @Vector(8, f32);

extern fn glacier_int4_matvec_neon_f32(
    input: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f32,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_f16scale(
    input: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_q8(
    input: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f32,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_q8_activation_quantize(
    input: [*]const f32,
    q_input: [*]i8,
    activation_scales: [*]f32,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_q8_prequant(
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f32,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_q8_prequant_f16scale(
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_q8_prequant_f16scale_rows4(
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
    q_inputs: [*]const i8,
    activation_scales: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    batch: usize,
    out_features: usize,
    in_features: usize,
    group_size: usize,
    output_stride: usize,
) void;

extern fn glacier_pair_nibble_matvec_neon_q8_prequant_f16scale_rows4_k16(
    q_input: [*]const i8,
    activation_scales: [*]const f32,
    paired_weights: [*]const u8,
    paired_scales: [*]const f16,
    gate_bias: ?[*]const f32,
    up_bias: ?[*]const f32,
    gate_output: [*]f32,
    up_output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_pair_nibble_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
    q_inputs: [*]const i8,
    activation_scales: [*]const f32,
    paired_weights: [*]const u8,
    paired_scales: [*]const f16,
    gate_bias: ?[*]const f32,
    up_bias: ?[*]const f32,
    gate_output: [*]f32,
    up_output: [*]f32,
    batch: usize,
    out_features: usize,
    in_features: usize,
    group_size: usize,
    output_stride: usize,
) void;

extern fn glacier_int4_matvec_neon_q8_f16scale(
    input: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_q8_f16scale_rows4(
    input: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int4_matvec_neon_q8_f16scale_rows4_k16(
    input: [*]const f32,
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

extern fn glacier_int8_matvec_neon_q8(
    input: [*]const f32,
    weights: [*]const i8,
    scales: [*]const f32,
    bias: ?[*]const f32,
    output: [*]f32,
    out_features: usize,
    in_features: usize,
    group_size: usize,
) void;

/// INT4 matmul: out[batch, out_f] = x[batch, in_f] × W^T[out_f, in_f].
///
/// `int4_packed`: packed INT4 weights, 2 per byte (low nibble first).
/// `scales`: per-group f32 scales, group_size elements per group.
/// `group_size`: number of elements per quantization group (typically 64).
///
/// The function reads nibbles on-the-fly and never materializes the
/// full f32 weight matrix. Memory traffic for weights is reduced by
/// ~8x compared to f32 (4 bits vs 32 bits per element).
pub fn linearInt4OnTheFly(
    x: Tensor, // [batch, in_f] f32
    int4_packed: []const u8, // [ceil(out_f * in_f / 2)] bytes
    scales: []const f32, // [num_groups] where num_groups = ceil(out_f*in_f / group_size)
    bias: []const f32,
    out: Tensor, // [batch, out_f] f32
    out_f: usize,
    in_f: usize,
    group_size: usize,
) TensorError!void {
    if (x.shape.len != 2 or out.shape.len != 2) return TensorError.ShapeMismatch;
    const batch = x.shape[0];
    if (out.shape[0] != batch or out.shape[1] != out_f) return TensorError.ShapeMismatch;
    if (x.shape[1] != in_f) return TensorError.ShapeMismatch;
    if (group_size == 0) return TensorError.ShapeMismatch;
    const num_weights = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    const packed_len = ceilDiv(num_weights, 2);
    const scale_len = ceilDiv(num_weights, group_size);
    if (int4_packed.len < packed_len or scales.len < scale_len) return TensorError.ShapeMismatch;
    if (bias.len != 0 and bias.len != out_f) return TensorError.ShapeMismatch;

    const xv = x.asF32();
    const ov = out.asF32();

    // AArch64 block kernel: eliminate the scalar nibble-table gathers in the
    // normal g8/g16 decode profiles. Odd/external layouts retain the generic
    // Zig implementation below.
    if (comptime builtin.cpu.arch == .aarch64) {
        if (batch == 1 and (group_size == 8 or group_size == 16) and in_f % 16 == 0) {
            const bias_ptr: ?[*]const f32 = if (bias.len == out_f) bias.ptr else null;
            glacier_int4_matvec_neon_f32(
                xv.ptr,
                int4_packed.ptr,
                scales.ptr,
                bias_ptr,
                ov.ptr,
                out_f,
                in_f,
                group_size,
            );
            return;
        }
    }

    var i: usize = 0;
    while (i < batch) : (i += 1) {
        const x_row = xv[i * in_f .. (i + 1) * in_f];
        var o: usize = 0;
        while (o < out_f) : (o += 1) {
            var acc: f32 = if (bias.len == out_f) bias[o] else 0;
            const w_row_start = o * in_f;

            // Normal model matrices align rows and quantization groups to an
            // 8-element vector. Iterate group-by-group so the hot loop needs
            // no integer division or boundary checks. Keep the generic path
            // below for odd widths and externally produced payloads.
            if (group_size % 8 == 0 and w_row_start % group_size == 0 and in_f % group_size == 0) {
                var vector_acc: Vec8 = @splat(0);
                var elem: usize = 0;
                var group_idx = w_row_start / group_size;
                while (elem < in_f) : (group_idx += 1) {
                    const group_end = elem + group_size;
                    const scale: Vec8 = @splat(scales[group_idx]);
                    while (elem < group_end) : (elem += 8) {
                        vector_acc += loadInt4x8(int4_packed, w_row_start + elem) * loadF32x8(x_row, elem) * scale;
                    }
                }
                acc += @reduce(.Add, vector_acc);
            } else {
                var elem: usize = 0;
                while (elem + 8 <= in_f) {
                    const global_idx = w_row_start + elem;
                    const gi0 = global_idx / group_size;
                    const gi1 = (global_idx + 7) / group_size;
                    if (global_idx % 2 != 0 or gi0 != gi1) {
                        acc += x_row[elem] * dequantElement(int4_packed, scales, global_idx, group_size);
                        elem += 1;
                        continue;
                    }
                    acc += dotInt4x8(x_row, elem, int4_packed, global_idx) * scales[gi0];
                    elem += 8;
                }
                while (elem < in_f) : (elem += 1) {
                    const global_idx = w_row_start + elem;
                    acc += x_row[elem] * dequantElement(int4_packed, scales, global_idx, group_size);
                }
            }
            ov[i * out_f + o] = acc;
        }
    }
}

/// INT4 matvec with blockwise Q8 activations.  The portable implementation
/// is deliberately kept beside the F32 reference so every architecture gets
/// the same numerics; AArch64 uses the fused NEON kernel for the hot path.
/// Weight scales stay per-group, while each activation group receives one
/// symmetric scale.  This removes the per-element floating-point multiply
/// from the inner loop and is the main throughput path for decode.
pub fn linearInt4Q8(
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const expected = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    if (weights.num_elements != expected) return TensorError.ShapeMismatch;
    return linearInt4Q8OnTheFly(
        x,
        weights.packed_bytes,
        weights.scales,
        bias,
        out,
        out_f,
        in_f,
        weights.group_size,
    );
}

fn linearInt4Q8OnTheFly(
    x: Tensor,
    int4_packed: []const u8,
    weight_scales: []const f32,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    group_size: usize,
) TensorError!void {
    if (x.shape.len != 2 or out.shape.len != 2) return TensorError.ShapeMismatch;
    const batch = x.shape[0];
    if (out.shape[0] != batch or out.shape[1] != out_f or x.shape[1] != in_f)
        return TensorError.ShapeMismatch;
    if (group_size == 0 or in_f % group_size != 0 or
        bias.len != 0 and bias.len != out_f)
        return TensorError.ShapeMismatch;
    const num_weights = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    if (int4_packed.len < ceilDiv(num_weights, 2) or
        weight_scales.len < ceilDiv(num_weights, group_size))
        return TensorError.ShapeMismatch;

    // Q8 activation quantization is shared across rows of the output.  The
    // common decode case is batch=1; for prefill batches the portable path
    // still works and quantizes each input row independently.
    const xv = x.asF32();
    const ov = out.asF32();
    const groups = ceilDiv(in_f, group_size);
    const activation_group_size = if (group_size == 8) 32 else group_size;
    const activation_groups = ceilDiv(in_f, activation_group_size);
    var row_idx: usize = 0;
    while (row_idx < batch) : (row_idx += 1) {
        const x_row = xv[row_idx * in_f .. (row_idx + 1) * in_f];
        // Keep these arrays on the stack for decode-sized vectors.  The
        // fallback allocator above is intentionally not used: Zig's VLA
        // equivalent is unavailable, so bounded models use fixed storage and
        // larger inputs take the exact F32 implementation below.
        if (in_f > 16384 or activation_groups > 2048) {
            return linearInt4OnTheFly(x, int4_packed, weight_scales, bias, out, out_f, in_f, group_size);
        }
        var q_values: [16384]i8 = undefined;
        var activation_scales: [2048]f32 = undefined;
        var group: usize = 0;
        while (group < activation_groups) : (group += 1) {
            const start = group * activation_group_size;
            const end = @min(start + activation_group_size, in_f);
            var max_abs: f32 = 0;
            for (x_row[start..end]) |v| max_abs = @max(max_abs, @abs(v));
            const scale = max_abs / 127.0;
            activation_scales[group] = scale;
            if (scale == 0) {
                @memset(q_values[start..end], 0);
            } else {
                const inv = 1.0 / scale;
                for (x_row[start..end], q_values[start..end]) |v, *qv| {
                    var qi: i32 = @intFromFloat(@round(v * inv));
                    qi = std.math.clamp(qi, -127, 127);
                    qv.* = @intCast(qi);
                }
            }
        }

        var row: usize = 0;
        while (row < out_f) : (row += 1) {
            var acc: f32 = if (bias.len == out_f) bias[row] else 0;
            const row_start = row * in_f;
            var output_group: usize = 0;
            while (output_group < groups) : (output_group += 1) {
                const start = output_group * group_size;
                const end = @min(start + group_size, in_f);
                var dot: i32 = 0;
                var col = start;
                while (col < end) : (col += 1) {
                    const idx = row_start + col;
                    const packed_byte = int4_packed[idx / 2];
                    const nibble: i32 = @intCast(if (idx & 1 == 0) packed_byte & 0x0f else packed_byte >> 4);
                    dot += (nibble - 7) * @as(i32, q_values[col]);
                }
                acc += @as(f32, @floatFromInt(dot)) * weight_scales[(row_start + start) / group_size] * activation_scales[start / activation_group_size];
            }
            ov[row_idx * out_f + row] = acc;
        }
    }
}

/// AArch64 fast path for one-token Q8 decode.  Other shapes use the portable
/// reference above; this keeps the public function safe for all callers.
pub fn linearInt4WeightQ8(
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const expected = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    if (weights.num_elements != expected) return TensorError.ShapeMismatch;
    const scale_count = if (weights.group_size == 0)
        0
    else
        ceilDiv(expected, weights.group_size);
    if (weights.expanded_i8.len >= expected and weights.scales.len >= scale_count and
        comptime builtin.cpu.arch == .aarch64)
    {
        if (x.shape.len == 2 and x.shape[0] == 1 and
            (weights.group_size == 8 or weights.group_size == 16) and in_f % 16 == 0 and
            out.shape.len == 2 and out.shape[0] == 1 and out.shape[1] == out_f and
            x.shape[1] == in_f and (bias.len == 0 or bias.len == out_f))
        {
            const bias_ptr: ?[*]const f32 = if (bias.len == out_f) bias.ptr else null;
            glacier_int8_matvec_neon_q8(
                x.asF32().ptr,
                weights.expanded_i8.ptr,
                weights.scales.ptr,
                bias_ptr,
                out.asF32().ptr,
                out_f,
                in_f,
                weights.group_size,
            );
            return;
        }
    }
    // Q8 activation conversion is amortized over medium/large hidden
    // projections, but the vocabulary head is output-heavy and its tiny
    // input vector makes the conversion cost dominate on M1.
    if (out_f > 65536 and weights.scales.len >= scale_count and
        weights.packed_layout == .row_major)
        return linearInt4Weight(x, weights, bias, out, out_f, in_f);
    // The row-tiled SDOT path handles g8 as well as g16. Keep the explicit
    // FP32 activation option available for quality/portability comparisons.
    if (comptime builtin.cpu.arch == .aarch64) {
        if (x.shape.len == 2 and x.shape[0] == 1 and
            (weights.group_size == 8 or weights.group_size == 16) and in_f % 16 == 0)
        {
            const packed_len = ceilDiv(expected, 2);
            if (weights.packed_bytes.len < packed_len or
                x.shape[1] != in_f or out.shape.len != 2 or out.shape[0] != 1 or out.shape[1] != out_f or
                (bias.len != 0 and bias.len != out_f))
                return TensorError.ShapeMismatch;
            const bias_ptr: ?[*]const f32 = if (bias.len == out_f) bias.ptr else null;
            if (weights.scales_f16_rows4.len >= scale_count and out_f % 4 == 0) {
                if (weights.packed_layout == .rows4_k16) {
                    glacier_int4_matvec_neon_q8_f16scale_rows4_k16(
                        x.asF32().ptr,
                        weights.packed_bytes.ptr,
                        weights.scales_f16_rows4.ptr,
                        bias_ptr,
                        out.asF32().ptr,
                        out_f,
                        in_f,
                        weights.group_size,
                    );
                    return;
                }
                glacier_int4_matvec_neon_q8_f16scale_rows4(
                    x.asF32().ptr,
                    weights.packed_bytes.ptr,
                    weights.scales_f16_rows4.ptr,
                    bias_ptr,
                    out.asF32().ptr,
                    out_f,
                    in_f,
                    weights.group_size,
                );
                return;
            }
            if (weights.packed_layout != .row_major) return TensorError.ShapeMismatch;
            if (weights.scales_f16.len >= scale_count) {
                glacier_int4_matvec_neon_q8_f16scale(
                    x.asF32().ptr,
                    weights.packed_bytes.ptr,
                    weights.scales_f16.ptr,
                    bias_ptr,
                    out.asF32().ptr,
                    out_f,
                    in_f,
                    weights.group_size,
                );
                return;
            }
            if (weights.scales.len < scale_count) return TensorError.ShapeMismatch;
            glacier_int4_matvec_neon_q8(
                x.asF32().ptr,
                weights.packed_bytes.ptr,
                weights.scales.ptr,
                bias_ptr,
                out.asF32().ptr,
                out_f,
                in_f,
                weights.group_size,
            );
            return;
        }
    }
    if (weights.packed_layout != .row_major) return TensorError.ShapeMismatch;
    return linearInt4Q8(x, weights, bias, out, out_f, in_f);
}

pub fn q8ActivationScaleCount(in_f: usize, group_size: usize) usize {
    const activation_group_size = if (group_size == 8) 32 else group_size;
    return ceilDiv(in_f, activation_group_size);
}

/// Quantize one activation vector once so several projections can share it.
pub fn quantizeQ8Activation(
    input: []const f32,
    group_size: usize,
    q_input: []i8,
    activation_scales: []f32,
) TensorError!void {
    if (group_size != 8 and group_size != 16) return TensorError.ShapeMismatch;
    if (q_input.len < input.len or
        activation_scales.len < q8ActivationScaleCount(input.len, group_size))
        return TensorError.ShapeMismatch;
    if (comptime builtin.cpu.arch != .aarch64) return TensorError.DTypeUnsupported;
    glacier_q8_activation_quantize(
        input.ptr,
        q_input.ptr,
        activation_scales.ptr,
        input.len,
        group_size,
    );
}

/// Constructor-only kernel recipe for the production compact rows4/K16 INT4 x
/// Q8 projection. The general checked wrapper remains the compatibility
/// oracle; sealing this one high-value layout keeps the hot descriptor small
/// and the worker path branch-free. Its raw-pointer fields are an engine-
/// internal contract: callers must use `init`, must keep every backing alive,
/// and must not forge or mutate the returned value.
pub const PreparedQ8MatvecPlan = struct {
    packed_weights: [*]const u8,
    scales: [*]const f16,
    bias: ?[*]const f32,
    output: [*]f32,
    out_f: u32,
    in_f: u32,
    group_size: u32,
    packed_bytes_per_row: u32,
    scales_per_row: u32,

    /// Validate static projection metadata and resolve its kernel before any
    /// output can be written. The returned descriptor contains no Tensor shape
    /// pointers, so it remains valid after stack-local view metadata expires.
    pub fn init(
        weights: int4_weights.Int4WeightData,
        bias: []const f32,
        out: Tensor,
        out_f: usize,
        in_f: usize,
    ) TensorError!PreparedQ8MatvecPlan {
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        if (out_f == 0 or in_f == 0 or
            out_f > std.math.maxInt(u32) or in_f > std.math.maxInt(u32) or
            (weights.group_size != 8 and weights.group_size != 16) or
            weights.packed_layout != .rows4_k16 or out_f % 4 != 0 or
            in_f % 16 != 0 or in_f % weights.group_size != 0)
            return TensorError.ShapeMismatch;

        const expected = std.math.mul(usize, out_f, in_f) catch
            return TensorError.ShapeMismatch;
        const packed_count = ceilDiv(expected, 2);
        const scale_count = ceilDiv(expected, weights.group_size);
        if (weights.num_elements != expected or
            weights.packed_bytes.len < packed_count or
            weights.scales_f16_rows4.len < scale_count or
            (bias.len != 0 and bias.len != out_f) or
            out.dtype != .f32 or out.shape.len != 2 or out.shape[0] != 1 or
            out.shape[1] != out_f)
            return TensorError.ShapeMismatch;

        const output_bytes = std.math.mul(usize, out_f, @sizeOf(f32)) catch
            return TensorError.ShapeMismatch;
        if (out.data.len != output_bytes or
            @intFromPtr(out.data.ptr) % @alignOf(f32) != 0)
            return TensorError.ShapeMismatch;
        const output_ptr: [*]f32 = @ptrFromInt(@intFromPtr(out.data.ptr));
        const packed_bytes = weights.packed_bytes[0..packed_count];
        const scale_bytes = std.mem.sliceAsBytes(
            weights.scales_f16_rows4[0..scale_count],
        );
        if (byteRangesOverlap(out.data, packed_bytes) or
            byteRangesOverlap(out.data, scale_bytes) or
            (bias.len != 0 and
                byteRangesOverlap(out.data, std.mem.sliceAsBytes(bias))))
            return TensorError.ShapeMismatch;

        return .{
            .packed_weights = packed_bytes.ptr,
            .scales = weights.scales_f16_rows4[0..scale_count].ptr,
            .bias = if (bias.len == out_f) bias.ptr else null,
            .output = output_ptr,
            .out_f = @intCast(out_f),
            .in_f = @intCast(in_f),
            .group_size = weights.group_size,
            .packed_bytes_per_row = @intCast(in_f / 2),
            .scales_per_row = @intCast(in_f / weights.group_size),
        };
    }

    /// Bind stable request-local activation scratch once. The contents may be
    /// overwritten for every token; only base addresses and capacities form
    /// part of the binding contract.
    pub fn bind(
        self: PreparedQ8MatvecPlan,
        q_input: []const i8,
        activation_scales: []const f32,
    ) TensorError!BoundPreparedQ8MatvecPlan {
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        const in_f: usize = self.in_f;
        const out_f: usize = self.out_f;
        if (out_f == 0 or in_f == 0 or out_f % 4 != 0 or in_f % 16 != 0 or
            (self.group_size != 8 and self.group_size != 16) or
            self.packed_bytes_per_row != in_f / 2 or
            self.scales_per_row != in_f / self.group_size)
            return TensorError.ShapeMismatch;
        const scale_count = q8ActivationScaleCount(in_f, self.group_size);
        if (q_input.len < in_f or activation_scales.len < scale_count)
            return TensorError.ShapeMismatch;
        const output_bytes = std.mem.sliceAsBytes(self.output[0..self.out_f]);
        const q_bytes = std.mem.sliceAsBytes(q_input[0..in_f]);
        const activation_bytes = std.mem.sliceAsBytes(
            activation_scales[0..scale_count],
        );
        if (byteRangesOverlap(output_bytes, q_bytes) or
            byteRangesOverlap(output_bytes, activation_bytes) or
            byteRangesOverlap(q_bytes, activation_bytes))
            return TensorError.ShapeMismatch;
        return .{
            .recipe = self,
            .q_input = q_input[0..in_f].ptr,
            .activation_scales = activation_scales[0..scale_count].ptr,
        };
    }
};

fn byteRangesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

/// Constructor-only activation binding for `PreparedQ8MatvecPlan`. Row ranges
/// remain checked because workers derive them dynamically, but every
/// expensive/static invariant has already been proven by `init` and `bind`.
/// Raw-pointer extents cannot be reconstructed from a forged value; keep the
/// descriptor immutable and use only the constructors above.
pub const BoundPreparedQ8MatvecPlan = struct {
    recipe: PreparedQ8MatvecPlan,
    q_input: [*]const i8,
    activation_scales: [*]const f32,

    pub fn runRows(
        self: BoundPreparedQ8MatvecPlan,
        row_start: usize,
        row_end: usize,
    ) TensorError!void {
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        const plan = self.recipe;
        const out_f: usize = plan.out_f;
        const in_f: usize = plan.in_f;
        const group_size: usize = plan.group_size;
        if (out_f == 0 or in_f == 0 or out_f % 4 != 0 or in_f % 16 != 0 or
            (group_size != 8 and group_size != 16) or
            plan.packed_bytes_per_row != in_f / 2 or
            plan.scales_per_row != in_f / group_size)
            return TensorError.ShapeMismatch;
        if (row_start >= row_end or row_end > out_f)
            return TensorError.ShapeMismatch;
        if (row_start % 4 != 0 or row_end % 4 != 0)
            return TensorError.ShapeMismatch;

        // Full-matrix construction already proves the backing extents. Keep
        // range arithmetic checked here so invalid geometry fails closed; raw
        // pointer extents remain the constructor-only caller contract.
        const start_element = std.math.mul(usize, row_start, in_f) catch
            return TensorError.ShapeMismatch;
        const end_element = std.math.mul(usize, row_end, in_f) catch
            return TensorError.ShapeMismatch;
        if (start_element % 2 != 0 or end_element % 2 != 0 or
            start_element % group_size != 0 or
            end_element % group_size != 0)
            return TensorError.ShapeMismatch;
        self.runRowsPrevalidated(row_start, row_end);
    }

    /// Internal sealed-schedule entry. Callers must derive the range from the
    /// prevalidated 4-row-aligned tile domain and hold the executor binding for
    /// the entire call. Debug builds retain assertions; ReleaseFast performs
    /// only pointer offsets plus the selected C kernel call.
    inline fn runRowsPrevalidated(
        self: BoundPreparedQ8MatvecPlan,
        row_start: usize,
        row_end: usize,
    ) void {
        const plan = self.recipe;
        const out_f: usize = plan.out_f;
        const in_f: usize = plan.in_f;
        const group_size: usize = plan.group_size;
        std.debug.assert(row_start < row_end and row_end <= out_f);
        std.debug.assert(row_start % 4 == 0 and row_end % 4 == 0);
        const packed_start = row_start * @as(usize, plan.packed_bytes_per_row);
        const scale_start = row_start * @as(usize, plan.scales_per_row);
        const row_count = row_end - row_start;
        const bias_ptr: ?[*]const f32 = if (plan.bias) |bias|
            bias + row_start
        else
            null;

        if (comptime builtin.cpu.arch == .aarch64) {
            glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
                self.q_input,
                self.activation_scales,
                plan.packed_weights + packed_start,
                plan.scales + scale_start,
                bias_ptr,
                plan.output + row_start,
                row_count,
                in_f,
                group_size,
            );
        } else {
            unreachable;
        }
    }
};

/// Execute a one-token packed projection from a caller-owned Q8 activation.
/// The weight can be a full matrix or an output-row shard.
pub fn linearInt4WeightQ8Prepared(
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const expected = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    if (weights.group_size != 8 and weights.group_size != 16) return TensorError.ShapeMismatch;
    const scale_count = ceilDiv(expected, weights.group_size);
    const has_scale_stream = weights.scales.len >= scale_count or
        weights.scales_f16.len >= scale_count or
        weights.scales_f16_rows4.len >= scale_count;
    if (weights.num_elements != expected or in_f % weights.group_size != 0 or
        q_input.len < in_f or
        activation_scales.len < q8ActivationScaleCount(in_f, weights.group_size) or
        weights.packed_bytes.len < ceilDiv(expected, 2) or
        !has_scale_stream or
        (weights.scales_f16.len != 0 and
            weights.scales_f16.len < ceilDiv(expected, weights.group_size)) or
        (weights.scales_f16_rows4.len != 0 and
            weights.scales_f16_rows4.len < ceilDiv(expected, weights.group_size)) or
        out.shape.len != 2 or out.shape[0] != 1 or out.shape[1] != out_f or
        (bias.len != 0 and bias.len != out_f))
        return TensorError.ShapeMismatch;
    if (comptime builtin.cpu.arch != .aarch64) return TensorError.DTypeUnsupported;
    const bias_ptr: ?[*]const f32 = if (bias.len == out_f) bias.ptr else null;
    if (weights.scales_f16_rows4.len != 0 and out_f % 4 == 0) {
        if (weights.packed_layout == .rows4_k16) {
            if (in_f % 16 != 0) return TensorError.ShapeMismatch;
            glacier_int4_matvec_neon_q8_prequant_f16scale_rows4_k16(
                q_input.ptr,
                activation_scales.ptr,
                weights.packed_bytes.ptr,
                weights.scales_f16_rows4.ptr,
                bias_ptr,
                out.asF32().ptr,
                out_f,
                in_f,
                weights.group_size,
            );
            return;
        }
        glacier_int4_matvec_neon_q8_prequant_f16scale_rows4(
            q_input.ptr,
            activation_scales.ptr,
            weights.packed_bytes.ptr,
            weights.scales_f16_rows4.ptr,
            bias_ptr,
            out.asF32().ptr,
            out_f,
            in_f,
            weights.group_size,
        );
        return;
    }
    if (weights.packed_layout != .row_major) return TensorError.ShapeMismatch;
    if (weights.scales_f16.len != 0) {
        glacier_int4_matvec_neon_q8_prequant_f16scale(
            q_input.ptr,
            activation_scales.ptr,
            weights.packed_bytes.ptr,
            weights.scales_f16.ptr,
            bias_ptr,
            out.asF32().ptr,
            out_f,
            in_f,
            weights.group_size,
        );
        return;
    }
    if (weights.scales.len < scale_count) return TensorError.ShapeMismatch;
    glacier_int4_matvec_neon_q8_prequant(
        q_input.ptr,
        activation_scales.ptr,
        weights.packed_bytes.ptr,
        weights.scales.ptr,
        bias_ptr,
        out.asF32().ptr,
        out_f,
        in_f,
        weights.group_size,
    );
}

/// Quantize a row-major activation matrix into the same per-row Q8 format
/// consumed by the one-token packed kernel. Rows are independent, so this is
/// numerically identical to calling `quantizeQ8Activation` for every token.
pub fn quantizeQ8ActivationBatch(
    input: []const f32,
    batch: usize,
    in_f: usize,
    group_size: usize,
    q_output: []i8,
    activation_scales: []f32,
) TensorError!void {
    // Validate before q8ActivationScaleCount: unsupported values (especially
    // zero) must not reach its ceilDiv denominator.
    if (batch == 0 or in_f == 0 or (group_size != 8 and group_size != 16))
        return TensorError.ShapeMismatch;
    const input_count = std.math.mul(usize, batch, in_f) catch
        return TensorError.ShapeMismatch;
    const scale_stride = q8ActivationScaleCount(in_f, group_size);
    const scale_count = std.math.mul(usize, batch, scale_stride) catch
        return TensorError.ShapeMismatch;
    if (input.len < input_count or q_output.len < input_count or
        activation_scales.len < scale_count)
        return TensorError.ShapeMismatch;
    for (0..batch) |row| {
        try quantizeQ8Activation(
            input[row * in_f ..][0..in_f],
            group_size,
            q_output[row * in_f ..][0..in_f],
            activation_scales[row * scale_stride ..][0..scale_stride],
        );
    }
}

test "batch Q8 quantization rejects invalid group sizes before stride math" {
    var input: [16]f32 = @splat(1.0);
    var q_output: [16]i8 = undefined;
    var scales: [2]f32 = undefined;
    for ([_]usize{ 0, 7, 32 }) |group_size| {
        try testing.expectError(
            TensorError.ShapeMismatch,
            quantizeQ8ActivationBatch(
                &input,
                1,
                input.len,
                group_size,
                &q_output,
                &scales,
            ),
        );
    }
}

/// Execute an MxK by packed-KxN projection from caller-prequantized Q8 rows.
/// `output_stride` permits output-row shards to write directly into a larger
/// row-major [batch, full_out] tensor without a gather/copy step.
fn validatePreparedBatch(
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    output_len: usize,
    batch: usize,
    out_f: usize,
    in_f: usize,
    output_stride: usize,
) TensorError!void {
    if (batch == 0 or out_f == 0 or in_f == 0 or output_stride < out_f or
        (weights.group_size != 8 and weights.group_size != 16) or
        weights.packed_layout != .rows4_k16 or out_f % 4 != 0 or in_f % 16 != 0)
        return TensorError.ShapeMismatch;
    const expected = std.math.mul(usize, out_f, in_f) catch
        return TensorError.ShapeMismatch;
    const q_count = std.math.mul(usize, batch, in_f) catch
        return TensorError.ShapeMismatch;
    const activation_stride = q8ActivationScaleCount(in_f, weights.group_size);
    const activation_count = std.math.mul(usize, batch, activation_stride) catch
        return TensorError.ShapeMismatch;
    const scale_count = ceilDiv(expected, weights.group_size);
    const last_row_offset = std.math.mul(usize, batch - 1, output_stride) catch
        return TensorError.ShapeMismatch;
    const output_count = std.math.add(usize, last_row_offset, out_f) catch
        return TensorError.ShapeMismatch;
    if (weights.num_elements != expected or q_input.len < q_count or
        activation_scales.len < activation_count or
        weights.packed_bytes.len < ceilDiv(expected, 2) or
        weights.scales_f16_rows4.len < scale_count or
        (weights.scales.len != 0 and weights.scales.len < scale_count) or
        (weights.scales_f16.len != 0 and weights.scales_f16.len < scale_count) or
        output_len < output_count or (bias.len != 0 and bias.len != out_f))
        return TensorError.ShapeMismatch;
}

fn checkedBatchOutput(out: Tensor, out_f: usize) TensorError![]f32 {
    if (out.dtype != .f32 or out.shape.len != 2 or out.shape[0] == 0 or
        out.shape[1] != out_f or out_f == 0)
        return TensorError.ShapeMismatch;
    const output_count = std.math.mul(usize, out.shape[0], out_f) catch
        return TensorError.ShapeMismatch;
    const output_bytes = std.math.mul(usize, output_count, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    if (out.data.len < output_bytes or
        @intFromPtr(out.data.ptr) % @alignOf(f32) != 0)
        return TensorError.ShapeMismatch;
    const ptr: [*]f32 = @ptrFromInt(@intFromPtr(out.data.ptr));
    return ptr[0..output_count];
}

fn byteSlicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

pub const pair_nibble_compact_task_scratch_alignment: usize = 64;

/// Exact caller-owned tensor-storage contract for the compact batch PairNibble
/// producer. Tile storage is slot-major `[task][batch][tile_rows]`
/// independently for gate and up. `task_count` is the number of leading slots
/// dispatched after the caller's slot and scheduling caps are applied.
pub const PairNibbleSiluQ8CompactBatchLedger = struct {
    batch: usize,
    in_f: usize,
    out_f: usize,
    producer_group_size: u32,
    down_group_size: u32,
    down_activation_group_size: usize,
    tile_rows: usize,
    task_slots: usize,
    max_tasks: usize,
    shard_count: usize,
    task_count: usize,
    input_count: usize,
    producer_q_count: usize,
    producer_scale_stride: usize,
    producer_scale_count: usize,
    q_output_count: usize,
    output_scale_stride: usize,
    output_scale_count: usize,
    tile_slot_stride: usize,
    tile_scratch_count_per_branch: usize,
};

/// Derive every logical extent without consulting storage or mutating caller
/// memory. Keeping this as the public allocation oracle prevents prefill-frame
/// admission and the kernel edge from drifting onto different byte ledgers.
pub fn derivePairNibbleSiluQ8CompactBatchLedger(
    batch: usize,
    in_f: usize,
    out_f: usize,
    producer_group_size: u32,
    down_group_size: u32,
    tile_rows: usize,
    task_slots: usize,
    max_tasks: usize,
) TensorError!PairNibbleSiluQ8CompactBatchLedger {
    if (batch == 0 or in_f == 0 or in_f % 16 != 0 or
        out_f == 0 or out_f % 4 != 0 or
        (producer_group_size != 8 and producer_group_size != 16) or
        (down_group_size != 8 and down_group_size != 16) or
        tile_rows == 0 or tile_rows % 32 != 0 or
        task_slots == 0 or max_tasks == 0)
        return TensorError.ShapeMismatch;

    const input_count = std.math.mul(usize, batch, in_f) catch
        return TensorError.ShapeMismatch;
    const producer_scale_stride = q8ActivationScaleCount(
        in_f,
        producer_group_size,
    );
    const producer_scale_count = std.math.mul(
        usize,
        batch,
        producer_scale_stride,
    ) catch return TensorError.ShapeMismatch;
    const q_output_count = std.math.mul(usize, batch, out_f) catch
        return TensorError.ShapeMismatch;
    const down_activation_group_size: usize = if (down_group_size == 8)
        32
    else
        16;
    const output_scale_stride = ceilDiv(out_f, down_activation_group_size);
    const output_scale_count = std.math.mul(
        usize,
        batch,
        output_scale_stride,
    ) catch return TensorError.ShapeMismatch;
    const tile_slot_stride = std.math.mul(usize, batch, tile_rows) catch
        return TensorError.ShapeMismatch;
    const tile_scratch_count_per_branch = std.math.mul(
        usize,
        task_slots,
        tile_slot_stride,
    ) catch return TensorError.ShapeMismatch;
    const shard_count = out_f / tile_rows +
        @intFromBool(out_f % tile_rows != 0);
    const task_count = @min(@min(task_slots, max_tasks), shard_count);
    if (task_count == 0) return TensorError.ShapeMismatch;

    // Prove every subsequent slice-to-byte conversion before preflight begins.
    const f32_counts = [_]usize{
        input_count,
        producer_scale_count,
        output_scale_count,
        tile_scratch_count_per_branch,
        out_f,
    };
    for (f32_counts) |count| {
        _ = std.math.mul(usize, count, @sizeOf(f32)) catch
            return TensorError.ShapeMismatch;
    }

    return .{
        .batch = batch,
        .in_f = in_f,
        .out_f = out_f,
        .producer_group_size = producer_group_size,
        .down_group_size = down_group_size,
        .down_activation_group_size = down_activation_group_size,
        .tile_rows = tile_rows,
        .task_slots = task_slots,
        .max_tasks = max_tasks,
        .shard_count = shard_count,
        .task_count = task_count,
        .input_count = input_count,
        .producer_q_count = input_count,
        .producer_scale_stride = producer_scale_stride,
        .producer_scale_count = producer_scale_count,
        .q_output_count = q_output_count,
        .output_scale_stride = output_scale_stride,
        .output_scale_count = output_scale_count,
        .tile_slot_stride = tile_slot_stride,
        .tile_scratch_count_per_branch = tile_scratch_count_per_branch,
    };
}

/// Constructor-only recipe for the typed PairNibble producer. Pair bytes are
/// deliberately never exposed as `Int4WeightData`: one byte represents both
/// logical branches and only this dual-output kernel may interpret it.
///
/// The recipe supports arbitrary positive batch sizes. The C edge consumes
/// complete M4 blocks and executes the exact M1 kernel for the M1--M3 tail.
/// `output_stride` permits a four-row weight shard to write directly into a
/// larger row-major destination without a gather step.
pub const PreparedPairNibbleQ8Plan = struct {
    paired_weights: [*]const u8,
    paired_scales: [*]const f16,
    gate_bias: ?[*]const f32,
    up_bias: ?[*]const f32,
    gate_output: [*]f32,
    up_output: [*]f32,
    batch: usize,
    out_f: usize,
    in_f: usize,
    group_size: usize,
    output_stride: usize,
    output_count: usize,
    paired_byte_count: usize,
    paired_scale_count: usize,
    paired_bytes_per_row: usize,
    paired_scales_per_row: usize,

    /// Prove all static geometry, extents, alignment and write aliases before
    /// an activation scratch byte or output element can be modified.
    pub fn init(
        weights: int4_weights.PairNibbleWeightData,
        gate_bias: []const f32,
        up_bias: []const f32,
        gate_output: []f32,
        up_output: []f32,
        batch: usize,
        output_stride: usize,
    ) TensorError!PreparedPairNibbleQ8Plan {
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        int4_weights.validatePairNibble(weights) catch
            return TensorError.ShapeMismatch;
        const out_f = weights.out_f;
        const in_f = weights.in_f;
        if (batch == 0 or output_stride < out_f or
            out_f == 0 or out_f % 4 != 0 or
            in_f == 0 or in_f % 16 != 0 or
            (gate_bias.len != 0 and gate_bias.len != out_f) or
            (up_bias.len != 0 and up_bias.len != out_f))
            return TensorError.ShapeMismatch;

        const last_row_offset = std.math.mul(
            usize,
            batch - 1,
            output_stride,
        ) catch return TensorError.ShapeMismatch;
        const output_count = std.math.add(usize, last_row_offset, out_f) catch
            return TensorError.ShapeMismatch;
        const paired_scale_count = std.math.mul(
            usize,
            weights.num_elements_per_branch / weights.group_size,
            2,
        ) catch return TensorError.ShapeMismatch;
        const paired_scales_per_row = std.math.mul(
            usize,
            in_f / weights.group_size,
            2,
        ) catch return TensorError.ShapeMismatch;
        if (gate_output.len < output_count or up_output.len < output_count or
            @intFromPtr(gate_output.ptr) % @alignOf(f32) != 0 or
            @intFromPtr(up_output.ptr) % @alignOf(f32) != 0 or
            weights.paired_bytes.len != weights.num_elements_per_branch or
            weights.scales_f16_pairs.len != paired_scale_count)
            return TensorError.ShapeMismatch;

        const gate_write = std.mem.sliceAsBytes(gate_output[0..output_count]);
        const up_write = std.mem.sliceAsBytes(up_output[0..output_count]);
        if (byteSlicesOverlap(gate_write, up_write))
            return TensorError.ShapeMismatch;
        const persistent_reads = [_][]const u8{
            weights.paired_bytes,
            std.mem.sliceAsBytes(weights.scales_f16_pairs),
            std.mem.sliceAsBytes(gate_bias),
            std.mem.sliceAsBytes(up_bias),
        };
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(gate_write, read) or
                byteSlicesOverlap(up_write, read))
                return TensorError.ShapeMismatch;
        }

        return .{
            .paired_weights = weights.paired_bytes.ptr,
            .paired_scales = weights.scales_f16_pairs.ptr,
            .gate_bias = if (gate_bias.len == out_f) gate_bias.ptr else null,
            .up_bias = if (up_bias.len == out_f) up_bias.ptr else null,
            .gate_output = gate_output.ptr,
            .up_output = up_output.ptr,
            .batch = batch,
            .out_f = out_f,
            .in_f = in_f,
            .group_size = weights.group_size,
            .output_stride = output_stride,
            .output_count = output_count,
            .paired_byte_count = weights.paired_bytes.len,
            .paired_scale_count = paired_scale_count,
            .paired_bytes_per_row = in_f,
            .paired_scales_per_row = paired_scales_per_row,
        };
    }

    /// Bind a complete prequantized activation batch. Binding is intentionally
    /// checked before quantization in the float-input wrappers, so scratch that
    /// aliases weights, scales, biases or outputs is rejected without writes.
    pub fn bind(
        self: PreparedPairNibbleQ8Plan,
        q_input: []const i8,
        activation_scales: []const f32,
    ) TensorError!BoundPreparedPairNibbleQ8Plan {
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        if (self.batch == 0 or self.out_f == 0 or self.out_f % 4 != 0 or
            self.in_f == 0 or self.in_f % 16 != 0 or
            (self.group_size != 8 and self.group_size != 16) or
            self.output_stride < self.out_f or
            self.paired_bytes_per_row != self.in_f or
            self.paired_scales_per_row !=
                2 * (self.in_f / self.group_size))
            return TensorError.ShapeMismatch;
        const q_count = std.math.mul(usize, self.batch, self.in_f) catch
            return TensorError.ShapeMismatch;
        const activation_stride = q8ActivationScaleCount(
            self.in_f,
            self.group_size,
        );
        const activation_count = std.math.mul(
            usize,
            self.batch,
            activation_stride,
        ) catch return TensorError.ShapeMismatch;
        if (q_input.len < q_count or activation_scales.len < activation_count)
            return TensorError.ShapeMismatch;

        const q_bytes = std.mem.sliceAsBytes(q_input[0..q_count]);
        const activation_bytes = std.mem.sliceAsBytes(
            activation_scales[0..activation_count],
        );
        const gate_write = std.mem.sliceAsBytes(
            self.gate_output[0..self.output_count],
        );
        const up_write = std.mem.sliceAsBytes(
            self.up_output[0..self.output_count],
        );
        if (byteSlicesOverlap(q_bytes, activation_bytes) or
            byteSlicesOverlap(q_bytes, gate_write) or
            byteSlicesOverlap(q_bytes, up_write) or
            byteSlicesOverlap(activation_bytes, gate_write) or
            byteSlicesOverlap(activation_bytes, up_write))
            return TensorError.ShapeMismatch;

        // These are read/read aliases once bound, but the float-input API
        // writes both scratch streams immediately before dispatch. Rejecting
        // them here keeps the same plan safe for both public entry points.
        const persistent_reads = [_][]const u8{
            self.paired_weights[0..self.paired_byte_count],
            std.mem.sliceAsBytes(
                self.paired_scales[0..self.paired_scale_count],
            ),
            if (self.gate_bias) |bias|
                std.mem.sliceAsBytes(bias[0..self.out_f])
            else
                &.{},
            if (self.up_bias) |bias|
                std.mem.sliceAsBytes(bias[0..self.out_f])
            else
                &.{},
        };
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(q_bytes, read) or
                byteSlicesOverlap(activation_bytes, read))
                return TensorError.ShapeMismatch;
        }
        return .{
            .recipe = self,
            .q_input = q_input[0..q_count].ptr,
            .activation_scales = activation_scales[0..activation_count].ptr,
        };
    }
};

/// Activation-bound PairNibble recipe. Four-row ranges are the only legal
/// ownership unit because each physical weight/scale tile interleaves exactly
/// four output rows.
pub const BoundPreparedPairNibbleQ8Plan = struct {
    recipe: PreparedPairNibbleQ8Plan,
    q_input: [*]const i8,
    activation_scales: [*]const f32,

    pub fn runRows(
        self: BoundPreparedPairNibbleQ8Plan,
        row_start: usize,
        row_end: usize,
    ) TensorError!void {
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        const plan = self.recipe;
        if (row_start >= row_end or row_end > plan.out_f or
            row_start % 4 != 0 or row_end % 4 != 0)
            return TensorError.ShapeMismatch;
        const paired_start = std.math.mul(
            usize,
            row_start,
            plan.paired_bytes_per_row,
        ) catch return TensorError.ShapeMismatch;
        const paired_end = std.math.mul(
            usize,
            row_end,
            plan.paired_bytes_per_row,
        ) catch return TensorError.ShapeMismatch;
        const scale_end = std.math.mul(
            usize,
            row_end,
            plan.paired_scales_per_row,
        ) catch return TensorError.ShapeMismatch;
        const scale_start = std.math.mul(
            usize,
            row_start,
            plan.paired_scales_per_row,
        ) catch return TensorError.ShapeMismatch;
        if (paired_end > plan.paired_byte_count or
            scale_end > plan.paired_scale_count)
            return TensorError.ShapeMismatch;
        self.runRowsPrevalidated(
            row_start,
            row_end,
            paired_start,
            scale_start,
        );
    }

    inline fn runRowsPrevalidated(
        self: BoundPreparedPairNibbleQ8Plan,
        row_start: usize,
        row_end: usize,
        paired_start: usize,
        scale_start: usize,
    ) void {
        const plan = self.recipe;
        const row_count = row_end - row_start;
        const gate_bias: ?[*]const f32 = if (plan.gate_bias) |bias|
            bias + row_start
        else
            null;
        const up_bias: ?[*]const f32 = if (plan.up_bias) |bias|
            bias + row_start
        else
            null;
        glacier_pair_nibble_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
            self.q_input,
            self.activation_scales,
            plan.paired_weights + paired_start,
            plan.paired_scales + scale_start,
            gate_bias,
            up_bias,
            plan.gate_output + row_start,
            plan.up_output + row_start,
            plan.batch,
            row_count,
            plan.in_f,
            plan.group_size,
            plan.output_stride,
        );
    }
};

/// Static PairNibble source recipe for bounded private-tile producers. Unlike
/// `PreparedPairNibbleQ8Plan`, this contract intentionally owns no full-width
/// gate/up destination. A bound worker may publish only one validated rows4
/// range into caller-private scratch before that range is consumed.
pub const PreparedPairNibbleQ8TilePlan = struct {
    paired_weights: []const u8,
    paired_scales: []const f16,
    gate_bias: []const f32,
    up_bias: []const f32,
    out_f: usize,
    in_f: usize,
    group_size: usize,
    paired_bytes_per_row: usize,
    paired_scales_per_row: usize,

    pub fn init(
        weights: int4_weights.PairNibbleWeightData,
        gate_bias: []const f32,
        up_bias: []const f32,
    ) TensorError!PreparedPairNibbleQ8TilePlan {
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        int4_weights.validatePairNibble(weights) catch
            return TensorError.ShapeMismatch;
        if (weights.out_f == 0 or weights.out_f % 4 != 0 or
            weights.in_f == 0 or weights.in_f % 16 != 0 or
            (weights.group_size != 8 and weights.group_size != 16) or
            (gate_bias.len != 0 and gate_bias.len != weights.out_f) or
            (up_bias.len != 0 and up_bias.len != weights.out_f))
            return TensorError.ShapeMismatch;
        const paired_scales_per_row = std.math.mul(
            usize,
            weights.in_f / weights.group_size,
            2,
        ) catch return TensorError.ShapeMismatch;
        const expected_scales = std.math.mul(
            usize,
            weights.out_f,
            paired_scales_per_row,
        ) catch return TensorError.ShapeMismatch;
        const expected_bytes = std.math.mul(
            usize,
            weights.out_f,
            weights.in_f,
        ) catch return TensorError.ShapeMismatch;
        if (weights.paired_bytes.len != expected_bytes or
            weights.scales_f16_pairs.len != expected_scales)
            return TensorError.ShapeMismatch;
        return .{
            .paired_weights = weights.paired_bytes,
            .paired_scales = weights.scales_f16_pairs,
            .gate_bias = gate_bias,
            .up_bias = up_bias,
            .out_f = weights.out_f,
            .in_f = weights.in_f,
            .group_size = weights.group_size,
            .paired_bytes_per_row = weights.in_f,
            .paired_scales_per_row = paired_scales_per_row,
        };
    }

    pub fn bind(
        self: PreparedPairNibbleQ8TilePlan,
        q_input: []const i8,
        activation_scales: []const f32,
    ) TensorError!BoundPreparedPairNibbleQ8TilePlan {
        return self.bindBatch(q_input, activation_scales, 1);
    }

    /// Bind one complete M-row activation capsule. The producer Q8/scales are
    /// shared read-only by row-tile tasks after this checked construction.
    pub fn bindBatch(
        self: PreparedPairNibbleQ8TilePlan,
        q_input: []const i8,
        activation_scales: []const f32,
        batch: usize,
    ) TensorError!BoundPreparedPairNibbleQ8TilePlan {
        if (batch == 0) return TensorError.ShapeMismatch;
        const q_count = std.math.mul(usize, batch, self.in_f) catch
            return TensorError.ShapeMismatch;
        const scale_stride = q8ActivationScaleCount(
            self.in_f,
            self.group_size,
        );
        const scale_count = std.math.mul(usize, batch, scale_stride) catch
            return TensorError.ShapeMismatch;
        if (q_input.len < q_count or activation_scales.len < scale_count)
            return TensorError.ShapeMismatch;
        _ = std.math.mul(usize, scale_count, @sizeOf(f32)) catch
            return TensorError.ShapeMismatch;
        const logical_q = q_input[0..q_count];
        const logical_scales = activation_scales[0..scale_count];
        const q_bytes = std.mem.sliceAsBytes(logical_q);
        const scale_bytes = std.mem.sliceAsBytes(logical_scales);
        if (byteSlicesOverlap(q_bytes, scale_bytes))
            return TensorError.ShapeMismatch;
        const persistent_reads = [_][]const u8{
            self.paired_weights,
            std.mem.sliceAsBytes(self.paired_scales),
            std.mem.sliceAsBytes(self.gate_bias),
            std.mem.sliceAsBytes(self.up_bias),
        };
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(q_bytes, read) or
                byteSlicesOverlap(scale_bytes, read))
                return TensorError.ShapeMismatch;
        }
        return .{
            .recipe = self,
            .q_input = logical_q,
            .activation_scales = logical_scales,
            .batch = batch,
        };
    }
};

pub const BoundPreparedPairNibbleQ8TilePlan = struct {
    recipe: PreparedPairNibbleQ8TilePlan,
    q_input: []const i8,
    activation_scales: []const f32,
    batch: usize,

    /// Materialize exactly one physical rows4 range into private scratch. The
    /// output starts at scratch index zero regardless of the global row, so no
    /// full hidden-width destination is required.
    pub fn runRowsInto(
        self: BoundPreparedPairNibbleQ8TilePlan,
        row_start: usize,
        row_end: usize,
        gate_output: []f32,
        up_output: []f32,
    ) TensorError!void {
        const plan = self.recipe;
        if (comptime builtin.cpu.arch != .aarch64)
            return TensorError.DTypeUnsupported;
        if (row_start >= row_end or row_end > plan.out_f or
            row_start % 4 != 0 or row_end % 4 != 0)
            return TensorError.ShapeMismatch;
        const row_count = row_end - row_start;
        const output_count = std.math.mul(
            usize,
            self.batch,
            row_count,
        ) catch return TensorError.ShapeMismatch;
        if (gate_output.len < output_count or up_output.len < output_count)
            return TensorError.ShapeMismatch;
        _ = std.math.mul(usize, output_count, @sizeOf(f32)) catch
            return TensorError.ShapeMismatch;
        const gate_write = std.mem.sliceAsBytes(gate_output[0..output_count]);
        const up_write = std.mem.sliceAsBytes(up_output[0..output_count]);
        if (byteSlicesOverlap(gate_write, up_write))
            return TensorError.ShapeMismatch;
        const persistent_reads = [_][]const u8{
            std.mem.sliceAsBytes(self.q_input),
            std.mem.sliceAsBytes(self.activation_scales),
            plan.paired_weights,
            std.mem.sliceAsBytes(plan.paired_scales),
            std.mem.sliceAsBytes(plan.gate_bias),
            std.mem.sliceAsBytes(plan.up_bias),
        };
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(gate_write, read) or
                byteSlicesOverlap(up_write, read))
                return TensorError.ShapeMismatch;
        }

        const paired_end = std.math.mul(
            usize,
            row_end,
            plan.paired_bytes_per_row,
        ) catch return TensorError.ShapeMismatch;
        const scale_end = std.math.mul(
            usize,
            row_end,
            plan.paired_scales_per_row,
        ) catch return TensorError.ShapeMismatch;
        if (paired_end > plan.paired_weights.len or
            scale_end > plan.paired_scales.len)
            return TensorError.ShapeMismatch;
        self.runRowsIntoPrevalidated(
            row_start,
            row_end,
            gate_output[0..output_count],
            up_output[0..output_count],
        );
    }

    /// Executor-only sealed edge. The caller must have constructed this plan,
    /// proven the rows4 range and private output extents, and kept every output
    /// disjoint from persistent reads for the synchronous worker epoch.
    pub inline fn runRowsIntoPrevalidated(
        self: BoundPreparedPairNibbleQ8TilePlan,
        row_start: usize,
        row_end: usize,
        gate_output: []f32,
        up_output: []f32,
    ) void {
        const plan = self.recipe;
        const row_count = row_end - row_start;
        const output_count = std.math.mul(
            usize,
            self.batch,
            row_count,
        ) catch unreachable;
        std.debug.assert(comptime builtin.cpu.arch == .aarch64);
        std.debug.assert(self.batch != 0);
        std.debug.assert(row_start < row_end and row_end <= plan.out_f);
        std.debug.assert(row_start % 4 == 0 and row_end % 4 == 0);
        std.debug.assert(gate_output.len == output_count);
        std.debug.assert(up_output.len == output_count);
        std.debug.assert(!byteSlicesOverlap(
            std.mem.sliceAsBytes(gate_output),
            std.mem.sliceAsBytes(up_output),
        ));
        const paired_start = row_start * plan.paired_bytes_per_row;
        const scale_start = row_start * plan.paired_scales_per_row;
        std.debug.assert(
            row_end * plan.paired_bytes_per_row <= plan.paired_weights.len,
        );
        std.debug.assert(
            row_end * plan.paired_scales_per_row <= plan.paired_scales.len,
        );
        const gate_bias: ?[*]const f32 = if (plan.gate_bias.len == plan.out_f)
            plan.gate_bias.ptr + row_start
        else
            null;
        const up_bias: ?[*]const f32 = if (plan.up_bias.len == plan.out_f)
            plan.up_bias.ptr + row_start
        else
            null;
        glacier_pair_nibble_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
            self.q_input.ptr,
            self.activation_scales.ptr,
            plan.paired_weights.ptr + paired_start,
            plan.paired_scales.ptr + scale_start,
            gate_bias,
            up_bias,
            gate_output.ptr,
            up_output.ptr,
            self.batch,
            row_count,
            plan.in_f,
            plan.group_size,
            row_count,
        );
    }
};

/// Execute one exact dual-output PairNibble projection from a prequantized Q8
/// activation. The paired stream is traversed once and emits gate/up outputs;
/// no branch is unpacked into a resident single-projection representation.
pub fn linearPairNibbleQ8Prepared(
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    gate_out: Tensor,
    up_out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const gate_output = try checkedBatchOutput(gate_out, out_f);
    const up_output = try checkedBatchOutput(up_out, out_f);
    if (gate_out.shape[0] != 1 or up_out.shape[0] != 1)
        return TensorError.ShapeMismatch;
    if (weights.out_f != out_f or weights.in_f != in_f)
        return TensorError.ShapeMismatch;
    const recipe = try PreparedPairNibbleQ8Plan.init(
        weights,
        gate_bias,
        up_bias,
        gate_output,
        up_output,
        1,
        out_f,
    );
    const bound = try recipe.bind(q_input, activation_scales);
    return bound.runRows(0, out_f);
}

/// Execute an exact M1..M4 dual-output PairNibble projection. The one-read M4
/// schedule has passed its explicit-artifact micro gate, but this low-level
/// entry point is not a production selector or a default whole-MLP path.
/// Smaller batches exercise the same checked tail contract. Both outputs use
/// the caller's contiguous [batch, out_f] layout.
pub fn linearPairNibbleQ8PreparedBatch(
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    gate_out: Tensor,
    up_out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const gate_output = try checkedBatchOutput(gate_out, out_f);
    const up_output = try checkedBatchOutput(up_out, out_f);
    if (gate_out.shape[0] != up_out.shape[0])
        return TensorError.ShapeMismatch;
    return linearPairNibbleQ8PreparedBatchStrided(
        q_input,
        activation_scales,
        weights,
        gate_bias,
        up_bias,
        gate_output,
        up_output,
        gate_out.shape[0],
        out_f,
        in_f,
        out_f,
    );
}

/// Checked arbitrary-batch PairNibble edge with an explicit destination
/// stride. This is also the primitive used by output-row shard schedulers.
pub fn linearPairNibbleQ8PreparedBatchStrided(
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    gate_output: []f32,
    up_output: []f32,
    batch: usize,
    out_f: usize,
    in_f: usize,
    output_stride: usize,
) TensorError!void {
    if (weights.out_f != out_f or weights.in_f != in_f)
        return TensorError.ShapeMismatch;
    const recipe = try PreparedPairNibbleQ8Plan.init(
        weights,
        gate_bias,
        up_bias,
        gate_output,
        up_output,
        batch,
        output_stride,
    );
    const bound = try recipe.bind(q_input, activation_scales);
    return bound.runRows(0, out_f);
}

/// Parallel arbitrary-batch PairNibble projection. Every task owns a disjoint
/// range of complete four-row physical tiles; the activation batch is shared
/// read-only and the full output stride is retained by every shard.
pub fn linearPairNibbleQ8PreparedBatchParallel(
    pool: *std.Thread.Pool,
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    gate_out: Tensor,
    up_out: Tensor,
    out_f: usize,
    in_f: usize,
    max_tasks: usize,
) TensorError!void {
    const gate_output = try checkedBatchOutput(gate_out, out_f);
    const up_output = try checkedBatchOutput(up_out, out_f);
    if (gate_out.shape[0] != up_out.shape[0] or
        weights.out_f != out_f or weights.in_f != in_f)
        return TensorError.ShapeMismatch;
    const recipe = try PreparedPairNibbleQ8Plan.init(
        weights,
        gate_bias,
        up_bias,
        gate_output,
        up_output,
        gate_out.shape[0],
        out_f,
    );
    const bound = try recipe.bind(q_input, activation_scales);
    return runPairNibbleQ8PreparedBatchParallel(
        pool,
        bound,
        out_f,
        max_tasks,
    );
}

fn runPairNibbleQ8PreparedBatchParallel(
    pool: *std.Thread.Pool,
    bound: BoundPreparedPairNibbleQ8Plan,
    out_f: usize,
    max_tasks: usize,
) TensorError!void {
    const row_tiles = out_f / 4;
    const max_job_count: usize = 16;
    const task_count = @min(@min(max_tasks, row_tiles), max_job_count);
    if (task_count < 2) return bound.runRows(0, out_f);

    const Job = struct {
        plan: BoundPreparedPairNibbleQ8Plan,
        row_start: usize,
        row_end: usize,
        err: ?TensorError = null,

        fn run(job: *@This()) void {
            job.plan.runRows(job.row_start, job.row_end) catch |err| {
                job.err = err;
            };
        }
    };

    var jobs: [max_job_count]Job = undefined;
    for (jobs[0..task_count], 0..) |*job, task_index| {
        const tile_start = row_tiles * task_index / task_count;
        const tile_end = row_tiles * (task_index + 1) / task_count;
        job.* = .{
            .plan = bound,
            .row_start = tile_start * 4,
            .row_end = tile_end * 4,
        };
    }
    var wait_group: std.Thread.WaitGroup = .{};
    for (jobs[0..task_count]) |*job|
        pool.spawnWg(&wait_group, Job.run, .{job});
    pool.waitAndWork(&wait_group);
    for (jobs[0..task_count]) |job| if (job.err) |err| return err;
}

/// Quantize one float activation batch once, then emit both PairNibble
/// branches in parallel. Complete preflight precedes both scratch and output
/// writes, including input/scratch/output and persistent-storage aliases.
pub fn linearPairNibbleWeightBatchQ8Parallel(
    pool: *std.Thread.Pool,
    x: Tensor,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    gate_out: Tensor,
    up_out: Tensor,
    out_f: usize,
    in_f: usize,
    q_scratch: []i8,
    scale_scratch: []f32,
    max_tasks: usize,
) TensorError!void {
    const input = try checkedBatchOutput(x, in_f);
    const gate_output = try checkedBatchOutput(gate_out, out_f);
    const up_output = try checkedBatchOutput(up_out, out_f);
    const batch = x.shape[0];
    if (gate_out.shape[0] != batch or up_out.shape[0] != batch or
        weights.out_f != out_f or weights.in_f != in_f)
        return TensorError.ShapeMismatch;
    const recipe = try PreparedPairNibbleQ8Plan.init(
        weights,
        gate_bias,
        up_bias,
        gate_output,
        up_output,
        batch,
        out_f,
    );
    // Bind before quantization: this validates the exact scratch extents and
    // rejects scratch aliases with every persistent read or output.
    const bound = try recipe.bind(q_scratch, scale_scratch);
    const input_bytes = std.mem.sliceAsBytes(input);
    const q_count = std.math.mul(usize, batch, in_f) catch
        return TensorError.ShapeMismatch;
    const scale_count = std.math.mul(
        usize,
        batch,
        q8ActivationScaleCount(in_f, weights.group_size),
    ) catch return TensorError.ShapeMismatch;
    const q_write = std.mem.sliceAsBytes(q_scratch[0..q_count]);
    const scale_write = std.mem.sliceAsBytes(scale_scratch[0..scale_count]);
    if (byteSlicesOverlap(input_bytes, q_write) or
        byteSlicesOverlap(input_bytes, scale_write) or
        byteSlicesOverlap(input_bytes, std.mem.sliceAsBytes(gate_output)) or
        byteSlicesOverlap(input_bytes, std.mem.sliceAsBytes(up_output)))
        return TensorError.ShapeMismatch;
    const writes = [_][]const u8{
        q_write,
        scale_write,
        std.mem.sliceAsBytes(gate_output),
        std.mem.sliceAsBytes(up_output),
    };
    const shape_metadata = [_][]const u8{
        std.mem.sliceAsBytes(x.shape),
        std.mem.sliceAsBytes(gate_out.shape),
        std.mem.sliceAsBytes(up_out.shape),
    };
    for (writes) |write| {
        for (shape_metadata) |metadata| {
            if (byteSlicesOverlap(write, metadata))
                return TensorError.ShapeMismatch;
        }
    }

    try quantizeQ8ActivationBatch(
        input,
        batch,
        in_f,
        weights.group_size,
        q_scratch[0..q_count],
        scale_scratch[0..scale_count],
    );
    return runPairNibbleQ8PreparedBatchParallel(
        pool,
        bound,
        out_f,
        max_tasks,
    );
}

const PairNibbleSiluQ8CompactBatchContext = struct {
    plan: BoundPreparedPairNibbleQ8TilePlan,
    ledger: PairNibbleSiluQ8CompactBatchLedger,
    q_output: []i8,
    output_scales: []f32,
    gate_tile_scratch: []f32,
    up_tile_scratch: []f32,

    fn runTask(context: *@This(), task_index: usize) void {
        const ledger = context.ledger;
        std.debug.assert(task_index < ledger.task_count);
        const slot_start = task_index * ledger.tile_slot_stride;
        const slot_end = slot_start + ledger.tile_slot_stride;
        const gate_slot = context.gate_tile_scratch[slot_start..slot_end];
        const up_slot = context.up_tile_scratch[slot_start..slot_end];

        // Static contiguous stripes give every task exclusive Q8, scale and
        // tile writes. Every non-final boundary is a complete 32-row down
        // activation-group boundary for both supported down group sizes.
        const shards_per_task = ledger.shard_count / ledger.task_count;
        const remainder = ledger.shard_count % ledger.task_count;
        const shard_start = task_index * shards_per_task +
            @min(task_index, remainder);
        const shard_end = shard_start + shards_per_task +
            @intFromBool(task_index < remainder);
        for (shard_start..shard_end) |shard_index| {
            const row_start = shard_index * ledger.tile_rows;
            const row_end = if (shard_index + 1 == ledger.shard_count)
                ledger.out_f
            else
                row_start + ledger.tile_rows;
            const row_count = row_end - row_start;
            const tile_output_count = std.math.mul(
                usize,
                ledger.batch,
                row_count,
            ) catch unreachable;
            const gate_tile = gate_slot[0..tile_output_count];
            const up_tile = up_slot[0..tile_output_count];
            context.plan.runRowsIntoPrevalidated(
                row_start,
                row_end,
                gate_tile,
                up_tile,
            );

            const tile_scale_count = row_count /
                ledger.down_activation_group_size +
                @intFromBool(
                    row_count % ledger.down_activation_group_size != 0,
                );
            for (0..ledger.batch) |batch_row| {
                const tile_row_start = batch_row * row_count;
                const q_start = batch_row * ledger.out_f + row_start;
                const scale_start = batch_row * ledger.output_scale_stride +
                    row_start / ledger.down_activation_group_size;
                kernels.siluMulQuantizeQ8SlicesPrevalidated(
                    gate_tile[tile_row_start..][0..row_count],
                    up_tile[tile_row_start..][0..row_count],
                    ledger.down_activation_group_size,
                    context.q_output[q_start..][0..row_count],
                    context.output_scales[scale_start..][0..tile_scale_count],
                );
            }
        }
    }
};

/// Quantize one bounded float activation capsule once, stream PairNibble
/// gate/up row tiles through task-private storage, and publish only the exact
/// Q8 SwiGLU activation consumed by a prepared down projection.
///
/// This edge has no materialized/full-hidden fallback. All geometry, extents,
/// alignment and aliases are proven before producer scratch or caller output
/// is written. Gate/up tile storage is slot-major `[task][batch][tile_rows]`;
/// callers should derive every extent with
/// `derivePairNibbleSiluQ8CompactBatchLedger`.
pub fn linearPairNibbleSiluQ8CompactBatchParallel(
    pool: *std.Thread.Pool,
    input: []const f32,
    batch: usize,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    producer_q_scratch: []i8,
    producer_scale_scratch: []f32,
    q_output: []i8,
    output_scales: []f32,
    gate_tile_scratch: []f32,
    up_tile_scratch: []f32,
    down_group_size: u32,
    tile_rows: usize,
    task_slots: usize,
    max_tasks: usize,
) TensorError!void {
    if (comptime builtin.cpu.arch != .aarch64)
        return TensorError.DTypeUnsupported;
    const ledger = try derivePairNibbleSiluQ8CompactBatchLedger(
        batch,
        weights.in_f,
        weights.out_f,
        weights.group_size,
        down_group_size,
        tile_rows,
        task_slots,
        max_tasks,
    );
    if (input.len != ledger.input_count or
        producer_q_scratch.len < ledger.producer_q_count or
        producer_scale_scratch.len < ledger.producer_scale_count or
        q_output.len < ledger.q_output_count or
        output_scales.len < ledger.output_scale_count or
        gate_tile_scratch.len < ledger.tile_scratch_count_per_branch or
        up_tile_scratch.len < ledger.tile_scratch_count_per_branch)
        return TensorError.ShapeMismatch;

    const logical_input = input[0..ledger.input_count];
    const logical_producer_q = producer_q_scratch[0..ledger.producer_q_count];
    const logical_producer_scales =
        producer_scale_scratch[0..ledger.producer_scale_count];
    const logical_q_output = q_output[0..ledger.q_output_count];
    const logical_output_scales = output_scales[0..ledger.output_scale_count];
    const logical_gate_tiles =
        gate_tile_scratch[0..ledger.tile_scratch_count_per_branch];
    const logical_up_tiles =
        up_tile_scratch[0..ledger.tile_scratch_count_per_branch];

    // Typed slices normally carry natural alignment, but this public edge may
    // receive foreign/mapped storage. Enforce the actual C and cache-isolation
    // contract instead of relying on provenance outside this module.
    if (@intFromPtr(logical_input.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(weights.scales_f16_pairs.ptr) % @alignOf(f16) != 0 or
        (gate_bias.len != 0 and
            @intFromPtr(gate_bias.ptr) % @alignOf(f32) != 0) or
        (up_bias.len != 0 and
            @intFromPtr(up_bias.ptr) % @alignOf(f32) != 0) or
        @intFromPtr(logical_producer_scales.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(logical_output_scales.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(logical_gate_tiles.ptr) %
            pair_nibble_compact_task_scratch_alignment != 0 or
        @intFromPtr(logical_up_tiles.ptr) %
            pair_nibble_compact_task_scratch_alignment != 0)
        return TensorError.ShapeMismatch;

    const recipe = try PreparedPairNibbleQ8TilePlan.init(
        weights,
        gate_bias,
        up_bias,
    );
    const bound = try recipe.bindBatch(
        logical_producer_q,
        logical_producer_scales,
        batch,
    );

    const persistent_reads = [_][]const u8{
        std.mem.sliceAsBytes(logical_input),
        recipe.paired_weights,
        std.mem.sliceAsBytes(recipe.paired_scales),
        std.mem.sliceAsBytes(recipe.gate_bias),
        std.mem.sliceAsBytes(recipe.up_bias),
    };
    const writes = [_][]const u8{
        std.mem.sliceAsBytes(logical_producer_q),
        std.mem.sliceAsBytes(logical_producer_scales),
        std.mem.sliceAsBytes(logical_q_output),
        std.mem.sliceAsBytes(logical_output_scales),
        std.mem.sliceAsBytes(logical_gate_tiles),
        std.mem.sliceAsBytes(logical_up_tiles),
    };
    for (writes, 0..) |write, write_index| {
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(write, read))
                return TensorError.ShapeMismatch;
        }
        for (writes[write_index + 1 ..]) |other_write| {
            if (byteSlicesOverlap(write, other_write))
                return TensorError.ShapeMismatch;
        }
    }

    // This is deliberately the first write after complete preflight.
    try quantizeQ8ActivationBatch(
        logical_input,
        batch,
        ledger.in_f,
        ledger.producer_group_size,
        logical_producer_q,
        logical_producer_scales,
    );

    var context: PairNibbleSiluQ8CompactBatchContext = .{
        .plan = bound,
        .ledger = ledger,
        .q_output = logical_q_output,
        .output_scales = logical_output_scales,
        .gate_tile_scratch = logical_gate_tiles,
        .up_tile_scratch = logical_up_tiles,
    };
    var wait_group: std.Thread.WaitGroup = .{};
    for (0..ledger.task_count) |task_index|
        pool.spawnWg(
            &wait_group,
            PairNibbleSiluQ8CompactBatchContext.runTask,
            .{ &context, task_index },
        );
    pool.waitAndWork(&wait_group);
}

/// Process-local contract for the fixed-width compact Pair producer and its
/// prepared down consumer. Unlike a generic graph ABI, this edge preserves the
/// exact existing M4 producer and rows4/K16 down kernels and changes only
/// worker ownership across their publication boundary.
pub const pair_nibble_silu_q8_down_wave_abi: u64 =
    0x4750_4457_0000_0001;

pub const PairNibblePreparedBatchDownProjection = struct {
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
};

pub const PairDownBatchEpochReceipt = struct {
    abi_version: u64 = pair_nibble_silu_q8_down_wave_abi,
    participants: usize,
    producer_shards: usize,
    down_row_shards: usize,
    worker_epochs: usize = 1,
    split_worker_epochs: usize,
    worker_joins_elided: usize,
    background_enqueues: usize,
};

const PairDownBatchBarrier = struct {
    participants: usize,
    arrived: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn wait(self: *@This()) void {
        const arrived = self.arrived.fetchAdd(1, .acq_rel);
        std.debug.assert(arrived < self.participants);
        if (arrived + 1 == self.participants) return;
        var spins: usize = 0;
        while (self.arrived.load(.acquire) != self.participants) : (spins +%= 1) {
            if (spins < 1024) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.yield() catch {};
            }
        }
    }
};

const PairDownWaveStartGate = struct {
    const pending: u32 = 0;
    const armed: u32 = 1;
    const aborted: u32 = 2;

    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(pending),

    fn publish(self: *@This(), state: u32, participants: usize) void {
        std.debug.assert(state == armed or state == aborted);
        self.state.store(state, .release);
        std.Thread.Futex.wake(&self.state, @intCast(participants));
    }

    fn waitUntilArmed(self: *@This()) bool {
        var spins: usize = 0;
        while (true) : (spins +%= 1) {
            const state = self.state.load(.acquire);
            if (state != pending) return state == armed;
            if (spins < 512) {
                std.atomic.spinLoopHint();
            } else {
                std.Thread.Futex.wait(&self.state, pending);
            }
        }
    }
};

const PairDownBatchWaveContext = struct {
    producer: PairNibbleSiluQ8CompactBatchContext,
    producer_task_count: usize,
    down_jobs: []PreparedBatchProjectionJob,
    start_gate: PairDownWaveStartGate = .{},
    barrier: PairDownBatchBarrier,

    fn runArmed(context: *@This(), task_index: usize) void {
        if (task_index < context.producer_task_count)
            context.producer.runTask(task_index);
        context.barrier.wait();
        if (task_index < context.down_jobs.len)
            context.down_jobs[task_index].run();
    }

    fn runJoined(
        context: *@This(),
        task_index: usize,
        wait_group: *std.Thread.WaitGroup,
    ) void {
        defer wait_group.finish();
        if (!context.start_gate.waitUntilArmed()) return;
        context.runArmed(task_index);
    }
};

/// Keep the compact B4 PairNibble producer and prepared down projection in one
/// synchronous worker wave. Every participant publishes its disjoint Q8 and
/// scale shards through one acquire/release barrier, then reuses the same
/// closure for a disjoint down-row shard. This removes one task cohort and one
/// caller join when the independent down projection would use workers.
///
/// The pool must be exclusively leased for this call, and the caller must not
/// itself be executing as a worker of that pool. The function derives a
/// participant count no larger than `pool.threads.len + 1`; the external caller
/// helps drain the pool, so every barrier participant can run concurrently.
/// Complete producer, consumer, metadata and cross-edge alias validation occurs
/// before activation quantization or any caller-owned output write.
pub fn linearPairNibbleSiluQ8CompactBatchDownWave(
    pool: *std.Thread.Pool,
    input: []const f32,
    batch: usize,
    weights: int4_weights.PairNibbleWeightData,
    gate_bias: []const f32,
    up_bias: []const f32,
    producer_q_scratch: []i8,
    producer_scale_scratch: []f32,
    q_output: []i8,
    output_scales: []f32,
    gate_tile_scratch: []f32,
    up_tile_scratch: []f32,
    down: PairNibblePreparedBatchDownProjection,
    tile_rows: usize,
    task_slots: usize,
    max_tasks: usize,
) TensorError!PairDownBatchEpochReceipt {
    if (comptime builtin.cpu.arch != .aarch64)
        return TensorError.DTypeUnsupported;
    if (down.in_f != weights.out_f or
        down.weights.group_size != 8 and down.weights.group_size != 16)
        return TensorError.ShapeMismatch;
    const ledger = try derivePairNibbleSiluQ8CompactBatchLedger(
        batch,
        weights.in_f,
        weights.out_f,
        weights.group_size,
        down.weights.group_size,
        tile_rows,
        task_slots,
        max_tasks,
    );
    if (input.len != ledger.input_count or
        producer_q_scratch.len < ledger.producer_q_count or
        producer_scale_scratch.len < ledger.producer_scale_count or
        q_output.len < ledger.q_output_count or
        output_scales.len < ledger.output_scale_count or
        gate_tile_scratch.len < ledger.tile_scratch_count_per_branch or
        up_tile_scratch.len < ledger.tile_scratch_count_per_branch)
        return TensorError.ShapeMismatch;

    const logical_input = input[0..ledger.input_count];
    const logical_producer_q = producer_q_scratch[0..ledger.producer_q_count];
    const logical_producer_scales =
        producer_scale_scratch[0..ledger.producer_scale_count];
    const logical_q_output = q_output[0..ledger.q_output_count];
    const logical_output_scales = output_scales[0..ledger.output_scale_count];
    const logical_gate_tiles =
        gate_tile_scratch[0..ledger.tile_scratch_count_per_branch];
    const logical_up_tiles =
        up_tile_scratch[0..ledger.tile_scratch_count_per_branch];

    if (@intFromPtr(logical_input.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(weights.scales_f16_pairs.ptr) % @alignOf(f16) != 0 or
        (gate_bias.len != 0 and
            @intFromPtr(gate_bias.ptr) % @alignOf(f32) != 0) or
        (up_bias.len != 0 and
            @intFromPtr(up_bias.ptr) % @alignOf(f32) != 0) or
        @intFromPtr(logical_producer_scales.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(logical_output_scales.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(logical_gate_tiles.ptr) %
            pair_nibble_compact_task_scratch_alignment != 0 or
        @intFromPtr(logical_up_tiles.ptr) %
            pair_nibble_compact_task_scratch_alignment != 0)
        return TensorError.ShapeMismatch;

    const recipe = try PreparedPairNibbleQ8TilePlan.init(
        weights,
        gate_bias,
        up_bias,
    );
    const bound = try recipe.bindBatch(
        logical_producer_q,
        logical_producer_scales,
        batch,
    );
    if (down.out.shape.len != 2 or down.out.shape[0] != batch)
        return TensorError.ShapeMismatch;
    const down_output = try checkedBatchOutput(down.out, down.out_f);
    try validatePreparedBatch(
        logical_q_output,
        logical_output_scales,
        down.weights,
        down.bias,
        down_output.len,
        batch,
        down.out_f,
        down.in_f,
        down.out_f,
    );

    const down_task_count = preparedBatchProjectionTaskCount(
        down.out_f,
        max_tasks,
    );
    if (down_task_count == 0) return TensorError.ShapeMismatch;
    const participant_count = @max(ledger.task_count, down_task_count);
    const pool_participants = std.math.add(
        usize,
        pool.threads.len,
        1,
    ) catch return TensorError.ShapeMismatch;
    if (participant_count > pool_participants)
        return TensorError.ShapeMismatch;

    const persistent_reads = [_][]const u8{
        std.mem.sliceAsBytes(logical_input),
        recipe.paired_weights,
        std.mem.sliceAsBytes(recipe.paired_scales),
        std.mem.sliceAsBytes(recipe.gate_bias),
        std.mem.sliceAsBytes(recipe.up_bias),
        down.weights.packed_bytes,
        std.mem.sliceAsBytes(down.weights.scales),
        std.mem.sliceAsBytes(down.weights.scales_f16),
        std.mem.sliceAsBytes(down.weights.scales_f16_rows4),
        std.mem.sliceAsBytes(down.bias),
        std.mem.sliceAsBytes(down.out.shape),
    };
    const writes = [_][]const u8{
        std.mem.sliceAsBytes(logical_producer_q),
        std.mem.sliceAsBytes(logical_producer_scales),
        std.mem.sliceAsBytes(logical_q_output),
        std.mem.sliceAsBytes(logical_output_scales),
        std.mem.sliceAsBytes(logical_gate_tiles),
        std.mem.sliceAsBytes(logical_up_tiles),
        std.mem.sliceAsBytes(down_output),
    };
    for (writes, 0..) |write, write_index| {
        for (persistent_reads) |read| {
            if (byteSlicesOverlap(write, read))
                return TensorError.ShapeMismatch;
        }
        for (writes[write_index + 1 ..]) |other_write| {
            if (byteSlicesOverlap(write, other_write))
                return TensorError.ShapeMismatch;
        }
    }

    const producer_context: PairNibbleSiluQ8CompactBatchContext = .{
        .plan = bound,
        .ledger = ledger,
        .q_output = logical_q_output,
        .output_scales = logical_output_scales,
        .gate_tile_scratch = logical_gate_tiles,
        .up_tile_scratch = logical_up_tiles,
    };
    var down_jobs: [prepared_batch_projection_max_tasks]PreparedBatchProjectionJob =
        undefined;
    initPreparedBatchProjectionJobs(
        down_jobs[0..down_task_count],
        logical_q_output,
        logical_output_scales,
        down.weights,
        down.bias,
        down_output,
        batch,
        down.out_f,
        down.in_f,
    );
    var context: PairDownBatchWaveContext = .{
        .producer = producer_context,
        .producer_task_count = ledger.task_count,
        .down_jobs = down_jobs[0..down_task_count],
        .barrier = .{ .participants = participant_count },
    };
    // `spawnWg` may run a task synchronously if its allocation fails. A task
    // that then entered the phase barrier could strand the submitter before
    // its peers existed. Instead, enqueue only background participants through
    // the fallible API while they wait behind a no-write start gate. The caller
    // is the final participant. Any enqueue failure aborts and drains admitted
    // jobs before quantization or caller output mutation.
    const background_jobs = participant_count - 1;
    var wait_group: std.Thread.WaitGroup = .{};
    if (background_jobs != 0) wait_group.startMany(background_jobs);
    for (0..background_jobs) |task_index| {
        pool.spawn(
            PairDownBatchWaveContext.runJoined,
            .{ &context, task_index, &wait_group },
        ) catch {
            for (task_index..background_jobs) |_| wait_group.finish();
            context.start_gate.publish(
                PairDownWaveStartGate.aborted,
                background_jobs,
            );
            pool.waitAndWork(&wait_group);
            return TensorError.OutOfMemory;
        };
    }

    // First write after complete graph validation and successful admission of
    // every background participant. This prevalidated quantizer cannot fail
    // for the geometry above; keep the typed error path draining-safe anyway.
    quantizeQ8ActivationBatch(
        logical_input,
        batch,
        ledger.in_f,
        ledger.producer_group_size,
        logical_producer_q,
        logical_producer_scales,
    ) catch |err| {
        context.start_gate.publish(
            PairDownWaveStartGate.aborted,
            background_jobs,
        );
        pool.waitAndWork(&wait_group);
        return err;
    };
    context.start_gate.publish(PairDownWaveStartGate.armed, background_jobs);
    context.runArmed(background_jobs);
    pool.waitAndWork(&wait_group);
    for (down_jobs[0..down_task_count]) |job|
        if (job.err) |err| return err;
    const split_worker_epochs: usize = 1 +
        @as(usize, @intFromBool(down_task_count >= 2));
    return .{
        .participants = participant_count,
        .producer_shards = ledger.shard_count,
        .down_row_shards = down_task_count,
        .split_worker_epochs = split_worker_epochs,
        .worker_joins_elided = split_worker_epochs - 1,
        .background_enqueues = background_jobs,
    };
}

fn linearInt4WeightQ8PreparedBatchStrided(
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    output: []f32,
    batch: usize,
    out_f: usize,
    in_f: usize,
    output_stride: usize,
) TensorError!void {
    try validatePreparedBatch(
        q_input,
        activation_scales,
        weights,
        bias,
        output.len,
        batch,
        out_f,
        in_f,
        output_stride,
    );
    if (comptime builtin.cpu.arch != .aarch64) return TensorError.DTypeUnsupported;
    const bias_ptr: ?[*]const f32 = if (bias.len == out_f) bias.ptr else null;
    glacier_int4_gemm_neon_q8_prequant_f16scale_rows4_k16_m4(
        q_input.ptr,
        activation_scales.ptr,
        weights.packed_bytes.ptr,
        weights.scales_f16_rows4.ptr,
        bias_ptr,
        output.ptr,
        batch,
        out_f,
        in_f,
        weights.group_size,
        output_stride,
    );
}

/// Public contiguous-output wrapper for the four-token packed GEMM kernel.
pub fn linearInt4WeightQ8PreparedBatch(
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const output = try checkedBatchOutput(out, out_f);
    return linearInt4WeightQ8PreparedBatchStrided(
        q_input,
        activation_scales,
        weights,
        bias,
        output,
        out.shape[0],
        out_f,
        in_f,
        out_f,
    );
}

const PreparedBatchProjectionJob = struct {
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    output: []f32,
    batch: usize,
    full_out_f: usize,
    out_start: usize,
    out_end: usize,
    in_f: usize,
    err: ?TensorError = null,

    fn run(job: *@This()) void {
        const start_element = job.out_start * job.in_f;
        const end_element = job.out_end * job.in_f;
        const group_size: usize = job.weights.group_size;
        const packed_start = start_element / 2;
        const packed_end = ceilDiv(end_element, 2);
        const scale_start = start_element / group_size;
        const scale_end = ceilDiv(end_element, group_size);
        const row_count = job.out_end - job.out_start;
        const sub_weights: int4_weights.Int4WeightData = .{
            .packed_bytes = job.weights.packed_bytes[packed_start..packed_end],
            .scales = if (job.weights.scales.len == 0)
                &.{}
            else
                job.weights.scales[scale_start..scale_end],
            .scales_f16 = if (job.weights.scales_f16.len == 0)
                &.{}
            else
                job.weights.scales_f16[scale_start..scale_end],
            .scales_f16_rows4 = job.weights.scales_f16_rows4[scale_start..scale_end],
            .expanded_i8 = &.{},
            .group_size = job.weights.group_size,
            .num_elements = end_element - start_element,
            .packed_layout = .rows4_k16,
        };
        const sub_bias = if (job.bias.len == 0)
            &.{}
        else
            job.bias[job.out_start..job.out_end];
        linearInt4WeightQ8PreparedBatchStrided(
            job.q_input,
            job.activation_scales,
            sub_weights,
            sub_bias,
            job.output[job.out_start..],
            job.batch,
            row_count,
            job.in_f,
            job.full_out_f,
        ) catch |err| {
            job.err = err;
        };
    }
};

fn preparedBatchProjectionTaskCount(out_f: usize, max_tasks: usize) usize {
    if (out_f == 0 or out_f % 4 != 0 or max_tasks == 0) return 0;
    return @min(
        @min(max_tasks, out_f / 4),
        prepared_batch_projection_max_tasks,
    );
}

fn initPreparedBatchProjectionJobs(
    jobs: []PreparedBatchProjectionJob,
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    output: []f32,
    batch: usize,
    out_f: usize,
    in_f: usize,
) void {
    const row_tiles = out_f / 4;
    for (jobs, 0..) |*job, task_idx| {
        const tile_start = row_tiles * task_idx / jobs.len;
        const tile_end = row_tiles * (task_idx + 1) / jobs.len;
        job.* = .{
            .q_input = q_input,
            .activation_scales = activation_scales,
            .weights = weights,
            .bias = bias,
            .output = output,
            .batch = batch,
            .full_out_f = out_f,
            .out_start = tile_start * 4,
            .out_end = tile_end * 4,
            .in_f = in_f,
        };
    }
}

/// Parallel output-row sharding for packed prefill. Each job owns aligned
/// groups of four output rows and writes them with the full output stride;
/// activations and weights are immutable and shared by all jobs.
pub fn linearInt4WeightQ8PreparedBatchParallel(
    pool: *std.Thread.Pool,
    q_input: []const i8,
    activation_scales: []const f32,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    max_tasks: usize,
) TensorError!void {
    const output = try checkedBatchOutput(out, out_f);
    const batch = out.shape[0];
    try validatePreparedBatch(
        q_input,
        activation_scales,
        weights,
        bias,
        output.len,
        batch,
        out_f,
        in_f,
        out_f,
    );
    if (max_tasks < 2) {
        return linearInt4WeightQ8PreparedBatchStrided(
            q_input,
            activation_scales,
            weights,
            bias,
            output,
            batch,
            out_f,
            in_f,
            out_f,
        );
    }
    const task_count = preparedBatchProjectionTaskCount(out_f, max_tasks);
    if (task_count < 2)
        return linearInt4WeightQ8PreparedBatchStrided(
            q_input,
            activation_scales,
            weights,
            bias,
            output,
            batch,
            out_f,
            in_f,
            out_f,
        );

    var jobs: [prepared_batch_projection_max_tasks]PreparedBatchProjectionJob =
        undefined;
    initPreparedBatchProjectionJobs(
        jobs[0..task_count],
        q_input,
        activation_scales,
        weights,
        bias,
        output,
        batch,
        out_f,
        in_f,
    );
    var wait_group: std.Thread.WaitGroup = .{};
    for (jobs[0..task_count]) |*job|
        pool.spawnWg(&wait_group, PreparedBatchProjectionJob.run, .{job});
    pool.waitAndWork(&wait_group);
    for (jobs[0..task_count]) |job| if (job.err) |err| return err;
}

/// One member of a prepared-projection wave. Every member consumes the same
/// immutable Q8 activation rows and activation-scale ABI, while owning a
/// disjoint output tensor. Keeping the descriptor public lets higher-level
/// graphs bundle Q/K/V without exposing the worker schedule.
pub const PreparedBatchProjection = struct {
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
};

pub const prepared_batch_projection_wave_abi: u64 =
    0x4750_5741_0000_0001;
pub const prepared_batch_projection_wave_max_members: usize = 8;
pub const prepared_batch_projection_max_tasks: usize = 16;

/// Whether one prepared projection uses a worker dispatch/join epoch under
/// the rows4 sharding cap shared by the independent and wave entry points.
pub fn preparedBatchProjectionUsesWorkerEpoch(
    out_f: usize,
    max_tasks: usize,
) bool {
    if (out_f == 0 or out_f % 4 != 0) return false;
    return preparedBatchProjectionTaskCount(out_f, max_tasks) >= 2;
}

test "prepared projection worker epoch classification matches rows4 cap" {
    try testing.expect(!preparedBatchProjectionUsesWorkerEpoch(0, 4));
    try testing.expect(!preparedBatchProjectionUsesWorkerEpoch(4, 4));
    try testing.expect(preparedBatchProjectionUsesWorkerEpoch(8, 4));
    try testing.expect(preparedBatchProjectionUsesWorkerEpoch(68, 4));
    try testing.expect(!preparedBatchProjectionUsesWorkerEpoch(68, 1));
    try testing.expect(!preparedBatchProjectionUsesWorkerEpoch(6, 4));
}

/// Execute several projections that share one prepared activation in one
/// worker epoch. Each worker owns a rows4-aligned output shard for every
/// member, so each projection retains the exact native reduction order of
/// `linearInt4WeightQ8PreparedBatchParallel`; only dispatch/join ownership is
/// changed. All members and cross-member aliases are validated before the
/// first output byte is written.
pub fn linearInt4WeightQ8PreparedBatchProjectionWave(
    pool: *std.Thread.Pool,
    q_input: []const i8,
    activation_scales: []const f32,
    projections: []const PreparedBatchProjection,
    in_f: usize,
    max_tasks: usize,
) TensorError!void {
    if (projections.len == 0 or
        projections.len > prepared_batch_projection_wave_max_members)
        return TensorError.ShapeMismatch;

    const BoundProjection = struct {
        weights: int4_weights.Int4WeightData,
        bias: []const f32,
        output: []f32,
        out_f: usize,
        batch: usize,
    };
    var bound_storage: [prepared_batch_projection_wave_max_members]BoundProjection =
        undefined;
    var batch: usize = 0;
    var group_size: u32 = 0;
    var max_row_tiles: usize = 0;

    // Complete shape/storage validation and bind every output before checking
    // cross-member aliases. No kernel or quantizer is reachable from here.
    for (projections, 0..) |projection, index| {
        const output = try checkedBatchOutput(projection.out, projection.out_f);
        const projection_batch = projection.out.shape[0];
        try validatePreparedBatch(
            q_input,
            activation_scales,
            projection.weights,
            projection.bias,
            output.len,
            projection_batch,
            projection.out_f,
            in_f,
            projection.out_f,
        );
        if (index == 0) {
            batch = projection_batch;
            group_size = projection.weights.group_size;
        } else if (projection_batch != batch or
            projection.weights.group_size != group_size)
        {
            return TensorError.ShapeMismatch;
        }
        max_row_tiles = @max(max_row_tiles, projection.out_f / 4);
        bound_storage[index] = .{
            .weights = projection.weights,
            .bias = projection.bias,
            .output = output,
            .out_f = projection.out_f,
            .batch = projection_batch,
        };
    }
    const bound = bound_storage[0..projections.len];

    const q_read = std.mem.sliceAsBytes(q_input);
    const scale_read = std.mem.sliceAsBytes(activation_scales);
    const descriptors = std.mem.sliceAsBytes(projections);
    for (bound, 0..) |projection, index| {
        const write = std.mem.sliceAsBytes(projection.output);
        if (byteSlicesOverlap(write, q_read) or
            byteSlicesOverlap(write, scale_read) or
            byteSlicesOverlap(write, descriptors))
            return TensorError.ShapeMismatch;

        // A member's output must not corrupt any other member's immutable
        // payload or Tensor metadata before that member executes. Checking
        // all members, rather than only the matching descriptor, also closes
        // cross-member read/write aliases that output-output checks miss.
        for (bound, 0..) |other, other_index| {
            if (byteSlicesOverlap(
                write,
                std.mem.sliceAsBytes(other.weights.packed_bytes),
            ) or
                byteSlicesOverlap(
                    write,
                    std.mem.sliceAsBytes(other.weights.scales),
                ) or
                byteSlicesOverlap(
                    write,
                    std.mem.sliceAsBytes(other.weights.scales_f16),
                ) or
                byteSlicesOverlap(
                    write,
                    std.mem.sliceAsBytes(other.weights.scales_f16_rows4),
                ) or
                byteSlicesOverlap(
                    write,
                    std.mem.sliceAsBytes(other.weights.expanded_i8),
                ) or
                byteSlicesOverlap(write, std.mem.sliceAsBytes(other.bias)) or
                byteSlicesOverlap(
                    write,
                    std.mem.sliceAsBytes(projections[other_index].out.shape),
                ) or
                (other_index != index and byteSlicesOverlap(
                    write,
                    std.mem.sliceAsBytes(other.output),
                )))
                return TensorError.ShapeMismatch;
        }
    }

    const runSerial = struct {
        fn run(
            prepared_q: []const i8,
            prepared_scales: []const f32,
            members: []const BoundProjection,
            input_features: usize,
        ) TensorError!void {
            for (members) |projection| {
                try linearInt4WeightQ8PreparedBatchStrided(
                    prepared_q,
                    prepared_scales,
                    projection.weights,
                    projection.bias,
                    projection.output,
                    projection.batch,
                    projection.out_f,
                    input_features,
                    projection.out_f,
                );
            }
        }
    }.run;
    const task_count = @min(
        @min(max_tasks, max_row_tiles),
        prepared_batch_projection_max_tasks,
    );
    if (task_count < 2)
        return runSerial(q_input, activation_scales, bound, in_f);

    const Job = struct {
        q_input: []const i8,
        activation_scales: []const f32,
        projections: []const BoundProjection,
        task_index: usize,
        task_count: usize,
        in_f: usize,
        err: ?TensorError = null,

        fn run(job: *@This()) void {
            for (job.projections) |projection| {
                const row_tiles = projection.out_f / 4;
                const tile_start = row_tiles * job.task_index / job.task_count;
                const tile_end = row_tiles * (job.task_index + 1) /
                    job.task_count;
                if (tile_start == tile_end) continue;
                const out_start = tile_start * 4;
                const out_end = tile_end * 4;
                const start_element = out_start * job.in_f;
                const end_element = out_end * job.in_f;
                const group: usize = projection.weights.group_size;
                const packed_start = start_element / 2;
                const packed_end = ceilDiv(end_element, 2);
                const scale_start = start_element / group;
                const scale_end = ceilDiv(end_element, group);
                const row_count = out_end - out_start;
                const sub_weights: int4_weights.Int4WeightData = .{
                    .packed_bytes = projection.weights.packed_bytes[packed_start..packed_end],
                    .scales = if (projection.weights.scales.len == 0)
                        &.{}
                    else
                        projection.weights.scales[scale_start..scale_end],
                    .scales_f16 = if (projection.weights.scales_f16.len == 0)
                        &.{}
                    else
                        projection.weights.scales_f16[scale_start..scale_end],
                    .scales_f16_rows4 = projection.weights.scales_f16_rows4[scale_start..scale_end],
                    .expanded_i8 = &.{},
                    .group_size = projection.weights.group_size,
                    .num_elements = end_element - start_element,
                    .packed_layout = .rows4_k16,
                };
                const sub_bias = if (projection.bias.len == 0)
                    &.{}
                else
                    projection.bias[out_start..out_end];
                linearInt4WeightQ8PreparedBatchStrided(
                    job.q_input,
                    job.activation_scales,
                    sub_weights,
                    sub_bias,
                    projection.output[out_start..],
                    projection.batch,
                    row_count,
                    job.in_f,
                    projection.out_f,
                ) catch |err| {
                    job.err = err;
                    return;
                };
            }
        }
    };

    var jobs: [prepared_batch_projection_max_tasks]Job = undefined;
    for (jobs[0..task_count], 0..) |*job, task_index| {
        job.* = .{
            .q_input = q_input,
            .activation_scales = activation_scales,
            .projections = bound,
            .task_index = task_index,
            .task_count = task_count,
            .in_f = in_f,
        };
    }
    var wait_group: std.Thread.WaitGroup = .{};
    for (jobs[0..task_count]) |*job|
        pool.spawnWg(&wait_group, Job.run, .{job});
    pool.waitAndWork(&wait_group);
    for (jobs[0..task_count]) |job| if (job.err) |err| return err;
}

/// Quantize a float activation batch once, then run the parallel packed GEMM.
pub fn linearInt4WeightBatchQ8Parallel(
    pool: *std.Thread.Pool,
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    q_scratch: []i8,
    scale_scratch: []f32,
    max_tasks: usize,
) TensorError!void {
    if (x.shape.len != 2 or out.shape.len != 2 or x.shape[0] != out.shape[0] or
        x.shape[1] != in_f or out.shape[1] != out_f)
        return TensorError.ShapeMismatch;
    try quantizeQ8ActivationBatch(
        x.asF32(),
        x.shape[0],
        in_f,
        weights.group_size,
        q_scratch,
        scale_scratch,
    );
    return linearInt4WeightQ8PreparedBatchParallel(
        pool,
        q_scratch,
        scale_scratch,
        weights,
        bias,
        out,
        out_f,
        in_f,
        max_tasks,
    );
}

/// Convenience wrapper that validates the logical weight count carried by
/// the packed representation.
pub fn linearInt4Weight(
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const expected = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    if (weights.num_elements != expected or weights.packed_layout != .row_major)
        return TensorError.ShapeMismatch;
    // The M1's FP32-scale NEON path is faster than converting every FP16
    // scale in the hot loop (the scale stream is small compared with packed
    // weights). Keep scales_f16 for targets where half loads win.
    return linearInt4OnTheFly(
        x,
        weights.packed_bytes,
        weights.scales,
        bias,
        out,
        out_f,
        in_f,
        weights.group_size,
    );
}

fn linearInt4WeightF16Scale(
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
) TensorError!void {
    const expected = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    const packed_len = ceilDiv(expected, 2);
    const scale_len = ceilDiv(expected, weights.group_size);
    if (weights.group_size == 0 or weights.packed_bytes.len < packed_len or
        weights.scales_f16.len < scale_len or x.shape.len != 2 or x.shape[0] != 1 or
        x.shape[1] != in_f or out.shape.len != 2 or out.shape[0] != 1 or out.shape[1] != out_f or
        (bias.len != 0 and bias.len != out_f))
        return TensorError.ShapeMismatch;
    const bias_ptr: ?[*]const f32 = if (bias.len == out_f) bias.ptr else null;
    glacier_int4_matvec_neon_f16scale(
        x.asF32().ptr,
        weights.packed_bytes.ptr,
        weights.scales_f16.ptr,
        bias_ptr,
        out.asF32().ptr,
        out_f,
        in_f,
        weights.group_size,
    );
}

/// Parallel row-split INT4 matmul for the large decode projections. Each
/// worker owns a disjoint output-row range, so results are bit-identical to
/// the serial kernel. Falls back to serial when row boundaries do not align
/// with the packed/group layout or when the input batch is not one token.
pub fn linearInt4WeightParallel(
    pool: *std.Thread.Pool,
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    max_tasks: usize,
) TensorError!void {
    return linearInt4WeightParallelMode(pool, x, weights, bias, out, out_f, in_f, max_tasks, false);
}

/// Parallel row-split variant of the Q8 activation path.  Activation
/// quantization is cheap relative to a large projection; workers recompute
/// the small Q8 vector locally so no synchronization or shared scratch is
/// needed.
pub fn linearInt4WeightParallelQ8(
    pool: *std.Thread.Pool,
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    max_tasks: usize,
) TensorError!void {
    return linearInt4WeightParallelMode(pool, x, weights, bias, out, out_f, in_f, max_tasks, true);
}

fn linearInt4WeightParallelMode(
    pool: *std.Thread.Pool,
    x: Tensor,
    weights: int4_weights.Int4WeightData,
    bias: []const f32,
    out: Tensor,
    out_f: usize,
    in_f: usize,
    max_tasks: usize,
    use_q8: bool,
) TensorError!void {
    const serial: *const fn (Tensor, int4_weights.Int4WeightData, []const f32, Tensor, usize, usize) TensorError!void =
        if (use_q8) linearInt4WeightQ8 else linearInt4Weight;
    if (max_tasks < 2 or x.shape.len != 2 or x.shape[0] != 1 or
        out.shape.len != 2 or out.shape[0] != 1)
    {
        return serial(x, weights, bias, out, out_f, in_f);
    }
    const expected = std.math.mul(usize, out_f, in_f) catch return TensorError.ShapeMismatch;
    if (weights.num_elements != expected or weights.group_size == 0) return TensorError.ShapeMismatch;
    if (x.shape[1] != in_f or out.shape[1] != out_f) return TensorError.ShapeMismatch;
    if (bias.len != 0 and bias.len != out_f) return TensorError.ShapeMismatch;
    const scale_count = ceilDiv(expected, weights.group_size);
    const has_q8_scales = weights.scales.len >= scale_count or
        weights.scales_f16.len >= scale_count or
        weights.scales_f16_rows4.len >= scale_count;
    if (weights.packed_bytes.len < ceilDiv(expected, 2) or
        (use_q8 and !has_q8_scales) or (!use_q8 and weights.scales.len < scale_count))
    {
        return TensorError.ShapeMismatch;
    }
    // Four-row-interleaved scales can only be sliced at four-row tile
    // boundaries. Keep this rare legacy/failure path serial; the persistent
    // executor uses aligned 64-row shards.
    if (weights.scales_f16_rows4.len != 0)
        return serial(x, weights, bias, out, out_f, in_f);
    const task_count = @min(@min(max_tasks, out_f), 16);
    if (task_count < 2) return serial(x, weights, bias, out, out_f, in_f);

    const Job = struct {
        x: Tensor,
        weights: int4_weights.Int4WeightData,
        bias: []const f32,
        out: Tensor,
        out_start: usize,
        out_end: usize,
        in_f: usize,
        use_q8: bool,
        err: ?TensorError = null,

        fn run(job: *@This()) void {
            const start_element = job.out_start * job.in_f;
            const end_element = job.out_end * job.in_f;
            const group_size: usize = job.weights.group_size;
            const packed_start = start_element / 2;
            const packed_end = ceilDiv(end_element, 2);
            const scale_start = start_element / group_size;
            const scale_end = ceilDiv(end_element, group_size);
            const row_count = job.out_end - job.out_start;
            var out_shape = [2]usize{ 1, row_count };
            const byte_start = job.out_start * @sizeOf(f32);
            const byte_end = job.out_end * @sizeOf(f32);
            const out_view: Tensor = .{
                .dtype = .f32,
                .shape = &out_shape,
                .data = job.out.data[byte_start..byte_end],
                .allocator = std.heap.page_allocator,
            };
            const sub_weights: int4_weights.Int4WeightData = .{
                .packed_bytes = job.weights.packed_bytes[packed_start..packed_end],
                .scales = if (job.weights.scales.len == 0) &.{} else job.weights.scales[scale_start..scale_end],
                .scales_f16 = if (job.weights.scales_f16.len == 0) &.{} else job.weights.scales_f16[scale_start..scale_end],
                .scales_f16_rows4 = &.{},
                .expanded_i8 = if (job.weights.expanded_i8.len == 0) &.{} else job.weights.expanded_i8[start_element..end_element],
                .group_size = job.weights.group_size,
                .num_elements = end_element - start_element,
                .packed_layout = job.weights.packed_layout,
            };
            const sub_bias = if (job.bias.len == 0) &.{} else job.bias[job.out_start..job.out_end];
            const result = if (job.use_q8)
                linearInt4WeightQ8(job.x, sub_weights, sub_bias, out_view, row_count, job.in_f)
            else
                linearInt4Weight(job.x, sub_weights, sub_bias, out_view, row_count, job.in_f);
            result catch |err| {
                job.err = err;
            };
        }
    };

    var jobs: [16]Job = undefined;
    for (0..task_count) |task_idx| {
        const out_start = out_f * task_idx / task_count;
        const out_end = out_f * (task_idx + 1) / task_count;
        const start_element = out_start * in_f;
        const end_element = out_end * in_f;
        if (start_element % 2 != 0 or end_element % 2 != 0 or
            start_element % weights.group_size != 0 or end_element % weights.group_size != 0)
        {
            return serial(x, weights, bias, out, out_f, in_f);
        }
        jobs[task_idx] = .{
            .x = x,
            .weights = weights,
            .bias = bias,
            .out = out,
            .out_start = out_start,
            .out_end = out_end,
            .in_f = in_f,
            .use_q8 = use_q8,
        };
    }

    var wait_group: std.Thread.WaitGroup = .{};
    for (jobs[0..task_count]) |*job| pool.spawnWg(&wait_group, Job.run, .{job});
    pool.waitAndWork(&wait_group);
    for (jobs[0..task_count]) |job| if (job.err) |err| return err;
}

/// Decode one logical matrix row without materializing the whole tensor.
/// Used for token embedding lookup in compact mode.
pub fn dequantizeRow(
    weights: int4_weights.Int4WeightData,
    row: usize,
    row_width: usize,
    out: []f32,
) TensorError!void {
    if (weights.group_size == 0 or row_width == 0 or out.len != row_width)
        return TensorError.ShapeMismatch;
    if (weights.num_elements % row_width != 0) return TensorError.ShapeMismatch;
    const row_count = weights.num_elements / row_width;
    if (weights.packed_layout == .rows4_k16 and
        (row_count % 4 != 0 or row_width % 16 != 0))
        return TensorError.ShapeMismatch;
    const start = std.math.mul(usize, row, row_width) catch return TensorError.ShapeMismatch;
    if (start > weights.num_elements or row_width > weights.num_elements - start) return TensorError.ShapeMismatch;
    const packed_len = ceilDiv(weights.num_elements, 2);
    const scale_len = ceilDiv(weights.num_elements, weights.group_size);
    if (weights.packed_bytes.len < packed_len or weights.scales.len < scale_len) return TensorError.ShapeMismatch;
    for (out, 0..) |*dst, col| {
        const logical = start + col;
        const physical = int4_weights.packedNibbleIndex(
            weights.packed_layout,
            row,
            col,
            row_width,
        );
        const byte = weights.packed_bytes[physical / 2];
        const nibble: u8 = if (physical & 1 == 0) byte & 0x0f else byte >> 4;
        dst.* = NIBBLE_TO_OFFSET[@as(usize, nibble)] * weights.scales[logical / weights.group_size];
    }
}

inline fn dequantElement(
    packed_weights: []const u8,
    scales: []const f32,
    idx: usize,
    group_size: usize,
) f32 {
    const byte = packed_weights[idx / 2];
    const nibble: u8 = if (idx & 1 == 0) byte & 0x0F else (byte >> 4) & 0x0F;
    return NIBBLE_TO_OFFSET[@as(usize, nibble)] * scales[idx / group_size];
}

inline fn dotInt4x8(
    x_row: []const f32,
    x_offset: usize,
    packed_weights: []const u8,
    weight_offset: usize,
) f32 {
    return @reduce(.Add, loadInt4x8(packed_weights, weight_offset) * loadF32x8(x_row, x_offset));
}

inline fn loadInt4x8(packed_weights: []const u8, weight_offset: usize) Vec8 {
    const byte_base = weight_offset / 2;
    const b0 = packed_weights[byte_base];
    const b1 = packed_weights[byte_base + 1];
    const b2 = packed_weights[byte_base + 2];
    const b3 = packed_weights[byte_base + 3];
    return .{
        NIBBLE_TO_OFFSET[@as(usize, b0 & 0xF)],
        NIBBLE_TO_OFFSET[@as(usize, (b0 >> 4) & 0xF)],
        NIBBLE_TO_OFFSET[@as(usize, b1 & 0xF)],
        NIBBLE_TO_OFFSET[@as(usize, (b1 >> 4) & 0xF)],
        NIBBLE_TO_OFFSET[@as(usize, b2 & 0xF)],
        NIBBLE_TO_OFFSET[@as(usize, (b2 >> 4) & 0xF)],
        NIBBLE_TO_OFFSET[@as(usize, b3 & 0xF)],
        NIBBLE_TO_OFFSET[@as(usize, (b3 >> 4) & 0xF)],
    };
}

inline fn loadF32x8(values: []const f32, offset: usize) Vec8 {
    return .{
        values[offset],     values[offset + 1], values[offset + 2], values[offset + 3],
        values[offset + 4], values[offset + 5], values[offset + 6], values[offset + 7],
    };
}

inline fn ceilDiv(numerator: usize, denominator: usize) usize {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const quant = @import("core").quant;

test "int4 on-the-fly matches full dequant + matmul" {
    // Quantize a small weight matrix, then compare:
    //   (a) full dequant → linearF32
    //   (b) on-the-fly int4 matmul
    const in_f: usize = 64;
    const out_f: usize = 8;
    const group_size: usize = 64;

    var rng = std.Random.DefaultPrng.init(42);
    var w_vals: [in_f * out_f]f32 = undefined;
    for (&w_vals) |*v| v.* = (rng.random().float(f32) * 2 - 1) * 0.1;

    // Quantize.
    const q = try quant.quantize(f32, testing.allocator, &w_vals, .int4, group_size);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }

    // Input.
    var x_vals: [in_f]f32 = undefined;
    for (&x_vals) |*v| v.* = (rng.random().float(f32) * 2 - 1);
    var x = try tensor.fromF32(testing.allocator, &.{ 1, in_f }, &x_vals);
    defer x.deinit();

    // (a) Full dequant + linearF32.
    const w_dequant = try quant.dequantize(f32, testing.allocator, q.packed_bytes, q.scales, .int4, group_size, w_vals.len);
    defer testing.allocator.free(w_dequant);
    var out_ref = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer out_ref.deinit();
    var w_tensor = try tensor.fromF32(testing.allocator, &.{ out_f, in_f }, w_dequant);
    defer w_tensor.deinit();
    try @import("kernels.zig").linearF32(x, w_tensor, &.{}, out_ref);

    // (b) On-the-fly. Same out tensor reused — check it matches.
    // Since we use the same quant data, results should be identical.
    var out_otf = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer out_otf.deinit();
    try linearInt4OnTheFly(x, q.packed_bytes, q.scales, &.{}, out_otf, out_f, in_f, group_size);

    // Compare.
    for (out_ref.asF32(), out_otf.asF32()) |a, b| {
        try testing.expectApproxEqAbs(a, b, 2e-6);
    }
}

test "int4 handles vector lanes crossing quant groups" {
    const in_f: usize = 18;
    const out_f: usize = 3;
    const group_size: usize = 10;
    var weights: [in_f * out_f]f32 = undefined;
    for (&weights, 0..) |*v, i| v.* = (@as(f32, @floatFromInt(i % 17)) - 8) / 13.0;
    const q = try quant.quantize(f32, testing.allocator, &weights, .int4, group_size);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }
    const dequant = try quant.dequantize(f32, testing.allocator, q.packed_bytes, q.scales, .int4, group_size, weights.len);
    defer testing.allocator.free(dequant);
    var x = try tensor.fromF32(testing.allocator, &.{ 1, in_f }, &([_]f32{1.25} ** in_f));
    defer x.deinit();
    var w = try tensor.fromF32(testing.allocator, &.{ out_f, in_f }, dequant);
    defer w.deinit();
    var expected = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer expected.deinit();
    var actual = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer actual.deinit();
    try @import("kernels.zig").linearF32(x, w, &.{}, expected);
    try linearInt4OnTheFly(x, q.packed_bytes, q.scales, &.{}, actual, out_f, in_f, group_size);
    for (expected.asF32(), actual.asF32()) |a, b| try testing.expectApproxEqAbs(a, b, 2e-6);
}

test "optimized g8 and g16 kernels match full dequant matmul" {
    const in_f: usize = 64;
    const out_f: usize = 9;
    var source: [in_f * out_f]f32 = undefined;
    var input_values: [in_f]f32 = undefined;
    for (&source, 0..) |*value, i| value.* = (@as(f32, @floatFromInt(i % 29)) - 14) / 31.0;
    for (&input_values, 0..) |*value, i| value.* = (@as(f32, @floatFromInt(i % 13)) - 6) / 9.0;

    for ([_]usize{ 8, 16 }) |group_size| {
        const q = try quant.quantize(f32, testing.allocator, &source, .int4, @intCast(group_size));
        defer {
            testing.allocator.free(q.packed_bytes);
            testing.allocator.free(q.scales);
        }
        const dequant = try quant.dequantize(
            f32,
            testing.allocator,
            q.packed_bytes,
            q.scales,
            .int4,
            @intCast(group_size),
            source.len,
        );
        defer testing.allocator.free(dequant);
        var input = try tensor.fromF32(testing.allocator, &.{ 1, in_f }, &input_values);
        defer input.deinit();
        var full_weights = try tensor.fromF32(testing.allocator, &.{ out_f, in_f }, dequant);
        defer full_weights.deinit();
        var expected = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
        defer expected.deinit();
        var actual = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
        defer actual.deinit();
        try @import("kernels.zig").linearF32(input, full_weights, &.{}, expected);
        try linearInt4OnTheFly(
            input,
            q.packed_bytes,
            q.scales,
            &.{},
            actual,
            out_f,
            in_f,
            group_size,
        );
        for (expected.asF32(), actual.asF32()) |reference, optimized| {
            try testing.expectApproxEqAbs(reference, optimized, 2e-5);
        }
    }
}

test "q8 activation INT4 path stays close to FP32 activation reference" {
    const in_f: usize = 64;
    const out_f: usize = 12;
    var source: [in_f * out_f]f32 = undefined;
    var input_values: [in_f]f32 = undefined;
    for (&source, 0..) |*value, i| {
        value.* = (@as(f32, @floatFromInt((i * 17) % 31)) - 15) / 23.0;
    }
    for (&input_values, 0..) |*value, i| {
        value.* = (@as(f32, @floatFromInt((i * 7) % 19)) - 9) / 11.0;
    }

    for ([_]usize{ 8, 16 }) |group_size| {
        const q = try quant.quantize(f32, testing.allocator, &source, .int4, @intCast(group_size));
        defer {
            testing.allocator.free(q.packed_bytes);
            testing.allocator.free(q.scales);
        }
        const weights: int4_weights.Int4WeightData = .{
            .packed_bytes = q.packed_bytes,
            .scales = q.scales,
            .group_size = @intCast(group_size),
            .num_elements = source.len,
        };
        var scale_half_storage: [source.len]f16 = undefined;
        const scale_half = scale_half_storage[0..q.scales.len];
        for (q.scales, scale_half) |src_scale, *dst_scale| dst_scale.* = @floatCast(src_scale);
        const weights_half = int4_weights.Int4WeightData{
            .packed_bytes = q.packed_bytes,
            .scales = q.scales,
            .scales_f16 = scale_half,
            .group_size = @intCast(group_size),
            .num_elements = source.len,
        };
        var input = try tensor.fromF32(testing.allocator, &.{ 1, in_f }, &input_values);
        defer input.deinit();
        const dequant = try quant.dequantize(f32, testing.allocator, q.packed_bytes, q.scales, .int4, @intCast(group_size), source.len);
        defer testing.allocator.free(dequant);
        var full_weights = try tensor.fromF32(testing.allocator, &.{ out_f, in_f }, dequant);
        defer full_weights.deinit();
        var expected = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
        defer expected.deinit();
        var actual = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
        defer actual.deinit();
        try @import("kernels.zig").linearF32(input, full_weights, &.{}, expected);
        try linearInt4WeightQ8(input, weights, &.{}, actual, out_f, in_f);
        for (expected.asF32(), actual.asF32()) |reference, optimized| {
            try testing.expectApproxEqAbs(reference, optimized, 0.08);
        }
        if (comptime builtin.cpu.arch == .aarch64) {
            var q_input: [in_f]i8 = undefined;
            var activation_scales: [in_f]f32 = undefined;
            var prepared_out = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
            defer prepared_out.deinit();
            const scale_count = q8ActivationScaleCount(in_f, group_size);
            try quantizeQ8Activation(
                input.asF32(),
                group_size,
                &q_input,
                activation_scales[0..scale_count],
            );
            try linearInt4WeightQ8Prepared(
                &q_input,
                activation_scales[0..scale_count],
                weights,
                &.{},
                prepared_out,
                out_f,
                in_f,
            );
            try testing.expectEqualSlices(f32, actual.asF32(), prepared_out.asF32());

            const rows4_with_f32 = try int4_weights.withRows4F16Scales(
                testing.allocator,
                weights,
                out_f,
            );
            defer testing.allocator.free(rows4_with_f32.scales_f16_rows4);
            var rows4_only = rows4_with_f32;
            rows4_only.scales = &.{};
            var rows4_out = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
            defer rows4_out.deinit();
            try linearInt4WeightQ8(input, rows4_only, &.{}, rows4_out, out_f, in_f);
            for (expected.asF32(), rows4_out.asF32()) |reference, optimized| {
                try testing.expectApproxEqAbs(reference, optimized, 0.08);
            }
            var rows4_prepared_out = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
            defer rows4_prepared_out.deinit();
            try linearInt4WeightQ8Prepared(
                &q_input,
                activation_scales[0..scale_count],
                rows4_only,
                &.{},
                rows4_prepared_out,
                out_f,
                in_f,
            );
            try testing.expectEqualSlices(f32, rows4_out.asF32(), rows4_prepared_out.asF32());

            const tiled_packed = try testing.allocator.dupe(u8, q.packed_bytes);
            defer testing.allocator.free(tiled_packed);
            var tiled_source = rows4_with_f32;
            tiled_source.packed_bytes = tiled_packed;
            const tiled = try int4_weights.withRows4K16Packing(
                testing.allocator,
                tiled_source,
                out_f,
            );
            var tiled_out = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
            defer tiled_out.deinit();
            try linearInt4WeightQ8Prepared(
                &q_input,
                activation_scales[0..scale_count],
                tiled,
                &.{},
                tiled_out,
                out_f,
                in_f,
            );
            for (rows4_prepared_out.asF32(), tiled_out.asF32()) |reference, optimized| {
                try testing.expectApproxEqAbs(reference, optimized, 1e-6);
            }

            var planned_out = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
            defer planned_out.deinit();
            const recipe = try PreparedQ8MatvecPlan.init(
                tiled,
                &.{},
                planned_out,
                out_f,
                in_f,
            );
            const bound = try recipe.bind(
                &q_input,
                activation_scales[0..scale_count],
            );
            try bound.runRows(0, 4);
            try bound.runRows(4, out_f);
            try testing.expectEqualSlices(
                f32,
                tiled_out.asF32(),
                planned_out.asF32(),
            );
            try testing.expectError(
                TensorError.ShapeMismatch,
                bound.runRows(1, 4),
            );
            var bad_output = planned_out;
            bad_output.dtype = .f16;
            try testing.expectError(
                TensorError.ShapeMismatch,
                PreparedQ8MatvecPlan.init(
                    tiled,
                    &.{},
                    bad_output,
                    out_f,
                    in_f,
                ),
            );

            var decoded_row: [in_f]f32 = undefined;
            try dequantizeRow(tiled, 3, in_f, &decoded_row);
            for (decoded_row, dequant[3 * in_f .. 4 * in_f]) |actual_value, reference| {
                try testing.expectEqual(reference, actual_value);
            }
        }
        var half_scale_out = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
        defer half_scale_out.deinit();
        try linearInt4Weight(input, weights_half, &.{}, half_scale_out, out_f, in_f);
        for (expected.asF32(), half_scale_out.asF32()) |reference, optimized| {
            try testing.expectApproxEqAbs(reference, optimized, 0.02);
        }
    }
}

test "q8 projection rejects weight groups that cross row boundaries" {
    const in_f: usize = 3;
    const out_f: usize = 8;
    const group_size: usize = 8;
    const element_count = in_f * out_f;
    const packed_bytes = [_]u8{0x77} ** (element_count / 2);
    const scales = [_]f32{1.0} ** (element_count / group_size);
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = group_size,
        .num_elements = element_count,
    };
    var input = try tensor.fromF32(
        testing.allocator,
        &.{ 1, in_f },
        &([_]f32{1.0} ** in_f),
    );
    defer input.deinit();
    var output = try tensor.fromF32(
        testing.allocator,
        &.{ 1, out_f },
        &([_]f32{9.0} ** out_f),
    );
    defer output.deinit();

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearInt4WeightQ8(input, weights, &.{}, output, out_f, in_f),
    );
    for (output.asF32()) |value| try testing.expectEqual(@as(f32, 9.0), value);

    if (comptime builtin.cpu.arch == .aarch64) {
        const q_input = [_]i8{1} ** in_f;
        const activation_scales = [_]f32{1.0};
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearInt4WeightQ8Prepared(
                &q_input,
                &activation_scales,
                weights,
                &.{},
                output,
                out_f,
                in_f,
            ),
        );
        for (output.asF32()) |value| try testing.expectEqual(@as(f32, 9.0), value);
    }
}

test "parallel int4 row split is bit-identical" {
    const in_f: usize = 64;
    const out_f: usize = 17;
    const group_size: usize = 64;
    var source: [in_f * out_f]f32 = undefined;
    for (&source, 0..) |*value, i| value.* = (@as(f32, @floatFromInt(i % 23)) - 11) / 17.0;
    const q = try quant.quantize(f32, testing.allocator, &source, .int4, group_size);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }
    const weights: int4_weights.Int4WeightData = .{
        .packed_bytes = q.packed_bytes,
        .scales = q.scales,
        .group_size = group_size,
        .num_elements = source.len,
    };
    var x = try tensor.fromF32(testing.allocator, &.{ 1, in_f }, &([_]f32{0.75} ** in_f));
    defer x.deinit();
    var serial = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer serial.deinit();
    var parallel = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer parallel.deinit();
    try linearInt4Weight(x, weights, &.{}, serial, out_f, in_f);
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = testing.allocator, .n_jobs = 2 });
    defer pool.deinit();
    try linearInt4WeightParallel(&pool, x, weights, &.{}, parallel, out_f, in_f, 3);
    try testing.expectEqualSlices(f32, serial.asF32(), parallel.asF32());

    // Validate malformed metadata before workers slice the shared buffers.
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearInt4WeightParallel(&pool, x, weights, &.{1.0}, parallel, out_f, in_f, 3),
    );
    var truncated = weights;
    truncated.packed_bytes = truncated.packed_bytes[0 .. truncated.packed_bytes.len - 1];
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearInt4WeightParallel(&pool, x, truncated, &.{}, parallel, out_f, in_f, 3),
    );
}

test "rows4 K16 batch microkernel matches repeated matvec for g8 g16 and tails" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const in_f: usize = 80; // K64 body plus one K16 tail.
    const out_f: usize = 68; // Seventeen row tiles also exercise the 16-job cap.
    const max_batch: usize = 7; // M4 body plus M1/M2/M3 tails.
    var source: [in_f * out_f]f32 = undefined;
    var inputs: [max_batch * in_f]f32 = undefined;
    var bias: [out_f]f32 = undefined;
    for (&source, 0..) |*value, i| {
        value.* = (@as(f32, @floatFromInt((i * 19 + 5) % 47)) - 23) / 31.0;
    }
    for (&inputs, 0..) |*value, i| {
        value.* = (@as(f32, @floatFromInt((i * 11 + 3) % 37)) - 18) / 29.0;
    }
    for (&bias, 0..) |*value, i| {
        value.* = (@as(f32, @floatFromInt(i)) - 9) / 113.0;
    }

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = testing.allocator, .n_jobs = 3 });
    defer pool.deinit();

    for ([_]usize{ 8, 16 }) |group_size| {
        const q = try quant.quantize(
            f32,
            testing.allocator,
            &source,
            .int4,
            @intCast(group_size),
        );
        defer {
            testing.allocator.free(q.packed_bytes);
            testing.allocator.free(q.scales);
        }
        const base_weights: int4_weights.Int4WeightData = .{
            .packed_bytes = q.packed_bytes,
            .scales = q.scales,
            .group_size = @intCast(group_size),
            .num_elements = source.len,
        };
        const with_rows4_scales = try int4_weights.withRows4F16Scales(
            testing.allocator,
            base_weights,
            out_f,
        );
        defer testing.allocator.free(with_rows4_scales.scales_f16_rows4);
        const tiled_bytes = try testing.allocator.dupe(u8, q.packed_bytes);
        defer testing.allocator.free(tiled_bytes);
        var tiled_source = with_rows4_scales;
        tiled_source.packed_bytes = tiled_bytes;
        const weights = try int4_weights.withRows4K16Packing(
            testing.allocator,
            tiled_source,
            out_f,
        );

        const scale_stride = q8ActivationScaleCount(in_f, group_size);
        var q_inputs: [max_batch * in_f]i8 = undefined;
        const max_scale_stride = comptime @max(
            q8ActivationScaleCount(in_f, 8),
            q8ActivationScaleCount(in_f, 16),
        );
        var activation_scales: [max_batch * max_scale_stride]f32 = undefined;
        for ([_]usize{ 1, 2, 3, 4, 5, 7 }) |batch| {
            try quantizeQ8ActivationBatch(
                inputs[0 .. batch * in_f],
                batch,
                in_f,
                group_size,
                q_inputs[0 .. batch * in_f],
                activation_scales[0 .. batch * scale_stride],
            );
            var expected = try tensor.zerosF32(testing.allocator, &.{ batch, out_f });
            defer expected.deinit();
            var actual = try tensor.zerosF32(testing.allocator, &.{ batch, out_f });
            defer actual.deinit();
            var parallel = try tensor.zerosF32(testing.allocator, &.{ batch, out_f });
            defer parallel.deinit();

            for (0..batch) |row| {
                var row_shape = [2]usize{ 1, out_f };
                const row_bytes = std.mem.sliceAsBytes(
                    expected.asF32()[row * out_f ..][0..out_f],
                );
                const row_out: Tensor = .{
                    .dtype = .f32,
                    .shape = &row_shape,
                    .data = row_bytes,
                    .allocator = std.heap.page_allocator,
                };
                try linearInt4WeightQ8Prepared(
                    q_inputs[row * in_f ..][0..in_f],
                    activation_scales[row * scale_stride ..][0..scale_stride],
                    weights,
                    &bias,
                    row_out,
                    out_f,
                    in_f,
                );
            }
            try linearInt4WeightQ8PreparedBatch(
                q_inputs[0 .. batch * in_f],
                activation_scales[0 .. batch * scale_stride],
                weights,
                &bias,
                actual,
                out_f,
                in_f,
            );
            try testing.expectEqualSlices(f32, expected.asF32(), actual.asF32());

            try linearInt4WeightQ8PreparedBatchParallel(
                &pool,
                q_inputs[0 .. batch * in_f],
                activation_scales[0 .. batch * scale_stride],
                weights,
                &bias,
                parallel,
                out_f,
                in_f,
                if (batch == max_batch) 64 else 4,
            );
            try testing.expectEqualSlices(f32, expected.asF32(), parallel.asF32());
        }

        // Reject malformed shared metadata before any worker computes shard
        // offsets or slices the caller-owned payloads.
        const malformed_batch: usize = 4;
        try quantizeQ8ActivationBatch(
            inputs[0 .. malformed_batch * in_f],
            malformed_batch,
            in_f,
            group_size,
            q_inputs[0 .. malformed_batch * in_f],
            activation_scales[0 .. malformed_batch * scale_stride],
        );
        var malformed_out = try tensor.zerosF32(
            testing.allocator,
            &.{ malformed_batch, out_f },
        );
        defer malformed_out.deinit();
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearInt4WeightQ8PreparedBatchParallel(
                &pool,
                q_inputs[0 .. malformed_batch * in_f],
                activation_scales[0 .. malformed_batch * scale_stride],
                weights,
                &.{1.0},
                malformed_out,
                out_f,
                in_f,
                64,
            ),
        );
        var truncated_packed = weights;
        truncated_packed.packed_bytes =
            truncated_packed.packed_bytes[0 .. truncated_packed.packed_bytes.len - 1];
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearInt4WeightQ8PreparedBatchParallel(
                &pool,
                q_inputs[0 .. malformed_batch * in_f],
                activation_scales[0 .. malformed_batch * scale_stride],
                truncated_packed,
                &bias,
                malformed_out,
                out_f,
                in_f,
                64,
            ),
        );
        var truncated_rows4_scales = weights;
        truncated_rows4_scales.scales_f16_rows4 = truncated_rows4_scales
            .scales_f16_rows4[0 .. truncated_rows4_scales.scales_f16_rows4.len - 1];
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearInt4WeightQ8PreparedBatchParallel(
                &pool,
                q_inputs[0 .. malformed_batch * in_f],
                activation_scales[0 .. malformed_batch * scale_stride],
                truncated_rows4_scales,
                &bias,
                malformed_out,
                out_f,
                in_f,
                64,
            ),
        );

        // A prepared projection wave must preserve every result bit while
        // replacing three independent worker epochs with one.
        var serial_a = try tensor.zerosF32(
            testing.allocator,
            &.{ malformed_batch, out_f },
        );
        defer serial_a.deinit();
        var serial_b = try tensor.zerosF32(
            testing.allocator,
            &.{ malformed_batch, out_f },
        );
        defer serial_b.deinit();
        var serial_c = try tensor.zerosF32(
            testing.allocator,
            &.{ malformed_batch, out_f },
        );
        defer serial_c.deinit();
        var wave_a = try tensor.zerosF32(
            testing.allocator,
            &.{ malformed_batch, out_f },
        );
        defer wave_a.deinit();
        var wave_b = try tensor.zerosF32(
            testing.allocator,
            &.{ malformed_batch, out_f },
        );
        defer wave_b.deinit();
        var wave_c = try tensor.zerosF32(
            testing.allocator,
            &.{ malformed_batch, out_f },
        );
        defer wave_c.deinit();
        try linearInt4WeightQ8PreparedBatchParallel(
            &pool,
            q_inputs[0 .. malformed_batch * in_f],
            activation_scales[0 .. malformed_batch * scale_stride],
            weights,
            &bias,
            serial_a,
            out_f,
            in_f,
            4,
        );
        try linearInt4WeightQ8PreparedBatchParallel(
            &pool,
            q_inputs[0 .. malformed_batch * in_f],
            activation_scales[0 .. malformed_batch * scale_stride],
            weights,
            &.{},
            serial_b,
            out_f,
            in_f,
            4,
        );
        try linearInt4WeightQ8PreparedBatchParallel(
            &pool,
            q_inputs[0 .. malformed_batch * in_f],
            activation_scales[0 .. malformed_batch * scale_stride],
            weights,
            &bias,
            serial_c,
            out_f,
            in_f,
            4,
        );
        const wave = [_]PreparedBatchProjection{
            .{ .weights = weights, .bias = &bias, .out = wave_a, .out_f = out_f },
            .{ .weights = weights, .bias = &.{}, .out = wave_b, .out_f = out_f },
            .{ .weights = weights, .bias = &bias, .out = wave_c, .out_f = out_f },
        };
        try linearInt4WeightQ8PreparedBatchProjectionWave(
            &pool,
            q_inputs[0 .. malformed_batch * in_f],
            activation_scales[0 .. malformed_batch * scale_stride],
            &wave,
            in_f,
            4,
        );
        try testing.expectEqualSlices(u8, serial_a.data, wave_a.data);
        try testing.expectEqualSlices(u8, serial_b.data, wave_b.data);
        try testing.expectEqualSlices(u8, serial_c.data, wave_c.data);

        // Cross-output aliases and a malformed later member reject before a
        // valid earlier member can alter its sentinel-filled output.
        @memset(wave_a.asF32Unsafe(), 17.0);
        const alias_wave = [_]PreparedBatchProjection{
            .{ .weights = weights, .bias = &bias, .out = wave_a, .out_f = out_f },
            .{ .weights = weights, .bias = &.{}, .out = wave_a, .out_f = out_f },
        };
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearInt4WeightQ8PreparedBatchProjectionWave(
                &pool,
                q_inputs[0 .. malformed_batch * in_f],
                activation_scales[0 .. malformed_batch * scale_stride],
                &alias_wave,
                in_f,
                4,
            ),
        );
        for (wave_a.asF32Unsafe()) |value|
            try testing.expectEqual(@as(f32, 17.0), value);

        const aliased_weight_bytes = try testing.allocator.alignedAlloc(
            u8,
            .@"4",
            weights.packed_bytes.len,
        );
        defer testing.allocator.free(aliased_weight_bytes);
        @memcpy(aliased_weight_bytes, weights.packed_bytes);
        const aliased_weight_snapshot = try testing.allocator.dupe(
            u8,
            aliased_weight_bytes,
        );
        defer testing.allocator.free(aliased_weight_snapshot);
        var aliased_weights = weights;
        aliased_weights.packed_bytes = aliased_weight_bytes;
        var aliased_shape = [2]usize{ malformed_batch, out_f };
        const cross_read_output: Tensor = .{
            .dtype = .f32,
            .shape = &aliased_shape,
            .data = aliased_weight_bytes[0 .. malformed_batch * out_f *
                @sizeOf(f32)],
            .allocator = std.heap.page_allocator,
        };
        const cross_read_wave = [_]PreparedBatchProjection{
            .{ .weights = weights, .bias = &bias, .out = cross_read_output, .out_f = out_f },
            .{ .weights = aliased_weights, .bias = &.{}, .out = wave_b, .out_f = out_f },
        };
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearInt4WeightQ8PreparedBatchProjectionWave(
                &pool,
                q_inputs[0 .. malformed_batch * in_f],
                activation_scales[0 .. malformed_batch * scale_stride],
                &cross_read_wave,
                in_f,
                4,
            ),
        );
        try testing.expectEqualSlices(
            u8,
            aliased_weight_snapshot,
            aliased_weight_bytes,
        );

        var malformed_member = weights;
        malformed_member.scales_f16_rows4 = malformed_member
            .scales_f16_rows4[0 .. malformed_member.scales_f16_rows4.len - 1];
        const malformed_wave = [_]PreparedBatchProjection{
            .{ .weights = weights, .bias = &bias, .out = wave_a, .out_f = out_f },
            .{ .weights = malformed_member, .bias = &.{}, .out = wave_b, .out_f = out_f },
        };
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearInt4WeightQ8PreparedBatchProjectionWave(
                &pool,
                q_inputs[0 .. malformed_batch * in_f],
                activation_scales[0 .. malformed_batch * scale_stride],
                &malformed_wave,
                in_f,
                4,
            ),
        );
        for (wave_a.asF32Unsafe()) |value|
            try testing.expectEqual(@as(f32, 17.0), value);
    }
}

fn expectPairNibbleF32Bits(expected: []const f32, actual: []const f32) !void {
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(expected),
        std.mem.sliceAsBytes(actual),
    );
}

fn runPairNibbleDifferentialCase(
    in_f: usize,
    group_size: usize,
    check_validation: bool,
) !void {
    const out_f: usize = 68; // Non-power-of-two rows4 tile count.
    const max_in_f: usize = 128;
    const max_batch: usize = 9;
    const element_count = in_f * out_f;
    var gate_source: [out_f * max_in_f]f32 = undefined;
    var up_source: [out_f * max_in_f]f32 = undefined;
    var inputs: [max_batch * max_in_f]f32 = undefined;
    var gate_bias: [out_f]f32 = undefined;
    var up_bias: [out_f]f32 = undefined;
    for (gate_source[0..element_count], 0..) |*value, index| {
        value.* = (@as(f32, @floatFromInt((index * 19 + in_f + 7) % 53)) - 26) / 37.0;
    }
    for (up_source[0..element_count], 0..) |*value, index| {
        value.* = (@as(f32, @floatFromInt((index * 23 + group_size + 11) % 59)) - 29) / 41.0;
    }
    for (inputs[0 .. max_batch * in_f], 0..) |*value, index| {
        value.* = (@as(f32, @floatFromInt((index * 13 + in_f + 3) % 43)) - 21) / 31.0;
    }
    for (&gate_bias, &up_bias, 0..) |*gate_value, *up_value, index| {
        gate_value.* = (@as(f32, @floatFromInt(index % 17)) - 8) / 127.0;
        up_value.* = (@as(f32, @floatFromInt(index % 13)) - 6) / 131.0;
    }

    const gate_quant = try quant.quantize(
        f32,
        testing.allocator,
        gate_source[0..element_count],
        .int4,
        @intCast(group_size),
    );
    defer {
        testing.allocator.free(gate_quant.packed_bytes);
        testing.allocator.free(gate_quant.scales);
    }
    const up_quant = try quant.quantize(
        f32,
        testing.allocator,
        up_source[0..element_count],
        .int4,
        @intCast(group_size),
    );
    defer {
        testing.allocator.free(up_quant.packed_bytes);
        testing.allocator.free(up_quant.scales);
    }
    const gate_base: int4_weights.Int4WeightData = .{
        .packed_bytes = gate_quant.packed_bytes,
        .scales = gate_quant.scales,
        .group_size = @intCast(group_size),
        .num_elements = element_count,
    };
    const up_base: int4_weights.Int4WeightData = .{
        .packed_bytes = up_quant.packed_bytes,
        .scales = up_quant.scales,
        .group_size = @intCast(group_size),
        .num_elements = element_count,
    };
    const gate_scaled = try int4_weights.withRows4F16Scales(
        testing.allocator,
        gate_base,
        out_f,
    );
    defer testing.allocator.free(gate_scaled.scales_f16_rows4);
    const up_scaled = try int4_weights.withRows4F16Scales(
        testing.allocator,
        up_base,
        out_f,
    );
    defer testing.allocator.free(up_scaled.scales_f16_rows4);
    const gate_bytes = try testing.allocator.dupe(u8, gate_quant.packed_bytes);
    defer testing.allocator.free(gate_bytes);
    const up_bytes = try testing.allocator.dupe(u8, up_quant.packed_bytes);
    defer testing.allocator.free(up_bytes);
    var gate_packable = gate_scaled;
    gate_packable.packed_bytes = gate_bytes;
    var up_packable = up_scaled;
    up_packable.packed_bytes = up_bytes;
    const gate_weights = try int4_weights.withRows4K16Packing(
        testing.allocator,
        gate_packable,
        out_f,
    );
    const up_weights = try int4_weights.withRows4K16Packing(
        testing.allocator,
        up_packable,
        out_f,
    );
    const paired_bytes = try testing.allocator.alloc(u8, element_count);
    defer testing.allocator.free(paired_bytes);
    const paired_scales = try testing.allocator.alloc(
        f16,
        2 * element_count / group_size,
    );
    defer testing.allocator.free(paired_scales);
    const pair = try int4_weights.pairRows4K16(
        gate_weights,
        up_weights,
        out_f,
        paired_bytes,
        paired_scales,
    );

    const scale_stride = q8ActivationScaleCount(in_f, group_size);
    var q_inputs: [max_batch * max_in_f]i8 = undefined;
    var activation_scales: [max_batch * (max_in_f / 16)]f32 = undefined;
    // M5/M6/M7 prove one M4 block plus each exact M1--M3 tail; M8 proves two
    // complete M4 blocks, and M9 proves that the schedule resumes at M1.
    for ([_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }) |batch| {
        try quantizeQ8ActivationBatch(
            inputs[0 .. batch * in_f],
            batch,
            in_f,
            group_size,
            q_inputs[0 .. batch * in_f],
            activation_scales[0 .. batch * scale_stride],
        );
        var expected_gate = try tensor.zerosF32(
            testing.allocator,
            &.{ batch, out_f },
        );
        defer expected_gate.deinit();
        var expected_up = try tensor.zerosF32(
            testing.allocator,
            &.{ batch, out_f },
        );
        defer expected_up.deinit();
        var actual_gate = try tensor.zerosF32(
            testing.allocator,
            &.{ batch, out_f },
        );
        defer actual_gate.deinit();
        var actual_up = try tensor.zerosF32(
            testing.allocator,
            &.{ batch, out_f },
        );
        defer actual_up.deinit();

        try linearInt4WeightQ8PreparedBatch(
            q_inputs[0 .. batch * in_f],
            activation_scales[0 .. batch * scale_stride],
            gate_weights,
            &gate_bias,
            expected_gate,
            out_f,
            in_f,
        );
        try linearInt4WeightQ8PreparedBatch(
            q_inputs[0 .. batch * in_f],
            activation_scales[0 .. batch * scale_stride],
            up_weights,
            &up_bias,
            expected_up,
            out_f,
            in_f,
        );
        if (batch == 1) {
            try linearPairNibbleQ8Prepared(
                q_inputs[0..in_f],
                activation_scales[0..scale_stride],
                pair,
                &gate_bias,
                &up_bias,
                actual_gate,
                actual_up,
                out_f,
                in_f,
            );
        } else {
            try linearPairNibbleQ8PreparedBatch(
                q_inputs[0 .. batch * in_f],
                activation_scales[0 .. batch * scale_stride],
                pair,
                &gate_bias,
                &up_bias,
                actual_gate,
                actual_up,
                out_f,
                in_f,
            );
        }
        try expectPairNibbleF32Bits(expected_gate.asF32(), actual_gate.asF32());
        try expectPairNibbleF32Bits(expected_up.asF32(), actual_up.asF32());

        if (check_validation and batch == 7) {
            const output_stride = out_f + 5;
            const strided_count = batch * output_stride;
            const strided_gate = try testing.allocator.alloc(f32, strided_count);
            defer testing.allocator.free(strided_gate);
            const strided_up = try testing.allocator.alloc(f32, strided_count);
            defer testing.allocator.free(strided_up);
            @memset(strided_gate, -91.0);
            @memset(strided_up, -93.0);
            try linearPairNibbleQ8PreparedBatchStrided(
                q_inputs[0 .. batch * in_f],
                activation_scales[0 .. batch * scale_stride],
                pair,
                &gate_bias,
                &up_bias,
                strided_gate,
                strided_up,
                batch,
                out_f,
                in_f,
                output_stride,
            );
            for (0..batch) |row| {
                try expectPairNibbleF32Bits(
                    expected_gate.asF32()[row * out_f ..][0..out_f],
                    strided_gate[row * output_stride ..][0..out_f],
                );
                try expectPairNibbleF32Bits(
                    expected_up.asF32()[row * out_f ..][0..out_f],
                    strided_up[row * output_stride ..][0..out_f],
                );
                for (strided_gate[row * output_stride + out_f ..][0 .. output_stride - out_f]) |value|
                    try testing.expectEqual(@as(f32, -91.0), value);
                for (strided_up[row * output_stride + out_f ..][0 .. output_stride - out_f]) |value|
                    try testing.expectEqual(@as(f32, -93.0), value);
            }

            var parallel_gate = try tensor.zerosF32(
                testing.allocator,
                &.{ batch, out_f },
            );
            defer parallel_gate.deinit();
            var parallel_up = try tensor.zerosF32(
                testing.allocator,
                &.{ batch, out_f },
            );
            defer parallel_up.deinit();
            var pool: std.Thread.Pool = undefined;
            try pool.init(.{ .allocator = testing.allocator, .n_jobs = 3 });
            defer pool.deinit();
            try linearPairNibbleQ8PreparedBatchParallel(
                &pool,
                q_inputs[0 .. batch * in_f],
                activation_scales[0 .. batch * scale_stride],
                pair,
                &gate_bias,
                &up_bias,
                parallel_gate,
                parallel_up,
                out_f,
                in_f,
                4,
            );
            try expectPairNibbleF32Bits(
                expected_gate.asF32(),
                parallel_gate.asF32(),
            );
            try expectPairNibbleF32Bits(
                expected_up.asF32(),
                parallel_up.asF32(),
            );
        }
    }

    if (!check_validation) return;
    // Keep malformed-input coverage on one representative K per group size
    // instead of repeating allocator-heavy sentinel setup across the matrix.
    try quantizeQ8ActivationBatch(
        inputs[0..in_f],
        1,
        in_f,
        group_size,
        q_inputs[0..in_f],
        activation_scales[0..scale_stride],
    );
    var sentinel = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer sentinel.deinit();
    @memset(sentinel.asF32(), 73.0);
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleQ8Prepared(
            q_inputs[0..in_f],
            activation_scales[0..scale_stride],
            pair,
            &gate_bias,
            &up_bias,
            sentinel,
            sentinel,
            out_f,
            in_f,
        ),
    );
    for (sentinel.asF32()) |value|
        try testing.expectEqual(@as(f32, 73.0), value);
    var truncated = pair;
    truncated.paired_bytes = truncated.paired_bytes[0 .. truncated.paired_bytes.len - 1];
    var other = try tensor.zerosF32(testing.allocator, &.{ 1, out_f });
    defer other.deinit();
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleQ8Prepared(
            q_inputs[0..in_f],
            activation_scales[0..scale_stride],
            truncated,
            &gate_bias,
            &up_bias,
            sentinel,
            other,
            out_f,
            in_f,
        ),
    );
    for (sentinel.asF32()) |value|
        try testing.expectEqual(@as(f32, 73.0), value);
    var truncated_scales = pair;
    truncated_scales.scales_f16_pairs = truncated_scales.scales_f16_pairs[0 .. truncated_scales.scales_f16_pairs.len - 1];
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleQ8Prepared(
            q_inputs[0..in_f],
            activation_scales[0..scale_stride],
            truncated_scales,
            &gate_bias,
            &up_bias,
            sentinel,
            other,
            out_f,
            in_f,
        ),
    );
    for (sentinel.asF32()) |value|
        try testing.expectEqual(@as(f32, 73.0), value);

    const recipe = try PreparedPairNibbleQ8Plan.init(
        pair,
        &gate_bias,
        &up_bias,
        sentinel.asF32(),
        other.asF32(),
        1,
        out_f,
    );
    const aliased_q: []const i8 = @as(
        [*]const i8,
        @ptrCast(pair.paired_bytes.ptr),
    )[0..in_f];
    try testing.expectError(
        TensorError.ShapeMismatch,
        recipe.bind(aliased_q, activation_scales[0..scale_stride]),
    );
    const bound = try recipe.bind(
        q_inputs[0..in_f],
        activation_scales[0..scale_stride],
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        bound.runRows(2, 6),
    );
    for (sentinel.asF32()) |value|
        try testing.expectEqual(@as(f32, 73.0), value);
}

test "PairNibble arbitrary batch is bit-identical across g8 g16 and K tails" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    // This guard makes the oracle's signed-zero contract explicit: unlike f32
    // value equality, byte equality below must distinguish +0.0 from -0.0.
    const positive_zero = [_]f32{@bitCast(@as(u32, 0x0000_0000))};
    const negative_zero = [_]f32{@bitCast(@as(u32, 0x8000_0000))};
    try testing.expect(!std.mem.eql(
        u8,
        std.mem.sliceAsBytes(&positive_zero),
        std.mem.sliceAsBytes(&negative_zero),
    ));

    // K16 covers the shortest legal shape, K64 the phase body, K80 its K16
    // tail, and K128 two complete bodies. Every case covers M1..M9, including
    // two M4 blocks and every M1--M3 tail.
    for ([_]usize{ 8, 16 }) |group_size| {
        for ([_]usize{ 16, 64, 80, 128 }) |in_f| {
            try runPairNibbleDifferentialCase(
                in_f,
                group_size,
                in_f == 80,
            );
        }
    }
}

test "compact Pair batch ledger is exact and rejects malformed topology" {
    const g8 = try derivePairNibbleSiluQ8CompactBatchLedger(
        5,
        80,
        68,
        8,
        8,
        32,
        4,
        2,
    );
    try testing.expectEqual(@as(usize, 400), g8.input_count);
    try testing.expectEqual(@as(usize, 400), g8.producer_q_count);
    try testing.expectEqual(@as(usize, 3), g8.producer_scale_stride);
    try testing.expectEqual(@as(usize, 15), g8.producer_scale_count);
    try testing.expectEqual(@as(usize, 340), g8.q_output_count);
    try testing.expectEqual(@as(usize, 3), g8.output_scale_stride);
    try testing.expectEqual(@as(usize, 15), g8.output_scale_count);
    try testing.expectEqual(@as(usize, 160), g8.tile_slot_stride);
    try testing.expectEqual(@as(usize, 640), g8.tile_scratch_count_per_branch);
    try testing.expectEqual(@as(usize, 3), g8.shard_count);
    try testing.expectEqual(@as(usize, 2), g8.task_count);

    const g16 = try derivePairNibbleSiluQ8CompactBatchLedger(
        5,
        80,
        68,
        16,
        16,
        64,
        8,
        99,
    );
    try testing.expectEqual(@as(usize, 5), g16.producer_scale_stride);
    try testing.expectEqual(@as(usize, 5), g16.output_scale_stride);
    try testing.expectEqual(@as(usize, 2), g16.shard_count);
    try testing.expectEqual(@as(usize, 2), g16.task_count);
    try testing.expectEqual(@as(usize, 320), g16.tile_slot_stride);
    try testing.expectEqual(@as(usize, 2560), g16.tile_scratch_count_per_branch);

    const invalid = [_]struct {
        batch: usize = 1,
        in_f: usize = 80,
        out_f: usize = 68,
        producer_group_size: u32 = 8,
        down_group_size: u32 = 16,
        tile_rows: usize = 32,
        task_slots: usize = 1,
        max_tasks: usize = 1,
    }{
        .{ .batch = 0 },
        .{ .in_f = 79 },
        .{ .out_f = 67 },
        .{ .producer_group_size = 7 },
        .{ .down_group_size = 32 },
        .{ .tile_rows = 0 },
        .{ .tile_rows = 16 },
        .{ .task_slots = 0 },
        .{ .max_tasks = 0 },
        .{ .batch = std.math.maxInt(usize) },
    };
    for (invalid) |case| {
        try testing.expectError(
            TensorError.ShapeMismatch,
            derivePairNibbleSiluQ8CompactBatchLedger(
                case.batch,
                case.in_f,
                case.out_f,
                case.producer_group_size,
                case.down_group_size,
                case.tile_rows,
                case.task_slots,
                case.max_tasks,
            ),
        );
    }
}

fn expectCompactPairSentinels(
    producer_q: []const i8,
    producer_scales: []const f32,
    q_output: []const i8,
    output_scales: []const f32,
    gate_tiles: []const f32,
    up_tiles: []const f32,
) !void {
    for (producer_q) |value| try testing.expectEqual(@as(i8, 37), value);
    for (producer_scales) |value|
        try testing.expectEqual(@as(f32, 41.0), value);
    for (q_output) |value| try testing.expectEqual(@as(i8, -43), value);
    for (output_scales) |value|
        try testing.expectEqual(@as(f32, 47.0), value);
    for (gate_tiles) |value|
        try testing.expectEqual(@as(f32, 53.0), value);
    for (up_tiles) |value|
        try testing.expectEqual(@as(f32, 59.0), value);
}

fn runCompactPairBatchDifferentialCase(
    producer_group_size: u32,
    down_group_size: u32,
    check_validation: bool,
) !void {
    const in_f: usize = 80; // K64 body plus K16 tail.
    const out_f: usize = 68; // Final 4-row hidden/down-group tail.
    const max_batch: usize = 17;
    const element_count = in_f * out_f;
    var gate_source: [element_count]f32 = undefined;
    var up_source: [element_count]f32 = undefined;
    var inputs: [max_batch * in_f]f32 = undefined;
    var gate_bias: [out_f]f32 = undefined;
    var up_bias: [out_f]f32 = undefined;
    for (&gate_source, 0..) |*value, index| {
        value.* = (@as(
            f32,
            @floatFromInt((index * 29 + producer_group_size + 3) % 71),
        ) - 35) / 43.0;
    }
    for (&up_source, 0..) |*value, index| {
        value.* = (@as(
            f32,
            @floatFromInt((index * 31 + down_group_size + 5) % 73),
        ) - 36) / 47.0;
    }
    for (&inputs, 0..) |*value, index| {
        value.* = (@as(f32, @floatFromInt((index * 17 + 7) % 61)) - 30) /
            37.0;
    }
    for (&gate_bias, &up_bias, 0..) |*gate, *up, index| {
        gate.* = (@as(f32, @floatFromInt(index % 19)) - 9) / 139.0;
        up.* = (@as(f32, @floatFromInt(index % 23)) - 11) / 149.0;
    }

    const gate_quant = try quant.quantize(
        f32,
        testing.allocator,
        &gate_source,
        .int4,
        @intCast(producer_group_size),
    );
    defer {
        testing.allocator.free(gate_quant.packed_bytes);
        testing.allocator.free(gate_quant.scales);
    }
    const up_quant = try quant.quantize(
        f32,
        testing.allocator,
        &up_source,
        .int4,
        @intCast(producer_group_size),
    );
    defer {
        testing.allocator.free(up_quant.packed_bytes);
        testing.allocator.free(up_quant.scales);
    }
    const gate_base: int4_weights.Int4WeightData = .{
        .packed_bytes = gate_quant.packed_bytes,
        .scales = gate_quant.scales,
        .group_size = producer_group_size,
        .num_elements = element_count,
    };
    const up_base: int4_weights.Int4WeightData = .{
        .packed_bytes = up_quant.packed_bytes,
        .scales = up_quant.scales,
        .group_size = producer_group_size,
        .num_elements = element_count,
    };
    const gate_scaled = try int4_weights.withRows4F16Scales(
        testing.allocator,
        gate_base,
        out_f,
    );
    defer testing.allocator.free(gate_scaled.scales_f16_rows4);
    const up_scaled = try int4_weights.withRows4F16Scales(
        testing.allocator,
        up_base,
        out_f,
    );
    defer testing.allocator.free(up_scaled.scales_f16_rows4);
    const gate_bytes = try testing.allocator.dupe(u8, gate_quant.packed_bytes);
    defer testing.allocator.free(gate_bytes);
    const up_bytes = try testing.allocator.dupe(u8, up_quant.packed_bytes);
    defer testing.allocator.free(up_bytes);
    var gate_packable = gate_scaled;
    gate_packable.packed_bytes = gate_bytes;
    var up_packable = up_scaled;
    up_packable.packed_bytes = up_bytes;
    const gate_weights = try int4_weights.withRows4K16Packing(
        testing.allocator,
        gate_packable,
        out_f,
    );
    const up_weights = try int4_weights.withRows4K16Packing(
        testing.allocator,
        up_packable,
        out_f,
    );
    const paired_bytes = try testing.allocator.alloc(u8, element_count);
    defer testing.allocator.free(paired_bytes);
    const paired_scales = try testing.allocator.alloc(
        f16,
        2 * element_count / producer_group_size,
    );
    defer testing.allocator.free(paired_scales);
    const pair = try int4_weights.pairRows4K16(
        gate_weights,
        up_weights,
        out_f,
        paired_bytes,
        paired_scales,
    );

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = testing.allocator, .n_jobs = 4 });
    defer pool.deinit();
    const topologies = [_]struct {
        tile_rows: usize,
        task_slots: usize,
        max_tasks: usize,
    }{
        .{ .tile_rows = 32, .task_slots = 1, .max_tasks = 1 },
        .{ .tile_rows = 32, .task_slots = 8, .max_tasks = 3 },
        .{ .tile_rows = 64, .task_slots = 4, .max_tasks = 16 },
        .{ .tile_rows = 96, .task_slots = 7, .max_tasks = 2 },
    };
    const batches = [_]usize{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 17 };
    for (batches, 0..) |batch, batch_index| {
        const topology = topologies[batch_index % topologies.len];
        const ledger = try derivePairNibbleSiluQ8CompactBatchLedger(
            batch,
            in_f,
            out_f,
            producer_group_size,
            down_group_size,
            topology.tile_rows,
            topology.task_slots,
            topology.max_tasks,
        );
        var x = try tensor.fromF32(
            testing.allocator,
            &.{ batch, in_f },
            inputs[0..ledger.input_count],
        );
        defer x.deinit();
        var materialized_gate = try tensor.zerosF32(
            testing.allocator,
            &.{ batch, out_f },
        );
        defer materialized_gate.deinit();
        var materialized_up = try tensor.zerosF32(
            testing.allocator,
            &.{ batch, out_f },
        );
        defer materialized_up.deinit();
        const oracle_producer_q = try testing.allocator.alloc(
            i8,
            ledger.producer_q_count,
        );
        defer testing.allocator.free(oracle_producer_q);
        const oracle_producer_scales = try testing.allocator.alloc(
            f32,
            ledger.producer_scale_count,
        );
        defer testing.allocator.free(oracle_producer_scales);
        try linearPairNibbleWeightBatchQ8Parallel(
            &pool,
            x,
            pair,
            &gate_bias,
            &up_bias,
            materialized_gate,
            materialized_up,
            out_f,
            in_f,
            oracle_producer_q,
            oracle_producer_scales,
            topology.max_tasks,
        );
        const expected_q = try testing.allocator.alloc(i8, ledger.q_output_count);
        defer testing.allocator.free(expected_q);
        const expected_scales = try testing.allocator.alloc(
            f32,
            ledger.output_scale_count,
        );
        defer testing.allocator.free(expected_scales);
        for (0..batch) |batch_row| {
            try kernels.siluMulQuantizeQ8Slices(
                materialized_gate.asF32()[batch_row * out_f ..][0..out_f],
                materialized_up.asF32()[batch_row * out_f ..][0..out_f],
                down_group_size,
                expected_q[batch_row * out_f ..][0..out_f],
                expected_scales[batch_row * ledger.output_scale_stride ..][0..ledger.output_scale_stride],
            );
        }

        const actual_producer_q = try testing.allocator.alloc(
            i8,
            ledger.producer_q_count,
        );
        defer testing.allocator.free(actual_producer_q);
        const actual_producer_scales = try testing.allocator.alloc(
            f32,
            ledger.producer_scale_count,
        );
        defer testing.allocator.free(actual_producer_scales);
        const actual_q = try testing.allocator.alloc(i8, ledger.q_output_count);
        defer testing.allocator.free(actual_q);
        const actual_scales = try testing.allocator.alloc(
            f32,
            ledger.output_scale_count,
        );
        defer testing.allocator.free(actual_scales);
        const gate_tiles = try testing.allocator.alignedAlloc(
            f32,
            .@"64",
            ledger.tile_scratch_count_per_branch,
        );
        defer testing.allocator.free(gate_tiles);
        const up_tiles = try testing.allocator.alignedAlloc(
            f32,
            .@"64",
            ledger.tile_scratch_count_per_branch,
        );
        defer testing.allocator.free(up_tiles);
        @memset(actual_producer_q, 17);
        @memset(actual_producer_scales, -19.0);
        @memset(actual_q, -23);
        @memset(actual_scales, -29.0);
        @memset(gate_tiles, -31.0);
        @memset(up_tiles, -37.0);
        try linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            x.asF32(),
            batch,
            pair,
            &gate_bias,
            &up_bias,
            actual_producer_q,
            actual_producer_scales,
            actual_q,
            actual_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            topology.tile_rows,
            topology.task_slots,
            topology.max_tasks,
        );
        try testing.expectEqualSlices(
            i8,
            oracle_producer_q,
            actual_producer_q,
        );
        try expectPairNibbleF32Bits(
            oracle_producer_scales,
            actual_producer_scales,
        );
        try testing.expectEqualSlices(i8, expected_q, actual_q);
        try expectPairNibbleF32Bits(expected_scales, actual_scales);
    }

    if (!check_validation) return;
    const batch: usize = 3;
    const ledger = try derivePairNibbleSiluQ8CompactBatchLedger(
        batch,
        in_f,
        out_f,
        producer_group_size,
        down_group_size,
        32,
        2,
        2,
    );
    const input = inputs[0..ledger.input_count];
    const input_before = try testing.allocator.dupe(f32, input);
    defer testing.allocator.free(input_before);
    const producer_q = try testing.allocator.alloc(i8, ledger.producer_q_count);
    defer testing.allocator.free(producer_q);
    const producer_scales = try testing.allocator.alloc(
        f32,
        ledger.producer_scale_count,
    );
    defer testing.allocator.free(producer_scales);
    const q_output = try testing.allocator.alloc(i8, ledger.q_output_count);
    defer testing.allocator.free(q_output);
    const output_scales = try testing.allocator.alloc(
        f32,
        ledger.output_scale_count,
    );
    defer testing.allocator.free(output_scales);
    const gate_tiles_backing = try testing.allocator.alignedAlloc(
        f32,
        .@"64",
        ledger.tile_scratch_count_per_branch + 1,
    );
    defer testing.allocator.free(gate_tiles_backing);
    const gate_tiles = gate_tiles_backing[0..ledger.tile_scratch_count_per_branch];
    const up_tiles = try testing.allocator.alignedAlloc(
        f32,
        .@"64",
        ledger.tile_scratch_count_per_branch,
    );
    defer testing.allocator.free(up_tiles);
    @memset(producer_q, 37);
    @memset(producer_scales, 41.0);
    @memset(q_output, -43);
    @memset(output_scales, 47.0);
    @memset(gate_tiles_backing, 53.0);
    @memset(up_tiles, 59.0);

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input[0 .. input.len - 1],
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            q_output,
            output_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    const input_q_alias: []i8 = @as(
        [*]i8,
        @ptrCast(@constCast(input.ptr)),
    )[0..ledger.q_output_count];
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            input_q_alias,
            output_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try testing.expectEqualSlices(f32, input_before, input);
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            q_output[0 .. q_output.len - 1],
            output_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            q_output,
            output_scales,
            gate_tiles[0 .. gate_tiles.len - 1],
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            q_output,
            output_scales,
            gate_tiles,
            gate_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            q_output,
            output_scales,
            gate_tiles_backing[1..],
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            producer_q[0..ledger.q_output_count],
            output_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            gate_tiles[0..ledger.producer_scale_count],
            q_output,
            output_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    const gate_bias_before = gate_bias;
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            q_output,
            gate_bias[0..ledger.output_scale_count],
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try testing.expectEqualSlices(f32, &gate_bias_before, &gate_bias);
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    const paired_before = try testing.allocator.dupe(u8, paired_bytes);
    defer testing.allocator.free(paired_before);
    const paired_q_alias: []i8 = @as(
        [*]i8,
        @ptrCast(paired_bytes.ptr),
    )[0..ledger.q_output_count];
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            pair,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            paired_q_alias,
            output_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try testing.expectEqualSlices(u8, paired_before, paired_bytes);
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    var truncated = pair;
    truncated.scales_f16_pairs =
        truncated.scales_f16_pairs[0 .. truncated.scales_f16_pairs.len - 1];
    try testing.expectError(
        TensorError.ShapeMismatch,
        linearPairNibbleSiluQ8CompactBatchParallel(
            &pool,
            input,
            batch,
            truncated,
            &gate_bias,
            &up_bias,
            producer_q,
            producer_scales,
            q_output,
            output_scales,
            gate_tiles,
            up_tiles,
            down_group_size,
            32,
            2,
            2,
        ),
    );
    try expectCompactPairSentinels(
        producer_q,
        producer_scales,
        q_output,
        output_scales,
        gate_tiles,
        up_tiles,
    );

    for ([_]struct {
        down_group_size: u32,
        tile_rows: usize,
        task_slots: usize,
        max_tasks: usize,
    }{
        .{
            .down_group_size = 7,
            .tile_rows = 32,
            .task_slots = 2,
            .max_tasks = 2,
        },
        .{
            .down_group_size = down_group_size,
            .tile_rows = 16,
            .task_slots = 2,
            .max_tasks = 2,
        },
        .{
            .down_group_size = down_group_size,
            .tile_rows = 32,
            .task_slots = 0,
            .max_tasks = 2,
        },
        .{
            .down_group_size = down_group_size,
            .tile_rows = 32,
            .task_slots = 2,
            .max_tasks = 0,
        },
    }) |malformed| {
        try testing.expectError(
            TensorError.ShapeMismatch,
            linearPairNibbleSiluQ8CompactBatchParallel(
                &pool,
                input,
                batch,
                pair,
                &gate_bias,
                &up_bias,
                producer_q,
                producer_scales,
                q_output,
                output_scales,
                gate_tiles,
                up_tiles,
                malformed.down_group_size,
                malformed.tile_rows,
                malformed.task_slots,
                malformed.max_tasks,
            ),
        );
        try expectCompactPairSentinels(
            producer_q,
            producer_scales,
            q_output,
            output_scales,
            gate_tiles,
            up_tiles,
        );
    }
    try testing.expectEqualSlices(f32, input_before, input);
}

test "compact Pair batch producer is exact for M1-M9 arbitrary M and tails" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    for ([_]u32{ 8, 16 }) |producer_group_size| {
        for ([_]u32{ 8, 16 }) |down_group_size| {
            try runCompactPairBatchDifferentialCase(
                producer_group_size,
                down_group_size,
                producer_group_size == 16 and down_group_size == 8,
            );
        }
    }
}

test "compact Pair down wave is bit-exact and rejects cross-edge aliases before writes" {
    if (comptime builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const batch: usize = 4;
    const in_f: usize = 32;
    const hidden: usize = 64;
    const out_f: usize = 32;
    const tile_rows: usize = 32;
    const task_slots: usize = 4;
    const max_tasks: usize = 4;
    const pair_elements = hidden * in_f;
    const down_elements = out_f * hidden;

    var input: [batch * in_f]f32 = undefined;
    for (&input, 0..) |*value, index|
        value.* = (@as(f32, @floatFromInt((index * 13 + 5) % 43)) - 21) /
            29.0;
    const pair_bytes = [_]u8{0x93} ** pair_elements;
    const down_bytes = [_]u8{0x6a} ** (down_elements / 2);
    var pair_scales: [2 * pair_elements / 8]f16 =
        [_]f16{@as(f16, 0.125)} ** (2 * pair_elements / 8);
    var down_scales: [down_elements / 8]f16 =
        [_]f16{@as(f16, 0.0625)} ** (down_elements / 8);

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = testing.allocator, .n_jobs = 3 });
    defer pool.deinit();

    for ([_]u32{ 8, 16 }) |producer_group_size| {
        for ([_]u32{ 8, 16 }) |down_group_size| {
            const pair_scale_count = 2 * pair_elements / producer_group_size;
            const down_scale_count = down_elements / down_group_size;
            const pair: int4_weights.PairNibbleWeightData = .{
                .paired_bytes = &pair_bytes,
                .scales_f16_pairs = pair_scales[0..pair_scale_count],
                .group_size = producer_group_size,
                .out_f = hidden,
                .in_f = in_f,
                .num_elements_per_branch = pair_elements,
                .geometry_commitment = try int4_weights.pairNibbleGeometryCommitment(
                    .gate_low_up_high_rows4_k16,
                    hidden,
                    in_f,
                    producer_group_size,
                ),
            };
            const down_weights: int4_weights.Int4WeightData = .{
                .packed_bytes = &down_bytes,
                .scales = &.{},
                .scales_f16_rows4 = down_scales[0..down_scale_count],
                .group_size = down_group_size,
                .num_elements = down_elements,
                .packed_layout = .rows4_k16,
            };
            const ledger = try derivePairNibbleSiluQ8CompactBatchLedger(
                batch,
                in_f,
                hidden,
                producer_group_size,
                down_group_size,
                tile_rows,
                task_slots,
                max_tasks,
            );

            var split_producer_q: [batch * in_f]i8 = undefined;
            var split_producer_scales: [batch * 2]f32 = undefined;
            var split_q: [batch * hidden]i8 = undefined;
            var split_scales: [batch * 4]f32 = undefined;
            var split_gate_tiles: [task_slots * batch * tile_rows]f32 align(64) =
                undefined;
            var split_up_tiles: [task_slots * batch * tile_rows]f32 align(64) =
                undefined;
            var split_output: [batch * out_f]f32 = undefined;
            var split_shape = [2]usize{ batch, out_f };
            const split_tensor: Tensor = .{
                .dtype = .f32,
                .shape = &split_shape,
                .data = std.mem.sliceAsBytes(&split_output),
                .allocator = std.heap.page_allocator,
            };
            try linearPairNibbleSiluQ8CompactBatchParallel(
                &pool,
                &input,
                batch,
                pair,
                &.{},
                &.{},
                split_producer_q[0..ledger.producer_q_count],
                split_producer_scales[0..ledger.producer_scale_count],
                split_q[0..ledger.q_output_count],
                split_scales[0..ledger.output_scale_count],
                split_gate_tiles[0..ledger.tile_scratch_count_per_branch],
                split_up_tiles[0..ledger.tile_scratch_count_per_branch],
                down_group_size,
                tile_rows,
                task_slots,
                max_tasks,
            );
            try linearInt4WeightQ8PreparedBatchParallel(
                &pool,
                split_q[0..ledger.q_output_count],
                split_scales[0..ledger.output_scale_count],
                down_weights,
                &.{},
                split_tensor,
                out_f,
                hidden,
                max_tasks,
            );

            var wave_producer_q: [batch * in_f]i8 = undefined;
            var wave_producer_scales: [batch * 2]f32 = undefined;
            var wave_q: [batch * hidden]i8 = undefined;
            var wave_scales: [batch * 4]f32 = undefined;
            var wave_gate_tiles: [task_slots * batch * tile_rows]f32 align(64) =
                undefined;
            var wave_up_tiles: [task_slots * batch * tile_rows]f32 align(64) =
                undefined;
            var wave_output: [batch * out_f]f32 = undefined;
            var wave_shape = [2]usize{ batch, out_f };
            const wave_tensor: Tensor = .{
                .dtype = .f32,
                .shape = &wave_shape,
                .data = std.mem.sliceAsBytes(&wave_output),
                .allocator = std.heap.page_allocator,
            };
            const receipt = try linearPairNibbleSiluQ8CompactBatchDownWave(
                &pool,
                &input,
                batch,
                pair,
                &.{},
                &.{},
                wave_producer_q[0..ledger.producer_q_count],
                wave_producer_scales[0..ledger.producer_scale_count],
                wave_q[0..ledger.q_output_count],
                wave_scales[0..ledger.output_scale_count],
                wave_gate_tiles[0..ledger.tile_scratch_count_per_branch],
                wave_up_tiles[0..ledger.tile_scratch_count_per_branch],
                .{
                    .weights = down_weights,
                    .bias = &.{},
                    .out = wave_tensor,
                    .out_f = out_f,
                    .in_f = hidden,
                },
                tile_rows,
                task_slots,
                max_tasks,
            );
            try testing.expectEqual(
                pair_nibble_silu_q8_down_wave_abi,
                receipt.abi_version,
            );
            try testing.expectEqual(@as(usize, 4), receipt.participants);
            try testing.expectEqual(@as(usize, 1), receipt.worker_epochs);
            try testing.expectEqual(@as(usize, 2), receipt.split_worker_epochs);
            try testing.expectEqual(@as(usize, 1), receipt.worker_joins_elided);
            try testing.expectEqual(@as(usize, 3), receipt.background_enqueues);
            try testing.expectEqualSlices(i8, &split_producer_q, &wave_producer_q);
            try testing.expectEqualSlices(
                f32,
                split_producer_scales[0..ledger.producer_scale_count],
                wave_producer_scales[0..ledger.producer_scale_count],
            );
            try testing.expectEqualSlices(i8, &split_q, &wave_q);
            try testing.expectEqualSlices(
                f32,
                split_scales[0..ledger.output_scale_count],
                wave_scales[0..ledger.output_scale_count],
            );
            try testing.expectEqualSlices(f32, &split_output, &wave_output);

            if (producer_group_size == 16 and down_group_size == 16) {
                var aliased_q_and_output: [batch * out_f * @sizeOf(f32)]i8 align(64) =
                    [_]i8{71} ** (batch * out_f * @sizeOf(f32));
                var alias_shape = [2]usize{ batch, out_f };
                const alias_tensor: Tensor = .{
                    .dtype = .f32,
                    .shape = &alias_shape,
                    .data = std.mem.sliceAsBytes(&aliased_q_and_output),
                    .allocator = std.heap.page_allocator,
                };
                @memset(wave_producer_q[0..ledger.producer_q_count], 73);
                @memset(
                    wave_producer_scales[0..ledger.producer_scale_count],
                    79.0,
                );
                try testing.expectError(
                    TensorError.ShapeMismatch,
                    linearPairNibbleSiluQ8CompactBatchDownWave(
                        &pool,
                        &input,
                        batch,
                        pair,
                        &.{},
                        &.{},
                        wave_producer_q[0..ledger.producer_q_count],
                        wave_producer_scales[0..ledger.producer_scale_count],
                        aliased_q_and_output[0..ledger.q_output_count],
                        wave_scales[0..ledger.output_scale_count],
                        wave_gate_tiles[0..ledger.tile_scratch_count_per_branch],
                        wave_up_tiles[0..ledger.tile_scratch_count_per_branch],
                        .{
                            .weights = down_weights,
                            .bias = &.{},
                            .out = alias_tensor,
                            .out_f = out_f,
                            .in_f = hidden,
                        },
                        tile_rows,
                        task_slots,
                        max_tasks,
                    ),
                );
                for (aliased_q_and_output) |value|
                    try testing.expectEqual(@as(i8, 71), value);
                for (wave_producer_q[0..ledger.producer_q_count]) |value|
                    try testing.expectEqual(@as(i8, 73), value);
                for (wave_producer_scales[0..ledger.producer_scale_count]) |value|
                    try testing.expectEqual(@as(f32, 79.0), value);

                var oversized_output: [(batch + 1) * out_f]f32 =
                    [_]f32{113.0} ** ((batch + 1) * out_f);
                var oversized_shape = [2]usize{ batch + 1, out_f };
                const oversized_tensor: Tensor = .{
                    .dtype = .f32,
                    .shape = &oversized_shape,
                    .data = std.mem.sliceAsBytes(&oversized_output),
                    .allocator = std.heap.page_allocator,
                };
                @memset(wave_producer_q[0..ledger.producer_q_count], 127);
                @memset(
                    wave_producer_scales[0..ledger.producer_scale_count],
                    131.0,
                );
                @memset(wave_q[0..ledger.q_output_count], -127);
                @memset(wave_scales[0..ledger.output_scale_count], 137.0);
                try testing.expectError(
                    TensorError.ShapeMismatch,
                    linearPairNibbleSiluQ8CompactBatchDownWave(
                        &pool,
                        &input,
                        batch,
                        pair,
                        &.{},
                        &.{},
                        wave_producer_q[0..ledger.producer_q_count],
                        wave_producer_scales[0..ledger.producer_scale_count],
                        wave_q[0..ledger.q_output_count],
                        wave_scales[0..ledger.output_scale_count],
                        wave_gate_tiles[0..ledger.tile_scratch_count_per_branch],
                        wave_up_tiles[0..ledger.tile_scratch_count_per_branch],
                        .{
                            .weights = down_weights,
                            .bias = &.{},
                            .out = oversized_tensor,
                            .out_f = out_f,
                            .in_f = hidden,
                        },
                        tile_rows,
                        task_slots,
                        max_tasks,
                    ),
                );
                for (oversized_output) |value|
                    try testing.expectEqual(@as(f32, 113.0), value);
                for (wave_producer_q[0..ledger.producer_q_count]) |value|
                    try testing.expectEqual(@as(i8, 127), value);
                for (wave_producer_scales[0..ledger.producer_scale_count]) |value|
                    try testing.expectEqual(@as(f32, 131.0), value);
                for (wave_q[0..ledger.q_output_count]) |value|
                    try testing.expectEqual(@as(i8, -127), value);
                for (wave_scales[0..ledger.output_scale_count]) |value|
                    try testing.expectEqual(@as(f32, 137.0), value);

                var failing_allocator = testing.FailingAllocator.init(
                    testing.allocator,
                    .{},
                );
                var failing_pool: std.Thread.Pool = undefined;
                try failing_pool.init(.{
                    .allocator = failing_allocator.allocator(),
                    .n_jobs = 3,
                });
                defer failing_pool.deinit();
                // Permit the first background closure, reject the second.
                failing_allocator.fail_index =
                    failing_allocator.alloc_index + 1;
                @memset(wave_producer_q[0..ledger.producer_q_count], 83);
                @memset(
                    wave_producer_scales[0..ledger.producer_scale_count],
                    89.0,
                );
                @memset(wave_q[0..ledger.q_output_count], -97);
                @memset(
                    wave_scales[0..ledger.output_scale_count],
                    101.0,
                );
                @memset(
                    wave_gate_tiles[0..ledger.tile_scratch_count_per_branch],
                    103.0,
                );
                @memset(
                    wave_up_tiles[0..ledger.tile_scratch_count_per_branch],
                    107.0,
                );
                @memset(&wave_output, 109.0);
                try testing.expectError(
                    TensorError.OutOfMemory,
                    linearPairNibbleSiluQ8CompactBatchDownWave(
                        &failing_pool,
                        &input,
                        batch,
                        pair,
                        &.{},
                        &.{},
                        wave_producer_q[0..ledger.producer_q_count],
                        wave_producer_scales[0..ledger.producer_scale_count],
                        wave_q[0..ledger.q_output_count],
                        wave_scales[0..ledger.output_scale_count],
                        wave_gate_tiles[0..ledger.tile_scratch_count_per_branch],
                        wave_up_tiles[0..ledger.tile_scratch_count_per_branch],
                        .{
                            .weights = down_weights,
                            .bias = &.{},
                            .out = wave_tensor,
                            .out_f = out_f,
                            .in_f = hidden,
                        },
                        tile_rows,
                        task_slots,
                        max_tasks,
                    ),
                );
                try testing.expect(failing_allocator.has_induced_failure);
                for (wave_producer_q[0..ledger.producer_q_count]) |value|
                    try testing.expectEqual(@as(i8, 83), value);
                for (wave_producer_scales[0..ledger.producer_scale_count]) |value|
                    try testing.expectEqual(@as(f32, 89.0), value);
                for (wave_q[0..ledger.q_output_count]) |value|
                    try testing.expectEqual(@as(i8, -97), value);
                for (wave_scales[0..ledger.output_scale_count]) |value|
                    try testing.expectEqual(@as(f32, 101.0), value);
                for (wave_gate_tiles[0..ledger.tile_scratch_count_per_branch]) |value|
                    try testing.expectEqual(@as(f32, 103.0), value);
                for (wave_up_tiles[0..ledger.tile_scratch_count_per_branch]) |value|
                    try testing.expectEqual(@as(f32, 107.0), value);
                for (wave_output) |value|
                    try testing.expectEqual(@as(f32, 109.0), value);

                // The aborted wave leaves the retained pool reusable.
                failing_allocator.fail_index = std.math.maxInt(usize);
                const retry_receipt = try linearPairNibbleSiluQ8CompactBatchDownWave(
                    &failing_pool,
                    &input,
                    batch,
                    pair,
                    &.{},
                    &.{},
                    wave_producer_q[0..ledger.producer_q_count],
                    wave_producer_scales[0..ledger.producer_scale_count],
                    wave_q[0..ledger.q_output_count],
                    wave_scales[0..ledger.output_scale_count],
                    wave_gate_tiles[0..ledger.tile_scratch_count_per_branch],
                    wave_up_tiles[0..ledger.tile_scratch_count_per_branch],
                    .{
                        .weights = down_weights,
                        .bias = &.{},
                        .out = wave_tensor,
                        .out_f = out_f,
                        .in_f = hidden,
                    },
                    tile_rows,
                    task_slots,
                    max_tasks,
                );
                try testing.expectEqual(@as(usize, 3), retry_receipt.background_enqueues);
                try testing.expectEqualSlices(f32, &split_output, &wave_output);
            }
        }
    }
}
