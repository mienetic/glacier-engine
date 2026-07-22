//! Request-local scratch for the packed batched prefill path.
//!
//! One chunk is processed layer by layer, so these buffers are reused across
//! every layer rather than multiplied by model depth. The materialized frame
//! retains the historical gate/up/SwiGLU matrices. The compact Pair frame
//! instead owns one bounded M1..M4 capsule, its exact Q8/down-scale payload,
//! and task-private gate/up tiles. Both layouts keep allocation arithmetic in
//! a checked, reproducible logical-byte ledger.

const std = @import("std");
const tensor = @import("core").tensor;

pub const Tensor = tensor.Tensor;

pub const Kind = enum {
    materialized,
    compact_pair,
};

/// All dimensions needed to admit one depth-independent prefill frame before
/// any request storage is allocated. Compact-only fields must be zero for the
/// materialized compatibility layout and complete for the compact layout.
pub const Spec = struct {
    kind: Kind,
    max_batch: usize,
    dim: usize,
    kv_dim: usize,
    hidden: usize,
    max_scale_stride: usize,
    task_slots: usize = 0,
    capsule_rows: usize = 0,
    tile_rows: usize = 0,
    pair_scale_stride: usize = 0,

    pub fn logicalLedger(self: Spec) !LogicalLedger {
        return deriveLogicalLedger(self);
    }
};

/// Exact typed-slice contribution to the logical allocation ledger. Allocator
/// metadata is excluded. Every field is computed with checked arithmetic.
pub const StorageBreakdown = struct {
    common_dim_f32_bytes: usize,
    common_kv_f32_bytes: usize,
    q_scratch_bytes: usize,
    scale_scratch_bytes: usize,
    gate_bytes: usize,
    up_bytes: usize,
    silu_gate_bytes: usize,
    pair_q8_bytes: usize,
    pair_scale_bytes: usize,
    gate_tile_bytes: usize,
    up_tile_bytes: usize,

    pub fn total(self: StorageBreakdown) !usize {
        var result: usize = 0;
        inline for (std.meta.fields(StorageBreakdown)) |field| {
            result = try std.math.add(usize, result, @field(self, field.name));
        }
        return result;
    }
};

pub const LogicalLedger = struct {
    kind: Kind,
    breakdown: StorageBreakdown,
    tensor_storage_bytes: usize,
    materialized_counterfactual_bytes: usize,
    reclaimed_bytes: usize,
};

