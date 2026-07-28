//! Exact Q30 L2-normalized dense-tensor embeddings over the stateless
//! publication lifecycle.
//!
//! The retained backend is a download-free signed-integer fixture. It proves
//! canonical normalization, typed batch identity, resource ownership, and
//! atomic result publication; it does not claim production embedding quality.

const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const qos = @import("lane_weave_qos.zig");
const stateless = @import("stateless_model_adapter.zig");
const tensor_result = @import("stateless_tensor_result.zig");
const embedding_result = @import("stateless_embedding_result.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 = 0x4744_454d_0000_0001;
pub const embedding_support = [_]model.SupportRecordV1{.{
    .family = .stateless_encoder,
    .operation = .encode,
    .input_kind = .dense_tensor,
    .output_kind = .embedding_i32,
    .numerical_policy = .exact_integer,
    .max_batch_items = 64,
    .max_input_features = 4_096,
    .max_output_dimensions = 256,
    .allowed_capabilities = model.no_capabilities,
}};

const source_mapping_domain =
    "glacier-dense-tensor-embedding-source-mapping-v1\x00";
const input_bundle_domain =
    "glacier-dense-tensor-embedding-input-bundle-v1\x00";

pub const Error = stateless.Error || tensor_result.Error ||
    embedding_result.Error || error{
    InvalidEmbeddingBinding,
    EmbeddingResultMismatch,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const ArmedScheduledResultV1 = stateless.ArmedScheduledResultV1;
pub const Phase = stateless.Phase;

/// Typed meaning for the legacy identity slots retained by ExecutionPlanV1.
///
/// input object -> media object, batch map -> processor state, embedding
/// policy -> processor bundle, input bundle -> cache bundle, and tensor ->
/// cache payload.
pub const EmbeddingInputBindingV1 = struct {
    input_object_sha256: Digest,
    batch_map_sha256: Digest,
    embedding_policy_sha256: Digest,
    input_bundle_sha256: Digest,
    tensor_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
};

pub const ReferenceContextV1 = struct {
    batch_map_encoded: []const u8,
    embedding_policy_encoded: []const u8,
};

pub const Session = struct {
    inner: stateless.Session = .{},

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        publication_state: *model.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
    ) Error!void {
        try validateEmbeddingAdapterV1(adapter, manifest, plan);
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &embedding_support,
        );
    }

    pub fn initScheduledV1(
        self: *Session,
        scheduler: *qos.Scheduler,
        admission: qos.Admission,
        publication_state: *model.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
    ) Error!void {
        try validateEmbeddingAdapterV1(adapter, manifest, plan);
        try self.inner.initScheduledV1(
            scheduler,
            admission,
            publication_state,
            manifest,
            plan,
            adapter,
            &embedding_support,
        );
    }

    /// Prepare one normalized embedding matrix, then independently recompute
    /// every component from the caller-supplied weights and tensor. A
    /// semantic mismatch aborts the publication permit before returning.
    pub fn prepareV1(
        self: *Session,
        binding: EmbeddingInputBindingV1,
        batch_map: tensor_result.BatchMapViewV1,
        embedding_policy: embedding_result.EmbeddingPolicyViewV1,
        projection_weights: []const u8,
        dense_tensor: []const u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateEmbeddingBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            binding,
            batch_map,
            embedding_policy,
            dense_tensor,
        );
        const output_bytes = std.math.cast(
            usize,
            self.inner.plan.output_bytes,
        ) orelse return Error.InvalidEmbeddingBinding;
        if (candidate.len < output_bytes or
            visible_output.len < output_bytes)
            return Error.BufferTooSmall;
        const candidate_output = candidate[0..output_bytes];
        const visible_output_slice = visible_output[0..output_bytes];
        if (slicesOverlap(candidate_output, batch_map.encoded) or
            slicesOverlap(
                candidate_output,
                embedding_policy.encoded,
            ) or
            slicesOverlap(visible_output_slice, batch_map.encoded) or
            slicesOverlap(
                visible_output_slice,
                embedding_policy.encoded,
            ))
            return Error.InvalidEmbeddingBinding;
        const source_mapping_sha256 =
            try sourceMappingRootV1(self.inner.plan, binding);
        const prepared = try self.inner.prepareV1(
            projection_weights,
            dense_tensor,
            source_mapping_sha256,
            candidate,
            visible_output,
        );
        validateEmbeddingCandidateV1(
            self.inner.plan,
            batch_map,
            embedding_policy,
            projection_weights,
            dense_tensor,
            candidate_output,
        ) catch {
            self.inner.abortV1() catch |err| return err;
            return Error.EmbeddingResultMismatch;
        };
        return prepared;
    }

    pub fn commitV1(self: *Session) Error!model.ResultEnvelopeV1 {
        return self.inner.commitV1();
    }

    pub fn armServiceV1(
        self: *Session,
        intent: qos.ServiceIntentV1,
    ) Error!ArmedScheduledResultV1 {
        return self.inner.armServiceV1(intent);
    }

    pub fn abortV1(self: *Session) Error!void {
        return self.inner.abortV1();
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        return self.inner.closeAndRelease();
    }

    pub fn cancelScheduledV1(self: *Session) Error!qos.EventV1 {
        return self.inner.cancelScheduledV1();
    }

    pub fn retireScheduledV1(self: *Session) Error!qos.EventV1 {
        return self.inner.retireScheduledV1();
    }
};

pub fn makeAdapterDescriptorV1(
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateEmbeddingManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .encode,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn referenceAdapterV1(
    manifest: model.ArtifactManifestV1,
    context: *ReferenceContextV1,
) Error!AdapterV1 {
    return .{
        .context = context,
        .descriptor = try makeAdapterDescriptorV1(
            manifest,
            model.sha256(
                "reference exact q30 dense tensor embedding v1",
            ),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateReferenceCandidateV1,
    };
}

pub fn validateEmbeddingAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateEmbeddingPlanV1(manifest, plan);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &embedding_support,
    );
}

