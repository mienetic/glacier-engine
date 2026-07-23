//! Canonical multimodal processor-cache payloads and fresh-Bank restore.
//!
//! The state plane records logical cache sizes and roots. This module carries
//! the exact cache bytes, binds them to that state, and charges caller-owned
//! materialization before any cache allocation becomes live.

const std = @import("std");
const media = @import("media_contract.zig");
const processor = @import("media_processor_state.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;
pub const cache_bundle_abi: u64 = 0x474d_5043_0000_0001;
pub const cache_bundle_magic = [8]u8{
    'G', 'M', 'P', 'C', 'C', 'H', '1', 0,
};
pub const cache_count: usize = processor.processor_count;
pub const cache_bundle_header_bytes: usize = 256;
pub const cache_entry_bytes: usize = 64;
pub const cache_directory_bytes: usize =
    cache_count * cache_entry_bytes;
pub const cache_payload_offset: usize =
    cache_bundle_header_bytes + cache_directory_bytes;
pub const cache_bundle_footer_bytes: usize = 32;
pub const allowed_flags: u64 = 0;

const cache_bundle_domain =
    "glacier-media-processor-cache-bundle-v1\x00";
const cache_scope_key_base: u64 = 0x4350_0000;
const cache_allocation_key_base: u64 = 0x4351_0000;
const cache_binding_key_base: u64 = 0x4352_0000;

pub const Error = processor.Error || resource_bank.Error || error{
    BufferTooSmall,
    InvalidCacheBundle,
    InvalidCacheBinding,
    InvalidCacheSuccessor,
    InvalidRestoreState,
    CacheExpectationMismatch,
    TargetNotFresh,
    RestorePoisoned,
};

pub const BundlePlanV1 = struct {
    processor_bundle_sha256: Digest,
    previous_cache_bundle_sha256: Digest,
    source_bank_epoch: u64,
    restore_bank_epoch: u64,
    restore_owner_key_base: u64,
    restore_tree_key_base: u64,
    restore_authority_key_base: u64,
    tenant_key: u64,
    publication_next_sequence: u64,
};

pub const PreparedBundleV1 = struct {
    bytes: []const u8,
    bundle_sha256: Digest,
};

pub const DecodedBundleV1 = struct {
    generation: u64,
    request_epoch: u64,
    challenge_sha256: Digest,
    processor_bundle_sha256: Digest,
    sync_sha256: Digest,
    previous_cache_bundle_sha256: Digest,
    source_bank_epoch: u64,
    restore_bank_epoch: u64,
    restore_owner_key_base: u64,
    restore_tree_key_base: u64,
    restore_authority_key_base: u64,
    tenant_key: u64,
    publication_next_sequence: u64,
    total_cache_bytes: u64,
    cache_sha256: [cache_count]Digest,
    payloads: [cache_count][]const u8,
    bundle_sha256: Digest,
};

pub fn encodeBundleV1(
    processor_bundle: processor.DecodedBundleV1,
    plan: BundlePlanV1,
    payloads: [cache_count][]const u8,
    output: []u8,
) Error!PreparedBundleV1 {
    try validatePlanV1(processor_bundle, plan);
    var total_cache_bytes: u64 = 0;
    var payload_bytes: usize = 0;
    var cache_sha256: [cache_count]Digest = undefined;
    for (
        processor_bundle.states,
        payloads,
        0..,
    ) |state, payload, index| {
        if (payload.len == 0 or
            payload.len != state.cache_bytes)
            return Error.InvalidCacheBinding;
        cache_sha256[index] = sha256(payload);
        if (!std.mem.eql(
            u8,
            &cache_sha256[index],
            &state.cache_content_sha256,
        ))
            return Error.InvalidCacheBinding;
        total_cache_bytes = std.math.add(
            u64,
            total_cache_bytes,
            @intCast(payload.len),
        ) catch return Error.InvalidCacheBundle;
        payload_bytes = std.math.add(
            usize,
            payload_bytes,
            payload.len,
        ) catch return Error.InvalidCacheBundle;
    }
    const total_bytes = std.math.add(
        usize,
        cache_payload_offset + cache_bundle_footer_bytes,
        payload_bytes,
    ) catch return Error.InvalidCacheBundle;
    if (output.len < total_bytes)
        return Error.BufferTooSmall;

    const encoded = output[0..total_bytes];
    @memset(encoded, 0);
    @memcpy(encoded[0..8], &cache_bundle_magic);
    writeU64(encoded, 8, cache_bundle_abi);
    writeU64(encoded, 16, total_bytes);
    writeU64(encoded, 24, allowed_flags);
    writeU64(encoded, 32, processor_bundle.sync.generation);
    writeU64(encoded, 40, processor_bundle.sync.request_epoch);
    writeU64(encoded, 48, cache_count);
    @memcpy(
        encoded[64..96],
        &processor_bundle.sync.challenge_sha256,
    );
    @memcpy(
        encoded[96..128],
        &plan.processor_bundle_sha256,
    );
    @memcpy(
        encoded[128..160],
        &processor_bundle.sync.sync_sha256,
    );
    @memcpy(
        encoded[160..192],
        &plan.previous_cache_bundle_sha256,
    );
    writeU64(encoded, 192, plan.restore_bank_epoch);
    writeU64(encoded, 200, plan.restore_owner_key_base);
    writeU64(encoded, 208, plan.restore_tree_key_base);
    writeU64(encoded, 216, plan.restore_authority_key_base);
    writeU64(encoded, 224, plan.tenant_key);
    writeU64(encoded, 232, plan.publication_next_sequence);
    writeU64(encoded, 240, total_cache_bytes);
    writeU64(encoded, 248, plan.source_bank_epoch);

    var cursor = cache_payload_offset;
    for (
        processor_bundle.states,
        payloads,
        cache_sha256,
        0..,
    ) |state, payload, digest, index| {
        const entry_offset =
            cache_bundle_header_bytes + index * cache_entry_bytes;
        writeU64(encoded, entry_offset, @intFromEnum(state.kind));
        writeU64(encoded, entry_offset + 8, cursor);
        writeU64(encoded, entry_offset + 16, payload.len);
        @memcpy(
            encoded[entry_offset + 32 .. entry_offset + 64],
            &digest,
        );
        @memcpy(
            encoded[cursor .. cursor + payload.len],
            payload,
        );
        cursor += payload.len;
    }
    const bundle_sha256 = cacheBundleRootV1(
        encoded[0 .. total_bytes - cache_bundle_footer_bytes],
    );
    @memcpy(
        encoded[total_bytes - cache_bundle_footer_bytes ..],
        &bundle_sha256,
    );
    _ = try decodeBundleV1(encoded);
    return .{
        .bytes = encoded,
        .bundle_sha256 = bundle_sha256,
    };
}

pub fn decodeBundleV1(
    encoded: []const u8,
) Error!DecodedBundleV1 {
    if (encoded.len <
        cache_payload_offset + cache_bundle_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &cache_bundle_magic) or
        readU64(encoded, 8) != cache_bundle_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 48) != cache_count or
        readU64(encoded, 56) != 0)
        return Error.InvalidCacheBundle;
    const generation = readU64(encoded, 32);
    const request_epoch = readU64(encoded, 40);
    const challenge_sha256: Digest = encoded[64..96].*;
    const processor_bundle_sha256: Digest = encoded[96..128].*;
    const sync_sha256: Digest = encoded[128..160].*;
    const previous_cache_bundle_sha256: Digest =
        encoded[160..192].*;
    const restore_bank_epoch = readU64(encoded, 192);
    const restore_owner_key_base = readU64(encoded, 200);
    const restore_tree_key_base = readU64(encoded, 208);
    const restore_authority_key_base = readU64(encoded, 216);
    const tenant_key = readU64(encoded, 224);
    const publication_next_sequence = readU64(encoded, 232);
    const total_cache_bytes = readU64(encoded, 240);
    const source_bank_epoch = readU64(encoded, 248);
    var bundle_sha256: Digest = undefined;
    @memcpy(
        &bundle_sha256,
        encoded[encoded.len - cache_bundle_footer_bytes .. encoded.len],
    );
    if (generation == 0 or request_epoch == 0 or
        isZero(challenge_sha256) or
        isZero(processor_bundle_sha256) or
        isZero(sync_sha256) or
        source_bank_epoch == 0 or
        restore_bank_epoch == 0 or
        source_bank_epoch == restore_bank_epoch or
        restore_owner_key_base == 0 or
        restore_tree_key_base == 0 or
        restore_authority_key_base == 0 or
        tenant_key == 0 or
        publication_next_sequence == 0 or
        total_cache_bytes == 0 or
        (generation == 1 and
            !isZero(previous_cache_bundle_sha256)) or
        (generation != 1 and
            isZero(previous_cache_bundle_sha256)) or
        !std.mem.eql(
            u8,
            &bundle_sha256,
            &cacheBundleRootV1(
                encoded[0 .. encoded.len -
                    cache_bundle_footer_bytes],
            ),
        ))
        return Error.InvalidCacheBundle;

    var payloads: [cache_count][]const u8 = undefined;
    var cache_sha256: [cache_count]Digest = undefined;
    var cursor: usize = cache_payload_offset;
    var observed_cache_bytes: u64 = 0;
    for (0..cache_count) |index| {
        const entry_offset =
            cache_bundle_header_bytes + index * cache_entry_bytes;
        if (readU64(encoded, entry_offset) !=
            @intFromEnum(mediaKindForIndex(index)) or
            readU64(encoded, entry_offset + 8) != cursor or
            readU64(encoded, entry_offset + 24) != 0)
            return Error.InvalidCacheBundle;
        const payload_len = std.math.cast(
            usize,
            readU64(encoded, entry_offset + 16),
        ) orelse return Error.InvalidCacheBundle;
        if (payload_len == 0 or
            payload_len > encoded.len - cursor -
                cache_bundle_footer_bytes)
            return Error.InvalidCacheBundle;
        @memcpy(
            &cache_sha256[index],
            encoded[entry_offset + 32 .. entry_offset + 64],
        );
        payloads[index] = encoded[cursor .. cursor + payload_len];
        if (!std.mem.eql(
            u8,
            &cache_sha256[index],
            &sha256(payloads[index]),
        ))
            return Error.InvalidCacheBundle;
        observed_cache_bytes = std.math.add(
            u64,
            observed_cache_bytes,
            @intCast(payload_len),
        ) catch return Error.InvalidCacheBundle;
        cursor += payload_len;
    }
    if (cursor != encoded.len - cache_bundle_footer_bytes or
        observed_cache_bytes != total_cache_bytes)
        return Error.InvalidCacheBundle;
    return .{
        .generation = generation,
        .request_epoch = request_epoch,
        .challenge_sha256 = challenge_sha256,
        .processor_bundle_sha256 = processor_bundle_sha256,
        .sync_sha256 = sync_sha256,
        .previous_cache_bundle_sha256 = previous_cache_bundle_sha256,
        .source_bank_epoch = source_bank_epoch,
        .restore_bank_epoch = restore_bank_epoch,
        .restore_owner_key_base = restore_owner_key_base,
        .restore_tree_key_base = restore_tree_key_base,
        .restore_authority_key_base = restore_authority_key_base,
        .tenant_key = tenant_key,
        .publication_next_sequence = publication_next_sequence,
        .total_cache_bytes = total_cache_bytes,
        .cache_sha256 = cache_sha256,
        .payloads = payloads,
        .bundle_sha256 = bundle_sha256,
    };
}

