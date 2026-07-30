//! Canonical, allocation-free fixed-corpus retrieval contracts.
//!
//! Retrieval V1 composes one normalized Q30 query with one immutable
//! normalized Q30 corpus. The index descriptor binds corpus order, tenant
//! visibility, embedding policy, matrix identity, and generation. Search
//! filters visibility before an exact Q30 dot product, then orders by score
//! descending and corpus ordinal ascending.
//!
//! Results use exactly one 96-byte slot per corpus item. The first `top_k`
//! slots are authenticated hits and every remaining slot is zero. A separate
//! contextual root binds the complete fixed-capacity wire to the exact index,
//! query, policy, and corpus geometry.

const std = @import("std");
const tensor_result = @import("stateless_tensor_result.zig");
const embedding_result = @import("stateless_embedding_result.zig");

pub const Digest = [32]u8;

pub const maximum_corpus_items: usize = 64;
pub const maximum_embedding_dimensions: usize = 4_096;
pub const retrieval_hit_bytes: usize = 96;
pub const retrieval_hit_body_bytes: usize = 64;

pub const visibility_map_magic =
    [_]u8{ 'G', 'R', 'V', 'I', 'S', '1', 0, 0 };
pub const visibility_map_abi: u64 = 0x4752_5649_5300_0001;
pub const visibility_map_header_bytes: usize = 64;
pub const visibility_map_item_bytes: usize = @sizeOf(u64);
pub const visibility_map_footer_bytes: usize = @sizeOf(Digest);

pub const retrieval_policy_magic =
    [_]u8{ 'G', 'R', 'P', 'O', 'L', '1', 0, 0 };
pub const retrieval_policy_abi: u64 = 0x4752_504f_4c00_0001;
pub const retrieval_policy_bytes: usize = 112;
pub const retrieval_policy_root_offset: usize = 80;

pub const retrieval_index_magic =
    [_]u8{ 'G', 'R', 'I', 'D', 'X', '1', 0, 0 };
pub const retrieval_index_abi: u64 = 0x4752_4944_5800_0001;
pub const retrieval_index_bytes: usize = 256;
pub const retrieval_index_root_offset: usize = 224;

pub const query_binding_magic =
    [_]u8{ 'G', 'R', 'Q', 'R', 'Y', '1', 0, 0 };
pub const query_binding_abi: u64 = 0x4752_5152_5900_0001;
pub const query_binding_bytes: usize = 320;
pub const query_binding_root_offset: usize = 288;

const visibility_map_domain =
    "glacier-retrieval-visibility-map-v1\x00";
const retrieval_policy_domain =
    "glacier-retrieval-policy-v1\x00";
const retrieval_index_domain =
    "glacier-retrieval-index-v1\x00";
const query_binding_domain =
    "glacier-retrieval-query-binding-v1\x00";
const retrieval_hit_domain =
    "glacier-retrieval-hit-v1\x00";
const retrieval_result_domain =
    "glacier-retrieval-result-v1\x00";

pub const Error = tensor_result.Error || embedding_result.Error || error{
    CapacityExceeded,
    InvalidStorage,
    InvalidLength,
    InvalidCount,
    InvalidDimensions,
    InvalidMagic,
    InvalidAbi,
    InvalidReserved,
    InvalidRoot,
    InvalidPolicy,
    InvalidTenant,
    InvalidBinding,
    InvalidOrdering,
    InvalidHit,
    ArithmeticOverflow,
    IndexOutOfBounds,
};

pub const SimilarityMetricV1 = enum(u64) {
    q30_dot_product = 1,
    _,
};

pub const RetrievalScoreFormatV1 = enum(u64) {
    signed_i64_q30 = 1,
    _,
};

pub const RetrievalRoundingV1 = enum(u64) {
    nearest_ties_to_even = 1,
    _,
};

pub const RetrievalOrderV1 = enum(u64) {
    score_descending = 1,
    _,
};

pub const RetrievalTieBreakV1 = enum(u64) {
    corpus_ordinal_ascending = 1,
    _,
};

pub const RetrievalPolicyV1 = struct {
    metric: SimilarityMetricV1 = .q30_dot_product,
    score_format: RetrievalScoreFormatV1 = .signed_i64_q30,
    rounding: RetrievalRoundingV1 = .nearest_ties_to_even,
    order: RetrievalOrderV1 = .score_descending,
    tie_break: RetrievalTieBreakV1 = .corpus_ordinal_ascending,
    top_k: u64,
};

pub const VisibilityMapViewV1 = struct {
    encoded: []const u8,
    item_count: usize,
    corpus_batch_map_sha256: Digest,
    visibility_sha256: Digest,

    pub fn tenantScope(
        self: VisibilityMapViewV1,
        corpus_ordinal: usize,
    ) Error!u64 {
        if (corpus_ordinal >= self.item_count)
            return Error.IndexOutOfBounds;
        const offset = visibility_map_header_bytes +
            corpus_ordinal * visibility_map_item_bytes;
        return readU64(self.encoded, offset);
    }

    pub fn permits(
        self: VisibilityMapViewV1,
        corpus_ordinal: usize,
        query_tenant: u64,
    ) Error!bool {
        const scope = try self.tenantScope(corpus_ordinal);
        return scope == 0 or scope == query_tenant;
    }
};

pub const RetrievalPolicyViewV1 = struct {
    encoded: []const u8,
    policy: RetrievalPolicyV1,
    retrieval_policy_sha256: Digest,
};

pub const RetrievalIndexV1 = struct {
    generation: u64,
    corpus_count: u64,
    dimensions: u64,
    index_id_sha256: Digest,
    corpus_map_sha256: Digest,
    visibility_sha256: Digest,
    embedding_policy_sha256: Digest,
    corpus_embedding_sha256: Digest,
};

pub const RetrievalIndexViewV1 = struct {
    encoded: []const u8,
    index: RetrievalIndexV1,
    index_descriptor_sha256: Digest,
    retrieval_index_sha256: Digest,
};

pub const QueryBindingV1 = struct {
    query_tenant: u64,
    dimensions: u64,
    query_object_sha256: Digest,
    query_map_sha256: Digest,
    embedding_policy_sha256: Digest,
    query_embedding_sha256: Digest,
    index_descriptor_sha256: Digest,
    retrieval_policy_sha256: Digest,
    challenge_sha256: Digest,
};

pub const QueryBindingViewV1 = struct {
    encoded: []const u8,
    binding: QueryBindingV1,
    query_binding_sha256: Digest,
};

const CanonicalCompositionV1 = struct {
    corpus_map: tensor_result.BatchMapViewV1,
    visibility: VisibilityMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    corpus_embedding: embedding_result.NormalizedEmbeddingViewV1,
    index: RetrievalIndexViewV1,
    query_map: tensor_result.BatchMapViewV1,
    query_embedding: embedding_result.NormalizedEmbeddingViewV1,
    policy: RetrievalPolicyViewV1,
    query_binding: QueryBindingViewV1,
};

