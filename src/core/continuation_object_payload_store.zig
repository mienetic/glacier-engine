//! Canonical durable-payload snapshot and copy-on-write reclaim preview.
//!
//! This module has no filesystem authority. It validates immutable payload
//! bytes against tenant-scoped object identities, encodes one deterministic
//! snapshot, and predicts an exact filtered successor without mutating the
//! active bytes. A filesystem adapter can sync that successor before atomically
//! promoting it.

const std = @import("std");
const bundle = @import("continuation_bundle.zig");
const object_store = @import("continuation_object_store.zig");

pub const Digest = [32]u8;
pub const magic = [8]u8{ 'G', 'L', 'P', 'A', 'Y', '0', '1', 0 };
pub const schema_version: u64 = 1;
pub const header_bytes: usize = 64;
pub const entry_header_bytes: usize = 40;
pub const footer_bytes: usize = 32;
pub const minimum_encoded_bytes: usize = header_bytes + footer_bytes;
pub const default_capacity: usize = object_store.default_capacity;

const body_domain = "glacier-continuation-object-payload-store-body-v1\x00";
const snapshot_domain = "glacier-continuation-object-payload-store-snapshot-v1\x00";
const preview_domain = "glacier-continuation-object-payload-store-reclaim-preview-v1\x00";

pub const Error = bundle.Error || object_store.Error || error{
    ArithmeticOverflow,
    BufferTooSmall,
    DuplicateEntry,
    EntryCountExceeded,
    InvalidEncoding,
    InvalidMagic,
    InvalidPayload,
    InvalidPreview,
    NonCanonicalEntries,
    TargetNotFound,
    TenantScopeMismatch,
    UnsupportedSchema,
    UnsafeDestination,
};

pub const EntryInputV1 = struct {
    reference: bundle.BlobRefV1,
    payload: []const u8,
};

pub const EntryViewV1 = struct {
    reference: bundle.BlobRefV1,
    payload: []const u8,
};

pub const SnapshotV1 = struct {
    tenant_scope_sha256: Digest,
    entry_count: u64,
    payload_bytes: u64,
    encoded_bytes: u64,
    body_sha256: Digest,
    encoded_sha256: Digest,
    snapshot_sha256: Digest,
};

pub const ReclaimPreviewV1 = struct {
    before: SnapshotV1,
    after: SnapshotV1,
    targets_sha256: Digest,
    freed_entries: u64,
    freed_payload_bytes: u64,
    preview_sha256: Digest,
};

pub fn sortEntriesV1(entries: []EntryInputV1) void {
    var index: usize = 1;
    while (index < entries.len) : (index += 1) {
        var cursor = index;
        while (cursor > 0 and
            entryOrder(
                entries[cursor].reference,
                entries[cursor - 1].reference,
            ) == .lt)
        {
            const prior = entries[cursor - 1];
            entries[cursor - 1] = entries[cursor];
            entries[cursor] = prior;
            cursor -= 1;
        }
    }
}

/// Encodes a canonical payload snapshot. All validation and capacity checks
/// finish before the first output byte is changed.
pub fn encodeSnapshotV1(
    tenant_scope_sha256: Digest,
    entries: []const EntryInputV1,
    output: []u8,
) Error![]const u8 {
    if (isZero(tenant_scope_sha256)) return Error.TenantScopeMismatch;
    if (entries.len > default_capacity) return Error.EntryCountExceeded;
    var payload_bytes: u64 = 0;
    var required_bytes: usize = minimum_encoded_bytes;
    for (entries, 0..) |entry, index| {
        try validateEntryV1(tenant_scope_sha256, entry);
        if (index > 0) {
            const order = entryOrder(
                entries[index - 1].reference,
                entry.reference,
            );
            if (order == .eq) return Error.DuplicateEntry;
            if (order != .lt) return Error.NonCanonicalEntries;
        }
        payload_bytes = std.math.add(
            u64,
            payload_bytes,
            entry.reference.byte_length,
        ) catch return Error.ArithmeticOverflow;
        required_bytes = std.math.add(
            usize,
            required_bytes,
            entry_header_bytes,
        ) catch return Error.ArithmeticOverflow;
        required_bytes = std.math.add(
            usize,
            required_bytes,
            entry.payload.len,
        ) catch return Error.ArithmeticOverflow;
    }
    if (output.len < required_bytes) return Error.BufferTooSmall;
    for (entries) |entry| {
        if (slicesOverlap(output[0..required_bytes], entry.payload))
            return Error.UnsafeDestination;
    }

    const encoded = output[0..required_bytes];
    @memcpy(encoded[0..magic.len], &magic);
    writeU64(encoded, 8, schema_version);
    @memcpy(encoded[16..48], &tenant_scope_sha256);
    writeU64(
        encoded,
        48,
        std.math.cast(u64, entries.len) orelse unreachable,
    );
    writeU64(encoded, 56, payload_bytes);
    var cursor: usize = header_bytes;
    for (entries) |entry| {
        writeU64(encoded, cursor, entry.reference.byte_length);
        cursor += 8;
        @memcpy(encoded[cursor .. cursor + 32], &entry.reference.sha256);
        cursor += 32;
        @memcpy(encoded[cursor .. cursor + entry.payload.len], entry.payload);
        cursor += entry.payload.len;
    }
    const body_sha256 = bodyRootV1(encoded[0..cursor]);
    @memcpy(encoded[cursor .. cursor + footer_bytes], &body_sha256);
    return encoded;
}

