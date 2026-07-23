//! Bounded, redistributable image/audio/video fixtures and identity decoder.

const std = @import("std");
const media = @import("media_contract.zig");
const decode_plan = @import("media_decode_plan.zig");

pub const Digest = media.Digest;
pub const fixture_abi: u64 = 0x474d_5446_0000_0001;
pub const decoder_abi: u64 = 0x474d_5444_0000_0001;
pub const fixture_magic = [_]u8{
    'G', 'M', 'T', 'I', 'N', 'Y', '1', 0,
};
pub const fixture_header_bytes: usize = 320;
pub const fixture_footer_bytes: usize = 32;
pub const maximum_payload_bytes: usize = 4096;
pub const maximum_fixture_bytes: usize =
    fixture_header_bytes + maximum_payload_bytes + fixture_footer_bytes;
pub const allowed_flags: u64 = 0;
pub const container_id: u64 = fixture_abi;

const fixture_domain = "glacier-tiny-media-fixture-v1\x00";
const decoder_domain = "glacier-tiny-media-decoder-v1\x00";
const transform_domain = "glacier-tiny-media-identity-transform-v1\x00";
const receipt_domain = "glacier-tiny-media-decode-receipt-v1\x00";
const mapping_domain = "glacier-tiny-media-unit-mapping-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidFixture,
    InvalidPlan,
    UnitOutOfRange,
    UnsafeDestination,
};

pub const RepresentationV1 = enum(u64) {
    image_rgb8 = 1,
    image_gray8 = 2,
    audio_pcm_s16le = 3,
    video_gray8_intra = 4,
};

pub const LayoutV1 = enum(u64) {
    image_rgb = 1,
    image_gray = 2,
    audio_interleaved = 3,
    video_gray = 4,
};

pub const OrientationV1 = enum(u64) {
    not_applicable = 0,
    top_left = 1,
};

pub const TransferV1 = enum(u64) {
    not_applicable = 0,
    srgb = 1,
    linear = 2,
};

pub const AlphaV1 = enum(u64) {
    not_applicable = 0,
    not_present = 1,
};

pub const FixtureSpecV1 = struct {
    kind: media.MediaKindV1,
    semantic_abi: u64,
    codec_id: u64,
    axes: [3]u64,
    target_axes: [3]u64,
    time_base: media.TimeBaseV1,
    storage_stride: u64,
    representation: RepresentationV1,
    layout: LayoutV1,
    orientation: OrientationV1,
    transfer: TransferV1,
    alpha: AlphaV1,
    start_ticks: u64,
    keyframe_bits: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    provenance_sha256: Digest,
    payload: []const u8,
};

pub const ParsedFixtureV1 = struct {
    kind: media.MediaKindV1,
    semantic_abi: u64,
    codec_id: u64,
    axes: [3]u64,
    target_axes: [3]u64,
    time_base: media.TimeBaseV1,
    storage_stride: u64,
    representation: RepresentationV1,
    layout: LayoutV1,
    orientation: OrientationV1,
    transfer: TransferV1,
    alpha: AlphaV1,
    start_ticks: u64,
    keyframe_bits: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    provenance_sha256: Digest,
    payload: []const u8,
    media_object: media.MediaObjectV1,
    media_object_sha256: Digest,
    fixture_sha256: Digest,
};

pub const DecodeReceiptV1 = struct {
    kind: media.MediaKindV1,
    logical_units: u64,
    source_payload_offset: u64,
    source_payload_bytes: u64,
    output_bytes: u64,
    media_object_sha256: Digest,
    decode_plan_sha256: Digest,
    fixture_sha256: Digest,
    output_sha256: Digest,
    mapping_sha256: Digest,
    receipt_sha256: Digest,
};

pub const UnitMappingV1 = struct {
    kind: media.MediaKindV1,
    unit_index: u64,
    source_offset: u64,
    source_bytes: u64,
    output_offset: u64,
    output_bytes: u64,
    has_timeline: bool,
    timeline_tick: u64,
    mapping_sha256: Digest,
};

pub const image_payload = [_]u8{
    255, 0, 0,   0,   255, 0,
    0,   0, 255, 255, 255, 255,
};

pub const audio_payload = [_]u8{
    0x00, 0x80, 0xff, 0x7f,
    0x00, 0xc0, 0x00, 0x40,
    0xff, 0xff, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0xff, 0xff,
    0x00, 0x40, 0x00, 0xc0,
    0xff, 0x7f, 0x00, 0x80,
    0xd2, 0x04, 0x2e, 0xfb,
};

pub const video_payload = [_]u8{
    0,   64,  128, 255,
    255, 128, 64,  0,
};

