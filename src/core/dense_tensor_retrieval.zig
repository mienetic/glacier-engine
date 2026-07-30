//! Exact, allocation-free fixed-corpus retrieval reference adapter.
//!
//! The adapter treats the authenticated index descriptor followed by the
//! row-major Q30 corpus embedding matrix as immutable artifact weights. The
//! execution-plan input is one Q30 query row; its map, policy, tenant
//! visibility, and request binding are explicit caller-supplied evidence. It
//! publishes only a canonical bounded top-k result through the common
//! stateless lifecycle.
//! The retained arithmetic is a conformance fixture, not a production-quality
//! semantic-search claim.

const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const qos = @import("lane_weave_qos.zig");
const stateless = @import("stateless_model_adapter.zig");
const tensor_result = @import("stateless_tensor_result.zig");
const embedding_result = @import("stateless_embedding_result.zig");
const retrieval_result = @import("stateless_retrieval_result.zig");

pub const Digest = model.Digest;
pub const reference_adapter_abi: u64 = 0x4744_5254_0000_0001;
pub const maximum_corpus_items: u64 = 64;
pub const maximum_embedding_dimensions: u64 = 4_096;
pub const maximum_result_bytes: u64 = 64 * 96;

pub const retrieval_support = [_]model.SupportRecordV1{.{
    .family = .retrieval,
    .operation = .retrieve,
    .input_kind = .embedding_i32,
    .output_kind = .retrieval_hits,
    .numerical_policy = .exact_integer,
    .max_batch_items = 1,
    .max_input_features = maximum_embedding_dimensions,
    .max_output_dimensions = maximum_result_bytes,
    .allowed_capabilities = model.no_capabilities,
}};

const source_mapping_domain =
    "glacier-dense-tensor-retrieval-source-mapping-v1\x00";
const input_bundle_domain =
    "glacier-dense-tensor-retrieval-input-bundle-v1\x00";

pub const Error = stateless.Error || tensor_result.Error ||
    embedding_result.Error || retrieval_result.Error || error{
    InvalidRetrievalBinding,
    RetrievalResultMismatch,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const ArmedScheduledResultV1 = stateless.ArmedScheduledResultV1;

/// Exact roots projected into the otherwise model-family-neutral plan.
///
/// `input_bundle_sha256` commits every preceding field through
/// `inputBundleRootV1`; no evidence slice is trusted merely because it was
/// supplied through the adapter context.
pub const RetrievalInputBindingV1 = struct {
    query_object_sha256: Digest,
    query_map_sha256: Digest,
    embedding_policy_sha256: Digest,
    query_embedding_sha256: Digest,
    index_descriptor_sha256: Digest,
    corpus_map_sha256: Digest,
    corpus_embedding_sha256: Digest,
    retrieval_policy_sha256: Digest,
    visibility_sha256: Digest,
    query_binding_sha256: Digest,
    input_bundle_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
};

/// Pointer-bearing execution context. Every referenced byte slice is decoded
/// and checked against `RetrievalInputBindingV1` before execution.
pub const ReferenceContextV1 = struct {
    corpus_map_encoded: []const u8,
    query_map_encoded: []const u8,
    embedding_policy_encoded: []const u8,
    retrieval_policy_encoded: []const u8,
    visibility_encoded: []const u8,
    query_binding_encoded: []const u8,
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
        try validateRetrievalAdapterV1(adapter, manifest, plan);
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &retrieval_support,
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
        try validateRetrievalAdapterV1(adapter, manifest, plan);
        try self.inner.initScheduledV1(
            scheduler,
            admission,
            publication_state,
            manifest,
            plan,
            adapter,
            &retrieval_support,
        );
    }

    /// Runs the adapter into provisional storage, then independently repeats
    /// the exact search into bounded stack storage before permitting commit.
    pub fn prepareV1(
        self: *Session,
        binding: RetrievalInputBindingV1,
        index: retrieval_result.RetrievalIndexViewV1,
        corpus_map: tensor_result.BatchMapViewV1,
        query_map: tensor_result.BatchMapViewV1,
        embedding_policy: embedding_result.EmbeddingPolicyViewV1,
        retrieval_policy: retrieval_result.RetrievalPolicyViewV1,
        visibility: retrieval_result.VisibilityMapViewV1,
        query_binding: retrieval_result.QueryBindingViewV1,
        packed_weights: []const u8,
        query_embedding: []const u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateRetrievalBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            binding,
            index,
            corpus_map,
            query_map,
            embedding_policy,
            retrieval_policy,
            visibility,
            query_binding,
            packed_weights,
            query_embedding,
        );
        const output_bytes = std.math.cast(
            usize,
            self.inner.plan.output_bytes,
        ) orelse return Error.InvalidRetrievalBinding;
        if (candidate.len < output_bytes or
            visible_output.len < output_bytes)
            return Error.BufferTooSmall;
        const candidate_output = candidate[0..output_bytes];
        const visible_output_slice = visible_output[0..output_bytes];
        if (slicesOverlap(candidate_output, visible_output_slice))
            return Error.InvalidRetrievalBinding;
        const evidence = [_][]const u8{
            index.encoded,
            corpus_map.encoded,
            query_map.encoded,
            embedding_policy.encoded,
            retrieval_policy.encoded,
            visibility.encoded,
            query_binding.encoded,
            packed_weights,
            query_embedding,
        };
        for (evidence) |encoded| {
            if (slicesOverlap(candidate_output, encoded) or
                slicesOverlap(visible_output_slice, encoded))
                return Error.InvalidRetrievalBinding;
        }
        const source_mapping_sha256 =
            try sourceMappingRootV1(self.inner.plan, binding);
        const prepared = try self.inner.prepareV1(
            packed_weights,
            query_embedding,
            source_mapping_sha256,
            candidate,
            visible_output,
        );
        validateRetrievalCandidateV1(
            self.inner.plan,
            index,
            corpus_map,
            query_map,
            embedding_policy,
            retrieval_policy,
            visibility,
            query_binding,
            packed_weights,
            query_embedding,
            candidate_output,
        ) catch {
            self.inner.abortV1() catch |err| return err;
            return Error.RetrievalResultMismatch;
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
    try validateRetrievalManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .retrieve,
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
            model.sha256("reference exact q30 fixed corpus retrieval v1"),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateReferenceCandidateV1,
    };
}

pub fn validateRetrievalAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateRetrievalPlanV1(manifest, plan);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &retrieval_support,
    );
}

