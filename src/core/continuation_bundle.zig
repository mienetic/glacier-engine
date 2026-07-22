//! Canonical tenant-scoped bundle manifest for one ContinuationCapsule.
//!
//! The fixed wire binds the capsule and all nine exact external objects while
//! separating semantic typed roots from tenant-bound storage blob roots.
//! Canonical first-occurrence ordinals describe in-tenant deduplication without
//! embedding payloads, opening storage, allocating memory, or granting access.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");

pub const Digest = capsule.Digest;
pub const zero_digest = capsule.zero_digest;
pub const magic = [_]u8{ 'G', 'C', 'B', 'N', 'D', 'V', '0', '1' };
pub const wire_abi: u64 = 0x4743_424e_0000_0001;
pub const flag_require_all_objects: u32 = 1 << 0;
pub const flag_tenant_bound_blobs: u32 = 1 << 1;
pub const flag_canonical_ordinals: u32 = 1 << 2;
pub const required_flags: u32 = flag_require_all_objects |
    flag_tenant_bound_blobs |
    flag_canonical_ordinals;

const blob_domain = "glacier-continuation-bundle-blob-v1\x00";
const envelope_domain = "glacier-continuation-bundle-wire-v1\x00";
const digest_bytes = @sizeOf(Digest);

pub const header_bytes: usize = 240;
pub const entry_bytes: usize = 96;
pub const encoded_bytes: usize =
    header_bytes + capsule.object_count * entry_bytes + digest_bytes;

pub const Error = capsule.Error || error{
    InvalidConfig,
    CapsuleMismatch,
    InvalidEntry,
    InvalidOrdinal,
    InvalidTotals,
    DigestCollision,
    ArithmeticOverflow,
};

pub const ConfigV1 = struct {
    tenant_scope_sha256: Digest,
    capsule_sha256: Digest,
    bundle_generation: u64,
    challenge_sha256: Digest,
    parent_bundle_sha256: Digest = zero_digest,
};

pub const BlobRefV1 = struct {
    byte_length: u64,
    sha256: Digest,
};

pub const EntryV1 = struct {
    kind: capsule.ObjectKind,
    abi_version: u64,
    byte_length: u64,
    blob_ordinal: u64,
    typed_sha256: Digest,
    blob_sha256: Digest,
};

pub const DecodedV1 = struct {
    config: ConfigV1,
    capsule_wire_length: u64,
    capsule_blob_sha256: Digest,
    logical_payload_bytes: u64,
    unique_blob_count: u64,
    unique_blob_bytes: u64,
    entries: [capsule.object_count]EntryV1,
    envelope_sha256: Digest,

    pub fn entry(self: DecodedV1, kind: capsule.ObjectKind) EntryV1 {
        return self.entries[kindIndex(kind)];
    }

    pub fn deduplicatedPayloadBytes(self: DecodedV1) u64 {
        return self.logical_payload_bytes - self.unique_blob_bytes;
    }
};

