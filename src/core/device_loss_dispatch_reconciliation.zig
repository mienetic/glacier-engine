//! Portable evidence for reconciling one in-flight dispatch after exact
//! command-buffer device loss.
//!
//! The retained value keeps the exact live LeaseTree pin and backend loss
//! projection reachable while lifecycle evidence is accepted. The plan binds
//! that retention to the selected device's `present -> lost` transition. The
//! receipt composes the exact terminal failure and Bank pin completion.
//!
//! These values are checksummed composition evidence, not runtime authority.
//! They cannot publish output, select or migrate to another device, reset a
//! device, reclaim physical memory, release a pin, or invoke an adapter.
//! Synthetic evidence remains useful for deterministic structural tests, but
//! is deliberately ineligible for the production gate.

const std = @import("std");
const device = @import("device_capability_contract.zig");
const lifecycle = @import("device_lifecycle_contract.zig");
const allocation = @import("device_allocation_lease.zig");
const allocation_tree = @import("device_allocation_lease_tree.zig");
const resource = @import("resource_bank.zig");

pub const Digest = device.Digest;
pub const zero_digest = device.zero_digest;

pub const retention_abi: u64 = 0x4744_4454_0000_0001;
pub const plan_abi: u64 = 0x4744_4450_0000_0001;
pub const receipt_abi: u64 = 0x4744_4452_0000_0001;

const retention_domain =
    "glacier-device-loss-dispatch-retention-v1\x00";
const plan_domain =
    "glacier-device-loss-dispatch-reconciliation-plan-v1\x00";
const receipt_domain =
    "glacier-device-loss-dispatch-reconciliation-receipt-v1\x00";

pub const LossDispatchRetentionKindV1 = enum(u64) {
    exact_command_device_removed = 1,
    _,
};

pub const Error = error{
    InvalidLossDispatchRetention,
    InvalidLossDispatchReconciliationPlan,
    ProductionEvidenceRequired,
    InvalidLossDispatchReconciliationReceipt,
};

/// Pointer-free retention for one exact live dispatch pin after the backend
/// observed the command-specific device-removed signature. The signature
/// fields are always the canonical 5/1/11 projection. `source` and
/// `evidence_class` keep an explicitly injected test projection distinct from
/// native production evidence.
pub const LossDispatchRetentionV1 = struct {
    abi_version: u64 = retention_abi,
    kind: LossDispatchRetentionKindV1 =
        .exact_command_device_removed,
    source: lifecycle.ObservationSourceV1 =
        .command_buffer_device_removed,
    evidence_class: lifecycle.EvidenceClassV1 = .native,
    dispatch_generation: u64 = 0,
    allocation_count: u64 = 0,
    pinned_device_bytes: u64 = 0,
    native_command_status: u64 = 0,
    native_completion_observed: u64 = 0,
    native_error_domain_kind: u64 = 0,
    native_error_code_bits: u64 = 0,
    selected_capability_sha256: Digest = zero_digest,
    allocation_lease_sha256: Digest = zero_digest,
    allocation_leaf_set_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    dispatch_pin_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    submission_sha256: Digest = zero_digest,
    backend_quarantine_sha256: Digest = zero_digest,
    adapter_challenge_sha256: Digest = zero_digest,
    output_authority_sha256: Digest = zero_digest,
    retention_sha256: Digest = zero_digest,
};

/// Immutable reconciliation proposal for the exact retained pin and exact
/// lifecycle transition. It has no terminal, unpin, output, reset, selection,
/// or migration authority.
pub const LossDispatchReconciliationPlanV1 = struct {
    abi_version: u64 = plan_abi,
    source: lifecycle.ObservationSourceV1 =
        .command_buffer_device_removed,
    evidence_class: lifecycle.EvidenceClassV1 = .native,
    successor_state: device.InventoryStateV1 = .lost,
    source_sequence: u64 = 0,
    reconciliation_generation: u64 = 0,
    source_instance_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
    transition_receipt_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    retention_sha256: Digest = zero_digest,
    plan_sha256: Digest = zero_digest,
};

