//! INT4 packed weight data for on-the-fly matmul.
//!
//! When weights are stored as INT4 in the .glacier file (qio format),
//! this struct holds the raw packed bytes + per-group scales extracted
//! from the qio payload. forwardLayerCached uses linearInt4OnTheFly
//! to compute matmuls without ever materializing the f32 weight matrix.
//!
//! For each weight tensor (wq, wk, wv, wo, w_gate, w_up, w_down) we
//! store an optional Int4WeightData. When present, the decode path uses
//! it; when absent, it falls back to the f32 path.

const std = @import("std");

pub const PackedLayout = enum {
    /// Conventional row-major nibble stream.
    row_major,
    /// Four output rows tiled together; inside each K16 block, four-column
    /// chunks from all four rows are contiguous. This feeds NEON SDOT lanes
    /// without horizontal reductions while preserving 4-bit storage density.
    rows4_k16,
};

/// Physical branch order for the paired MLP producer. This is deliberately a
/// different type from `PackedLayout`: a pair byte is not a valid single-
/// projection nibble stream and must never reach a legacy matvec by accident.
pub const PairNibbleLayout = enum(u8) {
    /// One byte per logical coefficient position. The low nibble is gate and
    /// the high nibble is up; byte order follows the rows4/K16 nibble order.
    gate_low_up_high_rows4_k16 = 1,
};

/// Select one logical coefficient stream from a typed PairNibble view.
pub const PairBranch = enum {
    gate,
    up,
};

/// Typed view of a lossless gate/up INT4 pair. `paired_bytes.len` equals one
/// branch's logical element count: combining two four-bit streams preserves
/// their total payload size while enabling one sequential producer traversal.
/// FP16 scale pairs are `[row_tile][k_group][branch][row_lane]`.
pub const PairNibbleWeightData = struct {
    paired_bytes: []const u8,
    scales_f16_pairs: []const f16,
    group_size: u32,
    out_f: usize,
    in_f: usize,
    num_elements_per_branch: usize,
    geometry_commitment: u64,
    packed_layout: PairNibbleLayout = .gate_low_up_high_rows4_k16,
};

/// In-process layout contract for the first PairNibble representation. GLRT v2
/// binds this layout through a role-specific record and cryptographic payload
/// digest; executable-loader admission remains a separate, fail-closed gate.
pub const pair_nibble_abi: u64 = 0x4750_4e42_0000_0001;

/// Recompute the stable PairNibble geometry identity for a mapped runtime
/// record. Payload integrity belongs to GLRT; this commitment prevents valid
/// bytes from being rebound to a different layout or matrix shape in memory.
pub fn pairNibbleGeometryCommitment(
    layout: PairNibbleLayout,
    out_f: usize,
    in_f: usize,
    group_size: u32,
) !u64 {
    const out_u64 = std.math.cast(u64, out_f) orelse
        return error.InvalidShape;
    const in_u64 = std.math.cast(u64, in_f) orelse
        return error.InvalidShape;
    var hasher = std.hash.Wyhash.init(pair_nibble_abi);
    hasher.update(std.mem.asBytes(&layout));
    hasher.update(std.mem.asBytes(&out_u64));
    hasher.update(std.mem.asBytes(&in_u64));
    hasher.update(std.mem.asBytes(&group_size));
    return hasher.final();
}

pub const Int4WeightData = struct {
    /// Packed INT4 bytes: 2 weights per byte (low nibble first).
    packed_bytes: []const u8,
    /// Per-group f32 scales.
    scales: []const f32,
    /// Optional FP16 scale mirror for targets where half loads win.
    /// The normal loader leaves this empty; callers then use `scales`.
    scales_f16: []const f16 = &.{},
    /// Optional FP16 scale grid interleaved across groups of four output
    /// rows: [row_tile][k_group][row_lane]. This lets a rows4 kernel load
    /// and convert four otherwise-strided scales with one vector operation.
    scales_f16_rows4: []const f16 = &.{},
    /// Optional persistent signed-INT8 expansion for dot-product decode.
    /// This is a deliberate memory/throughput trade-off: each nibble is
    /// expanded once at load time, allowing SDOT kernels to skip nibble
    /// unpacking on hot MLP matrices. Empty keeps the compact INT4 path.
    expanded_i8: []const i8 = &.{},
    /// Number of elements per quantization group.
    group_size: u32,
    /// Exact number of logical weights. The final packed byte can contain a
    /// padding nibble, so this cannot be recovered from `packed_bytes.len`.
    num_elements: usize,
    /// Physical nibble order. Logical tensor and scale order stay row-major.
    packed_layout: PackedLayout = .row_major,

    pub fn numElements(self: Int4WeightData) usize {
        return self.num_elements;
    }
};

