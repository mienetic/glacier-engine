//! Exact dense-tensor reranking over the stateless publication lifecycle.
//!
//! The retained backend is a download-free signed-integer fixture. It proves
//! typed batch identity, deterministic ordering, resource ownership, and
//! atomic result publication; it does not claim production retrieval quality.

const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const qos = @import("lane_weave_qos.zig");
const stateless = @import("stateless_model_adapter.zig");
const tensor_result = @import("stateless_tensor_result.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 = 0x4744_5252_0000_0001;
pub const reranker_support = [_]model.SupportRecordV1{.{
    .family = .stateless_encoder,
    .operation = .rerank,
    .input_kind = .dense_tensor,
    .output_kind = .ranked_items,
    .numerical_policy = .exact_integer,
    .max_batch_items = 64,
    .max_input_features = 4_096,
    .max_output_dimensions = 1,
    .allowed_capabilities = model.no_capabilities,
}};

const source_mapping_domain =
    "glacier-dense-tensor-reranker-source-mapping-v1\x00";
const input_bundle_domain =
    "glacier-dense-tensor-reranker-input-bundle-v1\x00";

pub const Error = stateless.Error || tensor_result.Error || error{
    InvalidTensorBinding,
    RankedResultMismatch,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const ArmedScheduledResultV1 = stateless.ArmedScheduledResultV1;
pub const Phase = stateless.Phase;

/// Typed meaning for the legacy identity slots retained by ExecutionPlanV1.
///
/// This is intentionally non-media. Each field maps one-for-one to the plan:
/// input object -> media object, batch map -> processor state, score policy ->
/// processor bundle, input bundle -> cache bundle, and tensor -> cache payload.
pub const TensorInputBindingV1 = struct {
    input_object_sha256: Digest,
    batch_map_sha256: Digest,
    score_policy_sha256: Digest,
    input_bundle_sha256: Digest,
    tensor_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
};

pub const ReferenceContextV1 = struct {
    batch_map_encoded: []const u8,
    score_policy_encoded: []const u8,
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
        try validateRerankerAdapterV1(adapter, manifest, plan);
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &reranker_support,
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
        try validateRerankerAdapterV1(adapter, manifest, plan);
        try self.inner.initScheduledV1(
            scheduler,
            admission,
            publication_state,
            manifest,
            plan,
            adapter,
            &reranker_support,
        );
    }

    /// Prepare one ranked result, then independently verify the provisional
    /// candidate against the caller-supplied map, policy, weights, and tensor.
    /// Any semantic mismatch aborts the publication permit before returning.
    pub fn prepareV1(
        self: *Session,
        binding: TensorInputBindingV1,
        batch_map: tensor_result.BatchMapViewV1,
        score_policy: tensor_result.ScorePolicyViewV1,
        query_weights: []const u8,
        dense_tensor: []const u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateTensorBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            binding,
            batch_map,
            score_policy,
            dense_tensor,
        );
        const output_bytes = std.math.cast(
            usize,
            self.inner.plan.output_bytes,
        ) orelse return Error.InvalidTensorBinding;
        if (candidate.len < output_bytes or
            visible_output.len < output_bytes)
            return Error.BufferTooSmall;
        const candidate_output = candidate[0..output_bytes];
        const visible_output_slice = visible_output[0..output_bytes];
        if (slicesOverlap(candidate_output, batch_map.encoded) or
            slicesOverlap(candidate_output, score_policy.encoded) or
            slicesOverlap(visible_output_slice, batch_map.encoded) or
            slicesOverlap(visible_output_slice, score_policy.encoded))
            return Error.InvalidTensorBinding;
        const source_mapping_sha256 =
            try sourceMappingRootV1(self.inner.plan, binding);
        const prepared = try self.inner.prepareV1(
            query_weights,
            dense_tensor,
            source_mapping_sha256,
            candidate,
            visible_output,
        );
        validateRankedCandidateV1(
            self.inner.plan,
            batch_map,
            score_policy,
            query_weights,
            dense_tensor,
            candidate_output,
        ) catch {
            self.inner.abortV1() catch |err| return err;
            return Error.RankedResultMismatch;
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
    try validateRerankerManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .rerank,
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
            model.sha256("reference exact dense tensor reranker v1"),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateReferenceCandidateV1,
    };
}

pub fn validateRerankerAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateRerankerPlanV1(manifest, plan);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &reranker_support,
    );
}

