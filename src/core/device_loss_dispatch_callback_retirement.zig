//! Portable evidence for callback-detached dispatch retirement after device
//! loss.
//!
//! This contract covers one exact live dispatch whose native state is still
//! pending, submission-ambiguous, completion-unknown, or invalid-completion.
//! A detached fence proves that the native completion callback can no longer
//! mutate the command record while that record remains retained for private
//! post-Bank settlement. Callback exit is diagnostic only and is not a
//! prerequisite for the fence.
//!
//! These values are checksummed composition evidence, not runtime authority.
//! They cannot publish output, consume a Bank permit, retire a native record,
//! release an allocation, reclaim physical memory, reset or migrate a device,
//! or invoke an adapter.

const std = @import("std");
const device = @import("device_capability_contract.zig");
const lifecycle = @import("device_lifecycle_contract.zig");
const allocation = @import("device_allocation_lease.zig");
const allocation_tree = @import("device_allocation_lease_tree.zig");
const resource = @import("resource_bank.zig");

pub const Digest = device.Digest;
pub const zero_digest = device.zero_digest;

pub const retention_abi: u64 = 0x4744_4354_0000_0001;
pub const plan_abi: u64 = 0x4744_4350_0000_0001;
pub const fence_abi: u64 = 0x4744_4346_0000_0001;
pub const receipt_abi: u64 = 0x4744_4352_0000_0001;

pub const native_command_status_unobserved: u64 =
    std.math.maxInt(u64);
pub const native_command_status_completed: u64 = 4;
pub const submission_ambiguous_error_code: u64 = 1;

const retention_domain =
    "glacier-device-loss-dispatch-callback-retention-v1\x00";
const plan_domain =
    "glacier-device-loss-dispatch-callback-retirement-plan-v1\x00";
const fence_domain =
    "glacier-device-loss-dispatch-callback-fence-v1\x00";
const receipt_domain =
    "glacier-device-loss-dispatch-callback-retirement-receipt-v1\x00";

pub const LossDispatchCallbackRetainedStateV1 = enum(u64) {
    pending = 1,
    submission_ambiguous = 2,
    completion_unknown = 3,
    invalid_completion = 4,
    _,
};

pub const LossDispatchCallbackNativeDispositionV1 = enum(u64) {
    commit_started = 1,
    submitted = 2,
    terminal_status_observed = 3,
    _,
};

pub const LossDispatchCallbackErrorDomainKindV1 = enum(u64) {
    none = 0,
    native_bridge = 1,
    completion_validation = 2,
    command_buffer = 3,
    native_other = 4,
    _,
};

pub const LossDispatchCallbackFenceStateV1 = enum(u64) {
    detached_pending_settlement = 1,
    _,
};

pub const Error = error{
    InvalidLossDispatchCallbackRetention,
    InvalidLossDispatchCallbackRetirementPlan,
    ProductionEvidenceRequired,
    InvalidLossDispatchCallbackFence,
    InvalidLossDispatchCallbackRetirementReceipt,
};

/// Pointer-free retention for one exact live dispatch and its current
/// nonterminal native classification. Pending has no quarantine root; every
/// sticky quarantine classification requires one.
pub const LossDispatchCallbackRetentionV1 = struct {
    abi_version: u64 = retention_abi,
    retained_state: LossDispatchCallbackRetainedStateV1 = .pending,
    dispatch_generation: u64 = 0,
    allocation_count: u64 = 0,
    pinned_device_bytes: u64 = 0,
    native_disposition: LossDispatchCallbackNativeDispositionV1 =
        .submitted,
    native_command_status: u64 = 0,
    native_completion_observed: u64 = 0,
    native_error_domain_kind: LossDispatchCallbackErrorDomainKindV1 = .none,
    native_error_code_bits: u64 = 0,
    selected_capability_sha256: Digest = zero_digest,
    allocation_lease_sha256: Digest = zero_digest,
    allocation_leaf_set_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    dispatch_pin_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    async_ticket_sha256: Digest = zero_digest,
    submission_sha256: Digest = zero_digest,
    backend_quarantine_sha256: Digest = zero_digest,
    adapter_challenge_sha256: Digest = zero_digest,
    output_authority_sha256: Digest = zero_digest,
    retention_sha256: Digest = zero_digest,
};

/// Immutable proposal joining retained nonterminal ownership to one exact
/// canonical `present -> lost` lifecycle transition.
pub const LossDispatchCallbackRetirementPlanV1 = struct {
    abi_version: u64 = plan_abi,
    source: lifecycle.ObservationSourceV1 =
        .removed_notification,
    evidence_class: lifecycle.EvidenceClassV1 = .native,
    successor_state: device.InventoryStateV1 = .lost,
    source_sequence: u64 = 0,
    retirement_generation: u64 = 0,
    source_instance_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
    transition_receipt_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    retention_sha256: Digest = zero_digest,
    plan_sha256: Digest = zero_digest,
};

/// Adapter composition evidence that the exact callback is detached while
/// the exact native command record remains retained for private post-Bank
/// settlement. `native_completion_observed` and its optional snapshot are
/// diagnostic only and need not prove callback quiescence.
pub const LossDispatchCallbackFenceV1 = struct {
    abi_version: u64 = fence_abi,
    state: LossDispatchCallbackFenceStateV1 =
        .detached_pending_settlement,
    retained_state: LossDispatchCallbackRetainedStateV1 = .pending,
    retirement_generation: u64 = 0,
    native_retirement_generation: u64 = 0,
    native_completion_observed: u64 = 0,
    native_callback_detached: u64 = 0,
    native_record_retained: u64 = 0,
    native_command_status: u64 = 0,
    native_error_domain_kind: LossDispatchCallbackErrorDomainKindV1 = .none,
    native_error_code_bits: u64 = 0,
    plan_sha256: Digest = zero_digest,
    retention_sha256: Digest = zero_digest,
    async_ticket_sha256: Digest = zero_digest,
    submission_sha256: Digest = zero_digest,
    backend_quarantine_sha256: Digest = zero_digest,
    native_prepare_sha256: Digest = zero_digest,
    callback_snapshot_sha256: Digest = zero_digest,
    backend_terminal_sha256: Digest = zero_digest,
    output_authority_sha256: Digest = zero_digest,
    fence_sha256: Digest = zero_digest,
};

