//! Quantization error harness.
//!
//! The real perplexity benchmark needs a forward pass, which the Metal
//! milestone unlocks. What we CAN measure today — and what actually
//! answers "is the P-axis worth it" — is the per-tensor error that
//! quantization introduces. If INT4 quant on real weights blows up the
//! error, the rest of the engine is moot. If it stays low, the perplexity
//! benchmark later will likely confirm we are in the right ballpark.
//!
//! This script:
//!   1. Reads a safetensors model.
//!   2. For each F32/F16 tensor, quantizes it to INT4 (group_size 64) and
//!      dequantizes back.
//!   3. Reports per-tensor and aggregate stats:
//!        max_abs_error, mean_abs_error, max_rel_error, mse,
//!        compression_ratio.
//!
//! Usage: glacier-bench-quant <model.safetensors>

const std = @import("std");
const engine = @import("engine");

const TensorStats = struct {
    name: []const u8,
    num_elements: u64,
    raw_bytes: u64,
    quant_bytes: u64,
    max_abs_error: f64,
    mean_abs_error: f64,
    max_rel_error: f64,
    mse: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var bw = std.fs.File.Writer.init(stdout, &buf);
    defer bw.interface.flush() catch {};

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 2) {
        try bw.interface.print("usage: glacier-bench-quant <model.safetensors>\n", .{});
        return error.InvalidUsage;
    }

    var stats = try benchFile(allocator, args[1]);
    defer {
        for (stats.items) |s| allocator.free(s.name);
        stats.deinit(allocator);
    }

    // Aggregate.
    var total_raw: u64 = 0;
    var total_quant: u64 = 0;
    var worst_max_abs: f64 = 0;
    var worst_mse: f64 = 0;
    var sum_mse: f64 = 0;
    var mse_count: usize = 0;
    for (stats.items) |s| {
        total_raw += s.raw_bytes;
        total_quant += s.quant_bytes;
        if (s.max_abs_error > worst_max_abs) worst_max_abs = s.max_abs_error;
        if (s.mse > worst_mse) worst_mse = s.mse;
        if (std.math.isFinite(s.mse)) {
            sum_mse += s.mse;
            mse_count += 1;
        }
    }

    const ratio: f64 = if (total_quant == 0) 0 else @as(f64, @floatFromInt(total_raw)) / @as(f64, @floatFromInt(total_quant));

    try bw.interface.print(
        "quant-error report: {s}\n",
        .{args[1]},
    );
    try bw.interface.print(
        "  tensors:    {d}\n",
        .{stats.items.len},
    );
    try bw.interface.print(
        "  raw bytes:  {d} ({d:.2} MiB)\n",
        .{ total_raw, @as(f64, @floatFromInt(total_raw)) / (1024.0 * 1024.0) },
    );
    try bw.interface.print(
        "  quant bytes:{d} ({d:.2} MiB)\n",
        .{ total_quant, @as(f64, @floatFromInt(total_quant)) / (1024.0 * 1024.0) },
    );
    try bw.interface.print(
        "  compression ratio: {d:.3}x\n",
        .{ratio},
    );
    try bw.interface.print(
        "  worst max_abs_error: {e}\n",
        .{worst_max_abs},
    );
    try bw.interface.print(
        "  worst mse:           {e}\n",
        .{worst_mse},
    );
    try bw.interface.print(
        "  mean mse (finite):   {e}\n",
        .{sum_mse / @as(f64, @floatFromInt(mse_count))},
    );

    // Top 5 worst tensors by max_abs_error.
    std.sort.heap(TensorStats, stats.items, {}, struct {
        fn lessThan(_: void, a: TensorStats, b: TensorStats) bool {
            return a.max_abs_error > b.max_abs_error;
        }
    }.lessThan);

    try bw.interface.print("\n  top 5 worst tensors by max_abs_error:\n", .{});
    const shown = @min(stats.items.len, 5);
    for (stats.items[0..shown]) |s| {
        try bw.interface.print(
            "    {e}  {s} ({d} elems, {d:.2}x)\n",
            .{
                s.max_abs_error,
                s.name,
                s.num_elements,
                @as(f64, @floatFromInt(s.raw_bytes)) / @as(f64, @floatFromInt(@max(s.quant_bytes, 1))),
            },
        );
    }
}

fn benchFile(allocator: std.mem.Allocator, path: []const u8) !std.ArrayList(TensorStats) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const map_len = std.math.cast(usize, stat.size) orelse
        return error.FileTooLarge;
    const mapping = try engine.runtime_image.ReadOnlyFileMapping.init(
        file,
        map_len,
    );
    defer mapping.close();
    const mapped = mapping.bytes;

    var sf = try engine.safetensors.parseHeader(allocator, mapped);
    defer sf.deinit();

    var results: std.ArrayList(TensorStats) = .{};
    errdefer {
        for (results.items) |_| {}
        results.deinit(allocator);
    }

    const group_size: u32 = 64;
    for (sf.tensors) |t| {
        // Only F32 source is quantizable by the MVP quant.
        if (t.dtype != .f32) continue;

        const base = sf.data_region_start + t.data_offset;
        const tensor_bytes = mapped[@intCast(base)..@intCast(base + t.byte_length)];
        const num_elements = tensor_bytes.len / @sizeOf(f32);

        // Copy into aligned f32 slice.
        const src = try allocator.alloc(f32, num_elements);
        defer allocator.free(src);
        @memcpy(@as([*]u8, @ptrCast(src.ptr))[0..tensor_bytes.len], tensor_bytes);

        // Quantize + dequantize in memory.
        const q = try engine.core.quant.quantize(f32, allocator, src, .int4, group_size);
        defer {
            allocator.free(q.packed_bytes);
            allocator.free(q.scales);
        }
        const back = try engine.core.quant.dequantize(f32, allocator, q.packed_bytes, q.scales, .int4, group_size, num_elements);
        defer allocator.free(back);

        // Compute stats.
        var max_abs: f64 = 0;
        var sum_abs: f64 = 0;
        var max_rel: f64 = 0;
        var sum_sq: f64 = 0;
        for (src, back) |a, b| {
            const af: f64 = a;
            const bf: f64 = b;
            const err = if (af > bf) af - bf else bf - af;
            if (err > max_abs) max_abs = err;
            sum_abs += err;
            const denom = if (@abs(af) > 1e-9) @abs(af) else 1e-9;
            const rel = err / denom;
            if (rel > max_rel) max_rel = rel;
            const d = af - bf;
            sum_sq += d * d;
        }
        const mean_abs = sum_abs / @as(f64, @floatFromInt(num_elements));
        const mse = sum_sq / @as(f64, @floatFromInt(num_elements));

        // Quant payload size estimate (matches qio.encodePage layout).
        const num_groups = (num_elements + group_size - 1) / group_size;
        const scales_bytes = num_groups * @sizeOf(f32);
        const packed_bytes_len = (num_elements * 4 + 7) / 8;
        const quant_total = 16 + scales_bytes + packed_bytes_len;

        const name_copy = try allocator.dupe(u8, t.name);
        try results.append(allocator, .{
            .name = name_copy,
            .num_elements = num_elements,
            .raw_bytes = tensor_bytes.len,
            .quant_bytes = quant_total,
            .max_abs_error = max_abs,
            .mean_abs_error = mean_abs,
            .max_rel_error = max_rel,
            .mse = mse,
        });
    }

    return results;
}
