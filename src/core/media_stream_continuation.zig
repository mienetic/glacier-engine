//! Fixed media-stream checkpoints and fresh-generation output reacquisition.

const std = @import("std");
const resource_bank = @import("resource_bank.zig");
const media = @import("media_contract.zig");
const decode_plan = @import("media_decode_plan.zig");
const fixture_api = @import("media_fixture.zig");
const transform = @import("media_transform.zig");
const lease = @import("media_runtime_lease.zig");
const stream_runtime = @import("media_stream_runtime.zig");

pub const Digest = [32]u8;
pub const checkpoint_abi: u64 = 0x474d_534b_0000_0001;
pub const checkpoint_magic =
    [_]u8{ 'G', 'M', 'S', 'K', 'P', 'T', '1', 0 };
pub const maximum_retained_outputs =
    stream_runtime.maximum_stream_chunks;
pub const checkpoint_header_bytes: usize = 480;
pub const checkpoint_entry_bytes: usize = 384;
pub const checkpoint_body_bytes: usize =
    checkpoint_header_bytes +
    maximum_retained_outputs * checkpoint_entry_bytes;
pub const checkpoint_bytes: usize =
    checkpoint_body_bytes + 32;
pub const allowed_flags: u64 = 0;

const digest_offset: usize = 192;
const entry_offset: usize = checkpoint_header_bytes;
const checkpoint_domain =
    "glacier-media-stream-checkpoint-v1\x00";
const retained_manifest_domain =
    "glacier-media-stream-retained-manifest-v1\x00";
const restored_ownership_domain =
    "glacier-media-stream-restored-ownership-v1\x00";
const restored_scope_key_base: u64 =
    0x6d73_6373_0000_0000;
const restored_allocation_key_base: u64 =
    0x6d73_6361_0000_0000;
const restored_binding_key_base: u64 =
    0x6d73_6362_0000_0000;

comptime {
    if (checkpoint_body_bytes != 2016 or
        checkpoint_bytes != 2048)
        @compileError("media stream checkpoint layout drift");
}

pub const Error = stream_runtime.Error ||
    resource_bank.Error || error{
    InvalidCheckpoint,
    CheckpointExpectationMismatch,
    InvalidMaterialization,
    ResumePoisoned,
    TargetNotFresh,
};

pub const CheckpointEntryV1 = struct {
    chunk_index: u64 = 0,
    publication_sequence: u64 = 0,
    output_bytes: u64 = 0,
    source_bank_epoch: u64 = 0,
    source_receipt_slot_index: u64 = 0,
    source_receipt_generation: u64 = 0,
    source_owner_key: u64 = 0,
    restore_owner_key: u64 = 0,
    restore_tree_key: u64 = 0,
    restore_authority_key: u64 = 0,
    tenant_key: u64 = 0,
    scope_key: u64 = 0,
    allocation_key: u64 = 0,
    binding_key: u64 = 0,
    publication_next_sequence: u64 = 0,
    parent_claim: resource_bank.Claim = .{},
    output_claim: resource_bank.Claim = .{},
    output_sha256: Digest = [_]u8{0} ** 32,
    chunk_receipt_sha256: Digest = [_]u8{0} ** 32,
    lease_receipt_sha256: Digest = [_]u8{0} ** 32,
};

pub const CheckpointV1 = struct {
    kind: media.MediaKindV1,
    request_epoch: u64,
    checkpoint_generation: u64,
    stream_key: u64,
    committed_chunks: u64,
    chunk_limit: u64,
    next_sequence: u64,
    visible_chunks: u64,
    visible_units: u64,
    timeline_base: media.TimeBaseV1,
    retained_output_count: usize,
    restore_bank_epoch: u64,
    next_owner_key_base: u64,
    next_tree_key_base: u64,
    next_authority_key_base: u64,
    tenant_key: u64,
    media_object_sha256: Digest,
    timeline_sha256: Digest,
    previous_commit_sha256: Digest,
    last_chunk_sha256: Digest,
    challenge_sha256: Digest,
    retained_manifest_sha256: Digest,
    previous_checkpoint_sha256: Digest,
    entries: [maximum_retained_outputs]CheckpointEntryV1,
    checkpoint_sha256: Digest,
};

pub const CheckpointPlanV1 = struct {
    checkpoint_generation: u64,
    chunk_limit: usize,
    restore_bank_epoch: u64,
    restore_owner_key_base: u64,
    restore_tree_key_base: u64,
    restore_authority_key_base: u64,
    next_owner_key_base: u64,
    next_tree_key_base: u64,
    next_authority_key_base: u64,
    tenant_key: u64,
    challenge_sha256: Digest,
    previous_checkpoint_sha256: Digest = [_]u8{0} ** 32,
};

pub fn makeCheckpointV1(
    source: *const stream_runtime.StreamSession,
    kind: media.MediaKindV1,
    plan: CheckpointPlanV1,
    retained_outputs: []const []const u8,
) Error!CheckpointV1 {
    if (!source.initialized or source.closed or source.poisoned or
        source.active_slot != null or
        source.active_generation != 0 or
        source.chunk_index_base != 0 or
        source.committed_chunks == 0 or
        source.committed_chunks >= source.chunk_limit or
        plan.chunk_limit != source.chunk_limit or
        retained_outputs.len != source.committed_chunks or
        plan.restore_bank_epoch == 0 or
        plan.restore_owner_key_base == 0 or
        plan.restore_tree_key_base == 0 or
        plan.restore_authority_key_base == 0 or
        plan.next_owner_key_base == 0 or
        plan.next_tree_key_base == 0 or
        plan.next_authority_key_base == 0 or
        plan.tenant_key == 0 or
        plan.checkpoint_generation == 0 or
        isZero(plan.challenge_sha256) or
        (plan.checkpoint_generation == 1 and
            !isZero(plan.previous_checkpoint_sha256)) or
        (plan.checkpoint_generation != 1 and
            isZero(plan.previous_checkpoint_sha256)))
        return Error.InvalidCheckpoint;

    const state = source.media_state.*;
    if (state.request_epoch != source.request_epoch or
        state.visible_chunks != source.committed_chunks)
        return Error.InvalidCheckpoint;

    var checkpoint: CheckpointV1 = .{
        .kind = kind,
        .request_epoch = state.request_epoch,
        .checkpoint_generation = plan.checkpoint_generation,
        .stream_key = source.stream_key,
        .committed_chunks = source.committed_chunks,
        .chunk_limit = plan.chunk_limit,
        .next_sequence = state.next_sequence,
        .visible_chunks = state.visible_chunks,
        .visible_units = state.visible_units,
        .timeline_base = state.timeline_base,
        .retained_output_count = source.committed_chunks,
        .restore_bank_epoch = plan.restore_bank_epoch,
        .next_owner_key_base = plan.next_owner_key_base,
        .next_tree_key_base = plan.next_tree_key_base,
        .next_authority_key_base = plan.next_authority_key_base,
        .tenant_key = plan.tenant_key,
        .media_object_sha256 = state.media_object_sha256,
        .timeline_sha256 = state.timeline_sha256,
        .previous_commit_sha256 = state.previous_commit_sha256,
        .last_chunk_sha256 = source.previous_chunk_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .retained_manifest_sha256 = [_]u8{0} ** 32,
        .previous_checkpoint_sha256 = plan.previous_checkpoint_sha256,
        .entries = [_]CheckpointEntryV1{.{}} **
            maximum_retained_outputs,
        .checkpoint_sha256 = [_]u8{0} ** 32,
    };
    var previous_chunk_sha256: Digest = [_]u8{0} ** 32;
    var final_units_after: u64 = 0;
    for (
        retained_outputs,
        0..,
    ) |output, index| {
        const execution = try source.executionReceipt(index);
        const chunk = try source.chunkReceipt(index);
        const output_bytes = std.math.cast(
            u64,
            output.len,
        ) orelse return Error.ArithmeticOverflow;
        const resource_next_sequence = std.math.add(
            u64,
            execution.resource_sequence,
            1,
        ) catch return Error.ArithmeticOverflow;
        var execution_wire: [lease.receipt_bytes]u8 = undefined;
        _ = lease.encodeLeaseExecutionReceiptV1(
            execution,
            &execution_wire,
        ) catch return Error.InvalidCheckpoint;
        var chunk_wire: [stream_runtime.chunk_receipt_bytes]u8 =
            undefined;
        _ = stream_runtime.encodeChunkReceiptV1(
            chunk,
            &chunk_wire,
        ) catch return Error.InvalidCheckpoint;
        if (execution.kind != kind or
            chunk.kind != kind or
            execution.request_epoch != state.request_epoch or
            chunk.request_epoch != state.request_epoch or
            chunk.stream_key != source.stream_key or
            chunk.stream_chunk_index != index or
            chunk.publication_sequence !=
                execution.media_sequence or
            !std.mem.eql(
                u8,
                &chunk.media_object_sha256,
                &state.media_object_sha256,
            ) or
            !std.mem.eql(
                u8,
                &chunk.lease_receipt_sha256,
                &execution.receipt_sha256,
            ) or
            !std.mem.eql(
                u8,
                &chunk.previous_chunk_sha256,
                &previous_chunk_sha256,
            ) or
            output_bytes != execution.output_bytes or
            !std.mem.eql(
                u8,
                &sha256(output),
                &execution.output_sha256,
            ) or
            !std.mem.eql(
                u8,
                &chunk.output_sha256,
                &execution.output_sha256,
            ) or
            execution.tree.parent.bank_epoch ==
                plan.restore_bank_epoch)
            return Error.InvalidCheckpoint;
        previous_chunk_sha256 = chunk.receipt_sha256;
        final_units_after = chunk.units_after;
        checkpoint.entries[index] = .{
            .chunk_index = chunk.stream_chunk_index,
            .publication_sequence = chunk.publication_sequence,
            .output_bytes = output_bytes,
            .source_bank_epoch = execution.tree.parent.bank_epoch,
            .source_receipt_slot_index = execution.tree.parent.slot_index,
            .source_receipt_generation = execution.tree.parent.generation,
            .source_owner_key = execution.tree.parent.owner_key,
            .restore_owner_key = try derivedKey(
                plan.restore_owner_key_base,
                index,
            ),
            .restore_tree_key = try derivedKey(
                plan.restore_tree_key_base,
                index,
            ),
            .restore_authority_key = try derivedKey(
                plan.restore_authority_key_base,
                index,
            ),
            .tenant_key = plan.tenant_key,
            .scope_key = try derivedKey(
                restored_scope_key_base,
                index,
            ),
            .allocation_key = try derivedKey(
                restored_allocation_key_base,
                index,
            ),
            .binding_key = try derivedKey(
                restored_binding_key_base,
                index,
            ),
            .publication_next_sequence = resource_next_sequence,
            .parent_claim = execution.tree.parent.claim,
            .output_claim = .{
                .output_journal_bytes = output_bytes,
            },
            .output_sha256 = execution.output_sha256,
            .chunk_receipt_sha256 = chunk.receipt_sha256,
            .lease_receipt_sha256 = execution.receipt_sha256,
        };
    }
    const last_chunk =
        checkpoint.entries[source.committed_chunks - 1];
    const expected_next_sequence = std.math.add(
        u64,
        last_chunk.publication_sequence,
        1,
    ) catch return Error.InvalidCheckpoint;
    if (state.visible_units != final_units_after or
        state.next_sequence != expected_next_sequence or
        !std.mem.eql(
            u8,
            &previous_chunk_sha256,
            &source.previous_chunk_sha256,
        ))
        return Error.InvalidCheckpoint;
    checkpoint.retained_manifest_sha256 =
        retainedManifestRootV1(
            checkpoint.entries[0..checkpoint.retained_output_count],
        );
    checkpoint.checkpoint_sha256 =
        checkpointRootV1(checkpoint);
    try validateCheckpointV1(checkpoint);
    return checkpoint;
}