pub fn imageSpecV1() FixtureSpecV1 {
    return .{
        .kind = .image,
        .semantic_abi = 1,
        .codec_id = 1,
        .axes = .{ 2, 2, 3 },
        .target_axes = .{ 2, 2, 3 },
        .time_base = .{ .numerator = 0, .denominator = 1 },
        .storage_stride = 6,
        .representation = .image_rgb8,
        .layout = .image_rgb,
        .orientation = .top_left,
        .transfer = .srgb,
        .alpha = .not_present,
        .start_ticks = 0,
        .keyframe_bits = 0,
        .tenant_scope_sha256 = [_]u8{0xa1} ** 32,
        .metadata_policy_sha256 = [_]u8{0xb1} ** 32,
        .provenance_sha256 = [_]u8{0xc1} ** 32,
        .payload = &image_payload,
    };
}

pub fn audioSpecV1() FixtureSpecV1 {
    return .{
        .kind = .audio,
        .semantic_abi = 1,
        .codec_id = 2,
        .axes = .{ 8, 2, 48_000 },
        .target_axes = .{ 8, 2, 48_000 },
        .time_base = .{ .numerator = 1, .denominator = 48_000 },
        .storage_stride = 4,
        .representation = .audio_pcm_s16le,
        .layout = .audio_interleaved,
        .orientation = .not_applicable,
        .transfer = .not_applicable,
        .alpha = .not_applicable,
        .start_ticks = 0,
        .keyframe_bits = 0,
        .tenant_scope_sha256 = [_]u8{0xa2} ** 32,
        .metadata_policy_sha256 = [_]u8{0xb2} ** 32,
        .provenance_sha256 = [_]u8{0xc2} ** 32,
        .payload = &audio_payload,
    };
}

pub fn videoSpecV1() FixtureSpecV1 {
    return .{
        .kind = .video,
        .semantic_abi = 1,
        .codec_id = 3,
        .axes = .{ 2, 2, 2 },
        .target_axes = .{ 2, 2, 2 },
        .time_base = .{ .numerator = 1, .denominator = 30 },
        .storage_stride = 4,
        .representation = .video_gray8_intra,
        .layout = .video_gray,
        .orientation = .top_left,
        .transfer = .linear,
        .alpha = .not_present,
        .start_ticks = 0,
        .keyframe_bits = 0b11,
        .tenant_scope_sha256 = [_]u8{0xa3} ** 32,
        .metadata_policy_sha256 = [_]u8{0xb3} ** 32,
        .provenance_sha256 = [_]u8{0xc3} ** 32,
        .payload = &video_payload,
    };
}