pub fn validateBindingV1(
    cache_bundle: *const DecodedBundleV1,
    processor_bundle: *const processor.DecodedBundleV1,
    expected_processor_bundle_sha256: Digest,
) Error!void {
    if (!std.mem.eql(
        u8,
        &cache_bundle.processor_bundle_sha256,
        &expected_processor_bundle_sha256,
    ) or
        cache_bundle.generation !=
            processor_bundle.sync.generation or
        cache_bundle.request_epoch !=
            processor_bundle.sync.request_epoch or
        !std.mem.eql(
            u8,
            &cache_bundle.challenge_sha256,
            &processor_bundle.sync.challenge_sha256,
        ) or
        !std.mem.eql(
            u8,
            &cache_bundle.sync_sha256,
            &processor_bundle.sync.sync_sha256,
        ))
        return Error.InvalidCacheBinding;
    for (
        processor_bundle.states,
        cache_bundle.payloads,
        cache_bundle.cache_sha256,
    ) |state, payload, digest| {
        if (payload.len != state.cache_bytes or
            !std.mem.eql(
                u8,
                &digest,
                &state.cache_content_sha256,
            ))
            return Error.InvalidCacheBinding;
    }
}

pub fn validateSuccessorV1(
    previous: *const DecodedBundleV1,
    successor: *const DecodedBundleV1,
) Error!void {
    const expected_generation = std.math.add(
        u64,
        previous.generation,
        1,
    ) catch return Error.InvalidCacheSuccessor;
    if (successor.generation != expected_generation or
        successor.request_epoch != previous.request_epoch or
        !std.mem.eql(
            u8,
            &successor.previous_cache_bundle_sha256,
            &previous.bundle_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.challenge_sha256,
            &previous.challenge_sha256,
        ) or
        successor.restore_bank_epoch ==
            previous.restore_bank_epoch or
        successor.source_bank_epoch !=
            previous.restore_bank_epoch)
        return Error.InvalidCacheSuccessor;
}

