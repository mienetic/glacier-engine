const std = @import("std");
const media = @import("media_contract.zig");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");
const audio = @import("audio_transcript_adapter.zig");
const video_segment = @import("video_segment_adapter.zig");
const video_timeline = @import("video_segment_timeline.zig");

const Digest = [32]u8;

pub const link_state_abi: u64 = 0x4741_564c_5300_0001;
pub const result_link_abi: u64 = 0x4741_564c_4b00_0001;
pub const link_state_bytes: usize = 320;
pub const result_link_bytes: usize = 576;
const link_state_body_bytes = link_state_bytes - 32;
const result_link_body_bytes = result_link_bytes - 32;
const allowed_flags: u64 = 0;
const link_state_magic = [_]u8{
    'G', 'A', 'V', 'L', 'S', '1', 0, 0,
};
const result_link_magic = [_]u8{
    'G', 'A', 'V', 'L', 'K', '1', 0, 0,
};
const link_state_domain =
    "glacier-audio-video-link-state-v1\x00";
const result_link_domain =
    "glacier-audio-video-result-link-v1\x00";
const link_policy_domain =
    "glacier-audio-video-link-policy-v1\x00";

pub const Error = media.Error || resource_bank.Error ||
    audio.Error || video_timeline.Error || error{
    InvalidState,
    InvalidLinkState,
    InvalidLinkInput,
    InvalidResultLink,
    NoTemporalOverlap,
    NonIntegralTimeMapping,
    BufferTooSmall,
    BufferAlias,
    CandidateDrift,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
};

pub const TemporalRelationV1 = enum(u64) {
    exact = 1,
    audio_within_video = 2,
    video_within_audio = 3,
    partial_overlap = 4,
};

pub const Phase = enum(u8) {
    idle = 0,
    prepared = 1,
    poisoned = 2,
    closed = 3,
};

pub const AudioVideoLinkStateV1 = struct {
    request_epoch: u64,
    next_sequence: u64,
    visible_links: u64,
    last_link_index: u64,
    audio_media_sha256: Digest,
    video_media_sha256: Digest,
    challenge_sha256: Digest,
    previous_link_sha256: Digest,
    policy_sha256: Digest,
    state_sha256: Digest,
};

