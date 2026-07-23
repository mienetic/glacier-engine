//! Model-free continuation runtime state and one-token restart publication.
//!
//! The fixed wire binds the exact next publication sequence, logical paged-KV
//! digest, RNG, sampling counter, output prefix, previous commit, and checkpoint
//! challenge. Resume validates all fallible state before acquiring a
//! ResourceBank permit; KV, sampler, output, and commit-chain visibility then
//! advance through one bounded infallible suffix.

const std = @import("std");
const core = @import("core");
const capsule = core.continuation_capsule;
const resource_bank = core.resource_bank;
const paged_kv = @import("paged_kv_cache.zig");

pub const Digest = [32]u8;
pub const RngState = [4]u64;
pub const runtime_state_abi: u64 = 0x4743_4c52_0000_0001;
pub const resume_receipt_abi: u64 = 0x4743_4c43_0000_0001;
pub const runtime_state_magic = [_]u8{
    'G', 'C', 'L', 'I', 'V', 'E', '0', '1',
};
pub const runtime_state_bytes: usize = 304;
pub const runtime_state_body_bytes: usize = runtime_state_bytes - 32;
pub const max_output_tokens: usize = 16;
pub const allowed_flags: u32 = 0;

const runtime_state_domain =
    "glacier-continuation-live-runtime-state-v1\x00";
const output_state_domain =
    "glacier-continuation-live-output-v1\x00";
const resume_receipt_domain =
    "glacier-continuation-live-resume-receipt-v1\x00";

pub const Error = capsule.Error || paged_kv.Error || resource_bank.Error || error{
    ArithmeticOverflow,
    CapacityExceeded,
    InvalidRuntimeState,
    InvalidResumeInput,
    NewAllocationRequired,
    UnsafeDestination,
};

pub const RuntimeStateV1 = struct {
    request_epoch: u64,
    publication_next_sequence: u64,
    checkpoint_generation: u64,
    kv_tokens: u64,
    output_token_count: usize,
    sampling_calls: u64,
    rng_state: RngState,
    previous_commit_sha256: Digest,
    logical_kv_sha256: Digest,
    challenge_sha256: Digest,
    output_tokens: [max_output_tokens]u32,
};

pub const PublicationAuthorityV1 = struct {
    bank: *resource_bank.Bank,
    tree: resource_bank.LeaseTreeV1,
    request_epoch: u64,
    session_id: usize,
};

pub const ResumeInputV1 = struct {
    token_id: u32,
    rng_after: RngState,
    sampling_calls_after: u64,
    layer_keys: []const f32,
    layer_values: []const f32,
};

pub const ResumeReceiptV1 = struct {
    abi_version: u64 = resume_receipt_abi,
    request_epoch: u64,
    transaction_sequence: u64,
    permit_generation: u64,
    checkpoint_generation: u64,
    token_id: u32,
    root_before: paged_kv.PageMapRootV1,
    root_after: paged_kv.PageMapRootV1,
    logical_kv_before_sha256: Digest,
    logical_kv_after_sha256: Digest,
    rng_before: RngState,
    rng_after: RngState,
    sampling_calls_before: u64,
    sampling_calls_after: u64,
    output_before: u64,
    output_after: u64,
    output_sha256: Digest,
    previous_commit_sha256: Digest,
    challenge_sha256: Digest,
    commit_sha256: Digest,
};

pub fn encodeRuntimeStateV1(
    state: RuntimeStateV1,
    destination: []u8,
) Error![]const u8 {
    try validateRuntimeStateV1(state);
    if (destination.len < runtime_state_bytes)
        return Error.CapacityExceeded;
    const output = destination[0..runtime_state_bytes];
    if (slicesOverlap(
        output,
        std.mem.sliceAsBytes(&state.output_tokens),
    )) return Error.UnsafeDestination;

    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&runtime_state_magic);
    try writer.writeU64(runtime_state_abi);
    try writer.writeU64(runtime_state_bytes);
    try writer.writeU32(allowed_flags);
    try writer.writeU32(0);
    try writer.writeU64(state.request_epoch);
    try writer.writeU64(state.publication_next_sequence);
    try writer.writeU64(state.checkpoint_generation);
    try writer.writeU64(state.kv_tokens);
    try writer.writeU64(state.output_token_count);
    try writer.writeU64(state.sampling_calls);
    for (state.rng_state) |word| try writer.writeU64(word);
    try writer.writeDigest(state.previous_commit_sha256);
    try writer.writeDigest(state.logical_kv_sha256);
    try writer.writeDigest(state.challenge_sha256);
    for (state.output_tokens) |token| try writer.writeU32(token);
    if (writer.position != runtime_state_body_bytes)
        return Error.InvalidRuntimeState;
    try writer.writeDigest(runtimeStateRootV1(
        output[0..runtime_state_body_bytes],
    ));
    if (writer.position != runtime_state_bytes)
        return Error.InvalidRuntimeState;
    return output;
}

