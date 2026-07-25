//! Canonical successor evidence for one prepared-text checkpoint boundary.
//!
//! The successor execution plan and residency binding reuse the Common Model
//! Contract wires. This module adds one fixed transcript-segment record that
//! joins those records to the exact source checkpoint, nonzero publication
//! sequence, logical KV payload, and an explicit target ownership intent.
//!
//! Every value here is pointer-free evidence. It neither exits the source nor
//! creates live Scheduler, ResourceBank, receipt, permit, or Session authority.

const std = @import("std");
const core = @import("core");
const model_contract = core.model_contract;
const resource_bank = core.resource_bank;
const lane = core.lane_weave_qos;
const checkpoint = @import("prepared_text_checkpoint.zig");
const kv = @import("kv_cache.zig");
const lane_contiguous = @import("lane_contiguous_publication.zig");
const publication = @import("lane_publication_txn.zig");

pub const Digest = [32]u8;
pub const successor_segment_abi: u64 = 0x474c_5454_0000_0001;
pub const ownership_intent_abi: u64 = 0x474c_544f_0000_0001;
pub const successor_segment_bytes: usize = 512;
pub const successor_segment_body_bytes: usize =
    successor_segment_bytes - @sizeOf(Digest);
pub const allowed_flags: u64 = 0;

const successor_segment_magic = "GLTSEG01";
const successor_segment_domain =
    "glacier-prepared-text-successor-transcript-segment-v1\x00";
const ownership_intent_domain =
    "glacier-prepared-text-successor-ownership-intent-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BindingMismatch,
    ChallengeMismatch,
    InvalidConfiguration,
    InvalidEncoding,
    InvalidOwnershipIntent,
    InvalidPlan,
    InvalidResidency,
    InvalidSegment,
    UnsafeDestination,
};

/// Target names and exact request charge to be consumed by a later restored
/// admission. These values only contribute to a canonical intent root here.
pub const TargetOwnershipV1 = struct {
    scheduler_epoch: u64,
    coordinator_id: u64,
    bank_epoch: u64,
    request_generation: u64,
    resource_owner_key: u64,
    tree_key: u64,
    authority_key: u64,
    tenant_key: u64,
    scope_key: u64,
    cache_node_key: u64,
    cache_binding_key: u64,
    intent_generation: u64,
    request_claim: resource_bank.Claim,
};

/// Trusted live source context. The checkpoint decoder supplies the portable
/// state bytes; this context supplies the canonical plan/residency and exact
/// publication/receipt lineage that the checkpoint does not authorize alone.
pub const SourceContextV1 = struct {
    bound_plan_sha256: Digest,
    execution: model_contract.ExecutionPlanV1,
    residency: model_contract.ExecutionResidencyBindingV1,
    boundary_sha256: Digest,
    publication: publication.TranscriptSnapshotV1,
    receipt: resource_bank.Receipt,
};

/// One control-plane bridge. It consumes no token sequence: the successor's
/// first future token still uses `sequence_base`.
pub const SuccessorSegmentV1 = struct {
    abi_version: u64 = successor_segment_abi,
    request_epoch: u64,
    sequence_base: u64,
    terminal_sequence: u64,
    remaining_quanta: u64,
    source_last_resource_permit_generation: u64,
    source_kv_position: u64,
    source_sampling_calls: u64,
    source_output_length: u64,
    source_execution_generation: u64,
    successor_execution_generation: u64,
    segment_generation: u64,
    execution_abi: u64,
    rng_state_abi: u64,
    source_checkpoint_sha256: Digest,
    source_bound_plan_sha256: Digest,
    source_execution_plan_sha256: Digest,
    source_boundary_sha256: Digest,
    predecessor_transcript_sha256: Digest,
    source_state_commitment_sha256: Digest,
    source_logical_kv_sha256: Digest,
    successor_execution_plan_sha256: Digest,
    successor_residency_binding_sha256: Digest,
    ownership_intent_sha256: Digest,
    challenge_sha256: Digest,
    segment_sha256: Digest,
};

pub const ArtifactsV1 = struct {
    successor_plan: model_contract.ExecutionPlanV1,
    successor_residency: model_contract.ExecutionResidencyBindingV1,
    segment: SuccessorSegmentV1,
};

/// Decode the checkpoint against caller-retained bindings, then derive the
/// exact Common Model Contract successor plan/residency and transcript bridge.
pub fn makeForCheckpointV1(
    encoded_checkpoint: []const u8,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: SourceContextV1,
    target: TargetOwnershipV1,
) !ArtifactsV1 {
    const decoded = try checkpoint.decodeCheckpointV1(
        encoded_checkpoint,
        expected_checkpoint,
    );
    return makeFromDecodedV1(decoded, source, target);
}

/// Encode all three fixed records into private temporaries before publishing
/// any destination byte. Every validation failure leaves all destinations
/// unchanged.
pub fn encodeArtifactsV1(
    artifacts: ArtifactsV1,
    encoded_plan: *[model_contract.execution_plan_bytes]u8,
    encoded_residency: *[model_contract.execution_residency_binding_bytes]u8,
    encoded_segment: *[successor_segment_bytes]u8,
) Error!void {
    try validateArtifactCompositionV1(artifacts);
    const plan_destination = encoded_plan[0..];
    const residency_destination = encoded_residency[0..];
    const segment_destination = encoded_segment[0..];
    if (slicesOverlap(plan_destination, residency_destination) or
        slicesOverlap(plan_destination, segment_destination) or
        slicesOverlap(residency_destination, segment_destination))
        return Error.UnsafeDestination;
    var plan_local: [model_contract.execution_plan_bytes]u8 = undefined;
    var residency_local: [model_contract.execution_residency_binding_bytes]u8 = undefined;
    var segment_local: [successor_segment_bytes]u8 = undefined;
    model_contract.encodeExecutionPlanV1(
        artifacts.successor_plan,
        &plan_local,
    ) catch return Error.InvalidPlan;
    model_contract.encodeExecutionResidencyBindingV1(
        artifacts.successor_residency,
        &residency_local,
    ) catch return Error.InvalidResidency;
    try encodeSuccessorSegmentV1(artifacts.segment, &segment_local);
    encoded_plan.* = plan_local;
    encoded_residency.* = residency_local;
    encoded_segment.* = segment_local;
}

