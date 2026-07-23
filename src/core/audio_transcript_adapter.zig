//! Exact overlapping-audio ownership and typed transcript publication fixture.
//!
//! A canonical overlap plan separates prefix context from the new sample range
//! that may produce visible text. The family adapter consumes one verified
//! processor-cache payload and publishes a fixed transcript segment through the
//! shared stateless lifecycle.

const std = @import("std");
const media = @import("media_contract.zig");
const processor = @import("media_processor_state.zig");
const processor_cache = @import("media_processor_cache.zig");
const model = @import("model_contract.zig");
const stateless = @import("stateless_model_adapter.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const reference_adapter_abi: u64 =
    0x4154_524e_0000_0001;
pub const overlap_plan_abi: u64 =
    0x414f_5652_0000_0001;
pub const transcript_segment_abi: u64 =
    0x4154_5347_0000_0001;
pub const overlap_plan_bytes: usize = 512;
pub const transcript_segment_bytes: usize = 384;
pub const maximum_text_bytes: usize = 64;
pub const allowed_flags: u64 = 0;

const overlap_body_bytes =
    overlap_plan_bytes - @sizeOf(Digest);
const transcript_body_bytes =
    transcript_segment_bytes - @sizeOf(Digest);
const overlap_magic = [8]u8{
    'G', 'A', 'O', 'V', 'R', 'P', '1', 0,
};
const transcript_magic = [8]u8{
    'G', 'A', 'T', 'R', 'N', 'S', '1', 0,
};
const overlap_domain =
    "glacier-audio-overlap-plan-v1\x00";
const transcript_domain =
    "glacier-audio-transcript-segment-v1\x00";

pub const transcript_support = [_]model.SupportRecordV1{.{
    .family = .audio_understanding,
    .operation = .transcribe,
    .input_kind = .audio_feature_i16,
    .output_kind = .transcript,
    .numerical_policy = .exact_integer,
    .max_batch_items = 1,
    .max_input_features = 4_096,
    .max_output_dimensions = transcript_segment_bytes,
    .allowed_capabilities = model.no_capabilities,
}};

pub const Error = media.Error || processor.Error ||
    processor_cache.Error || model.Error || stateless.Error ||
    resource_bank.Error || error{
    InvalidOverlapPlan,
    InvalidTranscript,
    InvalidTranscriptBinding,
};

pub const AdapterDescriptorV1 =
    stateless.AdapterDescriptorV1;
pub const AdapterV1 = stateless.AdapterV1;
pub const Phase = stateless.Phase;

pub const OverlapPlanV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    source_start_sample: u64,
    source_end_sample: u64,
    context_start_sample: u64,
    context_end_sample: u64,
    publish_start_sample: u64,
    publish_end_sample: u64,
    sample_rate: u64,
    window_samples: u64,
    hop_samples: u64,
    feature_frames: u64,
    feature_bins: u64,
    feature_bytes: u64,
    media_object_sha256: Digest,
    processor_state_sha256: Digest,
    processor_bundle_sha256: Digest,
    cache_bundle_sha256: Digest,
    cache_payload_sha256: Digest,
    ownership_sha256: Digest,
    challenge_sha256: Digest,
    previous_transcript_sha256: Digest,
    overlap_sha256: Digest,
};

pub const TranscriptSegmentV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    context_start_sample: u64,
    context_end_sample: u64,
    publish_start_sample: u64,
    publish_end_sample: u64,
    sample_rate: u64,
    text_bytes: u64,
    media_object_sha256: Digest,
    processor_state_sha256: Digest,
    cache_payload_sha256: Digest,
    overlap_sha256: Digest,
    previous_transcript_sha256: Digest,
    text: [maximum_text_bytes]u8,
    transcript_sha256: Digest,
};

pub const ReferenceContextV1 = struct {
    overlap_plan: OverlapPlanV1,
};

pub const Session = struct {
    inner: stateless.Session = .{},
    overlap_plan: OverlapPlanV1 = undefined,
    previous_transcript: TranscriptSegmentV1 = undefined,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        publication_state: *model.PublicationStateV1,
        manifest: model.ArtifactManifestV1,
        plan: model.ExecutionPlanV1,
        overlap_plan: OverlapPlanV1,
        previous_transcript: TranscriptSegmentV1,
        adapter: AdapterV1,
    ) Error!void {
        try validateTranscriptAdapterV1(
            adapter,
            manifest,
            plan,
        );
        try validateOverlapPlanV1(overlap_plan);
        try validateTranscriptPredecessorV1(
            overlap_plan,
            previous_transcript,
        );
        if (!std.mem.eql(
            u8,
            &plan.input_schema_sha256,
            &overlap_plan.overlap_sha256,
        ))
            return Error.InvalidTranscriptBinding;
        try self.inner.initV1(
            bank,
            owner_key,
            publication_state,
            manifest,
            plan,
            adapter,
            &transcript_support,
        );
        self.overlap_plan = overlap_plan;
        self.previous_transcript = previous_transcript;
    }

    pub fn prepareV1(
        self: *Session,
        processor_bundle: *const processor.DecodedBundleV1,
        cache_bundle: *const processor_cache.DecodedBundleV1,
        cache_session: *const processor_cache.RestoreSession,
        weights: []const u8,
        audio_cache: []const u8,
        candidate: []u8,
        visible_output: []u8,
    ) Error!model.ResultEnvelopeV1 {
        if (!self.inner.initialized)
            return Error.InvalidState;
        try validateTranscriptBindingsV1(
            self.inner.manifest,
            self.inner.plan,
            self.overlap_plan,
            self.previous_transcript,
            processor_bundle,
            cache_bundle,
            audio_cache,
        );
        try cache_session.validateActivePayloadV1(
            1,
            audio_cache,
        );
        return self.inner.prepareV1(
            weights,
            audio_cache,
            self.overlap_plan.overlap_sha256,
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
    try validateTranscriptManifestV1(manifest);
    return stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .transcribe,
        model.no_capabilities,
        implementation_sha256,
    );
}

