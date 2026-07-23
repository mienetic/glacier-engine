//! Transactional image/audio/video execution with exact per-buffer LeaseTree
//! ownership, early provisional retirement, and pointer-free receipts.

const std = @import("std");
const resource_bank = @import("resource_bank.zig");
const media = @import("media_contract.zig");
const decode_plan = @import("media_decode_plan.zig");
const fixture_api = @import("media_fixture.zig");
const transform = @import("media_transform.zig");
const flat = @import("media_runtime_txn.zig");

pub const Digest = [32]u8;
pub const runtime_abi: u64 = 0x474d_524c_0000_0001;
pub const receipt_abi: u64 = 0x474d_5245_0000_0001;
pub const receipt_magic = [_]u8{ 'G', 'M', 'R', 'L', 'E', 'A', 'S', '1' };
pub const maximum_bindings: usize = 4;
pub const binding_record_bytes: usize = 136;
pub const receipt_body_bytes: usize = 1504;
pub const receipt_bytes: usize = 1536;
pub const allowed_flags: u64 = 0;

const binding_offset: usize = 536;
const evidence_offset: usize =
    binding_offset + maximum_bindings * binding_record_bytes;
const tenant_offset: usize = evidence_offset + 9 * 32;
const resource_domain = "glacier-media-runtime-lease-resource-v1\x00";
const binding_domain = "glacier-media-runtime-lease-bindings-v1\x00";
const receipt_domain = "glacier-media-runtime-lease-receipt-v1\x00";
const mapping_accounting_bytes = flat.mapping_accounting_bytes;

const scope_key_base: u64 = 0x6d72_6c73_0000_0000;
const allocation_key_base: u64 = 0x6d72_6c61_0000_0000;
const binding_key_base: u64 = 0x6d72_6c62_0000_0000;

comptime {
    if (evidence_offset != 1080 or tenant_offset != 1368 or
        tenant_offset + 8 > receipt_body_bytes)
        @compileError("media runtime lease receipt layout drift");
}

pub const Error = error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidConfiguration,
    InvalidReceipt,
    InvalidState,
    PublicationFailed,
    ResourceAdmissionFailed,
    ResourceReceiptInvalid,
    TransformFailed,
};

pub const LeaseRoleV1 = enum(u64) {
    none = 0,
    decoded_source = 1,
    mappings = 2,
    scratch = 3,
    output = 4,
};

pub const NodeEvidenceV1 = struct {
    node_index: u32 = 0,
    generation: u64 = 0,
    parent_index: u32 = 0,
    parent_generation: u64 = 0,
    node_key: u64 = 0,
    tenant_key: u64 = 0,
    binding_key: u64 = 0,
    integrity: u64 = 0,
};

pub const BindingEvidenceV1 = struct {
    role: LeaseRoleV1 = .none,
    scope: NodeEvidenceV1 = .{},
    allocation: NodeEvidenceV1 = .{},
};

pub const LeaseExecutionReceiptV1 = struct {
    operation: transform.TransformOperationV1,
    kind: media.MediaKindV1,
    request_epoch: u64,
    resource_sequence: u64,
    media_sequence: u64,
    logical_units: u64,
    output_bytes: u64,
    mapping_count: u64,
    binding_count: u64,
    provisional_binding_count: u64,
    total_claim: resource_bank.Claim,
    tree: resource_bank.LeaseTreeV1,
    bindings: [maximum_bindings]BindingEvidenceV1,
    fixture_sha256: Digest,
    transform_plan_sha256: Digest,
    transform_receipt_sha256: Digest,
    resource_claim_sha256: Digest,
    timeline_event_sha256: Digest,
    publication_commit_sha256: Digest,
    output_sha256: Digest,
    mapping_chain_sha256: Digest,
    binding_manifest_sha256: Digest,
    tenant_key: u64,
    receipt_sha256: Digest,
};

const ScopeEntryV1 = struct {
    role: LeaseRoleV1,
    scope: resource_bank.LeaseNodeV1,
};

const LiveBindingV1 = struct {
    role: LeaseRoleV1,
    scope: resource_bank.LeaseNodeV1,
    allocation: resource_bank.LeaseNodeV1,
};

pub fn parentClaimForExecutionV1(
    encoded_fixture_bytes: usize,
) Error!resource_bank.Claim {
    const capsule_bytes = try checkedAdd(
        decode_plan.plan_bytes,
        transform.transform_plan_bytes,
    );
    return .{
        .capsule_bytes = capsule_bytes,
        .io_bytes = std.math.cast(
            u64,
            encoded_fixture_bytes,
        ) orelse return Error.ArithmeticOverflow,
        .queue_slots = 1,
    };
}

pub fn dynamicClaimForExecutionV1(
    plan: transform.TransformPlanV1,
) Error!resource_bank.Claim {
    const mapping_bytes = try checkedMul(
        plan.logical_units,
        mapping_accounting_bytes,
    );
    return .{
        .activation_bytes = plan.source_bytes,
        .output_journal_bytes = plan.output_bytes,
        .staging_bytes = try checkedAdd(
            mapping_bytes,
            plan.scratch_bytes,
        ),
    };
}

pub fn claimForRoleV1(
    plan: transform.TransformPlanV1,
    role: LeaseRoleV1,
) Error!resource_bank.Claim {
    return switch (role) {
        .none => Error.InvalidConfiguration,
        .decoded_source => .{
            .activation_bytes = plan.source_bytes,
        },
        .mappings => .{
            .staging_bytes = try checkedMul(
                plan.logical_units,
                mapping_accounting_bytes,
            ),
        },
        .scratch => if (plan.scratch_bytes == 0)
            Error.InvalidConfiguration
        else
            .{ .staging_bytes = plan.scratch_bytes },
        .output => .{
            .output_journal_bytes = plan.output_bytes,
        },
    };
}

pub fn bindingCountForPlanV1(
    plan: transform.TransformPlanV1,
) u64 {
    return if (plan.scratch_bytes == 0) 3 else 4;
}

pub fn provisionalBindingCountForPlanV1(
    plan: transform.TransformPlanV1,
) u64 {
    return if (plan.scratch_bytes == 0) 2 else 3;
}