pub const Buffers = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    max_batch: usize,
    dim: usize,
    kv_dim: usize,
    hidden: usize,
    max_scale_stride: usize,
    task_slots: usize,
    capsule_rows: usize,
    tile_rows: usize,
    pair_scale_stride: usize,
    ledger: LogicalLedger,

    x: []f32,
    next: []f32,
    h_norm: []f32,
    q: []f32,
    k: []f32,
    v: []f32,
    attn_out: []f32,
    proj: []f32,
    h: []f32,
    mlp_norm: []f32,
    gate: []f32,
    up: []f32,
    silu_gate: []f32,
    down: []f32,
    q_scratch: []i8,
    scale_scratch: []f32,

    /// Compact Pair output consumed by prepared down. These are deliberately
    /// distinct from `q_scratch`/`scale_scratch`, which hold the compact
    /// producer's input activation.
    pair_q8: []align(64) i8,
    pair_scales: []align(64) f32,
    /// Task-slot-major `[task][capsule row][tile row]` branch scratch.
    gate_tile: []align(64) f32,
    up_tile: []align(64) f32,

    /// Historical constructor: retain the exact materialized layout and its
    /// caller-provided signature while routing all arithmetic through `Spec`.
    pub fn init(
        allocator: std.mem.Allocator,
        max_batch: usize,
        dim: usize,
        kv_dim: usize,
        hidden: usize,
        max_scale_stride: usize,
    ) !Buffers {
        return initWithSpec(allocator, .{
            .kind = .materialized,
            .max_batch = max_batch,
            .dim = dim,
            .kv_dim = kv_dim,
            .hidden = hidden,
            .max_scale_stride = max_scale_stride,
        });
    }

    pub fn initWithSpec(
        allocator: std.mem.Allocator,
        spec: Spec,
    ) !Buffers {
        // Derive and validate the complete logical ledger before the first
        // allocation. This prevents malformed compact geometry from leaving a
        // partially allocated request frame.
        const ledger = try spec.logicalLedger();
        const dim_count = try std.math.mul(usize, spec.max_batch, spec.dim);
        const kv_count = try std.math.mul(usize, spec.max_batch, spec.kv_dim);
        const scale_count = try std.math.mul(
            usize,
            spec.max_batch,
            spec.max_scale_stride,
        );
        const q_count = switch (spec.kind) {
            .materialized => try std.math.mul(
                usize,
                spec.max_batch,
                @max(spec.dim, spec.hidden),
            ),
            .compact_pair => dim_count,
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        // Allocate aligned zero-length slices once so inactive representation
        // fields retain a stable, correctly aligned slice type.
        const empty_pair_q8 = try a.alignedAlloc(i8, .@"64", 0);
        const empty_pair_f32 = try a.alignedAlloc(f32, .@"64", 0);
        const empty_f32 = try a.alloc(f32, 0);

        // Preserve the historical materialized allocation order through the
        // last common pre-MLP activation. Some allocators place these slices
        // in one block, so compatibility includes their lifetime ordering.
        const x = try a.alloc(f32, dim_count);
        const next = try a.alloc(f32, dim_count);
        const h_norm = try a.alloc(f32, dim_count);
        const q = try a.alloc(f32, dim_count);
        const k = try a.alloc(f32, kv_count);
        const v = try a.alloc(f32, kv_count);
        const attn_out = try a.alloc(f32, dim_count);
        const proj = try a.alloc(f32, dim_count);
        const h = try a.alloc(f32, dim_count);
        const mlp_norm = try a.alloc(f32, dim_count);

        var gate = empty_f32;
        var up = empty_f32;
        var silu_gate = empty_f32;
        var pair_q8 = empty_pair_q8;
        var pair_scales = empty_pair_f32;
        var gate_tile = empty_pair_f32;
        var up_tile = empty_pair_f32;
        switch (spec.kind) {
            .materialized => {
                const hidden_count = try std.math.mul(
                    usize,
                    spec.max_batch,
                    spec.hidden,
                );
                gate = try a.alloc(f32, hidden_count);
                up = try a.alloc(f32, hidden_count);
                silu_gate = try a.alloc(f32, hidden_count);
            },
            .compact_pair => {
                const pair_q8_count = try std.math.mul(
                    usize,
                    spec.capsule_rows,
                    spec.hidden,
                );
                const pair_scale_count = try std.math.mul(
                    usize,
                    spec.capsule_rows,
                    spec.pair_scale_stride,
                );
                const tile_slot_stride = try std.math.mul(
                    usize,
                    spec.capsule_rows,
                    spec.tile_rows,
                );
                const tile_count = try std.math.mul(
                    usize,
                    spec.task_slots,
                    tile_slot_stride,
                );
                pair_q8 = try a.alignedAlloc(i8, .@"64", pair_q8_count);
                pair_scales = try a.alignedAlloc(f32, .@"64", pair_scale_count);
                gate_tile = try a.alignedAlloc(f32, .@"64", tile_count);
                up_tile = try a.alignedAlloc(f32, .@"64", tile_count);
            },
        }

        // Allocate every remaining slice before moving the arena into the
        // return value. Moving it earlier would retain a stale linked-list
        // head when one of these later allocations grows the arena.
        const down = try a.alloc(f32, dim_count);
        const q_scratch = try a.alloc(i8, q_count);
        const scale_scratch = try a.alloc(f32, scale_count);
        const result: Buffers = .{
            .arena = arena,
            .kind = spec.kind,
            .max_batch = spec.max_batch,
            .dim = spec.dim,
            .kv_dim = spec.kv_dim,
            .hidden = spec.hidden,
            .max_scale_stride = spec.max_scale_stride,
            .task_slots = spec.task_slots,
            .capsule_rows = spec.capsule_rows,
            .tile_rows = spec.tile_rows,
            .pair_scale_stride = spec.pair_scale_stride,
            .ledger = ledger,
            .x = x,
            .next = next,
            .h_norm = h_norm,
            .q = q,
            .k = k,
            .v = v,
            .attn_out = attn_out,
            .proj = proj,
            .h = h,
            .mlp_norm = mlp_norm,
            .gate = gate,
            .up = up,
            .silu_gate = silu_gate,
            .down = down,
            .q_scratch = q_scratch,
            .scale_scratch = scale_scratch,
            .pair_q8 = pair_q8,
            .pair_scales = pair_scales,
            .gate_tile = gate_tile,
            .up_tile = up_tile,
        };
        std.debug.assert(result.sliceStorageBytes() == ledger.tensor_storage_bytes);
        return result;
    }

    pub fn deinit(self: *Buffers) void {
        self.arena.deinit();
    }

    pub fn logicalLedger(self: *const Buffers) LogicalLedger {
        return self.ledger;
    }

    pub fn tensorStorageBytes(self: *const Buffers) usize {
        return self.ledger.tensor_storage_bytes;
    }

    pub fn materializedCounterfactualBytes(self: *const Buffers) usize {
        return self.ledger.materialized_counterfactual_bytes;
    }

    pub fn reclaimedPayloadBytes(self: *const Buffers) usize {
        return self.ledger.reclaimed_bytes;
    }

    pub fn reclaimedBytes(self: *const Buffers) usize {
        return self.reclaimedPayloadBytes();
    }

    fn sliceStorageBytes(self: *const Buffers) usize {
        const f32_elements = self.x.len + self.next.len + self.h_norm.len +
            self.q.len + self.k.len + self.v.len + self.attn_out.len +
            self.proj.len + self.h.len + self.mlp_norm.len + self.gate.len +
            self.up.len + self.silu_gate.len + self.down.len +
            self.scale_scratch.len + self.pair_scales.len +
            self.gate_tile.len + self.up_tile.len;
        return f32_elements * @sizeOf(f32) + self.q_scratch.len +
            self.pair_q8.len;
    }

    pub fn view(
        buffer: []f32,
        shape_storage: *[2]usize,
        rows: usize,
        cols: usize,
    ) Tensor {
        // This is an internal scratch view, but keep malformed dimensions from
        // wrapping into a deceptively small slice in optimized builds.
        const count = std.math.mul(usize, rows, cols) catch
            @panic("prefill buffer view size overflow");
        if (count > buffer.len) @panic("prefill buffer view exceeds allocation");
        shape_storage.* = .{ rows, cols };
        return .{
            .dtype = .f32,
            .shape = shape_storage,
            .data = std.mem.sliceAsBytes(buffer[0..count]),
            .allocator = std.heap.page_allocator,
        };
    }
};

