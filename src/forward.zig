//! Single transformer layer forward pass (Llama-style) on CPU.
//!
//! Implements the standard pre-norm Llama block:
//!
//!   h = x + Attn(RMSNorm(x, w_norm))
//!   y = h + MLP(RMSNorm(h, w_norm2))
//!
//! where Attn is single-head for the MVP (multi-head comes when the
//! attention kernel lands) and MLP is:
//!
//!   gate = SiLU(W_gate · h)
//!   up   = W_up · h
//!   down = W_down · (gate * up)
//!
//! Weights are supplied as raw page payloads (qio-encoded) so this path
//! exercises the INT4 dequant kernel end-to-end — exactly what the Metal
//! backend will replace with a single fused kernel later.
//!
//! MVP simplifications (documented so contributors know what's missing):
//!   - single attention head (n_heads = 1)
//!   - no KV cache (recomputed every step)
//!   - no rotary embeddings (RoPE) — adds rotational structure to Q/K
//!   - causal mask is applied
//!   - FP32 throughout

const std = @import("std");
const core = @import("core");
const tensor = core.tensor;
const kernels = @import("backends/cpu/kernels.zig");
const qio = @import("model/qio.zig");
const int4_executor = @import("int4_executor.zig");

pub const Tensor = tensor.Tensor;
pub const TensorError = tensor.TensorError;

pub const LayerWeights = struct {
    /// RMSNorm weight before attention, shape [dim].
    input_norm: []const f32,
    /// q/k/v/o projection weights, decoded to f32, row-major [out, in].
    wq: []const f32,
    wk: []const f32,
    wv: []const f32,
    wo: []const f32,
    /// f16 copies of projection weights (for f16 matmul path).
    /// Allocated once by the loader; empty = use f32 path.
    wq_f16: []const f16 = &.{},
    wk_f16: []const f16 = &.{},
    wv_f16: []const f16 = &.{},
    wo_f16: []const f16 = &.{},
    /// Optional biases.
    bq: []const f32,
    bk: []const f32,
    bv: []const f32,
    bo: []const f32,
    /// RMSNorm weight before MLP, shape [dim].
    post_attn_norm: []const f32,
    /// MLP gate/up/down weights, decoded to f32, [out, in] row-major.
    w_gate: []const f32,
    w_up: []const f32,
    w_down: []const f32,
    /// f16 copies of MLP weights.
    w_gate_f16: []const f16 = &.{},
    w_up_f16: []const f16 = &.{},
    w_down_f16: []const f16 = &.{},
    /// INT4 packed weight data for on-the-fly matmul.
    /// When present, decode path uses linearInt4OnTheFly (8x less traffic).
    wq_int4: ?@import("int4_weights.zig").Int4WeightData = null,
    wk_int4: ?@import("int4_weights.zig").Int4WeightData = null,
    wv_int4: ?@import("int4_weights.zig").Int4WeightData = null,
    wo_int4: ?@import("int4_weights.zig").Int4WeightData = null,
    w_gate_int4: ?@import("int4_weights.zig").Int4WeightData = null,
    w_up_int4: ?@import("int4_weights.zig").Int4WeightData = null,
    /// Lossless paired gate/up stream used by the dedicated dual-projection
    /// executor. This is intentionally not an Int4WeightData: passing paired
    /// bytes to either legacy single-projection kernel would reinterpret the
    /// other branch as coefficient bits.
    w_gate_up_pair_int4: ?@import("int4_weights.zig").PairNibbleWeightData = null,
    w_down_int4: ?@import("int4_weights.zig").Int4WeightData = null,
};

pub const LayerConfig = struct {
    dim: usize,
    /// Hidden dimension of the MLP (typically 4 × dim).
    hidden_dim: usize,
    /// RMSNorm epsilon.
    rms_eps: f32 = 1e-6,
    /// Sequence length currently being processed.
    seq_len: usize,
    /// Number of attention heads.
    num_heads: usize = 1,
    /// Per-head dimension = dim / num_heads.
    head_dim: usize = 0,
    /// RoPE base frequency.
    rope_theta: f32 = 10000.0,
    /// Number of key/value heads. Equal to num_heads for MHA, smaller for
    /// GQA. When smaller, each kv head is shared by num_heads/num_kv_heads
    /// query heads.
    num_kv_heads: usize = 0,
};

/// Wrap a flat f32 weight matrix as a 2D Tensor view for linearF32.
/// The returned Tensor borrows `weights` and uses `shape_storage` for its
/// shape slice — both must outlive the returned Tensor. The caller must
/// NOT call .deinit() on the result.
pub fn weightView(weights: []const f32, shape_storage: *[2]usize, out_features: usize, in_features: usize) Tensor {
    shape_storage.* = .{ out_features, in_features };
    // We only read from this view; cast away const to satisfy the Tensor
    // type. linearF32 never mutates its weight argument.
    const bytes: []u8 = @constCast(std.mem.sliceAsBytes(weights));
    return .{
        .dtype = .f32,
        .shape = shape_storage,
        .data = bytes,
        .allocator = std.heap.page_allocator, // unused; we never deinit views
    };
}

/// x · W^T + b, where W is a flat f32 row-major [out, in] matrix.
/// Dispatches to f16 matmul when f16 weights are available.
pub fn linearF32Weights(
    x: Tensor,
    w: []const f32,
    bias: []const f32,
    out_features: usize,
    in_features: usize,
    out: Tensor,
) TensorError!void {
    var shape_storage: [2]usize = undefined;
    const w_tensor = weightView(w, &shape_storage, out_features, in_features);
    try kernels.linearF32(x, w_tensor, bias, out);
}

/// f16-weight linear: same interface but takes f16 weights for halved
/// memory traffic. Uses dotproduct.linearF16Weight internally.
pub fn linearF16Weights(
    x: Tensor,
    w_f16: []const f16,
    bias: []const f32,
    out: Tensor,
) TensorError!void {
    const dp = @import("backends/cpu/dotproduct.zig");
    try dp.linearF16Weight(x, w_f16, bias, out);
}

