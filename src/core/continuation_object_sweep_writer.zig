//! Least-authority publication state machine for continuation sweep records.
//!
//! A caller first acquires an exclusive storage lease outside this module and
//! supplies a snapshot-bound capability. Append authority can only write and
//! sync a record body followed by its commit footer; it cannot read, truncate,
//! rename, or delete storage. Repair authority is a separate capability that
//! can only truncate one explicitly classified incomplete tail to the verified
//! committed prefix and sync that length. Any I/O error poisons the local state
//! machine, forcing a crash/reopen classification before reuse.
//!
//! `DeterministicStorageV1` is an allocation-free reference backend. It models
//! exclusive leases, volatile writes, sync lower bounds, partial writes,
//! uncertain operation outcomes, and crash persistence at every byte boundary.
//! It is a conformance model, not a production filesystem adapter.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");
const object_store = @import("continuation_object_store.zig");
const sweep = @import("continuation_object_sweep.zig");
const record = @import("continuation_object_sweep_record.zig");

pub const Digest = record.Digest;
pub const abi_version: u64 = 0x4743_5357_0000_0001;
const snapshot_domain = "glacier-continuation-sweep-writer-snapshot-v1\x00";

pub const Error = record.Error || error{
    ArithmeticOverflow,
    Busy,
    CapacityExceeded,
    CorruptRecovery,
    InjectedFault,
    InvalidCapability,
    InvalidCrashPoint,
    InvalidFault,
    InvalidIoOrder,
    InvalidRepairState,
    InvalidStorage,
    InvalidWriterState,
    RepairNotRequired,
    RepairRequired,
    SequenceExhausted,
    SnapshotMismatch,
};

pub const StorageSnapshotV1 = struct {
    abi: u64 = abi_version,
    storage_epoch: u64,
    lease_generation: u64,
    observed_bytes: usize,
    max_bytes: usize,
    stream_sha256: Digest,
    snapshot_sha256: Digest,
};

pub const RecoveryActionV1 = enum(u8) {
    open_clean,
    repair_incomplete_tail,
    reject_corrupt,
};

pub const RecoveryPlanV1 = struct {
    action: RecoveryActionV1,
    snapshot_sha256: Digest,
    classification: record.RecoveryClassificationV1,
    truncate_to_bytes: usize,
    discard_tail_bytes: usize,
};

pub const IoPhaseV1 = enum(u8) {
    body_write,
    body_sync,
    footer_write,
    footer_sync,
    repair_truncate,
    repair_sync,
};

pub const FaultTimingV1 = enum(u8) {
    before,
    after,
};

/// `write_prefix` is valid only for an `after` fault on a write operation. A
/// null prefix means the complete operation took effect before the error.
pub const FaultV1 = struct {
    call_index: u64,
    timing: FaultTimingV1,
    write_prefix: ?usize = null,
};

pub const AppendCapabilityV1 = struct {
    context: *anyopaque,
    snapshot: StorageSnapshotV1,
    validate_fn: *const fn (*anyopaque, u64, Digest, usize) Error!void,
    append_body_fn: *const fn (*anyopaque, u64, []const u8) Error!void,
    sync_body_fn: *const fn (*anyopaque, u64) Error!void,
    append_footer_fn: *const fn (*anyopaque, u64, []const u8) Error!void,
    sync_footer_fn: *const fn (*anyopaque, u64) Error!void,

    fn validate(
        self: AppendCapabilityV1,
        expected_current_bytes: usize,
    ) Error!void {
        try self.validate_fn(
            self.context,
            self.snapshot.lease_generation,
            self.snapshot.snapshot_sha256,
            expected_current_bytes,
        );
    }

    fn appendBody(self: AppendCapabilityV1, bytes: []const u8) Error!void {
        try self.append_body_fn(
            self.context,
            self.snapshot.lease_generation,
            bytes,
        );
    }

    fn syncBody(self: AppendCapabilityV1) Error!void {
        try self.sync_body_fn(self.context, self.snapshot.lease_generation);
    }

    fn appendFooter(self: AppendCapabilityV1, bytes: []const u8) Error!void {
        try self.append_footer_fn(
            self.context,
            self.snapshot.lease_generation,
            bytes,
        );
    }

    fn syncFooter(self: AppendCapabilityV1) Error!void {
        try self.sync_footer_fn(self.context, self.snapshot.lease_generation);
    }
};

pub const RepairCapabilityV1 = struct {
    context: *anyopaque,
    snapshot: StorageSnapshotV1,
    expected_current_bytes: usize,
    target_bytes: usize,
    discarded_tail_bytes: usize,
    final_record_sha256: Digest,
    validate_fn: *const fn (*anyopaque, u64) Error!void,
    truncate_fn: *const fn (*anyopaque, u64, Digest) Error!void,
    sync_fn: *const fn (*anyopaque, u64) Error!void,

    fn validate(self: RepairCapabilityV1) Error!void {
        try self.validate_fn(self.context, self.snapshot.lease_generation);
    }

    fn truncate(self: RepairCapabilityV1) Error!void {
        try self.truncate_fn(
            self.context,
            self.snapshot.lease_generation,
            self.snapshot.snapshot_sha256,
        );
    }

    fn sync(self: RepairCapabilityV1) Error!void {
        try self.sync_fn(self.context, self.snapshot.lease_generation);
    }
};

pub const WriterStateV1 = enum(u8) {
    ready,
    poisoned,
    closed,
};