pub fn encodeFixtureV1(
    spec: FixtureSpecV1,
    destination: []u8,
) Error![]const u8 {
    try validateSpecV1(spec);
    const total = std.math.add(
        usize,
        fixture_header_bytes,
        spec.payload.len,
    ) catch return Error.ArithmeticOverflow;
    const encoded_bytes = std.math.add(
        usize,
        total,
        fixture_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
    if (destination.len < encoded_bytes) return Error.BufferTooSmall;
    const output = destination[0..encoded_bytes];
    if (slicesOverlap(output, spec.payload))
        return Error.UnsafeDestination;
    @memset(output, 0);
    @memcpy(output[0..8], &fixture_magic);
    writeU64(output, 8, fixture_abi);
    writeU64(output, 16, encoded_bytes);
    writeU64(output, 24, fixture_header_bytes);
    writeU64(output, 32, allowed_flags);
    writeU64(output, 40, @intFromEnum(spec.kind));
    writeU64(output, 48, spec.semantic_abi);
    writeU64(output, 56, container_id);
    writeU64(output, 64, spec.codec_id);
    for (spec.axes, 0..) |axis, index|
        writeU64(output, 72 + index * 8, axis);
    writeU64(output, 96, spec.time_base.numerator);
    writeU64(output, 104, spec.time_base.denominator);
    writeU64(output, 112, fixture_header_bytes);
    writeU64(output, 120, spec.payload.len);
    writeU64(output, 128, spec.storage_stride);
    writeU64(output, 136, @intFromEnum(spec.representation));
    writeU64(output, 144, @intFromEnum(spec.layout));
    writeU64(output, 152, @intFromEnum(spec.orientation));
    writeU64(output, 160, @intFromEnum(spec.transfer));
    writeU64(output, 168, @intFromEnum(spec.alpha));
    writeU64(output, 176, spec.start_ticks);
    writeU64(output, 184, spec.keyframe_bits);
    @memcpy(output[192..224], &spec.tenant_scope_sha256);
    @memcpy(output[224..256], &spec.metadata_policy_sha256);
    @memcpy(output[256..288], &spec.provenance_sha256);
    for (spec.target_axes, 0..) |axis, index|
        writeU64(output, 288 + index * 8, axis);
    @memcpy(
        output[fixture_header_bytes .. fixture_header_bytes + spec.payload.len],
        spec.payload,
    );
    const root = fixtureRootV1(
        output[0 .. encoded_bytes - fixture_footer_bytes],
    );
    @memcpy(output[encoded_bytes - fixture_footer_bytes ..], &root);
    return output;
}

pub fn parseFixtureV1(
    encoded: []const u8,
) Error!ParsedFixtureV1 {
    if (encoded.len < fixture_header_bytes + fixture_footer_bytes or
        encoded.len > maximum_fixture_bytes or
        !std.mem.eql(u8, encoded[0..8], &fixture_magic) or
        readU64(encoded, 8) != fixture_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != fixture_header_bytes or
        readU64(encoded, 32) != allowed_flags or
        readU64(encoded, 56) != container_id or
        readU64(encoded, 112) != fixture_header_bytes or
        readU64(encoded, 312) != 0)
        return Error.InvalidFixture;
    const payload_bytes = std.math.cast(
        usize,
        readU64(encoded, 120),
    ) orelse return Error.InvalidFixture;
    const expected_total = std.math.add(
        usize,
        fixture_header_bytes,
        payload_bytes,
    ) catch return Error.InvalidFixture;
    const complete_total = std.math.add(
        usize,
        expected_total,
        fixture_footer_bytes,
    ) catch return Error.InvalidFixture;
    if (payload_bytes == 0 or
        payload_bytes > maximum_payload_bytes or
        complete_total != encoded.len)
        return Error.InvalidFixture;
    var footer: Digest = undefined;
    @memcpy(&footer, encoded[encoded.len - fixture_footer_bytes ..]);
    if (!std.mem.eql(
        u8,
        &footer,
        &fixtureRootV1(encoded[0 .. encoded.len - fixture_footer_bytes]),
    )) return Error.InvalidFixture;

    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(encoded, 40),
    ) catch return Error.InvalidFixture;
    const representation = std.meta.intToEnum(
        RepresentationV1,
        readU64(encoded, 136),
    ) catch return Error.InvalidFixture;
    const layout = std.meta.intToEnum(
        LayoutV1,
        readU64(encoded, 144),
    ) catch return Error.InvalidFixture;
    const orientation = std.meta.intToEnum(
        OrientationV1,
        readU64(encoded, 152),
    ) catch return Error.InvalidFixture;
    const transfer = std.meta.intToEnum(
        TransferV1,
        readU64(encoded, 160),
    ) catch return Error.InvalidFixture;
    const alpha = std.meta.intToEnum(
        AlphaV1,
        readU64(encoded, 168),
    ) catch return Error.InvalidFixture;
    var tenant_scope_sha256: Digest = undefined;
    var metadata_policy_sha256: Digest = undefined;
    var provenance_sha256: Digest = undefined;
    @memcpy(&tenant_scope_sha256, encoded[192..224]);
    @memcpy(&metadata_policy_sha256, encoded[224..256]);
    @memcpy(&provenance_sha256, encoded[256..288]);
    const payload = encoded[fixture_header_bytes .. fixture_header_bytes + payload_bytes];
    const spec: FixtureSpecV1 = .{
        .kind = kind,
        .semantic_abi = readU64(encoded, 48),
        .codec_id = readU64(encoded, 64),
        .axes = .{
            readU64(encoded, 72),
            readU64(encoded, 80),
            readU64(encoded, 88),
        },
        .target_axes = .{
            readU64(encoded, 288),
            readU64(encoded, 296),
            readU64(encoded, 304),
        },
        .time_base = .{
            .numerator = readU64(encoded, 96),
            .denominator = readU64(encoded, 104),
        },
        .storage_stride = readU64(encoded, 128),
        .representation = representation,
        .layout = layout,
        .orientation = orientation,
        .transfer = transfer,
        .alpha = alpha,
        .start_ticks = readU64(encoded, 176),
        .keyframe_bits = readU64(encoded, 184),
        .tenant_scope_sha256 = tenant_scope_sha256,
        .metadata_policy_sha256 = metadata_policy_sha256,
        .provenance_sha256 = provenance_sha256,
        .payload = payload,
    };
    try validateSpecV1(spec);

    var content_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &content_sha256, .{});
    const object: media.MediaObjectV1 = .{
        .kind = spec.kind,
        .semantic_abi = spec.semantic_abi,
        .byte_length = payload.len,
        .container_id = container_id,
        .codec_id = spec.codec_id,
        .axes = spec.axes,
        .time_base = spec.time_base,
        .tenant_scope_sha256 = spec.tenant_scope_sha256,
        .content_sha256 = content_sha256,
        .metadata_policy_sha256 = spec.metadata_policy_sha256,
        .provenance_sha256 = spec.provenance_sha256,
    };
    var object_storage: [media.descriptor_bytes]u8 = undefined;
    const encoded_object = media.encodeMediaObjectV1(
        object,
        &object_storage,
    ) catch return Error.InvalidFixture;
    const object_sha256 = media.mediaObjectSha256V1(
        encoded_object,
    ) catch return Error.InvalidFixture;
    return .{
        .kind = spec.kind,
        .semantic_abi = spec.semantic_abi,
        .codec_id = spec.codec_id,
        .axes = spec.axes,
        .target_axes = spec.target_axes,
        .time_base = spec.time_base,
        .storage_stride = spec.storage_stride,
        .representation = spec.representation,
        .layout = spec.layout,
        .orientation = spec.orientation,
        .transfer = spec.transfer,
        .alpha = spec.alpha,
        .start_ticks = spec.start_ticks,
        .keyframe_bits = spec.keyframe_bits,
        .tenant_scope_sha256 = spec.tenant_scope_sha256,
        .metadata_policy_sha256 = spec.metadata_policy_sha256,
        .provenance_sha256 = spec.provenance_sha256,
        .payload = payload,
        .media_object = object,
        .media_object_sha256 = object_sha256,
        .fixture_sha256 = footer,
    };
}

