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

/// Pin the selector-selected generation-two source-exit authority to one
/// address-stable, process-local grant. The generic lease consumer claim makes
/// duplicate target activation fail while preserving the durable selector for
/// deterministic retry after a pre-activation abort.
pub fn initSelectedSourceExitGrantV1(
    grant: *restore_admission.SelectedSourceExitGrantV1,
    lease: *checkpoint_file.LeaseV1,
    selected: DecodedSourceExitedSetV1,
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
    if (!std.meta.eql(lease.selector, selected.selector) or
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
    if (authority_archive.object_count != 2 or
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
