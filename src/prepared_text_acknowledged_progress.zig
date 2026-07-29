//! Portable acknowledged-progress selection for prepared-text continuation.
//!
//! This module composes one result-sink acknowledgement with the exact
//! checkpoint selector that preceded it. A non-terminal successor contains
//! that selector, the five canonical prepared-text restart objects, and the
//! acknowledgement. The additive bound shape carries an eighth object with
//! the byte-identical package, tokenizer, and raw-input context. A terminal
//! successor contains the immediate predecessor selector/archive, the
//! receipt-independent terminal semantic, the final acknowledgement, and the
//! complete canonical output-token record.
//!
//! The values here are authority-free canonical evidence.  Encoding and
//! decoding perform no filesystem I/O, acquire no lease, and create no
//! runnable Session.  The caller must still publish the returned set through
//! the generic checkpoint-file lease and then validate the selected successor
//! against the same immediate predecessor.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const lane = core.lane_weave_qos;
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
const archive = @import("prepared_text_handoff_archive.zig");
const checkpoint = @import("prepared_text_checkpoint.zig");
const durable_handoff =
    @import("prepared_text_durable_handoff.zig");
const input_archive =
    @import("prepared_text_input_archive.zig");
const kv = @import("kv_cache.zig");
const lane_contiguous =
    @import("lane_contiguous_publication.zig");
const publication = @import("lane_publication_txn.zig");
const restart_manifest =
    @import("prepared_text_restart_manifest.zig");
const result_sink = @import("prepared_text_result_sink.zig");
const source_recovery =
    @import("prepared_text_source_recovery.zig");
const session = @import("prepared_text_session.zig");
const successor = @import("prepared_text_successor.zig");
const terminal_semantic =
    @import("prepared_text_terminal_equivalence.zig");

pub const Digest = [32]u8;
pub const minimum_predecessor_generation: u64 = 2;

pub const nonterminal_object_count: usize = 7;
pub const bound_nonterminal_object_count: usize = 8;
pub const nonterminal_predecessor_selector_object_ordinal: u64 = 0;
pub const checkpoint_object_ordinal: u64 = 0;
pub const successor_plan_object_ordinal: u64 = 1;
pub const successor_residency_object_ordinal: u64 = 2;
pub const successor_segment_object_ordinal: u64 = 3;
pub const restart_manifest_object_ordinal: u64 = 4;
pub const acknowledgement_object_ordinal: u64 = 5;
pub const input_archive_object_ordinal: u64 = 6;

pub const terminal_output_tokens_abi: u64 =
    0x4750_544f_0000_0001;
pub const maximum_terminal_output_tokens: usize = 16 * 1024;
pub const terminal_object_count: usize = 5;
pub const terminal_predecessor_selector_object_ordinal: u64 = 0;
pub const terminal_predecessor_set_object_ordinal: u64 = 1;
pub const terminal_semantic_object_ordinal: u64 = 2;
pub const terminal_acknowledgement_object_ordinal: u64 = 3;
pub const terminal_output_tokens_object_ordinal: u64 = 4;

pub const Error = checkpoint_file.Error ||
    archive.Error ||
    checkpoint.Error ||
    durable_handoff.Error ||
    input_archive.Error ||
    restart_manifest.Error ||
    result_sink.Error ||
    successor.Error ||
    terminal_semantic.Error ||
    error{
        ArithmeticOverflow,
        InvalidAcknowledgement,
        InvalidLineage,
        InvalidNonterminalProgress,
        InvalidSelection,
        InvalidTerminalProgress,
    };

/// Exact canonical selector/archive pair.  Both slices are borrowed.
pub const DecodedSelectionV1 = struct {
    encoded_set: []const u8,
    encoded_selector: []const u8,
    set: checkpoint_file.DecodedSetV1,
    selector: checkpoint_file.DecodedSelectorV1,
};

pub const PreparedNonterminalV1 = struct {
    set: checkpoint_file.PreparedSetV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
};

pub const DecodedNonterminalV1 = struct {
    predecessor: DecodedSelectionV1,
    selected: DecodedSelectionV1,
    producer_target: successor.TargetOwnershipV1,
    manifest: restart_manifest.DecodedV1,
    checkpoint: checkpoint.DecodedV1,
    artifacts: successor.ArtifactsV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
    input_archive: ?input_archive.DecodedV1 = null,
};

pub const PreparedTerminalV1 = struct {
    set: checkpoint_file.PreparedSetV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
};

pub const DecodedTerminalV1 = struct {
    predecessor: DecodedSelectionV1,
    selected: DecodedSelectionV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
    canonical_output_u32_le: []const u8,

    pub fn outputCount(self: *const DecodedTerminalV1) usize {
        return self.canonical_output_u32_le.len /
            @sizeOf(u32);
    }

    pub fn outputToken(
        self: *const DecodedTerminalV1,
        index: usize,
    ) Error!u32 {
        if (index >= self.outputCount())
            return Error.InvalidTerminalProgress;
        const offset = index * @sizeOf(u32);
        return std.mem.readInt(
            u32,
            self.canonical_output_u32_le[offset..][0..4],
            .little,
        );
    }
};

/// Decode and cross-check one selected set and its fixed selector.
pub fn decodeSelectionV1(
    encoded_set: []const u8,
    encoded_selector: []const u8,
) Error!DecodedSelectionV1 {
    const set = try checkpoint_file.decodeSetV1(encoded_set);
    const selector =
        try checkpoint_file.decodeSelectorV1(encoded_selector);
    if (selector.generation != set.metadata.generation or
        selector.request_epoch != set.metadata.request_epoch or
        selector.publication_next_sequence !=
            set.metadata.publication_next_sequence or
        selector.checkpoint_bytes !=
            @as(u64, @intCast(encoded_set.len)) or
        !digestEqual(
            selector.checkpoint_sha256,
            set.checkpoint_sha256,
        ) or !digestEqual(
        selector.challenge_sha256,
        set.metadata.challenge_sha256,
    ))
        return Error.InvalidSelection;
    return .{
        .encoded_set = encoded_set,
        .encoded_selector = encoded_selector,
        .set = set,
        .selector = selector,
    };
}

