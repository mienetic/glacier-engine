const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const stateful = @import("stateful_model_adapter.zig");
const model_continuation =
    @import("stateful_model_continuation.zig");
const video_model =
    @import("stateful_video_adapter.zig");
const video_segment =
    @import("video_segment_adapter.zig");
const video_timeline =
    @import("video_segment_timeline.zig");
const audio = @import("audio_transcript_adapter.zig");
const result_link =
    @import("audio_video_result_link.zig");

const Digest = [32]u8;

pub const checkpoint_abi: u64 =
    0x4756_4d43_5000_0001;
pub const checkpoint_bytes: usize = 768;
const checkpoint_body_bytes = checkpoint_bytes - 32;
const allowed_flags: u64 = 0;
const checkpoint_magic =
    [_]u8{ 'G', 'V', 'M', 'C', 'P', '1', 0, 0 };
const checkpoint_domain =
    "glacier-video-model-continuation-v1\x00";

pub const Error = model.Error || resource_bank.Error ||
    stateful.Error || model_continuation.Error ||
    video_model.Error || video_segment.Error ||
    video_timeline.Error || audio.Error ||
    result_link.Error || error{
    InvalidCheckpoint,
    InvalidBinding,
    InvalidState,
};

pub const CheckpointV1 = struct {
    request_epoch: u64,
    completed_generation: u64,
    next_generation: u64,
    next_segment_index: u64,
    next_first_frame_ordinal: u64,
    next_frame_count: u64,
    next_previous_end_tick: u64,
    next_start_tick: u64,
    next_end_tick: u64,
    next_discontinuity_ticks: u64,
    target_numerator: u64,
    target_denominator: u64,
    state_bytes: u64,
    source_bank_epoch: u64,
    restore_bank_epoch: u64,
    model_publication_next_sequence: u64,
    timeline_next_sequence: u64,
    timeline_visible_segments: u64,
    link_next_sequence: u64,
    visible_links: u64,
    stateful_checkpoint_sha256: Digest,
    state_publication_sha256: Digest,
    restored_state_sha256: Digest,
    previous_window_sha256: Digest,
    previous_segment_sha256: Digest,
    next_window_sha256: Digest,
    video_timeline_sha256: Digest,
    previous_overlap_sha256: Digest,
    previous_transcript_sha256: Digest,
    next_overlap_sha256: Digest,
    next_transcript_sha256: Digest,
    link_state_sha256: Digest,
    previous_link_sha256: Digest,
    audio_media_sha256: Digest,
    video_media_sha256: Digest,
    challenge_sha256: Digest,
    checkpoint_sha256: Digest,
};

pub const ResumeSession = struct {
    inner: model_continuation.ResumeSession = .{},
    checkpoint: CheckpointV1 = undefined,
    previous_window: video_model.FrameWindowV1 =
        undefined,
    previous_segment: video_segment.VideoSegmentV1 =
        undefined,
    next_window: video_model.FrameWindowV1 =
        undefined,
    timeline: video_timeline.VideoSegmentTimelineV1 =
        undefined,
    previous_overlap: audio.OverlapPlanV1 = undefined,
    previous_transcript: audio.TranscriptSegmentV1 =
        undefined,
    next_overlap: audio.OverlapPlanV1 = undefined,
    next_transcript: audio.TranscriptSegmentV1 =
        undefined,
    previous_link: result_link.AudioVideoResultLinkV1 =
        undefined,
    link_state: result_link.AudioVideoLinkStateV1 =
        undefined,
    initialized: bool = false,

    pub fn prepareV1(
        self: *ResumeSession,
        bank: *resource_bank.Bank,
        checkpoint_wire: []const u8,
        stateful_checkpoint_wire: []const u8,
        state_publication_wire: []const u8,
        previous_window_wire: []const u8,
        previous_segment_wire: []const u8,
        next_window_wire: []const u8,
        timeline_wire: []const u8,
        previous_overlap_wire: []const u8,
        previous_transcript_wire: []const u8,
        next_overlap_wire: []const u8,
        next_transcript_wire: []const u8,
        previous_link_wire: []const u8,
        link_state_wire: []const u8,
    ) Error!void {
        if (self.initialized or
            self.inner.phase != .idle)
            return Error.InvalidState;
        const checkpoint =
            try decodeCheckpointV1(checkpoint_wire);
        const stateful_checkpoint =
            try model_continuation.decodeCheckpointV1(
                stateful_checkpoint_wire,
            );
        const state_publication =
            try stateful.decodeStatePublicationV1(
                state_publication_wire,
            );
        const previous_window =
            try video_model.decodeFrameWindowV1(
                previous_window_wire,
            );
        const previous_segment =
            try video_segment.decodeVideoSegmentV1(
                previous_segment_wire,
            );
        const next_window =
            try video_model.decodeFrameWindowV1(
                next_window_wire,
            );
        const timeline =
            try video_timeline.decodeTimelineV1(
                timeline_wire,
            );
        const previous_overlap =
            try audio.decodeOverlapPlanV1(
                previous_overlap_wire,
            );
        const previous_transcript =
            try audio.decodeTranscriptSegmentV1(
                previous_transcript_wire,
            );
        const next_overlap =
            try audio.decodeOverlapPlanV1(
                next_overlap_wire,
            );
        const next_transcript =
            try audio.decodeTranscriptSegmentV1(
                next_transcript_wire,
            );
        const previous_link =
            try result_link.decodeResultLinkV1(
                previous_link_wire,
            );
        const link_state =
            try result_link.decodeLinkStateV1(
                link_state_wire,
            );
        try validateCheckpointBindingsV1(
            checkpoint,
            stateful_checkpoint,
            state_publication,
            previous_window,
            previous_segment,
            next_window,
            timeline,
            previous_overlap,
            previous_transcript,
            next_overlap,
            next_transcript,
            previous_link,
            link_state,
        );
        var inner: model_continuation.ResumeSession =
            .{};
        try inner.prepareV1(
            bank,
            stateful_checkpoint_wire,
            state_publication_wire,
        );
        self.* = .{
            .inner = inner,
            .checkpoint = checkpoint,
            .previous_window = previous_window,
            .previous_segment = previous_segment,
            .next_window = next_window,
            .timeline = timeline,
            .previous_overlap = previous_overlap,
            .previous_transcript = previous_transcript,
            .next_overlap = next_overlap,
            .next_transcript = next_transcript,
            .previous_link = previous_link,
            .link_state = link_state,
            .initialized = true,
        };
    }

    pub fn commitMaterializedV1(
        self: *ResumeSession,
        durable_state: []const u8,
        destination: []u8,
    ) Error!void {
        if (!self.initialized)
            return Error.InvalidState;
        try self.inner.commitMaterializedV1(
            durable_state,
            destination,
        );
    }

    pub fn abortPreparedV1(
        self: *ResumeSession,
    ) Error!void {
        if (!self.initialized)
            return Error.InvalidState;
        try self.inner.abortPreparedV1();
        self.initialized = false;
    }

    pub fn closeAndRelease(
        self: *ResumeSession,
    ) Error!void {
        if (!self.initialized)
            return Error.InvalidState;
        try self.inner.closeAndRelease();
        self.initialized = false;
    }
};

