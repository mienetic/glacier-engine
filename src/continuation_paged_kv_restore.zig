//! Portable paged-KV page images and checkpoint remap under reacquired
//! continuation ownership.
//!
//! Source cache/page generations are evidence, never live target authority.
//! Restore verifies the complete source ownership chain, materializes pages
//! into a new cache instance, and commits the already charged ownership batch
//! only after every canonical image matches its durable payload entry.

const std = @import("std");
const core = @import("core");
const bundle = core.continuation_bundle;
const capsule = core.continuation_capsule;
const ownership = core.continuation_ownership_manifest;
const payload_store = core.continuation_object_payload_store;
const resource_bank = core.resource_bank;
const paged_kv = @import("paged_kv_cache.zig");

pub const Digest = [32]u8;
pub const page_image_abi: u64 = 0x4743_4b50_0000_0001;
pub const page_image_magic = [_]u8{
    'G', 'C', 'K', 'V', 'P', 'G', '0', '1',
};
pub const page_image_header_bytes: usize = 208;
pub const page_image_footer_bytes: usize = 32;
pub const page_image_allowed_flags: u32 = 0;

const page_image_domain =
    "glacier-continuation-paged-kv-page-image-v1\x00";

pub const Error = ownership.Error || paged_kv.Error || bundle.Error || error{
    ArithmeticOverflow,
    ForeignCheckpoint,
    InvalidPageImage,
    InvalidRestorePlan,
    PageImageNotDurable,
    UnsafeDestination,
};

pub const PageImageV1 = struct {
    source_root: paged_kv.PageMapRootV1,
    num_layers: usize,
    dim: usize,
    max_seq: usize,
    source_ref: paged_kv.PageRefV1,
    committed_rows: usize,
    payload_element_count: usize,
    canonical_f32_le: []const u8,
    challenge_sha256: Digest,
    image_sha256: Digest,
};

pub const PageImageInputV1 = struct {
    source_root: paged_kv.PageMapRootV1,
    num_layers: usize,
    dim: usize,
    max_seq: usize,
    source_ref: paged_kv.PageRefV1,
    committed_rows: usize,
    canonical_f32_le: []const u8,
    challenge_sha256: Digest,
};

pub const RestoredPagedKvV1 = struct {
    ownership_state: ownership.ActiveReacquireV1,
    cache: paged_kv.PagedKVCache,
    restore: paged_kv.CheckpointRestoreV1,
    target_refs: [ownership.max_allocations]paged_kv.PageRefV1,
    page_count: usize,
};

pub fn encodedPageImageBytesV1(
    num_layers: usize,
    dim: usize,
    committed_rows: usize,
) Error!usize {
    if (num_layers == 0 or dim == 0 or committed_rows == 0 or
        committed_rows > paged_kv.page_positions)
        return Error.InvalidPageImage;
    const elements = std.math.mul(
        usize,
        std.math.mul(
            usize,
            std.math.mul(usize, num_layers, 2) catch
                return Error.ArithmeticOverflow,
            committed_rows,
        ) catch return Error.ArithmeticOverflow,
        dim,
    ) catch return Error.ArithmeticOverflow;
    const payload_bytes = std.math.mul(
        usize,
        elements,
        @sizeOf(f32),
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        page_image_header_bytes + page_image_footer_bytes,
        payload_bytes,
    ) catch return Error.ArithmeticOverflow;
}

