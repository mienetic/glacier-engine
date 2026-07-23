const std = @import("std");
const media = @import("media_contract.zig");
const model = @import("model_contract.zig");
const stateful = @import("stateful_model_adapter.zig");
const video = @import("video_segment_adapter.zig");
const resource_bank = @import("resource_bank.zig");

const Digest = [32]u8;

pub const frame_capacity: usize = 4;
pub const frame_window_abi: u64 = 0x4756_4652_4d00_0001;
pub const frame_window_bytes: usize = 576;
const frame_window_body_bytes = frame_window_bytes - 32;
const frame_window_magic =
    [_]u8{ 'G', 'V', 'F', 'R', 'M', '1', 0, 0 };
const frame_window_domain =
    "glacier-video-vfr-frame-window-v1\x00";
const timestamp_payload_domain =
    "glacier-video-vfr-timestamp-payload-v1\x00";
const allowed_flags: u64 = 0;

pub const reference_adapter_abi: u64 =
    0x5354_5656_4652_0001;
pub const reference_state_bytes: usize = 48;
pub const reference_input_features: u64 = frame_capacity;
pub const reference_output_bytes: usize =
    video.video_segment_bytes;
pub const reference_weights = [_]u8{ 1, 2, 3, 4 };
pub const reference_first_features =
    [_]u8{ 3, 1, 0, 0 };
pub const reference_second_features =
    [_]u8{ 3, 2, 0, 0 };

pub const video_state_support =
    [_]model.SupportRecordV1{.{
        .family = .video_understanding,
        .operation = .segment,
        .input_kind = .video_feature_u8,
        .output_kind = .video_segment,
        .numerical_policy = .exact_integer,
        .max_batch_items = 1,
        .max_input_features = reference_input_features,
        .max_output_dimensions = reference_output_bytes,
        .allowed_capabilities = model.no_capabilities,
    }};

pub const Error = media.Error || model.Error ||
    stateful.Error || video.Error || resource_bank.Error ||
    error{
        InvalidFrameWindow,
        InvalidFramePredecessor,
        InvalidVideoState,
        InvalidVideoBinding,
        CandidateInvalid,
    };

pub const AdapterDescriptorV1 =
    stateful.AdapterDescriptorV1;
pub const AdapterV1 = stateful.AdapterV1;
pub const StatePublicationV1 =
    stateful.StatePublicationV1;
pub const Phase = stateful.Phase;

pub const FrameWindowV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    first_frame_ordinal: u64,
    frame_count: u64,
    target_numerator: u64,
    target_denominator: u64,
    previous_end_tick: u64,
    start_tick: u64,
    end_tick: u64,
    discontinuity_before_ticks: u64,
    duration_transition_count: u64,
    keyframe_count: u64,
    frame_ordinals: [frame_capacity]u64,
    presentation_ticks: [frame_capacity]u64,
    duration_ticks: [frame_capacity]u64,
    keyframe_flags: [frame_capacity]u64,
    media_object_sha256: Digest,
    processor_bundle_sha256: Digest,
    cache_bundle_sha256: Digest,
    ownership_sha256: Digest,
    frame_payload_sha256: Digest,
    timestamp_payload_sha256: Digest,
    previous_window_sha256: Digest,
    challenge_sha256: Digest,
    window_sha256: Digest,
};

pub const ReferenceStateV1 = struct {
    segment_index: u64,
    next_frame_ordinal: u64,
    last_end_tick: u64,
    target_numerator: u64,
    target_denominator: u64,
    emitted_segments: u64,
};

