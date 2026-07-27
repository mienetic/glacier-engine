//! Portable binding for retiring logical ownership after exact device loss.
//!
//! These pointer-free values compose existing lifecycle, selection, allocation,
//! and LeaseTree evidence. They do not free native references, consume a Bank
//! permit, clear dispatch quarantine, publish output, reset a device, select a
//! replacement, migrate work, or prove physical reclamation. Structural plans
//! may retain explicitly synthetic loss evidence for deterministic tests.
//! Production eligibility is a separate, narrower validation step.

const std = @import("std");
const device = @import("device_capability_contract.zig");
const lifecycle = @import("device_lifecycle_contract.zig");
const allocation = @import("device_allocation_lease.zig");
const allocation_tree = @import("device_allocation_lease_tree.zig");
const resource = @import("resource_bank.zig");

pub const Digest = device.Digest;
pub const zero_digest = device.zero_digest;

pub const plan_abi: u64 = 0x4744_4c50_0000_0001;
pub const receipt_abi: u64 = 0x4744_4c52_0000_0001;

const plan_domain = "glacier-device-loss-retirement-plan-v1\x00";
const receipt_domain =
    "glacier-device-loss-retirement-receipt-v1\x00";

pub const Error =
    device.Error ||
    lifecycle.Error ||
    allocation.Error ||
    allocation_tree.Error ||
    error{
        InvalidLossRetirementPlan,
        ProductionEvidenceRequired,
        InvalidLossRetirementReceipt,
    };

/// Immutable proposal to retire one exact LeaseTree allocation after an exact
/// lifecycle transition to `lost`. This is composition evidence only. The
/// adapter challenge names a private settlement attempt but grants no callback
/// or resource authority.
pub const LossRetirementPlanV1 = struct {
    abi_version: u64 = plan_abi,
    source: lifecycle.ObservationSourceV1 =
        .removed_notification,
    evidence_class: lifecycle.EvidenceClassV1 = .native,
    successor_state: device.InventoryStateV1 = .lost,
    source_sequence: u64 = 0,
    recovery_generation: u64 = 0,
    allocation_count: u64 = 0,
    materialized_bytes: u64 = 0,
    source_instance_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
    transition_receipt_sha256: Digest = zero_digest,
    requirement_sha256: Digest = zero_digest,
    prior_inventory_sha256: Digest = zero_digest,
    selected_entry_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    selection_receipt_sha256: Digest = zero_digest,
    allocation_authority_sha256: Digest = zero_digest,
    allocation_request_sha256: Digest = zero_digest,
    allocation_lease_sha256: Digest = zero_digest,
    allocation_leaf_set_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    adapter_challenge_sha256: Digest = zero_digest,
    plan_sha256: Digest = zero_digest,
};

