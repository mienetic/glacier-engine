//! Persistent, transactionally published text generation for one exact
//! prepared-image profile.
//!
//! V1 deliberately admits only prepared `.glrt`, serial CPU execution,
//! separate MLP storage, materialized logits, and deterministic greedy
//! selection. The narrow profile keeps its claim and numerical oracle exact
//! while the broader runtime contract evolves.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const lane = core.lane_weave_qos;
const model_contract = core.model_contract;
const tensor = core.tensor;
const forward = @import("forward.zig");
const loader = @import("loader.zig");
const kv = @import("kv_cache.zig");
const decode_buffers = @import("decode_buffers.zig");
const generate = @import("generate.zig");
const sampling = @import("sampling.zig");
const runtime_image = @import("model/runtime_image.zig");
const lane_contiguous = @import("lane_contiguous_publication.zig");
const publication = @import("lane_publication_txn.zig");
const prepared_checkpoint = @import("prepared_text_checkpoint.zig");
const prepared_source_lease =
    @import("prepared_text_source_lease.zig");
const prepared_successor = @import("prepared_text_successor.zig");
const prepared_restore =
    @import("prepared_text_restore_admission.zig");
const kernels = @import("backends/cpu/kernels.zig");

pub const plan_abi: u64 = 0x474c_5450_0000_0001;
pub const session_abi: u64 = 0x474c_5453_0000_0001;
pub const bound_plan_abi: u64 = 0x474c_5443_0000_0001;
pub const session_v2_abi: u64 = 0x474c_5453_0000_0002;
pub const session_v3_abi: u64 = 0x474c_5453_0000_0003;
pub const terminal_result_evidence_abi: u64 =
    0x474c_5452_0000_0001;
pub const prepared_artifact_profile_abi: u64 =
    0x474c_5441_0000_0001;

const prompt_domain = "glacier-prepared-text-prompt-v1\x00";
const plan_domain = "glacier-prepared-text-plan-v1\x00";
const boundary_domain = "glacier-prepared-text-boundary-v1\x00";
const artifact_metadata_domain =
    "glacier-prepared-text-artifact-metadata-v1\x00";
const cache_bundle_domain =
    "glacier-prepared-text-cache-bundle-v1\x00";
const empty_cache_payload_domain =
    "glacier-prepared-text-empty-cache-payload-v1\x00";
const ownership_domain =
    "glacier-prepared-text-ownership-v1\x00";
const input_schema_domain =
    "glacier-prepared-text-input-schema-v1\x00";
const output_schema_domain =
    "glacier-prepared-text-output-schema-v1\x00";
const bound_plan_domain =
    "glacier-prepared-text-bound-plan-v1\x00";
const boundary_v2_domain =
    "glacier-prepared-text-boundary-v2\x00";
const terminal_output_domain =
    "glacier-prepared-text-terminal-output-v1\x00";
const terminal_source_mapping_domain =
    "glacier-prepared-text-terminal-source-mapping-v1\x00";
const terminal_adapter_domain =
    "glacier-prepared-text-terminal-adapter-v1\x00";
const terminal_result_evidence_domain =
    "glacier-prepared-text-terminal-result-evidence-v1\x00";

pub const Error = error{
    PreparedImageRequired,
    InvalidConfiguration,
    InvalidPlan,
    InvalidBoundPlan,
    InvalidAdmission,
    AdmissionClaimMismatch,
    InvalidState,
    RecoveryRequired,
};

pub const OptionsV1 = struct {
    max_new_tokens: usize,
    eos_token: u32 = std.math.maxInt(u32),
    seed: u64 = 0,

    /// Exact legacy configuration used as the numerical compatibility oracle.
    pub fn generateOptions(self: OptionsV1) generate.GenerateOptions {
        return .{
            .max_new_tokens = self.max_new_tokens,
            .eos_token = self.eos_token,
            .sampler = .{ .temperature = 0 },
            .seed = self.seed,
            .num_threads = 1,
            .use_persistent_executor = false,
            .mlp_representation = .separate,
            .decode_frame_mode = .materialized_required,
            .parallel_attention_min_context = null,
            .decode_plan_mode = .checked,
            .greedy_output_mode = .materialized,
            .use_batch_prefill = false,
        };
    }
};

/// Caller-owned scheduling identity and QoS inputs. `SessionV1.start` derives
/// the exact work count and every resource dimension from its verified plan,
/// so callers cannot substitute execution ownership at admission.
pub const SchedulingV1 = struct {
    tenant_key: u64,
    request_key: u64,
    request_generation: u64,
    resource_owner_key: u64,
    weight: u16,
    deadline_tick: u64 = 0,

    fn requestSpec(self: SchedulingV1, plan: PlanV1) lane.RequestSpec {
        return .{
            .tenant_key = self.tenant_key,
            .request_key = self.request_key,
            .request_generation = self.request_generation,
            .resource_owner_key = self.resource_owner_key,
            .weight = self.weight,
            .work_quanta = plan.max_new_tokens,
            .deadline_tick = self.deadline_tick,
            .claim = plan.claim,
        };
    }
};

/// `started` means the Session owns the accepted admission and its exact
/// publication binding. A rejection leaves the Session uninitialized.
pub const StartDecisionV1 = union(enum) {
    started: lane.EventV1,
    rejected: lane.EventV1,
};

pub const PlanV1 = struct {
    abi_version: u64 = plan_abi,
    image_identity: runtime_image.ImageIdentityV1,
    prompt_tokens: u64,
    prompt_sha256: [32]u8,
    max_new_tokens: u64,
    eos_token: u32,
    seed: u64,
    claim: resource_bank.Claim,
    plan_sha256: [32]u8,
};

pub const BoundarySnapshotV1 = struct {
    abi_version: u64 = session_abi,
    plan_sha256: [32]u8,
    image_identity: runtime_image.ImageIdentityV1,
    publication: publication.TranscriptSnapshotV1,
    boundary_sha256: [32]u8,
};

/// Opaque, caller-asserted identities for pre-tokenized u32 input. R1c binds
/// these roots but does not execute a tokenizer or attest the bytes behind
/// them. `artifact_license_sha256` has the same assertion-only status. The
/// caller passes this value independently to both plan construction and V2
/// start so a coherently re-rooted substitution cannot become self-authorizing.
pub const BoundPlanInputV1 = struct {
    request_epoch: u64,
    token_domain_sha256: [32]u8,
    token_domain_config_sha256: [32]u8,
    artifact_license_sha256: [32]u8,
    previous_plan_sha256: [32]u8 = [_]u8{0} ** 32,
};

/// Cross-binding between the prepared-text profile and canonical Model
/// Contract identities. The common plan describes total logical resources;
/// `residency` projects that total to the exact request-charged claim.
pub const BoundPlanV1 = struct {
    abi_version: u64 = bound_plan_abi,
    local_plan_sha256: [32]u8,
    artifact: model_contract.ArtifactManifestV1,
    execution: model_contract.ExecutionPlanV1,
    residency: model_contract.ExecutionResidencyBindingV1,
    token_domain_sha256: [32]u8,
    token_domain_config_sha256: [32]u8,
    artifact_license_sha256: [32]u8,
    bound_plan_sha256: [32]u8,
};

/// V2 evidence keeps the stable V1 boundary intact and adds common artifact,
/// execution-plan, and charged-claim projection roots.
pub const BoundarySnapshotV2 = struct {
    abi_version: u64 = session_v2_abi,
    base: BoundarySnapshotV1,
    bound_plan_sha256: [32]u8,
    artifact_sha256: [32]u8,
    execution_plan_sha256: [32]u8,
    residency_binding_sha256: [32]u8,
    boundary_sha256: [32]u8,
};

/// Direct terminal evidence for the preferred R1d session. The contained
/// ResultEnvelope remains the canonical portable wire; this grouping is an
/// experimental in-process join to the exact V2 boundary and publication
/// state after one terminal result commit.
pub const TerminalResultEvidenceV1 = struct {
    abi_version: u64 = terminal_result_evidence_abi,
    boundary: BoundarySnapshotV2,
    result: model_contract.ResultEnvelopeV1,
    publication_state_after: model_contract.PublicationStateV1,
    publication_state_after_sha256: [32]u8,
    evidence_sha256: [32]u8,
};

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn promptSha256(prompt: []const u32) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_domain);
    hashU64(&hash, @intCast(prompt.len));
    for (prompt) |token| hashU32(&hash, token);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Canonical prepared-text prompt root used by the local plan. Raw-text
/// adapters expose this helper so independently tokenized input can prove that
/// its exact u32 stream, rather than only a caller assertion, entered the
/// common-plan bridge.
pub fn promptTokensSha256V1(prompt: []const u32) [32]u8 {
    return promptSha256(prompt);
}

/// Compute the same canonical prepared-text prompt root for a byte-token
/// stream without allocating an intermediate `u32` array. This is used by
/// durable UTF-8 input decoders before they trust any retained token buffer.
pub fn promptByteTokensSha256V1(bytes: []const u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_domain);
    hashU64(&hash, @intCast(bytes.len));
    for (bytes) |byte| hashU32(&hash, byte);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

test "byte-token prompt root matches canonical u32 prompt root" {
    const bytes = [_]u8{ 0, 7, 127, 128, 255 };
    const tokens = [_]u32{ 0, 7, 127, 128, 255 };
    try std.testing.expectEqualSlices(
        u8,
        &promptTokensSha256V1(&tokens),
        &promptByteTokensSha256V1(&bytes),
    );
}

fn planSha256(plan: PlanV1) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, plan.abi_version);
    hash.update(&plan.image_identity.source_fingerprint);
    hash.update(&plan.image_identity.abi_fingerprint);
    hashU64(&hash, plan.image_identity.container_bytes);
    hash.update(&plan.image_identity.container_sha256);
    hashU64(&hash, plan.prompt_tokens);
    hash.update(&plan.prompt_sha256);
    hashU64(&hash, plan.max_new_tokens);
    hashU32(&hash, plan.eos_token);
    hashU64(&hash, plan.seed);
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        hashU64(&hash, @field(plan.claim, field.name));
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Structural and canonical validation for a retained local prepared-text plan.
/// This check does not prove that the caller still holds the model or prompt
/// bytes; consumers that possess them must reconstruct the complete plan.
pub fn planValidV1(value: PlanV1) bool {
    return value.abi_version == plan_abi and
        value.prompt_tokens != 0 and
        value.max_new_tokens != 0 and
        value.image_identity.container_bytes != 0 and
        !isZeroDigest(value.prompt_sha256) and
        !isZeroDigest(value.image_identity.source_fingerprint) and
        !isZeroDigest(value.image_identity.abi_fingerprint) and
        !isZeroDigest(value.image_identity.container_sha256) and
        std.mem.eql(
            u8,
            &value.plan_sha256,
            &planSha256(value),
        );
}

