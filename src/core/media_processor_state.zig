//! Fixed image, audio, video processor state and synchronized cache progress.

const std = @import("std");
const media = @import("media_contract.zig");

pub const Digest = [32]u8;
pub const processor_state_abi: u64 =
    0x474d_5053_0000_0001;
pub const processor_state_magic =
    [_]u8{ 'G', 'M', 'P', 'R', 'S', 'T', '1', 0 };
pub const processor_state_body_bytes: usize = 480;
pub const processor_state_bytes: usize = 512;
pub const sync_state_abi: u64 =
    0x474d_5359_0000_0001;
pub const sync_state_magic =
    [_]u8{ 'G', 'M', 'S', 'Y', 'N', 'C', '1', 0 };
pub const sync_state_body_bytes: usize = 480;
pub const sync_state_bytes: usize = 512;
pub const processor_bundle_abi: u64 =
    0x474d_5042_0000_0001;
pub const processor_bundle_magic =
    [_]u8{ 'G', 'M', 'P', 'B', 'N', 'D', '1', 0 };
pub const processor_count: usize = 3;
pub const processor_bundle_header_bytes: usize = 192;
pub const processor_bundle_payload_bytes: usize =
    processor_count * processor_state_bytes +
    sync_state_bytes;
pub const processor_bundle_body_bytes: usize =
    processor_bundle_header_bytes +
    processor_bundle_payload_bytes;
pub const processor_bundle_bytes: usize =
    processor_bundle_body_bytes + 32;
pub const allowed_flags: u64 = 0;

const processor_state_domain =
    "glacier-media-processor-state-v1\x00";
const sync_state_domain =
    "glacier-media-processor-sync-state-v1\x00";
const processor_bundle_domain =
    "glacier-media-processor-state-bundle-v1\x00";
const ownership_set_domain =
    "glacier-media-processor-ownership-set-v1\x00";
const output_set_domain =
    "glacier-media-processor-output-set-v1\x00";

comptime {
    if (processor_state_body_bytes + 32 !=
        processor_state_bytes)
        @compileError("processor state layout drift");
    if (sync_state_body_bytes + 32 != sync_state_bytes)
        @compileError("sync state layout drift");
    if (processor_bundle_body_bytes != 2240 or
        processor_bundle_bytes != 2272)
        @compileError("processor bundle layout drift");
}

pub const Error = error{
    InvalidProcessorState,
    InvalidSyncState,
    InvalidProcessorBundle,
    InvalidSuccessor,
    ArithmeticOverflow,
    OutputTooSmall,
};

pub const StatePlanV1 = struct {
    kind: media.MediaKindV1,
    request_epoch: u64,
    generation: u64,
    stream_key: u64,
    timeline_base: media.TimeBaseV1,
    media_object_sha256: Digest,
    processor_plan_sha256: Digest,
    previous_state_sha256: Digest = [_]u8{0} ** 32,
    challenge_sha256: Digest,
    cache_content_sha256: Digest,
    output_chain_sha256: Digest,
    ownership_receipt_sha256: Digest,
    decoder_state_sha256: Digest,
};

pub const ProcessorStateV1 = struct {
    kind: media.MediaKindV1,
    request_epoch: u64,
    generation: u64,
    stream_key: u64,
    timeline_base: media.TimeBaseV1,
    cursor_units: u64,
    produced_units: u64,
    cache_entries: u64,
    cache_bytes: u64,
    parameters: [8]u64,
    media_object_sha256: Digest,
    processor_plan_sha256: Digest,
    previous_state_sha256: Digest,
    challenge_sha256: Digest,
    cache_content_sha256: Digest,
    output_chain_sha256: Digest,
    ownership_receipt_sha256: Digest,
    decoder_state_sha256: Digest,
    state_sha256: Digest,
};

pub const SyncPlanV1 = struct {
    generation: u64,
    request_epoch: u64,
    master_ticks_per_second: u64,
    maximum_skew_ticks: u64,
    challenge_sha256: Digest,
    sync_policy_sha256: Digest,
    previous_sync_sha256: Digest = [_]u8{0} ** 32,
};

pub const SyncStateV1 = struct {
    generation: u64,
    request_epoch: u64,
    master_ticks_per_second: u64,
    maximum_skew_ticks: u64,
    watermark_tick: u64,
    audio_end_tick: u64,
    video_end_tick: u64,
    image_barrier_units: u64,
    image_total_units: u64,
    processor_state_sha256: [processor_count]Digest,
    previous_sync_sha256: Digest,
    challenge_sha256: Digest,
    sync_policy_sha256: Digest,
    ownership_set_sha256: Digest,
    output_set_sha256: Digest,
    sync_sha256: Digest,
};

pub const PreparedBundleV1 = struct {
    bytes: []const u8,
    bundle_sha256: Digest,
};

pub const DecodedBundleV1 = struct {
    states: [processor_count]ProcessorStateV1,
    sync: SyncStateV1,
    bundle_sha256: Digest,
};

