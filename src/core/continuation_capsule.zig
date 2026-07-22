//! Proof-carrying continuation manifest for one committed AI checkpoint.
//!
//! The fixed-size wire binds nine typed external objects without copying their
//! payloads. Verification receives the expected scalar identity and exact
//! object bytes, recomputes every domain-separated reference, and rejects any
//! substitution. The manifest grants no model, allocator, scheduler, file, or
//! output authority; a resolver must supply those capabilities separately.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;
pub const wire_abi: u64 = 0x4743_4341_0000_0001;
pub const magic = [_]u8{ 'G', 'C', 'C', 'A', 'P', 'V', '0', '1' };
pub const flag_require_all_objects: u32 = 1 << 0;
pub const allowed_flags: u32 = flag_require_all_objects;

const object_domain = "glacier-continuation-object-v1\x00";
const envelope_domain = "glacier-continuation-capsule-wire-v1\x00";
const digest_bytes = @sizeOf(Digest);

pub const ObjectKind = enum(u64) {
    model = 0,
    tokenizer = 1,
    execution_plan = 2,
    resource_state = 3,
    lane_state = 4,
    kv_state = 5,
    sampler_state = 6,
    output_state = 7,
    publication_receipt = 8,
};

pub const object_kinds = [_]ObjectKind{
    .model,
    .tokenizer,
    .execution_plan,
    .resource_state,
    .lane_state,
    .kv_state,
    .sampler_state,
    .output_state,
    .publication_receipt,
};

pub const object_count: usize = object_kinds.len;
pub const header_bytes: usize =
    magic.len + 8 + 8 + 4 + 4 + 6 * 8 + 2 * digest_bytes;
pub const object_ref_bytes: usize = 8 + 8 + digest_bytes;
pub const encoded_bytes: usize =
    header_bytes + object_count * object_ref_bytes + digest_bytes;

pub const Error = error{
    CapacityExceeded,
    InvalidStorage,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidManifest,
    InvalidObject,
    InvalidEnvelope,
    InvalidComposition,
};

pub const ObjectV1 = struct {
    abi_version: u64,
    bytes: []const u8,
};

pub const ObjectsV1 = struct {
    model: ObjectV1,
    tokenizer: ObjectV1,
    execution_plan: ObjectV1,
    resource_state: ObjectV1,
    lane_state: ObjectV1,
    kv_state: ObjectV1,
    sampler_state: ObjectV1,
    output_state: ObjectV1,
    publication_receipt: ObjectV1,

    pub fn get(self: ObjectsV1, kind: ObjectKind) ObjectV1 {
        return switch (kind) {
            .model => self.model,
            .tokenizer => self.tokenizer,
            .execution_plan => self.execution_plan,
            .resource_state => self.resource_state,
            .lane_state => self.lane_state,
            .kv_state => self.kv_state,
            .sampler_state => self.sampler_state,
            .output_state => self.output_state,
            .publication_receipt => self.publication_receipt,
        };
    }
};

pub const ConfigV1 = struct {
    execution_abi: u64,
    request_epoch: u64,
    publication_sequence: u64,
    checkpoint_generation: u64,
    kv_tokens: u64,
    output_tokens: u64,
    challenge_sha256: Digest,
    parent_capsule_sha256: Digest = zero_digest,
};

pub const ObjectRefV1 = struct {
    abi_version: u64,
    byte_length: u64,
    sha256: Digest,
};

pub const DecodedV1 = struct {
    config: ConfigV1,
    refs: [object_count]ObjectRefV1,
    envelope_sha256: Digest,

    pub fn ref(self: DecodedV1, kind: ObjectKind) ObjectRefV1 {
        return self.refs[@intCast(@intFromEnum(kind))];
    }
};