pub const AudioVideoResultLinkV1 = struct {
    request_epoch: u64,
    link_sequence: u64,
    link_index: u64,
    relation: TemporalRelationV1,
    target_numerator: u64,
    target_denominator: u64,
    audio_source_start_sample: u64,
    audio_source_end_sample: u64,
    audio_start_tick: u64,
    audio_end_tick: u64,
    video_start_tick: u64,
    video_end_tick: u64,
    overlap_start_tick: u64,
    overlap_end_tick: u64,
    transcript_segment_index: u64,
    timeline_decision_count: u64,
    timeline_visible_segments: u64,
    audio_media_sha256: Digest,
    audio_processor_state_sha256: Digest,
    audio_cache_payload_sha256: Digest,
    audio_overlap_sha256: Digest,
    transcript_sha256: Digest,
    video_media_sha256: Digest,
    video_timeline_sha256: Digest,
    video_tail_segment_sha256: Digest,
    previous_link_sha256: Digest,
    challenge_sha256: Digest,
    policy_sha256: Digest,
    link_sha256: Digest,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    state: *AudioVideoLinkStateV1 = undefined,
    receipt: resource_bank.Receipt = undefined,
    permit: ?resource_bank.PublicationPermit = null,
    overlap: audio.OverlapPlanV1 = undefined,
    transcript: audio.TranscriptSegmentV1 = undefined,
    timeline: video_timeline.VideoSegmentTimelineV1 = undefined,
    prepared_link: ?AudioVideoResultLinkV1 = null,
    candidate: ?[]u8 = null,
    visible_output: ?[]u8 = null,
    expected_candidate_sha256: Digest = [_]u8{0} ** 32,
    expected_state_sha256: Digest = [_]u8{0} ** 32,
    next_resource_sequence: u64 = 0,
    initialized: bool = false,
    phase: Phase = .idle,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        state: *AudioVideoLinkStateV1,
    ) Error!void {
        if (self.initialized or owner_key == 0)
            return Error.InvalidState;
        try validateLinkStateV1(state.*);
        const reservation = bank.reserve(
            owner_key,
            linkClaimV1(),
        ) catch return Error.ResourceAdmissionFailed;
        const receipt = bank.commit(reservation) catch {
            bank.cancel(reservation) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceAdmissionFailed;
        };
        bank.bindPublicationSession(
            receipt,
            state.request_epoch,
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
            .initialized = true,
        };
    }

    pub fn prepareV1(
        self: *Session,
        overlap: audio.OverlapPlanV1,
        transcript: audio.TranscriptSegmentV1,
        timeline: video_timeline.VideoSegmentTimelineV1,
        candidate: []u8,
        visible_output: []u8,
    ) Error!AudioVideoResultLinkV1 {
        if (!self.initialized or self.phase != .idle or
            self.permit != null or self.prepared_link != null)
            return Error.InvalidState;
        try validateLinkStateV1(self.state.*);
        const expected = try makeResultLinkV1(
            self.state.*,
            overlap,
            transcript,
            timeline,
        );
        if (candidate.len < result_link_bytes or
            visible_output.len < result_link_bytes)
            return Error.BufferTooSmall;
        const candidate_slice = candidate[0..result_link_bytes];
        const visible_slice =
            visible_output[0..result_link_bytes];
        const state_bytes = std.mem.asBytes(self.state);
        if (slicesOverlap(candidate_slice, visible_slice) or
            slicesOverlap(candidate_slice, state_bytes) or
            slicesOverlap(visible_slice, state_bytes))
            return Error.BufferAlias;
        @memset(candidate_slice, 0);
        const permit = self.bank.beginPublication(
            self.receipt,
            self.state.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        var encoded: [result_link_bytes]u8 = undefined;
        _ = encodeResultLinkV1(expected, &encoded) catch {
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.InvalidResultLink;
        };
        @memcpy(candidate_slice, &encoded);
        self.permit = permit;
        self.overlap = overlap;
        self.transcript = transcript;
        self.timeline = timeline;
        self.prepared_link = expected;
        self.candidate = candidate_slice;
        self.visible_output = visible_slice;
        self.expected_candidate_sha256 =
            model.sha256(candidate_slice);
        self.expected_state_sha256 = self.state.state_sha256;
        self.phase = .prepared;
        return expected;
    }

    pub fn commitV1(self: *Session) Error!AudioVideoResultLinkV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        const expected = self.prepared_link orelse
            return Error.InvalidState;
        const candidate = self.candidate orelse
            return Error.InvalidState;
        const visible = self.visible_output orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        validateLinkStateV1(self.state.*) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.mem.eql(
            u8,
            &self.state.state_sha256,
            &self.expected_state_sha256,
        ) or
            !std.mem.eql(
                u8,
                &model.sha256(candidate),
                &self.expected_candidate_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        const decoded = decodeResultLinkV1(candidate) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.meta.eql(decoded, expected)) {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        const next_state = applyResultLinkV1(
            self.state.*,
            self.overlap,
            self.transcript,
            self.timeline,
            decoded,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        @memcpy(visible, candidate);
        self.state.* = next_state;
        self.bank.commitPublicationAssumeValid(permit);
        self.next_resource_sequence = permit.sequence + 1;
        @memset(candidate, 0);
        self.clearPreparedV1();
        self.phase = .idle;
        return decoded;
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
            self.state.request_epoch,
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
        if (self.candidate) |candidate|
            @memset(candidate, 0);
        self.bank.abortPublication(permit) catch {
            self.phase = .poisoned;
            return Error.ResourceReceiptInvalid;
        };
        self.clearPreparedV1();
        self.phase = .idle;
    }

    fn clearPreparedV1(self: *Session) void {
        self.permit = null;
        self.prepared_link = null;
        self.candidate = null;
        self.visible_output = null;
        self.expected_candidate_sha256 = [_]u8{0} ** 32;
        self.expected_state_sha256 = [_]u8{0} ** 32;
    }
};

pub fn linkClaimV1() resource_bank.Claim {
    return .{
        .partial_bytes = result_link_bytes,
        .output_journal_bytes = result_link_bytes,
        .queue_slots = 1,
    };
}

pub fn linkPolicyRootV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(link_policy_domain);
    hashU64(&hash, 1);
    inline for (std.meta.tags(TemporalRelationV1)) |relation|
        hashU64(&hash, @intFromEnum(relation));
    return hash.finalResult();
}