pub fn makeImageStateV1(
    plan: StatePlanV1,
    processed_tiles: u64,
    total_tiles: u64,
    tile_width: u64,
    tile_height: u64,
    patch_width: u64,
    patch_height: u64,
    channels: u64,
) Error!ProcessorStateV1 {
    const elements_per_tile = try checkedMul(
        try checkedMul(patch_width, patch_height),
        channels,
    );
    const normalized_elements = try checkedMul(
        processed_tiles,
        elements_per_tile,
    );
    var state = stateFromPlanV1(plan);
    state.cursor_units = processed_tiles;
    state.produced_units = normalized_elements;
    state.cache_entries = processed_tiles;
    state.cache_bytes = try checkedMul(
        normalized_elements,
        2,
    );
    state.parameters = .{
        processed_tiles,
        total_tiles,
        tile_width,
        tile_height,
        patch_width,
        patch_height,
        channels,
        normalized_elements,
    };
    state.state_sha256 = processorStateRootV1(state);
    try validateProcessorStateV1(state);
    return state;
}

pub fn makeAudioStateV1(
    plan: StatePlanV1,
    feature_frames: u64,
    sample_rate: u64,
    channels: u64,
    window_samples: u64,
    hop_samples: u64,
    feature_bins: u64,
    feature_bytes: u64,
) Error!ProcessorStateV1 {
    if (feature_frames == 0 or window_samples < hop_samples)
        return Error.InvalidProcessorState;
    const context_samples = window_samples - hop_samples;
    const cursor_units = try checkedAdd(
        window_samples,
        try checkedMul(feature_frames - 1, hop_samples),
    );
    const feature_cache_bytes = try checkedMul(
        try checkedMul(feature_frames, feature_bins),
        feature_bytes,
    );
    const context_bytes = try checkedMul(
        try checkedMul(context_samples, channels),
        2,
    );
    var state = stateFromPlanV1(plan);
    state.cursor_units = cursor_units;
    state.produced_units = feature_frames;
    state.cache_entries = feature_frames;
    state.cache_bytes = try checkedAdd(
        feature_cache_bytes,
        context_bytes,
    );
    state.parameters = .{
        sample_rate,
        channels,
        window_samples,
        hop_samples,
        feature_bins,
        context_samples,
        feature_bytes,
        0,
    };
    state.state_sha256 = processorStateRootV1(state);
    try validateProcessorStateV1(state);
    return state;
}

pub fn makeVideoStateV1(
    plan: StatePlanV1,
    window_capacity: u64,
    bytes_per_entry: u64,
    window_start_frame: u64,
    window_end_frame: u64,
    last_keyframe: u64,
) Error!ProcessorStateV1 {
    const cache_entries = std.math.sub(
        u64,
        window_end_frame,
        window_start_frame,
    ) catch return Error.InvalidProcessorState;
    var state = stateFromPlanV1(plan);
    state.cursor_units = window_end_frame;
    state.produced_units = window_end_frame;
    state.cache_entries = cache_entries;
    state.cache_bytes = try checkedMul(
        cache_entries,
        bytes_per_entry,
    );
    state.parameters = .{
        window_capacity,
        bytes_per_entry,
        window_start_frame,
        window_end_frame,
        last_keyframe,
        plan.generation,
        window_start_frame,
        0,
    };
    state.state_sha256 = processorStateRootV1(state);
    try validateProcessorStateV1(state);
    return state;
}

pub fn makeSyncStateV1(
    states: [processor_count]ProcessorStateV1,
    plan: SyncPlanV1,
) Error!SyncStateV1 {
    try validateStateOrderV1(states);
    const audio_end_tick = try unitsToTicksV1(
        states[1].cursor_units,
        states[1].timeline_base,
        plan.master_ticks_per_second,
    );
    const video_end_tick = try unitsToTicksV1(
        states[2].cursor_units,
        states[2].timeline_base,
        plan.master_ticks_per_second,
    );
    const watermark_tick = @min(
        audio_end_tick,
        video_end_tick,
    );
    var sync: SyncStateV1 = .{
        .generation = plan.generation,
        .request_epoch = plan.request_epoch,
        .master_ticks_per_second = plan.master_ticks_per_second,
        .maximum_skew_ticks = plan.maximum_skew_ticks,
        .watermark_tick = watermark_tick,
        .audio_end_tick = audio_end_tick,
        .video_end_tick = video_end_tick,
        .image_barrier_units = states[0].cursor_units,
        .image_total_units = states[0].parameters[1],
        .processor_state_sha256 = .{
            states[0].state_sha256,
            states[1].state_sha256,
            states[2].state_sha256,
        },
        .previous_sync_sha256 = plan.previous_sync_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .sync_policy_sha256 = plan.sync_policy_sha256,
        .ownership_set_sha256 = stateDigestSetRootV1(
            ownership_set_domain,
            .{
                states[0].ownership_receipt_sha256,
                states[1].ownership_receipt_sha256,
                states[2].ownership_receipt_sha256,
            },
        ),
        .output_set_sha256 = stateDigestSetRootV1(
            output_set_domain,
            .{
                states[0].output_chain_sha256,
                states[1].output_chain_sha256,
                states[2].output_chain_sha256,
            },
        ),
        .sync_sha256 = [_]u8{0} ** 32,
    };
    sync.sync_sha256 = syncStateRootV1(sync);
    try validateSyncAgainstStatesV1(states, sync);
    return sync;
}

