const std = @import("std");
const image = @import("generated_image_publication.zig");
const audio = @import("generated_audio_playback.zig");
const video = @import("generated_video_display.zig");
const model = @import("model_contract.zig");

pub const Digest = [32]u8;

pub const member_abi: u64 = 1;
pub const member_body_bytes: usize = 448;
pub const member_bytes: usize = member_body_bytes + 32;

pub const checkpoint_abi: u64 = 1;
pub const checkpoint_body_bytes: usize = 768;
pub const checkpoint_bytes: usize = checkpoint_body_bytes + 32;

pub const selector_abi: u64 = 1;
pub const selector_body_bytes: usize = 320;
pub const selector_bytes: usize = selector_body_bytes + 32;

pub const image_modality: u64 = 1;
pub const audio_modality: u64 = 2;
pub const video_modality: u64 = 3;
pub const required_member_count: u64 = 3;

const member_wire = WireConfig{
    .magic = "GLGMMBR1".*,
    .abi = member_abi,
    .body_bytes = member_body_bytes,
    .total_bytes = member_bytes,
    .domain = "glacier.generated-media-member.v1",
};
const checkpoint_wire = WireConfig{
    .magic = "GLGMCHK1".*,
    .abi = checkpoint_abi,
    .body_bytes = checkpoint_body_bytes,
    .total_bytes = checkpoint_bytes,
    .domain = "glacier.generated-media-checkpoint.v1",
};
const selector_wire = WireConfig{
    .magic = "GLGMSEL1".*,
    .abi = selector_abi,
    .body_bytes = selector_body_bytes,
    .total_bytes = selector_bytes,
    .domain = "glacier.generated-media-selector.v1",
};
const reference_domain = "glacier.generated-media-reference.v1";

const WireConfig = struct {
    magic: [8]u8,
    abi: u64,
    body_bytes: usize,
    total_bytes: usize,
    domain: []const u8,
};

pub const Error = error{
    InvalidMember,
    InvalidMemberRoot,
    InvalidCheckpoint,
    InvalidCheckpointRoot,
    InvalidSelector,
    InvalidSelectorRoot,
    InvalidBinding,
    InvalidWire,
    ArithmeticOverflow,
    BufferTooSmall,
};

pub const GeneratedMediaMemberV1 = struct {
    request_epoch: u64,
    source_generation: u64,
    modality: u64,
    ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    unit_end: u64,
    timeline_start: u64,
    timeline_end: u64,
    byte_count: u64,
    completion_required: u64,
    completed: u64,
    artifact_sha256: Digest,
    provenance_sha256: Digest,
    result_sha256: Digest,
    output_sha256: Digest,
    media_object_sha256: Digest,
    state_after_sha256: Digest,
    completion_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    member_sha256: Digest,
};

/// Typed producer fields projected for a shared output registry.
///
/// Unlike `GeneratedMediaMemberV1`, this projection does not assert the
/// synchronized one-member-per-modality checkpoint generation mapping.
pub const GeneratedMediaProducerProjectionV1 = struct {
    request_epoch: u64,
    modality: u64,
    ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    unit_end: u64,
    timeline_start: u64,
    timeline_end: u64,
    byte_count: u64,
    completion_required: u64,
    completed: u64,
    artifact_sha256: Digest,
    provenance_sha256: Digest,
    result_sha256: Digest,
    output_sha256: Digest,
    media_object_sha256: Digest,
    state_after_sha256: Digest,
    completion_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
};

pub const GeneratedMediaCheckpointV1 = struct {
    request_epoch: u64,
    generation: u64,
    publication_sequence: u64,
    member_count: u64,
    total_bytes: u64,
    total_units: u64,
    image_ordinal: u64,
    audio_ordinal: u64,
    video_ordinal: u64,
    image_unit_end: u64,
    audio_unit_end: u64,
    video_unit_end: u64,
    video_timeline_end: u64,
    image_bytes: u64,
    audio_bytes: u64,
    video_bytes: u64,
    image_units: u64,
    audio_units: u64,
    video_units: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    image_member_sha256: Digest,
    audio_member_sha256: Digest,
    video_member_sha256: Digest,
    image_result_sha256: Digest,
    audio_result_sha256: Digest,
    video_result_sha256: Digest,
    image_output_sha256: Digest,
    audio_output_sha256: Digest,
    video_output_sha256: Digest,
    image_state_sha256: Digest,
    audio_state_sha256: Digest,
    video_state_sha256: Digest,
    audio_completion_sha256: Digest,
    video_completion_sha256: Digest,
    previous_checkpoint_sha256: Digest,
    checkpoint_sha256: Digest,
};

pub const GeneratedMediaSelectorV1 = struct {
    request_epoch: u64,
    generation: u64,
    publication_sequence: u64,
    checkpoint_wire_bytes: u64,
    member_wire_bytes: u64,
    member_count: u64,
    checkpoint_sha256: Digest,
    image_member_sha256: Digest,
    audio_member_sha256: Digest,
    video_member_sha256: Digest,
    previous_checkpoint_sha256: Digest,
    previous_selector_sha256: Digest,
    challenge_sha256: Digest,
    selector_sha256: Digest,
};

pub const ReferenceFixtureV1 = struct {
    image1: GeneratedMediaMemberV1,
    audio1: GeneratedMediaMemberV1,
    video1: GeneratedMediaMemberV1,
    checkpoint1: GeneratedMediaCheckpointV1,
    selector1: GeneratedMediaSelectorV1,
    image2: GeneratedMediaMemberV1,
    audio2: GeneratedMediaMemberV1,
    video2: GeneratedMediaMemberV1,
    checkpoint2: GeneratedMediaCheckpointV1,
    selector2: GeneratedMediaSelectorV1,
};