pub const RetrievalHitV1 = struct {
    item_id: u64,
    corpus_ordinal: u64,
    rank: u64,
    score: i64,
};

pub const RetrievalResultViewV1 = struct {
    encoded: []const u8,
    corpus_count: usize,
    hit_count: usize,
    retrieval_result_sha256: Digest,

    pub fn hit(
        self: RetrievalResultViewV1,
        index: usize,
    ) Error!RetrievalHitV1 {
        if (index >= self.hit_count) return Error.IndexOutOfBounds;
        const offset = index * retrieval_hit_bytes;
        return readHit(self.encoded[offset .. offset + 32]);
    }
};

pub fn visibilityMapEncodedSizeV1(
    item_count: usize,
) Error!usize {
    if (item_count == 0 or item_count > maximum_corpus_items)
        return Error.InvalidCount;
    const entries = std.math.mul(
        usize,
        item_count,
        visibility_map_item_bytes,
    ) catch return Error.InvalidLength;
    return std.math.add(
        usize,
        visibility_map_header_bytes + visibility_map_footer_bytes,
        entries,
    ) catch return Error.InvalidLength;
}

pub fn retrievalResultEncodedSizeV1(
    corpus_count: usize,
) Error!usize {
    if (corpus_count == 0 or corpus_count > maximum_corpus_items)
        return Error.InvalidCount;
    return std.math.mul(
        usize,
        corpus_count,
        retrieval_hit_bytes,
    ) catch return Error.InvalidLength;
}

pub fn encodeVisibilityMapV1(
    corpus_batch_map_encoded: []const u8,
    tenant_scopes: []const u64,
    destination: []u8,
) Error![]const u8 {
    const corpus_map = tensor_result.decodeBatchMapV1(
        corpus_batch_map_encoded,
    ) catch return Error.InvalidBinding;
    if (corpus_map.item_count != tenant_scopes.len)
        return Error.InvalidCount;
    const needed = try visibilityMapEncodedSizeV1(tenant_scopes.len);
    if (destination.len < needed) return Error.CapacityExceeded;
    const output = destination[0..needed];
    if (slicesOverlap(corpus_batch_map_encoded, output) or
        slicesOverlap(std.mem.sliceAsBytes(tenant_scopes), output))
        return Error.InvalidStorage;

    @memcpy(output[0..8], &visibility_map_magic);
    writeU64(output, 8, visibility_map_abi);
    writeU64(output, 16, @intCast(needed));
    writeU64(output, 24, @intCast(tenant_scopes.len));
    @memcpy(output[32..64], &corpus_map.batch_map_sha256);
    for (tenant_scopes, 0..) |scope, index|
        writeU64(
            output,
            visibility_map_header_bytes +
                index * visibility_map_item_bytes,
            scope,
        );
    const root_offset = needed - visibility_map_footer_bytes;
    const root = domainRoot(
        visibility_map_domain,
        output[0..root_offset],
    );
    @memcpy(output[root_offset..needed], &root);
    return output;
}

pub fn decodeVisibilityMapV1(
    encoded: []const u8,
) Error!VisibilityMapViewV1 {
    if (encoded.len < visibility_map_header_bytes +
        visibility_map_item_bytes + visibility_map_footer_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &visibility_map_magic))
        return Error.InvalidMagic;
    if (readU64(encoded, 8) != visibility_map_abi)
        return Error.InvalidAbi;
    if (readU64(encoded, 16) != encoded.len)
        return Error.InvalidLength;
    const item_count = std.math.cast(
        usize,
        readU64(encoded, 24),
    ) orelse return Error.InvalidCount;
    const needed = try visibilityMapEncodedSizeV1(item_count);
    if (needed != encoded.len) return Error.InvalidLength;
    const root_offset = needed - visibility_map_footer_bytes;
    const expected = domainRoot(
        visibility_map_domain,
        encoded[0..root_offset],
    );
    if (!std.mem.eql(u8, &expected, encoded[root_offset..needed]))
        return Error.InvalidRoot;
    return .{
        .encoded = encoded,
        .item_count = item_count,
        .corpus_batch_map_sha256 = encoded[32..64].*,
        .visibility_sha256 = expected,
    };
}

pub fn decodeAndValidateVisibilityMapV1(
    encoded: []const u8,
    corpus_batch_map_encoded: []const u8,
) Error!VisibilityMapViewV1 {
    const view = try decodeVisibilityMapV1(encoded);
    const corpus_map = tensor_result.decodeBatchMapV1(
        corpus_batch_map_encoded,
    ) catch return Error.InvalidBinding;
    if (view.item_count != corpus_map.item_count or
        !std.mem.eql(
            u8,
            &view.corpus_batch_map_sha256,
            &corpus_map.batch_map_sha256,
        ))
        return Error.InvalidBinding;
    return view;
}

pub fn encodeRetrievalPolicyV1(
    policy: RetrievalPolicyV1,
    destination: []u8,
) Error![]const u8 {
    if (!retrievalPolicyValidV1(policy)) return Error.InvalidPolicy;
    if (destination.len < retrieval_policy_bytes)
        return Error.CapacityExceeded;
    const output = destination[0..retrieval_policy_bytes];
    @memcpy(output[0..8], &retrieval_policy_magic);
    writeU64(output, 8, retrieval_policy_abi);
    writeU64(output, 16, retrieval_policy_bytes);
    writeU64(output, 24, @intFromEnum(policy.metric));
    writeU64(output, 32, @intFromEnum(policy.score_format));
    writeU64(output, 40, @intFromEnum(policy.rounding));
    writeU64(output, 48, @intFromEnum(policy.order));
    writeU64(output, 56, @intFromEnum(policy.tie_break));
    writeU64(output, 64, policy.top_k);
    writeU64(output, 72, 0);
    const root = domainRoot(
        retrieval_policy_domain,
        output[0..retrieval_policy_root_offset],
    );
    @memcpy(output[retrieval_policy_root_offset..], &root);
    return output;
}

pub fn decodeRetrievalPolicyV1(
    encoded: []const u8,
) Error!RetrievalPolicyViewV1 {
    if (encoded.len != retrieval_policy_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &retrieval_policy_magic))
        return Error.InvalidMagic;
    if (readU64(encoded, 8) != retrieval_policy_abi)
        return Error.InvalidAbi;
    if (readU64(encoded, 16) != retrieval_policy_bytes)
        return Error.InvalidLength;
    if (readU64(encoded, 72) != 0)
        return Error.InvalidReserved;
    const policy: RetrievalPolicyV1 = .{
        .metric = std.meta.intToEnum(
            SimilarityMetricV1,
            readU64(encoded, 24),
        ) catch return Error.InvalidPolicy,
        .score_format = std.meta.intToEnum(
            RetrievalScoreFormatV1,
            readU64(encoded, 32),
        ) catch return Error.InvalidPolicy,
        .rounding = std.meta.intToEnum(
            RetrievalRoundingV1,
            readU64(encoded, 40),
        ) catch return Error.InvalidPolicy,
        .order = std.meta.intToEnum(
            RetrievalOrderV1,
            readU64(encoded, 48),
        ) catch return Error.InvalidPolicy,
        .tie_break = std.meta.intToEnum(
            RetrievalTieBreakV1,
            readU64(encoded, 56),
        ) catch return Error.InvalidPolicy,
        .top_k = readU64(encoded, 64),
    };
    if (!retrievalPolicyValidV1(policy)) return Error.InvalidPolicy;
    const expected = domainRoot(
        retrieval_policy_domain,
        encoded[0..retrieval_policy_root_offset],
    );
    if (!std.mem.eql(
        u8,
        &expected,
        encoded[retrieval_policy_root_offset..],
    )) return Error.InvalidRoot;
    return .{
        .encoded = encoded,
        .policy = policy,
        .retrieval_policy_sha256 = expected,
    };
}