pub const ReferenceContextV1 = struct {
    frame_window: FrameWindowV1,
    previous_segment_sha256: Digest,
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
        frame_window: FrameWindowV1,
    ) Error!void {
        try validateVideoAdapterV1(
            adapter,
            manifest,
            plan,
            state_publication.*,
            frame_window,
        );
        try self.inner.initV1(
            bank,
            owner_key,
            model_publication,
            state_publication,
            manifest,
            plan,
            adapter,
            &video_state_support,
        );
    }

    pub fn prepareV1(
        self: *Session,
        frame_window: FrameWindowV1,
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
        try validateVideoBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            self.inner.state_publication.*,
            frame_window,
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

pub fn makeFrameWindowV1(
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    target_base: media.TimeBaseV1,
    previous_end_tick: u64,
    frame_ordinals: []const u64,
    presentation_ticks: []const u64,
    duration_ticks: []const u64,
    keyframe_flags: []const u64,
    media_object_sha256: Digest,
    processor_bundle_sha256: Digest,
    cache_bundle_sha256: Digest,
    ownership_sha256: Digest,
    frame_payload_sha256: Digest,
    previous_window_sha256: Digest,
    challenge_sha256: Digest,
) Error!FrameWindowV1 {
    if (frame_ordinals.len == 0 or
        frame_ordinals.len > frame_capacity or
        presentation_ticks.len != frame_ordinals.len or
        duration_ticks.len != frame_ordinals.len or
        keyframe_flags.len != frame_ordinals.len)
        return Error.InvalidFrameWindow;
    const last_index = frame_ordinals.len - 1;
    const end_tick = std.math.add(
        u64,
        presentation_ticks[last_index],
        duration_ticks[last_index],
    ) catch return Error.InvalidFrameWindow;
    const discontinuity = std.math.sub(
        u64,
        presentation_ticks[0],
        previous_end_tick,
    ) catch return Error.InvalidFrameWindow;
    var duration_transitions: u64 = 0;
    var keyframes: u64 = 0;
    for (duration_ticks, 0..) |duration, index| {
        if (index > 0 and
            duration != duration_ticks[index - 1])
            duration_transitions += 1;
        if (keyframe_flags[index] == 1)
            keyframes += 1;
    }
    var window: FrameWindowV1 = .{
        .request_epoch = request_epoch,
        .generation = generation,
        .segment_index = segment_index,
        .first_frame_ordinal = frame_ordinals[0],
        .frame_count = frame_ordinals.len,
        .target_numerator = target_base.numerator,
        .target_denominator = target_base.denominator,
        .previous_end_tick = previous_end_tick,
        .start_tick = presentation_ticks[0],
        .end_tick = end_tick,
        .discontinuity_before_ticks = discontinuity,
        .duration_transition_count = duration_transitions,
        .keyframe_count = keyframes,
        .frame_ordinals = [_]u64{0} ** frame_capacity,
        .presentation_ticks = [_]u64{0} ** frame_capacity,
        .duration_ticks = [_]u64{0} ** frame_capacity,
        .keyframe_flags = [_]u64{0} ** frame_capacity,
        .media_object_sha256 = media_object_sha256,
        .processor_bundle_sha256 = processor_bundle_sha256,
        .cache_bundle_sha256 = cache_bundle_sha256,
        .ownership_sha256 = ownership_sha256,
        .frame_payload_sha256 = frame_payload_sha256,
        .timestamp_payload_sha256 = [_]u8{0} ** 32,
        .previous_window_sha256 = previous_window_sha256,
        .challenge_sha256 = challenge_sha256,
        .window_sha256 = [_]u8{0} ** 32,
    };
    @memcpy(
        window.frame_ordinals[0..frame_ordinals.len],
        frame_ordinals,
    );
    @memcpy(
        window.presentation_ticks[0..presentation_ticks.len],
        presentation_ticks,
    );
    @memcpy(
        window.duration_ticks[0..duration_ticks.len],
        duration_ticks,
    );
    @memcpy(
        window.keyframe_flags[0..keyframe_flags.len],
        keyframe_flags,
    );
    window.timestamp_payload_sha256 =
        timestampPayloadRootV1(window);
    window.window_sha256 = frameWindowRootV1(window);
    try validateFrameWindowV1(window);
    return window;
}

pub fn validateFrameWindowV1(
    window: FrameWindowV1,
) Error!void {
    media.validateTimeBaseV1(.{
        .numerator = window.target_numerator,
        .denominator = window.target_denominator,
    }) catch return Error.InvalidFrameWindow;
    if (window.request_epoch == 0 or
        window.generation == 0 or
        window.segment_index == 0 or
        window.frame_count == 0 or
        window.frame_count > frame_capacity or
        window.first_frame_ordinal !=
            window.frame_ordinals[0] or
        window.start_tick !=
            window.presentation_ticks[0] or
        window.start_tick < window.previous_end_tick or
        window.discontinuity_before_ticks !=
            window.start_tick - window.previous_end_tick or
        window.start_tick >= window.end_tick or
        isZero(window.media_object_sha256) or
        isZero(window.processor_bundle_sha256) or
        isZero(window.cache_bundle_sha256) or
        isZero(window.ownership_sha256) or
        isZero(window.frame_payload_sha256) or
        isZero(window.timestamp_payload_sha256) or
        isZero(window.previous_window_sha256) or
        isZero(window.challenge_sha256))
        return Error.InvalidFrameWindow;
    const count: usize = @intCast(window.frame_count);
    var duration_transitions: u64 = 0;
    var keyframes: u64 = 0;
    for (0..count) |index| {
        if (window.duration_ticks[index] == 0 or
            window.keyframe_flags[index] > 1)
            return Error.InvalidFrameWindow;
        if (window.keyframe_flags[index] == 1)
            keyframes += 1;
        if (index > 0) {
            const expected_ordinal = std.math.add(
                u64,
                window.frame_ordinals[index - 1],
                1,
            ) catch return Error.InvalidFrameWindow;
            const expected_tick = std.math.add(
                u64,
                window.presentation_ticks[index - 1],
                window.duration_ticks[index - 1],
            ) catch return Error.InvalidFrameWindow;
            if (window.frame_ordinals[index] !=
                expected_ordinal or
                window.presentation_ticks[index] !=
                    expected_tick)
                return Error.InvalidFrameWindow;
            if (window.duration_ticks[index] !=
                window.duration_ticks[index - 1])
                duration_transitions += 1;
        }
    }
    const expected_end = std.math.add(
        u64,
        window.presentation_ticks[count - 1],
        window.duration_ticks[count - 1],
    ) catch return Error.InvalidFrameWindow;
    if (window.end_tick != expected_end or
        window.duration_transition_count !=
            duration_transitions or
        window.keyframe_count != keyframes or
        keyframes == 0)
        return Error.InvalidFrameWindow;
    for (count..frame_capacity) |index| {
        if (window.frame_ordinals[index] != 0 or
            window.presentation_ticks[index] != 0 or
            window.duration_ticks[index] != 0 or
            window.keyframe_flags[index] != 0)
            return Error.InvalidFrameWindow;
    }
    if (!std.mem.eql(
        u8,
        &window.timestamp_payload_sha256,
        &timestampPayloadRootV1(window),
    ) or
        !std.mem.eql(
            u8,
            &window.window_sha256,
            &frameWindowRootV1(window),
        ))
        return Error.InvalidFrameWindow;
}

pub fn validateFramePredecessorV1(
    previous: FrameWindowV1,
    next: FrameWindowV1,
) Error!void {
    try validateFrameWindowV1(previous);
    try validateFrameWindowV1(next);
    const expected_generation = std.math.add(
        u64,
        previous.generation,
        1,
    ) catch return Error.InvalidFramePredecessor;
    const expected_segment = std.math.add(
        u64,
        previous.segment_index,
        1,
    ) catch return Error.InvalidFramePredecessor;
    const expected_frame = std.math.add(
        u64,
        previous.first_frame_ordinal,
        previous.frame_count,
    ) catch return Error.InvalidFramePredecessor;
    if (next.request_epoch != previous.request_epoch or
        next.generation != expected_generation or
        next.segment_index != expected_segment or
        next.first_frame_ordinal != expected_frame or
        next.previous_end_tick != previous.end_tick or
        next.target_numerator != previous.target_numerator or
        next.target_denominator !=
            previous.target_denominator or
        !std.mem.eql(
            u8,
            &next.media_object_sha256,
            &previous.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &next.processor_bundle_sha256,
            &previous.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &next.cache_bundle_sha256,
            &previous.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &next.ownership_sha256,
            &previous.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &next.previous_window_sha256,
            &previous.window_sha256,
        ) or
        !std.mem.eql(
            u8,
            &next.challenge_sha256,
            &previous.challenge_sha256,
        ))
        return Error.InvalidFramePredecessor;
}

pub fn encodeFrameWindowV1(
    window: FrameWindowV1,
    output: *[frame_window_bytes]u8,
) Error![]const u8 {
    try validateFrameWindowV1(window);
    writeFrameWindowBodyV1(
        window,
        output[0..frame_window_body_bytes],
    );
    @memcpy(
        output[frame_window_body_bytes..],
        &window.window_sha256,
    );
    return output;
}

pub fn decodeFrameWindowV1(
    encoded: []const u8,
) Error!FrameWindowV1 {
    if (encoded.len != frame_window_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &frame_window_magic,
        ) or
        readU64(encoded, 8) != frame_window_abi or
        readU64(encoded, 16) != frame_window_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[136..160], 0))
        return Error.InvalidFrameWindow;
    const window: FrameWindowV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .segment_index = readU64(encoded, 48),
        .first_frame_ordinal = readU64(encoded, 56),
        .frame_count = readU64(encoded, 64),
        .target_numerator = readU64(encoded, 72),
        .target_denominator = readU64(encoded, 80),
        .previous_end_tick = readU64(encoded, 88),
        .start_tick = readU64(encoded, 96),
        .end_tick = readU64(encoded, 104),
        .discontinuity_before_ticks = readU64(encoded, 112),
        .duration_transition_count = readU64(encoded, 120),
        .keyframe_count = readU64(encoded, 128),
        .frame_ordinals = readU64Array(
            encoded[160..192],
        ),
        .presentation_ticks = readU64Array(
            encoded[192..224],
        ),
        .duration_ticks = readU64Array(
            encoded[224..256],
        ),
        .keyframe_flags = readU64Array(
            encoded[256..288],
        ),
        .media_object_sha256 = encoded[288..320].*,
        .processor_bundle_sha256 = encoded[320..352].*,
        .cache_bundle_sha256 = encoded[352..384].*,
        .ownership_sha256 = encoded[384..416].*,
        .frame_payload_sha256 = encoded[416..448].*,
        .timestamp_payload_sha256 = encoded[448..480].*,
        .previous_window_sha256 = encoded[480..512].*,
        .challenge_sha256 = encoded[512..544].*,
        .window_sha256 = encoded[frame_window_body_bytes..frame_window_bytes].*,
    };
    try validateFrameWindowV1(window);
    var canonical: [frame_window_bytes]u8 = undefined;
    _ = try encodeFrameWindowV1(window, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidFrameWindow;
    return window;
}