pub fn encodeProcessorStateV1(
    state: ProcessorStateV1,
    output: *[processor_state_bytes]u8,
) Error![]const u8 {
    try validateProcessorStateV1(state);
    writeProcessorStateBodyV1(state, output[0..processor_state_body_bytes]);
    @memcpy(
        output[processor_state_body_bytes..],
        &state.state_sha256,
    );
    return output;
}

pub fn decodeProcessorStateV1(
    encoded: []const u8,
) Error!ProcessorStateV1 {
    if (encoded.len != processor_state_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &processor_state_magic,
        ) or
        readU64(encoded, 8) != processor_state_abi or
        readU64(encoded, 16) != processor_state_bytes or
        readU64(encoded, 24) != allowed_flags or
        !isZeroBytes(encoded[176..192]) or
        !isZeroBytes(encoded[448..processor_state_body_bytes]))
        return Error.InvalidProcessorState;
    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidProcessorState;
    var parameters: [8]u64 = undefined;
    for (&parameters, 0..) |*value, index|
        value.* = readU64(encoded, 112 + index * 8);
    const state: ProcessorStateV1 = .{
        .kind = kind,
        .request_epoch = readU64(encoded, 40),
        .generation = readU64(encoded, 48),
        .stream_key = readU64(encoded, 56),
        .timeline_base = .{
            .numerator = readU64(encoded, 64),
            .denominator = readU64(encoded, 72),
        },
        .cursor_units = readU64(encoded, 80),
        .produced_units = readU64(encoded, 88),
        .cache_entries = readU64(encoded, 96),
        .cache_bytes = readU64(encoded, 104),
        .parameters = parameters,
        .media_object_sha256 = encoded[192..224].*,
        .processor_plan_sha256 = encoded[224..256].*,
        .previous_state_sha256 = encoded[256..288].*,
        .challenge_sha256 = encoded[288..320].*,
        .cache_content_sha256 = encoded[320..352].*,
        .output_chain_sha256 = encoded[352..384].*,
        .ownership_receipt_sha256 = encoded[384..416].*,
        .decoder_state_sha256 = encoded[416..448].*,
        .state_sha256 = encoded[processor_state_body_bytes .. processor_state_body_bytes + 32].*,
    };
    try validateProcessorStateV1(state);
    return state;
}

pub fn encodeSyncStateV1(
    sync: SyncStateV1,
    output: *[sync_state_bytes]u8,
) Error![]const u8 {
    try validateSyncStateV1(sync);
    writeSyncStateBodyV1(
        sync,
        output[0..sync_state_body_bytes],
    );
    @memcpy(
        output[sync_state_body_bytes..],
        &sync.sync_sha256,
    );
    return output;
}

pub fn decodeSyncStateV1(
    encoded: []const u8,
) Error!SyncStateV1 {
    if (encoded.len != sync_state_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &sync_state_magic,
        ) or
        readU64(encoded, 8) != sync_state_abi or
        readU64(encoded, 16) != sync_state_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 104) != processor_count or
        !isZeroBytes(encoded[112..128]) or
        !isZeroBytes(encoded[384..sync_state_body_bytes]))
        return Error.InvalidSyncState;
    const sync: SyncStateV1 = .{
        .generation = readU64(encoded, 32),
        .request_epoch = readU64(encoded, 40),
        .master_ticks_per_second = readU64(encoded, 48),
        .maximum_skew_ticks = readU64(encoded, 56),
        .watermark_tick = readU64(encoded, 64),
        .audio_end_tick = readU64(encoded, 72),
        .video_end_tick = readU64(encoded, 80),
        .image_barrier_units = readU64(encoded, 88),
        .image_total_units = readU64(encoded, 96),
        .processor_state_sha256 = .{
            encoded[128..160].*,
            encoded[160..192].*,
            encoded[192..224].*,
        },
        .previous_sync_sha256 = encoded[224..256].*,
        .challenge_sha256 = encoded[256..288].*,
        .sync_policy_sha256 = encoded[288..320].*,
        .ownership_set_sha256 = encoded[320..352].*,
        .output_set_sha256 = encoded[352..384].*,
        .sync_sha256 = encoded[sync_state_body_bytes .. sync_state_body_bytes + 32].*,
    };
    try validateSyncStateV1(sync);
    return sync;
}

pub fn encodeBundleV1(
    states: [processor_count]ProcessorStateV1,
    sync: SyncStateV1,
    output: *[processor_bundle_bytes]u8,
) Error!PreparedBundleV1 {
    try validateSyncAgainstStatesV1(states, sync);
    @memset(output, 0);
    @memcpy(output[0..8], &processor_bundle_magic);
    writeU64(output, 8, processor_bundle_abi);
    writeU64(output, 16, processor_bundle_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, sync.generation);
    writeU64(output, 40, sync.request_epoch);
    writeU64(output, 48, processor_count);
    for (states, 0..) |state, index|
        @memcpy(
            output[64 + index * 32 .. 96 + index * 32],
            &state.state_sha256,
        );
    @memcpy(output[160..192], &sync.sync_sha256);

    var state_wire: [processor_state_bytes]u8 =
        undefined;
    for (states, 0..) |state, index| {
        _ = try encodeProcessorStateV1(
            state,
            &state_wire,
        );
        const offset =
            processor_bundle_header_bytes +
            index * processor_state_bytes;
        @memcpy(
            output[offset .. offset + processor_state_bytes],
            &state_wire,
        );
    }
    var sync_wire: [sync_state_bytes]u8 = undefined;
    _ = try encodeSyncStateV1(sync, &sync_wire);
    const sync_offset =
        processor_bundle_header_bytes +
        processor_count * processor_state_bytes;
    @memcpy(
        output[sync_offset .. sync_offset + sync_state_bytes],
        &sync_wire,
    );
    const bundle_sha256 = processorBundleRootV1(
        output[0..processor_bundle_body_bytes],
    );
    @memcpy(
        output[processor_bundle_body_bytes..],
        &bundle_sha256,
    );
    _ = try decodeBundleV1(output);
    return .{
        .bytes = output,
        .bundle_sha256 = bundle_sha256,
    };
}

