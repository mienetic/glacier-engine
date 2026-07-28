//! Canonical, allocation-free result wires for stateless tensor workloads.
//!
//! A batch map gives each input a non-zero application item ID. Its ordinal is
//! canonical and implicit in the item's position in the map. The fixed score
//! policy intentionally supports one ordering contract in V1: raw signed
//! scores, descending, with input ordinal as the ascending tie break.
//!
//! Ranked results have no framing bytes: they are exactly one 64-byte element
//! per batch-map item. Each element contains a 32-byte little-endian body and
//! a 32-byte SHA-256 root bound to that exact body, the canonical batch-map
//! root, and the canonical score-policy root. Consequently, callers must
//! supply both source wires when validating a result.

const std = @import("std");

pub const Digest = [32]u8;

pub const maximum_item_count: usize = 4096;
pub const ranked_element_bytes: usize = 64;
pub const ranked_element_body_bytes: usize = 32;

pub const batch_map_magic = [_]u8{ 'G', 'S', 'T', 'B', 'M', 'A', 'P', '1' };
pub const batch_map_abi: u64 = 0x4753_5442_4d00_0001;
pub const batch_map_header_bytes: usize = 32;
pub const batch_map_item_bytes: usize = 8;
pub const batch_map_footer_bytes: usize = 32;
pub const batch_map_minimum_bytes: usize =
    batch_map_header_bytes + batch_map_item_bytes + batch_map_footer_bytes;

pub const score_policy_magic =
    [_]u8{ 'G', 'S', 'T', 'P', 'O', 'L', '1', 0 };
pub const score_policy_abi: u64 = 0x4753_5450_4f00_0001;
pub const score_policy_bytes: usize = 88;

const batch_map_domain = "glacier-stateless-tensor-batch-map-v1\x00";
const score_policy_domain = "glacier-stateless-tensor-score-policy-v1\x00";
const ranked_element_domain =
    "glacier-stateless-tensor-ranked-element-v1\x00";

pub const Error = error{
    CapacityExceeded,
    InvalidStorage,
    InvalidLength,
    InvalidCount,
    InvalidMagic,
    InvalidAbi,
    InvalidReserved,
    InvalidRoot,
    InvalidItemId,
    DuplicateItemId,
    InvalidPolicy,
    InvalidRank,
    InvalidInputOrdinal,
    DuplicateInputOrdinal,
    ItemIdMismatch,
    InvalidOrdering,
    IndexOutOfBounds,
};

pub const NormalizationV1 = enum(u64) {
    none = 1,
    _,
};

pub const ScoreOrderV1 = enum(u64) {
    score_descending = 1,
    _,
};

pub const TieBreakV1 = enum(u64) {
    input_ordinal_ascending = 1,
    _,
};

pub const ScorePolicyV1 = struct {
    normalization: NormalizationV1 = .none,
    order: ScoreOrderV1 = .score_descending,
    tie_break: TieBreakV1 = .input_ordinal_ascending,
};

pub const canonical_score_policy_v1: ScorePolicyV1 = .{};

pub const RankedItemV1 = struct {
    item_id: u64,
    input_ordinal: u64,
    rank: u64,
    score: i64,
};

pub const BatchMapViewV1 = struct {
    encoded: []const u8,
    item_count: usize,
    batch_map_sha256: Digest,

    pub fn itemId(self: BatchMapViewV1, index: usize) Error!u64 {
        if (index >= self.item_count) return Error.IndexOutOfBounds;
        const offset = std.math.add(
            usize,
            batch_map_header_bytes,
            std.math.mul(usize, index, batch_map_item_bytes) catch
                return Error.InvalidLength,
        ) catch return Error.InvalidLength;
        const end = std.math.add(usize, offset, batch_map_item_bytes) catch
            return Error.InvalidLength;
        if (end > self.encoded.len) return Error.InvalidLength;
        return readU64(self.encoded, offset);
    }
};