pub fn validateRerankerManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    model.validateArtifactManifestV1(manifest) catch
        return Error.InvalidTensorBinding;
    if (manifest.family != .stateless_encoder or
        manifest.input_kind != .dense_tensor or
        manifest.output_kind != .ranked_items or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items == 0 or
        manifest.max_batch_items > reranker_support[0].max_batch_items or
        manifest.input_features == 0 or
        manifest.input_features >
            reranker_support[0].max_input_features or
        manifest.output_dimensions != 1 or
        manifest.input_element_bytes != @sizeOf(i16) or
        manifest.output_element_bytes !=
            tensor_result.ranked_element_bytes or
        manifest.weight_element_bytes != @sizeOf(i8) or
        manifest.weight_elements != manifest.input_features)
        return Error.InvalidTensorBinding;
}

pub fn validateRerankerPlanV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateRerankerManifestV1(manifest);
    try validateRerankerPlanShapeV1(plan);
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
        return Error.InvalidTensorBinding;
}

fn validateRerankerPlanShapeV1(
    plan: model.ExecutionPlanV1,
) Error!void {
    model.validateExecutionPlanV1(plan) catch
        return Error.InvalidTensorBinding;
    if (plan.family != .stateless_encoder or
        plan.operation != .rerank or
        plan.input_kind != .dense_tensor or
        plan.output_kind != .ranked_items or
        plan.numerical_policy != .exact_integer or
        plan.batch_items == 0 or
        plan.batch_items > reranker_support[0].max_batch_items or
        plan.input_features == 0 or
        plan.input_features >
            reranker_support[0].max_input_features or
        plan.output_dimensions != 1 or
        plan.input_element_bytes != @sizeOf(i16) or
        plan.output_element_bytes !=
            tensor_result.ranked_element_bytes or
        plan.weight_bytes != plan.input_features or
        plan.required_capabilities != model.no_capabilities or
        plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.scratch_bytes or
        plan.claim.output_journal_bytes != plan.output_bytes or
        plan.claim.queue_slots != 1 or
        plan.claim.kv_bytes != 0 or plan.claim.logits_bytes != 0 or
        plan.claim.staging_bytes != 0 or
        plan.claim.device_bytes != 0 or plan.claim.io_bytes != 0)
        return Error.InvalidTensorBinding;
}

pub fn validateTensorBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    binding: TensorInputBindingV1,
    batch_map: tensor_result.BatchMapViewV1,
    score_policy: tensor_result.ScorePolicyViewV1,
    dense_tensor: []const u8,
) Error!void {
    try validateRerankerPlanV1(manifest, plan);
    const decoded_map = tensor_result.decodeBatchMapV1(
        batch_map.encoded,
    ) catch return Error.InvalidTensorBinding;
    const decoded_policy = tensor_result.decodeScorePolicyV1(
        score_policy.encoded,
    ) catch return Error.InvalidTensorBinding;
    if (decoded_map.item_count != batch_map.item_count or
        !std.mem.eql(
            u8,
            &decoded_map.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.meta.eql(decoded_policy.policy, score_policy.policy) or
        !std.mem.eql(
            u8,
            &decoded_policy.score_policy_sha256,
            &score_policy.score_policy_sha256,
        ) or
        batch_map.item_count != plan.batch_items or
        score_policy.policy.normalization != .none or
        score_policy.policy.order != .score_descending or
        score_policy.policy.tie_break != .input_ordinal_ascending or
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
            &binding.score_policy_sha256,
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
            &binding.score_policy_sha256,
            &score_policy.score_policy_sha256,
        ) or
        bindingHasZeroRoot(binding))
        return Error.InvalidTensorBinding;
}

pub fn sourceMappingRootV1(
    plan: model.ExecutionPlanV1,
    binding: TensorInputBindingV1,
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
            &binding.score_policy_sha256,
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
        return Error.InvalidTensorBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_mapping_domain);
    hash.update(&binding.input_object_sha256);
    hash.update(&binding.batch_map_sha256);
    hash.update(&binding.score_policy_sha256);
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
    score_policy_sha256: Digest,
    tensor_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(input_bundle_domain);
    hash.update(&input_object_sha256);
    hash.update(&batch_map_sha256);
    hash.update(&score_policy_sha256);
    hash.update(&tensor_sha256);
    hash.update(&ownership_sha256);
    hash.update(&challenge_sha256);
    return hash.finalResult();
}

