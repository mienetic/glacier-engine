const std = @import("std");
const kv = @import("kv_cache.zig");
const lane_contiguous = @import("lane_contiguous_publication.zig");
const publication = @import("lane_publication_txn.zig");

pub const Digest = [32]u8;

pub const checkpoint_abi: u64 = 0x474c_544b_0000_0001;
pub const checkpoint_magic = [_]u8{ 'G', 'L', 'T', 'C', 'K', 'P', '0', '1' };
pub const checkpoint_header_bytes: usize = 544;
pub const checkpoint_footer_bytes: usize = 32;
pub const checkpoint_allowed_flags: u32 = 0;

const checkpoint_domain =
    "glacier-prepared-text-checkpoint-state-v1\x00";
const logical_kv_domain = "glacier-logical-kv-state-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BindingMismatch,
    CapacityExceeded,
    ChallengeMismatch,
    InvalidAbi,
    InvalidCheckpoint,
    InvalidFlags,
    InvalidLength,
    InvalidMagic,
    OutOfMemory,
    UnsafeDestination,
};

/// Immutable identities that a consumer already trusts. A checkpoint is not
/// allowed to select its own model, plan, artifact, or execution contract.
pub const ExpectedBindingsV1 = struct {
    local_plan_sha256: Digest,
    bound_plan_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    residency_binding_sha256: Digest,
    boundary_sha256: Digest,
    transcript_sha256: Digest,
    state_commitment_sha256: Digest,
    request_epoch: u64,
    publication_next_sequence: u64,
    prompt_tokens: u64,
    max_new_tokens: u64,
    vocab_size: u64,
    num_layers: u64,
    kv_dim: u64,
    max_kv_positions: u64,
    kv_positions: u64,
    output_count: u64,
    sampling_calls: u64,
    challenge_sha256: Digest,
};

/// Exact non-terminal prepared execution state. The transcript commitment and
/// logical KV root are deliberately separate: the former commits the
/// publication protocol, while the latter commits the concrete contiguous
/// cache bytes materialized by this codec.
pub const StateInputV1 = struct {
    local_plan_sha256: Digest,
    bound_plan_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    residency_binding_sha256: Digest,
    boundary_sha256: Digest,
    transcript_sha256: Digest,
    state_commitment_sha256: Digest,
    request_epoch: u64,
    publication_next_sequence: u64,
    prompt_tokens: u64,
    max_new_tokens: u64,
    vocab_size: u64,
    output_tokens: []const u32,
    rng_state: lane_contiguous.RngState,
    sampling_calls: u64,
    cache: *kv.KVCache,
    challenge_sha256: Digest,
};

/// Zero-copy, fully verified view over one canonical wire image. The payload
/// slices borrow `encoded`; callers must keep those bytes alive.
pub const DecodedV1 = struct {
    encoded: []const u8,
    local_plan_sha256: Digest,
    bound_plan_sha256: Digest,
    artifact_sha256: Digest,
    execution_plan_sha256: Digest,
    residency_binding_sha256: Digest,
    boundary_sha256: Digest,
    transcript_sha256: Digest,
    state_commitment_sha256: Digest,
    request_epoch: u64,
    publication_next_sequence: u64,
    prompt_tokens: usize,
    max_new_tokens: usize,
    vocab_size: u64,
    num_layers: usize,
    kv_dim: usize,
    max_kv_positions: usize,
    kv_positions: usize,
    output_count: usize,
    sampling_calls: u64,
    kv_element_count: usize,
    rng_state: lane_contiguous.RngState,
    output_state_sha256: Digest,
    rng_state_sha256: Digest,
    logical_kv_sha256: Digest,
    challenge_sha256: Digest,
    canonical_output_u32_le: []const u8,
    canonical_kv_f32_le: []const u8,
    checkpoint_sha256: Digest,
};

/// Detached computational payload reconstructed from a verified checkpoint.
/// It intentionally carries no Scheduler, Bank, permit, or publication
/// authority and therefore cannot itself resume an executing Session.
pub const DetachedPayloadV1 = struct {
    allocator: std.mem.Allocator,
    cache: kv.KVCache,
    output: []u32,
    output_len: usize,
    rng_state: lane_contiguous.RngState,
    sampling_calls: u64,
    checkpoint_sha256: Digest,

    pub fn deinit(self: *DetachedPayloadV1) void {
        self.allocator.free(self.output);
        self.cache.deinit();
        self.* = undefined;
    }

    pub fn outputTokens(self: *const DetachedPayloadV1) []const u32 {
        return self.output[0..self.output_len];
    }
};

