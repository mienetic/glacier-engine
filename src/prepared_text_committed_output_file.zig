//! Read-only filesystem composition for prepared-text committed output.
//!
//! This module opens only the active checkpoint and result-sink selectors plus
//! their selected immutable objects. It takes no writer lease, performs no
//! recovery or repair, and rereads both selectors after reconciliation to
//! establish an overlapping observed interval.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const committed = @import("prepared_text_committed_output.zig");
const durable_handoff = @import("prepared_text_durable_handoff.zig");
const input_archive = @import("prepared_text_input_archive.zig");
const progress = @import("prepared_text_acknowledged_progress.zig");
const restart_manifest = @import("prepared_text_restart_manifest.zig");
const result_sink = @import("prepared_text_result_sink.zig");
const sink_file = @import("prepared_text_result_sink_file.zig");
const tokenizer = @import("tokenizer.zig");

const maximum_sink_acknowledgements: usize =
    committed.maximum_visible_tokens;

pub const InspectOptionsV1 = struct {
    max_set_bytes: usize,
};

/// Returns a verified committed-output view whose `visible_bytes` borrow
/// `output_storage`. The caller retains ownership of `directory`; this
/// function never closes it or obtains write authority.
pub fn inspectDirectoryV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    options: InspectOptionsV1,
    output_storage: []u8,
) !committed.ViewV1 {
    var sizing_selector_storage: [checkpoint_file.selector_bytes]u8 = undefined;
    const sizing_selector =
        try checkpoint_file.readActiveSelectorReadOnlyV1(
            directory,
            &sizing_selector_storage,
        );
    const selected_set_bytes = std.math.cast(
        usize,
        sizing_selector.checkpoint_bytes,
    ) orelse return error.CheckpointSetTooLarge;
    if (selected_set_bytes > options.max_set_bytes)
        return error.CheckpointSetTooLarge;
    const selected_set_storage = try allocator.alloc(
        u8,
        selected_set_bytes,
    );
    defer allocator.free(selected_set_storage);

    var checkpoint_selector_storage: [checkpoint_file.selector_bytes]u8 = undefined;
    const checkpoint_snapshot =
        checkpoint_file.readSelectedSnapshotReadOnlyV1(
            directory,
            &checkpoint_selector_storage,
            selected_set_storage,
            selected_set_storage.len,
        ) catch |snapshot_error| switch (snapshot_error) {
            error.BufferTooSmall, error.CapacityExceeded => {
                try requireCheckpointSizingSelectorUnchangedV1(
                    directory,
                    &sizing_selector_storage,
                );
                return snapshot_error;
            },
            else => return snapshot_error,
        };
    const normalized = try normalizeCheckpointV1(
        allocator,
        directory,
        checkpoint_snapshot,
        options.max_set_bytes,
    );

    const maximum_sink_ledger_bytes =
        try sink_file.ledgerBytesForCountV1(
            maximum_sink_acknowledgements,
        );
    var sink_sizing_storage: [sink_file.selector_bytes]u8 =
        undefined;
    const sink_sizing =
        try sink_file.readActiveSelectorReadOnlyV1(
            directory,
            &sink_sizing_storage,
        );
    if (sink_sizing.acknowledgement_count >
        maximum_sink_acknowledgements or
        sink_sizing.ledger_bytes > maximum_sink_ledger_bytes)
        return error.ResultSinkTooLarge;
    const sink_ledger_storage = try allocator.alloc(
        u8,
        sink_sizing.ledger_bytes,
    );
    defer allocator.free(sink_ledger_storage);
    var sink_selector_storage: [sink_file.selector_bytes]u8 =
        undefined;
    const sink_snapshot =
        sink_file.readSelectedSnapshotReadOnlyV1(
            directory,
            &sink_selector_storage,
            sink_ledger_storage,
            maximum_sink_acknowledgements,
        ) catch |snapshot_error| switch (snapshot_error) {
            error.BufferTooSmall, error.CapacityExceeded => {
                try requireSinkSizingSelectorUnchangedV1(
                    directory,
                    &sink_sizing_storage,
                );
                return snapshot_error;
            },
            else => return snapshot_error,
        };
    if (sink_snapshot.selector.acknowledgement_count >
        maximum_sink_acknowledgements or
        sink_snapshot.selector.ledger_bytes >
            maximum_sink_ledger_bytes)
        return error.ResultSinkTooLarge;

    const staged_output_storage = try allocator.alloc(
        u8,
        @min(
            output_storage.len,
            maximum_sink_acknowledgements,
        ),
    );
    defer allocator.free(staged_output_storage);
    var view = try committed.reconcileV1(
        normalized.context,
        normalized.checkpoint,
        .{
            .selector = sink_snapshot.selector,
            .ledger = sink_snapshot.ledger,
        },
        staged_output_storage,
    );

    // Both byte-identical selectors must still be selected after both full
    // snapshots and the pure join. This establishes an overlapping observed
    // interval without acquiring either writer lease.
    var checkpoint_recheck: [checkpoint_file.selector_bytes]u8 = undefined;
    _ = checkpoint_file.readActiveSelectorReadOnlyV1(
        directory,
        &checkpoint_recheck,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(
        u8,
        &checkpoint_selector_storage,
        &checkpoint_recheck,
    )) return error.SelectionChanged;
    var sink_recheck: [sink_file.selector_bytes]u8 = undefined;
    _ = sink_file.readActiveSelectorReadOnlyV1(
        directory,
        &sink_recheck,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(
        u8,
        &sink_selector_storage,
        &sink_recheck,
    )) return error.SelectionChanged;

    @memcpy(
        output_storage[0..view.visible_bytes.len],
        view.visible_bytes,
    );
    view.visible_bytes =
        output_storage[0..view.visible_bytes.len];
    return view;
}