pub fn makeCheckpointV1(
    stateful_checkpoint: model_continuation.CheckpointV1,
    state_publication: stateful.StatePublicationV1,
    previous_window: video_model.FrameWindowV1,
    previous_segment: video_segment.VideoSegmentV1,
    next_window: video_model.FrameWindowV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    previous_overlap: audio.OverlapPlanV1,
    previous_transcript: audio.TranscriptSegmentV1,
    next_overlap: audio.OverlapPlanV1,
    next_transcript: audio.TranscriptSegmentV1,
    previous_link: result_link.AudioVideoResultLinkV1,
    link_state: result_link.AudioVideoLinkStateV1,
) Error!CheckpointV1 {
    const next_generation = std.math.add(
        u64,
        stateful_checkpoint.current_step,
        1,
    ) catch return Error.InvalidCheckpoint;
    var checkpoint: CheckpointV1 = .{
        .request_epoch = stateful_checkpoint.request_epoch,
        .completed_generation = stateful_checkpoint.current_step,
        .next_generation = next_generation,
        .next_segment_index = next_window.segment_index,
        .next_first_frame_ordinal = next_window.first_frame_ordinal,
        .next_frame_count = next_window.frame_count,
        .next_previous_end_tick = next_window.previous_end_tick,
        .next_start_tick = next_window.start_tick,
        .next_end_tick = next_window.end_tick,
        .next_discontinuity_ticks = next_window.discontinuity_before_ticks,
        .target_numerator = next_window.target_numerator,
        .target_denominator = next_window.target_denominator,
        .state_bytes = stateful_checkpoint.state_bytes,
        .source_bank_epoch = stateful_checkpoint.source_bank_epoch,
        .restore_bank_epoch = stateful_checkpoint.restore_bank_epoch,
        .model_publication_next_sequence = stateful_checkpoint.publication_next_sequence,
        .timeline_next_sequence = timeline.next_sequence,
        .timeline_visible_segments = timeline.visible_segments,
        .link_next_sequence = link_state.next_sequence,
        .visible_links = link_state.visible_links,
        .stateful_checkpoint_sha256 = stateful_checkpoint.checkpoint_sha256,
        .state_publication_sha256 = state_publication.publication_sha256,
        .restored_state_sha256 = state_publication.current_state_sha256,
        .previous_window_sha256 = previous_window.window_sha256,
        .previous_segment_sha256 = previous_segment.segment_sha256,
        .next_window_sha256 = next_window.window_sha256,
        .video_timeline_sha256 = timeline.timeline_sha256,
        .previous_overlap_sha256 = previous_overlap.overlap_sha256,
        .previous_transcript_sha256 = previous_transcript.transcript_sha256,
        .next_overlap_sha256 = next_overlap.overlap_sha256,
        .next_transcript_sha256 = next_transcript.transcript_sha256,
        .link_state_sha256 = link_state.state_sha256,
        .previous_link_sha256 = previous_link.link_sha256,
        .audio_media_sha256 = previous_overlap.media_object_sha256,
        .video_media_sha256 = previous_window.media_object_sha256,
        .challenge_sha256 = stateful_checkpoint.challenge_sha256,
        .checkpoint_sha256 = [_]u8{0} ** 32,
    };
    checkpoint.checkpoint_sha256 =
        checkpointRootV1(checkpoint);
    try validateCheckpointBindingsV1(
        checkpoint,
        stateful_checkpoint,
        state_publication,
        previous_window,
        previous_segment,
        next_window,
        timeline,
        previous_overlap,
        previous_transcript,
        next_overlap,
        next_transcript,
        previous_link,
        link_state,
    );
    return checkpoint;
}

pub fn validateCheckpointV1(
    checkpoint: CheckpointV1,
) Error!void {
    const expected_next = std.math.add(
        u64,
        checkpoint.completed_generation,
        1,
    ) catch return Error.InvalidCheckpoint;
    if (checkpoint.request_epoch == 0 or
        checkpoint.completed_generation == 0 or
        checkpoint.next_generation != expected_next or
        checkpoint.next_segment_index == 0 or
        checkpoint.next_frame_count == 0 or
        checkpoint.next_frame_count >
            video_model.frame_capacity or
        checkpoint.next_start_tick <
            checkpoint.next_previous_end_tick or
        checkpoint.next_start_tick >=
            checkpoint.next_end_tick or
        checkpoint.next_discontinuity_ticks !=
            checkpoint.next_start_tick -
                checkpoint.next_previous_end_tick or
        checkpoint.target_numerator == 0 or
        checkpoint.target_denominator == 0 or
        checkpoint.state_bytes == 0 or
        checkpoint.source_bank_epoch == 0 or
        checkpoint.restore_bank_epoch == 0 or
        checkpoint.source_bank_epoch ==
            checkpoint.restore_bank_epoch or
        checkpoint.model_publication_next_sequence !=
            checkpoint.completed_generation or
        checkpoint.timeline_visible_segments == 0 or
        checkpoint.link_next_sequence !=
            checkpoint.visible_links or
        checkpoint.visible_links == 0 or
        isZero(checkpoint.stateful_checkpoint_sha256) or
        isZero(checkpoint.state_publication_sha256) or
        isZero(checkpoint.restored_state_sha256) or
        isZero(checkpoint.previous_window_sha256) or
        isZero(checkpoint.previous_segment_sha256) or
        isZero(checkpoint.next_window_sha256) or
        isZero(checkpoint.video_timeline_sha256) or
        isZero(checkpoint.previous_overlap_sha256) or
        isZero(checkpoint.previous_transcript_sha256) or
        isZero(checkpoint.next_overlap_sha256) or
        isZero(checkpoint.next_transcript_sha256) or
        isZero(checkpoint.link_state_sha256) or
        isZero(checkpoint.previous_link_sha256) or
        isZero(checkpoint.audio_media_sha256) or
        isZero(checkpoint.video_media_sha256) or
        isZero(checkpoint.challenge_sha256) or
        !std.mem.eql(
            u8,
            &checkpoint.checkpoint_sha256,
            &checkpointRootV1(checkpoint),
        ))
        return Error.InvalidCheckpoint;
}

