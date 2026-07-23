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
pub const artifact_manifest_bytes: usize = 320;
pub const execution_plan_bytes: usize = 768;
pub const result_envelope_bytes: usize = 768;
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
const artifact_body_bytes = artifact_manifest_bytes - 32;
const plan_body_bytes = execution_plan_bytes - 32;
const result_body_bytes = result_envelope_bytes - 32;
const artifact_domain = "glacier-model-artifact-manifest-v1\x00";
const plan_domain = "glacier-model-execution-plan-v1\x00";
const result_domain = "glacier-model-result-envelope-v1\x00";
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
};

pub const InputKindV1 = enum(u64) {
    token_ids = 1,
    dense_tensor = 2,
    image_feature_u8 = 3,
    audio_feature_i16 = 4,
    video_feature_u8 = 5,
    latent_tensor = 6,
    typed_record = 7,
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
};

pub const NumericalPolicyV1 = enum(u64) {
    exact_integer = 1,
    strict_float32 = 2,
    bounded_float32 = 3,
    implementation_defined = 4,
};

pub const UnsupportedReasonV1 = enum(u64) {
    family = 1,
    operation = 2,
    input_kind = 3,
    output_kind = 4,
    numerical_policy = 5,
    dimensions = 6,
    capabilities = 7,
};

pub const Error = error{
    BufferTooSmall,
    InvalidArtifactManifest,
    InvalidExecutionPlan,
    InvalidResultEnvelope,
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
    if (artifact_abi == 0 or max_batch_items == 0 or
        input_features == 0 or output_dimensions == 0 or
        input_element_bytes == 0 or output_element_bytes == 0 or
        weight_element_bytes == 0 or weights.len == 0 or
        isZero(metadata_sha256) or
        isZero(license_sha256))
        return Error.InvalidArtifactManifest;
    if (weights.len % weight_element_bytes != 0)
        return Error.InvalidArtifactManifest;
    const weight_elements: u64 =
        @intCast(weights.len / weight_element_bytes);
    const weight_bytes: u64 = @intCast(weights.len);
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
        .weights_sha256 = sha256(weights),
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
    try validateResultEnvelopeV1(result);
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
    const plan = try makeExecutionPlanV1(manifest, .encode, .{
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
    });
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
