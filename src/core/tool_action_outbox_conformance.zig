//! Retained W4b-b ActionOutbox record and recovery conformance.
//!
//! The campaign is credential-free and performs no external dispatch or I/O.
//! It retains one primary action, one separately authorized compensation
//! action, every canonical frame, all retained cuts from the complete header
//! through the final journal, and the final closed journal roots.

const std = @import("std");
const action = @import("tool_action_contract.zig");
const outbox = @import("tool_action_outbox_record.zig");

pub const Digest = outbox.Digest;
pub const zero_digest = outbox.zero_digest;

pub const report_abi: u64 = 0x4754_4f50_0000_0001;
pub const reference_record_count: usize = 10;
pub const reference_action_count: usize = 2;
pub const reference_journal_bytes: usize =
    outbox.header_bytes +
    reference_record_count * outbox.record_bytes;

const recovery_matrix_domain =
    "glacier-action-outbox-recovery-matrix-v1\x00";
const recovery_leaf_domain =
    "glacier-action-outbox-recovery-leaf-v1\x00";
const torn_case_domain =
    "glacier-action-outbox-torn-case-v1\x00";
const report_domain =
    "glacier-action-outbox-conformance-report-v1\x00";

pub const Error = outbox.Error || error{
    InvalidReferenceReport,
};

pub const ReportV1 = struct {
    abi_version: u64 = report_abi,
    header_bytes: u64 = outbox.header_bytes,
    record_body_bytes: u64 = outbox.record_body_bytes,
    commit_footer_bytes: u64 = outbox.commit_footer_bytes,
    record_bytes: u64 = outbox.record_bytes,
    record_count: u64 = reference_record_count,
    action_count: u64 = reference_action_count,
    journal_bytes: u64 = reference_journal_bytes,
    header_sha256: Digest = zero_digest,
    primary_proposal_sha256: Digest = zero_digest,
    primary_authorization_sha256: Digest = zero_digest,
    primary_action_sha256: Digest = zero_digest,
    compensation_proposal_sha256: Digest = zero_digest,
    compensation_authorization_sha256: Digest = zero_digest,
    compensation_action_sha256: Digest = zero_digest,
    record_section_sha256: Digest = zero_digest,
    final_chain_sha256: Digest = zero_digest,
    final_state_sha256: Digest = zero_digest,
    ledger_sha256: Digest = zero_digest,
    closed_anchor_sha256: Digest = zero_digest,
    recovery_matrix_sha256: Digest = zero_digest,
    torn_case_sha256: Digest = zero_digest,
    event_kinds: [reference_record_count]outbox.EventKindV1 =
        undefined,
    attempt_generations: [reference_record_count]u64 =
        [_]u64{0} ** reference_record_count,
    summary: outbox.LedgerV1 = .{},
    report_sha256: Digest = zero_digest,
};