pub fn encodedCheckpointBytesV1(
    num_layers: usize,
    kv_dim: usize,
    kv_positions: usize,
    output_count: usize,
) Error!usize {
    if (num_layers == 0 or kv_dim == 0 or kv_positions == 0 or
        output_count == 0)
        return Error.InvalidCheckpoint;
    const kv_elements = try expectedKvElementsV1(
        num_layers,
        kv_dim,
        kv_positions,
    );
    const payload_elements = std.math.add(
        usize,
        output_count,
        kv_elements,
    ) catch return Error.ArithmeticOverflow;
    const payload_bytes = std.math.mul(
        usize,
        payload_elements,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        checkpoint_header_bytes + checkpoint_footer_bytes,
        payload_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn encodeCheckpointV1(
    input: StateInputV1,
    output: []u8,
) Error![]const u8 {
    const cache = input.cache;
    const output_count = input.output_tokens.len;
    const required = try encodedCheckpointBytesV1(
        cache.num_layers,
        cache.dim,
        cache.len,
        output_count,
    );
    if (output.len < required) return Error.CapacityExceeded;
    if (cache.rowTxnActive()) return Error.InvalidCheckpoint;
    const kv_element_count = try expectedKvElementsV1(
        cache.num_layers,
        cache.dim,
        cache.len,
    );
    try validateScalarStateV1(
        input.request_epoch,
        input.publication_next_sequence,
        input.prompt_tokens,
        input.max_new_tokens,
        input.vocab_size,
        cache.max_seq,
        cache.len,
        output_count,
        input.sampling_calls,
        kv_element_count,
    );
    try validateRootsV1(&.{
        input.local_plan_sha256,
        input.bound_plan_sha256,
        input.artifact_sha256,
        input.execution_plan_sha256,
        input.residency_binding_sha256,
        input.boundary_sha256,
        input.transcript_sha256,
        input.state_commitment_sha256,
        input.challenge_sha256,
    });
    for (input.output_tokens) |token| {
        if (@as(u64, token) >= input.vocab_size)
            return Error.InvalidCheckpoint;
    }
    const destination = output[0..required];
    if (slicesOverlap(
        destination,
        std.mem.asBytes(cache),
    ) or slicesOverlap(
        destination,
        std.mem.sliceAsBytes(cache.keys),
    ) or slicesOverlap(
        destination,
        std.mem.sliceAsBytes(cache.values),
    ) or slicesOverlap(
        destination,
        std.mem.sliceAsBytes(input.output_tokens),
    )) return Error.UnsafeDestination;
    for (0..cache.num_layers) |layer| {
        if (slicesOverlap(
            destination,
            std.mem.sliceAsBytes(cache.keys[layer]),
        ) or slicesOverlap(
            destination,
            std.mem.sliceAsBytes(cache.values[layer]),
        )) return Error.UnsafeDestination;
    }

    const output_state_sha256 = lane_contiguous.outputStateSha256(
        input.output_tokens,
        false,
    );
    const rng_state_sha256 =
        lane_contiguous.rngStateSha256(input.rng_state);
    const logical_kv_sha256 =
        lane_contiguous.logicalKvPrefixSha256(cache, cache.len);
    const state_kv_sha256 = try incrementalKvStateRootV1(
        cache,
        std.math.cast(usize, input.prompt_tokens) orelse
            return Error.InvalidCheckpoint,
    );
    const expected_state = publication.makeStateCommitmentV1(
        lane_contiguous.abi,
        @intCast(cache.len),
        state_kv_sha256,
        lane_contiguous.rng_state_abi,
        rng_state_sha256,
        input.sampling_calls,
        @intCast(output_count),
        output_state_sha256,
    );
    if (!std.mem.eql(
        u8,
        &expected_state.commitment_sha256,
        &input.state_commitment_sha256,
    )) return Error.InvalidCheckpoint;

    var writer: Writer = .{ .bytes = output[0..required] };
    try writer.writeBytes(&checkpoint_magic);
    try writer.writeU64(checkpoint_abi);
    try writer.writeU64(required);
    try writer.writeU32(checkpoint_allowed_flags);
    try writer.writeU32(0);
    try writer.writeDigest(input.local_plan_sha256);
    try writer.writeDigest(input.bound_plan_sha256);
    try writer.writeDigest(input.artifact_sha256);
    try writer.writeDigest(input.execution_plan_sha256);
    try writer.writeDigest(input.residency_binding_sha256);
    try writer.writeDigest(input.boundary_sha256);
    try writer.writeDigest(input.transcript_sha256);
    try writer.writeDigest(input.state_commitment_sha256);
    try writer.writeU64(input.request_epoch);
    try writer.writeU64(input.publication_next_sequence);
    try writer.writeU64(input.prompt_tokens);
    try writer.writeU64(input.max_new_tokens);
    try writer.writeU64(input.vocab_size);
    try writer.writeU64(cache.num_layers);
    try writer.writeU64(cache.dim);
    try writer.writeU64(cache.max_seq);
    try writer.writeU64(cache.len);
    try writer.writeU64(output_count);
    try writer.writeU64(input.sampling_calls);
    try writer.writeU64(kv_element_count);
    for (input.rng_state) |word| try writer.writeU64(word);
    try writer.writeDigest(output_state_sha256);
    try writer.writeDigest(rng_state_sha256);
    try writer.writeDigest(logical_kv_sha256);
    try writer.writeDigest(input.challenge_sha256);
    if (writer.position != checkpoint_header_bytes)
        return Error.InvalidLength;
    for (input.output_tokens) |token| try writer.writeU32(token);
    for (0..cache.num_layers) |layer| {
        for (cache.keysSliceCount(layer, cache.len)) |value|
            try writer.writeU32(@bitCast(value));
        for (cache.valuesSliceCount(layer, cache.len)) |value|
            try writer.writeU32(@bitCast(value));
    }
    try writer.writeDigest(checkpointRootV1(
        output[0 .. required - checkpoint_footer_bytes],
    ));
    if (writer.position != required) return Error.InvalidLength;
    return output[0..required];
}

pub fn decodeCheckpointV1(
    encoded: []const u8,
    expected: ExpectedBindingsV1,
) Error!DecodedV1 {
    if (encoded.len < checkpoint_header_bytes + checkpoint_footer_bytes)
        return Error.InvalidLength;
    try validateRootsV1(&.{
        expected.local_plan_sha256,
        expected.bound_plan_sha256,
        expected.artifact_sha256,
        expected.execution_plan_sha256,
        expected.residency_binding_sha256,
        expected.boundary_sha256,
        expected.transcript_sha256,
        expected.state_commitment_sha256,
        expected.challenge_sha256,
    });

    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(
        u8,
        try reader.readBytes(checkpoint_magic.len),
        &checkpoint_magic,
    )) return Error.InvalidMagic;
    if (try reader.readU64() != checkpoint_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded.len) return Error.InvalidLength;
    if (try reader.readU32() != checkpoint_allowed_flags or
        try reader.readU32() != 0)
        return Error.InvalidFlags;

    const local_plan_sha256 = try reader.readDigest();
    const bound_plan_sha256 = try reader.readDigest();
    const artifact_sha256 = try reader.readDigest();
    const execution_plan_sha256 = try reader.readDigest();
    const residency_binding_sha256 = try reader.readDigest();
    const boundary_sha256 = try reader.readDigest();
    const transcript_sha256 = try reader.readDigest();
    const state_commitment_sha256 = try reader.readDigest();
    if (!std.mem.eql(
        u8,
        &local_plan_sha256,
        &expected.local_plan_sha256,
    ) or !std.mem.eql(
        u8,
        &bound_plan_sha256,
        &expected.bound_plan_sha256,
    ) or !std.mem.eql(
        u8,
        &artifact_sha256,
        &expected.artifact_sha256,
    ) or !std.mem.eql(
        u8,
        &execution_plan_sha256,
        &expected.execution_plan_sha256,
    ) or !std.mem.eql(
        u8,
        &residency_binding_sha256,
        &expected.residency_binding_sha256,
    ) or !std.mem.eql(
        u8,
        &boundary_sha256,
        &expected.boundary_sha256,
    ) or !std.mem.eql(
        u8,
        &transcript_sha256,
        &expected.transcript_sha256,
    ) or !std.mem.eql(
        u8,
        &state_commitment_sha256,
        &expected.state_commitment_sha256,
    )) return Error.BindingMismatch;

    const request_epoch = try reader.readU64();
    const publication_next_sequence = try reader.readU64();
    const prompt_tokens_u64 = try reader.readU64();
    const max_new_tokens_u64 = try reader.readU64();
    const vocab_size = try reader.readU64();
    const num_layers_u64 = try reader.readU64();
    const kv_dim_u64 = try reader.readU64();
    const max_kv_positions_u64 = try reader.readU64();
    const kv_positions_u64 = try reader.readU64();
    const output_count_u64 = try reader.readU64();
    const sampling_calls = try reader.readU64();
    const kv_element_count_u64 = try reader.readU64();
    var rng_state: lane_contiguous.RngState = undefined;
    for (&rng_state) |*word| word.* = try reader.readU64();
    const output_state_sha256 = try reader.readDigest();
    const rng_state_sha256 = try reader.readDigest();
    const logical_kv_sha256 = try reader.readDigest();
    const challenge_sha256 = try reader.readDigest();
    if (reader.position != checkpoint_header_bytes)
        return Error.InvalidLength;
    if (request_epoch != expected.request_epoch or
        publication_next_sequence !=
            expected.publication_next_sequence or
        prompt_tokens_u64 != expected.prompt_tokens or
        max_new_tokens_u64 != expected.max_new_tokens or
        vocab_size != expected.vocab_size or
        num_layers_u64 != expected.num_layers or
        kv_dim_u64 != expected.kv_dim or
        max_kv_positions_u64 != expected.max_kv_positions or
        kv_positions_u64 != expected.kv_positions or
        output_count_u64 != expected.output_count or
        sampling_calls != expected.sampling_calls)
        return Error.BindingMismatch;
    if (!std.mem.eql(
        u8,
        &challenge_sha256,
        &expected.challenge_sha256,
    )) return Error.ChallengeMismatch;

    const prompt_tokens = std.math.cast(
        usize,
        prompt_tokens_u64,
    ) orelse return Error.InvalidCheckpoint;
    const max_new_tokens = std.math.cast(
        usize,
        max_new_tokens_u64,
    ) orelse return Error.InvalidCheckpoint;
    const num_layers = std.math.cast(
        usize,
        num_layers_u64,
    ) orelse return Error.InvalidCheckpoint;
    const kv_dim = std.math.cast(
        usize,
        kv_dim_u64,
    ) orelse return Error.InvalidCheckpoint;
    const max_kv_positions = std.math.cast(
        usize,
        max_kv_positions_u64,
    ) orelse return Error.InvalidCheckpoint;
    const kv_positions = std.math.cast(
        usize,
        kv_positions_u64,
    ) orelse return Error.InvalidCheckpoint;
    const output_count = std.math.cast(
        usize,
        output_count_u64,
    ) orelse return Error.InvalidCheckpoint;
    const kv_element_count = std.math.cast(
        usize,
        kv_element_count_u64,
    ) orelse return Error.InvalidCheckpoint;
    try validateScalarStateV1(
        request_epoch,
        publication_next_sequence,
        prompt_tokens_u64,
        max_new_tokens_u64,
        vocab_size,
        max_kv_positions,
        kv_positions,
        output_count,
        sampling_calls,
        kv_element_count,
    );
    if (kv_element_count != try expectedKvElementsV1(
        num_layers,
        kv_dim,
        kv_positions,
    )) return Error.InvalidCheckpoint;
    try validateRootsV1(&.{
        boundary_sha256,
        transcript_sha256,
        state_commitment_sha256,
        output_state_sha256,
        rng_state_sha256,
        logical_kv_sha256,
        challenge_sha256,
    });

    const required = try encodedCheckpointBytesV1(
        num_layers,
        kv_dim,
        kv_positions,
        output_count,
    );
    if (encoded.len != required) return Error.InvalidLength;
    const output_bytes = std.math.mul(
        usize,
        output_count,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    const kv_bytes = std.math.mul(
        usize,
        kv_element_count,
        @sizeOf(f32),
    ) catch return Error.ArithmeticOverflow;
    const canonical_output_u32_le = try reader.readBytes(output_bytes);
    const canonical_kv_f32_le = try reader.readBytes(kv_bytes);
    const checkpoint_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &checkpoint_sha256,
        &checkpointRootV1(
            encoded[0 .. encoded.len - checkpoint_footer_bytes],
        ),
    )) return Error.InvalidCheckpoint;

    var output_reader: Reader = .{
        .bytes = canonical_output_u32_le,
    };
    var computed_output_state =
        lane_contiguous.initialOutputStateSha256();
    for (0..output_count) |index| {
        const token = try output_reader.readU32();
        if (@as(u64, token) >= vocab_size)
            return Error.InvalidCheckpoint;
        computed_output_state = publication.nextOutputStateSha256(
            computed_output_state,
            @intCast(index),
            token,
            false,
        );
    }
    const state_kv_sha256 = try incrementalKvCanonicalRootV1(
        num_layers,
        kv_dim,
        kv_positions,
        prompt_tokens,
        canonical_kv_f32_le,
    );
    const expected_state = publication.makeStateCommitmentV1(
        lane_contiguous.abi,
        @intCast(kv_positions),
        state_kv_sha256,
        lane_contiguous.rng_state_abi,
        rng_state_sha256,
        sampling_calls,
        @intCast(output_count),
        output_state_sha256,
    );
    const canonical_logical_kv_sha256 =
        try logicalKvCanonicalRootV1(
            num_layers,
            kv_dim,
            kv_positions,
            canonical_kv_f32_le,
        );
    if (output_reader.position != canonical_output_u32_le.len or
        !std.mem.eql(
            u8,
            &computed_output_state,
            &output_state_sha256,
        ) or !std.mem.eql(
        u8,
        &lane_contiguous.rngStateSha256(rng_state),
        &rng_state_sha256,
    ) or !std.mem.eql(
        u8,
        &canonical_logical_kv_sha256,
        &logical_kv_sha256,
    ) or !std.mem.eql(
        u8,
        &expected_state.commitment_sha256,
        &state_commitment_sha256,
    ))
        return Error.InvalidCheckpoint;

    return .{
        .encoded = encoded,
        .local_plan_sha256 = local_plan_sha256,
        .bound_plan_sha256 = bound_plan_sha256,
        .artifact_sha256 = artifact_sha256,
        .execution_plan_sha256 = execution_plan_sha256,
        .residency_binding_sha256 = residency_binding_sha256,
        .boundary_sha256 = boundary_sha256,
        .transcript_sha256 = transcript_sha256,
        .state_commitment_sha256 = state_commitment_sha256,
        .request_epoch = request_epoch,
        .publication_next_sequence = publication_next_sequence,
        .prompt_tokens = prompt_tokens,
        .max_new_tokens = max_new_tokens,
        .vocab_size = vocab_size,
        .num_layers = num_layers,
        .kv_dim = kv_dim,
        .max_kv_positions = max_kv_positions,
        .kv_positions = kv_positions,
        .output_count = output_count,
        .sampling_calls = sampling_calls,
        .kv_element_count = kv_element_count,
        .rng_state = rng_state,
        .output_state_sha256 = output_state_sha256,
        .rng_state_sha256 = rng_state_sha256,
        .logical_kv_sha256 = logical_kv_sha256,
        .challenge_sha256 = challenge_sha256,
        .canonical_output_u32_le = canonical_output_u32_le,
        .canonical_kv_f32_le = canonical_kv_f32_le,
        .checkpoint_sha256 = checkpoint_sha256,
    };
}

