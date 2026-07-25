//! Receipt-independent terminal semantics for prepared text continuation.
//!
//! A terminal `ResultEnvelopeV1` intentionally binds the live ResourceBank
//! receipt that published it. That makes the raw result and evidence roots
//! authority-specific and therefore unsuitable for byte equality across a
//! source/target ownership remap. This record projects only the terminal
//! model/request identity and numerical state that must remain equal.

const std = @import("std");
const session = @import("prepared_text_session.zig");
const publication = @import("lane_publication_txn.zig");

pub const Digest = [32]u8;
pub const semantic_abi: u64 = 0x4750_5453_0000_0001;
pub const semantic_magic = [_]u8{ 'G', 'P', 'T', 'S', 'E', 'M', '1', 0 };
pub const semantic_bytes: usize = 640;
pub const semantic_body_bytes: usize = semantic_bytes - 32;
pub const allowed_flags: u64 = 0;

const semantic_domain =
    "glacier-prepared-text-terminal-semantic-v1\x00";
const output_domain =
    "glacier-prepared-text-terminal-output-semantic-v1\x00";

pub const Error = error{
    InvalidSemantic,
    InvalidTerminalBoundary,
    InvalidLength,
    UnsafeDestination,
    ArithmeticOverflow,
};

/// Canonical equality surface for uninterrupted and ownership-remapped
/// prepared-text execution. Publication transcript, sequence base, receipt,
/// Scheduler identity, Bank epoch, execution-plan generation, residency,
/// ownership, and result-envelope root are deliberately absent because those
/// values attest authority rather than model semantics.
pub const TerminalSemanticV1 = struct {
    abi_version: u64 = semantic_abi,
    request_epoch: u64,
    publication_next_sequence: u64,
    prompt_tokens: u64,
    max_new_tokens: u64,
    kv_position: u64,
    sampling_calls: u64,
    output_length: u64,
    output_bytes: u64,
    execution_abi: u64,
    rng_state_abi: u64,
    local_plan_sha256: Digest,
    artifact_sha256: Digest,
    token_domain_sha256: Digest,
    token_domain_config_sha256: Digest,
    image_container_sha256: Digest,
    prompt_sha256: Digest,
    output_sha256: Digest,
    logical_kv_sha256: Digest,
    kv_state_sha256: Digest,
    rng_state_sha256: Digest,
    output_state_sha256: Digest,
    state_commitment_sha256: Digest,
    semantic_sha256: Digest,
};