pub fn initializeLinkStateV1(
    request_epoch: u64,
    audio_media_sha256: Digest,
    video_media_sha256: Digest,
    challenge_sha256: Digest,
    genesis_link_sha256: Digest,
) Error!AudioVideoLinkStateV1 {
    var state: AudioVideoLinkStateV1 = .{
        .request_epoch = request_epoch,
        .next_sequence = 0,
        .visible_links = 0,
        .last_link_index = 0,
        .audio_media_sha256 = audio_media_sha256,
        .video_media_sha256 = video_media_sha256,
        .challenge_sha256 = challenge_sha256,
        .previous_link_sha256 = genesis_link_sha256,
        .policy_sha256 = linkPolicyRootV1(),
        .state_sha256 = [_]u8{0} ** 32,
    };
    state.state_sha256 = linkStateRootV1(state);
    try validateLinkStateV1(state);
    return state;
}

pub fn makeResultLinkV1(
    state: AudioVideoLinkStateV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
) Error!AudioVideoResultLinkV1 {
    try validateLinkInputsV1(
        state,
        overlap,
        transcript,
        timeline,
    );
    const mapped = try mapTranscriptPublishV1(
        transcript,
        .{
            .numerator = timeline.target_numerator,
            .denominator = timeline.target_denominator,
        },
    );
    const overlap_start = @max(
        mapped.start.ticks,
        timeline.tail_start_tick,
    );
    const overlap_end = @min(
        mapped.end.ticks,
        timeline.tail_end_tick,
    );
    if (overlap_start >= overlap_end)
        return Error.NoTemporalOverlap;
    const relation = temporalRelationV1(
        mapped.start.ticks,
        mapped.end.ticks,
        timeline.tail_start_tick,
        timeline.tail_end_tick,
    );
    const link_index = std.math.add(
        u64,
        state.last_link_index,
        1,
    ) catch return Error.InvalidLinkState;
    var link: AudioVideoResultLinkV1 = .{
        .request_epoch = state.request_epoch,
        .link_sequence = state.next_sequence,
        .link_index = link_index,
        .relation = relation,
        .target_numerator = timeline.target_numerator,
        .target_denominator = timeline.target_denominator,
        .audio_source_start_sample = transcript.publish_start_sample,
        .audio_source_end_sample = transcript.publish_end_sample,
        .audio_start_tick = mapped.start.ticks,
        .audio_end_tick = mapped.end.ticks,
        .video_start_tick = timeline.tail_start_tick,
        .video_end_tick = timeline.tail_end_tick,
        .overlap_start_tick = overlap_start,
        .overlap_end_tick = overlap_end,
        .transcript_segment_index = transcript.segment_index,
        .timeline_decision_count = timeline.decision_count,
        .timeline_visible_segments = timeline.visible_segments,
        .audio_media_sha256 = transcript.media_object_sha256,
        .audio_processor_state_sha256 = transcript.processor_state_sha256,
        .audio_cache_payload_sha256 = transcript.cache_payload_sha256,
        .audio_overlap_sha256 = transcript.overlap_sha256,
        .transcript_sha256 = transcript.transcript_sha256,
        .video_media_sha256 = timeline.media_object_sha256,
        .video_timeline_sha256 = timeline.timeline_sha256,
        .video_tail_segment_sha256 = timeline.tail_segment_sha256,
        .previous_link_sha256 = state.previous_link_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .policy_sha256 = state.policy_sha256,
        .link_sha256 = [_]u8{0} ** 32,
    };
    link.link_sha256 = resultLinkRootV1(link);
    try validateResultLinkV1(link);
    return link;
}

pub fn applyResultLinkV1(
    state: AudioVideoLinkStateV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    link: AudioVideoResultLinkV1,
) Error!AudioVideoLinkStateV1 {
    try validateLinkStateV1(state);
    const expected = try makeResultLinkV1(
        state,
        overlap,
        transcript,
        timeline,
    );
    if (!std.meta.eql(expected, link))
        return Error.InvalidResultLink;
    var next = state;
    next.next_sequence = std.math.add(
        u64,
        state.next_sequence,
        1,
    ) catch return Error.InvalidLinkState;
    next.visible_links = std.math.add(
        u64,
        state.visible_links,
        1,
    ) catch return Error.InvalidLinkState;
    next.last_link_index = link.link_index;
    next.previous_link_sha256 = link.link_sha256;
    next.state_sha256 = linkStateRootV1(next);
    try validateLinkStateV1(next);
    return next;
}

