//! Predictive neuron skipping (STUB).
//!
//! Not in the MVP. Sketched so the API surface is stable.
//!
//! Idea: a tiny predictor (~1M params) forecasts which weight rows will
//! contribute near-zero output for the current hidden state, and the
//! pager simply never loads them. This saves bandwidth, not compute.

const std = @import("std");

/// Bitmap of rows to skip for one layer. One bit per row, set = skip.
pub const SkipMask = struct {
    bits: []u64,
    num_rows: u32,

    pub fn deinit(self: *SkipMask, allocator: std.mem.Allocator) void {
        allocator.free(self.bits);
    }

    pub fn shouldSkip(self: SkipMask, row: u32) bool {
        const word = row / 64;
        const bit = row % 64;
        return (self.bits[word] >> @intCast(bit)) & 1 == 1;
    }
};

/// MVP placeholder: skip nothing. Returns an all-zero mask.
pub fn predict(
    allocator: std.mem.Allocator,
    layer_idx: u32,
    num_rows: u32,
) !SkipMask {
    _ = layer_idx;
    const words = (num_rows + 63) / 64;
    const bits = try allocator.alloc(u64, words);
    @memset(bits, 0);
    return .{ .bits = bits, .num_rows = num_rows };
}