pub const ReferenceStorageV1 = struct {
    journal: [reference_journal_bytes]u8 = undefined,
    journal_length: usize = 0,
    records: [reference_record_count]outbox.RecordV1 =
        [_]outbox.RecordV1{.{}} ** reference_record_count,
    record_count: usize = 0,
    states: [4]outbox.ActionStateV1 =
        [_]outbox.ActionStateV1{.{}} ** 4,
    ledger: outbox.LedgerV1 = .{},
    final_chain_sha256: Digest = zero_digest,
    replay_records: [32]outbox.RecordV1 =
        [_]outbox.RecordV1{.{}} ** 32,
    replay_states: [4]outbox.ActionStateV1 =
        [_]outbox.ActionStateV1{.{}} ** 4,

    fn init(self: *ReferenceStorageV1, header: outbox.HeaderV1) !void {
        @memset(&self.journal, 0);
        self.journal_length = outbox.header_bytes;
        self.records = [_]outbox.RecordV1{.{}} **
            reference_record_count;
        self.record_count = 0;
        self.states = [_]outbox.ActionStateV1{.{}} ** 4;
        self.ledger = .{};
        self.final_chain_sha256 = header.header_sha256;
        self.replay_records = [_]outbox.RecordV1{.{}} ** 32;
        self.replay_states = [_]outbox.ActionStateV1{.{}} ** 4;
        _ = try outbox.encodeHeaderV1(
            header,
            self.journal[0..outbox.header_bytes],
        );
    }

    fn append(
        self: *ReferenceStorageV1,
        header: outbox.HeaderV1,
        record: outbox.RecordV1,
    ) !void {
        if (self.record_count >= reference_record_count)
            return Error.CapacityExceeded;
        try outbox.applyRecordV1(
            header,
            record,
            &self.states,
            &self.ledger,
        );
        _ = try outbox.encodeRecordV1(
            header,
            record,
            self.journal[self.journal_length .. self.journal_length + outbox.record_bytes],
        );
        self.records[self.record_count] = record;
        self.record_count += 1;
        self.journal_length += outbox.record_bytes;
        self.final_chain_sha256 = record.record_sha256;
    }

    fn enqueue(
        self: *ReferenceStorageV1,
        header: outbox.HeaderV1,
        identity: outbox.ActionIdentityV1,
    ) !void {
        try self.append(
            header,
            try outbox.makeEnqueuedRecordV1(
                header,
                self.record_count + 1,
                self.final_chain_sha256,
                identity,
            ),
        );
    }

    fn transition(
        self: *ReferenceStorageV1,
        header: outbox.HeaderV1,
        action_sha256: Digest,
        kind: outbox.EventKindV1,
        attempt_generation: u64,
        observation_sha256: Digest,
        result_sha256: Digest,
    ) !void {
        const state = findState(
            &self.states,
            action_sha256,
        ) orelse return Error.InvalidLifecycle;
        try self.append(
            header,
            try outbox.makeTransitionRecordV1(
                header,
                self.record_count + 1,
                self.final_chain_sha256,
                state,
                kind,
                attempt_generation,
                observation_sha256,
                result_sha256,
            ),
        );
    }
};

const ActionPartsV1 = struct {
    descriptor: action.DescriptorV1,
    arguments: action.BoundedAddArgumentsV1,
    proposal: action.ActionProposalV1,
    policy: action.PolicyV1,
    authorization: action.AuthorizationReceiptV1,
};

pub fn referenceHeaderV1() Error!outbox.HeaderV1 {
    return outbox.makeHeaderV1(
        7,
        9,
        41,
        4,
        32,
        4096,
        digest("adapter"),
        digest("payload store"),
        digest("outbox challenge"),
    );
}

fn referenceActionPartsV1(
    ordinal: u64,
    idempotency_label: []const u8,
    delta: i64,
    before: i64,
) !ActionPartsV1 {
    const descriptor = try action.makeDescriptorV1(
        3,
        digest("tool namespace"),
        digest("arguments schema"),
        digest("result schema"),
        digest("implementation"),
    );
    const arguments = try action.makeBoundedAddArgumentsV1(88, delta);
    const proposal = try action.makeActionProposalV1(
        41,
        ordinal,
        digest("agent request"),
        descriptor,
        arguments,
        digest(idempotency_label),
    );
    const policy = try action.makePolicyV1(
        5,
        41,
        true,
        16,
        -100,
        100,
        descriptor,
        digest("policy challenge"),
    );
    return .{
        .descriptor = descriptor,
        .arguments = arguments,
        .proposal = proposal,
        .policy = policy,
        .authorization = try action.authorizeBoundedAddV1(
            proposal,
            descriptor,
            arguments,
            policy,
            before,
        ),
    };
}

fn referenceIdentityV1(
    header: outbox.HeaderV1,
    purpose: outbox.ActionPurposeV1,
    parent_action_sha256: Digest,
    parts: ActionPartsV1,
    payload_locator_label: []const u8,
) !outbox.ActionIdentityV1 {
    return outbox.makeActionIdentityV1(
        header,
        purpose,
        parent_action_sha256,
        parts.descriptor,
        parts.arguments,
        parts.proposal,
        parts.policy,
        parts.authorization,
        digest("service event"),
        digest(payload_locator_label),
        32,
        digest("payload bytes"),
    );
}

