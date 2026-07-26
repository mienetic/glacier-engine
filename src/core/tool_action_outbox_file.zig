//! Descriptor-relative durable storage for ActionOutbox journals.
//!
//! The store owns one exclusively locked regular-file descriptor beneath a
//! caller-opened trusted directory. Journal bytes remain exactly one canonical
//! `HeaderV1` followed by canonical `RecordV1` frames; there is no filesystem
//! envelope, trailer, or sidecar authority.
//!
//! Append state is preflighted against a bounded scratch copy before I/O.
//! Physical length and footer-synchronized committed length remain separate,
//! and caller-visible records, states, and ledger advance only after body sync,
//! footer sync, namespace verification, and exact readback all succeed.
//!
//! POSIX locks are advisory. Sync plus process termination demonstrates ordered
//! host filesystem calls and restart recovery, not device power-loss behavior,
//! distributed locking, provider truth, or externally exactly-once effects.

const std = @import("std");
const platform_capabilities = @import("platform_capabilities.zig");
const outbox = @import("tool_action_outbox_record.zig");

pub const Digest = outbox.Digest;
pub const zero_digest = outbox.zero_digest;
pub const max_name_bytes: usize = 255;
pub const store_abi: u64 = 0x4754_4f53_0000_0001;

const content_snapshot_domain =
    "glacier-action-outbox-store-content-snapshot-v1\x00";
const lease_binding_domain =
    "glacier-action-outbox-store-lease-binding-v1\x00";
const repair_plan_domain =
    "glacier-action-outbox-store-repair-plan-v1\x00";

pub const Error = outbox.Error || error{
    BufferTooSmall,
    InjectedFault,
    InvalidName,
    InvalidLeaseBinding,
    InvalidRepairPlan,
    InvalidSnapshot,
    InvalidStoreState,
    InvalidStorage,
    MultipleLinks,
    RepairNotRequired,
    RepairRequired,
    StorageContentChanged,
    StorageIdentityChanged,
    StorageIo,
    UnsafePermissions,
    UnsupportedPlatform,
};

pub const IoPhaseV1 = enum(u8) {
    header_write,
    header_sync,
    directory_sync,
    recovery_sync,
    body_write,
    body_sync,
    footer_write,
    footer_sync,
    repair_truncate,
    repair_sync,
};

/// Called after an OS operation returns but before its postcondition is
/// accepted. Tests use this boundary for injected errors, namespace races, and
/// real process death; production callers may use it for allocation-free
/// tracing.
pub const PhaseObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void,

    fn after(
        self: PhaseObserverV1,
        phase: IoPhaseV1,
    ) Error!void {
        try self.after_phase_fn(self.context, phase);
    }
};

pub const OpenOptionsV1 = struct {
    lock_nonblocking: bool = true,
    require_private_mode: bool = true,
    observer: ?PhaseObserverV1 = null,
};

pub const StoreStateV1 = enum(u8) {
    ready,
    append_active,
    repair_required,
    repair_active,
    repair_complete,
    poisoned,
    closed,
};

pub const DirectorySyncStatusV1 = enum(u8) {
    synced,
    not_applicable,
};

pub const FileIdentityV1 = struct {
    device: u64,
    inode: u64,
};

pub const ContentSnapshotV1 = struct {
    abi_version: u64 = store_abi,
    header_sha256: Digest = zero_digest,
    observed_bytes: u64 = 0,
    maximum_bytes: u64 = 0,
    stream_sha256: Digest = zero_digest,
    recovery_status: outbox.RecoveryStatusV1 = .clean,
    committed_bytes: u64 = 0,
    discarded_tail_bytes: u64 = 0,
    committed_records: u64 = 0,
    final_chain_sha256: Digest = zero_digest,
    state_sha256: Digest = zero_digest,
    ledger_sha256: Digest = zero_digest,
    snapshot_sha256: Digest = zero_digest,
};

pub fn contentSnapshotSha256V1(
    value: ContentSnapshotV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(content_snapshot_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.header_sha256);
    hashU64(&hash, value.observed_bytes);
    hashU64(&hash, value.maximum_bytes);
    hash.update(&value.stream_sha256);
    hashU8(&hash, @intFromEnum(value.recovery_status));
    hashU64(&hash, value.committed_bytes);
    hashU64(&hash, value.discarded_tail_bytes);
    hashU64(&hash, value.committed_records);
    hash.update(&value.final_chain_sha256);
    hash.update(&value.state_sha256);
    hash.update(&value.ledger_sha256);
    return finish(&hash);
}

pub fn validateContentSnapshotV1(
    value: ContentSnapshotV1,
) Error!void {
    const committed_payload =
        value.committed_bytes -| outbox.header_bytes;
    const committed_records =
        committed_payload / outbox.record_bytes;
    if (value.abi_version != store_abi or
        digestIsZero(value.header_sha256) or
        value.observed_bytes < outbox.header_bytes or
        value.observed_bytes > value.maximum_bytes or
        value.committed_bytes < outbox.header_bytes or
        value.committed_bytes > value.observed_bytes or
        committed_payload % outbox.record_bytes != 0 or
        value.committed_records != committed_records or
        value.discarded_tail_bytes !=
            value.observed_bytes - value.committed_bytes or
        !validTailShape(
            value.recovery_status,
            value.discarded_tail_bytes,
        ) or
        digestIsZero(value.stream_sha256) or
        digestIsZero(value.final_chain_sha256) or
        digestIsZero(value.state_sha256) or
        digestIsZero(value.ledger_sha256) or
        digestIsZero(value.snapshot_sha256) or
        !digestEqual(
            value.snapshot_sha256,
            contentSnapshotSha256V1(value),
        ))
        return Error.InvalidSnapshot;
}

pub const LeaseBindingV1 = struct {
    abi_version: u64 = store_abi,
    storage_epoch: u64 = 0,
    lease_generation: u64 = 0,
    snapshot_sha256: Digest = zero_digest,
    lease_sha256: Digest = zero_digest,
};

pub fn leaseBindingSha256V1(
    value: LeaseBindingV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(lease_binding_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.storage_epoch);
    hashU64(&hash, value.lease_generation);
    hash.update(&value.snapshot_sha256);
    return finish(&hash);
}

pub fn makeLeaseBindingV1(
    storage_epoch: u64,
    lease_generation: u64,
    snapshot: ContentSnapshotV1,
) Error!LeaseBindingV1 {
    try validateContentSnapshotV1(snapshot);
    if (storage_epoch == 0 or lease_generation == 0)
        return Error.InvalidLeaseBinding;
    var result: LeaseBindingV1 = .{
        .storage_epoch = storage_epoch,
        .lease_generation = lease_generation,
        .snapshot_sha256 = snapshot.snapshot_sha256,
    };
    result.lease_sha256 = leaseBindingSha256V1(result);
    return result;
}

pub fn validateLeaseBindingV1(
    value: LeaseBindingV1,
) Error!void {
    if (value.abi_version != store_abi or
        value.storage_epoch == 0 or
        value.lease_generation == 0 or
        digestIsZero(value.snapshot_sha256) or
        digestIsZero(value.lease_sha256) or
        !digestEqual(
            value.lease_sha256,
            leaseBindingSha256V1(value),
        ))
        return Error.InvalidLeaseBinding;
}

pub const RepairPlanV1 = struct {
    abi_version: u64 = store_abi,
    lease_sha256: Digest = zero_digest,
    recovery_status: outbox.RecoveryStatusV1 =
        .short_body_tail,
    observed_bytes: u64 = 0,
    committed_bytes: u64 = 0,
    discarded_tail_bytes: u64 = 0,
    final_chain_sha256: Digest = zero_digest,
    state_sha256: Digest = zero_digest,
    ledger_sha256: Digest = zero_digest,
    plan_sha256: Digest = zero_digest,
};

pub fn repairPlanSha256V1(value: RepairPlanV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(repair_plan_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.lease_sha256);
    hashU8(&hash, @intFromEnum(value.recovery_status));
    hashU64(&hash, value.observed_bytes);
    hashU64(&hash, value.committed_bytes);
    hashU64(&hash, value.discarded_tail_bytes);
    hash.update(&value.final_chain_sha256);
    hash.update(&value.state_sha256);
    hash.update(&value.ledger_sha256);
    return finish(&hash);
}

