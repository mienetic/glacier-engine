//! Descriptor-relative durable payload snapshot promotion.
//!
//! A stable lock inode serializes access while canonical payload snapshots are
//! replaced copy-on-write. The exact reclaim plan is written and synchronized
//! before a candidate can replace the active snapshot. Process death can leave
//! an old active snapshot, a complete candidate, or the promoted new snapshot;
//! recovery accepts only those plan-bound states.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");
const bundle = @import("continuation_bundle.zig");
const object_store = @import("continuation_object_store.zig");
const payload_store = @import("continuation_object_payload_store.zig");
const sweep = @import("continuation_object_sweep.zig");
const sweep_record = @import("continuation_object_sweep_record.zig");
const sweep_file = @import("continuation_object_sweep_file.zig");

pub const Digest = payload_store.Digest;
pub const reclaim_record_bytes: usize = 968;
pub const reclaim_record_magic = [8]u8{
    'G', 'L', 'P', 'R', 'E', 'C', '1', 0,
};
pub const reclaim_record_schema: u64 = 1;
pub const lock_name = ".glacier-payload-lock-v1";
pub const active_name = ".glacier-payload-active-v1";

const reclaim_record_domain =
    "glacier-continuation-object-payload-reclaim-record-v1\x00";
const max_generated_name_bytes: usize = 96;
const targets_offset: usize = 264;
const targets_bytes: usize =
    object_store.default_capacity * @sizeOf(bundle.BlobRefV1);
const challenge_offset: usize = targets_offset + targets_bytes;
const record_root_offset: usize = challenge_offset + 32;

pub const Error = payload_store.Error || sweep_file.Error || error{
    ActiveSnapshotMismatch,
    CandidateMismatch,
    InvalidReclaimRecord,
    InvalidState,
    PublishedPlanMismatch,
    ReclaimBindingMismatch,
};

pub const IoPhaseV1 = enum(u8) {
    plan_write,
    plan_sync,
    plan_directory_sync,
    candidate_write,
    candidate_sync,
    promote_rename,
    directory_sync,
};

pub const ObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        phase: IoPhaseV1,
    ) sweep_file.Error!void,

    fn after(self: ObserverV1, phase: IoPhaseV1) sweep_file.Error!void {
        try self.after_phase_fn(self.context, phase);
    }
};

pub const RecordMetadataV1 = struct {
    storage_epoch: u64,
    challenge_sha256: Digest,
};

pub const PreparedReclaimRecordV1 = struct {
    bytes: [reclaim_record_bytes]u8,
    record_sha256: Digest,
};

pub const DecodedReclaimRecordV1 = struct {
    storage_epoch: u64,
    tenant_scope_sha256: Digest,
    sweep_record_sha256: Digest,
    targets_sha256: Digest,
    before_snapshot_sha256: Digest,
    after_snapshot_sha256: Digest,
    preview_sha256: Digest,
    before_encoded_bytes: u64,
    after_encoded_bytes: u64,
    freed_entries: u64,
    freed_payload_bytes: u64,
    targets: [object_store.default_capacity]bundle.BlobRefV1,
    target_count: usize,
    challenge_sha256: Digest,
    record_sha256: Digest,
};

pub const PreparedReclaimV1 = struct {
    preview: payload_store.ReclaimPreviewV1,
    record: PreparedReclaimRecordV1,
    candidate_bytes: usize,
};

pub const ApplyDispositionV1 = enum(u8) {
    applied,
    already_applied,
};

pub const ApplyReceiptV1 = struct {
    disposition: ApplyDispositionV1,
    active_snapshot: payload_store.SnapshotV1,
    reclaim_record_sha256: Digest,
};

pub const LeaseStateV1 = enum(u8) {
    ready,
    poisoned,
    closed,
};