/// Immutable composition receipt for one exact terminal-failure settlement.
/// A trusted coordinator must still own and consume the private Bank permit;
/// this receipt carries none of that authority.
pub const LossDispatchReconciliationReceiptV1 = struct {
    abi_version: u64 = receipt_abi,
    source: lifecycle.ObservationSourceV1 =
        .command_buffer_device_removed,
    evidence_class: lifecycle.EvidenceClassV1 = .native,
    outcome: allocation_tree.DispatchTerminalOutcomeV1 =
        .terminal_failure,
    source_sequence: u64 = 0,
    reconciliation_generation: u64 = 0,
    released_dispatch_pin_count: u64 = 0,
    finalized_native_command_count: u64 = 0,
    plan_sha256: Digest = zero_digest,
    retention_sha256: Digest = zero_digest,
    backend_terminal_sha256: Digest = zero_digest,
    dispatch_terminal_sha256: Digest = zero_digest,
    dispatch_completion_sha256: Digest = zero_digest,
    bank_completion_sha256: Digest = zero_digest,
    adapter_settlement_sha256: Digest = zero_digest,
    output_authority_sha256: Digest = zero_digest,
    migration_authority_sha256: Digest = zero_digest,
    reset_authority_sha256: Digest = zero_digest,
    physical_reclaim_authority_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

comptime {
    if (@sizeOf(LossDispatchRetentionV1) != 440)
        @compileError("LossDispatchRetentionV1 layout changed");
    if (@sizeOf(LossDispatchReconciliationPlanV1) != 240)
        @compileError(
            "LossDispatchReconciliationPlanV1 layout changed",
        );
    if (@sizeOf(LossDispatchReconciliationReceiptV1) != 448)
        @compileError(
            "LossDispatchReconciliationReceiptV1 layout changed",
        );
}

pub fn makeLossDispatchRetentionV1(
    source: lifecycle.ObservationSourceV1,
    evidence_class: lifecycle.EvidenceClassV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    submission_sha256: Digest,
    backend_quarantine_sha256: Digest,
    adapter_challenge_sha256: Digest,
) Error!LossDispatchRetentionV1 {
    var result: LossDispatchRetentionV1 = .{
        .source = source,
        .evidence_class = evidence_class,
        .dispatch_generation = pin.dispatch_generation,
        .allocation_count = pin.allocation_count,
        .pinned_device_bytes = pin.pinned_device_bytes,
        .native_command_status = lifecycle.command_buffer_status_error,
        .native_completion_observed = 1,
        .native_error_domain_kind = lifecycle.command_buffer_error_domain,
        .native_error_code_bits = lifecycle.command_buffer_device_removed_error,
        .selected_capability_sha256 = selected_entry.capability.capability_sha256,
        .allocation_lease_sha256 = lease.lease_sha256,
        .allocation_leaf_set_sha256 = lease.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = lease.backend_object_set_sha256,
        .dispatch_pin_sha256 = pin.pin_sha256,
        .dispatch_request_sha256 = pin.dispatch_request_sha256,
        .submission_sha256 = submission_sha256,
        .backend_quarantine_sha256 = backend_quarantine_sha256,
        .adapter_challenge_sha256 = adapter_challenge_sha256,
    };
    result.retention_sha256 = lossDispatchRetentionRootV1(result);
    try validateLossDispatchRetentionV1(
        result,
        selected_entry,
        lease,
        pin,
    );
    return result;
}

pub fn validateLossDispatchRetentionV1(
    value: LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
) Error!void {
    device.validateInventoryEntryV1(selected_entry) catch
        return Error.InvalidLossDispatchRetention;
    allocation_tree.validateLeaseV1(lease) catch
        return Error.InvalidLossDispatchRetention;
    allocation_tree.validateDispatchPinV1(pin) catch
        return Error.InvalidLossDispatchRetention;

    if (selected_entry.state != .present or
        !sourceEvidencePairValidV1(
            value.source,
            value.evidence_class,
        ) or
        value.abi_version != retention_abi or
        value.kind != .exact_command_device_removed or
        value.dispatch_generation != pin.dispatch_generation or
        value.allocation_count != pin.allocation_count or
        value.allocation_count != lease.allocation_count or
        value.pinned_device_bytes != pin.pinned_device_bytes or
        value.pinned_device_bytes != lease.materialized_bytes or
        value.native_command_status !=
            lifecycle.command_buffer_status_error or
        value.native_completion_observed != 1 or
        value.native_error_domain_kind !=
            lifecycle.command_buffer_error_domain or
        value.native_error_code_bits !=
            lifecycle.command_buffer_device_removed_error or
        lease.coordinator_epoch != pin.coordinator_epoch or
        lease.generation != pin.allocation_generation or
        !digestEqual(
            lease.authority_sha256,
            pin.authority_sha256,
        ) or
        !digestEqual(lease.request_sha256, pin.request_sha256) or
        !digestEqual(
            lease.admission_sha256,
            pin.admission_sha256,
        ) or
        !digestEqual(lease.lease_sha256, pin.lease_sha256) or
        !digestEqual(
            lease.parent_receipt_sha256,
            pin.parent_receipt_sha256,
        ) or
        !digestEqual(
            lease.allocation_leaf_set_sha256,
            pin.allocation_leaf_set_sha256,
        ) or
        !digestEqual(
            lease.backend_object_set_sha256,
            pin.backend_object_set_sha256,
        ) or
        !std.meta.eql(lease.scope, pin.scope) or
        !digestEqual(
            lease.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
        ) or
        !digestEqual(
            value.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
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
        !digestEqual(value.dispatch_pin_sha256, pin.pin_sha256) or
        !digestEqual(
            value.dispatch_request_sha256,
            pin.dispatch_request_sha256,
        ) or
        digestIsZero(value.submission_sha256) or
        digestIsZero(value.backend_quarantine_sha256) or
        digestIsZero(value.adapter_challenge_sha256) or
        !digestEqual(value.output_authority_sha256, zero_digest) or
        digestIsZero(value.retention_sha256) or
        !digestEqual(
            value.retention_sha256,
            lossDispatchRetentionRootV1(value),
        ))
        return Error.InvalidLossDispatchRetention;
}

pub fn lossDispatchRetentionRootV1(
    value: LossDispatchRetentionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(retention_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.kind));
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, value.dispatch_generation);
    hashU64(&hash, value.allocation_count);
    hashU64(&hash, value.pinned_device_bytes);
    hashU64(&hash, value.native_command_status);
    hashU64(&hash, value.native_completion_observed);
    hashU64(&hash, value.native_error_domain_kind);
    hashU64(&hash, value.native_error_code_bits);
    hash.update(&value.selected_capability_sha256);
    hash.update(&value.allocation_lease_sha256);
    hash.update(&value.allocation_leaf_set_sha256);
    hash.update(&value.backend_object_set_sha256);
    hash.update(&value.dispatch_pin_sha256);
    hash.update(&value.dispatch_request_sha256);
    hash.update(&value.submission_sha256);
    hash.update(&value.backend_quarantine_sha256);
    hash.update(&value.adapter_challenge_sha256);
    hash.update(&value.output_authority_sha256);
    return finish(&hash);
}

pub fn validateLossDispatchRetentionReplayV1(
    candidate: LossDispatchRetentionV1,
    retained: LossDispatchRetentionV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossDispatchRetention;
}