pub fn validateEmbeddingManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    model.validateArtifactManifestV1(manifest) catch
        return Error.InvalidEmbeddingBinding;
    var canonical_wire: [model.artifact_manifest_bytes]u8 = undefined;
    model.encodeArtifactManifestV1(
        manifest,
        &canonical_wire,
    ) catch return Error.InvalidEmbeddingBinding;
    if (!std.mem.eql(
        u8,
        &manifest.artifact_sha256,
        canonical_wire[canonical_wire.len - @sizeOf(Digest) ..],
    ))
        return Error.InvalidEmbeddingBinding;
    const expected_weight_elements = std.math.mul(
        u64,
        manifest.input_features,
        manifest.output_dimensions,
    ) catch return Error.InvalidEmbeddingBinding;
    if (manifest.family != .stateless_encoder or
        manifest.input_kind != .dense_tensor or
        manifest.output_kind != .embedding_i32 or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items == 0 or
        manifest.max_batch_items >
            embedding_support[0].max_batch_items or
        manifest.input_features == 0 or
        manifest.input_features >
            embedding_support[0].max_input_features or
        manifest.output_dimensions == 0 or
        manifest.output_dimensions >
            embedding_support[0].max_output_dimensions or
        manifest.input_element_bytes != @sizeOf(i16) or
        manifest.output_element_bytes != @sizeOf(i32) or
        manifest.weight_element_bytes != @sizeOf(i8) or
        manifest.weight_elements != expected_weight_elements)
        return Error.InvalidEmbeddingBinding;
}

pub fn validateEmbeddingPlanV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateEmbeddingManifestV1(manifest);
    try validateEmbeddingPlanShapeV1(plan);
    if (plan.batch_items > manifest.max_batch_items or
        plan.family != manifest.family or
        plan.input_kind != manifest.input_kind or
        plan.output_kind != manifest.output_kind or
        plan.numerical_policy != manifest.numerical_policy or
        plan.input_features != manifest.input_features or
        plan.output_dimensions != manifest.output_dimensions or
        plan.input_element_bytes != manifest.input_element_bytes or
        plan.output_element_bytes != manifest.output_element_bytes or
        plan.weight_bytes != manifest.weight_bytes or
        !std.mem.eql(
            u8,
            &plan.artifact_sha256,
            &manifest.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.weights_sha256,
            &manifest.weights_sha256,
        ))
        return Error.InvalidEmbeddingBinding;
}

fn validateEmbeddingPlanShapeV1(
    plan: model.ExecutionPlanV1,
) Error!void {
    model.validateExecutionPlanV1(plan) catch
        return Error.InvalidEmbeddingBinding;
    var canonical_wire: [model.execution_plan_bytes]u8 = undefined;
    model.encodeExecutionPlanV1(
        plan,
        &canonical_wire,
    ) catch return Error.InvalidEmbeddingBinding;
    if (!std.mem.eql(
        u8,
        &plan.plan_sha256,
        canonical_wire[canonical_wire.len - @sizeOf(Digest) ..],
    ))
        return Error.InvalidEmbeddingBinding;
    const expected_weight_bytes = std.math.mul(
        u64,
        plan.input_features,
        plan.output_dimensions,
    ) catch return Error.InvalidEmbeddingBinding;
    if (plan.family != .stateless_encoder or
        plan.operation != .encode or
        plan.input_kind != .dense_tensor or
        plan.output_kind != .embedding_i32 or
        plan.numerical_policy != .exact_integer or
        plan.batch_items == 0 or
        plan.batch_items > embedding_support[0].max_batch_items or
        plan.input_features == 0 or
        plan.input_features >
            embedding_support[0].max_input_features or
        plan.output_dimensions == 0 or
        plan.output_dimensions >
            embedding_support[0].max_output_dimensions or
        plan.input_element_bytes != @sizeOf(i16) or
        plan.output_element_bytes != @sizeOf(i32) or
        plan.weight_bytes != expected_weight_bytes or
        plan.maximum_absolute_output !=
            @as(u64, @intCast(embedding_result.q30_scale)) or
        plan.required_capabilities != model.no_capabilities or
        plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.scratch_bytes or
        plan.claim.output_journal_bytes != plan.output_bytes or
        plan.claim.queue_slots != 1 or
        plan.claim.kv_bytes != 0 or
        plan.claim.logits_bytes != 0 or
        plan.claim.staging_bytes != 0 or
        plan.claim.device_bytes != 0 or
        plan.claim.io_bytes != 0)
        return Error.InvalidEmbeddingBinding;
}

pub fn validateEmbeddingBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    binding: EmbeddingInputBindingV1,
    batch_map: tensor_result.BatchMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    dense_tensor: []const u8,
) Error!void {
    try validateEmbeddingPlanV1(manifest, plan);
    const decoded_map = tensor_result.decodeBatchMapV1(
        batch_map.encoded,
    ) catch return Error.InvalidEmbeddingBinding;
    const decoded_policy =
        embedding_result.decodeEmbeddingPolicyV1(
            embedding_policy.encoded,
        ) catch return Error.InvalidEmbeddingBinding;
    if (decoded_map.item_count != batch_map.item_count or
        !std.mem.eql(
            u8,
            &decoded_map.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            embedding_policy.policy,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            embedding_result.canonical_embedding_policy_v1,
        ) or
        !std.mem.eql(
            u8,
            &decoded_policy.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ) or
        batch_map.item_count != plan.batch_items or
        dense_tensor.len != plan.input_bytes or
        !std.mem.eql(
            u8,
            &model.sha256(dense_tensor),
            &binding.tensor_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.input_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.batch_map_sha256,
            &plan.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.embedding_policy_sha256,
            &plan.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.input_bundle_sha256,
            &plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.tensor_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.ownership_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.challenge_sha256,
            &plan.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.input_bundle_sha256,
            &inputBundleRootV1(
                binding.input_object_sha256,
                binding.batch_map_sha256,
                binding.embedding_policy_sha256,
                binding.tensor_sha256,
                binding.ownership_sha256,
                binding.challenge_sha256,
            ),
        ) or
        !std.mem.eql(
            u8,
            &plan.output_schema_sha256,
            &decoded_policy.embedding_policy_sha256,
        ) or
        bindingHasZeroRoot(binding))
        return Error.InvalidEmbeddingBinding;
}

