//! Source-liveness authority for prepared-text durable handoff.
//!
//! A source keeps one address-stable `SourceLiveGrantV1` for as long as it may
//! serve the generation-one publication. The grant owns the checkpoint
//! lease's single consumer claim, so a copied grant, a moved grant, or a second
//! grant over the same lease cannot acquire source authority.
//!
//! `SourceLiveGrantV1` is deliberately process-local. Its logical roots never
//! hash or encode pointers; `self_address`, `lease_address`, and the underlying
//! consumer claim exist only to fence live in-process authority.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const lane = core.lane_weave_qos;
const platform_capabilities = core.platform_capabilities;
const resource_bank = core.resource_bank;
const source_exit_wire =
    @import("prepared_text_source_exit_wire.zig");
const source_recovery =
    @import("prepared_text_source_recovery.zig");

pub const Digest = checkpoint_file.Digest;
pub const source_live_marker_abi: u64 = 0x4750_544c_0000_0001;
pub const source_live_grant_abi: u64 = 0x4750_5447_0000_0001;
pub const source_replay_grant_abi: u64 = 0x4750_5447_0000_0002;
pub const source_live_set_generation: u64 = 1;
pub const immediate_successor_generation: u64 = 2;
pub const source_live_object_ordinal: u64 = 0;
pub const source_recovery_object_ordinal: u64 = 1;
pub const source_live_marker =
    "glacier-prepared-text-source-live-v1";

const source_binding_domain =
    "glacier-prepared-text-source-binding-v1\x00";
const source_live_grant_domain =
    "glacier-prepared-text-source-live-grant-v1\x00";
const source_replay_grant_domain =
    "glacier-prepared-text-source-live-grant-v2\x00";

pub const Error = checkpoint_file.Error ||
    source_recovery.Error ||
    source_exit_wire.Error ||
    error{
        InvalidSourceLiveMarker,
        InvalidSourceLiveGrant,
        InvalidSourceBinding,
        InvalidSourceExit,
        InvalidSuccessorSelection,
    };

pub const SourceLivePhaseV1 = enum(u8) {
    empty,
    ready,
    bound,
    handoff,
    exit_committed,
    completed,
};

/// Pointer-free source identity bound once to a generation-one grant.
///
/// `publication_next_sequence` is N and
/// `source_last_resource_permit_generation` is G.
pub const SourceBindingV1 = struct {
    source_scheduler_epoch: u64,
    source_coordinator_id: u64,
    source_bank_epoch: u64,
    request_sha256: Digest,
    publication_next_sequence: u64,
    source_last_resource_permit_generation: u64,
    source_receipt_sha256: Digest,
};

/// The exact immediate selector publication observed after source exit.
pub const ImmediateSuccessorV1 = struct {
    checkpoint_sha256: Digest,
    selector_sha256: Digest,
};

/// Address-fenced source authority. This value must not be copied, moved after
/// initialization, or serialized.
pub const SourceLiveGrantV1 = struct {
    lease: ?*checkpoint_file.LeaseV1 = null,
    self_address: usize = 0,
    lease_address: usize = 0,
    consumer_claim: checkpoint_file.ConsumerClaimV1 = .{},

    request_epoch: u64 = 0,
    publication_next_sequence: u64 = 0,
    source_checkpoint_sha256: Digest = [_]u8{0} ** 32,
    source_selector_sha256: Digest = [_]u8{0} ** 32,
    challenge_sha256: Digest = [_]u8{0} ** 32,
    source_recovery_contract_sha256: Digest = [_]u8{0} ** 32,

    source_scheduler_epoch: u64 = 0,
    source_coordinator_id: u64 = 0,
    source_bank_epoch: u64 = 0,
    request_sha256: Digest = [_]u8{0} ** 32,
    source_last_resource_permit_generation: u64 = 0,
    source_receipt_sha256: Digest = [_]u8{0} ** 32,
    source_binding_sha256: Digest = [_]u8{0} ** 32,

    source_exit_sha256: Digest = [_]u8{0} ** 32,
    successor_checkpoint_sha256: Digest = [_]u8{0} ** 32,
    successor_selector_sha256: Digest = [_]u8{0} ** 32,
    grant_sha256: Digest = [_]u8{0} ** 32,
    phase: SourceLivePhaseV1 = .empty,
};

const SourceLiveAuthorityV1 = struct {
    request_epoch: u64,
    publication_next_sequence: u64,
    checkpoint_sha256: Digest,
    selector_sha256: Digest,
    challenge_sha256: Digest,
    source_recovery_contract_sha256: Digest,
};

/// Encode the one-object canonical generation-one source-live checkpoint.
pub fn encodeSourceLiveSetV1(
    request_epoch: u64,
    publication_next_sequence: u64,
    challenge_sha256: Digest,
    destination: []u8,
) checkpoint_file.Error!checkpoint_file.PreparedSetV1 {
    const objects = [_]checkpoint_file.ObjectInputV1{.{
        .kind = .extension,
        .ordinal = source_live_object_ordinal,
        .abi_version = source_live_marker_abi,
        .bytes = source_live_marker,
    }};
    return checkpoint_file.encodeSetV1(
        .{
            .generation = source_live_set_generation,
            .request_epoch = request_epoch,
            .publication_next_sequence = publication_next_sequence,
            .parent_checkpoint_sha256 = [_]u8{0} ** 32,
            .challenge_sha256 = challenge_sha256,
        },
        &objects,
        destination,
    );
}