fn deriveLogicalLedger(spec: Spec) !LogicalLedger {
    try validateSpec(spec);

    const dim_count = try std.math.mul(usize, spec.max_batch, spec.dim);
    const kv_count = try std.math.mul(usize, spec.max_batch, spec.kv_dim);
    const dim_elements = try std.math.mul(usize, dim_count, 9);
    const kv_elements = try std.math.mul(usize, kv_count, 2);
    const common_dim_f32_bytes = try std.math.mul(
        usize,
        dim_elements,
        @sizeOf(f32),
    );
    const common_kv_f32_bytes = try std.math.mul(
        usize,
        kv_elements,
        @sizeOf(f32),
    );
    const scale_count = try std.math.mul(
        usize,
        spec.max_batch,
        spec.max_scale_stride,
    );
    const scale_scratch_bytes = try std.math.mul(
        usize,
        scale_count,
        @sizeOf(f32),
    );

    var breakdown: StorageBreakdown = .{
        .common_dim_f32_bytes = common_dim_f32_bytes,
        .common_kv_f32_bytes = common_kv_f32_bytes,
        .q_scratch_bytes = 0,
        .scale_scratch_bytes = scale_scratch_bytes,
        .gate_bytes = 0,
        .up_bytes = 0,
        .silu_gate_bytes = 0,
        .pair_q8_bytes = 0,
        .pair_scale_bytes = 0,
        .gate_tile_bytes = 0,
        .up_tile_bytes = 0,
    };

    switch (spec.kind) {
        .materialized => {
            const max_in_count = try std.math.mul(
                usize,
                spec.max_batch,
                @max(spec.dim, spec.hidden),
            );
            const hidden_count = try std.math.mul(
                usize,
                spec.max_batch,
                spec.hidden,
            );
            const hidden_bytes = try std.math.mul(
                usize,
                hidden_count,
                @sizeOf(f32),
            );
            breakdown.q_scratch_bytes = max_in_count;
            breakdown.gate_bytes = hidden_bytes;
            breakdown.up_bytes = hidden_bytes;
            breakdown.silu_gate_bytes = hidden_bytes;
        },
        .compact_pair => {
            breakdown.q_scratch_bytes = dim_count;
            breakdown.pair_q8_bytes = try std.math.mul(
                usize,
                spec.capsule_rows,
                spec.hidden,
            );
            const pair_scale_count = try std.math.mul(
                usize,
                spec.capsule_rows,
                spec.pair_scale_stride,
            );
            breakdown.pair_scale_bytes = try std.math.mul(
                usize,
                pair_scale_count,
                @sizeOf(f32),
            );
            const slot_stride = try std.math.mul(
                usize,
                spec.capsule_rows,
                spec.tile_rows,
            );
            const tile_count = try std.math.mul(
                usize,
                spec.task_slots,
                slot_stride,
            );
            const tile_bytes = try std.math.mul(
                usize,
                tile_count,
                @sizeOf(f32),
            );
            breakdown.gate_tile_bytes = tile_bytes;
            breakdown.up_tile_bytes = tile_bytes;
        },
    }

    const tensor_storage_bytes = try breakdown.total();
    const materialized_counterfactual_bytes = try materializedCounterfactual(spec);
    if (tensor_storage_bytes > materialized_counterfactual_bytes)
        return error.InvalidShape;
    return .{
        .kind = spec.kind,
        .breakdown = breakdown,
        .tensor_storage_bytes = tensor_storage_bytes,
        .materialized_counterfactual_bytes = materialized_counterfactual_bytes,
        .reclaimed_bytes = materialized_counterfactual_bytes - tensor_storage_bytes,
    };
}

