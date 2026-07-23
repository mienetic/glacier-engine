const std = @import("std");
const model = @import("model_contract.zig");
const stateful = @import("stateful_model_adapter.zig");
const audio = @import("audio_transcript_adapter.zig");
const resource_bank = @import("resource_bank.zig");

const Digest = [32]u8;

pub const reference_adapter_abi: u64 = 0x5354_5254_524e_0001;
pub const reference_state_bytes: usize = 32;
pub const reference_input_features: u64 = 4;
pub const reference_output_bytes: usize =
    audio.maximum_text_bytes;
pub const reference_weights = [_]u8{ 1, 2, 3, 4 };
pub const reference_first_features =
    [_]u8{ 7, 0, 0, 0, 1, 0, 0, 0 };
pub const reference_second_features =
    [_]u8{ 23, 0, 25, 0, 11, 0, 25, 0 };

pub const transcript_state_support =
    [_]model.SupportRecordV1{.{
        .family = .audio_understanding,
        .operation = .transcribe,
        .input_kind = .audio_feature_i16,
        .output_kind = .transcript,
        .numerical_policy = .exact_integer,
        .max_batch_items = 1,
        .max_input_features = reference_input_features,
        .max_output_dimensions = reference_output_bytes,
        .allowed_capabilities = model.no_capabilities,
    }};

pub const Error = model.Error || stateful.Error ||
    audio.Error || resource_bank.Error || error{
    InvalidTranscriptState,
    InvalidTranscriptBinding,
    CandidateInvalid,
};

pub const AdapterDescriptorV1 =
    stateful.AdapterDescriptorV1;
pub const AdapterV1 = stateful.AdapterV1;
pub const StatePublicationV1 =
    stateful.StatePublicationV1;
pub const Phase = stateful.Phase;

pub const ReferenceStateV1 = struct {
    segment_index: u64,
    next_sample: u64,
    sample_rate: u64,
    emitted_text_bytes: u64,
};

pub const ReferenceContextV1 = struct {
    overlap_plan: audio.OverlapPlanV1,
    text_bytes: u64,
};

pub const ReferenceFixtureV1 = struct {
    manifest: model.ArtifactManifestV1,
    model_publication: model.PublicationStateV1,
    state_publication: StatePublicationV1,
    state: ReferenceStateV1,
    state_wire: [reference_state_bytes]u8,
    plan: model.ExecutionPlanV1,
};

pub const Session = struct {
    inner: stateful.Session = .{},

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        model_publication: *model.PublicationStateV1,
        state_publication: *StatePublicationV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        adapter: AdapterV1,
        overlap_plan: audio.OverlapPlanV1,
    ) Error!void {
        try validateTranscriptAdapterV1(
            adapter,
            manifest,
            plan,
            state_publication.*,
            overlap_plan,
        );
        try self.inner.initV1(
            bank,
            owner_key,
            model_publication,
            state_publication,
            manifest,
            plan,
            adapter,
            &transcript_state_support,
        );
    }

    pub fn prepareV1(
        self: *Session,
        overlap_plan: audio.OverlapPlanV1,
        weights: []const u8,
        features: []const u8,
        current_state: []const u8,
        candidate_output: []u8,
        candidate_state: []u8,
        visible_output: []u8,
        visible_next_state: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateTranscriptBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            self.inner.state_publication.*,
            overlap_plan,
            features,
            current_state,
        );
        return self.inner.prepareV1(
            weights,
            features,
            current_state,
            candidate_output,
            candidate_state,
            visible_output,
            visible_next_state,
        );
    }

    pub fn commitV1(
        self: *Session,
    ) Error!model.ResultEnvelopeV1 {
        return self.inner.commitV1();
    }

    pub fn abortV1(self: *Session) Error!void {
        return self.inner.abortV1();
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        return self.inner.closeAndRelease();
    }
};