/// Run one transformer layer over the input activations.
/// `x` shape: [seq_len, dim]. Returns new tensor of same shape (caller owns).
pub fn forwardLayer(
    allocator: std.mem.Allocator,
    cfg: LayerConfig,
    weights: LayerWeights,
    x: Tensor, // [seq_len, dim]
) !Tensor {
    if (x.shape.len != 2 or x.shape[1] != cfg.dim) return TensorError.ShapeMismatch;
    const seq = cfg.seq_len;
    const dim = cfg.dim;
    const hidden = cfg.hidden_dim;

    // --- Attention block --------------------------------------------------
    var h_norm = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer h_norm.deinit();
    try kernels.rmsNormF32(x, weights.input_norm, cfg.rms_eps, h_norm);

    const kv_dim = cfg.num_kv_heads * cfg.head_dim;
    var q = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer q.deinit();
    var k = try tensor.zerosF32(allocator, &.{ seq, kv_dim });
    defer k.deinit();
    var v = try tensor.zerosF32(allocator, &.{ seq, kv_dim });
    defer v.deinit();

    // Parallel Q/K/V projections across threads.
    // On Apple Silicon with 8+ cores, this overlaps ~3ms of compute.
    var kv_thread: ?std.Thread = null;

    // Q projection on main thread, K/V on worker threads.
    const KVArgs = struct {
        h_norm: Tensor,
        wk: []const f32,
        wk_f16: []const f16,
        bk: []const f32,
        wv: []const f32,
        wv_f16: []const f16,
        bv: []const f32,
        kv_dim: usize,
        dim: usize,
        k_out: *Tensor,
        v_out: *Tensor,
        err: *?anyerror,
    };
    var kv_err: ?anyerror = null;
    var kv_args = KVArgs{
        .h_norm = h_norm,
        .wk = weights.wk,
        .wk_f16 = weights.wk_f16,
        .bk = weights.bk,
        .wv = weights.wv,
        .wv_f16 = weights.wv_f16,
        .bv = weights.bv,
        .kv_dim = kv_dim,
        .dim = dim,
        .k_out = &k,
        .v_out = &v,
        .err = &kv_err,
    };

    const kvWorker = struct {
        fn run(args: *KVArgs) void {
            const a = args.*;
            if (a.wk_f16.len > 0) {
                linearF16Weights(a.h_norm, a.wk_f16, a.bk, a.k_out.*) catch |e| {
                    args.err.* = e;
                    return;
                };
            } else {
                linearF32Weights(a.h_norm, a.wk, a.bk, a.kv_dim, a.dim, a.k_out.*) catch |e| {
                    args.err.* = e;
                    return;
                };
            }
            if (a.wv_f16.len > 0) {
                linearF16Weights(a.h_norm, a.wv_f16, a.bv, a.v_out.*) catch |e| {
                    args.err.* = e;
                    return;
                };
            } else {
                linearF32Weights(a.h_norm, a.wv, a.bv, a.kv_dim, a.dim, a.v_out.*) catch |e| {
                    args.err.* = e;
                    return;
                };
            }
        }
    };

    kv_thread = std.Thread.spawn(.{}, kvWorker.run, .{&kv_args}) catch null;
    // Q on main thread — use f16 path when available.
    if (weights.wq_f16.len > 0) {
        try linearF16Weights(h_norm, weights.wq_f16, weights.bq, q);
    } else {
        try linearF32Weights(h_norm, weights.wq, weights.bq, dim, dim, q);
    }
    if (kv_thread) |t| t.join();
    if (kv_err) |e| return e;

    var attn_out = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer attn_out.deinit();
    // Apply RoPE to Q and K before attention (positions 0..seq-1).
    applyRopeInPlace(q.asF32(), seq, cfg.num_heads, cfg.head_dim, cfg.rope_theta);
    applyRopeInPlace(k.asF32(), seq, cfg.num_kv_heads, cfg.head_dim, cfg.rope_theta);
    try attentionMultiHead(q, k, v, attn_out, cfg.num_heads, cfg.head_dim, cfg.rope_theta, cfg.num_kv_heads);

    // Output projection. Residual add into a copy of x.
    var proj = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer proj.deinit();
    if (weights.wo_f16.len > 0) {
        try linearF16Weights(attn_out, weights.wo_f16, weights.bo, proj);
    } else {
        try linearF32Weights(attn_out, weights.wo, weights.bo, dim, dim, proj);
    }

    var h = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer h.deinit();
    addInto(h.asF32(), x.asF32(), proj.asF32());

    // --- MLP block --------------------------------------------------------
    var mlp_norm = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer mlp_norm.deinit();
    try kernels.rmsNormF32(h, weights.post_attn_norm, cfg.rms_eps, mlp_norm);

    // Parallel gate + up projections (two largest matmuls in the layer).
    var gate = try tensor.zerosF32(allocator, &.{ seq, hidden });
    defer gate.deinit();
    var up = try tensor.zerosF32(allocator, &.{ seq, hidden });
    defer up.deinit();

    var up_err: ?anyerror = null;
    const UpArgs = struct {
        mlp_norm: Tensor,
        w_up: []const f32,
        w_up_f16: []const f16,
        hidden: usize,
        dim: usize,
        up_out: *Tensor,
        err: *?anyerror,
    };
    var up_args = UpArgs{
        .mlp_norm = mlp_norm,
        .w_up = weights.w_up,
        .w_up_f16 = weights.w_up_f16,
        .hidden = hidden,
        .dim = dim,
        .up_out = &up,
        .err = &up_err,
    };
    const upWorker = struct {
        fn run(args: *UpArgs) void {
            const a = args.*;
            if (a.w_up_f16.len > 0) {
                linearF16Weights(a.mlp_norm, a.w_up_f16, &.{}, a.up_out.*) catch |e| {
                    args.err.* = e;
                };
            } else {
                linearF32Weights(a.mlp_norm, a.w_up, &.{}, a.hidden, a.dim, a.up_out.*) catch |e| {
                    args.err.* = e;
                };
            }
        }
    };
    const up_thread = std.Thread.spawn(.{}, upWorker.run, .{&up_args}) catch null;
    // Gate on main thread.
    if (weights.w_gate_f16.len > 0) {
        try linearF16Weights(mlp_norm, weights.w_gate_f16, &.{}, gate);
    } else {
        try linearF32Weights(mlp_norm, weights.w_gate, &.{}, hidden, dim, gate);
    }
    if (up_thread) |t| t.join();
    if (up_err) |e| return e;

    // Fused: silu(gate) * up → single pass, no temp tensor.
    var silu_gate = try tensor.zerosF32(allocator, &.{ seq, hidden });
    defer silu_gate.deinit();
    try kernels.siluMulF32(gate, up, silu_gate);

    var down = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer down.deinit();
    if (weights.w_down_f16.len > 0) {
        try linearF16Weights(silu_gate, weights.w_down_f16, &.{}, down);
    } else {
        try linearF32Weights(silu_gate, weights.w_down, &.{}, dim, hidden, down);
    }

    // y = h + down
    var y = try tensor.zerosF32(allocator, &.{ seq, dim });
    addInto(y.asF32(), h.asF32(), down.asF32());
    return y;
}

/// Apply rotary position embeddings (RoPE) to Q or K in place.
///
/// Standard Llama-style RoPE: for each position i and each consecutive pair
/// of channels (2k, 2k+1) within a head, rotate by angle
///   θ_i = i / rope_theta^(2k / head_dim).
///
/// Layout assumption: q is [seq, num_heads * head_dim] row-major, and
/// pairs are (head_dim*2k, head_dim*2k+1) within each head. We process
/// all heads at each position independently.
pub fn applyRopeInPlace(q: []f32, seq: usize, num_heads: usize, head_dim: usize, rope_theta: f32) void {
    _ = applyRopeInPlaceOffset(q, seq, num_heads, head_dim, rope_theta, 0);
}

/// Same as applyRopeInPlace but starts at absolute position `pos_offset`.
/// Used by the cached decode path where Q is a single row at position N
/// (not 0).
pub fn applyRopeInPlaceOffset(q: []f32, seq: usize, num_heads: usize, head_dim: usize, rope_theta: f32, pos_offset: usize) void {
    const dim = num_heads * head_dim;
    var idx: usize = 0;
    while (idx < seq) : (idx += 1) {
        const pos = pos_offset + idx;
        const row = q[idx * dim .. (idx + 1) * dim];
        var h: usize = 0;
        while (h < num_heads) : (h += 1) {
            const head_off = h * head_dim;
            var k_pair: usize = 0;
            while (k_pair < head_dim / 2) : (k_pair += 1) {
                const freq = 1.0 / std.math.pow(f32, rope_theta, @as(f32, @floatFromInt(2 * k_pair)) / @as(f32, @floatFromInt(head_dim)));
                const angle = @as(f32, @floatFromInt(pos)) * freq;
                const cos_a = std.math.cos(angle);
                const sin_a = std.math.sin(angle);
                const idx0 = head_off + k_pair;
                const idx1 = head_off + k_pair + head_dim / 2;
                const x0 = row[idx0];
                const x1 = row[idx1];
                row[idx0] = x0 * cos_a - x1 * sin_a;
                row[idx1] = x0 * sin_a + x1 * cos_a;
            }
        }
    }
}

/// Multi-head causal attention with RoPE applied to Q and K.
///
/// q, k, v: [seq, num_heads * head_dim] row-major.
/// out:     [seq, num_heads * head_dim] row-major.
///
/// Standard scaled-dot-product attention per head, causal mask, softmax,
/// then weighted sum of V. Callers apply RoPE to Q and K before entering.
pub const max_attention_context: usize = 4096;

const AttentionContext = struct {
    q: []const f32,
    k: []const f32,
    v: []const f32,
    out: []f32,
    q_seq: usize,
    q_dim: usize,
    kv_seq: usize,
    kv_dim: usize,
    num_heads: usize,
    head_dim: usize,
    group_size: usize,
    query_start: usize,
    scale: f32,
};

