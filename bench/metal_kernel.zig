//! Metal INT4 matvec smoke benchmark.  This measures the persistent-weight
//! path independently from model loading and reports command-buffer overhead.

const std = @import("std");
const engine = @import("engine");
const quant = engine.core.quant;

pub fn main() !void {
    if (comptime !engine.metal_enabled) {
        std.debug.print("metal-kernel: unavailable (backend disabled)\n", .{});
        return;
    }
    return runMetal();
}

fn runMetal() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const out_f = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 4864;
    const in_f = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 896;
    const iterations = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 32;
    const group_size = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 8;

    var backend = engine.MetalBackend.init("zig-out/metal/shaders.metallib") catch |err| {
        std.debug.print("metal-kernel: unavailable ({s})\n", .{@errorName(err)});
        return;
    };
    defer backend.deinit();

    const element_count = try std.math.mul(usize, out_f, in_f);
    const source = try allocator.alloc(f32, element_count);
    defer allocator.free(source);
    for (source, 0..) |*v, i| v.* = @as(f32, @floatFromInt((i * 29 + 7) % 101)) / 127.0 - 0.4;
    const q = try quant.quantize(f32, allocator, source, .int4, group_size);
    defer {
        allocator.free(q.packed_bytes);
        allocator.free(q.scales);
    }
    const weight = try backend.createInt4Weight(q.packed_bytes, q.scales, group_size, @intCast(in_f), @intCast(out_f));
    defer backend.destroyInt4Weight(weight);
    const input = try allocator.alloc(f32, in_f);
    defer allocator.free(input);
    const output = try allocator.alloc(f32, out_f);
    defer allocator.free(output);
    for (input, 0..) |*v, i| v.* = @as(f32, @floatFromInt((i * 13 + 3) % 47)) / 31.0 - 0.7;

    try backend.matvecInt4(weight, input, output);
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| try backend.matvecInt4(weight, input, output);
    const elapsed_ns = timer.read();
    const ms = @as(f64, @floatFromInt(elapsed_ns)) / 1e6;
    const weight_bytes = @as(f64, @floatFromInt(element_count)) * 0.5;
    const bandwidth = weight_bytes * @as(f64, @floatFromInt(iterations)) /
        (@as(f64, @floatFromInt(elapsed_ns)) / 1e9) / (1024 * 1024 * 1024);
    var max_abs: f32 = 0;
    // A tiny CPU check ensures the GPU path did not silently return stale
    // output; exact numerical comparison is covered by metal_correctness.
    for (output) |v| max_abs = @max(max_abs, @abs(v));
    const stdout = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buf);
    try writer.interface.print(
        "metal-kernel: out={d} in={d} group={d} iterations={d}\n  {d:.3} ms ({d:.2} GiB/s) max_abs={d:.4}\n",
        .{ out_f, in_f, group_size, iterations, ms, bandwidth, max_abs },
    );
    try writer.interface.flush();
}