const PreparedCacheV1 = struct {
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    batch: resource_bank.LeaseAllocationBatchV1,
    scope: resource_bank.LeaseNodeV1,
    session_id: usize,
    cache_index: usize,
};

const ActiveCacheV1 = struct {
    receipt: resource_bank.Receipt = undefined,
    tree: resource_bank.LeaseTreeV1 = undefined,
    scope: resource_bank.LeaseNodeV1 = undefined,
    session_id: usize = 0,
    active: bool = false,
};

const RestorePhase = enum {
    idle,
    prepared,
    active,
    poisoned,
    closed,
};

pub const RestoreSession = struct {
    bank: *resource_bank.Bank = undefined,
    bundle: DecodedBundleV1 = undefined,
    prepared: [cache_count]PreparedCacheV1 = undefined,
    prepared_count: usize = 0,
    active_caches: [cache_count]ActiveCacheV1 =
        [_]ActiveCacheV1{.{}} ** cache_count,
    active_count: usize = 0,
    phase: RestorePhase = .idle,

    pub fn prepareV1(
        self: *RestoreSession,
        bank: *resource_bank.Bank,
        bundle: DecodedBundleV1,
        expected_bundle_sha256: Digest,
    ) Error!void {
        if (self.phase != .idle)
            return Error.InvalidRestoreState;
        if (isZero(expected_bundle_sha256) or
            !std.mem.eql(
                u8,
                &bundle.bundle_sha256,
                &expected_bundle_sha256,
            ))
            return Error.CacheExpectationMismatch;
        const snapshot = try bank.snapshotV3();
        if (snapshot.bank_epoch != bundle.restore_bank_epoch or
            !snapshot.used.isZero() or
            snapshot.live_allocations != 0 or
            snapshot.reserved_unmaterialized_allocations != 0 or
            snapshot.active_lease_trees != 0)
            return Error.TargetNotFresh;
        self.* = .{
            .bank = bank,
            .bundle = bundle,
            .phase = .prepared,
        };
        errdefer {
            self.cleanupPreparedV1() catch {
                self.phase = .poisoned;
            };
            if (self.phase != .poisoned)
                self.phase = .closed;
        }
        for (0..cache_count) |index| {
            self.prepared[index] = try self.prepareCacheV1(
                index,
            );
            self.prepared_count += 1;
        }
    }

    pub fn commitMaterializedV1(
        self: *RestoreSession,
        payloads: [cache_count][]const u8,
    ) Error!void {
        if (self.phase == .poisoned)
            return Error.RestorePoisoned;
        if (self.phase != .prepared or
            self.prepared_count != cache_count)
            return Error.InvalidRestoreState;
        for (
            payloads,
            self.bundle.payloads,
            self.bundle.cache_sha256,
        ) |payload, expected, digest| {
            if (!std.mem.eql(u8, payload, expected) or
                !std.mem.eql(u8, &sha256(payload), &digest))
                return Error.InvalidCacheBinding;
        }
        for (
            self.prepared[0..self.prepared_count],
            0..,
        ) |prepared, index| {
            const tree = self.bank
                .commitAllocationsAfterAllocate(
                prepared.batch,
            ) catch {
                self.phase = .poisoned;
                return Error.RestorePoisoned;
            };
            self.active_caches[index] = .{
                .receipt = prepared.receipt,
                .tree = tree,
                .scope = prepared.scope,
                .session_id = prepared.session_id,
                .active = true,
            };
            self.active_count += 1;
        }
        self.phase = .active;
    }

    /// Proves that one exact cache payload is visible under the live,
    /// generation-fenced ownership established by this restore session.
    pub fn validateActivePayloadV1(
        self: *const RestoreSession,
        index: usize,
        payload: []const u8,
    ) Error!void {
        if (self.phase != .active or index >= cache_count or
            self.active_count != cache_count)
            return Error.InvalidRestoreState;
        const active = self.active_caches[index];
        if (!active.active or
            !std.mem.eql(u8, payload, self.bundle.payloads[index]) or
            !std.mem.eql(
                u8,
                &sha256(payload),
                &self.bundle.cache_sha256[index],
            ))
            return Error.CacheExpectationMismatch;
        self.bank.validateCommitted(active.receipt) catch
            return Error.RestorePoisoned;
        self.bank.validateLeaseTree(active.tree) catch
            return Error.RestorePoisoned;
        self.bank.validateLeaseNode(active.tree, active.scope) catch
            return Error.RestorePoisoned;
    }

    pub fn closeAndRelease(
        self: *RestoreSession,
    ) Error!void {
        if (self.phase == .poisoned)
            return Error.RestorePoisoned;
        if (self.phase == .prepared) {
            try self.cleanupPreparedV1();
            self.phase = .closed;
            return;
        }
        if (self.phase != .active)
            return Error.InvalidRestoreState;
        while (self.active_count != 0) {
            const index = self.active_count - 1;
            try self.releaseActiveCacheV1(index);
            self.active_count -= 1;
        }
        self.phase = .closed;
    }

    fn prepareCacheV1(
        self: *RestoreSession,
        index: usize,
    ) Error!PreparedCacheV1 {
        const session_id = @intFromPtr(
            &self.prepared[index],
        );
        const cache_bytes: u64 =
            @intCast(self.bundle.payloads[index].len);
        const claim: resource_bank.Claim = .{
            .activation_bytes = cache_bytes,
        };
        const parent_claim: resource_bank.Claim = .{
            .queue_slots = 1,
        };
        const owner_key = try derivedKey(
            self.bundle.restore_owner_key_base,
            index,
        );
        const tree_key = try derivedKey(
            self.bundle.restore_tree_key_base,
            index,
        );
        const authority_key = try derivedKey(
            self.bundle.restore_authority_key_base,
            index,
        );
        var reservation: resource_bank.Reservation = undefined;
        var receipt: resource_bank.Receipt = undefined;
        var tree: resource_bank.LeaseTreeV1 = undefined;
        var scope: resource_bank.LeaseNodeV1 = undefined;
        var stage: enum {
            none,
            reserved,
            committed,
            tree_open,
            session_bound,
        } = .none;
        errdefer switch (stage) {
            .none => {},
            .reserved => self.bank.cancel(reservation) catch {
                self.phase = .poisoned;
            },
            .committed => self.bank.release(receipt) catch {
                self.phase = .poisoned;
            },
            .tree_open => {
                self.bank.closeLeaseTree(tree) catch {
                    self.phase = .poisoned;
                };
                self.bank.release(receipt) catch {
                    self.phase = .poisoned;
                };
            },
            .session_bound => {
                self.bank.closePublicationSession(
                    receipt,
                    self.bundle.request_epoch,
                    session_id,
                    self.bundle.publication_next_sequence,
                ) catch {
                    self.phase = .poisoned;
                };
                self.bank.closeLeaseTree(tree) catch {
                    self.phase = .poisoned;
                };
                self.bank.release(receipt) catch {
                    self.phase = .poisoned;
                };
            },
        };
        reservation = try self.bank.reserve(
            owner_key,
            parent_claim,
        );
        stage = .reserved;
        receipt = try self.bank.commit(reservation);
        stage = .committed;
        tree = try self.bank.openLeaseTree(
            receipt,
            tree_key,
            authority_key,
            claim,
        );
        stage = .tree_open;
        const opened = try self.bank.openLeaseScope(
            tree,
            cache_scope_key_base + index,
            self.bundle.tenant_key,
            claim,
        );
        tree = opened.tree;
        scope = opened.scope;
        try self.bank.bindRestoredPublicationSessionWithLeaseTree(
            tree,
            self.bundle.source_bank_epoch,
            self.bundle.request_epoch,
            session_id,
            self.bundle.publication_next_sequence,
        );
        stage = .session_bound;
        var allocations: [1]resource_bank.LeaseNodeV1 =
            undefined;
        const specs = [_]resource_bank.LeaseAllocationSpecV1{
            .{
                .scope = scope,
                .node_key = cache_allocation_key_base + index,
                .binding_key = cache_binding_key_base + index,
                .claim = claim,
            },
        };
        const prepared = try self.bank
            .reserveAllocationsForSession(
            tree,
            self.bundle.request_epoch,
            session_id,
            self.bundle.publication_next_sequence,
            &specs,
            &allocations,
        );
        return .{
            .receipt = receipt,
            .tree = prepared.tree,
            .batch = prepared.batch,
            .scope = scope,
            .session_id = session_id,
            .cache_index = index,
        };
    }

    fn cleanupPreparedV1(
        self: *RestoreSession,
    ) Error!void {
        while (self.prepared_count != 0) {
            const index = self.prepared_count - 1;
            const prepared = self.prepared[index];
            const tree = try self.bank
                .abortAllocationsAfterFree(prepared.batch);
            try self.bank.closePublicationSession(
                prepared.receipt,
                self.bundle.request_epoch,
                prepared.session_id,
                self.bundle.publication_next_sequence,
            );
            try self.bank.closeLeaseTree(tree);
            try self.bank.release(prepared.receipt);
            self.prepared_count -= 1;
        }
    }

    fn releaseActiveCacheV1(
        self: *RestoreSession,
        index: usize,
    ) Error!void {
        var active = &self.active_caches[index];
        if (!active.active)
            return Error.InvalidRestoreState;
        const retiring = try self.bank
            .beginRetireSubtreeForSession(
            active.tree,
            active.scope,
            self.bundle.request_epoch,
            active.session_id,
            self.bundle.publication_next_sequence,
        );
        const authorized = try self.bank.authorizeFree(
            retiring.ticket,
        );
        const empty_tree = try self.bank
            .commitFreeAfterAllocatorFree(
            authorized.permit,
        );
        try self.bank.closePublicationSession(
            active.receipt,
            self.bundle.request_epoch,
            active.session_id,
            self.bundle.publication_next_sequence,
        );
        try self.bank.closeLeaseTree(empty_tree);
        try self.bank.release(active.receipt);
        active.active = false;
    }
};