pub fn validateLinkStateV1(
    state: AudioVideoLinkStateV1,
) Error!void {
    if (state.request_epoch == 0 or
        state.next_sequence != state.visible_links or
        state.visible_links != state.last_link_index or
        isZero(state.audio_media_sha256) or
        isZero(state.video_media_sha256) or
        isZero(state.challenge_sha256) or
        isZero(state.previous_link_sha256) or
        !std.mem.eql(
            u8,
            &state.policy_sha256,
            &linkPolicyRootV1(),
        ) or
        !std.mem.eql(
            u8,
            &state.state_sha256,
            &linkStateRootV1(state),
        ))
        return Error.InvalidLinkState;
}

pub fn validateResultLinkV1(
    link: AudioVideoResultLinkV1,
) Error!void {
    media.validateTimeBaseV1(.{
        .numerator = link.target_numerator,
        .denominator = link.target_denominator,
    }) catch return Error.InvalidResultLink;
    const expected_index = std.math.add(
        u64,
        link.link_sequence,
        1,
    ) catch return Error.InvalidResultLink;
    const maximum_visible = std.math.add(
        u64,
        link.timeline_decision_count,
        1,
    ) catch return Error.InvalidResultLink;
    if (link.request_epoch == 0 or
        link.link_index != expected_index or
        link.target_numerator == 0 or
        link.target_denominator == 0 or
        link.audio_source_start_sample >=
            link.audio_source_end_sample or
        link.audio_start_tick >= link.audio_end_tick or
        link.video_start_tick >= link.video_end_tick or
        link.overlap_start_tick >= link.overlap_end_tick or
        link.overlap_start_tick != @max(
            link.audio_start_tick,
            link.video_start_tick,
        ) or
        link.overlap_end_tick != @min(
            link.audio_end_tick,
            link.video_end_tick,
        ) or
        link.relation != temporalRelationV1(
            link.audio_start_tick,
            link.audio_end_tick,
            link.video_start_tick,
            link.video_end_tick,
        ) or
        link.transcript_segment_index == 0 or
        link.timeline_visible_segments == 0 or
        link.timeline_visible_segments > maximum_visible or
        isZero(link.audio_media_sha256) or
        isZero(link.audio_processor_state_sha256) or
        isZero(link.audio_cache_payload_sha256) or
        isZero(link.audio_overlap_sha256) or
        isZero(link.transcript_sha256) or
        isZero(link.video_media_sha256) or
        isZero(link.video_timeline_sha256) or
        isZero(link.video_tail_segment_sha256) or
        isZero(link.previous_link_sha256) or
        isZero(link.challenge_sha256) or
        !std.mem.eql(
            u8,
            &link.policy_sha256,
            &linkPolicyRootV1(),
        ) or
        !std.mem.eql(
            u8,
            &link.link_sha256,
            &resultLinkRootV1(link),
        ))
        return Error.InvalidResultLink;
}

pub fn validateLinkInputsV1(
    state: AudioVideoLinkStateV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
) Error!void {
    try validateLinkStateV1(state);
    audio.validateOverlapPlanV1(overlap) catch
        return Error.InvalidLinkInput;
    audio.validateTranscriptSegmentV1(transcript) catch
        return Error.InvalidLinkInput;
    video_timeline.validateTimelineV1(timeline) catch
        return Error.InvalidLinkInput;
    if (state.request_epoch != overlap.request_epoch or
        state.request_epoch != transcript.request_epoch or
        state.request_epoch != timeline.request_epoch or
        overlap.generation != transcript.generation or
        overlap.segment_index != transcript.segment_index or
        overlap.context_start_sample !=
            transcript.context_start_sample or
        overlap.context_end_sample !=
            transcript.context_end_sample or
        overlap.publish_start_sample !=
            transcript.publish_start_sample or
        overlap.publish_end_sample !=
            transcript.publish_end_sample or
        overlap.sample_rate != transcript.sample_rate or
        !std.mem.eql(
            u8,
            &overlap.media_object_sha256,
            &transcript.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap.processor_state_sha256,
            &transcript.processor_state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap.cache_payload_sha256,
            &transcript.cache_payload_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap.overlap_sha256,
            &transcript.overlap_sha256,
        ) or
        !std.mem.eql(
            u8,
            &overlap.previous_transcript_sha256,
            &transcript.previous_transcript_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state.audio_media_sha256,
            &overlap.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state.video_media_sha256,
            &timeline.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state.challenge_sha256,
            &overlap.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &state.challenge_sha256,
            &timeline.challenge_sha256,
        ))
        return Error.InvalidLinkInput;
    _ = try mapTranscriptPublishV1(
        transcript,
        .{
            .numerator = timeline.target_numerator,
            .denominator = timeline.target_denominator,
        },
    );
}

