//! Scalar oracle for progressively decoding Glacier's offset-binary INT4.
//!
//! A stored nibble `u` represents the signed value `u - 7`.  The exact
//! value is split into centered 1 + 1 + 2-bit contributions:
//!
//!   coarse = 8*b3 - 4
//!   middle = 4*b2 - 2
//!   fine   = 2*b1 + b0 - 1
//!
//! Reading only the first contribution gives a P1 estimate, adding the
//! second gives P2, and adding all three reconstructs the original P4 value
//! exactly.  In addition to the packed-INT4 oracle, this module owns the real
//! allocation-backed split-plane representation, a scalar reference, and the
//! architecture-dispatched AArch64 CPU entry point.

const std = @import("std");
const builtin = @import("builtin");

extern fn glacier_prism_dot_p1_neon(
    activations: [*]const f32,
    coarse1: [*]const u8,
    scales: [*]const f32,
    num_weights: usize,
    group_size: usize,
) f32;

extern fn glacier_prism_dot_p2_neon(
    activations: [*]const f32,
    coarse1: [*]const u8,
    middle1: [*]const u8,
    scales: [*]const f32,
    num_weights: usize,
    group_size: usize,
) f32;

extern fn glacier_prism_dot_p4_neon(
    activations: [*]const f32,
    coarse1: [*]const u8,
    middle1: [*]const u8,
    fine2: [*]const u8,
    scales: [*]const f32,
    num_weights: usize,
    group_size: usize,
) f32;

pub const Tier = enum(u3) {
    p1 = 1,
    p2 = 2,
    p4 = 4,
};

pub const DecodeError = error{
    InvalidNibble,
};

pub const DotError = error{
    InvalidGroupSize,
    PackedLengthMismatch,
    ScaleLengthMismatch,
};

pub const SplitError = std.mem.Allocator.Error || error{
    PackedLengthMismatch,
};

/// Geometry errors for split-plane decoding.  Each required plane has a
/// distinct error so callers and benchmarks cannot silently compare buffers
/// with different logical weight counts.
pub const PlaneError = error{
    InvalidGroupSize,
    WeightLengthMismatch,
    CoarseLengthMismatch,
    MiddleLengthMismatch,
    FineLengthMismatch,
    ScaleLengthMismatch,
    WeightIndexOutOfBounds,
};

/// Exact byte lengths for the 1 + 1 + 2 bit planes.  The quotient/remainder
/// formulation is deliberate: unlike `(n + divisor - 1) / divisor`, it
/// remains defined even when `num_weights == maxInt(usize)`.
pub const PlaneByteLengths = struct {
    coarse1: usize,
    middle1: usize,
    fine2: usize,

    pub fn total(self: PlaneByteLengths) error{SizeOverflow}!usize {
        const one_bit_total = std.math.add(usize, self.coarse1, self.middle1) catch
            return error.SizeOverflow;
        return std.math.add(usize, one_bit_total, self.fine2) catch
            return error.SizeOverflow;
    }
};

pub fn planeByteLengths(num_weights: usize) PlaneByteLengths {
    return .{
        .coarse1 = ceilQuotient(num_weights, 8),
        .middle1 = ceilQuotient(num_weights, 8),
        .fine2 = ceilQuotient(num_weights, 4),
    };
}

/// A tier-tagged view makes the progressive I/O contract explicit in the
/// type itself.  P1 has no middle/fine slice to access, P2 has no fine slice,
/// and only P4 exposes all three planes.
pub const P1PlaneSlices = struct {
    num_weights: usize,
    coarse1: []const u8,
};

pub const P2PlaneSlices = struct {
    num_weights: usize,
    coarse1: []const u8,
    middle1: []const u8,
};

pub const P4PlaneSlices = struct {
    num_weights: usize,
    coarse1: []const u8,
    middle1: []const u8,
    fine2: []const u8,
};

pub const PlaneSlices = union(Tier) {
    p1: P1PlaneSlices,
    p2: P2PlaneSlices,
    p4: P4PlaneSlices,

    pub fn numWeights(self: PlaneSlices) usize {
        return switch (self) {
            inline else => |planes| planes.num_weights,
        };
    }
};

