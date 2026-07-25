//! Live restored admission for one verified prepared-text successor.
//!
//! This module consumes the canonical checkpoint, execution-plan, residency,
//! and successor-segment records, then acquires a fresh target Scheduler
//! admission and ResourceBank receipt. The receipt owns an empty LeaseTree and
//! tenant scope whose publication namespace resumes at the exact nonzero
//! sequence and source publication-permit generation.
//!
//! The returned capability deliberately retains the Scheduler's publication
//! adoption barrier. It is not a runnable Session and it does not allocate KV
//! storage. A later materialization gate must consume the retained cache
//! node/binding intent before committing the adoption.

const std = @import("std");
const core = @import("core");
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;
const checkpoint_file = core.continuation_checkpoint_file;
const checkpoint = @import("prepared_text_checkpoint.zig");
const successor = @import("prepared_text_successor.zig");

pub const canonical_request_weight: u16 = 1;
pub const canonical_deadline_tick: u64 = 0;
const bootstrap_domain =
    "glacier-prepared-text-restored-admission-bootstrap-v1\x00";
const activation_grant_domain =
    "glacier-prepared-text-selected-source-exit-grant-v1\x00";

pub const Error = error{
    InvalidActivationGrant,
    InvalidLiveTarget,
    InvalidPreparedAdmission,
    RecoveryRequired,
};

/// Caller-retained portable evidence and exact source/target context. The
/// slices are consumed synchronously and are not retained in live authority.
pub const EvidenceV1 = struct {
    encoded_plan: []const u8,
    encoded_residency: []const u8,
    encoded_segment: []const u8,
    encoded_checkpoint: []const u8,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: successor.SourceContextV1,
    target: successor.TargetOwnershipV1,
};

pub const Phase = enum(u8) {
    prepared,
    activated,
    publication_session_closed,
    lease_tree_closed,
    aborted,
};

pub const ActivationGrantPhase = enum(u8) {
    empty,
    ready,
    preparing,
    prepared,
    consumed,
    terminal_selected,
    completed,
};

/// Address-stable, process-local authority derived only from the active
/// generation-two selector while its exclusive file lease is held. Copies
/// fail the self-address fence. The lease must remain open and selector-stable
/// through restored activation and terminal publication.
pub const SelectedSourceExitGrantV1 = struct {
    lease: ?*checkpoint_file.LeaseV1 = null,
    self_address: usize = 0,
    lease_address: usize = 0,
    consumer_claim: checkpoint_file.ConsumerClaimV1 = .{},
    initial_consumer_claim_sha256: successor.Digest =
        [_]u8{0} ** 32,
    source_scheduler_epoch: u64 = 0,
    source_coordinator_id: u64 = 0,
    source_bank_epoch: u64 = 0,
    request_epoch: u64 = 0,
    publication_next_sequence: u64 = 0,
    source_last_resource_permit_generation: u64 = 0,
    source_selector_generation: u64 = 0,
    terminal_selector_generation: u64 = 0,
    authority_checkpoint_sha256: successor.Digest =
        [_]u8{0} ** 32,
    selected_selector_sha256: successor.Digest =
        [_]u8{0} ** 32,
    predecessor_selector_sha256: successor.Digest =
        [_]u8{0} ** 32,
    source_exit_sha256: successor.Digest = [_]u8{0} ** 32,
    source_receipt_sha256: successor.Digest =
        [_]u8{0} ** 32,
    checkpoint_sha256: successor.Digest = [_]u8{0} ** 32,
    prepared_archive_sha256: successor.Digest =
        [_]u8{0} ** 32,
    successor_segment_sha256: successor.Digest =
        [_]u8{0} ** 32,
    ownership_intent_sha256: successor.Digest =
        [_]u8{0} ** 32,
    challenge_sha256: successor.Digest = [_]u8{0} ** 32,
    grant_sha256: successor.Digest = [_]u8{0} ** 32,
    phase: ActivationGrantPhase = .empty,
};

pub const PrepareRecoveryPhase = enum(u8) {
    publication_session_bound,
    lease_tree_open,
    adoption_held,
    recovered,
};

/// Process-local, single-use authority. Pointer-bearing fields and live
/// handles intentionally have no wire encoding.
pub const PreparedRestoredAdmissionV1 = struct {
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    target: successor.TargetOwnershipV1,
    request_spec: lane.RequestSpec,
    adoption: lane.PublicationAdoptionV1,
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    scope: resource_bank.LeaseNodeV1,
    session_id: usize,
    source_bank_epoch: u64,
    publication_next_sequence: u64,
    source_last_resource_permit_generation: u64,
    successor_execution_plan_sha256: successor.Digest,
    successor_residency_binding_sha256: successor.Digest,
    successor_segment_sha256: successor.Digest,
    ownership_intent_sha256: successor.Digest,
    challenge_sha256: successor.Digest,
    activation_grant_address: usize = 0,
    activation_lease_address: usize = 0,
    activation_grant_sha256: successor.Digest =
        [_]u8{0} ** 32,
    selected_authority_checkpoint_sha256: successor.Digest =
        [_]u8{0} ** 32,
    selected_selector_sha256: successor.Digest =
        [_]u8{0} ** 32,
    selected_source_exit_sha256: successor.Digest =
        [_]u8{0} ** 32,
    bootstrap_sha256: successor.Digest,
    phase: Phase = .prepared,
};

/// Exact live authority retained only when automatic setup rollback cannot
/// finish. `recoverPrepareRestoredAdmissionV1` advances this value one
/// generation-fenced cleanup step at a time and can be retried after the
/// external condition that blocked cleanup has been repaired.
pub const PrepareRecoveryV1 = struct {
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    adoption: lane.PublicationAdoptionV1,
    receipt: resource_bank.Receipt,
    tree: ?resource_bank.LeaseTreeV1 = null,
    scope: ?resource_bank.LeaseNodeV1 = null,
    session_id: usize,
    request_epoch: u64,
    publication_next_sequence: u64,
    source_last_resource_permit_generation: u64,
    activation_grant: ?*SelectedSourceExitGrantV1 = null,
    activation_grant_sha256: successor.Digest =
        [_]u8{0} ** 32,
    phase: PrepareRecoveryPhase = .adoption_held,
};

pub const PrepareDecisionV1 = union(enum) {
    prepared: PreparedRestoredAdmissionV1,
    rejected: lane.EventV1,
    recovery_required: PrepareRecoveryV1,
};

/// Canonical scheduling projection for R1h. R1g already binds every value
/// except request key, weight, and deadline, so this gate derives those three
/// without accepting caller policy:
///
/// - request key is the target authority key;
/// - weight is one; and
/// - deadline is absent.
pub fn requestSpecV1(
    artifacts: successor.ArtifactsV1,
    target: successor.TargetOwnershipV1,
) lane.RequestSpec {
    return .{
        .tenant_key = target.tenant_key,
        .request_key = target.authority_key,
        .request_generation = target.request_generation,
        .resource_owner_key = target.resource_owner_key,
        .weight = canonical_request_weight,
        .work_quanta = artifacts.segment.remaining_quanta,
        .deadline_tick = canonical_deadline_tick,
        .claim = target.request_claim,
    };
}

/// Allocator-owned portion of the exact request claim. The immutable receipt
/// remains charged for the complete request; the queue slot stays under the
/// Scheduler while all byte classes become funded LeaseTree ownership.
pub fn materializedClaimV1(
    request_claim: resource_bank.Claim,
) resource_bank.Claim {
    var result = request_claim;
    result.queue_slots = 0;
    return result;
}