pub const ScorePolicyViewV1 = struct {
    encoded: []const u8,
    policy: ScorePolicyV1,
    score_policy_sha256: Digest,
};

pub const RankedResultViewV1 = struct {
    encoded: []const u8,
    item_count: usize,
    batch_map_sha256: Digest,
    score_policy_sha256: Digest,

    pub fn item(
        self: RankedResultViewV1,
        index: usize,
    ) Error!RankedItemV1 {
        if (index >= self.item_count) return Error.IndexOutOfBounds;
        const offset = std.math.mul(
            usize,
            index,
            ranked_element_bytes,
        ) catch return Error.InvalidLength;
        const end = std.math.add(
            usize,
            offset,
            ranked_element_body_bytes,
        ) catch return Error.InvalidLength;
        if (end > self.encoded.len) return Error.InvalidLength;
        return readRankedItem(self.encoded[offset..end]);
    }
};

/// Returns the exact encoded byte count for a non-empty BatchMap V1.
pub fn batchMapEncodedSizeV1(item_count: usize) Error!usize {
    if (item_count == 0 or item_count > maximum_item_count)
        return Error.InvalidCount;
    const item_bytes = std.math.mul(
        usize,
        item_count,
        batch_map_item_bytes,
    ) catch return Error.InvalidLength;
    const with_items = std.math.add(
        usize,
        batch_map_header_bytes,
        item_bytes,
    ) catch return Error.InvalidLength;
    return std.math.add(
        usize,
        with_items,
        batch_map_footer_bytes,
    ) catch return Error.InvalidLength;
}

/// Returns the exact result size: N fixed 64-byte elements and no envelope.
pub fn rankedResultEncodedSizeV1(item_count: usize) Error!usize {
    if (item_count == 0 or item_count > maximum_item_count)
        return Error.InvalidCount;
    return std.math.mul(
        usize,
        item_count,
        ranked_element_bytes,
    ) catch return Error.InvalidLength;
}

/// Encodes a canonical position-to-item-ID map without allocating.
///
/// Every validation and capacity check completes before the destination is
/// touched. Input/output overlap is rejected so successful encoding cannot
/// mutate an unread item ID.
pub fn encodeBatchMapV1(
    item_ids: []const u64,
    destination: []u8,
) Error![]const u8 {
    try validateItemIds(item_ids);
    const needed = try batchMapEncodedSizeV1(item_ids.len);
    if (destination.len < needed) return Error.CapacityExceeded;
    const output = destination[0..needed];
    if (slicesOverlap(std.mem.sliceAsBytes(item_ids), output))
        return Error.InvalidStorage;

    @memcpy(output[0..batch_map_magic.len], &batch_map_magic);
    writeU64(output, 8, batch_map_abi);
    writeU64(output, 16, @intCast(needed));
    writeU64(output, 24, @intCast(item_ids.len));
    for (item_ids, 0..) |item_id, index| {
        writeU64(
            output,
            batch_map_header_bytes + index * batch_map_item_bytes,
            item_id,
        );
    }
    const root_offset = needed - batch_map_footer_bytes;
    const root = domainRoot(batch_map_domain, output[0..root_offset]);
    @memcpy(output[root_offset..needed], &root);
    return output;
}