/// Allocation-backed split-plane representation used by correctness tests
/// and microbenchmarks.  Bytes are little-lane packed: bit `i % 8` for each
/// 1-bit plane and two-bit lane `i % 4` for the fine plane.  Padding bits are
/// zeroed but never decoded as logical weights.
pub const PackedPlanes = struct {
    allocator: std.mem.Allocator,
    num_weights: usize,
    coarse1: []u8,
    middle1: []u8,
    fine2: []u8,

    /// Split Glacier's low-nibble-first packed INT4 stream.  `num_weights` is
    /// explicit so an odd stream's high padding nibble is never interpreted.
    pub fn init(
        allocator: std.mem.Allocator,
        packed_weights: []const u8,
        num_weights: usize,
    ) SplitError!PackedPlanes {
        if (packed_weights.len != packedByteLength(num_weights)) {
            return error.PackedLengthMismatch;
        }

        const lengths = planeByteLengths(num_weights);
        const coarse1 = try allocator.alloc(u8, lengths.coarse1);
        errdefer allocator.free(coarse1);
        const middle1 = try allocator.alloc(u8, lengths.middle1);
        errdefer allocator.free(middle1);
        const fine2 = try allocator.alloc(u8, lengths.fine2);
        errdefer allocator.free(fine2);

        @memset(coarse1, 0);
        @memset(middle1, 0);
        @memset(fine2, 0);

        for (0..num_weights) |index| {
            const nibble = readNibble(packed_weights, index);
            writeOneBit(coarse1, index, (nibble >> 3) & 1);
            writeOneBit(middle1, index, (nibble >> 2) & 1);
            writeTwoBits(fine2, index, nibble & 0x03);
        }

        return .{
            .allocator = allocator,
            .num_weights = num_weights,
            .coarse1 = coarse1,
            .middle1 = middle1,
            .fine2 = fine2,
        };
    }

    pub fn deinit(self: *PackedPlanes) void {
        self.allocator.free(self.fine2);
        self.allocator.free(self.middle1);
        self.allocator.free(self.coarse1);
        self.* = undefined;
    }

    /// Return only the slices the selected tier is allowed to read.
    pub fn view(self: *const PackedPlanes, tier: Tier) PlaneSlices {
        return switch (tier) {
            .p1 => .{ .p1 = .{
                .num_weights = self.num_weights,
                .coarse1 = self.coarse1,
            } },
            .p2 => .{ .p2 = .{
                .num_weights = self.num_weights,
                .coarse1 = self.coarse1,
                .middle1 = self.middle1,
            } },
            .p4 => .{ .p4 = self.p4View() },
        };
    }

    pub fn p4View(self: *const PackedPlanes) P4PlaneSlices {
        return .{
            .num_weights = self.num_weights,
            .coarse1 = self.coarse1,
            .middle1 = self.middle1,
            .fine2 = self.fine2,
        };
    }

    pub fn nibbleAt(self: *const PackedPlanes, index: usize) PlaneError!u8 {
        return reconstructNibble(self.p4View(), index);
    }

    pub fn p4At(self: *const PackedPlanes, index: usize) PlaneError!i8 {
        return reconstructP4(self.p4View(), index);
    }
};

/// Convenience spelling for callers that treat splitting as a conversion.
pub fn splitPacked(
    allocator: std.mem.Allocator,
    packed_weights: []const u8,
    num_weights: usize,
) SplitError!PackedPlanes {
    return PackedPlanes.init(allocator, packed_weights, num_weights);
}

/// Versioned in-process contract for Prism's production rows4/K16 planes.
/// Bumping this value is required for any change to plane bit order, physical
/// coefficient order, or geometry-commitment encoding.
pub const rows4_k16_progressive_abi: u64 = 0x4750_5253_0000_0001;

pub const Rows4K16PlaneLayout = enum(u8) {
    /// Planes follow the existing rows4/K16 physical nibble stream. One-bit
    /// lanes are little-bit-first and two-bit lanes are little-pair-first.
    physical_1_1_2 = 1,
};

pub const Rows4K16Error = error{
    InvalidRows4Geometry,
    UnsupportedGroupSize,
    SizeOverflow,
    PackedLengthMismatch,
    CoarseLengthMismatch,
    MiddleLengthMismatch,
    FineLengthMismatch,
    DestinationLengthMismatch,
    AliasedBuffers,
    AbiMismatch,
    LayoutMismatch,
    GeometryMismatch,
    GeometryCommitmentMismatch,
    WeightIndexOutOfBounds,
};

pub const Rows4K16InitError = std.mem.Allocator.Error || Rows4K16Error;

/// Exact, independently addressable byte extents for both production tiers.
/// P2 is not described as a prefix of P4: kernels receive only its two plane
/// slices, while P4 receives all three. `packed_p4` is the size of the legacy
/// INT4 stream reconstructed by P4 and equals `p4_planes` for this ABI.
pub const Rows4K16PlaneExtents = struct {
    num_weights: usize,
    packed_p4: usize,
    coarse1: usize,
    middle1: usize,
    fine2: usize,
    p2_planes: usize,
    p4_planes: usize,
};