/// Immutable composition receipt for one callback-detached ownership
/// retirement. Allocation retirement remains a separate operation.
pub const LossDispatchCallbackRetirementReceiptV1 = struct {
    abi_version: u64 = receipt_abi,
    source: lifecycle.ObservationSourceV1 =
        .removed_notification,
    evidence_class: lifecycle.EvidenceClassV1 = .native,
    outcome: allocation_tree.DispatchTerminalOutcomeV1 =
        .ownership_retired_after_device_loss,
    retained_state: LossDispatchCallbackRetainedStateV1 = .pending,
    source_sequence: u64 = 0,
    retirement_generation: u64 = 0,
    native_retirement_generation: u64 = 0,
    released_dispatch_pin_count: u64 = 0,
    retired_native_command_count: u64 = 0,
    detached_native_callback_count: u64 = 0,
    plan_sha256: Digest = zero_digest,
    retention_sha256: Digest = zero_digest,
    callback_fence_sha256: Digest = zero_digest,
    dispatch_terminal_sha256: Digest = zero_digest,
    dispatch_completion_sha256: Digest = zero_digest,
    bank_completion_sha256: Digest = zero_digest,
    native_retirement_sha256: Digest = zero_digest,
    adapter_settlement_sha256: Digest = zero_digest,
    output_authority_sha256: Digest = zero_digest,
    migration_authority_sha256: Digest = zero_digest,
    reset_authority_sha256: Digest = zero_digest,
    physical_reclaim_authority_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

comptime {
    if (@sizeOf(LossDispatchCallbackRetentionV1) != 464)
        @compileError(
            "LossDispatchCallbackRetentionV1 layout changed",
        );
    if (@sizeOf(LossDispatchCallbackRetirementPlanV1) != 240)
        @compileError(
            "LossDispatchCallbackRetirementPlanV1 layout changed",
        );
    if (@sizeOf(LossDispatchCallbackFenceV1) != 408)
        @compileError(
            "LossDispatchCallbackFenceV1 layout changed",
        );
    if (@sizeOf(LossDispatchCallbackRetirementReceiptV1) != 504)
        @compileError(
            "LossDispatchCallbackRetirementReceiptV1 layout changed",
        );
}

pub fn makeLossDispatchCallbackRetentionV1(
    retained_state: LossDispatchCallbackRetainedStateV1,
    native_disposition: LossDispatchCallbackNativeDispositionV1,
    native_command_status: u64,
    native_completion_observed: u64,
    native_error_domain_kind: LossDispatchCallbackErrorDomainKindV1,
    native_error_code_bits: u64,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    async_ticket_sha256: Digest,
    submission_sha256: Digest,
    backend_quarantine_sha256: Digest,
    adapter_challenge_sha256: Digest,
) Error!LossDispatchCallbackRetentionV1 {
    var result: LossDispatchCallbackRetentionV1 = .{
        .retained_state = retained_state,
        .dispatch_generation = pin.dispatch_generation,
        .allocation_count = pin.allocation_count,
        .pinned_device_bytes = pin.pinned_device_bytes,
        .native_disposition = native_disposition,
        .native_command_status = native_command_status,
        .native_completion_observed = native_completion_observed,
        .native_error_domain_kind = native_error_domain_kind,
        .native_error_code_bits = native_error_code_bits,
        .selected_capability_sha256 = selected_entry.capability.capability_sha256,
        .allocation_lease_sha256 = lease.lease_sha256,
        .allocation_leaf_set_sha256 = lease.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = lease.backend_object_set_sha256,
        .dispatch_pin_sha256 = pin.pin_sha256,
        .dispatch_request_sha256 = pin.dispatch_request_sha256,
        .async_ticket_sha256 = async_ticket_sha256,
        .submission_sha256 = submission_sha256,
        .backend_quarantine_sha256 = backend_quarantine_sha256,
        .adapter_challenge_sha256 = adapter_challenge_sha256,
    };
    result.retention_sha256 =
        lossDispatchCallbackRetentionRootV1(result);
    try validateLossDispatchCallbackRetentionV1(
        result,
        selected_entry,
        lease,
        pin,
    );
    return result;
}

pub fn validateLossDispatchCallbackRetentionV1(
    value: LossDispatchCallbackRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
) Error!void {
    device.validateInventoryEntryV1(selected_entry) catch
        return Error.InvalidLossDispatchCallbackRetention;
    allocation_tree.validateLeaseV1(lease) catch
        return Error.InvalidLossDispatchCallbackRetention;
    allocation_tree.validateDispatchPinV1(pin) catch
        return Error.InvalidLossDispatchCallbackRetention;

    if (selected_entry.state != .present or
        !retentionShapeValidV1(value) or
        value.dispatch_generation != pin.dispatch_generation or
        value.allocation_count != pin.allocation_count or
        value.allocation_count != lease.allocation_count or
        value.pinned_device_bytes != pin.pinned_device_bytes or
        value.pinned_device_bytes != lease.materialized_bytes or
        lease.coordinator_epoch != pin.coordinator_epoch or
        lease.generation != pin.allocation_generation or
        !digestEqual(lease.authority_sha256, pin.authority_sha256) or
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
        ))
        return Error.InvalidLossDispatchCallbackRetention;
}