pub fn makeLossDispatchReconciliationPlanV1(
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    retention: LossDispatchRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    reconciliation_generation: u64,
) Error!LossDispatchReconciliationPlanV1 {
    var result: LossDispatchReconciliationPlanV1 = .{
        .source = observation.source,
        .evidence_class = observation.evidence_class,
        .successor_state = transition.successor_state,
        .source_sequence = observation.source_sequence,
        .reconciliation_generation = reconciliation_generation,
        .source_instance_sha256 = observation.source_instance_sha256,
        .observation_sha256 = observation.observation_sha256,
        .transition_receipt_sha256 = transition.receipt_sha256,
        .selected_capability_sha256 = selected_entry.capability.capability_sha256,
        .retention_sha256 = retention.retention_sha256,
    };
    result.plan_sha256 =
        lossDispatchReconciliationPlanRootV1(result);
    try validateLossDispatchReconciliationPlanV1(
        result,
        observation,
        transition,
        source_cursor,
        requirement,
        selection,
        prior_inventory,
        selected_entry,
        successor_entry,
        retention,
        lease,
        pin,
    );
    return result;
}

/// Replay the lifecycle cursor, deterministic selection, exact live lease,
/// exact dispatch pin, and retained loss projection. `source_cursor` is the
/// value immediately before the observation is consumed.
pub fn validateLossDispatchReconciliationPlanV1(
    value: LossDispatchReconciliationPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    retention: LossDispatchRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
) Error!void {
    lifecycle.validateTransitionReceiptV1(
        transition,
        observation,
        selected_entry,
        prior_inventory,
        successor_entry,
        source_cursor,
    ) catch return Error.InvalidLossDispatchReconciliationPlan;
    device.validateRequirementV1(requirement) catch
        return Error.InvalidLossDispatchReconciliationPlan;
    device.validateSelectionReceiptV1(
        selection,
        requirement,
        prior_inventory,
    ) catch return Error.InvalidLossDispatchReconciliationPlan;
    device.validateInventoryEntryV1(selected_entry) catch
        return Error.InvalidLossDispatchReconciliationPlan;
    device.validateInventoryEntryV1(successor_entry) catch
        return Error.InvalidLossDispatchReconciliationPlan;
    validateLossDispatchRetentionV1(
        retention,
        selected_entry,
        lease,
        pin,
    ) catch return Error.InvalidLossDispatchReconciliationPlan;

    if (!sourceEvidencePairValidV1(
        observation.source,
        observation.evidence_class,
    ) or
        observation.observed_state != .lost or
        transition.prior_state != .present or
        transition.successor_state != .lost or
        selected_entry.state != .present or
        successor_entry.state != .lost or
        observation.source != transition.source or
        observation.evidence_class != transition.evidence_class or
        retention.source != observation.source or
        retention.evidence_class != observation.evidence_class or
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
        !digestEqual(
            lease.selection_receipt_sha256,
            selection.receipt_sha256,
        ) or
        !digestEqual(
            lease.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
        ) or
        value.abi_version != plan_abi or
        value.source != observation.source or
        value.evidence_class != observation.evidence_class or
        value.successor_state != .lost or
        value.successor_state != transition.successor_state or
        value.source_sequence != observation.source_sequence or
        value.source_sequence != transition.source_sequence or
        value.reconciliation_generation == 0 or
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
            value.selected_capability_sha256,
            selected_entry.capability.capability_sha256,
        ) or
        !digestEqual(
            value.retention_sha256,
            retention.retention_sha256,
        ) or
        digestIsZero(value.plan_sha256) or
        !digestEqual(
            value.plan_sha256,
            lossDispatchReconciliationPlanRootV1(value),
        ))
        return Error.InvalidLossDispatchReconciliationPlan;
}

/// Production accepts only the native command-level device-removed event
/// carrying the canonical status/domain/code tuple 5/1/11. Structurally valid
/// test injection is intentionally rejected here.
pub fn lossDispatchReconciliationPlanProductionEligibleV1(
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) bool {
    return planShapeBoundToRetentionValidV1(
        plan,
        retention,
    ) and
        retention.abi_version == retention_abi and
        plan.source == .command_buffer_device_removed and
        retention.source == .command_buffer_device_removed and
        observation.source == .command_buffer_device_removed and
        transition.source == .command_buffer_device_removed and
        plan.evidence_class == .native and
        retention.evidence_class == .native and
        observation.evidence_class == .native and
        transition.evidence_class == .native and
        plan.successor_state == .lost and
        observation.observed_state == .lost and
        transition.prior_state == .present and
        transition.successor_state == .lost and
        plan.source_sequence == observation.source_sequence and
        plan.source_sequence == transition.source_sequence and
        digestEqual(
            plan.source_instance_sha256,
            observation.source_instance_sha256,
        ) and
        digestEqual(
            plan.selected_capability_sha256,
            observation.capability_sha256,
        ) and
        digestEqual(
            plan.selected_capability_sha256,
            transition.capability_sha256,
        ) and
        retention.kind == .exact_command_device_removed and
        retention.native_command_status ==
            lifecycle.command_buffer_status_error and
        retention.native_completion_observed == 1 and
        retention.native_error_domain_kind ==
            lifecycle.command_buffer_error_domain and
        retention.native_error_code_bits ==
            lifecycle.command_buffer_device_removed_error and
        observation.native_command_status ==
            lifecycle.command_buffer_status_error and
        observation.native_error_domain_kind ==
            lifecycle.command_buffer_error_domain and
        observation.native_error_code_bits ==
            lifecycle.command_buffer_device_removed_error and
        retention.allocation_count != 0 and
        retention.pinned_device_bytes >=
            retention.allocation_count and
        !digestIsZero(retention.submission_sha256) and
        !digestIsZero(retention.backend_quarantine_sha256) and
        !digestIsZero(retention.adapter_challenge_sha256) and
        digestEqual(retention.output_authority_sha256, zero_digest) and
        digestEqual(
            plan.observation_sha256,
            observation.observation_sha256,
        ) and
        digestEqual(
            observation.observation_sha256,
            lifecycle.observationRootV1(observation),
        ) and
        !digestIsZero(observation.observation_sha256) and
        digestEqual(
            plan.transition_receipt_sha256,
            transition.receipt_sha256,
        ) and
        digestEqual(
            transition.observation_sha256,
            observation.observation_sha256,
        ) and
        digestEqual(
            transition.receipt_sha256,
            lifecycle.transitionReceiptRootV1(transition),
        ) and
        !digestIsZero(transition.receipt_sha256) and
        digestEqual(
            retention.retention_sha256,
            lossDispatchRetentionRootV1(retention),
        ) and
        !digestIsZero(retention.retention_sha256);
}