/// Stable identity copied into every typed tier view. The commitment covers
/// the ABI, layout, matrix dimensions, group size, and all plane extents.
pub const Rows4K16Geometry = struct {
    abi: u64,
    layout: Rows4K16PlaneLayout,
    out_f: usize,
    in_f: usize,
    group_size: u32,
    extents: Rows4K16PlaneExtents,
    geometry_commitment: u64,
};

/// Typed declaration that the source bytes already use Glacier's rows4/K16
/// physical nibble order. The progressive owner never retains this slice.
pub const Rows4K16PackedView = struct {
    packed_bytes: []const u8,
    out_f: usize,
    in_f: usize,
    group_size: u32,
};

/// P2 structurally has no fine-plane pointer, preventing accidental P4 I/O.
pub const Rows4K16P2View = struct {
    geometry: Rows4K16Geometry,
    coarse1: []const u8,
    middle1: []const u8,

    pub fn validate(self: Rows4K16P2View) Rows4K16Error!void {
        try validateRows4K16Geometry(self.geometry);
        if (self.coarse1.len != self.geometry.extents.coarse1)
            return error.CoarseLengthMismatch;
        if (self.middle1.len != self.geometry.extents.middle1)
            return error.MiddleLengthMismatch;
    }
};

pub const Rows4K16P4View = struct {
    geometry: Rows4K16Geometry,
    coarse1: []const u8,
    middle1: []const u8,
    fine2: []const u8,

    pub fn validate(self: Rows4K16P4View) Rows4K16Error!void {
        try validateRows4K16Geometry(self.geometry);
        if (self.coarse1.len != self.geometry.extents.coarse1)
            return error.CoarseLengthMismatch;
        if (self.middle1.len != self.geometry.extents.middle1)
            return error.MiddleLengthMismatch;
        if (self.fine2.len != self.geometry.extents.fine2)
            return error.FineLengthMismatch;
    }
};

pub const Rows4K16Tier = enum(u3) {
    p2 = 2,
    p4 = 4,
};

pub const Rows4K16TierView = union(Rows4K16Tier) {
    p2: Rows4K16P2View,
    p4: Rows4K16P4View,
};

/// Allocation-backed production representation. It owns exactly the three
/// split planes and deliberately has no field capable of retaining the
/// original packed INT4 stream.
pub const Rows4K16Progressive = struct {
    allocator: std.mem.Allocator,
    geometry: Rows4K16Geometry,
    coarse1: []u8,
    middle1: []u8,
    fine2: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        source: Rows4K16PackedView,
    ) Rows4K16InitError!Rows4K16Progressive {
        const geometry = try validateRows4K16PackedView(source);
        const coarse1 = try allocator.alloc(u8, geometry.extents.coarse1);
        errdefer allocator.free(coarse1);
        const middle1 = try allocator.alloc(u8, geometry.extents.middle1);
        errdefer allocator.free(middle1);
        const fine2 = try allocator.alloc(u8, geometry.extents.fine2);
        errdefer allocator.free(fine2);

        _ = try packRows4K16Into(source, coarse1, middle1, fine2);
        return .{
            .allocator = allocator,
            .geometry = geometry,
            .coarse1 = coarse1,
            .middle1 = middle1,
            .fine2 = fine2,
        };
    }

    pub fn deinit(self: *Rows4K16Progressive) void {
        self.allocator.free(self.fine2);
        self.allocator.free(self.middle1);
        self.allocator.free(self.coarse1);
        self.* = undefined;
    }

    pub fn p2View(self: *const Rows4K16Progressive) Rows4K16P2View {
        return .{
            .geometry = self.geometry,
            .coarse1 = self.coarse1,
            .middle1 = self.middle1,
        };
    }

    pub fn p4View(self: *const Rows4K16Progressive) Rows4K16P4View {
        return .{
            .geometry = self.geometry,
            .coarse1 = self.coarse1,
            .middle1 = self.middle1,
            .fine2 = self.fine2,
        };
    }

    pub fn view(
        self: *const Rows4K16Progressive,
        tier: Rows4K16Tier,
    ) Rows4K16TierView {
        return switch (tier) {
            .p2 => .{ .p2 = self.p2View() },
            .p4 => .{ .p4 = self.p4View() },
        };
    }

    pub fn p2ValueAt(
        self: *const Rows4K16Progressive,
        physical_index: usize,
    ) Rows4K16Error!i8 {
        return rows4K16P2ValueAt(self.p2View(), physical_index);
    }

    pub fn p4NibbleAt(
        self: *const Rows4K16Progressive,
        physical_index: usize,
    ) Rows4K16Error!u8 {
        return rows4K16P4NibbleAt(self.p4View(), physical_index);
    }

    pub fn logicalP4NibbleAt(
        self: *const Rows4K16Progressive,
        row: usize,
        col: usize,
    ) Rows4K16Error!u8 {
        const physical_index = try rows4K16PhysicalIndex(self.geometry, row, col);
        return rows4K16P4NibbleAt(self.p4View(), physical_index);
    }

    pub fn writePackedP4(
        self: *const Rows4K16Progressive,
        destination: []u8,
    ) Rows4K16Error!void {
        return writeRows4K16PackedP4(self.p4View(), destination);
    }
};