pub fn validateTranscriptAdapterV1(
    adapter: AdapterV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
) Error!void {
    try validateTranscriptManifestV1(manifest);
    try stateless.validateAdapterForPlanV1(
        adapter,
        manifest,
        plan,
        &transcript_support,
    );
}

pub fn makeOverlapPlanV1(
    audio_state: processor.ProcessorStateV1,
    processor_bundle_sha256: Digest,
    cache_bundle_sha256: Digest,
    segment_index: u64,
    source_start_sample: u64,
    previous_transcript_sha256: Digest,
) Error!OverlapPlanV1 {
    var state_wire: [processor.processor_state_bytes]u8 =
        undefined;
    _ = try processor.encodeProcessorStateV1(
        audio_state,
        &state_wire,
    );
    if (audio_state.kind != .audio or segment_index == 0 or
        isZero(previous_transcript_sha256))
        return Error.InvalidOverlapPlan;
    const context_samples = audio_state.parameters[5];
    if (context_samples == 0)
        return Error.InvalidOverlapPlan;
    const source_end_sample = checkedAdd(
        source_start_sample,
        audio_state.cursor_units,
    ) catch return Error.InvalidOverlapPlan;
    const context_end_sample = checkedAdd(
        source_start_sample,
        context_samples,
    ) catch return Error.InvalidOverlapPlan;
    var plan: OverlapPlanV1 = .{
        .request_epoch = audio_state.request_epoch,
        .generation = audio_state.generation,
        .segment_index = segment_index,
        .source_start_sample = source_start_sample,
        .source_end_sample = source_end_sample,
        .context_start_sample = source_start_sample,
        .context_end_sample = context_end_sample,
        .publish_start_sample = context_end_sample,
        .publish_end_sample = source_end_sample,
        .sample_rate = audio_state.parameters[0],
        .window_samples = audio_state.parameters[2],
        .hop_samples = audio_state.parameters[3],
        .feature_frames = audio_state.produced_units,
        .feature_bins = audio_state.parameters[4],
        .feature_bytes = audio_state.parameters[6],
        .media_object_sha256 = audio_state.media_object_sha256,
        .processor_state_sha256 = audio_state.state_sha256,
        .processor_bundle_sha256 = processor_bundle_sha256,
        .cache_bundle_sha256 = cache_bundle_sha256,
        .cache_payload_sha256 = audio_state.cache_content_sha256,
        .ownership_sha256 = audio_state.ownership_receipt_sha256,
        .challenge_sha256 = audio_state.challenge_sha256,
        .previous_transcript_sha256 = previous_transcript_sha256,
        .overlap_sha256 = [_]u8{0} ** 32,
    };
    plan.overlap_sha256 = overlapPlanRootV1(plan);
    try validateOverlapPlanV1(plan);
    return plan;
}

pub fn encodeOverlapPlanV1(
    plan: OverlapPlanV1,
    output: *[overlap_plan_bytes]u8,
) Error![]const u8 {
    try validateOverlapPlanV1(plan);
    writeOverlapBodyV1(
        plan,
        output[0..overlap_body_bytes],
    );
    @memcpy(
        output[overlap_body_bytes..],
        &plan.overlap_sha256,
    );
    return output;
}

pub fn decodeOverlapPlanV1(
    encoded: []const u8,
) Error!OverlapPlanV1 {
    if (encoded.len != overlap_plan_bytes or
        !std.mem.eql(u8, encoded[0..8], &overlap_magic) or
        readU64(encoded, 8) != overlap_plan_abi or
        readU64(encoded, 16) != overlap_plan_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[152..160], 0) or
        !std.mem.allEqual(
            u8,
            encoded[416..overlap_body_bytes],
            0,
        ))
        return Error.InvalidOverlapPlan;
    const plan: OverlapPlanV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .segment_index = readU64(encoded, 48),
        .source_start_sample = readU64(encoded, 56),
        .source_end_sample = readU64(encoded, 64),
        .context_start_sample = readU64(encoded, 72),
        .context_end_sample = readU64(encoded, 80),
        .publish_start_sample = readU64(encoded, 88),
        .publish_end_sample = readU64(encoded, 96),
        .sample_rate = readU64(encoded, 104),
        .window_samples = readU64(encoded, 112),
        .hop_samples = readU64(encoded, 120),
        .feature_frames = readU64(encoded, 128),
        .feature_bins = readU64(encoded, 136),
        .feature_bytes = readU64(encoded, 144),
        .media_object_sha256 = encoded[160..192].*,
        .processor_state_sha256 = encoded[192..224].*,
        .processor_bundle_sha256 = encoded[224..256].*,
        .cache_bundle_sha256 = encoded[256..288].*,
        .cache_payload_sha256 = encoded[288..320].*,
        .ownership_sha256 = encoded[320..352].*,
        .challenge_sha256 = encoded[352..384].*,
        .previous_transcript_sha256 = encoded[384..416].*,
        .overlap_sha256 = encoded[overlap_body_bytes..overlap_plan_bytes].*,
    };
    try validateOverlapPlanV1(plan);
    var canonical: [overlap_plan_bytes]u8 = undefined;
    _ = try encodeOverlapPlanV1(plan, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidOverlapPlan;
    return plan;
}

