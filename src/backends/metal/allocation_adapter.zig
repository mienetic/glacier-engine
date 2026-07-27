//! Native Metal adapter for the portable device-allocation lease.
//!
//! The portable V1 charge is the exact logical `MTLBuffer.length` returned by
//! a direct Shared resource. `MTLResource.allocatedSize` is retained as a
//! separate per-object native observation because Metal exposes it only after
//! creation. Neither value is relabelled as residency, and device-wide
//! `currentAllocatedSize` is never used to infer object ownership.

const std = @import("std");
const core = @import("core");
const config = @import("config");
const metal = @import("backend.zig");
const metal_lifecycle = @import("device_lifecycle_adapter.zig");
const native = @import("native_observer.zig");

const metal_enabled = if (@hasDecl(config, "metal_enabled"))
    config.metal_enabled
else
    false;
const metal_test_faults = if (@hasDecl(config, "metal_test_faults"))
    config.metal_test_faults
else
    false;

pub const allocation = core.device_allocation_lease;
pub const lease_tree = core.device_allocation_lease_tree;
pub const device = core.device_capability_contract;
pub const lifecycle = core.device_lifecycle_contract;
pub const loss_dispatch_reconciliation =
    core.device_loss_dispatch_reconciliation;
pub const loss_retirement = core.device_loss_retirement;
const resource = core.resource_bank;
pub const Digest = allocation.Digest;

pub const adapter_abi: u64 = 0x474d_4141_0000_0001;
pub const observation_abi: u64 = 0x474d_414f_0000_0001;
pub const dispatch_observation_abi: u64 =
    0x474d_444f_0000_0001;
pub const pre_submit_attempt_abi: u64 =
    0x474d_5041_0000_0001;
pub const matvec_dispatch_request_abi: u64 =
    0x474d_4452_0000_0001;
pub const pre_submit_rejection_abi: u64 =
    0x474d_5052_0000_0001;
pub const async_dispatch_ticket_abi: u64 =
    0x474d_4154_0000_0001;
pub const async_dispatch_quarantine_abi: u64 =
    0x474d_4151_0000_0001;
pub const async_dispatch_terminal_failure_abi: u64 =
    0x474d_4146_0000_0001;

const authority_domain =
    "glacier-metal-allocation-authority-v1\x00";
const object_identity_domain =
    "glacier-metal-allocation-object-identity-v1\x00";
const observation_domain =
    "glacier-metal-allocation-observation-v1\x00";
const dispatch_authority_domain =
    "glacier-metal-dispatch-authority-v1\x00";
const queue_authority_domain =
    "glacier-metal-dispatch-queue-authority-v1\x00";
const dispatch_geometry_domain =
    "glacier-metal-dispatch-geometry-v1\x00";
const dispatch_roles_domain =
    "glacier-metal-dispatch-roles-v1\x00";
const dispatch_packed_input_domain =
    "glacier-metal-dispatch-packed-input-v1\x00";
const dispatch_scales_input_domain =
    "glacier-metal-dispatch-scales-input-v1\x00";
const dispatch_vector_input_domain =
    "glacier-metal-dispatch-vector-input-v1\x00";
const dispatch_output_domain =
    "glacier-metal-dispatch-output-v1\x00";
const dispatch_submission_domain =
    "glacier-metal-dispatch-submission-v1\x00";
const dispatch_telemetry_domain =
    "glacier-metal-dispatch-telemetry-v1\x00";
const dispatch_backend_completion_domain =
    "glacier-metal-dispatch-backend-completion-v1\x00";
const dispatch_observation_domain =
    "glacier-metal-dispatch-observation-v1\x00";
const pre_submit_attempt_domain =
    "glacier-metal-matvec-pre-submit-attempt-v1\x00";
const matvec_dispatch_request_domain =
    "glacier-metal-matvec-dispatch-request-v1\x00";
const pre_submit_rejection_domain =
    "glacier-metal-matvec-pre-submit-rejection-v1\x00";
const async_dispatch_ticket_domain =
    "glacier-metal-single-flight-async-ticket-v1\x00";
const async_dispatch_quarantine_domain =
    "glacier-metal-async-dispatch-quarantine-v1\x00";
const async_dispatch_native_terminal_domain =
    "glacier-metal-async-native-terminal-v1\x00";
const async_dispatch_failure_backend_completion_domain =
    "glacier-metal-async-failure-backend-completion-v1\x00";
const async_dispatch_terminal_failure_domain =
    "glacier-metal-async-dispatch-terminal-failure-v1\x00";
const loss_retirement_adapter_challenge_domain =
    "glacier-metal-loss-retirement-adapter-challenge-v1\x00";
const loss_retirement_settlement_domain =
    "glacier-metal-loss-retirement-settlement-v1\x00";
const loss_dispatch_reconciliation_adapter_challenge_domain =
    "glacier-metal-loss-dispatch-reconciliation-adapter-challenge-v1\x00";
const loss_dispatch_reconciliation_settlement_domain =
    "glacier-metal-loss-dispatch-reconciliation-settlement-v1\x00";
const completed_command_buffer_status: u32 = 4;
pub const async_native_command_status_unobserved: u64 =
    std.math.maxInt(u64);
pub const async_native_command_status_completed: u64 =
    completed_command_buffer_status;
pub const async_native_command_status_error: u64 = 5;
/// Adapter-local reason code used when the native submit call cannot prove
/// whether commit occurred and no native error code exists yet.
pub const async_submission_ambiguous_adapter_code: u64 = 1;
const supported_profile =
    device.OperationProfileBitsV1.matvec_int4_f32_bounded;
const supported_features =
    device.FeatureBitsV1.allocation |
    device.FeatureBitsV1.dispatch |
    device.FeatureBitsV1.completion_fence |
    device.FeatureBitsV1.persistent_weights |
    device.FeatureBitsV1.allocated_bytes_observation |
    device.FeatureBitsV1.device_loss_signal;

pub const Error =
    allocation.Error ||
    lease_tree.Error ||
    device.Error ||
    lifecycle.Error ||
    loss_dispatch_reconciliation.Error ||
    loss_retirement.Error ||
    metal_lifecycle.Error ||
    metal.MetalError ||
    error{
        InvalidConfiguration,
        InvalidDevice,
        InvalidObservation,
        InvalidDispatchEvidence,
        DispatchBusy,
        DispatchUnresolved,
        DispatchPreflightPassed,
        StaleObject,
        BufferTooSmall,
    };

/// Semantic binding identities for the four exact live allocations consumed
/// by one registered-buffer INT4 matvec. Digests are role labels, never
/// native handles, GPU addresses, or allocation permits.
pub const MetalMatvecAllocationBindingsV1 = struct {
    packed_weights_sha256: Digest = allocation.zero_digest,
    scales_sha256: Digest = allocation.zero_digest,
    input_sha256: Digest = allocation.zero_digest,
    output_sha256: Digest = allocation.zero_digest,
};

/// Canonical geometry derived before the backend is allowed to submit.
pub const MetalMatvecGeometryV1 = struct {
    group_size: u32 = 0,
    in_features: u32 = 0,
    out_features: u32 = 0,
    reserved: u32 = 0,
    packed_bytes: u64 = 0,
    scale_count: u64 = 0,
    scales_bytes: u64 = 0,
    input_count: u64 = 0,
    input_bytes: u64 = 0,
    output_count: u64 = 0,
    output_bytes: u64 = 0,
    geometry_sha256: Digest = allocation.zero_digest,
};

/// Pointer-free binding of semantic roles to the exact four backend objects.
/// Native registry tokens stay private inside the adapter.
pub const MetalMatvecRoleEvidenceV1 = struct {
    bindings: MetalMatvecAllocationBindingsV1 = .{},
    packed_weights_object_sha256: Digest = allocation.zero_digest,
    scales_object_sha256: Digest = allocation.zero_digest,
    input_object_sha256: Digest = allocation.zero_digest,
    output_object_sha256: Digest = allocation.zero_digest,
    roles_sha256: Digest = allocation.zero_digest,
};

/// Sealed evidence from one physically completed registered-buffer dispatch.
/// This is composition evidence, not authentication or a residency claim.
pub const MetalLeaseTreeDispatchObservationV1 = struct {
    abi_version: u64 = dispatch_observation_abi,
    outcome: lease_tree.DispatchTerminalOutcomeV1 = .succeeded,
    dispatch_generation: u64 = 0,
    allocation_count: u64 = 0,
    materialized_bytes: u64 = 0,
    authority_sha256: Digest = allocation.zero_digest,
    admission_sha256: Digest = allocation.zero_digest,
    lease_sha256: Digest = allocation.zero_digest,
    backend_object_set_sha256: Digest = allocation.zero_digest,
    pin_sha256: Digest = allocation.zero_digest,
    dispatch_request_sha256: Digest = allocation.zero_digest,
    dispatch_authority_sha256: Digest = allocation.zero_digest,
    queue_authority_sha256: Digest = allocation.zero_digest,
    geometry: MetalMatvecGeometryV1 = .{},
    roles: MetalMatvecRoleEvidenceV1 = .{},
    packed_weights_input_sha256: Digest = allocation.zero_digest,
    scales_input_sha256: Digest = allocation.zero_digest,
    vector_input_sha256: Digest = allocation.zero_digest,
    submission_sha256: Digest = allocation.zero_digest,
    telemetry: metal.MetalDispatchTelemetry = .{
        .current_allocated_before = 0,
        .current_allocated_after = 0,
        .gpu_start_time_bits = 0,
        .gpu_end_time_bits = 0,
        .gpu_duration_nanoseconds = 0,
        .command_status = 0,
    },
    telemetry_sha256: Digest = allocation.zero_digest,
    backend_completion_sha256: Digest = allocation.zero_digest,
    output_sha256: Digest = allocation.zero_digest,
    terminal_sha256: Digest = allocation.zero_digest,
    observation_sha256: Digest = allocation.zero_digest,
};

pub const MetalLeaseTreeDispatchResultV1 = struct {
    observation: MetalLeaseTreeDispatchObservationV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
};

/// Level-triggered observation of one exact single-flight async dispatch.
/// `pending` and `quarantined` are deliberately nonterminal and grant no
/// Bank-release or native-finalization authority.
pub const MetalAsyncDispatchPollV1 = union(enum) {
    pending,
    completed: MetalLeaseTreeDispatchResultV1,
    quarantined: MetalAsyncDispatchQuarantineV1,
};

/// Deterministic precedence for failures proven before any Metal command is
/// submitted. `invalid_role_mapping` additionally depends on the adapter's
/// exact live allocation slots and is therefore adapter-authorized rather
/// than independently derivable from this pointer-free attempt alone.
pub const MetalMatvecPreSubmitRejectionReasonV1 = enum(u64) {
    invalid_geometry = 1,
    invalid_host_lengths = 2,
    invalid_role_bindings = 3,
    invalid_role_mapping = 4,
    _,
};

/// Canonical pointer-free description of the arguments rejected before
/// submission. Slice contents are intentionally absent because no upload or
/// execution may occur on this transition.
pub const MetalMatvecPreSubmitAttemptV1 = struct {
    abi_version: u64 = pre_submit_attempt_abi,
    group_size: u32 = 0,
    in_features: u32 = 0,
    out_features: u32 = 0,
    reserved: u32 = 0,
    packed_weights_bytes: u64 = 0,
    scales_count: u64 = 0,
    input_count: u64 = 0,
    output_count: u64 = 0,
    bindings: MetalMatvecAllocationBindingsV1 = .{},
    attempt_sha256: Digest = allocation.zero_digest,
};

/// Adapter-issued one-shot request for one exact canonical matvec attempt.
/// Request generation prevents an old pin from replaying the same attempt
/// after a later request has completed on this adapter.
pub const MetalMatvecDispatchRequestV1 = struct {
    abi_version: u64 = matvec_dispatch_request_abi,
    request_generation: u64 = 0,
    dispatch_authority_sha256: Digest = allocation.zero_digest,
    queue_authority_sha256: Digest = allocation.zero_digest,
    attempt: MetalMatvecPreSubmitAttemptV1 = .{},
    request_sha256: Digest = allocation.zero_digest,
};

/// Pointer-free evidence that one exact prepared request and dispatch pin
/// were handed to the adapter's single native queue slot. The ticket is not
/// terminal evidence, grants no Bank mutation authority, and contains no
/// native handle. `ticket_generation` fences reuse of queue slot zero.
pub const MetalAsyncDispatchTicketV1 = struct {
    abi_version: u64 = async_dispatch_ticket_abi,
    ticket_generation: u64 = 0,
    queue_slot: u64 = 0,
    dispatch_generation: u64 = 0,
    dispatch_authority_sha256: Digest = allocation.zero_digest,
    queue_authority_sha256: Digest = allocation.zero_digest,
    request: MetalMatvecDispatchRequestV1 = .{},
    pin_sha256: Digest = allocation.zero_digest,
    submission_sha256: Digest = allocation.zero_digest,
    ticket_sha256: Digest = allocation.zero_digest,
};

/// Sticky, explicitly nonterminal classification of one async command whose
/// allocation pin must remain retained. These reasons describe only the
/// observed submission/completion boundary. They do not assert physical
/// device loss and do not alone authorize `DispatchTerminalEvidenceV1`.
/// Only an exact `terminal_command_error` plus the adapter's matching private
/// native snapshot may be reconciled into terminal-failure evidence.
pub const MetalAsyncDispatchQuarantineReasonV1 = enum(u64) {
    submission_ambiguous = 1,
    /// The adapter could not authenticate a completion snapshot. Raw status
    /// and observed-bit values are retained verbatim, including 4 or 5; this
    /// classification remains nonterminal regardless of those raw values.
    completion_unknown = 2,
    invalid_completion = 3,
    terminal_command_error = 4,
    _,
};

pub const MetalAsyncNativeDispositionV1 = enum(u64) {
    commit_started = 1,
    submitted = 2,
    terminal_status_observed = 3,
    _,
};

pub const MetalAsyncErrorDomainKindV1 = enum(u64) {
    none = 0,
    native_bridge = 1,
    completion_validation = 2,
    command_buffer = 3,
    _,
};

/// Pointer-free sticky quarantine observation for one exact async ticket.
/// Even when the raw native status is terminal, this value is deliberately
/// not core terminal evidence and carries no terminal/output root.
pub const MetalAsyncDispatchQuarantineV1 = struct {
    abi_version: u64 = async_dispatch_quarantine_abi,
    reason: MetalAsyncDispatchQuarantineReasonV1 =
        .submission_ambiguous,
    ticket: MetalAsyncDispatchTicketV1 = .{},
    device_sha256: Digest = allocation.zero_digest,
    placement_sha256: Digest = allocation.zero_digest,
    native_disposition: MetalAsyncNativeDispositionV1 =
        .commit_started,
    native_command_status: u64 =
        async_native_command_status_unobserved,
    native_completion_observed: u64 = 0,
    error_domain_kind: MetalAsyncErrorDomainKindV1 =
        .native_bridge,
    error_code_bits: u64 = 0,
    quarantine_sha256: Digest = allocation.zero_digest,
};

/// Adapter-authorized terminal-failure evidence for one exact quarantined
/// command-buffer error. The native command token remains private, while the
/// retained ticket, quarantine, and exact fixed-width error projection bind
/// this sidecar to the original submission. This value does not assert
/// physical device loss, residency loss, or successful output publication.
pub const MetalAsyncDispatchTerminalFailureV1 = struct {
    abi_version: u64 =
        async_dispatch_terminal_failure_abi,
    outcome: lease_tree.DispatchTerminalOutcomeV1 =
        .terminal_failure,
    quarantine: MetalAsyncDispatchQuarantineV1 = .{},
    dispatch_generation: u64 = 0,
    allocation_count: u64 = 0,
    materialized_bytes: u64 = 0,
    pin_sha256: Digest = allocation.zero_digest,
    backend_object_set_sha256: Digest =
        allocation.zero_digest,
    current_allocated_before: u64 = 0,
    current_allocated_after: u64 = 0,
    gpu_start_time_bits: u64 = 0,
    gpu_end_time_bits: u64 = 0,
    native_command_status: u64 = 0,
    error_domain_kind: MetalAsyncErrorDomainKindV1 =
        .command_buffer,
    error_code_bits: u64 = 0,
    native_terminal_sha256: Digest =
        allocation.zero_digest,
    submission_sha256: Digest = allocation.zero_digest,
    backend_completion_sha256: Digest =
        allocation.zero_digest,
    terminal_sha256: Digest = allocation.zero_digest,
    failure_sha256: Digest = allocation.zero_digest,
};

pub const MetalAsyncDispatchTerminalFailureResultV1 = struct {
    failure: MetalAsyncDispatchTerminalFailureV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
};

/// Adapter-authorized diagnostic evidence for one exact pre-submit failure.
/// The matching terminal is always `rejected_before_submit` with zero
/// submission, backend-completion, and output roots.
pub const MetalMatvecPreSubmitRejectionV1 = struct {
    abi_version: u64 = pre_submit_rejection_abi,
    reason: MetalMatvecPreSubmitRejectionReasonV1 =
        .invalid_geometry,
    dispatch_generation: u64 = 0,
    allocation_count: u64 = 0,
    materialized_bytes: u64 = 0,
    pin_sha256: Digest = allocation.zero_digest,
    backend_object_set_sha256: Digest = allocation.zero_digest,
    request: MetalMatvecDispatchRequestV1 = .{},
    terminal_sha256: Digest = allocation.zero_digest,
    rejection_sha256: Digest = allocation.zero_digest,
};

pub const MetalMatvecPreSubmitRejectionResultV1 = struct {
    rejection: MetalMatvecPreSubmitRejectionV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
};

const AuthorizedDispatchEvidenceV1 = union(enum) {
    submitted: MetalLeaseTreeDispatchObservationV1,
    terminal_failure: MetalAsyncDispatchTerminalFailureV1,
    rejected_before_submit: MetalMatvecPreSubmitRejectionV1,
    cancelled_before_submit: MetalMatvecDispatchRequestV1,
};

const AuthorizedDispatchTerminalV1 = struct {
    pin: lease_tree.LeaseTreeDispatchPinV1,
    request: MetalMatvecDispatchRequestV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
    evidence: AuthorizedDispatchEvidenceV1,
};

const DispatchSettlementTombstoneV1 = struct {
    pin: lease_tree.LeaseTreeDispatchPinV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
    completion: lease_tree.LeaseTreeDispatchCompletionV1,
    bank_permit: resource.LeasePinPermitV1,
    bank_completion: resource.LeasePinCompletionV1,
};

const ValidatedMatvecDispatchSetV1 = struct {
    tokens: [4]metal.MetalBufferToken,
    evidence: MetalMatvecRoleEvidenceV1,
};

const PendingMetalAsyncDispatchV1 = struct {
    lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    request: MetalMatvecDispatchRequestV1,
    ticket: MetalAsyncDispatchTicketV1,
    draft: MetalLeaseTreeDispatchObservationV1,
    selected: ValidatedMatvecDispatchSetV1,
    native_submission: metal.MetalAsyncSubmission,
    native_completion: ?metal.MetalAsyncCompletion = null,
};

/// Pointer-free direct evidence for one currently live native allocation.
/// `charged_resource_bytes` is logical resource accounting.
/// `resource_allocated_size_bytes` is the direct Metal per-resource
/// observation and is not a residency or reclaim-completion claim.
pub const MetalAllocationObservationV1 = struct {
    abi_version: u64 = observation_abi,
    authority_sha256: Digest = allocation.zero_digest,
    admission_sha256: Digest = allocation.zero_digest,
    allocation_call_sha256: Digest = allocation.zero_digest,
    binding_sha256: Digest = allocation.zero_digest,
    backend_object_sha256: Digest = allocation.zero_digest,
    object_sha256: Digest = allocation.zero_digest,
    adapter_slot_index: u32 = 0,
    reserved: u32 = 0,
    backend_object_generation: u64 = 0,
    ordinal: u64 = 0,
    device_registry_id: u64 = 0,
    requested_bytes: u64 = 0,
    charged_resource_bytes: u64 = 0,
    buffer_length_bytes: u64 = 0,
    resource_allocated_size_bytes: u64 = 0,
    storage_mode: u32 = 0,
    cpu_cache_mode: u32 = 0,
    observation_sha256: Digest = allocation.zero_digest,
};

/// Caller-owned private storage. Native pointers never enter a receipt,
/// manifest, observation, or snapshot.
pub const MetalAllocationSlotV1 = struct {
    live: bool = false,
    generation: u64 = 0,
    call: allocation.AllocationCallV1 = .{},
    object: allocation.BackendObjectV1 = .{},
    native_token: metal.MetalBufferToken = .{},
    native_info: metal.MetalBufferInfo = .{},
};

pub const MetalAllocationSnapshotV1 = struct {
    authority_epoch: u64,
    adapter_instance: u64,
    device_registry_id: u64,
    used_resource_bytes: u64,
    observed_allocated_size_bytes: u64,
    live_objects: usize,
    materialized_leases: usize,
    allocate_calls: u64,
    free_calls: u64,
    inspect_calls: u64,
};

const LossRetirementModeV1 = enum {
    production,
    synthetic_test,
};

/// Same-process destructive authority retained only after the portable plan
/// and this exact native adapter have both accepted the loss. Public hashes
/// alone never select the no-property-read free path.
const MetalLossRetirementPermitV1 = struct {
    plan: loss_retirement.LossRetirementPlanV1,
    plan_sha256: Digest,
    lease_sha256: Digest,
    authority_sha256: Digest,
    selected_capability_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    source_instance_sha256: Digest,
    source_identity: metal.MetalDeviceLifecycleSourceIdentity,
    minimum_event_sequence: u64,
    reference_release_count: u64 = 0,
    mode: LossRetirementModeV1,
};

const MetalLossRetirementTombstoneV1 = struct {
    plan: loss_retirement.LossRetirementPlanV1,
    terminal: lease_tree.LeaseTreeAllocationTerminalReceiptV1,
    receipt: loss_retirement.LossRetirementReceiptV1,
};

const MetalLossRetirementChallengeContextV1 = struct {
    adapter: *MetalAllocationAdapterV1,
    observation: lifecycle.ObservationV1,
    result: ?Digest = null,
};

const MetalLossRetirementArmContextV1 = struct {
    adapter: *MetalAllocationAdapterV1,
    plan: loss_retirement.LossRetirementPlanV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    mode: LossRetirementModeV1,
};

const LossDispatchReconciliationModeV1 = enum {
    production,
    synthetic_test,
};

/// Same-process authority for one exact retained device-removed command. It
/// contains no Bank permit: only the Coordinator can release the active pin.
const MetalLossDispatchReconciliationPermitV1 = struct {
    mode: LossDispatchReconciliationModeV1,
    plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
    retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    failure: MetalAsyncDispatchTerminalFailureV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
};

/// Exact post-Bank, post-native-finalization replay state. Native command
/// handles and Bank mutation authority never enter this tombstone.
const MetalLossDispatchReconciliationTombstoneV1 = struct {
    plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
    retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
    selected_entry: device.DeviceInventoryEntryV1,
    lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    failure: MetalAsyncDispatchTerminalFailureV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
    completion: lease_tree.LeaseTreeDispatchCompletionV1,
    receipt: loss_dispatch_reconciliation.LossDispatchReconciliationReceiptV1,
};

const MetalLossDispatchReconciliationChallengeContextV1 = struct {
    adapter: *MetalAllocationAdapterV1,
    observation: lifecycle.ObservationV1,
    ticket: MetalAsyncDispatchTicketV1,
    result: ?Digest = null,
};

const MetalLossDispatchReconciliationArmContextV1 = struct {
    adapter: *MetalAllocationAdapterV1,
    mode: LossDispatchReconciliationModeV1,
    plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
    retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
    observation: lifecycle.ObservationV1,
    transition: lifecycle.TransitionReceiptV1,
    source_cursor: lifecycle.SourceCursorV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    prior_inventory: []const device.DeviceInventoryEntryV1,
    selected_entry: device.DeviceInventoryEntryV1,
    successor_entry: device.DeviceInventoryEntryV1,
    ticket: MetalAsyncDispatchTicketV1,
    result: ?MetalAsyncDispatchTerminalFailureResultV1 = null,
};

const ValidatedLossDispatchReconciliationSourceV1 = struct {
    pending: PendingMetalAsyncDispatchV1,
    intent: lease_tree.DispatchPinIntentV1,
    quarantine: MetalAsyncDispatchQuarantineV1,
    native_completion: metal.MetalAsyncCompletion,
    result: MetalAsyncDispatchTerminalFailureResultV1,
};

fn expectedAllocationCapabilityV1(
    info: metal.MetalDeviceInfo,
    limits: metal.MetalAllocationLimits,
    max_total_resource_bytes: u64,
) Error!device.DeviceCapabilityV1 {
    if (limits.device_registry_id != info.registry_id or
        limits.resource_granularity != 1 or
        limits.storage_mode != metal.shared_storage_mode or
        limits.cpu_cache_mode != metal.default_cpu_cache_mode or
        info.recommended_max_working_set_size == 0 or
        max_total_resource_bytes == 0 or
        max_total_resource_bytes >
            info.recommended_max_working_set_size)
        return Error.InvalidDevice;
    const maximum_single = @min(
        limits.max_buffer_length,
        max_total_resource_bytes,
    );
    if (maximum_single == 0) return Error.InvalidDevice;
    return device.sealCapabilityV1(.{
        .backend_kind = .metal,
        .device_class = .accelerator,
        .operation_profile_bits = supported_profile,
        .operator_bits = device.profileOperatorBitsV1(supported_profile),
        .element_type_bits = device.profileElementTypeBitsV1(supported_profile),
        .numerical_policy_bits = device.profileNumericalPolicyBitsV1(supported_profile),
        .feature_bits = supported_features,
        .max_single_allocation_bytes = maximum_single,
        .max_total_device_bytes = max_total_resource_bytes,
        .max_queue_slots = 1,
        .backend_sha256 = native.contract.digestV1(
            "Metal.framework direct Shared allocation backend/v1",
        ),
        .device_sha256 = native.deviceIdentityV1(info),
        .driver_sha256 = device.zero_digest,
        .placement_sha256 = native.placementIdentityV1(info),
    });
}

/// Build one bounded Metal inventory entry for allocation-aware execution.
/// The caller chooses a logical resource budget no larger than Metal's
/// recommended working-set context. Allocation may still fail and remains a
/// fallible operation; this is a compatibility ceiling, not a memory promise.
pub fn makeAllocationInventoryEntryV1(
    backend: *metal.MetalBackend,
    discovery_epoch: u64,
    policy_rank: u64,
    max_total_resource_bytes: u64,
) Error!device.DeviceInventoryEntryV1 {
    if (comptime !metal_enabled)
        return metal.MetalError.Unavailable;
    if (discovery_epoch == 0 or max_total_resource_bytes == 0)
        return Error.InvalidConfiguration;
    try backend.requireInt4MatvecSupport();
    const info = try backend.deviceInfo();
    const limits = try backend.allocationLimits();
    const capability = try expectedAllocationCapabilityV1(
        info,
        limits,
        max_total_resource_bytes,
    );
    return device.sealInventoryEntryV1(.{
        .discovery_epoch = discovery_epoch,
        .policy_rank = policy_rank,
        .state = .present,
        .capability = capability,
    });
}