/// Encode caller-owned canonical f32 bytes. The source root chain is verified
/// when all page images are restored together.
pub fn encodeCanonicalPageImageV1(
    input: PageImageInputV1,
    output: []u8,
) Error![]const u8 {
    const required = try encodedPageImageBytesV1(
        input.num_layers,
        input.dim,
        input.committed_rows,
    );
    if (output.len < required) return Error.CapacityExceeded;
    const payload_element_count =
        (required - page_image_header_bytes - page_image_footer_bytes) /
        @sizeOf(f32);
    if (input.canonical_f32_le.len !=
        payload_element_count * @sizeOf(f32) or
        input.source_root.abi_version != paged_kv.page_map_root_abi or
        input.source_root.cache_instance == 0 or
        input.source_root.generation == 0 or
        input.source_root.committed_len == 0 or
        input.source_root.committed_len > input.max_seq or
        input.source_root.committed_pages == 0 or
        input.source_ref.abi_version != paged_kv.page_ref_abi or
        input.source_ref.cache_instance !=
            input.source_root.cache_instance or
        input.source_ref.logical_page >=
            input.source_root.committed_pages or
        input.source_ref.ownership_generation == 0 or
        input.committed_rows != expectedRowsV1(
            input.source_root,
            input.source_ref.logical_page,
        ) or
        isZero(input.source_root.ownership_sha256) or
        isZero(input.challenge_sha256))
        return Error.InvalidPageImage;
    const expected_pages = input.source_root.committed_len /
        paged_kv.page_positions +
        @intFromBool(
            input.source_root.committed_len %
                paged_kv.page_positions != 0,
        );
    if (input.source_root.committed_pages != expected_pages)
        return Error.InvalidPageImage;
    if (slicesOverlap(
        output[0..required],
        input.canonical_f32_le,
    )) return Error.UnsafeDestination;

    var writer: Writer = .{ .bytes = output[0..required] };
    try writer.writeBytes(&page_image_magic);
    try writer.writeU64(page_image_abi);
    try writer.writeU64(required);
    try writer.writeU32(page_image_allowed_flags);
    try writer.writeU32(0);
    try writer.writePageRoot(input.source_root);
    try writer.writeU64(input.num_layers);
    try writer.writeU64(input.dim);
    try writer.writeU64(input.max_seq);
    try writer.writePageRef(input.source_ref);
    try writer.writeU64(input.committed_rows);
    try writer.writeU64(payload_element_count);
    try writer.writeDigest(input.challenge_sha256);
    if (writer.position != page_image_header_bytes)
        return Error.InvalidLength;
    try writer.writeBytes(input.canonical_f32_le);
    try writer.writeDigest(pageImageRootV1(
        output[0 .. required - page_image_footer_bytes],
    ));
    if (writer.position != required) return Error.InvalidLength;
    return output[0..required];
}

/// Encode one committed source page without padded/uninitialized rows.
/// Callers must provide exclusive read access to the cache during this call.
pub fn encodePageImageV1(
    cache: *const paged_kv.PagedKVCache,
    logical_page: usize,
    challenge_sha256: Digest,
    output: []u8,
) Error![]const u8 {
    if (isZero(challenge_sha256)) return Error.InvalidPageImage;
    const source_root = cache.root();
    try cache.validateCurrentRoot(source_root);
    if (logical_page >= source_root.committed_pages)
        return Error.InvalidPageImage;
    const logical_start = std.math.mul(
        usize,
        logical_page,
        paged_kv.page_positions,
    ) catch return Error.ArithmeticOverflow;
    const committed_len = std.math.cast(
        usize,
        source_root.committed_len,
    ) orelse return Error.InvalidPageImage;
    if (logical_start >= committed_len) return Error.InvalidPageImage;
    const committed_rows = @min(
        paged_kv.page_positions,
        committed_len - logical_start,
    );
    const required = try encodedPageImageBytesV1(
        cache.num_layers,
        cache.dim,
        committed_rows,
    );
    if (output.len < required) return Error.CapacityExceeded;
    const source_ref = try sourcePageRefV1(cache, logical_page);

    for (0..cache.num_layers) |layer| {
        const prefix = try cache.committedPrefix(layer);
        for (logical_start..logical_start + committed_rows) |position| {
            const key = try prefix.keyRow(position);
            const value = try prefix.valueRow(position);
            if (slicesOverlap(
                output[0..required],
                std.mem.sliceAsBytes(key),
            ) or slicesOverlap(
                output[0..required],
                std.mem.sliceAsBytes(value),
            )) return Error.UnsafeDestination;
        }
    }

    var writer: Writer = .{ .bytes = output[0..required] };
    try writer.writeBytes(&page_image_magic);
    try writer.writeU64(page_image_abi);
    try writer.writeU64(required);
    try writer.writeU32(page_image_allowed_flags);
    try writer.writeU32(0);
    try writer.writePageRoot(source_root);
    try writer.writeU64(cache.num_layers);
    try writer.writeU64(cache.dim);
    try writer.writeU64(cache.max_seq);
    try writer.writePageRef(source_ref);
    try writer.writeU64(committed_rows);
    const payload_element_count =
        (required - page_image_header_bytes - page_image_footer_bytes) /
        @sizeOf(f32);
    try writer.writeU64(payload_element_count);
    try writer.writeDigest(challenge_sha256);
    if (writer.position != page_image_header_bytes)
        return Error.InvalidLength;

    for (0..cache.num_layers) |layer| {
        const prefix = try cache.committedPrefix(layer);
        inline for (.{ false, true }) |is_value| {
            for (logical_start..logical_start + committed_rows) |position| {
                const row = if (is_value)
                    try prefix.valueRow(position)
                else
                    try prefix.keyRow(position);
                for (row) |value|
                    try writer.writeU32(@bitCast(value));
            }
        }
    }
    if (writer.position != required - page_image_footer_bytes)
        return Error.InvalidLength;
    try writer.writeDigest(pageImageRootV1(
        output[0 .. required - page_image_footer_bytes],
    ));
    if (writer.position != required) return Error.InvalidLength;
    return output[0..required];
}