pub fn validateOverlapPlanV1(
    plan: OverlapPlanV1,
) Error!void {
    const source_units = checkedSub(
        plan.source_end_sample,
        plan.source_start_sample,
    ) catch return Error.InvalidOverlapPlan;
    const context_units = checkedSub(
        plan.context_end_sample,
        plan.context_start_sample,
    ) catch return Error.InvalidOverlapPlan;
    const publish_units = checkedSub(
        plan.publish_end_sample,
        plan.publish_start_sample,
    ) catch return Error.InvalidOverlapPlan;
    const expected_source_units = checkedAdd(
        plan.window_samples,
        checkedMul(
            plan.feature_frames -| 1,
            plan.hop_samples,
        ) catch return Error.InvalidOverlapPlan,
    ) catch return Error.InvalidOverlapPlan;
    if (plan.request_epoch == 0 or plan.generation == 0 or
        plan.segment_index == 0 or plan.sample_rate == 0 or
        plan.window_samples == 0 or plan.hop_samples == 0 or
        plan.hop_samples >= plan.window_samples or
        plan.feature_frames == 0 or plan.feature_bins == 0 or
        plan.feature_bytes == 0 or
        plan.context_start_sample !=
            plan.source_start_sample or
        plan.context_end_sample !=
            plan.publish_start_sample or
        plan.publish_end_sample != plan.source_end_sample or
        context_units !=
            plan.window_samples - plan.hop_samples or
        source_units != expected_source_units or
        publish_units != source_units - context_units or
        isZero(plan.media_object_sha256) or
        isZero(plan.processor_state_sha256) or
        isZero(plan.processor_bundle_sha256) or
        isZero(plan.cache_bundle_sha256) or
        isZero(plan.cache_payload_sha256) or
        isZero(plan.ownership_sha256) or
        isZero(plan.challenge_sha256) or
        isZero(plan.previous_transcript_sha256) or
        !std.mem.eql(
            u8,
            &overlapPlanRootV1(plan),
            &plan.overlap_sha256,
        ))
        return Error.InvalidOverlapPlan;
}

pub fn overlapPlanRootV1(
    plan: OverlapPlanV1,
) Digest {
    var body: [overlap_body_bytes]u8 = undefined;
    writeOverlapBodyV1(plan, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(overlap_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn makeTranscriptSegmentV1(
    plan: OverlapPlanV1,
    text: []const u8,
) Error!TranscriptSegmentV1 {
    try validateOverlapPlanV1(plan);
    if (text.len == 0 or text.len > maximum_text_bytes)
        return Error.InvalidTranscript;
    var segment: TranscriptSegmentV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .segment_index = plan.segment_index,
        .context_start_sample = plan.context_start_sample,
        .context_end_sample = plan.context_end_sample,
        .publish_start_sample = plan.publish_start_sample,
        .publish_end_sample = plan.publish_end_sample,
        .sample_rate = plan.sample_rate,
        .text_bytes = text.len,
        .media_object_sha256 = plan.media_object_sha256,
        .processor_state_sha256 = plan.processor_state_sha256,
        .cache_payload_sha256 = plan.cache_payload_sha256,
        .overlap_sha256 = plan.overlap_sha256,
        .previous_transcript_sha256 = plan.previous_transcript_sha256,
        .text = [_]u8{0} ** maximum_text_bytes,
        .transcript_sha256 = [_]u8{0} ** 32,
    };
    @memcpy(segment.text[0..text.len], text);
    segment.transcript_sha256 =
        transcriptSegmentRootV1(segment);
    try validateTranscriptSegmentV1(segment);
    return segment;
}

pub fn encodeTranscriptSegmentV1(
    segment: TranscriptSegmentV1,
    output: *[transcript_segment_bytes]u8,
) Error![]const u8 {
    try validateTranscriptSegmentV1(segment);
    writeTranscriptBodyV1(
        segment,
        output[0..transcript_body_bytes],
    );
    @memcpy(
        output[transcript_body_bytes..],
        &segment.transcript_sha256,
    );
    return output;
}

pub fn decodeTranscriptSegmentV1(
    encoded: []const u8,
) Error!TranscriptSegmentV1 {
    if (encoded.len != transcript_segment_bytes or
        !std.mem.eql(u8, encoded[0..8], &transcript_magic) or
        readU64(encoded, 8) != transcript_segment_abi or
        readU64(encoded, 16) != transcript_segment_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[104..128], 0))
        return Error.InvalidTranscript;
    const segment: TranscriptSegmentV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .segment_index = readU64(encoded, 48),
        .context_start_sample = readU64(encoded, 56),
        .context_end_sample = readU64(encoded, 64),
        .publish_start_sample = readU64(encoded, 72),
        .publish_end_sample = readU64(encoded, 80),
        .sample_rate = readU64(encoded, 88),
        .text_bytes = readU64(encoded, 96),
        .media_object_sha256 = encoded[128..160].*,
        .processor_state_sha256 = encoded[160..192].*,
        .cache_payload_sha256 = encoded[192..224].*,
        .overlap_sha256 = encoded[224..256].*,
        .previous_transcript_sha256 = encoded[256..288].*,
        .text = encoded[288..352].*,
        .transcript_sha256 = encoded[transcript_body_bytes..transcript_segment_bytes].*,
    };
    try validateTranscriptSegmentV1(segment);
    var canonical: [transcript_segment_bytes]u8 =
        undefined;
    _ = try encodeTranscriptSegmentV1(
        segment,
        &canonical,
    );
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidTranscript;
    return segment;
}

