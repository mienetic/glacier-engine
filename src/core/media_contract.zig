//! Shared authority-free identity, timeline, and publication contracts for
//! image, audio, and video state.

const std = @import("std");

pub const Digest = [32]u8;
pub const descriptor_abi: u64 = 0x474d_4f42_0000_0001;
pub const timeline_event_abi: u64 = 0x474d_544c_0000_0001;
pub const publication_abi: u64 = 0x474d_5055_0000_0001;
pub const descriptor_magic = [_]u8{
    'G', 'M', 'O', 'B', 'J', '0', '1', 0,
};
pub const descriptor_bytes: usize = 272;
pub const descriptor_body_bytes: usize = descriptor_bytes - 32;
pub const allowed_flags: u64 = 0;

const descriptor_domain = "glacier-media-object-v1\x00";
const timeline_event_domain = "glacier-media-timeline-event-v1\x00";
const publication_state_domain = "glacier-media-publication-state-v1\x00";
const publication_domain = "glacier-media-publication-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidDescriptor,
    InvalidPublication,
    InvalidTimeline,
    NonIntegralMapping,
    StalePublication,
};

pub const MediaKindV1 = enum(u64) {
    image = 1,
    audio = 2,
    video = 3,
};

pub const TimelineEventKindV1 = enum(u64) {
    identity = 1,
    trim = 2,
    pad = 3,
    resample = 4,
    frame_select = 5,
    reorder = 6,
};

pub const MediaObjectV1 = struct {
    kind: MediaKindV1,
    semantic_abi: u64,
    byte_length: u64,
    container_id: u64,
    codec_id: u64,
    axes: [3]u64,
    time_base: TimeBaseV1,
    tenant_scope_sha256: Digest,
    content_sha256: Digest,
    metadata_policy_sha256: Digest,
    provenance_sha256: Digest,
};

pub const TimeBaseV1 = struct {
    numerator: u64,
    denominator: u64,
};

pub const PositionV1 = struct {
    ticks: u64,
    base: TimeBaseV1,
};

pub const SpanV1 = struct {
    start: PositionV1,
    end: PositionV1,
};

pub const TimelineEventV1 = struct {
    kind: TimelineEventKindV1,
    sequence: u64,
    media_object_sha256: Digest,
    source: SpanV1,
    target: SpanV1,
    plan_sha256: Digest,
    previous_event_sha256: Digest,
};

pub const PublicationStateV1 = struct {
    request_epoch: u64,
    next_sequence: u64,
    visible_chunks: u64,
    visible_units: u64,
    timeline_base: TimeBaseV1,
    media_object_sha256: Digest,
    timeline_sha256: Digest,
    previous_commit_sha256: Digest,
};

pub const PreparedPublicationV1 = struct {
    abi_version: u64 = publication_abi,
    state_before_sha256: Digest,
    request_epoch: u64,
    sequence: u64,
    chunk_ordinal: u64,
    units_before: u64,
    units_after: u64,
    media_object_sha256: Digest,
    timeline_event_sha256: Digest,
    output_sha256: Digest,
    resource_claim_sha256: Digest,
    previous_commit_sha256: Digest,
    commit_sha256: Digest,
};

pub fn encodeMediaObjectV1(
    object: MediaObjectV1,
    destination: []u8,
) Error![]const u8 {
    try validateMediaObjectV1(object);
    if (destination.len < descriptor_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..descriptor_bytes];
    @memset(output, 0);
    @memcpy(output[0..8], &descriptor_magic);
    writeU64(output, 8, descriptor_abi);
    writeU64(output, 16, descriptor_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(object.kind));
    writeU64(output, 40, object.semantic_abi);
    writeU64(output, 48, object.byte_length);
    writeU64(output, 56, object.container_id);
    writeU64(output, 64, object.codec_id);
    for (object.axes, 0..) |axis, index|
        writeU64(output, 72 + index * 8, axis);
    writeU64(output, 96, object.time_base.numerator);
    writeU64(output, 104, object.time_base.denominator);
    @memcpy(output[112..144], &object.tenant_scope_sha256);
    @memcpy(output[144..176], &object.content_sha256);
    @memcpy(output[176..208], &object.metadata_policy_sha256);
    @memcpy(output[208..240], &object.provenance_sha256);
    const root = mediaObjectRootV1(output[0..descriptor_body_bytes]);
    @memcpy(output[descriptor_body_bytes..], &root);
    return output;
}