pub fn decodePageImageV1(
    encoded: []const u8,
    expected_challenge_sha256: Digest,
) Error!PageImageV1 {
    if (encoded.len < page_image_header_bytes + page_image_footer_bytes)
        return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(
        u8,
        try reader.readBytes(page_image_magic.len),
        &page_image_magic,
    )) return Error.InvalidMagic;
    if (try reader.readU64() != page_image_abi) return Error.InvalidAbi;
    if (try reader.readU64() != encoded.len) return Error.InvalidLength;
    if (try reader.readU32() != page_image_allowed_flags or
        try reader.readU32() != 0)
        return Error.InvalidFlags;
    const source_root = try reader.readPageRoot();
    const num_layers = std.math.cast(usize, try reader.readU64()) orelse
        return Error.InvalidPageImage;
    const dim = std.math.cast(usize, try reader.readU64()) orelse
        return Error.InvalidPageImage;
    const max_seq = std.math.cast(usize, try reader.readU64()) orelse
        return Error.InvalidPageImage;
    const source_ref = try reader.readPageRef();
    const committed_rows = std.math.cast(
        usize,
        try reader.readU64(),
    ) orelse return Error.InvalidPageImage;
    const payload_element_count = std.math.cast(
        usize,
        try reader.readU64(),
    ) orelse return Error.InvalidPageImage;
    const challenge_sha256 = try reader.readDigest();
    if (reader.position != page_image_header_bytes)
        return Error.InvalidLength;

    const required = try encodedPageImageBytesV1(
        num_layers,
        dim,
        committed_rows,
    );
    if (encoded.len != required) return Error.InvalidLength;
    const payload_bytes = std.math.mul(
        usize,
        payload_element_count,
        @sizeOf(f32),
    ) catch return Error.ArithmeticOverflow;
    if (payload_bytes !=
        encoded.len - page_image_header_bytes - page_image_footer_bytes)
        return Error.InvalidPageImage;
    const canonical_f32_le = try reader.readBytes(payload_bytes);
    const image_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or
        !std.mem.eql(
            u8,
            &image_sha256,
            &pageImageRootV1(
                encoded[0 .. encoded.len - page_image_footer_bytes],
            ),
        ))
        return Error.InvalidPageImage;

    const expected_pages = source_root.committed_len /
        paged_kv.page_positions +
        @intFromBool(
            source_root.committed_len % paged_kv.page_positions != 0,
        );
    if (source_root.abi_version != paged_kv.page_map_root_abi or
        source_root.cache_instance == 0 or source_root.generation == 0 or
        source_root.committed_len == 0 or
        source_root.committed_len > max_seq or
        source_root.committed_pages == 0 or
        source_root.committed_pages != expected_pages or
        isZero(source_root.ownership_sha256) or
        source_ref.abi_version != paged_kv.page_ref_abi or
        source_ref.cache_instance != source_root.cache_instance or
        source_ref.logical_page >= source_root.committed_pages or
        source_ref.ownership_generation == 0 or
        num_layers == 0 or dim == 0 or max_seq == 0 or
        committed_rows != expectedRowsV1(source_root, source_ref.logical_page) or
        isZero(expected_challenge_sha256) or
        !std.mem.eql(
            u8,
            &challenge_sha256,
            &expected_challenge_sha256,
        ))
        return Error.InvalidPageImage;
    const expected_elements = std.math.mul(
        usize,
        std.math.mul(
            usize,
            std.math.mul(usize, num_layers, 2) catch
                return Error.ArithmeticOverflow,
            committed_rows,
        ) catch return Error.ArithmeticOverflow,
        dim,
    ) catch return Error.ArithmeticOverflow;
    if (payload_element_count != expected_elements)
        return Error.InvalidPageImage;
    return .{
        .source_root = source_root,
        .num_layers = num_layers,
        .dim = dim,
        .max_seq = max_seq,
        .source_ref = source_ref,
        .committed_rows = committed_rows,
        .payload_element_count = payload_element_count,
        .canonical_f32_le = canonical_f32_le,
        .challenge_sha256 = challenge_sha256,
        .image_sha256 = image_sha256,
    };
}