/// Immutable composition receipt for the ordinary LeaseTree
/// `released`/`normal_release` terminal of the exact loss-bound lease.
///
/// Within the trusted same-process Coordinator flow, returning logical bytes
/// closes that allocation's accounting lifecycle. Structural validation is
/// composition evidence, not independent Bank attestation. It does not assert
/// that physical pages were reclaimed or that the old device has reusable
/// capacity. The four authority roots are fixed to zero so this receipt cannot
/// be confused with output, migration, reset, or physical-reclamation
/// authority.
pub const LossRetirementReceiptV1 = struct {
    abi_version: u64 = receipt_abi,
    source: lifecycle.ObservationSourceV1 =
        .removed_notification,
    evidence_class: lifecycle.EvidenceClassV1 = .native,
    recovery_generation: u64 = 0,
    reference_release_count: u64 = 0,
    returned_logical_device_bytes: u64 = 0,
    physical_reclaim_observed: u64 = 0,
    plan_sha256: Digest = zero_digest,
    transition_receipt_sha256: Digest = zero_digest,
    allocation_lease_sha256: Digest = zero_digest,
    allocation_leaf_set_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    allocation_terminal_sha256: Digest = zero_digest,
    adapter_settlement_sha256: Digest = zero_digest,
    output_authority_sha256: Digest = zero_digest,
    migration_authority_sha256: Digest = zero_digest,
    reset_authority_sha256: Digest = zero_digest,
    physical_reclaim_authority_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

comptime {
    if (@sizeOf(LossRetirementPlanV1) != 544)
        @compileError("LossRetirementPlanV1 layout changed");
    if (@sizeOf(LossRetirementReceiptV1) != 440)
        @compileError("LossRetirementReceiptV1 layout changed");
}

pub fn makeLossRetirementPlanV1(
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    authority: allocation.AllocationAuthorityV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    recovery_generation: u64,
    adapter_challenge_sha256: Digest,
) Error!LossRetirementPlanV1 {
    var result: LossRetirementPlanV1 = .{
        .source = observation.source,
        .evidence_class = observation.evidence_class,
        .successor_state = transition.successor_state,
        .source_sequence = observation.source_sequence,
        .recovery_generation = recovery_generation,
        .allocation_count = lease.allocation_count,
        .materialized_bytes = lease.materialized_bytes,
        .source_instance_sha256 = observation.source_instance_sha256,
        .observation_sha256 = observation.observation_sha256,
        .transition_receipt_sha256 = transition.receipt_sha256,
        .requirement_sha256 = requirement.requirement_sha256,
        .prior_inventory_sha256 = transition.prior_inventory_sha256,
        .selected_entry_sha256 = selected_entry.entry_sha256,
        .selected_capability_sha256 = selected_entry.capability.capability_sha256,
        .selection_receipt_sha256 = selection.receipt_sha256,
        .allocation_authority_sha256 = authority.authority_sha256,
        .allocation_request_sha256 = lease.request_sha256,
        .allocation_lease_sha256 = lease.lease_sha256,
        .allocation_leaf_set_sha256 = lease.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = lease.backend_object_set_sha256,
        .adapter_challenge_sha256 = adapter_challenge_sha256,
    };
    result.plan_sha256 = lossRetirementPlanRootV1(result);
    try validateLossRetirementPlanV1(
        result,
        observation,
        transition,
        source_cursor,
        requirement,
        selection,
        prior_inventory,
        selected_entry,
        successor_entry,
        authority,
        lease,
    );
    return result;
}

/// Replay all nested, externally authoritative bindings. `source_cursor` is
/// the cursor immediately before this loss observation; callers should compose
/// the plan while atomically accepting the transition rather than replaying it
/// after the durable cursor has advanced.
pub fn validateLossRetirementPlanV1(
    value: LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    authority: allocation.AllocationAuthorityV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
) Error!void {
    lifecycle.validateTransitionReceiptV1(
        transition,
        observation,
        selected_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    ) catch return Error.InvalidLossRetirementPlan;
    device.validateRequirementV1(requirement) catch
        return Error.InvalidLossRetirementPlan;
    device.validateSelectionReceiptV1(
        selection,
        requirement,
        prior_inventory,
    ) catch return Error.InvalidLossRetirementPlan;
    device.validateInventoryEntryV1(selected_entry) catch
        return Error.InvalidLossRetirementPlan;
    device.validateInventoryEntryV1(successor_entry) catch
        return Error.InvalidLossRetirementPlan;
    allocation.validateAuthorityV1(authority) catch
        return Error.InvalidLossRetirementPlan;
    allocation_tree.validateLeaseV1(lease) catch
        return Error.InvalidLossRetirementPlan;

    if (observation.observed_state != .lost or
        transition.prior_state != .present or
        transition.successor_state != .lost or
        successor_entry.state != .lost or
        selected_entry.state != .present or
        !digestEqual(
            selection.selected_entry_sha256,
            selected_entry.entry_sha256,
        ) or
        !digestEqual(
            selection.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
        ) or
        !digestEqual(
            transition.prior_entry_sha256,
            selected_entry.entry_sha256,
        ) or
        !digestEqual(
            transition.capability_sha256,
            selected_entry.capability.capability_sha256,
        ) or
        authority.selected_discovery_epoch !=
            selected_entry.discovery_epoch or
        !digestEqual(
            authority.selected_entry_sha256,
            selected_entry.entry_sha256,
        ) or
        !digestEqual(
            authority.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
        ) or
        !digestEqual(
            lease.authority_sha256,
            authority.authority_sha256,
        ) or
        !digestEqual(
            lease.selection_receipt_sha256,
            selection.receipt_sha256,
        ) or
        !digestEqual(
            lease.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
        ))
        return Error.InvalidLossRetirementPlan;

    try validateLossRetirementPlanShapeV1(
        value,
        observation,
        transition,
        requirement,
        selection,
        selected_entry,
        authority,
        lease,
    );
}

fn validateLossRetirementPlanShapeV1(
    value: LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    selected_entry: device.DeviceInventoryEntryV1,
    authority: allocation.AllocationAuthorityV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
) Error!void {
    if (value.abi_version != plan_abi or
        value.source != observation.source or
        value.evidence_class != observation.evidence_class or
        value.successor_state != .lost or
        value.successor_state != transition.successor_state or
        value.source_sequence != observation.source_sequence or
        value.source_sequence != transition.source_sequence or
        value.recovery_generation == 0 or
        value.allocation_count == 0 or
        value.allocation_count != lease.allocation_count or
        value.materialized_bytes == 0 or
        value.materialized_bytes != lease.materialized_bytes or
        !digestEqual(
            value.source_instance_sha256,
            observation.source_instance_sha256,
        ) or
        !digestEqual(
            value.observation_sha256,
            observation.observation_sha256,
        ) or
        !digestEqual(
            value.transition_receipt_sha256,
            transition.receipt_sha256,
        ) or
        !digestEqual(
            value.requirement_sha256,
            requirement.requirement_sha256,
        ) or
        !digestEqual(
            value.prior_inventory_sha256,
            transition.prior_inventory_sha256,
        ) or
        !digestEqual(
            value.selected_entry_sha256,
            selected_entry.entry_sha256,
        ) or
        !digestEqual(
            value.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
        ) or
        !digestEqual(
            value.selection_receipt_sha256,
            selection.receipt_sha256,
        ) or
        !digestEqual(
            value.allocation_authority_sha256,
            authority.authority_sha256,
        ) or
        !digestEqual(
            value.allocation_request_sha256,
            lease.request_sha256,
        ) or
        !digestEqual(
            value.allocation_lease_sha256,
            lease.lease_sha256,
        ) or
        !digestEqual(
            value.allocation_leaf_set_sha256,
            lease.allocation_leaf_set_sha256,
        ) or
        !digestEqual(
            value.backend_object_set_sha256,
            lease.backend_object_set_sha256,
        ) or
        digestIsZero(value.adapter_challenge_sha256) or
        digestIsZero(value.plan_sha256) or
        !digestEqual(
            value.plan_sha256,
            lossRetirementPlanRootV1(value),
        ))
        return Error.InvalidLossRetirementPlan;
}

/// Return whether an already structurally validated plan carries one of the
/// two native loss sources eligible for a production retirement attempt.
/// `test_injected` remains useful as structural evidence but always returns
/// false here.
pub fn lossRetirementPlanProductionEligibleV1(
    plan: LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) bool {
    if (plan.abi_version != plan_abi or
        plan.successor_state != .lost or
        plan.evidence_class != .native or
        observation.evidence_class != .native or
        transition.evidence_class != .native or
        observation.observed_state != .lost or
        transition.successor_state != .lost or
        plan.source != observation.source or
        plan.source != transition.source or
        !digestEqual(
            plan.observation_sha256,
            observation.observation_sha256,
        ) or
        digestIsZero(observation.observation_sha256) or
        !digestEqual(
            observation.observation_sha256,
            lifecycle.observationRootV1(observation),
        ) or
        !digestEqual(
            plan.transition_receipt_sha256,
            transition.receipt_sha256,
        ) or
        digestIsZero(transition.receipt_sha256) or
        !digestEqual(
            transition.receipt_sha256,
            lifecycle.transitionReceiptRootV1(transition),
        ) or
        !digestEqual(
            plan.plan_sha256,
            lossRetirementPlanRootV1(plan),
        ))
        return false;

    return switch (plan.source) {
        .removed_notification => observation.native_command_status == 0 and
            observation.native_error_domain_kind == 0 and
            observation.native_error_code_bits == 0,
        .command_buffer_device_removed => observation.native_command_status ==
            lifecycle.command_buffer_status_error and
            observation.native_error_domain_kind ==
                lifecycle.command_buffer_error_domain and
            observation.native_error_code_bits ==
                lifecycle.command_buffer_device_removed_error,
        else => false,
    };
}

pub fn requireProductionEligibleLossRetirementPlanV1(
    plan: LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) Error!void {
    if (!lossRetirementPlanProductionEligibleV1(
        plan,
        observation,
        transition,
    ))
        return Error.ProductionEvidenceRequired;
}

pub fn lossRetirementPlanRootV1(
    value: LossRetirementPlanV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, @intFromEnum(value.successor_state));
    hashU64(&hash, value.source_sequence);
    hashU64(&hash, value.recovery_generation);
    hashU64(&hash, value.allocation_count);
    hashU64(&hash, value.materialized_bytes);
    hash.update(&value.source_instance_sha256);
    hash.update(&value.observation_sha256);
    hash.update(&value.transition_receipt_sha256);
    hash.update(&value.requirement_sha256);
    hash.update(&value.prior_inventory_sha256);
    hash.update(&value.selected_entry_sha256);
    hash.update(&value.selected_capability_sha256);
    hash.update(&value.selection_receipt_sha256);
    hash.update(&value.allocation_authority_sha256);
    hash.update(&value.allocation_request_sha256);
    hash.update(&value.allocation_lease_sha256);
    hash.update(&value.allocation_leaf_set_sha256);
    hash.update(&value.backend_object_set_sha256);
    hash.update(&value.adapter_challenge_sha256);
    return finish(&hash);
}

