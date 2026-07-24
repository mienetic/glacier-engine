const std = @import("std");
const media = @import("media_contract.zig");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;

pub const state_abi: u64 = 1;
pub const state_body_bytes: usize = 416;
pub const state_bytes: usize = state_body_bytes + 32;
const state_magic = [_]u8{ 'G', 'L', 'A', 'U', 'D', 'S', 'T', '1' };
const state_domain = "glacier.generated-audio-state.v1";

pub const plan_abi: u64 = 1;
pub const plan_body_bytes: usize = 544;
pub const plan_bytes: usize = plan_body_bytes + 32;
const plan_magic = [_]u8{ 'G', 'L', 'A', 'U', 'D', 'P', 'L', '1' };
const plan_domain = "glacier.generated-audio-plan.v1";

pub const provenance_abi: u64 = 1;
pub const provenance_body_bytes: usize = 480;
pub const provenance_bytes: usize = provenance_body_bytes + 32;
const provenance_magic = [_]u8{ 'G', 'L', 'A', 'U', 'D', 'P', 'V', '1' };
const provenance_domain = "glacier.generated-audio-provenance.v1";

pub const result_abi: u64 = 1;
pub const result_body_bytes: usize = 544;
pub const result_bytes: usize = result_body_bytes + 32;
const result_magic = [_]u8{ 'G', 'L', 'A', 'U', 'D', 'R', 'S', '1' };
const result_domain = "glacier.generated-audio-result.v1";

pub const observation_abi: u64 = 1;
pub const observation_body_bytes: usize = 256;
pub const observation_bytes: usize = observation_body_bytes + 32;
const observation_magic = [_]u8{ 'G', 'L', 'A', 'U', 'D', 'O', 'B', '1' };
const observation_domain = "glacier.playback-observation.v1";

pub const ack_plan_abi: u64 = 1;
pub const ack_plan_body_bytes: usize = 416;
pub const ack_plan_bytes: usize = ack_plan_body_bytes + 32;
const ack_plan_magic = [_]u8{ 'G', 'L', 'A', 'U', 'D', 'A', 'P', '1' };
const ack_plan_domain = "glacier.playback-ack-plan.v1";

pub const ack_result_abi: u64 = 1;
pub const ack_result_body_bytes: usize = 480;
pub const ack_result_bytes: usize = ack_result_body_bytes + 32;
const ack_result_magic = [_]u8{ 'G', 'L', 'A', 'U', 'D', 'A', 'R', '1' };
const ack_result_domain = "glacier.playback-ack-result.v1";

const resource_domain = "glacier.generated-audio-resource.v1";
const media_provenance_domain = "glacier.generated-audio-media-provenance.v1";
const allowed_flags: u64 = 0;

pub const runtime_abi: u64 = 1;
pub const pcm_s16le_semantic_abi: u64 = 1;
pub const raw_audio_container_id: u64 = 1;
pub const pcm_s16le_codec_id: u64 = 1;
pub const reference_renderer_abi: u64 = 1;
pub const reference_renderer_payload = "pcm-s16le-v1";
pub const maximum_frames_per_chunk: u64 = 4096;
pub const maximum_channels: u64 = 64;
pub const maximum_sample_rate: u64 = 768_000;
pub const maximum_source_bytes: u64 =
    maximum_frames_per_chunk * maximum_channels * 8;
pub const maximum_pcm_bytes: u64 =
    maximum_frames_per_chunk * maximum_channels * 2;

pub const Error = error{
    InvalidState,
    InvalidStateRoot,
    InvalidPlan,
    InvalidPlanRoot,
    InvalidProvenance,
    InvalidProvenanceRoot,
    InvalidResult,
    InvalidResultRoot,
    InvalidObservation,
    InvalidObservationRoot,
    InvalidAckPlan,
    InvalidAckPlanRoot,
    InvalidAckResult,
    InvalidAckResultRoot,
    InvalidWire,
    InvalidBinding,
    InvalidMedia,
    ArithmeticOverflow,
    BufferTooSmall,
    BufferAlias,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
    CandidateInvalid,
    CandidateDrift,
    PlaybackPending,
    NoPlaybackPending,
};

pub const GeneratedAudioStateV1 = struct {
    request_epoch: u64,
    generation: u64,
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    next_chunk_index: u64,
    next_start_frame: u64,
    visible_chunks: u64,
    visible_frames: u64,
    acknowledged_chunks: u64,
    acknowledged_frames: u64,
    playback_sequence: u64,
    pending: u64,
    pending_chunk_index: u64,
    pending_start_frame: u64,
    pending_frame_count: u64,
    artifact_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    previous_publication_result_sha256: Digest,
    previous_ack_result_sha256: Digest,
    pending_publication_result_sha256: Digest,
    pending_output_sha256: Digest,
    challenge_sha256: Digest,
    state_sha256: Digest,
};

pub const GeneratedAudioPlanV1 = struct {
    request_epoch: u64,
    generation: u64,
    chunk_index: u64,
    start_frame: u64,
    frame_count: u64,
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    source_output_bytes: u64,
    pcm_bytes: u64,
    maximum_output_bytes: u64,
    publication_sequence: u64,
    visible_chunks_before: u64,
    visible_chunks_after: u64,
    visible_frames_before: u64,
    visible_frames_after: u64,
    logical_units: u64,
    required_capabilities: u64,
    renderer_abi: u64,
    artifact_sha256: Digest,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_payload_sha256: Digest,
    renderer_implementation_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    previous_publication_result_sha256: Digest,
    media_object_sha256: Digest,
    state_before_sha256: Digest,
    plan_sha256: Digest,
};

pub const GeneratedAudioProvenanceV1 = struct {
    request_epoch: u64,
    generation: u64,
    chunk_index: u64,
    start_frame: u64,
    frame_count: u64,
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    source_output_bytes: u64,
    pcm_bytes: u64,
    renderer_abi: u64,
    plan_sha256: Digest,
    artifact_sha256: Digest,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_payload_sha256: Digest,
    renderer_implementation_sha256: Digest,
    media_object_sha256: Digest,
    output_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    provenance_sha256: Digest,
};

pub const GeneratedAudioResultV1 = struct {
    request_epoch: u64,
    generation: u64,
    chunk_index: u64,
    start_frame: u64,
    frame_count: u64,
    end_frame: u64,
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    source_output_bytes: u64,
    pcm_bytes: u64,
    publication_sequence: u64,
    visible_chunks_before: u64,
    visible_chunks_after: u64,
    visible_frames_before: u64,
    visible_frames_after: u64,
    plan_sha256: Digest,
    provenance_sha256: Digest,
    artifact_sha256: Digest,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    media_object_sha256: Digest,
    output_sha256: Digest,
    resource_receipt_sha256: Digest,
    state_before_sha256: Digest,
    previous_publication_result_sha256: Digest,
    renderer_implementation_sha256: Digest,
    challenge_sha256: Digest,
    result_sha256: Digest,
};

pub const PlaybackObservationV1 = struct {
    request_epoch: u64,
    playback_sequence: u64,
    chunk_index: u64,
    start_frame: u64,
    frame_count: u64,
    consumed_frames: u64,
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    output_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    challenge_sha256: Digest,
    observation_sha256: Digest,
};

pub const PlaybackAckPlanV1 = struct {
    request_epoch: u64,
    generation: u64,
    playback_sequence: u64,
    chunk_index: u64,
    start_frame: u64,
    frame_count: u64,
    end_frame: u64,
    consumed_frames: u64,
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    acknowledged_chunks_before: u64,
    acknowledged_chunks_after: u64,
    acknowledged_frames_before: u64,
    acknowledged_frames_after: u64,
    state_before_sha256: Digest,
    publication_result_sha256: Digest,
    output_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    observation_sha256: Digest,
    previous_ack_result_sha256: Digest,
    challenge_sha256: Digest,
    plan_sha256: Digest,
};

pub const PlaybackAckResultV1 = struct {
    request_epoch: u64,
    generation: u64,
    playback_sequence: u64,
    chunk_index: u64,
    start_frame: u64,
    frame_count: u64,
    end_frame: u64,
    consumed_frames: u64,
    sample_rate: u64,
    channels: u64,
    bytes_per_sample: u64,
    acknowledged_chunks_before: u64,
    acknowledged_chunks_after: u64,
    acknowledged_frames_before: u64,
    acknowledged_frames_after: u64,
    plan_sha256: Digest,
    state_before_sha256: Digest,
    publication_result_sha256: Digest,
    output_sha256: Digest,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
    observation_sha256: Digest,
    previous_publication_result_sha256: Digest,
    previous_ack_result_sha256: Digest,
    challenge_sha256: Digest,
    result_sha256: Digest,
};

pub const RendererV1 = struct {
    renderer_abi: u64,
    maximum_source_bytes: u64,
    maximum_output_bytes: u64,
    required_capabilities: u64,
    implementation_sha256: Digest,
    context: *anyopaque,
    execute: *const fn (
        context: *anyopaque,
        plan: *const GeneratedAudioPlanV1,
        source_output: []const u8,
        renderer_payload: []const u8,
        candidate_output: []u8,
    ) anyerror!void,
    validate: *const fn (
        context: *anyopaque,
        plan: *const GeneratedAudioPlanV1,
        source_output: []const u8,
        renderer_payload: []const u8,
        candidate_output: []const u8,
    ) anyerror!void,
};

pub const Phase = enum {
    idle,
    prepared,
    poisoned,
    closed,
};

pub fn makeInitialStateV1(
    request_epoch: u64,
    sample_rate: u64,
    channels: u64,
    artifact_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
) Error!GeneratedAudioStateV1 {
    var state = GeneratedAudioStateV1{
        .request_epoch = request_epoch,
        .generation = 0,
        .sample_rate = sample_rate,
        .channels = channels,
        .bytes_per_sample = 2,
        .next_chunk_index = 0,
        .next_start_frame = 0,
        .visible_chunks = 0,
        .visible_frames = 0,
        .acknowledged_chunks = 0,
        .acknowledged_frames = 0,
        .playback_sequence = 0,
        .pending = 0,
        .pending_chunk_index = 0,
        .pending_start_frame = 0,
        .pending_frame_count = 0,
        .artifact_sha256 = artifact_sha256,
        .tenant_scope_sha256 = tenant_scope_sha256,
        .metadata_policy_sha256 = metadata_policy_sha256,
        .previous_publication_result_sha256 = [_]u8{0} ** 32,
        .previous_ack_result_sha256 = [_]u8{0} ** 32,
        .pending_publication_result_sha256 = [_]u8{0} ** 32,
        .pending_output_sha256 = [_]u8{0} ** 32,
        .challenge_sha256 = challenge_sha256,
        .state_sha256 = [_]u8{0} ** 32,
    };
    state.state_sha256 = stateRootV1(state);
    try validateStateV1(state);
    return state;
}

pub fn validateStateV1(state: GeneratedAudioStateV1) Error!void {
    if (state.request_epoch == 0 or
        state.sample_rate == 0 or
        state.sample_rate > maximum_sample_rate or
        state.channels == 0 or
        state.channels > maximum_channels or
        state.bytes_per_sample != 2 or
        isZero(state.artifact_sha256) or
        isZero(state.tenant_scope_sha256) or
        isZero(state.metadata_policy_sha256) or
        isZero(state.challenge_sha256))
        return Error.InvalidState;
    if (state.next_chunk_index != state.visible_chunks or
        state.next_start_frame != state.visible_frames or
        state.acknowledged_chunks > state.visible_chunks or
        state.acknowledged_frames > state.visible_frames or
        state.playback_sequence != state.acknowledged_chunks or
        state.pending > 1)
        return Error.InvalidState;
    if (state.pending == 0) {
        if (state.acknowledged_chunks != state.visible_chunks or
            state.acknowledged_frames != state.visible_frames or
            state.pending_chunk_index != 0 or
            state.pending_start_frame != 0 or
            state.pending_frame_count != 0 or
            !isZero(state.pending_publication_result_sha256) or
            !isZero(state.pending_output_sha256))
            return Error.InvalidState;
    } else {
        const expected_visible_chunks = checkedAdd(
            state.acknowledged_chunks,
            1,
        ) catch return Error.InvalidState;
        const expected_visible_frames = checkedAdd(
            state.acknowledged_frames,
            state.pending_frame_count,
        ) catch return Error.InvalidState;
        if (state.pending_frame_count == 0 or
            state.visible_chunks != expected_visible_chunks or
            state.visible_frames != expected_visible_frames or
            state.pending_chunk_index != state.acknowledged_chunks or
            state.pending_start_frame != state.acknowledged_frames or
            isZero(state.pending_publication_result_sha256) or
            isZero(state.pending_output_sha256))
            return Error.InvalidState;
    }
    if (!digestEqual(state.state_sha256, stateRootV1(state)))
        return Error.InvalidStateRoot;
}