fn revalidateDecodedV1(decoded: DecodedV1) Error!DecodedV1 {
    const verified = try decodeCheckpointV1(decoded.encoded, .{
        .local_plan_sha256 = decoded.local_plan_sha256,
        .bound_plan_sha256 = decoded.bound_plan_sha256,
        .artifact_sha256 = decoded.artifact_sha256,
        .execution_plan_sha256 = decoded.execution_plan_sha256,
        .residency_binding_sha256 = decoded.residency_binding_sha256,
        .boundary_sha256 = decoded.boundary_sha256,
        .transcript_sha256 = decoded.transcript_sha256,
        .state_commitment_sha256 = decoded.state_commitment_sha256,
        .request_epoch = decoded.request_epoch,
        .publication_next_sequence = decoded.publication_next_sequence,
        .prompt_tokens = @intCast(decoded.prompt_tokens),
        .max_new_tokens = @intCast(decoded.max_new_tokens),
        .vocab_size = decoded.vocab_size,
        .num_layers = @intCast(decoded.num_layers),
        .kv_dim = @intCast(decoded.kv_dim),
        .max_kv_positions = @intCast(decoded.max_kv_positions),
        .kv_positions = @intCast(decoded.kv_positions),
        .output_count = @intCast(decoded.output_count),
        .sampling_calls = decoded.sampling_calls,
        .challenge_sha256 = decoded.challenge_sha256,
    });
    if (!decodedViewsEqualV1(decoded, verified))
        return Error.InvalidCheckpoint;
    return verified;
}