pub fn validateSelectedSourceExitGrantV1(
    grant: *const SelectedSourceExitGrantV1,
    expected_phase: ActivationGrantPhase,
) !void {
    const lease = grant.lease orelse
        return Error.InvalidActivationGrant;
    if (expected_phase == .empty or
        expected_phase == .completed or
        grant.phase != expected_phase or
        grant.self_address != @intFromPtr(grant) or
        grant.lease_address != @intFromPtr(lease) or
        lease.state != .ready or
        grant.source_scheduler_epoch == 0 or
        grant.source_coordinator_id == 0 or
        grant.source_bank_epoch == 0 or
        grant.request_epoch == 0 or
        grant.publication_next_sequence == 0 or
        grant.source_last_resource_permit_generation == 0 or
        grant.source_last_resource_permit_generation ==
            std.math.maxInt(u64) or
        grant.source_selector_generation == 0 or
        grant.terminal_selector_generation <=
            grant.source_selector_generation or
        grant.consumer_claim.owner_address !=
            grant.self_address or
        grant.consumer_claim.lease_address !=
            grant.lease_address or
        grant.consumer_claim.claim_generation == 0 or
        isZeroDigest(
            grant.initial_consumer_claim_sha256,
        ) or
        isZeroDigest(grant.authority_checkpoint_sha256) or
        isZeroDigest(grant.selected_selector_sha256) or
        isZeroDigest(grant.predecessor_selector_sha256) or
        isZeroDigest(grant.source_exit_sha256) or
        isZeroDigest(grant.source_receipt_sha256) or
        isZeroDigest(grant.checkpoint_sha256) or
        isZeroDigest(grant.prepared_archive_sha256) or
        isZeroDigest(grant.successor_segment_sha256) or
        isZeroDigest(grant.ownership_intent_sha256) or
        isZeroDigest(grant.challenge_sha256) or
        !std.mem.eql(
            u8,
            &grant.grant_sha256,
            &selectedSourceExitGrantRootV1(grant.*),
        ))
        return Error.InvalidActivationGrant;
    lease.validateConsumerClaimV1(
        grant.consumer_claim,
    ) catch return Error.InvalidActivationGrant;
    const active_set = lease.activeSet() catch
        return Error.InvalidActivationGrant;
    if (active_set.metadata.request_epoch !=
        grant.request_epoch or
        !std.mem.eql(
            u8,
            &active_set.metadata.challenge_sha256,
            &grant.challenge_sha256,
        ))
        return Error.InvalidActivationGrant;
    if (expected_phase == .terminal_selected) {
        if (lease.selector.generation !=
            grant.terminal_selector_generation or
            active_set.metadata.generation !=
                grant.terminal_selector_generation or
            active_set.metadata.publication_next_sequence <=
                grant.publication_next_sequence or
            !std.mem.eql(
                u8,
                &lease.selector.previous_selector_sha256,
                &grant.selected_selector_sha256,
            ) or !std.mem.eql(
            u8,
            &active_set.metadata.parent_checkpoint_sha256,
            &grant.authority_checkpoint_sha256,
        ))
            return Error.InvalidActivationGrant;
    } else {
        if (!std.mem.eql(
            u8,
            &grant.consumer_claim.claim_sha256,
            &grant.initial_consumer_claim_sha256,
        ) or lease.selector.generation !=
            grant.source_selector_generation or
            active_set.metadata.generation !=
                grant.source_selector_generation or
            lease.selector.publication_next_sequence !=
                grant.publication_next_sequence or
            active_set.metadata.publication_next_sequence !=
                grant.publication_next_sequence or
            !std.mem.eql(
                u8,
                &lease.selector.selector_sha256,
                &grant.selected_selector_sha256,
            ) or !std.mem.eql(
            u8,
            &active_set.checkpoint_sha256,
            &grant.authority_checkpoint_sha256,
        ) or !std.mem.eql(
            u8,
            &lease.selector.previous_selector_sha256,
            &grant.predecessor_selector_sha256,
        ))
            return Error.InvalidActivationGrant;
    }
}

/// Address-bearing grant identity. `phase` is intentionally excluded so the
/// immutable identity survives ready -> preparing -> prepared -> consumed;
/// phase transitions remain single-threaded under the pinned-address contract.
pub fn selectedSourceExitGrantRootV1(
    grant: SelectedSourceExitGrantV1,
) successor.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(activation_grant_domain);
    hashU64(&hash, grant.self_address);
    hashU64(&hash, grant.lease_address);
    hash.update(&grant.initial_consumer_claim_sha256);
    hashU64(&hash, grant.source_scheduler_epoch);
    hashU64(&hash, grant.source_coordinator_id);
    hashU64(&hash, grant.source_bank_epoch);
    hashU64(&hash, grant.request_epoch);
    hashU64(&hash, grant.publication_next_sequence);
    hashU64(
        &hash,
        grant.source_last_resource_permit_generation,
    );
    hashU64(&hash, grant.source_selector_generation);
    hashU64(&hash, grant.terminal_selector_generation);
    hash.update(&grant.authority_checkpoint_sha256);
    hash.update(&grant.selected_selector_sha256);
    hash.update(&grant.predecessor_selector_sha256);
    hash.update(&grant.source_exit_sha256);
    hash.update(&grant.source_receipt_sha256);
    hash.update(&grant.checkpoint_sha256);
    hash.update(&grant.prepared_archive_sha256);
    hash.update(&grant.successor_segment_sha256);
    hash.update(&grant.ownership_intent_sha256);
    hash.update(&grant.challenge_sha256);
    var digest: successor.Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Abandon a not-yet-prepared grant and release the process-local claim while
/// leaving the durable generation-two selector available for a later target.
pub fn releaseReadyActivationGrantV1(
    grant: *SelectedSourceExitGrantV1,
) !void {
    try validateSelectedSourceExitGrantV1(grant, .ready);
    const lease = grant.lease orelse
        return Error.InvalidActivationGrant;
    lease.releaseConsumerClaimV1(
        grant.consumer_claim,
    ) catch return Error.InvalidActivationGrant;
    grant.phase = .completed;
}

/// Called only after the restored Scheduler/Bank authority is closed. A
/// terminal target must already have selected generation three; cancellation
/// releases generation two for deterministic retry.
pub fn completeRestoredActivationGrantV1(
    grant: *SelectedSourceExitGrantV1,
    terminal: bool,
) void {
    const expected_phase: ActivationGrantPhase =
        if (terminal) .terminal_selected else .consumed;
    validateSelectedSourceExitGrantV1(
        grant,
        expected_phase,
    ) catch @panic("restored activation grant drift");
    const lease = grant.lease orelse
        @panic("restored activation lease missing");
    lease.releaseConsumerClaimV1(
        grant.consumer_claim,
    ) catch @panic("restored activation claim release failed");
    grant.phase = .completed;
}

/// Verify all portable evidence and a genuinely fresh live target before
/// installing one adoption barrier. Tree/scope/session setup occurs behind
/// that barrier, so no Scheduler service can observe partial restore state.
pub fn prepareRestoredAdmissionV1(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    session_id: usize,
    evidence: EvidenceV1,
    activation_grant: *SelectedSourceExitGrantV1,
) !PrepareDecisionV1 {
    if (session_id == 0)
        return Error.InvalidLiveTarget;
    try validateSelectedSourceExitGrantV1(
        activation_grant,
        .ready,
    );
    const artifacts =
        successor.decodeAndVerifyForCheckpointV1(
            evidence.encoded_plan,
            evidence.encoded_residency,
            evidence.encoded_segment,
            evidence.encoded_checkpoint,
            evidence.expected_checkpoint,
            evidence.source,
            evidence.target,
        ) catch |err| return err;
    const request_spec = requestSpecV1(artifacts, evidence.target);
    try validateGrantForEvidenceV1(
        activation_grant,
        .ready,
        evidence,
        artifacts,
    );
    try validateFreshTargetV1(
        scheduler,
        bank,
        session_id,
        artifacts,
        evidence,
        request_spec,
    );

    activation_grant.phase = .preparing;
    const decision = scheduler.admitForPublicationAdoption(
        request_spec,
        artifacts.segment.request_epoch,
        session_id,
    ) catch |err| {
        activation_grant.phase = .ready;
        return err;
    };
    const adoption = switch (decision) {
        .rejected => |event| {
            activation_grant.phase = .ready;
            return .{ .rejected = event };
        },
        .adopted => |value| value,
    };

    var recovery: PrepareRecoveryV1 = .{
        .scheduler = scheduler,
        .bank = bank,
        .adoption = adoption,
        .receipt = adoption.admission.event.resource_receipt,
        .session_id = session_id,
        .request_epoch = artifacts.segment.request_epoch,
        .publication_next_sequence = artifacts.segment.sequence_base,
        .source_last_resource_permit_generation = artifacts.segment.source_last_resource_permit_generation,
        .activation_grant = activation_grant,
        .activation_grant_sha256 = activation_grant.grant_sha256,
    };
    const prepared = prepareAfterAdoptionV1(
        scheduler,
        bank,
        session_id,
        evidence,
        artifacts,
        request_spec,
        adoption,
        activation_grant,
        &recovery,
    ) catch |original_error| {
        _ = recoverPrepareRestoredAdmissionV1(&recovery) catch
            return .{ .recovery_required = recovery };
        return original_error;
    };
    activation_grant.phase = .prepared;
    validatePreparedRestoredAdmissionV1(
        &prepared,
        evidence,
        activation_grant,
    ) catch |original_error| {
        activation_grant.phase = .preparing;
        var cleanup = prepared;
        _ = abortPreparedRestoredAdmissionV1Internal(
            &cleanup,
        ) catch {
            recovery.tree = cleanup.tree;
            recovery.scope = cleanup.scope;
            recovery.phase = switch (cleanup.phase) {
                .prepared => .publication_session_bound,
                .publication_session_closed => .lease_tree_open,
                .lease_tree_closed => .adoption_held,
                .activated, .aborted => .recovered,
            };
            return .{ .recovery_required = recovery };
        };
        activation_grant.phase = .ready;
        return original_error;
    };
    return .{ .prepared = prepared };
}

