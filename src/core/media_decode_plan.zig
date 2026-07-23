//! Sealed, pointer-free media decode plans shared by image, audio, and video.

const std = @import("std");
const media = @import("media_contract.zig");

pub const Digest = media.Digest;
pub const plan_abi: u64 = 0x474d_4450_0000_0001;
pub const plan_magic = [_]u8{
    'G', 'M', 'D', 'P', 'L', 'N', '1', 0,
};
pub const plan_bytes: usize = 416;
pub const plan_body_bytes: usize = plan_bytes - 32;
pub const allowed_flags: u64 = 0;
pub const allowed_capabilities: u64 = 0x7;

const plan_domain = "glacier-media-decode-plan-v1\x00";

pub const Error = error{
    BufferTooSmall,
    InvalidMediaObject,
    InvalidPlan,
};

pub const ExecutionModeV1 = enum(u64) {
    deterministic = 1,
    quality = 2,
};

pub const NumericalPolicyV1 = enum(u64) {
    exact_integer = 1,
    strict_float = 2,
};

pub const RejectionPolicyV1 = enum(u64) {
    fail_closed = 1,
};

pub const DecodePlanV1 = struct {
    kind: media.MediaKindV1,
    decoder_abi: u64,
    source_container_id: u64,
    source_codec_id: u64,
    destination_representation_id: u64,
    execution_mode: ExecutionModeV1,
    numerical_policy: NumericalPolicyV1,
    rejection_policy: RejectionPolicyV1,
    required_capabilities: u64,
    source_bytes: u64,
    output_bytes: u64,
    scratch_bytes: u64,
    logical_units: u64,
    source_axes: [3]u64,
    target_axes: [3]u64,
    source_time_base: media.TimeBaseV1,
    target_time_base: media.TimeBaseV1,
    media_object_sha256: Digest,
    decoder_implementation_sha256: Digest,
    transform_policy_sha256: Digest,
    resource_policy_sha256: Digest,
    challenge_sha256: Digest,
};

pub fn encodePlanV1(
    plan: DecodePlanV1,
    destination: []u8,
) Error![]const u8 {
    try validatePlanV1(plan);
    if (destination.len < plan_bytes) return Error.BufferTooSmall;
    const output = destination[0..plan_bytes];
    @memset(output, 0);
    @memcpy(output[0..8], &plan_magic);
    writeU64(output, 8, plan_abi);
    writeU64(output, 16, plan_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(plan.kind));
    writeU64(output, 40, plan.decoder_abi);
    writeU64(output, 48, plan.source_container_id);
    writeU64(output, 56, plan.source_codec_id);
    writeU64(output, 64, plan.destination_representation_id);
    writeU64(output, 72, @intFromEnum(plan.execution_mode));
    writeU64(output, 80, @intFromEnum(plan.numerical_policy));
    writeU64(output, 88, @intFromEnum(plan.rejection_policy));
    writeU64(output, 96, plan.required_capabilities);
    writeU64(output, 104, plan.source_bytes);
    writeU64(output, 112, plan.output_bytes);
    writeU64(output, 120, plan.scratch_bytes);
    writeU64(output, 128, plan.logical_units);
    for (plan.source_axes, 0..) |axis, index|
        writeU64(output, 136 + index * 8, axis);
    for (plan.target_axes, 0..) |axis, index|
        writeU64(output, 160 + index * 8, axis);
    writeU64(output, 184, plan.source_time_base.numerator);
    writeU64(output, 192, plan.source_time_base.denominator);
    writeU64(output, 200, plan.target_time_base.numerator);
    writeU64(output, 208, plan.target_time_base.denominator);
    @memcpy(output[216..248], &plan.media_object_sha256);
    @memcpy(
        output[248..280],
        &plan.decoder_implementation_sha256,
    );
    @memcpy(output[280..312], &plan.transform_policy_sha256);
    @memcpy(output[312..344], &plan.resource_policy_sha256);
    @memcpy(output[344..376], &plan.challenge_sha256);
    const root = planRootV1(output[0..plan_body_bytes]);
    @memcpy(output[plan_body_bytes..], &root);
    return output;
}