pub fn validateRetrievalManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    model.validateArtifactManifestV1(manifest) catch
        return Error.InvalidRetrievalBinding;
    var canonical_wire: [model.artifact_manifest_bytes]u8 = undefined;
    model.encodeArtifactManifestV1(
        manifest,
        &canonical_wire,
    ) catch return Error.InvalidRetrievalBinding;
    if (!std.mem.eql(
        u8,
        &manifest.artifact_sha256,
        canonical_wire[canonical_wire.len - @sizeOf(Digest) ..],
    ))
        return Error.InvalidRetrievalBinding;
    if (manifest.family != .retrieval or
        manifest.input_kind != .embedding_i32 or
        manifest.output_kind != .retrieval_hits or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items != 1 or
        manifest.input_features == 0 or
        manifest.input_features >
            retrieval_support[0].max_input_features or
        manifest.output_dimensions == 0 or
        manifest.output_dimensions >
            retrieval_support[0].max_output_dimensions or
        manifest.input_element_bytes !=
            embedding_result.embedding_component_bytes or
        manifest.output_element_bytes != 1 or
        manifest.weight_element_bytes != 1 or
        manifest.weight_elements != manifest.weight_bytes)
        return Error.InvalidRetrievalBinding;
    const corpus_count = try corpusCountFromShapeV1(
        manifest.input_features,
        manifest.weight_bytes,
    );
    const expected_result_bytes =
        retrieval_result.retrievalResultEncodedSizeV1(corpus_count) catch
            return Error.InvalidRetrievalBinding;
    if (manifest.output_dimensions !=
        @as(u64, @intCast(expected_result_bytes)))
        return Error.InvalidRetrievalBinding;
}

pub fn validateRetrievalPlanV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateRetrievalManifestV1(manifest);
    try validateRetrievalPlanShapeV1(plan);
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
        return Error.InvalidRetrievalBinding;
}

fn validateRetrievalPlanShapeV1(
    plan: model.ExecutionPlanV1,
) Error!void {
    model.validateExecutionPlanV1(plan) catch
        return Error.InvalidRetrievalBinding;
    var canonical_wire: [model.execution_plan_bytes]u8 = undefined;
    model.encodeExecutionPlanV1(
        plan,
        &canonical_wire,
    ) catch return Error.InvalidRetrievalBinding;
    if (!std.mem.eql(
        u8,
        &plan.plan_sha256,
        canonical_wire[canonical_wire.len - @sizeOf(Digest) ..],
    ))
        return Error.InvalidRetrievalBinding;
    const corpus_count = try corpusCountFromShapeV1(
        plan.input_features,
        plan.weight_bytes,
    );
    const expected_result_bytes =
        retrieval_result.retrievalResultEncodedSizeV1(corpus_count) catch
            return Error.InvalidRetrievalBinding;
    const expected_input_bytes = std.math.mul(
        u64,
        plan.input_features,
        embedding_result.embedding_component_bytes,
    ) catch return Error.InvalidRetrievalBinding;
    if (plan.family != .retrieval or
        plan.operation != .retrieve or
        plan.input_kind != .embedding_i32 or
        plan.output_kind != .retrieval_hits or
        plan.numerical_policy != .exact_integer or
        plan.batch_items != 1 or
        plan.input_features == 0 or
        plan.input_features >
            retrieval_support[0].max_input_features or
        plan.output_dimensions !=
            @as(u64, @intCast(expected_result_bytes)) or
        plan.output_dimensions >
            retrieval_support[0].max_output_dimensions or
        plan.input_bytes != expected_input_bytes or
        plan.output_bytes !=
            @as(u64, @intCast(expected_result_bytes)) or
        plan.input_element_bytes !=
            embedding_result.embedding_component_bytes or
        plan.output_element_bytes != 1 or
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
        return Error.InvalidRetrievalBinding;
}

fn corpusCountFromShapeV1(
    dimensions: u64,
    packed_weight_bytes: u64,
) Error!usize {
    if (dimensions == 0 or
        dimensions > maximum_embedding_dimensions or
        packed_weight_bytes <= retrieval_result.retrieval_index_bytes)
        return Error.InvalidRetrievalBinding;
    const row_bytes = std.math.mul(
        u64,
        dimensions,
        embedding_result.embedding_component_bytes,
    ) catch return Error.InvalidRetrievalBinding;
    const matrix_bytes =
        packed_weight_bytes - retrieval_result.retrieval_index_bytes;
    if (row_bytes == 0 or matrix_bytes % row_bytes != 0)
        return Error.InvalidRetrievalBinding;
    const corpus_count = matrix_bytes / row_bytes;
    if (corpus_count == 0 or corpus_count > maximum_corpus_items)
        return Error.InvalidRetrievalBinding;
    return std.math.cast(usize, corpus_count) orelse
        return Error.InvalidRetrievalBinding;
}

pub fn inputBundleRootV1(
    binding: RetrievalInputBindingV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(input_bundle_domain);
    hash.update(&binding.query_object_sha256);
    hash.update(&binding.query_map_sha256);
    hash.update(&binding.embedding_policy_sha256);
    hash.update(&binding.query_embedding_sha256);
    hash.update(&binding.index_descriptor_sha256);
    hash.update(&binding.corpus_map_sha256);
    hash.update(&binding.corpus_embedding_sha256);
    hash.update(&binding.retrieval_policy_sha256);
    hash.update(&binding.visibility_sha256);
    hash.update(&binding.query_binding_sha256);
    hash.update(&binding.ownership_sha256);
    hash.update(&binding.challenge_sha256);
    return hash.finalResult();
}

pub fn sourceMappingRootV1(
    plan: model.ExecutionPlanV1,
    binding: RetrievalInputBindingV1,
) Error!Digest {
    if (bindingHasZeroRoot(binding) or
        !std.mem.eql(
            u8,
            &binding.query_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.query_map_sha256,
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
            &binding.query_embedding_sha256,
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
            &binding.query_binding_sha256,
            &plan.input_schema_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.retrieval_policy_sha256,
            &plan.output_schema_sha256,
        ))
        return Error.InvalidRetrievalBinding;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_mapping_domain);
    inline for (std.meta.fields(RetrievalInputBindingV1)) |field|
        hash.update(&@field(binding, field.name));
    hashU64(&hash, plan.request_epoch);
    hashU64(&hash, plan.generation);
    hashU64(&hash, plan.publication_next_sequence);
    hashU64(&hash, plan.batch_items);
    hashU64(&hash, plan.input_features);
    hashU64(&hash, plan.output_dimensions);
    return hash.finalResult();
}