/// Same-process adapter over one exact MetalBackend context.
///
/// Once `interface()` exposes this address, do not copy or move the value.
/// Every live lease must be released before the backend is deinitialized.
pub const MetalAllocationAdapterV1 = struct {
    backend: *metal.MetalBackend,
    authority: allocation.AllocationAuthorityV1,
    slots: []MetalAllocationSlotV1,
    limits: metal.MetalAllocationLimits,
    device_sha256: Digest,
    placement_sha256: Digest,
    adapter_nonce: u64,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    dispatch_authority_sha256: Digest,
    queue_authority_sha256: Digest,
    self_address: usize = 0,
    next_generation: u64 = 1,
    next_matvec_request_generation: u64 = 1,
    next_async_ticket_generation: u64 = 1,
    prepared_matvec_request: ?MetalMatvecDispatchRequestV1 = null,
    reserved_dispatch_intent: ?lease_tree.DispatchPinIntentV1 = null,
    aborted_dispatch_intent: ?lease_tree.DispatchPinIntentV1 = null,
    bound_dispatch_pin: ?lease_tree.LeaseTreeDispatchPinV1 = null,
    cancelled_prepared_request: ?MetalMatvecDispatchRequestV1 = null,
    used_resource_bytes: u64 = 0,
    observed_allocated_size_bytes: u64 = 0,
    active_admission_sha256: Digest = allocation.zero_digest,
    dispatch_unresolved: bool = false,
    async_dispatch: ?PendingMetalAsyncDispatchV1 = null,
    async_quarantine: ?MetalAsyncDispatchQuarantineV1 = null,
    authorized_terminal: ?AuthorizedDispatchTerminalV1 = null,
    terminal_validation_observed: bool = false,
    settlement_tombstone: ?DispatchSettlementTombstoneV1 = null,
    loss_dispatch_reconciliation_permit: ?MetalLossDispatchReconciliationPermitV1 = null,
    loss_dispatch_reconciliation_tombstone: ?MetalLossDispatchReconciliationTombstoneV1 = null,
    loss_retirement_permit: ?MetalLossRetirementPermitV1 = null,
    loss_retirement_tombstone: ?MetalLossRetirementTombstoneV1 = null,
    allocate_calls: u64 = 0,
    free_calls: u64 = 0,
    inspect_calls: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        backend: *metal.MetalBackend,
        selected: device.DeviceInventoryEntryV1,
        authority_epoch: u64,
        adapter_nonce: u64,
        slots: []MetalAllocationSlotV1,
    ) Error!MetalAllocationAdapterV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        if (authority_epoch == 0 or adapter_nonce == 0 or
            slots.len == 0 or
            slots.len > allocation.maximum_allocations)
            return Error.InvalidConfiguration;
        try device.validateInventoryEntryV1(selected);
        try backend.requireInt4MatvecSupport();
        const info = try backend.deviceInfo();
        const limits = try backend.allocationLimits();
        const capability = selected.capability;
        const expected_device = native.deviceIdentityV1(info);
        const expected_placement = native.placementIdentityV1(info);
        const expected_capability =
            expectedAllocationCapabilityV1(
                info,
                limits,
                capability.max_total_device_bytes,
            ) catch return Error.InvalidDevice;
        const expected_selected =
            device.sealInventoryEntryV1(.{
                .discovery_epoch = selected.discovery_epoch,
                .policy_rank = selected.policy_rank,
                .state = .present,
                .capability = expected_capability,
            }) catch return Error.InvalidDevice;
        if (!std.meta.eql(selected, expected_selected) or
            !device.digestEqual(
                capability.device_sha256,
                expected_device,
            ) or
            !device.digestEqual(
                capability.placement_sha256,
                expected_placement,
            ))
            return Error.InvalidDevice;
        for (slots) |*slot| slot.* = .{};
        const adapter_identity =
            try backend.claimAllocationAdapterIdentity();
        const backend_authority_sha256 = backendAuthorityRootV1(
            authority_epoch,
            adapter_nonce,
            adapter_identity,
            selected,
            limits,
        );
        const authority = try allocation.makeAuthorityV1(
            authority_epoch,
            1,
            @intCast(slots.len),
            limits.resource_granularity,
            selected,
            backend_authority_sha256,
        );
        const dispatch_authority_sha256 =
            dispatchAuthorityRootV1(
                authority,
                adapter_nonce,
                adapter_identity,
                limits,
            );
        const queue_authority_sha256 = queueAuthorityRootV1(
            dispatch_authority_sha256,
            adapter_identity,
            limits,
        );
        if (digestIsZero(dispatch_authority_sha256) or
            digestIsZero(queue_authority_sha256) or
            device.digestEqual(
                dispatch_authority_sha256,
                queue_authority_sha256,
            ))
            return Error.InvalidConfiguration;
        return .{
            .backend = backend,
            .authority = authority,
            .slots = slots,
            .limits = limits,
            .device_sha256 = expected_device,
            .placement_sha256 = expected_placement,
            .adapter_nonce = adapter_nonce,
            .adapter_identity = adapter_identity,
            .dispatch_authority_sha256 = dispatch_authority_sha256,
            .queue_authority_sha256 = queue_authority_sha256,
        };
    }

    pub fn interface(
        self: *MetalAllocationAdapterV1,
    ) allocation.AdapterV1 {
        self.bindAddressOrPanic();
        return .{
            .context = self,
            .authority = self.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    /// Derive the adapter-local challenge composed into a portable retirement
    /// plan. The digest names this exact adapter instance, live lease, device,
    /// placement, and lifecycle observation; it grants no free authority.
    pub fn lossRetirementAdapterChallengeV1(
        self: *MetalAllocationAdapterV1,
        coordinator: *lease_tree.CoordinatorV1,
        bound_adapter: allocation.AdapterV1,
        observation: lifecycle.ObservationV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    ) Error!Digest {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        if (observation.abi_version != lifecycle.observation_abi or
            observation.observed_state != .lost or
            digestIsZero(observation.observation_sha256) or
            !device.digestEqual(
                observation.observation_sha256,
                lifecycle.observationRootV1(observation),
            ))
            return Error.InvalidObservation;
        var context: MetalLossRetirementChallengeContextV1 = .{
            .adapter = self,
            .observation = observation,
        };
        try coordinator.withQuiescedRetirementBindingV1(
            lease,
            .{
                .context = &context,
                .allocation_adapter = bound_adapter,
                .arm_fn = lossRetirementChallengeCallback,
            },
        );
        return context.result orelse Error.InvalidConfiguration;
    }

    /// Arm the production no-property-read reference-release path. Portable
    /// evidence is fully replayed first, then the exact retained native
    /// lifecycle source is checked in its current sticky lost state without a
    /// second consume.
    pub fn armLossRetirementV1(
        self: *MetalAllocationAdapterV1,
        coordinator: *lease_tree.CoordinatorV1,
        bound_adapter: allocation.AdapterV1,
        plan: loss_retirement.LossRetirementPlanV1,
        observation: lifecycle.ObservationV1,
        transition: lifecycle.TransitionReceiptV1,
        source_cursor: lifecycle.SourceCursorV1,
        requirement: device.DeviceRequirementV1,
        selection: device.DeviceSelectionReceiptV1,
        prior_inventory: []const device.DeviceInventoryEntryV1,
        selected_entry: device.DeviceInventoryEntryV1,
        successor_entry: device.DeviceInventoryEntryV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    ) Error!void {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        try loss_retirement.validateLossRetirementPlanV1(
            plan,
            observation,
            transition,
            source_cursor,
            requirement,
            selection,
            prior_inventory,
            selected_entry,
            successor_entry,
            self.authority,
            lease,
        );
        try loss_retirement
            .requireProductionEligibleLossRetirementPlanV1(
            plan,
            observation,
            transition,
        );
        var context: MetalLossRetirementArmContextV1 = .{
            .adapter = self,
            .plan = plan,
            .observation = observation,
            .transition = transition,
            .source_cursor = source_cursor,
            .requirement = requirement,
            .selection = selection,
            .prior_inventory = prior_inventory,
            .selected_entry = selected_entry,
            .successor_entry = successor_entry,
            .mode = .production,
        };
        coordinator.withQuiescedRetirementBindingV1(
            lease,
            .{
                .context = &context,
                .allocation_adapter = bound_adapter,
                .arm_fn = lossRetirementArmCallback,
            },
        ) catch |err| return mapCoordinatorRetirementError(err);
    }

    /// Fault-build-only arm for deterministic tests over real MTLBuffers.
    /// Synthetic evidence can never enter the production arm above, and this
    /// entry point is unavailable unless `metal_test_faults` was compiled in.
    pub fn armSyntheticLossRetirementForTestV1(
        self: *MetalAllocationAdapterV1,
        coordinator: *lease_tree.CoordinatorV1,
        bound_adapter: allocation.AdapterV1,
        plan: loss_retirement.LossRetirementPlanV1,
        observation: lifecycle.ObservationV1,
        transition: lifecycle.TransitionReceiptV1,
        source_cursor: lifecycle.SourceCursorV1,
        requirement: device.DeviceRequirementV1,
        selection: device.DeviceSelectionReceiptV1,
        prior_inventory: []const device.DeviceInventoryEntryV1,
        selected_entry: device.DeviceInventoryEntryV1,
        successor_entry: device.DeviceInventoryEntryV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    ) Error!void {
        if (comptime !metal_enabled or !metal_test_faults)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        try loss_retirement.validateLossRetirementPlanV1(
            plan,
            observation,
            transition,
            source_cursor,
            requirement,
            selection,
            prior_inventory,
            selected_entry,
            successor_entry,
            self.authority,
            lease,
        );
        if (plan.source != .test_injected or
            plan.evidence_class != .synthetic or
            observation.source != .test_injected or
            observation.evidence_class != .synthetic or
            transition.source != .test_injected or
            transition.evidence_class != .synthetic or
            loss_retirement.lossRetirementPlanProductionEligibleV1(
                plan,
                observation,
                transition,
            ))
            return Error.InvalidLossRetirementPlan;
        var context: MetalLossRetirementArmContextV1 = .{
            .adapter = self,
            .plan = plan,
            .observation = observation,
            .transition = transition,
            .source_cursor = source_cursor,
            .requirement = requirement,
            .selection = selection,
            .prior_inventory = prior_inventory,
            .selected_entry = selected_entry,
            .successor_entry = successor_entry,
            .mode = .synthetic_test,
        };
        coordinator.withQuiescedRetirementBindingV1(
            lease,
            .{
                .context = &context,
                .allocation_adapter = bound_adapter,
                .arm_fn = lossRetirementArmCallback,
            },
        ) catch |err| return mapCoordinatorRetirementError(err);
    }

    /// Close an armed retirement only after the ordinary LeaseTree release is
    /// terminal and both adapter and native registries contain no retained
    /// object. `terminal` must come from the exact bound same-process
    /// Coordinator. Its structural digest is composition evidence, not
    /// authentication or Bank attestation for an untrusted caller. Exact
    /// completion replay returns the retained tombstone.
    pub fn completeLossRetirementV1(
        self: *MetalAllocationAdapterV1,
        plan: loss_retirement.LossRetirementPlanV1,
        terminal: lease_tree.LeaseTreeAllocationTerminalReceiptV1,
    ) Error!loss_retirement.LossRetirementReceiptV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.loss_retirement_tombstone) |retained| {
            if (std.meta.eql(retained.plan, plan) and
                std.meta.eql(retained.terminal, terminal))
            {
                try loss_retirement.validateLossRetirementReceiptV1(
                    retained.receipt,
                    plan,
                    terminal,
                );
                return retained.receipt;
            }
            return Error.StaleObject;
        }
        const permit = self.loss_retirement_permit orelse
            return Error.InvalidConfiguration;
        try loss_retirement.validateLossRetirementPlanReplayV1(
            plan,
            permit.plan,
        );
        try self.requireLossRetirementQuiescedUnlocked();
        if (self.used_resource_bytes != 0 or
            self.observed_allocated_size_bytes != 0 or
            !digestIsZero(self.active_admission_sha256) or
            permit.reference_release_count != plan.allocation_count)
            return Error.InvalidConfiguration;
        for (self.slots) |slot| if (slot.live or
            !slot.native_token.isZero())
            return Error.InvalidConfiguration;
        const backend_live_buffers = self.backend.liveBufferCount();
        const native_live_buffers =
            try self.backend.nativeLiveBufferCount();
        const native_live_commands =
            try self.backend.nativeLiveCommandCount();
        const backend_live_weights =
            self.backend.liveWeightCount();
        if (backend_live_buffers != 0 or
            native_live_buffers != 0 or
            native_live_commands != 0 or
            backend_live_weights != 0)
            return Error.InvalidConfiguration;
        const adapter_settlement_sha256 =
            lossRetirementSettlementRootV1(
                self,
                plan,
                terminal,
                permit.reference_release_count,
                backend_live_buffers,
                native_live_buffers,
                native_live_commands,
                backend_live_weights,
            );
        if (digestIsZero(adapter_settlement_sha256))
            return Error.InvalidConfiguration;
        const receipt =
            try loss_retirement.makeLossRetirementReceiptV1(
                plan,
                terminal,
                adapter_settlement_sha256,
                permit.reference_release_count,
            );
        self.loss_retirement_permit = null;
        self.loss_retirement_tombstone = .{
            .plan = plan,
            .terminal = terminal,
            .receipt = receipt,
        };
        return receipt;
    }

    fn requireLossRetirementQuiescedUnlocked(
        self: *MetalAllocationAdapterV1,
    ) Error!void {
        if (self.dispatch_unresolved or
            self.async_dispatch != null or
            self.async_quarantine != null or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.loss_dispatch_reconciliation_permit != null or
            self.prepared_matvec_request != null or
            self.reserved_dispatch_intent != null or
            self.bound_dispatch_pin != null or
            try self.backend.nativeLiveCommandCount() != 0)
            return Error.DispatchBusy;
    }

    fn bindAddressOrPanic(self: *MetalAllocationAdapterV1) void {
        const address = @intFromPtr(self);
        if (self.self_address == 0) {
            self.self_address = address;
        } else if (self.self_address != address) {
            @panic("Metal allocation adapter moved after interface binding");
        }
    }

    fn validateAddress(
        self: *MetalAllocationAdapterV1,
    ) Error!void {
        if (self.self_address == 0 or
            self.self_address != @intFromPtr(self))
            return Error.InvalidConfiguration;
    }

    fn armLossRetirementFromCoordinatorUnlocked(
        self: *MetalAllocationAdapterV1,
        context: MetalLossRetirementArmContextV1,
        retained_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) Error!void {
        try loss_retirement.validateLossRetirementPlanV1(
            context.plan,
            context.observation,
            context.transition,
            context.source_cursor,
            context.requirement,
            context.selection,
            context.prior_inventory,
            context.selected_entry,
            context.successor_entry,
            self.authority,
            retained_lease,
        );
        switch (context.mode) {
            .production => try loss_retirement
                .requireProductionEligibleLossRetirementPlanV1(
                context.plan,
                context.observation,
                context.transition,
            ),
            .synthetic_test => {
                if (comptime !metal_test_faults)
                    return metal.MetalError.Unavailable;
                if (context.plan.source != .test_injected or
                    context.plan.evidence_class != .synthetic or
                    context.observation.source != .test_injected or
                    context.observation.evidence_class != .synthetic or
                    context.transition.source != .test_injected or
                    context.transition.evidence_class != .synthetic or
                    loss_retirement
                        .lossRetirementPlanProductionEligibleV1(
                        context.plan,
                        context.observation,
                        context.transition,
                    ))
                    return Error.InvalidLossRetirementPlan;
            },
        }
        if (self.loss_retirement_permit) |retained| {
            if (retained.mode != context.mode or
                !std.meta.eql(retained.plan, context.plan) or
                !device.digestEqual(
                    retained.lease_sha256,
                    retained_lease.lease_sha256,
                ))
                return Error.DispatchBusy;
            if (context.mode == .production)
                _ = try metal_lifecycle
                    .validateStickyNativeLossForRetirementV1(
                    self.backend,
                    context.observation,
                );
            return;
        }
        if (self.loss_retirement_tombstone != null)
            return Error.StaleObject;
        try self.requireLossRetirementQuiescedUnlocked();
        try self.validateLossRetirementAdapterBindingUnlocked(
            context.plan,
            context.observation,
            context.selected_entry,
            retained_lease,
            retained_object_set,
            retained_calls,
            retained_objects,
        );
        var source_identity: metal.MetalDeviceLifecycleSourceIdentity = .{};
        if (context.mode == .production) {
            _ = try metal_lifecycle
                .validateStickyNativeLossForRetirementV1(
                self.backend,
                context.observation,
            );
            source_identity =
                self.backend.initialDeviceLifecycleSourceIdentity();
        }
        try self.backend.armLossRetirementFence(
            context.plan.allocation_count,
        );
        self.loss_retirement_permit = .{
            .plan = context.plan,
            .plan_sha256 = context.plan.plan_sha256,
            .lease_sha256 = retained_lease.lease_sha256,
            .authority_sha256 = self.authority.authority_sha256,
            .selected_capability_sha256 = self.authority.selected_capability_sha256,
            .device_sha256 = self.device_sha256,
            .placement_sha256 = self.placement_sha256,
            .source_instance_sha256 = context.observation.source_instance_sha256,
            .source_identity = source_identity,
            .minimum_event_sequence = context.observation.source_sequence,
            .mode = context.mode,
        };
    }

    fn validateLossRetirementAdapterBindingUnlocked(
        self: *MetalAllocationAdapterV1,
        plan: loss_retirement.LossRetirementPlanV1,
        observation: lifecycle.ObservationV1,
        selected_entry: device.DeviceInventoryEntryV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) Error!void {
        allocation.validateObjectSetForAdmissionRootV1(
            retained_object_set,
            lease.admission_sha256,
            self.authority.authority_sha256,
            lease.allocation_count,
            lease.materialized_bytes,
            retained_calls,
            retained_objects,
        ) catch return Error.InvalidConfiguration;
        const expected_challenge =
            lossRetirementAdapterChallengeRootV1(
                self,
                observation,
                lease,
            );
        if (!device.digestEqual(
            plan.adapter_challenge_sha256,
            expected_challenge,
        ) or !device.digestEqual(
            plan.allocation_authority_sha256,
            self.authority.authority_sha256,
        ) or !device.digestEqual(
            plan.allocation_lease_sha256,
            lease.lease_sha256,
        ) or !device.digestEqual(
            plan.selected_capability_sha256,
            self.authority.selected_capability_sha256,
        ) or !device.digestEqual(
            selected_entry.capability.device_sha256,
            self.device_sha256,
        ) or !device.digestEqual(
            selected_entry.capability.placement_sha256,
            self.placement_sha256,
        ) or !device.digestEqual(
            lease.admission_sha256,
            self.active_admission_sha256,
        ) or !device.digestEqual(
            lease.backend_object_set_sha256,
            retained_object_set.object_set_sha256,
        ) or retained_calls.len !=
            @as(usize, @intCast(lease.allocation_count)) or
            retained_objects.len != retained_calls.len or
            self.backend.liveWeightCount() != 0 or
            plan.allocation_count >
                @as(u64, @intCast(self.slots.len)))
            return Error.InvalidConfiguration;

        var live_count: u64 = 0;
        var live_bytes: u64 = 0;
        var observed_bytes: u64 = 0;
        var ordered_calls =
            [_]allocation.AllocationCallV1{.{}} **
            allocation.maximum_allocations;
        var ordered_objects =
            [_]allocation.BackendObjectV1{.{}} **
            allocation.maximum_allocations;
        var ordinal_seen =
            [_]bool{false} ** allocation.maximum_allocations;
        for (self.slots) |slot| {
            if (!slot.live) {
                if (!slot.native_token.isZero())
                    return Error.InvalidConfiguration;
                continue;
            }
            allocation.validateAllocationCallV1(slot.call) catch
                return Error.InvalidConfiguration;
            allocation.validateBackendObjectV1(
                slot.object,
                slot.call,
            ) catch return Error.InvalidConfiguration;
            if (slot.native_token.isZero() or
                !device.digestEqual(
                    slot.call.authority_sha256,
                    self.authority.authority_sha256,
                ) or !device.digestEqual(
                slot.call.admission_sha256,
                lease.admission_sha256,
            ) or slot.call.charged_bytes !=
                slot.object.allocated_bytes or
                slot.native_info.device_registry_id !=
                    self.limits.device_registry_id or
                slot.native_info.requested_length !=
                    slot.call.requested_bytes or
                slot.native_info.resource_length !=
                    slot.call.charged_bytes)
                return Error.InvalidConfiguration;
            const ordinal = std.math.cast(
                usize,
                slot.call.ordinal,
            ) orelse return Error.InvalidConfiguration;
            if (ordinal >=
                @as(usize, @intCast(plan.allocation_count)) or
                ordinal_seen[ordinal])
                return Error.InvalidConfiguration;
            ordinal_seen[ordinal] = true;
            ordered_calls[ordinal] = slot.call;
            ordered_objects[ordinal] = slot.object;
            live_count = std.math.add(u64, live_count, 1) catch
                return Error.InvalidConfiguration;
            live_bytes = std.math.add(
                u64,
                live_bytes,
                slot.call.charged_bytes,
            ) catch return Error.InvalidConfiguration;
            observed_bytes = std.math.add(
                u64,
                observed_bytes,
                slot.native_info.allocated_size,
            ) catch return Error.InvalidConfiguration;
        }
        if (live_count != plan.allocation_count or
            live_count != lease.allocation_count or
            live_bytes != plan.materialized_bytes or
            live_bytes != lease.materialized_bytes or
            live_bytes != self.used_resource_bytes or
            observed_bytes != self.observed_allocated_size_bytes or
            self.backend.liveBufferCount() != live_count or
            try self.backend.nativeLiveBufferCount() != live_count)
            return Error.InvalidConfiguration;
        const object_count: usize = @intCast(live_count);
        for (retained_calls, 0..) |call, ordinal|
            if (!std.meta.eql(call, ordered_calls[ordinal]) or
                !std.meta.eql(
                    retained_objects[ordinal],
                    ordered_objects[ordinal],
                ))
                return Error.InvalidConfiguration;
        const object_set =
            allocation.makeObjectSetForAdmissionRootV1(
                lease.admission_sha256,
                self.authority.authority_sha256,
                live_count,
                live_bytes,
                ordered_calls[0..object_count],
                ordered_objects[0..object_count],
            ) catch return Error.InvalidConfiguration;
        if (!std.meta.eql(object_set, retained_object_set) or
            !device.digestEqual(
                object_set.object_set_sha256,
                lease.backend_object_set_sha256,
            ) or !device.digestEqual(
            object_set.object_set_sha256,
            plan.backend_object_set_sha256,
        ))
            return Error.InvalidConfiguration;
    }

    /// Bind a LeaseTree dispatch pin to this exact native adapter and its
    /// single serial Metal queue. Terminal validation alone never clears the
    /// private authorization; only the post-Bank settlement callback does.
    pub fn dispatchInterface(
        self: *MetalAllocationAdapterV1,
    ) lease_tree.DispatchAdapterV1 {
        self.bindAddressOrPanic();
        return .{
            .context = self,
            .dispatch_authority_sha256 = self.dispatch_authority_sha256,
            .queue_authority_sha256 = self.queue_authority_sha256,
            .reserve_dispatch_intent_fn = reserveDispatchIntentCallback,
            .abort_dispatch_intent_fn = abortDispatchIntentCallback,
            .validate_terminal_fn = validateDispatchTerminalCallback,
            .confirm_settlement_fn = confirmDispatchSettlementCallback,
        };
    }

    /// Derive a non-authoritative challenge for the exact retained active pin
    /// and exact device-removed native command. The Coordinator owns the pin
    /// boundary throughout this call; this adapter is locked only from inside
    /// that boundary, preserving Coordinator -> adapter lock order.
    pub fn lossDispatchReconciliationAdapterChallengeV1(
        self: *MetalAllocationAdapterV1,
        coordinator: *lease_tree.CoordinatorV1,
        bound_adapter: lease_tree.DispatchAdapterV1,
        observation: lifecycle.ObservationV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
    ) Error!Digest {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        if (observation.abi_version != lifecycle.observation_abi or
            observation.observed_state != .lost or
            digestIsZero(observation.observation_sha256) or
            !device.digestEqual(
                observation.observation_sha256,
                lifecycle.observationRootV1(observation),
            ))
            return Error.InvalidObservation;
        try validateMetalAsyncDispatchTicketV1(ticket);
        var context: MetalLossDispatchReconciliationChallengeContextV1 = .{
            .adapter = self,
            .observation = observation,
            .ticket = ticket,
        };
        coordinator.withActiveDispatchReconciliationBindingV1(
            lease,
            pin,
            .{
                .context = &context,
                .dispatch_adapter = bound_adapter,
                .reconcile_fn = lossDispatchReconciliationChallengeCallback,
            },
        ) catch |err|
            return mapCoordinatorDispatchReconciliationError(err);
        return context.result orelse Error.InvalidConfiguration;
    }

    /// Authorize terminal failure for an exact native command-buffer
    /// device-removed event (status/domain/code 5/1/11). Every portable input
    /// is replayed again under the Coordinator's active-pin boundary before
    /// adapter-private terminal authority is retained.
    pub fn armLossDispatchReconciliationV1(
        self: *MetalAllocationAdapterV1,
        coordinator: *lease_tree.CoordinatorV1,
        bound_adapter: lease_tree.DispatchAdapterV1,
        plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
        retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
        observation: lifecycle.ObservationV1,
        transition: lifecycle.TransitionReceiptV1,
        source_cursor: lifecycle.SourceCursorV1,
        requirement: device.DeviceRequirementV1,
        selection: device.DeviceSelectionReceiptV1,
        prior_inventory: []const device.DeviceInventoryEntryV1,
        selected_entry: device.DeviceInventoryEntryV1,
        successor_entry: device.DeviceInventoryEntryV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
    ) Error!MetalAsyncDispatchTerminalFailureResultV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        try loss_dispatch_reconciliation
            .validateLossDispatchReconciliationPlanV1(
            plan,
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
        try loss_dispatch_reconciliation
            .requireProductionEligibleLossDispatchReconciliationPlanV1(
            plan,
            retention,
            observation,
            transition,
        );
        return self.armLossDispatchReconciliationAtBoundaryV1(
            coordinator,
            bound_adapter,
            .production,
            plan,
            retention,
            observation,
            transition,
            source_cursor,
            requirement,
            selection,
            prior_inventory,
            selected_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        );
    }

    /// Fault-build-only authorization over the same real Metal command and
    /// exact active pin. Only lifecycle evidence is synthetic; command
    /// ownership, quarantine, status/domain/code, and Bank ordering remain
    /// identical to production.
    pub fn armSyntheticLossDispatchReconciliationForTestV1(
        self: *MetalAllocationAdapterV1,
        coordinator: *lease_tree.CoordinatorV1,
        bound_adapter: lease_tree.DispatchAdapterV1,
        plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
        retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
        observation: lifecycle.ObservationV1,
        transition: lifecycle.TransitionReceiptV1,
        source_cursor: lifecycle.SourceCursorV1,
        requirement: device.DeviceRequirementV1,
        selection: device.DeviceSelectionReceiptV1,
        prior_inventory: []const device.DeviceInventoryEntryV1,
        selected_entry: device.DeviceInventoryEntryV1,
        successor_entry: device.DeviceInventoryEntryV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
    ) Error!MetalAsyncDispatchTerminalFailureResultV1 {
        if (comptime !metal_enabled or !metal_test_faults)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        try loss_dispatch_reconciliation
            .validateLossDispatchReconciliationPlanV1(
            plan,
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
        if (plan.source != .test_injected or
            plan.evidence_class != .synthetic or
            retention.source != .test_injected or
            retention.evidence_class != .synthetic or
            observation.source != .test_injected or
            observation.evidence_class != .synthetic or
            transition.source != .test_injected or
            transition.evidence_class != .synthetic or
            loss_dispatch_reconciliation
                .lossDispatchReconciliationPlanProductionEligibleV1(
                plan,
                retention,
                observation,
                transition,
            ))
            return Error.InvalidLossDispatchReconciliationPlan;
        return self.armLossDispatchReconciliationAtBoundaryV1(
            coordinator,
            bound_adapter,
            .synthetic_test,
            plan,
            retention,
            observation,
            transition,
            source_cursor,
            requirement,
            selection,
            prior_inventory,
            selected_entry,
            successor_entry,
            lease,
            pin,
            ticket,
        );
    }

    fn armLossDispatchReconciliationAtBoundaryV1(
        self: *MetalAllocationAdapterV1,
        coordinator: *lease_tree.CoordinatorV1,
        bound_adapter: lease_tree.DispatchAdapterV1,
        mode: LossDispatchReconciliationModeV1,
        plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
        retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
        observation: lifecycle.ObservationV1,
        transition: lifecycle.TransitionReceiptV1,
        source_cursor: lifecycle.SourceCursorV1,
        requirement: device.DeviceRequirementV1,
        selection: device.DeviceSelectionReceiptV1,
        prior_inventory: []const device.DeviceInventoryEntryV1,
        selected_entry: device.DeviceInventoryEntryV1,
        successor_entry: device.DeviceInventoryEntryV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
    ) Error!MetalAsyncDispatchTerminalFailureResultV1 {
        var context: MetalLossDispatchReconciliationArmContextV1 = .{
            .adapter = self,
            .mode = mode,
            .plan = plan,
            .retention = retention,
            .observation = observation,
            .transition = transition,
            .source_cursor = source_cursor,
            .requirement = requirement,
            .selection = selection,
            .prior_inventory = prior_inventory,
            .selected_entry = selected_entry,
            .successor_entry = successor_entry,
            .ticket = ticket,
        };
        coordinator.withActiveDispatchReconciliationBindingV1(
            lease,
            pin,
            .{
                .context = &context,
                .dispatch_adapter = bound_adapter,
                .reconcile_fn = lossDispatchReconciliationArmCallback,
            },
        ) catch |err|
            return mapCoordinatorDispatchReconciliationError(err);
        return context.result orelse Error.InvalidConfiguration;
    }

    /// Return the exact receipt retained by the post-Bank settlement callback.
    /// `completion` must be the successful Coordinator result; a plan,
    /// retention, or completion substitution cannot retrieve the tombstone.
    pub fn completeLossDispatchReconciliationV1(
        self: *MetalAllocationAdapterV1,
        plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
        retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
        completion: lease_tree.LeaseTreeDispatchCompletionV1,
    ) Error!loss_dispatch_reconciliation.LossDispatchReconciliationReceiptV1 {
        return (try self.currentLossDispatchReconciliationReceiptV1(
            plan,
            retention,
            completion,
        )) orelse Error.InvalidConfiguration;
    }

    /// Diagnostic exact replay. No receipt is returned unless all supplied
    /// evidence matches the retained post-settlement tombstone byte-for-byte.
    pub fn currentLossDispatchReconciliationReceiptV1(
        self: *MetalAllocationAdapterV1,
        plan: loss_dispatch_reconciliation.LossDispatchReconciliationPlanV1,
        retention: loss_dispatch_reconciliation.LossDispatchRetentionV1,
        completion: lease_tree.LeaseTreeDispatchCompletionV1,
    ) Error!?loss_dispatch_reconciliation.LossDispatchReconciliationReceiptV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try self.validateAddress();
        self.mutex.lock();
        defer self.mutex.unlock();
        const retained =
            self.loss_dispatch_reconciliation_tombstone orelse
            return null;
        if (!std.meta.eql(retained.plan, plan) or
            !std.meta.eql(retained.retention, retention) or
            !std.meta.eql(retained.completion, completion))
            return Error.StaleObject;
        try loss_dispatch_reconciliation
            .validateLossDispatchReconciliationReceiptV1(
            retained.receipt,
            plan,
            retention,
            retained.selected_entry,
            retained.lease,
            retained.pin,
            retained.terminal,
            completion,
        );
        return retained.receipt;
    }

    fn validateLossDispatchObjectBindingUnlocked(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        intent: lease_tree.DispatchPinIntentV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) Error!void {
        try self.validateAddress();
        try self.validateDispatchOwnershipBindingUnlocked(
            lease,
            pin,
        );
        lease_tree.validateDispatchPinForIntentV1(
            pin,
            intent,
        ) catch return Error.InvalidDispatchEvidence;
        allocation.validateObjectSetForAdmissionRootV1(
            retained_object_set,
            lease.admission_sha256,
            self.authority.authority_sha256,
            lease.allocation_count,
            lease.materialized_bytes,
            retained_calls,
            retained_objects,
        ) catch return Error.InvalidDispatchEvidence;
        const reserved_intent = self.reserved_dispatch_intent orelse
            return Error.InvalidDispatchEvidence;
        const bound_pin = self.bound_dispatch_pin orelse
            return Error.InvalidDispatchEvidence;
        if (!std.meta.eql(reserved_intent, intent) or
            !std.meta.eql(bound_pin, pin) or
            !device.digestEqual(
                retained_object_set.object_set_sha256,
                lease.backend_object_set_sha256,
            ) or retained_calls.len != 4 or
            retained_objects.len != retained_calls.len or
            !device.digestEqual(
                self.active_admission_sha256,
                lease.admission_sha256,
            ) or self.used_resource_bytes !=
            lease.materialized_bytes)
            return Error.InvalidDispatchEvidence;

        var seen = [_]bool{false} ** 4;
        var live_count: u64 = 0;
        var live_bytes: u64 = 0;
        var observed_bytes: u64 = 0;
        for (self.slots) |slot| {
            if (!slot.live) {
                if (!std.meta.eql(slot, MetalAllocationSlotV1{}))
                    return Error.InvalidDispatchEvidence;
                continue;
            }
            allocation.validateAllocationCallV1(
                slot.call,
            ) catch return Error.InvalidDispatchEvidence;
            allocation.validateBackendObjectV1(
                slot.object,
                slot.call,
            ) catch return Error.InvalidDispatchEvidence;
            const ordinal = std.math.cast(
                usize,
                slot.call.ordinal,
            ) orelse return Error.InvalidDispatchEvidence;
            if (ordinal >= seen.len or seen[ordinal] or
                slot.native_token.isZero() or
                slot.generation == 0 or
                slot.generation !=
                    slot.object.backend_object_generation or
                !std.meta.eql(
                    slot.call,
                    retained_calls[ordinal],
                ) or !std.meta.eql(
                slot.object,
                retained_objects[ordinal],
            ) or !device.digestEqual(
                slot.call.authority_sha256,
                self.authority.authority_sha256,
            ) or !device.digestEqual(
                slot.call.admission_sha256,
                lease.admission_sha256,
            ) or slot.native_info.device_registry_id !=
                self.limits.device_registry_id or
                slot.native_info.resource_length !=
                    slot.object.allocated_bytes)
                return Error.InvalidDispatchEvidence;
            seen[ordinal] = true;
            live_count = std.math.add(
                u64,
                live_count,
                1,
            ) catch return Error.InvalidDispatchEvidence;
            live_bytes = std.math.add(
                u64,
                live_bytes,
                slot.object.allocated_bytes,
            ) catch return Error.InvalidDispatchEvidence;
            observed_bytes = std.math.add(
                u64,
                observed_bytes,
                slot.native_info.allocated_size,
            ) catch return Error.InvalidDispatchEvidence;
        }
        for (seen) |present|
            if (!present)
                return Error.InvalidDispatchEvidence;
        if (live_count != lease.allocation_count or
            live_bytes != lease.materialized_bytes or
            live_bytes != self.used_resource_bytes or
            observed_bytes != self.observed_allocated_size_bytes)
            return Error.InvalidDispatchEvidence;
    }

    fn validateLossDispatchReconciliationSourceUnlocked(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        intent: lease_tree.DispatchPinIntentV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
        ticket: MetalAsyncDispatchTicketV1,
    ) Error!ValidatedLossDispatchReconciliationSourceV1 {
        try self.validateLossDispatchObjectBindingUnlocked(
            lease,
            pin,
            intent,
            retained_object_set,
            retained_calls,
            retained_objects,
        );
        const pending = self.async_dispatch orelse
            return Error.DispatchUnresolved;
        const quarantine = self.async_quarantine orelse
            return Error.DispatchUnresolved;
        const native_completion = pending.native_completion orelse
            return Error.DispatchUnresolved;
        if (!self.dispatch_unresolved or
            self.loss_retirement_permit != null or
            self.loss_retirement_tombstone != null or
            !std.meta.eql(pending.lease, lease) or
            !std.meta.eql(pending.pin, pin) or
            !std.meta.eql(pending.ticket, ticket) or
            !std.meta.eql(quarantine.ticket, ticket))
            return Error.InvalidDispatchEvidence;
        try validateMetalAsyncDispatchTicketForDispatchV1(
            ticket,
            pending.ticket.ticket_generation,
            pending.request,
            pin,
            pending.draft,
        );
        try validateMetalAsyncDispatchQuarantineForTicketV1(
            quarantine,
            ticket,
            self.device_sha256,
            self.placement_sha256,
        );
        const result = try makeMetalAsyncDispatchTerminalFailureV1(
            quarantine,
            pin,
            pending.draft,
            pending.native_submission,
            native_completion,
        );
        if (!lossDispatchNativeDeviceRemovedSourceValidV1(
            quarantine,
            native_completion,
            result.failure,
        ))
            return Error.InvalidDispatchEvidence;
        return .{
            .pending = pending,
            .intent = intent,
            .quarantine = quarantine,
            .native_completion = native_completion,
            .result = result,
        };
    }

    fn lossDispatchReconciliationChallengeUnlocked(
        self: *MetalAllocationAdapterV1,
        observation: lifecycle.ObservationV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        intent: lease_tree.DispatchPinIntentV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
        ticket: MetalAsyncDispatchTicketV1,
    ) Error!Digest {
        const source =
            try self.validateLossDispatchReconciliationSourceUnlocked(
                lease,
                pin,
                intent,
                retained_object_set,
                retained_calls,
                retained_objects,
                ticket,
            );
        switch (observation.source) {
            .command_buffer_device_removed => {
                if (observation.evidence_class != .native or
                    observation.native_command_status !=
                        lifecycle.command_buffer_status_error or
                    observation.native_error_domain_kind !=
                        lifecycle.command_buffer_error_domain or
                    observation.native_error_code_bits !=
                        lifecycle.command_buffer_device_removed_error)
                    return Error.InvalidObservation;
            },
            .test_injected => {
                if (comptime !metal_test_faults)
                    return metal.MetalError.Unavailable;
                if (observation.evidence_class != .synthetic)
                    return Error.InvalidObservation;
            },
            else => return Error.InvalidObservation,
        }
        return lossDispatchReconciliationAdapterChallengeRootV1(
            self,
            observation,
            lease,
            pin,
            intent,
            retained_object_set,
            source,
        );
    }

    fn armLossDispatchReconciliationFromCoordinatorUnlocked(
        self: *MetalAllocationAdapterV1,
        context: MetalLossDispatchReconciliationArmContextV1,
        retained_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        retained_pin: lease_tree.LeaseTreeDispatchPinV1,
        retained_intent: lease_tree.DispatchPinIntentV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) Error!MetalAsyncDispatchTerminalFailureResultV1 {
        try loss_dispatch_reconciliation
            .validateLossDispatchReconciliationPlanV1(
            context.plan,
            context.observation,
            context.transition,
            context.source_cursor,
            context.requirement,
            context.selection,
            context.prior_inventory,
            context.selected_entry,
            context.successor_entry,
            context.retention,
            retained_lease,
            retained_pin,
        );
        switch (context.mode) {
            .production => try loss_dispatch_reconciliation
                .requireProductionEligibleLossDispatchReconciliationPlanV1(
                context.plan,
                context.retention,
                context.observation,
                context.transition,
            ),
            .synthetic_test => {
                if (comptime !metal_test_faults)
                    return metal.MetalError.Unavailable;
                if (context.plan.source != .test_injected or
                    context.plan.evidence_class != .synthetic or
                    context.retention.source != .test_injected or
                    context.retention.evidence_class != .synthetic or
                    context.observation.source != .test_injected or
                    context.observation.evidence_class != .synthetic or
                    context.transition.source != .test_injected or
                    context.transition.evidence_class != .synthetic or
                    loss_dispatch_reconciliation
                        .lossDispatchReconciliationPlanProductionEligibleV1(
                        context.plan,
                        context.retention,
                        context.observation,
                        context.transition,
                    ))
                    return Error.InvalidLossDispatchReconciliationPlan;
            },
        }
        const source =
            try self.validateLossDispatchReconciliationSourceUnlocked(
                retained_lease,
                retained_pin,
                retained_intent,
                retained_object_set,
                retained_calls,
                retained_objects,
                context.ticket,
            );
        try loss_dispatch_reconciliation
            .validateLossDispatchRetentionV1(
            context.retention,
            context.selected_entry,
            retained_lease,
            retained_pin,
        );
        const expected_challenge =
            try self.lossDispatchReconciliationChallengeUnlocked(
                context.observation,
                retained_lease,
                retained_pin,
                retained_intent,
                retained_object_set,
                retained_calls,
                retained_objects,
                context.ticket,
            );
        if (!device.digestEqual(
            context.retention.adapter_challenge_sha256,
            expected_challenge,
        ) or !device.digestEqual(
            context.retention.submission_sha256,
            source.pending.draft.submission_sha256,
        ) or !device.digestEqual(
            context.retention.backend_quarantine_sha256,
            source.quarantine.quarantine_sha256,
        ) or !device.digestEqual(
            context.selected_entry.capability.device_sha256,
            self.device_sha256,
        ) or !device.digestEqual(
            context.selected_entry.capability.placement_sha256,
            self.placement_sha256,
        ) or !device.digestEqual(
            context.selected_entry.capability.capability_sha256,
            self.authority.selected_capability_sha256,
        ))
            return Error.InvalidDispatchEvidence;
        if (context.mode == .production)
            _ = try metal_lifecycle
                .validateStickyNativeLossForRetirementV1(
                self.backend,
                context.observation,
            );

        if (self.loss_dispatch_reconciliation_tombstone != null)
            return Error.StaleObject;
        if (self.loss_dispatch_reconciliation_permit) |retained| {
            if (retained.mode != context.mode or
                !std.meta.eql(retained.plan, context.plan) or
                !std.meta.eql(
                    retained.retention,
                    context.retention,
                ) or !std.meta.eql(
                retained.selected_entry,
                context.selected_entry,
            ) or !std.meta.eql(
                retained.lease,
                retained_lease,
            ) or !std.meta.eql(
                retained.pin,
                retained_pin,
            ) or !std.meta.eql(
                retained.failure,
                source.result.failure,
            ) or !std.meta.eql(
                retained.terminal,
                source.result.terminal,
            ))
                return Error.DispatchBusy;
            return source.result;
        }

        if (self.authorized_terminal) |authorized| {
            const failure = switch (authorized.evidence) {
                .terminal_failure => |value| value,
                .submitted,
                .rejected_before_submit,
                .cancelled_before_submit,
                => return Error.InvalidDispatchEvidence,
            };
            if (!std.meta.eql(authorized.pin, retained_pin) or
                !std.meta.eql(
                    authorized.request,
                    source.pending.request,
                ) or !std.meta.eql(
                authorized.terminal,
                source.result.terminal,
            ) or !std.meta.eql(
                failure,
                source.result.failure,
            ))
                return Error.InvalidDispatchEvidence;
        } else {
            self.authorized_terminal = .{
                .pin = retained_pin,
                .request = source.pending.request,
                .terminal = source.result.terminal,
                .evidence = .{
                    .terminal_failure = source.result.failure,
                },
            };
        }
        self.loss_dispatch_reconciliation_permit = .{
            .mode = context.mode,
            .plan = context.plan,
            .retention = context.retention,
            .selected_entry = context.selected_entry,
            .lease = retained_lease,
            .pin = retained_pin,
            .failure = source.result.failure,
            .terminal = source.result.terminal,
        };
        return source.result;
    }

    /// Prepare one replay-fenced request before acquiring a coordinator pin.
    /// Repeating the exact attempt in prepared-only state returns the same
    /// request. A different attempt or any intent/pin/terminal fence is
    /// rejected without mutation.
    pub fn prepareMatvecDispatchRequestV1(
        self: *MetalAllocationAdapterV1,
        attempt: MetalMatvecPreSubmitAttemptV1,
    ) Error!MetalMatvecDispatchRequestV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.prepareMatvecDispatchRequestUnlocked(
            attempt,
        );
    }

    /// Cancel one exact prepared-only request. Once a pin is bound or terminal
    /// work begins, cancellation is no longer an authority transition.
    pub fn cancelPreparedMatvecDispatchRequestV1(
        self: *MetalAllocationAdapterV1,
        request: MetalMatvecDispatchRequestV1,
    ) Error!void {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cancelPreparedMatvecDispatchRequestUnlocked(
            request,
        );
    }

    fn cancelPreparedMatvecDispatchRequestUnlocked(
        self: *MetalAllocationAdapterV1,
        request: MetalMatvecDispatchRequestV1,
    ) Error!void {
        try validateMetalMatvecDispatchRequestV1(request);
        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.loss_retirement_permit != null or
            self.loss_retirement_tombstone != null or
            self.reserved_dispatch_intent != null or
            self.bound_dispatch_pin != null)
            return Error.DispatchBusy;
        if (self.prepared_matvec_request) |prepared| {
            if (!std.meta.eql(prepared, request))
                return Error.DispatchBusy;
            self.prepared_matvec_request = null;
            self.cancelled_prepared_request = request;
            return;
        }
        if (self.cancelled_prepared_request) |cancelled| {
            if (std.meta.eql(cancelled, request))
                return;
        }
        return Error.StaleObject;
    }

    pub fn quote(
        self: *MetalAllocationAdapterV1,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        return quoteCallback(
            self,
            binding_sha256,
            requested_bytes,
        );
    }

    /// Submit one exact INT4 matvec without waiting for GPU completion.
    /// Successful replay of the same lease, pin, request, payload roots, and
    /// geometry returns the same ticket and never uploads or commits twice.
    /// A different request is rejected before native mutation while the one
    /// queue slot is occupied.
    pub fn submitMatvecInt4AsyncObserved(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        roles: MetalMatvecAllocationBindingsV1,
        packed_weights: []const u8,
        scales: []const f32,
        input: []const f32,
        output: []const f32,
        group_size: u32,
        in_features: u32,
        out_features: u32,
    ) Error!MetalAsyncDispatchTicketV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();

        const attempt = try makeMetalMatvecPreSubmitAttemptV1(
            roles,
            @intCast(packed_weights.len),
            @intCast(scales.len),
            @intCast(input.len),
            @intCast(output.len),
            group_size,
            in_features,
            out_features,
        );
        const packed_input_sha256 =
            matvecPackedWeightsInputRootV1(packed_weights);
        const scales_input_sha256 =
            matvecScalesInputRootV1(scales);
        const vector_input_sha256 =
            matvecVectorInputRootV1(input);
        if (digestIsZero(packed_input_sha256) or
            digestIsZero(scales_input_sha256) or
            digestIsZero(vector_input_sha256))
            return Error.InvalidDispatchEvidence;

        if (self.loss_retirement_permit != null or
            self.loss_retirement_tombstone != null)
            return Error.DispatchBusy;
        if (self.async_dispatch) |pending| {
            try validateMetalAsyncDispatchTicketForDispatchV1(
                pending.ticket,
                pending.ticket.ticket_generation,
                pending.request,
                pending.pin,
                pending.draft,
            );
            if (!std.meta.eql(pending.lease, lease) or
                !std.meta.eql(pending.pin, pin) or
                !std.meta.eql(
                    pending.request.attempt,
                    attempt,
                ) or !device.digestEqual(
                pending.draft.packed_weights_input_sha256,
                packed_input_sha256,
            ) or !device.digestEqual(
                pending.draft.scales_input_sha256,
                scales_input_sha256,
            ) or !device.digestEqual(
                pending.draft.vector_input_sha256,
                vector_input_sha256,
            ))
                return Error.DispatchBusy;
            return pending.ticket;
        }
        if (self.dispatch_unresolved or
            self.async_quarantine != null or
            self.authorized_terminal != null or
            self.terminal_validation_observed)
            return Error.DispatchBusy;
        if (self.settlement_tombstone) |settled| {
            if (std.meta.eql(settled.pin, pin))
                return Error.StaleObject;
        }

        const request =
            try self.requirePreparedMatvecRequestForPinUnlocked(
                pin,
                attempt,
            );
        const geometry = try makeMatvecGeometryV1(
            group_size,
            in_features,
            out_features,
        );
        if (@as(u64, @intCast(packed_weights.len)) !=
            geometry.packed_bytes or
            @as(u64, @intCast(scales.len)) !=
                geometry.scale_count or
            @as(u64, @intCast(input.len)) !=
                geometry.input_count or
            @as(u64, @intCast(output.len)) !=
                geometry.output_count)
            return Error.InvalidDispatchEvidence;

        const selected = try self.validateDispatchSetUnlocked(
            lease,
            pin,
            roles,
            geometry,
        );
        try self.bindPreparedMatvecRequestToPinUnlocked(
            request,
            pin,
        );

        var draft: MetalLeaseTreeDispatchObservationV1 = .{
            .dispatch_generation = pin.dispatch_generation,
            .allocation_count = pin.allocation_count,
            .materialized_bytes = pin.pinned_device_bytes,
            .authority_sha256 = pin.authority_sha256,
            .admission_sha256 = pin.admission_sha256,
            .lease_sha256 = pin.lease_sha256,
            .backend_object_set_sha256 = pin.backend_object_set_sha256,
            .pin_sha256 = pin.pin_sha256,
            .dispatch_request_sha256 = pin.dispatch_request_sha256,
            .dispatch_authority_sha256 = pin.dispatch_authority_sha256,
            .queue_authority_sha256 = pin.queue_authority_sha256,
            .geometry = geometry,
            .roles = selected.evidence,
            .packed_weights_input_sha256 = packed_input_sha256,
            .scales_input_sha256 = scales_input_sha256,
            .vector_input_sha256 = vector_input_sha256,
        };
        draft.submission_sha256 =
            dispatchSubmissionRootV1(draft);
        if (digestIsZero(draft.submission_sha256))
            return Error.InvalidDispatchEvidence;
        if (self.next_async_ticket_generation == 0 or
            self.next_async_ticket_generation ==
                std.math.maxInt(u64))
            return Error.GenerationExhausted;
        const ticket = try makeMetalAsyncDispatchTicketV1(
            self.next_async_ticket_generation,
            request,
            pin,
            draft,
        );

        // The backend returns an error only before its native commit boundary.
        // Once registry ownership exists it always returns a token, including
        // the explicitly ambiguous disposition.
        const native_submission =
            try self.backend.submitMatvecInt4RegisteredBuffers(
                ticket.ticket_sha256,
                selected.tokens[0],
                selected.tokens[1],
                selected.tokens[2],
                selected.tokens[3],
                packed_weights,
                scales,
                input,
                geometry.output_count,
                group_size,
                in_features,
                out_features,
            );
        self.next_async_ticket_generation += 1;
        self.dispatch_unresolved = true;
        self.async_dispatch = .{
            .lease = lease,
            .pin = pin,
            .request = request,
            .ticket = ticket,
            .draft = draft,
            .selected = selected,
            .native_submission = native_submission,
        };

        if (native_submission.disposition ==
            .submitted_or_ambiguous)
        {
            _ = try self.installAsyncQuarantineUnlocked(
                ticket,
                .submission_ambiguous,
                .commit_started,
                async_native_command_status_unobserved,
                0,
                .native_bridge,
                async_submission_ambiguous_adapter_code,
            );
            return ticket;
        }
        if (!device.digestEqual(
            packed_input_sha256,
            matvecPackedWeightsInputRootV1(packed_weights),
        ) or !device.digestEqual(
            scales_input_sha256,
            matvecScalesInputRootV1(scales),
        ) or !device.digestEqual(
            vector_input_sha256,
            matvecVectorInputRootV1(input),
        )) {
            _ = try self.installAsyncQuarantineUnlocked(
                ticket,
                .completion_unknown,
                .submitted,
                async_native_command_status_unobserved,
                0,
                .native_bridge,
                2,
            );
        }
        return ticket;
    }

    /// Non-blocking, level-triggered observation. Pending leaves `output`
    /// byte-for-byte unchanged. A completed result may be replayed before
    /// settlement and republishes the exact retained GPU output.
    pub fn pollMatvecInt4AsyncObserved(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
        output: []f32,
    ) Error!MetalAsyncDispatchPollV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.observeMatvecInt4AsyncUnlocked(
            lease,
            pin,
            ticket,
            output,
            false,
        );
    }

    /// Blocking counterpart to `pollMatvecInt4AsyncObserved`. It waits only
    /// for a normally submitted native command; an ambiguous submission is
    /// already sticky quarantine and is never waited as if commit were known.
    pub fn waitMatvecInt4AsyncObserved(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
        output: []f32,
    ) Error!MetalAsyncDispatchPollV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.observeMatvecInt4AsyncUnlocked(
            lease,
            pin,
            ticket,
            output,
            true,
        );
    }

    /// Copy the current public ticket without exposing the private native
    /// command token. This remains available when the synchronous
    /// compatibility wrapper reports an unresolved/quarantined command.
    pub fn currentAsyncDispatchTicket(
        self: *MetalAllocationAdapterV1,
    ) ?MetalAsyncDispatchTicketV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.async_dispatch) |pending|
            pending.ticket
        else
            null;
    }

    pub fn currentAsyncDispatchQuarantine(
        self: *MetalAllocationAdapterV1,
    ) ?MetalAsyncDispatchQuarantineV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.async_quarantine;
    }

    /// Convert one exact retained command-buffer error into core
    /// `terminal_failure` authority. The quarantine, native command, pin, and
    /// charge remain live until the coordinator confirms the matching Bank
    /// settlement through the adapter's private callback.
    ///
    /// Submission ambiguity, unknown completion, and invalid completion are
    /// intentionally not accepted here: those states still lack exact
    /// terminal authority and must remain quarantined.
    pub fn reconcileTerminalCommandFailureObserved(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
    ) Error!MetalAsyncDispatchTerminalFailureResultV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();

        const pending = self.async_dispatch orelse {
            if (self.settlement_tombstone) |settled| {
                if (std.meta.eql(settled.pin, pin))
                    return Error.StaleObject;
            }
            return Error.DispatchUnresolved;
        };
        try validateMetalAsyncDispatchTicketForDispatchV1(
            ticket,
            pending.ticket.ticket_generation,
            pending.request,
            pending.pin,
            pending.draft,
        );
        if (!self.dispatch_unresolved or
            !std.meta.eql(ticket, pending.ticket) or
            !std.meta.eql(lease, pending.lease) or
            !std.meta.eql(pin, pending.pin))
            return Error.InvalidDispatchEvidence;

        const quarantine = self.async_quarantine orelse
            return Error.DispatchUnresolved;
        try validateMetalAsyncDispatchQuarantineForTicketV1(
            quarantine,
            ticket,
            self.device_sha256,
            self.placement_sha256,
        );
        if (quarantine.reason != .terminal_command_error)
            return Error.DispatchUnresolved;
        const native_completion =
            pending.native_completion orelse
            return Error.InvalidDispatchEvidence;

        if (self.authorized_terminal) |authorized| {
            if (!std.meta.eql(authorized.pin, pin) or
                !std.meta.eql(
                    authorized.request,
                    pending.request,
                ))
                return Error.InvalidDispatchEvidence;
            const failure = switch (authorized.evidence) {
                .terminal_failure => |value| value,
                .submitted,
                .rejected_before_submit,
                .cancelled_before_submit,
                => return Error.InvalidDispatchEvidence,
            };
            try validateMetalAsyncDispatchTerminalFailureForDispatchV1(
                failure,
                pin,
                pending.draft,
                pending.native_submission,
                native_completion,
                authorized.terminal,
            );
            return .{
                .failure = failure,
                .terminal = authorized.terminal,
            };
        }

        const result =
            try makeMetalAsyncDispatchTerminalFailureV1(
                quarantine,
                pin,
                pending.draft,
                pending.native_submission,
                native_completion,
            );
        self.authorized_terminal = .{
            .pin = pin,
            .request = pending.request,
            .terminal = result.terminal,
            .evidence = .{
                .terminal_failure = result.failure,
            },
        };
        return result;
    }

    /// Synchronous compatibility wrapper over the single native async path.
    /// Native ownership still remains live after this method returns success;
    /// only the coordinator's private post-Bank callback finalizes it.
    pub fn dispatchMatvecInt4Observed(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        roles: MetalMatvecAllocationBindingsV1,
        packed_weights: []const u8,
        scales: []const f32,
        input: []const f32,
        output: []f32,
        group_size: u32,
        in_features: u32,
        out_features: u32,
    ) Error!MetalLeaseTreeDispatchResultV1 {
        const ticket = try self.submitMatvecInt4AsyncObserved(
            lease,
            pin,
            roles,
            packed_weights,
            scales,
            input,
            output,
            group_size,
            in_features,
            out_features,
        );
        const observed = try self.waitMatvecInt4AsyncObserved(
            lease,
            pin,
            ticket,
            output,
        );
        return switch (observed) {
            .completed => |result| result,
            .pending, .quarantined => Error.DispatchUnresolved,
        };
    }

    fn installAsyncQuarantineUnlocked(
        self: *MetalAllocationAdapterV1,
        ticket: MetalAsyncDispatchTicketV1,
        reason: MetalAsyncDispatchQuarantineReasonV1,
        native_disposition: MetalAsyncNativeDispositionV1,
        native_command_status: u64,
        native_completion_observed: u64,
        error_domain_kind: MetalAsyncErrorDomainKindV1,
        error_code_bits: u64,
    ) Error!MetalAsyncDispatchQuarantineV1 {
        const pending = self.async_dispatch orelse
            return Error.InvalidDispatchEvidence;
        try validateMetalAsyncDispatchTicketForDispatchV1(
            ticket,
            pending.ticket.ticket_generation,
            pending.request,
            pending.pin,
            pending.draft,
        );
        if (!std.meta.eql(ticket, pending.ticket))
            return Error.InvalidDispatchEvidence;
        if (self.async_quarantine) |retained| {
            try validateMetalAsyncDispatchQuarantineForTicketV1(
                retained,
                ticket,
                self.device_sha256,
                self.placement_sha256,
            );
            return retained;
        }
        const quarantine =
            try makeMetalAsyncDispatchQuarantineV1(
                ticket,
                self.device_sha256,
                self.placement_sha256,
                reason,
                native_disposition,
                native_command_status,
                native_completion_observed,
                error_domain_kind,
                error_code_bits,
            );
        self.async_quarantine = quarantine;
        return quarantine;
    }

    fn installTerminalCommandErrorQuarantineUnlocked(
        self: *MetalAllocationAdapterV1,
        ticket: MetalAsyncDispatchTicketV1,
        native_completion: metal.MetalAsyncCompletion,
    ) Error!MetalAsyncDispatchQuarantineV1 {
        const pending = self.async_dispatch orelse
            return Error.InvalidDispatchEvidence;
        metal.validateMetalAsyncSubmission(
            pending.native_submission,
        ) catch return Error.InvalidDispatchEvidence;
        metal.validateMetalAsyncCompletion(
            native_completion,
        ) catch return Error.InvalidDispatchEvidence;
        const native_error_bits: u64 =
            @bitCast(native_completion.error_code);
        if (native_completion.state != .@"error" or
            native_completion.command_status !=
                async_native_command_status_error or
            native_completion.error_present != 1 or
            native_completion.callback_fault != 0 or
            native_completion.error_domain_kind !=
                .command_buffer or
            native_error_bits == 0 or
            !std.meta.eql(
                pending.native_submission.token,
                native_completion.token,
            ) or
            !std.mem.eql(
                u8,
                &pending.native_submission
                    .submission_binding,
                &native_completion.submission_binding,
            ) or
            !std.mem.eql(
                u8,
                &pending.native_submission
                    .submission_binding,
                &ticket.ticket_sha256,
            ))
            return Error.InvalidDispatchEvidence;

        if (pending.native_completion) |exact| {
            if (!std.meta.eql(exact, native_completion))
                return Error.InvalidDispatchEvidence;
        }
        const quarantine =
            try self.installAsyncQuarantineUnlocked(
                ticket,
                .terminal_command_error,
                .terminal_status_observed,
                native_completion.command_status,
                1,
                .command_buffer,
                native_error_bits,
            );
        if (quarantine.reason != .terminal_command_error or
            quarantine.error_code_bits != native_error_bits)
            return Error.InvalidDispatchEvidence;
        if (self.async_dispatch) |*retained| {
            if (retained.native_completion == null)
                retained.native_completion = native_completion;
        } else return Error.InvalidDispatchEvidence;
        return quarantine;
    }

    fn observeMatvecInt4AsyncUnlocked(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        ticket: MetalAsyncDispatchTicketV1,
        output: []f32,
        wait_for_completion: bool,
    ) Error!MetalAsyncDispatchPollV1 {
        const pending = self.async_dispatch orelse {
            if (self.settlement_tombstone) |settled| {
                if (std.meta.eql(settled.pin, pin))
                    return Error.StaleObject;
            }
            return Error.DispatchUnresolved;
        };
        try validateMetalAsyncDispatchTicketForDispatchV1(
            ticket,
            pending.ticket.ticket_generation,
            pending.request,
            pending.pin,
            pending.draft,
        );
        if (!self.dispatch_unresolved or
            !std.meta.eql(ticket, pending.ticket) or
            !std.meta.eql(lease, pending.lease) or
            !std.meta.eql(pin, pending.pin) or
            @as(u64, @intCast(output.len)) !=
                pending.draft.geometry.output_count)
            return Error.InvalidDispatchEvidence;

        if (self.async_quarantine) |quarantine| {
            try validateMetalAsyncDispatchQuarantineForTicketV1(
                quarantine,
                ticket,
                self.device_sha256,
                self.placement_sha256,
            );
            return .{ .quarantined = quarantine };
        }
        if (self.authorized_terminal) |authorized| {
            const observation = switch (authorized.evidence) {
                .submitted => |value| value,
                .terminal_failure,
                .rejected_before_submit,
                .cancelled_before_submit,
                => return Error.InvalidDispatchEvidence,
            };
            const native_completion =
                pending.native_completion orelse
                return Error.InvalidDispatchEvidence;
            try self.backend.readMatvecInt4RegisteredOutput(
                pending.native_submission,
                native_completion,
                pending.selected.tokens[3],
                output,
            );
            if (!device.digestEqual(
                observation.output_sha256,
                matvecOutputRootV1(output),
            ))
                return Error.InvalidDispatchEvidence;
            try validateMetalLeaseTreeDispatchObservationForPinV1(
                observation,
                pending.pin,
                authorized.terminal,
            );
            try metal.validateMetalAsyncCompletion(
                native_completion,
            );
            return .{ .completed = .{
                .observation = observation,
                .terminal = authorized.terminal,
            } };
        }

        const native_completion =
            (if (wait_for_completion)
                self.backend.waitRegisteredDispatch(
                    pending.native_submission,
                )
            else
                self.backend.pollRegisteredDispatch(
                    pending.native_submission,
                )) catch {
                const quarantine =
                    try self.installAsyncQuarantineUnlocked(
                        ticket,
                        .completion_unknown,
                        .submitted,
                        async_native_command_status_unobserved,
                        0,
                        .native_bridge,
                        3,
                    );
                return .{ .quarantined = quarantine };
            };

        switch (native_completion.state) {
            .pending => return .pending,
            .unknown => {
                const native_error_bits: u64 =
                    @bitCast(native_completion.error_code);
                const quarantine =
                    try self.installAsyncQuarantineUnlocked(
                        ticket,
                        .completion_unknown,
                        .submitted,
                        native_completion.command_status,
                        1,
                        .native_bridge,
                        if (native_error_bits != 0)
                            native_error_bits
                        else
                            3,
                    );
                return .{ .quarantined = quarantine };
            },
            .@"error" => {
                const native_error_bits: u64 =
                    @bitCast(native_completion.error_code);
                const native_submission_valid = blk: {
                    metal.validateMetalAsyncSubmission(
                        pending.native_submission,
                    ) catch break :blk false;
                    break :blk true;
                };
                const native_completion_valid = blk: {
                    metal.validateMetalAsyncCompletion(
                        native_completion,
                    ) catch break :blk false;
                    break :blk true;
                };
                const exact_command_error =
                    native_submission_valid and
                    native_completion_valid and
                    native_completion.error_present == 1 and
                    native_completion.callback_fault == 0 and
                    native_completion.command_status ==
                        async_native_command_status_error and
                    native_completion.error_domain_kind ==
                        .command_buffer and
                    native_error_bits != 0 and
                    std.meta.eql(
                        pending.native_submission.token,
                        native_completion.token,
                    ) and
                    std.mem.eql(
                        u8,
                        &pending.native_submission
                            .submission_binding,
                        &native_completion.submission_binding,
                    ) and
                    std.mem.eql(
                        u8,
                        &pending.native_submission
                            .submission_binding,
                        &ticket.ticket_sha256,
                    );
                const quarantine = if (exact_command_error)
                    try self.installTerminalCommandErrorQuarantineUnlocked(
                        ticket,
                        native_completion,
                    )
                else
                    try self.installAsyncQuarantineUnlocked(
                        ticket,
                        .completion_unknown,
                        .submitted,
                        native_completion.command_status,
                        1,
                        .native_bridge,
                        if (native_error_bits != 0)
                            native_error_bits
                        else
                            4,
                    );
                return .{ .quarantined = quarantine };
            },
            .completed => {},
            _ => {
                const quarantine =
                    try self.installAsyncQuarantineUnlocked(
                        ticket,
                        .completion_unknown,
                        .submitted,
                        native_completion.command_status,
                        1,
                        .native_bridge,
                        3,
                    );
                return .{ .quarantined = quarantine };
            },
        }

        const telemetry =
            metal.telemetryForAsyncCompletion(
                native_completion,
            ) catch {
                const quarantine =
                    try self.installAsyncQuarantineUnlocked(
                        ticket,
                        .invalid_completion,
                        .terminal_status_observed,
                        async_native_command_status_completed,
                        1,
                        .completion_validation,
                        5,
                    );
                return .{ .quarantined = quarantine };
            };
        self.backend.readMatvecInt4RegisteredOutput(
            pending.native_submission,
            native_completion,
            pending.selected.tokens[3],
            output,
        ) catch {
            const quarantine =
                try self.installAsyncQuarantineUnlocked(
                    ticket,
                    .invalid_completion,
                    .terminal_status_observed,
                    async_native_command_status_completed,
                    1,
                    .completion_validation,
                    6,
                );
            return .{ .quarantined = quarantine };
        };

        var observation = pending.draft;
        observation.telemetry = telemetry;
        observation.telemetry_sha256 =
            dispatchTelemetryRootV1(telemetry);
        observation.backend_completion_sha256 =
            dispatchBackendCompletionRootV1(
                observation.submission_sha256,
                observation.telemetry_sha256,
            );
        observation.output_sha256 =
            matvecOutputRootV1(output);
        const terminal = lease_tree.makeDispatchTerminalV1(
            pin,
            .succeeded,
            observation.submission_sha256,
            observation.backend_completion_sha256,
            observation.output_sha256,
        ) catch {
            const quarantine =
                try self.installAsyncQuarantineUnlocked(
                    ticket,
                    .invalid_completion,
                    .terminal_status_observed,
                    async_native_command_status_completed,
                    1,
                    .completion_validation,
                    7,
                );
            return .{ .quarantined = quarantine };
        };
        observation.terminal_sha256 =
            terminal.terminal_sha256;
        observation.observation_sha256 =
            metalDispatchObservationRootV1(observation);
        validateMetalLeaseTreeDispatchObservationForPinV1(
            observation,
            pin,
            terminal,
        ) catch {
            const quarantine =
                try self.installAsyncQuarantineUnlocked(
                    ticket,
                    .invalid_completion,
                    .terminal_status_observed,
                    async_native_command_status_completed,
                    1,
                    .completion_validation,
                    8,
                );
            return .{ .quarantined = quarantine };
        };

        if (self.async_dispatch) |*retained|
            retained.native_completion = native_completion
        else
            return Error.InvalidDispatchEvidence;
        self.authorized_terminal = .{
            .pin = pin,
            .request = pending.request,
            .terminal = terminal,
            .evidence = .{ .submitted = observation },
        };
        return .{ .completed = .{
            .observation = observation,
            .terminal = terminal,
        } };
    }

    /// Authorize abandonment of one exact acquired request before native
    /// submission. This path depends only on sealed lease/pin/request/intent
    /// bindings: it performs no live device inspection, constructs or submits
    /// no command buffer, and never establishes native queue ownership. The
    /// pin remains fenced until the coordinator's private settlement callback
    /// confirms the exact Bank release.
    pub fn cancelMatvecBeforeSubmitObserved(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
    ) Error!lease_tree.DispatchTerminalEvidenceV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.authorized_terminal) |authorized| {
            switch (authorized.evidence) {
                .cancelled_before_submit => |cancelled_request| {
                    if (std.meta.eql(authorized.pin, pin) and
                        std.meta.eql(
                            cancelled_request,
                            authorized.request,
                        ))
                    {
                        const prepared =
                            try self.requirePreparedMatvecRequestForPinUnlocked(
                                pin,
                                cancelled_request.attempt,
                            );
                        if (!std.meta.eql(
                            prepared,
                            cancelled_request,
                        ))
                            return Error.InvalidDispatchEvidence;
                        try self.validateDispatchOwnershipBindingUnlocked(
                            lease,
                            pin,
                        );
                        try validateMetalMatvecCancellationForPinV1(
                            cancelled_request,
                            pin,
                            authorized.terminal,
                        );
                        return authorized.terminal;
                    }
                },
                .submitted,
                .terminal_failure,
                .rejected_before_submit,
                => {},
            }
            return Error.DispatchBusy;
        }
        if (self.dispatch_unresolved or
            self.terminal_validation_observed)
            return Error.DispatchBusy;
        if (self.settlement_tombstone) |settled| {
            if (std.meta.eql(settled.pin, pin))
                return Error.StaleObject;
        }

        const prepared = self.prepared_matvec_request orelse
            return Error.InvalidDispatchEvidence;
        const request =
            try self.requirePreparedMatvecRequestForPinUnlocked(
                pin,
                prepared.attempt,
            );
        if (!std.meta.eql(prepared, request))
            return Error.InvalidDispatchEvidence;
        try self.validateDispatchOwnershipBindingUnlocked(
            lease,
            pin,
        );
        try self.bindPreparedMatvecRequestToPinUnlocked(
            request,
            pin,
        );
        const terminal = lease_tree.makeDispatchTerminalV1(
            pin,
            .cancelled_before_submit,
            allocation.zero_digest,
            allocation.zero_digest,
            allocation.zero_digest,
        ) catch return Error.InvalidDispatchEvidence;
        try validateMetalMatvecCancellationForPinV1(
            request,
            pin,
            terminal,
        );

        self.dispatch_unresolved = true;
        self.authorized_terminal = .{
            .pin = pin,
            .request = request,
            .terminal = terminal,
            .evidence = .{
                .cancelled_before_submit = request,
            },
        };
        return terminal;
    }

    /// Authorize one exact malformed INT4 matvec attempt for the existing
    /// coordinator completion path without touching the native command queue.
    ///
    /// The caller must prepare the exact attempt, then acquire `pin` with the
    /// adapter-issued request root. A valid attempt returns
    /// `DispatchPreflightPassed` and leaves that exact request/pin bound for
    /// normal submission. Once authorized, allocation/free/new dispatch stay
    /// blocked until the private settlement callback confirms the exact Bank
    /// release.
    pub fn rejectMatvecInt4BeforeSubmitObserved(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        roles: MetalMatvecAllocationBindingsV1,
        packed_weights: []const u8,
        scales: []const f32,
        input: []const f32,
        output: []const f32,
        group_size: u32,
        in_features: u32,
        out_features: u32,
    ) Error!MetalMatvecPreSubmitRejectionResultV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();

        const attempt = try makeMetalMatvecPreSubmitAttemptV1(
            roles,
            @intCast(packed_weights.len),
            @intCast(scales.len),
            @intCast(input.len),
            @intCast(output.len),
            group_size,
            in_features,
            out_features,
        );
        if (self.authorized_terminal) |authorized| {
            switch (authorized.evidence) {
                .rejected_before_submit => |rejection| {
                    if (std.meta.eql(authorized.pin, pin) and
                        std.meta.eql(
                            rejection.request.attempt,
                            attempt,
                        ))
                        return .{
                            .rejection = rejection,
                            .terminal = authorized.terminal,
                        };
                },
                .submitted,
                .terminal_failure,
                .cancelled_before_submit,
                => {},
            }
            return Error.DispatchBusy;
        }
        if (self.dispatch_unresolved or
            self.terminal_validation_observed)
            return Error.DispatchBusy;
        if (self.settlement_tombstone) |settled| {
            if (std.meta.eql(settled.pin, pin))
                return Error.StaleObject;
        }
        const request =
            try self.requirePreparedMatvecRequestForPinUnlocked(
                pin,
                attempt,
            );

        // Prove that this exact pin still owns this adapter's complete live
        // object set before classifying any caller-controlled malformed
        // geometry, length, or role arguments as safe to reject.
        try self.validateDispatchOwnershipUnlocked(lease, pin);
        try self.bindPreparedMatvecRequestToPinUnlocked(
            request,
            pin,
        );

        var reason = try classifyStaticPreSubmitRejectionV1(
            attempt,
        );
        if (reason == null) {
            const geometry = try makeMatvecGeometryV1(
                group_size,
                in_features,
                out_features,
            );
            if (self.validateDispatchRolesUnlocked(
                roles,
                geometry,
            )) |_| {
                return Error.DispatchPreflightPassed;
            } else |_| {
                reason = .invalid_role_mapping;
            }
        }

        const terminal = lease_tree.makeDispatchTerminalV1(
            pin,
            .rejected_before_submit,
            allocation.zero_digest,
            allocation.zero_digest,
            allocation.zero_digest,
        ) catch return Error.InvalidDispatchEvidence;
        const rejection = try makeMetalMatvecPreSubmitRejectionV1(
            pin,
            request,
            reason.?,
            terminal,
        );
        try validateMetalMatvecPreSubmitRejectionForPinV1(
            rejection,
            pin,
            terminal,
        );

        // Native identity/allocation inspection may have occurred, but no
        // command buffer was constructed or submitted and no queue ownership
        // was established. Retain the same fail-closed allocation/free fence
        // until private settlement.
        self.dispatch_unresolved = true;
        self.authorized_terminal = .{
            .pin = pin,
            .request = request,
            .terminal = terminal,
            .evidence = .{
                .rejected_before_submit = rejection,
            },
        };
        return .{
            .rejection = rejection,
            .terminal = terminal,
        };
    }

    /// Compatibility acknowledgement. The private settlement callback is the
    /// only state transition; this method is an exact idempotent tombstone
    /// check and never clears adapter ownership.
    pub fn acknowledgeDispatchCompletion(
        self: *MetalAllocationAdapterV1,
        completion: lease_tree.LeaseTreeDispatchCompletionV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        lease_tree.validateDispatchCompletionV1(
            completion,
        ) catch return Error.InvalidDispatchEvidence;
        const settled = self.settlement_tombstone orelse
            return Error.DispatchUnresolved;
        if (!std.meta.eql(settled.completion, completion))
            return Error.DispatchUnresolved;
    }

    pub fn snapshot(
        self: *MetalAllocationAdapterV1,
    ) MetalAllocationSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var live_objects: usize = 0;
        for (self.slots) |slot| if (slot.live) {
            live_objects += 1;
        };
        return .{
            .authority_epoch = self.authority.authority_epoch,
            .adapter_instance = self.adapter_identity.adapter_instance,
            .device_registry_id = self.limits.device_registry_id,
            .used_resource_bytes = self.used_resource_bytes,
            .observed_allocated_size_bytes = self.observed_allocated_size_bytes,
            .live_objects = live_objects,
            .materialized_leases = @intFromBool(
                !digestIsZero(self.active_admission_sha256),
            ),
            .allocate_calls = self.allocate_calls,
            .free_calls = self.free_calls,
            .inspect_calls = self.inspect_calls,
        };
    }

    /// Copy current per-object evidence in allocation-call ordinal order.
    /// The returned values contain no Objective-C pointer or GPU address.
    pub fn copyLiveObservations(
        self: *MetalAllocationAdapterV1,
        out: []MetalAllocationObservationV1,
    ) Error!usize {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.loss_retirement_permit != null or
            self.loss_retirement_tombstone != null)
            return Error.DispatchBusy;
        var live_count: usize = 0;
        for (self.slots) |slot| if (slot.live) {
            live_count += 1;
        };
        if (out.len < live_count) return Error.BufferTooSmall;
        var copied: usize = 0;
        for (0..allocation.maximum_allocations) |ordinal| {
            for (self.slots, 0..) |*slot, slot_index| {
                if (!slot.live or slot.call.ordinal != ordinal)
                    continue;
                if (slot.native_token.isZero())
                    return Error.InvalidObservation;
                const info = self.backend.inspectBufferAllocation(
                    slot.native_token,
                ) catch return Error.InvalidObservation;
                if (!std.meta.eql(info, slot.native_info))
                    return Error.InvalidObservation;
                out[copied] = makeObservationV1(
                    self.authority,
                    @intCast(slot_index),
                    slot.*,
                    info,
                );
                try validateObservationV1(
                    out[copied],
                    self.authority,
                    self.limits.device_registry_id,
                );
                copied += 1;
                self.inspect_calls +|= 1;
            }
        }
        if (copied != live_count) return Error.InvalidObservation;
        return copied;
    }

    fn prepareMatvecDispatchRequestUnlocked(
        self: *MetalAllocationAdapterV1,
        attempt: MetalMatvecPreSubmitAttemptV1,
    ) Error!MetalMatvecDispatchRequestV1 {
        try validateMetalMatvecPreSubmitAttemptV1(attempt);
        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.loss_retirement_permit != null or
            self.loss_retirement_tombstone != null or
            self.reserved_dispatch_intent != null or
            self.bound_dispatch_pin != null)
            return Error.DispatchBusy;
        if (self.prepared_matvec_request) |prepared| {
            try validateMetalMatvecDispatchRequestV1(prepared);
            if (std.meta.eql(prepared.attempt, attempt))
                return prepared;
            return Error.DispatchBusy;
        }
        if (self.next_matvec_request_generation == 0 or
            self.next_matvec_request_generation ==
                std.math.maxInt(u64))
            return Error.GenerationExhausted;
        const request = try makeMetalMatvecDispatchRequestV1(
            self.next_matvec_request_generation,
            self.dispatch_authority_sha256,
            self.queue_authority_sha256,
            attempt,
        );
        self.next_matvec_request_generation += 1;
        self.prepared_matvec_request = request;
        return request;
    }

    fn requirePreparedMatvecRequestForPinUnlocked(
        self: *MetalAllocationAdapterV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        attempt: MetalMatvecPreSubmitAttemptV1,
    ) Error!MetalMatvecDispatchRequestV1 {
        try lease_tree.validateDispatchPinV1(pin);
        try validateMetalMatvecPreSubmitAttemptV1(attempt);
        const request = self.prepared_matvec_request orelse
            return Error.InvalidDispatchEvidence;
        const intent = self.reserved_dispatch_intent orelse
            return Error.InvalidDispatchEvidence;
        try validateMetalMatvecDispatchRequestV1(request);
        if (!std.meta.eql(request.attempt, attempt) or
            !device.digestEqual(
                request.dispatch_authority_sha256,
                self.dispatch_authority_sha256,
            ) or !device.digestEqual(
            request.queue_authority_sha256,
            self.queue_authority_sha256,
        ) or !device.digestEqual(
            request.dispatch_authority_sha256,
            pin.dispatch_authority_sha256,
        ) or !device.digestEqual(
            request.queue_authority_sha256,
            pin.queue_authority_sha256,
        ) or !device.digestEqual(
            request.request_sha256,
            pin.dispatch_request_sha256,
        ))
            return Error.InvalidDispatchEvidence;
        if (self.bound_dispatch_pin) |bound| {
            if (!std.meta.eql(bound, pin))
                return Error.InvalidDispatchEvidence;
        }
        lease_tree.validateDispatchPinForIntentV1(
            pin,
            intent,
        ) catch return Error.InvalidDispatchEvidence;
        return request;
    }

    fn bindPreparedMatvecRequestToPinUnlocked(
        self: *MetalAllocationAdapterV1,
        request: MetalMatvecDispatchRequestV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
    ) Error!void {
        const prepared =
            try self.requirePreparedMatvecRequestForPinUnlocked(
                pin,
                request.attempt,
            );
        if (!std.meta.eql(prepared, request))
            return Error.InvalidDispatchEvidence;
        if (self.bound_dispatch_pin) |bound| {
            if (!std.meta.eql(bound, pin))
                return Error.InvalidDispatchEvidence;
            return;
        }
        self.bound_dispatch_pin = pin;
    }

    fn validateDispatchSetUnlocked(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        bindings: MetalMatvecAllocationBindingsV1,
        geometry: MetalMatvecGeometryV1,
    ) Error!ValidatedMatvecDispatchSetV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try self.validateDispatchOwnershipUnlocked(
            lease,
            pin,
        );
        return self.validateDispatchRolesUnlocked(
            bindings,
            geometry,
        );
    }

    fn validateDispatchOwnershipBindingUnlocked(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
    ) Error!void {
        try lease_tree.validateLeaseV1(lease);
        try lease_tree.validateDispatchPinV1(pin);
        if (lease.allocation_count != 4 or
            pin.allocation_count != 4 or
            !device.digestEqual(
                lease.authority_sha256,
                self.authority.authority_sha256,
            ) or !device.digestEqual(
            pin.authority_sha256,
            self.authority.authority_sha256,
        ) or lease.coordinator_epoch !=
            pin.coordinator_epoch or
            lease.generation != pin.allocation_generation or
            !device.digestEqual(
                lease.request_sha256,
                pin.request_sha256,
            ) or !device.digestEqual(
            lease.admission_sha256,
            pin.admission_sha256,
        ) or !device.digestEqual(
            lease.lease_sha256,
            pin.lease_sha256,
        ) or !device.digestEqual(
            lease.parent_receipt_sha256,
            pin.parent_receipt_sha256,
        ) or !device.digestEqual(
            lease.allocation_leaf_set_sha256,
            pin.allocation_leaf_set_sha256,
        ) or !device.digestEqual(
            lease.backend_object_set_sha256,
            pin.backend_object_set_sha256,
        ) or lease.materialized_bytes !=
            pin.pinned_device_bytes or
            !std.meta.eql(lease.scope, pin.scope) or
            lease.materialized_tree.tree_key !=
                pin.pinned_tree.tree_key or
            lease.materialized_tree.identity_generation !=
                pin.pinned_tree.identity_generation or
            !std.meta.eql(
                lease.materialized_tree.parent,
                pin.pinned_tree.parent,
            ) or !device.digestEqual(
            pin.dispatch_authority_sha256,
            self.dispatch_authority_sha256,
        ) or !device.digestEqual(
            pin.queue_authority_sha256,
            self.queue_authority_sha256,
        ))
            return Error.InvalidDispatchEvidence;
    }

    fn validateDispatchOwnershipUnlocked(
        self: *MetalAllocationAdapterV1,
        lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
        pin: lease_tree.LeaseTreeDispatchPinV1,
    ) Error!void {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try lease_tree.validateLeaseV1(lease);
        try lease_tree.validateDispatchPinV1(pin);
        if (lease.allocation_count != 4 or
            pin.allocation_count != 4 or
            !device.digestEqual(
                lease.authority_sha256,
                self.authority.authority_sha256,
            ) or !device.digestEqual(
            pin.authority_sha256,
            self.authority.authority_sha256,
        ) or lease.coordinator_epoch !=
            pin.coordinator_epoch or
            lease.generation != pin.allocation_generation or
            !device.digestEqual(
                lease.request_sha256,
                pin.request_sha256,
            ) or !device.digestEqual(
            lease.admission_sha256,
            pin.admission_sha256,
        ) or !device.digestEqual(
            lease.lease_sha256,
            pin.lease_sha256,
        ) or !device.digestEqual(
            lease.parent_receipt_sha256,
            pin.parent_receipt_sha256,
        ) or !device.digestEqual(
            lease.allocation_leaf_set_sha256,
            pin.allocation_leaf_set_sha256,
        ) or !device.digestEqual(
            lease.backend_object_set_sha256,
            pin.backend_object_set_sha256,
        ) or lease.materialized_bytes !=
            pin.pinned_device_bytes or
            !std.meta.eql(lease.scope, pin.scope) or
            lease.materialized_tree.tree_key !=
                pin.pinned_tree.tree_key or
            lease.materialized_tree.identity_generation !=
                pin.pinned_tree.identity_generation or
            !std.meta.eql(
                lease.materialized_tree.parent,
                pin.pinned_tree.parent,
            ) or !device.digestEqual(
            pin.dispatch_authority_sha256,
            self.dispatch_authority_sha256,
        ) or !device.digestEqual(
            pin.queue_authority_sha256,
            self.queue_authority_sha256,
        ))
            return Error.InvalidDispatchEvidence;
        const fresh_limits = try self.backend.allocationLimits();
        const fresh_device_info = try self.backend.deviceInfo();
        try self.backend.requireInt4MatvecSupport();
        if (!std.meta.eql(fresh_limits, self.limits) or
            !device.digestEqual(
                native.deviceIdentityV1(fresh_device_info),
                self.device_sha256,
            ) or !device.digestEqual(
            native.placementIdentityV1(fresh_device_info),
            self.placement_sha256,
        ))
            return Error.InvalidDispatchEvidence;

        var calls: [allocation.maximum_allocations]allocation.AllocationCallV1 = undefined;
        var objects: [allocation.maximum_allocations]allocation.BackendObjectV1 = undefined;
        var seen =
            [_]bool{false} ** allocation.maximum_allocations;
        var live_count: u64 = 0;
        var live_bytes: u64 = 0;
        for (self.slots, 0..) |slot, slot_index| {
            if (!slot.live) {
                if (!std.meta.eql(
                    slot,
                    MetalAllocationSlotV1{},
                ))
                    return Error.InvalidDispatchEvidence;
                continue;
            }
            try allocation.validateAllocationCallV1(slot.call);
            try allocation.validateBackendObjectV1(
                slot.object,
                slot.call,
            );
            if (slot.native_token.isZero() or
                slot.generation == 0 or
                slot.generation !=
                    slot.object.backend_object_generation or
                slot.call.ordinal >= lease.allocation_count or
                !std.mem.eql(
                    u64,
                    &slot.native_token.context_nonce,
                    &self.adapter_identity.context_nonce,
                ) or !device.digestEqual(
                slot.object.backend_object_sha256,
                objectIdentityV1(
                    self.authority,
                    self.limits.device_registry_id,
                    @intCast(slot_index),
                    slot.generation,
                    slot.call.call_sha256,
                ),
            ) or
                !device.digestEqual(
                    slot.call.authority_sha256,
                    self.authority.authority_sha256,
                ) or !device.digestEqual(
                slot.call.admission_sha256,
                lease.admission_sha256,
            ))
                return Error.InvalidDispatchEvidence;
            const ordinal: usize =
                @intCast(slot.call.ordinal);
            if (seen[ordinal])
                return Error.InvalidDispatchEvidence;
            const fresh_info =
                try self.backend.inspectBufferAllocation(
                    slot.native_token,
                );
            if (!std.meta.eql(fresh_info, slot.native_info) or
                fresh_info.device_registry_id !=
                    self.limits.device_registry_id or
                fresh_info.resource_length !=
                    slot.object.allocated_bytes)
                return Error.InvalidDispatchEvidence;
            seen[ordinal] = true;
            calls[ordinal] = slot.call;
            objects[ordinal] = slot.object;
            live_count += 1;
            live_bytes = std.math.add(
                u64,
                live_bytes,
                slot.object.allocated_bytes,
            ) catch return Error.InvalidDispatchEvidence;
        }
        if (live_count != lease.allocation_count or
            live_bytes != lease.materialized_bytes or
            live_bytes != self.used_resource_bytes or
            !device.digestEqual(
                self.active_admission_sha256,
                lease.admission_sha256,
            ))
            return Error.InvalidDispatchEvidence;
        for (seen[0..@intCast(live_count)]) |present| {
            if (!present)
                return Error.InvalidDispatchEvidence;
        }
        const object_set =
            try allocation.makeObjectSetForAdmissionRootV1(
                lease.admission_sha256,
                self.authority.authority_sha256,
                lease.allocation_count,
                lease.materialized_bytes,
                calls[0..@intCast(live_count)],
                objects[0..@intCast(live_count)],
            );
        if (!device.digestEqual(
            object_set.object_set_sha256,
            lease.backend_object_set_sha256,
        ))
            return Error.InvalidDispatchEvidence;
    }

    fn validateDispatchRolesUnlocked(
        self: *MetalAllocationAdapterV1,
        bindings: MetalMatvecAllocationBindingsV1,
        geometry: MetalMatvecGeometryV1,
    ) Error!ValidatedMatvecDispatchSetV1 {
        if (comptime !metal_enabled)
            return metal.MetalError.Unavailable;
        try validateMatvecGeometryV1(geometry);
        try validateMatvecBindingsV1(bindings);
        const role_bindings = [_]Digest{
            bindings.packed_weights_sha256,
            bindings.scales_sha256,
            bindings.input_sha256,
            bindings.output_sha256,
        };
        const expected_lengths = [_]u64{
            geometry.packed_bytes,
            geometry.scales_bytes,
            geometry.input_bytes,
            geometry.output_bytes,
        };
        var tokens: [4]metal.MetalBufferToken = undefined;
        var role_objects: [4]Digest = undefined;
        for (
            role_bindings,
            expected_lengths,
            0..,
        ) |binding_sha256, expected_length, role_index| {
            var found: ?usize = null;
            for (self.slots, 0..) |slot, slot_index| {
                if (slot.live and device.digestEqual(
                    slot.call.binding_sha256,
                    binding_sha256,
                )) {
                    if (found != null)
                        return Error.InvalidDispatchEvidence;
                    found = slot_index;
                }
            }
            const slot = self.slots[
                found orelse
                    return Error.InvalidDispatchEvidence
            ];
            if (slot.call.requested_bytes != expected_length or
                slot.call.charged_bytes != expected_length or
                slot.object.allocated_bytes != expected_length or
                slot.native_info.resource_length != expected_length)
                return Error.InvalidDispatchEvidence;
            tokens[role_index] = slot.native_token;
            role_objects[role_index] = slot.object.object_sha256;
        }
        for (tokens, 0..) |token, index| {
            for (tokens[0..index]) |prior| {
                if (std.meta.eql(token, prior))
                    return Error.InvalidDispatchEvidence;
            }
        }
        var evidence: MetalMatvecRoleEvidenceV1 = .{
            .bindings = bindings,
            .packed_weights_object_sha256 = role_objects[0],
            .scales_object_sha256 = role_objects[1],
            .input_object_sha256 = role_objects[2],
            .output_object_sha256 = role_objects[3],
        };
        evidence.roles_sha256 =
            matvecRoleEvidenceRootV1(evidence);
        try validateMatvecRoleEvidenceV1(evidence);
        return .{
            .tokens = tokens,
            .evidence = evidence,
        };
    }

    pub fn validateEmpty(
        self: *MetalAllocationAdapterV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.used_resource_bytes != 0 or
            self.observed_allocated_size_bytes != 0 or
            !digestIsZero(self.active_admission_sha256) or
            self.loss_dispatch_reconciliation_permit != null or
            self.loss_retirement_permit != null or
            self.dispatch_unresolved or
            self.async_dispatch != null or
            self.async_quarantine != null or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.prepared_matvec_request != null or
            self.reserved_dispatch_intent != null or
            self.bound_dispatch_pin != null)
            return Error.InvalidConfiguration;
        for (self.slots) |slot| if (slot.live or
            !slot.native_token.isZero())
            return Error.InvalidConfiguration;
    }

    fn reserveDispatchIntentCallback(
        context: *anyopaque,
        intent: lease_tree.DispatchPinIntentV1,
    ) lease_tree.DispatchCallbackError!void {
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.validateAddress() catch
            return lease_tree.DispatchCallbackError.Unavailable;
        lease_tree.validateDispatchPinIntentV1(
            intent,
        ) catch return lease_tree.DispatchCallbackError
            .InvalidDispatchIntent;
        const prepared = self.prepared_matvec_request orelse
            return lease_tree.DispatchCallbackError
                .InvalidDispatchIntent;
        validateMetalMatvecDispatchRequestV1(
            prepared,
        ) catch return lease_tree.DispatchCallbackError
            .InvalidDispatchIntent;
        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.loss_retirement_permit != null or
            self.loss_retirement_tombstone != null or
            self.bound_dispatch_pin != null or
            !device.digestEqual(
                prepared.request_sha256,
                intent.dispatch_request_sha256,
            ) or !device.digestEqual(
            prepared.dispatch_authority_sha256,
            intent.dispatch_authority_sha256,
        ) or !device.digestEqual(
            prepared.queue_authority_sha256,
            intent.queue_authority_sha256,
        ) or !device.digestEqual(
            self.dispatch_authority_sha256,
            intent.dispatch_authority_sha256,
        ) or !device.digestEqual(
            self.queue_authority_sha256,
            intent.queue_authority_sha256,
        ) or !device.digestEqual(
            self.authority.authority_sha256,
            intent.authority_sha256,
        ) or !device.digestEqual(
            self.active_admission_sha256,
            intent.admission_sha256,
        ) or intent.allocation_count != 4 or
            intent.pinned_device_bytes != self.used_resource_bytes)
            return lease_tree.DispatchCallbackError
                .InvalidDispatchIntent;
        if (self.reserved_dispatch_intent) |reserved| {
            if (std.meta.eql(reserved, intent))
                return;
            return lease_tree.DispatchCallbackError
                .InvalidDispatchIntent;
        }
        self.reserved_dispatch_intent = intent;
    }

    fn abortDispatchIntentCallback(
        context: *anyopaque,
        intent: lease_tree.DispatchPinIntentV1,
    ) lease_tree.DispatchCallbackError!void {
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        lease_tree.validateDispatchPinIntentV1(
            intent,
        ) catch return lease_tree.DispatchCallbackError
            .InvalidDispatchIntent;
        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.bound_dispatch_pin != null)
            return lease_tree.DispatchCallbackError
                .InvalidDispatchIntent;
        if (self.reserved_dispatch_intent) |reserved| {
            if (!std.meta.eql(reserved, intent))
                return lease_tree.DispatchCallbackError
                    .InvalidDispatchIntent;
            self.reserved_dispatch_intent = null;
            self.aborted_dispatch_intent = intent;
            return;
        }
        if (self.aborted_dispatch_intent) |aborted| {
            if (std.meta.eql(aborted, intent))
                return;
        }
        return lease_tree.DispatchCallbackError
            .InvalidDispatchIntent;
    }

    fn validateDispatchTerminalCallback(
        context: *anyopaque,
        terminal: lease_tree.DispatchTerminalEvidenceV1,
    ) lease_tree.DispatchCallbackError!void {
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        const authorized = self.authorized_terminal orelse
            return lease_tree.DispatchCallbackError
                .InvalidTerminalEvidence;
        const prepared =
            self.requirePreparedMatvecRequestForPinUnlocked(
                authorized.pin,
                authorized.request.attempt,
            ) catch return lease_tree.DispatchCallbackError
                .InvalidTerminalEvidence;
        const bound = self.bound_dispatch_pin orelse
            return lease_tree.DispatchCallbackError
                .InvalidTerminalEvidence;
        if (!self.dispatch_unresolved or
            !std.meta.eql(prepared, authorized.request) or
            !std.meta.eql(bound, authorized.pin) or
            !std.meta.eql(terminal, authorized.terminal))
            return lease_tree.DispatchCallbackError
                .InvalidTerminalEvidence;
        switch (authorized.evidence) {
            .submitted => |observation| {
                const pending = self.async_dispatch orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                const native_completion =
                    pending.native_completion orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                validateMetalAsyncDispatchTicketForDispatchV1(
                    pending.ticket,
                    pending.ticket.ticket_generation,
                    pending.request,
                    pending.pin,
                    pending.draft,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidTerminalEvidence;
                metal.validateMetalAsyncCompletion(
                    native_completion,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidTerminalEvidence;
                if (self.async_quarantine != null or
                    native_completion.state != .completed or
                    !std.meta.eql(pending.pin, authorized.pin) or
                    !std.meta.eql(
                        pending.request,
                        authorized.request,
                    ) or !device.digestEqual(
                    pending.draft.submission_sha256,
                    observation.submission_sha256,
                ))
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                validateMetalLeaseTreeDispatchObservationForPinV1(
                    observation,
                    authorized.pin,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidTerminalEvidence;
            },
            .terminal_failure => |failure| {
                const pending = self.async_dispatch orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                const quarantine = self.async_quarantine orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                const native_completion =
                    pending.native_completion orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                if (!std.meta.eql(
                    quarantine,
                    failure.quarantine,
                ) or
                    !std.meta.eql(
                        pending.pin,
                        authorized.pin,
                    ) or
                    !std.meta.eql(
                        pending.request,
                        authorized.request,
                    ))
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                validateMetalAsyncDispatchQuarantineForTicketV1(
                    quarantine,
                    pending.ticket,
                    self.device_sha256,
                    self.placement_sha256,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidTerminalEvidence;
                validateMetalAsyncDispatchTerminalFailureForDispatchV1(
                    failure,
                    authorized.pin,
                    pending.draft,
                    pending.native_submission,
                    native_completion,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidTerminalEvidence;
            },
            .rejected_before_submit => |rejection| {
                if (self.async_dispatch != null or
                    self.async_quarantine != null)
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                validateMetalMatvecPreSubmitRejectionForPinV1(
                    rejection,
                    authorized.pin,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidTerminalEvidence;
            },
            .cancelled_before_submit => |cancelled_request| {
                if (self.async_dispatch != null or
                    self.async_quarantine != null)
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                if (!std.meta.eql(
                    cancelled_request,
                    authorized.request,
                ))
                    return lease_tree.DispatchCallbackError
                        .InvalidTerminalEvidence;
                validateMetalMatvecCancellationForPinV1(
                    cancelled_request,
                    authorized.pin,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidTerminalEvidence;
            },
        }
        self.terminal_validation_observed = true;
    }

    fn confirmDispatchSettlementCallback(
        context: *anyopaque,
        pin: lease_tree.LeaseTreeDispatchPinV1,
        terminal: lease_tree.DispatchTerminalEvidenceV1,
        completion: lease_tree.LeaseTreeDispatchCompletionV1,
        bank_permit: resource.LeasePinPermitV1,
        bank_completion: resource.LeasePinCompletionV1,
    ) lease_tree.DispatchCallbackError!void {
        if (comptime !metal_enabled)
            return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.settlement_tombstone) |settled| {
            if (std.meta.eql(settled.pin, pin) and
                std.meta.eql(settled.terminal, terminal) and
                std.meta.eql(settled.completion, completion) and
                std.meta.eql(settled.bank_permit, bank_permit) and
                std.meta.eql(
                    settled.bank_completion,
                    bank_completion,
                ))
            {
                if (self.loss_dispatch_reconciliation_permit != null)
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                if (self.loss_dispatch_reconciliation_tombstone) |loss| {
                    if (!std.meta.eql(loss.pin, pin) or
                        !std.meta.eql(loss.terminal, terminal) or
                        !std.meta.eql(loss.completion, completion))
                        return lease_tree.DispatchCallbackError
                            .InvalidSettlementEvidence;
                    loss_dispatch_reconciliation
                        .validateLossDispatchReconciliationReceiptV1(
                        loss.receipt,
                        loss.plan,
                        loss.retention,
                        loss.selected_entry,
                        loss.lease,
                        loss.pin,
                        loss.terminal,
                        loss.completion,
                    ) catch return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                }
                return;
            }
        }
        const authorized = self.authorized_terminal orelse
            return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
        const prepared =
            self.requirePreparedMatvecRequestForPinUnlocked(
                authorized.pin,
                authorized.request.attempt,
            ) catch return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
        const bound = self.bound_dispatch_pin orelse
            return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
        if (!self.dispatch_unresolved or
            !self.terminal_validation_observed or
            !std.meta.eql(pin, authorized.pin) or
            !std.meta.eql(terminal, authorized.terminal) or
            !std.meta.eql(prepared, authorized.request) or
            !std.meta.eql(bound, authorized.pin))
            return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
        var native_finalize: ?struct {
            submission: metal.MetalAsyncSubmission,
            completion: metal.MetalAsyncCompletion,
        } = null;
        switch (authorized.evidence) {
            .submitted => |observation| {
                const pending = self.async_dispatch orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                const native_completion =
                    pending.native_completion orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                validateMetalAsyncDispatchTicketForDispatchV1(
                    pending.ticket,
                    pending.ticket.ticket_generation,
                    pending.request,
                    pending.pin,
                    pending.draft,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
                metal.validateMetalAsyncCompletion(
                    native_completion,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
                if (self.async_quarantine != null or
                    native_completion.state != .completed or
                    !std.meta.eql(pending.pin, pin) or
                    !std.meta.eql(
                        pending.request,
                        authorized.request,
                    ) or !device.digestEqual(
                    pending.draft.submission_sha256,
                    observation.submission_sha256,
                ))
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                validateMetalLeaseTreeDispatchObservationForPinV1(
                    observation,
                    pin,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
                native_finalize = .{
                    .submission = pending.native_submission,
                    .completion = native_completion,
                };
            },
            .terminal_failure => |failure| {
                const pending = self.async_dispatch orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                const quarantine = self.async_quarantine orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                const native_completion =
                    pending.native_completion orelse
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                if (!std.meta.eql(
                    quarantine,
                    failure.quarantine,
                ) or
                    !std.meta.eql(pending.pin, pin) or
                    !std.meta.eql(
                        pending.request,
                        authorized.request,
                    ))
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                validateMetalAsyncDispatchQuarantineForTicketV1(
                    quarantine,
                    pending.ticket,
                    self.device_sha256,
                    self.placement_sha256,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
                validateMetalAsyncDispatchTerminalFailureForDispatchV1(
                    failure,
                    pin,
                    pending.draft,
                    pending.native_submission,
                    native_completion,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
                native_finalize = .{
                    .submission = pending.native_submission,
                    .completion = native_completion,
                };
            },
            .rejected_before_submit => |rejection| {
                if (self.async_dispatch != null or
                    self.async_quarantine != null)
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                validateMetalMatvecPreSubmitRejectionForPinV1(
                    rejection,
                    pin,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
            },
            .cancelled_before_submit => |cancelled_request| {
                if (self.async_dispatch != null or
                    self.async_quarantine != null)
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                if (!std.meta.eql(
                    cancelled_request,
                    authorized.request,
                ))
                    return lease_tree.DispatchCallbackError
                        .InvalidSettlementEvidence;
                validateMetalMatvecCancellationForPinV1(
                    cancelled_request,
                    pin,
                    terminal,
                ) catch return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
            },
        }
        lease_tree.validateDispatchSettlementForPinV1(
            completion,
            pin,
            terminal,
            bank_permit,
            bank_completion,
        ) catch return lease_tree.DispatchCallbackError
            .InvalidSettlementEvidence;
        var loss_tombstone: ?MetalLossDispatchReconciliationTombstoneV1 = null;
        if (self.loss_dispatch_reconciliation_permit) |permit| {
            const loss_pending = self.async_dispatch orelse
                return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
            const failure = switch (authorized.evidence) {
                .terminal_failure => |value| value,
                .submitted,
                .rejected_before_submit,
                .cancelled_before_submit,
                => return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence,
            };
            if (!std.meta.eql(permit.pin, pin) or
                !std.meta.eql(permit.terminal, terminal) or
                !std.meta.eql(permit.failure, failure) or
                !std.meta.eql(permit.lease, loss_pending.lease))
                return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
            loss_dispatch_reconciliation
                .validateLossDispatchRetentionV1(
                permit.retention,
                permit.selected_entry,
                permit.lease,
                pin,
            ) catch return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
            const adapter_settlement_sha256 =
                lossDispatchReconciliationSettlementRootV1(
                    self,
                    permit,
                    completion,
                    bank_permit,
                    bank_completion,
                );
            if (digestIsZero(adapter_settlement_sha256))
                return lease_tree.DispatchCallbackError
                    .InvalidSettlementEvidence;
            const receipt = loss_dispatch_reconciliation
                .makeLossDispatchReconciliationReceiptV1(
                permit.plan,
                permit.retention,
                permit.selected_entry,
                permit.lease,
                permit.pin,
                permit.terminal,
                completion,
                adapter_settlement_sha256,
            ) catch return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
            loss_tombstone = .{
                .plan = permit.plan,
                .retention = permit.retention,
                .selected_entry = permit.selected_entry,
                .lease = permit.lease,
                .pin = permit.pin,
                .failure = permit.failure,
                .terminal = permit.terminal,
                .completion = completion,
                .receipt = receipt,
            };
        }
        if (native_finalize) |value|
            self.backend.finalizeRegisteredDispatch(
                value.submission,
                value.completion,
            ) catch return lease_tree.DispatchCallbackError
                .InvalidSettlementEvidence;
        self.settlement_tombstone = .{
            .pin = pin,
            .terminal = terminal,
            .completion = completion,
            .bank_permit = bank_permit,
            .bank_completion = bank_completion,
        };
        if (loss_tombstone) |retained| {
            self.loss_dispatch_reconciliation_tombstone =
                retained;
            self.loss_dispatch_reconciliation_permit = null;
        }
        self.async_dispatch = null;
        self.async_quarantine = null;
        self.authorized_terminal = null;
        self.dispatch_unresolved = false;
        self.terminal_validation_observed = false;
        self.prepared_matvec_request = null;
        self.reserved_dispatch_intent = null;
        self.bound_dispatch_pin = null;
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.quoteUnlocked(
            binding_sha256,
            requested_bytes,
        );
    }

    fn quoteUnlocked(
        self: *MetalAllocationAdapterV1,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        if (digestIsZero(binding_sha256) or
            requested_bytes == 0)
            return allocation.CallbackError.InvalidRequest;
        if (requested_bytes >
            self.authority.max_single_allocation_bytes or
            requested_bytes > self.limits.max_buffer_length)
            return allocation.CallbackError.CapacityExceeded;
        // Direct MTLBuffer.length is the exact requested byte count. Physical
        // occupied size is observed only after allocation and is not charged
        // through this V1 logical-resource contract.
        return allocation.makeQuoteV1(
            self.authority,
            binding_sha256,
            requested_bytes,
            requested_bytes,
        ) catch return allocation.CallbackError.InvalidRequest;
    }

    fn allocateCallback(
        context: *anyopaque,
        call: allocation.AllocationCallV1,
    ) allocation.CallbackError!allocation.BackendObjectV1 {
        if (comptime !metal_enabled)
            return allocation.CallbackError.Unavailable;
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.loss_retirement_permit != null or
            self.loss_retirement_tombstone != null or
            self.prepared_matvec_request != null or
            self.reserved_dispatch_intent != null or
            self.bound_dispatch_pin != null)
            return allocation.CallbackError.Unavailable;
        allocation.validateAllocationCallV1(call) catch
            return allocation.CallbackError.InvalidRequest;
        if (!device.digestEqual(
            call.authority_sha256,
            self.authority.authority_sha256,
        )) return allocation.CallbackError.InvalidRequest;
        const replayed_quote = try self.quoteUnlocked(
            call.binding_sha256,
            call.requested_bytes,
        );
        if (call.charged_bytes != replayed_quote.charged_bytes or
            !device.digestEqual(
                call.quote_sha256,
                replayed_quote.quote_sha256,
            ))
            return allocation.CallbackError.InvalidRequest;
        if (!digestIsZero(self.active_admission_sha256) and
            !device.digestEqual(
                self.active_admission_sha256,
                call.admission_sha256,
            ))
            return allocation.CallbackError.CapacityExceeded;
        for (self.slots) |slot| {
            if (slot.live and
                device.digestEqual(
                    slot.call.admission_sha256,
                    call.admission_sha256,
                ) and slot.call.ordinal == call.ordinal)
                return allocation.CallbackError.StaleObject;
        }
        const fresh_limits = self.backend.allocationLimits() catch
            return allocation.CallbackError.Unavailable;
        const fresh_info = self.backend.deviceInfo() catch
            return allocation.CallbackError.Unavailable;
        self.backend.requireInt4MatvecSupport() catch
            return allocation.CallbackError.Unavailable;
        if (!std.meta.eql(fresh_limits, self.limits) or
            !device.digestEqual(
                native.deviceIdentityV1(fresh_info),
                self.device_sha256,
            ) or
            !device.digestEqual(
                native.placementIdentityV1(fresh_info),
                self.placement_sha256,
            ))
            return allocation.CallbackError.Unavailable;
        const next_used = std.math.add(
            u64,
            self.used_resource_bytes,
            call.charged_bytes,
        ) catch return allocation.CallbackError.CapacityExceeded;
        if (next_used > self.authority.max_total_device_bytes)
            return allocation.CallbackError.CapacityExceeded;
        var free_slot: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (!slot.live and slot.native_token.isZero()) {
                free_slot = index;
                break;
            }
        }
        const slot_index = free_slot orelse
            return allocation.CallbackError.CapacityExceeded;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return allocation.CallbackError.Unavailable;

        self.allocate_calls +|= 1;
        const native_token = self.backend.createBufferAllocation(
            call.requested_bytes,
        ) catch return allocation.CallbackError.CapacityExceeded;
        errdefer self.backend.destroyBufferAllocation(
            native_token,
        ) catch @panic(
            "Metal adapter could not roll back a fresh native token",
        );
        const native_info = self.backend.inspectBufferAllocation(
            native_token,
        ) catch return allocation.CallbackError.Unavailable;
        if (native_info.device_registry_id !=
            self.limits.device_registry_id or
            native_info.requested_length != call.requested_bytes or
            native_info.resource_length != call.charged_bytes)
            return allocation.CallbackError.InvalidRequest;
        const next_observed = std.math.add(
            u64,
            self.observed_allocated_size_bytes,
            native_info.allocated_size,
        ) catch return allocation.CallbackError.CapacityExceeded;

        const generation = self.next_generation;
        const identity = objectIdentityV1(
            self.authority,
            self.limits.device_registry_id,
            @intCast(slot_index),
            generation,
            call.call_sha256,
        );
        var object: allocation.BackendObjectV1 = .{
            .allocation_call_sha256 = call.call_sha256,
            .binding_sha256 = call.binding_sha256,
            .backend_object_sha256 = identity,
            .backend_object_generation = generation,
            .allocated_bytes = native_info.resource_length,
        };
        object.object_sha256 =
            allocation.backendObjectRootV1(object);
        allocation.validateBackendObjectV1(object, call) catch
            return allocation.CallbackError.InvalidRequest;

        self.slots[slot_index] = .{
            .live = true,
            .generation = generation,
            .call = call,
            .object = object,
            .native_token = native_token,
            .native_info = native_info,
        };
        self.next_generation += 1;
        self.used_resource_bytes = next_used;
        self.observed_allocated_size_bytes = next_observed;
        self.active_admission_sha256 = call.admission_sha256;
        return object;
    }

    fn freeCallback(
        context: *anyopaque,
        object: allocation.BackendObjectV1,
    ) allocation.CallbackError!void {
        if (comptime !metal_enabled)
            return allocation.CallbackError.Unavailable;
        const self: *MetalAllocationAdapterV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.validateAddress() catch
            return allocation.CallbackError.Unavailable;
        // Prepared or bound request state is an ownership fence. Core's
        // private settlement callback clears it atomically with exact Bank
        // completion validation, so no caller-controlled handoff window can
        // free a command buffer's registered resources.
        if (self.dispatch_unresolved or
            self.authorized_terminal != null or
            self.terminal_validation_observed or
            self.prepared_matvec_request != null or
            self.reserved_dispatch_intent != null or
            self.bound_dispatch_pin != null)
            return allocation.CallbackError.Unavailable;
        self.free_calls +|= 1;

        var found: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.live and
                slot.generation ==
                    object.backend_object_generation and
                std.meta.eql(slot.object, object))
            {
                found = index;
                break;
            }
        }
        const index = found orelse
            return allocation.CallbackError.StaleObject;
        const slot = &self.slots[index];
        allocation.validateBackendObjectV1(
            object,
            slot.call,
        ) catch return allocation.CallbackError.InvalidRequest;
        const native_token = slot.native_token;
        if (native_token.isZero())
            return allocation.CallbackError.Unavailable;
        if (self.loss_retirement_permit) |permit| {
            if (!device.digestEqual(
                permit.plan_sha256,
                permit.plan.plan_sha256,
            ) or !device.digestEqual(
                permit.lease_sha256,
                permit.plan.allocation_lease_sha256,
            ) or !device.digestEqual(
                permit.authority_sha256,
                self.authority.authority_sha256,
            ) or !device.digestEqual(
                permit.selected_capability_sha256,
                self.authority.selected_capability_sha256,
            ) or !device.digestEqual(
                permit.device_sha256,
                self.device_sha256,
            ) or !device.digestEqual(
                permit.placement_sha256,
                self.placement_sha256,
            ) or !device.digestEqual(
                permit.source_instance_sha256,
                permit.plan.source_instance_sha256,
            ) or !device.digestEqual(
                slot.call.admission_sha256,
                self.active_admission_sha256,
            ) or permit.reference_release_count >=
                permit.plan.allocation_count)
                return allocation.CallbackError.Unavailable;
            switch (permit.mode) {
                .production => self.backend
                    .releaseBufferAllocationAfterLifecycleLoss(
                    native_token,
                    permit.source_identity,
                    permit.minimum_event_sequence,
                ) catch return allocation.CallbackError.Unavailable,
                .synthetic_test => {
                    if (comptime !metal_test_faults)
                        return allocation.CallbackError.Unavailable;
                    self.backend.destroyBufferAllocation(
                        native_token,
                    ) catch return allocation.CallbackError.Unavailable;
                },
            }
            if (self.loss_retirement_permit) |*retained|
                retained.reference_release_count += 1;
        } else {
            const inspected = self.backend.inspectBufferAllocation(
                native_token,
            ) catch return allocation.CallbackError.Unavailable;
            if (!std.meta.eql(inspected, slot.native_info))
                return allocation.CallbackError.Unavailable;

            // Objective-C strong-reference release is synchronous and
            // non-failing. This proves adapter ownership relinquishment, not
            // driver reclamation or physical residency change.
            self.backend.destroyBufferAllocation(native_token) catch
                return allocation.CallbackError.Unavailable;
        }
        self.used_resource_bytes -= slot.call.charged_bytes;
        self.observed_allocated_size_bytes -=
            slot.native_info.allocated_size;
        slot.* = .{};
        var any_live = false;
        for (self.slots) |candidate| if (candidate.live) {
            any_live = true;
            break;
        };
        if (!any_live)
            self.active_admission_sha256 = allocation.zero_digest;
    }
};

fn lossDispatchReconciliationChallengeCallback(
    context_ptr: *anyopaque,
    retained_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    retained_pin: lease_tree.LeaseTreeDispatchPinV1,
    retained_intent: lease_tree.DispatchPinIntentV1,
    retained_object_set: allocation.BackendObjectSetV1,
    retained_calls: []const allocation.AllocationCallV1,
    retained_objects: []const allocation.BackendObjectV1,
) lease_tree.ActiveDispatchReconciliationBindingCallbackError!void {
    const context: *MetalLossDispatchReconciliationChallengeContextV1 =
        @ptrCast(@alignCast(context_ptr));
    const self = context.adapter;
    self.mutex.lock();
    defer self.mutex.unlock();
    const challenge =
        self.lossDispatchReconciliationChallengeUnlocked(
            context.observation,
            retained_lease,
            retained_pin,
            retained_intent,
            retained_object_set,
            retained_calls,
            retained_objects,
            context.ticket,
        ) catch |err|
            return mapDispatchReconciliationCallbackError(err);
    context.result = challenge;
}

fn lossDispatchReconciliationArmCallback(
    context_ptr: *anyopaque,
    retained_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    retained_pin: lease_tree.LeaseTreeDispatchPinV1,
    retained_intent: lease_tree.DispatchPinIntentV1,
    retained_object_set: allocation.BackendObjectSetV1,
    retained_calls: []const allocation.AllocationCallV1,
    retained_objects: []const allocation.BackendObjectV1,
) lease_tree.ActiveDispatchReconciliationBindingCallbackError!void {
    const context: *MetalLossDispatchReconciliationArmContextV1 =
        @ptrCast(@alignCast(context_ptr));
    const self = context.adapter;
    self.mutex.lock();
    defer self.mutex.unlock();
    const result =
        self.armLossDispatchReconciliationFromCoordinatorUnlocked(
            context.*,
            retained_lease,
            retained_pin,
            retained_intent,
            retained_object_set,
            retained_calls,
            retained_objects,
        ) catch |err|
            return mapDispatchReconciliationCallbackError(err);
    context.result = result;
}

fn mapDispatchReconciliationCallbackError(
    err: anyerror,
) lease_tree.ActiveDispatchReconciliationBindingCallbackError {
    return switch (err) {
        error.DispatchBusy,
        error.DispatchUnresolved,
        => error.Busy,
        error.Unavailable => error.Unavailable,
        else => error.InvalidReconciliationBinding,
    };
}

fn mapCoordinatorDispatchReconciliationError(
    err: lease_tree.Error,
) Error {
    return switch (err) {
        error.DispatchReconciliationAdapterBusy => Error.DispatchBusy,
        error.DispatchReconciliationAdapterUnavailable => metal.MetalError.Unavailable,
        else => err,
    };
}

fn lossRetirementChallengeCallback(
    context_ptr: *anyopaque,
    retained_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    retained_object_set: allocation.BackendObjectSetV1,
    retained_calls: []const allocation.AllocationCallV1,
    retained_objects: []const allocation.BackendObjectV1,
) lease_tree.RetirementBindingCallbackError!void {
    const context: *MetalLossRetirementChallengeContextV1 =
        @ptrCast(@alignCast(context_ptr));
    const self = context.adapter;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.validateAddress() catch
        return error.InvalidRetirementBinding;
    if (self.loss_retirement_permit != null or
        self.loss_retirement_tombstone != null)
        return error.Busy;
    allocation.validateObjectSetForAdmissionRootV1(
        retained_object_set,
        retained_lease.admission_sha256,
        self.authority.authority_sha256,
        retained_lease.allocation_count,
        retained_lease.materialized_bytes,
        retained_calls,
        retained_objects,
    ) catch return error.InvalidRetirementBinding;
    if (!device.digestEqual(
        retained_lease.authority_sha256,
        self.authority.authority_sha256,
    ) or !device.digestEqual(
        retained_lease.selected_capability_sha256,
        self.authority.selected_capability_sha256,
    ) or !device.digestEqual(
        retained_lease.admission_sha256,
        self.active_admission_sha256,
    ) or !device.digestEqual(
        retained_lease.backend_object_set_sha256,
        retained_object_set.object_set_sha256,
    ) or self.backend.liveWeightCount() != 0)
        return error.InvalidRetirementBinding;
    context.result = lossRetirementAdapterChallengeRootV1(
        self,
        context.observation,
        retained_lease,
    );
}

fn lossRetirementArmCallback(
    context_ptr: *anyopaque,
    retained_lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    retained_object_set: allocation.BackendObjectSetV1,
    retained_calls: []const allocation.AllocationCallV1,
    retained_objects: []const allocation.BackendObjectV1,
) lease_tree.RetirementBindingCallbackError!void {
    const context: *MetalLossRetirementArmContextV1 =
        @ptrCast(@alignCast(context_ptr));
    const self = context.adapter;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.validateAddress() catch
        return error.InvalidRetirementBinding;
    self.armLossRetirementFromCoordinatorUnlocked(
        context.*,
        retained_lease,
        retained_object_set,
        retained_calls,
        retained_objects,
    ) catch |err| return mapRetirementCallbackError(err);
}

fn mapRetirementCallbackError(
    err: anyerror,
) lease_tree.RetirementBindingCallbackError {
    return switch (err) {
        error.DispatchBusy => error.Busy,
        error.Unavailable => error.Unavailable,
        else => error.InvalidRetirementBinding,
    };
}

fn mapCoordinatorRetirementError(
    err: lease_tree.Error,
) Error {
    return switch (err) {
        error.RetirementAdapterBusy => Error.DispatchBusy,
        error.RetirementAdapterUnavailable => metal.MetalError.Unavailable,
        else => err,
    };
}

pub fn makeMetalMatvecPreSubmitAttemptV1(
    bindings: MetalMatvecAllocationBindingsV1,
    packed_weights_bytes: u64,
    scales_count: u64,
    input_count: u64,
    output_count: u64,
    group_size: u32,
    in_features: u32,
    out_features: u32,
) Error!MetalMatvecPreSubmitAttemptV1 {
    var result: MetalMatvecPreSubmitAttemptV1 = .{
        .group_size = group_size,
        .in_features = in_features,
        .out_features = out_features,
        .packed_weights_bytes = packed_weights_bytes,
        .scales_count = scales_count,
        .input_count = input_count,
        .output_count = output_count,
        .bindings = bindings,
    };
    result.attempt_sha256 =
        metalMatvecPreSubmitAttemptRootV1(result);
    try validateMetalMatvecPreSubmitAttemptV1(result);
    return result;
}

pub fn metalMatvecPreSubmitAttemptRootV1(
    attempt: MetalMatvecPreSubmitAttemptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(pre_submit_attempt_domain);
    hashU64(&hash, attempt.abi_version);
    hashU32(&hash, attempt.group_size);
    hashU32(&hash, attempt.in_features);
    hashU32(&hash, attempt.out_features);
    hashU32(&hash, attempt.reserved);
    hashU64(&hash, attempt.packed_weights_bytes);
    hashU64(&hash, attempt.scales_count);
    hashU64(&hash, attempt.input_count);
    hashU64(&hash, attempt.output_count);
    hash.update(&attempt.bindings.packed_weights_sha256);
    hash.update(&attempt.bindings.scales_sha256);
    hash.update(&attempt.bindings.input_sha256);
    hash.update(&attempt.bindings.output_sha256);
    return finish(&hash);
}

pub fn validateMetalMatvecPreSubmitAttemptV1(
    attempt: MetalMatvecPreSubmitAttemptV1,
) Error!void {
    if (attempt.abi_version != pre_submit_attempt_abi or
        attempt.reserved != 0 or
        digestIsZero(attempt.attempt_sha256) or
        !device.digestEqual(
            attempt.attempt_sha256,
            metalMatvecPreSubmitAttemptRootV1(attempt),
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn makeMetalMatvecDispatchRequestV1(
    request_generation: u64,
    dispatch_authority_sha256: Digest,
    queue_authority_sha256: Digest,
    attempt: MetalMatvecPreSubmitAttemptV1,
) Error!MetalMatvecDispatchRequestV1 {
    try validateMetalMatvecPreSubmitAttemptV1(attempt);
    var result: MetalMatvecDispatchRequestV1 = .{
        .request_generation = request_generation,
        .dispatch_authority_sha256 = dispatch_authority_sha256,
        .queue_authority_sha256 = queue_authority_sha256,
        .attempt = attempt,
    };
    result.request_sha256 =
        metalMatvecDispatchRequestRootV1(result);
    try validateMetalMatvecDispatchRequestV1(result);
    return result;
}

pub fn metalMatvecDispatchRequestRootV1(
    request: MetalMatvecDispatchRequestV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(matvec_dispatch_request_domain);
    hashU64(&hash, request.abi_version);
    hashU64(&hash, request.request_generation);
    hash.update(&request.dispatch_authority_sha256);
    hash.update(&request.queue_authority_sha256);
    hash.update(&request.attempt.attempt_sha256);
    return finish(&hash);
}

pub fn validateMetalMatvecDispatchRequestV1(
    request: MetalMatvecDispatchRequestV1,
) Error!void {
    try validateMetalMatvecPreSubmitAttemptV1(
        request.attempt,
    );
    if (request.abi_version !=
        matvec_dispatch_request_abi or
        request.request_generation == 0 or
        digestIsZero(request.dispatch_authority_sha256) or
        digestIsZero(request.queue_authority_sha256) or
        device.digestEqual(
            request.dispatch_authority_sha256,
            request.queue_authority_sha256,
        ) or digestIsZero(request.request_sha256) or
        !device.digestEqual(
            request.request_sha256,
            metalMatvecDispatchRequestRootV1(request),
        ))
        return Error.InvalidDispatchEvidence;
}

/// Validate the canonical pre-completion observation used to seal an async
/// ticket. Completion, output, terminal, and final-observation fields must all
/// remain absent. The inherited `.succeeded` value is only the submitted
/// operation profile; this draft is not terminal evidence.
pub fn validateMetalAsyncDispatchDraftForPinV1(
    draft: MetalLeaseTreeDispatchObservationV1,
    request: MetalMatvecDispatchRequestV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
) Error!void {
    try validateMetalMatvecDispatchRequestV1(request);
    lease_tree.validateDispatchPinV1(pin) catch
        return Error.InvalidDispatchEvidence;
    try validateMatvecGeometryV1(draft.geometry);
    try validateMatvecRoleEvidenceV1(draft.roles);

    const exact_bytes = std.math.add(
        u64,
        draft.geometry.packed_bytes,
        draft.geometry.scales_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    const exact_with_input = std.math.add(
        u64,
        exact_bytes,
        draft.geometry.input_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    const total_bytes = std.math.add(
        u64,
        exact_with_input,
        draft.geometry.output_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    const empty_telemetry: metal.MetalDispatchTelemetry = .{
        .current_allocated_before = 0,
        .current_allocated_after = 0,
        .gpu_start_time_bits = 0,
        .gpu_end_time_bits = 0,
        .gpu_duration_nanoseconds = 0,
        .command_status = 0,
    };

    if (draft.abi_version != dispatch_observation_abi or
        draft.outcome != .succeeded or
        draft.dispatch_generation != pin.dispatch_generation or
        draft.allocation_count != 4 or
        draft.allocation_count != pin.allocation_count or
        draft.materialized_bytes != total_bytes or
        draft.materialized_bytes != pin.pinned_device_bytes or
        !device.digestEqual(
            draft.authority_sha256,
            pin.authority_sha256,
        ) or !device.digestEqual(
        draft.admission_sha256,
        pin.admission_sha256,
    ) or !device.digestEqual(
        draft.lease_sha256,
        pin.lease_sha256,
    ) or !device.digestEqual(
        draft.backend_object_set_sha256,
        pin.backend_object_set_sha256,
    ) or !device.digestEqual(
        draft.pin_sha256,
        pin.pin_sha256,
    ) or !device.digestEqual(
        draft.dispatch_request_sha256,
        pin.dispatch_request_sha256,
    ) or !device.digestEqual(
        draft.dispatch_request_sha256,
        request.request_sha256,
    ) or !device.digestEqual(
        draft.dispatch_authority_sha256,
        pin.dispatch_authority_sha256,
    ) or !device.digestEqual(
        draft.dispatch_authority_sha256,
        request.dispatch_authority_sha256,
    ) or !device.digestEqual(
        draft.queue_authority_sha256,
        pin.queue_authority_sha256,
    ) or !device.digestEqual(
        draft.queue_authority_sha256,
        request.queue_authority_sha256,
    ) or request.attempt.group_size !=
        draft.geometry.group_size or
        request.attempt.in_features !=
            draft.geometry.in_features or
        request.attempt.out_features !=
            draft.geometry.out_features or
        request.attempt.packed_weights_bytes !=
            draft.geometry.packed_bytes or
        request.attempt.scales_count !=
            draft.geometry.scale_count or
        request.attempt.input_count !=
            draft.geometry.input_count or
        request.attempt.output_count !=
            draft.geometry.output_count or
        !std.meta.eql(
            request.attempt.bindings,
            draft.roles.bindings,
        ) or digestIsZero(
        draft.packed_weights_input_sha256,
    ) or digestIsZero(
        draft.scales_input_sha256,
    ) or digestIsZero(
        draft.vector_input_sha256,
    ) or digestIsZero(draft.submission_sha256) or
        !device.digestEqual(
            draft.submission_sha256,
            dispatchSubmissionRootV1(draft),
        ) or !std.meta.eql(
        draft.telemetry,
        empty_telemetry,
    ) or !digestIsZero(draft.telemetry_sha256) or
        !digestIsZero(
            draft.backend_completion_sha256,
        ) or !digestIsZero(draft.output_sha256) or
        !digestIsZero(draft.terminal_sha256) or
        !digestIsZero(draft.observation_sha256))
        return Error.InvalidDispatchEvidence;
}

pub fn makeMetalAsyncDispatchTicketV1(
    ticket_generation: u64,
    request: MetalMatvecDispatchRequestV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    draft: MetalLeaseTreeDispatchObservationV1,
) Error!MetalAsyncDispatchTicketV1 {
    try validateMetalAsyncDispatchDraftForPinV1(
        draft,
        request,
        pin,
    );
    if (ticket_generation == 0 or
        ticket_generation == std.math.maxInt(u64))
        return Error.InvalidDispatchEvidence;
    var result: MetalAsyncDispatchTicketV1 = .{
        .ticket_generation = ticket_generation,
        .dispatch_generation = pin.dispatch_generation,
        .dispatch_authority_sha256 = pin.dispatch_authority_sha256,
        .queue_authority_sha256 = pin.queue_authority_sha256,
        .request = request,
        .pin_sha256 = pin.pin_sha256,
        .submission_sha256 = draft.submission_sha256,
    };
    result.ticket_sha256 =
        metalAsyncDispatchTicketRootV1(result);
    try validateMetalAsyncDispatchTicketForDispatchV1(
        result,
        ticket_generation,
        request,
        pin,
        draft,
    );
    return result;
}

pub fn metalAsyncDispatchTicketRootV1(
    ticket: MetalAsyncDispatchTicketV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(async_dispatch_ticket_domain);
    hashU64(&hash, ticket.abi_version);
    hashU64(&hash, ticket.ticket_generation);
    hashU64(&hash, ticket.queue_slot);
    hashU64(&hash, ticket.dispatch_generation);
    hash.update(&ticket.dispatch_authority_sha256);
    hash.update(&ticket.queue_authority_sha256);
    hash.update(&ticket.request.request_sha256);
    hash.update(&ticket.pin_sha256);
    hash.update(&ticket.submission_sha256);
    return finish(&hash);
}

pub fn validateMetalAsyncDispatchTicketV1(
    ticket: MetalAsyncDispatchTicketV1,
) Error!void {
    try validateMetalMatvecDispatchRequestV1(
        ticket.request,
    );
    if (ticket.abi_version != async_dispatch_ticket_abi or
        ticket.ticket_generation == 0 or
        ticket.ticket_generation == std.math.maxInt(u64) or
        ticket.queue_slot != 0 or
        ticket.dispatch_generation == 0 or
        digestIsZero(ticket.dispatch_authority_sha256) or
        digestIsZero(ticket.queue_authority_sha256) or
        device.digestEqual(
            ticket.dispatch_authority_sha256,
            ticket.queue_authority_sha256,
        ) or !device.digestEqual(
        ticket.dispatch_authority_sha256,
        ticket.request.dispatch_authority_sha256,
    ) or !device.digestEqual(
        ticket.queue_authority_sha256,
        ticket.request.queue_authority_sha256,
    ) or digestIsZero(ticket.pin_sha256) or
        digestIsZero(ticket.submission_sha256) or
        digestIsZero(ticket.ticket_sha256) or
        !device.digestEqual(
            ticket.ticket_sha256,
            metalAsyncDispatchTicketRootV1(ticket),
        ))
        return Error.InvalidDispatchEvidence;
}

/// Bind a standalone ticket back to the exact live generation, request, pin,
/// and canonical pre-completion draft retained by the same-process adapter.
pub fn validateMetalAsyncDispatchTicketForDispatchV1(
    ticket: MetalAsyncDispatchTicketV1,
    expected_ticket_generation: u64,
    request: MetalMatvecDispatchRequestV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    draft: MetalLeaseTreeDispatchObservationV1,
) Error!void {
    try validateMetalAsyncDispatchTicketV1(ticket);
    try validateMetalAsyncDispatchDraftForPinV1(
        draft,
        request,
        pin,
    );
    if (expected_ticket_generation == 0 or
        expected_ticket_generation == std.math.maxInt(u64) or
        ticket.ticket_generation != expected_ticket_generation or
        ticket.dispatch_generation != pin.dispatch_generation or
        !std.meta.eql(ticket.request, request) or
        !device.digestEqual(
            ticket.pin_sha256,
            pin.pin_sha256,
        ) or !device.digestEqual(
        ticket.submission_sha256,
        draft.submission_sha256,
    ) or !device.digestEqual(
        ticket.dispatch_authority_sha256,
        pin.dispatch_authority_sha256,
    ) or !device.digestEqual(
        ticket.queue_authority_sha256,
        pin.queue_authority_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

fn asyncDispatchQuarantineReasonValid(
    reason: MetalAsyncDispatchQuarantineReasonV1,
) bool {
    return switch (reason) {
        .submission_ambiguous,
        .completion_unknown,
        .invalid_completion,
        .terminal_command_error,
        => true,
        _ => false,
    };
}

fn asyncDispatchQuarantineShapeValid(
    value: MetalAsyncDispatchQuarantineV1,
) bool {
    if (value.error_code_bits == 0 or
        value.native_completion_observed > 1)
        return false;
    return switch (value.reason) {
        .submission_ambiguous => value.native_disposition == .commit_started and
            value.native_command_status ==
                async_native_command_status_unobserved and
            value.native_completion_observed == 0 and
            value.error_domain_kind == .native_bridge and
            value.error_code_bits ==
                async_submission_ambiguous_adapter_code,
        .completion_unknown => value.native_disposition == .submitted and
            value.error_domain_kind == .native_bridge,
        .invalid_completion => value.native_disposition == .terminal_status_observed and
            value.native_command_status ==
                async_native_command_status_completed and
            value.native_completion_observed == 1 and
            value.error_domain_kind ==
                .completion_validation,
        .terminal_command_error => value.native_disposition == .terminal_status_observed and
            value.native_command_status ==
                async_native_command_status_error and
            value.native_completion_observed == 1 and
            value.error_domain_kind == .command_buffer,
        _ => false,
    };
}

pub fn makeMetalAsyncDispatchQuarantineV1(
    ticket: MetalAsyncDispatchTicketV1,
    device_sha256: Digest,
    placement_sha256: Digest,
    reason: MetalAsyncDispatchQuarantineReasonV1,
    native_disposition: MetalAsyncNativeDispositionV1,
    native_command_status: u64,
    native_completion_observed: u64,
    error_domain_kind: MetalAsyncErrorDomainKindV1,
    error_code_bits: u64,
) Error!MetalAsyncDispatchQuarantineV1 {
    try validateMetalAsyncDispatchTicketV1(ticket);
    var result: MetalAsyncDispatchQuarantineV1 = .{
        .reason = reason,
        .ticket = ticket,
        .device_sha256 = device_sha256,
        .placement_sha256 = placement_sha256,
        .native_disposition = native_disposition,
        .native_command_status = native_command_status,
        .native_completion_observed = native_completion_observed,
        .error_domain_kind = error_domain_kind,
        .error_code_bits = error_code_bits,
    };
    result.quarantine_sha256 =
        metalAsyncDispatchQuarantineRootV1(result);
    try validateMetalAsyncDispatchQuarantineV1(result);
    return result;
}

pub fn metalAsyncDispatchQuarantineRootV1(
    value: MetalAsyncDispatchQuarantineV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(async_dispatch_quarantine_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.reason));
    hash.update(&value.ticket.ticket_sha256);
    hash.update(&value.device_sha256);
    hash.update(&value.placement_sha256);
    hashU64(&hash, @intFromEnum(value.native_disposition));
    hashU64(&hash, value.native_command_status);
    hashU64(&hash, value.native_completion_observed);
    hashU64(&hash, @intFromEnum(value.error_domain_kind));
    hashU64(&hash, value.error_code_bits);
    return finish(&hash);
}

pub fn validateMetalAsyncDispatchQuarantineV1(
    value: MetalAsyncDispatchQuarantineV1,
) Error!void {
    try validateMetalAsyncDispatchTicketV1(value.ticket);
    if (value.abi_version != async_dispatch_quarantine_abi or
        !asyncDispatchQuarantineReasonValid(value.reason) or
        digestIsZero(value.device_sha256) or
        digestIsZero(value.placement_sha256) or
        device.digestEqual(
            value.device_sha256,
            value.placement_sha256,
        ) or !asyncDispatchQuarantineShapeValid(value) or
        digestIsZero(value.quarantine_sha256) or
        !device.digestEqual(
            value.quarantine_sha256,
            metalAsyncDispatchQuarantineRootV1(value),
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn validateMetalAsyncDispatchQuarantineForTicketV1(
    value: MetalAsyncDispatchQuarantineV1,
    ticket: MetalAsyncDispatchTicketV1,
    device_sha256: Digest,
    placement_sha256: Digest,
) Error!void {
    try validateMetalAsyncDispatchQuarantineV1(value);
    try validateMetalAsyncDispatchTicketV1(ticket);
    if (!std.meta.eql(value.ticket, ticket) or
        !device.digestEqual(
            value.device_sha256,
            device_sha256,
        ) or !device.digestEqual(
        value.placement_sha256,
        placement_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

/// A sticky quarantine slot may replay only the byte-for-byte same canonical
/// observation. A coherently resealed change is a different observation and
/// cannot replace the one already retained by the adapter.
pub fn validateMetalAsyncDispatchQuarantineReplayV1(
    value: MetalAsyncDispatchQuarantineV1,
    retained: MetalAsyncDispatchQuarantineV1,
) Error!void {
    try validateMetalAsyncDispatchQuarantineV1(value);
    try validateMetalAsyncDispatchQuarantineV1(retained);
    if (!std.meta.eql(value, retained))
        return Error.InvalidDispatchEvidence;
}

fn lossDispatchNativeDeviceRemovedSourceValidV1(
    quarantine: MetalAsyncDispatchQuarantineV1,
    completion: metal.MetalAsyncCompletion,
    failure: MetalAsyncDispatchTerminalFailureV1,
) bool {
    const error_code_bits: u64 = @bitCast(completion.error_code);
    return quarantine.reason == .terminal_command_error and
        quarantine.native_command_status ==
            lifecycle.command_buffer_status_error and
        quarantine.native_completion_observed == 1 and
        quarantine.error_domain_kind == .command_buffer and
        quarantine.error_code_bits ==
            lifecycle.command_buffer_device_removed_error and
        completion.state == .@"error" and
        completion.command_status ==
            lifecycle.command_buffer_status_error and
        completion.error_present == 1 and
        completion.callback_fault == 0 and
        @intFromEnum(completion.error_domain_kind) ==
            lifecycle.command_buffer_error_domain and
        error_code_bits ==
            lifecycle.command_buffer_device_removed_error and
        failure.native_command_status ==
            lifecycle.command_buffer_status_error and
        failure.error_domain_kind == .command_buffer and
        failure.error_code_bits ==
            lifecycle.command_buffer_device_removed_error and
        device.digestEqual(
            failure.quarantine.quarantine_sha256,
            quarantine.quarantine_sha256,
        );
}

pub fn metalAsyncDispatchNativeTerminalRootV1(
    value: MetalAsyncDispatchTerminalFailureV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(async_dispatch_native_terminal_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.quarantine.ticket.ticket_sha256);
    hash.update(&value.quarantine.quarantine_sha256);
    hashU64(&hash, value.current_allocated_before);
    hashU64(&hash, value.current_allocated_after);
    hashU64(&hash, value.gpu_start_time_bits);
    hashU64(&hash, value.gpu_end_time_bits);
    hashU64(&hash, value.native_command_status);
    hashU64(&hash, @intFromEnum(value.error_domain_kind));
    hashU64(&hash, value.error_code_bits);
    return finish(&hash);
}

pub fn metalAsyncDispatchFailureBackendCompletionRootV1(
    value: MetalAsyncDispatchTerminalFailureV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        async_dispatch_failure_backend_completion_domain,
    );
    hashU64(&hash, value.abi_version);
    hash.update(&value.submission_sha256);
    hash.update(&value.native_terminal_sha256);
    return finish(&hash);
}

pub fn metalAsyncDispatchTerminalFailureRootV1(
    value: MetalAsyncDispatchTerminalFailureV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(async_dispatch_terminal_failure_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.outcome));
    hash.update(&value.quarantine.quarantine_sha256);
    hashU64(&hash, value.dispatch_generation);
    hashU64(&hash, value.allocation_count);
    hashU64(&hash, value.materialized_bytes);
    hash.update(&value.pin_sha256);
    hash.update(&value.backend_object_set_sha256);
    hashU64(&hash, value.current_allocated_before);
    hashU64(&hash, value.current_allocated_after);
    hashU64(&hash, value.gpu_start_time_bits);
    hashU64(&hash, value.gpu_end_time_bits);
    hashU64(&hash, value.native_command_status);
    hashU64(&hash, @intFromEnum(value.error_domain_kind));
    hashU64(&hash, value.error_code_bits);
    hash.update(&value.native_terminal_sha256);
    hash.update(&value.submission_sha256);
    hash.update(&value.backend_completion_sha256);
    hash.update(&value.terminal_sha256);
    return finish(&hash);
}

/// Validate the portable terminal-failure sidecar and its matching core
/// terminal. Same-process native token authentication is deliberately
/// performed by `validateMetalAsyncDispatchTerminalFailureForDispatchV1`.
pub fn validateMetalAsyncDispatchTerminalFailureV1(
    value: MetalAsyncDispatchTerminalFailureV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
) Error!void {
    try validateMetalAsyncDispatchQuarantineV1(
        value.quarantine,
    );
    lease_tree.validateDispatchTerminalV1(
        terminal,
    ) catch return Error.InvalidDispatchEvidence;
    if (value.abi_version !=
        async_dispatch_terminal_failure_abi or
        value.outcome != .terminal_failure or
        value.quarantine.reason !=
            .terminal_command_error or
        value.dispatch_generation == 0 or
        value.dispatch_generation !=
            value.quarantine.ticket.dispatch_generation or
        value.allocation_count != 4 or
        value.materialized_bytes <
            value.allocation_count or
        digestIsZero(value.pin_sha256) or
        !device.digestEqual(
            value.pin_sha256,
            value.quarantine.ticket.pin_sha256,
        ) or
        digestIsZero(value.backend_object_set_sha256) or
        value.current_allocated_before == 0 or
        value.native_command_status !=
            async_native_command_status_error or
        value.error_domain_kind != .command_buffer or
        value.error_code_bits == 0 or
        value.error_code_bits !=
            value.quarantine.error_code_bits or
        digestIsZero(value.native_terminal_sha256) or
        !device.digestEqual(
            value.native_terminal_sha256,
            metalAsyncDispatchNativeTerminalRootV1(value),
        ) or
        digestIsZero(value.submission_sha256) or
        !device.digestEqual(
            value.submission_sha256,
            value.quarantine.ticket.submission_sha256,
        ) or
        digestIsZero(value.backend_completion_sha256) or
        !device.digestEqual(
            value.backend_completion_sha256,
            metalAsyncDispatchFailureBackendCompletionRootV1(
                value,
            ),
        ) or
        digestIsZero(value.terminal_sha256) or
        !device.digestEqual(
            value.terminal_sha256,
            terminal.terminal_sha256,
        ) or
        terminal.outcome != .terminal_failure or
        terminal.dispatch_generation !=
            value.dispatch_generation or
        !device.digestEqual(
            terminal.dispatch_authority_sha256,
            value.quarantine.ticket
                .dispatch_authority_sha256,
        ) or
        !device.digestEqual(
            terminal.queue_authority_sha256,
            value.quarantine.ticket
                .queue_authority_sha256,
        ) or
        !device.digestEqual(
            terminal.pin_sha256,
            value.pin_sha256,
        ) or
        !device.digestEqual(
            terminal.dispatch_request_sha256,
            value.quarantine.ticket
                .request.request_sha256,
        ) or
        !device.digestEqual(
            terminal.submission_sha256,
            value.submission_sha256,
        ) or
        !device.digestEqual(
            terminal.backend_completion_sha256,
            value.backend_completion_sha256,
        ) or
        !digestIsZero(terminal.output_sha256) or
        digestIsZero(value.failure_sha256) or
        !device.digestEqual(
            value.failure_sha256,
            metalAsyncDispatchTerminalFailureRootV1(value),
        ))
        return Error.InvalidDispatchEvidence;
}

/// Bind the portable failure sidecar back to the exact live pin, draft, and
/// private native command snapshot retained by the adapter.
pub fn validateMetalAsyncDispatchTerminalFailureForDispatchV1(
    value: MetalAsyncDispatchTerminalFailureV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    draft: MetalLeaseTreeDispatchObservationV1,
    submission: metal.MetalAsyncSubmission,
    completion: metal.MetalAsyncCompletion,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
) Error!void {
    try validateMetalAsyncDispatchTerminalFailureV1(
        value,
        terminal,
    );
    try validateMetalAsyncDispatchTicketForDispatchV1(
        value.quarantine.ticket,
        value.quarantine.ticket.ticket_generation,
        value.quarantine.ticket.request,
        pin,
        draft,
    );
    metal.validateMetalAsyncSubmission(
        submission,
    ) catch return Error.InvalidDispatchEvidence;
    metal.validateMetalAsyncCompletion(
        completion,
    ) catch return Error.InvalidDispatchEvidence;
    lease_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    ) catch return Error.InvalidDispatchEvidence;
    const error_code_bits: u64 =
        @bitCast(completion.error_code);
    if (completion.state != .@"error" or
        completion.command_status !=
            async_native_command_status_error or
        completion.error_present != 1 or
        completion.callback_fault != 0 or
        completion.error_domain_kind != .command_buffer or
        error_code_bits == 0 or
        !std.meta.eql(submission.token, completion.token) or
        !std.mem.eql(
            u8,
            &submission.submission_binding,
            &completion.submission_binding,
        ) or
        !std.mem.eql(
            u8,
            &submission.submission_binding,
            &value.quarantine.ticket.ticket_sha256,
        ) or
        value.current_allocated_before !=
            completion.current_allocated_before or
        value.current_allocated_after !=
            completion.current_allocated_after or
        value.gpu_start_time_bits !=
            @as(u64, @bitCast(completion.gpu_start_time)) or
        value.gpu_end_time_bits !=
            @as(u64, @bitCast(completion.gpu_end_time)) or
        value.native_command_status !=
            completion.command_status or
        value.error_code_bits != error_code_bits or
        value.error_code_bits !=
            value.quarantine.error_code_bits or
        value.dispatch_generation != pin.dispatch_generation or
        value.allocation_count != pin.allocation_count or
        value.materialized_bytes !=
            pin.pinned_device_bytes or
        !device.digestEqual(
            value.backend_object_set_sha256,
            pin.backend_object_set_sha256,
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn makeMetalAsyncDispatchTerminalFailureV1(
    quarantine: MetalAsyncDispatchQuarantineV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    draft: MetalLeaseTreeDispatchObservationV1,
    submission: metal.MetalAsyncSubmission,
    completion: metal.MetalAsyncCompletion,
) Error!MetalAsyncDispatchTerminalFailureResultV1 {
    try validateMetalAsyncDispatchQuarantineV1(quarantine);
    try validateMetalAsyncDispatchTicketForDispatchV1(
        quarantine.ticket,
        quarantine.ticket.ticket_generation,
        quarantine.ticket.request,
        pin,
        draft,
    );
    metal.validateMetalAsyncSubmission(
        submission,
    ) catch return Error.InvalidDispatchEvidence;
    metal.validateMetalAsyncCompletion(
        completion,
    ) catch return Error.InvalidDispatchEvidence;
    const error_code_bits: u64 =
        @bitCast(completion.error_code);
    if (quarantine.reason != .terminal_command_error or
        completion.state != .@"error" or
        completion.command_status !=
            async_native_command_status_error or
        completion.error_present != 1 or
        completion.callback_fault != 0 or
        completion.error_domain_kind != .command_buffer or
        error_code_bits == 0 or
        !std.meta.eql(submission.token, completion.token) or
        !std.mem.eql(
            u8,
            &submission.submission_binding,
            &completion.submission_binding,
        ) or
        !std.mem.eql(
            u8,
            &submission.submission_binding,
            &quarantine.ticket.ticket_sha256,
        ) or
        error_code_bits != quarantine.error_code_bits)
        return Error.InvalidDispatchEvidence;

    var failure: MetalAsyncDispatchTerminalFailureV1 = .{
        .quarantine = quarantine,
        .dispatch_generation = pin.dispatch_generation,
        .allocation_count = pin.allocation_count,
        .materialized_bytes = pin.pinned_device_bytes,
        .pin_sha256 = pin.pin_sha256,
        .backend_object_set_sha256 = pin.backend_object_set_sha256,
        .current_allocated_before = completion.current_allocated_before,
        .current_allocated_after = completion.current_allocated_after,
        .gpu_start_time_bits = @bitCast(completion.gpu_start_time),
        .gpu_end_time_bits = @bitCast(completion.gpu_end_time),
        .native_command_status = completion.command_status,
        .error_domain_kind = .command_buffer,
        .error_code_bits = error_code_bits,
        .submission_sha256 = draft.submission_sha256,
    };
    failure.native_terminal_sha256 =
        metalAsyncDispatchNativeTerminalRootV1(failure);
    failure.backend_completion_sha256 =
        metalAsyncDispatchFailureBackendCompletionRootV1(
            failure,
        );
    const terminal = lease_tree.makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        failure.submission_sha256,
        failure.backend_completion_sha256,
        allocation.zero_digest,
    ) catch return Error.InvalidDispatchEvidence;
    failure.terminal_sha256 = terminal.terminal_sha256;
    failure.failure_sha256 =
        metalAsyncDispatchTerminalFailureRootV1(failure);
    try validateMetalAsyncDispatchTerminalFailureForDispatchV1(
        failure,
        pin,
        draft,
        submission,
        completion,
        terminal,
    );
    return .{
        .failure = failure,
        .terminal = terminal,
    };
}

fn validateMetalMatvecCancellationForPinV1(
    request: MetalMatvecDispatchRequestV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
) Error!void {
    try validateMetalMatvecDispatchRequestV1(request);
    lease_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    ) catch return Error.InvalidDispatchEvidence;
    if (terminal.outcome != .cancelled_before_submit or
        !device.digestEqual(
            request.request_sha256,
            pin.dispatch_request_sha256,
        ) or !device.digestEqual(
        request.dispatch_authority_sha256,
        pin.dispatch_authority_sha256,
    ) or !device.digestEqual(
        request.queue_authority_sha256,
        pin.queue_authority_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

fn classifyStaticPreSubmitRejectionV1(
    attempt: MetalMatvecPreSubmitAttemptV1,
) Error!?MetalMatvecPreSubmitRejectionReasonV1 {
    try validateMetalMatvecPreSubmitAttemptV1(attempt);
    const geometry = makeMatvecGeometryV1(
        attempt.group_size,
        attempt.in_features,
        attempt.out_features,
    ) catch return .invalid_geometry;
    if (attempt.packed_weights_bytes != geometry.packed_bytes or
        attempt.scales_count != geometry.scale_count or
        attempt.input_count != geometry.input_count or
        attempt.output_count != geometry.output_count)
        return .invalid_host_lengths;
    validateMatvecBindingsV1(attempt.bindings) catch
        return .invalid_role_bindings;
    return null;
}

fn preSubmitRejectionReasonValid(
    reason: MetalMatvecPreSubmitRejectionReasonV1,
) bool {
    return switch (reason) {
        .invalid_geometry,
        .invalid_host_lengths,
        .invalid_role_bindings,
        .invalid_role_mapping,
        => true,
        _ => false,
    };
}

pub fn makeMetalMatvecPreSubmitRejectionV1(
    pin: lease_tree.LeaseTreeDispatchPinV1,
    request: MetalMatvecDispatchRequestV1,
    reason: MetalMatvecPreSubmitRejectionReasonV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
) Error!MetalMatvecPreSubmitRejectionV1 {
    try lease_tree.validateDispatchPinV1(pin);
    try lease_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    );
    try validateMetalMatvecDispatchRequestV1(request);
    const static_reason =
        try classifyStaticPreSubmitRejectionV1(
            request.attempt,
        );
    if (!preSubmitRejectionReasonValid(reason) or
        !device.digestEqual(
            request.request_sha256,
            pin.dispatch_request_sha256,
        ) or !device.digestEqual(
        request.dispatch_authority_sha256,
        pin.dispatch_authority_sha256,
    ) or !device.digestEqual(
        request.queue_authority_sha256,
        pin.queue_authority_sha256,
    ) or terminal.outcome != .rejected_before_submit or
        (reason == .invalid_role_mapping and
            static_reason != null) or
        (reason != .invalid_role_mapping and
            (static_reason == null or
                static_reason.? != reason)))
        return Error.InvalidDispatchEvidence;
    var result: MetalMatvecPreSubmitRejectionV1 = .{
        .reason = reason,
        .dispatch_generation = pin.dispatch_generation,
        .allocation_count = pin.allocation_count,
        .materialized_bytes = pin.pinned_device_bytes,
        .pin_sha256 = pin.pin_sha256,
        .backend_object_set_sha256 = pin.backend_object_set_sha256,
        .request = request,
        .terminal_sha256 = terminal.terminal_sha256,
    };
    result.rejection_sha256 =
        metalMatvecPreSubmitRejectionRootV1(result);
    try validateMetalMatvecPreSubmitRejectionForPinV1(
        result,
        pin,
        terminal,
    );
    return result;
}

pub fn metalMatvecPreSubmitRejectionRootV1(
    rejection: MetalMatvecPreSubmitRejectionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(pre_submit_rejection_domain);
    hashU64(&hash, rejection.abi_version);
    hashU64(&hash, @intFromEnum(rejection.reason));
    hashU64(&hash, rejection.dispatch_generation);
    hashU64(&hash, rejection.allocation_count);
    hashU64(&hash, rejection.materialized_bytes);
    hash.update(&rejection.pin_sha256);
    hash.update(&rejection.backend_object_set_sha256);
    hash.update(&rejection.request.request_sha256);
    hash.update(&rejection.terminal_sha256);
    return finish(&hash);
}

pub fn validateMetalMatvecPreSubmitRejectionV1(
    rejection: MetalMatvecPreSubmitRejectionV1,
) Error!void {
    try validateMetalMatvecDispatchRequestV1(
        rejection.request,
    );
    const static_reason =
        try classifyStaticPreSubmitRejectionV1(
            rejection.request.attempt,
        );
    if (rejection.abi_version != pre_submit_rejection_abi or
        !preSubmitRejectionReasonValid(rejection.reason) or
        (rejection.reason == .invalid_role_mapping and
            static_reason != null) or
        (rejection.reason != .invalid_role_mapping and
            (static_reason == null or
                static_reason.? != rejection.reason)) or
        rejection.dispatch_generation == 0 or
        rejection.allocation_count != 4 or
        rejection.materialized_bytes <
            rejection.allocation_count or
        digestIsZero(rejection.pin_sha256) or
        digestIsZero(
            rejection.backend_object_set_sha256,
        ) or digestIsZero(rejection.terminal_sha256) or
        digestIsZero(rejection.rejection_sha256) or
        !device.digestEqual(
            rejection.rejection_sha256,
            metalMatvecPreSubmitRejectionRootV1(rejection),
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn validateMetalMatvecPreSubmitRejectionForPinV1(
    rejection: MetalMatvecPreSubmitRejectionV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
) Error!void {
    try validateMetalMatvecPreSubmitRejectionV1(rejection);
    lease_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    ) catch return Error.InvalidDispatchEvidence;
    if (terminal.outcome != .rejected_before_submit or
        !digestIsZero(terminal.submission_sha256) or
        !digestIsZero(terminal.backend_completion_sha256) or
        !digestIsZero(terminal.output_sha256) or
        rejection.dispatch_generation != pin.dispatch_generation or
        rejection.allocation_count != pin.allocation_count or
        rejection.materialized_bytes != pin.pinned_device_bytes or
        !device.digestEqual(
            rejection.pin_sha256,
            pin.pin_sha256,
        ) or !device.digestEqual(
        rejection.request.request_sha256,
        pin.dispatch_request_sha256,
    ) or !device.digestEqual(
        rejection.request.dispatch_authority_sha256,
        pin.dispatch_authority_sha256,
    ) or !device.digestEqual(
        rejection.request.queue_authority_sha256,
        pin.queue_authority_sha256,
    ) or !device.digestEqual(
        rejection.backend_object_set_sha256,
        pin.backend_object_set_sha256,
    ) or !device.digestEqual(
        rejection.terminal_sha256,
        terminal.terminal_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

pub fn makeMatvecGeometryV1(
    group_size: u32,
    in_features: u32,
    out_features: u32,
) Error!MetalMatvecGeometryV1 {
    if (group_size == 0 or
        !std.math.isPowerOfTwo(group_size) or
        in_features == 0 or out_features == 0)
        return Error.InvalidDispatchEvidence;
    const elements =
        @as(u64, in_features) * @as(u64, out_features);
    if (elements > std.math.maxInt(u32))
        return Error.InvalidDispatchEvidence;
    const scale_count =
        (elements + @as(u64, group_size) - 1) /
        @as(u64, group_size);
    var result: MetalMatvecGeometryV1 = .{
        .group_size = group_size,
        .in_features = in_features,
        .out_features = out_features,
        .packed_bytes = (elements + 1) / 2,
        .scale_count = scale_count,
        .scales_bytes = scale_count * @sizeOf(f32),
        .input_count = in_features,
        .input_bytes = @as(u64, in_features) * @sizeOf(f32),
        .output_count = out_features,
        .output_bytes = @as(u64, out_features) * @sizeOf(f32),
    };
    result.geometry_sha256 = matvecGeometryRootV1(result);
    try validateMatvecGeometryV1(result);
    return result;
}

pub fn validateMatvecGeometryV1(
    geometry: MetalMatvecGeometryV1,
) Error!void {
    if (geometry.group_size == 0 or
        !std.math.isPowerOfTwo(geometry.group_size) or
        geometry.in_features == 0 or
        geometry.out_features == 0 or
        geometry.reserved != 0)
        return Error.InvalidDispatchEvidence;
    const elements =
        @as(u64, geometry.in_features) *
        @as(u64, geometry.out_features);
    if (elements > std.math.maxInt(u32))
        return Error.InvalidDispatchEvidence;
    const scale_count =
        (elements + @as(u64, geometry.group_size) - 1) /
        @as(u64, geometry.group_size);
    if (geometry.packed_bytes != (elements + 1) / 2 or
        geometry.scale_count != scale_count or
        geometry.scales_bytes !=
            scale_count * @sizeOf(f32) or
        geometry.input_count != geometry.in_features or
        geometry.input_bytes !=
            @as(u64, geometry.in_features) *
                @sizeOf(f32) or
        geometry.output_count != geometry.out_features or
        geometry.output_bytes !=
            @as(u64, geometry.out_features) *
                @sizeOf(f32) or
        digestIsZero(geometry.geometry_sha256) or
        !device.digestEqual(
            geometry.geometry_sha256,
            matvecGeometryRootV1(geometry),
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn matvecGeometryRootV1(
    geometry: MetalMatvecGeometryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_geometry_domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, geometry.group_size);
    hashU64(&hash, geometry.in_features);
    hashU64(&hash, geometry.out_features);
    hashU64(&hash, geometry.reserved);
    hashU64(&hash, geometry.packed_bytes);
    hashU64(&hash, geometry.scale_count);
    hashU64(&hash, geometry.scales_bytes);
    hashU64(&hash, geometry.input_count);
    hashU64(&hash, geometry.input_bytes);
    hashU64(&hash, geometry.output_count);
    hashU64(&hash, geometry.output_bytes);
    return finish(&hash);
}

pub fn validateMatvecBindingsV1(
    bindings: MetalMatvecAllocationBindingsV1,
) Error!void {
    const values = [_]Digest{
        bindings.packed_weights_sha256,
        bindings.scales_sha256,
        bindings.input_sha256,
        bindings.output_sha256,
    };
    for (values, 0..) |value, index| {
        if (digestIsZero(value))
            return Error.InvalidDispatchEvidence;
        for (values[0..index]) |prior| {
            if (device.digestEqual(value, prior))
                return Error.InvalidDispatchEvidence;
        }
    }
}

pub fn validateMatvecRoleEvidenceV1(
    evidence: MetalMatvecRoleEvidenceV1,
) Error!void {
    try validateMatvecBindingsV1(evidence.bindings);
    const object_roots = [_]Digest{
        evidence.packed_weights_object_sha256,
        evidence.scales_object_sha256,
        evidence.input_object_sha256,
        evidence.output_object_sha256,
    };
    for (object_roots, 0..) |value, index| {
        if (digestIsZero(value))
            return Error.InvalidDispatchEvidence;
        for (object_roots[0..index]) |prior| {
            if (device.digestEqual(value, prior))
                return Error.InvalidDispatchEvidence;
        }
    }
    if (digestIsZero(evidence.roles_sha256) or
        !device.digestEqual(
            evidence.roles_sha256,
            matvecRoleEvidenceRootV1(evidence),
        ))
        return Error.InvalidDispatchEvidence;
}

pub fn matvecRoleEvidenceRootV1(
    evidence: MetalMatvecRoleEvidenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_roles_domain);
    hashU64(&hash, dispatch_observation_abi);
    hash.update(&evidence.bindings.packed_weights_sha256);
    hash.update(&evidence.bindings.scales_sha256);
    hash.update(&evidence.bindings.input_sha256);
    hash.update(&evidence.bindings.output_sha256);
    hash.update(&evidence.packed_weights_object_sha256);
    hash.update(&evidence.scales_object_sha256);
    hash.update(&evidence.input_object_sha256);
    hash.update(&evidence.output_object_sha256);
    return finish(&hash);
}

pub fn matvecPackedWeightsInputRootV1(
    packed_weights: []const u8,
) Digest {
    return hashByteSliceV1(
        dispatch_packed_input_domain,
        packed_weights,
    );
}

pub fn matvecScalesInputRootV1(
    scales: []const f32,
) Digest {
    return hashF32SliceV1(
        dispatch_scales_input_domain,
        scales,
    );
}

pub fn matvecVectorInputRootV1(
    input: []const f32,
) Digest {
    return hashF32SliceV1(
        dispatch_vector_input_domain,
        input,
    );
}

pub fn matvecOutputRootV1(
    output: []const f32,
) Digest {
    return hashF32SliceV1(
        dispatch_output_domain,
        output,
    );
}

pub fn validateMetalDispatchTelemetryV1(
    telemetry: metal.MetalDispatchTelemetry,
) Error!void {
    const gpu_start: f64 =
        @bitCast(telemetry.gpu_start_time_bits);
    const gpu_end: f64 =
        @bitCast(telemetry.gpu_end_time_bits);
    if (telemetry.current_allocated_before == 0 or
        telemetry.current_allocated_after == 0 or
        !std.math.isFinite(gpu_start) or
        !std.math.isFinite(gpu_end) or
        gpu_start <= 0 or gpu_end <= gpu_start or
        telemetry.gpu_duration_nanoseconds == 0 or
        telemetry.command_status !=
            completed_command_buffer_status)
        return Error.InvalidDispatchEvidence;
    const duration_nanoseconds =
        (gpu_end - gpu_start) * 1_000_000_000.0;
    if (!std.math.isFinite(duration_nanoseconds) or
        duration_nanoseconds < 1 or
        duration_nanoseconds >=
            @as(f64, @floatFromInt(std.math.maxInt(u64))) or
        telemetry.gpu_duration_nanoseconds !=
            @as(u64, @intFromFloat(duration_nanoseconds)))
        return Error.InvalidDispatchEvidence;
}

pub fn dispatchTelemetryRootV1(
    telemetry: metal.MetalDispatchTelemetry,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_telemetry_domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, telemetry.current_allocated_before);
    hashU64(&hash, telemetry.current_allocated_after);
    hashU64(&hash, telemetry.gpu_start_time_bits);
    hashU64(&hash, telemetry.gpu_end_time_bits);
    hashU64(&hash, telemetry.gpu_duration_nanoseconds);
    hashU64(&hash, telemetry.command_status);
    return finish(&hash);
}

pub fn dispatchSubmissionRootV1(
    observation: MetalLeaseTreeDispatchObservationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_submission_domain);
    hashU64(&hash, observation.abi_version);
    hashU64(&hash, observation.dispatch_generation);
    hashU64(&hash, observation.allocation_count);
    hashU64(&hash, observation.materialized_bytes);
    hash.update(&observation.authority_sha256);
    hash.update(&observation.admission_sha256);
    hash.update(&observation.lease_sha256);
    hash.update(&observation.backend_object_set_sha256);
    hash.update(&observation.pin_sha256);
    hash.update(&observation.dispatch_request_sha256);
    hash.update(&observation.dispatch_authority_sha256);
    hash.update(&observation.queue_authority_sha256);
    hash.update(&observation.geometry.geometry_sha256);
    hash.update(&observation.roles.roles_sha256);
    hash.update(&observation.packed_weights_input_sha256);
    hash.update(&observation.scales_input_sha256);
    hash.update(&observation.vector_input_sha256);
    return finish(&hash);
}

pub fn dispatchBackendCompletionRootV1(
    submission_sha256: Digest,
    telemetry_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_backend_completion_domain);
    hashU64(&hash, dispatch_observation_abi);
    hash.update(&submission_sha256);
    hash.update(&telemetry_sha256);
    return finish(&hash);
}

pub fn metalDispatchObservationRootV1(
    observation: MetalLeaseTreeDispatchObservationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_observation_domain);
    hashU64(&hash, observation.abi_version);
    hashU64(&hash, @intFromEnum(observation.outcome));
    hashU64(&hash, observation.dispatch_generation);
    hashU64(&hash, observation.allocation_count);
    hashU64(&hash, observation.materialized_bytes);
    hash.update(&observation.authority_sha256);
    hash.update(&observation.admission_sha256);
    hash.update(&observation.lease_sha256);
    hash.update(&observation.backend_object_set_sha256);
    hash.update(&observation.pin_sha256);
    hash.update(&observation.dispatch_request_sha256);
    hash.update(&observation.dispatch_authority_sha256);
    hash.update(&observation.queue_authority_sha256);
    hash.update(&observation.geometry.geometry_sha256);
    hash.update(&observation.roles.roles_sha256);
    hash.update(&observation.packed_weights_input_sha256);
    hash.update(&observation.scales_input_sha256);
    hash.update(&observation.vector_input_sha256);
    hash.update(&observation.submission_sha256);
    hash.update(&observation.telemetry_sha256);
    hash.update(&observation.backend_completion_sha256);
    hash.update(&observation.output_sha256);
    hash.update(&observation.terminal_sha256);
    return finish(&hash);
}

pub fn validateMetalLeaseTreeDispatchObservationV1(
    observation: MetalLeaseTreeDispatchObservationV1,
) Error!void {
    try validateMatvecGeometryV1(observation.geometry);
    try validateMatvecRoleEvidenceV1(observation.roles);
    try validateMetalDispatchTelemetryV1(
        observation.telemetry,
    );
    const exact_bytes = std.math.add(
        u64,
        observation.geometry.packed_bytes,
        observation.geometry.scales_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    const exact_with_input = std.math.add(
        u64,
        exact_bytes,
        observation.geometry.input_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    const total_bytes = std.math.add(
        u64,
        exact_with_input,
        observation.geometry.output_bytes,
    ) catch return Error.InvalidDispatchEvidence;
    if (observation.abi_version !=
        dispatch_observation_abi or
        observation.outcome != .succeeded or
        observation.dispatch_generation == 0 or
        observation.allocation_count != 4 or
        observation.materialized_bytes != total_bytes or
        digestIsZero(observation.authority_sha256) or
        digestIsZero(observation.admission_sha256) or
        digestIsZero(observation.lease_sha256) or
        digestIsZero(
            observation.backend_object_set_sha256,
        ) or digestIsZero(observation.pin_sha256) or
        digestIsZero(observation.dispatch_request_sha256) or
        digestIsZero(
            observation.dispatch_authority_sha256,
        ) or digestIsZero(
        observation.queue_authority_sha256,
    ) or device.digestEqual(
        observation.dispatch_authority_sha256,
        observation.queue_authority_sha256,
    ) or digestIsZero(
        observation.packed_weights_input_sha256,
    ) or digestIsZero(
        observation.scales_input_sha256,
    ) or digestIsZero(
        observation.vector_input_sha256,
    ) or digestIsZero(observation.submission_sha256) or
        !device.digestEqual(
            observation.submission_sha256,
            dispatchSubmissionRootV1(observation),
        ) or digestIsZero(observation.telemetry_sha256) or
        !device.digestEqual(
            observation.telemetry_sha256,
            dispatchTelemetryRootV1(observation.telemetry),
        ) or digestIsZero(
        observation.backend_completion_sha256,
    ) or !device.digestEqual(
        observation.backend_completion_sha256,
        dispatchBackendCompletionRootV1(
            observation.submission_sha256,
            observation.telemetry_sha256,
        ),
    ) or digestIsZero(observation.output_sha256) or
        digestIsZero(observation.terminal_sha256) or
        digestIsZero(observation.observation_sha256) or
        !device.digestEqual(
            observation.observation_sha256,
            metalDispatchObservationRootV1(observation),
        ))
        return Error.InvalidDispatchEvidence;
    var terminal: lease_tree.DispatchTerminalEvidenceV1 = .{
        .outcome = observation.outcome,
        .dispatch_generation = observation.dispatch_generation,
        .dispatch_authority_sha256 = observation.dispatch_authority_sha256,
        .queue_authority_sha256 = observation.queue_authority_sha256,
        .pin_sha256 = observation.pin_sha256,
        .dispatch_request_sha256 = observation.dispatch_request_sha256,
        .submission_sha256 = observation.submission_sha256,
        .backend_completion_sha256 = observation.backend_completion_sha256,
        .output_sha256 = observation.output_sha256,
    };
    terminal.terminal_sha256 =
        lease_tree.dispatchTerminalRootV1(terminal);
    lease_tree.validateDispatchTerminalV1(terminal) catch
        return Error.InvalidDispatchEvidence;
    if (!device.digestEqual(
        terminal.terminal_sha256,
        observation.terminal_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

pub fn validateMetalLeaseTreeDispatchPayloadV1(
    observation: MetalLeaseTreeDispatchObservationV1,
    packed_weights: []const u8,
    scales: []const f32,
    input: []const f32,
    output: []const f32,
) Error!void {
    try validateMetalLeaseTreeDispatchObservationV1(
        observation,
    );
    if (@as(u64, @intCast(packed_weights.len)) !=
        observation.geometry.packed_bytes or
        @as(u64, @intCast(scales.len)) !=
            observation.geometry.scale_count or
        @as(u64, @intCast(input.len)) !=
            observation.geometry.input_count or
        @as(u64, @intCast(output.len)) !=
            observation.geometry.output_count or
        !device.digestEqual(
            observation.packed_weights_input_sha256,
            matvecPackedWeightsInputRootV1(packed_weights),
        ) or !device.digestEqual(
        observation.scales_input_sha256,
        matvecScalesInputRootV1(scales),
    ) or !device.digestEqual(
        observation.vector_input_sha256,
        matvecVectorInputRootV1(input),
    ) or !device.digestEqual(
        observation.output_sha256,
        matvecOutputRootV1(output),
    ))
        return Error.InvalidDispatchEvidence;
}

pub fn validateMetalLeaseTreeDispatchObservationForPinV1(
    observation: MetalLeaseTreeDispatchObservationV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    terminal: lease_tree.DispatchTerminalEvidenceV1,
) Error!void {
    try validateMetalLeaseTreeDispatchObservationV1(
        observation,
    );
    lease_tree.validateDispatchTerminalForPinV1(
        terminal,
        pin,
    ) catch return Error.InvalidDispatchEvidence;
    if (terminal.outcome != observation.outcome or
        terminal.dispatch_generation !=
            observation.dispatch_generation or
        pin.allocation_count != observation.allocation_count or
        pin.pinned_device_bytes !=
            observation.materialized_bytes or
        !device.digestEqual(
            pin.authority_sha256,
            observation.authority_sha256,
        ) or !device.digestEqual(
        pin.admission_sha256,
        observation.admission_sha256,
    ) or !device.digestEqual(
        pin.lease_sha256,
        observation.lease_sha256,
    ) or !device.digestEqual(
        pin.backend_object_set_sha256,
        observation.backend_object_set_sha256,
    ) or !device.digestEqual(
        terminal.pin_sha256,
        observation.pin_sha256,
    ) or !device.digestEqual(
        terminal.dispatch_request_sha256,
        observation.dispatch_request_sha256,
    ) or !device.digestEqual(
        terminal.dispatch_authority_sha256,
        observation.dispatch_authority_sha256,
    ) or !device.digestEqual(
        terminal.queue_authority_sha256,
        observation.queue_authority_sha256,
    ) or !device.digestEqual(
        terminal.submission_sha256,
        observation.submission_sha256,
    ) or !device.digestEqual(
        terminal.backend_completion_sha256,
        observation.backend_completion_sha256,
    ) or !device.digestEqual(
        terminal.output_sha256,
        observation.output_sha256,
    ) or !device.digestEqual(
        terminal.terminal_sha256,
        observation.terminal_sha256,
    ))
        return Error.InvalidDispatchEvidence;
}

pub fn observationRootV1(
    value: MetalAllocationObservationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(observation_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.authority_sha256);
    hash.update(&value.admission_sha256);
    hash.update(&value.allocation_call_sha256);
    hash.update(&value.binding_sha256);
    hash.update(&value.backend_object_sha256);
    hash.update(&value.object_sha256);
    hashU64(&hash, value.adapter_slot_index);
    hashU64(&hash, value.reserved);
    hashU64(&hash, value.backend_object_generation);
    hashU64(&hash, value.ordinal);
    hashU64(&hash, value.device_registry_id);
    hashU64(&hash, value.requested_bytes);
    hashU64(&hash, value.charged_resource_bytes);
    hashU64(&hash, value.buffer_length_bytes);
    hashU64(&hash, value.resource_allocated_size_bytes);
    hashU64(&hash, value.storage_mode);
    hashU64(&hash, value.cpu_cache_mode);
    return finish(&hash);
}

pub fn validateObservationV1(
    value: MetalAllocationObservationV1,
    authority: allocation.AllocationAuthorityV1,
    expected_device_registry_id: u64,
) Error!void {
    allocation.validateAuthorityV1(authority) catch
        return Error.InvalidObservation;
    const reconstructed_object: allocation.BackendObjectV1 = .{
        .allocation_call_sha256 = value.allocation_call_sha256,
        .binding_sha256 = value.binding_sha256,
        .backend_object_sha256 = value.backend_object_sha256,
        .backend_object_generation = value.backend_object_generation,
        .allocated_bytes = value.charged_resource_bytes,
        .object_sha256 = value.object_sha256,
    };
    if (value.abi_version != observation_abi or
        value.reserved != 0 or
        !device.digestEqual(
            value.authority_sha256,
            authority.authority_sha256,
        ) or
        digestIsZero(value.admission_sha256) or
        digestIsZero(value.allocation_call_sha256) or
        digestIsZero(value.binding_sha256) or
        digestIsZero(value.backend_object_sha256) or
        digestIsZero(value.object_sha256) or
        value.adapter_slot_index >=
            authority.maximum_live_objects or
        value.backend_object_generation == 0 or
        value.ordinal >= authority.maximum_live_objects or
        expected_device_registry_id == 0 or
        value.device_registry_id != expected_device_registry_id or
        value.requested_bytes == 0 or
        value.requested_bytes >
            authority.max_single_allocation_bytes or
        value.charged_resource_bytes >
            authority.max_single_allocation_bytes or
        value.charged_resource_bytes >
            authority.max_total_device_bytes or
        value.charged_resource_bytes != value.requested_bytes or
        value.buffer_length_bytes !=
            value.charged_resource_bytes or
        value.resource_allocated_size_bytes <
            value.buffer_length_bytes or
        value.storage_mode != metal.shared_storage_mode or
        value.cpu_cache_mode != metal.default_cpu_cache_mode or
        !device.digestEqual(
            value.backend_object_sha256,
            objectIdentityV1(
                authority,
                expected_device_registry_id,
                value.adapter_slot_index,
                value.backend_object_generation,
                value.allocation_call_sha256,
            ),
        ) or
        !device.digestEqual(
            value.object_sha256,
            allocation.backendObjectRootV1(
                reconstructed_object,
            ),
        ) or
        digestIsZero(value.observation_sha256) or
        !device.digestEqual(
            value.observation_sha256,
            observationRootV1(value),
        ))
        return Error.InvalidObservation;
}

fn makeObservationV1(
    authority: allocation.AllocationAuthorityV1,
    slot_index: u32,
    slot: MetalAllocationSlotV1,
    info: metal.MetalBufferInfo,
) MetalAllocationObservationV1 {
    var result: MetalAllocationObservationV1 = .{
        .authority_sha256 = authority.authority_sha256,
        .admission_sha256 = slot.call.admission_sha256,
        .allocation_call_sha256 = slot.call.call_sha256,
        .binding_sha256 = slot.call.binding_sha256,
        .backend_object_sha256 = slot.object.backend_object_sha256,
        .object_sha256 = slot.object.object_sha256,
        .adapter_slot_index = slot_index,
        .backend_object_generation = slot.generation,
        .ordinal = slot.call.ordinal,
        .device_registry_id = info.device_registry_id,
        .requested_bytes = slot.call.requested_bytes,
        .charged_resource_bytes = slot.call.charged_bytes,
        .buffer_length_bytes = info.resource_length,
        .resource_allocated_size_bytes = info.allocated_size,
        .storage_mode = info.storage_mode,
        .cpu_cache_mode = info.cpu_cache_mode,
    };
    result.observation_sha256 = observationRootV1(result);
    return result;
}

fn lossDispatchReconciliationAdapterChallengeRootV1(
    adapter: *const MetalAllocationAdapterV1,
    observation: lifecycle.ObservationV1,
    lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    intent: lease_tree.DispatchPinIntentV1,
    retained_object_set: allocation.BackendObjectSetV1,
    source: ValidatedLossDispatchReconciliationSourceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        loss_dispatch_reconciliation_adapter_challenge_domain,
    );
    hashU64(&hash, adapter_abi);
    hash.update(&adapter.authority.authority_sha256);
    hash.update(&adapter.authority.backend_authority_sha256);
    hash.update(&adapter.dispatch_authority_sha256);
    hash.update(&adapter.queue_authority_sha256);
    hashU64(&hash, adapter.adapter_nonce);
    hashU64(&hash, adapter.adapter_identity.abi_version);
    for (adapter.adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter.adapter_identity.adapter_instance);
    hash.update(&adapter.device_sha256);
    hash.update(&adapter.placement_sha256);
    hash.update(&lease.admission_sha256);
    hash.update(&lease.lease_sha256);
    hash.update(&lease.allocation_leaf_set_sha256);
    hash.update(&lease.backend_object_set_sha256);
    hash.update(&pin.pin_sha256);
    hash.update(&intent.intent_sha256);
    hash.update(&retained_object_set.object_set_sha256);
    hash.update(&source.pending.request.request_sha256);
    hash.update(&source.pending.ticket.ticket_sha256);
    hash.update(&source.pending.draft.submission_sha256);
    hash.update(&source.quarantine.quarantine_sha256);
    hash.update(&source.result.failure.failure_sha256);
    hash.update(&source.result.terminal.terminal_sha256);
    hashU64(&hash, @intFromEnum(observation.source));
    hashU64(&hash, @intFromEnum(observation.evidence_class));
    hashU64(&hash, observation.source_sequence);
    hash.update(&observation.source_instance_sha256);
    hash.update(&observation.observation_sha256);
    return finish(&hash);
}

fn lossDispatchReconciliationSettlementRootV1(
    adapter: *const MetalAllocationAdapterV1,
    permit: MetalLossDispatchReconciliationPermitV1,
    completion: lease_tree.LeaseTreeDispatchCompletionV1,
    bank_permit: resource.LeasePinPermitV1,
    bank_completion: resource.LeasePinCompletionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(loss_dispatch_reconciliation_settlement_domain);
    hashU64(&hash, adapter_abi);
    hashU64(&hash, @intFromEnum(permit.mode));
    hash.update(&permit.plan.plan_sha256);
    hash.update(&permit.retention.retention_sha256);
    hash.update(&permit.selected_entry.entry_sha256);
    hash.update(&permit.lease.lease_sha256);
    hash.update(&permit.pin.pin_sha256);
    hash.update(&permit.failure.failure_sha256);
    hash.update(&permit.terminal.terminal_sha256);
    hash.update(&completion.completion_sha256);
    hash.update(&completion.bank_completion_sha256);
    hash.update(&lease_tree.leasePinPermitSha256V1(bank_permit));
    hash.update(&lease_tree.leasePinCompletionSha256V1(
        bank_completion,
    ));
    hash.update(&adapter.authority.authority_sha256);
    hash.update(&adapter.dispatch_authority_sha256);
    hash.update(&adapter.queue_authority_sha256);
    hash.update(&adapter.device_sha256);
    hash.update(&adapter.placement_sha256);
    hashU64(&hash, adapter.adapter_identity.abi_version);
    for (adapter.adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter.adapter_identity.adapter_instance);
    // Exactly one registered command is finalized. No global command count
    // enters this root, so sibling native commands remain outside authority.
    hashU64(&hash, 1);
    return finish(&hash);
}

fn lossRetirementAdapterChallengeRootV1(
    adapter: *const MetalAllocationAdapterV1,
    observation: lifecycle.ObservationV1,
    lease: lease_tree.LeaseTreeDeviceAllocationLeaseV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(loss_retirement_adapter_challenge_domain);
    hashU64(&hash, adapter_abi);
    hash.update(&adapter.authority.authority_sha256);
    hash.update(&adapter.authority.backend_authority_sha256);
    hashU64(&hash, adapter.adapter_nonce);
    hashU64(&hash, adapter.adapter_identity.abi_version);
    for (adapter.adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter.adapter_identity.adapter_instance);
    hash.update(&adapter.device_sha256);
    hash.update(&adapter.placement_sha256);
    hash.update(&lease.admission_sha256);
    hash.update(&lease.lease_sha256);
    hash.update(&lease.allocation_leaf_set_sha256);
    hash.update(&lease.backend_object_set_sha256);
    hashU64(&hash, lease.allocation_count);
    hashU64(&hash, lease.materialized_bytes);
    hashU64(&hash, @intFromEnum(observation.source));
    hashU64(&hash, @intFromEnum(observation.evidence_class));
    hashU64(&hash, observation.source_sequence);
    hash.update(&observation.source_instance_sha256);
    hash.update(&observation.observation_sha256);
    return finish(&hash);
}

fn lossRetirementSettlementRootV1(
    adapter: *const MetalAllocationAdapterV1,
    plan: loss_retirement.LossRetirementPlanV1,
    terminal: lease_tree.LeaseTreeAllocationTerminalReceiptV1,
    reference_release_count: u64,
    backend_live_buffers: u64,
    native_live_buffers: u64,
    native_live_commands: u64,
    backend_live_weights: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(loss_retirement_settlement_domain);
    hashU64(&hash, adapter_abi);
    hash.update(&plan.plan_sha256);
    hash.update(&terminal.terminal_sha256);
    hash.update(&adapter.authority.authority_sha256);
    hash.update(&adapter.device_sha256);
    hash.update(&adapter.placement_sha256);
    hashU64(&hash, adapter.adapter_identity.abi_version);
    for (adapter.adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter.adapter_identity.adapter_instance);
    hashU64(&hash, reference_release_count);
    // These zeroes are explicit adapter/native registry observations at
    // completion, not a claim about physical pages or reusable capacity.
    hashU64(&hash, adapter.used_resource_bytes);
    hashU64(&hash, adapter.observed_allocated_size_bytes);
    hashU64(&hash, backend_live_buffers);
    hashU64(&hash, native_live_buffers);
    hashU64(&hash, native_live_commands);
    hashU64(&hash, backend_live_weights);
    return finish(&hash);
}

fn backendAuthorityRootV1(
    authority_epoch: u64,
    adapter_nonce: u64,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    selected: device.DeviceInventoryEntryV1,
    limits: metal.MetalAllocationLimits,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(authority_domain);
    hashU64(&hash, adapter_abi);
    hashU64(&hash, authority_epoch);
    hashU64(&hash, adapter_nonce);
    hashU64(&hash, adapter_identity.abi_version);
    for (adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter_identity.adapter_instance);
    hash.update(&selected.capability.capability_sha256);
    hash.update(&selected.entry_sha256);
    hashU64(&hash, limits.abi_version);
    hashU64(&hash, limits.device_registry_id);
    hashU64(&hash, limits.max_buffer_length);
    hashU64(&hash, limits.resource_granularity);
    hashU64(&hash, limits.storage_mode);
    hashU64(&hash, limits.cpu_cache_mode);
    return finish(&hash);
}

fn dispatchAuthorityRootV1(
    authority: allocation.AllocationAuthorityV1,
    adapter_nonce: u64,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    limits: metal.MetalAllocationLimits,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_authority_domain);
    hashU64(&hash, adapter_abi);
    hash.update(&authority.authority_sha256);
    hash.update(&authority.backend_authority_sha256);
    hashU64(&hash, adapter_nonce);
    hashU64(&hash, adapter_identity.abi_version);
    for (adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter_identity.adapter_instance);
    hashU64(&hash, limits.abi_version);
    hashU64(&hash, limits.device_registry_id);
    hashU64(&hash, limits.max_buffer_length);
    hashU64(&hash, limits.resource_granularity);
    hashU64(&hash, limits.storage_mode);
    hashU64(&hash, limits.cpu_cache_mode);
    hashU64(&hash, authority.max_queue_slots);
    return finish(&hash);
}

fn queueAuthorityRootV1(
    dispatch_authority_sha256: Digest,
    adapter_identity: metal.MetalAllocationAdapterIdentity,
    limits: metal.MetalAllocationLimits,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(queue_authority_domain);
    hashU64(&hash, adapter_abi);
    hash.update(&dispatch_authority_sha256);
    for (adapter_identity.context_nonce) |word|
        hashU64(&hash, word);
    hashU64(&hash, adapter_identity.adapter_instance);
    hashU64(&hash, limits.device_registry_id);
    // V1 owns one synchronous MTLCommandQueue use at a time.
    hashU64(&hash, 1);
    return finish(&hash);
}

fn objectIdentityV1(
    authority: allocation.AllocationAuthorityV1,
    device_registry_id: u64,
    slot_index: u32,
    generation: u64,
    call_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(object_identity_domain);
    hash.update(&authority.authority_sha256);
    hashU64(&hash, device_registry_id);
    hashU64(&hash, slot_index);
    hashU64(&hash, generation);
    hash.update(&call_sha256);
    return finish(&hash);
}

fn digestIsZero(value: Digest) bool {
    return device.digestEqual(value, allocation.zero_digest);
}

fn hashByteSliceV1(
    domain: []const u8,
    values: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, values.len);
    hash.update(values);
    return finish(&hash);
}

fn hashF32SliceV1(
    domain: []const u8,
    values: []const f32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hashU64(&hash, dispatch_observation_abi);
    hashU64(&hash, values.len);
    for (values) |value| hashU32(
        &hash,
        @as(u32, @bitCast(value)),
    );
    return finish(&hash);
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn testDispatchDigest(label: []const u8) Digest {
    return native.contract.digestV1(label);
}

const TestAsyncEvidenceFixture = struct {
    request: MetalMatvecDispatchRequestV1,
    intent: lease_tree.DispatchPinIntentV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
    draft: MetalLeaseTreeDispatchObservationV1,
    ticket: MetalAsyncDispatchTicketV1,
    device_sha256: Digest,
    placement_sha256: Digest,
};

fn makeTestAsyncEvidenceFixture(
    ticket_generation: u64,
) !TestAsyncEvidenceFixture {
    const geometry = try makeMatvecGeometryV1(8, 64, 37);
    const bindings: MetalMatvecAllocationBindingsV1 = .{
        .packed_weights_sha256 = testDispatchDigest("async packed binding"),
        .scales_sha256 = testDispatchDigest("async scales binding"),
        .input_sha256 = testDispatchDigest("async input binding"),
        .output_sha256 = testDispatchDigest("async output binding"),
    };
    const attempt = try makeMetalMatvecPreSubmitAttemptV1(
        bindings,
        geometry.packed_bytes,
        geometry.scale_count,
        geometry.input_count,
        geometry.output_count,
        geometry.group_size,
        geometry.in_features,
        geometry.out_features,
    );
    const dispatch_authority_sha256 =
        testDispatchDigest("async dispatch authority");
    const queue_authority_sha256 =
        testDispatchDigest("async queue authority");
    const request = try makeMetalMatvecDispatchRequestV1(
        17,
        dispatch_authority_sha256,
        queue_authority_sha256,
        attempt,
    );
    const total_bytes = geometry.packed_bytes +
        geometry.scales_bytes +
        geometry.input_bytes +
        geometry.output_bytes;

    var slots = [_]resource.Slot{.{}};
    var roots = [_]resource.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource.LeaseNodeSlot{.{}} ** 5;
    var pin_slots = [_]resource.LeasePinSlotV1{.{}};
    var bank = try resource.Bank.initWithLeaseTreePinStorage(
        &slots,
        &roots,
        &nodes,
        &pin_slots,
        .{
            .device_bytes = total_bytes,
            .queue_slots = 1,
        },
        0x4153_594e_4354,
    );
    const parent = try bank.commit(
        try bank.reserve(1, .{ .queue_slots = 1 }),
    );
    var tree = try bank.openLeaseTree(
        parent,
        2,
        3,
        .{ .device_bytes = total_bytes },
    );
    const scoped = try bank.openLeaseScope(
        tree,
        4,
        5,
        .{ .device_bytes = total_bytes },
    );
    tree = scoped.tree;
    var session_owner: u8 = 0;
    const session_id = @intFromPtr(&session_owner);
    const request_epoch: u64 = 6;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        request_epoch,
        session_id,
    );
    const specs = [_]resource.LeaseAllocationSpecV1{
        .{
            .scope = scoped.scope,
            .node_key = 10,
            .binding_key = 20,
            .claim = .{
                .device_bytes = geometry.packed_bytes,
            },
        },
        .{
            .scope = scoped.scope,
            .node_key = 11,
            .binding_key = 21,
            .claim = .{
                .device_bytes = geometry.scales_bytes,
            },
        },
        .{
            .scope = scoped.scope,
            .node_key = 12,
            .binding_key = 22,
            .claim = .{
                .device_bytes = geometry.input_bytes,
            },
        },
        .{
            .scope = scoped.scope,
            .node_key = 13,
            .binding_key = 23,
            .claim = .{
                .device_bytes = geometry.output_bytes,
            },
        },
    };
    var leaves: [specs.len]resource.LeaseNodeV1 =
        undefined;
    const reserved = try bank.reserveAllocationsForSession(
        tree,
        request_epoch,
        session_id,
        0,
        &specs,
        &leaves,
    );
    tree = try bank.commitAllocationsAfterAllocate(
        reserved.batch,
    );
    const acquired = try bank.acquireLeasePinsForSession(
        tree,
        scoped.scope,
        request_epoch,
        session_id,
        0,
        30,
        &leaves,
    );

    var pin: lease_tree.LeaseTreeDispatchPinV1 = .{
        .coordinator_epoch = 7,
        .allocation_generation = 8,
        .dispatch_generation = 9,
        .authority_sha256 = testDispatchDigest("async allocation authority"),
        .dispatch_authority_sha256 = dispatch_authority_sha256,
        .queue_authority_sha256 = queue_authority_sha256,
        .request_sha256 = testDispatchDigest("async allocation request"),
        .admission_sha256 = testDispatchDigest("async allocation admission"),
        .lease_sha256 = testDispatchDigest("async allocation lease"),
        .parent_receipt_sha256 = allocation.resourceReceiptRootV1(
            acquired.tree.parent,
        ),
        .allocation_leaf_set_sha256 = testDispatchDigest("async allocation leaves"),
        .backend_object_set_sha256 = testDispatchDigest("async backend objects"),
        .dispatch_request_sha256 = request.request_sha256,
        .publication_binding_sha256 = testDispatchDigest("async publication binding"),
        .bank_pin_sha256 = lease_tree.leasePinPermitSha256V1(
            acquired.permit,
        ),
        .pinned_tree = acquired.tree,
        .scope = scoped.scope,
        .allocation_count = 4,
        .pinned_device_bytes = total_bytes,
    };
    pin.pin_sha256 = lease_tree.dispatchPinRootV1(pin);
    try lease_tree.validateDispatchPinV1(pin);
    var intent: lease_tree.DispatchPinIntentV1 = .{
        .coordinator_epoch = pin.coordinator_epoch,
        .allocation_generation = pin.allocation_generation,
        .dispatch_generation = pin.dispatch_generation,
        .allocation_count = pin.allocation_count,
        .pinned_device_bytes = pin.pinned_device_bytes,
        .authority_sha256 = pin.authority_sha256,
        .dispatch_authority_sha256 = pin.dispatch_authority_sha256,
        .queue_authority_sha256 = pin.queue_authority_sha256,
        .request_sha256 = pin.request_sha256,
        .admission_sha256 = pin.admission_sha256,
        .lease_sha256 = pin.lease_sha256,
        .parent_receipt_sha256 = pin.parent_receipt_sha256,
        .allocation_leaf_set_sha256 = pin.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = pin.backend_object_set_sha256,
        .scope_sha256 = lease_tree.leaseNodeSha256V1(pin.scope),
        .dispatch_request_sha256 = pin.dispatch_request_sha256,
        .publication_binding_sha256 = pin.publication_binding_sha256,
    };
    intent.intent_sha256 =
        lease_tree.dispatchPinIntentRootV1(intent);
    try lease_tree.validateDispatchPinIntentV1(intent);

    var roles: MetalMatvecRoleEvidenceV1 = .{
        .bindings = bindings,
        .packed_weights_object_sha256 = testDispatchDigest("async packed object"),
        .scales_object_sha256 = testDispatchDigest("async scales object"),
        .input_object_sha256 = testDispatchDigest("async input object"),
        .output_object_sha256 = testDispatchDigest("async output object"),
    };
    roles.roles_sha256 = matvecRoleEvidenceRootV1(roles);
    var draft: MetalLeaseTreeDispatchObservationV1 = .{
        .dispatch_generation = pin.dispatch_generation,
        .allocation_count = pin.allocation_count,
        .materialized_bytes = pin.pinned_device_bytes,
        .authority_sha256 = pin.authority_sha256,
        .admission_sha256 = pin.admission_sha256,
        .lease_sha256 = pin.lease_sha256,
        .backend_object_set_sha256 = pin.backend_object_set_sha256,
        .pin_sha256 = pin.pin_sha256,
        .dispatch_request_sha256 = pin.dispatch_request_sha256,
        .dispatch_authority_sha256 = pin.dispatch_authority_sha256,
        .queue_authority_sha256 = pin.queue_authority_sha256,
        .geometry = geometry,
        .roles = roles,
        .packed_weights_input_sha256 = testDispatchDigest("async packed input"),
        .scales_input_sha256 = testDispatchDigest("async scales input"),
        .vector_input_sha256 = testDispatchDigest("async vector input"),
    };
    draft.submission_sha256 =
        dispatchSubmissionRootV1(draft);
    try validateMetalAsyncDispatchDraftForPinV1(
        draft,
        request,
        pin,
    );
    const ticket = try makeMetalAsyncDispatchTicketV1(
        ticket_generation,
        request,
        pin,
        draft,
    );
    return .{
        .request = request,
        .intent = intent,
        .pin = pin,
        .draft = draft,
        .ticket = ticket,
        .device_sha256 = testDispatchDigest("async native device"),
        .placement_sha256 = testDispatchDigest("async native placement"),
    };
}

const TestNativeAsyncErrorFixture = struct {
    submission: metal.MetalAsyncSubmission,
    completion: metal.MetalAsyncCompletion,
};

fn makeTestNativeAsyncErrorFixture(
    ticket: MetalAsyncDispatchTicketV1,
) TestNativeAsyncErrorFixture {
    const token: metal.MetalCommandToken = .{
        .context_nonce = .{ 0x11, 0x22, 0x33, 0x44 },
        .generation = 71,
    };
    return .{
        .submission = .{
            .token = token,
            .submission_binding = ticket.ticket_sha256,
            .disposition = .submitted,
        },
        .completion = .{
            .token = token,
            .submission_binding = ticket.ticket_sha256,
            .current_allocated_before = 4_096,
            .current_allocated_after = 4_352,
            .gpu_start_time = 12.5,
            .gpu_end_time = 12.75,
            .error_code = -73,
            .state = .@"error",
            .command_status = async_native_command_status_error,
            .error_domain_kind = .command_buffer,
            .error_present = 1,
        },
    };
}

fn resealTestAsyncTicket(
    ticket: *MetalAsyncDispatchTicketV1,
) void {
    ticket.ticket_sha256 =
        metalAsyncDispatchTicketRootV1(ticket.*);
}

fn resealTestAsyncQuarantine(
    value: *MetalAsyncDispatchQuarantineV1,
) void {
    value.quarantine_sha256 =
        metalAsyncDispatchQuarantineRootV1(value.*);
}

fn resealTestAsyncTerminalFailure(
    value: *MetalAsyncDispatchTerminalFailureV1,
    pin: lease_tree.LeaseTreeDispatchPinV1,
) !lease_tree.DispatchTerminalEvidenceV1 {
    value.native_terminal_sha256 =
        metalAsyncDispatchNativeTerminalRootV1(value.*);
    value.backend_completion_sha256 =
        metalAsyncDispatchFailureBackendCompletionRootV1(
            value.*,
        );
    const terminal = try lease_tree.makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        value.submission_sha256,
        value.backend_completion_sha256,
        allocation.zero_digest,
    );
    value.terminal_sha256 = terminal.terminal_sha256;
    value.failure_sha256 =
        metalAsyncDispatchTerminalFailureRootV1(value.*);
    return terminal;
}

fn resealTestDispatchObservation(
    observation: *MetalLeaseTreeDispatchObservationV1,
) void {
    observation.geometry.geometry_sha256 =
        matvecGeometryRootV1(observation.geometry);
    observation.roles.roles_sha256 =
        matvecRoleEvidenceRootV1(observation.roles);
    observation.submission_sha256 =
        dispatchSubmissionRootV1(observation.*);
    observation.telemetry_sha256 =
        dispatchTelemetryRootV1(observation.telemetry);
    observation.backend_completion_sha256 =
        dispatchBackendCompletionRootV1(
            observation.submission_sha256,
            observation.telemetry_sha256,
        );
    var terminal: lease_tree.DispatchTerminalEvidenceV1 = .{
        .outcome = observation.outcome,
        .dispatch_generation = observation.dispatch_generation,
        .dispatch_authority_sha256 = observation.dispatch_authority_sha256,
        .queue_authority_sha256 = observation.queue_authority_sha256,
        .pin_sha256 = observation.pin_sha256,
        .dispatch_request_sha256 = observation.dispatch_request_sha256,
        .submission_sha256 = observation.submission_sha256,
        .backend_completion_sha256 = observation.backend_completion_sha256,
        .output_sha256 = observation.output_sha256,
    };
    terminal.terminal_sha256 =
        lease_tree.dispatchTerminalRootV1(terminal);
    observation.terminal_sha256 = terminal.terminal_sha256;
    observation.observation_sha256 =
        metalDispatchObservationRootV1(observation.*);
}

fn makeTestDispatchObservation() !MetalLeaseTreeDispatchObservationV1 {
    const geometry = try makeMatvecGeometryV1(64, 37, 5);
    const gpu_start: f64 = 1.0;
    const gpu_end: f64 = 1.000_001;
    var roles: MetalMatvecRoleEvidenceV1 = .{
        .bindings = .{
            .packed_weights_sha256 = testDispatchDigest("packed binding"),
            .scales_sha256 = testDispatchDigest("scales binding"),
            .input_sha256 = testDispatchDigest("input binding"),
            .output_sha256 = testDispatchDigest("output binding"),
        },
        .packed_weights_object_sha256 = testDispatchDigest("packed object"),
        .scales_object_sha256 = testDispatchDigest("scales object"),
        .input_object_sha256 = testDispatchDigest("input object"),
        .output_object_sha256 = testDispatchDigest("output object"),
    };
    roles.roles_sha256 = matvecRoleEvidenceRootV1(roles);
    var observation: MetalLeaseTreeDispatchObservationV1 = .{
        .dispatch_generation = 7,
        .allocation_count = 4,
        .materialized_bytes = geometry.packed_bytes +
            geometry.scales_bytes +
            geometry.input_bytes +
            geometry.output_bytes,
        .authority_sha256 = testDispatchDigest("allocation authority"),
        .admission_sha256 = testDispatchDigest("allocation admission"),
        .lease_sha256 = testDispatchDigest("allocation lease"),
        .backend_object_set_sha256 = testDispatchDigest("allocation object set"),
        .pin_sha256 = testDispatchDigest("dispatch pin"),
        .dispatch_request_sha256 = testDispatchDigest("dispatch request"),
        .dispatch_authority_sha256 = testDispatchDigest("dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("queue authority"),
        .geometry = geometry,
        .roles = roles,
        .packed_weights_input_sha256 = testDispatchDigest("packed input"),
        .scales_input_sha256 = testDispatchDigest("scales input"),
        .vector_input_sha256 = testDispatchDigest("vector input"),
        .telemetry = .{
            .current_allocated_before = 4_096,
            .current_allocated_after = 4_096,
            .gpu_start_time_bits = @bitCast(gpu_start),
            .gpu_end_time_bits = @bitCast(gpu_end),
            .gpu_duration_nanoseconds = @intFromFloat(
                (gpu_end - gpu_start) * 1_000_000_000.0,
            ),
            .command_status = completed_command_buffer_status,
        },
        .output_sha256 = testDispatchDigest("dispatch output"),
    };
    resealTestDispatchObservation(&observation);
    return observation;
}

test "Metal async ticket binds exact request pin draft and live generation" {
    const fixture = try makeTestAsyncEvidenceFixture(1);
    try validateMetalAsyncDispatchTicketV1(
        fixture.ticket,
    );
    try validateMetalAsyncDispatchTicketForDispatchV1(
        fixture.ticket,
        1,
        fixture.request,
        fixture.pin,
        fixture.draft,
    );

    var unsealed = fixture.ticket;
    unsealed.ticket_generation += 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketV1(unsealed),
    );
    unsealed = fixture.ticket;
    unsealed.ticket_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketV1(unsealed),
    );

    var nonzero_slot = fixture.ticket;
    nonzero_slot.queue_slot = 1;
    resealTestAsyncTicket(&nonzero_slot);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketV1(nonzero_slot),
    );

    var coherent_submission = fixture.ticket;
    coherent_submission.submission_sha256 =
        testDispatchDigest("foreign async submission");
    resealTestAsyncTicket(&coherent_submission);
    try validateMetalAsyncDispatchTicketV1(
        coherent_submission,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketForDispatchV1(
            coherent_submission,
            1,
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );

    const foreign_request =
        try makeMetalMatvecDispatchRequestV1(
            fixture.request.request_generation + 1,
            fixture.request.dispatch_authority_sha256,
            fixture.request.queue_authority_sha256,
            fixture.request.attempt,
        );
    var foreign_request_pin = fixture.pin;
    foreign_request_pin.dispatch_request_sha256 =
        foreign_request.request_sha256;
    foreign_request_pin.pin_sha256 =
        lease_tree.dispatchPinRootV1(
            foreign_request_pin,
        );
    try lease_tree.validateDispatchPinV1(
        foreign_request_pin,
    );
    var foreign_request_draft = fixture.draft;
    foreign_request_draft.pin_sha256 =
        foreign_request_pin.pin_sha256;
    foreign_request_draft.dispatch_request_sha256 =
        foreign_request.request_sha256;
    foreign_request_draft.submission_sha256 =
        dispatchSubmissionRootV1(foreign_request_draft);
    const foreign_request_ticket =
        try makeMetalAsyncDispatchTicketV1(
            2,
            foreign_request,
            foreign_request_pin,
            foreign_request_draft,
        );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketForDispatchV1(
            foreign_request_ticket,
            2,
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );

    var foreign_pin = fixture.pin;
    foreign_pin.dispatch_generation += 1;
    foreign_pin.pin_sha256 =
        lease_tree.dispatchPinRootV1(foreign_pin);
    try lease_tree.validateDispatchPinV1(foreign_pin);
    var foreign_pin_draft = fixture.draft;
    foreign_pin_draft.dispatch_generation =
        foreign_pin.dispatch_generation;
    foreign_pin_draft.pin_sha256 = foreign_pin.pin_sha256;
    foreign_pin_draft.submission_sha256 =
        dispatchSubmissionRootV1(foreign_pin_draft);
    const foreign_pin_ticket =
        try makeMetalAsyncDispatchTicketV1(
            3,
            fixture.request,
            foreign_pin,
            foreign_pin_draft,
        );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketForDispatchV1(
            foreign_pin_ticket,
            3,
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );

    var foreign_draft = fixture.draft;
    foreign_draft.vector_input_sha256 =
        testDispatchDigest("foreign async vector");
    foreign_draft.submission_sha256 =
        dispatchSubmissionRootV1(foreign_draft);
    const foreign_submission_ticket =
        try makeMetalAsyncDispatchTicketV1(
            4,
            fixture.request,
            fixture.pin,
            foreign_draft,
        );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketForDispatchV1(
            foreign_submission_ticket,
            4,
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );

    var coherent_authority = fixture.ticket;
    coherent_authority.dispatch_authority_sha256 =
        testDispatchDigest("foreign async authority");
    coherent_authority.request.dispatch_authority_sha256 =
        coherent_authority.dispatch_authority_sha256;
    coherent_authority.request.request_sha256 =
        metalMatvecDispatchRequestRootV1(
            coherent_authority.request,
        );
    resealTestAsyncTicket(&coherent_authority);
    try validateMetalAsyncDispatchTicketV1(
        coherent_authority,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketForDispatchV1(
            coherent_authority,
            1,
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );
}

test "Metal async draft is canonical and completion-free" {
    const fixture = try makeTestAsyncEvidenceFixture(11);

    var unsealed = fixture.draft;
    unsealed.vector_input_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            unsealed,
            fixture.request,
            fixture.pin,
        ),
    );

    var completion_state = fixture.draft;
    completion_state.telemetry.command_status =
        completed_command_buffer_status;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            completion_state,
            fixture.request,
            fixture.pin,
        ),
    );
    completion_state = fixture.draft;
    completion_state.telemetry_sha256 =
        testDispatchDigest("draft telemetry");
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            completion_state,
            fixture.request,
            fixture.pin,
        ),
    );
    completion_state = fixture.draft;
    completion_state.backend_completion_sha256 =
        testDispatchDigest("draft completion");
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            completion_state,
            fixture.request,
            fixture.pin,
        ),
    );
    completion_state = fixture.draft;
    completion_state.output_sha256 =
        testDispatchDigest("draft output");
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            completion_state,
            fixture.request,
            fixture.pin,
        ),
    );
    completion_state = fixture.draft;
    completion_state.terminal_sha256 =
        testDispatchDigest("draft terminal");
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            completion_state,
            fixture.request,
            fixture.pin,
        ),
    );
    completion_state = fixture.draft;
    completion_state.observation_sha256 =
        testDispatchDigest("draft observation");
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            completion_state,
            fixture.request,
            fixture.pin,
        ),
    );
    completion_state = fixture.draft;
    completion_state.outcome = .terminal_failure;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchDraftForPinV1(
            completion_state,
            fixture.request,
            fixture.pin,
        ),
    );
}

test "Metal async ticket generation fences exhaustion and ABA replay" {
    const fixture = try makeTestAsyncEvidenceFixture(1);
    const second = try makeMetalAsyncDispatchTicketV1(
        2,
        fixture.request,
        fixture.pin,
        fixture.draft,
    );
    try std.testing.expect(!device.digestEqual(
        fixture.ticket.ticket_sha256,
        second.ticket_sha256,
    ));
    try validateMetalAsyncDispatchTicketForDispatchV1(
        second,
        2,
        fixture.request,
        fixture.pin,
        fixture.draft,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketForDispatchV1(
            fixture.ticket,
            2,
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        makeMetalAsyncDispatchTicketV1(
            0,
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        makeMetalAsyncDispatchTicketV1(
            std.math.maxInt(u64),
            fixture.request,
            fixture.pin,
            fixture.draft,
        ),
    );

    var exhausted = fixture.ticket;
    exhausted.ticket_generation = std.math.maxInt(u64);
    resealTestAsyncTicket(&exhausted);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTicketV1(exhausted),
    );

    var exact_second = fixture.ticket;
    exact_second.ticket_generation = 2;
    resealTestAsyncTicket(&exact_second);
    try std.testing.expectEqualDeep(second, exact_second);
}

test "Metal async quarantine shapes are sticky and explicitly nonterminal" {
    const fixture = try makeTestAsyncEvidenceFixture(21);
    const Case = struct {
        reason: MetalAsyncDispatchQuarantineReasonV1,
        disposition: MetalAsyncNativeDispositionV1,
        status: u64,
        completion_observed: u64,
        error_domain: MetalAsyncErrorDomainKindV1,
    };
    const cases = [_]Case{
        .{
            .reason = .submission_ambiguous,
            .disposition = .commit_started,
            .status = async_native_command_status_unobserved,
            .completion_observed = 0,
            .error_domain = .native_bridge,
        },
        .{
            .reason = .completion_unknown,
            .disposition = .submitted,
            .status = async_native_command_status_error,
            .completion_observed = 1,
            .error_domain = .native_bridge,
        },
        .{
            .reason = .invalid_completion,
            .disposition = .terminal_status_observed,
            .status = async_native_command_status_completed,
            .completion_observed = 1,
            .error_domain = .completion_validation,
        },
        .{
            .reason = .terminal_command_error,
            .disposition = .terminal_status_observed,
            .status = async_native_command_status_error,
            .completion_observed = 1,
            .error_domain = .command_buffer,
        },
    };
    try std.testing.expect(
        !@hasField(
            MetalAsyncDispatchQuarantineV1,
            "terminal_sha256",
        ),
    );
    try std.testing.expect(
        !@hasField(
            MetalAsyncDispatchQuarantineV1,
            "output_sha256",
        ),
    );

    for (cases, 0..) |case, index| {
        const value =
            try makeMetalAsyncDispatchQuarantineV1(
                fixture.ticket,
                fixture.device_sha256,
                fixture.placement_sha256,
                case.reason,
                case.disposition,
                case.status,
                case.completion_observed,
                case.error_domain,
                if (case.reason ==
                    .submission_ambiguous)
                    async_submission_ambiguous_adapter_code
                else
                    0x100 + index,
            );
        try validateMetalAsyncDispatchQuarantineForTicketV1(
            value,
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
        );
        try validateMetalAsyncDispatchQuarantineReplayV1(
            value,
            value,
        );

        var wrong = value;
        wrong.native_disposition = switch (case.disposition) {
            .commit_started => .submitted,
            .submitted => .commit_started,
            .terminal_status_observed => .submitted,
            _ => .commit_started,
        };
        resealTestAsyncQuarantine(&wrong);
        try std.testing.expectError(
            Error.InvalidDispatchEvidence,
            validateMetalAsyncDispatchQuarantineV1(wrong),
        );

        wrong = value;
        wrong.native_command_status =
            if (case.status ==
            async_native_command_status_unobserved)
                async_native_command_status_completed
            else
                async_native_command_status_unobserved;
        resealTestAsyncQuarantine(&wrong);
        if (case.reason == .completion_unknown) {
            try validateMetalAsyncDispatchQuarantineV1(wrong);
        } else {
            try std.testing.expectError(
                Error.InvalidDispatchEvidence,
                validateMetalAsyncDispatchQuarantineV1(wrong),
            );
        }

        wrong = value;
        wrong.native_completion_observed =
            if (case.reason == .completion_unknown)
                2
            else
                1 - case.completion_observed;
        resealTestAsyncQuarantine(&wrong);
        try std.testing.expectError(
            Error.InvalidDispatchEvidence,
            validateMetalAsyncDispatchQuarantineV1(wrong),
        );

        wrong = value;
        wrong.error_domain_kind =
            if (case.error_domain == .native_bridge)
                .completion_validation
            else
                .native_bridge;
        resealTestAsyncQuarantine(&wrong);
        try std.testing.expectError(
            Error.InvalidDispatchEvidence,
            validateMetalAsyncDispatchQuarantineV1(wrong),
        );

        wrong = value;
        wrong.error_code_bits = 0;
        resealTestAsyncQuarantine(&wrong);
        try std.testing.expectError(
            Error.InvalidDispatchEvidence,
            validateMetalAsyncDispatchQuarantineV1(wrong),
        );
    }

    const retained =
        try makeMetalAsyncDispatchQuarantineV1(
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
            .completion_unknown,
            .submitted,
            77,
            1,
            .native_bridge,
            0x777,
        );
    _ = try makeMetalAsyncDispatchQuarantineV1(
        fixture.ticket,
        fixture.device_sha256,
        fixture.placement_sha256,
        .submission_ambiguous,
        .commit_started,
        async_native_command_status_unobserved,
        0,
        .native_bridge,
        async_submission_ambiguous_adapter_code,
    );
    var unsealed = retained;
    unsealed.error_code_bits += 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineV1(unsealed),
    );

    var coherent_error = retained;
    coherent_error.error_code_bits += 1;
    resealTestAsyncQuarantine(&coherent_error);
    try validateMetalAsyncDispatchQuarantineV1(
        coherent_error,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineReplayV1(
            coherent_error,
            retained,
        ),
    );

    var coherent_device = retained;
    coherent_device.device_sha256 =
        testDispatchDigest("foreign async device");
    resealTestAsyncQuarantine(&coherent_device);
    try validateMetalAsyncDispatchQuarantineV1(
        coherent_device,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineForTicketV1(
            coherent_device,
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
        ),
    );

    const second = try makeMetalAsyncDispatchTicketV1(
        22,
        fixture.request,
        fixture.pin,
        fixture.draft,
    );
    var foreign_ticket = retained;
    foreign_ticket.ticket = second;
    resealTestAsyncQuarantine(&foreign_ticket);
    try validateMetalAsyncDispatchQuarantineV1(
        foreign_ticket,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineForTicketV1(
            foreign_ticket,
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
        ),
    );

    var invalid = retained;
    invalid.reason = @enumFromInt(99);
    resealTestAsyncQuarantine(&invalid);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineV1(invalid),
    );
    invalid = retained;
    invalid.native_completion_observed = 2;
    resealTestAsyncQuarantine(&invalid);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineV1(invalid),
    );
    invalid = retained;
    invalid.device_sha256 = allocation.zero_digest;
    resealTestAsyncQuarantine(&invalid);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineV1(invalid),
    );
    invalid = retained;
    invalid.placement_sha256 = invalid.device_sha256;
    resealTestAsyncQuarantine(&invalid);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchQuarantineV1(invalid),
    );
}

test "Metal loss dispatch production source is exact native 5 1 11" {
    const fixture = try makeTestAsyncEvidenceFixture(30);

    var removed_native =
        makeTestNativeAsyncErrorFixture(fixture.ticket);
    removed_native.completion.error_code =
        @intCast(lifecycle.command_buffer_device_removed_error);
    const removed_quarantine =
        try makeMetalAsyncDispatchQuarantineV1(
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
            .terminal_command_error,
            .terminal_status_observed,
            lifecycle.command_buffer_status_error,
            1,
            .command_buffer,
            lifecycle.command_buffer_device_removed_error,
        );
    const removed_result =
        try makeMetalAsyncDispatchTerminalFailureV1(
            removed_quarantine,
            fixture.pin,
            fixture.draft,
            removed_native.submission,
            removed_native.completion,
        );
    try std.testing.expect(
        lossDispatchNativeDeviceRemovedSourceValidV1(
            removed_quarantine,
            removed_native.completion,
            removed_result.failure,
        ),
    );

    const generic_native =
        makeTestNativeAsyncErrorFixture(fixture.ticket);
    const generic_code: u64 =
        @bitCast(generic_native.completion.error_code);
    const generic_quarantine =
        try makeMetalAsyncDispatchQuarantineV1(
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
            .terminal_command_error,
            .terminal_status_observed,
            lifecycle.command_buffer_status_error,
            1,
            .command_buffer,
            generic_code,
        );
    const generic_result =
        try makeMetalAsyncDispatchTerminalFailureV1(
            generic_quarantine,
            fixture.pin,
            fixture.draft,
            generic_native.submission,
            generic_native.completion,
        );
    try validateMetalAsyncDispatchTerminalFailureForDispatchV1(
        generic_result.failure,
        fixture.pin,
        fixture.draft,
        generic_native.submission,
        generic_native.completion,
        generic_result.terminal,
    );
    try std.testing.expect(
        !lossDispatchNativeDeviceRemovedSourceValidV1(
            generic_quarantine,
            generic_native.completion,
            generic_result.failure,
        ),
    );
}

test "Metal async exact command error authorizes only terminal failure settlement" {
    const fixture = try makeTestAsyncEvidenceFixture(31);
    const native_error =
        makeTestNativeAsyncErrorFixture(fixture.ticket);
    try metal.validateMetalAsyncSubmission(
        native_error.submission,
    );
    try metal.validateMetalAsyncCompletion(
        native_error.completion,
    );
    const error_code_bits: u64 =
        @bitCast(native_error.completion.error_code);
    const quarantine =
        try makeMetalAsyncDispatchQuarantineV1(
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
            .terminal_command_error,
            .terminal_status_observed,
            async_native_command_status_error,
            1,
            .command_buffer,
            error_code_bits,
        );

    const first =
        try makeMetalAsyncDispatchTerminalFailureV1(
            quarantine,
            fixture.pin,
            fixture.draft,
            native_error.submission,
            native_error.completion,
        );
    const replay =
        try makeMetalAsyncDispatchTerminalFailureV1(
            quarantine,
            fixture.pin,
            fixture.draft,
            native_error.submission,
            native_error.completion,
        );
    try std.testing.expectEqualDeep(first, replay);
    try validateMetalAsyncDispatchTerminalFailureV1(
        first.failure,
        first.terminal,
    );
    try validateMetalAsyncDispatchTerminalFailureForDispatchV1(
        first.failure,
        fixture.pin,
        fixture.draft,
        native_error.submission,
        native_error.completion,
        first.terminal,
    );
    try std.testing.expect(
        first.terminal.outcome == .terminal_failure,
    );
    try std.testing.expect(device.digestEqual(
        first.terminal.submission_sha256,
        fixture.ticket.submission_sha256,
    ));
    try std.testing.expect(
        !digestIsZero(
            first.terminal.backend_completion_sha256,
        ),
    );
    try std.testing.expect(
        digestIsZero(first.terminal.output_sha256),
    );
    try std.testing.expect(
        !@hasField(
            MetalAsyncDispatchTerminalFailureV1,
            "output_sha256",
        ),
    );
    try std.testing.expectEqualDeep(
        quarantine,
        first.failure.quarantine,
    );

    var unsealed = first.failure;
    unsealed.current_allocated_after += 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTerminalFailureV1(
            unsealed,
            first.terminal,
        ),
    );

    // Rehashing cannot make an error code disagreeing with the embedded
    // quarantine into a valid portable terminal-failure projection.
    var substituted_error_code = first.failure;
    substituted_error_code.error_code_bits += 1;
    const substituted_error_terminal =
        try resealTestAsyncTerminalFailure(
            &substituted_error_code,
            fixture.pin,
        );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTerminalFailureV1(
            substituted_error_code,
            substituted_error_terminal,
        ),
    );

    // A coherently resealed portable projection is structurally valid, but
    // cannot replace the exact native snapshot retained by this adapter.
    var substituted = first.failure;
    substituted.current_allocated_after += 1;
    const substituted_terminal =
        try resealTestAsyncTerminalFailure(
            &substituted,
            fixture.pin,
        );
    try validateMetalAsyncDispatchTerminalFailureV1(
        substituted,
        substituted_terminal,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalAsyncDispatchTerminalFailureForDispatchV1(
            substituted,
            fixture.pin,
            fixture.draft,
            native_error.submission,
            native_error.completion,
            substituted_terminal,
        ),
    );

    var foreign_completion = native_error.completion;
    foreign_completion.token.generation += 1;
    try metal.validateMetalAsyncCompletion(
        foreign_completion,
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        makeMetalAsyncDispatchTerminalFailureV1(
            quarantine,
            fixture.pin,
            fixture.draft,
            native_error.submission,
            foreign_completion,
        ),
    );

    var foreign_submission = native_error.submission;
    var foreign_bound_completion = native_error.completion;
    const foreign_binding =
        testDispatchDigest("foreign native async binding");
    foreign_submission.submission_binding = foreign_binding;
    foreign_bound_completion.submission_binding =
        foreign_binding;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        makeMetalAsyncDispatchTerminalFailureV1(
            quarantine,
            fixture.pin,
            fixture.draft,
            foreign_submission,
            foreign_bound_completion,
        ),
    );

    const unknown =
        try makeMetalAsyncDispatchQuarantineV1(
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
            .completion_unknown,
            .submitted,
            async_native_command_status_error,
            1,
            .native_bridge,
            error_code_bits,
        );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        makeMetalAsyncDispatchTerminalFailureV1(
            unknown,
            fixture.pin,
            fixture.draft,
            native_error.submission,
            native_error.completion,
        ),
    );
}

test "Metal adapter keeps exact terminal failure quarantined until private settlement" {
    if (!metal_enabled) return error.SkipZigTest;

    const fixture = try makeTestAsyncEvidenceFixture(32);
    const native_error =
        makeTestNativeAsyncErrorFixture(fixture.ticket);
    const error_code_bits: u64 =
        @bitCast(native_error.completion.error_code);
    const quarantine =
        try makeMetalAsyncDispatchQuarantineV1(
            fixture.ticket,
            fixture.device_sha256,
            fixture.placement_sha256,
            .terminal_command_error,
            .terminal_status_observed,
            async_native_command_status_error,
            1,
            .command_buffer,
            error_code_bits,
        );
    const lease = std.mem.zeroes(
        lease_tree.LeaseTreeDeviceAllocationLeaseV1,
    );
    var slots = [_]MetalAllocationSlotV1{.{}};
    var adapter: MetalAllocationAdapterV1 = .{
        .backend = @ptrFromInt(0x1000),
        .authority = .{},
        .slots = &slots,
        .limits = .{},
        .device_sha256 = fixture.device_sha256,
        .placement_sha256 = fixture.placement_sha256,
        .adapter_nonce = 1,
        .adapter_identity = .{},
        .dispatch_authority_sha256 = fixture.request.dispatch_authority_sha256,
        .queue_authority_sha256 = fixture.request.queue_authority_sha256,
        .prepared_matvec_request = fixture.request,
        .reserved_dispatch_intent = fixture.intent,
        .bound_dispatch_pin = fixture.pin,
        .dispatch_unresolved = true,
        .async_dispatch = .{
            .lease = lease,
            .pin = fixture.pin,
            .request = fixture.request,
            .ticket = fixture.ticket,
            .draft = fixture.draft,
            .selected = .{
                .tokens = [_]metal.MetalBufferToken{.{}} ** 4,
                .evidence = fixture.draft.roles,
            },
            .native_submission = native_error.submission,
        },
    };

    var changed_native_error = native_error.completion;
    changed_native_error.current_allocated_after += 1;
    try metal.validateMetalAsyncCompletion(
        changed_native_error,
    );
    adapter.async_dispatch.?.native_completion =
        changed_native_error;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        adapter.installTerminalCommandErrorQuarantineUnlocked(
            fixture.ticket,
            native_error.completion,
        ),
    );
    try std.testing.expect(adapter.async_quarantine == null);
    adapter.async_dispatch.?.native_completion = null;

    const installed =
        try adapter.installTerminalCommandErrorQuarantineUnlocked(
            fixture.ticket,
            native_error.completion,
        );
    try std.testing.expectEqualDeep(quarantine, installed);
    try std.testing.expectEqualDeep(
        native_error.completion,
        adapter.async_dispatch.?.native_completion.?,
    );
    try std.testing.expectEqualDeep(
        installed,
        try adapter.installTerminalCommandErrorQuarantineUnlocked(
            fixture.ticket,
            native_error.completion,
        ),
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        adapter.installTerminalCommandErrorQuarantineUnlocked(
            fixture.ticket,
            changed_native_error,
        ),
    );
    try std.testing.expectEqualDeep(
        native_error.completion,
        adapter.async_dispatch.?.native_completion.?,
    );

    const first =
        try adapter.reconcileTerminalCommandFailureObserved(
            lease,
            fixture.pin,
            fixture.ticket,
        );
    const replay =
        try adapter.reconcileTerminalCommandFailureObserved(
            lease,
            fixture.pin,
            fixture.ticket,
        );
    try std.testing.expectEqualDeep(first, replay);
    try std.testing.expectEqualDeep(
        quarantine,
        adapter.currentAsyncDispatchQuarantine().?,
    );
    try std.testing.expect(adapter.dispatch_unresolved);
    try std.testing.expect(
        adapter.async_dispatch.?.native_completion != null,
    );
    try std.testing.expect(
        adapter.authorized_terminal != null,
    );

    const dispatch_interface = adapter.dispatchInterface();
    try dispatch_interface.validate_terminal_fn(
        dispatch_interface.context,
        first.terminal,
    );
    try std.testing.expect(
        adapter.terminal_validation_observed,
    );
    try std.testing.expectEqualDeep(
        quarantine,
        adapter.currentAsyncDispatchQuarantine().?,
    );

    // Rejected settlement evidence must not reach native finalization or
    // clear any retained ownership.
    try std.testing.expectError(
        lease_tree.DispatchCallbackError
            .InvalidSettlementEvidence,
        dispatch_interface.confirm_settlement_fn(
            dispatch_interface.context,
            fixture.pin,
            first.terminal,
            std.mem.zeroes(
                lease_tree.LeaseTreeDispatchCompletionV1,
            ),
            std.mem.zeroes(resource.LeasePinPermitV1),
            std.mem.zeroes(resource.LeasePinCompletionV1),
        ),
    );
    try std.testing.expect(
        adapter.terminal_validation_observed,
    );
    try std.testing.expect(adapter.dispatch_unresolved);
    try std.testing.expect(
        adapter.async_dispatch.?.native_completion != null,
    );
    try std.testing.expectEqualDeep(
        quarantine,
        adapter.currentAsyncDispatchQuarantine().?,
    );

    var output = [_]f32{0} ** 37;
    const observed =
        try adapter.pollMatvecInt4AsyncObserved(
            lease,
            fixture.pin,
            fixture.ticket,
            &output,
        );
    switch (observed) {
        .quarantined => |value| try std.testing.expectEqualDeep(
            quarantine,
            value,
        ),
        .pending, .completed => return error.TestUnexpectedResult,
    }
}