pub fn validateCheckpointBindingsV1(
    checkpoint: CheckpointV1,
    stateful_checkpoint: model_continuation.CheckpointV1,
    state_publication: stateful.StatePublicationV1,
    previous_window: video_model.FrameWindowV1,
    previous_segment: video_segment.VideoSegmentV1,
    next_window: video_model.FrameWindowV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    previous_overlap: audio.OverlapPlanV1,
    previous_transcript: audio.TranscriptSegmentV1,
    next_overlap: audio.OverlapPlanV1,
    next_transcript: audio.TranscriptSegmentV1,
    previous_link: result_link.AudioVideoResultLinkV1,
    link_state: result_link.AudioVideoLinkStateV1,
) Error!void {
    try validateCheckpointV1(checkpoint);
    try model_continuation.validateCheckpointV1(
        stateful_checkpoint,
    );
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    try video_model.validateFrameWindowV1(
        previous_window,
    );
    try video_segment.validateVideoSegmentV1(
        previous_segment,
    );
    try video_model.validateFrameWindowV1(
        next_window,
    );
    try video_model.validateFramePredecessorV1(
        previous_window,
        next_window,
    );
    try video_timeline.validateTimelineV1(timeline);
    try audio.validateOverlapPlanV1(previous_overlap);
    try audio.validateTranscriptSegmentV1(
        previous_transcript,
    );
    try audio.validateOverlapPlanV1(next_overlap);
    try audio.validateTranscriptSegmentV1(
        next_transcript,
    );
    try audio.validateTranscriptPredecessorV1(
        next_overlap,
        previous_transcript,
    );
    try result_link.validateResultLinkV1(
        previous_link,
    );
    try result_link.validateLinkStateV1(link_state);
    var previous_segment_wire: [video_segment.video_segment_bytes]u8 =
        undefined;
    _ = try video_segment.encodeVideoSegmentV1(
        previous_segment,
        &previous_segment_wire,
    );
    const expected_next_segment = std.math.add(
        u64,
        previous_segment.segment_index,
        1,
    ) catch return Error.InvalidBinding;
    const expected_next_link = std.math.add(
        u64,
        previous_link.link_sequence,
        1,
    ) catch return Error.InvalidBinding;
    var previous_link_state = link_state;
    previous_link_state.next_sequence =
        previous_link.link_sequence;
    previous_link_state.visible_links =
        previous_link.link_sequence;
    previous_link_state.last_link_index =
        previous_link.link_sequence;
    previous_link_state.previous_link_sha256 =
        previous_link.previous_link_sha256;
    previous_link_state.state_sha256 =
        result_link.linkStateRootV1(
            previous_link_state,
        );
    const expected_previous_link =
        result_link.makeResultLinkV1(
            previous_link_state,
            previous_overlap,
            previous_transcript,
            timeline,
        ) catch return Error.InvalidBinding;
    if (!segmentMatchesWindowV1(
        previous_segment,
        previous_window,
    ) or
        !transcriptMatchesOverlapV1(
            previous_transcript,
            previous_overlap,
        ) or
        !transcriptMatchesOverlapV1(
            next_transcript,
            next_overlap,
        ) or
        !std.meta.eql(
            expected_previous_link,
            previous_link,
        ) or
        checkpoint.request_epoch !=
            stateful_checkpoint.request_epoch or
        checkpoint.request_epoch !=
            state_publication.request_epoch or
        checkpoint.request_epoch !=
            previous_window.request_epoch or
        checkpoint.request_epoch !=
            previous_segment.request_epoch or
        checkpoint.request_epoch !=
            next_window.request_epoch or
        checkpoint.request_epoch !=
            timeline.request_epoch or
        checkpoint.request_epoch !=
            previous_overlap.request_epoch or
        checkpoint.request_epoch !=
            next_overlap.request_epoch or
        checkpoint.request_epoch !=
            link_state.request_epoch or
        checkpoint.completed_generation !=
            stateful_checkpoint.current_step or
        checkpoint.completed_generation !=
            previous_window.generation or
        checkpoint.completed_generation !=
            previous_segment.generation or
        checkpoint.next_generation !=
            next_window.generation or
        checkpoint.next_segment_index !=
            expected_next_segment or
        checkpoint.next_segment_index !=
            next_window.segment_index or
        checkpoint.next_first_frame_ordinal !=
            next_window.first_frame_ordinal or
        checkpoint.next_frame_count !=
            next_window.frame_count or
        checkpoint.next_previous_end_tick !=
            next_window.previous_end_tick or
        checkpoint.next_start_tick !=
            next_window.start_tick or
        checkpoint.next_end_tick !=
            next_window.end_tick or
        checkpoint.next_discontinuity_ticks !=
            next_window.discontinuity_before_ticks or
        checkpoint.target_numerator !=
            next_window.target_numerator or
        checkpoint.target_denominator !=
            next_window.target_denominator or
        checkpoint.state_bytes !=
            stateful_checkpoint.state_bytes or
        checkpoint.state_bytes !=
            state_publication.state_bytes or
        checkpoint.source_bank_epoch !=
            stateful_checkpoint.source_bank_epoch or
        checkpoint.restore_bank_epoch !=
            stateful_checkpoint.restore_bank_epoch or
        checkpoint.model_publication_next_sequence !=
            stateful_checkpoint.publication_next_sequence or
        checkpoint.timeline_next_sequence !=
            timeline.next_sequence or
        checkpoint.timeline_visible_segments !=
            timeline.visible_segments or
        checkpoint.link_next_sequence !=
            link_state.next_sequence or
        checkpoint.link_next_sequence !=
            expected_next_link or
        checkpoint.visible_links !=
            link_state.visible_links or
        checkpoint.visible_links !=
            previous_link.link_index or
        timeline.tail_segment_index !=
            previous_segment.segment_index or
        timeline.tail_first_frame !=
            previous_segment.first_frame or
        timeline.tail_last_frame !=
            previous_segment.last_frame or
        timeline.target_numerator !=
            previous_segment.target_base.numerator or
        timeline.target_denominator !=
            previous_segment.target_base.denominator or
        timeline.tail_start_tick !=
            previous_segment.target_start_tick or
        timeline.tail_end_tick !=
            previous_segment.target_end_tick or
        !std.mem.eql(
            u8,
            &timeline.tail_segment_sha256,
            &previous_segment.segment_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.stateful_checkpoint_sha256,
            &stateful_checkpoint.checkpoint_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.state_publication_sha256,
            &state_publication.publication_sha256,
        ) or
        !std.mem.eql(
            u8,
            &stateful_checkpoint.state_publication_sha256,
            &state_publication.publication_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.restored_state_sha256,
            &state_publication.current_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &stateful_checkpoint.current_state_sha256,
            &state_publication.current_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &stateful_checkpoint.last_output_sha256,
            &model.sha256(&previous_segment_wire),
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_window_sha256,
            &previous_window.window_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_segment_sha256,
            &previous_segment.segment_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.next_window_sha256,
            &next_window.window_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.video_timeline_sha256,
            &timeline.timeline_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_overlap_sha256,
            &previous_overlap.overlap_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_transcript_sha256,
            &previous_transcript.transcript_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.next_overlap_sha256,
            &next_overlap.overlap_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.next_transcript_sha256,
            &next_transcript.transcript_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.link_state_sha256,
            &link_state.state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_link_sha256,
            &previous_link.link_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_link_sha256,
            &link_state.previous_link_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.audio_media_sha256,
            &previous_overlap.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.audio_media_sha256,
            &next_overlap.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.audio_media_sha256,
            &link_state.audio_media_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.video_media_sha256,
            &previous_window.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.video_media_sha256,
            &next_window.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.video_media_sha256,
            &timeline.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.video_media_sha256,
            &link_state.video_media_sha256,
        ) or
        !challengeMatchesAllV1(
            checkpoint.challenge_sha256,
            stateful_checkpoint,
            state_publication,
            previous_window,
            next_window,
            timeline,
            previous_overlap,
            next_overlap,
            link_state,
        ))
        return Error.InvalidBinding;
}