/// Require one exact `G -> G + 1`, `S -> S + 1` selector edge.
pub fn validateImmediateSuccessorV1(
    predecessor: DecodedSelectionV1,
    selected: DecodedSelectionV1,
) Error!void {
    if (predecessor.selector.generation <
        minimum_predecessor_generation)
        return Error.InvalidLineage;
    const next_generation = std.math.add(
        u64,
        predecessor.selector.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const next_sequence = std.math.add(
        u64,
        predecessor.selector.publication_next_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (selected.selector.generation != next_generation or
        selected.selector.request_epoch !=
            predecessor.selector.request_epoch or
        selected.selector.publication_next_sequence != next_sequence or
        !digestEqual(
            selected.set.metadata.parent_checkpoint_sha256,
            predecessor.set.checkpoint_sha256,
        ) or
        !digestEqual(
            selected.selector.previous_selector_sha256,
            predecessor.selector.selector_sha256,
        ) or !digestEqual(
        selected.selector.challenge_sha256,
        predecessor.selector.challenge_sha256,
    ))
        return Error.InvalidLineage;
}

/// The legacy seven-object set adds the exact predecessor selector and one
/// acknowledgement payload to an already canonical five-object archive.
pub fn encodedNonterminalBytesV1(
    encoded_restart_archive_bytes: usize,
) Error!usize {
    const with_selector = std.math.add(
        usize,
        encoded_restart_archive_bytes,
        checkpoint_file.selector_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        with_selector,
        result_sink.acknowledgement_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Encode one prepared, authority-free non-terminal progress generation.
///
/// `encoded_restart_archive` must already use generation `G + 1`, parent
/// checkpoint equal to the predecessor, and next sequence `S + 1`.
pub fn encodeNonterminalV1(
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    encoded_restart_archive: []const u8,
    encoded_acknowledgement: []const u8,
    destination: []u8,
) Error!PreparedNonterminalV1 {
    const predecessor = try decodeSelectionV1(
        predecessor_set,
        predecessor_selector,
    );
    if (predecessor.selector.generation <
        minimum_predecessor_generation)
        return Error.InvalidLineage;
    const next_generation = std.math.add(
        u64,
        predecessor.selector.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const restart = try archive.decodeRestartArchiveV1(
        encoded_restart_archive,
        next_generation,
        predecessor.set.checkpoint_sha256,
    );
    const producer = try decodeProducerContextV1(predecessor);
    try validateProducerLineageV1(
        producer,
        restart.manifest,
        null,
    );
    const acknowledgement =
        try result_sink.decodeAcknowledgementV1(
            encoded_acknowledgement,
        );
    try validateAcknowledgementEdgeV1(
        predecessor,
        producer,
        acknowledgement,
    );
    try validateNonterminalPayloadV1(
        predecessor,
        restart.archive,
        restart.checkpoint,
        acknowledgement,
    );

    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .runtime_state,
            .ordinal = nonterminal_predecessor_selector_object_ordinal,
            .abi_version = checkpoint_file.selector_abi,
            .bytes = predecessor_selector,
        },
        inputFromView(restart.archive.objects[0]),
        inputFromView(restart.archive.objects[1]),
        inputFromView(restart.archive.objects[2]),
        inputFromView(restart.archive.objects[3]),
        inputFromView(restart.archive.objects[4]),
        .{
            .kind = .extension,
            .ordinal = acknowledgement_object_ordinal,
            .abi_version = result_sink.acknowledgement_abi,
            .bytes = encoded_acknowledgement,
        },
    };
    const set = try checkpoint_file.encodeSetV1(
        restart.archive.metadata,
        &objects,
        destination,
    );
    return .{
        .set = set,
        .acknowledgement = acknowledgement,
    };
}

/// Size the additive eight-object generation. The input archive bytes are
/// already included in `encoded_bound_restart_archive_bytes`.
pub fn encodedBoundNonterminalBytesV1(
    encoded_bound_restart_archive_bytes: usize,
) Error!usize {
    return encodedNonterminalBytesV1(
        encoded_bound_restart_archive_bytes,
    );
}

/// Encode a non-terminal generation that retains the canonical raw-input
/// archive. The acknowledgement remains ordinal five and precedes input
/// ordinal six, so later generations can carry the input bytes unchanged.
pub fn encodeBoundNonterminalV1(
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    encoded_bound_restart_archive: []const u8,
    encoded_acknowledgement: []const u8,
    destination: []u8,
) Error!PreparedNonterminalV1 {
    const predecessor = try decodeSelectionV1(
        predecessor_set,
        predecessor_selector,
    );
    if (predecessor.selector.generation <
        minimum_predecessor_generation)
        return Error.InvalidLineage;
    const next_generation = std.math.add(
        u64,
        predecessor.selector.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const restart = try archive.decodeBoundRestartArchiveV1(
        encoded_bound_restart_archive,
        next_generation,
        predecessor.set.checkpoint_sha256,
    );
    const producer = try decodeProducerContextV1(predecessor);
    try validateProducerLineageV1(
        producer,
        restart.manifest,
        restart.input_archive,
    );
    const acknowledgement =
        try result_sink.decodeAcknowledgementV1(
            encoded_acknowledgement,
        );
    try validateAcknowledgementEdgeV1(
        predecessor,
        producer,
        acknowledgement,
    );
    try validateNonterminalPayloadV1(
        predecessor,
        restart.archive,
        restart.checkpoint,
        acknowledgement,
    );

    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .runtime_state,
            .ordinal = nonterminal_predecessor_selector_object_ordinal,
            .abi_version = checkpoint_file.selector_abi,
            .bytes = predecessor_selector,
        },
        inputFromView(restart.archive.objects[0]),
        inputFromView(restart.archive.objects[1]),
        inputFromView(restart.archive.objects[2]),
        inputFromView(restart.archive.objects[3]),
        inputFromView(restart.archive.objects[4]),
        .{
            .kind = .extension,
            .ordinal = acknowledgement_object_ordinal,
            .abi_version = result_sink.acknowledgement_abi,
            .bytes = encoded_acknowledgement,
        },
        inputFromView(restart.archive.objects[5]),
    };
    const set = try checkpoint_file.encodeSetV1(
        restart.archive.metadata,
        &objects,
        destination,
    );
    return .{
        .set = set,
        .acknowledgement = acknowledgement,
    };
}

/// Decode a selected non-terminal generation against its exact predecessor.
pub fn decodeNonterminalV1(
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    selected_set: []const u8,
    selected_selector: []const u8,
) Error!DecodedNonterminalV1 {
    const predecessor = try decodeSelectionV1(
        predecessor_set,
        predecessor_selector,
    );
    const selected = try decodeSelectionV1(
        selected_set,
        selected_selector,
    );
    try validateImmediateSuccessorV1(predecessor, selected);
    const producer = try decodeProducerContextV1(predecessor);
    if (selected.set.object_count != nonterminal_object_count and
        selected.set.object_count !=
            bound_nonterminal_object_count)
        return Error.InvalidNonterminalProgress;

    const embedded_predecessor_selector_object =
        try exactObjectV1(
            selected.set,
            0,
            .runtime_state,
            nonterminal_predecessor_selector_object_ordinal,
            checkpoint_file.selector_abi,
        );
    if (!std.mem.eql(
        u8,
        embedded_predecessor_selector_object.bytes,
        predecessor_selector,
    ))
        return Error.InvalidLineage;
    const embedded_predecessor_selector =
        try checkpoint_file.decodeSelectorV1(
            embedded_predecessor_selector_object.bytes,
        );
    if (!std.meta.eql(
        embedded_predecessor_selector,
        predecessor.selector,
    ) or !digestEqual(
        selected.selector.previous_selector_sha256,
        embedded_predecessor_selector.selector_sha256,
    ) or !digestEqual(
        selected.set.metadata.parent_checkpoint_sha256,
        embedded_predecessor_selector.checkpoint_sha256,
    ))
        return Error.InvalidLineage;

    const checkpoint_object = try exactObjectV1(
        selected.set,
        1,
        .extension,
        checkpoint_object_ordinal,
        checkpoint.checkpoint_abi,
    );
    const plan_object = try exactObjectV1(
        selected.set,
        2,
        .extension,
        successor_plan_object_ordinal,
        model_contract.execution_plan_abi,
    );
    const residency_object = try exactObjectV1(
        selected.set,
        3,
        .extension,
        successor_residency_object_ordinal,
        model_contract.execution_residency_binding_abi,
    );
    const segment_object = try exactObjectV1(
        selected.set,
        4,
        .extension,
        successor_segment_object_ordinal,
        successor.successor_segment_abi,
    );
    const manifest_object = try exactObjectV1(
        selected.set,
        5,
        .extension,
        restart_manifest_object_ordinal,
        restart_manifest.manifest_abi,
    );
    const acknowledgement_object = try exactObjectV1(
        selected.set,
        6,
        .extension,
        acknowledgement_object_ordinal,
        result_sink.acknowledgement_abi,
    );
    const selected_input_archive: ?input_archive.DecodedV1 =
        if (selected.set.object_count ==
        bound_nonterminal_object_count)
            try input_archive.decodeV1(
                (try exactObjectV1(
                    selected.set,
                    7,
                    .extension,
                    input_archive_object_ordinal,
                    input_archive.archive_abi,
                )).bytes,
            )
        else
            null;

    const manifest = try restart_manifest.decodeV1(
        manifest_object.bytes,
    );
    if (selected_input_archive) |input_context|
        try input_archive.verifyCurrentPlanV1(
            input_context,
            manifest.plan,
            manifest.bound_plan,
        );
    try validateProducerLineageV1(
        producer,
        manifest,
        selected_input_archive,
    );
    const decoded_checkpoint =
        try checkpoint.decodeCheckpointV1(
            checkpoint_object.bytes,
            manifest.expected_checkpoint,
        );
    const artifacts =
        try successor.decodeAndVerifyForCheckpointV1(
            plan_object.bytes,
            residency_object.bytes,
            segment_object.bytes,
            checkpoint_object.bytes,
            manifest.expected_checkpoint,
            manifest.source,
            manifest.target,
        );
    const acknowledgement =
        try result_sink.decodeAcknowledgementV1(
            acknowledgement_object.bytes,
        );
    try validateAcknowledgementEdgeV1(
        predecessor,
        producer,
        acknowledgement,
    );
    try validateNonterminalPayloadV1(
        predecessor,
        selected.set,
        decoded_checkpoint,
        acknowledgement,
    );
    if (artifacts.segment.request_epoch !=
        selected.selector.request_epoch or
        artifacts.segment.sequence_base !=
            selected.selector.publication_next_sequence or
        !digestEqual(
            artifacts.segment.challenge_sha256,
            selected.selector.challenge_sha256,
        ))
        return Error.InvalidNonterminalProgress;

    return .{
        .predecessor = predecessor,
        .selected = selected,
        .producer_target = producer.manifest.target,
        .manifest = manifest,
        .checkpoint = decoded_checkpoint,
        .artifacts = artifacts,
        .acknowledgement = acknowledgement,
        .input_archive = selected_input_archive,
    };
}

pub const DecodedProducerContextV1 = struct {
    manifest: restart_manifest.DecodedV1,
    artifacts: successor.ArtifactsV1,
    checkpoint: checkpoint.DecodedV1,
    source_recovery_contract: ?source_recovery.DecodedV1 = null,
    input_archive: ?input_archive.DecodedV1 = null,
};

/// Recover the plan and ownership that produced the immediate predecessor.
/// Generation two is the durable source-exit archive; every later generation
/// is an acknowledged nonterminal set whose manifest remains at object five.
/// This decoder performs no allocation, I/O, or mutation. Returned decoded
/// views may borrow bytes owned by `predecessor`.
pub fn decodeProducerContextV1(
    predecessor: DecodedSelectionV1,
) Error!DecodedProducerContextV1 {
    if (predecessor.selector.generation ==
        minimum_predecessor_generation)
    {
        const source_exited =
            try durable_handoff.decodeSourceExitedSetV1(
                predecessor.encoded_set,
                predecessor.selector,
                predecessor.set.metadata
                    .parent_checkpoint_sha256,
            );
        return .{
            .manifest = source_exited.evidence.manifest,
            .artifacts = source_exited.evidence.artifacts,
            .checkpoint = source_exited.evidence.checkpoint,
            .source_recovery_contract = source_exited.source_recovery_contract,
            .input_archive = source_exited.input_archive,
        };
    }
    if (predecessor.set.object_count != nonterminal_object_count and
        predecessor.set.object_count !=
            bound_nonterminal_object_count)
        return Error.InvalidLineage;

    const embedded_selector_object = try exactObjectV1(
        predecessor.set,
        0,
        .runtime_state,
        nonterminal_predecessor_selector_object_ordinal,
        checkpoint_file.selector_abi,
    );
    const embedded_selector =
        try checkpoint_file.decodeSelectorV1(
            embedded_selector_object.bytes,
        );
    const expected_generation = std.math.add(
        u64,
        embedded_selector.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const expected_sequence = std.math.add(
        u64,
        embedded_selector.publication_next_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (predecessor.selector.generation != expected_generation or
        predecessor.selector.request_epoch !=
            embedded_selector.request_epoch or
        predecessor.selector.publication_next_sequence !=
            expected_sequence or
        !digestEqual(
            predecessor.selector.previous_selector_sha256,
            embedded_selector.selector_sha256,
        ) or !digestEqual(
        predecessor.set.metadata.parent_checkpoint_sha256,
        embedded_selector.checkpoint_sha256,
    ) or !digestEqual(
        predecessor.selector.challenge_sha256,
        embedded_selector.challenge_sha256,
    ))
        return Error.InvalidLineage;

    const checkpoint_object = try exactObjectV1(
        predecessor.set,
        1,
        .extension,
        checkpoint_object_ordinal,
        checkpoint.checkpoint_abi,
    );
    const plan_object = try exactObjectV1(
        predecessor.set,
        2,
        .extension,
        successor_plan_object_ordinal,
        model_contract.execution_plan_abi,
    );
    const residency_object = try exactObjectV1(
        predecessor.set,
        3,
        .extension,
        successor_residency_object_ordinal,
        model_contract.execution_residency_binding_abi,
    );
    const segment_object = try exactObjectV1(
        predecessor.set,
        4,
        .extension,
        successor_segment_object_ordinal,
        successor.successor_segment_abi,
    );
    const manifest_object = try exactObjectV1(
        predecessor.set,
        5,
        .extension,
        restart_manifest_object_ordinal,
        restart_manifest.manifest_abi,
    );
    const manifest = try restart_manifest.decodeV1(
        manifest_object.bytes,
    );
    const producer_input_archive: ?input_archive.DecodedV1 =
        if (predecessor.set.object_count ==
        bound_nonterminal_object_count)
            try input_archive.decodeV1(
                (try exactObjectV1(
                    predecessor.set,
                    7,
                    .extension,
                    input_archive_object_ordinal,
                    input_archive.archive_abi,
                )).bytes,
            )
        else
            null;
    if (producer_input_archive) |input_context|
        try input_archive.verifyCurrentPlanV1(
            input_context,
            manifest.plan,
            manifest.bound_plan,
        );
    const decoded_checkpoint =
        try checkpoint.decodeCheckpointV1(
            checkpoint_object.bytes,
            manifest.expected_checkpoint,
        );
    const artifacts =
        try successor.decodeAndVerifyForCheckpointV1(
            plan_object.bytes,
            residency_object.bytes,
            segment_object.bytes,
            checkpoint_object.bytes,
            manifest.expected_checkpoint,
            manifest.source,
            manifest.target,
        );
    if (predecessor.set.metadata.request_epoch !=
        decoded_checkpoint.request_epoch or
        predecessor.set.metadata.publication_next_sequence !=
            decoded_checkpoint.publication_next_sequence or
        !digestEqual(
            predecessor.set.metadata.challenge_sha256,
            decoded_checkpoint.challenge_sha256,
        ) or artifacts.segment.request_epoch !=
        predecessor.selector.request_epoch or
        artifacts.segment.sequence_base !=
            predecessor.selector.publication_next_sequence or
        !digestEqual(
            artifacts.segment.challenge_sha256,
            predecessor.selector.challenge_sha256,
        ))
        return Error.InvalidLineage;
    return .{
        .manifest = manifest,
        .artifacts = artifacts,
        .checkpoint = decoded_checkpoint,
        .input_archive = producer_input_archive,
    };
}

fn validateProducerLineageV1(
    producer: DecodedProducerContextV1,
    selected_manifest: restart_manifest.DecodedV1,
    selected_input_archive: ?input_archive.DecodedV1,
) Error!void {
    const producer_target = producer.manifest.target;
    const expected_bound_plan =
        session.deriveSuccessorBoundPlanV1(
            producer.manifest.bound_plan,
            producer.artifacts,
        ) catch return Error.InvalidLineage;
    if (selected_manifest.source.receipt.bank_epoch !=
        producer_target.bank_epoch or
        selected_manifest.source.receipt.owner_key !=
            producer_target.resource_owner_key or
        !std.meta.eql(
            selected_manifest.source.receipt.claim,
            producer_target.request_claim,
        ) or !std.meta.eql(
        selected_manifest.bound_plan,
        expected_bound_plan,
    ) or !std.meta.eql(
        selected_manifest.source.execution,
        producer.artifacts.successor_plan,
    ) or !std.meta.eql(
        selected_manifest.source.residency,
        producer.artifacts.successor_residency,
    ))
        return Error.InvalidLineage;

    if ((producer.input_archive == null) !=
        (selected_input_archive == null))
        return Error.InvalidLineage;
    if (producer.input_archive) |producer_input| {
        const selected_input = selected_input_archive orelse
            return Error.InvalidLineage;
        if (!digestEqual(
            producer_input.archive_sha256,
            selected_input.archive_sha256,
        ) or !std.mem.eql(
            u8,
            producer_input.encoded,
            selected_input.encoded,
        ))
            return Error.InvalidLineage;
    }
}

pub fn encodedTerminalBytesV1(
    predecessor_set_bytes: usize,
    output_bytes: usize,
) Error!usize {
    if (output_bytes == 0 or
        output_bytes % @sizeOf(u32) != 0 or
        output_bytes / @sizeOf(u32) >
            maximum_terminal_output_tokens)
        return Error.InvalidTerminalProgress;
    var total = std.math.add(
        usize,
        checkpoint_file.set_payload_offset +
            checkpoint_file.set_footer_bytes,
        checkpoint_file.selector_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(
        usize,
        total,
        predecessor_set_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(
        usize,
        total,
        terminal_semantic.semantic_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(
        usize,
        total,
        result_sink.acknowledgement_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        total,
        output_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Encode a terminal semantic, final acknowledgement, and complete immediate
/// predecessor pair in one bounded five-object generation. The full output is
/// carried as canonical little-endian u32 token ids.
pub fn encodeTerminalV1(
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    encoded_semantic: []const u8,
    encoded_acknowledgement: []const u8,
    canonical_output_u32_le: []const u8,
    destination: []u8,
) Error!PreparedTerminalV1 {
    const predecessor = try decodeSelectionV1(
        predecessor_set,
        predecessor_selector,
    );
    if (predecessor.selector.generation <
        minimum_predecessor_generation)
        return Error.InvalidLineage;
    const semantic = try terminal_semantic.decodeV1(
        encoded_semantic,
    );
    const acknowledgement =
        try result_sink.decodeAcknowledgementV1(
            encoded_acknowledgement,
        );
    const producer = try decodeProducerContextV1(predecessor);
    try validateAcknowledgementEdgeV1(
        predecessor,
        producer,
        acknowledgement,
    );
    try validateTerminalPayloadV1(
        predecessor,
        producer,
        semantic,
        acknowledgement,
        canonical_output_u32_le,
    );
    const next_generation = std.math.add(
        u64,
        predecessor.selector.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const next_sequence = std.math.add(
        u64,
        predecessor.selector.publication_next_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = terminal_predecessor_selector_object_ordinal,
            .abi_version = checkpoint_file.selector_abi,
            .bytes = predecessor_selector,
        },
        .{
            .kind = .extension,
            .ordinal = terminal_predecessor_set_object_ordinal,
            .abi_version = checkpoint_file.set_abi,
            .bytes = predecessor_set,
        },
        .{
            .kind = .extension,
            .ordinal = terminal_semantic_object_ordinal,
            .abi_version = terminal_semantic.semantic_abi,
            .bytes = encoded_semantic,
        },
        .{
            .kind = .extension,
            .ordinal = terminal_acknowledgement_object_ordinal,
            .abi_version = result_sink.acknowledgement_abi,
            .bytes = encoded_acknowledgement,
        },
        .{
            .kind = .extension,
            .ordinal = terminal_output_tokens_object_ordinal,
            .abi_version = terminal_output_tokens_abi,
            .bytes = canonical_output_u32_le,
        },
    };
    const set = try checkpoint_file.encodeSetV1(
        .{
            .generation = next_generation,
            .request_epoch = predecessor.selector.request_epoch,
            .publication_next_sequence = next_sequence,
            .parent_checkpoint_sha256 = predecessor.set.checkpoint_sha256,
            .challenge_sha256 = predecessor.selector.challenge_sha256,
        },
        &objects,
        destination,
    );
    return .{
        .set = set,
        .semantic = semantic,
        .acknowledgement = acknowledgement,
    };
}

/// Decode a selected terminal generation against an independently retained
/// predecessor pair.  The nested pair must be byte-identical to that anchor.
pub fn decodeTerminalV1(
    predecessor_set: []const u8,
    predecessor_selector: []const u8,
    selected_set: []const u8,
    selected_selector: []const u8,
) Error!DecodedTerminalV1 {
    const predecessor = try decodeSelectionV1(
        predecessor_set,
        predecessor_selector,
    );
    const selected = try decodeSelectionV1(
        selected_set,
        selected_selector,
    );
    try validateImmediateSuccessorV1(predecessor, selected);
    if (selected.set.object_count != terminal_object_count)
        return Error.InvalidTerminalProgress;

    const predecessor_selector_object = try exactObjectV1(
        selected.set,
        0,
        .extension,
        terminal_predecessor_selector_object_ordinal,
        checkpoint_file.selector_abi,
    );
    const predecessor_set_object = try exactObjectV1(
        selected.set,
        1,
        .extension,
        terminal_predecessor_set_object_ordinal,
        checkpoint_file.set_abi,
    );
    const semantic_object = try exactObjectV1(
        selected.set,
        2,
        .extension,
        terminal_semantic_object_ordinal,
        terminal_semantic.semantic_abi,
    );
    const acknowledgement_object = try exactObjectV1(
        selected.set,
        3,
        .extension,
        terminal_acknowledgement_object_ordinal,
        result_sink.acknowledgement_abi,
    );
    const output_tokens_object = try exactObjectV1(
        selected.set,
        4,
        .extension,
        terminal_output_tokens_object_ordinal,
        terminal_output_tokens_abi,
    );
    if (!std.mem.eql(
        u8,
        predecessor_selector_object.bytes,
        predecessor_selector,
    ) or !std.mem.eql(
        u8,
        predecessor_set_object.bytes,
        predecessor_set,
    ))
        return Error.InvalidLineage;
    const nested_predecessor = try decodeSelectionV1(
        predecessor_set_object.bytes,
        predecessor_selector_object.bytes,
    );
    if (!std.meta.eql(
        nested_predecessor.selector,
        predecessor.selector,
    ) or !digestEqual(
        nested_predecessor.set.checkpoint_sha256,
        predecessor.set.checkpoint_sha256,
    ))
        return Error.InvalidLineage;

    const semantic = try terminal_semantic.decodeV1(
        semantic_object.bytes,
    );
    const acknowledgement =
        try result_sink.decodeAcknowledgementV1(
            acknowledgement_object.bytes,
        );
    const producer = try decodeProducerContextV1(predecessor);
    try validateAcknowledgementEdgeV1(
        predecessor,
        producer,
        acknowledgement,
    );
    try validateTerminalPayloadV1(
        predecessor,
        producer,
        semantic,
        acknowledgement,
        output_tokens_object.bytes,
    );
    return .{
        .predecessor = predecessor,
        .selected = selected,
        .semantic = semantic,
        .acknowledgement = acknowledgement,
        .canonical_output_u32_le = output_tokens_object.bytes,
    };
}

fn validateNonterminalPayloadV1(
    predecessor: DecodedSelectionV1,
    selected_set: checkpoint_file.DecodedSetV1,
    decoded_checkpoint: checkpoint.DecodedV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
) Error!void {
    const next_sequence = std.math.add(
        u64,
        predecessor.selector.publication_next_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (selected_set.metadata.request_epoch !=
        predecessor.selector.request_epoch or
        selected_set.metadata.publication_next_sequence !=
            next_sequence or
        selected_set.metadata.generation !=
            predecessor.selector.generation + 1 or
        !digestEqual(
            selected_set.metadata.parent_checkpoint_sha256,
            predecessor.set.checkpoint_sha256,
        ) or !digestEqual(
        selected_set.metadata.challenge_sha256,
        predecessor.selector.challenge_sha256,
    ) or decoded_checkpoint.request_epoch !=
        predecessor.selector.request_epoch or
        decoded_checkpoint.publication_next_sequence !=
            next_sequence or
        decoded_checkpoint.output_count == 0 or
        decoded_checkpoint.output_count != next_sequence or
        decoded_checkpoint.canonical_output_u32_le.len <
            @sizeOf(u32) or
        lastTokenV1(decoded_checkpoint) !=
            acknowledgement.token_id)
        return Error.InvalidNonterminalProgress;
}

fn validateTerminalPayloadV1(
    predecessor: DecodedSelectionV1,
    producer: DecodedProducerContextV1,
    semantic: terminal_semantic.TerminalSemanticV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
    canonical_output_u32_le: []const u8,
) Error!void {
    const next_sequence = std.math.add(
        u64,
        predecessor.selector.publication_next_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (semantic.request_epoch !=
        predecessor.selector.request_epoch or
        semantic.publication_next_sequence != next_sequence or
        semantic.output_length != next_sequence or
        semantic.sampling_calls != next_sequence or
        acknowledgement.request_epoch != semantic.request_epoch)
        return Error.InvalidTerminalProgress;

    const output_bytes = std.math.cast(
        usize,
        semantic.output_bytes,
    ) orelse return Error.InvalidTerminalProgress;
    const output_length = std.math.cast(
        usize,
        semantic.output_length,
    ) orelse return Error.InvalidTerminalProgress;
    if (output_length == 0 or
        output_length > maximum_terminal_output_tokens or
        output_bytes != canonical_output_u32_le.len or
        output_bytes != output_length * @sizeOf(u32))
        return Error.InvalidTerminalProgress;

    var output_tokens: [maximum_terminal_output_tokens]u32 = undefined;
    for (output_tokens[0..output_length], 0..) |
        *token,
        index,
    | {
        const offset = index * @sizeOf(u32);
        token.* = std.mem.readInt(
            u32,
            canonical_output_u32_le[offset..][0..4],
            .little,
        );
    }
    if (output_tokens[output_length - 1] !=
        acknowledgement.token_id)
        return Error.InvalidTerminalProgress;

    const manifest = producer.manifest;
    if (!digestEqual(
        semantic.local_plan_sha256,
        manifest.plan.plan_sha256,
    ) or !digestEqual(
        semantic.artifact_sha256,
        manifest.bound_plan.artifact.artifact_sha256,
    ) or !digestEqual(
        semantic.token_domain_sha256,
        manifest.bound_plan.token_domain_sha256,
    ) or !digestEqual(
        semantic.token_domain_config_sha256,
        manifest.bound_plan.token_domain_config_sha256,
    ) or !digestEqual(
        semantic.image_container_sha256,
        manifest.plan.image_identity.container_sha256,
    ) or !digestEqual(
        semantic.prompt_sha256,
        manifest.plan.prompt_sha256,
    ) or semantic.prompt_tokens != manifest.plan.prompt_tokens or
        semantic.max_new_tokens != manifest.plan.max_new_tokens or
        !digestEqual(
            semantic.output_sha256,
            terminal_semantic.outputSemanticRootV1(
                manifest.bound_plan,
                output_tokens[0..output_length],
            ),
        ))
        return Error.InvalidTerminalProgress;
}

fn validateAcknowledgementEdgeV1(
    predecessor: DecodedSelectionV1,
    producer: DecodedProducerContextV1,
    acknowledgement: result_sink.ResultAcknowledgementV1,
) Error!void {
    try result_sink.validateAcknowledgementV1(
        acknowledgement,
    );
    if (acknowledgement.request_epoch !=
        predecessor.selector.request_epoch or
        acknowledgement.transaction_sequence !=
            predecessor.selector.publication_next_sequence or
        acknowledgement.application_count != 1 or
        !digestEqual(
            acknowledgement.request_sha256,
            producer.manifest.plan.plan_sha256,
        ))
        return Error.InvalidAcknowledgement;

    const previous = try progressAcknowledgementV1(
        predecessor,
        producer.checkpoint,
    );
    if (previous) |value| {
        const expected_ordinal = std.math.add(
            u64,
            value.application_ordinal,
            1,
        ) catch return Error.ArithmeticOverflow;
        if (acknowledgement.application_ordinal !=
            expected_ordinal or
            !digestEqual(
                acknowledgement.request_sha256,
                value.request_sha256,
            ) or !digestEqual(
            acknowledgement.sink_implementation_sha256,
            value.sink_implementation_sha256,
        ) or !digestEqual(
            acknowledgement.sink_instance_sha256,
            value.sink_instance_sha256,
        ) or
            !digestEqual(
                acknowledgement.predecessor_acknowledgement_sha256,
                value.acknowledgement_sha256,
            ) or !digestEqual(
            acknowledgement.predecessor_sink_prefix_sha256,
            value.result_sink_prefix_sha256,
        ))
            return Error.InvalidAcknowledgement;
    } else {
        if (acknowledgement.application_ordinal != 1 or
            !isZero(
                acknowledgement.predecessor_acknowledgement_sha256,
            ) or !isZero(
            acknowledgement.predecessor_sink_prefix_sha256,
        ))
            return Error.InvalidAcknowledgement;
        if (producer.source_recovery_contract) |contract| {
            if (acknowledgement.transaction_sequence !=
                contract.sink.initial_sequence or
                !digestEqual(
                    acknowledgement.sink_implementation_sha256,
                    contract.sink.implementation_sha256,
                ) or !digestEqual(
                acknowledgement.sink_instance_sha256,
                contract.sink.instance_sha256,
            ))
                return Error.InvalidAcknowledgement;
        }
    }
}

fn progressAcknowledgementV1(
    predecessor: DecodedSelectionV1,
    predecessor_checkpoint: checkpoint.DecodedV1,
) Error!?result_sink.ResultAcknowledgementV1 {
    if (predecessor.selector.generation ==
        minimum_predecessor_generation)
        return null;
    if (predecessor.set.object_count != nonterminal_object_count and
        predecessor.set.object_count !=
            bound_nonterminal_object_count)
        return Error.InvalidLineage;
    const object = try exactObjectV1(
        predecessor.set,
        6,
        .extension,
        acknowledgement_object_ordinal,
        result_sink.acknowledgement_abi,
    );
    const acknowledgement =
        try result_sink.decodeAcknowledgementV1(object.bytes);
    const expected_next = std.math.add(
        u64,
        acknowledgement.transaction_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (acknowledgement.request_epoch !=
        predecessor.selector.request_epoch or
        expected_next !=
            predecessor.selector.publication_next_sequence or
        predecessor_checkpoint.output_count == 0 or
        predecessor_checkpoint.canonical_output_u32_le.len <
            @sizeOf(u32) or
        acknowledgement.token_id !=
            lastTokenV1(predecessor_checkpoint))
        return Error.InvalidLineage;
    return acknowledgement;
}

fn exactObjectV1(
    set: checkpoint_file.DecodedSetV1,
    index: usize,
    kind: checkpoint_file.ObjectKindV1,
    ordinal: u64,
    abi_version: u64,
) Error!checkpoint_file.ObjectViewV1 {
    if (index >= set.object_count)
        return Error.InvalidSelection;
    const object = set.objects[index];
    if (object.kind != kind or
        object.ordinal != ordinal or
        object.abi_version != abi_version)
        return Error.InvalidSelection;
    return object;
}

fn inputFromView(
    view: checkpoint_file.ObjectViewV1,
) checkpoint_file.ObjectInputV1 {
    return .{
        .kind = view.kind,
        .ordinal = view.ordinal,
        .abi_version = view.abi_version,
        .bytes = view.bytes,
    };
}

fn lastTokenV1(decoded: checkpoint.DecodedV1) u32 {
    const offset =
        decoded.canonical_output_u32_le.len - @sizeOf(u32);
    return std.mem.readInt(
        u32,
        decoded.canonical_output_u32_le[offset..][0..4],
        .little,
    );
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}

test "bound nonterminal sizing keeps legacy overhead" {
    const embedded_bytes: usize = 4096;
    try std.testing.expectEqual(
        try encodedNonterminalBytesV1(embedded_bytes),
        try encodedBoundNonterminalBytesV1(embedded_bytes),
    );

    var destination = [_]u8{0xa5} ** 32;
    if (encodeBoundNonterminalV1(
        &.{},
        &.{},
        &.{},
        &.{},
        &destination,
    )) |_| {
        return error.ExpectedFailure;
    } else |_| {}
    try std.testing.expect(std.mem.allEqual(
        u8,
        &destination,
        0xa5,
    ));
}

const TestFixture = struct {
    allocator: std.mem.Allocator,
    request_epoch: u64,
    challenge_sha256: Digest,
    predecessor_set: []u8,
    predecessor_selector: [checkpoint_file.selector_bytes]u8,
    restart_archive: []u8,
    first_acknowledgement: result_sink.ResultAcknowledgementV1,
    first_acknowledgement_wire: [result_sink.acknowledgement_bytes]u8,
    final_acknowledgement: result_sink.ResultAcknowledgementV1,
    final_acknowledgement_wire: [result_sink.acknowledgement_bytes]u8,
    terminal_semantic: terminal_semantic.TerminalSemanticV1,
    terminal_semantic_wire: [terminal_semantic.semantic_bytes]u8,
    terminal_output_u32_le: [4 * @sizeOf(u32)]u8,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        const request_epoch: u64 = 0x0102_0304_0506_0708;
        const challenge_sha256 = filledDigest(0xcc);
        const prompt = [_]u32{ 5, 7, 11 };
        const options: session.OptionsV1 = .{
            .max_new_tokens = 4,
            .eos_token = std.math.maxInt(u32),
            .seed = 0x1020_3040_5060_7080,
        };
        const request_claim: resource_bank.Claim = .{
            .capsule_bytes = 64,
            .kv_bytes = 192,
            .activation_bytes = 12,
            .partial_bytes = 64,
            .logits_bytes = 1024,
            .output_journal_bytes = 16,
            .staging_bytes = 32,
            .queue_slots = 1,
        };
        const total_claim: resource_bank.Claim = .{
            .capsule_bytes = 4160,
            .kv_bytes = request_claim.kv_bytes,
            .activation_bytes = request_claim.activation_bytes,
            .partial_bytes = request_claim.partial_bytes,
            .logits_bytes = request_claim.logits_bytes,
            .output_journal_bytes = request_claim.output_journal_bytes,
            .staging_bytes = request_claim.staging_bytes,
            .queue_slots = request_claim.queue_slots,
        };
        var plan: session.PlanV1 = .{
            .image_identity = .{
                .source_fingerprint = filledDigest(0x51),
                .abi_fingerprint = filledDigest(0x52),
                .container_bytes = 4096,
                .container_sha256 = filledDigest(0x41),
            },
            .prompt_tokens = prompt.len,
            .prompt_sha256 = testPromptRootV1(&prompt),
            .max_new_tokens = options.max_new_tokens,
            .eos_token = options.eos_token,
            .seed = options.seed,
            .claim = request_claim,
            .plan_sha256 = [_]u8{0} ** 32,
        };
        plan.plan_sha256 = testPlanRootV1(plan);

        const artifact =
            try model_contract.makeArtifactManifestFromDigestV1(
                .autoregressive,
                session.prepared_artifact_profile_abi,
                .token_ids,
                .token_ids,
                .implementation_defined,
                1,
                prompt.len,
                options.max_new_tokens,
                @sizeOf(u32),
                @sizeOf(u32),
                1,
                plan.image_identity.container_bytes,
                plan.image_identity.container_sha256,
                filledDigest(0x42),
                filledDigest(0x43),
            );
        const initial_execution =
            try model_contract.makeExecutionPlanV1(
                artifact,
                .generate_sequence,
                .{
                    .request_epoch = request_epoch,
                    .generation = 7,
                    .batch_items = 1,
                    .publication_next_sequence = 0,
                    .maximum_absolute_output = 255,
                    .claim = total_claim,
                    .media_object_sha256 = plan.prompt_sha256,
                    .processor_state_sha256 = filledDigest(0x53),
                    .processor_bundle_sha256 = filledDigest(0x54),
                    .cache_bundle_sha256 = filledDigest(0x34),
                    .cache_payload_sha256 = filledDigest(0x35),
                    .ownership_sha256 = filledDigest(0x36),
                    .challenge_sha256 = challenge_sha256,
                    .previous_plan_sha256 = [_]u8{0} ** 32,
                    .input_schema_sha256 = filledDigest(0x37),
                    .output_schema_sha256 = filledDigest(0x38),
                    .scratch_bytes = request_claim.partial_bytes,
                },
            );
        const initial_residency =
            try model_contract.makeExecutionResidencyBindingV1(
                initial_execution,
                .shared_read_only,
                plan.image_identity.container_bytes,
                request_claim,
            );
        var initial_bound_plan: session.BoundPlanV1 = .{
            .local_plan_sha256 = plan.plan_sha256,
            .artifact = artifact,
            .execution = initial_execution,
            .residency = initial_residency,
            .token_domain_sha256 = filledDigest(0x53),
            .token_domain_config_sha256 = filledDigest(0x54),
            .artifact_license_sha256 = filledDigest(0x43),
            .bound_plan_sha256 = [_]u8{0} ** 32,
        };
        initial_bound_plan.bound_plan_sha256 =
            session.boundPlanRootV1(initial_bound_plan);
        try session.validateBoundPlanV1(initial_bound_plan);

        var initial_slots = [_]resource_bank.Slot{.{}};
        var initial_bank = try resource_bank.Bank.init(
            &initial_slots,
            .{
                .host_bytes = 1 << 20,
                .capsule_bytes = 1 << 20,
                .kv_bytes = 1 << 20,
                .activation_bytes = 1 << 20,
                .partial_bytes = 1 << 20,
                .logits_bytes = 1 << 20,
                .output_journal_bytes = 1 << 20,
                .staging_bytes = 1 << 20,
                .device_bytes = 1 << 20,
                .io_bytes = 1 << 20,
                .queue_slots = 4,
            },
            41,
        );
        const initial_receipt = try initial_bank.commit(
            try initial_bank.reserve(1001, request_claim),
        );

        const rng_state: lane_contiguous.RngState = .{
            0x0102_0304_0506_0708,
            0x1112_1314_1516_1718,
            0x2122_2324_2526_2728,
            0x3132_3334_3536_3738,
        };
        var initial_cache =
            try kv.KVCache.init(allocator, 2, 2, 6);
        defer initial_cache.deinit();
        try testFillCacheV1(&initial_cache, 4);
        const initial_output_tokens = [_]u32{ 17, 29 };
        const initial_state = publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            4,
            try checkpoint.incrementalKvStateRootV1(
                &initial_cache,
                3,
            ),
            lane_contiguous.rng_state_abi,
            lane_contiguous.rngStateSha256(rng_state),
            2,
            2,
            lane_contiguous.outputStateSha256(
                &initial_output_tokens,
                false,
            ),
        );
        const initial_transcript_sha256 = filledDigest(0x75);
        const initial_boundary_sha256 = filledDigest(0x65);
        const initial_expected_checkpoint: checkpoint.ExpectedBindingsV1 = .{
            .local_plan_sha256 = plan.plan_sha256,
            .bound_plan_sha256 = initial_bound_plan.bound_plan_sha256,
            .artifact_sha256 = artifact.artifact_sha256,
            .execution_plan_sha256 = initial_execution.plan_sha256,
            .residency_binding_sha256 = initial_residency.binding_sha256,
            .boundary_sha256 = initial_boundary_sha256,
            .transcript_sha256 = initial_transcript_sha256,
            .state_commitment_sha256 = initial_state.commitment_sha256,
            .request_epoch = request_epoch,
            .publication_next_sequence = 2,
            .prompt_tokens = prompt.len,
            .max_new_tokens = options.max_new_tokens,
            .vocab_size = 256,
            .num_layers = 2,
            .kv_dim = 2,
            .max_kv_positions = 6,
            .kv_positions = 4,
            .output_count = 2,
            .sampling_calls = 2,
            .challenge_sha256 = challenge_sha256,
        };
        const initial_checkpoint_bytes =
            try checkpoint.encodedCheckpointBytesV1(
                2,
                2,
                4,
                initial_output_tokens.len,
            );
        const encoded_initial_checkpoint =
            try allocator.alloc(u8, initial_checkpoint_bytes);
        defer allocator.free(encoded_initial_checkpoint);
        _ = try checkpoint.encodeCheckpointV1(
            .{
                .local_plan_sha256 = plan.plan_sha256,
                .bound_plan_sha256 = initial_bound_plan.bound_plan_sha256,
                .artifact_sha256 = artifact.artifact_sha256,
                .execution_plan_sha256 = initial_execution.plan_sha256,
                .residency_binding_sha256 = initial_residency.binding_sha256,
                .boundary_sha256 = initial_boundary_sha256,
                .transcript_sha256 = initial_transcript_sha256,
                .state_commitment_sha256 = initial_state.commitment_sha256,
                .request_epoch = request_epoch,
                .publication_next_sequence = 2,
                .prompt_tokens = prompt.len,
                .max_new_tokens = options.max_new_tokens,
                .vocab_size = 256,
                .output_tokens = &initial_output_tokens,
                .rng_state = rng_state,
                .sampling_calls = 2,
                .cache = &initial_cache,
                .challenge_sha256 = challenge_sha256,
            },
            encoded_initial_checkpoint,
        );
        const initial_source: successor.SourceContextV1 = .{
            .bound_plan_sha256 = initial_bound_plan.bound_plan_sha256,
            .execution = initial_execution,
            .residency = initial_residency,
            .boundary_sha256 = initial_boundary_sha256,
            .publication = .{
                .request_epoch = request_epoch,
                .execution_abi = lane_contiguous.abi,
                .sequence_base = 0,
                .next_sequence = 2,
                .last_resource_permit_generation = 19,
                .terminal = false,
                .state = initial_state,
                .transcript_sha256 = initial_transcript_sha256,
            },
            .receipt = initial_receipt,
        };
        const initial_target: successor.TargetOwnershipV1 = .{
            .scheduler_epoch = 51,
            .coordinator_id = 52,
            .bank_epoch = 42,
            .request_generation = 8,
            .resource_owner_key = 2001,
            .tree_key = 2002,
            .authority_key = 2003,
            .tenant_key = 2004,
            .scope_key = 2005,
            .cache_node_key = 2006,
            .cache_binding_key = 2007,
            .intent_generation = 8,
            .request_claim = request_claim,
        };
        const manifest_bytes =
            try restart_manifest.encodedBytesV1(prompt.len);
        const encoded_initial_manifest =
            try allocator.alloc(u8, manifest_bytes);
        defer allocator.free(encoded_initial_manifest);
        _ = try restart_manifest.encodeV1(
            .{
                .prompt = &prompt,
                .options = options,
                .plan = plan,
                .bound_plan = initial_bound_plan,
                .expected_checkpoint = initial_expected_checkpoint,
                .source = initial_source,
                .target = initial_target,
            },
            encoded_initial_manifest,
        );
        const evidence_bytes =
            try archive.encodedRestartArchiveBytesV1(
                encoded_initial_checkpoint.len,
                encoded_initial_manifest.len,
            );
        const encoded_evidence =
            try allocator.alloc(u8, evidence_bytes);
        defer allocator.free(encoded_evidence);
        const evidence = try archive.encodeRestartArchiveV1(
            1,
            [_]u8{0} ** 32,
            encoded_initial_checkpoint,
            encoded_initial_manifest,
            encoded_evidence,
        );

        const previous_selector_sha256 = filledDigest(0xa2);
        const source_handle: lane.Handle = .{
            .scheduler_epoch = 51,
            .slot_index = initial_receipt.slot_index,
            .slot_generation = initial_receipt.generation,
            .tenant_key = 701,
            .request_key = 702,
            .request_generation = 7,
        };
        const source_spec: lane.RequestSpec = .{
            .tenant_key = source_handle.tenant_key,
            .request_key = source_handle.request_key,
            .request_generation = source_handle.request_generation,
            .resource_owner_key = initial_receipt.owner_key,
            .weight = 1,
            .work_quanta = options.max_new_tokens,
            .claim = request_claim,
        };
        var cancel_event: lane.EventV1 = .{
            .scheduler_epoch = source_handle.scheduler_epoch,
            .event_sequence = 23,
            .kind = .cancel,
            .previous_sha256 = filledDigest(0x71),
            .state_before_sha256 = filledDigest(0x72),
            .state_after_sha256 = filledDigest(0x73),
            .logical_tick_before = 9,
            .logical_tick_after = 9,
            .cursor_before = 0,
            .cursor_after = 0,
            .level_before = 1,
            .level_after = 1,
            .handle = source_handle,
            .spec = source_spec,
            .resource_receipt = initial_receipt,
            .resource_receipt_sha256 = lane.resourceReceiptSha256(initial_receipt),
            .remaining_before = 2,
            .remaining_after = 0,
            .maximum_service_gap = 4,
            .active_before = 1,
            .active_after = 0,
            .finished_before = 0,
            .finished_after = 0,
            .bank_used_before = request_claim,
            .bank_used_after = .{},
        };
        cancel_event.event_sha256 =
            lane.eventSha256(cancel_event);
        var source_exit: lane.SourceExitReceiptV1 = .{
            .scheduler_epoch = source_handle.scheduler_epoch,
            .coordinator_id = 52,
            .handoff_generation = 1,
            .handle = source_handle,
            .publication_request_epoch = request_epoch,
            .expected_next_sequence = 2,
            .source_last_publication_permit_generation = 19,
            .source_receipt = initial_receipt,
            .source_receipt_sha256 = lane.resourceReceiptSha256(initial_receipt),
            .scheduler_chain_head_before_sha256 = cancel_event.previous_sha256,
            .checkpoint_sha256 = evidence.artifacts.segment
                .source_checkpoint_sha256,
            .successor_segment_sha256 = evidence.artifacts.segment.segment_sha256,
            .target_ownership_intent_sha256 = evidence.artifacts.segment
                .ownership_intent_sha256,
            .prepared_archive_sha256 = evidence.set.checkpoint_sha256,
            .predecessor_selector_sha256 = previous_selector_sha256,
            .cancel_event_sequence = cancel_event.event_sequence,
            .cancel_event_sha256 = cancel_event.event_sha256,
        };
        source_exit.source_exit_sha256 =
            lane.sourceExitReceiptSha256(source_exit);
        const source_exit_commit: lane.SourceExitCommitV1 = .{
            .event = cancel_event,
            .receipt = source_exit,
        };
        try std.testing.expect(
            lane.sourceExitReceiptValidV1(
                source_exit,
                cancel_event,
            ),
        );
        const predecessor_bytes =
            try durable_handoff.encodedSourceExitedSetBytesV1(
                evidence.set.bytes.len,
            );
        const predecessor_set =
            try allocator.alloc(u8, predecessor_bytes);
        errdefer allocator.free(predecessor_set);
        const prepared_predecessor =
            try durable_handoff.encodeSourceExitedSetV1(
                evidence,
                source_exit_commit,
                filledDigest(0xa1),
                predecessor_set,
            );
        const predecessor_selector = try testSelectorForSetV1(
            previous_selector_sha256,
            predecessor_set,
        );

        const bound_plan =
            try session.deriveSuccessorBoundPlanV1(
                initial_bound_plan,
                evidence.artifacts,
            );
        const source_execution = bound_plan.execution;
        const source_residency = bound_plan.residency;
        var target_slots = [_]resource_bank.Slot{.{}};
        var target_bank = try resource_bank.Bank.init(
            &target_slots,
            .{
                .host_bytes = 1 << 20,
                .capsule_bytes = 1 << 20,
                .kv_bytes = 1 << 20,
                .activation_bytes = 1 << 20,
                .partial_bytes = 1 << 20,
                .logits_bytes = 1 << 20,
                .output_journal_bytes = 1 << 20,
                .staging_bytes = 1 << 20,
                .device_bytes = 1 << 20,
                .io_bytes = 1 << 20,
                .queue_slots = 4,
            },
            initial_target.bank_epoch,
        );
        const receipt = try target_bank.commit(
            try target_bank.reserve(
                initial_target.resource_owner_key,
                request_claim,
            ),
        );

        var cache = try kv.KVCache.init(allocator, 2, 2, 6);
        defer cache.deinit();
        try testFillCacheV1(&cache, 5);
        const output_tokens = [_]u32{ 17, 29, 31 };
        const state = publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            5,
            try checkpoint.incrementalKvStateRootV1(
                &cache,
                prompt.len,
            ),
            lane_contiguous.rng_state_abi,
            lane_contiguous.rngStateSha256(rng_state),
            3,
            3,
            lane_contiguous.outputStateSha256(
                &output_tokens,
                false,
            ),
        );
        const transcript_sha256 = filledDigest(0x77);
        const boundary_sha256 = filledDigest(0x66);
        const expected_checkpoint: checkpoint.ExpectedBindingsV1 = .{
            .local_plan_sha256 = plan.plan_sha256,
            .bound_plan_sha256 = bound_plan.bound_plan_sha256,
            .artifact_sha256 = artifact.artifact_sha256,
            .execution_plan_sha256 = source_execution.plan_sha256,
            .residency_binding_sha256 = source_residency.binding_sha256,
            .boundary_sha256 = boundary_sha256,
            .transcript_sha256 = transcript_sha256,
            .state_commitment_sha256 = state.commitment_sha256,
            .request_epoch = request_epoch,
            .publication_next_sequence = 3,
            .prompt_tokens = prompt.len,
            .max_new_tokens = options.max_new_tokens,
            .vocab_size = 256,
            .num_layers = 2,
            .kv_dim = 2,
            .max_kv_positions = 6,
            .kv_positions = 5,
            .output_count = 3,
            .sampling_calls = 3,
            .challenge_sha256 = challenge_sha256,
        };
        const checkpoint_bytes =
            try checkpoint.encodedCheckpointBytesV1(
                2,
                2,
                5,
                output_tokens.len,
            );
        const encoded_checkpoint =
            try allocator.alloc(u8, checkpoint_bytes);
        defer allocator.free(encoded_checkpoint);
        _ = try checkpoint.encodeCheckpointV1(
            .{
                .local_plan_sha256 = plan.plan_sha256,
                .bound_plan_sha256 = bound_plan.bound_plan_sha256,
                .artifact_sha256 = artifact.artifact_sha256,
                .execution_plan_sha256 = source_execution.plan_sha256,
                .residency_binding_sha256 = source_residency.binding_sha256,
                .boundary_sha256 = boundary_sha256,
                .transcript_sha256 = transcript_sha256,
                .state_commitment_sha256 = state.commitment_sha256,
                .request_epoch = request_epoch,
                .publication_next_sequence = 3,
                .prompt_tokens = prompt.len,
                .max_new_tokens = options.max_new_tokens,
                .vocab_size = 256,
                .output_tokens = &output_tokens,
                .rng_state = rng_state,
                .sampling_calls = 3,
                .cache = &cache,
                .challenge_sha256 = challenge_sha256,
            },
            encoded_checkpoint,
        );
        const source: successor.SourceContextV1 = .{
            .bound_plan_sha256 = bound_plan.bound_plan_sha256,
            .execution = source_execution,
            .residency = source_residency,
            .boundary_sha256 = boundary_sha256,
            .publication = .{
                .request_epoch = request_epoch,
                .execution_abi = lane_contiguous.abi,
                .sequence_base = 2,
                .next_sequence = 3,
                .last_resource_permit_generation = 29,
                .terminal = false,
                .state = state,
                .transcript_sha256 = transcript_sha256,
            },
            .receipt = receipt,
        };
        const target: successor.TargetOwnershipV1 = .{
            .scheduler_epoch = 61,
            .coordinator_id = 62,
            .bank_epoch = 43,
            .request_generation = 9,
            .resource_owner_key = 3001,
            .tree_key = 3002,
            .authority_key = 3003,
            .tenant_key = 3004,
            .scope_key = 3005,
            .cache_node_key = 3006,
            .cache_binding_key = 3007,
            .intent_generation = 9,
            .request_claim = request_claim,
        };
        const encoded_manifest =
            try allocator.alloc(u8, manifest_bytes);
        defer allocator.free(encoded_manifest);
        _ = try restart_manifest.encodeV1(
            .{
                .prompt = &prompt,
                .options = options,
                .plan = plan,
                .bound_plan = bound_plan,
                .expected_checkpoint = expected_checkpoint,
                .source = source,
                .target = target,
            },
            encoded_manifest,
        );
        const restart_bytes =
            try archive.encodedRestartArchiveBytesV1(
                encoded_checkpoint.len,
                encoded_manifest.len,
            );
        const restart_archive =
            try allocator.alloc(u8, restart_bytes);
        errdefer allocator.free(restart_archive);
        _ = try archive.encodeRestartArchiveV1(
            3,
            prepared_predecessor.checkpoint_sha256,
            encoded_checkpoint,
            encoded_manifest,
            restart_archive,
        );

        const request_sha256 = plan.plan_sha256;
        var sink = try result_sink.ResultSinkV1(2).init(
            request_sha256,
            request_epoch,
            2,
            filledDigest(0x92),
            filledDigest(0x93),
        );
        const first = try sink.apply(.{
            .request_sha256 = request_sha256,
            .request_epoch = request_epoch,
            .transaction_sequence = 2,
            .token_id = output_tokens[output_tokens.len - 1],
            .proposal_sha256 = filledDigest(0x94),
            .transition_sha256 = filledDigest(0x95),
            .commit_receipt_sha256 = filledDigest(0x96),
        });
        var first_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
        _ = try result_sink.encodeAcknowledgementV1(
            first.acknowledgement,
            &first_wire,
        );
        const final = try sink.apply(.{
            .request_sha256 = request_sha256,
            .request_epoch = request_epoch,
            .transaction_sequence = 3,
            .token_id = 37,
            .proposal_sha256 = filledDigest(0x97),
            .transition_sha256 = filledDigest(0x98),
            .commit_receipt_sha256 = filledDigest(0x99),
        });
        var final_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
        _ = try result_sink.encodeAcknowledgementV1(
            final.acknowledgement,
            &final_wire,
        );

        const terminal_output_tokens = [_]u32{
            17,
            29,
            31,
            final.acknowledgement.token_id,
        };
        const terminal_state =
            publication.makeStateCommitmentV1(
                lane_contiguous.abi,
                6,
                filledDigest(0xb1),
                lane_contiguous.rng_state_abi,
                filledDigest(0xb2),
                4,
                4,
                lane_contiguous.outputStateSha256(
                    &terminal_output_tokens,
                    true,
                ),
            );
        var semantic: terminal_semantic.TerminalSemanticV1 = .{
            .request_epoch = request_epoch,
            .publication_next_sequence = 4,
            .prompt_tokens = prompt.len,
            .max_new_tokens = options.max_new_tokens,
            .kv_position = 6,
            .sampling_calls = 4,
            .output_length = 4,
            .output_bytes = 16,
            .execution_abi = lane_contiguous.abi,
            .rng_state_abi = lane_contiguous.rng_state_abi,
            .local_plan_sha256 = plan.plan_sha256,
            .artifact_sha256 = artifact.artifact_sha256,
            .token_domain_sha256 = bound_plan.token_domain_sha256,
            .token_domain_config_sha256 = bound_plan.token_domain_config_sha256,
            .image_container_sha256 = plan.image_identity.container_sha256,
            .prompt_sha256 = plan.prompt_sha256,
            .output_sha256 = terminal_semantic.outputSemanticRootV1(
                bound_plan,
                &terminal_output_tokens,
            ),
            .logical_kv_sha256 = filledDigest(0xb5),
            .kv_state_sha256 = terminal_state.kv_state_sha256,
            .rng_state_sha256 = terminal_state.rng_state_sha256,
            .output_state_sha256 = terminal_state.output_state_sha256,
            .state_commitment_sha256 = terminal_state.commitment_sha256,
            .semantic_sha256 = undefined,
        };
        semantic.semantic_sha256 =
            terminal_semantic.semanticRootV1(semantic);
        try terminal_semantic.validateV1(semantic);
        var semantic_wire: [terminal_semantic.semantic_bytes]u8 = undefined;
        _ = try terminal_semantic.encodeV1(
            semantic,
            &semantic_wire,
        );
        var terminal_output_u32_le: [4 * @sizeOf(u32)]u8 = undefined;
        for (terminal_output_tokens, 0..) |token, index| {
            std.mem.writeInt(
                u32,
                terminal_output_u32_le[index * @sizeOf(u32) ..][0..4],
                token,
                .little,
            );
        }

        return .{
            .allocator = allocator,
            .request_epoch = request_epoch,
            .challenge_sha256 = challenge_sha256,
            .predecessor_set = predecessor_set,
            .predecessor_selector = predecessor_selector,
            .restart_archive = restart_archive,
            .first_acknowledgement = first.acknowledgement,
            .first_acknowledgement_wire = first_wire,
            .final_acknowledgement = final.acknowledgement,
            .final_acknowledgement_wire = final_wire,
            .terminal_semantic = semantic,
            .terminal_semantic_wire = semantic_wire,
            .terminal_output_u32_le = terminal_output_u32_le,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.allocator.free(self.predecessor_set);
        self.allocator.free(self.restart_archive);
        self.* = undefined;
    }
};

fn testFillCacheV1(
    cache: *kv.KVCache,
    rows: usize,
) !void {
    if (rows == 0 or rows > 6) return error.InvalidTestRows;
    const values_len = rows * cache.dim;
    for (0..cache.num_layers) |layer| {
        var keys: [12]f32 = undefined;
        var values: [12]f32 = undefined;
        for (keys[0..values_len], 0..) |*value, index| {
            const bits: u32 = @intCast(
                0x3f00_0000 + layer * 0x1000 + index,
            );
            value.* = @bitCast(bits);
        }
        for (values[0..values_len], 0..) |*value, index| {
            const bits: u32 = @intCast(
                0xbf00_0000 + layer * 0x1000 + index,
            );
            value.* = @bitCast(bits);
        }
        _ = try cache.appendRows(
            layer,
            keys[0..values_len],
            values[0..values_len],
            rows,
        );
    }
    cache.commitRows(rows);
}

test "acknowledged nonterminal progress is canonical and self-contained" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const required = try encodedNonterminalBytesV1(
        fixture.restart_archive.len,
    );
    const selected_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(selected_storage);
    const prepared = try encodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        fixture.restart_archive,
        &fixture.first_acknowledgement_wire,
        selected_storage,
    );
    try std.testing.expectEqual(required, prepared.set.bytes.len);
    const selected_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &fixture.predecessor_selector,
        )).selector_sha256,
        prepared.set.bytes,
    );
    const decoded = try decodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        prepared.set.bytes,
        &selected_selector,
    );
    try std.testing.expectEqual(
        @as(usize, nonterminal_object_count),
        decoded.selected.set.object_count,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        decoded.selected.selector.generation,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        decoded.selected.selector.publication_next_sequence,
    );
    try std.testing.expectEqual(
        @as(u32, 31),
        decoded.acknowledgement.token_id,
    );
    try std.testing.expectEqual(
        @as(u64, 51),
        decoded.producer_target.scheduler_epoch,
    );
    try std.testing.expectEqual(
        @as(u64, 52),
        decoded.producer_target.coordinator_id,
    );
    try std.testing.expectEqual(
        @as(u64, 42),
        decoded.producer_target.bank_epoch,
    );
    try std.testing.expectEqual(
        @as(u64, 2001),
        decoded.producer_target.resource_owner_key,
    );
    const embedded = decoded.selected.set.objects[0];
    try std.testing.expectEqual(
        checkpoint_file.ObjectKindV1.runtime_state,
        embedded.kind,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.predecessor_selector,
        embedded.bytes,
    );
    const later_producer =
        try decodeProducerContextV1(decoded.selected);
    try std.testing.expectEqualSlices(
        u8,
        &decoded.manifest.manifest_sha256,
        &later_producer.manifest.manifest_sha256,
    );
}

test "nonterminal progress rejects every selected byte mutation" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const required = try encodedNonterminalBytesV1(
        fixture.restart_archive.len,
    );
    const selected_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(selected_storage);
    const prepared = try encodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        fixture.restart_archive,
        &fixture.first_acknowledgement_wire,
        selected_storage,
    );
    const selected_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &fixture.predecessor_selector,
        )).selector_sha256,
        prepared.set.bytes,
    );

    const mutated_set = try std.testing.allocator.dupe(
        u8,
        prepared.set.bytes,
    );
    defer std.testing.allocator.free(mutated_set);
    for (mutated_set, 0..) |*byte, index| {
        byte.* ^= 0x01;
        if (decodeNonterminalV1(
            fixture.predecessor_set,
            &fixture.predecessor_selector,
            mutated_set,
            &selected_selector,
        )) |_|
            return error.TestExpectedMutationRejection
        else |_| {}
        mutated_set[index] ^= 0x01;
    }

    var mutated_selector = selected_selector;
    for (&mutated_selector, 0..) |*byte, index| {
        byte.* ^= 0x01;
        if (decodeNonterminalV1(
            fixture.predecessor_set,
            &fixture.predecessor_selector,
            prepared.set.bytes,
            &mutated_selector,
        )) |_|
            return error.TestExpectedMutationRejection
        else |_| {}
        mutated_selector[index] ^= 0x01;
    }
}