pub fn encodeV1(
    config: ConfigV1,
    capsule_wire: []const u8,
    objects: capsule.ObjectsV1,
    destination: []u8,
) Error![]const u8 {
    if (destination.len < encoded_bytes) return Error.CapacityExceeded;
    const output = destination[0..encoded_bytes];
    try validateConfig(config);
    if (slicesOverlap(output, capsule_wire)) return Error.InvalidStorage;
    for (capsule.object_kinds) |kind| {
        if (slicesOverlap(output, objects.get(kind).bytes))
            return Error.InvalidStorage;
    }

    const decoded_capsule = capsule.decodeManifestV1(capsule_wire) catch
        return Error.CapsuleMismatch;
    if (!std.mem.eql(
        u8,
        &decoded_capsule.envelope_sha256,
        &config.capsule_sha256,
    )) return Error.CapsuleMismatch;
    _ = capsule.decodeAndVerifyV1(
        capsule_wire,
        decoded_capsule.config,
        objects,
    ) catch return Error.CapsuleMismatch;

    var entries: [capsule.object_count]EntryV1 = undefined;
    var logical_payload_bytes: u64 = 0;
    var unique_blob_count: u64 = 0;
    var unique_blob_bytes: u64 = 0;
    for (capsule.object_kinds, 0..) |kind, index| {
        const object = objects.get(kind);
        const typed_ref = capsule.objectRefV1(kind, object) catch
            return Error.InvalidEntry;
        const blob_ref = try blobRefV1(
            config.tenant_scope_sha256,
            object.bytes,
        );
        logical_payload_bytes = std.math.add(
            u64,
            logical_payload_bytes,
            blob_ref.byte_length,
        ) catch return Error.ArithmeticOverflow;

        var ordinal: ?u64 = null;
        for (0..index) |previous_index| {
            const previous = entries[previous_index];
            if (!std.mem.eql(
                u8,
                &previous.blob_sha256,
                &blob_ref.sha256,
            )) continue;
            const previous_object = objects.get(
                capsule.object_kinds[previous_index],
            );
            if (previous.byte_length != blob_ref.byte_length or
                !std.mem.eql(u8, previous_object.bytes, object.bytes))
                return Error.DigestCollision;
            ordinal = previous.blob_ordinal;
            break;
        }
        const blob_ordinal = ordinal orelse unique_blob_count;
        if (ordinal == null) {
            unique_blob_count = std.math.add(
                u64,
                unique_blob_count,
                1,
            ) catch return Error.ArithmeticOverflow;
            unique_blob_bytes = std.math.add(
                u64,
                unique_blob_bytes,
                blob_ref.byte_length,
            ) catch return Error.ArithmeticOverflow;
        }
        entries[index] = .{
            .kind = kind,
            .abi_version = typed_ref.abi_version,
            .byte_length = typed_ref.byte_length,
            .blob_ordinal = blob_ordinal,
            .typed_sha256 = typed_ref.sha256,
            .blob_sha256 = blob_ref.sha256,
        };
    }

    const capsule_blob_ref = try blobRefV1(
        config.tenant_scope_sha256,
        capsule_wire,
    );
    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(encoded_bytes);
    try writer.writeU32(required_flags);
    try writer.writeU32(0);
    try writer.writeU64(capsule_wire.len);
    try writer.writeU64(capsule.object_count);
    try writer.writeU64(logical_payload_bytes);
    try writer.writeU64(unique_blob_count);
    try writer.writeU64(unique_blob_bytes);
    try writer.writeU64(config.bundle_generation);
    try writer.writeDigest(config.tenant_scope_sha256);
    try writer.writeDigest(config.capsule_sha256);
    try writer.writeDigest(capsule_blob_ref.sha256);
    try writer.writeDigest(config.challenge_sha256);
    try writer.writeDigest(config.parent_bundle_sha256);
    if (writer.position != header_bytes) return Error.InvalidLength;

    for (entries) |entry| {
        try writer.writeU64(@intFromEnum(entry.kind));
        try writer.writeU64(entry.abi_version);
        try writer.writeU64(entry.byte_length);
        try writer.writeU64(entry.blob_ordinal);
        try writer.writeDigest(entry.typed_sha256);
        try writer.writeDigest(entry.blob_sha256);
    }
    if (writer.position + digest_bytes != output.len)
        return Error.InvalidLength;
    try writer.writeDigest(envelopeSha256(output[0..writer.position]));
    if (writer.position != output.len) return Error.InvalidLength;
    return output;
}

