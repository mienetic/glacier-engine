//! Durable source-exit selection for prepared-text continuation.
//!
//! The portable R1e/R1g evidence archive is nested inside one authority
//! checkpoint selected by the generic atomic checkpoint-file protocol. A
//! canonical source-exit receipt proves that LaneWeave closed the exact source
//! publication binding before the successor selector became visible.
//!
//! This layer does not serialize process-local restored admission handles.
//! A fresh target must reconstruct R1h-a under the exclusive checkpoint-file
//! lease and keep that lease until terminal selection or abort.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;
const archive = @import("prepared_text_handoff_archive.zig");
const restore_admission =
    @import("prepared_text_restore_admission.zig");
const source_exit_wire =
    @import("prepared_text_source_exit_wire.zig");
const source_lease =
    @import("prepared_text_source_lease.zig");
const source_recovery =
    @import("prepared_text_source_recovery.zig");
const session = @import("prepared_text_session.zig");
const successor = @import("prepared_text_successor.zig");
const terminal_semantic =
    @import("prepared_text_terminal_equivalence.zig");

pub const Digest = [32]u8;
pub const source_exit_wire_abi = source_exit_wire.wire_abi;
pub const evidence_archive_object_abi: u64 =
    0x4750_5441_0000_0001;
pub const source_live_marker_abi =
    source_lease.source_live_marker_abi;
pub const source_exited_set_generation: u64 = 2;
pub const terminal_set_generation: u64 = 3;
pub const source_exit_wire_magic = source_exit_wire.wire_magic;
pub const source_exit_wire_bytes = source_exit_wire.wire_bytes;
pub const source_exit_wire_body_bytes =
    source_exit_wire.wire_body_bytes;
pub const source_exit_wire_flags = source_exit_wire.wire_flags;
pub const source_exit_object_ordinal: u64 = 0;
pub const evidence_archive_object_ordinal: u64 = 0;
pub const source_recovery_object_ordinal =
    source_lease.source_recovery_object_ordinal;
pub const source_live_object_ordinal =
    source_lease.source_live_object_ordinal;
pub const terminal_source_selector_object_ordinal: u64 = 0;
pub const terminal_source_archive_object_ordinal: u64 = 0;
pub const terminal_semantic_object_ordinal: u64 = 1;
pub const terminal_source_archive_object_abi: u64 =
    0x4750_5448_0000_0001;
pub const source_live_marker =
    source_lease.source_live_marker;

pub const Error = checkpoint_file.Error ||
    archive.Error ||
    restore_admission.Error ||
    source_recovery.Error ||
    source_exit_wire.Error ||
    successor.Error ||
    terminal_semantic.Error ||
    error{
        InvalidSourceExit,
        InvalidAuthorityArchive,
        InvalidSelector,
        InvalidLength,
        UnsafeDestination,
        ArithmeticOverflow,
    };

pub const DecodedSourceExitedSetV1 = struct {
    authority_archive: checkpoint_file.DecodedSetV1,
    evidence: archive.DecodedRestartArchiveV1,
    source_exit: lane.SourceExitReceiptV1,
    source_recovery_contract: ?source_recovery.DecodedV1 = null,
    selector: checkpoint_file.DecodedSelectorV1,
};

/// A terminal selector nests the exact generation-two source-exited archive,
/// its canonical selector, and the receipt-independent terminal semantic.
/// Keeping the predecessor pair inside the terminal archive lets a fresh
/// process verify the complete three-generation chain and reject replay.
pub const DecodedTerminalSetV1 = struct {
    terminal_archive: checkpoint_file.DecodedSetV1,
    source_exited: DecodedSourceExitedSetV1,
    source_exited_selector: checkpoint_file.DecodedSelectorV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    selector: checkpoint_file.DecodedSelectorV1,
};

const SourceExitGrantFlavorV1 = enum {
    legacy,
    recoverable,
};

/// Pin the selector-selected generation-two source-exit authority to one
/// address-stable, process-local grant. The generic lease consumer claim makes
/// duplicate target activation fail while preserving the durable selector for
/// deterministic retry after a pre-activation abort.
pub fn initSelectedSourceExitGrantV1(
    grant: *restore_admission.SelectedSourceExitGrantV1,
    lease: *checkpoint_file.LeaseV1,
    selected: DecodedSourceExitedSetV1,
) Error!void {
    try initSelectedSourceExitGrantCommonV1(
        grant,
        lease,
        selected,
        .legacy,
    );
}

fn initSelectedSourceExitGrantCommonV1(
    grant: *restore_admission.SelectedSourceExitGrantV1,
    lease: *checkpoint_file.LeaseV1,
    selected: DecodedSourceExitedSetV1,
    flavor: SourceExitGrantFlavorV1,
) Error!void {
    if (grant.phase != .empty or grant.lease != null or
        grant.self_address != 0 or grant.lease_address != 0 or
        lease.state != .ready or
        selected.selector.generation !=
            source_exited_set_generation or
        !lane.sourceExitReceiptStructurallyValidV1(
            selected.source_exit,
        ))
        return Error.InvalidActivationGrant;
    const active_set = lease.activeSet() catch
        return Error.InvalidActivationGrant;
    const authority_contract_present =
        active_set.object_count == 3;
    if ((active_set.object_count != 2 and
        active_set.object_count != 3) or
        !sourceExitGrantFlavorValidV1(
            authority_contract_present,
            selected.source_recovery_contract != null,
            flavor,
        ) or !std.meta.eql(lease.selector, selected.selector) or
        !digestEqual(
            active_set.checkpoint_sha256,
            selected.authority_archive.checkpoint_sha256,
        ) or !digestEqual(
        selected.source_exit.source_exit_sha256,
        lane.sourceExitReceiptSha256(selected.source_exit),
    ) or !digestEqual(
        selected.source_exit.checkpoint_sha256,
        selected.evidence.checkpoint.checkpoint_sha256,
    ) or !digestEqual(
        selected.source_exit.prepared_archive_sha256,
        selected.evidence.archive.checkpoint_sha256,
    ) or !digestEqual(
        selected.source_exit.successor_segment_sha256,
        selected.evidence.artifacts.segment.segment_sha256,
    ) or !digestEqual(
        selected.source_exit.target_ownership_intent_sha256,
        selected.evidence.artifacts.segment.ownership_intent_sha256,
    ) or !digestEqual(
        selected.source_exit.predecessor_selector_sha256,
        selected.selector.previous_selector_sha256,
    ))
        return Error.InvalidActivationGrant;

    const consumer_claim = lease.beginConsumerClaimV1(
        @intFromPtr(grant),
    ) catch |err| switch (err) {
        error.ConsumerClaimInFlight => return Error.InvalidActivationGrant,
        else => return err,
    };
    errdefer lease.releaseConsumerClaimV1(
        consumer_claim,
    ) catch {};
    errdefer grant.* = .{};
    grant.* = .{
        .lease = lease,
        .self_address = @intFromPtr(grant),
        .lease_address = @intFromPtr(lease),
        .consumer_claim = consumer_claim,
        .initial_consumer_claim_sha256 = consumer_claim.claim_sha256,
        .source_scheduler_epoch = selected.source_exit.scheduler_epoch,
        .source_coordinator_id = selected.source_exit.coordinator_id,
        .source_bank_epoch = selected.source_exit.source_receipt.bank_epoch,
        .request_epoch = selected.source_exit.publication_request_epoch,
        .publication_next_sequence = selected.source_exit.expected_next_sequence,
        .source_last_resource_permit_generation = selected.source_exit
            .source_last_publication_permit_generation,
        .source_selector_generation = source_exited_set_generation,
        .terminal_selector_generation = terminal_set_generation,
        .authority_checkpoint_sha256 = selected.authority_archive.checkpoint_sha256,
        .selected_selector_sha256 = selected.selector.selector_sha256,
        .predecessor_selector_sha256 = selected.source_exit.predecessor_selector_sha256,
        .source_exit_sha256 = selected.source_exit.source_exit_sha256,
        .source_receipt_sha256 = selected.source_exit.source_receipt_sha256,
        .checkpoint_sha256 = selected.source_exit.checkpoint_sha256,
        .prepared_archive_sha256 = selected.source_exit.prepared_archive_sha256,
        .successor_segment_sha256 = selected.source_exit.successor_segment_sha256,
        .ownership_intent_sha256 = selected.source_exit
            .target_ownership_intent_sha256,
        .challenge_sha256 = selected.evidence.artifacts.segment.challenge_sha256,
        .selected_authority_kind = .source_exit,
        .phase = .ready,
    };
    grant.grant_sha256 =
        restore_admission.selectedSourceExitGrantRootV1(
            grant.*,
        );
    try restore_admission.validateSelectedSourceExitGrantV1(
        grant,
        .ready,
    );
}