fn retentionShapeValidV1(
    value: LossDispatchCallbackRetentionV1,
) bool {
    return value.abi_version == retention_abi and
        value.dispatch_generation != 0 and
        value.dispatch_generation != std.math.maxInt(u64) and
        value.allocation_count != 0 and
        value.pinned_device_bytes >= value.allocation_count and
        nativeRetentionShapeValidV1(value) and
        !digestIsZero(value.selected_capability_sha256) and
        !digestIsZero(value.allocation_lease_sha256) and
        !digestIsZero(value.allocation_leaf_set_sha256) and
        !digestIsZero(value.backend_object_set_sha256) and
        !digestIsZero(value.dispatch_pin_sha256) and
        !digestIsZero(value.dispatch_request_sha256) and
        !digestIsZero(value.async_ticket_sha256) and
        !digestIsZero(value.submission_sha256) and
        !digestIsZero(value.adapter_challenge_sha256) and
        digestEqual(value.output_authority_sha256, zero_digest) and
        !digestIsZero(value.retention_sha256) and
        digestEqual(
            value.retention_sha256,
            lossDispatchCallbackRetentionRootV1(value),
        );
}

fn nativeRetentionShapeValidV1(
    value: LossDispatchCallbackRetentionV1,
) bool {
    if (value.native_completion_observed > 1)
        return false;
    return switch (value.retained_state) {
        .pending => value.native_disposition == .submitted and
            value.native_command_status == 0 and
            value.native_completion_observed == 0 and
            value.native_error_domain_kind == .none and
            value.native_error_code_bits == 0 and
            digestIsZero(value.backend_quarantine_sha256),
        .submission_ambiguous => value.native_disposition ==
            .commit_started and
            value.native_command_status ==
                native_command_status_unobserved and
            value.native_completion_observed == 0 and
            value.native_error_domain_kind == .native_bridge and
            value.native_error_code_bits ==
                submission_ambiguous_error_code and
            !digestIsZero(value.backend_quarantine_sha256),
        .completion_unknown => value.native_disposition ==
            .submitted and
            value.native_error_domain_kind == .native_bridge and
            value.native_error_code_bits != 0 and
            !digestIsZero(value.backend_quarantine_sha256),
        .invalid_completion => value.native_disposition ==
            .terminal_status_observed and
            value.native_command_status ==
                native_command_status_completed and
            value.native_completion_observed == 1 and
            value.native_error_domain_kind ==
                .completion_validation and
            value.native_error_code_bits != 0 and
            !digestIsZero(value.backend_quarantine_sha256),
        _ => false,
    };
}

pub fn lossDispatchCallbackRetentionRootV1(
    value: LossDispatchCallbackRetentionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(retention_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.retained_state));
    hashU64(&hash, value.dispatch_generation);
    hashU64(&hash, value.allocation_count);
    hashU64(&hash, value.pinned_device_bytes);
    hashU64(&hash, @intFromEnum(value.native_disposition));
    hashU64(&hash, value.native_command_status);
    hashU64(&hash, value.native_completion_observed);
    hashU64(&hash, @intFromEnum(value.native_error_domain_kind));
    hashU64(&hash, value.native_error_code_bits);
    hash.update(&value.selected_capability_sha256);
    hash.update(&value.allocation_lease_sha256);
    hash.update(&value.allocation_leaf_set_sha256);
    hash.update(&value.backend_object_set_sha256);
    hash.update(&value.dispatch_pin_sha256);
    hash.update(&value.dispatch_request_sha256);
    hash.update(&value.async_ticket_sha256);
    hash.update(&value.submission_sha256);
    hash.update(&value.backend_quarantine_sha256);
    hash.update(&value.adapter_challenge_sha256);
    hash.update(&value.output_authority_sha256);
    return finish(&hash);
}

pub fn validateLossDispatchCallbackRetentionReplayV1(
    candidate: LossDispatchCallbackRetentionV1,
    retained: LossDispatchCallbackRetentionV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossDispatchCallbackRetention;
}

pub fn makeLossDispatchCallbackRetirementPlanV1(
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    retention: LossDispatchCallbackRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    retirement_generation: u64,
) Error!LossDispatchCallbackRetirementPlanV1 {
    var result: LossDispatchCallbackRetirementPlanV1 = .{
        .source = observation.source,
        .evidence_class = observation.evidence_class,
        .successor_state = transition.successor_state,
        .source_sequence = observation.source_sequence,
        .retirement_generation = retirement_generation,
        .source_instance_sha256 = observation.source_instance_sha256,
        .observation_sha256 = observation.observation_sha256,
        .transition_receipt_sha256 = transition.receipt_sha256,
        .selected_capability_sha256 = selected_entry.capability.capability_sha256,
        .retention_sha256 = retention.retention_sha256,
    };
    result.plan_sha256 =
        lossDispatchCallbackRetirementPlanRootV1(result);
    try validateLossDispatchCallbackRetirementPlanV1(
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

pub fn validateLossDispatchCallbackRetirementPlanV1(
    value: LossDispatchCallbackRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    retention: LossDispatchCallbackRetentionV1,
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
    ) catch return Error.InvalidLossDispatchCallbackRetirementPlan;
    device.validateRequirementV1(requirement) catch
        return Error.InvalidLossDispatchCallbackRetirementPlan;
    device.validateSelectionReceiptV1(
        selection,
        requirement,
        prior_inventory,
    ) catch return Error.InvalidLossDispatchCallbackRetirementPlan;
    validateLossDispatchCallbackRetentionV1(
        retention,
        selected_entry,
        lease,
        pin,
    ) catch return Error.InvalidLossDispatchCallbackRetirementPlan;

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
            value.selected_capability_sha256,
            retention.selected_capability_sha256,
        ) or
        value.abi_version != plan_abi or
        value.source != observation.source or
        value.evidence_class != observation.evidence_class or
        value.successor_state != .lost or
        value.successor_state != transition.successor_state or
        value.source_sequence != observation.source_sequence or
        value.source_sequence != transition.source_sequence or
        value.retirement_generation == 0 or
        value.retirement_generation == std.math.maxInt(u64) or
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
            lossDispatchCallbackRetirementPlanRootV1(value),
        ))
        return Error.InvalidLossDispatchCallbackRetirementPlan;
}

