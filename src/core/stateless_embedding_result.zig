//! Canonical, allocation-free normalized embeddings for stateless workloads.
//!
//! EmbeddingPolicy V1 fixes one portable numerical contract: signed i32
//! components in Q30, exact L2 normalization by squared-threshold comparison,
//! round-to-nearest with ties to even, and rejection of zero vectors.
//!
//! An encoded embedding matrix contains no framing or footer. It is exactly
//! `item_count * dimensions` little-endian i32 components in row-major order.
//! The separately computed matrix root binds those bytes to the canonical
//! batch-map root, embedding-policy root, and matrix shape.

const std = @import("std");

pub const Digest = [32]u8;

pub const maximum_embedding_item_count: usize = 4096;
pub const maximum_embedding_dimensions: usize = 4096;
pub const embedding_component_bytes: usize = @sizeOf(i32);

pub const embedding_policy_magic =
    [_]u8{ 'G', 'S', 'T', 'E', 'M', 'B', '1', 0 };
pub const embedding_policy_abi: u64 = 0x4753_5445_4d00_0001;
pub const embedding_policy_bytes: usize = 112;
pub const embedding_policy_root_offset: usize = 80;

pub const q30_scale: i32 = 1 << 30;

const embedding_policy_domain =
    "glacier-stateless-embedding-policy-v1\x00";
const embedding_matrix_domain =
    "glacier-stateless-embedding-matrix-v1\x00";

pub const Error = error{
    CapacityExceeded,
    InvalidStorage,
    InvalidLength,
    InvalidCount,
    InvalidDimensions,
    InvalidShape,
    InvalidMagic,
    InvalidAbi,
    InvalidReserved,
    InvalidRoot,
    InvalidPolicy,
    InvalidComponent,
    ZeroVector,
    ArithmeticOverflow,
    IndexOutOfBounds,
};

pub const EmbeddingNormalizationV1 = enum(u64) {
    q30_l2 = 1,
    _,
};

pub const EmbeddingComponentFormatV1 = enum(u64) {
    signed_i32_le = 1,
    _,
};

pub const EmbeddingNormAlgorithmV1 = enum(u64) {
    exact_squared_threshold = 1,
    _,
};

pub const EmbeddingRoundingV1 = enum(u64) {
    nearest_ties_to_even = 1,
    _,
};

pub const EmbeddingZeroVectorPolicyV1 = enum(u64) {
    reject = 1,
    _,
};

pub const EmbeddingPolicyV1 = struct {
    normalization: EmbeddingNormalizationV1 = .q30_l2,
    component_format: EmbeddingComponentFormatV1 = .signed_i32_le,
    norm_algorithm: EmbeddingNormAlgorithmV1 = .exact_squared_threshold,
    rounding: EmbeddingRoundingV1 = .nearest_ties_to_even,
    zero_vector: EmbeddingZeroVectorPolicyV1 = .reject,
    scale: u64 = @intCast(q30_scale),
};

pub const canonical_embedding_policy_v1: EmbeddingPolicyV1 = .{};

pub const EmbeddingPolicyViewV1 = struct {
    encoded: []const u8,
    policy: EmbeddingPolicyV1,
    embedding_policy_sha256: Digest,
};

pub const NormalizedEmbeddingViewV1 = struct {
    encoded: []const u8,
    item_count: usize,
    dimensions: usize,
    batch_map_sha256: Digest,
    embedding_policy_sha256: Digest,
    embedding_matrix_sha256: Digest,

    pub fn component(
        self: NormalizedEmbeddingViewV1,
        item_index: usize,
        dimension_index: usize,
    ) Error!i32 {
        if (item_index >= self.item_count or
            dimension_index >= self.dimensions)
            return Error.IndexOutOfBounds;
        const linear_index = std.math.add(
            usize,
            std.math.mul(
                usize,
                item_index,
                self.dimensions,
            ) catch return Error.InvalidLength,
            dimension_index,
        ) catch return Error.InvalidLength;
        const offset = std.math.mul(
            usize,
            linear_index,
            embedding_component_bytes,
        ) catch return Error.InvalidLength;
        const end = std.math.add(
            usize,
            offset,
            embedding_component_bytes,
        ) catch return Error.InvalidLength;
        if (end > self.encoded.len) return Error.InvalidLength;
        return std.mem.readInt(
            i32,
            self.encoded[offset..][0..embedding_component_bytes],
            .little,
        );
    }
};

