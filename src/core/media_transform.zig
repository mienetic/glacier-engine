//! Deterministic image, audio, and video transform plans and executors.

const std = @import("std");
const media = @import("media_contract.zig");
const decode_plan = @import("media_decode_plan.zig");
const fixture_api = @import("media_fixture.zig");

pub const Digest = media.Digest;
pub const transform_plan_abi: u64 = 0x474d_5450_0000_0001;
pub const transform_implementation_abi: u64 = 0x474d_5458_0000_0001;
pub const transform_plan_magic = [_]u8{
    'G', 'M', 'T', 'R', 'F', 'M', '1', 0,
};
pub const transform_plan_bytes: usize = 512;
pub const transform_plan_body_bytes: usize = transform_plan_bytes - 32;
pub const allowed_flags: u64 = 0;
pub const allowed_capabilities: u64 = 0;
pub const parameter_count: usize = 8;
pub const maximum_video_selections: usize = parameter_count - 1;

const plan_domain = "glacier-media-transform-plan-v1\x00";
const implementation_domain = "glacier-media-transform-implementation-v1\x00";
const mapping_domain = "glacier-media-transform-mapping-v1\x00";
const mapping_chain_domain = "glacier-media-transform-mapping-chain-v1\x00";
const receipt_domain = "glacier-media-transform-receipt-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidFixture,
    InvalidPlan,
    InvalidReceipt,
    UnsafeDestination,
};

pub const TransformOperationV1 = enum(u64) {
    image_crop_nearest_tile = 1,
    audio_mix_decimate = 2,
    video_keyframe_select = 3,
};

pub const TransformPlanV1 = struct {
    operation: TransformOperationV1,
    kind: media.MediaKindV1,
    input_representation_id: u64,
    output_representation_id: u64,
    source_bytes: u64,
    output_bytes: u64,
    scratch_bytes: u64,
    logical_units: u64,
    source_axes: [3]u64,
    target_axes: [3]u64,
    source_time_base: media.TimeBaseV1,
    target_time_base: media.TimeBaseV1,
    parameters: [parameter_count]u64,
    media_object_sha256: Digest,
    decode_plan_sha256: Digest,
    decode_receipt_sha256: Digest,
    source_output_sha256: Digest,
    transform_implementation_sha256: Digest,
    resource_policy_sha256: Digest,
    challenge_sha256: Digest,
    required_capabilities: u64,
};

pub const TransformMappingV1 = struct {
    operation: TransformOperationV1,
    output_unit: u64,
    source_first_unit: u64,
    source_unit_count: u64,
    source_byte_offset: u64,
    source_bytes: u64,
    output_byte_offset: u64,
    output_bytes: u64,
    source_start_tick: u64,
    source_end_tick: u64,
    target_start_tick: u64,
    target_end_tick: u64,
    mapping_sha256: Digest,
};

pub const TransformReceiptV1 = struct {
    operation: TransformOperationV1,
    kind: media.MediaKindV1,
    logical_units: u64,
    output_bytes: u64,
    mapping_count: u64,
    transform_plan_sha256: Digest,
    decode_receipt_sha256: Digest,
    source_output_sha256: Digest,
    output_sha256: Digest,
    mapping_chain_sha256: Digest,
    receipt_sha256: Digest,
};

pub fn encodeTransformPlanV1(
    plan: TransformPlanV1,
    destination: []u8,
) Error![]const u8 {
    try validateTransformPlanV1(plan);
    if (destination.len < transform_plan_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..transform_plan_bytes];
    @memset(output, 0);
    @memcpy(output[0..8], &transform_plan_magic);
    writeU64(output, 8, transform_plan_abi);
    writeU64(output, 16, transform_plan_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(plan.operation));
    writeU64(output, 40, @intFromEnum(plan.kind));
    writeU64(output, 48, plan.input_representation_id);
    writeU64(output, 56, plan.output_representation_id);
    writeU64(output, 64, plan.source_bytes);
    writeU64(output, 72, plan.output_bytes);
    writeU64(output, 80, plan.scratch_bytes);
    writeU64(output, 88, plan.logical_units);
    for (plan.source_axes, 0..) |axis, index|
        writeU64(output, 96 + index * 8, axis);
    for (plan.target_axes, 0..) |axis, index|
        writeU64(output, 120 + index * 8, axis);
    writeU64(output, 144, plan.source_time_base.numerator);
    writeU64(output, 152, plan.source_time_base.denominator);
    writeU64(output, 160, plan.target_time_base.numerator);
    writeU64(output, 168, plan.target_time_base.denominator);
    for (plan.parameters, 0..) |parameter, index|
        writeU64(output, 176 + index * 8, parameter);
    @memcpy(output[240..272], &plan.media_object_sha256);
    @memcpy(output[272..304], &plan.decode_plan_sha256);
    @memcpy(output[304..336], &plan.decode_receipt_sha256);
    @memcpy(output[336..368], &plan.source_output_sha256);
    @memcpy(
        output[368..400],
        &plan.transform_implementation_sha256,
    );
    @memcpy(output[400..432], &plan.resource_policy_sha256);
    @memcpy(output[432..464], &plan.challenge_sha256);
    writeU64(output, 464, plan.required_capabilities);
    const root = transformPlanRootV1(
        output[0..transform_plan_body_bytes],
    );
    @memcpy(output[transform_plan_body_bytes..], &root);
    return output;
}

pub fn decodeTransformPlanV1(
    encoded: []const u8,
) Error!TransformPlanV1 {
    if (encoded.len != transform_plan_bytes or
        !std.mem.eql(u8, encoded[0..8], &transform_plan_magic) or
        readU64(encoded, 8) != transform_plan_abi or
        readU64(encoded, 16) != transform_plan_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 472) != 0)
        return Error.InvalidPlan;
    var footer: Digest = undefined;
    @memcpy(&footer, encoded[transform_plan_body_bytes..]);
    if (!std.mem.eql(
        u8,
        &footer,
        &transformPlanRootV1(
            encoded[0..transform_plan_body_bytes],
        ),
    )) return Error.InvalidPlan;

    const operation = std.meta.intToEnum(
        TransformOperationV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidPlan;
    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(encoded, 40),
    ) catch return Error.InvalidPlan;
    var plan: TransformPlanV1 = .{
        .operation = operation,
        .kind = kind,
        .input_representation_id = readU64(encoded, 48),
        .output_representation_id = readU64(encoded, 56),
        .source_bytes = readU64(encoded, 64),
        .output_bytes = readU64(encoded, 72),
        .scratch_bytes = readU64(encoded, 80),
        .logical_units = readU64(encoded, 88),
        .source_axes = .{
            readU64(encoded, 96),
            readU64(encoded, 104),
            readU64(encoded, 112),
        },
        .target_axes = .{
            readU64(encoded, 120),
            readU64(encoded, 128),
            readU64(encoded, 136),
        },
        .source_time_base = .{
            .numerator = readU64(encoded, 144),
            .denominator = readU64(encoded, 152),
        },
        .target_time_base = .{
            .numerator = readU64(encoded, 160),
            .denominator = readU64(encoded, 168),
        },
        .parameters = undefined,
        .media_object_sha256 = undefined,
        .decode_plan_sha256 = undefined,
        .decode_receipt_sha256 = undefined,
        .source_output_sha256 = undefined,
        .transform_implementation_sha256 = undefined,
        .resource_policy_sha256 = undefined,
        .challenge_sha256 = undefined,
        .required_capabilities = readU64(encoded, 464),
    };
    for (&plan.parameters, 0..) |*parameter, index|
        parameter.* = readU64(encoded, 176 + index * 8);
    @memcpy(&plan.media_object_sha256, encoded[240..272]);
    @memcpy(&plan.decode_plan_sha256, encoded[272..304]);
    @memcpy(&plan.decode_receipt_sha256, encoded[304..336]);
    @memcpy(&plan.source_output_sha256, encoded[336..368]);
    @memcpy(
        &plan.transform_implementation_sha256,
        encoded[368..400],
    );
    @memcpy(&plan.resource_policy_sha256, encoded[400..432]);
    @memcpy(&plan.challenge_sha256, encoded[432..464]);
    try validateTransformPlanV1(plan);
    return plan;
}

