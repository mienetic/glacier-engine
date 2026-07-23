//! Model-free deterministic image/audio/video transform demonstration.

const std = @import("std");
const core = @import("core");
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;
const transform = core.media_transform;

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
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var decoded_again: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var plan_roots: [3]transform.Digest = undefined;
    var receipt_roots: [3]transform.Digest = undefined;
    var total_output_bytes: u64 = 0;
    var total_mappings: u64 = 0;

    for (specs, 0..) |spec, index| {
        const encoded_fixture = try fixture_api.encodeFixtureV1(
            spec,
            &fixture_storage,
        );
        const fixture = try fixture_api.parseFixtureV1(encoded_fixture);
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
            &decoded,
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
        const transform_receipt = try transform.executeV1(
            encoded_fixture,
            encoded_decode_plan,
            encoded_transform_plan,
            &decoded_again,
            &output,
            &mappings,
        );
        const output_bytes: usize = @intCast(
            transform_receipt.output_bytes,
        );
        if (!std.mem.eql(
            u8,
            output[0..output_bytes],
            expected[index],
        )) return error.OutputMismatch;
        plan_roots[index] = transform_receipt.transform_plan_sha256;
        receipt_roots[index] = transform_receipt.receipt_sha256;
        total_output_bytes += transform_receipt.output_bytes;
        total_mappings += transform_receipt.mapping_count;
    }

    const image_plan_hex = std.fmt.bytesToHex(plan_roots[0], .lower);
    const audio_plan_hex = std.fmt.bytesToHex(plan_roots[1], .lower);
    const video_plan_hex = std.fmt.bytesToHex(plan_roots[2], .lower);
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
        "{{\"schema\":\"glacier.media-transform/demo-v1\"," ++
            "\"operations\":3,\"sealed_plan_bytes\":{d}," ++
            "\"image_crop\":true,\"image_nearest_resize\":true," ++
            "\"image_tile_mapping\":true," ++
            "\"audio_weighted_mix\":true," ++
            "\"audio_exact_decimation\":true," ++
            "\"video_keyframe_selection\":true," ++
            "\"total_output_bytes\":{d},\"exact_mappings\":{d}," ++
            "\"caller_owned_storage\":true," ++
            "\"heap_allocations\":0,\"scratch_bytes\":0," ++
            "\"required_capabilities\":0," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false,\"verified\":true," ++
            "\"image_plan_sha256\":\"{s}\"," ++
            "\"audio_plan_sha256\":\"{s}\"," ++
            "\"video_plan_sha256\":\"{s}\"," ++
            "\"image_receipt_sha256\":\"{s}\"," ++
            "\"audio_receipt_sha256\":\"{s}\"," ++
            "\"video_receipt_sha256\":\"{s}\"}}\n",
        .{
            transform.transform_plan_bytes,
            total_output_bytes,
            total_mappings,
            &image_plan_hex,
            &audio_plan_hex,
            &video_plan_hex,
            &image_receipt_hex,
            &audio_receipt_hex,
            &video_receipt_hex,
        },
    );
    try stdout.flush();
}