/// Reorder a mutable, owned row-major stream in place into four-row/K16
/// tiles. Only one four-row scratch tile is allocated, so model loading does
/// not retain a second weight copy. The caller must own mutable packed bytes
/// (the compact loader and benchmark both do).
pub fn withRows4K16Packing(
    allocator: std.mem.Allocator,
    weights: Int4WeightData,
    out_f: usize,
) !Int4WeightData {
    if (weights.packed_layout == .rows4_k16) return weights;
    if (out_f == 0 or out_f % 4 != 0 or weights.num_elements % out_f != 0 or
        weights.expanded_i8.len != 0)
        return error.InvalidShape;
    const in_f = weights.num_elements / out_f;
    if (in_f == 0 or in_f % 16 != 0 or weights.num_elements % 2 != 0 or
        weights.packed_bytes.len < weights.num_elements / 2)
        return error.InvalidShape;

    const tile_bytes = 2 * in_f;
    const scratch = try allocator.alloc(u8, tile_bytes);
    defer allocator.free(scratch);
    const packed_mut = @constCast(weights.packed_bytes);
    for (0..out_f / 4) |tile| {
        const tile_start = tile * tile_bytes;
        const destination = packed_mut[tile_start .. tile_start + tile_bytes];
        @memcpy(scratch, destination);
        @memset(destination, 0);
        for (0..4) |lane| {
            for (0..in_f) |col| {
                const source_nibble = lane * in_f + col;
                const block = col / 16;
                const chunk = (col % 16) / 4;
                const inner = col % 4;
                const destination_nibble = block * 64 + chunk * 16 + lane * 4 + inner;
                writeNibble(destination, destination_nibble, readNibble(scratch, source_nibble));
            }
        }
    }
    var out = weights;
    out.packed_layout = .rows4_k16;
    return out;
}

/// Translate a logical row/column into the physical nibble index.
pub inline fn packedNibbleIndex(
    layout: PackedLayout,
    row: usize,
    col: usize,
    row_width: usize,
) usize {
    return switch (layout) {
        .row_major => row * row_width + col,
        .rows4_k16 => blk: {
            const tile = row / 4;
            const lane = row % 4;
            const block = col / 16;
            const chunk = (col % 16) / 4;
            const inner = col % 4;
            break :blk tile * (4 * row_width) + block * 64 + chunk * 16 + lane * 4 + inner;
        },
    };
}

inline fn readNibble(bytes: []const u8, idx: usize) u8 {
    const byte = bytes[idx / 2];
    return if (idx & 1 == 0) byte & 0x0f else byte >> 4;
}

inline fn writeNibble(bytes: []u8, idx: usize, value: u8) void {
    const byte_idx = idx / 2;
    if (idx & 1 == 0) {
        bytes[byte_idx] = (bytes[byte_idx] & 0xf0) | (value & 0x0f);
    } else {
        bytes[byte_idx] = (bytes[byte_idx] & 0x0f) | ((value & 0x0f) << 4);
    }
}

fn byteSlicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

/// Return the exact stored four-bit code for one logical branch coefficient.
/// This scalar accessor is the portable oracle for paired SIMD kernels.
pub fn pairNibbleAt(
    weights: PairNibbleWeightData,
    branch: PairBranch,
    row: usize,
    col: usize,
) !u8 {
    try validatePairNibble(weights);
    if (row >= weights.out_f or col >= weights.in_f)
        return error.InvalidShape;
    const physical = packedNibbleIndex(.rows4_k16, row, col, weights.in_f);
    const pair = weights.paired_bytes[physical];
    return switch (branch) {
        .gate => pair & 0x0f,
        .up => pair >> 4,
    };
}

/// Validate the complete typed PairNibble geometry and exact destination
/// extents. Exact lengths prevent a larger backing view from being silently
/// reinterpreted with another rows4 shape.
pub fn validatePairNibble(weights: PairNibbleWeightData) !void {
    if (weights.packed_layout != .gate_low_up_high_rows4_k16 or
        weights.out_f == 0 or weights.out_f % 4 != 0 or
        weights.in_f == 0 or weights.in_f % 16 != 0 or
        (weights.group_size != 8 and weights.group_size != 16) or
        weights.in_f % weights.group_size != 0)
        return error.InvalidShape;
    const expected = std.math.mul(
        usize,
        weights.out_f,
        weights.in_f,
    ) catch return error.InvalidShape;
    const scale_count = expected / weights.group_size;
    const paired_scale_count = std.math.mul(
        usize,
        scale_count,
        2,
    ) catch return error.InvalidShape;
    if (weights.num_elements_per_branch != expected or
        weights.paired_bytes.len != expected or
        weights.scales_f16_pairs.len != paired_scale_count or
        weights.geometry_commitment != try pairNibbleGeometryCommitment(
            weights.packed_layout,
            weights.out_f,
            weights.in_f,
            weights.group_size,
        ))
        return error.InvalidShape;
}