pub fn sourceMappingRootV1(
    plan: model.ExecutionPlanV1,
    binding: EmbeddingInputBindingV1,
) Error!Digest {
    if (bindingHasZeroRoot(binding) or
        !std.mem.eql(
            u8,
            &binding.input_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.batch_map_sha256,
            &plan.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.embedding_policy_sha256,
            &plan.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.input_bundle_sha256,
            &plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.tensor_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.ownership_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.challenge_sha256,
            &plan.challenge_sha256,
        ))
        return Error.InvalidEmbeddingBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_mapping_domain);
    hash.update(&binding.input_object_sha256);
    hash.update(&binding.batch_map_sha256);
    hash.update(&binding.embedding_policy_sha256);
    hash.update(&binding.input_bundle_sha256);
    hash.update(&binding.tensor_sha256);
    hash.update(&binding.ownership_sha256);
    hash.update(&binding.challenge_sha256);
    hashU64(&hash, plan.request_epoch);
    hashU64(&hash, plan.generation);
    hashU64(&hash, plan.publication_next_sequence);
    hashU64(&hash, plan.batch_items);
    hashU64(&hash, plan.input_features);
    hashU64(&hash, plan.output_dimensions);
    return hash.finalResult();
}

pub fn inputBundleRootV1(
    input_object_sha256: Digest,
    batch_map_sha256: Digest,
    embedding_policy_sha256: Digest,
    tensor_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(input_bundle_domain);
    hash.update(&input_object_sha256);
    hash.update(&batch_map_sha256);
    hash.update(&embedding_policy_sha256);
    hash.update(&tensor_sha256);
    hash.update(&ownership_sha256);
    hash.update(&challenge_sha256);
    return hash.finalResult();
}

pub fn referenceExecuteV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    projection_weights: []const u8,
    dense_tensor: []const u8,
    candidate: []u8,
) anyerror!void {
    const context: *ReferenceContextV1 =
        @ptrCast(@alignCast(opaque_context));
    const batch_map = try tensor_result.decodeBatchMapV1(
        context.batch_map_encoded,
    );
    const policy = try embedding_result.decodeEmbeddingPolicyV1(
        context.embedding_policy_encoded,
    );
    if (!std.meta.eql(
        policy.policy,
        embedding_result.canonical_embedding_policy_v1,
    ))
        return Error.InvalidEmbeddingBinding;
    try validateReferenceShapeAndBuffersV1(
        plan.*,
        batch_map.item_count,
        projection_weights,
        dense_tensor,
        candidate,
    );
    if (slicesOverlap(candidate, projection_weights) or
        slicesOverlap(candidate, dense_tensor) or
        slicesOverlap(candidate, context.batch_map_encoded) or
        slicesOverlap(candidate, context.embedding_policy_encoded))
        return Error.InvalidEmbeddingBinding;
    const item_count: usize = @intCast(plan.batch_items);
    const dimensions: usize = @intCast(plan.output_dimensions);
    const row_bytes = std.math.mul(
        usize,
        dimensions,
        @sizeOf(i32),
    ) catch return Error.InvalidEmbeddingBinding;
    var raw: [embedding_support[0].max_output_dimensions]i64 = undefined;
    var normalized: [embedding_support[0].max_output_dimensions]i32 = undefined;
    // Preflight every row before touching caller storage. The second pass
    // trades bounded extra arithmetic for failure-atomic direct execution
    // while keeping scratch proportional to one output row.
    for (0..item_count) |item_index| {
        try computeRawProjectionRowV1(
            plan,
            projection_weights,
            dense_tensor,
            item_index,
            raw[0..dimensions],
        );
        _ = try embedding_result.normalizeQ30L2V1(
            raw[0..dimensions],
            1,
            dimensions,
            normalized[0..dimensions],
        );
    }
    for (0..item_count) |item_index| {
        try computeRawProjectionRowV1(
            plan,
            projection_weights,
            dense_tensor,
            item_index,
            raw[0..dimensions],
        );
        const components =
            try embedding_result.normalizeQ30L2V1(
                raw[0..dimensions],
                1,
                dimensions,
                normalized[0..dimensions],
            );
        const offset = std.math.mul(
            usize,
            item_index,
            row_bytes,
        ) catch return Error.InvalidEmbeddingBinding;
        const encoded =
            try embedding_result.encodeNormalizedEmbeddingV1(
                components,
                1,
                dimensions,
                candidate[offset .. offset + row_bytes],
            );
        if (encoded.len != row_bytes)
            return Error.InvalidEmbeddingBinding;
    }
}

pub fn validateReferenceCandidateV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    const context: *ReferenceContextV1 =
        @ptrCast(@alignCast(opaque_context));
    const map = try tensor_result.decodeBatchMapV1(
        context.batch_map_encoded,
    );
    const policy = try embedding_result.decodeEmbeddingPolicyV1(
        context.embedding_policy_encoded,
    );
    try validateCandidateMapAndPolicyV1(
        plan.*,
        map,
        policy,
        candidate,
    );
}

pub fn validateEmbeddingCandidateV1(
    plan: model.ExecutionPlanV1,
    batch_map: tensor_result.BatchMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    projection_weights: []const u8,
    dense_tensor: []const u8,
    candidate: []const u8,
) Error!void {
    try validateCandidateMapAndPolicyV1(
        plan,
        batch_map,
        embedding_policy,
        candidate,
    );
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.EmbeddingResultMismatch;
    const dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.EmbeddingResultMismatch;
    const view =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            candidate,
            batch_map.batch_map_sha256,
            embedding_policy.encoded,
            item_count,
            dimensions,
        ) catch return Error.EmbeddingResultMismatch;
    var raw: [embedding_support[0].max_output_dimensions]i64 = undefined;
    var normalized: [embedding_support[0].max_output_dimensions]i32 = undefined;
    for (0..item_count) |item_index| {
        computeRawProjectionRowV1(
            &plan,
            projection_weights,
            dense_tensor,
            item_index,
            raw[0..dimensions],
        ) catch return Error.EmbeddingResultMismatch;
        const expected = embedding_result.normalizeQ30L2V1(
            raw[0..dimensions],
            1,
            dimensions,
            normalized[0..dimensions],
        ) catch return Error.EmbeddingResultMismatch;
        for (0..dimensions) |dimension_index| {
            const actual = view.component(
                item_index,
                dimension_index,
            ) catch return Error.EmbeddingResultMismatch;
            if (actual != expected[dimension_index])
                return Error.EmbeddingResultMismatch;
        }
    }
}

