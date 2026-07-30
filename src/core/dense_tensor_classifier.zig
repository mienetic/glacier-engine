//! Exact dense-tensor classification over the stateless publication lifecycle.
//!
//! The retained backend is a download-free signed-integer fixture. It proves
//! explicit batch and class identity, exact scores, deterministic winner
//! selection, resource ownership, and atomic publication. It does not claim
//! calibrated probabilities or production classification quality.

const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const qos = @import("lane_weave_qos.zig");
const stateless = @import("stateless_model_adapter.zig");
const tensor_result = @import("stateless_tensor_result.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 = 0x4744_434c_0000_0001;
pub const classifier_support = [_]model.SupportRecordV1{.{
    .family = .stateless_encoder,
    .operation = .classify,
    .input_kind = .dense_tensor,
    .output_kind = .class_scores,
    .numerical_policy = .exact_integer,
    .max_batch_items = 64,
    .max_input_features = 4_096,
    .max_output_dimensions = 256,
    .allowed_capabilities = model.no_capabilities,
}};

const maximum_i16_i8_product: u64 = 4_194_304;
const source_mapping_domain =
    "glacier-dense-tensor-classifier-source-mapping-v1\x00";
const input_bundle_domain =
    "glacier-dense-tensor-classifier-input-bundle-v1\x00";

pub const Error = stateless.Error || tensor_result.Error || error{
    InvalidClassificationBinding,
    ClassScoreMismatch,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const ArmedScheduledResultV1 = stateless.ArmedScheduledResultV1;
pub const Phase = stateless.Phase;

/// Typed projection onto the generic ExecutionPlanV1 identity slots.
///
/// The output schema slot carries the exact class map. The processor bundle
/// carries the class-score policy, leaving the frozen plan wire unchanged.
pub const ClassificationInputBindingV1 = struct {
    input_object_sha256: Digest,
    batch_map_sha256: Digest,
    class_map_sha256: Digest,
    class_score_policy_sha256: Digest,
    input_bundle_sha256: Digest,
    tensor_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
};

pub const ReferenceContextV1 = struct {
    batch_map_encoded: []const u8,
    class_map_encoded: []const u8,
    class_score_policy_encoded: []const u8,
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
        try validateClassifierAdapterV1(adapter, manifest, plan);
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &classifier_support,
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
        try validateClassifierAdapterV1(adapter, manifest, plan);
        try self.inner.initScheduledV1(
            scheduler,
            admission,
            publication_state,
            manifest,
            plan,
            adapter,
            &classifier_support,
        );
    }

    /// Prepares one exact class-score matrix and independently recomputes it
    /// before allowing the generic stateless session to remain prepared.
    pub fn prepareV1(
        self: *Session,
        binding: ClassificationInputBindingV1,
        batch_map: tensor_result.BatchMapViewV1,
        class_map: tensor_result.ClassMapViewV1,
        class_score_policy: tensor_result.ClassScorePolicyViewV1,
        projection_weights: []const u8,
        dense_tensor: []const u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized) return Error.InvalidState;
        try validateClassificationBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            binding,
            batch_map,
            class_map,
            class_score_policy,
            dense_tensor,
        );
        const output_bytes = std.math.cast(
            usize,
            self.inner.plan.output_bytes,
        ) orelse return Error.InvalidClassificationBinding;
        if (candidate.len < output_bytes or
            visible_output.len < output_bytes)
            return Error.BufferTooSmall;
        const candidate_output = candidate[0..output_bytes];
        const visible_output_slice = visible_output[0..output_bytes];
        inline for (.{
            batch_map.encoded,
            class_map.encoded,
            class_score_policy.encoded,
        }) |evidence| {
            if (slicesOverlap(candidate_output, evidence) or
                slicesOverlap(visible_output_slice, evidence))
                return Error.InvalidClassificationBinding;
        }
        const source_mapping_sha256 =
            try sourceMappingRootV1(self.inner.plan, binding);
        const prepared = try self.inner.prepareV1(
            projection_weights,
            dense_tensor,
            source_mapping_sha256,
            candidate,
            visible_output,
        );
        validateClassificationCandidateV1(
            self.inner.plan,
            batch_map,
            class_map,
            class_score_policy,
            projection_weights,
            dense_tensor,
            candidate_output,
        ) catch {
            self.inner.abortV1() catch |err| return err;
            return Error.ClassScoreMismatch;
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

pub fn maximumAbsoluteScoreV1(input_features: u64) Error!u64 {
    if (input_features == 0 or
        input_features > classifier_support[0].max_input_features)
        return Error.InvalidClassificationBinding;
    return std.math.mul(
        u64,
        input_features,
        maximum_i16_i8_product,
    ) catch return Error.InvalidClassificationBinding;
}

pub fn makeAdapterDescriptorV1(
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateClassifierManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .classify,
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
                "reference exact i64 dense tensor classifier v1",
            ),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateReferenceCandidateV1,
    };
}

pub fn validateClassifierAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateClassifierPlanV1(manifest, plan);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &classifier_support,
    );
}