/// Construct and commit exact production geometry without allocating.
pub fn rows4K16Geometry(
    out_f: usize,
    in_f: usize,
    group_size: u32,
) Rows4K16Error!Rows4K16Geometry {
    if (out_f == 0 or out_f % 4 != 0 or in_f == 0 or in_f % 16 != 0)
        return error.InvalidRows4Geometry;
    if (group_size != 8 and group_size != 16)
        return error.UnsupportedGroupSize;
    const group_size_usize: usize = @intCast(group_size);
    if (in_f % group_size_usize != 0)
        return error.InvalidRows4Geometry;

    const num_weights = std.math.mul(usize, out_f, in_f) catch
        return error.SizeOverflow;
    const coarse1 = num_weights / 8;
    const middle1 = num_weights / 8;
    const fine2 = num_weights / 4;
    const p2_planes = std.math.add(usize, coarse1, middle1) catch
        return error.SizeOverflow;
    const p4_planes = std.math.add(usize, p2_planes, fine2) catch
        return error.SizeOverflow;
    const extents: Rows4K16PlaneExtents = .{
        .num_weights = num_weights,
        .packed_p4 = num_weights / 2,
        .coarse1 = coarse1,
        .middle1 = middle1,
        .fine2 = fine2,
        .p2_planes = p2_planes,
        .p4_planes = p4_planes,
    };
    return .{
        .abi = rows4_k16_progressive_abi,
        .layout = .physical_1_1_2,
        .out_f = out_f,
        .in_f = in_f,
        .group_size = group_size,
        .extents = extents,
        .geometry_commitment = try commitRows4K16Geometry(
            out_f,
            in_f,
            group_size,
            extents,
        ),
    };
}

pub fn validateRows4K16Geometry(
    geometry: Rows4K16Geometry,
) Rows4K16Error!void {
    if (geometry.abi != rows4_k16_progressive_abi)
        return error.AbiMismatch;
    if (geometry.layout != .physical_1_1_2)
        return error.LayoutMismatch;

    const expected = try rows4K16Geometry(
        geometry.out_f,
        geometry.in_f,
        geometry.group_size,
    );
    if (!std.meta.eql(geometry.extents, expected.extents))
        return error.GeometryMismatch;
    if (geometry.geometry_commitment != expected.geometry_commitment)
        return error.GeometryCommitmentMismatch;
}

pub fn validateRows4K16PackedView(
    source: Rows4K16PackedView,
) Rows4K16Error!Rows4K16Geometry {
    const geometry = try rows4K16Geometry(
        source.out_f,
        source.in_f,
        source.group_size,
    );
    if (source.packed_bytes.len != geometry.extents.packed_p4)
        return error.PackedLengthMismatch;
    return geometry;
}

/// Split an existing rows4/K16 stream into caller-owned production planes.
/// Every shape, exact length, overflow, and pairwise alias check completes
/// before the first output byte is changed.
pub fn packRows4K16Into(
    source: Rows4K16PackedView,
    coarse1: []u8,
    middle1: []u8,
    fine2: []u8,
) Rows4K16Error!Rows4K16Geometry {
    const geometry = try validateRows4K16PackedView(source);
    if (coarse1.len != geometry.extents.coarse1)
        return error.CoarseLengthMismatch;
    if (middle1.len != geometry.extents.middle1)
        return error.MiddleLengthMismatch;
    if (fine2.len != geometry.extents.fine2)
        return error.FineLengthMismatch;

    if (byteSlicesOverlap(source.packed_bytes, coarse1) or
        byteSlicesOverlap(source.packed_bytes, middle1) or
        byteSlicesOverlap(source.packed_bytes, fine2) or
        byteSlicesOverlap(coarse1, middle1) or
        byteSlicesOverlap(coarse1, fine2) or
        byteSlicesOverlap(middle1, fine2))
        return error.AliasedBuffers;

    @memset(coarse1, 0);
    @memset(middle1, 0);
    @memset(fine2, 0);
    for (0..geometry.extents.num_weights) |physical_index| {
        const nibble = readNibble(source.packed_bytes, physical_index);
        writeOneBit(coarse1, physical_index, (nibble >> 3) & 1);
        writeOneBit(middle1, physical_index, (nibble >> 2) & 1);
        writeTwoBits(fine2, physical_index, nibble & 0x03);
    }
    return geometry;
}