pub const AppendReceiptV1 = struct {
    sequence: u64,
    committed_bytes: usize,
    record_sha256: Digest,
    next_sequence_exhausted: bool,
    body_sync_exercised: bool,
    footer_sync_exercised: bool,
};

/// Process-local writer over one already locked and snapshot-bound stream.
pub const WriterV1 = struct {
    authority: AppendCapabilityV1,
    record_epoch: u64,
    next_sequence: u64,
    previous_record_sha256: Digest,
    committed_bytes: usize,
    sequence_exhausted: bool,
    state: WriterStateV1 = .ready,

    pub fn openClean(
        stream: []const u8,
        anchor: record.RecoveryAnchorV1,
        authority: AppendCapabilityV1,
    ) Error!WriterV1 {
        try authority.validate(authority.snapshot.observed_bytes);
        const recovery = try planRecoveryV1(stream, anchor, authority.snapshot);
        switch (recovery.action) {
            .open_clean => {},
            .repair_incomplete_tail => return Error.RepairRequired,
            .reject_corrupt => return Error.CorruptRecovery,
        }
        const classification = recovery.classification;
        const exhausted = classification.committed_records != 0 and
            classification.last_sequence == std.math.maxInt(u64);
        const next_sequence = if (classification.committed_records == 0)
            anchor.next_sequence
        else if (exhausted)
            classification.last_sequence
        else
            classification.last_sequence + 1;
        return .{
            .authority = authority,
            .record_epoch = anchor.record_epoch,
            .next_sequence = next_sequence,
            .previous_record_sha256 = classification.final_record_sha256,
            .committed_bytes = classification.committed_bytes,
            .sequence_exhausted = exhausted,
        };
    }

    pub fn appendRecord(
        self: *WriterV1,
        encoded: []const u8,
    ) Error!AppendReceiptV1 {
        if (self.state != .ready) return Error.InvalidWriterState;
        try self.authority.validate(self.committed_bytes);
        if (self.sequence_exhausted) return Error.SequenceExhausted;
        const decoded = try record.decodeV1(encoded);
        if (decoded.input.record_epoch != self.record_epoch or
            decoded.input.sequence != self.next_sequence or
            !std.mem.eql(
                u8,
                &decoded.input.previous_record_sha256,
                &self.previous_record_sha256,
            )) return Error.RecordExpectationMismatch;
        if (encoded.len > self.authority.snapshot.max_bytes -| self.committed_bytes)
            return Error.CapacityExceeded;
        const append_plan = try record.appendPlanV1(encoded);

        // Every error after this boundary has an uncertain storage outcome.
        self.state = .poisoned;
        try self.authority.appendBody(append_plan.body);
        try self.authority.syncBody();
        try self.authority.appendFooter(append_plan.commit_footer);
        try self.authority.syncFooter();

        self.committed_bytes = std.math.add(
            usize,
            self.committed_bytes,
            encoded.len,
        ) catch return Error.ArithmeticOverflow;
        self.previous_record_sha256 = decoded.record_sha256;
        self.sequence_exhausted = self.next_sequence == std.math.maxInt(u64);
        if (!self.sequence_exhausted) self.next_sequence += 1;
        self.state = .ready;
        return .{
            .sequence = decoded.input.sequence,
            .committed_bytes = self.committed_bytes,
            .record_sha256 = decoded.record_sha256,
            .next_sequence_exhausted = self.sequence_exhausted,
            .body_sync_exercised = true,
            .footer_sync_exercised = true,
        };
    }

    pub fn close(self: *WriterV1) void {
        self.state = .closed;
    }
};

pub const RepairStateV1 = enum(u8) {
    ready,
    poisoned,
    complete,
    closed,
};

pub const RepairReceiptV1 = struct {
    original_bytes: usize,
    committed_bytes: usize,
    discarded_tail_bytes: usize,
    final_record_sha256: Digest,
    truncate_exercised: bool,
    sync_exercised: bool,
};

/// One-shot repair state machine. Success still requires releasing the old
/// lease, reacquiring storage, and reopening against a fresh snapshot.
pub const RepairerV1 = struct {
    authority: RepairCapabilityV1,
    plan: RecoveryPlanV1,
    state: RepairStateV1 = .ready,

    pub fn init(
        stream: []const u8,
        anchor: record.RecoveryAnchorV1,
        authority: RepairCapabilityV1,
    ) Error!RepairerV1 {
        try authority.validate();
        const plan = try planRecoveryV1(stream, anchor, authority.snapshot);
        switch (plan.action) {
            .open_clean => return Error.RepairNotRequired,
            .repair_incomplete_tail => {},
            .reject_corrupt => return Error.CorruptRecovery,
        }
        if (authority.expected_current_bytes !=
            authority.snapshot.observed_bytes or
            authority.target_bytes != plan.truncate_to_bytes or
            authority.discarded_tail_bytes != plan.discard_tail_bytes or
            !std.mem.eql(
                u8,
                &authority.final_record_sha256,
                &plan.classification.final_record_sha256,
            )) return Error.InvalidCapability;
        return .{ .authority = authority, .plan = plan };
    }

    pub fn apply(self: *RepairerV1) Error!RepairReceiptV1 {
        if (self.state != .ready) return Error.InvalidRepairState;
        try self.authority.validate();
        self.state = .poisoned;
        try self.authority.truncate();
        try self.authority.sync();
        self.state = .complete;
        return .{
            .original_bytes = self.authority.snapshot.observed_bytes,
            .committed_bytes = self.plan.truncate_to_bytes,
            .discarded_tail_bytes = self.plan.discard_tail_bytes,
            .final_record_sha256 = self.plan.classification.final_record_sha256,
            .truncate_exercised = true,
            .sync_exercised = true,
        };
    }

    pub fn close(self: *RepairerV1) void {
        self.state = .closed;
    }
};