pub fn decodeMediaObjectV1(
    encoded: []const u8,
) Error!MediaObjectV1 {
    if (encoded.len != descriptor_bytes or
        !std.mem.eql(u8, encoded[0..8], &descriptor_magic) or
        readU64(encoded, 8) != descriptor_abi or
        readU64(encoded, 16) != descriptor_bytes or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidDescriptor;
    var footer: Digest = undefined;
    @memcpy(&footer, encoded[descriptor_body_bytes..]);
    if (!std.mem.eql(
        u8,
        &footer,
        &mediaObjectRootV1(encoded[0..descriptor_body_bytes]),
    )) return Error.InvalidDescriptor;
    const kind = std.meta.intToEnum(
        MediaKindV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidDescriptor;
    var object: MediaObjectV1 = .{
        .kind = kind,
        .semantic_abi = readU64(encoded, 40),
        .byte_length = readU64(encoded, 48),
        .container_id = readU64(encoded, 56),
        .codec_id = readU64(encoded, 64),
        .axes = .{
            readU64(encoded, 72),
            readU64(encoded, 80),
            readU64(encoded, 88),
        },
        .time_base = .{
            .numerator = readU64(encoded, 96),
            .denominator = readU64(encoded, 104),
        },
        .tenant_scope_sha256 = undefined,
        .content_sha256 = undefined,
        .metadata_policy_sha256 = undefined,
        .provenance_sha256 = undefined,
    };
    @memcpy(&object.tenant_scope_sha256, encoded[112..144]);
    @memcpy(&object.content_sha256, encoded[144..176]);
    @memcpy(&object.metadata_policy_sha256, encoded[176..208]);
    @memcpy(&object.provenance_sha256, encoded[208..240]);
    try validateMediaObjectV1(object);
    return object;
}

pub fn mediaObjectSha256V1(encoded: []const u8) Error!Digest {
    _ = try decodeMediaObjectV1(encoded);
    var root: Digest = undefined;
    @memcpy(&root, encoded[descriptor_body_bytes..]);
    return root;
}

pub fn validateTimeBaseV1(base: TimeBaseV1) Error!void {
    if (base.numerator == 0 or base.denominator == 0 or
        std.math.gcd(base.numerator, base.denominator) != 1)
        return Error.InvalidTimeline;
}

pub fn validateSpanV1(span: SpanV1) Error!void {
    try validateTimeBaseV1(span.start.base);
    try validateTimeBaseV1(span.end.base);
    if (!std.meta.eql(span.start.base, span.end.base) or
        span.start.ticks >= span.end.ticks)
        return Error.InvalidTimeline;
}

pub fn convertExactV1(
    position: PositionV1,
    target_base: TimeBaseV1,
) Error!PositionV1 {
    try validateTimeBaseV1(position.base);
    try validateTimeBaseV1(target_base);
    var numerator = std.math.mul(
        u128,
        position.ticks,
        position.base.numerator,
    ) catch return Error.ArithmeticOverflow;
    numerator = std.math.mul(
        u128,
        numerator,
        target_base.denominator,
    ) catch return Error.ArithmeticOverflow;
    const denominator = std.math.mul(
        u128,
        position.base.denominator,
        target_base.numerator,
    ) catch return Error.ArithmeticOverflow;
    if (numerator % denominator != 0)
        return Error.NonIntegralMapping;
    const ticks = std.math.cast(
        u64,
        numerator / denominator,
    ) orelse return Error.ArithmeticOverflow;
    return .{ .ticks = ticks, .base = target_base };
}

pub fn mapSpanExactV1(
    span: SpanV1,
    target_base: TimeBaseV1,
) Error!SpanV1 {
    try validateSpanV1(span);
    const mapped: SpanV1 = .{
        .start = try convertExactV1(span.start, target_base),
        .end = try convertExactV1(span.end, target_base),
    };
    try validateSpanV1(mapped);
    return mapped;
}

pub fn timelineEventRootV1(
    event: TimelineEventV1,
) Error!Digest {
    try validateTimelineEventV1(event);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(timeline_event_domain);
    hashU64(&hash, timeline_event_abi);
    hashU64(&hash, @intFromEnum(event.kind));
    hashU64(&hash, event.sequence);
    hash.update(&event.media_object_sha256);
    hashSpan(&hash, event.source);
    hashSpan(&hash, event.target);
    hash.update(&event.plan_sha256);
    hash.update(&event.previous_event_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn initializePublicationStateV1(
    request_epoch: u64,
    first_sequence: u64,
    timeline_base: TimeBaseV1,
    media_object_sha256: Digest,
    previous_commit_sha256: Digest,
) Error!PublicationStateV1 {
    try validateTimeBaseV1(timeline_base);
    if (request_epoch == 0 or first_sequence == 0 or
        isZero(media_object_sha256) or
        isZero(previous_commit_sha256))
        return Error.InvalidPublication;
    return .{
        .request_epoch = request_epoch,
        .next_sequence = first_sequence,
        .visible_chunks = 0,
        .visible_units = 0,
        .timeline_base = timeline_base,
        .media_object_sha256 = media_object_sha256,
        .timeline_sha256 = [_]u8{0} ** 32,
        .previous_commit_sha256 = previous_commit_sha256,
    };
}

pub fn preparePublicationV1(
    state: PublicationStateV1,
    event: TimelineEventV1,
    output_sha256: Digest,
    resource_claim_sha256: Digest,
) Error!PreparedPublicationV1 {
    try validatePublicationStateV1(state);
    try validateTimelineEventV1(event);
    const event_root = try timelineEventRootV1(event);
    if (event.sequence != state.next_sequence or
        !std.mem.eql(
            u8,
            &event.media_object_sha256,
            &state.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &event.previous_event_sha256,
            &state.timeline_sha256,
        ) or
        !std.meta.eql(event.target.start.base, state.timeline_base) or
        !std.meta.eql(event.target.end.base, state.timeline_base) or
        event.target.start.ticks != state.visible_units or
        isZero(output_sha256) or
        isZero(resource_claim_sha256))
        return Error.InvalidPublication;
    if (state.next_sequence == std.math.maxInt(u64) or
        state.visible_chunks == std.math.maxInt(u64))
        return Error.ArithmeticOverflow;
    var prepared: PreparedPublicationV1 = .{
        .state_before_sha256 = publicationStateRootV1(state),
        .request_epoch = state.request_epoch,
        .sequence = state.next_sequence,
        .chunk_ordinal = state.visible_chunks,
        .units_before = state.visible_units,
        .units_after = event.target.end.ticks,
        .media_object_sha256 = state.media_object_sha256,
        .timeline_event_sha256 = event_root,
        .output_sha256 = output_sha256,
        .resource_claim_sha256 = resource_claim_sha256,
        .previous_commit_sha256 = state.previous_commit_sha256,
        .commit_sha256 = undefined,
    };
    prepared.commit_sha256 = publicationRootV1(prepared);
    return prepared;
}

pub fn commitPublicationV1(
    state: *PublicationStateV1,
    prepared: PreparedPublicationV1,
) Error!void {
    try validatePublicationStateV1(state.*);
    if (prepared.abi_version != publication_abi or
        prepared.request_epoch != state.request_epoch or
        prepared.sequence != state.next_sequence or
        prepared.chunk_ordinal != state.visible_chunks or
        prepared.units_before != state.visible_units or
        prepared.units_after <= prepared.units_before or
        state.next_sequence == std.math.maxInt(u64) or
        state.visible_chunks == std.math.maxInt(u64) or
        !std.mem.eql(
            u8,
            &prepared.state_before_sha256,
            &publicationStateRootV1(state.*),
        ) or
        !std.mem.eql(
            u8,
            &prepared.media_object_sha256,
            &state.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &prepared.previous_commit_sha256,
            &state.previous_commit_sha256,
        ) or
        !std.mem.eql(
            u8,
            &prepared.commit_sha256,
            &publicationRootV1(prepared),
        ))
        return Error.StalePublication;

    // The bounded mutation suffix is infallible after complete validation.
    state.next_sequence += 1;
    state.visible_chunks += 1;
    state.visible_units = prepared.units_after;
    state.timeline_sha256 = prepared.timeline_event_sha256;
    state.previous_commit_sha256 = prepared.commit_sha256;
}

pub fn mediaObjectRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(descriptor_domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn publicationStateRootV1(state: PublicationStateV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(publication_state_domain);
    hashU64(&hash, state.request_epoch);
    hashU64(&hash, state.next_sequence);
    hashU64(&hash, state.visible_chunks);
    hashU64(&hash, state.visible_units);
    hashTimeBase(&hash, state.timeline_base);
    hash.update(&state.media_object_sha256);
    hash.update(&state.timeline_sha256);
    hash.update(&state.previous_commit_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn publicationRootV1(
    prepared: PreparedPublicationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(publication_domain);
    hashU64(&hash, publication_abi);
    hash.update(&prepared.state_before_sha256);
    hashU64(&hash, prepared.request_epoch);
    hashU64(&hash, prepared.sequence);
    hashU64(&hash, prepared.chunk_ordinal);
    hashU64(&hash, prepared.units_before);
    hashU64(&hash, prepared.units_after);
    hash.update(&prepared.media_object_sha256);
    hash.update(&prepared.timeline_event_sha256);
    hash.update(&prepared.output_sha256);
    hash.update(&prepared.resource_claim_sha256);
    hash.update(&prepared.previous_commit_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn validateMediaObjectV1(object: MediaObjectV1) Error!void {
    if (object.semantic_abi == 0 or object.byte_length == 0 or
        object.container_id == 0 or object.codec_id == 0 or
        isZero(object.tenant_scope_sha256) or
        isZero(object.content_sha256) or
        isZero(object.metadata_policy_sha256) or
        isZero(object.provenance_sha256))
        return Error.InvalidDescriptor;
    switch (object.kind) {
        .image => {
            if (object.axes[0] == 0 or object.axes[1] == 0 or
                object.axes[2] == 0 or object.axes[2] > 4 or
                object.time_base.numerator != 0 or
                object.time_base.denominator != 1)
                return Error.InvalidDescriptor;
        },
        .audio => {
            if (object.axes[0] == 0 or object.axes[1] == 0 or
                object.axes[1] > 64 or object.axes[2] == 0 or
                object.axes[2] > 768_000 or
                object.time_base.numerator != 1 or
                object.time_base.denominator != object.axes[2])
                return Error.InvalidDescriptor;
        },
        .video => {
            if (object.axes[0] == 0 or object.axes[1] == 0 or
                object.axes[2] == 0)
                return Error.InvalidDescriptor;
            validateTimeBaseV1(object.time_base) catch
                return Error.InvalidDescriptor;
        },
    }
}

fn validateTimelineEventV1(event: TimelineEventV1) Error!void {
    if (event.sequence == 0 or
        isZero(event.media_object_sha256) or
        isZero(event.plan_sha256))
        return Error.InvalidTimeline;
    try validateSpanV1(event.source);
    try validateSpanV1(event.target);
    switch (event.kind) {
        .identity => {
            if (!std.meta.eql(event.source, event.target))
                return Error.InvalidTimeline;
        },
        .trim, .frame_select => {
            if (event.target.end.ticks - event.target.start.ticks >
                event.source.end.ticks - event.source.start.ticks)
                return Error.InvalidTimeline;
        },
        .pad, .resample, .reorder => {},
    }
}

fn validatePublicationStateV1(state: PublicationStateV1) Error!void {
    try validateTimeBaseV1(state.timeline_base);
    if (state.request_epoch == 0 or state.next_sequence == 0 or
        isZero(state.media_object_sha256) or
        isZero(state.previous_commit_sha256) or
        (state.visible_chunks == 0 and
            (state.visible_units != 0 or
                !isZero(state.timeline_sha256))) or
        (state.visible_chunks > 0 and
            (state.visible_units == 0 or
                isZero(state.timeline_sha256))))
        return Error.InvalidPublication;
}

fn hashSpan(
    hash: *std.crypto.hash.sha2.Sha256,
    span: SpanV1,
) void {
    hashU64(hash, span.start.ticks);
    hashTimeBase(hash, span.start.base);
    hashU64(hash, span.end.ticks);
    hashTimeBase(hash, span.end.base);
}

fn hashTimeBase(
    hash: *std.crypto.hash.sha2.Sha256,
    base: TimeBaseV1,
) void {
    hashU64(hash, base.numerator);
    hashU64(hash, base.denominator);
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    @memcpy(output[offset .. offset + 8], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset .. offset + 8][0..8], .little);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

test "media descriptors cover image audio and video with fixed identity" {
    const fixtures = [_]MediaObjectV1{
        .{
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
        .{
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
        .{
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
    var storage: [descriptor_bytes]u8 = undefined;
    for (fixtures) |fixture| {
        const encoded = try encodeMediaObjectV1(fixture, &storage);
        try std.testing.expectEqualDeep(
            fixture,
            try decodeMediaObjectV1(encoded),
        );
    }
}

test "media object wire rejects every mutation and rehashed contradiction" {
    const object: MediaObjectV1 = .{
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
    };
    var storage: [descriptor_bytes]u8 = undefined;
    const encoded = try encodeMediaObjectV1(object, &storage);
    var expected: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected,
        "255d59c3ad202eececf7c206583ad3ef62cda5f3710966aa0f7cf3c4079285f5",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected,
        encoded[descriptor_body_bytes..],
    );
    var corrupted: [descriptor_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodeMediaObjectV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    @memcpy(&corrupted, encoded);
    writeU64(&corrupted, 24, 1);
    const rerooted = mediaObjectRootV1(
        corrupted[0..descriptor_body_bytes],
    );
    @memcpy(corrupted[descriptor_body_bytes..], &rerooted);
    try std.testing.expectError(
        Error.InvalidDescriptor,
        decodeMediaObjectV1(&corrupted),
    );
}

test "rational timeline mapping is exact or rejects" {
    const source: SpanV1 = .{
        .start = .{
            .ticks = 48_000,
            .base = .{ .numerator = 1, .denominator = 48_000 },
        },
        .end = .{
            .ticks = 96_000,
            .base = .{ .numerator = 1, .denominator = 48_000 },
        },
    };
    const mapped = try mapSpanExactV1(
        source,
        .{ .numerator = 1, .denominator = 16_000 },
    );
    try std.testing.expectEqual(@as(u64, 16_000), mapped.start.ticks);
    try std.testing.expectEqual(@as(u64, 32_000), mapped.end.ticks);
    try std.testing.expectError(
        Error.NonIntegralMapping,
        convertExactV1(
            .{
                .ticks = 1,
                .base = .{ .numerator = 1, .denominator = 48_000 },
            },
            .{ .numerator = 1, .denominator = 44_100 },
        ),
    );
}

test "media publication appends once and rejects stale replay" {
    const object_sha256 = [_]u8{0x71} ** 32;
    var state = try initializePublicationStateV1(
        91,
        7,
        .{ .numerator = 1, .denominator = 16_000 },
        object_sha256,
        [_]u8{0x72} ** 32,
    );
    const event: TimelineEventV1 = .{
        .kind = .resample,
        .sequence = 7,
        .media_object_sha256 = object_sha256,
        .source = .{
            .start = .{
                .ticks = 0,
                .base = .{ .numerator = 1, .denominator = 48_000 },
            },
            .end = .{
                .ticks = 48_000,
                .base = .{ .numerator = 1, .denominator = 48_000 },
            },
        },
        .target = .{
            .start = .{
                .ticks = 0,
                .base = .{ .numerator = 1, .denominator = 16_000 },
            },
            .end = .{
                .ticks = 16_000,
                .base = .{ .numerator = 1, .denominator = 16_000 },
            },
        },
        .plan_sha256 = [_]u8{0x73} ** 32,
        .previous_event_sha256 = [_]u8{0} ** 32,
    };
    const prepared = try preparePublicationV1(
        state,
        event,
        [_]u8{0x74} ** 32,
        [_]u8{0x75} ** 32,
    );
    var expected_commit: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_commit,
        "d26ae55bd2f88036e829c725d91c448bf5efafad20710f7bc84334e611157fb6",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_commit,
        &prepared.commit_sha256,
    );
    try commitPublicationV1(&state, prepared);
    try std.testing.expectEqual(@as(u64, 8), state.next_sequence);
    try std.testing.expectEqual(@as(u64, 1), state.visible_chunks);
    try std.testing.expectEqual(@as(u64, 16_000), state.visible_units);
    const committed = state;
    try std.testing.expectError(
        Error.StalePublication,
        commitPublicationV1(&state, prepared),
    );
    try std.testing.expectEqualDeep(committed, state);

    var exhausted = try initializePublicationStateV1(
        91,
        std.math.maxInt(u64),
        .{ .numerator = 1, .denominator = 16_000 },
        object_sha256,
        [_]u8{0x72} ** 32,
    );
    var forged = prepared;
    forged.sequence = exhausted.next_sequence;
    forged.state_before_sha256 = publicationStateRootV1(exhausted);
    forged.commit_sha256 = publicationRootV1(forged);
    try std.testing.expectError(
        Error.StalePublication,
        commitPublicationV1(&exhausted, forged),
    );
}
