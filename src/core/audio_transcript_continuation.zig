const std = @import("std");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const stateful = @import("stateful_model_adapter.zig");
const model_continuation =
    @import("stateful_model_continuation.zig");
const transcript_model =
    @import("stateful_transcript_adapter.zig");
const audio = @import("audio_transcript_adapter.zig");
const video_segment = @import("video_segment_adapter.zig");
const video_timeline = @import("video_segment_timeline.zig");
const result_link = @import("audio_video_result_link.zig");

const Digest = [32]u8;

pub const checkpoint_abi: u64 = 0x4154_4350_5400_0001;
pub const checkpoint_bytes: usize = 576;
const checkpoint_body_bytes = checkpoint_bytes - 32;
const allowed_flags: u64 = 0;
const checkpoint_magic =
    [_]u8{ 'G', 'A', 'T', 'C', 'P', '1', 0, 0 };
const checkpoint_domain =
    "glacier-audio-transcript-continuation-v1\x00";

pub const Error = model.Error || resource_bank.Error ||
    stateful.Error || model_continuation.Error ||
    transcript_model.Error || audio.Error ||
    video_timeline.Error || result_link.Error || error{
    InvalidCheckpoint,
    InvalidBinding,
    InvalidState,
};

pub const CheckpointV1 = struct {
    request_epoch: u64,
    completed_generation: u64,
    next_generation: u64,
    next_segment_index: u64,
    next_source_start_sample: u64,
    next_publish_start_sample: u64,
    next_publish_end_sample: u64,
    sample_rate: u64,
    state_bytes: u64,
    source_bank_epoch: u64,
    restore_bank_epoch: u64,
    model_publication_next_sequence: u64,
    link_next_sequence: u64,
    visible_links: u64,
    stateful_checkpoint_sha256: Digest,
    state_publication_sha256: Digest,
    restored_state_sha256: Digest,
    previous_overlap_sha256: Digest,
    previous_transcript_sha256: Digest,
    next_overlap_sha256: Digest,
    audio_media_sha256: Digest,
    video_media_sha256: Digest,
    video_timeline_sha256: Digest,
    link_state_sha256: Digest,
    previous_link_sha256: Digest,
    challenge_sha256: Digest,
    checkpoint_sha256: Digest,
};