/// Encodes the single canonical EmbeddingPolicy V1.
///
/// Policy validation and capacity checks complete before the destination is
/// touched.
pub fn encodeEmbeddingPolicyV1(
    policy: EmbeddingPolicyV1,
    destination: []u8,
) Error![]const u8 {
    if (!embeddingPolicyValidV1(policy)) return Error.InvalidPolicy;
    if (destination.len < embedding_policy_bytes)
        return Error.CapacityExceeded;
    const output = destination[0..embedding_policy_bytes];

    @memcpy(
        output[0..embedding_policy_magic.len],
        &embedding_policy_magic,
    );
    writeU64(output, 8, embedding_policy_abi);
    writeU64(output, 16, embedding_policy_bytes);
    writeU64(output, 24, @intFromEnum(policy.normalization));
    writeU64(output, 32, @intFromEnum(policy.component_format));
    writeU64(output, 40, @intFromEnum(policy.norm_algorithm));
    writeU64(output, 48, @intFromEnum(policy.rounding));
    writeU64(output, 56, @intFromEnum(policy.zero_vector));
    writeU64(output, 64, policy.scale);
    writeU64(output, 72, 0);
    const root = domainRoot(
        embedding_policy_domain,
        output[0..embedding_policy_root_offset],
    );
    @memcpy(output[embedding_policy_root_offset..], &root);
    return output;
}

/// Parses and authenticates the fixed canonical EmbeddingPolicy V1.
pub fn decodeEmbeddingPolicyV1(
    encoded: []const u8,
) Error!EmbeddingPolicyViewV1 {
    if (encoded.len != embedding_policy_bytes) return Error.InvalidLength;
    if (!std.mem.eql(
        u8,
        encoded[0..embedding_policy_magic.len],
        &embedding_policy_magic,
    )) return Error.InvalidMagic;
    if (readU64(encoded, 8) != embedding_policy_abi)
        return Error.InvalidAbi;
    if (readU64(encoded, 16) != embedding_policy_bytes)
        return Error.InvalidLength;
    if (readU64(encoded, 72) != 0) return Error.InvalidReserved;
    if (readU64(encoded, 24) !=
        @intFromEnum(EmbeddingNormalizationV1.q30_l2) or
        readU64(encoded, 32) !=
            @intFromEnum(EmbeddingComponentFormatV1.signed_i32_le) or
        readU64(encoded, 40) !=
            @intFromEnum(
                EmbeddingNormAlgorithmV1.exact_squared_threshold,
            ) or
        readU64(encoded, 48) !=
            @intFromEnum(EmbeddingRoundingV1.nearest_ties_to_even) or
        readU64(encoded, 56) !=
            @intFromEnum(EmbeddingZeroVectorPolicyV1.reject) or
        readU64(encoded, 64) != @as(u64, @intCast(q30_scale)))
        return Error.InvalidPolicy;

    const expected_root = domainRoot(
        embedding_policy_domain,
        encoded[0..embedding_policy_root_offset],
    );
    if (!std.mem.eql(
        u8,
        &expected_root,
        encoded[embedding_policy_root_offset..],
    )) return Error.InvalidRoot;
    return .{
        .encoded = encoded,
        .policy = canonical_embedding_policy_v1,
        .embedding_policy_sha256 = expected_root,
    };
}