/// Encode a generation-one source authority that retains the exact replay
/// contract needed by a fresh process. The legacy one-object marker remains
/// available for retained V1 fixtures, while this two-object form is the
/// recoverable source enrollment used by later handoff generations.
pub fn encodeRecoverableSourceLiveSetV1(
    encoded_contract: source_recovery.EncodedV1,
    destination: []u8,
) Error!checkpoint_file.PreparedSetV1 {
    const contract = try source_recovery.decodeV1(
        encoded_contract.bytes,
    );
    if (!digestEqual(
        contract.contract_sha256,
        encoded_contract.contract_sha256,
    ))
        return Error.InvalidSourceLiveMarker;
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = source_live_object_ordinal,
            .abi_version = source_live_marker_abi,
            .bytes = source_live_marker,
        },
        .{
            .kind = .extension,
            .ordinal = source_recovery_object_ordinal,
            .abi_version = source_recovery.contract_abi,
            .bytes = encoded_contract.bytes,
        },
    };
    return checkpoint_file.encodeSetV1(
        .{
            .generation = source_live_set_generation,
            .request_epoch = contract.request_epoch,
            .publication_next_sequence = contract.publication_next_sequence,
            .parent_checkpoint_sha256 = [_]u8{0} ** 32,
            .challenge_sha256 = contract.challenge_sha256,
        },
        &objects,
        destination,
    );
}

/// Acquire the lease-owned single consumer claim over the exact active
/// generation-one source-live marker.
pub fn initSourceLiveGrantV1(
    grant: *SourceLiveGrantV1,
    lease: *checkpoint_file.LeaseV1,
) Error!void {
    if (!sourceLiveGrantEmptyV1(grant.*))
        return Error.InvalidSourceLiveGrant;
    const authority = try sourceLiveAuthorityV1(lease);
    const consumer_claim = try lease.beginConsumerClaimV1(
        @intFromPtr(grant),
    );
    errdefer lease.releaseConsumerClaimV1(consumer_claim) catch {};
    errdefer grant.* = .{};

    grant.* = .{
        .lease = lease,
        .self_address = @intFromPtr(grant),
        .lease_address = @intFromPtr(lease),
        .consumer_claim = consumer_claim,
        .request_epoch = authority.request_epoch,
        .publication_next_sequence = authority.publication_next_sequence,
        .source_checkpoint_sha256 = authority.checkpoint_sha256,
        .source_selector_sha256 = authority.selector_sha256,
        .challenge_sha256 = authority.challenge_sha256,
        .source_recovery_contract_sha256 = authority.source_recovery_contract_sha256,
        .phase = .ready,
    };
    grant.grant_sha256 = sourceLiveGrantRootV1(grant.*);
    try validateSourceLiveGrantV1(grant, .ready);
}

/// Bind the grant once to the source scheduler, coordinator, Bank, request,
/// N/G lineage counters, and live resource receipt.
pub fn bindSourceLiveGrantV1(
    grant: *SourceLiveGrantV1,
    binding: SourceBindingV1,
) Error!void {
    try validateSourceLiveGrantV1(grant, .ready);
    if (!sourceBindingValidV1(binding) or
        binding.publication_next_sequence !=
            grant.publication_next_sequence)
        return Error.InvalidSourceBinding;

    grant.source_scheduler_epoch =
        binding.source_scheduler_epoch;
    grant.source_coordinator_id =
        binding.source_coordinator_id;
    grant.source_bank_epoch = binding.source_bank_epoch;
    grant.request_sha256 = binding.request_sha256;
    grant.source_last_resource_permit_generation =
        binding.source_last_resource_permit_generation;
    grant.source_receipt_sha256 =
        binding.source_receipt_sha256;
    grant.source_binding_sha256 =
        sourceBindingRootV1(binding);
    grant.grant_sha256 = sourceLiveGrantRootV1(grant.*);
    grant.phase = .bound;
    try validateSourceLiveGrantV1(grant, .bound);
}

pub fn beginSourceHandoffV1(
    grant: *SourceLiveGrantV1,
) Error!void {
    try validateSourceLiveGrantV1(grant, .bound);
    grant.phase = .handoff;
    try validateSourceLiveGrantV1(grant, .handoff);
}

pub fn abortSourceHandoffV1(
    grant: *SourceLiveGrantV1,
) Error!void {
    try validateSourceLiveGrantV1(grant, .handoff);
    grant.phase = .bound;
    try validateSourceLiveGrantV1(grant, .bound);
}