pub fn encodeCheckpointV1(
    checkpoint: CheckpointV1,
    output: *[checkpoint_bytes]u8,
) Error![]const u8 {
    try validateCheckpointV1(checkpoint);
    writeCheckpointBodyV1(
        checkpoint,
        output[0..checkpoint_body_bytes],
    );
    @memcpy(
        output[checkpoint_body_bytes..],
        &checkpoint.checkpoint_sha256,
    );
    return output;
}

pub fn decodeCheckpointV1(
    encoded: []const u8,
) Error!CheckpointV1 {
    if (encoded.len != checkpoint_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &checkpoint_magic,
        ) or
        readU64(encoded, 8) != checkpoint_abi or
        readU64(encoded, 16) != checkpoint_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[192..224], 0))
        return Error.InvalidCheckpoint;
    const checkpoint: CheckpointV1 = .{
        .request_epoch = readU64(encoded, 32),
        .completed_generation = readU64(encoded, 40),
        .next_generation = readU64(encoded, 48),
        .next_segment_index = readU64(encoded, 56),
        .next_first_frame_ordinal = readU64(encoded, 64),
        .next_frame_count = readU64(encoded, 72),
        .next_previous_end_tick = readU64(encoded, 80),
        .next_start_tick = readU64(encoded, 88),
        .next_end_tick = readU64(encoded, 96),
        .next_discontinuity_ticks = readU64(encoded, 104),
        .target_numerator = readU64(encoded, 112),
        .target_denominator = readU64(encoded, 120),
        .state_bytes = readU64(encoded, 128),
        .source_bank_epoch = readU64(encoded, 136),
        .restore_bank_epoch = readU64(encoded, 144),
        .model_publication_next_sequence = readU64(encoded, 152),
        .timeline_next_sequence = readU64(encoded, 160),
        .timeline_visible_segments = readU64(encoded, 168),
        .link_next_sequence = readU64(encoded, 176),
        .visible_links = readU64(encoded, 184),
        .stateful_checkpoint_sha256 = encoded[224..256].*,
        .state_publication_sha256 = encoded[256..288].*,
        .restored_state_sha256 = encoded[288..320].*,
        .previous_window_sha256 = encoded[320..352].*,
        .previous_segment_sha256 = encoded[352..384].*,
        .next_window_sha256 = encoded[384..416].*,
        .video_timeline_sha256 = encoded[416..448].*,
        .previous_overlap_sha256 = encoded[448..480].*,
        .previous_transcript_sha256 = encoded[480..512].*,
        .next_overlap_sha256 = encoded[512..544].*,
        .next_transcript_sha256 = encoded[544..576].*,
        .link_state_sha256 = encoded[576..608].*,
        .previous_link_sha256 = encoded[608..640].*,
        .audio_media_sha256 = encoded[640..672].*,
        .video_media_sha256 = encoded[672..704].*,
        .challenge_sha256 = encoded[704..736].*,
        .checkpoint_sha256 = encoded[checkpoint_body_bytes..checkpoint_bytes].*,
    };
    try validateCheckpointV1(checkpoint);
    var canonical: [checkpoint_bytes]u8 = undefined;
    _ = try encodeCheckpointV1(
        checkpoint,
        &canonical,
    );
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidCheckpoint;
    return checkpoint;
}