fn decodedViewsEqualV1(a: DecodedV1, b: DecodedV1) bool {
    return std.mem.eql(u8, a.encoded, b.encoded) and
        std.mem.eql(
            u8,
            &a.local_plan_sha256,
            &b.local_plan_sha256,
        ) and std.mem.eql(
        u8,
        &a.bound_plan_sha256,
        &b.bound_plan_sha256,
    ) and std.mem.eql(
        u8,
        &a.artifact_sha256,
        &b.artifact_sha256,
    ) and std.mem.eql(
        u8,
        &a.execution_plan_sha256,
        &b.execution_plan_sha256,
    ) and std.mem.eql(
        u8,
        &a.residency_binding_sha256,
        &b.residency_binding_sha256,
    ) and std.mem.eql(
        u8,
        &a.boundary_sha256,
        &b.boundary_sha256,
    ) and std.mem.eql(
        u8,
        &a.transcript_sha256,
        &b.transcript_sha256,
    ) and std.mem.eql(
        u8,
        &a.state_commitment_sha256,
        &b.state_commitment_sha256,
    ) and a.request_epoch == b.request_epoch and
        a.publication_next_sequence ==
            b.publication_next_sequence and
        a.prompt_tokens == b.prompt_tokens and
        a.max_new_tokens == b.max_new_tokens and
        a.vocab_size == b.vocab_size and
        a.num_layers == b.num_layers and
        a.kv_dim == b.kv_dim and
        a.max_kv_positions == b.max_kv_positions and
        a.kv_positions == b.kv_positions and
        a.output_count == b.output_count and
        a.sampling_calls == b.sampling_calls and
        a.kv_element_count == b.kv_element_count and
        std.meta.eql(a.rng_state, b.rng_state) and
        std.mem.eql(
            u8,
            &a.output_state_sha256,
            &b.output_state_sha256,
        ) and std.mem.eql(
        u8,
        &a.rng_state_sha256,
        &b.rng_state_sha256,
    ) and std.mem.eql(
        u8,
        &a.logical_kv_sha256,
        &b.logical_kv_sha256,
    ) and std.mem.eql(
        u8,
        &a.challenge_sha256,
        &b.challenge_sha256,
    ) and std.mem.eql(
        u8,
        a.canonical_output_u32_le,
        b.canonical_output_u32_le,
    ) and std.mem.eql(
        u8,
        a.canonical_kv_f32_le,
        b.canonical_kv_f32_le,
    ) and std.mem.eql(
        u8,
        &a.checkpoint_sha256,
        &b.checkpoint_sha256,
    );
}

pub fn materializeDetachedV1(
    allocator: std.mem.Allocator,
    decoded: DecodedV1,
) Error!DetachedPayloadV1 {
    const verified = try revalidateDecodedV1(decoded);
    var cache = kv.KVCache.init(
        allocator,
        verified.num_layers,
        verified.kv_dim,
        verified.max_kv_positions,
    ) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.InvalidCheckpoint,
    };
    errdefer cache.deinit();
    for (0..cache.num_layers) |layer| {
        @memset(cache.keys[layer], 0);
        @memset(cache.values[layer], 0);
    }

    const output = allocator.alloc(
        u32,
        verified.max_new_tokens,
    ) catch return Error.OutOfMemory;
    errdefer allocator.free(output);
    @memset(output, 0);

    var output_reader: Reader = .{
        .bytes = verified.canonical_output_u32_le,
    };
    for (output[0..verified.output_count]) |*token|
        token.* = try output_reader.readU32();
    if (output_reader.position !=
        verified.canonical_output_u32_le.len)
        return Error.InvalidCheckpoint;

    var kv_reader: Reader = .{
        .bytes = verified.canonical_kv_f32_le,
    };
    for (0..cache.num_layers) |layer| {
        const keys = cache.keysSliceCount(
            layer,
            verified.kv_positions,
        );
        const values = cache.valuesSliceCount(
            layer,
            verified.kv_positions,
        );
        for (keys) |*value|
            value.* = @bitCast(try kv_reader.readU32());
        for (values) |*value|
            value.* = @bitCast(try kv_reader.readU32());
    }
    if (kv_reader.position != verified.canonical_kv_f32_le.len)
        return Error.InvalidCheckpoint;
    cache.commitRows(verified.kv_positions);

    if (!std.mem.eql(
        u8,
        &lane_contiguous.logicalKvPrefixSha256(
            &cache,
            cache.len,
        ),
        &verified.logical_kv_sha256,
    ) or !std.mem.eql(
        u8,
        &lane_contiguous.outputStateSha256(
            output[0..verified.output_count],
            false,
        ),
        &verified.output_state_sha256,
    ) or !std.mem.eql(
        u8,
        &lane_contiguous.rngStateSha256(verified.rng_state),
        &verified.rng_state_sha256,
    )) return Error.InvalidCheckpoint;

    return .{
        .allocator = allocator,
        .cache = cache,
        .output = output,
        .output_len = verified.output_count,
        .rng_state = verified.rng_state,
        .sampling_calls = verified.sampling_calls,
        .checkpoint_sha256 = verified.checkpoint_sha256,
    };
}