pub fn encodeRetrievalIndexV1(
    index: RetrievalIndexV1,
    destination: []u8,
) Error![]const u8 {
    try validateIndexValue(index);
    if (destination.len < retrieval_index_bytes)
        return Error.CapacityExceeded;
    const output = destination[0..retrieval_index_bytes];
    @memcpy(output[0..8], &retrieval_index_magic);
    writeU64(output, 8, retrieval_index_abi);
    writeU64(output, 16, retrieval_index_bytes);
    writeU64(output, 24, index.generation);
    writeU64(output, 32, index.corpus_count);
    writeU64(output, 40, index.dimensions);
    writeU64(output, 48, 0);
    writeU64(output, 56, 0);
    @memcpy(output[64..96], &index.index_id_sha256);
    @memcpy(output[96..128], &index.corpus_map_sha256);
    @memcpy(output[128..160], &index.visibility_sha256);
    @memcpy(output[160..192], &index.embedding_policy_sha256);
    @memcpy(output[192..224], &index.corpus_embedding_sha256);
    const root = domainRoot(
        retrieval_index_domain,
        output[0..retrieval_index_root_offset],
    );
    @memcpy(output[retrieval_index_root_offset..], &root);
    return output;
}

pub fn decodeRetrievalIndexV1(
    encoded: []const u8,
) Error!RetrievalIndexViewV1 {
    if (encoded.len != retrieval_index_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &retrieval_index_magic))
        return Error.InvalidMagic;
    if (readU64(encoded, 8) != retrieval_index_abi)
        return Error.InvalidAbi;
    if (readU64(encoded, 16) != retrieval_index_bytes)
        return Error.InvalidLength;
    if (readU64(encoded, 48) != 0 or readU64(encoded, 56) != 0)
        return Error.InvalidReserved;
    const index: RetrievalIndexV1 = .{
        .generation = readU64(encoded, 24),
        .corpus_count = readU64(encoded, 32),
        .dimensions = readU64(encoded, 40),
        .index_id_sha256 = encoded[64..96].*,
        .corpus_map_sha256 = encoded[96..128].*,
        .visibility_sha256 = encoded[128..160].*,
        .embedding_policy_sha256 = encoded[160..192].*,
        .corpus_embedding_sha256 = encoded[192..224].*,
    };
    try validateIndexValue(index);
    const expected = domainRoot(
        retrieval_index_domain,
        encoded[0..retrieval_index_root_offset],
    );
    if (!std.mem.eql(
        u8,
        &expected,
        encoded[retrieval_index_root_offset..],
    )) return Error.InvalidRoot;
    return .{
        .encoded = encoded,
        .index = index,
        .index_descriptor_sha256 = expected,
        .retrieval_index_sha256 = expected,
    };
}

pub fn encodeQueryBindingV1(
    binding: QueryBindingV1,
    destination: []u8,
) Error![]const u8 {
    try validateQueryBindingValue(binding);
    if (destination.len < query_binding_bytes)
        return Error.CapacityExceeded;
    const output = destination[0..query_binding_bytes];
    @memcpy(output[0..8], &query_binding_magic);
    writeU64(output, 8, query_binding_abi);
    writeU64(output, 16, query_binding_bytes);
    writeU64(output, 24, binding.query_tenant);
    writeU64(output, 32, binding.dimensions);
    writeU64(output, 40, 0);
    writeU64(output, 48, 0);
    writeU64(output, 56, 0);
    @memcpy(output[64..96], &binding.query_object_sha256);
    @memcpy(output[96..128], &binding.query_map_sha256);
    @memcpy(output[128..160], &binding.embedding_policy_sha256);
    @memcpy(output[160..192], &binding.query_embedding_sha256);
    @memcpy(output[192..224], &binding.index_descriptor_sha256);
    @memcpy(output[224..256], &binding.retrieval_policy_sha256);
    @memcpy(output[256..288], &binding.challenge_sha256);
    const root = domainRoot(
        query_binding_domain,
        output[0..query_binding_root_offset],
    );
    @memcpy(output[query_binding_root_offset..], &root);
    return output;
}

pub fn decodeQueryBindingV1(
    encoded: []const u8,
) Error!QueryBindingViewV1 {
    if (encoded.len != query_binding_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &query_binding_magic))
        return Error.InvalidMagic;
    if (readU64(encoded, 8) != query_binding_abi)
        return Error.InvalidAbi;
    if (readU64(encoded, 16) != query_binding_bytes)
        return Error.InvalidLength;
    if (readU64(encoded, 40) != 0 or
        readU64(encoded, 48) != 0 or
        readU64(encoded, 56) != 0)
        return Error.InvalidReserved;
    const binding: QueryBindingV1 = .{
        .query_tenant = readU64(encoded, 24),
        .dimensions = readU64(encoded, 32),
        .query_object_sha256 = encoded[64..96].*,
        .query_map_sha256 = encoded[96..128].*,
        .embedding_policy_sha256 = encoded[128..160].*,
        .query_embedding_sha256 = encoded[160..192].*,
        .index_descriptor_sha256 = encoded[192..224].*,
        .retrieval_policy_sha256 = encoded[224..256].*,
        .challenge_sha256 = encoded[256..288].*,
    };
    try validateQueryBindingValue(binding);
    const expected = domainRoot(
        query_binding_domain,
        encoded[0..query_binding_root_offset],
    );
    if (!std.mem.eql(
        u8,
        &expected,
        encoded[query_binding_root_offset..],
    )) return Error.InvalidRoot;
    return .{
        .encoded = encoded,
        .binding = binding,
        .query_binding_sha256 = expected,
    };
}

