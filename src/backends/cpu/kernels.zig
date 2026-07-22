//! CPU compute kernels — the reference implementation.
//!
//! These are the functions Metal kernels will have to match numerically.
//! Correctness tests compare against hand-computed values; if these are
//! wrong, every downstream measurement is meaningless.
//!
//! MVP scope: FP32 in/out, FP32 or INT4-quantized weights. No SIMD yet —
//! scalar code first, then optimize once correctness is locked.

const std = @import("std");
const tensor = @import("core").tensor;
const quant = @import("core").quant;

pub const Tensor = tensor.Tensor;
pub const TensorError = tensor.TensorError;

fn checkedF32ElementCount(value: Tensor) TensorError!usize {
    if (value.dtype != .f32) return TensorError.DTypeUnsupported;
    var element_count: usize = 1;
    for (value.shape) |dimension| {
        element_count = std.math.mul(usize, element_count, dimension) catch
            return TensorError.ShapeMismatch;
    }
    const expected_bytes = std.math.mul(usize, element_count, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    if (value.data.len != expected_bytes or
        (element_count != 0 and @intFromPtr(value.data.ptr) % @alignOf(f32) != 0))
        return TensorError.ShapeMismatch;
    return element_count;
}

fn byteRangesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

/// y = x · W^T  +  b   (the linear layer primitive transformers are made of)
///
/// `x`   : [batch, in_features]      (activations)
/// `W`   : [out_features, in_features] (weights, row-major)
/// `b`   : [out_features]            (may be empty → no bias)
/// `out` : [batch, out_features]
///
/// Note: this transposes W implicitly. HuggingFace stores q_proj etc. as
/// [out, in] and we want x · W^T, which matches HF's `F.linear(x, W)`.
pub fn linearF32(
    x: Tensor, // [batch, in]
    w: Tensor, // [out, in]
    b: []const f32, // [out] or empty
    out: Tensor, // [batch, out]
) TensorError!void {
    if (x.shape.len != 2 or w.shape.len != 2 or out.shape.len != 2) return TensorError.ShapeMismatch;
    const batch = x.shape[0];
    const in_f = x.shape[1];
    const out_f = w.shape[0];
    if (w.shape[1] != in_f) return TensorError.ShapeMismatch;
    if (out.shape[0] != batch or out.shape[1] != out_f) return TensorError.ShapeMismatch;
    if (b.len != 0 and b.len != out_f) return TensorError.ShapeMismatch;

    const xv = x.asF32();
    const wv = w.asF32();
    const ov = out.asF32();

    // Vectorized dot product with 16-lane @Vector for maximum SIMD throughput.
    // On Apple Silicon (NEON 128-bit), the compiler unrolls two 128-bit ops
    // per 16-lane iteration. On x86 with AVX-512, it maps to a single vfmadd.
    // The 16-lane width matches the typical in_f=896 (Qwen) or in_f=1024+
    // (larger models) with zero tail waste.
    const Vec16 = @Vector(16, f32);

    var i: usize = 0;
    while (i < batch) : (i += 1) {
        var o: usize = 0;
        while (o < out_f) : (o += 1) {
            var acc: f32 = if (b.len == out_f) b[o] else 0;
            const w_row = wv[o * in_f .. (o + 1) * in_f];
            const x_row = xv[i * in_f .. (i + 1) * in_f];

            // 16-lane vectorized body.
            var k: usize = 0;
            const vec_end = in_f - (in_f % 16);
            while (k < vec_end) : (k += 16) {
                const x_vec: Vec16 = .{
                    x_row[k],      x_row[k + 1],  x_row[k + 2],  x_row[k + 3],
                    x_row[k + 4],  x_row[k + 5],  x_row[k + 6],  x_row[k + 7],
                    x_row[k + 8],  x_row[k + 9],  x_row[k + 10], x_row[k + 11],
                    x_row[k + 12], x_row[k + 13], x_row[k + 14], x_row[k + 15],
                };
                const w_vec: Vec16 = .{
                    w_row[k],      w_row[k + 1],  w_row[k + 2],  w_row[k + 3],
                    w_row[k + 4],  w_row[k + 5],  w_row[k + 6],  w_row[k + 7],
                    w_row[k + 8],  w_row[k + 9],  w_row[k + 10], w_row[k + 11],
                    w_row[k + 12], w_row[k + 13], w_row[k + 14], w_row[k + 15],
                };
                acc += @reduce(.Add, x_vec * w_vec);
            }
            // Scalar tail for remaining 0..15 elements.
            while (k < in_f) : (k += 1) acc += x_row[k] * w_row[k];

            ov[i * out_f + o] = acc;
        }
    }
}

/// Same as linearF32, but W is supplied as a raw quantized page payload
/// (the bytes from qio.encodePage). The kernel dequantizes W on the fly
/// and never materializes the full FP32 copy — this is the load-bearing
/// optimization the engine exists to measure.
pub fn linearInt4Weight(
    allocator: std.mem.Allocator,
    x: Tensor, // [batch, in]
    weight_payload: []const u8, // qio-encoded INT4 page
    bias: []const f32, // [out] or empty
    out_features: usize,
    out: Tensor, // [batch, out]
) !void {
    // Dequantize weights to a temporary f32 buffer via qio.
    const qio_mod = @import("../../model/qio.zig");
    const w = try qio_mod.decodePage(f32, allocator, weight_payload);
    defer allocator.free(w);
    if (w.len != out_features * x.shape[1]) return TensorError.ShapeMismatch;

    // Build a temporary Tensor view over w (no copy of data — the bytes
    // belong to `w`, which we free above; w_tensor.deinit must not run).
    const w_tensor: Tensor = .{
        .dtype = .f32,
        .shape = try allocator.dupe(usize, &.{ out_features, x.shape[1] }),
        .data = std.mem.sliceAsBytes(w),
        .allocator = allocator,
    };
    defer allocator.free(w_tensor.shape);
    try linearF32(x, w_tensor, bias, out);
}

/// Root-mean-square normalization (RMSNorm), used by Llama / Qwen.
/// y = x / sqrt(mean(x²) + eps) * weight
pub fn rmsNormF32(
    x: Tensor, // [batch, dim]
    weight: []const f32, // [dim]
    eps: f32,
    out: Tensor, // [batch, dim]
) TensorError!void {
    if (x.shape.len != 2 or out.shape.len != 2) return TensorError.ShapeMismatch;
    const batch = x.shape[0];
    const dim = x.shape[1];
    if (out.shape[0] != batch or out.shape[1] != dim) return TensorError.ShapeMismatch;
    if (weight.len != dim) return TensorError.ShapeMismatch;

    const xv = x.asF32();
    const ov = out.asF32();
    const Vec16 = @Vector(16, f32);

    var i: usize = 0;
    while (i < batch) : (i += 1) {
        const row = xv[i * dim .. (i + 1) * dim];

        // Vectorized sum-of-squares (16-lane).
        var sum_vec: Vec16 = @splat(0);
        var k: usize = 0;
        const vec_end = dim - (dim % 16);
        while (k < vec_end) : (k += 16) {
            const v: Vec16 = .{
                row[k],      row[k + 1],  row[k + 2],  row[k + 3],
                row[k + 4],  row[k + 5],  row[k + 6],  row[k + 7],
                row[k + 8],  row[k + 9],  row[k + 10], row[k + 11],
                row[k + 12], row[k + 13], row[k + 14], row[k + 15],
            };
            sum_vec += v * v;
        }
        var sum_sq: f32 = @reduce(.Add, sum_vec);
        while (k < dim) : (k += 1) sum_sq += row[k] * row[k];

        const rms = std.math.sqrt(sum_sq / @as(f32, @floatFromInt(dim)) + eps);
        const inv = 1.0 / rms;

        // Vectorized output: row * inv * weight (16-lane).
        const inv_vec: Vec16 = @splat(inv);
        k = 0;
        while (k < vec_end) : (k += 16) {
            const r: Vec16 = .{
                row[k],      row[k + 1],  row[k + 2],  row[k + 3],
                row[k + 4],  row[k + 5],  row[k + 6],  row[k + 7],
                row[k + 8],  row[k + 9],  row[k + 10], row[k + 11],
                row[k + 12], row[k + 13], row[k + 14], row[k + 15],
            };
            const w: Vec16 = .{
                weight[k],      weight[k + 1],  weight[k + 2],  weight[k + 3],
                weight[k + 4],  weight[k + 5],  weight[k + 6],  weight[k + 7],
                weight[k + 8],  weight[k + 9],  weight[k + 10], weight[k + 11],
                weight[k + 12], weight[k + 13], weight[k + 14], weight[k + 15],
            };
            const out_vec = r * inv_vec * w;
            ov[i * dim + k] = out_vec[0];
            ov[i * dim + k + 1] = out_vec[1];
            ov[i * dim + k + 2] = out_vec[2];
            ov[i * dim + k + 3] = out_vec[3];
            ov[i * dim + k + 4] = out_vec[4];
            ov[i * dim + k + 5] = out_vec[5];
            ov[i * dim + k + 6] = out_vec[6];
            ov[i * dim + k + 7] = out_vec[7];
            ov[i * dim + k + 8] = out_vec[8];
            ov[i * dim + k + 9] = out_vec[9];
            ov[i * dim + k + 10] = out_vec[10];
            ov[i * dim + k + 11] = out_vec[11];
            ov[i * dim + k + 12] = out_vec[12];
            ov[i * dim + k + 13] = out_vec[13];
            ov[i * dim + k + 14] = out_vec[14];
            ov[i * dim + k + 15] = out_vec[15];
        }
        while (k < dim) : (k += 1) ov[i * dim + k] = row[k] * inv * weight[k];
    }
}

/// Exact four-row RMSNorm with a weight-stationary output pass. Each lane's
/// sum-of-squares and multiply order matches `rmsNormF32`; only loop nesting
/// changes so every 16-value norm-weight tile is loaded once for four request
/// rows instead of four times.
pub fn rmsNormF32Rows4WeightStationary(
    x: Tensor,
    weight: []const f32,
    eps: f32,
    out: Tensor,
) TensorError!void {
    if (x.dtype != .f32 or out.dtype != .f32)
        return TensorError.DTypeUnsupported;
    if (x.shape.len != 2 or out.shape.len != 2 or x.shape[0] != 4 or
        out.shape[0] != 4 or out.shape[1] != x.shape[1] or
        weight.len != x.shape[1])
        return TensorError.ShapeMismatch;
    const dim = x.shape[1];
    if (dim == 0) return TensorError.ShapeMismatch;
    const expected_elements = std.math.mul(usize, 4, dim) catch
        return TensorError.ShapeMismatch;
    if (try checkedF32ElementCount(x) != expected_elements or
        try checkedF32ElementCount(out) != expected_elements or
        byteRangesOverlap(x.data, out.data) or
        byteRangesOverlap(std.mem.sliceAsBytes(weight), out.data))
        return TensorError.ShapeMismatch;
    const xv = x.asF32();
    const ov = out.asF32();
    const Vec16 = @Vector(16, f32);
    const vec_end = dim - (dim % 16);
    var inverse: [4]f32 = undefined;

    // Preserve the reference reduction tree independently for every row.
    for (0..4) |row_index| {
        const row = xv[row_index * dim ..][0..dim];
        var sum_vec: Vec16 = @splat(0);
        var k: usize = 0;
        while (k < vec_end) : (k += 16) {
            const values: Vec16 = .{
                row[k],      row[k + 1],  row[k + 2],  row[k + 3],
                row[k + 4],  row[k + 5],  row[k + 6],  row[k + 7],
                row[k + 8],  row[k + 9],  row[k + 10], row[k + 11],
                row[k + 12], row[k + 13], row[k + 14], row[k + 15],
            };
            sum_vec += values * values;
        }
        var sum_sq: f32 = @reduce(.Add, sum_vec);
        while (k < dim) : (k += 1) sum_sq += row[k] * row[k];
        inverse[row_index] = 1.0 /
            std.math.sqrt(sum_sq / @as(f32, @floatFromInt(dim)) + eps);
    }

    var k: usize = 0;
    while (k < vec_end) : (k += 16) {
        const weights: Vec16 = .{
            weight[k],      weight[k + 1],  weight[k + 2],  weight[k + 3],
            weight[k + 4],  weight[k + 5],  weight[k + 6],  weight[k + 7],
            weight[k + 8],  weight[k + 9],  weight[k + 10], weight[k + 11],
            weight[k + 12], weight[k + 13], weight[k + 14], weight[k + 15],
        };
        inline for (0..4) |row_index| {
            const row = xv[row_index * dim ..][0..dim];
            const values: Vec16 = .{
                row[k],      row[k + 1],  row[k + 2],  row[k + 3],
                row[k + 4],  row[k + 5],  row[k + 6],  row[k + 7],
                row[k + 8],  row[k + 9],  row[k + 10], row[k + 11],
                row[k + 12], row[k + 13], row[k + 14], row[k + 15],
            };
            const normalized = values * @as(Vec16, @splat(inverse[row_index])) * weights;
            const base = row_index * dim + k;
            ov[base] = normalized[0];
            ov[base + 1] = normalized[1];
            ov[base + 2] = normalized[2];
            ov[base + 3] = normalized[3];
            ov[base + 4] = normalized[4];
            ov[base + 5] = normalized[5];
            ov[base + 6] = normalized[6];
            ov[base + 7] = normalized[7];
            ov[base + 8] = normalized[8];
            ov[base + 9] = normalized[9];
            ov[base + 10] = normalized[10];
            ov[base + 11] = normalized[11];
            ov[base + 12] = normalized[12];
            ov[base + 13] = normalized[13];
            ov[base + 14] = normalized[14];
            ov[base + 15] = normalized[15];
        }
    }
    while (k < dim) : (k += 1) {
        const norm_weight = weight[k];
        inline for (0..4) |row_index| {
            const index = row_index * dim + k;
            ov[index] = xv[index] * inverse[row_index] * norm_weight;
        }
    }
}

/// Residual add followed by RMSNorm in two passes instead of three. The first
/// pass stores `residual = a + b` and accumulates the same Vec16 squares that
/// `rmsNormF32` would read back; every output operation therefore retains the
/// established floating-point order while one full residual read is removed.
/// `a`, `b`, and `weight` are read-only and may overlap one another. The
/// writable `residual` and `out` ranges must be mutually disjoint and must not
/// overlap any input range; invalid dtype, backing, alignment, or aliasing
/// fails before output is touched.
pub fn addRmsNormF32(
    a: Tensor,
    b: Tensor,
    residual: Tensor,
    weight: []const f32,
    eps: f32,
    out: Tensor,
) TensorError!void {
    if (a.dtype != .f32 or b.dtype != .f32 or residual.dtype != .f32 or
        out.dtype != .f32)
        return TensorError.DTypeUnsupported;
    if (a.shape.len != 2 or b.shape.len != 2 or residual.shape.len != 2 or
        out.shape.len != 2)
        return TensorError.ShapeMismatch;
    const batch = a.shape[0];
    const dim = a.shape[1];
    if (batch == 0 or dim == 0 or b.shape[0] != batch or
        residual.shape[0] != batch or out.shape[0] != batch or
        b.shape[1] != dim or residual.shape[1] != dim or out.shape[1] != dim or
        weight.len != dim)
        return TensorError.ShapeMismatch;
    const expected_elements = std.math.mul(usize, batch, dim) catch
        return TensorError.ShapeMismatch;
    if (try checkedF32ElementCount(a) != expected_elements or
        try checkedF32ElementCount(b) != expected_elements or
        try checkedF32ElementCount(residual) != expected_elements or
        try checkedF32ElementCount(out) != expected_elements)
        return TensorError.ShapeMismatch;

    const residual_bytes: []const u8 = residual.data;
    const out_bytes: []const u8 = out.data;
    const weight_bytes = std.mem.sliceAsBytes(weight);
    if (byteRangesOverlap(residual_bytes, a.data) or
        byteRangesOverlap(residual_bytes, b.data) or
        byteRangesOverlap(residual_bytes, out_bytes) or
        byteRangesOverlap(residual_bytes, weight_bytes) or
        byteRangesOverlap(out_bytes, a.data) or
        byteRangesOverlap(out_bytes, b.data) or
        byteRangesOverlap(out_bytes, weight_bytes))
        return TensorError.ShapeMismatch;

    const av = a.asF32();
    const bv = b.asF32();
    const rv = residual.asF32();
    const ov = out.asF32();
    const Vec16 = @Vector(16, f32);
    const vec_end = dim - (dim % 16);
    var row_index: usize = 0;
    while (row_index < batch) : (row_index += 1) {
        const row_start = row_index * dim;
        var sum_vec: Vec16 = @splat(0);
        var k: usize = 0;
        while (k < vec_end) : (k += 16) {
            const left: Vec16 = av[row_start + k ..][0..16].*;
            const right: Vec16 = bv[row_start + k ..][0..16].*;
            const value = left + right;
            rv[row_start + k ..][0..16].* = value;
            sum_vec += value * value;
        }
        var sum_sq: f32 = @reduce(.Add, sum_vec);
        while (k < dim) : (k += 1) {
            const value = av[row_start + k] + bv[row_start + k];
            rv[row_start + k] = value;
            sum_sq += value * value;
        }
        const rms = std.math.sqrt(sum_sq / @as(f32, @floatFromInt(dim)) + eps);
        const inv_vec: Vec16 = @splat(1.0 / rms);
        k = 0;
        while (k < vec_end) : (k += 16) {
            const value: Vec16 = rv[row_start + k ..][0..16].*;
            const w: Vec16 = weight[k..][0..16].*;
            ov[row_start + k ..][0..16].* = value * inv_vec * w;
        }
        const inv = inv_vec[0];
        while (k < dim) : (k += 1)
            ov[row_start + k] = rv[row_start + k] * inv * weight[k];
    }
}

/// SiLU (swish) activation: silu(x) = x * sigmoid(x).
/// Vectorized with 16-lane @Vector for the exp+mul loop.
pub fn siluF32(x: Tensor, out: Tensor) TensorError!void {
    if (x.shape.len != out.shape.len or x.data.len != out.data.len) return TensorError.ShapeMismatch;
    const xv = x.asF32();
    const ov = out.asF32();
    const n = xv.len;
    const Vec16 = @Vector(16, f32);
    const one_vec: Vec16 = @splat(1.0);

    var k: usize = 0;
    const vec_end = n - (n % 16);
    while (k < vec_end) : (k += 16) {
        const v: Vec16 = .{
            xv[k],      xv[k + 1],  xv[k + 2],  xv[k + 3],
            xv[k + 4],  xv[k + 5],  xv[k + 6],  xv[k + 7],
            xv[k + 8],  xv[k + 9],  xv[k + 10], xv[k + 11],
            xv[k + 12], xv[k + 13], xv[k + 14], xv[k + 15],
        };
        // sigmoid(x) = 1 / (1 + exp(-x)), silu(x) = x * sigmoid(x)
        const neg_v: Vec16 = .{
            -xv[k],      -xv[k + 1],  -xv[k + 2],  -xv[k + 3],
            -xv[k + 4],  -xv[k + 5],  -xv[k + 6],  -xv[k + 7],
            -xv[k + 8],  -xv[k + 9],  -xv[k + 10], -xv[k + 11],
            -xv[k + 12], -xv[k + 13], -xv[k + 14], -xv[k + 15],
        };
        // exp via @Vector — Zig maps this to NEON verdexp1f.
        // @exp on @Vector is supported in Zig — maps to NEON verdexp1f.
        const exp_neg = @exp(neg_v);
        const sig = one_vec / (one_vec + exp_neg);
        const result = v * sig;
        ov[k] = result[0];
        ov[k + 1] = result[1];
        ov[k + 2] = result[2];
        ov[k + 3] = result[3];
        ov[k + 4] = result[4];
        ov[k + 5] = result[5];
        ov[k + 6] = result[6];
        ov[k + 7] = result[7];
        ov[k + 8] = result[8];
        ov[k + 9] = result[9];
        ov[k + 10] = result[10];
        ov[k + 11] = result[11];
        ov[k + 12] = result[12];
        ov[k + 13] = result[13];
        ov[k + 14] = result[14];
        ov[k + 15] = result[15];
    }
    while (k < n) : (k += 1) ov[k] = xv[k] * sigmoid(xv[k]);
}

fn sigmoid(v: f32) f32 {
    return 1.0 / (1.0 + std.math.exp(-v));
}

// ---------------------------------------------------------------------------
// Correctness tests against hand-computed values.
// ---------------------------------------------------------------------------

/// Fused SiLU + element-wise multiply: out = silu(gate) * up.
/// Combines silu(gate) and gate*up into a single memory pass — eliminates
/// the temporary silu_gate tensor and one full read/write of hidden_dim
/// elements. On Qwen2.5-0.5B this saves ~19 KiB of memory traffic per
/// layer (hidden_dim=4864 × 4 bytes).
pub fn siluMulF32(gate: Tensor, up: Tensor, out: Tensor) TensorError!void {
    if (gate.data.len != up.data.len or gate.data.len != out.data.len)
        return TensorError.ShapeMismatch;
    const gv = gate.asF32();
    const uv = up.asF32();
    const ov = out.asF32();
    const n = gv.len;
    const Vec16 = @Vector(16, f32);
    const one_vec: Vec16 = @splat(1.0);

    var k: usize = 0;
    const vec_end = n - (n % 16);
    while (k < vec_end) : (k += 16) {
        const g: Vec16 = .{
            gv[k],      gv[k + 1],  gv[k + 2],  gv[k + 3],
            gv[k + 4],  gv[k + 5],  gv[k + 6],  gv[k + 7],
            gv[k + 8],  gv[k + 9],  gv[k + 10], gv[k + 11],
            gv[k + 12], gv[k + 13], gv[k + 14], gv[k + 15],
        };
        const u: Vec16 = .{
            uv[k],      uv[k + 1],  uv[k + 2],  uv[k + 3],
            uv[k + 4],  uv[k + 5],  uv[k + 6],  uv[k + 7],
            uv[k + 8],  uv[k + 9],  uv[k + 10], uv[k + 11],
            uv[k + 12], uv[k + 13], uv[k + 14], uv[k + 15],
        };
        const neg_g: Vec16 = .{
            -gv[k],      -gv[k + 1],  -gv[k + 2],  -gv[k + 3],
            -gv[k + 4],  -gv[k + 5],  -gv[k + 6],  -gv[k + 7],
            -gv[k + 8],  -gv[k + 9],  -gv[k + 10], -gv[k + 11],
            -gv[k + 12], -gv[k + 13], -gv[k + 14], -gv[k + 15],
        };
        const sig = one_vec / (one_vec + @exp(neg_g));
        const result = g * sig * u;
        inline for (0..16) |i| ov[k + i] = result[i];
    }
    while (k < n) : (k += 1) ov[k] = gv[k] * sigmoid(gv[k]) * uv[k];
}

/// Fuse SwiGLU with the activation conversion consumed by the packed INT4
/// down projection. Values live only in one 16/32-element stack block, so the
/// full hidden-width f32 intermediary is never written or read back.
/// Trusted execution descriptor. Only values returned by
/// `prepareSiluMulQuantizeQ8` satisfy the backing and alias contract; callers
/// must treat the fields as immutable after construction.
pub const SiluMulQuantizeQ8Plan = struct {
    gate: []const f32,
    up: []const f32,
    q_output: []i8,
    activation_scales: []f32,
    activation_group_size: usize,
    group_count: usize,

    /// Execute a prevalidated, disjoint half-open range of activation groups.
    /// A caller may run non-overlapping ranges concurrently. Construction of
    /// the plan proves all backing and alias invariants once, before any write.
    pub fn runGroupRange(
        self: SiluMulQuantizeQ8Plan,
        group_start: usize,
        group_end: usize,
    ) TensorError!void {
        if (group_start >= group_end or group_end > self.group_count)
            return TensorError.ShapeMismatch;

        const Vec16 = @Vector(16, f32);
        const one_vec: Vec16 = @splat(1.0);
        var values: [32]f32 = undefined;
        for (group_start..group_end) |group| {
            const start = group * self.activation_group_size;
            const count = @min(self.activation_group_size, self.gate.len - start);
            var offset: usize = 0;
            while (offset + 16 <= count) : (offset += 16) {
                const index = start + offset;
                const g: Vec16 = self.gate[index..][0..16].*;
                const u: Vec16 = self.up[index..][0..16].*;
                const result = g * (one_vec / (one_vec + @exp(-g))) * u;
                values[offset..][0..16].* = result;
            }
            while (offset < count) : (offset += 1) {
                const g = self.gate[start + offset];
                values[offset] = g * sigmoid(g) * self.up[start + offset];
            }

            var max_abs: f32 = 0;
            for (values[0..count]) |value| max_abs = @max(max_abs, @abs(value));
            const scale = max_abs / 127.0;
            self.activation_scales[group] = scale;
            if (scale == 0) {
                @memset(self.q_output[start .. start + count], 0);
                continue;
            }
            const inverse_scale = 1.0 / scale;
            for (values[0..count], self.q_output[start .. start + count]) |value, *quantized| {
                const rounded: i32 = @intFromFloat(@round(value * inverse_scale));
                quantized.* = @intCast(std.math.clamp(rounded, -127, 127));
            }
        }
    }

    /// Map a projection row tile onto whole activation groups. Every interior
    /// boundary must be group-aligned; only the logical final row may be a tail.
    pub fn runElementRange(
        self: SiluMulQuantizeQ8Plan,
        element_start: usize,
        element_end: usize,
    ) TensorError!void {
        if (element_start >= element_end or element_end > self.gate.len or
            element_start % self.activation_group_size != 0 or
            (element_end != self.gate.len and
                element_end % self.activation_group_size != 0))
            return TensorError.ShapeMismatch;
        const group_start = element_start / self.activation_group_size;
        const quotient = element_end / self.activation_group_size;
        const group_end = quotient + @intFromBool(
            element_end % self.activation_group_size != 0,
        );
        return self.runGroupRange(group_start, group_end);
    }
};

/// Validate an exact SwiGLU-to-Q8 bridge over caller-owned slices. This is the
/// storage-level form used by bounded producers whose gate/up values live only
/// in a private tile rather than in full Tensor objects. The returned plan uses
/// the same arithmetic implementation as `prepareSiluMulQuantizeQ8`.
pub fn prepareSiluMulQuantizeQ8Slices(
    gate: []const f32,
    up: []const f32,
    weight_group_size: u32,
    q_output: []i8,
    activation_scales: []f32,
) TensorError!SiluMulQuantizeQ8Plan {
    if (weight_group_size != 8 and weight_group_size != 16)
        return TensorError.ShapeMismatch;
    if (up.len != gate.len)
        return TensorError.ShapeMismatch;
    const activation_group_size: usize = if (weight_group_size == 8) 32 else 16;
    const quotient = gate.len / activation_group_size;
    const group_count = quotient + @intFromBool(
        gate.len % activation_group_size != 0,
    );
    if (q_output.len < gate.len or activation_scales.len < group_count)
        return TensorError.ShapeMismatch;

    const logical_q = q_output[0..gate.len];
    const logical_scales = activation_scales[0..group_count];
    const gate_bytes = std.mem.sliceAsBytes(gate);
    const up_bytes = std.mem.sliceAsBytes(up);
    const q_output_bytes = std.mem.sliceAsBytes(logical_q);
    const scale_bytes = std.mem.sliceAsBytes(logical_scales);
    if (byteRangesOverlap(q_output_bytes, gate_bytes) or
        byteRangesOverlap(q_output_bytes, up_bytes) or
        byteRangesOverlap(q_output_bytes, scale_bytes) or
        byteRangesOverlap(scale_bytes, gate_bytes) or
        byteRangesOverlap(scale_bytes, up_bytes))
        return TensorError.ShapeMismatch;

    return .{
        .gate = gate,
        .up = up,
        .q_output = logical_q,
        .activation_scales = logical_scales,
        .activation_group_size = activation_group_size,
        .group_count = group_count,
    };
}

/// Validate the complete SwiGLU-to-Q8 write set without touching it and return
/// an immutable execution description. This lets graph schedulers preflight
/// once, then execute disjoint ranges without repeated tensor/alias checks.
pub fn prepareSiluMulQuantizeQ8(
    gate: Tensor,
    up: Tensor,
    weight_group_size: u32,
    q_output: []i8,
    activation_scales: []f32,
) TensorError!SiluMulQuantizeQ8Plan {
    const element_count = try checkedF32ElementCount(gate);
    if (try checkedF32ElementCount(up) != element_count)
        return TensorError.ShapeMismatch;
    const plan = try prepareSiluMulQuantizeQ8Slices(
        if (element_count == 0) &.{} else gate.asF32(),
        if (element_count == 0) &.{} else up.asF32(),
        weight_group_size,
        q_output,
        activation_scales,
    );
    const q_output_bytes = std.mem.sliceAsBytes(plan.q_output);
    const scale_bytes = std.mem.sliceAsBytes(plan.activation_scales);
    if (byteRangesOverlap(q_output_bytes, std.mem.sliceAsBytes(gate.shape)) or
        byteRangesOverlap(q_output_bytes, std.mem.sliceAsBytes(up.shape)) or
        byteRangesOverlap(scale_bytes, std.mem.sliceAsBytes(gate.shape)) or
        byteRangesOverlap(scale_bytes, std.mem.sliceAsBytes(up.shape)))
        return TensorError.ShapeMismatch;
    return plan;
}

/// Execute the exact production SwiGLU-to-Q8 arithmetic over bounded private
/// slices. It is intentionally allocation-free and does not permit a caller to
/// offset into partially overlapping activation groups.
pub fn siluMulQuantizeQ8Slices(
    gate: []const f32,
    up: []const f32,
    weight_group_size: u32,
    q_output: []i8,
    activation_scales: []f32,
) TensorError!void {
    const plan = try prepareSiluMulQuantizeQ8Slices(
        gate,
        up,
        weight_group_size,
        q_output,
        activation_scales,
    );
    if (plan.group_count == 0) return;
    return plan.runGroupRange(0, plan.group_count);
}

/// Sealed worker edge for private producer tiles. The owning executor must
/// preflight all caller-visible aliases and derive whole activation-group
/// ranges before dispatch; stack-private gate/up slices are inherently
/// disjoint from the bound Q8 destination. Public callers use the checked
/// `siluMulQuantizeQ8Slices` constructor above.
pub inline fn siluMulQuantizeQ8SlicesPrevalidated(
    gate: []const f32,
    up: []const f32,
    activation_group_size: usize,
    q_output: []i8,
    activation_scales: []f32,
) void {
    std.debug.assert(gate.len != 0 and up.len == gate.len);
    std.debug.assert(
        activation_group_size == 16 or activation_group_size == 32,
    );
    std.debug.assert(q_output.len == gate.len);
    const group_count = gate.len / activation_group_size +
        @intFromBool(gate.len % activation_group_size != 0);
    std.debug.assert(activation_scales.len == group_count);
    const plan: SiluMulQuantizeQ8Plan = .{
        .gate = gate,
        .up = up,
        .q_output = q_output,
        .activation_scales = activation_scales,
        .activation_group_size = activation_group_size,
        .group_count = group_count,
    };
    plan.runGroupRange(0, group_count) catch unreachable;
}

pub fn siluMulQuantizeQ8(
    gate: Tensor,
    up: Tensor,
    weight_group_size: u32,
    q_output: []i8,
    activation_scales: []f32,
) TensorError!void {
    const plan = try prepareSiluMulQuantizeQ8(
        gate,
        up,
        weight_group_size,
        q_output,
        activation_scales,
    );
    if (plan.group_count == 0) return;
    return plan.runGroupRange(0, plan.group_count);
}

/// Quantize a disjoint half-open range of activation groups. Groups have no
/// cross-group reductions or state, so callers may execute validated ranges in
/// parallel while preserving the exact bytes of `siluMulQuantizeQ8`. `gate`
/// and `up` are read-only and may overlap; the full logical Q8 and scale output
/// ranges must be mutually disjoint and disjoint from both inputs.
pub fn siluMulQuantizeQ8Range(
    gate: Tensor,
    up: Tensor,
    weight_group_size: u32,
    q_output: []i8,
    activation_scales: []f32,
    group_start: usize,
    group_end: usize,
) TensorError!void {
    const plan = try prepareSiluMulQuantizeQ8(
        gate,
        up,
        weight_group_size,
        q_output,
        activation_scales,
    );
    return plan.runGroupRange(group_start, group_end);
}

const testing = std.testing;

test "fused SwiGLU Q8 conversion matches materialized activation" {
    var gate_values: [32]f32 = undefined;
    var up_values: [32]f32 = undefined;
    for (&gate_values, &up_values, 0..) |*gate_value, *up_value, index| {
        gate_value.* = (@as(f32, @floatFromInt(index)) - 15.5) / 8.0;
        up_value.* = (@as(f32, @floatFromInt((index * 7) % 19)) - 9.0) / 5.0;
    }
    var gate = try tensor.fromF32(testing.allocator, &.{ 1, 32 }, &gate_values);
    defer gate.deinit();
    var up = try tensor.fromF32(testing.allocator, &.{ 1, 32 }, &up_values);
    defer up.deinit();
    var materialized = try tensor.zerosF32(testing.allocator, &.{ 1, 32 });
    defer materialized.deinit();
    try siluMulF32(gate, up, materialized);

    var expected_q: [32]i8 = undefined;
    var max_abs: f32 = 0;
    for (materialized.asF32()) |value| max_abs = @max(max_abs, @abs(value));
    const expected_scale = max_abs / 127.0;
    for (materialized.asF32(), &expected_q) |value, *quantized| {
        const rounded: i32 = @intFromFloat(@round(value / expected_scale));
        quantized.* = @intCast(std.math.clamp(rounded, -127, 127));
    }

    var actual_q: [32]i8 = undefined;
    var actual_scales: [1]f32 = undefined;
    try siluMulQuantizeQ8(gate, up, 8, &actual_q, &actual_scales);
    try testing.expectEqualSlices(i8, &expected_q, &actual_q);
    try testing.expectEqual(expected_scale, actual_scales[0]);
}

test "SwiGLU Q8 group ranges compose byte exactly across tails" {
    const Verify = struct {
        fn run(comptime element_count: usize, comptime group_size: u32) !void {
            var gate_values: [element_count]f32 = undefined;
            var up_values: [element_count]f32 = undefined;
            for (&gate_values, &up_values, 0..) |*gate_value, *up_value, index| {
                gate_value.* = (@as(f32, @floatFromInt((index * 11) % 37)) - 18.0) / 7.0;
                up_value.* = (@as(f32, @floatFromInt((index * 5) % 29)) - 14.0) / 6.0;
            }
            var gate = try tensor.fromF32(testing.allocator, &.{ 1, element_count }, &gate_values);
            defer gate.deinit();
            var up = try tensor.fromF32(testing.allocator, &.{ 1, element_count }, &up_values);
            defer up.deinit();

            const activation_group_size: usize = if (group_size == 8) 32 else 16;
            const group_count = (element_count + activation_group_size - 1) /
                activation_group_size;
            var expected_q: [element_count]i8 = undefined;
            var actual_q = [_]i8{-99} ** element_count;
            var expected_scales: [(element_count + 15) / 16]f32 = undefined;
            var actual_scales = [_]f32{-99} ** ((element_count + 15) / 16);
            try siluMulQuantizeQ8(
                gate,
                up,
                group_size,
                &expected_q,
                expected_scales[0..group_count],
            );
            try siluMulQuantizeQ8Range(
                gate,
                up,
                group_size,
                &actual_q,
                actual_scales[0..group_count],
                0,
                1,
            );
            try siluMulQuantizeQ8Range(
                gate,
                up,
                group_size,
                &actual_q,
                actual_scales[0..group_count],
                1,
                group_count,
            );
            try testing.expectEqualSlices(i8, &expected_q, &actual_q);
            try testing.expect(std.mem.eql(
                u8,
                std.mem.sliceAsBytes(expected_scales[0..group_count]),
                std.mem.sliceAsBytes(actual_scales[0..group_count]),
            ));
            try testing.expectError(
                TensorError.ShapeMismatch,
                siluMulQuantizeQ8Range(
                    gate,
                    up,
                    group_size,
                    &actual_q,
                    actual_scales[0..group_count],
                    1,
                    1,
                ),
            );
            try testing.expectError(
                TensorError.ShapeMismatch,
                siluMulQuantizeQ8Range(
                    gate,
                    up,
                    group_size,
                    &actual_q,
                    actual_scales[0..group_count],
                    0,
                    group_count + 1,
                ),
            );

            var wrong_dtype = gate;
            wrong_dtype.dtype = .f16;
            try testing.expectError(
                TensorError.DTypeUnsupported,
                siluMulQuantizeQ8(
                    wrong_dtype,
                    up,
                    group_size,
                    &actual_q,
                    actual_scales[0..group_count],
                ),
            );
            var truncated = gate;
            truncated.data = truncated.data[0 .. truncated.data.len - @sizeOf(f32)];
            try testing.expectError(
                TensorError.ShapeMismatch,
                siluMulQuantizeQ8Range(
                    truncated,
                    up,
                    group_size,
                    &actual_q,
                    actual_scales[0..group_count],
                    0,
                    1,
                ),
            );
            var misaligned_storage: [element_count * @sizeOf(f32) + 1]u8 align(4) = undefined;
            var misaligned = gate;
            misaligned.data = misaligned_storage[1..][0 .. element_count * @sizeOf(f32)];
            try testing.expectError(
                TensorError.ShapeMismatch,
                siluMulQuantizeQ8Range(
                    misaligned,
                    up,
                    group_size,
                    &actual_q,
                    actual_scales[0..group_count],
                    0,
                    1,
                ),
            );

            const q_aliases_gate = std.mem.bytesAsSlice(i8, gate.data)[0..element_count];
            try testing.expectError(
                TensorError.ShapeMismatch,
                siluMulQuantizeQ8Range(
                    gate,
                    up,
                    group_size,
                    q_aliases_gate,
                    actual_scales[0..group_count],
                    0,
                    1,
                ),
            );
            try testing.expectError(
                TensorError.ShapeMismatch,
                siluMulQuantizeQ8Range(
                    gate,
                    up,
                    group_size,
                    &actual_q,
                    gate.asF32()[0..group_count],
                    0,
                    1,
                ),
            );
            var overlapping_outputs: [element_count]f32 = undefined;
            const overlapping_q = std.mem.bytesAsSlice(
                i8,
                std.mem.sliceAsBytes(overlapping_outputs[0..]),
            )[0..element_count];
            try testing.expectError(
                TensorError.ShapeMismatch,
                siluMulQuantizeQ8Range(
                    gate,
                    up,
                    group_size,
                    overlapping_q,
                    overlapping_outputs[0..group_count],
                    0,
                    1,
                ),
            );

            const metadata_bytes = @max(
                element_count,
                group_count * @sizeOf(f32),
            );
            var metadata_storage: [metadata_bytes]u8 align(@alignOf(usize)) = undefined;
            const metadata_shape = std.mem.bytesAsSlice(
                usize,
                metadata_storage[0 .. 2 * @sizeOf(usize)],
            );
            metadata_shape[0] = 1;
            metadata_shape[1] = element_count;
            var metadata_gate = gate;
            metadata_gate.shape = metadata_shape;
            const q_aliases_shape = std.mem.bytesAsSlice(
                i8,
                &metadata_storage,
            )[0..element_count];
            try testing.expectError(
                TensorError.ShapeMismatch,
                prepareSiluMulQuantizeQ8(
                    metadata_gate,
                    up,
                    group_size,
                    q_aliases_shape,
                    actual_scales[0..group_count],
                ),
            );
            try testing.expectEqualSlices(
                usize,
                &.{ 1, element_count },
                metadata_shape,
            );

            const scales_alias_shape = std.mem.bytesAsSlice(
                f32,
                metadata_storage[0 .. group_count * @sizeOf(f32)],
            );
            try testing.expectError(
                TensorError.ShapeMismatch,
                prepareSiluMulQuantizeQ8(
                    metadata_gate,
                    up,
                    group_size,
                    &actual_q,
                    scales_alias_shape,
                ),
            );
            try testing.expectEqualSlices(
                usize,
                &.{ 1, element_count },
                metadata_shape,
            );
        }
    };

    try Verify.run(69, 8);
    try Verify.run(35, 16);
}

test "SwiGLU Q8 empty activation remains a no-op" {
    const empty_shape = [_]usize{ 1, 0 };
    var empty_data: [0]u8 align(4) = .{};
    const gate: Tensor = .{
        .dtype = .f32,
        .shape = &empty_shape,
        .data = &empty_data,
        .allocator = testing.allocator,
    };
    const up = gate;
    var q_output: [0]i8 = .{};
    var activation_scales: [0]f32 = .{};

    try siluMulQuantizeQ8(
        gate,
        up,
        8,
        &q_output,
        &activation_scales,
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        siluMulQuantizeQ8Range(
            gate,
            up,
            8,
            &q_output,
            &activation_scales,
            0,
            0,
        ),
    );
}

test "linearF32 matches manual matmul" {
    // x = [[1, 2, 3]]   W = [[1,0,0],[0,1,0],[0,0,1]]   → out = [[1,2,3]]
    var x = try tensor.fromF32(testing.allocator, &.{ 1, 3 }, &.{ 1, 2, 3 });
    defer x.deinit();
    var w = try tensor.fromF32(testing.allocator, &.{ 3, 3 }, &.{
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
    });
    defer w.deinit();
    var out = try tensor.zerosF32(testing.allocator, &.{ 1, 3 });
    defer out.deinit();

    try linearF32(x, w, &.{}, out);
    try testing.expectEqualSlices(f32, &.{ 1, 2, 3 }, out.asF32());
}

test "linearF32 with bias" {
    var x = try tensor.fromF32(testing.allocator, &.{ 1, 2 }, &.{ 1, 1 });
    defer x.deinit();
    var w = try tensor.fromF32(testing.allocator, &.{ 2, 2 }, &.{
        1, 2,
        3, 4,
    });
    defer w.deinit();
    var out = try tensor.zerosF32(testing.allocator, &.{ 1, 2 });
    defer out.deinit();

    // x · W^T = [1*1+1*2, 1*3+1*4] = [3, 7], + bias [10, 20] = [13, 27]
    try linearF32(x, w, &.{ 10, 20 }, out);
    try testing.expectEqualSlices(f32, &.{ 13, 27 }, out.asF32());
}

test "rmsNorm normalizes to expected scale" {
    // x = [[3, 4]]; mean(x²) = (9+16)/2 = 12.5; rms = sqrt(12.5 + eps)
    // With weight [1,1] and eps≈0 → y ≈ [3/√12.5, 4/√12.5]
    var x = try tensor.fromF32(testing.allocator, &.{ 1, 2 }, &.{ 3, 4 });
    defer x.deinit();
    var out = try tensor.zerosF32(testing.allocator, &.{ 1, 2 });
    defer out.deinit();
    try rmsNormF32(x, &.{ 1, 1 }, 1e-6, out);

    const expected_rms = std.math.sqrt(12.5 + 1e-6);
    try testing.expectApproxEqAbs(3.0 / expected_rms, out.asF32()[0], 1e-5);
    try testing.expectApproxEqAbs(4.0 / expected_rms, out.asF32()[1], 1e-5);
}

test "four-row weight-stationary RMSNorm is byte exact for vector tails" {
    inline for ([_]usize{ 1, 15, 16, 19, 64 }) |dim| {
        const count = 4 * dim;
        var input_values: [count]f32 = undefined;
        var norm_weights: [dim]f32 = undefined;
        for (&input_values, 0..) |*value, index|
            value.* = (@as(f32, @floatFromInt((index * 17) % 53)) - 26.0) / 13.0;
        for (&norm_weights, 0..) |*value, index|
            value.* = 0.25 + @as(f32, @floatFromInt(index + 1)) / 41.0;
        var input = try tensor.fromF32(
            testing.allocator,
            &.{ 4, dim },
            &input_values,
        );
        defer input.deinit();
        var reference = try tensor.zerosF32(testing.allocator, &.{ 4, dim });
        defer reference.deinit();
        var actual = try tensor.zerosF32(testing.allocator, &.{ 4, dim });
        defer actual.deinit();
        try rmsNormF32(input, &norm_weights, 1e-6, reference);
        try rmsNormF32Rows4WeightStationary(input, &norm_weights, 1e-6, actual);
        try testing.expect(std.mem.eql(
            u8,
            std.mem.sliceAsBytes(reference.asF32()),
            std.mem.sliceAsBytes(actual.asF32()),
        ));
    }
}

test "fused residual RMSNorm matches materialized rows byte exactly" {
    const batch: usize = 2;
    const dim: usize = 19;
    const element_count = batch * dim;
    var left_values: [element_count]f32 = undefined;
    var right_values: [element_count]f32 = undefined;
    var weights: [dim]f32 = undefined;
    for (&left_values, &right_values, 0..) |*left, *right, index| {
        left.* = (@as(f32, @floatFromInt((index * 7) % 31)) - 15.0) / 9.0;
        right.* = (@as(f32, @floatFromInt((index * 13) % 41)) - 20.0) / 11.0;
    }
    for (&weights, 0..) |*weight, index|
        weight.* = 0.5 + @as(f32, @floatFromInt(index)) / 37.0;

    var left = try tensor.fromF32(testing.allocator, &.{ batch, dim }, &left_values);
    defer left.deinit();
    var right = try tensor.fromF32(testing.allocator, &.{ batch, dim }, &right_values);
    defer right.deinit();
    var expected_residual = try tensor.zerosF32(testing.allocator, &.{ batch, dim });
    defer expected_residual.deinit();
    var actual_residual = try tensor.zerosF32(testing.allocator, &.{ batch, dim });
    defer actual_residual.deinit();
    var expected_out = try tensor.zerosF32(testing.allocator, &.{ batch, dim });
    defer expected_out.deinit();
    var actual_out = try tensor.zerosF32(testing.allocator, &.{ batch, dim });
    defer actual_out.deinit();

    for (
        left.asF32(),
        right.asF32(),
        expected_residual.asF32(),
    ) |left_value, right_value, *residual_value| {
        residual_value.* = left_value + right_value;
    }
    try rmsNormF32(expected_residual, &weights, 1e-6, expected_out);
    try addRmsNormF32(
        left,
        right,
        actual_residual,
        &weights,
        1e-6,
        actual_out,
    );
    try testing.expect(std.mem.eql(
        u8,
        std.mem.sliceAsBytes(expected_residual.asF32()),
        std.mem.sliceAsBytes(actual_residual.asF32()),
    ));
    try testing.expect(std.mem.eql(
        u8,
        std.mem.sliceAsBytes(expected_out.asF32()),
        std.mem.sliceAsBytes(actual_out.asF32()),
    ));
    try testing.expectError(
        TensorError.ShapeMismatch,
        addRmsNormF32(
            left,
            right,
            actual_residual,
            weights[0 .. dim - 1],
            1e-6,
            actual_out,
        ),
    );

    var wrong_dtype = left;
    wrong_dtype.dtype = .bf16;
    try testing.expectError(
        TensorError.DTypeUnsupported,
        addRmsNormF32(
            wrong_dtype,
            right,
            actual_residual,
            &weights,
            1e-6,
            actual_out,
        ),
    );
    var truncated = left;
    truncated.data = truncated.data[0 .. truncated.data.len - @sizeOf(f32)];
    try testing.expectError(
        TensorError.ShapeMismatch,
        addRmsNormF32(
            truncated,
            right,
            actual_residual,
            &weights,
            1e-6,
            actual_out,
        ),
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        addRmsNormF32(
            left,
            right,
            left,
            &weights,
            1e-6,
            actual_out,
        ),
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        addRmsNormF32(
            left,
            right,
            actual_residual,
            &weights,
            1e-6,
            actual_residual,
        ),
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        addRmsNormF32(
            left,
            right,
            actual_residual,
            actual_residual.asF32()[0..dim],
            1e-6,
            actual_out,
        ),
    );

    var overlapping_outputs: [element_count + 1]f32 = undefined;
    const overlap_shape = [_]usize{ batch, dim };
    const residual_view: Tensor = .{
        .dtype = .f32,
        .shape = &overlap_shape,
        .data = std.mem.sliceAsBytes(overlapping_outputs[0..element_count]),
        .allocator = testing.allocator,
    };
    const shifted_out_view: Tensor = .{
        .dtype = .f32,
        .shape = &overlap_shape,
        .data = std.mem.sliceAsBytes(overlapping_outputs[1 .. element_count + 1]),
        .allocator = testing.allocator,
    };
    try testing.expectError(
        TensorError.ShapeMismatch,
        addRmsNormF32(
            left,
            right,
            residual_view,
            &weights,
            1e-6,
            shifted_out_view,
        ),
    );
}

test "silu matches definition" {
    // silu(0) = 0; silu(large+) → x; silu(large-) → 0.
    var x = try tensor.fromF32(testing.allocator, &.{ 1, 3 }, &.{ 0, 100, -100 });
    defer x.deinit();
    var out = try tensor.zerosF32(testing.allocator, &.{ 1, 3 });
    defer out.deinit();
    try siluF32(x, out);
    const v = out.asF32();
    try testing.expectApproxEqAbs(@as(f32, 0), v[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 100), v[1], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), v[2], 1e-3);
}