pub fn transformPlanSha256V1(
    encoded: []const u8,
) Error!Digest {
    _ = try decodeTransformPlanV1(encoded);
    var root: Digest = undefined;
    @memcpy(&root, encoded[transform_plan_body_bytes..]);
    return root;
}

pub fn makeImagePlanV1(
    fixture: fixture_api.ParsedFixtureV1,
    decode_receipt: fixture_api.DecodeReceiptV1,
    crop_x: u64,
    crop_y: u64,
    crop_width: u64,
    crop_height: u64,
    target_width: u64,
    target_height: u64,
    tile_width: u64,
    tile_height: u64,
    resource_policy_sha256: Digest,
    challenge_sha256: Digest,
) Error!TransformPlanV1 {
    const channels = fixture.target_axes[2];
    const target_pixels = try checkedMul(target_width, target_height);
    const output_bytes = try checkedMul(target_pixels, channels);
    const plan: TransformPlanV1 = .{
        .operation = .image_crop_nearest_tile,
        .kind = .image,
        .input_representation_id = @intFromEnum(fixture.representation),
        .output_representation_id = @intFromEnum(fixture.representation),
        .source_bytes = decode_receipt.output_bytes,
        .output_bytes = output_bytes,
        .scratch_bytes = 0,
        .logical_units = target_pixels,
        .source_axes = fixture.target_axes,
        .target_axes = .{ target_width, target_height, channels },
        .source_time_base = fixture.time_base,
        .target_time_base = fixture.time_base,
        .parameters = .{
            crop_x,
            crop_y,
            crop_width,
            crop_height,
            target_width,
            target_height,
            tile_width,
            tile_height,
        },
        .media_object_sha256 = fixture.media_object_sha256,
        .decode_plan_sha256 = decode_receipt.decode_plan_sha256,
        .decode_receipt_sha256 = decode_receipt.receipt_sha256,
        .source_output_sha256 = decode_receipt.output_sha256,
        .transform_implementation_sha256 = transformImplementationSha256V1(),
        .resource_policy_sha256 = resource_policy_sha256,
        .challenge_sha256 = challenge_sha256,
        .required_capabilities = 0,
    };
    try validateTransformPlanV1(plan);
    return plan;
}

pub fn makeAudioPlanV1(
    fixture: fixture_api.ParsedFixtureV1,
    decode_receipt: fixture_api.DecodeReceiptV1,
    source_start_frame: u64,
    source_frame_count: u64,
    target_sample_rate: u64,
    left_weight: u64,
    right_weight: u64,
    mix_denominator: u64,
    resource_policy_sha256: Digest,
    challenge_sha256: Digest,
) Error!TransformPlanV1 {
    const source_rate = fixture.target_axes[2];
    if (target_sample_rate == 0 or
        source_rate % target_sample_rate != 0)
        return Error.InvalidPlan;
    const factor = source_rate / target_sample_rate;
    if (factor == 0 or source_frame_count % factor != 0)
        return Error.InvalidPlan;
    const target_frames = source_frame_count / factor;
    const output_bytes = try checkedMul(target_frames, 2);
    const plan: TransformPlanV1 = .{
        .operation = .audio_mix_decimate,
        .kind = .audio,
        .input_representation_id = @intFromEnum(fixture.representation),
        .output_representation_id = @intFromEnum(
            fixture_api.RepresentationV1.audio_pcm_s16le,
        ),
        .source_bytes = decode_receipt.output_bytes,
        .output_bytes = output_bytes,
        .scratch_bytes = 0,
        .logical_units = target_frames,
        .source_axes = fixture.target_axes,
        .target_axes = .{ target_frames, 1, target_sample_rate },
        .source_time_base = fixture.time_base,
        .target_time_base = .{
            .numerator = 1,
            .denominator = target_sample_rate,
        },
        .parameters = .{
            source_start_frame,
            source_frame_count,
            left_weight,
            right_weight,
            mix_denominator,
            factor,
            0,
            0,
        },
        .media_object_sha256 = fixture.media_object_sha256,
        .decode_plan_sha256 = decode_receipt.decode_plan_sha256,
        .decode_receipt_sha256 = decode_receipt.receipt_sha256,
        .source_output_sha256 = decode_receipt.output_sha256,
        .transform_implementation_sha256 = transformImplementationSha256V1(),
        .resource_policy_sha256 = resource_policy_sha256,
        .challenge_sha256 = challenge_sha256,
        .required_capabilities = 0,
    };
    try validateTransformPlanV1(plan);
    return plan;
}

pub fn makeVideoPlanV1(
    fixture: fixture_api.ParsedFixtureV1,
    decode_receipt: fixture_api.DecodeReceiptV1,
    selected_frames: []const u64,
    resource_policy_sha256: Digest,
    challenge_sha256: Digest,
) Error!TransformPlanV1 {
    if (selected_frames.len == 0 or
        selected_frames.len > maximum_video_selections)
        return Error.InvalidPlan;
    var parameters = [_]u64{0} ** parameter_count;
    parameters[0] = selected_frames.len;
    for (selected_frames, 0..) |frame, index|
        parameters[index + 1] = frame;
    const frame_bytes = try checkedMul(
        fixture.target_axes[0],
        fixture.target_axes[1],
    );
    const output_bytes = try checkedMul(
        frame_bytes,
        selected_frames.len,
    );
    const plan: TransformPlanV1 = .{
        .operation = .video_keyframe_select,
        .kind = .video,
        .input_representation_id = @intFromEnum(fixture.representation),
        .output_representation_id = @intFromEnum(fixture.representation),
        .source_bytes = decode_receipt.output_bytes,
        .output_bytes = output_bytes,
        .scratch_bytes = 0,
        .logical_units = selected_frames.len,
        .source_axes = fixture.target_axes,
        .target_axes = .{
            fixture.target_axes[0],
            fixture.target_axes[1],
            selected_frames.len,
        },
        .source_time_base = fixture.time_base,
        .target_time_base = fixture.time_base,
        .parameters = parameters,
        .media_object_sha256 = fixture.media_object_sha256,
        .decode_plan_sha256 = decode_receipt.decode_plan_sha256,
        .decode_receipt_sha256 = decode_receipt.receipt_sha256,
        .source_output_sha256 = decode_receipt.output_sha256,
        .transform_implementation_sha256 = transformImplementationSha256V1(),
        .resource_policy_sha256 = resource_policy_sha256,
        .challenge_sha256 = challenge_sha256,
        .required_capabilities = 0,
    };
    try validateTransformPlanV1(plan);
    return plan;
}

