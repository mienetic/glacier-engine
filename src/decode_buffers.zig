//! Pre-allocated decode buffers — zero-allocation cached decode.
//!
//! Layer execution is synchronous: a layer has finished consuming every
//! temporary before the next layer starts. Keep one request-local activation
//! frame and reuse it across model depth instead of multiplying scratch by the
//! number of layers. `forwardLayerCached` still receives the same typed slices;
//! only their lifetime owner changes.

const std = @import("std");
const tensor = @import("core").tensor;
pub const Tensor = tensor.Tensor;

/// Representation-specific request frame. Separate MLP execution needs three
/// materialized hidden-width f32 vectors. Outputless PairNibble instead owns
/// only the exact Q8 activation consumed by down plus its largest per-layer
/// scale stream. The g16 variant also admits g8 layers in a mixed-group model.
pub const MlpFrameKind = enum {
    materialized,
    compact_pair_g8,
    compact_pair_g16,
};

pub const PairQ8Scratch = struct {
    q_output: []i8,
    activation_scales: []f32,
};

pub const LogicalLedger = struct {
    frame_kind: MlpFrameKind,
    base_tensor_bytes: usize,
    mlp_tensor_bytes: usize,
    tensor_payload_bytes: usize,
    materialized_counterfactual_bytes: usize,
    reclaimed_bytes: usize,
};

/// Allocation-free oracle shared by ResourceBank admission and the concrete
/// arena constructor. Model depth is validated but intentionally absent from
/// every byte formula because the frame is synchronously reused by all layers.
pub fn deriveLogicalLedger(
    num_layers: usize,
    dim: usize,
    kv_dim: usize,
    hidden: usize,
    frame_kind: MlpFrameKind,
) !LogicalLedger {
    if (num_layers == 0 or dim == 0 or kv_dim == 0 or hidden == 0)
        return error.InvalidFrameGeometry;
    const dim_elements = try std.math.mul(usize, dim, 8);
    const kv_elements = try std.math.mul(usize, kv_dim, 2);
    const base_elements = try std.math.add(usize, dim_elements, kv_elements);
    const base_tensor_bytes = try std.math.mul(
        usize,
        base_elements,
        @sizeOf(f32),
    );
    const materialized_elements = try std.math.mul(usize, hidden, 3);
    const materialized_mlp_bytes = try std.math.mul(
        usize,
        materialized_elements,
        @sizeOf(f32),
    );
    const materialized_counterfactual_bytes = try std.math.add(
        usize,
        base_tensor_bytes,
        materialized_mlp_bytes,
    );
    const mlp_tensor_bytes = switch (frame_kind) {
        .materialized => materialized_mlp_bytes,
        .compact_pair_g8, .compact_pair_g16 => blk: {
            const largest_group: u32 = if (frame_kind == .compact_pair_g16)
                16
            else
                8;
            const scale_count = q8ScaleCount(hidden, largest_group) orelse
                return error.InvalidPairGroupSize;
            const scale_bytes = try std.math.mul(
                usize,
                scale_count,
                @sizeOf(f32),
            );
            break :blk try std.math.add(usize, hidden, scale_bytes);
        },
    };
    const tensor_payload_bytes = try std.math.add(
        usize,
        base_tensor_bytes,
        mlp_tensor_bytes,
    );
    return .{
        .frame_kind = frame_kind,
        .base_tensor_bytes = base_tensor_bytes,
        .mlp_tensor_bytes = mlp_tensor_bytes,
        .tensor_payload_bytes = tensor_payload_bytes,
        .materialized_counterfactual_bytes = materialized_counterfactual_bytes,
        .reclaimed_bytes = materialized_counterfactual_bytes -| tensor_payload_bytes,
    };
}

pub const LayerBuffers = struct {
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
    pair_q8: []i8,
    pair_scales: []f32,
    down: []f32,
    next_h: []f32,

    pub fn pairQ8Scratch(
        self: *LayerBuffers,
        hidden: usize,
        group_size: u32,
    ) ?PairQ8Scratch {
        if (self.pair_q8.len != hidden) return null;
        const scale_count = q8ScaleCount(hidden, group_size) orelse return null;
        if (scale_count > self.pair_scales.len) return null;
        return .{
            .q_output = self.pair_q8,
            .activation_scales = self.pair_scales[0..scale_count],
        };
    }
};