pub fn requireProductionEligibleLossDispatchReconciliationPlanV1(
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) Error!void {
    if (!lossDispatchReconciliationPlanProductionEligibleV1(
        plan,
        retention,
        observation,
        transition,
    ))
        return Error.ProductionEvidenceRequired;
}

pub fn lossDispatchReconciliationPlanRootV1(
    value: LossDispatchReconciliationPlanV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, @intFromEnum(value.successor_state));
    hashU64(&hash, value.source_sequence);
    hashU64(&hash, value.reconciliation_generation);
    hash.update(&value.source_instance_sha256);
    hash.update(&value.observation_sha256);
    hash.update(&value.transition_receipt_sha256);
    hash.update(&value.selected_capability_sha256);
    hash.update(&value.retention_sha256);
    return finish(&hash);
}

pub fn validateLossDispatchReconciliationPlanReplayV1(
    candidate: LossDispatchReconciliationPlanV1,
    retained: LossDispatchReconciliationPlanV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossDispatchReconciliationPlan;
}

pub fn makeLossDispatchReconciliationReceiptV1(
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    terminal: allocation_tree.DispatchTerminalEvidenceV1,
    completion: allocation_tree.LeaseTreeDispatchCompletionV1,
    adapter_settlement_sha256: Digest,
) Error!LossDispatchReconciliationReceiptV1 {
    var result: LossDispatchReconciliationReceiptV1 = .{
        .source = plan.source,
        .evidence_class = plan.evidence_class,
        .outcome = terminal.outcome,
        .source_sequence = plan.source_sequence,
        .reconciliation_generation = plan.reconciliation_generation,
        .released_dispatch_pin_count = 1,
        .finalized_native_command_count = 1,
        .plan_sha256 = plan.plan_sha256,
        .retention_sha256 = retention.retention_sha256,
        .backend_terminal_sha256 = terminal.backend_completion_sha256,
        .dispatch_terminal_sha256 = terminal.terminal_sha256,
        .dispatch_completion_sha256 = completion.completion_sha256,
        .bank_completion_sha256 = completion.bank_completion_sha256,
        .adapter_settlement_sha256 = adapter_settlement_sha256,
    };
    result.receipt_sha256 =
        lossDispatchReconciliationReceiptRootV1(result);
    try validateLossDispatchReconciliationReceiptV1(
        result,
        plan,
        retention,
        selected_entry,
        lease,
        pin,
        terminal,
        completion,
    );
    return result;
}

pub fn validateLossDispatchReconciliationReceiptV1(
    value: LossDispatchReconciliationReceiptV1,
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    terminal: allocation_tree.DispatchTerminalEvidenceV1,
    completion: allocation_tree.LeaseTreeDispatchCompletionV1,
) Error!void {
    validateLossDispatchRetentionV1(
        retention,
        selected_entry,
        lease,
        pin,
    ) catch return Error.InvalidLossDispatchReconciliationReceipt;
    allocation_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    ) catch return Error.InvalidLossDispatchReconciliationReceipt;
    allocation_tree.validateDispatchCompletionForPinV1(
        completion,
        pin,
        terminal,
    ) catch return Error.InvalidLossDispatchReconciliationReceipt;

    if (!planShapeBoundToRetentionValidV1(plan, retention) or
        terminal.outcome != .terminal_failure or
        completion.outcome != .terminal_failure or
        !digestEqual(
            terminal.submission_sha256,
            retention.submission_sha256,
        ) or
        digestIsZero(terminal.backend_completion_sha256) or
        !digestEqual(terminal.output_sha256, zero_digest) or
        !digestEqual(completion.output_sha256, zero_digest) or
        value.abi_version != receipt_abi or
        value.source != plan.source or
        value.source != retention.source or
        value.evidence_class != plan.evidence_class or
        value.evidence_class != retention.evidence_class or
        value.outcome != .terminal_failure or
        value.source_sequence != plan.source_sequence or
        value.reconciliation_generation !=
            plan.reconciliation_generation or
        value.released_dispatch_pin_count != 1 or
        value.finalized_native_command_count != 1 or
        !digestEqual(value.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            value.retention_sha256,
            retention.retention_sha256,
        ) or
        !digestEqual(
            value.backend_terminal_sha256,
            terminal.backend_completion_sha256,
        ) or
        !digestEqual(
            value.dispatch_terminal_sha256,
            terminal.terminal_sha256,
        ) or
        !digestEqual(
            value.dispatch_completion_sha256,
            completion.completion_sha256,
        ) or
        !digestEqual(
            value.bank_completion_sha256,
            completion.bank_completion_sha256,
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
            lossDispatchReconciliationReceiptRootV1(value),
        ))
        return Error.InvalidLossDispatchReconciliationReceipt;
}

pub fn lossDispatchReconciliationReceiptRootV1(
    value: LossDispatchReconciliationReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, @intFromEnum(value.outcome));
    hashU64(&hash, value.source_sequence);
    hashU64(&hash, value.reconciliation_generation);
    hashU64(&hash, value.released_dispatch_pin_count);
    hashU64(&hash, value.finalized_native_command_count);
    hash.update(&value.plan_sha256);
    hash.update(&value.retention_sha256);
    hash.update(&value.backend_terminal_sha256);
    hash.update(&value.dispatch_terminal_sha256);
    hash.update(&value.dispatch_completion_sha256);
    hash.update(&value.bank_completion_sha256);
    hash.update(&value.adapter_settlement_sha256);
    hash.update(&value.output_authority_sha256);
    hash.update(&value.migration_authority_sha256);
    hash.update(&value.reset_authority_sha256);
    hash.update(&value.physical_reclaim_authority_sha256);
    return finish(&hash);
}