pub fn makeRepairPlanV1(
    snapshot: ContentSnapshotV1,
    lease: LeaseBindingV1,
) Error!RepairPlanV1 {
    try validateContentSnapshotV1(snapshot);
    try validateLeaseBindingV1(lease);
    if (!digestEqual(
        lease.snapshot_sha256,
        snapshot.snapshot_sha256,
    ) or
        snapshot.recovery_status == .clean or
        snapshot.discarded_tail_bytes == 0)
        return Error.InvalidRepairPlan;
    var result: RepairPlanV1 = .{
        .lease_sha256 = lease.lease_sha256,
        .recovery_status = snapshot.recovery_status,
        .observed_bytes = snapshot.observed_bytes,
        .committed_bytes = snapshot.committed_bytes,
        .discarded_tail_bytes = snapshot.discarded_tail_bytes,
        .final_chain_sha256 = snapshot.final_chain_sha256,
        .state_sha256 = snapshot.state_sha256,
        .ledger_sha256 = snapshot.ledger_sha256,
    };
    result.plan_sha256 = repairPlanSha256V1(result);
    return result;
}

pub fn validateRepairPlanV1(
    value: RepairPlanV1,
) Error!void {
    if (value.abi_version != store_abi or
        digestIsZero(value.lease_sha256) or
        value.recovery_status == .clean or
        value.committed_bytes < outbox.header_bytes or
        value.committed_bytes >= value.observed_bytes or
        value.discarded_tail_bytes !=
            value.observed_bytes - value.committed_bytes or
        !validTailShape(
            value.recovery_status,
            value.discarded_tail_bytes,
        ) or
        digestIsZero(value.final_chain_sha256) or
        digestIsZero(value.state_sha256) or
        digestIsZero(value.ledger_sha256) or
        digestIsZero(value.plan_sha256) or
        !digestEqual(
            value.plan_sha256,
            repairPlanSha256V1(value),
        ))
        return Error.InvalidRepairPlan;
}

pub const DurableAppendReceiptV1 = struct {
    sequence: u64,
    committed_bytes: usize,
    record_sha256: Digest,
    final_chain_sha256: Digest,
    state_sha256: Digest,
    ledger_sha256: Digest,
    content_snapshot_sha256: Digest,
    lease_sha256: Digest,
    ledger: outbox.LedgerV1,
    body_sync_exercised: bool,
    footer_sync_exercised: bool,
};

pub const RepairReceiptV1 = struct {
    original_bytes: usize,
    committed_bytes: usize,
    discarded_tail_bytes: usize,
    recovery_status: outbox.RecoveryStatusV1,
    final_chain_sha256: Digest,
    state_sha256: Digest,
    ledger_sha256: Digest,
    repair_plan_sha256: Digest,
    original_snapshot_sha256: Digest,
    repaired_snapshot_sha256: Digest,
    truncate_sync_exercised: bool,
};

var next_lease_generation = std.atomic.Value(u64).init(1);

pub fn maximumFileBytesV1(
    header: outbox.HeaderV1,
) Error!usize {
    try outbox.validateHeaderV1(header);
    const record_capacity: usize = @intCast(header.maximum_records);
    const records_bytes = std.math.mul(
        usize,
        record_capacity,
        outbox.record_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        outbox.header_bytes,
        records_bytes,
    ) catch return Error.ArithmeticOverflow;
}

fn makeContentSnapshotFieldsV1(
    header_sha256: Digest,
    observed_bytes: usize,
    maximum_bytes: usize,
    stream_sha256: Digest,
    recovery_status: outbox.RecoveryStatusV1,
    committed_bytes: usize,
    discarded_tail_bytes: usize,
    committed_records: u64,
    final_chain_sha256: Digest,
    state_sha256: Digest,
    ledger_sha256: Digest,
) ContentSnapshotV1 {
    var result: ContentSnapshotV1 = .{
        .header_sha256 = header_sha256,
        .observed_bytes = @intCast(observed_bytes),
        .maximum_bytes = @intCast(maximum_bytes),
        .stream_sha256 = stream_sha256,
        .recovery_status = recovery_status,
        .committed_bytes = @intCast(committed_bytes),
        .discarded_tail_bytes = @intCast(discarded_tail_bytes),
        .committed_records = committed_records,
        .final_chain_sha256 = final_chain_sha256,
        .state_sha256 = state_sha256,
        .ledger_sha256 = ledger_sha256,
    };
    result.snapshot_sha256 =
        contentSnapshotSha256V1(result);
    return result;
}

/// Replays the supplied recovery through caller-owned state scratch. The
/// scratch may alias `recovery.states`; it is replaced by the validated replay
/// on success and cleared on failure.
pub fn contentSnapshotFromRecoveryV1(
    stream: []const u8,
    maximum_bytes: usize,
    recovery: outbox.RecoveryV1,
    replay_state_storage: []outbox.ActionStateV1,
) Error!ContentSnapshotV1 {
    try outbox.validateHeaderV1(recovery.header);
    const action_capacity: usize =
        @intCast(recovery.header.maximum_actions);
    if (maximum_bytes !=
        try maximumFileBytesV1(recovery.header))
        return Error.InvalidSnapshot;
    if (stream.len < outbox.header_bytes or
        stream.len > maximum_bytes or
        recovery.committed_bytes > stream.len or
        recovery.discarded_tail_bytes !=
            stream.len - recovery.committed_bytes or
        recovery.records.len !=
            recovery.ledger.committed_records or
        recovery.states.len !=
            recovery.ledger.actions_enqueued or
        replay_state_storage.len < action_capacity)
        return Error.InvalidSnapshot;
    const decoded_header = outbox.decodeHeaderV1(
        stream[0..outbox.header_bytes],
        recovery.header.header_sha256,
    ) catch return Error.InvalidSnapshot;
    if (!std.meta.eql(decoded_header, recovery.header))
        return Error.InvalidSnapshot;

    const supplied_state_sha256 = outbox.stateSha256V1(
        recovery.header,
        recovery.states,
        recovery.ledger,
    );
    if (!digestEqual(
        supplied_state_sha256,
        recovery.state_sha256,
    )) return Error.InvalidSnapshot;
    const replay_states =
        replay_state_storage[0..action_capacity];
    zeroStates(replay_states);
    errdefer zeroStates(replay_states);
    var replay_ledger: outbox.LedgerV1 = .{};
    var previous = recovery.header.header_sha256;
    for (recovery.records, 0..) |expected, index| {
        const offset =
            outbox.header_bytes + index * outbox.record_bytes;
        if (offset + outbox.record_bytes >
            recovery.committed_bytes)
            return Error.InvalidSnapshot;
        const decoded = outbox.decodeRecordV1(
            recovery.header,
            @as(u64, @intCast(index)) + 1,
            previous,
            stream[offset .. offset + outbox.record_bytes],
        ) catch return Error.InvalidSnapshot;
        if (!std.meta.eql(decoded, expected))
            return Error.InvalidSnapshot;
        const apply_plan = outbox.planApplyRecordV1(
            recovery.header,
            decoded,
            replay_states,
            replay_ledger,
        ) catch return Error.InvalidSnapshot;
        outbox.commitApplyPlanV1(
            replay_states,
            &replay_ledger,
            apply_plan,
        );
        previous = decoded.record_sha256;
    }
    if (!std.meta.eql(replay_ledger, recovery.ledger) or
        !digestEqual(previous, recovery.final_chain_sha256))
        return Error.InvalidSnapshot;
    const replay_state_sha256 = outbox.stateSha256V1(
        recovery.header,
        replay_states[0..recovery.states.len],
        replay_ledger,
    );
    if (!digestEqual(
        replay_state_sha256,
        recovery.state_sha256,
    )) return Error.InvalidSnapshot;
    const stream_sha256 = sha256(stream);
    const result = makeContentSnapshotFieldsV1(
        recovery.header.header_sha256,
        stream.len,
        maximum_bytes,
        stream_sha256,
        recovery.status,
        recovery.committed_bytes,
        recovery.discarded_tail_bytes,
        recovery.ledger.committed_records,
        recovery.final_chain_sha256,
        recovery.state_sha256,
        outbox.ledgerSha256V1(recovery.ledger),
    );
    try validateContentSnapshotV1(result);
    return result;
}