fn validateAttention(
    q: Tensor,
    k: Tensor,
    v: Tensor,
    out: Tensor,
    num_heads: usize,
    head_dim: usize,
    num_kv_heads: usize,
) TensorError!AttentionContext {
    if (q.dtype != .f32 or k.dtype != .f32 or v.dtype != .f32 or out.dtype != .f32)
        return TensorError.DTypeUnsupported;
    if (q.shape.len != 2 or k.shape.len != 2 or v.shape.len != 2 or out.shape.len != 2 or
        num_heads == 0 or head_dim == 0)
        return TensorError.ShapeMismatch;

    const effective_kv = if (num_kv_heads == 0) num_heads else num_kv_heads;
    if (effective_kv == 0 or effective_kv > num_heads or num_heads % effective_kv != 0)
        return TensorError.ShapeMismatch;
    const q_dim = std.math.mul(usize, num_heads, head_dim) catch
        return TensorError.ShapeMismatch;
    const kv_dim = std.math.mul(usize, effective_kv, head_dim) catch
        return TensorError.ShapeMismatch;
    const q_seq = q.shape[0];
    const kv_seq = k.shape[0];
    if (q_seq == 0 or q_seq > kv_seq or kv_seq > max_attention_context or
        q.shape[1] != q_dim or k.shape[1] != kv_dim or
        v.shape[0] != kv_seq or v.shape[1] != kv_dim or
        out.shape[0] != q_seq or out.shape[1] != q_dim)
        return TensorError.ShapeMismatch;

    const q_count = std.math.mul(usize, q_seq, q_dim) catch
        return TensorError.ShapeMismatch;
    const kv_count = std.math.mul(usize, kv_seq, kv_dim) catch
        return TensorError.ShapeMismatch;
    const q_bytes = std.math.mul(usize, q_count, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    const kv_bytes = std.math.mul(usize, kv_count, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    if (q.data.len < q_bytes or k.data.len < kv_bytes or v.data.len < kv_bytes or
        out.data.len < q_bytes or @intFromPtr(q.data.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(k.data.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(v.data.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(out.data.ptr) % @alignOf(f32) != 0)
        return TensorError.ShapeMismatch;

    return .{
        .q = q.asF32Unsafe(),
        .k = k.asF32Unsafe(),
        .v = v.asF32Unsafe(),
        .out = out.asF32Unsafe(),
        .q_seq = q_seq,
        .q_dim = q_dim,
        .kv_seq = kv_seq,
        .kv_dim = kv_dim,
        .num_heads = num_heads,
        .head_dim = head_dim,
        .group_size = num_heads / effective_kv,
        .query_start = kv_seq - q_seq,
        .scale = 1.0 / std.math.sqrt(@as(f32, @floatFromInt(head_dim))),
    };
}

fn byteRangesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

/// Compute a validated, disjoint half-open range of query heads. Each head
/// retains the serial j/d traversal, softmax, and FP32 accumulation order, so
/// splitting ranges across workers does not change any output bit.
inline fn attentionHeadRange(context: *const AttentionContext, head_start: usize, head_end: usize) TensorError!void {
    if (head_start >= head_end or head_end > context.num_heads)
        return TensorError.ShapeMismatch;

    var h = head_start;
    while (h < head_end) : (h += 1) {
        const q_head_off = h * context.head_dim;
        const kv_head_off = (h / context.group_size) * context.head_dim;

        var i: usize = 0;
        while (i < context.q_seq) : (i += 1) {
            const q_head = context.q[i * context.q_dim + q_head_off ..][0..context.head_dim];
            const attend_up_to = @min(context.query_start + i, context.kv_seq - 1);

            var scores: [max_attention_context]f32 = undefined;
            var max_score: f32 = -std.math.inf(f32);
            const Vec8 = @Vector(8, f32);
            var j: usize = 0;
            while (j <= attend_up_to) : (j += 1) {
                const k_head = context.k[j * context.kv_dim + kv_head_off ..][0..context.head_dim];
                var dot_vec: Vec8 = @splat(0);
                var d: usize = 0;
                const vec_end = context.head_dim - (context.head_dim % 8);
                while (d < vec_end) : (d += 8) {
                    const qv8: Vec8 = .{ q_head[d], q_head[d + 1], q_head[d + 2], q_head[d + 3], q_head[d + 4], q_head[d + 5], q_head[d + 6], q_head[d + 7] };
                    const kv8: Vec8 = .{ k_head[d], k_head[d + 1], k_head[d + 2], k_head[d + 3], k_head[d + 4], k_head[d + 5], k_head[d + 6], k_head[d + 7] };
                    dot_vec += qv8 * kv8;
                }
                var dot: f32 = @reduce(.Add, dot_vec);
                while (d < context.head_dim) : (d += 1) dot += q_head[d] * k_head[d];
                scores[j] = dot * context.scale;
                if (scores[j] > max_score) max_score = scores[j];
            }

            var sum_exp: f32 = 0;
            j = 0;
            while (j <= attend_up_to) : (j += 1) {
                scores[j] = std.math.exp(scores[j] - max_score);
                sum_exp += scores[j];
            }
            const inv = 1.0 / sum_exp;

            var d: usize = 0;
            while (d < context.head_dim) : (d += 1)
                context.out[i * context.q_dim + q_head_off + d] = 0;
            j = 0;
            while (j <= attend_up_to) : (j += 1) {
                const weight = scores[j] * inv;
                const v_head = context.v[j * context.kv_dim + kv_head_off ..][0..context.head_dim];
                d = 0;
                while (d < context.head_dim) : (d += 1)
                    context.out[i * context.q_dim + q_head_off + d] += weight * v_head[d];
            }
        }
    }
}

/// Maximum number of query heads fused around one shared GQA K/V stream.
/// Four keeps each task's score scratch at 64 KiB at the 4096-token boundary,
/// while still exposing enough independent tiles to occupy Apple CPU cores.
pub const max_shared_kv_tile_width: usize = 4;

/// Compute a tile of query heads which all consume the same GQA K/V head.
/// K vectors and V scalars are loaded once per tile instead of once per query
/// head. The operations contributing to any individual output retain the
/// serial d/j order, so this kernel is byte-identical to attentionHeadRange.
fn attentionSharedKvTileExact(
    comptime head_count: usize,
    context: *const AttentionContext,
    kv_head: usize,
    local_head_start: usize,
) TensorError!void {
    comptime std.debug.assert(head_count >= 2 and head_count <= max_shared_kv_tile_width);
    if (context.group_size <= 1 or kv_head >= context.num_heads / context.group_size or
        local_head_start + head_count > context.group_size)
        return TensorError.ShapeMismatch;

    const first_head = kv_head * context.group_size + local_head_start;
    const kv_head_off = kv_head * context.head_dim;
    const Vec8 = @Vector(8, f32);

    var i: usize = 0;
    while (i < context.q_seq) : (i += 1) {
        const attend_up_to = @min(context.query_start + i, context.kv_seq - 1);
        var q_heads: [head_count][]const f32 = undefined;
        var out_heads: [head_count][]f32 = undefined;
        inline for (0..head_count) |lane| {
            const q_head_off = (first_head + lane) * context.head_dim;
            q_heads[lane] = context.q[i * context.q_dim + q_head_off ..][0..context.head_dim];
            out_heads[lane] = context.out[i * context.q_dim + q_head_off ..][0..context.head_dim];
        }

        var scores: [head_count][max_attention_context]f32 = undefined;
        var max_scores = [_]f32{-std.math.inf(f32)} ** head_count;
        var j: usize = 0;
        while (j <= attend_up_to) : (j += 1) {
            const k_head = context.k[j * context.kv_dim + kv_head_off ..][0..context.head_dim];
            var dot_vecs = [_]Vec8{@as(Vec8, @splat(0))} ** head_count;
            var d: usize = 0;
            const vec_end = context.head_dim - (context.head_dim % 8);
            while (d < vec_end) : (d += 8) {
                const kv8: Vec8 = .{ k_head[d], k_head[d + 1], k_head[d + 2], k_head[d + 3], k_head[d + 4], k_head[d + 5], k_head[d + 6], k_head[d + 7] };
                inline for (0..head_count) |lane| {
                    const q_head = q_heads[lane];
                    const qv8: Vec8 = .{ q_head[d], q_head[d + 1], q_head[d + 2], q_head[d + 3], q_head[d + 4], q_head[d + 5], q_head[d + 6], q_head[d + 7] };
                    dot_vecs[lane] += qv8 * kv8;
                }
            }
            inline for (0..head_count) |lane| {
                const q_head = q_heads[lane];
                var dot: f32 = @reduce(.Add, dot_vecs[lane]);
                var tail = d;
                while (tail < context.head_dim) : (tail += 1)
                    dot += q_head[tail] * k_head[tail];
                scores[lane][j] = dot * context.scale;
                if (scores[lane][j] > max_scores[lane])
                    max_scores[lane] = scores[lane][j];
            }
        }

        var inverse_sums: [head_count]f32 = undefined;
        inline for (0..head_count) |lane| {
            var sum_exp: f32 = 0;
            j = 0;
            while (j <= attend_up_to) : (j += 1) {
                scores[lane][j] = std.math.exp(scores[lane][j] - max_scores[lane]);
                sum_exp += scores[lane][j];
            }
            inverse_sums[lane] = 1.0 / sum_exp;
            @memset(out_heads[lane], 0);
        }

        j = 0;
        while (j <= attend_up_to) : (j += 1) {
            const v_head = context.v[j * context.kv_dim + kv_head_off ..][0..context.head_dim];
            var d: usize = 0;
            while (d < context.head_dim) : (d += 1) {
                const value = v_head[d];
                inline for (0..head_count) |lane|
                    out_heads[lane][d] += (scores[lane][j] * inverse_sums[lane]) * value;
            }
        }
    }
}

fn ceilDivNonZero(value: usize, divisor: usize) usize {
    std.debug.assert(value > 0 and divisor > 0);
    return value / divisor + @intFromBool(value % divisor != 0);
}

/// Serial attention restricted to a query-head range. This is public for
/// backend conformance tests and specialized schedulers; malformed or empty
/// ranges fail before any output is touched.
pub fn attentionMultiHeadRange(
    q: Tensor,
    k: Tensor,
    v: Tensor,
    out: Tensor,
    num_heads: usize,
    head_dim: usize,
    rope_theta: f32,
    num_kv_heads: usize,
    head_start: usize,
    head_end: usize,
) TensorError!void {
    _ = rope_theta;
    const context = try validateAttention(q, k, v, out, num_heads, head_dim, num_kv_heads);
    return attentionHeadRange(&context, head_start, head_end);
}

pub fn attentionMultiHead(
    q: Tensor,
    k: Tensor,
    v: Tensor,
    out: Tensor,
    num_heads: usize,
    head_dim: usize,
    rope_theta: f32,
    num_kv_heads: usize,
) TensorError!void {
    _ = rope_theta;
    const context = try validateAttention(q, k, v, out, num_heads, head_dim, num_kv_heads);
    return attentionHeadRange(&context, 0, num_heads);
}

pub const AttentionPartition = enum {
    /// Balance query heads evenly. This preserves the original experimental
    /// schedule and is useful when K/V heads are not shared.
    balanced_heads,
    /// Keep every query-head group that shares one GQA K/V head on the same
    /// task. This avoids duplicate K/V streaming across workers.
    gqa_affine,
};

pub const ParallelAttentionPlan = struct {
    attention: AttentionContext,
    task_count: usize,
    unit_count: usize,
    heads_per_unit: usize,

    pub fn init(
        q: Tensor,
        k: Tensor,
        v: Tensor,
        out: Tensor,
        num_heads: usize,
        head_dim: usize,
        num_kv_heads: usize,
        participants: usize,
        partition: AttentionPartition,
    ) TensorError!ParallelAttentionPlan {
        if (participants == 0) return TensorError.ShapeMismatch;
        const attention = try validateAttention(q, k, v, out, num_heads, head_dim, num_kv_heads);
        // Workers write disjoint output heads, but GQA workers may concurrently
        // read the same K/V head. Reject every input/output overlap rather than
        // turning a malformed view into a data race or schedule-dependent result.
        if (byteRangesOverlap(out.data, q.data) or
            byteRangesOverlap(out.data, k.data) or
            byteRangesOverlap(out.data, v.data))
            return TensorError.ShapeMismatch;

        const unit_count = switch (partition) {
            .balanced_heads => attention.num_heads,
            .gqa_affine => attention.num_heads / attention.group_size,
        };
        const heads_per_unit = switch (partition) {
            .balanced_heads => 1,
            .gqa_affine => attention.group_size,
        };
        return .{
            .attention = attention,
            .task_count = @min(unit_count, participants),
            .unit_count = unit_count,
            .heads_per_unit = heads_per_unit,
        };
    }

    pub fn run(raw_context: *anyopaque, task_index: usize) TensorError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        if (task_index >= self.task_count) return TensorError.ShapeMismatch;
        const units_per_task = self.unit_count / self.task_count;
        const extra_units = self.unit_count % self.task_count;
        const unit_start = task_index * units_per_task + @min(task_index, extra_units);
        const unit_end = unit_start + units_per_task + @intFromBool(task_index < extra_units);
        const head_start = unit_start * self.heads_per_unit;
        const head_end = unit_end * self.heads_per_unit;
        return attentionHeadRange(&self.attention, head_start, head_end);
    }
};

/// Adaptive grouped-query attention plan. It creates enough K/V-affine tiles
/// to occupy the available participants, but caps each tile at four query
/// heads so scratch and register pressure remain bounded. MHA falls back to
/// the original disjoint head-range kernel without entering the fused path.
pub const SharedKvAttentionPlan = struct {
    attention: AttentionContext,
    task_count: usize,
    tile_count: usize,
    tiles_per_kv: usize,
    binding_key: u64,

    pub fn init(
        q: Tensor,
        k: Tensor,
        v: Tensor,
        out: Tensor,
        num_heads: usize,
        head_dim: usize,
        num_kv_heads: usize,
        participants: usize,
    ) TensorError!SharedKvAttentionPlan {
        if (participants == 0) return TensorError.ShapeMismatch;
        const attention = try validateAttention(q, k, v, out, num_heads, head_dim, num_kv_heads);
        if (byteRangesOverlap(out.data, q.data) or
            byteRangesOverlap(out.data, k.data) or
            byteRangesOverlap(out.data, v.data))
            return TensorError.ShapeMismatch;

        const kv_head_count = attention.num_heads / attention.group_size;
        const minimum_tiles = ceilDivNonZero(
            attention.group_size,
            max_shared_kv_tile_width,
        );
        const occupancy_tiles = ceilDivNonZero(participants, kv_head_count);
        const tiles_per_kv = @min(
            attention.group_size,
            @max(minimum_tiles, occupancy_tiles),
        );
        const tile_count = kv_head_count * tiles_per_kv;
        return .{
            .attention = attention,
            .task_count = @min(tile_count, participants),
            .tile_count = tile_count,
            .tiles_per_kv = tiles_per_kv,
            .binding_key = attentionBindingKey(
                attention,
                @min(tile_count, participants),
                tile_count,
                tiles_per_kv,
            ),
        };
    }

    pub fn run(raw_context: *anyopaque, task_index: usize) TensorError!void {
        const self: *@This() = @ptrCast(@alignCast(raw_context));
        if (task_index >= self.task_count) return TensorError.ShapeMismatch;
        const tiles_per_task = self.tile_count / self.task_count;
        const extra_tiles = self.tile_count % self.task_count;
        const tile_start = task_index * tiles_per_task + @min(task_index, extra_tiles);
        const tile_end = tile_start + tiles_per_task + @intFromBool(task_index < extra_tiles);

        // One K/V head per query head means there is nothing to share. Since
        // tile indexes equal head indexes here, process the full assigned range
        // with the established serial-order kernel and its smaller scratch.
        if (self.attention.group_size == 1)
            return attentionHeadRange(&self.attention, tile_start, tile_end);

        const heads_per_tile = self.attention.group_size / self.tiles_per_kv;
        const extra_heads = self.attention.group_size % self.tiles_per_kv;
        var tile_index = tile_start;
        while (tile_index < tile_end) : (tile_index += 1) {
            const kv_head = tile_index / self.tiles_per_kv;
            const local_tile = tile_index % self.tiles_per_kv;
            const local_start = local_tile * heads_per_tile + @min(local_tile, extra_heads);
            const local_end = local_start + heads_per_tile + @intFromBool(local_tile < extra_heads);
            const local_count = local_end - local_start;
            switch (local_count) {
                1 => {
                    const head = kv_head * self.attention.group_size + local_start;
                    try attentionHeadRange(&self.attention, head, head + 1);
                },
                2 => try attentionSharedKvTileExact(2, &self.attention, kv_head, local_start),
                3 => try attentionSharedKvTileExact(3, &self.attention, kv_head, local_start),
                4 => try attentionSharedKvTileExact(4, &self.attention, kv_head, local_start),
                else => return TensorError.ShapeMismatch,
            }
        }
    }

    /// True only when at least one tile evaluates multiple query heads over a
    /// shared K/V stream. GQA geometries split into one-head occupancy tiles
    /// intentionally do not claim fused-kernel telemetry.
    pub fn usesFusedSharedKv(self: *const SharedKvAttentionPlan) bool {
        return self.attention.group_size > 1 and
            self.tiles_per_kv < self.attention.group_size;
    }

    /// Validate the position-dependent attention view used by a sealed decode
    /// invocation and return a stable key for its request-local buffers and
    /// geometry. `kv_seq` and `query_start` advance each token but must match
    /// the admitted absolute position exactly.
    pub fn sealedBindingKey(
        self: *const SharedKvAttentionPlan,
        position: usize,
        task_count: usize,
    ) TensorError!u64 {
        const expected_kv_seq = std.math.add(usize, position, 1) catch
            return TensorError.ShapeMismatch;
        const attention = self.attention;
        if (attention.q_seq != 1 or attention.kv_seq != expected_kv_seq or
            attention.query_start != position or self.task_count != task_count or
            task_count == 0)
            return TensorError.ShapeMismatch;

        return self.binding_key;
    }
};

/// Request-local attention recipe paired with a sealed Handoff plan. Full
/// backing/alias checks happen once; binding a new absolute position only
/// derives live K/V lengths and preserves the original arithmetic geometry.
pub const SealedSharedKvAttentionRecipe = struct {
    q: []const f32,
    k_backing: []const f32,
    v_backing: []const f32,
    out: []f32,
    q_dim: usize,
    kv_dim: usize,
    num_heads: usize,
    head_dim: usize,
    group_size: usize,
    scale: f32,
    task_count: usize,
    tile_count: usize,
    tiles_per_kv: usize,
    binding_key: u64,
    integrity: u64,

    pub fn init(
        plan: *const SharedKvAttentionPlan,
        k_backing: []const f32,
        v_backing: []const f32,
    ) TensorError!SealedSharedKvAttentionRecipe {
        const attention = plan.attention;
        if (attention.q_seq != 1 or attention.kv_seq == 0 or
            attention.q_dim == 0 or attention.kv_dim == 0 or
            attention.num_heads == 0 or attention.head_dim == 0 or
            attention.group_size == 0 or
            attention.num_heads % attention.group_size != 0 or
            attention.query_start != attention.kv_seq - 1 or
            k_backing.len != v_backing.len or
            k_backing.len % attention.kv_dim != 0 or
            k_backing.len / attention.kv_dim > max_attention_context or
            k_backing.len < attention.k.len or
            v_backing.len < attention.v.len or
            k_backing.ptr != attention.k.ptr or v_backing.ptr != attention.v.ptr)
            return TensorError.ShapeMismatch;
        const expected_q_dim = std.math.mul(
            usize,
            attention.num_heads,
            attention.head_dim,
        ) catch return TensorError.ShapeMismatch;
        const kv_head_count = attention.num_heads / attention.group_size;
        const expected_kv_dim = std.math.mul(
            usize,
            kv_head_count,
            attention.head_dim,
        ) catch return TensorError.ShapeMismatch;
        const live_kv_count = std.math.mul(
            usize,
            attention.kv_seq,
            attention.kv_dim,
        ) catch return TensorError.ShapeMismatch;
        const expected_tile_count = std.math.mul(
            usize,
            kv_head_count,
            plan.tiles_per_kv,
        ) catch return TensorError.ShapeMismatch;
        const expected_scale = 1.0 / std.math.sqrt(
            @as(f32, @floatFromInt(attention.head_dim)),
        );
        if (attention.q_dim != expected_q_dim or
            attention.kv_dim != expected_kv_dim or
            attention.q.len != attention.q_dim or
            attention.out.len != attention.q_dim or
            attention.k.len != live_kv_count or
            attention.v.len != live_kv_count or
            @as(u32, @bitCast(attention.scale)) !=
                @as(u32, @bitCast(expected_scale)) or
            plan.tiles_per_kv == 0 or
            plan.tiles_per_kv > attention.group_size or
            ceilDivNonZero(attention.group_size, plan.tiles_per_kv) >
                max_shared_kv_tile_width or
            plan.tile_count != expected_tile_count or
            plan.task_count == 0 or plan.task_count > plan.tile_count or
            plan.binding_key != attentionBindingKey(
                attention,
                plan.task_count,
                plan.tile_count,
                plan.tiles_per_kv,
            ))
            return TensorError.ShapeMismatch;
        const q_bytes = std.mem.sliceAsBytes(attention.q);
        const k_bytes = std.mem.sliceAsBytes(k_backing);
        const v_bytes = std.mem.sliceAsBytes(v_backing);
        const output_bytes = std.mem.sliceAsBytes(attention.out);
        if (byteRangesOverlap(k_bytes, v_bytes) or
            byteRangesOverlap(q_bytes, k_bytes) or
            byteRangesOverlap(q_bytes, v_bytes) or
            byteRangesOverlap(output_bytes, q_bytes) or
            byteRangesOverlap(output_bytes, k_bytes) or
            byteRangesOverlap(output_bytes, v_bytes))
            return TensorError.ShapeMismatch;
        var recipe: SealedSharedKvAttentionRecipe = .{
            .q = attention.q,
            .k_backing = k_backing,
            .v_backing = v_backing,
            .out = attention.out,
            .q_dim = attention.q_dim,
            .kv_dim = attention.kv_dim,
            .num_heads = attention.num_heads,
            .head_dim = attention.head_dim,
            .group_size = attention.group_size,
            .scale = attention.scale,
            .task_count = plan.task_count,
            .tile_count = plan.tile_count,
            .tiles_per_kv = plan.tiles_per_kv,
            .binding_key = plan.binding_key,
            .integrity = 0,
        };
        recipe.integrity = sealedAttentionRecipeIntegrity(&recipe);
        return recipe;
    }

    pub fn bind(
        self: *const SealedSharedKvAttentionRecipe,
        position: usize,
    ) TensorError!SharedKvAttentionPlan {
        if (self.integrity != sealedAttentionRecipeIntegrity(self))
            return TensorError.ShapeMismatch;
        const kv_seq = std.math.add(usize, position, 1) catch
            return TensorError.ShapeMismatch;
        const kv_count = std.math.mul(usize, kv_seq, self.kv_dim) catch
            return TensorError.ShapeMismatch;
        if (kv_count > self.k_backing.len or self.q.len != self.q_dim or
            self.out.len != self.q_dim)
            return TensorError.ShapeMismatch;
        return .{
            .attention = .{
                .q = self.q,
                .k = self.k_backing[0..kv_count],
                .v = self.v_backing[0..kv_count],
                .out = self.out,
                .q_seq = 1,
                .q_dim = self.q_dim,
                .kv_seq = kv_seq,
                .kv_dim = self.kv_dim,
                .num_heads = self.num_heads,
                .head_dim = self.head_dim,
                .group_size = self.group_size,
                .query_start = position,
                .scale = self.scale,
            },
            .task_count = self.task_count,
            .tile_count = self.tile_count,
            .tiles_per_kv = self.tiles_per_kv,
            .binding_key = self.binding_key,
        };
    }
};

fn sealedAttentionRecipeIntegrity(
    recipe: *const SealedSharedKvAttentionRecipe,
) u64 {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    hash = bindingMix(hash, @intFromPtr(recipe.q.ptr));
    hash = bindingMix(hash, recipe.q.len);
    hash = bindingMix(hash, @intFromPtr(recipe.k_backing.ptr));
    hash = bindingMix(hash, recipe.k_backing.len);
    hash = bindingMix(hash, @intFromPtr(recipe.v_backing.ptr));
    hash = bindingMix(hash, recipe.v_backing.len);
    hash = bindingMix(hash, @intFromPtr(recipe.out.ptr));
    hash = bindingMix(hash, recipe.out.len);
    hash = bindingMix(hash, recipe.q_dim);
    hash = bindingMix(hash, recipe.kv_dim);
    hash = bindingMix(hash, recipe.num_heads);
    hash = bindingMix(hash, recipe.head_dim);
    hash = bindingMix(hash, recipe.group_size);
    hash = bindingMix(hash, @as(u32, @bitCast(recipe.scale)));
    hash = bindingMix(hash, recipe.task_count);
    hash = bindingMix(hash, recipe.tile_count);
    hash = bindingMix(hash, recipe.tiles_per_kv);
    return bindingMix(hash, recipe.binding_key);
}

fn attentionBindingKey(
    attention: AttentionContext,
    task_count: usize,
    tile_count: usize,
    tiles_per_kv: usize,
) u64 {
    var key: u64 = 0xcbf2_9ce4_8422_2325;
    key = bindingMix(key, @intFromPtr(attention.q.ptr));
    key = bindingMix(key, @intFromPtr(attention.k.ptr));
    key = bindingMix(key, @intFromPtr(attention.v.ptr));
    key = bindingMix(key, @intFromPtr(attention.out.ptr));
    key = bindingMix(key, attention.q_dim);
    key = bindingMix(key, attention.kv_dim);
    key = bindingMix(key, attention.num_heads);
    key = bindingMix(key, attention.head_dim);
    key = bindingMix(key, attention.group_size);
    key = bindingMix(key, task_count);
    key = bindingMix(key, tile_count);
    return bindingMix(key, tiles_per_kv);
}

inline fn bindingMix(state: u64, value: u64) u64 {
    return (state ^ value) *% 0x0000_0100_0000_01b3;
}

/// Allocation-free parallel attention over deterministic, disjoint query-head
/// ranges. It deliberately parallelizes outside each head, preserving the
/// serial floating-point operation order within every output element.
pub fn attentionMultiHeadParallel(
    q: Tensor,
    k: Tensor,
    v: Tensor,
    out: Tensor,
    num_heads: usize,
    head_dim: usize,
    rope_theta: f32,
    num_kv_heads: usize,
    executor: *int4_executor.Executor,
) TensorError!void {
    _ = rope_theta;
    var plan = try ParallelAttentionPlan.init(
        q,
        k,
        v,
        out,
        num_heads,
        head_dim,
        num_kv_heads,
        executor.participantCount(),
        .balanced_heads,
    );
    return executor.parallelFor(plan.task_count, @ptrCast(&plan), ParallelAttentionPlan.run);
}

inline fn addInto(dst: []f32, a: []const f32, b: []const f32) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 1) dst[i] = a[i] + b[i];
}

inline fn mulInto(dst: []f32, a: []const f32, b: []const f32) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 1) dst[i] = a[i] * b[i];
}