test "Metal dispatch observation seals exact geometry roles telemetry and data" {
    const observation = try makeTestDispatchObservation();
    try validateMetalLeaseTreeDispatchObservationV1(
        observation,
    );
    var packed_weights = [_]u8{0x5a} ** 93;
    var scales = [_]f32{ 0.25, -0.5, 1.0 };
    var input = [_]f32{0.0} ** 37;
    var output = [_]f32{ 1.0, -2.0, 3.0, -4.0, 5.0 };
    packed_weights[17] = 0xa5;
    input[11] = -0.0;
    var payload_observation = observation;
    payload_observation.packed_weights_input_sha256 =
        matvecPackedWeightsInputRootV1(&packed_weights);
    payload_observation.scales_input_sha256 =
        matvecScalesInputRootV1(&scales);
    payload_observation.vector_input_sha256 =
        matvecVectorInputRootV1(&input);
    payload_observation.output_sha256 =
        matvecOutputRootV1(&output);
    resealTestDispatchObservation(&payload_observation);
    try validateMetalLeaseTreeDispatchPayloadV1(
        payload_observation,
        &packed_weights,
        &scales,
        &input,
        &output,
    );
    output[2] = 9.0;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchPayloadV1(
            payload_observation,
            &packed_weights,
            &scales,
            &input,
            &output,
        ),
    );

    var geometry_drift = observation;
    geometry_drift.geometry.input_bytes += 4;
    resealTestDispatchObservation(&geometry_drift);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            geometry_drift,
        ),
    );

    var duplicate_role = observation;
    duplicate_role.roles.bindings.output_sha256 =
        duplicate_role.roles.bindings.input_sha256;
    resealTestDispatchObservation(&duplicate_role);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            duplicate_role,
        ),
    );

    var byte_total_drift = observation;
    byte_total_drift.materialized_bytes += 1;
    resealTestDispatchObservation(&byte_total_drift);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            byte_total_drift,
        ),
    );

    var telemetry_drift = observation;
    telemetry_drift.telemetry.gpu_duration_nanoseconds += 1;
    resealTestDispatchObservation(&telemetry_drift);
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(
            telemetry_drift,
        ),
    );

    var input_drift = observation;
    input_drift.vector_input_sha256 =
        testDispatchDigest("different vector input");
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalLeaseTreeDispatchObservationV1(input_drift),
    );
}