pub fn decodePlanV1(encoded: []const u8) Error!DecodePlanV1 {
    if (encoded.len != plan_bytes or
        !std.mem.eql(u8, encoded[0..8], &plan_magic) or
        readU64(encoded, 8) != plan_abi or
        readU64(encoded, 16) != plan_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 376) != 0)
        return Error.InvalidPlan;
    var footer: Digest = undefined;
    @memcpy(&footer, encoded[plan_body_bytes..]);
    if (!std.mem.eql(
        u8,
        &footer,
        &planRootV1(encoded[0..plan_body_bytes]),
    )) return Error.InvalidPlan;

    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidPlan;
    const execution_mode = std.meta.intToEnum(
        ExecutionModeV1,
        readU64(encoded, 72),
    ) catch return Error.InvalidPlan;
    const numerical_policy = std.meta.intToEnum(
        NumericalPolicyV1,
        readU64(encoded, 80),
    ) catch return Error.InvalidPlan;
    const rejection_policy = std.meta.intToEnum(
        RejectionPolicyV1,
        readU64(encoded, 88),
    ) catch return Error.InvalidPlan;
    var plan: DecodePlanV1 = .{
        .kind = kind,
        .decoder_abi = readU64(encoded, 40),
        .source_container_id = readU64(encoded, 48),
        .source_codec_id = readU64(encoded, 56),
        .destination_representation_id = readU64(encoded, 64),
        .execution_mode = execution_mode,
        .numerical_policy = numerical_policy,
        .rejection_policy = rejection_policy,
        .required_capabilities = readU64(encoded, 96),
        .source_bytes = readU64(encoded, 104),
        .output_bytes = readU64(encoded, 112),
        .scratch_bytes = readU64(encoded, 120),
        .logical_units = readU64(encoded, 128),
        .source_axes = .{
            readU64(encoded, 136),
            readU64(encoded, 144),
            readU64(encoded, 152),
        },
        .target_axes = .{
            readU64(encoded, 160),
            readU64(encoded, 168),
            readU64(encoded, 176),
        },
        .source_time_base = .{
            .numerator = readU64(encoded, 184),
            .denominator = readU64(encoded, 192),
        },
        .target_time_base = .{
            .numerator = readU64(encoded, 200),
            .denominator = readU64(encoded, 208),
        },
        .media_object_sha256 = undefined,
        .decoder_implementation_sha256 = undefined,
        .transform_policy_sha256 = undefined,
        .resource_policy_sha256 = undefined,
        .challenge_sha256 = undefined,
    };
    @memcpy(&plan.media_object_sha256, encoded[216..248]);
    @memcpy(
        &plan.decoder_implementation_sha256,
        encoded[248..280],
    );
    @memcpy(&plan.transform_policy_sha256, encoded[280..312]);
    @memcpy(&plan.resource_policy_sha256, encoded[312..344]);
    @memcpy(&plan.challenge_sha256, encoded[344..376]);
    try validatePlanV1(plan);
    return plan;
}

pub fn planSha256V1(encoded: []const u8) Error!Digest {
    _ = try decodePlanV1(encoded);
    var root: Digest = undefined;
    @memcpy(&root, encoded[plan_body_bytes..]);
    return root;
}

pub fn validatePlanV1(plan: DecodePlanV1) Error!void {
    if (plan.decoder_abi == 0 or
        plan.source_container_id == 0 or
        plan.source_codec_id == 0 or
        plan.destination_representation_id == 0 or
        plan.source_bytes == 0 or
        plan.output_bytes == 0 or
        plan.logical_units == 0 or
        plan.required_capabilities & ~allowed_capabilities != 0 or
        plan.rejection_policy != .fail_closed or
        isZero(plan.media_object_sha256) or
        isZero(plan.decoder_implementation_sha256) or
        isZero(plan.transform_policy_sha256) or
        isZero(plan.resource_policy_sha256) or
        isZero(plan.challenge_sha256))
        return Error.InvalidPlan;
    for (plan.source_axes) |axis|
        if (axis == 0) return Error.InvalidPlan;
    for (plan.target_axes) |axis|
        if (axis == 0) return Error.InvalidPlan;
    switch (plan.kind) {
        .image => {
            if (!isStaticBase(plan.source_time_base) or
                !isStaticBase(plan.target_time_base))
                return Error.InvalidPlan;
        },
        .audio, .video => {
            media.validateTimeBaseV1(
                plan.source_time_base,
            ) catch return Error.InvalidPlan;
            media.validateTimeBaseV1(
                plan.target_time_base,
            ) catch return Error.InvalidPlan;
        },
    }
}