/// Resume an exact setup rollback retained in `PrepareDecisionV1`. Every
/// successful transition records the next live-authority shape before another
/// fallible operation begins, so the same value can be retried safely after a
/// reported `RecoveryRequired`.
pub fn recoverPrepareRestoredAdmissionV1(
    recovery: *PrepareRecoveryV1,
) !lane.EventV1 {
    try validatePrepareRecoveryAuthorityV1(recovery);
    while (true) {
        switch (recovery.phase) {
            .publication_session_bound => {
                recovery.bank.closePublicationSession(
                    recovery.receipt,
                    recovery.request_epoch,
                    recovery.session_id,
                    recovery.publication_next_sequence,
                ) catch return Error.RecoveryRequired;
                recovery.phase = .lease_tree_open;
            },
            .lease_tree_open => {
                recovery.bank.closeLeaseTree(
                    recovery.tree orelse
                        return Error.InvalidPreparedAdmission,
                ) catch return Error.RecoveryRequired;
                recovery.tree = null;
                recovery.scope = null;
                recovery.phase = .adoption_held;
            },
            .adoption_held => {
                const event =
                    recovery.scheduler.cancelPublicationAdoption(
                        recovery.adoption,
                    ) catch return Error.RecoveryRequired;
                recovery.phase = .recovered;
                if (recovery.activation_grant) |grant| {
                    grant.phase = .ready;
                }
                return event;
            },
            .recovered => return Error.InvalidPreparedAdmission,
        }
    }
}

/// Revalidate the independently retained evidence and every live handle.
/// Successful validation is mutation-free. Detected Scheduler/Bank drift keeps
/// the underlying coordinators' existing fail-closed poisoning behavior.
///
/// The evidence slices and expected context must remain valid for this call;
/// cleanup itself deliberately needs only the live capability.
pub fn validatePreparedRestoredAdmissionV1(
    prepared: *const PreparedRestoredAdmissionV1,
    evidence: EvidenceV1,
    activation_grant: *const SelectedSourceExitGrantV1,
) !void {
    if (prepared.phase != .prepared or
        prepared.session_id == 0 or
        prepared.scheduler.bank != prepared.bank or
        prepared.source_bank_epoch == 0 or
        prepared.source_bank_epoch == prepared.bank.epoch or
        prepared.publication_next_sequence == 0 or
        prepared.source_last_resource_permit_generation == 0 or
        prepared.source_last_resource_permit_generation ==
            std.math.maxInt(u64))
        return Error.InvalidPreparedAdmission;
    validateSelectedSourceExitGrantV1(
        activation_grant,
        .prepared,
    ) catch return Error.InvalidPreparedAdmission;
    if (!std.mem.eql(
        u8,
        &prepared.bootstrap_sha256,
        &preparedRestoredAdmissionRootV1(prepared.*),
    ))
        return Error.InvalidPreparedAdmission;
    const artifacts =
        successor.decodeAndVerifyForCheckpointV1(
            evidence.encoded_plan,
            evidence.encoded_residency,
            evidence.encoded_segment,
            evidence.encoded_checkpoint,
            evidence.expected_checkpoint,
            evidence.source,
            evidence.target,
        ) catch return Error.InvalidPreparedAdmission;
    if (!std.meta.eql(evidence.target, prepared.target) or
        evidence.source.receipt.bank_epoch !=
            prepared.source_bank_epoch or
        !std.meta.eql(
            requestSpecV1(artifacts, evidence.target),
            prepared.request_spec,
        ) or
        artifacts.segment.sequence_base !=
            prepared.publication_next_sequence or
        artifacts.segment.source_last_resource_permit_generation !=
            prepared.source_last_resource_permit_generation or
        !std.mem.eql(
            u8,
            &artifacts.successor_plan.plan_sha256,
            &prepared.successor_execution_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.successor_residency.binding_sha256,
            &prepared.successor_residency_binding_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.segment.segment_sha256,
            &prepared.successor_segment_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.segment.ownership_intent_sha256,
            &prepared.ownership_intent_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.segment.challenge_sha256,
            &prepared.challenge_sha256,
        ) or prepared.activation_grant_address !=
        @intFromPtr(activation_grant) or
        prepared.activation_lease_address !=
            activation_grant.lease_address or
        !std.mem.eql(
            u8,
            &prepared.activation_grant_sha256,
            &activation_grant.grant_sha256,
        ) or !std.mem.eql(
        u8,
        &prepared.selected_authority_checkpoint_sha256,
        &activation_grant.authority_checkpoint_sha256,
    ) or !std.mem.eql(
        u8,
        &prepared.selected_selector_sha256,
        &activation_grant.selected_selector_sha256,
    ) or !std.mem.eql(
        u8,
        &prepared.selected_source_exit_sha256,
        &activation_grant.source_exit_sha256,
    ))
        return Error.InvalidPreparedAdmission;
    try validateGrantForEvidenceV1(
        activation_grant,
        .prepared,
        evidence,
        artifacts,
    );
    validateTargetIdentityV1(
        prepared.scheduler,
        prepared.bank,
        prepared.target,
    ) catch return Error.InvalidPreparedAdmission;
    const identity = prepared.scheduler.identityV1() catch
        return Error.InvalidPreparedAdmission;
    if (!std.meta.eql(
        prepared.request_spec,
        requestSpecFromPreparedV1(prepared),
    ) or
        !std.mem.eql(
            u8,
            &identity.challenge_sha256,
            &prepared.challenge_sha256,
        ) or
        !std.meta.eql(
            prepared.receipt,
            prepared.adoption.admission.event.resource_receipt,
        ))
        return Error.InvalidPreparedAdmission;

    validateAdoptionV1(
        prepared.scheduler,
        prepared.bank,
        prepared.adoption,
        prepared.target,
        prepared.request_spec,
        artifacts.segment.request_epoch,
        prepared.session_id,
    ) catch return Error.InvalidPreparedAdmission;
    const materialized_claim =
        materializedClaimV1(prepared.target.request_claim);
    if (materialized_claim.isZero() or
        !std.meta.eql(prepared.tree.parent, prepared.receipt) or
        prepared.tree.tree_key != prepared.target.tree_key or
        prepared.tree.authority_key != prepared.target.authority_key or
        !std.meta.eql(
            prepared.tree.ceiling,
            materialized_claim,
        ) or
        !prepared.tree.current.isZero() or
        prepared.tree.active_nodes != 1 or
        !std.meta.eql(prepared.scope.parent, prepared.receipt) or
        prepared.scope.tree_key != prepared.target.tree_key or
        prepared.scope.tree_identity_generation !=
            prepared.tree.identity_generation or
        prepared.scope.node_key != prepared.target.scope_key or
        prepared.scope.tenant_key != prepared.target.tenant_key or
        prepared.scope.binding_key != 0 or
        prepared.scope.kind != .scope or
        !std.meta.eql(
            prepared.scope.ceiling,
            materialized_claim,
        ) or
        !prepared.scope.claim.isZero())
        return Error.InvalidPreparedAdmission;
    try validateLiveCleanupAuthorityV1(prepared);
    validatePreparedAccountingV1(prepared) catch
        return Error.InvalidPreparedAdmission;
}

/// Consume the prepared capability without ever making it runnable. Exact
/// prevalidation makes each following transition deterministic under the
/// single-owner contract. Each successful cleanup step is recorded before the
/// next fallible operation. If an external actor violates that contract, the
/// same capability can therefore resume from its exact remaining authority.
pub fn abortPreparedRestoredAdmissionV1(
    prepared: *PreparedRestoredAdmissionV1,
    activation_grant: *SelectedSourceExitGrantV1,
) !lane.EventV1 {
    if (prepared.phase != .prepared and
        prepared.phase != .publication_session_closed and
        prepared.phase != .lease_tree_closed)
        return Error.InvalidPreparedAdmission;
    try validatePreparedGrantBindingV1(
        prepared,
        activation_grant,
        .prepared,
    );
    const event =
        try abortPreparedRestoredAdmissionV1Internal(prepared);
    activation_grant.phase = .ready;
    return event;
}

fn abortPreparedRestoredAdmissionV1Internal(
    prepared: *PreparedRestoredAdmissionV1,
) !lane.EventV1 {
    try validateLiveCleanupAuthorityV1(prepared);
    while (true) {
        switch (prepared.phase) {
            .prepared => {
                prepared.bank.closePublicationSession(
                    prepared.receipt,
                    prepared.adoption.publication_request_epoch,
                    prepared.session_id,
                    prepared.publication_next_sequence,
                ) catch return Error.RecoveryRequired;
                prepared.phase = .publication_session_closed;
            },
            .publication_session_closed => {
                prepared.bank.closeLeaseTree(
                    prepared.tree,
                ) catch return Error.RecoveryRequired;
                prepared.phase = .lease_tree_closed;
            },
            .lease_tree_closed => {
                const event =
                    prepared.scheduler.cancelPublicationAdoption(
                        prepared.adoption,
                    ) catch return Error.RecoveryRequired;
                prepared.phase = .aborted;
                return event;
            },
            .activated, .aborted => return Error.InvalidPreparedAdmission,
        }
    }
}