pub fn executeV1(
    encoded_fixture: []const u8,
    encoded_decode_plan: []const u8,
    encoded_transform_plan: []const u8,
    decoded_source: []u8,
    output: []u8,
    mappings: []TransformMappingV1,
) Error!TransformReceiptV1 {
    const fixture = fixture_api.parseFixtureV1(
        encoded_fixture,
    ) catch return Error.InvalidFixture;
    const plan = try decodeTransformPlanV1(encoded_transform_plan);
    const decode_plan_sha256 = decode_plan.planSha256V1(
        encoded_decode_plan,
    ) catch return Error.InvalidPlan;
    if (!std.mem.eql(
        u8,
        &plan.decode_plan_sha256,
        &decode_plan_sha256,
    )) return Error.InvalidPlan;
    const source_bytes = std.math.cast(
        usize,
        plan.source_bytes,
    ) orelse return Error.InvalidPlan;
    const output_bytes = std.math.cast(
        usize,
        plan.output_bytes,
    ) orelse return Error.InvalidPlan;
    const mapping_count = std.math.cast(
        usize,
        plan.logical_units,
    ) orelse return Error.InvalidPlan;
    if (decoded_source.len < source_bytes or
        output.len < output_bytes or
        mappings.len < mapping_count)
        return Error.BufferTooSmall;
    const source_slice = decoded_source[0..source_bytes];
    const output_slice = output[0..output_bytes];
    const mapping_slice = mappings[0..mapping_count];
    const mapping_bytes = std.mem.sliceAsBytes(mapping_slice);
    if (slicesOverlap(source_slice, encoded_fixture) or
        slicesOverlap(source_slice, encoded_decode_plan) or
        slicesOverlap(source_slice, encoded_transform_plan) or
        slicesOverlap(source_slice, output_slice) or
        slicesOverlap(source_slice, mapping_bytes) or
        slicesOverlap(output_slice, encoded_fixture) or
        slicesOverlap(output_slice, encoded_decode_plan) or
        slicesOverlap(output_slice, encoded_transform_plan) or
        slicesOverlap(output_slice, mapping_bytes) or
        slicesOverlap(mapping_bytes, encoded_fixture) or
        slicesOverlap(mapping_bytes, encoded_decode_plan) or
        slicesOverlap(mapping_bytes, encoded_transform_plan))
        return Error.UnsafeDestination;

    const decode_receipt = fixture_api.decodeFixtureV1(
        encoded_fixture,
        encoded_decode_plan,
        source_slice,
    ) catch return Error.InvalidFixture;
    try validateForExecutionV1(
        plan,
        fixture,
        decode_receipt,
        source_slice,
    );

    switch (plan.operation) {
        .image_crop_nearest_tile => executeImageV1(
            plan,
            fixture,
            source_slice,
            output_slice,
            mapping_slice,
        ),
        .audio_mix_decimate => executeAudioV1(
            plan,
            fixture,
            source_slice,
            output_slice,
            mapping_slice,
        ),
        .video_keyframe_select => executeVideoV1(
            plan,
            fixture,
            source_slice,
            output_slice,
            mapping_slice,
        ),
    }
    const transform_plan_sha256 = try transformPlanSha256V1(
        encoded_transform_plan,
    );
    var output_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        output_slice,
        &output_sha256,
        .{},
    );
    const mapping_chain_sha256 = mappingChainRootV1(
        transform_plan_sha256,
        mapping_slice,
    );
    var receipt: TransformReceiptV1 = .{
        .operation = plan.operation,
        .kind = plan.kind,
        .logical_units = plan.logical_units,
        .output_bytes = plan.output_bytes,
        .mapping_count = plan.logical_units,
        .transform_plan_sha256 = transform_plan_sha256,
        .decode_receipt_sha256 = decode_receipt.receipt_sha256,
        .source_output_sha256 = decode_receipt.output_sha256,
        .output_sha256 = output_sha256,
        .mapping_chain_sha256 = mapping_chain_sha256,
        .receipt_sha256 = [_]u8{0} ** 32,
    };
    receipt.receipt_sha256 = transformReceiptRootV1(receipt);
    return receipt;
}

pub fn verifyReceiptV1(
    encoded_fixture: []const u8,
    encoded_transform_plan: []const u8,
    receipt: TransformReceiptV1,
    output: []const u8,
    mappings: []const TransformMappingV1,
) Error!void {
    const fixture = fixture_api.parseFixtureV1(
        encoded_fixture,
    ) catch return Error.InvalidFixture;
    const plan = try decodeTransformPlanV1(encoded_transform_plan);
    const plan_sha256 = try transformPlanSha256V1(
        encoded_transform_plan,
    );
    const output_bytes = std.math.cast(
        usize,
        plan.output_bytes,
    ) orelse return Error.InvalidReceipt;
    const mapping_count = std.math.cast(
        usize,
        plan.logical_units,
    ) orelse return Error.InvalidReceipt;
    if (output.len != output_bytes or
        mappings.len != mapping_count or
        plan.kind != fixture.kind or
        plan.input_representation_id !=
            @intFromEnum(fixture.representation) or
        plan.source_bytes != fixture.payload.len or
        !std.meta.eql(plan.source_axes, fixture.target_axes) or
        !std.meta.eql(plan.source_time_base, fixture.time_base) or
        !std.mem.eql(
            u8,
            &plan.media_object_sha256,
            &fixture.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.transform_implementation_sha256,
            &transformImplementationSha256V1(),
        ) or
        receipt.operation != plan.operation or
        receipt.kind != plan.kind or
        receipt.logical_units != plan.logical_units or
        receipt.output_bytes != plan.output_bytes or
        receipt.mapping_count != plan.logical_units or
        !std.mem.eql(
            u8,
            &receipt.transform_plan_sha256,
            &plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.decode_receipt_sha256,
            &plan.decode_receipt_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.source_output_sha256,
            &plan.source_output_sha256,
        ))
        return Error.InvalidReceipt;
    var source_output_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        fixture.payload,
        &source_output_sha256,
        .{},
    );
    var output_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        output,
        &output_sha256,
        .{},
    );
    if (!std.mem.eql(
        u8,
        &plan.source_output_sha256,
        &source_output_sha256,
    ) or
        !std.mem.eql(
            u8,
            &receipt.output_sha256,
            &output_sha256,
        ))
        return Error.InvalidReceipt;
    for (mappings, 0..) |mapping, index| {
        const output_unit: u64 = @intCast(index);
        const expected = expectedMappingV1(
            plan,
            fixture,
            output_unit,
        ) catch return Error.InvalidReceipt;
        if (!std.meta.eql(mapping, expected) or
            !(expectedOutputUnitV1(
                plan,
                fixture,
                output_unit,
                output,
            ) catch return Error.InvalidReceipt))
            return Error.InvalidReceipt;
    }
    const mapping_chain_sha256 = mappingChainRootV1(
        plan_sha256,
        mappings,
    );
    if (!std.mem.eql(
        u8,
        &receipt.mapping_chain_sha256,
        &mapping_chain_sha256,
    ) or
        !std.mem.eql(
            u8,
            &receipt.receipt_sha256,
            &transformReceiptRootV1(receipt),
        ))
        return Error.InvalidReceipt;
}