pub fn makeStorageSnapshotV1(
    storage_epoch: u64,
    lease_generation: u64,
    stream: []const u8,
    max_bytes: usize,
) Error!StorageSnapshotV1 {
    if (storage_epoch == 0 or lease_generation == 0 or
        stream.len > max_bytes)
        return Error.InvalidCapability;
    var stream_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(stream, &stream_sha256, .{});
    const snapshot_sha256 = snapshotRootV1(
        storage_epoch,
        lease_generation,
        stream.len,
        max_bytes,
        stream_sha256,
    );
    return .{
        .storage_epoch = storage_epoch,
        .lease_generation = lease_generation,
        .observed_bytes = stream.len,
        .max_bytes = max_bytes,
        .stream_sha256 = stream_sha256,
        .snapshot_sha256 = snapshot_sha256,
    };
}

pub fn validateStorageSnapshotV1(
    snapshot: StorageSnapshotV1,
    stream: []const u8,
) Error!void {
    if (snapshot.abi != abi_version or snapshot.storage_epoch == 0 or
        snapshot.lease_generation == 0 or
        snapshot.observed_bytes != stream.len or
        snapshot.observed_bytes > snapshot.max_bytes)
        return Error.SnapshotMismatch;
    var stream_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(stream, &stream_sha256, .{});
    if (!std.mem.eql(u8, &stream_sha256, &snapshot.stream_sha256))
        return Error.SnapshotMismatch;
    const expected = snapshotRootV1(
        snapshot.storage_epoch,
        snapshot.lease_generation,
        snapshot.observed_bytes,
        snapshot.max_bytes,
        snapshot.stream_sha256,
    );
    if (!std.mem.eql(u8, &expected, &snapshot.snapshot_sha256))
        return Error.SnapshotMismatch;
}

pub fn planRecoveryV1(
    stream: []const u8,
    anchor: record.RecoveryAnchorV1,
    snapshot: StorageSnapshotV1,
) Error!RecoveryPlanV1 {
    try validateStorageSnapshotV1(snapshot, stream);
    const classification = try record.classifyRecoveryV1(stream, anchor);
    const action: RecoveryActionV1 = switch (classification.status) {
        .clean => .open_clean,
        .short_body_tail,
        .body_without_footer,
        .partial_footer_tail,
        => .repair_incomplete_tail,
        .corrupt_record => .reject_corrupt,
    };
    return .{
        .action = action,
        .snapshot_sha256 = snapshot.snapshot_sha256,
        .classification = classification,
        .truncate_to_bytes = classification.committed_bytes,
        .discard_tail_bytes = classification.tail_bytes,
    };
}