pub fn checkpointRootV1(
    checkpoint: CheckpointV1,
) Digest {
    var body: [checkpoint_body_bytes]u8 =
        undefined;
    writeCheckpointBodyV1(checkpoint, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checkpoint_domain);
    hash.update(&body);
    return hash.finalResult();
}

fn segmentMatchesWindowV1(
    segment: video_segment.VideoSegmentV1,
    window: video_model.FrameWindowV1,
) bool {
    const last_index: usize =
        @intCast(window.frame_count - 1);
    return segment.request_epoch == window.request_epoch and
        segment.generation == window.generation and
        segment.segment_index == window.segment_index and
        segment.first_frame ==
            window.first_frame_ordinal and
        segment.last_frame ==
            window.frame_ordinals[last_index] and
        segment.frame_count == window.frame_count and
        segment.frame_stride == 1 and
        segment.keyframe_ordinal ==
            firstWindowKeyframeV1(window) and
        segment.eviction_boundary ==
            window.first_frame_ordinal and
        segment.cache_generation == window.generation and
        segment.target_base.numerator ==
            window.target_numerator and
        segment.target_base.denominator ==
            window.target_denominator and
        segment.target_start_tick == window.start_tick and
        segment.target_end_tick == window.end_tick and
        std.mem.eql(
            u8,
            &segment.media_object_sha256,
            &window.media_object_sha256,
        ) and
        std.mem.eql(
            u8,
            &segment.processor_bundle_sha256,
            &window.processor_bundle_sha256,
        ) and
        std.mem.eql(
            u8,
            &segment.cache_bundle_sha256,
            &window.cache_bundle_sha256,
        ) and
        std.mem.eql(
            u8,
            &segment.ownership_sha256,
            &window.ownership_sha256,
        ) and
        std.mem.eql(
            u8,
            &segment.selection_sha256,
            &window.window_sha256,
        ) and
        std.mem.eql(
            u8,
            &segment.challenge_sha256,
            &window.challenge_sha256,
        );
}

fn firstWindowKeyframeV1(
    window: video_model.FrameWindowV1,
) u64 {
    const count: usize = @intCast(window.frame_count);
    for (0..count) |index| {
        if (window.keyframe_flags[index] == 1)
            return window.frame_ordinals[index];
    }
    unreachable;
}

fn transcriptMatchesOverlapV1(
    transcript: audio.TranscriptSegmentV1,
    overlap: audio.OverlapPlanV1,
) bool {
    return transcript.request_epoch ==
        overlap.request_epoch and
        transcript.generation == overlap.generation and
        transcript.segment_index ==
            overlap.segment_index and
        transcript.context_start_sample ==
            overlap.context_start_sample and
        transcript.context_end_sample ==
            overlap.context_end_sample and
        transcript.publish_start_sample ==
            overlap.publish_start_sample and
        transcript.publish_end_sample ==
            overlap.publish_end_sample and
        transcript.sample_rate == overlap.sample_rate and
        std.mem.eql(
            u8,
            &transcript.media_object_sha256,
            &overlap.media_object_sha256,
        ) and
        std.mem.eql(
            u8,
            &transcript.processor_state_sha256,
            &overlap.processor_state_sha256,
        ) and
        std.mem.eql(
            u8,
            &transcript.cache_payload_sha256,
            &overlap.cache_payload_sha256,
        ) and
        std.mem.eql(
            u8,
            &transcript.overlap_sha256,
            &overlap.overlap_sha256,
        ) and
        std.mem.eql(
            u8,
            &transcript.previous_transcript_sha256,
            &overlap.previous_transcript_sha256,
        );
}

fn challengeMatchesAllV1(
    challenge: Digest,
    stateful_checkpoint: model_continuation.CheckpointV1,
    state_publication: stateful.StatePublicationV1,
    previous_window: video_model.FrameWindowV1,
    next_window: video_model.FrameWindowV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    previous_overlap: audio.OverlapPlanV1,
    next_overlap: audio.OverlapPlanV1,
    link_state: result_link.AudioVideoLinkStateV1,
) bool {
    return std.mem.eql(
        u8,
        &challenge,
        &stateful_checkpoint.challenge_sha256,
    ) and
        std.mem.eql(
            u8,
            &challenge,
            &state_publication.challenge_sha256,
        ) and
        std.mem.eql(
            u8,
            &challenge,
            &previous_window.challenge_sha256,
        ) and
        std.mem.eql(
            u8,
            &challenge,
            &next_window.challenge_sha256,
        ) and
        std.mem.eql(
            u8,
            &challenge,
            &timeline.challenge_sha256,
        ) and
        std.mem.eql(
            u8,
            &challenge,
            &previous_overlap.challenge_sha256,
        ) and
        std.mem.eql(
            u8,
            &challenge,
            &next_overlap.challenge_sha256,
        ) and
        std.mem.eql(
            u8,
            &challenge,
            &link_state.challenge_sha256,
        );
}

