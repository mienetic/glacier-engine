//! Deterministic W4b-c ActionOutbox storage conformance.
//!
//! This module replays logical write, sync, truncate, crash-persistence, and
//! explicit-repair outcomes over the portable ActionOutbox byte stream. It
//! performs no filesystem or process I/O. Host adapter observations remain a
//! separate evidence class and are not encoded in this retained report.

const std = @import("std");
const outbox = @import("tool_action_outbox_record.zig");
const protocol = @import("tool_action_outbox_conformance.zig");
const store = @import("tool_action_outbox_file.zig");

pub const Digest = outbox.Digest;
pub const zero_digest = outbox.zero_digest;

pub const report_abi: u64 = 0x4754_4f44_0000_0001;
pub const reference_record_count: usize =
    protocol.reference_record_count;
pub const reference_action_count: usize =
    protocol.reference_action_count;
pub const reference_journal_bytes: usize =
    protocol.reference_journal_bytes;
pub const reference_append_phase_case_count: usize =
    reference_record_count * 4;
pub const reference_partial_write_case_count: usize =
    (outbox.record_body_bytes + 1) +
    (outbox.commit_footer_bytes + 1);
pub const reference_repair_tail_case_count: usize =
    outbox.record_bytes - 1;
pub const reference_repair_fault_case_count: usize = 2 * 2 * 2;

const append_phase_case_domain =
    "glacier-action-outbox-store-append-phase-case-v1\x00";
const append_phase_matrix_domain =
    "glacier-action-outbox-store-append-phase-matrix-v1\x00";
const partial_write_case_domain =
    "glacier-action-outbox-store-partial-write-case-v1\x00";
const partial_write_matrix_domain =
    "glacier-action-outbox-store-partial-write-matrix-v1\x00";
const repair_tail_case_domain =
    "glacier-action-outbox-store-repair-tail-case-v1\x00";
const repair_tail_matrix_domain =
    "glacier-action-outbox-store-repair-tail-matrix-v1\x00";
const repair_fault_case_domain =
    "glacier-action-outbox-store-repair-fault-case-v1\x00";
const repair_fault_matrix_domain =
    "glacier-action-outbox-store-repair-fault-matrix-v1\x00";
const report_domain =
    "glacier-action-outbox-store-conformance-report-v1\x00";

pub const Error = outbox.Error || store.Error || protocol.Error || error{
    InvalidReferenceReport,
};

pub const AppendPhaseV1 = enum(u8) {
    body_write = 1,
    body_sync = 2,
    footer_write = 3,
    footer_sync = 4,
};

pub const RepairPhaseV1 = enum(u8) {
    repair_truncate = 1,
    repair_sync = 2,
};

const FaultTimingV1 = enum(u8) {
    before = 1,
    after = 2,
};

const PersistenceV1 = enum(u8) {
    lower = 1,
    upper = 2,
};

pub const append_phases = [_]AppendPhaseV1{
    .body_write,
    .body_sync,
    .footer_write,
    .footer_sync,
};

pub const repair_phases = [_]RepairPhaseV1{
    .repair_truncate,
    .repair_sync,
};

const fault_timings = [_]FaultTimingV1{
    .before,
    .after,
};

const persistence_choices = [_]PersistenceV1{
    .lower,
    .upper,
};