pub fn decodeRuntimeStateV1(
    encoded: []const u8,
) Error!RuntimeStateV1 {
    if (encoded.len != runtime_state_bytes)
        return Error.InvalidRuntimeState;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(
        u8,
        try reader.readBytes(runtime_state_magic.len),
        &runtime_state_magic,
    )) return Error.InvalidRuntimeState;
    if (try reader.readU64() != runtime_state_abi or
        try reader.readU64() != runtime_state_bytes or
        try reader.readU32() != allowed_flags or
        try reader.readU32() != 0)
        return Error.InvalidRuntimeState;

    var state: RuntimeStateV1 = .{
        .request_epoch = try reader.readU64(),
        .publication_next_sequence = try reader.readU64(),
        .checkpoint_generation = try reader.readU64(),
        .kv_tokens = try reader.readU64(),
        .output_token_count = std.math.cast(
            usize,
            try reader.readU64(),
        ) orelse return Error.InvalidRuntimeState,
        .sampling_calls = try reader.readU64(),
        .rng_state = undefined,
        .previous_commit_sha256 = undefined,
        .logical_kv_sha256 = undefined,
        .challenge_sha256 = undefined,
        .output_tokens = undefined,
    };
    for (&state.rng_state) |*word| word.* = try reader.readU64();
    state.previous_commit_sha256 = try reader.readDigest();
    state.logical_kv_sha256 = try reader.readDigest();
    state.challenge_sha256 = try reader.readDigest();
    for (&state.output_tokens) |*token| token.* = try reader.readU32();
    if (reader.position != runtime_state_body_bytes)
        return Error.InvalidRuntimeState;
    const wire_root = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &wire_root,
        &runtimeStateRootV1(encoded[0..runtime_state_body_bytes]),
    )) return Error.InvalidRuntimeState;
    try validateRuntimeStateV1(state);
    return state;
}

/// Verify every capsule object before returning mutable runtime state. The
/// sampler, output, and previous-publication slots deliberately bind the same
/// fixed wire through three distinct capsule object domains.
pub fn restoreRuntimeStateV1(
    capsule_wire: []const u8,
    expected_config: capsule.ConfigV1,
    objects: capsule.ObjectsV1,
    runtime_wire: []const u8,
) Error!RuntimeStateV1 {
    _ = try capsule.decodeAndVerifyV1(
        capsule_wire,
        expected_config,
        objects,
    );
    inline for (.{
        objects.sampler_state,
        objects.output_state,
        objects.publication_receipt,
    }) |object| {
        if (object.abi_version != runtime_state_abi or
            !std.mem.eql(u8, object.bytes, runtime_wire))
            return Error.InvalidRuntimeState;
    }
    const state = try decodeRuntimeStateV1(runtime_wire);
    if (state.request_epoch != expected_config.request_epoch or
        state.publication_next_sequence !=
            expected_config.publication_sequence or
        state.checkpoint_generation !=
            expected_config.checkpoint_generation or
        state.kv_tokens != expected_config.kv_tokens or
        state.output_token_count != expected_config.output_tokens or
        !std.mem.eql(
            u8,
            &state.challenge_sha256,
            &expected_config.challenge_sha256,
        ))
        return Error.InvalidRuntimeState;
    return state;
}