/// Pin a recoverable generation-two authority only after independently
/// loading its retained generation-one predecessor and proving that the
/// embedded replay contract is byte-identical. The caller supplies bounded
/// scratch storage; no authority is granted when the predecessor is missing,
/// foreign, or only coherently re-rooted inside generation two.
pub fn initSelectedRecoverableSourceExitGrantV1(
    grant: *restore_admission.SelectedSourceExitGrantV1,
    lease: *checkpoint_file.LeaseV1,
    selected: DecodedSourceExitedSetV1,
    retained_storage: []u8,
) Error!void {
    _ = try validateRecoverableSourcePredecessorV1(
        lease,
        selected,
        retained_storage,
    );
    try initSelectedSourceExitGrantCommonV1(
        grant,
        lease,
        selected,
        .recoverable,
    );
}

fn sourceExitGrantFlavorValidV1(
    authority_contract_present: bool,
    decoded_contract_present: bool,
    flavor: SourceExitGrantFlavorV1,
) bool {
    return authority_contract_present ==
        decoded_contract_present and
        authority_contract_present ==
            (flavor == .recoverable);
}

/// Prove that a selected one-ahead sink descends from the exact empty selector
/// committed by the recoverable source contract. A canonical generation-two
/// selector can otherwise be coherently re-rooted to any nonzero predecessor.
/// The first acknowledgement must also carry the exact empty semantic
/// predecessor roots.
pub fn recoverableOneAheadSinkLineageValidV1(
    expected_empty_selector_sha256: Digest,
    selected_previous_selector_sha256: Digest,
    predecessor_acknowledgement_sha256: Digest,
    predecessor_sink_prefix_sha256: Digest,
) bool {
    return !isZero(expected_empty_selector_sha256) and
        digestEqual(
            selected_previous_selector_sha256,
            expected_empty_selector_sha256,
        ) and isZero(predecessor_acknowledgement_sha256) and
        isZero(predecessor_sink_prefix_sha256);
}

pub fn validateRecoverableSourcePredecessorV1(
    lease: *checkpoint_file.LeaseV1,
    selected: DecodedSourceExitedSetV1,
    retained_storage: []u8,
) Error!source_recovery.DecodedV1 {
    const contract = selected.source_recovery_contract orelse
        return Error.InvalidAuthorityArchive;
    if (lease.state != .ready or
        !std.meta.eql(lease.selector, selected.selector))
        return Error.InvalidActivationGrant;
    const predecessor_root =
        selected.authority_archive.metadata
            .parent_checkpoint_sha256;
    const retained = lease.loadRetainedSetV1(
        predecessor_root,
        retained_storage,
    ) catch return Error.InvalidAuthorityArchive;
    if (retained.set.object_count != 2 or
        retained.set.metadata.generation !=
            source_lease.source_live_set_generation or
        retained.set.metadata.request_epoch !=
            contract.request_epoch or
        retained.set.metadata.publication_next_sequence !=
            contract.publication_next_sequence or
        !isZero(
            retained.set.metadata.parent_checkpoint_sha256,
        ) or !digestEqual(
        retained.set.metadata.challenge_sha256,
        contract.challenge_sha256,
    ))
        return Error.InvalidAuthorityArchive;
    const marker_object = retained.set.objects[0];
    const contract_object = retained.set.objects[1];
    if (marker_object.kind != .extension or
        marker_object.ordinal !=
            source_lease.source_live_object_ordinal or
        marker_object.abi_version !=
            source_lease.source_live_marker_abi or
        !std.mem.eql(
            u8,
            marker_object.bytes,
            source_lease.source_live_marker,
        ) or contract_object.kind != .extension or
        contract_object.ordinal !=
            source_recovery_object_ordinal or
        contract_object.abi_version !=
            source_recovery.contract_abi or
        !std.mem.eql(
            u8,
            contract_object.bytes,
            contract.encoded,
        ))
        return Error.InvalidAuthorityArchive;
    const prepared_retained: checkpoint_file.PreparedSetV1 = .{
        .bytes = retained.bytes,
        .checkpoint_sha256 = retained.set.checkpoint_sha256,
    };
    const predecessor_selector =
        try checkpoint_file.prepareInitialSelectorV1(
            prepared_retained,
        );
    if (!digestEqual(
        predecessor_selector.selector_sha256,
        selected.selector.previous_selector_sha256,
    ))
        return Error.InvalidSelector;
    return contract;
}

pub const encodeSourceLiveSetV1 =
    source_lease.encodeSourceLiveSetV1;

