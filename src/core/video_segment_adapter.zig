const std = @import("std");
const media = @import("media_contract.zig");
const processor = @import("media_processor_state.zig");
const processor_cache = @import("media_processor_cache.zig");
const model = @import("model_contract.zig");
const stateless = @import("stateless_model_adapter.zig");
const temporal = @import("temporal_video_adapter.zig");
const resource_bank = @import("resource_bank.zig");

const Digest = [32]u8;

pub const reference_adapter_abi: u64 = 0x4756_5341_0000_0001;
pub const video_segment_abi: u64 = 0x4756_5345_4700_0001;
pub const video_segment_bytes: usize = 512;
const video_segment_body_bytes = video_segment_bytes - 32;
const allowed_flags: u64 = 0;
const video_segment_magic = [_]u8{
    'G', 'V', 'S', 'E', 'G', '1', 0, 0,
};
const video_segment_domain =
    "glacier-video-segment-v1\x00";
const segment_source_domain =
    "glacier-video-segment-source-v1\x00";

pub const video_segment_support = [_]model.SupportRecordV1{.{
    .family = .video_understanding,
    .operation = .segment,
    .input_kind = .video_feature_u8,
    .output_kind = .video_segment,
    .numerical_policy = .exact_integer,
    .max_batch_items = 1,
    .max_input_features = 1_048_576,
    .max_output_dimensions = video_segment_bytes,
    .allowed_capabilities = model.no_capabilities,
}};

pub const Error = media.Error || processor.Error ||
    processor_cache.Error || model.Error || stateless.Error ||
    temporal.Error || resource_bank.Error || error{
    InvalidVideoSegment,
    InvalidVideoSegmentBinding,
};

pub const AdapterDescriptorV1 = stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const Phase = stateless.Phase;

pub const VideoSegmentV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    first_frame: u64,
    last_frame: u64,
    frame_count: u64,
    frame_stride: u64,
    keyframe_ordinal: u64,
    eviction_boundary: u64,
    cache_generation: u64,
    target_base: media.TimeBaseV1,
    target_start_tick: u64,
    target_end_tick: u64,
    event_id: u64,
    confidence_ppm: u64,
    media_object_sha256: Digest,
    processor_state_sha256: Digest,
    processor_bundle_sha256: Digest,
    cache_bundle_sha256: Digest,
    cache_payload_sha256: Digest,
    ownership_sha256: Digest,
    selection_sha256: Digest,
    challenge_sha256: Digest,
    previous_segment_sha256: Digest,
    segment_sha256: Digest,
};

pub const ReferenceContextV1 = struct {
    selection: temporal.TemporalSelectionV1,
    segment_index: u64,
    previous_segment_sha256: Digest,
};

pub const Session = struct {
    inner: stateless.Session = .{},
    selection: temporal.TemporalSelectionV1 = undefined,
    segment_index: u64 = 0,
    previous_segment_sha256: Digest = [_]u8{0} ** 32,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        publication_state: *model.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        selection: temporal.TemporalSelectionV1,
        segment_index: u64,
        previous_segment_sha256: Digest,
        adapter: AdapterV1,
    ) Error!void {
        try validateVideoSegmentAdapterV1(
            adapter,
            manifest,
            plan,
        );
        if (segment_index == 0 or isZero(previous_segment_sha256) or
            !std.mem.eql(
                u8,
                &segmentSourceRootV1(
                    plan,
                    selection,
                    segment_index,
                    previous_segment_sha256,
                ),
                &plan.input_schema_sha256,
            ) or
            !std.mem.eql(
                u8,
                &videoSegmentSchemaRootV1(),
                &plan.output_schema_sha256,
            ))
            return Error.InvalidVideoSegmentBinding;
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &video_segment_support,
        );
        self.selection = selection;
        self.segment_index = segment_index;
        self.previous_segment_sha256 =
            previous_segment_sha256;
    }

    pub fn prepareV1(
        self: *Session,
        processor_bundle: *const processor.DecodedBundleV1,
        cache_bundle: *const processor_cache.DecodedBundleV1,
        cache_session: *const processor_cache.RestoreSession,
        weights: []const u8,
        video_cache: []const u8,
        selected_input: []u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateVideoSegmentBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            self.selection,
            self.segment_index,
            self.previous_segment_sha256,
            processor_bundle,
            cache_bundle,
            video_cache,
        );
        try cache_session.validateActivePayloadV1(
            2,
            video_cache,
        );
        defer @memset(selected_input, 0);
        const selected =
            try temporal.materializeSelectedFramesV1(
                processor_bundle.states[2],
                self.selection,
                video_cache,
                selected_input,
            );
        return self.inner.prepareV1(
            weights,
            selected,
            self.inner.plan.input_schema_sha256,
            candidate,
            visible_output,
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

    pub fn closeAndRelease(
        self: *Session,
    ) Error!void {
        return self.inner.closeAndRelease();
    }
};