fn writeCheckpointBodyV1(
    checkpoint: CheckpointV1,
    output: *[checkpoint_body_bytes]u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &checkpoint_magic);
    writeU64(output, 8, checkpoint_abi);
    writeU64(output, 16, checkpoint_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        checkpoint.request_epoch,
        checkpoint.completed_generation,
        checkpoint.next_generation,
        checkpoint.next_segment_index,
        checkpoint.next_first_frame_ordinal,
        checkpoint.next_frame_count,
        checkpoint.next_previous_end_tick,
        checkpoint.next_start_tick,
        checkpoint.next_end_tick,
        checkpoint.next_discontinuity_ticks,
        checkpoint.target_numerator,
        checkpoint.target_denominator,
        checkpoint.state_bytes,
        checkpoint.source_bank_epoch,
        checkpoint.restore_bank_epoch,
        checkpoint.model_publication_next_sequence,
        checkpoint.timeline_next_sequence,
        checkpoint.timeline_visible_segments,
        checkpoint.link_next_sequence,
        checkpoint.visible_links,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        checkpoint.stateful_checkpoint_sha256,
        checkpoint.state_publication_sha256,
        checkpoint.restored_state_sha256,
        checkpoint.previous_window_sha256,
        checkpoint.previous_segment_sha256,
        checkpoint.next_window_sha256,
        checkpoint.video_timeline_sha256,
        checkpoint.previous_overlap_sha256,
        checkpoint.previous_transcript_sha256,
        checkpoint.next_overlap_sha256,
        checkpoint.next_transcript_sha256,
        checkpoint.link_state_sha256,
        checkpoint.previous_link_sha256,
        checkpoint.audio_media_sha256,
        checkpoint.video_media_sha256,
        checkpoint.challenge_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 224 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
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

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

pub const ReferenceSourceFixtureV1 = struct {
    manifest: model.ArtifactManifestV1,
    state_publication: stateful.StatePublicationV1,
    stateful_checkpoint: model_continuation.CheckpointV1,
    checkpoint: CheckpointV1,
    state_payload: [video_model.reference_state_bytes]u8,
    previous_window: video_model.FrameWindowV1,
    previous_segment: video_segment.VideoSegmentV1,
    next_window: video_model.FrameWindowV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    previous_overlap: audio.OverlapPlanV1,
    previous_transcript: audio.TranscriptSegmentV1,
    next_overlap: audio.OverlapPlanV1,
    next_transcript: audio.TranscriptSegmentV1,
    previous_link: result_link.AudioVideoResultLinkV1,
    link_state: result_link.AudioVideoLinkStateV1,
};

const TestRuntime = struct {
    slots: [12]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 12,
    roots: [12]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 12,
    nodes: [24]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 24,
};

fn referenceWindowV1(
    generation: u64,
    previous_end_tick: u64,
    frame_ordinals: []const u64,
    presentation_ticks: []const u64,
    duration_ticks: []const u64,
    previous_window_sha256: Digest,
) !video_model.FrameWindowV1 {
    return video_model.makeFrameWindowV1(
        531,
        generation,
        generation,
        .{ .numerator = 1, .denominator = 1_000 },
        previous_end_tick,
        frame_ordinals,
        presentation_ticks,
        duration_ticks,
        &[_]u64{ 1, 0 },
        model.sha256("continued VFR video media"),
        model.sha256("continued VFR processor bundle"),
        model.sha256("continued VFR cache bundle"),
        model.sha256("continued VFR ownership"),
        model.sha256(switch (generation) {
            1 => &video_model.reference_first_features,
            2 => &video_model.reference_second_features,
            else => "unsupported continued VFR generation",
        }),
        previous_window_sha256,
        model.sha256("continued VFR challenge"),
    );
}

fn referenceOverlapV1(
    generation: u64,
    source_start: u64,
    publish_start: u64,
    publish_end: u64,
    previous_transcript_sha256: Digest,
) !audio.OverlapPlanV1 {
    var overlap: audio.OverlapPlanV1 = .{
        .request_epoch = 531,
        .generation = generation,
        .segment_index = generation,
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
        .feature_bins = 4,
        .feature_bytes = 8,
        .media_object_sha256 = model.sha256("continued VFR audio media"),
        .processor_state_sha256 = model.sha256("continued VFR audio processor"),
        .processor_bundle_sha256 = model.sha256("continued VFR audio processor bundle"),
        .cache_bundle_sha256 = model.sha256("continued VFR audio cache bundle"),
        .cache_payload_sha256 = model.sha256("continued VFR audio feature cache"),
        .ownership_sha256 = model.sha256("continued VFR audio ownership"),
        .challenge_sha256 = model.sha256("continued VFR challenge"),
        .previous_transcript_sha256 = previous_transcript_sha256,
        .overlap_sha256 = [_]u8{0} ** 32,
    };
    overlap.overlap_sha256 =
        audio.overlapPlanRootV1(overlap);
    try audio.validateOverlapPlanV1(overlap);
    return overlap;
}

pub fn makeReferenceSourceV1() !ReferenceSourceFixtureV1 {
    const source_bank_epoch: u64 = 111_001;
    const restore_bank_epoch: u64 = 112_001;
    const previous_window = try referenceWindowV1(
        1,
        0,
        &[_]u64{ 0, 1 },
        &[_]u64{ 0, 8 },
        &[_]u64{ 8, 12 },
        model.sha256("continued VFR window genesis"),
    );
    const next_window = try referenceWindowV1(
        2,
        20,
        &[_]u64{ 2, 3 },
        &[_]u64{ 25, 35 },
        &[_]u64{ 10, 15 },
        previous_window.window_sha256,
    );
    var fixture =
        try video_model.makeReferenceFixtureV1(
            previous_window,
            2,
        );
    var source_storage: TestRuntime = .{};
    var source_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &source_storage.slots,
            &source_storage.roots,
            &source_storage.nodes,
            .{},
            source_bank_epoch,
        );
    var context: video_model.ReferenceContextV1 = .{
        .frame_window = previous_window,
        .previous_segment_sha256 = model.sha256("continued VFR segment genesis"),
    };
    const adapter =
        try video_model.referenceAdapterV1(
            fixture.manifest,
            &context,
        );
    var session: video_model.Session = .{};
    try session.initV1(
        &source_bank,
        111_101,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        adapter,
        previous_window,
    );
    var candidate_output: [video_model.reference_output_bytes]u8 =
        undefined;
    var candidate_state: [video_model.reference_state_bytes]u8 =
        undefined;
    var visible_output =
        [_]u8{0} **
        video_model.reference_output_bytes;
    var visible_state =
        [_]u8{0} **
        video_model.reference_state_bytes;
    _ = try session.prepareV1(
        previous_window,
        &video_model.reference_weights,
        &video_model.reference_first_features,
        &fixture.state_wire,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const first_result = try session.commitV1();
    const previous_segment =
        try video_segment.decodeVideoSegmentV1(
            &visible_output,
        );
    const timeline =
        try video_timeline.initializeTimelineV1(
            previous_segment,
            model.sha256("continued VFR timeline genesis"),
        );
    const previous_overlap = try referenceOverlapV1(
        1,
        0,
        2,
        27,
        model.sha256("continued VFR transcript genesis"),
    );
    const previous_transcript =
        try audio.makeTranscriptSegmentV1(
            previous_overlap,
            "alpha",
        );
    const next_overlap = try referenceOverlapV1(
        2,
        25,
        27,
        48,
        previous_transcript.transcript_sha256,
    );
    const next_transcript =
        try audio.makeTranscriptSegmentV1(
            next_overlap,
            "beta",
        );
    var link_state =
        try result_link.initializeLinkStateV1(
            531,
            previous_overlap.media_object_sha256,
            previous_window.media_object_sha256,
            previous_window.challenge_sha256,
            model.sha256("continued VFR link genesis"),
        );
    const previous_link =
        try result_link.makeResultLinkV1(
            link_state,
            previous_overlap,
            previous_transcript,
            timeline,
        );
    link_state = try result_link.applyResultLinkV1(
        link_state,
        previous_overlap,
        previous_transcript,
        timeline,
        previous_link,
    );
    const stateful_checkpoint =
        try model_continuation.makeCheckpointV1(
            source_bank_epoch,
            .{
                .restore_bank_epoch = restore_bank_epoch,
                .restore_owner_key = 112_101,
                .restore_tree_key = 112_201,
                .restore_authority_key = 112_301,
                .tenant_key = 112_401,
                .scope_key = 112_501,
                .allocation_key = 112_601,
                .binding_key = 112_701,
            },
            fixture.model_publication,
            fixture.state_publication,
            first_result,
        );
    const checkpoint = try makeCheckpointV1(
        stateful_checkpoint,
        fixture.state_publication,
        previous_window,
        previous_segment,
        next_window,
        timeline,
        previous_overlap,
        previous_transcript,
        next_overlap,
        next_transcript,
        previous_link,
        link_state,
    );
    try session.closeAndRelease();
    if (!(try source_bank.snapshotV3()).used.isZero())
        return Error.InvalidState;
    return .{
        .manifest = fixture.manifest,
        .state_publication = fixture.state_publication,
        .stateful_checkpoint = stateful_checkpoint,
        .checkpoint = checkpoint,
        .state_payload = visible_state,
        .previous_window = previous_window,
        .previous_segment = previous_segment,
        .next_window = next_window,
        .timeline = timeline,
        .previous_overlap = previous_overlap,
        .previous_transcript = previous_transcript,
        .next_overlap = next_overlap,
        .next_transcript = next_transcript,
        .previous_link = previous_link,
        .link_state = link_state,
    };
}

test "video continuation checkpoint rejects every mutation" {
    const source = try makeReferenceSourceV1();
    var expected_previous_window: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_previous_window,
        "675be9c8d94b3ec30fbe0f7a667449934e7cfe5c9b9a0a8ef8dedba291cef3b7",
    );
    try std.testing.expectEqual(
        expected_previous_window,
        source.previous_window.window_sha256,
    );
    var expected_next_window: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_next_window,
        "126d9db409e7d4bf7d81b3c2f2cfec7112e326be6a4691c563e8d5207f4928b4",
    );
    try std.testing.expectEqual(
        expected_next_window,
        source.next_window.window_sha256,
    );
    var expected_stateful_checkpoint: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_stateful_checkpoint,
        "9640bc8247bf6776afd5d62a3df728f9afaf806bfb7a58b22930f9967fb8a38a",
    );
    try std.testing.expectEqual(
        expected_stateful_checkpoint,
        source.stateful_checkpoint.checkpoint_sha256,
    );
    var expected_checkpoint: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_checkpoint,
        "cfe9828b0e030d6683e0bc14c093e79dd497411021f800243619c645f9dfc8f9",
    );
    try std.testing.expectEqual(
        expected_checkpoint,
        source.checkpoint.checkpoint_sha256,
    );
    var wire: [checkpoint_bytes]u8 = undefined;
    _ = try encodeCheckpointV1(
        source.checkpoint,
        &wire,
    );
    try std.testing.expectEqual(
        source.checkpoint,
        try decodeCheckpointV1(&wire),
    );
    for (0..wire.len) |index| {
        var mutated = wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidCheckpoint,
            decodeCheckpointV1(&mutated),
        );
    }
}