pub fn cacheBundleRootV1(
    body: []const u8,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(cache_bundle_domain);
    hasher.update(body);
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn validatePlanV1(
    processor_bundle: processor.DecodedBundleV1,
    plan: BundlePlanV1,
) Error!void {
    const generation = processor_bundle.sync.generation;
    if (isZero(plan.processor_bundle_sha256) or
        !std.mem.eql(
            u8,
            &plan.processor_bundle_sha256,
            &processor_bundle.bundle_sha256,
        ) or
        plan.source_bank_epoch == 0 or
        plan.restore_bank_epoch == 0 or
        plan.source_bank_epoch == plan.restore_bank_epoch or
        plan.restore_owner_key_base == 0 or
        plan.restore_tree_key_base == 0 or
        plan.restore_authority_key_base == 0 or
        plan.tenant_key == 0 or
        plan.publication_next_sequence == 0 or
        (generation == 1 and
            !isZero(plan.previous_cache_bundle_sha256)) or
        (generation != 1 and
            isZero(plan.previous_cache_bundle_sha256)))
        return Error.InvalidCacheBundle;
    for (0..cache_count) |index| {
        _ = try derivedKey(
            plan.restore_owner_key_base,
            index,
        );
        _ = try derivedKey(
            plan.restore_tree_key_base,
            index,
        );
        _ = try derivedKey(
            plan.restore_authority_key_base,
            index,
        );
    }
}

fn mediaKindForIndex(
    index: usize,
) media.MediaKindV1 {
    return switch (index) {
        0 => .image,
        1 => .audio,
        2 => .video,
        else => unreachable,
    };
}

fn derivedKey(
    base: u64,
    index: usize,
) Error!u64 {
    return std.math.add(
        u64,
        base,
        @intCast(index),
    ) catch return Error.InvalidCacheBundle;
}

fn sha256(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        bytes,
        &digest,
        .{},
    );
    return digest;
}