pub fn validateTranscriptSegmentV1(
    segment: TranscriptSegmentV1,
) Error!void {
    const text_bytes = std.math.cast(
        usize,
        segment.text_bytes,
    ) orelse return Error.InvalidTranscript;
    if (segment.request_epoch == 0 or
        segment.generation == 0 or
        segment.segment_index == 0 or
        segment.sample_rate == 0 or
        segment.context_start_sample >=
            segment.context_end_sample or
        segment.context_end_sample !=
            segment.publish_start_sample or
        segment.publish_start_sample >=
            segment.publish_end_sample or
        text_bytes == 0 or text_bytes > maximum_text_bytes or
        !std.mem.allEqual(
            u8,
            segment.text[text_bytes..],
            0,
        ) or
        isZero(segment.media_object_sha256) or
        isZero(segment.processor_state_sha256) or
        isZero(segment.cache_payload_sha256) or
        isZero(segment.overlap_sha256) or
        isZero(segment.previous_transcript_sha256) or
        !std.mem.eql(
            u8,
            &transcriptSegmentRootV1(segment),
            &segment.transcript_sha256,
        ))
        return Error.InvalidTranscript;
    for (segment.text[0..text_bytes]) |byte| {
        if (byte < 0x20 or byte > 0x7e)
            return Error.InvalidTranscript;
    }
}