pub const StoreV1 = struct {
    file: std.fs.File,
    directory: std.fs.Dir,
    name_storage: [max_name_bytes]u8,
    name_length: usize,
    header: outbox.HeaderV1,
    journal_storage: []u8,
    record_storage: []outbox.RecordV1,
    state_storage: []outbox.ActionStateV1,
    max_file_bytes: usize,
    observed_bytes: usize,
    current_bytes: usize,
    committed_bytes: usize,
    record_count: usize,
    action_count: usize,
    final_chain_sha256: Digest,
    state_sha256: Digest,
    ledger: outbox.LedgerV1,
    content_snapshot: ContentSnapshotV1,
    lease_binding: LeaseBindingV1,
    repair_plan: ?RepairPlanV1,
    recovery_status: outbox.RecoveryStatusV1,
    discarded_tail_bytes: usize,
    identity: FileIdentityV1,
    lease_generation: u64,
    require_private_mode: bool,
    observer: ?PhaseObserverV1,
    directory_sync_status: DirectorySyncStatusV1,
    file_sync_count: u64,
    directory_sync_count: u64,
    identity_check_count: u64,
    state: StoreStateV1,

    /// Creates a new private journal, writes its complete canonical header,
    /// synchronizes the file and containing directory, and only then returns
    /// append authority.
    pub fn create(
        directory: std.fs.Dir,
        name: []const u8,
        header: outbox.HeaderV1,
        options: OpenOptionsV1,
        journal_storage: []u8,
        record_storage: []outbox.RecordV1,
        state_storage: []outbox.ActionStateV1,
    ) !StoreV1 {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1.posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        const max_file_bytes = try validateAcquire(
            name,
            header,
            journal_storage,
            record_storage,
            state_storage,
        );
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
        if (inspected.size != 0)
            return Error.StorageIdentityChanged;

        var encoded_header: [outbox.header_bytes]u8 = undefined;
        _ = try outbox.encodeHeaderV1(header, &encoded_header);
        file.pwriteAll(&encoded_header, 0) catch
            return Error.StorageIo;
        if (options.observer) |observer|
            try observer.after(.header_write);
        try verifyInitial(
            file,
            directory,
            name,
            options.require_private_mode,
            inspected.identity,
            outbox.header_bytes,
        );

        file.sync() catch return Error.StorageIo;
        if (options.observer) |observer|
            try observer.after(.header_sync);
        try verifyInitial(
            file,
            directory,
            name,
            options.require_private_mode,
            inspected.identity,
            outbox.header_bytes,
        );

        syncDirectory(directory) catch return Error.StorageIo;
        if (options.observer) |observer|
            try observer.after(.directory_sync);
        try verifyInitial(
            file,
            directory,
            name,
            options.require_private_mode,
            inspected.identity,
            outbox.header_bytes,
        );
        try verifyFileContent(file, &encoded_header);

        @memset(journal_storage[0..max_file_bytes], 0);
        @memcpy(
            journal_storage[0..outbox.header_bytes],
            &encoded_header,
        );
        zeroRecords(record_storage);
        zeroStates(state_storage);
        var ledger: outbox.LedgerV1 = .{};
        try outbox.finalizeLedgerV1(&.{}, &ledger);
        const state_sha256 = outbox.stateSha256V1(
            header,
            state_storage[0..0],
            ledger,
        );
        const content_snapshot =
            makeContentSnapshotFieldsV1(
                header.header_sha256,
                outbox.header_bytes,
                max_file_bytes,
                sha256(&encoded_header),
                .clean,
                outbox.header_bytes,
                0,
                0,
                header.header_sha256,
                state_sha256,
                outbox.ledgerSha256V1(ledger),
            );
        try validateContentSnapshotV1(content_snapshot);
        const lease_binding = try makeLeaseBindingV1(
            header.outbox_epoch,
            generation,
            content_snapshot,
        );
        return .{
            .file = file,
            .directory = directory,
            .name_storage = name_storage,
            .name_length = name.len,
            .header = header,
            .journal_storage = journal_storage,
            .record_storage = record_storage,
            .state_storage = state_storage,
            .max_file_bytes = max_file_bytes,
            .observed_bytes = outbox.header_bytes,
            .current_bytes = outbox.header_bytes,
            .committed_bytes = outbox.header_bytes,
            .record_count = 0,
            .action_count = 0,
            .final_chain_sha256 = header.header_sha256,
            .state_sha256 = state_sha256,
            .ledger = ledger,
            .content_snapshot = content_snapshot,
            .lease_binding = lease_binding,
            .repair_plan = null,
            .recovery_status = .clean,
            .discarded_tail_bytes = 0,
            .identity = inspected.identity,
            .lease_generation = generation,
            .require_private_mode = options.require_private_mode,
            .observer = options.observer,
            .directory_sync_status = .synced,
            .file_sync_count = 1,
            .directory_sync_count = 1,
            .identity_check_count = 4,
            .state = .ready,
        };
    }

    /// Opens and exclusively locks one existing journal. The exact stable file
    /// snapshot is replayed without mutation. Clean evidence is synchronized
    /// once before append authority is returned; an incomplete tail instead
    /// returns a repair-only store.
    pub fn open(
        directory: std.fs.Dir,
        name: []const u8,
        expected_header: outbox.HeaderV1,
        options: OpenOptionsV1,
        journal_storage: []u8,
        record_storage: []outbox.RecordV1,
        state_storage: []outbox.ActionStateV1,
    ) !StoreV1 {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1.posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        const max_file_bytes = try validateAcquire(
            name,
            expected_header,
            journal_storage,
            record_storage,
            state_storage,
        );
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
        if (inspected.size > max_file_bytes)
            return Error.CapacityExceeded;
        if (inspected.size < outbox.header_bytes)
            return Error.InvalidLength;
        if (journal_storage.len < inspected.size)
            return Error.BufferTooSmall;
        const observed = journal_storage[0..inspected.size];
        try readAcquireSnapshot(
            file,
            observed,
            journal_storage[0..max_file_bytes],
            record_storage,
            state_storage,
        );
        var outputs_valid = false;
        errdefer if (!outputs_valid) {
            clearAcquireOutputs(
                journal_storage[0..max_file_bytes],
                record_storage,
                state_storage,
            );
        };
        const verified = try inspectInitial(
            file,
            directory,
            name,
            options.require_private_mode,
        );
        if (!std.meta.eql(inspected, verified))
            return Error.StorageIdentityChanged;

        const recovery = try outbox.recoverV1(
            observed,
            expected_header.header_sha256,
            record_storage,
            state_storage,
        );
        if (!std.meta.eql(recovery.header, expected_header))
            return Error.InvalidHeader;
        const action_count = std.math.cast(
            usize,
            recovery.ledger.actions_enqueued,
        ) orelse return Error.InvalidLifecycle;
        if (action_count != recovery.states.len)
            return Error.InvalidLifecycle;

        var file_sync_count: u64 = 0;
        var identity_check_count: u64 = 2;
        const state: StoreStateV1 = switch (recovery.status) {
            .clean => blk: {
                file.sync() catch return Error.StorageIo;
                file_sync_count = 1;
                if (options.observer) |observer|
                    try observer.after(.recovery_sync);
                try verifyInitial(
                    file,
                    directory,
                    name,
                    options.require_private_mode,
                    inspected.identity,
                    inspected.size,
                );
                try verifyFileContent(file, observed);
                identity_check_count = 3;
                break :blk .ready;
            },
            .short_body_tail,
            .body_without_footer,
            .partial_footer_tail,
            => .repair_required,
        };
        const content_snapshot =
            try contentSnapshotFromRecoveryV1(
                observed,
                max_file_bytes,
                recovery,
                state_storage,
            );
        const lease_binding = try makeLeaseBindingV1(
            expected_header.outbox_epoch,
            generation,
            content_snapshot,
        );
        const repair_plan: ?RepairPlanV1 =
            if (state == .repair_required)
                try makeRepairPlanV1(
                    content_snapshot,
                    lease_binding,
                )
            else
                null;
        outputs_valid = true;

        return .{
            .file = file,
            .directory = directory,
            .name_storage = name_storage,
            .name_length = name.len,
            .header = expected_header,
            .journal_storage = journal_storage,
            .record_storage = record_storage,
            .state_storage = state_storage,
            .max_file_bytes = max_file_bytes,
            .observed_bytes = inspected.size,
            .current_bytes = inspected.size,
            .committed_bytes = recovery.committed_bytes,
            .record_count = recovery.records.len,
            .action_count = action_count,
            .final_chain_sha256 = recovery.final_chain_sha256,
            .state_sha256 = recovery.state_sha256,
            .ledger = recovery.ledger,
            .content_snapshot = content_snapshot,
            .lease_binding = lease_binding,
            .repair_plan = repair_plan,
            .recovery_status = recovery.status,
            .discarded_tail_bytes = recovery.discarded_tail_bytes,
            .identity = inspected.identity,
            .lease_generation = generation,
            .require_private_mode = options.require_private_mode,
            .observer = options.observer,
            .directory_sync_status = .not_applicable,
            .file_sync_count = file_sync_count,
            .directory_sync_count = 0,
            .identity_check_count = identity_check_count,
            .state = state,
        };
    }

    pub fn entryName(self: *const StoreV1) []const u8 {
        return self.name_storage[0..self.name_length];
    }

    /// Returns only the footer-committed prefix. An incomplete observed suffix
    /// is available through `observedJournal` solely for diagnostics/repair.
    pub fn journal(
        self: *const StoreV1,
    ) Error![]const u8 {
        try self.requireAuthoritativeView();
        return self.journal_storage[0..self.committed_bytes];
    }

    pub fn observedJournal(
        self: *const StoreV1,
    ) Error![]const u8 {
        try self.requireAuthoritativeView();
        return self.journal_storage[0..self.observed_bytes];
    }

    pub fn records(
        self: *const StoreV1,
    ) Error![]const outbox.RecordV1 {
        try self.requireAuthoritativeView();
        return self.record_storage[0..self.record_count];
    }

    pub fn states(
        self: *const StoreV1,
    ) Error![]const outbox.ActionStateV1 {
        try self.requireAuthoritativeView();
        return self.state_storage[0..self.action_count];
    }

    /// Preflights semantic replay into bounded scratch state, publishes the
    /// body/footer with ordered syncs, verifies exact readback, and only then
    /// advances caller-visible state.
    pub fn appendRecord(
        self: *StoreV1,
        record: outbox.RecordV1,
    ) Error!DurableAppendReceiptV1 {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1.posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        if (self.state == .repair_required)
            return Error.RepairRequired;
        if (self.state != .ready or
            self.current_bytes != self.committed_bytes or
            self.observed_bytes != self.committed_bytes)
            return Error.InvalidStoreState;
        if (self.record_count >= self.header.maximum_records)
            return Error.CapacityExceeded;
        if (self.committed_bytes >
            self.max_file_bytes -| outbox.record_bytes)
            return Error.CapacityExceeded;
        try validateContentSnapshotV1(self.content_snapshot);
        try validateLeaseBindingV1(self.lease_binding);
        if (self.content_snapshot.recovery_status != .clean or
            !digestEqual(
                self.content_snapshot.snapshot_sha256,
                self.lease_binding.snapshot_sha256,
            ) or
            self.lease_binding.storage_epoch !=
                self.header.outbox_epoch or
            self.lease_binding.lease_generation !=
                self.lease_generation)
            return Error.InvalidLeaseBinding;
        self.verifyCurrent(self.committed_bytes) catch |err| {
            self.state = .poisoned;
            return err;
        };
        verifyFileContent(
            self.file,
            self.journal_storage[0..self.committed_bytes],
        ) catch |err| {
            self.state = .poisoned;
            return err;
        };

        var encoded: [outbox.record_bytes]u8 = undefined;
        _ = try outbox.encodeRecordV1(
            self.header,
            record,
            &encoded,
        );
        const expected_sequence: u64 =
            @as(u64, @intCast(self.record_count)) + 1;
        const append_plan = try outbox.appendPlanV1(
            self.header,
            expected_sequence,
            self.final_chain_sha256,
            &encoded,
        );

        const action_capacity: usize =
            @intCast(self.header.maximum_actions);
        const apply_plan = try outbox.planApplyRecordV1(
            self.header,
            record,
            self.state_storage[0..action_capacity],
            self.ledger,
        );
        const next_ledger = apply_plan.next_ledger;
        const next_action_count = apply_plan.next_action_count;
        if (next_action_count > action_capacity or
            apply_plan.state_index >= next_action_count)
            return Error.InvalidLifecycle;
        const next_state_sha256 = apply_plan.state_sha256;
        const next_ledger_sha256 =
            outbox.ledgerSha256V1(next_ledger);
        const append_offset = self.committed_bytes;
        const body_end = append_offset + outbox.record_body_bytes;
        const record_end = append_offset + outbox.record_bytes;
        const next_record_count = self.record_count + 1;
        const next_stream_sha256 = sha256Parts(
            self.journal_storage[0..append_offset],
            &encoded,
        );
        const next_content_snapshot =
            makeContentSnapshotFieldsV1(
                self.header.header_sha256,
                record_end,
                self.max_file_bytes,
                next_stream_sha256,
                .clean,
                record_end,
                0,
                next_ledger.committed_records,
                record.record_sha256,
                next_state_sha256,
                next_ledger_sha256,
            );
        try validateContentSnapshotV1(
            next_content_snapshot,
        );
        const next_lease_binding = try makeLeaseBindingV1(
            self.header.outbox_epoch,
            self.lease_generation,
            next_content_snapshot,
        );

        self.state = .append_active;
        errdefer self.state = .poisoned;

        self.state = .poisoned;
        self.file.pwriteAll(
            append_plan.body,
            append_offset,
        ) catch return Error.StorageIo;
        self.current_bytes = body_end;
        try self.observe(.body_write);
        try self.verifyCurrent(body_end);
        self.state = .append_active;

        self.state = .poisoned;
        self.file.sync() catch return Error.StorageIo;
        self.file_sync_count +|= 1;
        try self.observe(.body_sync);
        try self.verifyCurrent(body_end);
        self.state = .append_active;

        self.state = .poisoned;
        self.file.pwriteAll(
            append_plan.commit_footer,
            body_end,
        ) catch return Error.StorageIo;
        self.current_bytes = record_end;
        try self.observe(.footer_write);
        try self.verifyCurrent(record_end);
        self.state = .append_active;

        self.state = .poisoned;
        self.file.sync() catch return Error.StorageIo;
        self.file_sync_count +|= 1;
        try self.observe(.footer_sync);
        try self.verifyCurrent(record_end);

        try verifyFileContentParts(
            self.file,
            self.journal_storage[0..append_offset],
            &encoded,
        );
        try self.verifyCurrent(record_end);

        @memcpy(
            self.journal_storage[append_offset..record_end],
            &encoded,
        );
        outbox.commitApplyPlanV1(
            self.state_storage[0..action_capacity],
            &self.ledger,
            apply_plan,
        );
        self.record_storage[self.record_count] = record;
        self.record_count = next_record_count;
        self.action_count = next_action_count;
        self.final_chain_sha256 = record.record_sha256;
        self.state_sha256 = next_state_sha256;
        self.content_snapshot = next_content_snapshot;
        self.lease_binding = next_lease_binding;
        self.repair_plan = null;
        self.committed_bytes = record_end;
        self.observed_bytes = record_end;
        self.recovery_status = .clean;
        self.discarded_tail_bytes = 0;
        self.state = .ready;
        return .{
            .sequence = record.sequence,
            .committed_bytes = record_end,
            .record_sha256 = record.record_sha256,
            .final_chain_sha256 = record.record_sha256,
            .state_sha256 = next_state_sha256,
            .ledger_sha256 = next_ledger_sha256,
            .content_snapshot_sha256 = next_content_snapshot.snapshot_sha256,
            .lease_sha256 = next_lease_binding.lease_sha256,
            .ledger = next_ledger,
            .body_sync_exercised = true,
            .footer_sync_exercised = true,
        };
    }

    /// Truncates only a parser-classified incomplete suffix and synchronizes
    /// the repaired prefix. Successful repair intentionally does not restore
    /// append authority; the caller must close and freshly reopen/replay.
    pub fn repairIncompleteTail(
        self: *StoreV1,
    ) Error!RepairReceiptV1 {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1.posix_durable_file_adapter)
            return Error.UnsupportedPlatform;
        if (self.state == .ready)
            return Error.RepairNotRequired;
        if (self.state != .repair_required)
            return Error.InvalidStoreState;
        switch (self.recovery_status) {
            .clean => return Error.RepairNotRequired,
            .short_body_tail,
            .body_without_footer,
            .partial_footer_tail,
            => {},
        }
        const original_bytes = self.current_bytes;
        const target_bytes = self.committed_bytes;
        const discarded_tail_bytes = self.discarded_tail_bytes;
        const original_status = self.recovery_status;
        try validateContentSnapshotV1(self.content_snapshot);
        try validateLeaseBindingV1(self.lease_binding);
        const repair_plan = self.repair_plan orelse
            return Error.InvalidRepairPlan;
        try validateRepairPlanV1(repair_plan);
        if (!digestEqual(
            self.lease_binding.snapshot_sha256,
            self.content_snapshot.snapshot_sha256,
        ) or
            !digestEqual(
                repair_plan.lease_sha256,
                self.lease_binding.lease_sha256,
            ) or
            repair_plan.recovery_status != original_status or
            repair_plan.observed_bytes != original_bytes or
            repair_plan.committed_bytes != target_bytes or
            repair_plan.discarded_tail_bytes !=
                discarded_tail_bytes or
            !digestEqual(
                repair_plan.final_chain_sha256,
                self.final_chain_sha256,
            ) or
            !digestEqual(
                repair_plan.state_sha256,
                self.state_sha256,
            ) or
            !digestEqual(
                repair_plan.ledger_sha256,
                outbox.ledgerSha256V1(self.ledger),
            ))
            return Error.InvalidRepairPlan;
        const repaired_content_snapshot =
            makeContentSnapshotFieldsV1(
                self.header.header_sha256,
                target_bytes,
                self.max_file_bytes,
                sha256(
                    self.journal_storage[0..target_bytes],
                ),
                .clean,
                target_bytes,
                0,
                self.ledger.committed_records,
                self.final_chain_sha256,
                self.state_sha256,
                repair_plan.ledger_sha256,
            );
        try validateContentSnapshotV1(
            repaired_content_snapshot,
        );
        const repaired_lease_binding =
            try makeLeaseBindingV1(
                self.header.outbox_epoch,
                self.lease_generation,
                repaired_content_snapshot,
            );
        const receipt: RepairReceiptV1 = .{
            .original_bytes = original_bytes,
            .committed_bytes = target_bytes,
            .discarded_tail_bytes = discarded_tail_bytes,
            .recovery_status = original_status,
            .final_chain_sha256 = self.final_chain_sha256,
            .state_sha256 = self.state_sha256,
            .ledger_sha256 = outbox.ledgerSha256V1(self.ledger),
            .repair_plan_sha256 = repair_plan.plan_sha256,
            .original_snapshot_sha256 = self.content_snapshot.snapshot_sha256,
            .repaired_snapshot_sha256 = repaired_content_snapshot.snapshot_sha256,
            .truncate_sync_exercised = true,
        };
        self.verifyCurrent(original_bytes) catch |err| {
            self.state = .poisoned;
            return err;
        };
        verifyFileContent(
            self.file,
            self.journal_storage[0..original_bytes],
        ) catch |err| {
            self.state = .poisoned;
            return err;
        };

        self.state = .repair_active;
        errdefer self.state = .poisoned;

        self.state = .poisoned;
        self.file.setEndPos(target_bytes) catch
            return Error.StorageIo;
        self.current_bytes = target_bytes;
        try self.observe(.repair_truncate);
        try self.verifyCurrent(target_bytes);
        self.state = .repair_active;

        self.state = .poisoned;
        self.file.sync() catch return Error.StorageIo;
        self.file_sync_count +|= 1;
        try self.observe(.repair_sync);
        try self.verifyCurrent(target_bytes);

        try verifyFileContent(
            self.file,
            self.journal_storage[0..target_bytes],
        );
        try self.verifyCurrent(target_bytes);

        @memset(
            self.journal_storage[target_bytes..original_bytes],
            0,
        );
        self.observed_bytes = target_bytes;
        self.content_snapshot = repaired_content_snapshot;
        self.lease_binding = repaired_lease_binding;
        self.repair_plan = null;
        self.recovery_status = .clean;
        self.discarded_tail_bytes = 0;
        self.state = .repair_complete;
        return receipt;
    }

    /// Closing releases the advisory lock and invalidates the process-local
    /// lease. Caller-owned directory and storage buffers remain borrowed.
    pub fn close(self: *StoreV1) void {
        if (self.state == .closed) return;
        self.state = .closed;
        self.lease_generation = 0;
        self.file.close();
    }

    fn verifyCurrent(
        self: *StoreV1,
        expected_bytes: usize,
    ) Error!void {
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
        self.identity_check_count +|= 1;
    }

    fn observe(
        self: *StoreV1,
        phase: IoPhaseV1,
    ) Error!void {
        if (self.observer) |observer| try observer.after(phase);
    }

    fn requireAuthoritativeView(
        self: *const StoreV1,
    ) Error!void {
        switch (self.state) {
            .ready,
            .repair_required,
            .repair_complete,
            => {},
            .append_active,
            .repair_active,
            .poisoned,
            .closed,
            => return Error.InvalidStoreState,
        }
    }
};

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
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW"))
        return Error.UnsupportedPlatform;
    var flags: std.posix.O = .{ .ACCMODE = .RDWR };
    if (@hasField(std.posix.O, "CLOEXEC"))
        flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "NOCTTY"))
        flags.NOCTTY = true;
    if (@hasField(std.posix.O, "NOFOLLOW"))
        flags.NOFOLLOW = true;
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
        const nonblocking: i32 =
            if (lock_nonblocking) std.posix.LOCK.NB else 0;
        try std.posix.flock(
            fd,
            std.posix.LOCK.EX | nonblocking,
        );
    }
    if (lock_at_open and lock_nonblocking) {
        var file_flags = try std.posix.fcntl(
            fd,
            std.posix.F.GETFL,
            0,
        );
        file_flags &= ~@as(
            usize,
            1 << @bitOffsetOf(std.posix.O, "NONBLOCK"),
        );
        _ = try std.posix.fcntl(
            fd,
            std.posix.F.SETFL,
            file_flags,
        );
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
    const file_view = try inspectStat(
        file_stat,
        require_private_mode,
    );
    const entry_view = try inspectStat(
        entry_stat,
        require_private_mode,
    );
    if (!std.meta.eql(file_view, entry_view))
        return Error.StorageIdentityChanged;
    return file_view;
}