pub fn validateForMediaObjectV1(
    plan: DecodePlanV1,
    object: media.MediaObjectV1,
    object_sha256: Digest,
) Error!void {
    try validatePlanV1(plan);
    var storage: [media.descriptor_bytes]u8 = undefined;
    const encoded_object = media.encodeMediaObjectV1(
        object,
        &storage,
    ) catch return Error.InvalidMediaObject;
    const computed_object_sha256 = media.mediaObjectSha256V1(
        encoded_object,
    ) catch return Error.InvalidMediaObject;
    if (!std.mem.eql(
        u8,
        &computed_object_sha256,
        &object_sha256,
    ) or
        !std.mem.eql(
            u8,
            &plan.media_object_sha256,
            &object_sha256,
        ) or
        plan.kind != object.kind or
        plan.source_bytes != object.byte_length or
        plan.source_container_id != object.container_id or
        plan.source_codec_id != object.codec_id or
        !std.meta.eql(plan.source_axes, object.axes) or
        !std.meta.eql(plan.source_time_base, object.time_base))
        return Error.InvalidMediaObject;
}

pub fn planRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn isStaticBase(base: media.TimeBaseV1) bool {
    return base.numerator == 0 and base.denominator == 1;
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

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn fixtureObject() media.MediaObjectV1 {
    return .{
        .kind = .audio,
        .semantic_abi = 2,
        .byte_length = 32,
        .container_id = 0x474d_5446_0000_0001,
        .codec_id = 2,
        .axes = .{ 8, 2, 48_000 },
        .time_base = .{ .numerator = 1, .denominator = 48_000 },
        .tenant_scope_sha256 = [_]u8{0xa2} ** 32,
        .content_sha256 = [_]u8{0xb2} ** 32,
        .metadata_policy_sha256 = [_]u8{0xc2} ** 32,
        .provenance_sha256 = [_]u8{0xd2} ** 32,
    };
}

fn fixtureObjectRoot() !Digest {
    var storage: [media.descriptor_bytes]u8 = undefined;
    const encoded = try media.encodeMediaObjectV1(
        fixtureObject(),
        &storage,
    );
    return media.mediaObjectSha256V1(encoded);
}

fn fixturePlan() !DecodePlanV1 {
    return .{
        .kind = .audio,
        .decoder_abi = 0x474d_5444_0000_0001,
        .source_container_id = 0x474d_5446_0000_0001,
        .source_codec_id = 2,
        .destination_representation_id = 3,
        .execution_mode = .deterministic,
        .numerical_policy = .exact_integer,
        .rejection_policy = .fail_closed,
        .required_capabilities = 0,
        .source_bytes = 32,
        .output_bytes = 32,
        .scratch_bytes = 0,
        .logical_units = 8,
        .source_axes = .{ 8, 2, 48_000 },
        .target_axes = .{ 8, 2, 48_000 },
        .source_time_base = .{
            .numerator = 1,
            .denominator = 48_000,
        },
        .target_time_base = .{
            .numerator = 1,
            .denominator = 48_000,
        },
        .media_object_sha256 = try fixtureObjectRoot(),
        .decoder_implementation_sha256 = [_]u8{0xe1} ** 32,
        .transform_policy_sha256 = [_]u8{0xe2} ** 32,
        .resource_policy_sha256 = [_]u8{0xe3} ** 32,
        .challenge_sha256 = [_]u8{0xe4} ** 32,
    };
}

test "sealed decode plan round trips and binds media object" {
    const plan = try fixturePlan();
    var storage: [plan_bytes]u8 = undefined;
    const encoded = try encodePlanV1(plan, &storage);
    try std.testing.expectEqualDeep(
        plan,
        try decodePlanV1(encoded),
    );
    try validateForMediaObjectV1(
        plan,
        fixtureObject(),
        try fixtureObjectRoot(),
    );

    var foreign = fixtureObject();
    foreign.content_sha256 = [_]u8{0xff} ** 32;
    try std.testing.expectError(
        Error.InvalidMediaObject,
        validateForMediaObjectV1(
            plan,
            foreign,
            try fixtureObjectRoot(),
        ),
    );
}

test "sealed decode plan rejects every mutation and rehashed contradiction" {
    const plan = try fixturePlan();
    var storage: [plan_bytes]u8 = undefined;
    const encoded = try encodePlanV1(plan, &storage);
    var corrupted: [plan_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodePlanV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }

    @memcpy(&corrupted, encoded);
    writeU64(&corrupted, 24, 1);
    const rerooted = planRootV1(
        corrupted[0..plan_body_bytes],
    );
    @memcpy(corrupted[plan_body_bytes..], &rerooted);
    try std.testing.expectError(
        Error.InvalidPlan,
        decodePlanV1(&corrupted),
    );
}

test "sealed decode plan enforces exact size and closed policy" {
    const plan = try fixturePlan();
    var short: [plan_bytes - 1]u8 = undefined;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodePlanV1(plan, &short),
    );

    var open_plan = plan;
    open_plan.required_capabilities = allowed_capabilities + 1;
    try std.testing.expectError(
        Error.InvalidPlan,
        validatePlanV1(open_plan),
    );
}