pub fn transcriptSegmentRootV1(
    segment: TranscriptSegmentV1,
) Digest {
    var body: [transcript_body_bytes]u8 = undefined;
    writeTranscriptBodyV1(segment, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(transcript_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn validateTranscriptPredecessorV1(
    overlap_plan: OverlapPlanV1,
    previous: TranscriptSegmentV1,
) Error!void {
    try validateOverlapPlanV1(overlap_plan);
    try validateTranscriptSegmentV1(previous);
    const next_segment = std.math.add(
        u64,
        previous.segment_index,
        1,
    ) catch return Error.InvalidTranscriptBinding;
    if (next_segment != overlap_plan.segment_index or
        previous.request_epoch != overlap_plan.request_epoch or
        previous.sample_rate != overlap_plan.sample_rate or
        previous.publish_end_sample !=
            overlap_plan.publish_start_sample or
        !std.mem.eql(
            u8,
            &previous.media_object_sha256,
            &overlap_plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &previous.transcript_sha256,
            &overlap_plan.previous_transcript_sha256,
        ))
        return Error.InvalidTranscriptBinding;
}

pub fn transcriptSchemaRootV1() Digest {
    return model.sha256(
        "glacier audio transcript segment v1 384-byte wire",
    );
}

pub fn validateTranscriptBindingsV1(
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    overlap_plan: OverlapPlanV1,
    previous_transcript: TranscriptSegmentV1,
    processor_bundle: *const processor.DecodedBundleV1,
    cache_bundle: *const processor_cache.DecodedBundleV1,
    audio_cache: []const u8,
) Error!void {
    try validateTranscriptManifestV1(manifest);
    try validateOverlapPlanV1(overlap_plan);
    try validateTranscriptPredecessorV1(
        overlap_plan,
        previous_transcript,
    );
    const audio_state = processor_bundle.states[1];
    processor_cache.validateBindingV1(
        cache_bundle,
        processor_bundle,
        processor_bundle.bundle_sha256,
    ) catch return Error.InvalidTranscriptBinding;
    const input_features = std.math.cast(
        u64,
        audio_cache.len / @sizeOf(i16),
    ) orelse return Error.InvalidTranscriptBinding;
    if (audio_cache.len % @sizeOf(i16) != 0 or
        audio_state.kind != .audio or
        audio_state.parameters[5] == 0 or
        plan.family != .audio_understanding or
        plan.operation != .transcribe or
        plan.input_kind != .audio_feature_i16 or
        plan.output_kind != .transcript or
        plan.numerical_policy != .exact_integer or
        plan.request_epoch != audio_state.request_epoch or
        plan.generation != audio_state.generation or
        plan.batch_items != 1 or
        plan.input_features != input_features or
        plan.output_dimensions != transcript_segment_bytes or
        plan.output_element_bytes != @sizeOf(u8) or
        plan.input_element_bytes != @sizeOf(i16) or
        audioCacheBytesV1(audio_state) !=
            audio_state.cache_bytes or
        audio_cache.len != plan.input_bytes or
        !std.mem.eql(u8, audio_cache, cache_bundle.payloads[1]) or
        !std.mem.eql(
            u8,
            &model.sha256(audio_cache),
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &audio_state.cache_content_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.media_object_sha256,
            &plan.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.processor_state_sha256,
            &plan.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.processor_bundle_sha256,
            &plan.processor_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.cache_bundle_sha256,
            &plan.cache_bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.cache_payload_sha256,
            &plan.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.ownership_sha256,
            &plan.ownership_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.challenge_sha256,
            &plan.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap_plan.overlap_sha256,
            &plan.input_schema_sha256,
        ) or
        !std.mem.eql(
            u8,
            &transcriptSchemaRootV1(),
            &plan.output_schema_sha256,
        ) or
        overlap_plan.request_epoch != audio_state.request_epoch or
        overlap_plan.generation != audio_state.generation or
        overlap_plan.sample_rate != audio_state.parameters[0] or
        overlap_plan.window_samples != audio_state.parameters[2] or
        overlap_plan.hop_samples != audio_state.parameters[3] or
        overlap_plan.feature_frames != audio_state.produced_units or
        overlap_plan.feature_bins != audio_state.parameters[4] or
        overlap_plan.feature_bytes != audio_state.parameters[6] or
        overlap_plan.source_end_sample -
            overlap_plan.source_start_sample !=
            audio_state.cursor_units or
        manifest.input_features != plan.input_features or
        manifest.output_dimensions != plan.output_dimensions or
        plan.scratch_bytes != plan.output_bytes or
        plan.claim.capsule_bytes != plan.weight_bytes or
        plan.claim.activation_bytes != plan.input_bytes or
        plan.claim.partial_bytes != plan.scratch_bytes or
        plan.claim.output_journal_bytes != plan.output_bytes or
        plan.claim.queue_slots != 1 or plan.claim.kv_bytes != 0 or
        plan.claim.logits_bytes != 0 or
        plan.claim.staging_bytes != 0 or
        plan.claim.device_bytes != 0 or plan.claim.io_bytes != 0)
        return Error.InvalidTranscriptBinding;
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
    if (weights.len != 1 or weights[0] != 0x54 or
        input.len != plan.input_bytes or
        candidate.len != transcript_segment_bytes or
        !std.mem.eql(
            u8,
            &model.sha256(input),
            &plan.cache_payload_sha256,
        ))
        return Error.InvalidTranscriptBinding;
    const segment = try makeTranscriptSegmentV1(
        reference.overlap_plan,
        "ice",
    );
    var encoded: [transcript_segment_bytes]u8 =
        undefined;
    _ = try encodeTranscriptSegmentV1(
        segment,
        &encoded,
    );
    @memcpy(candidate, &encoded);
}

pub fn validateCandidateV1(
    context: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    const reference: *const ReferenceContextV1 =
        @ptrCast(@alignCast(context));
    const segment = try decodeTranscriptSegmentV1(
        candidate,
    );
    const text_bytes = std.math.cast(
        usize,
        segment.text_bytes,
    ) orelse return Error.InvalidTranscript;
    if (segment.request_epoch != plan.request_epoch or
        segment.generation != plan.generation or
        segment.segment_index !=
            reference.overlap_plan.segment_index or
        segment.context_start_sample !=
            reference.overlap_plan.context_start_sample or
        segment.context_end_sample !=
            reference.overlap_plan.context_end_sample or
        segment.publish_start_sample !=
            reference.overlap_plan.publish_start_sample or
        segment.publish_end_sample !=
            reference.overlap_plan.publish_end_sample or
        !std.mem.eql(
            u8,
            &segment.overlap_sha256,
            &reference.overlap_plan.overlap_sha256,
        ) or
        !std.mem.eql(
            u8,
            &segment.previous_transcript_sha256,
            &reference.overlap_plan.previous_transcript_sha256,
        ) or
        !std.mem.eql(u8, segment.text[0..text_bytes], "ice"))
        return Error.InvalidTranscript;
}

fn validateTranscriptManifestV1(
    manifest: model.ArtifactManifestV1,
) Error!void {
    if (manifest.family != .audio_understanding or
        manifest.input_kind != .audio_feature_i16 or
        manifest.output_kind != .transcript or
        manifest.numerical_policy != .exact_integer or
        manifest.max_batch_items != 1 or
        manifest.output_dimensions !=
            transcript_segment_bytes or
        manifest.input_element_bytes != @sizeOf(i16) or
        manifest.output_element_bytes != @sizeOf(u8) or
        manifest.weight_element_bytes != @sizeOf(u8) or
        manifest.weight_elements != 1 or
        manifest.weight_bytes != 1)
        return Error.InvalidTranscriptBinding;
}

fn audioCacheBytesV1(
    state: processor.ProcessorStateV1,
) u64 {
    const feature_bytes = checkedMul(
        checkedMul(
            state.produced_units,
            state.parameters[4],
        ) catch return std.math.maxInt(u64),
        state.parameters[6],
    ) catch return std.math.maxInt(u64);
    const context_bytes = checkedMul(
        checkedMul(
            state.parameters[5],
            state.parameters[1],
        ) catch return std.math.maxInt(u64),
        @sizeOf(i16),
    ) catch return std.math.maxInt(u64);
    return checkedAdd(
        feature_bytes,
        context_bytes,
    ) catch std.math.maxInt(u64);
}

fn writeOverlapBodyV1(
    plan: OverlapPlanV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &overlap_magic);
    writeU64(output, 8, overlap_plan_abi);
    writeU64(output, 16, overlap_plan_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        plan.request_epoch,
        plan.generation,
        plan.segment_index,
        plan.source_start_sample,
        plan.source_end_sample,
        plan.context_start_sample,
        plan.context_end_sample,
        plan.publish_start_sample,
        plan.publish_end_sample,
        plan.sample_rate,
        plan.window_samples,
        plan.hop_samples,
        plan.feature_frames,
        plan.feature_bins,
        plan.feature_bytes,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        plan.media_object_sha256,
        plan.processor_state_sha256,
        plan.processor_bundle_sha256,
        plan.cache_bundle_sha256,
        plan.cache_payload_sha256,
        plan.ownership_sha256,
        plan.challenge_sha256,
        plan.previous_transcript_sha256,
    };
    for (digests, 0..) |digest, index|
        @memcpy(
            output[160 + index * 32 .. 192 + index * 32],
            &digest,
        );
}

fn writeTranscriptBodyV1(
    segment: TranscriptSegmentV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &transcript_magic);
    writeU64(output, 8, transcript_segment_abi);
    writeU64(output, 16, transcript_segment_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        segment.request_epoch,
        segment.generation,
        segment.segment_index,
        segment.context_start_sample,
        segment.context_end_sample,
        segment.publish_start_sample,
        segment.publish_end_sample,
        segment.sample_rate,
        segment.text_bytes,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        segment.media_object_sha256,
        segment.processor_state_sha256,
        segment.cache_payload_sha256,
        segment.overlap_sha256,
        segment.previous_transcript_sha256,
    };
    for (digests, 0..) |digest, index|
        @memcpy(
            output[128 + index * 32 .. 160 + index * 32],
            &digest,
        );
    @memcpy(output[288..352], &segment.text);
}

fn checkedAdd(a: u64, b: u64) !u64 {
    return std.math.add(u64, a, b);
}

fn checkedSub(a: u64, b: u64) !u64 {
    return std.math.sub(u64, a, b);
}

fn checkedMul(a: u64, b: u64) !u64 {
    return std.math.mul(u64, a, b);
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

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

const TestFixture = struct {
    processor_storage: [processor.processor_bundle_bytes]u8,
    cache_storage: [
        processor_cache.cache_payload_offset + 15 +
            processor_cache.cache_bundle_footer_bytes
    ]u8,
    processor_bundle: processor.DecodedBundleV1,
    cache_bundle: processor_cache.DecodedBundleV1,
    overlap_plan: OverlapPlanV1,
    previous_transcript: TranscriptSegmentV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    publication_state: model.PublicationStateV1,
    weights: [1]u8,
    image_cache: [2]u8,
    audio_cache: [12]u8,
    video_cache: [1]u8,

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
        var audio_cache: [12]u8 = undefined;
        inline for (
            [_]i16{ 100, 200, -300, 400, -10, 10 },
            0..,
        ) |value, index|
            std.mem.writeInt(
                i16,
                audio_cache[index * 2 .. index * 2 + 2][0..2],
                value,
                .little,
            );
        const video_cache = [_]u8{3};
        const request_epoch: u64 = 221;
        const generation: u64 = 4;
        const challenge = model.sha256(
            "audio transcript challenge",
        );
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
                .denominator = 16_000,
            },
            .media_object_sha256 = model.sha256("transcript audio media"),
            .processor_plan_sha256 = model.sha256("overlap feature processor"),
            .previous_state_sha256 = model.sha256("previous overlap state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&audio_cache),
            .output_chain_sha256 = model.sha256("previous audio output chain"),
            .ownership_receipt_sha256 = model.sha256("overlap audio ownership"),
            .decoder_state_sha256 = model.sha256("overlap audio decoder"),
        }, 2, 16_000, 1, 4, 2, 2, 2);
        const video_state = try processor.makeVideoStateV1(.{
            .kind = .video,
            .request_epoch = request_epoch,
            .generation = generation,
            .stream_key = 41_003,
            .timeline_base = .{
                .numerator = 1,
                .denominator = 48_000,
            },
            .media_object_sha256 = model.sha256("video media"),
            .processor_plan_sha256 = model.sha256("video processor"),
            .previous_state_sha256 = model.sha256("previous video state"),
            .challenge_sha256 = challenge,
            .cache_content_sha256 = model.sha256(&video_cache),
            .output_chain_sha256 = model.sha256("video output"),
            .ownership_receipt_sha256 = model.sha256("video ownership"),
            .decoder_state_sha256 = model.sha256("video decoder"),
        }, 1, 1, 0, 1, 0);
        const states = [_]processor.ProcessorStateV1{
            image_state,
            audio_state,
            video_state,
        };
        const sync = try processor.makeSyncStateV1(states, .{
            .generation = generation,
            .request_epoch = request_epoch,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 24,
            .challenge_sha256 = challenge,
            .sync_policy_sha256 = model.sha256("transcript sync policy"),
            .previous_sync_sha256 = model.sha256("previous transcript sync"),
        });
        var processor_storage: [processor.processor_bundle_bytes]u8 = undefined;
        _ = try processor.encodeBundleV1(
            states,
            sync,
            &processor_storage,
        );
        const processor_bundle =
            try processor.decodeBundleV1(
                &processor_storage,
            );
        var cache_storage: [
            processor_cache.cache_payload_offset + 15 +
                processor_cache.cache_bundle_footer_bytes
        ]u8 =
            undefined;
        _ = try processor_cache.encodeBundleV1(
            processor_bundle,
            .{
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .previous_cache_bundle_sha256 = model.sha256(
                    "previous transcript cache bundle",
                ),
                .source_bank_epoch = 210,
                .restore_bank_epoch = 211,
                .restore_owner_key_base = 42_000,
                .restore_tree_key_base = 43_000,
                .restore_authority_key_base = 44_000,
                .tenant_key = 45_000,
                .publication_next_sequence = 2,
            },
            .{ &image_cache, &audio_cache, &video_cache },
            &cache_storage,
        );
        const cache_bundle =
            try processor_cache.decodeBundleV1(
                &cache_storage,
            );
        const previous_overlap = try makeOverlapPlanV1(
            audio_state,
            processor_bundle.bundle_sha256,
            cache_bundle.bundle_sha256,
            1,
            0,
            model.sha256("transcript genesis"),
        );
        const previous_transcript =
            try makeTranscriptSegmentV1(
                previous_overlap,
                "snow",
            );
        const overlap_plan = try makeOverlapPlanV1(
            audio_state,
            processor_bundle.bundle_sha256,
            cache_bundle.bundle_sha256,
            2,
            4,
            previous_transcript.transcript_sha256,
        );
        const weights = [_]u8{0x54};
        const manifest = try model.makeArtifactManifestV1(
            .audio_understanding,
            0x4154_524e_0000_0001,
            .audio_feature_i16,
            .transcript,
            .exact_integer,
            1,
            audio_cache.len / @sizeOf(i16),
            transcript_segment_bytes,
            @sizeOf(i16),
            @sizeOf(u8),
            @sizeOf(u8),
            &weights,
            model.sha256("transcript fixture metadata"),
            model.sha256("fixture-only license"),
        );
        const claim: resource_bank.Claim = .{
            .capsule_bytes = weights.len,
            .activation_bytes = audio_cache.len,
            .partial_bytes = transcript_segment_bytes,
            .output_journal_bytes = transcript_segment_bytes,
            .queue_slots = 1,
        };
        const plan = try model.makeExecutionPlanV1(
            manifest,
            .transcribe,
            .{
                .request_epoch = request_epoch,
                .generation = generation,
                .batch_items = 1,
                .publication_next_sequence = 1,
                .maximum_absolute_output = 0x7f,
                .claim = claim,
                .media_object_sha256 = audio_state.media_object_sha256,
                .processor_state_sha256 = audio_state.state_sha256,
                .processor_bundle_sha256 = processor_bundle.bundle_sha256,
                .cache_bundle_sha256 = cache_bundle.bundle_sha256,
                .cache_payload_sha256 = audio_state.cache_content_sha256,
                .ownership_sha256 = audio_state.ownership_receipt_sha256,
                .challenge_sha256 = challenge,
                .previous_plan_sha256 = model.sha256("previous transcript plan"),
                .input_schema_sha256 = overlap_plan.overlap_sha256,
                .output_schema_sha256 = transcriptSchemaRootV1(),
                .scratch_bytes = transcript_segment_bytes,
            },
        );
        const publication_state: model.PublicationStateV1 = .{
            .request_epoch = request_epoch,
            .next_sequence = 1,
            .visible_results = 1,
            .artifact_sha256 = manifest.artifact_sha256,
            .previous_result_sha256 = model.sha256("previous transcript result"),
        };
        _ = try model.publicationStateRootV1(
            publication_state,
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
        value.overlap_plan = overlap_plan;
        value.previous_transcript =
            previous_transcript;
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
                "reference exact audio transcript v1",
            ),
        ),
        .execute_fn = referenceExecuteV1,
        .validate_candidate_fn = validateCandidateV1,
    };
}