pub fn searchTopKV1(
    corpus_map: tensor_result.BatchMapViewV1,
    visibility: VisibilityMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    corpus_embedding: embedding_result.NormalizedEmbeddingViewV1,
    index: RetrievalIndexViewV1,
    query_map: tensor_result.BatchMapViewV1,
    query_embedding: embedding_result.NormalizedEmbeddingViewV1,
    policy: RetrievalPolicyViewV1,
    query_binding: QueryBindingViewV1,
    destination: []u8,
) Error![]const u8 {
    const composition = try canonicalizeComposition(
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    return searchCanonicalTopKV1(composition, destination);
}

fn searchCanonicalTopKV1(
    composition: CanonicalCompositionV1,
    destination: []u8,
) Error![]const u8 {
    const corpus_map = composition.corpus_map;
    const visibility = composition.visibility;
    const embedding_policy = composition.embedding_policy;
    const corpus_embedding = composition.corpus_embedding;
    const index = composition.index;
    const query_map = composition.query_map;
    const query_embedding = composition.query_embedding;
    const policy = composition.policy;
    const query_binding = composition.query_binding;
    const corpus_count = corpus_map.item_count;
    const needed = try retrievalResultEncodedSizeV1(corpus_count);
    if (destination.len < needed) return Error.CapacityExceeded;
    const output = destination[0..needed];
    if (slicesOverlap(output, corpus_map.encoded) or
        slicesOverlap(output, visibility.encoded) or
        slicesOverlap(output, embedding_policy.encoded) or
        slicesOverlap(output, corpus_embedding.encoded) or
        slicesOverlap(output, index.encoded) or
        slicesOverlap(output, query_map.encoded) or
        slicesOverlap(output, query_embedding.encoded) or
        slicesOverlap(output, policy.encoded) or
        slicesOverlap(output, query_binding.encoded))
        return Error.InvalidStorage;

    var hits: [maximum_corpus_items]RetrievalHitV1 = undefined;
    var eligible_count: usize = 0;
    for (0..corpus_count) |corpus_ordinal| {
        if (!(try visibility.permits(
            corpus_ordinal,
            query_binding.binding.query_tenant,
        ))) continue;
        hits[eligible_count] = .{
            .item_id = try corpus_map.itemId(corpus_ordinal),
            .corpus_ordinal = @intCast(corpus_ordinal),
            .rank = 0,
            .score = try q30DotScoreV1(
                query_embedding,
                corpus_embedding,
                corpus_ordinal,
            ),
        };
        eligible_count += 1;
    }
    const top_k = std.math.cast(
        usize,
        policy.policy.top_k,
    ) orelse return Error.InvalidPolicy;
    if (top_k == 0 or top_k > eligible_count)
        return Error.InvalidPolicy;
    insertionSortHits(hits[0..eligible_count]);
    for (hits[0..top_k], 0..) |*hit_value, rank|
        hit_value.rank = @intCast(rank);

    @memset(output, 0);
    for (hits[0..top_k], 0..) |hit_value, index_value| {
        const offset = index_value * retrieval_hit_bytes;
        writeHit(output[offset .. offset + retrieval_hit_body_bytes], hit_value);
        const root = hitRoot(
            index.index_descriptor_sha256,
            query_binding.query_binding_sha256,
            policy.retrieval_policy_sha256,
            output[offset .. offset + retrieval_hit_body_bytes],
        );
        @memcpy(
            output[offset + retrieval_hit_body_bytes .. offset + retrieval_hit_bytes],
            &root,
        );
    }
    return output;
}

pub fn decodeRetrievalResultV1(
    encoded: []const u8,
    corpus_map: tensor_result.BatchMapViewV1,
    visibility: VisibilityMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    corpus_embedding: embedding_result.NormalizedEmbeddingViewV1,
    index: RetrievalIndexViewV1,
    query_map: tensor_result.BatchMapViewV1,
    query_embedding: embedding_result.NormalizedEmbeddingViewV1,
    policy: RetrievalPolicyViewV1,
    query_binding: QueryBindingViewV1,
) Error!RetrievalResultViewV1 {
    const composition = try canonicalizeComposition(
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    const needed = try retrievalResultEncodedSizeV1(
        composition.corpus_map.item_count,
    );
    if (encoded.len != needed) return Error.InvalidLength;

    const top_k = std.math.cast(
        usize,
        composition.policy.policy.top_k,
    ) orelse return Error.InvalidPolicy;
    var previous: ?RetrievalHitV1 = null;
    for (0..top_k) |rank| {
        const offset = rank * retrieval_hit_bytes;
        const body = encoded[offset .. offset + retrieval_hit_body_bytes];
        if (!std.mem.allEqual(u8, body[32..retrieval_hit_body_bytes], 0))
            return Error.InvalidReserved;
        const expected_root = hitRoot(
            composition.index.index_descriptor_sha256,
            composition.query_binding.query_binding_sha256,
            composition.policy.retrieval_policy_sha256,
            body,
        );
        if (!std.mem.eql(
            u8,
            &expected_root,
            encoded[offset + retrieval_hit_body_bytes .. offset + retrieval_hit_bytes],
        )) return Error.InvalidRoot;
        const hit_value = readHit(body[0..32]);
        const ordinal = std.math.cast(
            usize,
            hit_value.corpus_ordinal,
        ) orelse return Error.InvalidHit;
        if (hit_value.rank != rank or
            ordinal >= composition.corpus_map.item_count or
            hit_value.item_id !=
                (try composition.corpus_map.itemId(ordinal)) or
            !(try composition.visibility.permits(
                ordinal,
                composition.query_binding.binding.query_tenant,
            )) or
            hit_value.score != (try q30DotScoreV1(
                composition.query_embedding,
                composition.corpus_embedding,
                ordinal,
            )))
            return Error.InvalidHit;
        if (previous) |prior| {
            if (!hitBefore(prior, hit_value))
                return Error.InvalidOrdering;
        }
        previous = hit_value;
    }
    const tail_offset = top_k * retrieval_hit_bytes;
    if (!std.mem.allEqual(u8, encoded[tail_offset..], 0))
        return Error.InvalidHit;

    var expected_storage: [maximum_corpus_items * retrieval_hit_bytes]u8 = undefined;
    const expected = try searchCanonicalTopKV1(
        composition,
        expected_storage[0..needed],
    );
    if (!std.mem.eql(u8, encoded, expected))
        return Error.InvalidHit;

    const root = retrievalResultRootV1(
        encoded,
        composition.index,
        composition.query_binding,
        composition.policy,
    );
    return .{
        .encoded = encoded,
        .corpus_count = composition.corpus_map.item_count,
        .hit_count = top_k,
        .retrieval_result_sha256 = root,
    };
}

pub fn retrievalResultRootV1(
    encoded: []const u8,
    index: RetrievalIndexViewV1,
    query_binding: QueryBindingViewV1,
    policy: RetrievalPolicyViewV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(retrieval_result_domain);
    hash.update(&index.index_descriptor_sha256);
    hash.update(&query_binding.query_binding_sha256);
    hash.update(&policy.retrieval_policy_sha256);
    hashU64(&hash, index.index.corpus_count);
    hashU64(&hash, index.index.dimensions);
    hashU64(&hash, policy.policy.top_k);
    hash.update(encoded);
    return hash.finalResult();
}

pub fn q30DotScoreV1(
    query: embedding_result.NormalizedEmbeddingViewV1,
    corpus: embedding_result.NormalizedEmbeddingViewV1,
    corpus_ordinal: usize,
) Error!i64 {
    if (query.item_count != 1 or
        query.dimensions == 0 or
        query.dimensions != corpus.dimensions or
        corpus_ordinal >= corpus.item_count)
        return Error.InvalidDimensions;
    var wide: i128 = 0;
    for (0..query.dimensions) |dimension| {
        const left: i128 = try query.component(0, dimension);
        const right: i128 =
            try corpus.component(corpus_ordinal, dimension);
        const product = std.math.mul(
            i128,
            left,
            right,
        ) catch return Error.ArithmeticOverflow;
        wide = std.math.add(
            i128,
            wide,
            product,
        ) catch return Error.ArithmeticOverflow;
    }
    return roundQ60ToQ30TiesEven(wide);
}

pub fn downscaleQ60ToQ30V1(value: i128) Error!i64 {
    return roundQ60ToQ30TiesEven(value);
}

fn canonicalizeComposition(
    corpus_map: tensor_result.BatchMapViewV1,
    visibility: VisibilityMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    corpus_embedding: embedding_result.NormalizedEmbeddingViewV1,
    index: RetrievalIndexViewV1,
    query_map: tensor_result.BatchMapViewV1,
    query_embedding: embedding_result.NormalizedEmbeddingViewV1,
    policy: RetrievalPolicyViewV1,
    query_binding: QueryBindingViewV1,
) Error!CanonicalCompositionV1 {
    const canonical_index = decodeRetrievalIndexV1(
        index.encoded,
    ) catch return Error.InvalidBinding;
    const canonical_corpus_map = tensor_result.decodeBatchMapV1(
        corpus_map.encoded,
    ) catch return Error.InvalidBinding;
    const canonical_query_map = tensor_result.decodeBatchMapV1(
        query_map.encoded,
    ) catch return Error.InvalidBinding;
    const canonical_embedding_policy =
        embedding_result.decodeEmbeddingPolicyV1(
            embedding_policy.encoded,
        ) catch return Error.InvalidBinding;
    const canonical_policy = decodeRetrievalPolicyV1(
        policy.encoded,
    ) catch return Error.InvalidBinding;
    const canonical_visibility = decodeAndValidateVisibilityMapV1(
        visibility.encoded,
        canonical_corpus_map.encoded,
    ) catch return Error.InvalidBinding;
    const canonical_query_binding = decodeQueryBindingV1(
        query_binding.encoded,
    ) catch return Error.InvalidBinding;

    const corpus_count = std.math.cast(
        usize,
        canonical_index.index.corpus_count,
    ) orelse return Error.InvalidCount;
    const dimensions = std.math.cast(
        usize,
        canonical_index.index.dimensions,
    ) orelse return Error.InvalidDimensions;

    const canonical_corpus_embedding =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            corpus_embedding.encoded,
            canonical_corpus_map.batch_map_sha256,
            canonical_embedding_policy.encoded,
            corpus_count,
            dimensions,
        ) catch return Error.InvalidBinding;
    const canonical_query_embedding =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            query_embedding.encoded,
            canonical_query_map.batch_map_sha256,
            canonical_embedding_policy.encoded,
            1,
            dimensions,
        ) catch return Error.InvalidBinding;

    if (corpus_map.item_count != canonical_corpus_map.item_count or
        !std.mem.eql(
            u8,
            &corpus_map.batch_map_sha256,
            &canonical_corpus_map.batch_map_sha256,
        ) or
        visibility.item_count != canonical_visibility.item_count or
        !std.mem.eql(
            u8,
            &visibility.corpus_batch_map_sha256,
            &canonical_visibility.corpus_batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &visibility.visibility_sha256,
            &canonical_visibility.visibility_sha256,
        ) or
        !std.meta.eql(
            embedding_policy.policy,
            canonical_embedding_policy.policy,
        ) or
        !std.mem.eql(
            u8,
            &embedding_policy.embedding_policy_sha256,
            &canonical_embedding_policy.embedding_policy_sha256,
        ) or
        corpus_embedding.item_count !=
            canonical_corpus_embedding.item_count or
        corpus_embedding.dimensions !=
            canonical_corpus_embedding.dimensions or
        !std.mem.eql(
            u8,
            &corpus_embedding.batch_map_sha256,
            &canonical_corpus_embedding.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &corpus_embedding.embedding_policy_sha256,
            &canonical_corpus_embedding.embedding_policy_sha256,
        ) or
        !std.mem.eql(
            u8,
            &corpus_embedding.embedding_matrix_sha256,
            &canonical_corpus_embedding.embedding_matrix_sha256,
        ) or
        !std.meta.eql(index.index, canonical_index.index) or
        !std.mem.eql(
            u8,
            &index.index_descriptor_sha256,
            &canonical_index.index_descriptor_sha256,
        ) or
        !std.mem.eql(
            u8,
            &index.retrieval_index_sha256,
            &canonical_index.retrieval_index_sha256,
        ) or
        query_map.item_count != canonical_query_map.item_count or
        !std.mem.eql(
            u8,
            &query_map.batch_map_sha256,
            &canonical_query_map.batch_map_sha256,
        ) or
        query_embedding.item_count !=
            canonical_query_embedding.item_count or
        query_embedding.dimensions !=
            canonical_query_embedding.dimensions or
        !std.mem.eql(
            u8,
            &query_embedding.batch_map_sha256,
            &canonical_query_embedding.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &query_embedding.embedding_policy_sha256,
            &canonical_query_embedding.embedding_policy_sha256,
        ) or
        !std.mem.eql(
            u8,
            &query_embedding.embedding_matrix_sha256,
            &canonical_query_embedding.embedding_matrix_sha256,
        ) or
        !std.meta.eql(policy.policy, canonical_policy.policy) or
        !std.mem.eql(
            u8,
            &policy.retrieval_policy_sha256,
            &canonical_policy.retrieval_policy_sha256,
        ) or
        !std.meta.eql(
            query_binding.binding,
            canonical_query_binding.binding,
        ) or
        !std.mem.eql(
            u8,
            &query_binding.query_binding_sha256,
            &canonical_query_binding.query_binding_sha256,
        ))
        return Error.InvalidBinding;

    const composition: CanonicalCompositionV1 = .{
        .corpus_map = canonical_corpus_map,
        .visibility = canonical_visibility,
        .embedding_policy = canonical_embedding_policy,
        .corpus_embedding = canonical_corpus_embedding,
        .index = canonical_index,
        .query_map = canonical_query_map,
        .query_embedding = canonical_query_embedding,
        .policy = canonical_policy,
        .query_binding = canonical_query_binding,
    };
    try validateCanonicalComposition(composition);
    return composition;
}