/// Parses and fully validates a canonical BatchMap V1 without allocating.
pub fn decodeBatchMapV1(encoded: []const u8) Error!BatchMapViewV1 {
    if (encoded.len < batch_map_minimum_bytes) return Error.InvalidLength;
    if (!std.mem.eql(
        u8,
        encoded[0..batch_map_magic.len],
        &batch_map_magic,
    )) return Error.InvalidMagic;
    if (readU64(encoded, 8) != batch_map_abi) return Error.InvalidAbi;
    const declared_length = readU64(encoded, 16);
    if (declared_length != encoded.len) return Error.InvalidLength;
    const count_u64 = readU64(encoded, 24);
    if (count_u64 == 0 or count_u64 > maximum_item_count)
        return Error.InvalidCount;
    const item_count: usize = @intCast(count_u64);
    if (try batchMapEncodedSizeV1(item_count) != encoded.len)
        return Error.InvalidLength;

    const root_offset = encoded.len - batch_map_footer_bytes;
    const expected_root =
        domainRoot(batch_map_domain, encoded[0..root_offset]);
    if (!std.mem.eql(u8, &expected_root, encoded[root_offset..]))
        return Error.InvalidRoot;

    var index: usize = 0;
    while (index < item_count) : (index += 1) {
        const item_id = readU64(
            encoded,
            batch_map_header_bytes + index * batch_map_item_bytes,
        );
        if (item_id == 0) return Error.InvalidItemId;
        var previous: usize = 0;
        while (previous < index) : (previous += 1) {
            if (item_id == readU64(
                encoded,
                batch_map_header_bytes +
                    previous * batch_map_item_bytes,
            )) return Error.DuplicateItemId;
        }
    }

    return .{
        .encoded = encoded,
        .item_count = item_count,
        .batch_map_sha256 = expected_root,
    };
}

/// Encodes the single canonical ScorePolicy V1.
pub fn encodeScorePolicyV1(
    policy: ScorePolicyV1,
    destination: []u8,
) Error![]const u8 {
    if (!scorePolicyValidV1(policy)) return Error.InvalidPolicy;
    if (destination.len < score_policy_bytes)
        return Error.CapacityExceeded;
    const output = destination[0..score_policy_bytes];

    @memcpy(output[0..score_policy_magic.len], &score_policy_magic);
    writeU64(output, 8, score_policy_abi);
    writeU64(output, 16, score_policy_bytes);
    writeU64(output, 24, @intFromEnum(policy.normalization));
    writeU64(output, 32, @intFromEnum(policy.order));
    writeU64(output, 40, @intFromEnum(policy.tie_break));
    writeU64(output, 48, 0);
    const root = domainRoot(
        score_policy_domain,
        output[0 .. score_policy_bytes - @sizeOf(Digest)],
    );
    @memcpy(
        output[score_policy_bytes - @sizeOf(Digest) ..],
        &root,
    );
    return output;
}

/// Parses the fixed score policy and rejects all non-canonical variants.
pub fn decodeScorePolicyV1(
    encoded: []const u8,
) Error!ScorePolicyViewV1 {
    if (encoded.len != score_policy_bytes) return Error.InvalidLength;
    if (!std.mem.eql(
        u8,
        encoded[0..score_policy_magic.len],
        &score_policy_magic,
    )) return Error.InvalidMagic;
    if (readU64(encoded, 8) != score_policy_abi) return Error.InvalidAbi;
    if (readU64(encoded, 16) != score_policy_bytes)
        return Error.InvalidLength;
    if (readU64(encoded, 48) != 0) return Error.InvalidReserved;
    if (readU64(encoded, 24) !=
        @intFromEnum(NormalizationV1.none) or
        readU64(encoded, 32) !=
            @intFromEnum(ScoreOrderV1.score_descending) or
        readU64(encoded, 40) !=
            @intFromEnum(TieBreakV1.input_ordinal_ascending))
        return Error.InvalidPolicy;

    const root_offset = encoded.len - @sizeOf(Digest);
    const expected_root =
        domainRoot(score_policy_domain, encoded[0..root_offset]);
    if (!std.mem.eql(u8, &expected_root, encoded[root_offset..]))
        return Error.InvalidRoot;
    return .{
        .encoded = encoded,
        .policy = canonical_score_policy_v1,
        .score_policy_sha256 = expected_root,
    };
}