/// Translate a logical matrix coordinate to the pre-existing rows4/K16
/// physical nibble stream. Validation makes every intermediate fit in usize.
pub fn rows4K16PhysicalIndex(
    geometry: Rows4K16Geometry,
    row: usize,
    col: usize,
) Rows4K16Error!usize {
    try validateRows4K16Geometry(geometry);
    if (row >= geometry.out_f or col >= geometry.in_f)
        return error.WeightIndexOutOfBounds;
    const tile = row / 4;
    const lane = row % 4;
    const block = col / 16;
    const chunk = (col % 16) / 4;
    const inner = col % 4;
    return tile * (4 * geometry.in_f) + block * 64 +
        chunk * 16 + lane * 4 + inner;
}

/// Centered P2 value in physical rows4/K16 order.
pub fn rows4K16P2ValueAt(
    view: Rows4K16P2View,
    physical_index: usize,
) Rows4K16Error!i8 {
    try view.validate();
    if (physical_index >= view.geometry.extents.num_weights)
        return error.WeightIndexOutOfBounds;
    return (if (readOneBit(view.coarse1, physical_index) == 0)
        @as(i8, -4)
    else
        @as(i8, 4)) + (if (readOneBit(view.middle1, physical_index) == 0)
        @as(i8, -2)
    else
        @as(i8, 2));
}

/// Exact unsigned INT4 code in physical rows4/K16 order.
pub fn rows4K16P4NibbleAt(
    view: Rows4K16P4View,
    physical_index: usize,
) Rows4K16Error!u8 {
    try view.validate();
    if (physical_index >= view.geometry.extents.num_weights)
        return error.WeightIndexOutOfBounds;
    return rows4K16P4NibbleAtUnchecked(view, physical_index);
}

/// Reconstruct the legacy rows4/K16 packed byte stream exactly. The
/// destination may be adjacent to plane storage but must not overlap it.
pub fn writeRows4K16PackedP4(
    view: Rows4K16P4View,
    destination: []u8,
) Rows4K16Error!void {
    try view.validate();
    if (destination.len != view.geometry.extents.packed_p4)
        return error.DestinationLengthMismatch;
    if (byteSlicesOverlap(destination, view.coarse1) or
        byteSlicesOverlap(destination, view.middle1) or
        byteSlicesOverlap(destination, view.fine2))
        return error.AliasedBuffers;

    for (destination, 0..) |*byte, byte_index| {
        const physical_index = byte_index * 2;
        byte.* = rows4K16P4NibbleAtUnchecked(view, physical_index) |
            (rows4K16P4NibbleAtUnchecked(view, physical_index + 1) << 4);
    }
}

inline fn rows4K16P4NibbleAtUnchecked(
    view: Rows4K16P4View,
    physical_index: usize,
) u8 {
    return (readOneBit(view.coarse1, physical_index) << 3) |
        (readOneBit(view.middle1, physical_index) << 2) |
        readTwoBits(view.fine2, physical_index);
}

/// FNV-1a over fixed-width little-endian fields keeps the commitment stable
/// across hosts and Zig releases. The ABI version pins this exact sequence.
fn commitRows4K16Geometry(
    out_f: usize,
    in_f: usize,
    group_size: u32,
    extents: Rows4K16PlaneExtents,
) Rows4K16Error!u64 {
    const out_u64 = std.math.cast(u64, out_f) orelse
        return error.SizeOverflow;
    const in_u64 = std.math.cast(u64, in_f) orelse
        return error.SizeOverflow;
    const fields = [_]u64{
        rows4_k16_progressive_abi,
        @intFromEnum(Rows4K16PlaneLayout.physical_1_1_2),
        out_u64,
        in_u64,
        group_size,
        std.math.cast(u64, extents.num_weights) orelse return error.SizeOverflow,
        std.math.cast(u64, extents.packed_p4) orelse return error.SizeOverflow,
        std.math.cast(u64, extents.coarse1) orelse return error.SizeOverflow,
        std.math.cast(u64, extents.middle1) orelse return error.SizeOverflow,
        std.math.cast(u64, extents.fine2) orelse return error.SizeOverflow,
        std.math.cast(u64, extents.p2_planes) orelse return error.SizeOverflow,
        std.math.cast(u64, extents.p4_planes) orelse return error.SizeOverflow,
    };
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (fields) |field| {
        var value = field;
        for (0..8) |_| {
            hash = (hash ^ @as(u8, @truncate(value))) *% 0x0000_0100_0000_01b3;
            value >>= 8;
        }
    }
    return hash;
}