fn validateCanonicalComposition(
    composition: CanonicalCompositionV1,
) Error!void {
    const corpus_map = composition.corpus_map;
    const visibility = composition.visibility;
    const embedding_policy = composition.embedding_policy;
    const corpus_embedding = composition.corpus_embedding;
    const index = composition.index;
    const query_map = composition.query_map;
    const query_embedding = composition.query_embedding;
    const policy = composition.policy;
    const query_binding = composition.query_binding;
    const corpus_count = std.math.cast(
        usize,
        index.index.corpus_count,
    ) orelse return Error.InvalidCount;
    const dimensions = std.math.cast(
        usize,
        index.index.dimensions,
    ) orelse return Error.InvalidDimensions;
    if (corpus_count == 0 or corpus_count > maximum_corpus_items or
        dimensions == 0 or dimensions > maximum_embedding_dimensions or
        corpus_map.item_count != corpus_count or
        visibility.item_count != corpus_count or
        corpus_embedding.item_count != corpus_count or
        corpus_embedding.dimensions != dimensions or
        query_map.item_count != 1 or
        query_embedding.item_count != 1 or
        query_embedding.dimensions != dimensions or
        query_binding.binding.dimensions != dimensions or
        policy.policy.top_k == 0 or
        policy.policy.top_k > corpus_count)
        return Error.InvalidBinding;
    if (!std.mem.eql(
        u8,
        &index.index.corpus_map_sha256,
        &corpus_map.batch_map_sha256,
    ) or !std.mem.eql(
        u8,
        &visibility.corpus_batch_map_sha256,
        &corpus_map.batch_map_sha256,
    ) or !std.mem.eql(
        u8,
        &index.index.visibility_sha256,
        &visibility.visibility_sha256,
    ) or !std.mem.eql(
        u8,
        &index.index.embedding_policy_sha256,
        &embedding_policy.embedding_policy_sha256,
    ) or !std.mem.eql(
        u8,
        &index.index.corpus_embedding_sha256,
        &corpus_embedding.embedding_matrix_sha256,
    ) or !std.mem.eql(
        u8,
        &query_binding.binding.query_map_sha256,
        &query_map.batch_map_sha256,
    ) or !std.mem.eql(
        u8,
        &query_binding.binding.embedding_policy_sha256,
        &embedding_policy.embedding_policy_sha256,
    ) or !std.mem.eql(
        u8,
        &query_binding.binding.query_embedding_sha256,
        &query_embedding.embedding_matrix_sha256,
    ) or !std.mem.eql(
        u8,
        &query_binding.binding.index_descriptor_sha256,
        &index.index_descriptor_sha256,
    ) or !std.mem.eql(
        u8,
        &query_binding.binding.retrieval_policy_sha256,
        &policy.retrieval_policy_sha256,
    ))
        return Error.InvalidBinding;
    if (!std.mem.eql(
        u8,
        &corpus_embedding.embedding_policy_sha256,
        &embedding_policy.embedding_policy_sha256,
    ) or !std.mem.eql(
        u8,
        &query_embedding.embedding_policy_sha256,
        &embedding_policy.embedding_policy_sha256,
    ) or !std.mem.eql(
        u8,
        &corpus_embedding.batch_map_sha256,
        &corpus_map.batch_map_sha256,
    ) or !std.mem.eql(
        u8,
        &query_embedding.batch_map_sha256,
        &query_map.batch_map_sha256,
    ))
        return Error.InvalidBinding;
}