test "fresh Bank restores VFR video and advances timeline and link" {
    const source = try makeReferenceSourceV1();
    var checkpoint_wire: [checkpoint_bytes]u8 =
        undefined;
    _ = try encodeCheckpointV1(
        source.checkpoint,
        &checkpoint_wire,
    );
    var stateful_checkpoint_wire: [model_continuation.checkpoint_bytes]u8 =
        undefined;
    _ = try model_continuation.encodeCheckpointV1(
        source.stateful_checkpoint,
        &stateful_checkpoint_wire,
    );
    var state_publication_wire: [stateful.state_publication_bytes]u8 =
        undefined;
    _ = try stateful.encodeStatePublicationV1(
        source.state_publication,
        &state_publication_wire,
    );
    var previous_window_wire: [video_model.frame_window_bytes]u8 =
        undefined;
    _ = try video_model.encodeFrameWindowV1(
        source.previous_window,
        &previous_window_wire,
    );
    var previous_segment_wire: [video_segment.video_segment_bytes]u8 =
        undefined;
    _ = try video_segment.encodeVideoSegmentV1(
        source.previous_segment,
        &previous_segment_wire,
    );
    var next_window_wire: [video_model.frame_window_bytes]u8 =
        undefined;
    _ = try video_model.encodeFrameWindowV1(
        source.next_window,
        &next_window_wire,
    );
    var timeline_wire: [video_timeline.timeline_bytes]u8 =
        undefined;
    _ = try video_timeline.encodeTimelineV1(
        source.timeline,
        &timeline_wire,
    );
    var previous_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try audio.encodeOverlapPlanV1(
        source.previous_overlap,
        &previous_overlap_wire,
    );
    var previous_transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try audio.encodeTranscriptSegmentV1(
        source.previous_transcript,
        &previous_transcript_wire,
    );
    var next_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try audio.encodeOverlapPlanV1(
        source.next_overlap,
        &next_overlap_wire,
    );
    var next_transcript_wire: [audio.transcript_segment_bytes]u8 =
        undefined;
    _ = try audio.encodeTranscriptSegmentV1(
        source.next_transcript,
        &next_transcript_wire,
    );
    var previous_link_wire: [result_link.result_link_bytes]u8 =
        undefined;
    _ = try result_link.encodeResultLinkV1(
        source.previous_link,
        &previous_link_wire,
    );
    var link_state_wire: [result_link.link_state_bytes]u8 =
        undefined;
    _ = try result_link.encodeLinkStateV1(
        source.link_state,
        &link_state_wire,
    );
    var target_storage: TestRuntime = .{};
    var target_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &target_storage.slots,
            &target_storage.roots,
            &target_storage.nodes,
            .{},
            source.checkpoint.restore_bank_epoch,
        );
    var resumed: ResumeSession = .{};
    try resumed.prepareV1(
        &target_bank,
        &checkpoint_wire,
        &stateful_checkpoint_wire,
        &state_publication_wire,
        &previous_window_wire,
        &previous_segment_wire,
        &next_window_wire,
        &timeline_wire,
        &previous_overlap_wire,
        &previous_transcript_wire,
        &next_overlap_wire,
        &next_transcript_wire,
        &previous_link_wire,
        &link_state_wire,
    );
    const reserved = try target_bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 1),
        reserved.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        reserved.live_allocations,
    );
    var restored_state: [video_model.reference_state_bytes]u8 =
        undefined;
    try resumed.commitMaterializedV1(
        &source.state_payload,
        &restored_state,
    );
    const second_plan =
        try video_model.makeReferencePlanV1(
            source.manifest,
            resumed.inner.model_publication,
            resumed.inner.state_publication,
            resumed.next_window,
            resumed.inner.checkpoint.last_plan_sha256,
        );
    var context: video_model.ReferenceContextV1 = .{
        .frame_window = resumed.next_window,
        .previous_segment_sha256 = resumed.previous_segment.segment_sha256,
    };
    const adapter =
        try video_model.referenceAdapterV1(
            source.manifest,
            &context,
        );
    var terminal: video_model.Session = .{};
    try terminal.initV1(
        &target_bank,
        113_001,
        &resumed.inner.model_publication,
        &resumed.inner.state_publication,
        source.manifest,
        second_plan,
        adapter,
        resumed.next_window,
    );
    var candidate_output: [video_model.reference_output_bytes]u8 =
        undefined;
    var candidate_state: [video_model.reference_state_bytes]u8 =
        undefined;
    var visible_output =
        [_]u8{0} **
        video_model.reference_output_bytes;
    var visible_state =
        [_]u8{0} **
        video_model.reference_state_bytes;
    _ = try terminal.prepareV1(
        resumed.next_window,
        &video_model.reference_weights,
        &video_model.reference_second_features,
        &restored_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const terminal_result = try terminal.commitV1();
    const next_segment =
        try video_segment.decodeVideoSegmentV1(
            &visible_output,
        );
    try std.testing.expectEqual(
        resumed.previous_segment.segment_sha256,
        next_segment.previous_segment_sha256,
    );
    try std.testing.expectEqual(
        model.sha256(&visible_output),
        terminal_result.output_sha256,
    );
    var timeline_session: video_timeline.Session = .{};
    try timeline_session.initV1(
        &target_bank,
        113_101,
        &resumed.timeline,
    );
    var timeline_candidate: [video_timeline.merge_receipt_bytes]u8 =
        undefined;
    var timeline_output =
        [_]u8{0} **
        video_timeline.merge_receipt_bytes;
    _ = try timeline_session.prepareV1(
        resumed.previous_segment,
        next_segment,
        &timeline_candidate,
        &timeline_output,
    );
    const merge_receipt =
        try timeline_session.commitV1();
    try std.testing.expectEqual(
        video_timeline.MergeActionV1.retain_distinct,
        merge_receipt.action,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        resumed.timeline.visible_segments,
    );
    try std.testing.expectEqual(
        @as(u64, 25),
        resumed.timeline.tail_start_tick,
    );
    var link_session: result_link.Session = .{};
    try link_session.initV1(
        &target_bank,
        113_201,
        &resumed.link_state,
    );
    var link_candidate: [result_link.result_link_bytes]u8 =
        undefined;
    var link_output =
        [_]u8{0} ** result_link.result_link_bytes;
    _ = try link_session.prepareV1(
        resumed.next_overlap,
        resumed.next_transcript,
        resumed.timeline,
        &link_candidate,
        &link_output,
    );
    const next_link = try link_session.commitV1();
    try std.testing.expectEqual(
        source.previous_link.link_sha256,
        next_link.previous_link_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        resumed.link_state.visible_links,
    );
    const next_state =
        try video_model.decodeReferenceStateV1(
            &visible_state,
        );
    try std.testing.expectEqual(
        @as(u64, 4),
        next_state.next_frame_ordinal,
    );
    try std.testing.expectEqual(
        @as(u64, 50),
        next_state.last_end_tick,
    );
    try link_session.closeAndRelease();
    try timeline_session.closeAndRelease();
    try terminal.closeAndRelease();
    try resumed.closeAndRelease();
    const final = try target_bank.snapshotV3();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(
        @as(u64, 0),
        final.live_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        final.active_lease_trees,
    );
}

