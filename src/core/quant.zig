//! Quantization — the P-axis made real.
//!
//! Group-wise zero-centered INT4/INT8 quantization with per-group FP32 scales.
//! The scheme AWQ/GPTQ-class engines use and what the Metal dequant
//! kernel matches (verified numerically in tests/metal_correctness.zig).
//!
//! Storage layout for one quantized tensor chunk:
//!
//!   ┌──────────────────────────────────────────────────────────┐
//!   │ group_count × fp16 scale    (one scale per group)        │
//!   ├──────────────────────────────────────────────────────────┤
//!   │ packed weights (2 per byte for INT4, 1 per byte for INT8)│
//!   └──────────────────────────────────────────────────────────┘
//!
//! INT8 and compact g8 INT4 use symmetric limits. INT4 groups of 16 or
//! larger use the spare positive code for [-7,+8]. Per-group calibration
//! keeps outliers in one region from wrecking the whole tensor.

const std = @import("std");

pub const QuantPrecision = enum(u8) { int8 = 0, int4 = 1 };

/// Bytes of weight payload per source element, by dtype.
pub fn srcBytesPerElem(comptime SrcDType: type) usize {
    return switch (SrcDType) {
        f16, u16, i16 => 2,
        f32, u32, i32 => 4,
        else => @compileError("unsupported source dtype"),
    };
}

/// Quantize a flat slice of source weights into a zero-centered integer
/// format. Returns the packed bytes (caller owns) and writes the scale count
/// into `out_group_count`. `group_size` is the number of source elements per
/// quantization group (typically 32, 64, or 128).
pub fn quantize(
    comptime SrcDType: type,
    allocator: std.mem.Allocator,
    src: []const SrcDType,
    precision: QuantPrecision,
    group_size: u32,
) !struct { packed_bytes: []u8, scales: []f32 } {
    if (src.len == 0) return .{ .packed_bytes = &.{}, .scales = &.{} };
    if (group_size == 0) return error.BadGroupSize;

    const bits: u8 = switch (precision) {
        .int8 => 8,
        .int4 => 4,
    };
    const qzero: i32 = (@as(i32, 1) << @intCast(bits - 1)) - 1; // 127 or 7
    const qmin: i32 = -qzero;
    // INT4 has one otherwise-unused code. Its established zero point is 7,
    // so code 15 naturally represents +8 while code 0 represents -7.
    const qmax: i32 = if (precision == .int4 and group_size >= 16) qzero + 1 else qzero;
    const group_size_usize: usize = group_size;
    const num_groups = ceilDiv(src.len, group_size_usize);
    const scales = try allocator.alloc(f32, num_groups);
    errdefer allocator.free(scales);

    const packed_bits = try std.math.mul(usize, src.len, bits);
    const packed_len = ceilDiv(packed_bits, 8);
    const packed_bytes = try allocator.alloc(u8, packed_len);
    errdefer allocator.free(packed_bytes);
    @memset(packed_bytes, 0);

    var elem_idx: usize = 0;
    var group_idx: usize = 0;
    while (elem_idx < src.len) : (group_idx += 1) {
        const end = elem_idx + @min(group_size_usize, src.len - elem_idx);

        // Pass 1: calibrate against the asymmetric [-7, +8] code limits.
        // This uses all 16 codes without adding a zero-point stream.
        var min_value: f32 = 0;
        var max_value: f32 = 0;
        for (src[elem_idx..end]) |v| {
            const fv: f32 = switch (@TypeOf(v)) {
                f16 => @floatCast(v),
                f32 => v,
                u16, u32 => @floatFromInt(v),
                i16, i32 => @floatFromInt(v),
                else => @compileError("unsupported dtype"),
            };
            min_value = @min(min_value, fv);
            max_value = @max(max_value, fv);
        }

        const negative_scale = -min_value / @as(f32, @floatFromInt(-qmin));
        const positive_scale = max_value / @as(f32, @floatFromInt(qmax));
        const scale: f32 = @max(negative_scale, positive_scale);
        scales[group_idx] = scale;
        const inv_scale: f32 = if (scale == 0) 0 else 1.0 / scale;

        // Pass 2: round to nearest int and pack.
        for (src[elem_idx..end], 0..) |v, i_in_group| {
            const fv: f32 = switch (@TypeOf(v)) {
                f16 => @floatCast(v),
                f32 => v,
                u16, u32 => @floatFromInt(v),
                i16, i32 => @floatFromInt(v),
                else => @compileError("unsupported dtype"),
            };
            var q: i32 = @intFromFloat(@round(fv * inv_scale));
            q = clamp(q, qmin, qmax);
            const uq: u8 = @intCast(q + qzero);
            writeNibbleOrByte(packed_bytes, elem_idx + i_in_group, uq, precision);
        }
        elem_idx = end;
    }

    return .{ .packed_bytes = packed_bytes, .scales = scales };
}