pub fn decodeBundleV1(
    encoded: []const u8,
) Error!DecodedBundleV1 {
    if (encoded.len != processor_bundle_bytes or
        !std.mem.eql(
            u8,
            encoded[0..8],
            &processor_bundle_magic,
        ) or
        readU64(encoded, 8) != processor_bundle_abi or
        readU64(encoded, 16) != processor_bundle_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 48) != processor_count or
        readU64(encoded, 56) != 0)
        return Error.InvalidProcessorBundle;
    var states: [processor_count]ProcessorStateV1 =
        undefined;
    for (&states, 0..) |*state, index| {
        const offset =
            processor_bundle_header_bytes +
            index * processor_state_bytes;
        state.* = decodeProcessorStateV1(
            encoded[offset .. offset + processor_state_bytes],
        ) catch return Error.InvalidProcessorBundle;
        if (!std.mem.eql(
            u8,
            &state.state_sha256,
            encoded[64 + index * 32 .. 96 + index * 32],
        )) return Error.InvalidProcessorBundle;
    }
    const sync_offset =
        processor_bundle_header_bytes +
        processor_count * processor_state_bytes;
    const sync = decodeSyncStateV1(
        encoded[sync_offset .. sync_offset + sync_state_bytes],
    ) catch return Error.InvalidProcessorBundle;
    const bundle_sha256: Digest = encoded[processor_bundle_body_bytes .. processor_bundle_body_bytes + 32].*;
    if (readU64(encoded, 32) != sync.generation or
        readU64(encoded, 40) != sync.request_epoch or
        !std.mem.eql(
            u8,
            &sync.sync_sha256,
            encoded[160..192],
        ) or
        !std.mem.eql(
            u8,
            &bundle_sha256,
            &processorBundleRootV1(
                encoded[0..processor_bundle_body_bytes],
            ),
        ))
        return Error.InvalidProcessorBundle;
    validateSyncAgainstStatesV1(
        states,
        sync,
    ) catch return Error.InvalidProcessorBundle;
    return .{
        .states = states,
        .sync = sync,
        .bundle_sha256 = bundle_sha256,
    };
}

pub fn validateSuccessorV1(
    previous: *const DecodedBundleV1,
    successor: *const DecodedBundleV1,
) Error!void {
    for (
        previous.states,
        successor.states,
    ) |prior, next|
        try validateProcessorSuccessorV1(prior, next);
    const expected_generation = std.math.add(
        u64,
        previous.sync.generation,
        1,
    ) catch return Error.InvalidSuccessor;
    const expected_image_barrier = std.math.add(
        u64,
        previous.sync.image_barrier_units,
        1,
    ) catch return Error.InvalidSuccessor;
    if (successor.sync.generation !=
        expected_generation or
        successor.sync.request_epoch !=
            previous.sync.request_epoch or
        successor.sync.master_ticks_per_second !=
            previous.sync.master_ticks_per_second or
        successor.sync.maximum_skew_ticks !=
            previous.sync.maximum_skew_ticks or
        successor.sync.watermark_tick <
            previous.sync.watermark_tick or
        successor.sync.audio_end_tick <=
            previous.sync.audio_end_tick or
        successor.sync.video_end_tick <=
            previous.sync.video_end_tick or
        successor.sync.image_barrier_units !=
            expected_image_barrier or
        successor.sync.image_total_units !=
            previous.sync.image_total_units or
        !std.mem.eql(
            u8,
            &successor.sync.previous_sync_sha256,
            &previous.sync.sync_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.sync.challenge_sha256,
            &previous.sync.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.sync.sync_policy_sha256,
            &previous.sync.sync_policy_sha256,
        ))
        return Error.InvalidSuccessor;
}

pub fn processorStateRootV1(
    state: ProcessorStateV1,
) Digest {
    var body: [processor_state_body_bytes]u8 =
        undefined;
    writeProcessorStateBodyV1(state, &body);
    return domainRootV1(processor_state_domain, &body);
}

pub fn syncStateRootV1(sync: SyncStateV1) Digest {
    var body: [sync_state_body_bytes]u8 = undefined;
    writeSyncStateBodyV1(sync, &body);
    return domainRootV1(sync_state_domain, &body);
}

pub fn processorBundleRootV1(body: []const u8) Digest {
    return domainRootV1(processor_bundle_domain, body);
}