/// Publish exactly one resumed token without allocating a new physical page.
/// A page boundary must first pass through the leased allocation planner so
/// ResourceBank can charge before allocator materialization.
pub fn resumeOneTokenV1(
    authority: PublicationAuthorityV1,
    cache: *paged_kv.PagedKVCache,
    state: *RuntimeStateV1,
    input: ResumeInputV1,
) Error!ResumeReceiptV1 {
    try validateRuntimeStateV1(state.*);
    if (authority.request_epoch != state.request_epoch or
        authority.session_id == 0)
        return Error.InvalidResumeInput;
    if (state.publication_next_sequence == std.math.maxInt(u64) or
        state.kv_tokens == std.math.maxInt(u64) or
        state.sampling_calls == std.math.maxInt(u64) or
        state.output_token_count >= max_output_tokens)
        return Error.CapacityExceeded;
    const expected_values = std.math.mul(
        usize,
        cache.num_layers,
        cache.dim,
    ) catch return Error.ArithmeticOverflow;
    if (input.layer_keys.len != expected_values or
        input.layer_values.len != expected_values or
        input.sampling_calls_after < state.sampling_calls or
        input.sampling_calls_after > state.sampling_calls + 1 or
        (input.sampling_calls_after == state.sampling_calls and
            !std.mem.eql(u64, &input.rng_after, &state.rng_state)))
        return Error.InvalidResumeInput;

    const root_before = cache.root();
    if (root_before.committed_len != state.kv_tokens or
        !std.mem.eql(
            u8,
            &try cache.logicalKvSha256(),
            &state.logical_kv_sha256,
        ))
        return Error.InvalidRuntimeState;
    try authority.bank.validateLeaseTree(authority.tree);
    try authority.bank.validatePublicationSession(
        authority.tree.parent,
        authority.request_epoch,
        authority.session_id,
        state.publication_next_sequence,
    );
    const allocation_plan = try cache.planNextRowAllocation();
    if (allocation_plan.allocation_bytes != 0)
        return Error.NewAllocationRequired;

    const mark = try cache.beginRowPlanned(allocation_plan);
    errdefer cache.abortRow(mark) catch
        @panic("validated continuation row failed rollback");
    for (0..cache.num_layers) |layer| {
        const start = layer * cache.dim;
        const end = start + cache.dim;
        _ = try cache.appendRowTxn(
            mark,
            layer,
            input.layer_keys[start..end],
            input.layer_values[start..end],
        );
    }
    const prepared = try cache.prepareCommit(mark);
    const logical_after = try cache.logicalKvTxnSha256(mark);
    const output_before: u64 = @intCast(state.output_token_count);
    const output_after = output_before + 1;
    var next_output = state.output_tokens;
    next_output[state.output_token_count] = input.token_id;
    const output_sha256 = outputStateSha256V1(
        next_output[0..@intCast(output_after)],
    );

    const permit = authority.bank.beginPublicationWithLeaseTree(
        authority.tree,
        authority.request_epoch,
        authority.session_id,
        state.publication_next_sequence,
    ) catch |err| return err;
    var receipt: ResumeReceiptV1 = .{
        .request_epoch = authority.request_epoch,
        .transaction_sequence = permit.sequence,
        .permit_generation = permit.generation,
        .checkpoint_generation = state.checkpoint_generation,
        .token_id = input.token_id,
        .root_before = root_before,
        .root_after = prepared.root_after,
        .logical_kv_before_sha256 = state.logical_kv_sha256,
        .logical_kv_after_sha256 = logical_after,
        .rng_before = state.rng_state,
        .rng_after = input.rng_after,
        .sampling_calls_before = state.sampling_calls,
        .sampling_calls_after = input.sampling_calls_after,
        .output_before = output_before,
        .output_after = output_after,
        .output_sha256 = output_sha256,
        .previous_commit_sha256 = state.previous_commit_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .commit_sha256 = undefined,
    };
    receipt.commit_sha256 = resumeReceiptRootV1(receipt);

    // Every operation below is bounded, prevalidated, and infallible.
    cache.commitPreparedAssumeValid(prepared);
    state.output_tokens = next_output;
    state.output_token_count += 1;
    state.rng_state = input.rng_after;
    state.sampling_calls = input.sampling_calls_after;
    state.kv_tokens += 1;
    state.publication_next_sequence += 1;
    state.logical_kv_sha256 = logical_after;
    state.previous_commit_sha256 = receipt.commit_sha256;
    authority.bank.commitPublicationAssumeValid(permit);
    return receipt;
}