pub fn bindingManifestRootV1(
    tree: resource_bank.LeaseTreeV1,
    bindings: []const BindingEvidenceV1,
    tenant_key: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(binding_domain);
    hashU64(&hash, receipt_abi);
    hashU64(&hash, tree.parent.integrity);
    hashU64(&hash, tree.tree_key);
    hashU64(&hash, tree.identity_generation);
    hashU64(&hash, tenant_key);
    hashU64(&hash, bindings.len);
    var encoded: [binding_record_bytes]u8 = undefined;
    for (bindings) |binding| {
        encodeBindingEvidenceV1(binding, &encoded);
        hash.update(&encoded);
    }
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn resourceCommitmentV1(
    request_epoch: u64,
    total_claim: resource_bank.Claim,
    tree: resource_bank.LeaseTreeV1,
    bindings: []const BindingEvidenceV1,
    tenant_key: u64,
    fixture_sha256: Digest,
    transform_plan_sha256: Digest,
) Error!Digest {
    if (request_epoch == 0 or tenant_key == 0 or bindings.len == 0 or
        bindings.len > maximum_bindings or
        !resource_bank.receiptIntegrityValidV1(tree.parent) or
        !resource_bank.leaseTreeIntegrityValidV1(tree))
        return Error.InvalidConfiguration;
    const binding_root = bindingManifestRootV1(
        tree,
        bindings,
        tenant_key,
    );
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(resource_domain);
    hashU64(&hash, runtime_abi);
    hashU64(&hash, request_epoch);
    hashReceipt(&hash, tree.parent);
    hashClaim(&hash, total_claim);
    hashU64(&hash, tree.tree_key);
    hashU64(&hash, tree.authority_key);
    hashU64(&hash, tree.identity_generation);
    hashU64(&hash, tree.generation);
    hashU64(&hash, tree.structural_revision);
    hashClaim(&hash, tree.ceiling);
    hashClaim(&hash, tree.current);
    hashU64(&hash, tree.active_nodes);
    hashU64(&hash, tree.state_digest);
    hashU64(&hash, tree.integrity);
    hash.update(&binding_root);
    hashU64(&hash, tenant_key);
    hash.update(&fixture_sha256);
    hash.update(&transform_plan_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn encodeLeaseExecutionReceiptV1(
    receipt: LeaseExecutionReceiptV1,
    storage: *[receipt_bytes]u8,
) Error![]const u8 {
    try validateReceiptShapeV1(receipt);
    writeReceiptBodyV1(receipt, storage[0..receipt_body_bytes]);
    @memcpy(
        storage[receipt_body_bytes..receipt_bytes],
        &receipt.receipt_sha256,
    );
    return storage;
}

pub fn decodeLeaseExecutionReceiptV1(
    encoded: []const u8,
) Error!LeaseExecutionReceiptV1 {
    if (encoded.len != receipt_bytes or
        !std.mem.eql(u8, encoded[0..8], &receipt_magic) or
        readU64(encoded, 8) != receipt_abi or
        readU64(encoded, 16) != receipt_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(
            u8,
            encoded[tenant_offset + 8 .. receipt_body_bytes],
            0,
        ))
        return Error.InvalidReceipt;
    const operation = std.meta.intToEnum(
        transform.TransformOperationV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidReceipt;
    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(encoded, 40),
    ) catch return Error.InvalidReceipt;
    const binding_count = readU64(encoded, 96);
    if (binding_count == 0 or binding_count > maximum_bindings)
        return Error.InvalidReceipt;
    const parent_claim = readClaim(encoded, 192);
    const parent: resource_bank.Receipt = .{
        .bank_epoch = readU64(encoded, 272),
        .slot_index = std.math.cast(
            u32,
            readU64(encoded, 280),
        ) orelse return Error.InvalidReceipt,
        .generation = readU64(encoded, 288),
        .owner_key = readU64(encoded, 296),
        .claim = parent_claim,
        .integrity = readU64(encoded, 304),
    };
    var bindings: [maximum_bindings]BindingEvidenceV1 =
        [_]BindingEvidenceV1{.{}} ** maximum_bindings;
    for (&bindings, 0..) |*binding, index| {
        binding.* = try decodeBindingEvidenceV1(
            encoded[binding_offset + index * binding_record_bytes .. binding_offset + (index + 1) * binding_record_bytes],
        );
    }
    const tree: resource_bank.LeaseTreeV1 = .{
        .parent = parent,
        .tree_key = readU64(encoded, 312),
        .authority_key = readU64(encoded, 320),
        .identity_generation = readU64(encoded, 328),
        .generation = readU64(encoded, 336),
        .structural_revision = readU64(encoded, 344),
        .ceiling = readClaim(encoded, 376),
        .current = readClaim(encoded, 456),
        .active_nodes = std.math.cast(
            u32,
            readU64(encoded, 352),
        ) orelse return Error.InvalidReceipt,
        .state_digest = readU64(encoded, 360),
        .integrity = readU64(encoded, 368),
    };
    const receipt: LeaseExecutionReceiptV1 = .{
        .operation = operation,
        .kind = kind,
        .request_epoch = readU64(encoded, 48),
        .resource_sequence = readU64(encoded, 56),
        .media_sequence = readU64(encoded, 64),
        .logical_units = readU64(encoded, 72),
        .output_bytes = readU64(encoded, 80),
        .mapping_count = readU64(encoded, 88),
        .binding_count = binding_count,
        .provisional_binding_count = readU64(encoded, 104),
        .total_claim = readClaim(encoded, 112),
        .tree = tree,
        .bindings = bindings,
        .fixture_sha256 = encoded[1080..1112].*,
        .transform_plan_sha256 = encoded[1112..1144].*,
        .transform_receipt_sha256 = encoded[1144..1176].*,
        .resource_claim_sha256 = encoded[1176..1208].*,
        .timeline_event_sha256 = encoded[1208..1240].*,
        .publication_commit_sha256 = encoded[1240..1272].*,
        .output_sha256 = encoded[1272..1304].*,
        .mapping_chain_sha256 = encoded[1304..1336].*,
        .binding_manifest_sha256 = encoded[1336..1368].*,
        .tenant_key = readU64(encoded, tenant_offset),
        .receipt_sha256 = encoded[receipt_body_bytes..receipt_bytes].*,
    };
    try validateReceiptShapeV1(receipt);
    return receipt;
}

pub fn leaseExecutionReceiptRootV1(
    receipt: LeaseExecutionReceiptV1,
) Digest {
    var body: [receipt_body_bytes]u8 = undefined;
    writeReceiptBodyV1(receipt, &body);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hash.update(&body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn verifyLeaseExecutionReceiptV1(
    state_before: media.PublicationStateV1,
    encoded_fixture: []const u8,
    encoded_transform_plan: []const u8,
    transform_receipt: transform.TransformReceiptV1,
    output: []const u8,
    mappings: []const transform.TransformMappingV1,
    expected_owner_key: u64,
    expected_tree_key: u64,
    expected_authority_key: u64,
    expected_tenant_key: u64,
    receipt: LeaseExecutionReceiptV1,
) Error!void {
    try validateReceiptShapeV1(receipt);
    transform.verifyReceiptV1(
        encoded_fixture,
        encoded_transform_plan,
        transform_receipt,
        output,
        mappings,
    ) catch return Error.TransformFailed;
    const fixture = fixture_api.parseFixtureV1(
        encoded_fixture,
    ) catch return Error.TransformFailed;
    const plan = transform.decodeTransformPlanV1(
        encoded_transform_plan,
    ) catch return Error.TransformFailed;
    const plan_sha256 = transform.transformPlanSha256V1(
        encoded_transform_plan,
    ) catch return Error.TransformFailed;
    const total_claim = flat.claimForExecutionV1(
        encoded_fixture.len,
        plan,
    ) catch return Error.InvalidReceipt;
    const parent_claim = try parentClaimForExecutionV1(
        encoded_fixture.len,
    );
    const dynamic_claim = try dynamicClaimForExecutionV1(plan);
    const binding_count = bindingCountForPlanV1(plan);
    if (!std.meta.eql(receipt.total_claim, total_claim) or
        !std.meta.eql(receipt.tree.parent.claim, parent_claim) or
        !std.meta.eql(receipt.tree.ceiling, dynamic_claim) or
        !std.meta.eql(receipt.tree.current, dynamic_claim) or
        receipt.tree.parent.owner_key != expected_owner_key or
        receipt.tree.tree_key != expected_tree_key or
        receipt.tree.authority_key != expected_authority_key or
        receipt.tenant_key != expected_tenant_key or
        receipt.request_epoch != state_before.request_epoch or
        receipt.resource_sequence != 0 or
        receipt.media_sequence != state_before.next_sequence or
        receipt.operation != plan.operation or
        receipt.kind != plan.kind or
        receipt.logical_units != plan.logical_units or
        receipt.output_bytes != plan.output_bytes or
        receipt.mapping_count != plan.logical_units or
        receipt.binding_count != binding_count or
        receipt.provisional_binding_count !=
            provisionalBindingCountForPlanV1(plan) or
        receipt.tree.active_nodes != binding_count * 2 or
        !std.mem.eql(
            u8,
            &receipt.fixture_sha256,
            &fixture.fixture_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.transform_plan_sha256,
            &plan_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.transform_receipt_sha256,
            &transform_receipt.receipt_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.output_sha256,
            &transform_receipt.output_sha256,
        ) or
        !std.mem.eql(
            u8,
            &receipt.mapping_chain_sha256,
            &transform_receipt.mapping_chain_sha256,
        ))
        return Error.InvalidReceipt;
    try verifyBindingsV1(plan, receipt);
    const active_bindings = receipt.bindings[0..@intCast(receipt.binding_count)];
    const binding_root = bindingManifestRootV1(
        receipt.tree,
        active_bindings,
        receipt.tenant_key,
    );
    const resource_root = try resourceCommitmentV1(
        receipt.request_epoch,
        receipt.total_claim,
        receipt.tree,
        active_bindings,
        receipt.tenant_key,
        receipt.fixture_sha256,
        receipt.transform_plan_sha256,
    );
    const event = flat.timelineEventForPlanV1(
        plan,
        fixture,
        state_before,
        plan_sha256,
    ) catch return Error.PublicationFailed;
    const event_root = media.timelineEventRootV1(
        event,
    ) catch return Error.PublicationFailed;
    const publication = media.preparePublicationV1(
        state_before,
        event,
        transform_receipt.output_sha256,
        resource_root,
    ) catch return Error.PublicationFailed;
    if (!std.mem.eql(
        u8,
        &receipt.binding_manifest_sha256,
        &binding_root,
    ) or
        !std.mem.eql(
            u8,
            &receipt.resource_claim_sha256,
            &resource_root,
        ) or
        !std.mem.eql(
            u8,
            &receipt.timeline_event_sha256,
            &event_root,
        ) or
        !std.mem.eql(
            u8,
            &receipt.publication_commit_sha256,
            &publication.commit_sha256,
        ))
        return Error.InvalidReceipt;
}

fn validateReceiptShapeV1(
    receipt: LeaseExecutionReceiptV1,
) Error!void {
    if (receipt.request_epoch == 0 or
        receipt.resource_sequence != 0 or
        receipt.media_sequence == 0 or
        receipt.logical_units == 0 or
        receipt.output_bytes == 0 or
        receipt.mapping_count != receipt.logical_units or
        receipt.binding_count == 0 or
        receipt.binding_count > maximum_bindings or
        receipt.provisional_binding_count + 1 != receipt.binding_count or
        receipt.tenant_key == 0 or
        receipt.total_claim.isZero() or
        !resource_bank.receiptIntegrityValidV1(receipt.tree.parent) or
        !resource_bank.leaseTreeIntegrityValidV1(receipt.tree) or
        isZero(receipt.fixture_sha256) or
        isZero(receipt.transform_plan_sha256) or
        isZero(receipt.transform_receipt_sha256) or
        isZero(receipt.resource_claim_sha256) or
        isZero(receipt.timeline_event_sha256) or
        isZero(receipt.publication_commit_sha256) or
        isZero(receipt.output_sha256) or
        isZero(receipt.mapping_chain_sha256) or
        isZero(receipt.binding_manifest_sha256) or
        isZero(receipt.receipt_sha256) or
        !std.mem.eql(
            u8,
            &receipt.binding_manifest_sha256,
            &bindingManifestRootV1(
                receipt.tree,
                receipt.bindings[0..@intCast(receipt.binding_count)],
                receipt.tenant_key,
            ),
        ) or
        !std.mem.eql(
            u8,
            &receipt.receipt_sha256,
            &leaseExecutionReceiptRootV1(receipt),
        ))
        return Error.InvalidReceipt;
    for (
        receipt.bindings[@intCast(receipt.binding_count)..],
    ) |binding| {
        if (!std.meta.eql(binding, BindingEvidenceV1{}))
            return Error.InvalidReceipt;
    }
}

fn verifyBindingsV1(
    plan: transform.TransformPlanV1,
    receipt: LeaseExecutionReceiptV1,
) Error!void {
    const count: usize = @intCast(receipt.binding_count);
    var roles: [maximum_bindings]LeaseRoleV1 = undefined;
    const role_count = fillRolesForPlanV1(plan, &roles);
    if (role_count != count) return Error.InvalidReceipt;
    for (receipt.bindings[0..count], 0..) |binding, index| {
        if (binding.role != roles[index])
            return Error.InvalidReceipt;
        const claim = try claimForRoleV1(plan, binding.role);
        const scope = nodeFromEvidenceV1(
            receipt.tree,
            binding.scope,
            .scope,
            claim,
        );
        const allocation = nodeFromEvidenceV1(
            receipt.tree,
            binding.allocation,
            .allocation,
            claim,
        );
        if (scope.node_index == allocation.node_index or
            scope.parent_index != std.math.maxInt(u32) or
            scope.parent_generation != receipt.tree.identity_generation or
            scope.node_key != scopeKeyV1(binding.role) or
            scope.tenant_key != receipt.tenant_key or
            scope.binding_key != 0 or
            allocation.parent_index != scope.node_index or
            allocation.parent_generation != scope.generation or
            allocation.node_key != allocationKeyV1(binding.role) or
            allocation.tenant_key != receipt.tenant_key or
            allocation.binding_key != bindingKeyV1(binding.role) or
            !resource_bank.leaseNodeIntegrityValidV1(scope) or
            !resource_bank.leaseNodeIntegrityValidV1(allocation))
            return Error.InvalidReceipt;
        for (receipt.bindings[0..index]) |prior| {
            if (prior.scope.node_index == binding.scope.node_index or
                prior.allocation.node_index == binding.allocation.node_index or
                prior.scope.node_index == binding.allocation.node_index or
                prior.allocation.node_index == binding.scope.node_index)
                return Error.InvalidReceipt;
        }
    }
}

fn nodeFromEvidenceV1(
    tree: resource_bank.LeaseTreeV1,
    evidence: NodeEvidenceV1,
    kind: resource_bank.LeaseNodeKind,
    claim: resource_bank.Claim,
) resource_bank.LeaseNodeV1 {
    return .{
        .parent = tree.parent,
        .tree_key = tree.tree_key,
        .tree_identity_generation = tree.identity_generation,
        .node_index = evidence.node_index,
        .generation = evidence.generation,
        .parent_index = evidence.parent_index,
        .parent_generation = evidence.parent_generation,
        .node_key = evidence.node_key,
        .tenant_key = evidence.tenant_key,
        .binding_key = evidence.binding_key,
        .kind = kind,
        .ceiling = claim,
        .claim = if (kind == .allocation) claim else .{},
        .integrity = evidence.integrity,
    };
}

fn evidenceFromNodeV1(
    node: resource_bank.LeaseNodeV1,
) NodeEvidenceV1 {
    return .{
        .node_index = node.node_index,
        .generation = node.generation,
        .parent_index = node.parent_index,
        .parent_generation = node.parent_generation,
        .node_key = node.node_key,
        .tenant_key = node.tenant_key,
        .binding_key = node.binding_key,
        .integrity = node.integrity,
    };
}

fn writeReceiptBodyV1(
    receipt: LeaseExecutionReceiptV1,
    output: []u8,
) void {
    std.debug.assert(output.len == receipt_body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &receipt_magic);
    writeU64(output, 8, receipt_abi);
    writeU64(output, 16, receipt_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(receipt.operation));
    writeU64(output, 40, @intFromEnum(receipt.kind));
    writeU64(output, 48, receipt.request_epoch);
    writeU64(output, 56, receipt.resource_sequence);
    writeU64(output, 64, receipt.media_sequence);
    writeU64(output, 72, receipt.logical_units);
    writeU64(output, 80, receipt.output_bytes);
    writeU64(output, 88, receipt.mapping_count);
    writeU64(output, 96, receipt.binding_count);
    writeU64(output, 104, receipt.provisional_binding_count);
    writeClaim(output, 112, receipt.total_claim);
    writeClaim(output, 192, receipt.tree.parent.claim);
    writeU64(output, 272, receipt.tree.parent.bank_epoch);
    writeU64(output, 280, receipt.tree.parent.slot_index);
    writeU64(output, 288, receipt.tree.parent.generation);
    writeU64(output, 296, receipt.tree.parent.owner_key);
    writeU64(output, 304, receipt.tree.parent.integrity);
    writeU64(output, 312, receipt.tree.tree_key);
    writeU64(output, 320, receipt.tree.authority_key);
    writeU64(output, 328, receipt.tree.identity_generation);
    writeU64(output, 336, receipt.tree.generation);
    writeU64(output, 344, receipt.tree.structural_revision);
    writeU64(output, 352, receipt.tree.active_nodes);
    writeU64(output, 360, receipt.tree.state_digest);
    writeU64(output, 368, receipt.tree.integrity);
    writeClaim(output, 376, receipt.tree.ceiling);
    writeClaim(output, 456, receipt.tree.current);
    for (receipt.bindings, 0..) |binding, index| {
        encodeBindingEvidenceV1(
            binding,
            output[binding_offset + index * binding_record_bytes .. binding_offset + (index + 1) * binding_record_bytes],
        );
    }
    const roots = [_]Digest{
        receipt.fixture_sha256,
        receipt.transform_plan_sha256,
        receipt.transform_receipt_sha256,
        receipt.resource_claim_sha256,
        receipt.timeline_event_sha256,
        receipt.publication_commit_sha256,
        receipt.output_sha256,
        receipt.mapping_chain_sha256,
        receipt.binding_manifest_sha256,
    };
    for (roots, 0..) |root, index|
        @memcpy(
            output[evidence_offset + index * 32 .. evidence_offset + (index + 1) * 32],
            &root,
        );
    writeU64(output, tenant_offset, receipt.tenant_key);
}

fn encodeBindingEvidenceV1(
    binding: BindingEvidenceV1,
    output: []u8,
) void {
    std.debug.assert(output.len == binding_record_bytes);
    @memset(output, 0);
    writeU64(output, 0, @intFromEnum(binding.role));
    writeNodeEvidenceV1(output, 8, binding.scope);
    writeNodeEvidenceV1(output, 72, binding.allocation);
}

fn decodeBindingEvidenceV1(
    encoded: []const u8,
) Error!BindingEvidenceV1 {
    if (encoded.len != binding_record_bytes)
        return Error.InvalidReceipt;
    const role = std.meta.intToEnum(
        LeaseRoleV1,
        readU64(encoded, 0),
    ) catch return Error.InvalidReceipt;
    return .{
        .role = role,
        .scope = try readNodeEvidenceV1(encoded, 8),
        .allocation = try readNodeEvidenceV1(encoded, 72),
    };
}

fn writeNodeEvidenceV1(
    output: []u8,
    offset: usize,
    node: NodeEvidenceV1,
) void {
    writeU64(output, offset, node.node_index);
    writeU64(output, offset + 8, node.generation);
    writeU64(output, offset + 16, node.parent_index);
    writeU64(output, offset + 24, node.parent_generation);
    writeU64(output, offset + 32, node.node_key);
    writeU64(output, offset + 40, node.tenant_key);
    writeU64(output, offset + 48, node.binding_key);
    writeU64(output, offset + 56, node.integrity);
}

fn readNodeEvidenceV1(
    input: []const u8,
    offset: usize,
) Error!NodeEvidenceV1 {
    return .{
        .node_index = std.math.cast(
            u32,
            readU64(input, offset),
        ) orelse return Error.InvalidReceipt,
        .generation = readU64(input, offset + 8),
        .parent_index = std.math.cast(
            u32,
            readU64(input, offset + 16),
        ) orelse return Error.InvalidReceipt,
        .parent_generation = readU64(input, offset + 24),
        .node_key = readU64(input, offset + 32),
        .tenant_key = readU64(input, offset + 40),
        .binding_key = readU64(input, offset + 48),
        .integrity = readU64(input, offset + 56),
    };
}

fn fillRolesForPlanV1(
    plan: transform.TransformPlanV1,
    roles: *[maximum_bindings]LeaseRoleV1,
) usize {
    roles[0] = .decoded_source;
    roles[1] = .mappings;
    var count: usize = 2;
    if (plan.scratch_bytes != 0) {
        roles[count] = .scratch;
        count += 1;
    }
    roles[count] = .output;
    return count + 1;
}

fn scopeKeyV1(role: LeaseRoleV1) u64 {
    return scope_key_base | @intFromEnum(role);
}

fn allocationKeyV1(role: LeaseRoleV1) u64 {
    return allocation_key_base | @intFromEnum(role);
}

fn bindingKeyV1(role: LeaseRoleV1) u64 {
    return binding_key_base | @intFromEnum(role);
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

fn writeClaim(
    output: []u8,
    offset: usize,
    claim: resource_bank.Claim,
) void {
    inline for (
        std.meta.fields(resource_bank.Claim),
        0..,
    ) |field, index|
        writeU64(
            output,
            offset + index * 8,
            @field(claim, field.name),
        );
}

fn readClaim(
    input: []const u8,
    offset: usize,
) resource_bank.Claim {
    var claim: resource_bank.Claim = .{};
    inline for (
        std.meta.fields(resource_bank.Claim),
        0..,
    ) |field, index|
        @field(claim, field.name) = readU64(
            input,
            offset + index * 8,
        );
    return claim;
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashReceipt(
    hash: *std.crypto.hash.sha2.Sha256,
    receipt: resource_bank.Receipt,
) void {
    hashU64(hash, receipt.bank_epoch);
    hashU64(hash, receipt.slot_index);
    hashU64(hash, receipt.generation);
    hashU64(hash, receipt.owner_key);
    hashClaim(hash, receipt.claim);
    hashU64(hash, receipt.integrity);
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

const SessionPhase = enum {
    idle,
    building,
    prepared,
    committing,
    committed,
    output_retained,
    poisoned,
    closed,
};

const TransactionState = enum {
    prepared,
    committed,
    aborted,
};

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    receipt: resource_bank.Receipt = undefined,
    tree: resource_bank.LeaseTreeV1 = undefined,
    scopes: [maximum_bindings]ScopeEntryV1 = undefined,
    scope_count: usize = 0,
    live_bindings: [maximum_bindings]LiveBindingV1 = undefined,
    live_count: usize = 0,
    owner_key: u64 = 0,
    tree_key: u64 = 0,
    authority_key: u64 = 0,
    tenant_key: u64 = 0,
    request_epoch: u64 = 0,
    media_state: *media.PublicationStateV1 = undefined,
    admitted_total_claim: resource_bank.Claim = .{},
    admitted_parent_claim: resource_bank.Claim = .{},
    admitted_dynamic_claim: resource_bank.Claim = .{},
    admitted_fixture_sha256: Digest = [_]u8{0} ** 32,
    admitted_plan_sha256: Digest = [_]u8{0} ** 32,
    initialized: bool = false,
    published: bool = false,
    phase: SessionPhase = .idle,
    next_resource_sequence: u64 = 0,
    next_generation: u64 = 1,
    active_generation: u64 = 0,
    active_permit: ?resource_bank.PublicationPermit = null,
    active_transform_receipt: ?transform.TransformReceiptV1 = null,
    active_publication: ?media.PreparedPublicationV1 = null,
    active_event_sha256: Digest = [_]u8{0} ** 32,
    active_resource_sha256: Digest = [_]u8{0} ** 32,
    active_fixture: ?[]const u8 = null,
    active_transform_plan: ?[]const u8 = null,
    active_decoded_source: ?[]u8 = null,
    active_output: ?[]u8 = null,
    active_mappings: ?[]transform.TransformMappingV1 = null,
    active_scratch: ?[]u8 = null,

    pub fn init(
        self: *Session,
        bank: *resource_bank.Bank,
        owner_key: u64,
        tree_key: u64,
        authority_key: u64,
        tenant_key: u64,
        request_epoch: u64,
        publication_state: *media.PublicationStateV1,
        encoded_fixture: []const u8,
        encoded_transform_plan: []const u8,
    ) Error!void {
        if (self.initialized) return Error.InvalidState;
        if (owner_key == 0 or tree_key == 0 or authority_key == 0 or
            tenant_key == 0 or request_epoch == 0 or
            publication_state.request_epoch != request_epoch)
            return Error.InvalidConfiguration;
        const fixture = fixture_api.parseFixtureV1(
            encoded_fixture,
        ) catch return Error.TransformFailed;
        const plan = transform.decodeTransformPlanV1(
            encoded_transform_plan,
        ) catch return Error.TransformFailed;
        const plan_sha256 = transform.transformPlanSha256V1(
            encoded_transform_plan,
        ) catch return Error.TransformFailed;
        if (!std.mem.eql(
            u8,
            &publication_state.media_object_sha256,
            &plan.media_object_sha256,
        ) or
            !std.mem.eql(
                u8,
                &fixture.media_object_sha256,
                &plan.media_object_sha256,
            ) or
            !std.meta.eql(
                publication_state.timeline_base,
                outputTimelineBaseV1(plan),
            ))
            return Error.InvalidConfiguration;
        const total_claim = flat.claimForExecutionV1(
            encoded_fixture.len,
            plan,
        ) catch return Error.InvalidConfiguration;
        const parent_claim = try parentClaimForExecutionV1(
            encoded_fixture.len,
        );
        const dynamic_claim = try dynamicClaimForExecutionV1(plan);
        if (!std.meta.eql(
            total_claim,
            try joinedClaimV1(parent_claim, dynamic_claim),
        )) return Error.InvalidConfiguration;

        const reservation = bank.reserve(
            owner_key,
            parent_claim,
        ) catch return Error.ResourceAdmissionFailed;
        const receipt = bank.commit(reservation) catch {
            bank.cancel(reservation) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceAdmissionFailed;
        };
        var tree = bank.openLeaseTree(
            receipt,
            tree_key,
            authority_key,
            dynamic_claim,
        ) catch {
            bank.release(receipt) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceAdmissionFailed;
        };
        var roles: [maximum_bindings]LeaseRoleV1 = undefined;
        const role_count = fillRolesForPlanV1(plan, &roles);
        var scopes: [maximum_bindings]ScopeEntryV1 = undefined;
        for (roles[0..role_count], 0..) |role, index| {
            const claim = try claimForRoleV1(plan, role);
            const opened = bank.openLeaseScope(
                tree,
                scopeKeyV1(role),
                tenant_key,
                claim,
            ) catch {
                cleanupUnboundV1(bank, receipt, tree) catch
                    return Error.ResourceReceiptInvalid;
                return Error.ResourceAdmissionFailed;
            };
            tree = opened.tree;
            scopes[index] = .{
                .role = role,
                .scope = opened.scope,
            };
        }
        bank.bindPublicationSessionWithLeaseTree(
            tree,
            request_epoch,
            @intFromPtr(self),
        ) catch {
            cleanupUnboundV1(bank, receipt, tree) catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        self.* = .{
            .bank = bank,
            .receipt = receipt,
            .tree = tree,
            .scopes = scopes,
            .scope_count = role_count,
            .owner_key = owner_key,
            .tree_key = tree_key,
            .authority_key = authority_key,
            .tenant_key = tenant_key,
            .request_epoch = request_epoch,
            .media_state = publication_state,
            .admitted_total_claim = total_claim,
            .admitted_parent_claim = parent_claim,
            .admitted_dynamic_claim = dynamic_claim,
            .admitted_fixture_sha256 = fixture.fixture_sha256,
            .admitted_plan_sha256 = plan_sha256,
            .initialized = true,
        };
    }

    pub fn prepare(
        self: *Session,
        encoded_fixture: []const u8,
        encoded_decode_plan: []const u8,
        encoded_transform_plan: []const u8,
        decoded_source: []u8,
        output: []u8,
        mappings: []transform.TransformMappingV1,
        scratch: []u8,
    ) Error!Transaction {
        if (!self.initialized or self.phase != .idle or
            self.published or self.active_generation != 0 or
            self.live_count != 0)
            return Error.InvalidState;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return Error.InvalidState;
        const fixture = fixture_api.parseFixtureV1(
            encoded_fixture,
        ) catch return Error.TransformFailed;
        const plan = transform.decodeTransformPlanV1(
            encoded_transform_plan,
        ) catch return Error.TransformFailed;
        const plan_sha256 = transform.transformPlanSha256V1(
            encoded_transform_plan,
        ) catch return Error.TransformFailed;
        const total_claim = flat.claimForExecutionV1(
            encoded_fixture.len,
            plan,
        ) catch return Error.InvalidConfiguration;
        const parent_claim = try parentClaimForExecutionV1(
            encoded_fixture.len,
        );
        const dynamic_claim = try dynamicClaimForExecutionV1(plan);
        if (!std.meta.eql(total_claim, self.admitted_total_claim) or
            !std.meta.eql(parent_claim, self.admitted_parent_claim) or
            !std.meta.eql(dynamic_claim, self.admitted_dynamic_claim) or
            !std.mem.eql(
                u8,
                &fixture.fixture_sha256,
                &self.admitted_fixture_sha256,
            ) or
            !std.mem.eql(
                u8,
                &plan_sha256,
                &self.admitted_plan_sha256,
            ) or
            self.media_state.request_epoch != self.request_epoch or
            !std.mem.eql(
                u8,
                &self.media_state.media_object_sha256,
                &plan.media_object_sha256,
            ) or
            !std.meta.eql(
                self.media_state.timeline_base,
                outputTimelineBaseV1(plan),
            ))
            return Error.InvalidConfiguration;
        const source_bytes = std.math.cast(
            usize,
            plan.source_bytes,
        ) orelse return Error.InvalidConfiguration;
        const output_bytes = std.math.cast(
            usize,
            plan.output_bytes,
        ) orelse return Error.InvalidConfiguration;
        const mapping_count = std.math.cast(
            usize,
            plan.logical_units,
        ) orelse return Error.InvalidConfiguration;
        const scratch_bytes = std.math.cast(
            usize,
            plan.scratch_bytes,
        ) orelse return Error.InvalidConfiguration;
        if (decoded_source.len < source_bytes or
            output.len < output_bytes or
            mappings.len < mapping_count or
            scratch.len < scratch_bytes)
            return Error.BufferTooSmall;
        const source_slice = decoded_source[0..source_bytes];
        const output_slice = output[0..output_bytes];
        const mapping_slice = mappings[0..mapping_count];
        const scratch_slice = scratch[0..scratch_bytes];

        var specs: [maximum_bindings]resource_bank.LeaseAllocationSpecV1 =
            undefined;
        var leaves: [maximum_bindings]resource_bank.LeaseNodeV1 = undefined;
        for (self.scopes[0..self.scope_count], 0..) |scope, index| {
            specs[index] = .{
                .scope = scope.scope,
                .node_key = allocationKeyV1(scope.role),
                .binding_key = bindingKeyV1(scope.role),
                .claim = try claimForRoleV1(plan, scope.role),
            };
        }
        const reservation = self.bank.reserveAllocationsForSession(
            self.tree,
            self.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
            specs[0..self.scope_count],
            leaves[0..self.scope_count],
        ) catch return Error.ResourceAdmissionFailed;
        @memset(scratch_slice, 0);
        const materialized_tree = self.bank.commitAllocationsAfterAllocate(
            reservation.batch,
        ) catch {
            scrubBuffers(
                source_slice,
                output_slice,
                mapping_slice,
                scratch_slice,
            );
            self.tree = self.bank.abortAllocationsAfterFree(
                reservation.batch,
            ) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            return Error.ResourceReceiptInvalid;
        };
        self.tree = materialized_tree;
        self.live_count = self.scope_count;
        for (self.scopes[0..self.scope_count], 0..) |scope, index| {
            self.live_bindings[index] = .{
                .role = scope.role,
                .scope = scope.scope,
                .allocation = leaves[index],
            };
        }
        self.active_fixture = encoded_fixture;
        self.active_transform_plan = encoded_transform_plan;
        self.active_decoded_source = source_slice;
        self.active_output = output_slice;
        self.active_mappings = mapping_slice;
        self.active_scratch = scratch_slice;
        self.phase = .building;

        const permit = self.bank.beginPublicationWithLeaseTree(
            self.tree,
            self.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch {
            self.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        self.active_permit = permit;
        const transform_receipt = transform.executeV1(
            encoded_fixture,
            encoded_decode_plan,
            encoded_transform_plan,
            source_slice,
            output_slice,
            mapping_slice,
        ) catch {
            self.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.TransformFailed;
        };
        transform.verifyReceiptV1(
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output_slice,
            mapping_slice,
        ) catch {
            self.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.TransformFailed;
        };
        const event = flat.timelineEventForPlanV1(
            plan,
            fixture,
            self.media_state.*,
            plan_sha256,
        ) catch {
            self.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.PublicationFailed;
        };
        const event_sha256 = media.timelineEventRootV1(
            event,
        ) catch {
            self.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.PublicationFailed;
        };
        var evidence: [maximum_bindings]BindingEvidenceV1 =
            [_]BindingEvidenceV1{.{}} ** maximum_bindings;
        self.copyLiveEvidenceV1(&evidence);
        const resource_sha256 = resourceCommitmentV1(
            self.request_epoch,
            self.admitted_total_claim,
            self.tree,
            evidence[0..self.live_count],
            self.tenant_key,
            fixture.fixture_sha256,
            plan_sha256,
        ) catch {
            self.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        const publication = media.preparePublicationV1(
            self.media_state.*,
            event,
            transform_receipt.output_sha256,
            resource_sha256,
        ) catch {
            self.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.PublicationFailed;
        };
        const generation = self.next_generation;
        self.next_generation += 1;
        self.phase = .prepared;
        self.active_generation = generation;
        self.active_transform_receipt = transform_receipt;
        self.active_publication = publication;
        self.active_event_sha256 = event_sha256;
        self.active_resource_sha256 = resource_sha256;
        return .{
            .session = self,
            .generation = generation,
            .state = .prepared,
        };
    }

    pub fn retireProvisional(self: *Session) Error!void {
        if (!self.initialized or self.phase != .committed or
            self.active_permit != null or self.live_count == 0)
            return Error.InvalidState;
        if (self.active_decoded_source) |source| @memset(source, 0);
        if (self.active_mappings) |mappings|
            @memset(std.mem.sliceAsBytes(mappings), 0);
        if (self.active_scratch) |scratch| @memset(scratch, 0);
        var index: usize = 0;
        while (index < self.live_count) {
            if (self.live_bindings[index].role == .output) {
                index += 1;
                continue;
            }
            self.releaseBindingAtV1(
                index,
                self.next_resource_sequence,
            ) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
        }
        self.active_decoded_source = null;
        self.active_mappings = null;
        self.active_scratch = null;
        self.phase = .output_retained;
    }

    pub fn closeAndRelease(self: *Session) Error!void {
        if (!self.initialized or
            (self.phase != .idle and
                self.phase != .committed and
                self.phase != .output_retained) or
            self.active_permit != null or self.active_generation != 0)
            return Error.InvalidState;
        if (self.phase == .committed) {
            if (self.active_decoded_source) |source| @memset(source, 0);
            if (self.active_mappings) |mappings|
                @memset(std.mem.sliceAsBytes(mappings), 0);
            if (self.active_scratch) |scratch| @memset(scratch, 0);
        }
        while (self.live_count != 0) {
            self.releaseBindingAtV1(
                self.live_count - 1,
                self.next_resource_sequence,
            ) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
        }
        self.bank.validateLeaseTree(self.tree) catch
            return Error.ResourceReceiptInvalid;
        self.bank.closePublicationSession(
            self.receipt,
            self.request_epoch,
            @intFromPtr(self),
            self.next_resource_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        self.bank.closeLeaseTree(self.tree) catch
            return Error.ResourceReceiptInvalid;
        self.bank.release(self.receipt) catch
            return Error.ResourceReceiptInvalid;
        self.initialized = false;
        self.phase = .closed;
        self.clearCandidateV1(false);
    }

    fn rollbackActiveV1(self: *Session) Error!void {
        self.scrubActiveV1();
        if (self.active_permit) |permit| {
            self.bank.abortPublication(permit) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
            self.active_permit = null;
        }
        while (self.live_count != 0) {
            self.releaseBindingAtV1(
                self.live_count - 1,
                self.next_resource_sequence,
            ) catch {
                self.phase = .poisoned;
                return Error.ResourceReceiptInvalid;
            };
        }
        self.clearCandidateV1(false);
        self.phase = .idle;
    }

    fn releaseBindingAtV1(
        self: *Session,
        index: usize,
        expected_sequence: u64,
    ) Error!void {
        if (index >= self.live_count)
            return Error.InvalidState;
        const binding = self.live_bindings[index];
        const retire = self.bank.beginRetireSubtreeForSession(
            self.tree,
            binding.scope,
            self.request_epoch,
            @intFromPtr(self),
            expected_sequence,
        ) catch return Error.ResourceReceiptInvalid;
        const authorized = self.bank.authorizeFree(
            retire.ticket,
        ) catch {
            self.tree = self.bank.cancelRetire(
                retire.ticket,
            ) catch return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        self.tree = self.bank.commitFreeAfterAllocatorFree(
            authorized.permit,
        ) catch return Error.ResourceReceiptInvalid;
        var shift = index;
        while (shift + 1 < self.live_count) : (shift += 1)
            self.live_bindings[shift] = self.live_bindings[shift + 1];
        self.live_count -= 1;
    }

    fn copyLiveEvidenceV1(
        self: *const Session,
        output: *[maximum_bindings]BindingEvidenceV1,
    ) void {
        output.* = [_]BindingEvidenceV1{.{}} ** maximum_bindings;
        for (self.live_bindings[0..self.live_count], 0..) |binding, index| {
            output[index] = .{
                .role = binding.role,
                .scope = evidenceFromNodeV1(binding.scope),
                .allocation = evidenceFromNodeV1(binding.allocation),
            };
        }
    }

    fn scrubActiveV1(self: *Session) void {
        if (self.active_decoded_source) |source| @memset(source, 0);
        if (self.active_output) |output| @memset(output, 0);
        if (self.active_mappings) |mappings|
            @memset(std.mem.sliceAsBytes(mappings), 0);
        if (self.active_scratch) |scratch| @memset(scratch, 0);
    }

    fn clearCandidateV1(
        self: *Session,
        retain_buffers: bool,
    ) void {
        self.active_generation = 0;
        self.active_permit = null;
        self.active_transform_receipt = null;
        self.active_publication = null;
        self.active_event_sha256 = [_]u8{0} ** 32;
        self.active_resource_sha256 = [_]u8{0} ** 32;
        self.active_fixture = null;
        self.active_transform_plan = null;
        if (!retain_buffers) {
            self.active_decoded_source = null;
            self.active_output = null;
            self.active_mappings = null;
            self.active_scratch = null;
        }
    }
};

pub const Transaction = struct {
    session: *Session,
    generation: u64,
    state: TransactionState,

    pub fn commit(
        self: *Transaction,
    ) Error!LeaseExecutionReceiptV1 {
        if (!self.owns(.prepared))
            return Error.InvalidState;
        const session = self.session;
        const permit = session.active_permit orelse
            return Error.InvalidState;
        const transform_receipt =
            session.active_transform_receipt orelse
            return Error.InvalidState;
        const publication = session.active_publication orelse
            return Error.InvalidState;
        const encoded_fixture = session.active_fixture orelse
            return Error.InvalidState;
        const encoded_transform_plan =
            session.active_transform_plan orelse
            return Error.InvalidState;
        const output = session.active_output orelse
            return Error.InvalidState;
        const mappings = session.active_mappings orelse
            return Error.InvalidState;
        session.phase = .committing;
        session.bank.validateLeaseTree(session.tree) catch {
            self.state = .aborted;
            session.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        for (
            session.live_bindings[0..session.live_count],
        ) |binding| {
            session.bank.validateLeaseNode(
                session.tree,
                binding.scope,
            ) catch {
                self.state = .aborted;
                session.rollbackActiveV1() catch
                    return Error.ResourceReceiptInvalid;
                return Error.ResourceReceiptInvalid;
            };
            session.bank.validateLeaseNode(
                session.tree,
                binding.allocation,
            ) catch {
                self.state = .aborted;
                session.rollbackActiveV1() catch
                    return Error.ResourceReceiptInvalid;
                return Error.ResourceReceiptInvalid;
            };
        }
        session.bank.validatePublication(permit) catch {
            self.state = .aborted;
            session.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.ResourceReceiptInvalid;
        };
        transform.verifyReceiptV1(
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output,
            mappings,
        ) catch {
            self.state = .aborted;
            session.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.TransformFailed;
        };
        var state_after = session.media_state.*;
        media.commitPublicationV1(
            &state_after,
            publication,
        ) catch {
            self.state = .aborted;
            session.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.PublicationFailed;
        };
        const fixture = fixture_api.parseFixtureV1(
            encoded_fixture,
        ) catch unreachable;
        const plan = transform.decodeTransformPlanV1(
            encoded_transform_plan,
        ) catch unreachable;
        var bindings: [maximum_bindings]BindingEvidenceV1 =
            [_]BindingEvidenceV1{.{}} ** maximum_bindings;
        session.copyLiveEvidenceV1(&bindings);
        const binding_root = bindingManifestRootV1(
            session.tree,
            bindings[0..session.live_count],
            session.tenant_key,
        );
        var receipt: LeaseExecutionReceiptV1 = .{
            .operation = plan.operation,
            .kind = plan.kind,
            .request_epoch = session.request_epoch,
            .resource_sequence = permit.sequence,
            .media_sequence = publication.sequence,
            .logical_units = plan.logical_units,
            .output_bytes = plan.output_bytes,
            .mapping_count = plan.logical_units,
            .binding_count = session.live_count,
            .provisional_binding_count = provisionalBindingCountForPlanV1(plan),
            .total_claim = session.admitted_total_claim,
            .tree = session.tree,
            .bindings = bindings,
            .fixture_sha256 = fixture.fixture_sha256,
            .transform_plan_sha256 = transform_receipt.transform_plan_sha256,
            .transform_receipt_sha256 = transform_receipt.receipt_sha256,
            .resource_claim_sha256 = session.active_resource_sha256,
            .timeline_event_sha256 = session.active_event_sha256,
            .publication_commit_sha256 = publication.commit_sha256,
            .output_sha256 = transform_receipt.output_sha256,
            .mapping_chain_sha256 = transform_receipt.mapping_chain_sha256,
            .binding_manifest_sha256 = binding_root,
            .tenant_key = session.tenant_key,
            .receipt_sha256 = [_]u8{0} ** 32,
        };
        receipt.receipt_sha256 = leaseExecutionReceiptRootV1(
            receipt,
        );
        verifyLeaseExecutionReceiptV1(
            session.media_state.*,
            encoded_fixture,
            encoded_transform_plan,
            transform_receipt,
            output,
            mappings,
            session.owner_key,
            session.tree_key,
            session.authority_key,
            session.tenant_key,
            receipt,
        ) catch {
            self.state = .aborted;
            session.rollbackActiveV1() catch
                return Error.ResourceReceiptInvalid;
            return Error.InvalidReceipt;
        };

        // The complete media candidate, every live lease, and the Bank permit
        // are now fixed. These request-local mutations are bounded and
        // infallible under the single-owner session contract.
        session.media_state.* = state_after;
        session.bank.commitPublicationAssumeValid(permit);
        session.next_resource_sequence = permit.sequence + 1;
        session.published = true;
        session.phase = .committed;
        session.clearCandidateV1(true);
        self.state = .committed;
        return receipt;
    }

    pub fn abort(self: *Transaction) Error!void {
        if (!self.owns(.prepared))
            return Error.InvalidState;
        self.state = .aborted;
        try self.session.rollbackActiveV1();
    }

    fn owns(
        self: *const Transaction,
        expected: TransactionState,
    ) bool {
        return self.state == expected and
            self.session.initialized and
            self.session.active_generation == self.generation and
            self.session.phase == .prepared;
    }
};

fn cleanupUnboundV1(
    bank: *resource_bank.Bank,
    receipt: resource_bank.Receipt,
    tree: resource_bank.LeaseTreeV1,
) Error!void {
    bank.closeLeaseTree(tree) catch
        return Error.ResourceReceiptInvalid;
    bank.release(receipt) catch
        return Error.ResourceReceiptInvalid;
}

fn joinedClaimV1(
    parent: resource_bank.Claim,
    dynamic: resource_bank.Claim,
) Error!resource_bank.Claim {
    var joined: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        @field(joined, field.name) = try checkedAdd(
            @field(parent, field.name),
            @field(dynamic, field.name),
        );
    return joined;
}

fn outputTimelineBaseV1(
    plan: transform.TransformPlanV1,
) media.TimeBaseV1 {
    return switch (plan.kind) {
        .image => .{ .numerator = 1, .denominator = 1 },
        .audio, .video => plan.target_time_base,
    };
}

fn scrubBuffers(
    source: []u8,
    output: []u8,
    mappings: []transform.TransformMappingV1,
    scratch: []u8,
) void {
    @memset(source, 0);
    @memset(output, 0);
    @memset(std.mem.sliceAsBytes(mappings), 0);
    @memset(scratch, 0);
}

const TestContext = struct {
    encoded_fixture: []const u8,
    fixture: fixture_api.ParsedFixtureV1,
    encoded_decode_plan: []const u8,
    transform_plan: transform.TransformPlanV1,
    encoded_transform_plan: []const u8,
    timeline_base: media.TimeBaseV1,
};

fn prepareTestContext(
    case_index: usize,
    fixture_storage: *[fixture_api.maximum_fixture_bytes]u8,
    decode_plan_storage: *[decode_plan.plan_bytes]u8,
    transform_plan_storage: *[transform.transform_plan_bytes]u8,
    decoded_for_plan: *[fixture_api.maximum_payload_bytes]u8,
) !TestContext {
    const spec = switch (case_index) {
        0 => fixture_api.imageSpecV1(),
        1 => fixture_api.audioSpecV1(),
        2 => fixture_api.videoSpecV1(),
        else => unreachable,
    };
    const encoded_fixture = try fixture_api.encodeFixtureV1(
        spec,
        fixture_storage,
    );
    const fixture = try fixture_api.parseFixtureV1(
        encoded_fixture,
    );
    const fixture_plan = try fixture_api.makeDecodePlanV1(
        fixture,
        [_]u8{0xd1} ** 32,
        [_]u8{0xe1} ** 32,
    );
    const encoded_decode_plan = try decode_plan.encodePlanV1(
        fixture_plan,
        decode_plan_storage,
    );
    const decode_receipt = try fixture_api.decodeFixtureV1(
        encoded_fixture,
        encoded_decode_plan,
        decoded_for_plan,
    );
    const transform_plan = switch (case_index) {
        0 => try transform.makeImagePlanV1(
            fixture,
            decode_receipt,
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
        ),
        1 => try transform.makeAudioPlanV1(
            fixture,
            decode_receipt,
            0,
            6,
            16_000,
            1,
            0,
            1,
            [_]u8{0xf1} ** 32,
            [_]u8{0xf2} ** 32,
        ),
        2 => blk: {
            const selected = [_]u64{1};
            break :blk try transform.makeVideoPlanV1(
                fixture,
                decode_receipt,
                &selected,
                [_]u8{0xf1} ** 32,
                [_]u8{0xf2} ** 32,
            );
        },
        else => unreachable,
    };
    const encoded_transform_plan =
        try transform.encodeTransformPlanV1(
            transform_plan,
            transform_plan_storage,
        );
    return .{
        .encoded_fixture = encoded_fixture,
        .fixture = fixture,
        .encoded_decode_plan = encoded_decode_plan,
        .transform_plan = transform_plan,
        .encoded_transform_plan = encoded_transform_plan,
        .timeline_base = outputTimelineBaseV1(transform_plan),
    };
}

test "lease runtime owns commits retires and releases all media buffers" {
    const expected_roots = [_]Digest{
        [_]u8{
            0xcc, 0xa8, 0x3c, 0xa5, 0x03, 0x54, 0x49, 0xec,
            0x2b, 0x29, 0xe6, 0x48, 0xb8, 0x7e, 0xda, 0x12,
            0xc8, 0x9a, 0xea, 0x4c, 0xdd, 0x5a, 0xb4, 0xb8,
            0x3c, 0xc0, 0xf9, 0x3b, 0xfb, 0xa2, 0xf5, 0xb7,
        },
        [_]u8{
            0x9c, 0x91, 0xbe, 0x07, 0x53, 0x37, 0xda, 0x60,
            0x3b, 0x2a, 0x11, 0x09, 0x7b, 0x89, 0xe5, 0x4e,
            0x77, 0xe3, 0x9b, 0xa5, 0x96, 0x34, 0xd6, 0xae,
            0x53, 0xe8, 0x2f, 0x01, 0xa4, 0xae, 0x81, 0x90,
        },
        [_]u8{
            0x3b, 0x8f, 0xa4, 0x02, 0x56, 0xd5, 0x3f, 0x38,
            0xab, 0x1e, 0x75, 0xe7, 0x90, 0xa4, 0x4a, 0xf3,
            0xd3, 0x54, 0xac, 0x47, 0x8b, 0x87, 0x25, 0x90,
            0x5b, 0xbb, 0xab, 0x9d, 0x43, 0xd3, 0x8d, 0x2f,
        },
    };
    const expected_outputs = [_][]const u8{
        &[_]u8{
            0,   255, 0,   0,   255, 0,
            255, 255, 255, 255, 255, 255,
        },
        &[_]u8{ 0x00, 0xc0, 0x55, 0x15 },
        &[_]u8{ 255, 128, 64, 0 },
    };
    var roots_out: [3]Digest = undefined;
    for (0..3) |case_index| {
        var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
            undefined;
        var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
        var transform_plan_storage: [transform.transform_plan_bytes]u8 = undefined;
        var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
        const context = try prepareTestContext(
            case_index,
            &fixture_storage,
            &decode_plan_storage,
            &transform_plan_storage,
            &decoded_for_plan,
        );
        const total_claim = try flat.claimForExecutionV1(
            context.encoded_fixture.len,
            context.transform_plan,
        );
        const parent_claim = try parentClaimForExecutionV1(
            context.encoded_fixture.len,
        );
        var slots = [_]resource_bank.Slot{.{}};
        var tree_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
        var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
        var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
            &slots,
            &tree_roots,
            &nodes,
            try flat.limitsForClaimV1(total_claim),
            2100 + case_index,
        );
        const request_epoch: u64 = 2200 + case_index;
        const owner_key: u64 = 2300 + case_index;
        const tree_key: u64 = 2400 + case_index;
        const authority_key: u64 = 2500 + case_index;
        const tenant_key: u64 = 2600 + case_index;
        var publication_state =
            try media.initializePublicationStateV1(
                request_epoch,
                1,
                context.timeline_base,
                context.fixture.media_object_sha256,
                [_]u8{@intCast(0xa0 + case_index)} ** 32,
            );
        const state_before = publication_state;
        var session: Session = .{};
        try session.init(
            &bank,
            owner_key,
            tree_key,
            authority_key,
            tenant_key,
            request_epoch,
            &publication_state,
            context.encoded_fixture,
            context.encoded_transform_plan,
        );
        try std.testing.expect(std.meta.eql(
            (try bank.snapshot()).used,
            parent_claim,
        ));
        var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
        var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
        var mappings: [4]transform.TransformMappingV1 = undefined;
        var scratch: [1]u8 = undefined;
        var transaction = try session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            context.encoded_transform_plan,
            &decoded,
            &output,
            &mappings,
            scratch[0..0],
        );
        const transform_receipt =
            session.active_transform_receipt.?;
        var snapshot = try bank.snapshotV3();
        try std.testing.expect(std.meta.eql(
            snapshot.used,
            total_claim,
        ));
        try std.testing.expectEqual(
            @as(usize, 3),
            snapshot.live_allocations,
        );
        const receipt = try transaction.commit();
        const output_bytes: usize = @intCast(receipt.output_bytes);
        const mapping_count: usize = @intCast(receipt.mapping_count);
        try std.testing.expectEqualSlices(
            u8,
            expected_outputs[case_index],
            output[0..output_bytes],
        );
        try verifyLeaseExecutionReceiptV1(
            state_before,
            context.encoded_fixture,
            context.encoded_transform_plan,
            transform_receipt,
            output[0..output_bytes],
            mappings[0..mapping_count],
            owner_key,
            tree_key,
            authority_key,
            tenant_key,
            receipt,
        );
        var encoded_storage: [receipt_bytes]u8 = undefined;
        const encoded = try encodeLeaseExecutionReceiptV1(
            receipt,
            &encoded_storage,
        );
        const decoded_receipt =
            try decodeLeaseExecutionReceiptV1(encoded);
        try std.testing.expect(std.meta.eql(
            receipt,
            decoded_receipt,
        ));
        roots_out[case_index] = receipt.receipt_sha256;

        try session.retireProvisional();
        snapshot = try bank.snapshotV3();
        const retained_claim = try joinedClaimV1(
            parent_claim,
            try claimForRoleV1(
                context.transform_plan,
                .output,
            ),
        );
        try std.testing.expect(std.meta.eql(
            snapshot.used,
            retained_claim,
        ));
        try std.testing.expectEqual(
            @as(usize, 1),
            snapshot.live_allocations,
        );
        try std.testing.expectEqualSlices(
            u8,
            expected_outputs[case_index],
            output[0..output_bytes],
        );
        try session.closeAndRelease();
        snapshot = try bank.snapshotV3();
        try std.testing.expect(snapshot.used.isZero());
        try std.testing.expectEqual(
            @as(u64, 3),
            snapshot.lease_reclaim_commits,
        );
        try std.testing.expectEqual(
            @as(u64, 1),
            snapshot.lease_tree_closes,
        );
    }
    for (roots_out, expected_roots) |root, expected_root|
        try std.testing.expectEqualSlices(u8, &expected_root, &root);
}

test "lease runtime abort and candidate drift free every dynamic lease" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var transform_plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        1,
        &fixture_storage,
        &decode_plan_storage,
        &transform_plan_storage,
        &decoded_for_plan,
    );
    const total_claim = try flat.claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    const parent_claim = try parentClaimForExecutionV1(
        context.encoded_fixture.len,
    );
    var slots = [_]resource_bank.Slot{.{}};
    var tree_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &tree_roots,
        &nodes,
        try flat.limitsForClaimV1(total_claim),
        2701,
    );
    var publication_state = try media.initializePublicationStateV1(
        2702,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xb1} ** 32,
    );
    const state_before = publication_state;
    var session: Session = .{};
    try session.init(
        &bank,
        2703,
        2704,
        2705,
        2706,
        2702,
        &publication_state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    var decoded = [_]u8{0x5a} **
        fixture_api.maximum_payload_bytes;
    var output = [_]u8{0x5a} **
        fixture_api.maximum_payload_bytes;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    var aborted = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
        scratch[0..0],
    );
    const stale_leaf = session.live_bindings[0].allocation;
    try aborted.abort();
    try std.testing.expect(std.meta.eql(
        (try bank.snapshot()).used,
        parent_claim,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        decoded[0..context.transform_plan.source_bytes],
        0,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        output[0..context.transform_plan.output_bytes],
        0,
    ));
    try std.testing.expect(std.meta.eql(
        state_before,
        publication_state,
    ));
    try std.testing.expectError(
        resource_bank.Error.StaleReservation,
        bank.validateLeaseNode(session.tree, stale_leaf),
    );

    var drifted = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
        scratch[0..0],
    );
    output[0] ^= 1;
    try std.testing.expectError(
        Error.TransformFailed,
        drifted.commit(),
    );
    try std.testing.expect(std.meta.eql(
        (try bank.snapshot()).used,
        parent_claim,
    ));
    try std.testing.expect(std.meta.eql(
        state_before,
        publication_state,
    ));

    var committed = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
        scratch[0..0],
    );
    _ = try committed.commit();
    try session.retireProvisional();
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "lease runtime capacity nodes and buffers reject without dynamic leaks" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var transform_plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        0,
        &fixture_storage,
        &decode_plan_storage,
        &transform_plan_storage,
        &decoded_for_plan,
    );
    const total_claim = try flat.claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    const parent_claim = try parentClaimForExecutionV1(
        context.encoded_fixture.len,
    );
    var limited = try flat.limitsForClaimV1(total_claim);
    limited.host_bytes -= 1;
    var slots = [_]resource_bank.Slot{.{}};
    var tree_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &tree_roots,
        &nodes,
        limited,
        2801,
    );
    var state = try media.initializePublicationStateV1(
        2802,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xc1} ** 32,
    );
    var session: Session = .{};
    try session.init(
        &bank,
        2803,
        2804,
        2805,
        2806,
        2802,
        &state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    try std.testing.expectError(
        Error.ResourceAdmissionFailed,
        session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            context.encoded_transform_plan,
            &decoded,
            &output,
            &mappings,
            scratch[0..0],
        ),
    );
    try std.testing.expect(std.meta.eql(
        (try bank.snapshot()).used,
        parent_claim,
    ));
    try session.closeAndRelease();
    try std.testing.expect((try bank.snapshot()).used.isZero());

    var node_slots = [_]resource_bank.Slot{.{}};
    var node_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var short_nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 5;
    var node_bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &node_slots,
        &node_roots,
        &short_nodes,
        try flat.limitsForClaimV1(total_claim),
        2811,
    );
    var node_state = try media.initializePublicationStateV1(
        2812,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xc2} ** 32,
    );
    var node_session: Session = .{};
    try node_session.init(
        &node_bank,
        2813,
        2814,
        2815,
        2816,
        2812,
        &node_state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    try std.testing.expectError(
        Error.ResourceAdmissionFailed,
        node_session.prepare(
            context.encoded_fixture,
            context.encoded_decode_plan,
            context.encoded_transform_plan,
            &decoded,
            &output,
            &mappings,
            scratch[0..0],
        ),
    );
    try std.testing.expect(std.meta.eql(
        (try node_bank.snapshot()).used,
        parent_claim,
    ));
    try node_session.closeAndRelease();
    try std.testing.expect((try node_bank.snapshot()).used.isZero());

    var init_slots = [_]resource_bank.Slot{.{}};
    var init_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var init_nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 2;
    var init_bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &init_slots,
        &init_roots,
        &init_nodes,
        try flat.limitsForClaimV1(total_claim),
        2821,
    );
    var init_state = try media.initializePublicationStateV1(
        2822,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xc3} ** 32,
    );
    var init_session: Session = .{};
    try std.testing.expectError(
        Error.ResourceAdmissionFailed,
        init_session.init(
            &init_bank,
            2823,
            2824,
            2825,
            2826,
            2822,
            &init_state,
            context.encoded_fixture,
            context.encoded_transform_plan,
        ),
    );
    const init_snapshot = try init_bank.snapshotV3();
    try std.testing.expect(init_snapshot.used.isZero());
    try std.testing.expectEqual(
        @as(usize, 0),
        init_snapshot.active_lease_trees,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        init_snapshot.active_lease_nodes,
    );
}