pub fn encodeCheckpointV1(
    checkpoint: CheckpointV1,
    storage: *[checkpoint_bytes]u8,
) Error![]const u8 {
    try validateCheckpointV1(checkpoint);
    writeCheckpointBodyV1(
        checkpoint,
        storage[0..checkpoint_body_bytes],
    );
    @memcpy(
        storage[checkpoint_body_bytes..checkpoint_bytes],
        &checkpoint.checkpoint_sha256,
    );
    return storage;
}

pub fn decodeCheckpointV1(
    encoded: []const u8,
) Error!CheckpointV1 {
    if (encoded.len != checkpoint_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &checkpoint_magic,
        ) or
        readU64(encoded, 8) != checkpoint_abi or
        readU64(encoded, 16) != checkpoint_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[168..192], 0) or
        !std.mem.allEqual(
            u8,
            encoded[416..checkpoint_header_bytes],
            0,
        ))
        return Error.InvalidCheckpoint;
    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidCheckpoint;
    const retained_count = std.math.cast(
        usize,
        readU64(encoded, 120),
    ) orelse return Error.InvalidCheckpoint;
    var checkpoint: CheckpointV1 = .{
        .kind = kind,
        .request_epoch = readU64(encoded, 40),
        .checkpoint_generation = readU64(encoded, 48),
        .stream_key = readU64(encoded, 56),
        .committed_chunks = readU64(encoded, 64),
        .chunk_limit = readU64(encoded, 72),
        .next_sequence = readU64(encoded, 80),
        .visible_chunks = readU64(encoded, 88),
        .visible_units = readU64(encoded, 96),
        .timeline_base = .{
            .numerator = readU64(encoded, 104),
            .denominator = readU64(encoded, 112),
        },
        .retained_output_count = retained_count,
        .restore_bank_epoch = readU64(encoded, 128),
        .next_owner_key_base = readU64(encoded, 136),
        .next_tree_key_base = readU64(encoded, 144),
        .next_authority_key_base = readU64(encoded, 152),
        .tenant_key = readU64(encoded, 160),
        .media_object_sha256 = encoded[digest_offset .. digest_offset + 32].*,
        .timeline_sha256 = encoded[digest_offset + 32 .. digest_offset + 64].*,
        .previous_commit_sha256 = encoded[digest_offset + 64 .. digest_offset + 96].*,
        .last_chunk_sha256 = encoded[digest_offset + 96 .. digest_offset + 128].*,
        .challenge_sha256 = encoded[digest_offset + 128 .. digest_offset + 160].*,
        .retained_manifest_sha256 = encoded[digest_offset + 160 .. digest_offset + 192].*,
        .previous_checkpoint_sha256 = encoded[digest_offset + 192 .. digest_offset + 224].*,
        .entries = [_]CheckpointEntryV1{.{}} **
            maximum_retained_outputs,
        .checkpoint_sha256 = encoded[checkpoint_body_bytes..checkpoint_bytes].*,
    };
    for (&checkpoint.entries, 0..) |*entry, index| {
        const start = entry_offset +
            index * checkpoint_entry_bytes;
        const record =
            encoded[start .. start + checkpoint_entry_bytes];
        if (index < retained_count) {
            entry.* = try decodeEntryV1(record);
        } else if (!std.mem.allEqual(u8, record, 0)) {
            return Error.InvalidCheckpoint;
        }
    }
    try validateCheckpointV1(checkpoint);
    return checkpoint;
}