pub fn lossDispatchCallbackRetirementPlanProductionEligibleV1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) bool {
    const native_loss_source =
        plan.source == .removed_notification or
        plan.source == .command_buffer_device_removed;
    return planShapeBoundToRetentionValidV1(plan, retention) and
        native_loss_source and
        plan.source == observation.source and
        plan.source == transition.source and
        plan.evidence_class == .native and
        retentionShapeValidV1(retention) and
        observation.evidence_class == .native and
        transition.evidence_class == .native and
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
        digestEqual(
            plan.observation_sha256,
            observation.observation_sha256,
        ) and
        digestEqual(
            observation.observation_sha256,
            lifecycle.observationRootV1(observation),
        ) and
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
        );
}

pub fn requireProductionEligibleLossDispatchCallbackRetirementPlanV1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
) Error!void {
    if (!lossDispatchCallbackRetirementPlanProductionEligibleV1(
        plan,
        retention,
        observation,
        transition,
    ))
        return Error.ProductionEvidenceRequired;
}

pub fn lossDispatchCallbackRetirementPlanRootV1(
    value: LossDispatchCallbackRetirementPlanV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, @intFromEnum(value.successor_state));
    hashU64(&hash, value.source_sequence);
    hashU64(&hash, value.retirement_generation);
    hash.update(&value.source_instance_sha256);
    hash.update(&value.observation_sha256);
    hash.update(&value.transition_receipt_sha256);
    hash.update(&value.selected_capability_sha256);
    hash.update(&value.retention_sha256);
    return finish(&hash);
}

pub fn validateLossDispatchCallbackRetirementPlanReplayV1(
    candidate: LossDispatchCallbackRetirementPlanV1,
    retained: LossDispatchCallbackRetirementPlanV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossDispatchCallbackRetirementPlan;
}

pub fn makeLossDispatchCallbackFenceV1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    native_retirement_generation: u64,
    native_prepare_sha256: Digest,
    backend_terminal_sha256: Digest,
    native_completion_observed: u64,
    native_command_status: u64,
    native_error_domain_kind: LossDispatchCallbackErrorDomainKindV1,
    native_error_code_bits: u64,
    callback_snapshot_sha256: Digest,
) Error!LossDispatchCallbackFenceV1 {
    var result: LossDispatchCallbackFenceV1 = .{
        .retained_state = retention.retained_state,
        .retirement_generation = plan.retirement_generation,
        .native_retirement_generation = native_retirement_generation,
        .native_completion_observed = native_completion_observed,
        .native_callback_detached = 1,
        .native_record_retained = 1,
        .native_command_status = native_command_status,
        .native_error_domain_kind = native_error_domain_kind,
        .native_error_code_bits = native_error_code_bits,
        .plan_sha256 = plan.plan_sha256,
        .retention_sha256 = retention.retention_sha256,
        .async_ticket_sha256 = retention.async_ticket_sha256,
        .submission_sha256 = retention.submission_sha256,
        .backend_quarantine_sha256 = retention.backend_quarantine_sha256,
        .native_prepare_sha256 = native_prepare_sha256,
        .callback_snapshot_sha256 = callback_snapshot_sha256,
        .backend_terminal_sha256 = backend_terminal_sha256,
    };
    result.fence_sha256 = lossDispatchCallbackFenceRootV1(result);
    try validateLossDispatchCallbackFenceV1(
        result,
        plan,
        retention,
    );
    return result;
}

pub fn validateLossDispatchCallbackFenceV1(
    value: LossDispatchCallbackFenceV1,
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
) Error!void {
    if (!planShapeBoundToRetentionValidV1(plan, retention) or
        value.abi_version != fence_abi or
        value.state != .detached_pending_settlement or
        value.retained_state != retention.retained_state or
        value.retirement_generation !=
            plan.retirement_generation or
        value.native_retirement_generation == 0 or
        value.native_retirement_generation == std.math.maxInt(u64) or
        value.native_completion_observed > 1 or
        value.native_callback_detached != 1 or
        value.native_record_retained != 1 or
        !nativeFenceDiagnosticShapeValidV1(value) or
        !digestEqual(value.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            value.retention_sha256,
            retention.retention_sha256,
        ) or
        !digestEqual(
            value.async_ticket_sha256,
            retention.async_ticket_sha256,
        ) or
        !digestEqual(
            value.submission_sha256,
            retention.submission_sha256,
        ) or
        !digestEqual(
            value.backend_quarantine_sha256,
            retention.backend_quarantine_sha256,
        ) or
        digestIsZero(value.native_prepare_sha256) or
        digestIsZero(value.backend_terminal_sha256) or
        !digestEqual(value.output_authority_sha256, zero_digest) or
        digestIsZero(value.fence_sha256) or
        !digestEqual(
            value.fence_sha256,
            lossDispatchCallbackFenceRootV1(value),
        ))
        return Error.InvalidLossDispatchCallbackFence;
}

fn nativeFenceDiagnosticShapeValidV1(
    value: LossDispatchCallbackFenceV1,
) bool {
    if (value.native_completion_observed == 0)
        return value.native_command_status == 0 and
            value.native_error_domain_kind == .none and
            value.native_error_code_bits == 0 and
            digestIsZero(value.callback_snapshot_sha256);
    if (value.native_completion_observed != 1 or
        digestIsZero(value.callback_snapshot_sha256))
        return false;
    return switch (value.native_error_domain_kind) {
        .none => value.native_error_code_bits == 0,
        .native_bridge,
        .completion_validation,
        .command_buffer,
        .native_other,
        => value.native_error_code_bits != 0,
        _ => false,
    };
}

pub fn lossDispatchCallbackFenceRootV1(
    value: LossDispatchCallbackFenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(fence_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.state));
    hashU64(&hash, @intFromEnum(value.retained_state));
    hashU64(&hash, value.retirement_generation);
    hashU64(&hash, value.native_retirement_generation);
    hashU64(&hash, value.native_completion_observed);
    hashU64(&hash, value.native_callback_detached);
    hashU64(&hash, value.native_record_retained);
    hashU64(&hash, value.native_command_status);
    hashU64(&hash, @intFromEnum(value.native_error_domain_kind));
    hashU64(&hash, value.native_error_code_bits);
    hash.update(&value.plan_sha256);
    hash.update(&value.retention_sha256);
    hash.update(&value.async_ticket_sha256);
    hash.update(&value.submission_sha256);
    hash.update(&value.backend_quarantine_sha256);
    hash.update(&value.native_prepare_sha256);
    hash.update(&value.callback_snapshot_sha256);
    hash.update(&value.backend_terminal_sha256);
    hash.update(&value.output_authority_sha256);
    return finish(&hash);
}

