//! Descriptor-relative filesystem adapter for continuation sweep publication.
//!
//! The adapter owns one locked regular-file descriptor beneath a caller-opened
//! directory. It composes with `continuation_object_sweep_writer.zig` rather
//! than duplicating record or recovery policy. Namespace identity, link count,
//! private permissions, exact length, and the pinned lease/snapshot binding are
//! checked before and after every external mutation.
//!
//! POSIX locks are advisory. A non-cooperating process can still rename,
//! replace, or overwrite files. The adapter detects visible identity, link,
//! mode, and length drift and poisons the capability; it does not claim to
//! detect a transient or same-length in-place overwrite by an untrusted writer.

const std = @import("std");
const builtin = @import("builtin");
const capsule = @import("continuation_capsule.zig");
const bundle = @import("continuation_bundle.zig");
const object_store = @import("continuation_object_store.zig");
const sweep = @import("continuation_object_sweep.zig");
const record = @import("continuation_object_sweep_record.zig");
const sweep_writer = @import("continuation_object_sweep_writer.zig");

pub const Digest = sweep_writer.Digest;
pub const max_name_bytes: usize = 255;

pub const Error = sweep_writer.Error || error{
    BufferTooSmall,
    InvalidName,
    MultipleLinks,
    PublishedCommitMismatch,
    PublishedCommitStateMismatch,
    UnsafePermissions,
};

pub const DirectorySyncStatusV1 = enum(u8) {
    synced,
    not_applicable,
};

pub const LeaseStateV1 = enum(u8) {
    ready,
    append_active,
    repair_ready,
    repair_active,
    repair_complete,
    poisoned,
    closed,
};

pub const FileIdentityV1 = struct {
    device: u64,
    inode: u64,
};

pub const CommitRecordMetadataV1 = struct {
    record_epoch: u64,
    sequence: u64,
    previous_record_sha256: Digest,
    record_challenge_sha256: Digest,
};

pub const PreparedCommitRecordV1 = struct {
    bytes: [record.encoded_bytes]u8,
    record_sha256: Digest,
};

pub const CommitBoundaryObserverV1 = struct {
    context: *anyopaque,
    after_publication_fn: *const fn (
        context: *anyopaque,
        record_sha256: Digest,
    ) sweep_writer.Error!void,

    fn afterPublication(
        self: CommitBoundaryObserverV1,
        record_sha256: Digest,
    ) sweep_writer.Error!void {
        try self.after_publication_fn(self.context, record_sha256);
    }
};

pub const PublishedCommitResultV1 = struct {
    publication: sweep_writer.AppendReceiptV1,
    commit: sweep.CommitResultV1,
};

pub const CommitRecoveryDispositionV1 = enum(u8) {
    applied,
    already_applied,
};

pub const PublishedCommitRecoveryV1 = struct {
    disposition: CommitRecoveryDispositionV1,
    commit: sweep.CommitResultV1,
};

/// Called after an OS operation has returned but before its postcondition is
/// accepted. Tests use this boundary for process death and namespace races;
/// production adapters may use it for allocation-free tracing.
pub const PhaseObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        phase: sweep_writer.IoPhaseV1,
    ) sweep_writer.Error!void,

    fn after(
        self: PhaseObserverV1,
        phase: sweep_writer.IoPhaseV1,
    ) sweep_writer.Error!void {
        try self.after_phase_fn(self.context, phase);
    }
};

pub const AcquireOptionsV1 = struct {
    storage_epoch: u64,
    max_bytes: usize,
    lock_nonblocking: bool = true,
    require_private_mode: bool = true,
    observer: ?PhaseObserverV1 = null,
};

/// Materializes the exact sweep receipt that must become durable before its
/// matching payload transition may run. `preview` itself was computed without
/// mutating the store.
pub fn prepareCommitRecordV1(
    preview: sweep.CommitPreviewV1,
    metadata: CommitRecordMetadataV1,
) Error!PreparedCommitRecordV1 {
    try validateCommitPreviewV1(preview);
    const input: record.InputV1 = .{
        .record_epoch = metadata.record_epoch,
        .sequence = metadata.sequence,
        .previous_record_sha256 = metadata.previous_record_sha256,
        .record_challenge_sha256 = metadata.record_challenge_sha256,
        .commit_grant = preview.commit_grant,
        .commit_receipt = preview.result.receipt,
        .store_receipt = preview.result.store_receipt,
    };
    var bytes: [record.encoded_bytes]u8 = undefined;
    _ = try record.encodeV1(input, &bytes);
    const decoded = try record.decodeV1(&bytes);
    return .{
        .bytes = bytes,
        .record_sha256 = decoded.record_sha256,
    };
}

/// Reconstructs the allocation-free commit preview needed after process death
/// from one verified fixed record plus its exact canonical target list.
pub fn commitPreviewFromRecordV1(
    prepared: PreparedCommitRecordV1,
    targets: []const bundle.BlobRefV1,
) Error!sweep.CommitPreviewV1 {
    if (targets.len == 0 or targets.len > object_store.default_capacity)
        return Error.PublishedCommitMismatch;
    const decoded = try record.decodeV1(&prepared.bytes);
    if (!std.mem.eql(
        u8,
        &decoded.record_sha256,
        &prepared.record_sha256,
    )) return Error.PublishedCommitMismatch;
    try sweep.verifyCommitReceiptV1(
        decoded.input.commit_grant,
        decoded.input.commit_receipt,
        decoded.input.store_receipt,
    );
    const targets_sha256 = try object_store.retiredTargetsRootV1(targets);
    if (!std.mem.eql(
        u8,
        &targets_sha256,
        &decoded.input.commit_receipt.targets_sha256,
    )) return Error.PublishedCommitMismatch;
    const grant_sha256 = try sweep.commitGrantRootV1(
        decoded.input.commit_grant,
    );
    var fixed_targets = [_]bundle.BlobRefV1{.{
        .byte_length = 0,
        .sha256 = capsule.zero_digest,
    }} ** object_store.default_capacity;
    std.mem.copyForwards(
        bundle.BlobRefV1,
        fixed_targets[0..targets.len],
        targets,
    );
    const grant = decoded.input.commit_grant;
    return .{
        .commit_grant = grant,
        .permit = .{
            .authority_epoch = grant.authority_epoch,
            .tenant_scope_sha256 = grant.tenant_scope_sha256,
            .bundle_sha256 = grant.bundle_sha256,
            .store_grant_sha256 = grant.store_grant_sha256,
            .expected_snapshot_sha256 = grant.expected_snapshot_sha256,
            .authorization_sha256 = grant_sha256,
            .max_freed_entries = grant.max_freed_entries,
            .max_freed_bytes = grant.max_freed_bytes,
        },
        .targets = fixed_targets,
        .target_count = targets.len,
        .result = .{
            .receipt = decoded.input.commit_receipt,
            .store_receipt = decoded.input.store_receipt,
        },
    };
}

