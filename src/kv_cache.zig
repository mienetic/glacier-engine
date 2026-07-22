//! KV cache for autoregressive generation.
//!
//! Without a cache, generating token N requires recomputing attention over
//! the entire prompt [0..N] from scratch — O(N²) work for the Nth token and
//! O(N³) total for a length-N generation. The cache stores the projected
//! K and V for every position ever seen, so the cost of generating token N
//! becomes O(N) (one new K/V row + one attention pass over the cache).
//!
//! Layout: per layer, two contiguous buffers [max_seq, dim] for K and V.
//! The cache owns no allocator state of its own — callers preallocate at
//! the size they intend to fill, and the cache tracks how many positions
//! are currently valid.

const std = @import("std");
const tensor = @import("core").tensor;

pub const Tensor = tensor.Tensor;
pub const TensorError = tensor.TensorError;

/// Generation-fenced logical-row transaction used by request-local decode.
/// Raw tail rows may be written while a transaction is active, but `len`
/// remains the sole visibility boundary until the prepared commit succeeds.
pub const row_txn_abi: u64 = 0x474b_5654_0000_0001;

pub const RowTxnError = error{
    InvalidTransaction,
    TransactionActive,
    TransactionIncomplete,
    GenerationExhausted,
    CacheFull,
    ShapeMismatch,
};

pub const RowTxnMark = struct {
    abi: u64 = row_txn_abi,
    cache_id: usize,
    cache_instance: u64,
    generation: u64,
    base_len: usize,
    row_count: usize,
};

/// A fully validated commit token. The cache must remain request-local and
/// unchanged between `prepareCommit` and `commitPreparedAssumeValid`.
pub const PreparedRowCommit = struct {
    abi: u64 = row_txn_abi,
    cache_id: usize,
    cache_instance: u64,
    generation: u64,
    base_len: usize,
    row_count: usize,
    target_len: usize,
};

const ActiveRowTxn = struct {
    cache_id: usize,
    cache_instance: u64,
    generation: u64,
    base_len: usize,
    row_count: usize,
    next_layer: usize = 0,
};

var next_cache_instance = std.atomic.Value(u64).init(1);