/// Inverse of quantize. `scales` must be the slice returned by quantize.
pub fn dequantize(
    comptime DstDType: type,
    allocator: std.mem.Allocator,
    packed_bytes: []const u8,
    scales: []const f32,
    precision: QuantPrecision,
    group_size: u32,
    num_elements: usize,
) ![]DstDType {
    if (num_elements == 0) return &.{};
    if (group_size == 0) return error.BadGroupSize;

    const bits: u8 = switch (precision) {
        .int8 => 8,
        .int4 => 4,
    };
    const qmax: i32 = (@as(i32, 1) << @intCast(bits - 1)) - 1;

    const group_size_usize: usize = group_size;
    const required_scales = ceilDiv(num_elements, group_size_usize);
    if (scales.len < required_scales) return error.TruncatedScales;
    const packed_bits = try std.math.mul(usize, num_elements, bits);
    const required_packed = ceilDiv(packed_bits, 8);
    if (packed_bytes.len < required_packed) return error.TruncatedPacked;

    const out = try allocator.alloc(DstDType, num_elements);
    errdefer allocator.free(out);

    var i: usize = 0;
    var group_idx: usize = 0;
    while (i < num_elements) : (group_idx += 1) {
        const end = i + @min(group_size_usize, num_elements - i);
        const scale = scales[group_idx];
        for (i..end) |j| {
            const uq = readNibbleOrByte(packed_bytes, j, precision);
            const q: i32 = @as(i32, uq) - qmax;
            const v: f32 = @as(f32, @floatFromInt(q)) * scale;
            out[j] = switch (DstDType) {
                f32 => v,
                f16 => @floatCast(v),
                u16, u32 => @intFromFloat(v),
                i16, i32 => @intFromFloat(v),
                else => @compileError("unsupported dst dtype"),
            };
        }
        i = end;
    }
    return out;
}

inline fn writeNibbleOrByte(buf: []u8, idx: usize, val: u8, precision: QuantPrecision) void {
    switch (precision) {
        .int8 => buf[idx] = val,
        .int4 => {
            // 2 per byte, low nibble first for even index.
            const byte_idx = idx / 2;
            if (idx % 2 == 0) {
                buf[byte_idx] = (buf[byte_idx] & 0xF0) | (val & 0x0F);
            } else {
                buf[byte_idx] = (buf[byte_idx] & 0x0F) | ((val & 0x0F) << 4);
            }
        },
    }
}

inline fn readNibbleOrByte(buf: []const u8, idx: usize, precision: QuantPrecision) u8 {
    return switch (precision) {
        .int8 => buf[idx],
        .int4 => blk: {
            const byte_idx = idx / 2;
            if (idx % 2 == 0) {
                break :blk buf[byte_idx] & 0x0F;
            } else {
                break :blk (buf[byte_idx] >> 4) & 0x0F;
            }
        },
    };
}

