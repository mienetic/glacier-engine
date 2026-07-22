//! Benchmark harness — measures the thing the engine exists to optimize:
//! bytes transferred across the bus vs. llama.cpp at equal perplexity.
//!
//! For now it just drives the pager through a large synthetic page table
//! and reports load/hit/eviction/byte stats. Real perplexity comparison
//! comes once the converter + dequant kernels land.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.Writer.init(stdout, &buf);
    defer bw.interface.flush() catch {};

    // 24-layer synthetic model, 4 pages per layer, 256 KiB each.
    const num_layers: u32 = 24;
    const pages_per_layer: u32 = 4;
    const total_pages = num_layers * pages_per_layer;

    var entries = try allocator.alloc(core.PageEntry, total_pages);
    var id_map = std.AutoHashMap(u64, usize).init(allocator);
    for (0..total_pages) |i| {
        entries[i] = .{
            .page_id = i,
            .layer_idx = @intCast(i / pages_per_layer),
            .payload_bytes = 256 * 1024,
            .stored_precision = .int4,
        };
        try id_map.put(i, i);
    }
    const table_ptr = try allocator.create(core.PageTable);
    defer {
        table_ptr.deinit(allocator); // frees entries + id_map
        allocator.destroy(table_ptr);
    }
    table_ptr.* = .{ .entries = entries, .id_to_index = id_map };

    var backend = engine.CpuBackend.init(allocator);
    defer backend.deinit();

    // Tight budget: only enough for ~2 layers resident at once.
    var pager = core.Pager.init(allocator, table_ptr, backend.asBackend(), .{
        .budget_bytes = 2 * pages_per_layer * 256 * 1024,
    });
    defer pager.deinit();

    var prof = try core.precision.precisionProfileFor(allocator, num_layers);
    defer prof.deinit(allocator);
    const sched = core.scheduler.Scheduler.init(&prof);

    // Simulate 16 generated tokens, each touching every layer.
    const num_tokens: u32 = 16;
    var t0 = try std.time.Timer.start();
    var t: u32 = 0;
    while (t < num_tokens) : (t += 1) {
        var layer: u32 = 0;
        while (layer < num_layers) : (layer += 1) {
            const base = layer * pages_per_layer;
            const slice_ids = try allocator.alloc(u64, pages_per_layer);
            defer allocator.free(slice_ids);
            for (0..pages_per_layer) |p| slice_ids[p] = base + p;
            try sched.ensureLayerResident(&pager, slice_ids, layer);
        }
    }
    const elapsed_ns = t0.read();

    try bw.interface.print(
        "glacier-bench: {d} tokens × {d} layers × {d} pages\n",
        .{ num_tokens, num_layers, pages_per_layer },
    );
    try bw.interface.print(
        "loads={d} hits={d} evictions={d}\n",
        .{ pager.loads, pager.hits, pager.evictions },
    );
    try bw.interface.print(
        "bytes_transferred={d} ({d:.2} MiB)\n",
        .{
            pager.bytesTransferred(),
            @as(f64, @floatFromInt(pager.bytesTransferred())) / (1024.0 * 1024.0),
        },
    );
    try bw.interface.print(
        "elapsed={d:.2} ms\n",
        .{@as(f64, @floatFromInt(elapsed_ns)) / 1e6},
    );
}