// ---------------------------------------------------------------------------
// Test: a layer with identity weights should produce a recognizable output.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "forward layer with identity weights returns approximately the input" {
    // Build a layer where Q/K/V/O and gate/up/down behave as scaled identity.
    // For INT4 with group_size 64 on small dim we can't get exact identity,
    // so this test just verifies the layer runs end-to-end without NaNs
    // and the output shape matches the input.
    const allocator = testing.allocator;
    const dim: usize = 8;
    const hidden: usize = 16;
    const seq: usize = 3;

    // Random-ish activations.
    var x_vals: [seq * dim]f32 = undefined;
    var rng = std.Random.DefaultPrng.init(1);
    for (&x_vals) |*v| v.* = rng.random().float(f32) * 2 - 1;
    var x = try tensor.fromF32(allocator, &.{ seq, dim }, &x_vals);
    defer x.deinit();

    // Build identity-ish weight matrices directly as f32 (no quantization
    // in this path now — the loader handles INT4 dequant; forward is pure f32).
    var wq_vals: [dim * dim]f32 = undefined;
    var mlp_vals: [hidden * dim]f32 = undefined;
    var down_vals: [dim * hidden]f32 = undefined;
    for (&wq_vals, 0..) |*v, i| v.* = if (i % (dim + 1) == 0) 0.1 else 0.01;
    for (&mlp_vals, 0..) |*v, i| v.* = if (i % dim == 0) 0.05 else 0.005;
    for (&down_vals, 0..) |*v, i| v.* = if (i % hidden == 0) 0.05 else 0.005;

    var norm_w: [dim]f32 = undefined;
    @memset(&norm_w, 1.0);

    const weights = LayerWeights{
        .input_norm = &norm_w,
        .wq = &wq_vals,
        .wk = &wq_vals,
        .wv = &wq_vals,
        .wo = &wq_vals,
        .bq = &.{},
        .bk = &.{},
        .bv = &.{},
        .bo = &.{},
        .post_attn_norm = &norm_w,
        .w_gate = &mlp_vals,
        .w_up = &mlp_vals,
        .w_down = &down_vals,
    };

    var y = try forwardLayer(allocator, .{
        .dim = dim,
        .hidden_dim = hidden,
        .seq_len = seq,
        .num_heads = 1,
        .head_dim = dim,
        .num_kv_heads = 1, // MHA for this fixture (1 kv head = 1 q head)
    }, weights, x);
    defer y.deinit();

    // Output shape must match input.
    try testing.expectEqual(@as(usize, seq), y.shape[0]);
    try testing.expectEqual(@as(usize, dim), y.shape[1]);
    // No NaN / inf.
    for (y.asF32()) |v| {
        try testing.expect(std.math.isFinite(v));
    }
}