test "lease runtime receipt rejects every byte and rehashed semantics" {
    var fixture_storage: [fixture_api.maximum_fixture_bytes]u8 =
        undefined;
    var decode_plan_storage: [decode_plan.plan_bytes]u8 = undefined;
    var transform_plan_storage: [transform.transform_plan_bytes]u8 = undefined;
    var decoded_for_plan: [fixture_api.maximum_payload_bytes]u8 = undefined;
    const context = try prepareTestContext(
        2,
        &fixture_storage,
        &decode_plan_storage,
        &transform_plan_storage,
        &decoded_for_plan,
    );
    const total_claim = try flat.claimForExecutionV1(
        context.encoded_fixture.len,
        context.transform_plan,
    );
    var slots = [_]resource_bank.Slot{.{}};
    var tree_roots = [_]resource_bank.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
    var bank = try resource_bank.Bank.initWithLeaseTreeStorage(
        &slots,
        &tree_roots,
        &nodes,
        try flat.limitsForClaimV1(total_claim),
        2901,
    );
    var state = try media.initializePublicationStateV1(
        2902,
        1,
        context.timeline_base,
        context.fixture.media_object_sha256,
        [_]u8{0xd1} ** 32,
    );
    const state_before = state;
    var session: Session = .{};
    try session.init(
        &bank,
        2903,
        2904,
        2905,
        2906,
        2902,
        &state,
        context.encoded_fixture,
        context.encoded_transform_plan,
    );
    var decoded: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var output: [fixture_api.maximum_payload_bytes]u8 = undefined;
    var mappings: [4]transform.TransformMappingV1 = undefined;
    var scratch: [1]u8 = undefined;
    var transaction = try session.prepare(
        context.encoded_fixture,
        context.encoded_decode_plan,
        context.encoded_transform_plan,
        &decoded,
        &output,
        &mappings,
        scratch[0..0],
    );
    const transform_receipt = session.active_transform_receipt.?;
    const receipt = try transaction.commit();
    var encoded: [receipt_bytes]u8 = undefined;
    _ = try encodeLeaseExecutionReceiptV1(receipt, &encoded);
    var corrupted: [receipt_bytes]u8 = undefined;
    for (0..receipt_bytes) |index| {
        @memcpy(&corrupted, &encoded);
        corrupted[index] ^= 1;
        const accepted = if (decodeLeaseExecutionReceiptV1(
            &corrupted,
        )) |_| true else |_| false;
        try std.testing.expect(!accepted);
    }

    @memcpy(&corrupted, &encoded);
    writeU64(
        &corrupted,
        112 + 5 * 8,
        receipt.total_claim.output_journal_bytes + 1,
    );
    var rerooted = receipt;
    rerooted.total_claim.output_journal_bytes += 1;
    const forged_root = leaseExecutionReceiptRootV1(rerooted);
    @memcpy(corrupted[receipt_body_bytes..], &forged_root);
    const decoded_forgery =
        try decodeLeaseExecutionReceiptV1(&corrupted);
    try std.testing.expectError(
        Error.InvalidReceipt,
        verifyLeaseExecutionReceiptV1(
            state_before,
            context.encoded_fixture,
            context.encoded_transform_plan,
            transform_receipt,
            output[0..receipt.output_bytes],
            mappings[0..receipt.mapping_count],
            2903,
            2904,
            2905,
            2906,
            decoded_forgery,
        ),
    );
    try session.retireProvisional();
    try session.closeAndRelease();
}