/// Losslessly pair two rows4/K16 streams into caller-owned destinations.
/// Pairing never requantizes: coefficient nibbles and FP16 scale bits are
/// copied verbatim. The explicit output buffers make ownership suitable for a
/// prepared-image arena and avoid hiding another full-model allocation.
pub fn pairRows4K16(
    gate: Int4WeightData,
    up: Int4WeightData,
    out_f: usize,
    paired_bytes: []u8,
    paired_scales: []f16,
) !PairNibbleWeightData {
    if (out_f == 0 or out_f % 4 != 0 or
        gate.packed_layout != .rows4_k16 or
        up.packed_layout != .rows4_k16 or
        gate.group_size != up.group_size or
        (gate.group_size != 8 and gate.group_size != 16) or
        gate.num_elements == 0 or gate.num_elements != up.num_elements or
        gate.num_elements % out_f != 0 or
        gate.expanded_i8.len != 0 or up.expanded_i8.len != 0)
        return error.InvalidShape;
    const in_f = gate.num_elements / out_f;
    if (in_f == 0 or in_f % 16 != 0 or
        gate.num_elements % gate.group_size != 0)
        return error.InvalidShape;
    const packed_count = gate.num_elements / 2;
    const scale_count = gate.num_elements / gate.group_size;
    const paired_scale_count = std.math.mul(usize, scale_count, 2) catch
        return error.InvalidShape;
    const geometry_commitment = try pairNibbleGeometryCommitment(
        .gate_low_up_high_rows4_k16,
        out_f,
        in_f,
        gate.group_size,
    );
    if (gate.packed_bytes.len < packed_count or
        up.packed_bytes.len < packed_count or
        gate.scales_f16_rows4.len < scale_count or
        up.scales_f16_rows4.len < scale_count or
        paired_bytes.len != gate.num_elements or
        paired_scales.len != paired_scale_count)
        return error.InvalidShape;

    const paired_byte_view: []const u8 = paired_bytes;
    const paired_scale_view = std.mem.sliceAsBytes(paired_scales);
    const gate_byte_view = gate.packed_bytes[0..packed_count];
    const up_byte_view = up.packed_bytes[0..packed_count];
    const gate_scale_view = std.mem.sliceAsBytes(
        gate.scales_f16_rows4[0..scale_count],
    );
    const up_scale_view = std.mem.sliceAsBytes(
        up.scales_f16_rows4[0..scale_count],
    );
    const gate_f32_scale_view = std.mem.sliceAsBytes(gate.scales);
    const up_f32_scale_view = std.mem.sliceAsBytes(up.scales);
    const gate_f16_scale_view = std.mem.sliceAsBytes(gate.scales_f16);
    const up_f16_scale_view = std.mem.sliceAsBytes(up.scales_f16);
    if (byteSlicesOverlap(paired_byte_view, paired_scale_view) or
        byteSlicesOverlap(paired_byte_view, gate_byte_view) or
        byteSlicesOverlap(paired_byte_view, up_byte_view) or
        byteSlicesOverlap(paired_byte_view, gate_scale_view) or
        byteSlicesOverlap(paired_byte_view, up_scale_view) or
        byteSlicesOverlap(paired_byte_view, gate_f32_scale_view) or
        byteSlicesOverlap(paired_byte_view, up_f32_scale_view) or
        byteSlicesOverlap(paired_byte_view, gate_f16_scale_view) or
        byteSlicesOverlap(paired_byte_view, up_f16_scale_view) or
        byteSlicesOverlap(paired_scale_view, gate_byte_view) or
        byteSlicesOverlap(paired_scale_view, up_byte_view) or
        byteSlicesOverlap(paired_scale_view, gate_scale_view) or
        byteSlicesOverlap(paired_scale_view, up_scale_view) or
        byteSlicesOverlap(paired_scale_view, gate_f32_scale_view) or
        byteSlicesOverlap(paired_scale_view, up_f32_scale_view) or
        byteSlicesOverlap(paired_scale_view, gate_f16_scale_view) or
        byteSlicesOverlap(paired_scale_view, up_f16_scale_view))
        return error.InvalidShape;

    for (paired_bytes, 0..) |*pair, physical_nibble| {
        pair.* = readNibble(gate.packed_bytes, physical_nibble) |
            (readNibble(up.packed_bytes, physical_nibble) << 4);
    }
    const scales_per_row = in_f / gate.group_size;
    for (0..out_f / 4) |tile| {
        for (0..scales_per_row) |group| {
            const source = (tile * scales_per_row + group) * 4;
            const destination = (tile * scales_per_row + group) * 8;
            @memcpy(paired_scales[destination..][0..4], gate.scales_f16_rows4[source..][0..4]);
            @memcpy(paired_scales[destination + 4 ..][0..4], up.scales_f16_rows4[source..][0..4]);
        }
    }
    return .{
        .paired_bytes = paired_bytes,
        .scales_f16_pairs = paired_scales,
        .group_size = gate.group_size,
        .out_f = out_f,
        .in_f = in_f,
        .num_elements_per_branch = gate.num_elements,
        .geometry_commitment = geometry_commitment,
    };
}