pub fn checkpointRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checkpoint_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn logicalKvCanonicalRootV1(
    num_layers: usize,
    kv_dim: usize,
    kv_positions: usize,
    canonical_f32_le: []const u8,
) Error!Digest {
    const elements = try expectedKvElementsV1(
        num_layers,
        kv_dim,
        kv_positions,
    );
    const expected_bytes = std.math.mul(
        usize,
        elements,
        @sizeOf(f32),
    ) catch return Error.ArithmeticOverflow;
    if (canonical_f32_le.len != expected_bytes)
        return Error.InvalidCheckpoint;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(logical_kv_domain);
    hashU64(&hash, @intCast(num_layers));
    hashU64(&hash, @intCast(kv_dim));
    hashU64(&hash, @intCast(kv_positions));
    var reader: Reader = .{ .bytes = canonical_f32_le };
    while (reader.position != reader.bytes.len)
        hashU32(&hash, try reader.readU32());
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Reconstruct the publication protocol's incremental KV state from a
/// concrete cache. The prefill prefix starts as a full logical root; each
/// decode row after the first output is then folded into the protocol chain.
pub fn incrementalKvStateRootV1(
    cache: *kv.KVCache,
    prompt_tokens: usize,
) Error!Digest {
    if (cache.rowTxnActive() or prompt_tokens == 0 or
        prompt_tokens > cache.len)
        return Error.InvalidCheckpoint;
    var state = lane_contiguous.logicalKvPrefixSha256(
        cache,
        prompt_tokens,
    );
    for (prompt_tokens..cache.len) |position| {
        var row_hash = std.crypto.hash.sha2.Sha256.init(.{});
        row_hash.update("glacier-contiguous-kv-row-v1\x00");
        hashU64(&row_hash, lane_contiguous.abi);
        hashU64(&row_hash, @intCast(cache.num_layers));
        hashU64(&row_hash, @intCast(cache.dim));
        hashU64(&row_hash, @intCast(position));
        const start = std.math.mul(usize, position, cache.dim) catch
            return Error.ArithmeticOverflow;
        const end = std.math.add(usize, start, cache.dim) catch
            return Error.ArithmeticOverflow;
        for (0..cache.num_layers) |layer| {
            for (cache.keys[layer][start..end]) |value|
                hashU32(&row_hash, @bitCast(value));
            for (cache.values[layer][start..end]) |value|
                hashU32(&row_hash, @bitCast(value));
        }
        var row_sha256: Digest = undefined;
        row_hash.final(&row_sha256);
        state = publication.nextKvStateSha256(
            state,
            @intCast(position),
            row_sha256,
        );
    }
    return state;
}

pub fn incrementalKvCanonicalRootV1(
    num_layers: usize,
    kv_dim: usize,
    kv_positions: usize,
    prompt_tokens: usize,
    canonical_f32_le: []const u8,
) Error!Digest {
    const elements = try expectedKvElementsV1(
        num_layers,
        kv_dim,
        kv_positions,
    );
    const expected_bytes = std.math.mul(
        usize,
        elements,
        @sizeOf(f32),
    ) catch return Error.ArithmeticOverflow;
    if (canonical_f32_le.len != expected_bytes or
        prompt_tokens == 0 or prompt_tokens > kv_positions)
        return Error.InvalidCheckpoint;

    var initial_hash = std.crypto.hash.sha2.Sha256.init(.{});
    initial_hash.update(logical_kv_domain);
    hashU64(&initial_hash, @intCast(num_layers));
    hashU64(&initial_hash, @intCast(kv_dim));
    hashU64(&initial_hash, @intCast(prompt_tokens));
    for (0..num_layers) |layer| {
        for (0..prompt_tokens) |position| {
            for (0..kv_dim) |dimension| {
                hashU32(
                    &initial_hash,
                    try canonicalKvBitsAt(
                        canonical_f32_le,
                        num_layers,
                        kv_dim,
                        kv_positions,
                        layer,
                        false,
                        position,
                        dimension,
                    ),
                );
            }
        }
        for (0..prompt_tokens) |position| {
            for (0..kv_dim) |dimension| {
                hashU32(
                    &initial_hash,
                    try canonicalKvBitsAt(
                        canonical_f32_le,
                        num_layers,
                        kv_dim,
                        kv_positions,
                        layer,
                        true,
                        position,
                        dimension,
                    ),
                );
            }
        }
    }
    var state: Digest = undefined;
    initial_hash.final(&state);

    for (prompt_tokens..kv_positions) |position| {
        var row_hash = std.crypto.hash.sha2.Sha256.init(.{});
        row_hash.update("glacier-contiguous-kv-row-v1\x00");
        hashU64(&row_hash, lane_contiguous.abi);
        hashU64(&row_hash, @intCast(num_layers));
        hashU64(&row_hash, @intCast(kv_dim));
        hashU64(&row_hash, @intCast(position));
        for (0..num_layers) |layer| {
            for (0..kv_dim) |dimension| {
                hashU32(
                    &row_hash,
                    try canonicalKvBitsAt(
                        canonical_f32_le,
                        num_layers,
                        kv_dim,
                        kv_positions,
                        layer,
                        false,
                        position,
                        dimension,
                    ),
                );
            }
            for (0..kv_dim) |dimension| {
                hashU32(
                    &row_hash,
                    try canonicalKvBitsAt(
                        canonical_f32_le,
                        num_layers,
                        kv_dim,
                        kv_positions,
                        layer,
                        true,
                        position,
                        dimension,
                    ),
                );
            }
        }
        var row_sha256: Digest = undefined;
        row_hash.final(&row_sha256);
        state = publication.nextKvStateSha256(
            state,
            @intCast(position),
            row_sha256,
        );
    }
    return state;
}

fn canonicalKvBitsAt(
    canonical_f32_le: []const u8,
    num_layers: usize,
    kv_dim: usize,
    kv_positions: usize,
    layer: usize,
    values: bool,
    position: usize,
    dimension: usize,
) Error!u32 {
    if (layer >= num_layers or position >= kv_positions or
        dimension >= kv_dim)
        return Error.InvalidCheckpoint;
    const plane_elements = std.math.mul(
        usize,
        kv_positions,
        kv_dim,
    ) catch return Error.ArithmeticOverflow;
    const layer_elements = std.math.mul(
        usize,
        plane_elements,
        2,
    ) catch return Error.ArithmeticOverflow;
    var element = std.math.mul(
        usize,
        layer,
        layer_elements,
    ) catch return Error.ArithmeticOverflow;
    if (values) element = std.math.add(
        usize,
        element,
        plane_elements,
    ) catch return Error.ArithmeticOverflow;
    element = std.math.add(
        usize,
        element,
        std.math.mul(usize, position, kv_dim) catch
            return Error.ArithmeticOverflow,
    ) catch return Error.ArithmeticOverflow;
    element = std.math.add(
        usize,
        element,
        dimension,
    ) catch return Error.ArithmeticOverflow;
    const byte_offset = std.math.mul(
        usize,
        element,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    const end = std.math.add(
        usize,
        byte_offset,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    if (end > canonical_f32_le.len)
        return Error.InvalidCheckpoint;
    return std.mem.readInt(
        u32,
        canonical_f32_le[byte_offset..end][0..4],
        .little,
    );
}

fn expectedKvElementsV1(
    num_layers: usize,
    kv_dim: usize,
    kv_positions: usize,
) Error!usize {
    if (num_layers == 0 or kv_dim == 0 or kv_positions == 0)
        return Error.InvalidCheckpoint;
    return std.math.mul(
        usize,
        std.math.mul(
            usize,
            std.math.mul(usize, num_layers, 2) catch
                return Error.ArithmeticOverflow,
            kv_positions,
        ) catch return Error.ArithmeticOverflow,
        kv_dim,
    ) catch return Error.ArithmeticOverflow;
}

fn validateScalarStateV1(
    request_epoch: u64,
    publication_next_sequence: u64,
    prompt_tokens: u64,
    max_new_tokens: u64,
    vocab_size: u64,
    max_kv_positions: usize,
    kv_positions: usize,
    output_count: usize,
    sampling_calls: u64,
    kv_element_count: usize,
) Error!void {
    if (request_epoch == 0 or prompt_tokens == 0 or
        max_new_tokens == 0 or
        vocab_size < 2 or
        vocab_size > @as(u64, std.math.maxInt(u32)) + 1 or
        output_count == 0 or
        @as(u64, @intCast(output_count)) >= max_new_tokens or
        publication_next_sequence !=
            @as(u64, @intCast(output_count)) or
        sampling_calls != @as(u64, @intCast(output_count)) or
        kv_element_count == 0)
        return Error.InvalidCheckpoint;
    const expected_kv_positions = std.math.add(
        u64,
        prompt_tokens,
        @as(u64, @intCast(output_count)) - 1,
    ) catch return Error.ArithmeticOverflow;
    const expected_max_kv_positions = std.math.add(
        u64,
        prompt_tokens,
        max_new_tokens - 1,
    ) catch return Error.ArithmeticOverflow;
    if (publication_next_sequence == 0 or
        expected_kv_positions !=
            @as(u64, @intCast(kv_positions)) or
        expected_max_kv_positions !=
            @as(u64, @intCast(max_kv_positions)) or
        kv_positions > max_kv_positions)
        return Error.InvalidCheckpoint;
}

fn validateRootsV1(roots: []const Digest) Error!void {
    for (roots) |root| {
        if (isZero(root)) return Error.InvalidCheckpoint;
    }
}

fn hashU32(hash: anytype, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch
        std.math.maxInt(usize);
    const b_end = std.math.add(usize, b_start, b.len) catch
        std.math.maxInt(usize);
    return a_start < b_end and b_start < a_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(usize, self.position, value.len) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: anytype) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(value), .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        const end = std.math.add(usize, self.position, length) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        const value = self.bytes[self.position..end];
        self.position = end;
        return value;
    }

    fn readU32(self: *Reader) Error!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(value.len));
        return value;
    }
};

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn digestFromHex(hex: []const u8) !Digest {
    var output: Digest = undefined;
    _ = try std.fmt.hexToBytes(&output, hex);
    return output;
}

