//! Bounded tenant-scoped in-memory store for continuation bundle objects.
//!
//! The store owns immutable payload copies through a caller-supplied allocator,
//! keeps its index in a fixed-capacity slot array, reuses equal tenant blob
//! identities without allocating a second payload, and accounts references,
//! payload bytes, and logical index bytes exactly. Bundle import is atomic: a
//! failed allocation or quota check rolls every prior action back in reverse.
//! No filesystem, network, decryption, scheduling, or publication authority is
//! present.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");
const bundle = @import("continuation_bundle.zig");

pub const Digest = capsule.Digest;
pub const zero_digest = capsule.zero_digest;
pub const logical_index_entry_bytes: u64 = 128;
pub const default_capacity: usize = 16;

pub const operation_put: u64 = 1 << 0;
pub const operation_get: u64 = 1 << 1;
pub const operation_release: u64 = 1 << 2;
pub const operation_quarantine: u64 = 1 << 3;
pub const operation_verify: u64 = 1 << 4;
pub const allowed_operations: u64 = operation_put |
    operation_get |
    operation_release |
    operation_quarantine |
    operation_verify;

const grant_domain = "glacier-continuation-store-grant-v1\x00";
const snapshot_domain = "glacier-continuation-store-snapshot-v1\x00";

pub const Error = bundle.Error || std.mem.Allocator.Error || error{
    InvalidGrant,
    StaleGrant,
    DeniedOperation,
    BundleMismatch,
    StoreCapacityExceeded,
    ObjectTooLarge,
    PayloadBudgetExceeded,
    IndexBudgetExceeded,
    ReferenceBudgetExceeded,
    BlobMismatch,
    DigestCollision,
    NotFound,
    Quarantined,
    CorruptPayload,
    InsufficientDestination,
    UnsafeDestination,
    InvalidProvenance,
    InvalidQuarantineReason,
    StoreClosed,
    InvalidAccounting,
};

pub const GrantV1 = struct {
    authority_epoch: u64,
    tenant_scope_sha256: Digest,
    bundle_sha256: Digest,
    allowed_operation_mask: u64,
    max_entries: u64,
    max_object_bytes: u64,
    max_payload_bytes: u64,
    max_index_bytes: u64,
    max_references: u64,
    challenge_sha256: Digest,
};

pub const EntryState = enum(u64) {
    live = 1,
    quarantined = 2,
};

pub const PutDisposition = enum {
    inserted,
    reused,
};

pub const PutReceiptV1 = struct {
    slot_index: usize,
    disposition: PutDisposition,
    reference_count: u64,
    entry_count_after: u64,
    payload_bytes_after: u64,
};

pub const ImportReceiptV1 = struct {
    bundle_sha256: Digest,
    semantic_references: u64,
    unique_entries_added: u64,
    references_reused: u64,
    payload_bytes_added: u64,
    entry_count_after: u64,
    payload_bytes_after: u64,
    reference_count_after: u64,
    snapshot_sha256: Digest,
};

pub const StatsV1 = struct {
    entry_count: u64,
    live_entries: u64,
    quarantined_entries: u64,
    payload_bytes: u64,
    logical_index_bytes: u64,
    reference_count: u64,
    native_slot_capacity_bytes: u64,
    native_store_bytes: u64,
};

const SlotV1 = struct {
    state: EntryState,
    byte_length: u64,
    sha256: Digest,
    payload: []u8,
    reference_count: u64,
    provenance_sha256: Digest,
    quarantine_reason_sha256: Digest,
};

const ImportAction = struct {
    slot_index: usize,
    inserted: bool,
};