// ===========================================================================
// Multi-layer model forward
// ===========================================================================

const loader = @import("loader.zig");

/// Run a full forward pass: embeddings → N transformer layers → final
/// RMSNorm → lm_head → logits.
///
/// `token_ids` : input prompt as token indices, length seq_len.
/// `out_logits` : caller-allocated [seq_len, vocab_size] tensor.
///
/// This is the MVP full-stack path. It owns every intermediate tensor it
/// allocates and frees them before returning; only `out_logits` survives.
pub fn forwardModel(
    allocator: std.mem.Allocator,
    model: loader.LoadedModel,
    token_ids: []const u32,
    out_logits: Tensor, // [seq_len, vocab_size]
) !void {
    const cfg = model.config;
    const seq = token_ids.len;
    if (out_logits.shape.len != 2 or out_logits.shape[0] != seq or out_logits.shape[1] != cfg.vocab_size) {
        return TensorError.ShapeMismatch;
    }

    // --- Embedding lookup -------------------------------------------------
    // Weights already decoded to f32 by the loader; just gather rows.
    var x = try tensor.zerosF32(allocator, &.{ seq, cfg.dim });
    defer x.deinit();
    {
        const emb = model.token_embedding;
        const rows = emb.len / cfg.dim;
        for (token_ids, 0..) |tid, i| {
            const row = @min(tid, @as(u32, @intCast(rows - 1)));
            @memcpy(
                x.asF32()[i * cfg.dim .. (i + 1) * cfg.dim],
                emb[@as(usize, row) * cfg.dim .. (@as(usize, row) + 1) * cfg.dim],
            );
        }
    }

    // --- Layer stack ------------------------------------------------------
    // We thread `h` through every layer, freeing the previous buffer when
    // we allocate the next one (except the very first iteration where h
    // aliases x, which is freed by the outer defer).
    var h = x;
    var h_owned = false;
    defer if (h_owned) h.deinit();

    for (model.layers, 0..) |lw, i| {
        const next = try forwardLayer(allocator, .{
            .dim = cfg.dim,
            .hidden_dim = cfg.hidden_dim,
            .rms_eps = cfg.rms_eps,
            .seq_len = seq,
            .num_heads = cfg.num_heads,
            .head_dim = cfg.head_dim,
            .rope_theta = cfg.rope_theta,
            .num_kv_heads = cfg.num_kv_heads,
        }, lw, h);
        if (i > 0) {
            // Free the previous owned intermediate. The first iteration
            // aliases x, which the outer defer frees.
            h.deinit();
        }
        h = next;
        h_owned = true;
    }

    // --- Final norm + lm_head → logits -----------------------------------
    var final_h = try tensor.zerosF32(allocator, &.{ seq, cfg.dim });
    defer final_h.deinit();
    try kernels.rmsNormF32(h, model.final_norm, cfg.rms_eps, final_h);

    // lm_head weights already decoded to f32 — just wrap as a view.
    try linearF32Weights(final_h, model.lm_head, &.{}, cfg.vocab_size, cfg.dim, out_logits);
}

