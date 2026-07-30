//! Typed, capability-closed contracts shared by every model-family adapter.
//!
//! These records describe meaning and bounds. They do not load weights, grant
//! device or network authority, or imply that a listed family is executable.

const std = @import("std");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const artifact_manifest_abi: u64 = 0x474d_4146_0000_0001;
pub const execution_plan_abi: u64 = 0x474d_504c_0000_0001;
pub const result_envelope_abi: u64 = 0x474d_5253_0000_0001;
pub const execution_residency_binding_abi: u64 =
    0x474d_5242_0000_0001;
pub const artifact_manifest_bytes: usize = 320;
pub const execution_plan_bytes: usize = 768;
pub const result_envelope_bytes: usize = 768;
pub const execution_residency_binding_bytes: usize = 256;
pub const allowed_flags: u64 = 0;
pub const no_capabilities: u64 = 0;

const artifact_magic = [8]u8{
    'G', 'M', 'A', 'R', 'T', '1', 0, 0,
};
const plan_magic = [8]u8{
    'G', 'M', 'P', 'L', 'A', 'N', '1', 0,
};
const result_magic = [8]u8{
    'G', 'M', 'R', 'E', 'S', '1', 0, 0,
};
const execution_residency_binding_magic = [8]u8{
    'G', 'M', 'R', 'B', 'N', 'D', '1', 0,
};
const artifact_body_bytes = artifact_manifest_bytes - 32;
const plan_body_bytes = execution_plan_bytes - 32;
const result_body_bytes = result_envelope_bytes - 32;
const execution_residency_binding_body_bytes =
    execution_residency_binding_bytes - 32;
const artifact_domain = "glacier-model-artifact-manifest-v1\x00";
const plan_domain = "glacier-model-execution-plan-v1\x00";
const result_domain = "glacier-model-result-envelope-v1\x00";
const execution_residency_binding_domain =
    "glacier-model-execution-residency-binding-v1\x00";
const publication_state_domain =
    "glacier-model-publication-state-v1\x00";
const publication_commit_domain =
    "glacier-model-publication-commit-v1\x00";

pub const ModelFamilyIdV1 = enum(u64) {
    autoregressive = 1,
    stateless_encoder = 2,
    vision_understanding = 3,
    audio_understanding = 4,
    speech_generation = 5,
    video_understanding = 6,
    image_generation = 7,
    video_generation = 8,
    audio_generation = 9,
    multimodal_fusion = 10,
    agent_policy = 11,
    retrieval = 12,
    time_series = 13,
    graph_scientific = 14,
    routed_model = 15,
    adapter_composition = 16,
    provider_hosted = 17,
    tool_executor = 18,
};

pub const OperationIdV1 = enum(u64) {
    prefill = 1,
    decode_next = 2,
    encode = 3,
    classify = 4,
    rerank = 5,
    transcribe = 6,
    synthesize = 7,
    diffuse_step = 8,
    detect = 9,
    segment = 10,
    route = 11,
    select_action = 12,
    generate_sequence = 13,
    execute_action = 14,
    retrieve = 15,
};

pub const InputKindV1 = enum(u64) {
    token_ids = 1,
    dense_tensor = 2,
    image_feature_u8 = 3,
    audio_feature_i16 = 4,
    video_feature_u8 = 5,
    latent_tensor = 6,
    typed_record = 7,
    embedding_i32 = 8,
};

pub const OutputKindV1 = enum(u64) {
    token_scores = 1,
    embedding_i32 = 2,
    class_scores = 3,
    ranked_items = 4,
    transcript = 5,
    media_chunk = 6,
    detection_set = 7,
    segmentation_mask = 8,
    typed_action = 9,
    video_segment = 10,
    token_ids = 11,
    tool_result = 12,
    retrieval_hits = 13,
};

pub const NumericalPolicyV1 = enum(u64) {
    exact_integer = 1,
    strict_float32 = 2,
    bounded_float32 = 3,
    implementation_defined = 4,
};

test "model vocabulary keeps stable additive IDs" {
    try std.testing.expectEqual(
        @as(u64, 18),
        @intFromEnum(ModelFamilyIdV1.tool_executor),
    );
    try std.testing.expectEqual(
        @as(u64, 14),
        @intFromEnum(OperationIdV1.execute_action),
    );
    try std.testing.expectEqual(
        @as(u64, 12),
        @intFromEnum(OutputKindV1.tool_result),
    );
    try std.testing.expectEqual(
        @as(u64, 15),
        @intFromEnum(OperationIdV1.retrieve),
    );
    try std.testing.expectEqual(
        @as(u64, 8),
        @intFromEnum(InputKindV1.embedding_i32),
    );
    try std.testing.expectEqual(
        @as(u64, 13),
        @intFromEnum(OutputKindV1.retrieval_hits),
    );
}

pub const UnsupportedReasonV1 = enum(u64) {
    family = 1,
    operation = 2,
    input_kind = 3,
    output_kind = 4,
    numerical_policy = 5,
    dimensions = 6,
    capabilities = 7,
};

pub const ArtifactResidencyV1 = enum(u64) {
    request_owned = 1,
    shared_read_only = 2,
};

pub const Error = error{
    BufferTooSmall,
    InvalidArtifactManifest,
    InvalidExecutionPlan,
    InvalidResultEnvelope,
    InvalidExecutionResidencyBinding,
    InvalidPublicationState,
    InvalidPublication,
    UnsupportedFamily,
    UnsupportedOperation,
    UnsupportedInputKind,
    UnsupportedOutputKind,
    UnsupportedNumericalPolicy,
    UnsupportedDimensions,
    UnsupportedCapabilities,
};

pub const ArtifactManifestV1 = struct {
    family: ModelFamilyIdV1,
    artifact_abi: u64,
    input_kind: InputKindV1,
    output_kind: OutputKindV1,
    numerical_policy: NumericalPolicyV1,
    max_batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    weight_elements: u64,
    input_element_bytes: u64,
    output_element_bytes: u64,
    weight_element_bytes: u64,
    weight_bytes: u64,
    weights_sha256: Digest,
    metadata_sha256: Digest,
    license_sha256: Digest,
    artifact_sha256: Digest,
};

pub const PlanInputV1 = struct {
    request_epoch: u64,
    generation: u64,
    batch_items: u64,
    publication_next_sequence: u64,
    maximum_absolute_output: u64,
    required_capabilities: u64 = no_capabilities,
    claim: resource_bank.Claim,
    media_object_sha256: Digest,
    processor_state_sha256: Digest,
    processor_bundle_sha256: Digest,
    cache_bundle_sha256: Digest,
    cache_payload_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
    previous_plan_sha256: Digest,
    input_schema_sha256: Digest,
    output_schema_sha256: Digest,
    scratch_bytes: u64,
};

pub const ExecutionPlanV1 = struct {
    family: ModelFamilyIdV1,
    operation: OperationIdV1,
    input_kind: InputKindV1,
    output_kind: OutputKindV1,
    numerical_policy: NumericalPolicyV1,
    request_epoch: u64,
    generation: u64,
    batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    input_bytes: u64,
    output_bytes: u64,
    scratch_bytes: u64,
    required_capabilities: u64,
    publication_next_sequence: u64,
    maximum_absolute_output: u64,
    weight_bytes: u64,
    input_element_bytes: u64,
    output_element_bytes: u64,
    claim: resource_bank.Claim,
    artifact_sha256: Digest,
    weights_sha256: Digest,
    media_object_sha256: Digest,
    processor_state_sha256: Digest,
    processor_bundle_sha256: Digest,
    cache_bundle_sha256: Digest,
    cache_payload_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
    previous_plan_sha256: Digest,
    input_schema_sha256: Digest,
    output_schema_sha256: Digest,
    plan_sha256: Digest,
};

/// Canonical projection from one execution plan's total claim to the
/// request-local claim after accounting for artifact residency.
///
/// `request_owned` retains the plan claim unchanged and carries no separate
/// resident byte count. `shared_read_only` records the complete read-only
/// artifact size separately while the plan's capsule claim remains the exact
/// sum of request-local capsule bytes and resident artifact bytes.
pub const ExecutionResidencyBindingV1 = struct {
    residency: ArtifactResidencyV1,
    resident_weight_bytes: u64,
    artifact_sha256: Digest,
    weights_sha256: Digest,
    plan_sha256: Digest,
    request_claim: resource_bank.Claim,
    binding_sha256: Digest,
};

pub const SupportRecordV1 = struct {
    family: ModelFamilyIdV1,
    operation: OperationIdV1,
    input_kind: InputKindV1,
    output_kind: OutputKindV1,
    numerical_policy: NumericalPolicyV1,
    max_batch_items: u64,
    max_input_features: u64,
    max_output_dimensions: u64,
    allowed_capabilities: u64,
};

pub const PublicationStateV1 = struct {
    request_epoch: u64,
    next_sequence: u64,
    visible_results: u64,
    artifact_sha256: Digest,
    previous_result_sha256: Digest,
};

pub const ResultEnvelopeV1 = struct {
    family: ModelFamilyIdV1,
    operation: OperationIdV1,
    output_kind: OutputKindV1,
    numerical_policy: NumericalPolicyV1,
    request_epoch: u64,
    generation: u64,
    publication_sequence: u64,
    batch_items: u64,
    output_dimensions: u64,
    output_element_bytes: u64,
    output_bytes: u64,
    resource_bank_epoch: u64,
    resource_slot_index: u64,
    resource_generation: u64,
    resource_owner_key: u64,
    claim: resource_bank.Claim,
    resource_integrity: u64,
    artifact_sha256: Digest,
    plan_sha256: Digest,
    media_object_sha256: Digest,
    processor_state_sha256: Digest,
    cache_bundle_sha256: Digest,
    cache_payload_sha256: Digest,
    ownership_sha256: Digest,
    output_sha256: Digest,
    source_mapping_sha256: Digest,
    challenge_sha256: Digest,
    previous_result_sha256: Digest,
    publication_state_before_sha256: Digest,
    publication_commit_sha256: Digest,
    adapter_sha256: Digest,
    result_sha256: Digest,
};

pub fn makeArtifactManifestV1(
    family: ModelFamilyIdV1,
    artifact_abi: u64,
    input_kind: InputKindV1,
    output_kind: OutputKindV1,
    numerical_policy: NumericalPolicyV1,
    max_batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    input_element_bytes: u64,
    output_element_bytes: u64,
    weight_element_bytes: u64,
    weights: []const u8,
    metadata_sha256: Digest,
    license_sha256: Digest,
) Error!ArtifactManifestV1 {
    return makeArtifactManifestFromDigestV1(
        family,
        artifact_abi,
        input_kind,
        output_kind,
        numerical_policy,
        max_batch_items,
        input_features,
        output_dimensions,
        input_element_bytes,
        output_element_bytes,
        weight_element_bytes,
        @intCast(weights.len),
        sha256(weights),
        metadata_sha256,
        license_sha256,
    );
}

