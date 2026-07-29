//! Additive variable-length terminal evidence for process-local prepared text.
//!
//! The fixed-output SessionV3 and ResultEnvelopeV1 contracts remain
//! unchanged. This profile closes SessionV2 after either exhausting its
//! admitted ceiling or publishing an in-vocabulary EOS token. An early close
//! uses LaneWeave's ordinary cancel event only as the resource-close
//! transport; a cancel event is never successful completion without the
//! canonical CompletedEarlyV1 sidecar defined here.

const std = @import("std");
const core = @import("core");
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;
const lane_contiguous = @import("lane_contiguous_publication.zig");
const publication = @import("lane_publication_txn.zig");
const prepared = @import("prepared_text_session.zig");
const terminal = @import("prepared_text_terminal_equivalence.zig");

pub const Digest = [32]u8;
pub const completed_early_abi: u64 = 0x4750_5445_0000_0001;
pub const evidence_abi: u64 = 0x4750_5456_0000_0001;

const completed_early_domain =
    "glacier-prepared-text-completed-early-v1\x00";
const evidence_domain =
    "glacier-prepared-text-variable-terminal-evidence-v1\x00";
const zero_digest = [_]u8{0} ** 32;

pub const Error = error{
    InvalidTerminal,
    ArithmeticOverflow,
};

pub const TerminationReasonV1 = enum(u8) {
    length,
    eos,
    eos_at_limit,
};

/// Pointer-free proof that an ordinary LaneWeave cancel event released only
/// unused admitted service after a verified terminal EOS publication.
pub const CompletedEarlyV1 = struct {
    abi_version: u64 = completed_early_abi,
    reason: TerminationReasonV1 = .eos,
    request_epoch: u64,
    max_new_tokens: u64,
    actual_new_tokens: u64,
    unused_quanta: u64,
    eos_token: u32,
    local_plan_sha256: Digest,
    bound_plan_sha256: Digest,
    challenge_sha256: Digest,
    boundary_sha256: Digest,
    terminal_semantic_sha256: Digest,
    output_sha256: Digest,
    close_event_sequence: u64,
    close_event_sha256: Digest,
    completed_early_sha256: Digest,
};

/// Complete terminal commit returned beside the still-canonical LaneWeave
/// close event. `completed_early` is present exactly when unused quota was
/// released; full-length completion retires normally and leaves it null.
pub const EvidenceV1 = struct {
    abi_version: u64 = evidence_abi,
    reason: TerminationReasonV1,
    max_new_tokens: u64,
    actual_new_tokens: u64,
    eos_token: u32,
    boundary: prepared.BoundarySnapshotV2,
    semantic: terminal.TerminalSemanticV1,
    final_commit: publication.CommitReceiptV1,
    close_event: lane.EventV1,
    completed_early: ?CompletedEarlyV1,
    evidence_sha256: Digest,
};

/// Verify terminal physical state, project its portable semantics, then close
/// the SessionV2 authority exactly once. The returned evidence distinguishes
/// successful early EOS from cancellation without changing EventV1.
pub fn completeV1(
    session: *prepared.SessionV2,
    final_commit: publication.CommitReceiptV1,
) !EvidenceV1 {
    if (!session.contract_bound or !session.isFinished())
        return Error.InvalidTerminal;

    const local_plan = session.inner.plan;
    const bound_plan = session.bound_plan;
    const output_tokens = session.outputTokens();
    if (output_tokens.len == 0)
        return Error.InvalidTerminal;
    const actual_new_tokens = std.math.cast(
        u64,
        output_tokens.len,
    ) orelse return Error.ArithmeticOverflow;
    if (actual_new_tokens > local_plan.max_new_tokens)
        return Error.InvalidTerminal;

    const boundary = try session.snapshotVariableVerifiedV1();
    const logical_kv_sha256 = lane_contiguous.logicalKvPrefixSha256(
        &session.inner.resources.cache,
        session.inner.resources.cache.len,
    );
    const semantic = try terminal.makeVariableV1(
        boundary,
        bound_plan,
        local_plan,
        output_tokens,
        logical_kv_sha256,
    );
    const eos_hit =
        output_tokens[output_tokens.len - 1] == local_plan.eos_token;
    if (actual_new_tokens < local_plan.max_new_tokens and !eos_hit)
        return Error.InvalidTerminal;
    for (output_tokens) |token| {
        if (@as(u64, token) >
            bound_plan.execution.maximum_absolute_output)
            return Error.InvalidTerminal;
    }
    const unused_quanta = std.math.sub(
        u64,
        local_plan.max_new_tokens,
        actual_new_tokens,
    ) catch return Error.ArithmeticOverflow;
    const reason: TerminationReasonV1 =
        if (!eos_hit)
            .length
        else if (actual_new_tokens < local_plan.max_new_tokens)
            .eos
        else
            .eos_at_limit;

    // This call repeats the live boundary comparison and validates the final
    // commit against the current admission before consuming close authority.
    const closed = try session.closeVariableTerminalV1(
        boundary,
        final_commit,
    );
    const completed_early = if (closed.mode == .release_unused)
        makeCompletedEarlyV1(
            closed,
            semantic,
            unused_quanta,
        )
    else
        null;
    var evidence: EvidenceV1 = .{
        .reason = reason,
        .max_new_tokens = local_plan.max_new_tokens,
        .actual_new_tokens = actual_new_tokens,
        .eos_token = local_plan.eos_token,
        .boundary = boundary,
        .semantic = semantic,
        .final_commit = final_commit,
        .close_event = closed.close_event,
        .completed_early = completed_early,
        .evidence_sha256 = zero_digest,
    };
    evidence.evidence_sha256 = evidenceRootV1(evidence);
    return evidence;
}

