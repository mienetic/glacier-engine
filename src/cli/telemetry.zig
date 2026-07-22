//! Cold, type-stable CLI evidence rendering.
//!
//! A production ReleaseFast build may optimize the cold CLI root, including
//! this renderer and command dispatcher, for size independently from imported
//! ReleaseFast engine/core modules. Telemetry remains byte-for-byte identical,
//! while formatter machinery cannot consume hot engine text pages or their
//! instruction-cache budget.

const std = @import("std");

pub const Counter = struct {
    name: []const u8,
    value: usize,
};

pub noinline fn writeString(
    writer: *std.Io.Writer,
    name: []const u8,
    value: []const u8,
) !void {
    try writer.print(" {s}={s}", .{ name, value });
}

pub noinline fn writeCount(
    writer: *std.Io.Writer,
    name: []const u8,
    value: usize,
) !void {
    try writer.print(" {s}={d}", .{ name, value });
}

/// Render byte limits, receipt counters, and other ABI-stable 64-bit values
/// without narrowing them to the host's pointer width.
pub noinline fn writeU64(
    writer: *std.Io.Writer,
    name: []const u8,
    value: u64,
) !void {
    try writer.print(" {s}={d}", .{ name, value });
}

pub noinline fn writeMillis(
    writer: *std.Io.Writer,
    name: []const u8,
    nanoseconds: u64,
) !void {
    const milliseconds = @as(f64, @floatFromInt(nanoseconds)) / 1e6;
    try writer.print(" {s}={d:.3}", .{ name, milliseconds });
}

pub noinline fn writeHex(
    writer: *std.Io.Writer,
    name: []const u8,
    value: u64,
) !void {
    try writer.print(" {s}={x}", .{ name, value });
}

pub noinline fn writeCounts(
    writer: *std.Io.Writer,
    counters: []const Counter,
) !void {
    for (counters) |counter|
        try writeCount(writer, counter.name, counter.value);
}