/// Constructs a manifest from a byte count and a digest that may be computed
/// incrementally, without requiring the complete weight payload in memory.
pub fn makeArtifactManifestFromDigestV1(
    family: ModelFamilyIdV1,
    artifact_abi: u64,
    input_kind: InputKindV1,
    output_kind: OutputKindV1,
    numerical_policy: NumericalPolicyV1,
    max_batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    input_element_bytes: u64,
    output_element_bytes: u64,
    weight_element_bytes: u64,
    weight_bytes: u64,
    weights_sha256: Digest,
    metadata_sha256: Digest,
    license_sha256: Digest,
) Error!ArtifactManifestV1 {
    if (artifact_abi == 0 or max_batch_items == 0 or
        input_features == 0 or output_dimensions == 0 or
        input_element_bytes == 0 or output_element_bytes == 0 or
        weight_element_bytes == 0 or weight_bytes == 0 or
        isZero(weights_sha256) or
        isZero(metadata_sha256) or
        isZero(license_sha256))
        return Error.InvalidArtifactManifest;
    if (weight_bytes % weight_element_bytes != 0)
        return Error.InvalidArtifactManifest;
    const weight_elements = weight_bytes / weight_element_bytes;
    var value: ArtifactManifestV1 = .{
        .family = family,
        .artifact_abi = artifact_abi,
        .input_kind = input_kind,
        .output_kind = output_kind,
        .numerical_policy = numerical_policy,
        .max_batch_items = max_batch_items,
        .input_features = input_features,
        .output_dimensions = output_dimensions,
        .weight_elements = weight_elements,
        .input_element_bytes = input_element_bytes,
        .output_element_bytes = output_element_bytes,
        .weight_element_bytes = weight_element_bytes,
        .weight_bytes = weight_bytes,
        .weights_sha256 = weights_sha256,
        .metadata_sha256 = metadata_sha256,
        .license_sha256 = license_sha256,
        .artifact_sha256 = [_]u8{0} ** 32,
    };
    var encoded: [artifact_manifest_bytes]u8 = undefined;
    encodeArtifactManifestV1(value, &encoded) catch
        return Error.InvalidArtifactManifest;
    value.artifact_sha256 =
        encoded[artifact_body_bytes..artifact_manifest_bytes].*;
    return value;
}

pub fn encodeArtifactManifestV1(
    manifest: ArtifactManifestV1,
    output: []u8,
) Error!void {
    if (output.len < artifact_manifest_bytes)
        return Error.BufferTooSmall;
    const encoded = output[0..artifact_manifest_bytes];
    @memset(encoded, 0);
    @memcpy(encoded[0..8], &artifact_magic);
    writeU64(encoded, 8, artifact_manifest_abi);
    writeU64(encoded, 16, artifact_manifest_bytes);
    writeU64(encoded, 24, allowed_flags);
    writeU64(encoded, 32, @intFromEnum(manifest.family));
    writeU64(encoded, 40, manifest.artifact_abi);
    writeU64(encoded, 48, @intFromEnum(manifest.input_kind));
    writeU64(encoded, 56, @intFromEnum(manifest.output_kind));
    writeU64(encoded, 64, @intFromEnum(manifest.numerical_policy));
    writeU64(encoded, 72, manifest.max_batch_items);
    writeU64(encoded, 80, manifest.input_features);
    writeU64(encoded, 88, manifest.output_dimensions);
    writeU64(encoded, 96, manifest.weight_elements);
    writeU64(encoded, 104, manifest.weight_bytes);
    writeU64(encoded, 208, manifest.weight_element_bytes);
    writeU64(encoded, 216, manifest.input_element_bytes);
    writeU64(encoded, 224, manifest.output_element_bytes);
    @memcpy(encoded[112..144], &manifest.weights_sha256);
    @memcpy(encoded[144..176], &manifest.metadata_sha256);
    @memcpy(encoded[176..208], &manifest.license_sha256);
    const root = artifactManifestRootV1(encoded[0..artifact_body_bytes]);
    if (!isZero(manifest.artifact_sha256) and
        !std.mem.eql(u8, &root, &manifest.artifact_sha256))
        return Error.InvalidArtifactManifest;
    @memcpy(encoded[artifact_body_bytes..artifact_manifest_bytes], &root);
    _ = try decodeArtifactManifestV1(encoded);
}

pub fn decodeArtifactManifestV1(
    encoded: []const u8,
) Error!ArtifactManifestV1 {
    if (encoded.len != artifact_manifest_bytes or
        !std.mem.eql(u8, encoded[0..8], &artifact_magic) or
        readU64(encoded, 8) != artifact_manifest_abi or
        readU64(encoded, 16) != artifact_manifest_bytes or
        readU64(encoded, 24) != allowed_flags or
        !allZero(encoded[232..artifact_body_bytes]))
        return Error.InvalidArtifactManifest;
    const root = artifactManifestRootV1(encoded[0..artifact_body_bytes]);
    if (!std.mem.eql(
        u8,
        &root,
        encoded[artifact_body_bytes..artifact_manifest_bytes],
    ))
        return Error.InvalidArtifactManifest;
    const manifest: ArtifactManifestV1 = .{
        .family = std.meta.intToEnum(
            ModelFamilyIdV1,
            readU64(encoded, 32),
        ) catch return Error.InvalidArtifactManifest,
        .artifact_abi = readU64(encoded, 40),
        .input_kind = std.meta.intToEnum(
            InputKindV1,
            readU64(encoded, 48),
        ) catch return Error.InvalidArtifactManifest,
        .output_kind = std.meta.intToEnum(
            OutputKindV1,
            readU64(encoded, 56),
        ) catch return Error.InvalidArtifactManifest,
        .numerical_policy = std.meta.intToEnum(
            NumericalPolicyV1,
            readU64(encoded, 64),
        ) catch return Error.InvalidArtifactManifest,
        .max_batch_items = readU64(encoded, 72),
        .input_features = readU64(encoded, 80),
        .output_dimensions = readU64(encoded, 88),
        .weight_elements = readU64(encoded, 96),
        .weight_bytes = readU64(encoded, 104),
        .weight_element_bytes = readU64(encoded, 208),
        .input_element_bytes = readU64(encoded, 216),
        .output_element_bytes = readU64(encoded, 224),
        .weights_sha256 = encoded[112..144].*,
        .metadata_sha256 = encoded[144..176].*,
        .license_sha256 = encoded[176..208].*,
        .artifact_sha256 = root,
    };
    try validateArtifactManifestV1(manifest);
    return manifest;
}

pub fn validateArtifactManifestV1(
    manifest: ArtifactManifestV1,
) Error!void {
    const expected_weight_bytes = std.math.mul(
        u64,
        manifest.weight_elements,
        manifest.weight_element_bytes,
    ) catch return Error.InvalidArtifactManifest;
    if (manifest.artifact_abi == 0 or
        manifest.max_batch_items == 0 or
        manifest.input_features == 0 or
        manifest.output_dimensions == 0 or
        manifest.input_element_bytes == 0 or
        manifest.output_element_bytes == 0 or
        manifest.weight_element_bytes == 0 or
        manifest.weight_elements == 0 or
        manifest.weight_bytes == 0 or
        manifest.weight_bytes != expected_weight_bytes or
        isZero(manifest.weights_sha256) or
        isZero(manifest.metadata_sha256) or
        isZero(manifest.license_sha256) or
        isZero(manifest.artifact_sha256))
        return Error.InvalidArtifactManifest;
}

pub fn makeExecutionPlanV1(
    manifest: ArtifactManifestV1,
    operation: OperationIdV1,
    input: PlanInputV1,
) Error!ExecutionPlanV1 {
    try validateArtifactManifestV1(manifest);
    if (input.batch_items == 0 or
        input.batch_items > manifest.max_batch_items)
        return Error.InvalidExecutionPlan;
    const input_elements = std.math.mul(
        u64,
        input.batch_items,
        manifest.input_features,
    ) catch return Error.InvalidExecutionPlan;
    const input_bytes = std.math.mul(
        u64,
        input_elements,
        manifest.input_element_bytes,
    ) catch return Error.InvalidExecutionPlan;
    const output_elements = std.math.mul(
        u64,
        input.batch_items,
        manifest.output_dimensions,
    ) catch return Error.InvalidExecutionPlan;
    const output_bytes = std.math.mul(
        u64,
        output_elements,
        manifest.output_element_bytes,
    ) catch return Error.InvalidExecutionPlan;
    var value: ExecutionPlanV1 = .{
        .family = manifest.family,
        .operation = operation,
        .input_kind = manifest.input_kind,
        .output_kind = manifest.output_kind,
        .numerical_policy = manifest.numerical_policy,
        .request_epoch = input.request_epoch,
        .generation = input.generation,
        .batch_items = input.batch_items,
        .input_features = manifest.input_features,
        .output_dimensions = manifest.output_dimensions,
        .input_bytes = input_bytes,
        .output_bytes = output_bytes,
        .scratch_bytes = input.scratch_bytes,
        .required_capabilities = input.required_capabilities,
        .publication_next_sequence = input.publication_next_sequence,
        .maximum_absolute_output = input.maximum_absolute_output,
        .weight_bytes = manifest.weight_bytes,
        .input_element_bytes = manifest.input_element_bytes,
        .output_element_bytes = manifest.output_element_bytes,
        .claim = input.claim,
        .artifact_sha256 = manifest.artifact_sha256,
        .weights_sha256 = manifest.weights_sha256,
        .media_object_sha256 = input.media_object_sha256,
        .processor_state_sha256 = input.processor_state_sha256,
        .processor_bundle_sha256 = input.processor_bundle_sha256,
        .cache_bundle_sha256 = input.cache_bundle_sha256,
        .cache_payload_sha256 = input.cache_payload_sha256,
        .ownership_sha256 = input.ownership_sha256,
        .challenge_sha256 = input.challenge_sha256,
        .previous_plan_sha256 = input.previous_plan_sha256,
        .input_schema_sha256 = input.input_schema_sha256,
        .output_schema_sha256 = input.output_schema_sha256,
        .plan_sha256 = [_]u8{0} ** 32,
    };
    try validateExecutionPlanShapeV1(value);
    var encoded: [execution_plan_bytes]u8 = undefined;
    try encodeExecutionPlanV1(value, &encoded);
    value.plan_sha256 =
        encoded[plan_body_bytes..execution_plan_bytes].*;
    return value;
}