test "Metal pre-submit attempts classify only deterministic validation failures" {
    const bindings: MetalMatvecAllocationBindingsV1 = .{
        .packed_weights_sha256 = testDispatchDigest("pre-submit packed binding"),
        .scales_sha256 = testDispatchDigest("pre-submit scales binding"),
        .input_sha256 = testDispatchDigest("pre-submit input binding"),
        .output_sha256 = testDispatchDigest("pre-submit output binding"),
    };
    const valid = try makeMetalMatvecPreSubmitAttemptV1(
        bindings,
        1_184,
        296,
        64,
        37,
        8,
        64,
        37,
    );
    try std.testing.expect(
        try classifyStaticPreSubmitRejectionV1(valid) == null,
    );

    const invalid_geometry =
        try makeMetalMatvecPreSubmitAttemptV1(
            bindings,
            1_184,
            296,
            64,
            37,
            0,
            64,
            37,
        );
    try std.testing.expectEqual(
        MetalMatvecPreSubmitRejectionReasonV1.invalid_geometry,
        (try classifyStaticPreSubmitRejectionV1(
            invalid_geometry,
        )).?,
    );

    const invalid_lengths =
        try makeMetalMatvecPreSubmitAttemptV1(
            bindings,
            1_185,
            296,
            64,
            37,
            8,
            64,
            37,
        );
    try std.testing.expectEqual(
        MetalMatvecPreSubmitRejectionReasonV1.invalid_host_lengths,
        (try classifyStaticPreSubmitRejectionV1(
            invalid_lengths,
        )).?,
    );

    var duplicate_bindings = bindings;
    duplicate_bindings.output_sha256 =
        duplicate_bindings.input_sha256;
    const invalid_roles =
        try makeMetalMatvecPreSubmitAttemptV1(
            duplicate_bindings,
            1_184,
            296,
            64,
            37,
            8,
            64,
            37,
        );
    try std.testing.expectEqual(
        MetalMatvecPreSubmitRejectionReasonV1.invalid_role_bindings,
        (try classifyStaticPreSubmitRejectionV1(
            invalid_roles,
        )).?,
    );

    var tampered = invalid_lengths;
    tampered.output_count += 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalMatvecPreSubmitAttemptV1(tampered),
    );
}