fn validateCandidateMapAndPolicyV1(
    plan: model.ExecutionPlanV1,
    batch_map: tensor_result.BatchMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    candidate: []const u8,
) Error!void {
    validateEmbeddingPlanShapeV1(plan) catch
        return Error.EmbeddingResultMismatch;
    const decoded_map = tensor_result.decodeBatchMapV1(
        batch_map.encoded,
    ) catch return Error.EmbeddingResultMismatch;
    const decoded_policy =
        embedding_result.decodeEmbeddingPolicyV1(
            embedding_policy.encoded,
        ) catch return Error.EmbeddingResultMismatch;
    if (candidate.len != plan.output_bytes or
        decoded_map.item_count != batch_map.item_count or
        !std.mem.eql(
            u8,
            &decoded_map.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            embedding_policy.policy,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            embedding_result.canonical_embedding_policy_v1,
        ) or
        !std.mem.eql(
            u8,
            &decoded_policy.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ) or
        batch_map.item_count != plan.batch_items)
        return Error.EmbeddingResultMismatch;
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.EmbeddingResultMismatch;
    const dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.EmbeddingResultMismatch;
    const view =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            candidate,
            batch_map.batch_map_sha256,
            embedding_policy.encoded,
            item_count,
            dimensions,
        ) catch return Error.EmbeddingResultMismatch;
    if (view.item_count != item_count or
        view.dimensions != dimensions or
        !std.mem.eql(
            u8,
            &view.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &view.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ))
        return Error.EmbeddingResultMismatch;
}

fn validateReferenceShapeAndBuffersV1(
    plan: model.ExecutionPlanV1,
    mapped_item_count: usize,
    projection_weights: []const u8,
    dense_tensor: []const u8,
    candidate: []const u8,
) Error!void {
    validateEmbeddingPlanShapeV1(plan) catch
        return Error.InvalidEmbeddingBinding;
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.InvalidEmbeddingBinding;
    const feature_count = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidEmbeddingBinding;
    const dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidEmbeddingBinding;
    const expected_weights = std.math.mul(
        usize,
        feature_count,
        dimensions,
    ) catch return Error.InvalidEmbeddingBinding;
    const input_elements = std.math.mul(
        usize,
        item_count,
        feature_count,
    ) catch return Error.InvalidEmbeddingBinding;
    const expected_input = std.math.mul(
        usize,
        input_elements,
        @sizeOf(i16),
    ) catch return Error.InvalidEmbeddingBinding;
    const expected_output =
        embedding_result.normalizedEmbeddingEncodedSizeV1(
            item_count,
            dimensions,
        ) catch return Error.InvalidEmbeddingBinding;
    if (mapped_item_count != item_count or
        projection_weights.len != expected_weights or
        projection_weights.len != plan.weight_bytes or
        dense_tensor.len != expected_input or
        dense_tensor.len != plan.input_bytes or
        candidate.len != expected_output or
        candidate.len != plan.output_bytes)
        return Error.InvalidEmbeddingBinding;
}

fn computeRawProjectionRowV1(
    plan: *const model.ExecutionPlanV1,
    projection_weights: []const u8,
    dense_tensor: []const u8,
    item_index: usize,
    raw: []i64,
) Error!void {
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.InvalidEmbeddingBinding;
    const feature_count = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidEmbeddingBinding;
    const dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidEmbeddingBinding;
    const expected_weights = std.math.mul(
        usize,
        dimensions,
        feature_count,
    ) catch return Error.InvalidEmbeddingBinding;
    const input_elements = std.math.mul(
        usize,
        item_count,
        feature_count,
    ) catch return Error.InvalidEmbeddingBinding;
    const expected_input = std.math.mul(
        usize,
        input_elements,
        @sizeOf(i16),
    ) catch return Error.InvalidEmbeddingBinding;
    if (item_index >= item_count or
        raw.len != dimensions or
        projection_weights.len != expected_weights or
        dense_tensor.len != expected_input)
        return Error.InvalidEmbeddingBinding;
    for (0..dimensions) |dimension_index| {
        var accumulator: i64 = 0;
        for (0..feature_count) |feature_index| {
            const tensor_element =
                item_index * feature_count + feature_index;
            const tensor_offset =
                tensor_element * @sizeOf(i16);
            const tensor_value: i64 = std.mem.readInt(
                i16,
                dense_tensor[tensor_offset .. tensor_offset + @sizeOf(i16)][0..@sizeOf(i16)],
                .little,
            );
            const weight_index =
                dimension_index * feature_count + feature_index;
            const weight_value: i64 = @as(
                i8,
                @bitCast(projection_weights[weight_index]),
            );
            const product = std.math.mul(
                i64,
                tensor_value,
                weight_value,
            ) catch return Error.EmbeddingResultMismatch;
            accumulator = std.math.add(
                i64,
                accumulator,
                product,
            ) catch return Error.EmbeddingResultMismatch;
        }
        raw[dimension_index] = accumulator;
    }
}

fn bindingHasZeroRoot(binding: EmbeddingInputBindingV1) bool {
    inline for (std.meta.fields(EmbeddingInputBindingV1)) |field| {
        if (std.mem.allEqual(u8, &@field(binding, field.name), 0))
            return true;
    }
    return false;
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(
        usize,
        a_start,
        a.len,
    ) catch return true;
    const b_end = std.math.add(
        usize,
        b_start,
        b.len,
    ) catch return true;
    return a_start < b_end and b_start < a_end;
}