pub fn encodeExecutionPlanV1(
    plan: ExecutionPlanV1,
    output: []u8,
) Error!void {
    if (output.len < execution_plan_bytes)
        return Error.BufferTooSmall;
    try validateExecutionPlanShapeV1(plan);
    const encoded = output[0..execution_plan_bytes];
    @memset(encoded, 0);
    @memcpy(encoded[0..8], &plan_magic);
    writeU64(encoded, 8, execution_plan_abi);
    writeU64(encoded, 16, execution_plan_bytes);
    writeU64(encoded, 24, allowed_flags);
    writeU64(encoded, 32, @intFromEnum(plan.family));
    writeU64(encoded, 40, @intFromEnum(plan.operation));
    writeU64(encoded, 48, @intFromEnum(plan.input_kind));
    writeU64(encoded, 56, @intFromEnum(plan.output_kind));
    writeU64(encoded, 64, @intFromEnum(plan.numerical_policy));
    writeU64(encoded, 72, plan.request_epoch);
    writeU64(encoded, 80, plan.generation);
    writeU64(encoded, 88, plan.batch_items);
    writeU64(encoded, 96, plan.input_features);
    writeU64(encoded, 104, plan.output_dimensions);
    writeU64(encoded, 112, plan.input_bytes);
    writeU64(encoded, 120, plan.output_bytes);
    writeU64(encoded, 128, plan.scratch_bytes);
    writeU64(encoded, 136, plan.required_capabilities);
    writeU64(encoded, 144, plan.publication_next_sequence);
    writeU64(encoded, 152, plan.maximum_absolute_output);
    writeU64(encoded, 160, plan.weight_bytes);
    writeClaim(encoded, 176, plan.claim);
    inline for (.{ plan.artifact_sha256, plan.weights_sha256, plan.media_object_sha256, plan.processor_state_sha256, plan.processor_bundle_sha256, plan.cache_bundle_sha256, plan.cache_payload_sha256, plan.ownership_sha256, plan.challenge_sha256, plan.previous_plan_sha256, plan.input_schema_sha256, plan.output_schema_sha256 }, 0..) |digest, index|
        @memcpy(encoded[256 + index * 32 .. 288 + index * 32], &digest);
    writeU64(encoded, 640, plan.input_element_bytes);
    writeU64(encoded, 648, plan.output_element_bytes);
    const root = executionPlanRootV1(encoded[0..plan_body_bytes]);
    if (!isZero(plan.plan_sha256) and
        !std.mem.eql(u8, &root, &plan.plan_sha256))
        return Error.InvalidExecutionPlan;
    @memcpy(encoded[plan_body_bytes..execution_plan_bytes], &root);
    _ = try decodeExecutionPlanV1(encoded);
}

pub fn decodeExecutionPlanV1(
    encoded: []const u8,
) Error!ExecutionPlanV1 {
    if (encoded.len != execution_plan_bytes or
        !std.mem.eql(u8, encoded[0..8], &plan_magic) or
        readU64(encoded, 8) != execution_plan_abi or
        readU64(encoded, 16) != execution_plan_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 168) != 0 or
        !allZero(encoded[656..plan_body_bytes]))
        return Error.InvalidExecutionPlan;
    const root = executionPlanRootV1(encoded[0..plan_body_bytes]);
    if (!std.mem.eql(
        u8,
        &root,
        encoded[plan_body_bytes..execution_plan_bytes],
    ))
        return Error.InvalidExecutionPlan;
    var digests: [12]Digest = undefined;
    for (&digests, 0..) |*digest, index|
        digest.* = encoded[256 + index * 32 ..][0..32].*;
    const plan: ExecutionPlanV1 = .{
        .family = std.meta.intToEnum(ModelFamilyIdV1, readU64(encoded, 32)) catch return Error.InvalidExecutionPlan,
        .operation = std.meta.intToEnum(OperationIdV1, readU64(encoded, 40)) catch return Error.InvalidExecutionPlan,
        .input_kind = std.meta.intToEnum(InputKindV1, readU64(encoded, 48)) catch return Error.InvalidExecutionPlan,
        .output_kind = std.meta.intToEnum(OutputKindV1, readU64(encoded, 56)) catch return Error.InvalidExecutionPlan,
        .numerical_policy = std.meta.intToEnum(
            NumericalPolicyV1,
            readU64(encoded, 64),
        ) catch return Error.InvalidExecutionPlan,
        .request_epoch = readU64(encoded, 72),
        .generation = readU64(encoded, 80),
        .batch_items = readU64(encoded, 88),
        .input_features = readU64(encoded, 96),
        .output_dimensions = readU64(encoded, 104),
        .input_bytes = readU64(encoded, 112),
        .output_bytes = readU64(encoded, 120),
        .scratch_bytes = readU64(encoded, 128),
        .required_capabilities = readU64(encoded, 136),
        .publication_next_sequence = readU64(encoded, 144),
        .maximum_absolute_output = readU64(encoded, 152),
        .weight_bytes = readU64(encoded, 160),
        .input_element_bytes = readU64(encoded, 640),
        .output_element_bytes = readU64(encoded, 648),
        .claim = readClaim(encoded, 176),
        .artifact_sha256 = digests[0],
        .weights_sha256 = digests[1],
        .media_object_sha256 = digests[2],
        .processor_state_sha256 = digests[3],
        .processor_bundle_sha256 = digests[4],
        .cache_bundle_sha256 = digests[5],
        .cache_payload_sha256 = digests[6],
        .ownership_sha256 = digests[7],
        .challenge_sha256 = digests[8],
        .previous_plan_sha256 = digests[9],
        .input_schema_sha256 = digests[10],
        .output_schema_sha256 = digests[11],
        .plan_sha256 = root,
    };
    try validateExecutionPlanV1(plan);
    return plan;
}

pub fn validateExecutionPlanV1(
    plan: ExecutionPlanV1,
) Error!void {
    try validateExecutionPlanShapeV1(plan);
    if (isZero(plan.plan_sha256))
        return Error.InvalidExecutionPlan;
}

fn validateExecutionPlanShapeV1(
    plan: ExecutionPlanV1,
) Error!void {
    const input_elements = std.math.mul(
        u64,
        plan.batch_items,
        plan.input_features,
    ) catch return Error.InvalidExecutionPlan;
    const input_bytes = std.math.mul(
        u64,
        input_elements,
        plan.input_element_bytes,
    ) catch return Error.InvalidExecutionPlan;
    const output_elements = std.math.mul(
        u64,
        plan.batch_items,
        plan.output_dimensions,
    ) catch return Error.InvalidExecutionPlan;
    const output_bytes = std.math.mul(
        u64,
        output_elements,
        plan.output_element_bytes,
    ) catch return Error.InvalidExecutionPlan;
    if (plan.request_epoch == 0 or plan.generation == 0 or
        plan.batch_items == 0 or plan.input_features == 0 or
        plan.output_dimensions == 0 or plan.input_element_bytes == 0 or
        plan.output_element_bytes == 0 or
        plan.maximum_absolute_output == 0 or
        plan.input_bytes != input_bytes or plan.output_bytes != output_bytes or
        plan.weight_bytes == 0 or
        plan.claim.capsule_bytes < plan.weight_bytes or
        plan.claim.activation_bytes < plan.input_bytes or
        plan.claim.partial_bytes < plan.scratch_bytes or
        plan.claim.output_journal_bytes < plan.output_bytes or
        plan.claim.queue_slots == 0 or
        isZero(plan.artifact_sha256) or isZero(plan.weights_sha256) or
        isZero(plan.media_object_sha256) or
        isZero(plan.processor_state_sha256) or
        isZero(plan.processor_bundle_sha256) or
        isZero(plan.cache_bundle_sha256) or
        isZero(plan.cache_payload_sha256) or
        isZero(plan.ownership_sha256) or isZero(plan.challenge_sha256) or
        isZero(plan.input_schema_sha256) or
        isZero(plan.output_schema_sha256))
        return Error.InvalidExecutionPlan;
}

pub fn makeExecutionResidencyBindingV1(
    plan: ExecutionPlanV1,
    residency: ArtifactResidencyV1,
    resident_weight_bytes: u64,
    request_claim: resource_bank.Claim,
) Error!ExecutionResidencyBindingV1 {
    try requireCanonicalExecutionPlanForResidencyV1(plan);
    var value: ExecutionResidencyBindingV1 = .{
        .residency = residency,
        .resident_weight_bytes = resident_weight_bytes,
        .artifact_sha256 = plan.artifact_sha256,
        .weights_sha256 = plan.weights_sha256,
        .plan_sha256 = plan.plan_sha256,
        .request_claim = request_claim,
        .binding_sha256 = [_]u8{0} ** 32,
    };
    try validateExecutionResidencyProjectionV1(value, plan);
    var encoded: [execution_residency_binding_bytes]u8 = undefined;
    try encodeExecutionResidencyBindingV1(value, &encoded);
    value.binding_sha256 =
        encoded[execution_residency_binding_body_bytes..execution_residency_binding_bytes].*;
    try validateExecutionResidencyBindingV1(value, plan);
    return value;
}

pub fn encodeExecutionResidencyBindingV1(
    binding: ExecutionResidencyBindingV1,
    output: []u8,
) Error!void {
    if (output.len < execution_residency_binding_bytes)
        return Error.BufferTooSmall;
    try validateExecutionResidencyBindingShapeV1(binding);
    const encoded = output[0..execution_residency_binding_bytes];
    writeExecutionResidencyBindingBodyV1(binding, encoded);
    const root = executionResidencyBindingRootV1(
        encoded[0..execution_residency_binding_body_bytes],
    );
    if (!isZero(binding.binding_sha256) and
        !std.mem.eql(u8, &root, &binding.binding_sha256))
        return Error.InvalidExecutionResidencyBinding;
    @memcpy(
        encoded[execution_residency_binding_body_bytes..execution_residency_binding_bytes],
        &root,
    );
    _ = try decodeExecutionResidencyBindingV1(encoded);
}

pub fn decodeExecutionResidencyBindingV1(
    encoded: []const u8,
) Error!ExecutionResidencyBindingV1 {
    if (encoded.len != execution_residency_binding_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &execution_residency_binding_magic,
        ) or
        readU64(encoded, 8) != execution_residency_binding_abi or
        readU64(encoded, 16) != execution_residency_binding_bytes or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidExecutionResidencyBinding;
    const root = executionResidencyBindingRootV1(
        encoded[0..execution_residency_binding_body_bytes],
    );
    if (!std.mem.eql(
        u8,
        &root,
        encoded[execution_residency_binding_body_bytes..execution_residency_binding_bytes],
    ))
        return Error.InvalidExecutionResidencyBinding;
    const binding: ExecutionResidencyBindingV1 = .{
        .residency = std.meta.intToEnum(
            ArtifactResidencyV1,
            readU64(encoded, 32),
        ) catch return Error.InvalidExecutionResidencyBinding,
        .resident_weight_bytes = readU64(encoded, 40),
        .artifact_sha256 = encoded[48..80].*,
        .weights_sha256 = encoded[80..112].*,
        .plan_sha256 = encoded[112..144].*,
        .request_claim = readClaim(encoded, 144),
        .binding_sha256 = root,
    };
    try validateExecutionResidencyBindingShapeV1(binding);
    if (isZero(binding.binding_sha256))
        return Error.InvalidExecutionResidencyBinding;
    return binding;
}

pub fn validateExecutionResidencyBindingV1(
    binding: ExecutionResidencyBindingV1,
    plan: ExecutionPlanV1,
) Error!void {
    try requireCanonicalExecutionPlanForResidencyV1(plan);
    var encoded: [execution_residency_binding_bytes]u8 = undefined;
    encodeExecutionResidencyBindingV1(
        binding,
        &encoded,
    ) catch return Error.InvalidExecutionResidencyBinding;
    if (isZero(binding.binding_sha256))
        return Error.InvalidExecutionResidencyBinding;
    try validateExecutionResidencyProjectionV1(binding, plan);
}