pub const DecodeBuffers = struct {
    shared: LayerBuffers,
    layer_count: usize,
    frame_kind: MlpFrameKind,
    ledger: LogicalLedger,
    arena: std.heap.ArenaAllocator,

    pub fn init(
        parent: std.mem.Allocator,
        num_layers: usize,
        dim: usize,
        kv_dim: usize,
        hidden: usize,
    ) !DecodeBuffers {
        return initWithFrame(
            parent,
            num_layers,
            dim,
            kv_dim,
            hidden,
            .materialized,
        );
    }

    pub fn initWithFrame(
        parent: std.mem.Allocator,
        num_layers: usize,
        dim: usize,
        kv_dim: usize,
        hidden: usize,
        frame_kind: MlpFrameKind,
    ) !DecodeBuffers {
        const ledger = try deriveLogicalLedger(
            num_layers,
            dim,
            kv_dim,
            hidden,
            frame_kind,
        );
        var arena = std.heap.ArenaAllocator.init(parent);
        errdefer arena.deinit();
        const a = arena.allocator();

        const empty_f32 = try a.alloc(f32, 0);
        const empty_i8 = try a.alloc(i8, 0);
        var gate = empty_f32;
        var up = empty_f32;
        var silu_gate = empty_f32;
        var pair_q8 = empty_i8;
        var pair_scales = empty_f32;
        switch (frame_kind) {
            .materialized => {
                gate = try a.alloc(f32, hidden);
                up = try a.alloc(f32, hidden);
                // The compatibility graph overlays Q8 bytes and f32 scales on
                // this buffer for prepared down. Keep the original alignment.
                silu_gate = try a.alignedAlloc(f32, .@"64", hidden);
            },
            .compact_pair_g8, .compact_pair_g16 => {
                pair_q8 = try a.alignedAlloc(i8, .@"64", hidden);
                const largest_group: u32 = if (frame_kind == .compact_pair_g16)
                    16
                else
                    8;
                pair_scales = try a.alignedAlloc(
                    f32,
                    .@"64",
                    q8ScaleCount(hidden, largest_group) orelse
                        return error.InvalidPairGroupSize,
                );
            },
        }

        const shared: LayerBuffers = .{
            .h_norm = try a.alloc(f32, dim),
            .q = try a.alloc(f32, dim),
            .k = try a.alloc(f32, kv_dim),
            .v = try a.alloc(f32, kv_dim),
            .attn_out = try a.alloc(f32, dim),
            .proj = try a.alloc(f32, dim),
            .h = try a.alloc(f32, dim),
            .mlp_norm = try a.alloc(f32, dim),
            .gate = gate,
            .up = up,
            .silu_gate = silu_gate,
            .pair_q8 = pair_q8,
            .pair_scales = pair_scales,
            .down = try a.alloc(f32, dim),
            .next_h = try a.alloc(f32, dim),
        };

        return .{
            .shared = shared,
            .layer_count = num_layers,
            .frame_kind = frame_kind,
            .ledger = ledger,
            .arena = arena,
        };
    }

    pub fn deinit(self: *DecodeBuffers) void {
        self.arena.deinit();
    }

    /// Borrow the sole activation frame for a logical layer. Layer graphs are
    /// joined before this method is called for the next index, so the frame is
    /// never shared by concurrently executing layers.
    pub fn forLayer(self: *DecodeBuffers, layer_idx: usize) *LayerBuffers {
        std.debug.assert(layer_idx < self.layer_count);
        return &self.shared;
    }

    /// Bytes occupied by typed tensor payloads in the depth-independent frame.
    /// Allocator bookkeeping and alignment padding are intentionally excluded.
    pub fn tensorStorageBytes(self: *const DecodeBuffers) usize {
        return self.ledger.tensor_payload_bytes;
    }

    /// Exact payload of the former materialized frame for this model geometry.
    /// This counterfactual excludes allocator padding just like
    /// `tensorStorageBytes`, so their difference is a reproducible byte ledger.
    pub fn materializedCounterfactualBytes(self: *const DecodeBuffers) usize {
        return self.ledger.materialized_counterfactual_bytes;
    }

    pub fn reclaimedPayloadBytes(self: *const DecodeBuffers) usize {
        return self.ledger.reclaimed_bytes;
    }

    pub fn logicalLedger(self: *const DecodeBuffers) LogicalLedger {
        return self.ledger;
    }

    /// Borrow the compact producer/consumer bridge at the exact scale extent
    /// required by one down layer. g16-capacity frames may serve g8 layers, but
    /// g8-only frames reject a larger scale stream without exposing a short
    /// slice to the executor.
    pub fn pairQ8Scratch(
        self: *DecodeBuffers,
        hidden: usize,
        group_size: u32,
    ) ?PairQ8Scratch {
        if (self.frame_kind == .materialized or
            self.shared.pair_q8.len != hidden)
            return null;
        return self.shared.pairQ8Scratch(hidden, group_size);
    }

    /// Counterfactual payload size of the previous one-frame-per-layer layout.
    /// This is exposed for tests and resource manifests, not allocation.
    pub fn perLayerTensorStorageBytes(self: *const DecodeBuffers) usize {
        return self.tensorStorageBytes() * self.layer_count;
    }

    /// Static shape storage for [1, cols] tensors. Since cols is comptime-known
    /// per call site (dim, kv_dim, hidden are all fixed per model), we use a
    /// small fixed array per invocation via the caller's stack.
    /// The caller must keep `shape_storage` alive while the Tensor is used.
    pub fn view(buf: []f32, shape_storage: *[2]usize, cols: usize) Tensor {
        if (cols > buf.len) @panic("decode buffer view exceeds allocation");
        shape_storage.* = .{ 1, cols };
        return .{
            .dtype = .f32,
            .shape = shape_storage,
            .data = std.mem.sliceAsBytes(buf[0..cols]),
            .allocator = std.heap.page_allocator,
        };
    }
};