pub fn encodeV1(
    config: ConfigV1,
    objects: ObjectsV1,
    destination: []u8,
) Error![]const u8 {
    if (destination.len < encoded_bytes) return Error.CapacityExceeded;
    const output = destination[0..encoded_bytes];
    try validateConfig(config);
    for (object_kinds) |kind| {
        const object = objects.get(kind);
        try validateObject(object);
        if (slicesOverlap(output, object.bytes))
            return Error.InvalidStorage;
    }

    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(encoded_bytes);
    try writer.writeU32(flag_require_all_objects);
    try writer.writeU32(0);
    try writer.writeU64(config.execution_abi);
    try writer.writeU64(config.request_epoch);
    try writer.writeU64(config.publication_sequence);
    try writer.writeU64(config.checkpoint_generation);
    try writer.writeU64(config.kv_tokens);
    try writer.writeU64(config.output_tokens);
    try writer.writeDigest(config.challenge_sha256);
    try writer.writeDigest(config.parent_capsule_sha256);

    for (object_kinds) |kind| {
        const object_ref = try objectRefV1(kind, objects.get(kind));
        try writer.writeU64(object_ref.abi_version);
        try writer.writeU64(object_ref.byte_length);
        try writer.writeDigest(object_ref.sha256);
    }
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    try writer.writeDigest(envelopeSha256(output[0..writer.position]));
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

/// Parse and validate the self-contained manifest envelope.
///
/// This does not verify external object payloads. Use `decodeAndVerifyV1` at a
/// resume/admission boundary before granting any authority.
pub fn decodeManifestV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded_bytes) return Error.InvalidLength;
    if (try reader.readU32() != flag_require_all_objects or
        try reader.readU32() != 0)
        return Error.InvalidFlags;

    const config: ConfigV1 = .{
        .execution_abi = try reader.readU64(),
        .request_epoch = try reader.readU64(),
        .publication_sequence = try reader.readU64(),
        .checkpoint_generation = try reader.readU64(),
        .kv_tokens = try reader.readU64(),
        .output_tokens = try reader.readU64(),
        .challenge_sha256 = try reader.readDigest(),
        .parent_capsule_sha256 = try reader.readDigest(),
    };
    try validateConfig(config);

    var refs: [object_count]ObjectRefV1 = undefined;
    for (&refs) |*object_ref| {
        object_ref.* = .{
            .abi_version = try reader.readU64(),
            .byte_length = try reader.readU64(),
            .sha256 = try reader.readDigest(),
        };
        try validateRef(object_ref.*);
    }
    const envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &envelope_sha256,
        &envelopeSha256(encoded[0 .. encoded.len - digest_bytes]),
    )) return Error.InvalidEnvelope;
    return .{
        .config = config,
        .refs = refs,
        .envelope_sha256 = envelope_sha256,
    };
}

/// Verify the exact scalar identity and every typed external object.
pub fn decodeAndVerifyV1(
    encoded: []const u8,
    expected_config: ConfigV1,
    objects: ObjectsV1,
) Error!DecodedV1 {
    const decoded = try decodeManifestV1(encoded);
    if (!std.meta.eql(decoded.config, expected_config))
        return Error.InvalidComposition;
    for (object_kinds) |kind| {
        try validateObject(objects.get(kind));
        if (slicesOverlap(encoded, objects.get(kind).bytes))
            return Error.InvalidStorage;
    }

    var expected_storage: [encoded_bytes]u8 = undefined;
    const expected = try encodeV1(
        expected_config,
        objects,
        &expected_storage,
    );
    if (!std.mem.eql(u8, encoded, expected))
        return Error.InvalidComposition;
    return decoded;
}

pub fn objectRefV1(
    kind: ObjectKind,
    object: ObjectV1,
) Error!ObjectRefV1 {
    try validateObject(object);
    const byte_length = std.math.cast(u64, object.bytes.len) orelse
        return Error.InvalidObject;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(object_domain);
    hashU64(&hash, @intFromEnum(kind));
    hashU64(&hash, object.abi_version);
    hashU64(&hash, byte_length);
    hash.update(object.bytes);
    var sha256: Digest = undefined;
    hash.final(&sha256);
    return .{
        .abi_version = object.abi_version,
        .byte_length = byte_length,
        .sha256 = sha256,
    };
}

pub fn envelopeRootV1(encoded: []const u8) Error!Digest {
    return (try decodeManifestV1(encoded)).envelope_sha256;
}

fn validateConfig(config: ConfigV1) Error!void {
    if (config.execution_abi == 0 or
        config.request_epoch == 0 or
        config.publication_sequence == 0 or
        config.kv_tokens == 0 or
        config.output_tokens == 0 or
        config.output_tokens > config.kv_tokens or
        isZero(config.challenge_sha256))
        return Error.InvalidManifest;
    const has_parent = !isZero(config.parent_capsule_sha256);
    if ((config.checkpoint_generation == 0 and has_parent) or
        (config.checkpoint_generation != 0 and !has_parent))
        return Error.InvalidManifest;
}

fn validateObject(object: ObjectV1) Error!void {
    if (object.abi_version == 0 or object.bytes.len == 0)
        return Error.InvalidObject;
    _ = std.math.cast(u64, object.bytes.len) orelse
        return Error.InvalidObject;
}

fn validateRef(object_ref: ObjectRefV1) Error!void {
    if (object_ref.abi_version == 0 or
        object_ref.byte_length == 0 or
        isZero(object_ref.sha256))
        return Error.InvalidObject;
}

fn envelopeSha256(prefix: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(envelope_domain);
    hash.update(prefix);
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = a_start + a.len;
    const b_end = b_start + b.len;
    return a_start < b_end and b_start < a_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        if (self.position > self.bytes.len or
            value.len > self.bytes.len - self.position)
            return Error.InvalidLength;
        @memcpy(self.bytes[self.position .. self.position + value.len], value);
        self.position += value.len;
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        if (self.position > self.bytes.len or
            length > self.bytes.len - self.position)
            return Error.InvalidLength;
        const value = self.bytes[self.position .. self.position + length];
        self.position += length;
        return value;
    }

    fn readU32(self: *Reader) Error!u32 {
        var bytes: [4]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(4));
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        var bytes: [8]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(8));
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(digest_bytes));
        return value;
    }
};