/// Encodes a ranked result after validating it against the supplied canonical
/// batch map and score policy. Validation completes before output is modified.
pub fn encodeRankedResultV1(
    encoded_batch_map: []const u8,
    encoded_score_policy: []const u8,
    ranked_items: []const RankedItemV1,
    destination: []u8,
) Error![]const u8 {
    const batch_map = try decodeBatchMapV1(encoded_batch_map);
    const score_policy = try decodeScorePolicyV1(encoded_score_policy);
    try validateRankedItems(batch_map, ranked_items);
    const needed = try rankedResultEncodedSizeV1(batch_map.item_count);
    if (destination.len < needed) return Error.CapacityExceeded;
    const output = destination[0..needed];
    if (slicesOverlap(encoded_batch_map, output) or
        slicesOverlap(encoded_score_policy, output) or
        slicesOverlap(std.mem.sliceAsBytes(ranked_items), output))
        return Error.InvalidStorage;

    for (ranked_items, 0..) |item, index| {
        const offset = index * ranked_element_bytes;
        writeRankedItem(output[offset .. offset + ranked_element_body_bytes], item);
        const root = rankedElementRoot(
            batch_map.batch_map_sha256,
            score_policy.score_policy_sha256,
            output[offset .. offset + ranked_element_body_bytes],
        );
        @memcpy(
            output[offset + ranked_element_body_bytes .. offset + ranked_element_bytes],
            &root,
        );
    }
    return output;
}

/// Validates every result-element root and the complete ranked permutation.
pub fn decodeAndVerifyRankedResultV1(
    encoded: []const u8,
    encoded_batch_map: []const u8,
    encoded_score_policy: []const u8,
) Error!RankedResultViewV1 {
    const batch_map = try decodeBatchMapV1(encoded_batch_map);
    const score_policy = try decodeScorePolicyV1(encoded_score_policy);
    const needed = try rankedResultEncodedSizeV1(batch_map.item_count);
    if (encoded.len != needed) return Error.InvalidLength;

    var index: usize = 0;
    while (index < batch_map.item_count) : (index += 1) {
        const offset = index * ranked_element_bytes;
        const body =
            encoded[offset .. offset + ranked_element_body_bytes];
        const expected_root = rankedElementRoot(
            batch_map.batch_map_sha256,
            score_policy.score_policy_sha256,
            body,
        );
        if (!std.mem.eql(
            u8,
            &expected_root,
            encoded[offset + ranked_element_body_bytes .. offset + ranked_element_bytes],
        )) return Error.InvalidRoot;
    }

    const view: RankedResultViewV1 = .{
        .encoded = encoded,
        .item_count = batch_map.item_count,
        .batch_map_sha256 = batch_map.batch_map_sha256,
        .score_policy_sha256 = score_policy.score_policy_sha256,
    };
    try validateRankedView(batch_map, view);
    return view;
}

fn validateItemIds(item_ids: []const u64) Error!void {
    if (item_ids.len == 0 or item_ids.len > maximum_item_count)
        return Error.InvalidCount;
    for (item_ids, 0..) |item_id, index| {
        if (item_id == 0) return Error.InvalidItemId;
        for (item_ids[0..index]) |previous| {
            if (item_id == previous) return Error.DuplicateItemId;
        }
    }
}

fn scorePolicyValidV1(policy: ScorePolicyV1) bool {
    return @intFromEnum(policy.normalization) ==
        @intFromEnum(NormalizationV1.none) and
        @intFromEnum(policy.order) ==
            @intFromEnum(ScoreOrderV1.score_descending) and
        @intFromEnum(policy.tie_break) ==
            @intFromEnum(TieBreakV1.input_ordinal_ascending);
}

fn validateRankedItems(
    batch_map: BatchMapViewV1,
    items: []const RankedItemV1,
) Error!void {
    if (items.len != batch_map.item_count) return Error.InvalidLength;
    for (items, 0..) |item, index| {
        try validateRankedItem(batch_map, items[0..index], item, index);
    }
}