pub fn makeAdapterDescriptorV1(
    manifest: model.ArtifactManifestV1,
    implementation_sha256: Digest,
) Error!AdapterDescriptorV1 {
    try validateVideoSegmentManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .segment,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn validateVideoSegmentAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateVideoSegmentManifestV1(manifest);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &video_segment_support,
    );
}

pub fn makeVideoSegmentV1(
    plan: model.ExecutionPlanV1,
    selection: temporal.TemporalSelectionV1,
    segment_index: u64,
    previous_segment_sha256: Digest,
    event_id: u64,
    confidence_ppm: u64,
) Error!VideoSegmentV1 {
    if (plan.family != .video_understanding or
        plan.operation != .segment or
        plan.input_kind != .video_feature_u8 or
        plan.output_kind != .video_segment or
        plan.numerical_policy != .exact_integer or
        plan.batch_items != 1 or
        plan.output_dimensions != video_segment_bytes or
        plan.input_element_bytes != @sizeOf(u8) or
        plan.output_element_bytes != @sizeOf(u8) or
        segment_index == 0 or event_id == 0 or
        confidence_ppm > 1_000_000 or
        isZero(previous_segment_sha256) or
        !std.mem.eql(
            u8,
            &segmentSourceRootV1(
                plan,
                selection,
                segment_index,
                previous_segment_sha256,
            ),
            &plan.input_schema_sha256,
        ) or
        !std.mem.eql(
            u8,
            &videoSegmentSchemaRootV1(),
            &plan.output_schema_sha256,
        ))
        return Error.InvalidVideoSegment;
    var segment: VideoSegmentV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .segment_index = segment_index,
        .first_frame = selection.first_frame,
        .last_frame = selection.last_frame,
        .frame_count = selection.frame_count,
        .frame_stride = selection.frame_stride,
        .keyframe_ordinal = selection.keyframe_ordinal,
        .eviction_boundary = selection.eviction_boundary,
        .cache_generation = selection.cache_generation,
        .target_base = selection.target_base,
        .target_start_tick = selection.target_start_tick,
        .target_end_tick = selection.target_end_tick,
        .event_id = event_id,
        .confidence_ppm = confidence_ppm,
        .media_object_sha256 = plan.media_object_sha256,
        .processor_state_sha256 = plan.processor_state_sha256,
        .processor_bundle_sha256 = plan.processor_bundle_sha256,
        .cache_bundle_sha256 = plan.cache_bundle_sha256,
        .cache_payload_sha256 = plan.cache_payload_sha256,
        .ownership_sha256 = plan.ownership_sha256,
        .selection_sha256 = selection.selection_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .previous_segment_sha256 = previous_segment_sha256,
        .segment_sha256 = [_]u8{0} ** 32,
    };
    segment.segment_sha256 = videoSegmentRootV1(segment);
    try validateVideoSegmentV1(segment);
    return segment;
}

pub fn encodeVideoSegmentV1(
    segment: VideoSegmentV1,
    output: *[video_segment_bytes]u8,
) Error![]const u8 {
    try validateVideoSegmentV1(segment);
    writeVideoSegmentBodyV1(
        segment,
        output[0..video_segment_body_bytes],
    );
    @memcpy(
        output[video_segment_body_bytes..],
        &segment.segment_sha256,
    );
    return output;
}

