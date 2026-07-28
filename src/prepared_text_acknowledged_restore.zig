//! Lease-pinned activation for acknowledged prepared-text progress.
//!
//! The portable progress module proves bytes and immediate selector lineage.
//! This module performs the process-local half: it pins the selected
//! nonterminal generation to the checkpoint-file lease's sole consumer claim,
//! reconstructs the existing restored-admission grant from canonical
//! producer/receipt evidence, and advances that claim only after the exact
//! verified successor becomes active.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const lane = core.lane_weave_qos;
const progress =
    @import("prepared_text_acknowledged_progress.zig");
const restore =
    @import("prepared_text_restore_admission.zig");
const successor = @import("prepared_text_successor.zig");

pub const Digest = [32]u8;

pub const Error = checkpoint_file.Error ||
    progress.Error ||
    restore.Error ||
    error{
        ArithmeticOverflow,
        InvalidAcknowledgedProgress,
        InvalidActivationGrant,
    };

/// Pin one selector-selected nonterminal progress generation to an
/// address-stable restored-activation grant. The producer identity comes from
/// the predecessor manifest's target; the selected manifest supplies the
/// matching source receipt and the complete next-target evidence.
pub fn initSelectedProgressGrantV1(
    grant: *restore.SelectedRestartGrantV1,
    lease: *checkpoint_file.LeaseV1,
    selected: progress.DecodedNonterminalV1,
) Error!void {
    if (grant.phase != .empty or grant.lease != null or
        grant.self_address != 0 or grant.lease_address != 0 or
        lease.state != .ready or
        selected.selected.selector.generation <=
            progress.minimum_predecessor_generation or
        selected.selected.selector.generation ==
            std.math.maxInt(u64))
        return Error.InvalidActivationGrant;

    const active_set = lease.activeSet() catch
        return Error.InvalidActivationGrant;
    const source = selected.manifest.source;
    const producer = selected.producer_target;
    const artifacts = selected.artifacts;
    const acknowledgement = selected.acknowledgement;
    const acknowledged_next = std.math.add(
        u64,
        acknowledgement.transaction_sequence,
        1,
    ) catch return Error.InvalidAcknowledgedProgress;
    if (!std.meta.eql(
        lease.selector,
        selected.selected.selector,
    ) or !digestEqual(
        active_set.checkpoint_sha256,
        selected.selected.set.checkpoint_sha256,
    ) or source.receipt.bank_epoch != producer.bank_epoch or
        source.publication.request_epoch !=
            artifacts.segment.request_epoch or
        source.publication.next_sequence !=
            artifacts.segment.sequence_base or
        source.publication.last_resource_permit_generation !=
            artifacts.segment.source_last_resource_permit_generation or
        acknowledgement.request_epoch !=
            artifacts.segment.request_epoch or
        acknowledged_next != artifacts.segment.sequence_base)
        return Error.InvalidAcknowledgedProgress;

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
        .source_scheduler_epoch = producer.scheduler_epoch,
        .source_coordinator_id = producer.coordinator_id,
        .source_bank_epoch = source.receipt.bank_epoch,
        .request_epoch = artifacts.segment.request_epoch,
        .publication_next_sequence = artifacts.segment.sequence_base,
        .source_last_resource_permit_generation = artifacts.segment
            .source_last_resource_permit_generation,
        .source_selector_generation = selected.selected.selector.generation,
        .terminal_selector_generation = selected.selected.selector.generation + 1,
        .authority_checkpoint_sha256 = selected.selected.set.checkpoint_sha256,
        .selected_selector_sha256 = selected.selected.selector.selector_sha256,
        .predecessor_selector_sha256 = selected.predecessor.selector.selector_sha256,
        // The retained V1 field name predates acknowledged progress. For this
        // authority kind it carries the exact selected acknowledgement root.
        .source_exit_sha256 = acknowledgement.acknowledgement_sha256,
        .source_receipt_sha256 = lane.resourceReceiptSha256(source.receipt),
        .checkpoint_sha256 = selected.checkpoint.checkpoint_sha256,
        .prepared_archive_sha256 = selected.selected.set.checkpoint_sha256,
        .successor_segment_sha256 = artifacts.segment.segment_sha256,
        .ownership_intent_sha256 = artifacts.segment.ownership_intent_sha256,
        .challenge_sha256 = artifacts.segment.challenge_sha256,
        .selected_authority_kind = .acknowledged_progress,
        .selected_acknowledgement_sha256 = acknowledgement.acknowledgement_sha256,
        .selected_sink_prefix_sha256 = acknowledgement.result_sink_prefix_sha256,
        .phase = .ready,
    };
    grant.grant_sha256 =
        restore.selectedSourceExitGrantRootV1(grant.*);
    try restore.validateSelectedSourceExitGrantV1(
        grant,
        .ready,
    );
}