pub fn validateTransformPlanV1(plan: TransformPlanV1) Error!void {
    if (plan.input_representation_id == 0 or
        plan.output_representation_id == 0 or
        plan.source_bytes == 0 or
        plan.output_bytes == 0 or
        plan.logical_units == 0 or
        plan.required_capabilities != allowed_capabilities or
        isZero(plan.media_object_sha256) or
        isZero(plan.decode_plan_sha256) or
        isZero(plan.decode_receipt_sha256) or
        isZero(plan.source_output_sha256) or
        isZero(plan.transform_implementation_sha256) or
        isZero(plan.resource_policy_sha256) or
        isZero(plan.challenge_sha256))
        return Error.InvalidPlan;
    for (plan.source_axes) |axis|
        if (axis == 0) return Error.InvalidPlan;
    for (plan.target_axes) |axis|
        if (axis == 0) return Error.InvalidPlan;
    switch (plan.operation) {
        .image_crop_nearest_tile => try validateImagePlanV1(plan),
        .audio_mix_decimate => try validateAudioPlanV1(plan),
        .video_keyframe_select => try validateVideoPlanV1(plan),
    }
}

pub fn transformImplementationSha256V1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(implementation_domain);
    hashU64(&hash, transform_implementation_abi);
    hashU64(&hash, parameter_count);
    hashU64(&hash, maximum_video_selections);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn transformPlanRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn transformReceiptRootV1(
    receipt: TransformReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hashU64(&hash, @intFromEnum(receipt.operation));
    hashU64(&hash, @intFromEnum(receipt.kind));
    hashU64(&hash, receipt.logical_units);
    hashU64(&hash, receipt.output_bytes);
    hashU64(&hash, receipt.mapping_count);
    hash.update(&receipt.transform_plan_sha256);
    hash.update(&receipt.decode_receipt_sha256);
    hash.update(&receipt.source_output_sha256);
    hash.update(&receipt.output_sha256);
    hash.update(&receipt.mapping_chain_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn validateForExecutionV1(
    plan: TransformPlanV1,
    fixture: fixture_api.ParsedFixtureV1,
    decode_receipt: fixture_api.DecodeReceiptV1,
    decoded_source: []const u8,
) Error!void {
    try validateTransformPlanV1(plan);
    var source_output_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        decoded_source,
        &source_output_sha256,
        .{},
    );
    const receipt_sha256 = fixture_api.receiptRootV1(
        decode_receipt,
    );
    if (!std.mem.eql(
        u8,
        &receipt_sha256,
        &decode_receipt.receipt_sha256,
    ) or
        plan.kind != fixture.kind or
        plan.input_representation_id !=
            @intFromEnum(fixture.representation) or
        plan.source_bytes != decoded_source.len or
        !std.meta.eql(plan.source_axes, fixture.target_axes) or
        !std.meta.eql(plan.source_time_base, fixture.time_base) or
        !std.mem.eql(
            u8,
            &plan.media_object_sha256,
            &fixture.media_object_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.decode_plan_sha256,
            &decode_receipt.decode_plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.decode_receipt_sha256,
            &decode_receipt.receipt_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.source_output_sha256,
            &source_output_sha256,
        ) or
        !std.mem.eql(
            u8,
            &plan.transform_implementation_sha256,
            &transformImplementationSha256V1(),
        ))
        return Error.InvalidPlan;
    if (plan.operation == .video_keyframe_select) {
        const count: usize = @intCast(plan.parameters[0]);
        for (plan.parameters[1 .. count + 1]) |frame| {
            const bit = @as(u64, 1) << @intCast(frame);
            if (fixture.keyframe_bits & bit == 0)
                return Error.InvalidPlan;
        }
    }
}

fn validateImagePlanV1(plan: TransformPlanV1) Error!void {
    if (plan.kind != .image or
        plan.input_representation_id != plan.output_representation_id or
        (plan.input_representation_id !=
            @intFromEnum(fixture_api.RepresentationV1.image_rgb8) and
            plan.input_representation_id !=
                @intFromEnum(fixture_api.RepresentationV1.image_gray8)) or
        !isStaticBase(plan.source_time_base) or
        !isStaticBase(plan.target_time_base) or
        plan.scratch_bytes != 0 or
        plan.source_axes[2] != plan.target_axes[2])
        return Error.InvalidPlan;
    const crop_x = plan.parameters[0];
    const crop_y = plan.parameters[1];
    const crop_width = plan.parameters[2];
    const crop_height = plan.parameters[3];
    const target_width = plan.parameters[4];
    const target_height = plan.parameters[5];
    const tile_width = plan.parameters[6];
    const tile_height = plan.parameters[7];
    if (crop_width == 0 or crop_height == 0 or
        target_width == 0 or target_height == 0 or
        tile_width == 0 or tile_height == 0 or
        target_width != plan.target_axes[0] or
        target_height != plan.target_axes[1] or
        target_width % tile_width != 0 or
        target_height % tile_height != 0)
        return Error.InvalidPlan;
    const crop_end_x = checkedAdd(
        crop_x,
        crop_width,
    ) catch return Error.InvalidPlan;
    const crop_end_y = checkedAdd(
        crop_y,
        crop_height,
    ) catch return Error.InvalidPlan;
    if (crop_end_x > plan.source_axes[0] or
        crop_end_y > plan.source_axes[1])
        return Error.InvalidPlan;
    const source_pixels = checkedMul(
        plan.source_axes[0],
        plan.source_axes[1],
    ) catch return Error.InvalidPlan;
    const expected_source = checkedMul(
        source_pixels,
        plan.source_axes[2],
    ) catch return Error.InvalidPlan;
    const target_pixels = checkedMul(
        target_width,
        target_height,
    ) catch return Error.InvalidPlan;
    const expected_output = checkedMul(
        target_pixels,
        plan.target_axes[2],
    ) catch return Error.InvalidPlan;
    if (plan.source_bytes != expected_source or
        plan.output_bytes != expected_output or
        plan.logical_units != target_pixels)
        return Error.InvalidPlan;
}

fn validateAudioPlanV1(plan: TransformPlanV1) Error!void {
    if (plan.kind != .audio or
        plan.input_representation_id !=
            @intFromEnum(fixture_api.RepresentationV1.audio_pcm_s16le) or
        plan.output_representation_id !=
            @intFromEnum(fixture_api.RepresentationV1.audio_pcm_s16le) or
        plan.source_axes[1] != 2 or
        plan.target_axes[1] != 1 or
        plan.source_axes[2] != plan.source_time_base.denominator or
        plan.source_time_base.numerator != 1 or
        plan.target_axes[2] != plan.target_time_base.denominator or
        plan.target_time_base.numerator != 1 or
        plan.scratch_bytes != 0 or
        plan.parameters[6] != 0 or
        plan.parameters[7] != 0)
        return Error.InvalidPlan;
    media.validateTimeBaseV1(
        plan.source_time_base,
    ) catch return Error.InvalidPlan;
    media.validateTimeBaseV1(
        plan.target_time_base,
    ) catch return Error.InvalidPlan;
    const start = plan.parameters[0];
    const source_count = plan.parameters[1];
    const left_weight = plan.parameters[2];
    const right_weight = plan.parameters[3];
    const denominator = plan.parameters[4];
    const factor = plan.parameters[5];
    const weight_sum = checkedAdd(
        left_weight,
        right_weight,
    ) catch return Error.InvalidPlan;
    const divisor = checkedMul(
        denominator,
        factor,
    ) catch return Error.InvalidPlan;
    const maximum_accumulator = checkedMul(
        divisor,
        32_768,
    ) catch return Error.InvalidPlan;
    if (source_count == 0 or denominator == 0 or factor == 0 or
        left_weight > 65_535 or right_weight > 65_535 or
        weight_sum != denominator or
        maximum_accumulator > std.math.maxInt(i64) or
        plan.source_axes[2] % plan.target_axes[2] != 0 or
        plan.source_axes[2] / plan.target_axes[2] != factor or
        source_count % factor != 0)
        return Error.InvalidPlan;
    const source_end = checkedAdd(
        start,
        source_count,
    ) catch return Error.InvalidPlan;
    if (source_end > plan.source_axes[0])
        return Error.InvalidPlan;
    const target_frames = source_count / factor;
    const source_samples = checkedMul(
        plan.source_axes[0],
        2,
    ) catch return Error.InvalidPlan;
    const expected_source = checkedMul(
        source_samples,
        2,
    ) catch return Error.InvalidPlan;
    const expected_output = checkedMul(
        target_frames,
        2,
    ) catch return Error.InvalidPlan;
    if (plan.target_axes[0] != target_frames or
        plan.source_bytes != expected_source or
        plan.output_bytes != expected_output or
        plan.logical_units != target_frames)
        return Error.InvalidPlan;
}

fn validateVideoPlanV1(plan: TransformPlanV1) Error!void {
    if (plan.kind != .video or
        plan.input_representation_id !=
            @intFromEnum(fixture_api.RepresentationV1.video_gray8_intra) or
        plan.output_representation_id !=
            @intFromEnum(fixture_api.RepresentationV1.video_gray8_intra) or
        plan.source_axes[0] != plan.target_axes[0] or
        plan.source_axes[1] != plan.target_axes[1] or
        !std.meta.eql(plan.source_time_base, plan.target_time_base) or
        plan.scratch_bytes != 0)
        return Error.InvalidPlan;
    media.validateTimeBaseV1(
        plan.source_time_base,
    ) catch return Error.InvalidPlan;
    const count = plan.parameters[0];
    if (count == 0 or count > maximum_video_selections or
        count != plan.target_axes[2] or
        count != plan.logical_units)
        return Error.InvalidPlan;
    const count_usize: usize = @intCast(count);
    for (plan.parameters[1 .. count_usize + 1], 0..) |frame, index| {
        if (frame >= plan.source_axes[2])
            return Error.InvalidPlan;
        for (plan.parameters[1 .. index + 1]) |prior|
            if (prior == frame) return Error.InvalidPlan;
    }
    for (plan.parameters[count_usize + 1 ..]) |unused|
        if (unused != 0) return Error.InvalidPlan;
    const frame_bytes = checkedMul(
        plan.source_axes[0],
        plan.source_axes[1],
    ) catch return Error.InvalidPlan;
    const expected_source = checkedMul(
        frame_bytes,
        plan.source_axes[2],
    ) catch return Error.InvalidPlan;
    const expected_output = checkedMul(
        frame_bytes,
        count,
    ) catch return Error.InvalidPlan;
    if (plan.source_bytes != expected_source or
        plan.output_bytes != expected_output)
        return Error.InvalidPlan;
}

fn executeImageV1(
    plan: TransformPlanV1,
    fixture: fixture_api.ParsedFixtureV1,
    source: []const u8,
    output: []u8,
    mappings: []TransformMappingV1,
) void {
    const crop_x = plan.parameters[0];
    const crop_y = plan.parameters[1];
    const crop_width = plan.parameters[2];
    const crop_height = plan.parameters[3];
    const target_width = plan.target_axes[0];
    const channels = plan.target_axes[2];
    for (mappings, 0..) |*mapping, raw_index| {
        const output_unit: u64 = @intCast(raw_index);
        const output_y = output_unit / target_width;
        const output_x = output_unit % target_width;
        const source_x = crop_x +
            output_x * crop_width / target_width;
        const source_y = crop_y +
            output_y * crop_height / plan.target_axes[1];
        const source_unit = source_y * plan.source_axes[0] + source_x;
        const source_offset = source_unit * channels;
        const output_offset = output_unit * channels;
        const source_offset_usize: usize = @intCast(source_offset);
        const output_offset_usize: usize = @intCast(output_offset);
        const channels_usize: usize = @intCast(channels);
        @memcpy(
            output[output_offset_usize .. output_offset_usize + channels_usize],
            source[source_offset_usize .. source_offset_usize + channels_usize],
        );
        mapping.* = makeMappingV1(
            plan.operation,
            output_unit,
            source_unit,
            1,
            source_offset,
            channels,
            output_offset,
            channels,
            0,
            0,
            0,
            0,
            plan.decode_receipt_sha256,
        );
    }
    _ = fixture;
}

fn executeAudioV1(
    plan: TransformPlanV1,
    fixture: fixture_api.ParsedFixtureV1,
    source: []const u8,
    output: []u8,
    mappings: []TransformMappingV1,
) void {
    const start = plan.parameters[0];
    const left_weight: i64 = @intCast(plan.parameters[2]);
    const right_weight: i64 = @intCast(plan.parameters[3]);
    const denominator: i64 = @intCast(plan.parameters[4]);
    const factor = plan.parameters[5];
    const divisor = denominator * @as(i64, @intCast(factor));
    for (mappings, 0..) |*mapping, raw_index| {
        const output_unit: u64 = @intCast(raw_index);
        const source_first = start + output_unit * factor;
        var sum: i64 = 0;
        for (0..factor) |raw_frame| {
            const frame = source_first + raw_frame;
            const offset: usize = @intCast(frame * 4);
            const left = std.mem.readInt(
                i16,
                source[offset .. offset + 2][0..2],
                .little,
            );
            const right = std.mem.readInt(
                i16,
                source[offset + 2 .. offset + 4][0..2],
                .little,
            );
            sum += @as(i64, left) * left_weight +
                @as(i64, right) * right_weight;
        }
        const sample: i16 = @intCast(@divTrunc(sum, divisor));
        var sample_bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &sample_bytes, sample, .little);
        const output_offset = output_unit * 2;
        const output_offset_usize: usize = @intCast(output_offset);
        @memcpy(
            output[output_offset_usize .. output_offset_usize + 2],
            &sample_bytes,
        );
        const source_offset = source_first * 4;
        const source_bytes = factor * 4;
        mapping.* = makeMappingV1(
            plan.operation,
            output_unit,
            source_first,
            factor,
            source_offset,
            source_bytes,
            output_offset,
            2,
            fixture.start_ticks + source_first,
            fixture.start_ticks + source_first + factor,
            output_unit,
            output_unit + 1,
            plan.decode_receipt_sha256,
        );
    }
}

