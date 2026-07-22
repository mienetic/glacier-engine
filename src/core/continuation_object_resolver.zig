//! Capability-bounded resolver for ContinuationCapsule external objects.
//!
//! A trusted caller supplies a tenant-scoped grant and an immutable catalog.
//! The resolver admits only the exact kind/ABI/length/root references committed
//! by one capsule, enforces byte and resolution budgets before copying, and
//! writes verified payloads only into caller-owned non-overlapping buffers.
//! It allocates nothing and owns no filesystem, network, or publication access.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");

pub const Digest = capsule.Digest;
pub const zero_digest = capsule.zero_digest;
pub const full_object_mask: u64 =
    (@as(u64, 1) << @intCast(capsule.object_count)) - 1;

const grant_domain = "glacier-continuation-resolver-grant-v1\x00";

pub const Error = capsule.Error || error{
    InvalidGrant,
    StaleGrant,
    CapsuleMismatch,
    CatalogLimitExceeded,
    DeniedKind,
    ResolutionLimit,
    ObjectTooLarge,
    TotalBudgetExceeded,
    ObjectNotFound,
    AmbiguousObject,
    CorruptObject,
    InsufficientDestination,
    UnsafeDestination,
    AlreadyResolved,
    Incomplete,
    ResolvedObjectChanged,
    Finalized,
};

/// Local least-authority token. Its digest is an auditable identity, not a
/// signature; the caller that constructs and supplies the grant is trusted.
pub const GrantV1 = struct {
    authority_epoch: u64,
    request_epoch: u64,
    capsule_sha256: Digest,
    tenant_scope_sha256: Digest,
    allowed_kind_mask: u64,
    max_object_bytes: u64,
    max_total_bytes: u64,
    max_resolutions: u64,
    max_catalog_entries: u64,
    challenge_sha256: Digest,
};

/// One immutable catalog entry. Payload bytes remain external to both the
/// capsule and grant.
pub const StoredObjectV1 = struct {
    tenant_scope_sha256: Digest,
    kind: capsule.ObjectKind,
    abi_version: u64,
    sha256: Digest,
    bytes: []const u8,
};