fn validateIndexValue(index: RetrievalIndexV1) Error!void {
    if (index.generation == 0 or
        index.corpus_count == 0 or
        index.corpus_count > maximum_corpus_items or
        index.dimensions == 0 or
        index.dimensions > maximum_embedding_dimensions or
        isZero(index.index_id_sha256) or
        isZero(index.corpus_map_sha256) or
        isZero(index.visibility_sha256) or
        isZero(index.embedding_policy_sha256) or
        isZero(index.corpus_embedding_sha256))
        return Error.InvalidBinding;
}

fn validateQueryBindingValue(binding: QueryBindingV1) Error!void {
    if (binding.dimensions == 0 or
        binding.dimensions > maximum_embedding_dimensions or
        isZero(binding.query_object_sha256) or
        isZero(binding.query_map_sha256) or
        isZero(binding.embedding_policy_sha256) or
        isZero(binding.query_embedding_sha256) or
        isZero(binding.index_descriptor_sha256) or
        isZero(binding.retrieval_policy_sha256) or
        isZero(binding.challenge_sha256))
        return Error.InvalidBinding;
}

fn retrievalPolicyValidV1(policy: RetrievalPolicyV1) bool {
    return policy.metric == .q30_dot_product and
        policy.score_format == .signed_i64_q30 and
        policy.rounding == .nearest_ties_to_even and
        policy.order == .score_descending and
        policy.tie_break == .corpus_ordinal_ascending and
        policy.top_k > 0 and
        policy.top_k <= maximum_corpus_items;
}

fn roundQ60ToQ30TiesEven(value: i128) Error!i64 {
    const divisor: i128 = @as(i128, 1) << 30;
    var quotient = @divTrunc(value, divisor);
    const remainder = @rem(value, divisor);
    const magnitude: i128 = if (remainder < 0)
        -remainder
    else
        remainder;
    const twice = std.math.mul(
        i128,
        magnitude,
        2,
    ) catch return Error.ArithmeticOverflow;
    const quotient_is_odd = @rem(
        if (quotient < 0) -quotient else quotient,
        2,
    ) == 1;
    if (twice > divisor or
        (twice == divisor and quotient_is_odd))
    {
        quotient = std.math.add(
            i128,
            quotient,
            if (value < 0) -1 else 1,
        ) catch return Error.ArithmeticOverflow;
    }
    return std.math.cast(i64, quotient) orelse
        Error.ArithmeticOverflow;
}

fn insertionSortHits(hits: []RetrievalHitV1) void {
    for (1..hits.len) |index| {
        var cursor = index;
        while (cursor > 0 and
            hitBefore(hits[cursor], hits[cursor - 1]))
        {
            std.mem.swap(
                RetrievalHitV1,
                &hits[cursor],
                &hits[cursor - 1],
            );
            cursor -= 1;
        }
    }
}

fn hitBefore(left: RetrievalHitV1, right: RetrievalHitV1) bool {
    return left.score > right.score or
        (left.score == right.score and
            left.corpus_ordinal < right.corpus_ordinal);
}

fn writeHit(destination: []u8, hit_value: RetrievalHitV1) void {
    writeU64(destination, 0, hit_value.item_id);
    writeU64(destination, 8, hit_value.corpus_ordinal);
    writeU64(destination, 16, hit_value.rank);
    std.mem.writeInt(i64, destination[24..32][0..8], hit_value.score, .little);
    @memset(destination[32..retrieval_hit_body_bytes], 0);
}

fn readHit(encoded: []const u8) RetrievalHitV1 {
    return .{
        .item_id = readU64(encoded, 0),
        .corpus_ordinal = readU64(encoded, 8),
        .rank = readU64(encoded, 16),
        .score = std.mem.readInt(i64, encoded[24..32][0..8], .little),
    };
}

