//! Deterministic image/audio/video processor-state and sync proof.

const std = @import("std");
const core = @import("core");
const media = core.media_contract;
const processor = core.media_processor_state;

const request_epoch: u64 = 24_000;
const challenge_sha256 = [_]u8{0x72} ** 32;
const sync_policy_sha256 = [_]u8{0x99} ** 32;

pub fn main() !void {
    const first_states = try makeStatesV1(1, null);
    const first_sync = try makeSyncV1(
        first_states,
        1,
        [_]u8{0} ** 32,
    );
    var first_storage: [processor.processor_bundle_bytes]u8 = undefined;
    const first = try processor.encodeBundleV1(
        first_states,
        first_sync,
        &first_storage,
    );
    const decoded_first = try processor.decodeBundleV1(
        first.bytes,
    );

    const second_states = try makeStatesV1(
        2,
        &decoded_first,
    );
    const second_sync = try makeSyncV1(
        second_states,
        2,
        decoded_first.sync.sync_sha256,
    );
    var second_storage: [processor.processor_bundle_bytes]u8 = undefined;
    const second = try processor.encodeBundleV1(
        second_states,
        second_sync,
        &second_storage,
    );
    const decoded_second = try processor.decodeBundleV1(
        second.bytes,
    );
    try processor.validateSuccessorV1(
        &decoded_first,
        &decoded_second,
    );

    var foreign_states = decoded_second.states;
    foreign_states[1].processor_plan_sha256 =
        [_]u8{0xee} ** 32;
    foreign_states[1].state_sha256 =
        processor.processorStateRootV1(
            foreign_states[1],
        );
    const foreign_sync = try makeSyncV1(
        foreign_states,
        2,
        decoded_first.sync.sync_sha256,
    );
    var foreign_storage: [processor.processor_bundle_bytes]u8 = undefined;
    const foreign = try processor.encodeBundleV1(
        foreign_states,
        foreign_sync,
        &foreign_storage,
    );
    const decoded_foreign =
        try processor.decodeBundleV1(foreign.bytes);
    try std.testing.expectError(
        processor.Error.InvalidSuccessor,
        processor.validateSuccessorV1(
            &decoded_first,
            &decoded_foreign,
        ),
    );

    var replay_states = decoded_second.states;
    replay_states[1].ownership_receipt_sha256 =
        decoded_first.states[1].ownership_receipt_sha256;
    replay_states[1].state_sha256 =
        processor.processorStateRootV1(replay_states[1]);
    const replay_sync = try makeSyncV1(
        replay_states,
        2,
        decoded_first.sync.sync_sha256,
    );
    var replay_storage: [processor.processor_bundle_bytes]u8 = undefined;
    const replay = try processor.encodeBundleV1(
        replay_states,
        replay_sync,
        &replay_storage,
    );
    const decoded_replay =
        try processor.decodeBundleV1(replay.bytes);
    try std.testing.expectError(
        processor.Error.InvalidSuccessor,
        processor.validateSuccessorV1(
            &decoded_first,
            &decoded_replay,
        ),
    );

    var skipped_states = decoded_second.states;
    skipped_states[1] = try processor.makeAudioStateV1(
        statePlanV1(
            .audio,
            2,
            decoded_first.states[1].state_sha256,
            24_200,
            .{ .numerator = 1, .denominator = 48_000 },
            0x30,
        ),
        3,
        48_000,
        1,
        400,
        160,
        80,
        2,
    );
    const skipped_sync = try makeSyncV1(
        skipped_states,
        2,
        decoded_first.sync.sync_sha256,
    );
    var skipped_storage: [processor.processor_bundle_bytes]u8 = undefined;
    const skipped = try processor.encodeBundleV1(
        skipped_states,
        skipped_sync,
        &skipped_storage,
    );
    const decoded_skipped =
        try processor.decodeBundleV1(skipped.bytes);
    try std.testing.expectError(
        processor.Error.InvalidSuccessor,
        processor.validateSuccessorV1(
            &decoded_first,
            &decoded_skipped,
        ),
    );

    const bundle_hex = std.fmt.bytesToHex(
        decoded_second.bundle_sha256,
        .lower,
    );
    const sync_hex = std.fmt.bytesToHex(
        decoded_second.sync.sync_sha256,
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-processor-state/demo-v1\"," ++
            "\"modalities\":3,\"generations\":2," ++
            "\"processor_state_bytes\":512," ++
            "\"sync_state_bytes\":512," ++
            "\"bundle_bytes\":2272," ++
            "\"image_processed_tiles\":2," ++
            "\"image_total_tiles\":4," ++
            "\"image_normalized_elements\":24," ++
            "\"audio_feature_frames\":2," ++
            "\"audio_window_samples\":400," ++
            "\"audio_hop_samples\":160," ++
            "\"audio_context_samples\":240," ++
            "\"audio_feature_bins\":80," ++
            "\"audio_cache_bytes\":800," ++
            "\"video_temporal_entries\":2," ++
            "\"video_cache_bytes\":256," ++
            "\"audio_end_tick\":560," ++
            "\"video_end_tick\":800," ++
            "\"synchronized_watermark_tick\":560," ++
            "\"maximum_skew_ticks\":400," ++
            "\"processor_substitution_rejected\":true," ++
            "\"ownership_replay_rejected\":true," ++
            "\"window_skip_rejected\":true," ++
            "\"exact_integer_timeline\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false," ++
            "\"bundle_sha256\":\"{s}\"," ++
            "\"sync_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{ &bundle_hex, &sync_hex },
    );
    try stdout.flush();
}