/// Appends and synchronizes the exact preview record before entering the
/// destructive no-failure suffix. If publication or its boundary observer
/// fails, no payload is freed.
pub fn publishThenCommitV1(
    store: *object_store.Store,
    preview: sweep.CommitPreviewV1,
    prepared: PreparedCommitRecordV1,
    publication_writer: *sweep_writer.WriterV1,
    observer: ?CommitBoundaryObserverV1,
) Error!PublishedCommitResultV1 {
    try validatePreparedCommitRecordV1(preview, prepared);
    const publication = try publication_writer.appendRecord(&prepared.bytes);
    if (!std.mem.eql(
        u8,
        &publication.record_sha256,
        &prepared.record_sha256,
    )) return Error.PublishedCommitMismatch;
    if (observer) |value|
        try value.afterPublication(publication.record_sha256);
    const committed = try sweep.commitPreviewV1(store, preview);
    if (!std.mem.eql(
        u8,
        &committed.receipt.snapshot_after_sha256,
        &preview.result.receipt.snapshot_after_sha256,
    )) return Error.PublishedCommitMismatch;
    return .{ .publication = publication, .commit = committed };
}

/// Reconciles one fully verified durable intent against the exact store
/// snapshot. The old snapshot applies once; the predicted new snapshot is an
/// idempotent success; every third state rejects.
pub fn recoverPublishedCommitV1(
    store: *object_store.Store,
    preview: sweep.CommitPreviewV1,
    prepared: PreparedCommitRecordV1,
    durable_stream: []const u8,
    anchor: record.RecoveryAnchorV1,
) Error!PublishedCommitRecoveryV1 {
    try verifyPublishedCommitRecordV1(
        preview,
        prepared,
        durable_stream,
        anchor,
    );
    const snapshot = try store.auditSnapshotRootV2();
    if (std.mem.eql(
        u8,
        &snapshot,
        &preview.result.receipt.snapshot_before_sha256,
    )) {
        const committed = try sweep.commitPreviewV1(store, preview);
        return .{ .disposition = .applied, .commit = committed };
    }
    if (std.mem.eql(
        u8,
        &snapshot,
        &preview.result.receipt.snapshot_after_sha256,
    )) {
        return .{
            .disposition = .already_applied,
            .commit = preview.result,
        };
    }
    return Error.PublishedCommitStateMismatch;
}

/// Verifies that an exact preview record is the complete anchored durable
/// publication. Downstream durable payload adapters use this without receiving
/// in-memory deallocation authority.
pub fn verifyPublishedCommitRecordV1(
    preview: sweep.CommitPreviewV1,
    prepared: PreparedCommitRecordV1,
    durable_stream: []const u8,
    anchor: record.RecoveryAnchorV1,
) Error!void {
    try validatePreparedCommitRecordV1(preview, prepared);
    const classification = try record.classifyRecoveryV1(
        durable_stream,
        anchor,
    );
    if (classification.status != .clean or
        classification.committed_bytes != durable_stream.len or
        !std.mem.eql(
            u8,
            &classification.final_record_sha256,
            &prepared.record_sha256,
        ))
        return Error.PublishedCommitMismatch;
}

fn validateCommitPreviewV1(
    preview: sweep.CommitPreviewV1,
) Error!void {
    if (preview.target_count == 0 or
        preview.target_count > preview.targets.len)
        return Error.PublishedCommitMismatch;
    try sweep.verifyCommitReceiptV1(
        preview.commit_grant,
        preview.result.receipt,
        preview.result.store_receipt,
    );
    const targets_root = try object_store.retiredTargetsRootV1(
        preview.targets[0..preview.target_count],
    );
    if (!std.mem.eql(
        u8,
        &targets_root,
        &preview.result.receipt.targets_sha256,
    )) return Error.PublishedCommitMismatch;
}

fn validatePreparedCommitRecordV1(
    preview: sweep.CommitPreviewV1,
    prepared: PreparedCommitRecordV1,
) Error!void {
    try validateCommitPreviewV1(preview);
    const decoded = try record.decodeV1(&prepared.bytes);
    if (!std.mem.eql(
        u8,
        &decoded.record_sha256,
        &prepared.record_sha256,
    ) or !std.meta.eql(
        decoded.input.commit_grant,
        preview.commit_grant,
    ) or !std.meta.eql(
        decoded.input.commit_receipt,
        preview.result.receipt,
    ) or !std.meta.eql(
        decoded.input.store_receipt,
        preview.result.store_receipt,
    )) return Error.PublishedCommitMismatch;
}

var next_lease_generation = std.atomic.Value(u64).init(1);