fn executeVideoV1(
    plan: TransformPlanV1,
    fixture: fixture_api.ParsedFixtureV1,
    source: []const u8,
    output: []u8,
    mappings: []TransformMappingV1,
) void {
    const frame_bytes = plan.source_axes[0] * plan.source_axes[1];
    for (mappings, 0..) |*mapping, raw_index| {
        const output_unit: u64 = @intCast(raw_index);
        const source_frame = plan.parameters[raw_index + 1];
        const source_offset = source_frame * frame_bytes;
        const output_offset = output_unit * frame_bytes;
        const source_offset_usize: usize = @intCast(source_offset);
        const output_offset_usize: usize = @intCast(output_offset);
        const frame_bytes_usize: usize = @intCast(frame_bytes);
        @memcpy(
            output[output_offset_usize .. output_offset_usize + frame_bytes_usize],
            source[source_offset_usize .. source_offset_usize + frame_bytes_usize],
        );
        mapping.* = makeMappingV1(
            plan.operation,
            output_unit,
            source_frame,
            1,
            source_offset,
            frame_bytes,
            output_offset,
            frame_bytes,
            fixture.start_ticks + source_frame,
            fixture.start_ticks + source_frame + 1,
            output_unit,
            output_unit + 1,
            plan.decode_receipt_sha256,
        );
    }
}