/// Materialize every durable page under an already prepared ownership batch.
/// Any failure before the final Bank commit deinitializes the private cache and
/// leaves the ownership batch pending for retry or explicit abort.
pub fn restoreAndCommitV1(
    allocator: std.mem.Allocator,
    bank: *resource_bank.Bank,
    prepared: ownership.PreparedReacquireV1,
    manifest_wire: []const u8,
    payload_snapshot_wire: []const u8,
    page_images: []const []const u8,
) Error!RestoredPagedKvV1 {
    const manifest = try ownership.decodeV1(manifest_wire);
    if (!std.meta.eql(manifest, prepared.manifest) or
        page_images.len == 0 or
        page_images.len != manifest.allocation_count)
        return Error.InvalidRestorePlan;

    var payload_entries: [payload_store.default_capacity]payload_store.EntryViewV1 = undefined;
    const payload_snapshot = try payload_store.decodeSnapshotV1(
        payload_snapshot_wire,
        manifest.tenant_scope_sha256,
        &payload_entries,
    );
    if (!std.mem.eql(
        u8,
        &payload_snapshot.snapshot_sha256,
        &manifest.payload_snapshot_sha256,
    )) return Error.InvalidRestorePlan;

    var checkpoint_pages: [ownership.max_allocations]paged_kv.CheckpointPageV1 = undefined;
    var materialized: [ownership.max_allocations]ownership.MaterializedObjectV1 = undefined;
    var source_root: paged_kv.PageMapRootV1 = undefined;
    var num_layers: usize = 0;
    var dim: usize = 0;
    var max_seq: usize = 0;
    for (page_images, 0..) |wire, index| {
        const allocation = manifest.allocations[index];
        if (allocation.kind != .kv_page or
            allocation.object_byte_length != wire.len or
            !claimOnlyKv(allocation.claim))
            return Error.InvalidRestorePlan;
        const image = try decodePageImageV1(
            wire,
            manifest.challenge_sha256,
        );
        if (image.source_ref.logical_page != index)
            return Error.InvalidRestorePlan;
        if (index == 0) {
            source_root = image.source_root;
            num_layers = image.num_layers;
            dim = image.dim;
            max_seq = image.max_seq;
        } else if (!std.meta.eql(source_root, image.source_root) or
            num_layers != image.num_layers or dim != image.dim or
            max_seq != image.max_seq)
            return Error.ForeignCheckpoint;
        try requireDurablePageV1(
            wire,
            manifest.tenant_scope_sha256,
            payload_entries[0..@intCast(payload_snapshot.entry_count)],
        );
        checkpoint_pages[index] = .{
            .source_ref = image.source_ref,
            .committed_rows = image.committed_rows,
            .canonical_f32_le = image.canonical_f32_le,
        };
        materialized[index] = .{ .kind = .kv_page, .bytes = wire };
    }

    const ledger = try paged_kv.deriveCapacityLedger(
        num_layers,
        dim,
        max_seq,
    );
    if (manifest.parent_claim.kv_bytes != ledger.page_map_bytes or
        source_root.committed_pages != page_images.len)
        return Error.InvalidRestorePlan;
    for (manifest.allocations[0..manifest.allocation_count]) |allocation| {
        if (allocation.claim.kv_bytes != ledger.page_payload_bytes)
            return Error.InvalidRestorePlan;
    }

    var cache = try paged_kv.PagedKVCache.initForCheckpoint(
        allocator,
        num_layers,
        dim,
        max_seq,
        source_root.cache_instance,
    );
    errdefer cache.deinit();
    var target_refs: [ownership.max_allocations]paged_kv.PageRefV1 = undefined;
    const restore = try cache.restoreCheckpointV1(
        source_root,
        checkpoint_pages[0..page_images.len],
        target_refs[0..page_images.len],
    );
    const ownership_state = ownership.commitMaterializedV1(
        bank,
        prepared,
        manifest_wire,
        materialized[0..page_images.len],
    ) catch |err| {
        cache.discardRestoredCheckpointV1(restore.target_root) catch {};
        return err;
    };
    return .{
        .ownership_state = ownership_state,
        .cache = cache,
        .restore = restore,
        .target_refs = target_refs,
        .page_count = page_images.len,
    };
}