pub fn validateLossRetirementPlanReplayV1(
    candidate: LossRetirementPlanV1,
    retained: LossRetirementPlanV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossRetirementPlan;
}

pub fn makeLossRetirementReceiptV1(
    plan: LossRetirementPlanV1,
    terminal: allocation_tree.LeaseTreeAllocationTerminalReceiptV1,
    adapter_settlement_sha256: Digest,
    reference_release_count: u64,
) Error!LossRetirementReceiptV1 {
    var result: LossRetirementReceiptV1 = .{
        .source = plan.source,
        .evidence_class = plan.evidence_class,
        .recovery_generation = plan.recovery_generation,
        .reference_release_count = reference_release_count,
        .returned_logical_device_bytes = terminal.returned_device_bytes,
        .physical_reclaim_observed = 0,
        .plan_sha256 = plan.plan_sha256,
        .transition_receipt_sha256 = plan.transition_receipt_sha256,
        .allocation_lease_sha256 = plan.allocation_lease_sha256,
        .allocation_leaf_set_sha256 = plan.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = plan.backend_object_set_sha256,
        .allocation_terminal_sha256 = terminal.terminal_sha256,
        .adapter_settlement_sha256 = adapter_settlement_sha256,
    };
    result.receipt_sha256 = lossRetirementReceiptRootV1(result);
    try validateLossRetirementReceiptV1(result, plan, terminal);
    return result;
}