fn makeMappingV1(
    operation: TransformOperationV1,
    output_unit: u64,
    source_first_unit: u64,
    source_unit_count: u64,
    source_byte_offset: u64,
    source_bytes: u64,
    output_byte_offset: u64,
    output_bytes: u64,
    source_start_tick: u64,
    source_end_tick: u64,
    target_start_tick: u64,
    target_end_tick: u64,
    decode_receipt_sha256: Digest,
) TransformMappingV1 {
    var mapping: TransformMappingV1 = .{
        .operation = operation,
        .output_unit = output_unit,
        .source_first_unit = source_first_unit,
        .source_unit_count = source_unit_count,
        .source_byte_offset = source_byte_offset,
        .source_bytes = source_bytes,
        .output_byte_offset = output_byte_offset,
        .output_bytes = output_bytes,
        .source_start_tick = source_start_tick,
        .source_end_tick = source_end_tick,
        .target_start_tick = target_start_tick,
        .target_end_tick = target_end_tick,
        .mapping_sha256 = [_]u8{0} ** 32,
    };
    mapping.mapping_sha256 = mappingRootV1(
        mapping,
        decode_receipt_sha256,
    );
    return mapping;
}

fn expectedMappingV1(
    plan: TransformPlanV1,
    fixture: fixture_api.ParsedFixtureV1,
    output_unit: u64,
) Error!TransformMappingV1 {
    if (output_unit >= plan.logical_units)
        return Error.InvalidReceipt;
    return switch (plan.operation) {
        .image_crop_nearest_tile => blk: {
            const target_width = plan.target_axes[0];
            const output_y = output_unit / target_width;
            const output_x = output_unit % target_width;
            const source_x = plan.parameters[0] +
                output_x * plan.parameters[2] / target_width;
            const source_y = plan.parameters[1] +
                output_y * plan.parameters[3] / plan.target_axes[1];
            const source_unit =
                source_y * plan.source_axes[0] + source_x;
            const channels = plan.target_axes[2];
            break :blk makeMappingV1(
                plan.operation,
                output_unit,
                source_unit,
                1,
                source_unit * channels,
                channels,
                output_unit * channels,
                channels,
                0,
                0,
                0,
                0,
                plan.decode_receipt_sha256,
            );
        },
        .audio_mix_decimate => blk: {
            const factor = plan.parameters[5];
            const source_first =
                plan.parameters[0] + output_unit * factor;
            break :blk makeMappingV1(
                plan.operation,
                output_unit,
                source_first,
                factor,
                source_first * 4,
                factor * 4,
                output_unit * 2,
                2,
                fixture.start_ticks + source_first,
                fixture.start_ticks + source_first + factor,
                output_unit,
                output_unit + 1,
                plan.decode_receipt_sha256,
            );
        },
        .video_keyframe_select => blk: {
            const frame_bytes =
                plan.source_axes[0] * plan.source_axes[1];
            const source_frame =
                plan.parameters[@as(usize, @intCast(output_unit)) + 1];
            const source_offset = source_frame * frame_bytes;
            break :blk makeMappingV1(
                plan.operation,
                output_unit,
                source_frame,
                1,
                source_offset,
                frame_bytes,
                output_unit * frame_bytes,
                frame_bytes,
                fixture.start_ticks + source_frame,
                fixture.start_ticks + source_frame + 1,
                output_unit,
                output_unit + 1,
                plan.decode_receipt_sha256,
            );
        },
    };
}