fn hitRoot(
    index_sha256: Digest,
    query_sha256: Digest,
    policy_sha256: Digest,
    body: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(retrieval_hit_domain);
    hash.update(&index_sha256);
    hash.update(&query_sha256);
    hash.update(&policy_sha256);
    hash.update(body);
    return hash.finalResult();
}

fn domainRoot(domain: []const u8, body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(body);
    return hash.finalResult();
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn writeU64(destination: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(
        u64,
        destination[offset .. offset + @sizeOf(u64)][0..@sizeOf(u64)],
        value,
        .little,
    );
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        source[offset .. offset + @sizeOf(u64)][0..@sizeOf(u64)],
        .little,
    );
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(
        usize,
        a_start,
        a.len,
    ) catch return true;
    const b_end = std.math.add(
        usize,
        b_start,
        b.len,
    ) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn expectInvalidCompositionRejectedV1(
    result_encoded: []const u8,
    corpus_map: tensor_result.BatchMapViewV1,
    visibility: VisibilityMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    corpus_embedding: embedding_result.NormalizedEmbeddingViewV1,
    index: RetrievalIndexViewV1,
    query_map: tensor_result.BatchMapViewV1,
    query_embedding: embedding_result.NormalizedEmbeddingViewV1,
    policy: RetrievalPolicyViewV1,
    query_binding: QueryBindingViewV1,
) !void {
    var destination =
        [_]u8{0xa5} ** (maximum_corpus_items * retrieval_hit_bytes);
    try std.testing.expectError(
        Error.InvalidBinding,
        searchTopKV1(
            corpus_map,
            visibility,
            embedding_policy,
            corpus_embedding,
            index,
            query_map,
            query_embedding,
            policy,
            query_binding,
            &destination,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &destination,
        0xa5,
    ));
    try std.testing.expectError(
        Error.InvalidBinding,
        decodeRetrievalResultV1(
            result_encoded,
            corpus_map,
            visibility,
            embedding_policy,
            corpus_embedding,
            index,
            query_map,
            query_embedding,
            policy,
            query_binding,
        ),
    );
}

test "fixed corpus retrieval filters before deterministic top-k" {
    const corpus_ids = [_]u64{ 9_101, 9_102, 9_103, 9_104 };
    var corpus_map_storage: [128]u8 = undefined;
    const corpus_map_encoded = try tensor_result.encodeBatchMapV1(
        &corpus_ids,
        &corpus_map_storage,
    );
    const corpus_map = try tensor_result.decodeBatchMapV1(
        corpus_map_encoded,
    );

    const query_ids = [_]u64{9_900};
    var query_map_storage: [80]u8 = undefined;
    const query_map_encoded = try tensor_result.encodeBatchMapV1(
        &query_ids,
        &query_map_storage,
    );
    const query_map = try tensor_result.decodeBatchMapV1(
        query_map_encoded,
    );

    var embedding_policy_storage: [embedding_result.embedding_policy_bytes]u8 =
        undefined;
    const embedding_policy_encoded =
        try embedding_result.encodeEmbeddingPolicyV1(
            embedding_result.canonical_embedding_policy_v1,
            &embedding_policy_storage,
        );
    const embedding_policy =
        try embedding_result.decodeEmbeddingPolicyV1(
            embedding_policy_encoded,
        );

    var diagonal_raw = [_]i64{ 1, 1 };
    var diagonal: [2]i32 = undefined;
    _ = try embedding_result.normalizeQ30L2V1(
        &diagonal_raw,
        1,
        2,
        &diagonal,
    );
    const scale = embedding_result.q30_scale;
    const corpus_components = [_]i32{
        diagonal[0], diagonal[1],
        scale,       0,
        diagonal[0], diagonal[1],
        0,           scale,
    };
    var corpus_embedding_storage: [corpus_components.len * @sizeOf(i32)]u8 =
        undefined;
    const corpus_embedding_encoded =
        try embedding_result.encodeNormalizedEmbeddingV1(
            &corpus_components,
            corpus_ids.len,
            2,
            &corpus_embedding_storage,
        );
    const corpus_embedding =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            corpus_embedding_encoded,
            corpus_map.batch_map_sha256,
            embedding_policy_encoded,
            corpus_ids.len,
            2,
        );

    const query_components = [_]i32{ scale, 0 };
    var query_embedding_storage: [query_components.len * @sizeOf(i32)]u8 =
        undefined;
    const query_embedding_encoded =
        try embedding_result.encodeNormalizedEmbeddingV1(
            &query_components,
            1,
            2,
            &query_embedding_storage,
        );
    const query_embedding =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            query_embedding_encoded,
            query_map.batch_map_sha256,
            embedding_policy_encoded,
            1,
            2,
        );

    const visibility_tenants = [_]u64{ 0, 99, 7, 7 };
    var visibility_storage: [128]u8 = undefined;
    const visibility_encoded = try encodeVisibilityMapV1(
        corpus_map_encoded,
        &visibility_tenants,
        &visibility_storage,
    );
    const visibility = try decodeAndValidateVisibilityMapV1(
        visibility_encoded,
        corpus_map_encoded,
    );

    var policy_storage: [retrieval_policy_bytes]u8 = undefined;
    const policy_encoded = try encodeRetrievalPolicyV1(
        .{ .top_k = 2 },
        &policy_storage,
    );
    const policy = try decodeRetrievalPolicyV1(policy_encoded);

    var index_storage: [retrieval_index_bytes]u8 = undefined;
    const index_encoded = try encodeRetrievalIndexV1(
        .{
            .generation = 3,
            .corpus_count = corpus_ids.len,
            .dimensions = 2,
            .index_id_sha256 = testDigest("retrieval test index"),
            .corpus_map_sha256 = corpus_map.batch_map_sha256,
            .visibility_sha256 = visibility.visibility_sha256,
            .embedding_policy_sha256 = embedding_policy.embedding_policy_sha256,
            .corpus_embedding_sha256 = corpus_embedding.embedding_matrix_sha256,
        },
        &index_storage,
    );
    const index = try decodeRetrievalIndexV1(index_encoded);

    var query_binding_storage: [query_binding_bytes]u8 = undefined;
    const query_binding_encoded = try encodeQueryBindingV1(
        .{
            .query_tenant = 7,
            .dimensions = 2,
            .query_object_sha256 = testDigest("retrieval test query object"),
            .query_map_sha256 = query_map.batch_map_sha256,
            .embedding_policy_sha256 = embedding_policy.embedding_policy_sha256,
            .query_embedding_sha256 = query_embedding.embedding_matrix_sha256,
            .index_descriptor_sha256 = index.index_descriptor_sha256,
            .retrieval_policy_sha256 = policy.retrieval_policy_sha256,
            .challenge_sha256 = testDigest("retrieval test challenge"),
        },
        &query_binding_storage,
    );
    const query_binding = try decodeQueryBindingV1(
        query_binding_encoded,
    );

    var output: [corpus_ids.len * retrieval_hit_bytes]u8 = undefined;
    _ = try searchTopKV1(
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
        &output,
    );
    const result = try decodeRetrievalResultV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    try std.testing.expectEqual(@as(usize, 2), result.hit_count);
    const first = try result.hit(0);
    const second = try result.hit(1);
    try std.testing.expectEqual(@as(u64, 9_101), first.item_id);
    try std.testing.expectEqual(@as(u64, 0), first.corpus_ordinal);
    try std.testing.expectEqual(@as(u64, 9_103), second.item_id);
    try std.testing.expectEqual(@as(u64, 2), second.corpus_ordinal);
    try std.testing.expectEqual(first.score, second.score);
    try std.testing.expect(
        first.score < embedding_result.q30_scale,
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[2 * retrieval_hit_bytes ..],
        0,
    ));

    var lower_ranked_result = output;
    const lower_ranked_offset = retrieval_hit_bytes;
    const lower_ranked_body = lower_ranked_result[lower_ranked_offset .. lower_ranked_offset + retrieval_hit_body_bytes];
    writeHit(lower_ranked_body, .{
        .item_id = corpus_ids[3],
        .corpus_ordinal = 3,
        .rank = 1,
        .score = try q30DotScoreV1(
            query_embedding,
            corpus_embedding,
            3,
        ),
    });
    const lower_ranked_root = hitRoot(
        index.index_descriptor_sha256,
        query_binding.query_binding_sha256,
        policy.retrieval_policy_sha256,
        lower_ranked_body,
    );
    @memcpy(
        lower_ranked_result[lower_ranked_offset + retrieval_hit_body_bytes .. lower_ranked_offset + retrieval_hit_bytes],
        &lower_ranked_root,
    );
    try std.testing.expectError(
        Error.InvalidHit,
        decodeRetrievalResultV1(
            &lower_ranked_result,
            corpus_map,
            visibility,
            embedding_policy,
            corpus_embedding,
            index,
            query_map,
            query_embedding,
            policy,
            query_binding,
        ),
    );

    var mutated_output = output;
    for (0..mutated_output.len) |byte_index| {
        mutated_output[byte_index] ^= 1;
        if (decodeRetrievalResultV1(
            &mutated_output,
            corpus_map,
            visibility,
            embedding_policy,
            corpus_embedding,
            index,
            query_map,
            query_embedding,
            policy,
            query_binding,
        )) |_| {
            return error.TestExpectedError;
        } else |_| {}
        mutated_output[byte_index] ^= 1;
    }

    var too_small = [_]u8{0xa5} ** output.len;
    try std.testing.expectError(
        Error.CapacityExceeded,
        searchTopKV1(
            corpus_map,
            visibility,
            embedding_policy,
            corpus_embedding,
            index,
            query_map,
            query_embedding,
            policy,
            query_binding,
            too_small[0 .. too_small.len - 1],
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &too_small, 0xa5));

    visibility_storage[visibility_map_header_bytes] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    visibility_storage[visibility_map_header_bytes] ^= 1;

    corpus_map_storage[tensor_result.batch_map_header_bytes] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    corpus_map_storage[tensor_result.batch_map_header_bytes] ^= 1;

    embedding_policy_storage[24] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    embedding_policy_storage[24] ^= 1;

    corpus_embedding_storage[0] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    corpus_embedding_storage[0] ^= 1;

    index_storage[24] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    index_storage[24] ^= 1;

    query_map_storage[tensor_result.batch_map_header_bytes] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    query_map_storage[tensor_result.batch_map_header_bytes] ^= 1;

    query_embedding_storage[0] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    query_embedding_storage[0] ^= 1;

    policy_storage[64] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    policy_storage[64] ^= 1;

    query_binding_storage[24] ^= 1;
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
    query_binding_storage[24] ^= 1;

    var short_visibility = visibility;
    short_visibility.encoded = short_visibility.encoded[0..7];
    try expectInvalidCompositionRejectedV1(
        &output,
        corpus_map,
        short_visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        policy,
        query_binding,
    );
}