pub fn validateLossRetirementReceiptV1(
    value: LossRetirementReceiptV1,
    plan: LossRetirementPlanV1,
    terminal: allocation_tree.LeaseTreeAllocationTerminalReceiptV1,
) Error!void {
    if (plan.abi_version != plan_abi or
        digestIsZero(plan.plan_sha256) or
        !digestEqual(
            plan.plan_sha256,
            lossRetirementPlanRootV1(plan),
        ))
        return Error.InvalidLossRetirementReceipt;
    allocation_tree.validateTerminalReceiptV1(terminal) catch
        return Error.InvalidLossRetirementReceipt;

    if (terminal.outcome != .released or
        terminal.reason != .normal_release or
        !digestEqual(
            terminal.authority_sha256,
            plan.allocation_authority_sha256,
        ) or
        !digestEqual(
            terminal.request_sha256,
            plan.allocation_request_sha256,
        ) or
        !digestEqual(
            terminal.lease_sha256,
            plan.allocation_lease_sha256,
        ) or
        !digestEqual(
            terminal.backend_object_set_sha256,
            plan.backend_object_set_sha256,
        ) or
        terminal.returned_device_bytes != plan.materialized_bytes or
        value.abi_version != receipt_abi or
        value.source != plan.source or
        value.evidence_class != plan.evidence_class or
        value.recovery_generation != plan.recovery_generation or
        value.reference_release_count != plan.allocation_count or
        value.returned_logical_device_bytes !=
            plan.materialized_bytes or
        value.physical_reclaim_observed != 0 or
        !digestEqual(value.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            value.transition_receipt_sha256,
            plan.transition_receipt_sha256,
        ) or
        !digestEqual(
            value.allocation_lease_sha256,
            plan.allocation_lease_sha256,
        ) or
        !digestEqual(
            value.allocation_leaf_set_sha256,
            plan.allocation_leaf_set_sha256,
        ) or
        !digestEqual(
            value.backend_object_set_sha256,
            plan.backend_object_set_sha256,
        ) or
        !digestEqual(
            value.allocation_terminal_sha256,
            terminal.terminal_sha256,
        ) or
        digestIsZero(value.adapter_settlement_sha256) or
        !digestEqual(value.output_authority_sha256, zero_digest) or
        !digestEqual(
            value.migration_authority_sha256,
            zero_digest,
        ) or
        !digestEqual(value.reset_authority_sha256, zero_digest) or
        !digestEqual(
            value.physical_reclaim_authority_sha256,
            zero_digest,
        ) or
        digestIsZero(value.receipt_sha256) or
        !digestEqual(
            value.receipt_sha256,
            lossRetirementReceiptRootV1(value),
        ))
        return Error.InvalidLossRetirementReceipt;
}

pub fn lossRetirementReceiptRootV1(
    value: LossRetirementReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, value.recovery_generation);
    hashU64(&hash, value.reference_release_count);
    hashU64(&hash, value.returned_logical_device_bytes);
    hashU64(&hash, value.physical_reclaim_observed);
    hash.update(&value.plan_sha256);
    hash.update(&value.transition_receipt_sha256);
    hash.update(&value.allocation_lease_sha256);
    hash.update(&value.allocation_leaf_set_sha256);
    hash.update(&value.backend_object_set_sha256);
    hash.update(&value.allocation_terminal_sha256);
    hash.update(&value.adapter_settlement_sha256);
    hash.update(&value.output_authority_sha256);
    hash.update(&value.migration_authority_sha256);
    hash.update(&value.reset_authority_sha256);
    hash.update(&value.physical_reclaim_authority_sha256);
    return finish(&hash);
}