pub fn validateClassifierManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    model.validateArtifactManifestV1(manifest) catch
        return Error.InvalidClassificationBinding;
    var canonical_wire: [model.artifact_manifest_bytes]u8 = undefined;
    model.encodeArtifactManifestV1(
        manifest,
        &canonical_wire,
    ) catch return Error.InvalidClassificationBinding;
    if (!std.mem.eql(
        u8,
        &manifest.artifact_sha256,
        canonical_wire[canonical_wire.len - @sizeOf(Digest) ..],
    )) return Error.InvalidClassificationBinding;
    const expected_weight_elements = std.math.mul(
        u64,
        manifest.input_features,
        manifest.output_dimensions,
    ) catch return Error.InvalidClassificationBinding;
    if (manifest.family != .stateless_encoder or
        manifest.input_kind != .dense_tensor or
        manifest.output_kind != .class_scores or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items == 0 or
        manifest.max_batch_items >
            classifier_support[0].max_batch_items or
        manifest.input_features == 0 or
        manifest.input_features >
            classifier_support[0].max_input_features or
        manifest.output_dimensions == 0 or
        manifest.output_dimensions >
            classifier_support[0].max_output_dimensions or
        manifest.input_element_bytes != @sizeOf(i16) or
        manifest.output_element_bytes !=
            tensor_result.class_score_element_bytes or
        manifest.weight_element_bytes != @sizeOf(i8) or
        manifest.weight_elements != expected_weight_elements)
        return Error.InvalidClassificationBinding;
}

pub fn validateClassifierPlanV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateClassifierManifestV1(manifest);
    try validateClassifierPlanShapeV1(plan);
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
        return Error.InvalidClassificationBinding;
}

fn validateClassifierPlanShapeV1(
    plan: model.ExecutionPlanV1,
) Error!void {
    model.validateExecutionPlanV1(plan) catch
        return Error.InvalidClassificationBinding;
    var canonical_wire: [model.execution_plan_bytes]u8 = undefined;
    model.encodeExecutionPlanV1(
        plan,
        &canonical_wire,
    ) catch return Error.InvalidClassificationBinding;
    if (!std.mem.eql(
        u8,
        &plan.plan_sha256,
        canonical_wire[canonical_wire.len - @sizeOf(Digest) ..],
    )) return Error.InvalidClassificationBinding;
    const expected_weight_bytes = std.math.mul(
        u64,
        plan.input_features,
        plan.output_dimensions,
    ) catch return Error.InvalidClassificationBinding;
    const expected_maximum =
        try maximumAbsoluteScoreV1(plan.input_features);
    if (plan.family != .stateless_encoder or
        plan.operation != .classify or
        plan.input_kind != .dense_tensor or
        plan.output_kind != .class_scores or
        plan.numerical_policy != .exact_integer or
        plan.batch_items == 0 or
        plan.batch_items > classifier_support[0].max_batch_items or
        plan.input_features == 0 or
        plan.input_features >
            classifier_support[0].max_input_features or
        plan.output_dimensions == 0 or
        plan.output_dimensions >
            classifier_support[0].max_output_dimensions or
        plan.input_element_bytes != @sizeOf(i16) or
        plan.output_element_bytes !=
            tensor_result.class_score_element_bytes or
        plan.weight_bytes != expected_weight_bytes or
        plan.maximum_absolute_output != expected_maximum or
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
        return Error.InvalidClassificationBinding;
}

pub fn validateClassificationBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    binding: ClassificationInputBindingV1,
    batch_map: tensor_result.BatchMapViewV1,
    class_map: tensor_result.ClassMapViewV1,
    class_score_policy: tensor_result.ClassScorePolicyViewV1,
    dense_tensor: []const u8,
) Error!void {
    try validateClassifierPlanV1(manifest, plan);
    const decoded_batch = tensor_result.decodeBatchMapV1(
        batch_map.encoded,
    ) catch return Error.InvalidClassificationBinding;
    const decoded_classes = tensor_result.decodeClassMapV1(
        class_map.encoded,
    ) catch return Error.InvalidClassificationBinding;
    const decoded_policy = tensor_result.decodeClassScorePolicyV1(
        class_score_policy.encoded,
    ) catch return Error.InvalidClassificationBinding;
    if (decoded_batch.item_count != batch_map.item_count or
        decoded_classes.class_count != class_map.class_count or
        !std.mem.eql(
            u8,
            &decoded_batch.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &decoded_classes.class_map_sha256,
            &class_map.class_map_sha256,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            class_score_policy.policy,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            tensor_result.canonical_class_score_policy_v1,
        ) or
        !std.mem.eql(
            u8,
            &decoded_policy.class_score_policy_sha256,
            &class_score_policy.class_score_policy_sha256,
        ) or
        batch_map.item_count != plan.batch_items or
        class_map.class_count != plan.output_dimensions or
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
            &binding.class_score_policy_sha256,
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
            &binding.class_map_sha256,
            &plan.output_schema_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.class_map_sha256,
            &class_map.class_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.class_score_policy_sha256,
            &class_score_policy.class_score_policy_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.input_bundle_sha256,
            &inputBundleRootV1(
                binding.input_object_sha256,
                binding.batch_map_sha256,
                binding.class_map_sha256,
                binding.class_score_policy_sha256,
                binding.tensor_sha256,
                binding.ownership_sha256,
                binding.challenge_sha256,
            ),
        ) or
        bindingHasZeroRoot(binding))
        return Error.InvalidClassificationBinding;
}