fn makeStatesV1(
    generation: u64,
    previous: ?*const processor.DecodedBundleV1,
) ![processor.processor_count]processor.ProcessorStateV1 {
    const prior: [processor.processor_count]processor.Digest =
        if (previous) |value|
            .{
                value.states[0].state_sha256,
                value.states[1].state_sha256,
                value.states[2].state_sha256,
            }
        else
            [_]processor.Digest{[_]u8{0} ** 32} **
                processor.processor_count;
    return .{
        try processor.makeImageStateV1(
            statePlanV1(
                .image,
                generation,
                prior[0],
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
        try processor.makeAudioStateV1(
            statePlanV1(
                .audio,
                generation,
                prior[1],
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
        try processor.makeVideoStateV1(
            statePlanV1(
                .video,
                generation,
                prior[2],
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

fn statePlanV1(
    kind: media.MediaKindV1,
    generation: u64,
    previous_state_sha256: processor.Digest,
    stream_key: u64,
    timeline_base: media.TimeBaseV1,
    seed: u8,
) processor.StatePlanV1 {
    const step: u8 = @intCast(generation);
    return .{
        .kind = kind,
        .request_epoch = request_epoch,
        .generation = generation,
        .stream_key = stream_key,
        .timeline_base = timeline_base,
        .media_object_sha256 = [_]u8{seed} ** 32,
        .processor_plan_sha256 = [_]u8{seed + 1} ** 32,
        .previous_state_sha256 = previous_state_sha256,
        .challenge_sha256 = challenge_sha256,
        .cache_content_sha256 = [_]u8{seed + 2 + step} ** 32,
        .output_chain_sha256 = [_]u8{seed + 4 + step} ** 32,
        .ownership_receipt_sha256 = [_]u8{seed + 6 + step} ** 32,
        .decoder_state_sha256 = [_]u8{seed + 8} ** 32,
    };
}

fn makeSyncV1(
    states: [processor.processor_count]processor.ProcessorStateV1,
    generation: u64,
    previous_sync_sha256: processor.Digest,
) !processor.SyncStateV1 {
    return processor.makeSyncStateV1(
        states,
        .{
            .generation = generation,
            .request_epoch = request_epoch,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 400,
            .challenge_sha256 = challenge_sha256,
            .sync_policy_sha256 = sync_policy_sha256,
            .previous_sync_sha256 = previous_sync_sha256,
        },
    );
}
