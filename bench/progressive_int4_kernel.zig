//! Microbenchmark for Prism's scalar and AArch64 split-bitplane dot kernels.
//!
//! This intentionally measures the isolated P1/P2/P4 primitive.  It does not
//! claim end-to-end decode speed: the generation path must first integrate
//! split-plane model storage, scheduling, and verification transactions.

const std = @import("std");
const progressive = @import("progressive_int4");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const num_weights = if (args.len > 1)
        try std.fmt.parseInt(usize, args[1], 10)
    else
        4864 * 896;
    const iterations = if (args.len > 2)
        try std.fmt.parseInt(usize, args[2], 10)
    else
        8;
    const group_size = if (args.len > 3)
        try std.fmt.parseInt(usize, args[3], 10)
    else
        16;
    if (num_weights == 0 or iterations == 0 or group_size == 0)
        return error.InvalidUsage;
    const sample_count = try std.math.mul(usize, num_weights, iterations);

    const packed_len = num_weights / 2 + num_weights % 2;
    const scale_len = num_weights / group_size +
        @intFromBool(num_weights % group_size != 0);
    const packed_weights = try allocator.alloc(u8, packed_len);
    defer allocator.free(packed_weights);
    const activations = try allocator.alloc(f32, num_weights);
    defer allocator.free(activations);
    const scales = try allocator.alloc(f32, scale_len);
    defer allocator.free(scales);

    for (packed_weights, 0..) |*byte, index| {
        const low: u8 = @intCast((index * 13 + 5) & 0x0f);
        const high: u8 = @intCast((index * 7 + 11) & 0x0f);
        byte.* = low | (high << 4);
    }
    for (activations, 0..) |*activation, index| {
        const centered: i32 = @intCast((index * 29 + 3) % 257);
        activation.* = @as(f32, @floatFromInt(centered - 128)) / 127.0;
    }
    for (scales, 0..) |*scale, index| {
        scale.* = @as(f32, @floatFromInt((index * 17 + 1) % 31 + 1)) / 128.0;
    }

    var planes = try progressive.PackedPlanes.init(
        allocator,
        packed_weights,
        num_weights,
    );
    defer planes.deinit();

    const stdout = std.fs.File.stdout();
    var output_buffer: [4096]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &output_buffer);
    try writer.interface.print(
        "prism-kernel: scope=single-fp32-dot production-k16-gate=false weights={d} group={d} iterations={d} neon={any}\n",
        .{
            num_weights,
            group_size,
            iterations,
            progressive.canUseNeonPlaneKernel(num_weights, group_size),
        },
    );

    inline for (std.meta.tags(progressive.Tier)) |tier| {
        const view = planes.view(tier);
        const scalar_warm = try progressive.dotPlanesTier(
            activations,
            view,
            scales,
            group_size,
        );
        const cpu_warm = try progressive.dotPlanesTierCpu(
            activations,
            view,
            scales,
            group_size,
        );
        std.mem.doNotOptimizeAway(scalar_warm);
        std.mem.doNotOptimizeAway(cpu_warm);

        var scalar_checksum: f32 = 0;
        var scalar_timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            scalar_checksum += try progressive.dotPlanesTier(
                activations,
                view,
                scales,
                group_size,
            );
        }
        const scalar_ns = scalar_timer.read();
        std.mem.doNotOptimizeAway(scalar_checksum);

        var cpu_checksum: f32 = 0;
        var cpu_timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            cpu_checksum += try progressive.dotPlanesTierCpu(
                activations,
                view,
                scales,
                group_size,
            );
        }
        const cpu_ns = cpu_timer.read();
        std.mem.doNotOptimizeAway(cpu_checksum);

        const scalar_per_weight = @as(f64, @floatFromInt(scalar_ns)) /
            @as(f64, @floatFromInt(sample_count));
        const cpu_per_weight = @as(f64, @floatFromInt(cpu_ns)) /
            @as(f64, @floatFromInt(sample_count));
        const versus_scalar = @as(f64, @floatFromInt(scalar_ns)) /
            @as(f64, @floatFromInt(cpu_ns));
        const result_delta = @abs(scalar_warm - cpu_warm);
        const plane_bytes = switch (tier) {
            .p1 => planes.coarse1.len,
            .p2 => planes.coarse1.len + planes.middle1.len,
            .p4 => planes.coarse1.len + planes.middle1.len + planes.fine2.len,
        };
        try writer.interface.print(
            "  {s}: plane_bytes={d} scalar={d:.3} ns/w cpu={d:.3} ns/w vs_scalar={d:.2}x result={d:.6} delta={d:.6}\n",
            .{ @tagName(tier), plane_bytes, scalar_per_weight, cpu_per_weight, versus_scalar, scalar_warm, result_delta },
        );
    }
    try writer.interface.flush();
}