/// Record the pointer-free root returned by the committed source-exit
/// transaction. The caller remains responsible for publishing generation two.
pub fn markSourceExitCommittedV1(
    grant: *SourceLiveGrantV1,
    source_exit_sha256: Digest,
) Error!void {
    try validateSourceLiveGrantV1(grant, .handoff);
    if (isZero(source_exit_sha256))
        return Error.InvalidSourceExit;
    grant.source_exit_sha256 = source_exit_sha256;
    grant.grant_sha256 = sourceLiveGrantRootV1(grant.*);
    grant.phase = .exit_committed;
    try validateSourceLiveGrantV1(grant, .exit_committed);
}

/// Release a source-live marker that will not be handed off. Only a ready or
/// bound source can abandon the grant; a committed source exit must publish
/// and complete its immediate successor instead.
pub fn releaseSourceLiveGrantV1(
    grant: *SourceLiveGrantV1,
) Error!void {
    const phase = grant.phase;
    if (phase != .ready and phase != .bound)
        return Error.InvalidSourceLiveGrant;
    try validateSourceLiveGrantV1(grant, phase);
    const lease = grant.lease orelse
        return Error.InvalidSourceLiveGrant;
    try lease.releaseConsumerClaimV1(grant.consumer_claim);
    grant.consumer_claim = .{};
    grant.lease = null;
    grant.phase = .completed;
}

/// Complete source handoff only after the caller has durably published the
/// immediate generation-two selector on this exact lease. The retained claim
/// is advanced across the one-generation lineage edge, released, and the
/// grant is permanently completed.
pub fn completeSourceHandoffV1(
    grant: *SourceLiveGrantV1,
    successor: ImmediateSuccessorV1,
) Error!void {
    const lease = try validateSourceLiveGrantShapeV1(
        grant,
        .exit_committed,
    );
    if (isZero(successor.checkpoint_sha256) or
        isZero(successor.selector_sha256) or
        !isZero(grant.successor_checkpoint_sha256) or
        !isZero(grant.successor_selector_sha256))
        return Error.InvalidSuccessorSelection;

    const active_set = lease.activeSet() catch
        return Error.InvalidSuccessorSelection;
    const recoverable =
        !isZero(grant.source_recovery_contract_sha256);
    if (active_set.object_count !=
        @as(usize, if (recoverable) 3 else 2) or
        lease.selector.generation !=
            immediate_successor_generation or
        active_set.metadata.generation !=
            immediate_successor_generation or
        lease.selector.request_epoch != grant.request_epoch or
        active_set.metadata.request_epoch != grant.request_epoch or
        lease.selector.publication_next_sequence !=
            grant.publication_next_sequence or
        active_set.metadata.publication_next_sequence !=
            grant.publication_next_sequence or
        lease.selector.checkpoint_bytes !=
            @as(u64, @intCast(lease.stream().len)) or
        !digestEqual(
            lease.selector.previous_selector_sha256,
            grant.source_selector_sha256,
        ) or !digestEqual(
        active_set.metadata.parent_checkpoint_sha256,
        grant.source_checkpoint_sha256,
    ) or !digestEqual(
        lease.selector.selector_sha256,
        successor.selector_sha256,
    ) or !digestEqual(
        active_set.checkpoint_sha256,
        successor.checkpoint_sha256,
    ) or !digestEqual(
        lease.selector.checkpoint_sha256,
        successor.checkpoint_sha256,
    ) or !digestEqual(
        lease.selector.challenge_sha256,
        grant.challenge_sha256,
    ) or !digestEqual(
        active_set.metadata.challenge_sha256,
        grant.challenge_sha256,
    ))
        return Error.InvalidSuccessorSelection;

    const exit_object = active_set.objects[0];
    if (exit_object.kind != .source_process or
        exit_object.ordinal != 0 or
        exit_object.abi_version !=
            source_exit_wire.wire_abi or
        exit_object.bytes.len !=
            source_exit_wire.wire_bytes)
        return Error.InvalidSuccessorSelection;
    const selected_exit =
        source_exit_wire.decodeV1(
            exit_object.bytes,
        ) catch return Error.InvalidSuccessorSelection;
    if (!digestEqual(
        selected_exit.source_exit_sha256,
        grant.source_exit_sha256,
    ) or selected_exit.scheduler_epoch !=
        grant.source_scheduler_epoch or
        selected_exit.coordinator_id !=
            grant.source_coordinator_id or
        selected_exit.source_receipt.bank_epoch !=
            grant.source_bank_epoch or
        selected_exit.publication_request_epoch !=
            grant.request_epoch or
        selected_exit.expected_next_sequence !=
            grant.publication_next_sequence or
        selected_exit.source_last_publication_permit_generation !=
            grant.source_last_resource_permit_generation or
        !digestEqual(
            selected_exit.source_receipt_sha256,
            grant.source_receipt_sha256,
        ) or !digestEqual(
        selected_exit.predecessor_selector_sha256,
        grant.source_selector_sha256,
    ))
        return Error.InvalidSuccessorSelection;
    if (recoverable) {
        const contract_object = active_set.objects[2];
        if (contract_object.kind != .extension or
            contract_object.ordinal !=
                source_recovery_object_ordinal or
            contract_object.abi_version !=
                source_recovery.contract_abi)
            return Error.InvalidSuccessorSelection;
        const contract = source_recovery.decodeV1(
            contract_object.bytes,
        ) catch return Error.InvalidSuccessorSelection;
        if (!digestEqual(
            contract.contract_sha256,
            grant.source_recovery_contract_sha256,
        ))
            return Error.InvalidSuccessorSelection;
    }

    if (grant.consumer_claim.selector_generation ==
        source_live_set_generation)
    {
        grant.consumer_claim = lease.advanceConsumerClaimV1(
            grant.consumer_claim,
        ) catch return Error.InvalidSuccessorSelection;
    } else if (grant.consumer_claim.selector_generation ==
        immediate_successor_generation)
    {
        lease.validateConsumerClaimV1(
            grant.consumer_claim,
        ) catch return Error.InvalidSuccessorSelection;
    } else {
        return Error.InvalidSuccessorSelection;
    }
    try lease.releaseConsumerClaimV1(grant.consumer_claim);

    grant.consumer_claim = .{};
    grant.lease = null;
    grant.successor_checkpoint_sha256 =
        successor.checkpoint_sha256;
    grant.successor_selector_sha256 =
        successor.selector_sha256;
    grant.grant_sha256 = sourceLiveGrantRootV1(grant.*);
    grant.phase = .completed;
}