fn requireCheckpointSizingSelectorUnchangedV1(
    directory: std.fs.Dir,
    expected: *const [checkpoint_file.selector_bytes]u8,
) !void {
    var current: [checkpoint_file.selector_bytes]u8 = undefined;
    _ = checkpoint_file.readActiveSelectorReadOnlyV1(
        directory,
        &current,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(u8, expected, &current))
        return error.SelectionChanged;
}

fn requireSinkSizingSelectorUnchangedV1(
    directory: std.fs.Dir,
    expected: *const [sink_file.selector_bytes]u8,
) !void {
    var current: [sink_file.selector_bytes]u8 = undefined;
    _ = sink_file.readActiveSelectorReadOnlyV1(
        directory,
        &current,
    ) catch return error.SelectionChanged;
    if (!std.mem.eql(u8, expected, &current))
        return error.SelectionChanged;
}

const NormalizedCheckpointV1 = struct {
    context: committed.ContextV1,
    checkpoint: committed.CheckpointV1,
};

fn normalizeCheckpointV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    selected: checkpoint_file.ReadOnlySelectedSnapshotV1,
    max_set_bytes: usize,
) !NormalizedCheckpointV1 {
    if (selected.selector.generation ==
        progress.minimum_predecessor_generation)
    {
        const source_exited =
            try durable_handoff.decodeSourceExitedSetV1(
                selected.set_bytes,
                selected.selector,
                selected.set.metadata.parent_checkpoint_sha256,
            );
        const bound_input = source_exited.input_archive orelse
            return error.BoundInputArchiveRequired;
        const recovery =
            source_exited.source_recovery_contract orelse
            return error.SourceRecoveryContractRequired;
        const context = try contextFromInputV1(
            bound_input,
            source_exited.evidence.manifest,
        );
        return .{
            .context = context,
            .checkpoint = checkpointFromStateV1(
                context,
                selected,
                source_exited.evidence.checkpoint.request_epoch,
                source_exited.evidence.checkpoint
                    .publication_next_sequence,
                recovery.sink.initial_sequence,
                source_exited.evidence.checkpoint
                    .canonical_output_u32_le,
                source_exited.evidence.manifest.plan.plan_sha256,
                recovery.sink.implementation_sha256,
                recovery.sink.instance_sha256,
                result_sink.zero_digest,
                result_sink.zero_digest,
                source_exited.evidence.checkpoint
                    .state_commitment_sha256,
                false,
            ),
        };
    }
    if (selected.selector.generation <
        progress.minimum_predecessor_generation)
        return error.UnsupportedCheckpointGeneration;

    const terminal =
        selected.set.object_count == progress.terminal_object_count;
    if (!terminal and
        selected.set.object_count !=
            progress.nonterminal_object_count and
        selected.set.object_count !=
            progress.bound_nonterminal_object_count)
        return error.UnsupportedCheckpointShape;
    const embedded_selector = try embeddedPredecessorSelectorV1(
        selected,
        terminal,
    );
    const predecessor_selector =
        try checkpoint_file.decodeSelectorV1(
            embedded_selector.bytes,
        );
    const predecessor_bytes = std.math.cast(
        usize,
        predecessor_selector.checkpoint_bytes,
    ) orelse return error.CheckpointSetTooLarge;
    if (predecessor_bytes > max_set_bytes)
        return error.CheckpointSetTooLarge;
    const predecessor_storage = try allocator.alloc(
        u8,
        predecessor_bytes,
    );
    defer allocator.free(predecessor_storage);
    const predecessor =
        try checkpoint_file.loadRetainedSetReadOnlyV1(
            directory,
            predecessor_selector,
            predecessor_storage,
            predecessor_storage.len,
        );

    if (!terminal) {
        const decoded = try progress.decodeNonterminalV1(
            predecessor.bytes,
            embedded_selector.bytes,
            selected.set_bytes,
            selected.selector_bytes,
        );
        const bound_input = decoded.input_archive orelse
            return error.BoundInputArchiveRequired;
        const context = try contextFromInputV1(
            bound_input,
            decoded.manifest,
        );
        const sink_initial = try acknowledgementInitialSequenceV1(
            decoded.acknowledgement,
        );
        return .{
            .context = context,
            .checkpoint = checkpointFromStateV1(
                context,
                selected,
                decoded.checkpoint.request_epoch,
                decoded.checkpoint.publication_next_sequence,
                sink_initial,
                decoded.checkpoint.canonical_output_u32_le,
                decoded.manifest.plan.plan_sha256,
                decoded.acknowledgement
                    .sink_implementation_sha256,
                decoded.acknowledgement.sink_instance_sha256,
                decoded.acknowledgement
                    .acknowledgement_sha256,
                decoded.acknowledgement
                    .result_sink_prefix_sha256,
                decoded.checkpoint.state_commitment_sha256,
                false,
            ),
        };
    }

    const decoded = try progress.decodeTerminalV1(
        predecessor.bytes,
        embedded_selector.bytes,
        selected.set_bytes,
        selected.selector_bytes,
    );
    const producer = try progress.decodeProducerContextV1(
        decoded.predecessor,
    );
    const bound_input = producer.input_archive orelse
        return error.BoundInputArchiveRequired;
    const context = try contextFromInputV1(
        bound_input,
        producer.manifest,
    );
    const sink_initial = try acknowledgementInitialSequenceV1(
        decoded.acknowledgement,
    );
    return .{
        .context = context,
        .checkpoint = checkpointFromStateV1(
            context,
            selected,
            decoded.semantic.request_epoch,
            decoded.semantic.publication_next_sequence,
            sink_initial,
            decoded.canonical_output_u32_le,
            producer.manifest.plan.plan_sha256,
            decoded.acknowledgement.sink_implementation_sha256,
            decoded.acknowledgement.sink_instance_sha256,
            decoded.acknowledgement.acknowledgement_sha256,
            decoded.acknowledgement.result_sink_prefix_sha256,
            decoded.semantic.state_commitment_sha256,
            true,
        ),
    };
}