/// Materialize an FP16 mirror of the scale stream for Q8 decode experiments.
/// FP32 scales remain the portable/reference representation.
pub fn withF16Scales(
    allocator: std.mem.Allocator,
    weights: Int4WeightData,
) !Int4WeightData {
    if (weights.scales_f16.len != 0) return weights;
    const scales_f16 = try allocator.alloc(f16, weights.scales.len);
    for (weights.scales, scales_f16) |src, *dst| dst.* = @floatCast(src);
    var out = weights;
    out.scales_f16 = scales_f16;
    return out;
}

/// Build the four-row-interleaved FP16 scale grid used by the experimental
/// output-lane SIMD kernel. `out_f` must describe complete rows.
pub fn withRows4F16Scales(
    allocator: std.mem.Allocator,
    weights: Int4WeightData,
    out_f: usize,
) !Int4WeightData {
    if (weights.scales_f16_rows4.len != 0) return weights;
    if (out_f == 0 or out_f % 4 != 0 or weights.scales.len % out_f != 0)
        return error.InvalidShape;
    const scales_per_row = weights.scales.len / out_f;
    const rows4 = try allocator.alloc(f16, weights.scales.len);
    for (0..out_f / 4) |tile| {
        for (0..scales_per_row) |group| {
            for (0..4) |lane| {
                const src = (tile * 4 + lane) * scales_per_row + group;
                const dst = (tile * scales_per_row + group) * 4 + lane;
                rows4[dst] = @floatCast(weights.scales[src]);
            }
        }
    }
    var out = weights;
    out.scales_f16_rows4 = rows4;
    return out;
}

/// Extract packed_bytes + scales from a qio-encoded payload.
/// Returns null if the payload is not INT4-quantized.
pub fn extractFromQio(arena: std.mem.Allocator, payload: []const u8) !?Int4WeightData {
    const qio = @import("model/qio.zig");
    if (payload.len < qio.SUB_HEADER_SIZE) return null;
    const magic = std.mem.readInt(u32, payload[0..4], .little);
    if (magic != qio.PAYLOAD_MAGIC) return null;

    const hdr = qio.readQuantHeader(payload) catch return null;
    if (hdr.precision != .int4) return null;
    if (hdr.group_size == 0) return null;

    const num_elements: usize = hdr.num_elements;
    const group_size: usize = hdr.group_size;
    const num_groups = ceilDiv(num_elements, group_size);
    const scales_off = qio.SUB_HEADER_SIZE;
    const scales_bytes = std.math.mul(usize, num_groups, @sizeOf(f32)) catch return null;
    const packed_off = std.math.add(usize, scales_off, scales_bytes) catch return null;
    if (payload.len < packed_off) return null;

    // Copy scales into arena. The CPU fast path keeps the on-disk FP32 scale
    // stream; an FP16 mirror is optional and is not materialized by default
    // because it increases the resident set substantially on Apple M1.
    const scales = try arena.alloc(f32, num_groups);
    for (0..num_groups) |i| {
        const off = scales_off + i * @sizeOf(f32);
        scales[i] = @bitCast(std.mem.readInt(u32, payload[off..][0..4], .little));
    }

    // Packed bytes start after scales.
    const packed_len = ceilDiv(num_elements, 2);
    if (payload.len - packed_off < packed_len) return null;

    const packed_bytes = try arena.dupe(u8, payload[packed_off..][0..packed_len]);

    return .{
        .packed_bytes = packed_bytes,
        .scales = scales,
        .group_size = hdr.group_size,
        .num_elements = hdr.num_elements,
    };
}