pub const reference_item_ids = [_]u64{ 8_101, 8_102, 8_103 };
pub const reference_projection_weights = [_]i8{
    2,  0,
    -1, 1,
    0,  3,
};
pub const reference_tensor_values = [_]i16{
    3,  1,
    -2, 4,
    1,  1,
};
pub const reference_raw_values = [_]i64{
    6,  -2, 3,
    -4, 6,  12,
    2,  0,  3,
};
pub const reference_input_features: usize = 2;
pub const reference_output_dimensions: usize = 3;
pub const reference_output_bytes: usize =
    reference_item_ids.len *
    reference_output_dimensions *
    @sizeOf(i32);

/// Small deterministic fixture with three nonzero projected rows. All bytes
/// are generated locally and require no model download.
pub const ReferenceFixtureV1 = struct {
    batch_map_storage: [512]u8,
    batch_map_len: usize,
    embedding_policy_storage: [embedding_result.embedding_policy_bytes]u8,
    embedding_policy_len: usize,
    projection_weights: [reference_projection_weights.len]u8,
    dense_tensor: [
        reference_tensor_values.len * @sizeOf(i16)
    ]u8,
    binding: EmbeddingInputBindingV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,

    pub fn init() !ReferenceFixtureV1 {
        var batch_map_storage: [512]u8 = undefined;
        const batch_map_encoded =
            try tensor_result.encodeBatchMapV1(
                &reference_item_ids,
                &batch_map_storage,
            );
        const batch_map_len = batch_map_encoded.len;
        const batch_map =
            try tensor_result.decodeBatchMapV1(batch_map_encoded);
        var embedding_policy_storage: [embedding_result.embedding_policy_bytes]u8 = undefined;
        const embedding_policy_encoded =
            try embedding_result.encodeEmbeddingPolicyV1(
                embedding_result.canonical_embedding_policy_v1,
                &embedding_policy_storage,
            );
        const embedding_policy_len =
            embedding_policy_encoded.len;
        const embedding_policy =
            try embedding_result.decodeEmbeddingPolicyV1(
                embedding_policy_encoded,
            );
        var projection_weights: [reference_projection_weights.len]u8 = undefined;
        for (
            reference_projection_weights,
            0..,
        ) |value, index|
            projection_weights[index] = @bitCast(value);
        var dense_tensor: [
            reference_tensor_values.len * @sizeOf(i16)
        ]u8 = undefined;
        for (reference_tensor_values, 0..) |value, index| {
            const offset = index * @sizeOf(i16);
            std.mem.writeInt(
                i16,
                dense_tensor[offset .. offset + @sizeOf(i16)][0..@sizeOf(i16)],
                value,
                .little,
            );
        }
        const input_object_sha256 =
            model.sha256("dense embedding input object");
        const ownership_sha256 =
            model.sha256("dense embedding ownership");
        const challenge_sha256 =
            model.sha256("dense embedding challenge");
        const tensor_sha256 = model.sha256(&dense_tensor);
        const input_bundle_sha256 = inputBundleRootV1(
            input_object_sha256,
            batch_map.batch_map_sha256,
            embedding_policy.embedding_policy_sha256,
            tensor_sha256,
            ownership_sha256,
            challenge_sha256,
        );
        const binding: EmbeddingInputBindingV1 = .{
            .input_object_sha256 = input_object_sha256,
            .batch_map_sha256 = batch_map.batch_map_sha256,
            .embedding_policy_sha256 = embedding_policy.embedding_policy_sha256,
            .input_bundle_sha256 = input_bundle_sha256,
            .tensor_sha256 = tensor_sha256,
            .ownership_sha256 = ownership_sha256,
            .challenge_sha256 = challenge_sha256,
        };
        const manifest = try model.makeArtifactManifestV1(
            .stateless_encoder,
            0x4445_4d42_0000_0001,
            .dense_tensor,
            .embedding_i32,
            .exact_integer,
            embedding_support[0].max_batch_items,
            reference_input_features,
            reference_output_dimensions,
            @sizeOf(i16),
            @sizeOf(i32),
            @sizeOf(i8),
            &projection_weights,
            model.sha256("dense embedding fixture metadata"),
            model.sha256("fixture-only generated data license"),
        );
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .encode,
            .{
                .request_epoch = 701,
                .generation = 1,
                .batch_items = reference_item_ids.len,
                .publication_next_sequence = 0,
                .maximum_absolute_output = @intCast(embedding_result.q30_scale),
                .claim = .{
                    .capsule_bytes = projection_weights.len,
                    .activation_bytes = dense_tensor.len,
                    .partial_bytes = reference_output_bytes,
                    .output_journal_bytes = reference_output_bytes,
                    .queue_slots = 1,
                },
                .media_object_sha256 = binding.input_object_sha256,
                .processor_state_sha256 = binding.batch_map_sha256,
                .processor_bundle_sha256 = binding.embedding_policy_sha256,
                .cache_bundle_sha256 = binding.input_bundle_sha256,
                .cache_payload_sha256 = binding.tensor_sha256,
                .ownership_sha256 = binding.ownership_sha256,
                .challenge_sha256 = binding.challenge_sha256,
                .previous_plan_sha256 = model.sha256("dense embedding genesis plan"),
                .input_schema_sha256 = model.sha256(
                    "three rows by two little-endian i16",
                ),
                .output_schema_sha256 = embedding_policy.embedding_policy_sha256,
                .scratch_bytes = reference_output_bytes,
            },
        );
        return .{
            .batch_map_storage = batch_map_storage,
            .batch_map_len = batch_map_len,
            .embedding_policy_storage = embedding_policy_storage,
            .embedding_policy_len = embedding_policy_len,
            .projection_weights = projection_weights,
            .dense_tensor = dense_tensor,
            .binding = binding,
            .manifest = manifest,
            .plan = plan,
            .publication_state = try model.initializePublicationStateV1(
                plan.request_epoch,
                manifest.artifact_sha256,
            ),
        };
    }

    pub fn batchMap(
        self: *const ReferenceFixtureV1,
    ) !tensor_result.BatchMapViewV1 {
        return tensor_result.decodeBatchMapV1(
            self.batch_map_storage[0..self.batch_map_len],
        );
    }

    pub fn embeddingPolicy(
        self: *const ReferenceFixtureV1,
    ) !embedding_result.EmbeddingPolicyViewV1 {
        return embedding_result.decodeEmbeddingPolicyV1(
            self.embedding_policy_storage[0..self.embedding_policy_len],
        );
    }

    pub fn referenceContext(
        self: *const ReferenceFixtureV1,
    ) ReferenceContextV1 {
        return .{
            .batch_map_encoded = self.batch_map_storage[0..self.batch_map_len],
            .embedding_policy_encoded = self.embedding_policy_storage[0..self.embedding_policy_len],
        };
    }
};