fn verifyInitial(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    require_private_mode: bool,
    expected_identity: FileIdentityV1,
    expected_size: usize,
) !void {
    const inspected = try inspectInitial(
        file,
        directory,
        name,
        require_private_mode,
    );
    if (!std.meta.eql(
        inspected.identity,
        expected_identity,
    ) or inspected.size != expected_size)
        return Error.StorageIdentityChanged;
}

fn inspectStat(
    stat: std.posix.Stat,
    require_private_mode: bool,
) Error!InspectedFile {
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG)
        return Error.InvalidStorage;
    if (stat.nlink != 1)
        return Error.MultipleLinks;
    if (require_private_mode and (stat.mode & 0o077) != 0)
        return Error.UnsafePermissions;
    const device = std.math.cast(u64, stat.dev) orelse
        return Error.InvalidStorage;
    const inode = std.math.cast(u64, stat.ino) orelse
        return Error.InvalidStorage;
    const size = std.math.cast(usize, stat.size) orelse
        return Error.CapacityExceeded;
    return .{
        .identity = .{
            .device = device,
            .inode = inode,
        },
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
    const device = std.math.cast(u64, stat.dev) orelse
        return null;
    const inode = std.math.cast(u64, stat.ino) orelse
        return null;
    const size = std.math.cast(usize, stat.size) orelse
        return null;
    return .{
        .identity = .{
            .device = device,
            .inode = inode,
        },
        .size = size,
    };
}

