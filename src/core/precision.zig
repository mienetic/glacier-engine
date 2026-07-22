//! Precision axis (P-axis).
//!
//! See docs/PAGING.md. The MVP uses a static per-layer precision profile;
//! dynamic per-page precision is future work.

const std = @import("std");

/// Storage precision for a weight page. Mirrors docs/FORMAT_SPEC.md.
pub const Precision = enum(u8) {
    fp32 = 6, // raw FP32 source bytes (not quantized)
    fp16 = 0,
    bf16 = 1,
    int8 = 2,
    int4 = 3,
    int2 = 4,
    tri1p58 = 5, // 1.58-bit ternary (BitNet-style)

    /// Bytes per weight at this precision (packed, before group overhead).
    pub fn bytesPerWeight(self: Precision) f32 {
        return switch (self) {
            .fp32 => 4.0,
            .fp16, .bf16 => 2.0,
            .int8 => 1.0,
            .int4 => 0.5,
            .int2 => 0.25,
            .tri1p58 => 0.375, // log2(3) ≈ 1.585 bits
        };
    }

    /// True if `self` is at least as precise as `required`.
    pub fn satisfies(self: Precision, required: Precision) bool {
        if (self == required) return true;
        const s = self.bytesPerWeight();
        const r = required.bytesPerWeight();
        return s >= r;
    }

    pub fn name(self: Precision) []const u8 {
        return switch (self) {
            .fp32 => "FP32",
            .fp16 => "FP16",
            .bf16 => "BF16",
            .int8 => "INT8",
            .int4 => "INT4",
            .int2 => "INT2",
            .tri1p58 => "TRI1.58",
        };
    }
};

/// Per-layer precision requirement. The MVP reads this from a static table
/// (see precisionProfileFor). A learned scheduler replaces it later.
pub const PrecisionProfile = struct {
    /// Indexed by layer index. Returns the minimum precision that layer
    /// requires for all of its weight pages.
    required: []const Precision,

    pub fn deinit(self: *PrecisionProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.required);
    }
};

/// Default heuristic profile. See docs/PAGING.md "Precision profile".
/// `num_layers` must be ≥ 4 for the first/last FP16 rule to make sense.
pub fn precisionProfileFor(
    allocator: std.mem.Allocator,
    num_layers: usize,
) !PrecisionProfile {
    const req = try allocator.alloc(Precision, num_layers);
    errdefer allocator.free(req);

    for (0..num_layers) |i| {
        const is_first = i < 2;
        const is_last = i + 2 >= num_layers;
        req[i] = if (is_first or is_last) .fp16 else .int4;
    }
    return .{ .required = req };
}

test "precision ordering" {
    try std.testing.expect(Precision.fp16.satisfies(.int4));
    try std.testing.expect(!Precision.int4.satisfies(.fp16));
    try std.testing.expect(Precision.bf16.satisfies(.fp16));
}

test "profile edges are fp16, middle is int4" {
    var prof = try precisionProfileFor(std.testing.allocator, 8);
    defer prof.deinit(std.testing.allocator);
    try std.testing.expectEqual(Precision.fp16, prof.required[0]);
    try std.testing.expectEqual(Precision.fp16, prof.required[1]);
    try std.testing.expectEqual(Precision.int4, prof.required[4]);
    try std.testing.expectEqual(Precision.fp16, prof.required[7]);
}