pub fn frameWindowRootV1(
    window: FrameWindowV1,
) Digest {
    var body: [frame_window_body_bytes]u8 =
        undefined;
    writeFrameWindowBodyV1(window, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(frame_window_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn timestampPayloadRootV1(
    window: FrameWindowV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(timestamp_payload_domain);
    hashU64(&hash, window.request_epoch);
    hashU64(&hash, window.generation);
    hashU64(&hash, window.frame_count);
    hashU64(&hash, window.target_numerator);
    hashU64(&hash, window.target_denominator);
    const count: usize = @intCast(window.frame_count);
    for (0..count) |index| {
        hashU64(&hash, window.frame_ordinals[index]);
        hashU64(&hash, window.presentation_ticks[index]);
        hashU64(&hash, window.duration_ticks[index]);
        hashU64(&hash, window.keyframe_flags[index]);
    }
    return hash.finalResult();
}

pub fn makeAdapterDescriptorV1(
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateVideoManifestV1(manifest);
    return stateful.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .segment,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn makeReferenceManifestV1(
    weights: []const u8,
) Error!model.ArtifactManifestV1 {
    if (weights.len != reference_weights.len)
        return Error.InvalidVideoBinding;
    return model.makeArtifactManifestV1(
        .video_understanding,
        0x5354_5653_4700_0001,
        .video_feature_u8,
        .video_segment,
        .exact_integer,
        1,
        reference_input_features,
        reference_output_bytes,
        @sizeOf(u8),
        @sizeOf(u8),
        @sizeOf(u8),
        weights,
        model.sha256("stateful VFR video fixture metadata"),
        model.sha256("fixture-only license"),
    );
}

pub fn initializeReferenceStateV1(
    first_window: FrameWindowV1,
) Error!ReferenceStateV1 {
    try validateFrameWindowV1(first_window);
    if (first_window.segment_index != 1 or
        first_window.generation != 1)
        return Error.InvalidVideoBinding;
    const state: ReferenceStateV1 = .{
        .segment_index = 0,
        .next_frame_ordinal = first_window.first_frame_ordinal,
        .last_end_tick = first_window.previous_end_tick,
        .target_numerator = first_window.target_numerator,
        .target_denominator = first_window.target_denominator,
        .emitted_segments = 0,
    };
    try validateReferenceStateV1(state);
    return state;
}

pub fn makeReferenceFixtureV1(
    first_window: FrameWindowV1,
    total_segments: u64,
) Error!ReferenceFixtureV1 {
    if (total_segments < 2)
        return Error.InvalidVideoBinding;
    const manifest =
        try makeReferenceManifestV1(&reference_weights);
    const state =
        try initializeReferenceStateV1(first_window);
    var state_wire: [reference_state_bytes]u8 =
        undefined;
    _ = try encodeReferenceStateV1(
        state,
        &state_wire,
    );
    const state_publication =
        try stateful.initializeStatePublicationV1(
            first_window.request_epoch,
            total_segments,
            reference_state_bytes,
            manifest.artifact_sha256,
            model.sha256(&state_wire),
            first_window.challenge_sha256,
        );
    const model_publication =
        try model.initializePublicationStateV1(
            first_window.request_epoch,
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
            first_window,
            model.sha256("stateful VFR video genesis plan"),
        ),
    };
}

pub fn makeReferencePlanV1(
    manifest: model.ArtifactManifestV1,
    model_publication: model.PublicationStateV1,
    state_publication: StatePublicationV1,
    frame_window: FrameWindowV1,
    previous_plan_sha256: Digest,
) Error!model.ExecutionPlanV1 {
    try validateVideoManifestV1(manifest);
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    try validateFrameWindowV1(frame_window);
    const generation = std.math.add(
        u64,
        state_publication.current_step,
        1,
    ) catch return Error.InvalidVideoBinding;
    if (state_publication.current_step >=
        state_publication.total_steps or
        generation != frame_window.generation or
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
            &frame_window.challenge_sha256,
        ) or
        isZero(previous_plan_sha256))
        return Error.InvalidVideoBinding;
    const publication_bytes = std.math.add(
        u64,
        reference_output_bytes,
        reference_state_bytes,
    ) catch return Error.InvalidVideoBinding;
    return model.makeExecutionPlanV1(
        manifest,
        .segment,
        .{
            .request_epoch = state_publication.request_epoch,
            .generation = generation,
            .batch_items = 1,
            .publication_next_sequence = model_publication.next_sequence,
            .maximum_absolute_output = 255,
            .claim = .{
                .capsule_bytes = manifest.weight_bytes,
                .activation_bytes = reference_input_features,
                .partial_bytes = reference_output_bytes,
                .output_journal_bytes = publication_bytes,
                .staging_bytes = reference_state_bytes,
                .queue_slots = 1,
            },
            .media_object_sha256 = frame_window.media_object_sha256,
            .processor_state_sha256 = state_publication.publication_sha256,
            .processor_bundle_sha256 = frame_window.processor_bundle_sha256,
            .cache_bundle_sha256 = frame_window.cache_bundle_sha256,
            .cache_payload_sha256 = state_publication.current_state_sha256,
            .ownership_sha256 = frame_window.ownership_sha256,
            .challenge_sha256 = frame_window.challenge_sha256,
            .previous_plan_sha256 = previous_plan_sha256,
            .input_schema_sha256 = frame_window.window_sha256,
            .output_schema_sha256 = video.videoSegmentSchemaRootV1(),
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
                "reference exact stateful VFR video v1",
            ),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
}

pub fn validateVideoAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
    frame_window: FrameWindowV1,
) Error!void {
    try validateVideoManifestV1(manifest);
    try stateful.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &video_state_support,
    );
    try validateVideoPlanV1(
        manifest,
        plan,
        state_publication,
        frame_window,
    );
}

pub fn validateVideoManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    try model.validateArtifactManifestV1(manifest);
    if (manifest.family != .video_understanding or
        manifest.input_kind != .video_feature_u8 or
        manifest.output_kind != .video_segment or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items != 1 or
        manifest.input_features !=
            reference_input_features or
        manifest.output_dimensions !=
            reference_output_bytes or
        manifest.input_element_bytes != @sizeOf(u8) or
        manifest.output_element_bytes != @sizeOf(u8) or
        manifest.weight_elements !=
            reference_weights.len or
        manifest.weight_element_bytes != @sizeOf(u8) or
        manifest.weight_bytes != reference_weights.len)
        return Error.InvalidVideoBinding;
}

