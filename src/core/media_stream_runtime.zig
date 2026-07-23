//! Bounded multi-chunk image/audio/video publication over per-buffer leases.

const std = @import("std");
const resource_bank = @import("resource_bank.zig");
const media = @import("media_contract.zig");
const decode_plan = @import("media_decode_plan.zig");
const fixture_api = @import("media_fixture.zig");
const transform = @import("media_transform.zig");
const flat = @import("media_runtime_txn.zig");
const lease = @import("media_runtime_lease.zig");

pub const Digest = [32]u8;
pub const stream_abi: u64 = 0x474d_5354_0000_0001;
pub const chunk_receipt_abi: u64 = 0x474d_5343_0000_0001;
pub const chunk_receipt_magic =
    [_]u8{ 'G', 'M', 'S', 'C', 'H', 'N', '1', 0 };
pub const maximum_stream_chunks: usize = 4;
pub const chunk_receipt_body_bytes: usize = 320;
pub const chunk_receipt_bytes: usize = 352;
pub const allowed_flags: u64 = 0;

const roots_offset: usize = 128;
const chunk_receipt_domain =
    "glacier-media-stream-chunk-receipt-v1\x00";

pub const Error = lease.Error || error{
    InvalidStream,
    InvalidChunkBoundary,
    StreamCapacityExceeded,
    StreamPoisoned,
    InvalidChunkReceipt,
};

pub const ChunkReceiptV1 = struct {
    kind: media.MediaKindV1,
    request_epoch: u64,
    stream_key: u64,
    stream_chunk_index: u64,
    publication_sequence: u64,
    units_before: u64,
    units_after: u64,
    output_bytes: u64,
    mapping_count: u64,
    binding_count: u64,
    provisional_binding_count: u64,
    media_object_sha256: Digest,
    transform_plan_sha256: Digest,
    lease_receipt_sha256: Digest,
    output_sha256: Digest,
    publication_commit_sha256: Digest,
    previous_chunk_sha256: Digest,
    receipt_sha256: Digest,
};

pub const CommittedChunkV1 = struct {
    execution: lease.LeaseExecutionReceiptV1,
    stream: ChunkReceiptV1,
};

const ChunkSlotState = enum {
    empty,
    prepared,
    committed,
    released,
};

const ChunkSlot = struct {
    session: lease.Session = .{},
    execution_receipt: ?lease.LeaseExecutionReceiptV1 = null,
    chunk_receipt: ?ChunkReceiptV1 = null,
    state: ChunkSlotState = .empty,
};

const ChunkTransactionState = enum {
    prepared,
    committed,
    aborted,
};

pub fn encodeChunkReceiptV1(
    receipt: ChunkReceiptV1,
    storage: *[chunk_receipt_bytes]u8,
) Error![]const u8 {
    try validateChunkReceiptShapeV1(receipt);
    writeChunkReceiptBodyV1(
        receipt,
        storage[0..chunk_receipt_body_bytes],
    );
    @memcpy(
        storage[chunk_receipt_body_bytes..chunk_receipt_bytes],
        &receipt.receipt_sha256,
    );
    return storage;
}

pub fn decodeChunkReceiptV1(
    encoded: []const u8,
) Error!ChunkReceiptV1 {
    if (encoded.len != chunk_receipt_bytes or
        !std.mem.eql(u8, encoded[0..8], &chunk_receipt_magic) or
        readU64(encoded, 8) != chunk_receipt_abi or
        readU64(encoded, 16) != chunk_receipt_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 120) != 0)
        return Error.InvalidChunkReceipt;
    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidChunkReceipt;
    const receipt: ChunkReceiptV1 = .{
        .kind = kind,
        .request_epoch = readU64(encoded, 40),
        .stream_key = readU64(encoded, 48),
        .stream_chunk_index = readU64(encoded, 56),
        .publication_sequence = readU64(encoded, 64),
        .units_before = readU64(encoded, 72),
        .units_after = readU64(encoded, 80),
        .output_bytes = readU64(encoded, 88),
        .mapping_count = readU64(encoded, 96),
        .binding_count = readU64(encoded, 104),
        .provisional_binding_count = readU64(encoded, 112),
        .media_object_sha256 = encoded[128..160].*,
        .transform_plan_sha256 = encoded[160..192].*,
        .lease_receipt_sha256 = encoded[192..224].*,
        .output_sha256 = encoded[224..256].*,
        .publication_commit_sha256 = encoded[256..288].*,
        .previous_chunk_sha256 = encoded[288..320].*,
        .receipt_sha256 = encoded[320..352].*,
    };
    try validateChunkReceiptShapeV1(receipt);
    return receipt;
}