pub fn validateLossRetirementReceiptReplayV1(
    candidate: LossRetirementReceiptV1,
    retained: LossRetirementReceiptV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossRetirementReceipt;
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn portableTypeHasPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| portableTypeHasPointer(info.child),
        .optional => |info| portableTypeHasPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (portableTypeHasPointer(field.type))
                    break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

const TestFixture = struct {
    inventory: [1]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    authority: allocation.AllocationAuthorityV1,
    entries: [1]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
};

const test_request_epoch: u64 = 0x4c4f_5353;
const test_session_id: usize = 0x5254_4952;

const TestHarness = struct {
    slots: [1]resource.Slot = [_]resource.Slot{.{}},
    roots: [1]resource.LeaseTreeRootSlot =
        [_]resource.LeaseTreeRootSlot{.{}},
    nodes: [2]resource.LeaseNodeSlot =
        [_]resource.LeaseNodeSlot{.{}} ** 2,
    bank: resource.Bank = undefined,
    parent: resource.Receipt = undefined,
    tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    publication_sequence: u64 = 0,
    fake_objects: [1]allocation.FakeObjectSlotV1 =
        [_]allocation.FakeObjectSlotV1{.{}},
    backend: allocation.FakeBackendV1 = undefined,
    coordinator_objects: [1]allocation_tree.CoordinatorObjectSlotV1 =
        [_]allocation_tree.CoordinatorObjectSlotV1{.{}},
    coordinator: allocation_tree.CoordinatorV1 = .{},
    fixture: TestFixture = undefined,

    fn init(self: *@This(), label: []const u8) !void {
        self.fixture = try makeTestFixture(label);
        self.bank = try resource.Bank.initWithLeaseTreeStorage(
            &self.slots,
            &self.roots,
            &self.nodes,
            .{
                .host_bytes = 1_024,
                .capsule_bytes = 1_024,
                .device_bytes = self.fixture.manifest.total_charged_bytes,
                .queue_slots = 1,
            },
            41,
        );
        self.parent = try self.bank.commit(
            try self.bank.reserve(
                9_001,
                .{
                    .capsule_bytes = 64,
                    .queue_slots = 1,
                },
            ),
        );
        const opened = try self.bank.openLeaseTree(
            self.parent,
            0x6c6f_7373_7472_6565,
            0x6c6f_7373_6175_7468,
            .{
                .device_bytes = self.fixture.manifest.total_charged_bytes,
            },
        );
        const scoped = try self.bank.openLeaseScope(
            opened,
            0x6c6f_7373_7363_6f70,
            0x6c6f_7373_7465_6e61,
            .{
                .device_bytes = self.fixture.manifest.total_charged_bytes,
            },
        );
        self.tree = scoped.tree;
        self.scope = scoped.scope;
        try self.bank.bindPublicationSessionWithLeaseTree(
            self.tree,
            test_request_epoch,
            test_session_id,
        );
        self.backend = try allocation.FakeBackendV1.init(
            self.fixture.authority,
            &self.fake_objects,
        );
        try self.coordinator.init(
            0x4c4f_5353_434f_4f52,
            &self.bank,
            &self.tree,
            self.scope,
            test_request_epoch,
            test_session_id,
            &self.publication_sequence,
            &self.coordinator_objects,
        );
    }

    fn request(self: *@This()) !allocation.AllocationRequestV1 {
        return allocation.makeRequestV1(
            test_request_epoch,
            testDigest("loss retirement request owner"),
            self.fixture.authority,
            self.fixture.selection,
            self.fixture.requirement,
            &self.fixture.inventory,
            self.parent,
            self.fixture.manifest,
            &self.fixture.entries,
        );
    }

    fn materialize(
        self: *@This(),
    ) !allocation_tree.LeaseTreeDeviceAllocationLeaseV1 {
        const admission = try self.coordinator.admit(
            self.backend.adapter(),
            try self.request(),
            self.fixture.selection,
            self.fixture.requirement,
            &self.fixture.inventory,
            self.parent,
            self.fixture.manifest,
            &self.fixture.entries,
        );
        const outcome = try self.coordinator.materialize(
            admission,
            self.backend.adapter(),
            .{},
        );
        return switch (outcome) {
            .active => |lease| lease,
            else => error.TestExpectedActiveLease,
        };
    }

    fn release(
        self: *@This(),
        lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    ) !allocation_tree.LeaseTreeAllocationTerminalReceiptV1 {
        const outcome = try self.coordinator.release(
            lease,
            self.backend.adapter(),
        );
        return switch (outcome) {
            .terminal => |terminal| terminal,
            else => error.TestExpectedTerminalReceipt,
        };
    }

    fn close(self: *@This()) !void {
        try self.bank.closePublicationSession(
            self.parent,
            test_request_epoch,
            test_session_id,
            self.publication_sequence,
        );
        try self.bank.closeLeaseTree(self.tree);
        try self.bank.release(self.parent);
        try std.testing.expect((try self.bank.snapshot()).used.isZero());
    }
};

const TestLoss = struct {
    cursor: lifecycle.SourceCursorV1,
    observation: lifecycle.ObservationV1,
    successor: device.DeviceInventoryEntryV1,
    transition: lifecycle.TransitionReceiptV1,
};

fn makeTestFixture(label: []const u8) !TestFixture {
    const profile =
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    const capability = try device.sealCapabilityV1(.{
        .backend_kind = .metal,
        .device_class = .accelerator,
        .operation_profile_bits = profile,
        .operator_bits = device.profileOperatorBitsV1(profile),
        .element_type_bits = device.profileElementTypeBitsV1(profile),
        .numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.dispatch |
            device.FeatureBitsV1.completion_fence |
            device.FeatureBitsV1.device_loss_signal,
        .max_single_allocation_bytes = 4_096,
        .max_total_device_bytes = 4_096,
        .max_queue_slots = 1,
        .backend_sha256 = testDigest("loss retirement test backend"),
        .device_sha256 = testDigest(label),
        .driver_sha256 = testDigest("loss retirement test driver"),
        .placement_sha256 = testDigest("loss retirement test placement"),
    });
    const inventory = [1]device.DeviceInventoryEntryV1{
        try device.sealInventoryEntryV1(.{
            .discovery_epoch = 19,
            .policy_rank = 3,
            .state = .present,
            .capability = capability,
        }),
    };
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = testDigest("loss retirement execution plan"),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profile,
        .required_operator_bits = device.profileOperatorBitsV1(profile),
        .required_element_type_bits = device.profileElementTypeBitsV1(profile),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .required_feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.device_loss_signal,
        .largest_single_allocation_bytes = 4_096,
        .total_device_bytes = 4_096,
        .queue_slots = 1,
        .fallback_policy = .forbidden,
    });
    const selection = try device.selectDeviceV1(
        requirement,
        &inventory,
    );
    const authority = try allocation.makeAuthorityV1(
        23,
        1,
        1,
        1_024,
        inventory[selection.selected_index],
        testDigest("loss retirement adapter authority"),
    );
    const quote = try allocation.makeFakeQuoteV1(
        authority,
        testDigest("loss retirement buffer binding"),
        4_000,
    );
    const entries = [1]allocation.AllocationEntryV1{.{
        .binding_sha256 = testDigest("loss retirement buffer binding"),
        .requested_bytes = 4_000,
        .charged_bytes = quote.charged_bytes,
        .quote_sha256 = quote.quote_sha256,
    }};
    return .{
        .inventory = inventory,
        .requirement = requirement,
        .selection = selection.receipt,
        .authority = authority,
        .entries = entries,
        .manifest = try allocation.sealManifestV1(&entries),
    };
}