pub const FileLeaseV1 = struct {
    file: std.fs.File,
    directory: std.fs.Dir,
    name_storage: [max_name_bytes]u8,
    name_length: usize,
    stream_storage: []u8,
    observed_bytes: usize,
    current_bytes: usize,
    max_bytes: usize,
    identity: FileIdentityV1,
    snapshot: sweep_writer.StorageSnapshotV1,
    generation: u64,
    require_private_mode: bool,
    observer: ?PhaseObserverV1,
    directory_sync_status: DirectorySyncStatusV1,
    file_sync_count: u64,
    identity_check_count: u64,
    state: LeaseStateV1 = .ready,
    expected_phase: sweep_writer.IoPhaseV1 = .body_write,
    append_generation: u64 = 0,
    append_snapshot_sha256: Digest = capsule.zero_digest,
    repair_generation: u64 = 0,
    repair_snapshot_sha256: Digest = capsule.zero_digest,
    repair_expected_bytes: usize = 0,
    repair_target_bytes: usize = 0,

    /// Creates one empty, owner-private stream and durably publishes its
    /// directory entry before returning append authority.
    pub fn create(
        directory: std.fs.Dir,
        name: []const u8,
        options: AcquireOptionsV1,
        stream_storage: []u8,
    ) !FileLeaseV1 {
        if (comptime !platformSupported())
            return Error.UnsupportedPlatform;
        try validateAcquire(name, options);
        const generation = try reserveLeaseGeneration();
        var name_storage = [_]u8{0} ** max_name_bytes;
        @memcpy(name_storage[0..name.len], name);

        const file = try openLockedFile(
            directory,
            name,
            .create,
            options.lock_nonblocking,
        );
        errdefer file.close();
        const inspected = try inspectInitial(
            file,
            directory,
            name,
            options.require_private_mode,
        );
        if (inspected.size != 0) return Error.StorageIdentityChanged;
        try file.sync();
        try syncDirectory(directory);
        const verified = try inspectInitial(
            file,
            directory,
            name,
            options.require_private_mode,
        );
        if (!std.meta.eql(inspected.identity, verified.identity) or
            verified.size != 0)
            return Error.StorageIdentityChanged;
        const snapshot = try sweep_writer.makeStorageSnapshotV1(
            options.storage_epoch,
            generation,
            &.{},
            options.max_bytes,
        );
        return .{
            .file = file,
            .directory = directory,
            .name_storage = name_storage,
            .name_length = name.len,
            .stream_storage = stream_storage,
            .observed_bytes = 0,
            .current_bytes = 0,
            .max_bytes = options.max_bytes,
            .identity = inspected.identity,
            .snapshot = snapshot,
            .generation = generation,
            .require_private_mode = options.require_private_mode,
            .observer = options.observer,
            .directory_sync_status = .synced,
            .file_sync_count = 1,
            .identity_check_count = 2,
        };
    }

    /// Opens one existing regular file without following a final symlink,
    /// acquires an exclusive lock, reads an exact stable snapshot into caller
    /// storage, and rejects hard links or visible namespace replacement.
    pub fn open(
        directory: std.fs.Dir,
        name: []const u8,
        options: AcquireOptionsV1,
        stream_storage: []u8,
    ) !FileLeaseV1 {
        if (comptime !platformSupported())
            return Error.UnsupportedPlatform;
        try validateAcquire(name, options);
        const generation = try reserveLeaseGeneration();
        var name_storage = [_]u8{0} ** max_name_bytes;
        @memcpy(name_storage[0..name.len], name);

        const file = try openLockedFile(
            directory,
            name,
            .existing,
            options.lock_nonblocking,
        );
        errdefer file.close();
        const inspected = try inspectInitial(
            file,
            directory,
            name,
            options.require_private_mode,
        );
        if (inspected.size > options.max_bytes)
            return Error.CapacityExceeded;
        if (stream_storage.len < inspected.size)
            return Error.BufferTooSmall;
        const observed_stream = stream_storage[0..inspected.size];
        if (try file.preadAll(observed_stream, 0) != inspected.size)
            return Error.StorageIo;
        const verified = try inspectInitial(
            file,
            directory,
            name,
            options.require_private_mode,
        );
        if (!std.meta.eql(inspected, verified))
            return Error.StorageIdentityChanged;
        const snapshot = try sweep_writer.makeStorageSnapshotV1(
            options.storage_epoch,
            generation,
            observed_stream,
            options.max_bytes,
        );
        return .{
            .file = file,
            .directory = directory,
            .name_storage = name_storage,
            .name_length = name.len,
            .stream_storage = stream_storage,
            .observed_bytes = inspected.size,
            .current_bytes = inspected.size,
            .max_bytes = options.max_bytes,
            .identity = inspected.identity,
            .snapshot = snapshot,
            .generation = generation,
            .require_private_mode = options.require_private_mode,
            .observer = options.observer,
            .directory_sync_status = .not_applicable,
            .file_sync_count = 0,
            .identity_check_count = 2,
        };
    }

    pub fn entryName(self: *const FileLeaseV1) []const u8 {
        return self.name_storage[0..self.name_length];
    }

    pub fn stream(self: *const FileLeaseV1) []const u8 {
        return self.stream_storage[0..self.observed_bytes];
    }

    pub fn appendCapability(
        self: *FileLeaseV1,
    ) Error!sweep_writer.AppendCapabilityV1 {
        if (comptime !platformSupported())
            return Error.UnsupportedPlatform;
        if (self.state != .ready or
            self.expected_phase != .body_write or
            self.current_bytes != self.snapshot.observed_bytes)
            return Error.InvalidCapability;
        try self.verifyCurrent(self.current_bytes);
        if (self.append_generation != 0 and
            (self.append_generation != self.generation or
                !std.mem.eql(
                    u8,
                    &self.append_snapshot_sha256,
                    &self.snapshot.snapshot_sha256,
                )))
            return Error.InvalidCapability;
        self.append_generation = self.generation;
        self.append_snapshot_sha256 = self.snapshot.snapshot_sha256;
        return .{
            .context = self,
            .snapshot = self.snapshot,
            .validate_fn = validateAppend,
            .append_body_fn = appendBody,
            .sync_body_fn = syncBody,
            .append_footer_fn = appendFooter,
            .sync_footer_fn = syncFooter,
        };
    }

    pub fn prepareRepair(
        self: *FileLeaseV1,
        anchor: record.RecoveryAnchorV1,
    ) Error!sweep_writer.RepairCapabilityV1 {
        if (comptime !platformSupported())
            return Error.UnsupportedPlatform;
        if (self.state != .ready or
            self.expected_phase != .body_write or
            self.current_bytes != self.snapshot.observed_bytes)
            return Error.InvalidCapability;
        try self.verifyCurrent(self.current_bytes);
        const plan = try sweep_writer.planRecoveryV1(
            self.stream(),
            anchor,
            self.snapshot,
        );
        switch (plan.action) {
            .open_clean => return Error.RepairNotRequired,
            .repair_incomplete_tail => {},
            .reject_corrupt => return Error.CorruptRecovery,
        }
        self.clearAppendAuthorization();
        self.state = .repair_ready;
        self.expected_phase = .repair_truncate;
        self.repair_generation = self.generation;
        self.repair_snapshot_sha256 = self.snapshot.snapshot_sha256;
        self.repair_expected_bytes = self.snapshot.observed_bytes;
        self.repair_target_bytes = plan.truncate_to_bytes;
        return .{
            .context = self,
            .snapshot = self.snapshot,
            .expected_current_bytes = self.snapshot.observed_bytes,
            .target_bytes = plan.truncate_to_bytes,
            .discarded_tail_bytes = plan.discard_tail_bytes,
            .final_record_sha256 = plan.classification.final_record_sha256,
            .validate_fn = validateRepair,
            .truncate_fn = repairTruncate,
            .sync_fn = repairSync,
        };
    }

    /// Closing releases the OS lock and invalidates all capabilities. The
    /// caller owns the directory descriptor and stream buffer.
    pub fn close(self: *FileLeaseV1) void {
        if (self.state == .closed) return;
        self.state = .closed;
        self.generation = 0;
        self.clearAppendAuthorization();
        self.clearRepairAuthorization();
        self.file.close();
    }

    fn verifyCurrent(
        self: *FileLeaseV1,
        expected_bytes: usize,
    ) sweep_writer.Error!void {
        const file_stat = std.posix.fstat(self.file.handle) catch
            return Error.StorageIo;
        const entry_stat = std.posix.fstatat(
            self.directory.fd,
            self.entryName(),
            std.posix.AT.SYMLINK_NOFOLLOW,
        ) catch return Error.StorageIdentityChanged;
        const file_view = inspectForCapability(
            file_stat,
            self.require_private_mode,
        ) orelse return Error.StorageIdentityChanged;
        const entry_view = inspectForCapability(
            entry_stat,
            self.require_private_mode,
        ) orelse return Error.StorageIdentityChanged;
        if (!std.meta.eql(file_view, entry_view) or
            !std.meta.eql(file_view.identity, self.identity) or
            file_view.size != expected_bytes)
            return Error.StorageIdentityChanged;
        self.identity_check_count = std.math.add(
            u64,
            self.identity_check_count,
            1,
        ) catch return Error.ArithmeticOverflow;
    }

    fn observe(
        self: *FileLeaseV1,
        phase: sweep_writer.IoPhaseV1,
    ) sweep_writer.Error!void {
        if (self.observer) |observer| try observer.after(phase);
    }

    fn clearAppendAuthorization(self: *FileLeaseV1) void {
        self.append_generation = 0;
        self.append_snapshot_sha256 = capsule.zero_digest;
    }

    fn clearRepairAuthorization(self: *FileLeaseV1) void {
        self.repair_generation = 0;
        self.repair_snapshot_sha256 = capsule.zero_digest;
        self.repair_expected_bytes = 0;
        self.repair_target_bytes = 0;
    }

    fn validateGeneration(
        self: *FileLeaseV1,
        generation: u64,
    ) sweep_writer.Error!void {
        if (generation == 0 or self.generation != generation or
            self.state == .closed or self.state == .poisoned)
            return Error.InvalidCapability;
    }
};