test "nonterminal progress rejects gap token and coherent ABI substitution" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const required = try encodedNonterminalBytesV1(
        fixture.restart_archive.len,
    );
    const destination =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(destination);
    @memset(destination, 0x5a);
    const before = try std.testing.allocator.dupe(
        u8,
        destination,
    );
    defer std.testing.allocator.free(before);

    var gap_sink = try result_sink.ResultSinkV1(1).init(
        fixture.first_acknowledgement.request_sha256,
        fixture.request_epoch,
        3,
        fixture.first_acknowledgement
            .sink_implementation_sha256,
        fixture.first_acknowledgement.sink_instance_sha256,
    );
    const gap = try gap_sink.apply(.{
        .request_sha256 = fixture.first_acknowledgement.request_sha256,
        .request_epoch = fixture.request_epoch,
        .transaction_sequence = 3,
        .token_id = 31,
        .proposal_sha256 = filledDigest(0xd1),
        .transition_sha256 = filledDigest(0xd2),
        .commit_receipt_sha256 = filledDigest(0xd3),
    });
    var gap_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
    _ = try result_sink.encodeAcknowledgementV1(
        gap.acknowledgement,
        &gap_wire,
    );
    try std.testing.expectError(
        Error.InvalidAcknowledgement,
        encodeNonterminalV1(
            fixture.predecessor_set,
            &fixture.predecessor_selector,
            fixture.restart_archive,
            &gap_wire,
            destination,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        before,
        destination,
    );

    var token_sink = try result_sink.ResultSinkV1(1).init(
        fixture.first_acknowledgement.request_sha256,
        fixture.request_epoch,
        2,
        fixture.first_acknowledgement
            .sink_implementation_sha256,
        fixture.first_acknowledgement.sink_instance_sha256,
    );
    const wrong_token = try token_sink.apply(.{
        .request_sha256 = fixture.first_acknowledgement.request_sha256,
        .request_epoch = fixture.request_epoch,
        .transaction_sequence = 2,
        .token_id = 99,
        .proposal_sha256 = filledDigest(0xd4),
        .transition_sha256 = filledDigest(0xd5),
        .commit_receipt_sha256 = filledDigest(0xd6),
    });
    var wrong_token_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
    _ = try result_sink.encodeAcknowledgementV1(
        wrong_token.acknowledgement,
        &wrong_token_wire,
    );
    try std.testing.expectError(
        Error.InvalidNonterminalProgress,
        encodeNonterminalV1(
            fixture.predecessor_set,
            &fixture.predecessor_selector,
            fixture.restart_archive,
            &wrong_token_wire,
            destination,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        before,
        destination,
    );

    const prepared = try encodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        fixture.restart_archive,
        &fixture.first_acknowledgement_wire,
        destination,
    );
    const decoded_set =
        try checkpoint_file.decodeSetV1(prepared.set.bytes);
    var objects: [nonterminal_object_count]checkpoint_file.ObjectInputV1 = undefined;
    for (&objects, 0..) |*object, index| {
        object.* = inputFromView(decoded_set.objects[index]);
    }
    objects[6].abi_version +%= 1;
    const foreign_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(foreign_storage);
    const foreign = try checkpoint_file.encodeSetV1(
        decoded_set.metadata,
        &objects,
        foreign_storage,
    );
    const foreign_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &fixture.predecessor_selector,
        )).selector_sha256,
        foreign.bytes,
    );
    try std.testing.expectError(
        Error.InvalidSelection,
        decodeNonterminalV1(
            fixture.predecessor_set,
            &fixture.predecessor_selector,
            foreign.bytes,
            &foreign_selector,
        ),
    );
}