fn expectedOutputUnitV1(
    plan: TransformPlanV1,
    fixture: fixture_api.ParsedFixtureV1,
    output_unit: u64,
    output: []const u8,
) Error!bool {
    const mapping = try expectedMappingV1(
        plan,
        fixture,
        output_unit,
    );
    const source_offset: usize = std.math.cast(
        usize,
        mapping.source_byte_offset,
    ) orelse return Error.InvalidReceipt;
    const source_bytes: usize = std.math.cast(
        usize,
        mapping.source_bytes,
    ) orelse return Error.InvalidReceipt;
    const output_offset: usize = std.math.cast(
        usize,
        mapping.output_byte_offset,
    ) orelse return Error.InvalidReceipt;
    const output_bytes: usize = std.math.cast(
        usize,
        mapping.output_bytes,
    ) orelse return Error.InvalidReceipt;
    const source_end = std.math.add(
        usize,
        source_offset,
        source_bytes,
    ) catch return Error.InvalidReceipt;
    const output_end = std.math.add(
        usize,
        output_offset,
        output_bytes,
    ) catch return Error.InvalidReceipt;
    if (source_end > fixture.payload.len or output_end > output.len)
        return Error.InvalidReceipt;
    return switch (plan.operation) {
        .image_crop_nearest_tile => std.mem.eql(
            u8,
            fixture.payload[source_offset..source_end],
            output[output_offset..output_end],
        ),
        .audio_mix_decimate => blk: {
            const left_weight: i64 = @intCast(plan.parameters[2]);
            const right_weight: i64 = @intCast(plan.parameters[3]);
            const denominator: i64 = @intCast(plan.parameters[4]);
            const factor = plan.parameters[5];
            const divisor = denominator * @as(i64, @intCast(factor));
            var sum: i64 = 0;
            for (0..factor) |raw_frame| {
                const frame = mapping.source_first_unit + raw_frame;
                const offset: usize = @intCast(frame * 4);
                const left = std.mem.readInt(
                    i16,
                    fixture.payload[offset .. offset + 2][0..2],
                    .little,
                );
                const right = std.mem.readInt(
                    i16,
                    fixture.payload[offset + 2 .. offset + 4][0..2],
                    .little,
                );
                sum += @as(i64, left) * left_weight +
                    @as(i64, right) * right_weight;
            }
            const expected_sample: i16 = @intCast(
                @divTrunc(sum, divisor),
            );
            const actual_sample = std.mem.readInt(
                i16,
                output[output_offset..output_end][0..2],
                .little,
            );
            break :blk actual_sample == expected_sample;
        },
        .video_keyframe_select => blk: {
            const bit = @as(u64, 1) <<
                @intCast(mapping.source_first_unit);
            if (fixture.keyframe_bits & bit == 0)
                break :blk false;
            break :blk std.mem.eql(
                u8,
                fixture.payload[source_offset..source_end],
                output[output_offset..output_end],
            );
        },
    };
}

fn mappingRootV1(
    mapping: TransformMappingV1,
    decode_receipt_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(mapping_domain);
    hash.update(&decode_receipt_sha256);
    hashU64(&hash, @intFromEnum(mapping.operation));
    hashU64(&hash, mapping.output_unit);
    hashU64(&hash, mapping.source_first_unit);
    hashU64(&hash, mapping.source_unit_count);
    hashU64(&hash, mapping.source_byte_offset);
    hashU64(&hash, mapping.source_bytes);
    hashU64(&hash, mapping.output_byte_offset);
    hashU64(&hash, mapping.output_bytes);
    hashU64(&hash, mapping.source_start_tick);
    hashU64(&hash, mapping.source_end_tick);
    hashU64(&hash, mapping.target_start_tick);
    hashU64(&hash, mapping.target_end_tick);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn mappingChainRootV1(
    transform_plan_sha256: Digest,
    mappings: []const TransformMappingV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(mapping_chain_domain);
    hash.update(&transform_plan_sha256);
    hashU64(&hash, mappings.len);
    for (mappings) |mapping|
        hash.update(&mapping.mapping_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn isStaticBase(base: media.TimeBaseV1) bool {
    return base.numerator == 0 and base.denominator == 1;
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

const TestContext = struct {
    encoded_fixture: []const u8,
    fixture: fixture_api.ParsedFixtureV1,
    encoded_decode_plan: []const u8,
    decode_receipt: fixture_api.DecodeReceiptV1,
};

fn prepareTestContext(
    spec: fixture_api.FixtureSpecV1,
    fixture_storage: *[fixture_api.maximum_fixture_bytes]u8,
    decode_plan_storage: *[decode_plan.plan_bytes]u8,
    decoded_source: *[fixture_api.maximum_payload_bytes]u8,
) !TestContext {
    const encoded_fixture = try fixture_api.encodeFixtureV1(
        spec,
        fixture_storage,
    );
    const fixture = try fixture_api.parseFixtureV1(encoded_fixture);
    const plan = try fixture_api.makeDecodePlanV1(
        fixture,
        [_]u8{0xd1} ** 32,
        [_]u8{0xe1} ** 32,
    );
    const encoded_decode_plan = try decode_plan.encodePlanV1(
        plan,
        decode_plan_storage,
    );
    const receipt = try fixture_api.decodeFixtureV1(
        encoded_fixture,
        encoded_decode_plan,
        decoded_source,
    );
    return .{
        .encoded_fixture = encoded_fixture,
        .fixture = fixture,
        .encoded_decode_plan = encoded_decode_plan,
        .decode_receipt = receipt,
    };
}

test "image crop nearest resize and tile mappings are exact" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        fixture_api.imageSpecV1(),
        &fixture_storage,
        &decode_plan_storage,
        &decoded,
    );
    const plan = try makeImagePlanV1(
        context.fixture,
        context.decode_receipt,
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
    );
    var transform_storage: [transform_plan_bytes]u8 = undefined;
    const encoded_transform = try encodeTransformPlanV1(
        plan,
        &transform_storage,
    );
    var decoded_again: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [12]u8 = undefined;
    var mappings: [4]TransformMappingV1 = undefined;
    const receipt = try executeV1(
        context.encoded_fixture,
        context.encoded_decode_plan,
        encoded_transform,
        &decoded_again,
        &output,
        &mappings,
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{
            0,   255, 0,   0,   255, 0,
            255, 255, 255, 255, 255, 255,
        },
        &output,
    );
    try std.testing.expectEqual(@as(u64, 4), receipt.logical_units);
    try std.testing.expectEqual(@as(u64, 1), mappings[0].source_first_unit);
    try std.testing.expectEqual(@as(u64, 1), mappings[1].source_first_unit);
    try std.testing.expectEqual(@as(u64, 3), mappings[2].source_first_unit);
    try std.testing.expectEqual(@as(u64, 3), mappings[3].source_first_unit);
    const plan_root = try transformPlanSha256V1(encoded_transform);
    const plan_hex = std.fmt.bytesToHex(plan_root, .lower);
    const receipt_hex = std.fmt.bytesToHex(receipt.receipt_sha256, .lower);
    try std.testing.expectEqualStrings(
        "d2f61e8923d642d9dfd0eb9d69cb9d2203058d02d91a50a3a17ce45f450c0d31",
        &plan_hex,
    );
    try std.testing.expectEqualStrings(
        "97c68e6b178db4e7b807b80e6987186ffa1b4ef856a8b1bbbba03b57d3f35da0",
        &receipt_hex,
    );
    try verifyReceiptV1(
        context.encoded_fixture,
        encoded_transform,
        receipt,
        &output,
        &mappings,
    );
    output[0] ^= 1;
    var forged_receipt = receipt;
    std.crypto.hash.sha2.Sha256.hash(
        &output,
        &forged_receipt.output_sha256,
        .{},
    );
    forged_receipt.receipt_sha256 = transformReceiptRootV1(
        forged_receipt,
    );
    try std.testing.expectError(
        Error.InvalidReceipt,
        verifyReceiptV1(
            context.encoded_fixture,
            encoded_transform,
            forged_receipt,
            &output,
            &mappings,
        ),
    );
}

test "audio channel mix and exact decimation bind source ranges" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        fixture_api.audioSpecV1(),
        &fixture_storage,
        &decode_plan_storage,
        &decoded,
    );
    const plan = try makeAudioPlanV1(
        context.fixture,
        context.decode_receipt,
        0,
        6,
        16_000,
        1,
        0,
        1,
        [_]u8{0xf1} ** 32,
        [_]u8{0xf2} ** 32,
    );
    var transform_storage: [transform_plan_bytes]u8 = undefined;
    const encoded_transform = try encodeTransformPlanV1(
        plan,
        &transform_storage,
    );
    var decoded_again: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [4]u8 = undefined;
    var mappings: [2]TransformMappingV1 = undefined;
    const receipt = try executeV1(
        context.encoded_fixture,
        context.encoded_decode_plan,
        encoded_transform,
        &decoded_again,
        &output,
        &mappings,
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x00, 0xc0, 0x55, 0x15 },
        &output,
    );
    try std.testing.expectEqual(@as(u64, 2), receipt.logical_units);
    try std.testing.expectEqual(@as(u64, 3), mappings[0].source_unit_count);
    try std.testing.expectEqual(@as(u64, 12), mappings[0].source_bytes);
    try std.testing.expectEqual(@as(u64, 3), mappings[1].source_first_unit);
    const plan_root = try transformPlanSha256V1(encoded_transform);
    const plan_hex = std.fmt.bytesToHex(plan_root, .lower);
    const receipt_hex = std.fmt.bytesToHex(receipt.receipt_sha256, .lower);
    try std.testing.expectEqualStrings(
        "202ed6b0ed607614ebe335d7a4d1f51c98c094bb04254a8f5e68912b9fca60ba",
        &plan_hex,
    );
    try std.testing.expectEqualStrings(
        "02f9d7547a276339cb62666adcbb5568f8ae23e4f855e0f7966d2616a8e8adc3",
        &receipt_hex,
    );
}