fn stateFromPlanV1(
    plan: StatePlanV1,
) ProcessorStateV1 {
    return .{
        .kind = plan.kind,
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .stream_key = plan.stream_key,
        .timeline_base = plan.timeline_base,
        .cursor_units = 0,
        .produced_units = 0,
        .cache_entries = 0,
        .cache_bytes = 0,
        .parameters = [_]u64{0} ** 8,
        .media_object_sha256 = plan.media_object_sha256,
        .processor_plan_sha256 = plan.processor_plan_sha256,
        .previous_state_sha256 = plan.previous_state_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .cache_content_sha256 = plan.cache_content_sha256,
        .output_chain_sha256 = plan.output_chain_sha256,
        .ownership_receipt_sha256 = plan.ownership_receipt_sha256,
        .decoder_state_sha256 = plan.decoder_state_sha256,
        .state_sha256 = [_]u8{0} ** 32,
    };
}

fn validateProcessorStateV1(
    state: ProcessorStateV1,
) Error!void {
    if (state.request_epoch == 0 or
        state.generation == 0 or
        state.stream_key == 0 or
        state.timeline_base.denominator == 0 or
        state.cursor_units == 0 or
        state.produced_units == 0 or
        state.cache_entries == 0 or
        state.cache_bytes == 0 or
        isZero(state.media_object_sha256) or
        isZero(state.processor_plan_sha256) or
        isZero(state.challenge_sha256) or
        isZero(state.cache_content_sha256) or
        isZero(state.output_chain_sha256) or
        isZero(state.ownership_receipt_sha256) or
        isZero(state.decoder_state_sha256) or
        isZero(state.state_sha256) or
        (state.generation == 1 and
            !isZero(state.previous_state_sha256)) or
        (state.generation != 1 and
            isZero(state.previous_state_sha256)))
        return Error.InvalidProcessorState;
    switch (state.kind) {
        .image => try validateImageStateV1(state),
        .audio => try validateAudioStateV1(state),
        .video => try validateVideoStateV1(state),
    }
    if (!std.mem.eql(
        u8,
        &state.state_sha256,
        &processorStateRootV1(state),
    )) return Error.InvalidProcessorState;
}

fn validateImageStateV1(
    state: ProcessorStateV1,
) Error!void {
    const p = state.parameters;
    if (state.timeline_base.numerator != 0 or
        state.timeline_base.denominator != 1 or
        p[0] != state.cursor_units or
        p[0] == 0 or p[0] > p[1] or
        p[2] == 0 or p[3] == 0 or
        p[4] == 0 or p[5] == 0 or p[6] == 0 or
        p[4] > p[2] or p[5] > p[3] or
        p[7] != state.produced_units or
        state.cache_entries != p[0])
        return Error.InvalidProcessorState;
    const expected_units = try checkedMul(
        try checkedMul(
            try checkedMul(p[0], p[4]),
            p[5],
        ),
        p[6],
    );
    const expected_bytes = try checkedMul(
        expected_units,
        2,
    );
    if (state.produced_units != expected_units or
        state.cache_bytes != expected_bytes)
        return Error.InvalidProcessorState;
}

fn validateAudioStateV1(
    state: ProcessorStateV1,
) Error!void {
    const p = state.parameters;
    if (state.timeline_base.numerator != 1 or
        state.timeline_base.denominator != p[0] or
        p[0] == 0 or p[1] == 0 or p[2] == 0 or
        p[3] == 0 or p[3] > p[2] or p[4] == 0 or
        p[5] != p[2] - p[3] or p[6] == 0 or
        p[7] != 0 or
        state.cache_entries != state.produced_units)
        return Error.InvalidProcessorState;
    const expected_cursor = try checkedAdd(
        p[2],
        try checkedMul(
            state.produced_units - 1,
            p[3],
        ),
    );
    const feature_bytes = try checkedMul(
        try checkedMul(
            state.produced_units,
            p[4],
        ),
        p[6],
    );
    const context_bytes = try checkedMul(
        try checkedMul(p[5], p[1]),
        2,
    );
    if (state.cursor_units != expected_cursor or
        state.cache_bytes !=
            try checkedAdd(feature_bytes, context_bytes))
        return Error.InvalidProcessorState;
}

fn validateVideoStateV1(
    state: ProcessorStateV1,
) Error!void {
    const p = state.parameters;
    if (state.timeline_base.numerator == 0 or
        p[0] == 0 or p[1] == 0 or
        p[2] >= p[3] or p[3] != state.cursor_units or
        state.produced_units != state.cursor_units or
        p[3] - p[2] > p[0] or
        p[4] < p[2] or p[4] >= p[3] or
        p[5] != state.generation or p[6] != p[2] or
        p[7] != 0 or
        state.cache_entries != p[3] - p[2] or
        state.cache_bytes !=
            try checkedMul(state.cache_entries, p[1]))
        return Error.InvalidProcessorState;
}