pub fn encodedSourceExitedSetBytesV1(
    evidence_archive_bytes: usize,
) Error!usize {
    const payload = std.math.add(
        usize,
        source_exit_wire_bytes,
        evidence_archive_bytes,
    ) catch return Error.ArithmeticOverflow;
    const with_header = std.math.add(
        usize,
        checkpoint_file.set_payload_offset,
        payload,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        with_header,
        checkpoint_file.set_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn encodedRecoverableSourceExitedSetBytesV1(
    evidence_archive_bytes: usize,
    recovery_contract_bytes: usize,
) Error!usize {
    const legacy = try encodedSourceExitedSetBytesV1(
        evidence_archive_bytes,
    );
    return std.math.add(
        usize,
        legacy,
        recovery_contract_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Encode the selected source-exited authority archive. `source_exit` must be
/// the exact commit result produced after the handoff barrier was installed
/// against `evidence.set`.
pub fn encodeSourceExitedSetV1(
    evidence: archive.PreparedArchiveV1,
    source_exit: lane.SourceExitCommitV1,
    predecessor_checkpoint_sha256: Digest,
    destination: []u8,
) Error!checkpoint_file.PreparedSetV1 {
    if (!lane.sourceExitReceiptValidV1(
        source_exit.receipt,
        source_exit.event,
    ))
        return Error.InvalidSourceExit;
    const decoded_evidence =
        try archive.decodeRestartArchiveV1(
            evidence.set.bytes,
            1,
            [_]u8{0} ** 32,
        );
    if (!std.meta.eql(
        decoded_evidence.artifacts,
        evidence.artifacts,
    ))
        return Error.InvalidAuthorityArchive;
    try validateEvidenceExitBindingsV1(
        evidence.set,
        evidence.artifacts,
        source_exit.receipt,
    );
    if (isZero(predecessor_checkpoint_sha256))
        return Error.InvalidAuthorityArchive;

    var encoded_exit: [source_exit_wire_bytes]u8 = undefined;
    _ = try encodeSourceExitReceiptV1(
        source_exit.receipt,
        &encoded_exit,
    );
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .source_process,
            .ordinal = source_exit_object_ordinal,
            .abi_version = source_exit_wire_abi,
            .bytes = &encoded_exit,
        },
        .{
            .kind = .extension,
            .ordinal = evidence_archive_object_ordinal,
            .abi_version = evidence_archive_object_abi,
            .bytes = evidence.set.bytes,
        },
    };
    return checkpoint_file.encodeSetV1(
        .{
            .generation = source_exited_set_generation,
            .request_epoch = evidence.artifacts.segment.request_epoch,
            .publication_next_sequence = evidence.artifacts.segment.sequence_base,
            .parent_checkpoint_sha256 = predecessor_checkpoint_sha256,
            .challenge_sha256 = evidence.artifacts.segment.challenge_sha256,
        },
        &objects,
        destination,
    );
}

/// Encode generation two with the byte-exact generation-one replay contract.
/// The normal source-exit receipt remains evidence from the successful clean
/// attempt; the contract proves which deterministic unpublished prefix and
/// empty result sink that attempt was allowed to publish.
pub fn encodeRecoverableSourceExitedSetV1(
    evidence: archive.PreparedArchiveV1,
    source_exit: lane.SourceExitCommitV1,
    predecessor_checkpoint_sha256: Digest,
    encoded_contract: source_recovery.EncodedV1,
    destination: []u8,
) Error!checkpoint_file.PreparedSetV1 {
    if (!lane.sourceExitReceiptValidV1(
        source_exit.receipt,
        source_exit.event,
    ))
        return Error.InvalidSourceExit;
    const decoded_evidence =
        try archive.decodeRestartArchiveV1(
            evidence.set.bytes,
            1,
            [_]u8{0} ** 32,
        );
    if (!std.meta.eql(
        decoded_evidence.artifacts,
        evidence.artifacts,
    ))
        return Error.InvalidAuthorityArchive;
    try validateEvidenceExitBindingsV1(
        evidence.set,
        evidence.artifacts,
        source_exit.receipt,
    );
    if (isZero(predecessor_checkpoint_sha256))
        return Error.InvalidAuthorityArchive;
    const contract = try source_recovery.decodeV1(
        encoded_contract.bytes,
    );
    if (!digestEqual(
        contract.contract_sha256,
        encoded_contract.contract_sha256,
    ))
        return Error.InvalidAuthorityArchive;
    try validateRecoveryEvidenceBindingsV1(
        contract,
        decoded_evidence,
        source_exit.receipt,
    );

    var encoded_exit: [source_exit_wire_bytes]u8 = undefined;
    _ = try encodeSourceExitReceiptV1(
        source_exit.receipt,
        &encoded_exit,
    );
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .source_process,
            .ordinal = source_exit_object_ordinal,
            .abi_version = source_exit_wire_abi,
            .bytes = &encoded_exit,
        },
        .{
            .kind = .extension,
            .ordinal = evidence_archive_object_ordinal,
            .abi_version = evidence_archive_object_abi,
            .bytes = evidence.set.bytes,
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
            .generation = source_exited_set_generation,
            .request_epoch = evidence.artifacts.segment.request_epoch,
            .publication_next_sequence = evidence.artifacts.segment.sequence_base,
            .parent_checkpoint_sha256 = predecessor_checkpoint_sha256,
            .challenge_sha256 = evidence.artifacts.segment.challenge_sha256,
        },
        &objects,
        destination,
    );
}