fn byteSlicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

/// Centered additive contributions for one offset-binary INT4 nibble.
/// `coarse` and `middle` each depend on one source bit; `fine` depends on
/// the remaining two source bits.
pub const Decomposition = struct {
    coarse: i8,
    middle: i8,
    fine: i8,

    /// Reconstruct the approximation available after reading `tier` bits.
    pub inline fn value(self: Decomposition, tier: Tier) i8 {
        return switch (tier) {
            .p1 => self.coarse,
            .p2 => self.coarse + self.middle,
            .p4 => self.coarse + self.middle + self.fine,
        };
    }
};

/// Results for all progressive tiers, accumulated in one scalar pass.
pub const DotTiers = struct {
    p1: f32,
    p2: f32,
    p4: f32,

    pub inline fn value(self: DotTiers, tier: Tier) f32 {
        return switch (tier) {
            .p1 => self.p1,
            .p2 => self.p2,
            .p4 => self.p4,
        };
    }
};

/// Split a nibble into its exact centered 1 + 1 + 2-bit representation.
pub fn decomposeNibble(nibble: u8) DecodeError!Decomposition {
    if (nibble > 0x0f) return error.InvalidNibble;
    return decomposeValidNibble(nibble);
}

/// Decode one nibble at the requested progressive tier.
pub fn decodeNibble(nibble: u8, tier: Tier) DecodeError!i8 {
    return (try decomposeNibble(nibble)).value(tier);
}

/// Compute all three scalar dot-product tiers in one pass.
///
/// Packed bytes use Glacier's existing low-nibble-first layout.  Scales are
/// indexed over the logical weight stream, including groups that cross byte
/// or odd-tail boundaries.  Lengths are exact rather than minimum bounds so
/// a caller cannot accidentally supply a mismatched logical weight count.
pub fn dotAll(
    activations: []const f32,
    packed_weights: []const u8,
    scales: []const f32,
    group_size: usize,
) DotError!DotTiers {
    try validateDotShape(activations.len, packed_weights.len, scales.len, group_size);

    var result = DotTiers{ .p1 = 0, .p2 = 0, .p4 = 0 };
    for (activations, 0..) |activation, index| {
        const components = decomposeValidNibble(readNibble(packed_weights, index));
        const scale = scales[index / group_size];

        // Keep the multiplication and accumulation order identical between
        // tiers.  In particular P4 first reconstructs the integer and then
        // applies its scale, matching the legacy full-INT4 scalar formula.
        const p1_weight: f32 = @floatFromInt(components.value(.p1));
        const p2_weight: f32 = @floatFromInt(components.value(.p2));
        const p4_weight: f32 = @floatFromInt(components.value(.p4));
        result.p1 += activation * (p1_weight * scale);
        result.p2 += activation * (p2_weight * scale);
        result.p4 += activation * (p4_weight * scale);
    }
    return result;
}

/// Compute a selected progressive scalar dot-product tier.
pub fn dotTier(
    activations: []const f32,
    packed_weights: []const u8,
    scales: []const f32,
    group_size: usize,
    tier: Tier,
) DotError!f32 {
    return (try dotAll(activations, packed_weights, scales, group_size)).value(tier);
}

pub fn dotP1(
    activations: []const f32,
    packed_weights: []const u8,
    scales: []const f32,
    group_size: usize,
) DotError!f32 {
    return dotTier(activations, packed_weights, scales, group_size, .p1);
}

pub fn dotP2(
    activations: []const f32,
    packed_weights: []const u8,
    scales: []const f32,
    group_size: usize,
) DotError!f32 {
    return dotTier(activations, packed_weights, scales, group_size, .p2);
}

pub fn dotP4(
    activations: []const f32,
    packed_weights: []const u8,
    scales: []const f32,
    group_size: usize,
) DotError!f32 {
    return dotTier(activations, packed_weights, scales, group_size, .p4);
}

/// Reconstruct the original unsigned INT4 nibble from all three planes.
pub fn reconstructNibble(planes: P4PlaneSlices, index: usize) PlaneError!u8 {
    try validateP4Geometry(planes);
    if (index >= planes.num_weights) return error.WeightIndexOutOfBounds;
    return reconstructNibbleUnchecked(planes, index);
}

/// Reconstruct Glacier's exact offset-binary P4 value (`nibble - 7`).
pub fn reconstructP4(planes: P4PlaneSlices, index: usize) PlaneError!i8 {
    const nibble = try reconstructNibble(planes, index);
    return @as(i8, @intCast(nibble)) - 7;
}