fn validateRankedView(
    batch_map: BatchMapViewV1,
    view: RankedResultViewV1,
) Error!void {
    var index: usize = 0;
    while (index < view.item_count) : (index += 1) {
        const item = try view.item(index);
        var previous_index: usize = 0;
        while (previous_index < index) : (previous_index += 1) {
            const previous = try view.item(previous_index);
            if (previous.input_ordinal == item.input_ordinal)
                return Error.DuplicateInputOrdinal;
        }
        if (item.rank != index) return Error.InvalidRank;
        if (item.input_ordinal >= batch_map.item_count)
            return Error.InvalidInputOrdinal;
        const ordinal: usize = @intCast(item.input_ordinal);
        if (item.item_id == 0 or
            item.item_id != try batch_map.itemId(ordinal))
            return Error.ItemIdMismatch;
        if (index != 0) {
            const previous = try view.item(index - 1);
            try validatePairOrdering(previous, item);
        }
    }
}

fn validateRankedItem(
    batch_map: BatchMapViewV1,
    previous_items: []const RankedItemV1,
    item: RankedItemV1,
    index: usize,
) Error!void {
    if (item.rank != index) return Error.InvalidRank;
    if (item.input_ordinal >= batch_map.item_count)
        return Error.InvalidInputOrdinal;
    const ordinal: usize = @intCast(item.input_ordinal);
    if (item.item_id == 0 or
        item.item_id != try batch_map.itemId(ordinal))
        return Error.ItemIdMismatch;
    for (previous_items) |previous| {
        if (previous.input_ordinal == item.input_ordinal)
            return Error.DuplicateInputOrdinal;
    }
    if (previous_items.len != 0)
        try validatePairOrdering(previous_items[previous_items.len - 1], item);
}

fn validatePairOrdering(
    previous: RankedItemV1,
    current: RankedItemV1,
) Error!void {
    if (previous.score < current.score) return Error.InvalidOrdering;
    if (previous.score == current.score and
        previous.input_ordinal >= current.input_ordinal)
        return Error.InvalidOrdering;
}

fn rankedElementRoot(
    batch_map_sha256: Digest,
    score_policy_sha256: Digest,
    body: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(ranked_element_domain);
    hash.update(&batch_map_sha256);
    hash.update(&score_policy_sha256);
    hash.update(body);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn domainRoot(domain: []const u8, bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(bytes);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn writeRankedItem(output: []u8, item: RankedItemV1) void {
    writeU64(output, 0, item.item_id);
    writeU64(output, 8, item.input_ordinal);
    writeU64(output, 16, item.rank);
    std.mem.writeInt(i64, output[24..32], item.score, .little);
}

fn readRankedItem(input: []const u8) RankedItemV1 {
    return .{
        .item_id = readU64(input, 0),
        .input_ordinal = readU64(input, 8),
        .rank = readU64(input, 16),
        .score = std.mem.readInt(i64, input[24..32], .little),
    };
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, output[offset..][0..8], value, .little);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset..][0..8], .little);
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch
        return true;
    const right_end = std.math.add(usize, right_start, right.len) catch
        return true;
    return left_start < right_end and right_start < left_end;
}

fn resealBatchMapForTest(encoded: []u8) void {
    const root_offset = encoded.len - batch_map_footer_bytes;
    const root = domainRoot(batch_map_domain, encoded[0..root_offset]);
    @memcpy(encoded[root_offset..], &root);
}

fn resealScorePolicyForTest(encoded: []u8) void {
    const root_offset = encoded.len - @sizeOf(Digest);
    const root = domainRoot(score_policy_domain, encoded[0..root_offset]);
    @memcpy(encoded[root_offset..], &root);
}

fn resealRankedElementForTest(
    encoded: []u8,
    element_index: usize,
    batch_root: Digest,
    policy_root: Digest,
) void {
    const offset = element_index * ranked_element_bytes;
    const root = rankedElementRoot(
        batch_root,
        policy_root,
        encoded[offset .. offset + ranked_element_body_bytes],
    );
    @memcpy(
        encoded[offset + ranked_element_body_bytes .. offset + ranked_element_bytes],
        &root,
    );
}