/// Decode the selected source-exit record and contextually reproduce every
/// nested R1e/R1g binding. Slices in the result borrow `encoded_authority`.
pub fn decodeSourceExitedSetV1(
    encoded_authority: []const u8,
    selected_selector: checkpoint_file.DecodedSelectorV1,
    predecessor_checkpoint_sha256: Digest,
) Error!DecodedSourceExitedSetV1 {
    if (isZero(predecessor_checkpoint_sha256))
        return Error.InvalidAuthorityArchive;
    const authority_archive =
        try checkpoint_file.decodeSetV1(encoded_authority);
    if ((authority_archive.object_count != 2 and
        authority_archive.object_count != 3) or
        authority_archive.metadata.generation !=
            source_exited_set_generation or
        !digestEqual(
            authority_archive.metadata.parent_checkpoint_sha256,
            predecessor_checkpoint_sha256,
        ))
        return Error.InvalidAuthorityArchive;

    const exit_object = authority_archive.objects[0];
    const evidence_object = authority_archive.objects[1];
    if (exit_object.kind != .source_process or
        exit_object.ordinal != source_exit_object_ordinal or
        exit_object.abi_version != source_exit_wire_abi or
        exit_object.bytes.len != source_exit_wire_bytes or
        evidence_object.kind != .extension or
        evidence_object.ordinal != evidence_archive_object_ordinal or
        evidence_object.abi_version != evidence_archive_object_abi)
        return Error.InvalidAuthorityArchive;

    const source_exit = try decodeSourceExitReceiptV1(
        exit_object.bytes,
    );
    const evidence = try archive.decodeRestartArchiveV1(
        evidence_object.bytes,
        1,
        [_]u8{0} ** 32,
    );
    try validateEvidenceExitBindingsV1(
        .{
            .bytes = evidence_object.bytes,
            .checkpoint_sha256 = evidence.archive.checkpoint_sha256,
        },
        evidence.artifacts,
        source_exit,
    );
    if (!std.meta.eql(
        source_exit.source_receipt,
        evidence.manifest.source.receipt,
    ) or
        source_exit.publication_request_epoch !=
            evidence.manifest.source.publication.request_epoch or
        source_exit.expected_next_sequence !=
            evidence.manifest.source.publication.next_sequence or
        source_exit.source_last_publication_permit_generation !=
            evidence.manifest.source.publication
                .last_resource_permit_generation or
        !digestEqual(
            source_exit.checkpoint_sha256,
            evidence.checkpoint.checkpoint_sha256,
        ))
        return Error.InvalidSourceExit;

    var recovery_contract: ?source_recovery.DecodedV1 = null;
    if (authority_archive.object_count == 3) {
        const contract_object = authority_archive.objects[2];
        if (contract_object.kind != .extension or
            contract_object.ordinal !=
                source_recovery_object_ordinal or
            contract_object.abi_version !=
                source_recovery.contract_abi)
            return Error.InvalidAuthorityArchive;
        const decoded_contract = try source_recovery.decodeV1(
            contract_object.bytes,
        );
        try validateRecoveryEvidenceBindingsV1(
            decoded_contract,
            evidence,
            source_exit,
        );
        recovery_contract = decoded_contract;
    }

    if (selected_selector.generation !=
        source_exited_set_generation or
        selected_selector.request_epoch !=
            authority_archive.metadata.request_epoch or
        selected_selector.publication_next_sequence !=
            authority_archive.metadata.publication_next_sequence or
        selected_selector.checkpoint_bytes !=
            encoded_authority.len or
        !digestEqual(
            selected_selector.previous_selector_sha256,
            source_exit.predecessor_selector_sha256,
        ) or !digestEqual(
        selected_selector.checkpoint_sha256,
        authority_archive.checkpoint_sha256,
    ) or !digestEqual(
        selected_selector.challenge_sha256,
        authority_archive.metadata.challenge_sha256,
    ))
        return Error.InvalidSelector;

    return .{
        .authority_archive = authority_archive,
        .evidence = evidence,
        .source_exit = source_exit,
        .source_recovery_contract = recovery_contract,
        .selector = selected_selector,
    };
}

pub fn encodedTerminalSetBytesV1(
    source_exited_set_bytes: usize,
) Error!usize {
    const with_selector = std.math.add(
        usize,
        source_exited_set_bytes,
        checkpoint_file.selector_bytes,
    ) catch return Error.ArithmeticOverflow;
    const payload = std.math.add(
        usize,
        with_selector,
        terminal_semantic.semantic_bytes,
    ) catch return Error.ArithmeticOverflow;
    const with_header = std.math.add(
        usize,
        checkpoint_file.set_payload_offset,
        payload,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        with_header,
        checkpoint_file.set_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Encode generation three before releasing target ownership. The terminal
/// semantic excludes Scheduler/Bank/receipt and successor-plan identities, so
/// it can be byte-compared with an uninterrupted execution oracle while this
/// archive still retains the exact authority lineage that produced it.
pub fn encodeTerminalSetV1(
    source_exited_set: checkpoint_file.PreparedSetV1,
    source_exited_selector: checkpoint_file.PreparedSelectorV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    destination: []u8,
) Error!checkpoint_file.PreparedSetV1 {
    const source_pair = try validateSourceExitedPairV1(
        source_exited_set.bytes,
        &source_exited_selector.bytes,
    );
    try terminal_semantic.validateV1(semantic);
    if (!digestEqual(
        source_exited_set.checkpoint_sha256,
        source_pair.set.checkpoint_sha256,
    ) or !digestEqual(
        source_exited_selector.selector_sha256,
        source_pair.selector.selector_sha256,
    ) or semantic.request_epoch !=
        source_pair.set.metadata.request_epoch or
        semantic.publication_next_sequence !=
            source_pair.segment.terminal_sequence or
        semantic.publication_next_sequence <=
            source_pair.set.metadata.publication_next_sequence or
        !digestEqual(
            semantic.artifact_sha256,
            source_pair.artifacts.successor_plan.artifact_sha256,
        ))
        return Error.InvalidAuthorityArchive;

    var encoded_semantic: [terminal_semantic.semantic_bytes]u8 = undefined;
    _ = try terminal_semantic.encodeV1(
        semantic,
        &encoded_semantic,
    );
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .runtime_state,
            .ordinal = terminal_source_selector_object_ordinal,
            .abi_version = checkpoint_file.selector_abi,
            .bytes = &source_exited_selector.bytes,
        },
        .{
            .kind = .source_process,
            .ordinal = terminal_source_archive_object_ordinal,
            .abi_version = terminal_source_archive_object_abi,
            .bytes = source_exited_set.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = terminal_semantic_object_ordinal,
            .abi_version = terminal_semantic.semantic_abi,
            .bytes = &encoded_semantic,
        },
    };
    return checkpoint_file.encodeSetV1(
        .{
            .generation = terminal_set_generation,
            .request_epoch = source_pair.set.metadata.request_epoch,
            .publication_next_sequence = semantic.publication_next_sequence,
            .parent_checkpoint_sha256 = source_pair.set.checkpoint_sha256,
            .challenge_sha256 = source_pair.set.metadata.challenge_sha256,
        },
        &objects,
        destination,
    );
}