test "overlap and transcript wires are canonical and mutation complete" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var overlap_wire: [overlap_plan_bytes]u8 =
        undefined;
    _ = try encodeOverlapPlanV1(
        fixture.overlap_plan,
        &overlap_wire,
    );
    try std.testing.expectEqual(
        fixture.overlap_plan,
        try decodeOverlapPlanV1(&overlap_wire),
    );
    const segment = try makeTranscriptSegmentV1(
        fixture.overlap_plan,
        "ice",
    );
    var transcript_wire: [transcript_segment_bytes]u8 =
        undefined;
    _ = try encodeTranscriptSegmentV1(
        segment,
        &transcript_wire,
    );
    var expected_overlap: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_overlap,
        "4747e104ce7b0a7b09f270ca72ad04bb" ++
            "cde759c67f858df710eefe75c1242635",
    );
    var expected_transcript: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_transcript,
        "062bd3166b979591f4ba9771606b6284" ++
            "b00ce7edc93378674cdeb1747597c625",
    );
    try std.testing.expectEqual(
        expected_overlap,
        fixture.overlap_plan.overlap_sha256,
    );
    try std.testing.expectEqual(
        expected_transcript,
        segment.transcript_sha256,
    );
    try std.testing.expectEqual(
        segment,
        try decodeTranscriptSegmentV1(&transcript_wire),
    );
    for (0..overlap_wire.len) |index| {
        var mutated = overlap_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidOverlapPlan,
            decodeOverlapPlanV1(&mutated),
        );
    }
    for (0..transcript_wire.len) |index| {
        var mutated = transcript_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidTranscript,
            decodeTranscriptSegmentV1(&mutated),
        );
    }
}