pub fn validatePreparedActivationGrantV1(
    prepared: *const PreparedRestoredAdmissionV1,
    activation_grant: *const SelectedSourceExitGrantV1,
) !void {
    if (prepared.phase != .prepared)
        return Error.InvalidPreparedAdmission;
    try validatePreparedGrantBindingV1(
        prepared,
        activation_grant,
        .prepared,
    );
}

/// The restored Session calls this only after adoption/materialization has
/// linearized successfully. No fallible operation may follow this transition.
pub fn consumePreparedActivationGrantV1(
    prepared: *const PreparedRestoredAdmissionV1,
    activation_grant: *SelectedSourceExitGrantV1,
) void {
    validatePreparedGrantBindingV1(
        prepared,
        activation_grant,
        .prepared,
    ) catch @panic("prepared restore activation grant drift");
    std.debug.assert(prepared.phase == .activated);
    activation_grant.phase = .consumed;
}

/// Validate only the sealed live handles needed for reverse cleanup. This path
/// intentionally does not borrow checkpoint/evidence bytes: losing an
/// inspector input must never strand a valid adoption barrier and receipt.
fn validateLiveCleanupAuthorityV1(
    prepared: *const PreparedRestoredAdmissionV1,
) !void {
    if (prepared.phase == .activated or
        prepared.phase == .aborted or
        prepared.scheduler.bank != prepared.bank or
        prepared.session_id == 0 or
        prepared.session_id !=
            prepared.adoption.publication_session_id or
        prepared.publication_next_sequence == 0 or
        prepared.source_last_resource_permit_generation == 0 or
        prepared.source_last_resource_permit_generation ==
            std.math.maxInt(u64) or
        !std.meta.eql(
            prepared.receipt,
            prepared.adoption.admission.event.resource_receipt,
        ))
        return Error.InvalidPreparedAdmission;
    prepared.scheduler.validatePublicationAdoption(
        prepared.adoption,
    ) catch return Error.InvalidPreparedAdmission;
    prepared.bank.validateCommitted(prepared.receipt) catch
        return Error.InvalidPreparedAdmission;
    switch (prepared.phase) {
        .prepared, .publication_session_closed => {
            try validateCleanupTreeV1(
                prepared.bank,
                prepared.receipt,
                prepared.tree,
                prepared.scope,
            );
            if (prepared.phase == .prepared) {
                prepared.bank
                    .validateRestoredPublicationSessionWithLeaseTreeFenced(
                    prepared.tree,
                    prepared.adoption.publication_request_epoch,
                    prepared.session_id,
                    prepared.publication_next_sequence,
                    prepared.source_last_resource_permit_generation,
                ) catch return Error.InvalidPreparedAdmission;
            }
        },
        .lease_tree_closed => {
            prepared.bank.validateReleaseReady(
                prepared.receipt,
            ) catch return Error.InvalidPreparedAdmission;
        },
        .activated, .aborted => unreachable,
    }
}

fn validatePrepareRecoveryAuthorityV1(
    recovery: *const PrepareRecoveryV1,
) !void {
    if (recovery.phase == .recovered or
        recovery.scheduler.bank != recovery.bank or
        recovery.session_id == 0 or
        recovery.session_id !=
            recovery.adoption.publication_session_id or
        recovery.request_epoch == 0 or
        recovery.request_epoch !=
            recovery.adoption.publication_request_epoch or
        recovery.publication_next_sequence == 0 or
        recovery.source_last_resource_permit_generation == 0 or
        recovery.source_last_resource_permit_generation ==
            std.math.maxInt(u64) or
        !std.meta.eql(
            recovery.receipt,
            recovery.adoption.admission.event.resource_receipt,
        ))
        return Error.InvalidPreparedAdmission;
    if (recovery.activation_grant) |grant| {
        validateSelectedSourceExitGrantV1(
            grant,
            .preparing,
        ) catch return Error.InvalidPreparedAdmission;
        if (!std.mem.eql(
            u8,
            &recovery.activation_grant_sha256,
            &grant.grant_sha256,
        ))
            return Error.InvalidPreparedAdmission;
    } else if (!isZeroDigest(
        recovery.activation_grant_sha256,
    )) return Error.InvalidPreparedAdmission;
    recovery.scheduler.validatePublicationAdoption(
        recovery.adoption,
    ) catch return Error.InvalidPreparedAdmission;
    recovery.bank.validateCommitted(
        recovery.receipt,
    ) catch return Error.InvalidPreparedAdmission;

    switch (recovery.phase) {
        .publication_session_bound, .lease_tree_open => {
            const tree = recovery.tree orelse
                return Error.InvalidPreparedAdmission;
            if (recovery.scope) |scope| {
                try validateCleanupTreeV1(
                    recovery.bank,
                    recovery.receipt,
                    tree,
                    scope,
                );
            } else {
                if (!std.meta.eql(tree.parent, recovery.receipt))
                    return Error.InvalidPreparedAdmission;
                recovery.bank.validateLeaseTree(tree) catch
                    return Error.InvalidPreparedAdmission;
            }
            if (recovery.phase == .publication_session_bound) {
                recovery.bank
                    .validateRestoredPublicationSessionWithLeaseTreeFenced(
                    tree,
                    recovery.request_epoch,
                    recovery.session_id,
                    recovery.publication_next_sequence,
                    recovery.source_last_resource_permit_generation,
                ) catch return Error.InvalidPreparedAdmission;
            }
        },
        .adoption_held => {
            if (recovery.tree != null or recovery.scope != null)
                return Error.InvalidPreparedAdmission;
            recovery.bank.validateReleaseReady(
                recovery.receipt,
            ) catch return Error.InvalidPreparedAdmission;
        },
        .recovered => unreachable,
    }
}

fn validateCleanupTreeV1(
    bank: *resource_bank.Bank,
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    scope: resource_bank.LeaseNodeV1,
) !void {
    if (!std.meta.eql(tree.parent, receipt) or
        !std.meta.eql(scope.parent, receipt) or
        scope.tree_key != tree.tree_key or
        scope.tree_identity_generation != tree.identity_generation)
        return Error.InvalidPreparedAdmission;
    bank.validateLeaseTree(tree) catch
        return Error.InvalidPreparedAdmission;
    bank.validateReceiptFundedLeaseTree(
        tree,
        false,
    ) catch return Error.InvalidPreparedAdmission;
    bank.validateLeaseNode(
        tree,
        scope,
    ) catch return Error.InvalidPreparedAdmission;
}