const TestRuntime = struct {
    bank_slots: [4]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 4,
    lane_slots: [4]qos.Slot = [_]qos.Slot{.{}} ** 4,
    projection: [4]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** 4,
};

fn expectReferenceEmbedding(
    fixture: *const ReferenceFixtureV1,
    output: []const u8,
) !void {
    const map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    const view =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            output,
            map.batch_map_sha256,
            policy.encoded,
            reference_item_ids.len,
            reference_output_dimensions,
        );
    var expected: [reference_raw_values.len]i32 = undefined;
    _ = try embedding_result.normalizeQ30L2V1(
        &reference_raw_values,
        reference_item_ids.len,
        reference_output_dimensions,
        &expected,
    );
    for (0..reference_item_ids.len) |item_index| {
        for (0..reference_output_dimensions) |dimension_index| {
            try std.testing.expectEqual(
                expected[
                    item_index * reference_output_dimensions +
                        dimension_index
                ],
                try view.component(item_index, dimension_index),
            );
        }
    }
}

fn resealPlanForTest(plan: *model.ExecutionPlanV1) !void {
    var encoded: [model.execution_plan_bytes]u8 = undefined;
    plan.plan_sha256 = [_]u8{0} ** @sizeOf(Digest);
    try model.encodeExecutionPlanV1(plan.*, &encoded);
    plan.plan_sha256 =
        encoded[encoded.len - @sizeOf(Digest) ..].*;
}

fn makeBoundaryManifestForTest(
    maximum_batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
) !model.ArtifactManifestV1 {
    const weight_bytes = try std.math.mul(
        u64,
        input_features,
        output_dimensions,
    );
    return model.makeArtifactManifestFromDigestV1(
        .stateless_encoder,
        0x4445_4d42_4f55_4e44,
        .dense_tensor,
        .embedding_i32,
        .exact_integer,
        maximum_batch_items,
        input_features,
        output_dimensions,
        @sizeOf(i16),
        @sizeOf(i32),
        @sizeOf(i8),
        weight_bytes,
        model.sha256("embedding boundary weights"),
        model.sha256("embedding boundary metadata"),
        model.sha256("embedding boundary license"),
    );
}

test "embedding validators bind exact manifest, dimensions, and plan" {
    const fixture = try ReferenceFixtureV1.init();
    try validateEmbeddingManifestV1(fixture.manifest);
    try validateEmbeddingPlanV1(fixture.manifest, fixture.plan);

    var too_wide = fixture.manifest;
    too_wide.output_dimensions =
        embedding_support[0].max_output_dimensions + 1;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingManifestV1(too_wide),
    );

    var too_many_features = fixture.manifest;
    too_many_features.input_features =
        embedding_support[0].max_input_features + 1;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingManifestV1(too_many_features),
    );

    var wrong_bound = fixture.plan;
    wrong_bound.maximum_absolute_output -= 1;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingPlanV1(fixture.manifest, wrong_bound),
    );

    var foreign_weights = fixture.plan;
    foreign_weights.weights_sha256 =
        model.sha256("foreign embedding weights");
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingPlanV1(
            fixture.manifest,
            foreign_weights,
        ),
    );

    var stale_manifest = fixture.manifest;
    stale_manifest.metadata_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingManifestV1(stale_manifest),
    );

    var stale_plan = fixture.plan;
    stale_plan.previous_plan_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingPlanV1(fixture.manifest, stale_plan),
    );

    var too_many_items = fixture.plan;
    too_many_items.batch_items =
        embedding_support[0].max_batch_items + 1;
    too_many_items.input_bytes =
        too_many_items.batch_items *
        too_many_items.input_features *
        too_many_items.input_element_bytes;
    too_many_items.output_bytes =
        too_many_items.batch_items *
        too_many_items.output_dimensions *
        too_many_items.output_element_bytes;
    too_many_items.scratch_bytes = too_many_items.output_bytes;
    too_many_items.claim.activation_bytes =
        too_many_items.input_bytes;
    too_many_items.claim.partial_bytes =
        too_many_items.scratch_bytes;
    too_many_items.claim.output_journal_bytes =
        too_many_items.output_bytes;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingPlanV1(
            fixture.manifest,
            too_many_items,
        ),
    );

    var forged_ownership = fixture.binding;
    forged_ownership.ownership_sha256 =
        model.sha256("foreign embedding owner");
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingBindingsV1(
            fixture.manifest,
            fixture.plan,
            forged_ownership,
            try fixture.batchMap(),
            try fixture.embeddingPolicy(),
            &fixture.dense_tensor,
        ),
    );

    var substituted_binding = fixture.binding;
    substituted_binding.input_bundle_sha256 =
        model.sha256("coherent but non-derived input bundle");
    var substituted_plan = fixture.plan;
    substituted_plan.cache_bundle_sha256 =
        substituted_binding.input_bundle_sha256;
    try resealPlanForTest(&substituted_plan);
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingBindingsV1(
            fixture.manifest,
            substituted_plan,
            substituted_binding,
            try fixture.batchMap(),
            try fixture.embeddingPolicy(),
            &fixture.dense_tensor,
        ),
    );

    var foreign_schema = fixture.plan;
    foreign_schema.output_schema_sha256 =
        model.sha256("foreign embedding output schema");
    try resealPlanForTest(&foreign_schema);
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingBindingsV1(
            fixture.manifest,
            foreign_schema,
            fixture.binding,
            try fixture.batchMap(),
            try fixture.embeddingPolicy(),
            &fixture.dense_tensor,
        ),
    );
}