pub const LeaseV1 = struct {
    directory: std.fs.Dir,
    lock: sweep_file.FileLeaseV1,
    storage_epoch: u64,
    tenant_scope_sha256: Digest,
    active_storage: []u8,
    active_bytes: usize,
    max_bytes: usize,
    active_snapshot: payload_store.SnapshotV1,
    state: LeaseStateV1 = .ready,

    pub fn create(
        directory: std.fs.Dir,
        storage_epoch: u64,
        tenant_scope_sha256: Digest,
        initial_snapshot: []const u8,
        max_bytes: usize,
        lock_storage: []u8,
        active_storage: []u8,
    ) !LeaseV1 {
        if (initial_snapshot.len > max_bytes or
            active_storage.len < max_bytes)
            return Error.BufferTooSmall;
        var views: [payload_store.default_capacity]payload_store.EntryViewV1 =
            undefined;
        const snapshot = try payload_store.decodeSnapshotV1(
            initial_snapshot,
            tenant_scope_sha256,
            &views,
        );
        var lock = try sweep_file.FileLeaseV1.create(
            directory,
            lock_name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = sweep_record.encoded_bytes,
            },
            lock_storage,
        );
        errdefer lock.close();
        const active = try openSafeFile(directory, active_name, .create);
        errdefer active.close();
        try writeInitialFile(
            active,
            directory,
            active_name,
            initial_snapshot,
        );
        active.close();
        std.mem.copyForwards(
            u8,
            active_storage[0..initial_snapshot.len],
            initial_snapshot,
        );
        return .{
            .directory = directory,
            .lock = lock,
            .storage_epoch = storage_epoch,
            .tenant_scope_sha256 = tenant_scope_sha256,
            .active_storage = active_storage,
            .active_bytes = initial_snapshot.len,
            .max_bytes = max_bytes,
            .active_snapshot = snapshot,
        };
    }

    pub fn open(
        directory: std.fs.Dir,
        storage_epoch: u64,
        tenant_scope_sha256: Digest,
        max_bytes: usize,
        lock_storage: []u8,
        active_storage: []u8,
    ) !LeaseV1 {
        if (active_storage.len < max_bytes) return Error.BufferTooSmall;
        var lock = try sweep_file.FileLeaseV1.open(
            directory,
            lock_name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = sweep_record.encoded_bytes,
            },
            lock_storage,
        );
        errdefer lock.close();
        const loaded = try readSnapshotFile(
            directory,
            active_name,
            tenant_scope_sha256,
            active_storage,
            max_bytes,
        );
        return .{
            .directory = directory,
            .lock = lock,
            .storage_epoch = storage_epoch,
            .tenant_scope_sha256 = tenant_scope_sha256,
            .active_storage = active_storage,
            .active_bytes = loaded.bytes,
            .max_bytes = max_bytes,
            .active_snapshot = loaded.snapshot,
        };
    }

    pub fn stream(self: *const LeaseV1) []const u8 {
        return self.active_storage[0..self.active_bytes];
    }

    pub fn close(self: *LeaseV1) void {
        if (self.state == .closed) return;
        self.state = .closed;
        self.lock.close();
    }

    fn refresh(self: *LeaseV1) Error!void {
        const loaded = readSnapshotFile(
            self.directory,
            active_name,
            self.tenant_scope_sha256,
            self.active_storage,
            self.max_bytes,
        ) catch return Error.StorageIo;
        self.active_bytes = loaded.bytes;
        self.active_snapshot = loaded.snapshot;
    }
};

const LoadedSnapshotV1 = struct {
    bytes: usize,
    snapshot: payload_store.SnapshotV1,
};

const OpenKind = enum {
    create,
    existing,
};

const FileViewV1 = struct {
    device: u64,
    inode: u64,
    size: usize,
};

/// Binds an exact payload successor to a fully published sweep record.
pub fn prepareFromPublishedSweepV1(
    active: []const u8,
    tenant_scope_sha256: Digest,
    sweep_preview: sweep.CommitPreviewV1,
    prepared_sweep_record: sweep_file.PreparedCommitRecordV1,
    durable_sweep_stream: []const u8,
    anchor: sweep_record.RecoveryAnchorV1,
    metadata: RecordMetadataV1,
    candidate_storage: []u8,
) Error!PreparedReclaimV1 {
    try sweep_file.verifyPublishedCommitRecordV1(
        sweep_preview,
        prepared_sweep_record,
        durable_sweep_stream,
        anchor,
    );
    if (!std.mem.eql(
        u8,
        &tenant_scope_sha256,
        &sweep_preview.commit_grant.tenant_scope_sha256,
    )) return Error.ReclaimBindingMismatch;
    const targets = sweep_preview.targets[0..sweep_preview.target_count];
    const preview = try payload_store.previewReclaimV1(
        active,
        tenant_scope_sha256,
        targets,
        candidate_storage,
    );
    try validateSweepBindingV1(sweep_preview, preview);
    const reclaim_record = try prepareReclaimRecordV1(
        preview,
        prepared_sweep_record.record_sha256,
        metadata,
        targets,
    );
    return .{
        .preview = preview,
        .record = reclaim_record,
        .candidate_bytes = std.math.cast(
            usize,
            preview.after.encoded_bytes,
        ) orelse return Error.ArithmeticOverflow,
    };
}