pub fn StoreV1(comptime capacity: usize) type {
    if (capacity == 0) @compileError("store capacity must be nonzero");
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        grant: GrantV1,
        grant_sha256: Digest,
        slots: [capacity]?SlotV1 = [_]?SlotV1{null} ** capacity,
        entry_count: u64 = 0,
        live_entries: u64 = 0,
        quarantined_entries: u64 = 0,
        payload_bytes: u64 = 0,
        logical_index_bytes: u64 = 0,
        reference_count: u64 = 0,
        closed: bool = false,

        pub fn initV1(
            allocator: std.mem.Allocator,
            grant: GrantV1,
            expected_authority_epoch: u64,
        ) Error!Self {
            try validateGrant(grant);
            if (grant.authority_epoch != expected_authority_epoch)
                return Error.StaleGrant;
            if (grant.max_entries > capacity)
                return Error.InvalidGrant;
            return .{
                .allocator = allocator,
                .grant = grant,
                .grant_sha256 = try grantRootV1(grant),
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.closed) return;
            var index = capacity;
            while (index > 0) {
                index -= 1;
                if (self.slots[index]) |slot| {
                    self.allocator.free(slot.payload);
                    self.slots[index] = null;
                }
            }
            self.entry_count = 0;
            self.live_entries = 0;
            self.quarantined_entries = 0;
            self.payload_bytes = 0;
            self.logical_index_bytes = 0;
            self.reference_count = 0;
            self.closed = true;
        }

        pub fn putV1(
            self: *Self,
            expected: bundle.BlobRefV1,
            payload: []const u8,
            provenance_sha256: Digest,
        ) Error!PutReceiptV1 {
            try self.ensureOperation(operation_put);
            if (isZero(provenance_sha256) or !std.mem.eql(
                u8,
                &provenance_sha256,
                &self.grant.bundle_sha256,
            ))
                return Error.InvalidProvenance;
            const computed = bundle.blobRefV1(
                self.grant.tenant_scope_sha256,
                payload,
            ) catch return Error.BlobMismatch;
            if (!std.meta.eql(computed, expected))
                return Error.BlobMismatch;
            if (expected.byte_length > self.grant.max_object_bytes)
                return Error.ObjectTooLarge;

            for (&self.slots, 0..) |*maybe_slot, index| {
                if (maybe_slot.*) |*slot| {
                    if (!std.mem.eql(u8, &slot.sha256, &expected.sha256))
                        continue;
                    if (slot.byte_length != expected.byte_length or
                        !std.mem.eql(u8, slot.payload, payload))
                        return Error.DigestCollision;
                    if (slot.state == .quarantined)
                        return Error.Quarantined;
                    const next_slot_references = std.math.add(
                        u64,
                        slot.reference_count,
                        1,
                    ) catch return Error.ReferenceBudgetExceeded;
                    const next_references = std.math.add(
                        u64,
                        self.reference_count,
                        1,
                    ) catch return Error.ReferenceBudgetExceeded;
                    if (next_references > self.grant.max_references)
                        return Error.ReferenceBudgetExceeded;
                    slot.reference_count = next_slot_references;
                    self.reference_count = next_references;
                    return .{
                        .slot_index = index,
                        .disposition = .reused,
                        .reference_count = next_slot_references,
                        .entry_count_after = self.entry_count,
                        .payload_bytes_after = self.payload_bytes,
                    };
                }
            }

            if (self.entry_count >= self.grant.max_entries)
                return Error.StoreCapacityExceeded;
            const next_index_bytes = std.math.add(
                u64,
                self.logical_index_bytes,
                logical_index_entry_bytes,
            ) catch return Error.IndexBudgetExceeded;
            if (next_index_bytes > self.grant.max_index_bytes)
                return Error.IndexBudgetExceeded;
            const next_payload_bytes = std.math.add(
                u64,
                self.payload_bytes,
                expected.byte_length,
            ) catch return Error.PayloadBudgetExceeded;
            if (next_payload_bytes > self.grant.max_payload_bytes)
                return Error.PayloadBudgetExceeded;
            const next_references = std.math.add(
                u64,
                self.reference_count,
                1,
            ) catch return Error.ReferenceBudgetExceeded;
            if (next_references > self.grant.max_references)
                return Error.ReferenceBudgetExceeded;
            const empty_index = self.firstEmptySlot() orelse
                return Error.StoreCapacityExceeded;
            const payload_length = std.math.cast(
                usize,
                expected.byte_length,
            ) orelse return Error.ObjectTooLarge;
            const owned = try self.allocator.alloc(u8, payload_length);
            errdefer self.allocator.free(owned);
            if (slicesOverlap(owned, payload))
                return Error.UnsafeDestination;
            @memcpy(owned, payload);
            self.slots[empty_index] = .{
                .state = .live,
                .byte_length = expected.byte_length,
                .sha256 = expected.sha256,
                .payload = owned,
                .reference_count = 1,
                .provenance_sha256 = provenance_sha256,
                .quarantine_reason_sha256 = zero_digest,
            };
            self.entry_count += 1;
            self.live_entries += 1;
            self.payload_bytes = next_payload_bytes;
            self.logical_index_bytes = next_index_bytes;
            self.reference_count = next_references;
            return .{
                .slot_index = empty_index,
                .disposition = .inserted,
                .reference_count = 1,
                .entry_count_after = self.entry_count,
                .payload_bytes_after = self.payload_bytes,
            };
        }

        pub fn getV1(
            self: *Self,
            expected: bundle.BlobRefV1,
            destination: []u8,
        ) Error![]const u8 {
            try self.ensureOperation(operation_get);
            const index = self.findExactSlot(expected) orelse
                return Error.NotFound;
            const slot = &self.slots[index].?;
            if (slot.state == .quarantined) return Error.Quarantined;
            const computed = bundle.blobRefV1(
                self.grant.tenant_scope_sha256,
                slot.payload,
            ) catch return Error.CorruptPayload;
            if (!std.meta.eql(computed, expected))
                return Error.CorruptPayload;
            const payload_length = std.math.cast(
                usize,
                expected.byte_length,
            ) orelse return Error.ObjectTooLarge;
            if (destination.len < payload_length)
                return Error.InsufficientDestination;
            const output = destination[0..payload_length];
            if (slicesOverlap(output, std.mem.asBytes(self)) or
                slicesOverlap(output, std.mem.sliceAsBytes(&self.slots)))
                return Error.UnsafeDestination;
            for (self.slots) |maybe_slot| {
                if (maybe_slot) |stored| {
                    if (slicesOverlap(output, stored.payload))
                        return Error.UnsafeDestination;
                }
            }
            @memcpy(output, slot.payload);
            return output;
        }

        pub fn releaseV1(
            self: *Self,
            expected: bundle.BlobRefV1,
        ) Error!void {
            try self.ensureOperation(operation_release);
            const index = self.findExactSlot(expected) orelse
                return Error.NotFound;
            const slot = &self.slots[index].?;
            if (slot.reference_count == 0)
                return Error.InvalidAccounting;
            if (slot.reference_count > 1) {
                slot.reference_count -= 1;
                self.reference_count -= 1;
                return;
            }
            const removed = slot.*;
            self.allocator.free(removed.payload);
            self.slots[index] = null;
            self.entry_count -= 1;
            if (removed.state == .live) {
                self.live_entries -= 1;
            } else {
                self.quarantined_entries -= 1;
            }
            self.payload_bytes -= removed.byte_length;
            self.logical_index_bytes -= logical_index_entry_bytes;
            self.reference_count -= 1;
        }

        pub fn quarantineV1(
            self: *Self,
            expected: bundle.BlobRefV1,
            reason_sha256: Digest,
        ) Error!void {
            try self.ensureOperation(operation_quarantine);
            if (isZero(reason_sha256))
                return Error.InvalidQuarantineReason;
            const index = self.findExactSlot(expected) orelse
                return Error.NotFound;
            const slot = &self.slots[index].?;
            if (slot.state == .quarantined) return Error.Quarantined;
            slot.state = .quarantined;
            slot.quarantine_reason_sha256 = reason_sha256;
            self.live_entries -= 1;
            self.quarantined_entries += 1;
        }

        pub fn verifyAllV1(self: *Self) Error!void {
            try self.ensureOperation(operation_verify);
            var computed_entries: u64 = 0;
            var computed_live: u64 = 0;
            var computed_quarantined: u64 = 0;
            var computed_payload_bytes: u64 = 0;
            var computed_index_bytes: u64 = 0;
            var computed_references: u64 = 0;
            for (self.slots, 0..) |maybe_slot, slot_index| {
                if (maybe_slot) |slot| {
                    if (slot.reference_count == 0 or
                        slot.byte_length > self.grant.max_object_bytes or
                        !std.mem.eql(
                            u8,
                            &slot.provenance_sha256,
                            &self.grant.bundle_sha256,
                        ))
                        return Error.InvalidAccounting;
                    for (self.slots[0..slot_index]) |previous_slot| {
                        if (previous_slot) |previous| {
                            if (std.mem.eql(
                                u8,
                                &previous.sha256,
                                &slot.sha256,
                            )) return Error.InvalidAccounting;
                        }
                    }
                    if ((slot.state == .live and
                        !isZero(slot.quarantine_reason_sha256)) or
                        (slot.state == .quarantined and
                            isZero(slot.quarantine_reason_sha256)))
                        return Error.InvalidAccounting;
                    const computed = bundle.blobRefV1(
                        self.grant.tenant_scope_sha256,
                        slot.payload,
                    ) catch return Error.CorruptPayload;
                    if (computed.byte_length != slot.byte_length or
                        !std.mem.eql(
                            u8,
                            &computed.sha256,
                            &slot.sha256,
                        )) return Error.CorruptPayload;
                    computed_entries += 1;
                    switch (slot.state) {
                        .live => computed_live += 1,
                        .quarantined => computed_quarantined += 1,
                    }
                    computed_payload_bytes = std.math.add(
                        u64,
                        computed_payload_bytes,
                        slot.byte_length,
                    ) catch return Error.InvalidAccounting;
                    computed_index_bytes = std.math.add(
                        u64,
                        computed_index_bytes,
                        logical_index_entry_bytes,
                    ) catch return Error.InvalidAccounting;
                    computed_references = std.math.add(
                        u64,
                        computed_references,
                        slot.reference_count,
                    ) catch return Error.InvalidAccounting;
                }
            }
            if (computed_entries != self.entry_count or
                computed_live != self.live_entries or
                computed_quarantined != self.quarantined_entries or
                computed_payload_bytes != self.payload_bytes or
                computed_index_bytes != self.logical_index_bytes or
                computed_references != self.reference_count or
                computed_entries > self.grant.max_entries or
                computed_payload_bytes > self.grant.max_payload_bytes or
                computed_index_bytes > self.grant.max_index_bytes or
                computed_references > self.grant.max_references)
                return Error.InvalidAccounting;
        }

        pub fn importBundleV1(
            self: *Self,
            bundle_wire: []const u8,
            expected_config: bundle.ConfigV1,
            capsule_wire: []const u8,
            objects: capsule.ObjectsV1,
        ) Error!ImportReceiptV1 {
            try self.ensureOperation(operation_put);
            const decoded = try bundle.decodeAndVerifyV1(
                bundle_wire,
                expected_config,
                capsule_wire,
                objects,
            );
            if (!std.mem.eql(
                u8,
                &decoded.envelope_sha256,
                &self.grant.bundle_sha256,
            ) or !std.mem.eql(
                u8,
                &decoded.config.tenant_scope_sha256,
                &self.grant.tenant_scope_sha256,
            )) return Error.BundleMismatch;

            var actions: [capsule.object_count]ImportAction = undefined;
            var action_count: usize = 0;
            errdefer self.rollbackImport(actions[0..action_count]);
            var unique_entries_added: u64 = 0;
            var references_reused: u64 = 0;
            var payload_bytes_added: u64 = 0;
            for (capsule.object_kinds) |kind| {
                const object = objects.get(kind);
                const entry = decoded.entry(kind);
                const receipt = try self.putV1(
                    .{
                        .byte_length = entry.byte_length,
                        .sha256 = entry.blob_sha256,
                    },
                    object.bytes,
                    decoded.envelope_sha256,
                );
                const inserted = receipt.disposition == .inserted;
                actions[action_count] = .{
                    .slot_index = receipt.slot_index,
                    .inserted = inserted,
                };
                action_count += 1;
                if (inserted) {
                    unique_entries_added += 1;
                    payload_bytes_added += entry.byte_length;
                } else {
                    references_reused += 1;
                }
            }
            return .{
                .bundle_sha256 = decoded.envelope_sha256,
                .semantic_references = capsule.object_count,
                .unique_entries_added = unique_entries_added,
                .references_reused = references_reused,
                .payload_bytes_added = payload_bytes_added,
                .entry_count_after = self.entry_count,
                .payload_bytes_after = self.payload_bytes,
                .reference_count_after = self.reference_count,
                .snapshot_sha256 = self.snapshotRootUnchecked(),
            };
        }

        pub fn statsV1(self: *const Self) StatsV1 {
            return .{
                .entry_count = self.entry_count,
                .live_entries = self.live_entries,
                .quarantined_entries = self.quarantined_entries,
                .payload_bytes = self.payload_bytes,
                .logical_index_bytes = self.logical_index_bytes,
                .reference_count = self.reference_count,
                .native_slot_capacity_bytes = @sizeOf(@TypeOf(self.slots)),
                .native_store_bytes = @sizeOf(Self),
            };
        }

        pub fn snapshotRootV1(self: *Self) Error!Digest {
            try self.verifyAllV1();
            return self.snapshotRootUnchecked();
        }

        fn snapshotRootUnchecked(self: *const Self) Digest {
            var hash = std.crypto.hash.sha2.Sha256.init(.{});
            hash.update(snapshot_domain);
            hash.update(&self.grant_sha256);
            hashU64(&hash, self.entry_count);
            hashU64(&hash, self.live_entries);
            hashU64(&hash, self.quarantined_entries);
            hashU64(&hash, self.payload_bytes);
            hashU64(&hash, self.logical_index_bytes);
            hashU64(&hash, self.reference_count);
            for (self.slots, 0..) |maybe_slot, index| {
                if (maybe_slot) |slot| {
                    hashU64(&hash, index);
                    hashU64(&hash, @intFromEnum(slot.state));
                    hashU64(&hash, slot.byte_length);
                    hash.update(&slot.sha256);
                    hashU64(&hash, slot.reference_count);
                    hash.update(&slot.provenance_sha256);
                    hash.update(&slot.quarantine_reason_sha256);
                }
            }
            var digest: Digest = undefined;
            hash.final(&digest);
            return digest;
        }

        fn rollbackImport(self: *Self, actions: []const ImportAction) void {
            var index = actions.len;
            while (index > 0) {
                index -= 1;
                const action = actions[index];
                if (action.inserted) {
                    const slot = self.slots[action.slot_index].?;
                    self.allocator.free(slot.payload);
                    self.slots[action.slot_index] = null;
                    self.entry_count -= 1;
                    if (slot.state == .live) {
                        self.live_entries -= 1;
                    } else {
                        self.quarantined_entries -= 1;
                    }
                    self.payload_bytes -= slot.byte_length;
                    self.logical_index_bytes -= logical_index_entry_bytes;
                    self.reference_count -= slot.reference_count;
                } else {
                    const slot = &self.slots[action.slot_index].?;
                    slot.reference_count -= 1;
                    self.reference_count -= 1;
                }
            }
        }

        fn ensureOperation(self: *const Self, operation: u64) Error!void {
            if (self.closed) return Error.StoreClosed;
            if (self.grant.allowed_operation_mask & operation == 0)
                return Error.DeniedOperation;
        }

        fn firstEmptySlot(self: *const Self) ?usize {
            for (self.slots, 0..) |maybe_slot, index| {
                if (maybe_slot == null) return index;
            }
            return null;
        }

        fn findExactSlot(
            self: *const Self,
            expected: bundle.BlobRefV1,
        ) ?usize {
            for (self.slots, 0..) |maybe_slot, index| {
                if (maybe_slot) |slot| {
                    if (slot.byte_length == expected.byte_length and
                        std.mem.eql(u8, &slot.sha256, &expected.sha256))
                        return index;
                }
            }
            return null;
        }
    };
}