/// Bind the portable evidence roots to every live process-local handle. The
/// address-bearing digest is an in-process corruption/replay fence, not a
/// portable authority record.
pub fn preparedRestoredAdmissionRootV1(
    prepared: PreparedRestoredAdmissionV1,
) successor.Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bootstrap_domain);
    hash.update(&prepared.adoption.adoption_sha256);
    const receipt_sha256 =
        lane.resourceReceiptSha256(prepared.receipt);
    hash.update(&receipt_sha256);
    hashTargetV1(&hash, prepared.target);
    hashRequestSpecV1(&hash, prepared.request_spec);
    hashTreeV1(&hash, prepared.tree);
    hashNodeV1(&hash, prepared.scope);
    hashU64(&hash, @intFromPtr(prepared.scheduler));
    hashU64(&hash, @intFromPtr(prepared.bank));
    hashU64(&hash, prepared.session_id);
    hashU64(&hash, prepared.source_bank_epoch);
    hashU64(&hash, prepared.publication_next_sequence);
    hashU64(
        &hash,
        prepared.source_last_resource_permit_generation,
    );
    hash.update(&prepared.successor_execution_plan_sha256);
    hash.update(&prepared.successor_residency_binding_sha256);
    hash.update(&prepared.successor_segment_sha256);
    hash.update(&prepared.ownership_intent_sha256);
    hash.update(&prepared.challenge_sha256);
    hashU64(&hash, prepared.activation_grant_address);
    hashU64(&hash, prepared.activation_lease_address);
    hash.update(&prepared.activation_grant_sha256);
    hash.update(
        &prepared.selected_authority_checkpoint_sha256,
    );
    hash.update(&prepared.selected_selector_sha256);
    hash.update(&prepared.selected_source_exit_sha256);
    var digest: successor.Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn prepareAfterAdoptionV1(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    session_id: usize,
    evidence: EvidenceV1,
    artifacts: successor.ArtifactsV1,
    request_spec: lane.RequestSpec,
    adoption: lane.PublicationAdoptionV1,
    activation_grant: *SelectedSourceExitGrantV1,
    recovery: *PrepareRecoveryV1,
) !PreparedRestoredAdmissionV1 {
    try validateAdoptionV1(
        scheduler,
        bank,
        adoption,
        evidence.target,
        request_spec,
        artifacts.segment.request_epoch,
        session_id,
    );
    const materialized_claim =
        materializedClaimV1(evidence.target.request_claim);
    if (materialized_claim.isZero())
        return Error.InvalidPreparedAdmission;
    recovery.tree = try bank.openReceiptFundedLeaseTree(
        adoption.admission.event.resource_receipt,
        evidence.target.tree_key,
        evidence.target.authority_key,
        materialized_claim,
    );
    recovery.phase = .lease_tree_open;
    const opened = try bank.openLeaseScope(
        recovery.tree.?,
        evidence.target.scope_key,
        evidence.target.tenant_key,
        materialized_claim,
    );
    recovery.tree = opened.tree;
    recovery.scope = opened.scope;
    try bank.bindRestoredPublicationSessionWithLeaseTreeFenced(
        recovery.tree.?,
        evidence.source.receipt.bank_epoch,
        artifacts.segment.request_epoch,
        session_id,
        artifacts.segment.sequence_base,
        artifacts.segment.source_last_resource_permit_generation,
    );
    recovery.phase = .publication_session_bound;

    var prepared: PreparedRestoredAdmissionV1 = .{
        .scheduler = scheduler,
        .bank = bank,
        .target = evidence.target,
        .request_spec = request_spec,
        .adoption = adoption,
        .receipt = adoption.admission.event.resource_receipt,
        .tree = recovery.tree.?,
        .scope = recovery.scope.?,
        .session_id = session_id,
        .source_bank_epoch = evidence.source.receipt.bank_epoch,
        .publication_next_sequence = artifacts.segment.sequence_base,
        .source_last_resource_permit_generation = artifacts.segment.source_last_resource_permit_generation,
        .successor_execution_plan_sha256 = artifacts.successor_plan.plan_sha256,
        .successor_residency_binding_sha256 = artifacts.successor_residency.binding_sha256,
        .successor_segment_sha256 = artifacts.segment.segment_sha256,
        .ownership_intent_sha256 = artifacts.segment.ownership_intent_sha256,
        .challenge_sha256 = artifacts.segment.challenge_sha256,
        .activation_grant_address = @intFromPtr(activation_grant),
        .activation_lease_address = activation_grant.lease_address,
        .activation_grant_sha256 = activation_grant.grant_sha256,
        .selected_authority_checkpoint_sha256 = activation_grant.authority_checkpoint_sha256,
        .selected_selector_sha256 = activation_grant.selected_selector_sha256,
        .selected_source_exit_sha256 = activation_grant.source_exit_sha256,
        .bootstrap_sha256 = undefined,
    };
    prepared.bootstrap_sha256 =
        preparedRestoredAdmissionRootV1(prepared);
    return prepared;
}

fn validateGrantForEvidenceV1(
    activation_grant: *const SelectedSourceExitGrantV1,
    expected_phase: ActivationGrantPhase,
    evidence: EvidenceV1,
    artifacts: successor.ArtifactsV1,
) !void {
    try validateSelectedSourceExitGrantV1(
        activation_grant,
        expected_phase,
    );
    const source_receipt_sha256 =
        lane.resourceReceiptSha256(evidence.source.receipt);
    if (activation_grant.source_bank_epoch !=
        evidence.source.receipt.bank_epoch or
        activation_grant.request_epoch !=
            artifacts.segment.request_epoch or
        activation_grant.publication_next_sequence !=
            artifacts.segment.sequence_base or
        activation_grant.source_last_resource_permit_generation !=
            artifacts.segment
                .source_last_resource_permit_generation or
        !std.mem.eql(
            u8,
            &activation_grant.source_receipt_sha256,
            &source_receipt_sha256,
        ) or !std.mem.eql(
        u8,
        &activation_grant.checkpoint_sha256,
        &artifacts.segment.source_checkpoint_sha256,
    ) or !std.mem.eql(
        u8,
        &activation_grant.successor_segment_sha256,
        &artifacts.segment.segment_sha256,
    ) or !std.mem.eql(
        u8,
        &activation_grant.ownership_intent_sha256,
        &artifacts.segment.ownership_intent_sha256,
    ) or !std.mem.eql(
        u8,
        &activation_grant.challenge_sha256,
        &artifacts.segment.challenge_sha256,
    ) or evidence.source.publication.request_epoch !=
        activation_grant.request_epoch or
        evidence.source.publication.next_sequence !=
            activation_grant.publication_next_sequence or
        evidence.source.publication
            .last_resource_permit_generation !=
            activation_grant
                .source_last_resource_permit_generation)
        return Error.InvalidActivationGrant;
}

fn validatePreparedGrantBindingV1(
    prepared: *const PreparedRestoredAdmissionV1,
    activation_grant: *const SelectedSourceExitGrantV1,
    expected_phase: ActivationGrantPhase,
) !void {
    try validateSelectedSourceExitGrantV1(
        activation_grant,
        expected_phase,
    );
    if (prepared.activation_grant_address !=
        @intFromPtr(activation_grant) or
        prepared.activation_lease_address !=
            activation_grant.lease_address or
        !std.mem.eql(
            u8,
            &prepared.activation_grant_sha256,
            &activation_grant.grant_sha256,
        ) or !std.mem.eql(
        u8,
        &prepared.selected_authority_checkpoint_sha256,
        &activation_grant.authority_checkpoint_sha256,
    ) or !std.mem.eql(
        u8,
        &prepared.selected_selector_sha256,
        &activation_grant.selected_selector_sha256,
    ) or !std.mem.eql(
        u8,
        &prepared.selected_source_exit_sha256,
        &activation_grant.source_exit_sha256,
    ) or prepared.source_bank_epoch !=
        activation_grant.source_bank_epoch or
        prepared.publication_next_sequence !=
            activation_grant.publication_next_sequence or
        prepared.source_last_resource_permit_generation !=
            activation_grant
                .source_last_resource_permit_generation or
        !std.mem.eql(
            u8,
            &prepared.successor_segment_sha256,
            &activation_grant.successor_segment_sha256,
        ) or !std.mem.eql(
        u8,
        &prepared.ownership_intent_sha256,
        &activation_grant.ownership_intent_sha256,
    ) or !std.mem.eql(
        u8,
        &prepared.challenge_sha256,
        &activation_grant.challenge_sha256,
    ))
        return Error.InvalidActivationGrant;
}

fn validateFreshTargetV1(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    session_id: usize,
    artifacts: successor.ArtifactsV1,
    evidence: EvidenceV1,
    request_spec: lane.RequestSpec,
) !void {
    try validateTargetIdentityV1(scheduler, bank, evidence.target);
    const identity = try scheduler.identityV1();
    if (session_id == @intFromPtr(scheduler) or
        session_id == @intFromPtr(bank) or
        artifacts.segment.sequence_base == 0 or
        artifacts.segment.remaining_quanta == 0 or
        artifacts.segment.source_last_resource_permit_generation == 0 or
        artifacts.segment.source_last_resource_permit_generation ==
            std.math.maxInt(u64) or
        artifacts.segment.request_epoch !=
            artifacts.successor_plan.request_epoch or
        artifacts.segment.sequence_base !=
            artifacts.successor_plan.publication_next_sequence or
        !std.mem.eql(
            u8,
            &identity.challenge_sha256,
            &artifacts.segment.challenge_sha256,
        ) or
        !std.meta.eql(
            evidence.target.request_claim,
            artifacts.successor_residency.request_claim,
        ) or
        !std.meta.eql(request_spec.claim, evidence.target.request_claim))
        return Error.InvalidLiveTarget;

    const scheduler_snapshot = try scheduler.snapshot();
    if (scheduler_snapshot.scheduler_epoch !=
        evidence.target.scheduler_epoch or
        scheduler_snapshot.logical_tick != 0 or
        scheduler_snapshot.next_event_sequence != 0 or
        scheduler_snapshot.cursor != 0 or
        scheduler_snapshot.level != 1 or
        scheduler_snapshot.active != 0 or
        scheduler_snapshot.finished != 0 or
        !scheduler_snapshot.used.isZero() or
        scheduler_snapshot.poisoned or
        scheduler_snapshot.closed)
        return Error.InvalidLiveTarget;

    const bank_snapshot = try bank.snapshotV3();
    if (!freshBankSnapshotV3(bank_snapshot) or
        bank_snapshot.bank_epoch != evidence.target.bank_epoch or
        !(try bank_snapshot.limits.fits(evidence.target.request_claim)))
        return Error.InvalidLiveTarget;
    const storage = bank.lease_tree_storage orelse
        return Error.InvalidLiveTarget;
    if (storage.roots.len != bank.slots.len or
        storage.roots.len == 0 or storage.nodes.len == 0)
        return Error.InvalidLiveTarget;
}