fn q8ScaleCount(hidden: usize, group_size: u32) ?usize {
    if (group_size != 8 and group_size != 16) return null;
    const activation_group: usize = if (group_size == 8) 32 else 16;
    return hidden / activation_group +
        @intFromBool(hidden % activation_group != 0);
}

test "decode activation frame is independent of model depth" {
    const testing = std.testing;
    var one = try DecodeBuffers.init(testing.allocator, 1, 8, 2, 12);
    defer one.deinit();
    var deep = try DecodeBuffers.init(testing.allocator, 24, 8, 2, 12);
    defer deep.deinit();

    // 8 dim slices + 2 KV slices + 3 hidden slices, all f32.
    const expected = (8 * 8 + 2 * 2 + 3 * 12) * @sizeOf(f32);
    try testing.expectEqual(expected, one.tensorStorageBytes());
    try testing.expectEqual(expected, deep.tensorStorageBytes());
    try testing.expectEqual(expected * 24, deep.perLayerTensorStorageBytes());
    try testing.expectEqual(
        @intFromPtr(deep.forLayer(0)),
        @intFromPtr(deep.forLayer(23)),
    );
    try testing.expectEqual(@as(usize, 0), @intFromPtr(deep.shared.silu_gate.ptr) % 64);
}

test "compact Pair frame owns only exact Q8 and largest scale stream" {
    const testing = std.testing;
    const dim: usize = 8;
    const kv_dim: usize = 2;
    const hidden: usize = 64;
    var g8 = try DecodeBuffers.initWithFrame(
        testing.allocator,
        24,
        dim,
        kv_dim,
        hidden,
        .compact_pair_g8,
    );
    defer g8.deinit();
    var g16 = try DecodeBuffers.initWithFrame(
        testing.allocator,
        24,
        dim,
        kv_dim,
        hidden,
        .compact_pair_g16,
    );
    defer g16.deinit();

    const base_bytes = (8 * dim + 2 * kv_dim) * @sizeOf(f32);
    const materialized_bytes = base_bytes + 3 * hidden * @sizeOf(f32);
    try testing.expectEqual(base_bytes + hidden + 2 * @sizeOf(f32), g8.tensorStorageBytes());
    try testing.expectEqual(base_bytes + hidden + 4 * @sizeOf(f32), g16.tensorStorageBytes());
    try testing.expectEqual(materialized_bytes, g8.materializedCounterfactualBytes());
    try testing.expectEqual(materialized_bytes - g8.tensorStorageBytes(), g8.reclaimedPayloadBytes());
    try testing.expectEqual(@as(usize, 0), g8.shared.gate.len);
    try testing.expectEqual(@as(usize, 0), g8.shared.up.len);
    try testing.expectEqual(@as(usize, 0), g8.shared.silu_gate.len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(g8.shared.pair_q8.ptr) % 64);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(g8.shared.pair_scales.ptr) % 64);
    try testing.expectEqual(@as(usize, 2), g8.pairQ8Scratch(hidden, 8).?.activation_scales.len);
    try testing.expect(g8.pairQ8Scratch(hidden, 16) == null);
    try testing.expectEqual(@as(usize, 2), g16.pairQ8Scratch(hidden, 8).?.activation_scales.len);
    try testing.expectEqual(@as(usize, 4), g16.pairQ8Scratch(hidden, 16).?.activation_scales.len);
    try testing.expect(g16.pairQ8Scratch(hidden, 7) == null);
    try testing.expectEqual(
        @intFromPtr(g16.forLayer(0)),
        @intFromPtr(g16.forLayer(23)),
    );
}