pub fn prepareReclaimRecordV1(
    preview: payload_store.ReclaimPreviewV1,
    sweep_record_sha256: Digest,
    metadata: RecordMetadataV1,
    targets: []const bundle.BlobRefV1,
) Error!PreparedReclaimRecordV1 {
    try payload_store.verifyReclaimPreviewV1(preview);
    const targets_sha256 = try object_store.retiredTargetsRootV1(targets);
    if (metadata.storage_epoch == 0 or
        isZero(metadata.challenge_sha256) or
        isZero(sweep_record_sha256) or
        targets.len > object_store.default_capacity or
        !std.mem.eql(
            u8,
            &targets_sha256,
            &preview.targets_sha256,
        ))
        return Error.InvalidReclaimRecord;
    var bytes = [_]u8{0} ** reclaim_record_bytes;
    @memcpy(bytes[0..8], &reclaim_record_magic);
    writeU64(&bytes, 8, reclaim_record_schema);
    writeU64(&bytes, 16, reclaim_record_bytes);
    writeU64(&bytes, 24, metadata.storage_epoch);
    @memcpy(bytes[32..64], &preview.before.tenant_scope_sha256);
    @memcpy(bytes[64..96], &sweep_record_sha256);
    @memcpy(bytes[96..128], &preview.targets_sha256);
    @memcpy(bytes[128..160], &preview.before.snapshot_sha256);
    @memcpy(bytes[160..192], &preview.after.snapshot_sha256);
    @memcpy(bytes[192..224], &preview.preview_sha256);
    writeU64(&bytes, 224, preview.before.encoded_bytes);
    writeU64(&bytes, 232, preview.after.encoded_bytes);
    writeU64(&bytes, 240, preview.freed_entries);
    writeU64(&bytes, 248, preview.freed_payload_bytes);
    writeU64(&bytes, 256, @intCast(targets.len));
    var cursor: usize = targets_offset;
    for (targets) |target| {
        writeU64(&bytes, cursor, target.byte_length);
        cursor += 8;
        @memcpy(bytes[cursor .. cursor + 32], &target.sha256);
        cursor += 32;
    }
    @memcpy(
        bytes[challenge_offset .. challenge_offset + 32],
        &metadata.challenge_sha256,
    );
    const record_sha256 = reclaimRecordRootV1(
        bytes[0..record_root_offset],
    );
    @memcpy(
        bytes[record_root_offset .. record_root_offset + 32],
        &record_sha256,
    );
    return .{ .bytes = bytes, .record_sha256 = record_sha256 };
}

pub fn decodeReclaimRecordV1(
    prepared: PreparedReclaimRecordV1,
) Error!DecodedReclaimRecordV1 {
    const bytes = &prepared.bytes;
    if (!std.mem.eql(u8, bytes[0..8], &reclaim_record_magic) or
        readU64(bytes, 8) != reclaim_record_schema or
        readU64(bytes, 16) != reclaim_record_bytes)
        return Error.InvalidReclaimRecord;
    const target_count_u64 = readU64(bytes, 256);
    const target_count = std.math.cast(usize, target_count_u64) orelse
        return Error.InvalidReclaimRecord;
    if (target_count == 0 or target_count > object_store.default_capacity)
        return Error.InvalidReclaimRecord;
    var targets = [_]bundle.BlobRefV1{.{
        .byte_length = 0,
        .sha256 = capsule.zero_digest,
    }} ** object_store.default_capacity;
    var cursor: usize = targets_offset;
    for (targets[0..target_count]) |*target| {
        target.byte_length = readU64(bytes, cursor);
        cursor += 8;
        @memcpy(&target.sha256, bytes[cursor .. cursor + 32]);
        cursor += 32;
    }
    if (!std.mem.allEqual(
        u8,
        bytes[cursor..challenge_offset],
        0,
    )) return Error.InvalidReclaimRecord;
    const targets_sha256 = object_store.retiredTargetsRootV1(
        targets[0..target_count],
    ) catch return Error.InvalidReclaimRecord;
    var decoded: DecodedReclaimRecordV1 = .{
        .storage_epoch = readU64(bytes, 24),
        .tenant_scope_sha256 = bytes[32..64].*,
        .sweep_record_sha256 = bytes[64..96].*,
        .targets_sha256 = bytes[96..128].*,
        .before_snapshot_sha256 = bytes[128..160].*,
        .after_snapshot_sha256 = bytes[160..192].*,
        .preview_sha256 = bytes[192..224].*,
        .before_encoded_bytes = readU64(bytes, 224),
        .after_encoded_bytes = readU64(bytes, 232),
        .freed_entries = readU64(bytes, 240),
        .freed_payload_bytes = readU64(bytes, 248),
        .targets = targets,
        .target_count = target_count,
        .challenge_sha256 = bytes[challenge_offset .. challenge_offset + 32].*,
        .record_sha256 = bytes[record_root_offset .. record_root_offset + 32].*,
    };
    var target_payload_bytes: u64 = 0;
    for (decoded.targets[0..decoded.target_count]) |target| {
        target_payload_bytes = std.math.add(
            u64,
            target_payload_bytes,
            target.byte_length,
        ) catch return Error.InvalidReclaimRecord;
    }
    const removed_entry_bytes = std.math.mul(
        u64,
        decoded.freed_entries,
        payload_store.entry_header_bytes,
    ) catch return Error.InvalidReclaimRecord;
    const removed_encoded_bytes = std.math.add(
        u64,
        removed_entry_bytes,
        decoded.freed_payload_bytes,
    ) catch return Error.InvalidReclaimRecord;
    const expected_preview_sha256 =
        payload_store.previewCommitmentRootV1(
            decoded.before_snapshot_sha256,
            decoded.after_snapshot_sha256,
            decoded.targets_sha256,
            decoded.freed_entries,
            decoded.freed_payload_bytes,
        );
    if (decoded.storage_epoch == 0 or
        isZero(decoded.tenant_scope_sha256) or
        isZero(decoded.sweep_record_sha256) or
        isZero(decoded.targets_sha256) or
        isZero(decoded.before_snapshot_sha256) or
        isZero(decoded.after_snapshot_sha256) or
        isZero(decoded.preview_sha256) or
        isZero(decoded.challenge_sha256) or
        isZero(decoded.record_sha256) or
        std.mem.eql(
            u8,
            &decoded.before_snapshot_sha256,
            &decoded.after_snapshot_sha256,
        ) or decoded.before_encoded_bytes <=
        decoded.after_encoded_bytes or
        decoded.after_encoded_bytes <
            payload_store.minimum_encoded_bytes or
        decoded.before_encoded_bytes - decoded.after_encoded_bytes !=
            removed_encoded_bytes or
        decoded.freed_entries != target_count_u64 or
        decoded.freed_payload_bytes != target_payload_bytes or
        !std.mem.eql(
            u8,
            &targets_sha256,
            &decoded.targets_sha256,
        ) or !std.mem.eql(
        u8,
        &expected_preview_sha256,
        &decoded.preview_sha256,
    ) or !std.mem.eql(
        u8,
        &decoded.record_sha256,
        &prepared.record_sha256,
    ) or !std.mem.eql(
        u8,
        &reclaimRecordRootV1(bytes[0..record_root_offset]),
        &decoded.record_sha256,
    ))
        return Error.InvalidReclaimRecord;
    return decoded;
}