pub const ReportV1 = struct {
    abi_version: u64 = report_abi,
    store_abi: u64 = store.store_abi,
    protocol_report_abi: u64 = protocol.report_abi,
    header_bytes: u64 = outbox.header_bytes,
    record_body_bytes: u64 = outbox.record_body_bytes,
    commit_footer_bytes: u64 = outbox.commit_footer_bytes,
    record_bytes: u64 = outbox.record_bytes,
    maximum_file_bytes: u64 = 0,
    journal_bytes: u64 = reference_journal_bytes,
    record_count: u64 = reference_record_count,
    action_count: u64 = reference_action_count,
    append_phase_case_count: u64 =
        reference_append_phase_case_count,
    partial_write_case_count: u64 =
        reference_partial_write_case_count,
    repair_tail_case_count: u64 =
        reference_repair_tail_case_count,
    repair_fault_case_count: u64 =
        reference_repair_fault_case_count,
    header_sha256: Digest = zero_digest,
    protocol_report_sha256: Digest = zero_digest,
    journal_sha256: Digest = zero_digest,
    initial_snapshot_sha256: Digest = zero_digest,
    uncertain_snapshot_sha256: Digest = zero_digest,
    final_snapshot_sha256: Digest = zero_digest,
    append_phase_matrix_sha256: Digest = zero_digest,
    partial_write_matrix_sha256: Digest = zero_digest,
    repair_tail_matrix_sha256: Digest = zero_digest,
    repair_fault_matrix_sha256: Digest = zero_digest,
    final_chain_sha256: Digest = zero_digest,
    final_state_sha256: Digest = zero_digest,
    ledger_sha256: Digest = zero_digest,
    report_sha256: Digest = zero_digest,
    append_phase_order: [append_phases.len]AppendPhaseV1 =
        append_phases,
    repair_phase_order: [repair_phases.len]RepairPhaseV1 =
        repair_phases,
    summary: outbox.LedgerV1 = .{},
};

pub const ReferenceStorageV1 = struct {
    protocol_storage: protocol.ReferenceStorageV1 = .{},
};

fn snapshotAt(
    storage: *ReferenceStorageV1,
    header: outbox.HeaderV1,
    maximum_bytes: usize,
    length: usize,
) Error!store.ContentSnapshotV1 {
    if (length < outbox.header_bytes or
        length > storage.protocol_storage.journal_length)
        return Error.InvalidReferenceReport;
    const recovered = try outbox.recoverV1(
        storage.protocol_storage.journal[0..length],
        header.header_sha256,
        &storage.protocol_storage.replay_records,
        &storage.protocol_storage.replay_states,
    );
    return store.contentSnapshotFromRecoveryV1(
        storage.protocol_storage.journal[0..length],
        maximum_bytes,
        recovered,
        &storage.protocol_storage.replay_states,
    );
}

fn appendPhaseMatrixSha256V1(
    storage: *ReferenceStorageV1,
    header: outbox.HeaderV1,
    maximum_bytes: usize,
) Error!Digest {
    var matrix = std.crypto.hash.sha2.Sha256.init(.{});
    matrix.update(append_phase_matrix_domain);
    hashU64(&matrix, reference_append_phase_case_count);

    for (0..reference_record_count) |record_index| {
        const sequence = record_index + 1;
        const prior_bytes =
            outbox.header_bytes +
            record_index * outbox.record_bytes;
        for (append_phases) |phase| {
            const persisted_bytes = switch (phase) {
                .body_write, .body_sync => prior_bytes + outbox.record_body_bytes,
                .footer_write, .footer_sync => prior_bytes + outbox.record_bytes,
            };
            const snapshot = try snapshotAt(
                storage,
                header,
                maximum_bytes,
                persisted_bytes,
            );
            var leaf = std.crypto.hash.sha2.Sha256.init(.{});
            leaf.update(append_phase_case_domain);
            hashU64(&leaf, sequence);
            hashU8(&leaf, @intFromEnum(phase));
            hashU64(&leaf, persisted_bytes);
            hashU8(
                &leaf,
                @intFromEnum(snapshot.recovery_status),
            );
            hashU64(&leaf, snapshot.committed_bytes);
            hashU64(&leaf, snapshot.discarded_tail_bytes);
            hashU64(&leaf, snapshot.committed_records);
            leaf.update(&snapshot.final_chain_sha256);
            leaf.update(&snapshot.state_sha256);
            leaf.update(&snapshot.ledger_sha256);
            leaf.update(&snapshot.snapshot_sha256);
            const leaf_sha256 = finish(&leaf);
            matrix.update(&leaf_sha256);
        }
    }
    return finish(&matrix);
}