/// Verify a selector-selected terminal marker and recursively reproduce the
/// exact generation-two source-exit and generation-one evidence archive.
/// Callers must retain the predecessor checkpoint root as their lineage
/// anchor; no record is allowed to choose that trust root for itself.
pub fn decodeTerminalSetV1(
    encoded_terminal: []const u8,
    selected_selector: checkpoint_file.DecodedSelectorV1,
    predecessor_checkpoint_sha256: Digest,
) Error!DecodedTerminalSetV1 {
    if (isZero(predecessor_checkpoint_sha256))
        return Error.InvalidAuthorityArchive;
    const terminal_archive =
        try checkpoint_file.decodeSetV1(encoded_terminal);
    if (terminal_archive.object_count != 3 or
        terminal_archive.metadata.generation !=
            terminal_set_generation)
        return Error.InvalidAuthorityArchive;

    const selector_object = terminal_archive.objects[0];
    const source_archive_object = terminal_archive.objects[1];
    const semantic_object = terminal_archive.objects[2];
    if (selector_object.kind != .runtime_state or
        selector_object.ordinal !=
            terminal_source_selector_object_ordinal or
        selector_object.abi_version !=
            checkpoint_file.selector_abi or
        selector_object.bytes.len !=
            checkpoint_file.selector_bytes or
        source_archive_object.kind != .source_process or
        source_archive_object.ordinal !=
            terminal_source_archive_object_ordinal or
        source_archive_object.abi_version !=
            terminal_source_archive_object_abi or
        semantic_object.kind != .extension or
        semantic_object.ordinal !=
            terminal_semantic_object_ordinal or
        semantic_object.abi_version !=
            terminal_semantic.semantic_abi or
        semantic_object.bytes.len !=
            terminal_semantic.semantic_bytes)
        return Error.InvalidAuthorityArchive;

    const source_exited_selector =
        try checkpoint_file.decodeSelectorV1(
            selector_object.bytes,
        );
    const source_pair = try validateSourceExitedPairV1(
        source_archive_object.bytes,
        selector_object.bytes,
    );
    const source_exited = try decodeSourceExitedSetV1(
        source_archive_object.bytes,
        source_exited_selector,
        predecessor_checkpoint_sha256,
    );
    const semantic =
        try terminal_semantic.decodeV1(semantic_object.bytes);

    if (!digestEqual(
        terminal_archive.metadata.parent_checkpoint_sha256,
        source_pair.set.checkpoint_sha256,
    ) or terminal_archive.metadata.request_epoch !=
        source_pair.set.metadata.request_epoch or
        terminal_archive.metadata.publication_next_sequence !=
            semantic.publication_next_sequence or
        !digestEqual(
            terminal_archive.metadata.challenge_sha256,
            source_pair.set.metadata.challenge_sha256,
        ) or semantic.request_epoch !=
        source_pair.set.metadata.request_epoch or
        semantic.publication_next_sequence !=
            source_pair.segment.terminal_sequence or
        semantic.publication_next_sequence <=
            source_pair.set.metadata.publication_next_sequence or
        !digestEqual(
            semantic.local_plan_sha256,
            source_exited.evidence.manifest
                .expected_checkpoint.local_plan_sha256,
        ) or !digestEqual(
        semantic.artifact_sha256,
        source_exited.evidence.manifest
            .expected_checkpoint.artifact_sha256,
    ) or semantic.prompt_tokens !=
        source_exited.evidence.manifest
            .expected_checkpoint.prompt_tokens or
        semantic.max_new_tokens !=
            source_exited.evidence.manifest
                .expected_checkpoint.max_new_tokens or
        semantic.output_length !=
            source_exited.evidence.manifest
                .expected_checkpoint.max_new_tokens)
        return Error.InvalidAuthorityArchive;

    if (selected_selector.generation !=
        terminal_set_generation or
        selected_selector.request_epoch !=
            terminal_archive.metadata.request_epoch or
        selected_selector.publication_next_sequence !=
            terminal_archive.metadata.publication_next_sequence or
        selected_selector.checkpoint_bytes !=
            encoded_terminal.len or
        !digestEqual(
            selected_selector.previous_selector_sha256,
            source_exited_selector.selector_sha256,
        ) or !digestEqual(
        selected_selector.checkpoint_sha256,
        terminal_archive.checkpoint_sha256,
    ) or !digestEqual(
        selected_selector.challenge_sha256,
        terminal_archive.metadata.challenge_sha256,
    ))
        return Error.InvalidSelector;

    return .{
        .terminal_archive = terminal_archive,
        .source_exited = source_exited,
        .source_exited_selector = source_exited_selector,
        .semantic = semantic,
        .selector = selected_selector,
    };
}

/// Finish the process-local half of generation-three publication. The lease
/// claim advances only after the active selector proves the immediate
/// generation-two to generation-three lineage and carries the exact terminal
/// semantic expected by the restored session.
pub fn markTerminalSelectedV1(
    grant: *restore_admission.SelectedSourceExitGrantV1,
    expected_semantic: terminal_semantic.TerminalSemanticV1,
) Error!void {
    if (grant.phase != .consumed or
        grant.self_address != @intFromPtr(grant) or
        !digestEqual(
            grant.grant_sha256,
            restore_admission.selectedSourceExitGrantRootV1(
                grant.*,
            ),
        ))
        return Error.InvalidActivationGrant;
    try terminal_semantic.validateV1(expected_semantic);
    const lease = grant.lease orelse
        return Error.InvalidActivationGrant;
    const active_set = lease.activeSet() catch
        return Error.InvalidActivationGrant;
    if (active_set.object_count != 3 or
        lease.selector.generation !=
            terminal_set_generation or
        active_set.metadata.generation !=
            terminal_set_generation or
        lease.selector.request_epoch != grant.request_epoch or
        active_set.metadata.request_epoch != grant.request_epoch or
        lease.selector.publication_next_sequence !=
            expected_semantic.publication_next_sequence or
        active_set.metadata.publication_next_sequence !=
            expected_semantic.publication_next_sequence or
        lease.selector.checkpoint_bytes !=
            @as(u64, @intCast(lease.stream().len)) or
        !digestEqual(
            lease.selector.previous_selector_sha256,
            grant.selected_selector_sha256,
        ) or !digestEqual(
        lease.selector.checkpoint_sha256,
        active_set.checkpoint_sha256,
    ) or !digestEqual(
        lease.selector.challenge_sha256,
        grant.challenge_sha256,
    ) or
        !digestEqual(
            active_set.metadata.parent_checkpoint_sha256,
            grant.authority_checkpoint_sha256,
        ) or !digestEqual(
        active_set.metadata.challenge_sha256,
        grant.challenge_sha256,
    ))
        return Error.InvalidActivationGrant;
    const source_selector_object = active_set.objects[0];
    const source_archive_object = active_set.objects[1];
    const source_pair = validateSourceExitedPairV1(
        source_archive_object.bytes,
        source_selector_object.bytes,
    ) catch return Error.InvalidActivationGrant;
    if (!digestEqual(
        source_pair.selector.selector_sha256,
        grant.selected_selector_sha256,
    ) or !digestEqual(
        source_pair.set.checkpoint_sha256,
        grant.authority_checkpoint_sha256,
    ) or !digestEqual(
        source_pair.selector.previous_selector_sha256,
        grant.predecessor_selector_sha256,
    ) or !digestEqual(
        source_pair.source_exit.source_exit_sha256,
        grant.source_exit_sha256,
    ) or !digestEqual(
        source_pair.source_exit.source_receipt_sha256,
        grant.source_receipt_sha256,
    ) or !digestEqual(
        source_pair.source_exit.checkpoint_sha256,
        grant.checkpoint_sha256,
    ) or !digestEqual(
        source_pair.source_exit.prepared_archive_sha256,
        grant.prepared_archive_sha256,
    ) or !digestEqual(
        source_pair.source_exit.successor_segment_sha256,
        grant.successor_segment_sha256,
    ) or !digestEqual(
        source_pair.source_exit.target_ownership_intent_sha256,
        grant.ownership_intent_sha256,
    ))
        return Error.InvalidActivationGrant;
    const semantic_object = active_set.objects[2];
    if (semantic_object.kind != .extension or
        semantic_object.ordinal !=
            terminal_semantic_object_ordinal or
        semantic_object.abi_version !=
            terminal_semantic.semantic_abi)
        return Error.InvalidActivationGrant;
    const selected_semantic =
        terminal_semantic.decodeV1(
            semantic_object.bytes,
        ) catch return Error.InvalidActivationGrant;
    if (!std.meta.eql(
        selected_semantic,
        expected_semantic,
    ))
        return Error.InvalidActivationGrant;

    grant.consumer_claim =
        lease.advanceConsumerClaimV1(
            grant.consumer_claim,
        ) catch return Error.InvalidActivationGrant;
    grant.phase = .terminal_selected;
    try restore_admission.validateSelectedSourceExitGrantV1(
        grant,
        .terminal_selected,
    );
}

