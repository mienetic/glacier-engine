//! Canonical resource ownership for one durable continuation checkpoint.
//!
//! The fixed wire binds a payload snapshot, a continuation capsule, bounded
//! LeaseTree topology, and exact materialized-object roots. Restore validates
//! every byte before charging a fresh ResourceBank, reserves all allocation
//! ownership before caller materialization, and advances lifecycle state only
//! after the supplied bytes match the durable plan.

const std = @import("std");
const capsule = @import("continuation_capsule.zig");
const payload_store = @import("continuation_object_payload_store.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = capsule.Digest;
pub const abi_version: u64 = 0x4743_4f4d_0000_0001;
pub const magic = [_]u8{ 'G', 'C', 'O', 'W', 'N', 'V', '0', '1' };
pub const allowed_flags: u32 = 0;
pub const max_scopes: usize = 4;
pub const max_allocations: usize = 16;
pub const header_bytes: usize = 384;
pub const scope_bytes: usize = 96;
pub const allocation_bytes: usize = 160;
pub const footer_bytes: usize = 32;
pub const encoded_bytes: usize = header_bytes +
    max_scopes * scope_bytes +
    max_allocations * allocation_bytes +
    footer_bytes;

const manifest_domain =
    "glacier-continuation-ownership-manifest-v1\x00";
const materialized_object_domain =
    "glacier-continuation-materialized-object-v1\x00";

comptime {
    if (@sizeOf(resource_bank.Claim) != 80)
        @compileError("ownership manifest Claim wire layout drifted");
    if (encoded_bytes != 3360)
        @compileError("ownership manifest wire layout drifted");
}

pub const Error = resource_bank.Error ||
    capsule.Error ||
    payload_store.Error ||
    error{
        AllocationCountExceeded,
        CapsuleBindingMismatch,
        InvalidManifest,
        InvalidMaterialization,
        ManifestExpectationMismatch,
        NonCanonicalAllocations,
        NonCanonicalScopes,
        RestoreCapacityExceeded,
        ScopeCountExceeded,
        TargetAuthorityMismatch,
        TargetNotFresh,
    };

pub const AllocationKindV1 = enum(u64) {
    kv_page = 1,
    output_journal = 2,
    sampler_state = 3,
    runtime_object = 4,
};

pub const ScopeInputV1 = struct {
    scope_key: u64,
    tenant_key: u64,
    ceiling: resource_bank.Claim,
};

pub const AllocationInputV1 = struct {
    scope_ordinal: u64,
    node_key: u64,
    binding_key: u64,
    kind: AllocationKindV1,
    claim: resource_bank.Claim,
    object_bytes: []const u8,
};

pub const InputV1 = struct {
    source_bank_epoch: u64,
    source_receipt_generation: u64,
    restore_bank_epoch: u64,
    request_epoch: u64,
    publication_next_sequence: u64,
    checkpoint_generation: u64,
    owner_key: u64,
    tree_key: u64,
    authority_key: u64,
    parent_claim: resource_bank.Claim,
    tree_ceiling: resource_bank.Claim,
    tenant_scope_sha256: Digest,
    payload_snapshot_sha256: Digest,
    challenge_sha256: Digest,
    scopes: []const ScopeInputV1,
    allocations: []const AllocationInputV1,
};

pub const ScopeV1 = struct {
    scope_key: u64 = 0,
    tenant_key: u64 = 0,
    ceiling: resource_bank.Claim = .{},
};

pub const AllocationV1 = struct {
    scope_ordinal: u64 = 0,
    node_key: u64 = 0,
    binding_key: u64 = 0,
    kind: AllocationKindV1 = .runtime_object,
    object_byte_length: u64 = 0,
    claim: resource_bank.Claim = .{},
    object_sha256: Digest = [_]u8{0} ** 32,
};

pub const DecodedV1 = struct {
    source_bank_epoch: u64,
    source_receipt_generation: u64,
    restore_bank_epoch: u64,
    request_epoch: u64,
    publication_next_sequence: u64,
    checkpoint_generation: u64,
    owner_key: u64,
    tree_key: u64,
    authority_key: u64,
    parent_claim: resource_bank.Claim,
    tree_ceiling: resource_bank.Claim,
    tenant_scope_sha256: Digest,
    payload_snapshot_sha256: Digest,
    challenge_sha256: Digest,
    scopes: [max_scopes]ScopeV1,
    scope_count: usize,
    allocations: [max_allocations]AllocationV1,
    allocation_count: usize,
    manifest_sha256: Digest,
};

pub const VerifiedBindingsV1 = struct {
    manifest: DecodedV1,
    capsule_manifest: capsule.DecodedV1,
    payload_snapshot: payload_store.SnapshotV1,
};

pub const PreparedReacquireV1 = struct {
    manifest: DecodedV1,
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    batch: resource_bank.LeaseAllocationBatchV1,
    scopes: [max_scopes]resource_bank.LeaseNodeV1,
    scope_count: usize,
    allocation_nodes: [max_allocations]resource_bank.LeaseNodeV1,
    allocation_count: usize,
};

pub const MaterializedObjectV1 = struct {
    kind: AllocationKindV1,
    bytes: []const u8,
};

pub const ActiveReacquireV1 = struct {
    manifest_sha256: Digest,
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    scopes: [max_scopes]resource_bank.LeaseNodeV1,
    scope_count: usize,
    allocation_nodes: [max_allocations]resource_bank.LeaseNodeV1,
    allocation_count: usize,
};

pub fn encodeV1(input: InputV1, output: []u8) Error![]const u8 {
    if (output.len < encoded_bytes) return Error.CapacityExceeded;
    const decoded = try decodedFromInputV1(input);

    var encoded: [encoded_bytes]u8 = [_]u8{0} ** encoded_bytes;
    var writer: Writer = .{ .bytes = &encoded };
    try writer.writeBytes(&magic);
    try writer.writeU64(abi_version);
    try writer.writeU64(encoded_bytes);
    try writer.writeU32(allowed_flags);
    try writer.writeU32(0);
    try writer.writeU64(decoded.source_bank_epoch);
    try writer.writeU64(decoded.source_receipt_generation);
    try writer.writeU64(decoded.restore_bank_epoch);
    try writer.writeU64(decoded.request_epoch);
    try writer.writeU64(decoded.publication_next_sequence);
    try writer.writeU64(decoded.checkpoint_generation);
    try writer.writeU64(decoded.owner_key);
    try writer.writeU64(decoded.tree_key);
    try writer.writeU64(decoded.authority_key);
    try writer.writeU64(decoded.scope_count);
    try writer.writeU64(decoded.allocation_count);
    try writer.writeClaim(decoded.parent_claim);
    try writer.writeClaim(decoded.tree_ceiling);
    try writer.writeDigest(decoded.tenant_scope_sha256);
    try writer.writeDigest(decoded.payload_snapshot_sha256);
    try writer.writeDigest(decoded.challenge_sha256);
    try writer.writeU64(0);
    if (writer.position != header_bytes) return Error.InvalidLength;

    for (decoded.scopes) |scope| {
        try writer.writeU64(scope.scope_key);
        try writer.writeU64(scope.tenant_key);
        try writer.writeClaim(scope.ceiling);
    }
    for (decoded.allocations, 0..) |allocation, index| {
        if (index < decoded.allocation_count) {
            try writer.writeU64(allocation.scope_ordinal);
            try writer.writeU64(allocation.node_key);
            try writer.writeU64(allocation.binding_key);
            try writer.writeU64(@intFromEnum(allocation.kind));
            try writer.writeU64(allocation.object_byte_length);
            try writer.writeU64(0);
            try writer.writeClaim(allocation.claim);
            try writer.writeDigest(allocation.object_sha256);
        } else {
            try writer.writeBytes(&([_]u8{0} ** allocation_bytes));
        }
    }
    if (writer.position != encoded_bytes - footer_bytes)
        return Error.InvalidLength;
    try writer.writeDigest(manifestRootV1(
        encoded[0 .. encoded_bytes - footer_bytes],
    ));
    if (writer.position != encoded_bytes) return Error.InvalidLength;

    std.mem.copyForwards(u8, output[0..encoded_bytes], &encoded);
    return output[0..encoded_bytes];
}

pub fn decodeV1(encoded: []const u8) Error!DecodedV1 {
    if (encoded.len != encoded_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(u8, try reader.readBytes(magic.len), &magic))
        return Error.InvalidMagic;
    if (try reader.readU64() != abi_version) return Error.InvalidAbi;
    if (try reader.readU64() != encoded_bytes) return Error.InvalidLength;
    if (try reader.readU32() != allowed_flags or try reader.readU32() != 0)
        return Error.InvalidFlags;

    var decoded: DecodedV1 = .{
        .source_bank_epoch = try reader.readU64(),
        .source_receipt_generation = try reader.readU64(),
        .restore_bank_epoch = try reader.readU64(),
        .request_epoch = try reader.readU64(),
        .publication_next_sequence = try reader.readU64(),
        .checkpoint_generation = try reader.readU64(),
        .owner_key = try reader.readU64(),
        .tree_key = try reader.readU64(),
        .authority_key = try reader.readU64(),
        .scope_count = std.math.cast(usize, try reader.readU64()) orelse
            return Error.ScopeCountExceeded,
        .allocation_count = std.math.cast(
            usize,
            try reader.readU64(),
        ) orelse return Error.AllocationCountExceeded,
        .parent_claim = try reader.readClaim(),
        .tree_ceiling = try reader.readClaim(),
        .tenant_scope_sha256 = try reader.readDigest(),
        .payload_snapshot_sha256 = try reader.readDigest(),
        .challenge_sha256 = try reader.readDigest(),
        .scopes = [_]ScopeV1{.{}} ** max_scopes,
        .allocations = [_]AllocationV1{.{}} ** max_allocations,
        .manifest_sha256 = undefined,
    };
    if (try reader.readU64() != 0) return Error.InvalidManifest;
    if (reader.position != header_bytes) return Error.InvalidLength;
    if (decoded.scope_count > max_scopes) return Error.ScopeCountExceeded;
    if (decoded.allocation_count > max_allocations)
        return Error.AllocationCountExceeded;

    for (&decoded.scopes, 0..) |*scope, index| {
        const value: ScopeV1 = .{
            .scope_key = try reader.readU64(),
            .tenant_key = try reader.readU64(),
            .ceiling = try reader.readClaim(),
        };
        if (index < decoded.scope_count) {
            scope.* = value;
        } else if (value.scope_key != 0 or value.tenant_key != 0 or
            !value.ceiling.isZero())
            return Error.InvalidManifest;
    }
    for (&decoded.allocations, 0..) |*allocation, index| {
        const scope_ordinal = try reader.readU64();
        const node_key = try reader.readU64();
        const binding_key = try reader.readU64();
        const raw_kind = try reader.readU64();
        const object_byte_length = try reader.readU64();
        const reserved = try reader.readU64();
        const claim = try reader.readClaim();
        const object_sha256 = try reader.readDigest();
        if (index < decoded.allocation_count) {
            const kind = std.meta.intToEnum(
                AllocationKindV1,
                raw_kind,
            ) catch return Error.InvalidManifest;
            if (reserved != 0) return Error.InvalidManifest;
            allocation.* = .{
                .scope_ordinal = scope_ordinal,
                .node_key = node_key,
                .binding_key = binding_key,
                .kind = kind,
                .object_byte_length = object_byte_length,
                .claim = claim,
                .object_sha256 = object_sha256,
            };
        } else if (scope_ordinal != 0 or node_key != 0 or binding_key != 0 or
            raw_kind != 0 or object_byte_length != 0 or reserved != 0 or
            !claim.isZero() or !isZero(object_sha256))
            return Error.InvalidManifest;
    }
    if (reader.position != encoded_bytes - footer_bytes)
        return Error.InvalidLength;
    decoded.manifest_sha256 = try reader.readDigest();
    if (reader.position != encoded.len or !std.mem.eql(
        u8,
        &decoded.manifest_sha256,
        &manifestRootV1(encoded[0 .. encoded.len - footer_bytes]),
    )) return Error.InvalidManifest;
    try validateDecodedV1(decoded);
    return decoded;
}

pub fn decodeAndVerifyBindingsV1(
    capsule_wire: []const u8,
    manifest_wire: []const u8,
    payload_snapshot_wire: []const u8,
) Error!VerifiedBindingsV1 {
    const manifest = try decodeV1(manifest_wire);
    const capsule_manifest = try capsule.decodeManifestV1(capsule_wire);
    if (capsule_manifest.config.request_epoch != manifest.request_epoch or
        capsule_manifest.config.publication_sequence !=
            manifest.publication_next_sequence or
        capsule_manifest.config.checkpoint_generation !=
            manifest.checkpoint_generation or
        !std.mem.eql(
            u8,
            &capsule_manifest.config.challenge_sha256,
            &manifest.challenge_sha256,
        ))
        return Error.CapsuleBindingMismatch;
    const resource_ref = try capsule.objectRefV1(.resource_state, .{
        .abi_version = abi_version,
        .bytes = manifest_wire,
    });
    if (!std.meta.eql(
        capsule_manifest.ref(.resource_state),
        resource_ref,
    )) return Error.CapsuleBindingMismatch;

    var entries: [payload_store.default_capacity]payload_store.EntryViewV1 =
        undefined;
    const payload_snapshot = try payload_store.decodeSnapshotV1(
        payload_snapshot_wire,
        manifest.tenant_scope_sha256,
        &entries,
    );
    if (!std.mem.eql(
        u8,
        &payload_snapshot.snapshot_sha256,
        &manifest.payload_snapshot_sha256,
    )) return Error.ManifestExpectationMismatch;
    return .{
        .manifest = manifest,
        .capsule_manifest = capsule_manifest,
        .payload_snapshot = payload_snapshot,
    };
}

/// Rebuild ownership into an exclusively owned, freshly initialized target
/// Bank. The returned batch is charged and `reserved_unmaterialized`; callers
/// must not expose restored payloads before `commitMaterializedV1` succeeds.
pub fn prepareReacquireV1(
    bank: *resource_bank.Bank,
    capsule_wire: []const u8,
    manifest_wire: []const u8,
    payload_snapshot_wire: []const u8,
    session_id: usize,
) Error!PreparedReacquireV1 {
    if (session_id == 0) return Error.InvalidManifest;
    const verified = try decodeAndVerifyBindingsV1(
        capsule_wire,
        manifest_wire,
        payload_snapshot_wire,
    );
    const plan = verified.manifest;
    const aggregate = try allocationClaimV1(plan);
    const total_claim = try addClaims(plan.parent_claim, aggregate);
    const snapshot = try bank.snapshotV3();
    try validateFreshTargetV1(snapshot, plan, total_claim);

    var reservation: resource_bank.Reservation = undefined;
    var receipt: resource_bank.Receipt = undefined;
    var tree: resource_bank.LeaseTreeV1 = undefined;
    var stage: PrepareStage = .none;
    errdefer cleanupPrepareFailureV1(
        bank,
        stage,
        reservation,
        receipt,
        tree,
        plan,
        session_id,
    );

    reservation = try bank.reserve(plan.owner_key, plan.parent_claim);
    stage = .reserved;
    receipt = try bank.commit(reservation);
    stage = .committed;
    tree = try bank.openLeaseTree(
        receipt,
        plan.tree_key,
        plan.authority_key,
        plan.tree_ceiling,
    );
    stage = .tree_open;

    var scopes: [max_scopes]resource_bank.LeaseNodeV1 = undefined;
    for (plan.scopes[0..plan.scope_count], 0..) |scope_plan, index| {
        const opened = try bank.openLeaseScope(
            tree,
            scope_plan.scope_key,
            scope_plan.tenant_key,
            scope_plan.ceiling,
        );
        tree = opened.tree;
        scopes[index] = opened.scope;
    }
    try bank.bindRestoredPublicationSessionWithLeaseTree(
        tree,
        plan.source_bank_epoch,
        plan.request_epoch,
        session_id,
        plan.publication_next_sequence,
    );
    stage = .session_bound;

    var specs: [max_allocations]resource_bank.LeaseAllocationSpecV1 =
        undefined;
    for (plan.allocations[0..plan.allocation_count], 0..) |allocation, index| {
        specs[index] = .{
            .scope = scopes[@intCast(allocation.scope_ordinal)],
            .node_key = allocation.node_key,
            .binding_key = allocation.binding_key,
            .claim = allocation.claim,
        };
    }
    var allocation_nodes: [max_allocations]resource_bank.LeaseNodeV1 =
        undefined;
    const reserved = try bank.reserveAllocationsForSession(
        tree,
        plan.request_epoch,
        session_id,
        plan.publication_next_sequence,
        specs[0..plan.allocation_count],
        allocation_nodes[0..plan.allocation_count],
    );
    stage = .prepared;
    return .{
        .manifest = plan,
        .receipt = receipt,
        .tree = reserved.tree,
        .batch = reserved.batch,
        .scopes = scopes,
        .scope_count = plan.scope_count,
        .allocation_nodes = allocation_nodes,
        .allocation_count = plan.allocation_count,
    };
}

/// Validate every materialized byte string before changing the pending Bank
/// batch to live. Any mismatch leaves the safe charge in place for retry or
/// explicit abort.
pub fn commitMaterializedV1(
    bank: *resource_bank.Bank,
    prepared: PreparedReacquireV1,
    manifest_wire: []const u8,
    objects: []const MaterializedObjectV1,
) Error!ActiveReacquireV1 {
    const manifest = try decodeV1(manifest_wire);
    if (!std.meta.eql(manifest, prepared.manifest) or
        objects.len != manifest.allocation_count or
        prepared.allocation_count != manifest.allocation_count or
        prepared.scope_count != manifest.scope_count)
        return Error.ManifestExpectationMismatch;
    for (objects, manifest.allocations[0..manifest.allocation_count]) |
        object,
        allocation,
    | {
        const byte_length = std.math.cast(u64, object.bytes.len) orelse
            return Error.InvalidMaterialization;
        if (object.kind != allocation.kind or
            byte_length != allocation.object_byte_length or
            !std.mem.eql(
                u8,
                &materializedObjectRootV1(object.kind, object.bytes),
                &allocation.object_sha256,
            ))
            return Error.InvalidMaterialization;
    }
    const tree = try bank.commitAllocationsAfterAllocate(prepared.batch);
    return .{
        .manifest_sha256 = manifest.manifest_sha256,
        .receipt = prepared.receipt,
        .tree = tree,
        .scopes = prepared.scopes,
        .scope_count = prepared.scope_count,
        .allocation_nodes = prepared.allocation_nodes,
        .allocation_count = prepared.allocation_count,
    };
}

/// Roll back a prepared reacquisition after every caller-side allocation has
/// been freed. This returns the exclusively owned target Bank to zero charge.
pub fn abortPreparedReacquireAfterFreeV1(
    bank: *resource_bank.Bank,
    prepared: PreparedReacquireV1,
) Error!void {
    const tree = try bank.abortAllocationsAfterFree(prepared.batch);
    try bank.closePublicationSession(
        prepared.receipt,
        prepared.manifest.request_epoch,
        prepared.batch.session_id,
        prepared.manifest.publication_next_sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(prepared.receipt);
}

pub fn materializedObjectRootV1(
    kind: AllocationKindV1,
    bytes: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(materialized_object_domain);
    hashU64(&hash, @intFromEnum(kind));
    hashU64(&hash, std.math.cast(u64, bytes.len) orelse
        std.math.maxInt(u64));
    hash.update(bytes);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn manifestRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(manifest_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn decodedFromInputV1(input: InputV1) Error!DecodedV1 {
    if (input.scopes.len > max_scopes) return Error.ScopeCountExceeded;
    if (input.allocations.len > max_allocations)
        return Error.AllocationCountExceeded;
    var decoded: DecodedV1 = .{
        .source_bank_epoch = input.source_bank_epoch,
        .source_receipt_generation = input.source_receipt_generation,
        .restore_bank_epoch = input.restore_bank_epoch,
        .request_epoch = input.request_epoch,
        .publication_next_sequence = input.publication_next_sequence,
        .checkpoint_generation = input.checkpoint_generation,
        .owner_key = input.owner_key,
        .tree_key = input.tree_key,
        .authority_key = input.authority_key,
        .parent_claim = input.parent_claim,
        .tree_ceiling = input.tree_ceiling,
        .tenant_scope_sha256 = input.tenant_scope_sha256,
        .payload_snapshot_sha256 = input.payload_snapshot_sha256,
        .challenge_sha256 = input.challenge_sha256,
        .scopes = [_]ScopeV1{.{}} ** max_scopes,
        .scope_count = input.scopes.len,
        .allocations = [_]AllocationV1{.{}} ** max_allocations,
        .allocation_count = input.allocations.len,
        .manifest_sha256 = [_]u8{0} ** 32,
    };
    for (input.scopes, 0..) |scope, index| {
        decoded.scopes[index] = .{
            .scope_key = scope.scope_key,
            .tenant_key = scope.tenant_key,
            .ceiling = scope.ceiling,
        };
    }
    for (input.allocations, 0..) |allocation, index| {
        decoded.allocations[index] = .{
            .scope_ordinal = allocation.scope_ordinal,
            .node_key = allocation.node_key,
            .binding_key = allocation.binding_key,
            .kind = allocation.kind,
            .object_byte_length = std.math.cast(
                u64,
                allocation.object_bytes.len,
            ) orelse return Error.InvalidManifest,
            .claim = allocation.claim,
            .object_sha256 = materializedObjectRootV1(
                allocation.kind,
                allocation.object_bytes,
            ),
        };
    }
    try validateDecodedV1(decoded);
    return decoded;
}

fn validateDecodedV1(decoded: DecodedV1) Error!void {
    if (decoded.source_bank_epoch == 0 or
        decoded.source_receipt_generation == 0 or
        decoded.restore_bank_epoch == 0 or
        decoded.restore_bank_epoch == decoded.source_bank_epoch or
        decoded.request_epoch == 0 or
        decoded.publication_next_sequence == 0 or
        decoded.owner_key == 0 or decoded.tree_key == 0 or
        decoded.authority_key == 0 or decoded.parent_claim.isZero() or
        decoded.tree_ceiling.isZero() or
        isZero(decoded.tenant_scope_sha256) or
        isZero(decoded.payload_snapshot_sha256) or
        isZero(decoded.challenge_sha256) or
        decoded.scope_count == 0 or decoded.scope_count > max_scopes or
        decoded.allocation_count == 0 or
        decoded.allocation_count > max_allocations)
        return Error.InvalidManifest;

    for (decoded.scopes[0..decoded.scope_count], 0..) |scope, index| {
        if (scope.scope_key == 0 or scope.tenant_key == 0 or
            scope.ceiling.isZero())
            return Error.InvalidManifest;
        if (index > 0) {
            const prior = decoded.scopes[index - 1];
            if (prior.scope_key == scope.scope_key)
                return Error.InvalidManifest;
            if (!scopeLess(prior, scope))
                return Error.NonCanonicalScopes;
        }
    }

    var scope_claims = [_]resource_bank.Claim{.{}} ** max_scopes;
    var aggregate: resource_bank.Claim = .{};
    for (decoded.allocations[0..decoded.allocation_count], 0..) |
        allocation,
        index,
    | {
        if (allocation.scope_ordinal >= decoded.scope_count or
            allocation.node_key == 0 or allocation.binding_key == 0 or
            allocation.object_byte_length == 0 or allocation.claim.isZero() or
            isZero(allocation.object_sha256))
            return Error.InvalidManifest;
        if (index > 0 and !allocationLess(
            decoded.allocations[index - 1],
            allocation,
        )) return Error.NonCanonicalAllocations;
        for (decoded.allocations[0..index]) |prior| {
            if ((prior.scope_ordinal == allocation.scope_ordinal and
                prior.node_key == allocation.node_key) or
                prior.binding_key == allocation.binding_key)
                return Error.InvalidManifest;
        }
        const scope_index: usize = @intCast(allocation.scope_ordinal);
        scope_claims[scope_index] = try addClaims(
            scope_claims[scope_index],
            allocation.claim,
        );
        aggregate = try addClaims(aggregate, allocation.claim);
    }
    for (scope_claims[0..decoded.scope_count], 0..) |claim, index| {
        if (!claimWithin(claim, decoded.scopes[index].ceiling))
            return Error.InvalidManifest;
    }
    if (!claimWithin(aggregate, decoded.tree_ceiling))
        return Error.InvalidManifest;
}

fn validateFreshTargetV1(
    snapshot: resource_bank.SnapshotV3,
    plan: DecodedV1,
    total_claim: resource_bank.Claim,
) Error!void {
    if (snapshot.bank_epoch != plan.restore_bank_epoch)
        return Error.TargetAuthorityMismatch;
    if (!snapshot.used.isZero() or !snapshot.peak.isZero() or
        snapshot.active_reservations != 0 or
        snapshot.committed_receipts != 0 or
        snapshot.active_child_leases != 0 or
        snapshot.active_lease_trees != 0 or
        snapshot.active_lease_scopes != 0 or
        snapshot.active_lease_nodes != 0 or
        snapshot.successful_reservations != 0 or
        snapshot.successful_commits != 0 or snapshot.cancellations != 0 or
        snapshot.releases != 0 or snapshot.child_opens != 0 or
        snapshot.lease_tree_opens != 0 or snapshot.lease_scope_opens != 0 or
        snapshot.lease_allocation_reserves != 0 or
        snapshot.lease_allocation_materializations != 0 or
        snapshot.lease_allocation_aborts != 0 or
        snapshot.lease_tree_closes != 0)
        return Error.TargetNotFresh;
    const node_capacity = snapshot.lease_node_pool_bytes /
        @sizeOf(resource_bank.LeaseNodeSlot);
    if (snapshot.lease_root_pool_bytes == 0 or
        node_capacity < plan.scope_count + plan.allocation_count)
        return Error.RestoreCapacityExceeded;
    if (!try snapshot.limits.fits(total_claim))
        return Error.RestoreCapacityExceeded;
}

fn allocationClaimV1(plan: DecodedV1) Error!resource_bank.Claim {
    var result: resource_bank.Claim = .{};
    for (plan.allocations[0..plan.allocation_count]) |allocation|
        result = try addClaims(result, allocation.claim);
    return result;
}

const PrepareStage = enum {
    none,
    reserved,
    committed,
    tree_open,
    session_bound,
    prepared,
};

fn cleanupPrepareFailureV1(
    bank: *resource_bank.Bank,
    stage: PrepareStage,
    reservation: resource_bank.Reservation,
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
    plan: DecodedV1,
    session_id: usize,
) void {
    switch (stage) {
        .none, .prepared => {},
        .reserved => bank.cancel(reservation) catch {},
        .committed => bank.release(receipt) catch {},
        .tree_open => {
            bank.closeLeaseTree(tree) catch {};
            bank.release(receipt) catch {};
        },
        .session_bound => {
            bank.closePublicationSession(
                receipt,
                plan.request_epoch,
                session_id,
                plan.publication_next_sequence,
            ) catch {};
            bank.closeLeaseTree(tree) catch {};
            bank.release(receipt) catch {};
        },
    }
}

fn scopeLess(a: ScopeV1, b: ScopeV1) bool {
    if (a.scope_key != b.scope_key) return a.scope_key < b.scope_key;
    return a.tenant_key < b.tenant_key;
}

fn allocationLess(a: AllocationV1, b: AllocationV1) bool {
    if (a.scope_ordinal != b.scope_ordinal)
        return a.scope_ordinal < b.scope_ordinal;
    if (a.node_key != b.node_key) return a.node_key < b.node_key;
    if (a.binding_key != b.binding_key)
        return a.binding_key < b.binding_key;
    if (a.kind != b.kind)
        return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    return std.mem.order(u8, &a.object_sha256, &b.object_sha256) == .lt;
}

fn addClaims(
    a: resource_bank.Claim,
    b: resource_bank.Claim,
) Error!resource_bank.Claim {
    var result: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        @field(result, field.name) = std.math.add(
            u64,
            @field(a, field.name),
            @field(b, field.name),
        ) catch return Error.ClaimOverflow;
    }
    return result;
}

fn claimWithin(
    claim: resource_bank.Claim,
    ceiling: resource_bank.Claim,
) bool {
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        if (@field(claim, field.name) > @field(ceiling, field.name))
            return false;
    }
    return true;
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        const end = std.math.add(usize, self.position, value.len) catch
            return Error.InvalidLength;
        if (end > self.bytes.len) return Error.InvalidLength;
        std.mem.copyForwards(u8, self.bytes[self.position..end], value);
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

    fn writeClaim(self: *Writer, claim: resource_bank.Claim) Error!void {
        inline for (std.meta.fields(resource_bank.Claim)) |field|
            try self.writeU64(@field(claim, field.name));
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

    fn readClaim(self: *Reader) Error!resource_bank.Claim {
        var claim: resource_bank.Claim = .{};
        inline for (std.meta.fields(resource_bank.Claim)) |field|
            @field(claim, field.name) = try self.readU64();
        return claim;
    }
};

test "ownership manifest rejects every single-byte mutation" {
    const tenant = filledDigest(0x44);
    const challenge = filledDigest(0x55);
    var payload_storage: [payload_store.minimum_encoded_bytes]u8 = undefined;
    const payload_wire = try payload_store.encodeSnapshotV1(
        tenant,
        &.{},
        &payload_storage,
    );
    var payload_entries: [payload_store.default_capacity]payload_store.EntryViewV1 = undefined;
    const payload_snapshot = try payload_store.decodeSnapshotV1(
        payload_wire,
        tenant,
        &payload_entries,
    );
    const scopes = [_]ScopeInputV1{
        .{
            .scope_key = 10,
            .tenant_key = 100,
            .ceiling = .{ .kv_bytes = 8 },
        },
        .{
            .scope_key = 20,
            .tenant_key = 200,
            .ceiling = .{ .output_journal_bytes = 6 },
        },
    };
    const allocations = [_]AllocationInputV1{
        .{
            .scope_ordinal = 0,
            .node_key = 1000,
            .binding_key = 10_000,
            .kind = .kv_page,
            .claim = .{ .kv_bytes = 8 },
            .object_bytes = "kv-page",
        },
        .{
            .scope_ordinal = 1,
            .node_key = 2000,
            .binding_key = 20_000,
            .kind = .output_journal,
            .claim = .{ .output_journal_bytes = 6 },
            .object_bytes = "output",
        },
    };
    var encoded_storage: [encoded_bytes]u8 = undefined;
    const encoded = try encodeV1(.{
        .source_bank_epoch = 41,
        .source_receipt_generation = 1,
        .restore_bank_epoch = 42,
        .request_epoch = 91,
        .publication_next_sequence = 7,
        .checkpoint_generation = 5,
        .owner_key = 7001,
        .tree_key = 7002,
        .authority_key = 7003,
        .parent_claim = .{ .capsule_bytes = 128, .queue_slots = 1 },
        .tree_ceiling = .{
            .kv_bytes = 8,
            .output_journal_bytes = 6,
        },
        .tenant_scope_sha256 = tenant,
        .payload_snapshot_sha256 = payload_snapshot.snapshot_sha256,
        .challenge_sha256 = challenge,
        .scopes = &scopes,
        .allocations = &allocations,
    }, &encoded_storage);
    const decoded = try decodeV1(encoded);
    var golden_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &golden_root,
        "59c777c9a576fdc87ecf8bb1d18ffbf1" ++
            "e98b30eef88e1ec8a5b312bfe68f394f",
    );
    try std.testing.expectEqualSlices(
        u8,
        &golden_root,
        &decoded.manifest_sha256,
    );

    var corrupted: [encoded_bytes]u8 = undefined;
    for (0..encoded.len) |index| {
        @memcpy(&corrupted, encoded);
        corrupted[index] ^= 0x01;
        const accepted = if (decodeV1(&corrupted)) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }

    @memcpy(&corrupted, encoded);
    std.mem.writeInt(u64, corrupted[376..384], 1, .little);
    const rerooted = manifestRootV1(
        corrupted[0 .. encoded_bytes - footer_bytes],
    );
    @memcpy(
        corrupted[encoded_bytes - footer_bytes .. encoded_bytes],
        &rerooted,
    );
    try std.testing.expectError(Error.InvalidManifest, decodeV1(&corrupted));
}

test "reacquire charges before materialization and rejects stale authority" {
    const tenant = filledDigest(0x44);
    const challenge = filledDigest(0x55);
    var payload_storage: [payload_store.minimum_encoded_bytes]u8 = undefined;
    const payload_wire = try payload_store.encodeSnapshotV1(
        tenant,
        &.{},
        &payload_storage,
    );
    var payload_entries: [payload_store.default_capacity]payload_store.EntryViewV1 = undefined;
    const payload_snapshot = try payload_store.decodeSnapshotV1(
        payload_wire,
        tenant,
        &payload_entries,
    );

    const parent_claim: resource_bank.Claim = .{
        .capsule_bytes = 128,
        .queue_slots = 1,
    };
    var source_slots = [_]resource_bank.Slot{.{}};
    var source_bank = try resource_bank.Bank.init(
        &source_slots,
        .{},
        41,
    );
    const source_receipt = try source_bank.commit(
        try source_bank.reserve(7001, parent_claim),
    );

    const scopes = [_]ScopeInputV1{
        .{
            .scope_key = 10,
            .tenant_key = 100,
            .ceiling = .{ .kv_bytes = 8 },
        },
        .{
            .scope_key = 20,
            .tenant_key = 200,
            .ceiling = .{ .output_journal_bytes = 6 },
        },
    };
    const allocations = [_]AllocationInputV1{
        .{
            .scope_ordinal = 0,
            .node_key = 1000,
            .binding_key = 10_000,
            .kind = .kv_page,
            .claim = .{ .kv_bytes = 8 },
            .object_bytes = "kv-page",
        },
        .{
            .scope_ordinal = 1,
            .node_key = 2000,
            .binding_key = 20_000,
            .kind = .output_journal,
            .claim = .{ .output_journal_bytes = 6 },
            .object_bytes = "output",
        },
    };
    var manifest_storage: [encoded_bytes]u8 = undefined;
    const manifest_wire = try encodeV1(.{
        .source_bank_epoch = source_receipt.bank_epoch,
        .source_receipt_generation = source_receipt.generation,
        .restore_bank_epoch = 42,
        .request_epoch = 91,
        .publication_next_sequence = 7,
        .checkpoint_generation = 5,
        .owner_key = source_receipt.owner_key,
        .tree_key = 7002,
        .authority_key = 7003,
        .parent_claim = parent_claim,
        .tree_ceiling = .{
            .kv_bytes = 8,
            .output_journal_bytes = 6,
        },
        .tenant_scope_sha256 = tenant,
        .payload_snapshot_sha256 = payload_snapshot.snapshot_sha256,
        .challenge_sha256 = challenge,
        .scopes = &scopes,
        .allocations = &allocations,
    }, &manifest_storage);

    const objects: capsule.ObjectsV1 = .{
        .model = .{ .abi_version = 1, .bytes = "model" },
        .tokenizer = .{ .abi_version = 2, .bytes = "tokenizer" },
        .execution_plan = .{ .abi_version = 3, .bytes = "plan" },
        .resource_state = .{
            .abi_version = abi_version,
            .bytes = manifest_wire,
        },
        .lane_state = .{ .abi_version = 5, .bytes = "lanes" },
        .kv_state = .{ .abi_version = 6, .bytes = "kv" },
        .sampler_state = .{ .abi_version = 7, .bytes = "sampler" },
        .output_state = .{ .abi_version = 8, .bytes = "output-state" },
        .publication_receipt = .{
            .abi_version = 9,
            .bytes = "publication",
        },
    };
    var capsule_storage: [capsule.encoded_bytes]u8 = undefined;
    const capsule_wire = try capsule.encodeV1(.{
        .execution_abi = 1,
        .request_epoch = 91,
        .publication_sequence = 7,
        .checkpoint_generation = 5,
        .kv_tokens = 8,
        .output_tokens = 4,
        .challenge_sha256 = challenge,
        .parent_capsule_sha256 = filledDigest(0x66),
    }, objects, &capsule_storage);

    var pending_slots = [_]resource_bank.Slot{.{}};
    var pending_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var pending_nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 4;
    var pending_bank = try resource_bank.Bank.initWithLeaseTree(
        &pending_slots,
        &pending_roots,
        &pending_nodes,
        .{
            .host_bytes = 1024,
            .capsule_bytes = 128,
            .kv_bytes = 8,
            .output_journal_bytes = 6,
            .queue_slots = 1,
        },
        42,
    );
    const prepared = try prepareReacquireV1(
        &pending_bank,
        capsule_wire,
        manifest_wire,
        payload_wire,
        0x1234,
    );
    const reserved_snapshot = try pending_bank.snapshotV3();
    try std.testing.expectEqual(@as(usize, 2), reserved_snapshot.active_lease_scopes);
    try std.testing.expectEqual(@as(usize, 2), reserved_snapshot.reserved_unmaterialized_allocations);
    try std.testing.expectEqual(@as(usize, 0), reserved_snapshot.live_allocations);
    try std.testing.expectEqual(@as(u64, 128), reserved_snapshot.used.capsule_bytes);
    try std.testing.expectEqual(@as(u64, 8), reserved_snapshot.used.kv_bytes);
    try std.testing.expectEqual(
        @as(u64, 6),
        reserved_snapshot.used.output_journal_bytes,
    );

    const wrong_objects = [_]MaterializedObjectV1{
        .{ .kind = .kv_page, .bytes = "wrong!!" },
        .{ .kind = .output_journal, .bytes = "output" },
    };
    try std.testing.expectError(
        Error.InvalidMaterialization,
        commitMaterializedV1(
            &pending_bank,
            prepared,
            manifest_wire,
            &wrong_objects,
        ),
    );
    const still_reserved = try pending_bank.snapshotV3();
    try std.testing.expectEqual(
        @as(usize, 2),
        still_reserved.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(@as(usize, 0), still_reserved.live_allocations);
    try abortPreparedReacquireAfterFreeV1(&pending_bank, prepared);
    const aborted_snapshot = try pending_bank.snapshotV3();
    try std.testing.expect(aborted_snapshot.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), aborted_snapshot.active_lease_trees);
    try std.testing.expectEqual(
        @as(usize, 0),
        aborted_snapshot.reserved_unmaterialized_allocations,
    );

    var target_slots = [_]resource_bank.Slot{.{}};
    var target_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var target_nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 4;
    var target_bank = try resource_bank.Bank.initWithLeaseTree(
        &target_slots,
        &target_roots,
        &target_nodes,
        .{
            .host_bytes = 1024,
            .capsule_bytes = 128,
            .kv_bytes = 8,
            .output_journal_bytes = 6,
            .queue_slots = 1,
        },
        42,
    );
    const exact_prepared = try prepareReacquireV1(
        &target_bank,
        capsule_wire,
        manifest_wire,
        payload_wire,
        0x1234,
    );
    const exact_objects = [_]MaterializedObjectV1{
        .{ .kind = .kv_page, .bytes = "kv-page" },
        .{ .kind = .output_journal, .bytes = "output" },
    };
    const active = try commitMaterializedV1(
        &target_bank,
        exact_prepared,
        manifest_wire,
        &exact_objects,
    );
    const live_snapshot = try target_bank.snapshotV3();
    try std.testing.expectEqual(
        @as(usize, 0),
        live_snapshot.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(@as(usize, 2), live_snapshot.live_allocations);

    const permit = try target_bank.beginPublicationWithLeaseTree(
        active.tree,
        91,
        0x1234,
        7,
    );
    try target_bank.abortPublication(permit);
    try std.testing.expectError(
        Error.TargetNotFresh,
        prepareReacquireV1(
            &target_bank,
            capsule_wire,
            manifest_wire,
            payload_wire,
            0x5678,
        ),
    );
    try std.testing.expectError(
        resource_bank.Error.StaleReservation,
        target_bank.release(source_receipt),
    );
}

fn filledDigest(value: u8) Digest {
    return [_]u8{value} ** 32;
}