pub fn pageImageRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(page_image_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn sourcePageRefV1(
    cache: *const paged_kv.PagedKVCache,
    logical_page: usize,
) Error!paged_kv.PageRefV1 {
    var iterator = (try cache.committedPrefix(0)).iterator() catch
        return Error.InvalidPageImage;
    while (try iterator.next()) |span| {
        if (span.page_ref.logical_page == logical_page)
            return span.page_ref;
    }
    return Error.InvalidPageImage;
}

fn expectedRowsV1(
    root: paged_kv.PageMapRootV1,
    logical_page: u64,
) usize {
    const start = logical_page * paged_kv.page_positions;
    const remaining = root.committed_len - start;
    return @intCast(@min(remaining, paged_kv.page_positions));
}

fn requireDurablePageV1(
    wire: []const u8,
    tenant_scope_sha256: Digest,
    entries: []const payload_store.EntryViewV1,
) Error!void {
    const reference = try bundle.blobRefV1(tenant_scope_sha256, wire);
    for (entries) |entry| {
        if (std.meta.eql(reference, entry.reference) and
            std.mem.eql(u8, wire, entry.payload))
            return;
    }
    return Error.PageImageNotDurable;
}

fn claimOnlyKv(claim: resource_bank.Claim) bool {
    return claim.kv_bytes != 0 and
        claim.capsule_bytes == 0 and
        claim.activation_bytes == 0 and
        claim.partial_bytes == 0 and
        claim.logits_bytes == 0 and
        claim.output_journal_bytes == 0 and
        claim.staging_bytes == 0 and
        claim.device_bytes == 0 and
        claim.io_bytes == 0 and
        claim.queue_slots == 0;
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(usize, a_start, a.len) catch
        std.math.maxInt(usize);
    const b_end = std.math.add(usize, b_start, b.len) catch
        std.math.maxInt(usize);
    return a_start < b_end and b_start < a_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(usize, self.position, value.len) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        @memcpy(self.bytes[self.position..end], value);
        self.position = end;
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: anytype) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(value), .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }

    fn writePageRoot(
        self: *Writer,
        value: paged_kv.PageMapRootV1,
    ) Error!void {
        try self.writeU64(value.abi_version);
        try self.writeU64(value.cache_instance);
        try self.writeU64(value.generation);
        try self.writeU64(value.committed_len);
        try self.writeU64(value.committed_pages);
        try self.writeDigest(value.ownership_sha256);
    }

    fn writePageRef(
        self: *Writer,
        value: paged_kv.PageRefV1,
    ) Error!void {
        try self.writeU64(value.abi_version);
        try self.writeU64(value.cache_instance);
        try self.writeU64(value.logical_page);
        try self.writeU64(value.ownership_generation);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        const end = std.math.add(usize, self.position, length) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        const value = self.bytes[self.position..end];
        self.position = end;
        return value;
    }

    fn readU32(self: *Reader) Error!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(value.len));
        return value;
    }

    fn readPageRoot(self: *Reader) Error!paged_kv.PageMapRootV1 {
        return .{
            .abi_version = try self.readU64(),
            .cache_instance = try self.readU64(),
            .generation = try self.readU64(),
            .committed_len = try self.readU64(),
            .committed_pages = try self.readU64(),
            .ownership_sha256 = try self.readDigest(),
        };
    }

    fn readPageRef(self: *Reader) Error!paged_kv.PageRefV1 {
        return .{
            .abi_version = try self.readU64(),
            .cache_instance = try self.readU64(),
            .logical_page = try self.readU64(),
            .ownership_generation = try self.readU64(),
        };
    }
};

