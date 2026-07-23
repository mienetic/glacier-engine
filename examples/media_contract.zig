//! Model-free shared image/audio/video contract demonstration.

const std = @import("std");
const media = @import("core").media_contract;

fn descriptor(kind: media.MediaKindV1) media.MediaObjectV1 {
    return switch (kind) {
        .image => .{
            .kind = .image,
            .semantic_abi = 1,
            .byte_length = 12,
            .container_id = 1,
            .codec_id = 1,
            .axes = .{ 2, 2, 3 },
            .time_base = .{ .numerator = 0, .denominator = 1 },
            .tenant_scope_sha256 = [_]u8{0x41} ** 32,
            .content_sha256 = [_]u8{0x42} ** 32,
            .metadata_policy_sha256 = [_]u8{0x43} ** 32,
            .provenance_sha256 = [_]u8{0x44} ** 32,
        },
        .audio => .{
            .kind = .audio,
            .semantic_abi = 2,
            .byte_length = 192_000,
            .container_id = 2,
            .codec_id = 2,
            .axes = .{ 48_000, 2, 48_000 },
            .time_base = .{ .numerator = 1, .denominator = 48_000 },
            .tenant_scope_sha256 = [_]u8{0x51} ** 32,
            .content_sha256 = [_]u8{0x52} ** 32,
            .metadata_policy_sha256 = [_]u8{0x53} ** 32,
            .provenance_sha256 = [_]u8{0x54} ** 32,
        },
        .video => .{
            .kind = .video,
            .semantic_abi = 3,
            .byte_length = 4096,
            .container_id = 3,
            .codec_id = 3,
            .axes = .{ 16, 16, 30 },
            .time_base = .{ .numerator = 1, .denominator = 30 },
            .tenant_scope_sha256 = [_]u8{0x61} ** 32,
            .content_sha256 = [_]u8{0x62} ** 32,
            .metadata_policy_sha256 = [_]u8{0x63} ** 32,
            .provenance_sha256 = [_]u8{0x64} ** 32,
        },
    };
}

fn event(
    sequence: u64,
    source_start: u64,
    source_end: u64,
    target_start: u64,
    target_end: u64,
    object_sha256: media.Digest,
    previous_event_sha256: media.Digest,
) media.TimelineEventV1 {
    return .{
        .kind = .resample,
        .sequence = sequence,
        .media_object_sha256 = object_sha256,
        .source = .{
            .start = .{
                .ticks = source_start,
                .base = .{ .numerator = 1, .denominator = 48_000 },
            },
            .end = .{
                .ticks = source_end,
                .base = .{ .numerator = 1, .denominator = 48_000 },
            },
        },
        .target = .{
            .start = .{
                .ticks = target_start,
                .base = .{ .numerator = 1, .denominator = 16_000 },
            },
            .end = .{
                .ticks = target_end,
                .base = .{ .numerator = 1, .denominator = 16_000 },
            },
        },
        .plan_sha256 = [_]u8{0x73} ** 32,
        .previous_event_sha256 = previous_event_sha256,
    };
}

pub fn main() !void {
    var roots: [3]media.Digest = undefined;
    var storage: [media.descriptor_bytes]u8 = undefined;
    const kinds = [_]media.MediaKindV1{ .image, .audio, .video };
    for (kinds, 0..) |kind, index| {
        const encoded = try media.encodeMediaObjectV1(
            descriptor(kind),
            &storage,
        );
        roots[index] = try media.mediaObjectSha256V1(encoded);
    }

    const mapped = try media.mapSpanExactV1(
        .{
            .start = .{
                .ticks = 48_000,
                .base = .{ .numerator = 1, .denominator = 48_000 },
            },
            .end = .{
                .ticks = 96_000,
                .base = .{ .numerator = 1, .denominator = 48_000 },
            },
        },
        .{ .numerator = 1, .denominator = 16_000 },
    );
    if (mapped.start.ticks != 16_000 or mapped.end.ticks != 32_000)
        return error.UnexpectedMapping;
    const non_integral_rejected = if (media.convertExactV1(
        .{
            .ticks = 1,
            .base = .{ .numerator = 1, .denominator = 48_000 },
        },
        .{ .numerator = 1, .denominator = 44_100 },
    )) |_| false else |_| true;
    if (!non_integral_rejected) return error.NonIntegralMappingAccepted;

    var state = try media.initializePublicationStateV1(
        91,
        7,
        .{ .numerator = 1, .denominator = 16_000 },
        roots[1],
        [_]u8{0x72} ** 32,
    );
    const first = try media.preparePublicationV1(
        state,
        event(7, 0, 48_000, 0, 16_000, roots[1], state.timeline_sha256),
        [_]u8{0x74} ** 32,
        [_]u8{0x75} ** 32,
    );
    try media.commitPublicationV1(&state, first);
    const once = state;
    const stale_replay_rejected = if (media.commitPublicationV1(
        &state,
        first,
    )) |_| false else |_| true;
    if (!stale_replay_rejected or !std.meta.eql(once, state))
        return error.StalePublicationAccepted;

    const second = try media.preparePublicationV1(
        state,
        event(
            8,
            48_000,
            96_000,
            16_000,
            32_000,
            roots[1],
            state.timeline_sha256,
        ),
        [_]u8{0x76} ** 32,
        [_]u8{0x77} ** 32,
    );
    try media.commitPublicationV1(&state, second);
    if (state.visible_chunks != 2 or state.visible_units != 32_000)
        return error.UnexpectedPublicationState;

    const object_hex = std.fmt.bytesToHex(roots[1], .lower);
    const timeline_hex = std.fmt.bytesToHex(
        state.timeline_sha256,
        .lower,
    );
    const commit_hex = std.fmt.bytesToHex(
        state.previous_commit_sha256,
        .lower,
    );
    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.media-contract/demo-v1\"," ++
            "\"descriptor_bytes\":{d},\"media_objects\":3," ++
            "\"image\":true,\"audio\":true,\"video\":true," ++
            "\"source_rate\":48000,\"target_rate\":16000," ++
            "\"exact_time_mapping\":true," ++
            "\"non_integral_mapping_rejected\":true," ++
            "\"visible_chunks\":{d},\"visible_units\":{d}," ++
            "\"stale_replay_rejected\":true," ++
            "\"filesystem_authority\":false," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false,\"verified\":true," ++
            "\"audio_object_sha256\":\"{s}\"," ++
            "\"timeline_sha256\":\"{s}\"," ++
            "\"publication_sha256\":\"{s}\"}}\n",
        .{
            media.descriptor_bytes,
            state.visible_chunks,
            state.visible_units,
            &object_hex,
            &timeline_hex,
            &commit_hex,
        },
    );
    try stdout.flush();
}