pub const ResolverV1 = struct {
    grant: GrantV1,
    grant_sha256: Digest,
    capsule_wire: []const u8,
    decoded: capsule.DecodedV1,
    catalog: []const StoredObjectV1,
    resolved: [capsule.object_count]?capsule.ObjectV1 =
        [_]?capsule.ObjectV1{null} ** capsule.object_count,
    resolved_mask: u64 = 0,
    resolved_bytes: u64 = 0,
    resolution_count: u64 = 0,
    finalized: bool = false,

    pub fn initV1(
        grant: GrantV1,
        expected_authority_epoch: u64,
        capsule_wire: []const u8,
        catalog: []const StoredObjectV1,
    ) Error!ResolverV1 {
        try validateGrant(grant);
        if (grant.authority_epoch != expected_authority_epoch)
            return Error.StaleGrant;
        if (catalog.len > grant.max_catalog_entries)
            return Error.CatalogLimitExceeded;
        const decoded = try capsule.decodeManifestV1(capsule_wire);
        if (!std.mem.eql(
            u8,
            &decoded.envelope_sha256,
            &grant.capsule_sha256,
        ) or decoded.config.request_epoch != grant.request_epoch)
            return Error.CapsuleMismatch;
        return .{
            .grant = grant,
            .grant_sha256 = try grantRootV1(grant),
            .capsule_wire = capsule_wire,
            .decoded = decoded,
            .catalog = catalog,
        };
    }

    /// Resolve one capsule reference into caller-owned storage. Every fallible
    /// check happens before the copy and before accounting changes.
    pub fn resolveV1(
        self: *ResolverV1,
        kind: capsule.ObjectKind,
        destination: []u8,
    ) Error![]const u8 {
        if (self.finalized) return Error.Finalized;
        const index = kindIndex(kind);
        const bit = kindBit(kind);
        if (self.grant.allowed_kind_mask & bit == 0)
            return Error.DeniedKind;
        if (self.resolved_mask & bit != 0)
            return Error.AlreadyResolved;
        if (self.resolution_count >= self.grant.max_resolutions)
            return Error.ResolutionLimit;

        const expected_ref = self.decoded.refs[index];
        if (expected_ref.byte_length > self.grant.max_object_bytes)
            return Error.ObjectTooLarge;
        const next_total = std.math.add(
            u64,
            self.resolved_bytes,
            expected_ref.byte_length,
        ) catch return Error.TotalBudgetExceeded;
        if (next_total > self.grant.max_total_bytes)
            return Error.TotalBudgetExceeded;
        const payload_length = std.math.cast(
            usize,
            expected_ref.byte_length,
        ) orelse return Error.ObjectTooLarge;
        if (destination.len < payload_length)
            return Error.InsufficientDestination;
        const output = destination[0..payload_length];
        if (slicesOverlap(output, std.mem.asBytes(self)) or
            slicesOverlap(output, std.mem.sliceAsBytes(self.catalog)) or
            slicesOverlap(output, self.capsule_wire))
            return Error.UnsafeDestination;
        for (self.resolved) |maybe_object| {
            if (maybe_object) |object| {
                if (slicesOverlap(output, object.bytes))
                    return Error.UnsafeDestination;
            }
        }
        // Protect the complete immutable catalog, not just the selected entry:
        // writing over a future source would make lookup order observable.
        for (self.catalog) |entry| {
            if (slicesOverlap(output, entry.bytes))
                return Error.UnsafeDestination;
        }

        var selected: ?*const StoredObjectV1 = null;
        var exact_matches: usize = 0;
        for (self.catalog) |*entry| {
            if (!std.mem.eql(
                u8,
                &entry.tenant_scope_sha256,
                &self.grant.tenant_scope_sha256,
            ) or entry.kind != kind or
                entry.abi_version != expected_ref.abi_version or
                entry.bytes.len != expected_ref.byte_length or
                !std.mem.eql(u8, &entry.sha256, &expected_ref.sha256))
                continue;
            exact_matches += 1;
            if (exact_matches > 1) return Error.AmbiguousObject;
            selected = entry;
        }
        const entry = selected orelse return Error.ObjectNotFound;
        const computed = capsule.objectRefV1(kind, .{
            .abi_version = entry.abi_version,
            .bytes = entry.bytes,
        }) catch return Error.CorruptObject;
        if (!std.meta.eql(computed, expected_ref))
            return Error.CorruptObject;

        @memcpy(output, entry.bytes);
        self.resolved[index] = .{
            .abi_version = entry.abi_version,
            .bytes = output,
        };
        self.resolved_mask |= bit;
        self.resolved_bytes = next_total;
        self.resolution_count += 1;
        return output;
    }

    /// Re-hash every caller-owned output and the complete capsule composition.
    /// A changed output poisons/finalizes the session so stale bytes cannot be
    /// retried as though they were a fresh resolution.
    pub fn finishFullV1(self: *ResolverV1) Error!capsule.ObjectsV1 {
        if (self.finalized) return Error.Finalized;
        if (self.grant.allowed_kind_mask != full_object_mask or
            self.resolved_mask != full_object_mask or
            self.resolution_count != capsule.object_count)
            return Error.Incomplete;
        const objects = self.resolvedObjects() catch {
            self.finalized = true;
            return Error.Incomplete;
        };
        _ = capsule.decodeAndVerifyV1(
            self.capsule_wire,
            self.decoded.config,
            objects,
        ) catch {
            self.finalized = true;
            return Error.ResolvedObjectChanged;
        };
        self.finalized = true;
        return objects;
    }

    fn resolvedObjects(self: *const ResolverV1) Error!capsule.ObjectsV1 {
        return .{
            .model = try self.resolvedObject(.model),
            .tokenizer = try self.resolvedObject(.tokenizer),
            .execution_plan = try self.resolvedObject(.execution_plan),
            .resource_state = try self.resolvedObject(.resource_state),
            .lane_state = try self.resolvedObject(.lane_state),
            .kv_state = try self.resolvedObject(.kv_state),
            .sampler_state = try self.resolvedObject(.sampler_state),
            .output_state = try self.resolvedObject(.output_state),
            .publication_receipt = try self.resolvedObject(
                .publication_receipt,
            ),
        };
    }

    fn resolvedObject(
        self: *const ResolverV1,
        kind: capsule.ObjectKind,
    ) Error!capsule.ObjectV1 {
        return self.resolved[kindIndex(kind)] orelse Error.Incomplete;
    }
};