pub fn makeDecodePlanV1(
    fixture: ParsedFixtureV1,
    resource_policy_sha256: Digest,
    challenge_sha256: Digest,
) Error!decode_plan.DecodePlanV1 {
    const logical_units = try logicalUnitsV1(fixture);
    return .{
        .kind = fixture.kind,
        .decoder_abi = decoder_abi,
        .source_container_id = container_id,
        .source_codec_id = fixture.codec_id,
        .destination_representation_id = @intFromEnum(
            fixture.representation,
        ),
        .execution_mode = .deterministic,
        .numerical_policy = .exact_integer,
        .rejection_policy = .fail_closed,
        .required_capabilities = 0,
        .source_bytes = fixture.payload.len,
        .output_bytes = fixture.payload.len,
        .scratch_bytes = 0,
        .logical_units = logical_units,
        .source_axes = fixture.axes,
        .target_axes = fixture.target_axes,
        .source_time_base = fixture.time_base,
        .target_time_base = fixture.time_base,
        .media_object_sha256 = fixture.media_object_sha256,
        .decoder_implementation_sha256 = decoderImplementationSha256V1(),
        .transform_policy_sha256 = identityTransformSha256V1(
            fixture.kind,
            fixture.representation,
        ),
        .resource_policy_sha256 = resource_policy_sha256,
        .challenge_sha256 = challenge_sha256,
    };
}

pub fn decodeFixtureV1(
    encoded_fixture: []const u8,
    encoded_plan: []const u8,
    destination: []u8,
) Error!DecodeReceiptV1 {
    const fixture = try parseFixtureV1(encoded_fixture);
    const plan = decode_plan.decodePlanV1(
        encoded_plan,
    ) catch return Error.InvalidPlan;
    decode_plan.validateForMediaObjectV1(
        plan,
        fixture.media_object,
        fixture.media_object_sha256,
    ) catch return Error.InvalidPlan;
    const logical_units = try logicalUnitsV1(fixture);
    if (plan.decoder_abi != decoder_abi or
        plan.destination_representation_id !=
            @intFromEnum(fixture.representation) or
        plan.execution_mode != .deterministic or
        plan.numerical_policy != .exact_integer or
        plan.rejection_policy != .fail_closed or
        plan.required_capabilities != 0 or
        plan.output_bytes != fixture.payload.len or
        plan.scratch_bytes != 0 or
        plan.logical_units != logical_units or
        !std.meta.eql(plan.target_axes, fixture.target_axes) or
        !std.meta.eql(plan.target_time_base, fixture.time_base) or
        !std.mem.eql(
            u8,
            &plan.decoder_implementation_sha256,
            &decoderImplementationSha256V1(),
        ) or
        !std.mem.eql(
            u8,
            &plan.transform_policy_sha256,
            &identityTransformSha256V1(
                fixture.kind,
                fixture.representation,
            ),
        ))
        return Error.InvalidPlan;
    const output_bytes = std.math.cast(
        usize,
        plan.output_bytes,
    ) orelse return Error.InvalidPlan;
    if (destination.len < output_bytes) return Error.BufferTooSmall;
    const output = destination[0..output_bytes];
    if (slicesOverlap(output, encoded_fixture) or
        slicesOverlap(output, encoded_plan))
        return Error.UnsafeDestination;

    @memcpy(output, fixture.payload);
    var output_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        output,
        &output_sha256,
        .{},
    );
    const plan_sha256 = decode_plan.planSha256V1(
        encoded_plan,
    ) catch return Error.InvalidPlan;
    var receipt: DecodeReceiptV1 = .{
        .kind = fixture.kind,
        .logical_units = logical_units,
        .source_payload_offset = fixture_header_bytes,
        .source_payload_bytes = fixture.payload.len,
        .output_bytes = output_bytes,
        .media_object_sha256 = fixture.media_object_sha256,
        .decode_plan_sha256 = plan_sha256,
        .fixture_sha256 = fixture.fixture_sha256,
        .output_sha256 = output_sha256,
        .mapping_sha256 = completeMappingSha256V1(fixture),
        .receipt_sha256 = undefined,
    };
    receipt.receipt_sha256 = receiptRootV1(receipt);
    return receipt;
}