test "paged KV page image is canonical and mutation complete" {
    const challenge_sha256 = filledDigest(0x61);
    const source_ref: paged_kv.PageRefV1 = .{
        .cache_instance = 501,
        .logical_page = 0,
        .ownership_generation = 9,
    };
    const empty_ownership = try paged_kv.checkpointEmptyOwnershipDigestV1(
        501,
        2,
        2,
        32,
    );
    const source_root: paged_kv.PageMapRootV1 = .{
        .cache_instance = 501,
        .generation = 8,
        .committed_len = 16,
        .committed_pages = 1,
        .ownership_sha256 = try paged_kv.checkpointAppendOwnershipDigestV1(
            empty_ownership,
            source_ref,
        ),
    };
    var canonical_payload: [512]u8 = undefined;
    for (0..canonical_payload.len / 4) |index| {
        const value: f32 = @floatFromInt(index);
        std.mem.writeInt(
            u32,
            canonical_payload[index * 4 ..][0..4],
            @bitCast(value),
            .little,
        );
    }
    var encoded_storage: [752]u8 = undefined;
    const encoded = try encodeCanonicalPageImageV1(.{
        .source_root = source_root,
        .num_layers = 2,
        .dim = 2,
        .max_seq = 32,
        .source_ref = source_ref,
        .committed_rows = 16,
        .canonical_f32_le = &canonical_payload,
        .challenge_sha256 = challenge_sha256,
    }, &encoded_storage);
    const decoded = try decodePageImageV1(encoded, challenge_sha256);
    var golden_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &golden_root,
        "e052306f36ef24b9b92f7f0ef505045e" ++
            "a25fddf7bdf8f4c9e81b96733437d1e4",
    );
    try std.testing.expectEqualSlices(
        u8,
        &golden_root,
        &decoded.image_sha256,
    );
    try std.testing.expectEqual(@as(usize, 128), decoded.payload_element_count);
    try std.testing.expectEqualSlices(
        u8,
        &canonical_payload,
        decoded.canonical_f32_le,
    );

    var corrupted: [752]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodePageImageV1(
            &corrupted,
            challenge_sha256,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }
    @memcpy(&corrupted, encoded);
    std.mem.writeInt(u32, corrupted[28..32], 1, .little);
    const rerooted = pageImageRootV1(
        corrupted[0 .. corrupted.len - page_image_footer_bytes],
    );
    @memcpy(
        corrupted[corrupted.len - page_image_footer_bytes ..],
        &rerooted,
    );
    try std.testing.expectError(
        Error.InvalidFlags,
        decodePageImageV1(&corrupted, challenge_sha256),
    );
}