pub fn sourceMappingRootV1(
    plan: model.ExecutionPlanV1,
    binding: ClassificationInputBindingV1,
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
            &binding.class_score_policy_sha256,
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
            &binding.class_map_sha256,
            &plan.output_schema_sha256,
        ))
        return Error.InvalidClassificationBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_mapping_domain);
    hash.update(&binding.input_object_sha256);
    hash.update(&binding.batch_map_sha256);
    hash.update(&binding.class_map_sha256);
    hash.update(&binding.class_score_policy_sha256);
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
    class_map_sha256: Digest,
    class_score_policy_sha256: Digest,
    tensor_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(input_bundle_domain);
    hash.update(&input_object_sha256);
    hash.update(&batch_map_sha256);
    hash.update(&class_map_sha256);
    hash.update(&class_score_policy_sha256);
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
    const class_map = try tensor_result.decodeClassMapV1(
        context.class_map_encoded,
    );
    const policy = try tensor_result.decodeClassScorePolicyV1(
        context.class_score_policy_encoded,
    );
    if (!std.meta.eql(
        policy.policy,
        tensor_result.canonical_class_score_policy_v1,
    )) return Error.InvalidClassificationBinding;
    try validateReferenceShapeAndBuffersV1(
        plan.*,
        batch_map.item_count,
        class_map.class_count,
        projection_weights,
        dense_tensor,
        candidate,
    );
    inline for (.{
        projection_weights,
        dense_tensor,
        context.batch_map_encoded,
        context.class_map_encoded,
        context.class_score_policy_encoded,
    }) |source| {
        if (slicesOverlap(candidate, source))
            return Error.InvalidClassificationBinding;
    }
    const item_count: usize = @intCast(plan.batch_items);
    const class_count: usize = @intCast(plan.output_dimensions);
    for (0..item_count) |item_index| {
        for (0..class_count) |class_index| {
            _ = try dotScoreV1(
                plan,
                projection_weights,
                dense_tensor,
                item_index,
                class_index,
            );
        }
    }
    for (0..item_count) |item_index| {
        for (0..class_count) |class_index| {
            const score_value = try dotScoreV1(
                plan,
                projection_weights,
                dense_tensor,
                item_index,
                class_index,
            );
            const element_index = item_index * class_count + class_index;
            const offset =
                element_index * tensor_result.class_score_element_bytes;
            std.mem.writeInt(
                i64,
                candidate[offset..][0..tensor_result.class_score_element_bytes],
                score_value,
                .little,
            );
        }
    }
}

pub fn validateReferenceCandidateV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    const context: *ReferenceContextV1 =
        @ptrCast(@alignCast(opaque_context));
    const batch_map = try tensor_result.decodeBatchMapV1(
        context.batch_map_encoded,
    );
    const class_map = try tensor_result.decodeClassMapV1(
        context.class_map_encoded,
    );
    const policy = try tensor_result.decodeClassScorePolicyV1(
        context.class_score_policy_encoded,
    );
    try validateCandidateSourcesV1(
        plan.*,
        batch_map,
        class_map,
        policy,
        candidate,
    );
}

pub fn validateClassificationCandidateV1(
    plan: model.ExecutionPlanV1,
    batch_map: tensor_result.BatchMapViewV1,
    class_map: tensor_result.ClassMapViewV1,
    class_score_policy: tensor_result.ClassScorePolicyViewV1,
    projection_weights: []const u8,
    dense_tensor: []const u8,
    candidate: []const u8,
) Error!void {
    validateReferenceShapeAndBuffersV1(
        plan,
        batch_map.item_count,
        class_map.class_count,
        projection_weights,
        dense_tensor,
        candidate,
    ) catch return Error.ClassScoreMismatch;
    try validateCandidateSourcesV1(
        plan,
        batch_map,
        class_map,
        class_score_policy,
        candidate,
    );
    const view = tensor_result.decodeAndVerifyClassScoreMatrixV1(
        candidate,
        batch_map.encoded,
        class_map.encoded,
        class_score_policy.encoded,
    ) catch return Error.ClassScoreMismatch;
    for (0..view.item_count) |item_index| {
        for (0..view.class_count) |class_index| {
            const expected = dotScoreV1(
                &plan,
                projection_weights,
                dense_tensor,
                item_index,
                class_index,
            ) catch return Error.ClassScoreMismatch;
            const actual = view.score(
                item_index,
                class_index,
            ) catch return Error.ClassScoreMismatch;
            if (actual != expected) return Error.ClassScoreMismatch;
        }
    }
}