/// Validate the self-contained bundle manifest and canonical ordinal table.
/// This does not authorize storage access or verify external payload bytes.
pub fn decodeManifestV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded_bytes) return Error.InvalidLength;
    if (try reader.readU32() != required_flags or try reader.readU32() != 0)
        return Error.InvalidFlags;

    const capsule_wire_length = try reader.readU64();
    const object_count = try reader.readU64();
    const logical_payload_bytes = try reader.readU64();
    const unique_blob_count = try reader.readU64();
    const unique_blob_bytes = try reader.readU64();
    const bundle_generation = try reader.readU64();
    const tenant_scope_sha256 = try reader.readDigest();
    const capsule_sha256 = try reader.readDigest();
    const capsule_blob_sha256 = try reader.readDigest();
    const challenge_sha256 = try reader.readDigest();
    const parent_bundle_sha256 = try reader.readDigest();
    if (reader.position != header_bytes) return Error.InvalidLength;
    const config: ConfigV1 = .{
        .tenant_scope_sha256 = tenant_scope_sha256,
        .capsule_sha256 = capsule_sha256,
        .bundle_generation = bundle_generation,
        .challenge_sha256 = challenge_sha256,
        .parent_bundle_sha256 = parent_bundle_sha256,
    };
    try validateConfig(config);
    if (capsule_wire_length != capsule.encoded_bytes or
        object_count != capsule.object_count or
        logical_payload_bytes == 0 or
        unique_blob_count == 0 or
        unique_blob_count > capsule.object_count or
        unique_blob_bytes == 0 or
        unique_blob_bytes > logical_payload_bytes or
        isZero(capsule_blob_sha256))
        return Error.InvalidTotals;

    var entries: [capsule.object_count]EntryV1 = undefined;
    var computed_logical_bytes: u64 = 0;
    var computed_unique_count: u64 = 0;
    var computed_unique_bytes: u64 = 0;
    for (&entries, capsule.object_kinds, 0..) |*entry, expected_kind, index| {
        const kind_value = try reader.readU64();
        if (kind_value != @intFromEnum(expected_kind))
            return Error.InvalidEntry;
        entry.* = .{
            .kind = expected_kind,
            .abi_version = try reader.readU64(),
            .byte_length = try reader.readU64(),
            .blob_ordinal = try reader.readU64(),
            .typed_sha256 = try reader.readDigest(),
            .blob_sha256 = try reader.readDigest(),
        };
        if (entry.abi_version == 0 or entry.byte_length == 0 or
            isZero(entry.typed_sha256) or isZero(entry.blob_sha256))
            return Error.InvalidEntry;
        computed_logical_bytes = std.math.add(
            u64,
            computed_logical_bytes,
            entry.byte_length,
        ) catch return Error.ArithmeticOverflow;

        var prior_ordinal: ?u64 = null;
        for (entries[0..index]) |previous| {
            if (!std.mem.eql(
                u8,
                &previous.blob_sha256,
                &entry.blob_sha256,
            )) continue;
            if (previous.byte_length != entry.byte_length)
                return Error.InvalidEntry;
            prior_ordinal = previous.blob_ordinal;
            break;
        }
        const expected_ordinal = prior_ordinal orelse computed_unique_count;
        if (entry.blob_ordinal != expected_ordinal)
            return Error.InvalidOrdinal;
        if (prior_ordinal == null) {
            computed_unique_count = std.math.add(
                u64,
                computed_unique_count,
                1,
            ) catch return Error.ArithmeticOverflow;
            computed_unique_bytes = std.math.add(
                u64,
                computed_unique_bytes,
                entry.byte_length,
            ) catch return Error.ArithmeticOverflow;
        }
    }
    if (computed_logical_bytes != logical_payload_bytes or
        computed_unique_count != unique_blob_count or
        computed_unique_bytes != unique_blob_bytes)
        return Error.InvalidTotals;

    const envelope_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &envelope_sha256,
        &envelopeSha256(encoded[0 .. encoded.len - digest_bytes]),
    )) return Error.InvalidEnvelope;
    return .{
        .config = config,
        .capsule_wire_length = capsule_wire_length,
        .capsule_blob_sha256 = capsule_blob_sha256,
        .logical_payload_bytes = logical_payload_bytes,
        .unique_blob_count = unique_blob_count,
        .unique_blob_bytes = unique_blob_bytes,
        .entries = entries,
        .envelope_sha256 = envelope_sha256,
    };
}

/// Verify expected bundle identity, exact capsule bytes, and all object bytes.
pub fn decodeAndVerifyV1(
    encoded: []const u8,
    expected_config: ConfigV1,
    capsule_wire: []const u8,
    objects: capsule.ObjectsV1,
) Error!DecodedV1 {
    const decoded = try decodeManifestV1(encoded);
    if (!std.meta.eql(decoded.config, expected_config))
        return Error.InvalidComposition;
    const decoded_capsule = capsule.decodeManifestV1(capsule_wire) catch
        return Error.CapsuleMismatch;
    if (!std.mem.eql(
        u8,
        &decoded_capsule.envelope_sha256,
        &expected_config.capsule_sha256,
    )) return Error.CapsuleMismatch;
    const capsule_blob_ref = try blobRefV1(
        expected_config.tenant_scope_sha256,
        capsule_wire,
    );
    if (capsule_blob_ref.byte_length != decoded.capsule_wire_length or
        !std.mem.eql(
            u8,
            &capsule_blob_ref.sha256,
            &decoded.capsule_blob_sha256,
        )) return Error.CapsuleMismatch;
    _ = capsule.decodeAndVerifyV1(
        capsule_wire,
        decoded_capsule.config,
        objects,
    ) catch return Error.InvalidComposition;

    var expected_storage: [encoded_bytes]u8 = undefined;
    const expected = try encodeV1(
        expected_config,
        capsule_wire,
        objects,
        &expected_storage,
    );
    if (!std.mem.eql(u8, encoded, expected))
        return Error.InvalidComposition;
    return decoded;
}