fn requireCanonicalExecutionPlanForResidencyV1(
    plan: ExecutionPlanV1,
) Error!void {
    _ = plan.claim.hostBytes() catch
        return Error.InvalidExecutionResidencyBinding;
    var encoded: [execution_plan_bytes]u8 = undefined;
    encodeExecutionPlanV1(plan, &encoded) catch
        return Error.InvalidExecutionResidencyBinding;
}

fn validateExecutionResidencyBindingShapeV1(
    binding: ExecutionResidencyBindingV1,
) Error!void {
    if (isZero(binding.artifact_sha256) or
        isZero(binding.weights_sha256) or
        isZero(binding.plan_sha256) or
        binding.request_claim.queue_slots == 0)
        return Error.InvalidExecutionResidencyBinding;
    _ = binding.request_claim.hostBytes() catch
        return Error.InvalidExecutionResidencyBinding;
    switch (binding.residency) {
        .request_owned => {
            if (binding.resident_weight_bytes != 0)
                return Error.InvalidExecutionResidencyBinding;
        },
        .shared_read_only => {
            if (binding.resident_weight_bytes == 0)
                return Error.InvalidExecutionResidencyBinding;
            _ = std.math.add(
                u64,
                binding.request_claim.capsule_bytes,
                binding.resident_weight_bytes,
            ) catch return Error.InvalidExecutionResidencyBinding;
        },
    }
}

fn validateExecutionResidencyProjectionV1(
    binding: ExecutionResidencyBindingV1,
    plan: ExecutionPlanV1,
) Error!void {
    try validateExecutionResidencyBindingShapeV1(binding);
    var projected_claim = binding.request_claim;
    switch (binding.residency) {
        .request_owned => {},
        .shared_read_only => {
            if (binding.resident_weight_bytes != plan.weight_bytes)
                return Error.InvalidExecutionResidencyBinding;
            projected_claim.capsule_bytes = std.math.add(
                u64,
                projected_claim.capsule_bytes,
                binding.resident_weight_bytes,
            ) catch return Error.InvalidExecutionResidencyBinding;
        },
    }
    if (!std.mem.eql(
        u8,
        &binding.artifact_sha256,
        &plan.artifact_sha256,
    ) or
        !std.mem.eql(
            u8,
            &binding.weights_sha256,
            &plan.weights_sha256,
        ) or
        !std.mem.eql(u8, &binding.plan_sha256, &plan.plan_sha256) or
        !std.meta.eql(projected_claim, plan.claim))
        return Error.InvalidExecutionResidencyBinding;
}

fn writeExecutionResidencyBindingBodyV1(
    binding: ExecutionResidencyBindingV1,
    encoded: []u8,
) void {
    @memset(encoded, 0);
    @memcpy(encoded[0..8], &execution_residency_binding_magic);
    writeU64(encoded, 8, execution_residency_binding_abi);
    writeU64(encoded, 16, execution_residency_binding_bytes);
    writeU64(encoded, 24, allowed_flags);
    writeU64(encoded, 32, @intFromEnum(binding.residency));
    writeU64(encoded, 40, binding.resident_weight_bytes);
    @memcpy(encoded[48..80], &binding.artifact_sha256);
    @memcpy(encoded[80..112], &binding.weights_sha256);
    @memcpy(encoded[112..144], &binding.plan_sha256);
    writeClaim(encoded, 144, binding.request_claim);
}

pub fn requireSupportV1(
    records: []const SupportRecordV1,
    plan: ExecutionPlanV1,
) Error!void {
    var family_seen = false;
    var operation_seen = false;
    var input_seen = false;
    var output_seen = false;
    var numerical_seen = false;
    for (records) |record| {
        if (record.family != plan.family) continue;
        family_seen = true;
        if (record.operation != plan.operation) continue;
        operation_seen = true;
        if (record.input_kind != plan.input_kind) continue;
        input_seen = true;
        if (record.output_kind != plan.output_kind) continue;
        output_seen = true;
        if (record.numerical_policy != plan.numerical_policy) continue;
        numerical_seen = true;
        if (plan.batch_items > record.max_batch_items or
            plan.input_features > record.max_input_features or
            plan.output_dimensions > record.max_output_dimensions)
            return Error.UnsupportedDimensions;
        if (plan.required_capabilities & ~record.allowed_capabilities != 0)
            return Error.UnsupportedCapabilities;
        return;
    }
    if (!family_seen) return Error.UnsupportedFamily;
    if (!operation_seen) return Error.UnsupportedOperation;
    if (!input_seen) return Error.UnsupportedInputKind;
    if (!output_seen) return Error.UnsupportedOutputKind;
    if (!numerical_seen) return Error.UnsupportedNumericalPolicy;
    return Error.UnsupportedDimensions;
}

pub fn initializePublicationStateV1(
    request_epoch: u64,
    artifact_sha256: Digest,
) Error!PublicationStateV1 {
    if (request_epoch == 0 or isZero(artifact_sha256))
        return Error.InvalidPublicationState;
    return .{
        .request_epoch = request_epoch,
        .next_sequence = 0,
        .visible_results = 0,
        .artifact_sha256 = artifact_sha256,
        .previous_result_sha256 = [_]u8{0} ** 32,
    };
}

pub fn publicationStateRootV1(
    state: PublicationStateV1,
) Error!Digest {
    if (state.request_epoch == 0 or isZero(state.artifact_sha256) or
        state.next_sequence != state.visible_results)
        return Error.InvalidPublicationState;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(publication_state_domain);
    hashU64(&hash, state.request_epoch);
    hashU64(&hash, state.next_sequence);
    hashU64(&hash, state.visible_results);
    hash.update(&state.artifact_sha256);
    hash.update(&state.previous_result_sha256);
    return hash.finalResult();
}

pub fn prepareResultEnvelopeV1(
    state: PublicationStateV1,
    plan: ExecutionPlanV1,
    receipt: resource_bank.Receipt,
    output_sha256: Digest,
    source_mapping_sha256: Digest,
    adapter_sha256: Digest,
) Error!ResultEnvelopeV1 {
    try validateExecutionPlanV1(plan);
    const state_before = try publicationStateRootV1(state);
    if (state.request_epoch != plan.request_epoch or
        state.next_sequence != plan.publication_next_sequence or
        !std.mem.eql(u8, &state.artifact_sha256, &plan.artifact_sha256) or
        !std.meta.eql(receipt.claim, plan.claim) or
        isZero(output_sha256) or isZero(source_mapping_sha256) or
        isZero(adapter_sha256))
        return Error.InvalidPublication;
    return buildResultEnvelopeV1(
        state,
        plan,
        receipt,
        state_before,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );
}

/// Prepare a ResultEnvelope whose charged claim follows the request-local
/// projection recorded by an ExecutionResidencyBinding. Receipt integrity is
/// structural; callers that require live ownership must separately validate
/// the Receipt against its originating ResourceBank.
pub fn prepareResidencyResultEnvelopeV1(
    state: PublicationStateV1,
    plan: ExecutionPlanV1,
    binding: ExecutionResidencyBindingV1,
    receipt: resource_bank.Receipt,
    output_sha256: Digest,
    source_mapping_sha256: Digest,
    adapter_sha256: Digest,
) Error!ResultEnvelopeV1 {
    try validateExecutionResidencyBindingV1(binding, plan);
    const state_before = try publicationStateRootV1(state);
    if (state.request_epoch != plan.request_epoch or
        state.next_sequence != plan.publication_next_sequence or
        !std.mem.eql(u8, &state.artifact_sha256, &plan.artifact_sha256) or
        !resource_bank.receiptIntegrityValidV1(receipt) or
        !std.meta.eql(receipt.claim, binding.request_claim) or
        isZero(output_sha256) or isZero(source_mapping_sha256) or
        isZero(adapter_sha256))
        return Error.InvalidPublication;
    const result = try buildResultEnvelopeV1(
        state,
        plan,
        receipt,
        state_before,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );
    try validateResidencyResultEnvelopeV1(
        state,
        plan,
        binding,
        receipt,
        result,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );
    return result;
}