fn validateProcessorSuccessorV1(
    previous: ProcessorStateV1,
    successor: ProcessorStateV1,
) Error!void {
    try validateProcessorStateV1(previous);
    try validateProcessorStateV1(successor);
    const expected_generation = std.math.add(
        u64,
        previous.generation,
        1,
    ) catch return Error.InvalidSuccessor;
    if (successor.generation != expected_generation or
        successor.kind != previous.kind or
        successor.request_epoch != previous.request_epoch or
        successor.stream_key != previous.stream_key or
        !std.meta.eql(
            successor.timeline_base,
            previous.timeline_base,
        ) or
        !std.mem.eql(
            u8,
            &successor.media_object_sha256,
            &previous.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.processor_plan_sha256,
            &previous.processor_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.previous_state_sha256,
            &previous.state_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.challenge_sha256,
            &previous.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.decoder_state_sha256,
            &previous.decoder_state_sha256,
        ) or
        std.mem.eql(
            u8,
            &successor.cache_content_sha256,
            &previous.cache_content_sha256,
        ) or
        std.mem.eql(
            u8,
            &successor.output_chain_sha256,
            &previous.output_chain_sha256,
        ) or
        std.mem.eql(
            u8,
            &successor.ownership_receipt_sha256,
            &previous.ownership_receipt_sha256,
        ))
        return Error.InvalidSuccessor;
    switch (successor.kind) {
        .image => {
            const expected_cursor = std.math.add(
                u64,
                previous.cursor_units,
                1,
            ) catch return Error.InvalidSuccessor;
            if (successor.cursor_units !=
                expected_cursor or
                !std.mem.eql(
                    u64,
                    successor.parameters[1..7],
                    previous.parameters[1..7],
                ))
                return Error.InvalidSuccessor;
        },
        .audio => {
            const expected_produced = std.math.add(
                u64,
                previous.produced_units,
                1,
            ) catch return Error.InvalidSuccessor;
            const expected_cursor = std.math.add(
                u64,
                previous.cursor_units,
                previous.parameters[3],
            ) catch return Error.InvalidSuccessor;
            if (successor.produced_units !=
                expected_produced or
                successor.cursor_units !=
                    expected_cursor or
                !std.mem.eql(
                    u64,
                    &successor.parameters,
                    &previous.parameters,
                ))
                return Error.InvalidSuccessor;
        },
        .video => {
            const expected_end = std.math.add(
                u64,
                previous.parameters[3],
                1,
            ) catch return Error.InvalidSuccessor;
            const expected_cache_generation = std.math.add(
                u64,
                previous.parameters[5],
                1,
            ) catch return Error.InvalidSuccessor;
            const expected_start =
                if (expected_end >
                previous.parameters[0])
                    expected_end -
                        previous.parameters[0]
                else
                    0;
            if (successor.parameters[0] !=
                previous.parameters[0] or
                successor.parameters[1] !=
                    previous.parameters[1] or
                successor.parameters[2] !=
                    expected_start or
                successor.parameters[3] != expected_end or
                successor.parameters[5] !=
                    expected_cache_generation or
                successor.parameters[6] != expected_start or
                successor.parameters[7] != 0)
                return Error.InvalidSuccessor;
        },
    }
}

fn validateStateOrderV1(
    states: [processor_count]ProcessorStateV1,
) Error!void {
    inline for (.{ media.MediaKindV1.image, .audio, .video }, 0..) |
        expected,
        index,
    | {
        try validateProcessorStateV1(states[index]);
        if (states[index].kind != expected)
            return Error.InvalidProcessorBundle;
        if (index != 0 and
            (states[index].generation != states[0].generation or
                states[index].request_epoch !=
                    states[0].request_epoch or
                !std.mem.eql(
                    u8,
                    &states[index].challenge_sha256,
                    &states[0].challenge_sha256,
                )))
            return Error.InvalidProcessorBundle;
        for (states[0..index]) |prior| {
            if (states[index].stream_key == prior.stream_key)
                return Error.InvalidProcessorBundle;
        }
    }
}

fn validateSyncStateV1(sync: SyncStateV1) Error!void {
    if (sync.generation == 0 or
        sync.request_epoch == 0 or
        sync.master_ticks_per_second == 0 or
        sync.maximum_skew_ticks == 0 or
        sync.watermark_tick == 0 or
        sync.audio_end_tick == 0 or
        sync.video_end_tick == 0 or
        sync.image_barrier_units == 0 or
        sync.image_total_units == 0 or
        sync.image_barrier_units > sync.image_total_units or
        sync.watermark_tick !=
            @min(sync.audio_end_tick, sync.video_end_tick) or
        absoluteDifferenceV1(
            sync.audio_end_tick,
            sync.video_end_tick,
        ) > sync.maximum_skew_ticks or
        isZero(sync.processor_state_sha256[0]) or
        isZero(sync.processor_state_sha256[1]) or
        isZero(sync.processor_state_sha256[2]) or
        isZero(sync.challenge_sha256) or
        isZero(sync.sync_policy_sha256) or
        isZero(sync.ownership_set_sha256) or
        isZero(sync.output_set_sha256) or
        isZero(sync.sync_sha256) or
        (sync.generation == 1 and
            !isZero(sync.previous_sync_sha256)) or
        (sync.generation != 1 and
            isZero(sync.previous_sync_sha256)) or
        !std.mem.eql(
            u8,
            &sync.sync_sha256,
            &syncStateRootV1(sync),
        ))
        return Error.InvalidSyncState;
}