fn partialWriteMatrixSha256V1(
    storage: *ReferenceStorageV1,
    header: outbox.HeaderV1,
    maximum_bytes: usize,
) Error!Digest {
    const prior_bytes =
        outbox.header_bytes + 3 * outbox.record_bytes;
    var matrix = std.crypto.hash.sha2.Sha256.init(.{});
    matrix.update(partial_write_matrix_domain);
    hashU64(&matrix, reference_partial_write_case_count);

    for (0..outbox.record_body_bytes + 1) |prefix| {
        const persisted_bytes = prior_bytes + prefix;
        const snapshot = try snapshotAt(
            storage,
            header,
            maximum_bytes,
            persisted_bytes,
        );
        var leaf = std.crypto.hash.sha2.Sha256.init(.{});
        leaf.update(partial_write_case_domain);
        hashU8(&leaf, 1);
        hashU64(&leaf, prefix);
        hashU64(&leaf, persisted_bytes);
        hashU8(
            &leaf,
            @intFromEnum(snapshot.recovery_status),
        );
        hashU64(&leaf, snapshot.committed_bytes);
        hashU64(&leaf, snapshot.discarded_tail_bytes);
        hashU64(&leaf, snapshot.committed_records);
        leaf.update(&snapshot.final_chain_sha256);
        leaf.update(&snapshot.state_sha256);
        leaf.update(&snapshot.ledger_sha256);
        leaf.update(&snapshot.snapshot_sha256);
        const leaf_sha256 = finish(&leaf);
        matrix.update(&leaf_sha256);
    }

    for (0..outbox.commit_footer_bytes + 1) |prefix| {
        const persisted_bytes =
            prior_bytes + outbox.record_body_bytes + prefix;
        const snapshot = try snapshotAt(
            storage,
            header,
            maximum_bytes,
            persisted_bytes,
        );
        var leaf = std.crypto.hash.sha2.Sha256.init(.{});
        leaf.update(partial_write_case_domain);
        hashU8(&leaf, 2);
        hashU64(&leaf, prefix);
        hashU64(&leaf, persisted_bytes);
        hashU8(
            &leaf,
            @intFromEnum(snapshot.recovery_status),
        );
        hashU64(&leaf, snapshot.committed_bytes);
        hashU64(&leaf, snapshot.discarded_tail_bytes);
        hashU64(&leaf, snapshot.committed_records);
        leaf.update(&snapshot.final_chain_sha256);
        leaf.update(&snapshot.state_sha256);
        leaf.update(&snapshot.ledger_sha256);
        leaf.update(&snapshot.snapshot_sha256);
        const leaf_sha256 = finish(&leaf);
        matrix.update(&leaf_sha256);
    }
    return finish(&matrix);
}

fn repairTailMatrixSha256V1(
    storage: *ReferenceStorageV1,
    header: outbox.HeaderV1,
    maximum_bytes: usize,
) Error!Digest {
    const prior_bytes =
        outbox.header_bytes + 3 * outbox.record_bytes;
    const repaired_snapshot = try snapshotAt(
        storage,
        header,
        maximum_bytes,
        prior_bytes,
    );
    const restored_snapshot = try snapshotAt(
        storage,
        header,
        maximum_bytes,
        prior_bytes + outbox.record_bytes,
    );
    var matrix = std.crypto.hash.sha2.Sha256.init(.{});
    matrix.update(repair_tail_matrix_domain);
    hashU64(&matrix, reference_repair_tail_case_count);

    for (1..outbox.record_bytes) |tail_bytes| {
        const pre_snapshot = try snapshotAt(
            storage,
            header,
            maximum_bytes,
            prior_bytes + tail_bytes,
        );
        const lease = try store.makeLeaseBindingV1(
            header.outbox_epoch,
            1,
            pre_snapshot,
        );
        const plan = try store.makeRepairPlanV1(
            pre_snapshot,
            lease,
        );
        var leaf = std.crypto.hash.sha2.Sha256.init(.{});
        leaf.update(repair_tail_case_domain);
        hashU64(&leaf, tail_bytes);
        leaf.update(&pre_snapshot.snapshot_sha256);
        leaf.update(&plan.plan_sha256);
        leaf.update(&repaired_snapshot.snapshot_sha256);
        leaf.update(&restored_snapshot.snapshot_sha256);
        const leaf_sha256 = finish(&leaf);
        matrix.update(&leaf_sha256);
    }
    return finish(&matrix);
}