test "acknowledged progress binds canonical request and stable sink identity" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const nonterminal_required =
        try encodedNonterminalBytesV1(
            fixture.restart_archive.len,
        );
    const nonterminal_storage =
        try std.testing.allocator.alloc(
            u8,
            nonterminal_required,
        );
    defer std.testing.allocator.free(nonterminal_storage);

    var wrong_request = fixture.first_acknowledgement;
    wrong_request.request_sha256 = filledDigest(0xd7);
    rerootTestAcknowledgementV1(&wrong_request);
    var wrong_request_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
    _ = try result_sink.encodeAcknowledgementV1(
        wrong_request,
        &wrong_request_wire,
    );
    try std.testing.expectError(
        Error.InvalidAcknowledgement,
        encodeNonterminalV1(
            fixture.predecessor_set,
            &fixture.predecessor_selector,
            fixture.restart_archive,
            &wrong_request_wire,
            nonterminal_storage,
        ),
    );

    const nonterminal = try encodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        fixture.restart_archive,
        &fixture.first_acknowledgement_wire,
        nonterminal_storage,
    );
    const predecessor_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &fixture.predecessor_selector,
        )).selector_sha256,
        nonterminal.set.bytes,
    );
    const terminal_required = try encodedTerminalBytesV1(
        nonterminal.set.bytes.len,
        fixture.terminal_output_u32_le.len,
    );
    const terminal_storage =
        try std.testing.allocator.alloc(u8, terminal_required);
    defer std.testing.allocator.free(terminal_storage);

    for (0..2) |identity_index| {
        var wrong_identity = fixture.final_acknowledgement;
        if (identity_index == 0) {
            wrong_identity.sink_implementation_sha256 =
                filledDigest(0xd8);
        } else {
            wrong_identity.sink_instance_sha256 =
                filledDigest(0xd9);
        }
        rerootTestAcknowledgementV1(&wrong_identity);
        var wrong_identity_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
        _ = try result_sink.encodeAcknowledgementV1(
            wrong_identity,
            &wrong_identity_wire,
        );
        try std.testing.expectError(
            Error.InvalidAcknowledgement,
            encodeTerminalV1(
                nonterminal.set.bytes,
                &predecessor_selector,
                &fixture.terminal_semantic_wire,
                &wrong_identity_wire,
                &fixture.terminal_output_u32_le,
                terminal_storage,
            ),
        );
    }
}