pub const encodeSourceExitReceiptV1 =
    source_exit_wire.encodeV1;
pub const decodeSourceExitReceiptV1 =
    source_exit_wire.decodeV1;
pub const sourceExitWireRootV1 =
    source_exit_wire.rootV1;

const SourceExitedPairV1 = struct {
    set: checkpoint_file.DecodedSetV1,
    selector: checkpoint_file.DecodedSelectorV1,
    source_exit: lane.SourceExitReceiptV1,
    artifacts: successor.ArtifactsV1,
    segment: successor.SuccessorSegmentV1,
};

/// Context-free structural validation used before nesting a generation-two
/// authority archive in the terminal record. Contextual checkpoint/source/
/// target verification remains mandatory in `decodeSourceExitedSetV1`.
fn validateSourceExitedPairV1(
    encoded_set: []const u8,
    encoded_selector: []const u8,
) Error!SourceExitedPairV1 {
    const set = try checkpoint_file.decodeSetV1(encoded_set);
    const selector =
        try checkpoint_file.decodeSelectorV1(encoded_selector);
    if (set.object_count != 2 or
        set.metadata.generation != source_exited_set_generation or
        isZero(set.metadata.parent_checkpoint_sha256) or
        selector.generation != source_exited_set_generation or
        selector.request_epoch != set.metadata.request_epoch or
        selector.publication_next_sequence !=
            set.metadata.publication_next_sequence or
        selector.checkpoint_bytes != encoded_set.len or
        !digestEqual(
            selector.checkpoint_sha256,
            set.checkpoint_sha256,
        ) or !digestEqual(
        selector.challenge_sha256,
        set.metadata.challenge_sha256,
    ))
        return Error.InvalidAuthorityArchive;

    const exit_object = set.objects[0];
    const evidence_object = set.objects[1];
    if (exit_object.kind != .source_process or
        exit_object.ordinal != source_exit_object_ordinal or
        exit_object.abi_version != source_exit_wire_abi or
        exit_object.bytes.len != source_exit_wire_bytes or
        evidence_object.kind != .extension or
        evidence_object.ordinal != evidence_archive_object_ordinal or
        evidence_object.abi_version != evidence_archive_object_abi)
        return Error.InvalidAuthorityArchive;

    const source_exit =
        try decodeSourceExitReceiptV1(exit_object.bytes);
    const decoded_evidence =
        try archive.decodeRestartArchiveV1(
            evidence_object.bytes,
            1,
            [_]u8{0} ** 32,
        );
    const evidence_set = decoded_evidence.archive;
    const artifacts = decoded_evidence.artifacts;
    try validateEvidenceExitBindingsV1(
        .{
            .bytes = evidence_object.bytes,
            .checkpoint_sha256 = evidence_set.checkpoint_sha256,
        },
        artifacts,
        source_exit,
    );
    if (set.metadata.request_epoch !=
        artifacts.segment.request_epoch or
        set.metadata.publication_next_sequence !=
            artifacts.segment.sequence_base or
        !digestEqual(
            set.metadata.challenge_sha256,
            artifacts.segment.challenge_sha256,
        ) or !digestEqual(
        selector.previous_selector_sha256,
        source_exit.predecessor_selector_sha256,
    ))
        return Error.InvalidAuthorityArchive;

    return .{
        .set = set,
        .selector = selector,
        .source_exit = source_exit,
        .artifacts = artifacts,
        .segment = artifacts.segment,
    };
}

fn validateEvidenceExitBindingsV1(
    evidence_set: checkpoint_file.PreparedSetV1,
    artifacts: successor.ArtifactsV1,
    source_exit: lane.SourceExitReceiptV1,
) Error!void {
    if (!lane.sourceExitReceiptStructurallyValidV1(source_exit))
        return Error.InvalidSourceExit;
    const decoded = try checkpoint_file.decodeSetV1(
        evidence_set.bytes,
    );
    if (decoded.metadata.generation != 1 or
        !isZero(decoded.metadata.parent_checkpoint_sha256) or
        decoded.metadata.request_epoch !=
            artifacts.segment.request_epoch or
        decoded.metadata.publication_next_sequence !=
            artifacts.segment.sequence_base or
        !digestEqual(
            decoded.metadata.challenge_sha256,
            artifacts.segment.challenge_sha256,
        ) or !digestEqual(
        decoded.checkpoint_sha256,
        evidence_set.checkpoint_sha256,
    ) or source_exit.publication_request_epoch !=
        artifacts.segment.request_epoch or
        source_exit.expected_next_sequence !=
            artifacts.segment.sequence_base or
        source_exit.source_last_publication_permit_generation !=
            artifacts.segment
                .source_last_resource_permit_generation or
        !digestEqual(
            source_exit.checkpoint_sha256,
            artifacts.segment.source_checkpoint_sha256,
        ) or !digestEqual(
        source_exit.successor_segment_sha256,
        artifacts.segment.segment_sha256,
    ) or !digestEqual(
        source_exit.target_ownership_intent_sha256,
        artifacts.segment.ownership_intent_sha256,
    ) or !digestEqual(
        source_exit.prepared_archive_sha256,
        evidence_set.checkpoint_sha256,
    ))
        return Error.InvalidSourceExit;
}