/// Project one already verified terminal boundary into the portable semantic
/// equality surface. `logical_kv_sha256` must be computed over the concrete
/// full logical KV prefix owned by the caller.
pub fn makeV1(
    boundary: session.BoundarySnapshotV2,
    bound_plan: session.BoundPlanV1,
    local_plan: session.PlanV1,
    output_tokens: []const u32,
    logical_kv_sha256: Digest,
) Error!TerminalSemanticV1 {
    if (!session.boundarySnapshotValidForBoundPlanV2(
        boundary,
        bound_plan,
        local_plan,
    ) or !boundary.base.publication.terminal)
        return Error.InvalidTerminalBoundary;
    if (output_tokens.len == 0 or
        output_tokens.len > std.math.maxInt(u64))
        return Error.InvalidSemantic;

    const output_length: u64 = @intCast(output_tokens.len);
    const output_bytes = std.math.mul(
        u64,
        output_length,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    const state = boundary.base.publication.state;
    var value: TerminalSemanticV1 = .{
        .request_epoch = boundary.base.publication.request_epoch,
        .publication_next_sequence = boundary.base.publication.next_sequence,
        .prompt_tokens = local_plan.prompt_tokens,
        .max_new_tokens = local_plan.max_new_tokens,
        .kv_position = state.kv_position,
        .sampling_calls = state.sampling_calls,
        .output_length = output_length,
        .output_bytes = output_bytes,
        .execution_abi = state.execution_abi,
        .rng_state_abi = state.rng_state_abi,
        .local_plan_sha256 = local_plan.plan_sha256,
        .artifact_sha256 = bound_plan.artifact.artifact_sha256,
        .token_domain_sha256 = bound_plan.token_domain_sha256,
        .token_domain_config_sha256 = bound_plan.token_domain_config_sha256,
        .image_container_sha256 = local_plan.image_identity.container_sha256,
        .prompt_sha256 = local_plan.prompt_sha256,
        .output_sha256 = outputSemanticRootV1(
            bound_plan,
            output_tokens,
        ),
        .logical_kv_sha256 = logical_kv_sha256,
        .kv_state_sha256 = state.kv_state_sha256,
        .rng_state_sha256 = state.rng_state_sha256,
        .output_state_sha256 = state.output_state_sha256,
        .state_commitment_sha256 = state.commitment_sha256,
        .semantic_sha256 = [_]u8{0} ** 32,
    };
    value.semantic_sha256 = semanticRootV1(value);
    try validateV1(value);
    return value;
}

pub fn encodeV1(
    value: TerminalSemanticV1,
    destination: []u8,
) Error![]u8 {
    if (destination.len != semantic_bytes)
        return Error.InvalidLength;
    try validateV1(value);
    var local: [semantic_bytes]u8 = undefined;
    writeBodyV1(value, local[0..semantic_body_bytes]);
    @memcpy(
        local[semantic_body_bytes..semantic_bytes],
        &value.semantic_sha256,
    );
    if (slicesOverlap(destination, local[0..]))
        return Error.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

pub fn decodeV1(encoded: []const u8) Error!TerminalSemanticV1 {
    if (encoded.len != semantic_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &semantic_magic) or
        readU64(encoded, 8) != semantic_abi or
        readU64(encoded, 16) != semantic_bytes or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidSemantic;

    var reader: Reader = .{
        .bytes = encoded[32..semantic_body_bytes],
    };
    const value: TerminalSemanticV1 = .{
        .request_epoch = try reader.readU64(),
        .publication_next_sequence = try reader.readU64(),
        .prompt_tokens = try reader.readU64(),
        .max_new_tokens = try reader.readU64(),
        .kv_position = try reader.readU64(),
        .sampling_calls = try reader.readU64(),
        .output_length = try reader.readU64(),
        .output_bytes = try reader.readU64(),
        .execution_abi = try reader.readU64(),
        .rng_state_abi = try reader.readU64(),
        .local_plan_sha256 = try reader.readDigest(),
        .artifact_sha256 = try reader.readDigest(),
        .token_domain_sha256 = try reader.readDigest(),
        .token_domain_config_sha256 = try reader.readDigest(),
        .image_container_sha256 = try reader.readDigest(),
        .prompt_sha256 = try reader.readDigest(),
        .output_sha256 = try reader.readDigest(),
        .logical_kv_sha256 = try reader.readDigest(),
        .kv_state_sha256 = try reader.readDigest(),
        .rng_state_sha256 = try reader.readDigest(),
        .output_state_sha256 = try reader.readDigest(),
        .state_commitment_sha256 = try reader.readDigest(),
        .semantic_sha256 = encoded[semantic_body_bytes..semantic_bytes].*,
    };
    if (!allZero(reader.remaining()))
        return Error.InvalidSemantic;
    try validateV1(value);
    return value;
}

pub fn validateV1(value: TerminalSemanticV1) Error!void {
    if (value.abi_version != semantic_abi or
        value.request_epoch == 0 or
        value.publication_next_sequence == 0 or
        value.prompt_tokens == 0 or
        value.max_new_tokens == 0 or
        value.output_length == 0 or
        value.output_length > value.max_new_tokens or
        value.publication_next_sequence != value.output_length or
        value.sampling_calls != value.output_length or
        value.execution_abi == 0 or value.rng_state_abi == 0 or
        isZero(value.local_plan_sha256) or
        isZero(value.artifact_sha256) or
        isZero(value.token_domain_sha256) or
        isZero(value.token_domain_config_sha256) or
        isZero(value.image_container_sha256) or
        isZero(value.prompt_sha256) or isZero(value.output_sha256) or
        isZero(value.logical_kv_sha256) or
        isZero(value.kv_state_sha256) or
        isZero(value.rng_state_sha256) or
        isZero(value.output_state_sha256) or
        isZero(value.state_commitment_sha256) or
        isZero(value.semantic_sha256))
        return Error.InvalidSemantic;

    const expected_output_bytes = std.math.mul(
        u64,
        value.output_length,
        @sizeOf(u32),
    ) catch return Error.ArithmeticOverflow;
    const expected_kv_position = std.math.add(
        u64,
        value.prompt_tokens,
        value.output_length - 1,
    ) catch return Error.ArithmeticOverflow;
    if (value.output_bytes != expected_output_bytes or
        value.kv_position != expected_kv_position)
        return Error.InvalidSemantic;

    const state: publication.StateCommitmentV1 = .{
        .execution_abi = value.execution_abi,
        .kv_position = value.kv_position,
        .kv_state_sha256 = value.kv_state_sha256,
        .rng_state_abi = value.rng_state_abi,
        .rng_state_sha256 = value.rng_state_sha256,
        .sampling_calls = value.sampling_calls,
        .output_length = value.output_length,
        .output_state_sha256 = value.output_state_sha256,
        .commitment_sha256 = value.state_commitment_sha256,
    };
    if (!publication.stateCommitmentValidV1(state) or
        !std.mem.eql(
            u8,
            &value.semantic_sha256,
            &semanticRootV1(value),
        ))
        return Error.InvalidSemantic;
}

pub fn equivalentV1(
    uninterrupted: TerminalSemanticV1,
    resumed: TerminalSemanticV1,
) bool {
    validateV1(uninterrupted) catch return false;
    validateV1(resumed) catch return false;
    return std.meta.eql(uninterrupted, resumed);
}

pub fn semanticRootV1(value: TerminalSemanticV1) Digest {
    var body: [semantic_body_bytes]u8 = undefined;
    writeBodyV1(value, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(semantic_domain);
    hash.update(&body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Token ids are compared independently of the execution-plan generation and
/// target residency/ownership roots. The immutable artifact and token-domain
/// identities still prevent equality across a different model or tokenizer.
pub fn outputSemanticRootV1(
    bound_plan: session.BoundPlanV1,
    output_tokens: []const u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(output_domain);
    hash.update(&bound_plan.artifact.artifact_sha256);
    hash.update(&bound_plan.token_domain_sha256);
    hash.update(&bound_plan.token_domain_config_sha256);
    hashU64(&hash, @intCast(output_tokens.len));
    for (output_tokens) |token| hashU32(&hash, token);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn writeBodyV1(
    value: TerminalSemanticV1,
    destination: []u8,
) void {
    std.debug.assert(destination.len == semantic_body_bytes);
    @memset(destination, 0);
    @memcpy(destination[0..8], &semantic_magic);
    writeU64(destination, 8, semantic_abi);
    writeU64(destination, 16, semantic_bytes);
    writeU64(destination, 24, allowed_flags);
    var writer: Writer = .{ .bytes = destination[32..] };
    writer.writeU64(value.request_epoch);
    writer.writeU64(value.publication_next_sequence);
    writer.writeU64(value.prompt_tokens);
    writer.writeU64(value.max_new_tokens);
    writer.writeU64(value.kv_position);
    writer.writeU64(value.sampling_calls);
    writer.writeU64(value.output_length);
    writer.writeU64(value.output_bytes);
    writer.writeU64(value.execution_abi);
    writer.writeU64(value.rng_state_abi);
    writer.writeDigest(value.local_plan_sha256);
    writer.writeDigest(value.artifact_sha256);
    writer.writeDigest(value.token_domain_sha256);
    writer.writeDigest(value.token_domain_config_sha256);
    writer.writeDigest(value.image_container_sha256);
    writer.writeDigest(value.prompt_sha256);
    writer.writeDigest(value.output_sha256);
    writer.writeDigest(value.logical_kv_sha256);
    writer.writeDigest(value.kv_state_sha256);
    writer.writeDigest(value.rng_state_sha256);
    writer.writeDigest(value.output_state_sha256);
    writer.writeDigest(value.state_commitment_sha256);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeU64(self: *Writer, value: u64) void {
        std.debug.assert(self.position + 8 <= self.bytes.len);
        std.mem.writeInt(
            u64,
            self.bytes[self.position..][0..8],
            value,
            .little,
        );
        self.position += 8;
    }

    fn writeDigest(self: *Writer, value: Digest) void {
        std.debug.assert(self.position + value.len <= self.bytes.len);
        @memcpy(
            self.bytes[self.position .. self.position + value.len],
            &value,
        );
        self.position += value.len;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readU64(self: *Reader) Error!u64 {
        if (self.position + 8 > self.bytes.len)
            return Error.InvalidSemantic;
        const value = std.mem.readInt(
            u64,
            self.bytes[self.position..][0..8],
            .little,
        );
        self.position += 8;
        return value;
    }

    fn readDigest(self: *Reader) Error!Digest {
        if (self.position + 32 > self.bytes.len)
            return Error.InvalidSemantic;
        const value = self.bytes[self.position..][0..32].*;
        self.position += 32;
        return value;
    }

    fn remaining(self: *const Reader) []const u8 {
        return self.bytes[self.position..];
    }
};

fn writeU64(destination: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(
        u64,
        destination[offset..][0..8],
        value,
        .little,
    );
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        source[offset..][0..8],
        .little,
    );
}

fn hashU64(hash: anytype, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU32(hash: anytype, value: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = left_start + left.len;
    const right_end = right_start + right.len;
    return left_start < right_end and right_start < left_end;
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn fixtureV1() TerminalSemanticV1 {
    const state = publication.makeStateCommitmentV1(
        0x4750_5445_0000_0001,
        6,
        filledDigest(0x31),
        0x4750_5452_0000_0001,
        filledDigest(0x32),
        4,
        4,
        filledDigest(0x33),
    );
    var value: TerminalSemanticV1 = .{
        .request_epoch = 71,
        .publication_next_sequence = 4,
        .prompt_tokens = 3,
        .max_new_tokens = 4,
        .kv_position = state.kv_position,
        .sampling_calls = state.sampling_calls,
        .output_length = state.output_length,
        .output_bytes = 16,
        .execution_abi = state.execution_abi,
        .rng_state_abi = state.rng_state_abi,
        .local_plan_sha256 = filledDigest(0x21),
        .artifact_sha256 = filledDigest(0x23),
        .token_domain_sha256 = filledDigest(0x24),
        .token_domain_config_sha256 = filledDigest(0x25),
        .image_container_sha256 = filledDigest(0x26),
        .prompt_sha256 = filledDigest(0x27),
        .output_sha256 = filledDigest(0x28),
        .logical_kv_sha256 = filledDigest(0x29),
        .kv_state_sha256 = state.kv_state_sha256,
        .rng_state_sha256 = state.rng_state_sha256,
        .output_state_sha256 = state.output_state_sha256,
        .state_commitment_sha256 = state.commitment_sha256,
        .semantic_sha256 = [_]u8{0} ** 32,
    };
    value.semantic_sha256 = semanticRootV1(value);
    return value;
}

test "terminal semantic wire is canonical and mutation complete" {
    const testing = std.testing;
    const expected = fixtureV1();
    try validateV1(expected);
    var encoded: [semantic_bytes]u8 = undefined;
    _ = try encodeV1(expected, &encoded);
    try testing.expectEqualDeep(expected, try decodeV1(&encoded));
    try testing.expect(equivalentV1(expected, expected));

    var mutated = encoded;
    for (0..mutated.len) |index| {
        mutated = encoded;
        mutated[index] ^= 1;
        try testing.expectError(
            Error.InvalidSemantic,
            decodeV1(&mutated),
        );
    }
    try testing.expectError(
        Error.InvalidLength,
        decodeV1(encoded[0 .. encoded.len - 1]),
    );
    var extended: [semantic_bytes + 1]u8 = undefined;
    @memcpy(extended[0..semantic_bytes], &encoded);
    extended[semantic_bytes] = 0;
    try testing.expectError(
        Error.InvalidLength,
        decodeV1(&extended),
    );
}

test "terminal semantic rejects coherently rerooted contradictions" {
    const testing = std.testing;
    var changed = fixtureV1();
    changed.output_length -= 1;
    changed.semantic_sha256 = semanticRootV1(changed);
    try testing.expectError(Error.InvalidSemantic, validateV1(changed));
    try testing.expect(!equivalentV1(fixtureV1(), changed));

    changed = fixtureV1();
    changed.state_commitment_sha256[0] ^= 1;
    changed.semantic_sha256 = semanticRootV1(changed);
    try testing.expectError(Error.InvalidSemantic, validateV1(changed));
}