test "terminal progress binds final acknowledgement and predecessor lineage" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const nonterminal_required =
        try encodedNonterminalBytesV1(
            fixture.restart_archive.len,
        );
    const nonterminal_storage =
        try std.testing.allocator.alloc(
            u8,
            nonterminal_required,
        );
    defer std.testing.allocator.free(nonterminal_storage);
    const nonterminal = try encodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        fixture.restart_archive,
        &fixture.first_acknowledgement_wire,
        nonterminal_storage,
    );
    const predecessor_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &fixture.predecessor_selector,
        )).selector_sha256,
        nonterminal.set.bytes,
    );

    const terminal_required = try encodedTerminalBytesV1(
        nonterminal.set.bytes.len,
        fixture.terminal_output_u32_le.len,
    );
    const terminal_storage =
        try std.testing.allocator.alloc(u8, terminal_required);
    defer std.testing.allocator.free(terminal_storage);
    const terminal_prepared = try encodeTerminalV1(
        nonterminal.set.bytes,
        &predecessor_selector,
        &fixture.terminal_semantic_wire,
        &fixture.final_acknowledgement_wire,
        &fixture.terminal_output_u32_le,
        terminal_storage,
    );
    const terminal_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &predecessor_selector,
        )).selector_sha256,
        terminal_prepared.set.bytes,
    );
    const decoded = try decodeTerminalV1(
        nonterminal.set.bytes,
        &predecessor_selector,
        terminal_prepared.set.bytes,
        &terminal_selector,
    );
    try std.testing.expectEqual(
        @as(usize, terminal_object_count),
        decoded.selected.set.object_count,
    );
    try std.testing.expectEqual(
        @as(u64, 4),
        decoded.selected.selector.generation,
    );
    try std.testing.expectEqual(
        @as(u64, 4),
        decoded.selected.selector.publication_next_sequence,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        decoded.acknowledgement.application_ordinal,
    );
    try std.testing.expectEqualSlices(
        u8,
        &decoded.acknowledgement
            .predecessor_acknowledgement_sha256,
        &fixture.first_acknowledgement
            .acknowledgement_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.terminal_output_u32_le,
        decoded.canonical_output_u32_le,
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        decoded.outputCount(),
    );
    try std.testing.expectEqual(
        @as(u32, 17),
        try decoded.outputToken(0),
    );
    try std.testing.expectEqual(
        @as(u32, 37),
        try decoded.outputToken(3),
    );
    try std.testing.expectError(
        Error.InvalidTerminalProgress,
        decoded.outputToken(4),
    );
    const output_object = decoded.selected.set.objects[4];
    try std.testing.expectEqual(
        terminal_output_tokens_abi,
        output_object.abi_version,
    );
    try std.testing.expectEqual(
        terminal_output_tokens_object_ordinal,
        output_object.ordinal,
    );
}