test "prepared text checkpoint wire matches independent bit-pattern golden" {
    const testing = std.testing;
    var cache = try kv.KVCache.init(testing.allocator, 2, 2, 7);
    defer cache.deinit();
    const l0_keys = [_]u32{
        0x0000_0000,
        0x8000_0000,
        0x3f80_0000,
        0xbf80_0000,
        0x0000_0001,
        0x007f_ffff,
        0x0080_0000,
        0x7f7f_ffff,
    };
    const l0_values = [_]u32{
        0x7f80_0000,
        0xff80_0000,
        0x7fc0_0001,
        0xffc0_1234,
        0x0102_0304,
        0x1122_3344,
        0xa1b2_c3d4,
        0xffff_ffff,
    };
    const l1_keys = [_]u32{
        0x4000_0000,
        0xc000_0000,
        0x3f00_0000,
        0xbf00_0000,
        0x4049_0fdb,
        0xc049_0fdb,
        0x3eaa_aaab,
        0xbeaa_aaab,
    };
    const l1_values = [_]u32{
        0x0080_0001,
        0x8080_0001,
        0x7f00_0001,
        0xff00_0001,
        0x1234_5678,
        0x8765_4321,
        0xdead_beef,
        0x0bad_f00d,
    };
    const key_bits = [_][]const u32{ &l0_keys, &l1_keys };
    const value_bits = [_][]const u32{ &l0_values, &l1_values };
    for (0..cache.num_layers) |layer| {
        var keys: [8]f32 = undefined;
        var values: [8]f32 = undefined;
        for (&keys, key_bits[layer]) |*value, bits|
            value.* = @bitCast(bits);
        for (&values, value_bits[layer]) |*value, bits|
            value.* = @bitCast(bits);
        _ = try cache.appendRows(layer, &keys, &values, 4);
    }
    cache.commitRows(4);

    const output_tokens = [_]u32{ 0x0102_0304, 0x0001_0002 };
    const rng_state: lane_contiguous.RngState = .{
        0x0102_0304_0506_0708,
        0x1122_3344_5566_7788,
        0x8000_0000_0000_0001,
        0xffff_ffff_ffff_ffff,
    };
    const state_commitment_sha256 = try digestFromHex(
        "7f5a4e56ead8de9a227f4fdb00a806370fc4ed0ed1c126f825548ba1349d0abe",
    );
    const expected: ExpectedBindingsV1 = .{
        .local_plan_sha256 = filledDigest(0x11),
        .bound_plan_sha256 = filledDigest(0x22),
        .artifact_sha256 = filledDigest(0x33),
        .execution_plan_sha256 = filledDigest(0x44),
        .residency_binding_sha256 = filledDigest(0x55),
        .boundary_sha256 = filledDigest(0x66),
        .transcript_sha256 = filledDigest(0x77),
        .state_commitment_sha256 = state_commitment_sha256,
        .request_epoch = 0x0102_0304_0506_0708,
        .publication_next_sequence = 2,
        .prompt_tokens = 3,
        .max_new_tokens = 5,
        .vocab_size = @as(u64, std.math.maxInt(u32)) + 1,
        .num_layers = 2,
        .kv_dim = 2,
        .max_kv_positions = 7,
        .kv_positions = 4,
        .output_count = 2,
        .sampling_calls = 2,
        .challenge_sha256 = filledDigest(0xcc),
    };
    const required = try encodedCheckpointBytesV1(2, 2, 4, 2);
    try testing.expectEqual(@as(usize, 712), required);
    const encoded = try testing.allocator.alloc(u8, required);
    defer testing.allocator.free(encoded);
    _ = try encodeCheckpointV1(.{
        .local_plan_sha256 = expected.local_plan_sha256,
        .bound_plan_sha256 = expected.bound_plan_sha256,
        .artifact_sha256 = expected.artifact_sha256,
        .execution_plan_sha256 = expected.execution_plan_sha256,
        .residency_binding_sha256 = expected.residency_binding_sha256,
        .boundary_sha256 = expected.boundary_sha256,
        .transcript_sha256 = expected.transcript_sha256,
        .state_commitment_sha256 = expected.state_commitment_sha256,
        .request_epoch = 0x0102_0304_0506_0708,
        .publication_next_sequence = 2,
        .prompt_tokens = 3,
        .max_new_tokens = 5,
        .vocab_size = @as(u64, std.math.maxInt(u32)) + 1,
        .output_tokens = &output_tokens,
        .rng_state = rng_state,
        .sampling_calls = 2,
        .cache = &cache,
        .challenge_sha256 = expected.challenge_sha256,
    }, encoded);
    const decoded = try decodeCheckpointV1(encoded, expected);
    try testing.expectEqualSlices(
        u8,
        &try digestFromHex(
            "03cbe74495cfa114143c7769dfc9532f2378c8f57769c9bd9a14e28809ac6c82",
        ),
        &decoded.output_state_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &try digestFromHex(
            "b833da6866b013a35f47013a8aaf72d53473487ad8d8f6c5d1f5fc62647db5c2",
        ),
        &decoded.rng_state_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &try digestFromHex(
            "f2888bdf0a9fd9518164ce850f3f0cdfe9772be661e2093c54a111970e9f3550",
        ),
        &decoded.logical_kv_sha256,
    );
    try testing.expectEqualSlices(
        u8,
        &try digestFromHex(
            "59aaeec3bd3ef69e0aef0e42ad83275866163ae95290bc7578c810845f5affdc",
        ),
        &decoded.checkpoint_sha256,
    );
}