pub fn makePlanV1(
    state: GeneratedAudioStateV1,
    frame_count: u64,
    source_output_bytes: u64,
    maximum_output_bytes: u64,
    required_capabilities: u64,
    renderer_abi: u64,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_payload_sha256: Digest,
    renderer_implementation_sha256: Digest,
    media_object_sha256: Digest,
) Error!GeneratedAudioPlanV1 {
    try validateStateV1(state);
    if (state.pending != 0)
        return Error.PlaybackPending;
    const sample_count = try checkedMul(frame_count, state.channels);
    const pcm_bytes = try checkedMul(sample_count, state.bytes_per_sample);
    const visible_frames_after = try checkedAdd(
        state.visible_frames,
        frame_count,
    );
    var plan = GeneratedAudioPlanV1{
        .request_epoch = state.request_epoch,
        .generation = try checkedAdd(state.generation, 1),
        .chunk_index = state.next_chunk_index,
        .start_frame = state.next_start_frame,
        .frame_count = frame_count,
        .sample_rate = state.sample_rate,
        .channels = state.channels,
        .bytes_per_sample = state.bytes_per_sample,
        .source_output_bytes = source_output_bytes,
        .pcm_bytes = pcm_bytes,
        .maximum_output_bytes = maximum_output_bytes,
        .publication_sequence = state.next_chunk_index,
        .visible_chunks_before = state.visible_chunks,
        .visible_chunks_after = try checkedAdd(
            state.visible_chunks,
            1,
        ),
        .visible_frames_before = state.visible_frames,
        .visible_frames_after = visible_frames_after,
        .logical_units = sample_count,
        .required_capabilities = required_capabilities,
        .renderer_abi = renderer_abi,
        .artifact_sha256 = state.artifact_sha256,
        .source_result_sha256 = source_result_sha256,
        .source_output_sha256 = source_output_sha256,
        .renderer_payload_sha256 = renderer_payload_sha256,
        .renderer_implementation_sha256 = renderer_implementation_sha256,
        .tenant_scope_sha256 = state.tenant_scope_sha256,
        .metadata_policy_sha256 = state.metadata_policy_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .previous_publication_result_sha256 = state.previous_publication_result_sha256,
        .media_object_sha256 = media_object_sha256,
        .state_before_sha256 = state.state_sha256,
        .plan_sha256 = [_]u8{0} ** 32,
    };
    plan.plan_sha256 = planRootV1(plan);
    try validatePlanV1(plan);
    return plan;
}

pub fn validatePlanV1(plan: GeneratedAudioPlanV1) Error!void {
    const sample_count = checkedMul(
        plan.frame_count,
        plan.channels,
    ) catch return Error.InvalidPlan;
    const pcm_bytes = checkedMul(
        sample_count,
        plan.bytes_per_sample,
    ) catch return Error.InvalidPlan;
    const visible_chunks_after = checkedAdd(
        plan.visible_chunks_before,
        1,
    ) catch return Error.InvalidPlan;
    const visible_frames_after = checkedAdd(
        plan.visible_frames_before,
        plan.frame_count,
    ) catch return Error.InvalidPlan;
    if (plan.request_epoch == 0 or plan.generation == 0 or
        plan.frame_count == 0 or
        plan.frame_count > maximum_frames_per_chunk or
        plan.sample_rate == 0 or
        plan.sample_rate > maximum_sample_rate or
        plan.channels == 0 or
        plan.channels > maximum_channels or
        plan.bytes_per_sample != 2 or
        plan.source_output_bytes == 0 or
        plan.source_output_bytes > maximum_source_bytes or
        plan.pcm_bytes == 0 or
        plan.pcm_bytes > maximum_pcm_bytes or
        plan.pcm_bytes != pcm_bytes or
        plan.maximum_output_bytes < plan.pcm_bytes or
        plan.maximum_output_bytes > maximum_pcm_bytes or
        plan.publication_sequence != plan.chunk_index or
        plan.visible_chunks_before != plan.chunk_index or
        plan.visible_chunks_after != visible_chunks_after or
        plan.visible_frames_before != plan.start_frame or
        plan.visible_frames_after != visible_frames_after or
        plan.logical_units != sample_count or
        plan.renderer_abi == 0 or
        isZero(plan.artifact_sha256) or
        isZero(plan.source_result_sha256) or
        isZero(plan.source_output_sha256) or
        isZero(plan.renderer_payload_sha256) or
        isZero(plan.renderer_implementation_sha256) or
        isZero(plan.tenant_scope_sha256) or
        isZero(plan.metadata_policy_sha256) or
        isZero(plan.challenge_sha256) or
        isZero(plan.media_object_sha256) or
        isZero(plan.state_before_sha256))
        return Error.InvalidPlan;
    if (!digestEqual(plan.plan_sha256, planRootV1(plan)))
        return Error.InvalidPlanRoot;
}

pub fn validatePublicationBindingsV1(
    plan: GeneratedAudioPlanV1,
    state: GeneratedAudioStateV1,
    media_object: media.MediaObjectV1,
    renderer_payload: []const u8,
    renderer: RendererV1,
) Error!void {
    try validatePlanV1(plan);
    try validateStateV1(state);
    if (state.pending != 0)
        return Error.PlaybackPending;
    const expected_generation = checkedAdd(
        state.generation,
        1,
    ) catch return Error.InvalidBinding;
    if (plan.request_epoch != state.request_epoch or
        plan.generation != expected_generation or
        plan.chunk_index != state.next_chunk_index or
        plan.start_frame != state.next_start_frame or
        plan.sample_rate != state.sample_rate or
        plan.channels != state.channels or
        plan.bytes_per_sample != state.bytes_per_sample or
        plan.visible_chunks_before != state.visible_chunks or
        plan.visible_frames_before != state.visible_frames or
        !digestEqual(plan.artifact_sha256, state.artifact_sha256) or
        !digestEqual(
            plan.tenant_scope_sha256,
            state.tenant_scope_sha256,
        ) or
        !digestEqual(
            plan.metadata_policy_sha256,
            state.metadata_policy_sha256,
        ) or
        !digestEqual(plan.challenge_sha256, state.challenge_sha256) or
        !digestEqual(
            plan.previous_publication_result_sha256,
            state.previous_publication_result_sha256,
        ) or
        !digestEqual(plan.state_before_sha256, state.state_sha256))
        return Error.InvalidBinding;
    if (renderer_payload.len == 0 or
        !digestEqual(
            plan.renderer_payload_sha256,
            model.sha256(renderer_payload),
        ) or
        renderer.renderer_abi != plan.renderer_abi or
        renderer.maximum_source_bytes <
            plan.source_output_bytes or
        renderer.maximum_output_bytes < plan.pcm_bytes or
        renderer.required_capabilities != plan.required_capabilities or
        !digestEqual(
            renderer.implementation_sha256,
            plan.renderer_implementation_sha256,
        ))
        return Error.InvalidBinding;
    const object_root = mediaObjectRootV1(media_object) catch
        return Error.InvalidMedia;
    if (!digestEqual(plan.media_object_sha256, object_root) or
        media_object.kind != .audio or
        media_object.semantic_abi != pcm_s16le_semantic_abi or
        media_object.container_id != raw_audio_container_id or
        media_object.codec_id != pcm_s16le_codec_id or
        media_object.byte_length != plan.pcm_bytes or
        media_object.axes[0] != plan.frame_count or
        media_object.axes[1] != plan.channels or
        media_object.axes[2] != plan.sample_rate or
        media_object.time_base.numerator != 1 or
        media_object.time_base.denominator != plan.sample_rate or
        !digestEqual(
            media_object.tenant_scope_sha256,
            plan.tenant_scope_sha256,
        ) or
        !digestEqual(
            media_object.metadata_policy_sha256,
            plan.metadata_policy_sha256,
        ))
        return Error.InvalidMedia;
}

pub fn makeProvenanceV1(
    plan: GeneratedAudioPlanV1,
    output_sha256: Digest,
) Error!GeneratedAudioProvenanceV1 {
    try validatePlanV1(plan);
    if (isZero(output_sha256))
        return Error.InvalidProvenance;
    var provenance = GeneratedAudioProvenanceV1{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .chunk_index = plan.chunk_index,
        .start_frame = plan.start_frame,
        .frame_count = plan.frame_count,
        .sample_rate = plan.sample_rate,
        .channels = plan.channels,
        .bytes_per_sample = plan.bytes_per_sample,
        .source_output_bytes = plan.source_output_bytes,
        .pcm_bytes = plan.pcm_bytes,
        .renderer_abi = plan.renderer_abi,
        .plan_sha256 = plan.plan_sha256,
        .artifact_sha256 = plan.artifact_sha256,
        .source_result_sha256 = plan.source_result_sha256,
        .source_output_sha256 = plan.source_output_sha256,
        .renderer_payload_sha256 = plan.renderer_payload_sha256,
        .renderer_implementation_sha256 = plan.renderer_implementation_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .output_sha256 = output_sha256,
        .tenant_scope_sha256 = plan.tenant_scope_sha256,
        .metadata_policy_sha256 = plan.metadata_policy_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .provenance_sha256 = [_]u8{0} ** 32,
    };
    provenance.provenance_sha256 =
        provenanceRootV1(provenance);
    try validateProvenanceV1(provenance);
    return provenance;
}

pub fn validateProvenanceV1(
    provenance: GeneratedAudioProvenanceV1,
) Error!void {
    const sample_count = checkedMul(
        provenance.frame_count,
        provenance.channels,
    ) catch return Error.InvalidProvenance;
    const pcm_bytes = checkedMul(
        sample_count,
        provenance.bytes_per_sample,
    ) catch return Error.InvalidProvenance;
    if (provenance.request_epoch == 0 or
        provenance.generation == 0 or
        provenance.frame_count == 0 or
        provenance.frame_count > maximum_frames_per_chunk or
        provenance.sample_rate == 0 or
        provenance.sample_rate > maximum_sample_rate or
        provenance.channels == 0 or
        provenance.channels > maximum_channels or
        provenance.bytes_per_sample != 2 or
        provenance.source_output_bytes == 0 or
        provenance.source_output_bytes > maximum_source_bytes or
        provenance.pcm_bytes == 0 or
        provenance.pcm_bytes != pcm_bytes or
        provenance.pcm_bytes > maximum_pcm_bytes or
        provenance.renderer_abi == 0 or
        isZero(provenance.plan_sha256) or
        isZero(provenance.artifact_sha256) or
        isZero(provenance.source_result_sha256) or
        isZero(provenance.source_output_sha256) or
        isZero(provenance.renderer_payload_sha256) or
        isZero(provenance.renderer_implementation_sha256) or
        isZero(provenance.media_object_sha256) or
        isZero(provenance.output_sha256) or
        isZero(provenance.tenant_scope_sha256) or
        isZero(provenance.metadata_policy_sha256) or
        isZero(provenance.challenge_sha256))
        return Error.InvalidProvenance;
    if (!digestEqual(
        provenance.provenance_sha256,
        provenanceRootV1(provenance),
    ))
        return Error.InvalidProvenanceRoot;
}