test "acknowledged progress revalidates the predecessor acknowledgement" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const nonterminal_required =
        try encodedNonterminalBytesV1(
            fixture.restart_archive.len,
        );
    const nonterminal_storage =
        try std.testing.allocator.alloc(
            u8,
            nonterminal_required,
        );
    defer std.testing.allocator.free(nonterminal_storage);
    const nonterminal = try encodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        fixture.restart_archive,
        &fixture.first_acknowledgement_wire,
        nonterminal_storage,
    );
    const decoded_nonterminal =
        try checkpoint_file.decodeSetV1(nonterminal.set.bytes);
    var objects: [nonterminal_object_count]checkpoint_file.ObjectInputV1 =
        undefined;
    for (&objects, 0..) |*object, index| {
        object.* = inputFromView(
            decoded_nonterminal.objects[index],
        );
    }

    const terminal_required = try encodedTerminalBytesV1(
        nonterminal.set.bytes.len,
        fixture.terminal_output_u32_le.len,
    );
    const terminal_storage =
        try std.testing.allocator.alloc(u8, terminal_required);
    defer std.testing.allocator.free(terminal_storage);
    const rerooted_predecessor_storage =
        try std.testing.allocator.alloc(
            u8,
            nonterminal.set.bytes.len,
        );
    defer std.testing.allocator.free(
        rerooted_predecessor_storage,
    );

    for (0..2) |mutation_index| {
        var changed_previous = fixture.first_acknowledgement;
        if (mutation_index == 0) {
            changed_previous.token_id +%= 1;
        } else {
            changed_previous.request_sha256 =
                filledDigest(0xda);
        }
        rerootTestAcknowledgementV1(&changed_previous);
        var changed_previous_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
        _ = try result_sink.encodeAcknowledgementV1(
            changed_previous,
            &changed_previous_wire,
        );
        objects[6].bytes = &changed_previous_wire;
        const changed_set = try checkpoint_file.encodeSetV1(
            decoded_nonterminal.metadata,
            &objects,
            rerooted_predecessor_storage,
        );
        const changed_selector = try testSelectorForSetV1(
            (try checkpoint_file.decodeSelectorV1(
                &fixture.predecessor_selector,
            )).selector_sha256,
            changed_set.bytes,
        );

        var chained = fixture.final_acknowledgement;
        chained.predecessor_acknowledgement_sha256 =
            changed_previous.acknowledgement_sha256;
        chained.predecessor_sink_prefix_sha256 =
            changed_previous.result_sink_prefix_sha256;
        rerootTestAcknowledgementV1(&chained);
        var chained_wire: [result_sink.acknowledgement_bytes]u8 = undefined;
        _ = try result_sink.encodeAcknowledgementV1(
            chained,
            &chained_wire,
        );
        if (mutation_index == 0) {
            try std.testing.expectError(
                Error.InvalidLineage,
                encodeTerminalV1(
                    changed_set.bytes,
                    &changed_selector,
                    &fixture.terminal_semantic_wire,
                    &chained_wire,
                    &fixture.terminal_output_u32_le,
                    terminal_storage,
                ),
            );
        } else {
            try std.testing.expectError(
                Error.InvalidAcknowledgement,
                encodeTerminalV1(
                    changed_set.bytes,
                    &changed_selector,
                    &fixture.terminal_semantic_wire,
                    &chained_wire,
                    &fixture.terminal_output_u32_le,
                    terminal_storage,
                ),
            );
        }
    }
}