pub fn makeAdapterDescriptorV1(
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateTranscriptManifestV1(manifest);
    return stateful.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .transcribe,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn makeReferenceManifestV1(
    weights: []const u8,
) Error!model.ArtifactManifestV1 {
    if (weights.len != reference_weights.len)
        return Error.InvalidTranscriptBinding;
    return model.makeArtifactManifestV1(
        .audio_understanding,
        0x5354_4153_5200_0001,
        .audio_feature_i16,
        .transcript,
        .exact_integer,
        1,
        reference_input_features,
        reference_output_bytes,
        @sizeOf(i16),
        @sizeOf(u8),
        @sizeOf(u8),
        weights,
        model.sha256("stateful transcript fixture metadata"),
        model.sha256("fixture-only license"),
    );
}

pub fn initializeReferenceStateV1(
    first_overlap: audio.OverlapPlanV1,
) Error!ReferenceStateV1 {
    try audio.validateOverlapPlanV1(first_overlap);
    if (first_overlap.segment_index != 1 or
        first_overlap.generation != 1)
        return Error.InvalidTranscriptBinding;
    const state: ReferenceStateV1 = .{
        .segment_index = 0,
        .next_sample = first_overlap.publish_start_sample,
        .sample_rate = first_overlap.sample_rate,
        .emitted_text_bytes = 0,
    };
    try validateReferenceStateV1(state);
    return state;
}

pub fn makeReferenceFixtureV1(
    first_overlap: audio.OverlapPlanV1,
    total_segments: u64,
) Error!ReferenceFixtureV1 {
    if (total_segments < 2)
        return Error.InvalidTranscriptBinding;
    const manifest =
        try makeReferenceManifestV1(&reference_weights);
    const state = try initializeReferenceStateV1(
        first_overlap,
    );
    var state_wire: [reference_state_bytes]u8 =
        undefined;
    _ = try encodeReferenceStateV1(state, &state_wire);
    const state_publication =
        try stateful.initializeStatePublicationV1(
            first_overlap.request_epoch,
            total_segments,
            reference_state_bytes,
            manifest.artifact_sha256,
            model.sha256(&state_wire),
            first_overlap.challenge_sha256,
        );
    const model_publication =
        try model.initializePublicationStateV1(
            first_overlap.request_epoch,
            manifest.artifact_sha256,
        );
    return .{
        .manifest = manifest,
        .model_publication = model_publication,
        .state_publication = state_publication,
        .state = state,
        .state_wire = state_wire,
        .plan = try makeReferencePlanV1(
            manifest,
            model_publication,
            state_publication,
            first_overlap,
            model.sha256("stateful transcript genesis plan"),
        ),
    };
}

pub fn makeReferencePlanV1(
    manifest: model.ArtifactManifestV1,
    model_publication: model.PublicationStateV1,
    state_publication: StatePublicationV1,
    overlap_plan: audio.OverlapPlanV1,
    previous_plan_sha256: Digest,
) Error!model.ExecutionPlanV1 {
    try validateTranscriptManifestV1(manifest);
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    try audio.validateOverlapPlanV1(overlap_plan);
    const generation = std.math.add(
        u64,
        state_publication.current_step,
        1,
    ) catch return Error.InvalidTranscriptBinding;
    if (state_publication.current_step >=
        state_publication.total_steps or
        generation != overlap_plan.generation or
        state_publication.state_bytes !=
            reference_state_bytes or
        model_publication.request_epoch !=
            state_publication.request_epoch or
        model_publication.next_sequence !=
            state_publication.current_step or
        model_publication.visible_results !=
            state_publication.current_step or
        !std.mem.eql(
            u8,
            &model_publication.artifact_sha256,
            &manifest.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &model_publication.previous_result_sha256,
            &state_publication.previous_result_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state_publication.challenge_sha256,
            &overlap_plan.challenge_sha256,
        ) or
        isZero(previous_plan_sha256))
        return Error.InvalidTranscriptBinding;
    const publication_bytes = std.math.add(
        u64,
        reference_output_bytes,
        reference_state_bytes,
    ) catch return Error.InvalidTranscriptBinding;
    return model.makeExecutionPlanV1(
        manifest,
        .transcribe,
        .{
            .request_epoch = state_publication.request_epoch,
            .generation = generation,
            .batch_items = 1,
            .publication_next_sequence = model_publication.next_sequence,
            .maximum_absolute_output = 'z',
            .claim = .{
                .capsule_bytes = manifest.weight_bytes,
                .activation_bytes = reference_input_features *
                    @sizeOf(i16),
                .partial_bytes = reference_output_bytes,
                .output_journal_bytes = publication_bytes,
                .staging_bytes = reference_state_bytes,
                .queue_slots = 1,
            },
            .media_object_sha256 = overlap_plan.media_object_sha256,
            .processor_state_sha256 = state_publication.publication_sha256,
            .processor_bundle_sha256 = overlap_plan.processor_bundle_sha256,
            .cache_bundle_sha256 = overlap_plan.cache_bundle_sha256,
            .cache_payload_sha256 = state_publication.current_state_sha256,
            .ownership_sha256 = overlap_plan.ownership_sha256,
            .challenge_sha256 = overlap_plan.challenge_sha256,
            .previous_plan_sha256 = previous_plan_sha256,
            .input_schema_sha256 = overlap_plan.overlap_sha256,
            .output_schema_sha256 = audio.transcriptSchemaRootV1(),
            .scratch_bytes = reference_output_bytes,
        },
    );
}

pub fn referenceAdapterV1(
    manifest: model.ArtifactManifestV1,
    context: *ReferenceContextV1,
) Error!AdapterV1 {
    try validateReferenceContextV1(context.*);
    return .{
        .context = @ptrCast(context),
        .descriptor = try makeAdapterDescriptorV1(
            manifest,
            model.sha256(
                "reference exact stateful transcript v1",
            ),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
}

pub fn validateTranscriptAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
    overlap_plan: audio.OverlapPlanV1,
) Error!void {
    try validateTranscriptManifestV1(manifest);
    try stateful.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &transcript_state_support,
    );
    try validateTranscriptPlanV1(
        manifest,
        plan,
        state_publication,
        overlap_plan,
    );
}

pub fn validateTranscriptManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    try model.validateArtifactManifestV1(manifest);
    if (manifest.family != .audio_understanding or
        manifest.input_kind != .audio_feature_i16 or
        manifest.output_kind != .transcript or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items != 1 or
        manifest.input_features !=
            reference_input_features or
        manifest.output_dimensions !=
            reference_output_bytes or
        manifest.input_element_bytes != @sizeOf(i16) or
        manifest.output_element_bytes != @sizeOf(u8) or
        manifest.weight_elements != reference_weights.len or
        manifest.weight_element_bytes != @sizeOf(u8) or
        manifest.weight_bytes != reference_weights.len)
        return Error.InvalidTranscriptBinding;
}