/// Verifies one complete snapshot and returns entry views into caller-owned
/// encoded storage.
pub fn decodeSnapshotV1(
    encoded: []const u8,
    expected_tenant_scope_sha256: Digest,
    entries: []EntryViewV1,
) Error!SnapshotV1 {
    if (encoded.len < minimum_encoded_bytes) return Error.InvalidEncoding;
    if (!std.mem.eql(u8, encoded[0..magic.len], &magic))
        return Error.InvalidMagic;
    if (readU64(encoded, 8) != schema_version)
        return Error.UnsupportedSchema;
    if (isZero(expected_tenant_scope_sha256) or
        !std.mem.eql(
            u8,
            encoded[16..48],
            &expected_tenant_scope_sha256,
        ))
        return Error.TenantScopeMismatch;
    const entry_count_u64 = readU64(encoded, 48);
    const entry_count = std.math.cast(usize, entry_count_u64) orelse
        return Error.EntryCountExceeded;
    if (entry_count > default_capacity or entry_count > entries.len)
        return Error.EntryCountExceeded;
    const declared_payload_bytes = readU64(encoded, 56);
    var cursor: usize = header_bytes;
    var payload_bytes: u64 = 0;
    for (0..entry_count) |index| {
        if (cursor > encoded.len -| entry_header_bytes)
            return Error.InvalidEncoding;
        const byte_length = readU64(encoded, cursor);
        cursor += 8;
        var reference: bundle.BlobRefV1 = .{
            .byte_length = byte_length,
            .sha256 = undefined,
        };
        @memcpy(&reference.sha256, encoded[cursor .. cursor + 32]);
        cursor += 32;
        const payload_length = std.math.cast(usize, byte_length) orelse
            return Error.InvalidEncoding;
        if (payload_length > encoded.len -| cursor)
            return Error.InvalidEncoding;
        const payload = encoded[cursor .. cursor + payload_length];
        cursor += payload_length;
        try validateEntryV1(expected_tenant_scope_sha256, .{
            .reference = reference,
            .payload = payload,
        });
        if (index > 0) {
            const order = entryOrder(
                entries[index - 1].reference,
                reference,
            );
            if (order == .eq) return Error.DuplicateEntry;
            if (order != .lt) return Error.NonCanonicalEntries;
        }
        entries[index] = .{
            .reference = reference,
            .payload = payload,
        };
        payload_bytes = std.math.add(
            u64,
            payload_bytes,
            byte_length,
        ) catch return Error.ArithmeticOverflow;
    }
    if (payload_bytes != declared_payload_bytes or
        cursor > encoded.len -| footer_bytes or
        cursor + footer_bytes != encoded.len)
        return Error.InvalidEncoding;
    const body_sha256 = bodyRootV1(encoded[0..cursor]);
    if (!std.mem.eql(
        u8,
        &body_sha256,
        encoded[cursor .. cursor + footer_bytes],
    )) return Error.InvalidEncoding;
    return snapshotV1(
        expected_tenant_scope_sha256,
        entry_count_u64,
        payload_bytes,
        encoded,
        body_sha256,
    );
}

