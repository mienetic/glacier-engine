//! Exact word timing, speaker attribution, and atomic speech annotation.
//!
//! The portable core receives verified transcript records and caller-owned
//! buffers. It has no microphone, codec, filesystem, network, provider,
//! accelerator, playback, clock, or device authority.

const std = @import("std");
const audio = @import("audio_transcript_adapter.zig");
const transcript_continuation =
    @import("audio_transcript_continuation.zig");
const model = @import("model_contract.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const state_abi: u64 = 0x5350_414e_5354_0001;
pub const plan_abi: u64 = 0x5350_414e_504c_0001;
pub const result_abi: u64 = 0x5350_414e_5253_0001;
pub const state_bytes: usize = 384;
pub const plan_bytes: usize = 576;
pub const result_bytes: usize = 896;
pub const maximum_words: usize = 4;
pub const maximum_speakers: usize = 2;
pub const maximum_confidence_ppm: u64 = 1_000_000;
pub const allowed_flags: u64 = 0;

const state_body_bytes = state_bytes - @sizeOf(Digest);
const plan_body_bytes = plan_bytes - @sizeOf(Digest);
const result_body_bytes = result_bytes - @sizeOf(Digest);
const state_magic = [_]u8{ 'G', 'S', 'P', 'A', 'N', 'S', '1', 0 };
const plan_magic = [_]u8{ 'G', 'S', 'P', 'A', 'N', 'P', '1', 0 };
const result_magic = [_]u8{ 'G', 'S', 'P', 'A', 'N', 'R', '1', 0 };
const state_domain = "glacier-speech-annotation-state-v1\x00";
const plan_domain = "glacier-speech-annotation-plan-v1\x00";
const result_domain = "glacier-speech-annotation-result-v1\x00";
const content_domain = "glacier-speech-annotation-content-v1\x00";
const policy_domain = "glacier-speech-annotation-policy-v1\x00";

pub const Error = audio.Error || transcript_continuation.Error ||
    resource_bank.Error || error{
    InvalidState,
    InvalidPlan,
    InvalidResult,
    InvalidBinding,
    InvalidWordTiming,
    InvalidSpeakerAttribution,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
    BufferTooSmall,
    BufferAlias,
    CandidateDrift,
};

pub const Phase = enum {
    idle,
    prepared,
    poisoned,
    closed,
};

pub const WordTimingV1 = struct {
    text_offset: u64 = 0,
    text_bytes: u64 = 0,
    start_sample: u64 = 0,
    end_sample: u64 = 0,
    speaker_index: u64 = 0,
    confidence_ppm: u64 = 0,
};

pub const SpeechAnnotationStateV1 = struct {
    request_epoch: u64,
    next_sequence: u64,
    visible_annotations: u64,
    visible_words: u64,
    visible_speaker_turns: u64,
    next_sample: u64,
    sample_rate: u64,
    audio_media_sha256: Digest,
    last_transcript_sha256: Digest,
    previous_result_sha256: Digest,
    last_speaker_sha256: Digest,
    policy_sha256: Digest,
    challenge_sha256: Digest,
    state_sha256: Digest,
};

pub const SpeechAnnotationPlanV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    sample_rate: u64,
    publish_start_sample: u64,
    publish_end_sample: u64,
    text_bytes: u64,
    maximum_words: u64,
    maximum_speakers: u64,
    publication_sequence: u64,
    visible_words_before: u64,
    visible_speaker_turns_before: u64,
    transcript_sha256: Digest,
    overlap_sha256: Digest,
    audio_media_sha256: Digest,
    processor_state_sha256: Digest,
    cache_payload_sha256: Digest,
    text_sha256: Digest,
    state_before_sha256: Digest,
    previous_result_sha256: Digest,
    policy_sha256: Digest,
    challenge_sha256: Digest,
    plan_sha256: Digest,
};