fn validateRecoveryEvidenceBindingsV1(
    contract: source_recovery.DecodedV1,
    evidence: archive.DecodedRestartArchiveV1,
    source_exit: lane.SourceExitReceiptV1,
) Error!void {
    const manifest = evidence.manifest;
    const artifacts = evidence.artifacts;
    if (contract.request_epoch !=
        artifacts.segment.request_epoch or
        contract.publication_next_sequence !=
            artifacts.segment.sequence_base or
        !digestEqual(
            contract.challenge_sha256,
            artifacts.segment.challenge_sha256,
        ) or !digestEqual(
        contract.plan_sha256,
        manifest.plan.plan_sha256,
    ) or !digestEqual(
        contract.bound_plan_sha256,
        manifest.bound_plan.bound_plan_sha256,
    ) or !digestEqual(
        contract.artifact_sha256,
        manifest.bound_plan.artifact.artifact_sha256,
    ) or !digestEqual(
        contract.execution_plan_sha256,
        manifest.bound_plan.execution.plan_sha256,
    ) or !digestEqual(
        contract.residency_binding_sha256,
        manifest.bound_plan.residency.binding_sha256,
    ) or !recoveryBoundPlanBindingsValidV1(
        contract.bound_plan_input,
        contract.scheduling,
        contract.source_runtime,
        contract.request_epoch,
        .{
            .token_domain_sha256 = manifest.bound_plan.token_domain_sha256,
            .token_domain_config_sha256 = manifest.bound_plan
                .token_domain_config_sha256,
            .artifact_license_sha256 = manifest.bound_plan
                .artifact_license_sha256,
            .previous_plan_sha256 = manifest.bound_plan.execution
                .previous_plan_sha256,
            .ownership_sha256 = manifest.bound_plan.execution
                .ownership_sha256,
        },
    ) or !std.meta.eql(contract.options, manifest.options) or
        !std.meta.eql(contract.target, manifest.target) or
        !digestEqual(
            contract.target_ownership_sha256,
            source_recovery.targetOwnershipRootV1(
                manifest.target,
            ),
        ) or contract.source_runtime.scheduler_epoch !=
        source_exit.scheduler_epoch or
        contract.source_runtime.coordinator_id !=
            source_exit.coordinator_id or
        contract.source_runtime.bank_epoch !=
            source_exit.source_receipt.bank_epoch or
        source_exit.publication_request_epoch !=
            contract.request_epoch or
        source_exit.expected_next_sequence !=
            contract.publication_next_sequence or
        contract.promptCount() != manifest.promptCount())
        return Error.InvalidAuthorityArchive;
    for (0..contract.promptCount()) |index| {
        if (try contract.promptToken(index) !=
            try manifest.promptToken(index))
            return Error.InvalidAuthorityArchive;
    }
}

const RecoveryBoundPlanEvidenceV1 = struct {
    token_domain_sha256: Digest,
    token_domain_config_sha256: Digest,
    artifact_license_sha256: Digest,
    previous_plan_sha256: Digest,
    ownership_sha256: Digest,
};

fn recoveryBoundPlanBindingsValidV1(
    bound_plan_input: session.BoundPlanInputV1,
    scheduling: session.SchedulingV1,
    source_runtime: source_recovery.SourceRuntimeIdentityV1,
    request_epoch: u64,
    evidence: RecoveryBoundPlanEvidenceV1,
) bool {
    return digestEqual(
        bound_plan_input.token_domain_sha256,
        evidence.token_domain_sha256,
    ) and digestEqual(
        bound_plan_input.token_domain_config_sha256,
        evidence.token_domain_config_sha256,
    ) and digestEqual(
        bound_plan_input.artifact_license_sha256,
        evidence.artifact_license_sha256,
    ) and digestEqual(
        bound_plan_input.previous_plan_sha256,
        evidence.previous_plan_sha256,
    ) and digestEqual(
        source_recovery.sourceOwnershipRootV1(
            scheduling,
            source_runtime,
            request_epoch,
        ),
        evidence.ownership_sha256,
    );
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn sourceExitFixtureV1() !lane.SourceExitReceiptV1 {
    var slots = [_]resource_bank.Slot{.{}};
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        41,
    );
    const claim: resource_bank.Claim = .{
        .kv_bytes = 128,
        .output_journal_bytes = 16,
        .queue_slots = 1,
    };
    const receipt = try bank.commit(try bank.reserve(91, claim));
    var value: lane.SourceExitReceiptV1 = .{
        .scheduler_epoch = 51,
        .coordinator_id = 61,
        .handoff_generation = 1,
        .handle = .{
            .scheduler_epoch = 51,
            .slot_index = receipt.slot_index,
            .slot_generation = receipt.generation,
            .tenant_key = 71,
            .request_key = 72,
            .request_generation = 1,
        },
        .publication_request_epoch = 81,
        .expected_next_sequence = 2,
        .source_last_publication_permit_generation = 3,
        .source_receipt = receipt,
        .source_receipt_sha256 = lane.resourceReceiptSha256(receipt),
        .scheduler_chain_head_before_sha256 = filledDigest(0x21),
        .checkpoint_sha256 = filledDigest(0x22),
        .successor_segment_sha256 = filledDigest(0x23),
        .target_ownership_intent_sha256 = filledDigest(0x24),
        .prepared_archive_sha256 = filledDigest(0x25),
        .predecessor_selector_sha256 = filledDigest(0x26),
        .cancel_event_sequence = 4,
        .cancel_event_sha256 = filledDigest(0x27),
    };
    value.source_exit_sha256 =
        lane.sourceExitReceiptSha256(value);
    return value;
}

test "prepared text source-exit wire is canonical and mutation complete" {
    const testing = std.testing;
    const expected = try sourceExitFixtureV1();
    try testing.expect(
        lane.sourceExitReceiptStructurallyValidV1(expected),
    );
    var encoded: [source_exit_wire_bytes]u8 = undefined;
    _ = try encodeSourceExitReceiptV1(expected, &encoded);
    try testing.expectEqualDeep(
        expected,
        try decodeSourceExitReceiptV1(&encoded),
    );

    var mutated = encoded;
    for (0..mutated.len) |index| {
        mutated = encoded;
        mutated[index] ^= 1;
        try testing.expectError(
            Error.InvalidSourceExit,
            decodeSourceExitReceiptV1(&mutated),
        );
    }
    try testing.expectError(
        Error.InvalidLength,
        decodeSourceExitReceiptV1(
            encoded[0 .. encoded.len - 1],
        ),
    );
}

test "prepared text source-exit wire rejects coherent stale authority" {
    const testing = std.testing;
    var changed = try sourceExitFixtureV1();
    changed.handle.slot_generation += 1;
    changed.source_exit_sha256 =
        lane.sourceExitReceiptSha256(changed);
    var encoded: [source_exit_wire_bytes]u8 = undefined;
    try testing.expectError(
        Error.InvalidSourceExit,
        encodeSourceExitReceiptV1(changed, &encoded),
    );
}

test "recoverable source-exit grants cannot use the legacy admission path" {
    try std.testing.expect(
        sourceExitGrantFlavorValidV1(
            false,
            false,
            .legacy,
        ),
    );
    try std.testing.expect(
        sourceExitGrantFlavorValidV1(
            true,
            true,
            .recoverable,
        ),
    );
    try std.testing.expect(
        !sourceExitGrantFlavorValidV1(
            true,
            true,
            .legacy,
        ),
    );
    try std.testing.expect(
        !sourceExitGrantFlavorValidV1(
            false,
            false,
            .recoverable,
        ),
    );
    try std.testing.expect(
        !sourceExitGrantFlavorValidV1(
            true,
            false,
            .legacy,
        ),
    );
    try std.testing.expect(
        !sourceExitGrantFlavorValidV1(
            false,
            true,
            .recoverable,
        ),
    );
}