pub fn validateVideoPlanV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
    frame_window: FrameWindowV1,
) Error!void {
    try model.validateExecutionPlanV1(plan);
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    try validateFrameWindowV1(frame_window);
    const expected_generation = std.math.add(
        u64,
        state_publication.current_step,
        1,
    ) catch return Error.InvalidVideoBinding;
    if (plan.family != .video_understanding or
        plan.operation != .segment or
        plan.input_kind != .video_feature_u8 or
        plan.output_kind != .video_segment or
        plan.numerical_policy != .exact_integer or
        plan.request_epoch != frame_window.request_epoch or
        plan.generation != frame_window.generation or
        plan.generation != expected_generation or
        plan.batch_items != 1 or
        plan.input_features !=
            reference_input_features or
        plan.output_dimensions !=
            reference_output_bytes or
        plan.input_bytes != reference_input_features or
        plan.output_bytes != reference_output_bytes or
        plan.scratch_bytes != reference_output_bytes or
        plan.publication_next_sequence !=
            state_publication.current_step or
        plan.maximum_absolute_output != 255 or
        !std.mem.eql(
            u8,
            &plan.artifact_sha256,
            &manifest.artifact_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.media_object_sha256,
            &frame_window.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.processor_state_sha256,
            &state_publication.publication_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.processor_bundle_sha256,
            &frame_window.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.cache_bundle_sha256,
            &frame_window.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.cache_payload_sha256,
            &state_publication.current_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.ownership_sha256,
            &frame_window.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.challenge_sha256,
            &frame_window.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.input_schema_sha256,
            &frame_window.window_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.output_schema_sha256,
            &video.videoSegmentSchemaRootV1(),
        ))
        return Error.InvalidVideoBinding;
}