pub fn grantRootV1(grant: GrantV1) Error!Digest {
    try validateGrant(grant);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(grant_domain);
    hashU64(&hash, grant.authority_epoch);
    hashU64(&hash, grant.request_epoch);
    hash.update(&grant.capsule_sha256);
    hash.update(&grant.tenant_scope_sha256);
    hashU64(&hash, grant.allowed_kind_mask);
    hashU64(&hash, grant.max_object_bytes);
    hashU64(&hash, grant.max_total_bytes);
    hashU64(&hash, grant.max_resolutions);
    hashU64(&hash, grant.max_catalog_entries);
    hash.update(&grant.challenge_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn validateGrant(grant: GrantV1) Error!void {
    if (grant.authority_epoch == 0 or
        grant.request_epoch == 0 or
        isZero(grant.capsule_sha256) or
        isZero(grant.tenant_scope_sha256) or
        isZero(grant.challenge_sha256) or
        grant.allowed_kind_mask == 0 or
        grant.allowed_kind_mask & ~full_object_mask != 0 or
        grant.max_object_bytes == 0 or
        grant.max_total_bytes == 0 or
        grant.max_catalog_entries == 0 or
        grant.max_resolutions != @popCount(grant.allowed_kind_mask))
        return Error.InvalidGrant;
}

fn kindIndex(kind: capsule.ObjectKind) usize {
    return @intCast(@intFromEnum(kind));
}

fn kindBit(kind: capsule.ObjectKind) u64 {
    return @as(u64, 1) << @intCast(@intFromEnum(kind));
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

fn demoConfig() capsule.ConfigV1 {
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

fn demoObjects() capsule.ObjectsV1 {
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

fn buildCatalog(
    objects: capsule.ObjectsV1,
    tenant_scope_sha256: Digest,
) ![capsule.object_count]StoredObjectV1 {
    var catalog: [capsule.object_count]StoredObjectV1 = undefined;
    for (capsule.object_kinds, 0..) |kind, index| {
        const object = objects.get(kind);
        const object_ref = try capsule.objectRefV1(kind, object);
        catalog[index] = .{
            .tenant_scope_sha256 = tenant_scope_sha256,
            .kind = kind,
            .abi_version = object.abi_version,
            .sha256 = object_ref.sha256,
            .bytes = object.bytes,
        };
    }
    return catalog;
}

fn totalObjectBytes(objects: capsule.ObjectsV1) u64 {
    var total: u64 = 0;
    for (capsule.object_kinds) |kind| total += objects.get(kind).bytes.len;
    return total;
}

fn demoGrant(capsule_sha256: Digest) GrantV1 {
    return .{
        .authority_epoch = 7,
        .request_epoch = demoConfig().request_epoch,
        .capsule_sha256 = capsule_sha256,
        .tenant_scope_sha256 = [_]u8{0x5c} ** 32,
        .allowed_kind_mask = full_object_mask,
        .max_object_bytes = 64,
        .max_total_bytes = totalObjectBytes(demoObjects()),
        .max_resolutions = capsule.object_count,
        .max_catalog_entries = 16,
        .challenge_sha256 = [_]u8{0xd4} ** 32,
    };
}

test "resolver verifies all capsule objects under exact quotas" {
    const config = demoConfig();
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        config,
        objects,
        &capsule_storage,
    );
    const capsule_root = try capsule.envelopeRootV1(capsule_wire);
    const grant = demoGrant(capsule_root);
    const catalog = try buildCatalog(objects, grant.tenant_scope_sha256);
    var resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    var outputs: [capsule.object_count][64]u8 = undefined;
    for (capsule.object_kinds, 0..) |kind, index| {
        const resolved = try resolver.resolveV1(kind, &outputs[index]);
        try std.testing.expectEqualSlices(
            u8,
            objects.get(kind).bytes,
            resolved,
        );
    }
    const resolved_objects = try resolver.finishFullV1();
    try std.testing.expectEqualSlices(
        u8,
        objects.kv_state.bytes,
        resolved_objects.kv_state.bytes,
    );
    try std.testing.expectEqual(grant.max_total_bytes, resolver.resolved_bytes);
    try std.testing.expectEqual(grant.max_resolutions, resolver.resolution_count);
    try std.testing.expectError(Error.Finalized, resolver.finishFullV1());
}

test "resolver rejects stale denied repeated and incomplete authority" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoConfig(),
        objects,
        &capsule_storage,
    );
    var grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    grant.allowed_kind_mask = kindBit(.model);
    grant.max_resolutions = 1;
    const catalog = try buildCatalog(objects, grant.tenant_scope_sha256);
    try std.testing.expectError(
        Error.StaleGrant,
        ResolverV1.initV1(
            grant,
            grant.authority_epoch + 1,
            capsule_wire,
            &catalog,
        ),
    );
    var resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    var output: [64]u8 = undefined;
    try std.testing.expectError(
        Error.DeniedKind,
        resolver.resolveV1(.tokenizer, &output),
    );
    _ = try resolver.resolveV1(.model, &output);
    try std.testing.expectError(
        Error.AlreadyResolved,
        resolver.resolveV1(.model, &output),
    );
    try std.testing.expectError(Error.Incomplete, resolver.finishFullV1());
}

test "resolver isolates tenant and rejects corrupt or ambiguous catalog" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoConfig(),
        objects,
        &capsule_storage,
    );
    const grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    var catalog = try buildCatalog(objects, [_]u8{0x91} ** 32);
    var resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    var output = [_]u8{0xee} ** 64;
    try std.testing.expectError(
        Error.ObjectNotFound,
        resolver.resolveV1(.model, &output),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xee));
    try std.testing.expectEqual(@as(u64, 0), resolver.resolved_bytes);

    catalog = try buildCatalog(objects, grant.tenant_scope_sha256);
    const original_model_bytes = catalog[0].bytes;
    catalog[0].bytes = "model-v1:sha256:demo-glru";
    resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    try std.testing.expectError(
        Error.CorruptObject,
        resolver.resolveV1(.model, &output),
    );
    catalog[0].bytes = original_model_bytes;

    var duplicate: [capsule.object_count + 1]StoredObjectV1 = undefined;
    @memcpy(duplicate[0..capsule.object_count], &catalog);
    duplicate[capsule.object_count] = catalog[0];
    resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &duplicate,
    );
    try std.testing.expectError(
        Error.AmbiguousObject,
        resolver.resolveV1(.model, &output),
    );
}