fn validateSyncAgainstStatesV1(
    states: [processor_count]ProcessorStateV1,
    sync: SyncStateV1,
) Error!void {
    try validateStateOrderV1(states);
    try validateSyncStateV1(sync);
    const audio_end_tick = try unitsToTicksV1(
        states[1].cursor_units,
        states[1].timeline_base,
        sync.master_ticks_per_second,
    );
    const video_end_tick = try unitsToTicksV1(
        states[2].cursor_units,
        states[2].timeline_base,
        sync.master_ticks_per_second,
    );
    if (sync.generation != states[0].generation or
        sync.request_epoch != states[0].request_epoch or
        sync.audio_end_tick != audio_end_tick or
        sync.video_end_tick != video_end_tick or
        sync.image_barrier_units !=
            states[0].cursor_units or
        sync.image_total_units !=
            states[0].parameters[1] or
        !std.mem.eql(
            u8,
            &sync.challenge_sha256,
            &states[0].challenge_sha256,
        ) or
        !std.meta.eql(
            sync.processor_state_sha256,
            [processor_count]Digest{
                states[0].state_sha256,
                states[1].state_sha256,
                states[2].state_sha256,
            },
        ) or
        !std.mem.eql(
            u8,
            &sync.ownership_set_sha256,
            &stateDigestSetRootV1(
                ownership_set_domain,
                .{
                    states[0].ownership_receipt_sha256,
                    states[1].ownership_receipt_sha256,
                    states[2].ownership_receipt_sha256,
                },
            ),
        ) or
        !std.mem.eql(
            u8,
            &sync.output_set_sha256,
            &stateDigestSetRootV1(
                output_set_domain,
                .{
                    states[0].output_chain_sha256,
                    states[1].output_chain_sha256,
                    states[2].output_chain_sha256,
                },
            ),
        ))
        return Error.InvalidSyncState;
}

fn writeProcessorStateBodyV1(
    state: ProcessorStateV1,
    output: []u8,
) void {
    std.debug.assert(output.len == processor_state_body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &processor_state_magic);
    writeU64(output, 8, processor_state_abi);
    writeU64(output, 16, processor_state_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(state.kind));
    writeU64(output, 40, state.request_epoch);
    writeU64(output, 48, state.generation);
    writeU64(output, 56, state.stream_key);
    writeU64(output, 64, state.timeline_base.numerator);
    writeU64(output, 72, state.timeline_base.denominator);
    writeU64(output, 80, state.cursor_units);
    writeU64(output, 88, state.produced_units);
    writeU64(output, 96, state.cache_entries);
    writeU64(output, 104, state.cache_bytes);
    for (state.parameters, 0..) |value, index|
        writeU64(output, 112 + index * 8, value);
    inline for (.{
        state.media_object_sha256,
        state.processor_plan_sha256,
        state.previous_state_sha256,
        state.challenge_sha256,
        state.cache_content_sha256,
        state.output_chain_sha256,
        state.ownership_receipt_sha256,
        state.decoder_state_sha256,
    }, 0..) |digest, index|
        @memcpy(
            output[192 + index * 32 .. 224 + index * 32],
            &digest,
        );
}

fn writeSyncStateBodyV1(
    sync: SyncStateV1,
    output: []u8,
) void {
    std.debug.assert(output.len == sync_state_body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &sync_state_magic);
    writeU64(output, 8, sync_state_abi);
    writeU64(output, 16, sync_state_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, sync.generation);
    writeU64(output, 40, sync.request_epoch);
    writeU64(output, 48, sync.master_ticks_per_second);
    writeU64(output, 56, sync.maximum_skew_ticks);
    writeU64(output, 64, sync.watermark_tick);
    writeU64(output, 72, sync.audio_end_tick);
    writeU64(output, 80, sync.video_end_tick);
    writeU64(output, 88, sync.image_barrier_units);
    writeU64(output, 96, sync.image_total_units);
    writeU64(output, 104, processor_count);
    inline for (.{
        sync.processor_state_sha256[0],
        sync.processor_state_sha256[1],
        sync.processor_state_sha256[2],
        sync.previous_sync_sha256,
        sync.challenge_sha256,
        sync.sync_policy_sha256,
        sync.ownership_set_sha256,
        sync.output_set_sha256,
    }, 0..) |digest, index|
        @memcpy(
            output[128 + index * 32 .. 160 + index * 32],
            &digest,
        );
}

fn unitsToTicksV1(
    units: u64,
    time_base: media.TimeBaseV1,
    master_ticks_per_second: u64,
) Error!u64 {
    if (time_base.numerator == 0 or
        time_base.denominator == 0 or
        master_ticks_per_second == 0)
        return Error.InvalidSyncState;
    const scaled = try checkedMul(
        try checkedMul(units, time_base.numerator),
        master_ticks_per_second,
    );
    if (scaled % time_base.denominator != 0)
        return Error.InvalidSyncState;
    return scaled / time_base.denominator;
}