pub fn validateLossDispatchReconciliationReceiptReplayV1(
    candidate: LossDispatchReconciliationReceiptV1,
    retained: LossDispatchReconciliationReceiptV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossDispatchReconciliationReceipt;
}

fn sourceEvidencePairValidV1(
    source: lifecycle.ObservationSourceV1,
    evidence_class: lifecycle.EvidenceClassV1,
) bool {
    return switch (source) {
        .command_buffer_device_removed => evidence_class == .native,
        .test_injected => evidence_class == .synthetic,
        else => false,
    };
}

fn planShapeBoundToRetentionValidV1(
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
) bool {
    return plan.abi_version == plan_abi and
        sourceEvidencePairValidV1(
            plan.source,
            plan.evidence_class,
        ) and
        plan.source == retention.source and
        plan.evidence_class == retention.evidence_class and
        plan.successor_state == .lost and
        plan.source_sequence != 0 and
        plan.reconciliation_generation != 0 and
        !digestIsZero(plan.source_instance_sha256) and
        !digestIsZero(plan.observation_sha256) and
        !digestIsZero(plan.transition_receipt_sha256) and
        !digestIsZero(plan.selected_capability_sha256) and
        digestEqual(
            plan.selected_capability_sha256,
            retention.selected_capability_sha256,
        ) and
        !digestIsZero(plan.retention_sha256) and
        digestEqual(
            plan.retention_sha256,
            retention.retention_sha256,
        ) and
        !digestIsZero(plan.plan_sha256) and
        digestEqual(
            plan.plan_sha256,
            lossDispatchReconciliationPlanRootV1(plan),
        );
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

const test_request_epoch: u64 = 0x4449_5350;
const test_session_id: usize = 0x5245_434f;

const TestHarness = struct {
    slots: [1]resource.Slot = [_]resource.Slot{.{}},
    roots: [1]resource.LeaseTreeRootSlot =
        [_]resource.LeaseTreeRootSlot{.{}},
    nodes: [2]resource.LeaseNodeSlot =
        [_]resource.LeaseNodeSlot{.{}} ** 2,
    pin_slots: [1]resource.LeasePinSlotV1 =
        [_]resource.LeasePinSlotV1{.{}},
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
    coordinator_dispatches: [1]allocation_tree.CoordinatorDispatchSlotV1 =
        [_]allocation_tree.CoordinatorDispatchSlotV1{.{}},
    coordinator: allocation_tree.CoordinatorV1 = .{},
    fixture: TestFixture = undefined,

    fn init(self: *@This(), label: []const u8) !void {
        self.fixture = try makeTestFixture(label);
        self.bank = try resource.Bank.initWithLeaseTreePinStorage(
            &self.slots,
            &self.roots,
            &self.nodes,
            &self.pin_slots,
            .{
                .host_bytes = 1_024,
                .capsule_bytes = 1_024,
                .device_bytes = self.fixture.manifest.total_charged_bytes,
                .queue_slots = 1,
            },
            53,
        );
        self.parent = try self.bank.commit(
            try self.bank.reserve(
                9_701,
                .{
                    .capsule_bytes = 64,
                    .queue_slots = 1,
                },
            ),
        );
        const opened = try self.bank.openLeaseTree(
            self.parent,
            0x7265_636f_7472_6565,
            0x7265_636f_6175_7468,
            .{
                .device_bytes = self.fixture.manifest.total_charged_bytes,
            },
        );
        const scoped = try self.bank.openLeaseScope(
            opened,
            0x7265_636f_7363_6f70,
            0x7265_636f_7465_6e61,
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
        try self.coordinator.initWithDispatchStorage(
            0x5245_434f_434f_4f52,
            &self.bank,
            &self.tree,
            self.scope,
            test_request_epoch,
            test_session_id,
            &self.publication_sequence,
            &self.coordinator_objects,
            &self.coordinator_dispatches,
        );
    }

    fn request(self: *@This()) !allocation.AllocationRequestV1 {
        return allocation.makeRequestV1(
            test_request_epoch,
            testDigest("dispatch reconciliation request owner"),
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
    ) !void {
        const outcome = try self.coordinator.release(
            lease,
            self.backend.adapter(),
        );
        _ = switch (outcome) {
            .terminal => |terminal| terminal,
            else => return error.TestExpectedTerminalReceipt,
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
        try std.testing.expect(
            (try self.bank.snapshot()).used.isZero(),
        );
    }
};

const TestDispatchAdapter = struct {
    expected_terminal_sha256: Digest = zero_digest,

    fn interface(
        self: *@This(),
    ) allocation_tree.DispatchAdapterV1 {
        return .{
            .context = self,
            .dispatch_authority_sha256 = testDigest("dispatch reconciliation authority"),
            .queue_authority_sha256 = testDigest("dispatch reconciliation queue"),
            .reserve_dispatch_intent_fn = reserve,
            .abort_dispatch_intent_fn = abort,
            .validate_terminal_fn = validateTerminal,
            .confirm_settlement_fn = confirmSettlement,
        };
    }

    fn expect(
        self: *@This(),
        terminal: allocation_tree.DispatchTerminalEvidenceV1,
    ) void {
        self.expected_terminal_sha256 = terminal.terminal_sha256;
    }

    fn reserve(
        _: *anyopaque,
        intent: allocation_tree.DispatchPinIntentV1,
    ) allocation_tree.DispatchCallbackError!void {
        allocation_tree.validateDispatchPinIntentV1(intent) catch
            return error.InvalidDispatchIntent;
    }

    fn abort(
        _: *anyopaque,
        intent: allocation_tree.DispatchPinIntentV1,
    ) allocation_tree.DispatchCallbackError!void {
        allocation_tree.validateDispatchPinIntentV1(intent) catch
            return error.InvalidDispatchIntent;
    }

    fn validateTerminal(
        context: *anyopaque,
        terminal: allocation_tree.DispatchTerminalEvidenceV1,
    ) allocation_tree.DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (digestIsZero(self.expected_terminal_sha256) or
            !digestEqual(
                self.expected_terminal_sha256,
                terminal.terminal_sha256,
            ))
            return error.InvalidTerminalEvidence;
    }

    fn confirmSettlement(
        context: *anyopaque,
        pin: allocation_tree.LeaseTreeDispatchPinV1,
        terminal: allocation_tree.DispatchTerminalEvidenceV1,
        completion: allocation_tree.LeaseTreeDispatchCompletionV1,
        bank_permit: resource.LeasePinPermitV1,
        bank_completion: resource.LeasePinCompletionV1,
    ) allocation_tree.DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        allocation_tree.validateDispatchSettlementForPinV1(
            completion,
            pin,
            terminal,
            bank_permit,
            bank_completion,
        ) catch return error.InvalidSettlementEvidence;
        if (digestIsZero(self.expected_terminal_sha256) or
            !digestEqual(
                self.expected_terminal_sha256,
                terminal.terminal_sha256,
            ))
            return error.InvalidSettlementEvidence;
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
        .backend_sha256 = testDigest("dispatch reconciliation backend"),
        .device_sha256 = testDigest(label),
        .driver_sha256 = testDigest("dispatch reconciliation driver"),
        .placement_sha256 = testDigest("dispatch reconciliation placement"),
    });
    const inventory = [1]device.DeviceInventoryEntryV1{
        try device.sealInventoryEntryV1(.{
            .discovery_epoch = 29,
            .policy_rank = 2,
            .state = .present,
            .capability = capability,
        }),
    };
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = testDigest("dispatch reconciliation execution plan"),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profile,
        .required_operator_bits = device.profileOperatorBitsV1(profile),
        .required_element_type_bits = device.profileElementTypeBitsV1(profile),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profile),
        .required_feature_bits = device.FeatureBitsV1.allocation |
            device.FeatureBitsV1.dispatch |
            device.FeatureBitsV1.completion_fence |
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
        37,
        1,
        1,
        1_024,
        inventory[selection.selected_index],
        testDigest("dispatch reconciliation adapter authority"),
    );
    const quote = try allocation.makeFakeQuoteV1(
        authority,
        testDigest("dispatch reconciliation buffer"),
        4_000,
    );
    const entries = [1]allocation.AllocationEntryV1{.{
        .binding_sha256 = testDigest("dispatch reconciliation buffer"),
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
        .source_instance_sha256 = testDigest("dispatch reconciliation source instance"),
        .last_sequence = source_sequence - 1,
    };
    const native_fields: [3]u64 =
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
        testDigest("dispatch reconciliation lifecycle evidence"),
        native_fields[0],
        native_fields[1],
        native_fields[2],
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

fn makeTestRetention(
    harness: *TestHarness,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    loss: TestLoss,
    submission_sha256: Digest,
) !LossDispatchRetentionV1 {
    return makeLossDispatchRetentionV1(
        loss.observation.source,
        loss.observation.evidence_class,
        harness.fixture.inventory[0],
        lease,
        pin,
        submission_sha256,
        testDigest("dispatch reconciliation quarantine"),
        testDigest("dispatch reconciliation challenge"),
    );
}

fn makeTestPlan(
    harness: *TestHarness,
    retention: LossDispatchRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    loss: TestLoss,
) !LossDispatchReconciliationPlanV1 {
    return makeLossDispatchReconciliationPlanV1(
        loss.observation,
        loss.transition,
        loss.cursor,
        harness.fixture.requirement,
        harness.fixture.selection,
        &harness.fixture.inventory,
        harness.fixture.inventory[0],
        loss.successor,
        retention,
        lease,
        pin,
        13,
    );
}

fn validateTestPlan(
    harness: *TestHarness,
    plan: LossDispatchReconciliationPlanV1,
    retention: LossDispatchRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    loss: TestLoss,
) !void {
    try validateLossDispatchReconciliationPlanV1(
        plan,
        loss.observation,
        loss.transition,
        loss.cursor,
        harness.fixture.requirement,
        harness.fixture.selection,
        &harness.fixture.inventory,
        harness.fixture.inventory[0],
        loss.successor,
        retention,
        lease,
        pin,
    );
}

fn testDigest(bytes: []const u8) Digest {
    return device.digestV1(bytes);
}

fn expectDigestHex(
    expected: []const u8,
    actual: Digest,
) !void {
    const encoded = std.fmt.bytesToHex(actual, .lower);
    try std.testing.expectEqualStrings(expected, &encoded);
}

test "loss dispatch reconciliation values have literal ABIs layouts and no pointers" {
    try std.testing.expectEqual(
        @as(u64, 0x4744_4454_0000_0001),
        retention_abi,
    );
    try std.testing.expectEqual(
        @as(u64, 0x4744_4450_0000_0001),
        plan_abi,
    );
    try std.testing.expectEqual(
        @as(u64, 0x4744_4452_0000_0001),
        receipt_abi,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        @intFromEnum(
            LossDispatchRetentionKindV1
                .exact_command_device_removed,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 440),
        @sizeOf(LossDispatchRetentionV1),
    );
    try std.testing.expectEqual(
        @as(usize, 240),
        @sizeOf(LossDispatchReconciliationPlanV1),
    );
    try std.testing.expectEqual(
        @as(usize, 448),
        @sizeOf(LossDispatchReconciliationReceiptV1),
    );
    try std.testing.expect(
        !portableTypeHasPointer(LossDispatchRetentionV1),
    );
    try std.testing.expect(
        !portableTypeHasPointer(
            LossDispatchReconciliationPlanV1,
        ),
    );
    try std.testing.expect(
        !portableTypeHasPointer(
            LossDispatchReconciliationReceiptV1,
        ),
    );
}

test "loss dispatch reconciliation literal roots stay stable" {
    var harness: TestHarness = .{};
    try harness.init("dispatch reconciliation golden gpu");
    const lease = try harness.materialize();
    var dispatch: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("dispatch reconciliation dispatch request"),
    );
    const loss = try makeTestLoss(
        harness.fixture,
        .command_buffer_device_removed,
        71,
    );
    const submission =
        testDigest("dispatch reconciliation submission");
    const retention = try makeTestRetention(
        &harness,
        lease,
        pin,
        loss,
        submission,
    );
    const plan = try makeTestPlan(
        &harness,
        retention,
        lease,
        pin,
        loss,
    );
    const terminal = try allocation_tree.makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        submission,
        testDigest("dispatch reconciliation backend terminal"),
        zero_digest,
    );
    dispatch.expect(terminal);
    const completion =
        try harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        );
    const receipt = try makeLossDispatchReconciliationReceiptV1(
        plan,
        retention,
        harness.fixture.inventory[0],
        lease,
        pin,
        terminal,
        completion,
        testDigest("dispatch reconciliation settlement"),
    );

    try expectDigestHex(
        "20daad021a4bff0c35885a7df278ea0b5fe2deaa8d35fc79a0f6c1d0f20f18df",
        retention.retention_sha256,
    );
    try expectDigestHex(
        "ea109393330b8f89f47eb5464f14323dfc5c7205a7c1c4ef3e0fb2703e5360b2",
        plan.plan_sha256,
    );
    try expectDigestHex(
        "70840a0821700dd7fab6a08ff25e63a016c7ebc1fe024f77597564778ba86a2b",
        receipt.receipt_sha256,
    );

    try harness.release(lease);
    try harness.close();
}

