//! Cross-language raw-event-v3 legacy-observer wire codec.
//!
//! This module owns canonical JSONL bytes and SHA-256 commitments only.  It is
//! intentionally separate from the actual-model runner. Its lane-at-a-time
//! `token_published` payload cannot represent TokenTxn wave prepare/commit
//! receipts, and the current retained observation structs also do not record
//! process/thread provenance. Runner-v6 transaction evidence therefore cannot
//! be truthfully adapted into this wire format.
//! `requireCurrentActualObservationEmission` keeps that boundary fail-closed;
//! callers cannot supply an asserted capability bitmap to bypass it. A future
//! emitter requires a new transaction-aware schema rather than relabeling v3.

const std = @import("std");

pub const raw_event_schema = "glacier.decode-lane4/raw-event-evidence-v3";
pub const event_stream_schema = "glacier.decode-lane4/event-stream-v1";
pub const event_schema = "glacier.decode-lane4/event-v1";

pub const observation_abi: u64 = 0x474c_344f_0000_0001;
pub const decode_lane4_abi: u64 = 0x4744_4c34_0000_0004;
pub const m1_execution_abi: u64 = 0x474d_3145_0000_0002;
pub const token_publication_abi: u64 = 0x4754_504f_0000_0001;
pub const resource_bank_abi: u64 = 0x4752_424b_0000_0001;
pub const resource_commit_observer_abi: u64 = 0x4752_434f_0000_0001;
pub const m1_barrier_abi: u64 = 0x474d_3142_0000_0001;
pub const b4_post_commit_abi: u64 = 0x4742_3443_0000_0001;
pub const generation_state_abi: u64 = 0x4747_5354_0000_0001;
pub const generation_rng_abi: u64 = 0x584f_5332_3536_0001;
pub const monotonic_clock_abi: u64 = 0x474d_4e43_0000_0001;
pub const production_clock_source = "os-boot-monotonic";

pub const lane_count: u32 = 4;
pub const worker_count: u32 = 4;
pub const tokens_per_lane: u32 = 64;
pub const total_token_events: u32 = lane_count * tokens_per_lane;
pub const max_core_bytes: usize = 4096;

pub const prompt_hash_domain = "glacier-lane4-prompt-v1\x00";
pub const lane_binding_hash_domain = "glacier-lane4-lane-binding-v1\x00";
const segment_root_domain = "glacier-lane4-segment-root-v1\x00";
const event_domain = "glacier-lane4-event-v1\x00";
const observation_root_domain = "glacier-lane4-observation-root-v1\x00";

pub const Digest = [32]u8;

pub const Error = std.Io.Writer.Error || error{
    InvalidIdentity,
    InvalidDigest,
    InvalidLane,
    InvalidMode,
    InvalidSegment,
    InvalidPayload,
    InvalidCommitment,
    InvalidPromptLength,
    TimestampRegression,
    SequenceOverflow,
    CoreTooLarge,
    MissingTokenEvents,
    MissingProductionClock,
    MissingGenerationState,
    MissingResourceStructs,
    MissingProcessIdentity,
    MissingExecutionThreadEvidence,
    MissingCanonicalIdentityDigests,
    MissingCanonicalResourceDigests,
    MissingSixSegmentEmitter,
};

fn isZeroDigest(value: Digest) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}