pub fn chunkReceiptRootV1(
    receipt: ChunkReceiptV1,
) Digest {
    var body: [chunk_receipt_body_bytes]u8 = undefined;
    writeChunkReceiptBodyV1(receipt, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(chunk_receipt_domain);
    hash.update(&body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn makeChunkReceiptV1(
    state_before: media.PublicationStateV1,
    stream_key: u64,
    stream_chunk_index: u64,
    previous_chunk_sha256: Digest,
    execution: lease.LeaseExecutionReceiptV1,
) Error!ChunkReceiptV1 {
    const units_after = std.math.add(
        u64,
        state_before.visible_units,
        execution.logical_units,
    ) catch return Error.ArithmeticOverflow;
    var receipt: ChunkReceiptV1 = .{
        .kind = execution.kind,
        .request_epoch = execution.request_epoch,
        .stream_key = stream_key,
        .stream_chunk_index = stream_chunk_index,
        .publication_sequence = execution.media_sequence,
        .units_before = state_before.visible_units,
        .units_after = units_after,
        .output_bytes = execution.output_bytes,
        .mapping_count = execution.mapping_count,
        .binding_count = execution.binding_count,
        .provisional_binding_count = execution.provisional_binding_count,
        .media_object_sha256 = state_before.media_object_sha256,
        .transform_plan_sha256 = execution.transform_plan_sha256,
        .lease_receipt_sha256 = execution.receipt_sha256,
        .output_sha256 = execution.output_sha256,
        .publication_commit_sha256 = execution.publication_commit_sha256,
        .previous_chunk_sha256 = previous_chunk_sha256,
        .receipt_sha256 = [_]u8{0} ** 32,
    };
    receipt.receipt_sha256 = chunkReceiptRootV1(receipt);
    try verifyChunkReceiptV1(
        state_before,
        stream_key,
        stream_chunk_index,
        previous_chunk_sha256,
        execution,
        receipt,
    );
    return receipt;
}

/// Verify stream composition after the embedded LeaseExecutionReceipt has
/// already passed its full fixture/transform/authority verifier.
pub fn verifyChunkReceiptV1(
    state_before: media.PublicationStateV1,
    expected_stream_key: u64,
    expected_stream_chunk_index: u64,
    expected_previous_chunk_sha256: Digest,
    execution: lease.LeaseExecutionReceiptV1,
    receipt: ChunkReceiptV1,
) Error!void {
    try validateChunkReceiptShapeV1(receipt);
    var execution_wire: [lease.receipt_bytes]u8 = undefined;
    _ = lease.encodeLeaseExecutionReceiptV1(
        execution,
        &execution_wire,
    ) catch return Error.InvalidChunkReceipt;
    const units_after = std.math.add(
        u64,
        state_before.visible_units,
        execution.logical_units,
    ) catch return Error.InvalidChunkReceipt;
    if (expected_stream_key == 0 or
        receipt.stream_key != expected_stream_key or
        receipt.stream_chunk_index !=
            expected_stream_chunk_index or
        receipt.request_epoch != state_before.request_epoch or
        receipt.request_epoch != execution.request_epoch or
        receipt.kind != execution.kind or
        receipt.publication_sequence !=
            state_before.next_sequence or
        receipt.publication_sequence != execution.media_sequence or
        receipt.units_before != state_before.visible_units or
        receipt.units_after != units_after or
        receipt.output_bytes != execution.output_bytes or
        receipt.mapping_count != execution.mapping_count or
        receipt.binding_count != execution.binding_count or
        receipt.provisional_binding_count !=
            execution.provisional_binding_count or
        !std.mem.eql(
            u8,
            &receipt.media_object_sha256,
            &state_before.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.transform_plan_sha256,
            &execution.transform_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.lease_receipt_sha256,
            &execution.receipt_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.output_sha256,
            &execution.output_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.publication_commit_sha256,
            &execution.publication_commit_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.previous_chunk_sha256,
            &expected_previous_chunk_sha256,
        ))
        return Error.InvalidChunkReceipt;
}

pub const StreamSession = struct {
    bank: *resource_bank.Bank = undefined,
    media_state: *media.PublicationStateV1 = undefined,
    slots: [maximum_stream_chunks]ChunkSlot =
        [_]ChunkSlot{.{}} ** maximum_stream_chunks,
    stream_key: u64 = 0,
    owner_key_base: u64 = 0,
    tree_key_base: u64 = 0,
    authority_key_base: u64 = 0,
    tenant_key: u64 = 0,
    request_epoch: u64 = 0,
    chunk_limit: usize = 0,
    chunk_index_base: usize = 0,
    committed_chunks: usize = 0,
    active_slot: ?usize = null,
    active_generation: u64 = 0,
    next_generation: u64 = 1,
    previous_chunk_sha256: Digest = [_]u8{0} ** 32,
    initialized: bool = false,
    poisoned: bool = false,
    closed: bool = false,

    pub fn init(
        self: *StreamSession,
        bank: *resource_bank.Bank,
        media_state: *media.PublicationStateV1,
        stream_key: u64,
        owner_key_base: u64,
        tree_key_base: u64,
        authority_key_base: u64,
        tenant_key: u64,
        request_epoch: u64,
        chunk_limit: usize,
    ) Error!void {
        try self.initAtChunkV1(
            bank,
            media_state,
            stream_key,
            owner_key_base,
            tree_key_base,
            authority_key_base,
            tenant_key,
            request_epoch,
            chunk_limit,
            0,
            [_]u8{0} ** 32,
        );
    }

    pub fn initContinuationV1(
        self: *StreamSession,
        bank: *resource_bank.Bank,
        media_state: *media.PublicationStateV1,
        stream_key: u64,
        owner_key_base: u64,
        tree_key_base: u64,
        authority_key_base: u64,
        tenant_key: u64,
        request_epoch: u64,
        chunk_limit: usize,
        committed_chunks_before: usize,
        previous_chunk_sha256: Digest,
    ) Error!void {
        if (committed_chunks_before == 0 or
            isZero(previous_chunk_sha256))
            return Error.InvalidStream;
        try self.initAtChunkV1(
            bank,
            media_state,
            stream_key,
            owner_key_base,
            tree_key_base,
            authority_key_base,
            tenant_key,
            request_epoch,
            chunk_limit,
            committed_chunks_before,
            previous_chunk_sha256,
        );
    }

    fn initAtChunkV1(
        self: *StreamSession,
        bank: *resource_bank.Bank,
        media_state: *media.PublicationStateV1,
        stream_key: u64,
        owner_key_base: u64,
        tree_key_base: u64,
        authority_key_base: u64,
        tenant_key: u64,
        request_epoch: u64,
        chunk_limit: usize,
        chunk_index_base: usize,
        previous_chunk_sha256: Digest,
    ) Error!void {
        if (self.initialized or self.closed)
            return Error.InvalidState;
        if (stream_key == 0 or owner_key_base == 0 or
            tree_key_base == 0 or authority_key_base == 0 or
            tenant_key == 0 or request_epoch == 0 or
            media_state.request_epoch != request_epoch or
            media_state.visible_chunks != chunk_index_base or
            chunk_limit == 0 or
            chunk_limit > maximum_stream_chunks or
            chunk_index_base >= chunk_limit or
            (chunk_index_base == 0 and
                !isZero(previous_chunk_sha256)))
            return Error.InvalidStream;
        const remaining_chunks = chunk_limit - chunk_index_base;
        _ = try derivedKey(
            owner_key_base,
            remaining_chunks - 1,
        );
        _ = try derivedKey(
            tree_key_base,
            remaining_chunks - 1,
        );
        _ = try derivedKey(
            authority_key_base,
            remaining_chunks - 1,
        );
        self.* = .{
            .bank = bank,
            .media_state = media_state,
            .stream_key = stream_key,
            .owner_key_base = owner_key_base,
            .tree_key_base = tree_key_base,
            .authority_key_base = authority_key_base,
            .tenant_key = tenant_key,
            .request_epoch = request_epoch,
            .chunk_limit = chunk_limit,
            .chunk_index_base = chunk_index_base,
            .previous_chunk_sha256 = previous_chunk_sha256,
            .initialized = true,
        };
    }

    pub fn prepareChunk(
        self: *StreamSession,
        declared_units_before: u64,
        declared_units_after: u64,
        encoded_fixture: []const u8,
        encoded_decode_plan: []const u8,
        encoded_transform_plan: []const u8,
        decoded_source: []u8,
        output: []u8,
        mappings: []transform.TransformMappingV1,
        scratch: []u8,
    ) Error!ChunkTransaction {
        if (!self.initialized or self.closed)
            return Error.InvalidState;
        if (self.poisoned) return Error.StreamPoisoned;
        if (self.active_slot != null or
            self.active_generation != 0)
            return Error.InvalidState;
        if (self.chunk_index_base + self.committed_chunks >=
            self.chunk_limit)
            return Error.StreamCapacityExceeded;
        const plan = transform.decodeTransformPlanV1(
            encoded_transform_plan,
        ) catch return Error.TransformFailed;
        const declared_units = std.math.sub(
            u64,
            declared_units_after,
            declared_units_before,
        ) catch return Error.InvalidChunkBoundary;
        if (declared_units_before !=
            self.media_state.visible_units or
            declared_units == 0 or
            declared_units != plan.logical_units)
            return Error.InvalidChunkBoundary;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return Error.InvalidState;

        const index = self.committed_chunks;
        const state_before = self.media_state.*;
        var slot = &self.slots[index];
        slot.* = .{};
        slot.session.init(
            self.bank,
            try derivedKey(self.owner_key_base, index),
            try derivedKey(self.tree_key_base, index),
            try derivedKey(self.authority_key_base, index),
            self.tenant_key,
            self.request_epoch,
            self.media_state,
            encoded_fixture,
            encoded_transform_plan,
        ) catch |err| return err;
        const transaction = slot.session.prepare(
            encoded_fixture,
            encoded_decode_plan,
            encoded_transform_plan,
            decoded_source,
            output,
            mappings,
            scratch,
        ) catch |err| {
            slot.session.closeAndRelease() catch {
                self.poisoned = true;
                return Error.ResourceReceiptInvalid;
            };
            slot.* = .{};
            return err;
        };
        const generation = self.next_generation;
        self.next_generation += 1;
        self.active_slot = index;
        self.active_generation = generation;
        slot.state = .prepared;
        return .{
            .stream = self,
            .inner = transaction,
            .slot_index = index,
            .generation = generation,
            .state_before = state_before,
        };
    }

    pub fn chunkReceipt(
        self: *const StreamSession,
        index: usize,
    ) Error!ChunkReceiptV1 {
        if (index >= self.committed_chunks)
            return Error.InvalidState;
        return self.slots[index].chunk_receipt orelse
            Error.InvalidState;
    }

    pub fn executionReceipt(
        self: *const StreamSession,
        index: usize,
    ) Error!lease.LeaseExecutionReceiptV1 {
        if (index >= self.committed_chunks)
            return Error.InvalidState;
        return self.slots[index].execution_receipt orelse
            Error.InvalidState;
    }

    pub fn closeAndRelease(
        self: *StreamSession,
    ) Error!void {
        if (!self.initialized or self.closed or
            self.active_slot != null or
            self.active_generation != 0)
            return Error.InvalidState;
        for (self.slots[0..self.committed_chunks]) |*slot| {
            if (slot.state == .released) continue;
            if (slot.state != .committed)
                return Error.InvalidState;
            slot.session.closeAndRelease() catch {
                self.poisoned = true;
                return Error.ResourceReceiptInvalid;
            };
            slot.state = .released;
        }
        self.initialized = false;
        self.closed = true;
    }

    fn cleanupFailedChunk(
        self: *StreamSession,
        index: usize,
    ) Error!void {
        var slot = &self.slots[index];
        if (slot.session.initialized)
            slot.session.closeAndRelease() catch {
                self.poisoned = true;
                return Error.ResourceReceiptInvalid;
            };
        slot.* = .{};
        self.active_slot = null;
        self.active_generation = 0;
    }
};

pub const ChunkTransaction = struct {
    stream: *StreamSession,
    inner: lease.Transaction,
    slot_index: usize,
    generation: u64,
    state_before: media.PublicationStateV1,
    state: ChunkTransactionState = .prepared,

    pub fn commit(
        self: *ChunkTransaction,
    ) Error!CommittedChunkV1 {
        if (!self.owns(.prepared))
            return Error.InvalidState;
        const stream = self.stream;
        var slot = &stream.slots[self.slot_index];
        const execution = self.inner.commit() catch |err| {
            self.state = .aborted;
            try stream.cleanupFailedChunk(self.slot_index);
            return err;
        };
        const chunk = makeChunkReceiptV1(
            self.state_before,
            stream.stream_key,
            @intCast(
                stream.chunk_index_base + self.slot_index,
            ),
            stream.previous_chunk_sha256,
            execution,
        ) catch unreachable;
        slot.execution_receipt = execution;
        slot.chunk_receipt = chunk;
        slot.state = .committed;
        stream.previous_chunk_sha256 =
            chunk.receipt_sha256;
        stream.committed_chunks += 1;
        slot.session.retireProvisional() catch {
            self.state = .committed;
            stream.active_slot = null;
            stream.active_generation = 0;
            stream.poisoned = true;
            return Error.ResourceReceiptInvalid;
        };
        stream.active_slot = null;
        stream.active_generation = 0;
        self.state = .committed;
        return .{
            .execution = execution,
            .stream = chunk,
        };
    }

    pub fn abort(self: *ChunkTransaction) Error!void {
        if (!self.owns(.prepared))
            return Error.InvalidState;
        self.inner.abort() catch |err| {
            self.stream.poisoned = true;
            return err;
        };
        self.state = .aborted;
        try self.stream.cleanupFailedChunk(self.slot_index);
    }

    fn owns(
        self: *const ChunkTransaction,
        expected: ChunkTransactionState,
    ) bool {
        return self.state == expected and
            self.stream.initialized and
            !self.stream.closed and
            !self.stream.poisoned and
            self.stream.active_slot == self.slot_index and
            self.stream.active_generation == self.generation and
            self.stream.slots[self.slot_index].state == .prepared;
    }
};

fn validateChunkReceiptShapeV1(
    receipt: ChunkReceiptV1,
) Error!void {
    const previous_valid =
        if (receipt.stream_chunk_index == 0)
            isZero(receipt.previous_chunk_sha256)
        else
            !isZero(receipt.previous_chunk_sha256);
    if (receipt.request_epoch == 0 or
        receipt.stream_key == 0 or
        receipt.stream_chunk_index >= maximum_stream_chunks or
        receipt.publication_sequence == 0 or
        receipt.units_after <= receipt.units_before or
        receipt.output_bytes == 0 or
        receipt.mapping_count == 0 or
        receipt.binding_count == 0 or
        receipt.binding_count > lease.maximum_bindings or
        receipt.provisional_binding_count !=
            receipt.binding_count - 1 or
        !previous_valid or
        isZero(receipt.media_object_sha256) or
        isZero(receipt.transform_plan_sha256) or
        isZero(receipt.lease_receipt_sha256) or
        isZero(receipt.output_sha256) or
        isZero(receipt.publication_commit_sha256) or
        isZero(receipt.receipt_sha256) or
        !std.mem.eql(
            u8,
            &receipt.receipt_sha256,
            &chunkReceiptRootV1(receipt),
        ))
        return Error.InvalidChunkReceipt;
}

fn writeChunkReceiptBodyV1(
    receipt: ChunkReceiptV1,
    output: []u8,
) void {
    std.debug.assert(output.len == chunk_receipt_body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &chunk_receipt_magic);
    writeU64(output, 8, chunk_receipt_abi);
    writeU64(output, 16, chunk_receipt_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(receipt.kind));
    writeU64(output, 40, receipt.request_epoch);
    writeU64(output, 48, receipt.stream_key);
    writeU64(output, 56, receipt.stream_chunk_index);
    writeU64(output, 64, receipt.publication_sequence);
    writeU64(output, 72, receipt.units_before);
    writeU64(output, 80, receipt.units_after);
    writeU64(output, 88, receipt.output_bytes);
    writeU64(output, 96, receipt.mapping_count);
    writeU64(output, 104, receipt.binding_count);
    writeU64(
        output,
        112,
        receipt.provisional_binding_count,
    );
    const roots = [_]Digest{
        receipt.media_object_sha256,
        receipt.transform_plan_sha256,
        receipt.lease_receipt_sha256,
        receipt.output_sha256,
        receipt.publication_commit_sha256,
        receipt.previous_chunk_sha256,
    };
    for (roots, 0..) |root, index|
        @memcpy(
            output[roots_offset + index * 32 .. roots_offset + (index + 1) * 32],
            &root,
        );
}

fn derivedKey(base: u64, index: usize) Error!u64 {
    const value = std.math.add(
        u64,
        base,
        @intCast(index),
    ) catch return Error.ArithmeticOverflow;
    if (value == 0) return Error.InvalidStream;
    return value;
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    @memcpy(output[offset .. offset + 8], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

const TestContext = struct {
    encoded_fixture: []const u8,
    fixture: fixture_api.ParsedFixtureV1,
    encoded_decode_plan: []const u8,
    decode_receipt: fixture_api.DecodeReceiptV1,
    timeline_base: media.TimeBaseV1,
};

fn prepareTestContext(
    case_index: usize,
    fixture_storage: *[fixture_api.maximum_fixture_bytes]u8,
    decode_plan_storage: *[decode_plan.plan_bytes]u8,
    decoded_for_plan: *[fixture_api.maximum_payload_bytes]u8,
) !TestContext {
    const spec = switch (case_index) {
        0 => fixture_api.imageSpecV1(),
        1 => fixture_api.audioSpecV1(),
        2 => fixture_api.videoSpecV1(),
        else => unreachable,
    };
    const encoded_fixture = try fixture_api.encodeFixtureV1(
        spec,
        fixture_storage,
    );
    const fixture = try fixture_api.parseFixtureV1(
        encoded_fixture,
    );
    const fixture_plan = try fixture_api.makeDecodePlanV1(
        fixture,
        [_]u8{0xd1} ** 32,
        [_]u8{0xe1} ** 32,
    );
    const encoded_decode_plan = try decode_plan.encodePlanV1(
        fixture_plan,
        decode_plan_storage,
    );
    const decode_receipt = try fixture_api.decodeFixtureV1(
        encoded_fixture,
        encoded_decode_plan,
        decoded_for_plan,
    );
    return .{
        .encoded_fixture = encoded_fixture,
        .fixture = fixture,
        .encoded_decode_plan = encoded_decode_plan,
        .decode_receipt = decode_receipt,
        .timeline_base = switch (case_index) {
            0 => .{ .numerator = 1, .denominator = 1 },
            1 => .{ .numerator = 1, .denominator = 16_000 },
            2 => fixture.time_base,
            else => unreachable,
        },
    };
}

fn makeChunkPlan(
    context: TestContext,
    case_index: usize,
    chunk_index: usize,
) !transform.TransformPlanV1 {
    return switch (case_index) {
        0 => try transform.makeImagePlanV1(
            context.fixture,
            context.decode_receipt,
            0,
            chunk_index,
            2,
            1,
            2,
            1,
            1,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ),
        1 => try transform.makeAudioPlanV1(
            context.fixture,
            context.decode_receipt,
            chunk_index * 3,
            3,
            16_000,
            1,
            0,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ),
        2 => blk: {
            const selected = [_]u64{@intCast(chunk_index)};
            break :blk try transform.makeVideoPlanV1(
                context.fixture,
                context.decode_receipt,
                &selected,
                [_]u8{0xf1} ** 32,
                [_]u8{0xf2} ** 32,
            );
        },
        else => unreachable,
    };
}

test "stream runtime commits two retained chunks for every media kind" {
    for (0..3) |case_index| {
        var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
            undefined;
        var decode_plan_storage: [decode_plan.plan_bytes]u8 =
            undefined;
        var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
            undefined;
        const context = try prepareTestContext(
            case_index,
            &fixture_storage,
            &decode_plan_storage,
            &decoded_for_plan,
        );
        var slots = [_]resource_bank.Slot{.{}} ** 2;
        var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
        var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
            &slots,
            &roots,
            &nodes,
            .{},
            3100 + case_index,
        );
        const request_epoch: u64 = 3200 + case_index;
        var state = try media.initializePublicationStateV1(
            request_epoch,
            1,
            context.timeline_base,
            context.fixture.media_object_sha256,
            [_]u8{@intCast(0xa0 + case_index)} ** 32,
        );
        var stream: StreamSession = .{};
        try stream.init(
            &bank,
            &state,
            3300 + case_index,
            3400 + case_index * 10,
            3500 + case_index * 10,
            3600 + case_index * 10,
            3700 + case_index,
            request_epoch,
            2,
        );
        var plan_storage: [transform.transform_plan_bytes]u8 =
            undefined;
        var decoded: [fixture_api.maximum_payload_bytes]u8 =
            undefined;
        var outputs: [2][fixture_api.maximum_payload_bytes]u8 =
            undefined;
        var mappings: [4]transform.TransformMappingV1 = undefined;
        var scratch: [1]u8 = undefined;
        var receipts: [2]ChunkReceiptV1 = undefined;
        var total_units: u64 = 0;
        for (0..2) |chunk_index| {
            const plan = try makeChunkPlan(
                context,
                case_index,
                chunk_index,
            );
            const encoded_plan =
                try transform.encodeTransformPlanV1(
                    plan,
                    &plan_storage,
                );
            const state_before = state;
            const units_after = try std.math.add(
                u64,
                state.visible_units,
                plan.logical_units,
            );
            var transaction = try stream.prepareChunk(
                state.visible_units,
                units_after,
                context.encoded_fixture,
                context.encoded_decode_plan,
                encoded_plan,
                &decoded,
                &outputs[chunk_index],
                &mappings,
                scratch[0..0],
            );
            const committed = try transaction.commit();
            try verifyChunkReceiptV1(
                state_before,
                stream.stream_key,
                chunk_index,
                if (chunk_index == 0)
                    [_]u8{0} ** 32
                else
                    receipts[chunk_index - 1].receipt_sha256,
                committed.execution,
                committed.stream,
            );
            receipts[chunk_index] = committed.stream;
            total_units += plan.logical_units;
            const snapshot = try bank.snapshotV3();
            try std.testing.expectEqual(
                chunk_index + 1,
                snapshot.live_allocations,
            );
            try std.testing.expectEqual(
                chunk_index + 1,
                snapshot.active_lease_trees,
            );
        }
        try std.testing.expectEqual(@as(u64, 2), state.visible_chunks);
        try std.testing.expectEqual(total_units, state.visible_units);
        try std.testing.expectEqualSlices(
            u8,
            &receipts[0].receipt_sha256,
            &receipts[1].previous_chunk_sha256,
        );
        const output_roots: [2]Digest = .{
            receipts[0].output_sha256,
            receipts[1].output_sha256,
        };
        try stream.closeAndRelease();
        const final = try bank.snapshotV3();
        try std.testing.expect(final.used.isZero());
        try std.testing.expectEqual(
            @as(usize, 0),
            final.live_allocations,
        );
        for (outputs, output_roots) |output, output_root| {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            const output_bytes: usize = switch (case_index) {
                0 => 6,
                1 => 2,
                2 => 4,
                else => unreachable,
            };
            hash.update(output[0..output_bytes]);
            var actual: Digest = undefined;
            hash.final(&actual);
            try std.testing.expectEqualSlices(
                u8,
                &output_root,
                &actual,
            );
        }
    }
}

test "stream rejects target gaps overlaps length drift and capacity" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    const context = try prepareTestContext(
        0,
        &fixture_storage,
        &decode_plan_storage,
        &decoded_for_plan,
    );
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{},
        3801,
    );
    var state = try media.initializePublicationStateV1(
        3802,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xb1} ** 32,
    );
    var stream: StreamSession = .{};
    try stream.init(
        &bank,
        &state,
        3803,
        3810,
        3820,
        3830,
        3840,
        3802,
        2,
    );
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var outputs: [2][fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    const first_plan = try makeChunkPlan(context, 0, 0);
    const first_encoded = try transform.encodeTransformPlanV1(
        first_plan,
        &plan_storage,
    );
    var first = try stream.prepareChunk(
        0,
        first_plan.logical_units,
        context.encoded_fixture,
        context.encoded_decode_plan,
        first_encoded,
        &decoded,
        &outputs[0],
        &mappings,
        scratch[0..0],
    );
    _ = try first.commit();
    const used_before = (try bank.snapshot()).used;
    const second_plan = try makeChunkPlan(context, 0, 1);
    const second_encoded = try transform.encodeTransformPlanV1(
        second_plan,
        &plan_storage,
    );
    try std.testing.expectError(
        Error.InvalidChunkBoundary,
        stream.prepareChunk(
            state.visible_units + 1,
            state.visible_units + 1 + second_plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            second_encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        ),
    );
    try std.testing.expectError(
        Error.InvalidChunkBoundary,
        stream.prepareChunk(
            state.visible_units - 1,
            state.visible_units - 1 + second_plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            second_encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        ),
    );
    try std.testing.expectError(
        Error.InvalidChunkBoundary,
        stream.prepareChunk(
            state.visible_units,
            state.visible_units + second_plan.logical_units + 1,
            context.encoded_fixture,
            context.encoded_decode_plan,
            second_encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        ),
    );
    try std.testing.expect(std.meta.eql(
        used_before,
        (try bank.snapshot()).used,
    ));
    var second = try stream.prepareChunk(
        state.visible_units,
        state.visible_units + second_plan.logical_units,
        context.encoded_fixture,
        context.encoded_decode_plan,
        second_encoded,
        &decoded,
        &outputs[1],
        &mappings,
        scratch[0..0],
    );
    _ = try second.commit();
    try std.testing.expectError(
        Error.StreamCapacityExceeded,
        stream.prepareChunk(
            state.visible_units,
            state.visible_units + second_plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            second_encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        ),
    );
    try stream.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "stream cancellation and candidate drift reclaim unpublished leases" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    const context = try prepareTestContext(
        1,
        &fixture_storage,
        &decode_plan_storage,
        &decoded_for_plan,
    );
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{},
        3901,
    );
    var state = try media.initializePublicationStateV1(
        3902,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xb2} ** 32,
    );
    var stream: StreamSession = .{};
    try stream.init(
        &bank,
        &state,
        3903,
        3910,
        3920,
        3930,
        3940,
        3902,
        2,
    );
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var outputs: [2][fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    for (0..2) |chunk_index| {
        const plan = try makeChunkPlan(context, 1, chunk_index);
        const encoded = try transform.encodeTransformPlanV1(
            plan,
            &plan_storage,
        );
        if (chunk_index == 0) {
            var first = try stream.prepareChunk(
                state.visible_units,
                state.visible_units + plan.logical_units,
                context.encoded_fixture,
                context.encoded_decode_plan,
                encoded,
                &decoded,
                &outputs[0],
                &mappings,
                scratch[0..0],
            );
            _ = try first.commit();
            continue;
        }
        const state_before = state;
        const used_before = (try bank.snapshot()).used;
        var cancelled = try stream.prepareChunk(
            state.visible_units,
            state.visible_units + plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        );
        var copied = cancelled;
        try cancelled.abort();
        try std.testing.expectError(
            Error.InvalidState,
            copied.abort(),
        );
        try std.testing.expect(std.meta.eql(state_before, state));
        try std.testing.expect(std.meta.eql(
            used_before,
            (try bank.snapshot()).used,
        ));

        var damaged = try stream.prepareChunk(
            state.visible_units,
            state.visible_units + plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        );
        outputs[1][0] ^= 1;
        try std.testing.expectError(
            Error.TransformFailed,
            damaged.commit(),
        );
        try std.testing.expect(std.meta.eql(state_before, state));
        try std.testing.expect(std.meta.eql(
            used_before,
            (try bank.snapshot()).used,
        ));

        var retry = try stream.prepareChunk(
            state.visible_units,
            state.visible_units + plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        );
        _ = try retry.commit();
    }
    try std.testing.expectEqual(@as(u64, 2), state.visible_chunks);
    try stream.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "stream pressure rejects the next chunk without dropping retained output" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    const context = try prepareTestContext(
        0,
        &fixture_storage,
        &decode_plan_storage,
        &decoded_for_plan,
    );
    const first_plan = try makeChunkPlan(context, 0, 0);
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    const first_encoded = try transform.encodeTransformPlanV1(
        first_plan,
        &plan_storage,
    );
    const one_chunk_claim = try flat.claimForExecutionV1(
        context.encoded_fixture.len,
        first_plan,
    );
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        try flat.limitsForClaimV1(one_chunk_claim),
        3951,
    );
    var state = try media.initializePublicationStateV1(
        3952,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xb4} ** 32,
    );
    var stream: StreamSession = .{};
    try stream.init(
        &bank,
        &state,
        3953,
        3960,
        3970,
        3980,
        3990,
        3952,
        2,
    );
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var outputs: [2][fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    var first = try stream.prepareChunk(
        0,
        first_plan.logical_units,
        context.encoded_fixture,
        context.encoded_decode_plan,
        first_encoded,
        &decoded,
        &outputs[0],
        &mappings,
        scratch[0..0],
    );
    _ = try first.commit();
    const state_before = state;
    const snapshot_before = try bank.snapshotV3();
    const second_plan = try makeChunkPlan(context, 0, 1);
    const second_encoded = try transform.encodeTransformPlanV1(
        second_plan,
        &plan_storage,
    );
    try std.testing.expectError(
        Error.ResourceAdmissionFailed,
        stream.prepareChunk(
            state.visible_units,
            state.visible_units + second_plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            second_encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        ),
    );
    const snapshot_after = try bank.snapshotV3();
    try std.testing.expect(std.meta.eql(state_before, state));
    try std.testing.expect(std.meta.eql(
        snapshot_before.used,
        snapshot_after.used,
    ));
    try std.testing.expectEqual(
        @as(usize, 1),
        snapshot_after.live_allocations,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        snapshot_after.active_lease_trees,
    );
    try stream.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "stream chunk receipt rejects every byte and rehashed contradiction" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    const context = try prepareTestContext(
        2,
        &fixture_storage,
        &decode_plan_storage,
        &decoded_for_plan,
    );
    const plan = try makeChunkPlan(context, 2, 0);
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    const encoded_plan = try transform.encodeTransformPlanV1(
        plan,
        &plan_storage,
    );
    var slots = [_]resource_bank.Slot{.{}};
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{},
        4001,
    );
    var state = try media.initializePublicationStateV1(
        4002,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xb3} ** 32,
    );
    const state_before = state;
    var stream: StreamSession = .{};
    try stream.init(
        &bank,
        &state,
        4003,
        4010,
        4020,
        4030,
        4040,
        4002,
        1,
    );
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    var transaction = try stream.prepareChunk(
        0,
        plan.logical_units,
        context.encoded_fixture,
        context.encoded_decode_plan,
        encoded_plan,
        &decoded,
        &output,
        &mappings,
        scratch[0..0],
    );
    const committed = try transaction.commit();
    var encoded_storage: [chunk_receipt_bytes]u8 = undefined;
    const encoded = try encodeChunkReceiptV1(
        committed.stream,
        &encoded_storage,
    );
    var corrupted: [chunk_receipt_bytes]u8 = undefined;
    for (0..chunk_receipt_bytes) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodeChunkReceiptV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }

    @memcpy(&corrupted, encoded);
    writeU64(
        &corrupted,
        80,
        committed.stream.units_after + 1,
    );
    var forged = committed.stream;
    forged.units_after += 1;
    const forged_root = chunkReceiptRootV1(forged);
    @memcpy(
        corrupted[chunk_receipt_body_bytes..],
        &forged_root,
    );
    const decoded_forgery = try decodeChunkReceiptV1(
        &corrupted,
    );
    try std.testing.expectError(
        Error.InvalidChunkReceipt,
        verifyChunkReceiptV1(
            state_before,
            stream.stream_key,
            0,
            [_]u8{0} ** 32,
            committed.execution,
            decoded_forgery,
        ),
    );

    @memcpy(&corrupted, encoded);
    var excessive_index = committed.stream;
    excessive_index.stream_chunk_index = maximum_stream_chunks;
    excessive_index.previous_chunk_sha256 = [_]u8{0xcc} ** 32;
    writeU64(&corrupted, 56, maximum_stream_chunks);
    @memcpy(
        corrupted[288..320],
        &excessive_index.previous_chunk_sha256,
    );
    const excessive_index_root =
        chunkReceiptRootV1(excessive_index);
    @memcpy(
        corrupted[chunk_receipt_body_bytes..],
        &excessive_index_root,
    );
    try std.testing.expectError(
        Error.InvalidChunkReceipt,
        decodeChunkReceiptV1(&corrupted),
    );

    @memcpy(&corrupted, encoded);
    var excessive_provisional = committed.stream;
    excessive_provisional.provisional_binding_count =
        std.math.maxInt(u64);
    writeU64(&corrupted, 112, std.math.maxInt(u64));
    const excessive_provisional_root =
        chunkReceiptRootV1(excessive_provisional);
    @memcpy(
        corrupted[chunk_receipt_body_bytes..],
        &excessive_provisional_root,
    );
    try std.testing.expectError(
        Error.InvalidChunkReceipt,
        decodeChunkReceiptV1(&corrupted),
    );
    try stream.closeAndRelease();
}

