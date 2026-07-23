const std = @import("std");
const resource_bank = @import("resource_bank.zig");
const model = @import("model_contract.zig");
const segment_adapter = @import("video_segment_adapter.zig");

const Digest = [32]u8;

pub const timeline_abi: u64 = 0x4756_544c_4e00_0001;
pub const merge_receipt_abi: u64 = 0x4756_4d52_4700_0001;
pub const timeline_bytes: usize = 384;
pub const merge_receipt_bytes: usize = 384;
const timeline_body_bytes = timeline_bytes - 32;
const merge_receipt_body_bytes = merge_receipt_bytes - 32;
const allowed_flags: u64 = 0;
const timeline_magic = [_]u8{
    'G', 'V', 'T', 'L', 'N', '1', 0, 0,
};
const merge_receipt_magic = [_]u8{
    'G', 'V', 'M', 'R', 'G', '1', 0, 0,
};
const timeline_domain =
    "glacier-video-segment-timeline-v1\x00";
const merge_receipt_domain =
    "glacier-video-segment-merge-receipt-v1\x00";
const policy_domain =
    "glacier-video-segment-merge-policy-v1\x00";

pub const Error = resource_bank.Error ||
    segment_adapter.Error || error{
    InvalidState,
    InvalidTimeline,
    InvalidMergeInput,
    InvalidMergeReceipt,
    BufferTooSmall,
    BufferAlias,
    CandidateDrift,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
};

pub const MergeActionV1 = enum(u64) {
    coalesce = 1,
    retain_distinct = 2,
};

pub const Phase = enum(u8) {
    idle = 0,
    prepared = 1,
    poisoned = 2,
    closed = 3,
};

pub const VideoSegmentTimelineV1 = struct {
    request_epoch: u64,
    next_sequence: u64,
    decision_count: u64,
    visible_segments: u64,
    tail_segment_index: u64,
    tail_first_frame: u64,
    tail_last_frame: u64,
    target_numerator: u64,
    target_denominator: u64,
    tail_start_tick: u64,
    tail_end_tick: u64,
    tail_event_id: u64,
    tail_confidence_ppm: u64,
    media_object_sha256: Digest,
    challenge_sha256: Digest,
    tail_segment_sha256: Digest,
    previous_decision_sha256: Digest,
    policy_sha256: Digest,
    timeline_sha256: Digest,
};