test "embedding profile accepts exact maxima and rejects each next value" {
    const maximum_manifest = try makeBoundaryManifestForTest(
        embedding_support[0].max_batch_items,
        embedding_support[0].max_input_features,
        embedding_support[0].max_output_dimensions,
    );
    try validateEmbeddingManifestV1(maximum_manifest);

    var policy_storage: [embedding_result.embedding_policy_bytes]u8 =
        undefined;
    const policy_encoded =
        try embedding_result.encodeEmbeddingPolicyV1(
            embedding_result.canonical_embedding_policy_v1,
            &policy_storage,
        );
    const policy =
        try embedding_result.decodeEmbeddingPolicyV1(
            policy_encoded,
        );
    const input_bytes =
        embedding_support[0].max_batch_items *
        embedding_support[0].max_input_features *
        @sizeOf(i16);
    const output_bytes =
        embedding_support[0].max_batch_items *
        embedding_support[0].max_output_dimensions *
        @sizeOf(i32);
    const maximum_plan = try model.makeExecutionPlanV1(
        maximum_manifest,
        .encode,
        .{
            .request_epoch = 1,
            .generation = 1,
            .batch_items = embedding_support[0].max_batch_items,
            .publication_next_sequence = 0,
            .maximum_absolute_output = @intCast(embedding_result.q30_scale),
            .claim = .{
                .capsule_bytes = maximum_manifest.weight_bytes,
                .activation_bytes = input_bytes,
                .partial_bytes = output_bytes,
                .output_journal_bytes = output_bytes,
                .queue_slots = 1,
            },
            .media_object_sha256 = model.sha256("embedding maximum input"),
            .processor_state_sha256 = model.sha256("embedding maximum batch"),
            .processor_bundle_sha256 = policy.embedding_policy_sha256,
            .cache_bundle_sha256 = model.sha256("embedding maximum bundle"),
            .cache_payload_sha256 = model.sha256("embedding maximum tensor"),
            .ownership_sha256 = model.sha256("embedding maximum ownership"),
            .challenge_sha256 = model.sha256("embedding maximum challenge"),
            .previous_plan_sha256 = model.sha256("embedding maximum predecessor"),
            .input_schema_sha256 = model.sha256("embedding maximum input schema"),
            .output_schema_sha256 = policy.embedding_policy_sha256,
            .scratch_bytes = output_bytes,
        },
    );
    try validateEmbeddingPlanV1(maximum_manifest, maximum_plan);

    const too_many_items = try makeBoundaryManifestForTest(
        embedding_support[0].max_batch_items + 1,
        1,
        1,
    );
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingManifestV1(too_many_items),
    );
    const too_many_features = try makeBoundaryManifestForTest(
        1,
        embedding_support[0].max_input_features + 1,
        1,
    );
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingManifestV1(too_many_features),
    );
    const too_many_dimensions = try makeBoundaryManifestForTest(
        1,
        1,
        embedding_support[0].max_output_dimensions + 1,
    );
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        validateEmbeddingManifestV1(too_many_dimensions),
    );
}

test "reference embedding bytes and matrix identity are deterministic" {
    var fixture = try ReferenceFixtureV1.init();
    const map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    var first: [reference_output_bytes]u8 = undefined;
    var second: [reference_output_bytes]u8 = undefined;
    try referenceExecuteV1(
        &context,
        &fixture.plan,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &first,
    );
    try referenceExecuteV1(
        &context,
        &fixture.plan,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &second,
    );
    try std.testing.expectEqualSlices(u8, &first, &second);
    const first_root =
        try embedding_result.embeddingMatrixSha256V1(
            map.batch_map_sha256,
            policy.embedding_policy_sha256,
            reference_item_ids.len,
            reference_output_dimensions,
            &first,
        );
    const second_root =
        try embedding_result.embeddingMatrixSha256V1(
            map.batch_map_sha256,
            policy.embedding_policy_sha256,
            reference_item_ids.len,
            reference_output_dimensions,
            &second,
        );
    try std.testing.expectEqual(first_root, second_root);
}

test "direct embedding execution is failure atomic and evidence disjoint" {
    var fixture = try ReferenceFixtureV1.init();
    var context = fixture.referenceContext();
    var later_zero_tensor = fixture.dense_tensor;
    const last_row_offset =
        (reference_item_ids.len - 1) *
        reference_input_features *
        @sizeOf(i16);
    @memset(
        later_zero_tensor[last_row_offset .. last_row_offset +
            reference_input_features * @sizeOf(i16)],
        0,
    );
    var candidate = [_]u8{0xa5} ** reference_output_bytes;
    try std.testing.expectError(
        Error.ZeroVector,
        referenceExecuteV1(
            &context,
            &fixture.plan,
            &fixture.projection_weights,
            &later_zero_tensor,
            &candidate,
        ),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0xa5),
    );

    const batch_map_before = fixture.batch_map_storage;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        referenceExecuteV1(
            &context,
            &fixture.plan,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            fixture.batch_map_storage[0..reference_output_bytes],
        ),
    );
    try std.testing.expectEqualDeep(
        batch_map_before,
        fixture.batch_map_storage,
    );
}

test "dense tensor embedding directly publishes canonical matrix" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x6201,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x6202,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output = [_]u8{0xa5} ** reference_output_bytes;
    const prepared = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try expectReferenceEmbedding(&fixture, &candidate);
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try expectReferenceEmbedding(&fixture, &output);
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expectEqual(
        committed.output_sha256,
        model.sha256(&output),
    );
    try std.testing.expectEqual(
        try sourceMappingRootV1(fixture.plan, fixture.binding),
        committed.source_mapping_sha256,
    );
    try session.closeAndRelease();
    const snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(
        @as(usize, 0),
        snapshot.committed_receipts,
    );
}

fn substitutedExecuteV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    try referenceExecuteV1(
        opaque_context,
        plan,
        weights,
        input,
        candidate,
    );
    var replacement = [_]i32{
        embedding_result.q30_scale,
        0,
        0,
    };
    _ = try embedding_result.encodeNormalizedEmbeddingV1(
        &replacement,
        1,
        reference_output_dimensions,
        candidate[0 .. reference_output_dimensions * @sizeOf(i32)],
    );
}

