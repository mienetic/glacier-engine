//! Quant-aware page payload IO.
//!
//! A page's on-disk payload (the bytes referenced by PageEntry.data_offset)
//! has one of two shapes:
//!
//!   1. Raw (precision = FP16/BF16): the source bytes, untouched.
//!   2. Quantized (precision = INT4/INT8): a small header + scales + packed:
//!
//!      ┌──────────────────────────────────────────────────────────────┐
//!      │ u32 magic          = 0x514F4954 ("QOIT")                     │
//!      │ u32 num_elements                                              │
//!      │ u32 group_size                                               │
//!      │ u8  precision      (0 = INT8, 1 = INT4)                      │
//!      │ u8  reserved[3]                                               │
//!      │ f32 scales[num_groups]                                       │
//!      │ u8  packed[(num_elements * bits + 7) / 8]                    │
//!      └──────────────────────────────────────────────────────────────┘
//!
//! The 16-byte sub-header is fixed so a dequant kernel can stream scales
//! and weights separately without parsing variable-length data. Magic
//! lets a reader detect the layout without consulting PageEntry.precision
//! (defensive; useful when payloads are copied out of context).

const std = @import("std");
const quant = @import("core").quant;

pub const PAYLOAD_MAGIC: u32 = 0x514F4954; // "QOIT"
pub const SUB_HEADER_SIZE: usize = 16;

pub const Layout = enum { raw, quantized };

/// Inspect the first 4 bytes of a payload to decide how to read it.
pub fn detectLayout(first_bytes: []const u8) Layout {
    if (first_bytes.len >= 4) {
        const m = std.mem.readInt(u32, first_bytes[0..4], .little);
        if (m == PAYLOAD_MAGIC) return .quantized;
    }
    return .raw;
}

pub const QuantHeader = struct {
    magic: u32,
    num_elements: u32,
    group_size: u32,
    precision: quant.QuantPrecision,
};

/// Read the 16-byte sub-header at the start of a quantized payload.
pub fn readQuantHeader(buf: []const u8) !QuantHeader {
    if (buf.len < SUB_HEADER_SIZE) return error.TruncatedHeader;
    const m = std.mem.readInt(u32, buf[0..4], .little);
    if (m != PAYLOAD_MAGIC) return error.BadMagic;
    const num_elements = std.mem.readInt(u32, buf[4..8], .little);
    const group_size = std.mem.readInt(u32, buf[8..12], .little);
    if (group_size == 0) return error.BadGroupSize;
    const prec_raw = buf[12];
    const precision: quant.QuantPrecision = switch (prec_raw) {
        0 => .int8,
        1 => .int4,
        else => return error.BadPrecision,
    };
    return .{
        .magic = m,
        .num_elements = num_elements,
        .group_size = group_size,
        .precision = precision,
    };
}

/// Build the full quantized payload for one page: sub-header + scales + packed.
/// `src` is the *flat source element array* the page represents (e.g. a slice
/// of FP16 weights). The returned bytes are owned by the caller.
pub fn encodePage(
    comptime SrcDType: type,
    allocator: std.mem.Allocator,
    src: []const SrcDType,
    precision: quant.QuantPrecision,
    group_size: u32,
) ![]u8 {
    const q = try quant.quantize(SrcDType, allocator, src, precision, group_size);
    defer {
        allocator.free(q.packed_bytes);
        allocator.free(q.scales);
    }

    const scales_bytes = try std.math.mul(usize, q.scales.len, @sizeOf(f32));
    const payload_bytes = try std.math.add(usize, scales_bytes, q.packed_bytes.len);
    const total = try std.math.add(usize, SUB_HEADER_SIZE, payload_bytes);
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    // Sub-header.
    std.mem.writeInt(u32, out[0..4], PAYLOAD_MAGIC, .little);
    std.mem.writeInt(u32, out[4..8], @intCast(src.len), .little);
    std.mem.writeInt(u32, out[8..12], group_size, .little);
    out[12] = @intFromEnum(precision);
    out[13] = 0;
    out[14] = 0;
    out[15] = 0;

    // Scales.
    var i: usize = 0;
    while (i < q.scales.len) : (i += 1) {
        const off = SUB_HEADER_SIZE + i * @sizeOf(f32);
        std.mem.writeInt(u32, out[off..][0..4], @bitCast(q.scales[i]), .little);
    }

    // Packed weights.
    const packed_off = SUB_HEADER_SIZE + scales_bytes;
    @memcpy(out[packed_off..], q.packed_bytes);

    return out;
}