pub fn decodeVideoSegmentV1(
    encoded: []const u8,
) Error!VideoSegmentV1 {
    if (encoded.len != video_segment_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &video_segment_magic,
        ) or
        readU64(encoded, 8) != video_segment_abi or
        readU64(encoded, 16) != video_segment_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[448..480], 0))
        return Error.InvalidVideoSegment;
    const segment: VideoSegmentV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .segment_index = readU64(encoded, 48),
        .first_frame = readU64(encoded, 56),
        .last_frame = readU64(encoded, 64),
        .frame_count = readU64(encoded, 72),
        .frame_stride = readU64(encoded, 80),
        .keyframe_ordinal = readU64(encoded, 88),
        .eviction_boundary = readU64(encoded, 96),
        .cache_generation = readU64(encoded, 104),
        .target_base = .{
            .numerator = readU64(encoded, 112),
            .denominator = readU64(encoded, 120),
        },
        .target_start_tick = readU64(encoded, 128),
        .target_end_tick = readU64(encoded, 136),
        .event_id = readU64(encoded, 144),
        .confidence_ppm = readU64(encoded, 152),
        .media_object_sha256 = encoded[160..192].*,
        .processor_state_sha256 = encoded[192..224].*,
        .processor_bundle_sha256 = encoded[224..256].*,
        .cache_bundle_sha256 = encoded[256..288].*,
        .cache_payload_sha256 = encoded[288..320].*,
        .ownership_sha256 = encoded[320..352].*,
        .selection_sha256 = encoded[352..384].*,
        .challenge_sha256 = encoded[384..416].*,
        .previous_segment_sha256 = encoded[416..448].*,
        .segment_sha256 = encoded[video_segment_body_bytes..video_segment_bytes].*,
    };
    try validateVideoSegmentV1(segment);
    var canonical: [video_segment_bytes]u8 = undefined;
    _ = try encodeVideoSegmentV1(segment, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidVideoSegment;
    return segment;
}

pub fn validateVideoSegmentV1(
    segment: VideoSegmentV1,
) Error!void {
    if (segment.request_epoch == 0 or
        segment.generation == 0 or
        segment.segment_index == 0 or
        segment.frame_count == 0 or
        segment.frame_stride == 0 or
        segment.keyframe_ordinal > segment.first_frame or
        segment.eviction_boundary > segment.first_frame or
        segment.target_base.numerator == 0 or
        segment.target_base.denominator == 0 or
        segment.target_start_tick >= segment.target_end_tick or
        segment.event_id == 0 or
        segment.confidence_ppm > 1_000_000)
        return Error.InvalidVideoSegment;
    const expected_last = std.math.add(
        u64,
        segment.first_frame,
        std.math.mul(
            u64,
            segment.frame_count - 1,
            segment.frame_stride,
        ) catch return Error.InvalidVideoSegment,
    ) catch return Error.InvalidVideoSegment;
    if (segment.last_frame != expected_last or
        isZero(segment.media_object_sha256) or
        isZero(segment.processor_state_sha256) or
        isZero(segment.processor_bundle_sha256) or
        isZero(segment.cache_bundle_sha256) or
        isZero(segment.cache_payload_sha256) or
        isZero(segment.ownership_sha256) or
        isZero(segment.selection_sha256) or
        isZero(segment.challenge_sha256) or
        isZero(segment.previous_segment_sha256) or
        !std.mem.eql(
            u8,
            &videoSegmentRootV1(segment),
            &segment.segment_sha256,
        ))
        return Error.InvalidVideoSegment;
}