pub fn verifyReclaimRecordV1(
    prepared: PreparedReclaimRecordV1,
    preview: payload_store.ReclaimPreviewV1,
    expected_sweep_record_sha256: Digest,
) Error!void {
    try payload_store.verifyReclaimPreviewV1(preview);
    const decoded = try decodeReclaimRecordV1(prepared);
    if (!std.mem.eql(
        u8,
        &decoded.tenant_scope_sha256,
        &preview.before.tenant_scope_sha256,
    ) or !std.mem.eql(
        u8,
        &decoded.sweep_record_sha256,
        &expected_sweep_record_sha256,
    ) or !std.mem.eql(
        u8,
        &decoded.targets_sha256,
        &preview.targets_sha256,
    ) or !std.mem.eql(
        u8,
        &decoded.before_snapshot_sha256,
        &preview.before.snapshot_sha256,
    ) or !std.mem.eql(
        u8,
        &decoded.after_snapshot_sha256,
        &preview.after.snapshot_sha256,
    ) or !std.mem.eql(
        u8,
        &decoded.preview_sha256,
        &preview.preview_sha256,
    ) or decoded.before_encoded_bytes != preview.before.encoded_bytes or
        decoded.after_encoded_bytes != preview.after.encoded_bytes or
        decoded.freed_entries != preview.freed_entries or
        decoded.freed_payload_bytes != preview.freed_payload_bytes)
        return Error.InvalidReclaimRecord;
}

/// Publishes and syncs the immutable plan sidecar. Repeating an exact
/// publication is idempotent; a foreign existing record rejects.
pub fn publishReclaimRecordV1(
    lease: *LeaseV1,
    prepared: PreparedReclaimRecordV1,
) Error!void {
    return publishReclaimRecordObservedV1(lease, prepared, null);
}

pub fn publishReclaimRecordObservedV1(
    lease: *LeaseV1,
    prepared: PreparedReclaimRecordV1,
    observer: ?ObserverV1,
) Error!void {
    if (lease.state != .ready) return Error.InvalidState;
    _ = try verifyLeaseRecordScopeV1(lease, prepared);
    var name_storage: [max_generated_name_bytes]u8 = undefined;
    const name = reclaimRecordNameV1(
        prepared.record_sha256,
        &name_storage,
    ) catch return Error.InvalidReclaimRecord;
    const created = openSafeFile(
        lease.directory,
        name,
        .create,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return Error.StorageIo,
    };
    if (created) |file| {
        defer file.close();
        lease.state = .poisoned;
        file.writeAll(&prepared.bytes) catch return Error.StorageIo;
        if (observer) |value| try value.after(.plan_write);
        file.sync() catch return Error.StorageIo;
        if (observer) |value| try value.after(.plan_sync);
        _ = inspectFile(
            file,
            lease.directory,
            name,
        ) catch return Error.StorageIdentityChanged;
        syncDirectory(lease.directory) catch return Error.StorageIo;
        if (observer) |value| try value.after(.plan_directory_sync);
        lease.state = .ready;
        return;
    }
    var existing_storage: [reclaim_record_bytes]u8 = undefined;
    const existing = readExactFile(
        lease.directory,
        name,
        &existing_storage,
        reclaim_record_bytes,
    ) catch return Error.StorageIo;
    if (existing.len != reclaim_record_bytes or
        !std.mem.eql(u8, existing, &prepared.bytes))
        return Error.PublishedPlanMismatch;
    const existing_file = openSafeFile(
        lease.directory,
        name,
        .existing,
    ) catch return Error.StorageIo;
    defer existing_file.close();
    lease.state = .poisoned;
    existing_file.sync() catch return Error.StorageIo;
    syncDirectory(lease.directory) catch return Error.StorageIo;
    lease.state = .ready;
}