fn snapshotRootV1(
    storage_epoch: u64,
    lease_generation: u64,
    observed_bytes: usize,
    max_bytes: usize,
    stream_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(snapshot_domain);
    hashU64(&hash, abi_version);
    hashU64(&hash, storage_epoch);
    hashU64(&hash, lease_generation);
    hashU64(&hash, @intCast(observed_bytes));
    hashU64(&hash, @intCast(max_bytes));
    hash.update(&stream_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

/// Allocation-free storage model for adapter conformance and crash campaigns.
pub const DeterministicStorageV1 = struct {
    backing: []u8,
    length: usize,
    synced_length: usize,
    storage_epoch: u64,
    next_generation: u64 = 1,
    active_generation: u64 = 0,
    expected_phase: IoPhaseV1 = .body_write,
    fault: ?FaultV1 = null,
    call_index: u64 = 0,
    operation_count: u64 = 0,
    trace_storage: [64]IoPhaseV1 = undefined,
    trace_length: usize = 0,
    trace_truncated: bool = false,
    append_generation: u64 = 0,
    append_snapshot_sha256: Digest = capsule.zero_digest,
    repair_generation: u64 = 0,
    repair_snapshot_sha256: Digest = capsule.zero_digest,
    repair_expected_bytes: usize = 0,
    repair_target_bytes: usize = 0,

    pub fn init(
        backing: []u8,
        initial: []const u8,
        storage_epoch: u64,
    ) Error!DeterministicStorageV1 {
        if (storage_epoch == 0 or initial.len > backing.len or
            rangesOverlap(backing, initial))
            return Error.InvalidStorage;
        std.mem.copyForwards(u8, backing[0..initial.len], initial);
        return .{
            .backing = backing,
            .length = initial.len,
            .synced_length = initial.len,
            .storage_epoch = storage_epoch,
        };
    }

    pub fn bytes(self: *const DeterministicStorageV1) []const u8 {
        return self.backing[0..self.length];
    }

    pub fn trace(self: *const DeterministicStorageV1) []const IoPhaseV1 {
        return self.trace_storage[0..self.trace_length];
    }

    pub fn setFault(self: *DeterministicStorageV1, fault: ?FaultV1) void {
        self.fault = fault;
        self.call_index = 0;
        self.operation_count = 0;
        self.trace_length = 0;
        self.trace_truncated = false;
    }

    pub fn acquire(self: *DeterministicStorageV1) Error!DeterministicLeaseV1 {
        if (self.active_generation != 0) return Error.Busy;
        if (self.next_generation == 0) return Error.ArithmeticOverflow;
        const generation = self.next_generation;
        self.next_generation = std.math.add(
            u64,
            self.next_generation,
            1,
        ) catch 0;
        self.active_generation = generation;
        self.expected_phase = .body_write;
        self.fault = null;
        self.call_index = 0;
        self.operation_count = 0;
        self.trace_length = 0;
        self.trace_truncated = false;
        self.clearAppendAuthorization();
        self.clearRepairAuthorization();
        const snapshot = try makeStorageSnapshotV1(
            self.storage_epoch,
            generation,
            self.bytes(),
            self.backing.len,
        );
        return .{
            .storage = self,
            .generation = generation,
            .snapshot = snapshot,
        };
    }

    /// Simulates process loss. Any prefix between the last sync length and the
    /// current volatile length may survive, including the reverse interval
    /// created by an unsynced truncate.
    pub fn crashPersist(
        self: *DeterministicStorageV1,
        persisted_bytes: usize,
    ) Error!void {
        const lower = @min(self.length, self.synced_length);
        const upper = @max(self.length, self.synced_length);
        if (persisted_bytes < lower or persisted_bytes > upper)
            return Error.InvalidCrashPoint;
        self.length = persisted_bytes;
        self.synced_length = persisted_bytes;
        self.active_generation = 0;
        self.expected_phase = .body_write;
        self.fault = null;
        self.call_index = 0;
        self.clearAppendAuthorization();
        self.clearRepairAuthorization();
    }

    pub fn crashBounds(self: *const DeterministicStorageV1) struct {
        lower: usize,
        upper: usize,
    } {
        return .{
            .lower = @min(self.length, self.synced_length),
            .upper = @max(self.length, self.synced_length),
        };
    }

    fn validateLease(context: *anyopaque, generation: u64) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        if (generation == 0 or self.active_generation != generation)
            return Error.InvalidCapability;
    }

    fn validateAppend(
        context: *anyopaque,
        generation: u64,
        snapshot_sha256: Digest,
        expected_current_bytes: usize,
    ) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        try validateLease(self, generation);
        if (self.append_generation != generation or
            self.length != expected_current_bytes or
            !std.mem.eql(
                u8,
                &self.append_snapshot_sha256,
                &snapshot_sha256,
            )) return Error.InvalidCapability;
    }

    fn appendBody(
        context: *anyopaque,
        generation: u64,
        bytes_value: []const u8,
    ) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        if (bytes_value.len != record.body_bytes)
            return Error.InvalidIoOrder;
        try self.appendAtPhase(generation, .body_write, .body_sync, bytes_value);
    }

    fn syncBody(context: *anyopaque, generation: u64) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        try self.syncAtPhase(generation, .body_sync, .footer_write);
    }

    fn appendFooter(
        context: *anyopaque,
        generation: u64,
        bytes_value: []const u8,
    ) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        if (bytes_value.len != record.commit_footer_bytes)
            return Error.InvalidIoOrder;
        try self.appendAtPhase(
            generation,
            .footer_write,
            .footer_sync,
            bytes_value,
        );
    }

    fn syncFooter(context: *anyopaque, generation: u64) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        try self.syncAtPhase(generation, .footer_sync, .body_write);
    }

    fn repairTruncate(
        context: *anyopaque,
        generation: u64,
        snapshot_sha256: Digest,
    ) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        try self.validateOperation(generation, .repair_truncate);
        if (self.repair_generation != generation or
            !std.mem.eql(
                u8,
                &self.repair_snapshot_sha256,
                &snapshot_sha256,
            )) return Error.InvalidCapability;
        const after_fault = try self.beginOperation(.repair_truncate, false);
        if (self.length != self.repair_expected_bytes or
            self.repair_target_bytes > self.length)
            return Error.InvalidStorage;
        self.length = self.repair_target_bytes;
        self.expected_phase = .repair_sync;
        if (after_fault) return Error.InjectedFault;
    }

    fn repairSync(context: *anyopaque, generation: u64) Error!void {
        const self: *DeterministicStorageV1 = @ptrCast(@alignCast(context));
        try self.syncAtPhase(generation, .repair_sync, .body_write);
    }

    fn appendAtPhase(
        self: *DeterministicStorageV1,
        generation: u64,
        phase: IoPhaseV1,
        next_phase: IoPhaseV1,
        bytes_value: []const u8,
    ) Error!void {
        try self.validateOperation(generation, phase);
        const after_fault = try self.beginOperation(phase, true);
        var write_length = bytes_value.len;
        if (after_fault) {
            if (self.fault.?.write_prefix) |prefix| {
                if (prefix > bytes_value.len) return Error.InvalidFault;
                write_length = prefix;
            }
        }
        if (write_length > self.backing.len -| self.length)
            return Error.CapacityExceeded;
        std.mem.copyForwards(
            u8,
            self.backing[self.length .. self.length + write_length],
            bytes_value[0..write_length],
        );
        self.length += write_length;
        if (write_length == bytes_value.len) self.expected_phase = next_phase;
        if (after_fault) return Error.InjectedFault;
    }

    fn syncAtPhase(
        self: *DeterministicStorageV1,
        generation: u64,
        phase: IoPhaseV1,
        next_phase: IoPhaseV1,
    ) Error!void {
        try self.validateOperation(generation, phase);
        const after_fault = try self.beginOperation(phase, false);
        self.synced_length = self.length;
        self.expected_phase = next_phase;
        if (after_fault) return Error.InjectedFault;
    }

    fn validateOperation(
        self: *DeterministicStorageV1,
        generation: u64,
        phase: IoPhaseV1,
    ) Error!void {
        try validateLease(self, generation);
        if (self.expected_phase != phase) return Error.InvalidIoOrder;
    }

    fn beginOperation(
        self: *DeterministicStorageV1,
        phase: IoPhaseV1,
        is_write: bool,
    ) Error!bool {
        if (self.trace_length < self.trace_storage.len) {
            self.trace_storage[self.trace_length] = phase;
            self.trace_length += 1;
        } else {
            self.trace_truncated = true;
        }
        self.operation_count = std.math.add(
            u64,
            self.operation_count,
            1,
        ) catch return Error.ArithmeticOverflow;
        const current_call = self.call_index;
        self.call_index = std.math.add(u64, self.call_index, 1) catch
            return Error.ArithmeticOverflow;
        const fault = self.fault orelse return false;
        if (fault.call_index != current_call) return false;
        if (!is_write and fault.write_prefix != null) return Error.InvalidFault;
        if (fault.timing == .before) {
            if (fault.write_prefix != null) return Error.InvalidFault;
            return Error.InjectedFault;
        }
        return true;
    }

    fn clearRepairAuthorization(self: *DeterministicStorageV1) void {
        self.repair_generation = 0;
        self.repair_snapshot_sha256 = capsule.zero_digest;
        self.repair_expected_bytes = 0;
        self.repair_target_bytes = 0;
    }

    fn clearAppendAuthorization(self: *DeterministicStorageV1) void {
        self.append_generation = 0;
        self.append_snapshot_sha256 = capsule.zero_digest;
    }
};