pub const Store = StoreV1(default_capacity);

pub fn grantRootV1(grant: GrantV1) Error!Digest {
    try validateGrant(grant);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(grant_domain);
    hashU64(&hash, grant.authority_epoch);
    hash.update(&grant.tenant_scope_sha256);
    hash.update(&grant.bundle_sha256);
    hashU64(&hash, grant.allowed_operation_mask);
    hashU64(&hash, grant.max_entries);
    hashU64(&hash, grant.max_object_bytes);
    hashU64(&hash, grant.max_payload_bytes);
    hashU64(&hash, grant.max_index_bytes);
    hashU64(&hash, grant.max_references);
    hash.update(&grant.challenge_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn validateGrant(grant: GrantV1) Error!void {
    if (grant.authority_epoch == 0 or
        isZero(grant.tenant_scope_sha256) or
        isZero(grant.bundle_sha256) or
        grant.allowed_operation_mask == 0 or
        grant.allowed_operation_mask & ~allowed_operations != 0 or
        grant.max_entries == 0 or
        grant.max_object_bytes == 0 or
        grant.max_payload_bytes == 0 or
        grant.max_index_bytes == 0 or
        grant.max_references == 0 or
        grant.max_object_bytes > grant.max_payload_bytes or
        isZero(grant.challenge_sha256))
        return Error.InvalidGrant;
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

fn buildDemoBundle(
    objects: capsule.ObjectsV1,
    capsule_storage: *[capsule.encoded_bytes]u8,
    bundle_storage: *[bundle.encoded_bytes]u8,
) !struct {
    capsule_wire: []const u8,
    bundle_wire: []const u8,
    config: bundle.ConfigV1,
} {
    const capsule_wire = try capsule.encodeV1(
        demoCapsuleConfig(),
        objects,
        capsule_storage,
    );
    const config: bundle.ConfigV1 = .{
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .capsule_sha256 = try capsule.envelopeRootV1(capsule_wire),
        .bundle_generation = 0,
        .challenge_sha256 = [_]u8{0xe3} ** 32,
    };
    const bundle_wire = try bundle.encodeV1(
        config,
        capsule_wire,
        objects,
        bundle_storage,
    );
    return .{
        .capsule_wire = capsule_wire,
        .bundle_wire = bundle_wire,
        .config = config,
    };
}

fn demoGrant(bundle_sha256: Digest) GrantV1 {
    return .{
        .authority_epoch = 11,
        .tenant_scope_sha256 = [_]u8{0x6d} ** 32,
        .bundle_sha256 = bundle_sha256,
        .allowed_operation_mask = allowed_operations,
        .max_entries = 12,
        .max_object_bytes = 64,
        .max_payload_bytes = 512,
        .max_index_bytes = 12 * logical_index_entry_bytes,
        .max_references = 16,
        .challenge_sha256 = [_]u8{0xf2} ** 32,
    };
}

test "tenant store atomically imports bundle and reuses duplicate payload" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try buildDemoBundle(
        objects,
        &capsule_storage,
        &bundle_storage,
    );
    const bundle_root = try bundle.envelopeRootV1(fixture.bundle_wire);
    const grant = demoGrant(bundle_root);
    const grant_root_hex = std.fmt.bytesToHex(
        try grantRootV1(grant),
        .lower,
    );
    try std.testing.expectEqualStrings(
        "1d7b766cd09f48421c8638916716299c" ++
            "bbe0d7046aa7c24c54b5971c68d91771",
        &grant_root_hex,
    );
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer store.deinit();
    const receipt = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.config,
        fixture.capsule_wire,
        objects,
    );
    try std.testing.expectEqual(@as(u64, 9), receipt.semantic_references);
    try std.testing.expectEqual(@as(u64, 8), receipt.unique_entries_added);
    try std.testing.expectEqual(@as(u64, 1), receipt.references_reused);
    try std.testing.expectEqual(@as(u64, 255), receipt.payload_bytes_added);
    const snapshot_hex = std.fmt.bytesToHex(receipt.snapshot_sha256, .lower);
    try std.testing.expectEqualStrings(
        "5ef533c5bbf2db216806736f6a12c595" ++
            "03f668b02e3c12dba8dc8b503121860f",
        &snapshot_hex,
    );
    const stats = store.statsV1();
    try std.testing.expectEqual(@as(u64, 8), stats.entry_count);
    try std.testing.expectEqual(@as(u64, 9), stats.reference_count);
    try std.testing.expectEqual(@as(u64, 255), stats.payload_bytes);
    try std.testing.expectEqual(@as(u64, 1024), stats.logical_index_bytes);
    try store.verifyAllV1();

    const decoded = try bundle.decodeManifestV1(fixture.bundle_wire);
    const model = decoded.entry(.model);
    var output: [64]u8 = undefined;
    const resolved = try store.getV1(.{
        .byte_length = model.byte_length,
        .sha256 = model.blob_sha256,
    }, &output);
    try std.testing.expectEqualSlices(u8, objects.model.bytes, resolved);
}

test "tenant store reference release frees only the final duplicate" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try buildDemoBundle(
        objects,
        &capsule_storage,
        &bundle_storage,
    );
    const grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.config,
        fixture.capsule_wire,
        objects,
    );
    const decoded = try bundle.decodeManifestV1(fixture.bundle_wire);
    const model = decoded.entry(.model);
    const key: bundle.BlobRefV1 = .{
        .byte_length = model.byte_length,
        .sha256 = model.blob_sha256,
    };
    try store.releaseV1(key);
    try std.testing.expectEqual(@as(u64, 8), store.entry_count);
    try std.testing.expectEqual(@as(u64, 8), store.reference_count);
    try store.releaseV1(key);
    try std.testing.expectEqual(@as(u64, 7), store.entry_count);
    try std.testing.expectEqual(@as(u64, 7), store.reference_count);
    try std.testing.expectEqual(@as(u64, 230), store.payload_bytes);
    try std.testing.expectError(Error.NotFound, store.releaseV1(key));
}