pub const SpeechAnnotationResultV1 = struct {
    request_epoch: u64,
    generation: u64,
    segment_index: u64,
    sample_rate: u64,
    publish_start_sample: u64,
    publish_end_sample: u64,
    text_bytes: u64,
    word_count: u64,
    speaker_count: u64,
    publication_sequence: u64,
    visible_annotations_before: u64,
    visible_annotations_after: u64,
    visible_words_before: u64,
    visible_words_after: u64,
    visible_speaker_turns_before: u64,
    visible_speaker_turns_after: u64,
    transcript_sha256: Digest,
    overlap_sha256: Digest,
    audio_media_sha256: Digest,
    processor_state_sha256: Digest,
    cache_payload_sha256: Digest,
    text_sha256: Digest,
    plan_sha256: Digest,
    annotation_content_sha256: Digest,
    state_before_sha256: Digest,
    previous_result_sha256: Digest,
    policy_sha256: Digest,
    challenge_sha256: Digest,
    words: [maximum_words]WordTimingV1,
    speakers: [maximum_speakers]Digest,
    result_sha256: Digest,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    state: *SpeechAnnotationStateV1 = undefined,
    receipt: resource_bank.Receipt = undefined,
    permit: ?resource_bank.PublicationPermit = null,
    plan: SpeechAnnotationPlanV1 = undefined,
    overlap: audio.OverlapPlanV1 = undefined,
    transcript: audio.TranscriptSegmentV1 = undefined,
    prepared_result: ?SpeechAnnotationResultV1 = null,
    prepared_state_after: ?SpeechAnnotationStateV1 = null,
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
        state: *SpeechAnnotationStateV1,
        plan: SpeechAnnotationPlanV1,
        overlap: audio.OverlapPlanV1,
        transcript: audio.TranscriptSegmentV1,
    ) Error!void {
        if (self.initialized or self.phase != .idle or owner_key == 0)
            return Error.InvalidState;
        try validatePlanBindingsV1(
            state.*,
            plan,
            overlap,
            transcript,
        );
        const reservation = bank.reserve(
            owner_key,
            annotationClaimV1(),
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
            .plan = plan,
            .overlap = overlap,
            .transcript = transcript,
            .initialized = true,
        };
    }

    pub fn prepareV1(
        self: *Session,
        words: []const WordTimingV1,
        speakers: []const Digest,
        candidate: []u8,
        visible_output: []u8,
    ) Error!SpeechAnnotationResultV1 {
        if (!self.initialized or self.phase != .idle or
            self.permit != null or self.prepared_result != null)
            return Error.InvalidState;
        try validatePlanBindingsV1(
            self.state.*,
            self.plan,
            self.overlap,
            self.transcript,
        );
        const result = try makeResultV1(
            self.state.*,
            self.plan,
            self.overlap,
            self.transcript,
            words,
            speakers,
        );
        const state_after = try applyResultV1(
            self.state.*,
            self.plan,
            self.overlap,
            self.transcript,
            result,
        );
        if (candidate.len < result_bytes or
            visible_output.len < result_bytes)
            return Error.BufferTooSmall;
        const candidate_slice = candidate[0..result_bytes];
        const visible_slice = visible_output[0..result_bytes];
        const state_slice = std.mem.asBytes(self.state);
        if (slicesOverlap(candidate_slice, visible_slice) or
            slicesOverlap(candidate_slice, state_slice) or
            slicesOverlap(visible_slice, state_slice))
            return Error.BufferAlias;
        @memset(candidate_slice, 0);
        const permit = self.bank.beginPublication(
            self.receipt,
            self.state.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        var encoded: [result_bytes]u8 = undefined;
        _ = encodeResultV1(result, &encoded) catch {
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.InvalidResult;
        };
        @memcpy(candidate_slice, &encoded);
        self.permit = permit;
        self.prepared_result = result;
        self.prepared_state_after = state_after;
        self.candidate = candidate_slice;
        self.visible_output = visible_slice;
        self.expected_candidate_sha256 = model.sha256(candidate_slice);
        self.expected_state_sha256 = self.state.state_sha256;
        self.phase = .prepared;
        return result;
    }

    pub fn commitV1(
        self: *Session,
    ) Error!SpeechAnnotationResultV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse return Error.InvalidState;
        const expected = self.prepared_result orelse
            return Error.InvalidState;
        const expected_state_after = self.prepared_state_after orelse
            return Error.InvalidState;
        const candidate = self.candidate orelse
            return Error.InvalidState;
        const visible = self.visible_output orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        validatePlanBindingsV1(
            self.state.*,
            self.plan,
            self.overlap,
            self.transcript,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!digestEqual(
            self.state.state_sha256,
            self.expected_state_sha256,
        ) or
            !digestEqual(
                model.sha256(candidate),
                self.expected_candidate_sha256,
            ))
        {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        const decoded = decodeResultV1(candidate) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        validateResultBindingsV1(
            self.state.*,
            self.plan,
            self.overlap,
            self.transcript,
            decoded,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.meta.eql(decoded, expected)) {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        const next_state = applyResultV1(
            self.state.*,
            self.plan,
            self.overlap,
            self.transcript,
            decoded,
        ) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.meta.eql(next_state, expected_state_after)) {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
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
        const permit = self.permit orelse return Error.InvalidState;
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
        self.prepared_result = null;
        self.prepared_state_after = null;
        self.candidate = null;
        self.visible_output = null;
        self.expected_candidate_sha256 = [_]u8{0} ** 32;
        self.expected_state_sha256 = [_]u8{0} ** 32;
    }
};

pub fn annotationClaimV1() resource_bank.Claim {
    return .{
        .partial_bytes = result_bytes,
        .output_journal_bytes = result_bytes,
        .queue_slots = 1,
    };
}

pub fn annotationPolicyRootV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(policy_domain);
    hashU64(&hash, 1);
    hashU64(&hash, maximum_words);
    hashU64(&hash, maximum_speakers);
    hashU64(&hash, maximum_confidence_ppm);
    return hash.finalResult();
}

pub fn initializeStateV1(
    request_epoch: u64,
    audio_media_sha256: Digest,
    sample_rate: u64,
    next_sample: u64,
    last_transcript_sha256: Digest,
    genesis_result_sha256: Digest,
    genesis_speaker_sha256: Digest,
    challenge_sha256: Digest,
) Error!SpeechAnnotationStateV1 {
    var state: SpeechAnnotationStateV1 = .{
        .request_epoch = request_epoch,
        .next_sequence = 0,
        .visible_annotations = 0,
        .visible_words = 0,
        .visible_speaker_turns = 0,
        .next_sample = next_sample,
        .sample_rate = sample_rate,
        .audio_media_sha256 = audio_media_sha256,
        .last_transcript_sha256 = last_transcript_sha256,
        .previous_result_sha256 = genesis_result_sha256,
        .last_speaker_sha256 = genesis_speaker_sha256,
        .policy_sha256 = annotationPolicyRootV1(),
        .challenge_sha256 = challenge_sha256,
        .state_sha256 = [_]u8{0} ** 32,
    };
    state.state_sha256 = stateRootV1(state);
    try validateStateV1(state);
    return state;
}

pub fn makePlanV1(
    state: SpeechAnnotationStateV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
) Error!SpeechAnnotationPlanV1 {
    try validateTranscriptInputsV1(
        state,
        overlap,
        transcript,
    );
    const text_len = std.math.cast(
        usize,
        transcript.text_bytes,
    ) orelse return Error.InvalidPlan;
    var plan: SpeechAnnotationPlanV1 = .{
        .request_epoch = state.request_epoch,
        .generation = transcript.generation,
        .segment_index = transcript.segment_index,
        .sample_rate = transcript.sample_rate,
        .publish_start_sample = transcript.publish_start_sample,
        .publish_end_sample = transcript.publish_end_sample,
        .text_bytes = transcript.text_bytes,
        .maximum_words = maximum_words,
        .maximum_speakers = maximum_speakers,
        .publication_sequence = state.next_sequence,
        .visible_words_before = state.visible_words,
        .visible_speaker_turns_before = state.visible_speaker_turns,
        .transcript_sha256 = transcript.transcript_sha256,
        .overlap_sha256 = overlap.overlap_sha256,
        .audio_media_sha256 = transcript.media_object_sha256,
        .processor_state_sha256 = transcript.processor_state_sha256,
        .cache_payload_sha256 = transcript.cache_payload_sha256,
        .text_sha256 = model.sha256(
            transcript.text[0..text_len],
        ),
        .state_before_sha256 = state.state_sha256,
        .previous_result_sha256 = state.previous_result_sha256,
        .policy_sha256 = state.policy_sha256,
        .challenge_sha256 = state.challenge_sha256,
        .plan_sha256 = [_]u8{0} ** 32,
    };
    plan.plan_sha256 = planRootV1(plan);
    try validatePlanBindingsV1(
        state,
        plan,
        overlap,
        transcript,
    );
    return plan;
}