fn buildResultEnvelopeV1(
    state: PublicationStateV1,
    plan: ExecutionPlanV1,
    receipt: resource_bank.Receipt,
    state_before: Digest,
    output_sha256: Digest,
    source_mapping_sha256: Digest,
    adapter_sha256: Digest,
) Error!ResultEnvelopeV1 {
    var result: ResultEnvelopeV1 = .{
        .family = plan.family,
        .operation = plan.operation,
        .output_kind = plan.output_kind,
        .numerical_policy = plan.numerical_policy,
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .publication_sequence = state.next_sequence,
        .batch_items = plan.batch_items,
        .output_dimensions = plan.output_dimensions,
        .output_element_bytes = plan.output_element_bytes,
        .output_bytes = plan.output_bytes,
        .resource_bank_epoch = receipt.bank_epoch,
        .resource_slot_index = receipt.slot_index,
        .resource_generation = receipt.generation,
        .resource_owner_key = receipt.owner_key,
        .claim = receipt.claim,
        .resource_integrity = receipt.integrity,
        .artifact_sha256 = plan.artifact_sha256,
        .plan_sha256 = plan.plan_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .processor_state_sha256 = plan.processor_state_sha256,
        .cache_bundle_sha256 = plan.cache_bundle_sha256,
        .cache_payload_sha256 = plan.cache_payload_sha256,
        .ownership_sha256 = plan.ownership_sha256,
        .output_sha256 = output_sha256,
        .source_mapping_sha256 = source_mapping_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .previous_result_sha256 = state.previous_result_sha256,
        .publication_state_before_sha256 = state_before,
        .publication_commit_sha256 = [_]u8{0} ** 32,
        .adapter_sha256 = adapter_sha256,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.publication_commit_sha256 = publicationCommitRootV1(result);
    var encoded: [result_envelope_bytes]u8 = undefined;
    try encodeResultEnvelopeV1(result, &encoded);
    result.result_sha256 =
        encoded[result_body_bytes..result_envelope_bytes].*;
    return result;
}

pub fn encodeResultEnvelopeV1(
    result: ResultEnvelopeV1,
    output: []u8,
) Error!void {
    if (output.len < result_envelope_bytes)
        return Error.BufferTooSmall;
    try validateResultEnvelopeShapeV1(result);
    const encoded = output[0..result_envelope_bytes];
    @memset(encoded, 0);
    @memcpy(encoded[0..8], &result_magic);
    writeU64(encoded, 8, result_envelope_abi);
    writeU64(encoded, 16, result_envelope_bytes);
    writeU64(encoded, 24, allowed_flags);
    writeU64(encoded, 32, @intFromEnum(result.family));
    writeU64(encoded, 40, @intFromEnum(result.operation));
    writeU64(encoded, 48, @intFromEnum(result.output_kind));
    writeU64(encoded, 56, @intFromEnum(result.numerical_policy));
    writeU64(encoded, 64, result.request_epoch);
    writeU64(encoded, 72, result.generation);
    writeU64(encoded, 80, result.publication_sequence);
    writeU64(encoded, 88, result.batch_items);
    writeU64(encoded, 96, result.output_dimensions);
    writeU64(encoded, 104, result.output_bytes);
    writeU64(encoded, 112, result.resource_bank_epoch);
    writeU64(encoded, 120, result.resource_slot_index);
    writeU64(encoded, 128, result.resource_generation);
    writeU64(encoded, 136, result.resource_owner_key);
    writeClaim(encoded, 144, result.claim);
    writeU64(encoded, 224, result.resource_integrity);
    writeU64(encoded, 232, result.output_element_bytes);
    inline for (.{ result.artifact_sha256, result.plan_sha256, result.media_object_sha256, result.processor_state_sha256, result.cache_bundle_sha256, result.cache_payload_sha256, result.ownership_sha256, result.output_sha256, result.source_mapping_sha256, result.challenge_sha256, result.previous_result_sha256, result.publication_state_before_sha256, result.publication_commit_sha256, result.adapter_sha256 }, 0..) |digest, index|
        @memcpy(encoded[240 + index * 32 .. 272 + index * 32], &digest);
    const root = resultEnvelopeRootV1(encoded[0..result_body_bytes]);
    if (!isZero(result.result_sha256) and
        !std.mem.eql(u8, &root, &result.result_sha256))
        return Error.InvalidResultEnvelope;
    @memcpy(encoded[result_body_bytes..result_envelope_bytes], &root);
    _ = try decodeResultEnvelopeV1(encoded);
}

pub fn decodeResultEnvelopeV1(
    encoded: []const u8,
) Error!ResultEnvelopeV1 {
    if (encoded.len != result_envelope_bytes or
        !std.mem.eql(u8, encoded[0..8], &result_magic) or
        readU64(encoded, 8) != result_envelope_abi or
        readU64(encoded, 16) != result_envelope_bytes or
        readU64(encoded, 24) != allowed_flags or
        !allZero(encoded[688..result_body_bytes]))
        return Error.InvalidResultEnvelope;
    const root = resultEnvelopeRootV1(encoded[0..result_body_bytes]);
    if (!std.mem.eql(
        u8,
        &root,
        encoded[result_body_bytes..result_envelope_bytes],
    ))
        return Error.InvalidResultEnvelope;
    var digests: [14]Digest = undefined;
    for (&digests, 0..) |*digest, index|
        digest.* = encoded[240 + index * 32 ..][0..32].*;
    const result: ResultEnvelopeV1 = .{
        .family = std.meta.intToEnum(ModelFamilyIdV1, readU64(encoded, 32)) catch return Error.InvalidResultEnvelope,
        .operation = std.meta.intToEnum(OperationIdV1, readU64(encoded, 40)) catch return Error.InvalidResultEnvelope,
        .output_kind = std.meta.intToEnum(OutputKindV1, readU64(encoded, 48)) catch return Error.InvalidResultEnvelope,
        .numerical_policy = std.meta.intToEnum(
            NumericalPolicyV1,
            readU64(encoded, 56),
        ) catch return Error.InvalidResultEnvelope,
        .request_epoch = readU64(encoded, 64),
        .generation = readU64(encoded, 72),
        .publication_sequence = readU64(encoded, 80),
        .batch_items = readU64(encoded, 88),
        .output_dimensions = readU64(encoded, 96),
        .output_bytes = readU64(encoded, 104),
        .output_element_bytes = readU64(encoded, 232),
        .resource_bank_epoch = readU64(encoded, 112),
        .resource_slot_index = readU64(encoded, 120),
        .resource_generation = readU64(encoded, 128),
        .resource_owner_key = readU64(encoded, 136),
        .claim = readClaim(encoded, 144),
        .resource_integrity = readU64(encoded, 224),
        .artifact_sha256 = digests[0],
        .plan_sha256 = digests[1],
        .media_object_sha256 = digests[2],
        .processor_state_sha256 = digests[3],
        .cache_bundle_sha256 = digests[4],
        .cache_payload_sha256 = digests[5],
        .ownership_sha256 = digests[6],
        .output_sha256 = digests[7],
        .source_mapping_sha256 = digests[8],
        .challenge_sha256 = digests[9],
        .previous_result_sha256 = digests[10],
        .publication_state_before_sha256 = digests[11],
        .publication_commit_sha256 = digests[12],
        .adapter_sha256 = digests[13],
        .result_sha256 = root,
    };
    try validateResultEnvelopeV1(result);
    return result;
}

pub fn validateResultEnvelopeV1(
    result: ResultEnvelopeV1,
) Error!void {
    try validateResultEnvelopeShapeV1(result);
    if (isZero(result.result_sha256))
        return Error.InvalidResultEnvelope;
}

/// Validate every field shared by the execution plan and result, together
/// with the request-local charged claim projected by the residency binding.
pub fn validateExecutionResidencyResultV1(
    plan: ExecutionPlanV1,
    binding: ExecutionResidencyBindingV1,
    result: ResultEnvelopeV1,
) Error!void {
    try validateExecutionResidencyBindingV1(binding, plan);
    try requireCanonicalResultEnvelopeV1(result);
    if (result.family != plan.family or
        result.operation != plan.operation or
        result.output_kind != plan.output_kind or
        result.numerical_policy != plan.numerical_policy or
        result.request_epoch != plan.request_epoch or
        result.generation != plan.generation or
        result.publication_sequence != plan.publication_next_sequence or
        result.batch_items != plan.batch_items or
        result.output_dimensions != plan.output_dimensions or
        result.output_element_bytes != plan.output_element_bytes or
        result.output_bytes != plan.output_bytes or
        !std.meta.eql(result.claim, binding.request_claim) or
        !std.mem.eql(u8, &result.artifact_sha256, &plan.artifact_sha256) or
        !std.mem.eql(u8, &result.plan_sha256, &plan.plan_sha256) or
        !std.mem.eql(
            u8,
            &result.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &result.processor_state_sha256,
            &plan.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &result.cache_bundle_sha256,
            &plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &result.cache_payload_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &result.ownership_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &result.challenge_sha256,
            &plan.challenge_sha256,
        ))
        return Error.InvalidPublication;
}

/// Contextually validate a residency-aware ResultEnvelope without mutating
/// publication state. The caller performs the explicit commit separately.
pub fn validateResidencyResultEnvelopeV1(
    state: PublicationStateV1,
    plan: ExecutionPlanV1,
    binding: ExecutionResidencyBindingV1,
    receipt: resource_bank.Receipt,
    result: ResultEnvelopeV1,
    output_sha256: Digest,
    source_mapping_sha256: Digest,
    adapter_sha256: Digest,
) Error!void {
    try validateExecutionResidencyResultV1(plan, binding, result);
    const state_before = try publicationStateRootV1(state);
    if (!resource_bank.receiptIntegrityValidV1(receipt) or
        !std.meta.eql(receipt.claim, binding.request_claim) or
        result.resource_bank_epoch != receipt.bank_epoch or
        result.resource_slot_index != receipt.slot_index or
        result.resource_generation != receipt.generation or
        result.resource_owner_key != receipt.owner_key or
        !std.meta.eql(result.claim, receipt.claim) or
        result.resource_integrity != receipt.integrity or
        state.request_epoch != result.request_epoch or
        state.next_sequence != result.publication_sequence or
        !std.mem.eql(u8, &state.artifact_sha256, &result.artifact_sha256) or
        !std.mem.eql(
            u8,
            &state.previous_result_sha256,
            &result.previous_result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state_before,
            &result.publication_state_before_sha256,
        ) or
        !std.mem.eql(u8, &output_sha256, &result.output_sha256) or
        !std.mem.eql(
            u8,
            &source_mapping_sha256,
            &result.source_mapping_sha256,
        ) or
        !std.mem.eql(u8, &adapter_sha256, &result.adapter_sha256))
        return Error.InvalidPublication;
}

fn requireCanonicalResultEnvelopeV1(
    result: ResultEnvelopeV1,
) Error!void {
    var encoded: [result_envelope_bytes]u8 = undefined;
    encodeResultEnvelopeV1(result, &encoded) catch
        return Error.InvalidResultEnvelope;
}

fn validateResultEnvelopeShapeV1(
    result: ResultEnvelopeV1,
) Error!void {
    const output_elements = std.math.mul(
        u64,
        result.batch_items,
        result.output_dimensions,
    ) catch return Error.InvalidResultEnvelope;
    const output_bytes = std.math.mul(
        u64,
        output_elements,
        result.output_element_bytes,
    ) catch return Error.InvalidResultEnvelope;
    if (result.request_epoch == 0 or result.generation == 0 or
        result.batch_items == 0 or result.output_dimensions == 0 or
        result.output_element_bytes == 0 or
        result.output_bytes != output_bytes or
        result.resource_bank_epoch == 0 or
        result.resource_generation == 0 or
        result.resource_owner_key == 0 or result.resource_integrity == 0 or
        result.claim.output_journal_bytes < result.output_bytes or
        result.claim.queue_slots == 0 or
        isZero(result.artifact_sha256) or isZero(result.plan_sha256) or
        isZero(result.media_object_sha256) or
        isZero(result.processor_state_sha256) or
        isZero(result.cache_bundle_sha256) or
        isZero(result.cache_payload_sha256) or
        isZero(result.ownership_sha256) or isZero(result.output_sha256) or
        isZero(result.source_mapping_sha256) or
        isZero(result.challenge_sha256) or
        isZero(result.publication_state_before_sha256) or
        isZero(result.publication_commit_sha256) or
        isZero(result.adapter_sha256))
        return Error.InvalidResultEnvelope;
    if (!std.mem.eql(
        u8,
        &publicationCommitRootV1(result),
        &result.publication_commit_sha256,
    ))
        return Error.InvalidResultEnvelope;
}

pub fn commitResultV1(
    state: *PublicationStateV1,
    result: ResultEnvelopeV1,
) Error!void {
    try requireCanonicalResultEnvelopeV1(result);
    const before = try publicationStateRootV1(state.*);
    if (state.request_epoch != result.request_epoch or
        state.next_sequence != result.publication_sequence or
        !std.mem.eql(u8, &state.artifact_sha256, &result.artifact_sha256) or
        !std.mem.eql(
            u8,
            &state.previous_result_sha256,
            &result.previous_result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &before,
            &result.publication_state_before_sha256,
        ))
        return Error.InvalidPublication;
    state.next_sequence = std.math.add(
        u64,
        state.next_sequence,
        1,
    ) catch return Error.InvalidPublication;
    state.visible_results = std.math.add(
        u64,
        state.visible_results,
        1,
    ) catch return Error.InvalidPublication;
    state.previous_result_sha256 = result.result_sha256;
}

pub fn artifactManifestRootV1(body: []const u8) Digest {
    return domainRootV1(artifact_domain, body);
}

pub fn executionPlanRootV1(body: []const u8) Digest {
    return domainRootV1(plan_domain, body);
}

pub fn resultEnvelopeRootV1(body: []const u8) Digest {
    return domainRootV1(result_domain, body);
}

pub fn executionResidencyBindingRootV1(
    body: []const u8,
) Digest {
    return domainRootV1(execution_residency_binding_domain, body);
}

fn publicationCommitRootV1(result: ResultEnvelopeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(publication_commit_domain);
    hash.update(&result.publication_state_before_sha256);
    hash.update(&result.plan_sha256);
    hash.update(&result.output_sha256);
    hash.update(&result.source_mapping_sha256);
    hash.update(&result.previous_result_sha256);
    hash.update(&result.adapter_sha256);
    hashU64(&hash, result.publication_sequence);
    return hash.finalResult();
}

fn domainRootV1(domain: []const u8, body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(body);
    return hash.finalResult();
}

pub fn sha256(bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes);
    return hash.finalResult();
}