/// Decode a quantized page payload back to a flat element array. Caller owns.
pub fn decodePage(
    comptime DstDType: type,
    allocator: std.mem.Allocator,
    payload: []const u8,
) ![]DstDType {
    const hdr = try readQuantHeader(payload);
    const num_elements: usize = hdr.num_elements;
    const group_size: usize = hdr.group_size;
    const num_groups = ceilDiv(num_elements, group_size);
    const scales_off = SUB_HEADER_SIZE;
    const scales_bytes = std.math.mul(usize, num_groups, @sizeOf(f32)) catch
        return error.InvalidPayloadSize;
    const packed_off = std.math.add(usize, scales_off, scales_bytes) catch
        return error.InvalidPayloadSize;
    if (payload.len < packed_off) return error.TruncatedScales;

    const bits: usize = switch (hdr.precision) {
        .int8 => 8,
        .int4 => 4,
    };
    const packed_bits = std.math.mul(usize, num_elements, bits) catch
        return error.InvalidPayloadSize;
    const packed_len = ceilDiv(packed_bits, 8);
    if (payload.len - packed_off < packed_len) return error.TruncatedPacked;

    const scales = try allocator.alloc(f32, num_groups);
    defer allocator.free(scales);
    var i: usize = 0;
    while (i < num_groups) : (i += 1) {
        const off = scales_off + i * @sizeOf(f32);
        scales[i] = @bitCast(std.mem.readInt(u32, payload[off..][0..4], .little));
    }

    const packed_bytes = payload[packed_off..][0..packed_len];

    return try quant.dequantize(
        DstDType,
        allocator,
        packed_bytes,
        scales,
        hdr.precision,
        hdr.group_size,
        hdr.num_elements,
    );
}

inline fn ceilDiv(numerator: usize, denominator: usize) usize {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "encode/decode round-trip INT4 matches direct quant" {
    var rng = std.Random.DefaultPrng.init(7);
    var src: [128]f32 = undefined;
    for (&src) |*v| v.* = (rng.random().float(f32) * 2 - 1) * 0.5;

    const payload = try encodePage(f32, testing.allocator, &src, .int4, 32);
    defer testing.allocator.free(payload);

    // Header looks right.
    const hdr = try readQuantHeader(payload);
    try testing.expectEqual(@as(u32, 128), hdr.num_elements);
    try testing.expectEqual(@as(u32, 32), hdr.group_size);
    try testing.expectEqual(quant.QuantPrecision.int4, hdr.precision);

    // Decode matches within INT4 tolerance.
    const back = try decodePage(f32, testing.allocator, payload);
    defer testing.allocator.free(back);
    var max_abs: f32 = 0;
    for (src, back) |a, b| {
        const err: f32 = if (a > b) a - b else b - a;
        if (err > max_abs) max_abs = err;
    }
    // Range ±0.5, INT4 step ≈ 0.5/7 ≈ 0.0714 → half-step ≈ 0.036.
    try testing.expect(max_abs < 0.06);
}

test "detectLayout recognizes raw vs quantized payloads" {
    try testing.expectEqual(Layout.raw, detectLayout(&[_]u8{ 1, 2, 3, 4 }));
    var magic_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &magic_buf, PAYLOAD_MAGIC, .little);
    try testing.expectEqual(Layout.quantized, detectLayout(&magic_buf));
}

test "decode rejects payload with bad magic" {
    var bad: [SUB_HEADER_SIZE]u8 = undefined;
    @memset(&bad, 0);
    try testing.expectError(error.BadMagic, readQuantHeader(&bad));
}

test "decode rejects zero group size and truncated packed bytes" {
    var header: [SUB_HEADER_SIZE]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], PAYLOAD_MAGIC, .little);
    std.mem.writeInt(u32, header[4..8], 8, .little);
    header[12] = @intFromEnum(quant.QuantPrecision.int4);
    try testing.expectError(error.BadGroupSize, readQuantHeader(&header));

    const encoded = try encodePage(f32, testing.allocator, &([_]f32{1} ** 8), .int4, 4);
    defer testing.allocator.free(encoded);
    try testing.expectError(
        error.TruncatedPacked,
        decodePage(f32, testing.allocator, encoded[0 .. encoded.len - 1]),
    );
}