/// Scalar reference dot product over actual split planes.
///
/// `planes` is tier-tagged, so this function cannot inspect a plane that the
/// requested tier should not fetch.  Every exposed plane and the scale array
/// must have the exact length implied by `num_weights`.
pub fn dotPlanesTier(
    activations: []const f32,
    planes: PlaneSlices,
    scales: []const f32,
    group_size: usize,
) PlaneError!f32 {
    try validatePlaneDotShape(activations.len, planes, scales.len, group_size);
    return dotPlanesTierScalarUnchecked(activations, planes, scales, group_size);
}

/// Use the architecture-tuned split-plane dot kernel when its block geometry
/// is valid, otherwise preserve the scalar reference as a portable fallback.
///
/// The AArch64 ABI has a separate entry point for every tier.  In addition to
/// saving bandwidth, this makes the access contract structural: P1 receives
/// no middle/fine pointers and P2 receives no fine pointer.  P4 reconstructs
/// the signed INT4 value in integer lanes before applying floating scales.
/// Floating reductions are vectorized, so callers comparing this result to
/// the sequential scalar oracle should use normal FP32 tolerance rather than
/// bitwise equality.
pub fn dotPlanesTierCpu(
    activations: []const f32,
    planes: PlaneSlices,
    scales: []const f32,
    group_size: usize,
) PlaneError!f32 {
    try validatePlaneDotShape(activations.len, planes, scales.len, group_size);

    const num_weights = planes.numWeights();
    if (comptime builtin.cpu.arch == .aarch64) {
        if (canUseNeonPlaneKernel(num_weights, group_size)) {
            return switch (planes) {
                .p1 => |p1| glacier_prism_dot_p1_neon(
                    activations.ptr,
                    p1.coarse1.ptr,
                    scales.ptr,
                    num_weights,
                    group_size,
                ),
                .p2 => |p2| glacier_prism_dot_p2_neon(
                    activations.ptr,
                    p2.coarse1.ptr,
                    p2.middle1.ptr,
                    scales.ptr,
                    num_weights,
                    group_size,
                ),
                .p4 => |p4| glacier_prism_dot_p4_neon(
                    activations.ptr,
                    p4.coarse1.ptr,
                    p4.middle1.ptr,
                    p4.fine2.ptr,
                    scales.ptr,
                    num_weights,
                    group_size,
                ),
            };
        }
    }

    return dotPlanesTierScalarUnchecked(activations, planes, scales, group_size);
}

/// Whether `dotPlanesTierCpu` can enter its eight-weight AArch64 kernel for
/// this shape.  Keeping this predicate public lets microbenchmarks state
/// unambiguously whether they measured SIMD or the scalar fallback.
pub fn canUseNeonPlaneKernel(num_weights: usize, group_size: usize) bool {
    return builtin.cpu.arch == .aarch64 and
        num_weights >= 8 and
        group_size >= 8 and
        group_size % 8 == 0;
}

inline fn decomposeValidNibble(nibble: u8) Decomposition {
    std.debug.assert(nibble <= 0x0f);
    return .{
        .coarse = if (nibble & 0x08 != 0) 4 else -4,
        .middle = if (nibble & 0x04 != 0) 2 else -2,
        .fine = @as(i8, @intCast(nibble & 0x03)) - 1,
    };
}

inline fn readNibble(packed_weights: []const u8, index: usize) u8 {
    const byte = packed_weights[index / 2];
    return if (index & 1 == 0) byte & 0x0f else byte >> 4;
}

inline fn packedByteLength(num_weights: usize) usize {
    return ceilQuotient(num_weights, 2);
}