pub fn makeResultV1(
    state: SpeechAnnotationStateV1,
    plan: SpeechAnnotationPlanV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
    words: []const WordTimingV1,
    speakers: []const Digest,
) Error!SpeechAnnotationResultV1 {
    try validatePlanBindingsV1(
        state,
        plan,
        overlap,
        transcript,
    );
    const turns = try validateCandidateV1(
        state,
        transcript,
        words,
        speakers,
    );
    const annotations_after = std.math.add(
        u64,
        state.visible_annotations,
        1,
    ) catch return Error.InvalidResult;
    const words_after = std.math.add(
        u64,
        state.visible_words,
        words.len,
    ) catch return Error.InvalidResult;
    const turns_after = std.math.add(
        u64,
        state.visible_speaker_turns,
        turns,
    ) catch return Error.InvalidResult;
    var result: SpeechAnnotationResultV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .segment_index = plan.segment_index,
        .sample_rate = plan.sample_rate,
        .publish_start_sample = plan.publish_start_sample,
        .publish_end_sample = plan.publish_end_sample,
        .text_bytes = plan.text_bytes,
        .word_count = words.len,
        .speaker_count = speakers.len,
        .publication_sequence = plan.publication_sequence,
        .visible_annotations_before = state.visible_annotations,
        .visible_annotations_after = annotations_after,
        .visible_words_before = state.visible_words,
        .visible_words_after = words_after,
        .visible_speaker_turns_before = state.visible_speaker_turns,
        .visible_speaker_turns_after = turns_after,
        .transcript_sha256 = plan.transcript_sha256,
        .overlap_sha256 = plan.overlap_sha256,
        .audio_media_sha256 = plan.audio_media_sha256,
        .processor_state_sha256 = plan.processor_state_sha256,
        .cache_payload_sha256 = plan.cache_payload_sha256,
        .text_sha256 = plan.text_sha256,
        .plan_sha256 = plan.plan_sha256,
        .annotation_content_sha256 = [_]u8{0} ** 32,
        .state_before_sha256 = plan.state_before_sha256,
        .previous_result_sha256 = plan.previous_result_sha256,
        .policy_sha256 = plan.policy_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .words = [_]WordTimingV1{.{}} ** maximum_words,
        .speakers = [_]Digest{[_]u8{0} ** 32} ** maximum_speakers,
        .result_sha256 = [_]u8{0} ** 32,
    };
    @memcpy(result.words[0..words.len], words);
    @memcpy(result.speakers[0..speakers.len], speakers);
    result.annotation_content_sha256 =
        annotationContentRootV1(result);
    result.result_sha256 = resultRootV1(result);
    try validateResultBindingsV1(
        state,
        plan,
        overlap,
        transcript,
        result,
    );
    return result;
}

pub fn applyResultV1(
    state: SpeechAnnotationStateV1,
    plan: SpeechAnnotationPlanV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
    result: SpeechAnnotationResultV1,
) Error!SpeechAnnotationStateV1 {
    try validateResultBindingsV1(
        state,
        plan,
        overlap,
        transcript,
        result,
    );
    const speaker_count = std.math.cast(
        usize,
        result.speaker_count,
    ) orelse return Error.InvalidResult;
    const word_count = std.math.cast(
        usize,
        result.word_count,
    ) orelse return Error.InvalidResult;
    const last_word = result.words[word_count - 1];
    const speaker_index = std.math.cast(
        usize,
        last_word.speaker_index,
    ) orelse return Error.InvalidResult;
    if (speaker_index >= speaker_count)
        return Error.InvalidResult;
    var next = state;
    next.next_sequence = result.visible_annotations_after;
    next.visible_annotations = result.visible_annotations_after;
    next.visible_words = result.visible_words_after;
    next.visible_speaker_turns =
        result.visible_speaker_turns_after;
    next.next_sample = result.publish_end_sample;
    next.last_transcript_sha256 =
        result.transcript_sha256;
    next.previous_result_sha256 = result.result_sha256;
    next.last_speaker_sha256 =
        result.speakers[speaker_index];
    next.state_sha256 = stateRootV1(next);
    try validateStateV1(next);
    return next;
}

pub fn validateStateV1(
    state: SpeechAnnotationStateV1,
) Error!void {
    if (state.request_epoch == 0 or
        state.next_sequence != state.visible_annotations or
        state.visible_speaker_turns > state.visible_words or
        state.sample_rate == 0 or
        isZero(state.audio_media_sha256) or
        isZero(state.last_transcript_sha256) or
        isZero(state.previous_result_sha256) or
        isZero(state.last_speaker_sha256) or
        !digestEqual(
            state.policy_sha256,
            annotationPolicyRootV1(),
        ) or
        isZero(state.challenge_sha256) or
        !digestEqual(
            state.state_sha256,
            stateRootV1(state),
        ))
        return Error.InvalidState;
}

pub fn validatePlanV1(
    plan: SpeechAnnotationPlanV1,
) Error!void {
    if (plan.request_epoch == 0 or
        plan.generation == 0 or
        plan.segment_index == 0 or
        plan.sample_rate == 0 or
        plan.publish_start_sample >=
            plan.publish_end_sample or
        plan.text_bytes == 0 or
        plan.text_bytes > audio.maximum_text_bytes or
        plan.maximum_words != maximum_words or
        plan.maximum_speakers != maximum_speakers or
        plan.publication_sequence == std.math.maxInt(u64) or
        plan.visible_speaker_turns_before >
            plan.visible_words_before or
        isZero(plan.transcript_sha256) or
        isZero(plan.overlap_sha256) or
        isZero(plan.audio_media_sha256) or
        isZero(plan.processor_state_sha256) or
        isZero(plan.cache_payload_sha256) or
        isZero(plan.text_sha256) or
        isZero(plan.state_before_sha256) or
        isZero(plan.previous_result_sha256) or
        !digestEqual(
            plan.policy_sha256,
            annotationPolicyRootV1(),
        ) or
        isZero(plan.challenge_sha256) or
        !digestEqual(
            plan.plan_sha256,
            planRootV1(plan),
        ))
        return Error.InvalidPlan;
}