pub fn encodeLinkStateV1(
    state: AudioVideoLinkStateV1,
    output: *[link_state_bytes]u8,
) Error![]const u8 {
    try validateLinkStateV1(state);
    writeLinkStateBodyV1(
        state,
        output[0..link_state_body_bytes],
    );
    @memcpy(
        output[link_state_body_bytes..],
        &state.state_sha256,
    );
    return output;
}

pub fn decodeLinkStateV1(
    encoded: []const u8,
) Error!AudioVideoLinkStateV1 {
    if (encoded.len != link_state_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &link_state_magic,
        ) or
        readU64(encoded, 8) != link_state_abi or
        readU64(encoded, 16) != link_state_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[64..96], 0) or
        !std.mem.allEqual(u8, encoded[256..288], 0))
        return Error.InvalidLinkState;
    const state: AudioVideoLinkStateV1 = .{
        .request_epoch = readU64(encoded, 32),
        .next_sequence = readU64(encoded, 40),
        .visible_links = readU64(encoded, 48),
        .last_link_index = readU64(encoded, 56),
        .audio_media_sha256 = encoded[96..128].*,
        .video_media_sha256 = encoded[128..160].*,
        .challenge_sha256 = encoded[160..192].*,
        .previous_link_sha256 = encoded[192..224].*,
        .policy_sha256 = encoded[224..256].*,
        .state_sha256 = encoded[link_state_body_bytes..link_state_bytes].*,
    };
    try validateLinkStateV1(state);
    var canonical: [link_state_bytes]u8 = undefined;
    _ = try encodeLinkStateV1(state, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidLinkState;
    return state;
}

pub fn encodeResultLinkV1(
    link: AudioVideoResultLinkV1,
    output: *[result_link_bytes]u8,
) Error![]const u8 {
    try validateResultLinkV1(link);
    writeResultLinkBodyV1(
        link,
        output[0..result_link_body_bytes],
    );
    @memcpy(
        output[result_link_body_bytes..],
        &link.link_sha256,
    );
    return output;
}

pub fn decodeResultLinkV1(
    encoded: []const u8,
) Error!AudioVideoResultLinkV1 {
    if (encoded.len != result_link_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &result_link_magic,
        ) or
        readU64(encoded, 8) != result_link_abi or
        readU64(encoded, 16) != result_link_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[168..192], 0))
        return Error.InvalidResultLink;
    const relation = std.meta.intToEnum(
        TemporalRelationV1,
        readU64(encoded, 56),
    ) catch return Error.InvalidResultLink;
    const link: AudioVideoResultLinkV1 = .{
        .request_epoch = readU64(encoded, 32),
        .link_sequence = readU64(encoded, 40),
        .link_index = readU64(encoded, 48),
        .relation = relation,
        .target_numerator = readU64(encoded, 64),
        .target_denominator = readU64(encoded, 72),
        .audio_source_start_sample = readU64(encoded, 80),
        .audio_source_end_sample = readU64(encoded, 88),
        .audio_start_tick = readU64(encoded, 96),
        .audio_end_tick = readU64(encoded, 104),
        .video_start_tick = readU64(encoded, 112),
        .video_end_tick = readU64(encoded, 120),
        .overlap_start_tick = readU64(encoded, 128),
        .overlap_end_tick = readU64(encoded, 136),
        .transcript_segment_index = readU64(encoded, 144),
        .timeline_decision_count = readU64(encoded, 152),
        .timeline_visible_segments = readU64(encoded, 160),
        .audio_media_sha256 = encoded[192..224].*,
        .audio_processor_state_sha256 = encoded[224..256].*,
        .audio_cache_payload_sha256 = encoded[256..288].*,
        .audio_overlap_sha256 = encoded[288..320].*,
        .transcript_sha256 = encoded[320..352].*,
        .video_media_sha256 = encoded[352..384].*,
        .video_timeline_sha256 = encoded[384..416].*,
        .video_tail_segment_sha256 = encoded[416..448].*,
        .previous_link_sha256 = encoded[448..480].*,
        .challenge_sha256 = encoded[480..512].*,
        .policy_sha256 = encoded[512..544].*,
        .link_sha256 = encoded[result_link_body_bytes..result_link_bytes].*,
    };
    try validateResultLinkV1(link);
    var canonical: [result_link_bytes]u8 = undefined;
    _ = try encodeResultLinkV1(link, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidResultLink;
    return link;
}