/// Decode and cross-check the three self-contained wires without granting
/// trust to their source context.
pub fn decodeArtifactsV1(
    encoded_plan: []const u8,
    encoded_residency: []const u8,
    encoded_segment: []const u8,
) Error!ArtifactsV1 {
    const successor_plan =
        model_contract.decodeExecutionPlanV1(encoded_plan) catch
            return Error.InvalidPlan;
    const successor_residency =
        model_contract.decodeExecutionResidencyBindingV1(
            encoded_residency,
        ) catch return Error.InvalidResidency;
    const segment = try decodeSuccessorSegmentV1(encoded_segment);
    const artifacts: ArtifactsV1 = .{
        .successor_plan = successor_plan,
        .successor_residency = successor_residency,
        .segment = segment,
    };
    try validateArtifactCompositionV1(artifacts);
    return artifacts;
}

/// Contextual verifier. Syntactically valid, coherently re-rooted foreign
/// artifacts reject unless they reproduce the caller-retained checkpoint,
/// source authority evidence, and target intent exactly.
pub fn decodeAndVerifyForCheckpointV1(
    encoded_plan: []const u8,
    encoded_residency: []const u8,
    encoded_segment: []const u8,
    encoded_checkpoint: []const u8,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: SourceContextV1,
    target: TargetOwnershipV1,
) !ArtifactsV1 {
    const expected = try makeForCheckpointV1(
        encoded_checkpoint,
        expected_checkpoint,
        source,
        target,
    );
    const decoded = try decodeArtifactsV1(
        encoded_plan,
        encoded_residency,
        encoded_segment,
    );
    if (!std.mem.eql(
        u8,
        &decoded.segment.challenge_sha256,
        &expected.segment.challenge_sha256,
    ))
        return Error.ChallengeMismatch;
    if (!std.meta.eql(decoded, expected))
        return Error.BindingMismatch;
    return decoded;
}

pub fn encodeSuccessorSegmentV1(
    segment: SuccessorSegmentV1,
    destination: *[successor_segment_bytes]u8,
) Error!void {
    try validateSuccessorSegmentV1(segment);
    var encoded: [successor_segment_bytes]u8 = undefined;
    var writer: Writer = .{ .bytes = &encoded };
    try writeSuccessorSegmentBodyV1(&writer, segment);
    if (writer.position != successor_segment_body_bytes)
        return Error.InvalidEncoding;
    try writer.writeDigest(segment.segment_sha256);
    if (writer.position != successor_segment_bytes)
        return Error.InvalidEncoding;
    destination.* = encoded;
}