test "rehashed hidden VFR discontinuity rejects before admission" {
    const source = try makeReferenceSourceV1();
    var foreign = source.next_window;
    foreign.presentation_ticks[0] = 24;
    foreign.presentation_ticks[1] = 34;
    foreign.duration_ticks[1] = 16;
    foreign.start_tick = 24;
    foreign.discontinuity_before_ticks = 4;
    foreign.timestamp_payload_sha256 =
        video_model.timestampPayloadRootV1(foreign);
    foreign.window_sha256 =
        video_model.frameWindowRootV1(foreign);
    try video_model.validateFrameWindowV1(foreign);
    var target_storage: TestRuntime = .{};
    var target_bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &target_storage.slots,
            &target_storage.roots,
            &target_storage.nodes,
            .{},
            source.checkpoint.restore_bank_epoch,
        );
    try std.testing.expectError(
        Error.InvalidBinding,
        validateCheckpointBindingsV1(
            source.checkpoint,
            source.stateful_checkpoint,
            source.state_publication,
            source.previous_window,
            source.previous_segment,
            foreign,
            source.timeline,
            source.previous_overlap,
            source.previous_transcript,
            source.next_overlap,
            source.next_transcript,
            source.previous_link,
            source.link_state,
        ),
    );
    try std.testing.expect(
        (try target_bank.snapshotV3()).used.isZero(),
    );
}