/// Expand the logical INT4 values to signed INT8 once, retaining the same
/// per-group FP32 scales. The returned slice is arena-owned and shares all
/// immutable fields with `weights`.
pub fn withExpandedI8(arena: std.mem.Allocator, weights: Int4WeightData) !Int4WeightData {
    if (weights.packed_layout != .row_major) return error.InvalidLayout;
    const expanded = try arena.alloc(i8, weights.num_elements);
    for (expanded, 0..) |*dst, idx| {
        const packed_byte = weights.packed_bytes[idx / 2];
        const nibble: u8 = if (idx & 1 == 0) packed_byte & 0x0f else packed_byte >> 4;
        dst.* = @intCast(@as(i16, nibble) - 7);
    }
    var out = weights;
    out.expanded_i8 = expanded;
    return out;
}

inline fn ceilDiv(numerator: usize, denominator: usize) usize {
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

test "INT4 to signed INT8 expansion preserves nibble values" {
    const packed_bytes = [_]u8{ 0x80, 0x0f };
    const scales = [_]f32{1.0};
    const weights = Int4WeightData{
        .packed_bytes = &packed_bytes,
        .scales = &scales,
        .group_size = 4,
        .num_elements = 4,
    };
    const expanded = try withExpandedI8(std.testing.allocator, weights);
    defer std.testing.allocator.free(expanded.expanded_i8);
    try std.testing.expectEqualSlices(i8, &.{ -7, 1, 8, -7 }, expanded.expanded_i8);
}

test "FP16 scale mirror preserves scale ordering" {
    const weights: Int4WeightData = .{
        .packed_bytes = &.{ 0x70, 0xf1 },
        .scales = &.{ 0.125, 0.25 },
        .group_size = 2,
        .num_elements = 4,
    };
    const mirrored = try withF16Scales(std.testing.allocator, weights);
    defer std.testing.allocator.free(mirrored.scales_f16);
    try std.testing.expectEqual(@as(f16, 0.125), mirrored.scales_f16[0]);
    try std.testing.expectEqual(@as(f16, 0.25), mirrored.scales_f16[1]);
}

test "rows4 FP16 scale grid interleaves output lanes" {
    const weights: Int4WeightData = .{
        .packed_bytes = &([_]u8{0} ** 8),
        .scales = &.{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .group_size = 2,
        .num_elements = 16,
    };
    const interleaved = try withRows4F16Scales(std.testing.allocator, weights, 4);
    defer std.testing.allocator.free(interleaved.scales_f16_rows4);
    try std.testing.expectEqualSlices(
        f16,
        &.{ 1, 3, 5, 7, 2, 4, 6, 8 },
        interleaved.scales_f16_rows4,
    );
}

test "rows4 K16 packing preserves every logical nibble" {
    const out_f = 4;
    const in_f = 32;
    var packed_storage = [_]u8{0} ** (out_f * in_f / 2);
    for (0..out_f) |row| {
        for (0..in_f) |col| {
            writeNibble(&packed_storage, row * in_f + col, @intCast(row * 4 + col % 4));
        }
    }
    const weights: Int4WeightData = .{
        .packed_bytes = &packed_storage,
        .scales = &.{1},
        .group_size = 128,
        .num_elements = out_f * in_f,
    };
    const tiled = try withRows4K16Packing(std.testing.allocator, weights, out_f);
    try std.testing.expectEqual(PackedLayout.rows4_k16, tiled.packed_layout);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe },
        tiled.packed_bytes[0..8],
    );
    for (0..out_f) |row| {
        for (0..in_f) |col| {
            const physical = packedNibbleIndex(tiled.packed_layout, row, col, in_f);
            try std.testing.expectEqual(
                @as(u8, @intCast(row * 4 + col % 4)),
                readNibble(tiled.packed_bytes, physical),
            );
        }
    }
}

test "PairNibble exhaustively preserves all gate and up code pairs" {
    const out_f: usize = 4;
    const in_f: usize = 16;
    const elements = out_f * in_f;
    var gate_packed = [_]u8{0} ** (elements / 2);
    var up_packed = [_]u8{0} ** (elements / 2);
    const gate_scales = [_]f16{1.0} ** (elements / 8);
    const up_scales = [_]f16{2.0} ** (elements / 8);
    var pair_bytes: [elements]u8 = undefined;
    var pair_scales: [elements / 4]f16 = undefined;

    for (0..16) |gate_code| {
        for (0..16) |up_code| {
            @memset(&gate_packed, @as(u8, @intCast(gate_code | gate_code << 4)));
            @memset(&up_packed, @as(u8, @intCast(up_code | up_code << 4)));
            const paired = try pairRows4K16(
                .{
                    .packed_bytes = &gate_packed,
                    .scales = &.{},
                    .scales_f16_rows4 = &gate_scales,
                    .group_size = 8,
                    .num_elements = elements,
                    .packed_layout = .rows4_k16,
                },
                .{
                    .packed_bytes = &up_packed,
                    .scales = &.{},
                    .scales_f16_rows4 = &up_scales,
                    .group_size = 8,
                    .num_elements = elements,
                    .packed_layout = .rows4_k16,
                },
                out_f,
                &pair_bytes,
                &pair_scales,
            );
            const expected_pair: u8 = @intCast(gate_code | up_code << 4);
            for (paired.paired_bytes) |pair|
                try std.testing.expectEqual(expected_pair, pair);
            try std.testing.expectEqual(
                @as(u8, @intCast(gate_code)),
                try pairNibbleAt(paired, .gate, 3, 15),
            );
            try std.testing.expectEqual(
                @as(u8, @intCast(up_code)),
                try pairNibbleAt(paired, .up, 3, 15),
            );
        }
    }
}