test "authenticated retrieval wires reject every changed byte" {
    const corpus_ids = [_]u64{ 1, 2 };
    var map_storage: [96]u8 = undefined;
    const map_encoded = try tensor_result.encodeBatchMapV1(
        &corpus_ids,
        &map_storage,
    );
    const map = try tensor_result.decodeBatchMapV1(map_encoded);

    var visibility_storage: [112]u8 = undefined;
    const visibility_encoded = try encodeVisibilityMapV1(
        map_encoded,
        &[_]u64{ 0, 7 },
        &visibility_storage,
    );
    var visibility_mutated: [112]u8 = visibility_encoded[0..112].*;
    for (0..visibility_mutated.len) |index_value| {
        visibility_mutated[index_value] ^= 1;
        if (decodeAndValidateVisibilityMapV1(
            &visibility_mutated,
            map_encoded,
        )) |_| {
            return error.TestExpectedError;
        } else |_| {}
        visibility_mutated[index_value] ^= 1;
    }

    var policy_storage: [retrieval_policy_bytes]u8 = undefined;
    const policy_encoded = try encodeRetrievalPolicyV1(
        .{ .top_k = 1 },
        &policy_storage,
    );
    var policy_mutated = policy_storage;
    for (0..policy_mutated.len) |index_value| {
        policy_mutated[index_value] ^= 1;
        if (decodeRetrievalPolicyV1(&policy_mutated)) |_| {
            return error.TestExpectedError;
        } else |_| {}
        policy_mutated[index_value] ^= 1;
    }

    const root = testDigest("retrieval mutation root");
    var index_storage: [retrieval_index_bytes]u8 = undefined;
    _ = try encodeRetrievalIndexV1(
        .{
            .generation = 1,
            .corpus_count = 2,
            .dimensions = 2,
            .index_id_sha256 = root,
            .corpus_map_sha256 = map.batch_map_sha256,
            .visibility_sha256 = root,
            .embedding_policy_sha256 = root,
            .corpus_embedding_sha256 = root,
        },
        &index_storage,
    );
    for (0..index_storage.len) |index_value| {
        index_storage[index_value] ^= 1;
        if (decodeRetrievalIndexV1(&index_storage)) |_| {
            return error.TestExpectedError;
        } else |_| {}
        index_storage[index_value] ^= 1;
    }

    _ = policy_encoded;
}

test "q60 downscale uses signed nearest ties to even" {
    const unit: i128 = @as(i128, 1) << 30;
    const half = unit / 2;
    try std.testing.expectEqual(
        @as(i64, 2),
        try downscaleQ60ToQ30V1(unit + half),
    );
    try std.testing.expectEqual(
        @as(i64, 2),
        try downscaleQ60ToQ30V1(2 * unit + half),
    );
    try std.testing.expectEqual(
        @as(i64, -2),
        try downscaleQ60ToQ30V1(-unit - half),
    );
    try std.testing.expectEqual(
        @as(i64, -2),
        try downscaleQ60ToQ30V1(-2 * unit - half),
    );
}

fn testDigest(comptime text: []const u8) Digest {
    var output: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &output, .{});
    return output;
}