fn validateSpec(spec: Spec) !void {
    if (spec.max_batch == 0 or spec.dim == 0 or spec.kv_dim == 0 or
        spec.hidden == 0 or spec.max_scale_stride == 0)
        return error.InvalidShape;
    const max_in = @max(spec.dim, spec.hidden);
    switch (spec.kind) {
        .materialized => {
            if (spec.task_slots != 0 or spec.capsule_rows != 0 or
                spec.tile_rows != 0 or spec.pair_scale_stride != 0)
                return error.InvalidShape;
        },
        .compact_pair => {
            if (spec.max_scale_stride > max_in or spec.task_slots == 0 or
                spec.capsule_rows == 0 or
                spec.capsule_rows > spec.max_batch or spec.tile_rows == 0 or
                spec.tile_rows > spec.hidden or spec.tile_rows % 32 != 0 or
                spec.pair_scale_stride == 0 or
                spec.pair_scale_stride > spec.hidden)
                return error.InvalidShape;
            // A normal capsule is M4 (or a multiple thereof). M1--M3 are the
            // only admitted active-tail capacities.
            if (spec.capsule_rows > 3 and spec.capsule_rows % 4 != 0)
                return error.InvalidShape;
        },
    }
}

fn materializedCounterfactual(spec: Spec) !usize {
    const max_in = @max(spec.dim, spec.hidden);
    const historical: Spec = .{
        .kind = .materialized,
        .max_batch = spec.max_batch,
        .dim = spec.dim,
        .kv_dim = spec.kv_dim,
        .hidden = spec.hidden,
        // The legacy materialized constructor treated this as caller-owned
        // capacity rather than a derived geometry. Preserve that exact frame
        // for compatibility; compact candidates retain the historical H/8
        // materialized control used by their reclaim receipt.
        .max_scale_stride = switch (spec.kind) {
            .materialized => spec.max_scale_stride,
            .compact_pair => ceilDiv8(max_in),
        },
    };
    const dim_count = try std.math.mul(usize, historical.max_batch, historical.dim);
    const kv_count = try std.math.mul(usize, historical.max_batch, historical.kv_dim);
    const hidden_count = try std.math.mul(
        usize,
        historical.max_batch,
        historical.hidden,
    );
    const scale_count = try std.math.mul(
        usize,
        historical.max_batch,
        historical.max_scale_stride,
    );
    var total: usize = 0;
    total = try std.math.add(
        usize,
        total,
        try std.math.mul(usize, try std.math.mul(usize, dim_count, 9), @sizeOf(f32)),
    );
    total = try std.math.add(
        usize,
        total,
        try std.math.mul(usize, try std.math.mul(usize, kv_count, 2), @sizeOf(f32)),
    );
    total = try std.math.add(usize, total, try std.math.mul(usize, historical.max_batch, max_in));
    total = try std.math.add(
        usize,
        total,
        try std.math.mul(usize, scale_count, @sizeOf(f32)),
    );
    total = try std.math.add(
        usize,
        total,
        try std.math.mul(usize, try std.math.mul(usize, hidden_count, 3), @sizeOf(f32)),
    );
    return total;
}