fn validateAcquire(
    name: []const u8,
    header: outbox.HeaderV1,
    journal_storage: []u8,
    record_storage: []outbox.RecordV1,
    state_storage: []outbox.ActionStateV1,
) Error!usize {
    if (name.len == 0 or name.len > max_name_bytes or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, "..") or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null)
        return Error.InvalidName;
    const max_file_bytes = try maximumFileBytesV1(header);
    if (journal_storage.len < max_file_bytes)
        return Error.BufferTooSmall;
    if (record_storage.len < header.maximum_records or
        state_storage.len < header.maximum_actions)
        return Error.CapacityExceeded;
    return max_file_bytes;
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
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return Error.UnsupportedPlatform;
    try std.posix.fsync(directory.fd);
}

fn verifyFileContent(
    file: std.fs.File,
    expected: []const u8,
) Error!void {
    var chunk: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < expected.len) {
        const chunk_bytes = @min(
            expected.len - offset,
            chunk.len,
        );
        const actual = chunk[0..chunk_bytes];
        const read_bytes = file.preadAll(
            actual,
            offset,
        ) catch return Error.StorageIo;
        if (read_bytes != chunk_bytes)
            return Error.StorageIo;
        if (!std.mem.eql(
            u8,
            actual,
            expected[offset .. offset + chunk_bytes],
        )) return Error.StorageContentChanged;
        offset += chunk_bytes;
    }
}

fn verifyFileContentParts(
    file: std.fs.File,
    first: []const u8,
    second: []const u8,
) Error!void {
    try verifyFileContent(file, first);
    var chunk: [4096]u8 = undefined;
    var relative_offset: usize = 0;
    while (relative_offset < second.len) {
        const chunk_bytes = @min(
            second.len - relative_offset,
            chunk.len,
        );
        const actual = chunk[0..chunk_bytes];
        const read_bytes = file.preadAll(
            actual,
            first.len + relative_offset,
        ) catch return Error.StorageIo;
        if (read_bytes != chunk_bytes)
            return Error.StorageIo;
        if (!std.mem.eql(
            u8,
            actual,
            second[relative_offset .. relative_offset + chunk_bytes],
        )) return Error.StorageContentChanged;
        relative_offset += chunk_bytes;
    }
}