/// Validate a live phase and prove that the exact generation-one selector and
/// marker remain selected under the retained lease-owned claim.
pub fn validateSourceLiveGrantV1(
    grant: *const SourceLiveGrantV1,
    expected_phase: SourceLivePhaseV1,
) Error!void {
    const lease = try validateSourceLiveGrantShapeV1(
        grant,
        expected_phase,
    );
    if (grant.consumer_claim.selector_generation !=
        source_live_set_generation or
        !digestEqual(
            grant.consumer_claim.selector_sha256,
            grant.source_selector_sha256,
        ))
        return Error.InvalidSourceLiveGrant;
    lease.validateConsumerClaimV1(
        grant.consumer_claim,
    ) catch return Error.InvalidSourceLiveGrant;
    const authority = sourceLiveAuthorityV1(lease) catch
        return Error.InvalidSourceLiveGrant;
    if (authority.request_epoch != grant.request_epoch or
        authority.publication_next_sequence !=
            grant.publication_next_sequence or
        !digestEqual(
            authority.checkpoint_sha256,
            grant.source_checkpoint_sha256,
        ) or !digestEqual(
        authority.selector_sha256,
        grant.source_selector_sha256,
    ) or !digestEqual(
        authority.challenge_sha256,
        grant.challenge_sha256,
    ) or !digestEqual(
        authority.source_recovery_contract_sha256,
        grant.source_recovery_contract_sha256,
    ))
        return Error.InvalidSourceLiveGrant;
}