fn validateCandidateSourcesV1(
    plan: model.ExecutionPlanV1,
    batch_map: tensor_result.BatchMapViewV1,
    class_map: tensor_result.ClassMapViewV1,
    class_score_policy: tensor_result.ClassScorePolicyViewV1,
    candidate: []const u8,
) Error!void {
    validateClassifierPlanShapeV1(plan) catch
        return Error.ClassScoreMismatch;
    const decoded_batch = tensor_result.decodeBatchMapV1(
        batch_map.encoded,
    ) catch return Error.ClassScoreMismatch;
    const decoded_classes = tensor_result.decodeClassMapV1(
        class_map.encoded,
    ) catch return Error.ClassScoreMismatch;
    const decoded_policy = tensor_result.decodeClassScorePolicyV1(
        class_score_policy.encoded,
    ) catch return Error.ClassScoreMismatch;
    if (candidate.len != plan.output_bytes or
        decoded_batch.item_count != batch_map.item_count or
        decoded_classes.class_count != class_map.class_count or
        !std.mem.eql(
            u8,
            &decoded_batch.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &decoded_classes.class_map_sha256,
            &class_map.class_map_sha256,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            class_score_policy.policy,
        ) or
        !std.meta.eql(
            decoded_policy.policy,
            tensor_result.canonical_class_score_policy_v1,
        ) or
        !std.mem.eql(
            u8,
            &decoded_policy.class_score_policy_sha256,
            &class_score_policy.class_score_policy_sha256,
        ) or
        batch_map.item_count != plan.batch_items or
        class_map.class_count != plan.output_dimensions)
        return Error.ClassScoreMismatch;
    const view = tensor_result.decodeAndVerifyClassScoreMatrixV1(
        candidate,
        batch_map.encoded,
        class_map.encoded,
        class_score_policy.encoded,
    ) catch return Error.ClassScoreMismatch;
    if (view.item_count != batch_map.item_count or
        view.class_count != class_map.class_count or
        !std.mem.eql(
            u8,
            &view.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &view.class_map_sha256,
            &class_map.class_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &view.class_score_policy_sha256,
            &class_score_policy.class_score_policy_sha256,
        ))
        return Error.ClassScoreMismatch;
}

fn validateReferenceShapeAndBuffersV1(
    plan: model.ExecutionPlanV1,
    mapped_item_count: usize,
    mapped_class_count: usize,
    projection_weights: []const u8,
    dense_tensor: []const u8,
    candidate: []const u8,
) Error!void {
    validateClassifierPlanShapeV1(plan) catch
        return Error.InvalidClassificationBinding;
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.InvalidClassificationBinding;
    const feature_count = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidClassificationBinding;
    const class_count = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidClassificationBinding;
    const expected_weights = std.math.mul(
        usize,
        feature_count,
        class_count,
    ) catch return Error.InvalidClassificationBinding;
    const input_elements = std.math.mul(
        usize,
        item_count,
        feature_count,
    ) catch return Error.InvalidClassificationBinding;
    const expected_input = std.math.mul(
        usize,
        input_elements,
        @sizeOf(i16),
    ) catch return Error.InvalidClassificationBinding;
    const expected_output =
        tensor_result.classScoreMatrixEncodedSizeV1(
            item_count,
            class_count,
        ) catch return Error.InvalidClassificationBinding;
    if (mapped_item_count != item_count or
        mapped_class_count != class_count or
        projection_weights.len != expected_weights or
        projection_weights.len != plan.weight_bytes or
        dense_tensor.len != expected_input or
        dense_tensor.len != plan.input_bytes or
        candidate.len != expected_output or
        candidate.len != plan.output_bytes)
        return Error.InvalidClassificationBinding;
}

fn dotScoreV1(
    plan: *const model.ExecutionPlanV1,
    projection_weights: []const u8,
    dense_tensor: []const u8,
    item_index: usize,
    class_index: usize,
) Error!i64 {
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.InvalidClassificationBinding;
    const feature_count = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidClassificationBinding;
    const class_count = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidClassificationBinding;
    if (item_index >= item_count or class_index >= class_count)
        return Error.InvalidClassificationBinding;
    var accumulator: i64 = 0;
    for (0..feature_count) |feature_index| {
        const tensor_element =
            item_index * feature_count + feature_index;
        const tensor_offset = tensor_element * @sizeOf(i16);
        const tensor_value: i64 = std.mem.readInt(
            i16,
            dense_tensor[tensor_offset .. tensor_offset + @sizeOf(i16)][0..@sizeOf(i16)],
            .little,
        );
        const weight_index =
            class_index * feature_count + feature_index;
        const weight_value: i64 = @as(
            i8,
            @bitCast(projection_weights[weight_index]),
        );
        const product = std.math.mul(
            i64,
            tensor_value,
            weight_value,
        ) catch return Error.ClassScoreMismatch;
        accumulator = std.math.add(
            i64,
            accumulator,
            product,
        ) catch return Error.ClassScoreMismatch;
    }
    const maximum: i64 = @intCast(plan.maximum_absolute_output);
    if (accumulator > maximum or accumulator < -maximum)
        return Error.ClassScoreMismatch;
    return accumulator;
}