pub fn validateTranscriptPlanV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
    overlap_plan: audio.OverlapPlanV1,
) Error!void {
    try model.validateExecutionPlanV1(plan);
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    try audio.validateOverlapPlanV1(overlap_plan);
    const expected_generation = std.math.add(
        u64,
        state_publication.current_step,
        1,
    ) catch return Error.InvalidTranscriptBinding;
    if (plan.family != .audio_understanding or
        plan.operation != .transcribe or
        plan.input_kind != .audio_feature_i16 or
        plan.output_kind != .transcript or
        plan.numerical_policy != .exact_integer or
        plan.request_epoch != overlap_plan.request_epoch or
        plan.generation != overlap_plan.generation or
        plan.generation != expected_generation or
        plan.batch_items != 1 or
        plan.input_features !=
            reference_input_features or
        plan.output_dimensions !=
            reference_output_bytes or
        plan.input_bytes !=
            reference_input_features * @sizeOf(i16) or
        plan.output_bytes != reference_output_bytes or
        plan.scratch_bytes != reference_output_bytes or
        plan.publication_next_sequence !=
            state_publication.current_step or
        plan.maximum_absolute_output != 'z' or
        !std.mem.eql(
            u8,
            &plan.artifact_sha256,
            &manifest.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.media_object_sha256,
            &overlap_plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.processor_state_sha256,
            &state_publication.publication_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.processor_bundle_sha256,
            &overlap_plan.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.cache_bundle_sha256,
            &overlap_plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.cache_payload_sha256,
            &state_publication.current_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.ownership_sha256,
            &overlap_plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.challenge_sha256,
            &overlap_plan.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.input_schema_sha256,
            &overlap_plan.overlap_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.output_schema_sha256,
            &audio.transcriptSchemaRootV1(),
        ))
        return Error.InvalidTranscriptBinding;
}