/// Produces the exact successor snapshot in caller storage without changing
/// the active snapshot. Targets must use the canonical store ordering.
pub fn previewReclaimV1(
    active: []const u8,
    tenant_scope_sha256: Digest,
    targets: []const bundle.BlobRefV1,
    candidate_storage: []u8,
) Error!ReclaimPreviewV1 {
    if (slicesOverlap(active, candidate_storage))
        return Error.UnsafeDestination;
    const targets_sha256 = try object_store.retiredTargetsRootV1(targets);
    var active_entries: [default_capacity]EntryViewV1 = undefined;
    const before = try decodeSnapshotV1(
        active,
        tenant_scope_sha256,
        &active_entries,
    );
    const active_count = std.math.cast(usize, before.entry_count) orelse
        return Error.EntryCountExceeded;
    var retained: [default_capacity]EntryInputV1 = undefined;
    var retained_count: usize = 0;
    var target_cursor: usize = 0;
    var freed_payload_bytes: u64 = 0;
    for (active_entries[0..active_count]) |entry| {
        if (target_cursor < targets.len and
            std.meta.eql(entry.reference, targets[target_cursor]))
        {
            freed_payload_bytes = std.math.add(
                u64,
                freed_payload_bytes,
                entry.reference.byte_length,
            ) catch return Error.ArithmeticOverflow;
            target_cursor += 1;
            continue;
        }
        retained[retained_count] = .{
            .reference = entry.reference,
            .payload = entry.payload,
        };
        retained_count += 1;
    }
    if (target_cursor != targets.len) return Error.TargetNotFound;
    const candidate = try encodeSnapshotV1(
        tenant_scope_sha256,
        retained[0..retained_count],
        candidate_storage,
    );
    var candidate_entries: [default_capacity]EntryViewV1 = undefined;
    const after = try decodeSnapshotV1(
        candidate,
        tenant_scope_sha256,
        &candidate_entries,
    );
    var preview: ReclaimPreviewV1 = .{
        .before = before,
        .after = after,
        .targets_sha256 = targets_sha256,
        .freed_entries = std.math.cast(u64, targets.len) orelse
            return Error.ArithmeticOverflow,
        .freed_payload_bytes = freed_payload_bytes,
        .preview_sha256 = [_]u8{0} ** 32,
    };
    preview.preview_sha256 = previewRootV1(preview);
    return preview;
}

pub fn verifyReclaimPreviewV1(preview: ReclaimPreviewV1) Error!void {
    const removed_entry_bytes = std.math.mul(
        u64,
        preview.freed_entries,
        entry_header_bytes,
    ) catch return Error.InvalidPreview;
    const removed_encoded_bytes = std.math.add(
        u64,
        removed_entry_bytes,
        preview.freed_payload_bytes,
    ) catch return Error.InvalidPreview;
    if (preview.freed_entries == 0 or
        isZero(preview.before.tenant_scope_sha256) or
        !std.mem.eql(
            u8,
            &preview.before.tenant_scope_sha256,
            &preview.after.tenant_scope_sha256,
        ) or isZero(preview.before.body_sha256) or
        isZero(preview.before.encoded_sha256) or
        isZero(preview.before.snapshot_sha256) or
        isZero(preview.after.body_sha256) or
        isZero(preview.after.encoded_sha256) or
        isZero(preview.after.snapshot_sha256) or
        isZero(preview.targets_sha256) or
        preview.before.entry_count < preview.freed_entries or
        preview.before.payload_bytes < preview.freed_payload_bytes or
        preview.before.encoded_bytes < minimum_encoded_bytes or
        preview.after.encoded_bytes < minimum_encoded_bytes or
        preview.before.encoded_bytes <= preview.after.encoded_bytes or
        preview.before.encoded_bytes - preview.after.encoded_bytes !=
            removed_encoded_bytes or
        preview.after.entry_count !=
            preview.before.entry_count - preview.freed_entries or
        preview.after.payload_bytes !=
            preview.before.payload_bytes - preview.freed_payload_bytes or
        !std.mem.eql(
            u8,
            &preview.preview_sha256,
            &previewRootV1(preview),
        ))
        return Error.InvalidPreview;
}

pub fn previewRootV1(preview: ReclaimPreviewV1) Digest {
    return previewCommitmentRootV1(
        preview.before.snapshot_sha256,
        preview.after.snapshot_sha256,
        preview.targets_sha256,
        preview.freed_entries,
        preview.freed_payload_bytes,
    );
}