pub fn completedEarlyRootV1(value: CompletedEarlyV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(completed_early_domain);
    hashU64(&hash, value.abi_version);
    hashU8(&hash, @intFromEnum(value.reason));
    hashU64(&hash, value.request_epoch);
    hashU64(&hash, value.max_new_tokens);
    hashU64(&hash, value.actual_new_tokens);
    hashU64(&hash, value.unused_quanta);
    hashU32(&hash, value.eos_token);
    hash.update(&value.local_plan_sha256);
    hash.update(&value.bound_plan_sha256);
    hash.update(&value.challenge_sha256);
    hash.update(&value.boundary_sha256);
    hash.update(&value.terminal_semantic_sha256);
    hash.update(&value.output_sha256);
    hashU64(&hash, value.close_event_sequence);
    hash.update(&value.close_event_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn evidenceRootV1(value: EvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(evidence_domain);
    hashU64(&hash, value.abi_version);
    hashU8(&hash, @intFromEnum(value.reason));
    hashU64(&hash, value.max_new_tokens);
    hashU64(&hash, value.actual_new_tokens);
    hashU32(&hash, value.eos_token);
    hash.update(&value.boundary.boundary_sha256);
    hash.update(&value.semantic.semantic_sha256);
    hash.update(&value.final_commit.transcript_sha256);
    hash.update(&value.final_commit.service_event_sha256);
    hash.update(&value.close_event.event_sha256);
    if (value.completed_early) |completed| {
        hashU8(&hash, 1);
        hash.update(&completed.completed_early_sha256);
    } else {
        hashU8(&hash, 0);
        hash.update(&zero_digest);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn completedEarlyStructurallyValidV1(
    value: CompletedEarlyV1,
    close_event: lane.EventV1,
) bool {
    const expected_unused = std.math.sub(
        u64,
        value.max_new_tokens,
        value.actual_new_tokens,
    ) catch return false;
    return value.abi_version == completed_early_abi and
        value.reason == .eos and
        value.request_epoch != 0 and
        value.max_new_tokens != 0 and
        value.actual_new_tokens != 0 and
        value.actual_new_tokens < value.max_new_tokens and
        value.unused_quanta == expected_unused and
        !isZero(value.local_plan_sha256) and
        !isZero(value.bound_plan_sha256) and
        !isZero(value.challenge_sha256) and
        !isZero(value.boundary_sha256) and
        !isZero(value.terminal_semantic_sha256) and
        !isZero(value.output_sha256) and
        value.close_event_sequence != 0 and
        !isZero(value.close_event_sha256) and
        !isZero(value.completed_early_sha256) and
        std.mem.eql(
            u8,
            &value.completed_early_sha256,
            &completedEarlyRootV1(value),
        ) and
        close_event.kind == .cancel and
        close_event.event_sequence == value.close_event_sequence and
        std.mem.eql(
            u8,
            &close_event.event_sha256,
            &value.close_event_sha256,
        ) and
        closeEventValidV1(
            close_event,
            value.max_new_tokens,
            value.unused_quanta,
            .cancel,
        );
}

pub fn evidenceValidV1(
    value: EvidenceV1,
    bound_plan: prepared.BoundPlanV1,
    local_plan: prepared.PlanV1,
    output_tokens: []const u32,
) bool {
    const output_length = std.math.cast(
        u64,
        output_tokens.len,
    ) orelse return false;
    if (value.abi_version != evidence_abi or
        output_tokens.len == 0 or
        value.max_new_tokens != local_plan.max_new_tokens or
        value.actual_new_tokens != output_length or
        value.eos_token != local_plan.eos_token or
        value.actual_new_tokens > value.max_new_tokens or
        !prepared.boundarySnapshotValidForVariableBoundPlanV2(
            value.boundary,
            bound_plan,
            local_plan,
        ) or
        !value.boundary.base.publication.terminal or
        value.boundary.base.publication.next_sequence !=
            value.actual_new_tokens or
        value.boundary.base.publication.state.output_length !=
            value.actual_new_tokens)
        return false;

    if (!publication.commitReceiptValidV1(value.final_commit) or
        value.final_commit.proposal.sequence_base !=
            value.boundary.base.publication.sequence_base or
        !value.final_commit.proposal.transition.terminal or
        value.final_commit.proposal.transition.token_id !=
            output_tokens[output_tokens.len - 1] or
        value.final_commit.proposal.request_epoch !=
            value.boundary.base.publication.request_epoch or
        value.final_commit.proposal.execution_abi !=
            value.boundary.base.publication.execution_abi or
        value.final_commit.proposal.resource_permit_generation !=
            value.boundary.base.publication
                .last_resource_permit_generation or
        value.final_commit.proposal.transaction_sequence !=
            value.actual_new_tokens - 1 or
        !std.meta.eql(
            value.final_commit.proposal.transition.after,
            value.boundary.base.publication.state,
        ) or
        !std.mem.eql(
            u8,
            &value.final_commit.transcript_sha256,
            &value.boundary.base.publication.transcript_sha256,
        ))
        return false;

    for (output_tokens) |token| {
        if (@as(u64, token) >
            bound_plan.execution.maximum_absolute_output)
            return false;
    }

    const expected_semantic = terminal.makeVariableV1(
        value.boundary,
        bound_plan,
        local_plan,
        output_tokens,
        value.semantic.logical_kv_sha256,
    ) catch return false;
    if (!std.meta.eql(expected_semantic, value.semantic))
        return false;

    const eos_hit =
        output_tokens[output_tokens.len - 1] == local_plan.eos_token;
    const expected_reason: TerminationReasonV1 =
        if (!eos_hit)
            .length
        else if (value.actual_new_tokens < value.max_new_tokens)
            .eos
        else
            .eos_at_limit;
    if (value.reason != expected_reason or
        (value.actual_new_tokens < value.max_new_tokens and !eos_hit))
        return false;

    if (value.actual_new_tokens < value.max_new_tokens) {
        const completed = value.completed_early orelse return false;
        if (!std.mem.eql(
            u8,
            &completed.local_plan_sha256,
            &local_plan.plan_sha256,
        ) or
            !std.mem.eql(
                u8,
                &completed.bound_plan_sha256,
                &bound_plan.bound_plan_sha256,
            ) or
            !std.mem.eql(
                u8,
                &completed.challenge_sha256,
                &bound_plan.execution.challenge_sha256,
            ) or
            completed.request_epoch !=
                value.boundary.base.publication.request_epoch or
            completed.max_new_tokens != value.max_new_tokens or
            completed.actual_new_tokens != value.actual_new_tokens or
            completed.eos_token != value.eos_token or
            !std.mem.eql(
                u8,
                &completed.boundary_sha256,
                &value.boundary.boundary_sha256,
            ) or
            !std.mem.eql(
                u8,
                &completed.terminal_semantic_sha256,
                &value.semantic.semantic_sha256,
            ) or
            !std.mem.eql(
                u8,
                &completed.output_sha256,
                &value.semantic.output_sha256,
            ) or
            !completedEarlyStructurallyValidV1(
                completed,
                value.close_event,
            ) or
            !closeFollowsFinalCommitV1(
                value.close_event,
                value.final_commit,
            ))
            return false;
    } else {
        if (value.completed_early != null or
            !closeEventValidV1(
                value.close_event,
                value.max_new_tokens,
                0,
                .retire,
            ) or
            !closeFollowsFinalCommitV1(
                value.close_event,
                value.final_commit,
            ))
            return false;
    }

    return std.mem.eql(
        u8,
        &value.evidence_sha256,
        &evidenceRootV1(value),
    );
}

fn closeFollowsFinalCommitV1(
    close_event: lane.EventV1,
    final_commit: publication.CommitReceiptV1,
) bool {
    const service_event = final_commit.service_event;
    // Other requests may legitimately advance the Scheduler's global chain
    // between this request's terminal service and close. The generation-fenced
    // handle, exact spec/receipt, and remaining-work transition bind the two;
    // full global ordering is verified by replaying the complete event stream.
    return close_event.event_sequence >
        service_event.event_sequence and
        std.meta.eql(close_event.handle, service_event.handle) and
        std.meta.eql(close_event.spec, service_event.spec) and
        std.meta.eql(
            close_event.resource_receipt,
            service_event.resource_receipt,
        ) and
        std.mem.eql(
            u8,
            &close_event.resource_receipt_sha256,
            &service_event.resource_receipt_sha256,
        ) and
        close_event.remaining_before == service_event.remaining_after;
}

fn makeCompletedEarlyV1(
    closed: prepared.VariableTerminalCloseV1,
    semantic: terminal.TerminalSemanticV1,
    unused_quanta: u64,
) CompletedEarlyV1 {
    var value: CompletedEarlyV1 = .{
        .request_epoch = closed.request_epoch,
        .max_new_tokens = closed.max_new_tokens,
        .actual_new_tokens = semantic.output_length,
        .unused_quanta = unused_quanta,
        .eos_token = closed.eos_token,
        .local_plan_sha256 = closed.local_plan_sha256,
        .bound_plan_sha256 = closed.bound_plan_sha256,
        .challenge_sha256 = closed.challenge_sha256,
        .boundary_sha256 = closed.boundary_sha256,
        .terminal_semantic_sha256 = semantic.semantic_sha256,
        .output_sha256 = semantic.output_sha256,
        .close_event_sequence = closed.close_event.event_sequence,
        .close_event_sha256 = closed.close_event.event_sha256,
        .completed_early_sha256 = zero_digest,
    };
    value.completed_early_sha256 = completedEarlyRootV1(value);
    return value;
}

fn closeEventValidV1(
    event: lane.EventV1,
    max_new_tokens: u64,
    remaining_before: u64,
    expected_kind: lane.EventKind,
) bool {
    if (event.abi_version != lane.event_abi or
        event.kind != expected_kind or
        event.rejection_reason != .none or
        event.scheduler_epoch == 0 or event.event_sequence == 0 or
        event.handle.scheduler_epoch != event.scheduler_epoch or
        event.handle.slot_generation == 0 or
        event.handle.tenant_key != event.spec.tenant_key or
        event.handle.request_key != event.spec.request_key or
        event.handle.request_generation !=
            event.spec.request_generation or
        event.spec.work_quanta != max_new_tokens or
        event.resource_receipt.owner_key !=
            event.spec.resource_owner_key or
        event.handle.slot_index != event.resource_receipt.slot_index or
        event.handle.slot_generation !=
            event.resource_receipt.generation or
        !std.meta.eql(
            event.resource_receipt.claim,
            event.spec.claim,
        ) or
        !resource_bank.receiptIntegrityValidV1(
            event.resource_receipt,
        ) or
        !std.mem.eql(
            u8,
            &event.resource_receipt_sha256,
            &lane.resourceReceiptSha256(event.resource_receipt),
        ) or
        event.remaining_before != remaining_before or
        event.remaining_after != 0 or
        event.wait_quanta != 0 or
        event.logical_tick_before != event.logical_tick_after or
        event.cursor_before != event.cursor_after or
        event.level_before != event.level_after or
        !std.mem.eql(
            u8,
            &event.event_sha256,
            &lane.eventSha256(event),
        ))
        return false;

    const expected_bank_after = subtractClaimV1(
        event.bank_used_before,
        event.spec.claim,
    ) orelse return false;
    if (!std.meta.eql(expected_bank_after, event.bank_used_after))
        return false;

    const active_after_plus_one = std.math.add(
        u32,
        event.active_after,
        1,
    ) catch return false;
    const finished_after_plus_one = std.math.add(
        u32,
        event.finished_after,
        1,
    ) catch return false;
    return switch (expected_kind) {
        .cancel => event.active_before == active_after_plus_one and
            event.finished_before == event.finished_after,
        .retire => event.active_before == event.active_after and
            event.finished_before == finished_after_plus_one,
        else => false,
    };
}

fn subtractClaimV1(
    lhs: resource_bank.Claim,
    rhs: resource_bank.Claim,
) ?resource_bank.Claim {
    var result: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        @field(result, field.name) = std.math.sub(
            u64,
            @field(lhs, field.name),
            @field(rhs, field.name),
        ) catch return null;
    }
    return result;
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn hashU8(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&[_]u8{value});
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}