fn bindingHasZeroRoot(binding: ClassificationInputBindingV1) bool {
    inline for (std.meta.fields(ClassificationInputBindingV1)) |field| {
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
    const a_end = std.math.add(usize, a_start, a.len) catch
        return true;
    const b_end = std.math.add(usize, b_start, b.len) catch
        return true;
    return a_start < b_end and b_start < a_end;
}

pub const reference_item_ids = [_]u64{ 501, 502, 503 };
pub const reference_class_ids = [_]u64{ 11, 22, 33, 44 };
pub const reference_projection_weights = [_]i8{
    1, 2,  0,
    0, -1, 2,
    2, 0,  1,
    2, 0,  1,
};
pub const reference_tensor_values = [_]i16{
    2, -1, 3,
    2, 0,  0,
    0, 5,  -3,
};
pub const reference_scores = [_]i64{
    0,  7,   7,  7,
    2,  0,   4,  4,
    10, -11, -3, -3,
};
pub const reference_input_features: usize = 3;
pub const reference_output_dimensions: usize = 4;
pub const reference_output_bytes: usize =
    reference_item_ids.len *
    reference_output_dimensions *
    tensor_result.class_score_element_bytes;

pub const ReferenceFixtureV1 = struct {
    batch_map_storage: [512]u8,
    batch_map_len: usize,
    class_map_storage: [512]u8,
    class_map_len: usize,
    class_score_policy_storage: [
        tensor_result.class_score_policy_bytes
    ]u8,
    class_score_policy_len: usize,
    projection_weights: [reference_projection_weights.len]u8,
    dense_tensor: [
        reference_tensor_values.len * @sizeOf(i16)
    ]u8,
    binding: ClassificationInputBindingV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,

    pub fn init() !ReferenceFixtureV1 {
        var batch_map_storage: [512]u8 = undefined;
        const batch_encoded = try tensor_result.encodeBatchMapV1(
            &reference_item_ids,
            &batch_map_storage,
        );
        const batch_map_len = batch_encoded.len;
        const batch_map = try tensor_result.decodeBatchMapV1(
            batch_encoded,
        );
        var class_map_storage: [512]u8 = undefined;
        const class_encoded = try tensor_result.encodeClassMapV1(
            &reference_class_ids,
            &class_map_storage,
        );
        const class_map_len = class_encoded.len;
        const class_map = try tensor_result.decodeClassMapV1(
            class_encoded,
        );
        var class_score_policy_storage: [
            tensor_result.class_score_policy_bytes
        ]u8 = undefined;
        const policy_encoded =
            try tensor_result.encodeClassScorePolicyV1(
                tensor_result.canonical_class_score_policy_v1,
                &class_score_policy_storage,
            );
        const class_score_policy_len = policy_encoded.len;
        const policy =
            try tensor_result.decodeClassScorePolicyV1(
                policy_encoded,
            );
        var projection_weights: [
            reference_projection_weights.len
        ]u8 = undefined;
        for (reference_projection_weights, 0..) |value, index|
            projection_weights[index] = @bitCast(value);
        var dense_tensor: [
            reference_tensor_values.len * @sizeOf(i16)
        ]u8 = undefined;
        for (reference_tensor_values, 0..) |value, index| {
            const offset = index * @sizeOf(i16);
            std.mem.writeInt(
                i16,
                dense_tensor[offset..][0..@sizeOf(i16)],
                value,
                .little,
            );
        }
        const input_object_sha256 =
            model.sha256("dense classifier input object");
        const ownership_sha256 =
            model.sha256("dense classifier ownership");
        const challenge_sha256 =
            model.sha256("dense classifier challenge");
        const tensor_sha256 = model.sha256(&dense_tensor);
        const input_bundle_sha256 = inputBundleRootV1(
            input_object_sha256,
            batch_map.batch_map_sha256,
            class_map.class_map_sha256,
            policy.class_score_policy_sha256,
            tensor_sha256,
            ownership_sha256,
            challenge_sha256,
        );
        const binding: ClassificationInputBindingV1 = .{
            .input_object_sha256 = input_object_sha256,
            .batch_map_sha256 = batch_map.batch_map_sha256,
            .class_map_sha256 = class_map.class_map_sha256,
            .class_score_policy_sha256 = policy.class_score_policy_sha256,
            .input_bundle_sha256 = input_bundle_sha256,
            .tensor_sha256 = tensor_sha256,
            .ownership_sha256 = ownership_sha256,
            .challenge_sha256 = challenge_sha256,
        };
        const manifest = try model.makeArtifactManifestV1(
            .stateless_encoder,
            0x4443_4c53_0000_0001,
            .dense_tensor,
            .class_scores,
            .exact_integer,
            classifier_support[0].max_batch_items,
            reference_input_features,
            reference_output_dimensions,
            @sizeOf(i16),
            tensor_result.class_score_element_bytes,
            @sizeOf(i8),
            &projection_weights,
            model.sha256("dense classifier fixture metadata"),
            model.sha256("fixture-only generated data license"),
        );
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .classify,
            .{
                .request_epoch = 801,
                .generation = 1,
                .batch_items = reference_item_ids.len,
                .publication_next_sequence = 0,
                .maximum_absolute_output = try maximumAbsoluteScoreV1(
                    reference_input_features,
                ),
                .claim = .{
                    .capsule_bytes = projection_weights.len,
                    .activation_bytes = dense_tensor.len,
                    .partial_bytes = reference_output_bytes,
                    .output_journal_bytes = reference_output_bytes,
                    .queue_slots = 1,
                },
                .media_object_sha256 = binding.input_object_sha256,
                .processor_state_sha256 = binding.batch_map_sha256,
                .processor_bundle_sha256 = binding.class_score_policy_sha256,
                .cache_bundle_sha256 = binding.input_bundle_sha256,
                .cache_payload_sha256 = binding.tensor_sha256,
                .ownership_sha256 = binding.ownership_sha256,
                .challenge_sha256 = binding.challenge_sha256,
                .previous_plan_sha256 = model.sha256("dense classifier genesis plan"),
                .input_schema_sha256 = model.sha256(
                    "three rows by three little-endian i16",
                ),
                .output_schema_sha256 = binding.class_map_sha256,
                .scratch_bytes = reference_output_bytes,
            },
        );
        return .{
            .batch_map_storage = batch_map_storage,
            .batch_map_len = batch_map_len,
            .class_map_storage = class_map_storage,
            .class_map_len = class_map_len,
            .class_score_policy_storage = class_score_policy_storage,
            .class_score_policy_len = class_score_policy_len,
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

    pub fn classMap(
        self: *const ReferenceFixtureV1,
    ) !tensor_result.ClassMapViewV1 {
        return tensor_result.decodeClassMapV1(
            self.class_map_storage[0..self.class_map_len],
        );
    }

    pub fn classScorePolicy(
        self: *const ReferenceFixtureV1,
    ) !tensor_result.ClassScorePolicyViewV1 {
        return tensor_result.decodeClassScorePolicyV1(
            self.class_score_policy_storage[0..self.class_score_policy_len],
        );
    }

    pub fn referenceContext(
        self: *const ReferenceFixtureV1,
    ) ReferenceContextV1 {
        return .{
            .batch_map_encoded = self.batch_map_storage[0..self.batch_map_len],
            .class_map_encoded = self.class_map_storage[0..self.class_map_len],
            .class_score_policy_encoded = self.class_score_policy_storage[0..self.class_score_policy_len],
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

fn expectReferenceScores(
    fixture: *const ReferenceFixtureV1,
    output: []const u8,
) !void {
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    const view = try tensor_result.decodeAndVerifyClassScoreMatrixV1(
        output,
        batch_map.encoded,
        class_map.encoded,
        policy.encoded,
    );
    for (0..view.item_count) |item_index| {
        for (0..view.class_count) |class_index| {
            try std.testing.expectEqual(
                reference_scores[
                    item_index * view.class_count + class_index
                ],
                try view.score(item_index, class_index),
            );
        }
    }
    try std.testing.expectEqualDeep(
        tensor_result.ClassWinnerV1{
            .class_id = 22,
            .class_ordinal = 1,
            .score = 7,
        },
        try view.winner(class_map, 0),
    );
    try std.testing.expectEqualDeep(
        tensor_result.ClassWinnerV1{
            .class_id = 33,
            .class_ordinal = 2,
            .score = 4,
        },
        try view.winner(class_map, 1),
    );
    try std.testing.expectEqualDeep(
        tensor_result.ClassWinnerV1{
            .class_id = 11,
            .class_ordinal = 0,
            .score = 10,
        },
        try view.winner(class_map, 2),
    );
}

fn resealPlanForTest(plan: *model.ExecutionPlanV1) !void {
    var encoded: [model.execution_plan_bytes]u8 = undefined;
    plan.plan_sha256 = [_]u8{0} ** @sizeOf(Digest);
    try model.encodeExecutionPlanV1(plan.*, &encoded);
    plan.plan_sha256 =
        encoded[encoded.len - @sizeOf(Digest) ..].*;
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
    const first = std.mem.readInt(
        i64,
        candidate[0..tensor_result.class_score_element_bytes],
        .little,
    );
    std.mem.writeInt(
        i64,
        candidate[0..tensor_result.class_score_element_bytes],
        first + 1,
        .little,
    );
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
        0x4443_4c53_424f_554e,
        .dense_tensor,
        .class_scores,
        .exact_integer,
        maximum_batch_items,
        input_features,
        output_dimensions,
        @sizeOf(i16),
        tensor_result.class_score_element_bytes,
        @sizeOf(i8),
        weight_bytes,
        model.sha256("classifier boundary weights"),
        model.sha256("classifier boundary metadata"),
        model.sha256("classifier boundary license"),
    );
}

test "classifier validators bind exact profile plan and class schema" {
    const fixture = try ReferenceFixtureV1.init();
    try validateClassifierManifestV1(fixture.manifest);
    try validateClassifierPlanV1(fixture.manifest, fixture.plan);
    const descriptor = try makeAdapterDescriptorV1(
        fixture.manifest,
        model.sha256("classifier implementation"),
    );
    try std.testing.expectEqual(reference_adapter_abi, descriptor.adapter_abi);
    try std.testing.expectEqual(
        model.OperationIdV1.classify,
        descriptor.operation,
    );
    try std.testing.expectEqual(
        @as(u64, 17_179_869_184),
        try maximumAbsoluteScoreV1(
            classifier_support[0].max_input_features,
        ),
    );
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        maximumAbsoluteScoreV1(0),
    );
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        maximumAbsoluteScoreV1(
            classifier_support[0].max_input_features + 1,
        ),
    );

    const maximum_manifest = try makeBoundaryManifestForTest(
        classifier_support[0].max_batch_items,
        classifier_support[0].max_input_features,
        classifier_support[0].max_output_dimensions,
    );
    try validateClassifierManifestV1(maximum_manifest);
    const too_many_items = try makeBoundaryManifestForTest(
        classifier_support[0].max_batch_items + 1,
        1,
        1,
    );
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassifierManifestV1(too_many_items),
    );
    const too_many_features = try makeBoundaryManifestForTest(
        1,
        classifier_support[0].max_input_features + 1,
        1,
    );
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassifierManifestV1(too_many_features),
    );
    const too_many_classes = try makeBoundaryManifestForTest(
        1,
        1,
        classifier_support[0].max_output_dimensions + 1,
    );
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassifierManifestV1(too_many_classes),
    );

    var wrong_bound = fixture.plan;
    wrong_bound.maximum_absolute_output -= 1;
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassifierPlanV1(fixture.manifest, wrong_bound),
    );
    var stale_plan = fixture.plan;
    stale_plan.previous_plan_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassifierPlanV1(fixture.manifest, stale_plan),
    );
    var foreign_class_schema = fixture.plan;
    foreign_class_schema.output_schema_sha256 =
        model.sha256("foreign class schema");
    try resealPlanForTest(&foreign_class_schema);
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassificationBindingsV1(
            fixture.manifest,
            foreign_class_schema,
            fixture.binding,
            try fixture.batchMap(),
            try fixture.classMap(),
            try fixture.classScorePolicy(),
            &fixture.dense_tensor,
        ),
    );
    var foreign_class_binding = fixture.binding;
    foreign_class_binding.class_map_sha256 =
        model.sha256("foreign class map");
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassificationBindingsV1(
            fixture.manifest,
            fixture.plan,
            foreign_class_binding,
            try fixture.batchMap(),
            try fixture.classMap(),
            try fixture.classScorePolicy(),
            &fixture.dense_tensor,
        ),
    );
    var substituted_bundle = fixture.binding;
    substituted_bundle.input_bundle_sha256 =
        model.sha256("non-derived classifier bundle");
    var substituted_plan = fixture.plan;
    substituted_plan.cache_bundle_sha256 =
        substituted_bundle.input_bundle_sha256;
    try resealPlanForTest(&substituted_plan);
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        validateClassificationBindingsV1(
            fixture.manifest,
            substituted_plan,
            substituted_bundle,
            try fixture.batchMap(),
            try fixture.classMap(),
            try fixture.classScorePolicy(),
            &fixture.dense_tensor,
        ),
    );
}