test "tenant store rejects stale denied foreign and over-budget grants" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try buildDemoBundle(
        objects,
        &capsule_storage,
        &bundle_storage,
    );
    var grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    try std.testing.expectError(
        Error.StaleGrant,
        Store.initV1(fba.allocator(), grant, grant.authority_epoch + 1),
    );
    grant.allowed_operation_mask = operation_get;
    var denied = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer denied.deinit();
    try std.testing.expectError(
        Error.DeniedOperation,
        denied.importBundleV1(
            fixture.bundle_wire,
            fixture.config,
            fixture.capsule_wire,
            objects,
        ),
    );

    grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    var provenance_store = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer provenance_store.deinit();
    const decoded = try bundle.decodeManifestV1(fixture.bundle_wire);
    const model = decoded.entry(.model);
    try std.testing.expectError(
        Error.InvalidProvenance,
        provenance_store.putV1(
            .{
                .byte_length = model.byte_length,
                .sha256 = model.blob_sha256,
            },
            objects.model.bytes,
            [_]u8{0x33} ** 32,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), provenance_store.entry_count);

    grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    grant.max_entries = 7;
    var limited = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer limited.deinit();
    try std.testing.expectError(
        Error.StoreCapacityExceeded,
        limited.importBundleV1(
            fixture.bundle_wire,
            fixture.config,
            fixture.capsule_wire,
            objects,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), limited.entry_count);
    try std.testing.expectEqual(@as(u64, 0), limited.payload_bytes);
    try std.testing.expectEqual(@as(u64, 0), limited.reference_count);
}