pub fn validateVideoBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    state_publication: StatePublicationV1,
    frame_window: FrameWindowV1,
    features: []const u8,
    current_state_wire: []const u8,
) Error!void {
    try validateVideoManifestV1(manifest);
    try validateVideoPlanV1(
        manifest,
        plan,
        state_publication,
        frame_window,
    );
    if (features.len != plan.input_bytes or
        current_state_wire.len !=
            reference_state_bytes or
        !std.mem.eql(
            u8,
            &model.sha256(features),
            &frame_window.frame_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &model.sha256(current_state_wire),
            &state_publication.current_state_sha256,
        ))
        return Error.InvalidVideoBinding;
    const current = try decodeReferenceStateV1(
        current_state_wire,
    );
    try validateStateWindowV1(current, frame_window);
}

pub fn encodeReferenceStateV1(
    state: ReferenceStateV1,
    output: *[reference_state_bytes]u8,
) Error![]const u8 {
    try validateReferenceStateV1(state);
    writeU64(output, 0, state.segment_index);
    writeU64(output, 8, state.next_frame_ordinal);
    writeU64(output, 16, state.last_end_tick);
    writeU64(output, 24, state.target_numerator);
    writeU64(output, 32, state.target_denominator);
    writeU64(output, 40, state.emitted_segments);
    return output;
}