/// Advance a consumed grant after a verified nonterminal progress set becomes
/// the active immediate successor.
pub fn markNonterminalSelectedV1(
    grant: *restore.SelectedRestartGrantV1,
    selected: progress.DecodedNonterminalV1,
) Error!void {
    try validateSelectedEdgeV1(
        grant,
        selected.predecessor,
        selected.selected,
        selected.acknowledgement,
    );
    try restore.markAcknowledgedSuccessorSelectedV1(
        grant,
        selected.selected.set.checkpoint_sha256,
        selected.selected.selector.selector_sha256,
        selected.selected.selector.publication_next_sequence,
        false,
    );
}

/// Advance a consumed grant after a verified terminal progress set becomes
/// the active immediate successor.
pub fn markTerminalSelectedV1(
    grant: *restore.SelectedRestartGrantV1,
    selected: progress.DecodedTerminalV1,
) Error!void {
    try validateSelectedEdgeV1(
        grant,
        selected.predecessor,
        selected.selected,
        selected.acknowledgement,
    );
    try restore.markAcknowledgedSuccessorSelectedV1(
        grant,
        selected.selected.set.checkpoint_sha256,
        selected.selected.selector.selector_sha256,
        selected.selected.selector.publication_next_sequence,
        true,
    );
}

fn validateSelectedEdgeV1(
    grant: *restore.SelectedRestartGrantV1,
    predecessor: progress.DecodedSelectionV1,
    selected: progress.DecodedSelectionV1,
    acknowledgement: @import(
        "prepared_text_result_sink.zig",
    ).ResultAcknowledgementV1,
) Error!void {
    if (grant.phase != .consumed or
        grant.self_address != @intFromPtr(grant) or
        !digestEqual(
            grant.grant_sha256,
            restore.selectedSourceExitGrantRootV1(grant.*),
        ) or !digestEqual(
        predecessor.set.checkpoint_sha256,
        grant.authority_checkpoint_sha256,
    ) or !digestEqual(
        predecessor.selector.selector_sha256,
        grant.selected_selector_sha256,
    ) or predecessor.selector.generation !=
        grant.source_selector_generation or
        predecessor.selector.publication_next_sequence !=
            grant.publication_next_sequence or
        selected.selector.generation !=
            grant.terminal_selector_generation or
        acknowledgement.request_epoch != grant.request_epoch or
        acknowledgement.transaction_sequence !=
            grant.publication_next_sequence)
        return Error.InvalidAcknowledgedProgress;
    switch (grant.selected_authority_kind) {
        .source_exit => {
            if (acknowledgement.application_ordinal != 1 or
                !isZero(
                    acknowledgement
                        .predecessor_acknowledgement_sha256,
                ) or !isZero(
                acknowledgement.predecessor_sink_prefix_sha256,
            ))
                return Error.InvalidAcknowledgedProgress;
        },
        .acknowledged_progress => {
            if (!digestEqual(
                acknowledgement
                    .predecessor_acknowledgement_sha256,
                grant.selected_acknowledgement_sha256,
            ) or !digestEqual(
                acknowledgement.predecessor_sink_prefix_sha256,
                grant.selected_sink_prefix_sha256,
            ))
                return Error.InvalidAcknowledgedProgress;
        },
        .none => return Error.InvalidActivationGrant,
    }
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}