fn reserveCacheInstance() RowTxnError!u64 {
    var current = next_cache_instance.load(.monotonic);
    while (true) {
        if (current == 0 or current == std.math.maxInt(u64))
            return error.GenerationExhausted;
        if (next_cache_instance.cmpxchgWeak(
            current,
            current + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            current = observed;
        } else {
            return current;
        }
    }
}

/// Exact caller-visible allocation ledger. Tensor payload and the two outer
/// slice tables are separated so resource admission never mistakes descriptor
/// bytes for K/V values or silently drops them. Allocator padding is excluded.
pub const LogicalLedger = struct {
    row_elements: usize,
    tensor_payload_bytes: usize,
    descriptor_bytes: usize,
    allocation_payload_bytes: usize,
};

pub fn deriveLogicalLedger(
    num_layers: usize,
    dim: usize,
    max_seq: usize,
) TensorError!LogicalLedger {
    if (num_layers == 0 or dim == 0 or max_seq == 0)
        return TensorError.ShapeMismatch;
    const row_elements = std.math.mul(usize, max_seq, dim) catch
        return TensorError.ShapeMismatch;
    const layer_elements = std.math.mul(usize, num_layers, row_elements) catch
        return TensorError.ShapeMismatch;
    const kv_elements = std.math.mul(usize, layer_elements, 2) catch
        return TensorError.ShapeMismatch;
    const tensor_payload_bytes = std.math.mul(
        usize,
        kv_elements,
        @sizeOf(f32),
    ) catch return TensorError.ShapeMismatch;
    const descriptor_count = std.math.mul(usize, num_layers, 2) catch
        return TensorError.ShapeMismatch;
    const descriptor_bytes = std.math.mul(
        usize,
        descriptor_count,
        @sizeOf([]f32),
    ) catch return TensorError.ShapeMismatch;
    const allocation_payload_bytes = std.math.add(
        usize,
        tensor_payload_bytes,
        descriptor_bytes,
    ) catch return TensorError.ShapeMismatch;
    return .{
        .row_elements = row_elements,
        .tensor_payload_bytes = tensor_payload_bytes,
        .descriptor_bytes = descriptor_bytes,
        .allocation_payload_bytes = allocation_payload_bytes,
    };
}

pub const KVCache = struct {
    allocator: std.mem.Allocator,
    num_layers: usize,
    dim: usize,
    max_seq: usize,
    /// keys[layer][position * dim .. (position+1) * dim].
    /// For multi-head models the dim here is num_heads*head_dim, matching
    /// the layout attentionMultiHead expects.
    keys: [][]f32,
    values: [][]f32,
    ledger: LogicalLedger,
    /// Process-unique, non-wrapping identity; prevents address-reuse ABA.
    instance_id: u64,
    /// Number of positions currently filled in every layer's K/V.
    len: usize = 0,
    next_row_txn_generation: u64 = 1,
    active_row_txn: ?ActiveRowTxn = null,

    pub fn init(
        allocator: std.mem.Allocator,
        num_layers: usize,
        dim: usize,
        max_seq: usize,
    ) !KVCache {
        const ledger = try deriveLogicalLedger(num_layers, dim, max_seq);
        const instance_id = try reserveCacheInstance();
        const keys = try allocator.alloc([]f32, num_layers);
        errdefer allocator.free(keys);
        const values = try allocator.alloc([]f32, num_layers);
        errdefer allocator.free(values);

        for (keys, 0..) |*k, i| {
            k.* = try allocator.alloc(f32, ledger.row_elements);
            errdefer {
                for (keys[0..i]) |kk| allocator.free(kk);
            }
        }
        for (values, 0..) |*v, i| {
            v.* = try allocator.alloc(f32, ledger.row_elements);
            errdefer {
                for (values[0..i]) |vv| allocator.free(vv);
            }
        }

        return .{
            .allocator = allocator,
            .num_layers = num_layers,
            .dim = dim,
            .max_seq = max_seq,
            .keys = keys,
            .values = values,
            .ledger = ledger,
            .instance_id = instance_id,
        };
    }

    pub fn deinit(self: *KVCache) void {
        for (self.keys) |k| self.allocator.free(k);
        for (self.values) |v| self.allocator.free(v);
        self.allocator.free(self.keys);
        self.allocator.free(self.values);
    }

    /// Reset the cache to zero filled positions. Allocations are preserved
    /// so the cache can be reused across generations. Any provisional row
    /// transaction is fenced off; its copied tail is logically unreachable.
    pub fn reset(self: *KVCache) void {
        self.len = 0;
        self.active_row_txn = null;
    }

    pub fn logicalLedger(self: *const KVCache) LogicalLedger {
        return self.ledger;
    }

    /// True while a private row transaction owns the logical tail. Admission
    /// adapters use this read-only fence to reject pre-existing work instead
    /// of accidentally adopting another executor's provisional bytes.
    pub fn rowTxnActive(self: *const KVCache) bool {
        return self.active_row_txn != null;
    }

    /// Borrow the K rows for a given layer as a flat f32 slice covering
    /// `count` positions. Callers usually pass `len + 1` to include a row
    /// that was just appended but not yet committed.
    pub fn keysSliceCount(self: *KVCache, layer: usize, count: usize) []f32 {
        return self.keys[layer][0 .. count * self.dim];
    }

    pub fn valuesSliceCount(self: *KVCache, layer: usize, count: usize) []f32 {
        return self.values[layer][0 .. count * self.dim];
    }

    /// Append one K/V row at the next free position for `layer`. Returns
    /// the absolute position index where the row was written.
    pub fn appendRow(self: *KVCache, layer: usize, k_row: []const f32, v_row: []const f32) !usize {
        return self.appendRows(layer, k_row, v_row, 1);
    }

    /// Append a contiguous row-major K/V batch at the current logical end.
    /// The logical length is unchanged until `commitRows` is called after all
    /// layers have written the same positions.
    pub fn appendRows(
        self: *KVCache,
        layer: usize,
        k_rows: []const f32,
        v_rows: []const f32,
        count: usize,
    ) !usize {
        if (self.active_row_txn != null) return error.TransactionActive;
        return self.writeRowsAt(self.len, layer, k_rows, v_rows, count);
    }

    fn writeRowsAt(
        self: *KVCache,
        position: usize,
        layer: usize,
        k_rows: []const f32,
        v_rows: []const f32,
        count: usize,
    ) RowTxnError!usize {
        if (layer >= self.num_layers or count == 0) return error.ShapeMismatch;
        if (position > self.max_seq or count > self.max_seq - position)
            return error.CacheFull;
        const element_count = std.math.mul(usize, count, self.dim) catch
            return error.ShapeMismatch;
        if (k_rows.len != element_count or v_rows.len != element_count)
            return error.ShapeMismatch;
        const off = std.math.mul(usize, position, self.dim) catch
            return error.ShapeMismatch;
        const end = std.math.add(usize, off, element_count) catch
            return error.ShapeMismatch;
        if (end > self.ledger.row_elements) return error.ShapeMismatch;
        @memcpy(self.keys[layer][off..end], k_rows);
        @memcpy(self.values[layer][off..end], v_rows);
        return position;
    }

    /// Begin one bounded row transaction at the current logical end. Only one
    /// transaction may own a cache, and generations never wrap or reuse. The
    /// cache address must remain stable until this mark is committed/aborted;
    /// address binding prevents same-generation marks crossing cache objects.
    pub fn beginRows(
        self: *KVCache,
        count: usize,
    ) RowTxnError!RowTxnMark {
        if (self.active_row_txn != null) return error.TransactionActive;
        if (count == 0) return error.ShapeMismatch;
        if (count > self.max_seq -| self.len) return error.CacheFull;
        if (self.next_row_txn_generation == 0 or
            self.next_row_txn_generation == std.math.maxInt(u64))
            return error.GenerationExhausted;

        const generation = self.next_row_txn_generation;
        const cache_id = @intFromPtr(self);
        self.next_row_txn_generation += 1;
        self.active_row_txn = .{
            .cache_id = cache_id,
            .cache_instance = self.instance_id,
            .generation = generation,
            .base_len = self.len,
            .row_count = count,
        };
        return .{
            .cache_id = cache_id,
            .cache_instance = self.instance_id,
            .generation = generation,
            .base_len = self.len,
            .row_count = count,
        };
    }

    /// Write the next complete layer of a provisional row transaction.
    /// Requiring canonical layer order makes missing and duplicate layers
    /// reject before the logical cache cursor can advance.
    pub fn appendRowsTxn(
        self: *KVCache,
        mark: RowTxnMark,
        layer: usize,
        k_rows: []const f32,
        v_rows: []const f32,
    ) RowTxnError!usize {
        const active = try self.validateRowTxn(mark);
        if (layer != active.next_layer or layer >= self.num_layers)
            return error.InvalidTransaction;
        const position = try self.writeRowsAt(
            mark.base_len,
            layer,
            k_rows,
            v_rows,
            mark.row_count,
        );
        active.next_layer += 1;
        return position;
    }

    pub fn appendRowTxn(
        self: *KVCache,
        mark: RowTxnMark,
        layer: usize,
        k_row: []const f32,
        v_row: []const f32,
    ) RowTxnError!usize {
        if (mark.row_count != 1) return error.ShapeMismatch;
        return self.appendRowsTxn(mark, layer, k_row, v_row);
    }

    /// Validate every layer and capacity invariant without changing `len`.
    pub fn prepareCommit(
        self: *KVCache,
        mark: RowTxnMark,
    ) RowTxnError!PreparedRowCommit {
        const active = try self.validateRowTxn(mark);
        if (active.next_layer != self.num_layers)
            return error.TransactionIncomplete;
        const target = std.math.add(
            usize,
            mark.base_len,
            mark.row_count,
        ) catch return error.ShapeMismatch;
        if (target > self.max_seq) return error.CacheFull;
        return .{
            .cache_id = mark.cache_id,
            .cache_instance = mark.cache_instance,
            .generation = mark.generation,
            .base_len = mark.base_len,
            .row_count = mark.row_count,
            .target_len = target,
        };
    }

    /// Commit a token that was prepared against this unchanged request-local
    /// cache. This operation performs no allocation, callback or fallible work.
    pub fn commitPreparedAssumeValid(
        self: *KVCache,
        prepared: PreparedRowCommit,
    ) void {
        const active = self.active_row_txn orelse
            @panic("missing prepared KV row transaction");
        const target = std.math.add(
            usize,
            prepared.base_len,
            prepared.row_count,
        ) catch @panic("overflowed prepared KV row transaction");
        if (prepared.abi != row_txn_abi or
            prepared.cache_id != @intFromPtr(self) or
            prepared.cache_instance != self.instance_id or
            active.cache_id != prepared.cache_id or
            active.cache_instance != prepared.cache_instance or
            active.generation != prepared.generation or
            active.base_len != prepared.base_len or
            active.row_count != prepared.row_count or
            active.next_layer != self.num_layers or
            self.len != prepared.base_len or
            prepared.target_len != target or
            prepared.target_len > self.max_seq)
            @panic("invalid prepared KV row transaction");
        self.len = prepared.target_len;
        self.active_row_txn = null;
    }

    /// Abort a token already returned by `prepareCommit`. Like the matching
    /// commit operation, this is allocation-free and infallible after prepare;
    /// invariant violations are programming errors and therefore panic. Dirty
    /// tail bytes stay unreachable behind the unchanged logical cursor.
    pub fn abortPreparedAssumeValid(
        self: *KVCache,
        prepared: PreparedRowCommit,
    ) void {
        const active = self.active_row_txn orelse
            @panic("missing prepared KV row transaction");
        const target = std.math.add(
            usize,
            prepared.base_len,
            prepared.row_count,
        ) catch @panic("overflowed prepared KV row transaction");
        if (prepared.abi != row_txn_abi or
            prepared.cache_id != @intFromPtr(self) or
            prepared.cache_instance != self.instance_id or
            active.cache_id != prepared.cache_id or
            active.cache_instance != prepared.cache_instance or
            active.generation != prepared.generation or
            active.base_len != prepared.base_len or
            active.row_count != prepared.row_count or
            active.next_layer != self.num_layers or
            self.len != prepared.base_len or
            prepared.target_len != target or
            prepared.target_len > self.max_seq)
            @panic("invalid prepared KV row transaction");
        self.active_row_txn = null;
    }

    /// Checked convenience path for callers that do not need a multi-cache
    /// prepare barrier.
    pub fn commitRowsTxn(
        self: *KVCache,
        mark: RowTxnMark,
    ) RowTxnError!void {
        const prepared = try self.prepareCommit(mark);
        self.commitPreparedAssumeValid(prepared);
    }

    /// Abort a current mark. Dirty tail bytes remain private and will be
    /// overwritten by the next transaction at the unchanged logical cursor.
    pub fn abortRows(
        self: *KVCache,
        mark: RowTxnMark,
    ) RowTxnError!void {
        _ = try self.validateRowTxn(mark);
        self.active_row_txn = null;
    }

    fn validateRowTxn(
        self: *KVCache,
        mark: RowTxnMark,
    ) RowTxnError!*ActiveRowTxn {
        const active = if (self.active_row_txn) |*value|
            value
        else
            return error.InvalidTransaction;
        if (mark.abi != row_txn_abi or
            mark.cache_id != @intFromPtr(self) or
            mark.cache_instance != self.instance_id or
            active.cache_id != mark.cache_id or
            active.cache_instance != mark.cache_instance or
            active.generation != mark.generation or
            active.base_len != mark.base_len or
            active.row_count != mark.row_count or
            self.len != mark.base_len)
            return error.InvalidTransaction;
        return active;
    }

    /// Advance the filled-position counter after every layer has been
    /// updated for the new token. Call once per generated position.
    pub fn commit(self: *KVCache) void {
        self.commitRows(1);
    }

    pub fn commitRows(self: *KVCache, count: usize) void {
        if (self.active_row_txn != null)
            @panic("legacy KV commit cannot bypass an active row transaction");
        if (self.len > self.max_seq or count > self.max_seq - self.len)
            @panic("legacy KV commit exceeds cache capacity");
        self.len += count;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "KVCache init/deinit round-trip" {
    var cache = try KVCache.init(testing.allocator, 4, 16, 32);
    defer cache.deinit();
    try testing.expectEqual(@as(usize, 4), cache.num_layers);
    try testing.expectEqual(@as(usize, 16), cache.dim);
    try testing.expectEqual(@as(usize, 32), cache.max_seq);
    try testing.expectEqual(@as(usize, 0), cache.len);
}

test "KVCache reset preserves allocations" {
    var cache = try KVCache.init(testing.allocator, 2, 8, 16);
    defer cache.deinit();
    cache.len = 5;
    cache.reset();
    try testing.expectEqual(@as(usize, 0), cache.len);
    // The buffers should still be valid for writes.
    cache.keys[0][0] = 1.0;
    try testing.expectEqual(@as(f32, 1.0), cache.keys[0][0]);
}

test "KVCache views reflect current length" {
    var cache = try KVCache.init(testing.allocator, 1, 4, 8);
    defer cache.deinit();
    cache.len = 3;
    const kslice = cache.keysSliceCount(0, 3);
    try testing.expectEqual(@as(usize, 3 * 4), kslice.len);
}

test "KVCache appendRow then commit advances length" {
    var cache = try KVCache.init(testing.allocator, 1, 4, 4);
    defer cache.deinit();
    const k = [_]f32{ 1, 2, 3, 4 };
    const v = [_]f32{ 5, 6, 7, 8 };
    const pos = try cache.appendRow(0, &k, &v);
    try testing.expectEqual(@as(usize, 0), pos);
    try testing.expectEqual(@as(usize, 0), cache.len); // not committed yet
    cache.commit();
    try testing.expectEqual(@as(usize, 1), cache.len);
    // Verify the row landed at position 0.
    try testing.expectEqual(@as(f32, 1), cache.keys[0][0]);
    try testing.expectEqual(@as(f32, 8), cache.values[0][3]);
}

test "KVCache bulk append writes each layer before one commit" {
    var cache = try KVCache.init(testing.allocator, 2, 2, 8);
    defer cache.deinit();
    const k0 = [_]f32{ 1, 2, 3, 4, 5, 6 };
    const v0 = [_]f32{ 7, 8, 9, 10, 11, 12 };
    const k1 = [_]f32{ 13, 14, 15, 16, 17, 18 };
    const v1 = [_]f32{ 19, 20, 21, 22, 23, 24 };
    try testing.expectEqual(@as(usize, 0), try cache.appendRows(0, &k0, &v0, 3));
    try testing.expectEqual(@as(usize, 0), try cache.appendRows(1, &k1, &v1, 3));
    try testing.expectEqual(@as(usize, 0), cache.len);
    cache.commitRows(3);
    try testing.expectEqual(@as(usize, 3), cache.len);
    try testing.expectEqualSlices(f32, &k1, cache.keysSliceCount(1, 3));
    try testing.expectEqualSlices(f32, &v0, cache.valuesSliceCount(0, 3));
}

test "KV row transaction abort hides partial tails and retry overwrites them" {
    var cache = try KVCache.init(testing.allocator, 2, 2, 4);
    defer cache.deinit();

    const prefix_k0 = [_]f32{ 1, 2 };
    const prefix_v0 = [_]f32{ 3, 4 };
    const prefix_k1 = [_]f32{ 5, 6 };
    const prefix_v1 = [_]f32{ 7, 8 };
    _ = try cache.appendRow(0, &prefix_k0, &prefix_v0);
    _ = try cache.appendRow(1, &prefix_k1, &prefix_v1);
    cache.commit();

    const first = try cache.beginRows(1);
    const dirty_k0 = [_]f32{ 11, 12 };
    const dirty_v0 = [_]f32{ 13, 14 };
    _ = try cache.appendRowTxn(first, 0, &dirty_k0, &dirty_v0);
    try testing.expectError(
        error.TransactionIncomplete,
        cache.prepareCommit(first),
    );
    try testing.expectError(
        error.InvalidTransaction,
        cache.appendRowTxn(first, 0, &dirty_k0, &dirty_v0),
    );
    try testing.expectError(
        error.TransactionActive,
        cache.appendRow(1, &dirty_k0, &dirty_v0),
    );
    try cache.abortRows(first);

    try testing.expectEqual(@as(usize, 1), cache.len);
    try testing.expectEqualSlices(f32, &prefix_k0, cache.keysSliceCount(0, 1));
    try testing.expectEqualSlices(f32, &prefix_v1, cache.valuesSliceCount(1, 1));
    try testing.expectEqualSlices(
        f32,
        &dirty_k0,
        cache.keys[0][2..4],
    );

    const second = try cache.beginRows(1);
    try testing.expect(second.generation != first.generation);
    const exact_k0 = [_]f32{ 21, 22 };
    const exact_v0 = [_]f32{ 23, 24 };
    const exact_k1 = [_]f32{ 25, 26 };
    const exact_v1 = [_]f32{ 27, 28 };
    _ = try cache.appendRowTxn(second, 0, &exact_k0, &exact_v0);
    _ = try cache.appendRowTxn(second, 1, &exact_k1, &exact_v1);
    const prepared = try cache.prepareCommit(second);
    try testing.expectEqual(@as(usize, 1), prepared.base_len);
    try testing.expectEqual(@as(usize, 2), prepared.target_len);
    cache.commitPreparedAssumeValid(prepared);

    try testing.expectEqual(@as(usize, 2), cache.len);
    try testing.expectEqualSlices(f32, &exact_k0, cache.keys[0][2..4]);
    try testing.expectEqualSlices(f32, &exact_v1, cache.values[1][2..4]);
    try testing.expectError(error.InvalidTransaction, cache.abortRows(second));
    try testing.expectError(error.InvalidTransaction, cache.commitRowsTxn(second));
    try testing.expectError(error.InvalidTransaction, cache.abortRows(first));
}

test "KV prepared row abort is infallible and preserves the logical prefix" {
    var cache = try KVCache.init(testing.allocator, 2, 2, 3);
    defer cache.deinit();

    const mark = try cache.beginRows(1);
    _ = try cache.appendRowTxn(mark, 0, &.{ 1, 2 }, &.{ 3, 4 });
    _ = try cache.appendRowTxn(mark, 1, &.{ 5, 6 }, &.{ 7, 8 });
    const prepared = try cache.prepareCommit(mark);
    try testing.expect(cache.rowTxnActive());
    cache.abortPreparedAssumeValid(prepared);

    try testing.expect(!cache.rowTxnActive());
    try testing.expectEqual(@as(usize, 0), cache.len);
    const retry = try cache.beginRows(1);
    try testing.expect(retry.generation != mark.generation);
    try cache.abortRows(retry);
}

test "KV row transaction validates bulk geometry fencing and reset" {
    var cache = try KVCache.init(testing.allocator, 2, 1, 4);
    defer cache.deinit();

    try testing.expectError(error.ShapeMismatch, cache.beginRows(0));
    const mark = try cache.beginRows(2);
    try testing.expectError(error.TransactionActive, cache.beginRows(1));
    try testing.expectError(
        error.ShapeMismatch,
        cache.appendRowsTxn(mark, 0, &.{1}, &.{2}),
    );
    _ = try cache.appendRowsTxn(mark, 0, &.{ 1, 2 }, &.{ 3, 4 });
    _ = try cache.appendRowsTxn(mark, 1, &.{ 5, 6 }, &.{ 7, 8 });
    try cache.commitRowsTxn(mark);
    try testing.expectEqual(@as(usize, 2), cache.len);

    const reset_mark = try cache.beginRows(1);
    _ = try cache.appendRowsTxn(reset_mark, 0, &.{9}, &.{10});
    cache.reset();
    try testing.expectEqual(@as(usize, 0), cache.len);
    try testing.expectError(
        error.InvalidTransaction,
        cache.abortRows(reset_mark),
    );

    cache.next_row_txn_generation = std.math.maxInt(u64);
    try testing.expectError(error.GenerationExhausted, cache.beginRows(1));
}

test "KV row transaction marks cannot cross identical cache objects" {
    var left = try KVCache.init(testing.allocator, 1, 1, 2);
    defer left.deinit();
    var right = try KVCache.init(testing.allocator, 1, 1, 2);
    defer right.deinit();

    const left_mark = try left.beginRows(1);
    const right_mark = try right.beginRows(1);
    try testing.expectEqual(left_mark.generation, right_mark.generation);
    try testing.expect(left_mark.cache_id != right_mark.cache_id);
    try testing.expectError(
        error.InvalidTransaction,
        left.appendRowTxn(right_mark, 0, &.{1}, &.{2}),
    );
    try testing.expectError(
        error.InvalidTransaction,
        right.appendRowTxn(left_mark, 0, &.{3}, &.{4}),
    );

    _ = try left.appendRowTxn(left_mark, 0, &.{5}, &.{6});
    _ = try right.appendRowTxn(right_mark, 0, &.{7}, &.{8});
    try left.commitRowsTxn(left_mark);
    try right.commitRowsTxn(right_mark);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqual(@as(usize, 1), right.len);
}

test "KV row transaction instance identity prevents address reuse ABA" {
    var cache = try KVCache.init(testing.allocator, 1, 1, 2);
    const stale = try cache.beginRows(1);
    cache.deinit();

    cache = try KVCache.init(testing.allocator, 1, 1, 2);
    defer cache.deinit();
    const current = try cache.beginRows(1);
    try testing.expectEqual(stale.cache_id, current.cache_id);
    try testing.expectEqual(stale.generation, current.generation);
    try testing.expect(stale.cache_instance != current.cache_instance);
    try testing.expectError(
        error.InvalidTransaction,
        cache.appendRowTxn(stale, 0, &.{1}, &.{2}),
    );
    _ = try cache.appendRowTxn(current, 0, &.{3}, &.{4});
    try cache.commitRowsTxn(current);
    try testing.expectEqual(@as(usize, 1), cache.len);
}

test "KVCache rejects append when full" {
    var cache = try KVCache.init(testing.allocator, 1, 2, 1);
    defer cache.deinit();
    const k = [_]f32{ 0, 0 };
    _ = try cache.appendRow(0, &k, &k);
    cache.commit();
    try testing.expectError(error.CacheFull, cache.appendRow(0, &k, &k));
}

test "KV logical ledger includes payload and outer descriptors" {
    const ledger = try deriveLogicalLedger(24, 128, 240);
    try testing.expectEqual(@as(usize, 30_720), ledger.row_elements);
    try testing.expectEqual(@as(usize, 5_898_240), ledger.tensor_payload_bytes);
    try testing.expectEqual(
        @as(usize, 48 * @sizeOf([]f32)),
        ledger.descriptor_bytes,
    );
    try testing.expectEqual(
        ledger.tensor_payload_bytes + ledger.descriptor_bytes,
        ledger.allocation_payload_bytes,
    );

    var cache = try KVCache.init(testing.allocator, 24, 128, 240);
    defer cache.deinit();
    try testing.expectEqualDeep(ledger, cache.logicalLedger());
}

test "KV logical ledger rejects zero and overflowing geometry" {
    try testing.expectError(
        TensorError.ShapeMismatch,
        deriveLogicalLedger(0, 128, 240),
    );
    try testing.expectError(
        TensorError.ShapeMismatch,
        deriveLogicalLedger(2, std.math.maxInt(usize), 2),
    );
}
