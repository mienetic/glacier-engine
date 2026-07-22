//! Reproducible packed-INT4 kernel benchmark.
//!
//! Compares the legacy FP32-activation decode with the Q8-activation path on
//! a representative Qwen projection.  It deliberately measures serial
//! kernels first; end-to-end generation adds a separate thread-scheduling
//! dimension and is reported by the CLI benchmark.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const tensor = engine.core.tensor;
const quant = engine.core.quant;
const int4 = engine.int4_matmul;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const out_f = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 4864;
    const in_f = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 896;
    const iterations = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else 8;
    const group_size = if (args.len > 4) try std.fmt.parseInt(u32, args[4], 10) else 8;
    const threads = if (args.len > 5) try std.fmt.parseInt(usize, args[5], 10) else 1;
    // Scale mode: 0=FP32 row-major, 1=FP16 row-major, 2=FP16 rows4 grid,
    // 3=FP16 rows4 grid with four-row/K16 packed weights.
    const scale_mode = if (args.len > 6) try std.fmt.parseInt(u8, args[6], 10) else 1;
    const batch_size = if (args.len > 7) try std.fmt.parseInt(usize, args[7], 10) else 128;
    if (out_f == 0 or in_f == 0 or iterations == 0 or group_size == 0 or
        scale_mode > 3 or batch_size == 0)
        return error.InvalidUsage;

    const element_count = try std.math.mul(usize, out_f, in_f);
    const source = try allocator.alloc(f32, element_count);
    defer allocator.free(source);
    for (source, 0..) |*v, i| {
        // Deterministic, non-uniform values exercise all nibbles without
        // requiring a random-number stream in benchmark output.
        const a = @as(f32, @floatFromInt((i * 29 + 7) % 101)) - 50;
        v.* = a / 127.0;
    }
    const q = try quant.quantize(f32, allocator, source, .int4, group_size);
    defer {
        allocator.free(q.packed_bytes);
        allocator.free(q.scales);
    }
    const scales_f16 = try allocator.alloc(f16, q.scales.len);
    defer allocator.free(scales_f16);
    for (q.scales, scales_f16) |src_scale, *dst_scale| dst_scale.* = @floatCast(src_scale);
    var weights = engine.int4_weights.Int4WeightData{
        .packed_bytes = q.packed_bytes,
        .scales = q.scales,
        .scales_f16 = if (scale_mode == 1) scales_f16 else &.{},
        .group_size = group_size,
        .num_elements = element_count,
    };
    var rows4_scales: []const f16 = &.{};
    defer if (rows4_scales.len != 0) allocator.free(rows4_scales);
    var reference_packed: []u8 = &.{};
    defer if (reference_packed.len != 0) allocator.free(reference_packed);
    if (scale_mode == 2 or scale_mode == 3) {
        weights = try engine.int4_weights.withRows4F16Scales(allocator, weights, out_f);
        rows4_scales = weights.scales_f16_rows4;
    }
    var reference_weights = weights;
    if (scale_mode == 3) {
        reference_packed = try allocator.dupe(u8, weights.packed_bytes);
        reference_weights.packed_bytes = reference_packed;
        reference_weights.scales_f16_rows4 = &.{};
        weights = try engine.int4_weights.withRows4K16Packing(allocator, weights, out_f);
    }

    const input_values = try allocator.alloc(f32, in_f);
    defer allocator.free(input_values);
    for (input_values, 0..) |*v, i| {
        const a = @as(f32, @floatFromInt((i * 13 + 3) % 47)) - 23;
        v.* = a / 31.0;
    }
    var input = try tensor.fromF32(allocator, &.{ 1, in_f }, input_values);
    defer input.deinit();
    var f32_out = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer f32_out.deinit();
    var q8_out = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer q8_out.deinit();
    var portable_q8_out = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer portable_q8_out.deinit();
    var prepared_q8_out = try tensor.zerosF32(allocator, &.{ 1, out_f });
    defer prepared_q8_out.deinit();

    var pool: std.Thread.Pool = undefined;
    var pool_ptr: ?*std.Thread.Pool = null;
    if (threads > 1) {
        try pool.init(.{ .allocator = allocator, .n_jobs = threads - 1 });
        pool_ptr = &pool;
    }
    defer if (pool_ptr != null) pool.deinit();

    const runF32 = struct {
        fn call(p: ?*std.Thread.Pool, input_tensor: tensor.Tensor, w: engine.int4_weights.Int4WeightData, output: tensor.Tensor, of: usize, inf: usize) !void {
            if (p) |pool_value| return int4.linearInt4WeightParallel(pool_value, input_tensor, w, &.{}, output, of, inf, 16);
            return int4.linearInt4Weight(input_tensor, w, &.{}, output, of, inf);
        }
    }.call;
    const runQ8 = struct {
        fn call(p: ?*std.Thread.Pool, input_tensor: tensor.Tensor, w: engine.int4_weights.Int4WeightData, output: tensor.Tensor, of: usize, inf: usize) !void {
            if (p) |pool_value| return int4.linearInt4WeightParallelQ8(pool_value, input_tensor, w, &.{}, output, of, inf, 16);
            return int4.linearInt4WeightQ8(input_tensor, w, &.{}, output, of, inf);
        }
    }.call;

    // Warmup both paths to remove first-use instruction/cache effects.
    try runF32(pool_ptr, input, reference_weights, f32_out, out_f, in_f);
    try runQ8(pool_ptr, input, weights, q8_out, out_f, in_f);
    // The portable Zig Q8 implementation is a correctness oracle for the
    // architecture-specific SDOT/row-tile kernel; it is intentionally not
    // included in either timed region.
    try int4.linearInt4Q8(input, reference_weights, &.{}, portable_q8_out, out_f, in_f);

    const prepared_supported = builtin.cpu.arch == .aarch64 and
        (group_size == 8 or group_size == 16);
    const prepared_q_input = try allocator.alloc(i8, if (prepared_supported) in_f else 0);
    defer allocator.free(prepared_q_input);
    const prepared_scale_count = if (prepared_supported)
        int4.q8ActivationScaleCount(in_f, group_size)
    else
        0;
    const prepared_scales = try allocator.alloc(f32, prepared_scale_count);
    defer allocator.free(prepared_scales);
    if (prepared_supported) {
        try int4.quantizeQ8Activation(input_values, group_size, prepared_q_input, prepared_scales);
        try int4.linearInt4WeightQ8Prepared(
            prepared_q_input,
            prepared_scales,
            weights,
            &.{},
            prepared_q8_out,
            out_f,
            in_f,
        );
    }

    var f32_timer = try std.time.Timer.start();
    for (0..iterations) |_| try runF32(pool_ptr, input, reference_weights, f32_out, out_f, in_f);
    const f32_ns = f32_timer.read();

    var q8_timer = try std.time.Timer.start();
    for (0..iterations) |_| try runQ8(pool_ptr, input, weights, q8_out, out_f, in_f);
    const q8_ns = q8_timer.read();

    var prepared_q8_ns: ?u64 = null;
    if (prepared_supported) {
        var prepared_timer = try std.time.Timer.start();
        for (0..iterations) |_| try int4.linearInt4WeightQ8Prepared(
            prepared_q_input,
            prepared_scales,
            weights,
            &.{},
            prepared_q8_out,
            out_f,
            in_f,
        );
        prepared_q8_ns = prepared_timer.read();
    }

    var repeated_batch_ns: ?u64 = null;
    var packed_batch_ns: ?u64 = null;
    var packed_batch_parallel_ns: ?u64 = null;
    if (prepared_supported and scale_mode == 3) {
        const batch_in_count = try std.math.mul(usize, batch_size, in_f);
        const batch_out_count = try std.math.mul(usize, batch_size, out_f);
        _ = batch_out_count; // Tensor construction below repeats this checked product.
        const batch_input_values = try allocator.alloc(f32, batch_in_count);
        defer allocator.free(batch_input_values);
        for (batch_input_values, 0..) |*value, i| {
            const a = @as(f32, @floatFromInt((i * 17 + 11) % 59)) - 29;
            value.* = a / 37.0;
        }
        const batch_q = try allocator.alloc(i8, batch_in_count);
        defer allocator.free(batch_q);
        const batch_scale_stride = int4.q8ActivationScaleCount(in_f, group_size);
        const batch_scale_count = try std.math.mul(usize, batch_size, batch_scale_stride);
        const batch_scales = try allocator.alloc(f32, batch_scale_count);
        defer allocator.free(batch_scales);
        try int4.quantizeQ8ActivationBatch(
            batch_input_values,
            batch_size,
            in_f,
            group_size,
            batch_q,
            batch_scales,
        );
        var repeated_out = try tensor.zerosF32(allocator, &.{ batch_size, out_f });
        defer repeated_out.deinit();
        var packed_batch_out = try tensor.zerosF32(allocator, &.{ batch_size, out_f });
        defer packed_batch_out.deinit();
        var parallel_out = try tensor.zerosF32(allocator, &.{ batch_size, out_f });
        defer parallel_out.deinit();

        var row_shape = [2]usize{ 1, out_f };
        var repeated_timer = try std.time.Timer.start();
        for (0..iterations) |_| {
            for (0..batch_size) |row| {
                const row_out: tensor.Tensor = .{
                    .dtype = .f32,
                    .shape = &row_shape,
                    .data = std.mem.sliceAsBytes(
                        repeated_out.asF32()[row * out_f ..][0..out_f],
                    ),
                    .allocator = std.heap.page_allocator,
                };
                try int4.linearInt4WeightQ8Prepared(
                    batch_q[row * in_f ..][0..in_f],
                    batch_scales[row * batch_scale_stride ..][0..batch_scale_stride],
                    weights,
                    &.{},
                    row_out,
                    out_f,
                    in_f,
                );
            }
        }
        repeated_batch_ns = repeated_timer.read();

        var packed_batch_timer = try std.time.Timer.start();
        for (0..iterations) |_| try int4.linearInt4WeightQ8PreparedBatch(
            batch_q,
            batch_scales,
            weights,
            &.{},
            packed_batch_out,
            out_f,
            in_f,
        );
        packed_batch_ns = packed_batch_timer.read();

        if (pool_ptr) |thread_pool| {
            var parallel_timer = try std.time.Timer.start();
            for (0..iterations) |_| try int4.linearInt4WeightQ8PreparedBatchParallel(
                thread_pool,
                batch_q,
                batch_scales,
                weights,
                &.{},
                parallel_out,
                out_f,
                in_f,
                threads,
            );
            packed_batch_parallel_ns = parallel_timer.read();
        }
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(repeated_out.asF32()), std.mem.sliceAsBytes(packed_batch_out.asF32())))
            return error.BatchMismatch;
        if (packed_batch_parallel_ns != null and
            !std.mem.eql(u8, std.mem.sliceAsBytes(repeated_out.asF32()), std.mem.sliceAsBytes(parallel_out.asF32())))
            return error.BatchMismatch;
    }

    var max_abs: f32 = 0;
    for (f32_out.asF32(), q8_out.asF32()) |a, b| max_abs = @max(max_abs, @abs(a - b));
    var max_abs_portable: f32 = 0;
    for (portable_q8_out.asF32(), q8_out.asF32()) |a, b| max_abs_portable = @max(max_abs_portable, @abs(a - b));
    var max_abs_prepared: f32 = 0;
    if (prepared_supported) {
        for (prepared_q8_out.asF32(), q8_out.asF32()) |a, b|
            max_abs_prepared = @max(max_abs_prepared, @abs(a - b));
    }
    const f32_ms = @as(f64, @floatFromInt(f32_ns)) / 1e6;
    const q8_ms = @as(f64, @floatFromInt(q8_ns)) / 1e6;
    const speedup = if (q8_ms == 0) 0 else f32_ms / q8_ms;
    const bytes = @as(f64, @floatFromInt(element_count));
    const f32_bw = bytes * 0.5 * @as(f64, @floatFromInt(iterations)) /
        (@as(f64, @floatFromInt(f32_ns)) / 1e9) / (1024 * 1024 * 1024);
    const q8_bw = bytes * 0.5 * @as(f64, @floatFromInt(iterations)) /
        (@as(f64, @floatFromInt(q8_ns)) / 1e9) / (1024 * 1024 * 1024);

    const stdout = std.fs.File.stdout();
    var buf: [2048]u8 = undefined;
    var writer = std.fs.File.Writer.init(stdout, &buf);
    try writer.interface.print(
        "int4-kernel: out={d} in={d} group={d} iterations={d}\n",
        .{ out_f, in_f, group_size, iterations },
    );
    try writer.interface.print(
        "  f32 activation: {d:.3} ms ({d:.2} GiB/s)\n",
        .{ f32_ms, f32_bw },
    );
    try writer.interface.print(
        "  q8 activation:  {d:.3} ms ({d:.2} GiB/s)\n",
        .{ q8_ms, q8_bw },
    );
    if (prepared_q8_ns) |ns| {
        const prepared_ms = @as(f64, @floatFromInt(ns)) / 1e6;
        const prepared_bw = bytes * 0.5 * @as(f64, @floatFromInt(iterations)) /
            (@as(f64, @floatFromInt(ns)) / 1e9) / (1024 * 1024 * 1024);
        try writer.interface.print(
            "  prepared q8:   {d:.3} ms ({d:.2} GiB/s) delta={d:.6}\n",
            .{ prepared_ms, prepared_bw, max_abs_prepared },
        );
    }
    if (repeated_batch_ns) |reference_ns| {
        const batch_ns = packed_batch_ns.?;
        const batch_kernel_label = if (comptime builtin.cpu.arch == .aarch64 and
            builtin.cpu.features.isEnabled(
                @intFromEnum(std.Target.aarch64.Feature.dotprod),
            ))
            "packed-m4"
        else
            "batch-api-m1-fallback";
        try writer.interface.print(
            "  batch M={d}: serial-m1={d:.3} ms {s}-1t={d:.3} ms batching-only={d:.2}x\n",
            .{
                batch_size,
                @as(f64, @floatFromInt(reference_ns)) / 1e6,
                batch_kernel_label,
                @as(f64, @floatFromInt(batch_ns)) / 1e6,
                @as(f64, @floatFromInt(reference_ns)) / @as(f64, @floatFromInt(batch_ns)),
            },
        );
        if (packed_batch_parallel_ns) |parallel_ns| {
            try writer.interface.print(
                "  batch M={d}: {s}-{d}t={d:.3} ms combined-vs-serial-m1={d:.2}x\n",
                .{
                    batch_size,
                    batch_kernel_label,
                    threads,
                    @as(f64, @floatFromInt(parallel_ns)) / 1e6,
                    @as(f64, @floatFromInt(reference_ns)) / @as(f64, @floatFromInt(parallel_ns)),
                },
            );
        }
    }
    try writer.interface.print(
        "  speedup: {d:.2}x  max_abs_output_delta: {d:.6}  portable_q8_delta: {d:.6}\n",
        .{ speedup, max_abs, max_abs_portable },
    );
    try writer.interface.flush();
}