pub const DeterministicLeaseV1 = struct {
    storage: *DeterministicStorageV1,
    generation: u64,
    snapshot: StorageSnapshotV1,

    pub fn appendCapability(
        self: DeterministicLeaseV1,
    ) Error!AppendCapabilityV1 {
        try DeterministicStorageV1.validateLease(self.storage, self.generation);
        if (self.storage.expected_phase != .body_write or
            self.storage.length != self.snapshot.observed_bytes)
            return Error.InvalidCapability;
        if (self.storage.append_generation != 0 and
            (self.storage.append_generation != self.generation or
                !std.mem.eql(
                    u8,
                    &self.storage.append_snapshot_sha256,
                    &self.snapshot.snapshot_sha256,
                ))) return Error.InvalidCapability;
        self.storage.append_generation = self.generation;
        self.storage.append_snapshot_sha256 = self.snapshot.snapshot_sha256;
        return .{
            .context = self.storage,
            .snapshot = self.snapshot,
            .validate_fn = DeterministicStorageV1.validateAppend,
            .append_body_fn = DeterministicStorageV1.appendBody,
            .sync_body_fn = DeterministicStorageV1.syncBody,
            .append_footer_fn = DeterministicStorageV1.appendFooter,
            .sync_footer_fn = DeterministicStorageV1.syncFooter,
        };
    }

    pub fn prepareRepair(
        self: DeterministicLeaseV1,
        stream: []const u8,
        anchor: record.RecoveryAnchorV1,
    ) Error!RepairCapabilityV1 {
        try DeterministicStorageV1.validateLease(self.storage, self.generation);
        if (self.storage.expected_phase != .body_write)
            return Error.InvalidIoOrder;
        const plan = try planRecoveryV1(stream, anchor, self.snapshot);
        switch (plan.action) {
            .open_clean => return Error.RepairNotRequired,
            .repair_incomplete_tail => {},
            .reject_corrupt => return Error.CorruptRecovery,
        }
        self.storage.clearAppendAuthorization();
        self.storage.expected_phase = .repair_truncate;
        self.storage.repair_generation = self.generation;
        self.storage.repair_snapshot_sha256 = self.snapshot.snapshot_sha256;
        self.storage.repair_expected_bytes = self.snapshot.observed_bytes;
        self.storage.repair_target_bytes = plan.truncate_to_bytes;
        return .{
            .context = self.storage,
            .snapshot = self.snapshot,
            .expected_current_bytes = self.snapshot.observed_bytes,
            .target_bytes = plan.truncate_to_bytes,
            .discarded_tail_bytes = plan.discard_tail_bytes,
            .final_record_sha256 = plan.classification.final_record_sha256,
            .validate_fn = DeterministicStorageV1.validateLease,
            .truncate_fn = DeterministicStorageV1.repairTruncate,
            .sync_fn = DeterministicStorageV1.repairSync,
        };
    }

    pub fn release(self: *DeterministicLeaseV1) Error!void {
        try DeterministicStorageV1.validateLease(self.storage, self.generation);
        self.storage.active_generation = 0;
        self.generation = 0;
    }
};

