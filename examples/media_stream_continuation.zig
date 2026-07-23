//! Fresh-runtime image/audio/video checkpoint and resume demonstration.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;
const stream_runtime = core.media_stream_runtime;
const continuation = core.media_stream_continuation;

pub fn main() !void {
    const specs = [_]fixture_api.FixtureSpecV1{
        fixture_api.imageSpecV1(),
        fixture_api.audioSpecV1(),
        fixture_api.videoSpecV1(),
    };
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 =
        undefined;
    var plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var outputs: [2][fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var mappings: [4]transform.TransformMappingV1 =
        undefined;
    var scratch: [1]u8 = undefined;
    var checkpoint_storage: [continuation.checkpoint_bytes]u8 =
        undefined;
    var tail_roots: [3]continuation.Digest = undefined;
    var checkpoint_roots: [3]continuation.Digest =
        undefined;
    var source_release_count: u64 = 0;
    var reserved_before_materialization: u64 = 0;
    var restored_output_count: u64 = 0;
    var resumed_chunk_count: u64 = 0;
    var materialization_rejections: u64 = 0;

    for (specs, 0..) |spec, case_index| {
        const encoded_fixture =
            try fixture_api.encodeFixtureV1(
                spec,
                &fixture_storage,
            );
        const fixture = try fixture_api.parseFixtureV1(
            encoded_fixture,
        );
        const fixture_plan =
            try fixture_api.makeDecodePlanV1(
                fixture,
                [_]u8{0xd1} ** 32,
                [_]u8{0xe1} ** 32,
            );
        const encoded_decode_plan =
            try decode_plan.encodePlanV1(
                fixture_plan,
                &decode_plan_storage,
            );
        const decode_receipt =
            try fixture_api.decodeFixtureV1(
                encoded_fixture,
                encoded_decode_plan,
                &decoded_for_plan,
            );
        const timeline_base: media.TimeBaseV1 =
            switch (case_index) {
                0 => .{
                    .numerator = 1,
                    .denominator = 1,
                },
                1 => .{
                    .numerator = 1,
                    .denominator = 16_000,
                },
                2 => fixture.time_base,
                else => unreachable,
            };

        var source_slots = [_]resource_bank.Slot{.{}};
        var source_roots =
            [_]resource_bank.LeaseTreeRootSlot{.{}};
        var source_nodes =
            [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
        const source_bank_epoch: u64 =
            8100 + case_index;
        var source_bank =
            try resource_bank.Bank.initWithLeaseTreeStorage(
                &source_slots,
                &source_roots,
                &source_nodes,
                .{},
                source_bank_epoch,
            );
        const request_epoch: u64 = 8200 + case_index;
        var source_state =
            try media.initializePublicationStateV1(
                request_epoch,
                1,
                timeline_base,
                fixture.media_object_sha256,
                [_]u8{@intCast(0xa0 + case_index)} ** 32,
            );
        var source_stream: stream_runtime.StreamSession =
            .{};
        try source_stream.init(
            &source_bank,
            &source_state,
            8300 + case_index,
            8310 + case_index * 10,
            8320 + case_index * 10,
            8330 + case_index * 10,
            8340 + case_index,
            request_epoch,
            2,
        );

        const first_plan = try makeChunkPlan(
            fixture,
            decode_receipt,
            case_index,
            0,
        );
        const first_encoded =
            try transform.encodeTransformPlanV1(
                first_plan,
                &plan_storage,
            );
        var first = try source_stream.prepareChunk(
            0,
            first_plan.logical_units,
            encoded_fixture,
            encoded_decode_plan,
            first_encoded,
            &decoded,
            &outputs[0],
            &mappings,
            scratch[0..0],
        );
        const first_committed = try first.commit();
        const first_output = outputs[0][0..@intCast(first_plan.output_bytes)];
        const retained = [_][]const u8{first_output};
        const restore_bank_epoch: u64 =
            8400 + case_index;
        const checkpoint = try continuation.makeCheckpointV1(
            &source_stream,
            first_committed.execution.kind,
            .{
                .checkpoint_generation = 1,
                .chunk_limit = 2,
                .restore_bank_epoch = restore_bank_epoch,
                .restore_owner_key_base = 8410 + case_index * 10,
                .restore_tree_key_base = 8420 + case_index * 10,
                .restore_authority_key_base = 8430 + case_index * 10,
                .next_owner_key_base = 8440 + case_index * 10,
                .next_tree_key_base = 8450 + case_index * 10,
                .next_authority_key_base = 8460 + case_index * 10,
                .tenant_key = 8470 + case_index,
                .challenge_sha256 = [_]u8{@intCast(0xc0 + case_index)} ** 32,
            },
            &retained,
        );
        const encoded_checkpoint =
            try continuation.encodeCheckpointV1(
                checkpoint,
                &checkpoint_storage,
            );
        checkpoint_roots[case_index] =
            checkpoint.checkpoint_sha256;
        try source_stream.closeAndRelease();
        if (!(try source_bank.snapshot()).used.isZero())
            return error.SourceOwnershipLeak;
        source_release_count += 1;

        var target_slots =
            [_]resource_bank.Slot{.{}} ** 2;
        var target_roots =
            [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
        var target_nodes =
            [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
        var target_bank =
            try resource_bank.Bank.initWithLeaseTreeStorage(
                &target_slots,
                &target_roots,
                &target_nodes,
                .{},
                restore_bank_epoch,
            );
        var target_state: media.PublicationStateV1 =
            undefined;
        var resumed: continuation.ResumeSession = .{};
        try resumed.prepareV1(
            &target_bank,
            &target_state,
            encoded_checkpoint,
            checkpoint.checkpoint_sha256,
        );
        const reserved = try target_bank.snapshotV3();
        if (reserved.reserved_unmaterialized_allocations !=
            1 or reserved.live_allocations != 0)
            return error.ChargeBeforeMaterializeMissing;
        reserved_before_materialization += 1;

        if (case_index == 1) {
            var wrong: [fixture_api.maximum_payload_bytes]u8 =
                undefined;
            @memcpy(
                wrong[0..first_output.len],
                first_output,
            );
            wrong[0] ^= 1;
            const wrong_outputs = [_][]const u8{
                wrong[0..first_output.len],
            };
            const rejected =
                if (resumed.commitMaterializedV1(
                    &wrong_outputs,
                )) |_| false else |err| blk: {
                    if (err !=
                        error.InvalidMaterialization)
                        return err;
                    break :blk true;
                };
            if (!rejected)
                return error.InvalidMaterializationAccepted;
            materialization_rejections += 1;
        }
        try resumed.commitMaterializedV1(&retained);
        restored_output_count += 1;

        const second_plan = try makeChunkPlan(
            fixture,
            decode_receipt,
            case_index,
            1,
        );
        const second_encoded =
            try transform.encodeTransformPlanV1(
                second_plan,
                &plan_storage,
            );
        var second = try resumed.stream.prepareChunk(
            target_state.visible_units,
            target_state.visible_units +
                second_plan.logical_units,
            encoded_fixture,
            encoded_decode_plan,
            second_encoded,
            &decoded,
            &outputs[1],
            &mappings,
            scratch[0..0],
        );
        const second_committed = try second.commit();
        if (second_committed.stream.stream_chunk_index != 1 or
            !std.mem.eql(
                u8,
                &second_committed.stream
                    .previous_chunk_sha256,
                &checkpoint.last_chunk_sha256,
            ) or target_state.visible_chunks != 2)
            return error.InvalidResumedPublication;
        tail_roots[case_index] =
            second_committed.stream.receipt_sha256;
        resumed_chunk_count += 1;
        try resumed.closeAndRelease();
        const final = try target_bank.snapshotV3();
        if (!final.used.isZero() or
            final.live_allocations != 0 or
            final.active_lease_trees != 0)
            return error.TargetOwnershipLeak;
    }

    const image_checkpoint_hex = std.fmt.bytesToHex(
        checkpoint_roots[0],
        .lower,
    );
    const image_tail_hex = std.fmt.bytesToHex(
        tail_roots[0],
        .lower,
    );
    const audio_tail_hex = std.fmt.bytesToHex(
        tail_roots[1],
        .lower,
    );
    const video_tail_hex = std.fmt.bytesToHex(
        tail_roots[2],
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-stream-continuation/demo-v1\"," ++
            "\"modalities\":3,\"checkpoint_bytes\":{d}," ++
            "\"portable_checkpoints\":3," ++
            "\"source_ownership_releases\":{d}," ++
            "\"fresh_bank_epochs\":3," ++
            "\"reserved_before_materialization\":{d}," ++
            "\"restored_outputs\":{d}," ++
            "\"resumed_chunks\":{d}," ++
            "\"duplicate_publications\":0," ++
            "\"materialization_rejections\":{d}," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"process_restart\":false," ++
            "\"durable_file_io\":false," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false," ++
            "\"verified\":true," ++
            "\"image_checkpoint_sha256\":\"{s}\"," ++
            "\"image_tail_sha256\":\"{s}\"," ++
            "\"audio_tail_sha256\":\"{s}\"," ++
            "\"video_tail_sha256\":\"{s}\"}}\n",
        .{
            continuation.checkpoint_bytes,
            source_release_count,
            reserved_before_materialization,
            restored_output_count,
            resumed_chunk_count,
            materialization_rejections,
            &image_checkpoint_hex,
            &image_tail_hex,
            &audio_tail_hex,
            &video_tail_hex,
        },
    );
    try stdout.flush();
}

fn makeChunkPlan(
    fixture: fixture_api.ParsedFixtureV1,
    decode_receipt: fixture_api.DecodeReceiptV1,
    case_index: usize,
    chunk_index: usize,
) !transform.TransformPlanV1 {
    return switch (case_index) {
        0 => try transform.makeImagePlanV1(
            fixture,
            decode_receipt,
            0,
            chunk_index,
            2,
            1,
            2,
            1,
            1,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ),
        1 => try transform.makeAudioPlanV1(
            fixture,
            decode_receipt,
            chunk_index * 3,
            3,
            16_000,
            1,
            0,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ),
        2 => blk: {
            const selected =
                [_]u64{@intCast(chunk_index)};
            break :blk try transform.makeVideoPlanV1(
                fixture,
                decode_receipt,
                &selected,
                [_]u8{0xf1} ** 32,
                [_]u8{0xf2} ** 32,
            );
        },
        else => unreachable,
    };
}