/// Applies or recognizes one exact published payload successor. The durable
/// sweep publication and sidecar are reverified before filesystem mutation.
pub fn applyFromPublishedSweepV1(
    lease: *LeaseV1,
    sweep_preview: sweep.CommitPreviewV1,
    prepared_sweep_record: sweep_file.PreparedCommitRecordV1,
    durable_sweep_stream: []const u8,
    anchor: sweep_record.RecoveryAnchorV1,
    prepared: PreparedReclaimV1,
    candidate: []const u8,
    observer: ?ObserverV1,
) Error!ApplyReceiptV1 {
    if (lease.state != .ready) return Error.InvalidState;
    try sweep_file.verifyPublishedCommitRecordV1(
        sweep_preview,
        prepared_sweep_record,
        durable_sweep_stream,
        anchor,
    );
    try validateSweepBindingV1(sweep_preview, prepared.preview);
    try verifyReclaimRecordV1(
        prepared.record,
        prepared.preview,
        prepared_sweep_record.record_sha256,
    );
    return applyPublishedPlanV1(
        lease,
        prepared,
        candidate,
        prepared_sweep_record.record_sha256,
        observer,
    );
}

/// Reconstructs exact target authority from the two durable records after
/// process death. An old active snapshot regenerates and promotes the candidate;
/// the exact new snapshot is idempotent success; every third state rejects.
pub fn recoverFromPublishedFilesV1(
    lease: *LeaseV1,
    prepared_sweep_record: sweep_file.PreparedCommitRecordV1,
    durable_sweep_stream: []const u8,
    anchor: sweep_record.RecoveryAnchorV1,
    prepared_reclaim_record: PreparedReclaimRecordV1,
    candidate_storage: []u8,
    observer: ?ObserverV1,
) Error!ApplyReceiptV1 {
    if (lease.state != .ready) return Error.InvalidState;
    const decoded = try verifyLeaseRecordScopeV1(
        lease,
        prepared_reclaim_record,
    );
    if (!std.mem.eql(
        u8,
        &decoded.sweep_record_sha256,
        &prepared_sweep_record.record_sha256,
    )) return Error.ReclaimBindingMismatch;
    const sweep_preview = try sweep_file.commitPreviewFromRecordV1(
        prepared_sweep_record,
        decoded.targets[0..decoded.target_count],
    );
    try sweep_file.verifyPublishedCommitRecordV1(
        sweep_preview,
        prepared_sweep_record,
        durable_sweep_stream,
        anchor,
    );
    if (!std.mem.eql(
        u8,
        &decoded.targets_sha256,
        &sweep_preview.result.receipt.targets_sha256,
    ) or decoded.freed_entries !=
        sweep_preview.result.receipt.freed_entries or
        decoded.freed_payload_bytes !=
            sweep_preview.result.receipt.freed_payload_bytes)
        return Error.ReclaimBindingMismatch;
    try verifyPublishedSidecarV1(lease, prepared_reclaim_record);
    try lease.refresh();
    if (std.mem.eql(
        u8,
        &lease.active_snapshot.snapshot_sha256,
        &decoded.after_snapshot_sha256,
    ) and lease.active_snapshot.encoded_bytes ==
        decoded.after_encoded_bytes)
    {
        syncDirectory(lease.directory) catch return Error.StorageIo;
        return .{
            .disposition = .already_applied,
            .active_snapshot = lease.active_snapshot,
            .reclaim_record_sha256 = prepared_reclaim_record.record_sha256,
        };
    }
    if (!std.mem.eql(
        u8,
        &lease.active_snapshot.snapshot_sha256,
        &decoded.before_snapshot_sha256,
    ) or lease.active_snapshot.encoded_bytes !=
        decoded.before_encoded_bytes)
        return Error.ActiveSnapshotMismatch;
    const preview = try payload_store.previewReclaimV1(
        lease.stream(),
        lease.tenant_scope_sha256,
        decoded.targets[0..decoded.target_count],
        candidate_storage,
    );
    try validateSweepBindingV1(sweep_preview, preview);
    try verifyReclaimRecordV1(
        prepared_reclaim_record,
        preview,
        prepared_sweep_record.record_sha256,
    );
    const candidate_bytes = std.math.cast(
        usize,
        preview.after.encoded_bytes,
    ) orelse return Error.ArithmeticOverflow;
    const prepared: PreparedReclaimV1 = .{
        .preview = preview,
        .record = prepared_reclaim_record,
        .candidate_bytes = candidate_bytes,
    };
    return applyFromPublishedSweepV1(
        lease,
        sweep_preview,
        prepared_sweep_record,
        durable_sweep_stream,
        anchor,
        prepared,
        candidate_storage[0..candidate_bytes],
        observer,
    );
}