/// Returns the exact compact row-major matrix byte count.
pub fn normalizedEmbeddingEncodedSizeV1(
    item_count: usize,
    dimensions: usize,
) Error!usize {
    try validateShapeBounds(item_count, dimensions);
    const component_count = std.math.mul(
        usize,
        item_count,
        dimensions,
    ) catch return Error.ArithmeticOverflow;
    return std.math.mul(
        usize,
        component_count,
        embedding_component_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Exactly L2-normalizes row-major signed i64 values into signed Q30 i32.
///
/// For a magnitude `a` and squared row norm `s`, the selected magnitude is
/// the nearest integer to `a * 2^30 / sqrt(s)`. The implementation never
/// computes a square root: it binary-searches the largest `y` satisfying
/// `y^2 * s <= a^2 * 2^60`, then performs an exact squared midpoint
/// comparison. Midpoint equality rounds to an even `y`.
///
/// All validation, zero-row detection, and overlap checks finish before any
/// destination element is modified.
pub fn normalizeQ30L2V1(
    raw_values: []const i64,
    item_count: usize,
    dimensions: usize,
    destination: []i32,
) Error![]const i32 {
    const component_count = try validatedComponentCount(
        raw_values.len,
        item_count,
        dimensions,
    );
    if (destination.len < component_count) return Error.CapacityExceeded;
    const output = destination[0..component_count];
    if (slicesOverlap(
        std.mem.sliceAsBytes(raw_values),
        std.mem.sliceAsBytes(output),
    )) return Error.InvalidStorage;

    var item_index: usize = 0;
    while (item_index < item_count) : (item_index += 1) {
        const row_offset = item_index * dimensions;
        _ = try rowSumSquares(
            raw_values[row_offset .. row_offset + dimensions],
        );
    }

    item_index = 0;
    while (item_index < item_count) : (item_index += 1) {
        const row_offset = item_index * dimensions;
        const row = raw_values[row_offset .. row_offset + dimensions];
        const sum_squares = try rowSumSquares(row);
        for (row, 0..) |raw, dimension_index| {
            const magnitude = try roundedMagnitudeQ30(
                magnitudeI64(raw),
                sum_squares,
            );
            const signed: i32 = @intCast(magnitude);
            output[row_offset + dimension_index] =
                if (raw < 0) -signed else signed;
        }
    }
    return output;
}

/// Encodes an already normalized matrix as compact little-endian i32 values.
///
/// Shape, component, zero-row, capacity, and overlap validation completes
/// before the destination is modified.
pub fn encodeNormalizedEmbeddingV1(
    components: []const i32,
    item_count: usize,
    dimensions: usize,
    destination: []u8,
) Error![]const u8 {
    const component_count = try validatedComponentCount(
        components.len,
        item_count,
        dimensions,
    );
    try validateComponents(components, item_count, dimensions);
    const needed = try normalizedEmbeddingEncodedSizeV1(
        item_count,
        dimensions,
    );
    if (destination.len < needed) return Error.CapacityExceeded;
    const output = destination[0..needed];
    if (slicesOverlap(
        std.mem.sliceAsBytes(components[0..component_count]),
        output,
    )) return Error.InvalidStorage;

    for (components, 0..) |component_value, index| {
        const offset = index * embedding_component_bytes;
        std.mem.writeInt(
            i32,
            output[offset..][0..embedding_component_bytes],
            component_value,
            .little,
        );
    }
    return output;
}

/// Parses a compact matrix, validates its canonical policy constraints, and
/// returns an immutable view plus its source-bound matrix root.
pub fn decodeAndValidateNormalizedEmbeddingV1(
    encoded: []const u8,
    batch_map_sha256: Digest,
    encoded_embedding_policy: []const u8,
    item_count: usize,
    dimensions: usize,
) Error!NormalizedEmbeddingViewV1 {
    const policy = try decodeEmbeddingPolicyV1(
        encoded_embedding_policy,
    );
    const needed = try normalizedEmbeddingEncodedSizeV1(
        item_count,
        dimensions,
    );
    if (encoded.len != needed) return Error.InvalidLength;
    try validateEncodedComponents(encoded, item_count, dimensions);
    const matrix_root = try embeddingMatrixSha256V1(
        batch_map_sha256,
        policy.embedding_policy_sha256,
        item_count,
        dimensions,
        encoded,
    );
    return .{
        .encoded = encoded,
        .item_count = item_count,
        .dimensions = dimensions,
        .batch_map_sha256 = batch_map_sha256,
        .embedding_policy_sha256 = policy.embedding_policy_sha256,
        .embedding_matrix_sha256 = matrix_root,
    };
}

/// Computes the domain-separated root of one exact compact matrix.
pub fn embeddingMatrixSha256V1(
    batch_map_sha256: Digest,
    embedding_policy_sha256: Digest,
    item_count: usize,
    dimensions: usize,
    encoded: []const u8,
) Error!Digest {
    const needed = try normalizedEmbeddingEncodedSizeV1(
        item_count,
        dimensions,
    );
    if (encoded.len != needed) return Error.InvalidLength;

    var item_count_le: [8]u8 = undefined;
    var dimensions_le: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &item_count_le,
        @intCast(item_count),
        .little,
    );
    std.mem.writeInt(
        u64,
        &dimensions_le,
        @intCast(dimensions),
        .little,
    );
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(embedding_matrix_domain);
    hash.update(&batch_map_sha256);
    hash.update(&embedding_policy_sha256);
    hash.update(&item_count_le);
    hash.update(&dimensions_le);
    hash.update(encoded);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn embeddingPolicyValidV1(policy: EmbeddingPolicyV1) bool {
    return @intFromEnum(policy.normalization) ==
        @intFromEnum(EmbeddingNormalizationV1.q30_l2) and
        @intFromEnum(policy.component_format) ==
            @intFromEnum(EmbeddingComponentFormatV1.signed_i32_le) and
        @intFromEnum(policy.norm_algorithm) ==
            @intFromEnum(
                EmbeddingNormAlgorithmV1.exact_squared_threshold,
            ) and
        @intFromEnum(policy.rounding) ==
            @intFromEnum(EmbeddingRoundingV1.nearest_ties_to_even) and
        @intFromEnum(policy.zero_vector) ==
            @intFromEnum(EmbeddingZeroVectorPolicyV1.reject) and
        policy.scale == @as(u64, @intCast(q30_scale));
}

fn validateShapeBounds(
    item_count: usize,
    dimensions: usize,
) Error!void {
    if (item_count == 0 or
        item_count > maximum_embedding_item_count)
        return Error.InvalidCount;
    if (dimensions == 0 or
        dimensions > maximum_embedding_dimensions)
        return Error.InvalidDimensions;
}

fn validatedComponentCount(
    actual_count: usize,
    item_count: usize,
    dimensions: usize,
) Error!usize {
    try validateShapeBounds(item_count, dimensions);
    const expected_count = std.math.mul(
        usize,
        item_count,
        dimensions,
    ) catch return Error.ArithmeticOverflow;
    if (actual_count != expected_count) return Error.InvalidShape;
    return expected_count;
}

fn rowSumSquares(row: []const i64) Error!u256 {
    var sum: u256 = 0;
    for (row) |value| {
        const magnitude: u256 = magnitudeI64(value);
        const square = std.math.mul(
            u256,
            magnitude,
            magnitude,
        ) catch return Error.ArithmeticOverflow;
        sum = std.math.add(
            u256,
            sum,
            square,
        ) catch return Error.ArithmeticOverflow;
    }
    if (sum == 0) return Error.ZeroVector;
    return sum;
}

fn roundedMagnitudeQ30(
    magnitude: u64,
    sum_squares: u256,
) Error!u32 {
    if (sum_squares == 0) return Error.ZeroVector;
    const scale: u256 = @intCast(q30_scale);
    const magnitude_wide: u256 = magnitude;
    const magnitude_squared = std.math.mul(
        u256,
        magnitude_wide,
        magnitude_wide,
    ) catch return Error.ArithmeticOverflow;
    const scale_squared = std.math.mul(
        u256,
        scale,
        scale,
    ) catch return Error.ArithmeticOverflow;
    const target = std.math.mul(
        u256,
        magnitude_squared,
        scale_squared,
    ) catch return Error.ArithmeticOverflow;

    var low: u64 = 0;
    var high: u64 = @intCast(q30_scale);
    while (low < high) {
        const midpoint = low + (high - low + 1) / 2;
        const midpoint_wide: u256 = midpoint;
        const midpoint_squared = std.math.mul(
            u256,
            midpoint_wide,
            midpoint_wide,
        ) catch return Error.ArithmeticOverflow;
        const threshold = std.math.mul(
            u256,
            midpoint_squared,
            sum_squares,
        ) catch return Error.ArithmeticOverflow;
        if (threshold <= target) {
            low = midpoint;
        } else {
            high = midpoint - 1;
        }
    }

    if (low == @as(u64, @intCast(q30_scale)))
        return @intCast(low);

    const twice_low_plus_one: u256 =
        @as(u256, low) * 2 + 1;
    const midpoint_squared = std.math.mul(
        u256,
        twice_low_plus_one,
        twice_low_plus_one,
    ) catch return Error.ArithmeticOverflow;
    const midpoint_left = std.math.mul(
        u256,
        midpoint_squared,
        sum_squares,
    ) catch return Error.ArithmeticOverflow;
    const midpoint_right = std.math.mul(
        u256,
        target,
        4,
    ) catch return Error.ArithmeticOverflow;
    if (midpoint_left < midpoint_right or
        (midpoint_left == midpoint_right and (low & 1) == 1))
        low += 1;
    return @intCast(low);
}

fn magnitudeI64(value: i64) u64 {
    if (value >= 0) return @intCast(value);
    return @intCast(-@as(i128, value));
}

fn validateComponents(
    components: []const i32,
    item_count: usize,
    dimensions: usize,
) Error!void {
    _ = try validatedComponentCount(
        components.len,
        item_count,
        dimensions,
    );
    var item_index: usize = 0;
    while (item_index < item_count) : (item_index += 1) {
        const row_offset = item_index * dimensions;
        var nonzero = false;
        for (components[row_offset .. row_offset + dimensions]) |value| {
            const magnitude: u64 = if (value >= 0)
                @intCast(value)
            else
                @intCast(-@as(i64, value));
            if (magnitude > @as(u64, @intCast(q30_scale)))
                return Error.InvalidComponent;
            nonzero = nonzero or value != 0;
        }
        if (!nonzero) return Error.ZeroVector;
    }
}

fn validateEncodedComponents(
    encoded: []const u8,
    item_count: usize,
    dimensions: usize,
) Error!void {
    const needed = try normalizedEmbeddingEncodedSizeV1(
        item_count,
        dimensions,
    );
    if (encoded.len != needed) return Error.InvalidLength;
    var item_index: usize = 0;
    while (item_index < item_count) : (item_index += 1) {
        var nonzero = false;
        var dimension_index: usize = 0;
        while (dimension_index < dimensions) : (dimension_index += 1) {
            const linear_index = item_index * dimensions +
                dimension_index;
            const offset = linear_index * embedding_component_bytes;
            const value = std.mem.readInt(
                i32,
                encoded[offset..][0..embedding_component_bytes],
                .little,
            );
            const magnitude: u64 = if (value >= 0)
                @intCast(value)
            else
                @intCast(-@as(i64, value));
            if (magnitude > @as(u64, @intCast(q30_scale)))
                return Error.InvalidComponent;
            nonzero = nonzero or value != 0;
        }
        if (!nonzero) return Error.ZeroVector;
    }
}

fn domainRoot(domain: []const u8, bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(bytes);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
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

fn resealPolicyForTest(encoded: []u8) void {
    const root = domainRoot(
        embedding_policy_domain,
        encoded[0..embedding_policy_root_offset],
    );
    @memcpy(encoded[embedding_policy_root_offset..], &root);
}

fn expectPolicyRejected(encoded: []const u8) !void {
    if (decodeEmbeddingPolicyV1(encoded)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectMatrixRejected(
    encoded: []const u8,
    batch_root: Digest,
    policy: []const u8,
    item_count: usize,
    dimensions: usize,
) !void {
    if (decodeAndValidateNormalizedEmbeddingV1(
        encoded,
        batch_root,
        policy,
        item_count,
        dimensions,
    )) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "embedding policy has one authenticated canonical wire" {
    var storage: [embedding_policy_bytes]u8 = undefined;
    const encoded = try encodeEmbeddingPolicyV1(
        canonical_embedding_policy_v1,
        &storage,
    );
    const view = try decodeEmbeddingPolicyV1(encoded);
    try std.testing.expectEqual(
        EmbeddingNormalizationV1.q30_l2,
        view.policy.normalization,
    );
    try std.testing.expectEqual(
        EmbeddingComponentFormatV1.signed_i32_le,
        view.policy.component_format,
    );
    try std.testing.expectEqual(
        EmbeddingNormAlgorithmV1.exact_squared_threshold,
        view.policy.norm_algorithm,
    );
    try std.testing.expectEqual(
        EmbeddingRoundingV1.nearest_ties_to_even,
        view.policy.rounding,
    );
    try std.testing.expectEqual(
        EmbeddingZeroVectorPolicyV1.reject,
        view.policy.zero_vector,
    );
    try std.testing.expectEqual(
        @as(u64, @intCast(q30_scale)),
        view.policy.scale,
    );

    var mutated = storage;
    for (0..mutated.len) |index| {
        mutated[index] ^= 1;
        try expectPolicyRejected(&mutated);
        mutated[index] ^= 1;
    }
    for (0..encoded.len) |length|
        try expectPolicyRejected(encoded[0..length]);
}

test "semantic policy variants fail even after resealing" {
    var storage: [embedding_policy_bytes]u8 = undefined;
    _ = try encodeEmbeddingPolicyV1(
        canonical_embedding_policy_v1,
        &storage,
    );

    var forged = storage;
    writeU64(&forged, 72, 1);
    resealPolicyForTest(&forged);
    try std.testing.expectError(
        Error.InvalidReserved,
        decodeEmbeddingPolicyV1(&forged),
    );

    forged = storage;
    writeU64(&forged, 40, 2);
    resealPolicyForTest(&forged);
    try std.testing.expectError(
        Error.InvalidPolicy,
        decodeEmbeddingPolicyV1(&forged),
    );

    var invalid = canonical_embedding_policy_v1;
    invalid.rounding = @enumFromInt(2);
    var untouched = [_]u8{0x7d} ** embedding_policy_bytes;
    try std.testing.expectError(
        Error.InvalidPolicy,
        encodeEmbeddingPolicyV1(invalid, &untouched),
    );
    for (untouched) |byte|
        try std.testing.expectEqual(@as(u8, 0x7d), byte);

    var short = [_]u8{0x36} ** (embedding_policy_bytes - 1);
    try std.testing.expectError(
        Error.CapacityExceeded,
        encodeEmbeddingPolicyV1(
            canonical_embedding_policy_v1,
            &short,
        ),
    );
    for (short) |byte|
        try std.testing.expectEqual(@as(u8, 0x36), byte);
}

test "exact Q30 normalization covers axes signs and rational norms" {
    const raw = [_]i64{
        7,  0,
        0,  -9,
        -3, 4,
    };
    var output: [raw.len]i32 = undefined;
    const normalized = try normalizeQ30L2V1(
        &raw,
        3,
        2,
        &output,
    );
    const expected = [_]i32{
        q30_scale,
        0,
        0,
        -q30_scale,
        -644_245_094,
        858_993_459,
    };
    try std.testing.expectEqualSlices(i32, &expected, normalized);

    var repeated: [raw.len]i32 = undefined;
    const normalized_again = try normalizeQ30L2V1(
        &raw,
        3,
        2,
        &repeated,
    );
    try std.testing.expectEqualSlices(
        i32,
        normalized,
        normalized_again,
    );
}

test "exact squared midpoint uses ties to even" {
    const scale: u256 = @intCast(q30_scale);
    const synthetic_sum = 4 * scale * scale;
    try std.testing.expectEqual(
        @as(u32, 0),
        try roundedMagnitudeQ30(1, synthetic_sum),
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        try roundedMagnitudeQ30(3, synthetic_sum),
    );
}

test "normalization failures leave the destination unchanged" {
    const raw = [_]i64{ 3, 4, 0, 0 };
    var untouched = [_]i32{0x1357_2468} ** raw.len;
    try std.testing.expectError(
        Error.ZeroVector,
        normalizeQ30L2V1(&raw, 2, 2, &untouched),
    );
    for (untouched) |value|
        try std.testing.expectEqual(@as(i32, 0x1357_2468), value);

    const valid = [_]i64{ 3, 4 };
    try std.testing.expectError(
        Error.InvalidShape,
        normalizeQ30L2V1(&valid, 1, 3, &untouched),
    );
    for (untouched) |value|
        try std.testing.expectEqual(@as(i32, 0x1357_2468), value);

    var short = [_]i32{0x1234_5678};
    try std.testing.expectError(
        Error.CapacityExceeded,
        normalizeQ30L2V1(&valid, 1, 2, &short),
    );
    try std.testing.expectEqual(@as(i32, 0x1234_5678), short[0]);

    var aliased = [_]i64{ 3, 4 };
    const aliased_destination: [*]i32 = @ptrCast(&aliased);
    const before = aliased;
    try std.testing.expectError(
        Error.InvalidStorage,
        normalizeQ30L2V1(
            &aliased,
            1,
            2,
            aliased_destination[0..2],
        ),
    );
    try std.testing.expectEqualDeep(before, aliased);

    try std.testing.expectError(
        Error.InvalidCount,
        normalizedEmbeddingEncodedSizeV1(0, 2),
    );
    try std.testing.expectError(
        Error.InvalidDimensions,
        normalizedEmbeddingEncodedSizeV1(
            1,
            maximum_embedding_dimensions + 1,
        ),
    );
}

test "compact embedding matrix round trips with a source-bound root" {
    const components = [_]i32{
        q30_scale,    0,           0,
        -644_245_094, 858_993_459, 0,
    };
    var encoded_storage: [
        components.len * embedding_component_bytes
    ]u8 = undefined;
    const encoded = try encodeNormalizedEmbeddingV1(
        &components,
        2,
        3,
        &encoded_storage,
    );
    try std.testing.expectEqual(
        components.len * embedding_component_bytes,
        encoded.len,
    );
    try std.testing.expectEqual(
        q30_scale,
        std.mem.readInt(i32, encoded[0..4], .little),
    );

    var policy_storage: [embedding_policy_bytes]u8 = undefined;
    const policy = try encodeEmbeddingPolicyV1(
        canonical_embedding_policy_v1,
        &policy_storage,
    );
    var batch_root: Digest = undefined;
    for (&batch_root, 0..) |*byte, index| byte.* = @intCast(index);
    const view = try decodeAndValidateNormalizedEmbeddingV1(
        encoded,
        batch_root,
        policy,
        2,
        3,
    );
    for (components, 0..) |expected, linear_index| {
        try std.testing.expectEqual(
            expected,
            try view.component(
                linear_index / 3,
                linear_index % 3,
            ),
        );
    }
    try std.testing.expectError(
        Error.IndexOutOfBounds,
        view.component(2, 0),
    );
    try std.testing.expectEqualSlices(
        u8,
        &view.embedding_matrix_sha256,
        &(try embeddingMatrixSha256V1(
            batch_root,
            view.embedding_policy_sha256,
            2,
            3,
            encoded,
        )),
    );

    var second_batch_root = batch_root;
    second_batch_root[0] ^= 1;
    const rebound = try embeddingMatrixSha256V1(
        second_batch_root,
        view.embedding_policy_sha256,
        2,
        3,
        encoded,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &view.embedding_matrix_sha256,
        &rebound,
    ));
}

test "compact matrix validation is strict and encoding is transactional" {
    const valid = [_]i32{ q30_scale, 0, 0, q30_scale };
    var encoded_storage: [
        valid.len * embedding_component_bytes
    ]u8 = undefined;
    _ = try encodeNormalizedEmbeddingV1(
        &valid,
        2,
        2,
        &encoded_storage,
    );
    var policy_storage: [embedding_policy_bytes]u8 = undefined;
    const policy = try encodeEmbeddingPolicyV1(
        canonical_embedding_policy_v1,
        &policy_storage,
    );
    const batch_root = [_]u8{0xa5} ** @sizeOf(Digest);

    for (0..encoded_storage.len) |length|
        try expectMatrixRejected(
            encoded_storage[0..length],
            batch_root,
            policy,
            2,
            2,
        );

    var invalid_component = encoded_storage;
    std.mem.writeInt(
        i32,
        invalid_component[0..4],
        q30_scale + 1,
        .little,
    );
    try std.testing.expectError(
        Error.InvalidComponent,
        decodeAndValidateNormalizedEmbeddingV1(
            &invalid_component,
            batch_root,
            policy,
            2,
            2,
        ),
    );

    var zero_row = encoded_storage;
    @memset(zero_row[0..8], 0);
    try std.testing.expectError(
        Error.ZeroVector,
        decodeAndValidateNormalizedEmbeddingV1(
            &zero_row,
            batch_root,
            policy,
            2,
            2,
        ),
    );

    const invalid_values = [_]i32{ q30_scale, 0, 0, 0 };
    var untouched = [_]u8{0x6b} ** encoded_storage.len;
    try std.testing.expectError(
        Error.ZeroVector,
        encodeNormalizedEmbeddingV1(
            &invalid_values,
            2,
            2,
            &untouched,
        ),
    );
    for (untouched) |byte|
        try std.testing.expectEqual(@as(u8, 0x6b), byte);

    var aliased = valid;
    const aliased_bytes = std.mem.sliceAsBytes(aliased[0..]);
    const before = aliased;
    try std.testing.expectError(
        Error.InvalidStorage,
        encodeNormalizedEmbeddingV1(
            &aliased,
            2,
            2,
            aliased_bytes,
        ),
    );
    try std.testing.expectEqualDeep(before, aliased);
}