test "tenant store allocator failure rolls import back to exact zero" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try buildDemoBundle(
        objects,
        &capsule_storage,
        &bundle_storage,
    );
    const grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    var allocator_storage: [96]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer store.deinit();
    try std.testing.expectError(
        error.OutOfMemory,
        store.importBundleV1(
            fixture.bundle_wire,
            fixture.config,
            fixture.capsule_wire,
            objects,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), store.entry_count);
    try std.testing.expectEqual(@as(u64, 0), store.live_entries);
    try std.testing.expectEqual(@as(u64, 0), store.payload_bytes);
    try std.testing.expectEqual(@as(u64, 0), store.logical_index_bytes);
    try std.testing.expectEqual(@as(u64, 0), store.reference_count);
    try store.verifyAllV1();
}

test "tenant store every import quota failure rolls back to exact zero" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try buildDemoBundle(
        objects,
        &capsule_storage,
        &bundle_storage,
    );
    const bundle_root = try bundle.envelopeRootV1(fixture.bundle_wire);
    for (0..4) |case_index| {
        var grant = demoGrant(bundle_root);
        const expected_error: anyerror = switch (case_index) {
            0 => block: {
                grant.max_object_bytes = 32;
                break :block Error.ObjectTooLarge;
            },
            1 => block: {
                grant.max_payload_bytes = 200;
                break :block Error.PayloadBudgetExceeded;
            },
            2 => block: {
                grant.max_index_bytes = 7 * logical_index_entry_bytes;
                break :block Error.IndexBudgetExceeded;
            },
            3 => block: {
                grant.max_references = 8;
                break :block Error.ReferenceBudgetExceeded;
            },
            else => unreachable,
        };
        var allocator_storage: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
        var store = try Store.initV1(
            fba.allocator(),
            grant,
            grant.authority_epoch,
        );
        if (store.importBundleV1(
            fixture.bundle_wire,
            fixture.config,
            fixture.capsule_wire,
            objects,
        )) |_| {
            return error.ExpectedQuotaRejection;
        } else |actual_error| {
            try std.testing.expectEqual(expected_error, actual_error);
        }
        try std.testing.expectEqual(@as(u64, 0), store.entry_count);
        try std.testing.expectEqual(@as(u64, 0), store.payload_bytes);
        try std.testing.expectEqual(@as(u64, 0), store.logical_index_bytes);
        try std.testing.expectEqual(@as(u64, 0), store.reference_count);
        store.deinit();
    }
}