fn applyPublishedPlanV1(
    lease: *LeaseV1,
    prepared: PreparedReclaimV1,
    candidate: []const u8,
    expected_sweep_record_sha256: Digest,
    observer: ?ObserverV1,
) Error!ApplyReceiptV1 {
    try verifyReclaimRecordV1(
        prepared.record,
        prepared.preview,
        expected_sweep_record_sha256,
    );
    if (candidate.len != prepared.candidate_bytes or
        slicesOverlap(candidate, lease.active_storage))
        return Error.CandidateMismatch;
    var candidate_views: [payload_store.default_capacity]payload_store.EntryViewV1 = undefined;
    const candidate_snapshot = try payload_store.decodeSnapshotV1(
        candidate,
        lease.tenant_scope_sha256,
        &candidate_views,
    );
    if (!std.meta.eql(candidate_snapshot, prepared.preview.after))
        return Error.CandidateMismatch;
    try verifyPublishedSidecarV1(lease, prepared.record);
    try lease.refresh();
    if (std.meta.eql(lease.active_snapshot, prepared.preview.after)) {
        syncDirectory(lease.directory) catch return Error.StorageIo;
        return .{
            .disposition = .already_applied,
            .active_snapshot = lease.active_snapshot,
            .reclaim_record_sha256 = prepared.record.record_sha256,
        };
    }
    if (!std.meta.eql(lease.active_snapshot, prepared.preview.before))
        return Error.ActiveSnapshotMismatch;

    lease.state = .poisoned;
    var candidate_name_storage: [max_generated_name_bytes]u8 = undefined;
    const candidate_name = candidateNameV1(
        prepared.record.record_sha256,
        &candidate_name_storage,
    ) catch return Error.CandidateMismatch;
    try ensureCandidateV1(
        lease,
        candidate_name,
        candidate,
        observer,
    );
    const before_rename = readSnapshotFile(
        lease.directory,
        active_name,
        lease.tenant_scope_sha256,
        lease.active_storage,
        lease.max_bytes,
    ) catch return Error.StorageIo;
    if (!std.meta.eql(before_rename.snapshot, prepared.preview.before))
        return Error.ActiveSnapshotMismatch;
    lease.directory.rename(
        candidate_name,
        active_name,
    ) catch return Error.StorageIo;
    if (observer) |value| try value.after(.promote_rename);
    syncDirectory(lease.directory) catch return Error.StorageIo;
    if (observer) |value| try value.after(.directory_sync);
    const promoted = readSnapshotFile(
        lease.directory,
        active_name,
        lease.tenant_scope_sha256,
        lease.active_storage,
        lease.max_bytes,
    ) catch return Error.StorageIo;
    if (!std.meta.eql(promoted.snapshot, candidate_snapshot))
        return Error.CandidateMismatch;
    lease.active_bytes = promoted.bytes;
    lease.active_snapshot = promoted.snapshot;
    lease.state = .ready;
    return .{
        .disposition = .applied,
        .active_snapshot = candidate_snapshot,
        .reclaim_record_sha256 = prepared.record.record_sha256,
    };
}

fn validateSweepBindingV1(
    sweep_preview: sweep.CommitPreviewV1,
    payload_preview: payload_store.ReclaimPreviewV1,
) Error!void {
    if (!std.mem.eql(
        u8,
        &sweep_preview.commit_grant.tenant_scope_sha256,
        &payload_preview.before.tenant_scope_sha256,
    ) or !std.mem.eql(
        u8,
        &sweep_preview.result.receipt.targets_sha256,
        &payload_preview.targets_sha256,
    ) or sweep_preview.result.receipt.freed_entries !=
        payload_preview.freed_entries or
        sweep_preview.result.receipt.freed_payload_bytes !=
            payload_preview.freed_payload_bytes)
        return Error.ReclaimBindingMismatch;
}

fn ensureCandidateV1(
    lease: *LeaseV1,
    name: []const u8,
    candidate: []const u8,
    observer: ?ObserverV1,
) Error!void {
    const created = openSafeFile(
        lease.directory,
        name,
        .create,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => null,
        else => return Error.StorageIo,
    };
    if (created) |file| {
        defer file.close();
        file.writeAll(candidate) catch return Error.StorageIo;
        if (observer) |value| try value.after(.candidate_write);
        file.sync() catch return Error.StorageIo;
        if (observer) |value| try value.after(.candidate_sync);
        const view = inspectFile(
            file,
            lease.directory,
            name,
        ) catch return Error.StorageIdentityChanged;
        if (view.size != candidate.len) return Error.CandidateMismatch;
        return;
    }
    if (candidate.len > lease.active_storage.len)
        return Error.BufferTooSmall;
    const existing = readExactFile(
        lease.directory,
        name,
        lease.active_storage,
        lease.max_bytes,
    ) catch return Error.StorageIo;
    if (!std.mem.eql(u8, existing, candidate))
        return Error.CandidateMismatch;
    const file = openSafeFile(
        lease.directory,
        name,
        .existing,
    ) catch return Error.StorageIo;
    defer file.close();
    file.sync() catch return Error.StorageIo;
}