pub fn decodeReferenceStateV1(
    encoded: []const u8,
) Error!ReferenceStateV1 {
    if (encoded.len != reference_state_bytes)
        return Error.InvalidVideoState;
    const state: ReferenceStateV1 = .{
        .segment_index = readU64(encoded, 0),
        .next_frame_ordinal = readU64(encoded, 8),
        .last_end_tick = readU64(encoded, 16),
        .target_numerator = readU64(encoded, 24),
        .target_denominator = readU64(encoded, 32),
        .emitted_segments = readU64(encoded, 40),
    };
    try validateReferenceStateV1(state);
    var canonical: [reference_state_bytes]u8 =
        undefined;
    _ = try encodeReferenceStateV1(
        state,
        &canonical,
    );
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidVideoState;
    return state;
}

pub fn validateReferenceStateV1(
    state: ReferenceStateV1,
) Error!void {
    media.validateTimeBaseV1(.{
        .numerator = state.target_numerator,
        .denominator = state.target_denominator,
    }) catch return Error.InvalidVideoState;
    if (state.segment_index != state.emitted_segments)
        return Error.InvalidVideoState;
}

pub fn validateReferenceContextV1(
    context: ReferenceContextV1,
) Error!void {
    try validateFrameWindowV1(context.frame_window);
    if (isZero(context.previous_segment_sha256))
        return Error.InvalidVideoBinding;
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
        features.len != reference_input_features or
        current_state_wire.len !=
            reference_state_bytes or
        candidate_output.len !=
            reference_output_bytes or
        candidate_state_wire.len !=
            reference_state_bytes)
        return Error.InvalidVideoBinding;
    if (!std.mem.eql(
        u8,
        &model.sha256(features),
        &context.frame_window.frame_payload_sha256,
    ))
        return Error.InvalidVideoBinding;
    const current = try decodeReferenceStateV1(
        current_state_wire,
    );
    try validateStateWindowV1(
        current,
        context.frame_window,
    );
    const event_id = std.math.add(
        u64,
        features[0],
        weights[0],
    ) catch return Error.CandidateInvalid;
    const confidence_delta = std.math.mul(
        u64,
        features[1],
        10_000,
    ) catch return Error.CandidateInvalid;
    const confidence = std.math.add(
        u64,
        800_000,
        confidence_delta,
    ) catch return Error.CandidateInvalid;
    const window = context.frame_window;
    var segment: video.VideoSegmentV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .segment_index = window.segment_index,
        .first_frame = window.first_frame_ordinal,
        .last_frame = window.frame_ordinals[
            @as(usize, @intCast(window.frame_count - 1))
        ],
        .frame_count = window.frame_count,
        .frame_stride = 1,
        .keyframe_ordinal = firstKeyframeV1(window),
        .eviction_boundary = window.first_frame_ordinal,
        .cache_generation = window.generation,
        .target_base = .{
            .numerator = window.target_numerator,
            .denominator = window.target_denominator,
        },
        .target_start_tick = window.start_tick,
        .target_end_tick = window.end_tick,
        .event_id = event_id,
        .confidence_ppm = confidence,
        .media_object_sha256 = plan.media_object_sha256,
        .processor_state_sha256 = plan.processor_state_sha256,
        .processor_bundle_sha256 = plan.processor_bundle_sha256,
        .cache_bundle_sha256 = plan.cache_bundle_sha256,
        .cache_payload_sha256 = plan.cache_payload_sha256,
        .ownership_sha256 = plan.ownership_sha256,
        .selection_sha256 = window.window_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .previous_segment_sha256 = context.previous_segment_sha256,
        .segment_sha256 = [_]u8{0} ** 32,
    };
    segment.segment_sha256 =
        video.videoSegmentRootV1(segment);
    try video.validateVideoSegmentV1(segment);
    var segment_wire: [video.video_segment_bytes]u8 =
        undefined;
    _ = try video.encodeVideoSegmentV1(
        segment,
        &segment_wire,
    );
    @memcpy(candidate_output, &segment_wire);
    const next_frame = std.math.add(
        u64,
        window.first_frame_ordinal,
        window.frame_count,
    ) catch return Error.CandidateInvalid;
    const emitted = std.math.add(
        u64,
        current.emitted_segments,
        1,
    ) catch return Error.CandidateInvalid;
    const next: ReferenceStateV1 = .{
        .segment_index = window.segment_index,
        .next_frame_ordinal = next_frame,
        .last_end_tick = window.end_tick,
        .target_numerator = window.target_numerator,
        .target_denominator = window.target_denominator,
        .emitted_segments = emitted,
    };
    var state_wire: [reference_state_bytes]u8 =
        undefined;
    _ = try encodeReferenceStateV1(
        next,
        &state_wire,
    );
    @memcpy(candidate_state_wire, &state_wire);
}