fn writeClaim(output: []u8, offset: usize, claim: resource_bank.Claim) void {
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        writeU64(output, offset + index * 8, @field(claim, field.name));
}

fn readClaim(input: []const u8, offset: usize) resource_bank.Claim {
    var claim: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        @field(claim, field.name) = readU64(input, offset + index * 8);
    return claim;
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(
        u64,
        output[offset .. offset + 8][0..8],
        value,
        .little,
    );
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

fn allZero(bytes: []const u8) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

test "typed model contracts are canonical and fail closed" {
    const weights = [_]u8{
        1,
        2,
        3,
        4,
        @bitCast(@as(i8, -1)),
        @bitCast(@as(i8, -2)),
        1,
        2,
    };
    const manifest = try makeArtifactManifestV1(
        .vision_understanding,
        0x5649_5349_4f4e_0001,
        .image_feature_u8,
        .embedding_i32,
        .exact_integer,
        2,
        4,
        2,
        1,
        4,
        1,
        &weights,
        sha256("fixture metadata"),
        sha256("fixture license"),
    );
    const prehashed_manifest = try makeArtifactManifestFromDigestV1(
        .vision_understanding,
        0x5649_5349_4f4e_0001,
        .image_feature_u8,
        .embedding_i32,
        .exact_integer,
        2,
        4,
        2,
        1,
        4,
        1,
        weights.len,
        sha256(&weights),
        sha256("fixture metadata"),
        sha256("fixture license"),
    );
    try std.testing.expectEqual(manifest, prehashed_manifest);
    try std.testing.expectEqual(
        @as(u64, 11),
        @intFromEnum(OutputKindV1.token_ids),
    );
    try std.testing.expectError(
        Error.InvalidArtifactManifest,
        makeArtifactManifestFromDigestV1(
            .vision_understanding,
            0x5649_5349_4f4e_0001,
            .image_feature_u8,
            .embedding_i32,
            .exact_integer,
            2,
            4,
            2,
            1,
            4,
            3,
            weights.len,
            sha256(&weights),
            sha256("fixture metadata"),
            sha256("fixture license"),
        ),
    );
    var manifest_bytes: [artifact_manifest_bytes]u8 = undefined;
    try encodeArtifactManifestV1(manifest, &manifest_bytes);
    try std.testing.expectEqual(
        manifest,
        try decodeArtifactManifestV1(&manifest_bytes),
    );
    var claim: resource_bank.Claim = .{
        .capsule_bytes = weights.len,
        .activation_bytes = 8,
        .partial_bytes = 16,
        .output_journal_bytes = 16,
        .queue_slots = 1,
    };
    const plan_input: PlanInputV1 = .{
        .request_epoch = 41,
        .generation = 7,
        .batch_items = 2,
        .publication_next_sequence = 0,
        .maximum_absolute_output = 4096,
        .claim = claim,
        .media_object_sha256 = sha256("media"),
        .processor_state_sha256 = sha256("processor state"),
        .processor_bundle_sha256 = sha256("processor bundle"),
        .cache_bundle_sha256 = sha256("cache bundle"),
        .cache_payload_sha256 = sha256("cache payload"),
        .ownership_sha256 = sha256("ownership"),
        .challenge_sha256 = sha256("challenge"),
        .previous_plan_sha256 = [_]u8{0} ** 32,
        .input_schema_sha256 = sha256("input schema"),
        .output_schema_sha256 = sha256("output schema"),
        .scratch_bytes = 16,
    };
    const plan = try makeExecutionPlanV1(manifest, .encode, plan_input);
    var plan_bytes: [execution_plan_bytes]u8 = undefined;
    try encodeExecutionPlanV1(plan, &plan_bytes);
    try std.testing.expectEqual(plan, try decodeExecutionPlanV1(&plan_bytes));
    const support = [_]SupportRecordV1{.{
        .family = .vision_understanding,
        .operation = .encode,
        .input_kind = .image_feature_u8,
        .output_kind = .embedding_i32,
        .numerical_policy = .exact_integer,
        .max_batch_items = 2,
        .max_input_features = 4,
        .max_output_dimensions = 2,
        .allowed_capabilities = no_capabilities,
    }};
    try requireSupportV1(&support, plan);
    var unsupported = plan;
    unsupported.operation = .classify;
    try std.testing.expectError(
        Error.UnsupportedOperation,
        requireSupportV1(&support, unsupported),
    );

    var state = try initializePublicationStateV1(
        plan.request_epoch,
        plan.artifact_sha256,
    );
    const receipt: resource_bank.Receipt = .{
        .bank_epoch = 3,
        .slot_index = 1,
        .generation = 9,
        .owner_key = 77,
        .claim = claim,
        .integrity = 88,
    };
    const result = try prepareResultEnvelopeV1(
        state,
        plan,
        receipt,
        sha256(&[_]u8{
            0x1e, 0, 0, 0,
            0x06, 0, 0, 0,
            0x46, 0, 0, 0,
            0x06, 0, 0, 0,
        }),
        sha256("mapping"),
        sha256("adapter"),
    );
    var result_bytes: [result_envelope_bytes]u8 = undefined;
    try encodeResultEnvelopeV1(result, &result_bytes);
    try std.testing.expectEqual(
        result,
        try decodeResultEnvelopeV1(&result_bytes),
    );
    try commitResultV1(&state, result);
    try std.testing.expectEqual(@as(u64, 1), state.visible_results);
    try std.testing.expectEqual(result.result_sha256, state.previous_result_sha256);
    var expected_artifact: Digest = undefined;
    var expected_plan: Digest = undefined;
    var expected_result: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_artifact,
        "62ded12535e6029577afbf588c97077a" ++
            "88a12ffb03863eec476e75d49d003750",
    );
    _ = try std.fmt.hexToBytes(
        &expected_plan,
        "7b931bcf9e4858b0c433d893812b770d" ++
            "eff7d3b022cf40aebec164bef4945786",
    );
    _ = try std.fmt.hexToBytes(
        &expected_result,
        "b522a4ed75ba657638a8fc162833ed87" ++
            "749647b3ba6cfdd73661de41041bd6c9",
    );
    try std.testing.expectEqual(expected_artifact, manifest.artifact_sha256);
    try std.testing.expectEqual(expected_plan, plan.plan_sha256);
    try std.testing.expectEqual(expected_result, result.result_sha256);

    // The independent Python reference extends this exact three-record fixture
    // with a structurally valid shared-residency Receipt. Pin the same fourth
    // wire and projected result here so parity is bidirectional.
    var golden_request_claim = claim;
    golden_request_claim.capsule_bytes -= @intCast(weights.len);
    const golden_shared_binding =
        try makeExecutionResidencyBindingV1(
            plan,
            .shared_read_only,
            @intCast(weights.len),
            golden_request_claim,
        );
    var golden_binding_bytes: [execution_residency_binding_bytes]u8 = undefined;
    try encodeExecutionResidencyBindingV1(
        golden_shared_binding,
        &golden_binding_bytes,
    );
    try std.testing.expectEqual(
        golden_shared_binding,
        try decodeExecutionResidencyBindingV1(
            &golden_binding_bytes,
        ),
    );
    const golden_shared_receipt: resource_bank.Receipt = .{
        .bank_epoch = 3,
        .slot_index = 1,
        .generation = 9,
        .owner_key = 77,
        .claim = golden_request_claim,
        .integrity = 0x8c92_0168_12c6_ad3d,
    };
    try std.testing.expect(
        resource_bank.receiptIntegrityValidV1(
            golden_shared_receipt,
        ),
    );
    const golden_output_sha256 = sha256(&[_]u8{
        0x1e, 0, 0, 0,
        0x06, 0, 0, 0,
        0x46, 0, 0, 0,
        0x06, 0, 0, 0,
    });
    const golden_mapping_sha256 = sha256("mapping");
    const golden_adapter_sha256 = sha256("adapter");
    var golden_shared_state = try initializePublicationStateV1(
        plan.request_epoch,
        plan.artifact_sha256,
    );
    const golden_shared_result =
        try prepareResidencyResultEnvelopeV1(
            golden_shared_state,
            plan,
            golden_shared_binding,
            golden_shared_receipt,
            golden_output_sha256,
            golden_mapping_sha256,
            golden_adapter_sha256,
        );
    try validateResidencyResultEnvelopeV1(
        golden_shared_state,
        plan,
        golden_shared_binding,
        golden_shared_receipt,
        golden_shared_result,
        golden_output_sha256,
        golden_mapping_sha256,
        golden_adapter_sha256,
    );
    var expected_binding: Digest = undefined;
    var expected_shared_result: Digest = undefined;
    var expected_shared_commit: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_binding,
        "86c0f91dcf7012f12619585092ab22ab" ++
            "870985be1a92359a844551f67c1462a6",
    );
    _ = try std.fmt.hexToBytes(
        &expected_shared_result,
        "ca3c4184081d77603bc01da8458d73bd" ++
            "ef9143ca68c8f3e3615be4802e8358fc",
    );
    _ = try std.fmt.hexToBytes(
        &expected_shared_commit,
        "fa7cf84c037d528f0af5570b3f7e7474" ++
            "489f6686123925e75c6df4b57836cb33",
    );
    try std.testing.expectEqual(
        expected_binding,
        golden_shared_binding.binding_sha256,
    );
    try std.testing.expectEqual(
        expected_shared_result,
        golden_shared_result.result_sha256,
    );
    try std.testing.expectEqual(
        expected_shared_commit,
        golden_shared_result.publication_commit_sha256,
    );
    try commitResultV1(
        &golden_shared_state,
        golden_shared_result,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        golden_shared_state.visible_results,
    );

    for (&manifest_bytes, 0..) |_, index| {
        var mutated = manifest_bytes;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidArtifactManifest,
            decodeArtifactManifestV1(&mutated),
        );
    }
    for (&plan_bytes, 0..) |_, index| {
        var mutated = plan_bytes;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidExecutionPlan,
            decodeExecutionPlanV1(&mutated),
        );
    }
    for (&result_bytes, 0..) |_, index| {
        var mutated = result_bytes;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidResultEnvelope,
            decodeResultEnvelopeV1(&mutated),
        );
    }
    var unknown_family = manifest_bytes;
    writeU64(&unknown_family, 32, std.math.maxInt(u64));
    const unknown_root = artifactManifestRootV1(
        unknown_family[0..artifact_body_bytes],
    );
    @memcpy(
        unknown_family[artifact_body_bytes..artifact_manifest_bytes],
        &unknown_root,
    );
    try std.testing.expectError(
        Error.InvalidArtifactManifest,
        decodeArtifactManifestV1(&unknown_family),
    );
    var unknown_operation = plan_bytes;
    writeU64(&unknown_operation, 40, std.math.maxInt(u64));
    const unknown_plan_root = executionPlanRootV1(
        unknown_operation[0..plan_body_bytes],
    );
    @memcpy(
        unknown_operation[plan_body_bytes..execution_plan_bytes],
        &unknown_plan_root,
    );
    try std.testing.expectError(
        Error.InvalidExecutionPlan,
        decodeExecutionPlanV1(&unknown_operation),
    );
    claim.queue_slots = 0;
    var wrong_claim = plan;
    wrong_claim.claim = claim;
    try std.testing.expectError(
        Error.InvalidExecutionPlan,
        validateExecutionPlanV1(wrong_claim),
    );
}