pub fn previewCommitmentRootV1(
    before_snapshot_sha256: Digest,
    after_snapshot_sha256: Digest,
    targets_sha256: Digest,
    freed_entries: u64,
    freed_payload_bytes: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(preview_domain);
    hash.update(&before_snapshot_sha256);
    hash.update(&after_snapshot_sha256);
    hash.update(&targets_sha256);
    hashU64(&hash, freed_entries);
    hashU64(&hash, freed_payload_bytes);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn validateEntryV1(
    tenant_scope_sha256: Digest,
    entry: EntryInputV1,
) Error!void {
    const payload_length = std.math.cast(
        usize,
        entry.reference.byte_length,
    ) orelse return Error.InvalidPayload;
    if (entry.reference.byte_length == 0 or
        entry.payload.len != payload_length)
        return Error.InvalidPayload;
    const actual = bundle.blobRefV1(
        tenant_scope_sha256,
        entry.payload,
    ) catch return Error.InvalidPayload;
    if (!std.meta.eql(actual, entry.reference))
        return Error.InvalidPayload;
}

fn snapshotV1(
    tenant_scope_sha256: Digest,
    entry_count: u64,
    payload_bytes: u64,
    encoded: []const u8,
    body_sha256: Digest,
) SnapshotV1 {
    var encoded_sha256: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded, &encoded_sha256, .{});
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(snapshot_domain);
    hash.update(&tenant_scope_sha256);
    hashU64(&hash, entry_count);
    hashU64(&hash, payload_bytes);
    hashU64(&hash, @intCast(encoded.len));
    hash.update(&encoded_sha256);
    var snapshot_sha256: Digest = undefined;
    hash.final(&snapshot_sha256);
    return .{
        .tenant_scope_sha256 = tenant_scope_sha256,
        .entry_count = entry_count,
        .payload_bytes = payload_bytes,
        .encoded_bytes = @intCast(encoded.len),
        .body_sha256 = body_sha256,
        .encoded_sha256 = encoded_sha256,
        .snapshot_sha256 = snapshot_sha256,
    };
}