/// Canonical pointer-free identity for a bound source.
pub fn sourceBindingRootV1(
    binding: SourceBindingV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_binding_domain);
    hashU64(&hash, binding.source_scheduler_epoch);
    hashU64(&hash, binding.source_coordinator_id);
    hashU64(&hash, binding.source_bank_epoch);
    hash.update(&binding.request_sha256);
    hashU64(&hash, binding.publication_next_sequence);
    hashU64(
        &hash,
        binding.source_last_resource_permit_generation,
    );
    hash.update(&binding.source_receipt_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Canonical pointer-free logical root for a source grant.
///
/// The lease pointer, self pointer, and consumer-claim root are intentionally
/// absent. They are live authority fences, never durable identity.
pub fn sourceLiveGrantRootV1(
    grant: SourceLiveGrantV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    const recoverable =
        !isZero(grant.source_recovery_contract_sha256);
    hash.update(if (recoverable)
        source_replay_grant_domain
    else
        source_live_grant_domain);
    hashU64(
        &hash,
        if (recoverable)
            source_replay_grant_abi
        else
            source_live_grant_abi,
    );
    hashU64(&hash, grant.request_epoch);
    hashU64(&hash, grant.publication_next_sequence);
    hash.update(&grant.source_checkpoint_sha256);
    hash.update(&grant.source_selector_sha256);
    hash.update(&grant.challenge_sha256);
    if (recoverable)
        hash.update(&grant.source_recovery_contract_sha256);
    hashU64(&hash, grant.source_scheduler_epoch);
    hashU64(&hash, grant.source_coordinator_id);
    hashU64(&hash, grant.source_bank_epoch);
    hash.update(&grant.request_sha256);
    hashU64(
        &hash,
        grant.source_last_resource_permit_generation,
    );
    hash.update(&grant.source_receipt_sha256);
    hash.update(&grant.source_binding_sha256);
    hash.update(&grant.source_exit_sha256);
    hash.update(&grant.successor_checkpoint_sha256);
    hash.update(&grant.successor_selector_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn sourceLiveAuthorityV1(
    lease: *checkpoint_file.LeaseV1,
) Error!SourceLiveAuthorityV1 {
    if (lease.state != .ready)
        return Error.InvalidSourceLiveMarker;
    const active_set = lease.activeSet() catch
        return Error.InvalidSourceLiveMarker;
    if ((active_set.object_count != 1 and
        active_set.object_count != 2) or
        active_set.metadata.generation !=
            source_live_set_generation or
        lease.selector.generation !=
            source_live_set_generation or
        active_set.metadata.request_epoch == 0 or
        active_set.metadata.publication_next_sequence == 0 or
        !isZero(active_set.metadata.parent_checkpoint_sha256) or
        !isZero(lease.selector.previous_selector_sha256) or
        lease.selector.request_epoch !=
            active_set.metadata.request_epoch or
        lease.selector.publication_next_sequence !=
            active_set.metadata.publication_next_sequence or
        lease.selector.checkpoint_bytes !=
            @as(u64, @intCast(lease.stream().len)) or
        !digestEqual(
            lease.selector.checkpoint_sha256,
            active_set.checkpoint_sha256,
        ) or !digestEqual(
        lease.selector.challenge_sha256,
        active_set.metadata.challenge_sha256,
    ) or !digestEqual(
        lease.challenge_sha256,
        active_set.metadata.challenge_sha256,
    ))
        return Error.InvalidSourceLiveMarker;
    const marker = active_set.object(
        .extension,
        source_live_object_ordinal,
    ) catch return Error.InvalidSourceLiveMarker;
    if (marker.abi_version != source_live_marker_abi or
        !std.mem.eql(u8, marker.bytes, source_live_marker))
        return Error.InvalidSourceLiveMarker;
    var recovery_contract_sha256 = [_]u8{0} ** 32;
    if (active_set.object_count == 2) {
        const contract_object = active_set.objects[1];
        if (contract_object.kind != .extension or
            contract_object.ordinal !=
                source_recovery_object_ordinal or
            contract_object.abi_version !=
                source_recovery.contract_abi)
            return Error.InvalidSourceLiveMarker;
        const contract = source_recovery.decodeV1(
            contract_object.bytes,
        ) catch return Error.InvalidSourceLiveMarker;
        if (contract.request_epoch !=
            active_set.metadata.request_epoch or
            contract.publication_next_sequence !=
                active_set.metadata.publication_next_sequence or
            !digestEqual(
                contract.challenge_sha256,
                active_set.metadata.challenge_sha256,
            ))
            return Error.InvalidSourceLiveMarker;
        recovery_contract_sha256 = contract.contract_sha256;
    }
    return .{
        .request_epoch = active_set.metadata.request_epoch,
        .publication_next_sequence = active_set.metadata.publication_next_sequence,
        .checkpoint_sha256 = active_set.checkpoint_sha256,
        .selector_sha256 = lease.selector.selector_sha256,
        .challenge_sha256 = active_set.metadata.challenge_sha256,
        .source_recovery_contract_sha256 = recovery_contract_sha256,
    };
}

fn validateSourceLiveGrantShapeV1(
    grant: *const SourceLiveGrantV1,
    expected_phase: SourceLivePhaseV1,
) Error!*checkpoint_file.LeaseV1 {
    const lease = grant.lease orelse
        return Error.InvalidSourceLiveGrant;
    if (expected_phase == .empty or
        expected_phase == .completed or
        grant.phase != expected_phase or
        grant.self_address != @intFromPtr(grant) or
        grant.lease_address != @intFromPtr(lease) or
        lease.state != .ready or
        grant.consumer_claim.lease_address !=
            grant.lease_address or
        grant.consumer_claim.owner_address !=
            grant.self_address or
        grant.consumer_claim.claim_generation == 0 or
        grant.request_epoch == 0 or
        grant.publication_next_sequence == 0 or
        isZero(grant.source_checkpoint_sha256) or
        isZero(grant.source_selector_sha256) or
        isZero(grant.challenge_sha256) or
        isZero(grant.grant_sha256) or
        !digestEqual(
            grant.grant_sha256,
            sourceLiveGrantRootV1(grant.*),
        ))
        return Error.InvalidSourceLiveGrant;

    const binding = bindingFromGrantV1(grant.*);
    switch (expected_phase) {
        .ready => {
            if (!sourceBindingEmptyV1(binding) or
                !isZero(grant.source_binding_sha256) or
                !isZero(grant.source_exit_sha256))
                return Error.InvalidSourceLiveGrant;
        },
        .bound, .handoff => {
            if (!sourceBindingValidV1(binding) or
                !digestEqual(
                    grant.source_binding_sha256,
                    sourceBindingRootV1(binding),
                ) or !isZero(grant.source_exit_sha256))
                return Error.InvalidSourceLiveGrant;
        },
        .exit_committed => {
            if (!sourceBindingValidV1(binding) or
                !digestEqual(
                    grant.source_binding_sha256,
                    sourceBindingRootV1(binding),
                ) or isZero(grant.source_exit_sha256))
                return Error.InvalidSourceLiveGrant;
        },
        else => return Error.InvalidSourceLiveGrant,
    }
    if (!isZero(grant.successor_checkpoint_sha256) or
        !isZero(grant.successor_selector_sha256))
        return Error.InvalidSourceLiveGrant;
    return lease;
}

fn sourceLiveGrantEmptyV1(grant: SourceLiveGrantV1) bool {
    return grant.phase == .empty and
        grant.lease == null and
        grant.self_address == 0 and
        grant.lease_address == 0 and
        std.meta.eql(
            grant.consumer_claim,
            checkpoint_file.ConsumerClaimV1{},
        ) and
        grant.request_epoch == 0 and
        grant.publication_next_sequence == 0 and
        isZero(grant.source_checkpoint_sha256) and
        isZero(grant.source_selector_sha256) and
        isZero(grant.challenge_sha256) and
        isZero(grant.source_recovery_contract_sha256) and
        sourceBindingEmptyV1(bindingFromGrantV1(grant)) and
        isZero(grant.source_binding_sha256) and
        isZero(grant.source_exit_sha256) and
        isZero(grant.successor_checkpoint_sha256) and
        isZero(grant.successor_selector_sha256) and
        isZero(grant.grant_sha256);
}

fn bindingFromGrantV1(
    grant: SourceLiveGrantV1,
) SourceBindingV1 {
    return .{
        .source_scheduler_epoch = grant.source_scheduler_epoch,
        .source_coordinator_id = grant.source_coordinator_id,
        .source_bank_epoch = grant.source_bank_epoch,
        .request_sha256 = grant.request_sha256,
        .publication_next_sequence = grant.publication_next_sequence,
        .source_last_resource_permit_generation = grant.source_last_resource_permit_generation,
        .source_receipt_sha256 = grant.source_receipt_sha256,
    };
}

fn sourceBindingValidV1(binding: SourceBindingV1) bool {
    return binding.source_scheduler_epoch != 0 and
        binding.source_coordinator_id != 0 and
        binding.source_bank_epoch != 0 and
        !isZero(binding.request_sha256) and
        binding.publication_next_sequence != 0 and
        binding.source_last_resource_permit_generation != 0 and
        binding.source_last_resource_permit_generation !=
            std.math.maxInt(u64) and
        !isZero(binding.source_receipt_sha256);
}

fn sourceBindingEmptyV1(binding: SourceBindingV1) bool {
    return binding.source_scheduler_epoch == 0 and
        binding.source_coordinator_id == 0 and
        binding.source_bank_epoch == 0 and
        isZero(binding.request_sha256) and
        binding.source_last_resource_permit_generation == 0 and
        isZero(binding.source_receipt_sha256);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn closeTestLeaseV1(
    lease: *checkpoint_file.LeaseV1,
) void {
    if (lease.consumer_claim) |claim|
        lease.releaseConsumerClaimV1(claim) catch {};
    lease.close();
}

fn sourceExitFixtureV1(
    binding: SourceBindingV1,
    request_epoch: u64,
    predecessor_selector_sha256: Digest,
    mutation: u64,
) !lane.SourceExitReceiptV1 {
    var slots = [_]resource_bank.Slot{.{}};
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        binding.source_bank_epoch,
    );
    const receipt = try bank.commit(
        try bank.reserve(
            9103,
            .{
                .kv_bytes = 128,
                .output_journal_bytes = 16,
                .queue_slots = 1,
            },
        ),
    );
    var value: lane.SourceExitReceiptV1 = .{
        .scheduler_epoch = binding.source_scheduler_epoch,
        .coordinator_id = binding.source_coordinator_id,
        .handoff_generation = 1,
        .handle = .{
            .scheduler_epoch = binding.source_scheduler_epoch,
            .slot_index = receipt.slot_index,
            .slot_generation = receipt.generation,
            .tenant_key = 9104,
            .request_key = 9105,
            .request_generation = 1,
        },
        .publication_request_epoch = request_epoch,
        .expected_next_sequence = binding.publication_next_sequence,
        .source_last_publication_permit_generation = binding.source_last_resource_permit_generation,
        .source_receipt = receipt,
        .source_receipt_sha256 = lane.resourceReceiptSha256(receipt),
        .scheduler_chain_head_before_sha256 = [_]u8{0x21} ** 32,
        .checkpoint_sha256 = [_]u8{0x22} ** 32,
        .successor_segment_sha256 = [_]u8{0x23} ** 32,
        .target_ownership_intent_sha256 = [_]u8{0x24} ** 32,
        .prepared_archive_sha256 = [_]u8{0x25} ** 32,
        .predecessor_selector_sha256 = predecessor_selector_sha256,
        .cancel_event_sequence = 4 + mutation,
        .cancel_event_sha256 = [_]u8{0x27} ** 32,
    };
    value.source_exit_sha256 =
        lane.sourceExitReceiptSha256(value);
    return value;
}

test "source-live marker encoding is exact generation one" {
    const challenge = [_]u8{0x41} ** 32;
    var storage: [1024]u8 = undefined;
    const prepared = try encodeSourceLiveSetV1(
        701,
        29,
        challenge,
        &storage,
    );
    const decoded = try checkpoint_file.decodeSetV1(
        prepared.bytes,
    );
    try std.testing.expectEqual(
        source_live_set_generation,
        decoded.metadata.generation,
    );
    try std.testing.expectEqual(@as(usize, 1), decoded.object_count);
    try std.testing.expect(isZero(
        decoded.metadata.parent_checkpoint_sha256,
    ));
    const marker = try decoded.object(
        .extension,
        source_live_object_ordinal,
    );
    try std.testing.expectEqual(
        source_live_marker_abi,
        marker.abi_version,
    );
    try std.testing.expectEqualStrings(
        source_live_marker,
        marker.bytes,
    );
}

test "source-live grant fences copies duplicate claims and selector drift" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const challenge = [_]u8{0x42} ** 32;
    var initial_storage: [1024]u8 = undefined;
    const initial = try encodeSourceLiveSetV1(
        702,
        31,
        challenge,
        &initial_storage,
    );
    const initial_selector =
        try checkpoint_file.prepareInitialSelectorV1(initial);
    var lock_storage: [1]u8 = undefined;
    var active_storage: [1024]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.create(
        temporary.dir,
        9101,
        challenge,
        initial,
        initial_selector,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    defer closeTestLeaseV1(&lease);

    var grant: SourceLiveGrantV1 = .{};
    try initSourceLiveGrantV1(&grant, &lease);
    try validateSourceLiveGrantV1(&grant, .ready);

    var copied = grant;
    try std.testing.expectEqualSlices(
        u8,
        &grant.grant_sha256,
        &sourceLiveGrantRootV1(copied),
    );
    try std.testing.expectError(
        Error.InvalidSourceLiveGrant,
        validateSourceLiveGrantV1(&copied, .ready),
    );
    var address_mutated = grant;
    address_mutated.self_address ^= 1;
    address_mutated.lease_address ^= 1;
    address_mutated.consumer_claim.owner_address ^= 1;
    address_mutated.consumer_claim.lease_address ^= 1;
    try std.testing.expectEqualSlices(
        u8,
        &grant.grant_sha256,
        &sourceLiveGrantRootV1(address_mutated),
    );

    var duplicate: SourceLiveGrantV1 = .{};
    try std.testing.expectError(
        error.ConsumerClaimInFlight,
        initSourceLiveGrantV1(&duplicate, &lease),
    );
    try std.testing.expectEqual(
        SourceLivePhaseV1.empty,
        duplicate.phase,
    );

    const selected = lease.selector;
    lease.selector.selector_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidSourceLiveGrant,
        validateSourceLiveGrantV1(&grant, .ready),
    );
    lease.selector = selected;
    try validateSourceLiveGrantV1(&grant, .ready);
}

test "source-live grant advances and releases exact generation two" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const challenge = [_]u8{0x43} ** 32;
    var initial_storage: [1024]u8 = undefined;
    const initial = try encodeSourceLiveSetV1(
        703,
        37,
        challenge,
        &initial_storage,
    );
    const initial_selector =
        try checkpoint_file.prepareInitialSelectorV1(initial);
    var lock_storage: [1]u8 = undefined;
    var active_storage: [2048]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.create(
        temporary.dir,
        9102,
        challenge,
        initial,
        initial_selector,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    defer closeTestLeaseV1(&lease);

    var grant: SourceLiveGrantV1 = .{};
    try initSourceLiveGrantV1(&grant, &lease);
    var binding: SourceBindingV1 = .{
        .source_scheduler_epoch = 81,
        .source_coordinator_id = 82,
        .source_bank_epoch = 83,
        .request_sha256 = [_]u8{0x84} ** 32,
        .publication_next_sequence = 37,
        .source_last_resource_permit_generation = 85,
        .source_receipt_sha256 = [_]u8{0} ** 32,
    };
    const source_exit = try sourceExitFixtureV1(
        binding,
        703,
        initial_selector.selector_sha256,
        0,
    );
    binding.source_receipt_sha256 =
        source_exit.source_receipt_sha256;
    try bindSourceLiveGrantV1(&grant, binding);
    try std.testing.expectError(
        Error.InvalidSourceLiveGrant,
        bindSourceLiveGrantV1(&grant, binding),
    );
    try beginSourceHandoffV1(&grant);
    try validateSourceLiveGrantV1(&grant, .handoff);
    try abortSourceHandoffV1(&grant);
    try validateSourceLiveGrantV1(&grant, .bound);
    try beginSourceHandoffV1(&grant);
    try markSourceExitCommittedV1(
        &grant,
        source_exit.source_exit_sha256,
    );
    try validateSourceLiveGrantV1(&grant, .exit_committed);

    var encoded_exit: [source_exit_wire.wire_bytes]u8 =
        undefined;
    _ = try source_exit_wire.encodeV1(
        source_exit,
        &encoded_exit,
    );
    const successor_objects =
        [_]checkpoint_file.ObjectInputV1{
            .{
                .kind = .source_process,
                .ordinal = 0,
                .abi_version = source_exit_wire.wire_abi,
                .bytes = &encoded_exit,
            },
            .{
                .kind = .extension,
                .ordinal = 0,
                .abi_version = 1,
                .bytes = "source-evidence-fixture",
            },
        };
    var successor_storage: [2048]u8 = undefined;
    const successor_set = try checkpoint_file.encodeSetV1(
        .{
            .generation = immediate_successor_generation,
            .request_epoch = 703,
            .publication_next_sequence = 37,
            .parent_checkpoint_sha256 = initial.checkpoint_sha256,
            .challenge_sha256 = challenge,
        },
        &successor_objects,
        &successor_storage,
    );
    const publication =
        try checkpoint_file.preparePublicationV1(
            &lease,
            successor_set,
        );
    _ = try checkpoint_file.publishV1(&lease, publication);

    var drifted_selector =
        publication.selector.selector_sha256;
    drifted_selector[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidSuccessorSelection,
        completeSourceHandoffV1(&grant, .{
            .checkpoint_sha256 = successor_set.checkpoint_sha256,
            .selector_sha256 = drifted_selector,
        }),
    );
    try std.testing.expect(lease.consumer_claim != null);

    try completeSourceHandoffV1(&grant, .{
        .checkpoint_sha256 = successor_set.checkpoint_sha256,
        .selector_sha256 = publication.selector.selector_sha256,
    });
    try std.testing.expectEqual(
        SourceLivePhaseV1.completed,
        grant.phase,
    );
    try std.testing.expect(grant.lease == null);
    try std.testing.expect(lease.consumer_claim == null);
    try std.testing.expectEqualSlices(
        u8,
        &publication.selector.selector_sha256,
        &grant.successor_selector_sha256,
    );
}

test "source-live grant rejects generation two with another source exit" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const challenge = [_]u8{0x44} ** 32;
    var initial_storage: [1024]u8 = undefined;
    const initial = try encodeSourceLiveSetV1(
        704,
        41,
        challenge,
        &initial_storage,
    );
    const initial_selector =
        try checkpoint_file.prepareInitialSelectorV1(initial);
    var lock_storage: [1]u8 = undefined;
    var active_storage: [2048]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.create(
        temporary.dir,
        9106,
        challenge,
        initial,
        initial_selector,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    defer closeTestLeaseV1(&lease);

    var grant: SourceLiveGrantV1 = .{};
    try initSourceLiveGrantV1(&grant, &lease);
    var binding: SourceBindingV1 = .{
        .source_scheduler_epoch = 91,
        .source_coordinator_id = 92,
        .source_bank_epoch = 93,
        .request_sha256 = [_]u8{0x94} ** 32,
        .publication_next_sequence = 41,
        .source_last_resource_permit_generation = 95,
        .source_receipt_sha256 = [_]u8{0} ** 32,
    };
    const expected_exit = try sourceExitFixtureV1(
        binding,
        704,
        initial_selector.selector_sha256,
        0,
    );
    binding.source_receipt_sha256 =
        expected_exit.source_receipt_sha256;
    try bindSourceLiveGrantV1(&grant, binding);
    try beginSourceHandoffV1(&grant);
    try markSourceExitCommittedV1(
        &grant,
        expected_exit.source_exit_sha256,
    );

    const other_exit = try sourceExitFixtureV1(
        binding,
        704,
        initial_selector.selector_sha256,
        1,
    );
    var encoded_exit: [source_exit_wire.wire_bytes]u8 =
        undefined;
    _ = try source_exit_wire.encodeV1(
        other_exit,
        &encoded_exit,
    );
    const successor_objects =
        [_]checkpoint_file.ObjectInputV1{
            .{
                .kind = .source_process,
                .ordinal = 0,
                .abi_version = source_exit_wire.wire_abi,
                .bytes = &encoded_exit,
            },
            .{
                .kind = .extension,
                .ordinal = 0,
                .abi_version = 1,
                .bytes = "other-source-evidence",
            },
        };
    var successor_storage: [2048]u8 = undefined;
    const successor_set = try checkpoint_file.encodeSetV1(
        .{
            .generation = immediate_successor_generation,
            .request_epoch = 704,
            .publication_next_sequence = 41,
            .parent_checkpoint_sha256 = initial.checkpoint_sha256,
            .challenge_sha256 = challenge,
        },
        &successor_objects,
        &successor_storage,
    );
    const publication =
        try checkpoint_file.preparePublicationV1(
            &lease,
            successor_set,
        );
    _ = try checkpoint_file.publishV1(
        &lease,
        publication,
    );

    try std.testing.expectError(
        Error.InvalidSuccessorSelection,
        completeSourceHandoffV1(
            &grant,
            .{
                .checkpoint_sha256 = successor_set.checkpoint_sha256,
                .selector_sha256 = publication.selector.selector_sha256,
            },
        ),
    );
    try std.testing.expectEqual(
        SourceLivePhaseV1.exit_committed,
        grant.phase,
    );
    try std.testing.expect(lease.consumer_claim != null);

    // Test-only cleanup: the production API deliberately refuses to release
    // source authority over the mismatched selected exit.
    grant.consumer_claim = try lease.advanceConsumerClaimV1(
        grant.consumer_claim,
    );
    try lease.releaseConsumerClaimV1(grant.consumer_claim);
    grant.consumer_claim = .{};
    grant.lease = null;
    grant.phase = .completed;
}