fn repairFaultMatrixSha256V1(
    storage: *ReferenceStorageV1,
    header: outbox.HeaderV1,
    maximum_bytes: usize,
) Error!Digest {
    const committed_bytes =
        outbox.header_bytes + 3 * outbox.record_bytes;
    const torn_bytes =
        committed_bytes + outbox.record_body_bytes + 7;
    const pre_snapshot = try snapshotAt(
        storage,
        header,
        maximum_bytes,
        torn_bytes,
    );
    const lease = try store.makeLeaseBindingV1(
        header.outbox_epoch,
        1,
        pre_snapshot,
    );
    const plan = try store.makeRepairPlanV1(
        pre_snapshot,
        lease,
    );

    var matrix = std.crypto.hash.sha2.Sha256.init(.{});
    matrix.update(repair_fault_matrix_domain);
    hashU64(&matrix, reference_repair_fault_case_count);
    for (repair_phases) |phase| {
        for (fault_timings) |timing| {
            for (persistence_choices) |persistence| {
                const truncate_applied =
                    phase == .repair_sync or timing == .after;
                const sync_applied =
                    phase == .repair_sync and timing == .after;
                const lower_bytes: usize = if (!truncate_applied)
                    torn_bytes
                else
                    committed_bytes;
                const upper_bytes: usize = if (!truncate_applied)
                    torn_bytes
                else if (sync_applied)
                    committed_bytes
                else
                    torn_bytes;
                const persisted_bytes = switch (persistence) {
                    .lower => lower_bytes,
                    .upper => upper_bytes,
                };
                const reopened_snapshot = try snapshotAt(
                    storage,
                    header,
                    maximum_bytes,
                    persisted_bytes,
                );
                const action: u8 =
                    if (reopened_snapshot.recovery_status == .clean)
                        1
                    else
                        2;

                var leaf = std.crypto.hash.sha2.Sha256.init(.{});
                leaf.update(repair_fault_case_domain);
                hashU8(&leaf, @intFromEnum(phase));
                hashU8(&leaf, @intFromEnum(timing));
                hashU8(&leaf, @intFromEnum(persistence));
                hashU64(&leaf, persisted_bytes);
                hashU8(&leaf, action);
                leaf.update(&pre_snapshot.snapshot_sha256);
                leaf.update(&plan.plan_sha256);
                leaf.update(&reopened_snapshot.snapshot_sha256);
                const leaf_sha256 = finish(&leaf);
                matrix.update(&leaf_sha256);
            }
        }
    }
    return finish(&matrix);
}

pub fn reportSha256V1(value: ReportV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(report_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.store_abi);
    hashU64(&hash, value.protocol_report_abi);
    hashU64(&hash, value.header_bytes);
    hashU64(&hash, value.record_body_bytes);
    hashU64(&hash, value.commit_footer_bytes);
    hashU64(&hash, value.record_bytes);
    hashU64(&hash, value.maximum_file_bytes);
    hashU64(&hash, value.journal_bytes);
    hashU64(&hash, value.record_count);
    hashU64(&hash, value.action_count);
    hashU64(&hash, value.append_phase_case_count);
    hashU64(&hash, value.partial_write_case_count);
    hashU64(&hash, value.repair_tail_case_count);
    hashU64(&hash, value.repair_fault_case_count);
    hash.update(&value.header_sha256);
    hash.update(&value.protocol_report_sha256);
    hash.update(&value.journal_sha256);
    hash.update(&value.initial_snapshot_sha256);
    hash.update(&value.uncertain_snapshot_sha256);
    hash.update(&value.final_snapshot_sha256);
    hash.update(&value.append_phase_matrix_sha256);
    hash.update(&value.partial_write_matrix_sha256);
    hash.update(&value.repair_tail_matrix_sha256);
    hash.update(&value.repair_fault_matrix_sha256);
    hash.update(&value.final_chain_sha256);
    hash.update(&value.final_state_sha256);
    hash.update(&value.ledger_sha256);
    for (value.append_phase_order) |phase| {
        hashU8(&hash, @intFromEnum(phase));
    }
    for (value.repair_phase_order) |phase| {
        hashU8(&hash, @intFromEnum(phase));
    }
    hashLedger(&hash, value.summary);
    return finish(&hash);
}