test "Qwen 0.5B compact Pair frame byte ledger is exact" {
    const testing = std.testing;
    var g8 = try DecodeBuffers.initWithFrame(
        testing.allocator,
        24,
        896,
        128,
        4864,
        .compact_pair_g8,
    );
    defer g8.deinit();
    var g16 = try DecodeBuffers.initWithFrame(
        testing.allocator,
        24,
        896,
        128,
        4864,
        .compact_pair_g16,
    );
    defer g16.deinit();

    try testing.expectEqual(@as(usize, 35_168), g8.tensorStorageBytes());
    try testing.expectEqual(@as(usize, 35_776), g16.tensorStorageBytes());
    try testing.expectEqual(@as(usize, 88_064), g8.materializedCounterfactualBytes());
    try testing.expectEqual(@as(usize, 52_896), g8.reclaimedPayloadBytes());
    try testing.expectEqual(@as(usize, 52_288), g16.reclaimedPayloadBytes());
}

test "compact Pair scale capacity rounds hidden tails upward" {
    const testing = std.testing;
    const int4_matmul = @import("backends/cpu/int4_matmul.zig");
    const hidden: usize = 528;
    var g8 = try DecodeBuffers.initWithFrame(
        testing.allocator,
        1,
        128,
        32,
        hidden,
        .compact_pair_g8,
    );
    defer g8.deinit();
    var g16 = try DecodeBuffers.initWithFrame(
        testing.allocator,
        1,
        128,
        32,
        hidden,
        .compact_pair_g16,
    );
    defer g16.deinit();

    try testing.expectEqual(@as(usize, 17), g8.shared.pair_scales.len);
    try testing.expectEqual(@as(usize, 33), g16.shared.pair_scales.len);
    try testing.expectEqual(
        int4_matmul.q8ActivationScaleCount(hidden, 8),
        g8.shared.pair_scales.len,
    );
    try testing.expectEqual(
        int4_matmul.q8ActivationScaleCount(hidden, 16),
        g16.shared.pair_scales.len,
    );
    try testing.expectEqual(@as(usize, 17), g16.pairQ8Scratch(hidden, 8).?.activation_scales.len);
    try testing.expectEqual(@as(usize, 33), g16.pairQ8Scratch(hidden, 16).?.activation_scales.len);
    const q_bytes = std.mem.sliceAsBytes(g16.shared.pair_q8);
    const scale_bytes = std.mem.sliceAsBytes(g16.shared.pair_scales);
    const q_start = @intFromPtr(q_bytes.ptr);
    const q_end = q_start + q_bytes.len;
    const scale_start = @intFromPtr(scale_bytes.ptr);
    const scale_end = scale_start + scale_bytes.len;
    try testing.expect(q_end <= scale_start or scale_end <= q_start);
}

test "decode ledger is allocation-free exact and rejects overflow" {
    const ledger = try deriveLogicalLedger(
        24,
        896,
        128,
        4864,
        .compact_pair_g16,
    );
    try std.testing.expectEqual(@as(usize, 29_696), ledger.base_tensor_bytes);
    try std.testing.expectEqual(@as(usize, 6_080), ledger.mlp_tensor_bytes);
    try std.testing.expectEqual(@as(usize, 35_776), ledger.tensor_payload_bytes);
    try std.testing.expectEqual(@as(usize, 88_064), ledger.materialized_counterfactual_bytes);
    try std.testing.expectEqual(@as(usize, 52_288), ledger.reclaimed_bytes);
    try std.testing.expectError(
        error.InvalidFrameGeometry,
        deriveLogicalLedger(0, 896, 128, 4864, .materialized),
    );
    try std.testing.expectError(
        error.Overflow,
        deriveLogicalLedger(
            1,
            std.math.maxInt(usize),
            1,
            1,
            .materialized,
        ),
    );
}

fn decodeFrameAllocationProbe(
    allocator: std.mem.Allocator,
    frame_kind: MlpFrameKind,
) !void {
    var buffers = try DecodeBuffers.initWithFrame(
        allocator,
        24,
        128,
        32,
        528,
        frame_kind,
    );
    defer buffers.deinit();
}

test "decode frame releases every partial allocation on failure" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(
        testing.allocator,
        decodeFrameAllocationProbe,
        .{MlpFrameKind.materialized},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        decodeFrameAllocationProbe,
        .{MlpFrameKind.compact_pair_g8},
    );
    try testing.checkAllAllocationFailures(
        testing.allocator,
        decodeFrameAllocationProbe,
        .{MlpFrameKind.compact_pair_g16},
    );
}