pub fn checkpointRootV1(
    checkpoint: CheckpointV1,
) Digest {
    var body: [checkpoint_body_bytes]u8 = undefined;
    writeCheckpointBodyV1(checkpoint, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checkpoint_domain);
    hash.update(&body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn retainedManifestRootV1(
    entries: []const CheckpointEntryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(retained_manifest_domain);
    var count_bytes: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &count_bytes,
        @intCast(entries.len),
        .little,
    );
    hash.update(&count_bytes);
    var encoded: [checkpoint_entry_bytes]u8 = undefined;
    for (entries) |entry| {
        writeEntryV1(entry, &encoded);
        hash.update(&encoded);
    }
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn restoredOwnershipReceiptRootV1(
    previous_checkpoint_sha256: Digest,
    prior: CheckpointEntryV1,
    successor: CheckpointEntryV1,
) Digest {
    var body: [416]u8 = [_]u8{0} ** 416;
    writeU64(&body, 0, successor.chunk_index);
    writeU64(&body, 8, successor.publication_sequence);
    writeU64(&body, 16, successor.output_bytes);
    writeU64(&body, 24, successor.source_bank_epoch);
    writeU64(
        &body,
        32,
        successor.source_receipt_slot_index,
    );
    writeU64(
        &body,
        40,
        successor.source_receipt_generation,
    );
    writeU64(&body, 48, successor.source_owner_key);
    writeU64(
        &body,
        56,
        successor.publication_next_sequence,
    );
    writeClaim(&body, 64, successor.parent_claim);
    writeClaim(&body, 144, successor.output_claim);
    @memcpy(body[224..256], &previous_checkpoint_sha256);
    @memcpy(
        body[256..288],
        &prior.lease_receipt_sha256,
    );
    @memcpy(body[288..320], &prior.output_sha256);
    @memcpy(
        body[320..352],
        &prior.chunk_receipt_sha256,
    );
    @memcpy(body[352..384], &successor.output_sha256);
    @memcpy(
        body[384..416],
        &successor.chunk_receipt_sha256,
    );
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(restored_ownership_domain);
    hash.update(&body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn validateRestoredSuccessorCheckpointV1(
    previous: CheckpointV1,
    successor: CheckpointV1,
) Error!void {
    try validateCheckpointV1(previous);
    try validateCheckpointV1(successor);
    const expected_generation = std.math.add(
        u64,
        previous.checkpoint_generation,
        1,
    ) catch return Error.InvalidCheckpoint;
    if (successor.checkpoint_generation !=
        expected_generation or
        successor.kind != previous.kind or
        successor.request_epoch != previous.request_epoch or
        successor.stream_key != previous.stream_key or
        successor.chunk_limit != previous.chunk_limit or
        successor.tenant_key != previous.tenant_key or
        successor.committed_chunks !=
            previous.committed_chunks + 1 or
        successor.visible_chunks !=
            previous.visible_chunks + 1 or
        successor.next_sequence !=
            previous.next_sequence + 1 or
        successor.visible_units <= previous.visible_units or
        successor.restore_bank_epoch ==
            previous.restore_bank_epoch or
        !std.meta.eql(
            successor.timeline_base,
            previous.timeline_base,
        ) or
        !std.mem.eql(
            u8,
            &successor.media_object_sha256,
            &previous.media_object_sha256,
        ) or
        std.mem.eql(
            u8,
            &successor.timeline_sha256,
            &previous.timeline_sha256,
        ) or
        std.mem.eql(
            u8,
            &successor.previous_commit_sha256,
            &previous.previous_commit_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.challenge_sha256,
            &previous.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.previous_checkpoint_sha256,
            &previous.checkpoint_sha256,
        ))
        return Error.InvalidCheckpoint;

    for (
        successor.entries[0..successor.retained_output_count],
        0..,
    ) |entry, index| {
        if (entry.source_bank_epoch !=
            previous.restore_bank_epoch)
            return Error.InvalidCheckpoint;
        if (index < previous.retained_output_count) {
            const prior = previous.entries[index];
            if (entry.chunk_index != prior.chunk_index or
                entry.publication_sequence !=
                    prior.publication_sequence or
                entry.output_bytes != prior.output_bytes or
                entry.source_owner_key !=
                    prior.restore_owner_key or
                entry.publication_next_sequence !=
                    prior.publication_next_sequence or
                !std.meta.eql(
                    entry.parent_claim,
                    prior.parent_claim,
                ) or
                !std.meta.eql(
                    entry.output_claim,
                    prior.output_claim,
                ) or
                !std.mem.eql(
                    u8,
                    &entry.output_sha256,
                    &prior.output_sha256,
                ) or
                !std.mem.eql(
                    u8,
                    &entry.chunk_receipt_sha256,
                    &prior.chunk_receipt_sha256,
                ) or
                !std.mem.eql(
                    u8,
                    &entry.lease_receipt_sha256,
                    &restoredOwnershipReceiptRootV1(
                        previous.checkpoint_sha256,
                        prior,
                        entry,
                    ),
                ))
                return Error.InvalidCheckpoint;
        } else if (entry.source_owner_key !=
            previous.next_owner_key_base)
        {
            return Error.InvalidCheckpoint;
        }
    }
}

pub fn verifyMaterializedOutputsV1(
    checkpoint: CheckpointV1,
    outputs: []const []const u8,
) Error!void {
    try validateCheckpointV1(checkpoint);
    if (outputs.len != checkpoint.retained_output_count)
        return Error.InvalidMaterialization;
    for (
        outputs,
        checkpoint.entries[0..checkpoint.retained_output_count],
    ) |output, entry| {
        const output_bytes = std.math.cast(
            u64,
            output.len,
        ) orelse return Error.InvalidMaterialization;
        if (output_bytes != entry.output_bytes or
            !std.mem.eql(
                u8,
                &sha256(output),
                &entry.output_sha256,
            ))
            return Error.InvalidMaterialization;
    }
}

const PreparedOutputV1 = struct {
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    batch: resource_bank.LeaseAllocationBatchV1,
    scope: resource_bank.LeaseNodeV1,
    allocation: resource_bank.LeaseNodeV1,
    session_id: usize,
    entry_index: usize,
};

const ActiveOutputV1 = struct {
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    scope: resource_bank.LeaseNodeV1,
    session_id: usize,
    publication_next_sequence: u64,
    active: bool = false,
};

const ResumePhase = enum {
    idle,
    prepared,
    active,
    poisoned,
    closed,
};

pub const ResumeSession = struct {
    bank: *resource_bank.Bank = undefined,
    media_state: *media.PublicationStateV1 = undefined,
    checkpoint: CheckpointV1 = undefined,
    prepared: [maximum_retained_outputs]PreparedOutputV1 =
        undefined,
    prepared_count: usize = 0,
    active_outputs: [maximum_retained_outputs]ActiveOutputV1 =
        undefined,
    active_count: usize = 0,
    stream: stream_runtime.StreamSession = .{},
    phase: ResumePhase = .idle,

    pub fn prepareV1(
        self: *ResumeSession,
        bank: *resource_bank.Bank,
        media_state: *media.PublicationStateV1,
        encoded_checkpoint: []const u8,
        expected_checkpoint_sha256: Digest,
    ) Error!void {
        if (self.phase != .idle)
            return Error.InvalidState;
        const checkpoint = try decodeCheckpointV1(
            encoded_checkpoint,
        );
        if (isZero(expected_checkpoint_sha256) or
            !std.mem.eql(
                u8,
                &checkpoint.checkpoint_sha256,
                &expected_checkpoint_sha256,
            ))
            return Error.CheckpointExpectationMismatch;
        const snapshot = try bank.snapshotV3();
        if (snapshot.bank_epoch !=
            checkpoint.restore_bank_epoch or
            !snapshot.used.isZero() or
            snapshot.live_allocations != 0 or
            snapshot.reserved_unmaterialized_allocations != 0 or
            snapshot.active_lease_trees != 0)
            return Error.TargetNotFresh;

        self.* = .{
            .bank = bank,
            .media_state = media_state,
            .checkpoint = checkpoint,
            .phase = .prepared,
        };
        errdefer {
            self.cleanupPreparedV1() catch {
                self.phase = .poisoned;
            };
            if (self.phase != .poisoned)
                self.phase = .closed;
        }
        for (
            checkpoint.entries[0..checkpoint.retained_output_count],
            0..,
        ) |entry, index| {
            self.prepared[index] = try self.prepareOutputV1(
                entry,
                index,
            );
            self.prepared_count += 1;
        }
    }

    pub fn commitMaterializedV1(
        self: *ResumeSession,
        outputs: []const []const u8,
    ) Error!void {
        if (self.phase == .poisoned)
            return Error.ResumePoisoned;
        if (self.phase != .prepared or
            self.prepared_count !=
                self.checkpoint.retained_output_count)
            return Error.InvalidState;
        try verifyMaterializedOutputsV1(
            self.checkpoint,
            outputs,
        );

        for (
            self.prepared[0..self.prepared_count],
            0..,
        ) |prepared, index| {
            const tree = self.bank
                .commitAllocationsAfterAllocate(
                prepared.batch,
            ) catch {
                self.phase = .poisoned;
                return Error.ResumePoisoned;
            };
            const entry =
                self.checkpoint.entries[prepared.entry_index];
            self.active_outputs[index] = .{
                .receipt = prepared.receipt,
                .tree = tree,
                .scope = prepared.scope,
                .session_id = prepared.session_id,
                .publication_next_sequence = entry.publication_next_sequence,
                .active = true,
            };
            self.active_count += 1;
        }

        self.media_state.* = stateFromCheckpointV1(
            self.checkpoint,
        );
        self.stream.initContinuationV1(
            self.bank,
            self.media_state,
            self.checkpoint.stream_key,
            self.checkpoint.next_owner_key_base,
            self.checkpoint.next_tree_key_base,
            self.checkpoint.next_authority_key_base,
            self.checkpoint.tenant_key,
            self.checkpoint.request_epoch,
            @intCast(self.checkpoint.chunk_limit),
            @intCast(self.checkpoint.committed_chunks),
            self.checkpoint.last_chunk_sha256,
        ) catch {
            self.phase = .poisoned;
            return Error.ResumePoisoned;
        };
        self.phase = .active;
    }

    pub fn makeSuccessorCheckpointV1(
        self: *ResumeSession,
        kind: media.MediaKindV1,
        plan: CheckpointPlanV1,
        retained_outputs: []const []const u8,
    ) Error!CheckpointV1 {
        if (self.phase != .active or
            self.stream.closed or self.stream.poisoned or
            self.stream.active_slot != null or
            self.stream.active_generation != 0 or
            self.stream.chunk_index_base !=
                self.checkpoint.committed_chunks or
            self.stream.committed_chunks != 1 or
            self.active_count !=
                self.checkpoint.retained_output_count)
            return Error.InvalidCheckpoint;
        const expected_generation = std.math.add(
            u64,
            self.checkpoint.checkpoint_generation,
            1,
        ) catch return Error.ArithmeticOverflow;
        const retained_count = std.math.add(
            usize,
            self.checkpoint.retained_output_count,
            self.stream.committed_chunks,
        ) catch return Error.ArithmeticOverflow;
        if (plan.checkpoint_generation != expected_generation or
            plan.chunk_limit != self.stream.chunk_limit or
            retained_count != retained_outputs.len or
            retained_count >= plan.chunk_limit or
            plan.restore_bank_epoch ==
                self.checkpoint.restore_bank_epoch or
            plan.tenant_key != self.checkpoint.tenant_key or
            !std.mem.eql(
                u8,
                &plan.challenge_sha256,
                &self.checkpoint.challenge_sha256,
            ) or
            !std.mem.eql(
                u8,
                &plan.previous_checkpoint_sha256,
                &self.checkpoint.checkpoint_sha256,
            ))
            return Error.InvalidCheckpoint;
        try verifyMaterializedOutputsV1(
            self.checkpoint,
            retained_outputs[0..self.checkpoint.retained_output_count],
        );
        const snapshot = try self.bank.snapshotV3();
        if (snapshot.bank_epoch !=
            self.checkpoint.restore_bank_epoch or
            snapshot.used.isZero() or
            snapshot.live_allocations <
                self.checkpoint.retained_output_count)
            return Error.InvalidCheckpoint;

        const state = self.media_state.*;
        if (state.request_epoch !=
            self.checkpoint.request_epoch or
            state.visible_chunks != retained_count or
            std.mem.eql(
                u8,
                &self.stream.previous_chunk_sha256,
                &self.checkpoint.last_chunk_sha256,
            ))
            return Error.InvalidCheckpoint;

        var checkpoint: CheckpointV1 = .{
            .kind = kind,
            .request_epoch = state.request_epoch,
            .checkpoint_generation = plan.checkpoint_generation,
            .stream_key = self.checkpoint.stream_key,
            .committed_chunks = @intCast(retained_count),
            .chunk_limit = @intCast(plan.chunk_limit),
            .next_sequence = state.next_sequence,
            .visible_chunks = state.visible_chunks,
            .visible_units = state.visible_units,
            .timeline_base = state.timeline_base,
            .retained_output_count = retained_count,
            .restore_bank_epoch = plan.restore_bank_epoch,
            .next_owner_key_base = plan.next_owner_key_base,
            .next_tree_key_base = plan.next_tree_key_base,
            .next_authority_key_base = plan.next_authority_key_base,
            .tenant_key = plan.tenant_key,
            .media_object_sha256 = state.media_object_sha256,
            .timeline_sha256 = state.timeline_sha256,
            .previous_commit_sha256 = state.previous_commit_sha256,
            .last_chunk_sha256 = self.stream.previous_chunk_sha256,
            .challenge_sha256 = plan.challenge_sha256,
            .retained_manifest_sha256 = [_]u8{0} ** 32,
            .previous_checkpoint_sha256 = plan.previous_checkpoint_sha256,
            .entries = [_]CheckpointEntryV1{.{}} **
                maximum_retained_outputs,
            .checkpoint_sha256 = [_]u8{0} ** 32,
        };

        for (
            self.active_outputs[0..self.checkpoint.retained_output_count],
            0..,
        ) |active, index| {
            if (!active.active)
                return Error.InvalidCheckpoint;
            try self.bank.validateCommitted(active.receipt);
            try self.bank.validateLeaseTree(active.tree);
            try self.bank.validateLeaseNode(
                active.tree,
                active.scope,
            );
            const prior = self.checkpoint.entries[index];
            const output = retained_outputs[index];
            const output_bytes = std.math.cast(
                u64,
                output.len,
            ) orelse return Error.ArithmeticOverflow;
            if (active.receipt.bank_epoch !=
                self.checkpoint.restore_bank_epoch or
                active.receipt.owner_key !=
                    prior.restore_owner_key or
                !std.meta.eql(
                    active.receipt.claim,
                    prior.parent_claim,
                ) or
                active.tree.tree_key !=
                    prior.restore_tree_key or
                active.tree.authority_key !=
                    prior.restore_authority_key or
                active.scope.node_key != prior.scope_key or
                active.scope.tenant_key !=
                    prior.tenant_key or
                active.publication_next_sequence !=
                    prior.publication_next_sequence or
                output_bytes != prior.output_bytes or
                !std.mem.eql(
                    u8,
                    &sha256(output),
                    &prior.output_sha256,
                ))
                return Error.InvalidCheckpoint;
            var entry: CheckpointEntryV1 = .{
                .chunk_index = prior.chunk_index,
                .publication_sequence = prior.publication_sequence,
                .output_bytes = prior.output_bytes,
                .source_bank_epoch = active.receipt.bank_epoch,
                .source_receipt_slot_index = @intCast(active.receipt.slot_index),
                .source_receipt_generation = active.receipt.generation,
                .source_owner_key = active.receipt.owner_key,
                .restore_owner_key = try derivedKey(
                    plan.restore_owner_key_base,
                    index,
                ),
                .restore_tree_key = try derivedKey(
                    plan.restore_tree_key_base,
                    index,
                ),
                .restore_authority_key = try derivedKey(
                    plan.restore_authority_key_base,
                    index,
                ),
                .tenant_key = plan.tenant_key,
                .scope_key = try derivedKey(
                    restored_scope_key_base,
                    index,
                ),
                .allocation_key = try derivedKey(
                    restored_allocation_key_base,
                    index,
                ),
                .binding_key = try derivedKey(
                    restored_binding_key_base,
                    index,
                ),
                .publication_next_sequence = active.publication_next_sequence,
                .parent_claim = active.receipt.claim,
                .output_claim = prior.output_claim,
                .output_sha256 = prior.output_sha256,
                .chunk_receipt_sha256 = prior.chunk_receipt_sha256,
                .lease_receipt_sha256 = [_]u8{0} ** 32,
            };
            entry.lease_receipt_sha256 =
                restoredOwnershipReceiptRootV1(
                    self.checkpoint.checkpoint_sha256,
                    prior,
                    entry,
                );
            checkpoint.entries[index] = entry;
        }

        const local_index: usize = 0;
        const global_index =
            self.checkpoint.retained_output_count;
        const execution =
            try self.stream.executionReceipt(local_index);
        const chunk =
            try self.stream.chunkReceipt(local_index);
        const output = retained_outputs[global_index];
        const output_bytes = std.math.cast(
            u64,
            output.len,
        ) orelse return Error.ArithmeticOverflow;
        const publication_next_sequence = std.math.add(
            u64,
            execution.resource_sequence,
            1,
        ) catch return Error.ArithmeticOverflow;
        var execution_wire: [lease.receipt_bytes]u8 =
            undefined;
        _ = lease.encodeLeaseExecutionReceiptV1(
            execution,
            &execution_wire,
        ) catch return Error.InvalidCheckpoint;
        if (execution.kind != kind or
            chunk.kind != kind or
            execution.request_epoch !=
                self.checkpoint.request_epoch or
            chunk.request_epoch !=
                self.checkpoint.request_epoch or
            chunk.stream_key != self.checkpoint.stream_key or
            chunk.stream_chunk_index != global_index or
            chunk.publication_sequence !=
                execution.media_sequence or
            execution.tree.parent.bank_epoch !=
                self.checkpoint.restore_bank_epoch or
            execution.tree.parent.owner_key !=
                self.checkpoint.next_owner_key_base or
            output_bytes != execution.output_bytes or
            !std.mem.eql(
                u8,
                &sha256(output),
                &execution.output_sha256,
            ) or
            !std.mem.eql(
                u8,
                &chunk.output_sha256,
                &execution.output_sha256,
            ) or
            !std.mem.eql(
                u8,
                &chunk.lease_receipt_sha256,
                &execution.receipt_sha256,
            ) or
            !std.mem.eql(
                u8,
                &chunk.previous_chunk_sha256,
                &self.checkpoint.last_chunk_sha256,
            ))
            return Error.InvalidCheckpoint;
        checkpoint.entries[global_index] = .{
            .chunk_index = chunk.stream_chunk_index,
            .publication_sequence = chunk.publication_sequence,
            .output_bytes = output_bytes,
            .source_bank_epoch = execution.tree.parent.bank_epoch,
            .source_receipt_slot_index = @intCast(
                execution.tree.parent.slot_index,
            ),
            .source_receipt_generation = execution.tree.parent.generation,
            .source_owner_key = execution.tree.parent.owner_key,
            .restore_owner_key = try derivedKey(
                plan.restore_owner_key_base,
                global_index,
            ),
            .restore_tree_key = try derivedKey(
                plan.restore_tree_key_base,
                global_index,
            ),
            .restore_authority_key = try derivedKey(
                plan.restore_authority_key_base,
                global_index,
            ),
            .tenant_key = plan.tenant_key,
            .scope_key = try derivedKey(
                restored_scope_key_base,
                global_index,
            ),
            .allocation_key = try derivedKey(
                restored_allocation_key_base,
                global_index,
            ),
            .binding_key = try derivedKey(
                restored_binding_key_base,
                global_index,
            ),
            .publication_next_sequence = publication_next_sequence,
            .parent_claim = execution.tree.parent.claim,
            .output_claim = .{
                .output_journal_bytes = output_bytes,
            },
            .output_sha256 = execution.output_sha256,
            .chunk_receipt_sha256 = chunk.receipt_sha256,
            .lease_receipt_sha256 = execution.receipt_sha256,
        };
        checkpoint.retained_manifest_sha256 =
            retainedManifestRootV1(
                checkpoint.entries[0..retained_count],
            );
        checkpoint.checkpoint_sha256 =
            checkpointRootV1(checkpoint);
        try validateCheckpointV1(checkpoint);
        try validateRestoredSuccessorCheckpointV1(
            self.checkpoint,
            checkpoint,
        );
        return checkpoint;
    }

    pub fn abortPreparedV1(
        self: *ResumeSession,
    ) Error!void {
        if (self.phase != .prepared)
            return Error.InvalidState;
        try self.cleanupPreparedV1();
        self.phase = .closed;
    }

    pub fn closeAndRelease(
        self: *ResumeSession,
    ) Error!void {
        if (self.phase == .poisoned)
            return Error.ResumePoisoned;
        if (self.phase != .active)
            return Error.InvalidState;
        self.stream.closeAndRelease() catch {
            self.phase = .poisoned;
            return Error.ResumePoisoned;
        };
        while (self.active_count != 0) {
            const index = self.active_count - 1;
            self.releaseActiveOutputV1(index) catch {
                self.phase = .poisoned;
                return Error.ResumePoisoned;
            };
            self.active_count -= 1;
        }
        self.phase = .closed;
    }

    fn prepareOutputV1(
        self: *ResumeSession,
        entry: CheckpointEntryV1,
        index: usize,
    ) Error!PreparedOutputV1 {
        const session_id = @intFromPtr(
            &self.prepared[index],
        );
        var reservation: resource_bank.Reservation = undefined;
        var receipt: resource_bank.Receipt = undefined;
        var tree: resource_bank.LeaseTreeV1 = undefined;
        var scope: resource_bank.LeaseNodeV1 = undefined;
        var stage: enum {
            none,
            reserved,
            committed,
            tree_open,
            session_bound,
        } = .none;
        errdefer switch (stage) {
            .none => {},
            .reserved => self.bank.cancel(reservation) catch {
                self.phase = .poisoned;
            },
            .committed => self.bank.release(receipt) catch {
                self.phase = .poisoned;
            },
            .tree_open => {
                self.bank.closeLeaseTree(tree) catch {
                    self.phase = .poisoned;
                };
                self.bank.release(receipt) catch {
                    self.phase = .poisoned;
                };
            },
            .session_bound => {
                self.bank.closePublicationSession(
                    receipt,
                    self.checkpoint.request_epoch,
                    session_id,
                    entry.publication_next_sequence,
                ) catch {
                    self.phase = .poisoned;
                };
                self.bank.closeLeaseTree(tree) catch {
                    self.phase = .poisoned;
                };
                self.bank.release(receipt) catch {
                    self.phase = .poisoned;
                };
            },
        };

        reservation = try self.bank.reserve(
            entry.restore_owner_key,
            entry.parent_claim,
        );
        stage = .reserved;
        receipt = try self.bank.commit(reservation);
        stage = .committed;
        tree = try self.bank.openLeaseTree(
            receipt,
            entry.restore_tree_key,
            entry.restore_authority_key,
            entry.output_claim,
        );
        stage = .tree_open;
        const opened = try self.bank.openLeaseScope(
            tree,
            entry.scope_key,
            entry.tenant_key,
            entry.output_claim,
        );
        tree = opened.tree;
        scope = opened.scope;
        try self.bank
            .bindRestoredPublicationSessionWithLeaseTree(
            tree,
            entry.source_bank_epoch,
            self.checkpoint.request_epoch,
            session_id,
            entry.publication_next_sequence,
        );
        stage = .session_bound;
        var allocation: [1]resource_bank.LeaseNodeV1 =
            undefined;
        const specs = [_]resource_bank.LeaseAllocationSpecV1{
            .{
                .scope = scope,
                .node_key = entry.allocation_key,
                .binding_key = entry.binding_key,
                .claim = entry.output_claim,
            },
        };
        const prepared = try self.bank
            .reserveAllocationsForSession(
            tree,
            self.checkpoint.request_epoch,
            session_id,
            entry.publication_next_sequence,
            &specs,
            &allocation,
        );
        return .{
            .receipt = receipt,
            .tree = prepared.tree,
            .batch = prepared.batch,
            .scope = scope,
            .allocation = allocation[0],
            .session_id = session_id,
            .entry_index = index,
        };
    }

    fn cleanupPreparedV1(
        self: *ResumeSession,
    ) Error!void {
        while (self.prepared_count != 0) {
            const index = self.prepared_count - 1;
            const prepared = self.prepared[index];
            const entry =
                self.checkpoint.entries[prepared.entry_index];
            const tree = try self.bank
                .abortAllocationsAfterFree(prepared.batch);
            try self.bank.closePublicationSession(
                prepared.receipt,
                self.checkpoint.request_epoch,
                prepared.session_id,
                entry.publication_next_sequence,
            );
            try self.bank.closeLeaseTree(tree);
            try self.bank.release(prepared.receipt);
            self.prepared_count -= 1;
        }
    }

    fn releaseActiveOutputV1(
        self: *ResumeSession,
        index: usize,
    ) Error!void {
        var output = &self.active_outputs[index];
        if (!output.active) return Error.InvalidState;
        const retiring = try self.bank
            .beginRetireSubtreeForSession(
            output.tree,
            output.scope,
            self.checkpoint.request_epoch,
            output.session_id,
            output.publication_next_sequence,
        );
        const authorized = try self.bank.authorizeFree(
            retiring.ticket,
        );
        const empty_tree = try self.bank
            .commitFreeAfterAllocatorFree(
            authorized.permit,
        );
        try self.bank.closePublicationSession(
            output.receipt,
            self.checkpoint.request_epoch,
            output.session_id,
            output.publication_next_sequence,
        );
        try self.bank.closeLeaseTree(empty_tree);
        try self.bank.release(output.receipt);
        output.active = false;
    }
};

fn stateFromCheckpointV1(
    checkpoint: CheckpointV1,
) media.PublicationStateV1 {
    return .{
        .request_epoch = checkpoint.request_epoch,
        .next_sequence = checkpoint.next_sequence,
        .visible_chunks = checkpoint.visible_chunks,
        .visible_units = checkpoint.visible_units,
        .timeline_base = checkpoint.timeline_base,
        .media_object_sha256 = checkpoint.media_object_sha256,
        .timeline_sha256 = checkpoint.timeline_sha256,
        .previous_commit_sha256 = checkpoint.previous_commit_sha256,
    };
}

fn validateCheckpointV1(
    checkpoint: CheckpointV1,
) Error!void {
    const count = checkpoint.retained_output_count;
    if (checkpoint.request_epoch == 0 or
        checkpoint.checkpoint_generation == 0 or
        checkpoint.stream_key == 0 or
        checkpoint.committed_chunks == 0 or
        checkpoint.committed_chunks != count or
        checkpoint.chunk_limit == 0 or
        checkpoint.chunk_limit >
            maximum_retained_outputs or
        checkpoint.committed_chunks >=
            checkpoint.chunk_limit or
        checkpoint.next_sequence == 0 or
        checkpoint.visible_chunks !=
            checkpoint.committed_chunks or
        checkpoint.visible_units == 0 or
        checkpoint.timeline_base.numerator == 0 or
        checkpoint.timeline_base.denominator == 0 or
        count == 0 or count > maximum_retained_outputs or
        checkpoint.restore_bank_epoch == 0 or
        checkpoint.next_owner_key_base == 0 or
        checkpoint.next_tree_key_base == 0 or
        checkpoint.next_authority_key_base == 0 or
        checkpoint.tenant_key == 0 or
        isZero(checkpoint.media_object_sha256) or
        isZero(checkpoint.timeline_sha256) or
        isZero(checkpoint.previous_commit_sha256) or
        isZero(checkpoint.last_chunk_sha256) or
        isZero(checkpoint.challenge_sha256) or
        isZero(checkpoint.retained_manifest_sha256) or
        isZero(checkpoint.checkpoint_sha256) or
        (checkpoint.checkpoint_generation == 1 and
            !isZero(
                checkpoint.previous_checkpoint_sha256,
            )) or
        (checkpoint.checkpoint_generation != 1 and
            isZero(
                checkpoint.previous_checkpoint_sha256,
            )))
        return Error.InvalidCheckpoint;

    var previous_publication_sequence: u64 = 0;
    var source_bank_epoch: u64 = 0;
    for (
        checkpoint.entries[0..count],
        0..,
    ) |entry, index| {
        const expected_publication_sequence =
            if (index == 0)
                entry.publication_sequence
            else
                std.math.add(
                    u64,
                    previous_publication_sequence,
                    1,
                ) catch return Error.InvalidCheckpoint;
        if (entry.chunk_index != index or
            entry.publication_sequence == 0 or
            entry.publication_sequence !=
                expected_publication_sequence or
            entry.output_bytes == 0 or
            entry.source_bank_epoch == 0 or
            entry.source_bank_epoch ==
                checkpoint.restore_bank_epoch or
            entry.source_receipt_generation == 0 or
            entry.source_owner_key == 0 or
            entry.restore_owner_key == 0 or
            entry.restore_tree_key == 0 or
            entry.restore_authority_key == 0 or
            entry.tenant_key != checkpoint.tenant_key or
            entry.scope_key == 0 or
            entry.allocation_key == 0 or
            entry.binding_key == 0 or
            entry.publication_next_sequence == 0 or
            entry.parent_claim.isZero() or
            !std.meta.eql(
                entry.output_claim,
                resource_bank.Claim{
                    .output_journal_bytes = entry.output_bytes,
                },
            ) or
            isZero(entry.output_sha256) or
            isZero(entry.chunk_receipt_sha256) or
            isZero(entry.lease_receipt_sha256))
            return Error.InvalidCheckpoint;
        if (index == 0) {
            source_bank_epoch = entry.source_bank_epoch;
        } else if (entry.source_bank_epoch !=
            source_bank_epoch)
        {
            return Error.InvalidCheckpoint;
        }
        for (
            checkpoint.entries[0..index],
        ) |prior| {
            if ((entry.source_receipt_slot_index ==
                prior.source_receipt_slot_index and
                entry.source_receipt_generation ==
                    prior.source_receipt_generation) or
                entry.restore_owner_key ==
                    prior.restore_owner_key or
                entry.restore_tree_key ==
                    prior.restore_tree_key or
                entry.restore_authority_key ==
                    prior.restore_authority_key or
                entry.scope_key == prior.scope_key or
                entry.allocation_key ==
                    prior.allocation_key or
                entry.binding_key == prior.binding_key)
                return Error.InvalidCheckpoint;
        }
        previous_publication_sequence =
            entry.publication_sequence;
    }
    for (
        checkpoint.entries[count..],
    ) |entry| {
        if (!std.meta.eql(entry, CheckpointEntryV1{}))
            return Error.InvalidCheckpoint;
    }
    const final_entry = checkpoint.entries[count - 1];
    const remaining_chunks: u64 =
        checkpoint.chunk_limit -
        checkpoint.committed_chunks;
    const final_local_index = remaining_chunks - 1;
    _ = std.math.add(
        u64,
        checkpoint.next_owner_key_base,
        final_local_index,
    ) catch return Error.InvalidCheckpoint;
    _ = std.math.add(
        u64,
        checkpoint.next_tree_key_base,
        final_local_index,
    ) catch return Error.InvalidCheckpoint;
    _ = std.math.add(
        u64,
        checkpoint.next_authority_key_base,
        final_local_index,
    ) catch return Error.InvalidCheckpoint;
    const expected_next_sequence = std.math.add(
        u64,
        final_entry.publication_sequence,
        1,
    ) catch return Error.InvalidCheckpoint;
    if (expected_next_sequence != checkpoint.next_sequence or
        !std.mem.eql(
            u8,
            &final_entry.chunk_receipt_sha256,
            &checkpoint.last_chunk_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.retained_manifest_sha256,
            &retainedManifestRootV1(
                checkpoint.entries[0..count],
            ),
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.checkpoint_sha256,
            &checkpointRootV1(checkpoint),
        ))
        return Error.InvalidCheckpoint;
}

fn writeCheckpointBodyV1(
    checkpoint: CheckpointV1,
    output: []u8,
) void {
    std.debug.assert(output.len == checkpoint_body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &checkpoint_magic);
    writeU64(output, 8, checkpoint_abi);
    writeU64(output, 16, checkpoint_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(checkpoint.kind));
    writeU64(output, 40, checkpoint.request_epoch);
    writeU64(output, 48, checkpoint.checkpoint_generation);
    writeU64(output, 56, checkpoint.stream_key);
    writeU64(output, 64, checkpoint.committed_chunks);
    writeU64(output, 72, checkpoint.chunk_limit);
    writeU64(output, 80, checkpoint.next_sequence);
    writeU64(output, 88, checkpoint.visible_chunks);
    writeU64(output, 96, checkpoint.visible_units);
    writeU64(output, 104, checkpoint.timeline_base.numerator);
    writeU64(output, 112, checkpoint.timeline_base.denominator);
    writeU64(output, 120, checkpoint.retained_output_count);
    writeU64(output, 128, checkpoint.restore_bank_epoch);
    writeU64(output, 136, checkpoint.next_owner_key_base);
    writeU64(output, 144, checkpoint.next_tree_key_base);
    writeU64(
        output,
        152,
        checkpoint.next_authority_key_base,
    );
    writeU64(output, 160, checkpoint.tenant_key);
    const roots = [_]Digest{
        checkpoint.media_object_sha256,
        checkpoint.timeline_sha256,
        checkpoint.previous_commit_sha256,
        checkpoint.last_chunk_sha256,
        checkpoint.challenge_sha256,
        checkpoint.retained_manifest_sha256,
        checkpoint.previous_checkpoint_sha256,
    };
    for (roots, 0..) |root, index|
        @memcpy(
            output[digest_offset + index * 32 .. digest_offset + (index + 1) * 32],
            &root,
        );
    for (checkpoint.entries, 0..) |entry, index| {
        const start = entry_offset +
            index * checkpoint_entry_bytes;
        writeEntryV1(
            entry,
            output[start .. start + checkpoint_entry_bytes],
        );
    }
}

fn writeEntryV1(
    entry: CheckpointEntryV1,
    output: []u8,
) void {
    std.debug.assert(output.len == checkpoint_entry_bytes);
    @memset(output, 0);
    const values = [_]u64{
        entry.chunk_index,
        entry.publication_sequence,
        entry.output_bytes,
        entry.source_bank_epoch,
        entry.source_receipt_slot_index,
        entry.source_receipt_generation,
        entry.source_owner_key,
        entry.restore_owner_key,
        entry.restore_tree_key,
        entry.restore_authority_key,
        entry.tenant_key,
        entry.scope_key,
        entry.allocation_key,
        entry.binding_key,
        entry.publication_next_sequence,
    };
    for (values, 0..) |value, index|
        writeU64(output, index * 8, value);
    writeClaim(output, 128, entry.parent_claim);
    writeClaim(output, 208, entry.output_claim);
    @memcpy(output[288..320], &entry.output_sha256);
    @memcpy(
        output[320..352],
        &entry.chunk_receipt_sha256,
    );
    @memcpy(
        output[352..384],
        &entry.lease_receipt_sha256,
    );
}

fn decodeEntryV1(
    encoded: []const u8,
) Error!CheckpointEntryV1 {
    if (encoded.len != checkpoint_entry_bytes or
        !std.mem.allEqual(u8, encoded[120..128], 0))
        return Error.InvalidCheckpoint;
    return .{
        .chunk_index = readU64(encoded, 0),
        .publication_sequence = readU64(encoded, 8),
        .output_bytes = readU64(encoded, 16),
        .source_bank_epoch = readU64(encoded, 24),
        .source_receipt_slot_index = readU64(encoded, 32),
        .source_receipt_generation = readU64(encoded, 40),
        .source_owner_key = readU64(encoded, 48),
        .restore_owner_key = readU64(encoded, 56),
        .restore_tree_key = readU64(encoded, 64),
        .restore_authority_key = readU64(encoded, 72),
        .tenant_key = readU64(encoded, 80),
        .scope_key = readU64(encoded, 88),
        .allocation_key = readU64(encoded, 96),
        .binding_key = readU64(encoded, 104),
        .publication_next_sequence = readU64(encoded, 112),
        .parent_claim = readClaim(encoded, 128),
        .output_claim = readClaim(encoded, 208),
        .output_sha256 = encoded[288..320].*,
        .chunk_receipt_sha256 = encoded[320..352].*,
        .lease_receipt_sha256 = encoded[352..384].*,
    };
}

fn writeClaim(
    output: []u8,
    offset: usize,
    claim: resource_bank.Claim,
) void {
    inline for (
        std.meta.fields(resource_bank.Claim),
        0..,
    ) |field, index|
        writeU64(
            output,
            offset + index * 8,
            @field(claim, field.name),
        );
}

fn readClaim(
    input: []const u8,
    offset: usize,
) resource_bank.Claim {
    var claim: resource_bank.Claim = .{};
    inline for (
        std.meta.fields(resource_bank.Claim),
        0..,
    ) |field, index|
        @field(claim, field.name) =
            readU64(input, offset + index * 8);
    return claim;
}

fn derivedKey(base: u64, index: usize) Error!u64 {
    const value = std.math.add(
        u64,
        base,
        @intCast(index),
    ) catch return Error.ArithmeticOverflow;
    if (value == 0) return Error.InvalidCheckpoint;
    return value;
}

fn sha256(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        bytes,
        &digest,
        .{},
    );
    return digest;
}

fn writeU64(
    output: []u8,
    offset: usize,
    value: anytype,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &bytes,
        @intCast(value),
        .little,
    );
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

test "restored ownership receipt matches the independent golden" {
    const claim: resource_bank.Claim = .{
        .output_journal_bytes = 17,
    };
    const prior: CheckpointEntryV1 = .{
        .chunk_index = 0,
        .publication_sequence = 7,
        .output_bytes = 17,
        .source_bank_epoch = 11,
        .source_receipt_slot_index = 2,
        .source_receipt_generation = 3,
        .source_owner_key = 13,
        .restore_owner_key = 14,
        .restore_tree_key = 15,
        .restore_authority_key = 16,
        .tenant_key = 17,
        .scope_key = 18,
        .allocation_key = 19,
        .binding_key = 20,
        .publication_next_sequence = 8,
        .parent_claim = claim,
        .output_claim = claim,
        .output_sha256 = [_]u8{0x22} ** 32,
        .chunk_receipt_sha256 = [_]u8{0x33} ** 32,
        .lease_receipt_sha256 = [_]u8{0x11} ** 32,
    };
    var successor = prior;
    successor.source_bank_epoch = 21;
    successor.source_receipt_slot_index = 4;
    successor.source_receipt_generation = 5;
    successor.source_owner_key = 23;
    successor.publication_next_sequence = 9;
    successor.output_sha256 = [_]u8{0x44} ** 32;
    successor.chunk_receipt_sha256 = [_]u8{0x55} ** 32;
    successor.lease_receipt_sha256 = [_]u8{0x66} ** 32;
    var expected: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "3bf4bd7b8efd19644f86a59476c37580" ++
            "cc12887be45a29810e29b8a53444b38a",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &restoredOwnershipReceiptRootV1(
            [_]u8{0xaa} ** 32,
            prior,
            successor,
        ),
    );
}

test "checkpoint releases source reacquires output and resumes every media kind" {
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
        var source_slots = [_]resource_bank.Slot{.{}};
        var source_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
        var source_nodes =
            [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
        const source_bank_epoch: u64 = 6100 + case_index;
        var source_bank =
            try resource_bank.Bank.initWithLeaseTreeStorage(
                &source_slots,
                &source_roots,
                &source_nodes,
                .{},
                source_bank_epoch,
            );
        const request_epoch: u64 = 6200 + case_index;
        var source_state =
            try media.initializePublicationStateV1(
                request_epoch,
                1,
                context.timeline_base,
                context.fixture.media_object_sha256,
                [_]u8{@intCast(0xa0 + case_index)} ** 32,
            );
        var source_stream: stream_runtime.StreamSession = .{};
        try source_stream.init(
            &source_bank,
            &source_state,
            6300 + case_index,
            6310 + case_index * 10,
            6320 + case_index * 10,
            6330 + case_index * 10,
            6340 + case_index,
            request_epoch,
            3,
        );

        var plan_storage: [transform.transform_plan_bytes]u8 =
            undefined;
        var decoded: [fixture_api.maximum_payload_bytes]u8 =
            undefined;
        var outputs: [2][fixture_api.maximum_payload_bytes]u8 =
            undefined;
        var mappings: [4]transform.TransformMappingV1 =
            undefined;
        var scratch: [1]u8 = undefined;
        const first_plan = try makeChunkPlan(
            context,
            case_index,
            0,
        );
        const first_encoded =
            try transform.encodeTransformPlanV1(
                first_plan,
                &plan_storage,
            );
        var first = try source_stream.prepareChunk(
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
        const first_committed = try first.commit();
        const first_output = outputs[0][0..@intCast(first_plan.output_bytes)];
        const retained = [_][]const u8{first_output};
        const restore_bank_epoch: u64 =
            6400 + case_index;
        const checkpoint = try makeCheckpointV1(
            &source_stream,
            first_committed.execution.kind,
            .{
                .checkpoint_generation = 1,
                .chunk_limit = 3,
                .restore_bank_epoch = restore_bank_epoch,
                .restore_owner_key_base = 6410 + case_index * 10,
                .restore_tree_key_base = 6420 + case_index * 10,
                .restore_authority_key_base = 6430 + case_index * 10,
                .next_owner_key_base = 6440 + case_index * 10,
                .next_tree_key_base = 6450 + case_index * 10,
                .next_authority_key_base = 6460 + case_index * 10,
                .tenant_key = 6470 + case_index,
                .challenge_sha256 = [_]u8{@intCast(0xc0 + case_index)} ** 32,
            },
            &retained,
        );
        if (case_index == 0) {
            var expected_checkpoint_root: Digest =
                undefined;
            _ = try std.fmt.hexToBytes(
                &expected_checkpoint_root,
                "68931cd23e921fd810ddd78b6fcdfee5" ++
                    "c4a06cc030e8ff67752ef18c9a54fa6a",
            );
            try std.testing.expectEqualSlices(
                u8,
                &expected_checkpoint_root,
                &checkpoint.checkpoint_sha256,
            );
        }
        var checkpoint_storage: [checkpoint_bytes]u8 =
            undefined;
        const encoded_checkpoint =
            try encodeCheckpointV1(
                checkpoint,
                &checkpoint_storage,
            );
        try std.testing.expect(std.meta.eql(
            checkpoint,
            try decodeCheckpointV1(encoded_checkpoint),
        ));
        const retained_source_used =
            (try source_bank.snapshot()).used;
        try source_stream.closeAndRelease();
        try std.testing.expect(
            (try source_bank.snapshot()).used.isZero(),
        );

        var target_slots = [_]resource_bank.Slot{.{}} ** 2;
        var target_roots =
            [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
        var target_nodes =
            [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
        var target_bank =
            try resource_bank.Bank.initWithLeaseTreeStorage(
                &target_slots,
                &target_roots,
                &target_nodes,
                .{},
                restore_bank_epoch,
            );
        var target_state: media.PublicationStateV1 =
            undefined;
        var resumed: ResumeSession = .{};
        try resumed.prepareV1(
            &target_bank,
            &target_state,
            encoded_checkpoint,
            checkpoint.checkpoint_sha256,
        );
        const reserved = try target_bank.snapshotV3();
        try std.testing.expectEqual(
            @as(usize, 1),
            reserved.reserved_unmaterialized_allocations,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            reserved.live_allocations,
        );
        try std.testing.expect(std.meta.eql(
            retained_source_used,
            reserved.used,
        ));
        try resumed.commitMaterializedV1(&retained);
        try std.testing.expectEqual(
            @as(usize, 1),
            (try target_bank.snapshotV3())
                .live_allocations,
        );
        try std.testing.expectError(
            resource_bank.Error.StaleReservation,
            target_bank.release(
                first_committed.execution.tree.parent,
            ),
        );

        const second_plan = try makeChunkPlan(
            context,
            case_index,
            1,
        );
        const second_encoded =
            try transform.encodeTransformPlanV1(
                second_plan,
                &plan_storage,
            );
        const state_before = target_state;
        var second = try resumed.stream.prepareChunk(
            target_state.visible_units,
            target_state.visible_units +
                second_plan.logical_units,
            context.encoded_fixture,
            context.encoded_decode_plan,
            second_encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        );
        const second_committed = try second.commit();
        try std.testing.expectEqual(
            @as(u64, 1),
            second_committed.stream.stream_chunk_index,
        );
        try std.testing.expectEqualSlices(
            u8,
            &checkpoint.last_chunk_sha256,
            &second_committed.stream
                .previous_chunk_sha256,
        );
        try stream_runtime.verifyChunkReceiptV1(
            state_before,
            checkpoint.stream_key,
            1,
            checkpoint.last_chunk_sha256,
            second_committed.execution,
            second_committed.stream,
        );
        try std.testing.expectEqual(
            @as(u64, 2),
            target_state.visible_chunks,
        );
        const second_output =
            outputs[1][0..@intCast(second_plan.output_bytes)];
        const successor_retained = [_][]const u8{
            first_output,
            second_output,
        };
        const successor = try resumed.makeSuccessorCheckpointV1(
            first_committed.execution.kind,
            .{
                .checkpoint_generation = 2,
                .chunk_limit = 3,
                .restore_bank_epoch = 6480 + case_index,
                .restore_owner_key_base = 6490 + case_index * 10,
                .restore_tree_key_base = 6500 + case_index * 10,
                .restore_authority_key_base = 6510 + case_index * 10,
                .next_owner_key_base = 6520 + case_index * 10,
                .next_tree_key_base = 6530 + case_index * 10,
                .next_authority_key_base = 6540 + case_index * 10,
                .tenant_key = checkpoint.tenant_key,
                .challenge_sha256 = checkpoint.challenge_sha256,
                .previous_checkpoint_sha256 = checkpoint.checkpoint_sha256,
            },
            &successor_retained,
        );
        try validateRestoredSuccessorCheckpointV1(
            checkpoint,
            successor,
        );
        try std.testing.expectEqual(
            checkpoint.restore_bank_epoch,
            successor.entries[0].source_bank_epoch,
        );
        try std.testing.expectEqual(
            checkpoint.entries[0].restore_owner_key,
            successor.entries[0].source_owner_key,
        );
        try std.testing.expect(!std.mem.eql(
            u8,
            &checkpoint.entries[0].lease_receipt_sha256,
            &successor.entries[0].lease_receipt_sha256,
        ));

        var stale_authority = successor;
        stale_authority.entries[0].source_bank_epoch =
            source_bank_epoch;
        stale_authority.entries[0].lease_receipt_sha256 =
            restoredOwnershipReceiptRootV1(
                checkpoint.checkpoint_sha256,
                checkpoint.entries[0],
                stale_authority.entries[0],
            );
        stale_authority.retained_manifest_sha256 =
            retainedManifestRootV1(
                stale_authority.entries[0..stale_authority.retained_output_count],
            );
        stale_authority.checkpoint_sha256 =
            checkpointRootV1(stale_authority);
        try std.testing.expectError(
            Error.InvalidCheckpoint,
            validateRestoredSuccessorCheckpointV1(
                checkpoint,
                stale_authority,
            ),
        );
        try resumed.closeAndRelease();
        const final = try target_bank.snapshotV3();
        try std.testing.expect(final.used.isZero());
        try std.testing.expectEqual(
            @as(usize, 0),
            final.live_allocations,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            final.active_lease_trees,
        );
    }
}

test "checkpoint materialization retry and expectation failures are atomic" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    const context = try prepareTestContext(
        0,
        &fixture_storage,
        &decode_plan_storage,
        &decoded_for_plan,
    );
    var source_slots = [_]resource_bank.Slot{.{}};
    var source_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var source_nodes =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
    var source_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &source_slots,
            &source_roots,
            &source_nodes,
            .{},
            6501,
        );
    var state = try media.initializePublicationStateV1(
        6502,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xa1} ** 32,
    );
    var source_stream: stream_runtime.StreamSession = .{};
    try source_stream.init(
        &source_bank,
        &state,
        6503,
        6510,
        6520,
        6530,
        6540,
        6502,
        2,
    );
    var plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    const plan = try makeChunkPlan(context, 0, 0);
    const encoded_plan =
        try transform.encodeTransformPlanV1(
            plan,
            &plan_storage,
        );
    var decoded: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var mappings: [4]transform.TransformMappingV1 =
        undefined;
    var scratch: [1]u8 = undefined;
    var transaction = try source_stream.prepareChunk(
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
    _ = try transaction.commit();
    const exact_output =
        output[0..@intCast(plan.output_bytes)];
    const retained = [_][]const u8{exact_output};
    const checkpoint = try makeCheckpointV1(
        &source_stream,
        .image,
        .{
            .checkpoint_generation = 1,
            .chunk_limit = 2,
            .restore_bank_epoch = 6504,
            .restore_owner_key_base = 6550,
            .restore_tree_key_base = 6560,
            .restore_authority_key_base = 6570,
            .next_owner_key_base = 6580,
            .next_tree_key_base = 6590,
            .next_authority_key_base = 6600,
            .tenant_key = 6610,
            .challenge_sha256 = [_]u8{0xc1} ** 32,
        },
        &retained,
    );
    var encoded_storage: [checkpoint_bytes]u8 = undefined;
    const encoded = try encodeCheckpointV1(
        checkpoint,
        &encoded_storage,
    );
    try source_stream.closeAndRelease();

    var foreign_slots = [_]resource_bank.Slot{.{}};
    var foreign_roots =
        [_]resource_bank.LeaseTreeRootSlot{.{}};
    var foreign_nodes =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 4;
    var foreign_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &foreign_slots,
            &foreign_roots,
            &foreign_nodes,
            .{},
            6505,
        );
    var foreign_state: media.PublicationStateV1 =
        undefined;
    var foreign_resume: ResumeSession = .{};
    try std.testing.expectError(
        Error.TargetNotFresh,
        foreign_resume.prepareV1(
            &foreign_bank,
            &foreign_state,
            encoded,
            checkpoint.checkpoint_sha256,
        ),
    );
    try std.testing.expect(
        (try foreign_bank.snapshot()).used.isZero(),
    );

    var limited_slots = [_]resource_bank.Slot{.{}};
    var limited_roots =
        [_]resource_bank.LeaseTreeRootSlot{.{}};
    var limited_nodes =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 4;
    var limited_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &limited_slots,
            &limited_roots,
            &limited_nodes,
            .{
                .output_journal_bytes = plan.output_bytes - 1,
            },
            6504,
        );
    var limited_state: media.PublicationStateV1 =
        undefined;
    var limited_resume: ResumeSession = .{};
    try std.testing.expectError(
        resource_bank.Error.CapacityExceeded,
        limited_resume.prepareV1(
            &limited_bank,
            &limited_state,
            encoded,
            checkpoint.checkpoint_sha256,
        ),
    );
    const limited_final = try limited_bank.snapshotV3();
    try std.testing.expect(limited_final.used.isZero());
    try std.testing.expectEqual(
        @as(usize, 0),
        limited_final.active_lease_trees,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        limited_final.reserved_unmaterialized_allocations,
    );

    var wrong_slots = [_]resource_bank.Slot{.{}};
    var wrong_roots =
        [_]resource_bank.LeaseTreeRootSlot{.{}};
    var wrong_nodes =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 4;
    var wrong_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &wrong_slots,
            &wrong_roots,
            &wrong_nodes,
            .{},
            6504,
        );
    var wrong_state: media.PublicationStateV1 = undefined;
    var wrong_resume: ResumeSession = .{};
    try std.testing.expectError(
        Error.CheckpointExpectationMismatch,
        wrong_resume.prepareV1(
            &wrong_bank,
            &wrong_state,
            encoded,
            [_]u8{0xee} ** 32,
        ),
    );
    try std.testing.expect(
        (try wrong_bank.snapshot()).used.isZero(),
    );

    var resumed: ResumeSession = .{};
    try resumed.prepareV1(
        &wrong_bank,
        &wrong_state,
        encoded,
        checkpoint.checkpoint_sha256,
    );
    var wrong_output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    @memcpy(
        wrong_output[0..exact_output.len],
        exact_output,
    );
    wrong_output[0] ^= 1;
    const wrong_materialized = [_][]const u8{
        wrong_output[0..exact_output.len],
    };
    try std.testing.expectError(
        Error.InvalidMaterialization,
        resumed.commitMaterializedV1(
            &wrong_materialized,
        ),
    );
    const still_reserved = try wrong_bank.snapshotV3();
    try std.testing.expectEqual(
        @as(usize, 1),
        still_reserved.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        still_reserved.live_allocations,
    );
    try resumed.commitMaterializedV1(&retained);
    try resumed.closeAndRelease();
    try std.testing.expect(
        (try wrong_bank.snapshot()).used.isZero(),
    );
}