pub fn videoSegmentRootV1(
    segment: VideoSegmentV1,
) Digest {
    var body: [video_segment_body_bytes]u8 = undefined;
    writeVideoSegmentBodyV1(segment, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(video_segment_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn videoSegmentSchemaRootV1() Digest {
    return model.sha256(
        "glacier video segment v1 512-byte wire",
    );
}

pub fn segmentSourceRootV1(
    plan: model.ExecutionPlanV1,
    selection: temporal.TemporalSelectionV1,
    segment_index: u64,
    previous_segment_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(segment_source_domain);
    hashU64(&hash, plan.request_epoch);
    hashU64(&hash, plan.generation);
    hashU64(&hash, segment_index);
    hash.update(&plan.media_object_sha256);
    hash.update(&plan.processor_state_sha256);
    hash.update(&plan.processor_bundle_sha256);
    hash.update(&plan.cache_bundle_sha256);
    hash.update(&plan.cache_payload_sha256);
    hash.update(&plan.ownership_sha256);
    hash.update(&selection.selection_sha256);
    hash.update(&plan.challenge_sha256);
    hash.update(&previous_segment_sha256);
    return hash.finalResult();
}

pub fn validateVideoSegmentBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    selection: temporal.TemporalSelectionV1,
    segment_index: u64,
    previous_segment_sha256: Digest,
    processor_bundle: *const processor.DecodedBundleV1,
    cache_bundle: *const processor_cache.DecodedBundleV1,
    video_cache: []const u8,
) Error!void {
    try validateVideoSegmentManifestV1(manifest);
    const video_state = processor_bundle.states[2];
    processor_cache.validateBindingV1(
        cache_bundle,
        processor_bundle,
        processor_bundle.bundle_sha256,
    ) catch return Error.InvalidVideoSegmentBinding;
    temporal.validateTemporalSelectionV1(
        video_state,
        selection,
    ) catch return Error.InvalidVideoSegmentBinding;
    const selected_bytes = temporal.selectedFrameBytesV1(
        video_state,
        selection,
    ) catch return Error.InvalidVideoSegmentBinding;
    if (segment_index == 0 or isZero(previous_segment_sha256) or
        plan.family != .video_understanding or
        plan.operation != .segment or
        plan.input_kind != .video_feature_u8 or
        plan.output_kind != .video_segment or
        plan.numerical_policy != .exact_integer or
        plan.request_epoch != video_state.request_epoch or
        plan.generation != video_state.generation or
        plan.batch_items != 1 or
        plan.input_features != selected_bytes or
        plan.output_dimensions != video_segment_bytes or
        plan.input_element_bytes != @sizeOf(u8) or
        plan.output_element_bytes != @sizeOf(u8) or
        video_cache.len != video_state.cache_bytes or
        !std.mem.eql(u8, video_cache, cache_bundle.payloads[2]) or
        !std.mem.eql(
            u8,
            &model.sha256(video_cache),
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.cache_content_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.state_sha256,
            &plan.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &processor_bundle.bundle_sha256,
            &plan.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &cache_bundle.bundle_sha256,
            &plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.ownership_receipt_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &video_state.challenge_sha256,
            &plan.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segmentSourceRootV1(
                plan,
                selection,
                segment_index,
                previous_segment_sha256,
            ),
            &plan.input_schema_sha256,
        ) or
        !std.mem.eql(
            u8,
            &videoSegmentSchemaRootV1(),
            &plan.output_schema_sha256,
        ) or
        manifest.input_features != plan.input_features or
        manifest.output_dimensions != plan.output_dimensions or
        plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.scratch_bytes or
        plan.claim.output_journal_bytes != plan.output_bytes or
        plan.claim.staging_bytes != plan.input_bytes or
        plan.claim.queue_slots != 1 or
        plan.claim.kv_bytes != 0 or
        plan.claim.logits_bytes != 0 or
        plan.claim.device_bytes != 0 or
        plan.claim.io_bytes != 0)
        return Error.InvalidVideoSegmentBinding;
}

pub fn referenceExecuteV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    const reference: *const ReferenceContextV1 =
        @ptrCast(@alignCast(context));
    if (weights.len != 1 or weights[0] != 0x56 or
        input.len != plan.input_bytes or
        candidate.len != video_segment_bytes)
        return Error.InvalidVideoSegmentBinding;
    var sum: u64 = 0;
    for (input) |value| {
        sum = std.math.add(
            u64,
            sum,
            value,
        ) catch return Error.InvalidVideoSegment;
    }
    const segment = try makeVideoSegmentV1(
        plan.*,
        reference.selection,
        reference.segment_index,
        reference.previous_segment_sha256,
        sum % 1_024 + 1,
        500_000 + sum % 500_001,
    );
    var encoded: [video_segment_bytes]u8 = undefined;
    _ = try encodeVideoSegmentV1(segment, &encoded);
    @memcpy(candidate, &encoded);
}

pub fn validateCandidateV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    const reference: *const ReferenceContextV1 =
        @ptrCast(@alignCast(context));
    const segment = try decodeVideoSegmentV1(candidate);
    const selection = reference.selection;
    if (segment.request_epoch != plan.request_epoch or
        segment.generation != plan.generation or
        segment.segment_index != reference.segment_index or
        segment.first_frame != selection.first_frame or
        segment.last_frame != selection.last_frame or
        segment.frame_count != selection.frame_count or
        segment.frame_stride != selection.frame_stride or
        segment.keyframe_ordinal != selection.keyframe_ordinal or
        segment.eviction_boundary != selection.eviction_boundary or
        segment.cache_generation != selection.cache_generation or
        segment.target_base.numerator !=
            selection.target_base.numerator or
        segment.target_base.denominator !=
            selection.target_base.denominator or
        segment.target_start_tick != selection.target_start_tick or
        segment.target_end_tick != selection.target_end_tick or
        !std.mem.eql(
            u8,
            &segment.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.processor_state_sha256,
            &plan.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.processor_bundle_sha256,
            &plan.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.cache_bundle_sha256,
            &plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.cache_payload_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.ownership_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.selection_sha256,
            &selection.selection_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.challenge_sha256,
            &plan.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.previous_segment_sha256,
            &reference.previous_segment_sha256,
        ))
        return Error.InvalidVideoSegment;
}