test "resolver enforces destination and byte budgets before mutation" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoConfig(),
        objects,
        &capsule_storage,
    );
    var grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    var catalog = try buildCatalog(objects, grant.tenant_scope_sha256);
    grant.max_object_bytes = objects.model.bytes.len - 1;
    var resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    var output = [_]u8{0xee} ** 64;
    try std.testing.expectError(
        Error.ObjectTooLarge,
        resolver.resolveV1(.model, &output),
    );
    try std.testing.expect(std.mem.allEqual(u8, &output, 0xee));

    grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    try std.testing.expectError(
        Error.InsufficientDestination,
        resolver.resolveV1(.model, output[0..4]),
    );
    try std.testing.expectError(
        Error.UnsafeDestination,
        resolver.resolveV1(.model, capsule_storage[0..64]),
    );
    try std.testing.expectError(
        Error.UnsafeDestination,
        resolver.resolveV1(.model, std.mem.asBytes(&resolver)),
    );
    try std.testing.expectError(
        Error.UnsafeDestination,
        resolver.resolveV1(.model, std.mem.asBytes(&catalog)),
    );
    _ = try resolver.resolveV1(.model, &output);
    try std.testing.expectError(
        Error.UnsafeDestination,
        resolver.resolveV1(.tokenizer, output[1..]),
    );
}

test "resolver detects changed caller-owned output at finalization" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoConfig(),
        objects,
        &capsule_storage,
    );
    const grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    const catalog = try buildCatalog(objects, grant.tenant_scope_sha256);
    var resolver = try ResolverV1.initV1(
        grant,
        grant.authority_epoch,
        capsule_wire,
        &catalog,
    );
    var outputs: [capsule.object_count][64]u8 = undefined;
    for (capsule.object_kinds, 0..) |kind, index| {
        _ = try resolver.resolveV1(kind, &outputs[index]);
    }
    outputs[kindIndex(.kv_state)][0] ^= 1;
    try std.testing.expectError(
        Error.ResolvedObjectChanged,
        resolver.finishFullV1(),
    );
    try std.testing.expectError(Error.Finalized, resolver.finishFullV1());
}

test "resolver grant and capsule identity fail closed" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(
        demoConfig(),
        objects,
        &capsule_storage,
    );
    var grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    const catalog = try buildCatalog(objects, grant.tenant_scope_sha256);
    grant.max_catalog_entries = catalog.len - 1;
    try std.testing.expectError(
        Error.CatalogLimitExceeded,
        ResolverV1.initV1(
            grant,
            grant.authority_epoch,
            capsule_wire,
            &catalog,
        ),
    );
    grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    grant.capsule_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.CapsuleMismatch,
        ResolverV1.initV1(
            grant,
            grant.authority_epoch,
            capsule_wire,
            &catalog,
        ),
    );
    grant = demoGrant(try capsule.envelopeRootV1(capsule_wire));
    grant.request_epoch += 1;
    try std.testing.expectError(
        Error.CapsuleMismatch,
        ResolverV1.initV1(
            grant,
            grant.authority_epoch,
            capsule_wire,
            &catalog,
        ),
    );
}