fn expectBatchRejected(encoded: []const u8) !void {
    if (decodeBatchMapV1(encoded)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectPolicyRejected(encoded: []const u8) !void {
    if (decodeScorePolicyV1(encoded)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectResultRejected(
    encoded: []const u8,
    batch: []const u8,
    policy: []const u8,
) !void {
    if (decodeAndVerifyRankedResultV1(encoded, batch, policy)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "canonical tensor wires round trip and result is exactly N elements" {
    const ids = [_]u64{ 41, 7, 99, 5 };
    var batch_storage: [
        batch_map_header_bytes +
            ids.len * batch_map_item_bytes +
            batch_map_footer_bytes
    ]u8 = undefined;
    const batch = try encodeBatchMapV1(&ids, &batch_storage);
    const batch_view = try decodeBatchMapV1(batch);
    try std.testing.expectEqual(ids.len, batch_view.item_count);
    for (ids, 0..) |expected, index|
        try std.testing.expectEqual(expected, try batch_view.itemId(index));
    try std.testing.expectError(
        Error.IndexOutOfBounds,
        batch_view.itemId(ids.len),
    );

    var policy_storage: [score_policy_bytes]u8 = undefined;
    const policy = try encodeScorePolicyV1(
        canonical_score_policy_v1,
        &policy_storage,
    );
    const policy_view = try decodeScorePolicyV1(policy);
    try std.testing.expectEqual(
        NormalizationV1.none,
        policy_view.policy.normalization,
    );

    const ranked = [_]RankedItemV1{
        .{ .item_id = 7, .input_ordinal = 1, .rank = 0, .score = 20 },
        .{ .item_id = 41, .input_ordinal = 0, .rank = 1, .score = 10 },
        .{ .item_id = 99, .input_ordinal = 2, .rank = 2, .score = 10 },
        .{ .item_id = 5, .input_ordinal = 3, .rank = 3, .score = -2 },
    };
    var result_storage: [ids.len * ranked_element_bytes]u8 = undefined;
    const result = try encodeRankedResultV1(
        batch,
        policy,
        &ranked,
        &result_storage,
    );
    try std.testing.expectEqual(
        ids.len * ranked_element_bytes,
        result.len,
    );
    const result_view = try decodeAndVerifyRankedResultV1(
        result,
        batch,
        policy,
    );
    for (ranked, 0..) |expected, index| {
        try std.testing.expectEqualDeep(
            expected,
            try result_view.item(index),
        );
    }
    try std.testing.expectError(
        Error.IndexOutOfBounds,
        result_view.item(ids.len),
    );
}

test "every byte of each canonical tensor wire is authenticated" {
    const ids = [_]u64{ 1001, 2002, 3003 };
    var batch_storage: [
        batch_map_header_bytes +
            ids.len * batch_map_item_bytes +
            batch_map_footer_bytes
    ]u8 = undefined;
    const batch = try encodeBatchMapV1(&ids, &batch_storage);
    var policy_storage: [score_policy_bytes]u8 = undefined;
    const policy = try encodeScorePolicyV1(
        canonical_score_policy_v1,
        &policy_storage,
    );
    const ranked = [_]RankedItemV1{
        .{
            .item_id = 3003,
            .input_ordinal = 2,
            .rank = 0,
            .score = 17,
        },
        .{
            .item_id = 1001,
            .input_ordinal = 0,
            .rank = 1,
            .score = 11,
        },
        .{
            .item_id = 2002,
            .input_ordinal = 1,
            .rank = 2,
            .score = -9,
        },
    };
    var result_storage: [ids.len * ranked_element_bytes]u8 = undefined;
    const result = try encodeRankedResultV1(
        batch,
        policy,
        &ranked,
        &result_storage,
    );

    var mutated_batch = batch_storage;
    for (0..mutated_batch.len) |index| {
        mutated_batch[index] ^= 1;
        try expectBatchRejected(&mutated_batch);
        mutated_batch[index] ^= 1;
    }
    var mutated_policy = policy_storage;
    for (0..mutated_policy.len) |index| {
        mutated_policy[index] ^= 1;
        try expectPolicyRejected(&mutated_policy);
        mutated_policy[index] ^= 1;
    }
    var mutated_result = result_storage;
    for (0..mutated_result.len) |index| {
        mutated_result[index] ^= 1;
        try expectResultRejected(
            &mutated_result,
            batch,
            policy,
        );
        mutated_result[index] ^= 1;
    }
    _ = result;
}

test "all strict truncations are rejected" {
    const ids = [_]u64{ 8, 13 };
    var batch_storage: [
        batch_map_header_bytes +
            ids.len * batch_map_item_bytes +
            batch_map_footer_bytes
    ]u8 = undefined;
    const batch = try encodeBatchMapV1(&ids, &batch_storage);
    var policy_storage: [score_policy_bytes]u8 = undefined;
    const policy = try encodeScorePolicyV1(
        canonical_score_policy_v1,
        &policy_storage,
    );
    const ranked = [_]RankedItemV1{
        .{ .item_id = 13, .input_ordinal = 1, .rank = 0, .score = 2 },
        .{ .item_id = 8, .input_ordinal = 0, .rank = 1, .score = 1 },
    };
    var result_storage: [ids.len * ranked_element_bytes]u8 = undefined;
    const result = try encodeRankedResultV1(
        batch,
        policy,
        &ranked,
        &result_storage,
    );

    for (0..batch.len) |length|
        try expectBatchRejected(batch[0..length]);
    for (0..policy.len) |length|
        try expectPolicyRejected(policy[0..length]);
    for (0..result.len) |length|
        try expectResultRejected(result[0..length], batch, policy);
}

test "duplicate IDs and ordinals are rejected after semantic resealing" {
    const ids = [_]u64{ 71, 72, 73 };
    var untouched = [_]u8{0xa5} **
        (batch_map_header_bytes +
            ids.len * batch_map_item_bytes +
            batch_map_footer_bytes);
    const duplicate_ids = [_]u64{ 71, 71, 73 };
    try std.testing.expectError(
        Error.DuplicateItemId,
        encodeBatchMapV1(&duplicate_ids, &untouched),
    );
    for (untouched) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);

    var batch_storage: [
        batch_map_header_bytes +
            ids.len * batch_map_item_bytes +
            batch_map_footer_bytes
    ]u8 = undefined;
    const batch = try encodeBatchMapV1(&ids, &batch_storage);
    var forged_batch = batch_storage;
    writeU64(
        &forged_batch,
        batch_map_header_bytes + batch_map_item_bytes,
        ids[0],
    );
    resealBatchMapForTest(&forged_batch);
    try std.testing.expectError(
        Error.DuplicateItemId,
        decodeBatchMapV1(&forged_batch),
    );

    var policy_storage: [score_policy_bytes]u8 = undefined;
    const policy = try encodeScorePolicyV1(
        canonical_score_policy_v1,
        &policy_storage,
    );
    const ranked = [_]RankedItemV1{
        .{ .item_id = 71, .input_ordinal = 0, .rank = 0, .score = 9 },
        .{ .item_id = 72, .input_ordinal = 1, .rank = 1, .score = 8 },
        .{ .item_id = 73, .input_ordinal = 2, .rank = 2, .score = 7 },
    };
    var result_storage: [ids.len * ranked_element_bytes]u8 = undefined;
    _ = try encodeRankedResultV1(
        batch,
        policy,
        &ranked,
        &result_storage,
    );
    const batch_view = try decodeBatchMapV1(batch);
    const policy_view = try decodeScorePolicyV1(policy);
    var forged_result = result_storage;
    writeU64(
        forged_result[ranked_element_bytes..],
        0,
        ranked[0].item_id,
    );
    writeU64(
        forged_result[ranked_element_bytes..],
        8,
        ranked[0].input_ordinal,
    );
    resealRankedElementForTest(
        &forged_result,
        1,
        batch_view.batch_map_sha256,
        policy_view.score_policy_sha256,
    );
    try std.testing.expectError(
        Error.DuplicateInputOrdinal,
        decodeAndVerifyRankedResultV1(
            &forged_result,
            batch,
            policy,
        ),
    );
}

test "record reorder and noncanonical tie order are rejected" {
    const ids = [_]u64{ 11, 22, 33 };
    var batch_storage: [
        batch_map_header_bytes +
            ids.len * batch_map_item_bytes +
            batch_map_footer_bytes
    ]u8 = undefined;
    const batch = try encodeBatchMapV1(&ids, &batch_storage);
    var policy_storage: [score_policy_bytes]u8 = undefined;
    const policy = try encodeScorePolicyV1(
        canonical_score_policy_v1,
        &policy_storage,
    );
    const canonical = [_]RankedItemV1{
        .{ .item_id = 11, .input_ordinal = 0, .rank = 0, .score = 6 },
        .{ .item_id = 22, .input_ordinal = 1, .rank = 1, .score = 6 },
        .{ .item_id = 33, .input_ordinal = 2, .rank = 2, .score = 1 },
    };
    var result_storage: [ids.len * ranked_element_bytes]u8 = undefined;
    _ = try encodeRankedResultV1(
        batch,
        policy,
        &canonical,
        &result_storage,
    );

    var reordered = result_storage;
    var temporary: [ranked_element_bytes]u8 = undefined;
    @memcpy(&temporary, reordered[0..ranked_element_bytes]);
    @memcpy(
        reordered[0..ranked_element_bytes],
        reordered[ranked_element_bytes .. 2 * ranked_element_bytes],
    );
    @memcpy(
        reordered[ranked_element_bytes .. 2 * ranked_element_bytes],
        &temporary,
    );
    try std.testing.expectError(
        Error.InvalidRank,
        decodeAndVerifyRankedResultV1(&reordered, batch, policy),
    );

    const reversed_tie = [_]RankedItemV1{
        .{ .item_id = 22, .input_ordinal = 1, .rank = 0, .score = 6 },
        .{ .item_id = 11, .input_ordinal = 0, .rank = 1, .score = 6 },
        .{ .item_id = 33, .input_ordinal = 2, .rank = 2, .score = 1 },
    };
    var untouched = [_]u8{0x3c} ** result_storage.len;
    try std.testing.expectError(
        Error.InvalidOrdering,
        encodeRankedResultV1(
            batch,
            policy,
            &reversed_tie,
            &untouched,
        ),
    );
    for (untouched) |byte| try std.testing.expectEqual(@as(u8, 0x3c), byte);
}

test "invalid policy and capacity failures leave output unchanged" {
    var invalid_policy = canonical_score_policy_v1;
    invalid_policy.normalization = @enumFromInt(2);
    var policy_output = [_]u8{0x7e} ** score_policy_bytes;
    try std.testing.expectError(
        Error.InvalidPolicy,
        encodeScorePolicyV1(invalid_policy, &policy_output),
    );
    for (policy_output) |byte|
        try std.testing.expectEqual(@as(u8, 0x7e), byte);

    var valid_policy: [score_policy_bytes]u8 = undefined;
    _ = try encodeScorePolicyV1(
        canonical_score_policy_v1,
        &valid_policy,
    );
    var forged_policy = valid_policy;
    writeU64(&forged_policy, 24, 2);
    resealScorePolicyForTest(&forged_policy);
    try std.testing.expectError(
        Error.InvalidPolicy,
        decodeScorePolicyV1(&forged_policy),
    );

    const ids = [_]u64{ 1, 2 };
    var short_batch = [_]u8{0x55} **
        (batch_map_header_bytes +
            ids.len * batch_map_item_bytes +
            batch_map_footer_bytes - 1);
    try std.testing.expectError(
        Error.CapacityExceeded,
        encodeBatchMapV1(&ids, &short_batch),
    );
    for (short_batch) |byte|
        try std.testing.expectEqual(@as(u8, 0x55), byte);
}