pub fn validateRetrievalBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    binding: RetrievalInputBindingV1,
    index: retrieval_result.RetrievalIndexViewV1,
    corpus_map: tensor_result.BatchMapViewV1,
    query_map: tensor_result.BatchMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    retrieval_policy: retrieval_result.RetrievalPolicyViewV1,
    visibility: retrieval_result.VisibilityMapViewV1,
    query_binding: retrieval_result.QueryBindingViewV1,
    packed_weights: []const u8,
    query_embedding: []const u8,
) Error!void {
    try validateRetrievalPlanV1(manifest, plan);
    const artifact = try splitPackedArtifactV1(plan, packed_weights);
    const decoded_index = retrieval_result.decodeRetrievalIndexV1(
        index.encoded,
    ) catch return Error.InvalidRetrievalBinding;
    const decoded_corpus_map = tensor_result.decodeBatchMapV1(
        corpus_map.encoded,
    ) catch return Error.InvalidRetrievalBinding;
    const decoded_query_map = tensor_result.decodeBatchMapV1(
        query_map.encoded,
    ) catch return Error.InvalidRetrievalBinding;
    const decoded_embedding_policy =
        embedding_result.decodeEmbeddingPolicyV1(
            embedding_policy.encoded,
        ) catch return Error.InvalidRetrievalBinding;
    const decoded_retrieval_policy =
        retrieval_result.decodeRetrievalPolicyV1(
            retrieval_policy.encoded,
        ) catch return Error.InvalidRetrievalBinding;
    const decoded_visibility =
        retrieval_result.decodeAndValidateVisibilityMapV1(
            visibility.encoded,
            corpus_map.encoded,
        ) catch return Error.InvalidRetrievalBinding;
    const decoded_query_binding =
        retrieval_result.decodeQueryBindingV1(
            query_binding.encoded,
        ) catch return Error.InvalidRetrievalBinding;

    const corpus_count = try corpusCountFromShapeV1(
        plan.input_features,
        plan.weight_bytes,
    );
    const dimensions = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidRetrievalBinding;
    const corpus_embedding =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            artifact.corpus_embedding,
            corpus_map.batch_map_sha256,
            embedding_policy.encoded,
            corpus_count,
            dimensions,
        ) catch return Error.InvalidRetrievalBinding;
    const query_embedding_view =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            query_embedding,
            query_map.batch_map_sha256,
            embedding_policy.encoded,
            1,
            dimensions,
        ) catch return Error.InvalidRetrievalBinding;

    if (!std.mem.eql(u8, artifact.index_encoded, index.encoded) or
        !std.meta.eql(decoded_index.index, index.index) or
        !std.mem.eql(
            u8,
            &decoded_index.retrieval_index_sha256,
            &index.retrieval_index_sha256,
        ) or
        decoded_corpus_map.item_count != corpus_map.item_count or
        !std.mem.eql(
            u8,
            &decoded_corpus_map.batch_map_sha256,
            &corpus_map.batch_map_sha256,
        ) or
        decoded_query_map.item_count != query_map.item_count or
        !std.mem.eql(
            u8,
            &decoded_query_map.batch_map_sha256,
            &query_map.batch_map_sha256,
        ) or
        !std.meta.eql(
            decoded_embedding_policy.policy,
            embedding_policy.policy,
        ) or
        !std.meta.eql(
            decoded_embedding_policy.policy,
            embedding_result.canonical_embedding_policy_v1,
        ) or
        !std.mem.eql(
            u8,
            &decoded_embedding_policy.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ) or
        !std.meta.eql(
            decoded_retrieval_policy.policy,
            retrieval_policy.policy,
        ) or
        !std.mem.eql(
            u8,
            &decoded_retrieval_policy.retrieval_policy_sha256,
            &retrieval_policy.retrieval_policy_sha256,
        ) or
        decoded_visibility.item_count != visibility.item_count or
        !std.mem.eql(
            u8,
            &decoded_visibility.corpus_batch_map_sha256,
            &visibility.corpus_batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &decoded_visibility.visibility_sha256,
            &visibility.visibility_sha256,
        ) or
        !std.meta.eql(
            decoded_query_binding.binding,
            query_binding.binding,
        ) or
        !std.mem.eql(
            u8,
            &decoded_query_binding.query_binding_sha256,
            &query_binding.query_binding_sha256,
        ))
        return Error.InvalidRetrievalBinding;

    if (corpus_map.item_count != corpus_count or
        query_map.item_count != 1 or
        visibility.item_count != corpus_count or
        index.index.corpus_count != corpus_count or
        index.index.dimensions != dimensions or
        retrieval_policy.policy.top_k == 0 or
        retrieval_policy.policy.top_k > corpus_count or
        query_binding.binding.dimensions != dimensions or
        query_embedding.len != plan.input_bytes or
        !std.mem.eql(
            u8,
            &model.sha256(packed_weights),
            &plan.weights_sha256,
        ) or
        !std.mem.eql(
            u8,
            &model.sha256(index.encoded),
            &manifest.metadata_sha256,
        ) or
        !std.mem.eql(
            u8,
            &query_embedding_view.embedding_matrix_sha256,
            &binding.query_embedding_sha256,
        ) or
        !std.mem.eql(
            u8,
            &corpus_embedding.embedding_matrix_sha256,
            &binding.corpus_embedding_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.query_map_sha256,
            &query_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.index_descriptor_sha256,
            &index.retrieval_index_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.corpus_map_sha256,
            &corpus_map.batch_map_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.retrieval_policy_sha256,
            &retrieval_policy.retrieval_policy_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.visibility_sha256,
            &visibility.visibility_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.query_binding_sha256,
            &query_binding.query_binding_sha256,
        ) or
        !std.mem.eql(
            u8,
            &binding.input_bundle_sha256,
            &inputBundleRootV1(binding),
        ) or
        !queryBindingMatchesV1(
            query_binding,
            index,
            query_map,
            embedding_policy,
            retrieval_policy,
            query_embedding_view,
            binding.query_object_sha256,
            binding.challenge_sha256,
        ) or
        !indexMatchesCorpusV1(
            index,
            corpus_map,
            embedding_policy,
            visibility,
            corpus_embedding,
        ) or
        bindingHasZeroRoot(binding))
        return Error.InvalidRetrievalBinding;

    _ = try sourceMappingRootV1(plan, binding);
}