test "checkpoint wire rejects every mutation and rehashed contradictions" {
    var checkpoint: CheckpointV1 = .{
        .kind = .image,
        .request_epoch = 7101,
        .checkpoint_generation = 1,
        .stream_key = 7102,
        .committed_chunks = 1,
        .chunk_limit = 2,
        .next_sequence = 2,
        .visible_chunks = 1,
        .visible_units = 1,
        .timeline_base = .{
            .numerator = 1,
            .denominator = 1,
        },
        .retained_output_count = 1,
        .restore_bank_epoch = 7104,
        .next_owner_key_base = 7110,
        .next_tree_key_base = 7120,
        .next_authority_key_base = 7130,
        .tenant_key = 7140,
        .media_object_sha256 = [_]u8{0xa1} ** 32,
        .timeline_sha256 = [_]u8{0xa2} ** 32,
        .previous_commit_sha256 = [_]u8{0xa3} ** 32,
        .last_chunk_sha256 = [_]u8{0xa4} ** 32,
        .challenge_sha256 = [_]u8{0xa5} ** 32,
        .retained_manifest_sha256 = undefined,
        .previous_checkpoint_sha256 = [_]u8{0} ** 32,
        .entries = [_]CheckpointEntryV1{.{}} **
            maximum_retained_outputs,
        .checkpoint_sha256 = undefined,
    };
    checkpoint.entries[0] = .{
        .chunk_index = 0,
        .publication_sequence = 1,
        .output_bytes = 6,
        .source_bank_epoch = 7103,
        .source_receipt_slot_index = 0,
        .source_receipt_generation = 1,
        .source_owner_key = 7201,
        .restore_owner_key = 7202,
        .restore_tree_key = 7203,
        .restore_authority_key = 7204,
        .tenant_key = 7140,
        .scope_key = 7205,
        .allocation_key = 7206,
        .binding_key = 7207,
        .publication_next_sequence = 1,
        .parent_claim = .{
            .capsule_bytes = 928,
            .io_bytes = 12,
            .queue_slots = 1,
        },
        .output_claim = .{
            .output_journal_bytes = 6,
        },
        .output_sha256 = [_]u8{0xb1} ** 32,
        .chunk_receipt_sha256 = [_]u8{0xa4} ** 32,
        .lease_receipt_sha256 = [_]u8{0xb3} ** 32,
    };
    checkpoint.retained_manifest_sha256 =
        retainedManifestRootV1(
            checkpoint.entries[0..1],
        );
    checkpoint.checkpoint_sha256 =
        checkpointRootV1(checkpoint);
    var storage: [checkpoint_bytes]u8 = undefined;
    const encoded = try encodeCheckpointV1(
        checkpoint,
        &storage,
    );
    var corrupted: [checkpoint_bytes]u8 = undefined;
    for (0..checkpoint_bytes) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodeCheckpointV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }

    @memcpy(&corrupted, encoded);
    writeU64(&corrupted, 128, 7103);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checkpoint_domain);
    hash.update(corrupted[0..checkpoint_body_bytes]);
    var forged_root: Digest = undefined;
    hash.final(&forged_root);
    @memcpy(
        corrupted[checkpoint_body_bytes..],
        &forged_root,
    );
    try std.testing.expectError(
        Error.InvalidCheckpoint,
        decodeCheckpointV1(&corrupted),
    );
}