fn ceilDiv8(value: usize) usize {
    return value / 8 + @intFromBool(value % 8 != 0);
}

test "prefill buffers size views to the active chunk" {
    var buffers = try Buffers.init(std.testing.allocator, 8, 16, 4, 32, 4);
    defer buffers.deinit();
    var shape: [2]usize = undefined;
    const active = Buffers.view(buffers.gate, &shape, 3, 32);
    try std.testing.expectEqualSlices(usize, &.{ 3, 32 }, active.shape);
    try std.testing.expectEqual(@as(usize, 3 * 32), active.asF32().len);
}

test "materialized wrapper preserves historical frame and exact ledger" {
    const testing = std.testing;
    var buffers = try Buffers.init(testing.allocator, 8, 16, 4, 32, 4);
    defer buffers.deinit();
    try testing.expectEqual(Kind.materialized, buffers.kind);
    try testing.expectEqual(@as(usize, 8 * 32), buffers.gate.len);
    try testing.expectEqual(@as(usize, 8 * 32), buffers.up.len);
    try testing.expectEqual(@as(usize, 8 * 32), buffers.silu_gate.len);
    try testing.expectEqual(@as(usize, 8 * 32), buffers.q_scratch.len);
    try testing.expectEqual(@as(usize, 0), buffers.pair_q8.len);
    try testing.expectEqual(@as(usize, 0), buffers.pair_scales.len);
    try testing.expectEqual(@as(usize, 0), buffers.gate_tile.len);
    try testing.expectEqual(@as(usize, 0), buffers.up_tile.len);
    try testing.expectEqual(buffers.tensorStorageBytes(), buffers.materializedCounterfactualBytes());
    try testing.expectEqual(@as(usize, 0), buffers.reclaimedPayloadBytes());
}

test "materialized wrapper preserves arbitrary positive legacy scale stride" {
    const testing = std.testing;
    for ([_]usize{ 1, 3, 33, 257 }) |scale_stride| {
        var buffers = try Buffers.init(
            testing.allocator,
            2,
            16,
            4,
            32,
            scale_stride,
        );
        defer buffers.deinit();
        try testing.expectEqual(scale_stride, buffers.max_scale_stride);
        try testing.expectEqual(2 * scale_stride, buffers.scale_scratch.len);
        try testing.expectEqual(
            buffers.tensorStorageBytes(),
            buffers.materializedCounterfactualBytes(),
        );
        try testing.expectEqual(@as(usize, 0), buffers.reclaimedPayloadBytes());
    }
}

fn qwenCompactSpec(max_batch: usize, capsule_rows: usize) Spec {
    return .{
        .kind = .compact_pair,
        .max_batch = max_batch,
        .dim = 896,
        .kv_dim = 128,
        .hidden = 4864,
        .max_scale_stride = 56,
        .task_slots = 4,
        .capsule_rows = capsule_rows,
        .tile_rows = 64,
        .pair_scale_stride = 304,
    };
}