fn demoConfig() ConfigV1 {
    return .{
        .execution_abi = 0x4341_4558_0000_0001,
        .request_epoch = 0x4341_5251_0000_0001,
        .publication_sequence = 3,
        .checkpoint_generation = 0,
        .kv_tokens = 35,
        .output_tokens = 3,
        .challenge_sha256 = [_]u8{0xa7} ** 32,
    };
}

fn demoObjects() ObjectsV1 {
    return .{
        .model = .{ .abi_version = 0x4341_4d4f_0000_0001, .bytes = "model-v1:sha256:demo-glrt" },
        .tokenizer = .{ .abi_version = 0x4341_544b_0000_0001, .bytes = "tokenizer-v1:demo-qwen" },
        .execution_plan = .{ .abi_version = 0x4341_504c_0000_0001, .bytes = "plan-v1:cpu:threads=4:strict" },
        .resource_state = .{ .abi_version = 0x4341_5253_0000_0001, .bytes = "resource-v1:bank=17:kv=4096:output=64" },
        .lane_state = .{ .abi_version = 0x4341_4c4e_0000_0001, .bytes = "lane-v1:request=41:service=9" },
        .kv_state = .{ .abi_version = 0x4341_4b56_0000_0001, .bytes = "kv-v1:positions=35:root=demo" },
        .sampler_state = .{ .abi_version = 0x4341_534d_0000_0001, .bytes = "sampler-v1:rng=01020304:calls=3" },
        .output_state = .{ .abi_version = 0x4341_4f55_0000_0001, .bytes = "output-v1:tokens=901,902,903" },
        .publication_receipt = .{ .abi_version = 0x4341_5052_0000_0001, .bytes = "publication-v1:sequence=3:commit=demo" },
    };
}

test "continuation capsule layout is fixed" {
    try std.testing.expectEqual(@as(usize, 144), header_bytes);
    try std.testing.expectEqual(@as(usize, 48), object_ref_bytes);
    try std.testing.expectEqual(@as(usize, 9), object_count);
    try std.testing.expectEqual(@as(usize, 608), encoded_bytes);
}

test "continuation capsule verifies exact typed objects" {
    const config = demoConfig();
    const objects = demoObjects();
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(config, objects, &storage);
    const decoded = try decodeAndVerifyV1(encoded, config, objects);
    try std.testing.expectEqual(config, decoded.config);
    try std.testing.expectEqual(
        @as(u64, objects.kv_state.bytes.len),
        decoded.ref(.kv_state).byte_length,
    );
    try std.testing.expect(!isZero(decoded.envelope_sha256));
}

test "continuation capsule rejects every manifest mutation" {
    const config = demoConfig();
    const objects = demoObjects();
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(config, objects, &storage);
    var mutated: [encoded_bytes]u8 = undefined;
    for (0..encoded.len) |offset| {
        @memcpy(&mutated, encoded);
        mutated[offset] ^= 1;
        if (offset < encoded.len - digest_bytes) {
            const resealed = envelopeSha256(
                mutated[0 .. encoded.len - digest_bytes],
            );
            @memcpy(mutated[encoded.len - digest_bytes ..], &resealed);
        }
        if (decodeAndVerifyV1(&mutated, config, objects)) |_| {
            return error.ExpectedMutationRejection;
        } else |_| {}
    }
}

test "continuation capsule rejects valid foreign object substitution" {
    const config = demoConfig();
    const objects = demoObjects();
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(config, objects, &storage);
    var foreign = objects;
    foreign.kv_state = .{
        .abi_version = objects.kv_state.abi_version,
        .bytes = "kv-v1:positions=35:root=foreign",
    };
    try std.testing.expectError(
        Error.InvalidComposition,
        decodeAndVerifyV1(encoded, config, foreign),
    );
}

test "continuation capsule parent chain and storage fail closed" {
    const objects = demoObjects();
    var storage: [encoded_bytes]u8 = undefined;
    const first = try encodeV1(demoConfig(), objects, &storage);
    const parent = try envelopeRootV1(first);
    var resumed = demoConfig();
    resumed.publication_sequence = 4;
    resumed.checkpoint_generation = 1;
    resumed.kv_tokens = 36;
    resumed.output_tokens = 4;
    resumed.parent_capsule_sha256 = parent;
    var resumed_storage: [encoded_bytes]u8 = undefined;
    _ = try encodeV1(resumed, objects, &resumed_storage);

    var invalid = resumed;
    invalid.parent_capsule_sha256 = zero_digest;
    try std.testing.expectError(
        Error.InvalidManifest,
        encodeV1(invalid, objects, &resumed_storage),
    );

    var aliased = objects;
    aliased.model = .{
        .abi_version = objects.model.abi_version,
        .bytes = resumed_storage[0..16],
    };
    try std.testing.expectError(
        Error.InvalidStorage,
        encodeV1(resumed, aliased, &resumed_storage),
    );
}