fn artifactMetadataSha256(
    model: loader.LoadedModel,
    plan: PlanV1,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(artifact_metadata_domain);
    hashU64(&hash, prepared_artifact_profile_abi);
    hash.update(&plan.image_identity.source_fingerprint);
    hash.update(&plan.image_identity.abi_fingerprint);
    hashU64(&hash, plan.image_identity.container_bytes);
    hash.update(&plan.image_identity.container_sha256);
    hashU64(&hash, @intCast(model.config.dim));
    hashU64(&hash, @intCast(model.config.hidden_dim));
    hashU64(&hash, @intCast(model.config.num_layers));
    hashU64(&hash, @intCast(model.config.vocab_size));
    hashU64(&hash, @intCast(model.config.num_heads));
    hashU64(&hash, @intCast(model.config.head_dim));
    hashU64(&hash, @intCast(model.config.num_kv_heads));
    hashU32(&hash, @bitCast(model.config.rms_eps));
    hashU32(&hash, @bitCast(model.config.rope_theta));
    hash.update(&[_]u8{
        @intFromBool(model.config.tie_word_embeddings),
        @intFromBool(model.prepared_mlp_layout == .separate),
    });
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn cacheBundleSha256(
    model: loader.LoadedModel,
    plan: PlanV1,
) ![32]u8 {
    const max_positions = std.math.add(
        u64,
        plan.prompt_tokens,
        plan.max_new_tokens - 1,
    ) catch return Error.InvalidBoundPlan;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(cache_bundle_domain);
    hashU64(&hash, @intCast(model.config.num_layers));
    hashU64(&hash, @intCast(model.config.num_kv_heads));
    hashU64(&hash, @intCast(model.config.head_dim));
    hashU64(&hash, max_positions);
    hashU64(&hash, plan.claim.kv_bytes);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn emptyCachePayloadSha256(cache_bundle_sha256: [32]u8) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(empty_cache_payload_domain);
    hash.update(&cache_bundle_sha256);
    hashU64(&hash, 0);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn ownershipSha256(
    scheduling: SchedulingV1,
    scheduler: *const lane.Scheduler,
    request_epoch: u64,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(ownership_domain);
    hashU64(&hash, request_epoch);
    hashU64(&hash, scheduler.config.scheduler_epoch);
    hashU64(&hash, scheduler.bank_epoch);
    hashU64(&hash, scheduling.tenant_key);
    hashU64(&hash, scheduling.request_key);
    hashU64(&hash, scheduling.request_generation);
    hashU64(&hash, scheduling.resource_owner_key);
    hashU64(&hash, scheduling.weight);
    hashU64(&hash, scheduling.deadline_tick);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn inputSchemaSha256(
    model: loader.LoadedModel,
    plan: PlanV1,
    input: BoundPlanInputV1,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(input_schema_domain);
    hashU64(&hash, @sizeOf(u32));
    hashU64(&hash, plan.prompt_tokens);
    hashU64(&hash, @intCast(model.config.vocab_size));
    hash.update(&input.token_domain_sha256);
    hash.update(&input.token_domain_config_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

fn outputSchemaSha256(
    model: loader.LoadedModel,
    plan: PlanV1,
    input: BoundPlanInputV1,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(output_schema_domain);
    hashU64(&hash, @sizeOf(u32));
    hashU64(&hash, plan.max_new_tokens);
    hashU64(&hash, @intCast(model.config.vocab_size));
    hashU32(&hash, plan.eos_token);
    hash.update(&input.token_domain_sha256);
    hash.update(&input.token_domain_config_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn boundPlanRootV1(value: BoundPlanV1) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bound_plan_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.local_plan_sha256);
    hash.update(&value.artifact.artifact_sha256);
    hash.update(&value.execution.plan_sha256);
    hash.update(&value.residency.binding_sha256);
    hash.update(&value.token_domain_sha256);
    hash.update(&value.token_domain_config_sha256);
    hash.update(&value.artifact_license_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn boundaryRootV1(snapshot: BoundarySnapshotV1) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(boundary_domain);
    hashU64(&hash, snapshot.abi_version);
    hash.update(&snapshot.plan_sha256);
    hash.update(&snapshot.image_identity.source_fingerprint);
    hash.update(&snapshot.image_identity.abi_fingerprint);
    hashU64(&hash, snapshot.image_identity.container_bytes);
    hash.update(&snapshot.image_identity.container_sha256);
    hashU64(&hash, snapshot.publication.abi_version);
    hashU64(&hash, snapshot.publication.request_epoch);
    hashU64(&hash, snapshot.publication.execution_abi);
    hashU64(&hash, snapshot.publication.sequence_base);
    hashU64(&hash, snapshot.publication.next_sequence);
    hashU64(
        &hash,
        snapshot.publication.last_resource_permit_generation,
    );
    hash.update(&[_]u8{@intFromBool(snapshot.publication.terminal)});
    hash.update(&snapshot.publication.state.commitment_sha256);
    hash.update(&snapshot.publication.transcript_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn boundarySnapshotValidV1(snapshot: BoundarySnapshotV1) bool {
    if (snapshot.abi_version != session_abi or
        snapshot.image_identity.container_bytes == 0 or
        isZeroDigest(snapshot.plan_sha256) or
        isZeroDigest(snapshot.image_identity.source_fingerprint) or
        isZeroDigest(snapshot.image_identity.abi_fingerprint) or
        isZeroDigest(snapshot.image_identity.container_sha256) or
        snapshot.publication.abi_version !=
            publication.transcript_snapshot_abi or
        snapshot.publication.request_epoch == 0 or
        snapshot.publication.execution_abi != lane_contiguous.abi or
        snapshot.publication.state.execution_abi != lane_contiguous.abi or
        !publication.stateCommitmentValidV1(snapshot.publication.state) or
        snapshot.publication.sequence_base >
            snapshot.publication.next_sequence or
        snapshot.publication.next_sequence !=
            snapshot.publication.state.output_length or
        isZeroDigest(snapshot.publication.transcript_sha256))
        return false;
    const expected = boundaryRootV1(snapshot);
    return std.mem.eql(
        u8,
        &snapshot.boundary_sha256,
        &expected,
    );
}

pub fn boundaryRootV2(snapshot: BoundarySnapshotV2) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(boundary_v2_domain);
    hashU64(&hash, snapshot.abi_version);
    hash.update(&snapshot.base.boundary_sha256);
    hash.update(&snapshot.bound_plan_sha256);
    hash.update(&snapshot.artifact_sha256);
    hash.update(&snapshot.execution_plan_sha256);
    hash.update(&snapshot.residency_binding_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn boundarySnapshotValidV2(snapshot: BoundarySnapshotV2) bool {
    if (snapshot.abi_version != session_v2_abi or
        !boundarySnapshotValidV1(snapshot.base) or
        isZeroDigest(snapshot.bound_plan_sha256) or
        isZeroDigest(snapshot.artifact_sha256) or
        isZeroDigest(snapshot.execution_plan_sha256) or
        isZeroDigest(snapshot.residency_binding_sha256))
        return false;
    const expected = boundaryRootV2(snapshot);
    return std.mem.eql(u8, &snapshot.boundary_sha256, &expected);
}

/// Contextual verification for consumers that possess the bound plan. The
/// self-canonical V2 boundary alone authenticates only its own root list; this
/// check joins that list back to the canonical plan and prepared image.
pub fn boundarySnapshotValidForBoundPlanV2(
    snapshot: BoundarySnapshotV2,
    bound_plan: BoundPlanV1,
    local_plan: PlanV1,
) bool {
    if (!boundarySnapshotValidV2(snapshot))
        return false;
    validateBoundPlanV1(bound_plan) catch return false;
    if (!planValidV1(local_plan))
        return false;
    return std.mem.eql(
        u8,
        &snapshot.bound_plan_sha256,
        &bound_plan.bound_plan_sha256,
    ) and
        std.mem.eql(
            u8,
            &snapshot.artifact_sha256,
            &bound_plan.artifact.artifact_sha256,
        ) and
        std.mem.eql(
            u8,
            &snapshot.execution_plan_sha256,
            &bound_plan.execution.plan_sha256,
        ) and
        std.mem.eql(
            u8,
            &snapshot.residency_binding_sha256,
            &bound_plan.residency.binding_sha256,
        ) and
        std.mem.eql(
            u8,
            &snapshot.base.plan_sha256,
            &local_plan.plan_sha256,
        ) and
        std.mem.eql(
            u8,
            &bound_plan.local_plan_sha256,
            &local_plan.plan_sha256,
        ) and
        std.meta.eql(
            snapshot.base.image_identity,
            local_plan.image_identity,
        ) and
        std.meta.eql(
            bound_plan.residency.request_claim,
            local_plan.claim,
        ) and
        @as(u64, local_plan.eos_token) >
            bound_plan.execution.maximum_absolute_output and
        std.mem.eql(
            u8,
            &snapshot.base.image_identity.container_sha256,
            &bound_plan.artifact.weights_sha256,
        ) and
        snapshot.base.image_identity.container_bytes ==
            bound_plan.artifact.weight_bytes and
        bound_plan.artifact.input_features ==
            local_plan.prompt_tokens and
        bound_plan.artifact.output_dimensions ==
            local_plan.max_new_tokens and
        std.mem.eql(
            u8,
            &bound_plan.execution.media_object_sha256,
            &local_plan.prompt_sha256,
        ) and
        snapshot.base.publication.request_epoch ==
            bound_plan.execution.request_epoch and
        snapshot.base.publication.sequence_base ==
            bound_plan.execution.publication_next_sequence;
}

/// Canonical terminal token-sequence root. Token ids are hashed as explicit
/// little-endian u32 values and remain bound to the exact execution and token
/// domain rather than to host memory representation.
pub fn terminalOutputRootV1(
    bound_plan: BoundPlanV1,
    output_tokens: []const u32,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(terminal_output_domain);
    hash.update(&bound_plan.execution.plan_sha256);
    hash.update(&bound_plan.token_domain_sha256);
    hash.update(&bound_plan.token_domain_config_sha256);
    hashU64(&hash, @intCast(output_tokens.len));
    for (output_tokens) |token| hashU32(&hash, token);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Bind each terminal token sequence to the exact contiguous-publication
/// transcript and V2 boundary that made it visible.
pub fn terminalSourceMappingRootV1(
    bound_plan: BoundPlanV1,
    boundary: BoundarySnapshotV2,
    output_sha256: [32]u8,
    output_tokens: u64,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(terminal_source_mapping_domain);
    hash.update(&bound_plan.bound_plan_sha256);
    hash.update(&boundary.boundary_sha256);
    hash.update(&boundary.base.publication.transcript_sha256);
    hash.update(&output_sha256);
    hashU64(&hash, output_tokens);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Experimental implementation identity for the retained serial prepared-text
/// adapter. This is not a stable package or tokenizer identity.
pub fn terminalAdapterRootV1(
    bound_plan: BoundPlanV1,
    local_plan: PlanV1,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(terminal_adapter_domain);
    hashU64(&hash, session_v3_abi);
    hashU64(&hash, prepared_artifact_profile_abi);
    hashU64(&hash, @intFromEnum(bound_plan.execution.family));
    hashU64(&hash, @intFromEnum(bound_plan.execution.operation));
    hashU64(&hash, @intFromEnum(bound_plan.execution.input_kind));
    hashU64(&hash, @intFromEnum(bound_plan.execution.output_kind));
    hashU64(
        &hash,
        @intFromEnum(bound_plan.execution.numerical_policy),
    );
    hash.update(&bound_plan.artifact.metadata_sha256);
    hash.update(&local_plan.image_identity.source_fingerprint);
    hash.update(&local_plan.image_identity.abi_fingerprint);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn terminalResultEvidenceRootV1(
    evidence: TerminalResultEvidenceV1,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(terminal_result_evidence_domain);
    hashU64(&hash, evidence.abi_version);
    hash.update(&evidence.boundary.boundary_sha256);
    hash.update(&evidence.result.result_sha256);
    hash.update(&evidence.publication_state_after_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

/// Contextual verification for the direct R1d evidence grouping. The caller
/// supplies the expected bound/local plans and the exact token payload whose
/// canonical digest is carried by the portable ResultEnvelope. Receipt fields
/// are structurally checked from the envelope itself; consumers retaining an
/// independent receipt should additionally use
/// `terminalResultEvidenceValidForReceiptV1`.
pub fn terminalResultEvidenceValidV1(
    evidence: TerminalResultEvidenceV1,
    bound_plan: BoundPlanV1,
    local_plan: PlanV1,
    output_tokens: []const u32,
) bool {
    if (evidence.abi_version != terminal_result_evidence_abi or
        !boundarySnapshotValidForBoundPlanV2(
            evidence.boundary,
            bound_plan,
            local_plan,
        ) or
        @as(u64, @intCast(output_tokens.len)) !=
            local_plan.max_new_tokens or
        evidence.boundary.base.publication.next_sequence !=
            local_plan.max_new_tokens or
        evidence.boundary.base.publication.state.output_length !=
            local_plan.max_new_tokens or
        !evidence.boundary.base.publication.terminal)
        return false;
    for (output_tokens) |token| {
        if (@as(u64, token) >
            bound_plan.execution.maximum_absolute_output)
            return false;
    }
    model_contract.validateExecutionResidencyResultV1(
        bound_plan.execution,
        bound_plan.residency,
        evidence.result,
    ) catch return false;

    const output_sha256 = terminalOutputRootV1(
        bound_plan,
        output_tokens,
    );
    const source_mapping_sha256 = terminalSourceMappingRootV1(
        bound_plan,
        evidence.boundary,
        output_sha256,
        @intCast(output_tokens.len),
    );
    const adapter_sha256 = terminalAdapterRootV1(
        bound_plan,
        local_plan,
    );
    if (!std.mem.eql(
        u8,
        &evidence.result.output_sha256,
        &output_sha256,
    ) or
        !std.mem.eql(
            u8,
            &evidence.result.source_mapping_sha256,
            &source_mapping_sha256,
        ) or
        !std.mem.eql(
            u8,
            &evidence.result.adapter_sha256,
            &adapter_sha256,
        ))
        return false;

    const initial_state = model_contract.initializePublicationStateV1(
        bound_plan.execution.request_epoch,
        bound_plan.artifact.artifact_sha256,
    ) catch return false;
    const receipt_slot_index = std.math.cast(
        u32,
        evidence.result.resource_slot_index,
    ) orelse return false;
    const receipt: resource_bank.Receipt = .{
        .bank_epoch = evidence.result.resource_bank_epoch,
        .slot_index = receipt_slot_index,
        .generation = evidence.result.resource_generation,
        .owner_key = evidence.result.resource_owner_key,
        .claim = evidence.result.claim,
        .integrity = evidence.result.resource_integrity,
    };
    model_contract.validateResidencyResultEnvelopeV1(
        initial_state,
        bound_plan.execution,
        bound_plan.residency,
        receipt,
        evidence.result,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    ) catch return false;
    const initial_root = model_contract.publicationStateRootV1(
        initial_state,
    ) catch return false;
    const state_after_root = model_contract.publicationStateRootV1(
        evidence.publication_state_after,
    ) catch return false;
    const expected_next_sequence = std.math.add(
        u64,
        bound_plan.execution.publication_next_sequence,
        1,
    ) catch return false;
    if (!std.mem.eql(
        u8,
        &evidence.result.publication_state_before_sha256,
        &initial_root,
    ) or
        evidence.publication_state_after.request_epoch !=
            bound_plan.execution.request_epoch or
        evidence.publication_state_after.next_sequence !=
            expected_next_sequence or
        evidence.publication_state_after.visible_results != 1 or
        !std.mem.eql(
            u8,
            &evidence.publication_state_after.artifact_sha256,
            &bound_plan.artifact.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &evidence.publication_state_after.previous_result_sha256,
            &evidence.result.result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &evidence.publication_state_after_sha256,
            &state_after_root,
        ))
        return false;

    const expected_evidence = terminalResultEvidenceRootV1(evidence);
    return std.mem.eql(
        u8,
        &evidence.evidence_sha256,
        &expected_evidence,
    );
}

/// Bind otherwise self-contained terminal evidence to one independently
/// retained Receipt. This proves exact receipt-field equality and structural
/// integrity, but only the live Bank check inside `SessionV3.sealTerminalResult`
/// proves that the receipt is still committed to that publication session.
pub fn terminalResultEvidenceValidForReceiptV1(
    evidence: TerminalResultEvidenceV1,
    bound_plan: BoundPlanV1,
    local_plan: PlanV1,
    output_tokens: []const u32,
    expected_receipt: resource_bank.Receipt,
) bool {
    if (!terminalResultEvidenceValidV1(
        evidence,
        bound_plan,
        local_plan,
        output_tokens,
    ))
        return false;
    const initial_state = model_contract.initializePublicationStateV1(
        bound_plan.execution.request_epoch,
        bound_plan.artifact.artifact_sha256,
    ) catch return false;
    const output_sha256 = terminalOutputRootV1(
        bound_plan,
        output_tokens,
    );
    const source_mapping_sha256 = terminalSourceMappingRootV1(
        bound_plan,
        evidence.boundary,
        output_sha256,
        @intCast(output_tokens.len),
    );
    const adapter_sha256 = terminalAdapterRootV1(
        bound_plan,
        local_plan,
    );
    model_contract.validateResidencyResultEnvelopeV1(
        initial_state,
        bound_plan.execution,
        bound_plan.residency,
        expected_receipt,
        evidence.result,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    ) catch return false;
    return true;
}

fn isZeroDigest(digest: [32]u8) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

pub fn makePlanV1(
    model: loader.LoadedModel,
    prompt: []const u32,
    options: OptionsV1,
) (generate.GenerateError || Error)!PlanV1 {
    if (options.max_new_tokens == 0)
        return Error.InvalidConfiguration;
    // V1 retires only after the admission's fixed service count is exhausted.
    // Early EOS therefore remains outside this exact lifecycle contract.
    if (options.eos_token < model.config.vocab_size)
        return Error.InvalidConfiguration;
    if (model.prepared_mlp_layout != .separate)
        return Error.InvalidConfiguration;
    const image = model.prepared_image orelse
        return Error.PreparedImageRequired;
    const image_identity = image.identityV1();
    if (isZeroDigest(image_identity.source_fingerprint) or
        !std.mem.eql(
            u8,
            &image_identity.source_fingerprint,
            &model.source_fingerprint,
        )) return Error.InvalidConfiguration;

    const max_new_tokens = std.math.cast(
        u64,
        options.max_new_tokens,
    ) orelse return generate.GenerateError.ContextTooLong;
    var claim = try generate.deriveResourceClaim(
        model,
        prompt,
        options.generateOptions(),
    );
    claim.output_journal_bytes = std.math.mul(
        u64,
        max_new_tokens,
        @sizeOf(u32),
    ) catch return generate.GenerateError.ContextTooLong;
    var plan: PlanV1 = .{
        .image_identity = image_identity,
        .prompt_tokens = @intCast(prompt.len),
        .prompt_sha256 = promptSha256(prompt),
        .max_new_tokens = max_new_tokens,
        .eos_token = options.eos_token,
        .seed = options.seed,
        .claim = claim,
        .plan_sha256 = undefined,
    };
    plan.plan_sha256 = planSha256(plan);
    return plan;
}

fn totalLogicalClaim(
    request_claim: resource_bank.Claim,
    shared_artifact_bytes: u64,
) !resource_bank.Claim {
    var total = request_claim;
    total.capsule_bytes = std.math.add(
        u64,
        request_claim.capsule_bytes,
        shared_artifact_bytes,
    ) catch return Error.InvalidBoundPlan;
    return total;
}

/// Construct the exact common-plan bridge for one pre-tokenized request
/// profile. The artifact manifest is intentionally request-profile-specific:
/// its root varies with prompt and output dimensions, while
/// `weights_sha256` remains the exact mapped `.glrt` container digest.
pub fn makeBoundPlanV1(
    model: loader.LoadedModel,
    prompt: []const u32,
    options: OptionsV1,
    local_plan: PlanV1,
    scheduling: SchedulingV1,
    scheduler: *const lane.Scheduler,
    input: BoundPlanInputV1,
) !BoundPlanV1 {
    const expected_local = try makePlanV1(model, prompt, options);
    if (!std.meta.eql(expected_local, local_plan) or
        input.request_epoch == 0 or
        isZeroDigest(input.token_domain_sha256) or
        isZeroDigest(input.token_domain_config_sha256) or
        isZeroDigest(input.artifact_license_sha256) or
        scheduling.tenant_key == 0 or scheduling.request_key == 0 or
        scheduling.request_generation == 0 or
        scheduling.resource_owner_key == 0 or scheduling.weight == 0)
        return Error.InvalidBoundPlan;
    if (local_plan.prompt_tokens == 0 or model.config.vocab_size <= 1)
        return Error.InvalidBoundPlan;

    const metadata_sha256 = artifactMetadataSha256(model, local_plan);
    const artifact =
        model_contract.makeArtifactManifestFromDigestV1(
            .autoregressive,
            prepared_artifact_profile_abi,
            .token_ids,
            .token_ids,
            .implementation_defined,
            1,
            local_plan.prompt_tokens,
            local_plan.max_new_tokens,
            @sizeOf(u32),
            @sizeOf(u32),
            1,
            local_plan.image_identity.container_bytes,
            local_plan.image_identity.container_sha256,
            metadata_sha256,
            input.artifact_license_sha256,
        ) catch return Error.InvalidBoundPlan;
    const cache_bundle_sha256 =
        try cacheBundleSha256(model, local_plan);
    const total_claim = try totalLogicalClaim(
        local_plan.claim,
        local_plan.image_identity.container_bytes,
    );
    const execution = model_contract.makeExecutionPlanV1(
        artifact,
        .generate_sequence,
        .{
            .request_epoch = input.request_epoch,
            .generation = scheduling.request_generation,
            .batch_items = 1,
            .publication_next_sequence = 0,
            .maximum_absolute_output = @intCast(model.config.vocab_size - 1),
            .claim = total_claim,
            .media_object_sha256 = local_plan.prompt_sha256,
            .processor_state_sha256 = input.token_domain_sha256,
            .processor_bundle_sha256 = input.token_domain_config_sha256,
            .cache_bundle_sha256 = cache_bundle_sha256,
            .cache_payload_sha256 = emptyCachePayloadSha256(cache_bundle_sha256),
            .ownership_sha256 = ownershipSha256(
                scheduling,
                scheduler,
                input.request_epoch,
            ),
            .challenge_sha256 = scheduler.config.challenge,
            .previous_plan_sha256 = input.previous_plan_sha256,
            .input_schema_sha256 = inputSchemaSha256(model, local_plan, input),
            .output_schema_sha256 = outputSchemaSha256(model, local_plan, input),
            .scratch_bytes = local_plan.claim.partial_bytes,
        },
    ) catch return Error.InvalidBoundPlan;
    const residency =
        model_contract.makeExecutionResidencyBindingV1(
            execution,
            .shared_read_only,
            local_plan.image_identity.container_bytes,
            local_plan.claim,
        ) catch return Error.InvalidBoundPlan;
    var value: BoundPlanV1 = .{
        .local_plan_sha256 = local_plan.plan_sha256,
        .artifact = artifact,
        .execution = execution,
        .residency = residency,
        .token_domain_sha256 = input.token_domain_sha256,
        .token_domain_config_sha256 = input.token_domain_config_sha256,
        .artifact_license_sha256 = input.artifact_license_sha256,
        .bound_plan_sha256 = [_]u8{0} ** 32,
    };
    value.bound_plan_sha256 = boundPlanRootV1(value);
    try validateBoundPlanV1(value);
    return value;
}

pub fn validateBoundPlanV1(value: BoundPlanV1) !void {
    var artifact_wire: [model_contract.artifact_manifest_bytes]u8 =
        undefined;
    model_contract.encodeArtifactManifestV1(
        value.artifact,
        &artifact_wire,
    ) catch return Error.InvalidBoundPlan;
    if (!std.meta.eql(
        value.artifact,
        model_contract.decodeArtifactManifestV1(&artifact_wire) catch
            return Error.InvalidBoundPlan,
    )) return Error.InvalidBoundPlan;

    var execution_wire: [model_contract.execution_plan_bytes]u8 =
        undefined;
    model_contract.encodeExecutionPlanV1(
        value.execution,
        &execution_wire,
    ) catch return Error.InvalidBoundPlan;
    if (!std.meta.eql(
        value.execution,
        model_contract.decodeExecutionPlanV1(&execution_wire) catch
            return Error.InvalidBoundPlan,
    )) return Error.InvalidBoundPlan;
    model_contract.validateExecutionResidencyBindingV1(
        value.residency,
        value.execution,
    ) catch return Error.InvalidBoundPlan;

    if (value.abi_version != bound_plan_abi or
        value.artifact.artifact_abi !=
            prepared_artifact_profile_abi or
        value.artifact.max_batch_items != 1 or
        value.execution.family != .autoregressive or
        value.execution.operation != .generate_sequence or
        value.execution.input_kind != .token_ids or
        value.execution.output_kind != .token_ids or
        value.execution.numerical_policy != .implementation_defined or
        value.execution.batch_items != 1 or
        value.execution.required_capabilities !=
            model_contract.no_capabilities or
        value.residency.residency != .shared_read_only or
        value.artifact.family != value.execution.family or
        value.artifact.input_kind != value.execution.input_kind or
        value.artifact.output_kind != value.execution.output_kind or
        value.artifact.numerical_policy !=
            value.execution.numerical_policy or
        value.artifact.input_features !=
            value.execution.input_features or
        value.artifact.output_dimensions !=
            value.execution.output_dimensions or
        value.artifact.input_element_bytes != @sizeOf(u32) or
        value.artifact.output_element_bytes != @sizeOf(u32) or
        value.execution.input_element_bytes != @sizeOf(u32) or
        value.execution.output_element_bytes != @sizeOf(u32) or
        value.artifact.input_element_bytes !=
            value.execution.input_element_bytes or
        value.artifact.output_element_bytes !=
            value.execution.output_element_bytes or
        value.artifact.weight_bytes != value.execution.weight_bytes or
        value.artifact.weight_element_bytes != 1 or
        value.execution.scratch_bytes !=
            value.residency.request_claim.partial_bytes or
        isZeroDigest(value.local_plan_sha256) or
        isZeroDigest(value.token_domain_sha256) or
        isZeroDigest(value.token_domain_config_sha256) or
        isZeroDigest(value.artifact_license_sha256) or
        !std.mem.eql(
            u8,
            &value.execution.artifact_sha256,
            &value.artifact.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &value.execution.weights_sha256,
            &value.artifact.weights_sha256,
        ) or
        !std.mem.eql(
            u8,
            &value.execution.processor_state_sha256,
            &value.token_domain_sha256,
        ) or
        !std.mem.eql(
            u8,
            &value.execution.processor_bundle_sha256,
            &value.token_domain_config_sha256,
        ) or
        !std.mem.eql(
            u8,
            &value.artifact.license_sha256,
            &value.artifact_license_sha256,
        ) or
        !std.mem.eql(
            u8,
            &value.bound_plan_sha256,
            &boundPlanRootV1(value),
        ))
        return Error.InvalidBoundPlan;
}

/// Rebind one already-verified R1g successor execution/residency pair to the
/// immutable prepared artifact and token-domain metadata retained by its
/// source BoundPlan. The resulting root is local process state; portable
/// verification remains on the canonical successor wires.
pub fn deriveSuccessorBoundPlanV1(
    source: BoundPlanV1,
    artifacts: prepared_successor.ArtifactsV1,
) !BoundPlanV1 {
    try validateBoundPlanV1(source);
    if (!std.mem.eql(
        u8,
        &artifacts.successor_plan.previous_plan_sha256,
        &source.execution.plan_sha256,
    ) or artifacts.successor_plan.publication_next_sequence == 0 or
        artifacts.successor_plan.generation <= source.execution.generation or
        !std.mem.eql(
            u8,
            &artifacts.successor_plan.artifact_sha256,
            &source.artifact.artifact_sha256,
        ) or !std.meta.eql(
        artifacts.successor_residency.request_claim,
        source.residency.request_claim,
    ))
        return Error.InvalidBoundPlan;
    var result: BoundPlanV1 = .{
        .local_plan_sha256 = source.local_plan_sha256,
        .artifact = source.artifact,
        .execution = artifacts.successor_plan,
        .residency = artifacts.successor_residency,
        .token_domain_sha256 = source.token_domain_sha256,
        .token_domain_config_sha256 = source.token_domain_config_sha256,
        .artifact_license_sha256 = source.artifact_license_sha256,
        .bound_plan_sha256 = undefined,
    };
    result.bound_plan_sha256 = boundPlanRootV1(result);
    try validateBoundPlanV1(result);
    return result;
}

fn validateAdmissionForAdoption(
    scheduler: *lane.Scheduler,
    bank: *resource_bank.Bank,
    admission: lane.Admission,
    plan: PlanV1,
    request_epoch: u64,
) (Error || lane.Error)!void {
    if (request_epoch == 0 or scheduler.bank != bank)
        return Error.InvalidAdmission;
    const snapshot = try scheduler.snapshot();
    const event = admission.event;
    if (snapshot.closed or snapshot.poisoned or
        event.abi_version != lane.event_abi or
        event.kind != .admission_accepted or
        event.rejection_reason != .none or
        event.scheduler_epoch != snapshot.scheduler_epoch or
        event.event_sequence == std.math.maxInt(u64) or
        event.event_sequence + 1 != snapshot.next_event_sequence or
        !std.meta.eql(admission.handle, event.handle) or
        !std.meta.eql(plan.claim, event.spec.claim) or
        !std.meta.eql(plan.claim, event.resource_receipt.claim) or
        event.spec.work_quanta != plan.max_new_tokens or
        event.remaining_after != plan.max_new_tokens)
        return Error.InvalidAdmission;
    const expected_receipt = lane.resourceReceiptSha256(
        event.resource_receipt,
    );
    const expected_event = lane.eventSha256(event);
    if (!std.mem.eql(
        u8,
        &event.resource_receipt_sha256,
        &expected_receipt,
    ) or
        !std.mem.eql(u8, &event.event_sha256, &expected_event) or
        !std.mem.eql(
            u8,
            &event.event_sha256,
            &snapshot.chain_head_sha256,
        ))
        return Error.InvalidAdmission;
    bank.validateCommitted(event.resource_receipt) catch
        return Error.InvalidAdmission;
}

const Resources = struct {
    allocator: std.mem.Allocator,
    cache: kv.KVCache,
    output: []u32,
    x_row: tensor.Tensor,
    logits: tensor.Tensor,
    buffers: decode_buffers.DecodeBuffers,
    rope_table: generate.PreparedTextRopeTableV1,

    fn init(
        allocator: std.mem.Allocator,
        model: loader.LoadedModel,
        max_kv_positions: usize,
        max_new_tokens: usize,
    ) generate.GenerateError!Resources {
        const cfg = model.config;
        const kv_dim = std.math.mul(
            usize,
            cfg.num_kv_heads,
            cfg.head_dim,
        ) catch return generate.GenerateError.ShapeMismatch;
        var cache = kv.KVCache.init(
            allocator,
            cfg.num_layers,
            kv_dim,
            max_kv_positions,
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer cache.deinit();
        const output = allocator.alloc(u32, max_new_tokens) catch
            return generate.GenerateError.OutOfMemory;
        errdefer allocator.free(output);
        var x_row = tensor.zerosF32(
            allocator,
            &.{ 1, cfg.dim },
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer x_row.deinit();
        var logits = tensor.zerosF32(
            allocator,
            &.{ 1, cfg.vocab_size },
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer logits.deinit();
        var buffers = decode_buffers.DecodeBuffers.initWithFrame(
            allocator,
            cfg.num_layers,
            cfg.dim,
            kv_dim,
            cfg.hidden_dim,
            .materialized,
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer buffers.deinit();
        var rope_table = generate.PreparedTextRopeTableV1.init(
            allocator,
            max_kv_positions,
            cfg.head_dim,
            cfg.rope_theta,
        ) catch return generate.GenerateError.OutOfMemory;
        errdefer rope_table.deinit();
        return .{
            .allocator = allocator,
            .cache = cache,
            .output = output,
            .x_row = x_row,
            .logits = logits,
            .buffers = buffers,
            .rope_table = rope_table,
        };
    }

    fn initRestored(
        allocator: std.mem.Allocator,
        model: loader.LoadedModel,
        decoded: prepared_checkpoint.DecodedV1,
    ) !Resources {
        const cfg = model.config;
        const expected_kv_dim = std.math.mul(
            usize,
            cfg.num_kv_heads,
            cfg.head_dim,
        ) catch return Error.InvalidState;
        if (decoded.num_layers != cfg.num_layers or
            decoded.kv_dim != expected_kv_dim or
            decoded.vocab_size != cfg.vocab_size or
            decoded.output_count == 0 or
            decoded.output_count != decoded.sampling_calls)
            return Error.InvalidState;
        var resources = try Resources.init(
            allocator,
            model,
            decoded.max_kv_positions,
            decoded.max_new_tokens,
        );
        errdefer resources.deinit();
        try prepared_checkpoint.materializeIntoV1(
            decoded,
            &resources.cache,
            resources.output,
        );
        return resources;
    }

    fn deinit(self: *Resources) void {
        self.rope_table.deinit();
        self.buffers.deinit();
        self.logits.deinit();
        self.x_row.deinit();
        self.allocator.free(self.output);
        self.cache.deinit();
    }
};

/// Address-stable persistent session. Place it at its final address before
/// calling `start` or `init`; the concrete publication adapter binds its field
/// addresses. Do not move, copy, or concurrently access it until the active
/// lifecycle, including any start-adoption recovery, has ended.
pub const SessionV1 = struct {
    model: *const loader.LoadedModel = undefined,
    scheduler: *lane.Scheduler = undefined,
    plan: PlanV1 = undefined,
    options: OptionsV1 = undefined,
    resources: Resources = undefined,
    publication_session: lane_contiguous.Session = .{},
    output_len: usize = 0,
    rng_state: lane_contiguous.RngState = [_]u64{0} ** 4,
    sampling_calls: u64 = 0,
    resources_initialized: bool = false,
    publication_bound: bool = false,
    finished: bool = false,
    recovery_adoption: ?lane.PublicationAdoptionV1 = null,

    /// Atomically admit and adopt one exact plan. The Scheduler installs a
    /// global adoption barrier before any charged runtime allocation, so no
    /// competing Scheduler transition can split admission from publication
    /// binding. Initialization failure normally consumes the authority through
    /// an accepted-to-cancel transition and releases the full claim. If that
    /// cleanup itself returns an error, the Session retains the exact authority
    /// and reports `RecoveryRequired`.
    ///
    /// The barrier deliberately remains active during allocation and prefill;
    /// other callers of the same Scheduler receive `AdoptionInFlight` until
    /// this method commits or cancels the adoption.
    pub fn start(
        self: *SessionV1,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        plan: PlanV1,
        scheduling: SchedulingV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        request_epoch: u64,
    ) !StartDecisionV1 {
        if (self.resources_initialized or self.publication_bound or
            self.recovery_adoption != null)
            return Error.InvalidState;
        const expected = try makePlanV1(model.*, prompt, options);
        if (!std.meta.eql(expected, plan))
            return Error.InvalidPlan;
        if (scheduler.bank != bank)
            return Error.InvalidAdmission;
        const max_kv_positions = std.math.add(
            usize,
            prompt.len,
            options.max_new_tokens - 1,
        ) catch return generate.GenerateError.ContextTooLong;

        const decision = try scheduler.admitForPublicationAdoption(
            scheduling.requestSpec(plan),
            request_epoch,
            @intFromPtr(&self.publication_session.inner),
        );
        const adoption = switch (decision) {
            .rejected => |event| return .{ .rejected = event },
            .adopted => |value| value,
        };

        self.initializeAdopting(
            allocator,
            model,
            prompt,
            options,
            plan,
            scheduler,
            bank,
            adoption,
            max_kv_positions,
        ) catch |err| {
            _ = scheduler.cancelPublicationAdoption(adoption) catch {
                self.* = .{
                    .scheduler = scheduler,
                    .recovery_adoption = adoption,
                };
                return Error.RecoveryRequired;
            };
            return err;
        };
        return .{ .started = adoption.admission.event };
    }

    fn initializeAdopting(
        self: *SessionV1,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        plan: PlanV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        adoption: lane.PublicationAdoptionV1,
        max_kv_positions: usize,
    ) !void {
        const resources = try Resources.init(
            allocator,
            model.*,
            max_kv_positions,
            options.max_new_tokens,
        );
        const initial_prng = std.Random.DefaultPrng.init(options.seed);
        self.* = .{
            .model = model,
            .scheduler = scheduler,
            .plan = plan,
            .options = options,
            .resources = resources,
            .rng_state = initial_prng.s,
            .resources_initialized = true,
            .publication_bound = true,
        };
        errdefer {
            self.resources.deinit();
            self.* = .{};
        }

        try self.prefill(prompt);
        try self.publication_session.initAdopting(
            scheduler,
            bank,
            adoption,
            .{
                .cache = &self.resources.cache,
                .rng_state = &self.rng_state,
                .sampling_calls = &self.sampling_calls,
                .output = self.resources.output,
                .output_len = &self.output_len,
            },
        );
    }

    fn initializeRestoredAdopting(
        self: *SessionV1,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        plan: PlanV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        adoption: lane.PublicationAdoptionV1,
        tree: resource_bank.LeaseTreeV1,
        batch: resource_bank.LeaseAllocationBatchV1,
        decoded: prepared_checkpoint.DecodedV1,
        restored: publication.TranscriptSnapshotV1,
    ) !void {
        if (self.resources_initialized or self.publication_bound or
            self.recovery_adoption != null)
            return Error.InvalidState;
        const expected = try makePlanV1(model.*, prompt, options);
        const expected_max_kv_positions = std.math.add(
            usize,
            prompt.len,
            options.max_new_tokens - 1,
        ) catch return generate.GenerateError.ContextTooLong;
        if (!std.meta.eql(expected, plan) or
            scheduler.bank != bank or
            !std.meta.eql(plan.claim, adoption.admission.event.spec.claim) or
            !std.mem.eql(
                u8,
                &decoded.local_plan_sha256,
                &plan.plan_sha256,
            ) or decoded.prompt_tokens != prompt.len or
            decoded.max_new_tokens != options.max_new_tokens or
            decoded.max_kv_positions != expected_max_kv_positions or
            decoded.publication_next_sequence != restored.next_sequence or
            decoded.output_count != restored.next_sequence or
            decoded.sampling_calls != restored.state.sampling_calls or
            restored.sequence_base != restored.next_sequence or
            restored.request_epoch != adoption.publication_request_epoch or
            !std.mem.eql(
                u8,
                &decoded.transcript_sha256,
                &restored.transcript_sha256,
            ) or !std.mem.eql(
            u8,
            &decoded.state_commitment_sha256,
            &restored.state.commitment_sha256,
        ))
            return Error.InvalidState;

        const resources = try Resources.initRestored(
            allocator,
            model.*,
            decoded,
        );
        self.* = .{
            .model = model,
            .scheduler = scheduler,
            .plan = plan,
            .options = options,
            .resources = resources,
            .output_len = decoded.output_count,
            .rng_state = decoded.rng_state,
            .sampling_calls = decoded.sampling_calls,
            .resources_initialized = true,
            .publication_bound = true,
        };
        errdefer {
            self.resources.deinit();
            self.* = .{};
        }

        try self.publication_session
            .initRestoredAdoptingWithFundedLeaseTree(
            scheduler,
            bank,
            adoption,
            tree,
            batch,
            restored,
            decoded.logical_kv_sha256,
            .{
                .cache = &self.resources.cache,
                .rng_state = &self.rng_state,
                .sampling_calls = &self.sampling_calls,
                .output = self.resources.output,
                .output_len = &self.output_len,
            },
        );
    }

    /// Adopt the exact just-admitted request. From `Scheduler.admit` through
    /// this call's return, the caller must not make another public call on the
    /// same Scheduler, including from another thread. This preserves the
    /// Scheduler's admission-event-to-publication-binding boundary and makes
    /// failure cleanup unambiguous. Normal shared Scheduler use may resume
    /// after this call succeeds.
    pub fn init(
        self: *SessionV1,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        plan: PlanV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        admission: lane.Admission,
        request_epoch: u64,
    ) !void {
        if (self.resources_initialized or self.publication_bound or
            self.recovery_adoption != null)
            return Error.InvalidState;
        const expected = try makePlanV1(model.*, prompt, options);
        if (!std.meta.eql(expected, plan))
            return Error.InvalidPlan;
        if (!std.meta.eql(plan.claim, admission.event.spec.claim))
            return Error.AdmissionClaimMismatch;
        try validateAdmissionForAdoption(
            scheduler,
            bank,
            admission,
            plan,
            request_epoch,
        );
        var admission_adopted = true;
        errdefer if (admission_adopted) {
            _ = scheduler.cancel(admission.handle) catch
                @panic("prepared text admission cleanup failed");
        };

        const max_kv_positions = std.math.add(
            usize,
            prompt.len,
            options.max_new_tokens - 1,
        ) catch return generate.GenerateError.ContextTooLong;
        const resources = try Resources.init(
            allocator,
            model.*,
            max_kv_positions,
            options.max_new_tokens,
        );
        const initial_prng = std.Random.DefaultPrng.init(options.seed);
        self.* = .{
            .model = model,
            .scheduler = scheduler,
            .plan = plan,
            .options = options,
            .resources = resources,
            .rng_state = initial_prng.s,
            .resources_initialized = true,
        };
        errdefer {
            self.resources.deinit();
            self.* = .{};
        }

        try self.prefill(prompt);
        try self.publication_session.init(
            scheduler,
            bank,
            admission,
            request_epoch,
            .{
                .cache = &self.resources.cache,
                .rng_state = &self.rng_state,
                .sampling_calls = &self.sampling_calls,
                .output = self.resources.output,
                .output_len = &self.output_len,
            },
        );
        self.publication_bound = true;
        admission_adopted = false;
    }

    /// Retry the exact accepted-to-cancel cleanup retained after `start`
    /// reports `RecoveryRequired`. This method does not diagnose or repair the
    /// condition that prevented the original cancellation.
    pub fn recoverStartAdoption(self: *SessionV1) !lane.EventV1 {
        const adoption = self.recovery_adoption orelse
            return Error.InvalidState;
        if (self.resources_initialized or self.publication_bound)
            return Error.InvalidState;
        const event = try self.scheduler.cancelPublicationAdoption(adoption);
        self.* = .{};
        return event;
    }

    pub fn deinit(self: *SessionV1) void {
        if (self.recovery_adoption != null) {
            _ = self.recoverStartAdoption() catch
                @panic("prepared text adoption recovery failed");
            return;
        }
        if (!self.resources_initialized) return;
        if (self.publication_bound) {
            self.publication_session.close() catch
                @panic("prepared text session failed to close");
            self.publication_bound = false;
        }
        self.resources.deinit();
        self.* = .{};
    }

    pub fn step(
        self: *SessionV1,
        permit: lane.ServicePermitV1,
        downstream: publication.SinkV1,
    ) !publication.CommitReceiptV1 {
        if (!self.resources_initialized or
            !self.publication_bound or self.finished)
            return Error.InvalidState;

        const stage = self.prepareStage() catch |err| {
            self.scheduler.abortService(permit) catch
                return Error.RecoveryRequired;
            return err;
        };
        const receipt = try self.publication_session.publish(
            permit,
            stage,
            downstream,
        );
        self.finished = stage.terminal;
        return receipt;
    }

    /// Prepare all fallible numerical state before publication adopts the
    /// service permit. On failure, `step` aborts that still-pending permit;
    /// after success the contiguous publication transaction owns both the
    /// permit and any staged KV row.
    fn prepareStage(self: *SessionV1) !lane_contiguous.StageV1 {
        var mark: ?kv.RowTxnMark = null;
        if (self.output_len != 0) {
            const active_mark = try self.resources.cache.beginRows(1);
            mark = active_mark;
            errdefer self.resources.cache.abortRows(active_mark) catch {};
            try self.decodeCommittedTail(active_mark);
        }
        const sampled = try self.sampleCurrentLogits();
        const terminal = sampled.token_id == self.options.eos_token or
            self.output_len + 1 == self.options.max_new_tokens;
        return .{
            .kv_mark = mark,
            .rng_after = sampled.rng_after,
            .sampling_calls_after = sampled.sampling_calls_after,
            .token_id = sampled.token_id,
            .terminal = terminal,
        };
    }

    pub fn outputTokens(self: *const SessionV1) []const u32 {
        if (!self.resources_initialized) return &.{};
        return self.resources.output[0..self.output_len];
    }

    pub fn isFinished(self: *const SessionV1) bool {
        return self.finished;
    }

    pub fn snapshotVerified(self: *SessionV1) !BoundarySnapshotV1 {
        if (!self.resources_initialized or
            !self.publication_bound)
            return Error.InvalidState;
        var snapshot: BoundarySnapshotV1 = .{
            .plan_sha256 = self.plan.plan_sha256,
            .image_identity = self.plan.image_identity,
            .publication = try self.publication_session.snapshotVerified(),
            .boundary_sha256 = [_]u8{0} ** 32,
        };
        snapshot.boundary_sha256 = boundaryRootV1(snapshot);
        if (!boundarySnapshotValidV1(snapshot))
            return Error.InvalidState;
        return snapshot;
    }

    pub fn retire(self: *SessionV1) !lane.EventV1 {
        if (!self.resources_initialized or
            !self.publication_bound or !self.finished)
            return Error.InvalidState;
        const event = try self.publication_session.retire();
        self.publication_bound = false;
        return event;
    }

    pub fn cancel(self: *SessionV1) !lane.EventV1 {
        if (!self.resources_initialized or
            !self.publication_bound or self.finished)
            return Error.InvalidState;
        const event = try self.publication_session.cancel();
        self.publication_bound = false;
        return event;
    }

    const SampledToken = struct {
        token_id: u32,
        rng_after: lane_contiguous.RngState,
        sampling_calls_after: u64,
    };

    fn sampleCurrentLogits(self: *SessionV1) !SampledToken {
        if (self.resources.logits.asF32Unsafe().len == 0)
            return Error.InvalidState;
        var prng: std.Random.DefaultPrng = .{ .s = self.rng_state };
        var empty_scratch: [0]sampling.Candidate = .{};
        const token_index = sampling.sample(
            self.resources.logits.asF32Unsafe(),
            .{ .temperature = 0 },
            prng.random(),
            &empty_scratch,
        );
        const token_id = std.math.cast(u32, token_index) orelse
            return generate.GenerateError.ShapeMismatch;
        const calls_after = std.math.add(
            u64,
            self.sampling_calls,
            1,
        ) catch return Error.InvalidState;
        return .{
            .token_id = token_id,
            .rng_after = prng.s,
            .sampling_calls_after = calls_after,
        };
    }

    fn prefill(self: *SessionV1, prompt: []const u32) !void {
        const cfg = self.model.config;
        const layer_cfg = layerConfig(cfg);
        var s_next: [2]usize = undefined;
        var s_final: [2]usize = undefined;
        for (prompt, 0..) |prompt_token, prompt_pos| {
            try generate.loadPreparedTextEmbeddingV1(
                self.model.*,
                prompt_token,
                self.resources.x_row.asF32Unsafe(),
            );
            for (self.model.layers, 0..) |weights, layer_index| {
                const layer_buffers =
                    self.resources.buffers.forLayer(layer_index);
                const next_h = decode_buffers.DecodeBuffers.view(
                    layer_buffers.next_h,
                    &s_next,
                    cfg.dim,
                );
                try forwardOne(
                    layer_cfg,
                    weights,
                    self.resources.x_row,
                    &self.resources.cache,
                    layer_index,
                    prompt_pos,
                    layer_buffers,
                    next_h,
                    &self.resources.rope_table,
                    .prefill,
                    null,
                );
                @memcpy(
                    self.resources.x_row.asF32Unsafe(),
                    layer_buffers.next_h,
                );
            }
            self.resources.cache.commit();
        }
        try self.projectFinal(&s_final);
    }

    fn decodeCommittedTail(self: *SessionV1, mark: kv.RowTxnMark) !void {
        const cfg = self.model.config;
        const previous_token = self.resources.output[self.output_len - 1];
        try generate.loadPreparedTextEmbeddingV1(
            self.model.*,
            previous_token,
            self.resources.x_row.asF32Unsafe(),
        );
        var s_next: [2]usize = undefined;
        var s_final: [2]usize = undefined;
        const cur_pos = self.resources.cache.len;
        const layer_cfg = layerConfig(cfg);
        for (self.model.layers, 0..) |weights, layer_index| {
            const layer_buffers =
                self.resources.buffers.forLayer(layer_index);
            const next_h = decode_buffers.DecodeBuffers.view(
                layer_buffers.next_h,
                &s_next,
                cfg.dim,
            );
            try forwardOne(
                layer_cfg,
                weights,
                self.resources.x_row,
                &self.resources.cache,
                layer_index,
                cur_pos,
                layer_buffers,
                next_h,
                &self.resources.rope_table,
                .decode,
                mark,
            );
            @memcpy(
                self.resources.x_row.asF32Unsafe(),
                layer_buffers.next_h,
            );
        }
        try self.projectFinal(&s_final);
    }

    fn projectFinal(self: *SessionV1, shape: *[2]usize) !void {
        const cfg = self.model.config;
        const last_layer = cfg.num_layers - 1;
        const final_h = decode_buffers.DecodeBuffers.view(
            self.resources.buffers.forLayer(last_layer).next_h,
            shape,
            cfg.dim,
        );
        kernels.rmsNormF32(
            self.resources.x_row,
            self.model.final_norm,
            cfg.rms_eps,
            final_h,
        ) catch return generate.GenerateError.ForwardFailed;
        try generate.projectPreparedTextHeadV1(
            self.model.*,
            final_h,
            self.resources.logits,
        );
    }
};

/// Address-stable prepared session with a canonical common-plan binding.
///
/// V2 owns an unchanged `SessionV1` and installs the verified binding before
/// admission adoption begins. This closes the interval in which publication
/// could become visible without the common artifact, execution-plan, and
/// residency roots already being present at the session's final address.
/// Like V1, callers must not move, copy, mutate, or concurrently access this
/// value during an active lifecycle or start-adoption recovery.
pub const SessionV2 = struct {
    inner: SessionV1 = .{},
    bound_plan: BoundPlanV1 = undefined,
    contract_bound: bool = false,

    /// Verify the supplied plan against the independently retained
    /// `bound_input` before making any Scheduler, Bank, or allocator call.
    pub fn start(
        self: *SessionV2,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        local_plan: PlanV1,
        bound_input: BoundPlanInputV1,
        bound_plan: BoundPlanV1,
        scheduling: SchedulingV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
    ) !StartDecisionV1 {
        if (self.contract_bound or self.inner.resources_initialized or
            self.inner.publication_bound or
            self.inner.recovery_adoption != null)
            return Error.InvalidState;

        const expected = try makeBoundPlanV1(
            model.*,
            prompt,
            options,
            local_plan,
            scheduling,
            scheduler,
            bound_input,
        );
        if (!std.meta.eql(expected, bound_plan))
            return Error.InvalidBoundPlan;

        // The roots must be installed before SessionV1 can commit the
        // Scheduler's publication-adoption barrier.
        self.bound_plan = bound_plan;
        self.contract_bound = true;
        const decision = self.inner.start(
            allocator,
            model,
            prompt,
            options,
            local_plan,
            scheduling,
            scheduler,
            bank,
            bound_input.request_epoch,
        ) catch |err| {
            if (err != Error.RecoveryRequired) self.* = .{};
            return err;
        };
        switch (decision) {
            .started => return decision,
            .rejected => {
                self.* = .{};
                return decision;
            },
        }
    }

    /// Retry the exact cleanup retained by V1 while preserving the common
    /// binding until the accepted adoption has been cancelled successfully.
    pub fn recoverStartAdoption(self: *SessionV2) !lane.EventV1 {
        if (!self.contract_bound) return Error.InvalidState;
        const event = try self.inner.recoverStartAdoption();
        self.* = .{};
        return event;
    }

    pub fn deinit(self: *SessionV2) void {
        self.inner.deinit();
        self.* = .{};
    }

    pub fn step(
        self: *SessionV2,
        permit: lane.ServicePermitV1,
        downstream: publication.SinkV1,
    ) !publication.CommitReceiptV1 {
        if (!self.contract_bound) return Error.InvalidState;
        return self.inner.step(permit, downstream);
    }

    pub fn outputTokens(self: *const SessionV2) []const u32 {
        if (!self.contract_bound) return &.{};
        return self.inner.outputTokens();
    }

    pub fn isFinished(self: *const SessionV2) bool {
        return self.contract_bound and self.inner.isFinished();
    }

    pub fn snapshotVerified(self: *SessionV2) !BoundarySnapshotV2 {
        if (!self.contract_bound) return Error.InvalidState;
        try validateBoundPlanV1(self.bound_plan);
        const base = try self.inner.snapshotVerified();
        if (!std.mem.eql(
            u8,
            &self.bound_plan.local_plan_sha256,
            &base.plan_sha256,
        ) or
            !std.mem.eql(
                u8,
                &self.bound_plan.artifact.weights_sha256,
                &base.image_identity.container_sha256,
            ) or
            self.bound_plan.artifact.weight_bytes !=
                base.image_identity.container_bytes or
            !std.meta.eql(
                self.bound_plan.residency.request_claim,
                self.inner.plan.claim,
            ) or
            self.bound_plan.execution.request_epoch !=
                base.publication.request_epoch)
            return Error.InvalidBoundPlan;
        var snapshot: BoundarySnapshotV2 = .{
            .base = base,
            .bound_plan_sha256 = self.bound_plan.bound_plan_sha256,
            .artifact_sha256 = self.bound_plan.artifact.artifact_sha256,
            .execution_plan_sha256 = self.bound_plan.execution.plan_sha256,
            .residency_binding_sha256 = self.bound_plan.residency.binding_sha256,
            .boundary_sha256 = [_]u8{0} ** 32,
        };
        snapshot.boundary_sha256 = boundaryRootV2(snapshot);
        if (!boundarySnapshotValidForBoundPlanV2(
            snapshot,
            self.bound_plan,
            self.inner.plan,
        ))
            return Error.InvalidState;
        return snapshot;
    }

    pub fn retire(self: *SessionV2) !lane.EventV1 {
        if (!self.contract_bound) return Error.InvalidState;
        return self.inner.retire();
    }

    pub fn cancel(self: *SessionV2) !lane.EventV1 {
        if (!self.contract_bound) return Error.InvalidState;
        return self.inner.cancel();
    }
};

const CheckpointContextV1 = struct {
    boundary: BoundarySnapshotV2,
    expected: prepared_checkpoint.ExpectedBindingsV1,
};

pub const RestoredLifecyclePhaseV1 = enum(u8) {
    none,
    allocation_abort_required,
    live,
    close_held,
    retire_prepared,
    backing_freed,
    tree_empty,
};

/// Preferred R1d-R1h-b session. V3 preserves the complete V2 execution
/// lifecycle, adds one terminal, residency-aware Common Model Contract
/// ResultEnvelope, can replace exact non-terminal state buffers while
/// retaining the original in-process publication authority, and can activate
/// one charge-correct process-local restored target.
///
/// The Model Contract publication state is a separate result domain from the
/// per-token contiguous transcript: token transactions advance the V2
/// boundary, then at most one explicit terminal seal can commit sequence
/// 0 -> 1 before explicit retirement releases the request-charged receipt.
/// `deinit` remains an abandonment cleanup path and may close without evidence;
/// a retained restored-start rollback still requires its prepared capability.
pub const SessionV3 = struct {
    inner: SessionV2 = .{},
    result_publication_state: model_contract.PublicationStateV1 = undefined,
    terminal_result_evidence: TerminalResultEvidenceV1 = undefined,
    result_receipt: resource_bank.Receipt = undefined,
    result_state_initialized: bool = false,
    result_receipt_live: bool = false,
    terminal_result_sealed: bool = false,
    source_live_grant: ?*prepared_source_lease.SourceLiveGrantV1 = null,
    source_handoff: ?lane.PublicationHandoffV1 = null,
    restored_mode: bool = false,
    restored_phase: RestoredLifecyclePhaseV1 = .none,
    restored_scheduler: ?*lane.Scheduler = null,
    restored_bank: ?*resource_bank.Bank = null,
    restored_activation_grant: ?*prepared_restore.SelectedSourceExitGrantV1 = null,
    restored_tree: resource_bank.LeaseTreeV1 = undefined,
    restored_scope: resource_bank.LeaseNodeV1 = undefined,
    restored_allocation: resource_bank.LeaseNodeV1 = undefined,
    restored_batch: resource_bank.LeaseAllocationBatchV1 = undefined,
    restored_close: lane.RestoredPublicationCloseV1 = undefined,
    restored_retire_ticket: resource_bank.LeaseRetireTicketV1 = undefined,
    restored_free_permit: resource_bank.LeaseFreePermitV1 = undefined,

    /// Address that R1h-a must bind before any restored allocation. It names
    /// the final nested publication coordinator, not the outer Session value.
    pub fn restoredPublicationSessionIdV1(
        self: *SessionV3,
    ) usize {
        return @intFromPtr(
            &self.inner.inner.publication_session.inner,
        );
    }

    /// Materialize and activate one verified R1g successor behind the exact
    /// R1h-a barrier. The immutable receipt is already charged; this method
    /// reserves a queue-free funded ownership carve-out before its first
    /// allocator call, reconstructs concrete KV/output/RNG state, and makes
    /// the Scheduler binding visible only as its final fallible operation.
    pub fn startRestoredV1(
        self: *SessionV3,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        local_plan: PlanV1,
        source_bound_plan: BoundPlanV1,
        prepared: *prepared_restore.PreparedRestoredAdmissionV1,
        evidence: prepared_restore.EvidenceV1,
        activation_grant: *prepared_restore.SelectedSourceExitGrantV1,
    ) !void {
        if (self.result_state_initialized or
            self.terminal_result_sealed or
            self.inner.contract_bound or self.restored_mode or
            self.restored_phase != .none)
            return Error.InvalidState;
        if (@as(u64, options.eos_token) <
            @as(u64, @intCast(model.config.vocab_size)))
            return Error.InvalidConfiguration;
        if (prepared.session_id !=
            self.restoredPublicationSessionIdV1())
            return Error.InvalidAdmission;

        try prepared_restore.validatePreparedRestoredAdmissionV1(
            prepared,
            evidence,
            activation_grant,
        );
        const artifacts =
            try prepared_successor.decodeAndVerifyForCheckpointV1(
                evidence.encoded_plan,
                evidence.encoded_residency,
                evidence.encoded_segment,
                evidence.encoded_checkpoint,
                evidence.expected_checkpoint,
                evidence.source,
                evidence.target,
            );
        const decoded =
            try prepared_checkpoint.decodeCheckpointV1(
                evidence.encoded_checkpoint,
                evidence.expected_checkpoint,
            );
        const expected_local_plan =
            try makePlanV1(model.*, prompt, options);
        try validateBoundPlanV1(source_bound_plan);
        if (!std.meta.eql(expected_local_plan, local_plan) or
            !std.mem.eql(
                u8,
                &source_bound_plan.bound_plan_sha256,
                &evidence.source.bound_plan_sha256,
            ) or !std.meta.eql(
            source_bound_plan.execution,
            evidence.source.execution,
        ) or !std.meta.eql(
            source_bound_plan.residency,
            evidence.source.residency,
        ) or !std.mem.eql(
            u8,
            &source_bound_plan.local_plan_sha256,
            &local_plan.plan_sha256,
        ) or !std.mem.eql(
            u8,
            &decoded.bound_plan_sha256,
            &source_bound_plan.bound_plan_sha256,
        ) or !std.meta.eql(
            local_plan.claim,
            prepared.target.request_claim,
        ))
            return Error.InvalidBoundPlan;
        const successor_bound_plan =
            try deriveSuccessorBoundPlanV1(
                source_bound_plan,
                artifacts,
            );
        if (!std.mem.eql(
            u8,
            &successor_bound_plan.execution.plan_sha256,
            &prepared.successor_execution_plan_sha256,
        ) or !std.mem.eql(
            u8,
            &successor_bound_plan.residency.binding_sha256,
            &prepared.successor_residency_binding_sha256,
        ) or successor_bound_plan.execution.publication_next_sequence !=
            prepared.publication_next_sequence)
            return Error.InvalidBoundPlan;

        const initial_result_state =
            model_contract.initializePublicationStateV1(
                successor_bound_plan.execution.request_epoch,
                successor_bound_plan.artifact.artifact_sha256,
            ) catch return Error.InvalidBoundPlan;
        var restored = evidence.source.publication;
        restored.sequence_base = prepared.publication_next_sequence;
        if (restored.next_sequence !=
            prepared.publication_next_sequence or
            restored.last_resource_permit_generation !=
                prepared.source_last_resource_permit_generation or
            restored.terminal or
            restored.state.output_length !=
                prepared.publication_next_sequence or
            restored.state.sampling_calls !=
                prepared.publication_next_sequence or
            !std.mem.eql(
                u8,
                &restored.state.commitment_sha256,
                &decoded.state_commitment_sha256,
            ) or !std.mem.eql(
            u8,
            &restored.transcript_sha256,
            &decoded.transcript_sha256,
        ))
            return Error.InvalidState;

        const materialized_claim =
            prepared_restore.materializedClaimV1(local_plan.claim);
        if (materialized_claim.isZero())
            return Error.InvalidPlan;
        var allocation_nodes: [1]resource_bank.LeaseNodeV1 =
            undefined;
        const reservation =
            try prepared.bank
                .reserveReceiptFundedAllocationsForSession(
                prepared.tree,
                prepared.adoption.publication_request_epoch,
                prepared.session_id,
                prepared.publication_next_sequence,
                &.{.{
                    .scope = prepared.scope,
                    .node_key = prepared.target.cache_node_key,
                    .binding_key = prepared.target.cache_binding_key,
                    .claim = materialized_claim,
                }},
                &allocation_nodes,
            );

        self.inner.bound_plan = successor_bound_plan;
        self.inner.contract_bound = true;
        self.result_publication_state = initial_result_state;
        self.result_receipt = prepared.receipt;
        self.result_state_initialized = true;
        self.result_receipt_live = true;
        self.restored_mode = true;
        self.restored_scheduler = prepared.scheduler;
        self.restored_bank = prepared.bank;
        self.restored_activation_grant = activation_grant;
        self.restored_tree = reservation.tree;
        self.restored_scope = prepared.scope;
        self.restored_allocation = allocation_nodes[0];
        self.restored_batch = reservation.batch;

        self.inner.inner.initializeRestoredAdopting(
            allocator,
            model,
            prompt,
            options,
            local_plan,
            prepared.scheduler,
            prepared.bank,
            prepared.adoption,
            reservation.tree,
            reservation.batch,
            decoded,
            restored,
        ) catch |original_error| {
            const recovered_tree =
                prepared.bank.abortAllocationsAfterFree(
                    reservation.batch,
                ) catch {
                    self.restored_phase =
                        .allocation_abort_required;
                    return Error.RecoveryRequired;
                };
            prepared.tree = recovered_tree;
            prepared.bootstrap_sha256 =
                prepared_restore.preparedRestoredAdmissionRootV1(
                    prepared.*,
                );
            self.* = .{};
            return original_error;
        };

        self.restored_tree = self.inner.inner.publication_session
            .inner.funded_lease_tree orelse
            @panic("restored adoption lost funded tree");
        self.restored_phase = .live;
        prepared.tree = self.restored_tree;
        prepared.phase = .activated;
        prepared.bootstrap_sha256 =
            prepared_restore.preparedRestoredAdmissionRootV1(
                prepared.*,
            );
        prepared_restore.consumePreparedActivationGrantV1(
            prepared,
            activation_grant,
        );
    }

    /// Retry the only pre-activation recovery state retained by
    /// `startRestoredV1`: allocator backing is already gone, but the funded
    /// reservation must still be aborted before R1h-a authority is usable.
    pub fn recoverRestoredStartV1(
        self: *SessionV3,
        prepared: *prepared_restore.PreparedRestoredAdmissionV1,
    ) !void {
        if (!self.restored_mode or
            self.restored_phase != .allocation_abort_required or
            self.restored_scheduler == null or
            self.restored_scheduler.? != prepared.scheduler or
            self.restored_bank == null or
            self.restored_bank.? != prepared.bank or
            prepared.phase != .prepared or
            !std.meta.eql(
                self.restored_batch.parent,
                prepared.receipt,
            ) or
            prepared.session_id !=
                self.restoredPublicationSessionIdV1())
            return Error.InvalidState;
        const recovered_tree =
            prepared.bank.abortAllocationsAfterFree(
                self.restored_batch,
            ) catch return Error.RecoveryRequired;
        prepared.tree = recovered_tree;
        prepared.bootstrap_sha256 =
            prepared_restore.preparedRestoredAdmissionRootV1(
                prepared.*,
            );
        self.* = .{};
    }

    pub fn start(
        self: *SessionV3,
        allocator: std.mem.Allocator,
        model: *const loader.LoadedModel,
        prompt: []const u32,
        options: OptionsV1,
        local_plan: PlanV1,
        bound_input: BoundPlanInputV1,
        bound_plan: BoundPlanV1,
        scheduling: SchedulingV1,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
    ) !StartDecisionV1 {
        if (self.result_state_initialized or
            self.terminal_result_sealed or
            self.inner.contract_bound)
            return Error.InvalidState;
        // ResultEnvelopeV1 carries the plan's exact fixed output shape. Keep
        // V3 total by rejecting an in-vocabulary EOS policy that could finish
        // with fewer tokens than that declared shape. A variable-length or
        // early-EOS result profile remains future work.
        if (@as(u64, options.eos_token) <
            @as(u64, @intCast(model.config.vocab_size)))
            return Error.InvalidConfiguration;
        try validateBoundPlanV1(bound_plan);
        const initial_state =
            model_contract.initializePublicationStateV1(
                bound_plan.execution.request_epoch,
                bound_plan.artifact.artifact_sha256,
            ) catch return Error.InvalidBoundPlan;

        // Install the terminal-result state before the nested V2 session can
        // commit publication adoption at its final address.
        self.result_publication_state = initial_state;
        self.result_state_initialized = true;
        const decision = self.inner.start(
            allocator,
            model,
            prompt,
            options,
            local_plan,
            bound_input,
            bound_plan,
            scheduling,
            scheduler,
            bank,
        ) catch |err| {
            if (err != Error.RecoveryRequired) self.* = .{};
            return err;
        };
        switch (decision) {
            .started => |event| {
                const nested_receipt = self.inner.inner
                    .publication_session.admission.event.resource_receipt;
                if (!std.meta.eql(
                    event.resource_receipt,
                    nested_receipt,
                ))
                    @panic("prepared result receipt drift after start");
                self.result_receipt = event.resource_receipt;
                self.result_receipt_live = true;
                return decision;
            },
            .rejected => {
                self.* = .{};
                return decision;
            },
        }
    }

    pub fn recoverStartAdoption(self: *SessionV3) !lane.EventV1 {
        if (!self.result_state_initialized)
            return Error.InvalidState;
        const event = try self.inner.recoverStartAdoption();
        self.* = .{};
        return event;
    }

    pub fn deinit(self: *SessionV3) void {
        if (self.restored_mode) {
            switch (self.restored_phase) {
                .live => {
                    _ = self.closeRestoredV1() catch
                        @panic("restored Session close failed");
                },
                .close_held,
                .retire_prepared,
                .backing_freed,
                .tree_empty,
                => {
                    _ = self.recoverRestoredCloseV1() catch
                        @panic("restored Session close recovery failed");
                },
                .allocation_abort_required => @panic("restored Session start recovery required"),
                .none => @panic("invalid restored Session phase"),
            }
            return;
        }
        if (self.source_handoff) |handoff| {
            self.inner.inner.publication_session
                .abortPublicationHandoffV1(handoff) catch
                @panic("prepared text source handoff abort failed");
            const source_live_grant =
                self.source_live_grant orelse
                @panic("prepared text source grant missing");
            prepared_source_lease.abortSourceHandoffV1(
                source_live_grant,
            ) catch @panic("prepared text source grant abort failed");
            self.source_handoff = null;
        }
        if (self.source_live_grant) |grant| {
            switch (grant.phase) {
                .ready, .bound => {
                    prepared_source_lease.releaseSourceLiveGrantV1(
                        grant,
                    ) catch @panic("prepared text source grant release failed");
                },
                .completed => {},
                .exit_committed => @panic("prepared text source handoff completion required"),
                .handoff => @panic("prepared text source handoff drift"),
                .empty => @panic("prepared text source grant empty"),
            }
            self.source_live_grant = null;
        }
        self.inner.deinit();
        self.* = .{};
    }

    /// Establish the Scheduler-side no-service barrier, then reclaim concrete
    /// resources before atomically closing the empty funded tree and receipt.
    /// A failure after the barrier is retained in `restored_phase` and must be
    /// retried with `recoverRestoredCloseV1`.
    pub fn closeRestoredV1(
        self: *SessionV3,
    ) !lane.EventV1 {
        if (!self.restored_mode or
            self.restored_phase != .live or
            !self.result_receipt_live or
            !self.inner.contract_bound or
            !self.inner.inner.resources_initialized or
            !self.inner.inner.publication_bound)
            return Error.InvalidState;
        const terminal = self.inner.isFinished();
        try self.validateRestoredActivationGrantV1(
            self.restoredCloseGrantPhaseV1(terminal),
        );
        const publication_session =
            &self.inner.inner.publication_session;
        const snapshot = try publication_session.snapshotVerified();
        const kind: lane.EventKind =
            if (terminal) .retire else .cancel;
        self.restored_close =
            try self.inner.inner.scheduler
                .beginRestoredPublicationClose(
                publication_session.admission.handle,
                kind,
                publication_session.request_epoch,
                @intFromPtr(&publication_session.inner),
                snapshot.next_sequence,
                self.restored_tree,
            );
        self.restored_phase = .close_held;
        return self.recoverRestoredCloseV1();
    }

    /// Resume one exact barrier-held cleanup phase. No phase uncharges the
    /// parent receipt before allocator backing is gone, and no phase can make
    /// Scheduler service runnable again.
    pub fn recoverRestoredCloseV1(
        self: *SessionV3,
    ) !lane.EventV1 {
        if (!self.restored_mode or
            self.restored_phase == .none or
            self.restored_phase == .live or
            self.restored_phase == .allocation_abort_required)
            return Error.InvalidState;
        const terminal =
            self.restored_close.kind == .retire;
        try self.validateRestoredActivationGrantV1(
            self.restoredCloseGrantPhaseV1(terminal),
        );
        const publication_session =
            &self.inner.inner.publication_session;
        const bank = publication_session.bank;
        const scheduler = self.inner.inner.scheduler;
        while (true) {
            switch (self.restored_phase) {
                .close_held => {
                    const prepared_retire =
                        bank.beginRetireSubtreeForSession(
                            self.restored_tree,
                            self.restored_scope,
                            publication_session.request_epoch,
                            @intFromPtr(&publication_session.inner),
                            self.restored_close
                                .expected_next_sequence,
                        ) catch return Error.RecoveryRequired;
                    self.restored_tree = prepared_retire.tree;
                    self.restored_retire_ticket =
                        prepared_retire.ticket;
                    self.restored_phase = .retire_prepared;
                },
                .retire_prepared => {
                    if (!self.inner.inner.resources_initialized)
                        return Error.RecoveryRequired;
                    const authorized =
                        bank.authorizeFree(
                            self.restored_retire_ticket,
                        ) catch return Error.RecoveryRequired;
                    self.restored_tree = authorized.tree;
                    self.restored_free_permit = authorized.permit;
                    self.inner.inner.resources.deinit();
                    self.inner.inner.resources_initialized = false;
                    self.restored_phase = .backing_freed;
                },
                .backing_freed => {
                    self.restored_tree =
                        bank.commitFreeAfterAllocatorFree(
                            self.restored_free_permit,
                        ) catch return Error.RecoveryRequired;
                    self.restored_phase = .tree_empty;
                },
                .tree_empty => {
                    const activation_grant =
                        self.restored_activation_grant orelse
                        @panic("restored activation grant missing");
                    const event =
                        scheduler.commitRestoredPublicationClose(
                            self.restored_close,
                            self.restored_tree,
                        ) catch return Error.RecoveryRequired;
                    prepared_restore
                        .completeRestoredActivationGrantV1(
                        activation_grant,
                        terminal,
                    );
                    self.* = .{};
                    return event;
                },
                .none,
                .allocation_abort_required,
                .live,
                => return Error.InvalidState,
            }
        }
    }

    pub fn step(
        self: *SessionV3,
        permit: lane.ServicePermitV1,
        downstream: publication.SinkV1,
    ) !publication.CommitReceiptV1 {
        if (!self.result_state_initialized or
            !self.result_receipt_live or
            self.source_live_grant != null or
            self.source_handoff != null or
            (self.restored_mode and
                self.restored_phase != .live) or
            self.terminal_result_sealed)
            return Error.InvalidState;
        if (self.restored_mode)
            try self.validateRestoredActivationGrantV1(
                .consumed,
            );
        return self.inner.step(permit, downstream);
    }

    pub fn outputTokens(self: *const SessionV3) []const u32 {
        if (!self.result_state_initialized or
            (self.source_live_grant != null and
                !self.sourceLiveGrantValidV1()) or
            (self.restored_mode and
                (self.restored_phase != .live or
                    !self.restoredActivationGrantValidV1())))
            return &.{};
        return self.inner.outputTokens();
    }

    pub fn isFinished(self: *const SessionV3) bool {
        return self.result_state_initialized and
            (self.source_live_grant == null or
                self.sourceLiveGrantValidV1()) and
            (!self.restored_mode or
                (self.restored_phase == .live and
                    self.restoredActivationGrantValidV1())) and
            self.inner.isFinished();
    }

    pub fn snapshotVerified(self: *SessionV3) !BoundarySnapshotV2 {
        if (!self.result_state_initialized or
            (self.source_live_grant != null and
                !self.sourceLiveGrantValidV1()) or
            (self.restored_mode and
                (self.restored_phase != .live or
                    !self.restoredActivationGrantValidV1())))
            return Error.InvalidState;
        return self.inner.snapshotVerified();
    }

    fn checkpointContextV1(
        self: *SessionV3,
        challenge_sha256: [32]u8,
    ) !CheckpointContextV1 {
        if (!self.result_state_initialized or
            !self.result_receipt_live or
            self.source_handoff != null or
            (self.restored_mode and
                self.restored_phase != .live) or
            self.terminal_result_sealed or
            self.inner.isFinished())
            return Error.InvalidState;
        if (self.restored_mode)
            try self.validateRestoredActivationGrantV1(
                .consumed,
            );
        if (self.source_live_grant) |grant| {
            if (!std.mem.eql(
                u8,
                &grant.challenge_sha256,
                &challenge_sha256,
            ))
                return Error.InvalidState;
            try self.validateSourceLiveGrantV1(.bound);
        }
        const session = &self.inner.inner;
        if (!session.resources_initialized or
            !session.publication_bound or
            session.recovery_adoption != null)
            return Error.InvalidState;
        const output = session.outputTokens();
        if (output.len == 0 or
            output.len >= session.options.max_new_tokens)
            return Error.InvalidState;

        const publication_session = &session.publication_session;
        const bindings = publication_session.bindings;
        if (bindings.cache != &session.resources.cache or
            bindings.rng_state != &session.rng_state or
            bindings.sampling_calls != &session.sampling_calls or
            bindings.output_len != &session.output_len or
            bindings.output.ptr != session.resources.output.ptr or
            bindings.output.len != session.resources.output.len)
            return Error.InvalidState;

        const boundary = self.inner.snapshotVerified() catch
            return Error.InvalidState;
        const local_plan = session.plan;
        const bound_plan = self.inner.bound_plan;
        try validateBoundPlanV1(bound_plan);
        const expected_result_state =
            model_contract.initializePublicationStateV1(
                bound_plan.execution.request_epoch,
                bound_plan.artifact.artifact_sha256,
            ) catch return Error.InvalidState;
        if (!boundarySnapshotValidForBoundPlanV2(
            boundary,
            bound_plan,
            local_plan,
        ) or boundary.base.publication.terminal or
            !std.meta.eql(
                self.result_publication_state,
                expected_result_state,
            ) or
            boundary.base.publication.next_sequence != output.len or
            boundary.base.publication.state.output_length != output.len or
            boundary.base.publication.state.sampling_calls !=
                output.len or
            local_plan.prompt_tokens == 0 or
            local_plan.max_new_tokens !=
                session.options.max_new_tokens or
            bound_plan.execution.request_epoch !=
                boundary.base.publication.request_epoch)
            return Error.InvalidState;

        const nested_receipt =
            publication_session.admission.event.resource_receipt;
        if (!std.meta.eql(nested_receipt, self.result_receipt))
            return Error.InvalidState;
        publication_session.bank.validatePublicationSession(
            self.result_receipt,
            bound_plan.execution.request_epoch,
            @intFromPtr(&publication_session.inner),
            boundary.base.publication.next_sequence,
        ) catch return Error.InvalidState;

        const cache = &session.resources.cache;
        return .{
            .boundary = boundary,
            .expected = .{
                .local_plan_sha256 = local_plan.plan_sha256,
                .bound_plan_sha256 = bound_plan.bound_plan_sha256,
                .artifact_sha256 = bound_plan.artifact.artifact_sha256,
                .execution_plan_sha256 = bound_plan.execution.plan_sha256,
                .residency_binding_sha256 = bound_plan.residency.binding_sha256,
                .boundary_sha256 = boundary.boundary_sha256,
                .transcript_sha256 = boundary.base.publication.transcript_sha256,
                .state_commitment_sha256 = boundary.base.publication
                    .state.commitment_sha256,
                .request_epoch = bound_plan.execution.request_epoch,
                .publication_next_sequence = boundary.base.publication.next_sequence,
                .prompt_tokens = local_plan.prompt_tokens,
                .max_new_tokens = local_plan.max_new_tokens,
                .vocab_size = @intCast(session.model.config.vocab_size),
                .num_layers = @intCast(cache.num_layers),
                .kv_dim = @intCast(cache.dim),
                .max_kv_positions = @intCast(cache.max_seq),
                .kv_positions = @intCast(cache.len),
                .output_count = @intCast(output.len),
                .sampling_calls = session.sampling_calls,
                .challenge_sha256 = challenge_sha256,
            },
        };
    }

    fn validateRebindCandidateV1(
        self: *SessionV3,
        decoded: prepared_checkpoint.DecodedV1,
        candidate: *prepared_checkpoint.DetachedPayloadV1,
    ) !void {
        const session = &self.inner.inner;
        const live_cache = &session.resources.cache;
        const candidate_cache = &candidate.cache;
        const live_output = session.outputTokens();
        if (!std.meta.eql(
            candidate.allocator,
            session.resources.allocator,
        ) or candidate_cache.rowTxnActive() or
            candidate_cache.instance_id == live_cache.instance_id or
            candidate_cache.num_layers != live_cache.num_layers or
            candidate_cache.dim != live_cache.dim or
            candidate_cache.max_seq != live_cache.max_seq or
            candidate_cache.len != live_cache.len or
            candidate.output.ptr == session.resources.output.ptr or
            candidate.output.len != session.resources.output.len or
            candidate.output_len != live_output.len or
            candidate.output_len != decoded.output_count or
            !std.meta.eql(candidate.rng_state, session.rng_state) or
            candidate.sampling_calls != session.sampling_calls or
            !std.mem.eql(
                u8,
                &candidate.checkpoint_sha256,
                &decoded.checkpoint_sha256,
            ) or !std.mem.eql(
            u8,
            &decoded.logical_kv_sha256,
            &session.publication_session.physical_kv_sha256,
        ) or !std.mem.eql(
            u32,
            candidate.outputTokens(),
            live_output,
        ) or !std.mem.eql(
            u8,
            &lane_contiguous.logicalKvPrefixSha256(
                candidate_cache,
                candidate_cache.len,
            ),
            &lane_contiguous.logicalKvPrefixSha256(
                live_cache,
                live_cache.len,
            ),
        ))
            return prepared_checkpoint.Error.InvalidCheckpoint;

        for (0..live_cache.num_layers) |layer| {
            if (!std.mem.eql(
                u8,
                std.mem.sliceAsBytes(
                    candidate_cache.keysSliceCount(
                        layer,
                        candidate_cache.len,
                    ),
                ),
                std.mem.sliceAsBytes(
                    live_cache.keysSliceCount(
                        layer,
                        live_cache.len,
                    ),
                ),
            ) or !std.mem.eql(
                u8,
                std.mem.sliceAsBytes(
                    candidate_cache.valuesSliceCount(
                        layer,
                        candidate_cache.len,
                    ),
                ),
                std.mem.sliceAsBytes(
                    live_cache.valuesSliceCount(
                        layer,
                        live_cache.len,
                    ),
                ),
            ))
                return prepared_checkpoint.Error.InvalidCheckpoint;
        }
        for (candidate.output[candidate.output_len..]) |token| {
            if (token != 0)
                return prepared_checkpoint.Error.InvalidCheckpoint;
        }
        const slack_start =
            candidate_cache.len * candidate_cache.dim;
        for (0..candidate_cache.num_layers) |layer| {
            for (candidate_cache.keys[layer][slack_start..]) |value| {
                if (@as(u32, @bitCast(value)) != 0)
                    return prepared_checkpoint.Error.InvalidCheckpoint;
            }
            for (candidate_cache.values[layer][slack_start..]) |value| {
                if (@as(u32, @bitCast(value)) != 0)
                    return prepared_checkpoint.Error.InvalidCheckpoint;
            }
        }
    }

    /// Capture one exact, non-terminal prepared boundary as canonical bytes.
    /// The returned allocation belongs to `allocator`. Decoding it can
    /// materialize a detached output/RNG/KV payload, but does not transfer the
    /// live Scheduler/Bank/publication authority held by this Session.
    pub fn captureCheckpointV1(
        self: *SessionV3,
        allocator: std.mem.Allocator,
        challenge_sha256: [32]u8,
    ) ![]u8 {
        const context = try self.checkpointContextV1(
            challenge_sha256,
        );
        const session = &self.inner.inner;
        const output = session.outputTokens();
        const cache = &session.resources.cache;
        const required =
            try prepared_checkpoint.encodedCheckpointBytesV1(
                cache.num_layers,
                cache.dim,
                cache.len,
                output.len,
            );
        const bytes = allocator.alloc(u8, required) catch
            return error.OutOfMemory;
        errdefer allocator.free(bytes);
        const encoded = try prepared_checkpoint.encodeCheckpointV1(
            .{
                .local_plan_sha256 = context.expected.local_plan_sha256,
                .bound_plan_sha256 = context.expected.bound_plan_sha256,
                .artifact_sha256 = context.expected.artifact_sha256,
                .execution_plan_sha256 = context.expected.execution_plan_sha256,
                .residency_binding_sha256 = context.expected.residency_binding_sha256,
                .boundary_sha256 = context.expected.boundary_sha256,
                .transcript_sha256 = context.expected.transcript_sha256,
                .state_commitment_sha256 = context.expected.state_commitment_sha256,
                .request_epoch = context.expected.request_epoch,
                .publication_next_sequence = context.expected.publication_next_sequence,
                .prompt_tokens = context.expected.prompt_tokens,
                .max_new_tokens = context.expected.max_new_tokens,
                .vocab_size = context.expected.vocab_size,
                .output_tokens = output,
                .rng_state = session.rng_state,
                .sampling_calls = session.sampling_calls,
                .cache = cache,
                .challenge_sha256 = context.expected.challenge_sha256,
            },
            bytes,
        );
        std.debug.assert(encoded.len == bytes.len);
        return bytes;
    }

    /// Derive pointer-free successor plan, residency, and transcript-segment
    /// evidence from the exact current checkpoint. This read-only operation
    /// records target ownership intent but does not exit the source, admit a
    /// target, remap a receipt, or create runnable successor authority.
    ///
    /// The caller must serialize the entire call with every operation on this
    /// Session and its bound receipt authority.
    pub fn captureSuccessorArtifactsV1(
        self: *SessionV3,
        encoded_checkpoint: []const u8,
        challenge_sha256: [32]u8,
        target: prepared_successor.TargetOwnershipV1,
    ) !prepared_successor.ArtifactsV1 {
        const before = try self.checkpointContextV1(
            challenge_sha256,
        );
        const source: prepared_successor.SourceContextV1 = .{
            .bound_plan_sha256 = self.inner.bound_plan.bound_plan_sha256,
            .execution = self.inner.bound_plan.execution,
            .residency = self.inner.bound_plan.residency,
            .boundary_sha256 = before.boundary.boundary_sha256,
            .publication = before.boundary.base.publication,
            .receipt = self.result_receipt,
        };
        const artifacts = try prepared_successor.makeForCheckpointV1(
            encoded_checkpoint,
            before.expected,
            source,
            target,
        );
        const after = try self.checkpointContextV1(
            challenge_sha256,
        );
        const source_after: prepared_successor.SourceContextV1 = .{
            .bound_plan_sha256 = self.inner.bound_plan.bound_plan_sha256,
            .execution = self.inner.bound_plan.execution,
            .residency = self.inner.bound_plan.residency,
            .boundary_sha256 = after.boundary.boundary_sha256,
            .publication = after.boundary.base.publication,
            .receipt = self.result_receipt,
        };
        if (!std.meta.eql(before, after) or
            !std.meta.eql(source, source_after))
            return Error.InvalidState;
        return artifacts;
    }

    /// Pin the exact non-terminal source boundary to the active
    /// generation-one selector. Once attached, token service remains frozen
    /// until the grant is explicitly released or consumed by durable handoff.
    pub fn attachSourceLiveGrantV1(
        self: *SessionV3,
        grant: *prepared_source_lease.SourceLiveGrantV1,
    ) !void {
        if (self.restored_mode or
            self.source_live_grant != null or
            self.source_handoff != null or
            !self.result_state_initialized or
            !self.result_receipt_live or
            self.terminal_result_sealed or
            self.inner.isFinished())
            return Error.InvalidState;
        const boundary = try self.inner.snapshotVerified();
        if (boundary.base.publication.next_sequence == 0 or
            boundary.base.publication.next_sequence !=
                grant.publication_next_sequence or
            boundary.base.publication.request_epoch !=
                grant.request_epoch)
            return Error.InvalidState;
        const binding = try self.sourceBindingV1(boundary);
        prepared_source_lease.bindSourceLiveGrantV1(
            grant,
            binding,
        ) catch return Error.InvalidState;
        self.source_live_grant = grant;
        try self.validateSourceLiveGrantV1(.bound);
    }

    /// Abandon a selector-pinned source boundary without exiting its live
    /// Scheduler/Bank authority. Ordinary token service may resume afterward.
    pub fn releaseSourceLiveGrantV1(
        self: *SessionV3,
    ) !void {
        const grant = self.source_live_grant orelse
            return Error.InvalidState;
        if (self.source_handoff != null or
            grant.phase != .bound or
            !self.result_receipt_live)
            return Error.InvalidState;
        try self.validateSourceLiveGrantV1(.bound);
        prepared_source_lease.releaseSourceLiveGrantV1(
            grant,
        ) catch return Error.InvalidState;
        self.source_live_grant = null;
    }

    /// Freeze the exact captured source boundary behind LaneWeave's
    /// single-winner handoff barrier. The prepared archive and predecessor
    /// selector roots are already known, so a later source-exit receipt can
    /// bind the complete durable selection without a circular selector root.
    pub fn beginDurableHandoffV1(
        self: *SessionV3,
        encoded_checkpoint: []const u8,
        challenge_sha256: [32]u8,
        target: prepared_successor.TargetOwnershipV1,
        prepared_archive_sha256: [32]u8,
        predecessor_selector_sha256: [32]u8,
    ) !lane.PublicationHandoffV1 {
        const source_live_grant =
            self.source_live_grant orelse
            return Error.InvalidState;
        if (self.restored_mode or self.source_handoff != null or
            !self.result_receipt_live)
            return Error.InvalidState;
        try self.validateSourceLiveGrantV1(.bound);
        if (!std.mem.eql(
            u8,
            &predecessor_selector_sha256,
            &source_live_grant.source_selector_sha256,
        ) or !std.mem.eql(
            u8,
            &challenge_sha256,
            &source_live_grant.challenge_sha256,
        ))
            return Error.InvalidState;
        const artifacts = try self.captureSuccessorArtifactsV1(
            encoded_checkpoint,
            challenge_sha256,
            target,
        );
        prepared_source_lease.beginSourceHandoffV1(
            source_live_grant,
        ) catch return Error.InvalidState;
        errdefer prepared_source_lease.abortSourceHandoffV1(
            source_live_grant,
        ) catch @panic("prepared text source grant rollback failed");
        const handoff =
            try self.inner.inner.publication_session
                .beginPublicationHandoffV1(
                artifacts.segment.source_checkpoint_sha256,
                artifacts.segment.segment_sha256,
                artifacts.segment.ownership_intent_sha256,
                prepared_archive_sha256,
                predecessor_selector_sha256,
            );
        self.source_handoff = handoff;
        return handoff;
    }

    pub fn validateDurableHandoffV1(
        self: *SessionV3,
    ) !void {
        const handoff = self.source_handoff orelse
            return Error.InvalidState;
        try self.validateSourceLiveGrantV1(.handoff);
        try self.inner.inner.publication_session
            .validatePublicationHandoffV1(handoff);
    }

    /// Remove an uncommitted source freeze without changing publication state.
    pub fn abortDurableHandoffV1(
        self: *SessionV3,
    ) !void {
        const handoff = self.source_handoff orelse
            return Error.InvalidState;
        const source_live_grant =
            self.source_live_grant orelse
            return Error.InvalidState;
        try self.validateSourceLiveGrantV1(.handoff);
        try self.inner.inner.publication_session
            .abortPublicationHandoffV1(handoff);
        prepared_source_lease.abortSourceHandoffV1(
            source_live_grant,
        ) catch @panic("prepared text source grant abort failed");
        self.source_handoff = null;
    }

    /// Atomically revoke the source receipt and return the fixed source-exit
    /// evidence used by the durable selector. Concrete model state remains
    /// owned by this value only until `deinit`; it has no publication authority
    /// after this method succeeds.
    pub fn commitDurableHandoffV1(
        self: *SessionV3,
    ) !lane.SourceExitCommitV1 {
        const handoff = self.source_handoff orelse
            return Error.InvalidState;
        const source_live_grant =
            self.source_live_grant orelse
            return Error.InvalidState;
        try self.validateSourceLiveGrantV1(.handoff);
        const committed =
            try self.inner.inner.publication_session
                .commitPublicationHandoffV1(handoff);
        self.inner.inner.publication_bound = false;
        self.result_receipt_live = false;
        self.source_handoff = null;
        prepared_source_lease.markSourceExitCommittedV1(
            source_live_grant,
            committed.receipt.source_exit_sha256,
        ) catch @panic("prepared text source exit grant drift");
        return committed;
    }

    /// Release the source selector claim only after the exact generation-two
    /// successor has become the active durable selector.
    pub fn completeDurableHandoffV1(
        self: *SessionV3,
        successor: prepared_source_lease.ImmediateSuccessorV1,
    ) !void {
        const grant = self.source_live_grant orelse
            return Error.InvalidState;
        if (self.source_handoff != null or
            self.result_receipt_live or
            grant.phase != .exit_committed)
            return Error.InvalidState;
        prepared_source_lease.completeSourceHandoffV1(
            grant,
            successor,
        ) catch return Error.InvalidState;
        self.source_live_grant = null;
    }

    /// Replace only the concrete KV/output backing at the exact current
    /// non-terminal boundary. The embedded publication coordinator, Scheduler,
    /// Bank, receipt, epoch, sequence, transcript, and scalar field addresses
    /// remain unchanged. Previously borrowed output/cache views are invalid
    /// after success. The caller must serialize the entire call with every
    /// operation on this Session and its bound receipt authority.
    pub fn rebindCheckpointV1(
        self: *SessionV3,
        encoded: []const u8,
        challenge_sha256: [32]u8,
    ) ![32]u8 {
        const before = try self.checkpointContextV1(
            challenge_sha256,
        );
        const decoded =
            try prepared_checkpoint.decodeCheckpointV1(
                encoded,
                before.expected,
            );
        const session = &self.inner.inner;
        var candidate =
            try prepared_checkpoint.materializeDetachedV1(
                session.resources.allocator,
                decoded,
            );
        var candidate_owned = true;
        defer if (candidate_owned) candidate.deinit();

        const after = try self.checkpointContextV1(
            challenge_sha256,
        );
        if (!std.meta.eql(before, after))
            return Error.InvalidState;
        try self.validateRebindCandidateV1(
            decoded,
            &candidate,
        );

        // Every fallible validation ends above. The cache and scalar fields
        // retain their addresses; only their values and the copied output
        // slice descriptor change before the old backing is released.
        var old_cache = session.resources.cache;
        const old_output = session.resources.output;
        session.resources.cache = candidate.cache;
        session.resources.output = candidate.output;
        session.rng_state = candidate.rng_state;
        session.sampling_calls = candidate.sampling_calls;
        session.output_len = candidate.output_len;
        session.publication_session.bindings.output =
            session.resources.output;
        candidate_owned = false;

        session.resources.allocator.free(old_output);
        old_cache.deinit();
        return decoded.checkpoint_sha256;
    }

    /// Seal the only Common Model Contract result while the exact charged
    /// receipt is still live. All fallible verification and state transition
    /// work happens on local copies before the Session becomes result-visible.
    pub fn sealTerminalResult(
        self: *SessionV3,
    ) !TerminalResultEvidenceV1 {
        if (!self.result_state_initialized or
            !self.result_receipt_live or
            self.source_live_grant != null or
            (self.restored_mode and
                self.restored_phase != .live) or
            !self.inner.isFinished() or
            self.terminal_result_sealed)
            return Error.InvalidState;

        const boundary = try self.inner.snapshotVerified();
        const output = self.inner.outputTokens();
        const local_plan = self.inner.inner.plan;
        const bound_plan = self.inner.bound_plan;
        if (@as(u64, @intCast(output.len)) !=
            bound_plan.execution.output_dimensions)
            return Error.InvalidState;

        const output_sha256 = terminalOutputRootV1(
            bound_plan,
            output,
        );
        const source_mapping_sha256 =
            terminalSourceMappingRootV1(
                bound_plan,
                boundary,
                output_sha256,
                @intCast(output.len),
            );
        const adapter_sha256 = terminalAdapterRootV1(
            bound_plan,
            local_plan,
        );
        const publication_session =
            &self.inner.inner.publication_session;
        const nested_receipt =
            publication_session.admission.event.resource_receipt;
        if (!std.meta.eql(nested_receipt, self.result_receipt))
            return Error.InvalidState;
        const receipt = self.result_receipt;
        publication_session.bank.validatePublicationSession(
            receipt,
            bound_plan.execution.request_epoch,
            @intFromPtr(&publication_session.inner),
            boundary.base.publication.next_sequence,
        ) catch return Error.InvalidState;
        const result =
            try model_contract.prepareResidencyResultEnvelopeV1(
                self.result_publication_state,
                bound_plan.execution,
                bound_plan.residency,
                receipt,
                output_sha256,
                source_mapping_sha256,
                adapter_sha256,
            );
        try model_contract.validateResidencyResultEnvelopeV1(
            self.result_publication_state,
            bound_plan.execution,
            bound_plan.residency,
            receipt,
            result,
            output_sha256,
            source_mapping_sha256,
            adapter_sha256,
        );

        var state_after = self.result_publication_state;
        try model_contract.commitResultV1(&state_after, result);
        const state_after_sha256 =
            try model_contract.publicationStateRootV1(state_after);
        var evidence: TerminalResultEvidenceV1 = .{
            .boundary = boundary,
            .result = result,
            .publication_state_after = state_after,
            .publication_state_after_sha256 = state_after_sha256,
            .evidence_sha256 = [_]u8{0} ** 32,
        };
        evidence.evidence_sha256 =
            terminalResultEvidenceRootV1(evidence);
        if (!terminalResultEvidenceValidForReceiptV1(
            evidence,
            bound_plan,
            local_plan,
            output,
            receipt,
        ))
            return Error.InvalidState;

        self.result_publication_state = state_after;
        self.terminal_result_evidence = evidence;
        self.terminal_result_sealed = true;
        return evidence;
    }

    pub fn terminalResult(
        self: *const SessionV3,
    ) ?TerminalResultEvidenceV1 {
        if (!self.terminal_result_sealed) return null;
        return self.terminal_result_evidence;
    }

    pub fn retire(self: *SessionV3) !lane.EventV1 {
        if (self.restored_mode) {
            if (self.restored_phase != .live)
                return Error.InvalidState;
            if (!self.inner.isFinished())
                return Error.InvalidState;
            return self.closeRestoredV1();
        }
        if (!self.result_state_initialized or
            !self.result_receipt_live or
            self.source_live_grant != null or
            !self.terminal_result_sealed)
            return Error.InvalidState;
        const event = try self.inner.retire();
        self.result_receipt_live = false;
        return event;
    }

    pub fn cancel(self: *SessionV3) !lane.EventV1 {
        if (self.restored_mode) {
            if (self.restored_phase != .live)
                return Error.InvalidState;
            if (self.inner.isFinished())
                return Error.InvalidState;
            return self.closeRestoredV1();
        }
        if (!self.result_state_initialized or
            !self.result_receipt_live or
            (self.source_live_grant != null and
                self.source_handoff == null) or
            self.terminal_result_sealed)
            return Error.InvalidState;
        const event = try self.inner.cancel();
        self.result_receipt_live = false;
        return event;
    }

    fn sourceBindingV1(
        self: *SessionV3,
        boundary: BoundarySnapshotV2,
    ) !prepared_source_lease.SourceBindingV1 {
        const identity =
            try self.inner.inner.scheduler.identityV1();
        return .{
            .source_scheduler_epoch = identity.scheduler_epoch,
            .source_coordinator_id = identity.coordinator_id,
            .source_bank_epoch = self.result_receipt.bank_epoch,
            .request_sha256 = self.inner.bound_plan.execution.plan_sha256,
            .publication_next_sequence = boundary.base.publication.next_sequence,
            .source_last_resource_permit_generation = boundary.base.publication
                .last_resource_permit_generation,
            .source_receipt_sha256 = lane.resourceReceiptSha256(
                self.result_receipt,
            ),
        };
    }

    fn validateSourceLiveGrantV1(
        self: *SessionV3,
        expected_phase: prepared_source_lease.SourceLivePhaseV1,
    ) !void {
        const grant = self.source_live_grant orelse
            return Error.InvalidState;
        prepared_source_lease.validateSourceLiveGrantV1(
            grant,
            expected_phase,
        ) catch return Error.InvalidState;
        const boundary = try self.inner.snapshotVerified();
        const binding = try self.sourceBindingV1(boundary);
        if (binding.source_scheduler_epoch !=
            grant.source_scheduler_epoch or
            binding.source_coordinator_id !=
                grant.source_coordinator_id or
            binding.source_bank_epoch !=
                grant.source_bank_epoch or
            binding.publication_next_sequence !=
                grant.publication_next_sequence or
            binding.source_last_resource_permit_generation !=
                grant.source_last_resource_permit_generation or
            !std.mem.eql(
                u8,
                &binding.request_sha256,
                &grant.request_sha256,
            ) or !std.mem.eql(
            u8,
            &binding.source_receipt_sha256,
            &grant.source_receipt_sha256,
        ) or !std.mem.eql(
            u8,
            &prepared_source_lease.sourceBindingRootV1(
                binding,
            ),
            &grant.source_binding_sha256,
        ))
            return Error.InvalidState;
    }

    fn sourceLiveGrantValidV1(
        self: *const SessionV3,
    ) bool {
        const grant = self.source_live_grant orelse
            return true;
        const expected_phase: prepared_source_lease.SourceLivePhaseV1 =
            if (self.source_handoff == null)
                .bound
            else
                .handoff;
        prepared_source_lease.validateSourceLiveGrantV1(
            grant,
            expected_phase,
        ) catch return false;
        if (!self.result_receipt_live or
            !self.inner.contract_bound)
            return false;
        const publication_session =
            &self.inner.inner.publication_session.inner;
        return publication_session.initialized and
            publication_session.request_epoch ==
                grant.request_epoch and
            publication_session.next_sequence ==
                grant.publication_next_sequence and
            publication_session
                .last_resource_permit_generation ==
                grant.source_last_resource_permit_generation and
            self.result_receipt.bank_epoch ==
                grant.source_bank_epoch and
            publication_session.admission.handle.scheduler_epoch ==
                grant.source_scheduler_epoch and
            std.mem.eql(
                u8,
                &self.inner.bound_plan.execution.plan_sha256,
                &grant.request_sha256,
            ) and std.mem.eql(
            u8,
            &lane.resourceReceiptSha256(
                self.result_receipt,
            ),
            &grant.source_receipt_sha256,
        );
    }

    fn validateRestoredActivationGrantV1(
        self: *const SessionV3,
        expected_phase: prepared_restore.ActivationGrantPhase,
    ) !void {
        if (!self.restored_mode)
            return Error.InvalidState;
        const grant = self.restored_activation_grant orelse
            return Error.InvalidState;
        prepared_restore.validateSelectedSourceExitGrantV1(
            grant,
            expected_phase,
        ) catch return Error.InvalidState;
    }

    fn restoredCloseGrantPhaseV1(
        self: *const SessionV3,
        terminal: bool,
    ) prepared_restore.ActivationGrantPhase {
        if (terminal) return .terminal_selected;
        const grant = self.restored_activation_grant orelse
            return .consumed;
        return if (grant.phase == .successor_selected)
            .successor_selected
        else
            .consumed;
    }

    fn restoredActivationGrantValidV1(
        self: *const SessionV3,
    ) bool {
        if (!self.restored_mode) return true;
        const grant = self.restored_activation_grant orelse
            return false;
        const expected: prepared_restore.ActivationGrantPhase =
            switch (grant.phase) {
                .consumed => .consumed,
                .successor_selected => .successor_selected,
                .terminal_selected => .terminal_selected,
                else => return false,
            };
        self.validateRestoredActivationGrantV1(
            expected,
        ) catch return false;
        return true;
    }
};

fn layerConfig(cfg: loader.ModelConfig) forward.LayerConfig {
    return .{
        .dim = cfg.dim,
        .hidden_dim = cfg.hidden_dim,
        .rms_eps = cfg.rms_eps,
        .seq_len = 1,
        .num_heads = cfg.num_heads,
        .head_dim = cfg.head_dim,
        .rope_theta = cfg.rope_theta,
        .num_kv_heads = cfg.num_kv_heads,
    };
}

fn forwardOne(
    cfg: forward.LayerConfig,
    weights: forward.LayerWeights,
    x_row: tensor.Tensor,
    cache: *kv.KVCache,
    layer_index: usize,
    position: usize,
    buffers: *decode_buffers.LayerBuffers,
    next_h: tensor.Tensor,
    rope_table: *const generate.PreparedTextRopeTableV1,
    phase: generate.PreparedTextPhaseV1,
    mark: ?kv.RowTxnMark,
) !void {
    try generate.forwardPreparedTextLayerSerialV1(
        cfg,
        weights,
        x_row,
        cache,
        layer_index,
        position,
        buffers,
        next_h,
        rope_table,
        phase,
        mark,
    );
}