test "compact Pair frame has exact aligned disjoint slices" {
    const testing = std.testing;
    const spec = qwenCompactSpec(128, 32);
    var buffers = try Buffers.initWithSpec(testing.allocator, spec);
    defer buffers.deinit();
    try testing.expectEqual(Kind.compact_pair, buffers.kind);
    try testing.expectEqual(@as(usize, 0), buffers.gate.len);
    try testing.expectEqual(@as(usize, 0), buffers.up.len);
    try testing.expectEqual(@as(usize, 0), buffers.silu_gate.len);
    try testing.expectEqual(spec.max_batch * spec.dim, buffers.q_scratch.len);
    try testing.expectEqual(spec.capsule_rows * spec.hidden, buffers.pair_q8.len);
    try testing.expectEqual(
        spec.capsule_rows * spec.pair_scale_stride,
        buffers.pair_scales.len,
    );
    const tile_count = spec.task_slots * spec.capsule_rows * spec.tile_rows;
    try testing.expectEqual(tile_count, buffers.gate_tile.len);
    try testing.expectEqual(tile_count, buffers.up_tile.len);
    inline for (.{
        buffers.pair_q8,
        buffers.pair_scales,
        buffers.gate_tile,
        buffers.up_tile,
    }) |slice| {
        try testing.expectEqual(@as(usize, 0), @intFromPtr(slice.ptr) % 64);
    }

    const slices = [_][]const u8{
        std.mem.sliceAsBytes(buffers.x),
        std.mem.sliceAsBytes(buffers.next),
        std.mem.sliceAsBytes(buffers.h_norm),
        std.mem.sliceAsBytes(buffers.q),
        std.mem.sliceAsBytes(buffers.k),
        std.mem.sliceAsBytes(buffers.v),
        std.mem.sliceAsBytes(buffers.attn_out),
        std.mem.sliceAsBytes(buffers.proj),
        std.mem.sliceAsBytes(buffers.h),
        std.mem.sliceAsBytes(buffers.mlp_norm),
        std.mem.sliceAsBytes(buffers.down),
        std.mem.sliceAsBytes(buffers.q_scratch),
        std.mem.sliceAsBytes(buffers.scale_scratch),
        std.mem.sliceAsBytes(buffers.pair_q8),
        std.mem.sliceAsBytes(buffers.pair_scales),
        std.mem.sliceAsBytes(buffers.gate_tile),
        std.mem.sliceAsBytes(buffers.up_tile),
    };
    for (slices, 0..) |left, left_index| {
        for (slices[left_index + 1 ..]) |right| {
            const left_start = @intFromPtr(left.ptr);
            const left_end = left_start + left.len;
            const right_start = @intFromPtr(right.ptr);
            const right_end = right_start + right.len;
            try testing.expect(left_end <= right_start or right_end <= left_start);
        }
    }
}

test "Qwen PP128 and PP256 W32 and W64 compact ledgers are exact" {
    const testing = std.testing;
    const cases = [_]struct {
        max_batch: usize,
        capsule_rows: usize,
        common_dim: usize,
        common_kv: usize,
        q_scratch: usize,
        scale_scratch: usize,
        pair_q8: usize,
        pair_scale: usize,
        tile: usize,
        active: usize,
        materialized: usize,
        reclaimed: usize,
    }{
        .{
            .max_batch = 128,
            .capsule_rows = 32,
            .common_dim = 4_128_768,
            .common_kv = 131_072,
            .q_scratch = 114_688,
            .scale_scratch = 28_672,
            .pair_q8 = 155_648,
            .pair_scale = 38_912,
            .tile = 32_768,
            .active = 4_663_296,
            .materialized = 12_664_832,
            .reclaimed = 8_001_536,
        },
        .{
            .max_batch = 128,
            .capsule_rows = 64,
            .common_dim = 4_128_768,
            .common_kv = 131_072,
            .q_scratch = 114_688,
            .scale_scratch = 28_672,
            .pair_q8 = 311_296,
            .pair_scale = 77_824,
            .tile = 65_536,
            .active = 4_923_392,
            .materialized = 12_664_832,
            .reclaimed = 7_741_440,
        },
        .{
            .max_batch = 256,
            .capsule_rows = 32,
            .common_dim = 8_257_536,
            .common_kv = 262_144,
            .q_scratch = 229_376,
            .scale_scratch = 57_344,
            .pair_q8 = 155_648,
            .pair_scale = 38_912,
            .tile = 32_768,
            .active = 9_066_496,
            .materialized = 25_329_664,
            .reclaimed = 16_263_168,
        },
        .{
            .max_batch = 256,
            .capsule_rows = 64,
            .common_dim = 8_257_536,
            .common_kv = 262_144,
            .q_scratch = 229_376,
            .scale_scratch = 57_344,
            .pair_q8 = 311_296,
            .pair_scale = 77_824,
            .tile = 65_536,
            .active = 9_326_592,
            .materialized = 25_329_664,
            .reclaimed = 16_003_072,
        },
    };
    for (cases) |expected| {
        const ledger = try qwenCompactSpec(
            expected.max_batch,
            expected.capsule_rows,
        ).logicalLedger();
        try testing.expectEqual(expected.common_dim, ledger.breakdown.common_dim_f32_bytes);
        try testing.expectEqual(expected.common_kv, ledger.breakdown.common_kv_f32_bytes);
        try testing.expectEqual(expected.q_scratch, ledger.breakdown.q_scratch_bytes);
        try testing.expectEqual(expected.scale_scratch, ledger.breakdown.scale_scratch_bytes);
        try testing.expectEqual(expected.pair_q8, ledger.breakdown.pair_q8_bytes);
        try testing.expectEqual(expected.pair_scale, ledger.breakdown.pair_scale_bytes);
        try testing.expectEqual(expected.tile, ledger.breakdown.gate_tile_bytes);
        try testing.expectEqual(expected.tile, ledger.breakdown.up_tile_bytes);
        try testing.expectEqual(expected.active, ledger.tensor_storage_bytes);
        try testing.expectEqual(expected.materialized, ledger.materialized_counterfactual_bytes);
        try testing.expectEqual(expected.reclaimed, ledger.reclaimed_bytes);
    }
}