test "Metal matvec dispatch requests bind generation authorities and attempt" {
    const dispatch_authority =
        testDispatchDigest("request dispatch authority");
    const queue_authority =
        testDispatchDigest("request queue authority");
    const attempt = try makeMetalMatvecPreSubmitAttemptV1(
        .{
            .packed_weights_sha256 = testDispatchDigest("request packed binding"),
            .scales_sha256 = testDispatchDigest("request scales binding"),
            .input_sha256 = testDispatchDigest("request input binding"),
            .output_sha256 = testDispatchDigest("request output binding"),
        },
        1_184,
        296,
        64,
        37,
        8,
        64,
        37,
    );
    const first = try makeMetalMatvecDispatchRequestV1(
        1,
        dispatch_authority,
        queue_authority,
        attempt,
    );
    const second = try makeMetalMatvecDispatchRequestV1(
        2,
        dispatch_authority,
        queue_authority,
        attempt,
    );
    try validateMetalMatvecDispatchRequestV1(first);
    try validateMetalMatvecDispatchRequestV1(second);
    try std.testing.expect(!device.digestEqual(
        first.request_sha256,
        second.request_sha256,
    ));

    var tampered = first;
    tampered.request_generation += 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalMatvecDispatchRequestV1(tampered),
    );
    tampered = first;
    tampered.attempt.output_count += 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalMatvecDispatchRequestV1(tampered),
    );
    tampered = first;
    tampered.request_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        validateMetalMatvecDispatchRequestV1(tampered),
    );
    try std.testing.expectError(
        Error.InvalidDispatchEvidence,
        makeMetalMatvecDispatchRequestV1(
            1,
            dispatch_authority,
            dispatch_authority,
            attempt,
        ),
    );
}