pub fn referenceExecuteV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    query_weights: []const u8,
    dense_tensor: []const u8,
    candidate: []u8,
) anyerror!void {
    const context: *ReferenceContextV1 =
        @ptrCast(@alignCast(opaque_context));
    const batch_map = try tensor_result.decodeBatchMapV1(
        context.batch_map_encoded,
    );
    const score_policy = try tensor_result.decodeScorePolicyV1(
        context.score_policy_encoded,
    );
    if (batch_map.item_count > reranker_support[0].max_batch_items or
        plan.batch_items > reranker_support[0].max_batch_items or
        plan.input_features == 0 or
        plan.input_features > reranker_support[0].max_input_features or
        plan.output_dimensions != 1 or
        batch_map.item_count != plan.batch_items or
        score_policy.policy.normalization != .none or
        score_policy.policy.order != .score_descending or
        score_policy.policy.tie_break != .input_ordinal_ascending or
        plan.input_element_bytes != @sizeOf(i16) or
        plan.output_element_bytes !=
            tensor_result.ranked_element_bytes)
        return Error.InvalidTensorBinding;
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.InvalidTensorBinding;
    const feature_count = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidTensorBinding;
    const input_elements = std.math.mul(
        usize,
        item_count,
        feature_count,
    ) catch return Error.InvalidTensorBinding;
    const expected_input_bytes = std.math.mul(
        usize,
        input_elements,
        @sizeOf(i16),
    ) catch return Error.InvalidTensorBinding;
    const expected_output_bytes = std.math.mul(
        usize,
        item_count,
        tensor_result.ranked_element_bytes,
    ) catch return Error.InvalidTensorBinding;
    if (query_weights.len != feature_count or
        query_weights.len != plan.weight_bytes or
        dense_tensor.len != expected_input_bytes or
        dense_tensor.len != plan.input_bytes or
        candidate.len != expected_output_bytes or
        candidate.len != plan.output_bytes)
        return Error.InvalidTensorBinding;
    var items: [reranker_support[0].max_batch_items]tensor_result.RankedItemV1 = undefined;
    for (0..item_count) |ordinal| {
        items[ordinal] = .{
            .item_id = try batch_map.itemId(ordinal),
            .input_ordinal = ordinal,
            .rank = 0,
            .score = try dotScoreV1(
                plan,
                query_weights,
                dense_tensor,
                ordinal,
            ),
        };
    }
    insertionSortRankedItems(items[0..item_count]);
    for (items[0..item_count], 0..) |*item, rank|
        item.rank = rank;
    const encoded = try tensor_result.encodeRankedResultV1(
        context.batch_map_encoded,
        context.score_policy_encoded,
        items[0..item_count],
        candidate,
    );
    if (encoded.len != candidate.len)
        return Error.InvalidTensorBinding;
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
    const policy = try tensor_result.decodeScorePolicyV1(
        context.score_policy_encoded,
    );
    try validateCandidateMapAndPolicyV1(
        plan.*,
        map,
        policy,
        candidate,
    );
}

pub fn validateRankedCandidateV1(
    plan: model.ExecutionPlanV1,
    batch_map: tensor_result.BatchMapViewV1,
    score_policy: tensor_result.ScorePolicyViewV1,
    query_weights: []const u8,
    dense_tensor: []const u8,
    candidate: []const u8,
) Error!void {
    try validateCandidateMapAndPolicyV1(
        plan,
        batch_map,
        score_policy,
        candidate,
    );
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.RankedResultMismatch;
    const feature_count = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.RankedResultMismatch;
    const input_elements = std.math.mul(
        usize,
        item_count,
        feature_count,
    ) catch return Error.RankedResultMismatch;
    const expected_input_bytes = std.math.mul(
        usize,
        input_elements,
        @sizeOf(i16),
    ) catch return Error.RankedResultMismatch;
    const plan_input_bytes = std.math.cast(
        usize,
        plan.input_bytes,
    ) orelse return Error.RankedResultMismatch;
    if (query_weights.len != feature_count or
        dense_tensor.len != expected_input_bytes or
        dense_tensor.len != plan_input_bytes)
        return Error.RankedResultMismatch;
    const view = tensor_result.decodeAndVerifyRankedResultV1(
        candidate,
        batch_map.encoded,
        score_policy.encoded,
    ) catch return Error.RankedResultMismatch;
    for (0..view.item_count) |index| {
        const item = view.item(index) catch
            return Error.RankedResultMismatch;
        const ordinal = std.math.cast(
            usize,
            item.input_ordinal,
        ) orelse return Error.RankedResultMismatch;
        const expected_score = dotScoreV1(
            &plan,
            query_weights,
            dense_tensor,
            ordinal,
        ) catch return Error.RankedResultMismatch;
        if (item.score != expected_score)
            return Error.RankedResultMismatch;
    }
}

