//! Bounded two-chunk image/audio/video stream demonstration.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;
const stream_runtime = core.media_stream_runtime;

pub fn main() !void {
    const specs = [_]fixture_api.FixtureSpecV1{
        fixture_api.imageSpecV1(),
        fixture_api.audioSpecV1(),
        fixture_api.videoSpecV1(),
    };
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var outputs: [2][fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    var tail_roots: [3]stream_runtime.Digest = undefined;
    var committed_chunks: u64 = 0;
    var visible_units: u64 = 0;
    var early_retired_allocations: u64 = 0;
    var reclaim_commits: u64 = 0;
    var cancellation_reclaimed = false;
    var boundary_rejections: u64 = 0;

    for (specs, 0..) |spec, case_index| {
        const encoded_fixture = try fixture_api.encodeFixtureV1(
            spec,
            &fixture_storage,
        );
        const fixture = try fixture_api.parseFixtureV1(
            encoded_fixture,
        );
        const fixture_plan = try fixture_api.makeDecodePlanV1(
            fixture,
            [_]u8{0xd1} ** 32,
            [_]u8{0xe1} ** 32,
        );
        const encoded_decode_plan = try decode_plan.encodePlanV1(
            fixture_plan,
            &decode_plan_storage,
        );
        const decode_receipt = try fixture_api.decodeFixtureV1(
            encoded_fixture,
            encoded_decode_plan,
            &decoded_for_plan,
        );
        const timeline_base: media.TimeBaseV1 = switch (case_index) {
            0 => .{ .numerator = 1, .denominator = 1 },
            1 => .{ .numerator = 1, .denominator = 16_000 },
            2 => fixture.time_base,
            else => unreachable,
        };
        var slots = [_]resource_bank.Slot{.{}} ** 2;
        var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 2;
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 12;
        var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
            &slots,
            &roots,
            &nodes,
            .{},
            5100 + case_index,
        );
        const request_epoch: u64 = 5200 + case_index;
        var state = try media.initializePublicationStateV1(
            request_epoch,
            1,
            timeline_base,
            fixture.media_object_sha256,
            [_]u8{@intCast(0xa0 + case_index)} ** 32,
        );
        var stream: stream_runtime.StreamSession = .{};
        try stream.init(
            &bank,
            &state,
            5300 + case_index,
            5400 + case_index * 10,
            5500 + case_index * 10,
            5600 + case_index * 10,
            5700 + case_index,
            request_epoch,
            2,
        );

        for (0..2) |chunk_index| {
            const plan = try makeChunkPlan(
                fixture,
                decode_receipt,
                case_index,
                chunk_index,
            );
            const encoded_plan =
                try transform.encodeTransformPlanV1(
                    plan,
                    &plan_storage,
                );
            const units_after = state.visible_units +
                plan.logical_units;

            if (case_index == 2 and chunk_index == 1) {
                const gap = stream.prepareChunk(
                    state.visible_units + 1,
                    units_after + 1,
                    encoded_fixture,
                    encoded_decode_plan,
                    encoded_plan,
                    &decoded,
                    &outputs[chunk_index],
                    &mappings,
                    scratch[0..0],
                );
                if (gap) |_| return error.GapAccepted else |err| {
                    if (err != error.InvalidChunkBoundary)
                        return err;
                }
                const overlap = stream.prepareChunk(
                    state.visible_units - 1,
                    units_after - 1,
                    encoded_fixture,
                    encoded_decode_plan,
                    encoded_plan,
                    &decoded,
                    &outputs[chunk_index],
                    &mappings,
                    scratch[0..0],
                );
                if (overlap) |_| return error.OverlapAccepted else |err| {
                    if (err != error.InvalidChunkBoundary)
                        return err;
                }
                boundary_rejections += 2;
            }

            if (case_index == 1 and chunk_index == 1) {
                const state_before = state;
                const used_before = (try bank.snapshot()).used;
                var cancelled = try stream.prepareChunk(
                    state.visible_units,
                    units_after,
                    encoded_fixture,
                    encoded_decode_plan,
                    encoded_plan,
                    &decoded,
                    &outputs[chunk_index],
                    &mappings,
                    scratch[0..0],
                );
                try cancelled.abort();
                cancellation_reclaimed =
                    std.meta.eql(state_before, state) and
                    std.meta.eql(
                        used_before,
                        (try bank.snapshot()).used,
                    );
                if (!cancellation_reclaimed)
                    return error.CancellationLeak;
            }

            var transaction = try stream.prepareChunk(
                state.visible_units,
                units_after,
                encoded_fixture,
                encoded_decode_plan,
                encoded_plan,
                &decoded,
                &outputs[chunk_index],
                &mappings,
                scratch[0..0],
            );
            const committed = try transaction.commit();
            committed_chunks += 1;
            early_retired_allocations +=
                committed.execution.provisional_binding_count;
            if ((try bank.snapshotV3()).live_allocations !=
                chunk_index + 1)
                return error.OutputLeaseNotRetained;
            tail_roots[case_index] =
                committed.stream.receipt_sha256;
        }
        visible_units += state.visible_units;
        try stream.closeAndRelease();
        const final = try bank.snapshotV3();
        if (!final.used.isZero() or
            final.live_allocations != 0 or
            final.active_lease_trees != 0)
            return error.ResourceLeak;
        reclaim_commits += final.lease_reclaim_commits;
    }

    if (!cancellation_reclaimed or boundary_rejections != 2)
        return error.MissingRejectionEvidence;
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
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-stream-runtime/demo-v1\"," ++
            "\"modalities\":3,\"chunks_per_modality\":2," ++
            "\"committed_chunks\":{d},\"visible_units\":{d}," ++
            "\"chunk_receipt_bytes\":{d}," ++
            "\"retained_output_leases_per_stream\":2," ++
            "\"early_retired_allocations\":{d}," ++
            "\"cancelled_unpublished_chunks\":1," ++
            "\"cancellation_reclaimed\":true," ++
            "\"target_gap_rejections\":1," ++
            "\"target_overlap_rejections\":1," ++
            "\"lease_reclaim_commits\":{d}," ++
            "\"final_bank_host_bytes\":0," ++
            "\"final_live_allocations\":0," ++
            "\"final_active_lease_trees\":0," ++
            "\"portable_chunk_chain\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false,\"verified\":true," ++
            "\"image_tail_sha256\":\"{s}\"," ++
            "\"audio_tail_sha256\":\"{s}\"," ++
            "\"video_tail_sha256\":\"{s}\"}}\n",
        .{
            committed_chunks,
            visible_units,
            stream_runtime.chunk_receipt_bytes,
            early_retired_allocations,
            reclaim_commits,
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
            const selected = [_]u64{@intCast(chunk_index)};
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