test "Metal matvec request and rejection roots match cross-language golden" {
    const attempt = try makeMetalMatvecPreSubmitAttemptV1(
        .{
            .packed_weights_sha256 = testDispatchDigest("request packed binding"),
            .scales_sha256 = testDispatchDigest("request scales binding"),
            .input_sha256 = testDispatchDigest("request input binding"),
            .output_sha256 = testDispatchDigest("request output binding"),
        },
        1_184,
        296,
        64,
        37,
        8,
        64,
        37,
    );
    var expected_attempt: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_attempt,
        "b79371a76c12ca08d58980f5913fe33dda2aaca41e801d8a473b941a5b04e2cb",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_attempt,
        &attempt.attempt_sha256,
    );

    const request = try makeMetalMatvecDispatchRequestV1(
        1,
        testDispatchDigest("request dispatch authority"),
        testDispatchDigest("request queue authority"),
        attempt,
    );
    var expected_request: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_request,
        "f89175ddd5b07db24854c8432a650449a023c9445cedbc86a75459305b2e4486",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_request,
        &request.request_sha256,
    );

    var pin_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &pin_sha256,
        "d8a9faa9bced09e52d1867afee4e2f2698d38d9dce277bd11aab403a9289f93c",
    );
    var backend_object_set_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &backend_object_set_sha256,
        "6c658fa780e2e01102b38508bd2aa4b6f9218450eb6c9f5317a0a58a9ffe7418",
    );
    var terminal_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &terminal_sha256,
        "a646ea614bd10b279e1f921440517633b200e959536f7d685f97310f6f099a6d",
    );
    var rejection: MetalMatvecPreSubmitRejectionV1 = .{
        .reason = .invalid_role_mapping,
        .dispatch_generation = 1,
        .allocation_count = 4,
        .materialized_bytes = 8_192,
        .pin_sha256 = pin_sha256,
        .backend_object_set_sha256 = backend_object_set_sha256,
        .request = request,
        .terminal_sha256 = terminal_sha256,
    };
    rejection.rejection_sha256 =
        metalMatvecPreSubmitRejectionRootV1(rejection);
    var expected_rejection: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_rejection,
        "64b4f359d932f74f3dc6e6cd3819b7e7d6d6fbc784f4a6ddef128268372b0f5c",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_rejection,
        &rejection.rejection_sha256,
    );
    try validateMetalMatvecPreSubmitRejectionV1(
        rejection,
    );
}