pub fn runReferenceCampaignV1(
    storage: *ReferenceStorageV1,
) Error!ReportV1 {
    const protocol_report =
        try protocol.runReferenceCampaignV1(
            &storage.protocol_storage,
        );
    const header = try protocol.referenceHeaderV1();
    const maximum_bytes =
        try store.maximumFileBytesV1(header);
    const initial_snapshot = try snapshotAt(
        storage,
        header,
        maximum_bytes,
        outbox.header_bytes,
    );
    const uncertain_snapshot = try snapshotAt(
        storage,
        header,
        maximum_bytes,
        outbox.header_bytes + 3 * outbox.record_bytes,
    );
    const final_snapshot = try snapshotAt(
        storage,
        header,
        maximum_bytes,
        reference_journal_bytes,
    );
    var journal_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        storage.protocol_storage
            .journal[0..reference_journal_bytes],
        &journal_sha256,
        .{},
    );

    var result: ReportV1 = .{
        .maximum_file_bytes = @intCast(maximum_bytes),
        .header_sha256 = header.header_sha256,
        .protocol_report_sha256 = protocol_report.report_sha256,
        .journal_sha256 = journal_sha256,
        .initial_snapshot_sha256 = initial_snapshot.snapshot_sha256,
        .uncertain_snapshot_sha256 = uncertain_snapshot.snapshot_sha256,
        .final_snapshot_sha256 = final_snapshot.snapshot_sha256,
        .append_phase_matrix_sha256 = try appendPhaseMatrixSha256V1(
            storage,
            header,
            maximum_bytes,
        ),
        .partial_write_matrix_sha256 = try partialWriteMatrixSha256V1(
            storage,
            header,
            maximum_bytes,
        ),
        .repair_tail_matrix_sha256 = try repairTailMatrixSha256V1(
            storage,
            header,
            maximum_bytes,
        ),
        .repair_fault_matrix_sha256 = try repairFaultMatrixSha256V1(
            storage,
            header,
            maximum_bytes,
        ),
        .final_chain_sha256 = protocol_report.final_chain_sha256,
        .final_state_sha256 = protocol_report.final_state_sha256,
        .ledger_sha256 = protocol_report.ledger_sha256,
        .summary = protocol_report.summary,
    };
    result.report_sha256 = reportSha256V1(result);
    try validateReportShapeV1(result);
    return result;
}