pub fn imageProducerProjectionV1(
    plan: image.GeneratedImagePlanV1,
    provenance: image.GeneratedImageProvenanceV1,
    result: image.GeneratedImageResultV1,
) Error!GeneratedMediaProducerProjectionV1 {
    image.validateGeneratedImagePlanV1(plan) catch
        return Error.InvalidBinding;
    image.validateGeneratedImageProvenanceV1(provenance) catch
        return Error.InvalidBinding;
    image.validateGeneratedImageResultV1(result) catch
        return Error.InvalidBinding;
    if (result.request_epoch != plan.request_epoch or
        provenance.request_epoch != plan.request_epoch or
        result.generation != plan.generation or
        provenance.generation != plan.generation or
        result.image_index != plan.image_index or
        provenance.image_index != plan.image_index or
        result.source_step != plan.source_step or
        provenance.source_step != plan.source_step or
        result.width != plan.width or result.height != plan.height or
        result.channels != plan.channels or
        result.row_stride != plan.row_stride or
        result.pixel_bytes != plan.pixel_bytes or
        provenance.width != plan.width or
        provenance.height != plan.height or
        provenance.channels != plan.channels or
        provenance.pixel_bytes != plan.pixel_bytes or
        result.publication_sequence != plan.publication_sequence or
        result.visible_images_before != plan.visible_images_before or
        result.visible_images_after != plan.visible_images_after or
        result.logical_units != plan.logical_units or
        result.decoder_abi != plan.decoder_abi or
        provenance.decoder_abi != plan.decoder_abi or
        provenance.color_model != plan.color_model or
        provenance.transfer_function != plan.transfer_function or
        provenance.alpha_mode != plan.alpha_mode or
        !digestEqual(result.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            result.provenance_sha256,
            provenance.provenance_sha256,
        ) or
        !digestEqual(provenance.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            provenance.artifact_sha256,
            plan.artifact_sha256,
        ) or
        !digestEqual(
            provenance.terminal_result_sha256,
            plan.terminal_result_sha256,
        ) or
        !digestEqual(
            provenance.terminal_plan_sha256,
            plan.terminal_plan_sha256,
        ) or
        !digestEqual(
            provenance.terminal_output_sha256,
            plan.terminal_output_sha256,
        ) or
        !digestEqual(
            provenance.terminal_state_publication_sha256,
            plan.terminal_state_publication_sha256,
        ) or
        !digestEqual(
            provenance.stateful_checkpoint_sha256,
            plan.stateful_checkpoint_sha256,
        ) or
        !digestEqual(
            provenance.decoder_payload_sha256,
            plan.decoder_payload_sha256,
        ) or
        !digestEqual(
            provenance.decoder_implementation_sha256,
            plan.decoder_implementation_sha256,
        ) or
        !digestEqual(
            provenance.media_object_sha256,
            plan.media_object_sha256,
        ) or
        !digestEqual(
            provenance.source_provenance_sha256,
            plan.source_provenance_sha256,
        ) or
        !digestEqual(result.artifact_sha256, plan.artifact_sha256) or
        !digestEqual(
            result.terminal_result_sha256,
            plan.terminal_result_sha256,
        ) or
        !digestEqual(
            result.terminal_output_sha256,
            plan.terminal_output_sha256,
        ) or
        !digestEqual(
            result.terminal_state_publication_sha256,
            plan.terminal_state_publication_sha256,
        ) or
        !digestEqual(
            result.media_object_sha256,
            plan.media_object_sha256,
        ) or
        !digestEqual(
            result.output_sha256,
            provenance.output_sha256,
        ) or
        !digestEqual(
            result.previous_result_sha256,
            plan.previous_result_sha256,
        ) or
        !digestEqual(
            result.decoder_implementation_sha256,
            plan.decoder_implementation_sha256,
        ) or
        !digestEqual(result.challenge_sha256, plan.challenge_sha256) or
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
    return .{
        .request_epoch = result.request_epoch,
        .modality = image_modality,
        .ordinal = result.image_index,
        .unit_start = result.visible_images_before,
        .unit_count = 1,
        .unit_end = result.visible_images_after,
        .timeline_start = result.visible_images_before,
        .timeline_end = result.visible_images_after,
        .byte_count = result.pixel_bytes,
        .completion_required = 0,
        .completed = 1,
        .artifact_sha256 = result.artifact_sha256,
        .provenance_sha256 = result.provenance_sha256,
        .result_sha256 = result.result_sha256,
        .output_sha256 = result.output_sha256,
        .media_object_sha256 = result.media_object_sha256,
        .state_after_sha256 = result.publication_state_after_sha256,
        .completion_sha256 = [_]u8{0} ** 32,
        .tenant_scope_sha256 = plan.tenant_scope_sha256,
        .metadata_policy_sha256 = plan.metadata_policy_sha256,
        .challenge_sha256 = plan.challenge_sha256,
    };
}

pub fn imageMemberV1(
    plan: image.GeneratedImagePlanV1,
    provenance: image.GeneratedImageProvenanceV1,
    result: image.GeneratedImageResultV1,
) Error!GeneratedMediaMemberV1 {
    const projection = try imageProducerProjectionV1(
        plan,
        provenance,
        result,
    );
    var member = memberFromProjectionV1(
        projection,
        result.generation,
    );
    member.member_sha256 = memberRootV1(member);
    try validateMemberV1(member);
    return member;
}

pub fn audioProducerProjectionV1(
    state: audio.GeneratedAudioStateV1,
    plan: audio.GeneratedAudioPlanV1,
    provenance: audio.GeneratedAudioProvenanceV1,
    result: audio.GeneratedAudioResultV1,
    acknowledgement: audio.PlaybackAckResultV1,
) Error!GeneratedMediaProducerProjectionV1 {
    audio.validateStateV1(state) catch return Error.InvalidBinding;
    audio.validateProvenanceBindingV1(plan, provenance) catch
        return Error.InvalidBinding;
    audio.validateResultV1(result) catch
        return Error.InvalidBinding;
    audio.validatePlaybackAckResultV1(acknowledgement) catch
        return Error.InvalidBinding;
    const acknowledged_generation = checkedAdd(
        result.generation,
        1,
    ) catch return Error.InvalidBinding;
    if (result.request_epoch != plan.request_epoch or
        result.generation != plan.generation or
        result.chunk_index != plan.chunk_index or
        result.start_frame != plan.start_frame or
        result.frame_count != plan.frame_count or
        result.end_frame != plan.visible_frames_after or
        result.sample_rate != plan.sample_rate or
        result.channels != plan.channels or
        result.bytes_per_sample != plan.bytes_per_sample or
        result.source_output_bytes != plan.source_output_bytes or
        result.pcm_bytes != plan.pcm_bytes or
        result.publication_sequence != plan.publication_sequence or
        result.visible_chunks_before != plan.visible_chunks_before or
        result.visible_chunks_after != plan.visible_chunks_after or
        result.visible_frames_before != plan.visible_frames_before or
        result.visible_frames_after != plan.visible_frames_after or
        !digestEqual(result.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            result.provenance_sha256,
            provenance.provenance_sha256,
        ) or
        !digestEqual(result.artifact_sha256, plan.artifact_sha256) or
        !digestEqual(
            result.source_result_sha256,
            plan.source_result_sha256,
        ) or
        !digestEqual(
            result.source_output_sha256,
            plan.source_output_sha256,
        ) or
        !digestEqual(
            result.media_object_sha256,
            plan.media_object_sha256,
        ) or
        !digestEqual(result.output_sha256, provenance.output_sha256) or
        !digestEqual(
            result.state_before_sha256,
            plan.state_before_sha256,
        ) or
        !digestEqual(
            result.previous_publication_result_sha256,
            plan.previous_publication_result_sha256,
        ) or
        !digestEqual(
            result.renderer_implementation_sha256,
            plan.renderer_implementation_sha256,
        ) or
        !digestEqual(result.challenge_sha256, plan.challenge_sha256) or
        state.pending != 0 or
        state.request_epoch != result.request_epoch or
        acknowledgement.request_epoch != result.request_epoch or
        acknowledgement.generation != acknowledged_generation or
        state.generation != acknowledgement.generation or
        acknowledgement.playback_sequence != result.chunk_index or
        acknowledgement.chunk_index != result.chunk_index or
        acknowledgement.start_frame != result.start_frame or
        acknowledgement.frame_count != result.frame_count or
        acknowledgement.end_frame != result.end_frame or
        acknowledgement.sample_rate != result.sample_rate or
        acknowledgement.channels != result.channels or
        acknowledgement.bytes_per_sample != result.bytes_per_sample or
        acknowledgement.acknowledged_chunks_before !=
            result.visible_chunks_before or
        acknowledgement.acknowledged_chunks_after !=
            result.visible_chunks_after or
        acknowledgement.acknowledged_frames_before !=
            result.visible_frames_before or
        acknowledgement.acknowledged_frames_after !=
            result.visible_frames_after or
        state.visible_chunks != result.visible_chunks_after or
        state.visible_frames != result.visible_frames_after or
        state.acknowledged_chunks != result.visible_chunks_after or
        state.acknowledged_frames != result.visible_frames_after or
        state.playback_sequence !=
            acknowledgement.acknowledged_chunks_after or
        !digestEqual(result.artifact_sha256, state.artifact_sha256) or
        !digestEqual(
            state.tenant_scope_sha256,
            plan.tenant_scope_sha256,
        ) or
        !digestEqual(
            state.metadata_policy_sha256,
            plan.metadata_policy_sha256,
        ) or
        !digestEqual(result.challenge_sha256, state.challenge_sha256) or
        !digestEqual(
            acknowledgement.publication_result_sha256,
            result.result_sha256,
        ) or
        !digestEqual(
            acknowledgement.previous_publication_result_sha256,
            result.previous_publication_result_sha256,
        ) or
        !digestEqual(
            acknowledgement.output_sha256,
            result.output_sha256,
        ) or
        !digestEqual(
            acknowledgement.challenge_sha256,
            result.challenge_sha256,
        ) or
        !digestEqual(
            state.previous_publication_result_sha256,
            result.result_sha256,
        ) or
        !digestEqual(
            state.previous_ack_result_sha256,
            acknowledgement.result_sha256,
        ))
        return Error.InvalidBinding;
    validateAudioCompletionProjectionV1(
        state,
        result,
        acknowledgement,
    ) catch return Error.InvalidBinding;
    return .{
        .request_epoch = result.request_epoch,
        .modality = audio_modality,
        .ordinal = result.chunk_index,
        .unit_start = result.start_frame,
        .unit_count = result.frame_count,
        .unit_end = result.end_frame,
        .timeline_start = result.start_frame,
        .timeline_end = result.end_frame,
        .byte_count = result.pcm_bytes,
        .completion_required = 1,
        .completed = 1,
        .artifact_sha256 = result.artifact_sha256,
        .provenance_sha256 = result.provenance_sha256,
        .result_sha256 = result.result_sha256,
        .output_sha256 = result.output_sha256,
        .media_object_sha256 = result.media_object_sha256,
        .state_after_sha256 = state.state_sha256,
        .completion_sha256 = acknowledgement.result_sha256,
        .tenant_scope_sha256 = state.tenant_scope_sha256,
        .metadata_policy_sha256 = state.metadata_policy_sha256,
        .challenge_sha256 = state.challenge_sha256,
    };
}

pub fn audioMemberV1(
    state: audio.GeneratedAudioStateV1,
    plan: audio.GeneratedAudioPlanV1,
    provenance: audio.GeneratedAudioProvenanceV1,
    result: audio.GeneratedAudioResultV1,
    acknowledgement: audio.PlaybackAckResultV1,
) Error!GeneratedMediaMemberV1 {
    const projection = try audioProducerProjectionV1(
        state,
        plan,
        provenance,
        result,
        acknowledgement,
    );
    var member = memberFromProjectionV1(
        projection,
        result.generation,
    );
    member.member_sha256 = memberRootV1(member);
    try validateMemberV1(member);
    return member;
}

pub fn videoProducerProjectionV1(
    state: video.GeneratedVideoStateV1,
    manifest: video.GeneratedVideoManifestV1,
    provenance: video.GeneratedVideoProvenanceV1,
    result: video.GeneratedVideoResultV1,
    acknowledgement: video.DisplayAckResultV1,
) Error!GeneratedMediaProducerProjectionV1 {
    video.validateStateV1(state) catch return Error.InvalidBinding;
    video.validateResultBindingV1(
        manifest,
        provenance,
        result,
    ) catch return Error.InvalidBinding;
    video.validateDisplayAckResultV1(acknowledgement) catch
        return Error.InvalidBinding;
    const acknowledged_generation = checkedAdd(
        result.generation,
        1,
    ) catch return Error.InvalidBinding;
    if (state.pending != 0 or
        state.request_epoch != result.request_epoch or
        acknowledgement.request_epoch != result.request_epoch or
        acknowledgement.generation != acknowledged_generation or
        state.generation != acknowledgement.generation or
        acknowledgement.display_sequence != result.segment_index or
        acknowledgement.segment_index != result.segment_index or
        acknowledgement.first_frame_ordinal !=
            result.first_frame_ordinal or
        acknowledgement.frame_count != result.frame_count or
        acknowledgement.end_frame_ordinal !=
            result.end_frame_ordinal or
        acknowledgement.start_tick != result.start_tick or
        acknowledgement.end_tick != result.end_tick or
        acknowledgement.displayed_segments_before !=
            result.visible_segments_before or
        acknowledgement.displayed_segments_after !=
            result.visible_segments_after or
        acknowledgement.displayed_frames_before !=
            result.visible_frames_before or
        acknowledgement.displayed_frames_after !=
            result.visible_frames_after or
        state.visible_segments != result.visible_segments_after or
        state.visible_frames != result.visible_frames_after or
        state.visible_end_tick != result.visible_end_tick_after or
        state.displayed_segments != result.visible_segments_after or
        state.displayed_frames != result.visible_frames_after or
        state.displayed_end_tick != result.visible_end_tick_after or
        state.display_sequence !=
            acknowledgement.displayed_segments_after or
        !digestEqual(result.artifact_sha256, state.artifact_sha256) or
        !digestEqual(
            state.tenant_scope_sha256,
            manifest.tenant_scope_sha256,
        ) or
        !digestEqual(
            state.metadata_policy_sha256,
            manifest.metadata_policy_sha256,
        ) or
        !digestEqual(result.challenge_sha256, state.challenge_sha256) or
        !digestEqual(
            acknowledgement.publication_result_sha256,
            result.result_sha256,
        ) or
        !digestEqual(
            acknowledgement.previous_publication_result_sha256,
            result.result_sha256,
        ) or
        !digestEqual(
            acknowledgement.output_sha256,
            result.output_sha256,
        ) or
        !digestEqual(
            acknowledgement.challenge_sha256,
            result.challenge_sha256,
        ) or
        !digestEqual(
            state.previous_publication_result_sha256,
            result.result_sha256,
        ) or
        !digestEqual(
            state.previous_ack_result_sha256,
            acknowledgement.result_sha256,
        ))
        return Error.InvalidBinding;
    validateVideoCompletionProjectionV1(
        state,
        result,
        acknowledgement,
    ) catch return Error.InvalidBinding;
    return .{
        .request_epoch = result.request_epoch,
        .modality = video_modality,
        .ordinal = result.segment_index,
        .unit_start = result.first_frame_ordinal,
        .unit_count = result.frame_count,
        .unit_end = result.end_frame_ordinal,
        .timeline_start = result.start_tick,
        .timeline_end = result.end_tick,
        .byte_count = result.total_output_bytes,
        .completion_required = 1,
        .completed = 1,
        .artifact_sha256 = result.artifact_sha256,
        .provenance_sha256 = result.provenance_sha256,
        .result_sha256 = result.result_sha256,
        .output_sha256 = result.output_sha256,
        .media_object_sha256 = result.media_object_sha256,
        .state_after_sha256 = state.state_sha256,
        .completion_sha256 = acknowledgement.result_sha256,
        .tenant_scope_sha256 = state.tenant_scope_sha256,
        .metadata_policy_sha256 = state.metadata_policy_sha256,
        .challenge_sha256 = state.challenge_sha256,
    };
}

pub fn videoMemberV1(
    state: video.GeneratedVideoStateV1,
    manifest: video.GeneratedVideoManifestV1,
    provenance: video.GeneratedVideoProvenanceV1,
    result: video.GeneratedVideoResultV1,
    acknowledgement: video.DisplayAckResultV1,
) Error!GeneratedMediaMemberV1 {
    const projection = try videoProducerProjectionV1(
        state,
        manifest,
        provenance,
        result,
        acknowledgement,
    );
    var member = memberFromProjectionV1(
        projection,
        result.generation,
    );
    member.member_sha256 = memberRootV1(member);
    try validateMemberV1(member);
    return member;
}

fn validateAudioCompletionProjectionV1(
    state: audio.GeneratedAudioStateV1,
    result: audio.GeneratedAudioResultV1,
    acknowledgement: audio.PlaybackAckResultV1,
) !void {
    if (state.sample_rate != result.sample_rate or
        state.channels != result.channels or
        state.bytes_per_sample != result.bytes_per_sample or
        state.next_chunk_index != result.visible_chunks_after or
        state.next_start_frame != result.visible_frames_after)
        return Error.InvalidBinding;

    var before = state;
    before.generation = std.math.sub(
        u64,
        result.generation,
        1,
    ) catch return Error.InvalidBinding;
    before.next_chunk_index = result.chunk_index;
    before.next_start_frame = result.start_frame;
    before.visible_chunks = result.visible_chunks_before;
    before.visible_frames = result.visible_frames_before;
    before.acknowledged_chunks =
        result.visible_chunks_before;
    before.acknowledged_frames =
        result.visible_frames_before;
    before.playback_sequence = result.chunk_index;
    before.pending = 0;
    before.pending_chunk_index = 0;
    before.pending_start_frame = 0;
    before.pending_frame_count = 0;
    before.previous_publication_result_sha256 =
        result.previous_publication_result_sha256;
    before.previous_ack_result_sha256 =
        acknowledgement.previous_ack_result_sha256;
    before.pending_publication_result_sha256 =
        [_]u8{0} ** 32;
    before.pending_output_sha256 = [_]u8{0} ** 32;
    before.state_sha256 = [_]u8{0} ** 32;
    before.state_sha256 = audio.stateRootV1(before);
    audio.validateStateV1(before) catch
        return Error.InvalidBinding;
    if (!digestEqual(
        before.state_sha256,
        result.state_before_sha256,
    )) return Error.InvalidBinding;

    var pending = state;
    pending.generation = result.generation;
    pending.acknowledged_chunks =
        result.visible_chunks_before;
    pending.acknowledged_frames =
        result.visible_frames_before;
    pending.playback_sequence = result.chunk_index;
    pending.pending = 1;
    pending.pending_chunk_index = result.chunk_index;
    pending.pending_start_frame = result.start_frame;
    pending.pending_frame_count = result.frame_count;
    pending.previous_publication_result_sha256 =
        result.previous_publication_result_sha256;
    pending.previous_ack_result_sha256 =
        acknowledgement.previous_ack_result_sha256;
    pending.pending_publication_result_sha256 =
        result.result_sha256;
    pending.pending_output_sha256 = result.output_sha256;
    pending.state_sha256 = [_]u8{0} ** 32;
    pending.state_sha256 = audio.stateRootV1(pending);
    audio.validateStateV1(pending) catch
        return Error.InvalidBinding;

    const observation = audio.makePlaybackObservationV1(
        pending,
        acknowledgement.sink_implementation_sha256,
        acknowledgement.sink_instance_sha256,
    ) catch return Error.InvalidBinding;
    const plan = audio.makePlaybackAckPlanV1(
        pending,
        result,
        observation,
    ) catch return Error.InvalidBinding;
    var expected_state = pending;
    const expected_acknowledgement =
        audio.acknowledgePlaybackV1(
            &expected_state,
            result,
            observation,
            plan,
        ) catch return Error.InvalidBinding;
    if (!std.meta.eql(
        expected_acknowledgement,
        acknowledgement,
    ) or !std.meta.eql(expected_state, state))
        return Error.InvalidBinding;
}

fn validateVideoCompletionProjectionV1(
    state: video.GeneratedVideoStateV1,
    result: video.GeneratedVideoResultV1,
    acknowledgement: video.DisplayAckResultV1,
) !void {
    if (state.width != result.width or
        state.height != result.height or
        state.channels != result.channels or
        state.bytes_per_channel != result.bytes_per_channel or
        state.next_segment_index != result.visible_segments_after or
        state.next_frame_ordinal != result.visible_frames_after or
        state.next_start_tick != result.visible_end_tick_after)
        return Error.InvalidBinding;

    var before = state;
    before.generation = std.math.sub(
        u64,
        result.generation,
        1,
    ) catch return Error.InvalidBinding;
    before.next_segment_index = result.segment_index;
    before.next_frame_ordinal = result.first_frame_ordinal;
    before.next_start_tick = result.start_tick;
    before.visible_segments =
        result.visible_segments_before;
    before.visible_frames = result.visible_frames_before;
    before.visible_end_tick =
        result.visible_end_tick_before;
    before.displayed_segments =
        result.visible_segments_before;
    before.displayed_frames =
        result.visible_frames_before;
    before.displayed_end_tick =
        result.visible_end_tick_before;
    before.display_sequence = result.segment_index;
    before.pending = 0;
    before.pending_segment_index = 0;
    before.pending_first_frame = 0;
    before.pending_frame_count = 0;
    before.pending_start_tick = 0;
    before.pending_end_tick = 0;
    before.previous_publication_result_sha256 =
        result.previous_publication_result_sha256;
    before.previous_ack_result_sha256 =
        acknowledgement.previous_ack_result_sha256;
    before.pending_publication_result_sha256 =
        [_]u8{0} ** 32;
    before.pending_output_sha256 = [_]u8{0} ** 32;
    before.state_sha256 = [_]u8{0} ** 32;
    before.state_sha256 = video.stateRootV1(before);
    video.validateStateV1(before) catch
        return Error.InvalidBinding;
    if (!digestEqual(
        before.state_sha256,
        result.state_before_sha256,
    )) return Error.InvalidBinding;

    var pending = state;
    pending.generation = result.generation;
    pending.displayed_segments =
        result.visible_segments_before;
    pending.displayed_frames = result.visible_frames_before;
    pending.displayed_end_tick =
        result.visible_end_tick_before;
    pending.display_sequence = result.segment_index;
    pending.pending = 1;
    pending.pending_segment_index = result.segment_index;
    pending.pending_first_frame =
        result.first_frame_ordinal;
    pending.pending_frame_count = result.frame_count;
    pending.pending_start_tick = result.start_tick;
    pending.pending_end_tick = result.end_tick;
    pending.previous_publication_result_sha256 =
        result.result_sha256;
    pending.previous_ack_result_sha256 =
        acknowledgement.previous_ack_result_sha256;
    pending.pending_publication_result_sha256 =
        result.result_sha256;
    pending.pending_output_sha256 = result.output_sha256;
    pending.state_sha256 = [_]u8{0} ** 32;
    pending.state_sha256 = video.stateRootV1(pending);
    video.validateStateV1(pending) catch
        return Error.InvalidBinding;

    const observation = video.makeDisplayObservationV1(
        pending,
        acknowledgement.sink_implementation_sha256,
        acknowledgement.sink_instance_sha256,
    ) catch return Error.InvalidBinding;
    const plan = video.makeDisplayAckPlanV1(
        pending,
        result,
        observation,
    ) catch return Error.InvalidBinding;
    var expected_state = pending;
    const expected_acknowledgement =
        video.acknowledgeDisplayV1(
            &expected_state,
            result,
            observation,
            plan,
        ) catch return Error.InvalidBinding;
    if (!std.meta.eql(
        expected_acknowledgement,
        acknowledgement,
    ) or !std.meta.eql(expected_state, state))
        return Error.InvalidBinding;
}

fn memberFromProjectionV1(
    projection: GeneratedMediaProducerProjectionV1,
    source_generation: u64,
) GeneratedMediaMemberV1 {
    return .{
        .request_epoch = projection.request_epoch,
        .source_generation = source_generation,
        .modality = projection.modality,
        .ordinal = projection.ordinal,
        .unit_start = projection.unit_start,
        .unit_count = projection.unit_count,
        .unit_end = projection.unit_end,
        .timeline_start = projection.timeline_start,
        .timeline_end = projection.timeline_end,
        .byte_count = projection.byte_count,
        .completion_required = projection.completion_required,
        .completed = projection.completed,
        .artifact_sha256 = projection.artifact_sha256,
        .provenance_sha256 = projection.provenance_sha256,
        .result_sha256 = projection.result_sha256,
        .output_sha256 = projection.output_sha256,
        .media_object_sha256 = projection.media_object_sha256,
        .state_after_sha256 = projection.state_after_sha256,
        .completion_sha256 = projection.completion_sha256,
        .tenant_scope_sha256 = projection.tenant_scope_sha256,
        .metadata_policy_sha256 = projection.metadata_policy_sha256,
        .challenge_sha256 = projection.challenge_sha256,
        .member_sha256 = [_]u8{0} ** 32,
    };
}

pub fn validateMemberV1(member: GeneratedMediaMemberV1) Error!void {
    const unit_end = checkedAdd(
        member.unit_start,
        member.unit_count,
    ) catch return Error.InvalidMember;
    if (member.request_epoch == 0 or member.source_generation == 0 or
        member.unit_count == 0 or member.unit_end != unit_end or
        member.timeline_end <= member.timeline_start or
        member.byte_count == 0 or member.completed != 1 or
        isZero(member.artifact_sha256) or
        isZero(member.provenance_sha256) or
        isZero(member.result_sha256) or
        isZero(member.output_sha256) or
        isZero(member.media_object_sha256) or
        isZero(member.state_after_sha256) or
        isZero(member.tenant_scope_sha256) or
        isZero(member.metadata_policy_sha256) or
        isZero(member.challenge_sha256))
        return Error.InvalidMember;
    switch (member.modality) {
        image_modality => {
            const expected_start = std.math.sub(
                u64,
                member.ordinal,
                1,
            ) catch return Error.InvalidMember;
            if (member.ordinal == 0 or
                member.source_generation != member.ordinal or
                member.unit_start != expected_start or
                member.unit_count != 1 or
                member.unit_end != member.ordinal or
                member.timeline_start != member.unit_start or
                member.timeline_end != member.unit_end or
                member.completion_required != 0 or
                !isZero(member.completion_sha256))
                return Error.InvalidMember;
        },
        audio_modality, video_modality => {
            const expected_generation = checkedAdd(
                checkedMul(
                    member.ordinal,
                    2,
                ) catch return Error.InvalidMember,
                1,
            ) catch return Error.InvalidMember;
            if (member.source_generation != expected_generation or
                member.completion_required != 1 or
                isZero(member.completion_sha256))
                return Error.InvalidMember;
            if (member.modality == audio_modality and
                (member.timeline_start != member.unit_start or
                    member.timeline_end != member.unit_end))
                return Error.InvalidMember;
        },
        else => return Error.InvalidMember,
    }
    if (!digestEqual(member.member_sha256, memberRootV1(member)))
        return Error.InvalidMemberRoot;
}

pub fn makeCheckpointV1(
    previous: ?GeneratedMediaCheckpointV1,
    image_member: GeneratedMediaMemberV1,
    audio_member: GeneratedMediaMemberV1,
    video_member: GeneratedMediaMemberV1,
) Error!GeneratedMediaCheckpointV1 {
    try validateMemberV1(image_member);
    try validateMemberV1(audio_member);
    try validateMemberV1(video_member);
    if (image_member.modality != image_modality or
        audio_member.modality != audio_modality or
        video_member.modality != video_modality or
        image_member.request_epoch != audio_member.request_epoch or
        image_member.request_epoch != video_member.request_epoch or
        !digestEqual(
            image_member.tenant_scope_sha256,
            audio_member.tenant_scope_sha256,
        ) or
        !digestEqual(
            image_member.tenant_scope_sha256,
            video_member.tenant_scope_sha256,
        ) or
        !digestEqual(
            image_member.metadata_policy_sha256,
            audio_member.metadata_policy_sha256,
        ) or
        !digestEqual(
            image_member.metadata_policy_sha256,
            video_member.metadata_policy_sha256,
        ) or
        !digestEqual(
            image_member.challenge_sha256,
            audio_member.challenge_sha256,
        ) or
        !digestEqual(
            image_member.challenge_sha256,
            video_member.challenge_sha256,
        ))
        return Error.InvalidBinding;
    const generation = image_member.ordinal;
    const expected_audio_generation = checkedAdd(
        audio_member.ordinal,
        1,
    ) catch return Error.InvalidBinding;
    const expected_video_generation = checkedAdd(
        video_member.ordinal,
        1,
    ) catch return Error.InvalidBinding;
    if (expected_audio_generation != generation or
        expected_video_generation != generation)
        return Error.InvalidBinding;
    var previous_root = [_]u8{0} ** 32;
    if (previous) |prior| {
        try validateCheckpointV1(prior);
        const expected_generation = checkedAdd(
            prior.generation,
            1,
        ) catch return Error.InvalidBinding;
        if (generation != expected_generation or
            image_member.unit_start != prior.image_unit_end or
            audio_member.unit_start != prior.audio_unit_end or
            video_member.unit_start != prior.video_unit_end or
            video_member.timeline_start != prior.video_timeline_end or
            image_member.request_epoch != prior.request_epoch or
            !digestEqual(
                image_member.tenant_scope_sha256,
                prior.tenant_scope_sha256,
            ) or
            !digestEqual(
                image_member.metadata_policy_sha256,
                prior.metadata_policy_sha256,
            ) or
            !digestEqual(
                image_member.challenge_sha256,
                prior.challenge_sha256,
            ) or
            digestEqual(
                image_member.member_sha256,
                prior.image_member_sha256,
            ) or
            digestEqual(
                audio_member.member_sha256,
                prior.audio_member_sha256,
            ) or
            digestEqual(
                video_member.member_sha256,
                prior.video_member_sha256,
            ) or
            digestEqual(
                image_member.result_sha256,
                prior.image_result_sha256,
            ) or
            digestEqual(
                audio_member.result_sha256,
                prior.audio_result_sha256,
            ) or
            digestEqual(
                video_member.result_sha256,
                prior.video_result_sha256,
            ))
            return Error.InvalidBinding;
        previous_root = prior.checkpoint_sha256;
    } else if (generation != 1 or
        image_member.unit_start != 0 or
        audio_member.unit_start != 0 or
        video_member.unit_start != 0 or
        video_member.timeline_start != 0)
    {
        return Error.InvalidBinding;
    }
    const total_bytes = try checkedAdd(
        try checkedAdd(
            image_member.byte_count,
            audio_member.byte_count,
        ),
        video_member.byte_count,
    );
    const total_units = try checkedAdd(
        try checkedAdd(
            image_member.unit_count,
            audio_member.unit_count,
        ),
        video_member.unit_count,
    );
    var checkpoint: GeneratedMediaCheckpointV1 = .{
        .request_epoch = image_member.request_epoch,
        .generation = generation,
        .publication_sequence = generation,
        .member_count = required_member_count,
        .total_bytes = total_bytes,
        .total_units = total_units,
        .image_ordinal = image_member.ordinal,
        .audio_ordinal = audio_member.ordinal,
        .video_ordinal = video_member.ordinal,
        .image_unit_end = image_member.unit_end,
        .audio_unit_end = audio_member.unit_end,
        .video_unit_end = video_member.unit_end,
        .video_timeline_end = video_member.timeline_end,
        .image_bytes = image_member.byte_count,
        .audio_bytes = audio_member.byte_count,
        .video_bytes = video_member.byte_count,
        .image_units = image_member.unit_count,
        .audio_units = audio_member.unit_count,
        .video_units = video_member.unit_count,
        .tenant_scope_sha256 = image_member.tenant_scope_sha256,
        .metadata_policy_sha256 = image_member.metadata_policy_sha256,
        .challenge_sha256 = image_member.challenge_sha256,
        .image_member_sha256 = image_member.member_sha256,
        .audio_member_sha256 = audio_member.member_sha256,
        .video_member_sha256 = video_member.member_sha256,
        .image_result_sha256 = image_member.result_sha256,
        .audio_result_sha256 = audio_member.result_sha256,
        .video_result_sha256 = video_member.result_sha256,
        .image_output_sha256 = image_member.output_sha256,
        .audio_output_sha256 = audio_member.output_sha256,
        .video_output_sha256 = video_member.output_sha256,
        .image_state_sha256 = image_member.state_after_sha256,
        .audio_state_sha256 = audio_member.state_after_sha256,
        .video_state_sha256 = video_member.state_after_sha256,
        .audio_completion_sha256 = audio_member.completion_sha256,
        .video_completion_sha256 = video_member.completion_sha256,
        .previous_checkpoint_sha256 = previous_root,
        .checkpoint_sha256 = [_]u8{0} ** 32,
    };
    checkpoint.checkpoint_sha256 = checkpointRootV1(checkpoint);
    try validateCheckpointV1(checkpoint);
    return checkpoint;
}

pub fn validateCheckpointV1(
    checkpoint: GeneratedMediaCheckpointV1,
) Error!void {
    const expected_image_ordinal = checkpoint.generation;
    const expected_stream_ordinal = std.math.sub(
        u64,
        checkpoint.generation,
        1,
    ) catch return Error.InvalidCheckpoint;
    const total_bytes = checkedAdd(
        checkedAdd(
            checkpoint.image_bytes,
            checkpoint.audio_bytes,
        ) catch return Error.InvalidCheckpoint,
        checkpoint.video_bytes,
    ) catch return Error.InvalidCheckpoint;
    const total_units = checkedAdd(
        checkedAdd(
            checkpoint.image_units,
            checkpoint.audio_units,
        ) catch return Error.InvalidCheckpoint,
        checkpoint.video_units,
    ) catch return Error.InvalidCheckpoint;
    if (checkpoint.request_epoch == 0 or checkpoint.generation == 0 or
        checkpoint.publication_sequence != checkpoint.generation or
        checkpoint.member_count != required_member_count or
        checkpoint.total_bytes == 0 or
        checkpoint.total_bytes != total_bytes or
        checkpoint.total_units == 0 or
        checkpoint.total_units != total_units or
        checkpoint.image_ordinal != expected_image_ordinal or
        checkpoint.audio_ordinal != expected_stream_ordinal or
        checkpoint.video_ordinal != expected_stream_ordinal or
        checkpoint.image_unit_end != checkpoint.image_ordinal or
        checkpoint.image_bytes == 0 or checkpoint.audio_bytes == 0 or
        checkpoint.video_bytes == 0 or checkpoint.image_units != 1 or
        checkpoint.audio_units == 0 or checkpoint.video_units == 0 or
        checkpoint.audio_unit_end == 0 or
        checkpoint.video_unit_end == 0 or
        checkpoint.video_timeline_end == 0 or
        isZero(checkpoint.tenant_scope_sha256) or
        isZero(checkpoint.metadata_policy_sha256) or
        isZero(checkpoint.challenge_sha256) or
        isZero(checkpoint.image_member_sha256) or
        isZero(checkpoint.audio_member_sha256) or
        isZero(checkpoint.video_member_sha256) or
        isZero(checkpoint.image_result_sha256) or
        isZero(checkpoint.audio_result_sha256) or
        isZero(checkpoint.video_result_sha256) or
        isZero(checkpoint.image_output_sha256) or
        isZero(checkpoint.audio_output_sha256) or
        isZero(checkpoint.video_output_sha256) or
        isZero(checkpoint.image_state_sha256) or
        isZero(checkpoint.audio_state_sha256) or
        isZero(checkpoint.video_state_sha256) or
        isZero(checkpoint.audio_completion_sha256) or
        isZero(checkpoint.video_completion_sha256))
        return Error.InvalidCheckpoint;
    if ((checkpoint.generation == 1) !=
        isZero(checkpoint.previous_checkpoint_sha256))
        return Error.InvalidCheckpoint;
    if (!digestEqual(
        checkpoint.checkpoint_sha256,
        checkpointRootV1(checkpoint),
    ))
        return Error.InvalidCheckpointRoot;
}

pub fn validateCheckpointBindingsV1(
    previous: ?GeneratedMediaCheckpointV1,
    image_member: GeneratedMediaMemberV1,
    audio_member: GeneratedMediaMemberV1,
    video_member: GeneratedMediaMemberV1,
    checkpoint: GeneratedMediaCheckpointV1,
) Error!void {
    const expected = try makeCheckpointV1(
        previous,
        image_member,
        audio_member,
        video_member,
    );
    if (!std.meta.eql(expected, checkpoint))
        return Error.InvalidBinding;
}

pub fn makeSelectorV1(
    previous: ?GeneratedMediaSelectorV1,
    checkpoint: GeneratedMediaCheckpointV1,
) Error!GeneratedMediaSelectorV1 {
    try validateCheckpointV1(checkpoint);
    var previous_selector_root = [_]u8{0} ** 32;
    if (previous) |prior| {
        try validateSelectorV1(prior);
        const expected_generation = checkedAdd(
            prior.generation,
            1,
        ) catch return Error.InvalidBinding;
        if (checkpoint.generation != expected_generation or
            checkpoint.request_epoch != prior.request_epoch or
            !digestEqual(
                checkpoint.previous_checkpoint_sha256,
                prior.checkpoint_sha256,
            ) or
            !digestEqual(
                checkpoint.challenge_sha256,
                prior.challenge_sha256,
            ))
            return Error.InvalidBinding;
        previous_selector_root = prior.selector_sha256;
    } else if (checkpoint.generation != 1) {
        return Error.InvalidBinding;
    }
    var selector: GeneratedMediaSelectorV1 = .{
        .request_epoch = checkpoint.request_epoch,
        .generation = checkpoint.generation,
        .publication_sequence = checkpoint.publication_sequence,
        .checkpoint_wire_bytes = checkpoint_bytes,
        .member_wire_bytes = member_bytes,
        .member_count = required_member_count,
        .checkpoint_sha256 = checkpoint.checkpoint_sha256,
        .image_member_sha256 = checkpoint.image_member_sha256,
        .audio_member_sha256 = checkpoint.audio_member_sha256,
        .video_member_sha256 = checkpoint.video_member_sha256,
        .previous_checkpoint_sha256 = checkpoint.previous_checkpoint_sha256,
        .previous_selector_sha256 = previous_selector_root,
        .challenge_sha256 = checkpoint.challenge_sha256,
        .selector_sha256 = [_]u8{0} ** 32,
    };
    selector.selector_sha256 = selectorRootV1(selector);
    try validateSelectorV1(selector);
    return selector;
}

pub fn validateSelectorV1(selector: GeneratedMediaSelectorV1) Error!void {
    if (selector.request_epoch == 0 or selector.generation == 0 or
        selector.publication_sequence != selector.generation or
        selector.checkpoint_wire_bytes != checkpoint_bytes or
        selector.member_wire_bytes != member_bytes or
        selector.member_count != required_member_count or
        isZero(selector.checkpoint_sha256) or
        isZero(selector.image_member_sha256) or
        isZero(selector.audio_member_sha256) or
        isZero(selector.video_member_sha256) or
        isZero(selector.challenge_sha256))
        return Error.InvalidSelector;
    if ((selector.generation == 1) !=
        isZero(selector.previous_checkpoint_sha256) or
        (selector.generation == 1) !=
            isZero(selector.previous_selector_sha256))
        return Error.InvalidSelector;
    if (!digestEqual(
        selector.selector_sha256,
        selectorRootV1(selector),
    ))
        return Error.InvalidSelectorRoot;
}

pub fn validateSelectorBindingsV1(
    previous: ?GeneratedMediaSelectorV1,
    checkpoint: GeneratedMediaCheckpointV1,
    selector: GeneratedMediaSelectorV1,
) Error!void {
    const expected = try makeSelectorV1(previous, checkpoint);
    if (!std.meta.eql(expected, selector))
        return Error.InvalidBinding;
}

pub fn encodeMemberV1(
    value: GeneratedMediaMemberV1,
    output: []u8,
) Error![]const u8 {
    try validateMemberV1(value);
    return encodeRecordV1(
        GeneratedMediaMemberV1,
        member_wire,
        value,
        output,
    );
}

pub fn decodeMemberV1(input: []const u8) Error!GeneratedMediaMemberV1 {
    const value = try decodeRecordV1(
        GeneratedMediaMemberV1,
        member_wire,
        input,
    );
    try validateMemberV1(value);
    return value;
}

pub fn encodeCheckpointV1(
    value: GeneratedMediaCheckpointV1,
    output: []u8,
) Error![]const u8 {
    try validateCheckpointV1(value);
    return encodeRecordV1(
        GeneratedMediaCheckpointV1,
        checkpoint_wire,
        value,
        output,
    );
}

pub fn decodeCheckpointV1(
    input: []const u8,
) Error!GeneratedMediaCheckpointV1 {
    const value = try decodeRecordV1(
        GeneratedMediaCheckpointV1,
        checkpoint_wire,
        input,
    );
    try validateCheckpointV1(value);
    return value;
}

pub fn encodeSelectorV1(
    value: GeneratedMediaSelectorV1,
    output: []u8,
) Error![]const u8 {
    try validateSelectorV1(value);
    return encodeRecordV1(
        GeneratedMediaSelectorV1,
        selector_wire,
        value,
        output,
    );
}

pub fn decodeSelectorV1(
    input: []const u8,
) Error!GeneratedMediaSelectorV1 {
    const value = try decodeRecordV1(
        GeneratedMediaSelectorV1,
        selector_wire,
        input,
    );
    try validateSelectorV1(value);
    return value;
}

pub fn memberRootV1(value: GeneratedMediaMemberV1) Digest {
    return recordRootV1(GeneratedMediaMemberV1, member_wire, value);
}

pub fn checkpointRootV1(value: GeneratedMediaCheckpointV1) Digest {
    return recordRootV1(
        GeneratedMediaCheckpointV1,
        checkpoint_wire,
        value,
    );
}

pub fn selectorRootV1(value: GeneratedMediaSelectorV1) Digest {
    return recordRootV1(
        GeneratedMediaSelectorV1,
        selector_wire,
        value,
    );
}

pub fn referenceFixtureV1() Error!ReferenceFixtureV1 {
    const image1 = try referenceMemberV1(image_modality, 1);
    const audio1 = try referenceMemberV1(audio_modality, 1);
    const video1 = try referenceMemberV1(video_modality, 1);
    const checkpoint1 = try makeCheckpointV1(
        null,
        image1,
        audio1,
        video1,
    );
    const selector1 = try makeSelectorV1(null, checkpoint1);
    const image2 = try referenceMemberV1(image_modality, 2);
    const audio2 = try referenceMemberV1(audio_modality, 2);
    const video2 = try referenceMemberV1(video_modality, 2);
    const checkpoint2 = try makeCheckpointV1(
        checkpoint1,
        image2,
        audio2,
        video2,
    );
    const selector2 = try makeSelectorV1(selector1, checkpoint2);
    return .{
        .image1 = image1,
        .audio1 = audio1,
        .video1 = video1,
        .checkpoint1 = checkpoint1,
        .selector1 = selector1,
        .image2 = image2,
        .audio2 = audio2,
        .video2 = video2,
        .checkpoint2 = checkpoint2,
        .selector2 = selector2,
    };
}

fn referenceMemberV1(
    modality: u64,
    generation: u64,
) Error!GeneratedMediaMemberV1 {
    const ordinal = if (modality == image_modality)
        generation
    else
        std.math.sub(u64, generation, 1) catch
            return Error.ArithmeticOverflow;
    const unit_start = switch (modality) {
        image_modality => ordinal - 1,
        audio_modality, video_modality => try checkedMul(ordinal, 2),
        else => return Error.InvalidMember,
    };
    const unit_count: u64 = if (modality == image_modality) 1 else 2;
    const unit_end = try checkedAdd(unit_start, unit_count);
    const timeline_start = if (modality == video_modality)
        try checkedMul(ordinal, 5)
    else
        unit_start;
    const timeline_end = if (modality == video_modality)
        try checkedAdd(timeline_start, 5)
    else
        unit_end;
    const byte_count: u64 = switch (modality) {
        image_modality, audio_modality => 4,
        video_modality => 8,
        else => return Error.InvalidMember,
    };
    const source_generation = if (modality == image_modality)
        generation
    else
        try checkedAdd(try checkedMul(ordinal, 2), 1);
    var member: GeneratedMediaMemberV1 = .{
        .request_epoch = 70_001,
        .source_generation = source_generation,
        .modality = modality,
        .ordinal = ordinal,
        .unit_start = unit_start,
        .unit_count = unit_count,
        .unit_end = unit_end,
        .timeline_start = timeline_start,
        .timeline_end = timeline_end,
        .byte_count = byte_count,
        .completion_required = if (modality == image_modality) 0 else 1,
        .completed = 1,
        .artifact_sha256 = referenceDigestV1(1, modality, generation),
        .provenance_sha256 = referenceDigestV1(2, modality, generation),
        .result_sha256 = referenceDigestV1(3, modality, generation),
        .output_sha256 = referenceDigestV1(4, modality, generation),
        .media_object_sha256 = referenceDigestV1(5, modality, generation),
        .state_after_sha256 = referenceDigestV1(6, modality, generation),
        .completion_sha256 = if (modality == image_modality)
            [_]u8{0} ** 32
        else
            referenceDigestV1(7, modality, generation),
        .tenant_scope_sha256 = referenceDigestV1(8, 0, 0),
        .metadata_policy_sha256 = referenceDigestV1(9, 0, 0),
        .challenge_sha256 = referenceDigestV1(10, 0, 0),
        .member_sha256 = [_]u8{0} ** 32,
    };
    member.member_sha256 = memberRootV1(member);
    try validateMemberV1(member);
    return member;
}

fn referenceDigestV1(
    kind: u64,
    modality: u64,
    generation: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(reference_domain);
    hashU64(&hash, kind);
    hashU64(&hash, modality);
    hashU64(&hash, generation);
    return hash.finalResult();
}

fn encodeRecordV1(
    comptime T: type,
    comptime config: WireConfig,
    value: T,
    output: []u8,
) Error![]const u8 {
    if (output.len < config.total_bytes)
        return Error.BufferTooSmall;
    writeRecordBodyV1(T, config, value, output[0..config.body_bytes]);
    const fields = std.meta.fields(T);
    const root_field = fields[fields.len - 1];
    if (root_field.type != Digest)
        @compileError("wire root must be the final digest field");
    @memcpy(
        output[config.body_bytes..config.total_bytes],
        &@field(value, root_field.name),
    );
    return output[0..config.total_bytes];
}

fn decodeRecordV1(
    comptime T: type,
    comptime config: WireConfig,
    input: []const u8,
) Error!T {
    if (input.len != config.total_bytes or
        !std.mem.eql(u8, input[0..8], &config.magic) or
        readU64(input, 8) != config.abi or
        readU64(input, 16) != config.total_bytes or
        readU64(input, 24) != 0)
        return Error.InvalidWire;
    const expected_root = domainRoot(
        config.domain,
        input[0..config.body_bytes],
    );
    if (!std.mem.eql(
        u8,
        input[config.body_bytes..config.total_bytes],
        &expected_root,
    ))
        return Error.InvalidWire;
    var value: T = undefined;
    var offset: usize = 32;
    const fields = std.meta.fields(T);
    inline for (fields[0 .. fields.len - 1]) |field| {
        if (field.type == u64) {
            if (offset + 8 > config.body_bytes)
                return Error.InvalidWire;
            @field(value, field.name) = readU64(input, offset);
            offset += 8;
        } else if (field.type == Digest) {
            if (offset + 32 > config.body_bytes)
                return Error.InvalidWire;
            @memcpy(
                &@field(value, field.name),
                input[offset .. offset + 32],
            );
            offset += 32;
        } else {
            @compileError("unsupported canonical wire field type");
        }
    }
    for (input[offset..config.body_bytes]) |byte| {
        if (byte != 0)
            return Error.InvalidWire;
    }
    const root_field = fields[fields.len - 1];
    if (root_field.type != Digest)
        @compileError("wire root must be the final digest field");
    @memcpy(
        &@field(value, root_field.name),
        input[config.body_bytes..config.total_bytes],
    );
    return value;
}

fn recordRootV1(
    comptime T: type,
    comptime config: WireConfig,
    value: T,
) Digest {
    var body: [config.body_bytes]u8 = undefined;
    writeRecordBodyV1(T, config, value, &body);
    return domainRoot(config.domain, &body);
}

fn writeRecordBodyV1(
    comptime T: type,
    comptime config: WireConfig,
    value: T,
    output: []u8,
) void {
    std.debug.assert(output.len == config.body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &config.magic);
    writeU64(output, 8, config.abi);
    writeU64(output, 16, config.total_bytes);
    writeU64(output, 24, 0);
    var offset: usize = 32;
    const fields = std.meta.fields(T);
    inline for (fields[0 .. fields.len - 1]) |field| {
        if (field.type == u64) {
            writeU64(output, offset, @field(value, field.name));
            offset += 8;
        } else if (field.type == Digest) {
            @memcpy(
                output[offset .. offset + 32],
                &@field(value, field.name),
            );
            offset += 32;
        } else {
            @compileError("unsupported canonical wire field type");
        }
    }
    std.debug.assert(offset <= config.body_bytes);
}

fn domainRoot(domain: []const u8, body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(body);
    return hash.finalResult();
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn checkedMul(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(digest: Digest) bool {
    return digestEqual(digest, [_]u8{0} ** 32);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var storage: [8]u8 = undefined;
    std.mem.writeInt(u64, &storage, value, .little);
    hash.update(&storage);
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

test "generated media checkpoint wires are canonical and mutation complete" {
    const fixture = try referenceFixtureV1();
    const Case = struct {
        bytes: usize,
        value: union(enum) {
            member: GeneratedMediaMemberV1,
            checkpoint: GeneratedMediaCheckpointV1,
            selector: GeneratedMediaSelectorV1,
        },
    };
    const cases = [_]Case{
        .{ .bytes = member_bytes, .value = .{ .member = fixture.image1 } },
        .{ .bytes = member_bytes, .value = .{ .member = fixture.audio1 } },
        .{ .bytes = member_bytes, .value = .{ .member = fixture.video1 } },
        .{
            .bytes = checkpoint_bytes,
            .value = .{ .checkpoint = fixture.checkpoint1 },
        },
        .{
            .bytes = selector_bytes,
            .value = .{ .selector = fixture.selector1 },
        },
    };
    var storage: [checkpoint_bytes]u8 = undefined;
    for (cases) |case| {
        const encoded = switch (case.value) {
            .member => |value| try encodeMemberV1(value, &storage),
            .checkpoint => |value| try encodeCheckpointV1(value, &storage),
            .selector => |value| try encodeSelectorV1(value, &storage),
        };
        try std.testing.expectEqual(case.bytes, encoded.len);
        for (0..encoded.len) |index| {
            var mutated: [checkpoint_bytes]u8 = undefined;
            @memcpy(mutated[0..encoded.len], encoded);
            mutated[index] ^= 1;
            switch (case.value) {
                .member => try std.testing.expectError(
                    Error.InvalidWire,
                    decodeMemberV1(mutated[0..encoded.len]),
                ),
                .checkpoint => try std.testing.expectError(
                    Error.InvalidWire,
                    decodeCheckpointV1(mutated[0..encoded.len]),
                ),
                .selector => try std.testing.expectError(
                    Error.InvalidWire,
                    decodeSelectorV1(mutated[0..encoded.len]),
                ),
            }
        }
    }
}

test "generated media checkpoint rejects mixed and replayed generations" {
    const fixture = try referenceFixtureV1();
    try validateCheckpointBindingsV1(
        null,
        fixture.image1,
        fixture.audio1,
        fixture.video1,
        fixture.checkpoint1,
    );
    try validateCheckpointBindingsV1(
        fixture.checkpoint1,
        fixture.image2,
        fixture.audio2,
        fixture.video2,
        fixture.checkpoint2,
    );
    try validateSelectorBindingsV1(
        null,
        fixture.checkpoint1,
        fixture.selector1,
    );
    try validateSelectorBindingsV1(
        fixture.selector1,
        fixture.checkpoint2,
        fixture.selector2,
    );
    try std.testing.expectError(
        Error.InvalidBinding,
        makeCheckpointV1(
            fixture.checkpoint1,
            fixture.image2,
            fixture.audio1,
            fixture.video2,
        ),
    );
    try std.testing.expectError(
        Error.InvalidBinding,
        makeCheckpointV1(
            fixture.checkpoint1,
            fixture.image2,
            fixture.audio2,
            fixture.video1,
        ),
    );
    var foreign = fixture.image2;
    foreign.tenant_scope_sha256 =
        model.sha256("foreign generated media tenant");
    foreign.member_sha256 = memberRootV1(foreign);
    try validateMemberV1(foreign);
    try std.testing.expectError(
        Error.InvalidBinding,
        makeCheckpointV1(
            fixture.checkpoint1,
            foreign,
            fixture.audio2,
            fixture.video2,
        ),
    );
    var replay = fixture.selector2;
    replay.previous_selector_sha256 =
        model.sha256("foreign generated media selector");
    replay.selector_sha256 = selectorRootV1(replay);
    try validateSelectorV1(replay);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateSelectorBindingsV1(
            fixture.selector1,
            fixture.checkpoint2,
            replay,
        ),
    );
}

const ImageInputs = struct {
    plan: image.GeneratedImagePlanV1,
    provenance: image.GeneratedImageProvenanceV1,
    result: image.GeneratedImageResultV1,
};

const AudioInputs = struct {
    state: audio.GeneratedAudioStateV1,
    plan: audio.GeneratedAudioPlanV1,
    provenance: audio.GeneratedAudioProvenanceV1,
    result: audio.GeneratedAudioResultV1,
    acknowledgement: audio.PlaybackAckResultV1,
};

const VideoInputs = struct {
    state: video.GeneratedVideoStateV1,
    manifest: video.GeneratedVideoManifestV1,
    provenance: video.GeneratedVideoProvenanceV1,
    result: video.GeneratedVideoResultV1,
    acknowledgement: video.DisplayAckResultV1,
};

test "typed image audio and video completions compose only when exact" {
    const scope = model.sha256("generated media typed tenant");
    const policy = model.sha256("generated media typed policy");
    const challenge = model.sha256("generated media typed challenge");
    const image_inputs = try makeTestImageInputsV1(
        scope,
        policy,
        challenge,
    );
    const audio_inputs = try makeTestAudioInputsV1(
        scope,
        policy,
        challenge,
    );
    const video_inputs = try makeTestVideoInputsV1(
        scope,
        policy,
        challenge,
    );
    const image_member = try imageMemberV1(
        image_inputs.plan,
        image_inputs.provenance,
        image_inputs.result,
    );
    var foreign_image_provenance = image_inputs.provenance;
    foreign_image_provenance.source_step += 1;
    foreign_image_provenance.provenance_sha256 =
        image.generatedImageProvenanceRootV1(
            foreign_image_provenance,
        );
    try image.validateGeneratedImageProvenanceV1(
        foreign_image_provenance,
    );
    var foreign_image_result = image_inputs.result;
    foreign_image_result.provenance_sha256 =
        foreign_image_provenance.provenance_sha256;
    foreign_image_result.result_sha256 =
        image.generatedImageResultRootV1(foreign_image_result);
    try image.validateGeneratedImageResultV1(foreign_image_result);
    try std.testing.expectError(
        Error.InvalidBinding,
        imageMemberV1(
            image_inputs.plan,
            foreign_image_provenance,
            foreign_image_result,
        ),
    );
    const audio_member = try audioMemberV1(
        audio_inputs.state,
        audio_inputs.plan,
        audio_inputs.provenance,
        audio_inputs.result,
        audio_inputs.acknowledgement,
    );
    try std.testing.expect(isZero(
        audio_inputs.acknowledgement.previous_publication_result_sha256,
    ));
    try std.testing.expect(isZero(
        audio_inputs.acknowledgement.previous_ack_result_sha256,
    ));
    const successor_audio_inputs =
        try makeTestAudioSuccessorInputsV1(audio_inputs);
    const successor_audio_member = try audioMemberV1(
        successor_audio_inputs.state,
        successor_audio_inputs.plan,
        successor_audio_inputs.provenance,
        successor_audio_inputs.result,
        successor_audio_inputs.acknowledgement,
    );
    try std.testing.expectEqual(@as(u64, 1), successor_audio_member.ordinal);
    try std.testing.expectEqualSlices(
        u8,
        &audio_inputs.result.result_sha256,
        &successor_audio_inputs
            .acknowledgement
            .previous_publication_result_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &audio_inputs.acknowledgement.result_sha256,
        &successor_audio_inputs
            .acknowledgement
            .previous_ack_result_sha256,
    );
    const video_member = try videoMemberV1(
        video_inputs.state,
        video_inputs.manifest,
        video_inputs.provenance,
        video_inputs.result,
        video_inputs.acknowledgement,
    );
    const checkpoint = try makeCheckpointV1(
        null,
        image_member,
        audio_member,
        video_member,
    );
    try std.testing.expectEqual(@as(u64, 1), checkpoint.generation);
    try std.testing.expectEqual(@as(u64, 16), checkpoint.total_bytes);
    try std.testing.expectEqual(@as(u64, 5), checkpoint.total_units);

    var foreign_ack = audio_inputs.acknowledgement;
    foreign_ack.output_sha256 =
        model.sha256("foreign generated media audio output");
    foreign_ack.result_sha256 = audio.ackResultRootV1(foreign_ack);
    try audio.validatePlaybackAckResultV1(foreign_ack);
    try std.testing.expectError(
        Error.InvalidBinding,
        audioMemberV1(
            audio_inputs.state,
            audio_inputs.plan,
            audio_inputs.provenance,
            audio_inputs.result,
            foreign_ack,
        ),
    );
    var old_semantics_ack = audio_inputs.acknowledgement;
    old_semantics_ack.previous_publication_result_sha256 =
        audio_inputs.result.result_sha256;
    old_semantics_ack.result_sha256 =
        audio.ackResultRootV1(old_semantics_ack);
    try audio.validatePlaybackAckResultV1(old_semantics_ack);
    try std.testing.expectError(
        Error.InvalidBinding,
        audioMemberV1(
            audio_inputs.state,
            audio_inputs.plan,
            audio_inputs.provenance,
            audio_inputs.result,
            old_semantics_ack,
        ),
    );
    var pending_state = video_inputs.state;
    pending_state.pending = 1;
    pending_state.pending_segment_index = 1;
    pending_state.pending_first_frame = 2;
    pending_state.pending_frame_count = 2;
    pending_state.pending_start_tick = 5;
    pending_state.pending_end_tick = 10;
    pending_state.visible_segments = 2;
    pending_state.visible_frames = 4;
    pending_state.visible_end_tick = 10;
    pending_state.next_segment_index = 2;
    pending_state.next_frame_ordinal = 4;
    pending_state.next_start_tick = 10;
    pending_state.generation = 3;
    pending_state.pending_publication_result_sha256 =
        model.sha256("pending generated media video result");
    pending_state.pending_output_sha256 =
        model.sha256("pending generated media video output");
    pending_state.previous_publication_result_sha256 =
        pending_state.pending_publication_result_sha256;
    pending_state.state_sha256 = video.stateRootV1(pending_state);
    try video.validateStateV1(pending_state);
    try std.testing.expectError(
        Error.InvalidBinding,
        videoMemberV1(
            pending_state,
            video_inputs.manifest,
            video_inputs.provenance,
            video_inputs.result,
            video_inputs.acknowledgement,
        ),
    );
}

test "generated media roots match the independent reference chain" {
    const fixture = try referenceFixtureV1();
    const expected = .{
        .{
            fixture.image1.member_sha256,
            "8eb5fb1951d0e0fb358ba418456327c6752c23ec8342363f22ff945f2e00227e",
        },
        .{
            fixture.audio1.member_sha256,
            "122e084af15cf69167f3f2e88f94719bec62c96bc1f759a4b5e113a3d887c167",
        },
        .{
            fixture.video1.member_sha256,
            "ac25f1f95f9466e49252e5d10769cf862fbb40e58aef8cc0e29891a8d1811d94",
        },
        .{
            fixture.checkpoint1.checkpoint_sha256,
            "543c160372a565b2663cddc3ac6b15c385d3d56723e9cdf40cb253c696eebddd",
        },
        .{
            fixture.selector1.selector_sha256,
            "423ac653e10b4ef4e4b5eb21707700f08b3e2836acc4ee8a4dcd1ee76b0de60d",
        },
        .{
            fixture.image2.member_sha256,
            "b6187ac1e8c709451e06d480a9051f30611eb8fe3e62b13a24c448b49fd87d4f",
        },
        .{
            fixture.audio2.member_sha256,
            "8fcc8400ab74e05b933ca37aa5a1890100f36c98f4585fd76202cad36485ab5d",
        },
        .{
            fixture.video2.member_sha256,
            "46048dfec3fd752233591ff6b0de35fd9ea3f8387ccd0d818884180a018d2e63",
        },
        .{
            fixture.checkpoint2.checkpoint_sha256,
            "372bd7c26248520a7293715caa6e7872897454d350041d2d0a1bb0c475330d59",
        },
        .{
            fixture.selector2.selector_sha256,
            "2222c55c70e63a50e1bb23c2542f0c39a0f5179ee68c6fe3be69134671692d7e",
        },
    };
    inline for (expected) |entry| {
        try std.testing.expectEqual(
            try digestFromHexV1(entry[1]),
            entry[0],
        );
    }
}

fn makeTestImageInputsV1(
    scope: Digest,
    policy: Digest,
    challenge: Digest,
) !ImageInputs {
    var plan: image.GeneratedImagePlanV1 = .{
        .request_epoch = 70_001,
        .generation = 1,
        .image_index = 1,
        .source_step = 2,
        .width = 2,
        .height = 2,
        .channels = 1,
        .row_stride = 2,
        .latent_bytes = 4,
        .pixel_bytes = 4,
        .maximum_output_bytes = 4,
        .decoder_abi = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
        .publication_sequence = 1,
        .visible_images_before = 0,
        .visible_images_after = 1,
        .logical_units = 1,
        .required_capabilities = 0,
        .artifact_sha256 = model.sha256("typed image artifact"),
        .terminal_result_sha256 = model.sha256("typed image terminal result"),
        .terminal_plan_sha256 = model.sha256("typed image terminal plan"),
        .terminal_output_sha256 = model.sha256("typed image terminal output"),
        .terminal_state_publication_sha256 = model.sha256("typed image terminal state"),
        .stateful_checkpoint_sha256 = model.sha256("typed image checkpoint"),
        .decoder_payload_sha256 = model.sha256("typed image decoder payload"),
        .decoder_implementation_sha256 = model.sha256("typed image decoder implementation"),
        .tenant_scope_sha256 = scope,
        .metadata_policy_sha256 = policy,
        .source_provenance_sha256 = model.sha256("typed image source provenance"),
        .challenge_sha256 = challenge,
        .previous_plan_sha256 = model.sha256("typed image previous plan"),
        .previous_result_sha256 = model.sha256("typed image previous result"),
        .media_object_sha256 = model.sha256("typed image media object"),
        .plan_sha256 = [_]u8{0} ** 32,
    };
    plan.plan_sha256 = image.generatedImagePlanRootV1(plan);
    try image.validateGeneratedImagePlanV1(plan);
    const provenance = try image.makeGeneratedImageProvenanceV1(
        plan,
        model.sha256("typed image output"),
    );
    var result: image.GeneratedImageResultV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .image_index = plan.image_index,
        .source_step = plan.source_step,
        .width = plan.width,
        .height = plan.height,
        .channels = plan.channels,
        .row_stride = plan.row_stride,
        .pixel_bytes = plan.pixel_bytes,
        .publication_sequence = plan.publication_sequence,
        .visible_images_before = plan.visible_images_before,
        .visible_images_after = plan.visible_images_after,
        .logical_units = plan.logical_units,
        .decoder_abi = plan.decoder_abi,
        .plan_sha256 = plan.plan_sha256,
        .provenance_sha256 = provenance.provenance_sha256,
        .artifact_sha256 = plan.artifact_sha256,
        .terminal_result_sha256 = plan.terminal_result_sha256,
        .terminal_output_sha256 = plan.terminal_output_sha256,
        .terminal_state_publication_sha256 = plan.terminal_state_publication_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .output_sha256 = provenance.output_sha256,
        .resource_receipt_sha256 = model.sha256("typed image resource receipt"),
        .publication_state_before_sha256 = model.sha256("typed image state before"),
        .timeline_event_sha256 = model.sha256("typed image timeline event"),
        .media_commit_sha256 = model.sha256("typed image media commit"),
        .publication_state_after_sha256 = model.sha256("typed image state after"),
        .previous_result_sha256 = plan.previous_result_sha256,
        .decoder_implementation_sha256 = plan.decoder_implementation_sha256,
        .challenge_sha256 = challenge,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.result_sha256 = image.generatedImageResultRootV1(result);
    try image.validateGeneratedImageResultV1(result);
    return .{
        .plan = plan,
        .provenance = provenance,
        .result = result,
    };
}

fn makeTestAudioInputsV1(
    scope: Digest,
    policy: Digest,
    challenge: Digest,
) !AudioInputs {
    const artifact = model.sha256("typed audio artifact");
    const source_state = try audio.makeInitialStateV1(
        70_001,
        16_000,
        1,
        artifact,
        scope,
        policy,
        challenge,
    );
    return makeTestAudioInputsFromStateV1(
        source_state,
        model.sha256("typed audio source result"),
        model.sha256("typed audio source output"),
        model.sha256("typed audio output"),
        model.sha256("typed audio resource receipt"),
    );
}

fn makeTestAudioSuccessorInputsV1(
    previous: AudioInputs,
) !AudioInputs {
    return makeTestAudioInputsFromStateV1(
        previous.state,
        model.sha256("typed successor audio source result"),
        model.sha256("typed successor audio source output"),
        model.sha256("typed successor audio output"),
        model.sha256("typed successor audio resource receipt"),
    );
}

fn makeTestAudioInputsFromStateV1(
    source_state: audio.GeneratedAudioStateV1,
    source_result_sha256: Digest,
    source_output_sha256: Digest,
    output_sha256: Digest,
    resource_receipt_sha256: Digest,
) !AudioInputs {
    const plan = try audio.makePlanV1(
        source_state,
        2,
        2,
        4,
        0,
        1,
        source_result_sha256,
        source_output_sha256,
        model.sha256("typed audio renderer payload"),
        model.sha256("typed audio renderer"),
        model.sha256("typed audio media object"),
    );
    const provenance = try audio.makeProvenanceV1(
        plan,
        output_sha256,
    );
    var result: audio.GeneratedAudioResultV1 = .{
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
        .resource_receipt_sha256 = resource_receipt_sha256,
        .state_before_sha256 = plan.state_before_sha256,
        .previous_publication_result_sha256 = plan.previous_publication_result_sha256,
        .renderer_implementation_sha256 = plan.renderer_implementation_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.result_sha256 = audio.resultRootV1(result);
    try audio.validateResultV1(result);
    var state = source_state;
    state.generation = plan.generation;
    state.next_chunk_index = plan.visible_chunks_after;
    state.next_start_frame = plan.visible_frames_after;
    state.visible_chunks = plan.visible_chunks_after;
    state.visible_frames = plan.visible_frames_after;
    state.pending = 1;
    state.pending_chunk_index = plan.chunk_index;
    state.pending_start_frame = plan.start_frame;
    state.pending_frame_count = plan.frame_count;
    state.pending_publication_result_sha256 = result.result_sha256;
    state.pending_output_sha256 = result.output_sha256;
    state.state_sha256 = [_]u8{0} ** 32;
    state.state_sha256 = audio.stateRootV1(state);
    try audio.validateStateV1(state);
    const observation = try audio.makePlaybackObservationV1(
        state,
        model.sha256("typed audio sink implementation"),
        model.sha256("typed audio sink instance"),
    );
    const ack_plan = try audio.makePlaybackAckPlanV1(
        state,
        result,
        observation,
    );
    const acknowledgement = try audio.acknowledgePlaybackV1(
        &state,
        result,
        observation,
        ack_plan,
    );
    return .{
        .state = state,
        .plan = plan,
        .provenance = provenance,
        .result = result,
        .acknowledgement = acknowledgement,
    };
}

fn makeTestVideoInputsV1(
    scope: Digest,
    policy: Digest,
    challenge: Digest,
) !VideoInputs {
    const artifact = model.sha256("typed video artifact");
    const source_state = try video.initializeStateV1(
        70_001,
        2,
        2,
        1,
        artifact,
        scope,
        policy,
        challenge,
    );
    const manifest = try video.makeManifestV1(
        source_state,
        2,
        3,
        2,
        8,
        0,
        1,
        model.sha256("typed video source result"),
        model.sha256("typed video source output"),
        model.sha256("typed video renderer payload"),
        model.sha256("typed video renderer"),
        model.sha256("typed video media object"),
        model.sha256("typed video first frame"),
        model.sha256("typed video second frame"),
    );
    const provenance = try video.makeProvenanceV1(
        manifest,
        model.sha256("typed video output"),
    );
    var result: video.GeneratedVideoResultV1 = .{
        .request_epoch = manifest.request_epoch,
        .generation = manifest.generation,
        .segment_index = manifest.segment_index,
        .first_frame_ordinal = manifest.first_frame_ordinal,
        .frame_count = manifest.frame_count,
        .end_frame_ordinal = manifest.visible_frames_after,
        .start_tick = manifest.start_tick,
        .end_tick = manifest.end_tick,
        .width = manifest.width,
        .height = manifest.height,
        .channels = manifest.channels,
        .bytes_per_channel = manifest.bytes_per_channel,
        .total_output_bytes = manifest.total_output_bytes,
        .publication_sequence = manifest.publication_sequence,
        .visible_segments_before = manifest.visible_segments_before,
        .visible_segments_after = manifest.visible_segments_after,
        .visible_frames_before = manifest.visible_frames_before,
        .visible_frames_after = manifest.visible_frames_after,
        .visible_end_tick_before = manifest.visible_end_tick_before,
        .visible_end_tick_after = manifest.visible_end_tick_after,
        .manifest_sha256 = manifest.manifest_sha256,
        .provenance_sha256 = provenance.provenance_sha256,
        .artifact_sha256 = artifact,
        .source_result_sha256 = manifest.source_result_sha256,
        .source_output_sha256 = manifest.source_output_sha256,
        .media_object_sha256 = manifest.media_object_sha256,
        .first_frame_sha256 = manifest.first_frame_sha256,
        .second_frame_sha256 = manifest.second_frame_sha256,
        .output_sha256 = provenance.output_sha256,
        .resource_receipt_sha256 = model.sha256("typed video resource receipt"),
        .state_before_sha256 = manifest.state_before_sha256,
        .previous_publication_result_sha256 = manifest.previous_publication_result_sha256,
        .renderer_implementation_sha256 = manifest.renderer_implementation_sha256,
        .challenge_sha256 = challenge,
        .result_sha256 = [_]u8{0} ** 32,
    };
    result.result_sha256 = video.resultRootV1(result);
    try video.validateResultBindingV1(
        manifest,
        provenance,
        result,
    );
    var state = source_state;
    state.generation = manifest.generation;
    state.next_segment_index = manifest.visible_segments_after;
    state.next_frame_ordinal = manifest.visible_frames_after;
    state.next_start_tick = manifest.end_tick;
    state.visible_segments = manifest.visible_segments_after;
    state.visible_frames = manifest.visible_frames_after;
    state.visible_end_tick = manifest.end_tick;
    state.pending = 1;
    state.pending_segment_index = manifest.segment_index;
    state.pending_first_frame = manifest.first_frame_ordinal;
    state.pending_frame_count = manifest.frame_count;
    state.pending_start_tick = manifest.start_tick;
    state.pending_end_tick = manifest.end_tick;
    state.previous_publication_result_sha256 =
        result.result_sha256;
    state.pending_publication_result_sha256 =
        result.result_sha256;
    state.pending_output_sha256 = result.output_sha256;
    state.state_sha256 = [_]u8{0} ** 32;
    state.state_sha256 = video.stateRootV1(state);
    try video.validateStateV1(state);
    const observation = try video.makeDisplayObservationV1(
        state,
        model.sha256("typed video sink implementation"),
        model.sha256("typed video sink instance"),
    );
    const acknowledgement_plan =
        try video.makeDisplayAckPlanV1(
            state,
            result,
            observation,
        );
    const acknowledgement =
        try video.acknowledgeDisplayV1(
            &state,
            result,
            observation,
            acknowledgement_plan,
        );
    return .{
        .state = state,
        .manifest = manifest,
        .provenance = provenance,
        .result = result,
        .acknowledgement = acknowledgement,
    };
}

fn digestFromHexV1(hex: []const u8) !Digest {
    if (hex.len != 64)
        return Error.InvalidBinding;
    var digest: Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch
        return Error.InvalidBinding;
    return digest;
}