pub fn blobRefV1(
    tenant_scope_sha256: Digest,
    bytes: []const u8,
) Error!BlobRefV1 {
    if (isZero(tenant_scope_sha256) or bytes.len == 0)
        return Error.InvalidEntry;
    const byte_length = std.math.cast(u64, bytes.len) orelse
        return Error.InvalidEntry;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(blob_domain);
    hash.update(&tenant_scope_sha256);
    hashU64(&hash, byte_length);
    hash.update(bytes);
    var sha256: Digest = undefined;
    hash.final(&sha256);
    return .{ .byte_length = byte_length, .sha256 = sha256 };
}

pub fn envelopeRootV1(encoded: []const u8) Error!Digest {
    return (try decodeManifestV1(encoded)).envelope_sha256;
}

fn validateConfig(config: ConfigV1) Error!void {
    if (isZero(config.tenant_scope_sha256) or
        isZero(config.capsule_sha256) or
        isZero(config.challenge_sha256))
        return Error.InvalidConfig;
    const has_parent = !isZero(config.parent_bundle_sha256);
    if ((config.bundle_generation == 0 and has_parent) or
        (config.bundle_generation != 0 and !has_parent))
        return Error.InvalidConfig;
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

fn kindIndex(kind: capsule.ObjectKind) usize {
    return @intCast(@intFromEnum(kind));
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

fn demoCapsuleConfig() capsule.ConfigV1 {
    return .{
        .execution_abi = 0x4341_4558_0000_0001,
        .request_epoch = 0x4341_5251_0000_0001,
        .publication_sequence = 5,
        .checkpoint_generation = 0,
        .kv_tokens = 37,
        .output_tokens = 5,
        .challenge_sha256 = [_]u8{0xa8} ** 32,
    };
}

fn demoObjects() capsule.ObjectsV1 {
    return .{
        .model = .{ .abi_version = 0x4341_4d4f_0000_0001, .bytes = "shared-static-identity-v1" },
        .tokenizer = .{ .abi_version = 0x4341_544b_0000_0001, .bytes = "shared-static-identity-v1" },
        .execution_plan = .{ .abi_version = 0x4341_504c_0000_0001, .bytes = "plan-v1:cpu:threads=4:strict" },
        .resource_state = .{ .abi_version = 0x4341_5253_0000_0001, .bytes = "resource-v1:bank=17:kv=4096:output=64" },
        .lane_state = .{ .abi_version = 0x4341_4c4e_0000_0001, .bytes = "lane-v1:request=41:service=11" },
        .kv_state = .{ .abi_version = 0x4341_4b56_0000_0001, .bytes = "kv-v1:positions=37:root=bundle" },
        .sampler_state = .{ .abi_version = 0x4341_534d_0000_0001, .bytes = "sampler-v1:rng=01020304:calls=5" },
        .output_state = .{ .abi_version = 0x4341_4f55_0000_0001, .bytes = "output-v1:tokens=901,902,903,904,905" },
        .publication_receipt = .{ .abi_version = 0x4341_5052_0000_0001, .bytes = "publication-v1:sequence=5:commit=bundle" },
    };
}

fn demoBundleConfig(capsule_sha256: Digest) ConfigV1 {
    return .{
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .capsule_sha256 = capsule_sha256,
        .bundle_generation = 0,
        .challenge_sha256 = [_]u8{0xe3} ** 32,
    };
}

test "continuation bundle layout and canonical dedup are fixed" {
    try std.testing.expectEqual(@as(usize, 240), header_bytes);
    try std.testing.expectEqual(@as(usize, 96), entry_bytes);
    try std.testing.expectEqual(@as(usize, 1136), encoded_bytes);

    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const config = demoBundleConfig(try capsule.envelopeRootV1(capsule_wire));
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(config, capsule_wire, objects, &storage);
    const decoded = try decodeAndVerifyV1(
        encoded,
        config,
        capsule_wire,
        objects,
    );
    const root_hex = std.fmt.bytesToHex(decoded.envelope_sha256, .lower);
    try std.testing.expectEqualStrings(
        "390c29d58b4cf979f44606f611f10b81" ++
            "1351d85cdbe1dedaeebe7b31b8564cc5",
        &root_hex,
    );
    try std.testing.expectEqual(@as(u64, 8), decoded.unique_blob_count);
    try std.testing.expectEqual(
        @as(u64, objects.model.bytes.len),
        decoded.deduplicatedPayloadBytes(),
    );
    try std.testing.expectEqual(@as(u64, 0), decoded.entry(.model).blob_ordinal);
    try std.testing.expectEqual(
        decoded.entry(.model).blob_ordinal,
        decoded.entry(.tokenizer).blob_ordinal,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &decoded.entry(.model).typed_sha256,
        &decoded.entry(.tokenizer).typed_sha256,
    ));
}

test "continuation bundle rejects every serialized byte mutation" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const config = demoBundleConfig(try capsule.envelopeRootV1(capsule_wire));
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(config, capsule_wire, objects, &storage);
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
        if (decodeAndVerifyV1(
            &mutated,
            config,
            capsule_wire,
            objects,
        )) |_| {
            return error.ExpectedMutationRejection;
        } else |_| {}
    }
}