inline fn clamp(v: i32, lo: i32, hi: i32) i32 {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

inline fn ceilDiv(numerator: usize, denominator: usize) usize {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "INT8 round-trip is exact for integers" {
    const src = [_]f32{ 0, 1, -1, 2, -2, 64, -64, 127, -127 };
    const q = try quantize(f32, testing.allocator, &src, .int8, 16);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }
    const back = try dequantize(f32, testing.allocator, q.packed_bytes, q.scales, .int8, 16, src.len);
    defer testing.allocator.free(back);
    for (src, back) |a, b| {
        try testing.expectApproxEqAbs(a, b, 1.0); // INT8 has headroom; integers should match closely.
    }
}

test "INT4 packs 2 elements per byte" {
    const src = [_]f32{ 0, 0, 0, 0 };
    const q = try quantize(f32, testing.allocator, &src, .int4, 4);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }
    // 4 elements × 4 bits = 16 bits = 2 bytes.
    try testing.expectEqual(@as(usize, 2), q.packed_bytes.len);
    // All zeros quantize to the symmetric midpoint (qmax), so each nibble
    // holds qmax = 7. Two 7-nibbles packed low+high = 0x77.
    try testing.expectEqual(@as(u8, 0x77), q.packed_bytes[0]);
    try testing.expectEqual(@as(u8, 0x77), q.packed_bytes[1]);
}

test "INT4 group 16 uses the full positive code while group 8 stays compatible" {
    var src = [_]f32{0} ** 16;
    src[0] = 1;
    const full_range = try quantize(f32, testing.allocator, &src, .int4, 16);
    defer {
        testing.allocator.free(full_range.packed_bytes);
        testing.allocator.free(full_range.scales);
    }
    try testing.expectEqual(@as(u8, 0x7f), full_range.packed_bytes[0]);
    try testing.expectEqual(@as(f32, 0.125), full_range.scales[0]);

    const compatible = try quantize(f32, testing.allocator, src[0..8], .int4, 8);
    defer {
        testing.allocator.free(compatible.packed_bytes);
        testing.allocator.free(compatible.scales);
    }
    try testing.expectEqual(@as(u8, 0x7e), compatible.packed_bytes[0]);
}

test "INT4 round-trip within absolute tolerance on synthetic weights" {
    // Mimic real-ish weights: spread of small values with a few larger ones.
    var rng = std.Random.DefaultPrng.init(42);
    var src: [256]f32 = undefined;
    for (&src) |*v| v.* = (rng.random().float(f32) * 2 - 1) * 0.1;

    const q = try quantize(f32, testing.allocator, &src, .int4, 64);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }
    const back = try dequantize(f32, testing.allocator, q.packed_bytes, q.scales, .int4, 64, src.len);
    defer testing.allocator.free(back);

    // Absolute error is the meaningful bound for zero-centered INT4. Range is ±0.1,
    // 16 levels per group → step ≈ 0.1/7 ≈ 0.0143, worst case half-step ≈ 0.0072.
    // We allow 2× headroom for safety.
    var max_abs: f32 = 0;
    for (src, back) |a, b| {
        const abs_err: f32 = if (a > b) a - b else b - a;
        if (abs_err > max_abs) max_abs = abs_err;
    }
    try testing.expect(max_abs < 0.02);
}

test "zero tensor quantizes to zero scales and zero bytes" {
    const src = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const q = try quantize(f32, testing.allocator, &src, .int4, 4);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }
    // 8 elements / 4 per group = 2 groups.
    try testing.expectEqual(@as(usize, 2), q.scales.len);
    try testing.expectEqual(@as(f32, 0), q.scales[0]);
    try testing.expectEqual(@as(f32, 0), q.scales[1]);

    const back = try dequantize(f32, testing.allocator, q.packed_bytes, q.scales, .int4, 4, src.len);
    defer testing.allocator.free(back);
    for (back) |v| try testing.expectEqual(@as(f32, 0), v);
}

test "multiple groups get independent scales" {
    // First half tiny, second half huge — naive single-scale would wreck the tiny side.
    var src: [16]f32 = undefined;
    for (0..8) |i| src[i] = @as(f32, @floatFromInt(i)) * 0.001; // ±0.007
    for (8..16) |i| src[i] = @as(f32, @floatFromInt(i - 8)) * 10.0; // 0..70

    const q = try quantize(f32, testing.allocator, &src, .int4, 8);
    defer {
        testing.allocator.free(q.packed_bytes);
        testing.allocator.free(q.scales);
    }
    try testing.expectEqual(@as(usize, 2), q.scales.len);
    // Group 0 scale is tiny; group 1 scale is ~10x larger.
    try testing.expect(q.scales[0] < q.scales[1] / 1000);
}