pub fn validateLossDispatchCallbackFenceReplayV1(
    candidate: LossDispatchCallbackFenceV1,
    retained: LossDispatchCallbackFenceV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossDispatchCallbackFence;
}

pub fn makeLossDispatchCallbackRetirementReceiptV1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    fence: LossDispatchCallbackFenceV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    terminal: allocation_tree.DispatchTerminalEvidenceV1,
    completion: allocation_tree.LeaseTreeDispatchCompletionV1,
    native_retirement_sha256: Digest,
    adapter_settlement_sha256: Digest,
) Error!LossDispatchCallbackRetirementReceiptV1 {
    var result: LossDispatchCallbackRetirementReceiptV1 = .{
        .source = plan.source,
        .evidence_class = plan.evidence_class,
        .retained_state = retention.retained_state,
        .source_sequence = plan.source_sequence,
        .retirement_generation = plan.retirement_generation,
        .native_retirement_generation = fence.native_retirement_generation,
        .released_dispatch_pin_count = 1,
        .retired_native_command_count = 1,
        .detached_native_callback_count = 1,
        .plan_sha256 = plan.plan_sha256,
        .retention_sha256 = retention.retention_sha256,
        .callback_fence_sha256 = fence.fence_sha256,
        .dispatch_terminal_sha256 = terminal.terminal_sha256,
        .dispatch_completion_sha256 = completion.completion_sha256,
        .bank_completion_sha256 = completion.bank_completion_sha256,
        .native_retirement_sha256 = native_retirement_sha256,
        .adapter_settlement_sha256 = adapter_settlement_sha256,
    };
    result.receipt_sha256 =
        lossDispatchCallbackRetirementReceiptRootV1(result);
    try validateLossDispatchCallbackRetirementReceiptV1(
        result,
        plan,
        retention,
        fence,
        selected_entry,
        lease,
        pin,
        terminal,
        completion,
    );
    return result;
}

pub fn validateLossDispatchCallbackRetirementReceiptV1(
    value: LossDispatchCallbackRetirementReceiptV1,
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
    fence: LossDispatchCallbackFenceV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    terminal: allocation_tree.DispatchTerminalEvidenceV1,
    completion: allocation_tree.LeaseTreeDispatchCompletionV1,
) Error!void {
    validateLossDispatchCallbackRetentionV1(
        retention,
        selected_entry,
        lease,
        pin,
    ) catch return Error.InvalidLossDispatchCallbackRetirementReceipt;
    validateLossDispatchCallbackFenceV1(
        fence,
        plan,
        retention,
    ) catch return Error.InvalidLossDispatchCallbackRetirementReceipt;
    allocation_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    ) catch return Error.InvalidLossDispatchCallbackRetirementReceipt;
    allocation_tree.validateDispatchCompletionForPinV1(
        completion,
        pin,
        terminal,
    ) catch return Error.InvalidLossDispatchCallbackRetirementReceipt;

    if (terminal.outcome !=
        .ownership_retired_after_device_loss or
        completion.outcome !=
            .ownership_retired_after_device_loss or
        !digestEqual(
            terminal.submission_sha256,
            retention.submission_sha256,
        ) or
        !digestEqual(
            terminal.backend_completion_sha256,
            fence.backend_terminal_sha256,
        ) or
        !digestEqual(terminal.output_sha256, zero_digest) or
        !digestEqual(completion.output_sha256, zero_digest) or
        value.abi_version != receipt_abi or
        value.source != plan.source or
        value.evidence_class != plan.evidence_class or
        value.retained_state != retention.retained_state or
        value.outcome != .ownership_retired_after_device_loss or
        value.source_sequence != plan.source_sequence or
        value.retirement_generation !=
            plan.retirement_generation or
        value.native_retirement_generation !=
            fence.native_retirement_generation or
        value.released_dispatch_pin_count != 1 or
        value.retired_native_command_count != 1 or
        value.detached_native_callback_count != 1 or
        !digestEqual(value.plan_sha256, plan.plan_sha256) or
        !digestEqual(
            value.retention_sha256,
            retention.retention_sha256,
        ) or
        !digestEqual(
            value.callback_fence_sha256,
            fence.fence_sha256,
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
        digestIsZero(value.native_retirement_sha256) or
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
            lossDispatchCallbackRetirementReceiptRootV1(value),
        ))
        return Error.InvalidLossDispatchCallbackRetirementReceipt;
}

pub fn lossDispatchCallbackRetirementReceiptRootV1(
    value: LossDispatchCallbackRetirementReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.source));
    hashU64(&hash, @intFromEnum(value.evidence_class));
    hashU64(&hash, @intFromEnum(value.outcome));
    hashU64(&hash, @intFromEnum(value.retained_state));
    hashU64(&hash, value.source_sequence);
    hashU64(&hash, value.retirement_generation);
    hashU64(&hash, value.native_retirement_generation);
    hashU64(&hash, value.released_dispatch_pin_count);
    hashU64(&hash, value.retired_native_command_count);
    hashU64(&hash, value.detached_native_callback_count);
    hash.update(&value.plan_sha256);
    hash.update(&value.retention_sha256);
    hash.update(&value.callback_fence_sha256);
    hash.update(&value.dispatch_terminal_sha256);
    hash.update(&value.dispatch_completion_sha256);
    hash.update(&value.bank_completion_sha256);
    hash.update(&value.native_retirement_sha256);
    hash.update(&value.adapter_settlement_sha256);
    hash.update(&value.output_authority_sha256);
    hash.update(&value.migration_authority_sha256);
    hash.update(&value.reset_authority_sha256);
    hash.update(&value.physical_reclaim_authority_sha256);
    return finish(&hash);
}

