//! Byte-exact serial attention over a paged KV prefix.
//!
//! The kernel preserves the contiguous reference's h/i/j/d traversal, Vec8
//! reduction, softmax order and V accumulation. Only K/V row addressing changes.

const std = @import("std");
const core = @import("core");
const tensor = core.tensor;
const paged = @import("paged_kv_cache.zig");

pub const Tensor = tensor.Tensor;
pub const TensorError = tensor.TensorError;
pub const Error = TensorError || paged.Error;
pub const max_attention_context: usize = 4096;

const AttentionContext = struct {
    q: []const f32,
    out: []f32,
    prefix: paged.LayerPrefix,
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
    prefix: paged.LayerPrefix,
    out: Tensor,
    num_heads: usize,
    head_dim: usize,
    num_kv_heads: usize,
) Error!AttentionContext {
    if (q.dtype != .f32 or out.dtype != .f32)
        return TensorError.DTypeUnsupported;
    if (q.shape.len != 2 or out.shape.len != 2 or
        num_heads == 0 or head_dim == 0)
        return TensorError.ShapeMismatch;

    const effective_kv = if (num_kv_heads == 0) num_heads else num_kv_heads;
    if (effective_kv == 0 or effective_kv > num_heads or
        num_heads % effective_kv != 0)
        return TensorError.ShapeMismatch;
    const q_dim = std.math.mul(usize, num_heads, head_dim) catch
        return TensorError.ShapeMismatch;
    const kv_dim = std.math.mul(usize, effective_kv, head_dim) catch
        return TensorError.ShapeMismatch;
    const q_seq = q.shape[0];
    const kv_seq = prefix.positions;
    if (q_seq == 0 or q_seq > kv_seq or kv_seq > max_attention_context or
        q.shape[1] != q_dim or prefix.cache.dim != kv_dim or
        out.shape[0] != q_seq or out.shape[1] != q_dim)
        return TensorError.ShapeMismatch;

    const q_count = std.math.mul(usize, q_seq, q_dim) catch
        return TensorError.ShapeMismatch;
    const q_bytes = std.math.mul(usize, q_count, @sizeOf(f32)) catch
        return TensorError.ShapeMismatch;
    if (q.data.len < q_bytes or out.data.len < q_bytes or
        @intFromPtr(q.data.ptr) % @alignOf(f32) != 0 or
        @intFromPtr(out.data.ptr) % @alignOf(f32) != 0)
        return TensorError.ShapeMismatch;

    // Validate the complete page chain before touching output. Under the
    // module's single-writer contract it cannot become stale during execution.
    var expected_start: usize = 0;
    var pages = try prefix.iterator();
    while (try pages.next()) |span| {
        const expected_elements = std.math.mul(
            usize,
            span.row_count,
            kv_dim,
        ) catch return TensorError.ShapeMismatch;
        if (span.logical_start != expected_start or span.row_count == 0 or
            span.keys.len != expected_elements or
            span.values.len != expected_elements)
            return TensorError.ShapeMismatch;
        expected_start = std.math.add(
            usize,
            expected_start,
            span.row_count,
        ) catch return TensorError.ShapeMismatch;
    }
    if (expected_start != kv_seq) return TensorError.ShapeMismatch;

    return .{
        .q = q.asF32Unsafe(),
        .out = out.asF32Unsafe(),
        .prefix = prefix,
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

/// Exact serial multi-head attention over one layer's paged K/V prefix.
pub fn attentionMultiHead(
    q: Tensor,
    prefix: paged.LayerPrefix,
    out: Tensor,
    num_heads: usize,
    head_dim: usize,
    rope_theta: f32,
    num_kv_heads: usize,
) Error!void {
    _ = rope_theta;
    const context = try validateAttention(
        q,
        prefix,
        out,
        num_heads,
        head_dim,
        num_kv_heads,
    );

    var h: usize = 0;
    while (h < context.num_heads) : (h += 1) {
        const q_head_off = h * context.head_dim;
        const kv_head_off = (h / context.group_size) * context.head_dim;

        var i: usize = 0;
        while (i < context.q_seq) : (i += 1) {
            const q_head = context.q[i * context.q_dim + q_head_off ..][0..context.head_dim];
            const attend_up_to = @min(
                context.query_start + i,
                context.kv_seq - 1,
            );

            var scores: [max_attention_context]f32 = undefined;
            var max_score: f32 = -std.math.inf(f32);
            const Vec8 = @Vector(8, f32);
            var j: usize = 0;
            var key_pages = try context.prefix.iterator();
            key_loop: while (try key_pages.next()) |span| {
                var local_row: usize = 0;
                while (local_row < span.row_count) : (local_row += 1) {
                    if (j > attend_up_to) break :key_loop;
                    const row_start = local_row * context.kv_dim;
                    const k_row = span.keys[row_start..][0..context.kv_dim];
                    const k_head = k_row[kv_head_off..][0..context.head_dim];
                    var dot_vec: Vec8 = @splat(0);
                    var d: usize = 0;
                    const vec_end = context.head_dim -
                        (context.head_dim % 8);
                    while (d < vec_end) : (d += 8) {
                        const qv8: Vec8 = .{
                            q_head[d],     q_head[d + 1], q_head[d + 2],
                            q_head[d + 3], q_head[d + 4], q_head[d + 5],
                            q_head[d + 6], q_head[d + 7],
                        };
                        const kv8: Vec8 = .{
                            k_head[d],     k_head[d + 1], k_head[d + 2],
                            k_head[d + 3], k_head[d + 4], k_head[d + 5],
                            k_head[d + 6], k_head[d + 7],
                        };
                        dot_vec += qv8 * kv8;
                    }
                    var dot: f32 = @reduce(.Add, dot_vec);
                    while (d < context.head_dim) : (d += 1)
                        dot += q_head[d] * k_head[d];
                    scores[j] = dot * context.scale;
                    if (scores[j] > max_score) max_score = scores[j];
                    j += 1;
                }
            }
            if (j != attend_up_to + 1) return TensorError.ShapeMismatch;

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
            var value_pages = try context.prefix.iterator();
            value_loop: while (try value_pages.next()) |span| {
                var local_row: usize = 0;
                while (local_row < span.row_count) : (local_row += 1) {
                    if (j > attend_up_to) break :value_loop;
                    const weight = scores[j] * inv;
                    const row_start = local_row * context.kv_dim;
                    const v_row = span.values[row_start..][0..context.kv_dim];
                    const v_head = v_row[kv_head_off..][0..context.head_dim];
                    d = 0;
                    while (d < context.head_dim) : (d += 1)
                        context.out[i * context.q_dim + q_head_off + d] +=
                            weight * v_head[d];
                    j += 1;
                }
            }
            if (j != attend_up_to + 1) return TensorError.ShapeMismatch;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const forward = @import("forward.zig");

test "paged and contiguous attention context bounds stay aligned" {
    try testing.expectEqual(forward.max_attention_context, max_attention_context);
}

fn appendRows(
    cache: *paged.PagedKVCache,
    keys: []const f32,
    values: []const f32,
    start: usize,
    end: usize,
) !void {
    for (start..end) |position| {
        const mark = try cache.beginRow();
        const row_start = position * cache.dim;
        _ = try cache.appendRowTxn(
            mark,
            0,
            keys[row_start .. row_start + cache.dim],
            values[row_start .. row_start + cache.dim],
        );
        try cache.commitRowTxn(mark);
    }
}

fn runExactCase(
    seq: usize,
    q_seq: usize,
    num_heads: usize,
    num_kv_heads: usize,
    head_dim: usize,
) !void {
    const q_dim = num_heads * head_dim;
    const kv_dim = num_kv_heads * head_dim;
    const keys = try testing.allocator.alloc(f32, seq * kv_dim);
    defer testing.allocator.free(keys);
    const values = try testing.allocator.alloc(f32, seq * kv_dim);
    defer testing.allocator.free(values);
    const query = try testing.allocator.alloc(f32, q_seq * q_dim);
    defer testing.allocator.free(query);
    for (keys, 0..) |*value, index|
        value.* = @as(f32, @floatFromInt(index % 29)) * 0.03125 - 0.4;
    for (values, 0..) |*value, index|
        value.* = @as(f32, @floatFromInt(index % 31)) * -0.0234375 + 0.3;
    for (query, 0..) |*value, index|
        value.* = @as(f32, @floatFromInt(index % 17)) * 0.046875 - 0.2;

    var cache = try paged.PagedKVCache.init(
        testing.allocator,
        1,
        kv_dim,
        seq,
    );
    defer cache.deinit();
    try appendRows(&cache, keys, values, 0, seq);

    var q = try tensor.fromF32(testing.allocator, &.{ q_seq, q_dim }, query);
    defer q.deinit();
    var k = try tensor.fromF32(testing.allocator, &.{ seq, kv_dim }, keys);
    defer k.deinit();
    var v = try tensor.fromF32(testing.allocator, &.{ seq, kv_dim }, values);
    defer v.deinit();
    var contiguous_out = try tensor.zerosF32(
        testing.allocator,
        &.{ q_seq, q_dim },
    );
    defer contiguous_out.deinit();
    var paged_out = try tensor.zerosF32(
        testing.allocator,
        &.{ q_seq, q_dim },
    );
    defer paged_out.deinit();

    try forward.attentionMultiHead(
        q,
        k,
        v,
        contiguous_out,
        num_heads,
        head_dim,
        10_000,
        num_kv_heads,
    );
    try attentionMultiHead(
        q,
        try cache.committedPrefix(0),
        paged_out,
        num_heads,
        head_dim,
        10_000,
        num_kv_heads,
    );
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(contiguous_out.asF32()),
        std.mem.sliceAsBytes(paged_out.asF32()),
    );
}

test "paged serial attention is byte-identical across page boundaries" {
    for ([_]usize{ 1, 15, 16, 17, 31, 32 }) |seq| {
        try runExactCase(seq, 1, 4, 2, 8);
        try runExactCase(seq, 1, 3, 3, 5);
    }
    try runExactCase(17, 3, 4, 2, 8);
    try runExactCase(32, 5, 3, 3, 5);
}

test "paged serial attention consumes a fully written provisional row" {
    const seq = 17;
    const num_heads = 4;
    const num_kv_heads = 2;
    const head_dim = 4;
    const q_dim = num_heads * head_dim;
    const kv_dim = num_kv_heads * head_dim;
    var keys: [seq * kv_dim]f32 = undefined;
    var values: [seq * kv_dim]f32 = undefined;
    var query: [q_dim]f32 = undefined;
    for (&keys, 0..) |*value, index|
        value.* = @as(f32, @floatFromInt(index % 23)) * 0.0625 - 0.5;
    for (&values, 0..) |*value, index|
        value.* = @as(f32, @floatFromInt(index % 19)) * -0.03125 + 0.2;
    for (&query, 0..) |*value, index|
        value.* = @as(f32, @floatFromInt(index % 13)) * 0.0390625 - 0.1;

    var cache = try paged.PagedKVCache.init(
        testing.allocator,
        1,
        kv_dim,
        seq,
    );
    defer cache.deinit();
    try appendRows(&cache, &keys, &values, 0, 16);
    const mark = try cache.beginRow();
    _ = try cache.appendRowTxn(
        mark,
        0,
        keys[16 * kv_dim ..],
        values[16 * kv_dim ..],
    );

    var q = try tensor.fromF32(testing.allocator, &.{ 1, q_dim }, &query);
    defer q.deinit();
    var k = try tensor.fromF32(testing.allocator, &.{ seq, kv_dim }, &keys);
    defer k.deinit();
    var v = try tensor.fromF32(testing.allocator, &.{ seq, kv_dim }, &values);
    defer v.deinit();
    var contiguous_out = try tensor.zerosF32(
        testing.allocator,
        &.{ 1, q_dim },
    );
    defer contiguous_out.deinit();
    var paged_out = try tensor.zerosF32(testing.allocator, &.{ 1, q_dim });
    defer paged_out.deinit();
    try forward.attentionMultiHead(
        q,
        k,
        v,
        contiguous_out,
        num_heads,
        head_dim,
        10_000,
        num_kv_heads,
    );
    try attentionMultiHead(
        q,
        try cache.txnPrefix(mark, 0),
        paged_out,
        num_heads,
        head_dim,
        10_000,
        num_kv_heads,
    );
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(contiguous_out.asF32()),
        std.mem.sliceAsBytes(paged_out.asF32()),
    );
    try cache.abortRow(mark);
}

test "stale paged prefix rejects before touching attention output" {
    const keys = [_]f32{ 0.25, 0.5 };
    const values = [_]f32{ 0.75, 1.0 };
    var cache = try paged.PagedKVCache.init(testing.allocator, 1, 1, 2);
    defer cache.deinit();
    try appendRows(&cache, &keys, &values, 0, 1);
    const stale = try cache.committedPrefix(0);
    try appendRows(&cache, &keys, &values, 1, 2);

    const query = [_]f32{1};
    var q = try tensor.fromF32(testing.allocator, &.{ 1, 1 }, &query);
    defer q.deinit();
    var out = try tensor.allocF32(testing.allocator, &.{ 1, 1 });
    defer out.deinit();
    out.asF32()[0] = 123.0;
    try testing.expectError(
        error.InvalidRoot,
        attentionMultiHead(q, stale, out, 1, 1, 10_000, 1),
    );
    try testing.expectEqual(@as(f32, 123.0), out.asF32()[0]);
}