fn writeU64(
    output: []u8,
    offset: usize,
    value: anytype,
) void {
    std.mem.writeInt(
        u64,
        output[offset .. offset + 8][0..8],
        @intCast(value),
        .little,
    );
}

fn readU64(
    encoded: []const u8,
    offset: usize,
) u64 {
    return std.mem.readInt(
        u64,
        encoded[offset .. offset + 8][0..8],
        .little,
    );
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn testProcessorBundleV1(
    generation: u64,
    previous: ?*const processor.DecodedBundleV1,
    payloads: [cache_count][]const u8,
    storage: *[processor.processor_bundle_bytes]u8,
) !processor.DecodedBundleV1 {
    const kinds = [_]media.MediaKindV1{
        .image,
        .audio,
        .video,
    };
    const timelines = [_]media.TimeBaseV1{
        .{ .numerator = 0, .denominator = 1 },
        .{ .numerator = 1, .denominator = 48_000 },
        .{ .numerator = 1, .denominator = 120 },
    };
    var plans: [cache_count]processor.StatePlanV1 =
        undefined;
    for (&plans, 0..) |*plan, index| {
        plan.* = .{
            .kind = kinds[index],
            .request_epoch = 25_000,
            .generation = generation,
            .stream_key = 25_100 + index,
            .timeline_base = timelines[index],
            .media_object_sha256 = [_]u8{@intCast(0x10 + index)} ** 32,
            .processor_plan_sha256 = [_]u8{@intCast(0x20 + index)} ** 32,
            .previous_state_sha256 = if (previous) |prior|
                prior.states[index].state_sha256
            else
                [_]u8{0} ** 32,
            .challenge_sha256 = [_]u8{0x72} ** 32,
            .cache_content_sha256 = sha256(payloads[index]),
            .output_chain_sha256 = [_]u8{@intCast(0x40 + index + generation)} ** 32,
            .ownership_receipt_sha256 = [_]u8{@intCast(0x50 + index + generation)} ** 32,
            .decoder_state_sha256 = [_]u8{@intCast(0x60 + index)} ** 32,
        };
    }
    const window_start = generation -| 2;
    const states = [_]processor.ProcessorStateV1{
        try processor.makeImageStateV1(
            plans[0],
            generation,
            4,
            4,
            4,
            2,
            2,
            3,
        ),
        try processor.makeAudioStateV1(
            plans[1],
            generation,
            48_000,
            1,
            400,
            160,
            80,
            2,
        ),
        try processor.makeVideoStateV1(
            plans[2],
            2,
            128,
            window_start,
            generation,
            window_start,
        ),
    };
    const sync = try processor.makeSyncStateV1(
        states,
        .{
            .generation = generation,
            .request_epoch = 25_000,
            .master_ticks_per_second = 48_000,
            .maximum_skew_ticks = 800,
            .challenge_sha256 = [_]u8{0x72} ** 32,
            .sync_policy_sha256 = [_]u8{0x70} ** 32,
            .previous_sync_sha256 = if (previous) |prior|
                prior.sync.sync_sha256
            else
                [_]u8{0} ** 32,
        },
    );
    const prepared = try processor.encodeBundleV1(
        states,
        sync,
        storage,
    );
    return processor.decodeBundleV1(prepared.bytes);
}

test "processor cache bundle restores charged bytes before visibility" {
    var image_cache = [_]u8{0x11} ** 24;
    var audio_cache = [_]u8{0x22} ** 640;
    var video_cache = [_]u8{0x33} ** 128;
    const payloads = [_][]const u8{
        &image_cache,
        &audio_cache,
        &video_cache,
    };
    var processor_storage: [processor.processor_bundle_bytes]u8 = undefined;
    const processor_bundle = try testProcessorBundleV1(
        1,
        null,
        payloads,
        &processor_storage,
    );
    const processor_root =
        processor.processorBundleRootV1(
            processor_storage[0..processor.processor_bundle_body_bytes],
        );
    var cache_storage: [2048]u8 = undefined;
    const prepared = try encodeBundleV1(
        processor_bundle,
        .{
            .processor_bundle_sha256 = processor_root,
            .previous_cache_bundle_sha256 = [_]u8{0} ** 32,
            .source_bank_epoch = 30_000,
            .restore_bank_epoch = 31_000,
            .restore_owner_key_base = 31_100,
            .restore_tree_key_base = 31_200,
            .restore_authority_key_base = 31_300,
            .tenant_key = 31_400,
            .publication_next_sequence = 2,
        },
        payloads,
        &cache_storage,
    );
    const decoded = try decodeBundleV1(prepared.bytes);
    var expected_bundle_sha256: Digest = undefined;
    _ = std.fmt.hexToBytes(
        &expected_bundle_sha256,
        "b11ac37dd0125a6086a44dce9c0e394f" ++
            "cfa5435715cc21b4ed5182cb74e7528c",
    ) catch unreachable;
    try std.testing.expectEqualSlices(
        u8,
        &expected_bundle_sha256,
        &decoded.bundle_sha256,
    );
    try validateBindingV1(
        &decoded,
        &processor_bundle,
        processor_root,
    );

    var slots = [_]resource_bank.Slot{.{}} ** cache_count;
    var roots =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** cache_count;
    var nodes =
        [_]resource_bank.LeaseNodeSlot{.{}} ** (cache_count * 2);
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{},
        decoded.restore_bank_epoch,
    );
    var restored: RestoreSession = .{};
    try restored.prepareV1(
        &bank,
        decoded,
        decoded.bundle_sha256,
    );
    const reserved = try bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, cache_count),
        reserved.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(@as(u64, 0), reserved.live_allocations);
    var foreign_image = image_cache;
    foreign_image[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidCacheBinding,
        restored.commitMaterializedV1(.{
            &foreign_image,
            &audio_cache,
            &video_cache,
        }),
    );
    const still_reserved = try bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, cache_count),
        still_reserved.reserved_unmaterialized_allocations,
    );
    try restored.commitMaterializedV1(payloads);
    const active = try bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, cache_count),
        active.live_allocations,
    );
    try std.testing.expectEqual(
        decoded.total_cache_bytes,
        active.used.activation_bytes,
    );
    try restored.closeAndRelease();
    const final = try bank.snapshotV3();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(u64, 0), final.live_allocations);
    try std.testing.expectEqual(
        @as(u64, 0),
        final.active_lease_trees,
    );

    for (0..prepared.bytes.len) |index| {
        var corrupted = cache_storage;
        corrupted[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidCacheBundle,
            decodeBundleV1(
                corrupted[0..prepared.bytes.len],
            ),
        );
    }
}