pub fn validateLossDispatchCallbackRetirementReceiptReplayV1(
    candidate: LossDispatchCallbackRetirementReceiptV1,
    retained: LossDispatchCallbackRetirementReceiptV1,
) Error!void {
    if (!std.meta.eql(candidate, retained))
        return Error.InvalidLossDispatchCallbackRetirementReceipt;
}

fn sourceEvidencePairValidV1(
    source: lifecycle.ObservationSourceV1,
    evidence_class: lifecycle.EvidenceClassV1,
) bool {
    return switch (source) {
        .removed_notification,
        .command_buffer_device_removed,
        => evidence_class == .native,
        .test_injected => evidence_class == .synthetic,
        else => false,
    };
}

fn planShapeBoundToRetentionValidV1(
    plan: LossDispatchCallbackRetirementPlanV1,
    retention: LossDispatchCallbackRetentionV1,
) bool {
    return plan.abi_version == plan_abi and
        sourceEvidencePairValidV1(
            plan.source,
            plan.evidence_class,
        ) and
        plan.successor_state == .lost and
        plan.source_sequence != 0 and
        plan.retirement_generation != 0 and
        plan.retirement_generation != std.math.maxInt(u64) and
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
        retentionShapeValidV1(retention) and
        !digestIsZero(plan.plan_sha256) and
        digestEqual(
            plan.plan_sha256,
            lossDispatchCallbackRetirementPlanRootV1(plan),
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

const test_request_epoch: u64 = 0x4342_5245;
const test_session_id: usize = 0x5449_5245;

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
            59,
        );
        self.parent = try self.bank.commit(
            try self.bank.reserve(
                8_901,
                .{
                    .capsule_bytes = 64,
                    .queue_slots = 1,
                },
            ),
        );
        const opened = try self.bank.openLeaseTree(
            self.parent,
            0x6362_7265_7472_6565,
            0x6362_7265_6175_7468,
            .{
                .device_bytes = self.fixture.manifest.total_charged_bytes,
            },
        );
        const scoped = try self.bank.openLeaseScope(
            opened,
            0x6362_7265_7363_6f70,
            0x6362_7265_7465_6e61,
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
            0x4342_5245_434f_4f52,
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
            testDigest("callback retirement request owner"),
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
        return switch (try self.coordinator.materialize(
            admission,
            self.backend.adapter(),
            .{},
        )) {
            .active => |lease| lease,
            else => error.TestExpectedActiveLease,
        };
    }

    fn release(
        self: *@This(),
        lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    ) !void {
        _ = switch (try self.coordinator.release(
            lease,
            self.backend.adapter(),
        )) {
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
            .dispatch_authority_sha256 = testDigest("callback retirement dispatch authority"),
            .queue_authority_sha256 = testDigest("callback retirement queue authority"),
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
        .backend_sha256 = testDigest("callback retirement backend"),
        .device_sha256 = testDigest(label),
        .driver_sha256 = testDigest("callback retirement driver"),
        .placement_sha256 = testDigest("callback retirement placement"),
    });
    const inventory = [1]device.DeviceInventoryEntryV1{
        try device.sealInventoryEntryV1(.{
            .discovery_epoch = 31,
            .policy_rank = 2,
            .state = .present,
            .capability = capability,
        }),
    };
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = testDigest("callback retirement execution plan"),
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
        41,
        1,
        1,
        1_024,
        inventory[selection.selected_index],
        testDigest("callback retirement adapter authority"),
    );
    const quote = try allocation.makeFakeQuoteV1(
        authority,
        testDigest("callback retirement buffer"),
        4_000,
    );
    const entries = [1]allocation.AllocationEntryV1{.{
        .binding_sha256 = testDigest("callback retirement buffer"),
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
        .source_instance_sha256 = testDigest("callback retirement source instance"),
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
        testDigest("callback retirement lifecycle evidence"),
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
    state: LossDispatchCallbackRetainedStateV1,
) !LossDispatchCallbackRetentionV1 {
    const shape: struct {
        disposition: LossDispatchCallbackNativeDispositionV1,
        status: u64,
        observed: u64,
        domain: LossDispatchCallbackErrorDomainKindV1,
        code: u64,
        quarantine: Digest,
    } = switch (state) {
        .pending => .{
            .disposition = .submitted,
            .status = 0,
            .observed = 0,
            .domain = .none,
            .code = 0,
            .quarantine = zero_digest,
        },
        .submission_ambiguous => .{
            .disposition = .commit_started,
            .status = native_command_status_unobserved,
            .observed = 0,
            .domain = .native_bridge,
            .code = submission_ambiguous_error_code,
            .quarantine = testDigest("callback retirement ambiguous"),
        },
        .completion_unknown => .{
            .disposition = .submitted,
            .status = lifecycle.command_buffer_status_error,
            .observed = 1,
            .domain = .native_bridge,
            .code = 17,
            .quarantine = testDigest("callback retirement unknown"),
        },
        .invalid_completion => .{
            .disposition = .terminal_status_observed,
            .status = native_command_status_completed,
            .observed = 1,
            .domain = .completion_validation,
            .code = 5,
            .quarantine = testDigest("callback retirement invalid"),
        },
        _ => return error.TestInvalidRetainedState,
    };
    return makeLossDispatchCallbackRetentionV1(
        state,
        shape.disposition,
        shape.status,
        shape.observed,
        shape.domain,
        shape.code,
        harness.fixture.inventory[0],
        lease,
        pin,
        testDigest("callback retirement async ticket"),
        testDigest("callback retirement submission"),
        shape.quarantine,
        testDigest("callback retirement adapter challenge"),
    );
}

fn makeTestPlan(
    harness: *TestHarness,
    retention: LossDispatchCallbackRetentionV1,
    lease: allocation_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
    loss: TestLoss,
) !LossDispatchCallbackRetirementPlanV1 {
    return makeLossDispatchCallbackRetirementPlanV1(
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
        19,
    );
}

fn settleForCleanup(
    harness: *TestHarness,
    adapter: *TestDispatchAdapter,
    pin: allocation_tree.LeaseTreeDispatchPinV1,
) !void {
    const terminal = try allocation_tree.makeDispatchTerminalV1(
        pin,
        .cancelled_before_submit,
        zero_digest,
        zero_digest,
        zero_digest,
    );
    adapter.expect(terminal);
    _ = try harness.coordinator.completeDispatchPin(
        pin,
        adapter.interface(),
        terminal,
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

test "callback retirement values have literal layouts and no pointers" {
    try std.testing.expectEqual(
        @as(u64, 0x4744_4354_0000_0001),
        retention_abi,
    );
    try std.testing.expectEqual(
        @as(u64, 0x4744_4350_0000_0001),
        plan_abi,
    );
    try std.testing.expectEqual(
        @as(u64, 0x4744_4346_0000_0001),
        fence_abi,
    );
    try std.testing.expectEqual(
        @as(u64, 0x4744_4352_0000_0001),
        receipt_abi,
    );
    try std.testing.expectEqual(
        @as(usize, 464),
        @sizeOf(LossDispatchCallbackRetentionV1),
    );
    try std.testing.expectEqual(
        @as(usize, 240),
        @sizeOf(LossDispatchCallbackRetirementPlanV1),
    );
    try std.testing.expectEqual(
        @as(usize, 408),
        @sizeOf(LossDispatchCallbackFenceV1),
    );
    try std.testing.expectEqual(
        @as(usize, 504),
        @sizeOf(LossDispatchCallbackRetirementReceiptV1),
    );
    try std.testing.expect(
        !portableTypeHasPointer(LossDispatchCallbackRetentionV1),
    );
    try std.testing.expect(
        !portableTypeHasPointer(
            LossDispatchCallbackRetirementPlanV1,
        ),
    );
    try std.testing.expect(
        !portableTypeHasPointer(LossDispatchCallbackFenceV1),
    );
    try std.testing.expect(
        !portableTypeHasPointer(
            LossDispatchCallbackRetirementReceiptV1,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        @intFromEnum(
            allocation_tree.DispatchTerminalOutcomeV1
                .ownership_retired_after_device_loss,
        ),
    );
}

test "retained native states and production sources fail closed" {
    var harness: TestHarness = .{};
    try harness.init("callback retirement shape device");
    const lease = try harness.materialize();
    var adapter: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        adapter.interface(),
        testDigest("callback retirement shape request"),
    );

    const states = [_]LossDispatchCallbackRetainedStateV1{
        .pending,
        .submission_ambiguous,
        .completion_unknown,
        .invalid_completion,
    };
    for (states) |state| {
        const retention = try makeTestRetention(
            &harness,
            lease,
            pin,
            state,
        );
        try validateLossDispatchCallbackRetentionV1(
            retention,
            harness.fixture.inventory[0],
            lease,
            pin,
        );
    }

    const pending = try makeTestRetention(
        &harness,
        lease,
        pin,
        .pending,
    );
    const removed = try makeTestLoss(
        harness.fixture,
        .removed_notification,
        7,
    );
    const removed_plan = try makeTestPlan(
        &harness,
        pending,
        lease,
        pin,
        removed,
    );
    try requireProductionEligibleLossDispatchCallbackRetirementPlanV1(
        removed_plan,
        pending,
        removed.observation,
        removed.transition,
    );

    const command_removed = try makeTestLoss(
        harness.fixture,
        .command_buffer_device_removed,
        8,
    );
    const command_plan = try makeTestPlan(
        &harness,
        pending,
        lease,
        pin,
        command_removed,
    );
    try requireProductionEligibleLossDispatchCallbackRetirementPlanV1(
        command_plan,
        pending,
        command_removed.observation,
        command_removed.transition,
    );

    const synthetic = try makeTestLoss(
        harness.fixture,
        .test_injected,
        9,
    );
    const synthetic_plan = try makeTestPlan(
        &harness,
        pending,
        lease,
        pin,
        synthetic,
    );
    try std.testing.expect(
        !lossDispatchCallbackRetirementPlanProductionEligibleV1(
            synthetic_plan,
            pending,
            synthetic.observation,
            synthetic.transition,
        ),
    );
    try std.testing.expectError(
        Error.ProductionEvidenceRequired,
        requireProductionEligibleLossDispatchCallbackRetirementPlanV1(
            synthetic_plan,
            pending,
            synthetic.observation,
            synthetic.transition,
        ),
    );

    var forged_pending = pending;
    forged_pending.backend_quarantine_sha256 =
        testDigest("forged pending quarantine");
    forged_pending.retention_sha256 =
        lossDispatchCallbackRetentionRootV1(forged_pending);
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackRetention,
        validateLossDispatchCallbackRetentionV1(
            forged_pending,
            harness.fixture.inventory[0],
            lease,
            pin,
        ),
    );

    const ambiguous = try makeTestRetention(
        &harness,
        lease,
        pin,
        .submission_ambiguous,
    );
    var forged_ambiguous = ambiguous;
    forged_ambiguous.backend_quarantine_sha256 = zero_digest;
    forged_ambiguous.retention_sha256 =
        lossDispatchCallbackRetentionRootV1(forged_ambiguous);
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackRetention,
        validateLossDispatchCallbackRetentionV1(
            forged_ambiguous,
            harness.fixture.inventory[0],
            lease,
            pin,
        ),
    );
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackRetention,
        validateLossDispatchCallbackRetentionReplayV1(
            forged_pending,
            pending,
        ),
    );

    try settleForCleanup(&harness, &adapter, pin);
    try harness.release(lease);
    try harness.close();
}