test "paged KV checkpoint remaps generations only after durable ownership" {
    const allocator = std.testing.allocator;
    var source_cache = try paged_kv.PagedKVCache.init(
        allocator,
        2,
        2,
        32,
    );
    defer source_cache.deinit();
    for (0..17) |position|
        try appendFixtureRowV1(&source_cache, position);
    const source_root = source_cache.root();
    const source_logical_sha256 = try source_cache.logicalKvSha256();

    const tenant_scope_sha256 = filledDigest(0x71);
    const challenge_sha256 = filledDigest(0x72);
    var page_zero_storage: [1024]u8 = undefined;
    const page_zero = try encodePageImageV1(
        &source_cache,
        0,
        challenge_sha256,
        &page_zero_storage,
    );
    var page_one_storage: [1024]u8 = undefined;
    const page_one = try encodePageImageV1(
        &source_cache,
        1,
        challenge_sha256,
        &page_one_storage,
    );
    const page_wires = [_][]const u8{ page_zero, page_one };

    var payload_inputs = [_]payload_store.EntryInputV1{
        .{
            .reference = try bundle.blobRefV1(
                tenant_scope_sha256,
                page_zero,
            ),
            .payload = page_zero,
        },
        .{
            .reference = try bundle.blobRefV1(
                tenant_scope_sha256,
                page_one,
            ),
            .payload = page_one,
        },
    };
    payload_store.sortEntriesV1(&payload_inputs);
    var payload_storage: [2048]u8 = undefined;
    const payload_wire = try payload_store.encodeSnapshotV1(
        tenant_scope_sha256,
        &payload_inputs,
        &payload_storage,
    );
    var payload_entries: [payload_store.default_capacity]payload_store.EntryViewV1 = undefined;
    const payload_snapshot = try payload_store.decodeSnapshotV1(
        payload_wire,
        tenant_scope_sha256,
        &payload_entries,
    );

    const ledger = source_cache.capacityLedger();
    const page_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_payload_bytes),
    };
    const tree_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_payload_bytes * 2),
    };
    const parent_claim: resource_bank.Claim = .{
        .kv_bytes = @intCast(ledger.page_map_bytes),
    };
    var source_slots = [_]resource_bank.Slot{.{}};
    var source_bank = try resource_bank.Bank.init(
        &source_slots,
        .{},
        71,
    );
    const source_receipt = try source_bank.commit(
        try source_bank.reserve(9001, parent_claim),
    );
    const scopes = [_]ownership.ScopeInputV1{.{
        .scope_key = 9100,
        .tenant_key = 9200,
        .ceiling = tree_claim,
    }};
    const allocations = [_]ownership.AllocationInputV1{
        .{
            .scope_ordinal = 0,
            .node_key = 9300,
            .binding_key = 9400,
            .kind = .kv_page,
            .claim = page_claim,
            .object_bytes = page_zero,
        },
        .{
            .scope_ordinal = 0,
            .node_key = 9301,
            .binding_key = 9401,
            .kind = .kv_page,
            .claim = page_claim,
            .object_bytes = page_one,
        },
    };
    var manifest_storage: [ownership.encoded_bytes]u8 = undefined;
    const manifest_wire = try ownership.encodeV1(.{
        .source_bank_epoch = source_receipt.bank_epoch,
        .source_receipt_generation = source_receipt.generation,
        .restore_bank_epoch = 72,
        .request_epoch = 101,
        .publication_next_sequence = 18,
        .checkpoint_generation = 3,
        .owner_key = source_receipt.owner_key,
        .tree_key = 9002,
        .authority_key = 9003,
        .parent_claim = parent_claim,
        .tree_ceiling = tree_claim,
        .tenant_scope_sha256 = tenant_scope_sha256,
        .payload_snapshot_sha256 = payload_snapshot.snapshot_sha256,
        .challenge_sha256 = challenge_sha256,
        .scopes = &scopes,
        .allocations = &allocations,
    }, &manifest_storage);

    const capsule_objects: capsule.ObjectsV1 = .{
        .model = .{ .abi_version = 1, .bytes = "model" },
        .tokenizer = .{ .abi_version = 2, .bytes = "tokenizer" },
        .execution_plan = .{ .abi_version = 3, .bytes = "plan" },
        .resource_state = .{
            .abi_version = ownership.abi_version,
            .bytes = manifest_wire,
        },
        .lane_state = .{ .abi_version = 5, .bytes = "lanes" },
        .kv_state = .{ .abi_version = page_image_abi, .bytes = "paged-kv" },
        .sampler_state = .{ .abi_version = 7, .bytes = "sampler" },
        .output_state = .{ .abi_version = 8, .bytes = "output" },
        .publication_receipt = .{
            .abi_version = 9,
            .bytes = "publication",
        },
    };
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(.{
        .execution_abi = 1,
        .request_epoch = 101,
        .publication_sequence = 18,
        .checkpoint_generation = 3,
        .kv_tokens = 17,
        .output_tokens = 1,
        .challenge_sha256 = challenge_sha256,
        .parent_capsule_sha256 = filledDigest(0x73),
    }, capsule_objects, &capsule_storage);

    var target_slots = [_]resource_bank.Slot{.{}};
    var target_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var target_nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 3;
    var target_bank = try resource_bank.Bank.initWithLeaseTree(
        &target_slots,
        &target_roots,
        &target_nodes,
        .{
            .host_bytes = @intCast(
                ledger.page_map_bytes + ledger.page_payload_bytes * 2,
            ),
            .kv_bytes = @intCast(
                ledger.page_map_bytes + ledger.page_payload_bytes * 2,
            ),
        },
        72,
    );
    const prepared = try ownership.prepareReacquireV1(
        &target_bank,
        capsule_wire,
        manifest_wire,
        payload_wire,
        0x4321,
    );
    try std.testing.expectError(
        resource_bank.Error.InvalidTransition,
        target_bank.beginPublicationWithLeaseTree(
            prepared.tree,
            101,
            0x4321,
            18,
        ),
    );

    const image_zero = try decodePageImageV1(
        page_zero,
        challenge_sha256,
    );
    const image_one = try decodePageImageV1(
        page_one,
        challenge_sha256,
    );
    var foreign_pages = [_]paged_kv.CheckpointPageV1{
        .{
            .source_ref = image_zero.source_ref,
            .committed_rows = image_zero.committed_rows,
            .canonical_f32_le = image_zero.canonical_f32_le,
        },
        .{
            .source_ref = image_one.source_ref,
            .committed_rows = image_one.committed_rows,
            .canonical_f32_le = image_one.canonical_f32_le,
        },
    };
    foreign_pages[0].source_ref.ownership_generation += 1;
    var probe_cache = try paged_kv.PagedKVCache.init(
        allocator,
        2,
        2,
        32,
    );
    defer probe_cache.deinit();
    var probe_refs: [2]paged_kv.PageRefV1 = undefined;
    try std.testing.expectError(
        paged_kv.Error.InvalidCheckpoint,
        probe_cache.restoreCheckpointV1(
            source_root,
            &foreign_pages,
            &probe_refs,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), probe_cache.root().committed_len);
    try std.testing.expectEqual(
        @as(usize, 0),
        (try probe_cache.allocationCommitmentLedger()).allocated_pages,
    );

    var restored = try restoreAndCommitV1(
        allocator,
        &target_bank,
        prepared,
        manifest_wire,
        payload_wire,
        &page_wires,
    );
    try std.testing.expect(
        restored.restore.source_root.cache_instance !=
            restored.restore.target_root.cache_instance,
    );
    try std.testing.expectEqual(
        source_root.committed_len,
        restored.restore.target_root.committed_len,
    );
    try std.testing.expectEqualSlices(
        u8,
        &source_logical_sha256,
        &(try restored.cache.logicalKvSha256()),
    );
    for (0..restored.page_count) |index| {
        try restored.cache.validateCommittedPageRef(
            restored.target_refs[index],
        );
        try std.testing.expectError(
            paged_kv.Error.InvalidPageRef,
            restored.cache.validateCommittedPageRef(
                if (index == 0)
                    image_zero.source_ref
                else
                    image_one.source_ref,
            ),
        );
    }
    const permit = try target_bank.beginPublicationWithLeaseTree(
        restored.ownership_state.tree,
        101,
        0x4321,
        18,
    );
    try target_bank.abortPublication(permit);

    const retiring = try target_bank.beginRetireSubtreeForSession(
        restored.ownership_state.tree,
        restored.ownership_state.scopes[0],
        101,
        0x4321,
        18,
    );
    const authorized = try target_bank.authorizeFree(retiring.ticket);
    restored.cache.deinit();
    const empty_tree = try target_bank.commitFreeAfterAllocatorFree(
        authorized.permit,
    );
    try target_bank.closePublicationSession(
        restored.ownership_state.receipt,
        101,
        0x4321,
        18,
    );
    try target_bank.closeLeaseTree(empty_tree);
    try target_bank.release(restored.ownership_state.receipt);
    try std.testing.expect((try target_bank.snapshotV3()).used.isZero());
}

fn appendFixtureRowV1(
    cache: *paged_kv.PagedKVCache,
    position: usize,
) !void {
    const mark = try cache.beginRow();
    for (0..cache.num_layers) |layer| {
        const base: f32 = @floatFromInt(position * 100 + layer * 10);
        const key = [_]f32{ base + 1, base + 2 };
        const value = [_]f32{ base + 3, base + 4 };
        _ = try cache.appendRowTxn(mark, layer, &key, &value);
    }
    try cache.commitRowTxn(mark);
}

fn filledDigest(value: u8) Digest {
    return [_]u8{value} ** 32;
}