test "recoverable one-ahead sink rejects a coherent selector reroot" {
    const testing = std.testing;
    const sink = @import("prepared_text_result_sink.zig");
    const sink_file =
        @import("prepared_text_result_sink_file.zig");
    const request_sha256 = filledDigest(0x31);
    const implementation_sha256 = filledDigest(0x32);
    const instance_sha256 = filledDigest(0x33);
    const request_epoch: u64 = 41;
    const initial_sequence: u64 = 2;

    var empty_ledger_storage: [
        sink_file.ledger_header_bytes +
            sink_file.ledger_footer_bytes
    ]u8 = undefined;
    const empty_ledger = try sink_file.encodeLedgerV1(
        request_sha256,
        request_epoch,
        initial_sequence,
        implementation_sha256,
        instance_sha256,
        &.{},
        &empty_ledger_storage,
    );
    const empty_selector =
        try sink_file.prepareInitialSelectorV1(
            empty_ledger,
        );
    const decoded_empty_selector =
        try sink_file.decodeSelectorV1(
            &empty_selector.bytes,
        );

    var semantic_sink = try sink.ResultSinkV1(1).init(
        request_sha256,
        request_epoch,
        initial_sequence,
        implementation_sha256,
        instance_sha256,
    );
    const applied = try semantic_sink.apply(.{
        .request_sha256 = request_sha256,
        .request_epoch = request_epoch,
        .transaction_sequence = initial_sequence,
        .token_id = 7,
        .proposal_sha256 = filledDigest(0x34),
        .transition_sha256 = filledDigest(0x35),
        .commit_receipt_sha256 = filledDigest(0x36),
    });
    try testing.expectEqual(
        sink.ApplyDispositionV1.applied,
        applied.disposition,
    );
    var one_ahead_ledger_storage: [
        sink_file.ledger_header_bytes +
            sink.acknowledgement_bytes +
            sink_file.ledger_footer_bytes
    ]u8 = undefined;
    const one_ahead_ledger = try sink_file.encodeLedgerV1(
        request_sha256,
        request_epoch,
        initial_sequence,
        implementation_sha256,
        instance_sha256,
        semantic_sink.acknowledgementSlice(),
        &one_ahead_ledger_storage,
    );
    const canonical_successor =
        try sink_file.prepareSuccessorSelectorV1(
            decoded_empty_selector,
            one_ahead_ledger,
        );
    const decoded_canonical_successor =
        try sink_file.decodeSelectorV1(
            &canonical_successor.bytes,
        );
    try testing.expect(
        recoverableOneAheadSinkLineageValidV1(
            empty_selector.selector_sha256,
            decoded_canonical_successor
                .previous_selector_sha256,
            applied.acknowledgement
                .predecessor_acknowledgement_sha256,
            applied.acknowledgement
                .predecessor_sink_prefix_sha256,
        ),
    );

    var foreign_predecessor = decoded_empty_selector;
    foreign_predecessor.selector_sha256 =
        filledDigest(0x37);
    const rerooted_successor =
        try sink_file.prepareSuccessorSelectorV1(
            foreign_predecessor,
            one_ahead_ledger,
        );
    const decoded_rerooted_successor =
        try sink_file.decodeSelectorV1(
            &rerooted_successor.bytes,
        );
    try testing.expectEqual(
        @as(u64, 2),
        decoded_rerooted_successor.generation,
    );
    try testing.expect(
        !recoverableOneAheadSinkLineageValidV1(
            empty_selector.selector_sha256,
            decoded_rerooted_successor
                .previous_selector_sha256,
            applied.acknowledgement
                .predecessor_acknowledgement_sha256,
            applied.acknowledgement
                .predecessor_sink_prefix_sha256,
        ),
    );
    try testing.expect(
        !recoverableOneAheadSinkLineageValidV1(
            empty_selector.selector_sha256,
            empty_selector.selector_sha256,
            filledDigest(0x38),
            [_]u8{0} ** 32,
        ),
    );
    try testing.expect(
        !recoverableOneAheadSinkLineageValidV1(
            empty_selector.selector_sha256,
            empty_selector.selector_sha256,
            [_]u8{0} ** 32,
            filledDigest(0x39),
        ),
    );
}

test "recoverable evidence rejects coherent scheduling and plan reroots" {
    const testing = std.testing;
    const request_epoch: u64 = 0x101;
    const source_runtime: source_recovery
        .SourceRuntimeIdentityV1 = .{
        .scheduler_epoch = 0x201,
        .coordinator_id = 0x202,
        .bank_epoch = 0x203,
    };
    const scheduling: session.SchedulingV1 = .{
        .tenant_key = 0x301,
        .request_key = 0x302,
        .request_generation = 1,
        .resource_owner_key = 0x303,
        .weight = 2,
        .deadline_tick = 0x304,
    };
    const bound_plan_input: session.BoundPlanInputV1 = .{
        .request_epoch = request_epoch,
        .token_domain_sha256 = filledDigest(0x41),
        .token_domain_config_sha256 = filledDigest(0x42),
        .artifact_license_sha256 = filledDigest(0x43),
        .previous_plan_sha256 = filledDigest(0x44),
    };
    const evidence: RecoveryBoundPlanEvidenceV1 = .{
        .token_domain_sha256 = bound_plan_input.token_domain_sha256,
        .token_domain_config_sha256 = bound_plan_input.token_domain_config_sha256,
        .artifact_license_sha256 = bound_plan_input.artifact_license_sha256,
        .previous_plan_sha256 = bound_plan_input.previous_plan_sha256,
        .ownership_sha256 = source_recovery.sourceOwnershipRootV1(
            scheduling,
            source_runtime,
            request_epoch,
        ),
    };
    try testing.expect(
        recoveryBoundPlanBindingsValidV1(
            bound_plan_input,
            scheduling,
            source_runtime,
            request_epoch,
            evidence,
        ),
    );

    var foreign_weight = scheduling;
    foreign_weight.weight += 1;
    try testing.expect(
        !recoveryBoundPlanBindingsValidV1(
            bound_plan_input,
            foreign_weight,
            source_runtime,
            request_epoch,
            evidence,
        ),
    );
    var foreign_deadline = scheduling;
    foreign_deadline.deadline_tick += 1;
    try testing.expect(
        !recoveryBoundPlanBindingsValidV1(
            bound_plan_input,
            foreign_deadline,
            source_runtime,
            request_epoch,
            evidence,
        ),
    );
    var foreign_previous_plan = bound_plan_input;
    foreign_previous_plan.previous_plan_sha256 =
        filledDigest(0x45);
    try testing.expect(
        !recoveryBoundPlanBindingsValidV1(
            foreign_previous_plan,
            scheduling,
            source_runtime,
            request_epoch,
            evidence,
        ),
    );
}