/// Compute softmax over a slice in-place. Stable (subtracts max).
pub fn softmaxInPlace(v: []f32) void {
    var max_v: f32 = -std.math.inf(f32);
    for (v) |x| if (x > max_v) {
        max_v = x;
    };
    var sum: f32 = 0;
    for (v) |*x| {
        x.* = std.math.exp(x.* - max_v);
        sum += x.*;
    }
    if (sum > 0) for (v) |*x| {
        x.* /= sum;
    };
}

/// Argmax over a slice. Returns the index of the largest value.
pub fn argmax(v: []const f32) usize {
    var best_i: usize = 0;
    var best_v: f32 = v[0];
    for (v[1..], 1..) |x, i| {
        if (x > best_v) {
            best_v = x;
            best_i = i;
        }
    }
    return best_i;
}

test "RoPE rotates consecutive pairs by expected angle" {
    // 1 head, head_dim=4: pairs (0,2) and (1,3) in GPT-NeoX layout.
    // 2 positions so position 1 gets angle = 1 / 10000^0 = 1.0 rad for k=0.
    var buf = [_]f32{
        0, 0, 0, 0, // position 0 (untouched by the assertion)
        1, 0, 0, 0, // position 1: x[4]=1, x[6]=0
    };
    const slice: []f32 = &buf;
    applyRopeInPlace(slice, 2, 1, 4, 10000.0);

    // pair at position 1, idx0=4, idx1=6: rotated by angle 1.0.
    try testing.expectApproxEqAbs(@as(f32, std.math.cos(1.0)), buf[4], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, std.math.sin(1.0)), buf[6], 1e-5);
}

test "RoPE at position 0 is identity" {
    // pos=0 → angle=0 → no rotation regardless of theta.
    var buf = [_]f32{ 3, 7, -2, 5 };
    const original = buf;
    const slice: []f32 = &buf;
    applyRopeInPlace(slice, 1, 1, 4, 10000.0);
    try testing.expectEqualSlices(f32, &original, &buf);
}

test "multi-head attention runs with 2 heads and stays finite" {
    // Smoke test: 2 heads × head_dim 4 = dim 8, seq 3, with random Q/K/V.
    // RoPE + softmax + V mixing should all produce finite output.
    const allocator = testing.allocator;
    const seq: usize = 3;
    const num_heads: usize = 2;
    const head_dim: usize = 4;
    const dim = num_heads * head_dim;

    var rng = std.Random.DefaultPrng.init(5);
    var q_vals: [seq * dim]f32 = undefined;
    var k_vals: [seq * dim]f32 = undefined;
    var v_vals: [seq * dim]f32 = undefined;
    for (&q_vals) |*x| x.* = rng.random().float(f32) * 2 - 1;
    for (&k_vals) |*x| x.* = rng.random().float(f32) * 2 - 1;
    for (&v_vals) |*x| x.* = rng.random().float(f32) * 2 - 1;

    var q = try tensor.fromF32(allocator, &.{ seq, dim }, &q_vals);
    defer q.deinit();
    var k = try tensor.fromF32(allocator, &.{ seq, dim }, &k_vals);
    defer k.deinit();
    var v = try tensor.fromF32(allocator, &.{ seq, dim }, &v_vals);
    defer v.deinit();
    var out = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer out.deinit();

    try attentionMultiHead(q, k, v, out, num_heads, head_dim, 10000.0, num_heads);

    for (out.asF32()) |x| try testing.expect(std.math.isFinite(x));

    // Causality: row 0 of out must depend only on row 0 of v (single-token
    // context). Changing rows 1..2 of v must not change row 0 of out.
    var v2_vals = v_vals;
    v2_vals[dim + 0] = 999.0; // perturb row 1
    var v2 = try tensor.fromF32(allocator, &.{ seq, dim }, &v2_vals);
    defer v2.deinit();
    var q_copy = try tensor.fromF32(allocator, &.{ seq, dim }, &q_vals);
    defer q_copy.deinit();
    var k_copy = try tensor.fromF32(allocator, &.{ seq, dim }, &k_vals);
    defer k_copy.deinit();
    var out2 = try tensor.zerosF32(allocator, &.{ seq, dim });
    defer out2.deinit();
    try attentionMultiHead(q_copy, k_copy, v2, out2, num_heads, head_dim, 10000.0, num_heads);

    // Row 0 should be identical; rows 1..2 may differ.
    try testing.expectEqualSlices(f32, out.asF32()[0..dim], out2.asF32()[0..dim]);
}