pub fn validateProvenanceBindingV1(
    plan: GeneratedAudioPlanV1,
    provenance: GeneratedAudioProvenanceV1,
) Error!void {
    try validatePlanV1(plan);
    try validateProvenanceV1(provenance);
    if (provenance.request_epoch != plan.request_epoch or
        provenance.generation != plan.generation or
        provenance.chunk_index != plan.chunk_index or
        provenance.start_frame != plan.start_frame or
        provenance.frame_count != plan.frame_count or
        provenance.sample_rate != plan.sample_rate or
        provenance.channels != plan.channels or
        provenance.bytes_per_sample != plan.bytes_per_sample or
        provenance.source_output_bytes != plan.source_output_bytes or
        provenance.pcm_bytes != plan.pcm_bytes or
        provenance.renderer_abi != plan.renderer_abi or
        !digestEqual(provenance.plan_sha256, plan.plan_sha256) or
        !digestEqual(provenance.artifact_sha256, plan.artifact_sha256) or
        !digestEqual(
            provenance.source_result_sha256,
            plan.source_result_sha256,
        ) or
        !digestEqual(
            provenance.source_output_sha256,
            plan.source_output_sha256,
        ) or
        !digestEqual(
            provenance.renderer_payload_sha256,
            plan.renderer_payload_sha256,
        ) or
        !digestEqual(
            provenance.renderer_implementation_sha256,
            plan.renderer_implementation_sha256,
        ) or
        !digestEqual(
            provenance.media_object_sha256,
            plan.media_object_sha256,
        ) or
        !digestEqual(
            provenance.tenant_scope_sha256,
            plan.tenant_scope_sha256,
        ) or
        !digestEqual(
            provenance.metadata_policy_sha256,
            plan.metadata_policy_sha256,
        ) or
        !digestEqual(
            provenance.challenge_sha256,
            plan.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn makeResultV1(
    plan: GeneratedAudioPlanV1,
    provenance: GeneratedAudioProvenanceV1,
    receipt: resource_bank.Receipt,
) Error!GeneratedAudioResultV1 {
    try validateProvenanceBindingV1(plan, provenance);
    var result = GeneratedAudioResultV1{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .chunk_index = plan.chunk_index,
        .start_frame = plan.start_frame,
        .frame_count = plan.frame_count,
        .end_frame = plan.visible_frames_after,
        .sample_rate = plan.sample_rate,
        .channels = plan.channels,
        .bytes_per_sample = plan.bytes_per_sample,
        .source_output_bytes = plan.source_output_bytes,
        .pcm_bytes = plan.pcm_bytes,
        .publication_sequence = plan.publication_sequence,
        .visible_chunks_before = plan.visible_chunks_before,
        .visible_chunks_after = plan.visible_chunks_after,
        .visible_frames_before = plan.visible_frames_before,
        .visible_frames_after = plan.visible_frames_after,
        .plan_sha256 = plan.plan_sha256,
        .provenance_sha256 = provenance.provenance_sha256,
        .artifact_sha256 = plan.artifact_sha256,
        .source_result_sha256 = plan.source_result_sha256,
        .source_output_sha256 = plan.source_output_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .output_sha256 = provenance.output_sha256,
        .resource_receipt_sha256 = resourceReceiptRootV1(
            receipt,
            plan.request_epoch,
            plan.plan_sha256,
            plan.renderer_implementation_sha256,
        ),
        .state_before_sha256 = plan.state_before_sha256,
        .previous_publication_result_sha256 = plan.previous_publication_result_sha256,
        .renderer_implementation_sha256 = plan.renderer_implementation_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.result_sha256 = resultRootV1(result);
    try validateResultV1(result);
    return result;
}

pub fn validateResultV1(result: GeneratedAudioResultV1) Error!void {
    const end_frame = checkedAdd(
        result.start_frame,
        result.frame_count,
    ) catch return Error.InvalidResult;
    const visible_chunks_after = checkedAdd(
        result.visible_chunks_before,
        1,
    ) catch return Error.InvalidResult;
    const sample_count = checkedMul(
        result.frame_count,
        result.channels,
    ) catch return Error.InvalidResult;
    const pcm_bytes = checkedMul(
        sample_count,
        result.bytes_per_sample,
    ) catch return Error.InvalidResult;
    if (result.request_epoch == 0 or result.generation == 0 or
        result.frame_count == 0 or
        result.frame_count > maximum_frames_per_chunk or
        result.sample_rate == 0 or
        result.sample_rate > maximum_sample_rate or
        result.channels == 0 or
        result.channels > maximum_channels or
        result.bytes_per_sample != 2 or
        result.source_output_bytes == 0 or
        result.source_output_bytes > maximum_source_bytes or
        result.pcm_bytes == 0 or
        result.pcm_bytes != pcm_bytes or
        result.pcm_bytes > maximum_pcm_bytes or
        result.end_frame != end_frame or
        result.publication_sequence != result.chunk_index or
        result.visible_chunks_before != result.chunk_index or
        result.visible_chunks_after != visible_chunks_after or
        result.visible_frames_before != result.start_frame or
        result.visible_frames_after != result.end_frame or
        isZero(result.plan_sha256) or
        isZero(result.provenance_sha256) or
        isZero(result.artifact_sha256) or
        isZero(result.source_result_sha256) or
        isZero(result.source_output_sha256) or
        isZero(result.media_object_sha256) or
        isZero(result.output_sha256) or
        isZero(result.resource_receipt_sha256) or
        isZero(result.state_before_sha256) or
        isZero(result.renderer_implementation_sha256) or
        isZero(result.challenge_sha256))
        return Error.InvalidResult;
    if (!digestEqual(result.result_sha256, resultRootV1(result)))
        return Error.InvalidResultRoot;
}

pub fn stateAfterPublicationV1(
    state: GeneratedAudioStateV1,
    plan: GeneratedAudioPlanV1,
    result: GeneratedAudioResultV1,
) Error!GeneratedAudioStateV1 {
    try validateStateV1(state);
    try validatePlanV1(plan);
    try validateResultV1(result);
    if (state.pending != 0 or
        !digestEqual(plan.state_before_sha256, state.state_sha256) or
        !digestEqual(result.plan_sha256, plan.plan_sha256))
        return Error.InvalidBinding;
    var next = state;
    next.generation = plan.generation;
    next.next_chunk_index = plan.visible_chunks_after;
    next.next_start_frame = plan.visible_frames_after;
    next.visible_chunks = plan.visible_chunks_after;
    next.visible_frames = plan.visible_frames_after;
    next.pending = 1;
    next.pending_chunk_index = plan.chunk_index;
    next.pending_start_frame = plan.start_frame;
    next.pending_frame_count = plan.frame_count;
    next.pending_publication_result_sha256 =
        result.result_sha256;
    next.pending_output_sha256 = result.output_sha256;
    next.state_sha256 = [_]u8{0} ** 32;
    next.state_sha256 = stateRootV1(next);
    try validateStateV1(next);
    return next;
}

pub fn makePlaybackObservationV1(
    state: GeneratedAudioStateV1,
    sink_implementation_sha256: Digest,
    sink_instance_sha256: Digest,
) Error!PlaybackObservationV1 {
    try validateStateV1(state);
    if (state.pending == 0)
        return Error.NoPlaybackPending;
    var observation = PlaybackObservationV1{
        .request_epoch = state.request_epoch,
        .playback_sequence = state.playback_sequence,
        .chunk_index = state.pending_chunk_index,
        .start_frame = state.pending_start_frame,
        .frame_count = state.pending_frame_count,
        .consumed_frames = state.pending_frame_count,
        .sample_rate = state.sample_rate,
        .channels = state.channels,
        .bytes_per_sample = state.bytes_per_sample,
        .output_sha256 = state.pending_output_sha256,
        .sink_implementation_sha256 = sink_implementation_sha256,
        .sink_instance_sha256 = sink_instance_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .observation_sha256 = [_]u8{0} ** 32,
    };
    observation.observation_sha256 =
        observationRootV1(observation);
    try validatePlaybackObservationV1(observation);
    return observation;
}

pub fn validatePlaybackObservationV1(
    observation: PlaybackObservationV1,
) Error!void {
    if (observation.request_epoch == 0 or
        observation.frame_count == 0 or
        observation.consumed_frames != observation.frame_count or
        observation.sample_rate == 0 or
        observation.sample_rate > maximum_sample_rate or
        observation.channels == 0 or
        observation.channels > maximum_channels or
        observation.bytes_per_sample != 2 or
        isZero(observation.output_sha256) or
        isZero(observation.sink_implementation_sha256) or
        isZero(observation.sink_instance_sha256) or
        isZero(observation.challenge_sha256))
        return Error.InvalidObservation;
    if (!digestEqual(
        observation.observation_sha256,
        observationRootV1(observation),
    ))
        return Error.InvalidObservationRoot;
}

pub fn makePlaybackAckPlanV1(
    state: GeneratedAudioStateV1,
    publication_result: GeneratedAudioResultV1,
    observation: PlaybackObservationV1,
) Error!PlaybackAckPlanV1 {
    try validateStateV1(state);
    try validateResultV1(publication_result);
    try validatePlaybackObservationV1(observation);
    if (state.pending == 0)
        return Error.NoPlaybackPending;
    const acknowledged_chunks_after = try checkedAdd(
        state.acknowledged_chunks,
        1,
    );
    const acknowledged_frames_after = try checkedAdd(
        state.acknowledged_frames,
        state.pending_frame_count,
    );
    var plan = PlaybackAckPlanV1{
        .request_epoch = state.request_epoch,
        .generation = try checkedAdd(state.generation, 1),
        .playback_sequence = state.playback_sequence,
        .chunk_index = state.pending_chunk_index,
        .start_frame = state.pending_start_frame,
        .frame_count = state.pending_frame_count,
        .end_frame = acknowledged_frames_after,
        .consumed_frames = observation.consumed_frames,
        .sample_rate = state.sample_rate,
        .channels = state.channels,
        .bytes_per_sample = state.bytes_per_sample,
        .acknowledged_chunks_before = state.acknowledged_chunks,
        .acknowledged_chunks_after = acknowledged_chunks_after,
        .acknowledged_frames_before = state.acknowledged_frames,
        .acknowledged_frames_after = acknowledged_frames_after,
        .state_before_sha256 = state.state_sha256,
        .publication_result_sha256 = publication_result.result_sha256,
        .output_sha256 = state.pending_output_sha256,
        .sink_implementation_sha256 = observation.sink_implementation_sha256,
        .sink_instance_sha256 = observation.sink_instance_sha256,
        .observation_sha256 = observation.observation_sha256,
        .previous_ack_result_sha256 = state.previous_ack_result_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .plan_sha256 = [_]u8{0} ** 32,
    };
    plan.plan_sha256 = ackPlanRootV1(plan);
    try validatePlaybackAckBindingsV1(
        state,
        publication_result,
        observation,
        plan,
    );
    return plan;
}

pub fn validatePlaybackAckPlanV1(
    plan: PlaybackAckPlanV1,
) Error!void {
    const end_frame = checkedAdd(
        plan.start_frame,
        plan.frame_count,
    ) catch return Error.InvalidAckPlan;
    const acknowledged_chunks_after = checkedAdd(
        plan.acknowledged_chunks_before,
        1,
    ) catch return Error.InvalidAckPlan;
    if (plan.request_epoch == 0 or plan.generation == 0 or
        plan.frame_count == 0 or
        plan.end_frame != end_frame or
        plan.consumed_frames != plan.frame_count or
        plan.sample_rate == 0 or
        plan.sample_rate > maximum_sample_rate or
        plan.channels == 0 or
        plan.channels > maximum_channels or
        plan.bytes_per_sample != 2 or
        plan.acknowledged_chunks_after !=
            acknowledged_chunks_after or
        plan.acknowledged_frames_before != plan.start_frame or
        plan.acknowledged_frames_after != plan.end_frame or
        isZero(plan.state_before_sha256) or
        isZero(plan.publication_result_sha256) or
        isZero(plan.output_sha256) or
        isZero(plan.sink_implementation_sha256) or
        isZero(plan.sink_instance_sha256) or
        isZero(plan.observation_sha256) or
        isZero(plan.challenge_sha256))
        return Error.InvalidAckPlan;
    if (!digestEqual(plan.plan_sha256, ackPlanRootV1(plan)))
        return Error.InvalidAckPlanRoot;
}

pub fn validatePlaybackAckBindingsV1(
    state: GeneratedAudioStateV1,
    publication_result: GeneratedAudioResultV1,
    observation: PlaybackObservationV1,
    plan: PlaybackAckPlanV1,
) Error!void {
    try validateStateV1(state);
    try validateResultV1(publication_result);
    try validatePlaybackObservationV1(observation);
    try validatePlaybackAckPlanV1(plan);
    if (state.pending == 0)
        return Error.NoPlaybackPending;
    const expected_generation = checkedAdd(
        state.generation,
        1,
    ) catch return Error.InvalidBinding;
    if (plan.request_epoch != state.request_epoch or
        plan.generation != expected_generation or
        plan.playback_sequence != state.playback_sequence or
        plan.chunk_index != state.pending_chunk_index or
        plan.start_frame != state.pending_start_frame or
        plan.frame_count != state.pending_frame_count or
        plan.sample_rate != state.sample_rate or
        plan.channels != state.channels or
        plan.bytes_per_sample != state.bytes_per_sample or
        plan.acknowledged_chunks_before !=
            state.acknowledged_chunks or
        plan.acknowledged_frames_before !=
            state.acknowledged_frames or
        !digestEqual(plan.state_before_sha256, state.state_sha256) or
        !digestEqual(
            plan.publication_result_sha256,
            state.pending_publication_result_sha256,
        ) or
        !digestEqual(
            plan.publication_result_sha256,
            publication_result.result_sha256,
        ) or
        !digestEqual(plan.output_sha256, state.pending_output_sha256) or
        !digestEqual(plan.output_sha256, publication_result.output_sha256) or
        !digestEqual(
            plan.previous_ack_result_sha256,
            state.previous_ack_result_sha256,
        ) or
        !digestEqual(plan.challenge_sha256, state.challenge_sha256))
        return Error.InvalidBinding;
    if (observation.request_epoch != plan.request_epoch or
        observation.playback_sequence != plan.playback_sequence or
        observation.chunk_index != plan.chunk_index or
        observation.start_frame != plan.start_frame or
        observation.frame_count != plan.frame_count or
        observation.consumed_frames != plan.consumed_frames or
        observation.sample_rate != plan.sample_rate or
        observation.channels != plan.channels or
        observation.bytes_per_sample != plan.bytes_per_sample or
        !digestEqual(observation.output_sha256, plan.output_sha256) or
        !digestEqual(
            observation.sink_implementation_sha256,
            plan.sink_implementation_sha256,
        ) or
        !digestEqual(
            observation.sink_instance_sha256,
            plan.sink_instance_sha256,
        ) or
        !digestEqual(
            observation.observation_sha256,
            plan.observation_sha256,
        ) or
        !digestEqual(
            observation.challenge_sha256,
            plan.challenge_sha256,
        ))
        return Error.InvalidBinding;
    if (publication_result.request_epoch != plan.request_epoch or
        publication_result.chunk_index != plan.chunk_index or
        publication_result.start_frame != plan.start_frame or
        publication_result.frame_count != plan.frame_count or
        publication_result.sample_rate != plan.sample_rate or
        publication_result.channels != plan.channels or
        publication_result.bytes_per_sample !=
            plan.bytes_per_sample or
        !digestEqual(
            publication_result.previous_publication_result_sha256,
            state.previous_publication_result_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn makePlaybackAckResultV1(
    state: GeneratedAudioStateV1,
    publication_result: GeneratedAudioResultV1,
    observation: PlaybackObservationV1,
    plan: PlaybackAckPlanV1,
) Error!PlaybackAckResultV1 {
    try validatePlaybackAckBindingsV1(
        state,
        publication_result,
        observation,
        plan,
    );
    var result = PlaybackAckResultV1{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .playback_sequence = plan.playback_sequence,
        .chunk_index = plan.chunk_index,
        .start_frame = plan.start_frame,
        .frame_count = plan.frame_count,
        .end_frame = plan.end_frame,
        .consumed_frames = plan.consumed_frames,
        .sample_rate = plan.sample_rate,
        .channels = plan.channels,
        .bytes_per_sample = plan.bytes_per_sample,
        .acknowledged_chunks_before = plan.acknowledged_chunks_before,
        .acknowledged_chunks_after = plan.acknowledged_chunks_after,
        .acknowledged_frames_before = plan.acknowledged_frames_before,
        .acknowledged_frames_after = plan.acknowledged_frames_after,
        .plan_sha256 = plan.plan_sha256,
        .state_before_sha256 = state.state_sha256,
        .publication_result_sha256 = publication_result.result_sha256,
        .output_sha256 = publication_result.output_sha256,
        .sink_implementation_sha256 = observation.sink_implementation_sha256,
        .sink_instance_sha256 = observation.sink_instance_sha256,
        .observation_sha256 = observation.observation_sha256,
        .previous_publication_result_sha256 = state.previous_publication_result_sha256,
        .previous_ack_result_sha256 = state.previous_ack_result_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.result_sha256 = ackResultRootV1(result);
    try validatePlaybackAckResultV1(result);
    return result;
}

pub fn validatePlaybackAckResultV1(
    result: PlaybackAckResultV1,
) Error!void {
    const end_frame = checkedAdd(
        result.start_frame,
        result.frame_count,
    ) catch return Error.InvalidAckResult;
    const acknowledged_chunks_after = checkedAdd(
        result.acknowledged_chunks_before,
        1,
    ) catch return Error.InvalidAckResult;
    if (result.request_epoch == 0 or result.generation == 0 or
        result.frame_count == 0 or result.end_frame != end_frame or
        result.consumed_frames != result.frame_count or
        result.sample_rate == 0 or result.channels == 0 or
        result.bytes_per_sample != 2 or
        result.acknowledged_chunks_after !=
            acknowledged_chunks_after or
        result.acknowledged_frames_before != result.start_frame or
        result.acknowledged_frames_after != result.end_frame or
        isZero(result.plan_sha256) or
        isZero(result.state_before_sha256) or
        isZero(result.publication_result_sha256) or
        isZero(result.output_sha256) or
        isZero(result.sink_implementation_sha256) or
        isZero(result.sink_instance_sha256) or
        isZero(result.observation_sha256) or
        isZero(result.challenge_sha256))
        return Error.InvalidAckResult;
    if (!digestEqual(
        result.result_sha256,
        ackResultRootV1(result),
    ))
        return Error.InvalidAckResultRoot;
}

fn stateAfterAckV1(
    state: GeneratedAudioStateV1,
    publication_result: GeneratedAudioResultV1,
    ack_result: PlaybackAckResultV1,
) Error!GeneratedAudioStateV1 {
    try validateStateV1(state);
    try validateResultV1(publication_result);
    try validatePlaybackAckResultV1(ack_result);
    if (state.pending == 0 or
        !digestEqual(
            state.pending_publication_result_sha256,
            publication_result.result_sha256,
        ) or
        !digestEqual(
            ack_result.publication_result_sha256,
            publication_result.result_sha256,
        ) or
        !digestEqual(ack_result.state_before_sha256, state.state_sha256))
        return Error.InvalidBinding;
    var next = state;
    next.generation = ack_result.generation;
    next.acknowledged_chunks =
        ack_result.acknowledged_chunks_after;
    next.acknowledged_frames =
        ack_result.acknowledged_frames_after;
    next.playback_sequence = try checkedAdd(
        state.playback_sequence,
        1,
    );
    next.pending = 0;
    next.pending_chunk_index = 0;
    next.pending_start_frame = 0;
    next.pending_frame_count = 0;
    next.previous_publication_result_sha256 =
        publication_result.result_sha256;
    next.previous_ack_result_sha256 = ack_result.result_sha256;
    next.pending_publication_result_sha256 =
        [_]u8{0} ** 32;
    next.pending_output_sha256 = [_]u8{0} ** 32;
    next.state_sha256 = [_]u8{0} ** 32;
    next.state_sha256 = stateRootV1(next);
    try validateStateV1(next);
    return next;
}

pub fn acknowledgePlaybackV1(
    state: *GeneratedAudioStateV1,
    publication_result: GeneratedAudioResultV1,
    observation: PlaybackObservationV1,
    plan: PlaybackAckPlanV1,
) Error!PlaybackAckResultV1 {
    const before = state.*;
    const result = try makePlaybackAckResultV1(
        before,
        publication_result,
        observation,
        plan,
    );
    const after = try stateAfterAckV1(
        before,
        publication_result,
        result,
    );
    state.* = after;
    return result;
}

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    state: *GeneratedAudioStateV1 = undefined,
    receipt: resource_bank.Receipt = undefined,
    plan: GeneratedAudioPlanV1 = undefined,
    media_object: media.MediaObjectV1 = undefined,
    renderer: RendererV1 = undefined,
    renderer_payload: []const u8 = &[_]u8{},
    permit: ?resource_bank.PublicationPermit = null,
    prepared_provenance: ?GeneratedAudioProvenanceV1 = null,
    prepared_result: ?GeneratedAudioResultV1 = null,
    prepared_state_after: ?GeneratedAudioStateV1 = null,
    source_output: []const u8 = &[_]u8{},
    candidate_output: ?[]u8 = null,
    candidate_provenance: ?[]u8 = null,
    candidate_result: ?[]u8 = null,
    visible_output: ?[]u8 = null,
    visible_provenance: ?[]u8 = null,
    visible_result: ?[]u8 = null,
    expected_output_sha256: Digest = [_]u8{0} ** 32,
    expected_provenance_wire_sha256: Digest = [_]u8{0} ** 32,
    expected_result_wire_sha256: Digest = [_]u8{0} ** 32,
    expected_state_sha256: Digest = [_]u8{0} ** 32,
    next_resource_sequence: u64 = 0,
    initialized: bool = false,
    phase: Phase = .idle,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        state: *GeneratedAudioStateV1,
        plan: GeneratedAudioPlanV1,
        media_object: media.MediaObjectV1,
        renderer_payload: []const u8,
        renderer: RendererV1,
    ) Error!void {
        if (self.initialized or self.phase != .idle or owner_key == 0)
            return Error.InvalidState;
        try validatePublicationBindingsV1(
            plan,
            state.*,
            media_object,
            renderer_payload,
            renderer,
        );
        const payload_bytes = std.math.cast(
            u64,
            renderer_payload.len,
        ) orelse return Error.ArithmeticOverflow;
        const claim = try claimForPlanV1(plan, payload_bytes);
        const reservation = bank.reserve(
            owner_key,
            claim,
        ) catch return Error.ResourceAdmissionFailed;
        const receipt = bank.commit(reservation) catch {
            bank.cancel(reservation) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceAdmissionFailed;
        };
        bank.bindPublicationSession(
            receipt,
            plan.request_epoch,
            @intFromPtr(self),
        ) catch {
            bank.release(receipt) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        self.* = .{
            .bank = bank,
            .state = state,
            .receipt = receipt,
            .plan = plan,
            .media_object = media_object,
            .renderer = renderer,
            .renderer_payload = renderer_payload,
            .initialized = true,
        };
    }

    pub fn prepareV1(
        self: *Session,
        source_output: []const u8,
        candidate_output_storage: []u8,
        candidate_provenance_storage: []u8,
        candidate_result_storage: []u8,
        visible_output_storage: []u8,
        visible_provenance_storage: []u8,
        visible_result_storage: []u8,
    ) Error!GeneratedAudioResultV1 {
        if (!self.initialized or self.phase != .idle or
            self.permit != null)
            return Error.InvalidState;
        try validatePublicationBindingsV1(
            self.plan,
            self.state.*,
            self.media_object,
            self.renderer_payload,
            self.renderer,
        );
        const pcm_bytes: usize = std.math.cast(
            usize,
            self.plan.pcm_bytes,
        ) orelse return Error.ArithmeticOverflow;
        if (source_output.len != self.plan.source_output_bytes or
            candidate_output_storage.len < pcm_bytes or
            candidate_provenance_storage.len < provenance_bytes or
            candidate_result_storage.len < result_bytes or
            visible_output_storage.len < pcm_bytes or
            visible_provenance_storage.len < provenance_bytes or
            visible_result_storage.len < result_bytes)
            return Error.BufferTooSmall;
        if (!digestEqual(
            model.sha256(source_output),
            self.plan.source_output_sha256,
        ))
            return Error.InvalidBinding;
        const candidate_output =
            candidate_output_storage[0..pcm_bytes];
        const candidate_provenance =
            candidate_provenance_storage[0..provenance_bytes];
        const candidate_result =
            candidate_result_storage[0..result_bytes];
        const visible_output = visible_output_storage[0..pcm_bytes];
        const visible_provenance =
            visible_provenance_storage[0..provenance_bytes];
        const visible_result =
            visible_result_storage[0..result_bytes];
        const mutable = [_][]u8{
            candidate_output,
            candidate_provenance,
            candidate_result,
            visible_output,
            visible_provenance,
            visible_result,
        };
        const immutable = [_][]const u8{
            source_output,
            self.renderer_payload,
            std.mem.asBytes(&self.plan),
            std.mem.asBytes(&self.media_object),
            std.mem.asBytes(self.state),
        };
        if (!buffersDisjoint(&mutable, &immutable))
            return Error.BufferAlias;
        @memset(candidate_output, 0);
        @memset(candidate_provenance, 0);
        @memset(candidate_result, 0);
        const permit = self.bank.beginPublication(
            self.receipt,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.permit = permit;
        self.source_output = source_output;
        self.candidate_output = candidate_output;
        self.candidate_provenance = candidate_provenance;
        self.candidate_result = candidate_result;
        self.visible_output = visible_output;
        self.visible_provenance = visible_provenance;
        self.visible_result = visible_result;
        self.phase = .prepared;
        self.renderer.execute(
            self.renderer.context,
            &self.plan,
            source_output,
            self.renderer_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        };
        self.renderer.validate(
            self.renderer.context,
            &self.plan,
            source_output,
            self.renderer_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        };
        const output_sha256 = model.sha256(candidate_output);
        if (!digestEqual(
            output_sha256,
            self.media_object.content_sha256,
        )) {
            try self.rollbackV1(permit);
            return Error.CandidateInvalid;
        }
        const provenance = makeProvenanceV1(
            self.plan,
            output_sha256,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidProvenance;
        };
        var provenance_wire: [provenance_bytes]u8 = undefined;
        _ = encodeProvenanceV1(
            provenance,
            &provenance_wire,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidProvenance;
        };
        @memcpy(candidate_provenance, &provenance_wire);
        const result = makeResultV1(
            self.plan,
            provenance,
            self.receipt,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidResult;
        };
        var result_wire: [result_bytes]u8 = undefined;
        _ = encodeResultV1(result, &result_wire) catch {
            try self.rollbackV1(permit);
            return Error.InvalidResult;
        };
        @memcpy(candidate_result, &result_wire);
        const state_after = stateAfterPublicationV1(
            self.state.*,
            self.plan,
            result,
        ) catch {
            try self.rollbackV1(permit);
            return Error.InvalidState;
        };
        self.prepared_provenance = provenance;
        self.prepared_result = result;
        self.prepared_state_after = state_after;
        self.expected_output_sha256 = output_sha256;
        self.expected_provenance_wire_sha256 =
            model.sha256(candidate_provenance);
        self.expected_result_wire_sha256 =
            model.sha256(candidate_result);
        self.expected_state_sha256 = self.state.state_sha256;
        return result;
    }

    pub fn commitV1(self: *Session) Error!GeneratedAudioResultV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        const expected_provenance =
            self.prepared_provenance orelse
            return Error.InvalidState;
        const expected_result = self.prepared_result orelse
            return Error.InvalidState;
        const expected_state_after =
            self.prepared_state_after orelse
            return Error.InvalidState;
        const candidate_output = self.candidate_output orelse
            return Error.InvalidState;
        const candidate_provenance =
            self.candidate_provenance orelse
            return Error.InvalidState;
        const candidate_result = self.candidate_result orelse
            return Error.InvalidState;
        const visible_output = self.visible_output orelse
            return Error.InvalidState;
        const visible_provenance = self.visible_provenance orelse
            return Error.InvalidState;
        const visible_result = self.visible_result orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        validatePublicationBindingsV1(
            self.plan,
            self.state.*,
            self.media_object,
            self.renderer_payload,
            self.renderer,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!digestEqual(
            self.state.state_sha256,
            self.expected_state_sha256,
        ) or
            !digestEqual(
                model.sha256(self.source_output),
                self.plan.source_output_sha256,
            ) or
            !digestEqual(
                model.sha256(candidate_output),
                self.expected_output_sha256,
            ) or
            !digestEqual(
                model.sha256(candidate_provenance),
                self.expected_provenance_wire_sha256,
            ) or
            !digestEqual(
                model.sha256(candidate_result),
                self.expected_result_wire_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        self.renderer.validate(
            self.renderer.context,
            &self.plan,
            self.source_output,
            self.renderer_payload,
            candidate_output,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const decoded_provenance = decodeProvenanceV1(
            candidate_provenance,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const decoded_result = decodeResultV1(
            candidate_result,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const reconstructed_provenance = makeProvenanceV1(
            self.plan,
            model.sha256(candidate_output),
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const reconstructed_result = makeResultV1(
            self.plan,
            reconstructed_provenance,
            self.receipt,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        const reconstructed_state_after = stateAfterPublicationV1(
            self.state.*,
            self.plan,
            reconstructed_result,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.meta.eql(decoded_provenance, expected_provenance) or
            !std.meta.eql(
                decoded_provenance,
                reconstructed_provenance,
            ) or
            !std.meta.eql(decoded_result, expected_result) or
            !std.meta.eql(decoded_result, reconstructed_result) or
            !std.meta.eql(
                expected_state_after,
                reconstructed_state_after,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        @memcpy(visible_output, candidate_output);
        @memcpy(visible_provenance, candidate_provenance);
        @memcpy(visible_result, candidate_result);
        self.state.* = reconstructed_state_after;
        self.bank.commitPublicationAssumeValid(permit);
        self.next_resource_sequence = permit.sequence + 1;
        self.scrubCandidatesV1();
        self.clearPreparedV1();
        self.phase = .idle;
        return decoded_result;
    }

    pub fn abortV1(self: *Session) Error!void {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        try self.rollbackV1(permit);
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        if (!self.initialized or self.phase != .idle)
            return Error.InvalidState;
        self.bank.closePublicationSession(
            self.receipt,
            self.plan.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.bank.release(self.receipt) catch
            return Error.ResourceReceiptInvalid;
        self.initialized = false;
        self.phase = .closed;
    }

    fn rollbackV1(
        self: *Session,
        permit: resource_bank.PublicationPermit,
    ) Error!void {
        self.bank.abortPublication(permit) catch {
            self.scrubCandidatesV1();
            self.clearPreparedV1();
            self.phase = .poisoned;
            return Error.ResourceReceiptInvalid;
        };
        self.scrubCandidatesV1();
        self.clearPreparedV1();
        self.phase = .idle;
    }

    fn scrubCandidatesV1(self: *Session) void {
        if (self.candidate_output) |bytes| @memset(bytes, 0);
        if (self.candidate_provenance) |bytes| @memset(bytes, 0);
        if (self.candidate_result) |bytes| @memset(bytes, 0);
    }

    fn clearPreparedV1(self: *Session) void {
        self.permit = null;
        self.prepared_provenance = null;
        self.prepared_result = null;
        self.prepared_state_after = null;
        self.source_output = &[_]u8{};
        self.candidate_output = null;
        self.candidate_provenance = null;
        self.candidate_result = null;
        self.visible_output = null;
        self.visible_provenance = null;
        self.visible_result = null;
        self.expected_output_sha256 = [_]u8{0} ** 32;
        self.expected_provenance_wire_sha256 = [_]u8{0} ** 32;
        self.expected_result_wire_sha256 = [_]u8{0} ** 32;
        self.expected_state_sha256 = [_]u8{0} ** 32;
    }
};

pub fn claimForPlanV1(
    plan: GeneratedAudioPlanV1,
    renderer_payload_bytes: u64,
) Error!resource_bank.Claim {
    try validatePlanV1(plan);
    if (renderer_payload_bytes == 0)
        return Error.InvalidPlan;
    const private_bytes = try checkedAdd(
        plan.pcm_bytes,
        provenance_bytes + result_bytes,
    );
    return .{
        .capsule_bytes = renderer_payload_bytes,
        .activation_bytes = plan.source_output_bytes,
        .partial_bytes = private_bytes,
        .output_journal_bytes = private_bytes,
        .queue_slots = 1,
    };
}

pub fn resourceReceiptRootV1(
    receipt: resource_bank.Receipt,
    request_epoch: u64,
    plan_sha256: Digest,
    renderer_implementation_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(resource_domain);
    hashU64(&hash, runtime_abi);
    hashU64(&hash, request_epoch);
    hashU64(&hash, receipt.bank_epoch);
    hashU64(&hash, receipt.slot_index);
    hashU64(&hash, receipt.generation);
    hashU64(&hash, receipt.owner_key);
    hashClaim(&hash, receipt.claim);
    hashU64(&hash, receipt.integrity);
    hash.update(&plan_sha256);
    hash.update(&renderer_implementation_sha256);
    return hash.finalResult();
}

pub fn referenceRendererV1(context: *anyopaque) RendererV1 {
    return .{
        .renderer_abi = reference_renderer_abi,
        .maximum_source_bytes = maximum_source_bytes,
        .maximum_output_bytes = maximum_pcm_bytes,
        .required_capabilities = 0,
        .implementation_sha256 = model.sha256(
            "reference exact audio-token-to-pcm-s16le renderer v1",
        ),
        .context = context,
        .execute = referenceRenderV1,
        .validate = validateReferenceRenderV1,
    };
}

fn referenceRenderV1(
    _: *anyopaque,
    plan: *const GeneratedAudioPlanV1,
    source_output: []const u8,
    renderer_payload: []const u8,
    candidate_output: []u8,
) anyerror!void {
    if (!std.mem.eql(
        u8,
        renderer_payload,
        reference_renderer_payload,
    ) or source_output.len != plan.source_output_bytes or
        plan.source_output_bytes != plan.logical_units or
        candidate_output.len != plan.pcm_bytes)
        return Error.CandidateInvalid;
    try renderReferencePcmV1(source_output, candidate_output);
}

pub fn renderReferencePcmV1(
    source_output: []const u8,
    candidate_output: []u8,
) Error!void {
    const expected_bytes = checkedMul(
        std.math.cast(u64, source_output.len) orelse
            return Error.ArithmeticOverflow,
        2,
    ) catch return Error.ArithmeticOverflow;
    if (candidate_output.len != expected_bytes)
        return Error.CandidateInvalid;
    for (source_output, 0..) |token, index| {
        const centered: i32 = @as(i32, token) - 128;
        const sample: i16 = @intCast(centered * 256);
        const offset = index * 2;
        std.mem.writeInt(
            i16,
            candidate_output[offset..][0..2],
            sample,
            .little,
        );
    }
}

fn validateReferenceRenderV1(
    context: *anyopaque,
    plan: *const GeneratedAudioPlanV1,
    source_output: []const u8,
    renderer_payload: []const u8,
    candidate_output: []const u8,
) anyerror!void {
    var expected: [maximum_pcm_bytes]u8 = undefined;
    const output_len: usize = @intCast(plan.pcm_bytes);
    try referenceRenderV1(
        context,
        plan,
        source_output,
        renderer_payload,
        expected[0..output_len],
    );
    if (!std.mem.eql(
        u8,
        expected[0..output_len],
        candidate_output,
    ))
        return Error.CandidateInvalid;
}

pub fn makeAudioMediaObjectV1(
    plan_state: GeneratedAudioStateV1,
    frame_count: u64,
    output_sha256: Digest,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_implementation_sha256: Digest,
) Error!media.MediaObjectV1 {
    try validateStateV1(plan_state);
    if (frame_count == 0 or
        frame_count > maximum_frames_per_chunk or
        isZero(output_sha256))
        return Error.InvalidMedia;
    const pcm_bytes = try checkedMul(
        try checkedMul(frame_count, plan_state.channels),
        plan_state.bytes_per_sample,
    );
    const provenance_sha256 = audioMediaProvenanceRootV1(
        plan_state,
        frame_count,
        source_result_sha256,
        source_output_sha256,
        renderer_implementation_sha256,
    );
    const object = media.MediaObjectV1{
        .kind = .audio,
        .semantic_abi = pcm_s16le_semantic_abi,
        .byte_length = pcm_bytes,
        .container_id = raw_audio_container_id,
        .codec_id = pcm_s16le_codec_id,
        .axes = .{
            frame_count,
            plan_state.channels,
            plan_state.sample_rate,
        },
        .time_base = .{
            .numerator = 1,
            .denominator = plan_state.sample_rate,
        },
        .tenant_scope_sha256 = plan_state.tenant_scope_sha256,
        .content_sha256 = output_sha256,
        .metadata_policy_sha256 = plan_state.metadata_policy_sha256,
        .provenance_sha256 = provenance_sha256,
    };
    _ = mediaObjectRootV1(object) catch
        return Error.InvalidMedia;
    return object;
}

fn audioMediaProvenanceRootV1(
    state: GeneratedAudioStateV1,
    frame_count: u64,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    renderer_implementation_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(media_provenance_domain);
    hashU64(&hash, runtime_abi);
    hashU64(&hash, state.request_epoch);
    hashU64(&hash, state.next_chunk_index);
    hashU64(&hash, state.next_start_frame);
    hashU64(&hash, frame_count);
    hash.update(&state.artifact_sha256);
    hash.update(&source_result_sha256);
    hash.update(&source_output_sha256);
    hash.update(&renderer_implementation_sha256);
    hash.update(&state.challenge_sha256);
    return hash.finalResult();
}

fn mediaObjectRootV1(
    object: media.MediaObjectV1,
) Error!Digest {
    var encoded: [media.descriptor_bytes]u8 = undefined;
    _ = media.encodeMediaObjectV1(object, &encoded) catch
        return Error.InvalidMedia;
    return media.mediaObjectSha256V1(&encoded) catch
        return Error.InvalidMedia;
}

pub fn encodeStateV1(
    state: GeneratedAudioStateV1,
    output: *[state_bytes]u8,
) Error![]const u8 {
    try validateStateV1(state);
    writeStateBodyV1(state, output[0..state_body_bytes]);
    @memcpy(output[state_body_bytes..], &state.state_sha256);
    return output;
}

pub fn decodeStateV1(input: []const u8) Error!GeneratedAudioStateV1 {
    if (input.len != state_bytes or
        !std.mem.eql(u8, input[0..8], &state_magic) or
        readU64(input, 8) != state_abi or
        readU64(input, 16) != state_bytes or
        readU64(input, 24) != allowed_flags)
        return Error.InvalidWire;
    const state = GeneratedAudioStateV1{
        .request_epoch = readU64(input, 32),
        .generation = readU64(input, 40),
        .sample_rate = readU64(input, 48),
        .channels = readU64(input, 56),
        .bytes_per_sample = readU64(input, 64),
        .next_chunk_index = readU64(input, 72),
        .next_start_frame = readU64(input, 80),
        .visible_chunks = readU64(input, 88),
        .visible_frames = readU64(input, 96),
        .acknowledged_chunks = readU64(input, 104),
        .acknowledged_frames = readU64(input, 112),
        .playback_sequence = readU64(input, 120),
        .pending = readU64(input, 128),
        .pending_chunk_index = readU64(input, 136),
        .pending_start_frame = readU64(input, 144),
        .pending_frame_count = readU64(input, 152),
        .artifact_sha256 = digestAt(input, 160),
        .tenant_scope_sha256 = digestAt(input, 192),
        .metadata_policy_sha256 = digestAt(input, 224),
        .previous_publication_result_sha256 = digestAt(input, 256),
        .previous_ack_result_sha256 = digestAt(input, 288),
        .pending_publication_result_sha256 = digestAt(input, 320),
        .pending_output_sha256 = digestAt(input, 352),
        .challenge_sha256 = digestAt(input, 384),
        .state_sha256 = digestAt(input, state_body_bytes),
    };
    try validateStateV1(state);
    var canonical: [state_bytes]u8 = undefined;
    _ = try encodeStateV1(state, &canonical);
    if (!std.mem.eql(u8, input, &canonical))
        return Error.InvalidWire;
    return state;
}

pub fn encodePlanV1(
    plan: GeneratedAudioPlanV1,
    output: *[plan_bytes]u8,
) Error![]const u8 {
    try validatePlanV1(plan);
    writePlanBodyV1(plan, output[0..plan_body_bytes]);
    @memcpy(output[plan_body_bytes..], &plan.plan_sha256);
    return output;
}

pub fn decodePlanV1(input: []const u8) Error!GeneratedAudioPlanV1 {
    if (input.len != plan_bytes or
        !std.mem.eql(u8, input[0..8], &plan_magic) or
        readU64(input, 8) != plan_abi or
        readU64(input, 16) != plan_bytes or
        readU64(input, 24) != allowed_flags)
        return Error.InvalidWire;
    var plan: GeneratedAudioPlanV1 = undefined;
    const scalar_fields = [_]*u64{
        &plan.request_epoch,
        &plan.generation,
        &plan.chunk_index,
        &plan.start_frame,
        &plan.frame_count,
        &plan.sample_rate,
        &plan.channels,
        &plan.bytes_per_sample,
        &plan.source_output_bytes,
        &plan.pcm_bytes,
        &plan.maximum_output_bytes,
        &plan.publication_sequence,
        &plan.visible_chunks_before,
        &plan.visible_chunks_after,
        &plan.visible_frames_before,
        &plan.visible_frames_after,
        &plan.logical_units,
        &plan.required_capabilities,
        &plan.renderer_abi,
    };
    for (scalar_fields, 0..) |field, index|
        field.* = readU64(input, 32 + index * 8);
    plan.artifact_sha256 = digestAt(input, 184);
    plan.source_result_sha256 = digestAt(input, 216);
    plan.source_output_sha256 = digestAt(input, 248);
    plan.renderer_payload_sha256 = digestAt(input, 280);
    plan.renderer_implementation_sha256 = digestAt(input, 312);
    plan.tenant_scope_sha256 = digestAt(input, 344);
    plan.metadata_policy_sha256 = digestAt(input, 376);
    plan.challenge_sha256 = digestAt(input, 408);
    plan.previous_publication_result_sha256 =
        digestAt(input, 440);
    plan.media_object_sha256 = digestAt(input, 472);
    plan.state_before_sha256 = digestAt(input, 504);
    plan.plan_sha256 = digestAt(input, plan_body_bytes);
    try validatePlanV1(plan);
    var canonical: [plan_bytes]u8 = undefined;
    _ = try encodePlanV1(plan, &canonical);
    if (!std.mem.eql(u8, input, &canonical))
        return Error.InvalidWire;
    return plan;
}

pub fn encodeProvenanceV1(
    provenance: GeneratedAudioProvenanceV1,
    output: *[provenance_bytes]u8,
) Error![]const u8 {
    try validateProvenanceV1(provenance);
    writeProvenanceBodyV1(
        provenance,
        output[0..provenance_body_bytes],
    );
    @memcpy(
        output[provenance_body_bytes..],
        &provenance.provenance_sha256,
    );
    return output;
}

pub fn decodeProvenanceV1(
    input: []const u8,
) Error!GeneratedAudioProvenanceV1 {
    if (input.len != provenance_bytes or
        !std.mem.eql(u8, input[0..8], &provenance_magic) or
        readU64(input, 8) != provenance_abi or
        readU64(input, 16) != provenance_bytes or
        readU64(input, 24) != allowed_flags)
        return Error.InvalidWire;
    var value: GeneratedAudioProvenanceV1 = undefined;
    const scalars = [_]*u64{
        &value.request_epoch,
        &value.generation,
        &value.chunk_index,
        &value.start_frame,
        &value.frame_count,
        &value.sample_rate,
        &value.channels,
        &value.bytes_per_sample,
        &value.source_output_bytes,
        &value.pcm_bytes,
        &value.renderer_abi,
    };
    for (scalars, 0..) |field, index|
        field.* = readU64(input, 32 + index * 8);
    value.plan_sha256 = digestAt(input, 120);
    value.artifact_sha256 = digestAt(input, 152);
    value.source_result_sha256 = digestAt(input, 184);
    value.source_output_sha256 = digestAt(input, 216);
    value.renderer_payload_sha256 = digestAt(input, 248);
    value.renderer_implementation_sha256 = digestAt(input, 280);
    value.media_object_sha256 = digestAt(input, 312);
    value.output_sha256 = digestAt(input, 344);
    value.tenant_scope_sha256 = digestAt(input, 376);
    value.metadata_policy_sha256 = digestAt(input, 408);
    value.challenge_sha256 = digestAt(input, 440);
    value.provenance_sha256 =
        digestAt(input, provenance_body_bytes);
    try validateProvenanceV1(value);
    var canonical: [provenance_bytes]u8 = undefined;
    _ = try encodeProvenanceV1(value, &canonical);
    if (!std.mem.eql(u8, input, &canonical))
        return Error.InvalidWire;
    return value;
}

pub fn encodeResultV1(
    result: GeneratedAudioResultV1,
    output: *[result_bytes]u8,
) Error![]const u8 {
    try validateResultV1(result);
    writeResultBodyV1(result, output[0..result_body_bytes]);
    @memcpy(output[result_body_bytes..], &result.result_sha256);
    return output;
}

pub fn decodeResultV1(input: []const u8) Error!GeneratedAudioResultV1 {
    if (input.len != result_bytes or
        !std.mem.eql(u8, input[0..8], &result_magic) or
        readU64(input, 8) != result_abi or
        readU64(input, 16) != result_bytes or
        readU64(input, 24) != allowed_flags)
        return Error.InvalidWire;
    var value: GeneratedAudioResultV1 = undefined;
    const scalars = [_]*u64{
        &value.request_epoch,
        &value.generation,
        &value.chunk_index,
        &value.start_frame,
        &value.frame_count,
        &value.end_frame,
        &value.sample_rate,
        &value.channels,
        &value.bytes_per_sample,
        &value.source_output_bytes,
        &value.pcm_bytes,
        &value.publication_sequence,
        &value.visible_chunks_before,
        &value.visible_chunks_after,
        &value.visible_frames_before,
        &value.visible_frames_after,
    };
    for (scalars, 0..) |field, index|
        field.* = readU64(input, 32 + index * 8);
    value.plan_sha256 = digestAt(input, 160);
    value.provenance_sha256 = digestAt(input, 192);
    value.artifact_sha256 = digestAt(input, 224);
    value.source_result_sha256 = digestAt(input, 256);
    value.source_output_sha256 = digestAt(input, 288);
    value.media_object_sha256 = digestAt(input, 320);
    value.output_sha256 = digestAt(input, 352);
    value.resource_receipt_sha256 = digestAt(input, 384);
    value.state_before_sha256 = digestAt(input, 416);
    value.previous_publication_result_sha256 =
        digestAt(input, 448);
    value.renderer_implementation_sha256 =
        digestAt(input, 480);
    value.challenge_sha256 = digestAt(input, 512);
    value.result_sha256 = digestAt(input, result_body_bytes);
    try validateResultV1(value);
    var canonical: [result_bytes]u8 = undefined;
    _ = try encodeResultV1(value, &canonical);
    if (!std.mem.eql(u8, input, &canonical))
        return Error.InvalidWire;
    return value;
}

pub fn encodePlaybackObservationV1(
    observation: PlaybackObservationV1,
    output: *[observation_bytes]u8,
) Error![]const u8 {
    try validatePlaybackObservationV1(observation);
    writeObservationBodyV1(
        observation,
        output[0..observation_body_bytes],
    );
    @memcpy(
        output[observation_body_bytes..],
        &observation.observation_sha256,
    );
    return output;
}

pub fn decodePlaybackObservationV1(
    input: []const u8,
) Error!PlaybackObservationV1 {
    if (input.len != observation_bytes or
        !std.mem.eql(u8, input[0..8], &observation_magic) or
        readU64(input, 8) != observation_abi or
        readU64(input, 16) != observation_bytes or
        readU64(input, 24) != allowed_flags)
        return Error.InvalidWire;
    var value: PlaybackObservationV1 = undefined;
    const scalars = [_]*u64{
        &value.request_epoch,
        &value.playback_sequence,
        &value.chunk_index,
        &value.start_frame,
        &value.frame_count,
        &value.consumed_frames,
        &value.sample_rate,
        &value.channels,
        &value.bytes_per_sample,
    };
    for (scalars, 0..) |field, index|
        field.* = readU64(input, 32 + index * 8);
    value.output_sha256 = digestAt(input, 104);
    value.sink_implementation_sha256 = digestAt(input, 136);
    value.sink_instance_sha256 = digestAt(input, 168);
    value.challenge_sha256 = digestAt(input, 200);
    value.observation_sha256 =
        digestAt(input, observation_body_bytes);
    try validatePlaybackObservationV1(value);
    var canonical: [observation_bytes]u8 = undefined;
    _ = try encodePlaybackObservationV1(value, &canonical);
    if (!std.mem.eql(u8, input, &canonical))
        return Error.InvalidWire;
    return value;
}

pub fn encodePlaybackAckPlanV1(
    plan: PlaybackAckPlanV1,
    output: *[ack_plan_bytes]u8,
) Error![]const u8 {
    try validatePlaybackAckPlanV1(plan);
    writeAckPlanBodyV1(plan, output[0..ack_plan_body_bytes]);
    @memcpy(output[ack_plan_body_bytes..], &plan.plan_sha256);
    return output;
}

pub fn decodePlaybackAckPlanV1(
    input: []const u8,
) Error!PlaybackAckPlanV1 {
    if (input.len != ack_plan_bytes or
        !std.mem.eql(u8, input[0..8], &ack_plan_magic) or
        readU64(input, 8) != ack_plan_abi or
        readU64(input, 16) != ack_plan_bytes or
        readU64(input, 24) != allowed_flags)
        return Error.InvalidWire;
    var value: PlaybackAckPlanV1 = undefined;
    const scalars = [_]*u64{
        &value.request_epoch,
        &value.generation,
        &value.playback_sequence,
        &value.chunk_index,
        &value.start_frame,
        &value.frame_count,
        &value.end_frame,
        &value.consumed_frames,
        &value.sample_rate,
        &value.channels,
        &value.bytes_per_sample,
        &value.acknowledged_chunks_before,
        &value.acknowledged_chunks_after,
        &value.acknowledged_frames_before,
        &value.acknowledged_frames_after,
    };
    for (scalars, 0..) |field, index|
        field.* = readU64(input, 32 + index * 8);
    value.state_before_sha256 = digestAt(input, 152);
    value.publication_result_sha256 = digestAt(input, 184);
    value.output_sha256 = digestAt(input, 216);
    value.sink_implementation_sha256 = digestAt(input, 248);
    value.sink_instance_sha256 = digestAt(input, 280);
    value.observation_sha256 = digestAt(input, 312);
    value.previous_ack_result_sha256 = digestAt(input, 344);
    value.challenge_sha256 = digestAt(input, 376);
    value.plan_sha256 = digestAt(input, ack_plan_body_bytes);
    try validatePlaybackAckPlanV1(value);
    var canonical: [ack_plan_bytes]u8 = undefined;
    _ = try encodePlaybackAckPlanV1(value, &canonical);
    if (!std.mem.eql(u8, input, &canonical))
        return Error.InvalidWire;
    return value;
}

pub fn encodePlaybackAckResultV1(
    result: PlaybackAckResultV1,
    output: *[ack_result_bytes]u8,
) Error![]const u8 {
    try validatePlaybackAckResultV1(result);
    writeAckResultBodyV1(
        result,
        output[0..ack_result_body_bytes],
    );
    @memcpy(
        output[ack_result_body_bytes..],
        &result.result_sha256,
    );
    return output;
}

pub fn decodePlaybackAckResultV1(
    input: []const u8,
) Error!PlaybackAckResultV1 {
    if (input.len != ack_result_bytes or
        !std.mem.eql(u8, input[0..8], &ack_result_magic) or
        readU64(input, 8) != ack_result_abi or
        readU64(input, 16) != ack_result_bytes or
        readU64(input, 24) != allowed_flags)
        return Error.InvalidWire;
    var value: PlaybackAckResultV1 = undefined;
    const scalars = [_]*u64{
        &value.request_epoch,
        &value.generation,
        &value.playback_sequence,
        &value.chunk_index,
        &value.start_frame,
        &value.frame_count,
        &value.end_frame,
        &value.consumed_frames,
        &value.sample_rate,
        &value.channels,
        &value.bytes_per_sample,
        &value.acknowledged_chunks_before,
        &value.acknowledged_chunks_after,
        &value.acknowledged_frames_before,
        &value.acknowledged_frames_after,
    };
    for (scalars, 0..) |field, index|
        field.* = readU64(input, 32 + index * 8);
    value.plan_sha256 = digestAt(input, 152);
    value.state_before_sha256 = digestAt(input, 184);
    value.publication_result_sha256 = digestAt(input, 216);
    value.output_sha256 = digestAt(input, 248);
    value.sink_implementation_sha256 = digestAt(input, 280);
    value.sink_instance_sha256 = digestAt(input, 312);
    value.observation_sha256 = digestAt(input, 344);
    value.previous_publication_result_sha256 =
        digestAt(input, 376);
    value.previous_ack_result_sha256 = digestAt(input, 408);
    value.challenge_sha256 = digestAt(input, 440);
    value.result_sha256 = digestAt(input, ack_result_body_bytes);
    try validatePlaybackAckResultV1(value);
    var canonical: [ack_result_bytes]u8 = undefined;
    _ = try encodePlaybackAckResultV1(value, &canonical);
    if (!std.mem.eql(u8, input, &canonical))
        return Error.InvalidWire;
    return value;
}

pub fn stateRootV1(state: GeneratedAudioStateV1) Digest {
    var body: [state_body_bytes]u8 = undefined;
    writeStateBodyV1(state, &body);
    return domainRoot(state_domain, &body);
}

pub fn planRootV1(plan: GeneratedAudioPlanV1) Digest {
    var body: [plan_body_bytes]u8 = undefined;
    writePlanBodyV1(plan, &body);
    return domainRoot(plan_domain, &body);
}

pub fn provenanceRootV1(
    provenance: GeneratedAudioProvenanceV1,
) Digest {
    var body: [provenance_body_bytes]u8 = undefined;
    writeProvenanceBodyV1(provenance, &body);
    return domainRoot(provenance_domain, &body);
}

pub fn resultRootV1(result: GeneratedAudioResultV1) Digest {
    var body: [result_body_bytes]u8 = undefined;
    writeResultBodyV1(result, &body);
    return domainRoot(result_domain, &body);
}

pub fn observationRootV1(
    observation: PlaybackObservationV1,
) Digest {
    var body: [observation_body_bytes]u8 = undefined;
    writeObservationBodyV1(observation, &body);
    return domainRoot(observation_domain, &body);
}

pub fn ackPlanRootV1(plan: PlaybackAckPlanV1) Digest {
    var body: [ack_plan_body_bytes]u8 = undefined;
    writeAckPlanBodyV1(plan, &body);
    return domainRoot(ack_plan_domain, &body);
}

pub fn ackResultRootV1(result: PlaybackAckResultV1) Digest {
    var body: [ack_result_body_bytes]u8 = undefined;
    writeAckResultBodyV1(result, &body);
    return domainRoot(ack_result_domain, &body);
}

fn writeStateBodyV1(
    state: GeneratedAudioStateV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &state_magic);
    writeU64(output, 8, state_abi);
    writeU64(output, 16, state_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        state.request_epoch,
        state.generation,
        state.sample_rate,
        state.channels,
        state.bytes_per_sample,
        state.next_chunk_index,
        state.next_start_frame,
        state.visible_chunks,
        state.visible_frames,
        state.acknowledged_chunks,
        state.acknowledged_frames,
        state.playback_sequence,
        state.pending,
        state.pending_chunk_index,
        state.pending_start_frame,
        state.pending_frame_count,
    };
    writeScalars(output, 32, &scalars);
    const digests = [_]Digest{
        state.artifact_sha256,
        state.tenant_scope_sha256,
        state.metadata_policy_sha256,
        state.previous_publication_result_sha256,
        state.previous_ack_result_sha256,
        state.pending_publication_result_sha256,
        state.pending_output_sha256,
        state.challenge_sha256,
    };
    writeDigests(output, 160, &digests);
}

fn writePlanBodyV1(
    plan: GeneratedAudioPlanV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &plan_magic);
    writeU64(output, 8, plan_abi);
    writeU64(output, 16, plan_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        plan.request_epoch,
        plan.generation,
        plan.chunk_index,
        plan.start_frame,
        plan.frame_count,
        plan.sample_rate,
        plan.channels,
        plan.bytes_per_sample,
        plan.source_output_bytes,
        plan.pcm_bytes,
        plan.maximum_output_bytes,
        plan.publication_sequence,
        plan.visible_chunks_before,
        plan.visible_chunks_after,
        plan.visible_frames_before,
        plan.visible_frames_after,
        plan.logical_units,
        plan.required_capabilities,
        plan.renderer_abi,
    };
    writeScalars(output, 32, &scalars);
    const digests = [_]Digest{
        plan.artifact_sha256,
        plan.source_result_sha256,
        plan.source_output_sha256,
        plan.renderer_payload_sha256,
        plan.renderer_implementation_sha256,
        plan.tenant_scope_sha256,
        plan.metadata_policy_sha256,
        plan.challenge_sha256,
        plan.previous_publication_result_sha256,
        plan.media_object_sha256,
        plan.state_before_sha256,
    };
    writeDigests(output, 184, &digests);
}

fn writeProvenanceBodyV1(
    value: GeneratedAudioProvenanceV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &provenance_magic);
    writeU64(output, 8, provenance_abi);
    writeU64(output, 16, provenance_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        value.request_epoch,
        value.generation,
        value.chunk_index,
        value.start_frame,
        value.frame_count,
        value.sample_rate,
        value.channels,
        value.bytes_per_sample,
        value.source_output_bytes,
        value.pcm_bytes,
        value.renderer_abi,
    };
    writeScalars(output, 32, &scalars);
    const digests = [_]Digest{
        value.plan_sha256,
        value.artifact_sha256,
        value.source_result_sha256,
        value.source_output_sha256,
        value.renderer_payload_sha256,
        value.renderer_implementation_sha256,
        value.media_object_sha256,
        value.output_sha256,
        value.tenant_scope_sha256,
        value.metadata_policy_sha256,
        value.challenge_sha256,
    };
    writeDigests(output, 120, &digests);
}

fn writeResultBodyV1(
    value: GeneratedAudioResultV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &result_magic);
    writeU64(output, 8, result_abi);
    writeU64(output, 16, result_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        value.request_epoch,
        value.generation,
        value.chunk_index,
        value.start_frame,
        value.frame_count,
        value.end_frame,
        value.sample_rate,
        value.channels,
        value.bytes_per_sample,
        value.source_output_bytes,
        value.pcm_bytes,
        value.publication_sequence,
        value.visible_chunks_before,
        value.visible_chunks_after,
        value.visible_frames_before,
        value.visible_frames_after,
    };
    writeScalars(output, 32, &scalars);
    const digests = [_]Digest{
        value.plan_sha256,
        value.provenance_sha256,
        value.artifact_sha256,
        value.source_result_sha256,
        value.source_output_sha256,
        value.media_object_sha256,
        value.output_sha256,
        value.resource_receipt_sha256,
        value.state_before_sha256,
        value.previous_publication_result_sha256,
        value.renderer_implementation_sha256,
        value.challenge_sha256,
    };
    writeDigests(output, 160, &digests);
}

fn writeObservationBodyV1(
    value: PlaybackObservationV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &observation_magic);
    writeU64(output, 8, observation_abi);
    writeU64(output, 16, observation_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        value.request_epoch,
        value.playback_sequence,
        value.chunk_index,
        value.start_frame,
        value.frame_count,
        value.consumed_frames,
        value.sample_rate,
        value.channels,
        value.bytes_per_sample,
    };
    writeScalars(output, 32, &scalars);
    const digests = [_]Digest{
        value.output_sha256,
        value.sink_implementation_sha256,
        value.sink_instance_sha256,
        value.challenge_sha256,
    };
    writeDigests(output, 104, &digests);
}

fn writeAckPlanBodyV1(
    value: PlaybackAckPlanV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &ack_plan_magic);
    writeU64(output, 8, ack_plan_abi);
    writeU64(output, 16, ack_plan_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        value.request_epoch,
        value.generation,
        value.playback_sequence,
        value.chunk_index,
        value.start_frame,
        value.frame_count,
        value.end_frame,
        value.consumed_frames,
        value.sample_rate,
        value.channels,
        value.bytes_per_sample,
        value.acknowledged_chunks_before,
        value.acknowledged_chunks_after,
        value.acknowledged_frames_before,
        value.acknowledged_frames_after,
    };
    writeScalars(output, 32, &scalars);
    const digests = [_]Digest{
        value.state_before_sha256,
        value.publication_result_sha256,
        value.output_sha256,
        value.sink_implementation_sha256,
        value.sink_instance_sha256,
        value.observation_sha256,
        value.previous_ack_result_sha256,
        value.challenge_sha256,
    };
    writeDigests(output, 152, &digests);
}

fn writeAckResultBodyV1(
    value: PlaybackAckResultV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &ack_result_magic);
    writeU64(output, 8, ack_result_abi);
    writeU64(output, 16, ack_result_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        value.request_epoch,
        value.generation,
        value.playback_sequence,
        value.chunk_index,
        value.start_frame,
        value.frame_count,
        value.end_frame,
        value.consumed_frames,
        value.sample_rate,
        value.channels,
        value.bytes_per_sample,
        value.acknowledged_chunks_before,
        value.acknowledged_chunks_after,
        value.acknowledged_frames_before,
        value.acknowledged_frames_after,
    };
    writeScalars(output, 32, &scalars);
    const digests = [_]Digest{
        value.plan_sha256,
        value.state_before_sha256,
        value.publication_result_sha256,
        value.output_sha256,
        value.sink_implementation_sha256,
        value.sink_instance_sha256,
        value.observation_sha256,
        value.previous_publication_result_sha256,
        value.previous_ack_result_sha256,
        value.challenge_sha256,
    };
    writeDigests(output, 152, &digests);
}

fn writeScalars(
    output: []u8,
    start: usize,
    values: []const u64,
) void {
    for (values, 0..) |value, index|
        writeU64(output, start + index * 8, value);
}

fn writeDigests(
    output: []u8,
    start: usize,
    values: []const Digest,
) void {
    for (values, 0..) |digest, index| {
        const offset = start + index * 32;
        @memcpy(output[offset .. offset + 32], &digest);
    }
}

fn domainRoot(domain: []const u8, body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(body);
    return hash.finalResult();
}

fn digestAt(input: []const u8, offset: usize) Digest {
    var digest: Digest = undefined;
    @memcpy(&digest, input[offset .. offset + 32]);
    return digest;
}

fn buffersDisjoint(
    mutable: []const []u8,
    immutable: []const []const u8,
) bool {
    for (mutable, 0..) |left, index| {
        for (mutable[index + 1 ..]) |right| {
            if (slicesOverlap(left, right))
                return false;
        }
        for (immutable) |right| {
            if (slicesOverlap(left, right))
                return false;
        }
    }
    return true;
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0)
        return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left.len,
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right.len,
    ) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn checkedMul(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(
        u64,
        output[offset..][0..8],
        value,
        .little,
    );
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset..][0..8],
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

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    hashU64(hash, claim.capsule_bytes);
    hashU64(hash, claim.kv_bytes);
    hashU64(hash, claim.activation_bytes);
    hashU64(hash, claim.partial_bytes);
    hashU64(hash, claim.logits_bytes);
    hashU64(hash, claim.output_journal_bytes);
    hashU64(hash, claim.staging_bytes);
    hashU64(hash, claim.device_bytes);
    hashU64(hash, claim.io_bytes);
    hashU64(hash, claim.queue_slots);
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestFromHex(hex: []const u8) !Digest {
    var digest: Digest = undefined;
    _ = try std.fmt.hexToBytes(&digest, hex);
    return digest;
}

const TestStorage = struct {
    slots: [12]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 12,
    roots: [12]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 12,
    nodes: [24]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 24,
};

const TestChunk = struct {
    media_object: media.MediaObjectV1,
    plan: GeneratedAudioPlanV1,
};

fn makeTestState() Error!GeneratedAudioStateV1 {
    return makeInitialStateV1(
        91_001,
        16_000,
        1,
        model.sha256("generated audio test artifact"),
        model.sha256("generated audio test tenant"),
        model.sha256("generated audio test policy"),
        model.sha256("generated audio test challenge"),
    );
}

fn testSourceResultRootV1(
    state: GeneratedAudioStateV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier.generated-audio-test-source-result.v1");
    hashU64(&hash, state.next_chunk_index);
    hashU64(&hash, state.next_start_frame);
    hash.update(&state.previous_publication_result_sha256);
    return hash.finalResult();
}

fn makeTestChunk(
    state: GeneratedAudioStateV1,
    source_output: []const u8,
    renderer: RendererV1,
) Error!TestChunk {
    if (source_output.len == 0 or source_output.len > 16)
        return Error.InvalidPlan;
    var pcm: [32]u8 = undefined;
    const pcm_len = source_output.len * 2;
    try renderReferencePcmV1(
        source_output,
        pcm[0..pcm_len],
    );
    const source_result_sha256 = testSourceResultRootV1(state);
    const source_output_sha256 = model.sha256(source_output);
    const media_object = try makeAudioMediaObjectV1(
        state,
        @intCast(source_output.len / state.channels),
        model.sha256(pcm[0..pcm_len]),
        source_result_sha256,
        source_output_sha256,
        renderer.implementation_sha256,
    );
    const object_root = try mediaObjectRootV1(media_object);
    const plan = try makePlanV1(
        state,
        @intCast(source_output.len / state.channels),
        @intCast(source_output.len),
        maximum_pcm_bytes,
        renderer.required_capabilities,
        renderer.renderer_abi,
        source_result_sha256,
        source_output_sha256,
        model.sha256(reference_renderer_payload),
        renderer.implementation_sha256,
        object_root,
    );
    return .{
        .media_object = media_object,
        .plan = plan,
    };
}

fn publishTestChunk(
    bank: *resource_bank.Bank,
    state: *GeneratedAudioStateV1,
    owner_key: u64,
    source_output: []const u8,
    renderer_context: *anyopaque,
) !GeneratedAudioResultV1 {
    const renderer = referenceRendererV1(renderer_context);
    const chunk = try makeTestChunk(
        state.*,
        source_output,
        renderer,
    );
    var session: Session = .{};
    try session.initV1(
        bank,
        owner_key,
        state,
        chunk.plan,
        chunk.media_object,
        reference_renderer_payload,
        renderer,
    );
    var candidate_output: [32]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output = [_]u8{0} ** 32;
    var visible_provenance =
        [_]u8{0} ** provenance_bytes;
    var visible_result = [_]u8{0} ** result_bytes;
    _ = try session.prepareV1(
        source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    const result = try session.commitV1();
    try session.closeAndRelease();
    return result;
}

fn expectStateWireRejected(input: []const u8) !void {
    if (decodeStateV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectPlanWireRejected(input: []const u8) !void {
    if (decodePlanV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectProvenanceWireRejected(input: []const u8) !void {
    if (decodeProvenanceV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectResultWireRejected(input: []const u8) !void {
    if (decodeResultV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectObservationWireRejected(input: []const u8) !void {
    if (decodePlaybackObservationV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectAckPlanWireRejected(input: []const u8) !void {
    if (decodePlaybackAckPlanV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

fn expectAckResultWireRejected(input: []const u8) !void {
    if (decodePlaybackAckResultV1(input)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "generated audio wires are canonical and mutation complete" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        92_001,
    );
    var renderer_context: u8 = 1;
    const renderer = referenceRendererV1(&renderer_context);
    var state = try makeTestState();
    const initial_state = state;
    const source_output = [_]u8{ 129, 127 };
    const chunk = try makeTestChunk(
        state,
        &source_output,
        renderer,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        93_001,
        &state,
        chunk.plan,
        chunk.media_object,
        reference_renderer_payload,
        renderer,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output = [_]u8{0} ** 4;
    var visible_provenance =
        [_]u8{0} ** provenance_bytes;
    var visible_result = [_]u8{0} ** result_bytes;
    _ = try session.prepareV1(
        &source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    const publication_result = try session.commitV1();
    try session.closeAndRelease();
    const observation = try makePlaybackObservationV1(
        state,
        model.sha256("test playback sink implementation"),
        model.sha256("test playback sink instance"),
    );
    const ack_plan = try makePlaybackAckPlanV1(
        state,
        publication_result,
        observation,
    );
    const ack_result = try makePlaybackAckResultV1(
        state,
        publication_result,
        observation,
        ack_plan,
    );

    var state_wire: [state_bytes]u8 = undefined;
    _ = try encodeStateV1(initial_state, &state_wire);
    try std.testing.expectEqual(
        initial_state,
        try decodeStateV1(&state_wire),
    );
    for (0..state_wire.len) |index| {
        var mutated = state_wire;
        mutated[index] ^= 1;
        try expectStateWireRejected(&mutated);
    }

    var plan_wire: [plan_bytes]u8 = undefined;
    _ = try encodePlanV1(chunk.plan, &plan_wire);
    try std.testing.expectEqual(
        chunk.plan,
        try decodePlanV1(&plan_wire),
    );
    for (0..plan_wire.len) |index| {
        var mutated = plan_wire;
        mutated[index] ^= 1;
        try expectPlanWireRejected(&mutated);
    }

    try std.testing.expectEqual(
        session.prepared_provenance,
        null,
    );
    const provenance =
        try decodeProvenanceV1(&visible_provenance);
    try validateProvenanceBindingV1(chunk.plan, provenance);
    var rebound_provenance = provenance;
    rebound_provenance.source_output_bytes += 1;
    rebound_provenance.provenance_sha256 =
        provenanceRootV1(rebound_provenance);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateProvenanceBindingV1(
            chunk.plan,
            rebound_provenance,
        ),
    );
    for (0..visible_provenance.len) |index| {
        var mutated = visible_provenance;
        mutated[index] ^= 1;
        try expectProvenanceWireRejected(&mutated);
    }
    try std.testing.expectEqual(
        publication_result,
        try decodeResultV1(&visible_result),
    );
    for (0..visible_result.len) |index| {
        var mutated = visible_result;
        mutated[index] ^= 1;
        try expectResultWireRejected(&mutated);
    }

    var observation_wire: [observation_bytes]u8 = undefined;
    _ = try encodePlaybackObservationV1(
        observation,
        &observation_wire,
    );
    for (0..observation_wire.len) |index| {
        var mutated = observation_wire;
        mutated[index] ^= 1;
        try expectObservationWireRejected(&mutated);
    }

    var ack_plan_wire: [ack_plan_bytes]u8 = undefined;
    _ = try encodePlaybackAckPlanV1(
        ack_plan,
        &ack_plan_wire,
    );
    for (0..ack_plan_wire.len) |index| {
        var mutated = ack_plan_wire;
        mutated[index] ^= 1;
        try expectAckPlanWireRejected(&mutated);
    }

    var ack_result_wire: [ack_result_bytes]u8 = undefined;
    _ = try encodePlaybackAckResultV1(
        ack_result,
        &ack_result_wire,
    );
    for (0..ack_result_wire.len) |index| {
        var mutated = ack_result_wire;
        mutated[index] ^= 1;
        try expectAckResultWireRejected(&mutated);
    }
    try std.testing.expectEqual(
        chunk.plan.plan_sha256,
        provenance.plan_sha256,
    );
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "generated audio publication and playback acknowledgement gate chunks" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        94_001,
    );
    var renderer_context: u8 = 1;
    var state = try makeTestState();
    const initial_state = state;
    const first_source = [_]u8{ 129, 127 };
    const first_chunk = try makeTestChunk(
        state,
        &first_source,
        referenceRendererV1(&renderer_context),
    );
    var first_pcm: [4]u8 = undefined;
    try renderReferencePcmV1(&first_source, &first_pcm);
    const first_provenance = try makeProvenanceV1(
        first_chunk.plan,
        model.sha256(&first_pcm),
    );
    const first_result = try publishTestChunk(
        &bank,
        &state,
        95_001,
        &first_source,
        &renderer_context,
    );
    try std.testing.expectEqual(@as(u64, 1), state.pending);
    try std.testing.expectEqual(@as(u64, 1), state.visible_chunks);
    try std.testing.expectEqual(@as(u64, 0), state.acknowledged_chunks);
    try std.testing.expectError(
        Error.PlaybackPending,
        makePlanV1(
            state,
            2,
            2,
            4,
            0,
            reference_renderer_abi,
            model.sha256("blocked source result"),
            model.sha256("blocked source output"),
            model.sha256(reference_renderer_payload),
            referenceRendererV1(
                &renderer_context,
            ).implementation_sha256,
            model.sha256("blocked media"),
        ),
    );
    const sink_implementation =
        model.sha256("test playback sink implementation");
    const sink_instance =
        model.sha256("test playback sink instance");
    const first_observation = try makePlaybackObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    const first_ack_plan = try makePlaybackAckPlanV1(
        state,
        first_result,
        first_observation,
    );
    const first_ack = try acknowledgePlaybackV1(
        &state,
        first_result,
        first_observation,
        first_ack_plan,
    );
    try std.testing.expectEqual(@as(u64, 0), state.pending);
    try std.testing.expectEqual(@as(u64, 1), state.acknowledged_chunks);
    try std.testing.expectEqual(@as(u64, 2), state.acknowledged_frames);
    try std.testing.expectEqual(
        first_ack.result_sha256,
        state.previous_ack_result_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "7c6c4cf1519e02163a1b9009d8bc3c890566edf5bdd7d4fb1d63ddec9e2df654",
        ),
        initial_state.state_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "57f4887803a87eb795b98fd3a10bd8e19839807d14746de67e9482e4ebd14122",
        ),
        first_chunk.plan.plan_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "f075731d49893ca58497090debcffcc736f1e61253577abe78e1fba646702567",
        ),
        first_provenance.provenance_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "1055112e6118209e442ccb44b1fa39e55d765c76d9790357e5ec7d203d52bc13",
        ),
        first_result.result_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "603e75167914c5a32f75cfd9baa20caefa2518a0bb5361132d835f742bc0350e",
        ),
        first_observation.observation_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "f134f093575d6f19b84c6d1885736856b4a67011ae99fdfca590426ddf5d83fd",
        ),
        first_ack_plan.plan_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHex(
            "455544e586d1e20191f3792430ce248fd914a51c0aa9d76150ea0818558c54a6",
        ),
        first_ack.result_sha256,
    );

    const second_source = [_]u8{ 130, 126 };
    const second_result = try publishTestChunk(
        &bank,
        &state,
        95_002,
        &second_source,
        &renderer_context,
    );
    const second_observation = try makePlaybackObservationV1(
        state,
        sink_implementation,
        sink_instance,
    );
    const second_ack_plan = try makePlaybackAckPlanV1(
        state,
        second_result,
        second_observation,
    );
    _ = try acknowledgePlaybackV1(
        &state,
        second_result,
        second_observation,
        second_ack_plan,
    );
    try std.testing.expectEqual(@as(u64, 4), state.generation);
    try std.testing.expectEqual(@as(u64, 2), state.visible_chunks);
    try std.testing.expectEqual(@as(u64, 4), state.visible_frames);
    try std.testing.expectEqual(@as(u64, 2), state.acknowledged_chunks);
    try std.testing.expectEqual(@as(u64, 4), state.acknowledged_frames);
    try std.testing.expectEqual(@as(u64, 2), state.playback_sequence);
    try std.testing.expectEqual(@as(u64, 0), state.pending);
    try std.testing.expectEqual(
        try digestFromHex(
            "eee498d7003a186732ed3a3e1bfb8824a0a69b01ef8020fa2cce8d667db1b2a9",
        ),
        state.state_sha256,
    );
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "generated audio abort and candidate drift preserve visibility" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        96_001,
    );
    var renderer_context: u8 = 1;
    const renderer = referenceRendererV1(&renderer_context);
    var state = try makeTestState();
    const state_before = state;
    const source_output = [_]u8{ 129, 127 };
    const chunk = try makeTestChunk(
        state,
        &source_output,
        renderer,
    );
    var session: Session = .{};
    try session.initV1(
        &bank,
        97_001,
        &state,
        chunk.plan,
        chunk.media_object,
        reference_renderer_payload,
        renderer,
    );
    var candidate_output: [4]u8 = undefined;
    var candidate_provenance: [provenance_bytes]u8 = undefined;
    var candidate_result: [result_bytes]u8 = undefined;
    var visible_output = [_]u8{0xa5} ** 4;
    var visible_provenance =
        [_]u8{0xa5} ** provenance_bytes;
    var visible_result = [_]u8{0xa5} ** result_bytes;
    var foreign_source = source_output;
    foreign_source[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidBinding,
        session.prepareV1(
            &foreign_source,
            &candidate_output,
            &candidate_provenance,
            &candidate_result,
            &visible_output,
            &visible_provenance,
            &visible_result,
        ),
    );
    _ = try session.prepareV1(
        &source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    candidate_output[0] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(state_before, state);
    try std.testing.expect(
        std.mem.allEqual(u8, &visible_output, 0xa5),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate_output, 0),
    );
    _ = try session.prepareV1(
        &source_output,
        &candidate_output,
        &candidate_provenance,
        &candidate_result,
        &visible_output,
        &visible_provenance,
        &visible_result,
    );
    try session.abortV1();
    try std.testing.expectEqual(state_before, state);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate_output, 0),
    );
    try session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "playback acknowledgement rejects partial foreign and duplicate evidence" {
    var storage: TestStorage = .{};
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &storage.slots,
        &storage.roots,
        &storage.nodes,
        .{},
        98_001,
    );
    var renderer_context: u8 = 1;
    var state = try makeTestState();
    const source_output = [_]u8{ 129, 127 };
    const publication_result = try publishTestChunk(
        &bank,
        &state,
        99_001,
        &source_output,
        &renderer_context,
    );
    const state_before = state;
    const observation = try makePlaybackObservationV1(
        state,
        model.sha256("test playback sink implementation"),
        model.sha256("test playback sink instance"),
    );
    const ack_plan = try makePlaybackAckPlanV1(
        state,
        publication_result,
        observation,
    );

    var partial_observation = observation;
    partial_observation.consumed_frames -= 1;
    partial_observation.observation_sha256 =
        observationRootV1(partial_observation);
    try std.testing.expectError(
        Error.InvalidObservation,
        acknowledgePlaybackV1(
            &state,
            publication_result,
            partial_observation,
            ack_plan,
        ),
    );
    try std.testing.expectEqual(state_before, state);

    var foreign_result = publication_result;
    foreign_result.output_sha256 =
        model.sha256("foreign output");
    foreign_result.result_sha256 = resultRootV1(foreign_result);
    try std.testing.expectError(
        Error.InvalidBinding,
        acknowledgePlaybackV1(
            &state,
            foreign_result,
            observation,
            ack_plan,
        ),
    );
    try std.testing.expectEqual(state_before, state);

    _ = try acknowledgePlaybackV1(
        &state,
        publication_result,
        observation,
        ack_plan,
    );
    try std.testing.expectError(
        Error.NoPlaybackPending,
        acknowledgePlaybackV1(
            &state,
            publication_result,
            observation,
            ack_plan,
        ),
    );
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}
