//! Integration test: full layer walk through the pager against the CPU
//! backend, verifying the load/eviction/reload cycle behaves as the
//! docs claim.

const std = @import("std");
const engine = @import("engine");
const core = engine.core;

const testing = std.testing;

fn makePageTable(
    allocator: std.mem.Allocator,
    total_pages: usize,
    pages_per_layer: u32,
) !*core.PageTable {
    if (pages_per_layer == 0 or total_pages % pages_per_layer != 0)
        return error.InvalidPageGeometry;
    const num_layers = total_pages / pages_per_layer;
    const entries = try allocator.alloc(core.PageEntry, total_pages);
    errdefer allocator.free(entries);
    var id_map = std.AutoHashMap(u64, usize).init(allocator);
    errdefer id_map.deinit();
    for (0..total_pages) |i| {
        const layer_idx = i / pages_per_layer;
        const stored_precision: core.Precision =
            if (layer_idx < 2 or layer_idx + 2 >= num_layers) .fp16 else .int4;
        entries[i] = .{
            .page_id = i,
            .layer_idx = @intCast(layer_idx),
            .payload_bytes = 1024,
            .stored_precision = stored_precision,
        };
        try id_map.put(i, i);
    }
    const table_ptr = try allocator.create(core.PageTable);
    errdefer allocator.destroy(table_ptr);
    table_ptr.* = .{ .entries = entries, .id_to_index = id_map };
    return table_ptr;
}

test "full forward pass through pager" {
    const num_layers: u32 = 6;
    const pages_per_layer: u32 = 3;
    const total_pages = num_layers * pages_per_layer;

    const table_ptr = try makePageTable(
        testing.allocator,
        total_pages,
        pages_per_layer,
    );
    defer {
        table_ptr.deinit(testing.allocator);
        testing.allocator.destroy(table_ptr);
    }

    var backend = engine.CpuBackend.init(testing.allocator);
    defer backend.deinit();

    var pager = core.Pager.init(testing.allocator, table_ptr, backend.asBackend(), .{
        .budget_bytes = 3 * 1024, // exactly one layer at a time
    });
    defer pager.deinit();

    var prof = try core.precision.precisionProfileFor(testing.allocator, num_layers);
    defer prof.deinit(testing.allocator);
    const sched = core.scheduler.Scheduler.init(&prof);

    var layer: u32 = 0;
    while (layer < num_layers) : (layer += 1) {
        const base = layer * pages_per_layer;
        const ids = try testing.allocator.alloc(u64, pages_per_layer);
        defer testing.allocator.free(ids);
        for (0..pages_per_layer) |p| ids[p] = base + p;
        try sched.ensureLayerResident(&pager, ids, layer);
    }

    // With a 3-page budget and 18 total page-touches spread across 6
    // layers, every page should have been loaded at least once.
    try testing.expect(pager.loads == total_pages);
    // And we should have evicted to stay within budget.
    try testing.expect(pager.evictions > 0);
}