fn validateCandidateMapAndPolicyV1(
    plan: model.ExecutionPlanV1,
    batch_map: tensor_result.BatchMapViewV1,
    score_policy: tensor_result.ScorePolicyViewV1,
    candidate: []const u8,
) Error!void {
    validateRerankerPlanShapeV1(plan) catch
        return Error.RankedResultMismatch;
    const decoded_map = tensor_result.decodeBatchMapV1(
        batch_map.encoded,
    ) catch return Error.RankedResultMismatch;
    const decoded_policy = tensor_result.decodeScorePolicyV1(
        score_policy.encoded,
    ) catch return Error.RankedResultMismatch;
    if (candidate.len != plan.output_bytes or
        decoded_map.item_count != batch_map.item_count or
        !std.mem.eql(
            u8,
            &decoded_map.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.meta.eql(decoded_policy.policy, score_policy.policy) or
        !std.mem.eql(
            u8,
            &decoded_policy.score_policy_sha256,
            &score_policy.score_policy_sha256,
        ) or
        batch_map.item_count != plan.batch_items or
        score_policy.policy.normalization != .none or
        score_policy.policy.order != .score_descending or
        score_policy.policy.tie_break != .input_ordinal_ascending)
        return Error.RankedResultMismatch;
    const view = tensor_result.decodeAndVerifyRankedResultV1(
        candidate,
        batch_map.encoded,
        score_policy.encoded,
    ) catch return Error.RankedResultMismatch;
    if (view.item_count != batch_map.item_count or
        !std.mem.eql(
            u8,
            &view.batch_map_sha256,
            &batch_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &view.score_policy_sha256,
            &score_policy.score_policy_sha256,
        ))
        return Error.RankedResultMismatch;
    var seen_ordinals: u64 = 0;
    var previous: ?tensor_result.RankedItemV1 = null;
    for (0..view.item_count) |index| {
        const item = view.item(index) catch
            return Error.RankedResultMismatch;
        if (item.rank != index or
            item.input_ordinal >= view.item_count or
            item.item_id !=
                (batch_map.itemId(
                    @intCast(item.input_ordinal),
                ) catch return Error.RankedResultMismatch) or
            @as(i128, item.score) >
                @as(i128, plan.maximum_absolute_output) or
            @as(i128, item.score) <
                -@as(i128, plan.maximum_absolute_output))
            return Error.RankedResultMismatch;
        const bit = @as(u64, 1) <<
            @intCast(item.input_ordinal);
        if (seen_ordinals & bit != 0)
            return Error.RankedResultMismatch;
        seen_ordinals |= bit;
        if (previous) |prior| {
            if (prior.score < item.score or
                (prior.score == item.score and
                    prior.input_ordinal > item.input_ordinal))
                return Error.RankedResultMismatch;
        }
        previous = item;
    }
    const expected_seen = if (view.item_count == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(view.item_count)) - 1;
    if (seen_ordinals != expected_seen)
        return Error.RankedResultMismatch;
}

fn dotScoreV1(
    plan: *const model.ExecutionPlanV1,
    query_weights: []const u8,
    dense_tensor: []const u8,
    ordinal: usize,
) Error!i64 {
    const feature_count = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidTensorBinding;
    const item_count = std.math.cast(
        usize,
        plan.batch_items,
    ) orelse return Error.InvalidTensorBinding;
    const input_elements = std.math.mul(
        usize,
        item_count,
        feature_count,
    ) catch return Error.InvalidTensorBinding;
    const expected_input_bytes = std.math.mul(
        usize,
        input_elements,
        @sizeOf(i16),
    ) catch return Error.InvalidTensorBinding;
    const plan_input_bytes = std.math.cast(
        usize,
        plan.input_bytes,
    ) orelse return Error.InvalidTensorBinding;
    if (ordinal >= item_count or
        query_weights.len != feature_count or
        dense_tensor.len != expected_input_bytes or
        dense_tensor.len != plan_input_bytes)
        return Error.InvalidTensorBinding;
    const row_elements = std.math.mul(
        usize,
        ordinal,
        feature_count,
    ) catch return Error.InvalidTensorBinding;
    const row_offset = std.math.mul(
        usize,
        row_elements,
        @sizeOf(i16),
    ) catch return Error.InvalidTensorBinding;
    var accumulator: i64 = 0;
    for (0..feature_count) |feature| {
        const feature_offset = std.math.mul(
            usize,
            feature,
            @sizeOf(i16),
        ) catch return Error.InvalidTensorBinding;
        const tensor_offset = std.math.add(
            usize,
            row_offset,
            feature_offset,
        ) catch return Error.InvalidTensorBinding;
        const tensor_end = std.math.add(
            usize,
            tensor_offset,
            @sizeOf(i16),
        ) catch return Error.InvalidTensorBinding;
        if (tensor_end > dense_tensor.len)
            return Error.InvalidTensorBinding;
        const tensor_value: i64 = std.mem.readInt(
            i16,
            dense_tensor[tensor_offset..tensor_end][0..@sizeOf(i16)],
            .little,
        );
        const weight_value: i64 = @as(
            i8,
            @bitCast(query_weights[feature]),
        );
        const product = std.math.mul(
            i64,
            tensor_value,
            weight_value,
        ) catch return Error.RankedResultMismatch;
        accumulator = std.math.add(
            i64,
            accumulator,
            product,
        ) catch return Error.RankedResultMismatch;
    }
    return accumulator;
}

fn insertionSortRankedItems(
    items: []tensor_result.RankedItemV1,
) void {
    for (1..items.len) |index| {
        var cursor = index;
        while (cursor > 0 and
            rankedBefore(items[cursor], items[cursor - 1]))
        {
            std.mem.swap(
                tensor_result.RankedItemV1,
                &items[cursor],
                &items[cursor - 1],
            );
            cursor -= 1;
        }
    }
}

fn rankedBefore(
    left: tensor_result.RankedItemV1,
    right: tensor_result.RankedItemV1,
) bool {
    return left.score > right.score or
        (left.score == right.score and
            left.input_ordinal < right.input_ordinal);
}

fn bindingHasZeroRoot(binding: TensorInputBindingV1) bool {
    inline for (std.meta.fields(TensorInputBindingV1)) |field| {
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

pub const reference_item_ids = [_]u64{
    7_001,
    7_002,
    7_003,
    7_004,
};
pub const reference_query_weights = [_]i8{ 2, -1, 3 };
pub const reference_tensor_values = [_]i16{
    1,  0, 1,
    2,  2, 0,
    3,  1, 0,
    -2, 1, 0,
};
pub const reference_expected_ordinals = [_]u64{ 0, 2, 1, 3 };
pub const reference_expected_scores = [_]i64{ 5, 5, 2, -5 };

/// Small deterministic fixture with a score tie between input ordinals 0 and
/// 2. All bytes are generated locally and require no model download.
pub const ReferenceFixtureV1 = struct {
    batch_map_storage: [512]u8,
    batch_map_len: usize,
    score_policy_storage: [256]u8,
    score_policy_len: usize,
    query_weights: [reference_query_weights.len]u8,
    dense_tensor: [
        reference_tensor_values.len * @sizeOf(i16)
    ]u8,
    binding: TensorInputBindingV1,
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
        var score_policy_storage: [256]u8 = undefined;
        const score_policy_encoded =
            try tensor_result.encodeScorePolicyV1(
                .{},
                &score_policy_storage,
            );
        const score_policy_len = score_policy_encoded.len;
        const score_policy =
            try tensor_result.decodeScorePolicyV1(
                score_policy_encoded,
            );
        var query_weights: [reference_query_weights.len]u8 =
            undefined;
        for (reference_query_weights, 0..) |value, index|
            query_weights[index] = @bitCast(value);
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
            model.sha256("dense reranker input object");
        const ownership_sha256 =
            model.sha256("dense reranker ownership");
        const challenge_sha256 =
            model.sha256("dense reranker challenge");
        const tensor_sha256 = model.sha256(&dense_tensor);
        const input_bundle_sha256 = inputBundleRootV1(
            input_object_sha256,
            batch_map.batch_map_sha256,
            score_policy.score_policy_sha256,
            tensor_sha256,
            ownership_sha256,
            challenge_sha256,
        );
        const binding: TensorInputBindingV1 = .{
            .input_object_sha256 = input_object_sha256,
            .batch_map_sha256 = batch_map.batch_map_sha256,
            .score_policy_sha256 = score_policy.score_policy_sha256,
            .input_bundle_sha256 = input_bundle_sha256,
            .tensor_sha256 = tensor_sha256,
            .ownership_sha256 = ownership_sha256,
            .challenge_sha256 = challenge_sha256,
        };
        const manifest = try model.makeArtifactManifestV1(
            .stateless_encoder,
            0x4452_524b_0000_0001,
            .dense_tensor,
            .ranked_items,
            .exact_integer,
            reranker_support[0].max_batch_items,
            reference_query_weights.len,
            1,
            @sizeOf(i16),
            tensor_result.ranked_element_bytes,
            @sizeOf(i8),
            &query_weights,
            model.sha256("dense reranker fixture metadata"),
            model.sha256("fixture-only generated data license"),
        );
        const output_bytes =
            reference_item_ids.len *
            tensor_result.ranked_element_bytes;
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .rerank,
            .{
                .request_epoch = 601,
                .generation = 1,
                .batch_items = reference_item_ids.len,
                .publication_next_sequence = 0,
                .maximum_absolute_output = 1_000_000,
                .claim = .{
                    .capsule_bytes = query_weights.len,
                    .activation_bytes = dense_tensor.len,
                    .partial_bytes = output_bytes,
                    .output_journal_bytes = output_bytes,
                    .queue_slots = 1,
                },
                .media_object_sha256 = binding.input_object_sha256,
                .processor_state_sha256 = binding.batch_map_sha256,
                .processor_bundle_sha256 = binding.score_policy_sha256,
                .cache_bundle_sha256 = binding.input_bundle_sha256,
                .cache_payload_sha256 = binding.tensor_sha256,
                .ownership_sha256 = binding.ownership_sha256,
                .challenge_sha256 = binding.challenge_sha256,
                .previous_plan_sha256 = model.sha256("dense reranker genesis plan"),
                .input_schema_sha256 = model.sha256("four rows by three little-endian i16"),
                .output_schema_sha256 = model.sha256("four canonical ranked item records"),
                .scratch_bytes = output_bytes,
            },
        );
        return .{
            .batch_map_storage = batch_map_storage,
            .batch_map_len = batch_map_len,
            .score_policy_storage = score_policy_storage,
            .score_policy_len = score_policy_len,
            .query_weights = query_weights,
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

    pub fn scorePolicy(
        self: *const ReferenceFixtureV1,
    ) !tensor_result.ScorePolicyViewV1 {
        return tensor_result.decodeScorePolicyV1(
            self.score_policy_storage[0..self.score_policy_len],
        );
    }

    pub fn referenceContext(
        self: *const ReferenceFixtureV1,
    ) ReferenceContextV1 {
        return .{
            .batch_map_encoded = self.batch_map_storage[0..self.batch_map_len],
            .score_policy_encoded = self.score_policy_storage[0..self.score_policy_len],
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

fn expectReferenceRanking(
    fixture: *const ReferenceFixtureV1,
    output: []const u8,
) !void {
    const view = try tensor_result.decodeAndVerifyRankedResultV1(
        output,
        fixture.batch_map_storage[0..fixture.batch_map_len],
        fixture.score_policy_storage[0..fixture.score_policy_len],
    );
    try std.testing.expectEqual(reference_item_ids.len, view.item_count);
    for (0..view.item_count) |index| {
        const item = try view.item(index);
        try std.testing.expectEqual(@as(u64, @intCast(index)), item.rank);
        try std.testing.expectEqual(
            reference_expected_ordinals[index],
            item.input_ordinal,
        );
        try std.testing.expectEqual(
            reference_expected_scores[index],
            item.score,
        );
        try std.testing.expectEqual(
            reference_item_ids[
                @intCast(reference_expected_ordinals[index])
            ],
            item.item_id,
        );
    }
}

test "reranker validators bind the base contract and exact manifest" {
    const fixture = try ReferenceFixtureV1.init();
    try validateRerankerManifestV1(fixture.manifest);
    try validateRerankerPlanV1(fixture.manifest, fixture.plan);

    var invalid_manifest = fixture.manifest;
    invalid_manifest.artifact_abi = 0;
    try std.testing.expectError(
        Error.InvalidTensorBinding,
        validateRerankerManifestV1(invalid_manifest),
    );

    var narrow_manifest = fixture.manifest;
    narrow_manifest.max_batch_items =
        fixture.plan.batch_items - 1;
    try std.testing.expectError(
        Error.InvalidTensorBinding,
        validateRerankerPlanV1(narrow_manifest, fixture.plan),
    );

    var foreign_artifact_plan = fixture.plan;
    foreign_artifact_plan.artifact_sha256 =
        model.sha256("foreign reranker artifact");
    try std.testing.expectError(
        Error.InvalidTensorBinding,
        validateRerankerPlanV1(
            fixture.manifest,
            foreign_artifact_plan,
        ),
    );

    var foreign_weights_plan = fixture.plan;
    foreign_weights_plan.weights_sha256 =
        model.sha256("foreign reranker weights");
    try std.testing.expectError(
        Error.InvalidTensorBinding,
        validateRerankerPlanV1(
            fixture.manifest,
            foreign_weights_plan,
        ),
    );

    var malformed_shape_plan = fixture.plan;
    malformed_shape_plan.input_bytes -= 1;
    malformed_shape_plan.claim.activation_bytes =
        malformed_shape_plan.input_bytes;
    try std.testing.expectError(
        Error.InvalidTensorBinding,
        validateRerankerPlanV1(
            fixture.manifest,
            malformed_shape_plan,
        ),
    );
}

test "ranked validation rejects forged view roots" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    var context = fixture.referenceContext();
    var candidate: [
        reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    try referenceExecuteV1(
        &context,
        &fixture.plan,
        &fixture.query_weights,
        &fixture.dense_tensor,
        &candidate,
    );
    try validateRankedCandidateV1(
        fixture.plan,
        batch_map,
        policy,
        &fixture.query_weights,
        &fixture.dense_tensor,
        &candidate,
    );

    var forged_map = batch_map;
    forged_map.batch_map_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.RankedResultMismatch,
        validateRankedCandidateV1(
            fixture.plan,
            forged_map,
            policy,
            &fixture.query_weights,
            &fixture.dense_tensor,
            &candidate,
        ),
    );

    var forged_policy = policy;
    forged_policy.score_policy_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.RankedResultMismatch,
        validateRankedCandidateV1(
            fixture.plan,
            batch_map,
            forged_policy,
            &fixture.query_weights,
            &fixture.dense_tensor,
            &candidate,
        ),
    );
}

test "ranked validation rejects unsafe shapes without narrowing wire limits" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    var context = fixture.referenceContext();
    var reference_candidate: [
        reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    try referenceExecuteV1(
        &context,
        &fixture.plan,
        &fixture.query_weights,
        &fixture.dense_tensor,
        &reference_candidate,
    );

    var malformed_plan = fixture.plan;
    malformed_plan.input_bytes = 1;
    malformed_plan.claim.activation_bytes = 1;
    const truncated_tensor = [_]u8{0};
    try std.testing.expectError(
        Error.RankedResultMismatch,
        validateRankedCandidateV1(
            malformed_plan,
            batch_map,
            policy,
            &fixture.query_weights,
            &truncated_tensor,
            &reference_candidate,
        ),
    );

    const oversized_count: usize =
        reranker_support[0].max_batch_items + 1;
    var oversized_ids: [oversized_count]u64 = undefined;
    var oversized_items: [oversized_count]tensor_result.RankedItemV1 = undefined;
    for (0..oversized_count) |index| {
        oversized_ids[index] = @intCast(index + 1);
        oversized_items[index] = .{
            .item_id = oversized_ids[index],
            .input_ordinal = @intCast(index),
            .rank = @intCast(index),
            .score = 0,
        };
    }
    var oversized_map_storage: [
        tensor_result.batch_map_header_bytes +
            oversized_count * tensor_result.batch_map_item_bytes +
            tensor_result.batch_map_footer_bytes
    ]u8 = undefined;
    const oversized_map_encoded =
        try tensor_result.encodeBatchMapV1(
            &oversized_ids,
            &oversized_map_storage,
        );
    const oversized_map =
        try tensor_result.decodeBatchMapV1(oversized_map_encoded);
    var oversized_policy_storage: [tensor_result.score_policy_bytes]u8 = undefined;
    const oversized_policy_encoded =
        try tensor_result.encodeScorePolicyV1(
            .{},
            &oversized_policy_storage,
        );
    const oversized_policy =
        try tensor_result.decodeScorePolicyV1(
            oversized_policy_encoded,
        );
    var oversized_result_storage: [
        oversized_count *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    const oversized_result =
        try tensor_result.encodeRankedResultV1(
            oversized_map_encoded,
            oversized_policy_encoded,
            &oversized_items,
            &oversized_result_storage,
        );
    _ = try tensor_result.decodeAndVerifyRankedResultV1(
        oversized_result,
        oversized_map_encoded,
        oversized_policy_encoded,
    );

    const oversized_input_bytes =
        oversized_count *
        reference_query_weights.len *
        @sizeOf(i16);
    var oversized_tensor =
        [_]u8{0} ** oversized_input_bytes;
    var oversized_plan = fixture.plan;
    oversized_plan.batch_items = oversized_count;
    oversized_plan.input_bytes = oversized_input_bytes;
    oversized_plan.output_bytes = oversized_result.len;
    oversized_plan.scratch_bytes = oversized_result.len;
    oversized_plan.claim.activation_bytes =
        oversized_plan.input_bytes;
    oversized_plan.claim.partial_bytes =
        oversized_plan.scratch_bytes;
    oversized_plan.claim.output_journal_bytes =
        oversized_plan.output_bytes;
    try std.testing.expectError(
        Error.RankedResultMismatch,
        validateRankedCandidateV1(
            oversized_plan,
            oversized_map,
            oversized_policy,
            &fixture.query_weights,
            &oversized_tensor,
            oversized_result,
        ),
    );
}

test "dense tensor reranker directly publishes canonical tied ranking" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x5201,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x5202,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [
        reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    var output = [_]u8{0xa5} ** candidate.len;
    const prepared = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.query_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try expectReferenceRanking(&fixture, &candidate);
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try expectReferenceRanking(&fixture, &output);
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
    const final_snapshot = try bank.snapshot();
    try std.testing.expect(final_snapshot.used.isZero());
    try std.testing.expectEqual(
        @as(usize, 0),
        final_snapshot.committed_receipts,
    );
}

test "post-validation mismatch rolls back candidate and ownership" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    var foreign_map_storage: [512]u8 = undefined;
    const foreign_ids = [_]u64{ 8_001, 8_002, 8_003, 8_004 };
    const foreign_map = try tensor_result.encodeBatchMapV1(
        &foreign_ids,
        &foreign_map_storage,
    );
    var context: ReferenceContextV1 = .{
        .batch_map_encoded = foreign_map,
        .score_policy_encoded = fixture.score_policy_storage[0..fixture.score_policy_len],
    };
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x5301,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x5302,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [
        reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    var output = [_]u8{0xa5} ** candidate.len;
    try std.testing.expectError(
        Error.RankedResultMismatch,
        session.prepareV1(
            fixture.binding,
            batch_map,
            policy,
            &fixture.query_weights,
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

test "ranked output cannot alias canonical map or policy evidence" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    const batch_root_before = batch_map.batch_map_sha256;
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x5351,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x5352,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    const output_bytes: usize = @intCast(fixture.plan.output_bytes);
    var visible_output: [
        reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidTensorBinding,
        session.prepareV1(
            fixture.binding,
            batch_map,
            policy,
            &fixture.query_weights,
            &fixture.dense_tensor,
            fixture.batch_map_storage[0..output_bytes],
            &visible_output,
        ),
    );
    const map_after = try fixture.batchMap();
    try std.testing.expectEqual(
        batch_root_before,
        map_after.batch_map_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "scheduled reranking publishes only with the final service quantum" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x5401,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &runtime.lane_slots,
            .projection = &runtime.projection,
        },
        .{
            .scheduler_epoch = 0x5402,
            .challenge = model.sha256("scheduled reranker challenge"),
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const decision = try scheduler.admit(.{
        .tenant_key = 0x5403,
        .request_key = 0x5404,
        .request_generation = 1,
        .resource_owner_key = 0x5405,
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
    var candidate: [
        reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    var output: [candidate.len]u8 = undefined;
    const prepared = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.query_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    const armed_service = try scheduler.armServiceCommit(permit);
    var armed_model = try session.armServiceV1(
        armed_service.intent,
    );
    _ = try scheduler.commitArmedServiceV2(
        armed_service.ticket,
        armed_model.finalizer(),
    );
    try std.testing.expectEqual(prepared, try armed_model.resultV1());
    try expectReferenceRanking(&fixture, &output);
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.publication_state.visible_results,
    );
    const retired = try session.retireScheduledV1();
    try std.testing.expectEqual(qos.EventKind.retire, retired.kind);
    _ = try scheduler.close();
    const final_snapshot = try bank.snapshot();
    try std.testing.expect(final_snapshot.used.isZero());
    try std.testing.expectEqual(
        @as(usize, 0),
        final_snapshot.committed_receipts,
    );
}

test "scheduled cancellation after abort leaves zero ownership" {
    var fixture = try ReferenceFixtureV1.init();
    const batch_map = try fixture.batchMap();
    const policy = try fixture.scorePolicy();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x5501,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &runtime.lane_slots,
            .projection = &runtime.projection,
        },
        .{
            .scheduler_epoch = 0x5502,
            .challenge = model.sha256("cancel reranker challenge"),
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const decision = try scheduler.admit(.{
        .tenant_key = 0x5503,
        .request_key = 0x5504,
        .request_generation = 1,
        .resource_owner_key = 0x5505,
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
    var candidate: [
        reference_item_ids.len *
            tensor_result.ranked_element_bytes
    ]u8 = undefined;
    var output = [_]u8{0xa5} ** candidate.len;
    _ = try session.prepareV1(
        fixture.binding,
        batch_map,
        policy,
        &fixture.query_weights,
        &fixture.dense_tensor,
        &candidate,
        &output,
    );
    try session.abortV1();
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const cancelled = try session.cancelScheduledV1();
    try std.testing.expectEqual(qos.EventKind.cancel, cancelled.kind);
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    _ = try scheduler.close();
    const final_snapshot = try bank.snapshot();
    try std.testing.expect(final_snapshot.used.isZero());
    try std.testing.expectEqual(
        @as(usize, 0),
        final_snapshot.committed_receipts,
    );
}