test "production gate is exact and test injection remains structural" {
    var harness: TestHarness = .{};
    try harness.init("dispatch reconciliation eligibility gpu");
    const lease = try harness.materialize();
    var dispatch: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("dispatch reconciliation eligibility request"),
    );
    const submission =
        testDigest("dispatch reconciliation eligibility submission");
    const cases = [_]struct {
        source: lifecycle.ObservationSourceV1,
        eligible: bool,
    }{
        .{
            .source = .command_buffer_device_removed,
            .eligible = true,
        },
        .{ .source = .test_injected, .eligible = false },
    };
    for (cases, 0..) |case, index| {
        const loss = try makeTestLoss(
            harness.fixture,
            case.source,
            @intCast(80 + index),
        );
        const retention = try makeTestRetention(
            &harness,
            lease,
            pin,
            loss,
            submission,
        );
        const plan = try makeTestPlan(
            &harness,
            retention,
            lease,
            pin,
            loss,
        );
        try validateTestPlan(
            &harness,
            plan,
            retention,
            lease,
            pin,
            loss,
        );
        try std.testing.expectEqual(
            case.eligible,
            lossDispatchReconciliationPlanProductionEligibleV1(
                plan,
                retention,
                loss.observation,
                loss.transition,
            ),
        );
        if (case.eligible) {
            try requireProductionEligibleLossDispatchReconciliationPlanV1(
                plan,
                retention,
                loss.observation,
                loss.transition,
            );
        } else {
            try std.testing.expectError(
                Error.ProductionEvidenceRequired,
                requireProductionEligibleLossDispatchReconciliationPlanV1(
                    plan,
                    retention,
                    loss.observation,
                    loss.transition,
                ),
            );
        }
    }

    const terminal = try allocation_tree.makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        submission,
        testDigest(
            "dispatch reconciliation eligibility terminal",
        ),
        zero_digest,
    );
    dispatch.expect(terminal);
    _ = try harness.coordinator.completeDispatchPin(
        pin,
        dispatch.interface(),
        terminal,
    );
    try harness.release(lease);
    try harness.close();
}