fn hashU16(hash: *std.crypto.hash.sha2.Sha256, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

/// Commit one non-empty prompt as
/// `domain || token_count:u64-le || token_ids:u32-le[]`.
pub fn derivePromptSha256(token_ids: []const u32) Error!Digest {
    const token_count = std.math.cast(u64, token_ids.len) orelse
        return Error.InvalidPromptLength;
    if (token_count == 0) return Error.InvalidPromptLength;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prompt_hash_domain);
    hashU64(&hash, token_count);
    for (token_ids) |token_id| hashU32(&hash, token_id);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Bind a prompt to one fixed DecodeLane4 lane. Mode is deliberately absent:
/// M1x4 and B4 must use the same trusted workload binding. The preimage pins
/// the observation/decode/state/RNG ABIs, lane, prompt count/digest, seed,
/// fixed output count, EOS-disabled flag, and greedy-sampling flag.
pub fn deriveLaneBindingSha256(
    lane_index: u32,
    prompt_sha256: Digest,
    prompt_token_count: u64,
    seed: u64,
) Error!Digest {
    if (lane_index >= lane_count) return Error.InvalidLane;
    if (isZeroDigest(prompt_sha256)) return Error.InvalidDigest;
    if (prompt_token_count == 0 or
        prompt_token_count >
            std.math.maxInt(u64) - @as(u64, tokens_per_lane - 1))
        return Error.InvalidPromptLength;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(lane_binding_hash_domain);
    hashU64(&hash, observation_abi);
    hashU64(&hash, decode_lane4_abi);
    hashU64(&hash, generation_state_abi);
    hashU64(&hash, generation_rng_abi);
    hashU32(&hash, lane_index);
    hashU64(&hash, prompt_token_count);
    hash.update(&prompt_sha256);
    hashU64(&hash, seed);
    hashU32(&hash, tokens_per_lane);
    hash.update(&.{ 1, 1 }); // eos_disabled=true, greedy_sampling=true
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn writeDigest(writer: *std.Io.Writer, value: Digest) !void {
    const hex = std.fmt.bytesToHex(value, .lower);
    try writer.print("\"{s}\"", .{&hex});
}

fn writeU32(writer: *std.Io.Writer, value: u32) !void {
    try writer.print("\"{x:0>8}\"", .{value});
}

fn writeU64(writer: *std.Io.Writer, value: u64) !void {
    try writer.print("\"{x:0>16}\"", .{value});
}

pub const Mode = enum(u8) {
    m1x4 = 1,
    b4 = 2,

    pub fn text(self: Mode) []const u8 {
        return switch (self) {
            .m1x4 => "m1x4",
            .b4 => "b4",
        };
    }
};

pub const Segment = enum(u8) {
    coordinator = 0,
    lane_0 = 1,
    lane_1 = 2,
    lane_2 = 3,
    lane_3 = 4,
    sampler = 5,

    pub fn text(self: Segment) []const u8 {
        return switch (self) {
            .coordinator => "coordinator",
            .lane_0 => "lane-0",
            .lane_1 => "lane-1",
            .lane_2 => "lane-2",
            .lane_3 => "lane-3",
            .sampler => "sampler",
        };
    }

    pub fn laneIndex(self: Segment) ?u32 {
        return switch (self) {
            .lane_0 => 0,
            .lane_1 => 1,
            .lane_2 => 2,
            .lane_3 => 3,
            else => null,
        };
    }
};

pub const segment_order = [_]Segment{
    .coordinator,
    .lane_0,
    .lane_1,
    .lane_2,
    .lane_3,
    .sampler,
};

pub const Identity = struct {
    process_id: u64,
    model_instance_sha256: Digest,

    fn validate(self: Identity) Error!void {
        if (self.process_id == 0) return Error.InvalidIdentity;
        if (isZeroDigest(self.model_instance_sha256))
            return Error.InvalidDigest;
    }
};

pub const ObservationContractPayload = struct {
    identity: Identity,
    coordinator_thread_id: u64,
    binary_sha256: Digest,
    model_sha256: Digest,
    workload_sha256: Digest,
    options_sha256: Digest,
    mode: Mode,
};

pub const ObservationBeginPayload = struct {
    identity: Identity,
    mode: Mode,
};

pub const M1ResourceCommittedPayload = struct {
    identity: Identity,
    lane_index: u32,
    claim_sha256: Digest,
    receipt_sha256: Digest,
};

pub const B4ResourceCommittedPayload = struct {
    identity: Identity,
    claim_sha256: Digest,
    receipt_sha256: Digest,
};

pub const M1ResourceBarrierPayload = struct {
    identity: Identity,
    committed_snapshot_sha256: Digest,
    barrier_receipt_sha256: Digest,
};

pub const ResourceReleasedPayload = struct {
    identity: Identity,
    release_count: u32,
    released_snapshot_sha256: Digest,
};

pub const ObservationEndPayload = struct {
    identity: Identity,
    mode: Mode,
};

pub const LaneBeginPayload = struct {
    identity: Identity,
    lane_index: u32,
    mode: Mode,
    binding_sha256: Digest,
    prompt_sha256: Digest,
    seed: u64,
};

pub const TokenPublishedPayload = struct {
    step_index: u64,
    terminal: bool,
    token_id: u32,
};

pub const LaneEndPayload = struct {
    identity: Identity,
    lane_index: u32,
    mode: Mode,
    binding_sha256: Digest,
    output_sha256: Digest,
    kv_sha256: Digest,
    kv_positions: u64,
    sampling_calls: u64,
    rng_state: [4]u64,
};

pub const PhysicalMetricsUnavailablePayload = struct {};

pub const Payload = union(enum) {
    observation_contract: ObservationContractPayload,
    observation_begin: ObservationBeginPayload,
    m1_resource_committed: M1ResourceCommittedPayload,
    b4_resource_committed: B4ResourceCommittedPayload,
    m1_resource_barrier: M1ResourceBarrierPayload,
    resource_released: ResourceReleasedPayload,
    observation_end: ObservationEndPayload,
    lane_begin: LaneBeginPayload,
    token_published: TokenPublishedPayload,
    lane_end: LaneEndPayload,
    physical_metrics_unavailable: PhysicalMetricsUnavailablePayload,

    pub fn kind(self: Payload) []const u8 {
        return switch (self) {
            .observation_contract => "observation_contract",
            .observation_begin => "observation_begin",
            .m1_resource_committed, .b4_resource_committed => "resource_committed",
            .m1_resource_barrier => "resource_barrier",
            .resource_released => "resource_released",
            .observation_end => "observation_end",
            .lane_begin => "lane_begin",
            .token_published => "token_published",
            .lane_end => "lane_end",
            .physical_metrics_unavailable => "physical_metrics_unavailable",
        };
    }

    fn validate(self: Payload) Error!void {
        switch (self) {
            .observation_contract => |value| {
                try value.identity.validate();
                if (value.coordinator_thread_id == 0 or
                    isZeroDigest(value.binary_sha256) or
                    isZeroDigest(value.model_sha256) or
                    isZeroDigest(value.workload_sha256) or
                    isZeroDigest(value.options_sha256))
                    return Error.InvalidDigest;
            },
            .observation_begin => |value| try value.identity.validate(),
            .m1_resource_committed => |value| {
                try value.identity.validate();
                if (value.lane_index >= lane_count) return Error.InvalidLane;
                if (isZeroDigest(value.claim_sha256) or
                    isZeroDigest(value.receipt_sha256))
                    return Error.InvalidDigest;
            },
            .b4_resource_committed => |value| {
                try value.identity.validate();
                if (isZeroDigest(value.claim_sha256) or
                    isZeroDigest(value.receipt_sha256))
                    return Error.InvalidDigest;
            },
            .m1_resource_barrier => |value| {
                try value.identity.validate();
                if (isZeroDigest(value.committed_snapshot_sha256) or
                    isZeroDigest(value.barrier_receipt_sha256))
                    return Error.InvalidDigest;
            },
            .resource_released => |value| {
                try value.identity.validate();
                if (value.release_count == 0 or
                    isZeroDigest(value.released_snapshot_sha256))
                    return Error.InvalidDigest;
            },
            .observation_end => |value| try value.identity.validate(),
            .lane_begin => |value| {
                try value.identity.validate();
                if (value.lane_index >= lane_count) return Error.InvalidLane;
                if (isZeroDigest(value.binding_sha256) or
                    isZeroDigest(value.prompt_sha256))
                    return Error.InvalidDigest;
            },
            .token_published => {},
            .lane_end => |value| {
                try value.identity.validate();
                if (value.lane_index >= lane_count) return Error.InvalidLane;
                if (isZeroDigest(value.binding_sha256) or
                    isZeroDigest(value.output_sha256) or
                    isZeroDigest(value.kv_sha256) or value.kv_positions == 0 or
                    value.sampling_calls != tokens_per_lane or
                    std.mem.allEqual(u64, &value.rng_state, 0))
                    return Error.InvalidPayload;
            },
            .physical_metrics_unavailable => {},
        }
    }

    fn validateForSegment(self: Payload, segment: Segment) Error!void {
        switch (self) {
            .observation_contract,
            .observation_begin,
            .m1_resource_committed,
            .b4_resource_committed,
            .m1_resource_barrier,
            .resource_released,
            .observation_end,
            => if (segment != .coordinator) return Error.InvalidSegment,
            .lane_begin => |value| {
                if (segment.laneIndex() != value.lane_index)
                    return Error.InvalidSegment;
            },
            .token_published => if (segment.laneIndex() == null)
                return Error.InvalidSegment,
            .lane_end => |value| {
                if (segment.laneIndex() != value.lane_index)
                    return Error.InvalidSegment;
            },
            .physical_metrics_unavailable => if (segment != .sampler)
                return Error.InvalidSegment,
        }
    }

    fn writeIdentityFields(
        writer: *std.Io.Writer,
        identity: Identity,
        prefix: []const u8,
    ) !void {
        try writer.writeAll(prefix);
        try writeDigest(writer, identity.model_instance_sha256);
        try writer.writeAll(",\"process_id\":");
        try writeU64(writer, identity.process_id);
    }

    pub fn writeCanonical(self: Payload, writer: *std.Io.Writer) !void {
        switch (self) {
            .observation_contract => |value| {
                try writer.writeAll("{\"b4_post_commit_abi\":");
                try writeU64(writer, b4_post_commit_abi);
                try writer.writeAll(",\"binary_sha256\":");
                try writeDigest(writer, value.binary_sha256);
                try writer.writeAll(",\"coordinator_thread_id\":");
                try writeU64(writer, value.coordinator_thread_id);
                try writer.writeAll(",\"decode_lane4_abi\":");
                try writeU64(writer, decode_lane4_abi);
                try writer.writeAll(",\"eos_disabled\":true,\"generation_rng_abi\":");
                try writeU64(writer, generation_rng_abi);
                try writer.writeAll(",\"generation_state_abi\":");
                try writeU64(writer, generation_state_abi);
                try writer.writeAll(",\"greedy_sampling\":true,\"lane_count\":");
                try writeU32(writer, lane_count);
                try writer.writeAll(",\"m1_barrier_abi\":");
                try writeU64(writer, m1_barrier_abi);
                try writer.writeAll(",\"m1_execution_abi\":");
                try writeU64(writer, m1_execution_abi);
                try writer.print(",\"mode\":\"{s}\",\"model_instance_sha256\":", .{value.mode.text()});
                try writeDigest(writer, value.identity.model_instance_sha256);
                try writer.writeAll(",\"model_sha256\":");
                try writeDigest(writer, value.model_sha256);
                try writer.writeAll(",\"monotonic_clock_abi\":");
                try writeU64(writer, monotonic_clock_abi);
                try writer.print(",\"monotonic_clock_source\":\"{s}\",\"observation_abi\":", .{production_clock_source});
                try writeU64(writer, observation_abi);
                try writer.writeAll(",\"options_sha256\":");
                try writeDigest(writer, value.options_sha256);
                try writer.writeAll(",\"physical_metrics_claimed\":false,\"process_id\":");
                try writeU64(writer, value.identity.process_id);
                try writer.print(",\"raw_schema\":\"{s}\",\"resource_bank_abi\":", .{raw_event_schema});
                try writeU64(writer, resource_bank_abi);
                try writer.writeAll(",\"resource_commit_observer_abi\":");
                try writeU64(writer, resource_commit_observer_abi);
                try writer.writeAll(",\"token_publication_abi\":");
                try writeU64(writer, token_publication_abi);
                try writer.writeAll(",\"tokens_per_lane\":");
                try writeU32(writer, tokens_per_lane);
                try writer.writeAll(",\"worker_count\":");
                try writeU32(writer, worker_count);
                try writer.writeAll(",\"workload_sha256\":");
                try writeDigest(writer, value.workload_sha256);
                try writer.writeAll("}");
            },
            .observation_begin => |value| {
                try writer.print("{{\"mode\":\"{s}\",\"model_instance_sha256\":", .{value.mode.text()});
                try writeDigest(writer, value.identity.model_instance_sha256);
                try writer.writeAll(",\"process_id\":");
                try writeU64(writer, value.identity.process_id);
                try writer.writeAll("}");
            },
            .m1_resource_committed => |value| {
                try writer.writeAll("{\"claim_sha256\":");
                try writeDigest(writer, value.claim_sha256);
                try writer.writeAll(",\"lane_index\":");
                try writeU32(writer, value.lane_index);
                try writeIdentityFields(writer, value.identity, ",\"model_instance_sha256\":");
                try writer.writeAll(",\"receipt_sha256\":");
                try writeDigest(writer, value.receipt_sha256);
                try writer.writeAll(",\"resource_bank_abi\":");
                try writeU64(writer, resource_bank_abi);
                try writer.writeAll(",\"resource_commit_observer_abi\":");
                try writeU64(writer, resource_commit_observer_abi);
                try writer.writeAll("}");
            },
            .b4_resource_committed => |value| {
                try writer.writeAll("{\"b4_post_commit_abi\":");
                try writeU64(writer, b4_post_commit_abi);
                try writer.writeAll(",\"claim_sha256\":");
                try writeDigest(writer, value.claim_sha256);
                try writeIdentityFields(writer, value.identity, ",\"model_instance_sha256\":");
                try writer.writeAll(",\"receipt_sha256\":");
                try writeDigest(writer, value.receipt_sha256);
                try writer.writeAll(",\"resource_bank_abi\":");
                try writeU64(writer, resource_bank_abi);
                try writer.writeAll(",\"resource_commit_observer_abi\":");
                try writeU64(writer, resource_commit_observer_abi);
                try writer.writeAll("}");
            },
            .m1_resource_barrier => |value| {
                try writer.writeAll("{\"arrival_count\":");
                try writeU32(writer, lane_count);
                try writer.writeAll(",\"barrier_abi\":");
                try writeU64(writer, m1_barrier_abi);
                try writer.writeAll(",\"barrier_receipt_sha256\":");
                try writeDigest(writer, value.barrier_receipt_sha256);
                try writer.writeAll(",\"committed_snapshot_sha256\":");
                try writeDigest(writer, value.committed_snapshot_sha256);
                try writeIdentityFields(writer, value.identity, ",\"model_instance_sha256\":");
                try writer.writeAll("}");
            },
            .resource_released => |value| {
                try writer.writeAll("{\"model_instance_sha256\":");
                try writeDigest(writer, value.identity.model_instance_sha256);
                try writer.writeAll(",\"process_id\":");
                try writeU64(writer, value.identity.process_id);
                try writer.writeAll(",\"release_count\":");
                try writeU32(writer, value.release_count);
                try writer.writeAll(",\"released_snapshot_sha256\":");
                try writeDigest(writer, value.released_snapshot_sha256);
                try writer.writeAll(",\"resource_bank_abi\":");
                try writeU64(writer, resource_bank_abi);
                try writer.writeAll(",\"used_zero\":true}");
            },
            .observation_end => |value| {
                try writer.print("{{\"mode\":\"{s}\",\"model_instance_sha256\":", .{value.mode.text()});
                try writeDigest(writer, value.identity.model_instance_sha256);
                try writer.writeAll(",\"process_id\":");
                try writeU64(writer, value.identity.process_id);
                try writer.writeAll(",\"published_token_count\":");
                try writeU32(writer, total_token_events);
                try writer.writeAll(",\"status\":\"complete\"}");
            },
            .lane_begin => |value| {
                try writer.writeAll("{\"binding_sha256\":");
                try writeDigest(writer, value.binding_sha256);
                try writer.writeAll(",\"lane_index\":");
                try writeU32(writer, value.lane_index);
                try writer.print(",\"mode\":\"{s}\",\"model_instance_sha256\":", .{value.mode.text()});
                try writeDigest(writer, value.identity.model_instance_sha256);
                try writer.writeAll(",\"process_id\":");
                try writeU64(writer, value.identity.process_id);
                try writer.writeAll(",\"prompt_sha256\":");
                try writeDigest(writer, value.prompt_sha256);
                try writer.writeAll(",\"seed\":");
                try writeU64(writer, value.seed);
                try writer.writeAll("}");
            },
            .token_published => |value| {
                try writer.writeAll("{\"observer_abi\":");
                try writeU64(writer, token_publication_abi);
                try writer.writeAll(",\"step_index\":");
                try writeU64(writer, value.step_index);
                try writer.print(",\"terminal\":{s},\"token_id\":", .{if (value.terminal) "true" else "false"});
                try writeU32(writer, value.token_id);
                try writer.writeAll("}");
            },
            .lane_end => |value| {
                try writer.writeAll("{\"binding_sha256\":");
                try writeDigest(writer, value.binding_sha256);
                try writer.writeAll(",\"complete\":true,\"execution_abi\":");
                try writeU64(writer, if (value.mode == .m1x4) m1_execution_abi else decode_lane4_abi);
                try writer.writeAll(",\"generation_rng_abi\":");
                try writeU64(writer, generation_rng_abi);
                try writer.writeAll(",\"generation_state_abi\":");
                try writeU64(writer, generation_state_abi);
                try writer.writeAll(",\"kv_positions\":");
                try writeU64(writer, value.kv_positions);
                try writer.writeAll(",\"kv_sha256\":");
                try writeDigest(writer, value.kv_sha256);
                try writer.writeAll(",\"lane_index\":");
                try writeU32(writer, value.lane_index);
                try writer.print(",\"mode\":\"{s}\",\"model_instance_sha256\":", .{value.mode.text()});
                try writeDigest(writer, value.identity.model_instance_sha256);
                try writer.writeAll(",\"output_sha256\":");
                try writeDigest(writer, value.output_sha256);
                try writer.writeAll(",\"process_id\":");
                try writeU64(writer, value.identity.process_id);
                try writer.writeAll(",\"published_count\":");
                try writeU32(writer, tokens_per_lane);
                try writer.writeAll(",\"rng_state\":[");
                for (value.rng_state, 0..) |word, index| {
                    if (index != 0) try writer.writeAll(",");
                    try writeU64(writer, word);
                }
                try writer.writeAll("],\"sampling_calls\":");
                try writeU64(writer, value.sampling_calls);
                try writer.writeAll(",\"thread_participants\":");
                try writeU32(writer, if (value.mode == .m1x4) 1 else worker_count);
                try writer.writeAll("}");
            },
            .physical_metrics_unavailable => {
                try writer.writeAll("{\"external_sampler_required\":true,\"physical_metrics_claimed\":false,\"status\":\"unavailable\",\"symmetric_arms_required\":true}");
            },
        }
    }
};

pub const SegmentCommitment = struct {
    campaign_id: Digest,
    observation_id: Digest,
    segment: Segment,
    event_count: u64,
    segment_root_sha256: Digest,
    segment_tip_sha256: Digest,
};

pub fn deriveSegmentRoot(
    campaign_id: Digest,
    observation_id: Digest,
    segment: Segment,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(segment_root_domain);
    hash.update(&campaign_id);
    hash.update(&observation_id);
    const segment_text = segment.text();
    hashU16(&hash, @intCast(segment_text.len));
    hash.update(segment_text);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub const SegmentEncoder = struct {
    campaign_id: Digest,
    observation_id: Digest,
    segment: Segment,
    root_sha256: Digest,
    previous_sha256: Digest,
    event_count: u64 = 0,
    last_monotonic_ns: u64 = 0,
    has_timestamp: bool = false,

    pub fn init(
        campaign_id: Digest,
        observation_id: Digest,
        segment: Segment,
    ) Error!SegmentEncoder {
        if (isZeroDigest(campaign_id) or isZeroDigest(observation_id))
            return Error.InvalidIdentity;
        const root = deriveSegmentRoot(campaign_id, observation_id, segment);
        return .{
            .campaign_id = campaign_id,
            .observation_id = observation_id,
            .segment = segment,
            .root_sha256 = root,
            .previous_sha256 = root,
        };
    }

    pub fn append(
        self: *SegmentEncoder,
        writer: *std.Io.Writer,
        monotonic_ns: u64,
        thread_id: u64,
        payload: Payload,
    ) Error!Digest {
        // Reject before writing anything. Otherwise an event at maxInt(u64)
        // would be present in the output even though advancing the encoder
        // failed, leaving the caller with bytes that have no commitment.
        if (self.event_count == std.math.maxInt(u64))
            return Error.SequenceOverflow;
        if (self.has_timestamp and monotonic_ns < self.last_monotonic_ns)
            return Error.TimestampRegression;
        try payload.validate();
        try payload.validateForSegment(self.segment);

        var core_storage: [max_core_bytes]u8 = undefined;
        var core_writer = std.Io.Writer.fixed(&core_storage);
        const campaign_hex = std.fmt.bytesToHex(self.campaign_id, .lower);
        const observation_hex = std.fmt.bytesToHex(self.observation_id, .lower);
        try core_writer.print("{{\"campaign_id\":\"{s}\",\"kind\":\"{s}\",\"local_sequence\":", .{
            &campaign_hex,
            payload.kind(),
        });
        try writeU64(&core_writer, self.event_count);
        try core_writer.writeAll(",\"monotonic_ns\":");
        try writeU64(&core_writer, monotonic_ns);
        try core_writer.print(",\"observation_id\":\"{s}\",\"payload\":", .{&observation_hex});
        payload.writeCanonical(&core_writer) catch return Error.CoreTooLarge;
        try core_writer.print(",\"schema\":\"{s}\",\"segment\":\"{s}\",\"thread_id\":", .{
            event_schema,
            self.segment.text(),
        });
        try writeU64(&core_writer, thread_id);
        try core_writer.writeAll("}");
        const core = core_writer.buffered();

        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(event_domain);
        hash.update(&self.previous_sha256);
        hashU64(&hash, self.event_count);
        hashU64(&hash, @intCast(core.len));
        hash.update(core);
        var event_sha256: Digest = undefined;
        hash.final(&event_sha256);

        const event_hex = std.fmt.bytesToHex(event_sha256, .lower);
        const previous_hex = std.fmt.bytesToHex(self.previous_sha256, .lower);
        try writer.writeAll("{\"core\":");
        try writer.writeAll(core);
        try writer.print(",\"event_sha256\":\"{s}\",\"previous_sha256\":\"{s}\"}}\n", .{
            &event_hex,
            &previous_hex,
        });

        self.previous_sha256 = event_sha256;
        self.event_count += 1;
        self.last_monotonic_ns = monotonic_ns;
        self.has_timestamp = true;
        return event_sha256;
    }

    pub fn finish(self: SegmentEncoder) SegmentCommitment {
        return .{
            .campaign_id = self.campaign_id,
            .observation_id = self.observation_id,
            .segment = self.segment,
            .event_count = self.event_count,
            .segment_root_sha256 = self.root_sha256,
            .segment_tip_sha256 = self.previous_sha256,
        };
    }
};

pub fn deriveObservationRoot(
    campaign_id: Digest,
    observation_id: Digest,
    commitments: [segment_order.len]SegmentCommitment,
) Error!Digest {
    if (isZeroDigest(campaign_id) or isZeroDigest(observation_id))
        return Error.InvalidIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(observation_root_domain);
    hash.update(&campaign_id);
    hash.update(&observation_id);
    for (commitments, segment_order) |commitment, expected_segment| {
        const expected_root = deriveSegmentRoot(
            campaign_id,
            observation_id,
            expected_segment,
        );
        if (commitment.segment != expected_segment or
            !std.mem.eql(u8, &commitment.campaign_id, &campaign_id) or
            !std.mem.eql(u8, &commitment.observation_id, &observation_id) or
            !std.mem.eql(u8, &commitment.segment_root_sha256, &expected_root) or
            isZeroDigest(commitment.segment_tip_sha256) or
            (commitment.event_count == 0 and !std.mem.eql(
                u8,
                &commitment.segment_tip_sha256,
                &expected_root,
            )))
            return Error.InvalidCommitment;
        const text = expected_segment.text();
        hashU16(&hash, @intCast(text.len));
        hash.update(text);
        hashU64(&hash, commitment.event_count);
        hash.update(&commitment.segment_root_sha256);
        hash.update(&commitment.segment_tip_sha256);
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Internal inventory for the actual-observation structs in this revision.
/// This deliberately is not public: a caller-authored all-true bitmap is not
/// evidence that the current observation path captured these capabilities.
const ActualObservationCapabilities = struct {
    token_events: bool,
    production_clock: bool,
    generation_state: bool,
    resource_structs: bool,
    process_identity: bool,
    execution_thread_ids: bool,
    canonical_identity_digests: bool,
    canonical_resource_digests: bool,
    six_segment_emitter: bool,
};

fn currentActualObservationCapabilities() ActualObservationCapabilities {
    return .{
        .token_events = true,
        .production_clock = true,
        .generation_state = true,
        .resource_structs = true,
        .process_identity = false,
        .execution_thread_ids = false,
        .canonical_identity_digests = false,
        .canonical_resource_digests = false,
        .six_segment_emitter = false,
    };
}

fn requireActualObservationCapabilities(
    capabilities: ActualObservationCapabilities,
) Error!void {
    if (!capabilities.token_events) return Error.MissingTokenEvents;
    if (!capabilities.production_clock) return Error.MissingProductionClock;
    if (!capabilities.generation_state) return Error.MissingGenerationState;
    if (!capabilities.resource_structs) return Error.MissingResourceStructs;
    if (!capabilities.process_identity) return Error.MissingProcessIdentity;
    if (!capabilities.execution_thread_ids)
        return Error.MissingExecutionThreadEvidence;
    if (!capabilities.canonical_identity_digests)
        return Error.MissingCanonicalIdentityDigests;
    if (!capabilities.canonical_resource_digests)
        return Error.MissingCanonicalResourceDigests;
    if (!capabilities.six_segment_emitter)
        return Error.MissingSixSegmentEmitter;
}

/// Preflight the only actual-observation path represented by this revision.
///
/// This has no caller-controlled inputs and therefore cannot be converted into
/// an emission permit by asserting capabilities that the runner did not record.
/// It will remain fail-closed until the production observation path itself owns
/// every required field and the six-segment emitter.
pub fn requireCurrentActualObservationEmission() Error!void {
    return requireActualObservationCapabilities(
        currentActualObservationCapabilities(),
    );
}

fn digestRepeated(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn testHashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
    endian: std.builtin.Endian,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, endian);
    hash.update(&bytes);
}

fn testHashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
    endian: std.builtin.Endian,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, endian);
    hash.update(&bytes);
}

fn testPromptDigest(
    domain: []const u8,
    declared_count: u64,
    tokens: []const u32,
    endian: std.builtin.Endian,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    testHashU64(&hash, declared_count, endian);
    for (tokens) |token| testHashU32(&hash, token, endian);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn testLaneBindingDigest(
    domain: []const u8,
    prompt_token_count: u64,
    prompt_sha256: Digest,
    endian: std.builtin.Endian,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    for ([_]u64{
        observation_abi,
        decode_lane4_abi,
        generation_state_abi,
        generation_rng_abi,
    }) |abi| testHashU64(&hash, abi, endian);
    testHashU32(&hash, 2, endian);
    testHashU64(&hash, prompt_token_count, endian);
    hash.update(&prompt_sha256);
    testHashU64(&hash, 0x0102_0304_0506_0708, endian);
    testHashU32(&hash, tokens_per_lane, endian);
    hash.update(&.{ 1, 1 });
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

const payload_variant_count = @typeInfo(Payload).@"union".fields.len;

fn testPayloadVariantIndex(payload: Payload) usize {
    return switch (payload) {
        .observation_contract => 0,
        .observation_begin => 1,
        .m1_resource_committed => 2,
        .b4_resource_committed => 3,
        .m1_resource_barrier => 4,
        .resource_released => 5,
        .observation_end => 6,
        .lane_begin => 7,
        .token_published => 8,
        .lane_end => 9,
        .physical_metrics_unavailable => 10,
    };
}

fn testCanonicalPayloadAggregate(payloads: []const Payload) !Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-payload-golden-v1\x00");
    hashU32(&hash, @intCast(payloads.len));
    for (payloads) |payload| {
        try payload.validate();
        const kind = payload.kind();
        hashU16(&hash, @intCast(kind.len));
        hash.update(kind);

        var storage: [max_core_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&storage);
        try payload.writeCanonical(&writer);
        const canonical = writer.buffered();
        hashU64(&hash, @intCast(canonical.len));
        hash.update(canonical);
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

test "Python prompt and lane-binding golden vectors are identical" {
    const tokens = [_]u32{ 1, 0x0102_0304, 32_000, 0xffff_ffff };
    const expected_prompt = Digest{
        0x45, 0x27, 0x4d, 0x0d, 0x28, 0x3f, 0xd1, 0x71,
        0x7b, 0xa4, 0x77, 0x9c, 0x6a, 0xd5, 0x1c, 0xd4,
        0x53, 0x7d, 0x74, 0x34, 0x51, 0x00, 0x57, 0x8c,
        0xc6, 0xbb, 0xf6, 0x32, 0xa5, 0xab, 0x02, 0xc2,
    };
    const expected_binding = Digest{
        0xbb, 0x23, 0xd1, 0x5d, 0xc5, 0x8f, 0x93, 0x8f,
        0x98, 0xe2, 0x72, 0x8a, 0x18, 0x2d, 0x20, 0x6d,
        0x60, 0x5a, 0x41, 0xb8, 0x19, 0x7e, 0xec, 0x12,
        0xa2, 0x54, 0x83, 0xc0, 0x62, 0x57, 0xba, 0xb0,
    };
    const prompt = try derivePromptSha256(&tokens);
    try std.testing.expectEqualSlices(u8, &expected_prompt, &prompt);
    const binding = try deriveLaneBindingSha256(
        2,
        prompt,
        tokens.len,
        0x0102_0304_0506_0708,
    );
    try std.testing.expectEqualSlices(u8, &expected_binding, &binding);
}

test "prompt and binding domains lengths and endianness are pinned" {
    const tokens = [_]u32{ 1, 0x0102_0304, 32_000, 0xffff_ffff };
    const expected_prompt = try derivePromptSha256(&tokens);
    const wrong_prompt_domain = testPromptDigest(
        "glacier-lane4-prompt-v2\x00",
        tokens.len,
        &tokens,
        .little,
    );
    const wrong_prompt_length = testPromptDigest(
        prompt_hash_domain,
        tokens.len + 1,
        &tokens,
        .little,
    );
    const wrong_prompt_endian = testPromptDigest(
        prompt_hash_domain,
        tokens.len,
        &tokens,
        .big,
    );
    try std.testing.expect(!std.mem.eql(u8, &expected_prompt, &wrong_prompt_domain));
    try std.testing.expect(!std.mem.eql(u8, &expected_prompt, &wrong_prompt_length));
    try std.testing.expect(!std.mem.eql(u8, &expected_prompt, &wrong_prompt_endian));

    const expected_binding = try deriveLaneBindingSha256(
        2,
        expected_prompt,
        tokens.len,
        0x0102_0304_0506_0708,
    );
    const canonical_binding = testLaneBindingDigest(
        lane_binding_hash_domain,
        tokens.len,
        expected_prompt,
        .little,
    );
    try std.testing.expectEqualSlices(u8, &expected_binding, &canonical_binding);
    const wrong_binding_domain = testLaneBindingDigest(
        "glacier-lane4-lane-binding-v2\x00",
        tokens.len,
        expected_prompt,
        .little,
    );
    const wrong_binding_length = testLaneBindingDigest(
        lane_binding_hash_domain,
        tokens.len + 1,
        expected_prompt,
        .little,
    );
    const wrong_binding_endian = testLaneBindingDigest(
        lane_binding_hash_domain,
        tokens.len,
        expected_prompt,
        .big,
    );
    try std.testing.expect(!std.mem.eql(u8, &expected_binding, &wrong_binding_domain));
    try std.testing.expect(!std.mem.eql(u8, &expected_binding, &wrong_binding_length));
    try std.testing.expect(!std.mem.eql(u8, &expected_binding, &wrong_binding_endian));
    try std.testing.expectError(
        Error.InvalidPromptLength,
        derivePromptSha256(&[_]u32{}),
    );
    try std.testing.expectError(
        Error.InvalidLane,
        deriveLaneBindingSha256(4, expected_prompt, tokens.len, 0),
    );
}

test "Python canonical payload aggregate covers every payload variant" {
    const identity = Identity{
        .process_id = 0x0102_0304_0506_0708,
        .model_instance_sha256 = digestRepeated(0x11),
    };
    const lane_end_common = LaneEndPayload{
        .identity = identity,
        .lane_index = 2,
        .mode = .m1x4,
        .binding_sha256 = digestRepeated(0xbb),
        .output_sha256 = digestRepeated(0xdd),
        .kv_sha256 = digestRepeated(0xee),
        .kv_positions = 79,
        .sampling_calls = tokens_per_lane,
        .rng_state = .{
            1,
            0x0203_0405_0607_0809,
            0x1112_1314_1516_1718,
            0xf1f2_f3f4_f5f6_f7f8,
        },
    };
    const payloads = [_]Payload{
        .{ .observation_contract = .{
            .identity = identity,
            .coordinator_thread_id = 0x2122_2324_2526_2728,
            .binary_sha256 = digestRepeated(0x22),
            .model_sha256 = digestRepeated(0x33),
            .workload_sha256 = digestRepeated(0x44),
            .options_sha256 = digestRepeated(0x55),
            .mode = .m1x4,
        } },
        .{ .observation_contract = .{
            .identity = identity,
            .coordinator_thread_id = 0x2122_2324_2526_2728,
            .binary_sha256 = digestRepeated(0x22),
            .model_sha256 = digestRepeated(0x33),
            .workload_sha256 = digestRepeated(0x44),
            .options_sha256 = digestRepeated(0x55),
            .mode = .b4,
        } },
        .{ .observation_begin = .{
            .identity = identity,
            .mode = .b4,
        } },
        .{ .m1_resource_committed = .{
            .identity = identity,
            .lane_index = 2,
            .claim_sha256 = digestRepeated(0x66),
            .receipt_sha256 = digestRepeated(0x77),
        } },
        .{ .b4_resource_committed = .{
            .identity = identity,
            .claim_sha256 = digestRepeated(0x66),
            .receipt_sha256 = digestRepeated(0x77),
        } },
        .{ .m1_resource_barrier = .{
            .identity = identity,
            .committed_snapshot_sha256 = digestRepeated(0x88),
            .barrier_receipt_sha256 = digestRepeated(0x99),
        } },
        .{ .resource_released = .{
            .identity = identity,
            .release_count = lane_count,
            .released_snapshot_sha256 = digestRepeated(0xaa),
        } },
        .{ .observation_end = .{
            .identity = identity,
            .mode = .m1x4,
        } },
        .{ .lane_begin = .{
            .identity = identity,
            .lane_index = 2,
            .mode = .b4,
            .binding_sha256 = digestRepeated(0xbb),
            .prompt_sha256 = digestRepeated(0xcc),
            .seed = 0x1112_1314_1516_1718,
        } },
        .{ .token_published = .{
            .step_index = tokens_per_lane - 1,
            .terminal = true,
            .token_id = 0xfedc_ba98,
        } },
        .{ .lane_end = lane_end_common },
        .{ .lane_end = .{
            .identity = lane_end_common.identity,
            .lane_index = lane_end_common.lane_index,
            .mode = .b4,
            .binding_sha256 = lane_end_common.binding_sha256,
            .output_sha256 = lane_end_common.output_sha256,
            .kv_sha256 = lane_end_common.kv_sha256,
            .kv_positions = lane_end_common.kv_positions,
            .sampling_calls = lane_end_common.sampling_calls,
            .rng_state = lane_end_common.rng_state,
        } },
        .{ .physical_metrics_unavailable = .{} },
    };

    var covered = [_]bool{false} ** payload_variant_count;
    for (payloads) |payload| covered[testPayloadVariantIndex(payload)] = true;
    for (covered) |is_covered| try std.testing.expect(is_covered);

    // Independently generated with Python's sorted, compact ASCII JSON bytes.
    // Preimage: domain || count:u32-le ||
    //           (kind_len:u16-le || kind || payload_len:u64-le || payload)[]
    const expected = Digest{
        0x3a, 0x31, 0xef, 0x5f, 0xd1, 0x6c, 0x2f, 0xe5,
        0x7b, 0xe7, 0xcd, 0xb8, 0x15, 0x43, 0xf1, 0xf9,
        0x72, 0x5f, 0x05, 0xf7, 0x3c, 0x38, 0xea, 0x94,
        0x64, 0x26, 0x16, 0xab, 0xc7, 0x0f, 0xfe, 0xab,
    };
    const actual = try testCanonicalPayloadAggregate(&payloads);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "Python event-v1 golden vector is byte-for-byte identical" {
    const campaign = digestRepeated(0x11);
    const observation = digestRepeated(0x22);
    var encoder = try SegmentEncoder.init(campaign, observation, .lane_0);
    var storage: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    const event_hash = try encoder.append(
        &writer,
        123_456_789,
        7,
        .{ .token_published = .{
            .step_index = 0,
            .terminal = false,
            .token_id = 42,
        } },
    );
    const expected_line =
        "{\"core\":{\"campaign_id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"kind\":\"token_published\",\"local_sequence\":\"0000000000000000\",\"monotonic_ns\":\"00000000075bcd15\",\"observation_id\":\"2222222222222222222222222222222222222222222222222222222222222222\",\"payload\":{\"observer_abi\":\"4754504f00000001\",\"step_index\":\"0000000000000000\",\"terminal\":false,\"token_id\":\"0000002a\"},\"schema\":\"glacier.decode-lane4/event-v1\",\"segment\":\"lane-0\",\"thread_id\":\"0000000000000007\"},\"event_sha256\":\"49dcd944047aedc72f0b54a04251829019bd40f51a523ba5effd80930ca422f5\",\"previous_sha256\":\"d2786d2e73e0569acf86a19d669ca9e3da03dd431fb7f2604c2c8b599a594964\"}\n";
    try std.testing.expectEqualStrings(expected_line, writer.buffered());
    const expected_event = [_]u8{
        0x49, 0xdc, 0xd9, 0x44, 0x04, 0x7a, 0xed, 0xc7,
        0x2f, 0x0b, 0x54, 0xa0, 0x42, 0x51, 0x82, 0x90,
        0x19, 0xbd, 0x40, 0xf5, 0x1a, 0x52, 0x3b, 0xa5,
        0xef, 0xfd, 0x80, 0x93, 0x0c, 0xa4, 0x22, 0xf5,
    };
    try std.testing.expectEqualSlices(u8, &expected_event, &event_hash);
}

test "Python six-segment observation-root golden vector is identical" {
    const campaign = digestRepeated(0x11);
    const observation = digestRepeated(0x22);
    var commitments: [segment_order.len]SegmentCommitment = undefined;
    for (segment_order, 0..) |segment, index| {
        var encoder = try SegmentEncoder.init(campaign, observation, segment);
        if (segment == .lane_0) {
            var discard_storage: [2048]u8 = undefined;
            var discard = std.Io.Writer.fixed(&discard_storage);
            _ = try encoder.append(
                &discard,
                123_456_789,
                7,
                .{ .token_published = .{
                    .step_index = 0,
                    .terminal = false,
                    .token_id = 42,
                } },
            );
        }
        commitments[index] = encoder.finish();
    }
    const root = try deriveObservationRoot(campaign, observation, commitments);
    const expected = [_]u8{
        0xd0, 0x2b, 0x69, 0x4d, 0xa7, 0x84, 0x07, 0x4b,
        0x66, 0x4b, 0x1d, 0x2e, 0xee, 0xf2, 0x41, 0x96,
        0x9d, 0x76, 0x07, 0x24, 0xe2, 0x1a, 0xa5, 0x64,
        0x5c, 0xc7, 0x7a, 0xf1, 0xd5, 0xaf, 0x32, 0x16,
    };
    try std.testing.expectEqualSlices(u8, &expected, &root);
}

test "observation root rejects segment-order mismatch" {
    const campaign = digestRepeated(0x11);
    const observation = digestRepeated(0x22);
    var commitments: [segment_order.len]SegmentCommitment = undefined;
    for (segment_order, 0..) |segment, index| {
        const root = deriveSegmentRoot(campaign, observation, segment);
        commitments[index] = .{
            .campaign_id = campaign,
            .observation_id = observation,
            .segment = segment,
            .event_count = 0,
            .segment_root_sha256 = root,
            .segment_tip_sha256 = root,
        };
    }
    const lane_zero = commitments[1];
    commitments[1] = commitments[2];
    commitments[2] = lane_zero;
    try std.testing.expectError(
        Error.InvalidCommitment,
        deriveObservationRoot(campaign, observation, commitments),
    );
}

test "observation root rejects a zero non-empty segment tip" {
    const campaign = digestRepeated(0x11);
    const observation = digestRepeated(0x22);
    var commitments: [segment_order.len]SegmentCommitment = undefined;
    for (segment_order, 0..) |segment, index| {
        const root = deriveSegmentRoot(campaign, observation, segment);
        commitments[index] = .{
            .campaign_id = campaign,
            .observation_id = observation,
            .segment = segment,
            .event_count = 0,
            .segment_root_sha256 = root,
            .segment_tip_sha256 = root,
        };
    }
    commitments[1].event_count = 1;
    commitments[1].segment_tip_sha256 = [_]u8{0} ** 32;
    try std.testing.expectError(
        Error.InvalidCommitment,
        deriveObservationRoot(campaign, observation, commitments),
    );
}

test "current actual observations fail closed before raw-event-v3 emission" {
    const capabilities = currentActualObservationCapabilities();
    try std.testing.expect(capabilities.token_events);
    try std.testing.expect(capabilities.production_clock);
    try std.testing.expect(capabilities.generation_state);
    try std.testing.expect(capabilities.resource_structs);
    try std.testing.expectError(
        Error.MissingProcessIdentity,
        requireCurrentActualObservationEmission(),
    );

    const complete = ActualObservationCapabilities{
        .token_events = true,
        .production_clock = true,
        .generation_state = true,
        .resource_structs = true,
        .process_identity = true,
        .execution_thread_ids = true,
        .canonical_identity_digests = true,
        .canonical_resource_digests = true,
        .six_segment_emitter = true,
    };
    try requireActualObservationCapabilities(complete);

    var incomplete = complete;
    incomplete.token_events = false;
    try std.testing.expectError(
        Error.MissingTokenEvents,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.production_clock = false;
    try std.testing.expectError(
        Error.MissingProductionClock,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.generation_state = false;
    try std.testing.expectError(
        Error.MissingGenerationState,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.resource_structs = false;
    try std.testing.expectError(
        Error.MissingResourceStructs,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.process_identity = false;
    try std.testing.expectError(
        Error.MissingProcessIdentity,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.execution_thread_ids = false;
    try std.testing.expectError(
        Error.MissingExecutionThreadEvidence,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.canonical_identity_digests = false;
    try std.testing.expectError(
        Error.MissingCanonicalIdentityDigests,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.canonical_resource_digests = false;
    try std.testing.expectError(
        Error.MissingCanonicalResourceDigests,
        requireActualObservationCapabilities(incomplete),
    );
    incomplete = complete;
    incomplete.six_segment_emitter = false;
    try std.testing.expectError(
        Error.MissingSixSegmentEmitter,
        requireActualObservationCapabilities(incomplete),
    );
}

test "sequence overflow rejects before emitting an uncommitted line" {
    var encoder = try SegmentEncoder.init(
        digestRepeated(0x11),
        digestRepeated(0x22),
        .lane_0,
    );
    encoder.event_count = std.math.maxInt(u64);
    const original_tip = encoder.previous_sha256;
    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(
        Error.SequenceOverflow,
        encoder.append(
            &writer,
            1,
            7,
            .{ .token_published = .{
                .step_index = 0,
                .terminal = false,
                .token_id = 42,
            } },
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);
    try std.testing.expectEqual(std.math.maxInt(u64), encoder.event_count);
    try std.testing.expectEqualSlices(
        u8,
        &original_tip,
        &encoder.previous_sha256,
    );
}