fn queryBindingMatchesV1(
    query_binding: retrieval_result.QueryBindingViewV1,
    index: retrieval_result.RetrievalIndexViewV1,
    query_map: tensor_result.BatchMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    retrieval_policy: retrieval_result.RetrievalPolicyViewV1,
    query_embedding: embedding_result.NormalizedEmbeddingViewV1,
    query_object_sha256: Digest,
    challenge_sha256: Digest,
) bool {
    return query_binding.binding.query_tenant != 0 and
        query_binding.binding.dimensions == query_embedding.dimensions and
        std.mem.eql(
            u8,
            &query_binding.binding.query_object_sha256,
            &query_object_sha256,
        ) and
        std.mem.eql(
            u8,
            &query_binding.binding.query_map_sha256,
            &query_map.batch_map_sha256,
        ) and
        std.mem.eql(
            u8,
            &query_binding.binding.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ) and
        std.mem.eql(
            u8,
            &query_binding.binding.query_embedding_sha256,
            &query_embedding.embedding_matrix_sha256,
        ) and
        std.mem.eql(
            u8,
            &query_binding.binding.index_descriptor_sha256,
            &index.index_descriptor_sha256,
        ) and
        std.mem.eql(
            u8,
            &query_binding.binding.retrieval_policy_sha256,
            &retrieval_policy.retrieval_policy_sha256,
        ) and
        std.mem.eql(
            u8,
            &query_binding.binding.challenge_sha256,
            &challenge_sha256,
        );
}

fn indexMatchesCorpusV1(
    index: retrieval_result.RetrievalIndexViewV1,
    corpus_map: tensor_result.BatchMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    visibility: retrieval_result.VisibilityMapViewV1,
    corpus_embedding: embedding_result.NormalizedEmbeddingViewV1,
) bool {
    return index.index.generation != 0 and
        index.index.corpus_count == corpus_embedding.item_count and
        index.index.dimensions == corpus_embedding.dimensions and
        std.mem.eql(
            u8,
            &index.index.corpus_map_sha256,
            &corpus_map.batch_map_sha256,
        ) and
        std.mem.eql(
            u8,
            &index.index.visibility_sha256,
            &visibility.visibility_sha256,
        ) and
        std.mem.eql(
            u8,
            &index.index.embedding_policy_sha256,
            &embedding_policy.embedding_policy_sha256,
        ) and
        std.mem.eql(
            u8,
            &index.index.corpus_embedding_sha256,
            &corpus_embedding.embedding_matrix_sha256,
        );
}

pub fn referenceExecuteV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    packed_weights: []const u8,
    query_embedding: []const u8,
    candidate: []u8,
) anyerror!void {
    const context: *ReferenceContextV1 =
        @ptrCast(@alignCast(opaque_context));
    const artifact = try splitPackedArtifactV1(
        plan.*,
        packed_weights,
    );
    const corpus_map = try tensor_result.decodeBatchMapV1(
        context.corpus_map_encoded,
    );
    const query_map = try tensor_result.decodeBatchMapV1(
        context.query_map_encoded,
    );
    const embedding_policy =
        try embedding_result.decodeEmbeddingPolicyV1(
            context.embedding_policy_encoded,
        );
    const policy = try retrieval_result.decodeRetrievalPolicyV1(
        context.retrieval_policy_encoded,
    );
    const visibility =
        try retrieval_result.decodeAndValidateVisibilityMapV1(
            context.visibility_encoded,
            context.corpus_map_encoded,
        );
    const index = try retrieval_result.decodeRetrievalIndexV1(
        artifact.index_encoded,
    );
    const query_binding = try retrieval_result.decodeQueryBindingV1(
        context.query_binding_encoded,
    );
    const corpus_count = try corpusCountFromShapeV1(
        plan.input_features,
        plan.weight_bytes,
    );
    const dimensions = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidRetrievalBinding;
    const corpus_embedding =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            artifact.corpus_embedding,
            corpus_map.batch_map_sha256,
            embedding_policy.encoded,
            corpus_count,
            dimensions,
        );
    const query_embedding_view =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            query_embedding,
            query_map.batch_map_sha256,
            embedding_policy.encoded,
            1,
            dimensions,
        );
    const encoded = try retrieval_result.searchTopKV1(
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding_view,
        policy,
        query_binding,
        candidate,
    );
    if (encoded.len != candidate.len or
        candidate.len != plan.output_bytes)
        return Error.InvalidRetrievalBinding;
}

pub fn validateReferenceCandidateV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    _ = opaque_context;
    validateRetrievalPlanShapeV1(plan.*) catch
        return Error.RetrievalResultMismatch;
    if (candidate.len != plan.output_bytes)
        return Error.RetrievalResultMismatch;
}

pub fn validateRetrievalCandidateV1(
    plan: model.ExecutionPlanV1,
    index: retrieval_result.RetrievalIndexViewV1,
    corpus_map: tensor_result.BatchMapViewV1,
    query_map: tensor_result.BatchMapViewV1,
    embedding_policy: embedding_result.EmbeddingPolicyViewV1,
    retrieval_policy: retrieval_result.RetrievalPolicyViewV1,
    visibility: retrieval_result.VisibilityMapViewV1,
    query_binding: retrieval_result.QueryBindingViewV1,
    packed_weights: []const u8,
    query_embedding: []const u8,
    candidate: []const u8,
) Error!void {
    validateRetrievalPlanShapeV1(plan) catch
        return Error.RetrievalResultMismatch;
    const artifact = splitPackedArtifactV1(
        plan,
        packed_weights,
    ) catch return Error.RetrievalResultMismatch;
    const needed = std.math.cast(
        usize,
        plan.output_bytes,
    ) orelse return Error.RetrievalResultMismatch;
    if (needed > maximum_result_bytes or candidate.len != needed)
        return Error.RetrievalResultMismatch;
    var expected_storage: [maximum_result_bytes]u8 = undefined;
    const expected = retrieval_result.searchTopKV1(
        corpus_map,
        visibility,
        embedding_policy,
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            artifact.corpus_embedding,
            corpus_map.batch_map_sha256,
            embedding_policy.encoded,
            corpus_map.item_count,
            @intCast(plan.input_features),
        ) catch return Error.RetrievalResultMismatch,
        index,
        query_map,
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            query_embedding,
            query_map.batch_map_sha256,
            embedding_policy.encoded,
            1,
            @intCast(plan.input_features),
        ) catch return Error.RetrievalResultMismatch,
        retrieval_policy,
        query_binding,
        expected_storage[0..needed],
    ) catch return Error.RetrievalResultMismatch;
    if (expected.len != candidate.len or
        !std.mem.eql(u8, expected, candidate))
        return Error.RetrievalResultMismatch;
    const corpus_embedding =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            artifact.corpus_embedding,
            corpus_map.batch_map_sha256,
            embedding_policy.encoded,
            corpus_map.item_count,
            @intCast(plan.input_features),
        ) catch return Error.RetrievalResultMismatch;
    const query_embedding_view =
        embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            query_embedding,
            query_map.batch_map_sha256,
            embedding_policy.encoded,
            1,
            @intCast(plan.input_features),
        ) catch return Error.RetrievalResultMismatch;
    _ = retrieval_result.decodeRetrievalResultV1(
        candidate,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding_view,
        retrieval_policy,
        query_binding,
    ) catch
        return Error.RetrievalResultMismatch;
}