fn verifyPublishedSidecarV1(
    lease: *LeaseV1,
    prepared: PreparedReclaimRecordV1,
) Error!void {
    _ = try verifyLeaseRecordScopeV1(lease, prepared);
    var name_storage: [max_generated_name_bytes]u8 = undefined;
    const name = reclaimRecordNameV1(
        prepared.record_sha256,
        &name_storage,
    ) catch return Error.InvalidReclaimRecord;
    var storage: [reclaim_record_bytes]u8 = undefined;
    const encoded = readExactFile(
        lease.directory,
        name,
        &storage,
        reclaim_record_bytes,
    ) catch return Error.StorageIo;
    if (!std.mem.eql(u8, encoded, &prepared.bytes))
        return Error.PublishedPlanMismatch;
}

fn verifyLeaseRecordScopeV1(
    lease: *const LeaseV1,
    prepared: PreparedReclaimRecordV1,
) Error!DecodedReclaimRecordV1 {
    const decoded = try decodeReclaimRecordV1(prepared);
    if (decoded.storage_epoch != lease.storage_epoch or
        !std.mem.eql(
            u8,
            &decoded.tenant_scope_sha256,
            &lease.tenant_scope_sha256,
        ))
        return Error.ReclaimBindingMismatch;
    return decoded;
}

fn writeInitialFile(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    try file.writeAll(bytes);
    try file.sync();
    const view = try inspectFile(file, directory, name);
    if (view.size != bytes.len) return Error.StorageIdentityChanged;
    try syncDirectory(directory);
}

fn readSnapshotFile(
    directory: std.fs.Dir,
    name: []const u8,
    tenant_scope_sha256: Digest,
    storage: []u8,
    max_bytes: usize,
) !LoadedSnapshotV1 {
    const encoded = try readExactFile(
        directory,
        name,
        storage,
        max_bytes,
    );
    var views: [payload_store.default_capacity]payload_store.EntryViewV1 =
        undefined;
    const snapshot = try payload_store.decodeSnapshotV1(
        encoded,
        tenant_scope_sha256,
        &views,
    );
    return .{ .bytes = encoded.len, .snapshot = snapshot };
}

fn readExactFile(
    directory: std.fs.Dir,
    name: []const u8,
    storage: []u8,
    max_bytes: usize,
) ![]const u8 {
    const file = try openSafeFile(directory, name, .existing);
    defer file.close();
    const before = try inspectFile(file, directory, name);
    if (before.size > max_bytes or before.size > storage.len)
        return Error.BufferTooSmall;
    const encoded = storage[0..before.size];
    if (try file.preadAll(encoded, 0) != encoded.len)
        return Error.StorageIo;
    const after = try inspectFile(file, directory, name);
    if (!std.meta.eql(before, after))
        return Error.StorageIdentityChanged;
    return encoded;
}

fn openSafeFile(
    directory: std.fs.Dir,
    name: []const u8,
    kind: OpenKind,
) !std.fs.File {
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW"))
        return Error.UnsupportedPlatform;
    var flags: std.posix.O = .{ .ACCMODE = .RDWR };
    flags.CLOEXEC = true;
    flags.NOFOLLOW = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (kind == .create) {
        flags.CREAT = true;
        flags.EXCL = true;
    }
    const fd = try std.posix.openat(
        directory.fd,
        name,
        flags,
        if (kind == .create) 0o600 else 0,
    );
    return .{ .handle = fd };
}

fn inspectFile(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
) !FileViewV1 {
    const file_stat = try std.posix.fstat(file.handle);
    const entry_stat = try std.posix.fstatat(
        directory.fd,
        name,
        std.posix.AT.SYMLINK_NOFOLLOW,
    );
    const file_view = try inspectStat(file_stat);
    const entry_view = try inspectStat(entry_stat);
    if (!std.meta.eql(file_view, entry_view))
        return Error.StorageIdentityChanged;
    return file_view;
}

fn inspectStat(stat: std.posix.Stat) Error!FileViewV1 {
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG)
        return Error.InvalidStorage;
    if (stat.nlink != 1) return Error.MultipleLinks;
    if ((stat.mode & 0o077) != 0) return Error.UnsafePermissions;
    return .{
        .device = std.math.cast(u64, stat.dev) orelse
            return Error.InvalidStorage,
        .inode = std.math.cast(u64, stat.ino) orelse
            return Error.InvalidStorage,
        .size = std.math.cast(usize, stat.size) orelse
            return Error.CapacityExceeded,
    };
}

pub fn reclaimRecordNameV1(
    record_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(record_sha256, .lower);
    return std.fmt.bufPrint(storage, "payload-plan-{s}.record", .{&hex});
}

fn candidateNameV1(
    record_sha256: Digest,
    storage: []u8,
) ![]const u8 {
    const hex = std.fmt.bytesToHex(record_sha256, .lower);
    return std.fmt.bufPrint(storage, "payload-next-{s}.snapshot", .{&hex});
}