pub fn runtimeStateRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(runtime_state_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn outputStateSha256V1(tokens: []const u32) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(output_state_domain);
    hashU64(&hash, @as(u64, @intCast(tokens.len)));
    for (tokens) |token| hashU32(&hash, token);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn resumeReceiptRootV1(receipt: ResumeReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(resume_receipt_domain);
    hashU64(&hash, resume_receipt_abi);
    hashU64(&hash, receipt.request_epoch);
    hashU64(&hash, receipt.transaction_sequence);
    hashU64(&hash, receipt.permit_generation);
    hashU64(&hash, receipt.checkpoint_generation);
    hashU32(&hash, receipt.token_id);
    hashPageRoot(&hash, receipt.root_before);
    hashPageRoot(&hash, receipt.root_after);
    hash.update(&receipt.logical_kv_before_sha256);
    hash.update(&receipt.logical_kv_after_sha256);
    for (receipt.rng_before) |word| hashU64(&hash, word);
    for (receipt.rng_after) |word| hashU64(&hash, word);
    hashU64(&hash, receipt.sampling_calls_before);
    hashU64(&hash, receipt.sampling_calls_after);
    hashU64(&hash, receipt.output_before);
    hashU64(&hash, receipt.output_after);
    hash.update(&receipt.output_sha256);
    hash.update(&receipt.previous_commit_sha256);
    hash.update(&receipt.challenge_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn validateRuntimeStateV1(state: RuntimeStateV1) Error!void {
    if (state.request_epoch == 0 or
        state.publication_next_sequence == 0 or
        state.checkpoint_generation == 0 or state.kv_tokens == 0 or
        state.output_token_count == 0 or
        state.output_token_count > max_output_tokens or
        state.output_token_count > state.kv_tokens or
        isZero(state.rng_state) or
        isZero(state.previous_commit_sha256) or
        isZero(state.logical_kv_sha256) or
        isZero(state.challenge_sha256))
        return Error.InvalidRuntimeState;
    for (state.output_tokens[state.output_token_count..]) |token| {
        if (token != 0) return Error.InvalidRuntimeState;
    }
}

fn hashPageRoot(
    hash: *std.crypto.hash.sha2.Sha256,
    root: paged_kv.PageMapRootV1,
) void {
    hashU64(hash, root.abi_version);
    hashU64(hash, root.cache_instance);
    hashU64(hash, root.generation);
    hashU64(hash, root.committed_len);
    hashU64(hash, root.committed_pages);
    hash.update(&root.ownership_sha256);
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn isZero(value: anytype) bool {
    const bytes = std.mem.asBytes(&value);
    return std.mem.allEqual(u8, bytes, 0);
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
        const end = std.math.add(
            usize,
            self.position,
            value.len,
        ) catch return Error.InvalidRuntimeState;
        if (end > self.bytes.len) return Error.InvalidRuntimeState;
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
        const end = std.math.add(
            usize,
            self.position,
            length,
        ) catch return Error.InvalidRuntimeState;
        if (end > self.bytes.len) return Error.InvalidRuntimeState;
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

test "live runtime state is canonical and mutation complete" {
    var tokens = [_]u32{0} ** max_output_tokens;
    tokens[0] = 101;
    tokens[1] = 102;
    const state: RuntimeStateV1 = .{
        .request_epoch = 71,
        .publication_next_sequence = 17,
        .checkpoint_generation = 4,
        .kv_tokens = 16,
        .output_token_count = 2,
        .sampling_calls = 2,
        .rng_state = .{ 1, 2, 3, 4 },
        .previous_commit_sha256 = [_]u8{0x51} ** 32,
        .logical_kv_sha256 = [_]u8{0x52} ** 32,
        .challenge_sha256 = [_]u8{0x53} ** 32,
        .output_tokens = tokens,
    };
    var storage: [runtime_state_bytes]u8 = undefined;
    const encoded = try encodeRuntimeStateV1(state, &storage);
    try std.testing.expectEqualDeep(
        state,
        try decodeRuntimeStateV1(encoded),
    );
    var golden_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &golden_root,
        "3817f7c8078688de1b22072e8bc2f45a" ++
            "801f2de0d3b825d4cfdada6135b0ada9",
    );
    try std.testing.expectEqualSlices(
        u8,
        &golden_root,
        encoded[runtime_state_body_bytes..],
    );

    var corrupted: [runtime_state_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodeRuntimeStateV1(&corrupted)) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    @memcpy(&corrupted, encoded);
    std.mem.writeInt(u32, corrupted[28..32], 1, .little);
    const rerooted = runtimeStateRootV1(
        corrupted[0..runtime_state_body_bytes],
    );
    @memcpy(corrupted[runtime_state_body_bytes..], &rerooted);
    try std.testing.expectError(
        Error.InvalidRuntimeState,
        decodeRuntimeStateV1(&corrupted),
    );
}

test "one resumed token atomically advances KV sampler output and Bank fence" {
    const allocator = std.testing.allocator;
    var cache = try paged_kv.PagedKVCache.init(allocator, 1, 1, 32);
    for (0..17) |position|
        try appendFixtureRowV1(&cache, position);
    const ledger = cache.capacityLedger();
    const page_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_payload_bytes),
    };
    const tree_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_payload_bytes * 2),
    };
    const parent_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_map_bytes),
        .output_journal_bytes = runtime_state_bytes,
    };
    const total_host_bytes = try std.math.add(
        u64,
        try parent_claim.hostBytes(),
        try tree_claim.hostBytes(),
    );
    var slots = [_]resource_bank.Slot{.{}};
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 3;
    var bank = try resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{
            .host_bytes = total_host_bytes,
            .kv_bytes = parent_claim.kv_bytes + tree_claim.kv_bytes,
            .output_journal_bytes = parent_claim.output_journal_bytes,
        },
        82,
    );
    const receipt = try bank.commit(
        try bank.reserve(0x8101, parent_claim),
    );
    var tree = try bank.openLeaseTree(
        receipt,
        0x8102,
        0x8103,
        tree_claim,
    );
    const opened = try bank.openLeaseScope(
        tree,
        0x8104,
        0x8105,
        tree_claim,
    );
    tree = opened.tree;
    var session_identity: u8 = 0;
    const session_id = @intFromPtr(&session_identity);
    try bank.bindRestoredPublicationSessionWithLeaseTree(
        tree,
        81,
        71,
        session_id,
        18,
    );
    var leaves: [2]resource_bank.LeaseNodeV1 = undefined;
    const specs = [_]resource_bank.LeaseAllocationSpecV1{
        .{
            .scope = opened.scope,
            .node_key = 1,
            .binding_key = 101,
            .claim = page_claim,
        },
        .{
            .scope = opened.scope,
            .node_key = 2,
            .binding_key = 102,
            .claim = page_claim,
        },
    };
    const reserved = try bank.reserveAllocationsForSession(
        tree,
        71,
        session_id,
        18,
        &specs,
        &leaves,
    );
    tree = try bank.commitAllocationsAfterAllocate(reserved.batch);

    var tokens = [_]u32{0} ** max_output_tokens;
    tokens[0] = 501;
    tokens[1] = 502;
    tokens[2] = 503;
    var state: RuntimeStateV1 = .{
        .request_epoch = 71,
        .publication_next_sequence = 18,
        .checkpoint_generation = 4,
        .kv_tokens = 17,
        .output_token_count = 3,
        .sampling_calls = 3,
        .rng_state = .{ 11, 22, 33, 44 },
        .previous_commit_sha256 = [_]u8{0x61} ** 32,
        .logical_kv_sha256 = try cache.logicalKvSha256(),
        .challenge_sha256 = [_]u8{0x62} ** 32,
        .output_tokens = tokens,
    };
    const root_before = cache.root();
    const previous_commit = state.previous_commit_sha256;
    const keys = [_]f32{1801};
    const values = [_]f32{1802};
    const receipt_after = try resumeOneTokenV1(
        .{
            .bank = &bank,
            .tree = tree,
            .request_epoch = 71,
            .session_id = session_id,
        },
        &cache,
        &state,
        .{
            .token_id = 504,
            .rng_after = .{ 12, 23, 34, 45 },
            .sampling_calls_after = 4,
            .layer_keys = &keys,
            .layer_values = &values,
        },
    );
    try std.testing.expectEqual(@as(u64, 18), receipt_after.transaction_sequence);
    try std.testing.expectEqualDeep(root_before, receipt_after.root_before);
    try std.testing.expectEqualDeep(cache.root(), receipt_after.root_after);
    try std.testing.expectEqual(@as(u64, 19), state.publication_next_sequence);
    try std.testing.expectEqual(@as(u64, 18), state.kv_tokens);
    try std.testing.expectEqual(@as(usize, 4), state.output_token_count);
    try std.testing.expectEqualSlices(
        u32,
        &[_]u32{ 501, 502, 503, 504 },
        state.output_tokens[0..state.output_token_count],
    );
    try std.testing.expectEqualSlices(
        u8,
        &previous_commit,
        &receipt_after.previous_commit_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &receipt_after.commit_sha256,
        &state.previous_commit_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &resumeReceiptRootV1(receipt_after),
        &receipt_after.commit_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &try cache.logicalKvSha256(),
        &state.logical_kv_sha256,
    );

    const stale_root = cache.root();
    var stale_state = state;
    stale_state.publication_next_sequence = 18;
    try std.testing.expectError(
        resource_bank.Error.InvalidTransition,
        resumeOneTokenV1(
            .{
                .bank = &bank,
                .tree = tree,
                .request_epoch = 71,
                .session_id = session_id,
            },
            &cache,
            &stale_state,
            .{
                .token_id = 505,
                .rng_after = .{ 13, 24, 35, 46 },
                .sampling_calls_after = 5,
                .layer_keys = &keys,
                .layer_values = &values,
            },
        ),
    );
    try std.testing.expectEqualDeep(stale_root, cache.root());

    const retiring = try bank.beginRetireSubtreeForSession(
        tree,
        opened.scope,
        71,
        session_id,
        19,
    );
    const authorized = try bank.authorizeFree(retiring.ticket);
    cache.deinit();
    const empty_tree = try bank.commitFreeAfterAllocatorFree(
        authorized.permit,
    );
    try bank.closePublicationSession(receipt, 71, session_id, 19);
    try bank.closeLeaseTree(empty_tree);
    try bank.release(receipt);
    try std.testing.expect((try bank.snapshotV3()).used.isZero());
}