pub fn runReferenceCampaignV1(
    storage: *ReferenceStorageV1,
) Error!ReportV1 {
    const header = try referenceHeaderV1();
    try storage.init(header);

    const primary_parts = try referenceActionPartsV1(
        1,
        "primary key",
        3,
        0,
    );
    const primary = try referenceIdentityV1(
        header,
        .primary,
        zero_digest,
        primary_parts,
        "primary payload",
    );
    try storage.enqueue(header, primary);
    try storage.transition(
        header,
        primary.action_sha256,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try storage.transition(
        header,
        primary.action_sha256,
        .ambiguity_observed,
        1,
        digest("timeout observation"),
        zero_digest,
    );
    try storage.transition(
        header,
        primary.action_sha256,
        .reconciled_not_applied,
        1,
        digest("not applied evidence"),
        zero_digest,
    );
    try storage.transition(
        header,
        primary.action_sha256,
        .dispatch_intent,
        2,
        zero_digest,
        zero_digest,
    );
    try storage.transition(
        header,
        primary.action_sha256,
        .acknowledged_success,
        2,
        digest("success acknowledgement"),
        digest("primary result"),
    );

    const compensation_parts = try referenceActionPartsV1(
        2,
        "compensation key",
        -3,
        3,
    );
    const compensation = try referenceIdentityV1(
        header,
        .compensation,
        primary.action_sha256,
        compensation_parts,
        "compensation payload",
    );
    try storage.enqueue(header, compensation);
    try storage.transition(
        header,
        compensation.action_sha256,
        .dispatch_intent,
        1,
        zero_digest,
        zero_digest,
    );
    try storage.transition(
        header,
        compensation.action_sha256,
        .ambiguity_observed,
        1,
        digest("compensation timeout"),
        zero_digest,
    );
    try storage.transition(
        header,
        compensation.action_sha256,
        .reconciled_success,
        1,
        digest("compensation status"),
        digest("compensation result"),
    );
    if (storage.record_count != reference_record_count or
        storage.journal_length != reference_journal_bytes)
        return Error.InvalidReferenceReport;

    const recovered = try outbox.recoverV1(
        storage.journal[0..storage.journal_length],
        header.header_sha256,
        &storage.replay_records,
        &storage.replay_states,
    );
    const anchor = try outbox.makeClosedAnchorV1(recovered);
    var record_section_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        storage.journal[outbox.header_bytes..storage.journal_length],
        &record_section_sha256,
        .{},
    );

    var result: ReportV1 = .{
        .header_sha256 = header.header_sha256,
        .primary_proposal_sha256 = primary_parts.proposal.proposal_sha256,
        .primary_authorization_sha256 = primary_parts.authorization.authorization_sha256,
        .primary_action_sha256 = primary.action_sha256,
        .compensation_proposal_sha256 = compensation_parts.proposal.proposal_sha256,
        .compensation_authorization_sha256 = compensation_parts.authorization.authorization_sha256,
        .compensation_action_sha256 = compensation.action_sha256,
        .record_section_sha256 = record_section_sha256,
        .final_chain_sha256 = recovered.final_chain_sha256,
        .final_state_sha256 = recovered.state_sha256,
        .ledger_sha256 = outbox.ledgerSha256V1(recovered.ledger),
        .closed_anchor_sha256 = anchor.anchor_sha256,
        .recovery_matrix_sha256 = try recoveryMatrixSha256V1(
            storage,
            header,
        ),
        .torn_case_sha256 = try tornCaseSha256V1(
            storage,
            header,
        ),
        .summary = recovered.ledger,
    };
    for (storage.records, 0..) |record, index| {
        result.event_kinds[index] = record.kind;
        result.attempt_generations[index] =
            record.attempt_generation;
    }
    result.report_sha256 = reportSha256V1(result);
    try validateReportShapeV1(result);
    return result;
}

fn recoveryMatrixSha256V1(
    storage: *ReferenceStorageV1,
    header: outbox.HeaderV1,
) Error!Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(recovery_matrix_domain);
    hashU64(&hash, outbox.header_bytes);
    hashU64(&hash, storage.journal_length);
    for (outbox.header_bytes..storage.journal_length + 1) |cut| {
        const recovered = try outbox.recoverV1(
            storage.journal[0..cut],
            header.header_sha256,
            &storage.replay_records,
            &storage.replay_states,
        );
        var leaf = std.crypto.hash.sha2.Sha256.init(.{});
        leaf.update(recovery_leaf_domain);
        hashU64(&leaf, cut);
        hashU8(&leaf, @intFromEnum(recovered.status));
        hashU64(&leaf, recovered.committed_bytes);
        hashU64(&leaf, recovered.discarded_tail_bytes);
        hashU64(&leaf, recovered.ledger.committed_records);
        leaf.update(&recovered.final_chain_sha256);
        leaf.update(&recovered.state_sha256);
        const ledger_sha256 = outbox.ledgerSha256V1(
            recovered.ledger,
        );
        leaf.update(&ledger_sha256);
        const leaf_sha256 = finish(&leaf);
        hash.update(&leaf_sha256);
    }
    return finish(&hash);
}