test "parallel and split-range attention are byte-identical for MHA and GQA" {
    const allocator = testing.allocator;
    const q_seq: usize = 3;
    const kv_seq: usize = 19;
    const num_heads: usize = 14;
    const head_dim: usize = 10;
    const q_dim = num_heads * head_dim;

    var executor: int4_executor.Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();

    for ([_]usize{ num_heads, 2, 1 }) |num_kv_heads| {
        const kv_dim = num_kv_heads * head_dim;
        const q_values = try allocator.alloc(f32, q_seq * q_dim);
        defer allocator.free(q_values);
        const k_values = try allocator.alloc(f32, kv_seq * kv_dim);
        defer allocator.free(k_values);
        const v_values = try allocator.alloc(f32, kv_seq * kv_dim);
        defer allocator.free(v_values);

        var rng = std.Random.DefaultPrng.init(0x91a7 + num_kv_heads);
        for (q_values) |*value| value.* = rng.random().float(f32) * 2 - 1;
        for (k_values) |*value| value.* = rng.random().float(f32) * 2 - 1;
        for (v_values) |*value| value.* = rng.random().float(f32) * 2 - 1;

        var q = try tensor.fromF32(allocator, &.{ q_seq, q_dim }, q_values);
        defer q.deinit();
        var k = try tensor.fromF32(allocator, &.{ kv_seq, kv_dim }, k_values);
        defer k.deinit();
        var v = try tensor.fromF32(allocator, &.{ kv_seq, kv_dim }, v_values);
        defer v.deinit();
        var serial = try tensor.zerosF32(allocator, &.{ q_seq, q_dim });
        defer serial.deinit();
        var parallel = try tensor.zerosF32(allocator, &.{ q_seq, q_dim });
        defer parallel.deinit();
        var affine = try tensor.zerosF32(allocator, &.{ q_seq, q_dim });
        defer affine.deinit();
        var shared_kv = try tensor.zerosF32(allocator, &.{ q_seq, q_dim });
        defer shared_kv.deinit();
        var split = try tensor.zerosF32(allocator, &.{ q_seq, q_dim });
        defer split.deinit();

        try attentionMultiHead(q, k, v, serial, num_heads, head_dim, 10000.0, num_kv_heads);
        try attentionMultiHeadParallel(
            q,
            k,
            v,
            parallel,
            num_heads,
            head_dim,
            10000.0,
            num_kv_heads,
            &executor,
        );
        var affine_plan = try ParallelAttentionPlan.init(
            q,
            k,
            v,
            affine,
            num_heads,
            head_dim,
            num_kv_heads,
            executor.participantCount(),
            .gqa_affine,
        );
        try executor.parallelFor(
            affine_plan.task_count,
            @ptrCast(&affine_plan),
            ParallelAttentionPlan.run,
        );
        try testing.expectEqual(
            @min(num_kv_heads, executor.participantCount()),
            affine_plan.task_count,
        );
        var shared_kv_plan = try SharedKvAttentionPlan.init(
            q,
            k,
            v,
            shared_kv,
            num_heads,
            head_dim,
            num_kv_heads,
            executor.participantCount(),
        );
        try executor.parallelFor(
            shared_kv_plan.task_count,
            @ptrCast(&shared_kv_plan),
            SharedKvAttentionPlan.run,
        );
        try testing.expectEqual(
            @min(shared_kv_plan.tile_count, executor.participantCount()),
            shared_kv_plan.task_count,
        );
        const expected_tiles_per_kv: usize = if (num_kv_heads == num_heads)
            1
        else if (num_kv_heads == 2)
            2
        else
            4;
        try testing.expectEqual(expected_tiles_per_kv, shared_kv_plan.tiles_per_kv);
        try testing.expectEqual(
            num_kv_heads != num_heads,
            shared_kv_plan.usesFusedSharedKv(),
        );
        try attentionMultiHeadRange(q, k, v, split, num_heads, head_dim, 10000.0, num_kv_heads, 0, 1);
        try attentionMultiHeadRange(q, k, v, split, num_heads, head_dim, 10000.0, num_kv_heads, 1, 5);
        try attentionMultiHeadRange(q, k, v, split, num_heads, head_dim, 10000.0, num_kv_heads, 5, num_heads);

        try testing.expectEqualSlices(u8, serial.data, parallel.data);
        try testing.expectEqualSlices(u8, serial.data, affine.data);
        try testing.expectEqualSlices(u8, serial.data, shared_kv.data);
        try testing.expectEqualSlices(u8, serial.data, split.data);
        try testing.expectError(
            TensorError.ShapeMismatch,
            attentionMultiHeadRange(q, k, v, split, num_heads, head_dim, 10000.0, num_kv_heads, 3, 3),
        );
    }
}

test "shared-KV kernel is byte-identical at Qwen decode geometries" {
    const allocator = testing.allocator;
    const num_heads: usize = 14;
    const num_kv_heads: usize = 2;
    const head_dim: usize = 64;
    const q_dim = num_heads * head_dim;
    const kv_dim = num_kv_heads * head_dim;

    var executor: int4_executor.Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();

    for ([_]usize{ 177, 687, max_attention_context }) |kv_seq| {
        const q_values = try allocator.alloc(f32, q_dim);
        defer allocator.free(q_values);
        const k_values = try allocator.alloc(f32, kv_seq * kv_dim);
        defer allocator.free(k_values);
        const v_values = try allocator.alloc(f32, kv_seq * kv_dim);
        defer allocator.free(v_values);
        var rng = std.Random.DefaultPrng.init(0x6a7a_0040 + kv_seq);
        for (q_values) |*value| value.* = rng.random().float(f32) * 2 - 1;
        for (k_values) |*value| value.* = rng.random().float(f32) * 2 - 1;
        for (v_values) |*value| value.* = rng.random().float(f32) * 2 - 1;

        var q = try tensor.fromF32(allocator, &.{ 1, q_dim }, q_values);
        defer q.deinit();
        var k = try tensor.fromF32(allocator, &.{ kv_seq, kv_dim }, k_values);
        defer k.deinit();
        var v = try tensor.fromF32(allocator, &.{ kv_seq, kv_dim }, v_values);
        defer v.deinit();
        var serial = try tensor.zerosF32(allocator, &.{ 1, q_dim });
        defer serial.deinit();
        var shared_kv = try tensor.zerosF32(allocator, &.{ 1, q_dim });
        defer shared_kv.deinit();

        try attentionMultiHead(q, k, v, serial, num_heads, head_dim, 10000.0, num_kv_heads);
        var plan = try SharedKvAttentionPlan.init(
            q,
            k,
            v,
            shared_kv,
            num_heads,
            head_dim,
            num_kv_heads,
            executor.participantCount(),
        );
        try testing.expectEqual(@as(usize, 2), plan.tiles_per_kv);
        try testing.expectEqual(@as(usize, 4), plan.tile_count);
        try testing.expectEqual(@as(usize, 4), plan.task_count);
        try executor.parallelFor(plan.task_count, @ptrCast(&plan), SharedKvAttentionPlan.run);
        try testing.expectEqualSlices(u8, serial.data, shared_kv.data);

        var malformed_plan = plan;
        malformed_plan.tile_count +%= 1;
        try testing.expectError(
            TensorError.ShapeMismatch,
            SealedSharedKvAttentionRecipe.init(
                &malformed_plan,
                k.asF32Unsafe(),
                v.asF32Unsafe(),
            ),
        );

        const recipe = try SealedSharedKvAttentionRecipe.init(
            &plan,
            k.asF32Unsafe(),
            v.asF32Unsafe(),
        );
        var rebound = try recipe.bind(kv_seq - 1);
        try testing.expectEqual(plan.binding_key, rebound.binding_key);
        @memset(shared_kv.asF32Unsafe(), 0);
        try executor.parallelFor(
            rebound.task_count,
            @ptrCast(&rebound),
            SharedKvAttentionPlan.run,
        );
        try testing.expectEqualSlices(u8, serial.data, shared_kv.data);
        try testing.expectError(TensorError.ShapeMismatch, recipe.bind(kv_seq));

        var corrupt_recipe = recipe;
        corrupt_recipe.q = corrupt_recipe.k_backing[0..q_dim];
        @memset(shared_kv.asF32Unsafe(), -123);
        try testing.expectError(
            TensorError.ShapeMismatch,
            corrupt_recipe.bind(kv_seq - 1),
        );
        for (shared_kv.asF32Unsafe()) |value|
            try testing.expectEqual(@as(f32, -123), value);

        var alias_q_shape: [2]usize = .{ 1, q_dim };
        const alias_q: Tensor = .{
            .dtype = .f32,
            .shape = &alias_q_shape,
            .data = std.mem.sliceAsBytes(k.asF32Unsafe()[0..q_dim]),
            .allocator = std.heap.page_allocator,
        };
        const alias_plan = try SharedKvAttentionPlan.init(
            alias_q,
            k,
            v,
            shared_kv,
            num_heads,
            head_dim,
            num_kv_heads,
            4,
        );
        try testing.expectError(
            TensorError.ShapeMismatch,
            SealedSharedKvAttentionRecipe.init(
                &alias_plan,
                k.asF32Unsafe(),
                v.asF32Unsafe(),
            ),
        );
    }
}