test "coherent candidate substitution aborts and scrubs ownership" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    var adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    adapter.execute_fn = substitutedExecuteV1;
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x6301,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x6302,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output = [_]u8{0xa5} ** reference_output_bytes;
    try std.testing.expectError(
        Error.EmbeddingResultMismatch,
        session.prepareV1(
            fixture.binding,
            batch_map,
            policy,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            &candidate,
            &output,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "embedding output cannot alias map or policy evidence" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x6351,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x6352,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var output: [reference_output_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        session.prepareV1(
            fixture.binding,
            batch_map,
            policy,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            fixture.batch_map_storage[0..reference_output_bytes],
            &output,
        ),
    );
    try std.testing.expectError(
        Error.InvalidEmbeddingBinding,
        session.prepareV1(
            fixture.binding,
            batch_map,
            policy,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            &output,
            fixture.embedding_policy_storage[0..reference_output_bytes],
        ),
    );
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "zero projected row fails without publication and permits retry" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var zero_tensor = fixture.dense_tensor;
    @memset(zero_tensor[0 .. reference_input_features *
        @sizeOf(i16)], 0);
    var zero_binding = fixture.binding;
    zero_binding.tensor_sha256 = model.sha256(&zero_tensor);
    zero_binding.input_bundle_sha256 = inputBundleRootV1(
        zero_binding.input_object_sha256,
        zero_binding.batch_map_sha256,
        zero_binding.embedding_policy_sha256,
        zero_binding.tensor_sha256,
        zero_binding.ownership_sha256,
        zero_binding.challenge_sha256,
    );
    const zero_plan = try model.makeExecutionPlanV1(
        fixture.manifest,
        .encode,
        .{
            .request_epoch = fixture.plan.request_epoch,
            .generation = fixture.plan.generation,
            .batch_items = fixture.plan.batch_items,
            .publication_next_sequence = fixture.plan.publication_next_sequence,
            .maximum_absolute_output = fixture.plan.maximum_absolute_output,
            .required_capabilities = fixture.plan.required_capabilities,
            .claim = fixture.plan.claim,
            .media_object_sha256 = zero_binding.input_object_sha256,
            .processor_state_sha256 = zero_binding.batch_map_sha256,
            .processor_bundle_sha256 = zero_binding.embedding_policy_sha256,
            .cache_bundle_sha256 = zero_binding.input_bundle_sha256,
            .cache_payload_sha256 = zero_binding.tensor_sha256,
            .ownership_sha256 = zero_binding.ownership_sha256,
            .challenge_sha256 = zero_binding.challenge_sha256,
            .previous_plan_sha256 = fixture.plan.previous_plan_sha256,
            .input_schema_sha256 = fixture.plan.input_schema_sha256,
            .output_schema_sha256 = fixture.plan.output_schema_sha256,
            .scratch_bytes = fixture.plan.scratch_bytes,
        },
    );
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x6381,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x6382,
        &fixture.publication_state,
        fixture.manifest,
        zero_plan,
        adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output = [_]u8{0xa5} ** reference_output_bytes;
    try std.testing.expectError(
        Error.BackendFailed,
        session.prepareV1(
            zero_binding,
            batch_map,
            policy,
            &fixture.projection_weights,
            &zero_tensor,
            &candidate,
            &output,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();

    var retry: Session = .{};
    try retry.initV1(
        &bank,
        0x6383,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    _ = try retry.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try retry.abortV1();
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try retry.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "candidate mutation aborts commit and a new session can retry" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x63a1,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x63a2,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output: [reference_output_bytes]u8 = undefined;
    _ = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    candidate[0] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try session.closeAndRelease();

    var retry: Session = .{};
    try retry.initV1(
        &bank,
        0x63a3,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    _ = try retry.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    _ = try retry.commitV1();
    try retry.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "scheduled embedding publishes at final service and retires" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x6401,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &runtime.lane_slots,
            .projection = &runtime.projection,
        },
        .{
            .scheduler_epoch = 0x6402,
            .challenge = model.sha256("scheduled embedding challenge"),
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const decision = try scheduler.admit(.{
        .tenant_key = 0x6403,
        .request_key = 0x6404,
        .request_generation = 1,
        .resource_owner_key = 0x6405,
        .weight = 1,
        .work_quanta = 1,
        .deadline_tick = 8,
        .claim = fixture.plan.claim,
    });
    const admission = switch (decision) {
        .admitted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        admission,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    const permit = try scheduler.prepareService();
    var candidate: [reference_output_bytes]u8 = undefined;
    var output: [reference_output_bytes]u8 = undefined;
    const prepared = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    const armed_service = try scheduler.armServiceCommit(permit);
    var armed_model =
        try session.armServiceV1(armed_service.intent);
    _ = try scheduler.commitArmedServiceV2(
        armed_service.ticket,
        armed_model.finalizer(),
    );
    try std.testing.expectEqual(
        prepared,
        try armed_model.resultV1(),
    );
    try expectReferenceEmbedding(&fixture, &output);
    const retired = try session.retireScheduledV1();
    try std.testing.expectEqual(qos.EventKind.retire, retired.kind);
    _ = try scheduler.close();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "scheduled abort and cancellation leave zero ownership" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.embeddingPolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x6501,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &runtime.lane_slots,
            .projection = &runtime.projection,
        },
        .{
            .scheduler_epoch = 0x6502,
            .challenge = model.sha256("cancel embedding challenge"),
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const decision = try scheduler.admit(.{
        .tenant_key = 0x6503,
        .request_key = 0x6504,
        .request_generation = 1,
        .resource_owner_key = 0x6505,
        .weight = 1,
        .work_quanta = 1,
        .deadline_tick = 8,
        .claim = fixture.plan.claim,
    });
    const admission = switch (decision) {
        .admitted => |value| value,
        .rejected => return error.TestUnexpectedResult,
    };
    var session: Session = .{};
    try session.initScheduledV1(
        &scheduler,
        admission,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output: [reference_output_bytes]u8 = undefined;
    _ = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try session.abortV1();
    const cancelled = try session.cancelScheduledV1();
    try std.testing.expectEqual(
        qos.EventKind.cancel,
        cancelled.kind,
    );
    _ = try scheduler.close();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}