test "detached callback fence settles outcome six without other authority" {
    var harness: TestHarness = .{};
    try harness.init("callback retirement settlement device");
    const lease = try harness.materialize();
    var adapter: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        adapter.interface(),
        testDigest("callback retirement settlement request"),
    );
    const loss = try makeTestLoss(
        harness.fixture,
        .removed_notification,
        11,
    );
    const retention = try makeTestRetention(
        &harness,
        lease,
        pin,
        .invalid_completion,
    );
    const plan = try makeTestPlan(
        &harness,
        retention,
        lease,
        pin,
        loss,
    );

    const fence = try makeLossDispatchCallbackFenceV1(
        plan,
        retention,
        23,
        testDigest("callback retirement native prepare"),
        testDigest("callback retirement backend terminal"),
        0,
        0,
        .none,
        0,
        zero_digest,
    );
    try std.testing.expectEqual(@as(u64, 1), fence.native_callback_detached);
    try std.testing.expectEqual(@as(u64, 1), fence.native_record_retained);
    try std.testing.expectEqual(@as(u64, 0), fence.native_completion_observed);

    const observed_fence = try makeLossDispatchCallbackFenceV1(
        plan,
        retention,
        23,
        testDigest("callback retirement native prepare"),
        testDigest("callback retirement backend terminal"),
        1,
        lifecycle.command_buffer_status_error,
        .command_buffer,
        lifecycle.command_buffer_device_removed_error,
        testDigest("callback retirement diagnostic snapshot"),
    );
    try validateLossDispatchCallbackFenceV1(
        observed_fence,
        plan,
        retention,
    );
    const native_other_fence = try makeLossDispatchCallbackFenceV1(
        plan,
        retention,
        23,
        testDigest("callback retirement native prepare"),
        testDigest("callback retirement backend terminal"),
        1,
        lifecycle.command_buffer_status_error,
        .native_other,
        29,
        testDigest("callback retirement other-domain snapshot"),
    );
    try validateLossDispatchCallbackFenceV1(
        native_other_fence,
        plan,
        retention,
    );

    const terminal = try allocation_tree.makeDispatchTerminalV1(
        pin,
        .ownership_retired_after_device_loss,
        retention.submission_sha256,
        fence.backend_terminal_sha256,
        zero_digest,
    );
    adapter.expect(terminal);
    const completion = try harness.coordinator.completeDispatchPin(
        pin,
        adapter.interface(),
        terminal,
    );
    const receipt =
        try makeLossDispatchCallbackRetirementReceiptV1(
            plan,
            retention,
            fence,
            harness.fixture.inventory[0],
            lease,
            pin,
            terminal,
            completion,
            testDigest("callback retirement native retirement"),
            testDigest("callback retirement adapter settlement"),
        );
    try validateLossDispatchCallbackRetirementReceiptV1(
        receipt,
        plan,
        retention,
        fence,
        harness.fixture.inventory[0],
        lease,
        pin,
        terminal,
        completion,
    );
    try validateLossDispatchCallbackRetentionReplayV1(
        retention,
        retention,
    );
    try validateLossDispatchCallbackRetirementPlanReplayV1(
        plan,
        plan,
    );
    try validateLossDispatchCallbackFenceReplayV1(fence, fence);
    try validateLossDispatchCallbackRetirementReceiptReplayV1(
        receipt,
        receipt,
    );

    try expectDigestHex(
        "640f042c95d7e0b5c8af997fcc66c61cf0d833711fa2da9a8d0a72106e51d6d8",
        retention.retention_sha256,
    );
    try expectDigestHex(
        "b8b61fb38735daf94ae4f76556248557eea5e2b6846b83c3a11c29b269e9f6f9",
        plan.plan_sha256,
    );
    try expectDigestHex(
        "63f7b35ee4b3b22013526296ffc3aba4b253fa0c4a732e94ae4265720ebf378c",
        fence.fence_sha256,
    );
    try expectDigestHex(
        "5cf6dbec24be0518df4c2425d251c86035b67a44b0633c103c00049d67bede55",
        receipt.receipt_sha256,
    );

    var forged_fence = fence;
    forged_fence.native_callback_detached = 0;
    forged_fence.fence_sha256 =
        lossDispatchCallbackFenceRootV1(forged_fence);
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackFence,
        validateLossDispatchCallbackFenceV1(
            forged_fence,
            plan,
            retention,
        ),
    );

    forged_fence = fence;
    forged_fence.native_completion_observed = 1;
    forged_fence.native_command_status = 0;
    forged_fence.native_error_domain_kind = .none;
    forged_fence.native_error_code_bits = 0;
    forged_fence.callback_snapshot_sha256 = zero_digest;
    forged_fence.fence_sha256 =
        lossDispatchCallbackFenceRootV1(forged_fence);
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackFence,
        validateLossDispatchCallbackFenceV1(
            forged_fence,
            plan,
            retention,
        ),
    );

    var forged_receipt = receipt;
    forged_receipt.outcome = .terminal_failure;
    forged_receipt.receipt_sha256 =
        lossDispatchCallbackRetirementReceiptRootV1(
            forged_receipt,
        );
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackRetirementReceipt,
        validateLossDispatchCallbackRetirementReceiptV1(
            forged_receipt,
            plan,
            retention,
            fence,
            harness.fixture.inventory[0],
            lease,
            pin,
            terminal,
            completion,
        ),
    );
    forged_receipt = receipt;
    forged_receipt.native_retirement_sha256 = zero_digest;
    forged_receipt.receipt_sha256 =
        lossDispatchCallbackRetirementReceiptRootV1(
            forged_receipt,
        );
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackRetirementReceipt,
        validateLossDispatchCallbackRetirementReceiptV1(
            forged_receipt,
            plan,
            retention,
            fence,
            harness.fixture.inventory[0],
            lease,
            pin,
            terminal,
            completion,
        ),
    );
    forged_receipt = receipt;
    forged_receipt.output_authority_sha256 =
        testDigest("forged output authority");
    forged_receipt.receipt_sha256 =
        lossDispatchCallbackRetirementReceiptRootV1(
            forged_receipt,
        );
    try std.testing.expectError(
        Error.InvalidLossDispatchCallbackRetirementReceipt,
        validateLossDispatchCallbackRetirementReceiptV1(
            forged_receipt,
            plan,
            retention,
            fence,
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