pub fn validateTranscriptBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
    overlap_plan: audio.OverlapPlanV1,
    features: []const u8,
    current_state_wire: []const u8,
) Error!void {
    try validateTranscriptManifestV1(manifest);
    try validateTranscriptPlanV1(
        manifest,
        plan,
        state_publication,
        overlap_plan,
    );
    if (features.len != plan.input_bytes or
        current_state_wire.len != reference_state_bytes or
        !std.mem.eql(
            u8,
            &model.sha256(current_state_wire),
            &state_publication.current_state_sha256,
        ))
        return Error.InvalidTranscriptBinding;
    const current = try decodeReferenceStateV1(
        current_state_wire,
    );
    const expected_segment = std.math.add(
        u64,
        current.segment_index,
        1,
    ) catch return Error.InvalidTranscriptBinding;
    if (expected_segment != overlap_plan.segment_index or
        current.next_sample !=
            overlap_plan.publish_start_sample or
        current.sample_rate != overlap_plan.sample_rate)
        return Error.InvalidTranscriptBinding;
}

pub fn encodeReferenceStateV1(
    state: ReferenceStateV1,
    output: *[reference_state_bytes]u8,
) Error![]const u8 {
    try validateReferenceStateV1(state);
    writeU64(output, 0, state.segment_index);
    writeU64(output, 8, state.next_sample);
    writeU64(output, 16, state.sample_rate);
    writeU64(output, 24, state.emitted_text_bytes);
    return output;
}

pub fn decodeReferenceStateV1(
    encoded: []const u8,
) Error!ReferenceStateV1 {
    if (encoded.len != reference_state_bytes)
        return Error.InvalidTranscriptState;
    const state: ReferenceStateV1 = .{
        .segment_index = readU64(encoded, 0),
        .next_sample = readU64(encoded, 8),
        .sample_rate = readU64(encoded, 16),
        .emitted_text_bytes = readU64(encoded, 24),
    };
    try validateReferenceStateV1(state);
    var canonical: [reference_state_bytes]u8 =
        undefined;
    _ = try encodeReferenceStateV1(state, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidTranscriptState;
    return state;
}

pub fn validateReferenceStateV1(
    state: ReferenceStateV1,
) Error!void {
    if (state.next_sample == 0 or
        state.sample_rate == 0)
        return Error.InvalidTranscriptState;
}

pub fn validateReferenceContextV1(
    context: ReferenceContextV1,
) Error!void {
    try audio.validateOverlapPlanV1(
        context.overlap_plan,
    );
    if (context.text_bytes == 0 or
        context.text_bytes >
            reference_input_features or
        context.text_bytes > reference_output_bytes)
        return Error.InvalidTranscriptBinding;
}

pub fn referenceExecuteV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    features: []const u8,
    current_state_wire: []const u8,
    candidate_output: []u8,
    candidate_state_wire: []u8,
) anyerror!void {
    const context: *ReferenceContextV1 =
        @ptrCast(@alignCast(opaque_context));
    try validateReferenceContextV1(context.*);
    if (weights.len != reference_weights.len or
        features.len != plan.input_bytes or
        current_state_wire.len != reference_state_bytes or
        candidate_output.len != reference_output_bytes or
        candidate_state_wire.len != reference_state_bytes)
        return Error.InvalidTranscriptBinding;
    const current = try decodeReferenceStateV1(
        current_state_wire,
    );
    const expected_segment = std.math.add(
        u64,
        current.segment_index,
        1,
    ) catch return Error.CandidateInvalid;
    if (expected_segment !=
        context.overlap_plan.segment_index or
        current.next_sample !=
            context.overlap_plan.publish_start_sample or
        current.sample_rate !=
            context.overlap_plan.sample_rate)
        return Error.InvalidTranscriptBinding;
    @memset(candidate_output, 0);
    const text_bytes: usize = @intCast(
        context.text_bytes,
    );
    for (0..text_bytes) |index| {
        const feature_index =
            index % @as(usize, @intCast(
                reference_input_features,
            ));
        const feature = std.mem.readInt(
            u16,
            features[feature_index * @sizeOf(i16) .. (feature_index + 1) *
                @sizeOf(i16)][0..@sizeOf(i16)],
            .little,
        );
        const sum = std.math.add(
            u64,
            feature,
            weights[index % weights.len],
        ) catch return Error.CandidateInvalid;
        const with_history = std.math.add(
            u64,
            sum,
            current.emitted_text_bytes,
        ) catch return Error.CandidateInvalid;
        candidate_output[index] =
            @as(u8, @intCast(with_history % 26)) + 'a';
    }
    const emitted = std.math.add(
        u64,
        current.emitted_text_bytes,
        context.text_bytes,
    ) catch return Error.CandidateInvalid;
    const next: ReferenceStateV1 = .{
        .segment_index = context.overlap_plan.segment_index,
        .next_sample = context.overlap_plan.publish_end_sample,
        .sample_rate = context.overlap_plan.sample_rate,
        .emitted_text_bytes = emitted,
    };
    var encoded: [reference_state_bytes]u8 =
        undefined;
    _ = try encodeReferenceStateV1(next, &encoded);
    @memcpy(candidate_state_wire, &encoded);
}