fn rangesOverlap(destination: []u8, source: []const u8) bool {
    if (destination.len == 0 or source.len == 0) return false;
    const destination_start = @intFromPtr(destination.ptr);
    const source_start = @intFromPtr(source.ptr);
    const destination_end = destination_start + destination.len;
    const source_end = source_start + source.len;
    return destination_start < source_end and source_start < destination_end;
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
    const grant_sha256 = sweep.commitGrantRootV1(commit_grant) catch unreachable;
    var store_receipt: object_store.RetiredCommitReceiptV1 = .{
        .authorization_sha256 = grant_sha256,
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
        .commit_grant_sha256 = grant_sha256,
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

const TestStream = struct {
    bytes: [record.encoded_bytes * 2]u8,
    first_root: Digest,
    second_root: Digest,
};

fn testStream() Error!TestStream {
    var output: TestStream = undefined;
    const first = try record.encodeV1(
        testInput(0x6a, 0x6b),
        output.bytes[0..record.encoded_bytes],
    );
    const first_decoded = try record.decodeV1(first);
    var second_input = testInput(0x6b, 0x6c);
    second_input.sequence = 2;
    second_input.previous_record_sha256 = first_decoded.record_sha256;
    const second = try record.encodeV1(
        second_input,
        output.bytes[record.encoded_bytes..],
    );
    output.first_root = first_decoded.record_sha256;
    output.second_root = (try record.decodeV1(second)).record_sha256;
    return output;
}

fn testAnchor() record.RecoveryAnchorV1 {
    return .{
        .record_epoch = 0x5357_4545_5000_0001,
        .next_sequence = 1,
        .previous_record_sha256 = capsule.zero_digest,
    };
}

test "snapshot-bound exclusive writer appends only ordered synced records" {
    const fixture = try testStream();
    var backing: [record.encoded_bytes * 3]u8 = undefined;
    var storage = try DeterministicStorageV1.init(
        &backing,
        fixture.bytes[0..record.encoded_bytes],
        41,
    );
    var lease = try storage.acquire();
    try std.testing.expectError(Error.Busy, storage.acquire());
    const append_capability = try lease.appendCapability();
    const stream_hex = std.fmt.bytesToHex(lease.snapshot.stream_sha256, .lower);
    const snapshot_hex = std.fmt.bytesToHex(
        lease.snapshot.snapshot_sha256,
        .lower,
    );
    try std.testing.expectEqualStrings(
        "3b3fb1adf8ed0b13b8e8719a3ade7dbb2a7133c0ea6d307598ee3b2941d7c6d3",
        &stream_hex,
    );
    try std.testing.expectEqualStrings(
        "b02d101a0c8152e112562ed4d70ea5b957192ba5886e35188ea8ef9a9aee3897",
        &snapshot_hex,
    );

    var writer = try WriterV1.openClean(
        storage.bytes(),
        testAnchor(),
        append_capability,
    );
    const receipt = try writer.appendRecord(
        fixture.bytes[record.encoded_bytes..],
    );
    try std.testing.expectEqual(@as(u64, 2), receipt.sequence);
    try std.testing.expectEqual(fixture.bytes.len, receipt.committed_bytes);
    try std.testing.expectEqualSlices(
        u8,
        &fixture.second_root,
        &receipt.record_sha256,
    );
    try std.testing.expectEqualSlices(u8, &fixture.bytes, storage.bytes());
    try std.testing.expectEqualSlices(IoPhaseV1, &.{
        .body_write,
        .body_sync,
        .footer_write,
        .footer_sync,
    }, storage.trace());
    try std.testing.expectEqual(storage.length, storage.synced_length);
    try std.testing.expectError(
        Error.InvalidCapability,
        WriterV1.openClean(
            fixture.bytes[0..record.encoded_bytes],
            testAnchor(),
            append_capability,
        ),
    );

    writer.close();
    try std.testing.expectError(
        Error.InvalidWriterState,
        writer.appendRecord(fixture.bytes[record.encoded_bytes..]),
    );
    const stale_capability = append_capability;
    try lease.release();
    try std.testing.expectError(
        Error.InvalidCapability,
        WriterV1.openClean(storage.bytes(), testAnchor(), stale_capability),
    );
}

test "snapshot mismatch and record preflight reject before I/O" {
    const fixture = try testStream();
    var backing: [record.encoded_bytes * 2]u8 = undefined;
    var storage = try DeterministicStorageV1.init(
        &backing,
        fixture.bytes[0..record.encoded_bytes],
        42,
    );
    var lease = try storage.acquire();
    defer lease.release() catch {};
    var changed = fixture.bytes[0..record.encoded_bytes].*;
    changed[0] ^= 1;
    try std.testing.expectError(
        Error.SnapshotMismatch,
        WriterV1.openClean(
            &changed,
            testAnchor(),
            try lease.appendCapability(),
        ),
    );

    var writer = try WriterV1.openClean(
        storage.bytes(),
        testAnchor(),
        try lease.appendCapability(),
    );
    try std.testing.expectError(
        Error.RecordExpectationMismatch,
        writer.appendRecord(fixture.bytes[0..record.encoded_bytes]),
    );
    try std.testing.expectEqual(WriterStateV1.ready, writer.state);
    try std.testing.expectEqual(@as(usize, 0), storage.trace().len);

    var limited_backing: [record.encoded_bytes + record.body_bytes]u8 = undefined;
    var limited_storage = try DeterministicStorageV1.init(
        &limited_backing,
        fixture.bytes[0..record.encoded_bytes],
        44,
    );
    var limited_lease = try limited_storage.acquire();
    defer limited_lease.release() catch {};
    var limited_writer = try WriterV1.openClean(
        limited_storage.bytes(),
        testAnchor(),
        try limited_lease.appendCapability(),
    );
    try std.testing.expectError(
        Error.CapacityExceeded,
        limited_writer.appendRecord(fixture.bytes[record.encoded_bytes..]),
    );
    try std.testing.expectEqual(WriterStateV1.ready, limited_writer.state);
    try std.testing.expectEqual(@as(usize, 0), limited_storage.trace().len);
}

test "bounded trace saturation never limits valid append capacity" {
    const record_count = 17;
    var backing: [record.encoded_bytes * record_count]u8 = undefined;
    var storage = try DeterministicStorageV1.init(&backing, &.{}, 43);
    var lease = try storage.acquire();
    defer lease.release() catch {};
    var writer = try WriterV1.openClean(
        storage.bytes(),
        testAnchor(),
        try lease.appendCapability(),
    );
    var previous = capsule.zero_digest;
    for (0..record_count) |index| {
        const offset: u8 = @intCast(index);
        var input = testInput(0x6a + offset, 0x6b + offset);
        input.sequence = @as(u64, @intCast(index)) + 1;
        input.previous_record_sha256 = previous;
        var encoded: [record.encoded_bytes]u8 = undefined;
        const bytes_value = try record.encodeV1(input, &encoded);
        const receipt = try writer.appendRecord(bytes_value);
        previous = receipt.record_sha256;
    }
    try std.testing.expectEqual(WriterStateV1.ready, writer.state);
    try std.testing.expectEqual(backing.len, storage.length);
    try std.testing.expectEqual(storage.length, storage.synced_length);
    try std.testing.expectEqual(@as(usize, 64), storage.trace().len);
    try std.testing.expect(storage.trace_truncated);
    try std.testing.expectEqual(@as(u64, record_count * 4), storage.operation_count);
    const classified = try record.classifyRecoveryV1(storage.bytes(), testAnchor());
    try std.testing.expectEqual(record.RecoveryStatusV1.clean, classified.status);
    try std.testing.expectEqual(@as(u64, record_count), classified.committed_records);
}

test "every I/O uncertainty poisons writer and reopens from persisted evidence" {
    const fixture = try testStream();
    const expected_status = [_][2]record.RecoveryStatusV1{
        .{ .clean, .body_without_footer },
        .{ .body_without_footer, .body_without_footer },
        .{ .body_without_footer, .clean },
        .{ .clean, .clean },
    };
    for (0..4) |call_index| {
        for ([_]FaultTimingV1{ .before, .after }, 0..) |timing, timing_index| {
            var backing: [record.encoded_bytes * 2]u8 = undefined;
            var storage = try DeterministicStorageV1.init(
                &backing,
                fixture.bytes[0..record.encoded_bytes],
                50 + call_index * 2 + timing_index,
            );
            var lease = try storage.acquire();
            var writer = try WriterV1.openClean(
                storage.bytes(),
                testAnchor(),
                try lease.appendCapability(),
            );
            storage.setFault(.{
                .call_index = call_index,
                .timing = timing,
            });
            try std.testing.expectError(
                Error.InjectedFault,
                writer.appendRecord(fixture.bytes[record.encoded_bytes..]),
            );
            try std.testing.expectEqual(WriterStateV1.poisoned, writer.state);
            try std.testing.expectError(
                Error.InvalidWriterState,
                writer.appendRecord(fixture.bytes[record.encoded_bytes..]),
            );
            const bounds = storage.crashBounds();
            try storage.crashPersist(bounds.upper);
            lease.generation = 0;
            var reopened = try storage.acquire();
            defer reopened.release() catch {};
            const plan = try planRecoveryV1(
                storage.bytes(),
                testAnchor(),
                reopened.snapshot,
            );
            try std.testing.expectEqual(
                expected_status[call_index][timing_index],
                plan.classification.status,
            );
        }
    }
}

test "every body and footer partial write boundary classifies exactly" {
    const fixture = try testStream();
    for (0..record.body_bytes + 1) |prefix| {
        var backing: [record.encoded_bytes * 2]u8 = undefined;
        var storage = try DeterministicStorageV1.init(
            &backing,
            fixture.bytes[0..record.encoded_bytes],
            1000 + prefix,
        );
        const lease = try storage.acquire();
        var writer = try WriterV1.openClean(
            storage.bytes(),
            testAnchor(),
            try lease.appendCapability(),
        );
        storage.setFault(.{
            .call_index = 0,
            .timing = .after,
            .write_prefix = prefix,
        });
        try std.testing.expectError(
            Error.InjectedFault,
            writer.appendRecord(fixture.bytes[record.encoded_bytes..]),
        );
        try storage.crashPersist(storage.crashBounds().upper);
        var reopened = try storage.acquire();
        defer reopened.release() catch {};
        const plan = try planRecoveryV1(
            storage.bytes(),
            testAnchor(),
            reopened.snapshot,
        );
        const expected_status: record.RecoveryStatusV1 = if (prefix == 0)
            record.RecoveryStatusV1.clean
        else if (prefix < record.body_bytes)
            .short_body_tail
        else
            .body_without_footer;
        try std.testing.expectEqual(
            expected_status,
            plan.classification.status,
        );
    }

    for (0..record.commit_footer_bytes + 1) |prefix| {
        var backing: [record.encoded_bytes * 2]u8 = undefined;
        var storage = try DeterministicStorageV1.init(
            &backing,
            fixture.bytes[0..record.encoded_bytes],
            2000 + prefix,
        );
        const lease = try storage.acquire();
        var writer = try WriterV1.openClean(
            storage.bytes(),
            testAnchor(),
            try lease.appendCapability(),
        );
        storage.setFault(.{
            .call_index = 2,
            .timing = .after,
            .write_prefix = prefix,
        });
        try std.testing.expectError(
            Error.InjectedFault,
            writer.appendRecord(fixture.bytes[record.encoded_bytes..]),
        );
        try storage.crashPersist(storage.crashBounds().upper);
        var reopened = try storage.acquire();
        defer reopened.release() catch {};
        const plan = try planRecoveryV1(
            storage.bytes(),
            testAnchor(),
            reopened.snapshot,
        );
        const expected_status: record.RecoveryStatusV1 = if (prefix == 0)
            record.RecoveryStatusV1.body_without_footer
        else if (prefix < record.commit_footer_bytes)
            .partial_footer_tail
        else
            .clean;
        try std.testing.expectEqual(
            expected_status,
            plan.classification.status,
        );
    }
}

test "explicit repair truncates only an incomplete tail and requires reacquire" {
    const fixture = try testStream();
    for (1..record.encoded_bytes) |tail_length| {
        var backing: [record.encoded_bytes * 2]u8 = undefined;
        var storage = try DeterministicStorageV1.init(
            &backing,
            fixture.bytes[0 .. record.encoded_bytes + tail_length],
            3000 + tail_length,
        );
        var lease = try storage.acquire();
        const append_capability = try lease.appendCapability();
        try std.testing.expectError(
            Error.RepairRequired,
            WriterV1.openClean(storage.bytes(), testAnchor(), append_capability),
        );
        const repair_capability = try lease.prepareRepair(
            storage.bytes(),
            testAnchor(),
        );
        if (tail_length == 1) {
            var forged_capability = repair_capability;
            forged_capability.target_bytes += 1;
            try std.testing.expectError(
                Error.InvalidCapability,
                RepairerV1.init(
                    storage.bytes(),
                    testAnchor(),
                    forged_capability,
                ),
            );
            try std.testing.expectEqual(@as(usize, 0), storage.trace().len);
        }
        var repairer = try RepairerV1.init(
            storage.bytes(),
            testAnchor(),
            repair_capability,
        );
        const receipt = try repairer.apply();
        try std.testing.expectEqual(record.encoded_bytes, receipt.committed_bytes);
        try std.testing.expectEqual(tail_length, receipt.discarded_tail_bytes);
        try std.testing.expectEqual(RepairStateV1.complete, repairer.state);
        try std.testing.expectError(Error.InvalidRepairState, repairer.apply());
        try std.testing.expectError(
            Error.InvalidCapability,
            WriterV1.openClean(storage.bytes(), testAnchor(), append_capability),
        );
        try lease.release();

        var reopened = try storage.acquire();
        defer reopened.release() catch {};
        var writer = try WriterV1.openClean(
            storage.bytes(),
            testAnchor(),
            try reopened.appendCapability(),
        );
        _ = try writer.appendRecord(fixture.bytes[record.encoded_bytes..]);
        try std.testing.expectEqualSlices(u8, &fixture.bytes, storage.bytes());
    }
}

test "uncertain repair poisons and crash preserves either admissible length" {
    const fixture = try testStream();
    for (0..2) |call_index| {
        for ([_]FaultTimingV1{ .before, .after }) |timing| {
            for ([_]bool{ false, true }) |persist_upper| {
                var backing: [record.encoded_bytes * 2]u8 = undefined;
                var storage = try DeterministicStorageV1.init(
                    &backing,
                    fixture.bytes[0 .. record.encoded_bytes + 100],
                    5000 + call_index * 4 +
                        @as(usize, @intFromEnum(timing)) * 2 +
                        @intFromBool(persist_upper),
                );
                const lease = try storage.acquire();
                var repairer = try RepairerV1.init(
                    storage.bytes(),
                    testAnchor(),
                    try lease.prepareRepair(storage.bytes(), testAnchor()),
                );
                storage.setFault(.{
                    .call_index = call_index,
                    .timing = timing,
                });
                try std.testing.expectError(Error.InjectedFault, repairer.apply());
                try std.testing.expectEqual(RepairStateV1.poisoned, repairer.state);
                try std.testing.expectError(Error.InvalidRepairState, repairer.apply());
                const bounds = storage.crashBounds();
                const persisted = if (persist_upper) bounds.upper else bounds.lower;
                try storage.crashPersist(persisted);
                var reopened = try storage.acquire();
                defer reopened.release() catch {};
                const plan = try planRecoveryV1(
                    storage.bytes(),
                    testAnchor(),
                    reopened.snapshot,
                );
                try std.testing.expectEqual(
                    if (persisted == record.encoded_bytes)
                        RecoveryActionV1.open_clean
                    else
                        .repair_incomplete_tail,
                    plan.action,
                );
            }
        }
    }
}

test "corrupt complete evidence never receives repair authority" {
    const fixture = try testStream();
    var corrupted = fixture.bytes;
    corrupted[record.encoded_bytes + record.accounting_before_offset] ^= 1;
    var backing: [record.encoded_bytes * 2]u8 = undefined;
    var storage = try DeterministicStorageV1.init(&backing, &corrupted, 4001);
    var lease = try storage.acquire();
    defer lease.release() catch {};
    const before = backing;
    const plan = try planRecoveryV1(
        storage.bytes(),
        testAnchor(),
        lease.snapshot,
    );
    try std.testing.expectEqual(RecoveryActionV1.reject_corrupt, plan.action);
    try std.testing.expectError(
        Error.CorruptRecovery,
        lease.prepareRepair(storage.bytes(), testAnchor()),
    );
    try std.testing.expectEqualSlices(u8, &before, &backing);
}