fn tornCaseSha256V1(
    storage: *ReferenceStorageV1,
    header: outbox.HeaderV1,
) Error!Digest {
    const committed_records: usize = 3;
    const committed_bytes =
        outbox.header_bytes + committed_records * outbox.record_bytes;
    const cut = committed_bytes + outbox.record_body_bytes;
    const recovered = try outbox.recoverV1(
        storage.journal[0..cut],
        header.header_sha256,
        &storage.replay_records,
        &storage.replay_states,
    );
    if (recovered.status != .body_without_footer or
        recovered.committed_bytes != committed_bytes or
        recovered.discarded_tail_bytes != outbox.record_body_bytes or
        recovered.ledger.committed_records != committed_records or
        recovered.ledger.uncertain_actions != 1 or
        recovered.ledger.ready_actions != 0)
        return Error.InvalidReferenceReport;
    const repaired = try outbox.recoverV1(
        storage.journal[0..storage.journal_length],
        header.header_sha256,
        &storage.replay_records,
        &storage.replay_states,
    );
    if (repaired.status != .clean or
        repaired.ledger.ready_actions != 0 or
        repaired.ledger.uncertain_actions != 0 or
        !digestEqual(
            repaired.final_chain_sha256,
            storage.final_chain_sha256,
        ))
        return Error.InvalidReferenceReport;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(torn_case_domain);
    hashU64(&hash, cut);
    hashU8(&hash, @intFromEnum(recovered.status));
    hashU64(&hash, recovered.committed_bytes);
    hashU64(&hash, recovered.discarded_tail_bytes);
    hash.update(&recovered.final_chain_sha256);
    hash.update(&recovered.state_sha256);
    const torn_ledger_sha256 =
        outbox.ledgerSha256V1(recovered.ledger);
    hash.update(&torn_ledger_sha256);
    hash.update(&repaired.final_chain_sha256);
    hash.update(&repaired.state_sha256);
    return finish(&hash);
}

pub fn reportSha256V1(value: ReportV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(report_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.header_bytes);
    hashU64(&hash, value.record_body_bytes);
    hashU64(&hash, value.commit_footer_bytes);
    hashU64(&hash, value.record_bytes);
    hashU64(&hash, value.record_count);
    hashU64(&hash, value.action_count);
    hashU64(&hash, value.journal_bytes);
    hash.update(&value.header_sha256);
    hash.update(&value.primary_proposal_sha256);
    hash.update(&value.primary_authorization_sha256);
    hash.update(&value.primary_action_sha256);
    hash.update(&value.compensation_proposal_sha256);
    hash.update(&value.compensation_authorization_sha256);
    hash.update(&value.compensation_action_sha256);
    hash.update(&value.record_section_sha256);
    hash.update(&value.final_chain_sha256);
    hash.update(&value.final_state_sha256);
    hash.update(&value.ledger_sha256);
    hash.update(&value.closed_anchor_sha256);
    hash.update(&value.recovery_matrix_sha256);
    hash.update(&value.torn_case_sha256);
    for (value.event_kinds) |kind| {
        hashU8(&hash, @intFromEnum(kind));
    }
    for (value.attempt_generations) |generation| {
        hashU64(&hash, generation);
    }
    hashLedger(&hash, value.summary);
    return finish(&hash);
}