pub fn validateCandidateV1(
    opaque_context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    current_state_wire: []const u8,
    candidate_output: []const u8,
    candidate_state_wire: []const u8,
) anyerror!void {
    var expected_output: [reference_output_bytes]u8 =
        undefined;
    var expected_state: [reference_state_bytes]u8 =
        undefined;
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

fn validateStateWindowV1(
    state: ReferenceStateV1,
    window: FrameWindowV1,
) Error!void {
    const expected_segment = std.math.add(
        u64,
        state.segment_index,
        1,
    ) catch return Error.InvalidVideoBinding;
    if (expected_segment != window.segment_index or
        state.next_frame_ordinal !=
            window.first_frame_ordinal or
        state.last_end_tick !=
            window.previous_end_tick or
        state.target_numerator !=
            window.target_numerator or
        state.target_denominator !=
            window.target_denominator)
        return Error.InvalidVideoBinding;
}

fn firstKeyframeV1(
    window: FrameWindowV1,
) u64 {
    const count: usize = @intCast(window.frame_count);
    for (0..count) |index| {
        if (window.keyframe_flags[index] == 1)
            return window.frame_ordinals[index];
    }
    unreachable;
}

fn writeFrameWindowBodyV1(
    window: FrameWindowV1,
    output: *[frame_window_body_bytes]u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &frame_window_magic);
    writeU64(output, 8, frame_window_abi);
    writeU64(output, 16, frame_window_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        window.request_epoch,
        window.generation,
        window.segment_index,
        window.first_frame_ordinal,
        window.frame_count,
        window.target_numerator,
        window.target_denominator,
        window.previous_end_tick,
        window.start_tick,
        window.end_tick,
        window.discontinuity_before_ticks,
        window.duration_transition_count,
        window.keyframe_count,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    writeU64Array(output[160..192], window.frame_ordinals);
    writeU64Array(
        output[192..224],
        window.presentation_ticks,
    );
    writeU64Array(output[224..256], window.duration_ticks);
    writeU64Array(output[256..288], window.keyframe_flags);
    const digests = [_]Digest{
        window.media_object_sha256,
        window.processor_bundle_sha256,
        window.cache_bundle_sha256,
        window.ownership_sha256,
        window.frame_payload_sha256,
        window.timestamp_payload_sha256,
        window.previous_window_sha256,
        window.challenge_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 288 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

fn writeU64Array(
    output: []u8,
    values: [frame_capacity]u64,
) void {
    for (values, 0..) |value, index|
        writeU64(output, index * 8, value);
}

fn readU64Array(
    input: []const u8,
) [frame_capacity]u64 {
    var values = [_]u64{0} ** frame_capacity;
    for (0..frame_capacity) |index|
        values[index] = readU64(input, index * 8);
    return values;
}

fn writeU64(
    output: []u8,
    offset: usize,
    value: u64,
) void {
    std.mem.writeInt(
        u64,
        output[offset .. offset + 8][0..8],
        value,
        .little,
    );
}

fn readU64(
    input: []const u8,
    offset: usize,
) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

fn testWindow(
    generation: u64,
    previous_end_tick: u64,
    frame_ordinals: []const u64,
    presentation_ticks: []const u64,
    duration_ticks: []const u64,
    previous_window_sha256: Digest,
) !FrameWindowV1 {
    return makeFrameWindowV1(
        531,
        generation,
        generation,
        .{ .numerator = 1, .denominator = 1_000 },
        previous_end_tick,
        frame_ordinals,
        presentation_ticks,
        duration_ticks,
        &[_]u64{ 1, 0 },
        model.sha256("stateful VFR video media"),
        model.sha256("stateful VFR processor bundle"),
        model.sha256("stateful VFR cache bundle"),
        model.sha256("stateful VFR ownership"),
        model.sha256(switch (generation) {
            1 => &reference_first_features,
            2 => &reference_second_features,
            else => "unsupported VFR feature generation",
        }),
        previous_window_sha256,
        model.sha256("stateful VFR challenge"),
    );
}

const TestRuntime = struct {
    slots: [4]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 4,
    roots: [4]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 4,
    nodes: [8]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 8,
};

test "VFR windows are canonical and predecessor exact" {
    const first = try testWindow(
        1,
        0,
        &[_]u64{ 0, 1 },
        &[_]u64{ 0, 8 },
        &[_]u64{ 8, 12 },
        model.sha256("stateful VFR genesis"),
    );
    const second = try testWindow(
        2,
        20,
        &[_]u64{ 2, 3 },
        &[_]u64{ 25, 35 },
        &[_]u64{ 10, 15 },
        first.window_sha256,
    );
    try validateFramePredecessorV1(first, second);
    try std.testing.expectEqual(
        @as(u64, 5),
        second.discontinuity_before_ticks,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        first.duration_transition_count,
    );
    var wire: [frame_window_bytes]u8 = undefined;
    _ = try encodeFrameWindowV1(second, &wire);
    try std.testing.expectEqual(
        second,
        try decodeFrameWindowV1(&wire),
    );
    for (0..wire.len) |index| {
        var mutated = wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidFrameWindow,
            decodeFrameWindowV1(&mutated),
        );
    }
}

test "VFR frame payload binds the exact model feature bytes" {
    const first = try testWindow(
        1,
        0,
        &[_]u64{ 0, 1 },
        &[_]u64{ 0, 8 },
        &[_]u64{ 8, 12 },
        model.sha256("stateful VFR genesis"),
    );
    const fixture = try makeReferenceFixtureV1(first, 2);
    try validateVideoBindingsV1(
        fixture.manifest,
        fixture.plan,
        fixture.state_publication,
        first,
        &reference_first_features,
        &fixture.state_wire,
    );
    var foreign_features = reference_first_features;
    foreign_features[1] ^= 1;
    try std.testing.expectError(
        Error.InvalidVideoBinding,
        validateVideoBindingsV1(
            fixture.manifest,
            fixture.plan,
            fixture.state_publication,
            first,
            &foreign_features,
            &fixture.state_wire,
        ),
    );
}

test "stateful VFR video emits exact segment and advances frame state" {
    const first = try testWindow(
        1,
        0,
        &[_]u64{ 0, 1 },
        &[_]u64{ 0, 8 },
        &[_]u64{ 8, 12 },
        model.sha256("stateful VFR genesis"),
    );
    const second = try testWindow(
        2,
        20,
        &[_]u64{ 2, 3 },
        &[_]u64{ 25, 35 },
        &[_]u64{ 10, 15 },
        first.window_sha256,
    );
    var fixture = try makeReferenceFixtureV1(first, 2);
    var runtime: TestRuntime = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &runtime.slots,
            &runtime.roots,
            &runtime.nodes,
            .{},
            94_001,
        );
    var first_context: ReferenceContextV1 = .{
        .frame_window = first,
        .previous_segment_sha256 = model.sha256("stateful VFR segment genesis"),
    };
    const first_adapter = try referenceAdapterV1(
        fixture.manifest,
        &first_context,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        94_101,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        first_adapter,
        first,
    );
    var candidate_output: [reference_output_bytes]u8 =
        undefined;
    var candidate_state: [reference_state_bytes]u8 =
        undefined;
    var visible_output =
        [_]u8{0} ** reference_output_bytes;
    var visible_state =
        [_]u8{0} ** reference_state_bytes;
    _ = try session.prepareV1(
        first,
        &reference_weights,
        &reference_first_features,
        &fixture.state_wire,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    _ = try session.commitV1();
    const first_segment =
        try video.decodeVideoSegmentV1(&visible_output);
    try std.testing.expectEqual(
        @as(u64, 20),
        first_segment.target_end_tick,
    );
    const first_state =
        try decodeReferenceStateV1(&visible_state);
    try std.testing.expectEqual(
        @as(u64, 2),
        first_state.next_frame_ordinal,
    );
    const second_plan = try makeReferencePlanV1(
        fixture.manifest,
        fixture.model_publication,
        fixture.state_publication,
        second,
        fixture.plan.plan_sha256,
    );
    var second_context: ReferenceContextV1 = .{
        .frame_window = second,
        .previous_segment_sha256 = first_segment.segment_sha256,
    };
    const second_adapter = try referenceAdapterV1(
        fixture.manifest,
        &second_context,
    );
    var second_session: Session = .{};
    try second_session.initV1(
        &bank,
        94_201,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        second_plan,
        second_adapter,
        second,
    );
    var second_candidate_output: [reference_output_bytes]u8 = undefined;
    var second_candidate_state: [reference_state_bytes]u8 = undefined;
    var second_visible_output =
        [_]u8{0} ** reference_output_bytes;
    var second_visible_state =
        [_]u8{0} ** reference_state_bytes;
    _ = try second_session.prepareV1(
        second,
        &reference_weights,
        &reference_second_features,
        &visible_state,
        &second_candidate_output,
        &second_candidate_state,
        &second_visible_output,
        &second_visible_state,
    );
    _ = try second_session.commitV1();
    const second_segment =
        try video.decodeVideoSegmentV1(
            &second_visible_output,
        );
    try std.testing.expectEqual(
        first_segment.segment_sha256,
        second_segment.previous_segment_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, 25),
        second_segment.target_start_tick,
    );
    try std.testing.expectEqual(
        @as(u64, 50),
        second_segment.target_end_tick,
    );
    const second_state =
        try decodeReferenceStateV1(
            &second_visible_state,
        );
    try std.testing.expectEqual(
        @as(u64, 4),
        second_state.next_frame_ordinal,
    );
    try second_session.closeAndRelease();
    try session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "stateful VFR video rejects hidden frame or time discontinuity" {
    const first = try testWindow(
        1,
        0,
        &[_]u64{ 0, 1 },
        &[_]u64{ 0, 8 },
        &[_]u64{ 8, 12 },
        model.sha256("stateful VFR genesis"),
    );
    var second = try testWindow(
        2,
        20,
        &[_]u64{ 2, 3 },
        &[_]u64{ 25, 35 },
        &[_]u64{ 10, 15 },
        first.window_sha256,
    );
    second.first_frame_ordinal = 3;
    second.window_sha256 = frameWindowRootV1(second);
    try std.testing.expectError(
        Error.InvalidFrameWindow,
        validateFramePredecessorV1(first, second),
    );
}