fn validateAppend(
    context: *anyopaque,
    generation: u64,
    snapshot_sha256: Digest,
    expected_current_bytes: usize,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .ready or
        self.expected_phase != .body_write or
        self.append_generation != generation or
        self.current_bytes != expected_current_bytes or
        !std.mem.eql(
            u8,
            &self.append_snapshot_sha256,
            &snapshot_sha256,
        ))
        return Error.InvalidCapability;
    try self.verifyCurrent(expected_current_bytes);
}

fn appendBody(
    context: *anyopaque,
    generation: u64,
    bytes: []const u8,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .ready or
        self.expected_phase != .body_write or
        bytes.len != record.body_bytes)
        return Error.InvalidIoOrder;
    if (self.current_bytes > self.max_bytes -| record.encoded_bytes)
        return Error.CapacityExceeded;
    try self.verifyCurrent(self.current_bytes);
    self.state = .poisoned;
    self.file.pwriteAll(bytes, self.current_bytes) catch
        return Error.StorageIo;
    self.current_bytes = std.math.add(
        usize,
        self.current_bytes,
        bytes.len,
    ) catch return Error.ArithmeticOverflow;
    try self.observe(.body_write);
    try self.verifyCurrent(self.current_bytes);
    self.expected_phase = .body_sync;
    self.state = .append_active;
}

fn syncBody(
    context: *anyopaque,
    generation: u64,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .append_active or
        self.expected_phase != .body_sync)
        return Error.InvalidIoOrder;
    self.state = .poisoned;
    self.file.sync() catch return Error.StorageIo;
    self.file_sync_count = std.math.add(
        u64,
        self.file_sync_count,
        1,
    ) catch return Error.ArithmeticOverflow;
    try self.observe(.body_sync);
    try self.verifyCurrent(self.current_bytes);
    self.expected_phase = .footer_write;
    self.state = .append_active;
}