pub fn validateResultV1(
    result: SpeechAnnotationResultV1,
) Error!void {
    const word_count = std.math.cast(
        usize,
        result.word_count,
    ) orelse return Error.InvalidResult;
    const speaker_count = std.math.cast(
        usize,
        result.speaker_count,
    ) orelse return Error.InvalidResult;
    const expected_annotations_after = std.math.add(
        u64,
        result.visible_annotations_before,
        1,
    ) catch return Error.InvalidResult;
    const expected_words_after = std.math.add(
        u64,
        result.visible_words_before,
        result.word_count,
    ) catch return Error.InvalidResult;
    if (result.request_epoch == 0 or
        result.generation == 0 or
        result.segment_index == 0 or
        result.sample_rate == 0 or
        result.publish_start_sample >=
            result.publish_end_sample or
        result.text_bytes == 0 or
        result.text_bytes > audio.maximum_text_bytes or
        word_count == 0 or word_count > maximum_words or
        speaker_count == 0 or
        speaker_count > maximum_speakers or
        result.visible_annotations_after !=
            expected_annotations_after or
        result.visible_words_after != expected_words_after or
        result.visible_speaker_turns_before >
            result.visible_words_before or
        result.visible_speaker_turns_after <
            result.visible_speaker_turns_before or
        result.visible_speaker_turns_after >
            result.visible_words_after or
        isZero(result.transcript_sha256) or
        isZero(result.overlap_sha256) or
        isZero(result.audio_media_sha256) or
        isZero(result.processor_state_sha256) or
        isZero(result.cache_payload_sha256) or
        isZero(result.text_sha256) or
        isZero(result.plan_sha256) or
        isZero(result.annotation_content_sha256) or
        isZero(result.state_before_sha256) or
        isZero(result.previous_result_sha256) or
        !digestEqual(
            result.policy_sha256,
            annotationPolicyRootV1(),
        ) or
        isZero(result.challenge_sha256))
        return Error.InvalidResult;
    for (result.words[word_count..]) |word| {
        if (!std.meta.eql(word, WordTimingV1{}))
            return Error.InvalidResult;
    }
    for (result.speakers[speaker_count..]) |speaker| {
        if (!isZero(speaker))
            return Error.InvalidResult;
    }
    if (!digestEqual(
        result.annotation_content_sha256,
        annotationContentRootV1(result),
    ) or
        !digestEqual(
            result.result_sha256,
            resultRootV1(result),
        ))
        return Error.InvalidResult;
}