fn makeTestLoss(
    fixture: TestFixture,
    source: lifecycle.ObservationSourceV1,
    source_sequence: u64,
) !TestLoss {
    const cursor: lifecycle.SourceCursorV1 = .{
        .source_instance_sha256 = testDigest("loss retirement source instance"),
        .last_sequence = source_sequence - 1,
    };
    const command_fields: [3]u64 =
        if (source == .command_buffer_device_removed)
            .{
                lifecycle.command_buffer_status_error,
                lifecycle.command_buffer_error_domain,
                lifecycle.command_buffer_device_removed_error,
            }
        else
            .{ 0, 0, 0 };
    const observation = try lifecycle.makeObservationV1(
        fixture.inventory[0],
        &fixture.inventory,
        cursor.source_instance_sha256,
        source_sequence,
        source,
        testDigest("loss retirement lifecycle evidence"),
        command_fields[0],
        command_fields[1],
        command_fields[2],
    );
    const successor = try lifecycle.makeSuccessorEntryV1(
        observation,
        fixture.inventory[0],
        &fixture.inventory,
        cursor,
        fixture.inventory[0].discovery_epoch + 1,
    );
    return .{
        .cursor = cursor,
        .observation = observation,
        .successor = successor,
        .transition = try lifecycle.makeTransitionReceiptV1(
            observation,
            fixture.inventory[0],
            &fixture.inventory,
            successor,
            cursor,
        ),
    };
}

fn makeTestPlan(
    harness: *TestHarness,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    loss: TestLoss,
) !LossRetirementPlanV1 {
    return makeLossRetirementPlanV1(
        loss.observation,
        loss.transition,
        loss.cursor,
        harness.fixture.requirement,
        harness.fixture.selection,
        &harness.fixture.inventory,
        harness.fixture.inventory[0],
        loss.successor,
        harness.fixture.authority,
        lease,
        7,
        testDigest("loss retirement adapter challenge"),
    );
}

fn validateTestPlan(
    harness: *TestHarness,
    plan: LossRetirementPlanV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    loss: TestLoss,
) !void {
    try validateLossRetirementPlanV1(
        plan,
        loss.observation,
        loss.transition,
        loss.cursor,
        harness.fixture.requirement,
        harness.fixture.selection,
        &harness.fixture.inventory,
        harness.fixture.inventory[0],
        loss.successor,
        harness.fixture.authority,
        lease,
    );
}

fn testDigest(bytes: []const u8) Digest {
    return device.digestV1(bytes);
}

fn expectDigestHex(expected: []const u8, actual: Digest) !void {
    const encoded = std.fmt.bytesToHex(actual, .lower);
    try std.testing.expectEqualStrings(expected, &encoded);
}

test "loss retirement values have literal ABIs layouts and no pointers" {
    try std.testing.expectEqual(
        @as(u64, 0x4744_4c50_0000_0001),
        plan_abi,
    );
    try std.testing.expectEqual(
        @as(u64, 0x4744_4c52_0000_0001),
        receipt_abi,
    );
    try std.testing.expectEqual(
        @as(usize, 544),
        @sizeOf(LossRetirementPlanV1),
    );
    try std.testing.expectEqual(
        @as(usize, 440),
        @sizeOf(LossRetirementReceiptV1),
    );
    try std.testing.expect(
        !portableTypeHasPointer(LossRetirementPlanV1),
    );
    try std.testing.expect(
        !portableTypeHasPointer(LossRetirementReceiptV1),
    );
}

test "loss retirement literal plan and receipt roots stay stable" {
    var harness: TestHarness = .{};
    try harness.init("loss retirement golden gpu");
    const lease = try harness.materialize();
    const loss = try makeTestLoss(
        harness.fixture,
        .command_buffer_device_removed,
        31,
    );
    const plan = try makeTestPlan(&harness, lease, loss);
    const terminal = try harness.release(lease);
    const receipt = try makeLossRetirementReceiptV1(
        plan,
        terminal,
        testDigest("loss retirement golden settlement"),
        plan.allocation_count,
    );

    try expectDigestHex(
        "b335fc92c606b155ffb000aa8a91d9a5999aa1d9b82bef69b9f97604a8f83417",
        plan.plan_sha256,
    );
    try expectDigestHex(
        "ac46b55947af12b55884920e6ab98102090c8b19ce2091277ad46e54c86d31d0",
        receipt.receipt_sha256,
    );
    try harness.close();
}