test "terminal progress recovers generation-two producer manifest" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const predecessor = try decodeSelectionV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
    );
    const producer = try decodeProducerContextV1(predecessor);
    const output_tokens = [_]u32{ 17, 29, 31 };
    var output_wire: [output_tokens.len * @sizeOf(u32)]u8 = undefined;
    for (output_tokens, 0..) |token, index| {
        std.mem.writeInt(
            u32,
            output_wire[index * @sizeOf(u32) ..][0..4],
            token,
            .little,
        );
    }
    const state = publication.makeStateCommitmentV1(
        lane_contiguous.abi,
        5,
        filledDigest(0xe1),
        lane_contiguous.rng_state_abi,
        filledDigest(0xe2),
        output_tokens.len,
        output_tokens.len,
        lane_contiguous.outputStateSha256(
            &output_tokens,
            true,
        ),
    );
    var semantic: terminal_semantic.TerminalSemanticV1 = .{
        .request_epoch = fixture.request_epoch,
        .publication_next_sequence = output_tokens.len,
        .prompt_tokens = producer.manifest.plan.prompt_tokens,
        .max_new_tokens = producer.manifest.plan.max_new_tokens,
        .kv_position = 5,
        .sampling_calls = output_tokens.len,
        .output_length = output_tokens.len,
        .output_bytes = output_wire.len,
        .execution_abi = lane_contiguous.abi,
        .rng_state_abi = lane_contiguous.rng_state_abi,
        .local_plan_sha256 = producer.manifest.plan.plan_sha256,
        .artifact_sha256 = producer.manifest.bound_plan
            .artifact.artifact_sha256,
        .token_domain_sha256 = producer.manifest.bound_plan.token_domain_sha256,
        .token_domain_config_sha256 = producer.manifest.bound_plan
            .token_domain_config_sha256,
        .image_container_sha256 = producer.manifest.plan
            .image_identity.container_sha256,
        .prompt_sha256 = producer.manifest.plan.prompt_sha256,
        .output_sha256 = terminal_semantic.outputSemanticRootV1(
            producer.manifest.bound_plan,
            &output_tokens,
        ),
        .logical_kv_sha256 = filledDigest(0xe3),
        .kv_state_sha256 = state.kv_state_sha256,
        .rng_state_sha256 = state.rng_state_sha256,
        .output_state_sha256 = state.output_state_sha256,
        .state_commitment_sha256 = state.commitment_sha256,
        .semantic_sha256 = undefined,
    };
    semantic.semantic_sha256 =
        terminal_semantic.semanticRootV1(semantic);
    var semantic_wire: [terminal_semantic.semantic_bytes]u8 = undefined;
    _ = try terminal_semantic.encodeV1(
        semantic,
        &semantic_wire,
    );

    const required = try encodedTerminalBytesV1(
        fixture.predecessor_set.len,
        output_wire.len,
    );
    const storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(storage);
    const prepared = try encodeTerminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        &semantic_wire,
        &fixture.first_acknowledgement_wire,
        &output_wire,
        storage,
    );
    const selector = try testSelectorForSetV1(
        predecessor.selector.selector_sha256,
        prepared.set.bytes,
    );
    const decoded = try decodeTerminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        prepared.set.bytes,
        &selector,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        decoded.selected.selector.generation,
    );
    try std.testing.expectEqualSlices(
        u8,
        &output_wire,
        decoded.canonical_output_u32_le,
    );
}

