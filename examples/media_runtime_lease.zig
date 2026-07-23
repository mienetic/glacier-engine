//! Per-buffer LeaseTree ownership for transactional image/audio/video work.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const media = core.media_contract;
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;
const flat_runtime = core.media_runtime_txn;
const runtime = core.media_runtime_lease;

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
    var scratch: [1]u8 = undefined;
    var receipt_storage: [runtime.receipt_bytes]u8 = undefined;
    var receipt_roots: [3]runtime.Digest = undefined;
    var total_claimed_host_bytes: u64 = 0;
    var retained_output_host_bytes: u64 = 0;
    var early_retired_allocations: u64 = 0;
    var total_reclaim_commits: u64 = 0;
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
        const total_claim = try flat_runtime.claimForExecutionV1(
            encoded_fixture.len,
            transform_plan,
        );
        var slots = [_]resource_bank.Slot{.{}};
        var tree_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
        var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
            &slots,
            &tree_roots,
            &nodes,
            try flat_runtime.limitsForClaimV1(total_claim),
            2100 + index,
        );
        const request_epoch: u64 = 2200 + index;
        const owner_key: u64 = 2300 + index;
        const tree_key: u64 = 2400 + index;
        const authority_key: u64 = 2500 + index;
        const tenant_key: u64 = 2600 + index;
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
                [_]u8{@intCast(0xa0 + index)} ** 32,
            );
        const state_before = publication_state;
        var session: runtime.Session = .{};
        try session.init(
            &bank,
            owner_key,
            tree_key,
            authority_key,
            tenant_key,
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
                scratch[0..0],
            );
            try aborted.abort();
            abort_scrub_verified =
                std.mem.allEqual(
                    u8,
                    output[0..@intCast(transform_plan.output_bytes)],
                    0,
                ) and std.meta.eql(state_before, publication_state) and
                (try bank.snapshotV3()).live_allocations == 0;
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
            scratch[0..0],
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
        try runtime.verifyLeaseExecutionReceiptV1(
            state_before,
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output[0..output_bytes],
            mappings[0..mapping_count],
            owner_key,
            tree_key,
            authority_key,
            tenant_key,
            runtime_receipt,
        );
        const encoded_receipt =
            try runtime.encodeLeaseExecutionReceiptV1(
                runtime_receipt,
                &receipt_storage,
            );
        const decoded_receipt =
            try runtime.decodeLeaseExecutionReceiptV1(
                encoded_receipt,
            );
        if (!std.meta.eql(runtime_receipt, decoded_receipt))
            return error.ReceiptRoundTripFailed;
        receipt_roots[index] = runtime_receipt.receipt_sha256;
        total_claimed_host_bytes += try total_claim.hostBytes();

        try session.retireProvisional();
        const retained = try bank.snapshotV3();
        if (retained.live_allocations != 1)
            return error.ProvisionalRetirementFailed;
        retained_output_host_bytes += try retained.used.hostBytes();
        early_retired_allocations +=
            runtime_receipt.provisional_binding_count;

        try session.closeAndRelease();
        const final = try bank.snapshotV3();
        if (!final.used.isZero() or final.live_allocations != 0)
            return error.ResourceLeak;
        total_reclaim_commits += final.lease_reclaim_commits;
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
        "{{\"schema\":\"glacier.media-runtime-lease/demo-v1\"," ++
            "\"modalities\":3,\"runtime_receipt_bytes\":{d}," ++
            "\"binding_roles\":3,\"committed_publications\":3," ++
            "\"aborted_publications\":1,\"abort_scrub_verified\":true," ++
            "\"total_claimed_host_bytes\":{d}," ++
            "\"retained_parent_plus_output_host_bytes\":{d}," ++
            "\"early_retired_allocations\":{d}," ++
            "\"lease_reclaim_commits\":{d}," ++
            "\"final_bank_host_bytes\":0,\"final_live_allocations\":0," ++
            "\"candidate_revalidation\":true," ++
            "\"per_buffer_generation_fencing\":true," ++
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
            retained_output_host_bytes,
            early_retired_allocations,
            total_reclaim_commits,
            &image_receipt_hex,
            &audio_receipt_hex,
            &video_receipt_hex,
        },
    );
    try stdout.flush();
}