test "shared-KV planner covers uneven GQA groups at every participant count" {
    const allocator = testing.allocator;
    const num_heads: usize = 14;
    const num_kv_heads: usize = 2;
    const head_dim: usize = 1;
    var q = try tensor.fromF32(allocator, &.{ 1, num_heads }, &([_]f32{0.25} ** num_heads));
    defer q.deinit();
    var k = try tensor.fromF32(allocator, &.{ 1, num_kv_heads }, &([_]f32{0.5} ** num_kv_heads));
    defer k.deinit();
    var v = try tensor.fromF32(allocator, &.{ 1, num_kv_heads }, &.{ 3.0, 7.0 });
    defer v.deinit();
    var serial = try tensor.zerosF32(allocator, &.{ 1, num_heads });
    defer serial.deinit();
    var shared_kv = try tensor.zerosF32(allocator, &.{ 1, num_heads });
    defer shared_kv.deinit();
    try attentionMultiHead(q, k, v, serial, num_heads, head_dim, 10000.0, num_kv_heads);

    for ([_]usize{ 2, 3, 4, 8 }) |participants| {
        @memset(shared_kv.asF32Unsafe(), 0);
        var plan = try SharedKvAttentionPlan.init(
            q,
            k,
            v,
            shared_kv,
            num_heads,
            head_dim,
            num_kv_heads,
            participants,
        );
        const expected_tiles_per_kv: usize = if (participants <= 4) 2 else 4;
        try testing.expectEqual(expected_tiles_per_kv, plan.tiles_per_kv);
        try testing.expectEqual(num_kv_heads * expected_tiles_per_kv, plan.tile_count);
        try testing.expectEqual(@min(participants, plan.tile_count), plan.task_count);
        for (0..plan.task_count) |task_index|
            try SharedKvAttentionPlan.run(@ptrCast(&plan), task_index);
        try testing.expectEqualSlices(u8, serial.data, shared_kv.data);
    }
}

test "one-head GQA occupancy tiles do not claim fused shared-KV execution" {
    const allocator = testing.allocator;
    var q = try tensor.fromF32(allocator, &.{ 1, 4 }, &.{ 1, 2, 3, 4 });
    defer q.deinit();
    var k = try tensor.fromF32(allocator, &.{ 1, 2 }, &.{ 1, 2 });
    defer k.deinit();
    var v = try tensor.fromF32(allocator, &.{ 1, 2 }, &.{ 3, 4 });
    defer v.deinit();
    var out = try tensor.zerosF32(allocator, &.{ 1, 4 });
    defer out.deinit();
    var plan = try SharedKvAttentionPlan.init(q, k, v, out, 4, 1, 2, 4);
    try testing.expectEqual(@as(usize, 2), plan.tiles_per_kv);
    try testing.expect(!plan.usesFusedSharedKv());
}

test "parallel attention rejects overlapping query and GQA KV output storage" {
    const allocator = testing.allocator;
    const num_heads: usize = 4;
    const num_kv_heads: usize = 1;
    const head_dim: usize = 2;
    const q_dim = num_heads * head_dim;
    const kv_dim = num_kv_heads * head_dim;
    const kv_seq: usize = 4;

    var q = try tensor.fromF32(allocator, &.{ 1, q_dim }, &([_]f32{0.25} ** q_dim));
    defer q.deinit();
    var v = try tensor.fromF32(allocator, &.{ kv_seq, kv_dim }, &([_]f32{0.5} ** (kv_seq * kv_dim)));
    defer v.deinit();
    var kv_out_storage = [_]f32{0.75} ** (kv_seq * kv_dim);
    var k_shape = [2]usize{ kv_seq, kv_dim };
    var out_shape = [2]usize{ 1, q_dim };
    const k: Tensor = .{
        .dtype = .f32,
        .shape = &k_shape,
        .data = std.mem.sliceAsBytes(&kv_out_storage),
        .allocator = std.heap.page_allocator,
    };
    const overlapping_out: Tensor = .{
        .dtype = .f32,
        .shape = &out_shape,
        .data = std.mem.sliceAsBytes(&kv_out_storage),
        .allocator = std.heap.page_allocator,
    };

    var executor: int4_executor.Executor = undefined;
    try executor.init(allocator, 4);
    defer executor.deinit();
    try testing.expectError(
        TensorError.ShapeMismatch,
        attentionMultiHeadParallel(
            q,
            k,
            v,
            overlapping_out,
            num_heads,
            head_dim,
            10000.0,
            num_kv_heads,
            &executor,
        ),
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        attentionMultiHeadParallel(
            q,
            k,
            v,
            q,
            num_heads,
            head_dim,
            10000.0,
            num_kv_heads,
            &executor,
        ),
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        SharedKvAttentionPlan.init(
            q,
            k,
            v,
            overlapping_out,
            num_heads,
            head_dim,
            num_kv_heads,
            executor.participantCount(),
        ),
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        SharedKvAttentionPlan.init(
            q,
            k,
            v,
            q,
            num_heads,
            head_dim,
            num_kv_heads,
            executor.participantCount(),
        ),
    );
}

test "chunked causal attention cannot see future rows in its suffix" {
    const allocator = testing.allocator;
    var q = try tensor.fromF32(allocator, &.{ 2, 1 }, &.{ 0, 0 });
    defer q.deinit();
    var k = try tensor.fromF32(allocator, &.{ 4, 1 }, &.{ 0, 0, 0, 0 });
    defer k.deinit();
    var v = try tensor.fromF32(allocator, &.{ 4, 1 }, &.{ 1, 2, 3, 100 });
    defer v.deinit();
    var out = try tensor.zerosF32(allocator, &.{ 2, 1 });
    defer out.deinit();
    try attentionMultiHead(q, k, v, out, 1, 1, 10000.0, 1);
    // Query rows are absolute positions 2 and 3. Position 2 averages only
    // values 0..2, while position 3 can consume the final sentinel row.
    try testing.expectApproxEqAbs(@as(f32, 2.0), out.asF32()[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 26.5), out.asF32()[1], 1e-6);
}

test "attention accepts its 4096-token boundary and rejects 4097" {
    const allocator = testing.allocator;
    var values = try allocator.alloc(f32, max_attention_context + 1);
    defer allocator.free(values);
    @memset(values, 1.0);

    var q = try tensor.fromF32(allocator, &.{ 1, 1 }, &.{0});
    defer q.deinit();
    var k = try tensor.fromF32(
        allocator,
        &.{ max_attention_context, 1 },
        values[0..max_attention_context],
    );
    defer k.deinit();
    var v = try tensor.fromF32(
        allocator,
        &.{ max_attention_context, 1 },
        values[0..max_attention_context],
    );
    defer v.deinit();
    var out = try tensor.zerosF32(allocator, &.{ 1, 1 });
    defer out.deinit();
    try attentionMultiHead(q, k, v, out, 1, 1, 10000.0, 1);
    try testing.expectApproxEqAbs(@as(f32, 1.0), out.asF32()[0], 1e-6);

    var k_too_long = try tensor.fromF32(
        allocator,
        &.{ max_attention_context + 1, 1 },
        values,
    );
    defer k_too_long.deinit();
    var v_too_long = try tensor.fromF32(
        allocator,
        &.{ max_attention_context + 1, 1 },
        values,
    );
    defer v_too_long.deinit();
    try testing.expectError(
        TensorError.ShapeMismatch,
        attentionMultiHead(q, k_too_long, v_too_long, out, 1, 1, 10000.0, 1),
    );
}