test "native plans are production eligible and synthetic plans are not" {
    var harness: TestHarness = .{};
    try harness.init("loss retirement eligibility gpu");
    const lease = try harness.materialize();
    const cases = [_]struct {
        source: lifecycle.ObservationSourceV1,
        production: bool,
    }{
        .{ .source = .removed_notification, .production = true },
        .{
            .source = .command_buffer_device_removed,
            .production = true,
        },
        .{ .source = .test_injected, .production = false },
    };
    for (cases, 0..) |case, index| {
        const loss = try makeTestLoss(
            harness.fixture,
            case.source,
            @intCast(40 + index),
        );
        const plan = try makeTestPlan(&harness, lease, loss);
        try validateTestPlan(&harness, plan, lease, loss);
        try std.testing.expectEqual(
            case.production,
            lossRetirementPlanProductionEligibleV1(
                plan,
                loss.observation,
                loss.transition,
            ),
        );
        if (case.production) {
            try requireProductionEligibleLossRetirementPlanV1(
                plan,
                loss.observation,
                loss.transition,
            );
        } else {
            try std.testing.expectEqual(
                lifecycle.EvidenceClassV1.synthetic,
                plan.evidence_class,
            );
            try std.testing.expectError(
                Error.ProductionEvidenceRequired,
                requireProductionEligibleLossRetirementPlanV1(
                    plan,
                    loss.observation,
                    loss.transition,
                ),
            );
        }
    }
    _ = try harness.release(lease);
    try harness.close();
}

test "unavailable lifecycle transition cannot construct retirement" {
    var harness: TestHarness = .{};
    try harness.init("loss retirement unavailable gpu");
    const lease = try harness.materialize();
    const loss = try makeTestLoss(
        harness.fixture,
        .removal_requested_notification,
        50,
    );
    try std.testing.expectEqual(
        device.InventoryStateV1.unavailable,
        loss.transition.successor_state,
    );
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        makeTestPlan(&harness, lease, loss),
    );
    _ = try harness.release(lease);
    try harness.close();
}

test "plan rejects selection source device authority and lease substitution" {
    var harness: TestHarness = .{};
    try harness.init("loss retirement primary gpu");
    const lease = try harness.materialize();
    const loss = try makeTestLoss(
        harness.fixture,
        .removed_notification,
        60,
    );
    const plan = try makeTestPlan(&harness, lease, loss);

    var changed_selection = harness.fixture.selection;
    changed_selection.selected_policy_rank += 1;
    changed_selection.receipt_sha256 =
        device.selectionReceiptRootV1(changed_selection);
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        validateLossRetirementPlanV1(
            plan,
            loss.observation,
            loss.transition,
            loss.cursor,
            harness.fixture.requirement,
            changed_selection,
            &harness.fixture.inventory,
            harness.fixture.inventory[0],
            loss.successor,
            harness.fixture.authority,
            lease,
        ),
    );

    var changed_observation = loss.observation;
    changed_observation.source_instance_sha256 =
        testDigest("substituted lifecycle source");
    changed_observation.observation_sha256 =
        lifecycle.observationRootV1(changed_observation);
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        validateLossRetirementPlanV1(
            plan,
            changed_observation,
            loss.transition,
            loss.cursor,
            harness.fixture.requirement,
            harness.fixture.selection,
            &harness.fixture.inventory,
            harness.fixture.inventory[0],
            loss.successor,
            harness.fixture.authority,
            lease,
        ),
    );

    const foreign = try makeTestFixture(
        "loss retirement foreign gpu",
    );
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        validateLossRetirementPlanV1(
            plan,
            loss.observation,
            loss.transition,
            loss.cursor,
            foreign.requirement,
            foreign.selection,
            &foreign.inventory,
            foreign.inventory[0],
            loss.successor,
            foreign.authority,
            lease,
        ),
    );

    var changed_authority = harness.fixture.authority;
    changed_authority.backend_authority_sha256 =
        testDigest("substituted allocation authority");
    changed_authority.authority_sha256 =
        allocation.authorityRootV1(changed_authority);
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        validateLossRetirementPlanV1(
            plan,
            loss.observation,
            loss.transition,
            loss.cursor,
            harness.fixture.requirement,
            harness.fixture.selection,
            &harness.fixture.inventory,
            harness.fixture.inventory[0],
            loss.successor,
            changed_authority,
            lease,
        ),
    );

    var changed_lease = lease;
    changed_lease.allocation_leaf_set_sha256 =
        testDigest("substituted allocation leaf set");
    changed_lease.lease_sha256 =
        allocation_tree.leaseRootV1(changed_lease);
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        validateLossRetirementPlanV1(
            plan,
            loss.observation,
            loss.transition,
            loss.cursor,
            harness.fixture.requirement,
            harness.fixture.selection,
            &harness.fixture.inventory,
            harness.fixture.inventory[0],
            loss.successor,
            harness.fixture.authority,
            changed_lease,
        ),
    );

    _ = try harness.release(lease);
    try harness.close();
}