test "Metal async ticket and quarantine roots match cross-language goldens" {
    const attempt = try makeMetalMatvecPreSubmitAttemptV1(
        .{
            .packed_weights_sha256 = testDispatchDigest("request packed binding"),
            .scales_sha256 = testDispatchDigest("request scales binding"),
            .input_sha256 = testDispatchDigest("request input binding"),
            .output_sha256 = testDispatchDigest("request output binding"),
        },
        1_184,
        296,
        64,
        37,
        8,
        64,
        37,
    );
    const request = try makeMetalMatvecDispatchRequestV1(
        1,
        testDispatchDigest("request dispatch authority"),
        testDispatchDigest("request queue authority"),
        attempt,
    );
    var pin_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &pin_sha256,
        "d8a9faa9bced09e52d1867afee4e2f2698d38d9dce277bd11aab403a9289f93c",
    );
    var ticket: MetalAsyncDispatchTicketV1 = .{
        .ticket_generation = 21,
        .dispatch_generation = 1,
        .dispatch_authority_sha256 = request.dispatch_authority_sha256,
        .queue_authority_sha256 = request.queue_authority_sha256,
        .request = request,
        .pin_sha256 = pin_sha256,
        .submission_sha256 = testDispatchDigest("async dispatch submission"),
    };
    ticket.ticket_sha256 = metalAsyncDispatchTicketRootV1(ticket);
    try validateMetalAsyncDispatchTicketV1(ticket);

    var expected_ticket_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_ticket_sha256,
        "50eafb3b20fd1ce75b3b8be385a413001e3d297a929bfda3ba115b99621eabc7",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_ticket_sha256,
        &ticket.ticket_sha256,
    );

    const Case = struct {
        reason: MetalAsyncDispatchQuarantineReasonV1,
        disposition: MetalAsyncNativeDispositionV1,
        status: u64,
        completion_observed: u64,
        error_domain: MetalAsyncErrorDomainKindV1,
        error_code_bits: u64,
        expected_sha256_hex: []const u8,
    };
    const cases = [_]Case{
        .{
            .reason = .submission_ambiguous,
            .disposition = .commit_started,
            .status = async_native_command_status_unobserved,
            .completion_observed = 0,
            .error_domain = .native_bridge,
            .error_code_bits = async_submission_ambiguous_adapter_code,
            .expected_sha256_hex = "20612cc2fc1f4111353d2abbe2a565be8c03e3c33ec7dc6b5d368e4857501aa7",
        },
        .{
            .reason = .completion_unknown,
            .disposition = .submitted,
            .status = 77,
            .completion_observed = 1,
            .error_domain = .native_bridge,
            .error_code_bits = 0x777,
            .expected_sha256_hex = "bc08b31107c056f768da3eb8f5807df2faf230ae907175ead2de62fc685626d9",
        },
        .{
            .reason = .invalid_completion,
            .disposition = .terminal_status_observed,
            .status = async_native_command_status_completed,
            .completion_observed = 1,
            .error_domain = .completion_validation,
            .error_code_bits = 0x202,
            .expected_sha256_hex = "ee46ee2bc57ad0bba2542f33bff363a918eaa6214da5291432bf5ff3d8458cf9",
        },
        .{
            .reason = .terminal_command_error,
            .disposition = .terminal_status_observed,
            .status = async_native_command_status_error,
            .completion_observed = 1,
            .error_domain = .command_buffer,
            .error_code_bits = 0x303,
            .expected_sha256_hex = "ec05a4ea41d93a96ae763f85c217344de3abeab261a4e7dbd169809a64d72ae9",
        },
    };
    for (cases) |case| {
        const quarantine = try makeMetalAsyncDispatchQuarantineV1(
            ticket,
            testDispatchDigest("async Metal device"),
            testDispatchDigest("async Metal placement"),
            case.reason,
            case.disposition,
            case.status,
            case.completion_observed,
            case.error_domain,
            case.error_code_bits,
        );
        var expected_quarantine_sha256: Digest = undefined;
        _ = try std.fmt.hexToBytes(
            &expected_quarantine_sha256,
            case.expected_sha256_hex,
        );
        try std.testing.expectEqualSlices(
            u8,
            &expected_quarantine_sha256,
            &quarantine.quarantine_sha256,
        );
    }

    const terminal_error_bits: u64 =
        @bitCast(@as(i64, -73));
    const terminal_quarantine =
        try makeMetalAsyncDispatchQuarantineV1(
            ticket,
            testDispatchDigest("async Metal device"),
            testDispatchDigest("async Metal placement"),
            .terminal_command_error,
            .terminal_status_observed,
            async_native_command_status_error,
            1,
            .command_buffer,
            terminal_error_bits,
        );
    var backend_object_set_sha256: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &backend_object_set_sha256,
        "6c658fa780e2e01102b38508bd2aa4b6f9218450eb6c9f5317a0a58a9ffe7418",
    );
    var failure: MetalAsyncDispatchTerminalFailureV1 = .{
        .quarantine = terminal_quarantine,
        .dispatch_generation = 1,
        .allocation_count = 4,
        .materialized_bytes = 8_192,
        .pin_sha256 = pin_sha256,
        .backend_object_set_sha256 = backend_object_set_sha256,
        .current_allocated_before = 4_096,
        .current_allocated_after = 4_352,
        .gpu_start_time_bits = 0x4029_0000_0000_0000,
        .gpu_end_time_bits = 0x4029_8000_0000_0000,
        .native_command_status = async_native_command_status_error,
        .error_domain_kind = .command_buffer,
        .error_code_bits = terminal_error_bits,
        .submission_sha256 = ticket.submission_sha256,
    };
    failure.native_terminal_sha256 =
        metalAsyncDispatchNativeTerminalRootV1(failure);
    failure.backend_completion_sha256 =
        metalAsyncDispatchFailureBackendCompletionRootV1(
            failure,
        );
    var terminal: lease_tree.DispatchTerminalEvidenceV1 = .{
        .outcome = .terminal_failure,
        .dispatch_generation = 1,
        .dispatch_authority_sha256 = request.dispatch_authority_sha256,
        .queue_authority_sha256 = request.queue_authority_sha256,
        .pin_sha256 = pin_sha256,
        .dispatch_request_sha256 = request.request_sha256,
        .submission_sha256 = ticket.submission_sha256,
        .backend_completion_sha256 = failure.backend_completion_sha256,
    };
    terminal.terminal_sha256 =
        lease_tree.dispatchTerminalRootV1(terminal);
    failure.terminal_sha256 = terminal.terminal_sha256;
    failure.failure_sha256 =
        metalAsyncDispatchTerminalFailureRootV1(failure);
    try validateMetalAsyncDispatchTerminalFailureV1(
        failure,
        terminal,
    );

    const Golden = struct {
        actual: Digest,
        expected_hex: []const u8,
    };
    const goldens = [_]Golden{
        .{
            .actual = terminal_quarantine.quarantine_sha256,
            .expected_hex = "2b035ebd584186a2e6e7c57234159455fbcd2ad35f60116fb9352d7968cfb2e5",
        },
        .{
            .actual = failure.native_terminal_sha256,
            .expected_hex = "ecc3170904263bd9d60cc5ccd7f1e091e1a82ab7e3ded6b6e557185ffffb13ba",
        },
        .{
            .actual = failure.backend_completion_sha256,
            .expected_hex = "6f14c76497c1641ede6092984b638e7799ea1dc65a290c40a087e80de402cdee",
        },
        .{
            .actual = terminal.terminal_sha256,
            .expected_hex = "e2f46a7585a8633ed04d47b4f4d5f14f2d0c43bbc8374d64f8bfb89ffbd258b2",
        },
        .{
            .actual = failure.failure_sha256,
            .expected_hex = "af406c37a46e4557cc281d4bf98927afcd13b4ab12fbdd69563cbfad90eb015e",
        },
    };
    for (goldens) |golden| {
        var expected: Digest = undefined;
        _ = try std.fmt.hexToBytes(
            &expected,
            golden.expected_hex,
        );
        try std.testing.expectEqualSlices(
            u8,
            &expected,
            &golden.actual,
        );
    }
}