fn validateTargetIdentityV1(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    target: successor.TargetOwnershipV1,
) !void {
    if (scheduler.bank != bank or bank.epoch != target.bank_epoch)
        return Error.InvalidLiveTarget;
    const identity = try scheduler.identityV1();
    if (identity.scheduler_epoch != target.scheduler_epoch or
        identity.coordinator_id != target.coordinator_id or
        identity.coordinator_address != @intFromPtr(scheduler) or
        identity.bank_epoch != target.bank_epoch)
        return Error.InvalidLiveTarget;
}

fn validateAdoptionV1(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    adoption: lane.PublicationAdoptionV1,
    target: successor.TargetOwnershipV1,
    request_spec: lane.RequestSpec,
    request_epoch: u64,
    session_id: usize,
) !void {
    const event = adoption.admission.event;
    if (adoption.scheduler_epoch != target.scheduler_epoch or
        adoption.coordinator_id != target.coordinator_id or
        adoption.coordinator_address != @intFromPtr(scheduler) or
        adoption.publication_request_epoch != request_epoch or
        adoption.publication_session_id != session_id or
        adoption.publication_service_policy != .every_service or
        !std.meta.eql(event.spec, request_spec) or
        !std.meta.eql(adoption.admission.handle, event.handle) or
        event.kind != .admission_accepted or
        event.resource_receipt.bank_epoch != target.bank_epoch or
        event.resource_receipt.owner_key != target.resource_owner_key or
        !std.meta.eql(event.resource_receipt.claim, target.request_claim) or
        scheduler.bank != bank)
        return Error.InvalidPreparedAdmission;
    if (!std.mem.eql(
        u8,
        &adoption.adoption_sha256,
        &lane.publicationAdoptionSha256(adoption),
    ) or
        !std.mem.eql(
            u8,
            &event.resource_receipt_sha256,
            &lane.resourceReceiptSha256(event.resource_receipt),
        ) or
        !std.mem.eql(u8, &event.event_sha256, &lane.eventSha256(event)))
        return Error.InvalidPreparedAdmission;
}

fn validatePreparedAccountingV1(
    prepared: *const PreparedRestoredAdmissionV1,
) !void {
    const scheduler_snapshot = try prepared.scheduler.snapshot();
    const bank_snapshot = try prepared.bank.snapshotV3();
    const expected_host_bytes =
        try prepared.target.request_claim.hostBytes();
    if (scheduler_snapshot.logical_tick != 0 or
        scheduler_snapshot.next_event_sequence != 1 or
        scheduler_snapshot.active != 1 or
        scheduler_snapshot.finished != 0 or
        !std.meta.eql(scheduler_snapshot.used, prepared.target.request_claim) or
        !std.mem.eql(
            u8,
            &scheduler_snapshot.chain_head_sha256,
            &prepared.adoption.admission.event.event_sha256,
        ) or
        !std.meta.eql(bank_snapshot.used, prepared.target.request_claim) or
        !std.meta.eql(bank_snapshot.peak, prepared.target.request_claim) or
        bank_snapshot.peak_host_bytes != expected_host_bytes or
        bank_snapshot.active_reservations != 0 or
        bank_snapshot.committed_receipts != 1 or
        bank_snapshot.active_child_leases != 0 or
        bank_snapshot.active_lease_trees != 1 or
        bank_snapshot.active_lease_scopes != 1 or
        bank_snapshot.active_lease_nodes != 1 or
        bank_snapshot.reserved_unmaterialized_allocations != 0 or
        bank_snapshot.live_allocations != 0 or
        bank_snapshot.quiescing_allocations != 0 or
        bank_snapshot.free_authorized_allocations != 0 or
        bank_snapshot.successful_reservations != 1 or
        bank_snapshot.successful_commits != 1 or
        bank_snapshot.cancellations != 0 or
        bank_snapshot.releases != 0 or
        bank_snapshot.rejected_capacity != 0 or
        bank_snapshot.rejected_slots != 0 or
        bank_snapshot.child_opens != 0 or
        bank_snapshot.child_grows != 0 or
        bank_snapshot.child_shrinks != 0 or
        bank_snapshot.child_closes != 0 or
        bank_snapshot.rejected_child_capacity != 0 or
        bank_snapshot.lease_tree_opens != 1 or
        bank_snapshot.lease_scope_opens != 1 or
        bank_snapshot.lease_allocation_reserves != 0 or
        bank_snapshot.lease_allocation_materializations != 0 or
        bank_snapshot.lease_allocation_aborts != 0 or
        bank_snapshot.lease_reclaim_prepares != 0 or
        bank_snapshot.lease_reclaim_authorizations != 0 or
        bank_snapshot.lease_reclaim_cancels != 0 or
        bank_snapshot.lease_reclaim_commits != 0 or
        bank_snapshot.lease_tree_closes != 0 or
        bank_snapshot.rejected_lease_capacity != 0 or
        bank_snapshot.rejected_lease_nodes != 0)
        return Error.InvalidPreparedAdmission;
}

fn freshBankSnapshotV3(snapshot: resource_bank.SnapshotV3) bool {
    return snapshot.used.isZero() and
        snapshot.peak.isZero() and
        snapshot.peak_host_bytes == 0 and
        snapshot.active_reservations == 0 and
        snapshot.committed_receipts == 0 and
        snapshot.active_child_leases == 0 and
        snapshot.active_lease_trees == 0 and
        snapshot.active_lease_scopes == 0 and
        snapshot.active_lease_nodes == 0 and
        snapshot.reserved_unmaterialized_allocations == 0 and
        snapshot.live_allocations == 0 and
        snapshot.quiescing_allocations == 0 and
        snapshot.free_authorized_allocations == 0 and
        snapshot.successful_reservations == 0 and
        snapshot.successful_commits == 0 and
        snapshot.cancellations == 0 and
        snapshot.releases == 0 and
        snapshot.rejected_capacity == 0 and
        snapshot.rejected_slots == 0 and
        snapshot.child_opens == 0 and
        snapshot.child_grows == 0 and
        snapshot.child_shrinks == 0 and
        snapshot.child_closes == 0 and
        snapshot.rejected_child_capacity == 0 and
        snapshot.lease_tree_opens == 0 and
        snapshot.lease_scope_opens == 0 and
        snapshot.lease_allocation_reserves == 0 and
        snapshot.lease_allocation_materializations == 0 and
        snapshot.lease_allocation_aborts == 0 and
        snapshot.lease_reclaim_prepares == 0 and
        snapshot.lease_reclaim_authorizations == 0 and
        snapshot.lease_reclaim_cancels == 0 and
        snapshot.lease_reclaim_commits == 0 and
        snapshot.lease_tree_closes == 0 and
        snapshot.rejected_lease_capacity == 0 and
        snapshot.rejected_lease_nodes == 0;
}

fn requestSpecFromPreparedV1(
    prepared: *const PreparedRestoredAdmissionV1,
) lane.RequestSpec {
    return .{
        .tenant_key = prepared.target.tenant_key,
        .request_key = prepared.target.authority_key,
        .request_generation = prepared.target.request_generation,
        .resource_owner_key = prepared.target.resource_owner_key,
        .weight = canonical_request_weight,
        .work_quanta = prepared.adoption.admission.event.spec.work_quanta,
        .deadline_tick = canonical_deadline_tick,
        .claim = prepared.target.request_claim,
    };
}

fn hashTargetV1(
    hash: *std.crypto.hash.sha2.Sha256,
    target: successor.TargetOwnershipV1,
) void {
    hashU64(hash, target.scheduler_epoch);
    hashU64(hash, target.coordinator_id);
    hashU64(hash, target.bank_epoch);
    hashU64(hash, target.request_generation);
    hashU64(hash, target.resource_owner_key);
    hashU64(hash, target.tree_key);
    hashU64(hash, target.authority_key);
    hashU64(hash, target.tenant_key);
    hashU64(hash, target.scope_key);
    hashU64(hash, target.cache_node_key);
    hashU64(hash, target.cache_binding_key);
    hashU64(hash, target.intent_generation);
    hashClaimV1(hash, target.request_claim);
}

fn hashRequestSpecV1(
    hash: *std.crypto.hash.sha2.Sha256,
    spec: lane.RequestSpec,
) void {
    hashU64(hash, spec.tenant_key);
    hashU64(hash, spec.request_key);
    hashU64(hash, spec.request_generation);
    hashU64(hash, spec.resource_owner_key);
    hashU64(hash, spec.weight);
    hashU64(hash, spec.work_quanta);
    hashU64(hash, spec.deadline_tick);
    hashClaimV1(hash, spec.claim);
}