test "plan and receipt mutation and replay are explicit" {
    var harness: TestHarness = .{};
    try harness.init("loss retirement replay gpu");
    const lease = try harness.materialize();
    const loss = try makeTestLoss(
        harness.fixture,
        .removed_notification,
        70,
    );
    const plan = try makeTestPlan(&harness, lease, loss);
    try validateLossRetirementPlanReplayV1(plan, plan);

    var unsealed_plan = plan;
    unsealed_plan.adapter_challenge_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        validateTestPlan(&harness, unsealed_plan, lease, loss),
    );
    var changed_plan = unsealed_plan;
    changed_plan.plan_sha256 =
        lossRetirementPlanRootV1(changed_plan);
    try validateTestPlan(&harness, changed_plan, lease, loss);
    try std.testing.expectError(
        Error.InvalidLossRetirementPlan,
        validateLossRetirementPlanReplayV1(
            changed_plan,
            plan,
        ),
    );

    const terminal = try harness.release(lease);
    const receipt = try makeLossRetirementReceiptV1(
        plan,
        terminal,
        testDigest("loss retirement replay settlement"),
        plan.allocation_count,
    );
    try validateLossRetirementReceiptReplayV1(receipt, receipt);
    var unsealed_receipt = receipt;
    unsealed_receipt.adapter_settlement_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidLossRetirementReceipt,
        validateLossRetirementReceiptV1(
            unsealed_receipt,
            plan,
            terminal,
        ),
    );
    var changed_receipt = unsealed_receipt;
    changed_receipt.receipt_sha256 =
        lossRetirementReceiptRootV1(changed_receipt);
    try validateLossRetirementReceiptV1(
        changed_receipt,
        plan,
        terminal,
    );
    try std.testing.expectError(
        Error.InvalidLossRetirementReceipt,
        validateLossRetirementReceiptReplayV1(
            changed_receipt,
            receipt,
        ),
    );
    try harness.close();
}

test "receipt requires the exact ordinary release terminal and counts" {
    var harness: TestHarness = .{};
    try harness.init("loss retirement terminal gpu");
    const lease = try harness.materialize();
    const loss = try makeTestLoss(
        harness.fixture,
        .removed_notification,
        80,
    );
    const plan = try makeTestPlan(&harness, lease, loss);
    const terminal = try harness.release(lease);
    const settlement =
        testDigest("loss retirement terminal settlement");
    const receipt = try makeLossRetirementReceiptV1(
        plan,
        terminal,
        settlement,
        plan.allocation_count,
    );
    try validateLossRetirementReceiptV1(
        receipt,
        plan,
        terminal,
    );
    try std.testing.expectError(
        Error.InvalidLossRetirementReceipt,
        makeLossRetirementReceiptV1(
            plan,
            terminal,
            zero_digest,
            plan.allocation_count,
        ),
    );
    try std.testing.expectError(
        Error.InvalidLossRetirementReceipt,
        makeLossRetirementReceiptV1(
            plan,
            terminal,
            settlement,
            plan.allocation_count + 1,
        ),
    );

    var substituted_terminal = terminal;
    substituted_terminal.lease_sha256 =
        testDigest("substituted terminal lease");
    substituted_terminal.terminal_sha256 =
        allocation_tree.terminalRootV1(substituted_terminal);
    try std.testing.expectError(
        Error.InvalidLossRetirementReceipt,
        validateLossRetirementReceiptV1(
            receipt,
            plan,
            substituted_terminal,
        ),
    );
    try harness.close();
}

test "receipt rejects physical reclaim and every forbidden authority" {
    var harness: TestHarness = .{};
    try harness.init("loss retirement authority gpu");
    const lease = try harness.materialize();
    const loss = try makeTestLoss(
        harness.fixture,
        .removed_notification,
        90,
    );
    const plan = try makeTestPlan(&harness, lease, loss);
    const terminal = try harness.release(lease);
    const receipt = try makeLossRetirementReceiptV1(
        plan,
        terminal,
        testDigest("loss retirement authority settlement"),
        plan.allocation_count,
    );

    for (0..5) |field_index| {
        var changed = receipt;
        switch (field_index) {
            0 => changed.physical_reclaim_observed = 1,
            1 => changed.output_authority_sha256 =
                testDigest("forbidden output authority"),
            2 => changed.migration_authority_sha256 =
                testDigest("forbidden migration authority"),
            3 => changed.reset_authority_sha256 =
                testDigest("forbidden reset authority"),
            4 => changed.physical_reclaim_authority_sha256 =
                testDigest("forbidden reclaim authority"),
            else => unreachable,
        }
        changed.receipt_sha256 =
            lossRetirementReceiptRootV1(changed);
        try std.testing.expectError(
            Error.InvalidLossRetirementReceipt,
            validateLossRetirementReceiptV1(
                changed,
                plan,
                terminal,
            ),
        );
    }
    try harness.close();
}