fn sha256(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn sha256Parts(
    first: []const u8,
    second: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(first);
    hash.update(second);
    return finish(&hash);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn validTailShape(
    status: outbox.RecoveryStatusV1,
    discarded_tail_bytes: u64,
) bool {
    return switch (status) {
        .clean => discarded_tail_bytes == 0,
        .short_body_tail => discarded_tail_bytes > 0 and
            discarded_tail_bytes < outbox.record_body_bytes,
        .body_without_footer => discarded_tail_bytes == outbox.record_body_bytes,
        .partial_footer_tail => discarded_tail_bytes > outbox.record_body_bytes and
            discarded_tail_bytes < outbox.record_bytes,
    };
}

fn hashU8(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&[_]u8{value});
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn readAcquireSnapshot(
    file: std.fs.File,
    observed: []u8,
    journal_storage: []u8,
    record_storage: []outbox.RecordV1,
    state_storage: []outbox.ActionStateV1,
) Error!void {
    const read_bytes = file.preadAll(observed, 0) catch {
        clearAcquireOutputs(
            journal_storage,
            record_storage,
            state_storage,
        );
        return Error.StorageIo;
    };
    if (read_bytes != observed.len) {
        clearAcquireOutputs(
            journal_storage,
            record_storage,
            state_storage,
        );
        return Error.StorageIo;
    }
}

fn clearAcquireOutputs(
    journal_storage: []u8,
    record_storage: []outbox.RecordV1,
    state_storage: []outbox.ActionStateV1,
) void {
    @memset(journal_storage, 0);
    zeroRecords(record_storage);
    zeroStates(state_storage);
}

fn zeroRecords(values: []outbox.RecordV1) void {
    for (values) |*value| value.* = .{};
}

fn zeroStates(values: []outbox.ActionStateV1) void {
    for (values) |*value| value.* = .{};
}

const conformance = @import("tool_action_outbox_conformance.zig");

const InjectObserver = struct {
    phase: IoPhaseV1,
    calls: usize = 0,
    armed: bool = true,

    fn after(
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *InjectObserver =
            @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.armed and phase == self.phase)
            return Error.InjectedFault;
    }
};

fn referenceCampaign() !struct {
    header: outbox.HeaderV1,
    storage: conformance.ReferenceStorageV1,
    report: conformance.ReportV1,
} {
    var storage: conformance.ReferenceStorageV1 = .{};
    const report = try conformance.runReferenceCampaignV1(
        &storage,
    );
    return .{
        .header = try conformance.referenceHeaderV1(),
        .storage = storage,
        .report = report,
    };
}

test "durable outbox creates appends and reopens exact campaign" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var journal_storage: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    var store = try StoreV1.create(
        temporary.dir,
        "actions.outbox",
        fixture.header,
        .{},
        journal_storage[0..max_bytes],
        records[0..@intCast(fixture.header.maximum_records)],
        states[0..@intCast(fixture.header.maximum_actions)],
    );
    try std.testing.expectEqual(
        DirectorySyncStatusV1.synced,
        store.directory_sync_status,
    );
    try std.testing.expectEqual(outbox.header_bytes, store.committed_bytes);

    var locked_journal: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var locked_records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var locked_states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    try std.testing.expectError(
        error.WouldBlock,
        StoreV1.open(
            temporary.dir,
            "actions.outbox",
            fixture.header,
            .{},
            locked_journal[0..max_bytes],
            locked_records[0..@intCast(
                fixture.header.maximum_records,
            )],
            locked_states[0..@intCast(
                fixture.header.maximum_actions,
            )],
        ),
    );

    for (fixture.storage.records[0..conformance.reference_record_count]) |value| {
        const receipt = try store.appendRecord(value);
        try std.testing.expect(receipt.body_sync_exercised);
        try std.testing.expect(receipt.footer_sync_exercised);
    }
    try std.testing.expectEqual(
        conformance.reference_journal_bytes,
        store.committed_bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        fixture.storage.journal[0..fixture.storage.journal_length],
        try store.journal(),
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.report.final_chain_sha256,
        &store.final_chain_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.report.final_state_sha256,
        &store.state_sha256,
    );
    store.close();

    var reopened = try StoreV1.open(
        temporary.dir,
        "actions.outbox",
        fixture.header,
        .{},
        journal_storage[0..max_bytes],
        records[0..@intCast(fixture.header.maximum_records)],
        states[0..@intCast(fixture.header.maximum_actions)],
    );
    defer reopened.close();
    try std.testing.expectEqual(StoreStateV1.ready, reopened.state);
    try std.testing.expectEqual(
        conformance.reference_record_count,
        reopened.record_count,
    );
    try std.testing.expectEqual(
        conformance.reference_action_count,
        reopened.action_count,
    );
    try std.testing.expectEqualSlices(
        u8,
        fixture.storage.journal[0..fixture.storage.journal_length],
        try reopened.journal(),
    );
}

test "every append phase poisons without speculative state advance" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    for ([_]IoPhaseV1{
        .body_write,
        .body_sync,
        .footer_write,
        .footer_sync,
    }) |phase| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var observer: InjectObserver = .{ .phase = phase };
        var journal_storage: [
            outbox.header_bytes +
                outbox.maximum_supported_records *
                    outbox.record_bytes
        ]u8 = undefined;
        var records: [outbox.maximum_supported_records]outbox.RecordV1 =
            undefined;
        var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
            undefined;
        var store = try StoreV1.create(
            temporary.dir,
            "fault.outbox",
            fixture.header,
            .{
                .observer = .{
                    .context = &observer,
                    .after_phase_fn = InjectObserver.after,
                },
            },
            journal_storage[0..max_bytes],
            records[0..@intCast(
                fixture.header.maximum_records,
            )],
            states[0..@intCast(
                fixture.header.maximum_actions,
            )],
        );
        try std.testing.expectError(
            Error.InjectedFault,
            store.appendRecord(fixture.storage.records[0]),
        );
        try std.testing.expectEqual(
            StoreStateV1.poisoned,
            store.state,
        );
        try std.testing.expectEqual(@as(usize, 0), store.record_count);
        try std.testing.expectEqual(
            @as(u64, 0),
            store.ledger.committed_records,
        );
        try std.testing.expectError(
            Error.InvalidStoreState,
            store.journal(),
        );
        try std.testing.expectError(
            Error.InvalidStoreState,
            store.observedJournal(),
        );
        try std.testing.expectError(
            Error.InvalidStoreState,
            store.records(),
        );
        try std.testing.expectError(
            Error.InvalidStoreState,
            store.states(),
        );
        store.close();

        var reopened = try StoreV1.open(
            temporary.dir,
            "fault.outbox",
            fixture.header,
            .{},
            journal_storage[0..max_bytes],
            records[0..@intCast(
                fixture.header.maximum_records,
            )],
            states[0..@intCast(
                fixture.header.maximum_actions,
            )],
        );
        switch (phase) {
            .body_write, .body_sync => {
                try std.testing.expectEqual(
                    StoreStateV1.repair_required,
                    reopened.state,
                );
                const repair =
                    try reopened.repairIncompleteTail();
                try std.testing.expectEqual(
                    outbox.header_bytes,
                    repair.committed_bytes,
                );
                try std.testing.expectEqual(
                    outbox.record_body_bytes,
                    repair.discarded_tail_bytes,
                );
                try std.testing.expectEqual(
                    StoreStateV1.repair_complete,
                    reopened.state,
                );
                try std.testing.expectError(
                    Error.InvalidStoreState,
                    reopened.appendRecord(
                        fixture.storage.records[0],
                    ),
                );
            },
            .footer_write, .footer_sync => {
                try std.testing.expectEqual(
                    StoreStateV1.ready,
                    reopened.state,
                );
                try std.testing.expectEqual(
                    @as(usize, 1),
                    reopened.record_count,
                );
            },
            else => unreachable,
        }
        reopened.close();
    }
}