fn validateVideoSegmentManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    if (manifest.family != .video_understanding or
        manifest.input_kind != .video_feature_u8 or
        manifest.output_kind != .video_segment or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items != 1 or
        manifest.output_dimensions != video_segment_bytes or
        manifest.input_element_bytes != @sizeOf(u8) or
        manifest.output_element_bytes != @sizeOf(u8) or
        manifest.weight_element_bytes != @sizeOf(u8) or
        manifest.weight_elements != 1 or
        manifest.weight_bytes != 1)
        return Error.InvalidVideoSegmentBinding;
}

fn writeVideoSegmentBodyV1(
    segment: VideoSegmentV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &video_segment_magic);
    writeU64(output, 8, video_segment_abi);
    writeU64(output, 16, video_segment_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        segment.request_epoch,
        segment.generation,
        segment.segment_index,
        segment.first_frame,
        segment.last_frame,
        segment.frame_count,
        segment.frame_stride,
        segment.keyframe_ordinal,
        segment.eviction_boundary,
        segment.cache_generation,
        segment.target_base.numerator,
        segment.target_base.denominator,
        segment.target_start_tick,
        segment.target_end_tick,
        segment.event_id,
        segment.confidence_ppm,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        segment.media_object_sha256,
        segment.processor_state_sha256,
        segment.processor_bundle_sha256,
        segment.cache_bundle_sha256,
        segment.cache_payload_sha256,
        segment.ownership_sha256,
        segment.selection_sha256,
        segment.challenge_sha256,
        segment.previous_segment_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 160 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
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

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

const TestFixture = struct {
    processor_storage: [processor.processor_bundle_bytes]u8,
    cache_storage: [
        processor_cache.cache_payload_offset +
            18 +
            processor_cache.cache_bundle_footer_bytes
    ]u8,
    processor_bundle: processor.DecodedBundleV1,
    cache_bundle: processor_cache.DecodedBundleV1,
    selection: temporal.TemporalSelectionV1,
    previous_segment_sha256: Digest,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,
    weights: [1]u8,
    image_cache: [2]u8,
    audio_cache: [8]u8,
    video_cache: [8]u8,

    fn rebind(self: *TestFixture) !void {
        self.processor_bundle =
            try processor.decodeBundleV1(
                &self.processor_storage,
            );
        self.cache_bundle =
            try processor_cache.decodeBundleV1(
                &self.cache_storage,
            );
    }

    fn init() !TestFixture {
        const image_cache = [_]u8{ 1, 2 };
        const audio_cache = [_]u8{0} ** 8;
        const video_cache = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
        const request_epoch: u64 = 221;
        const generation: u64 = 7;
        const challenge = model.sha256("video challenge");
        const image_state = try processor.makeImageStateV1(.{
            .kind = .image,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 41_001,
            .timeline_base = .{
                .numerator = 0,
                .denominator = 1,
            },
            .media_object_sha256 = model.sha256("image media"),
            .processor_plan_sha256 = model.sha256("image processor"),
            .previous_state_sha256 = model.sha256("previous image state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&image_cache),
            .output_chain_sha256 = model.sha256("image output"),
            .ownership_receipt_sha256 = model.sha256("image ownership"),
            .decoder_state_sha256 = model.sha256("image decoder"),
        }, 1, 2, 1, 1, 1, 1, 1);
        const audio_state = try processor.makeAudioStateV1(.{
            .kind = .audio,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 41_002,
            .timeline_base = .{
                .numerator = 1,
                .denominator = 30_000,
            },
            .media_object_sha256 = model.sha256("audio media"),
            .processor_plan_sha256 = model.sha256("audio processor"),
            .previous_state_sha256 = model.sha256("previous audio state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&audio_cache),
            .output_chain_sha256 = model.sha256("audio output"),
            .ownership_receipt_sha256 = model.sha256("audio ownership"),
            .decoder_state_sha256 = model.sha256("audio decoder"),
        }, 2, 30_000, 1, 4, 4, 2, 2);
        const video_state = try processor.makeVideoStateV1(.{
            .kind = .video,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 41_003,
            .timeline_base = .{
                .numerator = 1,
                .denominator = 30,
            },
            .media_object_sha256 = model.sha256("video media"),
            .processor_plan_sha256 = model.sha256("video processor"),
            .previous_state_sha256 = model.sha256("previous video state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&video_cache),
            .output_chain_sha256 = model.sha256("video output"),
            .ownership_receipt_sha256 = model.sha256("video ownership"),
            .decoder_state_sha256 = model.sha256("video decoder"),
        }, 4, 2, 10, 14, 10);
        const states = [_]processor.ProcessorStateV1{
            image_state,
            audio_state,
            video_state,
        };
        const sync = try processor.makeSyncStateV1(states, .{
            .generation = generation,
            .request_epoch = request_epoch,
            .master_ticks_per_second = 90_000,
            .maximum_skew_ticks = 50_000,
            .challenge_sha256 = challenge,
            .sync_policy_sha256 = model.sha256("video sync policy"),
            .previous_sync_sha256 = model.sha256("previous video sync"),
        });
        var processor_storage: [processor.processor_bundle_bytes]u8 = undefined;
        _ = try processor.encodeBundleV1(
            states,
            sync,
            &processor_storage,
        );
        const processor_bundle =
            try processor.decodeBundleV1(&processor_storage);
        var cache_storage: [
            processor_cache.cache_payload_offset +
                18 +
                processor_cache.cache_bundle_footer_bytes
        ]u8 = undefined;
        _ = try processor_cache.encodeBundleV1(
            processor_bundle,
            .{
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .previous_cache_bundle_sha256 = model.sha256(
                    "previous segment cache bundle",
                ),
                .source_bank_epoch = 210,
                .restore_bank_epoch = 211,
                .restore_owner_key_base = 42_000,
                .restore_tree_key_base = 43_000,
                .restore_authority_key_base = 44_000,
                .tenant_key = 45_000,
                .publication_next_sequence = 5,
            },
            .{
                &image_cache,
                &audio_cache,
                &video_cache,
            },
            &cache_storage,
        );
        const cache_bundle =
            try processor_cache.decodeBundleV1(&cache_storage);
        const selection =
            try temporal.makeTemporalSelectionV1(
                video_state,
                10,
                2,
                2,
                .{
                    .numerator = 1,
                    .denominator = 90_000,
                },
            );
        const weights = [_]u8{0x56};
        const manifest = try model.makeArtifactManifestV1(
            .video_understanding,
            0x5653_4547_0000_0001,
            .video_feature_u8,
            .video_segment,
            .exact_integer,
            1,
            4,
            video_segment_bytes,
            1,
            1,
            1,
            &weights,
            model.sha256("video segment fixture metadata"),
            model.sha256("fixture-only license"),
        );
        const previous_segment_sha256 =
            model.sha256("previous video segment");
        const claim: resource_bank.Claim = .{
            .capsule_bytes = weights.len,
            .activation_bytes = 4,
            .partial_bytes = video_segment_bytes,
            .output_journal_bytes = video_segment_bytes,
            .staging_bytes = 4,
            .queue_slots = 1,
        };
        var plan_input: model.PlanInputV1 = .{
            .request_epoch = request_epoch,
            .generation = generation,
            .batch_items = 1,
            .publication_next_sequence = 0,
            .maximum_absolute_output = 255,
            .claim = claim,
            .media_object_sha256 = video_state.media_object_sha256,
            .processor_state_sha256 = video_state.state_sha256,
            .processor_bundle_sha256 = processor_bundle.bundle_sha256,
            .cache_bundle_sha256 = cache_bundle.bundle_sha256,
            .cache_payload_sha256 = video_state.cache_content_sha256,
            .ownership_sha256 = video_state.ownership_receipt_sha256,
            .challenge_sha256 = challenge,
            .previous_plan_sha256 = model.sha256("previous video segment plan"),
            .input_schema_sha256 = model.sha256("provisional segment source"),
            .output_schema_sha256 = videoSegmentSchemaRootV1(),
            .scratch_bytes = video_segment_bytes,
        };
        const provisional = try model.makeExecutionPlanV1(
            manifest,
            .segment,
            plan_input,
        );
        plan_input.input_schema_sha256 = segmentSourceRootV1(
            provisional,
            selection,
            3,
            previous_segment_sha256,
        );
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .segment,
            plan_input,
        );
        const publication_state =
            try model.initializePublicationStateV1(
                request_epoch,
                manifest.artifact_sha256,
            );
        var value: TestFixture = undefined;
        value.processor_storage = processor_storage;
        value.cache_storage = cache_storage;
        value.processor_bundle =
            try processor.decodeBundleV1(
                &value.processor_storage,
            );
        value.cache_bundle =
            try processor_cache.decodeBundleV1(
                &value.cache_storage,
            );
        value.selection = selection;
        value.previous_segment_sha256 =
            previous_segment_sha256;
        value.manifest = manifest;
        value.plan = plan;
        value.publication_state = publication_state;
        value.weights = weights;
        value.image_cache = image_cache;
        value.audio_cache = audio_cache;
        value.video_cache = video_cache;
        return value;
    }
};

const TestRuntime = struct {
    slots: [8]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [12]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 12,
};

fn testAdapter(
    fixture: *const TestFixture,
    context: *ReferenceContextV1,
) !AdapterV1 {
    return .{
        .context = context,
        .descriptor = try makeAdapterDescriptorV1(
            fixture.manifest,
            model.sha256(
                "reference typed video segment v1",
            ),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
}

test "video segment wire is canonical and mutation complete" {
    var selection_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &selection_sha256,
        "05910857e31e4c92c9124a22533a6d43" ++
            "51491e0c5fe4dfe83312c4eefb049ae4",
    );
    const selection: temporal.TemporalSelectionV1 = .{
        .first_frame = 10,
        .frame_count = 2,
        .frame_stride = 2,
        .last_frame = 12,
        .keyframe_ordinal = 10,
        .eviction_boundary = 10,
        .cache_generation = 7,
        .target_base = .{
            .numerator = 1,
            .denominator = 90_000,
        },
        .target_start_tick = 30_000,
        .target_end_tick = 39_000,
        .selection_sha256 = selection_sha256,
    };
    const previous = model.sha256("previous video segment");
    var plan: model.ExecutionPlanV1 = undefined;
    @memset(std.mem.asBytes(&plan), 0);
    plan.request_epoch = 221;
    plan.generation = 7;
    plan.family = .video_understanding;
    plan.operation = .segment;
    plan.input_kind = .video_feature_u8;
    plan.output_kind = .video_segment;
    plan.numerical_policy = .exact_integer;
    plan.batch_items = 1;
    plan.output_dimensions = video_segment_bytes;
    plan.input_element_bytes = @sizeOf(u8);
    plan.output_element_bytes = @sizeOf(u8);
    plan.media_object_sha256 = model.sha256("video media");
    _ = try std.fmt.hexToBytes(
        &plan.processor_state_sha256,
        "34eb7b8438998508572c1aeaaddbec1f" ++
            "baad4a44aff5ea146c6ce616b41edf45",
    );
    plan.processor_bundle_sha256 =
        model.sha256("video processor bundle");
    plan.cache_bundle_sha256 =
        model.sha256("video cache bundle");
    plan.cache_payload_sha256 =
        model.sha256(&[_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 });
    plan.ownership_sha256 = model.sha256("video ownership");
    plan.challenge_sha256 = model.sha256("video challenge");
    plan.output_schema_sha256 =
        videoSegmentSchemaRootV1();
    plan.input_schema_sha256 = segmentSourceRootV1(
        plan,
        selection,
        3,
        previous,
    );
    const segment = try makeVideoSegmentV1(
        plan,
        selection,
        3,
        previous,
        15,
        500_014,
    );
    var encoded: [video_segment_bytes]u8 = undefined;
    _ = try encodeVideoSegmentV1(segment, &encoded);
    try std.testing.expectEqual(
        segment,
        try decodeVideoSegmentV1(&encoded),
    );
    var expected_source: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_source,
        "76eb274c3afc40640b4b0125ee886e88" ++
            "e915268380f19d7156fe2e7f1252e0ac",
    );
    try std.testing.expectEqual(
        expected_source,
        plan.input_schema_sha256,
    );
    var expected_segment: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_segment,
        "d7d3122d8fb22e872c8825f002e1b7b4" ++
            "f47b8bf912a2920a8eb41165b7d61cf4",
    );
    try std.testing.expectEqual(
        expected_segment,
        segment.segment_sha256,
    );
    for (0..encoded.len) |index| {
        var mutated = encoded;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidVideoSegment,
            decodeVideoSegmentV1(&mutated),
        );
    }
}

test "video segment publishes atomically from live selected frames" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var storage: TestRuntime = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            fixture.cache_bundle.restore_bank_epoch,
        );
    var cache_session: processor_cache.RestoreSession = .{};
    try cache_session.prepareV1(
        &bank,
        fixture.cache_bundle,
        fixture.cache_bundle.bundle_sha256,
    );
    try cache_session.commitMaterializedV1(.{
        &fixture.image_cache,
        &fixture.audio_cache,
        &fixture.video_cache,
    });
    var context: ReferenceContextV1 = .{
        .selection = fixture.selection,
        .segment_index = 3,
        .previous_segment_sha256 = fixture.previous_segment_sha256,
    };
    const adapter = try testAdapter(&fixture, &context);
    var session: Session = .{};
    try session.initV1(
        &bank,
        46_000,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        fixture.selection,
        3,
        fixture.previous_segment_sha256,
        adapter,
    );
    var selected_input: [4]u8 = undefined;
    var candidate: [video_segment_bytes]u8 = undefined;
    var output: [video_segment_bytes]u8 = undefined;
    const prepared = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.video_cache,
        &selected_input,
        &candidate,
        &output,
    );
    try std.testing.expectEqual(
        fixture.plan.input_schema_sha256,
        prepared.source_mapping_sha256,
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &selected_input, 0),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const segment = try decodeVideoSegmentV1(&candidate);
    try std.testing.expectEqual(@as(u64, 10), segment.first_frame);
    try std.testing.expectEqual(@as(u64, 12), segment.last_frame);
    try std.testing.expectEqual(@as(u64, 15), segment.event_id);
    try std.testing.expectEqual(
        @as(u64, 500_014),
        segment.confidence_ppm,
    );
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expectEqual(
        segment,
        try decodeVideoSegmentV1(&output),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "video segment abort drift and stale selection preserve visibility" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var stale = fixture.selection;
    stale.eviction_boundary += 1;
    try std.testing.expectError(
        Error.InvalidVideoSegmentBinding,
        validateVideoSegmentBindingsV1(
            fixture.manifest,
            fixture.plan,
            stale,
            3,
            fixture.previous_segment_sha256,
            &fixture.processor_bundle,
            &fixture.cache_bundle,
            &fixture.video_cache,
        ),
    );
    var foreign_cache = fixture.video_cache;
    foreign_cache[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidVideoSegmentBinding,
        validateVideoSegmentBindingsV1(
            fixture.manifest,
            fixture.plan,
            fixture.selection,
            3,
            fixture.previous_segment_sha256,
            &fixture.processor_bundle,
            &fixture.cache_bundle,
            &foreign_cache,
        ),
    );
    var storage: TestRuntime = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            fixture.cache_bundle.restore_bank_epoch,
        );
    var cache_session: processor_cache.RestoreSession = .{};
    try cache_session.prepareV1(
        &bank,
        fixture.cache_bundle,
        fixture.cache_bundle.bundle_sha256,
    );
    try cache_session.commitMaterializedV1(.{
        &fixture.image_cache,
        &fixture.audio_cache,
        &fixture.video_cache,
    });
    var context: ReferenceContextV1 = .{
        .selection = fixture.selection,
        .segment_index = 3,
        .previous_segment_sha256 = fixture.previous_segment_sha256,
    };
    const adapter = try testAdapter(&fixture, &context);
    var session: Session = .{};
    try session.initV1(
        &bank,
        46_001,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        fixture.selection,
        3,
        fixture.previous_segment_sha256,
        adapter,
    );
    var selected_input: [4]u8 = undefined;
    var candidate: [video_segment_bytes]u8 = undefined;
    var output: [video_segment_bytes]u8 = undefined;
    _ = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.video_cache,
        &selected_input,
        &candidate,
        &output,
    );
    try session.abortV1();
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    _ = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.video_cache,
        &selected_input,
        &candidate,
        &output,
    );
    candidate[144] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}