fn stateDigestSetRootV1(
    domain: []const u8,
    digests: [processor_count]Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    for (digests) |digest| hash.update(&digest);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn domainRootV1(
    domain: []const u8,
    body: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        Error.ArithmeticOverflow;
}

fn checkedMul(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch
        Error.ArithmeticOverflow;
}

fn absoluteDifferenceV1(left: u64, right: u64) u64 {
    return if (left >= right)
        left - right
    else
        right - left;
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
    return isZeroBytes(&digest);
}

fn isZeroBytes(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn testStatesV1(
    generation: u64,
    previous: ?*const DecodedBundleV1,
) ![processor_count]ProcessorStateV1 {
    const previous_roots: [processor_count]Digest =
        if (previous) |value|
            .{
                value.states[0].state_sha256,
                value.states[1].state_sha256,
                value.states[2].state_sha256,
            }
        else
            [_]Digest{[_]u8{0} ** 32} ** processor_count;
    const common = struct {
        fn plan(
            kind: media.MediaKindV1,
            generation_value: u64,
            prior: Digest,
            stream_key: u64,
            timeline_base: media.TimeBaseV1,
            seed: u8,
        ) StatePlanV1 {
            const step: u8 = @intCast(generation_value);
            return .{
                .kind = kind,
                .request_epoch = 24_000,
                .generation = generation_value,
                .stream_key = stream_key,
                .timeline_base = timeline_base,
                .media_object_sha256 = [_]u8{seed} ** 32,
                .processor_plan_sha256 = [_]u8{seed + 1} ** 32,
                .previous_state_sha256 = prior,
                .challenge_sha256 = [_]u8{0x72} ** 32,
                .cache_content_sha256 = [_]u8{seed + 2 + step} ** 32,
                .output_chain_sha256 = [_]u8{seed + 4 + step} ** 32,
                .ownership_receipt_sha256 = [_]u8{seed + 6 + step} ** 32,
                .decoder_state_sha256 = [_]u8{seed + 8} ** 32,
            };
        }
    };
    return .{
        try makeImageStateV1(
            common.plan(
                .image,
                generation,
                previous_roots[0],
                24_100,
                .{ .numerator = 0, .denominator = 1 },
                0x10,
            ),
            generation,
            4,
            4,
            4,
            2,
            2,
            3,
        ),
        try makeAudioStateV1(
            common.plan(
                .audio,
                generation,
                previous_roots[1],
                24_200,
                .{ .numerator = 1, .denominator = 48_000 },
                0x30,
            ),
            generation,
            48_000,
            1,
            400,
            160,
            80,
            2,
        ),
        try makeVideoStateV1(
            common.plan(
                .video,
                generation,
                previous_roots[2],
                24_300,
                .{ .numerator = 1, .denominator = 120 },
                0x50,
            ),
            2,
            128,
            0,
            generation,
            0,
        ),
    };
}

fn testBundleV1(
    generation: u64,
    previous: ?*const DecodedBundleV1,
    output: *[processor_bundle_bytes]u8,
) !PreparedBundleV1 {
    const states = try testStatesV1(generation, previous);
    const sync = try makeSyncStateV1(
        states,
        .{
            .generation = generation,
            .request_epoch = 24_000,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 400,
            .challenge_sha256 = [_]u8{0x72} ** 32,
            .sync_policy_sha256 = [_]u8{0x99} ** 32,
            .previous_sync_sha256 = if (previous) |value|
                value.sync.sync_sha256
            else
                [_]u8{0} ** 32,
        },
    );
    return encodeBundleV1(states, sync, output);
}

test "processor state bundle is canonical and mutation complete" {
    var first_storage: [processor_bundle_bytes]u8 =
        undefined;
    const first = try testBundleV1(
        1,
        null,
        &first_storage,
    );
    const decoded_first = try decodeBundleV1(first.bytes);
    var second_storage: [processor_bundle_bytes]u8 =
        undefined;
    const second = try testBundleV1(
        2,
        &decoded_first,
        &second_storage,
    );
    const decoded_second = try decodeBundleV1(second.bytes);
    try validateSuccessorV1(
        &decoded_first,
        &decoded_second,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        decoded_second.states[0].cursor_units,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        decoded_second.states[1].produced_units,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        decoded_second.states[2].cache_entries,
    );
    var expected: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "51a723cbb2919db803a865eb971d080e" ++
            "4a66df8f791ea4d50be35de7192c8609",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        &second.bundle_sha256,
    );

    for (0..processor_bundle_bytes) |index| {
        var corrupted = second_storage;
        corrupted[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidProcessorBundle,
            decodeBundleV1(&corrupted),
        );
    }

    var foreign_states = decoded_second.states;
    foreign_states[1].processor_plan_sha256 =
        [_]u8{0xee} ** 32;
    foreign_states[1].state_sha256 =
        processorStateRootV1(foreign_states[1]);
    const foreign_sync = try makeSyncStateV1(
        foreign_states,
        .{
            .generation = 2,
            .request_epoch = 24_000,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 400,
            .challenge_sha256 = [_]u8{0x72} ** 32,
            .sync_policy_sha256 = [_]u8{0x99} ** 32,
            .previous_sync_sha256 = decoded_first.sync.sync_sha256,
        },
    );
    var foreign_storage: [processor_bundle_bytes]u8 =
        undefined;
    const foreign = try encodeBundleV1(
        foreign_states,
        foreign_sync,
        &foreign_storage,
    );
    const decoded_foreign = try decodeBundleV1(
        foreign.bytes,
    );
    try std.testing.expectError(
        Error.InvalidSuccessor,
        validateSuccessorV1(
            &decoded_first,
            &decoded_foreign,
        ),
    );
}