test "video keyframe selection binds exact frame and timeline" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        fixture_api.videoSpecV1(),
        &fixture_storage,
        &decode_plan_storage,
        &decoded,
    );
    const selected = [_]u64{1};
    const plan = try makeVideoPlanV1(
        context.fixture,
        context.decode_receipt,
        &selected,
        [_]u8{0xf1} ** 32,
        [_]u8{0xf2} ** 32,
    );
    var transform_storage: [transform_plan_bytes]u8 = undefined;
    const encoded_transform = try encodeTransformPlanV1(
        plan,
        &transform_storage,
    );
    var decoded_again: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [4]u8 = undefined;
    var mappings: [1]TransformMappingV1 = undefined;
    const receipt = try executeV1(
        context.encoded_fixture,
        context.encoded_decode_plan,
        encoded_transform,
        &decoded_again,
        &output,
        &mappings,
    );
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 255, 128, 64, 0 },
        &output,
    );
    try std.testing.expectEqual(@as(u64, 1), receipt.logical_units);
    try std.testing.expectEqual(@as(u64, 1), mappings[0].source_first_unit);
    try std.testing.expectEqual(@as(u64, 1), mappings[0].source_start_tick);
    try std.testing.expectEqual(@as(u64, 2), mappings[0].source_end_tick);
    const plan_root = try transformPlanSha256V1(encoded_transform);
    const plan_hex = std.fmt.bytesToHex(plan_root, .lower);
    const receipt_hex = std.fmt.bytesToHex(receipt.receipt_sha256, .lower);
    try std.testing.expectEqualStrings(
        "9f64b26c5e926893649bfc6f0c09bd16563c3d500bebc8cd54440422303e6662",
        &plan_hex,
    );
    try std.testing.expectEqualStrings(
        "9e9fcce71a4419697d2affc2ca6fbe0f5e4161b5e31f23c3ddee90ba4a4bb1bb",
        &receipt_hex,
    );
}

test "transform plan rejects every mutation and rehashed contradiction" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        fixture_api.imageSpecV1(),
        &fixture_storage,
        &decode_plan_storage,
        &decoded,
    );
    const plan = try makeImagePlanV1(
        context.fixture,
        context.decode_receipt,
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
    );
    var storage: [transform_plan_bytes]u8 = undefined;
    const encoded = try encodeTransformPlanV1(plan, &storage);
    var corrupted: [transform_plan_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodeTransformPlanV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    @memcpy(&corrupted, encoded);
    writeU64(&corrupted, 176, 2);
    const rerooted = transformPlanRootV1(
        corrupted[0..transform_plan_body_bytes],
    );
    @memcpy(corrupted[transform_plan_body_bytes..], &rerooted);
    try std.testing.expectError(
        Error.InvalidPlan,
        decodeTransformPlanV1(&corrupted),
    );
}

test "transform executor rejects stale roots capacity and overlap" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 = undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        fixture_api.videoSpecV1(),
        &fixture_storage,
        &decode_plan_storage,
        &decoded,
    );
    const selected = [_]u64{1};
    var plan = try makeVideoPlanV1(
        context.fixture,
        context.decode_receipt,
        &selected,
        [_]u8{0xf1} ** 32,
        [_]u8{0xf2} ** 32,
    );
    plan.decode_receipt_sha256[0] ^= 1;
    var transform_storage: [transform_plan_bytes]u8 = undefined;
    const stale_encoded = try encodeTransformPlanV1(
        plan,
        &transform_storage,
    );
    var decoded_again: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output = [_]u8{0x5a} ** 4;
    var mappings: [1]TransformMappingV1 = undefined;
    try std.testing.expectError(
        Error.InvalidPlan,
        executeV1(
            context.encoded_fixture,
            context.encoded_decode_plan,
            stale_encoded,
            &decoded_again,
            &output,
            &mappings,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0x5a));

    plan.decode_receipt_sha256 = context.decode_receipt.receipt_sha256;
    const valid_encoded = try encodeTransformPlanV1(
        plan,
        &transform_storage,
    );
    var short_output = [_]u8{0x5a} ** 3;
    try std.testing.expectError(
        Error.BufferTooSmall,
        executeV1(
            context.encoded_fixture,
            context.encoded_decode_plan,
            valid_encoded,
            &decoded_again,
            &short_output,
            &mappings,
        ),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short_output, 0x5a));
    try std.testing.expectError(
        Error.UnsafeDestination,
        executeV1(
            context.encoded_fixture,
            context.encoded_decode_plan,
            valid_encoded,
            &decoded_again,
            decoded_again[0..4],
            &mappings,
        ),
    );
}