fn reclaimRecordRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(reclaim_record_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    @memcpy(output[offset .. offset + bytes.len], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    var bytes: [8]u8 = undefined;
    @memcpy(&bytes, input[offset .. offset + bytes.len]);
    return std.mem.readInt(u64, &bytes, .little);
}

fn syncDirectory(directory: std.fs.Dir) !void {
    try std.posix.fsync(directory.fd);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

test "payload file publishes plan and atomically promotes exact successor" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const tenant = [_]u8{0x6d} ** 32;
    const payloads = [_][]const u8{
        "payload-alpha",
        "payload-beta-beta",
        "payload-gamma-gamma-gamma",
    };
    var inputs: [payloads.len]payload_store.EntryInputV1 = undefined;
    for (payloads, 0..) |payload, index| {
        inputs[index] = .{
            .reference = try @import("continuation_bundle.zig").blobRefV1(
                tenant,
                payload,
            ),
            .payload = payload,
        };
    }
    payload_store.sortEntriesV1(&inputs);
    var initial_storage: [512]u8 = undefined;
    const initial = try payload_store.encodeSnapshotV1(
        tenant,
        &inputs,
        &initial_storage,
    );
    var targets = [_]@import("continuation_bundle.zig").BlobRefV1{
        inputs[1].reference,
    };
    @import("continuation_object_store.zig").sortRootReferencesV1(&targets);
    var candidate_storage: [512]u8 = undefined;
    const preview = try payload_store.previewReclaimV1(
        initial,
        tenant,
        &targets,
        &candidate_storage,
    );
    const record = try prepareReclaimRecordV1(
        preview,
        [_]u8{0x91} ** 32,
        .{
            .storage_epoch = 1,
            .challenge_sha256 = [_]u8{0x92} ** 32,
        },
        &targets,
    );
    try verifyReclaimRecordV1(record, preview, [_]u8{0x91} ** 32);
    var rehashed_contradiction = record;
    rehashed_contradiction.bytes[192] ^= 1;
    rehashed_contradiction.record_sha256 = reclaimRecordRootV1(
        rehashed_contradiction.bytes[0..record_root_offset],
    );
    @memcpy(
        rehashed_contradiction.bytes[record_root_offset .. record_root_offset + 32],
        &rehashed_contradiction.record_sha256,
    );
    try std.testing.expectError(
        Error.InvalidReclaimRecord,
        decodeReclaimRecordV1(rehashed_contradiction),
    );

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var lock_storage: [1]u8 = undefined;
    var active_storage: [512]u8 = undefined;
    var lease = try LeaseV1.create(
        temporary.dir,
        1,
        tenant,
        initial,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    var foreign_epoch = record;
    writeU64(&foreign_epoch.bytes, 24, 2);
    foreign_epoch.record_sha256 = reclaimRecordRootV1(
        foreign_epoch.bytes[0..record_root_offset],
    );
    @memcpy(
        foreign_epoch.bytes[record_root_offset .. record_root_offset + 32],
        &foreign_epoch.record_sha256,
    );
    try std.testing.expectError(
        Error.ReclaimBindingMismatch,
        publishReclaimRecordV1(&lease, foreign_epoch),
    );
    try publishReclaimRecordV1(&lease, record);
    const candidate_bytes = std.math.cast(
        usize,
        preview.after.encoded_bytes,
    ) orelse return Error.ArithmeticOverflow;
    const candidate = candidate_storage[0..candidate_bytes];
    const prepared: PreparedReclaimV1 = .{
        .preview = preview,
        .record = record,
        .candidate_bytes = candidate.len,
    };
    const applied = try applyPublishedPlanV1(
        &lease,
        prepared,
        candidate,
        [_]u8{0x91} ** 32,
        null,
    );
    try std.testing.expectEqual(
        ApplyDispositionV1.applied,
        applied.disposition,
    );
    lease.close();

    var reopened_lock_storage: [1]u8 = undefined;
    var reopened_active_storage: [512]u8 = undefined;
    var reopened = try LeaseV1.open(
        temporary.dir,
        1,
        tenant,
        reopened_active_storage.len,
        &reopened_lock_storage,
        &reopened_active_storage,
    );
    defer reopened.close();
    try std.testing.expect(std.meta.eql(
        reopened.active_snapshot,
        preview.after,
    ));
    const repeated = try applyPublishedPlanV1(
        &reopened,
        prepared,
        candidate,
        [_]u8{0x91} ** 32,
        null,
    );
    try std.testing.expectEqual(
        ApplyDispositionV1.already_applied,
        repeated.disposition,
    );
    var foreign_targets = [_]bundle.BlobRefV1{inputs[0].reference};
    object_store.sortRootReferencesV1(&foreign_targets);
    var third_storage: [512]u8 = undefined;
    const third_preview = try payload_store.previewReclaimV1(
        initial,
        tenant,
        &foreign_targets,
        &third_storage,
    );
    const third_bytes = std.math.cast(
        usize,
        third_preview.after.encoded_bytes,
    ) orelse return Error.ArithmeticOverflow;
    const active_file = try openSafeFile(
        temporary.dir,
        active_name,
        .existing,
    );
    try active_file.setEndPos(0);
    try active_file.pwriteAll(third_storage[0..third_bytes], 0);
    try active_file.sync();
    active_file.close();
    try std.testing.expectError(
        Error.ActiveSnapshotMismatch,
        applyPublishedPlanV1(
            &reopened,
            prepared,
            candidate,
            [_]u8{0x91} ** 32,
            null,
        ),
    );
}