test "continuation bundle tenant scope separates identical blobs" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const first = demoBundleConfig(try capsule.envelopeRootV1(capsule_wire));
    var second = first;
    second.tenant_scope_sha256 = [_]u8{0x7e} ** 32;
    const first_blob = try blobRefV1(
        first.tenant_scope_sha256,
        objects.model.bytes,
    );
    const second_blob = try blobRefV1(
        second.tenant_scope_sha256,
        objects.model.bytes,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &first_blob.sha256,
        &second_blob.sha256,
    ));
    var first_storage: [encoded_bytes]u8 = undefined;
    const first_encoded = try encodeV1(
        first,
        capsule_wire,
        objects,
        &first_storage,
    );
    try std.testing.expectError(
        Error.InvalidComposition,
        decodeAndVerifyV1(
            first_encoded,
            second,
            capsule_wire,
            objects,
        ),
    );
}

test "continuation bundle rejects foreign objects capsule and storage" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const config = demoBundleConfig(try capsule.envelopeRootV1(capsule_wire));
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(config, capsule_wire, objects, &storage);
    var foreign = objects;
    foreign.kv_state = .{
        .abi_version = objects.kv_state.abi_version,
        .bytes = "kv-v1:positions=37:root=foreign",
    };
    try std.testing.expectError(
        Error.InvalidComposition,
        decodeAndVerifyV1(
            encoded,
            config,
            capsule_wire,
            foreign,
        ),
    );
    var foreign_capsule_config = demoCapsuleConfig();
    foreign_capsule_config.publication_sequence += 1;
    var foreign_capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const foreign_capsule = try capsule.encodeV1(
        foreign_capsule_config,
        objects,
        &foreign_capsule_storage,
    );
    try std.testing.expectError(
        Error.CapsuleMismatch,
        decodeAndVerifyV1(
            encoded,
            config,
            foreign_capsule,
            objects,
        ),
    );
    var alias_storage: [encoded_bytes]u8 = undefined;
    var aliased = objects;
    aliased.model.bytes = alias_storage[0..objects.model.bytes.len];
    try std.testing.expectError(
        Error.InvalidStorage,
        encodeV1(
            config,
            capsule_wire,
            aliased,
            &alias_storage,
        ),
    );
}

test "continuation bundle rejects truncation and extension" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const config = demoBundleConfig(try capsule.envelopeRootV1(capsule_wire));
    var storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(config, capsule_wire, objects, &storage);
    try std.testing.expectError(
        Error.InvalidLength,
        decodeManifestV1(encoded[0 .. encoded.len - 1]),
    );
    var extended: [encoded_bytes + 1]u8 = undefined;
    @memcpy(extended[0..encoded_bytes], encoded);
    extended[encoded_bytes] = 0;
    try std.testing.expectError(
        Error.InvalidLength,
        decodeManifestV1(&extended),
    );
}

test "continuation bundle parent lineage fails closed" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        &capsule_storage,
    );
    const first_config = demoBundleConfig(
        try capsule.envelopeRootV1(capsule_wire),
    );
    var first_storage: [encoded_bytes]u8 = undefined;
    const first = try encodeV1(
        first_config,
        capsule_wire,
        objects,
        &first_storage,
    );
    var next = first_config;
    next.bundle_generation = 1;
    next.parent_bundle_sha256 = try envelopeRootV1(first);
    var next_storage: [encoded_bytes]u8 = undefined;
    _ = try encodeV1(next, capsule_wire, objects, &next_storage);
    next.parent_bundle_sha256 = zero_digest;
    try std.testing.expectError(
        Error.InvalidConfig,
        encodeV1(next, capsule_wire, objects, &next_storage),
    );
}