test "stream chunk chain matches independent two-bank golden roots" {
    const expected_roots = [_]Digest{
        [_]u8{
            0x0e, 0xb6, 0x96, 0xdf, 0x27, 0xc1, 0xf2, 0x26,
            0xb8, 0x47, 0x51, 0xfe, 0xdc, 0xe6, 0xf1, 0x2e,
            0xfc, 0x56, 0x66, 0x38, 0x75, 0x3b, 0x16, 0xb2,
            0x78, 0xc2, 0x2e, 0xb7, 0x7a, 0xc5, 0x2e, 0x15,
        },
        [_]u8{
            0xdb, 0x98, 0x0b, 0x30, 0x6c, 0x87, 0x79, 0xfc,
            0x7f, 0x3c, 0x0d, 0x44, 0xd8, 0x3f, 0x15, 0x09,
            0xb0, 0xf2, 0x76, 0xa2, 0xbc, 0x43, 0x3c, 0xab,
            0x61, 0xe4, 0x62, 0xdb, 0x27, 0x14, 0x61, 0xec,
        },
    };
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    const context = try prepareTestContext(
        0,
        &fixture_storage,
        &decode_plan_storage,
        &decoded_for_plan,
    );
    var state = try media.initializePublicationStateV1(
        4100,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xa0} ** 32,
    );
    var previous: Digest = [_]u8{0} ** 32;
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    for (0..2) |chunk_index| {
        const plan = try makeChunkPlan(context, 0, chunk_index);
        const encoded_plan = try transform.encodeTransformPlanV1(
            plan,
            &plan_storage,
        );
        var slots = [_]resource_bank.Slot{.{}};
        var roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
        var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
            &slots,
            &roots,
            &nodes,
            .{},
            4200 + chunk_index,
        );
        const state_before = state;
        var session: lease.Session = .{};
        try session.init(
            &bank,
            4300 + chunk_index,
            4400 + chunk_index,
            4500 + chunk_index,
            4600,
            4100,
            &state,
            context.encoded_fixture,
            encoded_plan,
        );
        var transaction = try session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            encoded_plan,
            &decoded,
            &output,
            &mappings,
            scratch[0..0],
        );
        const execution = try transaction.commit();
        const receipt = try makeChunkReceiptV1(
            state_before,
            4700,
            chunk_index,
            previous,
            execution,
        );
        try std.testing.expectEqualSlices(
            u8,
            &expected_roots[chunk_index],
            &receipt.receipt_sha256,
        );
        previous = receipt.receipt_sha256;
        try session.retireProvisional();
        try session.closeAndRelease();
        try std.testing.expect((try bank.snapshot()).used.isZero());
    }
}