test "token ID contract roots match the independent oracle" {
    const weights = [_]u8{ 1, 2, 3, 4, 0xff, 0xfe, 1, 2 };
    const manifest = try makeArtifactManifestFromDigestV1(
        .autoregressive,
        0x5445_5854_0000_0001,
        .token_ids,
        .token_ids,
        .exact_integer,
        1,
        4,
        1,
        4,
        4,
        1,
        weights.len,
        sha256(&weights),
        sha256("token ID fixture metadata"),
        sha256("token ID fixture license"),
    );
    const claim: resource_bank.Claim = .{
        .capsule_bytes = 8,
        .activation_bytes = 16,
        .partial_bytes = 8,
        .output_journal_bytes = 4,
        .queue_slots = 1,
    };
    const plan = try makeExecutionPlanV1(manifest, .decode_next, .{
        .request_epoch = 73,
        .generation = 5,
        .batch_items = 1,
        .publication_next_sequence = 0,
        .maximum_absolute_output = 65535,
        .claim = claim,
        .media_object_sha256 = sha256("token prompt"),
        .processor_state_sha256 = sha256("tokenizer state"),
        .processor_bundle_sha256 = sha256("tokenizer bundle"),
        .cache_bundle_sha256 = sha256("token cache bundle"),
        .cache_payload_sha256 = sha256("token cache payload"),
        .ownership_sha256 = sha256("token ownership"),
        .challenge_sha256 = sha256("token challenge"),
        .previous_plan_sha256 = [_]u8{0} ** 32,
        .input_schema_sha256 = sha256("token input schema"),
        .output_schema_sha256 = sha256("token output schema"),
        .scratch_bytes = 8,
    });
    const state = try initializePublicationStateV1(
        plan.request_epoch,
        plan.artifact_sha256,
    );
    const receipt: resource_bank.Receipt = .{
        .bank_epoch = 4,
        .slot_index = 0,
        .generation = 2,
        .owner_key = 91,
        .claim = claim,
        .integrity = 123,
    };
    const output = [_]u8{ 42, 0, 0, 0 };
    const result = try prepareResultEnvelopeV1(
        state,
        plan,
        receipt,
        sha256(&output),
        sha256("token mapping"),
        sha256("token adapter"),
    );

    var manifest_wire: [artifact_manifest_bytes]u8 = undefined;
    var plan_wire: [execution_plan_bytes]u8 = undefined;
    var result_wire: [result_envelope_bytes]u8 = undefined;
    try encodeArtifactManifestV1(manifest, &manifest_wire);
    try encodeExecutionPlanV1(plan, &plan_wire);
    try encodeResultEnvelopeV1(result, &result_wire);
    try std.testing.expectEqual(
        manifest,
        try decodeArtifactManifestV1(&manifest_wire),
    );
    try std.testing.expectEqual(plan, try decodeExecutionPlanV1(&plan_wire));
    try std.testing.expectEqual(
        result,
        try decodeResultEnvelopeV1(&result_wire),
    );

    var expected_artifact: Digest = undefined;
    var expected_plan: Digest = undefined;
    var expected_result: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_artifact,
        "e850bc468da43295e4345122eb5389ba" ++
            "e2df8e4bb003b518b0ae9b6bcbcf7843",
    );
    _ = try std.fmt.hexToBytes(
        &expected_plan,
        "9c572db5caaa229a20f4fc58bccb7dde" ++
            "43d3a92289bb1c43f1536904dfdb7276",
    );
    _ = try std.fmt.hexToBytes(
        &expected_result,
        "e87cf08d3c42efe196db681392ce3899" ++
            "6276c0a31bb5b3aae28b2a3ec54ff8ad",
    );
    try std.testing.expectEqual(expected_artifact, manifest.artifact_sha256);
    try std.testing.expectEqual(expected_plan, plan.plan_sha256);
    try std.testing.expectEqual(expected_result, result.result_sha256);
}

fn executionResidencyTestPlanV1(
    request_epoch: u64,
    input_identity: []const u8,
) !ExecutionPlanV1 {
    const weights = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const manifest = try makeArtifactManifestV1(
        .autoregressive,
        0x5445_5854_0000_0002,
        .token_ids,
        .token_ids,
        .implementation_defined,
        1,
        4,
        2,
        @sizeOf(u32),
        @sizeOf(u32),
        @sizeOf(u8),
        &weights,
        sha256("residency fixture metadata"),
        sha256("residency fixture license"),
    );
    return makeExecutionPlanV1(
        manifest,
        .generate_sequence,
        .{
            .request_epoch = request_epoch,
            .generation = 5,
            .batch_items = 1,
            .publication_next_sequence = 0,
            .maximum_absolute_output = 127,
            .claim = .{
                .capsule_bytes = weights.len,
                .activation_bytes = 16,
                .output_journal_bytes = 8,
                .queue_slots = 1,
            },
            .media_object_sha256 = sha256(input_identity),
            .processor_state_sha256 = sha256(
                "residency processor state",
            ),
            .processor_bundle_sha256 = sha256(
                "residency processor bundle",
            ),
            .cache_bundle_sha256 = sha256(
                "residency cache bundle",
            ),
            .cache_payload_sha256 = sha256(
                "residency cache payload",
            ),
            .ownership_sha256 = sha256("residency ownership"),
            .challenge_sha256 = sha256("residency challenge"),
            .previous_plan_sha256 = [_]u8{0} ** 32,
            .input_schema_sha256 = sha256(
                "residency token input schema",
            ),
            .output_schema_sha256 = sha256(
                "residency token output schema",
            ),
            .scratch_bytes = 0,
        },
    );
}

test "execution residency binding is canonical and projects exact claims" {
    try std.testing.expectEqual(
        @as(u64, 13),
        @intFromEnum(OperationIdV1.generate_sequence),
    );
    const plan = try executionResidencyTestPlanV1(
        73,
        "residency input",
    );
    var request_claim = plan.claim;
    request_claim.capsule_bytes = 0;
    const shared = try makeExecutionResidencyBindingV1(
        plan,
        .shared_read_only,
        plan.weight_bytes,
        request_claim,
    );
    try validateExecutionResidencyBindingV1(shared, plan);
    try std.testing.expectEqual(
        ArtifactResidencyV1.shared_read_only,
        shared.residency,
    );
    try std.testing.expectEqual(
        plan.weight_bytes,
        shared.resident_weight_bytes,
    );
    try std.testing.expectEqualDeep(
        request_claim,
        shared.request_claim,
    );
    var projected_claim = request_claim;
    projected_claim.capsule_bytes += shared.resident_weight_bytes;
    try std.testing.expectEqualDeep(plan.claim, projected_claim);

    var shared_wire: [execution_residency_binding_bytes]u8 = undefined;
    try encodeExecutionResidencyBindingV1(shared, &shared_wire);
    const decoded_shared =
        try decodeExecutionResidencyBindingV1(&shared_wire);
    try std.testing.expectEqualDeep(shared, decoded_shared);
    try validateExecutionResidencyBindingV1(decoded_shared, plan);
    try std.testing.expectEqual(
        shared.binding_sha256,
        executionResidencyBindingRootV1(
            shared_wire[0..execution_residency_binding_body_bytes],
        ),
    );

    const request_owned = try makeExecutionResidencyBindingV1(
        plan,
        .request_owned,
        0,
        plan.claim,
    );
    try validateExecutionResidencyBindingV1(request_owned, plan);
    var request_owned_wire: [execution_residency_binding_bytes]u8 = undefined;
    try encodeExecutionResidencyBindingV1(
        request_owned,
        &request_owned_wire,
    );
    try std.testing.expectEqualDeep(
        request_owned,
        try decodeExecutionResidencyBindingV1(&request_owned_wire),
    );
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        makeExecutionResidencyBindingV1(
            plan,
            .request_owned,
            1,
            plan.claim,
        ),
    );
    var mismatched_request_owned_claim = plan.claim;
    mismatched_request_owned_claim.activation_bytes += 1;
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        makeExecutionResidencyBindingV1(
            plan,
            .request_owned,
            0,
            mismatched_request_owned_claim,
        ),
    );
}