pub fn validateCandidateV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    current_state_wire: []const u8,
    candidate_output: []const u8,
    candidate_state_wire: []const u8,
) anyerror!void {
    var expected_output: [reference_output_bytes]u8 = undefined;
    var expected_state: [reference_state_bytes]u8 = undefined;
    referenceExecuteV1(
        opaque_context,
        plan,
        &reference_weights,
        switch (plan.generation) {
            1 => &reference_first_features,
            2 => &reference_second_features,
            else => return Error.CandidateInvalid,
        },
        current_state_wire,
        &expected_output,
        &expected_state,
    ) catch return Error.CandidateInvalid;
    if (!std.mem.eql(
        u8,
        candidate_output,
        &expected_output,
    ) or
        !std.mem.eql(
            u8,
            candidate_state_wire,
            &expected_state,
        ))
        return Error.CandidateInvalid;
}

fn testOverlap(
    generation: u64,
    segment_index: u64,
    source_start: u64,
    publish_start: u64,
    publish_end: u64,
    previous_transcript: Digest,
) !audio.OverlapPlanV1 {
    var overlap: audio.OverlapPlanV1 = .{
        .request_epoch = 431,
        .generation = generation,
        .segment_index = segment_index,
        .source_start_sample = source_start,
        .source_end_sample = publish_end,
        .context_start_sample = source_start,
        .context_end_sample = publish_start,
        .publish_start_sample = publish_start,
        .publish_end_sample = publish_end,
        .sample_rate = 1_000,
        .window_samples = publish_end - source_start,
        .hop_samples = publish_end - publish_start,
        .feature_frames = 1,
        .feature_bins = reference_input_features,
        .feature_bytes = reference_first_features.len,
        .media_object_sha256 = model.sha256("stateful transcript audio"),
        .processor_state_sha256 = model.sha256("stateful transcript processor"),
        .processor_bundle_sha256 = model.sha256("stateful transcript processor bundle"),
        .cache_bundle_sha256 = model.sha256("stateful transcript cache bundle"),
        .cache_payload_sha256 = model.sha256("stateful transcript feature cache"),
        .ownership_sha256 = model.sha256("stateful transcript ownership"),
        .challenge_sha256 = model.sha256("stateful transcript challenge"),
        .previous_transcript_sha256 = previous_transcript,
        .overlap_sha256 = [_]u8{0} ** 32,
    };
    overlap.overlap_sha256 =
        audio.overlapPlanRootV1(overlap);
    try audio.validateOverlapPlanV1(overlap);
    return overlap;
}

const TestRuntime = struct {
    slots: [4]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 4,
    roots: [4]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 4,
    nodes: [8]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 8,
};