test "PairNibble preserves rows4 coordinates and FP16 scale bits" {
    const out_f: usize = 8;
    const in_f: usize = 32;
    const elements = out_f * in_f;
    var gate_packed = [_]u8{0} ** (elements / 2);
    var up_packed = [_]u8{0} ** (elements / 2);
    for (0..out_f) |row| {
        for (0..in_f) |col| {
            const physical = packedNibbleIndex(.rows4_k16, row, col, in_f);
            writeNibble(&gate_packed, physical, @intCast((row * 3 + col) % 16));
            writeNibble(&up_packed, physical, @intCast((row + col * 5) % 16));
        }
    }
    const scale_count = elements / 16;
    var gate_scales: [scale_count]f16 = undefined;
    var up_scales: [scale_count]f16 = undefined;
    for (&gate_scales, &up_scales, 0..) |*gate_scale, *up_scale, index| {
        gate_scale.* = @bitCast(@as(u16, @intCast(0x2000 + index)));
        up_scale.* = @bitCast(@as(u16, @intCast(0x6000 + index)));
    }
    var pair_bytes: [elements]u8 = undefined;
    var pair_scales: [scale_count * 2]f16 = undefined;
    const paired = try pairRows4K16(
        .{
            .packed_bytes = &gate_packed,
            .scales = &.{},
            .scales_f16_rows4 = &gate_scales,
            .group_size = 16,
            .num_elements = elements,
            .packed_layout = .rows4_k16,
        },
        .{
            .packed_bytes = &up_packed,
            .scales = &.{},
            .scales_f16_rows4 = &up_scales,
            .group_size = 16,
            .num_elements = elements,
            .packed_layout = .rows4_k16,
        },
        out_f,
        &pair_bytes,
        &pair_scales,
    );

    for (0..out_f) |row| {
        for (0..in_f) |col| {
            try std.testing.expectEqual(
                @as(u8, @intCast((row * 3 + col) % 16)),
                try pairNibbleAt(paired, .gate, row, col),
            );
            try std.testing.expectEqual(
                @as(u8, @intCast((row + col * 5) % 16)),
                try pairNibbleAt(paired, .up, row, col),
            );
        }
    }
    const scales_per_row = in_f / 16;
    for (0..out_f / 4) |tile| {
        for (0..scales_per_row) |group| {
            const source = (tile * scales_per_row + group) * 4;
            const destination = (tile * scales_per_row + group) * 8;
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(gate_scales[source..][0..4]),
                std.mem.sliceAsBytes(pair_scales[destination..][0..4]),
            );
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(up_scales[source..][0..4]),
                std.mem.sliceAsBytes(pair_scales[destination + 4 ..][0..4]),
            );
        }
    }
}

test "PairNibble rejects mismatched layouts groups and destination extents" {
    const elements: usize = 64;
    const packed_codes = [_]u8{0x77} ** (elements / 2);
    const scales = [_]f16{1.0} ** (elements / 8);
    var pair_bytes: [elements]u8 = undefined;
    var pair_scales: [elements / 4]f16 = undefined;
    const valid: Int4WeightData = .{
        .packed_bytes = &packed_codes,
        .scales = &.{},
        .scales_f16_rows4 = &scales,
        .group_size = 8,
        .num_elements = elements,
        .packed_layout = .rows4_k16,
    };
    var row_major = valid;
    row_major.packed_layout = .row_major;
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(row_major, valid, 4, &pair_bytes, &pair_scales),
    );
    var g16 = valid;
    g16.group_size = 16;
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(valid, g16, 4, &pair_bytes, &pair_scales),
    );
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(valid, valid, 4, pair_bytes[0 .. elements - 1], &pair_scales),
    );

    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(valid, valid, 0, &pair_bytes, &pair_scales),
    );
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(valid, valid, 8, &pair_bytes, &pair_scales),
    );
    var invalid_group = valid;
    invalid_group.group_size = 7;
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(invalid_group, invalid_group, 4, &pair_bytes, &pair_scales),
    );
    var expanded = valid;
    expanded.expanded_i8 = &.{1};
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(expanded, valid, 4, &pair_bytes, &pair_scales),
    );
    var short_packed = valid;
    short_packed.packed_bytes = packed_codes[0 .. packed_codes.len - 1];
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(short_packed, valid, 4, &pair_bytes, &pair_scales),
    );
    var short_scales = valid;
    short_scales.scales_f16_rows4 = scales[0 .. scales.len - 1];
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(short_scales, valid, 4, &pair_bytes, &pair_scales),
    );
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(valid, valid, 4, &pair_bytes, pair_scales[0 .. pair_scales.len - 1]),
    );
}