test "dispatch intent restart never exposes stale retry authority" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    for ([_]IoPhaseV1{
        .body_write,
        .body_sync,
        .footer_write,
        .footer_sync,
    }) |phase| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var observer: InjectObserver = .{
            .phase = phase,
            .armed = false,
        };
        var journal_storage: [
            outbox.header_bytes +
                outbox.maximum_supported_records *
                    outbox.record_bytes
        ]u8 = undefined;
        var records: [outbox.maximum_supported_records]outbox.RecordV1 =
            undefined;
        var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
            undefined;
        var store = try StoreV1.create(
            temporary.dir,
            "intent.outbox",
            fixture.header,
            .{
                .observer = .{
                    .context = &observer,
                    .after_phase_fn = InjectObserver.after,
                },
            },
            journal_storage[0..max_bytes],
            records[0..@intCast(
                fixture.header.maximum_records,
            )],
            states[0..@intCast(
                fixture.header.maximum_actions,
            )],
        );
        _ = try store.appendRecord(
            fixture.storage.records[0],
        );
        observer.armed = true;
        try std.testing.expectError(
            Error.InjectedFault,
            store.appendRecord(fixture.storage.records[1]),
        );
        try std.testing.expectError(
            Error.InvalidStoreState,
            store.states(),
        );
        store.close();

        var reopened = try StoreV1.open(
            temporary.dir,
            "intent.outbox",
            fixture.header,
            .{},
            journal_storage[0..max_bytes],
            records[0..@intCast(
                fixture.header.maximum_records,
            )],
            states[0..@intCast(
                fixture.header.maximum_actions,
            )],
        );
        switch (phase) {
            .body_write, .body_sync => {
                try std.testing.expectEqual(
                    StoreStateV1.repair_required,
                    reopened.state,
                );
                const committed_states =
                    try reopened.states();
                try std.testing.expectEqual(
                    outbox.ActionPhaseV1.ready,
                    committed_states[0].phase,
                );
                _ = try reopened.repairIncompleteTail();
                reopened.close();
                reopened = try StoreV1.open(
                    temporary.dir,
                    "intent.outbox",
                    fixture.header,
                    .{},
                    journal_storage[0..max_bytes],
                    records[0..@intCast(
                        fixture.header.maximum_records,
                    )],
                    states[0..@intCast(
                        fixture.header.maximum_actions,
                    )],
                );
                _ = try reopened.appendRecord(
                    fixture.storage.records[1],
                );
                try std.testing.expectEqual(
                    outbox.ActionPhaseV1.uncertain,
                    (try reopened.states())[0].phase,
                );
            },
            .footer_write, .footer_sync => {
                try std.testing.expectEqual(
                    StoreStateV1.ready,
                    reopened.state,
                );
                const committed_states =
                    try reopened.states();
                try std.testing.expectEqual(
                    outbox.ActionPhaseV1.uncertain,
                    committed_states[0].phase,
                );
                try std.testing.expectError(
                    Error.InvalidLifecycle,
                    outbox.makeTransitionRecordV1(
                        fixture.header,
                        3,
                        reopened.final_chain_sha256,
                        committed_states[0],
                        .dispatch_intent,
                        2,
                        zero_digest,
                        zero_digest,
                    ),
                );
            },
            else => unreachable,
        }
        reopened.close();
    }
}

test "complete corruption and wrong header never receive repair authority" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var journal_storage: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;

    {
        var complete: [outbox.header_bytes + outbox.record_bytes]u8 =
            undefined;
        @memcpy(
            &complete,
            fixture.storage.journal[0..complete.len],
        );
        complete[
            outbox.header_bytes +
                outbox.record_body_bytes
        ] ^= 0x01;
        const raw = try temporary.dir.createFile(
            "corrupt.outbox",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try raw.writeAll(&complete);
        try raw.sync();
        raw.close();
        try std.testing.expectError(
            Error.InvalidFooter,
            StoreV1.open(
                temporary.dir,
                "corrupt.outbox",
                fixture.header,
                .{},
                journal_storage[0..max_bytes],
                records[0..@intCast(
                    fixture.header.maximum_records,
                )],
                states[0..@intCast(
                    fixture.header.maximum_actions,
                )],
            ),
        );
        try std.testing.expectEqual(
            @as(u64, complete.len),
            (try temporary.dir.statFile(
                "corrupt.outbox",
            )).size,
        );
    }

    {
        var store = try StoreV1.create(
            temporary.dir,
            "header.outbox",
            fixture.header,
            .{},
            journal_storage[0..max_bytes],
            records[0..@intCast(
                fixture.header.maximum_records,
            )],
            states[0..@intCast(
                fixture.header.maximum_actions,
            )],
        );
        store.close();
        const alternate = try outbox.makeHeaderV1(
            fixture.header.outbox_epoch,
            fixture.header.outbox_id,
            fixture.header.tenant_key,
            fixture.header.maximum_actions,
            fixture.header.maximum_records,
            fixture.header.maximum_payload_bytes,
            fixture.header.adapter_descriptor_sha256,
            fixture.header.payload_store_descriptor_sha256,
            [_]u8{0xa5} ** 32,
        );
        try std.testing.expectError(
            Error.InvalidHeader,
            StoreV1.open(
                temporary.dir,
                "header.outbox",
                alternate,
                .{},
                journal_storage[0..max_bytes],
                records[0..@intCast(
                    fixture.header.maximum_records,
                )],
                states[0..@intCast(
                    fixture.header.maximum_actions,
                )],
            ),
        );
        try std.testing.expectEqual(
            @as(u64, outbox.header_bytes),
            (try temporary.dir.statFile(
                "header.outbox",
            )).size,
        );
        for (records[0..@intCast(
            fixture.header.maximum_records,
        )]) |value|
            try std.testing.expectEqual(
                outbox.RecordV1{},
                value,
            );
        for (states[0..@intCast(
            fixture.header.maximum_actions,
        )]) |value|
            try std.testing.expectEqual(
                outbox.ActionStateV1{},
                value,
            );
    }
}

test "outbox store rejects unsafe names links and permissions" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var journal_storage: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    for ([_][]const u8{
        "",
        ".",
        "..",
        "../escape",
        "a/b",
        "a\\b",
    }) |name| {
        try std.testing.expectError(
            Error.InvalidName,
            StoreV1.create(
                temporary.dir,
                name,
                fixture.header,
                .{},
                journal_storage[0..max_bytes],
                records[0..@intCast(
                    fixture.header.maximum_records,
                )],
                states[0..@intCast(
                    fixture.header.maximum_actions,
                )],
            ),
        );
    }

    {
        const target = try temporary.dir.createFile(
            "target",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        target.close();
        try temporary.dir.symLink(
            "target",
            "symlink",
            .{},
        );
        try std.testing.expectError(
            error.SymLinkLoop,
            StoreV1.open(
                temporary.dir,
                "symlink",
                fixture.header,
                .{},
                journal_storage[0..max_bytes],
                records[0..@intCast(
                    fixture.header.maximum_records,
                )],
                states[0..@intCast(
                    fixture.header.maximum_actions,
                )],
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
            StoreV1.open(
                temporary.dir,
                "target",
                fixture.header,
                .{},
                journal_storage[0..max_bytes],
                records[0..@intCast(
                    fixture.header.maximum_records,
                )],
                states[0..@intCast(
                    fixture.header.maximum_actions,
                )],
            ),
        );
    }

    {
        const public_file = try temporary.dir.createFile(
            "public",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o644,
            },
        );
        public_file.close();
        try std.testing.expectError(
            Error.UnsafePermissions,
            StoreV1.open(
                temporary.dir,
                "public",
                fixture.header,
                .{},
                journal_storage[0..max_bytes],
                records[0..@intCast(
                    fixture.header.maximum_records,
                )],
                states[0..@intCast(
                    fixture.header.maximum_actions,
                )],
            ),
        );
    }
}

