//! Resource-admitted transactional image/audio/video runtime demonstration.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;
const runtime = core.media_runtime_txn;

pub fn main() !void {
    const specs = [_]fixture_api.FixtureSpecV1{
        fixture_api.imageSpecV1(),
        fixture_api.audioSpecV1(),
        fixture_api.videoSpecV1(),
    };
    const expected = [_][]const u8{
        &[_]u8{
            0,   255, 0,   0,   255, 0,
            255, 255, 255, 255, 255, 255,
        },
        &[_]u8{ 0x00, 0xc0, 0x55, 0x15 },
        &[_]u8{ 255, 128, 64, 0 },
    };
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var transform_plan_storage: [transform.transform_plan_bytes]u8 =
        undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 =
        undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var receipt_storage: [runtime.receipt_bytes]u8 = undefined;
    var receipt_roots: [3]runtime.Digest = undefined;
    var total_claimed_host_bytes: u64 = 0;
    var total_output_bytes: u64 = 0;
    var total_mappings: u64 = 0;
    var total_releases: u64 = 0;
    var abort_scrub_verified = false;

    for (specs, 0..) |spec, index| {
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
        const transform_plan = switch (index) {
            0 => try transform.makeImagePlanV1(
                fixture,
                decode_receipt,
                1,
                0,
                1,
                2,
                2,
                2,
                1,
                1,
                [_]u8{0xf1} ** 32,
                [_]u8{0xf2} ** 32,
            ),
            1 => try transform.makeAudioPlanV1(
                fixture,
                decode_receipt,
                0,
                6,
                16_000,
                1,
                0,
                1,
                [_]u8{0xf1} ** 32,
                [_]u8{0xf2} ** 32,
            ),
            2 => blk: {
                const selected = [_]u64{1};
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
        const encoded_transform_plan =
            try transform.encodeTransformPlanV1(
                transform_plan,
                &transform_plan_storage,
            );
        const claim = try runtime.claimForExecutionV1(
            encoded_fixture.len,
            transform_plan,
        );
        var slots = [_]resource_bank.Slot{.{}};
        var bank = try resource_bank.Bank.init(
            &slots,
            try runtime.limitsForClaimV1(claim),
            800 + index,
        );
        const request_epoch: u64 = 900 + index;
        var previous_commit: runtime.Digest = undefined;
        @memset(&previous_commit, @intCast(0xa0 + index));
        const timeline_base: media.TimeBaseV1 = switch (transform_plan.kind) {
            .image => .{ .numerator = 1, .denominator = 1 },
            .audio, .video => transform_plan.target_time_base,
        };
        var publication_state =
            try media.initializePublicationStateV1(
                request_epoch,
                1,
                timeline_base,
                fixture.media_object_sha256,
                previous_commit,
            );
        const state_before = publication_state;
        var session: runtime.Session = .{};
        try session.init(
            &bank,
            700 + index,
            request_epoch,
            &publication_state,
            encoded_fixture,
            encoded_transform_plan,
        );

        if (index == 1) {
            var aborted = try session.prepare(
                encoded_fixture,
                encoded_decode_plan,
                encoded_transform_plan,
                &decoded,
                &output,
                &mappings,
            );
            try aborted.abort();
            abort_scrub_verified =
                std.mem.allEqual(
                    u8,
                    output[0..transform_plan.output_bytes],
                    0,
                ) and std.meta.eql(state_before, publication_state);
            if (!abort_scrub_verified)
                return error.AbortScrubFailed;
        }

        var transaction = try session.prepare(
            encoded_fixture,
            encoded_decode_plan,
            encoded_transform_plan,
            &decoded,
            &output,
            &mappings,
        );
        const transform_receipt =
            session.active_transform_receipt orelse
            return error.MissingTransformReceipt;
        const runtime_receipt = try transaction.commit();
        const output_bytes: usize = @intCast(
            runtime_receipt.output_bytes,
        );
        const mapping_count: usize = @intCast(
            runtime_receipt.mapping_count,
        );
        if (!std.mem.eql(
            u8,
            output[0..output_bytes],
            expected[index],
        )) return error.OutputMismatch;
        try runtime.verifyExecutionReceiptV1(
            state_before,
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output[0..output_bytes],
            mappings[0..mapping_count],
            runtime_receipt,
        );
        const encoded_receipt = try runtime.encodeExecutionReceiptV1(
            runtime_receipt,
            &receipt_storage,
        );
        const decoded_receipt =
            try runtime.decodeExecutionReceiptV1(encoded_receipt);
        if (!std.meta.eql(runtime_receipt, decoded_receipt))
            return error.ReceiptRoundTripFailed;
        receipt_roots[index] = runtime_receipt.receipt_sha256;
        total_claimed_host_bytes += try claim.hostBytes();
        total_output_bytes += runtime_receipt.output_bytes;
        total_mappings += runtime_receipt.mapping_count;
        try session.closeAndRelease();
        const snapshot = try bank.snapshot();
        if (!snapshot.used.isZero() or snapshot.releases != 1)
            return error.ResourceLeak;
        total_releases += snapshot.releases;
    }

    const image_receipt_hex = std.fmt.bytesToHex(
        receipt_roots[0],
        .lower,
    );
    const audio_receipt_hex = std.fmt.bytesToHex(
        receipt_roots[1],
        .lower,
    );
    const video_receipt_hex = std.fmt.bytesToHex(
        receipt_roots[2],
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-runtime-txn/demo-v1\"," ++
            "\"modalities\":3,\"runtime_receipt_bytes\":{d}," ++
            "\"admitted_sessions\":3,\"committed_publications\":3," ++
            "\"aborted_publications\":1,\"abort_scrub_verified\":true," ++
            "\"total_claimed_host_bytes\":{d}," ++
            "\"total_output_bytes\":{d},\"exact_mappings\":{d}," ++
            "\"resource_releases\":{d},\"final_bank_host_bytes\":0," ++
            "\"candidate_revalidation\":true," ++
            "\"caller_owned_storage\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false,\"verified\":true," ++
            "\"image_receipt_sha256\":\"{s}\"," ++
            "\"audio_receipt_sha256\":\"{s}\"," ++
            "\"video_receipt_sha256\":\"{s}\"}}\n",
        .{
            runtime.receipt_bytes,
            total_claimed_host_bytes,
            total_output_bytes,
            total_mappings,
            total_releases,
            &image_receipt_hex,
            &audio_receipt_hex,
            &video_receipt_hex,
        },
    );
    try stdout.flush();
}