fn appendFooter(
    context: *anyopaque,
    generation: u64,
    bytes: []const u8,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .append_active or
        self.expected_phase != .footer_write or
        bytes.len != record.commit_footer_bytes)
        return Error.InvalidIoOrder;
    if (self.current_bytes > self.max_bytes -| bytes.len)
        return Error.CapacityExceeded;
    try self.verifyCurrent(self.current_bytes);
    self.state = .poisoned;
    self.file.pwriteAll(bytes, self.current_bytes) catch
        return Error.StorageIo;
    self.current_bytes = std.math.add(
        usize,
        self.current_bytes,
        bytes.len,
    ) catch return Error.ArithmeticOverflow;
    try self.observe(.footer_write);
    try self.verifyCurrent(self.current_bytes);
    self.expected_phase = .footer_sync;
    self.state = .append_active;
}

fn syncFooter(
    context: *anyopaque,
    generation: u64,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .append_active or
        self.expected_phase != .footer_sync)
        return Error.InvalidIoOrder;
    self.state = .poisoned;
    self.file.sync() catch return Error.StorageIo;
    self.file_sync_count = std.math.add(
        u64,
        self.file_sync_count,
        1,
    ) catch return Error.ArithmeticOverflow;
    try self.observe(.footer_sync);
    try self.verifyCurrent(self.current_bytes);
    self.expected_phase = .body_write;
    self.state = .ready;
}

fn validateRepair(
    context: *anyopaque,
    generation: u64,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .repair_ready or
        self.expected_phase != .repair_truncate or
        self.repair_generation != generation)
        return Error.InvalidCapability;
    try self.verifyCurrent(self.repair_expected_bytes);
}

fn repairTruncate(
    context: *anyopaque,
    generation: u64,
    snapshot_sha256: Digest,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .repair_ready or
        self.expected_phase != .repair_truncate or
        self.repair_generation != generation or
        self.current_bytes != self.repair_expected_bytes or
        self.repair_target_bytes > self.repair_expected_bytes or
        !std.mem.eql(
            u8,
            &self.repair_snapshot_sha256,
            &snapshot_sha256,
        ))
        return Error.InvalidCapability;
    try self.verifyCurrent(self.repair_expected_bytes);
    self.state = .poisoned;
    self.file.setEndPos(self.repair_target_bytes) catch
        return Error.StorageIo;
    self.current_bytes = self.repair_target_bytes;
    try self.observe(.repair_truncate);
    try self.verifyCurrent(self.current_bytes);
    self.expected_phase = .repair_sync;
    self.state = .repair_active;
}

fn repairSync(
    context: *anyopaque,
    generation: u64,
) sweep_writer.Error!void {
    const self: *FileLeaseV1 = @ptrCast(@alignCast(context));
    try self.validateGeneration(generation);
    if (self.state != .repair_active or
        self.expected_phase != .repair_sync)
        return Error.InvalidIoOrder;
    self.state = .poisoned;
    self.file.sync() catch return Error.StorageIo;
    self.file_sync_count = std.math.add(
        u64,
        self.file_sync_count,
        1,
    ) catch return Error.ArithmeticOverflow;
    try self.observe(.repair_sync);
    try self.verifyCurrent(self.current_bytes);
    self.expected_phase = .body_write;
    self.state = .repair_complete;
}

const OpenKind = enum {
    create,
    existing,
};

fn openLockedFile(
    directory: std.fs.Dir,
    name: []const u8,
    kind: OpenKind,
    lock_nonblocking: bool,
) !std.fs.File {
    if (comptime !platformSupported()) return Error.UnsupportedPlatform;
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW"))
        return Error.UnsupportedPlatform;
    var flags: std.posix.O = .{ .ACCMODE = .RDWR };
    if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
    if (@hasField(std.posix.O, "NOFOLLOW")) flags.NOFOLLOW = true;
    if (kind == .create) {
        flags.CREAT = true;
        flags.EXCL = true;
    }
    const lock_at_open = @hasField(std.posix.O, "EXLOCK");
    if (lock_at_open) {
        flags.EXLOCK = true;
        flags.NONBLOCK = lock_nonblocking;
    }
    const fd = try std.posix.openat(
        directory.fd,
        name,
        flags,
        if (kind == .create) 0o600 else 0,
    );
    errdefer std.posix.close(fd);
    if (!lock_at_open) {
        const nonblocking: i32 = if (lock_nonblocking) std.posix.LOCK.NB else 0;
        try std.posix.flock(fd, std.posix.LOCK.EX | nonblocking);
    }
    if (lock_at_open and lock_nonblocking) {
        var file_flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
        file_flags &= ~@as(
            usize,
            1 << @bitOffsetOf(std.posix.O, "NONBLOCK"),
        );
        _ = try std.posix.fcntl(fd, std.posix.F.SETFL, file_flags);
    }
    return .{ .handle = fd };
}

const InspectedFile = struct {
    identity: FileIdentityV1,
    size: usize,
};

fn inspectInitial(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    require_private_mode: bool,
) !InspectedFile {
    const file_stat = try std.posix.fstat(file.handle);
    const entry_stat = try std.posix.fstatat(
        directory.fd,
        name,
        std.posix.AT.SYMLINK_NOFOLLOW,
    );
    const file_view = try inspectStat(file_stat, require_private_mode);
    const entry_view = try inspectStat(entry_stat, require_private_mode);
    if (!std.meta.eql(file_view, entry_view))
        return Error.StorageIdentityChanged;
    return file_view;
}

fn inspectStat(
    stat: std.posix.Stat,
    require_private_mode: bool,
) Error!InspectedFile {
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG)
        return Error.InvalidStorage;
    if (stat.nlink != 1) return Error.MultipleLinks;
    if (require_private_mode and (stat.mode & 0o077) != 0)
        return Error.UnsafePermissions;
    const device = std.math.cast(u64, stat.dev) orelse
        return Error.InvalidStorage;
    const inode = std.math.cast(u64, stat.ino) orelse
        return Error.InvalidStorage;
    const size = std.math.cast(usize, stat.size) orelse
        return Error.CapacityExceeded;
    return .{
        .identity = .{ .device = device, .inode = inode },
        .size = size,
    };
}