pub fn mapUnitV1(
    encoded_fixture: []const u8,
    unit_index: u64,
) Error!UnitMappingV1 {
    const fixture = try parseFixtureV1(encoded_fixture);
    const logical_units = try logicalUnitsV1(fixture);
    if (unit_index >= logical_units) return Error.UnitOutOfRange;
    var relative_offset: u64 = undefined;
    var unit_bytes: u64 = undefined;
    switch (fixture.kind) {
        .image => {
            const width = fixture.axes[0];
            const row = unit_index / width;
            const column = unit_index % width;
            unit_bytes = fixture.axes[2];
            const row_offset = try checkedMul(row, fixture.storage_stride);
            const column_offset = try checkedMul(column, unit_bytes);
            relative_offset = try checkedAdd(row_offset, column_offset);
        },
        .audio, .video => {
            unit_bytes = fixture.storage_stride;
            relative_offset = try checkedMul(
                unit_index,
                fixture.storage_stride,
            );
        },
    }
    const source_offset = try checkedAdd(
        fixture_header_bytes,
        relative_offset,
    );
    const has_timeline = fixture.kind != .image;
    const timeline_tick = if (has_timeline)
        try checkedAdd(fixture.start_ticks, unit_index)
    else
        0;
    var mapping: UnitMappingV1 = .{
        .kind = fixture.kind,
        .unit_index = unit_index,
        .source_offset = source_offset,
        .source_bytes = unit_bytes,
        .output_offset = relative_offset,
        .output_bytes = unit_bytes,
        .has_timeline = has_timeline,
        .timeline_tick = timeline_tick,
        .mapping_sha256 = undefined,
    };
    mapping.mapping_sha256 = unitMappingRootV1(
        mapping,
        fixture.fixture_sha256,
    );
    return mapping;
}

pub fn verifyCompleteMappingV1(
    encoded_fixture: []const u8,
) Error!u64 {
    const fixture = try parseFixtureV1(encoded_fixture);
    const logical_units = try logicalUnitsV1(fixture);
    var next_source: u64 = fixture_header_bytes;
    var next_output: u64 = 0;
    for (0..logical_units) |raw_index| {
        const mapping = try mapUnitV1(
            encoded_fixture,
            @intCast(raw_index),
        );
        if (mapping.source_offset != next_source or
            mapping.output_offset != next_output or
            mapping.source_bytes != mapping.output_bytes)
            return Error.InvalidFixture;
        next_source = try checkedAdd(
            next_source,
            mapping.source_bytes,
        );
        next_output = try checkedAdd(
            next_output,
            mapping.output_bytes,
        );
    }
    if (next_source !=
        fixture_header_bytes + fixture.payload.len or
        next_output != fixture.payload.len)
        return Error.InvalidFixture;
    return logical_units;
}

pub fn fixtureSha256V1(
    encoded: []const u8,
) Error!Digest {
    return (try parseFixtureV1(encoded)).fixture_sha256;
}