test "PairNibble binds exact rows4 geometry and validates its complete view" {
    const out_f: usize = 8;
    const in_f: usize = 32;
    const elements = out_f * in_f;
    const packed_codes = [_]u8{0x87} ** (elements / 2);
    const scales = [_]f16{1.0} ** (elements / 16);
    var pair_bytes: [elements]u8 = undefined;
    var pair_scales: [elements / 8]f16 = undefined;
    const source: Int4WeightData = .{
        .packed_bytes = &packed_codes,
        .scales = &.{},
        .scales_f16_rows4 = &scales,
        .group_size = 16,
        .num_elements = elements,
        .packed_layout = .rows4_k16,
    };
    const paired = try pairRows4K16(
        source,
        source,
        out_f,
        &pair_bytes,
        &pair_scales,
    );
    try validatePairNibble(paired);
    try std.testing.expectEqual(out_f, paired.out_f);
    try std.testing.expectEqual(in_f, paired.in_f);

    var reinterpreted = paired;
    reinterpreted.out_f = 4;
    reinterpreted.in_f = 64;
    try std.testing.expectError(
        error.InvalidShape,
        pairNibbleAt(reinterpreted, .gate, 0, 32),
    );
    try std.testing.expectError(
        error.InvalidShape,
        pairNibbleAt(paired, .gate, out_f, 0),
    );
    try std.testing.expectError(
        error.InvalidShape,
        pairNibbleAt(paired, .up, 0, in_f),
    );

    var truncated_bytes = paired;
    truncated_bytes.paired_bytes = pair_bytes[0 .. pair_bytes.len - 1];
    try std.testing.expectError(
        error.InvalidShape,
        validatePairNibble(truncated_bytes),
    );
    var truncated_scales = paired;
    truncated_scales.scales_f16_pairs = pair_scales[0 .. pair_scales.len - 1];
    try std.testing.expectError(
        error.InvalidShape,
        validatePairNibble(truncated_scales),
    );
    const overflowed: PairNibbleWeightData = .{
        .paired_bytes = &.{},
        .scales_f16_pairs = &.{},
        .group_size = 8,
        .out_f = std.math.maxInt(usize) - 3,
        .in_f = 16,
        .num_elements_per_branch = 0,
        .geometry_commitment = 0,
    };
    try std.testing.expectError(
        error.InvalidShape,
        validatePairNibble(overflowed),
    );
}

test "PairNibble preserves asymmetric g8 scale tile group branch and lane order" {
    const out_f: usize = 8;
    const in_f: usize = 16;
    const elements = out_f * in_f;
    const packed_codes = [_]u8{0x77} ** (elements / 2);
    const scale_count = elements / 8;
    var gate_scales: [scale_count]f16 = undefined;
    var up_scales: [scale_count]f16 = undefined;
    for (&gate_scales, &up_scales, 0..) |*gate_scale, *up_scale, index| {
        gate_scale.* = @bitCast(@as(u16, @intCast(0x2100 + index)));
        up_scale.* = @bitCast(@as(u16, @intCast(0x6100 + index)));
    }
    const gate: Int4WeightData = .{
        .packed_bytes = &packed_codes,
        .scales = &.{},
        .scales_f16_rows4 = &gate_scales,
        .group_size = 8,
        .num_elements = elements,
        .packed_layout = .rows4_k16,
    };
    var up = gate;
    up.scales_f16_rows4 = &up_scales;
    var pair_bytes: [elements]u8 = undefined;
    var pair_scales: [scale_count * 2]f16 = undefined;
    _ = try pairRows4K16(
        gate,
        up,
        out_f,
        &pair_bytes,
        &pair_scales,
    );
    const groups_per_row = in_f / 8;
    for (0..out_f / 4) |tile| {
        for (0..groups_per_row) |group| {
            const source = (tile * groups_per_row + group) * 4;
            const destination = (tile * groups_per_row + group) * 8;
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(gate_scales[source..][0..4]),
                std.mem.sliceAsBytes(pair_scales[destination..][0..4]),
            );
            try std.testing.expectEqualSlices(
                u8,
                std.mem.sliceAsBytes(up_scales[source..][0..4]),
                std.mem.sliceAsBytes(pair_scales[destination + 4 ..][0..4]),
            );
        }
    }
}