test "Metal prepared matvec request is idempotent and generation fenced" {
    var slots = [_]MetalAllocationSlotV1{.{}};
    var adapter: MetalAllocationAdapterV1 = .{
        .backend = @ptrFromInt(0x1000),
        .authority = .{},
        .slots = &slots,
        .limits = .{},
        .device_sha256 = allocation.zero_digest,
        .placement_sha256 = allocation.zero_digest,
        .adapter_nonce = 1,
        .adapter_identity = .{},
        .dispatch_authority_sha256 = testDispatchDigest("prepared dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("prepared queue authority"),
    };
    const attempt = try makeMetalMatvecPreSubmitAttemptV1(
        .{},
        1,
        2,
        3,
        4,
        8,
        16,
        32,
    );
    const first =
        try adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        );
    const replay =
        try adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        );
    try std.testing.expectEqualDeep(first, replay);
    try std.testing.expectEqual(@as(u64, 1), first.request_generation);
    try std.testing.expectEqual(
        @as(u64, 2),
        adapter.next_matvec_request_generation,
    );

    const different = try makeMetalMatvecPreSubmitAttemptV1(
        .{},
        1,
        2,
        3,
        5,
        8,
        16,
        32,
    );
    try std.testing.expectError(
        Error.DispatchBusy,
        adapter.prepareMatvecDispatchRequestUnlocked(
            different,
        ),
    );
    try std.testing.expectEqualDeep(
        first,
        adapter.prepared_matvec_request.?,
    );

    try adapter.cancelPreparedMatvecDispatchRequestUnlocked(
        first,
    );
    try adapter.cancelPreparedMatvecDispatchRequestUnlocked(
        first,
    );
    try std.testing.expect(
        adapter.prepared_matvec_request == null,
    );
    const second =
        try adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        );
    try std.testing.expectEqual(@as(u64, 2), second.request_generation);
    try std.testing.expect(!device.digestEqual(
        first.request_sha256,
        second.request_sha256,
    ));
    try std.testing.expectError(
        Error.DispatchBusy,
        adapter.cancelPreparedMatvecDispatchRequestUnlocked(
            first,
        ),
    );

    adapter.dispatch_unresolved = true;
    try std.testing.expectError(
        Error.DispatchBusy,
        adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        ),
    );
    try std.testing.expectError(
        Error.DispatchBusy,
        adapter.cancelPreparedMatvecDispatchRequestUnlocked(
            second,
        ),
    );
    adapter.dispatch_unresolved = false;
    try adapter.cancelPreparedMatvecDispatchRequestUnlocked(
        second,
    );
    adapter.dispatch_unresolved = true;
    try std.testing.expectError(
        Error.DispatchBusy,
        adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        ),
    );
    adapter.dispatch_unresolved = false;
    adapter.next_matvec_request_generation =
        std.math.maxInt(u64);
    try std.testing.expectError(
        Error.GenerationExhausted,
        adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        ),
    );
}

test "Metal dispatch intent reservation and abort are exact and replay safe" {
    const authority_sha256 =
        testDispatchDigest("intent allocation authority");
    const admission_sha256 =
        testDispatchDigest("intent admission");
    var slots = [_]MetalAllocationSlotV1{.{}};
    var adapter: MetalAllocationAdapterV1 = .{
        .backend = @ptrFromInt(0x1000),
        .authority = .{
            .authority_sha256 = authority_sha256,
        },
        .slots = &slots,
        .limits = .{},
        .device_sha256 = allocation.zero_digest,
        .placement_sha256 = allocation.zero_digest,
        .adapter_nonce = 1,
        .adapter_identity = .{},
        .dispatch_authority_sha256 = testDispatchDigest("intent dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("intent queue authority"),
        .active_admission_sha256 = admission_sha256,
        .used_resource_bytes = 8_192,
    };
    const attempt = try makeMetalMatvecPreSubmitAttemptV1(
        .{},
        1,
        2,
        3,
        4,
        8,
        16,
        32,
    );
    const first =
        try adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        );
    var intent: lease_tree.DispatchPinIntentV1 = .{
        .coordinator_epoch = 7,
        .allocation_generation = 11,
        .dispatch_generation = 13,
        .allocation_count = 4,
        .pinned_device_bytes = 8_192,
        .authority_sha256 = authority_sha256,
        .dispatch_authority_sha256 = adapter.dispatch_authority_sha256,
        .queue_authority_sha256 = adapter.queue_authority_sha256,
        .request_sha256 = testDispatchDigest("intent allocation request"),
        .admission_sha256 = admission_sha256,
        .lease_sha256 = testDispatchDigest("intent lease"),
        .parent_receipt_sha256 = testDispatchDigest("intent parent"),
        .allocation_leaf_set_sha256 = testDispatchDigest("intent leaves"),
        .backend_object_set_sha256 = testDispatchDigest("intent objects"),
        .scope_sha256 = testDispatchDigest("intent scope"),
        .dispatch_request_sha256 = first.request_sha256,
        .publication_binding_sha256 = testDispatchDigest("intent publication"),
    };
    intent.intent_sha256 =
        lease_tree.dispatchPinIntentRootV1(intent);
    const dispatch = adapter.dispatchInterface();
    try dispatch.reserve_dispatch_intent_fn(
        dispatch.context,
        intent,
    );
    try dispatch.reserve_dispatch_intent_fn(
        dispatch.context,
        intent,
    );
    try std.testing.expectEqualDeep(
        intent,
        adapter.reserved_dispatch_intent.?,
    );
    try std.testing.expectError(
        Error.DispatchBusy,
        adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        ),
    );
    try std.testing.expectError(
        Error.DispatchBusy,
        adapter.cancelPreparedMatvecDispatchRequestUnlocked(
            first,
        ),
    );

    var foreign = intent;
    foreign.dispatch_generation += 1;
    foreign.intent_sha256 =
        lease_tree.dispatchPinIntentRootV1(foreign);
    try std.testing.expectError(
        lease_tree.DispatchCallbackError
            .InvalidDispatchIntent,
        dispatch.reserve_dispatch_intent_fn(
            dispatch.context,
            foreign,
        ),
    );
    try std.testing.expectError(
        lease_tree.DispatchCallbackError
            .InvalidDispatchIntent,
        dispatch.abort_dispatch_intent_fn(
            dispatch.context,
            foreign,
        ),
    );
    try std.testing.expectEqualDeep(
        intent,
        adapter.reserved_dispatch_intent.?,
    );

    try dispatch.abort_dispatch_intent_fn(
        dispatch.context,
        intent,
    );
    try dispatch.abort_dispatch_intent_fn(
        dispatch.context,
        intent,
    );
    try std.testing.expect(
        adapter.reserved_dispatch_intent == null,
    );
    try adapter.cancelPreparedMatvecDispatchRequestUnlocked(
        first,
    );
    const second =
        try adapter.prepareMatvecDispatchRequestUnlocked(
            attempt,
        );
    try std.testing.expect(
        second.request_generation >
            first.request_generation,
    );
    var second_intent = intent;
    second_intent.dispatch_generation += 2;
    second_intent.dispatch_request_sha256 =
        second.request_sha256;
    second_intent.intent_sha256 =
        lease_tree.dispatchPinIntentRootV1(
            second_intent,
        );
    try dispatch.reserve_dispatch_intent_fn(
        dispatch.context,
        second_intent,
    );
    try dispatch.abort_dispatch_intent_fn(
        dispatch.context,
        second_intent,
    );
    try adapter.cancelPreparedMatvecDispatchRequestUnlocked(
        second,
    );
}

test "disabled Metal adapter rejects every native entry point" {
    if (comptime metal_enabled)
        return error.SkipZigTest;

    const backend: *metal.MetalBackend = @ptrFromInt(0x1000);
    var slots = [_]MetalAllocationSlotV1{.{}};
    var adapter: MetalAllocationAdapterV1 = .{
        .backend = backend,
        .authority = .{},
        .slots = &slots,
        .limits = .{},
        .device_sha256 = allocation.zero_digest,
        .placement_sha256 = allocation.zero_digest,
        .adapter_nonce = 1,
        .adapter_identity = .{},
        .dispatch_authority_sha256 = testDispatchDigest("disabled dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("disabled queue authority"),
    };

    try std.testing.expectError(
        metal.MetalError.Unavailable,
        makeAllocationInventoryEntryV1(backend, 1, 1, 1),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        MetalAllocationAdapterV1.init(
            backend,
            .{},
            1,
            1,
            &slots,
        ),
    );
    const disabled_coordinator: *lease_tree.CoordinatorV1 = @ptrFromInt(0x2000);
    const disabled_dispatch = adapter.dispatchInterface();
    const no_inventory =
        [_]device.DeviceInventoryEntryV1{};
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.lossDispatchReconciliationAdapterChallengeV1(
            disabled_coordinator,
            disabled_dispatch,
            .{},
            .{},
            .{},
            .{},
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.armLossDispatchReconciliationV1(
            disabled_coordinator,
            disabled_dispatch,
            .{},
            .{},
            .{},
            .{},
            .{},
            .{},
            .{},
            &no_inventory,
            .{},
            .{},
            .{},
            .{},
            .{},
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.armSyntheticLossDispatchReconciliationForTestV1(
            disabled_coordinator,
            disabled_dispatch,
            .{},
            .{},
            .{},
            .{},
            .{},
            .{},
            .{},
            &no_inventory,
            .{},
            .{},
            .{},
            .{},
            .{},
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.completeLossDispatchReconciliationV1(
            .{},
            .{},
            .{},
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.currentLossDispatchReconciliationReceiptV1(
            .{},
            .{},
            .{},
        ),
    );

    const packed_input = [_]u8{};
    const scales = [_]f32{};
    const input = [_]f32{};
    var output = [_]f32{};
    const disabled_attempt =
        try makeMetalMatvecPreSubmitAttemptV1(
            .{},
            0,
            0,
            0,
            0,
            1,
            1,
            1,
        );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.prepareMatvecDispatchRequestV1(
            disabled_attempt,
        ),
    );
    const disabled_request =
        try makeMetalMatvecDispatchRequestV1(
            1,
            adapter.dispatch_authority_sha256,
            adapter.queue_authority_sha256,
            disabled_attempt,
        );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.cancelPreparedMatvecDispatchRequestV1(
            disabled_request,
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.cancelMatvecBeforeSubmitObserved(
            .{},
            .{},
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.dispatchMatvecInt4Observed(
            .{},
            .{},
            .{},
            &packed_input,
            &scales,
            &input,
            &output,
            1,
            1,
            1,
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.submitMatvecInt4AsyncObserved(
            .{},
            .{},
            .{},
            &packed_input,
            &scales,
            &input,
            &output,
            1,
            1,
            1,
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.pollMatvecInt4AsyncObserved(
            .{},
            .{},
            .{},
            &output,
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.waitMatvecInt4AsyncObserved(
            .{},
            .{},
            .{},
            &output,
        ),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.rejectMatvecInt4BeforeSubmitObserved(
            .{},
            .{},
            .{},
            &packed_input,
            &scales,
            &input,
            &output,
            1,
            1,
            1,
        ),
    );

    var observations = [_]MetalAllocationObservationV1{.{}};
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.copyLiveObservations(&observations),
    );
    try std.testing.expectError(
        metal.MetalError.Unavailable,
        adapter.validateDispatchSetUnlocked(
            .{},
            .{},
            .{},
            .{},
        ),
    );
}

test "Metal dispatch ownership blocks allocation and free before settlement" {
    var slots = [_]MetalAllocationSlotV1{.{}};
    var adapter: MetalAllocationAdapterV1 = .{
        .backend = @ptrFromInt(0x1000),
        .authority = .{},
        .slots = &slots,
        .limits = .{},
        .device_sha256 = allocation.zero_digest,
        .placement_sha256 = allocation.zero_digest,
        .adapter_nonce = 1,
        .adapter_identity = .{},
        .dispatch_authority_sha256 = testDispatchDigest("blocked dispatch authority"),
        .queue_authority_sha256 = testDispatchDigest("blocked queue authority"),
        .dispatch_unresolved = true,
    };
    const interface = adapter.interface();
    try std.testing.expectError(
        allocation.CallbackError.Unavailable,
        interface.allocate_fn(interface.context, .{}),
    );
    try std.testing.expectError(
        allocation.CallbackError.Unavailable,
        interface.free_fn(interface.context, .{}),
    );
    try std.testing.expectEqual(@as(u64, 0), adapter.allocate_calls);
    try std.testing.expectEqual(@as(u64, 0), adapter.free_calls);
}

test "Metal dispatch and queue authorities bind exact adapter identity" {
    const authority: allocation.AllocationAuthorityV1 = .{
        .authority_sha256 = testDispatchDigest("authority identity"),
        .backend_authority_sha256 = testDispatchDigest("backend authority identity"),
        .max_queue_slots = 1,
    };
    const limits: metal.MetalAllocationLimits = .{
        .abi_version = 1,
        .device_registry_id = 77,
        .max_buffer_length = 4_096,
        .resource_granularity = 1,
        .storage_mode = metal.shared_storage_mode,
        .cpu_cache_mode = metal.default_cpu_cache_mode,
    };
    const identity: metal.MetalAllocationAdapterIdentity = .{
        .abi_version = 1,
        .context_nonce = .{ 1, 2, 3, 4 },
        .adapter_instance = 9,
    };
    const first = dispatchAuthorityRootV1(
        authority,
        11,
        identity,
        limits,
    );
    const replay = dispatchAuthorityRootV1(
        authority,
        11,
        identity,
        limits,
    );
    const queue = queueAuthorityRootV1(
        first,
        identity,
        limits,
    );
    var changed_identity = identity;
    changed_identity.adapter_instance += 1;
    const foreign = dispatchAuthorityRootV1(
        authority,
        11,
        changed_identity,
        limits,
    );
    try std.testing.expectEqualSlices(u8, &first, &replay);
    try std.testing.expect(
        !device.digestEqual(first, foreign),
    );
    try std.testing.expect(
        !device.digestEqual(first, queue),
    );
}

test "Metal allocation observation binds logical and occupied byte meanings" {
    const selected = try device.sealInventoryEntryV1(.{
        .discovery_epoch = 1,
        .state = .present,
        .capability = try device.sealCapabilityV1(.{
            .backend_kind = .metal,
            .device_class = .accelerator,
            .operation_profile_bits = device.OperationProfileBitsV1.matvec_int4_f32_bounded,
            .operator_bits = device.OperatorBitsV1.matvec_int4_f32,
            .element_type_bits = device.ElementTypeBitsV1.packed_int4 |
                device.ElementTypeBitsV1.float32,
            .numerical_policy_bits = device.NumericalPolicyBitsV1.bounded_float32,
            .feature_bits = device.FeatureBitsV1.allocation |
                device.FeatureBitsV1.allocated_bytes_observation,
            .max_single_allocation_bytes = 4_096,
            .max_total_device_bytes = 8_192,
            .max_queue_slots = 1,
            .backend_sha256 = native.contract.digestV1("backend"),
            .device_sha256 = native.contract.digestV1("device"),
            .placement_sha256 = native.contract.digestV1("placement"),
        }),
    });
    const authority = try allocation.makeAuthorityV1(
        1,
        1,
        3,
        1,
        selected,
        native.contract.digestV1("authority"),
    );
    var observation: MetalAllocationObservationV1 = .{
        .authority_sha256 = authority.authority_sha256,
        .admission_sha256 = native.contract.digestV1("admission"),
        .allocation_call_sha256 = native.contract.digestV1("call"),
        .binding_sha256 = native.contract.digestV1("binding"),
        .backend_object_sha256 = allocation.zero_digest,
        .object_sha256 = native.contract.digestV1("object"),
        .adapter_slot_index = 2,
        .backend_object_generation = 7,
        .ordinal = 1,
        .device_registry_id = 9,
        .requested_bytes = 1_000,
        .charged_resource_bytes = 1_000,
        .buffer_length_bytes = 1_000,
        .resource_allocated_size_bytes = 1_024,
        .storage_mode = metal.shared_storage_mode,
        .cpu_cache_mode = metal.default_cpu_cache_mode,
    };
    observation.backend_object_sha256 = objectIdentityV1(
        authority,
        observation.device_registry_id,
        observation.adapter_slot_index,
        observation.backend_object_generation,
        observation.allocation_call_sha256,
    );
    observation.object_sha256 =
        allocation.backendObjectRootV1(.{
            .allocation_call_sha256 = observation.allocation_call_sha256,
            .binding_sha256 = observation.binding_sha256,
            .backend_object_sha256 = observation.backend_object_sha256,
            .backend_object_generation = observation.backend_object_generation,
            .allocated_bytes = observation.charged_resource_bytes,
        });
    observation.observation_sha256 =
        observationRootV1(observation);
    try validateObservationV1(observation, authority, 9);
    const expected_observation_sha256 = [_]u8{
        0xd8, 0xa8, 0x31, 0xe4, 0x1a, 0xda, 0x0e, 0xaf,
        0xe2, 0x17, 0x49, 0x38, 0xab, 0xde, 0x80, 0x60,
        0x94, 0xbc, 0xd3, 0x85, 0x24, 0xea, 0x32, 0x9b,
        0xcd, 0xca, 0xcc, 0xbd, 0x55, 0xf1, 0x6b, 0x45,
    };
    try std.testing.expectEqualSlices(
        u8,
        &expected_observation_sha256,
        &observation.observation_sha256,
    );

    var occupied_drift = observation;
    occupied_drift.resource_allocated_size_bytes = 999;
    occupied_drift.observation_sha256 =
        observationRootV1(occupied_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(occupied_drift, authority, 9),
    );

    var logical_drift = observation;
    logical_drift.charged_resource_bytes += 1;
    logical_drift.observation_sha256 =
        observationRootV1(logical_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(logical_drift, authority, 9),
    );

    var root_drift = observation;
    root_drift.device_registry_id += 1;
    root_drift.observation_sha256 =
        observationRootV1(root_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(root_drift, authority, 9),
    );

    var impossible_slot = observation;
    impossible_slot.adapter_slot_index = 3;
    impossible_slot.observation_sha256 =
        observationRootV1(impossible_slot);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(impossible_slot, authority, 9),
    );

    var impossible_ordinal = observation;
    impossible_ordinal.ordinal = 3;
    impossible_ordinal.observation_sha256 =
        observationRootV1(impossible_ordinal);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(impossible_ordinal, authority, 9),
    );

    var impossible_size = observation;
    impossible_size.requested_bytes = 4_097;
    impossible_size.charged_resource_bytes = 4_097;
    impossible_size.buffer_length_bytes = 4_097;
    impossible_size.resource_allocated_size_bytes = 8_192;
    impossible_size.object_sha256 =
        allocation.backendObjectRootV1(.{
            .allocation_call_sha256 = impossible_size.allocation_call_sha256,
            .binding_sha256 = impossible_size.binding_sha256,
            .backend_object_sha256 = impossible_size.backend_object_sha256,
            .backend_object_generation = impossible_size.backend_object_generation,
            .allocated_bytes = impossible_size.charged_resource_bytes,
        });
    impossible_size.observation_sha256 =
        observationRootV1(impossible_size);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(impossible_size, authority, 9),
    );

    var backend_identity_drift = observation;
    backend_identity_drift.backend_object_sha256 =
        native.contract.digestV1("impossible backend identity");
    backend_identity_drift.object_sha256 =
        allocation.backendObjectRootV1(.{
            .allocation_call_sha256 = backend_identity_drift.allocation_call_sha256,
            .binding_sha256 = backend_identity_drift.binding_sha256,
            .backend_object_sha256 = backend_identity_drift.backend_object_sha256,
            .backend_object_generation = backend_identity_drift.backend_object_generation,
            .allocated_bytes = backend_identity_drift.charged_resource_bytes,
        });
    backend_identity_drift.observation_sha256 =
        observationRootV1(backend_identity_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(
            backend_identity_drift,
            authority,
            9,
        ),
    );

    var object_root_drift = observation;
    object_root_drift.object_sha256 =
        native.contract.digestV1("impossible object root");
    object_root_drift.observation_sha256 =
        observationRootV1(object_root_drift);
    try std.testing.expectError(
        Error.InvalidObservation,
        validateObservationV1(object_root_drift, authority, 9),
    );
}