const PackedArtifactV1 = struct {
    index_encoded: []const u8,
    corpus_embedding: []const u8,
};

fn splitPackedArtifactV1(
    plan: model.ExecutionPlanV1,
    packed_weights: []const u8,
) Error!PackedArtifactV1 {
    const expected = std.math.cast(
        usize,
        plan.weight_bytes,
    ) orelse return Error.InvalidRetrievalBinding;
    if (packed_weights.len != expected or
        packed_weights.len <= retrieval_result.retrieval_index_bytes)
        return Error.InvalidRetrievalBinding;
    return .{
        .index_encoded = packed_weights[0..retrieval_result.retrieval_index_bytes],
        .corpus_embedding = packed_weights[retrieval_result.retrieval_index_bytes..],
    };
}

fn bindingHasZeroRoot(binding: RetrievalInputBindingV1) bool {
    inline for (std.meta.fields(RetrievalInputBindingV1)) |field| {
        if (std.mem.allEqual(u8, &@field(binding, field.name), 0))
            return true;
    }
    return false;
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

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

pub const reference_corpus_item_ids = [_]u64{
    101,
    201,
    202,
    203,
};
pub const reference_query_item_ids = [_]u64{9001};
pub const reference_visibility_tenants = [_]u64{
    99,
    7,
    7,
    7,
};
pub const reference_dimensions: usize = 2;
pub const reference_top_k: usize = 2;
pub const reference_corpus_components = [_]i32{
    embedding_result.q30_scale,  0,
    0,                           embedding_result.q30_scale,
    0,                           embedding_result.q30_scale,
    -embedding_result.q30_scale, 0,
};
pub const reference_query_components = [_]i32{
    embedding_result.q30_scale,
    0,
};
pub const reference_expected_hits = [_]retrieval_result.RetrievalHitV1{
    .{
        .item_id = 201,
        .corpus_ordinal = 1,
        .rank = 0,
        .score = 0,
    },
    .{
        .item_id = 202,
        .corpus_ordinal = 2,
        .rank = 1,
        .score = 0,
    },
};
pub const reference_corpus_embedding_bytes: usize =
    reference_corpus_components.len *
    embedding_result.embedding_component_bytes;
pub const reference_query_embedding_bytes: usize =
    reference_query_components.len *
    embedding_result.embedding_component_bytes;
pub const reference_packed_weight_bytes: usize =
    retrieval_result.retrieval_index_bytes +
    reference_corpus_embedding_bytes;
pub const reference_output_bytes: usize =
    reference_corpus_item_ids.len *
    retrieval_result.retrieval_hit_bytes;

pub const ReferenceFixtureV1 = struct {
    corpus_map_storage: [512]u8,
    corpus_map_len: usize,
    query_map_storage: [512]u8,
    query_map_len: usize,
    embedding_policy_storage: [embedding_result.embedding_policy_bytes]u8,
    retrieval_policy_storage: [retrieval_result.retrieval_policy_bytes]u8,
    visibility_storage: [256]u8,
    visibility_len: usize,
    index_storage: [retrieval_result.retrieval_index_bytes]u8,
    query_binding_storage: [retrieval_result.query_binding_bytes]u8,
    packed_weights: [reference_packed_weight_bytes]u8,
    query_embedding: [reference_query_embedding_bytes]u8,
    binding: RetrievalInputBindingV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,

    pub fn init() !ReferenceFixtureV1 {
        var corpus_map_storage: [512]u8 = undefined;
        const corpus_map_encoded = try tensor_result.encodeBatchMapV1(
            &reference_corpus_item_ids,
            &corpus_map_storage,
        );
        const corpus_map_len = corpus_map_encoded.len;
        const corpus_map = try tensor_result.decodeBatchMapV1(
            corpus_map_encoded,
        );
        var query_map_storage: [512]u8 = undefined;
        const query_map_encoded = try tensor_result.encodeBatchMapV1(
            &reference_query_item_ids,
            &query_map_storage,
        );
        const query_map_len = query_map_encoded.len;
        const query_map = try tensor_result.decodeBatchMapV1(
            query_map_encoded,
        );

        var embedding_policy_storage: [embedding_result.embedding_policy_bytes]u8 = undefined;
        const embedding_policy_encoded =
            try embedding_result.encodeEmbeddingPolicyV1(
                embedding_result.canonical_embedding_policy_v1,
                &embedding_policy_storage,
            );
        const embedding_policy =
            try embedding_result.decodeEmbeddingPolicyV1(
                embedding_policy_encoded,
            );
        var corpus_embedding_storage: [reference_corpus_embedding_bytes]u8 = undefined;
        const corpus_embedding_encoded =
            try embedding_result.encodeNormalizedEmbeddingV1(
                &reference_corpus_components,
                reference_corpus_item_ids.len,
                reference_dimensions,
                &corpus_embedding_storage,
            );
        const corpus_embedding =
            try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
                corpus_embedding_encoded,
                corpus_map.batch_map_sha256,
                embedding_policy.encoded,
                reference_corpus_item_ids.len,
                reference_dimensions,
            );
        var query_embedding: [reference_query_embedding_bytes]u8 =
            undefined;
        const query_embedding_encoded =
            try embedding_result.encodeNormalizedEmbeddingV1(
                &reference_query_components,
                1,
                reference_dimensions,
                &query_embedding,
            );
        const query_embedding_view =
            try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
                query_embedding_encoded,
                query_map.batch_map_sha256,
                embedding_policy.encoded,
                1,
                reference_dimensions,
            );

        var visibility_storage: [256]u8 = undefined;
        const visibility_encoded =
            try retrieval_result.encodeVisibilityMapV1(
                corpus_map.encoded,
                &reference_visibility_tenants,
                &visibility_storage,
            );
        const visibility_len = visibility_encoded.len;
        const visibility_view =
            try retrieval_result.decodeAndValidateVisibilityMapV1(
                visibility_encoded,
                corpus_map.encoded,
            );
        var retrieval_policy_storage: [retrieval_result.retrieval_policy_bytes]u8 = undefined;
        const retrieval_policy_encoded =
            try retrieval_result.encodeRetrievalPolicyV1(
                .{ .top_k = reference_top_k },
                &retrieval_policy_storage,
            );
        const retrieval_policy =
            try retrieval_result.decodeRetrievalPolicyV1(
                retrieval_policy_encoded,
            );
        var index_storage: [retrieval_result.retrieval_index_bytes]u8 = undefined;
        const index_encoded =
            try retrieval_result.encodeRetrievalIndexV1(
                .{
                    .generation = 1,
                    .corpus_count = reference_corpus_item_ids.len,
                    .dimensions = reference_dimensions,
                    .index_id_sha256 = model.sha256("reference fixed corpus index"),
                    .corpus_map_sha256 = corpus_map.batch_map_sha256,
                    .visibility_sha256 = visibility_view.visibility_sha256,
                    .embedding_policy_sha256 = embedding_policy.embedding_policy_sha256,
                    .corpus_embedding_sha256 = corpus_embedding.embedding_matrix_sha256,
                },
                &index_storage,
            );
        const index_view = try retrieval_result.decodeRetrievalIndexV1(
            index_encoded,
        );
        const query_object_sha256 =
            model.sha256("reference retrieval query object");
        const challenge_sha256 =
            model.sha256("reference retrieval challenge");
        var query_binding_storage: [retrieval_result.query_binding_bytes]u8 = undefined;
        const query_binding_encoded =
            try retrieval_result.encodeQueryBindingV1(
                .{
                    .query_tenant = 7,
                    .dimensions = reference_dimensions,
                    .query_object_sha256 = query_object_sha256,
                    .query_map_sha256 = query_map.batch_map_sha256,
                    .embedding_policy_sha256 = embedding_policy.embedding_policy_sha256,
                    .query_embedding_sha256 = query_embedding_view.embedding_matrix_sha256,
                    .index_descriptor_sha256 = index_view.index_descriptor_sha256,
                    .retrieval_policy_sha256 = retrieval_policy.retrieval_policy_sha256,
                    .challenge_sha256 = challenge_sha256,
                },
                &query_binding_storage,
            );
        const query_binding_view =
            try retrieval_result.decodeQueryBindingV1(
                query_binding_encoded,
            );

        var packed_weights: [reference_packed_weight_bytes]u8 =
            undefined;
        @memcpy(
            packed_weights[0..retrieval_result.retrieval_index_bytes],
            index_view.encoded,
        );
        @memcpy(
            packed_weights[retrieval_result.retrieval_index_bytes..],
            corpus_embedding.encoded,
        );
        const ownership_sha256 =
            model.sha256("reference retrieval ownership");
        var binding: RetrievalInputBindingV1 = .{
            .query_object_sha256 = query_object_sha256,
            .query_map_sha256 = query_map.batch_map_sha256,
            .embedding_policy_sha256 = embedding_policy.embedding_policy_sha256,
            .query_embedding_sha256 = query_embedding_view.embedding_matrix_sha256,
            .index_descriptor_sha256 = index_view.index_descriptor_sha256,
            .corpus_map_sha256 = corpus_map.batch_map_sha256,
            .corpus_embedding_sha256 = corpus_embedding.embedding_matrix_sha256,
            .retrieval_policy_sha256 = retrieval_policy.retrieval_policy_sha256,
            .visibility_sha256 = visibility_view.visibility_sha256,
            .query_binding_sha256 = query_binding_view.query_binding_sha256,
            .input_bundle_sha256 = [_]u8{0} ** @sizeOf(Digest),
            .ownership_sha256 = ownership_sha256,
            .challenge_sha256 = challenge_sha256,
        };
        binding.input_bundle_sha256 = inputBundleRootV1(binding);

        const manifest = try model.makeArtifactManifestV1(
            .retrieval,
            0x4452_4554_0000_0001,
            .embedding_i32,
            .retrieval_hits,
            .exact_integer,
            1,
            reference_dimensions,
            reference_output_bytes,
            embedding_result.embedding_component_bytes,
            1,
            1,
            &packed_weights,
            model.sha256(index_view.encoded),
            model.sha256("fixture-only generated data license"),
        );
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .retrieve,
            .{
                .request_epoch = 801,
                .generation = 1,
                .batch_items = 1,
                .publication_next_sequence = 0,
                .maximum_absolute_output = @intCast(embedding_result.q30_scale),
                .claim = .{
                    .capsule_bytes = packed_weights.len,
                    .activation_bytes = query_embedding.len,
                    .partial_bytes = reference_output_bytes,
                    .output_journal_bytes = reference_output_bytes,
                    .queue_slots = 1,
                },
                .media_object_sha256 = binding.query_object_sha256,
                .processor_state_sha256 = binding.query_map_sha256,
                .processor_bundle_sha256 = binding.embedding_policy_sha256,
                .cache_bundle_sha256 = binding.input_bundle_sha256,
                .cache_payload_sha256 = binding.query_embedding_sha256,
                .ownership_sha256 = binding.ownership_sha256,
                .challenge_sha256 = binding.challenge_sha256,
                .previous_plan_sha256 = model.sha256("reference retrieval genesis plan"),
                .input_schema_sha256 = binding.query_binding_sha256,
                .output_schema_sha256 = binding.retrieval_policy_sha256,
                .scratch_bytes = reference_output_bytes,
            },
        );
        return .{
            .corpus_map_storage = corpus_map_storage,
            .corpus_map_len = corpus_map_len,
            .query_map_storage = query_map_storage,
            .query_map_len = query_map_len,
            .embedding_policy_storage = embedding_policy_storage,
            .retrieval_policy_storage = retrieval_policy_storage,
            .visibility_storage = visibility_storage,
            .visibility_len = visibility_len,
            .index_storage = index_storage,
            .query_binding_storage = query_binding_storage,
            .packed_weights = packed_weights,
            .query_embedding = query_embedding,
            .binding = binding,
            .manifest = manifest,
            .plan = plan,
            .publication_state = try model.initializePublicationStateV1(
                plan.request_epoch,
                manifest.artifact_sha256,
            ),
        };
    }

    pub fn corpusMap(
        self: *const ReferenceFixtureV1,
    ) !tensor_result.BatchMapViewV1 {
        return tensor_result.decodeBatchMapV1(
            self.corpus_map_storage[0..self.corpus_map_len],
        );
    }

    pub fn queryMap(
        self: *const ReferenceFixtureV1,
    ) !tensor_result.BatchMapViewV1 {
        return tensor_result.decodeBatchMapV1(
            self.query_map_storage[0..self.query_map_len],
        );
    }

    pub fn embeddingPolicy(
        self: *const ReferenceFixtureV1,
    ) !embedding_result.EmbeddingPolicyViewV1 {
        return embedding_result.decodeEmbeddingPolicyV1(
            &self.embedding_policy_storage,
        );
    }

    pub fn retrievalPolicy(
        self: *const ReferenceFixtureV1,
    ) !retrieval_result.RetrievalPolicyViewV1 {
        return retrieval_result.decodeRetrievalPolicyV1(
            &self.retrieval_policy_storage,
        );
    }

    pub fn visibility(
        self: *const ReferenceFixtureV1,
    ) !retrieval_result.VisibilityMapViewV1 {
        return retrieval_result.decodeAndValidateVisibilityMapV1(
            self.visibility_storage[0..self.visibility_len],
            self.corpus_map_storage[0..self.corpus_map_len],
        );
    }

    pub fn index(
        self: *const ReferenceFixtureV1,
    ) !retrieval_result.RetrievalIndexViewV1 {
        return retrieval_result.decodeRetrievalIndexV1(
            &self.index_storage,
        );
    }

    pub fn queryBinding(
        self: *const ReferenceFixtureV1,
    ) !retrieval_result.QueryBindingViewV1 {
        return retrieval_result.decodeQueryBindingV1(
            &self.query_binding_storage,
        );
    }

    pub fn referenceContext(
        self: *const ReferenceFixtureV1,
    ) ReferenceContextV1 {
        return .{
            .corpus_map_encoded = self.corpus_map_storage[0..self.corpus_map_len],
            .query_map_encoded = self.query_map_storage[0..self.query_map_len],
            .embedding_policy_encoded = &self.embedding_policy_storage,
            .retrieval_policy_encoded = &self.retrieval_policy_storage,
            .visibility_encoded = self.visibility_storage[0..self.visibility_len],
            .query_binding_encoded = &self.query_binding_storage,
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

fn decodeReferenceResultV1(
    fixture: *const ReferenceFixtureV1,
    encoded: []const u8,
) !retrieval_result.RetrievalResultViewV1 {
    const corpus_map = try fixture.corpusMap();
    const query_map = try fixture.queryMap();
    const embedding_policy = try fixture.embeddingPolicy();
    const visibility = try fixture.visibility();
    const index = try fixture.index();
    const retrieval_policy = try fixture.retrievalPolicy();
    const query_binding = try fixture.queryBinding();
    const artifact = try splitPackedArtifactV1(
        fixture.plan,
        &fixture.packed_weights,
    );
    const corpus_embedding =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            artifact.corpus_embedding,
            corpus_map.batch_map_sha256,
            embedding_policy.encoded,
            reference_corpus_item_ids.len,
            reference_dimensions,
        );
    const query_embedding =
        try embedding_result.decodeAndValidateNormalizedEmbeddingV1(
            &fixture.query_embedding,
            query_map.batch_map_sha256,
            embedding_policy.encoded,
            1,
            reference_dimensions,
        );
    return retrieval_result.decodeRetrievalResultV1(
        encoded,
        corpus_map,
        visibility,
        embedding_policy,
        corpus_embedding,
        index,
        query_map,
        query_embedding,
        retrieval_policy,
        query_binding,
    );
}

fn expectReferenceHitsV1(
    fixture: *const ReferenceFixtureV1,
    encoded: []const u8,
) !void {
    const view = try decodeReferenceResultV1(fixture, encoded);
    try std.testing.expectEqual(
        reference_corpus_item_ids.len,
        view.corpus_count,
    );
    try std.testing.expectEqual(reference_top_k, view.hit_count);
    for (reference_expected_hits, 0..) |expected, index|
        try std.testing.expectEqual(expected, try view.hit(index));
}

fn substitutedExecuteV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    packed_weights: []const u8,
    query_embedding: []const u8,
    candidate: []u8,
) anyerror!void {
    try referenceExecuteV1(
        opaque_context,
        plan,
        packed_weights,
        query_embedding,
        candidate,
    );
    candidate[0] ^= 1;
}