fn embeddedPredecessorSelectorV1(
    selected: checkpoint_file.ReadOnlySelectedSnapshotV1,
    terminal: bool,
) !checkpoint_file.ObjectViewV1 {
    if (selected.set.object_count == 0)
        return error.UnsupportedCheckpointShape;
    const object = selected.set.objects[0];
    const expected_kind: checkpoint_file.ObjectKindV1 =
        if (terminal) .extension else .runtime_state;
    const expected_ordinal =
        if (terminal)
            progress.terminal_predecessor_selector_object_ordinal
        else
            progress.nonterminal_predecessor_selector_object_ordinal;
    if (object.kind != expected_kind or
        object.ordinal != expected_ordinal or
        object.abi_version != checkpoint_file.selector_abi or
        object.bytes.len != checkpoint_file.selector_bytes)
        return error.UnsupportedCheckpointShape;
    return object;
}

fn contextFromInputV1(
    bound_input: input_archive.DecodedV1,
    manifest: restart_manifest.DecodedV1,
) !committed.ContextV1 {
    if (!tokenizer.utf8ByteManifestValidV1(
        bound_input.tokenizer_manifest,
    )) return error.CanonicalTokenizerRequired;
    try input_archive.verifyCurrentPlanV1(
        bound_input,
        manifest.plan,
        manifest.bound_plan,
    );
    return .{
        .package_sha256 = bound_input.package.package_sha256,
        .representation_sha256 = bound_input.representation.representation_sha256,
        .input_archive_sha256 = bound_input.archive_sha256,
        .tokenizer_manifest = bound_input.tokenizer_manifest,
        .local_plan_sha256 = manifest.plan.plan_sha256,
    };
}

fn checkpointFromStateV1(
    context: committed.ContextV1,
    selected: checkpoint_file.ReadOnlySelectedSnapshotV1,
    request_epoch: u64,
    next_sequence: u64,
    sink_initial_sequence: u64,
    canonical_output_u32_le: []const u8,
    request_sha256: committed.Digest,
    sink_implementation_sha256: committed.Digest,
    sink_instance_sha256: committed.Digest,
    head_acknowledgement_sha256: committed.Digest,
    result_sink_prefix_sha256: committed.Digest,
    state_sha256: committed.Digest,
    terminal: bool,
) committed.CheckpointV1 {
    return .{
        .context = context,
        .generation = selected.selector.generation,
        .terminal = terminal,
        .request_epoch = request_epoch,
        .next_sequence = next_sequence,
        .sink_initial_sequence = sink_initial_sequence,
        .canonical_output_u32_le = canonical_output_u32_le,
        .request_sha256 = request_sha256,
        .sink_implementation_sha256 = sink_implementation_sha256,
        .sink_instance_sha256 = sink_instance_sha256,
        .head_acknowledgement_sha256 = head_acknowledgement_sha256,
        .result_sink_prefix_sha256 = result_sink_prefix_sha256,
        .selector_sha256 = selected.selector.selector_sha256,
        .selected_set_sha256 = selected.set.checkpoint_sha256,
        .state_sha256 = state_sha256,
    };
}

fn acknowledgementInitialSequenceV1(
    acknowledgement: result_sink.ResultAcknowledgementV1,
) !u64 {
    if (acknowledgement.application_ordinal == 0)
        return error.InvalidAcknowledgementOrdinal;
    const preceding = acknowledgement.application_ordinal - 1;
    return std.math.sub(
        u64,
        acknowledgement.transaction_sequence,
        preceding,
    ) catch return error.InvalidAcknowledgementOrdinal;
}