test "terminal progress rejects every selected byte mutation and replay" {
    var fixture = try TestFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const nonterminal_required =
        try encodedNonterminalBytesV1(
            fixture.restart_archive.len,
        );
    const nonterminal_storage =
        try std.testing.allocator.alloc(
            u8,
            nonterminal_required,
        );
    defer std.testing.allocator.free(nonterminal_storage);
    const nonterminal = try encodeNonterminalV1(
        fixture.predecessor_set,
        &fixture.predecessor_selector,
        fixture.restart_archive,
        &fixture.first_acknowledgement_wire,
        nonterminal_storage,
    );
    const predecessor_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &fixture.predecessor_selector,
        )).selector_sha256,
        nonterminal.set.bytes,
    );
    const required = try encodedTerminalBytesV1(
        nonterminal.set.bytes.len,
        fixture.terminal_output_u32_le.len,
    );
    const terminal_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(terminal_storage);
    const prepared = try encodeTerminalV1(
        nonterminal.set.bytes,
        &predecessor_selector,
        &fixture.terminal_semantic_wire,
        &fixture.final_acknowledgement_wire,
        &fixture.terminal_output_u32_le,
        terminal_storage,
    );
    const terminal_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &predecessor_selector,
        )).selector_sha256,
        prepared.set.bytes,
    );

    const decoded_prepared_set =
        try checkpoint_file.decodeSetV1(prepared.set.bytes);
    var terminal_objects: [terminal_object_count]checkpoint_file.ObjectInputV1 =
        undefined;
    for (&terminal_objects, 0..) |*object, index| {
        object.* = inputFromView(
            decoded_prepared_set.objects[index],
        );
    }
    var coherent_output = fixture.terminal_output_u32_le;
    coherent_output[0] ^= 1;
    terminal_objects[4].bytes = &coherent_output;
    const coherent_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(coherent_storage);
    const coherent = try checkpoint_file.encodeSetV1(
        decoded_prepared_set.metadata,
        &terminal_objects,
        coherent_storage,
    );
    const coherent_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &predecessor_selector,
        )).selector_sha256,
        coherent.bytes,
    );
    try std.testing.expectError(
        Error.InvalidTerminalProgress,
        decodeTerminalV1(
            nonterminal.set.bytes,
            &predecessor_selector,
            coherent.bytes,
            &coherent_selector,
        ),
    );

    terminal_objects[4].bytes =
        &fixture.terminal_output_u32_le;
    terminal_objects[4].abi_version +%= 1;
    const substituted = try checkpoint_file.encodeSetV1(
        decoded_prepared_set.metadata,
        &terminal_objects,
        coherent_storage,
    );
    const substituted_selector = try testSelectorForSetV1(
        (try checkpoint_file.decodeSelectorV1(
            &predecessor_selector,
        )).selector_sha256,
        substituted.bytes,
    );
    try std.testing.expectError(
        Error.InvalidSelection,
        decodeTerminalV1(
            nonterminal.set.bytes,
            &predecessor_selector,
            substituted.bytes,
            &substituted_selector,
        ),
    );

    const mutated_set = try std.testing.allocator.dupe(
        u8,
        prepared.set.bytes,
    );
    defer std.testing.allocator.free(mutated_set);
    for (mutated_set, 0..) |*byte, index| {
        byte.* ^= 0x01;
        if (decodeTerminalV1(
            nonterminal.set.bytes,
            &predecessor_selector,
            mutated_set,
            &terminal_selector,
        )) |_|
            return error.TestExpectedMutationRejection
        else |_| {}
        mutated_set[index] ^= 0x01;
    }
    var mutated_selector = terminal_selector;
    for (&mutated_selector, 0..) |*byte, index| {
        byte.* ^= 0x01;
        if (decodeTerminalV1(
            nonterminal.set.bytes,
            &predecessor_selector,
            prepared.set.bytes,
            &mutated_selector,
        )) |_|
            return error.TestExpectedMutationRejection
        else |_| {}
        mutated_selector[index] ^= 0x01;
    }

    const retry_storage =
        try std.testing.allocator.alloc(u8, required);
    defer std.testing.allocator.free(retry_storage);
    @memset(retry_storage, 0x6b);
    const retry_before = try std.testing.allocator.dupe(
        u8,
        retry_storage,
    );
    defer std.testing.allocator.free(retry_before);
    try std.testing.expectError(
        Error.InvalidTerminalProgress,
        encodeTerminalV1(
            nonterminal.set.bytes,
            &predecessor_selector,
            &fixture.terminal_semantic_wire,
            &fixture.final_acknowledgement_wire,
            &coherent_output,
            retry_storage,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        retry_before,
        retry_storage,
    );
    try std.testing.expectError(
        Error.InvalidAcknowledgement,
        encodeTerminalV1(
            nonterminal.set.bytes,
            &predecessor_selector,
            &fixture.terminal_semantic_wire,
            &fixture.first_acknowledgement_wire,
            &fixture.terminal_output_u32_le,
            retry_storage,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        retry_before,
        retry_storage,
    );
    try std.testing.expectError(
        Error.InvalidTerminalProgress,
        encodedTerminalBytesV1(
            nonterminal.set.bytes.len,
            3,
        ),
    );
    try std.testing.expectError(
        Error.InvalidTerminalProgress,
        encodedTerminalBytesV1(
            nonterminal.set.bytes.len,
            (maximum_terminal_output_tokens + 1) *
                @sizeOf(u32),
        ),
    );
    try std.testing.expectError(
        Error.InvalidLineage,
        decodeTerminalV1(
            fixture.predecessor_set,
            &fixture.predecessor_selector,
            prepared.set.bytes,
            &terminal_selector,
        ),
    );
}

fn testSelectorForSetV1(
    previous_selector_sha256: Digest,
    encoded_set: []const u8,
) ![checkpoint_file.selector_bytes]u8 {
    const set = try checkpoint_file.decodeSetV1(encoded_set);
    var bytes: [checkpoint_file.selector_bytes]u8 =
        [_]u8{0} ** checkpoint_file.selector_bytes;
    @memcpy(bytes[0..8], "GCSWIT1\x00");
    testWriteU64(&bytes, 8, checkpoint_file.selector_abi);
    testWriteU64(&bytes, 16, checkpoint_file.selector_bytes);
    testWriteU64(&bytes, 24, set.metadata.generation);
    testWriteU64(&bytes, 32, set.metadata.request_epoch);
    testWriteU64(
        &bytes,
        40,
        set.metadata.publication_next_sequence,
    );
    testWriteU64(&bytes, 48, encoded_set.len);
    testWriteU64(&bytes, 56, 0);
    @memcpy(bytes[64..96], &previous_selector_sha256);
    @memcpy(bytes[96..128], &set.checkpoint_sha256);
    @memcpy(
        bytes[128..160],
        &set.metadata.challenge_sha256,
    );
    const root = checkpoint_file.selectorRootV1(
        bytes[0..checkpoint_file.selector_body_bytes],
    );
    @memcpy(
        bytes[checkpoint_file.selector_body_bytes..],
        &root,
    );
    _ = try checkpoint_file.decodeSelectorV1(&bytes);
    return bytes;
}

fn testPromptRootV1(prompt: []const u32) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-prepared-text-prompt-v1\x00");
    testHashU64(&hash, @intCast(prompt.len));
    for (prompt) |token| testHashU32(&hash, token);
    return testFinish(&hash);
}

fn testPlanRootV1(plan: session.PlanV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-prepared-text-plan-v1\x00");
    testHashU64(&hash, plan.abi_version);
    hash.update(&plan.image_identity.source_fingerprint);
    hash.update(&plan.image_identity.abi_fingerprint);
    testHashU64(&hash, plan.image_identity.container_bytes);
    hash.update(&plan.image_identity.container_sha256);
    testHashU64(&hash, plan.prompt_tokens);
    hash.update(&plan.prompt_sha256);
    testHashU64(&hash, plan.max_new_tokens);
    testHashU32(&hash, plan.eos_token);
    testHashU64(&hash, plan.seed);
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        testHashU64(&hash, @field(plan.claim, field.name));
    }
    return testFinish(&hash);
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn rerootTestAcknowledgementV1(
    acknowledgement: *result_sink.ResultAcknowledgementV1,
) void {
    acknowledgement.delivery_key_sha256 =
        result_sink.deliveryKeyRootV1(
            acknowledgement.request_sha256,
            acknowledgement.request_epoch,
            acknowledgement.transaction_sequence,
        );
    acknowledgement.result_sink_prefix_sha256 =
        result_sink.resultSinkPrefixRootV1(
            acknowledgement.*,
        );
    acknowledgement.acknowledgement_sha256 =
        result_sink.acknowledgementRootV1(
            acknowledgement.*,
        );
}

fn testWriteU64(
    destination: []u8,
    offset: usize,
    value: anytype,
) void {
    std.mem.writeInt(
        u64,
        destination[offset..][0..8],
        @intCast(value),
        .little,
    );
}

fn testHashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn testHashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn testFinish(
    hash: *std.crypto.hash.sha2.Sha256,
) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}