test "overlap context publishes only the new transcript range" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var storage: TestRuntime = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
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
        .overlap_plan = fixture.overlap_plan,
    };
    const adapter = try testAdapter(&fixture, &context);
    var session: Session = .{};
    try session.initV1(
        &bank,
        46_000,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        fixture.overlap_plan,
        fixture.previous_transcript,
        adapter,
    );
    var candidate: [transcript_segment_bytes]u8 = undefined;
    var output: [transcript_segment_bytes]u8 = undefined;
    const prepared = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.audio_cache,
        &candidate,
        &output,
    );
    try std.testing.expectEqual(
        fixture.overlap_plan.overlap_sha256,
        prepared.source_mapping_sha256,
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const private_segment =
        try decodeTranscriptSegmentV1(&candidate);
    try std.testing.expectEqual(
        @as(u64, 4),
        private_segment.context_start_sample,
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        private_segment.context_end_sample,
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        private_segment.publish_start_sample,
    );
    try std.testing.expectEqual(
        @as(u64, 10),
        private_segment.publish_end_sample,
    );
    try std.testing.expectEqualSlices(
        u8,
        "ice",
        private_segment.text[0..3],
    );
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    const visible_segment =
        try decodeTranscriptSegmentV1(&output);
    try std.testing.expectEqual(
        private_segment,
        visible_segment,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        fixture.publication_state.visible_results,
    );
    try session.closeAndRelease();
    try cache_session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "transcript abort drift and foreign overlap preserve publication" {
    var fixture = try TestFixture.init();
    try fixture.rebind();
    var foreign_overlap = fixture.overlap_plan;
    foreign_overlap.previous_transcript_sha256 =
        model.sha256("foreign transcript predecessor");
    foreign_overlap.overlap_sha256 =
        overlapPlanRootV1(foreign_overlap);
    try std.testing.expectError(
        Error.InvalidTranscriptBinding,
        validateTranscriptBindingsV1(
            fixture.manifest,
            fixture.plan,
            foreign_overlap,
            fixture.previous_transcript,
            &fixture.processor_bundle,
            &fixture.cache_bundle,
            &fixture.audio_cache,
        ),
    );
    const foreign_previous = try makeTranscriptSegmentV1(
        try makeOverlapPlanV1(
            fixture.processor_bundle.states[1],
            fixture.processor_bundle.bundle_sha256,
            fixture.cache_bundle.bundle_sha256,
            1,
            0,
            model.sha256("transcript genesis"),
        ),
        "rain",
    );
    try std.testing.expectError(
        Error.InvalidTranscriptBinding,
        validateTranscriptPredecessorV1(
            fixture.overlap_plan,
            foreign_previous,
        ),
    );
    var foreign_cache = fixture.audio_cache;
    foreign_cache[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidTranscriptBinding,
        validateTranscriptBindingsV1(
            fixture.manifest,
            fixture.plan,
            fixture.overlap_plan,
            fixture.previous_transcript,
            &fixture.processor_bundle,
            &fixture.cache_bundle,
            &foreign_cache,
        ),
    );

    var storage: TestRuntime = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
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
        .overlap_plan = fixture.overlap_plan,
    };
    const adapter = try testAdapter(&fixture, &context);
    var session: Session = .{};
    try session.initV1(
        &bank,
        46_001,
        &fixture.publication_state,
        fixture.manifest,
        fixture.plan,
        fixture.overlap_plan,
        fixture.previous_transcript,
        adapter,
    );
    var candidate: [transcript_segment_bytes]u8 = undefined;
    var output: [transcript_segment_bytes]u8 = undefined;
    _ = try session.prepareV1(
        &fixture.processor_bundle,
        &fixture.cache_bundle,
        &cache_session,
        &fixture.weights,
        &fixture.audio_cache,
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
        &fixture.audio_cache,
        &candidate,
        &output,
    );
    candidate[288] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
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