test "stateful transcript emits exact text and advances sample state" {
    const genesis = model.sha256(
        "stateful transcript genesis",
    );
    const first_overlap = try testOverlap(
        1,
        1,
        0,
        2,
        10,
        genesis,
    );
    var fixture = try makeReferenceFixtureV1(
        first_overlap,
        2,
    );
    var runtime: TestRuntime = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &runtime.slots,
        &runtime.roots,
        &runtime.nodes,
        .{},
        91_001,
    );
    var first_context: ReferenceContextV1 = .{
        .overlap_plan = first_overlap,
        .text_bytes = 3,
    };
    const first_adapter = try referenceAdapterV1(
        fixture.manifest,
        &first_context,
    );
    var first_session: Session = .{};
    try first_session.initV1(
        &bank,
        91_101,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        first_adapter,
        first_overlap,
    );
    var candidate_output: [reference_output_bytes]u8 = undefined;
    var candidate_state: [reference_state_bytes]u8 = undefined;
    var visible_output =
        [_]u8{0} ** reference_output_bytes;
    var visible_state =
        [_]u8{0} ** reference_state_bytes;
    _ = try first_session.prepareV1(
        first_overlap,
        &reference_weights,
        &reference_first_features,
        &fixture.state_wire,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const first_result =
        try first_session.commitV1();
    try std.testing.expectEqualStrings(
        "ice",
        visible_output[0..3],
    );
    const first_state =
        try decodeReferenceStateV1(&visible_state);
    try std.testing.expectEqual(@as(u64, 1), first_state.segment_index);
    try std.testing.expectEqual(@as(u64, 10), first_state.next_sample);
    const first_transcript =
        try audio.makeTranscriptSegmentV1(
            first_overlap,
            visible_output[0..3],
        );
    const second_overlap = try testOverlap(
        2,
        2,
        8,
        10,
        18,
        first_transcript.transcript_sha256,
    );
    const second_plan = try makeReferencePlanV1(
        fixture.manifest,
        fixture.model_publication,
        fixture.state_publication,
        second_overlap,
        first_result.plan_sha256,
    );
    var second_context: ReferenceContextV1 = .{
        .overlap_plan = second_overlap,
        .text_bytes = 4,
    };
    const second_adapter = try referenceAdapterV1(
        fixture.manifest,
        &second_context,
    );
    var second_session: Session = .{};
    try second_session.initV1(
        &bank,
        91_102,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        second_plan,
        second_adapter,
        second_overlap,
    );
    var second_candidate_output: [reference_output_bytes]u8 = undefined;
    var second_candidate_state: [reference_state_bytes]u8 = undefined;
    var second_visible_output =
        [_]u8{0} ** reference_output_bytes;
    var second_visible_state =
        [_]u8{0} ** reference_state_bytes;
    _ = try second_session.prepareV1(
        second_overlap,
        &reference_weights,
        &reference_second_features,
        &visible_state,
        &second_candidate_output,
        &second_candidate_state,
        &second_visible_output,
        &second_visible_state,
    );
    _ = try second_session.commitV1();
    try std.testing.expectEqualStrings(
        "berg",
        second_visible_output[0..4],
    );
    const second_state =
        try decodeReferenceStateV1(
            &second_visible_state,
        );
    try std.testing.expectEqual(@as(u64, 2), second_state.segment_index);
    try std.testing.expectEqual(@as(u64, 18), second_state.next_sample);
    const second_transcript =
        try audio.makeTranscriptSegmentV1(
            second_overlap,
            second_visible_output[0..4],
        );
    try audio.validateTranscriptPredecessorV1(
        second_overlap,
        first_transcript,
    );
    try std.testing.expectEqual(
        first_transcript.transcript_sha256,
        second_transcript.previous_transcript_sha256,
    );
    try first_session.closeAndRelease();
    try second_session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "stateful transcript rejects sample discontinuity" {
    const first_overlap = try testOverlap(
        1,
        1,
        0,
        2,
        10,
        model.sha256("stateful transcript genesis"),
    );
    const fixture = try makeReferenceFixtureV1(
        first_overlap,
        2,
    );
    var discontinuous = first_overlap;
    discontinuous.publish_start_sample = 3;
    discontinuous.context_end_sample = 3;
    discontinuous.hop_samples = 7;
    discontinuous.overlap_sha256 =
        audio.overlapPlanRootV1(discontinuous);
    try audio.validateOverlapPlanV1(discontinuous);
    try std.testing.expectError(
        Error.InvalidTranscriptBinding,
        validateTranscriptBindingsV1(
            fixture.manifest,
            fixture.plan,
            fixture.state_publication,
            discontinuous,
            &reference_first_features,
            &fixture.state_wire,
        ),
    );
}

fn writeU64(
    output: []u8,
    offset: usize,
    value: u64,
) void {
    std.mem.writeInt(
        u64,
        output[offset .. offset + @sizeOf(u64)][0..@sizeOf(u64)],
        value,
        .little,
    );
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + @sizeOf(u64)][0..@sizeOf(u64)],
        .little,
    );
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}