pub fn validatePlanBindingsV1(
    state: SpeechAnnotationStateV1,
    plan: SpeechAnnotationPlanV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
) Error!void {
    try validateStateV1(state);
    try validatePlanV1(plan);
    try validateTranscriptInputsV1(
        state,
        overlap,
        transcript,
    );
    const text_len = std.math.cast(
        usize,
        transcript.text_bytes,
    ) orelse return Error.InvalidBinding;
    if (plan.request_epoch != state.request_epoch or
        plan.generation != transcript.generation or
        plan.segment_index != transcript.segment_index or
        plan.sample_rate != state.sample_rate or
        plan.publish_start_sample != state.next_sample or
        plan.publish_start_sample !=
            transcript.publish_start_sample or
        plan.publish_end_sample !=
            transcript.publish_end_sample or
        plan.text_bytes != transcript.text_bytes or
        plan.publication_sequence != state.next_sequence or
        plan.visible_words_before != state.visible_words or
        plan.visible_speaker_turns_before !=
            state.visible_speaker_turns or
        !digestEqual(
            plan.transcript_sha256,
            transcript.transcript_sha256,
        ) or
        !digestEqual(
            plan.overlap_sha256,
            overlap.overlap_sha256,
        ) or
        !digestEqual(
            plan.audio_media_sha256,
            state.audio_media_sha256,
        ) or
        !digestEqual(
            plan.processor_state_sha256,
            transcript.processor_state_sha256,
        ) or
        !digestEqual(
            plan.cache_payload_sha256,
            transcript.cache_payload_sha256,
        ) or
        !digestEqual(
            plan.text_sha256,
            model.sha256(transcript.text[0..text_len]),
        ) or
        !digestEqual(
            plan.state_before_sha256,
            state.state_sha256,
        ) or
        !digestEqual(
            plan.previous_result_sha256,
            state.previous_result_sha256,
        ) or
        !digestEqual(plan.policy_sha256, state.policy_sha256) or
        !digestEqual(
            plan.challenge_sha256,
            state.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn validateResultBindingsV1(
    state: SpeechAnnotationStateV1,
    plan: SpeechAnnotationPlanV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
    result: SpeechAnnotationResultV1,
) Error!void {
    try validatePlanBindingsV1(
        state,
        plan,
        overlap,
        transcript,
    );
    try validateResultV1(result);
    const word_count = std.math.cast(
        usize,
        result.word_count,
    ) orelse return Error.InvalidBinding;
    const speaker_count = std.math.cast(
        usize,
        result.speaker_count,
    ) orelse return Error.InvalidBinding;
    const turns = try validateCandidateV1(
        state,
        transcript,
        result.words[0..word_count],
        result.speakers[0..speaker_count],
    );
    const expected_annotations_after = std.math.add(
        u64,
        state.visible_annotations,
        1,
    ) catch return Error.InvalidBinding;
    const expected_words_after = std.math.add(
        u64,
        state.visible_words,
        result.word_count,
    ) catch return Error.InvalidBinding;
    const expected_turns_after = std.math.add(
        u64,
        state.visible_speaker_turns,
        turns,
    ) catch return Error.InvalidBinding;
    if (result.request_epoch != plan.request_epoch or
        result.generation != plan.generation or
        result.segment_index != plan.segment_index or
        result.sample_rate != plan.sample_rate or
        result.publish_start_sample !=
            plan.publish_start_sample or
        result.publish_end_sample != plan.publish_end_sample or
        result.text_bytes != plan.text_bytes or
        result.publication_sequence !=
            plan.publication_sequence or
        result.visible_annotations_before !=
            state.visible_annotations or
        result.visible_annotations_after !=
            expected_annotations_after or
        result.visible_words_before != state.visible_words or
        result.visible_words_after != expected_words_after or
        result.visible_speaker_turns_before !=
            state.visible_speaker_turns or
        result.visible_speaker_turns_after !=
            expected_turns_after or
        !digestEqual(
            result.transcript_sha256,
            plan.transcript_sha256,
        ) or
        !digestEqual(
            result.overlap_sha256,
            plan.overlap_sha256,
        ) or
        !digestEqual(
            result.audio_media_sha256,
            plan.audio_media_sha256,
        ) or
        !digestEqual(
            result.processor_state_sha256,
            plan.processor_state_sha256,
        ) or
        !digestEqual(
            result.cache_payload_sha256,
            plan.cache_payload_sha256,
        ) or
        !digestEqual(result.text_sha256, plan.text_sha256) or
        !digestEqual(result.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            result.state_before_sha256,
            plan.state_before_sha256,
        ) or
        !digestEqual(
            result.previous_result_sha256,
            plan.previous_result_sha256,
        ) or
        !digestEqual(result.policy_sha256, plan.policy_sha256) or
        !digestEqual(
            result.challenge_sha256,
            plan.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn validateCandidateV1(
    state: SpeechAnnotationStateV1,
    transcript: audio.TranscriptSegmentV1,
    words: []const WordTimingV1,
    speakers: []const Digest,
) Error!u64 {
    try validateStateV1(state);
    audio.validateTranscriptSegmentV1(transcript) catch
        return Error.InvalidBinding;
    if (words.len == 0 or words.len > maximum_words or
        speakers.len == 0 or speakers.len > maximum_speakers)
        return Error.InvalidWordTiming;
    for (speakers, 0..) |speaker, index| {
        if (isZero(speaker))
            return Error.InvalidSpeakerAttribution;
        for (speakers[0..index]) |previous| {
            if (digestEqual(speaker, previous))
                return Error.InvalidSpeakerAttribution;
        }
    }
    const text_len = std.math.cast(
        usize,
        transcript.text_bytes,
    ) orelse return Error.InvalidWordTiming;
    const text = transcript.text[0..text_len];
    if (text.len == 0 or text[0] == ' ' or
        text[text.len - 1] == ' ')
        return Error.InvalidWordTiming;
    var cursor: usize = 0;
    var previous_end = transcript.publish_start_sample;
    var maximum_seen_speaker: u64 = 0;
    var previous_speaker = state.last_speaker_sha256;
    var turns: u64 = 0;
    for (words, 0..) |word, index| {
        if (cursor >= text.len or text[cursor] == ' ')
            return Error.InvalidWordTiming;
        const word_start = cursor;
        while (cursor < text.len and text[cursor] != ' ')
            cursor += 1;
        const expected_bytes = cursor - word_start;
        if (word.text_offset != word_start or
            word.text_bytes != expected_bytes or
            word.start_sample < transcript.publish_start_sample or
            word.end_sample > transcript.publish_end_sample or
            word.start_sample >= word.end_sample or
            (index == 0 and
                word.start_sample !=
                    transcript.publish_start_sample) or
            (index > 0 and
                word.start_sample < previous_end) or
            word.confidence_ppm == 0 or
            word.confidence_ppm > maximum_confidence_ppm or
            word.speaker_index >= speakers.len)
            return Error.InvalidWordTiming;
        if (index == 0) {
            if (word.speaker_index != 0)
                return Error.InvalidSpeakerAttribution;
        } else if (word.speaker_index > maximum_seen_speaker) {
            if (word.speaker_index != maximum_seen_speaker + 1)
                return Error.InvalidSpeakerAttribution;
            maximum_seen_speaker = word.speaker_index;
        }
        const speaker_index = std.math.cast(
            usize,
            word.speaker_index,
        ) orelse return Error.InvalidSpeakerAttribution;
        const speaker = speakers[speaker_index];
        if (!digestEqual(speaker, previous_speaker)) {
            turns = std.math.add(
                u64,
                turns,
                1,
            ) catch return Error.InvalidSpeakerAttribution;
        }
        previous_speaker = speaker;
        previous_end = word.end_sample;
        if (cursor < text.len) {
            if (text[cursor] != ' ' or
                cursor + 1 >= text.len or
                text[cursor + 1] == ' ')
                return Error.InvalidWordTiming;
            cursor += 1;
        }
    }
    if (cursor != text.len or
        previous_end != transcript.publish_end_sample or
        maximum_seen_speaker + 1 != speakers.len)
        return Error.InvalidWordTiming;
    return turns;
}

fn validateTranscriptInputsV1(
    state: SpeechAnnotationStateV1,
    overlap: audio.OverlapPlanV1,
    transcript: audio.TranscriptSegmentV1,
) Error!void {
    try validateStateV1(state);
    audio.validateOverlapPlanV1(overlap) catch
        return Error.InvalidBinding;
    audio.validateTranscriptSegmentV1(transcript) catch
        return Error.InvalidBinding;
    if (state.request_epoch != overlap.request_epoch or
        state.request_epoch != transcript.request_epoch or
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
        state.sample_rate != transcript.sample_rate or
        state.next_sample != transcript.publish_start_sample or
        !digestEqual(
            state.audio_media_sha256,
            transcript.media_object_sha256,
        ) or
        !digestEqual(
            state.last_transcript_sha256,
            transcript.previous_transcript_sha256,
        ) or
        !digestEqual(
            overlap.media_object_sha256,
            transcript.media_object_sha256,
        ) or
        !digestEqual(
            overlap.processor_state_sha256,
            transcript.processor_state_sha256,
        ) or
        !digestEqual(
            overlap.cache_payload_sha256,
            transcript.cache_payload_sha256,
        ) or
        !digestEqual(
            overlap.overlap_sha256,
            transcript.overlap_sha256,
        ) or
        !digestEqual(
            overlap.previous_transcript_sha256,
            transcript.previous_transcript_sha256,
        ) or
        !digestEqual(
            state.challenge_sha256,
            overlap.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn encodeStateV1(
    state: SpeechAnnotationStateV1,
    output: *[state_bytes]u8,
) Error![]const u8 {
    try validateStateV1(state);
    writeStateBodyV1(
        state,
        output[0..state_body_bytes],
    );
    @memcpy(output[state_body_bytes..], &state.state_sha256);
    return output;
}

pub fn decodeStateV1(
    encoded: []const u8,
) Error!SpeechAnnotationStateV1 {
    if (encoded.len != state_bytes or
        !std.mem.eql(u8, encoded[0..8], &state_magic) or
        readU64(encoded, 8) != state_abi or
        readU64(encoded, 16) != state_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[88..96], 0) or
        !std.mem.allEqual(
            u8,
            encoded[288..state_body_bytes],
            0,
        ))
        return Error.InvalidState;
    const state: SpeechAnnotationStateV1 = .{
        .request_epoch = readU64(encoded, 32),
        .next_sequence = readU64(encoded, 40),
        .visible_annotations = readU64(encoded, 48),
        .visible_words = readU64(encoded, 56),
        .visible_speaker_turns = readU64(encoded, 64),
        .next_sample = readU64(encoded, 72),
        .sample_rate = readU64(encoded, 80),
        .audio_media_sha256 = encoded[96..128].*,
        .last_transcript_sha256 = encoded[128..160].*,
        .previous_result_sha256 = encoded[160..192].*,
        .last_speaker_sha256 = encoded[192..224].*,
        .policy_sha256 = encoded[224..256].*,
        .challenge_sha256 = encoded[256..288].*,
        .state_sha256 = encoded[state_body_bytes..state_bytes].*,
    };
    try validateStateV1(state);
    var canonical: [state_bytes]u8 = undefined;
    _ = try encodeStateV1(state, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidState;
    return state;
}

pub fn encodePlanV1(
    plan: SpeechAnnotationPlanV1,
    output: *[plan_bytes]u8,
) Error![]const u8 {
    try validatePlanV1(plan);
    writePlanBodyV1(
        plan,
        output[0..plan_body_bytes],
    );
    @memcpy(output[plan_body_bytes..], &plan.plan_sha256);
    return output;
}

pub fn decodePlanV1(
    encoded: []const u8,
) Error!SpeechAnnotationPlanV1 {
    if (encoded.len != plan_bytes or
        !std.mem.eql(u8, encoded[0..8], &plan_magic) or
        readU64(encoded, 8) != plan_abi or
        readU64(encoded, 16) != plan_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[128..160], 0) or
        !std.mem.allEqual(
            u8,
            encoded[480..plan_body_bytes],
            0,
        ))
        return Error.InvalidPlan;
    const plan: SpeechAnnotationPlanV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .segment_index = readU64(encoded, 48),
        .sample_rate = readU64(encoded, 56),
        .publish_start_sample = readU64(encoded, 64),
        .publish_end_sample = readU64(encoded, 72),
        .text_bytes = readU64(encoded, 80),
        .maximum_words = readU64(encoded, 88),
        .maximum_speakers = readU64(encoded, 96),
        .publication_sequence = readU64(encoded, 104),
        .visible_words_before = readU64(encoded, 112),
        .visible_speaker_turns_before = readU64(encoded, 120),
        .transcript_sha256 = encoded[160..192].*,
        .overlap_sha256 = encoded[192..224].*,
        .audio_media_sha256 = encoded[224..256].*,
        .processor_state_sha256 = encoded[256..288].*,
        .cache_payload_sha256 = encoded[288..320].*,
        .text_sha256 = encoded[320..352].*,
        .state_before_sha256 = encoded[352..384].*,
        .previous_result_sha256 = encoded[384..416].*,
        .policy_sha256 = encoded[416..448].*,
        .challenge_sha256 = encoded[448..480].*,
        .plan_sha256 = encoded[plan_body_bytes..plan_bytes].*,
    };
    try validatePlanV1(plan);
    var canonical: [plan_bytes]u8 = undefined;
    _ = try encodePlanV1(plan, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidPlan;
    return plan;
}

pub fn encodeResultV1(
    result: SpeechAnnotationResultV1,
    output: *[result_bytes]u8,
) Error![]const u8 {
    try validateResultV1(result);
    writeResultBodyV1(
        result,
        output[0..result_body_bytes],
    );
    @memcpy(
        output[result_body_bytes..],
        &result.result_sha256,
    );
    return output;
}

pub fn decodeResultV1(
    encoded: []const u8,
) Error!SpeechAnnotationResultV1 {
    if (encoded.len != result_bytes or
        !std.mem.eql(u8, encoded[0..8], &result_magic) or
        readU64(encoded, 8) != result_abi or
        readU64(encoded, 16) != result_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(
            u8,
            encoded[832..result_body_bytes],
            0,
        ))
        return Error.InvalidResult;
    var words = [_]WordTimingV1{.{}} ** maximum_words;
    for (&words, 0..) |*word, index| {
        const start = 544 + index * 48;
        word.* = .{
            .text_offset = readU64(encoded, start),
            .text_bytes = readU64(encoded, start + 8),
            .start_sample = readU64(encoded, start + 16),
            .end_sample = readU64(encoded, start + 24),
            .speaker_index = readU64(encoded, start + 32),
            .confidence_ppm = readU64(encoded, start + 40),
        };
    }
    var speakers =
        [_]Digest{[_]u8{0} ** 32} ** maximum_speakers;
    for (&speakers, 0..) |*speaker, index| {
        const start = 736 + index * 32;
        speaker.* = encoded[start..][0..32].*;
    }
    const result: SpeechAnnotationResultV1 = .{
        .request_epoch = readU64(encoded, 32),
        .generation = readU64(encoded, 40),
        .segment_index = readU64(encoded, 48),
        .sample_rate = readU64(encoded, 56),
        .publish_start_sample = readU64(encoded, 64),
        .publish_end_sample = readU64(encoded, 72),
        .text_bytes = readU64(encoded, 80),
        .word_count = readU64(encoded, 88),
        .speaker_count = readU64(encoded, 96),
        .publication_sequence = readU64(encoded, 104),
        .visible_annotations_before = readU64(encoded, 112),
        .visible_annotations_after = readU64(encoded, 120),
        .visible_words_before = readU64(encoded, 128),
        .visible_words_after = readU64(encoded, 136),
        .visible_speaker_turns_before = readU64(encoded, 144),
        .visible_speaker_turns_after = readU64(encoded, 152),
        .transcript_sha256 = encoded[160..192].*,
        .overlap_sha256 = encoded[192..224].*,
        .audio_media_sha256 = encoded[224..256].*,
        .processor_state_sha256 = encoded[256..288].*,
        .cache_payload_sha256 = encoded[288..320].*,
        .text_sha256 = encoded[320..352].*,
        .plan_sha256 = encoded[352..384].*,
        .annotation_content_sha256 = encoded[384..416].*,
        .state_before_sha256 = encoded[416..448].*,
        .previous_result_sha256 = encoded[448..480].*,
        .policy_sha256 = encoded[480..512].*,
        .challenge_sha256 = encoded[512..544].*,
        .words = words,
        .speakers = speakers,
        .result_sha256 = encoded[result_body_bytes..result_bytes].*,
    };
    try validateResultV1(result);
    var canonical: [result_bytes]u8 = undefined;
    _ = try encodeResultV1(result, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidResult;
    return result;
}

pub fn stateRootV1(
    state: SpeechAnnotationStateV1,
) Digest {
    var body: [state_body_bytes]u8 = undefined;
    writeStateBodyV1(state, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(state_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn planRootV1(
    plan: SpeechAnnotationPlanV1,
) Digest {
    var body: [plan_body_bytes]u8 = undefined;
    writePlanBodyV1(plan, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn annotationContentRootV1(
    result: SpeechAnnotationResultV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(content_domain);
    hash.update(&result.transcript_sha256);
    hash.update(&result.text_sha256);
    hashU64(&hash, result.word_count);
    hashU64(&hash, result.speaker_count);
    const word_count = std.math.cast(
        usize,
        result.word_count,
    ) orelse return [_]u8{0} ** 32;
    const speaker_count = std.math.cast(
        usize,
        result.speaker_count,
    ) orelse return [_]u8{0} ** 32;
    if (word_count > maximum_words or
        speaker_count > maximum_speakers)
        return [_]u8{0} ** 32;
    for (result.words[0..word_count]) |word| {
        hashU64(&hash, word.text_offset);
        hashU64(&hash, word.text_bytes);
        hashU64(&hash, word.start_sample);
        hashU64(&hash, word.end_sample);
        hashU64(&hash, word.speaker_index);
        hashU64(&hash, word.confidence_ppm);
    }
    for (result.speakers[0..speaker_count]) |speaker|
        hash.update(&speaker);
    return hash.finalResult();
}

pub fn resultRootV1(
    result: SpeechAnnotationResultV1,
) Digest {
    var body: [result_body_bytes]u8 = undefined;
    writeResultBodyV1(result, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(result_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub const ReferenceFixtureV1 = struct {
    first_overlap: audio.OverlapPlanV1,
    first_transcript: audio.TranscriptSegmentV1,
    second_overlap: audio.OverlapPlanV1,
    second_transcript: audio.TranscriptSegmentV1,
    initial_state: SpeechAnnotationStateV1,
    first_words: [1]WordTimingV1,
    second_words: [1]WordTimingV1,
    first_speakers: [1]Digest,
    second_speakers: [1]Digest,
};

pub fn makeReferenceFixtureV1() Error!ReferenceFixtureV1 {
    const source =
        try transcript_continuation.makeReferenceSourceV1();
    const second_transcript =
        try audio.makeTranscriptSegmentV1(
            source.next_overlap,
            "berg",
        );
    const first_speaker = model.sha256(
        "speech annotation speaker one",
    );
    const second_speaker = model.sha256(
        "speech annotation speaker two",
    );
    return .{
        .first_overlap = source.previous_overlap,
        .first_transcript = source.previous_transcript,
        .second_overlap = source.next_overlap,
        .second_transcript = second_transcript,
        .initial_state = try initializeStateV1(
            source.previous_overlap.request_epoch,
            source.previous_overlap.media_object_sha256,
            source.previous_overlap.sample_rate,
            source.previous_overlap.publish_start_sample,
            source.previous_overlap.previous_transcript_sha256,
            model.sha256(
                "speech annotation result genesis",
            ),
            model.sha256(
                "speech annotation speaker genesis",
            ),
            source.previous_overlap.challenge_sha256,
        ),
        .first_words = .{.{
            .text_offset = 0,
            .text_bytes = 3,
            .start_sample = 2,
            .end_sample = 10,
            .speaker_index = 0,
            .confidence_ppm = 950_000,
        }},
        .second_words = .{.{
            .text_offset = 0,
            .text_bytes = 4,
            .start_sample = 10,
            .end_sample = 18,
            .speaker_index = 0,
            .confidence_ppm = 925_000,
        }},
        .first_speakers = .{first_speaker},
        .second_speakers = .{second_speaker},
    };
}

fn writeStateBodyV1(
    state: SpeechAnnotationStateV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &state_magic);
    writeU64(output, 8, state_abi);
    writeU64(output, 16, state_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        state.request_epoch,
        state.next_sequence,
        state.visible_annotations,
        state.visible_words,
        state.visible_speaker_turns,
        state.next_sample,
        state.sample_rate,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        state.audio_media_sha256,
        state.last_transcript_sha256,
        state.previous_result_sha256,
        state.last_speaker_sha256,
        state.policy_sha256,
        state.challenge_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 96 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

fn writePlanBodyV1(
    plan: SpeechAnnotationPlanV1,
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
        plan.segment_index,
        plan.sample_rate,
        plan.publish_start_sample,
        plan.publish_end_sample,
        plan.text_bytes,
        plan.maximum_words,
        plan.maximum_speakers,
        plan.publication_sequence,
        plan.visible_words_before,
        plan.visible_speaker_turns_before,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        plan.transcript_sha256,
        plan.overlap_sha256,
        plan.audio_media_sha256,
        plan.processor_state_sha256,
        plan.cache_payload_sha256,
        plan.text_sha256,
        plan.state_before_sha256,
        plan.previous_result_sha256,
        plan.policy_sha256,
        plan.challenge_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 160 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

fn writeResultBodyV1(
    result: SpeechAnnotationResultV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &result_magic);
    writeU64(output, 8, result_abi);
    writeU64(output, 16, result_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        result.request_epoch,
        result.generation,
        result.segment_index,
        result.sample_rate,
        result.publish_start_sample,
        result.publish_end_sample,
        result.text_bytes,
        result.word_count,
        result.speaker_count,
        result.publication_sequence,
        result.visible_annotations_before,
        result.visible_annotations_after,
        result.visible_words_before,
        result.visible_words_after,
        result.visible_speaker_turns_before,
        result.visible_speaker_turns_after,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        result.transcript_sha256,
        result.overlap_sha256,
        result.audio_media_sha256,
        result.processor_state_sha256,
        result.cache_payload_sha256,
        result.text_sha256,
        result.plan_sha256,
        result.annotation_content_sha256,
        result.state_before_sha256,
        result.previous_result_sha256,
        result.policy_sha256,
        result.challenge_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 160 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
    for (result.words, 0..) |word, index| {
        const start = 544 + index * 48;
        writeU64(output, start, word.text_offset);
        writeU64(output, start + 8, word.text_bytes);
        writeU64(output, start + 16, word.start_sample);
        writeU64(output, start + 24, word.end_sample);
        writeU64(output, start + 32, word.speaker_index);
        writeU64(output, start + 40, word.confidence_ppm);
    }
    for (result.speakers, 0..) |speaker, index| {
        const start = 736 + index * 32;
        @memcpy(output[start .. start + 32], &speaker);
    }
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0)
        return false;
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

fn digestEqual(a: Digest, b: Digest) bool {
    return std.mem.eql(u8, &a, &b);
}

fn isZero(digest: Digest) bool {
    return std.mem.allEqual(u8, &digest, 0);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
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

const TestStorage = struct {
    slots: [8]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 8,
    roots: [8]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 8,
    nodes: [12]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 12,
};

test "speech annotation wires are canonical and mutation complete" {
    const fixture = try makeReferenceFixtureV1();
    const state = fixture.initial_state;
    const plan = try makePlanV1(
        state,
        fixture.first_overlap,
        fixture.first_transcript,
    );
    const result = try makeResultV1(
        state,
        plan,
        fixture.first_overlap,
        fixture.first_transcript,
        &fixture.first_words,
        &fixture.first_speakers,
    );
    var state_wire: [state_bytes]u8 = undefined;
    _ = try encodeStateV1(state, &state_wire);
    var plan_wire: [plan_bytes]u8 = undefined;
    _ = try encodePlanV1(plan, &plan_wire);
    var result_wire: [result_bytes]u8 = undefined;
    _ = try encodeResultV1(result, &result_wire);
    var expected_state: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_state,
        "35343461c17a639e5c28d877d72a5fb4" ++
            "b14603bc8a4adcfab24a18747cbe5b9e",
    );
    var expected_plan: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_plan,
        "2bd1094e8421818e4ad7f31643460fc0" ++
            "053a1c139873c473cedbcb20bf768987",
    );
    var expected_result: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_result,
        "354403f1c299a2e665ec3727d32f9dcd" ++
            "79a40888483e456a2f9eaff4b5b1e2a3",
    );
    try std.testing.expectEqual(
        expected_state,
        state.state_sha256,
    );
    try std.testing.expectEqual(
        expected_plan,
        plan.plan_sha256,
    );
    try std.testing.expectEqual(
        expected_result,
        result.result_sha256,
    );
    try std.testing.expectEqual(
        state,
        try decodeStateV1(&state_wire),
    );
    try std.testing.expectEqual(
        plan,
        try decodePlanV1(&plan_wire),
    );
    try std.testing.expectEqual(
        result,
        try decodeResultV1(&result_wire),
    );
    for (0..state_wire.len) |index| {
        var mutated = state_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidState,
            decodeStateV1(&mutated),
        );
    }
    for (0..plan_wire.len) |index| {
        var mutated = plan_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidPlan,
            decodePlanV1(&mutated),
        );
    }
    for (0..result_wire.len) |index| {
        var mutated = result_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidResult,
            decodeResultV1(&mutated),
        );
    }
}

test "word timing and speaker turns publish atomically" {
    const fixture = try makeReferenceFixtureV1();
    var state = fixture.initial_state;
    var storage: TestStorage = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            131_001,
        );
    const first_plan = try makePlanV1(
        state,
        fixture.first_overlap,
        fixture.first_transcript,
    );
    var first_session: Session = .{};
    try first_session.initV1(
        &bank,
        131_101,
        &state,
        first_plan,
        fixture.first_overlap,
        fixture.first_transcript,
    );
    var candidate: [result_bytes]u8 = undefined;
    var visible = [_]u8{0xa5} ** result_bytes;
    _ = try first_session.prepareV1(
        &fixture.first_words,
        &fixture.first_speakers,
        &candidate,
        &visible,
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &visible, 0xa5),
    );
    const first_result = try first_session.commitV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        state.visible_annotations,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        state.visible_words,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        state.visible_speaker_turns,
    );
    try std.testing.expectEqual(@as(u64, 10), state.next_sample);
    try std.testing.expectEqual(
        first_result,
        try decodeResultV1(&visible),
    );
    try first_session.closeAndRelease();

    const second_plan = try makePlanV1(
        state,
        fixture.second_overlap,
        fixture.second_transcript,
    );
    var second_session: Session = .{};
    try second_session.initV1(
        &bank,
        131_201,
        &state,
        second_plan,
        fixture.second_overlap,
        fixture.second_transcript,
    );
    @memset(&visible, 0x5a);
    _ = try second_session.prepareV1(
        &fixture.second_words,
        &fixture.second_speakers,
        &candidate,
        &visible,
    );
    const second_result = try second_session.commitV1();
    try std.testing.expectEqual(
        @as(u64, 2),
        state.visible_annotations,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        state.visible_words,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        state.visible_speaker_turns,
    );
    try std.testing.expectEqual(@as(u64, 18), state.next_sample);
    try std.testing.expectEqual(
        second_result,
        try decodeResultV1(&visible),
    );
    try second_session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "speech annotation abort drift and substitutions preserve state" {
    const fixture = try makeReferenceFixtureV1();
    var state = fixture.initial_state;
    const state_before = state;
    const plan = try makePlanV1(
        state,
        fixture.first_overlap,
        fixture.first_transcript,
    );
    var foreign_plan = plan;
    foreign_plan.transcript_sha256 =
        model.sha256("foreign transcript");
    foreign_plan.plan_sha256 = planRootV1(foreign_plan);
    try validatePlanV1(foreign_plan);
    try std.testing.expectError(
        Error.InvalidBinding,
        validatePlanBindingsV1(
            state,
            foreign_plan,
            fixture.first_overlap,
            fixture.first_transcript,
        ),
    );
    var foreign_words = fixture.first_words;
    foreign_words[0].end_sample = 9;
    try std.testing.expectError(
        Error.InvalidWordTiming,
        makeResultV1(
            state,
            plan,
            fixture.first_overlap,
            fixture.first_transcript,
            &foreign_words,
            &fixture.first_speakers,
        ),
    );
    var storage: TestStorage = .{};
    var bank =
        try resource_bank.Bank.initWithLeaseTreeStorage(
            &storage.slots,
            &storage.roots,
            &storage.nodes,
            .{},
            131_001,
        );
    var session: Session = .{};
    try session.initV1(
        &bank,
        131_101,
        &state,
        plan,
        fixture.first_overlap,
        fixture.first_transcript,
    );
    var candidate: [result_bytes]u8 = undefined;
    var visible = [_]u8{0xa5} ** result_bytes;
    _ = try session.prepareV1(
        &fixture.first_words,
        &fixture.first_speakers,
        &candidate,
        &visible,
    );
    candidate[160] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(state_before, state);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &visible, 0xa5),
    );
    _ = try session.prepareV1(
        &fixture.first_words,
        &fixture.first_speakers,
        &candidate,
        &visible,
    );
    try session.abortV1();
    try std.testing.expectEqual(state_before, state);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}

test "multi-word speaker palette follows first occurrence" {
    const fixture = try makeReferenceFixtureV1();
    var overlap = fixture.first_overlap;
    overlap.source_end_sample = 18;
    overlap.publish_end_sample = 18;
    overlap.window_samples = 18;
    overlap.hop_samples = 16;
    overlap.overlap_sha256 =
        audio.overlapPlanRootV1(overlap);
    try audio.validateOverlapPlanV1(overlap);
    const transcript =
        try audio.makeTranscriptSegmentV1(
            overlap,
            "ice berg",
        );
    const plan = try makePlanV1(
        fixture.initial_state,
        overlap,
        transcript,
    );
    const words = [_]WordTimingV1{
        .{
            .text_offset = 0,
            .text_bytes = 3,
            .start_sample = 2,
            .end_sample = 10,
            .speaker_index = 0,
            .confidence_ppm = 950_000,
        },
        .{
            .text_offset = 4,
            .text_bytes = 4,
            .start_sample = 10,
            .end_sample = 18,
            .speaker_index = 1,
            .confidence_ppm = 925_000,
        },
    };
    const speakers = [_]Digest{
        fixture.first_speakers[0],
        fixture.second_speakers[0],
    };
    const result = try makeResultV1(
        fixture.initial_state,
        plan,
        overlap,
        transcript,
        &words,
        &speakers,
    );
    try std.testing.expectEqual(@as(u64, 2), result.word_count);
    try std.testing.expectEqual(@as(u64, 2), result.speaker_count);
    try std.testing.expectEqual(
        @as(u64, 2),
        result.visible_speaker_turns_after,
    );
    var reversed = words;
    reversed[0].speaker_index = 1;
    reversed[1].speaker_index = 0;
    try std.testing.expectError(
        Error.InvalidSpeakerAttribution,
        makeResultV1(
            fixture.initial_state,
            plan,
            overlap,
            transcript,
            &reversed,
            &speakers,
        ),
    );
}