fn hashTreeV1(
    hash: *std.crypto.hash.sha2.Sha256,
    tree: resource_bank.LeaseTreeV1,
) void {
    hashU64(hash, tree.abi_version);
    const receipt_sha256 = lane.resourceReceiptSha256(tree.parent);
    hash.update(&receipt_sha256);
    hashU64(hash, tree.tree_key);
    hashU64(hash, tree.authority_key);
    hashU64(hash, tree.identity_generation);
    hashU64(hash, tree.generation);
    hashU64(hash, tree.structural_revision);
    hashClaimV1(hash, tree.ceiling);
    hashClaimV1(hash, tree.current);
    hashU64(hash, tree.active_nodes);
    hashU64(hash, tree.state_digest);
    hashU64(hash, tree.integrity);
}

fn hashNodeV1(
    hash: *std.crypto.hash.sha2.Sha256,
    node: resource_bank.LeaseNodeV1,
) void {
    hashU64(hash, node.abi_version);
    const receipt_sha256 = lane.resourceReceiptSha256(node.parent);
    hash.update(&receipt_sha256);
    hashU64(hash, node.tree_key);
    hashU64(hash, node.tree_identity_generation);
    hashU64(hash, node.node_index);
    hashU64(hash, node.generation);
    hashU64(hash, node.parent_index);
    hashU64(hash, node.parent_generation);
    hashU64(hash, node.node_key);
    hashU64(hash, node.tenant_key);
    hashU64(hash, node.binding_key);
    hashU64(hash, @intFromEnum(node.kind));
    hashClaimV1(hash, node.ceiling);
    hashClaimV1(hash, node.claim);
    hashU64(hash, node.integrity);
}