test "reference classifier scores and winners are deterministic" {
    var fixture = try ReferenceFixtureV1.init();
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
    try expectReferenceScores(&fixture, &first);
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    const first_view =
        try tensor_result.decodeAndVerifyClassScoreMatrixV1(
            &first,
            batch_map.encoded,
            class_map.encoded,
            policy.encoded,
        );
    const second_view =
        try tensor_result.decodeAndVerifyClassScoreMatrixV1(
            &second,
            batch_map.encoded,
            class_map.encoded,
            policy.encoded,
        );
    try std.testing.expectEqual(
        first_view.class_score_matrix_sha256,
        second_view.class_score_matrix_sha256,
    );

    var invalid_plan = fixture.plan;
    invalid_plan.maximum_absolute_output -= 1;
    var untouched = [_]u8{0xa5} ** reference_output_bytes;
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        referenceExecuteV1(
            &context,
            &invalid_plan,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            &untouched,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &untouched, 0xa5));
}

test "candidate validation rejects buffer shape drift before scoring" {
    var fixture = try ReferenceFixtureV1.init();
    var context = fixture.referenceContext();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    var candidate: [reference_output_bytes]u8 = undefined;
    try referenceExecuteV1(
        &context,
        &fixture.plan,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
    );
    const canonical_candidate = candidate;

    var long_weights: [reference_projection_weights.len + 1]u8 = undefined;
    @memcpy(
        long_weights[0..reference_projection_weights.len],
        &fixture.projection_weights,
    );
    long_weights[reference_projection_weights.len] = 0;
    var long_tensor: [
        reference_tensor_values.len * @sizeOf(i16) + 1
    ]u8 = undefined;
    @memcpy(
        long_tensor[0 .. reference_tensor_values.len * @sizeOf(i16)],
        &fixture.dense_tensor,
    );
    long_tensor[reference_tensor_values.len * @sizeOf(i16)] = 0;

    const invalid_inputs = [_]struct {
        weights: []const u8,
        tensor: []const u8,
    }{
        .{
            .weights = fixture.projection_weights[0 .. fixture.projection_weights.len - 1],
            .tensor = &fixture.dense_tensor,
        },
        .{
            .weights = &long_weights,
            .tensor = &fixture.dense_tensor,
        },
        .{
            .weights = &fixture.projection_weights,
            .tensor = fixture.dense_tensor[0 .. fixture.dense_tensor.len - 1],
        },
        .{
            .weights = &fixture.projection_weights,
            .tensor = &long_tensor,
        },
    };
    for (invalid_inputs) |invalid| {
        try std.testing.expectError(
            Error.ClassScoreMismatch,
            validateClassificationCandidateV1(
                fixture.plan,
                batch_map,
                class_map,
                policy,
                invalid.weights,
                invalid.tensor,
                &candidate,
            ),
        );
        try std.testing.expectEqualSlices(
            u8,
            &canonical_candidate,
            &candidate,
        );
    }
}