test "tenant store detects corruption quarantines and protects storage" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try buildDemoBundle(
        objects,
        &capsule_storage,
        &bundle_storage,
    );
    const grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer store.deinit();
    _ = try store.importBundleV1(
        fixture.bundle_wire,
        fixture.config,
        fixture.capsule_wire,
        objects,
    );
    const decoded = try bundle.decodeManifestV1(fixture.bundle_wire);
    const kv = decoded.entry(.kv_state);
    const key: bundle.BlobRefV1 = .{
        .byte_length = kv.byte_length,
        .sha256 = kv.blob_sha256,
    };
    const index = store.findExactSlot(key).?;
    store.slots[index].?.payload[0] ^= 1;
    try std.testing.expectError(Error.CorruptPayload, store.verifyAllV1());
    var output: [64]u8 = undefined;
    try std.testing.expectError(
        Error.CorruptPayload,
        store.getV1(key, &output),
    );
    try store.quarantineV1(key, [_]u8{0x9a} ** 32);
    try std.testing.expectEqual(@as(u64, 1), store.quarantined_entries);
    try std.testing.expectError(Error.Quarantined, store.getV1(key, &output));
    try std.testing.expectError(
        Error.UnsafeDestination,
        store.getV1(
            .{
                .byte_length = decoded.entry(.model).byte_length,
                .sha256 = decoded.entry(.model).blob_sha256,
            },
            std.mem.asBytes(&store),
        ),
    );
}

test "tenant store bundle grant and tenant fail closed" {
    const objects = demoObjects();
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    var bundle_storage: [bundle.encoded_bytes]u8 = undefined;
    const fixture = try buildDemoBundle(
        objects,
        &capsule_storage,
        &bundle_storage,
    );
    var grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    grant.bundle_sha256[0] ^= 1;
    var allocator_storage: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&allocator_storage);
    var store = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer store.deinit();
    try std.testing.expectError(
        Error.BundleMismatch,
        store.importBundleV1(
            fixture.bundle_wire,
            fixture.config,
            fixture.capsule_wire,
            objects,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), store.entry_count);

    grant = demoGrant(try bundle.envelopeRootV1(fixture.bundle_wire));
    grant.tenant_scope_sha256 = [_]u8{0x7e} ** 32;
    var foreign_tenant = try Store.initV1(
        fba.allocator(),
        grant,
        grant.authority_epoch,
    );
    defer foreign_tenant.deinit();
    try std.testing.expectError(
        Error.BundleMismatch,
        foreign_tenant.importBundleV1(
            fixture.bundle_wire,
            fixture.config,
            fixture.capsule_wire,
            objects,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), foreign_tenant.entry_count);
}