test "prepared text checkpoint is canonical and detached materialization is exact" {
    const testing = std.testing;
    var cache = try kv.KVCache.init(testing.allocator, 2, 2, 7);
    defer cache.deinit();
    for (0..cache.num_layers) |layer| {
        var keys: [8]f32 = undefined;
        var values: [8]f32 = undefined;
        for (&keys, 0..) |*value, index| {
            const bits: u32 = @intCast(
                0x3f00_0000 + layer * 0x1000 + index,
            );
            value.* = @bitCast(bits);
        }
        for (&values, 0..) |*value, index| {
            const bits: u32 = @intCast(
                0xbf00_0000 + layer * 0x1000 + index,
            );
            value.* = @bitCast(bits);
        }
        _ = try cache.appendRows(layer, &keys, &values, 4);
    }
    cache.commitRows(4);

    const output_tokens = [_]u32{ 7, 11 };
    const rng_state: lane_contiguous.RngState = .{ 13, 17, 19, 23 };
    const state_commitment_sha256 =
        publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            @intCast(cache.len),
            try incrementalKvStateRootV1(&cache, 3),
            lane_contiguous.rng_state_abi,
            lane_contiguous.rngStateSha256(rng_state),
            2,
            output_tokens.len,
            lane_contiguous.outputStateSha256(
                &output_tokens,
                false,
            ),
        ).commitment_sha256;
    const expected: ExpectedBindingsV1 = .{
        .local_plan_sha256 = filledDigest(0x11),
        .bound_plan_sha256 = filledDigest(0x12),
        .artifact_sha256 = filledDigest(0x13),
        .execution_plan_sha256 = filledDigest(0x14),
        .residency_binding_sha256 = filledDigest(0x15),
        .boundary_sha256 = filledDigest(0x16),
        .transcript_sha256 = filledDigest(0x17),
        .state_commitment_sha256 = state_commitment_sha256,
        .request_epoch = 29,
        .publication_next_sequence = 2,
        .prompt_tokens = 3,
        .max_new_tokens = 5,
        .vocab_size = 64,
        .num_layers = 2,
        .kv_dim = 2,
        .max_kv_positions = 7,
        .kv_positions = 4,
        .output_count = 2,
        .sampling_calls = 2,
        .challenge_sha256 = filledDigest(0x1a),
    };
    const required = try encodedCheckpointBytesV1(2, 2, 4, 2);
    try testing.expectEqual(@as(usize, 712), required);
    const encoded = try testing.allocator.alloc(u8, required);
    defer testing.allocator.free(encoded);
    const canonical = try encodeCheckpointV1(.{
        .local_plan_sha256 = expected.local_plan_sha256,
        .bound_plan_sha256 = expected.bound_plan_sha256,
        .artifact_sha256 = expected.artifact_sha256,
        .execution_plan_sha256 = expected.execution_plan_sha256,
        .residency_binding_sha256 = expected.residency_binding_sha256,
        .boundary_sha256 = expected.boundary_sha256,
        .transcript_sha256 = expected.transcript_sha256,
        .state_commitment_sha256 = expected.state_commitment_sha256,
        .request_epoch = 29,
        .publication_next_sequence = 2,
        .prompt_tokens = 3,
        .max_new_tokens = 5,
        .vocab_size = 64,
        .output_tokens = &output_tokens,
        .rng_state = rng_state,
        .sampling_calls = 2,
        .cache = &cache,
        .challenge_sha256 = expected.challenge_sha256,
    }, encoded);
    try testing.expectEqual(required, canonical.len);

    const decoded = try decodeCheckpointV1(canonical, expected);
    try testing.expectEqual(@as(usize, 4), decoded.kv_positions);
    try testing.expectEqual(@as(usize, 32), decoded.kv_element_count);
    try testing.expectEqual(rng_state, decoded.rng_state);
    try testing.expectEqualSlices(
        u8,
        &lane_contiguous.logicalKvPrefixSha256(&cache, cache.len),
        &decoded.logical_kv_sha256,
    );

    var forged_decoded = decoded;
    forged_decoded.sampling_calls += 1;
    try testing.expectError(
        error.BindingMismatch,
        materializeDetachedV1(testing.allocator, forged_decoded),
    );
    forged_decoded = decoded;
    forged_decoded.max_new_tokens = 1;
    try testing.expectError(
        error.BindingMismatch,
        materializeDetachedV1(testing.allocator, forged_decoded),
    );
    forged_decoded = decoded;
    forged_decoded.checkpoint_sha256[0] ^= 0x01;
    try testing.expectError(
        error.InvalidCheckpoint,
        materializeDetachedV1(testing.allocator, forged_decoded),
    );

    var detached = try materializeDetachedV1(
        testing.allocator,
        decoded,
    );
    defer detached.deinit();
    try testing.expectEqualSlices(
        u32,
        &output_tokens,
        detached.outputTokens(),
    );
    try testing.expectEqual(cache.len, detached.cache.len);
    try testing.expectEqualSlices(
        u8,
        &lane_contiguous.logicalKvPrefixSha256(&cache, cache.len),
        &lane_contiguous.logicalKvPrefixSha256(
            &detached.cache,
            detached.cache.len,
        ),
    );
    for (0..detached.cache.num_layers) |layer| {
        for (
            detached.cache.keys[layer][detached.cache.len * detached.cache.dim ..],
        ) |value| try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(value)));
        for (
            detached.cache.values[layer][detached.cache.len * detached.cache.dim ..],
        ) |value| try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(value)));
    }
    for (detached.output[detached.output_len..]) |token|
        try testing.expectEqual(@as(u32, 0), token);
}