test "retrieval validators bind packed index query and exact support" {
    const fixture = try ReferenceFixtureV1.init();
    try validateRetrievalManifestV1(fixture.manifest);
    try validateRetrievalPlanV1(fixture.manifest, fixture.plan);
    try validateRetrievalBindingsV1(
        fixture.manifest,
        fixture.plan,
        fixture.binding,
        try fixture.index(),
        try fixture.corpusMap(),
        try fixture.queryMap(),
        try fixture.embeddingPolicy(),
        try fixture.retrievalPolicy(),
        try fixture.visibility(),
        try fixture.queryBinding(),
        &fixture.packed_weights,
        &fixture.query_embedding,
    );

    var foreign_query = fixture.binding;
    foreign_query.query_embedding_sha256 =
        model.sha256("substituted query embedding");
    try std.testing.expectError(
        Error.InvalidRetrievalBinding,
        validateRetrievalBindingsV1(
            fixture.manifest,
            fixture.plan,
            foreign_query,
            try fixture.index(),
            try fixture.corpusMap(),
            try fixture.queryMap(),
            try fixture.embeddingPolicy(),
            try fixture.retrievalPolicy(),
            try fixture.visibility(),
            try fixture.queryBinding(),
            &fixture.packed_weights,
            &fixture.query_embedding,
        ),
    );

    var foreign_weights = fixture.packed_weights;
    foreign_weights[retrieval_result.retrieval_index_bytes] ^= 1;
    try std.testing.expectError(
        Error.InvalidRetrievalBinding,
        validateRetrievalBindingsV1(
            fixture.manifest,
            fixture.plan,
            fixture.binding,
            try fixture.index(),
            try fixture.corpusMap(),
            try fixture.queryMap(),
            try fixture.embeddingPolicy(),
            try fixture.retrievalPolicy(),
            try fixture.visibility(),
            try fixture.queryBinding(),
            &foreign_weights,
            &fixture.query_embedding,
        ),
    );
}