test "prefill spec rejects malformed compact geometry before allocation" {
    const testing = std.testing;
    const valid = qwenCompactSpec(128, 32);
    var cases: [11]Spec = @splat(valid);
    cases[0].max_batch = 0;
    cases[1].task_slots = 0;
    cases[2].capsule_rows = 0;
    cases[3].capsule_rows = 129;
    cases[4].capsule_rows = 5;
    cases[5].tile_rows = 0;
    cases[6].tile_rows = 96 + 1;
    cases[7].tile_rows = 4896;
    cases[8].pair_scale_stride = 0;
    cases[9].pair_scale_stride = 4865;
    cases[10].max_scale_stride = 4865;
    for (cases) |spec| {
        try testing.expectError(error.InvalidShape, spec.logicalLedger());
    }
    var materialized = Spec{
        .kind = .materialized,
        .max_batch = 8,
        .dim = 16,
        .kv_dim = 4,
        .hidden = 32,
        .max_scale_stride = 4,
        .task_slots = 1,
    };
    try testing.expectError(error.InvalidShape, materialized.logicalLedger());
    materialized.task_slots = 0;
    materialized.max_scale_stride = 3;
    const materialized_ledger = try materialized.logicalLedger();
    try testing.expectEqual(
        materialized_ledger.tensor_storage_bytes,
        materialized_ledger.materialized_counterfactual_bytes,
    );
    try testing.expectEqual(@as(usize, 0), materialized_ledger.reclaimed_bytes);
}

test "compact Pair admits M1-M3 tail capsules and M4 multiples" {
    const testing = std.testing;
    for ([_]usize{ 1, 2, 3, 4, 8 }) |capsule_rows| {
        const ledger = try (Spec{
            .kind = .compact_pair,
            .max_batch = 8,
            .dim = 32,
            .kv_dim = 8,
            .hidden = 64,
            .max_scale_stride = 8,
            .task_slots = 2,
            .capsule_rows = capsule_rows,
            .tile_rows = 32,
            .pair_scale_stride = 4,
        }).logicalLedger();
        try testing.expectEqual(Kind.compact_pair, ledger.kind);
        try testing.expect(ledger.reclaimed_bytes > 0);
    }
}

test "prefill ledger rejects checked arithmetic overflow" {
    const testing = std.testing;
    var materialized = Spec{
        .kind = .materialized,
        .max_batch = std.math.maxInt(usize),
        .dim = 8,
        .kv_dim = 1,
        .hidden = 8,
        .max_scale_stride = 1,
    };
    try testing.expectError(error.Overflow, materialized.logicalLedger());
    materialized.max_batch = 8;
    materialized.dim = std.math.maxInt(usize);
    materialized.hidden = std.math.maxInt(usize);
    materialized.max_scale_stride = ceilDiv8(std.math.maxInt(usize));
    try testing.expectError(error.Overflow, materialized.logicalLedger());

    var compact = qwenCompactSpec(128, 32);
    compact.task_slots = std.math.maxInt(usize);
    try testing.expectError(error.Overflow, compact.logicalLedger());
}

fn prefillAllocationProbe(allocator: std.mem.Allocator, spec: Spec) !void {
    var buffers = try Buffers.initWithSpec(allocator, spec);
    defer buffers.deinit();
    try std.testing.expectEqual(
        buffers.logicalLedger().tensor_storage_bytes,
        buffers.tensorStorageBytes(),
    );
}

test "prefill frames release every partial allocation on failure" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(
        testing.allocator,
        prefillAllocationProbe,
        .{Spec{
            .kind = .materialized,
            .max_batch = 8,
            .dim = 16,
            .kv_dim = 4,
            .hidden = 32,
            .max_scale_stride = 4,
        }},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        prefillAllocationProbe,
        .{qwenCompactSpec(8, 8)},
    );
}