test "execution residency binding rejects mutation substitution and overflow" {
    const plan = try executionResidencyTestPlanV1(
        73,
        "residency input",
    );
    var request_claim = plan.claim;
    request_claim.capsule_bytes = 0;
    const binding = try makeExecutionResidencyBindingV1(
        plan,
        .shared_read_only,
        plan.weight_bytes,
        request_claim,
    );
    var wire: [execution_residency_binding_bytes]u8 = undefined;
    try encodeExecutionResidencyBindingV1(binding, &wire);
    for (&wire, 0..) |_, index| {
        var mutated_wire = wire;
        mutated_wire[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidExecutionResidencyBinding,
            decodeExecutionResidencyBindingV1(&mutated_wire),
        );
    }

    var mutated_binding = binding;
    mutated_binding.request_claim.activation_bytes += 1;
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        validateExecutionResidencyBindingV1(
            mutated_binding,
            plan,
        ),
    );
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        makeExecutionResidencyBindingV1(
            plan,
            .shared_read_only,
            plan.weight_bytes - 1,
            request_claim,
        ),
    );
    var mismatched_shared_claim = request_claim;
    mismatched_shared_claim.kv_bytes += 1;
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        makeExecutionResidencyBindingV1(
            plan,
            .shared_read_only,
            plan.weight_bytes,
            mismatched_shared_claim,
        ),
    );

    const foreign_plan = try executionResidencyTestPlanV1(
        74,
        "foreign residency input",
    );
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        validateExecutionResidencyBindingV1(binding, foreign_plan),
    );
    var foreign_request_claim = foreign_plan.claim;
    foreign_request_claim.capsule_bytes = 0;
    const foreign_binding = try makeExecutionResidencyBindingV1(
        foreign_plan,
        .shared_read_only,
        foreign_plan.weight_bytes,
        foreign_request_claim,
    );
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        validateExecutionResidencyBindingV1(
            foreign_binding,
            plan,
        ),
    );

    var aggregate_overflow_request = request_claim;
    aggregate_overflow_request.kv_bytes = std.math.maxInt(u64);
    _ = try std.math.add(
        u64,
        aggregate_overflow_request.capsule_bytes,
        plan.weight_bytes,
    );
    try std.testing.expectError(
        resource_bank.Error.ClaimOverflow,
        aggregate_overflow_request.hostBytes(),
    );
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        makeExecutionResidencyBindingV1(
            plan,
            .shared_read_only,
            plan.weight_bytes,
            aggregate_overflow_request,
        ),
    );

    var near_limit_request = plan.claim;
    near_limit_request.capsule_bytes = 1;
    near_limit_request.kv_bytes = 0;
    const fixed_request_host_bytes = try near_limit_request.hostBytes();
    near_limit_request.kv_bytes =
        std.math.maxInt(u64) - fixed_request_host_bytes - 2;
    _ = try near_limit_request.hostBytes();
    var aggregate_overflow_plan = plan;
    aggregate_overflow_plan.claim = near_limit_request;
    aggregate_overflow_plan.claim.capsule_bytes = try std.math.add(
        u64,
        near_limit_request.capsule_bytes,
        plan.weight_bytes,
    );
    try std.testing.expectError(
        resource_bank.Error.ClaimOverflow,
        aggregate_overflow_plan.claim.hostBytes(),
    );
    aggregate_overflow_plan.plan_sha256 = [_]u8{0} ** 32;
    var aggregate_overflow_plan_wire: [execution_plan_bytes]u8 =
        undefined;
    try encodeExecutionPlanV1(
        aggregate_overflow_plan,
        &aggregate_overflow_plan_wire,
    );
    aggregate_overflow_plan = try decodeExecutionPlanV1(
        &aggregate_overflow_plan_wire,
    );
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        makeExecutionResidencyBindingV1(
            aggregate_overflow_plan,
            .shared_read_only,
            plan.weight_bytes,
            near_limit_request,
        ),
    );

    var overflow_claim = request_claim;
    overflow_claim.capsule_bytes = std.math.maxInt(u64);
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        makeExecutionResidencyBindingV1(
            plan,
            .shared_read_only,
            plan.weight_bytes,
            overflow_claim,
        ),
    );
}

test "residency result envelope charges shared receipt and commits explicitly" {
    const plan = try executionResidencyTestPlanV1(
        81,
        "shared result input",
    );
    var request_claim = plan.claim;
    request_claim.capsule_bytes = 0;
    const binding = try makeExecutionResidencyBindingV1(
        plan,
        .shared_read_only,
        plan.weight_bytes,
        request_claim,
    );

    var slots: [1]resource_bank.Slot = undefined;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        0x5245_5349_4445_4e54,
    );
    const receipt = try bank.commit(
        try bank.reserve(0x5348_4152_4544, request_claim),
    );
    defer bank.release(receipt) catch unreachable;

    var state = try initializePublicationStateV1(
        plan.request_epoch,
        plan.artifact_sha256,
    );
    const state_before_prepare = state;
    const output_sha256 = sha256("shared residency output");
    const source_mapping_sha256 = sha256(
        "shared residency source mapping",
    );
    const adapter_sha256 = sha256("shared residency adapter");
    const result = try prepareResidencyResultEnvelopeV1(
        state,
        plan,
        binding,
        receipt,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );

    try std.testing.expectEqualDeep(state_before_prepare, state);
    try std.testing.expectEqualDeep(receipt.claim, result.claim);
    try std.testing.expectEqualDeep(binding.request_claim, result.claim);
    try std.testing.expect(!std.meta.eql(plan.claim, result.claim));
    var aggregate_claim = request_claim;
    aggregate_claim.capsule_bytes = try std.math.add(
        u64,
        aggregate_claim.capsule_bytes,
        binding.resident_weight_bytes,
    );
    try std.testing.expectEqualDeep(plan.claim, aggregate_claim);
    try std.testing.expectEqual(
        try plan.claim.hostBytes(),
        try std.math.add(
            u64,
            try request_claim.hostBytes(),
            binding.resident_weight_bytes,
        ),
    );

    try validateExecutionResidencyResultV1(plan, binding, result);
    try validateResidencyResultEnvelopeV1(
        state,
        plan,
        binding,
        receipt,
        result,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );
    var encoded: [result_envelope_bytes]u8 = undefined;
    try encodeResultEnvelopeV1(result, &encoded);
    const decoded = try decodeResultEnvelopeV1(&encoded);
    try std.testing.expectEqualDeep(result, decoded);
    try validateResidencyResultEnvelopeV1(
        state,
        plan,
        binding,
        receipt,
        decoded,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );
    try std.testing.expectEqual(@as(u64, 0), state.next_sequence);
    try std.testing.expectEqual(@as(u64, 0), state.visible_results);

    try commitResultV1(&state, decoded);
    try std.testing.expectEqual(@as(u64, 1), state.next_sequence);
    try std.testing.expectEqual(@as(u64, 1), state.visible_results);
    try std.testing.expectEqual(
        decoded.result_sha256,
        state.previous_result_sha256,
    );
    try std.testing.expectError(
        Error.InvalidPublication,
        validateResidencyResultEnvelopeV1(
            state,
            plan,
            binding,
            receipt,
            decoded,
            output_sha256,
            source_mapping_sha256,
            adapter_sha256,
        ),
    );
}

test "residency result envelope preserves request-owned wire parity" {
    const plan = try executionResidencyTestPlanV1(
        82,
        "request-owned result input",
    );
    const binding = try makeExecutionResidencyBindingV1(
        plan,
        .request_owned,
        0,
        plan.claim,
    );
    var slots: [1]resource_bank.Slot = undefined;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        0x5245_5155_4553_544f,
    );
    const receipt = try bank.commit(
        try bank.reserve(0x4f57_4e45_4421, plan.claim),
    );
    defer bank.release(receipt) catch unreachable;
    const state = try initializePublicationStateV1(
        plan.request_epoch,
        plan.artifact_sha256,
    );
    const output_sha256 = sha256("request-owned output");
    const source_mapping_sha256 = sha256(
        "request-owned source mapping",
    );
    const adapter_sha256 = sha256("request-owned adapter");

    const legacy_result = try prepareResultEnvelopeV1(
        state,
        plan,
        receipt,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );
    const residency_result = try prepareResidencyResultEnvelopeV1(
        state,
        plan,
        binding,
        receipt,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );
    try std.testing.expectEqualDeep(legacy_result, residency_result);

    var legacy_wire: [result_envelope_bytes]u8 = undefined;
    var residency_wire: [result_envelope_bytes]u8 = undefined;
    try encodeResultEnvelopeV1(legacy_result, &legacy_wire);
    try encodeResultEnvelopeV1(residency_result, &residency_wire);
    try std.testing.expectEqualSlices(
        u8,
        &legacy_wire,
        &residency_wire,
    );
}

test "residency result envelope rejects contextual substitutions atomically" {
    const plan = try executionResidencyTestPlanV1(
        83,
        "substitution result input",
    );
    var request_claim = plan.claim;
    request_claim.capsule_bytes = 0;
    const binding = try makeExecutionResidencyBindingV1(
        plan,
        .shared_read_only,
        plan.weight_bytes,
        request_claim,
    );
    var slots: [2]resource_bank.Slot = undefined;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        0x5355_4253_5449_5455,
    );
    const receipt = try bank.commit(
        try bank.reserve(0x5052_494d_4152_59, request_claim),
    );
    defer bank.release(receipt) catch unreachable;
    const substitute_receipt = try bank.commit(
        try bank.reserve(0x5355_4253_5449_54, request_claim),
    );
    defer bank.release(substitute_receipt) catch unreachable;

    const state = try initializePublicationStateV1(
        plan.request_epoch,
        plan.artifact_sha256,
    );
    const original_state = state;
    const output_sha256 = sha256("substitution output");
    const source_mapping_sha256 = sha256(
        "substitution source mapping",
    );
    const adapter_sha256 = sha256("substitution adapter");
    const result = try prepareResidencyResultEnvelopeV1(
        state,
        plan,
        binding,
        receipt,
        output_sha256,
        source_mapping_sha256,
        adapter_sha256,
    );

    var invalid_plan = plan;
    invalid_plan.generation += 1;
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        prepareResidencyResultEnvelopeV1(
            state,
            invalid_plan,
            binding,
            receipt,
            output_sha256,
            source_mapping_sha256,
            adapter_sha256,
        ),
    );
    var invalid_binding = binding;
    invalid_binding.binding_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidExecutionResidencyBinding,
        prepareResidencyResultEnvelopeV1(
            state,
            plan,
            invalid_binding,
            receipt,
            output_sha256,
            source_mapping_sha256,
            adapter_sha256,
        ),
    );
    var invalid_receipt = receipt;
    invalid_receipt.integrity ^= 1;
    try std.testing.expectError(
        Error.InvalidPublication,
        prepareResidencyResultEnvelopeV1(
            state,
            plan,
            binding,
            invalid_receipt,
            output_sha256,
            source_mapping_sha256,
            adapter_sha256,
        ),
    );
    try std.testing.expectError(
        Error.InvalidPublication,
        validateResidencyResultEnvelopeV1(
            state,
            plan,
            binding,
            substitute_receipt,
            result,
            output_sha256,
            source_mapping_sha256,
            adapter_sha256,
        ),
    );

    const substituted_result = try prepareResidencyResultEnvelopeV1(
        state,
        plan,
        binding,
        receipt,
        sha256("substituted output"),
        source_mapping_sha256,
        adapter_sha256,
    );
    try std.testing.expectError(
        Error.InvalidPublication,
        validateResidencyResultEnvelopeV1(
            state,
            plan,
            binding,
            receipt,
            substituted_result,
            output_sha256,
            source_mapping_sha256,
            adapter_sha256,
        ),
    );
    inline for (.{
        .{
            sha256("substituted expected output"),
            source_mapping_sha256,
            adapter_sha256,
        },
        .{
            output_sha256,
            sha256("substituted expected source mapping"),
            adapter_sha256,
        },
        .{
            output_sha256,
            source_mapping_sha256,
            sha256("substituted expected adapter"),
        },
    }) |digests| {
        try std.testing.expectError(
            Error.InvalidPublication,
            validateResidencyResultEnvelopeV1(
                state,
                plan,
                binding,
                receipt,
                result,
                digests[0],
                digests[1],
                digests[2],
            ),
        );
    }

    var noncanonical_result = result;
    noncanonical_result.result_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidResultEnvelope,
        validateExecutionResidencyResultV1(
            plan,
            binding,
            noncanonical_result,
        ),
    );
    var commit_state = state;
    try std.testing.expectError(
        Error.InvalidResultEnvelope,
        commitResultV1(&commit_state, noncanonical_result),
    );
    try std.testing.expectEqualDeep(original_state, commit_state);
    try std.testing.expectEqualDeep(original_state, state);
}