test "nested substitutions and replay fail closed" {
    var harness: TestHarness = .{};
    try harness.init("dispatch reconciliation replay gpu");
    const lease = try harness.materialize();
    var dispatch: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("dispatch reconciliation replay request"),
    );
    const loss = try makeTestLoss(
        harness.fixture,
        .command_buffer_device_removed,
        91,
    );
    const submission =
        testDigest("dispatch reconciliation replay submission");
    const retention = try makeTestRetention(
        &harness,
        lease,
        pin,
        loss,
        submission,
    );
    const plan = try makeTestPlan(
        &harness,
        retention,
        lease,
        pin,
        loss,
    );
    try validateLossDispatchRetentionReplayV1(
        retention,
        retention,
    );
    try validateLossDispatchReconciliationPlanReplayV1(
        plan,
        plan,
    );

    var forbidden_retention = retention;
    forbidden_retention.output_authority_sha256 =
        testDigest("forbidden reconciliation output");
    forbidden_retention.retention_sha256 =
        lossDispatchRetentionRootV1(forbidden_retention);
    try std.testing.expectError(
        Error.InvalidLossDispatchRetention,
        validateLossDispatchRetentionV1(
            forbidden_retention,
            harness.fixture.inventory[0],
            lease,
            pin,
        ),
    );

    var replay_retention = retention;
    replay_retention.adapter_challenge_sha256 =
        testDigest("changed reconciliation challenge");
    replay_retention.retention_sha256 =
        lossDispatchRetentionRootV1(replay_retention);
    try validateLossDispatchRetentionV1(
        replay_retention,
        harness.fixture.inventory[0],
        lease,
        pin,
    );
    try std.testing.expectError(
        Error.InvalidLossDispatchRetention,
        validateLossDispatchRetentionReplayV1(
            replay_retention,
            retention,
        ),
    );

    var changed_selection = harness.fixture.selection;
    changed_selection.selected_policy_rank += 1;
    changed_selection.receipt_sha256 =
        device.selectionReceiptRootV1(changed_selection);
    try std.testing.expectError(
        Error.InvalidLossDispatchReconciliationPlan,
        validateLossDispatchReconciliationPlanV1(
            plan,
            loss.observation,
            loss.transition,
            loss.cursor,
            harness.fixture.requirement,
            changed_selection,
            &harness.fixture.inventory,
            harness.fixture.inventory[0],
            loss.successor,
            retention,
            lease,
            pin,
        ),
    );

    var changed_plan = plan;
    changed_plan.reconciliation_generation += 1;
    changed_plan.plan_sha256 =
        lossDispatchReconciliationPlanRootV1(changed_plan);
    try validateTestPlan(
        &harness,
        changed_plan,
        retention,
        lease,
        pin,
        loss,
    );
    try std.testing.expectError(
        Error.InvalidLossDispatchReconciliationPlan,
        validateLossDispatchReconciliationPlanReplayV1(
            changed_plan,
            plan,
        ),
    );

    const terminal = try allocation_tree.makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        submission,
        testDigest("dispatch reconciliation replay terminal"),
        zero_digest,
    );
    dispatch.expect(terminal);
    const completion =
        try harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        );
    const receipt = try makeLossDispatchReconciliationReceiptV1(
        plan,
        retention,
        harness.fixture.inventory[0],
        lease,
        pin,
        terminal,
        completion,
        testDigest("dispatch reconciliation replay settlement"),
    );
    try validateLossDispatchReconciliationReceiptReplayV1(
        receipt,
        receipt,
    );

    var forged_receipt_plan = plan;
    forged_receipt_plan.successor_state = .present;
    forged_receipt_plan.plan_sha256 =
        lossDispatchReconciliationPlanRootV1(
            forged_receipt_plan,
        );
    try std.testing.expectError(
        Error.InvalidLossDispatchReconciliationReceipt,
        validateLossDispatchReconciliationReceiptV1(
            receipt,
            forged_receipt_plan,
            retention,
            harness.fixture.inventory[0],
            lease,
            pin,
            terminal,
            completion,
        ),
    );

    var forbidden_receipt = receipt;
    forbidden_receipt.migration_authority_sha256 =
        testDigest("forbidden reconciliation migration");
    forbidden_receipt.receipt_sha256 =
        lossDispatchReconciliationReceiptRootV1(
            forbidden_receipt,
        );
    try std.testing.expectError(
        Error.InvalidLossDispatchReconciliationReceipt,
        validateLossDispatchReconciliationReceiptV1(
            forbidden_receipt,
            plan,
            retention,
            harness.fixture.inventory[0],
            lease,
            pin,
            terminal,
            completion,
        ),
    );

    var replay_receipt = receipt;
    replay_receipt.adapter_settlement_sha256 =
        testDigest("changed reconciliation settlement");
    replay_receipt.receipt_sha256 =
        lossDispatchReconciliationReceiptRootV1(replay_receipt);
    try validateLossDispatchReconciliationReceiptV1(
        replay_receipt,
        plan,
        retention,
        harness.fixture.inventory[0],
        lease,
        pin,
        terminal,
        completion,
    );
    try std.testing.expectError(
        Error.InvalidLossDispatchReconciliationReceipt,
        validateLossDispatchReconciliationReceiptReplayV1(
            replay_receipt,
            receipt,
        ),
    );

    try harness.release(lease);
    try harness.close();
}