test "fixed corpus retrieval filters tenant and publishes tied top k" {
    var fixture = try ReferenceFixtureV1.init();
    const corpus_map = try fixture.corpusMap();
    const query_map = try fixture.queryMap();
    const embedding_policy = try fixture.embeddingPolicy();
    const retrieval_policy = try fixture.retrievalPolicy();
    const visibility = try fixture.visibility();
    const index = try fixture.index();
    const query_binding = try fixture.queryBinding();
    try std.testing.expect(!(try visibility.permits(0, 7)));
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
        index,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        query_binding,
        &fixture.packed_weights,
        &fixture.query_embedding,
        &candidate,
        &output,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try expectReferenceHitsV1(&fixture, &candidate);
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try expectReferenceHitsV1(&fixture, &output);
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

test "retrieval rejects aliased or substituted provisional output atomically" {
    var fixture = try ReferenceFixtureV1.init();
    const corpus_map = try fixture.corpusMap();
    const query_map = try fixture.queryMap();
    const embedding_policy = try fixture.embeddingPolicy();
    const retrieval_policy = try fixture.retrievalPolicy();
    const visibility = try fixture.visibility();
    const index = try fixture.index();
    const query_binding = try fixture.queryBinding();
    var context = fixture.referenceContext();
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x7301,
    );

    const reference_adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var alias_session: Session = .{};
    try alias_session.initV1(
        &bank,
        0x7302,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        reference_adapter,
    );
    var alias_output: [reference_output_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidRetrievalBinding,
        alias_session.prepareV1(
            fixture.binding,
            index,
            corpus_map,
            query_map,
            embedding_policy,
            retrieval_policy,
            visibility,
            query_binding,
            &fixture.packed_weights,
            &fixture.query_embedding,
            fixture.corpus_map_storage[0..reference_output_bytes],
            &alias_output,
        ),
    );
    try alias_session.closeAndRelease();

    var substituted_adapter = reference_adapter;
    substituted_adapter.execute_fn = substitutedExecuteV1;
    var substituted_session: Session = .{};
    try substituted_session.initV1(
        &bank,
        0x7303,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        substituted_adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output: [reference_output_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.RetrievalResultMismatch,
        substituted_session.prepareV1(
            fixture.binding,
            index,
            corpus_map,
            query_map,
            embedding_policy,
            retrieval_policy,
            visibility,
            query_binding,
            &fixture.packed_weights,
            &fixture.query_embedding,
            &candidate,
            &output,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    try substituted_session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "retrieval candidate drift aborts and an exact retry publishes" {
    var fixture = try ReferenceFixtureV1.init();
    const corpus_map = try fixture.corpusMap();
    const query_map = try fixture.queryMap();
    const embedding_policy = try fixture.embeddingPolicy();
    const retrieval_policy = try fixture.retrievalPolicy();
    const visibility = try fixture.visibility();
    const index = try fixture.index();
    const query_binding = try fixture.queryBinding();
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
    var session: Session = .{};
    try session.initV1(
        &bank,
        0x7402,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    var candidate: [reference_output_bytes]u8 = undefined;
    var output: [reference_output_bytes]u8 = undefined;
    _ = try session.prepareV1(
        fixture.binding,
        index,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        query_binding,
        &fixture.packed_weights,
        &fixture.query_embedding,
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
        0x7403,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        adapter,
    );
    _ = try retry.prepareV1(
        fixture.binding,
        index,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        query_binding,
        &fixture.packed_weights,
        &fixture.query_embedding,
        &candidate,
        &output,
    );
    _ = try retry.commitV1();
    try expectReferenceHitsV1(&fixture, &output);
    try retry.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "scheduled retrieval publishes at final service and retires" {
    var fixture = try ReferenceFixtureV1.init();
    const corpus_map = try fixture.corpusMap();
    const query_map = try fixture.queryMap();
    const embedding_policy = try fixture.embeddingPolicy();
    const retrieval_policy = try fixture.retrievalPolicy();
    const visibility = try fixture.visibility();
    const index = try fixture.index();
    const query_binding = try fixture.queryBinding();
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
            .challenge = model.sha256("scheduled retrieval challenge"),
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
    const permit = try scheduler.prepareService();
    var candidate: [reference_output_bytes]u8 = undefined;
    var output: [reference_output_bytes]u8 = undefined;
    const prepared = try session.prepareV1(
        fixture.binding,
        index,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        query_binding,
        &fixture.packed_weights,
        &fixture.query_embedding,
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
    try expectReferenceHitsV1(&fixture, &output);
    const retired = try session.retireScheduledV1();
    try std.testing.expectEqual(qos.EventKind.retire, retired.kind);
    _ = try scheduler.close();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "scheduled retrieval cancellation leaves zero ownership" {
    var fixture = try ReferenceFixtureV1.init();
    const corpus_map = try fixture.corpusMap();
    const query_map = try fixture.queryMap();
    const embedding_policy = try fixture.embeddingPolicy();
    const retrieval_policy = try fixture.retrievalPolicy();
    const visibility = try fixture.visibility();
    const index = try fixture.index();
    const query_binding = try fixture.queryBinding();
    var context = fixture.referenceContext();
    const adapter = try referenceAdapterV1(
        fixture.manifest,
        &context,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.init(
        &runtime.bank_slots,
        .{},
        0x7601,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = &runtime.lane_slots,
            .projection = &runtime.projection,
        },
        .{
            .scheduler_epoch = 0x7602,
            .challenge = model.sha256("cancel retrieval challenge"),
            .max_weight = 1,
            .max_projection_quanta = 8,
            .max_projection_operations = 64,
        },
    );
    const decision = try scheduler.admit(.{
        .tenant_key = 0x7603,
        .request_key = 0x7604,
        .request_generation = 1,
        .resource_owner_key = 0x7605,
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
        index,
        corpus_map,
        query_map,
        embedding_policy,
        retrieval_policy,
        visibility,
        query_binding,
        &fixture.packed_weights,
        &fixture.query_embedding,
        &candidate,
        &output,
    );
    try session.abortV1();
    try std.testing.expect(std.mem.allEqual(u8, &candidate, 0));
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const cancelled = try session.cancelScheduledV1();
    try std.testing.expectEqual(
        qos.EventKind.cancel,
        cancelled.kind,
    );
    _ = try scheduler.close();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}