inline fn ceilQuotient(numerator: usize, denominator: usize) usize {
    std.debug.assert(denominator != 0);
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

inline fn writeOneBit(plane: []u8, index: usize, bit: u8) void {
    std.debug.assert(bit <= 1);
    const shift: u3 = @intCast(index & 7);
    plane[index / 8] |= bit << shift;
}

inline fn writeTwoBits(plane: []u8, index: usize, bits: u8) void {
    std.debug.assert(bits <= 3);
    const shift: u3 = @intCast((index & 3) * 2);
    plane[index / 4] |= bits << shift;
}

inline fn readOneBit(plane: []const u8, index: usize) u8 {
    const shift: u3 = @intCast(index & 7);
    return (plane[index / 8] >> shift) & 1;
}

inline fn readTwoBits(plane: []const u8, index: usize) u8 {
    const shift: u3 = @intCast((index & 3) * 2);
    return (plane[index / 4] >> shift) & 3;
}

inline fn coarseValue(coarse1: []const u8, index: usize) i8 {
    return if (readOneBit(coarse1, index) == 0) -4 else 4;
}

inline fn middleValue(middle1: []const u8, index: usize) i8 {
    return if (readOneBit(middle1, index) == 0) -2 else 2;
}

inline fn fineValue(fine2: []const u8, index: usize) i8 {
    return @as(i8, @intCast(readTwoBits(fine2, index))) - 1;
}

inline fn reconstructNibbleUnchecked(planes: P4PlaneSlices, index: usize) u8 {
    return (readOneBit(planes.coarse1, index) << 3) |
        (readOneBit(planes.middle1, index) << 2) |
        readTwoBits(planes.fine2, index);
}

fn validateP1Geometry(planes: P1PlaneSlices) PlaneError!void {
    const lengths = planeByteLengths(planes.num_weights);
    if (planes.coarse1.len != lengths.coarse1) return error.CoarseLengthMismatch;
}

fn validateP2Geometry(planes: P2PlaneSlices) PlaneError!void {
    const lengths = planeByteLengths(planes.num_weights);
    if (planes.coarse1.len != lengths.coarse1) return error.CoarseLengthMismatch;
    if (planes.middle1.len != lengths.middle1) return error.MiddleLengthMismatch;
}

fn validateP4Geometry(planes: P4PlaneSlices) PlaneError!void {
    const lengths = planeByteLengths(planes.num_weights);
    if (planes.coarse1.len != lengths.coarse1) return error.CoarseLengthMismatch;
    if (planes.middle1.len != lengths.middle1) return error.MiddleLengthMismatch;
    if (planes.fine2.len != lengths.fine2) return error.FineLengthMismatch;
}

fn validatePlaneDotShape(
    activation_len: usize,
    planes: PlaneSlices,
    scale_len: usize,
    group_size: usize,
) PlaneError!void {
    if (group_size == 0) return error.InvalidGroupSize;

    const num_weights = planes.numWeights();
    if (activation_len != num_weights) return error.WeightLengthMismatch;
    if (scale_len != ceilQuotient(num_weights, group_size)) {
        return error.ScaleLengthMismatch;
    }

    switch (planes) {
        .p1 => |p1| try validateP1Geometry(p1),
        .p2 => |p2| try validateP2Geometry(p2),
        .p4 => |p4| try validateP4Geometry(p4),
    }
}

inline fn dotPlanesTierScalarUnchecked(
    activations: []const f32,
    planes: PlaneSlices,
    scales: []const f32,
    group_size: usize,
) f32 {
    return switch (planes) {
        .p1 => |p1| dotP1PlanesUnchecked(activations, p1, scales, group_size),
        .p2 => |p2| dotP2PlanesUnchecked(activations, p2, scales, group_size),
        .p4 => |p4| dotP4PlanesUnchecked(activations, p4, scales, group_size),
    };
}

fn dotP1PlanesUnchecked(
    activations: []const f32,
    planes: P1PlaneSlices,
    scales: []const f32,
    group_size: usize,
) f32 {
    var result: f32 = 0;
    for (activations, 0..) |activation, index| {
        const weight: f32 = @floatFromInt(coarseValue(planes.coarse1, index));
        result += activation * (weight * scales[index / group_size]);
    }
    return result;
}

fn dotP2PlanesUnchecked(
    activations: []const f32,
    planes: P2PlaneSlices,
    scales: []const f32,
    group_size: usize,
) f32 {
    var result: f32 = 0;
    for (activations, 0..) |activation, index| {
        const value = coarseValue(planes.coarse1, index) +
            middleValue(planes.middle1, index);
        const weight: f32 = @floatFromInt(value);
        result += activation * (weight * scales[index / group_size]);
    }
    return result;
}

fn dotP4PlanesUnchecked(
    activations: []const f32,
    planes: P4PlaneSlices,
    scales: []const f32,
    group_size: usize,
) f32 {
    var result: f32 = 0;
    for (activations, 0..) |activation, index| {
        // Reconstruct the integer before scaling, preserving the operation
        // order of the packed scalar oracle for bit-exact comparisons.
        const value: i8 = @as(i8, @intCast(reconstructNibbleUnchecked(planes, index))) - 7;
        const weight: f32 = @floatFromInt(value);
        result += activation * (weight * scales[index / group_size]);
    }
    return result;
}

fn validateDotShape(
    num_weights: usize,
    packed_len: usize,
    scale_len: usize,
    group_size: usize,
) DotError!void {
    if (group_size == 0) return error.InvalidGroupSize;

    const expected_packed_len = num_weights / 2 + num_weights % 2;
    if (packed_len != expected_packed_len) return error.PackedLengthMismatch;

    const expected_scale_len = num_weights / group_size +
        @intFromBool(num_weights % group_size != 0);
    if (scale_len != expected_scale_len) return error.ScaleLengthMismatch;
}