pub const VideoSegmentMergeReceiptV1 = struct {
    request_epoch: u64,
    decision_sequence: u64,
    previous_segment_index: u64,
    incoming_segment_index: u64,
    action: MergeActionV1,
    output_first_frame: u64,
    output_last_frame: u64,
    target_numerator: u64,
    target_denominator: u64,
    output_start_tick: u64,
    output_end_tick: u64,
    output_event_id: u64,
    output_confidence_ppm: u64,
    input_overlap_ticks: u64,
    replaced_tail_count: u64,
    visible_segment_delta: u64,
    media_object_sha256: Digest,
    challenge_sha256: Digest,
    previous_segment_sha256: Digest,
    incoming_segment_sha256: Digest,
    previous_decision_sha256: Digest,
    policy_sha256: Digest,
    receipt_sha256: Digest,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    state: *VideoSegmentTimelineV1 = undefined,
    receipt: resource_bank.Receipt = undefined,
    permit: ?resource_bank.PublicationPermit = null,
    previous: segment_adapter.VideoSegmentV1 = undefined,
    incoming: segment_adapter.VideoSegmentV1 = undefined,
    prepared_receipt: ?VideoSegmentMergeReceiptV1 = null,
    candidate: ?[]u8 = null,
    visible_output: ?[]u8 = null,
    expected_candidate_sha256: Digest = [_]u8{0} ** 32,
    expected_timeline_sha256: Digest = [_]u8{0} ** 32,
    next_resource_sequence: u64 = 0,
    initialized: bool = false,
    phase: Phase = .idle,

    pub fn initV1(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        state: *VideoSegmentTimelineV1,
    ) Error!void {
        if (self.initialized or owner_key == 0)
            return Error.InvalidState;
        try validateTimelineV1(state.*);
        const reservation = bank.reserve(
            owner_key,
            mergeClaimV1(),
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
        previous: segment_adapter.VideoSegmentV1,
        incoming: segment_adapter.VideoSegmentV1,
        candidate: []u8,
        visible_output: []u8,
    ) Error!VideoSegmentMergeReceiptV1 {
        if (!self.initialized or self.phase != .idle or
            self.permit != null or self.prepared_receipt != null)
            return Error.InvalidState;
        try validateTimelineV1(self.state.*);
        const expected = try makeMergeReceiptV1(
            self.state.*,
            previous,
            incoming,
        );
        if (candidate.len < merge_receipt_bytes or
            visible_output.len < merge_receipt_bytes)
            return Error.BufferTooSmall;
        const candidate_slice = candidate[0..merge_receipt_bytes];
        const visible_slice =
            visible_output[0..merge_receipt_bytes];
        if (slicesOverlap(candidate_slice, visible_slice))
            return Error.BufferAlias;
        @memset(candidate_slice, 0);
        @memset(visible_slice, 0);
        const permit = self.bank.beginPublication(
            self.receipt,
            self.state.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        var encoded: [merge_receipt_bytes]u8 = undefined;
        _ = encodeMergeReceiptV1(
            expected,
            &encoded,
        ) catch {
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.InvalidMergeReceipt;
        };
        @memcpy(candidate_slice, &encoded);
        self.permit = permit;
        self.previous = previous;
        self.incoming = incoming;
        self.prepared_receipt = expected;
        self.candidate = candidate_slice;
        self.visible_output = visible_slice;
        self.expected_candidate_sha256 =
            model.sha256(candidate_slice);
        self.expected_timeline_sha256 =
            self.state.timeline_sha256;
        self.phase = .prepared;
        return expected;
    }

    pub fn commitV1(
        self: *Session,
    ) Error!VideoSegmentMergeReceiptV1 {
        if (!self.initialized or self.phase != .prepared)
            return Error.InvalidState;
        const permit = self.permit orelse
            return Error.InvalidState;
        const expected = self.prepared_receipt orelse
            return Error.InvalidState;
        const candidate = self.candidate orelse
            return Error.InvalidState;
        const visible = self.visible_output orelse
            return Error.InvalidState;
        self.bank.validatePublication(permit) catch {
            try self.rollbackV1(permit);
            return Error.ResourceReceiptInvalid;
        };
        validateTimelineV1(self.state.*) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.mem.eql(
            u8,
            &self.state.timeline_sha256,
            &self.expected_timeline_sha256,
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
        const decoded = decodeMergeReceiptV1(candidate) catch {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        };
        if (!std.meta.eql(decoded, expected)) {
            try self.rollbackV1(permit);
            return Error.CandidateDrift;
        }
        const next_state = applyMergeReceiptV1(
            self.state.*,
            self.previous,
            self.incoming,
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
        self.prepared_receipt = null;
        self.candidate = null;
        self.visible_output = null;
        self.expected_candidate_sha256 = [_]u8{0} ** 32;
        self.expected_timeline_sha256 = [_]u8{0} ** 32;
    }
};

pub fn mergeClaimV1() resource_bank.Claim {
    return .{
        .partial_bytes = merge_receipt_bytes,
        .output_journal_bytes = merge_receipt_bytes,
        .queue_slots = 1,
    };
}

pub fn mergePolicyRootV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(policy_domain);
    hashU64(&hash, 1);
    hashU64(&hash, @intFromEnum(MergeActionV1.coalesce));
    hashU64(
        &hash,
        @intFromEnum(MergeActionV1.retain_distinct),
    );
    return hash.finalResult();
}

pub fn initializeTimelineV1(
    initial: segment_adapter.VideoSegmentV1,
    genesis_decision_sha256: Digest,
) Error!VideoSegmentTimelineV1 {
    try segment_adapter.validateVideoSegmentV1(initial);
    if (isZero(genesis_decision_sha256))
        return Error.InvalidTimeline;
    var timeline: VideoSegmentTimelineV1 = .{
        .request_epoch = initial.request_epoch,
        .next_sequence = 0,
        .decision_count = 0,
        .visible_segments = 1,
        .tail_segment_index = initial.segment_index,
        .tail_first_frame = initial.first_frame,
        .tail_last_frame = initial.last_frame,
        .target_numerator = initial.target_base.numerator,
        .target_denominator = initial.target_base.denominator,
        .tail_start_tick = initial.target_start_tick,
        .tail_end_tick = initial.target_end_tick,
        .tail_event_id = initial.event_id,
        .tail_confidence_ppm = initial.confidence_ppm,
        .media_object_sha256 = initial.media_object_sha256,
        .challenge_sha256 = initial.challenge_sha256,
        .tail_segment_sha256 = initial.segment_sha256,
        .previous_decision_sha256 = genesis_decision_sha256,
        .policy_sha256 = mergePolicyRootV1(),
        .timeline_sha256 = [_]u8{0} ** 32,
    };
    timeline.timeline_sha256 = timelineRootV1(timeline);
    try validateTimelineV1(timeline);
    return timeline;
}

pub fn makeMergeReceiptV1(
    timeline: VideoSegmentTimelineV1,
    previous: segment_adapter.VideoSegmentV1,
    incoming: segment_adapter.VideoSegmentV1,
) Error!VideoSegmentMergeReceiptV1 {
    try validateMergeInputsV1(
        timeline,
        previous,
        incoming,
    );
    const overlaps_or_touches =
        incoming.target_start_tick <= timeline.tail_end_tick;
    const same_event =
        incoming.event_id == timeline.tail_event_id;
    const action: MergeActionV1 =
        if (overlaps_or_touches and same_event)
            .coalesce
        else
            .retain_distinct;
    const coalesced = action == .coalesce;
    const output_first_frame =
        if (coalesced)
            timeline.tail_first_frame
        else
            incoming.first_frame;
    const output_last_frame =
        if (coalesced)
            @max(
                timeline.tail_last_frame,
                incoming.last_frame,
            )
        else
            incoming.last_frame;
    const output_start_tick =
        if (coalesced)
            timeline.tail_start_tick
        else
            incoming.target_start_tick;
    const output_end_tick =
        if (coalesced)
            @max(
                timeline.tail_end_tick,
                incoming.target_end_tick,
            )
        else
            incoming.target_end_tick;
    const output_event_id =
        if (coalesced)
            timeline.tail_event_id
        else
            incoming.event_id;
    const output_confidence_ppm =
        if (coalesced)
            @max(
                timeline.tail_confidence_ppm,
                incoming.confidence_ppm,
            )
        else
            incoming.confidence_ppm;
    const input_overlap_ticks =
        if (incoming.target_start_tick < timeline.tail_end_tick)
            timeline.tail_end_tick -
                incoming.target_start_tick
        else
            0;
    var receipt: VideoSegmentMergeReceiptV1 = .{
        .request_epoch = timeline.request_epoch,
        .decision_sequence = timeline.next_sequence,
        .previous_segment_index = previous.segment_index,
        .incoming_segment_index = incoming.segment_index,
        .action = action,
        .output_first_frame = output_first_frame,
        .output_last_frame = output_last_frame,
        .target_numerator = timeline.target_numerator,
        .target_denominator = timeline.target_denominator,
        .output_start_tick = output_start_tick,
        .output_end_tick = output_end_tick,
        .output_event_id = output_event_id,
        .output_confidence_ppm = output_confidence_ppm,
        .input_overlap_ticks = input_overlap_ticks,
        .replaced_tail_count = if (coalesced) 1 else 0,
        .visible_segment_delta = if (coalesced) 0 else 1,
        .media_object_sha256 = timeline.media_object_sha256,
        .challenge_sha256 = timeline.challenge_sha256,
        .previous_segment_sha256 = previous.segment_sha256,
        .incoming_segment_sha256 = incoming.segment_sha256,
        .previous_decision_sha256 = timeline.previous_decision_sha256,
        .policy_sha256 = timeline.policy_sha256,
        .receipt_sha256 = [_]u8{0} ** 32,
    };
    receipt.receipt_sha256 = mergeReceiptRootV1(receipt);
    try validateMergeReceiptV1(receipt);
    return receipt;
}

pub fn applyMergeReceiptV1(
    timeline: VideoSegmentTimelineV1,
    previous: segment_adapter.VideoSegmentV1,
    incoming: segment_adapter.VideoSegmentV1,
    receipt: VideoSegmentMergeReceiptV1,
) Error!VideoSegmentTimelineV1 {
    try validateTimelineV1(timeline);
    const expected = try makeMergeReceiptV1(
        timeline,
        previous,
        incoming,
    );
    if (!std.meta.eql(expected, receipt))
        return Error.InvalidMergeReceipt;
    var next = timeline;
    next.next_sequence = checkedAdd(
        timeline.next_sequence,
        1,
    ) catch return Error.InvalidTimeline;
    next.decision_count = checkedAdd(
        timeline.decision_count,
        1,
    ) catch return Error.InvalidTimeline;
    next.visible_segments = checkedAdd(
        timeline.visible_segments,
        receipt.visible_segment_delta,
    ) catch return Error.InvalidTimeline;
    next.tail_segment_index = incoming.segment_index;
    next.tail_first_frame = receipt.output_first_frame;
    next.tail_last_frame = receipt.output_last_frame;
    next.tail_start_tick = receipt.output_start_tick;
    next.tail_end_tick = receipt.output_end_tick;
    next.tail_event_id = receipt.output_event_id;
    next.tail_confidence_ppm =
        receipt.output_confidence_ppm;
    next.tail_segment_sha256 = incoming.segment_sha256;
    next.previous_decision_sha256 =
        receipt.receipt_sha256;
    next.timeline_sha256 = timelineRootV1(next);
    try validateTimelineV1(next);
    return next;
}

pub fn validateTimelineV1(
    timeline: VideoSegmentTimelineV1,
) Error!void {
    const maximum_visible = std.math.add(
        u64,
        timeline.decision_count,
        1,
    ) catch return Error.InvalidTimeline;
    if (timeline.request_epoch == 0 or
        timeline.visible_segments == 0 or
        timeline.tail_segment_index == 0 or
        timeline.tail_first_frame >
            timeline.tail_last_frame or
        timeline.target_numerator == 0 or
        timeline.target_denominator == 0 or
        timeline.tail_start_tick >= timeline.tail_end_tick or
        timeline.tail_event_id == 0 or
        timeline.tail_confidence_ppm > 1_000_000 or
        timeline.next_sequence != timeline.decision_count or
        timeline.visible_segments > maximum_visible or
        isZero(timeline.media_object_sha256) or
        isZero(timeline.challenge_sha256) or
        isZero(timeline.tail_segment_sha256) or
        isZero(timeline.previous_decision_sha256) or
        !std.mem.eql(
            u8,
            &timeline.policy_sha256,
            &mergePolicyRootV1(),
        ) or
        !std.mem.eql(
            u8,
            &timeline.timeline_sha256,
            &timelineRootV1(timeline),
        ))
        return Error.InvalidTimeline;
}

pub fn validateMergeReceiptV1(
    receipt: VideoSegmentMergeReceiptV1,
) Error!void {
    const action = receipt.action;
    const expected_incoming_index = std.math.add(
        u64,
        receipt.previous_segment_index,
        1,
    ) catch return Error.InvalidMergeReceipt;
    if (receipt.request_epoch == 0 or
        receipt.previous_segment_index == 0 or
        receipt.incoming_segment_index == 0 or
        receipt.incoming_segment_index !=
            expected_incoming_index or
        receipt.output_first_frame >
            receipt.output_last_frame or
        receipt.target_numerator == 0 or
        receipt.target_denominator == 0 or
        receipt.output_start_tick >= receipt.output_end_tick or
        receipt.output_event_id == 0 or
        receipt.output_confidence_ppm > 1_000_000 or
        (action == .coalesce and
            (receipt.replaced_tail_count != 1 or
                receipt.visible_segment_delta != 0)) or
        (action == .retain_distinct and
            (receipt.replaced_tail_count != 0 or
                receipt.visible_segment_delta != 1)) or
        isZero(receipt.media_object_sha256) or
        isZero(receipt.challenge_sha256) or
        isZero(receipt.previous_segment_sha256) or
        isZero(receipt.incoming_segment_sha256) or
        isZero(receipt.previous_decision_sha256) or
        !std.mem.eql(
            u8,
            &receipt.policy_sha256,
            &mergePolicyRootV1(),
        ) or
        !std.mem.eql(
            u8,
            &receipt.receipt_sha256,
            &mergeReceiptRootV1(receipt),
        ))
        return Error.InvalidMergeReceipt;
}

pub fn validateMergeInputsV1(
    timeline: VideoSegmentTimelineV1,
    previous: segment_adapter.VideoSegmentV1,
    incoming: segment_adapter.VideoSegmentV1,
) Error!void {
    try validateTimelineV1(timeline);
    segment_adapter.validateVideoSegmentV1(previous) catch
        return Error.InvalidMergeInput;
    segment_adapter.validateVideoSegmentV1(incoming) catch
        return Error.InvalidMergeInput;
    const expected_index = checkedAdd(
        previous.segment_index,
        1,
    ) catch return Error.InvalidMergeInput;
    if (timeline.request_epoch != previous.request_epoch or
        timeline.request_epoch != incoming.request_epoch or
        timeline.tail_segment_index !=
            previous.segment_index or
        incoming.segment_index != expected_index or
        incoming.generation < previous.generation or
        timeline.target_numerator !=
            previous.target_base.numerator or
        timeline.target_denominator !=
            previous.target_base.denominator or
        timeline.target_numerator !=
            incoming.target_base.numerator or
        timeline.target_denominator !=
            incoming.target_base.denominator or
        incoming.first_frame < timeline.tail_first_frame or
        incoming.target_start_tick <
            timeline.tail_start_tick or
        timeline.tail_first_frame > previous.first_frame or
        timeline.tail_last_frame < previous.last_frame or
        timeline.tail_start_tick >
            previous.target_start_tick or
        timeline.tail_end_tick < previous.target_end_tick or
        timeline.tail_event_id != previous.event_id or
        timeline.tail_confidence_ppm <
            previous.confidence_ppm or
        !std.mem.eql(
            u8,
            &timeline.media_object_sha256,
            &previous.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &timeline.media_object_sha256,
            &incoming.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &timeline.challenge_sha256,
            &previous.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &timeline.challenge_sha256,
            &incoming.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &timeline.tail_segment_sha256,
            &previous.segment_sha256,
        ) or
        !std.mem.eql(
            u8,
            &incoming.previous_segment_sha256,
            &previous.segment_sha256,
        ))
        return Error.InvalidMergeInput;
}

pub fn encodeTimelineV1(
    timeline: VideoSegmentTimelineV1,
    output: *[timeline_bytes]u8,
) Error![]const u8 {
    try validateTimelineV1(timeline);
    writeTimelineBodyV1(
        timeline,
        output[0..timeline_body_bytes],
    );
    @memcpy(
        output[timeline_body_bytes..],
        &timeline.timeline_sha256,
    );
    return output;
}

pub fn decodeTimelineV1(
    encoded: []const u8,
) Error!VideoSegmentTimelineV1 {
    if (encoded.len != timeline_bytes or
        !std.mem.eql(u8, encoded[0..8], &timeline_magic) or
        readU64(encoded, 8) != timeline_abi or
        readU64(encoded, 16) != timeline_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[136..160], 0) or
        !std.mem.allEqual(u8, encoded[320..352], 0))
        return Error.InvalidTimeline;
    const timeline: VideoSegmentTimelineV1 = .{
        .request_epoch = readU64(encoded, 32),
        .next_sequence = readU64(encoded, 40),
        .decision_count = readU64(encoded, 48),
        .visible_segments = readU64(encoded, 56),
        .tail_segment_index = readU64(encoded, 64),
        .tail_first_frame = readU64(encoded, 72),
        .tail_last_frame = readU64(encoded, 80),
        .target_numerator = readU64(encoded, 88),
        .target_denominator = readU64(encoded, 96),
        .tail_start_tick = readU64(encoded, 104),
        .tail_end_tick = readU64(encoded, 112),
        .tail_event_id = readU64(encoded, 120),
        .tail_confidence_ppm = readU64(encoded, 128),
        .media_object_sha256 = encoded[160..192].*,
        .challenge_sha256 = encoded[192..224].*,
        .tail_segment_sha256 = encoded[224..256].*,
        .previous_decision_sha256 = encoded[256..288].*,
        .policy_sha256 = encoded[288..320].*,
        .timeline_sha256 = encoded[timeline_body_bytes..timeline_bytes].*,
    };
    try validateTimelineV1(timeline);
    var canonical: [timeline_bytes]u8 = undefined;
    _ = try encodeTimelineV1(timeline, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidTimeline;
    return timeline;
}

pub fn encodeMergeReceiptV1(
    receipt: VideoSegmentMergeReceiptV1,
    output: *[merge_receipt_bytes]u8,
) Error![]const u8 {
    try validateMergeReceiptV1(receipt);
    writeMergeReceiptBodyV1(
        receipt,
        output[0..merge_receipt_body_bytes],
    );
    @memcpy(
        output[merge_receipt_body_bytes..],
        &receipt.receipt_sha256,
    );
    return output;
}

pub fn decodeMergeReceiptV1(
    encoded: []const u8,
) Error!VideoSegmentMergeReceiptV1 {
    if (encoded.len != merge_receipt_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &merge_receipt_magic,
        ) or
        readU64(encoded, 8) != merge_receipt_abi or
        readU64(encoded, 16) != merge_receipt_bytes or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidMergeReceipt;
    const action = std.meta.intToEnum(
        MergeActionV1,
        readU64(encoded, 64),
    ) catch return Error.InvalidMergeReceipt;
    const receipt: VideoSegmentMergeReceiptV1 = .{
        .request_epoch = readU64(encoded, 32),
        .decision_sequence = readU64(encoded, 40),
        .previous_segment_index = readU64(encoded, 48),
        .incoming_segment_index = readU64(encoded, 56),
        .action = action,
        .output_first_frame = readU64(encoded, 72),
        .output_last_frame = readU64(encoded, 80),
        .target_numerator = readU64(encoded, 88),
        .target_denominator = readU64(encoded, 96),
        .output_start_tick = readU64(encoded, 104),
        .output_end_tick = readU64(encoded, 112),
        .output_event_id = readU64(encoded, 120),
        .output_confidence_ppm = readU64(encoded, 128),
        .input_overlap_ticks = readU64(encoded, 136),
        .replaced_tail_count = readU64(encoded, 144),
        .visible_segment_delta = readU64(encoded, 152),
        .media_object_sha256 = encoded[160..192].*,
        .challenge_sha256 = encoded[192..224].*,
        .previous_segment_sha256 = encoded[224..256].*,
        .incoming_segment_sha256 = encoded[256..288].*,
        .previous_decision_sha256 = encoded[288..320].*,
        .policy_sha256 = encoded[320..352].*,
        .receipt_sha256 = encoded[merge_receipt_body_bytes..merge_receipt_bytes].*,
    };
    try validateMergeReceiptV1(receipt);
    var canonical: [merge_receipt_bytes]u8 = undefined;
    _ = try encodeMergeReceiptV1(receipt, &canonical);
    if (!std.mem.eql(u8, encoded, &canonical))
        return Error.InvalidMergeReceipt;
    return receipt;
}

pub fn timelineRootV1(
    timeline: VideoSegmentTimelineV1,
) Digest {
    var body: [timeline_body_bytes]u8 = undefined;
    writeTimelineBodyV1(timeline, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(timeline_domain);
    hash.update(&body);
    return hash.finalResult();
}

pub fn mergeReceiptRootV1(
    receipt: VideoSegmentMergeReceiptV1,
) Digest {
    var body: [merge_receipt_body_bytes]u8 = undefined;
    writeMergeReceiptBodyV1(receipt, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(merge_receipt_domain);
    hash.update(&body);
    return hash.finalResult();
}

fn writeTimelineBodyV1(
    timeline: VideoSegmentTimelineV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &timeline_magic);
    writeU64(output, 8, timeline_abi);
    writeU64(output, 16, timeline_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        timeline.request_epoch,
        timeline.next_sequence,
        timeline.decision_count,
        timeline.visible_segments,
        timeline.tail_segment_index,
        timeline.tail_first_frame,
        timeline.tail_last_frame,
        timeline.target_numerator,
        timeline.target_denominator,
        timeline.tail_start_tick,
        timeline.tail_end_tick,
        timeline.tail_event_id,
        timeline.tail_confidence_ppm,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        timeline.media_object_sha256,
        timeline.challenge_sha256,
        timeline.tail_segment_sha256,
        timeline.previous_decision_sha256,
        timeline.policy_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 160 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

fn writeMergeReceiptBodyV1(
    receipt: VideoSegmentMergeReceiptV1,
    output: []u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &merge_receipt_magic);
    writeU64(output, 8, merge_receipt_abi);
    writeU64(output, 16, merge_receipt_bytes);
    writeU64(output, 24, allowed_flags);
    const scalars = [_]u64{
        receipt.request_epoch,
        receipt.decision_sequence,
        receipt.previous_segment_index,
        receipt.incoming_segment_index,
        @intFromEnum(receipt.action),
        receipt.output_first_frame,
        receipt.output_last_frame,
        receipt.target_numerator,
        receipt.target_denominator,
        receipt.output_start_tick,
        receipt.output_end_tick,
        receipt.output_event_id,
        receipt.output_confidence_ppm,
        receipt.input_overlap_ticks,
        receipt.replaced_tail_count,
        receipt.visible_segment_delta,
    };
    for (scalars, 0..) |value, index|
        writeU64(output, 32 + index * 8, value);
    const digests = [_]Digest{
        receipt.media_object_sha256,
        receipt.challenge_sha256,
        receipt.previous_segment_sha256,
        receipt.incoming_segment_sha256,
        receipt.previous_decision_sha256,
        receipt.policy_sha256,
    };
    for (digests, 0..) |digest, index| {
        const start = 160 + index * 32;
        @memcpy(output[start .. start + 32], &digest);
    }
}

fn checkedAdd(left: u64, right: u64) !u64 {
    return std.math.add(u64, left, right);
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

fn testSegment(
    segment_index: u64,
    first_frame: u64,
    last_frame: u64,
    start_tick: u64,
    end_tick: u64,
    event_id: u64,
    confidence_ppm: u64,
    previous_segment_sha256: Digest,
) !segment_adapter.VideoSegmentV1 {
    var value: segment_adapter.VideoSegmentV1 = .{
        .request_epoch = 221,
        .generation = 7,
        .segment_index = segment_index,
        .first_frame = first_frame,
        .last_frame = last_frame,
        .frame_count = last_frame - first_frame + 1,
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
        .event_id = event_id,
        .confidence_ppm = confidence_ppm,
        .media_object_sha256 = model.sha256("timeline media"),
        .processor_state_sha256 = model.sha256("timeline processor"),
        .processor_bundle_sha256 = model.sha256("timeline processor bundle"),
        .cache_bundle_sha256 = model.sha256("timeline cache bundle"),
        .cache_payload_sha256 = model.sha256("timeline cache payload"),
        .ownership_sha256 = model.sha256("timeline ownership"),
        .selection_sha256 = model.sha256("timeline selection"),
        .challenge_sha256 = model.sha256("timeline challenge"),
        .previous_segment_sha256 = previous_segment_sha256,
        .segment_sha256 = [_]u8{0} ** 32,
    };
    value.segment_sha256 =
        segment_adapter.videoSegmentRootV1(value);
    try segment_adapter.validateVideoSegmentV1(value);
    return value;
}

test "timeline and merge receipt wires reject every mutation" {
    const first = try testSegment(
        1,
        0,
        9,
        0,
        10,
        7,
        600_000,
        model.sha256("segment genesis"),
    );
    const second = try testSegment(
        2,
        8,
        15,
        8,
        16,
        7,
        700_000,
        first.segment_sha256,
    );
    const timeline = try initializeTimelineV1(
        first,
        model.sha256("decision genesis"),
    );
    const receipt = try makeMergeReceiptV1(
        timeline,
        first,
        second,
    );
    var expected_timeline: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_timeline,
        "81e3e59397afb89fc38a772a7bd6dfba" ++
            "716275365a10f4d130afb3165c59ccbd",
    );
    try std.testing.expectEqual(
        expected_timeline,
        timeline.timeline_sha256,
    );
    var expected_receipt: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_receipt,
        "11e668efb1cc13432dda079d2341bc73" ++
            "ccbbf84b8c19b64a0ff842cca3f43319",
    );
    try std.testing.expectEqual(
        expected_receipt,
        receipt.receipt_sha256,
    );
    var timeline_wire: [timeline_bytes]u8 = undefined;
    _ = try encodeTimelineV1(timeline, &timeline_wire);
    try std.testing.expectEqual(
        timeline,
        try decodeTimelineV1(&timeline_wire),
    );
    for (0..timeline_wire.len) |index| {
        var mutated = timeline_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidTimeline,
            decodeTimelineV1(&mutated),
        );
    }
    var receipt_wire: [merge_receipt_bytes]u8 = undefined;
    _ = try encodeMergeReceiptV1(receipt, &receipt_wire);
    try std.testing.expectEqual(
        receipt,
        try decodeMergeReceiptV1(&receipt_wire),
    );
    for (0..receipt_wire.len) |index| {
        var mutated = receipt_wire;
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidMergeReceipt,
            decodeMergeReceiptV1(&mutated),
        );
    }
}

test "timeline coalesces overlap and retains deterministic gaps" {
    const first = try testSegment(
        1,
        0,
        9,
        0,
        10,
        7,
        600_000,
        model.sha256("segment genesis"),
    );
    const second = try testSegment(
        2,
        8,
        15,
        8,
        16,
        7,
        700_000,
        first.segment_sha256,
    );
    var timeline = try initializeTimelineV1(
        first,
        model.sha256("decision genesis"),
    );
    const merge = try makeMergeReceiptV1(
        timeline,
        first,
        second,
    );
    try std.testing.expectEqual(
        MergeActionV1.coalesce,
        merge.action,
    );
    try std.testing.expectEqual(@as(u64, 2), merge.input_overlap_ticks);
    try std.testing.expectEqual(@as(u64, 0), merge.output_start_tick);
    try std.testing.expectEqual(@as(u64, 16), merge.output_end_tick);
    try std.testing.expectEqual(
        @as(u64, 700_000),
        merge.output_confidence_ppm,
    );
    timeline = try applyMergeReceiptV1(
        timeline,
        first,
        second,
        merge,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        timeline.visible_segments,
    );
    const third = try testSegment(
        3,
        20,
        24,
        20,
        25,
        7,
        650_000,
        second.segment_sha256,
    );
    const retain = try makeMergeReceiptV1(
        timeline,
        second,
        third,
    );
    try std.testing.expectEqual(
        MergeActionV1.retain_distinct,
        retain.action,
    );
    timeline = try applyMergeReceiptV1(
        timeline,
        second,
        third,
        retain,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        timeline.visible_segments,
    );
    try std.testing.expectEqual(
        @as(u64, 20),
        timeline.tail_start_tick,
    );
    const fourth = try testSegment(
        4,
        23,
        29,
        23,
        30,
        8,
        900_000,
        third.segment_sha256,
    );
    const distinct_event = try makeMergeReceiptV1(
        timeline,
        third,
        fourth,
    );
    try std.testing.expectEqual(
        MergeActionV1.retain_distinct,
        distinct_event.action,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        distinct_event.input_overlap_ticks,
    );
    timeline = try applyMergeReceiptV1(
        timeline,
        third,
        fourth,
        distinct_event,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        timeline.visible_segments,
    );
    try std.testing.expectEqual(
        @as(u64, 8),
        timeline.tail_event_id,
    );
}

test "timeline rejects foreign lineage and out of order successors" {
    const first = try testSegment(
        1,
        0,
        9,
        0,
        10,
        7,
        600_000,
        model.sha256("segment genesis"),
    );
    const timeline = try initializeTimelineV1(
        first,
        model.sha256("decision genesis"),
    );
    const out_of_order = try testSegment(
        3,
        8,
        15,
        8,
        16,
        7,
        700_000,
        first.segment_sha256,
    );
    try std.testing.expectError(
        Error.InvalidMergeInput,
        makeMergeReceiptV1(
            timeline,
            first,
            out_of_order,
        ),
    );
    var foreign = try testSegment(
        2,
        8,
        15,
        8,
        16,
        7,
        700_000,
        first.segment_sha256,
    );
    foreign.media_object_sha256 =
        model.sha256("foreign timeline media");
    foreign.segment_sha256 =
        segment_adapter.videoSegmentRootV1(foreign);
    try segment_adapter.validateVideoSegmentV1(foreign);
    try std.testing.expectError(
        Error.InvalidMergeInput,
        makeMergeReceiptV1(
            timeline,
            first,
            foreign,
        ),
    );
    var foreign_predecessor = try testSegment(
        2,
        8,
        15,
        8,
        16,
        7,
        700_000,
        model.sha256("foreign raw predecessor"),
    );
    foreign_predecessor.segment_sha256 =
        segment_adapter.videoSegmentRootV1(
            foreign_predecessor,
        );
    try segment_adapter.validateVideoSegmentV1(
        foreign_predecessor,
    );
    try std.testing.expectError(
        Error.InvalidMergeInput,
        makeMergeReceiptV1(
            timeline,
            first,
            foreign_predecessor,
        ),
    );
}

test "merge session abort commit drift and release are atomic" {
    const first = try testSegment(
        1,
        0,
        9,
        0,
        10,
        7,
        600_000,
        model.sha256("segment genesis"),
    );
    const second = try testSegment(
        2,
        8,
        15,
        8,
        16,
        7,
        700_000,
        first.segment_sha256,
    );
    var timeline = try initializeTimelineV1(
        first,
        model.sha256("decision genesis"),
    );
    const initial_root = timeline.timeline_sha256;
    var slots: [2]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{},
        991,
    );
    var session: Session = .{};
    try session.initV1(&bank, 77_001, &timeline);
    var candidate: [merge_receipt_bytes]u8 = undefined;
    var output: [merge_receipt_bytes]u8 = undefined;
    _ = try session.prepareV1(
        first,
        second,
        &candidate,
        &output,
    );
    try session.abortV1();
    try std.testing.expectEqual(
        initial_root,
        timeline.timeline_sha256,
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0));
    const prepared = try session.prepareV1(
        first,
        second,
        &candidate,
        &output,
    );
    const committed = try session.commitV1();
    try std.testing.expectEqual(prepared, committed);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expectEqual(
        committed,
        try decodeMergeReceiptV1(&output),
    );
    const after_commit = timeline;
    const third = try testSegment(
        3,
        14,
        19,
        14,
        20,
        7,
        650_000,
        second.segment_sha256,
    );
    var next_output: [merge_receipt_bytes]u8 = undefined;
    _ = try session.prepareV1(
        second,
        third,
        &candidate,
        &next_output,
    );
    candidate[120] ^= 1;
    try std.testing.expectError(
        Error.CandidateDrift,
        session.commitV1(),
    );
    try std.testing.expectEqual(after_commit, timeline);
    try std.testing.expect(
        std.mem.allEqual(u8, &candidate, 0),
    );
    try std.testing.expect(
        std.mem.allEqual(u8, &next_output, 0),
    );
    const retried = try session.prepareV1(
        second,
        third,
        &candidate,
        &next_output,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        retried.decision_sequence,
    );
    _ = try session.commitV1();
    try std.testing.expectEqual(
        @as(u64, 2),
        timeline.decision_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        timeline.visible_segments,
    );
    try std.testing.expectEqual(
        @as(u64, 20),
        timeline.tail_end_tick,
    );
    try session.closeAndRelease();
    try std.testing.expect(
        (try bank.snapshotV3()).used.isZero(),
    );
}