pub fn decoderImplementationSha256V1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(decoder_domain);
    hashU64(&hash, decoder_abi);
    hashU64(&hash, maximum_payload_bytes);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn identityTransformSha256V1(
    kind: media.MediaKindV1,
    representation: RepresentationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(transform_domain);
    hashU64(&hash, @intFromEnum(kind));
    hashU64(&hash, @intFromEnum(representation));
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn fixtureRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(fixture_domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn receiptRootV1(receipt: DecodeReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hashU64(&hash, @intFromEnum(receipt.kind));
    hashU64(&hash, receipt.logical_units);
    hashU64(&hash, receipt.source_payload_offset);
    hashU64(&hash, receipt.source_payload_bytes);
    hashU64(&hash, receipt.output_bytes);
    hash.update(&receipt.media_object_sha256);
    hash.update(&receipt.decode_plan_sha256);
    hash.update(&receipt.fixture_sha256);
    hash.update(&receipt.output_sha256);
    hash.update(&receipt.mapping_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn completeMappingSha256V1(
    fixture: ParsedFixtureV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(mapping_domain);
    hash.update(&fixture.fixture_sha256);
    hashU64(&hash, @intFromEnum(fixture.kind));
    hashU64(&hash, fixture_header_bytes);
    hashU64(&hash, fixture.payload.len);
    hashU64(
        &hash,
        logicalUnitsV1(fixture) catch unreachable,
    );
    hashU64(&hash, fixture.storage_stride);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn unitMappingRootV1(
    mapping: UnitMappingV1,
    fixture_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(mapping_domain);
    hash.update(&fixture_sha256);
    hashU64(&hash, @intFromEnum(mapping.kind));
    hashU64(&hash, mapping.unit_index);
    hashU64(&hash, mapping.source_offset);
    hashU64(&hash, mapping.source_bytes);
    hashU64(&hash, mapping.output_offset);
    hashU64(&hash, mapping.output_bytes);
    hashU64(&hash, @intFromBool(mapping.has_timeline));
    hashU64(&hash, mapping.timeline_tick);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn logicalUnitsV1(
    fixture: ParsedFixtureV1,
) Error!u64 {
    return switch (fixture.kind) {
        .image => checkedMul(fixture.axes[0], fixture.axes[1]),
        .audio => fixture.axes[0],
        .video => fixture.axes[2],
    };
}

fn validateSpecV1(spec: FixtureSpecV1) Error!void {
    if (spec.semantic_abi == 0 or
        spec.codec_id == 0 or
        spec.payload.len == 0 or
        spec.payload.len > maximum_payload_bytes or
        isZero(spec.tenant_scope_sha256) or
        isZero(spec.metadata_policy_sha256) or
        isZero(spec.provenance_sha256))
        return Error.InvalidFixture;
    for (spec.axes) |axis|
        if (axis == 0) return Error.InvalidFixture;
    for (spec.target_axes) |axis|
        if (axis == 0) return Error.InvalidFixture;
    if (!std.meta.eql(spec.target_axes, spec.axes))
        return Error.InvalidFixture;

    var expected_payload: u64 = undefined;
    switch (spec.kind) {
        .image => {
            const channels = spec.axes[2];
            const expected_representation: RepresentationV1 =
                if (channels == 3)
                    .image_rgb8
                else if (channels == 1)
                    .image_gray8
                else
                    return Error.InvalidFixture;
            const expected_layout: LayoutV1 =
                if (channels == 3) .image_rgb else .image_gray;
            const row_bytes = try checkedMul(spec.axes[0], channels);
            expected_payload = try checkedMul(
                row_bytes,
                spec.axes[1],
            );
            if (spec.representation != expected_representation or
                spec.layout != expected_layout or
                spec.orientation != .top_left or
                spec.transfer != .srgb or
                spec.alpha != .not_present or
                spec.time_base.numerator != 0 or
                spec.time_base.denominator != 1 or
                spec.storage_stride != row_bytes or
                spec.start_ticks != 0 or
                spec.keyframe_bits != 0)
                return Error.InvalidFixture;
        },
        .audio => {
            if (spec.axes[1] > 64 or spec.axes[2] > 768_000)
                return Error.InvalidFixture;
            const frame_bytes = try checkedMul(spec.axes[1], 2);
            expected_payload = try checkedMul(
                spec.axes[0],
                frame_bytes,
            );
            if (spec.representation != .audio_pcm_s16le or
                spec.layout != .audio_interleaved or
                spec.orientation != .not_applicable or
                spec.transfer != .not_applicable or
                spec.alpha != .not_applicable or
                spec.time_base.numerator != 1 or
                spec.time_base.denominator != spec.axes[2] or
                spec.storage_stride != frame_bytes or
                spec.keyframe_bits != 0)
                return Error.InvalidFixture;
        },
        .video => {
            if (spec.axes[2] > 64)
                return Error.InvalidFixture;
            media.validateTimeBaseV1(
                spec.time_base,
            ) catch return Error.InvalidFixture;
            const frame_bytes = try checkedMul(
                spec.axes[0],
                spec.axes[1],
            );
            expected_payload = try checkedMul(
                frame_bytes,
                spec.axes[2],
            );
            const allowed_keyframes: u64 = if (spec.axes[2] == 64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(spec.axes[2])) - 1;
            if (spec.representation != .video_gray8_intra or
                spec.layout != .video_gray or
                spec.orientation != .top_left or
                spec.transfer != .linear or
                spec.alpha != .not_present or
                spec.storage_stride != frame_bytes or
                spec.keyframe_bits & 1 == 0 or
                spec.keyframe_bits & ~allowed_keyframes != 0)
                return Error.InvalidFixture;
        },
    }
    if (expected_payload != spec.payload.len)
        return Error.InvalidFixture;
}

fn checkedAdd(a: anytype, b: anytype) Error!u64 {
    return std.math.add(
        u64,
        @intCast(a),
        @intCast(b),
    ) catch Error.ArithmeticOverflow;
}

fn checkedMul(a: anytype, b: anytype) Error!u64 {
    return std.math.mul(
        u64,
        @intCast(a),
        @intCast(b),
    ) catch Error.ArithmeticOverflow;
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    @memcpy(output[offset .. offset + 8], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn encodeTestFixture(
    spec: FixtureSpecV1,
    storage: *[maximum_fixture_bytes]u8,
) ![]const u8 {
    return encodeFixtureV1(spec, storage);
}

fn encodeTestPlan(
    fixture: ParsedFixtureV1,
    storage: *[decode_plan.plan_bytes]u8,
) ![]const u8 {
    const plan = try makeDecodePlanV1(
        fixture,
        [_]u8{0xd1} ** 32,
        [_]u8{0xe1} ** 32,
    );
    return decode_plan.encodePlanV1(plan, storage);
}

test "bounded fixtures decode image audio and video with complete mappings" {
    const specs = [_]FixtureSpecV1{
        imageSpecV1(),
        audioSpecV1(),
        videoSpecV1(),
    };
    var fixture_storage: [maximum_fixture_bytes]u8 = undefined;
    var plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var output: [maximum_payload_bytes]u8 = undefined;
    const expected_units = [_]u64{ 4, 8, 2 };
    const expected_fixture_roots = [_][]const u8{
        "5891de6bfad27654fa993b8a31c71749" ++
            "ab5346bd3701b2cbcf62ef8ef43cd8eb",
        "e3bf4bc1015c30431150acb9d70b4183" ++
            "19ba7109caf98952942e2ada6f5b6daf",
        "7c16ff3eb368dab477fafef9414cf3d6" ++
            "310dec334c6d8d3051bf04e5e2de0282",
    };
    const expected_plan_roots = [_][]const u8{
        "6930f3135b2821f2a47eceb6f83db94" ++
            "b5853418c3a9177fe334648a87138d9ea",
        "25b0032855459ec3d7b80bbedeb5f561" ++
            "28cf583c78d748354b8f2544e8ed547b",
        "4f951425133820d2b0119de9b889126a" ++
            "45dca1909c34c4139c4e8d0121a2e680",
    };
    const expected_receipt_roots = [_][]const u8{
        "b4445f2763effc0310621a3d9209ee71" ++
            "368e008bf6b0e717e7e81d515f00235e",
        "d1e4072db08208f64a91db6113a35fce" ++
            "c636884a0f14c16ffa8988a4ba4c8bf0",
        "bb21e899d7aa97ea92ce2297af98fbad" ++
            "b8b5f0b0343883eb01277c90de931911",
    };
    for (specs, expected_units, 0..) |spec, units, index| {
        const encoded_fixture = try encodeTestFixture(
            spec,
            &fixture_storage,
        );
        const fixture = try parseFixtureV1(encoded_fixture);
        var expected_fixture: Digest = undefined;
        _ = try std.fmt.hexToBytes(
            &expected_fixture,
            expected_fixture_roots[index],
        );
        try std.testing.expectEqualSlices(
            u8,
            &expected_fixture,
            &fixture.fixture_sha256,
        );
        const encoded_plan = try encodeTestPlan(
            fixture,
            &plan_storage,
        );
        var expected_plan: Digest = undefined;
        _ = try std.fmt.hexToBytes(
            &expected_plan,
            expected_plan_roots[index],
        );
        const plan_sha256 = try decode_plan.planSha256V1(
            encoded_plan,
        );
        try std.testing.expectEqualSlices(
            u8,
            &expected_plan,
            &plan_sha256,
        );
        const receipt = try decodeFixtureV1(
            encoded_fixture,
            encoded_plan,
            &output,
        );
        var expected_receipt: Digest = undefined;
        _ = try std.fmt.hexToBytes(
            &expected_receipt,
            expected_receipt_roots[index],
        );
        try std.testing.expectEqualSlices(
            u8,
            &expected_receipt,
            &receipt.receipt_sha256,
        );
        try std.testing.expectEqual(units, receipt.logical_units);
        try std.testing.expectEqualSlices(
            u8,
            spec.payload,
            output[0..spec.payload.len],
        );
        try std.testing.expectEqual(
            units,
            try verifyCompleteMappingV1(encoded_fixture),
        );
        const last = try mapUnitV1(encoded_fixture, units - 1);
        try std.testing.expectEqual(
            @as(u64, spec.payload.len),
            last.output_offset + last.output_bytes,
        );
    }
}

test "fixture wires reject every mutation and rehashed contradictions" {
    const specs = [_]FixtureSpecV1{
        imageSpecV1(),
        audioSpecV1(),
        videoSpecV1(),
    };
    var fixture_storage: [maximum_fixture_bytes]u8 = undefined;
    var corrupted: [maximum_fixture_bytes]u8 = undefined;
    for (specs) |spec| {
        const encoded = try encodeTestFixture(
            spec,
            &fixture_storage,
        );
        for (0..encoded.len) |index| {
            @memcpy(corrupted[0..encoded.len], encoded);
            corrupted[index] ^= 1;
            const accepted = if (parseFixtureV1(
                corrupted[0..encoded.len],
            )) |_| true else |_| false;
            try std.testing.expect(!accepted);
        }
        @memcpy(corrupted[0..encoded.len], encoded);
        writeU64(&corrupted, 32, 1);
        const rerooted = fixtureRootV1(
            corrupted[0 .. encoded.len - fixture_footer_bytes],
        );
        @memcpy(
            corrupted[encoded.len - fixture_footer_bytes .. encoded.len],
            &rerooted,
        );
        try std.testing.expectError(
            Error.InvalidFixture,
            parseFixtureV1(corrupted[0..encoded.len]),
        );

        @memcpy(corrupted[0..encoded.len], encoded);
        writeU64(&corrupted, 288, spec.target_axes[0] + 1);
        const geometry_rerooted = fixtureRootV1(
            corrupted[0 .. encoded.len - fixture_footer_bytes],
        );
        @memcpy(
            corrupted[encoded.len - fixture_footer_bytes .. encoded.len],
            &geometry_rerooted,
        );
        try std.testing.expectError(
            Error.InvalidFixture,
            parseFixtureV1(corrupted[0..encoded.len]),
        );
        try std.testing.expectError(
            Error.InvalidFixture,
            parseFixtureV1(encoded[0 .. encoded.len - 1]),
        );
    }
}

test "fixture plans reject every mutation for every media kind" {
    const specs = [_]FixtureSpecV1{
        imageSpecV1(),
        audioSpecV1(),
        videoSpecV1(),
    };
    var fixture_storage: [maximum_fixture_bytes]u8 = undefined;
    var plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var corrupted: [decode_plan.plan_bytes]u8 = undefined;
    for (specs) |spec| {
        const encoded_fixture = try encodeTestFixture(
            spec,
            &fixture_storage,
        );
        const fixture = try parseFixtureV1(encoded_fixture);
        const encoded_plan = try encodeTestPlan(
            fixture,
            &plan_storage,
        );
        for (0..encoded_plan.len) |index| {
            @memcpy(&corrupted, encoded_plan);
            corrupted[index] ^= 1;
            const accepted = if (decode_plan.decodePlanV1(
                &corrupted,
            )) |_| true else |_| false;
            try std.testing.expect(!accepted);
        }
        try std.testing.expectError(
            decode_plan.Error.InvalidPlan,
            decode_plan.decodePlanV1(
                encoded_plan[0 .. encoded_plan.len - 1],
            ),
        );
    }
}

test "fixture decoder rejects substitution capacity and overlap" {
    var image_storage: [maximum_fixture_bytes]u8 = undefined;
    var audio_storage: [maximum_fixture_bytes]u8 = undefined;
    var plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    const image_encoded = try encodeTestFixture(
        imageSpecV1(),
        &image_storage,
    );
    const audio_encoded = try encodeTestFixture(
        audioSpecV1(),
        &audio_storage,
    );
    const image = try parseFixtureV1(image_encoded);
    const image_plan = try encodeTestPlan(image, &plan_storage);
    var short: [image_payload.len - 1]u8 =
        [_]u8{0x5a} ** (image_payload.len - 1);
    try std.testing.expectError(
        Error.BufferTooSmall,
        decodeFixtureV1(image_encoded, image_plan, &short),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short, 0x5a));
    try std.testing.expectError(
        Error.InvalidPlan,
        decodeFixtureV1(audio_encoded, image_plan, &audio_storage),
    );
    try std.testing.expectError(
        Error.UnsafeDestination,
        decodeFixtureV1(
            image_encoded,
            image_plan,
            image_storage[fixture_header_bytes .. fixture_header_bytes + image_payload.len],
        ),
    );
    try std.testing.expectError(
        Error.UnitOutOfRange,
        mapUnitV1(image_encoded, 4),
    );
}