test "reference execution rejects buffer shape drift atomically" {
    var fixture = try ReferenceFixtureV1.init();
    var context = fixture.referenceContext();
    var long_weights: [reference_projection_weights.len + 1]u8 = undefined;
    @memcpy(
        long_weights[0..reference_projection_weights.len],
        &fixture.projection_weights,
    );
    long_weights[reference_projection_weights.len] = 0;
    var long_tensor: [
        reference_tensor_values.len * @sizeOf(i16) + 1
    ]u8 = undefined;
    @memcpy(
        long_tensor[0 .. reference_tensor_values.len * @sizeOf(i16)],
        &fixture.dense_tensor,
    );
    long_tensor[reference_tensor_values.len * @sizeOf(i16)] = 0;

    const invalid_inputs = [_]struct {
        weights: []const u8,
        tensor: []const u8,
    }{
        .{
            .weights = fixture.projection_weights[0 .. fixture.projection_weights.len - 1],
            .tensor = &fixture.dense_tensor,
        },
        .{
            .weights = &long_weights,
            .tensor = &fixture.dense_tensor,
        },
        .{
            .weights = &fixture.projection_weights,
            .tensor = fixture.dense_tensor[0 .. fixture.dense_tensor.len - 1],
        },
        .{
            .weights = &fixture.projection_weights,
            .tensor = &long_tensor,
        },
    };
    for (invalid_inputs) |invalid| {
        var untouched = [_]u8{0xa5} ** reference_output_bytes;
        try std.testing.expectError(
            Error.InvalidClassificationBinding,
            referenceExecuteV1(
                &context,
                &fixture.plan,
                invalid.weights,
                invalid.tensor,
                &untouched,
            ),
        );
        try std.testing.expect(std.mem.allEqual(u8, &untouched, 0xa5));
    }
}