fn validateReportShapeV1(value: ReportV1) Error!void {
    if (value.abi_version != report_abi or
        value.store_abi != store.store_abi or
        value.protocol_report_abi != protocol.report_abi or
        value.header_bytes != outbox.header_bytes or
        value.record_body_bytes != outbox.record_body_bytes or
        value.commit_footer_bytes != outbox.commit_footer_bytes or
        value.record_bytes != outbox.record_bytes or
        value.journal_bytes != reference_journal_bytes or
        value.record_count != reference_record_count or
        value.action_count != reference_action_count or
        value.append_phase_case_count !=
            reference_append_phase_case_count or
        value.partial_write_case_count !=
            reference_partial_write_case_count or
        value.repair_tail_case_count !=
            reference_repair_tail_case_count or
        value.repair_fault_case_count !=
            reference_repair_fault_case_count or
        !std.meta.eql(
            value.append_phase_order,
            append_phases,
        ) or
        !std.meta.eql(
            value.repair_phase_order,
            repair_phases,
        ) or
        digestIsZero(value.header_sha256) or
        digestIsZero(value.protocol_report_sha256) or
        digestIsZero(value.journal_sha256) or
        digestIsZero(value.initial_snapshot_sha256) or
        digestIsZero(value.uncertain_snapshot_sha256) or
        digestIsZero(value.final_snapshot_sha256) or
        digestIsZero(value.append_phase_matrix_sha256) or
        digestIsZero(value.partial_write_matrix_sha256) or
        digestIsZero(value.repair_tail_matrix_sha256) or
        digestIsZero(value.repair_fault_matrix_sha256) or
        digestIsZero(value.final_chain_sha256) or
        digestIsZero(value.final_state_sha256) or
        digestIsZero(value.ledger_sha256) or
        digestIsZero(value.report_sha256) or
        !digestEqual(
            value.ledger_sha256,
            outbox.ledgerSha256V1(value.summary),
        ) or
        !digestEqual(
            value.report_sha256,
            reportSha256V1(value),
        ))
        return Error.InvalidReferenceReport;
}

pub fn validateReportV1(value: ReportV1) Error!void {
    var storage: ReferenceStorageV1 = .{};
    const actual = try runReferenceCampaignV1(&storage);
    if (!std.meta.eql(actual, value))
        return Error.InvalidReferenceReport;
}

pub fn validateReportByReplayV1(
    expected: ReportV1,
    storage: *ReferenceStorageV1,
) Error!void {
    try validateReportShapeV1(expected);
    const actual = try runReferenceCampaignV1(storage);
    if (!std.meta.eql(actual, expected))
        return Error.InvalidReferenceReport;
}

fn hashLedger(
    hash: *std.crypto.hash.sha2.Sha256,
    ledger: outbox.LedgerV1,
) void {
    inline for (std.meta.fields(outbox.LedgerV1)) |field| {
        hashU64(hash, @field(ledger, field.name));
    }
}

fn hashU8(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&[_]u8{value});
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &encoded,
        @as(u64, @intCast(value)),
        .little,
    );
    hash.update(&encoded);
}

fn finish(
    hash: *std.crypto.hash.sha2.Sha256,
) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digestIsZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

test "retained storage report replays every deterministic case" {
    var storage: ReferenceStorageV1 = .{};
    const report = try runReferenceCampaignV1(&storage);
    var replay: ReferenceStorageV1 = .{};
    try validateReportByReplayV1(report, &replay);
    try std.testing.expectEqual(
        @as(u64, reference_append_phase_case_count),
        report.append_phase_case_count,
    );
    try std.testing.expectEqual(
        @as(u64, reference_partial_write_case_count),
        report.partial_write_case_count,
    );
    try std.testing.expectEqual(
        @as(u64, reference_repair_tail_case_count),
        report.repair_tail_case_count,
    );
    try std.testing.expectEqual(
        @as(u64, reference_repair_fault_case_count),
        report.repair_fault_case_count,
    );
}

test "semantic report substitution rejects after reseal" {
    var storage: ReferenceStorageV1 = .{};
    const report = try runReferenceCampaignV1(&storage);
    var mutated = report;
    mutated.summary.safe_retry_dispatches += 1;
    mutated.ledger_sha256 =
        outbox.ledgerSha256V1(mutated.summary);
    mutated.report_sha256 = reportSha256V1(mutated);
    try std.testing.expectError(
        Error.InvalidReferenceReport,
        validateReportV1(mutated),
    );

    mutated = report;
    mutated.partial_write_matrix_sha256[0] ^= 1;
    mutated.report_sha256 = reportSha256V1(mutated);
    try std.testing.expectError(
        Error.InvalidReferenceReport,
        validateReportV1(mutated),
    );
}