fn validateReportShapeV1(value: ReportV1) Error!void {
    const expected_kinds = [_]outbox.EventKindV1{
        .enqueued,
        .dispatch_intent,
        .ambiguity_observed,
        .reconciled_not_applied,
        .dispatch_intent,
        .acknowledged_success,
        .enqueued,
        .dispatch_intent,
        .ambiguity_observed,
        .reconciled_success,
    };
    const expected_generations = [_]u64{
        0, 1, 1, 1, 2, 2, 0, 1, 1, 1,
    };
    const expected_anchor: outbox.ClosedAnchorV1 = .{
        .header_sha256 = value.header_sha256,
        .committed_bytes = value.journal_bytes,
        .committed_records = value.record_count,
        .final_chain_sha256 = value.final_chain_sha256,
        .state_sha256 = value.final_state_sha256,
        .ledger_sha256 = value.ledger_sha256,
        .anchor_sha256 = value.closed_anchor_sha256,
    };
    if (value.abi_version != report_abi or
        value.header_bytes != outbox.header_bytes or
        value.record_body_bytes != outbox.record_body_bytes or
        value.commit_footer_bytes != outbox.commit_footer_bytes or
        value.record_bytes != outbox.record_bytes or
        value.record_count != reference_record_count or
        value.action_count != reference_action_count or
        value.journal_bytes != reference_journal_bytes or
        !std.meta.eql(value.event_kinds, expected_kinds) or
        !std.meta.eql(
            value.attempt_generations,
            expected_generations,
        ) or value.summary.committed_records != 10 or
        value.summary.actions_enqueued != 2 or
        value.summary.primary_actions != 1 or
        value.summary.compensation_actions != 1 or
        value.summary.dispatch_intents != 3 or
        value.summary.safe_retry_dispatches != 1 or
        value.summary.ambiguity_observations != 2 or
        value.summary.acknowledged_successes != 1 or
        value.summary.acknowledged_failures != 0 or
        value.summary.reconciled_not_applied != 1 or
        value.summary.reconciled_successes != 1 or
        value.summary.reconciled_failures != 0 or
        value.summary.ready_actions != 0 or
        value.summary.uncertain_actions != 0 or
        value.summary.succeeded_actions != 2 or
        value.summary.failed_actions != 0 or
        digestIsZero(value.header_sha256) or
        digestIsZero(value.primary_proposal_sha256) or
        digestIsZero(value.primary_authorization_sha256) or
        digestIsZero(value.primary_action_sha256) or
        digestIsZero(value.compensation_proposal_sha256) or
        digestIsZero(value.compensation_authorization_sha256) or
        digestIsZero(value.compensation_action_sha256) or
        digestIsZero(value.record_section_sha256) or
        digestIsZero(value.final_chain_sha256) or
        digestIsZero(value.final_state_sha256) or
        digestIsZero(value.ledger_sha256) or
        digestIsZero(value.closed_anchor_sha256) or
        digestIsZero(value.recovery_matrix_sha256) or
        digestIsZero(value.torn_case_sha256) or
        !digestEqual(
            value.ledger_sha256,
            outbox.ledgerSha256V1(value.summary),
        ) or !digestEqual(
        value.closed_anchor_sha256,
        outbox.closedAnchorSha256V1(expected_anchor),
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

fn findState(
    states: []const outbox.ActionStateV1,
    action_sha256: Digest,
) ?outbox.ActionStateV1 {
    for (states) |state| {
        if (state.occupied and
            digestEqual(
                state.identity.action_sha256,
                action_sha256,
            ))
            return state;
    }
    return null;
}

fn digest(label: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(label, &result, .{});
    return result;
}

fn hashLedger(
    hash: *std.crypto.hash.sha2.Sha256,
    ledger: outbox.LedgerV1,
) void {
    inline for (std.meta.fields(outbox.LedgerV1)) |field| {
        hashU64(hash, @field(ledger, field.name));
    }
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
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

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
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

test "retained action outbox report replays every boundary" {
    var storage: ReferenceStorageV1 = .{};
    const report = try runReferenceCampaignV1(&storage);
    var replay: ReferenceStorageV1 = .{};
    try validateReportByReplayV1(report, &replay);
}

test "semantic report substitution rejects after reseal" {
    var storage: ReferenceStorageV1 = .{};
    const report = try runReferenceCampaignV1(&storage);
    var mutated = report;
    mutated.summary.safe_retry_dispatches = 2;
    mutated.report_sha256 = reportSha256V1(mutated);
    try std.testing.expectError(
        Error.InvalidReferenceReport,
        validateReportV1(mutated),
    );

    mutated = report;
    mutated.record_section_sha256[0] ^= 1;
    mutated.report_sha256 = reportSha256V1(mutated);
    try std.testing.expectError(
        Error.InvalidReferenceReport,
        validateReportV1(mutated),
    );
}