test "receipt requires exact terminal failure completion and zero authorities" {
    var harness: TestHarness = .{};
    try harness.init("dispatch reconciliation terminal gpu");
    const lease = try harness.materialize();
    var dispatch: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("dispatch reconciliation terminal request"),
    );
    const loss = try makeTestLoss(
        harness.fixture,
        .command_buffer_device_removed,
        101,
    );
    const submission =
        testDigest("dispatch reconciliation terminal submission");
    const retention = try makeTestRetention(
        &harness,
        lease,
        pin,
        loss,
        submission,
    );
    const plan = try makeTestPlan(
        &harness,
        retention,
        lease,
        pin,
        loss,
    );
    const terminal = try allocation_tree.makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        submission,
        testDigest("dispatch reconciliation terminal backend"),
        zero_digest,
    );
    dispatch.expect(terminal);
    const completion =
        try harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        );
    const settlement =
        testDigest("dispatch reconciliation terminal settlement");
    const receipt = try makeLossDispatchReconciliationReceiptV1(
        plan,
        retention,
        harness.fixture.inventory[0],
        lease,
        pin,
        terminal,
        completion,
        settlement,
    );
    try validateLossDispatchReconciliationReceiptV1(
        receipt,
        plan,
        retention,
        harness.fixture.inventory[0],
        lease,
        pin,
        terminal,
        completion,
    );

    try std.testing.expectError(
        Error.InvalidLossDispatchReconciliationReceipt,
        makeLossDispatchReconciliationReceiptV1(
            plan,
            retention,
            harness.fixture.inventory[0],
            lease,
            pin,
            terminal,
            completion,
            zero_digest,
        ),
    );

    var wrong_count = receipt;
    wrong_count.released_dispatch_pin_count = 2;
    wrong_count.receipt_sha256 =
        lossDispatchReconciliationReceiptRootV1(wrong_count);
    try std.testing.expectError(
        Error.InvalidLossDispatchReconciliationReceipt,
        validateLossDispatchReconciliationReceiptV1(
            wrong_count,
            plan,
            retention,
            harness.fixture.inventory[0],
            lease,
            pin,
            terminal,
            completion,
        ),
    );

    try harness.release(lease);
    try harness.close();
}