test "PairNibble rejects every source and destination alias before writes" {
    const out_f: usize = 4;
    const in_f: usize = 16;
    const elements = out_f * in_f;
    const packed_count = elements / 2;
    const scale_count = elements / 8;
    const separate_packed = [_]u8{0x77} ** packed_count;
    const separate_scales = [_]f16{1.0} ** scale_count;
    const valid: Int4WeightData = .{
        .packed_bytes = &separate_packed,
        .scales = &.{},
        .scales_f16_rows4 = &separate_scales,
        .group_size = 8,
        .num_elements = elements,
        .packed_layout = .rows4_k16,
    };
    var pair_bytes: [elements]u8 = [_]u8{0xa5} ** elements;
    var pair_scales: [scale_count * 2]f16 = [_]f16{3.0} ** (scale_count * 2);

    var packed_backing = [_]u8{0x77} ** (elements + packed_count);
    var packed_alias = valid;
    packed_alias.packed_bytes = packed_backing[0..packed_count];
    const packed_snapshot = packed_backing;
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(
            packed_alias,
            valid,
            out_f,
            packed_backing[0..elements],
            &pair_scales,
        ),
    );
    try std.testing.expectEqualSlices(u8, &packed_snapshot, &packed_backing);

    var rows4_scale_backing = [_]f16{2.0} ** (scale_count * 3);
    var scale_alias = valid;
    scale_alias.scales_f16_rows4 = rows4_scale_backing[0..scale_count];
    const rows4_scale_snapshot = rows4_scale_backing;
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(
            scale_alias,
            valid,
            out_f,
            &pair_bytes,
            rows4_scale_backing[0 .. scale_count * 2],
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&rows4_scale_snapshot),
        std.mem.asBytes(&rows4_scale_backing),
    );

    var output_backing: [elements + scale_count * 2 * @sizeOf(f16)]u8 align(@alignOf(f16)) =
        [_]u8{0x6b} ** (elements + scale_count * 2 * @sizeOf(f16));
    const output_snapshot = output_backing;
    const overlapping_scales = std.mem.bytesAsSlice(
        f16,
        output_backing[elements - 16 .. elements - 16 + scale_count * 2 * @sizeOf(f16)],
    );
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(
            valid,
            valid,
            out_f,
            output_backing[0..elements],
            overlapping_scales,
        ),
    );
    try std.testing.expectEqualSlices(u8, &output_snapshot, &output_backing);

    var legacy_f32_scales = [_]f32{4.0} ** (elements / @sizeOf(f32));
    var legacy_f32_alias = valid;
    legacy_f32_alias.scales = &legacy_f32_scales;
    const legacy_f32_snapshot = legacy_f32_scales;
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(
            legacy_f32_alias,
            valid,
            out_f,
            std.mem.sliceAsBytes(&legacy_f32_scales)[0..elements],
            &pair_scales,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&legacy_f32_snapshot),
        std.mem.asBytes(&legacy_f32_scales),
    );

    var legacy_f16_scales = [_]f16{5.0} ** (elements / @sizeOf(f16));
    var legacy_f16_alias = valid;
    legacy_f16_alias.scales_f16 = legacy_f16_scales[0..scale_count];
    const legacy_f16_snapshot = legacy_f16_scales;
    try std.testing.expectError(
        error.InvalidShape,
        pairRows4K16(
            legacy_f16_alias,
            valid,
            out_f,
            std.mem.sliceAsBytes(&legacy_f16_scales)[0..elements],
            &pair_scales,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&legacy_f16_snapshot),
        std.mem.asBytes(&legacy_f16_scales),
    );

    var adjacent_backing: [elements + scale_count * 2 * @sizeOf(f16)]u8 align(@alignOf(f16)) =
        undefined;
    const adjacent_scales = std.mem.bytesAsSlice(
        f16,
        adjacent_backing[elements..],
    );
    const adjacent = try pairRows4K16(
        valid,
        valid,
        out_f,
        adjacent_backing[0..elements],
        adjacent_scales,
    );
    try validatePairNibble(adjacent);
}