pub fn linkStateRootV1(state: AudioVideoLinkStateV1) Digest {
    var body: [link_state_body_bytes]u8 = undefined;
    writeLinkStateBodyV1(state, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(link_state_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn resultLinkRootV1(link: AudioVideoResultLinkV1) Digest {
    var body: [result_link_body_bytes]u8 = undefined;
    writeResultLinkBodyV1(link, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(result_link_domain);
    hash.update(&body);
    return hash.finalResult();
}

fn mapTranscriptPublishV1(
    transcript: audio.TranscriptSegmentV1,
    target: media.TimeBaseV1,
) Error!media.SpanV1 {
    return media.mapSpanExactV1(
        .{
            .start = .{
                .ticks = transcript.publish_start_sample,
                .base = .{
                    .numerator = 1,
                    .denominator = transcript.sample_rate,
                },
            },
            .end = .{
                .ticks = transcript.publish_end_sample,
                .base = .{
                    .numerator = 1,
                    .denominator = transcript.sample_rate,
                },
            },
        },
        target,
    ) catch |err| switch (err) {
        error.NonIntegralMapping => return Error.NonIntegralTimeMapping,
        else => return err,
    };
}

fn temporalRelationV1(
    audio_start: u64,
    audio_end: u64,
    video_start: u64,
    video_end: u64,
) TemporalRelationV1 {
    if (audio_start == video_start and audio_end == video_end)
        return .exact;
    if (audio_start >= video_start and audio_end <= video_end)
        return .audio_within_video;
    if (video_start >= audio_start and video_end <= audio_end)
        return .video_within_audio;
    return .partial_overlap;
}

fn writeLinkStateBodyV1(
    state: AudioVideoLinkStateV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &link_state_magic);
    writeU64(output, 8, link_state_abi);
    writeU64(output, 16, link_state_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        state.request_epoch,
        state.next_sequence,
        state.visible_links,
        state.last_link_index,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        state.audio_media_sha256,
        state.video_media_sha256,
        state.challenge_sha256,
        state.previous_link_sha256,
        state.policy_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 96 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

fn writeResultLinkBodyV1(
    link: AudioVideoResultLinkV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &result_link_magic);
    writeU64(output, 8, result_link_abi);
    writeU64(output, 16, result_link_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        link.request_epoch,
        link.link_sequence,
        link.link_index,
        @intFromEnum(link.relation),
        link.target_numerator,
        link.target_denominator,
        link.audio_source_start_sample,
        link.audio_source_end_sample,
        link.audio_start_tick,
        link.audio_end_tick,
        link.video_start_tick,
        link.video_end_tick,
        link.overlap_start_tick,
        link.overlap_end_tick,
        link.transcript_segment_index,
        link.timeline_decision_count,
        link.timeline_visible_segments,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        link.audio_media_sha256,
        link.audio_processor_state_sha256,
        link.audio_cache_payload_sha256,
        link.audio_overlap_sha256,
        link.transcript_sha256,
        link.video_media_sha256,
        link.video_timeline_sha256,
        link.video_tail_segment_sha256,
        link.previous_link_sha256,
        link.challenge_sha256,
        link.policy_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 192 + index * 32;
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

const TestFixture = struct {
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
    video: video_segment.VideoSegmentV1,
    timeline: video_timeline.VideoSegmentTimelineV1,
    state: AudioVideoLinkStateV1,
};

fn testOverlap(
    publish_start: u64,
    publish_end: u64,
    sample_rate: u64,
    challenge: Digest,
) !audio.OverlapPlanV1 {
    const context_units: u64 = 2;
    const source_start = publish_start -| context_units;
    const source_units = publish_end - source_start;
    var overlap: audio.OverlapPlanV1 = .{
        .request_epoch = 221,
        .generation = 7,
        .segment_index = 1,
        .source_start_sample = source_start,
        .source_end_sample = publish_end,
        .context_start_sample = source_start,
        .context_end_sample = publish_start,
        .publish_start_sample = publish_start,
        .publish_end_sample = publish_end,
        .sample_rate = sample_rate,
        .window_samples = source_units,
        .hop_samples = source_units - context_units,
        .feature_frames = 1,
        .feature_bins = 8,
        .feature_bytes = 16,
        .media_object_sha256 = model.sha256("link audio media"),
        .processor_state_sha256 = model.sha256("link audio processor"),
        .processor_bundle_sha256 = model.sha256("link audio processor bundle"),
        .cache_bundle_sha256 = model.sha256("link audio cache bundle"),
        .cache_payload_sha256 = model.sha256("link audio cache payload"),
        .ownership_sha256 = model.sha256("link audio ownership"),
        .challenge_sha256 = challenge,
        .previous_transcript_sha256 = model.sha256("link previous transcript"),
        .overlap_sha256 = [_]u8{0} ** 32,
    };
    overlap.overlap_sha256 = audio.overlapPlanRootV1(overlap);
    try audio.validateOverlapPlanV1(overlap);
    return overlap;
}

fn testVideoSegment(
    start_tick: u64,
    end_tick: u64,
    challenge: Digest,
) !video_segment.VideoSegmentV1 {
    var value: video_segment.VideoSegmentV1 = .{
        .request_epoch = 221,
        .generation = 7,
        .segment_index = 1,
        .first_frame = start_tick,
        .last_frame = end_tick - 1,
        .frame_count = end_tick - start_tick,
        .frame_stride = 1,
        .keyframe_ordinal = 0,
        .eviction_boundary = 0,
        .cache_generation = 7,
        .target_base = .{
            .numerator = 1,
            .denominator = 1_000,
        },
        .target_start_tick = start_tick,
        .target_end_tick = end_tick,
        .event_id = 9,
        .confidence_ppm = 800_000,
        .media_object_sha256 = model.sha256("link video media"),
        .processor_state_sha256 = model.sha256("link video processor"),
        .processor_bundle_sha256 = model.sha256("link video processor bundle"),
        .cache_bundle_sha256 = model.sha256("link video cache bundle"),
        .cache_payload_sha256 = model.sha256("link video cache payload"),
        .ownership_sha256 = model.sha256("link video ownership"),
        .selection_sha256 = model.sha256("link video selection"),
        .challenge_sha256 = challenge,
        .previous_segment_sha256 = model.sha256("link previous video segment"),
        .segment_sha256 = [_]u8{0} ** 32,
    };
    value.segment_sha256 =
        video_segment.videoSegmentRootV1(value);
    try video_segment.validateVideoSegmentV1(value);
    return value;
}

fn testFixture(
    audio_start: u64,
    audio_end: u64,
    sample_rate: u64,
    video_start: u64,
    video_end: u64,
) !TestFixture {
    const challenge = model.sha256("audio video link challenge");
    const overlap = try testOverlap(
        audio_start,
        audio_end,
        sample_rate,
        challenge,
    );
    const transcript = try audio.makeTranscriptSegmentV1(
        overlap,
        "ice",
    );
    const video = try testVideoSegment(
        video_start,
        video_end,
        challenge,
    );
    const timeline = try video_timeline.initializeTimelineV1(
        video,
        model.sha256("link decision genesis"),
    );
    const state = try initializeLinkStateV1(
        221,
        overlap.media_object_sha256,
        video.media_object_sha256,
        challenge,
        model.sha256("audio video link genesis"),
    );
    return .{
        .overlap = overlap,
        .transcript = transcript,
        .video = video,
        .timeline = timeline,
        .state = state,
    };
}

test "audio video state and link wires reject every mutation" {
    const fixture = try testFixture(2, 10, 1_000, 0, 10);
    const link = try makeResultLinkV1(
        fixture.state,
        fixture.overlap,
        fixture.transcript,
        fixture.timeline,
    );
    try std.testing.expectEqual(
        TemporalRelationV1.audio_within_video,
        link.relation,
    );
    try std.testing.expectEqual(@as(u64, 2), link.audio_start_tick);
    try std.testing.expectEqual(@as(u64, 10), link.audio_end_tick);
    try std.testing.expectEqual(
        @as(u64, 2),
        link.overlap_start_tick,
    );
    var expected_state_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_state_root,
        "2052d23dc2c56b207f9fa159f85c177c291e0f08f2b5414e7620ab48915ed98f",
    );
    try std.testing.expectEqual(
        expected_state_root,
        fixture.state.state_sha256,
    );
    var expected_link_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_link_root,
        "e8790644683c583f170436fea1e30ff2ba257f879d1d48b4950d18c2f6f63cf9",
    );
    try std.testing.expectEqual(
        expected_link_root,
        link.link_sha256,
    );
    var non_canonical_time = link;
    non_canonical_time.target_numerator = 2;
    non_canonical_time.target_denominator = 2_000;
    non_canonical_time.link_sha256 =
        resultLinkRootV1(non_canonical_time);
    try std.testing.expectError(
        Error.InvalidResultLink,
        validateResultLinkV1(non_canonical_time),
    );
    var impossible_visible_count = link;
    impossible_visible_count.timeline_visible_segments = 2;
    impossible_visible_count.link_sha256 =
        resultLinkRootV1(impossible_visible_count);
    try std.testing.expectError(
        Error.InvalidResultLink,
        validateResultLinkV1(impossible_visible_count),
    );
    var state_wire: [link_state_bytes]u8 = undefined;
    _ = try encodeLinkStateV1(fixture.state, &state_wire);
    try std.testing.expectEqual(
        fixture.state,
        try decodeLinkStateV1(&state_wire),
    );
    for (0..state_wire.len) |index| {
        var mutated = state_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidLinkState,
            decodeLinkStateV1(&mutated),
        );
    }
    var link_wire: [result_link_bytes]u8 = undefined;
    _ = try encodeResultLinkV1(link, &link_wire);
    try std.testing.expectEqual(
        link,
        try decodeResultLinkV1(&link_wire),
    );
    for (0..link_wire.len) |index| {
        var mutated = link_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidResultLink,
            decodeResultLinkV1(&mutated),
        );
    }
}

test "audio video relations are exact and disjoint ranges reject" {
    const exact_fixture = try testFixture(2, 10, 1_000, 2, 10);
    try std.testing.expectEqual(
        TemporalRelationV1.exact,
        (try makeResultLinkV1(
            exact_fixture.state,
            exact_fixture.overlap,
            exact_fixture.transcript,
            exact_fixture.timeline,
        )).relation,
    );
    const video_within = try testFixture(2, 12, 1_000, 4, 10);
    try std.testing.expectEqual(
        TemporalRelationV1.video_within_audio,
        (try makeResultLinkV1(
            video_within.state,
            video_within.overlap,
            video_within.transcript,
            video_within.timeline,
        )).relation,
    );
    const partial = try testFixture(2, 10, 1_000, 8, 14);
    try std.testing.expectEqual(
        TemporalRelationV1.partial_overlap,
        (try makeResultLinkV1(
            partial.state,
            partial.overlap,
            partial.transcript,
            partial.timeline,
        )).relation,
    );
    const disjoint = try testFixture(20, 30, 1_000, 0, 10);
    try std.testing.expectError(
        Error.NoTemporalOverlap,
        makeResultLinkV1(
            disjoint.state,
            disjoint.overlap,
            disjoint.transcript,
            disjoint.timeline,
        ),
    );
    const non_integral = try testFixture(2, 10, 16_000, 0, 10);
    try std.testing.expectError(
        Error.NonIntegralTimeMapping,
        makeResultLinkV1(
            non_integral.state,
            non_integral.overlap,
            non_integral.transcript,
            non_integral.timeline,
        ),
    );
}

test "audio video link session abort drift retry and release are atomic" {
    var fixture = try testFixture(2, 10, 1_000, 0, 10);
    const initial = fixture.state;
    var slots: [2]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(&slots, .{}, 992);
    var session: Session = .{};
    try session.initV1(
        &bank,
        88_001,
        &fixture.state,
    );
    var candidate: [result_link_bytes]u8 = undefined;
    var output = [_]u8{0xa5} ** result_link_bytes;
    const original_output = output;
    _ = try session.prepareV1(
        fixture.overlap,
        fixture.transcript,
        fixture.timeline,
        &candidate,
        &output,
    );
    try session.abortV1();
    try std.testing.expectEqual(initial, fixture.state);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expectEqualSlices(
        u8,
        &original_output,
        &output,
    );
    _ = try session.prepareV1(
        fixture.overlap,
        fixture.transcript,
        fixture.timeline,
        &candidate,
        &output,
    );
    candidate[128] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(initial, fixture.state);
    try std.testing.expectEqualSlices(
        u8,
        &original_output,
        &output,
    );
    const prepared = try session.prepareV1(
        fixture.overlap,
        fixture.transcript,
        fixture.timeline,
        &candidate,
        &output,
    );
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.state.visible_links,
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expectEqual(
        committed,
        try decodeResultLinkV1(&output),
    );
    try session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}