fn bodyRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(body_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn entryOrder(
    a: bundle.BlobRefV1,
    b: bundle.BlobRefV1,
) std.math.Order {
    const digest_order = std.mem.order(u8, &a.sha256, &b.sha256);
    if (digest_order != .eq) return digest_order;
    return std.math.order(a.byte_length, b.byte_length);
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    @memcpy(output[offset .. offset + bytes.len], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    var bytes: [8]u8 = undefined;
    @memcpy(&bytes, input[offset .. offset + bytes.len]);
    return std.mem.readInt(u64, &bytes, .little);
}

fn hashU64(hash: anytype, value: u64) void {
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
    const a_end = std.math.add(usize, a_start, a.len) catch return true;
    const b_end = std.math.add(usize, b_start, b.len) catch return true;
    return a_start < b_end and b_start < a_end;
}

test "payload snapshot round trips and predicts exact reclaim without mutation" {
    const tenant = [_]u8{0x6d} ** 32;
    const payloads = [_][]const u8{
        "payload-alpha",
        "payload-beta-beta",
        "payload-gamma-gamma-gamma",
    };
    var inputs: [payloads.len]EntryInputV1 = undefined;
    for (payloads, 0..) |payload, index| {
        inputs[index] = .{
            .reference = try bundle.blobRefV1(tenant, payload),
            .payload = payload,
        };
    }
    sortEntriesV1(&inputs);
    var active_storage: [512]u8 = undefined;
    const active = try encodeSnapshotV1(tenant, &inputs, &active_storage);
    var decoded_entries: [default_capacity]EntryViewV1 = undefined;
    const snapshot = try decodeSnapshotV1(
        active,
        tenant,
        &decoded_entries,
    );
    try std.testing.expectEqual(@as(u64, 3), snapshot.entry_count);
    try std.testing.expectEqual(@as(u64, 55), snapshot.payload_bytes);

    var targets = [_]bundle.BlobRefV1{inputs[1].reference};
    object_store.sortRootReferencesV1(&targets);
    var candidate_storage: [512]u8 = undefined;
    const preview = try previewReclaimV1(
        active,
        tenant,
        &targets,
        &candidate_storage,
    );
    try verifyReclaimPreviewV1(preview);
    try std.testing.expectEqual(@as(u64, 3), preview.before.entry_count);
    try std.testing.expectEqual(@as(u64, 2), preview.after.entry_count);
    try std.testing.expectEqual(
        inputs[1].reference.byte_length,
        preview.freed_payload_bytes,
    );
    var active_after: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(active, &active_after, .{});
    try std.testing.expectEqualSlices(
        u8,
        &snapshot.encoded_sha256,
        &active_after,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &preview.before.snapshot_sha256,
        &preview.after.snapshot_sha256,
    ));
    const actual = .{
        std.fmt.bytesToHex(snapshot.encoded_sha256, .lower),
        std.fmt.bytesToHex(preview.before.snapshot_sha256, .lower),
        std.fmt.bytesToHex(preview.targets_sha256, .lower),
        std.fmt.bytesToHex(preview.after.snapshot_sha256, .lower),
        std.fmt.bytesToHex(preview.preview_sha256, .lower),
    };
    try std.testing.expectEqualStrings(
        "9399cdbed8b404f99452d389e42cf911" ++
            "69f5754fd434039144267bad493040e8",
        &actual[0],
    );
    try std.testing.expectEqualStrings(
        "273c8764ec1a383b4c6b613c4ba5cac" ++
            "bc4f84537fcd83a9ef258c268e1085f97",
        &actual[1],
    );
    try std.testing.expectEqualStrings(
        "3401de400d1a47621ed276440d83fb915" ++
            "391363635e31c8ee1d80a66846e4432",
        &actual[2],
    );
    try std.testing.expectEqualStrings(
        "20175ca9739aa818bc006a6aec42cb9b" ++
            "37c25356f75d478c782dbcc34ae2c189",
        &actual[3],
    );
    try std.testing.expectEqualStrings(
        "175dd88fd650ebcb22b437d58f976443" ++
            "fe97bc8a5931bbba850b19cd0b23f533",
        &actual[4],
    );
}

test "payload snapshot rejects mutations foreign tenants and invalid targets" {
    const tenant = [_]u8{0x6d} ** 32;
    const payload = "payload";
    var input = [_]EntryInputV1{.{
        .reference = try bundle.blobRefV1(tenant, payload),
        .payload = payload,
    }};
    var storage: [256]u8 = undefined;
    const encoded = try encodeSnapshotV1(tenant, &input, &storage);
    var views: [default_capacity]EntryViewV1 = undefined;
    try std.testing.expectError(
        Error.TenantScopeMismatch,
        decodeSnapshotV1(encoded, [_]u8{0x7d} ** 32, &views),
    );
    var mutated_storage: [256]u8 = undefined;
    @memcpy(mutated_storage[0..encoded.len], encoded);
    mutated_storage[header_bytes + entry_header_bytes] ^= 1;
    try std.testing.expectError(
        Error.InvalidPayload,
        decodeSnapshotV1(
            mutated_storage[0..encoded.len],
            tenant,
            &views,
        ),
    );
    var candidate: [256]u8 = undefined;
    var foreign_target = [_]bundle.BlobRefV1{try bundle.blobRefV1(
        tenant,
        "foreign",
    )};
    object_store.sortRootReferencesV1(&foreign_target);
    try std.testing.expectError(
        Error.TargetNotFound,
        previewReclaimV1(
            encoded,
            tenant,
            &foreign_target,
            &candidate,
        ),
    );

    var overlap_storage: [256]u8 = undefined;
    @memcpy(overlap_storage[0..encoded.len], encoded);
    const overlap_before = overlap_storage;
    var exact_target = [_]bundle.BlobRefV1{input[0].reference};
    object_store.sortRootReferencesV1(&exact_target);
    try std.testing.expectError(
        Error.UnsafeDestination,
        previewReclaimV1(
            overlap_storage[0..encoded.len],
            tenant,
            &exact_target,
            &overlap_storage,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &overlap_before,
        &overlap_storage,
    );

    input[0].payload = "changed";
    var untouched = [_]u8{0xa5} ** 256;
    try std.testing.expectError(
        Error.InvalidPayload,
        encodeSnapshotV1(tenant, &input, &untouched),
    );
    try std.testing.expect(std.mem.allEqual(u8, &untouched, 0xa5));
}