fn inspectForCapability(
    stat: std.posix.Stat,
    require_private_mode: bool,
) ?InspectedFile {
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG or
        stat.nlink != 1 or
        (require_private_mode and (stat.mode & 0o077) != 0))
        return null;
    const device = std.math.cast(u64, stat.dev) orelse return null;
    const inode = std.math.cast(u64, stat.ino) orelse return null;
    const size = std.math.cast(usize, stat.size) orelse return null;
    return .{
        .identity = .{ .device = device, .inode = inode },
        .size = size,
    };
}

fn validateAcquire(
    name: []const u8,
    options: AcquireOptionsV1,
) Error!void {
    if (name.len == 0 or name.len > max_name_bytes or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null)
        return Error.InvalidName;
    if (options.storage_epoch == 0 or
        options.max_bytes < record.encoded_bytes)
        return Error.InvalidCapability;
}

fn reserveLeaseGeneration() Error!u64 {
    var current = next_lease_generation.load(.monotonic);
    while (true) {
        if (current == 0 or current == std.math.maxInt(u64))
            return Error.ArithmeticOverflow;
        if (next_lease_generation.cmpxchgWeak(
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

fn syncDirectory(directory: std.fs.Dir) !void {
    if (!platformSupported()) return Error.UnsupportedPlatform;
    try std.posix.fsync(directory.fd);
}

fn platformSupported() bool {
    return switch (builtin.os.tag) {
        .linux,
        .macos,
        .ios,
        .freebsd,
        .netbsd,
        .dragonfly,
        .openbsd,
        .solaris,
        .illumos,
        => true,
        else => false,
    };
}

fn testDigest(byte: u8) Digest {
    return [_]u8{byte} ** @sizeOf(Digest);
}

fn testInput(commit_challenge: u8, record_challenge: u8) record.InputV1 {
    const commit_grant: sweep.CommitGrantV1 = .{
        .authority_epoch = 11,
        .tenant_scope_sha256 = testDigest(0x61),
        .bundle_sha256 = testDigest(0x62),
        .store_grant_sha256 = testDigest(0x63),
        .sweep_grant_sha256 = testDigest(0x64),
        .prepare_sha256 = testDigest(0x65),
        .expected_snapshot_sha256 = testDigest(0x66),
        .collection_plan_sha256 = testDigest(0x67),
        .max_freed_entries = 2,
        .max_freed_bytes = 128,
        .challenge_sha256 = testDigest(commit_challenge),
    };
    const commit_grant_sha256 = sweep.commitGrantRootV1(commit_grant) catch
        unreachable;
    var store_receipt: object_store.RetiredCommitReceiptV1 = .{
        .authorization_sha256 = commit_grant_sha256,
        .targets_sha256 = testDigest(0x68),
        .snapshot_before_sha256 = commit_grant.expected_snapshot_sha256,
        .snapshot_after_sha256 = testDigest(0x69),
        .accounting_before = .{
            .entry_count = 8,
            .live_entries = 6,
            .quarantined_entries = 1,
            .retired_entries = 1,
            .payload_bytes = 255,
            .logical_index_bytes = 1024,
            .reference_count = 8,
            .active_leases = 1,
            .repair_count = 0,
        },
        .accounting_after = .{
            .entry_count = 7,
            .live_entries = 6,
            .quarantined_entries = 1,
            .retired_entries = 0,
            .payload_bytes = 216,
            .logical_index_bytes = 896,
            .reference_count = 8,
            .active_leases = 1,
            .repair_count = 0,
        },
        .freed_entries = 1,
        .freed_payload_bytes = 39,
        .freed_index_bytes = object_store.logical_index_entry_bytes,
        .freed_repair_count = 0,
        .allocator_deallocation_calls = 1,
        .commit_sha256 = capsule.zero_digest,
    };
    store_receipt.commit_sha256 =
        object_store.retiredCommitReceiptRootV1(store_receipt);
    var commit_receipt: sweep.CommitReceiptV1 = .{
        .commit_grant_sha256 = commit_grant_sha256,
        .sweep_grant_sha256 = commit_grant.sweep_grant_sha256,
        .prepare_sha256 = commit_grant.prepare_sha256,
        .collection_plan_sha256 = commit_grant.collection_plan_sha256,
        .targets_sha256 = store_receipt.targets_sha256,
        .snapshot_before_sha256 = store_receipt.snapshot_before_sha256,
        .snapshot_after_sha256 = store_receipt.snapshot_after_sha256,
        .store_commit_sha256 = store_receipt.commit_sha256,
        .freed_entries = store_receipt.freed_entries,
        .freed_payload_bytes = store_receipt.freed_payload_bytes,
        .freed_index_bytes = store_receipt.freed_index_bytes,
        .freed_repair_count = store_receipt.freed_repair_count,
        .allocator_deallocation_calls = store_receipt.allocator_deallocation_calls,
        .commit_sha256 = capsule.zero_digest,
    };
    commit_receipt.commit_sha256 = sweep.commitRootV1(commit_receipt);
    return .{
        .record_epoch = 0x5357_4545_5000_0001,
        .sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
        .record_challenge_sha256 = testDigest(record_challenge),
        .commit_grant = commit_grant,
        .commit_receipt = commit_receipt,
        .store_receipt = store_receipt,
    };
}

fn testRecords() !struct {
    first: [record.encoded_bytes]u8,
    second: [record.encoded_bytes]u8,
    first_root: Digest,
} {
    var first: [record.encoded_bytes]u8 = undefined;
    const first_input = testInput(0x6A, 0x6B);
    _ = try record.encodeV1(first_input, &first);
    const first_root = (try record.decodeV1(&first)).record_sha256;
    var second_input = testInput(0x7A, 0x7B);
    second_input.sequence = 2;
    second_input.previous_record_sha256 = first_root;
    var second: [record.encoded_bytes]u8 = undefined;
    _ = try record.encodeV1(second_input, &second);
    return .{ .first = first, .second = second, .first_root = first_root };
}

fn testAnchor() record.RecoveryAnchorV1 {
    return .{
        .record_epoch = 0x5357_4545_5000_0001,
        .next_sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
    };
}

test "directory lease creates locks appends and reopens exact records" {
    if (comptime !platformSupported()) return error.SkipZigTest;
    const fixture = try testRecords();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var initial_storage: [1]u8 = undefined;
    var lease = try FileLeaseV1.create(
        temporary.dir,
        "sweep.records",
        .{
            .storage_epoch = 41,
            .max_bytes = record.encoded_bytes * 3,
        },
        &initial_storage,
    );
    defer lease.close();
    try std.testing.expectEqual(DirectorySyncStatusV1.synced, lease.directory_sync_status);
    try std.testing.expectEqual(@as(u64, 1), lease.file_sync_count);

    var locked_storage: [record.encoded_bytes * 3]u8 = undefined;
    try std.testing.expectError(
        error.WouldBlock,
        FileLeaseV1.open(
            temporary.dir,
            "sweep.records",
            .{
                .storage_epoch = 41,
                .max_bytes = record.encoded_bytes * 3,
            },
            &locked_storage,
        ),
    );

    var stream_writer = try sweep_writer.WriterV1.openClean(
        lease.stream(),
        testAnchor(),
        try lease.appendCapability(),
    );
    _ = try stream_writer.appendRecord(&fixture.first);
    _ = try stream_writer.appendRecord(&fixture.second);
    try std.testing.expectEqual(record.encoded_bytes * 2, lease.current_bytes);
    try std.testing.expectEqual(@as(u64, 5), lease.file_sync_count);
    var actual: [record.encoded_bytes * 2]u8 = undefined;
    try std.testing.expectEqual(
        actual.len,
        try lease.file.preadAll(&actual, 0),
    );
    try std.testing.expectEqualSlices(u8, &fixture.first, actual[0..record.encoded_bytes]);
    try std.testing.expectEqualSlices(u8, &fixture.second, actual[record.encoded_bytes..]);
    const stale = stream_writer.authority;
    lease.close();

    var reopened_storage: [record.encoded_bytes * 3]u8 = undefined;
    lease = try FileLeaseV1.open(
        temporary.dir,
        "sweep.records",
        .{
            .storage_epoch = 41,
            .max_bytes = record.encoded_bytes * 3,
        },
        &reopened_storage,
    );
    try std.testing.expectEqualSlices(u8, &actual, lease.stream());
    try std.testing.expectError(
        Error.InvalidCapability,
        sweep_writer.WriterV1.openClean(lease.stream(), testAnchor(), stale),
    );
    const reopened_writer = try sweep_writer.WriterV1.openClean(
        lease.stream(),
        testAnchor(),
        try lease.appendCapability(),
    );
    try std.testing.expectEqual(@as(u64, 3), reopened_writer.next_sequence);
}

test "directory lease rejects unsafe names symlinks hard links and permissions" {
    if (comptime !platformSupported()) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var storage: [record.encoded_bytes]u8 = undefined;
    for ([_][]const u8{ "", ".", "..", "../escape", "a/b", "a\\b" }) |name| {
        try std.testing.expectError(
            Error.InvalidName,
            FileLeaseV1.create(
                temporary.dir,
                name,
                .{
                    .storage_epoch = 1,
                    .max_bytes = record.encoded_bytes,
                },
                &storage,
            ),
        );
    }

    {
        const target = try temporary.dir.createFile("target", .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        });
        target.close();
        try temporary.dir.symLink("target", "symlink", .{});
        try std.testing.expectError(
            error.SymLinkLoop,
            FileLeaseV1.open(
                temporary.dir,
                "symlink",
                .{
                    .storage_epoch = 2,
                    .max_bytes = record.encoded_bytes,
                },
                &storage,
            ),
        );
        try std.posix.linkat(
            temporary.dir.fd,
            "target",
            temporary.dir.fd,
            "hardlink",
            0,
        );
        try std.testing.expectError(
            Error.MultipleLinks,
            FileLeaseV1.open(
                temporary.dir,
                "target",
                .{
                    .storage_epoch = 2,
                    .max_bytes = record.encoded_bytes,
                },
                &storage,
            ),
        );
    }

    {
        const public_file = try temporary.dir.createFile("public", .{
            .read = true,
            .exclusive = true,
            .mode = 0o644,
        });
        public_file.close();
        try std.testing.expectError(
            Error.UnsafePermissions,
            FileLeaseV1.open(
                temporary.dir,
                "public",
                .{
                    .storage_epoch = 3,
                    .max_bytes = record.encoded_bytes,
                },
                &storage,
            ),
        );
    }
}

const InjectObserver = struct {
    phase: sweep_writer.IoPhaseV1,
    calls: usize = 0,

    fn after(
        context: *anyopaque,
        phase: sweep_writer.IoPhaseV1,
    ) sweep_writer.Error!void {
        const self: *InjectObserver = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (phase == self.phase) return Error.InjectedFault;
    }
};

test "every real file append phase poisons and reopens from exact evidence" {
    if (comptime !platformSupported()) return error.SkipZigTest;
    const fixture = try testRecords();
    for ([_]sweep_writer.IoPhaseV1{
        .body_write,
        .body_sync,
        .footer_write,
        .footer_sync,
    }) |phase| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var observer: InjectObserver = .{ .phase = phase };
        var empty_storage: [1]u8 = undefined;
        var lease = try FileLeaseV1.create(
            temporary.dir,
            "fault.records",
            .{
                .storage_epoch = 100 + @intFromEnum(phase),
                .max_bytes = record.encoded_bytes * 2,
                .observer = .{
                    .context = &observer,
                    .after_phase_fn = InjectObserver.after,
                },
            },
            &empty_storage,
        );
        var stream_writer = try sweep_writer.WriterV1.openClean(
            lease.stream(),
            testAnchor(),
            try lease.appendCapability(),
        );
        try std.testing.expectError(
            Error.InjectedFault,
            stream_writer.appendRecord(&fixture.first),
        );
        try std.testing.expectEqual(sweep_writer.WriterStateV1.poisoned, stream_writer.state);
        try std.testing.expectEqual(LeaseStateV1.poisoned, lease.state);
        lease.close();

        var reopened_storage: [record.encoded_bytes * 2]u8 = undefined;
        var reopened = try FileLeaseV1.open(
            temporary.dir,
            "fault.records",
            .{
                .storage_epoch = 100 + @intFromEnum(phase),
                .max_bytes = record.encoded_bytes * 2,
            },
            &reopened_storage,
        );
        defer reopened.close();
        const plan = try sweep_writer.planRecoveryV1(
            reopened.stream(),
            testAnchor(),
            reopened.snapshot,
        );
        switch (phase) {
            .body_write, .body_sync => {
                try std.testing.expectEqual(
                    sweep_writer.RecoveryActionV1.repair_incomplete_tail,
                    plan.action,
                );
            },
            .footer_write, .footer_sync => {
                try std.testing.expectEqual(
                    sweep_writer.RecoveryActionV1.open_clean,
                    plan.action,
                );
            },
            else => unreachable,
        }
    }
}

test "real incomplete tail repair is explicit durable and requires reacquire" {
    if (comptime !platformSupported()) return error.SkipZigTest;
    const fixture = try testRecords();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const raw = try temporary.dir.createFile("repair.records", .{
        .read = true,
        .exclusive = true,
        .mode = 0o600,
    });
    try raw.writeAll(&fixture.first);
    try raw.writeAll(fixture.second[0 .. record.body_bytes + 7]);
    try raw.sync();
    raw.close();

    var storage: [record.encoded_bytes * 2]u8 = undefined;
    var lease = try FileLeaseV1.open(
        temporary.dir,
        "repair.records",
        .{
            .storage_epoch = 501,
            .max_bytes = storage.len,
        },
        &storage,
    );
    const stale_append = try lease.appendCapability();
    try std.testing.expectError(
        Error.RepairRequired,
        sweep_writer.WriterV1.openClean(
            lease.stream(),
            testAnchor(),
            stale_append,
        ),
    );
    var repairer = try sweep_writer.RepairerV1.init(
        lease.stream(),
        testAnchor(),
        try lease.prepareRepair(testAnchor()),
    );
    const receipt = try repairer.apply();
    try std.testing.expectEqual(record.encoded_bytes, receipt.committed_bytes);
    try std.testing.expectEqual(record.body_bytes + 7, receipt.discarded_tail_bytes);
    try std.testing.expectEqual(LeaseStateV1.repair_complete, lease.state);
    try std.testing.expectError(
        Error.InvalidCapability,
        sweep_writer.WriterV1.openClean(lease.stream(), testAnchor(), stale_append),
    );
    lease.close();

    var reopened_storage: [record.encoded_bytes * 2]u8 = undefined;
    var reopened = try FileLeaseV1.open(
        temporary.dir,
        "repair.records",
        .{
            .storage_epoch = 501,
            .max_bytes = reopened_storage.len,
        },
        &reopened_storage,
    );
    defer reopened.close();
    var stream_writer = try sweep_writer.WriterV1.openClean(
        reopened.stream(),
        testAnchor(),
        try reopened.appendCapability(),
    );
    _ = try stream_writer.appendRecord(&fixture.second);
    var actual: [record.encoded_bytes * 2]u8 = undefined;
    try std.testing.expectEqual(actual.len, try reopened.file.preadAll(&actual, 0));
    try std.testing.expectEqualSlices(u8, &fixture.first, actual[0..record.encoded_bytes]);
    try std.testing.expectEqualSlices(u8, &fixture.second, actual[record.encoded_bytes..]);
}

test "namespace replacement poisons before append reaches replacement file" {
    if (comptime !platformSupported()) return error.SkipZigTest;
    const fixture = try testRecords();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var observer: ReplaceObserver = .{ .directory = temporary.dir };
    var empty: [1]u8 = undefined;
    var lease = try FileLeaseV1.create(
        temporary.dir,
        "stable.records",
        .{
            .storage_epoch = 601,
            .max_bytes = record.encoded_bytes,
            .observer = .{
                .context = &observer,
                .after_phase_fn = ReplaceObserver.after,
            },
        },
        &empty,
    );
    defer lease.close();
    var publication = try sweep_writer.WriterV1.openClean(
        lease.stream(),
        testAnchor(),
        try lease.appendCapability(),
    );
    try std.testing.expectError(
        Error.StorageIdentityChanged,
        publication.appendRecord(&fixture.first),
    );
    try std.testing.expect(observer.replaced);
    try std.testing.expectEqual(LeaseStateV1.poisoned, lease.state);
    try std.testing.expectEqual(sweep_writer.WriterStateV1.poisoned, publication.state);
    try std.testing.expectEqual(@as(u64, 0), (try temporary.dir.statFile("stable.records")).size);
    try std.testing.expectEqual(
        @as(u64, record.body_bytes),
        (try temporary.dir.statFile("moved.records")).size,
    );
}

const ReplaceObserver = struct {
    directory: std.fs.Dir,
    replaced: bool = false,

    fn after(
        context: *anyopaque,
        phase: sweep_writer.IoPhaseV1,
    ) sweep_writer.Error!void {
        const self: *ReplaceObserver = @ptrCast(@alignCast(context));
        if (phase != .body_write or self.replaced) return;
        self.directory.rename(
            "stable.records",
            "moved.records",
        ) catch return Error.StorageIo;
        const replacement = self.directory.createFile(
            "stable.records",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        ) catch return Error.StorageIo;
        replacement.close();
        self.replaced = true;
    }
};