fn hashClaimV1(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    hashU64(hash, claim.capsule_bytes);
    hashU64(hash, claim.kv_bytes);
    hashU64(hash, claim.activation_bytes);
    hashU64(hash, claim.partial_bytes);
    hashU64(hash, claim.logits_bytes);
    hashU64(hash, claim.output_journal_bytes);
    hashU64(hash, claim.staging_bytes);
    hashU64(hash, claim.device_bytes);
    hashU64(hash, claim.io_bytes);
    hashU64(hash, claim.queue_slots);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn isZeroDigest(value: successor.Digest) bool {
    return std.mem.eql(
        u8,
        &value,
        &([_]u8{0} ** 32),
    );
}

fn preparedCleanupFixtureV1(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    adoption: lane.PublicationAdoptionV1,
    tree: resource_bank.LeaseTreeV1,
    scope: resource_bank.LeaseNodeV1,
    source_bank_epoch: u64,
    publication_next_sequence: u64,
    source_last_resource_permit_generation: u64,
    phase: Phase,
) PreparedRestoredAdmissionV1 {
    const event = adoption.admission.event;
    return .{
        .scheduler = scheduler,
        .bank = bank,
        .target = .{
            .scheduler_epoch = adoption.scheduler_epoch,
            .coordinator_id = adoption.coordinator_id,
            .bank_epoch = bank.epoch,
            .request_generation = event.spec.request_generation,
            .resource_owner_key = event.spec.resource_owner_key,
            .tree_key = tree.tree_key,
            .authority_key = event.spec.request_key,
            .tenant_key = event.spec.tenant_key,
            .scope_key = scope.node_key,
            .cache_node_key = 1,
            .cache_binding_key = 2,
            .intent_generation = event.spec.request_generation,
            .request_claim = event.spec.claim,
        },
        .request_spec = event.spec,
        .adoption = adoption,
        .receipt = event.resource_receipt,
        .tree = tree,
        .scope = scope,
        .session_id = adoption.publication_session_id,
        .source_bank_epoch = source_bank_epoch,
        .publication_next_sequence = publication_next_sequence,
        .source_last_resource_permit_generation = source_last_resource_permit_generation,
        .successor_execution_plan_sha256 = [_]u8{0} ** 32,
        .successor_residency_binding_sha256 = [_]u8{0} ** 32,
        .successor_segment_sha256 = [_]u8{0} ** 32,
        .ownership_intent_sha256 = [_]u8{0} ** 32,
        .challenge_sha256 = [_]u8{0} ** 32,
        .bootstrap_sha256 = [_]u8{0} ** 32,
        .phase = phase,
    };
}

test "prepare recovery consumes adoption-only and bound-tree authority" {
    const testing = std.testing;
    const claim: resource_bank.Claim = .{
        .kv_bytes = 16,
        .queue_slots = 1,
    };
    const request_spec: lane.RequestSpec = .{
        .tenant_key = 1,
        .request_key = 2,
        .request_generation = 3,
        .resource_owner_key = 4,
        .weight = 1,
        .work_quanta = 1,
        .claim = claim,
    };
    const challenge = [_]u8{0x71} ** 32;

    {
        var slots: [1]resource_bank.Slot = undefined;
        var roots: [1]resource_bank.LeaseTreeRootSlot = undefined;
        var nodes: [1]resource_bank.LeaseNodeSlot = undefined;
        var bank = try resource_bank.Bank.initWithLeaseTree(
            &slots,
            &roots,
            &nodes,
            .{},
            101,
        );
        var lane_slots: [1]lane.Slot = undefined;
        var projection: [1]lane.ProjectionSlot = undefined;
        var scheduler = try lane.Scheduler.initWithLeaseTree(
            &bank,
            .{
                .slots = &lane_slots,
                .projection = &projection,
            },
            .{
                .scheduler_epoch = 201,
                .challenge = challenge,
                .max_weight = 1,
            },
        );
        var session_identity: u8 = 0;
        const session_id = @intFromPtr(&session_identity);
        const decision = try scheduler.admitForPublicationAdoption(
            request_spec,
            301,
            session_id,
        );
        const adoption = switch (decision) {
            .adopted => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        var recovery: PrepareRecoveryV1 = .{
            .scheduler = &scheduler,
            .bank = &bank,
            .adoption = adoption,
            .receipt = adoption.admission.event.resource_receipt,
            .session_id = session_id,
            .request_epoch = 301,
            .publication_next_sequence = 7,
            .source_last_resource_permit_generation = 5,
        };
        const event = try recoverPrepareRestoredAdmissionV1(
            &recovery,
        );
        try testing.expectEqual(lane.EventKind.cancel, event.kind);
        try testing.expectEqual(
            PrepareRecoveryPhase.recovered,
            recovery.phase,
        );
        try testing.expect((try bank.snapshotV3()).used.isZero());
        try testing.expectError(
            Error.InvalidPreparedAdmission,
            recoverPrepareRestoredAdmissionV1(&recovery),
        );
        _ = try scheduler.close();
    }

    {
        var slots: [1]resource_bank.Slot = undefined;
        var roots: [1]resource_bank.LeaseTreeRootSlot = undefined;
        var nodes: [1]resource_bank.LeaseNodeSlot = undefined;
        var bank = try resource_bank.Bank.initWithLeaseTree(
            &slots,
            &roots,
            &nodes,
            .{},
            102,
        );
        var lane_slots: [1]lane.Slot = undefined;
        var projection: [1]lane.ProjectionSlot = undefined;
        var scheduler = try lane.Scheduler.initWithLeaseTree(
            &bank,
            .{
                .slots = &lane_slots,
                .projection = &projection,
            },
            .{
                .scheduler_epoch = 202,
                .challenge = challenge,
                .max_weight = 1,
            },
        );
        var session_identity: u8 = 0;
        const session_id = @intFromPtr(&session_identity);
        const decision = try scheduler.admitForPublicationAdoption(
            request_spec,
            302,
            session_id,
        );
        const adoption = switch (decision) {
            .adopted => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        const receipt = adoption.admission.event.resource_receipt;
        const opened = try bank.openReceiptFundedLeaseTree(
            receipt,
            11,
            12,
            materializedClaimV1(claim),
        );
        const scoped = try bank.openLeaseScope(
            opened,
            13,
            request_spec.tenant_key,
            materializedClaimV1(claim),
        );
        try bank.bindRestoredPublicationSessionWithLeaseTreeFenced(
            scoped.tree,
            99,
            302,
            session_id,
            8,
            6,
        );
        try testing.expectError(
            resource_bank.Error.InvalidTransition,
            bank.validateReleaseReady(receipt),
        );
        var recovery: PrepareRecoveryV1 = .{
            .scheduler = &scheduler,
            .bank = &bank,
            .adoption = adoption,
            .receipt = receipt,
            .tree = scoped.tree,
            .scope = scoped.scope,
            .session_id = session_id,
            .request_epoch = 302,
            .publication_next_sequence = 8,
            .source_last_resource_permit_generation = 6,
            .phase = .publication_session_bound,
        };
        const event = try recoverPrepareRestoredAdmissionV1(
            &recovery,
        );
        try testing.expectEqual(lane.EventKind.cancel, event.kind);
        try testing.expectEqual(
            PrepareRecoveryPhase.recovered,
            recovery.phase,
        );
        try testing.expect(recovery.tree == null);
        try testing.expect(recovery.scope == null);
        const snapshot = try bank.snapshotV3();
        try testing.expect(snapshot.used.isZero());
        try testing.expectEqual(@as(u32, 0), snapshot.active_lease_trees);
        try testing.expectEqual(@as(u32, 0), snapshot.active_lease_scopes);
        _ = try scheduler.close();
    }

    {
        var slots: [1]resource_bank.Slot = undefined;
        var roots: [1]resource_bank.LeaseTreeRootSlot = undefined;
        var nodes: [1]resource_bank.LeaseNodeSlot = undefined;
        var bank = try resource_bank.Bank.initWithLeaseTree(
            &slots,
            &roots,
            &nodes,
            .{},
            103,
        );
        var lane_slots: [1]lane.Slot = undefined;
        var projection: [1]lane.ProjectionSlot = undefined;
        var scheduler = try lane.Scheduler.initWithLeaseTree(
            &bank,
            .{
                .slots = &lane_slots,
                .projection = &projection,
            },
            .{
                .scheduler_epoch = 203,
                .challenge = challenge,
                .max_weight = 1,
            },
        );
        var session_identity: u8 = 0;
        const session_id = @intFromPtr(&session_identity);
        const decision = try scheduler.admitForPublicationAdoption(
            request_spec,
            303,
            session_id,
        );
        const adoption = switch (decision) {
            .adopted => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        const receipt = adoption.admission.event.resource_receipt;
        const opened = try bank.openReceiptFundedLeaseTree(
            receipt,
            21,
            22,
            materializedClaimV1(claim),
        );
        const scoped = try bank.openLeaseScope(
            opened,
            23,
            request_spec.tenant_key,
            materializedClaimV1(claim),
        );
        try bank.bindRestoredPublicationSessionWithLeaseTreeFenced(
            scoped.tree,
            99,
            303,
            session_id,
            9,
            7,
        );
        var recovery: PrepareRecoveryV1 = .{
            .scheduler = &scheduler,
            .bank = &bank,
            .adoption = adoption,
            .receipt = receipt,
            .tree = scoped.tree,
            .scope = scoped.scope,
            .session_id = session_id,
            .request_epoch = 303,
            .publication_next_sequence = 9,
            .source_last_resource_permit_generation = 7,
            .phase = .lease_tree_open,
        };
        const before = try bank.snapshotV3();
        var missing_tree = recovery;
        missing_tree.tree = null;
        try testing.expectError(
            Error.InvalidPreparedAdmission,
            recoverPrepareRestoredAdmissionV1(&missing_tree),
        );
        try testing.expectEqualDeep(before, try bank.snapshotV3());
        try testing.expectError(
            Error.RecoveryRequired,
            recoverPrepareRestoredAdmissionV1(&recovery),
        );
        try testing.expectEqual(
            PrepareRecoveryPhase.lease_tree_open,
            recovery.phase,
        );
        try testing.expectEqualDeep(before, try bank.snapshotV3());

        // Repair the external session that violated the retained phase, then
        // retry the exact same recovery authority.
        try bank.closePublicationSession(
            receipt,
            303,
            session_id,
            9,
        );
        const event = try recoverPrepareRestoredAdmissionV1(
            &recovery,
        );
        try testing.expectEqual(lane.EventKind.cancel, event.kind);
        try testing.expectEqual(
            PrepareRecoveryPhase.recovered,
            recovery.phase,
        );
        try testing.expect((try bank.snapshotV3()).used.isZero());
        _ = try scheduler.close();
    }
}

test "prepared abort resumes exact closed-session and closed-tree phases" {
    const testing = std.testing;
    const claim: resource_bank.Claim = .{
        .kv_bytes = 16,
        .queue_slots = 1,
    };
    const request_spec: lane.RequestSpec = .{
        .tenant_key = 31,
        .request_key = 32,
        .request_generation = 33,
        .resource_owner_key = 34,
        .weight = 1,
        .work_quanta = 1,
        .claim = claim,
    };
    const challenge = [_]u8{0x72} ** 32;

    {
        var slots: [1]resource_bank.Slot = undefined;
        var roots: [1]resource_bank.LeaseTreeRootSlot = undefined;
        var nodes: [1]resource_bank.LeaseNodeSlot = undefined;
        var bank = try resource_bank.Bank.initWithLeaseTree(
            &slots,
            &roots,
            &nodes,
            .{},
            104,
        );
        var lane_slots: [1]lane.Slot = undefined;
        var projection: [1]lane.ProjectionSlot = undefined;
        var scheduler = try lane.Scheduler.initWithLeaseTree(
            &bank,
            .{
                .slots = &lane_slots,
                .projection = &projection,
            },
            .{
                .scheduler_epoch = 204,
                .challenge = challenge,
                .max_weight = 1,
            },
        );
        var session_identity: u8 = 0;
        const session_id = @intFromPtr(&session_identity);
        const decision = try scheduler.admitForPublicationAdoption(
            request_spec,
            304,
            session_id,
        );
        const adoption = switch (decision) {
            .adopted => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        const receipt = adoption.admission.event.resource_receipt;
        const opened = try bank.openReceiptFundedLeaseTree(
            receipt,
            41,
            request_spec.request_key,
            materializedClaimV1(claim),
        );
        const scoped = try bank.openLeaseScope(
            opened,
            42,
            request_spec.tenant_key,
            materializedClaimV1(claim),
        );
        try bank.bindRestoredPublicationSessionWithLeaseTreeFenced(
            scoped.tree,
            99,
            304,
            session_id,
            10,
            8,
        );
        try bank.closePublicationSession(
            receipt,
            304,
            session_id,
            10,
        );
        var prepared = preparedCleanupFixtureV1(
            &scheduler,
            &bank,
            adoption,
            scoped.tree,
            scoped.scope,
            99,
            10,
            8,
            .publication_session_closed,
        );
        const event = try abortPreparedRestoredAdmissionV1Internal(
            &prepared,
        );
        try testing.expectEqual(lane.EventKind.cancel, event.kind);
        try testing.expectEqual(Phase.aborted, prepared.phase);
        const snapshot = try bank.snapshotV3();
        try testing.expect(snapshot.used.isZero());
        try testing.expectEqual(@as(u32, 0), snapshot.active_lease_trees);
        try testing.expectEqual(@as(u32, 0), snapshot.active_lease_scopes);
        _ = try scheduler.close();
    }

    {
        var slots: [1]resource_bank.Slot = undefined;
        var roots: [1]resource_bank.LeaseTreeRootSlot = undefined;
        var nodes: [1]resource_bank.LeaseNodeSlot = undefined;
        var bank = try resource_bank.Bank.initWithLeaseTree(
            &slots,
            &roots,
            &nodes,
            .{},
            105,
        );
        var lane_slots: [1]lane.Slot = undefined;
        var projection: [1]lane.ProjectionSlot = undefined;
        var scheduler = try lane.Scheduler.initWithLeaseTree(
            &bank,
            .{
                .slots = &lane_slots,
                .projection = &projection,
            },
            .{
                .scheduler_epoch = 205,
                .challenge = challenge,
                .max_weight = 1,
            },
        );
        var session_identity: u8 = 0;
        const session_id = @intFromPtr(&session_identity);
        const decision = try scheduler.admitForPublicationAdoption(
            request_spec,
            305,
            session_id,
        );
        const adoption = switch (decision) {
            .adopted => |value| value,
            .rejected => return error.TestUnexpectedResult,
        };
        const receipt = adoption.admission.event.resource_receipt;
        const opened = try bank.openReceiptFundedLeaseTree(
            receipt,
            51,
            request_spec.request_key,
            materializedClaimV1(claim),
        );
        const scoped = try bank.openLeaseScope(
            opened,
            52,
            request_spec.tenant_key,
            materializedClaimV1(claim),
        );
        try bank.bindRestoredPublicationSessionWithLeaseTreeFenced(
            scoped.tree,
            99,
            305,
            session_id,
            11,
            9,
        );
        try bank.closePublicationSession(
            receipt,
            305,
            session_id,
            11,
        );
        try bank.closeLeaseTree(scoped.tree);
        var prepared = preparedCleanupFixtureV1(
            &scheduler,
            &bank,
            adoption,
            scoped.tree,
            scoped.scope,
            99,
            11,
            9,
            .lease_tree_closed,
        );
        const event = try abortPreparedRestoredAdmissionV1Internal(
            &prepared,
        );
        try testing.expectEqual(lane.EventKind.cancel, event.kind);
        try testing.expectEqual(Phase.aborted, prepared.phase);
        try testing.expect((try bank.snapshotV3()).used.isZero());
        _ = try scheduler.close();
    }
}