pub const ResumeSession = struct {
    inner: model_continuation.ResumeSession = .{},
    checkpoint: CheckpointV1 = undefined,
    previous_overlap: audio.OverlapPlanV1 = undefined,
    previous_transcript: audio.TranscriptSegmentV1 = undefined,
    previous_link: result_link.AudioVideoResultLinkV1 = undefined,
    next_overlap: audio.OverlapPlanV1 = undefined,
    timeline: video_timeline.VideoSegmentTimelineV1 = undefined,
    link_state: result_link.AudioVideoLinkStateV1 = undefined,
    initialized: bool = false,

    pub fn prepareV1(
        self: *ResumeSession,
        bank: *resource_bank.Bank,
        checkpoint_wire: []const u8,
        stateful_checkpoint_wire: []const u8,
        state_publication_wire: []const u8,
        previous_overlap_wire: []const u8,
        previous_transcript_wire: []const u8,
        previous_link_wire: []const u8,
        next_overlap_wire: []const u8,
        timeline_wire: []const u8,
        link_state_wire: []const u8,
    ) Error!void {
        if (self.initialized or
            self.inner.phase != .idle)
            return Error.InvalidState;
        const checkpoint = try decodeCheckpointV1(
            checkpoint_wire,
        );
        const stateful_checkpoint =
            try model_continuation.decodeCheckpointV1(
                stateful_checkpoint_wire,
            );
        const state_publication =
            try stateful.decodeStatePublicationV1(
                state_publication_wire,
            );
        const previous_overlap =
            try audio.decodeOverlapPlanV1(
                previous_overlap_wire,
            );
        const previous_transcript =
            try audio.decodeTranscriptSegmentV1(
                previous_transcript_wire,
            );
        const previous_link =
            try result_link.decodeResultLinkV1(
                previous_link_wire,
            );
        const next_overlap =
            try audio.decodeOverlapPlanV1(
                next_overlap_wire,
            );
        const timeline =
            try video_timeline.decodeTimelineV1(
                timeline_wire,
            );
        const link_state =
            try result_link.decodeLinkStateV1(
                link_state_wire,
            );
        try validateCheckpointBindingsV1(
            checkpoint,
            stateful_checkpoint,
            state_publication,
            previous_overlap,
            previous_transcript,
            previous_link,
            next_overlap,
            timeline,
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
            .previous_overlap = previous_overlap,
            .previous_transcript = previous_transcript,
            .previous_link = previous_link,
            .next_overlap = next_overlap,
            .timeline = timeline,
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
    previous_overlap: audio.OverlapPlanV1,
    previous_transcript: audio.TranscriptSegmentV1,
    previous_link: result_link.AudioVideoResultLinkV1,
    next_overlap: audio.OverlapPlanV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
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
        .next_segment_index = next_overlap.segment_index,
        .next_source_start_sample = next_overlap.source_start_sample,
        .next_publish_start_sample = next_overlap.publish_start_sample,
        .next_publish_end_sample = next_overlap.publish_end_sample,
        .sample_rate = next_overlap.sample_rate,
        .state_bytes = stateful_checkpoint.state_bytes,
        .source_bank_epoch = stateful_checkpoint.source_bank_epoch,
        .restore_bank_epoch = stateful_checkpoint.restore_bank_epoch,
        .model_publication_next_sequence = stateful_checkpoint.publication_next_sequence,
        .link_next_sequence = link_state.next_sequence,
        .visible_links = link_state.visible_links,
        .stateful_checkpoint_sha256 = stateful_checkpoint.checkpoint_sha256,
        .state_publication_sha256 = state_publication.publication_sha256,
        .restored_state_sha256 = state_publication.current_state_sha256,
        .previous_overlap_sha256 = previous_overlap.overlap_sha256,
        .previous_transcript_sha256 = previous_transcript.transcript_sha256,
        .next_overlap_sha256 = next_overlap.overlap_sha256,
        .audio_media_sha256 = next_overlap.media_object_sha256,
        .video_media_sha256 = timeline.media_object_sha256,
        .video_timeline_sha256 = timeline.timeline_sha256,
        .link_state_sha256 = link_state.state_sha256,
        .previous_link_sha256 = link_state.previous_link_sha256,
        .challenge_sha256 = stateful_checkpoint.challenge_sha256,
        .checkpoint_sha256 = [_]u8{0} ** 32,
    };
    checkpoint.checkpoint_sha256 =
        checkpointRootV1(checkpoint);
    try validateCheckpointBindingsV1(
        checkpoint,
        stateful_checkpoint,
        state_publication,
        previous_overlap,
        previous_transcript,
        previous_link,
        next_overlap,
        timeline,
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
        checkpoint.next_source_start_sample >=
            checkpoint.next_publish_start_sample or
        checkpoint.next_publish_start_sample >=
            checkpoint.next_publish_end_sample or
        checkpoint.sample_rate == 0 or
        checkpoint.state_bytes == 0 or
        checkpoint.source_bank_epoch == 0 or
        checkpoint.restore_bank_epoch == 0 or
        checkpoint.source_bank_epoch ==
            checkpoint.restore_bank_epoch or
        checkpoint.model_publication_next_sequence !=
            checkpoint.completed_generation or
        checkpoint.link_next_sequence !=
            checkpoint.visible_links or
        checkpoint.visible_links == 0 or
        isZero(checkpoint.stateful_checkpoint_sha256) or
        isZero(checkpoint.state_publication_sha256) or
        isZero(checkpoint.restored_state_sha256) or
        isZero(checkpoint.previous_overlap_sha256) or
        isZero(checkpoint.previous_transcript_sha256) or
        isZero(checkpoint.next_overlap_sha256) or
        isZero(checkpoint.audio_media_sha256) or
        isZero(checkpoint.video_media_sha256) or
        isZero(checkpoint.video_timeline_sha256) or
        isZero(checkpoint.link_state_sha256) or
        isZero(checkpoint.previous_link_sha256) or
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
    previous_overlap: audio.OverlapPlanV1,
    previous_transcript: audio.TranscriptSegmentV1,
    previous_link: result_link.AudioVideoResultLinkV1,
    next_overlap: audio.OverlapPlanV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    link_state: result_link.AudioVideoLinkStateV1,
) Error!void {
    try validateCheckpointV1(checkpoint);
    try model_continuation.validateCheckpointV1(
        stateful_checkpoint,
    );
    try stateful.validateStatePublicationV1(
        state_publication,
    );
    try audio.validateOverlapPlanV1(previous_overlap);
    try audio.validateTranscriptSegmentV1(
        previous_transcript,
    );
    try result_link.validateResultLinkV1(
        previous_link,
    );
    try audio.validateOverlapPlanV1(next_overlap);
    try audio.validateTranscriptPredecessorV1(
        next_overlap,
        previous_transcript,
    );
    try video_timeline.validateTimelineV1(timeline);
    try result_link.validateLinkStateV1(link_state);
    const expected_next_segment = std.math.add(
        u64,
        previous_overlap.segment_index,
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
    if (!transcriptMatchesOverlapV1(
        previous_transcript,
        previous_overlap,
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
            previous_overlap.request_epoch or
        checkpoint.request_epoch !=
            previous_link.request_epoch or
        checkpoint.request_epoch !=
            next_overlap.request_epoch or
        checkpoint.request_epoch !=
            timeline.request_epoch or
        checkpoint.request_epoch !=
            link_state.request_epoch or
        checkpoint.completed_generation !=
            stateful_checkpoint.current_step or
        checkpoint.completed_generation !=
            previous_overlap.generation or
        checkpoint.next_generation !=
            next_overlap.generation or
        checkpoint.next_segment_index !=
            expected_next_segment or
        checkpoint.next_segment_index !=
            next_overlap.segment_index or
        previous_overlap.publish_end_sample !=
            next_overlap.publish_start_sample or
        checkpoint.next_source_start_sample !=
            next_overlap.source_start_sample or
        checkpoint.next_publish_start_sample !=
            next_overlap.publish_start_sample or
        checkpoint.next_publish_end_sample !=
            next_overlap.publish_end_sample or
        checkpoint.sample_rate !=
            previous_overlap.sample_rate or
        checkpoint.sample_rate !=
            next_overlap.sample_rate or
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
        checkpoint.link_next_sequence !=
            link_state.next_sequence or
        checkpoint.link_next_sequence !=
            expected_next_link or
        checkpoint.visible_links !=
            link_state.visible_links or
        checkpoint.visible_links !=
            previous_link.link_index or
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
            &stateful_checkpoint.last_output_sha256,
            &model.sha256(&previous_transcript.text),
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.next_overlap_sha256,
            &next_overlap.overlap_sha256,
        ) or
        !std.mem.eql(
            u8,
            &next_overlap.previous_transcript_sha256,
            &previous_transcript.transcript_sha256,
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
            &timeline.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.video_media_sha256,
            &link_state.video_media_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.video_timeline_sha256,
            &timeline.timeline_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.link_state_sha256,
            &link_state.state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_link_sha256,
            &link_state.previous_link_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.previous_link_sha256,
            &previous_link.link_sha256,
        ) or
        !std.mem.eql(
            u8,
            &previous_link.audio_overlap_sha256,
            &previous_overlap.overlap_sha256,
        ) or
        !std.mem.eql(
            u8,
            &previous_link.transcript_sha256,
            &previous_transcript.transcript_sha256,
        ) or
        !std.mem.eql(
            u8,
            &previous_link.video_timeline_sha256,
            &timeline.timeline_sha256,
        ) or
        !std.mem.eql(
            u8,
            &previous_link.audio_media_sha256,
            &checkpoint.audio_media_sha256,
        ) or
        !std.mem.eql(
            u8,
            &previous_link.video_media_sha256,
            &checkpoint.video_media_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.challenge_sha256,
            &stateful_checkpoint.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.challenge_sha256,
            &state_publication.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.challenge_sha256,
            &previous_overlap.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.challenge_sha256,
            &next_overlap.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.challenge_sha256,
            &timeline.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &checkpoint.challenge_sha256,
            &link_state.challenge_sha256,
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
        !std.mem.allEqual(u8, encoded[144..160], 0))
        return Error.InvalidCheckpoint;
    const checkpoint: CheckpointV1 = .{
        .request_epoch = readU64(encoded, 32),
        .completed_generation = readU64(encoded, 40),
        .next_generation = readU64(encoded, 48),
        .next_segment_index = readU64(encoded, 56),
        .next_source_start_sample = readU64(encoded, 64),
        .next_publish_start_sample = readU64(encoded, 72),
        .next_publish_end_sample = readU64(encoded, 80),
        .sample_rate = readU64(encoded, 88),
        .state_bytes = readU64(encoded, 96),
        .source_bank_epoch = readU64(encoded, 104),
        .restore_bank_epoch = readU64(encoded, 112),
        .model_publication_next_sequence = readU64(encoded, 120),
        .link_next_sequence = readU64(encoded, 128),
        .visible_links = readU64(encoded, 136),
        .stateful_checkpoint_sha256 = encoded[160..192].*,
        .state_publication_sha256 = encoded[192..224].*,
        .restored_state_sha256 = encoded[224..256].*,
        .previous_overlap_sha256 = encoded[256..288].*,
        .previous_transcript_sha256 = encoded[288..320].*,
        .next_overlap_sha256 = encoded[320..352].*,
        .audio_media_sha256 = encoded[352..384].*,
        .video_media_sha256 = encoded[384..416].*,
        .video_timeline_sha256 = encoded[416..448].*,
        .link_state_sha256 = encoded[448..480].*,
        .previous_link_sha256 = encoded[480..512].*,
        .challenge_sha256 = encoded[512..544].*,
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
    var body: [checkpoint_body_bytes]u8 = undefined;
    writeCheckpointBodyV1(checkpoint, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(checkpoint_domain);
    hash.update(&body);
    return hash.finalResult();
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

fn writeCheckpointBodyV1(
    checkpoint: CheckpointV1,
    output: []u8,
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
        checkpoint.next_source_start_sample,
        checkpoint.next_publish_start_sample,
        checkpoint.next_publish_end_sample,
        checkpoint.sample_rate,
        checkpoint.state_bytes,
        checkpoint.source_bank_epoch,
        checkpoint.restore_bank_epoch,
        checkpoint.model_publication_next_sequence,
        checkpoint.link_next_sequence,
        checkpoint.visible_links,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        checkpoint.stateful_checkpoint_sha256,
        checkpoint.state_publication_sha256,
        checkpoint.restored_state_sha256,
        checkpoint.previous_overlap_sha256,
        checkpoint.previous_transcript_sha256,
        checkpoint.next_overlap_sha256,
        checkpoint.audio_media_sha256,
        checkpoint.video_media_sha256,
        checkpoint.video_timeline_sha256,
        checkpoint.link_state_sha256,
        checkpoint.previous_link_sha256,
        checkpoint.challenge_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 160 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

pub const ReferenceSourceFixtureV1 = struct {
    manifest: model.ArtifactManifestV1,
    state_publication: stateful.StatePublicationV1,
    stateful_checkpoint: model_continuation.CheckpointV1,
    checkpoint: CheckpointV1,
    state_payload: [transcript_model.reference_state_bytes]u8,
    previous_overlap: audio.OverlapPlanV1,
    previous_transcript: audio.TranscriptSegmentV1,
    previous_link: result_link.AudioVideoResultLinkV1,
    next_overlap: audio.OverlapPlanV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    link_state: result_link.AudioVideoLinkStateV1,
};

const TestRuntime = struct {
    slots: [8]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [16]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 16,
};

fn testOverlap(
    generation: u64,
    segment_index: u64,
    source_start: u64,
    publish_start: u64,
    publish_end: u64,
    previous_transcript: Digest,
    challenge: Digest,
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
        .feature_bins = transcript_model.reference_input_features,
        .feature_bytes = transcript_model.reference_first_features.len,
        .media_object_sha256 = model.sha256("continued transcript audio"),
        .processor_state_sha256 = model.sha256("continued transcript processor"),
        .processor_bundle_sha256 = model.sha256("continued transcript processor bundle"),
        .cache_bundle_sha256 = model.sha256("continued transcript cache bundle"),
        .cache_payload_sha256 = model.sha256("continued transcript feature cache"),
        .ownership_sha256 = model.sha256("continued transcript ownership"),
        .challenge_sha256 = challenge,
        .previous_transcript_sha256 = previous_transcript,
        .overlap_sha256 = [_]u8{0} ** 32,
    };
    overlap.overlap_sha256 =
        audio.overlapPlanRootV1(overlap);
    try audio.validateOverlapPlanV1(overlap);
    return overlap;
}

fn testTimeline(
    challenge: Digest,
) !video_timeline.VideoSegmentTimelineV1 {
    var segment: video_segment.VideoSegmentV1 = .{
        .request_epoch = 431,
        .generation = 1,
        .segment_index = 1,
        .first_frame = 0,
        .last_frame = 19,
        .frame_count = 20,
        .frame_stride = 1,
        .keyframe_ordinal = 0,
        .eviction_boundary = 0,
        .cache_generation = 1,
        .target_base = .{
            .numerator = 1,
            .denominator = 1_000,
        },
        .target_start_tick = 0,
        .target_end_tick = 20,
        .event_id = 7,
        .confidence_ppm = 900_000,
        .media_object_sha256 = model.sha256("continued transcript video"),
        .processor_state_sha256 = model.sha256("continued video processor"),
        .processor_bundle_sha256 = model.sha256("continued video processor bundle"),
        .cache_bundle_sha256 = model.sha256("continued video cache bundle"),
        .cache_payload_sha256 = model.sha256("continued video cache payload"),
        .ownership_sha256 = model.sha256("continued video ownership"),
        .selection_sha256 = model.sha256("continued video selection"),
        .challenge_sha256 = challenge,
        .previous_segment_sha256 = model.sha256("continued video genesis"),
        .segment_sha256 = [_]u8{0} ** 32,
    };
    segment.segment_sha256 =
        video_segment.videoSegmentRootV1(segment);
    try video_segment.validateVideoSegmentV1(segment);
    return video_timeline.initializeTimelineV1(
        segment,
        model.sha256("continued timeline genesis"),
    );
}

pub fn makeReferenceSourceV1() !ReferenceSourceFixtureV1 {
    const source_bank_epoch: u64 = 101_001;
    const restore_bank_epoch: u64 = 102_001;
    const challenge = model.sha256(
        "continued transcript challenge",
    );
    const first_overlap = try testOverlap(
        1,
        1,
        0,
        2,
        10,
        model.sha256("continued transcript genesis"),
        challenge,
    );
    var fixture =
        try transcript_model.makeReferenceFixtureV1(
            first_overlap,
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
    var context: transcript_model.ReferenceContextV1 =
        .{
            .overlap_plan = first_overlap,
            .text_bytes = 3,
        };
    const adapter =
        try transcript_model.referenceAdapterV1(
            fixture.manifest,
            &context,
        );
    var session: transcript_model.Session = .{};
    try session.initV1(
        &source_bank,
        101_101,
        &fixture.model_publication,
        &fixture.state_publication,
        fixture.manifest,
        fixture.plan,
        adapter,
        first_overlap,
    );
    var candidate_output: [transcript_model.reference_output_bytes]u8 =
        undefined;
    var candidate_state: [transcript_model.reference_state_bytes]u8 =
        undefined;
    var visible_output =
        [_]u8{0} **
        transcript_model.reference_output_bytes;
    var visible_state =
        [_]u8{0} **
        transcript_model.reference_state_bytes;
    _ = try session.prepareV1(
        first_overlap,
        &transcript_model.reference_weights,
        &transcript_model.reference_first_features,
        &fixture.state_wire,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    const first_result = try session.commitV1();
    const previous_transcript =
        try audio.makeTranscriptSegmentV1(
            first_overlap,
            visible_output[0..3],
        );
    const next_overlap = try testOverlap(
        2,
        2,
        8,
        10,
        18,
        previous_transcript.transcript_sha256,
        challenge,
    );
    const timeline = try testTimeline(challenge);
    var link_state =
        try result_link.initializeLinkStateV1(
            431,
            first_overlap.media_object_sha256,
            timeline.media_object_sha256,
            challenge,
            model.sha256("continued link genesis"),
        );
    const first_link = try result_link.makeResultLinkV1(
        link_state,
        first_overlap,
        previous_transcript,
        timeline,
    );
    link_state = try result_link.applyResultLinkV1(
        link_state,
        first_overlap,
        previous_transcript,
        timeline,
        first_link,
    );
    const stateful_checkpoint =
        try model_continuation.makeCheckpointV1(
            source_bank_epoch,
            .{
                .restore_bank_epoch = restore_bank_epoch,
                .restore_owner_key = 102_101,
                .restore_tree_key = 102_201,
                .restore_authority_key = 102_301,
                .tenant_key = 102_401,
                .scope_key = 102_501,
                .allocation_key = 102_601,
                .binding_key = 102_701,
            },
            fixture.model_publication,
            fixture.state_publication,
            first_result,
        );
    const checkpoint = try makeCheckpointV1(
        stateful_checkpoint,
        fixture.state_publication,
        first_overlap,
        previous_transcript,
        first_link,
        next_overlap,
        timeline,
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
        .previous_overlap = first_overlap,
        .previous_transcript = previous_transcript,
        .previous_link = first_link,
        .next_overlap = next_overlap,
        .timeline = timeline,
        .link_state = link_state,
    };
}

test "audio transcript checkpoint wire rejects every mutation" {
    const source = try makeReferenceSourceV1();
    var expected_stateful_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_stateful_root,
        "dfb92dd4895a10a91c9de6c7cbe48e4ce47da5b5fce154fec23b2acd8d500d75",
    );
    try std.testing.expectEqual(
        expected_stateful_root,
        source.stateful_checkpoint.checkpoint_sha256,
    );
    var expected_checkpoint_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_checkpoint_root,
        "7c70fd73db93752fad108aab54894402617a864ba0ec7032d044a69fa7538816",
    );
    try std.testing.expectEqual(
        expected_checkpoint_root,
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

test "fresh Bank restores transcript state and links next segment" {
    const source = try makeReferenceSourceV1();
    var checkpoint_wire: [checkpoint_bytes]u8 = undefined;
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
    var previous_link_wire: [result_link.result_link_bytes]u8 =
        undefined;
    _ = try result_link.encodeResultLinkV1(
        source.previous_link,
        &previous_link_wire,
    );
    var next_overlap_wire: [audio.overlap_plan_bytes]u8 = undefined;
    _ = try audio.encodeOverlapPlanV1(
        source.next_overlap,
        &next_overlap_wire,
    );
    var timeline_wire: [video_timeline.timeline_bytes]u8 = undefined;
    _ = try video_timeline.encodeTimelineV1(
        source.timeline,
        &timeline_wire,
    );
    var link_state_wire: [result_link.link_state_bytes]u8 = undefined;
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
        &previous_overlap_wire,
        &previous_transcript_wire,
        &previous_link_wire,
        &next_overlap_wire,
        &timeline_wire,
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
    var restored_state: [transcript_model.reference_state_bytes]u8 =
        undefined;
    try resumed.commitMaterializedV1(
        &source.state_payload,
        &restored_state,
    );
    const active = try target_bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 1),
        active.live_allocations,
    );
    const second_plan =
        try transcript_model.makeReferencePlanV1(
            source.manifest,
            resumed.inner.model_publication,
            resumed.inner.state_publication,
            resumed.next_overlap,
            resumed.inner.checkpoint.last_plan_sha256,
        );
    var context: transcript_model.ReferenceContextV1 =
        .{
            .overlap_plan = resumed.next_overlap,
            .text_bytes = 4,
        };
    const adapter =
        try transcript_model.referenceAdapterV1(
            source.manifest,
            &context,
        );
    var terminal: transcript_model.Session = .{};
    try terminal.initV1(
        &target_bank,
        103_001,
        &resumed.inner.model_publication,
        &resumed.inner.state_publication,
        source.manifest,
        second_plan,
        adapter,
        resumed.next_overlap,
    );
    var candidate_output: [transcript_model.reference_output_bytes]u8 =
        undefined;
    var candidate_state: [transcript_model.reference_state_bytes]u8 =
        undefined;
    var visible_output =
        [_]u8{0} **
        transcript_model.reference_output_bytes;
    var visible_state =
        [_]u8{0} **
        transcript_model.reference_state_bytes;
    _ = try terminal.prepareV1(
        resumed.next_overlap,
        &transcript_model.reference_weights,
        &transcript_model.reference_second_features,
        &restored_state,
        &candidate_output,
        &candidate_state,
        &visible_output,
        &visible_state,
    );
    _ = try terminal.commitV1();
    try std.testing.expectEqualStrings(
        "berg",
        visible_output[0..4],
    );
    const next_transcript =
        try audio.makeTranscriptSegmentV1(
            resumed.next_overlap,
            visible_output[0..4],
        );
    try audio.validateTranscriptPredecessorV1(
        resumed.next_overlap,
        resumed.previous_transcript,
    );
    var link_session: result_link.Session = .{};
    try link_session.initV1(
        &target_bank,
        103_101,
        &resumed.link_state,
    );
    var link_candidate: [result_link.result_link_bytes]u8 =
        undefined;
    var link_output =
        [_]u8{0} ** result_link.result_link_bytes;
    _ = try link_session.prepareV1(
        resumed.next_overlap,
        next_transcript,
        resumed.timeline,
        &link_candidate,
        &link_output,
    );
    const next_link = try link_session.commitV1();
    try std.testing.expectEqual(
        @as(u64, 2),
        resumed.link_state.visible_links,
    );
    try std.testing.expectEqual(
        source.link_state.previous_link_sha256,
        next_link.previous_link_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        resumed.inner.state_publication.current_step,
    );
    try link_session.closeAndRelease();
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

test "foreign next overlap rejects before target admission" {
    const source = try makeReferenceSourceV1();
    var foreign = source.next_overlap;
    foreign.challenge_sha256 =
        model.sha256("foreign continuation challenge");
    foreign.overlap_sha256 =
        audio.overlapPlanRootV1(foreign);
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
            source.previous_overlap,
            source.previous_transcript,
            source.previous_link,
            foreign,
            source.timeline,
            source.link_state,
        ),
    );
    try std.testing.expect(
        (try target_bank.snapshotV3()).used.isZero(),
    );
}

test "rehashed output and result link substitutions reject semantic lineage" {
    const source = try makeReferenceSourceV1();

    var foreign_stateful = source.stateful_checkpoint;
    foreign_stateful.last_output_sha256 =
        model.sha256("substituted transcript output");
    foreign_stateful.checkpoint_sha256 =
        model_continuation.checkpointRootV1(
            foreign_stateful,
        );
    var foreign_output_checkpoint = source.checkpoint;
    foreign_output_checkpoint.stateful_checkpoint_sha256 =
        foreign_stateful.checkpoint_sha256;
    foreign_output_checkpoint.checkpoint_sha256 =
        checkpointRootV1(foreign_output_checkpoint);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateCheckpointBindingsV1(
            foreign_output_checkpoint,
            foreign_stateful,
            source.state_publication,
            source.previous_overlap,
            source.previous_transcript,
            source.previous_link,
            source.next_overlap,
            source.timeline,
            source.link_state,
        ),
    );

    var foreign_link = source.previous_link;
    foreign_link.transcript_sha256 =
        model.sha256("substituted linked transcript");
    foreign_link.link_sha256 =
        result_link.resultLinkRootV1(foreign_link);
    try result_link.validateResultLinkV1(foreign_link);
    var foreign_link_state = source.link_state;
    foreign_link_state.previous_link_sha256 =
        foreign_link.link_sha256;
    foreign_link_state.state_sha256 =
        result_link.linkStateRootV1(
            foreign_link_state,
        );
    var foreign_link_checkpoint = source.checkpoint;
    foreign_link_checkpoint.link_state_sha256 =
        foreign_link_state.state_sha256;
    foreign_link_checkpoint.previous_link_sha256 =
        foreign_link.link_sha256;
    foreign_link_checkpoint.checkpoint_sha256 =
        checkpointRootV1(foreign_link_checkpoint);
    try std.testing.expectError(
        Error.InvalidBinding,
        validateCheckpointBindingsV1(
            foreign_link_checkpoint,
            source.stateful_checkpoint,
            source.state_publication,
            source.previous_overlap,
            source.previous_transcript,
            foreign_link,
            source.next_overlap,
            source.timeline,
            foreign_link_state,
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