test "dense tensor classifier directly publishes canonical scores" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x7201,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x7202,
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
        class_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try expectReferenceScores(&fixture, &candidate);
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try expectReferenceScores(&fixture, &output);
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

test "coherent class-score substitution aborts and scrubs ownership" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
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
        0x7301,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x7302,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output = [_]u8{0xa5} ** reference_output_bytes;
    try std.testing.expectError(
        Error.ClassScoreMismatch,
        session.prepareV1(
            fixture.binding,
            batch_map,
            class_map,
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

test "class score output cannot alias any mapping or policy evidence" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x7351,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x7352,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var output: [reference_output_bytes]u8 = undefined;
    var candidate: [reference_output_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        session.prepareV1(
            fixture.binding,
            batch_map,
            class_map,
            policy,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            fixture.batch_map_storage[0..reference_output_bytes],
            &output,
        ),
    );
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        session.prepareV1(
            fixture.binding,
            batch_map,
            class_map,
            policy,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            fixture.class_map_storage[0..reference_output_bytes],
            &output,
        ),
    );
    try std.testing.expectError(
        Error.InvalidClassificationBinding,
        session.prepareV1(
            fixture.binding,
            batch_map,
            class_map,
            policy,
            &fixture.projection_weights,
            &fixture.dense_tensor,
            &candidate,
            fixture.class_score_policy_storage[0..reference_output_bytes],
        ),
    );
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "candidate drift aborts classifier commit and permits retry" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x73a1,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output: [reference_output_bytes]u8 = undefined;
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x73a2,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    _ = try session.prepareV1(
        fixture.binding,
        batch_map,
        class_map,
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
        0x73a3,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    _ = try retry.prepareV1(
        fixture.binding,
        batch_map,
        class_map,
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

test "scheduled classifier publishes only at final service and retires" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x7401,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &runtime.lane_slots,
            .projection = &runtime.projection,
        },
        .{
            .scheduler_epoch = 0x7402,
            .challenge = model.sha256(
                "scheduled classifier challenge",
            ),
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const decision = try scheduler.admit(.{
        .tenant_key = 0x7403,
        .request_key = 0x7404,
        .request_generation = 1,
        .resource_owner_key = 0x7405,
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
        class_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
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
    try expectReferenceScores(&fixture, &output);
    const retired = try session.retireScheduledV1();
    try std.testing.expectEqual(qos.EventKind.retire, retired.kind);
    _ = try scheduler.close();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "scheduled classifier abort and cancellation leave zero ownership" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const class_map = try fixture.classMap();
    const policy = try fixture.classScorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x7501,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &runtime.lane_slots,
            .projection = &runtime.projection,
        },
        .{
            .scheduler_epoch = 0x7502,
            .challenge = model.sha256(
                "cancel classifier challenge",
            ),
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const decision = try scheduler.admit(.{
        .tenant_key = 0x7503,
        .request_key = 0x7504,
        .request_generation = 1,
        .resource_owner_key = 0x7505,
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
        class_map,
        policy,
        &fixture.projection_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try session.abortV1();
    const cancelled = try session.cancelScheduledV1();
    try std.testing.expectEqual(qos.EventKind.cancel, cancelled.kind);
    _ = try scheduler.close();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}