test "resume receipt root matches independent fixture" {
    const root_before: paged_kv.PageMapRootV1 = .{
        .cache_instance = 900,
        .generation = 8,
        .committed_len = 16,
        .committed_pages = 1,
        .ownership_sha256 = [_]u8{0x78} ** 32,
    };
    const root_after: paged_kv.PageMapRootV1 = .{
        .cache_instance = 900,
        .generation = 9,
        .committed_len = 17,
        .committed_pages = 2,
        .ownership_sha256 = [_]u8{0x79} ** 32,
    };
    const outputs = [_]u32{ 101, 102, 103 };
    const output_sha256 = outputStateSha256V1(&outputs);
    var receipt: ResumeReceiptV1 = .{
        .request_epoch = 71,
        .transaction_sequence = 17,
        .permit_generation = 7,
        .checkpoint_generation = 4,
        .token_id = 103,
        .root_before = root_before,
        .root_after = root_after,
        .logical_kv_before_sha256 = [_]u8{0x52} ** 32,
        .logical_kv_after_sha256 = [_]u8{0x54} ** 32,
        .rng_before = .{ 1, 2, 3, 4 },
        .rng_after = .{ 2, 3, 4, 5 },
        .sampling_calls_before = 2,
        .sampling_calls_after = 3,
        .output_before = 2,
        .output_after = 3,
        .output_sha256 = output_sha256,
        .previous_commit_sha256 = [_]u8{0x51} ** 32,
        .challenge_sha256 = [_]u8{0x53} ** 32,
        .commit_sha256 = undefined,
    };
    receipt.commit_sha256 = resumeReceiptRootV1(receipt);
    var expected_output: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_output,
        "9ee5866300196621498083280108d1cc" ++
            "36b322c28e93a234d20b231b8c6a42e2",
    );
    var expected_commit: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_commit,
        "42fd59983f808664141334276a05bec49" ++
            "7b8ebae91a728094ca926b60916ebb7",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_output,
        &output_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_commit,
        &receipt.commit_sha256,
    );
}

fn appendFixtureRowV1(
    cache: *paged_kv.PagedKVCache,
    position: usize,
) !void {
    const mark = try cache.beginRow();
    for (0..cache.num_layers) |layer| {
        const base: f32 = @floatFromInt(position * 100 + layer * 10);
        const key = [_]f32{base + 1};
        const value = [_]f32{base + 2};
        _ = try cache.appendRowTxn(mark, layer, &key, &value);
    }
    try cache.commitRowTxn(mark);
}