const ReplaceObserver = struct {
    directory: std.fs.Dir,
    replaced: bool = false,

    fn after(
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *ReplaceObserver =
            @ptrCast(@alignCast(context));
        if (phase != .body_write or self.replaced) return;
        self.directory.rename(
            "stable.outbox",
            "moved.outbox",
        ) catch return Error.StorageIo;
        const replacement = self.directory.createFile(
            "stable.outbox",
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

const HeaderReplaceObserver = struct {
    directory: std.fs.Dir,
    replaced: bool = false,

    fn after(
        context: *anyopaque,
        phase: IoPhaseV1,
    ) Error!void {
        const self: *HeaderReplaceObserver =
            @ptrCast(@alignCast(context));
        if (phase != .header_write or self.replaced) return;
        self.directory.rename(
            "create.outbox",
            "moved-create.outbox",
        ) catch return Error.StorageIo;
        const replacement = self.directory.createFile(
            "create.outbox",
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

test "namespace replacement rejects header publication" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var observer: HeaderReplaceObserver = .{
        .directory = temporary.dir,
    };
    var journal_storage: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    try std.testing.expectError(
        Error.StorageIdentityChanged,
        StoreV1.create(
            temporary.dir,
            "create.outbox",
            fixture.header,
            .{
                .observer = .{
                    .context = &observer,
                    .after_phase_fn = HeaderReplaceObserver.after,
                },
            },
            journal_storage[0..max_bytes],
            records[0..@intCast(
                fixture.header.maximum_records,
            )],
            states[0..@intCast(
                fixture.header.maximum_actions,
            )],
        ),
    );
    try std.testing.expect(observer.replaced);
    try std.testing.expectEqual(
        @as(u64, 0),
        (try temporary.dir.statFile(
            "create.outbox",
        )).size,
    );
    try std.testing.expectEqual(
        @as(u64, outbox.header_bytes),
        (try temporary.dir.statFile(
            "moved-create.outbox",
        )).size,
    );
}

test "namespace replacement poisons before footer publication" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var observer: ReplaceObserver = .{
        .directory = temporary.dir,
    };
    var journal_storage: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    var store = try StoreV1.create(
        temporary.dir,
        "stable.outbox",
        fixture.header,
        .{
            .observer = .{
                .context = &observer,
                .after_phase_fn = ReplaceObserver.after,
            },
        },
        journal_storage[0..max_bytes],
        records[0..@intCast(fixture.header.maximum_records)],
        states[0..@intCast(fixture.header.maximum_actions)],
    );
    defer store.close();
    try std.testing.expectError(
        Error.StorageIdentityChanged,
        store.appendRecord(fixture.storage.records[0]),
    );
    try std.testing.expect(observer.replaced);
    try std.testing.expectEqual(StoreStateV1.poisoned, store.state);
    try std.testing.expectEqual(
        @as(u64, 0),
        (try temporary.dir.statFile("stable.outbox")).size,
    );
    try std.testing.expectEqual(
        @as(u64, outbox.header_bytes +
            outbox.record_body_bytes),
        (try temporary.dir.statFile("moved.outbox")).size,
    );
}

test "snapshot validators reject semantically invalid resealed values" {
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    const clean_recovery = try outbox.recoverV1(
        fixture.storage.journal[0..outbox.header_bytes],
        fixture.header.header_sha256,
        &records,
        &states,
    );
    const clean = try contentSnapshotFromRecoveryV1(
        fixture.storage.journal[0..outbox.header_bytes],
        max_bytes,
        clean_recovery,
        &states,
    );

    var zero_stream = clean;
    zero_stream.stream_sha256 = zero_digest;
    zero_stream.snapshot_sha256 =
        contentSnapshotSha256V1(zero_stream);
    try std.testing.expectError(
        Error.InvalidSnapshot,
        validateContentSnapshotV1(zero_stream),
    );

    var invalid_tail = clean;
    invalid_tail.observed_bytes += 1;
    invalid_tail.discarded_tail_bytes = 1;
    invalid_tail.snapshot_sha256 =
        contentSnapshotSha256V1(invalid_tail);
    try std.testing.expectError(
        Error.InvalidSnapshot,
        validateContentSnapshotV1(invalid_tail),
    );

    const torn_bytes =
        outbox.header_bytes +
        3 * outbox.record_bytes +
        outbox.record_body_bytes;
    const torn_recovery = try outbox.recoverV1(
        fixture.storage.journal[0..torn_bytes],
        fixture.header.header_sha256,
        &records,
        &states,
    );
    const torn = try contentSnapshotFromRecoveryV1(
        fixture.storage.journal[0..torn_bytes],
        max_bytes,
        torn_recovery,
        &states,
    );
    const lease = try makeLeaseBindingV1(
        fixture.header.outbox_epoch,
        1,
        torn,
    );
    var invalid_plan = try makeRepairPlanV1(torn, lease);
    invalid_plan.recovery_status = .short_body_tail;
    invalid_plan.plan_sha256 =
        repairPlanSha256V1(invalid_plan);
    try std.testing.expectError(
        Error.InvalidRepairPlan,
        validateRepairPlanV1(invalid_plan),
    );

    const maximum_header = try outbox.makeHeaderV1(
        fixture.header.outbox_epoch,
        fixture.header.outbox_id,
        fixture.header.tenant_key,
        outbox.maximum_supported_actions,
        outbox.maximum_supported_records,
        fixture.header.maximum_payload_bytes,
        fixture.header.adapter_descriptor_sha256,
        fixture.header.payload_store_descriptor_sha256,
        fixture.header.challenge_sha256,
    );
    var encoded_header: [outbox.header_bytes]u8 = undefined;
    _ = try outbox.encodeHeaderV1(
        maximum_header,
        &encoded_header,
    );
    const heap_records = try std.testing.allocator.alloc(
        outbox.RecordV1,
        outbox.maximum_supported_records,
    );
    defer std.testing.allocator.free(heap_records);
    const heap_states = try std.testing.allocator.alloc(
        outbox.ActionStateV1,
        outbox.maximum_supported_actions,
    );
    defer std.testing.allocator.free(heap_states);
    const maximum_recovery = try outbox.recoverV1(
        &encoded_header,
        maximum_header.header_sha256,
        heap_records,
        heap_states,
    );
    _ = try contentSnapshotFromRecoveryV1(
        &encoded_header,
        try maximumFileBytesV1(maximum_header),
        maximum_recovery,
        heap_states,
    );
}

test "short initial read clears all acquisition outputs" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(
        "short.outbox",
        .{ .read = true, .mode = 0o600 },
    );
    defer file.close();
    try file.pwriteAll(&[_]u8{7}, 0);

    var journal = [_]u8{0xa5} ** 4;
    var records = [_]outbox.RecordV1{
        .{ .sequence = 1 },
    };
    var states = [_]outbox.ActionStateV1{
        .{ .occupied = true },
    };
    try std.testing.expectError(
        Error.StorageIo,
        readAcquireSnapshot(
            file,
            journal[0..2],
            &journal,
            &records,
            &states,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 0 },
        &journal,
    );
    try std.testing.expect(std.meta.eql(
        records[0],
        outbox.RecordV1{},
    ));
    try std.testing.expect(std.meta.eql(
        states[0],
        outbox.ActionStateV1{},
    ));
}

test "pre-append storage drift revokes all live views" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var journal_storage: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;

    var changed = try StoreV1.create(
        temporary.dir,
        "changed.outbox",
        fixture.header,
        .{},
        journal_storage[0..max_bytes],
        records[0..@intCast(fixture.header.maximum_records)],
        states[0..@intCast(fixture.header.maximum_actions)],
    );
    try changed.file.pwriteAll(
        &[_]u8{1},
        outbox.header_bytes - 1,
    );
    try changed.file.sync();
    try std.testing.expectError(
        Error.StorageContentChanged,
        changed.appendRecord(fixture.storage.records[0]),
    );
    try std.testing.expectEqual(StoreStateV1.poisoned, changed.state);
    try std.testing.expectError(
        Error.InvalidStoreState,
        changed.journal(),
    );
    try std.testing.expectError(
        Error.InvalidStoreState,
        changed.records(),
    );
    try std.testing.expectError(
        Error.InvalidStoreState,
        changed.states(),
    );
    changed.close();

    var replaced = try StoreV1.create(
        temporary.dir,
        "replaced.outbox",
        fixture.header,
        .{},
        journal_storage[0..max_bytes],
        records[0..@intCast(fixture.header.maximum_records)],
        states[0..@intCast(fixture.header.maximum_actions)],
    );
    try temporary.dir.rename(
        "replaced.outbox",
        "replaced-original.outbox",
    );
    const replacement = try temporary.dir.createFile(
        "replaced.outbox",
        .{ .read = true, .mode = 0o600 },
    );
    replacement.close();
    try std.testing.expectError(
        Error.StorageIdentityChanged,
        replaced.appendRecord(fixture.storage.records[0]),
    );
    try std.testing.expectEqual(StoreStateV1.poisoned, replaced.state);
    try std.testing.expectError(
        Error.InvalidStoreState,
        replaced.journal(),
    );
    replaced.close();
}

test "pre-repair content drift revokes repair authority" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const fixture = try referenceCampaign();
    const max_bytes = try maximumFileBytesV1(fixture.header);
    const torn_bytes =
        outbox.header_bytes +
        3 * outbox.record_bytes +
        outbox.record_body_bytes;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const seed = try temporary.dir.createFile(
        "repair.outbox",
        .{ .read = true, .mode = 0o600 },
    );
    try seed.writeAll(
        fixture.storage.journal[0..torn_bytes],
    );
    try seed.sync();
    seed.close();

    var journal_storage: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined;
    var records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined;
    var states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined;
    var store = try StoreV1.open(
        temporary.dir,
        "repair.outbox",
        fixture.header,
        .{},
        journal_storage[0..max_bytes],
        records[0..@intCast(fixture.header.maximum_records)],
        states[0..@intCast(fixture.header.maximum_actions)],
    );
    defer store.close();
    try std.testing.expectEqual(
        StoreStateV1.repair_required,
        store.state,
    );
    try store.file.pwriteAll(
        &[_]u8{1},
        outbox.header_bytes - 1,
    );
    try store.file.sync();
    try std.testing.expectError(
        Error.StorageContentChanged,
        store.repairIncompleteTail(),
    );
    try std.testing.expectEqual(StoreStateV1.poisoned, store.state);
    try std.testing.expectError(
        Error.InvalidStoreState,
        store.observedJournal(),
    );
}