test "prepared text checkpoint rejects destinations aliased to cache storage" {
    const testing = std.testing;
    var cache = try kv.KVCache.init(testing.allocator, 1, 1, 1024);
    defer cache.deinit();
    const key = [_]f32{1};
    const value = [_]f32{-1};
    _ = try cache.appendRows(0, &key, &value, 1);
    cache.commit();

    const tokens = [_]u32{5};
    const rng_state: lane_contiguous.RngState = .{ 1, 2, 3, 4 };
    const state_commitment_sha256 =
        publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            @intCast(cache.len),
            try incrementalKvStateRootV1(&cache, 1),
            lane_contiguous.rng_state_abi,
            lane_contiguous.rngStateSha256(rng_state),
            1,
            tokens.len,
            lane_contiguous.outputStateSha256(&tokens, false),
        ).commitment_sha256;
    const input: StateInputV1 = .{
        .local_plan_sha256 = filledDigest(0x31),
        .bound_plan_sha256 = filledDigest(0x32),
        .artifact_sha256 = filledDigest(0x33),
        .execution_plan_sha256 = filledDigest(0x34),
        .residency_binding_sha256 = filledDigest(0x35),
        .boundary_sha256 = filledDigest(0x36),
        .transcript_sha256 = filledDigest(0x37),
        .state_commitment_sha256 = state_commitment_sha256,
        .request_epoch = 41,
        .publication_next_sequence = 1,
        .prompt_tokens = 1,
        .max_new_tokens = 1024,
        .vocab_size = 32,
        .output_tokens = &tokens,
        .rng_state = rng_state,
        .sampling_calls = 1,
        .cache = &cache,
        .challenge_sha256 = filledDigest(0x3a),
    };
    const required = try encodedCheckpointBytesV1(1, 1, 1, 1);
    const key_bytes = std.mem.sliceAsBytes(cache.keys[0]);
    const value_bytes = std.mem.sliceAsBytes(cache.values[0]);
    try testing.expect(key_bytes.len >= required);
    try testing.expect(value_bytes.len >= required);
    try testing.expectError(
        error.UnsafeDestination,
        encodeCheckpointV1(input, key_bytes[0..required]),
    );
    try testing.expectError(
        error.UnsafeDestination,
        encodeCheckpointV1(input, value_bytes[0..required]),
    );

    if (@sizeOf([]f32) > 8) {
        var descriptor_cache = try kv.KVCache.init(
            testing.allocator,
            80,
            1,
            2,
        );
        defer descriptor_cache.deinit();
        for (0..descriptor_cache.num_layers) |layer|
            _ = try descriptor_cache.appendRows(
                layer,
                &key,
                &value,
                1,
            );
        descriptor_cache.commit();
        const descriptor_required =
            try encodedCheckpointBytesV1(80, 1, 1, 1);
        const key_descriptors =
            std.mem.sliceAsBytes(descriptor_cache.keys);
        const value_descriptors =
            std.mem.sliceAsBytes(descriptor_cache.values);
        try testing.expect(key_descriptors.len >= descriptor_required);
        try testing.expect(
            value_descriptors.len >= descriptor_required,
        );
        const descriptor_input: StateInputV1 = .{
            .local_plan_sha256 = filledDigest(0x41),
            .bound_plan_sha256 = filledDigest(0x42),
            .artifact_sha256 = filledDigest(0x43),
            .execution_plan_sha256 = filledDigest(0x44),
            .residency_binding_sha256 = filledDigest(0x45),
            .boundary_sha256 = filledDigest(0x46),
            .transcript_sha256 = filledDigest(0x47),
            .state_commitment_sha256 = filledDigest(0x48),
            .request_epoch = 43,
            .publication_next_sequence = 1,
            .prompt_tokens = 1,
            .max_new_tokens = 2,
            .vocab_size = 32,
            .output_tokens = &tokens,
            .rng_state = rng_state,
            .sampling_calls = 1,
            .cache = &descriptor_cache,
            .challenge_sha256 = filledDigest(0x4a),
        };
        try testing.expectError(
            error.UnsafeDestination,
            encodeCheckpointV1(
                descriptor_input,
                key_descriptors[0..descriptor_required],
            ),
        );
        try testing.expectError(
            error.UnsafeDestination,
            encodeCheckpointV1(
                descriptor_input,
                value_descriptors[0..descriptor_required],
            ),
        );
    }
}

test "prepared text checkpoint rejects every committed region mutation" {
    const testing = std.testing;
    var cache = try kv.KVCache.init(testing.allocator, 1, 1, 3);
    defer cache.deinit();
    const key = [_]f32{1};
    const value = [_]f32{-1};
    _ = try cache.appendRows(0, &key, &value, 1);
    cache.commit();
    const tokens = [_]u32{5};
    const state_commitment_sha256 =
        publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            @intCast(cache.len),
            try incrementalKvStateRootV1(&cache, 1),
            lane_contiguous.rng_state_abi,
            lane_contiguous.rngStateSha256(.{ 1, 2, 3, 4 }),
            1,
            tokens.len,
            lane_contiguous.outputStateSha256(&tokens, false),
        ).commitment_sha256;
    const expected: ExpectedBindingsV1 = .{
        .local_plan_sha256 = filledDigest(0x21),
        .bound_plan_sha256 = filledDigest(0x22),
        .artifact_sha256 = filledDigest(0x23),
        .execution_plan_sha256 = filledDigest(0x24),
        .residency_binding_sha256 = filledDigest(0x25),
        .boundary_sha256 = filledDigest(0x26),
        .transcript_sha256 = filledDigest(0x27),
        .state_commitment_sha256 = state_commitment_sha256,
        .request_epoch = 31,
        .publication_next_sequence = 1,
        .prompt_tokens = 1,
        .max_new_tokens = 3,
        .vocab_size = 32,
        .num_layers = 1,
        .kv_dim = 1,
        .max_kv_positions = 3,
        .kv_positions = 1,
        .output_count = 1,
        .sampling_calls = 1,
        .challenge_sha256 = filledDigest(0x2a),
    };
    const required = try encodedCheckpointBytesV1(1, 1, 1, 1);
    const encoded = try testing.allocator.alloc(u8, required);
    defer testing.allocator.free(encoded);
    _ = try encodeCheckpointV1(.{
        .local_plan_sha256 = expected.local_plan_sha256,
        .bound_plan_sha256 = expected.bound_plan_sha256,
        .artifact_sha256 = expected.artifact_sha256,
        .execution_plan_sha256 = expected.execution_plan_sha256,
        .residency_binding_sha256 = expected.residency_binding_sha256,
        .boundary_sha256 = expected.boundary_sha256,
        .transcript_sha256 = expected.transcript_sha256,
        .state_commitment_sha256 = expected.state_commitment_sha256,
        .request_epoch = 31,
        .publication_next_sequence = 1,
        .prompt_tokens = 1,
        .max_new_tokens = 3,
        .vocab_size = 32,
        .output_tokens = &tokens,
        .rng_state = .{ 1, 2, 3, 4 },
        .sampling_calls = 1,
        .cache = &cache,
        .challenge_sha256 = expected.challenge_sha256,
    }, encoded);
    _ = try decodeCheckpointV1(encoded, expected);

    for (0..encoded.len) |offset| {
        encoded[offset] ^= 0x01;
        if (decodeCheckpointV1(encoded, expected)) |_| {
            return error.TestUnexpectedResult;
        } else |_| {}
        encoded[offset] ^= 0x01;
        _ = try decodeCheckpointV1(encoded, expected);
    }
}
