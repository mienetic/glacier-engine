//! Model-free bounded image/audio/video decode fixture demonstration.

const std = @import("std");
const core = @import("core");
const decode_plan = core.media_decode_plan;
const fixture_api = core.media_fixture;

pub fn main() !void {
    const specs = [_]fixture_api.FixtureSpecV1{
        fixture_api.imageSpecV1(),
        fixture_api.audioSpecV1(),
        fixture_api.videoSpecV1(),
    };
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var fixture_roots: [3]fixture_api.Digest = undefined;
    var plan_roots: [3]fixture_api.Digest = undefined;
    var receipt_roots: [3]fixture_api.Digest = undefined;
    var total_fixture_bytes: u64 = 0;
    var total_output_bytes: u64 = 0;
    var total_units: u64 = 0;

    for (specs, 0..) |spec, index| {
        const encoded_fixture = try fixture_api.encodeFixtureV1(
            spec,
            &fixture_storage,
        );
        const fixture = try fixture_api.parseFixtureV1(
            encoded_fixture,
        );
        const plan = try fixture_api.makeDecodePlanV1(
            fixture,
            [_]u8{0xd1} ** 32,
            [_]u8{0xe1} ** 32,
        );
        const encoded_plan = try decode_plan.encodePlanV1(
            plan,
            &plan_storage,
        );
        const receipt = try fixture_api.decodeFixtureV1(
            encoded_fixture,
            encoded_plan,
            &output,
        );
        if (!std.mem.eql(
            u8,
            output[0..spec.payload.len],
            spec.payload,
        )) return error.OutputMismatch;
        const mapped_units = try fixture_api.verifyCompleteMappingV1(
            encoded_fixture,
        );
        if (mapped_units != receipt.logical_units)
            return error.IncompleteMapping;
        fixture_roots[index] = fixture.fixture_sha256;
        plan_roots[index] = try decode_plan.planSha256V1(encoded_plan);
        receipt_roots[index] = receipt.receipt_sha256;
        total_fixture_bytes += encoded_fixture.len;
        total_output_bytes += receipt.output_bytes;
        total_units += receipt.logical_units;
    }

    var image_fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var audio_fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var image_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    const image_encoded = try fixture_api.encodeFixtureV1(
        fixture_api.imageSpecV1(),
        &image_fixture_storage,
    );
    const audio_encoded = try fixture_api.encodeFixtureV1(
        fixture_api.audioSpecV1(),
        &audio_fixture_storage,
    );
    const image = try fixture_api.parseFixtureV1(image_encoded);
    const image_plan = try fixture_api.makeDecodePlanV1(
        image,
        [_]u8{0xd1} ** 32,
        [_]u8{0xe1} ** 32,
    );
    const image_plan_encoded = try decode_plan.encodePlanV1(
        image_plan,
        &image_plan_storage,
    );
    var foreign_output: [fixture_api.audio_payload.len]u8 = undefined;
    const foreign_plan_rejected = if (fixture_api.decodeFixtureV1(
        audio_encoded,
        image_plan_encoded,
        &foreign_output,
    )) |_| false else |_| true;
    var short_output: [fixture_api.image_payload.len - 1]u8 =
        [_]u8{0x5a} ** (fixture_api.image_payload.len - 1);
    const short_output_rejected = if (fixture_api.decodeFixtureV1(
        image_encoded,
        image_plan_encoded,
        &short_output,
    )) |_| false else |_| true;
    if (!foreign_plan_rejected or
        !short_output_rejected or
        !std.mem.allEqual(u8, &short_output, 0x5a))
        return error.FailClosedCheckFailed;

    const image_fixture_hex = std.fmt.bytesToHex(
        fixture_roots[0],
        .lower,
    );
    const audio_fixture_hex = std.fmt.bytesToHex(
        fixture_roots[1],
        .lower,
    );
    const video_fixture_hex = std.fmt.bytesToHex(
        fixture_roots[2],
        .lower,
    );
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
        "{{\"schema\":\"glacier.media-decode-fixture/demo-v1\"," ++
            "\"fixtures\":3,\"sealed_plan_bytes\":{d}," ++
            "\"fixture_header_bytes\":{d}," ++
            "\"total_fixture_bytes\":{d}," ++
            "\"total_decoded_bytes\":{d}," ++
            "\"mapped_units\":{d}," ++
            "\"image_pixels\":4,\"image_channels\":3," ++
            "\"audio_frames\":8,\"audio_channels\":2," ++
            "\"audio_sample_rate\":48000," ++
            "\"video_frames\":2,\"video_keyframes\":2," ++
            "\"complete_source_mapping\":true," ++
            "\"caller_owned_output\":true," ++
            "\"heap_allocations\":0,\"scratch_bytes\":0," ++
            "\"required_capabilities\":0," ++
            "\"foreign_plan_rejected\":true," ++
            "\"short_output_rejected_without_mutation\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false," ++
            "\"model_execution\":false,\"verified\":true," ++
            "\"image_fixture_sha256\":\"{s}\"," ++
            "\"audio_fixture_sha256\":\"{s}\"," ++
            "\"video_fixture_sha256\":\"{s}\"," ++
            "\"image_receipt_sha256\":\"{s}\"," ++
            "\"audio_receipt_sha256\":\"{s}\"," ++
            "\"video_receipt_sha256\":\"{s}\"}}\n",
        .{
            decode_plan.plan_bytes,
            fixture_api.fixture_header_bytes,
            total_fixture_bytes,
            total_output_bytes,
            total_units,
            &image_fixture_hex,
            &audio_fixture_hex,
            &video_fixture_hex,
            &image_receipt_hex,
            &audio_receipt_hex,
            &video_receipt_hex,
        },
    );
    try stdout.flush();
}