pub fn decodeSuccessorSegmentV1(
    encoded: []const u8,
) Error!SuccessorSegmentV1 {
    if (encoded.len != successor_segment_bytes)
        return Error.InvalidEncoding;
    var reader: Reader = .{ .bytes = encoded };
    const magic = try reader.readBytes(successor_segment_magic.len);
    if (!std.mem.eql(u8, magic, successor_segment_magic))
        return Error.InvalidEncoding;
    const abi_version = try reader.readU64();
    const flags = try reader.readU64();
    if (abi_version != successor_segment_abi or
        flags != allowed_flags)
        return Error.InvalidEncoding;
    const value: SuccessorSegmentV1 = .{
        .abi_version = abi_version,
        .request_epoch = try reader.readU64(),
        .sequence_base = try reader.readU64(),
        .terminal_sequence = try reader.readU64(),
        .remaining_quanta = try reader.readU64(),
        .source_last_resource_permit_generation = try reader.readU64(),
        .source_kv_position = try reader.readU64(),
        .source_sampling_calls = try reader.readU64(),
        .source_output_length = try reader.readU64(),
        .source_execution_generation = try reader.readU64(),
        .successor_execution_generation = try reader.readU64(),
        .segment_generation = try reader.readU64(),
        .execution_abi = try reader.readU64(),
        .rng_state_abi = try reader.readU64(),
        .source_checkpoint_sha256 = try reader.readDigest(),
        .source_bound_plan_sha256 = try reader.readDigest(),
        .source_execution_plan_sha256 = try reader.readDigest(),
        .source_boundary_sha256 = try reader.readDigest(),
        .predecessor_transcript_sha256 = try reader.readDigest(),
        .source_state_commitment_sha256 = try reader.readDigest(),
        .source_logical_kv_sha256 = try reader.readDigest(),
        .successor_execution_plan_sha256 = try reader.readDigest(),
        .successor_residency_binding_sha256 = try reader.readDigest(),
        .ownership_intent_sha256 = try reader.readDigest(),
        .challenge_sha256 = try reader.readDigest(),
        .segment_sha256 = try reader.readDigest(),
    };
    if (reader.position != successor_segment_bytes)
        return Error.InvalidEncoding;
    try validateSuccessorSegmentV1(value);
    var canonical: [successor_segment_bytes]u8 = undefined;
    try encodeSuccessorSegmentV1(value, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidEncoding;
    return value;
}

pub fn successorSegmentRootV1(segment: SuccessorSegmentV1) Digest {
    var body: [successor_segment_body_bytes]u8 = undefined;
    var writer: Writer = .{ .bytes = &body };
    writeSuccessorSegmentBodyV1(&writer, segment) catch
        return [_]u8{0} ** 32;
    if (writer.position != successor_segment_body_bytes)
        return [_]u8{0} ** 32;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(successor_segment_domain);
    hash.update(&body);
    return finish(&hash);
}

pub fn ownershipIntentRootV1(
    source: SourceContextV1,
    source_checkpoint_sha256: Digest,
    source_boundary_sha256: Digest,
    sequence_base: u64,
    successor_generation: u64,
    challenge_sha256: Digest,
    target: TargetOwnershipV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(ownership_intent_domain);
    hashU64(&hash, ownership_intent_abi);
    hashU64(&hash, resource_bank.abi);
    hashU64(&hash, resource_bank.lease_tree_abi);
    hashU64(&hash, lane.abi);
    hashU64(&hash, model_contract.execution_plan_abi);
    hash.update(&lane.resourceReceiptSha256(source.receipt));
    hash.update(&source.execution.ownership_sha256);
    hash.update(&source.execution.plan_sha256);
    hash.update(&source_checkpoint_sha256);
    hash.update(&source_boundary_sha256);
    hashU64(&hash, source.execution.request_epoch);
    hashU64(&hash, sequence_base);
    hashU64(&hash, source.execution.generation);
    hashU64(&hash, successor_generation);
    hashTargetOwnership(&hash, target);
    hash.update(&challenge_sha256);
    return finish(&hash);
}

pub fn validateSuccessorSegmentV1(
    segment: SuccessorSegmentV1,
) Error!void {
    const expected_successor_generation = std.math.add(
        u64,
        segment.source_execution_generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const expected_remaining = std.math.sub(
        u64,
        segment.terminal_sequence,
        segment.sequence_base,
    ) catch return Error.InvalidSegment;
    if (segment.terminal_sequence == std.math.maxInt(u64))
        return Error.InvalidSegment;
    _ = std.math.add(
        u64,
        segment.source_last_resource_permit_generation,
        expected_remaining,
    ) catch return Error.ArithmeticOverflow;
    if (segment.abi_version != successor_segment_abi or
        segment.request_epoch == 0 or
        segment.sequence_base == 0 or
        segment.sequence_base >= segment.terminal_sequence or
        segment.remaining_quanta == 0 or
        segment.remaining_quanta != expected_remaining or
        segment.source_last_resource_permit_generation == 0 or
        segment.source_kv_position == 0 or
        segment.source_sampling_calls != segment.sequence_base or
        segment.source_output_length != segment.sequence_base or
        segment.source_execution_generation == 0 or
        segment.successor_execution_generation !=
            expected_successor_generation or
        segment.segment_generation !=
            segment.successor_execution_generation or
        segment.execution_abi != lane_contiguous.abi or
        segment.rng_state_abi != lane_contiguous.rng_state_abi or
        isZero(segment.source_checkpoint_sha256) or
        isZero(segment.source_bound_plan_sha256) or
        isZero(segment.source_execution_plan_sha256) or
        isZero(segment.source_boundary_sha256) or
        isZero(segment.predecessor_transcript_sha256) or
        isZero(segment.source_state_commitment_sha256) or
        isZero(segment.source_logical_kv_sha256) or
        isZero(segment.successor_execution_plan_sha256) or
        isZero(segment.successor_residency_binding_sha256) or
        isZero(segment.ownership_intent_sha256) or
        isZero(segment.challenge_sha256) or
        std.mem.eql(
            u8,
            &segment.source_execution_plan_sha256,
            &segment.successor_execution_plan_sha256,
        ))
        return Error.InvalidSegment;
    const expected_root = successorSegmentRootV1(segment);
    if (isZero(expected_root) or
        !std.mem.eql(u8, &segment.segment_sha256, &expected_root))
        return Error.InvalidSegment;
}

fn makeFromDecodedV1(
    decoded: checkpoint.DecodedV1,
    source: SourceContextV1,
    target: TargetOwnershipV1,
) Error!ArtifactsV1 {
    try validateSourceContextV1(decoded, source);
    const successor_generation = std.math.add(
        u64,
        source.execution.generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    try validateTargetOwnershipV1(
        source,
        target,
        successor_generation,
    );
    const ownership_intent_sha256 = ownershipIntentRootV1(
        source,
        decoded.checkpoint_sha256,
        decoded.boundary_sha256,
        decoded.publication_next_sequence,
        successor_generation,
        decoded.challenge_sha256,
        target,
    );
    if (isZero(ownership_intent_sha256))
        return Error.InvalidOwnershipIntent;

    var successor_plan = source.execution;
    successor_plan.generation = successor_generation;
    successor_plan.publication_next_sequence =
        decoded.publication_next_sequence;
    successor_plan.cache_payload_sha256 = decoded.logical_kv_sha256;
    successor_plan.ownership_sha256 = ownership_intent_sha256;
    successor_plan.challenge_sha256 = decoded.challenge_sha256;
    successor_plan.previous_plan_sha256 =
        source.execution.plan_sha256;
    try sealExecutionPlanV1(&successor_plan);
    model_contract.validateExecutionPlanV1(successor_plan) catch
        return Error.InvalidPlan;

    const successor_residency =
        model_contract.makeExecutionResidencyBindingV1(
            successor_plan,
            source.residency.residency,
            source.residency.resident_weight_bytes,
            source.residency.request_claim,
        ) catch return Error.InvalidResidency;

    const terminal_sequence = decoded.max_new_tokens;
    const remaining_quanta = std.math.sub(
        u64,
        terminal_sequence,
        decoded.publication_next_sequence,
    ) catch return Error.InvalidSegment;
    var segment: SuccessorSegmentV1 = .{
        .request_epoch = decoded.request_epoch,
        .sequence_base = decoded.publication_next_sequence,
        .terminal_sequence = terminal_sequence,
        .remaining_quanta = remaining_quanta,
        .source_last_resource_permit_generation = source.publication.last_resource_permit_generation,
        .source_kv_position = @intCast(decoded.kv_positions),
        .source_sampling_calls = decoded.sampling_calls,
        .source_output_length = decoded.output_count,
        .source_execution_generation = source.execution.generation,
        .successor_execution_generation = successor_generation,
        .segment_generation = successor_generation,
        .execution_abi = source.publication.state.execution_abi,
        .rng_state_abi = source.publication.state.rng_state_abi,
        .source_checkpoint_sha256 = decoded.checkpoint_sha256,
        .source_bound_plan_sha256 = decoded.bound_plan_sha256,
        .source_execution_plan_sha256 = source.execution.plan_sha256,
        .source_boundary_sha256 = decoded.boundary_sha256,
        .predecessor_transcript_sha256 = decoded.transcript_sha256,
        .source_state_commitment_sha256 = decoded.state_commitment_sha256,
        .source_logical_kv_sha256 = decoded.logical_kv_sha256,
        .successor_execution_plan_sha256 = successor_plan.plan_sha256,
        .successor_residency_binding_sha256 = successor_residency.binding_sha256,
        .ownership_intent_sha256 = ownership_intent_sha256,
        .challenge_sha256 = decoded.challenge_sha256,
        .segment_sha256 = [_]u8{0} ** 32,
    };
    segment.segment_sha256 = successorSegmentRootV1(segment);
    const artifacts: ArtifactsV1 = .{
        .successor_plan = successor_plan,
        .successor_residency = successor_residency,
        .segment = segment,
    };
    try validateArtifactCompositionV1(artifacts);
    return artifacts;
}

fn validateSourceContextV1(
    decoded: checkpoint.DecodedV1,
    source: SourceContextV1,
) Error!void {
    model_contract.validateExecutionPlanV1(source.execution) catch
        return Error.InvalidPlan;
    model_contract.validateExecutionResidencyBindingV1(
        source.residency,
        source.execution,
    ) catch return Error.InvalidResidency;
    if (!resource_bank.receiptIntegrityValidV1(source.receipt))
        return Error.InvalidConfiguration;
    _ = source.receipt.claim.hostBytes() catch
        return Error.InvalidConfiguration;
    const maximum_output = std.math.add(
        u64,
        source.execution.maximum_absolute_output,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (source.execution.family != .autoregressive or
        source.execution.operation != .generate_sequence or
        source.execution.input_kind != .token_ids or
        source.execution.output_kind != .token_ids or
        source.execution.numerical_policy !=
            .implementation_defined or
        source.execution.batch_items != 1 or
        source.execution.required_capabilities !=
            model_contract.no_capabilities or
        source.execution.input_element_bytes != @sizeOf(u32) or
        source.execution.output_element_bytes != @sizeOf(u32) or
        source.residency.residency != .shared_read_only or
        source.execution.scratch_bytes !=
            source.residency.request_claim.partial_bytes or
        source.execution.request_epoch != decoded.request_epoch or
        source.execution.input_features != decoded.prompt_tokens or
        source.execution.output_dimensions != decoded.max_new_tokens or
        maximum_output != decoded.vocab_size or
        source.execution.publication_next_sequence >=
            decoded.publication_next_sequence or
        !std.mem.eql(
            u8,
            &source.execution.artifact_sha256,
            &decoded.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &source.execution.plan_sha256,
            &decoded.execution_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &source.residency.binding_sha256,
            &decoded.residency_binding_sha256,
        ) or
        !std.mem.eql(
            u8,
            &source.bound_plan_sha256,
            &decoded.bound_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &source.boundary_sha256,
            &decoded.boundary_sha256,
        ) or
        source.publication.abi_version !=
            publication.transcript_snapshot_abi or
        !publication.transcriptSnapshotValidV1(
            source.publication,
        ) or
        source.publication.request_epoch != decoded.request_epoch or
        source.publication.execution_abi != lane_contiguous.abi or
        source.publication.execution_abi !=
            source.publication.state.execution_abi or
        source.publication.state.rng_state_abi !=
            lane_contiguous.rng_state_abi or
        source.publication.next_sequence !=
            decoded.publication_next_sequence or
        source.publication.sequence_base !=
            source.execution.publication_next_sequence or
        source.publication.last_resource_permit_generation == 0 or
        source.publication.terminal or
        !publication.stateCommitmentValidV1(
            source.publication.state,
        ) or
        source.publication.state.kv_position != decoded.kv_positions or
        source.publication.state.sampling_calls !=
            decoded.sampling_calls or
        source.publication.state.output_length !=
            decoded.output_count or
        !std.mem.eql(
            u8,
            &source.publication.state.commitment_sha256,
            &decoded.state_commitment_sha256,
        ) or
        !std.mem.eql(
            u8,
            &source.publication.transcript_sha256,
            &decoded.transcript_sha256,
        ) or
        !std.meta.eql(
            source.receipt.claim,
            source.residency.request_claim,
        ))
        return Error.BindingMismatch;
}

fn validateTargetOwnershipV1(
    source: SourceContextV1,
    target: TargetOwnershipV1,
    successor_generation: u64,
) Error!void {
    if (target.scheduler_epoch == 0 or target.coordinator_id == 0 or
        target.bank_epoch == 0 or target.request_generation == 0 or
        target.resource_owner_key == 0 or target.tree_key == 0 or
        target.authority_key == 0 or target.tenant_key == 0 or
        target.scope_key == 0 or target.cache_node_key == 0 or
        target.cache_binding_key == 0 or
        target.intent_generation == 0 or
        target.bank_epoch == source.receipt.bank_epoch or
        target.resource_owner_key == source.receipt.owner_key or
        target.request_generation != successor_generation or
        target.intent_generation != successor_generation or
        !std.meta.eql(
            target.request_claim,
            source.residency.request_claim,
        ))
        return Error.InvalidOwnershipIntent;
    _ = target.request_claim.hostBytes() catch
        return Error.InvalidOwnershipIntent;
}

fn validateArtifactCompositionV1(
    artifacts: ArtifactsV1,
) Error!void {
    model_contract.validateExecutionPlanV1(
        artifacts.successor_plan,
    ) catch return Error.InvalidPlan;
    model_contract.validateExecutionResidencyBindingV1(
        artifacts.successor_residency,
        artifacts.successor_plan,
    ) catch return Error.InvalidResidency;
    try validateSuccessorSegmentV1(artifacts.segment);
    const kv_sequence_offset = std.math.sub(
        u64,
        artifacts.segment.sequence_base,
        1,
    ) catch return Error.InvalidSegment;
    const expected_source_kv_position = std.math.add(
        u64,
        artifacts.successor_plan.input_features,
        kv_sequence_offset,
    ) catch return Error.ArithmeticOverflow;
    if (artifacts.successor_plan.family != .autoregressive or
        artifacts.successor_plan.operation != .generate_sequence or
        artifacts.successor_plan.input_kind != .token_ids or
        artifacts.successor_plan.output_kind != .token_ids or
        artifacts.successor_plan.numerical_policy !=
            .implementation_defined or
        artifacts.successor_plan.batch_items != 1 or
        artifacts.successor_plan.required_capabilities !=
            model_contract.no_capabilities or
        artifacts.successor_plan.input_element_bytes != @sizeOf(u32) or
        artifacts.successor_plan.output_element_bytes != @sizeOf(u32) or
        artifacts.successor_residency.residency != .shared_read_only or
        artifacts.successor_plan.scratch_bytes !=
            artifacts.successor_residency.request_claim.partial_bytes)
        return Error.InvalidPlan;
    if (artifacts.successor_plan.request_epoch !=
        artifacts.segment.request_epoch or
        artifacts.successor_plan.generation !=
            artifacts.segment.successor_execution_generation or
        artifacts.successor_plan.publication_next_sequence !=
            artifacts.segment.sequence_base or
        artifacts.successor_plan.output_dimensions !=
            artifacts.segment.terminal_sequence or
        artifacts.segment.source_kv_position !=
            expected_source_kv_position or
        !std.mem.eql(
            u8,
            &artifacts.successor_plan.previous_plan_sha256,
            &artifacts.segment.source_execution_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.successor_plan.cache_payload_sha256,
            &artifacts.segment.source_logical_kv_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.successor_plan.ownership_sha256,
            &artifacts.segment.ownership_intent_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.successor_plan.challenge_sha256,
            &artifacts.segment.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.successor_plan.plan_sha256,
            &artifacts.segment.successor_execution_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &artifacts.successor_residency.binding_sha256,
            &artifacts.segment.successor_residency_binding_sha256,
        ))
        return Error.BindingMismatch;
}

fn sealExecutionPlanV1(
    plan: *model_contract.ExecutionPlanV1,
) Error!void {
    plan.plan_sha256 = [_]u8{0} ** 32;
    var encoded: [model_contract.execution_plan_bytes]u8 = undefined;
    model_contract.encodeExecutionPlanV1(plan.*, &encoded) catch
        return Error.InvalidPlan;
    plan.plan_sha256 =
        encoded[model_contract.execution_plan_bytes - 32 ..].*;
}

fn writeSuccessorSegmentBodyV1(
    writer: *Writer,
    segment: SuccessorSegmentV1,
) Error!void {
    try writer.writeBytes(successor_segment_magic);
    try writer.writeU64(successor_segment_abi);
    try writer.writeU64(allowed_flags);
    try writer.writeU64(segment.request_epoch);
    try writer.writeU64(segment.sequence_base);
    try writer.writeU64(segment.terminal_sequence);
    try writer.writeU64(segment.remaining_quanta);
    try writer.writeU64(
        segment.source_last_resource_permit_generation,
    );
    try writer.writeU64(segment.source_kv_position);
    try writer.writeU64(segment.source_sampling_calls);
    try writer.writeU64(segment.source_output_length);
    try writer.writeU64(segment.source_execution_generation);
    try writer.writeU64(segment.successor_execution_generation);
    try writer.writeU64(segment.segment_generation);
    try writer.writeU64(segment.execution_abi);
    try writer.writeU64(segment.rng_state_abi);
    try writer.writeDigest(segment.source_checkpoint_sha256);
    try writer.writeDigest(segment.source_bound_plan_sha256);
    try writer.writeDigest(segment.source_execution_plan_sha256);
    try writer.writeDigest(segment.source_boundary_sha256);
    try writer.writeDigest(segment.predecessor_transcript_sha256);
    try writer.writeDigest(segment.source_state_commitment_sha256);
    try writer.writeDigest(segment.source_logical_kv_sha256);
    try writer.writeDigest(segment.successor_execution_plan_sha256);
    try writer.writeDigest(
        segment.successor_residency_binding_sha256,
    );
    try writer.writeDigest(segment.ownership_intent_sha256);
    try writer.writeDigest(segment.challenge_sha256);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(
            usize,
            self.position,
            value.len,
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.InvalidEncoding;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, value, .little);
        try self.writeBytes(&encoded);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        const end = std.math.add(
            usize,
            self.position,
            length,
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.InvalidEncoding;
        const value = self.bytes[self.position..end];
        self.position = end;
        return value;
    }

    fn readU64(self: *Reader) Error!u64 {
        const encoded = try self.readBytes(8);
        return std.mem.readInt(u64, encoded[0..8], .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        const encoded = try self.readBytes(@sizeOf(Digest));
        return encoded[0..@sizeOf(Digest)].*;
    }
};

fn hashTargetOwnership(
    hash: *std.crypto.hash.sha2.Sha256,
    target: TargetOwnershipV1,
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
    hashClaim(hash, target.request_claim);
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch
        std.math.maxInt(usize);
    const b_end = std.math.add(usize, b_start, b.len) catch
        std.math.maxInt(usize);
    return a_start < b_end and b_start < a_end;
}

comptime {
    if (successor_segment_body_bytes != 480)
        @compileError("prepared successor segment body drift");
    if (successor_segment_bytes != 512)
        @compileError("prepared successor segment wire drift");
}

const TestFixture = struct {
    allocator: std.mem.Allocator,
    encoded_checkpoint: []u8,
    expected_checkpoint: checkpoint.ExpectedBindingsV1,
    source: SourceContextV1,
    target: TargetOwnershipV1,
    artifacts: ArtifactsV1,

    fn init(allocator: std.mem.Allocator) !TestFixture {
        const request_claim: resource_bank.Claim = .{
            .capsule_bytes = 64,
            .kv_bytes = 224,
            .activation_bytes = 12,
            .partial_bytes = 64,
            .logits_bytes = 1024,
            .output_journal_bytes = 20,
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
        var slots = [_]resource_bank.Slot{.{}};
        var bank = try resource_bank.Bank.init(
            &slots,
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
        const reservation = try bank.reserve(1001, request_claim);
        const receipt = try bank.commit(reservation);

        const artifact =
            try model_contract.makeArtifactManifestFromDigestV1(
                .autoregressive,
                0x474c_5446_0000_0001,
                .token_ids,
                .token_ids,
                .implementation_defined,
                1,
                3,
                5,
                @sizeOf(u32),
                @sizeOf(u32),
                1,
                4096,
                filledDigest(0x41),
                filledDigest(0x42),
                filledDigest(0x43),
            );
        const source_execution =
            try model_contract.makeExecutionPlanV1(
                artifact,
                .generate_sequence,
                .{
                    .request_epoch = 0x0102_0304_0506_0708,
                    .generation = 7,
                    .batch_items = 1,
                    .publication_next_sequence = 0,
                    .maximum_absolute_output = 255,
                    .claim = total_claim,
                    .media_object_sha256 = filledDigest(0x31),
                    .processor_state_sha256 = filledDigest(0x32),
                    .processor_bundle_sha256 = filledDigest(0x33),
                    .cache_bundle_sha256 = filledDigest(0x34),
                    .cache_payload_sha256 = filledDigest(0x35),
                    .ownership_sha256 = filledDigest(0x36),
                    .challenge_sha256 = filledDigest(0xcc),
                    .previous_plan_sha256 = [_]u8{0} ** 32,
                    .input_schema_sha256 = filledDigest(0x37),
                    .output_schema_sha256 = filledDigest(0x38),
                    .scratch_bytes = request_claim.partial_bytes,
                },
            );
        const source_residency =
            try model_contract.makeExecutionResidencyBindingV1(
                source_execution,
                .shared_read_only,
                4096,
                request_claim,
            );

        var cache = try kv.KVCache.init(allocator, 2, 2, 7);
        defer cache.deinit();
        for (0..cache.num_layers) |layer| {
            var keys: [8]f32 = undefined;
            var values: [8]f32 = undefined;
            for (&keys, 0..) |*value, index| {
                const bits: u32 = @intCast(
                    0x3f00_0000 + layer * 0x1000 + index,
                );
                value.* = @bitCast(bits);
            }
            for (&values, 0..) |*value, index| {
                const bits: u32 = @intCast(
                    0xbf00_0000 + layer * 0x1000 + index,
                );
                value.* = @bitCast(bits);
            }
            _ = try cache.appendRows(layer, &keys, &values, 4);
        }
        cache.commitRows(4);

        const output_tokens = [_]u32{ 17, 29 };
        const rng_state: lane_contiguous.RngState = .{
            0x0102_0304_0506_0708,
            0x1112_1314_1516_1718,
            0x2122_2324_2526_2728,
            0x3132_3334_3536_3738,
        };
        const state = publication.makeStateCommitmentV1(
            lane_contiguous.abi,
            4,
            try checkpoint.incrementalKvStateRootV1(&cache, 3),
            lane_contiguous.rng_state_abi,
            lane_contiguous.rngStateSha256(rng_state),
            2,
            2,
            lane_contiguous.outputStateSha256(&output_tokens, false),
        );
        const transcript_sha256 = filledDigest(0x77);
        const bound_plan_sha256 = filledDigest(0x22);
        const boundary_sha256 = filledDigest(0x66);
        const challenge_sha256 = filledDigest(0xcc);
        const expected_checkpoint: checkpoint.ExpectedBindingsV1 = .{
            .local_plan_sha256 = filledDigest(0x11),
            .bound_plan_sha256 = bound_plan_sha256,
            .artifact_sha256 = artifact.artifact_sha256,
            .execution_plan_sha256 = source_execution.plan_sha256,
            .residency_binding_sha256 = source_residency.binding_sha256,
            .boundary_sha256 = boundary_sha256,
            .transcript_sha256 = transcript_sha256,
            .state_commitment_sha256 = state.commitment_sha256,
            .request_epoch = source_execution.request_epoch,
            .publication_next_sequence = 2,
            .prompt_tokens = 3,
            .max_new_tokens = 5,
            .vocab_size = 256,
            .num_layers = 2,
            .kv_dim = 2,
            .max_kv_positions = 7,
            .kv_positions = 4,
            .output_count = 2,
            .sampling_calls = 2,
            .challenge_sha256 = challenge_sha256,
        };
        const required =
            try checkpoint.encodedCheckpointBytesV1(2, 2, 4, 2);
        const encoded_checkpoint = try allocator.alloc(u8, required);
        errdefer allocator.free(encoded_checkpoint);
        _ = try checkpoint.encodeCheckpointV1(
            .{
                .local_plan_sha256 = expected_checkpoint.local_plan_sha256,
                .bound_plan_sha256 = bound_plan_sha256,
                .artifact_sha256 = artifact.artifact_sha256,
                .execution_plan_sha256 = source_execution.plan_sha256,
                .residency_binding_sha256 = source_residency.binding_sha256,
                .boundary_sha256 = boundary_sha256,
                .transcript_sha256 = transcript_sha256,
                .state_commitment_sha256 = state.commitment_sha256,
                .request_epoch = source_execution.request_epoch,
                .publication_next_sequence = 2,
                .prompt_tokens = 3,
                .max_new_tokens = 5,
                .vocab_size = 256,
                .output_tokens = &output_tokens,
                .rng_state = rng_state,
                .sampling_calls = 2,
                .cache = &cache,
                .challenge_sha256 = challenge_sha256,
            },
            encoded_checkpoint,
        );
        const source: SourceContextV1 = .{
            .bound_plan_sha256 = bound_plan_sha256,
            .execution = source_execution,
            .residency = source_residency,
            .boundary_sha256 = boundary_sha256,
            .publication = .{
                .request_epoch = source_execution.request_epoch,
                .execution_abi = lane_contiguous.abi,
                .next_sequence = 2,
                .last_resource_permit_generation = 19,
                .terminal = false,
                .state = state,
                .transcript_sha256 = transcript_sha256,
            },
            .receipt = receipt,
        };
        const target: TargetOwnershipV1 = .{
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
        const artifacts = try makeForCheckpointV1(
            encoded_checkpoint,
            expected_checkpoint,
            source,
            target,
        );
        return .{
            .allocator = allocator,
            .encoded_checkpoint = encoded_checkpoint,
            .expected_checkpoint = expected_checkpoint,
            .source = source,
            .target = target,
            .artifacts = artifacts,
        };
    }

    fn deinit(self: *TestFixture) void {
        self.allocator.free(self.encoded_checkpoint);
        self.* = undefined;
    }
};

test "prepared successor artifacts are canonical and mutation complete" {
    const testing = std.testing;
    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit();
    var encoded_plan: [model_contract.execution_plan_bytes]u8 = undefined;
    var encoded_residency: [model_contract.execution_residency_binding_bytes]u8 = undefined;
    var encoded_segment: [successor_segment_bytes]u8 = undefined;
    try encodeArtifactsV1(
        fixture.artifacts,
        &encoded_plan,
        &encoded_residency,
        &encoded_segment,
    );
    const decoded = try decodeAndVerifyForCheckpointV1(
        &encoded_plan,
        &encoded_residency,
        &encoded_segment,
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        fixture.target,
    );
    try testing.expectEqualDeep(fixture.artifacts, decoded);
    const plan_hex = std.fmt.bytesToHex(
        fixture.artifacts.successor_plan.plan_sha256,
        .lower,
    );
    const residency_hex = std.fmt.bytesToHex(
        fixture.artifacts.successor_residency.binding_sha256,
        .lower,
    );
    const intent_hex = std.fmt.bytesToHex(
        fixture.artifacts.segment.ownership_intent_sha256,
        .lower,
    );
    const segment_hex = std.fmt.bytesToHex(
        fixture.artifacts.segment.segment_sha256,
        .lower,
    );
    try testing.expectEqualStrings(
        "f678322f4dae556ce2e660787d52811bcc17627a5b3538fa5a2ce9f03d64dfaa",
        &plan_hex,
    );
    try testing.expectEqualStrings(
        "6449605803a760b8f6748c60537f196c4faeb1ee272d397bc39b5903602db244",
        &residency_hex,
    );
    try testing.expectEqualStrings(
        "7a27a8ae765d373cd05acd5bc5a9de213173b4a0f48538250756fdff7327d584",
        &intent_hex,
    );
    try testing.expectEqualStrings(
        "d4b64fea15cae72847f72d586dffae76a225a096de8e26e69a6025b1a452a818",
        &segment_hex,
    );

    for (0..encoded_plan.len) |index| {
        var mutated = encoded_plan;
        mutated[index] ^= 1;
        try expectArtifactsReject(
            &mutated,
            &encoded_residency,
            &encoded_segment,
        );
    }
    for (0..encoded_residency.len) |index| {
        var mutated = encoded_residency;
        mutated[index] ^= 1;
        try expectArtifactsReject(
            &encoded_plan,
            &mutated,
            &encoded_segment,
        );
    }
    for (0..encoded_segment.len) |index| {
        var mutated = encoded_segment;
        mutated[index] ^= 1;
        try expectArtifactsReject(
            &encoded_plan,
            &encoded_residency,
            &mutated,
        );
    }
    for (0..successor_segment_bytes) |length| {
        try testing.expectError(
            Error.InvalidEncoding,
            decodeSuccessorSegmentV1(encoded_segment[0..length]),
        );
    }
    var extended: [successor_segment_bytes + 1]u8 = undefined;
    @memcpy(extended[0..successor_segment_bytes], &encoded_segment);
    extended[successor_segment_bytes] = 0;
    try testing.expectError(
        Error.InvalidEncoding,
        decodeSuccessorSegmentV1(&extended),
    );
}

test "prepared successor contextual verifier rejects coherent foreign intent" {
    const testing = std.testing;
    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit();
    var foreign_target = fixture.target;
    foreign_target.resource_owner_key += 1;
    const foreign = try makeForCheckpointV1(
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
        fixture.source,
        foreign_target,
    );
    var encoded_plan: [model_contract.execution_plan_bytes]u8 = undefined;
    var encoded_residency: [model_contract.execution_residency_binding_bytes]u8 = undefined;
    var encoded_segment: [successor_segment_bytes]u8 = undefined;
    try encodeArtifactsV1(
        foreign,
        &encoded_plan,
        &encoded_residency,
        &encoded_segment,
    );
    _ = try decodeArtifactsV1(
        &encoded_plan,
        &encoded_residency,
        &encoded_segment,
    );
    try testing.expectError(
        Error.BindingMismatch,
        decodeAndVerifyForCheckpointV1(
            &encoded_plan,
            &encoded_residency,
            &encoded_segment,
            fixture.encoded_checkpoint,
            fixture.expected_checkpoint,
            fixture.source,
            fixture.target,
        ),
    );

    var foreign_plan = foreign;
    foreign_plan.successor_plan.media_object_sha256[0] ^= 1;
    try sealExecutionPlanV1(&foreign_plan.successor_plan);
    foreign_plan.successor_residency =
        try model_contract.makeExecutionResidencyBindingV1(
            foreign_plan.successor_plan,
            foreign_plan.successor_residency.residency,
            foreign_plan.successor_residency.resident_weight_bytes,
            foreign_plan.successor_residency.request_claim,
        );
    foreign_plan.segment.successor_execution_plan_sha256 =
        foreign_plan.successor_plan.plan_sha256;
    foreign_plan.segment.successor_residency_binding_sha256 =
        foreign_plan.successor_residency.binding_sha256;
    foreign_plan.segment.segment_sha256 =
        successorSegmentRootV1(foreign_plan.segment);
    try encodeArtifactsV1(
        foreign_plan,
        &encoded_plan,
        &encoded_residency,
        &encoded_segment,
    );
    try testing.expectError(
        Error.BindingMismatch,
        decodeAndVerifyForCheckpointV1(
            &encoded_plan,
            &encoded_residency,
            &encoded_segment,
            fixture.encoded_checkpoint,
            fixture.expected_checkpoint,
            fixture.source,
            foreign_target,
        ),
    );
}

test "prepared successor structural validation rejects coherent contradictions" {
    const testing = std.testing;
    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit();
    var plan_destination: [model_contract.execution_plan_bytes]u8 =
        undefined;
    var residency_destination: [
        model_contract.execution_residency_binding_bytes
    ]u8 = undefined;
    var segment_destination: [successor_segment_bytes]u8 = undefined;

    var terminal_mismatch = fixture.artifacts;
    terminal_mismatch.segment.terminal_sequence += 1;
    terminal_mismatch.segment.remaining_quanta += 1;
    terminal_mismatch.segment.segment_sha256 =
        successorSegmentRootV1(terminal_mismatch.segment);
    try testing.expectError(
        Error.BindingMismatch,
        encodeArtifactsV1(
            terminal_mismatch,
            &plan_destination,
            &residency_destination,
            &segment_destination,
        ),
    );

    var kv_mismatch = fixture.artifacts;
    kv_mismatch.segment.source_kv_position += 1;
    kv_mismatch.segment.segment_sha256 =
        successorSegmentRootV1(kv_mismatch.segment);
    try testing.expectError(
        Error.BindingMismatch,
        encodeArtifactsV1(
            kv_mismatch,
            &plan_destination,
            &residency_destination,
            &segment_destination,
        ),
    );

    var incompatible_profile = fixture.artifacts;
    incompatible_profile.successor_plan.input_element_bytes = 2;
    incompatible_profile.successor_plan.output_element_bytes = 2;
    incompatible_profile.successor_plan.input_bytes =
        incompatible_profile.successor_plan.input_features * 2;
    incompatible_profile.successor_plan.output_bytes =
        incompatible_profile.successor_plan.output_dimensions * 2;
    try sealExecutionPlanV1(&incompatible_profile.successor_plan);
    incompatible_profile.successor_residency =
        try model_contract.makeExecutionResidencyBindingV1(
            incompatible_profile.successor_plan,
            incompatible_profile.successor_residency.residency,
            incompatible_profile.successor_residency.resident_weight_bytes,
            incompatible_profile.successor_residency.request_claim,
        );
    incompatible_profile.segment.successor_execution_plan_sha256 =
        incompatible_profile.successor_plan.plan_sha256;
    incompatible_profile.segment.successor_residency_binding_sha256 =
        incompatible_profile.successor_residency.binding_sha256;
    incompatible_profile.segment.segment_sha256 =
        successorSegmentRootV1(incompatible_profile.segment);
    try testing.expectError(
        Error.InvalidPlan,
        encodeArtifactsV1(
            incompatible_profile,
            &plan_destination,
            &residency_destination,
            &segment_destination,
        ),
    );

    var wrong_execution_abi = fixture.artifacts;
    wrong_execution_abi.segment.execution_abi += 1;
    wrong_execution_abi.segment.segment_sha256 =
        successorSegmentRootV1(wrong_execution_abi.segment);
    try testing.expectError(
        Error.InvalidSegment,
        encodeArtifactsV1(
            wrong_execution_abi,
            &plan_destination,
            &residency_destination,
            &segment_destination,
        ),
    );

    var exhausted_permit_space = fixture.artifacts.segment;
    exhausted_permit_space.source_last_resource_permit_generation =
        std.math.maxInt(u64) - 1;
    exhausted_permit_space.segment_sha256 =
        successorSegmentRootV1(exhausted_permit_space);
    try testing.expectError(
        Error.ArithmeticOverflow,
        validateSuccessorSegmentV1(exhausted_permit_space),
    );

    var exhausted_sequence_space = fixture.artifacts.segment;
    exhausted_sequence_space.terminal_sequence =
        std.math.maxInt(u64);
    exhausted_sequence_space.remaining_quanta =
        exhausted_sequence_space.terminal_sequence -
        exhausted_sequence_space.sequence_base;
    exhausted_sequence_space.segment_sha256 =
        successorSegmentRootV1(exhausted_sequence_space);
    try testing.expectError(
        Error.InvalidSegment,
        validateSuccessorSegmentV1(exhausted_sequence_space),
    );

    const decoded_checkpoint = try checkpoint.decodeCheckpointV1(
        fixture.encoded_checkpoint,
        fixture.expected_checkpoint,
    );
    var non_u32_source = fixture.source;
    non_u32_source.execution.input_element_bytes = 2;
    non_u32_source.execution.output_element_bytes = 2;
    non_u32_source.execution.input_bytes =
        non_u32_source.execution.input_features * 2;
    non_u32_source.execution.output_bytes =
        non_u32_source.execution.output_dimensions * 2;
    try sealExecutionPlanV1(&non_u32_source.execution);
    non_u32_source.residency =
        try model_contract.makeExecutionResidencyBindingV1(
            non_u32_source.execution,
            non_u32_source.residency.residency,
            non_u32_source.residency.resident_weight_bytes,
            non_u32_source.residency.request_claim,
        );
    var non_u32_decoded = decoded_checkpoint;
    non_u32_decoded.execution_plan_sha256 =
        non_u32_source.execution.plan_sha256;
    non_u32_decoded.residency_binding_sha256 =
        non_u32_source.residency.binding_sha256;
    try testing.expectError(
        Error.BindingMismatch,
        validateSourceContextV1(non_u32_decoded, non_u32_source),
    );

    var outer_abi_mismatch = fixture.source;
    outer_abi_mismatch.publication.execution_abi += 1;
    try testing.expectError(
        Error.BindingMismatch,
        validateSourceContextV1(
            decoded_checkpoint,
            outer_abi_mismatch,
        ),
    );

    var sequence_base_mismatch = fixture.source;
    sequence_base_mismatch.publication.sequence_base += 1;
    try testing.expectError(
        Error.BindingMismatch,
        validateSourceContextV1(
            decoded_checkpoint,
            sequence_base_mismatch,
        ),
    );

    var aliased_destinations = [_]u8{0xa5} ** 1536;
    const aliased_before = aliased_destinations;
    const aliased_plan: *[model_contract.execution_plan_bytes]u8 =
        @ptrCast(aliased_destinations[0..].ptr);
    const aliased_residency: *[
        model_contract.execution_residency_binding_bytes
    ]u8 = @ptrCast(aliased_destinations[512..].ptr);
    const disjoint_segment: *[successor_segment_bytes]u8 =
        @ptrCast(aliased_destinations[1024..].ptr);
    try testing.expectError(
        Error.UnsafeDestination,
        encodeArtifactsV1(
            fixture.artifacts,
            aliased_plan,
            aliased_residency,
            disjoint_segment,
        ),
    );
    try testing.expectEqualSlices(
        u8,
        &aliased_before,
        &aliased_destinations,
    );
}

test "prepared successor failures preserve output and exact source bindings" {
    const testing = std.testing;
    var fixture = try TestFixture.init(testing.allocator);
    defer fixture.deinit();
    var invalid_target = fixture.target;
    invalid_target.bank_epoch = fixture.source.receipt.bank_epoch;
    try testing.expectError(
        Error.InvalidOwnershipIntent,
        makeForCheckpointV1(
            fixture.encoded_checkpoint,
            fixture.expected_checkpoint,
            fixture.source,
            invalid_target,
        ),
    );
    var wrong_challenge = fixture.expected_checkpoint;
    wrong_challenge.challenge_sha256[0] ^= 1;
    try testing.expectError(
        checkpoint.Error.ChallengeMismatch,
        makeForCheckpointV1(
            fixture.encoded_checkpoint,
            wrong_challenge,
            fixture.source,
            fixture.target,
        ),
    );
    var wrong_boundary = fixture.source;
    wrong_boundary.boundary_sha256[0] ^= 1;
    try testing.expectError(
        Error.BindingMismatch,
        makeForCheckpointV1(
            fixture.encoded_checkpoint,
            fixture.expected_checkpoint,
            wrong_boundary,
            fixture.target,
        ),
    );

    var invalid = fixture.artifacts;
    invalid.segment.sequence_base = 0;
    invalid.segment.segment_sha256 =
        successorSegmentRootV1(invalid.segment);
    var plan_destination =
        [_]u8{0xa5} ** model_contract.execution_plan_bytes;
    var residency_destination =
        [_]u8{0xa5} **
        model_contract.execution_residency_binding_bytes;
    var segment_destination =
        [_]u8{0xa5} ** successor_segment_bytes;
    const plan_before = plan_destination;
    const residency_before = residency_destination;
    const segment_before = segment_destination;
    try testing.expectError(
        Error.InvalidSegment,
        encodeArtifactsV1(
            invalid,
            &plan_destination,
            &residency_destination,
            &segment_destination,
        ),
    );
    try testing.expectEqualSlices(
        u8,
        &plan_before,
        &plan_destination,
    );
    try testing.expectEqualSlices(
        u8,
        &residency_before,
        &residency_destination,
    );
    try testing.expectEqualSlices(
        u8,
        &segment_before,
        &segment_destination,
    );
}

fn expectArtifactsReject(
    encoded_plan: []const u8,
    encoded_residency: []const u8,
    encoded_segment: []const u8,
) !void {
    if (decodeArtifactsV1(
        encoded_plan,
        encoded_residency,
        encoded_segment,
    )) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn filledDigest(value: u8) Digest {
    return [_]u8{value} ** 32;
}
