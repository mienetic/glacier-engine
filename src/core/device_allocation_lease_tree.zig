//! LeaseTree-backed backend allocation ownership.
//!
//! This coordinator is deliberately separate from the ChildLease-backed
//! device-allocation V1 ABI. It reuses immutable selection, request, quote,
//! allocation-call, backend-object, and adapter contracts while binding live
//! ownership to ResourceBank's reserve/materialize/free-permit protocol.
//!
//! One coordinator owns one pre-created scope in an additive LeaseTree. The
//! tree and publication sequence are shared by address with the surrounding
//! execution owner so sibling structural mutations cannot leave a cached tree
//! token behind. Allocation batches, retire tickets, and free permits remain
//! coordinator-private.

const std = @import("std");
const device = @import("device_capability_contract.zig");
const allocation = @import("device_allocation_lease.zig");
const resource = @import("resource_bank.zig");

pub const Digest = allocation.Digest;
pub const zero_digest = allocation.zero_digest;

pub const admission_abi: u64 = 0x4744_5441_0000_0001;
pub const lease_abi: u64 = 0x4744_544c_0000_0001;
pub const recovery_abi: u64 = 0x4744_5452_0000_0001;
pub const terminal_abi: u64 = 0x4744_5454_0000_0001;
pub const dispatch_pin_abi: u64 = 0x4744_5450_0000_0001;
pub const dispatch_pin_intent_abi: u64 =
    0x4744_5449_0000_0001;
pub const dispatch_terminal_abi: u64 = 0x4744_5444_0000_0001;
pub const dispatch_completion_abi: u64 = 0x4744_5443_0000_0001;

const admission_domain =
    "glacier-device-tree-allocation-admission-v1\x00";
const lease_domain =
    "glacier-device-tree-allocation-lease-v1\x00";
const recovery_domain =
    "glacier-device-tree-allocation-recovery-v1\x00";
const terminal_domain =
    "glacier-device-tree-allocation-terminal-v1\x00";
const dispatch_pin_domain =
    "glacier-device-tree-dispatch-pin-v1\x00";
const dispatch_pin_intent_domain =
    "glacier-device-tree-dispatch-pin-intent-v1\x00";
const dispatch_terminal_domain =
    "glacier-device-tree-dispatch-terminal-v1\x00";
const dispatch_completion_domain =
    "glacier-device-tree-dispatch-completion-v1\x00";
const tree_domain =
    "glacier-resource-lease-tree-v1\x00";
const node_domain =
    "glacier-resource-lease-node-v1\x00";
const batch_domain =
    "glacier-resource-lease-allocation-batch-v1\x00";
const permit_domain =
    "glacier-resource-lease-free-permit-v1\x00";
const leaf_set_domain =
    "glacier-device-tree-allocation-leaf-set-v1\x00";
const publication_binding_domain =
    "glacier-device-tree-publication-binding-v1\x00";
const outstanding_set_domain =
    "glacier-device-tree-allocation-outstanding-v1\x00";
const node_key_domain =
    "glacier-device-tree-allocation-node-key-v1\x00";
const binding_key_domain =
    "glacier-device-tree-allocation-binding-key-v1\x00";
const dispatch_owner_domain =
    "glacier-device-tree-dispatch-owner-v1\x00";
const dispatch_publication_domain =
    "glacier-device-tree-dispatch-publication-v1\x00";
const bank_pin_domain =
    "glacier-resource-lease-pin-permit-v1\x00";
const bank_pin_completion_domain =
    "glacier-resource-lease-pin-completion-v1\x00";

pub const Error =
    allocation.Error ||
    resource.Error ||
    error{
        AlreadyInitialized,
        InvalidCoordinator,
        InvalidTreeAdmission,
        InvalidTreeLease,
        InvalidTreeRecovery,
        InvalidTreeTerminalReceipt,
        InvalidDispatchAdapter,
        InvalidDispatchPin,
        InvalidDispatchTerminal,
        InvalidDispatchCompletion,
        InvalidDispatchReconciliationBinding,
        DispatchReconciliationAdapterBusy,
        DispatchReconciliationAdapterUnavailable,
        InvalidRetirementBinding,
        RetirementAdapterBusy,
        RetirementAdapterUnavailable,
        InvalidTreeBinding,
        InvalidExclusiveScope,
        DispatchSlotsExhausted,
        DispatchInFlight,
        CoordinatorBusy,
        GenerationExhausted,
    };

pub const DispatchCallbackError = error{
    Unavailable,
    InvalidDispatchIntent,
    InvalidTerminalEvidence,
    InvalidSettlementEvidence,
};

pub const RetirementBindingCallbackError = error{
    InvalidRetirementBinding,
    Busy,
    Unavailable,
};

pub const ActiveDispatchReconciliationBindingCallbackError = error{
    InvalidReconciliationBinding,
    Busy,
    Unavailable,
};

/// Only terminal queue states may release a device-allocation pin. Pending,
/// unknown, timed-out, or device-lost observations intentionally have no
/// value in this enum and must retain the pin for later reconciliation.
/// `ownership_retired_after_device_loss` additionally requires backend proof
/// that the exact native callback was detached while its command record stayed
/// retained for the private post-Bank settlement callback.
pub const DispatchTerminalOutcomeV1 = enum(u64) {
    succeeded = 1,
    terminal_failure = 2,
    cancelled_before_submit = 3,
    cancelled_after_submit = 4,
    rejected_before_submit = 5,
    ownership_retired_after_device_loss = 6,
    _,
};

/// Backend-owned terminal command evidence. Checksums are composition
/// evidence, not authentication; live completion additionally requires the
/// exact adapter context and validation callback bound at pin acquisition.
pub const DispatchTerminalEvidenceV1 = struct {
    abi_version: u64 = dispatch_terminal_abi,
    outcome: DispatchTerminalOutcomeV1 = .rejected_before_submit,
    dispatch_generation: u64 = 0,
    dispatch_authority_sha256: Digest = zero_digest,
    queue_authority_sha256: Digest = zero_digest,
    pin_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    submission_sha256: Digest = zero_digest,
    backend_completion_sha256: Digest = zero_digest,
    output_sha256: Digest = zero_digest,
    terminal_sha256: Digest = zero_digest,
};

/// Pre-Bank reservation of one exact adapter request. The intent closes the
/// gap between request preparation and private Bank pin acquisition without
/// claiming that a pin already exists.
pub const DispatchPinIntentV1 = struct {
    abi_version: u64 = dispatch_pin_intent_abi,
    coordinator_epoch: u64 = 0,
    allocation_generation: u64 = 0,
    dispatch_generation: u64 = 0,
    allocation_count: u64 = 0,
    pinned_device_bytes: u64 = 0,
    authority_sha256: Digest = zero_digest,
    dispatch_authority_sha256: Digest = zero_digest,
    queue_authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    lease_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    allocation_leaf_set_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    scope_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    publication_binding_sha256: Digest = zero_digest,
    intent_sha256: Digest = zero_digest,
};

pub const DispatchAdapterV1 = struct {
    context: *anyopaque,
    dispatch_authority_sha256: Digest,
    queue_authority_sha256: Digest,
    /// Reserve one adapter-side request before ResourceBank is mutated.
    /// Success must be idempotent for the exact intent; errors must not retain
    /// partial state.
    reserve_dispatch_intent_fn: *const fn (
        context: *anyopaque,
        intent: DispatchPinIntentV1,
    ) DispatchCallbackError!void,
    /// Undo the exact successful reservation when callback-source validation
    /// or atomic Bank pin acquisition fails.
    abort_dispatch_intent_fn: *const fn (
        context: *anyopaque,
        intent: DispatchPinIntentV1,
    ) DispatchCallbackError!void,
    /// Terminal authorization only. Calling this function directly never
    /// proves that ResourceBank consumed the pin.
    validate_terminal_fn: *const fn (
        context: *anyopaque,
        terminal: DispatchTerminalEvidenceV1,
    ) DispatchCallbackError!void,
    /// Post-release capability confirmation. The coordinator alone retains
    /// `bank_permit` and invokes this only after `bank_completion` exists.
    /// Adapters must accept exact retries idempotently and must not call back
    /// into the coordinator or Bank while this function runs.
    confirm_settlement_fn: *const fn (
        context: *anyopaque,
        pin: LeaseTreeDispatchPinV1,
        terminal: DispatchTerminalEvidenceV1,
        completion: LeaseTreeDispatchCompletionV1,
        bank_permit: resource.LeasePinPermitV1,
        bank_completion: resource.LeasePinCompletionV1,
    ) DispatchCallbackError!void,
};

/// Same-process callback through which the coordinator presents its exact
/// retained live lease and object set to one already-bound allocation
/// adapter. These values grant no Bank authority; the callback may only
/// establish adapter-private retirement state. The call/object slices borrow
/// coordinator stack storage only for the callback duration and must not be
/// retained.
pub const RetirementBindingAdapterV1 = struct {
    context: *anyopaque,
    allocation_adapter: allocation.AdapterV1,
    arm_fn: *const fn (
        context: *anyopaque,
        retained_lease: LeaseTreeDeviceAllocationLeaseV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) RetirementBindingCallbackError!void,
};

/// Same-process callback through which the coordinator presents the exact
/// retained evidence for one currently pinned dispatch. The Bank permit stays
/// private to the coordinator. The call/object slices borrow coordinator stack
/// storage only for the callback duration and must not be retained.
pub const ActiveDispatchReconciliationBindingV1 = struct {
    context: *anyopaque,
    dispatch_adapter: DispatchAdapterV1,
    reconcile_fn: *const fn (
        context: *anyopaque,
        retained_lease: LeaseTreeDeviceAllocationLeaseV1,
        retained_pin: LeaseTreeDispatchPinV1,
        retained_intent: DispatchPinIntentV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) ActiveDispatchReconciliationBindingCallbackError!void,
};

/// Reservation evidence returned only after ResourceBank has atomically
/// charged the complete adapter-quoted allocation wave.
pub const LeaseTreeAllocationAdmissionV1 = struct {
    abi_version: u64 = admission_abi,
    coordinator_epoch: u64 = 0,
    generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    selection_receipt_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    allocation_manifest_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    reservation_tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    allocation_batch_sha256: Digest = zero_digest,
    allocation_leaf_set_sha256: Digest = zero_digest,
    publication_binding_sha256: Digest = zero_digest,
    allocation_count: u64 = 0,
    total_device_bytes: u64 = 0,
    admission_sha256: Digest = zero_digest,
};

/// Live object-set evidence. `materialized_tree` is an immutable observation
/// at the settlement point; current Bank authority stays in the coordinator's
/// shared tree pointer.
pub const LeaseTreeDeviceAllocationLeaseV1 = struct {
    abi_version: u64 = lease_abi,
    coordinator_epoch: u64 = 0,
    generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    selection_receipt_sha256: Digest = zero_digest,
    selected_capability_sha256: Digest = zero_digest,
    allocation_manifest_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    materialized_tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    allocation_leaf_set_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    allocation_count: u64 = 0,
    materialized_bytes: u64 = 0,
    lease_sha256: Digest = zero_digest,
};

pub const RecoveryPhaseV1 = enum(u64) {
    /// Objects may remain while the Bank batch is reserved_unmaterialized.
    rollback_reserved = 1,
    /// An irreversible FreePermit exists and objects may remain live.
    free_authorized = 2,
    /// Every object is gone; the FreePermit still needs Bank settlement.
    settlement_required = 3,
    _,
};

pub const LeaseTreeAllocationRecoveryV1 = struct {
    abi_version: u64 = recovery_abi,
    phase: RecoveryPhaseV1 = .rollback_reserved,
    target_outcome: allocation.TerminalOutcomeV1 = .cancelled,
    target_reason: allocation.TerminalReasonV1 =
        .explicit_cancellation,
    coordinator_epoch: u64 = 0,
    generation: u64 = 0,
    recovery_generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    lease_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    bank_authority_sha256: Digest = zero_digest,
    total_device_bytes: u64 = 0,
    outstanding_object_count: u64 = 0,
    outstanding_bytes: u64 = 0,
    outstanding_set_sha256: Digest = zero_digest,
    pending_tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    recovery_sha256: Digest = zero_digest,
};

/// Terminal evidence includes the exact tree token produced by
/// abort-after-free or commit-free-after-free. This coordinator's scope is
/// empty; sibling scopes may remain live in the shared tree.
pub const LeaseTreeAllocationTerminalReceiptV1 = struct {
    abi_version: u64 = terminal_abi,
    outcome: allocation.TerminalOutcomeV1 = .cancelled,
    reason: allocation.TerminalReasonV1 = .explicit_cancellation,
    coordinator_epoch: u64 = 0,
    generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    lease_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    allocation_batch_sha256: Digest = zero_digest,
    returned_device_bytes: u64 = 0,
    terminal_tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    terminal_sha256: Digest = zero_digest,
};

/// Pointer-free evidence that the exact live allocation object set is pinned
/// in ResourceBank for one bounded queue use. The private Bank permit remains
/// inside the coordinator; this value grants no unpin authority.
pub const LeaseTreeDispatchPinV1 = struct {
    abi_version: u64 = dispatch_pin_abi,
    coordinator_epoch: u64 = 0,
    allocation_generation: u64 = 0,
    dispatch_generation: u64 = 0,
    authority_sha256: Digest = zero_digest,
    dispatch_authority_sha256: Digest = zero_digest,
    queue_authority_sha256: Digest = zero_digest,
    request_sha256: Digest = zero_digest,
    admission_sha256: Digest = zero_digest,
    lease_sha256: Digest = zero_digest,
    parent_receipt_sha256: Digest = zero_digest,
    allocation_leaf_set_sha256: Digest = zero_digest,
    backend_object_set_sha256: Digest = zero_digest,
    dispatch_request_sha256: Digest = zero_digest,
    publication_binding_sha256: Digest = zero_digest,
    bank_pin_sha256: Digest = zero_digest,
    pinned_tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    allocation_count: u64 = 0,
    pinned_device_bytes: u64 = 0,
    pin_sha256: Digest = zero_digest,
};

/// Terminal proof that one exact dispatch pin was consumed. Completion only
/// means the queue no longer references these allocations; it grants no
/// output-publication or residency authority.
pub const LeaseTreeDispatchCompletionV1 = struct {
    abi_version: u64 = dispatch_completion_abi,
    outcome: DispatchTerminalOutcomeV1 = .rejected_before_submit,
    coordinator_epoch: u64 = 0,
    allocation_generation: u64 = 0,
    dispatch_generation: u64 = 0,
    pin_sha256: Digest = zero_digest,
    dispatch_terminal_sha256: Digest = zero_digest,
    submission_sha256: Digest = zero_digest,
    backend_completion_sha256: Digest = zero_digest,
    output_sha256: Digest = zero_digest,
    bank_completion_sha256: Digest = zero_digest,
    completion_publication_binding_sha256: Digest = zero_digest,
    completed_tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    completion_sha256: Digest = zero_digest,
};

comptime {
    // These are auto-layout Zig evidence values, not a byte wire codec. Keep
    // the expected 64-bit in-memory footprint stable without rejecting 32-bit
    // source compilation, where alignment may legitimately differ.
    if (@sizeOf(usize) == 8 and
        (@sizeOf(LeaseTreeAllocationAdmissionV1) != 1080 or
            @sizeOf(LeaseTreeDeviceAllocationLeaseV1) != 1080 or
            @sizeOf(LeaseTreeAllocationRecoveryV1) != 1056 or
            @sizeOf(LeaseTreeAllocationTerminalReceiptV1) != 1024 or
            @sizeOf(DispatchPinIntentV1) != 464 or
            @sizeOf(DispatchTerminalEvidenceV1) != 280 or
            @sizeOf(LeaseTreeDispatchPinV1) != 1184 or
            @sizeOf(LeaseTreeDispatchCompletionV1) != 1016))
        @compileError(
            "LeaseTree device allocation V1 64-bit footprint changed",
        );
}

pub const MaterializeOutcomeV1 = union(enum) {
    active: LeaseTreeDeviceAllocationLeaseV1,
    terminal: LeaseTreeAllocationTerminalReceiptV1,
    recovery_required: LeaseTreeAllocationRecoveryV1,
};

pub const RecoveryOutcomeV1 = union(enum) {
    terminal: LeaseTreeAllocationTerminalReceiptV1,
    recovery_required: LeaseTreeAllocationRecoveryV1,
};

const CoordinatorStateV1 = enum(u8) {
    idle,
    reserved,
    live,
    rollback_required,
    free_authorized,
    settlement_required,
};

const ObjectStateV1 = enum(u8) {
    free,
    reserved,
    live,
};

const DispatchSlotStateV1 = enum(u8) {
    free,
    pinned,
    settlement_pending,
};

pub const maximum_dispatches: usize = 64;

/// Caller-owned fixed object storage. Raw backend handles remain inside the
/// adapter; these are pointer-free object identities and exact leaf bindings.
pub const CoordinatorObjectSlotV1 = struct {
    state: ObjectStateV1 = .free,
    coordinator_generation: u64 = 0,
    ordinal: u64 = 0,
    entry: allocation.AllocationEntryV1 = .{},
    leaf: resource.LeaseNodeV1 = undefined,
    call: allocation.AllocationCallV1 = .{},
    object: allocation.BackendObjectV1 = .{},
};

/// Caller-owned private dispatch storage. Bank mutation authority and adapter
/// function identities never enter public dispatch evidence.
pub const CoordinatorDispatchSlotV1 = struct {
    state: DispatchSlotStateV1 = .free,
    allocation_generation: u64 = 0,
    dispatch_generation: u64 = 0,
    adapter_context: ?*anyopaque = null,
    adapter_reserve_dispatch_intent_fn: ?@TypeOf(
        @as(DispatchAdapterV1, undefined)
            .reserve_dispatch_intent_fn,
    ) = null,
    adapter_abort_dispatch_intent_fn: ?@TypeOf(
        @as(DispatchAdapterV1, undefined)
            .abort_dispatch_intent_fn,
    ) = null,
    adapter_validate_terminal_fn: ?@TypeOf(
        @as(DispatchAdapterV1, undefined).validate_terminal_fn,
    ) = null,
    adapter_confirm_settlement_fn: ?@TypeOf(
        @as(DispatchAdapterV1, undefined).confirm_settlement_fn,
    ) = null,
    bank_permit: ?resource.LeasePinPermitV1 = null,
    intent: ?DispatchPinIntentV1 = null,
    pin: ?LeaseTreeDispatchPinV1 = null,
    terminal: ?DispatchTerminalEvidenceV1 = null,
    completion: ?LeaseTreeDispatchCompletionV1 = null,
    bank_completion: ?resource.LeasePinCompletionV1 = null,
};

const CoordinatorBindingsV1 = struct {
    epoch: u64,
    bank: *resource.Bank,
    tree: *resource.LeaseTreeV1,
    scope: resource.LeaseNodeV1,
    request_epoch: u64,
    session_id: usize,
    publication_sequence: *u64,
    publication_sequence_value: u64,
    objects: []CoordinatorObjectSlotV1,
    dispatches: []CoordinatorDispatchSlotV1,
    next_generation: u64,
    next_dispatch_generation: u64,
    generation: u64,
    recovery_generation: u64,
    adapter: allocation.AdapterV1,
};

const RollbackSourceV1 = struct {
    bindings: CoordinatorBindingsV1,
    authority: allocation.AllocationAuthorityV1,
    request: allocation.AllocationRequestV1,
    admission: LeaseTreeAllocationAdmissionV1,
    batch: resource.LeaseAllocationBatchV1,
    allocation_count: usize,
    objects: [allocation.maximum_allocations]CoordinatorObjectSlotV1,
    dispatch_count: usize,
    dispatches: [maximum_dispatches]CoordinatorDispatchSlotV1,
};

const FreeSourceV1 = struct {
    bindings: CoordinatorBindingsV1,
    authority: allocation.AllocationAuthorityV1,
    request: allocation.AllocationRequestV1,
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
    object_set: allocation.BackendObjectSetV1,
    tree: resource.LeaseTreeV1,
    permit: resource.LeaseFreePermitV1,
    target_outcome: allocation.TerminalOutcomeV1,
    target_reason: allocation.TerminalReasonV1,
    allocation_count: usize,
    objects: [allocation.maximum_allocations]CoordinatorObjectSlotV1,
    dispatch_count: usize,
    dispatches: [maximum_dispatches]CoordinatorDispatchSlotV1,
};

const DispatchValidationSourceV1 = struct {
    bindings: CoordinatorBindingsV1,
    tree: resource.LeaseTreeV1,
    authority: allocation.AllocationAuthorityV1,
    request: allocation.AllocationRequestV1,
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
    object_set: allocation.BackendObjectSetV1,
    allocation_count: usize,
    objects: [allocation.maximum_allocations]CoordinatorObjectSlotV1,
    dispatch_count: usize,
    dispatches: [maximum_dispatches]CoordinatorDispatchSlotV1,
};

pub const CoordinatorSnapshotV1 = struct {
    coordinator_epoch: u64,
    next_generation: u64,
    idle: bool,
    reserved_wave: bool,
    live_lease: bool,
    rollback_required: bool,
    free_authorized: bool,
    settlement_required: bool,
    reserved_objects: usize,
    live_objects: usize,
    dispatch_capacity: usize,
    active_dispatches: usize,
};

var empty_dispatch_slots: [0]CoordinatorDispatchSlotV1 = .{};

/// Address-stable, synchronous coordinator for one exclusive LeaseTree scope.
///
/// Adapter and cancellation callbacks execute under the coordinator mutex and
/// must not re-enter it. The surrounding tree owner serializes mutations and
/// updates the shared publication sequence after its own publications.
pub const CoordinatorV1 = struct {
    initialized: bool = false,
    self_address: usize = 0,
    epoch: u64 = 0,
    bound_epoch: u64 = 0,
    bank: *resource.Bank = undefined,
    bound_bank: *resource.Bank = undefined,
    tree: *resource.LeaseTreeV1 = undefined,
    bound_tree: *resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    bound_scope: resource.LeaseNodeV1 = undefined,
    request_epoch: u64 = 0,
    bound_request_epoch: u64 = 0,
    session_id: usize = 0,
    bound_session_id: usize = 0,
    publication_sequence: *u64 = undefined,
    bound_publication_sequence: *u64 = undefined,
    objects: []CoordinatorObjectSlotV1 = undefined,
    bound_objects_address: usize = 0,
    bound_objects_len: usize = 0,
    dispatches: []CoordinatorDispatchSlotV1 =
        empty_dispatch_slots[0..],
    bound_dispatches_address: usize = 0,
    bound_dispatches_len: usize = 0,
    next_generation: u64 = 1,
    next_dispatch_generation: u64 = 1,
    state: CoordinatorStateV1 = .idle,
    generation: u64 = 0,
    authority: allocation.AllocationAuthorityV1 = .{},
    request: allocation.AllocationRequestV1 = .{},
    admission: LeaseTreeAllocationAdmissionV1 = undefined,
    batch: ?resource.LeaseAllocationBatchV1 = null,
    object_set: allocation.BackendObjectSetV1 = .{},
    lease: LeaseTreeDeviceAllocationLeaseV1 = undefined,
    permit: ?resource.LeaseFreePermitV1 = null,
    target_outcome: allocation.TerminalOutcomeV1 = .cancelled,
    target_reason: allocation.TerminalReasonV1 =
        .explicit_cancellation,
    recovery_generation: u64 = 0,
    recovery: LeaseTreeAllocationRecoveryV1 = undefined,
    adapter_context: ?*anyopaque = null,
    adapter_quote_fn: ?@TypeOf(
        @as(allocation.AdapterV1, undefined).quote_fn,
    ) = null,
    adapter_allocate_fn: ?@TypeOf(
        @as(allocation.AdapterV1, undefined).allocate_fn,
    ) = null,
    adapter_free_fn: ?@TypeOf(
        @as(allocation.AdapterV1, undefined).free_fn,
    ) = null,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        self: *CoordinatorV1,
        epoch: u64,
        bank: *resource.Bank,
        shared_tree: *resource.LeaseTreeV1,
        scope: resource.LeaseNodeV1,
        request_epoch: u64,
        session_id: usize,
        shared_publication_sequence: *u64,
        objects: []CoordinatorObjectSlotV1,
    ) Error!void {
        return self.initStorage(
            epoch,
            bank,
            shared_tree,
            scope,
            request_epoch,
            session_id,
            shared_publication_sequence,
            objects,
            empty_dispatch_slots[0..],
        );
    }

    /// Opt into bounded two-phase dispatch pins without changing callers that
    /// only need allocation ownership. The Bank must also have been
    /// initialized with LeasePin storage.
    pub fn initWithDispatchStorage(
        self: *CoordinatorV1,
        epoch: u64,
        bank: *resource.Bank,
        shared_tree: *resource.LeaseTreeV1,
        scope: resource.LeaseNodeV1,
        request_epoch: u64,
        session_id: usize,
        shared_publication_sequence: *u64,
        objects: []CoordinatorObjectSlotV1,
        dispatches: []CoordinatorDispatchSlotV1,
    ) Error!void {
        if (dispatches.len == 0 or
            dispatches.len > maximum_dispatches)
            return Error.InvalidCoordinator;
        return self.initStorage(
            epoch,
            bank,
            shared_tree,
            scope,
            request_epoch,
            session_id,
            shared_publication_sequence,
            objects,
            dispatches,
        );
    }

    fn initStorage(
        self: *CoordinatorV1,
        epoch: u64,
        bank: *resource.Bank,
        shared_tree: *resource.LeaseTreeV1,
        scope: resource.LeaseNodeV1,
        request_epoch: u64,
        session_id: usize,
        shared_publication_sequence: *u64,
        objects: []CoordinatorObjectSlotV1,
        dispatches: []CoordinatorDispatchSlotV1,
    ) Error!void {
        if (self.initialized or self.self_address != 0)
            return Error.AlreadyInitialized;
        if (epoch == 0 or request_epoch == 0 or session_id == 0 or
            objects.len == 0 or
            objects.len > allocation.maximum_allocations or
            dispatches.len > maximum_dispatches or
            dispatches.len > scope.parent.claim.queue_slots or
            scope.kind != .scope or scope.binding_key != 0 or
            scope.ceiling.device_bytes == 0 or
            !claimIsDeviceOnly(scope.ceiling))
            return Error.InvalidCoordinator;
        try bank.validateAdditiveLeaseTree(shared_tree.*);
        try bank.validateLeaseNode(shared_tree.*, scope);
        try bank.validateLeaseScopeSubtreeClaim(
            shared_tree.*,
            scope,
            .{},
        );
        try bank.validatePublicationSession(
            shared_tree.parent,
            request_epoch,
            session_id,
            shared_publication_sequence.*,
        );
        for (objects) |*object| object.* = .{};
        for (dispatches) |*dispatch| dispatch.* = .{};
        self.* = .{
            .initialized = true,
            .self_address = @intFromPtr(self),
            .epoch = epoch,
            .bound_epoch = epoch,
            .bank = bank,
            .bound_bank = bank,
            .tree = shared_tree,
            .bound_tree = shared_tree,
            .scope = scope,
            .bound_scope = scope,
            .request_epoch = request_epoch,
            .bound_request_epoch = request_epoch,
            .session_id = session_id,
            .bound_session_id = session_id,
            .publication_sequence = shared_publication_sequence,
            .bound_publication_sequence = shared_publication_sequence,
            .objects = objects,
            .bound_objects_address = @intFromPtr(objects.ptr),
            .bound_objects_len = objects.len,
            .dispatches = dispatches,
            .bound_dispatches_address = @intFromPtr(dispatches.ptr),
            .bound_dispatches_len = dispatches.len,
        };
    }

    pub fn snapshot(
        self: *CoordinatorV1,
    ) Error!CoordinatorSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateAddress();
        var reserved_objects: usize = 0;
        var live_objects: usize = 0;
        var active_dispatches: usize = 0;
        for (self.objects) |object| switch (object.state) {
            .free => {},
            .reserved => reserved_objects += 1,
            .live => live_objects += 1,
        };
        for (self.dispatches) |dispatch| switch (dispatch.state) {
            .free => {},
            .pinned, .settlement_pending => active_dispatches += 1,
        };
        return .{
            .coordinator_epoch = self.epoch,
            .next_generation = self.next_generation,
            .idle = self.state == .idle,
            .reserved_wave = self.state == .reserved,
            .live_lease = self.state == .live,
            .rollback_required = self.state == .rollback_required,
            .free_authorized = self.state == .free_authorized,
            .settlement_required = self.state == .settlement_required,
            .reserved_objects = reserved_objects,
            .live_objects = live_objects,
            .dispatch_capacity = self.dispatches.len,
            .active_dispatches = active_dispatches,
        };
    }

    /// Replay all fallible portable and adapter evidence, then reserve the
    /// exact additive LeaseTree wave before any allocation callback.
    pub fn admit(
        self: *CoordinatorV1,
        adapter: allocation.AdapterV1,
        request: allocation.AllocationRequestV1,
        selection_receipt: device.DeviceSelectionReceiptV1,
        requirement: device.DeviceRequirementV1,
        inventory: []const device.DeviceInventoryEntryV1,
        parent: resource.Receipt,
        manifest: allocation.AllocationManifestV1,
        entries: []const allocation.AllocationEntryV1,
    ) Error!LeaseTreeAllocationAdmissionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateAddress();
        if (self.state != .idle) return Error.CoordinatorBusy;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return Error.GenerationExhausted;
        for (self.objects) |object|
            if (object.state != .free)
                return Error.InvalidCoordinator;
        for (self.dispatches) |dispatch|
            if (!dispatchSlotCanonicalFree(dispatch))
                return Error.InvalidCoordinator;
        try allocation.validateRequestV1(
            request,
            adapter.authority,
            selection_receipt,
            requirement,
            inventory,
            parent,
            manifest,
            entries,
        );
        if (request.request_epoch != self.request_epoch or
            !std.meta.eql(parent, self.tree.parent) or
            entries.len != self.objects.len or
            request.total_device_bytes !=
                self.scope.ceiling.device_bytes)
            return Error.InvalidTreeBinding;
        try self.bank.validateAdditiveLeaseTree(self.tree.*);
        try self.bank.validateLeaseNode(self.tree.*, self.scope);
        try self.bank.validateLeaseScopeSubtreeClaim(
            self.tree.*,
            self.scope,
            .{},
        );
        try self.bank.validatePublicationSession(
            parent,
            self.request_epoch,
            self.session_id,
            self.publication_sequence.*,
        );

        for (entries) |entry| {
            const replayed = adapter.quote_fn(
                adapter.context,
                entry.binding_sha256,
                entry.requested_bytes,
            ) catch return Error.InvalidQuote;
            try allocation.validateQuoteV1(
                replayed,
                adapter.authority,
            );
            const expected = allocation.makeQuoteV1(
                adapter.authority,
                entry.binding_sha256,
                entry.requested_bytes,
                entry.charged_bytes,
            ) catch return Error.InvalidQuote;
            if (!std.meta.eql(replayed, expected) or
                !digestEqual(
                    replayed.quote_sha256,
                    entry.quote_sha256,
                ))
                return Error.InvalidQuote;
        }

        const generation = self.next_generation;
        var specs: [allocation.maximum_allocations]resource.LeaseAllocationSpecV1 =
            undefined;
        var leaves: [allocation.maximum_allocations]resource.LeaseNodeV1 =
            undefined;
        for (entries, 0..) |entry, ordinal| {
            const node_key = allocationKey(
                node_key_domain,
                self.epoch,
                generation,
                ordinal,
                entry.binding_sha256,
            );
            const binding_key = allocationKey(
                binding_key_domain,
                self.epoch,
                generation,
                ordinal,
                entry.binding_sha256,
            );
            for (specs[0..ordinal]) |prior| {
                if (prior.node_key == node_key or
                    prior.binding_key == binding_key)
                    return Error.InvalidTreeBinding;
            }
            specs[ordinal] = .{
                .scope = self.scope,
                .node_key = node_key,
                .binding_key = binding_key,
                .claim = .{ .device_bytes = entry.charged_bytes },
            };
        }
        const reservation =
            try self.bank.reserveAllocationsForSession(
                self.tree.*,
                self.request_epoch,
                self.session_id,
                self.publication_sequence.*,
                specs[0..entries.len],
                leaves[0..entries.len],
            );
        self.tree.* = reservation.tree;

        const admission = makeAdmission(
            self.epoch,
            generation,
            adapter.authority,
            request,
            reservation,
            self.scope,
            leaves[0..entries.len],
        );
        self.state = .reserved;
        self.generation = generation;
        self.authority = adapter.authority;
        self.request = request;
        self.admission = admission;
        self.batch = reservation.batch;
        self.object_set = .{};
        self.permit = null;
        self.target_outcome = .cancelled;
        self.target_reason = .explicit_cancellation;
        self.recovery_generation = 0;
        self.adapter_context = adapter.context;
        self.adapter_quote_fn = adapter.quote_fn;
        self.adapter_allocate_fn = adapter.allocate_fn;
        self.adapter_free_fn = adapter.free_fn;
        for (entries, 0..) |entry, ordinal| {
            self.objects[ordinal] = .{
                .state = .reserved,
                .coordinator_generation = generation,
                .ordinal = @intCast(ordinal),
                .entry = entry,
                .leaf = leaves[ordinal],
            };
        }
        self.next_generation += 1;
        return admission;
    }

    pub fn cancelAdmission(
        self: *CoordinatorV1,
        admission: LeaseTreeAllocationAdmissionV1,
    ) Error!LeaseTreeAllocationTerminalReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateAdmission(admission, .reserved);
        if (self.liveObjectCount() != 0)
            return Error.InvalidTransition;
        const source = try self.captureRollbackSource(admission);
        try self.validateRollbackSource(source);
        const tree_after =
            try self.bank.abortAllocationsAfterFree(source.batch);
        self.tree.* = tree_after;
        const terminal = self.makeTerminal(
            source.admission,
            zero_digest,
            zero_digest,
            .cancelled,
            .explicit_cancellation,
        );
        self.clearLifecycle();
        return terminal;
    }

    pub fn materialize(
        self: *CoordinatorV1,
        admission: LeaseTreeAllocationAdmissionV1,
        adapter: allocation.AdapterV1,
        cancellation: allocation.CancellationProbeV1,
    ) Error!MaterializeOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateAdmission(admission, .reserved);
        try self.validateAdapter(adapter);
        try self.bank.validateLeaseTree(self.tree.*);
        try cancellation.validate();
        var rollback_source =
            try self.captureRollbackSource(admission);
        try self.validateRollbackSource(rollback_source);

        var ordinal: u64 = 0;
        while (ordinal < admission.allocation_count) : (ordinal += 1) {
            const cancelled_at_boundary =
                cancellation.cancelled(ordinal);
            self.restoreRollbackSourceAfterCallback(
                rollback_source,
            );
            if (cancelled_at_boundary)
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .cancelled,
                    .explicit_cancellation,
                );
            if (self.bank != self.bound_bank)
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            const object_slot =
                &rollback_source.objects[@intCast(ordinal)];
            if (object_slot.state != .reserved or
                object_slot.coordinator_generation !=
                    admission.generation or
                object_slot.ordinal != ordinal)
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            const call =
                allocation.makeAllocationCallForAdmissionRootV1(
                    rollback_source.authority,
                    admission.admission_sha256,
                    ordinal,
                    rollback_source.objects[
                        @intCast(ordinal)
                    ].entry,
                ) catch {
                    return self.rollbackOrRecover(
                        adapter,
                        rollback_source,
                        .allocation_failed,
                        .backend_protocol_violation,
                    );
                };
            object_slot.call = call;
            self.restoreRollbackSource(rollback_source);
            const object = adapter.allocate_fn(
                adapter.context,
                call,
            ) catch {
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_allocation_failure,
                );
            };
            // Retain identity before validation so protocol-drift responses
            // still receive a cleanup attempt.
            object_slot.object = object;
            object_slot.state = .live;
            self.restoreRollbackSourceAfterCallback(
                rollback_source,
            );
            if (self.bank != self.bound_bank)
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            allocation.validateBackendObjectV1(
                object,
                call,
            ) catch {
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            };
            if (self.hasDuplicateObject(ordinal, object))
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
        }
        const cancelled_after_wave =
            cancellation.cancelled(admission.allocation_count);
        self.restoreRollbackSourceAfterCallback(
            rollback_source,
        );
        if (cancelled_after_wave)
            return self.rollbackOrRecover(
                adapter,
                rollback_source,
                .cancelled,
                .explicit_cancellation,
            );
        if (self.bank != self.bound_bank)
            return self.rollbackOrRecover(
                adapter,
                rollback_source,
                .allocation_failed,
                .backend_protocol_violation,
            );
        if (!self.recoveryStorageValid(.rollback_reserved))
            return self.rollbackOrRecover(
                adapter,
                rollback_source,
                .allocation_failed,
                .backend_protocol_violation,
            );

        var calls: [allocation.maximum_allocations]allocation.AllocationCallV1 =
            undefined;
        var objects: [allocation.maximum_allocations]allocation.BackendObjectV1 =
            undefined;
        self.copyLiveObjectsInOrder(
            calls[0..@intCast(admission.allocation_count)],
            objects[0..@intCast(admission.allocation_count)],
        ) catch {
            return self.rollbackOrRecover(
                adapter,
                rollback_source,
                .allocation_failed,
                .backend_protocol_violation,
            );
        };
        const object_set =
            allocation.makeObjectSetForAdmissionRootV1(
                admission.admission_sha256,
                admission.authority_sha256,
                admission.allocation_count,
                admission.total_device_bytes,
                calls[0..@intCast(admission.allocation_count)],
                objects[0..@intCast(admission.allocation_count)],
            ) catch {
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            };
        self.restoreRollbackSource(rollback_source);
        try self.validateRollbackSource(rollback_source);
        const materialized_tree =
            self.bank.commitAllocationsAfterAllocate(
                rollback_source.batch,
            ) catch {
                return self.rollbackOrRecover(
                    adapter,
                    rollback_source,
                    .allocation_failed,
                    .backend_protocol_violation,
                );
            };
        self.tree.* = materialized_tree;
        const lease = makeLease(
            rollback_source.admission,
            object_set,
            materialized_tree,
        );
        self.object_set = object_set;
        self.lease = lease;
        self.batch = null;
        self.state = .live;
        return .{ .active = lease };
    }

    /// Pin the exact full live object set before a backend may submit work.
    /// The returned value is evidence only; the ResourceBank mutation permit
    /// remains private in one generation-fenced coordinator slot.
    pub fn acquireDispatchPin(
        self: *CoordinatorV1,
        lease: LeaseTreeDeviceAllocationLeaseV1,
        adapter: DispatchAdapterV1,
        dispatch_request_sha256: Digest,
    ) Error!LeaseTreeDispatchPinV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateLease(lease);
        try validateDispatchAdapterV1(adapter);
        if (digestIsZero(dispatch_request_sha256))
            return Error.InvalidDispatchPin;
        if (self.dispatches.len == 0)
            return Error.InvalidConfiguration;
        if (self.next_dispatch_generation == 0 or
            self.next_dispatch_generation == std.math.maxInt(u64))
            return Error.GenerationExhausted;
        for (self.dispatches) |slot| {
            if (slot.state == .free) continue;
            const active_pin = slot.pin orelse
                return Error.InvalidCoordinator;
            if (slot.adapter_context == adapter.context and
                digestEqual(
                    active_pin.dispatch_request_sha256,
                    dispatch_request_sha256,
                ))
                return Error.InvalidDispatchPin;
        }
        const slot_index = for (self.dispatches, 0..) |slot, index| {
            if (slot.state == .free) {
                if (!dispatchSlotCanonicalFree(slot))
                    return Error.InvalidCoordinator;
                break index;
            }
        } else return Error.DispatchSlotsExhausted;

        try self.bank.validateAdditiveLeaseTree(self.tree.*);
        try self.bank.validatePublicationSession(
            self.tree.parent,
            self.request_epoch,
            self.session_id,
            self.publication_sequence.*,
        );
        try self.validateLiveObjectSet();
        try self.validateLiveAdmissionStorage();
        const expected_claim: resource.Claim = .{
            .device_bytes = lease.materialized_bytes,
        };
        try self.bank.validateLeaseScopeSubtreeClaim(
            self.tree.*,
            self.scope,
            expected_claim,
        );
        var leaves: [allocation.maximum_allocations]resource.LeaseNodeV1 =
            undefined;
        for (
            self.objects[0..@intCast(lease.allocation_count)],
            0..,
        ) |object, ordinal| {
            try self.bank.validateLeaseNode(
                self.tree.*,
                object.leaf,
            );
            leaves[ordinal] = object.leaf;
        }

        const dispatch_generation = self.next_dispatch_generation;
        const intent = makeDispatchPinIntent(
            self.admission,
            self.lease,
            self.scope,
            adapter,
            dispatch_generation,
            dispatch_request_sha256,
            dispatchPublicationBindingSha256V1(
                self.tree.parent,
                self.bound_request_epoch,
                self.bound_session_id,
                self.publication_sequence.*,
            ),
        );
        const intent_source =
            try self.captureDispatchValidationSource();
        const reserve_intent_result =
            adapter.reserve_dispatch_intent_fn(
                adapter.context,
                intent,
            );
        self.restoreDispatchValidationSourceAfterCallback(
            intent_source,
        );
        reserve_intent_result catch {
            try self.validateDispatchValidationSource(
                intent_source,
            );
            return Error.InvalidDispatchPin;
        };
        self.validateDispatchValidationSource(
            intent_source,
        ) catch |validation_error| {
            try self.abortDispatchIntentAndValidateSource(
                intent_source,
                adapter,
                intent,
            );
            return validation_error;
        };

        const owner_key = dispatchOwnerKeyV1(
            self.epoch,
            self.generation,
            dispatch_generation,
            dispatch_request_sha256,
        );
        const acquired =
            self.bank.acquireLeasePinsForSession(
                self.tree.*,
                self.scope,
                self.request_epoch,
                self.session_id,
                self.publication_sequence.*,
                owner_key,
                leaves[0..@intCast(lease.allocation_count)],
            ) catch |acquire_error| {
                try self.abortDispatchIntentAndValidateSource(
                    intent_source,
                    adapter,
                    intent,
                );
                return acquire_error;
            };
        self.tree.* = acquired.tree;
        const pin = makeDispatchPin(
            self.admission,
            self.lease,
            acquired,
            adapter,
            dispatch_generation,
            dispatch_request_sha256,
        );
        validateDispatchPinForIntentV1(
            pin,
            intent,
        ) catch @panic(
            "constructed dispatch pin does not match reserved intent",
        );
        self.dispatches[slot_index] = .{
            .state = .pinned,
            .allocation_generation = self.generation,
            .dispatch_generation = dispatch_generation,
            .adapter_context = adapter.context,
            .adapter_reserve_dispatch_intent_fn = adapter.reserve_dispatch_intent_fn,
            .adapter_abort_dispatch_intent_fn = adapter.abort_dispatch_intent_fn,
            .adapter_validate_terminal_fn = adapter.validate_terminal_fn,
            .adapter_confirm_settlement_fn = adapter.confirm_settlement_fn,
            .bank_permit = acquired.permit,
            .intent = intent,
            .pin = pin,
        };
        self.next_dispatch_generation += 1;
        return pin;
    }

    /// Consume one private Bank pin only after the exact bound adapter
    /// validates terminal queue evidence. After Bank release, the same
    /// private permit is presented to the adapter as settlement authority.
    /// Validation failure or a Bank conflict keeps the pin active; a failed
    /// settlement confirmation keeps the completed slot retryable without
    /// releasing the Bank pin twice.
    pub fn completeDispatchPin(
        self: *CoordinatorV1,
        pin: LeaseTreeDispatchPinV1,
        adapter: DispatchAdapterV1,
        terminal: DispatchTerminalEvidenceV1,
    ) Error!LeaseTreeDispatchCompletionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateLease(self.lease);
        try validateDispatchPinV1(pin);
        try validateDispatchTerminalV1(terminal);
        try validateDispatchTerminalForPinV1(terminal, pin);
        const slot_index = self.findDispatchSlot(pin) orelse
            return Error.InvalidDispatchPin;
        const slot = self.dispatches[slot_index];
        try validateBoundDispatchAdapter(slot, adapter);
        try self.validateLiveObjectSet();
        try self.validateLiveAdmissionStorage();
        if (slot.state == .settlement_pending) {
            const stored_terminal = slot.terminal orelse
                return Error.InvalidDispatchCompletion;
            if (!std.meta.eql(terminal, stored_terminal))
                return Error.InvalidDispatchTerminal;
            return self.confirmDispatchSettlementUnlocked(
                slot_index,
                pin,
                adapter,
                terminal,
            );
        }
        const bank_permit = slot.bank_permit orelse
            return Error.InvalidDispatchPin;
        if (!bankPermitForDispatchPinValid(bank_permit, pin))
            return Error.InvalidDispatchPin;
        try self.bank.validateLeasePin(bank_permit);
        try self.bank.validatePublicationSessionBinding(
            self.tree.parent,
            self.bound_request_epoch,
            self.bound_session_id,
            self.publication_sequence.*,
        );
        try self.bank.validateLeaseScopeSubtreeClaim(
            self.tree.*,
            self.scope,
            .{ .device_bytes = self.lease.materialized_bytes },
        );

        const source = try self.captureDispatchValidationSource();
        const callback_result = adapter.validate_terminal_fn(
            adapter.context,
            terminal,
        );
        self.restoreDispatchValidationSourceAfterCallback(source);
        callback_result catch
            return Error.InvalidDispatchTerminal;
        try self.validateDispatchValidationSource(source);
        const restored_slot_index =
            self.findDispatchSlot(pin) orelse
            return Error.InvalidDispatchPin;
        const restored_slot = self.dispatches[restored_slot_index];
        try validateBoundDispatchAdapter(restored_slot, adapter);
        const restored_bank_permit =
            restored_slot.bank_permit orelse
            return Error.InvalidDispatchPin;
        if (!bankPermitForDispatchPinValid(
            restored_bank_permit,
            pin,
        ))
            return Error.InvalidDispatchPin;
        try self.bank.validateLeasePin(restored_bank_permit);

        const released = try self.bank.releaseLeasePins(
            restored_bank_permit,
        );
        self.tree.* = released.tree;
        const completion = makeDispatchCompletion(
            pin,
            terminal,
            released,
            restored_bank_permit,
            dispatchPublicationBindingSha256V1(
                released.tree.parent,
                self.bound_request_epoch,
                self.bound_session_id,
                self.publication_sequence.*,
            ),
        );
        var settlement_slot = restored_slot;
        settlement_slot.state = .settlement_pending;
        settlement_slot.terminal = terminal;
        settlement_slot.completion = completion;
        settlement_slot.bank_completion = released.completion;
        self.dispatches[restored_slot_index] = settlement_slot;
        return self.confirmDispatchSettlementUnlocked(
            restored_slot_index,
            pin,
            adapter,
            terminal,
        );
    }

    fn confirmDispatchSettlementUnlocked(
        self: *CoordinatorV1,
        slot_index: usize,
        pin: LeaseTreeDispatchPinV1,
        adapter: DispatchAdapterV1,
        terminal: DispatchTerminalEvidenceV1,
    ) Error!LeaseTreeDispatchCompletionV1 {
        if (slot_index >= self.dispatches.len)
            return Error.InvalidDispatchPin;
        const slot = self.dispatches[slot_index];
        try validateBoundDispatchAdapter(slot, adapter);
        if (slot.state != .settlement_pending)
            return Error.InvalidDispatchCompletion;
        const stored_pin = slot.pin orelse
            return Error.InvalidDispatchPin;
        const stored_terminal = slot.terminal orelse
            return Error.InvalidDispatchCompletion;
        const completion = slot.completion orelse
            return Error.InvalidDispatchCompletion;
        const bank_permit = slot.bank_permit orelse
            return Error.InvalidDispatchPin;
        const bank_completion = slot.bank_completion orelse
            return Error.InvalidDispatchCompletion;
        if (!std.meta.eql(pin, stored_pin) or
            !std.meta.eql(terminal, stored_terminal))
            return Error.InvalidDispatchCompletion;
        try validateDispatchSettlementForPinV1(
            completion,
            pin,
            terminal,
            bank_permit,
            bank_completion,
        );

        const source = try self.captureDispatchValidationSource();
        const callback_result = adapter.confirm_settlement_fn(
            adapter.context,
            pin,
            terminal,
            completion,
            bank_permit,
            bank_completion,
        );
        self.restoreDispatchValidationSourceAfterCallback(source);
        callback_result catch
            return Error.InvalidDispatchCompletion;
        try self.validateDispatchValidationSource(source);
        const restored_slot_index =
            self.findDispatchSlot(pin) orelse
            return Error.InvalidDispatchPin;
        const restored_slot =
            self.dispatches[restored_slot_index];
        try validateBoundDispatchAdapter(restored_slot, adapter);
        const restored_terminal = restored_slot.terminal orelse
            return Error.InvalidDispatchCompletion;
        const restored_completion = restored_slot.completion orelse
            return Error.InvalidDispatchCompletion;
        const restored_permit = restored_slot.bank_permit orelse
            return Error.InvalidDispatchCompletion;
        const restored_bank_completion =
            restored_slot.bank_completion orelse
            return Error.InvalidDispatchCompletion;
        if (restored_slot.state != .settlement_pending or
            !std.meta.eql(restored_terminal, terminal) or
            !std.meta.eql(restored_completion, completion) or
            !std.meta.eql(restored_permit, bank_permit) or
            !std.meta.eql(
                restored_bank_completion,
                bank_completion,
            ))
            return Error.InvalidDispatchCompletion;
        self.dispatches[restored_slot_index] = .{};
        return completion;
    }

    /// Invoke one narrow reconciliation callback for an exact retained active
    /// dispatch pin. The target must still be in the pre-terminal `.pinned`
    /// phase and remain backed by its live private Bank pin. Terminal,
    /// completion, and Bank permit authority are never exposed.
    ///
    /// The callback runs under the coordinator mutex and must not re-enter the
    /// coordinator or Bank. Lock order is coordinator then adapter, matching
    /// the other allocation and dispatch callbacks.
    pub fn withActiveDispatchReconciliationBindingV1(
        self: *CoordinatorV1,
        lease: LeaseTreeDeviceAllocationLeaseV1,
        pin: LeaseTreeDispatchPinV1,
        binding: ActiveDispatchReconciliationBindingV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateLease(lease);
        try validateDispatchPinV1(pin);
        const slot_index = self.findDispatchSlot(pin) orelse
            return Error.InvalidDispatchPin;
        const slot = self.dispatches[slot_index];
        try validateBoundDispatchAdapter(
            slot,
            binding.dispatch_adapter,
        );
        if (slot.state != .pinned)
            return Error.InvalidDispatchReconciliationBinding;
        const retained_intent = slot.intent orelse
            return Error.InvalidDispatchReconciliationBinding;
        const retained_pin = slot.pin orelse
            return Error.InvalidDispatchReconciliationBinding;
        const bank_permit = slot.bank_permit orelse
            return Error.InvalidDispatchReconciliationBinding;
        if (!std.meta.eql(retained_pin, pin) or
            slot.terminal != null or
            slot.completion != null or
            slot.bank_completion != null)
            return Error.InvalidDispatchReconciliationBinding;
        try validateDispatchPinForIntentV1(
            retained_pin,
            retained_intent,
        );
        if (!bankPermitForDispatchPinValid(
            bank_permit,
            retained_pin,
        ))
            return Error.InvalidDispatchReconciliationBinding;
        try self.bank.validateLeasePin(bank_permit);
        try self.bank.validateAdditiveLeaseTree(self.tree.*);
        try self.bank.validatePublicationSessionBinding(
            self.tree.parent,
            self.bound_request_epoch,
            self.bound_session_id,
            self.publication_sequence.*,
        );
        try self.validateLiveObjectSet();
        try self.validateLiveAdmissionStorage();
        try self.bank.validateLeaseScopeSubtreeClaim(
            self.tree.*,
            self.scope,
            .{ .device_bytes = lease.materialized_bytes },
        );
        for (self.objects[0..@intCast(lease.allocation_count)]) |object|
            try self.bank.validateLeaseNode(self.tree.*, object.leaf);

        var retained_calls: [allocation.maximum_allocations]allocation.AllocationCallV1 =
            undefined;
        var retained_objects: [allocation.maximum_allocations]allocation.BackendObjectV1 =
            undefined;
        const count: usize = @intCast(lease.allocation_count);
        try self.copyLiveObjectsInOrder(
            retained_calls[0..count],
            retained_objects[0..count],
        );

        const source = try self.captureDispatchValidationSource();
        const callback_result = binding.reconcile_fn(
            binding.context,
            self.lease,
            retained_pin,
            retained_intent,
            self.object_set,
            retained_calls[0..count],
            retained_objects[0..count],
        );
        self.restoreDispatchValidationSourceAfterCallback(source);
        try self.validateDispatchValidationSource(source);
        callback_result catch |err| return switch (err) {
            error.InvalidReconciliationBinding => Error.InvalidDispatchReconciliationBinding,
            error.Busy => Error.DispatchReconciliationAdapterBusy,
            error.Unavailable => Error.DispatchReconciliationAdapterUnavailable,
        };
    }

    /// Invoke one narrow adapter callback with the coordinator's exact private
    /// live lease and object set. The coordinator remains locked across the
    /// callback, so dispatch acquisition and ordinary release cannot cross the
    /// binding boundary. No Bank permit or native-free authority is exposed.
    ///
    /// The callback must not re-enter this coordinator. Lock order is
    /// coordinator then adapter, matching allocation and dispatch callbacks.
    pub fn withQuiescedRetirementBindingV1(
        self: *CoordinatorV1,
        lease: LeaseTreeDeviceAllocationLeaseV1,
        adapter: RetirementBindingAdapterV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateLease(lease);
        if (self.activeDispatchCount() != 0)
            return Error.DispatchInFlight;
        try self.validateAdapter(adapter.allocation_adapter);
        try self.bank.validateAdditiveLeaseTree(self.tree.*);
        try self.bank.validatePublicationSession(
            self.tree.parent,
            self.request_epoch,
            self.session_id,
            self.publication_sequence.*,
        );
        try self.validateLiveObjectSet();
        try self.validateLiveAdmissionStorage();
        try self.bank.validateLeaseScopeSubtreeClaim(
            self.tree.*,
            self.scope,
            .{ .device_bytes = lease.materialized_bytes },
        );
        for (self.objects[0..@intCast(lease.allocation_count)]) |object|
            try self.bank.validateLeaseNode(self.tree.*, object.leaf);

        var retained_calls: [allocation.maximum_allocations]allocation.AllocationCallV1 =
            undefined;
        var retained_objects: [allocation.maximum_allocations]allocation.BackendObjectV1 =
            undefined;
        const count: usize = @intCast(self.lease.allocation_count);
        for (self.objects[0..count], 0..) |object, ordinal| {
            if (object.state != .live or
                object.ordinal != @as(u64, @intCast(ordinal)))
                return Error.InvalidRetirementBinding;
            retained_calls[ordinal] = object.call;
            retained_objects[ordinal] = object.object;
        }
        adapter.arm_fn(
            adapter.context,
            self.lease,
            self.object_set,
            retained_calls[0..count],
            retained_objects[0..count],
        ) catch |err| return switch (err) {
            error.InvalidRetirementBinding => Error.InvalidRetirementBinding,
            error.Busy => Error.RetirementAdapterBusy,
            error.Unavailable => Error.RetirementAdapterUnavailable,
        };
    }

    /// Reclaim one complete exclusive scope. All coordinator, adapter, object,
    /// node, scope-sum, and session checks happen before irreversible free
    /// authorization.
    pub fn release(
        self: *CoordinatorV1,
        lease: LeaseTreeDeviceAllocationLeaseV1,
        adapter: allocation.AdapterV1,
    ) Error!RecoveryOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateLease(lease);
        if (self.activeDispatchCount() != 0)
            return Error.DispatchInFlight;
        try self.validateAdapter(adapter);
        try self.bank.validateAdditiveLeaseTree(self.tree.*);
        try self.bank.validatePublicationSession(
            self.tree.parent,
            self.request_epoch,
            self.session_id,
            self.publication_sequence.*,
        );
        try self.validateLiveObjectSet();
        try self.validateLiveAdmissionStorage();
        const expected_claim: resource.Claim = .{
            .device_bytes = lease.materialized_bytes,
        };
        try self.bank.validateLeaseScopeSubtreeClaim(
            self.tree.*,
            self.scope,
            expected_claim,
        );
        for (self.objects[0..@intCast(lease.allocation_count)]) |object|
            try self.bank.validateLeaseNode(self.tree.*, object.leaf);

        const prepared =
            try self.bank.beginRetireSubtreeForSession(
                self.tree.*,
                self.scope,
                self.request_epoch,
                self.session_id,
                self.publication_sequence.*,
            );
        self.tree.* = prepared.tree;
        // These values were prevalidated against the same locked Bank state.
        // A mismatch is an internal invariant failure; cancel before exposing
        // any allocator-free authority.
        if (prepared.ticket.scope_index != self.scope.node_index or
            prepared.ticket.scope_generation != self.scope.generation or
            prepared.ticket.node_count != lease.allocation_count or
            !std.meta.eql(prepared.ticket.claim, expected_claim))
        {
            self.tree.* = self.bank.cancelRetire(
                prepared.ticket,
            ) catch @panic(
                "valid device LeaseTree retire ticket could not cancel",
            );
            return Error.InvalidExclusiveScope;
        }
        for (self.objects[0..@intCast(lease.allocation_count)]) |object| {
            self.bank.validateLeaseNode(
                prepared.tree,
                object.leaf,
            ) catch {
                self.tree.* = self.bank.cancelRetire(
                    prepared.ticket,
                ) catch @panic(
                    "valid device LeaseTree retire ticket could not cancel",
                );
                return Error.InvalidExclusiveScope;
            };
        }
        const authorized = self.bank.authorizeFree(
            prepared.ticket,
        ) catch @panic(
            "private prevalidated device LeaseTree ticket could not authorize",
        );
        self.tree.* = authorized.tree;
        self.permit = authorized.permit;
        self.target_outcome = .released;
        self.target_reason = .normal_release;
        self.state = .free_authorized;
        const source = try self.captureFreeSource(
            authorized.tree,
            authorized.permit,
            .released,
            .normal_release,
        );
        try self.validateFreeSource(source);
        return self.freeAuthorizedOrRecover(adapter, source);
    }

    pub fn retryRecovery(
        self: *CoordinatorV1,
        recovery: LeaseTreeAllocationRecoveryV1,
        adapter: allocation.AdapterV1,
    ) Error!RecoveryOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.validateRecovery(recovery);
        try self.validateAdapter(adapter);
        return switch (self.state) {
            .rollback_required => blk: {
                const source =
                    try self.captureRollbackSource(
                        self.admission,
                    );
                const result = try self.rollbackOrRecover(
                    adapter,
                    source,
                    self.target_outcome,
                    self.target_reason,
                );
                break :blk switch (result) {
                    .terminal => |terminal| .{ .terminal = terminal },
                    .recovery_required => |next| .{ .recovery_required = next },
                    .active => unreachable,
                };
            },
            .free_authorized, .settlement_required => blk: {
                const source = try self.captureFreeSource(
                    self.tree.*,
                    self.permit orelse
                        return Error.InvalidTransition,
                    self.target_outcome,
                    self.target_reason,
                );
                break :blk try self.freeAuthorizedOrRecover(
                    adapter,
                    source,
                );
            },
            else => Error.InvalidTransition,
        };
    }

    fn rollbackOrRecover(
        self: *CoordinatorV1,
        adapter: allocation.AdapterV1,
        source: RollbackSourceV1,
        outcome: allocation.TerminalOutcomeV1,
        reason: allocation.TerminalReasonV1,
    ) Error!MaterializeOutcomeV1 {
        var working = source;
        self.target_outcome = outcome;
        self.target_reason = reason;
        self.restoreRollbackSourceAfterCallback(working);
        if (self.bank != self.bound_bank) {
            self.state = .rollback_required;
            return .{
                .recovery_required = try self.refreshRecoveryAfterBankDrift(
                    .rollback_reserved,
                    self.bank,
                ),
            };
        }
        try self.validateRollbackSource(working);
        var free_failed = false;
        var object_index = working.allocation_count;
        while (object_index != 0) {
            object_index -= 1;
            const object = &working.objects[object_index];
            if (object.state != .live) continue;
            adapter.free_fn(
                adapter.context,
                object.object,
            ) catch {
                free_failed = true;
                self.restoreRollbackSourceAfterCallback(
                    working,
                );
                continue;
            };
            object.state = .reserved;
            object.object = .{};
            self.restoreRollbackSourceAfterCallback(working);
        }
        self.restoreRollbackSourceAfterCallback(working);
        self.target_outcome = outcome;
        self.target_reason = reason;
        if (self.bank != self.bound_bank) {
            self.state = .rollback_required;
            return .{
                .recovery_required = try self.refreshRecoveryAfterBankDrift(
                    .rollback_reserved,
                    self.bank,
                ),
            };
        }
        try self.validateRollbackSource(working);
        if (free_failed) {
            self.state = .rollback_required;
            return .{
                .recovery_required = try self.refreshRecovery(
                    .rollback_reserved,
                ),
            };
        }
        const tree_after =
            self.bank.abortAllocationsAfterFree(
                source.batch,
            ) catch {
                self.state = .rollback_required;
                return .{
                    .recovery_required = try self.refreshRecovery(
                        .rollback_reserved,
                    ),
                };
            };
        self.tree.* = tree_after;
        const terminal = self.makeTerminal(
            working.admission,
            zero_digest,
            zero_digest,
            outcome,
            reason,
        );
        self.clearLifecycle();
        return .{ .terminal = terminal };
    }

    fn freeAuthorizedOrRecover(
        self: *CoordinatorV1,
        adapter: allocation.AdapterV1,
        source: FreeSourceV1,
    ) Error!RecoveryOutcomeV1 {
        var working = source;
        try self.validateFreeSource(working);
        if (self.state != .settlement_required) {
            var free_failed = false;
            var object_index = working.allocation_count;
            while (object_index != 0) {
                object_index -= 1;
                const object = &working.objects[object_index];
                if (object.state != .live) continue;
                adapter.free_fn(
                    adapter.context,
                    object.object,
                ) catch {
                    free_failed = true;
                    self.restoreFreeSourceAfterCallback(
                        working,
                    );
                    continue;
                };
                object.state = .reserved;
                object.object = .{};
                self.restoreFreeSourceAfterCallback(working);
            }
            self.restoreFreeSourceAfterCallback(working);
            if (self.bank != self.bound_bank) {
                const phase: RecoveryPhaseV1 =
                    if (free_failed)
                        .free_authorized
                    else
                        .settlement_required;
                self.state = switch (phase) {
                    .free_authorized => .free_authorized,
                    .settlement_required => .settlement_required,
                    else => unreachable,
                };
                return .{
                    .recovery_required = try self.refreshRecoveryAfterBankDrift(
                        phase,
                        self.bank,
                    ),
                };
            }
            try self.validateFreeSource(working);
            if (free_failed) {
                self.state = .free_authorized;
                return .{
                    .recovery_required = try self.refreshRecovery(
                        .free_authorized,
                    ),
                };
            }
            self.state = .settlement_required;
        }
        self.restoreFreeSource(working);
        try self.validateFreeSource(working);
        const tree_after =
            self.bank.commitFreeAfterAllocatorFree(
                working.permit,
            ) catch {
                return .{
                    .recovery_required = try self.refreshRecovery(
                        .settlement_required,
                    ),
                };
            };
        self.tree.* = tree_after;
        const terminal = self.makeTerminal(
            working.admission,
            working.lease.lease_sha256,
            working.object_set.object_set_sha256,
            working.target_outcome,
            working.target_reason,
        );
        self.clearLifecycle();
        return .{ .terminal = terminal };
    }

    fn validateAddress(self: *const CoordinatorV1) Error!void {
        if (!self.initialized or self.self_address == 0 or
            self.self_address != @intFromPtr(self) or
            self.epoch == 0 or self.request_epoch == 0 or
            self.session_id == 0 or self.objects.len == 0 or
            self.epoch != self.bound_epoch or
            self.bank != self.bound_bank or
            self.tree != self.bound_tree or
            !std.meta.eql(self.scope, self.bound_scope) or
            self.request_epoch != self.bound_request_epoch or
            self.session_id != self.bound_session_id or
            self.publication_sequence !=
                self.bound_publication_sequence or
            @intFromPtr(self.objects.ptr) !=
                self.bound_objects_address or
            self.objects.len != self.bound_objects_len or
            @intFromPtr(self.dispatches.ptr) !=
                self.bound_dispatches_address or
            self.dispatches.len != self.bound_dispatches_len or
            self.dispatches.len > maximum_dispatches)
            return Error.InvalidCoordinator;
    }

    fn validateAdapter(
        self: *CoordinatorV1,
        adapter: allocation.AdapterV1,
    ) Error!void {
        try allocation.validateAuthorityV1(adapter.authority);
        const context = self.adapter_context orelse
            return Error.InvalidAdapter;
        const quote_fn = self.adapter_quote_fn orelse
            return Error.InvalidAdapter;
        const allocate_fn = self.adapter_allocate_fn orelse
            return Error.InvalidAdapter;
        const free_fn = self.adapter_free_fn orelse
            return Error.InvalidAdapter;
        if (!std.meta.eql(adapter.authority, self.authority) or
            adapter.context != context or
            @intFromPtr(adapter.quote_fn) != @intFromPtr(quote_fn) or
            @intFromPtr(adapter.allocate_fn) !=
                @intFromPtr(allocate_fn) or
            @intFromPtr(adapter.free_fn) != @intFromPtr(free_fn))
            return Error.InvalidAdapter;
    }

    fn captureBindings(
        self: *CoordinatorV1,
    ) Error!CoordinatorBindingsV1 {
        try self.validateAddress();
        return .{
            .epoch = self.epoch,
            .bank = self.bank,
            .tree = self.tree,
            .scope = self.scope,
            .request_epoch = self.request_epoch,
            .session_id = self.session_id,
            .publication_sequence = self.publication_sequence,
            .publication_sequence_value = self.publication_sequence.*,
            .objects = self.objects,
            .dispatches = self.dispatches,
            .next_generation = self.next_generation,
            .next_dispatch_generation = self.next_dispatch_generation,
            .generation = self.generation,
            .recovery_generation = self.recovery_generation,
            .adapter = .{
                .context = self.adapter_context orelse
                    return Error.InvalidAdapter,
                .authority = self.authority,
                .quote_fn = self.adapter_quote_fn orelse
                    return Error.InvalidAdapter,
                .allocate_fn = self.adapter_allocate_fn orelse
                    return Error.InvalidAdapter,
                .free_fn = self.adapter_free_fn orelse
                    return Error.InvalidAdapter,
            },
        };
    }

    fn captureRollbackSource(
        self: *CoordinatorV1,
        admission: LeaseTreeAllocationAdmissionV1,
    ) Error!RollbackSourceV1 {
        var source: RollbackSourceV1 = .{
            .bindings = try self.captureBindings(),
            .authority = self.authority,
            .request = self.request,
            .admission = admission,
            .batch = self.batch orelse
                return Error.InvalidTransition,
            .allocation_count = self.objects.len,
            .objects = undefined,
            .dispatch_count = self.dispatches.len,
            .dispatches = undefined,
        };
        for (self.objects, 0..) |object, ordinal|
            source.objects[ordinal] = object;
        for (self.dispatches, 0..) |dispatch, ordinal|
            source.dispatches[ordinal] = dispatch;
        return source;
    }

    fn captureFreeSource(
        self: *CoordinatorV1,
        tree: resource.LeaseTreeV1,
        permit: resource.LeaseFreePermitV1,
        outcome: allocation.TerminalOutcomeV1,
        reason: allocation.TerminalReasonV1,
    ) Error!FreeSourceV1 {
        var source: FreeSourceV1 = .{
            .bindings = try self.captureBindings(),
            .authority = self.authority,
            .request = self.request,
            .admission = self.admission,
            .lease = self.lease,
            .object_set = self.object_set,
            .tree = tree,
            .permit = permit,
            .target_outcome = outcome,
            .target_reason = reason,
            .allocation_count = self.objects.len,
            .objects = undefined,
            .dispatch_count = self.dispatches.len,
            .dispatches = undefined,
        };
        for (self.objects, 0..) |object, ordinal|
            source.objects[ordinal] = object;
        for (self.dispatches, 0..) |dispatch, ordinal|
            source.dispatches[ordinal] = dispatch;
        return source;
    }

    fn captureDispatchValidationSource(
        self: *CoordinatorV1,
    ) Error!DispatchValidationSourceV1 {
        if (self.objects.len > allocation.maximum_allocations or
            self.dispatches.len > maximum_dispatches)
            return Error.InvalidCoordinator;
        var source: DispatchValidationSourceV1 = .{
            .bindings = try self.captureBindings(),
            .tree = self.tree.*,
            .authority = self.authority,
            .request = self.request,
            .admission = self.admission,
            .lease = self.lease,
            .object_set = self.object_set,
            .allocation_count = self.objects.len,
            .objects = undefined,
            .dispatch_count = self.dispatches.len,
            .dispatches = undefined,
        };
        for (self.objects, 0..) |object, ordinal|
            source.objects[ordinal] = object;
        for (self.dispatches, 0..) |dispatch, ordinal|
            source.dispatches[ordinal] = dispatch;
        return source;
    }

    fn restoreDispatchValidationSource(
        self: *CoordinatorV1,
        source: DispatchValidationSourceV1,
    ) void {
        source.bindings.tree.* = source.tree;
        for (
            source.bindings.objects,
            0..,
        ) |*object, ordinal|
            object.* = source.objects[ordinal];
        for (
            source.bindings.dispatches,
            0..,
        ) |*dispatch, ordinal|
            dispatch.* = source.dispatches[ordinal];
        self.restoreBindings(source.bindings);
        self.state = .live;
        self.authority = source.authority;
        self.request = source.request;
        self.admission = source.admission;
        self.batch = null;
        self.object_set = source.object_set;
        self.lease = source.lease;
        self.permit = null;
        self.target_outcome = .cancelled;
        self.target_reason = .explicit_cancellation;
        self.recovery_generation = 0;
    }

    fn restoreDispatchValidationSourceAfterCallback(
        self: *CoordinatorV1,
        source: DispatchValidationSourceV1,
    ) void {
        const observed_bank = self.bank;
        const bank_drifted =
            observed_bank != source.bindings.bank;
        self.restoreDispatchValidationSource(source);
        if (bank_drifted) self.bank = observed_bank;
    }

    fn abortDispatchIntentAndValidateSource(
        self: *CoordinatorV1,
        source: DispatchValidationSourceV1,
        adapter: DispatchAdapterV1,
        intent: DispatchPinIntentV1,
    ) Error!void {
        const callback_result =
            adapter.abort_dispatch_intent_fn(
                adapter.context,
                intent,
            );
        self.restoreDispatchValidationSourceAfterCallback(source);
        try self.validateDispatchValidationSource(source);
        callback_result catch
            return Error.InvalidDispatchAdapter;
    }

    fn validateDispatchValidationSource(
        self: *CoordinatorV1,
        source: DispatchValidationSourceV1,
    ) Error!void {
        try self.validateAddress();
        if (source.allocation_count != self.objects.len or
            source.dispatch_count != self.dispatches.len or
            self.state != .live or
            !std.meta.eql(source.tree, self.tree.*) or
            !std.meta.eql(source.authority, self.authority) or
            !std.meta.eql(source.request, self.request) or
            !std.meta.eql(source.admission, self.admission) or
            !std.meta.eql(source.lease, self.lease) or
            !std.meta.eql(source.object_set, self.object_set))
            return Error.InvalidTransition;
        for (self.objects, 0..) |object, ordinal|
            if (!std.meta.eql(
                object,
                source.objects[ordinal],
            ))
                return Error.InvalidTransition;
        for (self.dispatches, 0..) |dispatch, ordinal| {
            if (!std.meta.eql(
                dispatch,
                source.dispatches[ordinal],
            ))
                return Error.InvalidTransition;
            switch (dispatch.state) {
                .free => if (!dispatchSlotCanonicalFree(dispatch))
                    return Error.InvalidTransition,
                .pinned => {
                    const dispatch_intent = dispatch.intent orelse
                        return Error.InvalidTransition;
                    const dispatch_pin = dispatch.pin orelse
                        return Error.InvalidTransition;
                    const dispatch_bank_permit =
                        dispatch.bank_permit orelse
                        return Error.InvalidTransition;
                    if (dispatch.terminal != null or
                        dispatch.completion != null or
                        dispatch.bank_completion != null)
                        return Error.InvalidTransition;
                    try validateDispatchPinForIntentV1(
                        dispatch_pin,
                        dispatch_intent,
                    );
                    if (!bankPermitForDispatchPinValid(
                        dispatch_bank_permit,
                        dispatch_pin,
                    ))
                        return Error.InvalidTransition;
                    try self.bank.validateLeasePin(
                        dispatch_bank_permit,
                    );
                },
                .settlement_pending => {
                    const dispatch_intent = dispatch.intent orelse
                        return Error.InvalidTransition;
                    const dispatch_pin = dispatch.pin orelse
                        return Error.InvalidTransition;
                    const dispatch_terminal =
                        dispatch.terminal orelse
                        return Error.InvalidTransition;
                    const dispatch_completion =
                        dispatch.completion orelse
                        return Error.InvalidTransition;
                    const dispatch_bank_permit =
                        dispatch.bank_permit orelse
                        return Error.InvalidTransition;
                    const dispatch_bank_completion =
                        dispatch.bank_completion orelse
                        return Error.InvalidTransition;
                    try validateDispatchPinForIntentV1(
                        dispatch_pin,
                        dispatch_intent,
                    );
                    try validateDispatchSettlementForPinV1(
                        dispatch_completion,
                        dispatch_pin,
                        dispatch_terminal,
                        dispatch_bank_permit,
                        dispatch_bank_completion,
                    );
                },
            }
        }
        try self.validateLease(source.lease);
        try self.validateLiveObjectSet();
        try self.validateLiveAdmissionStorage();
        try self.bank.validateLeaseScopeSubtreeClaim(
            source.tree,
            source.admission.scope,
            .{ .device_bytes = source.lease.materialized_bytes },
        );
        try self.bank.validateAdditiveLeaseTree(source.tree);
        try self.bank.validatePublicationSessionBinding(
            source.tree.parent,
            self.bound_request_epoch,
            self.bound_session_id,
            self.publication_sequence.*,
        );
    }

    fn validateRollbackSource(
        self: *CoordinatorV1,
        source: RollbackSourceV1,
    ) Error!void {
        try self.validateAddress();
        try self.validateAdapter(source.bindings.adapter);
        allocation.validateAuthorityV1(source.authority) catch
            return Error.InvalidTransition;
        validateAdmissionV1(source.admission) catch
            return Error.InvalidTransition;
        if (source.allocation_count != self.objects.len or
            source.dispatch_count != self.dispatches.len or
            source.allocation_count !=
                source.admission.allocation_count)
            return Error.InvalidTransition;
        for (self.dispatches, 0..) |dispatch, ordinal|
            if (!dispatchSlotCanonicalFree(dispatch) or
                !dispatchSlotCanonicalFree(
                    source.dispatches[ordinal],
                ) or
                !std.meta.eql(
                    dispatch,
                    source.dispatches[ordinal],
                ))
                return Error.InvalidTransition;
        var entries: [allocation.maximum_allocations]allocation.AllocationEntryV1 =
            undefined;
        var leaves: [allocation.maximum_allocations]resource.LeaseNodeV1 =
            undefined;
        for (
            source.objects[0..source.allocation_count],
            0..,
        ) |object, ordinal| {
            entries[ordinal] = object.entry;
            leaves[ordinal] = object.leaf;
        }
        const manifest = allocation.sealManifestV1(
            entries[0..source.allocation_count],
        ) catch return Error.InvalidTransition;
        if (!requestAdmissionBindingValid(
            source.request,
            source.admission,
            self.bound_request_epoch,
        ) or !digestEqual(
            source.authority.authority_sha256,
            source.admission.authority_sha256,
        ) or !admissionBatchBindingValid(
            source.admission,
            source.batch,
        ) or !digestEqual(
            manifest.manifest_sha256,
            source.request.allocation_manifest_sha256,
        ) or !digestEqual(
            allocationLeafSetSha256V1(
                leaves[0..source.allocation_count],
            ),
            source.admission.allocation_leaf_set_sha256,
        ) or !std.meta.eql(
            source.admission.reservation_tree,
            self.tree.*,
        ) or !std.meta.eql(
            source.admission.scope,
            self.bound_scope,
        ) or !admittedLeafBindingsValid(
            source.admission,
            source.objects[0..source.allocation_count],
        ) or
            source.batch.request_epoch !=
                self.bound_request_epoch or
            source.batch.session_id != self.bound_session_id or
            source.batch.sequence !=
                self.publication_sequence.*)
            return Error.InvalidTransition;
        for (leaves[0..source.allocation_count]) |leaf|
            self.bank.validateLeaseNode(
                source.admission.reservation_tree,
                leaf,
            ) catch return Error.InvalidTransition;
        self.bank.validateAdditiveLeaseTree(
            source.admission.reservation_tree,
        ) catch return Error.InvalidTransition;
        self.bank.validateLeaseAllocationBatch(
            source.batch,
        ) catch return Error.InvalidTransition;
        self.bank.validatePublicationSessionBinding(
            source.batch.parent,
            self.bound_request_epoch,
            self.bound_session_id,
            self.publication_sequence.*,
        ) catch return Error.InvalidTransition;
    }

    fn restoreBindings(
        self: *CoordinatorV1,
        bindings: CoordinatorBindingsV1,
    ) void {
        self.initialized = true;
        self.self_address = @intFromPtr(self);
        self.epoch = bindings.epoch;
        self.bound_epoch = bindings.epoch;
        self.bank = bindings.bank;
        self.bound_bank = bindings.bank;
        self.tree = bindings.tree;
        self.bound_tree = bindings.tree;
        self.scope = bindings.scope;
        self.bound_scope = bindings.scope;
        self.request_epoch = bindings.request_epoch;
        self.bound_request_epoch = bindings.request_epoch;
        self.session_id = bindings.session_id;
        self.bound_session_id = bindings.session_id;
        self.publication_sequence =
            bindings.publication_sequence;
        self.bound_publication_sequence =
            bindings.publication_sequence;
        bindings.publication_sequence.* =
            bindings.publication_sequence_value;
        self.objects = bindings.objects;
        self.bound_objects_address =
            @intFromPtr(bindings.objects.ptr);
        self.bound_objects_len = bindings.objects.len;
        self.dispatches = bindings.dispatches;
        self.bound_dispatches_address =
            @intFromPtr(bindings.dispatches.ptr);
        self.bound_dispatches_len =
            bindings.dispatches.len;
        self.next_generation = bindings.next_generation;
        self.next_dispatch_generation =
            bindings.next_dispatch_generation;
        self.generation = bindings.generation;
        self.recovery_generation =
            bindings.recovery_generation;
        self.adapter_context = bindings.adapter.context;
        self.adapter_quote_fn = bindings.adapter.quote_fn;
        self.adapter_allocate_fn =
            bindings.adapter.allocate_fn;
        self.adapter_free_fn = bindings.adapter.free_fn;
    }

    fn restoreRollbackSource(
        self: *CoordinatorV1,
        source: RollbackSourceV1,
    ) void {
        source.bindings.tree.* =
            source.admission.reservation_tree;
        for (
            source.bindings.objects,
            0..,
        ) |*object, ordinal|
            object.* = source.objects[ordinal];
        for (
            source.bindings.dispatches,
            0..,
        ) |*dispatch, ordinal|
            dispatch.* = source.dispatches[ordinal];
        self.restoreBindings(source.bindings);
        self.authority = source.authority;
        self.request = source.request;
        self.admission = source.admission;
        self.batch = source.batch;
    }

    fn restoreRollbackSourceAfterCallback(
        self: *CoordinatorV1,
        source: RollbackSourceV1,
    ) void {
        const observed_bank = self.bank;
        const bank_drifted =
            observed_bank != source.bindings.bank;
        self.restoreRollbackSource(source);
        if (bank_drifted) self.bank = observed_bank;
    }

    fn validateFreeSource(
        self: *CoordinatorV1,
        source: FreeSourceV1,
    ) Error!void {
        try self.validateAddress();
        try self.validateAdapter(source.bindings.adapter);
        allocation.validateAuthorityV1(source.authority) catch
            return Error.InvalidTransition;
        validateAdmissionV1(source.admission) catch
            return Error.InvalidTransition;
        validateLeaseV1(source.lease) catch
            return Error.InvalidTransition;
        if (source.allocation_count != self.objects.len or
            source.dispatch_count != self.dispatches.len or
            source.allocation_count !=
                source.admission.allocation_count)
            return Error.InvalidTransition;
        for (self.dispatches, 0..) |dispatch, ordinal|
            if (!dispatchSlotCanonicalFree(dispatch) or
                !dispatchSlotCanonicalFree(
                    source.dispatches[ordinal],
                ) or
                !std.meta.eql(
                    dispatch,
                    source.dispatches[ordinal],
                ))
                return Error.InvalidTransition;
        var entries: [allocation.maximum_allocations]allocation.AllocationEntryV1 =
            undefined;
        var leaves: [allocation.maximum_allocations]resource.LeaseNodeV1 =
            undefined;
        for (
            source.objects[0..source.allocation_count],
            0..,
        ) |object, ordinal| {
            entries[ordinal] = object.entry;
            leaves[ordinal] = object.leaf;
        }
        const manifest = allocation.sealManifestV1(
            entries[0..source.allocation_count],
        ) catch return Error.InvalidTransition;
        if (!requestAdmissionBindingValid(
            source.request,
            source.admission,
            self.bound_request_epoch,
        ) or !admissionLeaseBindingValid(
            source.admission,
            source.lease,
        ) or !digestEqual(
            source.authority.authority_sha256,
            source.admission.authority_sha256,
        ) or !digestEqual(
            source.lease.backend_object_set_sha256,
            source.object_set.object_set_sha256,
        ) or !digestEqual(
            manifest.manifest_sha256,
            source.request.allocation_manifest_sha256,
        ) or !digestEqual(
            allocationLeafSetSha256V1(
                leaves[0..source.allocation_count],
            ),
            source.admission.allocation_leaf_set_sha256,
        ) or !admittedLeafBindingsValid(
            source.admission,
            source.objects[0..source.allocation_count],
        ) or !terminalPairValid(
            source.target_outcome,
            source.target_reason,
        ) or source.target_outcome != .released or
            source.target_reason != .normal_release or
            !freePermitBindingValid(
                source.permit,
                source.tree,
                source.admission,
                source.lease,
                self.bound_scope,
                self.bound_request_epoch,
                self.bound_session_id,
                self.publication_sequence.*,
            ) or !std.meta.eql(source.tree, self.tree.*))
            return Error.InvalidTransition;
        for (leaves[0..source.allocation_count]) |leaf|
            self.bank.validateLeaseNode(
                source.tree,
                leaf,
            ) catch return Error.InvalidTransition;
        self.bank.validateAdditiveLeaseTree(
            source.tree,
        ) catch return Error.InvalidTransition;
        self.bank.validateLeaseFreePermit(
            source.permit,
        ) catch return Error.InvalidTransition;
        self.bank.validatePublicationSessionBinding(
            source.permit.parent,
            self.bound_request_epoch,
            self.bound_session_id,
            self.publication_sequence.*,
        ) catch return Error.InvalidTransition;
    }

    fn restoreFreeSource(
        self: *CoordinatorV1,
        source: FreeSourceV1,
    ) void {
        source.bindings.tree.* = source.tree;
        for (
            source.bindings.objects,
            0..,
        ) |*object, ordinal|
            object.* = source.objects[ordinal];
        for (
            source.bindings.dispatches,
            0..,
        ) |*dispatch, ordinal|
            dispatch.* = source.dispatches[ordinal];
        self.restoreBindings(source.bindings);
        self.authority = source.authority;
        self.request = source.request;
        self.admission = source.admission;
        self.lease = source.lease;
        self.object_set = source.object_set;
        self.permit = source.permit;
        self.target_outcome = source.target_outcome;
        self.target_reason = source.target_reason;
    }

    fn restoreFreeSourceAfterCallback(
        self: *CoordinatorV1,
        source: FreeSourceV1,
    ) void {
        const observed_bank = self.bank;
        const bank_drifted =
            observed_bank != source.bindings.bank;
        self.restoreFreeSource(source);
        if (bank_drifted) self.bank = observed_bank;
    }

    fn validateRecoverySource(
        self: *CoordinatorV1,
        phase: RecoveryPhaseV1,
    ) Error!void {
        switch (phase) {
            .rollback_reserved => try self.validateRollbackSource(
                try self.captureRollbackSource(
                    self.admission,
                ),
            ),
            .free_authorized, .settlement_required => try self.validateFreeSource(
                try self.captureFreeSource(
                    self.tree.*,
                    self.permit orelse
                        return Error.InvalidTransition,
                    self.target_outcome,
                    self.target_reason,
                ),
            ),
            _ => return Error.InvalidTransition,
        }
    }

    fn validateAdmission(
        self: *CoordinatorV1,
        admission: LeaseTreeAllocationAdmissionV1,
        state: CoordinatorStateV1,
    ) Error!void {
        try self.validateAddress();
        validateAdmissionV1(admission) catch
            return Error.InvalidTreeAdmission;
        if (self.state != state or
            !std.meta.eql(admission, self.admission))
            return Error.InvalidTransition;
        if (!requestAdmissionBindingValid(
            self.request,
            self.admission,
            self.bound_request_epoch,
        ))
            return Error.InvalidTransition;
        allocation.validateAuthorityV1(self.authority) catch
            return Error.InvalidTransition;
        if (!digestEqual(
            self.authority.authority_sha256,
            self.admission.authority_sha256,
        ))
            return Error.InvalidTransition;
        const batch = self.batch orelse
            return Error.InvalidTransition;
        self.bank.validateLeaseAllocationBatch(batch) catch
            return Error.InvalidTransition;
        if (!admissionBatchBindingValid(
            self.admission,
            batch,
        ) or !std.meta.eql(
            self.admission.reservation_tree,
            self.tree.*,
        ) or !self.reservedAdmissionStorageValid() or
            !admittedLeafBindingsValid(
                self.admission,
                self.objects,
            ))
            return Error.InvalidTransition;
    }

    fn validateLease(
        self: *CoordinatorV1,
        lease: LeaseTreeDeviceAllocationLeaseV1,
    ) Error!void {
        try self.validateAddress();
        validateLeaseV1(lease) catch
            return Error.InvalidTreeLease;
        if (self.state != .live or
            !std.meta.eql(lease, self.lease))
            return Error.InvalidTransition;
        validateAdmissionV1(self.admission) catch
            return Error.InvalidTransition;
        allocation.validateAuthorityV1(self.authority) catch
            return Error.InvalidTransition;
        if (!requestAdmissionBindingValid(
            self.request,
            self.admission,
            self.bound_request_epoch,
        ) or !admissionLeaseBindingValid(
            self.admission,
            self.lease,
        ) or !digestEqual(
            self.authority.authority_sha256,
            self.admission.authority_sha256,
        ))
            return Error.InvalidTransition;
    }

    fn validateRecovery(
        self: *CoordinatorV1,
        recovery: LeaseTreeAllocationRecoveryV1,
    ) Error!void {
        try self.validateAddress();
        validateRecoveryV1(recovery) catch
            return Error.InvalidTreeRecovery;
        const phase: RecoveryPhaseV1 = switch (self.state) {
            .rollback_required => .rollback_reserved,
            .free_authorized => .free_authorized,
            .settlement_required => .settlement_required,
            else => return Error.InvalidTransition,
        };
        if (recovery.phase != phase or
            recovery.recovery_generation !=
                self.recovery_generation or
            !std.meta.eql(recovery, self.recovery))
            return Error.InvalidTransition;
        validateAdmissionV1(self.admission) catch
            return Error.InvalidTransition;
        allocation.validateAuthorityV1(self.authority) catch
            return Error.InvalidTransition;
        if (!requestAdmissionBindingValid(
            self.request,
            self.admission,
            self.bound_request_epoch,
        ) or !digestEqual(
            self.authority.authority_sha256,
            self.admission.authority_sha256,
        ) or !self.recoveryStorageValid(phase))
            return Error.InvalidTransition;
        self.validateRecoverySource(phase) catch
            return Error.InvalidTransition;
        self.bank.validateAdditiveLeaseTree(self.tree.*) catch
            return Error.InvalidTransition;
        self.bank.validatePublicationSessionBinding(
            self.tree.parent,
            self.bound_request_epoch,
            self.bound_session_id,
            self.publication_sequence.*,
        ) catch return Error.InvalidTransition;
        switch (phase) {
            .rollback_reserved => {
                const batch = self.batch orelse
                    return Error.InvalidTransition;
                self.bank.validateLeaseAllocationBatch(batch) catch
                    return Error.InvalidTransition;
            },
            .free_authorized, .settlement_required => {
                const permit = self.permit orelse
                    return Error.InvalidTransition;
                self.bank.validateLeaseFreePermit(permit) catch
                    return Error.InvalidTransition;
            },
            _ => return Error.InvalidTransition,
        }
        if (!std.meta.eql(
            recovery,
            self.makeRecoverySnapshot(
                phase,
                recovery.recovery_generation,
            ),
        ))
            return Error.InvalidTransition;
    }

    fn validateLiveObjectSet(self: *CoordinatorV1) Error!void {
        const count: usize = @intCast(self.lease.allocation_count);
        var calls: [allocation.maximum_allocations]allocation.AllocationCallV1 =
            undefined;
        var objects: [allocation.maximum_allocations]allocation.BackendObjectV1 =
            undefined;
        try self.copyLiveObjectsInOrder(
            calls[0..count],
            objects[0..count],
        );
        try allocation.validateObjectSetForAdmissionRootV1(
            self.object_set,
            self.admission.admission_sha256,
            self.authority.authority_sha256,
            self.admission.allocation_count,
            self.admission.total_device_bytes,
            calls[0..count],
            objects[0..count],
        );
    }

    fn validateLiveAdmissionStorage(
        self: *CoordinatorV1,
    ) Error!void {
        if (self.admission.allocation_count !=
            self.objects.len)
            return Error.InvalidTransition;
        var entries: [allocation.maximum_allocations]allocation.AllocationEntryV1 =
            undefined;
        var leaves: [allocation.maximum_allocations]resource.LeaseNodeV1 =
            undefined;
        for (self.objects, 0..) |object, ordinal| {
            if (object.state != .live or
                object.coordinator_generation !=
                    self.generation or
                object.ordinal != ordinal)
                return Error.InvalidTransition;
            self.bank.validateLeaseNode(
                self.tree.*,
                object.leaf,
            ) catch return Error.InvalidTransition;
            entries[ordinal] = object.entry;
            leaves[ordinal] = object.leaf;
        }
        const manifest = allocation.sealManifestV1(
            entries[0..self.objects.len],
        ) catch return Error.InvalidTransition;
        if (!digestEqual(
            manifest.manifest_sha256,
            self.request.allocation_manifest_sha256,
        ) or !digestEqual(
            allocationLeafSetSha256V1(
                leaves[0..self.objects.len],
            ),
            self.admission.allocation_leaf_set_sha256,
        ) or !admittedLeafBindingsValid(
            self.admission,
            self.objects,
        ))
            return Error.InvalidTransition;
    }

    fn copyLiveObjectsInOrder(
        self: *CoordinatorV1,
        out_calls: []allocation.AllocationCallV1,
        out_objects: []allocation.BackendObjectV1,
    ) Error!void {
        if (out_calls.len != out_objects.len or
            out_calls.len != self.admission.allocation_count)
            return Error.InvalidConfiguration;
        for (out_objects, 0..) |*target, ordinal| {
            const object = self.objects[ordinal];
            if (object.state != .live or
                object.coordinator_generation != self.generation or
                object.ordinal != ordinal)
                return Error.InvalidTransition;
            out_calls[ordinal] = object.call;
            target.* = object.object;
        }
        for (self.objects[out_objects.len..]) |object|
            if (object.state != .free)
                return Error.InvalidTransition;
    }

    fn hasDuplicateObject(
        self: *CoordinatorV1,
        current_ordinal: u64,
        candidate: allocation.BackendObjectV1,
    ) bool {
        for (self.objects[0..@intCast(current_ordinal)]) |prior| {
            if (prior.state == .live and
                prior.object.backend_object_generation ==
                    candidate.backend_object_generation and
                digestEqual(
                    prior.object.backend_object_sha256,
                    candidate.backend_object_sha256,
                ))
                return true;
        }
        return false;
    }

    fn liveObjectCount(self: *CoordinatorV1) usize {
        var count: usize = 0;
        for (self.objects) |object|
            if (object.state == .live) {
                count += 1;
            };
        return count;
    }

    fn activeDispatchCount(self: *const CoordinatorV1) usize {
        var count: usize = 0;
        for (self.dispatches) |dispatch| switch (dispatch.state) {
            .free => {},
            .pinned, .settlement_pending => count += 1,
        };
        return count;
    }

    fn findDispatchSlot(
        self: *const CoordinatorV1,
        pin: LeaseTreeDispatchPinV1,
    ) ?usize {
        for (self.dispatches, 0..) |dispatch, index| {
            const dispatch_pin = dispatch.pin orelse continue;
            if (dispatch.state != .free and
                dispatch.allocation_generation ==
                    pin.allocation_generation and
                dispatch.dispatch_generation ==
                    pin.dispatch_generation and
                std.meta.eql(dispatch_pin, pin))
                return index;
        }
        return null;
    }

    fn recoveryStorageValid(
        self: *const CoordinatorV1,
        phase: RecoveryPhaseV1,
    ) bool {
        if (self.admission.allocation_count != self.objects.len)
            return false;
        for (self.objects, 0..) |object, ordinal| {
            if (object.coordinator_generation != self.generation or
                object.ordinal != ordinal)
                return false;
            switch (phase) {
                .rollback_reserved, .free_authorized => {
                    if (object.state != .reserved and
                        object.state != .live)
                        return false;
                },
                .settlement_required => {
                    if (object.state != .reserved)
                        return false;
                },
                _ => return false,
            }
            if (object.state != .live) {
                if (!std.meta.eql(
                    object.object,
                    allocation.BackendObjectV1{},
                ))
                    return false;
                continue;
            }
            allocation.validateAllocationCallV1(
                object.call,
            ) catch return false;
            if (object.call.ordinal != ordinal or
                !digestEqual(
                    object.call.authority_sha256,
                    self.authority.authority_sha256,
                ) or
                !digestEqual(
                    object.call.admission_sha256,
                    self.admission.admission_sha256,
                ) or
                !digestEqual(
                    object.call.binding_sha256,
                    object.entry.binding_sha256,
                ) or
                object.call.requested_bytes !=
                    object.entry.requested_bytes or
                object.call.charged_bytes !=
                    object.entry.charged_bytes or
                !digestEqual(
                    object.call.quote_sha256,
                    object.entry.quote_sha256,
                ))
                return false;
            for (self.objects[0..ordinal]) |prior|
                if (prior.state == .live and
                    prior.object.backend_object_generation ==
                        object.object.backend_object_generation and
                    digestEqual(
                        prior.object.backend_object_sha256,
                        object.object.backend_object_sha256,
                    ))
                    return false;
        }
        return true;
    }

    fn reservedAdmissionStorageValid(
        self: *CoordinatorV1,
    ) bool {
        if (self.admission.allocation_count != self.objects.len)
            return false;
        var entries: [allocation.maximum_allocations]allocation.AllocationEntryV1 =
            undefined;
        var leaves: [allocation.maximum_allocations]resource.LeaseNodeV1 =
            undefined;
        for (self.objects, 0..) |object, ordinal| {
            if (object.state != .reserved or
                object.coordinator_generation != self.generation or
                object.ordinal != ordinal)
                return false;
            self.bank.validateLeaseNode(
                self.tree.*,
                object.leaf,
            ) catch return false;
            entries[ordinal] = object.entry;
            leaves[ordinal] = object.leaf;
        }
        const manifest = allocation.sealManifestV1(
            entries[0..self.objects.len],
        ) catch return false;
        return digestEqual(
            manifest.manifest_sha256,
            self.request.allocation_manifest_sha256,
        ) and digestEqual(
            allocationLeafSetSha256V1(
                leaves[0..self.objects.len],
            ),
            self.admission.allocation_leaf_set_sha256,
        );
    }

    fn refreshRecovery(
        self: *CoordinatorV1,
        phase: RecoveryPhaseV1,
    ) Error!LeaseTreeAllocationRecoveryV1 {
        if (!self.recoveryStorageValid(phase))
            return Error.InvalidCoordinator;
        try self.validateRecoverySource(phase);
        self.recovery_generation =
            nextRecoveryGeneration(self.recovery_generation);
        const result = self.makeRecoverySnapshot(
            phase,
            self.recovery_generation,
        );
        self.recovery = result;
        return result;
    }

    fn refreshRecoveryAfterBankDrift(
        self: *CoordinatorV1,
        phase: RecoveryPhaseV1,
        drifted_bank: *resource.Bank,
    ) Error!LeaseTreeAllocationRecoveryV1 {
        self.bank = self.bound_bank;
        defer self.bank = drifted_bank;
        return self.refreshRecovery(phase);
    }

    fn makeRecoverySnapshot(
        self: *CoordinatorV1,
        phase: RecoveryPhaseV1,
        recovery_generation: u64,
    ) LeaseTreeAllocationRecoveryV1 {
        var outstanding_count: u64 = 0;
        var outstanding_bytes: u64 = 0;
        var outstanding_hash =
            std.crypto.hash.sha2.Sha256.init(.{});
        outstanding_hash.update(outstanding_set_domain);
        hashU64(
            &outstanding_hash,
            self.admission.coordinator_epoch,
        );
        hashU64(&outstanding_hash, self.admission.generation);
        for (self.objects) |object| {
            if (object.state != .live) continue;
            outstanding_count += 1;
            outstanding_bytes +|= object.call.charged_bytes;
            hashU64(&outstanding_hash, object.ordinal);
            outstanding_hash.update(
                &allocation.backendObjectRootV1(object.object),
            );
            outstanding_hash.update(&object.object.object_sha256);
        }
        var outstanding_root = zero_digest;
        if (outstanding_count != 0)
            outstanding_hash.final(&outstanding_root);
        const bank_authority = switch (phase) {
            .rollback_reserved => if (self.batch) |batch|
                leaseAllocationBatchSha256V1(batch)
            else
                zero_digest,
            .free_authorized, .settlement_required => if (self.permit) |permit|
                leaseFreePermitSha256V1(permit)
            else
                zero_digest,
            _ => zero_digest,
        };
        var result: LeaseTreeAllocationRecoveryV1 = .{
            .phase = phase,
            .target_outcome = self.target_outcome,
            .target_reason = self.target_reason,
            .coordinator_epoch = self.admission.coordinator_epoch,
            .generation = self.admission.generation,
            .recovery_generation = recovery_generation,
            .authority_sha256 = self.admission.authority_sha256,
            .admission_sha256 = self.admission.admission_sha256,
            .parent_receipt_sha256 = self.admission.parent_receipt_sha256,
            .lease_sha256 = if (self.target_outcome == .released)
                self.lease.lease_sha256
            else
                zero_digest,
            .backend_object_set_sha256 = if (self.target_outcome == .released)
                self.object_set.object_set_sha256
            else
                zero_digest,
            .bank_authority_sha256 = bank_authority,
            .total_device_bytes = self.admission.total_device_bytes,
            .outstanding_object_count = outstanding_count,
            .outstanding_bytes = outstanding_bytes,
            .outstanding_set_sha256 = outstanding_root,
            .pending_tree = self.tree.*,
            .scope = self.admission.scope,
        };
        result.recovery_sha256 = recoveryRootV1(result);
        return result;
    }

    fn makeTerminal(
        self: *CoordinatorV1,
        admission: LeaseTreeAllocationAdmissionV1,
        lease_sha256: Digest,
        object_set_sha256: Digest,
        outcome: allocation.TerminalOutcomeV1,
        reason: allocation.TerminalReasonV1,
    ) LeaseTreeAllocationTerminalReceiptV1 {
        var result: LeaseTreeAllocationTerminalReceiptV1 = .{
            .outcome = outcome,
            .reason = reason,
            .coordinator_epoch = admission.coordinator_epoch,
            .generation = admission.generation,
            .authority_sha256 = admission.authority_sha256,
            .request_sha256 = admission.request_sha256,
            .admission_sha256 = admission.admission_sha256,
            .lease_sha256 = if (outcome == .released)
                lease_sha256
            else
                zero_digest,
            .backend_object_set_sha256 = if (outcome == .released)
                object_set_sha256
            else
                zero_digest,
            .parent_receipt_sha256 = admission.parent_receipt_sha256,
            .allocation_batch_sha256 = admission.allocation_batch_sha256,
            .returned_device_bytes = admission.total_device_bytes,
            .terminal_tree = self.tree.*,
            .scope = admission.scope,
        };
        result.terminal_sha256 = terminalRootV1(result);
        return result;
    }

    fn clearLifecycle(self: *CoordinatorV1) void {
        for (self.dispatches) |*dispatch| {
            if (dispatch.state != .free)
                @panic(
                    "device allocation lifecycle cleared with active dispatch",
                );
            dispatch.* = .{};
        }
        for (self.objects) |*object| {
            if (object.state != .free)
                object.* = .{};
        }
        self.state = .idle;
        self.generation = 0;
        self.authority = .{};
        self.request = .{};
        self.admission = undefined;
        self.batch = null;
        self.object_set = .{};
        self.lease = undefined;
        self.permit = null;
        self.target_outcome = .cancelled;
        self.target_reason = .explicit_cancellation;
        self.recovery_generation = 0;
        self.recovery = undefined;
        self.adapter_context = null;
        self.adapter_quote_fn = null;
        self.adapter_allocate_fn = null;
        self.adapter_free_fn = null;
    }
};

fn makeAdmission(
    coordinator_epoch: u64,
    generation: u64,
    authority: allocation.AllocationAuthorityV1,
    request: allocation.AllocationRequestV1,
    reservation: resource.LeaseAllocationReservationV1,
    scope: resource.LeaseNodeV1,
    leaves: []const resource.LeaseNodeV1,
) LeaseTreeAllocationAdmissionV1 {
    var result: LeaseTreeAllocationAdmissionV1 = .{
        .coordinator_epoch = coordinator_epoch,
        .generation = generation,
        .authority_sha256 = authority.authority_sha256,
        .request_sha256 = request.request_sha256,
        .selection_receipt_sha256 = request.selection_receipt_sha256,
        .selected_capability_sha256 = request.selected_capability_sha256,
        .allocation_manifest_sha256 = request.allocation_manifest_sha256,
        .parent_receipt_sha256 = request.parent_receipt_sha256,
        .reservation_tree = reservation.tree,
        .scope = scope,
        .allocation_batch_sha256 = leaseAllocationBatchSha256V1(reservation.batch),
        .allocation_leaf_set_sha256 = allocationLeafSetSha256V1(leaves),
        .publication_binding_sha256 = publicationBindingSha256V1(reservation.batch),
        .allocation_count = request.allocation_count,
        .total_device_bytes = request.total_device_bytes,
    };
    result.admission_sha256 = admissionRootV1(result);
    return result;
}

fn makeLease(
    admission: LeaseTreeAllocationAdmissionV1,
    object_set: allocation.BackendObjectSetV1,
    tree: resource.LeaseTreeV1,
) LeaseTreeDeviceAllocationLeaseV1 {
    var result: LeaseTreeDeviceAllocationLeaseV1 = .{
        .coordinator_epoch = admission.coordinator_epoch,
        .generation = admission.generation,
        .authority_sha256 = admission.authority_sha256,
        .request_sha256 = admission.request_sha256,
        .admission_sha256 = admission.admission_sha256,
        .selection_receipt_sha256 = admission.selection_receipt_sha256,
        .selected_capability_sha256 = admission.selected_capability_sha256,
        .allocation_manifest_sha256 = admission.allocation_manifest_sha256,
        .parent_receipt_sha256 = admission.parent_receipt_sha256,
        .materialized_tree = tree,
        .scope = admission.scope,
        .allocation_leaf_set_sha256 = admission.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = object_set.object_set_sha256,
        .allocation_count = object_set.allocation_count,
        .materialized_bytes = object_set.total_allocated_bytes,
    };
    result.lease_sha256 = leaseRootV1(result);
    return result;
}

fn makeDispatchPinIntent(
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
    scope: resource.LeaseNodeV1,
    adapter: DispatchAdapterV1,
    dispatch_generation: u64,
    dispatch_request_sha256: Digest,
    publication_binding_sha256: Digest,
) DispatchPinIntentV1 {
    var result: DispatchPinIntentV1 = .{
        .coordinator_epoch = admission.coordinator_epoch,
        .allocation_generation = admission.generation,
        .dispatch_generation = dispatch_generation,
        .allocation_count = lease.allocation_count,
        .pinned_device_bytes = lease.materialized_bytes,
        .authority_sha256 = admission.authority_sha256,
        .dispatch_authority_sha256 = adapter.dispatch_authority_sha256,
        .queue_authority_sha256 = adapter.queue_authority_sha256,
        .request_sha256 = admission.request_sha256,
        .admission_sha256 = admission.admission_sha256,
        .lease_sha256 = lease.lease_sha256,
        .parent_receipt_sha256 = admission.parent_receipt_sha256,
        .allocation_leaf_set_sha256 = admission.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = lease.backend_object_set_sha256,
        .scope_sha256 = leaseNodeSha256V1(scope),
        .dispatch_request_sha256 = dispatch_request_sha256,
        .publication_binding_sha256 = publication_binding_sha256,
    };
    result.intent_sha256 = dispatchPinIntentRootV1(result);
    validateDispatchPinIntentV1(result) catch
        @panic("constructed invalid dispatch pin intent");
    return result;
}

fn makeDispatchPin(
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
    acquired: resource.LeasePinAcquiredV1,
    adapter: DispatchAdapterV1,
    dispatch_generation: u64,
    dispatch_request_sha256: Digest,
) LeaseTreeDispatchPinV1 {
    if (!resource.leasePinPermitIntegrityValidV1(
        acquired.permit,
    ) or !bankPinBindingValid(
        acquired,
        admission,
        lease,
    ))
        @panic("valid device dispatch Bank pin failed composition");
    var result: LeaseTreeDispatchPinV1 = .{
        .coordinator_epoch = admission.coordinator_epoch,
        .allocation_generation = admission.generation,
        .dispatch_generation = dispatch_generation,
        .authority_sha256 = admission.authority_sha256,
        .dispatch_authority_sha256 = adapter.dispatch_authority_sha256,
        .queue_authority_sha256 = adapter.queue_authority_sha256,
        .request_sha256 = admission.request_sha256,
        .admission_sha256 = admission.admission_sha256,
        .lease_sha256 = lease.lease_sha256,
        .parent_receipt_sha256 = admission.parent_receipt_sha256,
        .allocation_leaf_set_sha256 = admission.allocation_leaf_set_sha256,
        .backend_object_set_sha256 = lease.backend_object_set_sha256,
        .dispatch_request_sha256 = dispatch_request_sha256,
        .publication_binding_sha256 = dispatchPublicationBindingSha256V1(
            acquired.permit.parent,
            acquired.permit.request_epoch,
            acquired.permit.session_id,
            acquired.permit.sequence,
        ),
        .bank_pin_sha256 = leasePinPermitSha256V1(acquired.permit),
        .pinned_tree = acquired.tree,
        .scope = admission.scope,
        .allocation_count = lease.allocation_count,
        .pinned_device_bytes = lease.materialized_bytes,
    };
    result.pin_sha256 = dispatchPinRootV1(result);
    validateDispatchPinV1(result) catch
        @panic("constructed invalid device dispatch pin");
    return result;
}

fn makeDispatchCompletion(
    pin: LeaseTreeDispatchPinV1,
    terminal: DispatchTerminalEvidenceV1,
    released: resource.LeasePinReleasedV1,
    permit: resource.LeasePinPermitV1,
    publication_binding_sha256: Digest,
) LeaseTreeDispatchCompletionV1 {
    if (!resource.leasePinCompletionIntegrityValidV1(
        released.completion,
    ) or !bankCompletionBindingValid(
        released,
        pin,
        permit,
    ))
        @panic(
            "valid device dispatch Bank completion failed composition",
        );
    var result: LeaseTreeDispatchCompletionV1 = .{
        .outcome = terminal.outcome,
        .coordinator_epoch = pin.coordinator_epoch,
        .allocation_generation = pin.allocation_generation,
        .dispatch_generation = pin.dispatch_generation,
        .pin_sha256 = pin.pin_sha256,
        .dispatch_terminal_sha256 = terminal.terminal_sha256,
        .submission_sha256 = terminal.submission_sha256,
        .backend_completion_sha256 = terminal.backend_completion_sha256,
        .output_sha256 = terminal.output_sha256,
        .bank_completion_sha256 = leasePinCompletionSha256V1(
            released.completion,
        ),
        .completion_publication_binding_sha256 = publication_binding_sha256,
        .completed_tree = released.tree,
        .scope = pin.scope,
    };
    result.completion_sha256 =
        dispatchCompletionRootV1(result);
    validateDispatchCompletionForPinV1(
        result,
        pin,
        terminal,
    ) catch @panic(
        "constructed invalid device dispatch completion",
    );
    return result;
}

pub fn validateAdmissionV1(
    admission: LeaseTreeAllocationAdmissionV1,
) Error!void {
    if (admission.abi_version != admission_abi or
        admission.coordinator_epoch == 0 or
        admission.generation == 0 or
        digestIsZero(admission.authority_sha256) or
        digestIsZero(admission.request_sha256) or
        digestIsZero(admission.selection_receipt_sha256) or
        digestIsZero(admission.selected_capability_sha256) or
        digestIsZero(admission.allocation_manifest_sha256) or
        digestIsZero(admission.parent_receipt_sha256) or
        !resource.leaseTreeIntegrityValidV1(
            admission.reservation_tree,
        ) or
        !treeScopeBindingValid(
            admission.reservation_tree,
            admission.scope,
            admission.parent_receipt_sha256,
        ) or
        digestIsZero(admission.allocation_batch_sha256) or
        digestIsZero(admission.allocation_leaf_set_sha256) or
        digestIsZero(admission.publication_binding_sha256) or
        admission.allocation_count == 0 or
        admission.allocation_count > allocation.maximum_allocations or
        admission.total_device_bytes == 0 or
        admission.total_device_bytes < admission.allocation_count or
        admission.total_device_bytes !=
            admission.scope.ceiling.device_bytes or
        admission.reservation_tree.active_nodes <
            admission.allocation_count + 1 or
        admission.reservation_tree.current.device_bytes <
            admission.total_device_bytes or
        digestIsZero(admission.admission_sha256) or
        !digestEqual(
            admission.admission_sha256,
            admissionRootV1(admission),
        ))
        return Error.InvalidTreeAdmission;
}

pub fn admissionRootV1(
    admission: LeaseTreeAllocationAdmissionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(admission_domain);
    hashU64(&hash, admission.abi_version);
    hashU64(&hash, admission.coordinator_epoch);
    hashU64(&hash, admission.generation);
    hash.update(&admission.authority_sha256);
    hash.update(&admission.request_sha256);
    hash.update(&admission.selection_receipt_sha256);
    hash.update(&admission.selected_capability_sha256);
    hash.update(&admission.allocation_manifest_sha256);
    hash.update(&admission.parent_receipt_sha256);
    hash.update(&leaseTreeSha256V1(admission.reservation_tree));
    hash.update(&leaseNodeSha256V1(admission.scope));
    hash.update(&admission.allocation_batch_sha256);
    hash.update(&admission.allocation_leaf_set_sha256);
    hash.update(&admission.publication_binding_sha256);
    hashU64(&hash, admission.allocation_count);
    hashU64(&hash, admission.total_device_bytes);
    return finish(&hash);
}

pub fn validateLeaseV1(
    lease: LeaseTreeDeviceAllocationLeaseV1,
) Error!void {
    if (lease.abi_version != lease_abi or
        lease.coordinator_epoch == 0 or lease.generation == 0 or
        digestIsZero(lease.authority_sha256) or
        digestIsZero(lease.request_sha256) or
        digestIsZero(lease.admission_sha256) or
        digestIsZero(lease.selection_receipt_sha256) or
        digestIsZero(lease.selected_capability_sha256) or
        digestIsZero(lease.allocation_manifest_sha256) or
        digestIsZero(lease.parent_receipt_sha256) or
        !resource.leaseTreeIntegrityValidV1(
            lease.materialized_tree,
        ) or
        !treeScopeBindingValid(
            lease.materialized_tree,
            lease.scope,
            lease.parent_receipt_sha256,
        ) or
        digestIsZero(lease.allocation_leaf_set_sha256) or
        digestIsZero(lease.backend_object_set_sha256) or
        lease.allocation_count == 0 or
        lease.allocation_count > allocation.maximum_allocations or
        lease.materialized_bytes == 0 or
        lease.materialized_bytes < lease.allocation_count or
        lease.materialized_bytes != lease.scope.ceiling.device_bytes or
        lease.materialized_tree.active_nodes <
            lease.allocation_count + 1 or
        lease.materialized_tree.current.device_bytes <
            lease.materialized_bytes or
        digestIsZero(lease.lease_sha256) or
        !digestEqual(lease.lease_sha256, leaseRootV1(lease)))
        return Error.InvalidTreeLease;
}

pub fn leaseRootV1(
    lease: LeaseTreeDeviceAllocationLeaseV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(lease_domain);
    hashU64(&hash, lease.abi_version);
    hashU64(&hash, lease.coordinator_epoch);
    hashU64(&hash, lease.generation);
    hash.update(&lease.authority_sha256);
    hash.update(&lease.request_sha256);
    hash.update(&lease.admission_sha256);
    hash.update(&lease.selection_receipt_sha256);
    hash.update(&lease.selected_capability_sha256);
    hash.update(&lease.allocation_manifest_sha256);
    hash.update(&lease.parent_receipt_sha256);
    hash.update(&leaseTreeSha256V1(lease.materialized_tree));
    hash.update(&leaseNodeSha256V1(lease.scope));
    hash.update(&lease.allocation_leaf_set_sha256);
    hash.update(&lease.backend_object_set_sha256);
    hashU64(&hash, lease.allocation_count);
    hashU64(&hash, lease.materialized_bytes);
    return finish(&hash);
}

pub fn validateRecoveryV1(
    recovery: LeaseTreeAllocationRecoveryV1,
) Error!void {
    if (recovery.abi_version != recovery_abi or
        !recoveryPhaseValid(recovery.phase) or
        !recoveryPhasePairValid(
            recovery.phase,
            recovery.target_outcome,
            recovery.outstanding_object_count,
        ) or
        !terminalPairValid(
            recovery.target_outcome,
            recovery.target_reason,
        ) or recovery.coordinator_epoch == 0 or
        recovery.generation == 0 or
        recovery.recovery_generation == 0 or
        digestIsZero(recovery.authority_sha256) or
        digestIsZero(recovery.admission_sha256) or
        digestIsZero(recovery.parent_receipt_sha256) or
        digestIsZero(recovery.bank_authority_sha256) or
        recovery.total_device_bytes == 0 or
        recovery.outstanding_object_count >
            allocation.maximum_allocations or
        ((recovery.target_outcome == .released) !=
            !digestIsZero(recovery.lease_sha256)) or
        ((recovery.target_outcome == .released) !=
            !digestIsZero(
                recovery.backend_object_set_sha256,
            )) or
        ((recovery.outstanding_object_count == 0) !=
            digestIsZero(recovery.outstanding_set_sha256)) or
        (recovery.outstanding_object_count == 0 and
            recovery.outstanding_bytes != 0) or
        (recovery.outstanding_object_count != 0 and
            recovery.outstanding_bytes == 0) or
        recovery.outstanding_bytes <
            recovery.outstanding_object_count or
        (recovery.phase == .settlement_required and
            recovery.outstanding_object_count != 0) or
        !resource.leaseTreeIntegrityValidV1(
            recovery.pending_tree,
        ) or
        !treeScopeBindingValid(
            recovery.pending_tree,
            recovery.scope,
            recovery.parent_receipt_sha256,
        ) or
        recovery.total_device_bytes !=
            recovery.scope.ceiling.device_bytes or
        recovery.pending_tree.active_nodes <
            @max(
                recovery.outstanding_object_count + 1,
                @as(u64, 2),
            ) or
        recovery.pending_tree.current.device_bytes <
            recovery.total_device_bytes or
        recovery.outstanding_bytes > recovery.total_device_bytes or
        digestIsZero(recovery.recovery_sha256) or
        !digestEqual(
            recovery.recovery_sha256,
            recoveryRootV1(recovery),
        ))
        return Error.InvalidTreeRecovery;
}

pub fn recoveryRootV1(
    recovery: LeaseTreeAllocationRecoveryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(recovery_domain);
    hashU64(&hash, recovery.abi_version);
    hashU64(&hash, @intFromEnum(recovery.phase));
    hashU64(&hash, @intFromEnum(recovery.target_outcome));
    hashU64(&hash, @intFromEnum(recovery.target_reason));
    hashU64(&hash, recovery.coordinator_epoch);
    hashU64(&hash, recovery.generation);
    hashU64(&hash, recovery.recovery_generation);
    hash.update(&recovery.authority_sha256);
    hash.update(&recovery.admission_sha256);
    hash.update(&recovery.parent_receipt_sha256);
    hash.update(&recovery.lease_sha256);
    hash.update(&recovery.backend_object_set_sha256);
    hash.update(&recovery.bank_authority_sha256);
    hashU64(&hash, recovery.total_device_bytes);
    hashU64(&hash, recovery.outstanding_object_count);
    hashU64(&hash, recovery.outstanding_bytes);
    hash.update(&recovery.outstanding_set_sha256);
    hash.update(&leaseTreeSha256V1(recovery.pending_tree));
    hash.update(&leaseNodeSha256V1(recovery.scope));
    return finish(&hash);
}

pub fn validateTerminalReceiptV1(
    terminal: LeaseTreeAllocationTerminalReceiptV1,
) Error!void {
    if (terminal.abi_version != terminal_abi or
        !terminalPairValid(terminal.outcome, terminal.reason) or
        terminal.coordinator_epoch == 0 or terminal.generation == 0 or
        digestIsZero(terminal.authority_sha256) or
        digestIsZero(terminal.request_sha256) or
        digestIsZero(terminal.admission_sha256) or
        digestIsZero(terminal.parent_receipt_sha256) or
        digestIsZero(terminal.allocation_batch_sha256) or
        terminal.returned_device_bytes == 0 or
        ((terminal.outcome == .released) !=
            !digestIsZero(terminal.lease_sha256)) or
        ((terminal.outcome == .released) !=
            !digestIsZero(
                terminal.backend_object_set_sha256,
            )) or
        !resource.leaseTreeIntegrityValidV1(
            terminal.terminal_tree,
        ) or
        !treeScopeBindingValid(
            terminal.terminal_tree,
            terminal.scope,
            terminal.parent_receipt_sha256,
        ) or
        terminal.returned_device_bytes !=
            terminal.scope.ceiling.device_bytes or
        !deviceBytesCanBeRestored(
            terminal.terminal_tree.current.device_bytes,
            terminal.returned_device_bytes,
            terminal.terminal_tree.ceiling.device_bytes,
        ) or
        (!terminal.terminal_tree.current.isZero() and
            terminal.terminal_tree.active_nodes < 3) or
        digestIsZero(terminal.terminal_sha256) or
        !digestEqual(
            terminal.terminal_sha256,
            terminalRootV1(terminal),
        ))
        return Error.InvalidTreeTerminalReceipt;
}

pub fn terminalRootV1(
    terminal: LeaseTreeAllocationTerminalReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(terminal_domain);
    hashU64(&hash, terminal.abi_version);
    hashU64(&hash, @intFromEnum(terminal.outcome));
    hashU64(&hash, @intFromEnum(terminal.reason));
    hashU64(&hash, terminal.coordinator_epoch);
    hashU64(&hash, terminal.generation);
    hash.update(&terminal.authority_sha256);
    hash.update(&terminal.request_sha256);
    hash.update(&terminal.admission_sha256);
    hash.update(&terminal.lease_sha256);
    hash.update(&terminal.backend_object_set_sha256);
    hash.update(&terminal.parent_receipt_sha256);
    hash.update(&terminal.allocation_batch_sha256);
    hashU64(&hash, terminal.returned_device_bytes);
    hash.update(&leaseTreeSha256V1(terminal.terminal_tree));
    hash.update(&leaseNodeSha256V1(terminal.scope));
    return finish(&hash);
}

pub fn validateDispatchAdapterV1(
    adapter: DispatchAdapterV1,
) Error!void {
    if (digestIsZero(adapter.dispatch_authority_sha256) or
        digestIsZero(adapter.queue_authority_sha256) or
        digestEqual(
            adapter.dispatch_authority_sha256,
            adapter.queue_authority_sha256,
        ))
        return Error.InvalidDispatchAdapter;
}

pub fn makeDispatchTerminalV1(
    pin: LeaseTreeDispatchPinV1,
    outcome: DispatchTerminalOutcomeV1,
    submission_sha256: Digest,
    backend_completion_sha256: Digest,
    output_sha256: Digest,
) Error!DispatchTerminalEvidenceV1 {
    try validateDispatchPinV1(pin);
    var result: DispatchTerminalEvidenceV1 = .{
        .outcome = outcome,
        .dispatch_generation = pin.dispatch_generation,
        .dispatch_authority_sha256 = pin.dispatch_authority_sha256,
        .queue_authority_sha256 = pin.queue_authority_sha256,
        .pin_sha256 = pin.pin_sha256,
        .dispatch_request_sha256 = pin.dispatch_request_sha256,
        .submission_sha256 = submission_sha256,
        .backend_completion_sha256 = backend_completion_sha256,
        .output_sha256 = output_sha256,
    };
    result.terminal_sha256 =
        dispatchTerminalRootV1(result);
    try validateDispatchTerminalV1(result);
    return result;
}

pub fn validateDispatchTerminalV1(
    terminal: DispatchTerminalEvidenceV1,
) Error!void {
    if (terminal.abi_version != dispatch_terminal_abi or
        !dispatchTerminalOutcomeValid(terminal.outcome) or
        terminal.dispatch_generation == 0 or
        digestIsZero(terminal.dispatch_authority_sha256) or
        digestIsZero(terminal.queue_authority_sha256) or
        digestEqual(
            terminal.dispatch_authority_sha256,
            terminal.queue_authority_sha256,
        ) or digestIsZero(terminal.pin_sha256) or
        digestIsZero(terminal.dispatch_request_sha256) or
        !dispatchTerminalRootPairValid(terminal) or
        digestIsZero(terminal.terminal_sha256) or
        !digestEqual(
            terminal.terminal_sha256,
            dispatchTerminalRootV1(terminal),
        ))
        return Error.InvalidDispatchTerminal;
}

pub fn dispatchTerminalRootV1(
    terminal: DispatchTerminalEvidenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_terminal_domain);
    hashU64(&hash, terminal.abi_version);
    hashU64(&hash, @intFromEnum(terminal.outcome));
    hashU64(&hash, terminal.dispatch_generation);
    hash.update(&terminal.dispatch_authority_sha256);
    hash.update(&terminal.queue_authority_sha256);
    hash.update(&terminal.pin_sha256);
    hash.update(&terminal.dispatch_request_sha256);
    hash.update(&terminal.submission_sha256);
    hash.update(&terminal.backend_completion_sha256);
    hash.update(&terminal.output_sha256);
    return finish(&hash);
}

pub fn validateDispatchPinIntentV1(
    intent: DispatchPinIntentV1,
) Error!void {
    if (intent.abi_version != dispatch_pin_intent_abi or
        intent.coordinator_epoch == 0 or
        intent.allocation_generation == 0 or
        intent.dispatch_generation == 0 or
        intent.allocation_count == 0 or
        intent.allocation_count > allocation.maximum_allocations or
        intent.pinned_device_bytes < intent.allocation_count or
        digestIsZero(intent.authority_sha256) or
        digestIsZero(intent.dispatch_authority_sha256) or
        digestIsZero(intent.queue_authority_sha256) or
        digestEqual(
            intent.dispatch_authority_sha256,
            intent.queue_authority_sha256,
        ) or digestIsZero(intent.request_sha256) or
        digestIsZero(intent.admission_sha256) or
        digestIsZero(intent.lease_sha256) or
        digestIsZero(intent.parent_receipt_sha256) or
        digestIsZero(intent.allocation_leaf_set_sha256) or
        digestIsZero(intent.backend_object_set_sha256) or
        digestIsZero(intent.scope_sha256) or
        digestIsZero(intent.dispatch_request_sha256) or
        digestIsZero(intent.publication_binding_sha256) or
        digestIsZero(intent.intent_sha256) or
        !digestEqual(
            intent.intent_sha256,
            dispatchPinIntentRootV1(intent),
        ))
        return Error.InvalidDispatchPin;
}

pub fn dispatchPinIntentRootV1(
    intent: DispatchPinIntentV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_pin_intent_domain);
    hashU64(&hash, intent.abi_version);
    hashU64(&hash, intent.coordinator_epoch);
    hashU64(&hash, intent.allocation_generation);
    hashU64(&hash, intent.dispatch_generation);
    hashU64(&hash, intent.allocation_count);
    hashU64(&hash, intent.pinned_device_bytes);
    hash.update(&intent.authority_sha256);
    hash.update(&intent.dispatch_authority_sha256);
    hash.update(&intent.queue_authority_sha256);
    hash.update(&intent.request_sha256);
    hash.update(&intent.admission_sha256);
    hash.update(&intent.lease_sha256);
    hash.update(&intent.parent_receipt_sha256);
    hash.update(&intent.allocation_leaf_set_sha256);
    hash.update(&intent.backend_object_set_sha256);
    hash.update(&intent.scope_sha256);
    hash.update(&intent.dispatch_request_sha256);
    hash.update(&intent.publication_binding_sha256);
    return finish(&hash);
}

pub fn validateDispatchPinForIntentV1(
    pin: LeaseTreeDispatchPinV1,
    intent: DispatchPinIntentV1,
) Error!void {
    try validateDispatchPinV1(pin);
    try validateDispatchPinIntentV1(intent);
    if (pin.coordinator_epoch != intent.coordinator_epoch or
        pin.allocation_generation != intent.allocation_generation or
        pin.dispatch_generation != intent.dispatch_generation or
        pin.allocation_count != intent.allocation_count or
        pin.pinned_device_bytes != intent.pinned_device_bytes or
        !digestEqual(pin.authority_sha256, intent.authority_sha256) or
        !digestEqual(
            pin.dispatch_authority_sha256,
            intent.dispatch_authority_sha256,
        ) or !digestEqual(
        pin.queue_authority_sha256,
        intent.queue_authority_sha256,
    ) or !digestEqual(pin.request_sha256, intent.request_sha256) or
        !digestEqual(
            pin.admission_sha256,
            intent.admission_sha256,
        ) or !digestEqual(pin.lease_sha256, intent.lease_sha256) or
        !digestEqual(
            pin.parent_receipt_sha256,
            intent.parent_receipt_sha256,
        ) or !digestEqual(
        pin.allocation_leaf_set_sha256,
        intent.allocation_leaf_set_sha256,
    ) or !digestEqual(
        pin.backend_object_set_sha256,
        intent.backend_object_set_sha256,
    ) or !digestEqual(
        leaseNodeSha256V1(pin.scope),
        intent.scope_sha256,
    ) or !digestEqual(
        pin.dispatch_request_sha256,
        intent.dispatch_request_sha256,
    ) or !digestEqual(
        pin.publication_binding_sha256,
        intent.publication_binding_sha256,
    ))
        return Error.InvalidDispatchPin;
}

pub fn validateDispatchPinV1(
    pin: LeaseTreeDispatchPinV1,
) Error!void {
    if (pin.abi_version != dispatch_pin_abi or
        pin.coordinator_epoch == 0 or
        pin.allocation_generation == 0 or
        pin.dispatch_generation == 0 or
        digestIsZero(pin.authority_sha256) or
        digestIsZero(pin.dispatch_authority_sha256) or
        digestIsZero(pin.queue_authority_sha256) or
        digestEqual(
            pin.dispatch_authority_sha256,
            pin.queue_authority_sha256,
        ) or digestIsZero(pin.request_sha256) or
        digestIsZero(pin.admission_sha256) or
        digestIsZero(pin.lease_sha256) or
        digestIsZero(pin.parent_receipt_sha256) or
        digestIsZero(pin.allocation_leaf_set_sha256) or
        digestIsZero(pin.backend_object_set_sha256) or
        digestIsZero(pin.dispatch_request_sha256) or
        digestIsZero(pin.publication_binding_sha256) or
        digestIsZero(pin.bank_pin_sha256) or
        !treeScopeBindingValid(
            pin.pinned_tree,
            pin.scope,
            pin.parent_receipt_sha256,
        ) or pin.allocation_count == 0 or
        pin.allocation_count > allocation.maximum_allocations or
        pin.pinned_device_bytes == 0 or
        pin.pinned_device_bytes < pin.allocation_count or
        pin.pinned_device_bytes != pin.scope.ceiling.device_bytes or
        pin.pinned_tree.active_nodes < pin.allocation_count + 1 or
        pin.pinned_tree.current.device_bytes <
            pin.pinned_device_bytes or
        digestIsZero(pin.pin_sha256) or
        !digestEqual(pin.pin_sha256, dispatchPinRootV1(pin)))
        return Error.InvalidDispatchPin;
}

pub fn dispatchPinRootV1(
    pin: LeaseTreeDispatchPinV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_pin_domain);
    hashU64(&hash, pin.abi_version);
    hashU64(&hash, pin.coordinator_epoch);
    hashU64(&hash, pin.allocation_generation);
    hashU64(&hash, pin.dispatch_generation);
    hash.update(&pin.authority_sha256);
    hash.update(&pin.dispatch_authority_sha256);
    hash.update(&pin.queue_authority_sha256);
    hash.update(&pin.request_sha256);
    hash.update(&pin.admission_sha256);
    hash.update(&pin.lease_sha256);
    hash.update(&pin.parent_receipt_sha256);
    hash.update(&pin.allocation_leaf_set_sha256);
    hash.update(&pin.backend_object_set_sha256);
    hash.update(&pin.dispatch_request_sha256);
    hash.update(&pin.publication_binding_sha256);
    hash.update(&pin.bank_pin_sha256);
    hash.update(&leaseTreeSha256V1(pin.pinned_tree));
    hash.update(&leaseNodeSha256V1(pin.scope));
    hashU64(&hash, pin.allocation_count);
    hashU64(&hash, pin.pinned_device_bytes);
    return finish(&hash);
}

pub fn validateDispatchTerminalForPinV1(
    terminal: DispatchTerminalEvidenceV1,
    pin: LeaseTreeDispatchPinV1,
) Error!void {
    try validateDispatchTerminalV1(terminal);
    try validateDispatchPinV1(pin);
    if (terminal.dispatch_generation != pin.dispatch_generation or
        !digestEqual(
            terminal.dispatch_authority_sha256,
            pin.dispatch_authority_sha256,
        ) or !digestEqual(
        terminal.queue_authority_sha256,
        pin.queue_authority_sha256,
    ) or !digestEqual(
        terminal.pin_sha256,
        pin.pin_sha256,
    ) or !digestEqual(
        terminal.dispatch_request_sha256,
        pin.dispatch_request_sha256,
    ))
        return Error.InvalidDispatchTerminal;
}

pub fn validateDispatchCompletionV1(
    completion: LeaseTreeDispatchCompletionV1,
) Error!void {
    const parent_sha256 = allocation.resourceReceiptRootV1(
        completion.completed_tree.parent,
    );
    if (completion.abi_version != dispatch_completion_abi or
        !dispatchTerminalOutcomeValid(completion.outcome) or
        completion.coordinator_epoch == 0 or
        completion.allocation_generation == 0 or
        completion.dispatch_generation == 0 or
        digestIsZero(completion.pin_sha256) or
        digestIsZero(completion.dispatch_terminal_sha256) or
        !dispatchCompletionRootPairValid(completion) or
        digestIsZero(completion.bank_completion_sha256) or
        digestIsZero(
            completion.completion_publication_binding_sha256,
        ) or !treeScopeBindingValid(
        completion.completed_tree,
        completion.scope,
        parent_sha256,
    ) or completion.completed_tree.current.device_bytes <
        completion.scope.ceiling.device_bytes or
        digestIsZero(completion.completion_sha256) or
        !digestEqual(
            completion.completion_sha256,
            dispatchCompletionRootV1(completion),
        ))
        return Error.InvalidDispatchCompletion;
}

pub fn dispatchCompletionRootV1(
    completion: LeaseTreeDispatchCompletionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_completion_domain);
    hashU64(&hash, completion.abi_version);
    hashU64(&hash, @intFromEnum(completion.outcome));
    hashU64(&hash, completion.coordinator_epoch);
    hashU64(&hash, completion.allocation_generation);
    hashU64(&hash, completion.dispatch_generation);
    hash.update(&completion.pin_sha256);
    hash.update(&completion.dispatch_terminal_sha256);
    hash.update(&completion.submission_sha256);
    hash.update(&completion.backend_completion_sha256);
    hash.update(&completion.output_sha256);
    hash.update(&completion.bank_completion_sha256);
    hash.update(
        &completion.completion_publication_binding_sha256,
    );
    hash.update(&leaseTreeSha256V1(completion.completed_tree));
    hash.update(&leaseNodeSha256V1(completion.scope));
    return finish(&hash);
}

pub fn validateDispatchCompletionForPinV1(
    completion: LeaseTreeDispatchCompletionV1,
    pin: LeaseTreeDispatchPinV1,
    terminal: DispatchTerminalEvidenceV1,
) Error!void {
    try validateDispatchCompletionV1(completion);
    try validateDispatchTerminalForPinV1(terminal, pin);
    if (completion.outcome != terminal.outcome or
        completion.coordinator_epoch != pin.coordinator_epoch or
        completion.allocation_generation !=
            pin.allocation_generation or
        completion.dispatch_generation !=
            pin.dispatch_generation or
        !digestEqual(completion.pin_sha256, pin.pin_sha256) or
        !digestEqual(
            completion.dispatch_terminal_sha256,
            terminal.terminal_sha256,
        ) or !digestEqual(
        completion.submission_sha256,
        terminal.submission_sha256,
    ) or !digestEqual(
        completion.backend_completion_sha256,
        terminal.backend_completion_sha256,
    ) or !digestEqual(
        completion.output_sha256,
        terminal.output_sha256,
    ) or !digestEqual(
        completion.completion_publication_binding_sha256,
        pin.publication_binding_sha256,
    ) or !std.meta.eql(completion.scope, pin.scope) or
        !std.meta.eql(
            completion.completed_tree.parent,
            pin.pinned_tree.parent,
        ) or completion.completed_tree.tree_key !=
        pin.pinned_tree.tree_key or
        completion.completed_tree.authority_key !=
            pin.pinned_tree.authority_key or
        completion.completed_tree.identity_generation !=
            pin.pinned_tree.identity_generation or
        completion.completed_tree.generation <=
            pin.pinned_tree.generation or
        completion.completed_tree.structural_revision <=
            pin.pinned_tree.structural_revision or
        !std.meta.eql(
            completion.completed_tree.ceiling,
            pin.pinned_tree.ceiling,
        ) or completion.completed_tree.active_nodes <
        pin.allocation_count + 1)
        return Error.InvalidDispatchCompletion;
}

/// Bind a public dispatch completion to the exact coordinator-private Bank
/// permit consumed for this pin. Static completion hashes alone are
/// composition evidence; adapter settlement authority additionally requires
/// this permit and its exact Bank-produced completion.
pub fn validateDispatchSettlementForPinV1(
    completion: LeaseTreeDispatchCompletionV1,
    pin: LeaseTreeDispatchPinV1,
    terminal: DispatchTerminalEvidenceV1,
    bank_permit: resource.LeasePinPermitV1,
    bank_completion: resource.LeasePinCompletionV1,
) Error!void {
    try validateDispatchCompletionForPinV1(
        completion,
        pin,
        terminal,
    );
    const released: resource.LeasePinReleasedV1 = .{
        .tree = completion.completed_tree,
        .completion = bank_completion,
    };
    if (!bankPermitForDispatchPinValid(bank_permit, pin) or
        !bankCompletionBindingValid(
            released,
            pin,
            bank_permit,
        ) or !digestEqual(
        completion.bank_completion_sha256,
        leasePinCompletionSha256V1(bank_completion),
    ))
        return Error.InvalidDispatchCompletion;
}

pub fn leasePinPermitSha256V1(
    permit: resource.LeasePinPermitV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bank_pin_domain);
    hashU64(&hash, permit.abi_version);
    hash.update(&allocation.resourceReceiptRootV1(permit.parent));
    hashU64(&hash, permit.tree_key);
    hashU64(&hash, permit.tree_identity_generation);
    hashU64(&hash, permit.tree_generation);
    hashU64(&hash, permit.structural_revision);
    hashU64(&hash, permit.pin_slot_index);
    hashU64(&hash, permit.reserved);
    hashU64(&hash, permit.generation);
    hashU64(&hash, permit.completion_generation);
    hashU64(&hash, permit.request_epoch);
    hashU64(&hash, @as(u64, @intCast(permit.session_id)));
    hashU64(&hash, permit.sequence);
    hashU64(&hash, permit.owner_key);
    hashU64(&hash, permit.scope_index);
    hashU64(&hash, permit.scope_generation);
    hashU64(&hash, permit.node_count);
    hashClaim(&hash, permit.claim);
    hashU64(&hash, permit.node_set_digest);
    hashU64(&hash, permit.integrity);
    return finish(&hash);
}

pub fn leasePinCompletionSha256V1(
    completion: resource.LeasePinCompletionV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bank_pin_completion_domain);
    hashU64(&hash, completion.abi_version);
    hash.update(
        &allocation.resourceReceiptRootV1(completion.parent),
    );
    hashU64(&hash, completion.tree_key);
    hashU64(&hash, completion.tree_identity_generation);
    hashU64(&hash, completion.pin_slot_index);
    hashU64(&hash, completion.reserved);
    hashU64(&hash, completion.permit_generation);
    hashU64(&hash, completion.completion_generation);
    hashU64(&hash, completion.request_epoch);
    hashU64(&hash, @as(u64, @intCast(completion.session_id)));
    hashU64(&hash, completion.sequence);
    hashU64(&hash, completion.owner_key);
    hashU64(&hash, completion.scope_index);
    hashU64(&hash, completion.scope_generation);
    hashU64(&hash, completion.node_count);
    hashClaim(&hash, completion.claim);
    hashU64(&hash, completion.node_set_digest);
    hashU64(&hash, completion.permit_integrity);
    hashU64(&hash, completion.completion_tree_generation);
    hashU64(
        &hash,
        completion.completion_structural_revision,
    );
    hashU64(&hash, completion.completion_state_digest);
    hashU64(&hash, completion.completion_tree_integrity);
    hashU64(&hash, completion.integrity);
    return finish(&hash);
}

pub fn leaseTreeSha256V1(tree: resource.LeaseTreeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(tree_domain);
    hashU64(&hash, tree.abi_version);
    hash.update(&allocation.resourceReceiptRootV1(tree.parent));
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
    return finish(&hash);
}

pub fn leaseNodeSha256V1(node: resource.LeaseNodeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(node_domain);
    hashU64(&hash, node.abi_version);
    hash.update(&allocation.resourceReceiptRootV1(node.parent));
    hashU64(&hash, node.tree_key);
    hashU64(&hash, node.tree_identity_generation);
    hashU64(&hash, node.node_index);
    hashU64(&hash, node.generation);
    hashU64(&hash, node.parent_index);
    hashU64(&hash, node.parent_generation);
    hashU64(&hash, node.node_key);
    hashU64(&hash, node.tenant_key);
    hashU64(&hash, node.binding_key);
    hashU64(&hash, @intFromEnum(node.kind));
    hashClaim(&hash, node.ceiling);
    hashClaim(&hash, node.claim);
    hashU64(&hash, node.integrity);
    return finish(&hash);
}

pub fn leaseAllocationBatchSha256V1(
    batch: resource.LeaseAllocationBatchV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(batch_domain);
    hashU64(&hash, batch.abi_version);
    hash.update(&allocation.resourceReceiptRootV1(batch.parent));
    hashU64(&hash, batch.tree_key);
    hashU64(&hash, batch.tree_identity_generation);
    hashU64(&hash, batch.tree_generation);
    hashU64(&hash, batch.structural_revision);
    hashU64(&hash, batch.request_epoch);
    hashU64(&hash, batch.session_id);
    hashU64(&hash, batch.sequence);
    hashU64(&hash, batch.generation);
    hashU64(&hash, batch.completion_tree_generation);
    hashU64(&hash, batch.node_count);
    hashClaim(&hash, batch.claim);
    hashU64(&hash, batch.node_set_digest);
    hashU64(&hash, batch.integrity);
    return finish(&hash);
}

pub fn leaseFreePermitSha256V1(
    permit: resource.LeaseFreePermitV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(permit_domain);
    hashU64(&hash, permit.abi_version);
    hash.update(&allocation.resourceReceiptRootV1(permit.parent));
    hashU64(&hash, permit.tree_key);
    hashU64(&hash, permit.tree_identity_generation);
    hashU64(&hash, permit.tree_generation);
    hashU64(&hash, permit.structural_revision);
    hashU64(&hash, permit.request_epoch);
    hashU64(&hash, permit.session_id);
    hashU64(&hash, permit.sequence);
    hashU64(&hash, permit.generation);
    hashU64(&hash, permit.completion_tree_generation);
    hashU64(&hash, permit.scope_index);
    hashU64(&hash, permit.scope_generation);
    hashU64(&hash, permit.node_count);
    hashClaim(&hash, permit.claim);
    hashU64(&hash, permit.node_set_digest);
    hashU64(&hash, permit.integrity);
    return finish(&hash);
}

pub fn allocationLeafSetSha256V1(
    leaves: []const resource.LeaseNodeV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(leaf_set_domain);
    hashU64(&hash, leaves.len);
    for (leaves) |leaf| hash.update(&leaseNodeSha256V1(leaf));
    return finish(&hash);
}

fn publicationBindingSha256V1(
    batch: resource.LeaseAllocationBatchV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(publication_binding_domain);
    hash.update(&allocation.resourceReceiptRootV1(batch.parent));
    hashU64(&hash, batch.request_epoch);
    hashU64(&hash, batch.session_id);
    hashU64(&hash, batch.sequence);
    return finish(&hash);
}

fn allocationKey(
    domain: []const u8,
    coordinator_epoch: u64,
    generation: u64,
    ordinal: usize,
    binding_sha256: Digest,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hashU64(&hash, coordinator_epoch);
    hashU64(&hash, generation);
    hashU64(&hash, ordinal);
    hash.update(&binding_sha256);
    const root = finish(&hash);
    const value = std.mem.readInt(u64, root[0..8], .little);
    return if (value == 0) 1 else value;
}

fn recoveryPhaseValid(phase: RecoveryPhaseV1) bool {
    return switch (phase) {
        .rollback_reserved,
        .free_authorized,
        .settlement_required,
        => true,
        _ => false,
    };
}

fn recoveryPhasePairValid(
    phase: RecoveryPhaseV1,
    outcome: allocation.TerminalOutcomeV1,
    outstanding_object_count: u64,
) bool {
    return switch (phase) {
        .rollback_reserved => outcome != .released,
        .free_authorized => outcome == .released and outstanding_object_count != 0,
        .settlement_required => outcome == .released and outstanding_object_count == 0,
        _ => false,
    };
}

fn terminalPairValid(
    outcome: allocation.TerminalOutcomeV1,
    reason: allocation.TerminalReasonV1,
) bool {
    return switch (outcome) {
        .cancelled => reason == .explicit_cancellation,
        .allocation_failed => reason == .backend_allocation_failure or
            reason == .backend_protocol_violation,
        .released => reason == .normal_release,
        _ => false,
    };
}

fn nextRecoveryGeneration(current: u64) u64 {
    return if (current == std.math.maxInt(u64))
        current
    else
        current + 1;
}

fn requestAdmissionBindingValid(
    request: allocation.AllocationRequestV1,
    admission: LeaseTreeAllocationAdmissionV1,
    expected_request_epoch: u64,
) bool {
    return request.abi_version == allocation.request_abi and
        request.request_epoch == expected_request_epoch and
        !digestIsZero(request.owner_sha256) and
        !digestIsZero(request.authority_sha256) and
        !digestIsZero(request.selection_receipt_sha256) and
        !digestIsZero(request.requirement_sha256) and
        !digestIsZero(request.selected_capability_sha256) and
        !digestIsZero(request.selected_entry_sha256) and
        !digestIsZero(request.allocation_manifest_sha256) and
        !digestIsZero(request.parent_receipt_sha256) and
        request.allocation_count != 0 and
        request.allocation_count <= allocation.maximum_allocations and
        request.largest_single_allocation_bytes != 0 and
        request.total_device_bytes != 0 and
        request.queue_slots != 0 and
        digestEqual(
            request.request_sha256,
            allocation.requestRootV1(request),
        ) and
        digestEqual(
            request.request_sha256,
            admission.request_sha256,
        ) and
        digestEqual(
            request.authority_sha256,
            admission.authority_sha256,
        ) and
        digestEqual(
            request.selection_receipt_sha256,
            admission.selection_receipt_sha256,
        ) and
        digestEqual(
            request.selected_capability_sha256,
            admission.selected_capability_sha256,
        ) and
        digestEqual(
            request.allocation_manifest_sha256,
            admission.allocation_manifest_sha256,
        ) and
        digestEqual(
            request.parent_receipt_sha256,
            admission.parent_receipt_sha256,
        ) and
        request.allocation_count == admission.allocation_count and
        request.total_device_bytes == admission.total_device_bytes;
}

fn admissionLeaseBindingValid(
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
) bool {
    return admission.coordinator_epoch == lease.coordinator_epoch and
        admission.generation == lease.generation and
        digestEqual(
            admission.authority_sha256,
            lease.authority_sha256,
        ) and
        digestEqual(
            admission.request_sha256,
            lease.request_sha256,
        ) and
        digestEqual(
            admission.admission_sha256,
            lease.admission_sha256,
        ) and
        digestEqual(
            admission.selection_receipt_sha256,
            lease.selection_receipt_sha256,
        ) and
        digestEqual(
            admission.selected_capability_sha256,
            lease.selected_capability_sha256,
        ) and
        digestEqual(
            admission.allocation_manifest_sha256,
            lease.allocation_manifest_sha256,
        ) and
        digestEqual(
            admission.parent_receipt_sha256,
            lease.parent_receipt_sha256,
        ) and
        std.meta.eql(admission.scope, lease.scope) and
        digestEqual(
            admission.allocation_leaf_set_sha256,
            lease.allocation_leaf_set_sha256,
        ) and
        admission.allocation_count == lease.allocation_count and
        admission.total_device_bytes == lease.materialized_bytes;
}

fn admissionBatchBindingValid(
    admission: LeaseTreeAllocationAdmissionV1,
    batch: resource.LeaseAllocationBatchV1,
) bool {
    return digestEqual(
        admission.allocation_batch_sha256,
        leaseAllocationBatchSha256V1(batch),
    ) and digestEqual(
        admission.publication_binding_sha256,
        publicationBindingSha256V1(batch),
    ) and digestEqual(
        admission.parent_receipt_sha256,
        allocation.resourceReceiptRootV1(batch.parent),
    ) and
        batch.tree_key == admission.reservation_tree.tree_key and
        batch.tree_identity_generation ==
            admission.reservation_tree.identity_generation and
        batch.tree_generation == admission.reservation_tree.generation and
        batch.structural_revision ==
            admission.reservation_tree.structural_revision and
        batch.node_count == admission.allocation_count and
        std.meta.eql(
            batch.claim,
            resource.Claim{
                .device_bytes = admission.total_device_bytes,
            },
        );
}

fn freePermitBindingValid(
    permit: resource.LeaseFreePermitV1,
    tree: resource.LeaseTreeV1,
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
    scope: resource.LeaseNodeV1,
    request_epoch: u64,
    session_id: usize,
    sequence: u64,
) bool {
    return digestEqual(
        admission.parent_receipt_sha256,
        allocation.resourceReceiptRootV1(permit.parent),
    ) and
        std.meta.eql(permit.parent, tree.parent) and
        permit.tree_key == tree.tree_key and
        permit.tree_identity_generation ==
            tree.identity_generation and
        permit.tree_generation == tree.generation and
        permit.structural_revision == tree.structural_revision and
        permit.request_epoch == request_epoch and
        permit.session_id == session_id and
        permit.sequence == sequence and
        permit.scope_index == scope.node_index and
        permit.scope_generation == scope.generation and
        permit.node_count == admission.allocation_count and
        permit.node_count == lease.allocation_count and
        std.meta.eql(
            permit.claim,
            resource.Claim{
                .device_bytes = admission.total_device_bytes,
            },
        ) and
        admission.total_device_bytes == lease.materialized_bytes;
}

fn admittedLeafBindingsValid(
    admission: LeaseTreeAllocationAdmissionV1,
    objects: []const CoordinatorObjectSlotV1,
) bool {
    if (objects.len != admission.allocation_count)
        return false;
    for (objects, 0..) |object, ordinal| {
        const leaf = object.leaf;
        const exact_claim: resource.Claim = .{
            .device_bytes = object.entry.charged_bytes,
        };
        if (!resource.leaseNodeIntegrityValidV1(leaf) or
            leaf.kind != .allocation or
            !std.meta.eql(leaf.parent, admission.scope.parent) or
            leaf.tree_key != admission.scope.tree_key or
            leaf.tree_identity_generation !=
                admission.scope.tree_identity_generation or
            leaf.node_index == std.math.maxInt(u32) or
            leaf.generation == 0 or
            leaf.parent_index != admission.scope.node_index or
            leaf.parent_generation != admission.scope.generation or
            leaf.tenant_key != admission.scope.tenant_key or
            leaf.node_key != allocationKey(
                node_key_domain,
                admission.coordinator_epoch,
                admission.generation,
                ordinal,
                object.entry.binding_sha256,
            ) or
            leaf.binding_key != allocationKey(
                binding_key_domain,
                admission.coordinator_epoch,
                admission.generation,
                ordinal,
                object.entry.binding_sha256,
            ) or !std.meta.eql(leaf.ceiling, exact_claim) or
            !std.meta.eql(leaf.claim, exact_claim))
            return false;
    }
    return true;
}

fn validateBoundDispatchAdapter(
    slot: CoordinatorDispatchSlotV1,
    adapter: DispatchAdapterV1,
) Error!void {
    try validateDispatchAdapterV1(adapter);
    const context = slot.adapter_context orelse
        return Error.InvalidDispatchAdapter;
    const reserve_dispatch_intent_fn =
        slot.adapter_reserve_dispatch_intent_fn orelse
        return Error.InvalidDispatchAdapter;
    const abort_dispatch_intent_fn =
        slot.adapter_abort_dispatch_intent_fn orelse
        return Error.InvalidDispatchAdapter;
    const validate_terminal_fn =
        slot.adapter_validate_terminal_fn orelse
        return Error.InvalidDispatchAdapter;
    const confirm_settlement_fn =
        slot.adapter_confirm_settlement_fn orelse
        return Error.InvalidDispatchAdapter;
    const pin = slot.pin orelse
        return Error.InvalidDispatchAdapter;
    const intent = slot.intent orelse
        return Error.InvalidDispatchAdapter;
    if (slot.state == .free or
        adapter.context != context or
        @intFromPtr(adapter.reserve_dispatch_intent_fn) !=
            @intFromPtr(reserve_dispatch_intent_fn) or
        @intFromPtr(adapter.abort_dispatch_intent_fn) !=
            @intFromPtr(abort_dispatch_intent_fn) or
        @intFromPtr(adapter.validate_terminal_fn) !=
            @intFromPtr(validate_terminal_fn) or
        @intFromPtr(adapter.confirm_settlement_fn) !=
            @intFromPtr(confirm_settlement_fn) or
        !digestEqual(
            adapter.dispatch_authority_sha256,
            pin.dispatch_authority_sha256,
        ) or !digestEqual(
        adapter.queue_authority_sha256,
        pin.queue_authority_sha256,
    ))
        return Error.InvalidDispatchAdapter;
    try validateDispatchPinForIntentV1(pin, intent);
}

fn dispatchSlotCanonicalFree(
    slot: CoordinatorDispatchSlotV1,
) bool {
    return std.meta.eql(slot, CoordinatorDispatchSlotV1{});
}

fn dispatchTerminalOutcomeValid(
    outcome: DispatchTerminalOutcomeV1,
) bool {
    return switch (outcome) {
        .succeeded,
        .terminal_failure,
        .cancelled_before_submit,
        .cancelled_after_submit,
        .rejected_before_submit,
        .ownership_retired_after_device_loss,
        => true,
        _ => false,
    };
}

fn dispatchTerminalRootPairValid(
    terminal: DispatchTerminalEvidenceV1,
) bool {
    return switch (terminal.outcome) {
        .succeeded => !digestIsZero(
            terminal.submission_sha256,
        ) and !digestIsZero(
            terminal.backend_completion_sha256,
        ) and !digestIsZero(terminal.output_sha256),
        .terminal_failure,
        .cancelled_after_submit,
        .ownership_retired_after_device_loss,
        => !digestIsZero(
            terminal.submission_sha256,
        ) and !digestIsZero(
            terminal.backend_completion_sha256,
        ) and digestIsZero(terminal.output_sha256),
        .cancelled_before_submit, .rejected_before_submit => digestIsZero(
            terminal.submission_sha256,
        ) and digestIsZero(
            terminal.backend_completion_sha256,
        ) and digestIsZero(terminal.output_sha256),
        _ => false,
    };
}

fn dispatchCompletionRootPairValid(
    completion: LeaseTreeDispatchCompletionV1,
) bool {
    return switch (completion.outcome) {
        .succeeded => !digestIsZero(
            completion.submission_sha256,
        ) and !digestIsZero(
            completion.backend_completion_sha256,
        ) and !digestIsZero(completion.output_sha256),
        .terminal_failure,
        .cancelled_after_submit,
        .ownership_retired_after_device_loss,
        => !digestIsZero(
            completion.submission_sha256,
        ) and !digestIsZero(
            completion.backend_completion_sha256,
        ) and digestIsZero(completion.output_sha256),
        .cancelled_before_submit, .rejected_before_submit => digestIsZero(
            completion.submission_sha256,
        ) and digestIsZero(
            completion.backend_completion_sha256,
        ) and digestIsZero(completion.output_sha256),
        _ => false,
    };
}

fn dispatchOwnerKeyV1(
    coordinator_epoch: u64,
    allocation_generation: u64,
    dispatch_generation: u64,
    dispatch_request_sha256: Digest,
) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_owner_domain);
    hashU64(&hash, coordinator_epoch);
    hashU64(&hash, allocation_generation);
    hashU64(&hash, dispatch_generation);
    hash.update(&dispatch_request_sha256);
    const root = finish(&hash);
    const value = std.mem.readInt(u64, root[0..8], .little);
    return if (value == 0) 1 else value;
}

fn dispatchPublicationBindingSha256V1(
    parent: resource.Receipt,
    request_epoch: u64,
    session_id: usize,
    sequence: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_publication_domain);
    hash.update(&allocation.resourceReceiptRootV1(parent));
    hashU64(&hash, request_epoch);
    hashU64(&hash, @as(u64, @intCast(session_id)));
    hashU64(&hash, sequence);
    return finish(&hash);
}

fn bankPinBindingValid(
    acquired: resource.LeasePinAcquiredV1,
    admission: LeaseTreeAllocationAdmissionV1,
    lease: LeaseTreeDeviceAllocationLeaseV1,
) bool {
    const permit = acquired.permit;
    const exact_claim: resource.Claim = .{
        .device_bytes = lease.materialized_bytes,
    };
    return resource.leasePinPermitIntegrityValidV1(permit) and
        std.meta.eql(acquired.tree.parent, permit.parent) and
        acquired.tree.tree_key == permit.tree_key and
        acquired.tree.identity_generation ==
            permit.tree_identity_generation and
        acquired.tree.generation == permit.tree_generation and
        acquired.tree.structural_revision ==
            permit.structural_revision and
        digestEqual(
            admission.parent_receipt_sha256,
            allocation.resourceReceiptRootV1(permit.parent),
        ) and permit.scope_index == admission.scope.node_index and
        permit.scope_generation == admission.scope.generation and
        permit.node_count == lease.allocation_count and
        std.meta.eql(permit.claim, exact_claim);
}

fn bankPermitForDispatchPinValid(
    permit: resource.LeasePinPermitV1,
    pin: LeaseTreeDispatchPinV1,
) bool {
    const exact_claim: resource.Claim = .{
        .device_bytes = pin.pinned_device_bytes,
    };
    return resource.leasePinPermitIntegrityValidV1(permit) and
        digestEqual(
            leasePinPermitSha256V1(permit),
            pin.bank_pin_sha256,
        ) and
        std.meta.eql(permit.parent, pin.pinned_tree.parent) and
        permit.tree_key == pin.pinned_tree.tree_key and
        permit.tree_identity_generation ==
            pin.pinned_tree.identity_generation and
        permit.tree_generation == pin.pinned_tree.generation and
        permit.structural_revision ==
            pin.pinned_tree.structural_revision and
        digestEqual(
            pin.parent_receipt_sha256,
            allocation.resourceReceiptRootV1(permit.parent),
        ) and digestEqual(
        pin.publication_binding_sha256,
        dispatchPublicationBindingSha256V1(
            permit.parent,
            permit.request_epoch,
            permit.session_id,
            permit.sequence,
        ),
    ) and permit.owner_key == dispatchOwnerKeyV1(
        pin.coordinator_epoch,
        pin.allocation_generation,
        pin.dispatch_generation,
        pin.dispatch_request_sha256,
    ) and permit.scope_index == pin.scope.node_index and
        permit.scope_generation == pin.scope.generation and
        permit.node_count == pin.allocation_count and
        std.meta.eql(permit.claim, exact_claim);
}

fn bankCompletionBindingValid(
    released: resource.LeasePinReleasedV1,
    pin: LeaseTreeDispatchPinV1,
    permit: resource.LeasePinPermitV1,
) bool {
    const completion = released.completion;
    const exact_claim: resource.Claim = .{
        .device_bytes = pin.pinned_device_bytes,
    };
    return bankPermitForDispatchPinValid(permit, pin) and
        resource.leasePinCompletionIntegrityValidV1(
            completion,
        ) and std.meta.eql(
        released.tree.parent,
        completion.parent,
    ) and released.tree.tree_key == completion.tree_key and
        released.tree.identity_generation ==
            completion.tree_identity_generation and
        released.tree.generation ==
            completion.completion_tree_generation and
        released.tree.structural_revision ==
            completion.completion_structural_revision and
        released.tree.state_digest ==
            completion.completion_state_digest and
        released.tree.integrity ==
            completion.completion_tree_integrity and
        digestEqual(
            pin.parent_receipt_sha256,
            allocation.resourceReceiptRootV1(completion.parent),
        ) and std.meta.eql(completion.parent, permit.parent) and
        completion.tree_key == permit.tree_key and
        completion.tree_identity_generation ==
            permit.tree_identity_generation and
        completion.pin_slot_index == permit.pin_slot_index and
        completion.reserved == permit.reserved and
        completion.permit_generation == permit.generation and
        completion.completion_generation ==
            permit.completion_generation and
        completion.request_epoch == permit.request_epoch and
        completion.session_id == permit.session_id and
        completion.sequence == permit.sequence and
        completion.owner_key == permit.owner_key and
        completion.scope_index == permit.scope_index and
        completion.scope_generation == permit.scope_generation and
        completion.node_count == permit.node_count and
        std.meta.eql(completion.claim, permit.claim) and
        completion.node_set_digest == permit.node_set_digest and
        completion.permit_integrity == permit.integrity and
        completion.scope_index == pin.scope.node_index and
        completion.scope_generation == pin.scope.generation and
        completion.node_count == pin.allocation_count and
        std.meta.eql(completion.claim, exact_claim);
}

fn treeScopeBindingValid(
    tree: resource.LeaseTreeV1,
    scope: resource.LeaseNodeV1,
    parent_receipt_sha256: Digest,
) bool {
    return resource.leaseTreeIntegrityValidV1(tree) and
        resource.leaseNodeIntegrityValidV1(scope) and
        tree.tree_key != 0 and tree.authority_key != 0 and
        tree.identity_generation != 0 and
        tree.generation > tree.identity_generation and
        tree.structural_revision != 0 and
        tree.active_nodes != 0 and !tree.ceiling.isZero() and
        claimWithin(tree.current, tree.ceiling) and
        std.meta.eql(scope.parent, tree.parent) and
        scope.tree_key == tree.tree_key and
        scope.tree_identity_generation == tree.identity_generation and
        scope.node_index != std.math.maxInt(u32) and
        scope.generation != 0 and
        scope.parent_index == std.math.maxInt(u32) and
        scope.parent_generation == tree.identity_generation and
        scope.node_key != 0 and scope.tenant_key != 0 and
        scope.kind == .scope and scope.binding_key == 0 and
        scope.claim.isZero() and claimIsDeviceOnly(scope.ceiling) and
        claimWithin(scope.ceiling, tree.ceiling) and
        digestEqual(
            parent_receipt_sha256,
            allocation.resourceReceiptRootV1(tree.parent),
        );
}

fn claimWithin(
    claim: resource.Claim,
    ceiling: resource.Claim,
) bool {
    inline for (std.meta.fields(resource.Claim)) |field|
        if (@field(claim, field.name) >
            @field(ceiling, field.name))
            return false;
    return true;
}

fn deviceBytesCanBeRestored(
    current: u64,
    returned: u64,
    ceiling: u64,
) bool {
    return current <= ceiling and
        returned <= ceiling - current;
}

fn claimIsDeviceOnly(claim: resource.Claim) bool {
    return claim.device_bytes != 0 and
        claim.capsule_bytes == 0 and
        claim.kv_bytes == 0 and
        claim.activation_bytes == 0 and
        claim.partial_bytes == 0 and
        claim.logits_bytes == 0 and
        claim.output_journal_bytes == 0 and
        claim.staging_bytes == 0 and
        claim.io_bytes == 0 and
        claim.queue_slots == 0;
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource.Claim,
) void {
    inline for (std.meta.fields(resource.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
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

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

const TestFixture = struct {
    inventory: [3]device.DeviceInventoryEntryV1,
    requirement: device.DeviceRequirementV1,
    selection: device.DeviceSelectionReceiptV1,
    entries: [3]allocation.AllocationEntryV1,
    manifest: allocation.AllocationManifestV1,
    authority: allocation.AllocationAuthorityV1,
};

const test_session_id: usize = 0x4754_5345;
const test_request_epoch: u64 = 61;

const TestHarness = struct {
    slots: [1]resource.Slot = [_]resource.Slot{.{}},
    roots: [1]resource.LeaseTreeRootSlot =
        [_]resource.LeaseTreeRootSlot{.{}},
    nodes: [4]resource.LeaseNodeSlot =
        [_]resource.LeaseNodeSlot{.{}} ** 4,
    pin_slots: [2]resource.LeasePinSlotV1 =
        [_]resource.LeasePinSlotV1{.{}} ** 2,
    bank: resource.Bank = undefined,
    parent: resource.Receipt = undefined,
    tree: resource.LeaseTreeV1 = undefined,
    scope: resource.LeaseNodeV1 = undefined,
    sequence: u64 = 0,
    fake_objects: [3]allocation.FakeObjectSlotV1 =
        [_]allocation.FakeObjectSlotV1{.{}} ** 3,
    backend: allocation.FakeBackendV1 = undefined,
    coordinator_objects: [3]CoordinatorObjectSlotV1 =
        [_]CoordinatorObjectSlotV1{.{}} ** 3,
    coordinator_dispatches: [2]CoordinatorDispatchSlotV1 =
        [_]CoordinatorDispatchSlotV1{.{}} ** 2,
    coordinator: CoordinatorV1 = .{},
    fixture: TestFixture = undefined,

    fn init(self: *@This()) !void {
        return self.initMode(0, false);
    }

    fn initDispatch(self: *@This()) !void {
        return self.initMode(2, true);
    }

    fn initDispatchOne(self: *@This()) !void {
        return self.initMode(1, true);
    }

    fn initDispatchWithoutBankPins(self: *@This()) !void {
        return self.initMode(2, false);
    }

    fn initMode(
        self: *@This(),
        dispatch_slot_count: usize,
        bank_pins: bool,
    ) !void {
        if (dispatch_slot_count >
            self.coordinator_dispatches.len)
            return error.TestInvalidDispatchSlotCount;
        const queue_slots: u64 =
            if (dispatch_slot_count == 0)
                1
            else
                @intCast(dispatch_slot_count);
        self.fixture =
            try makeTestFixtureWithQueueSlots(queue_slots);
        const limits: resource.Limits = .{
            .host_bytes = 1_024,
            .capsule_bytes = 1_024,
            .device_bytes = self.fixture.manifest.total_charged_bytes,
            .queue_slots = queue_slots,
        };
        self.bank = if (bank_pins)
            try resource.Bank.initWithLeaseTreePinStorage(
                &self.slots,
                &self.roots,
                &self.nodes,
                &self.pin_slots,
                limits,
                41,
            )
        else
            try resource.Bank.initWithLeaseTreeStorage(
                &self.slots,
                &self.roots,
                &self.nodes,
                limits,
                41,
            );
        self.parent = try self.bank.commit(
            try self.bank.reserve(
                9001,
                .{
                    .capsule_bytes = 64,
                    .queue_slots = queue_slots,
                },
            ),
        );
        const opened = try self.bank.openLeaseTree(
            self.parent,
            0x6465_7669_6365,
            0x6175_7468_6f72,
            .{
                .device_bytes = self.fixture.manifest.total_charged_bytes,
            },
        );
        const scoped = try self.bank.openLeaseScope(
            opened,
            0x616c_6c6f_6361,
            0x7465_6e61_6e74,
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
        if (dispatch_slot_count != 0) {
            try self.coordinator.initWithDispatchStorage(
                0x434f_4f52_4449_4e41,
                &self.bank,
                &self.tree,
                self.scope,
                test_request_epoch,
                test_session_id,
                &self.sequence,
                &self.coordinator_objects,
                self.coordinator_dispatches[0..dispatch_slot_count],
            );
        } else {
            try self.coordinator.init(
                0x434f_4f52_4449_4e41,
                &self.bank,
                &self.tree,
                self.scope,
                test_request_epoch,
                test_session_id,
                &self.sequence,
                &self.coordinator_objects,
            );
        }
    }

    fn request(
        self: *@This(),
    ) !allocation.AllocationRequestV1 {
        return allocation.makeRequestV1(
            test_request_epoch,
            testDigest("allocation request owner"),
            self.fixture.authority,
            self.fixture.selection,
            self.fixture.requirement,
            &self.fixture.inventory,
            self.parent,
            self.fixture.manifest,
            &self.fixture.entries,
        );
    }

    fn admit(
        self: *@This(),
    ) !LeaseTreeAllocationAdmissionV1 {
        return self.coordinator.admit(
            self.backend.adapter(),
            try self.request(),
            self.fixture.selection,
            self.fixture.requirement,
            &self.fixture.inventory,
            self.parent,
            self.fixture.manifest,
            &self.fixture.entries,
        );
    }

    fn close(self: *@This()) !void {
        try self.bank.closePublicationSession(
            self.parent,
            test_request_epoch,
            test_session_id,
            self.sequence,
        );
        try self.bank.closeLeaseTree(self.tree);
        try self.bank.release(self.parent);
        try std.testing.expect((try self.bank.snapshot()).used.isZero());
    }
};

const TestDispatchAdapter = struct {
    dispatch_authority_sha256: Digest = zero_digest,
    queue_authority_sha256: Digest = zero_digest,
    expected_terminal_sha256: Digest = zero_digest,
    reject_intent: bool = false,
    reject_terminal: bool = false,
    reject_settlement: bool = false,
    intent_reserve_count: u64 = 0,
    intent_abort_count: u64 = 0,
    callback_count: u64 = 0,
    settlement_callback_count: u64 = 0,
    coordinator_to_drift: ?*CoordinatorV1 = null,
    drift_bank: ?*resource.Bank = null,
    abort_drift_bank: ?*resource.Bank = null,

    fn interface(self: *@This()) DispatchAdapterV1 {
        return .{
            .context = self,
            .dispatch_authority_sha256 = if (digestIsZero(self.dispatch_authority_sha256))
                testDigest("test dispatch authority")
            else
                self.dispatch_authority_sha256,
            .queue_authority_sha256 = if (digestIsZero(self.queue_authority_sha256))
                testDigest("test dispatch queue authority")
            else
                self.queue_authority_sha256,
            .reserve_dispatch_intent_fn = reserveDispatchIntent,
            .abort_dispatch_intent_fn = abortDispatchIntent,
            .validate_terminal_fn = validateTerminal,
            .confirm_settlement_fn = confirmSettlement,
        };
    }

    fn expect(self: *@This(), terminal: DispatchTerminalEvidenceV1) void {
        self.expected_terminal_sha256 = terminal.terminal_sha256;
    }

    fn reserveDispatchIntent(
        context: *anyopaque,
        intent: DispatchPinIntentV1,
    ) DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.intent_reserve_count += 1;
        if (self.coordinator_to_drift) |coordinator| {
            if (self.drift_bank) |bank| coordinator.bank = bank;
        }
        validateDispatchPinIntentV1(intent) catch
            return DispatchCallbackError.InvalidDispatchIntent;
        if (self.reject_intent)
            return DispatchCallbackError.InvalidDispatchIntent;
    }

    fn abortDispatchIntent(
        context: *anyopaque,
        intent: DispatchPinIntentV1,
    ) DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.intent_abort_count += 1;
        if (self.coordinator_to_drift) |coordinator| {
            if (self.abort_drift_bank) |bank|
                coordinator.bank = bank;
        }
        validateDispatchPinIntentV1(intent) catch
            return DispatchCallbackError.InvalidDispatchIntent;
    }

    fn validateTerminal(
        context: *anyopaque,
        terminal: DispatchTerminalEvidenceV1,
    ) DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.callback_count += 1;
        if (self.coordinator_to_drift) |coordinator| {
            if (self.drift_bank) |bank| coordinator.bank = bank;
        }
        if (self.reject_terminal or
            digestIsZero(self.expected_terminal_sha256) or
            !digestEqual(
                terminal.terminal_sha256,
                self.expected_terminal_sha256,
            ))
            return DispatchCallbackError.InvalidTerminalEvidence;
    }

    fn confirmSettlement(
        context: *anyopaque,
        pin: LeaseTreeDispatchPinV1,
        terminal: DispatchTerminalEvidenceV1,
        completion: LeaseTreeDispatchCompletionV1,
        bank_permit: resource.LeasePinPermitV1,
        bank_completion: resource.LeasePinCompletionV1,
    ) DispatchCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.settlement_callback_count += 1;
        if (self.reject_settlement)
            return DispatchCallbackError.InvalidSettlementEvidence;
        validateDispatchSettlementForPinV1(
            completion,
            pin,
            terminal,
            bank_permit,
            bank_completion,
        ) catch return DispatchCallbackError.InvalidSettlementEvidence;
        if (digestIsZero(self.expected_terminal_sha256) or
            !digestEqual(
                terminal.terminal_sha256,
                self.expected_terminal_sha256,
            ))
            return DispatchCallbackError.InvalidSettlementEvidence;
    }
};

fn materializeTestLease(
    harness: *TestHarness,
) !LeaseTreeDeviceAllocationLeaseV1 {
    const admission = try harness.admit();
    const materialized = try harness.coordinator.materialize(
        admission,
        harness.backend.adapter(),
        .{},
    );
    return switch (materialized) {
        .active => |lease| lease,
        else => error.TestUnexpectedResult,
    };
}

const TestRetirementBindingObserver = struct {
    expected_lease: LeaseTreeDeviceAllocationLeaseV1,
    expected_object_set: allocation.BackendObjectSetV1,
    callback_count: u64 = 0,

    fn interface(
        self: *@This(),
        adapter: allocation.AdapterV1,
    ) RetirementBindingAdapterV1 {
        return .{
            .context = self,
            .allocation_adapter = adapter,
            .arm_fn = callback,
        };
    }

    fn callback(
        context: *anyopaque,
        retained_lease: LeaseTreeDeviceAllocationLeaseV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) RetirementBindingCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        allocation.validateObjectSetForAdmissionRootV1(
            retained_object_set,
            retained_lease.admission_sha256,
            retained_lease.authority_sha256,
            retained_lease.allocation_count,
            retained_lease.materialized_bytes,
            retained_calls,
            retained_objects,
        ) catch return error.InvalidRetirementBinding;
        if (!std.meta.eql(retained_lease, self.expected_lease) or
            !std.meta.eql(
                retained_object_set,
                self.expected_object_set,
            ))
            return error.InvalidRetirementBinding;
        self.callback_count += 1;
    }
};

const TestActiveDispatchReconciliationObserver = struct {
    const Failure = enum {
        none,
        invalid,
        busy,
        unavailable,
    };

    expected_lease: LeaseTreeDeviceAllocationLeaseV1,
    expected_pin: LeaseTreeDispatchPinV1,
    expected_intent: DispatchPinIntentV1,
    expected_object_set: allocation.BackendObjectSetV1,
    callback_count: u64 = 0,
    failure: Failure = .none,
    coordinator_to_mutate: ?*CoordinatorV1 = null,

    fn interface(
        self: *@This(),
        dispatch_adapter: DispatchAdapterV1,
    ) ActiveDispatchReconciliationBindingV1 {
        return .{
            .context = self,
            .dispatch_adapter = dispatch_adapter,
            .reconcile_fn = callback,
        };
    }

    fn callback(
        context: *anyopaque,
        retained_lease: LeaseTreeDeviceAllocationLeaseV1,
        retained_pin: LeaseTreeDispatchPinV1,
        retained_intent: DispatchPinIntentV1,
        retained_object_set: allocation.BackendObjectSetV1,
        retained_calls: []const allocation.AllocationCallV1,
        retained_objects: []const allocation.BackendObjectV1,
    ) ActiveDispatchReconciliationBindingCallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        validateDispatchPinForIntentV1(
            retained_pin,
            retained_intent,
        ) catch return error.InvalidReconciliationBinding;
        allocation.validateObjectSetForAdmissionRootV1(
            retained_object_set,
            retained_lease.admission_sha256,
            retained_lease.authority_sha256,
            retained_lease.allocation_count,
            retained_lease.materialized_bytes,
            retained_calls,
            retained_objects,
        ) catch return error.InvalidReconciliationBinding;
        if (!std.meta.eql(retained_lease, self.expected_lease) or
            !std.meta.eql(retained_pin, self.expected_pin) or
            !std.meta.eql(retained_intent, self.expected_intent) or
            !std.meta.eql(
                retained_object_set,
                self.expected_object_set,
            ))
            return error.InvalidReconciliationBinding;
        self.callback_count += 1;
        if (self.coordinator_to_mutate) |coordinator|
            coordinator.next_dispatch_generation += 7;
        return switch (self.failure) {
            .none => {},
            .invalid => error.InvalidReconciliationBinding,
            .busy => error.Busy,
            .unavailable => error.Unavailable,
        };
    }
};

test "active dispatch reconciliation binds exact retained pin without permit authority" {
    var harness: TestHarness = .{};
    try harness.initDispatchOne();
    const lease = try materializeTestLease(&harness);
    var dispatch: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("active reconciliation request"),
    );
    const retained_intent =
        harness.coordinator_dispatches[0].intent.?;
    const permit =
        harness.coordinator_dispatches[0].bank_permit.?;
    var observer: TestActiveDispatchReconciliationObserver = .{
        .expected_lease = lease,
        .expected_pin = pin,
        .expected_intent = retained_intent,
        .expected_object_set = harness.coordinator.object_set,
    };

    try harness.coordinator
        .withActiveDispatchReconciliationBindingV1(
        lease,
        pin,
        observer.interface(dispatch.interface()),
    );
    try std.testing.expectEqual(@as(u64, 1), observer.callback_count);
    try harness.bank.validateLeasePin(permit);
    try std.testing.expectEqual(
        DispatchSlotStateV1.pinned,
        harness.coordinator_dispatches[0].state,
    );
    try std.testing.expect(
        harness.coordinator_dispatches[0].terminal == null,
    );
    try std.testing.expect(
        harness.coordinator_dispatches[0].completion == null,
    );
    try std.testing.expect(
        harness.coordinator_dispatches[0].bank_completion == null,
    );

    var resealed_pin = pin;
    resealed_pin.dispatch_request_sha256 =
        testDigest("foreign resealed reconciliation request");
    resealed_pin.pin_sha256 = dispatchPinRootV1(resealed_pin);
    try validateDispatchPinV1(resealed_pin);
    try std.testing.expectError(
        Error.InvalidDispatchPin,
        harness.coordinator
            .withActiveDispatchReconciliationBindingV1(
            lease,
            resealed_pin,
            observer.interface(dispatch.interface()),
        ),
    );

    var foreign_dispatch: TestDispatchAdapter = .{};
    try std.testing.expectError(
        Error.InvalidDispatchAdapter,
        harness.coordinator
            .withActiveDispatchReconciliationBindingV1(
            lease,
            pin,
            observer.interface(foreign_dispatch.interface()),
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), observer.callback_count);

    const slot_before_failure =
        harness.coordinator_dispatches[0];
    const tree_before_failure = harness.tree;
    const bank_before_failure = try harness.bank.snapshotV3();
    const next_dispatch_generation_before_failure =
        harness.coordinator.next_dispatch_generation;
    observer.failure = .invalid;
    observer.coordinator_to_mutate = &harness.coordinator;
    try std.testing.expectError(
        Error.InvalidDispatchReconciliationBinding,
        harness.coordinator
            .withActiveDispatchReconciliationBindingV1(
            lease,
            pin,
            observer.interface(dispatch.interface()),
        ),
    );
    try std.testing.expectEqual(@as(u64, 2), observer.callback_count);
    try std.testing.expectEqualDeep(
        slot_before_failure,
        harness.coordinator_dispatches[0],
    );
    try std.testing.expectEqualDeep(
        tree_before_failure,
        harness.tree,
    );
    try std.testing.expectEqualDeep(
        bank_before_failure,
        try harness.bank.snapshotV3(),
    );
    try std.testing.expectEqual(
        next_dispatch_generation_before_failure,
        harness.coordinator.next_dispatch_generation,
    );
    try harness.bank.validateLeasePin(permit);

    observer.coordinator_to_mutate = null;
    const terminal = try makeDispatchTerminalV1(
        pin,
        .succeeded,
        testDigest("active reconciliation submission"),
        testDigest("active reconciliation completion"),
        testDigest("active reconciliation output"),
    );
    dispatch.expect(terminal);
    _ = try harness.coordinator.completeDispatchPin(
        pin,
        dispatch.interface(),
        terminal,
    );
    _ = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    try harness.close();
}

test "active dispatch reconciliation rejects settlement pending without callback" {
    var harness: TestHarness = .{};
    try harness.initDispatchOne();
    const lease = try materializeTestLease(&harness);
    var dispatch: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("settlement pending reconciliation request"),
    );
    const retained_intent =
        harness.coordinator_dispatches[0].intent.?;
    const terminal = try makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        testDigest("settlement pending submission"),
        testDigest("settlement pending completion"),
        zero_digest,
    );
    dispatch.expect(terminal);
    dispatch.reject_settlement = true;
    try std.testing.expectError(
        Error.InvalidDispatchCompletion,
        harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        ),
    );
    var observer: TestActiveDispatchReconciliationObserver = .{
        .expected_lease = lease,
        .expected_pin = pin,
        .expected_intent = retained_intent,
        .expected_object_set = harness.coordinator.object_set,
    };
    const slot_before =
        harness.coordinator_dispatches[0];
    const tree_before = harness.tree;
    const bank_before = try harness.bank.snapshotV3();
    try std.testing.expectError(
        Error.InvalidDispatchReconciliationBinding,
        harness.coordinator
            .withActiveDispatchReconciliationBindingV1(
            lease,
            pin,
            observer.interface(dispatch.interface()),
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), observer.callback_count);
    try std.testing.expectEqualDeep(
        slot_before,
        harness.coordinator_dispatches[0],
    );
    try std.testing.expectEqualDeep(tree_before, harness.tree);
    try std.testing.expectEqualDeep(
        bank_before,
        try harness.bank.snapshotV3(),
    );

    dispatch.reject_settlement = false;
    _ = try harness.coordinator.completeDispatchPin(
        pin,
        dispatch.interface(),
        terminal,
    );
    _ = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    try harness.close();
}

test "quiesced retirement binding uses exact coordinator lease and adapter" {
    var harness: TestHarness = .{};
    try harness.init();
    const lease = try materializeTestLease(&harness);
    var observer: TestRetirementBindingObserver = .{
        .expected_lease = lease,
        .expected_object_set = harness.coordinator.object_set,
    };
    try harness.coordinator.withQuiescedRetirementBindingV1(
        lease,
        observer.interface(harness.backend.adapter()),
    );
    try std.testing.expectEqual(@as(u64, 1), observer.callback_count);

    const mutations = [_]struct {
        field: enum { object_set, leaf_set, request },
        digest: Digest,
    }{
        .{
            .field = .object_set,
            .digest = testDigest("forged retirement object set"),
        },
        .{
            .field = .leaf_set,
            .digest = testDigest("forged retirement leaf set"),
        },
        .{
            .field = .request,
            .digest = testDigest("forged retirement request"),
        },
    };
    for (mutations) |mutation| {
        var forged = lease;
        switch (mutation.field) {
            .object_set => forged.backend_object_set_sha256 = mutation.digest,
            .leaf_set => forged.allocation_leaf_set_sha256 = mutation.digest,
            .request => forged.request_sha256 = mutation.digest,
        }
        forged.lease_sha256 = leaseRootV1(forged);
        try validateLeaseV1(forged);
        try std.testing.expectError(
            Error.InvalidTransition,
            harness.coordinator.withQuiescedRetirementBindingV1(
                forged,
                observer.interface(harness.backend.adapter()),
            ),
        );
    }
    try std.testing.expectEqual(@as(u64, 1), observer.callback_count);

    var foreign = CountingQuoteAdapter{
        .inner = harness.backend.adapter(),
    };
    try std.testing.expectError(
        allocation.Error.InvalidAdapter,
        harness.coordinator.withQuiescedRetirementBindingV1(
            lease,
            observer.interface(foreign.interface()),
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), observer.callback_count);

    const released = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    _ = switch (released) {
        .terminal => |terminal| terminal,
        else => return error.TestUnexpectedResult,
    };
    try harness.close();
}

test "quiesced retirement binding rejects an active dispatch pin" {
    var harness: TestHarness = .{};
    try harness.initDispatchOne();
    const lease = try materializeTestLease(&harness);
    var observer: TestRetirementBindingObserver = .{
        .expected_lease = lease,
        .expected_object_set = harness.coordinator.object_set,
    };
    var dispatch: TestDispatchAdapter = .{};
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("retirement active dispatch request"),
    );
    try std.testing.expectError(
        Error.DispatchInFlight,
        harness.coordinator.withQuiescedRetirementBindingV1(
            lease,
            observer.interface(harness.backend.adapter()),
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), observer.callback_count);

    const terminal = try makeDispatchTerminalV1(
        pin,
        .succeeded,
        testDigest("retirement active submission"),
        testDigest("retirement active completion"),
        testDigest("retirement active output"),
    );
    dispatch.expect(terminal);
    _ = try harness.coordinator.completeDispatchPin(
        pin,
        dispatch.interface(),
        terminal,
    );
    const released = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    _ = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try harness.close();
}

const CancelAtBoundary = struct {
    boundary: u64,

    fn callback(context: *anyopaque, boundary: u64) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return boundary == self.boundary;
    }

    fn probe(self: *@This()) allocation.CancellationProbeV1 {
        return .{
            .context = self,
            .cancelled_fn = callback,
        };
    }
};

const BlockingQuoteAdapter = struct {
    inner: allocation.AdapterV1,
    entered: std.atomic.Value(bool) =
        std.atomic.Value(bool).init(false),
    proceed: std.atomic.Value(bool) =
        std.atomic.Value(bool).init(false),
    blocked_once: bool = false,

    fn interface(self: *@This()) allocation.AdapterV1 {
        return .{
            .context = self,
            .authority = self.inner.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (!self.blocked_once) {
            self.blocked_once = true;
            self.entered.store(true, .release);
            while (!self.proceed.load(.acquire))
                std.atomic.spinLoopHint();
        }
        return self.inner.quote_fn(
            self.inner.context,
            binding_sha256,
            requested_bytes,
        );
    }

    fn allocateCallback(
        context: *anyopaque,
        call: allocation.AllocationCallV1,
    ) allocation.CallbackError!allocation.BackendObjectV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.allocate_fn(self.inner.context, call);
    }

    fn freeCallback(
        context: *anyopaque,
        object: allocation.BackendObjectV1,
    ) allocation.CallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.free_fn(self.inner.context, object);
    }
};

const CountingQuoteAdapter = struct {
    inner: allocation.AdapterV1,
    quote_calls: u64 = 0,

    fn interface(self: *@This()) allocation.AdapterV1 {
        return .{
            .context = self,
            .authority = self.inner.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.quote_calls += 1;
        return self.inner.quote_fn(
            self.inner.context,
            binding_sha256,
            requested_bytes,
        );
    }

    fn allocateCallback(
        context: *anyopaque,
        call: allocation.AllocationCallV1,
    ) allocation.CallbackError!allocation.BackendObjectV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.allocate_fn(self.inner.context, call);
    }

    fn freeCallback(
        context: *anyopaque,
        object: allocation.BackendObjectV1,
    ) allocation.CallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.free_fn(self.inner.context, object);
    }
};

const CallbackDriftAdapter = struct {
    inner: allocation.AdapterV1,
    coordinator: *CoordinatorV1,
    allocation_callbacks: u64 = 0,
    free_callbacks: u64 = 0,

    fn interface(self: *@This()) allocation.AdapterV1 {
        return .{
            .context = self,
            .authority = self.inner.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.quote_fn(
            self.inner.context,
            binding_sha256,
            requested_bytes,
        );
    }

    fn allocateCallback(
        context: *anyopaque,
        call: allocation.AllocationCallV1,
    ) allocation.CallbackError!allocation.BackendObjectV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        const object = try self.inner.allocate_fn(
            self.inner.context,
            call,
        );
        self.allocation_callbacks += 1;
        self.coordinator.request.request_sha256[0] ^= 1;
        self.coordinator.batch = null;
        self.coordinator.generation +%= 1;
        self.coordinator.publication_sequence.* +%= 1;
        if (call.ordinal == 0) {
            self.coordinator.objects[1].entry =
                self.coordinator.objects[2].entry;
            self.coordinator.objects[1].leaf =
                self.coordinator.objects[2].leaf;
        } else if (call.ordinal == 1) {
            self.coordinator.objects[0].call.binding_sha256[0] ^= 1;
            self.coordinator.objects[0].object.object_sha256[0] ^= 1;
        }
        return object;
    }

    fn freeCallback(
        context: *anyopaque,
        object: allocation.BackendObjectV1,
    ) allocation.CallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        try self.inner.free_fn(self.inner.context, object);
        self.free_callbacks += 1;
        self.coordinator.target_outcome = .cancelled;
        self.coordinator.target_reason = .explicit_cancellation;
        self.coordinator.generation +%= 1;
        self.coordinator.publication_sequence.* +%= 1;
        if (self.free_callbacks == 1) {
            self.coordinator.objects[1].call =
                self.coordinator.objects[2].call;
            self.coordinator.objects[1].object =
                self.coordinator.objects[2].object;
        }
    }
};

const SettlementFaultAdapter = struct {
    inner: allocation.AdapterV1,
    bank: *resource.Bank,
    fault_bank: *resource.Bank,
    coordinator: *CoordinatorV1,
    expected_device_bytes: u64,
    free_calls: u64 = 0,
    ordering_violation: bool = false,

    fn interface(self: *@This()) allocation.AdapterV1 {
        return .{
            .context = self,
            .authority = self.inner.authority,
            .quote_fn = quoteCallback,
            .allocate_fn = allocateCallback,
            .free_fn = freeCallback,
        };
    }

    fn quoteCallback(
        context: *anyopaque,
        binding_sha256: Digest,
        requested_bytes: u64,
    ) allocation.CallbackError!allocation.AllocationQuoteV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.quote_fn(
            self.inner.context,
            binding_sha256,
            requested_bytes,
        );
    }

    fn allocateCallback(
        context: *anyopaque,
        call: allocation.AllocationCallV1,
    ) allocation.CallbackError!allocation.BackendObjectV1 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.inner.allocate_fn(self.inner.context, call);
    }

    fn freeCallback(
        context: *anyopaque,
        object: allocation.BackendObjectV1,
    ) allocation.CallbackError!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        const snapshot = self.bank.snapshotV3() catch {
            self.ordering_violation = true;
            return allocation.CallbackError.Unavailable;
        };
        if (snapshot.used.device_bytes != self.expected_device_bytes or
            snapshot.free_authorized_allocations != 3)
            self.ordering_violation = true;
        try self.inner.free_fn(self.inner.context, object);
        self.free_calls += 1;
        if (self.free_calls == 3)
            self.coordinator.bank = self.fault_bank;
    }
};

fn makeTestFixture() !TestFixture {
    return makeTestFixtureWithQueueSlots(1);
}

fn makeTestFixtureWithQueueSlots(
    queue_slots: u64,
) !TestFixture {
    if (queue_slots == 0)
        return error.TestInvalidQueueSlots;
    const makeCapability = struct {
        fn call(
            backend: device.BackendKindV1,
            class: device.DeviceClassV1,
            label: []const u8,
            capability_queue_slots: u64,
        ) !device.DeviceCapabilityV1 {
            const profiles =
                device.OperationProfileBitsV1.dequantize_int4_f16 |
                device.OperationProfileBitsV1.matmul_f16_bounded |
                device.OperationProfileBitsV1.matvec_int4_f32_bounded;
            return device.sealCapabilityV1(.{
                .backend_kind = backend,
                .device_class = class,
                .operation_profile_bits = profiles,
                .operator_bits = device.profileOperatorBitsV1(profiles),
                .element_type_bits = device.profileElementTypeBitsV1(profiles),
                .numerical_policy_bits = device.profileNumericalPolicyBitsV1(profiles),
                .feature_bits = device.FeatureBitsV1.allocation |
                    device.FeatureBitsV1.dispatch |
                    device.FeatureBitsV1.completion_fence,
                .max_single_allocation_bytes = 4_096,
                .max_total_device_bytes = 8_192,
                .max_queue_slots = capability_queue_slots,
                .backend_sha256 = testDigest("test allocation backend"),
                .device_sha256 = testDigest(label),
                .driver_sha256 = testDigest("test allocation driver"),
                .placement_sha256 = testDigest("test allocation placement"),
            });
        }
    }.call;
    const makeInventoryEntry = struct {
        fn call(
            capability: device.DeviceCapabilityV1,
            epoch: u64,
            rank: u64,
        ) !device.DeviceInventoryEntryV1 {
            return device.sealInventoryEntryV1(.{
                .discovery_epoch = epoch,
                .policy_rank = rank,
                .capability = capability,
            });
        }
    }.call;
    const gpu_a = try makeCapability(
        .metal,
        .accelerator,
        "lease gpu a",
        queue_slots,
    );
    const gpu_b = try makeCapability(
        .portable_compute,
        .accelerator,
        "lease gpu b",
        queue_slots,
    );
    const cpu = try makeCapability(
        .cpu,
        .cpu,
        "lease cpu",
        queue_slots,
    );
    const inventory = [3]device.DeviceInventoryEntryV1{
        try makeInventoryEntry(gpu_a, 10, 5),
        try makeInventoryEntry(gpu_b, 20, 1),
        try makeInventoryEntry(cpu, 30, 0),
    };
    const profiles =
        device.OperationProfileBitsV1.dequantize_int4_f16 |
        device.OperationProfileBitsV1.matmul_f16_bounded |
        device.OperationProfileBitsV1.matvec_int4_f32_bounded;
    const requirement = try device.sealRequirementV1(.{
        .plan_sha256 = testDigest("device allocation execution plan"),
        .required_device_class = .accelerator,
        .required_operation_profile_bits = profiles,
        .required_operator_bits = device.profileOperatorBitsV1(profiles),
        .required_element_type_bits = device.profileElementTypeBitsV1(profiles),
        .required_numerical_policy_bits = device.profileNumericalPolicyBitsV1(profiles),
        .required_feature_bits = device.FeatureBitsV1.allocation,
        .largest_single_allocation_bytes = 4_096,
        .total_device_bytes = 8_192,
        .queue_slots = queue_slots,
        .fallback_policy = .explicit_cpu,
    });
    const selection = try device.selectDeviceV1(
        requirement,
        &inventory,
    );
    const authority = try allocation.makeAuthorityV1(
        77,
        1,
        3,
        1_024,
        inventory[selection.selected_index],
        testDigest("fake allocation authority"),
    );
    var entries = [3]allocation.AllocationEntryV1{
        .{
            .binding_sha256 = testDigest("activation allocation"),
            .requested_bytes = 1_000,
        },
        .{
            .binding_sha256 = testDigest("kv allocation"),
            .requested_bytes = 3_000,
        },
        .{
            .binding_sha256 = testDigest("weight allocation"),
            .requested_bytes = 4_000,
        },
    };
    for (&entries) |*entry| {
        const quote = try allocation.makeFakeQuoteV1(
            authority,
            entry.binding_sha256,
            entry.requested_bytes,
        );
        entry.charged_bytes = quote.charged_bytes;
        entry.quote_sha256 = quote.quote_sha256;
    }
    std.mem.sort(
        allocation.AllocationEntryV1,
        &entries,
        {},
        struct {
            fn lessThan(
                _: void,
                left: allocation.AllocationEntryV1,
                right: allocation.AllocationEntryV1,
            ) bool {
                return std.mem.order(
                    u8,
                    &left.binding_sha256,
                    &right.binding_sha256,
                ) == .lt;
            }
        }.lessThan,
    );
    const manifest = try allocation.sealManifestV1(&entries);
    return .{
        .inventory = inventory,
        .requirement = requirement,
        .selection = selection.receipt,
        .entries = entries,
        .manifest = manifest,
        .authority = authority,
    };
}

fn testDigest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn resealTestLeaseNode(
    node: resource.LeaseNodeV1,
) resource.LeaseNodeV1 {
    var result = node;
    var integrity = testMix64(
        0x6c65_6173_656e_6431 ^ result.parent.integrity,
    );
    integrity = testMix64(integrity ^ result.tree_key);
    integrity = testMix64(
        integrity ^ result.tree_identity_generation,
    );
    integrity = testMix64(
        integrity ^ @as(u64, result.node_index),
    );
    integrity = testMix64(integrity ^ result.generation);
    integrity = testMix64(
        integrity ^ @as(u64, result.parent_index),
    );
    integrity = testMix64(integrity ^ result.parent_generation);
    integrity = testMix64(integrity ^ result.node_key);
    integrity = testMix64(integrity ^ result.tenant_key);
    integrity = testMix64(integrity ^ result.binding_key);
    integrity = testMix64(
        integrity ^ @intFromEnum(result.kind),
    );
    inline for (std.meta.fields(resource.Claim)) |field|
        integrity = testMix64(
            integrity ^ @field(result.ceiling, field.name),
        );
    inline for (std.meta.fields(resource.Claim)) |field|
        integrity = testMix64(
            integrity ^ @field(result.claim, field.name),
        );
    result.integrity = integrity;
    return result;
}

fn resealTestLeaseTree(
    tree: resource.LeaseTreeV1,
) resource.LeaseTreeV1 {
    var result = tree;
    var integrity = testMix64(
        0x6c65_6173_6574_7231 ^ result.parent.integrity,
    );
    integrity = testMix64(integrity ^ result.tree_key);
    integrity = testMix64(integrity ^ result.authority_key);
    integrity = testMix64(
        integrity ^ result.identity_generation,
    );
    integrity = testMix64(integrity ^ result.generation);
    integrity = testMix64(
        integrity ^ result.structural_revision,
    );
    inline for (std.meta.fields(resource.Claim)) |field|
        integrity = testMix64(
            integrity ^ @field(result.ceiling, field.name),
        );
    inline for (std.meta.fields(resource.Claim)) |field|
        integrity = testMix64(
            integrity ^ @field(result.current, field.name),
        );
    integrity = testMix64(
        integrity ^ @as(u64, result.active_nodes),
    );
    integrity = testMix64(integrity ^ result.state_digest);
    result.integrity = integrity;
    return result;
}

fn testMix64(value: u64) u64 {
    var mixed = value;
    mixed ^= mixed >> 30;
    mixed *%= 0xbf58_476d_1ce4_e5b9;
    mixed ^= mixed >> 27;
    mixed *%= 0x94d0_49bb_1331_11eb;
    mixed ^= mixed >> 31;
    return mixed;
}

fn expectGoldenDigest(
    encoded: []const u8,
    actual: Digest,
) !void {
    const expected = try testDigestFromHex(encoded);
    try std.testing.expectEqualDeep(expected, actual);
}

fn testDigestFromHex(encoded: []const u8) !Digest {
    var result: Digest = undefined;
    _ = try std.fmt.hexToBytes(&result, encoded);
    return result;
}

test "LeaseTree device allocation charges materializes and releases exact wave" {
    var harness: TestHarness = .{};
    try harness.init();
    const expected = harness.fixture.manifest.total_charged_bytes;
    try std.testing.expectEqual(@as(u64, 8_192), expected);

    var first_object_generations: [3]u64 = undefined;
    var first_lease: LeaseTreeDeviceAllocationLeaseV1 = undefined;
    for (0..2) |cycle| {
        const admission = try harness.admit();
        try validateAdmissionV1(admission);
        var bank_snapshot = try harness.bank.snapshotV3();
        try std.testing.expectEqual(
            expected,
            bank_snapshot.used.device_bytes,
        );
        try std.testing.expectEqual(
            @as(usize, 3),
            bank_snapshot.reserved_unmaterialized_allocations,
        );
        try std.testing.expectEqual(
            expected,
            harness.tree.current.device_bytes,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            harness.backend.snapshot().live_objects,
        );

        const materialized = try harness.coordinator.materialize(
            admission,
            harness.backend.adapter(),
            .{},
        );
        const lease = switch (materialized) {
            .active => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try validateLeaseV1(lease);
        if (cycle == 0) first_lease = lease;
        bank_snapshot = try harness.bank.snapshotV3();
        try std.testing.expectEqual(
            @as(usize, 0),
            bank_snapshot.reserved_unmaterialized_allocations,
        );
        try std.testing.expectEqual(
            @as(usize, 3),
            bank_snapshot.live_allocations,
        );
        try std.testing.expectEqual(
            @as(usize, 3),
            harness.backend.snapshot().live_objects,
        );
        for (harness.coordinator_objects, 0..) |object, ordinal| {
            if (cycle == 0) {
                first_object_generations[ordinal] =
                    object.object.backend_object_generation;
            } else {
                try std.testing.expect(
                    object.object.backend_object_generation >
                        first_object_generations[ordinal],
                );
            }
        }

        const released = try harness.coordinator.release(
            lease,
            harness.backend.adapter(),
        );
        const terminal = switch (released) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try validateTerminalReceiptV1(terminal);
        try std.testing.expectEqual(
            allocation.TerminalOutcomeV1.released,
            terminal.outcome,
        );
        try std.testing.expect(terminal.terminal_tree.current.isZero());
        bank_snapshot = try harness.bank.snapshotV3();
        try std.testing.expectEqual(
            @as(u64, 0),
            bank_snapshot.used.device_bytes,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            bank_snapshot.live_allocations,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            bank_snapshot.free_authorized_allocations,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            harness.backend.snapshot().live_objects,
        );
    }
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.release(
            first_lease,
            harness.backend.adapter(),
        ),
    );
    try harness.close();
}

test "LeaseTree allocation cancellation aborts only after reverse frees" {
    for (0..4) |boundary| {
        var harness: TestHarness = .{};
        try harness.init();
        const admission = try harness.admit();
        var cancel = CancelAtBoundary{
            .boundary = @intCast(boundary),
        };
        const outcome = try harness.coordinator.materialize(
            admission,
            harness.backend.adapter(),
            cancel.probe(),
        );
        const terminal = switch (outcome) {
            .terminal => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try validateTerminalReceiptV1(terminal);
        try std.testing.expectEqual(
            allocation.TerminalOutcomeV1.cancelled,
            terminal.outcome,
        );
        const bank_snapshot = try harness.bank.snapshotV3();
        try std.testing.expectEqual(
            @as(u64, 0),
            bank_snapshot.used.device_bytes,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            bank_snapshot.reserved_unmaterialized_allocations,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            harness.backend.snapshot().live_objects,
        );
        try harness.close();
    }
}

test "LeaseTree malformed cancellation probe preserves cancellable reservation" {
    var harness: TestHarness = .{};
    try harness.init();
    const admission = try harness.admit();
    try std.testing.expectError(
        Error.InvalidConfiguration,
        harness.coordinator.materialize(
            admission,
            harness.backend.adapter(),
            .{ .cancelled_fn = CancelAtBoundary.callback },
        ),
    );
    var bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 8_192),
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        bank_snapshot.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        harness.backend.snapshot().allocate_calls,
    );
    const terminal = try harness.coordinator.cancelAdmission(
        admission,
    );
    try validateTerminalReceiptV1(terminal);
    bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        bank_snapshot.used.device_bytes,
    );
    try harness.close();
}

test "LeaseTree coordinator address and adapter instance are exact" {
    var harness: TestHarness = .{};
    try harness.init();
    var copied = harness.coordinator;
    try std.testing.expectError(
        Error.InvalidCoordinator,
        copied.snapshot(),
    );
    var rebound_objects =
        [_]CoordinatorObjectSlotV1{.{}} ** 3;
    const original_objects = harness.coordinator.objects;
    harness.coordinator.objects = &rebound_objects;
    try std.testing.expectError(
        Error.InvalidCoordinator,
        harness.coordinator.snapshot(),
    );
    harness.coordinator.objects = original_objects;
    const original_scope = harness.coordinator.scope;
    harness.coordinator.scope.generation +%= 1;
    try std.testing.expectError(
        Error.InvalidCoordinator,
        harness.coordinator.snapshot(),
    );
    harness.coordinator.scope = original_scope;
    const admission = try harness.admit();
    var foreign_objects =
        [_]allocation.FakeObjectSlotV1{.{}} ** 3;
    var foreign_backend = try allocation.FakeBackendV1.init(
        harness.fixture.authority,
        &foreign_objects,
    );
    try std.testing.expectError(
        Error.InvalidAdapter,
        harness.coordinator.materialize(
            admission,
            foreign_backend.adapter(),
            .{},
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        harness.backend.snapshot().allocate_calls,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        foreign_backend.snapshot().allocate_calls,
    );
    _ = try harness.coordinator.cancelAdmission(admission);
    try harness.close();
}

test "LeaseTree admission requires one exact fixed object slot per entry" {
    var harness: TestHarness = .{};
    try harness.init();
    var oversized_objects =
        [_]CoordinatorObjectSlotV1{.{}} ** 4;
    var coordinator: CoordinatorV1 = .{};
    try coordinator.init(
        0x6f76_6572_7369_7a65,
        &harness.bank,
        &harness.tree,
        harness.scope,
        test_request_epoch,
        test_session_id,
        &harness.sequence,
        &oversized_objects,
    );
    var counting = CountingQuoteAdapter{
        .inner = harness.backend.adapter(),
    };
    try std.testing.expectError(
        Error.InvalidTreeBinding,
        coordinator.admit(
            counting.interface(),
            try harness.request(),
            harness.fixture.selection,
            harness.fixture.requirement,
            &harness.fixture.inventory,
            harness.parent,
            harness.fixture.manifest,
            &harness.fixture.entries,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        counting.quote_calls,
    );
    const snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        snapshot.reserved_unmaterialized_allocations,
    );
    try std.testing.expect((try coordinator.snapshot()).idle);
    try harness.close();
}

test "LeaseTree cached evidence drift fails before terminal mutation" {
    var harness: TestHarness = .{};
    try harness.init();
    const admission = try harness.admit();

    const valid_request = harness.coordinator.request;
    harness.coordinator.request.request_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.cancelAdmission(admission),
    );
    harness.coordinator.request = valid_request;

    const valid_authority = harness.coordinator.authority;
    harness.coordinator.authority.authority_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.cancelAdmission(admission),
    );
    harness.coordinator.authority = valid_authority;

    const valid_admission = harness.coordinator.admission;
    harness.coordinator.admission.allocation_batch_sha256[0] ^= 1;
    harness.coordinator.admission.admission_sha256 =
        admissionRootV1(harness.coordinator.admission);
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.cancelAdmission(
            harness.coordinator.admission,
        ),
    );
    harness.coordinator.admission = valid_admission;

    const first_leaf = harness.coordinator.objects[0].leaf;
    const second_leaf = harness.coordinator.objects[1].leaf;
    harness.coordinator.objects[0].leaf = second_leaf;
    harness.coordinator.objects[1].leaf = first_leaf;
    var swapped_leaves: [3]resource.LeaseNodeV1 =
        undefined;
    for (
        harness.coordinator.objects,
        0..,
    ) |object, ordinal|
        swapped_leaves[ordinal] = object.leaf;
    harness.coordinator.admission.allocation_leaf_set_sha256 =
        allocationLeafSetSha256V1(&swapped_leaves);
    harness.coordinator.admission.admission_sha256 =
        admissionRootV1(harness.coordinator.admission);
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.cancelAdmission(
            harness.coordinator.admission,
        ),
    );
    harness.coordinator.objects[0].leaf = first_leaf;
    harness.coordinator.objects[1].leaf = second_leaf;
    harness.coordinator.admission = valid_admission;

    const terminal =
        try harness.coordinator.cancelAdmission(admission);
    try validateTerminalReceiptV1(terminal);
    try std.testing.expectEqualDeep(
        admission.request_sha256,
        terminal.request_sha256,
    );
    try std.testing.expectEqualDeep(
        admission.authority_sha256,
        terminal.authority_sha256,
    );
    try harness.close();
}

test "LeaseTree callback drift cannot substitute admitted object evidence" {
    var harness: TestHarness = .{};
    try harness.init();
    var drifting = CallbackDriftAdapter{
        .inner = harness.backend.adapter(),
        .coordinator = &harness.coordinator,
    };
    const admission = try harness.coordinator.admit(
        drifting.interface(),
        try harness.request(),
        harness.fixture.selection,
        harness.fixture.requirement,
        &harness.fixture.inventory,
        harness.parent,
        harness.fixture.manifest,
        &harness.fixture.entries,
    );
    const materialized = try harness.coordinator.materialize(
        admission,
        drifting.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateLeaseV1(lease);
    try std.testing.expectEqual(
        @as(u64, admission.allocation_count),
        drifting.allocation_callbacks,
    );
    for (harness.coordinator.objects, 0..) |object, ordinal| {
        try std.testing.expectEqualDeep(
            harness.fixture.entries[ordinal],
            object.entry,
        );
        try std.testing.expectEqualDeep(
            object.entry.binding_sha256,
            object.call.binding_sha256,
        );
    }
    const released = try harness.coordinator.release(
        lease,
        drifting.interface(),
    );
    const terminal = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateTerminalReceiptV1(terminal);
    try std.testing.expectEqual(
        @as(u64, admission.allocation_count),
        drifting.free_callbacks,
    );
    try std.testing.expectEqual(
        allocation.TerminalOutcomeV1.released,
        terminal.outcome,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        harness.backend.snapshot().live_objects,
    );
    try harness.close();
}

test "LeaseTree release rejects ordered leaf drift before free authority" {
    var harness: TestHarness = .{};
    try harness.init();
    const admission = try harness.admit();
    const materialized = try harness.coordinator.materialize(
        admission,
        harness.backend.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const first_leaf = harness.coordinator.objects[0].leaf;
    const second_leaf = harness.coordinator.objects[1].leaf;
    harness.coordinator.objects[0].leaf = second_leaf;
    harness.coordinator.objects[1].leaf = first_leaf;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.release(
            lease,
            harness.backend.adapter(),
        ),
    );
    var bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 8_192),
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        bank_snapshot.live_allocations,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        bank_snapshot.free_authorized_allocations,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        harness.backend.snapshot().live_objects,
    );

    harness.coordinator.objects[0].leaf = first_leaf;
    harness.coordinator.objects[1].leaf = second_leaf;
    const released = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    const terminal = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateTerminalReceiptV1(terminal);
    bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        bank_snapshot.used.device_bytes,
    );
    try harness.close();
}

test "LeaseTree public evidence rejects a re-sealed foreign scope" {
    var harness: TestHarness = .{};
    try harness.init();
    const admission = try harness.admit();

    var foreign_slots = [_]resource.Slot{.{}};
    var foreign_roots = [_]resource.LeaseTreeRootSlot{.{}};
    var foreign_nodes = [_]resource.LeaseNodeSlot{.{}};
    var foreign_bank = try resource.Bank.initWithLeaseTreeStorage(
        &foreign_slots,
        &foreign_roots,
        &foreign_nodes,
        .{ .device_bytes = 8_192, .queue_slots = 1 },
        0x666f_7265_6967_6e,
    );
    const foreign_parent = try foreign_bank.commit(
        try foreign_bank.reserve(1, .{ .queue_slots = 1 }),
    );
    const foreign_opened = try foreign_bank.openLeaseTree(
        foreign_parent,
        2,
        3,
        .{ .device_bytes = 8_192 },
    );
    const foreign_scoped = try foreign_bank.openLeaseScope(
        foreign_opened,
        4,
        5,
        .{ .device_bytes = 8_192 },
    );
    var forged_admission = admission;
    forged_admission.scope = foreign_scoped.scope;
    forged_admission.admission_sha256 =
        admissionRootV1(forged_admission);
    try std.testing.expectError(
        Error.InvalidTreeAdmission,
        validateAdmissionV1(forged_admission),
    );

    const expectInvalidScope = struct {
        fn call(
            base: LeaseTreeAllocationAdmissionV1,
            scope: resource.LeaseNodeV1,
        ) !void {
            var forged = base;
            forged.scope = resealTestLeaseNode(scope);
            forged.admission_sha256 = admissionRootV1(forged);
            try std.testing.expectError(
                Error.InvalidTreeAdmission,
                validateAdmissionV1(forged),
            );
        }
    }.call;
    var impossible_scope = admission.scope;
    impossible_scope.parent_index = 0;
    try expectInvalidScope(admission, impossible_scope);
    impossible_scope = admission.scope;
    impossible_scope.parent_generation +%= 1;
    try expectInvalidScope(admission, impossible_scope);
    impossible_scope = admission.scope;
    impossible_scope.node_key = 0;
    try expectInvalidScope(admission, impossible_scope);
    impossible_scope = admission.scope;
    impossible_scope.tenant_key = 0;
    try expectInvalidScope(admission, impossible_scope);
    impossible_scope = admission.scope;
    impossible_scope.node_index = std.math.maxInt(u32);
    try expectInvalidScope(admission, impossible_scope);

    const expectInvalidTree = struct {
        fn call(
            base: LeaseTreeAllocationAdmissionV1,
            tree: resource.LeaseTreeV1,
        ) !void {
            var forged = base;
            forged.reservation_tree = resealTestLeaseTree(tree);
            forged.admission_sha256 = admissionRootV1(forged);
            try std.testing.expectError(
                Error.InvalidTreeAdmission,
                validateAdmissionV1(forged),
            );
        }
    }.call;
    var impossible_tree = admission.reservation_tree;
    impossible_tree.generation =
        impossible_tree.identity_generation;
    try expectInvalidTree(admission, impossible_tree);
    impossible_tree = admission.reservation_tree;
    impossible_tree.active_nodes = 0;
    try expectInvalidTree(admission, impossible_tree);
    impossible_tree = admission.reservation_tree;
    impossible_tree.current.device_bytes =
        impossible_tree.ceiling.device_bytes + 1;
    try expectInvalidTree(admission, impossible_tree);
    impossible_tree = admission.reservation_tree;
    impossible_tree.active_nodes =
        @intCast(admission.allocation_count);
    try expectInvalidTree(admission, impossible_tree);
    var impossible_volume = admission;
    impossible_volume.total_device_bytes = 2;
    impossible_volume.scope.ceiling.device_bytes = 2;
    impossible_volume.scope =
        resealTestLeaseNode(impossible_volume.scope);
    impossible_volume.admission_sha256 =
        admissionRootV1(impossible_volume);
    try std.testing.expectError(
        Error.InvalidTreeAdmission,
        validateAdmissionV1(impossible_volume),
    );

    const materialized = try harness.coordinator.materialize(
        admission,
        harness.backend.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var forged_lease = lease;
    forged_lease.scope = foreign_scoped.scope;
    forged_lease.lease_sha256 = leaseRootV1(forged_lease);
    try std.testing.expectError(
        Error.InvalidTreeLease,
        validateLeaseV1(forged_lease),
    );
    var impossible_lease = lease;
    impossible_lease.materialized_bytes = 2;
    impossible_lease.scope.ceiling.device_bytes = 2;
    impossible_lease.scope =
        resealTestLeaseNode(impossible_lease.scope);
    impossible_lease.lease_sha256 =
        leaseRootV1(impossible_lease);
    try std.testing.expectError(
        Error.InvalidTreeLease,
        validateLeaseV1(impossible_lease),
    );
    impossible_lease = lease;
    impossible_lease.materialized_tree.active_nodes =
        @intCast(lease.allocation_count);
    impossible_lease.materialized_tree =
        resealTestLeaseTree(
            impossible_lease.materialized_tree,
        );
    impossible_lease.lease_sha256 =
        leaseRootV1(impossible_lease);
    try std.testing.expectError(
        Error.InvalidTreeLease,
        validateLeaseV1(impossible_lease),
    );
    const released = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    const terminal = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var forged_terminal = terminal;
    forged_terminal.scope = foreign_scoped.scope;
    forged_terminal.terminal_sha256 =
        terminalRootV1(forged_terminal);
    try std.testing.expectError(
        Error.InvalidTreeTerminalReceipt,
        validateTerminalReceiptV1(forged_terminal),
    );
    var impossible_terminal = terminal;
    impossible_terminal.terminal_tree.current.device_bytes =
        impossible_terminal.terminal_tree.ceiling.device_bytes;
    impossible_terminal.terminal_tree =
        resealTestLeaseTree(
            impossible_terminal.terminal_tree,
        );
    impossible_terminal.terminal_sha256 =
        terminalRootV1(impossible_terminal);
    try std.testing.expectError(
        Error.InvalidTreeTerminalReceipt,
        validateTerminalReceiptV1(impossible_terminal),
    );

    try foreign_bank.closeLeaseTree(foreign_scoped.tree);
    try foreign_bank.release(foreign_parent);
    try harness.close();
}

test "LeaseTree public scope index is Bank-global not per-tree count" {
    var slots = [_]resource.Slot{.{}} ** 2;
    var roots = [_]resource.LeaseTreeRootSlot{.{}} ** 2;
    var nodes = [_]resource.LeaseNodeSlot{.{}} ** 8;
    var bank = try resource.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{ .device_bytes = 8_192, .queue_slots = 2 },
        0x676c_6f62_616c_6e64,
    );
    const first_parent = try bank.commit(
        try bank.reserve(1, .{ .queue_slots = 1 }),
    );
    var first_tree = try bank.openLeaseTree(
        first_parent,
        2,
        3,
        .{ .device_bytes = 8_192 },
    );
    var scope_index: u64 = 0;
    while (scope_index < 4) : (scope_index += 1) {
        const opened = try bank.openLeaseScope(
            first_tree,
            10 + scope_index,
            20 + scope_index,
            .{ .device_bytes = 8_192 },
        );
        first_tree = opened.tree;
    }

    const second_parent = try bank.commit(
        try bank.reserve(30, .{ .queue_slots = 1 }),
    );
    const second_opened = try bank.openLeaseTree(
        second_parent,
        31,
        32,
        .{ .device_bytes = 8_192 },
    );
    const second_scoped = try bank.openLeaseScope(
        second_opened,
        33,
        34,
        .{ .device_bytes = 8_192 },
    );
    try std.testing.expect(
        second_scoped.scope.node_index >=
            second_scoped.tree.active_nodes,
    );
    var second_tree = second_scoped.tree;
    const sequence: u64 = 0;
    const session_id: usize = 0x676c_6f62;
    try bank.bindPublicationSessionWithLeaseTree(
        second_tree,
        35,
        session_id,
    );
    var leaves: [1]resource.LeaseNodeV1 = undefined;
    const reservation = try bank.reserveAllocationsForSession(
        second_tree,
        35,
        session_id,
        sequence,
        &.{.{
            .scope = second_scoped.scope,
            .node_key = 36,
            .binding_key = 37,
            .claim = .{ .device_bytes = 8_192 },
        }},
        &leaves,
    );
    second_tree = reservation.tree;
    try std.testing.expect(
        second_scoped.scope.node_index >=
            second_tree.active_nodes,
    );
    var admission: LeaseTreeAllocationAdmissionV1 = .{
        .coordinator_epoch = 38,
        .generation = 39,
        .authority_sha256 = testDigest("global node authority"),
        .request_sha256 = testDigest("global node request"),
        .selection_receipt_sha256 = testDigest("global node selection"),
        .selected_capability_sha256 = testDigest("global node capability"),
        .allocation_manifest_sha256 = testDigest("global node manifest"),
        .parent_receipt_sha256 = allocation.resourceReceiptRootV1(second_parent),
        .reservation_tree = reservation.tree,
        .scope = second_scoped.scope,
        .allocation_batch_sha256 = leaseAllocationBatchSha256V1(reservation.batch),
        .allocation_leaf_set_sha256 = allocationLeafSetSha256V1(&leaves),
        .publication_binding_sha256 = publicationBindingSha256V1(reservation.batch),
        .allocation_count = 1,
        .total_device_bytes = 8_192,
    };
    admission.admission_sha256 = admissionRootV1(admission);
    try validateAdmissionV1(admission);

    second_tree =
        try bank.abortAllocationsAfterFree(reservation.batch);
    try bank.closePublicationSession(
        second_parent,
        35,
        session_id,
        sequence,
    );
    try bank.closeLeaseTree(second_tree);
    try bank.release(second_parent);
    try bank.closeLeaseTree(first_tree);
    try bank.release(first_parent);
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "LeaseTree allocation rollback recovery retains full reserved charge" {
    var harness: TestHarness = .{};
    try harness.init();
    const admission = try harness.admit();
    harness.backend.failNextAllocationAtOrdinal(2);
    harness.backend.failNextFreeForBinding(
        harness.fixture.entries[1].binding_sha256,
    );
    const outcome = try harness.coordinator.materialize(
        admission,
        harness.backend.adapter(),
        .{},
    );
    const recovery = switch (outcome) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateRecoveryV1(recovery);
    var impossible_recovery = recovery;
    impossible_recovery.outstanding_object_count = 2;
    impossible_recovery.outstanding_bytes = 1;
    impossible_recovery.recovery_sha256 =
        recoveryRootV1(impossible_recovery);
    try std.testing.expectError(
        Error.InvalidTreeRecovery,
        validateRecoveryV1(impossible_recovery),
    );
    impossible_recovery = recovery;
    impossible_recovery.pending_tree.active_nodes =
        @intCast(recovery.outstanding_object_count);
    impossible_recovery.pending_tree =
        resealTestLeaseTree(
            impossible_recovery.pending_tree,
        );
    impossible_recovery.recovery_sha256 =
        recoveryRootV1(impossible_recovery);
    try std.testing.expectError(
        Error.InvalidTreeRecovery,
        validateRecoveryV1(impossible_recovery),
    );
    try std.testing.expectEqual(
        RecoveryPhaseV1.rollback_reserved,
        recovery.phase,
    );
    try std.testing.expectEqual(@as(u64, 1), recovery.outstanding_object_count);
    var bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 8_192),
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        bank_snapshot.reserved_unmaterialized_allocations,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        harness.backend.snapshot().live_objects,
    );

    var outstanding_index: ?usize = null;
    for (harness.coordinator.objects, 0..) |object, index|
        if (object.state == .live) {
            outstanding_index = index;
            break;
        };
    const index = outstanding_index orelse
        return error.TestUnexpectedResult;
    const original_slot = harness.coordinator.objects[index];
    harness.coordinator.objects[index].ordinal +%= 1;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            harness.backend.adapter(),
        ),
    );
    harness.coordinator.objects[index] = original_slot;
    const original_object = harness.coordinator.objects[index].object;
    harness.coordinator.objects[index].object.allocated_bytes +%= 1;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            harness.backend.adapter(),
        ),
    );
    harness.coordinator.objects[index].object = original_object;
    const retried = try harness.coordinator.retryRecovery(
        recovery,
        harness.backend.adapter(),
    );
    const terminal = switch (retried) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateTerminalReceiptV1(terminal);
    try std.testing.expectEqual(
        allocation.TerminalOutcomeV1.allocation_failed,
        terminal.outcome,
    );
    bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        harness.backend.snapshot().live_objects,
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            harness.backend.adapter(),
        ),
    );
    try harness.close();
}

test "LeaseTree free permit recovery remains charged until retry succeeds" {
    var harness: TestHarness = .{};
    try harness.init();
    const admission = try harness.admit();
    const materialized = try harness.coordinator.materialize(
        admission,
        harness.backend.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    harness.backend.failNextFreeForBinding(
        harness.fixture.entries[1].binding_sha256,
    );
    const release = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    const recovery = switch (release) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateRecoveryV1(recovery);
    try std.testing.expectEqual(
        RecoveryPhaseV1.free_authorized,
        recovery.phase,
    );
    try std.testing.expectEqual(@as(u64, 1), recovery.outstanding_object_count);
    var bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 8_192),
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        bank_snapshot.free_authorized_allocations,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        harness.backend.snapshot().live_objects,
    );
    try std.testing.expectError(
        resource.Error.InvalidTransition,
        harness.bank.closePublicationSession(
            harness.parent,
            test_request_epoch,
            test_session_id,
            harness.sequence,
        ),
    );

    const retried = try harness.coordinator.retryRecovery(
        recovery,
        harness.backend.adapter(),
    );
    const terminal = switch (retried) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateTerminalReceiptV1(terminal);
    bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        bank_snapshot.free_authorized_allocations,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        harness.backend.snapshot().live_objects,
    );
    try harness.close();
}

test "LeaseTree settlement retry does not free backend objects twice" {
    var harness: TestHarness = .{};
    try harness.init();
    var fault_slots = [_]resource.Slot{.{}};
    var fault_bank = try resource.Bank.init(
        &fault_slots,
        .{},
        0x4641_554c_5442_414e,
    );
    var fault = SettlementFaultAdapter{
        .inner = harness.backend.adapter(),
        .bank = &harness.bank,
        .fault_bank = &fault_bank,
        .coordinator = &harness.coordinator,
        .expected_device_bytes = harness.fixture.manifest.total_charged_bytes,
    };
    const request = try harness.request();
    const admission = try harness.coordinator.admit(
        fault.interface(),
        request,
        harness.fixture.selection,
        harness.fixture.requirement,
        &harness.fixture.inventory,
        harness.parent,
        harness.fixture.manifest,
        &harness.fixture.entries,
    );
    const materialized = try harness.coordinator.materialize(
        admission,
        fault.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const released = try harness.coordinator.release(
        lease,
        fault.interface(),
    );
    const recovery = switch (released) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateRecoveryV1(recovery);
    try std.testing.expectEqual(
        RecoveryPhaseV1.settlement_required,
        recovery.phase,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        recovery.outstanding_object_count,
    );
    try std.testing.expectEqual(@as(u64, 3), fault.free_calls);
    try std.testing.expect(!fault.ordering_violation);
    try std.testing.expectEqual(
        @as(usize, 0),
        harness.backend.snapshot().live_objects,
    );
    var bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 8_192),
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        bank_snapshot.free_authorized_allocations,
    );

    try std.testing.expectError(
        Error.InvalidCoordinator,
        harness.coordinator.retryRecovery(
            recovery,
            fault.interface(),
        ),
    );
    harness.coordinator.bank = &harness.bank;
    harness.sequence +%= 1;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            fault.interface(),
        ),
    );
    harness.sequence -%= 1;
    const valid_request = harness.coordinator.request;
    harness.coordinator.request.request_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            fault.interface(),
        ),
    );
    harness.coordinator.request = valid_request;
    const valid_admission = harness.coordinator.admission;
    harness.coordinator.admission.allocation_batch_sha256[0] ^= 1;
    harness.coordinator.admission.admission_sha256 =
        admissionRootV1(harness.coordinator.admission);
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            fault.interface(),
        ),
    );
    harness.coordinator.admission = valid_admission;
    harness.coordinator.target_outcome = .cancelled;
    harness.coordinator.target_reason = .explicit_cancellation;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            fault.interface(),
        ),
    );
    harness.coordinator.target_outcome = .released;
    harness.coordinator.target_reason = .normal_release;
    const valid_permit = harness.coordinator.permit.?;
    var forged_permit = valid_permit;
    forged_permit.integrity ^= 1;
    harness.coordinator.permit = forged_permit;
    try std.testing.expectError(
        Error.InvalidTransition,
        harness.coordinator.retryRecovery(
            recovery,
            fault.interface(),
        ),
    );
    harness.coordinator.permit = valid_permit;
    const retried = try harness.coordinator.retryRecovery(
        recovery,
        fault.interface(),
    );
    const terminal = switch (retried) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateTerminalReceiptV1(terminal);
    try std.testing.expectEqual(@as(u64, 3), fault.free_calls);
    bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        bank_snapshot.used.device_bytes,
    );
    try harness.close();
}

test "LeaseTree lifecycle literal golden roots stay stable" {
    var harness: TestHarness = .{};
    try harness.init();
    var fault_slots = [_]resource.Slot{.{}};
    var fault_bank = try resource.Bank.init(
        &fault_slots,
        .{},
        0x4641_554c_5442_414e,
    );
    var fault = SettlementFaultAdapter{
        .inner = harness.backend.adapter(),
        .bank = &harness.bank,
        .fault_bank = &fault_bank,
        .coordinator = &harness.coordinator,
        .expected_device_bytes = harness.fixture.manifest.total_charged_bytes,
    };
    const request = try harness.request();

    const first = try harness.coordinator.admit(
        fault.interface(),
        request,
        harness.fixture.selection,
        harness.fixture.requirement,
        &harness.fixture.inventory,
        harness.parent,
        harness.fixture.manifest,
        &harness.fixture.entries,
    );
    const first_batch = harness.coordinator.batch.?;
    var first_leaves: [3]resource.LeaseNodeV1 = undefined;
    for (&first_leaves, 0..) |*leaf, ordinal|
        leaf.* = harness.coordinator.objects[ordinal].leaf;
    const cancelled =
        try harness.coordinator.cancelAdmission(first);

    const second = try harness.coordinator.admit(
        fault.interface(),
        request,
        harness.fixture.selection,
        harness.fixture.requirement,
        &harness.fixture.inventory,
        harness.parent,
        harness.fixture.manifest,
        &harness.fixture.entries,
    );
    const second_batch = harness.coordinator.batch.?;
    var second_leaves: [3]resource.LeaseNodeV1 = undefined;
    for (&second_leaves, 0..) |*leaf, ordinal|
        leaf.* = harness.coordinator.objects[ordinal].leaf;
    const materialized = try harness.coordinator.materialize(
        second,
        fault.interface(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var calls: [3]allocation.AllocationCallV1 = undefined;
    var objects: [3]allocation.BackendObjectV1 = undefined;
    for (harness.coordinator.objects, 0..) |object, ordinal| {
        calls[ordinal] = object.call;
        objects[ordinal] = object.object;
    }

    harness.backend.failNextFreeForBinding(
        harness.fixture.entries[1].binding_sha256,
    );
    const released = try harness.coordinator.release(
        lease,
        fault.interface(),
    );
    const free_recovery = switch (released) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const permit = harness.coordinator.permit.?;
    const settlement_outcome =
        try harness.coordinator.retryRecovery(
            free_recovery,
            fault.interface(),
        );
    const settlement_recovery = switch (settlement_outcome) {
        .recovery_required => |value| value,
        else => return error.TestUnexpectedResult,
    };
    harness.coordinator.bank = &harness.bank;
    const terminal_outcome =
        try harness.coordinator.retryRecovery(
            settlement_recovery,
            fault.interface(),
        );
    const terminal = switch (terminal_outcome) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };

    const roots = .{
        .parent = allocation.resourceReceiptRootV1(harness.parent),
        .scope = leaseNodeSha256V1(harness.scope),
        .reservation_tree_1 = leaseTreeSha256V1(first.reservation_tree),
        .batch_1 = leaseAllocationBatchSha256V1(first_batch),
        .leaf_set_1 = allocationLeafSetSha256V1(&first_leaves),
        .publication_1 = publicationBindingSha256V1(first_batch),
        .admission_1 = first.admission_sha256,
        .terminal_cancel_1 = cancelled.terminal_sha256,
        .reservation_tree_2 = leaseTreeSha256V1(second.reservation_tree),
        .batch_2 = leaseAllocationBatchSha256V1(second_batch),
        .leaf_set_2 = allocationLeafSetSha256V1(&second_leaves),
        .publication_2 = publicationBindingSha256V1(second_batch),
        .admission_2 = second.admission_sha256,
        .materialized_tree_2 = leaseTreeSha256V1(lease.materialized_tree),
        .object_set_2 = lease.backend_object_set_sha256,
        .lease_2 = lease.lease_sha256,
        .authorized_tree_2 = leaseTreeSha256V1(free_recovery.pending_tree),
        .permit_2 = leaseFreePermitSha256V1(permit),
        .outstanding_2 = free_recovery.outstanding_set_sha256,
        .recovery_free_2 = free_recovery.recovery_sha256,
        .recovery_settlement_2 = settlement_recovery.recovery_sha256,
        .terminal_tree_2 = leaseTreeSha256V1(terminal.terminal_tree),
        .terminal_release_2 = terminal.terminal_sha256,
    };
    try expectGoldenDigest(
        "2bb3c84cccbab6fd65e803e2dd645b3b825e8f433562ed8767c29dd7f8dd73b0",
        roots.parent,
    );
    try expectGoldenDigest(
        "50430f53e717d1c2412b27d10c27142c7599627a5d1837a7d0c9bb5335a470e8",
        roots.scope,
    );
    try expectGoldenDigest(
        "c9d4ed4a0df86cffb3720d97dc8ac444104fa19838fd051495724d4a7343adc3",
        roots.reservation_tree_1,
    );
    try expectGoldenDigest(
        "22042c0ea52d80a9de60978521da5570093a82b7a0b1e4b9b64ee8ac5a397082",
        roots.batch_1,
    );
    try expectGoldenDigest(
        "6df1d9c657b7c43e96541dceb37781d4d6ace79d20590f43e7e8c9580d90a9de",
        roots.leaf_set_1,
    );
    try expectGoldenDigest(
        "85f572413e82b885446905d87862a37e27e2120aa583126ee47656823ee1817e",
        roots.publication_1,
    );
    try expectGoldenDigest(
        "160dda1c947f61ddd20fe490ef8fffb38374544da987da01c0736a8235f5dcf2",
        roots.admission_1,
    );
    try expectGoldenDigest(
        "679596cf0de6804890bc0f3b0cc11f10ef7fb461d6999f7e35bb3acd521509e9",
        roots.terminal_cancel_1,
    );
    try expectGoldenDigest(
        "5013d70445c815468589bf7babf26f378118ce2aa7e0670dd59fbac394c0d9d5",
        roots.reservation_tree_2,
    );
    try expectGoldenDigest(
        "76d743677341f7b0a1b1948810a664af28ac248abf13869ca4dc1f28b85af202",
        roots.batch_2,
    );
    try expectGoldenDigest(
        "c8716b822035b0fa4c0716719b930c919018b5b72a526fc6f06c75184ddc42d4",
        roots.leaf_set_2,
    );
    try expectGoldenDigest(
        "85f572413e82b885446905d87862a37e27e2120aa583126ee47656823ee1817e",
        roots.publication_2,
    );
    try expectGoldenDigest(
        "c12e7846d353e09d42af842ed923b216c468d56eebe8ea0965caca50b45d7414",
        roots.admission_2,
    );
    try expectGoldenDigest(
        "822a2ae5dcfed078045741293fa2024b73b7f181f9fd1948aaa9f1eb05c03bb0",
        roots.materialized_tree_2,
    );
    try expectGoldenDigest(
        "6c658fa780e2e01102b38508bd2aa4b6f9218450eb6c9f5317a0a58a9ffe7418",
        roots.object_set_2,
    );
    try expectGoldenDigest(
        "3e2f35f71ccda404a2f6d9ebd18a1c7ffa0e88c2deccbcabd0e7557711b2211b",
        roots.lease_2,
    );
    try expectGoldenDigest(
        "2f285718598af11581da3bdf835bbcf9eb1b11bbfbcafa13a42f92cfee2f24a8",
        roots.authorized_tree_2,
    );
    try expectGoldenDigest(
        "c3aa16c01d6650e8e433635b9f14f92906d1d08c7303b0adba11ca18e8be742a",
        roots.permit_2,
    );
    try expectGoldenDigest(
        "5463ee1c5ac81d555dfd917c88962facef6dd7b75a9031ff139a0989b2a511f3",
        roots.outstanding_2,
    );
    try expectGoldenDigest(
        "af1656c374960e32807cb33db889f7c444dd35249ae948bb840efaa8f62e998f",
        roots.recovery_free_2,
    );
    try expectGoldenDigest(
        "1f390c48781dc37b62dabb70ab7816f007d6aa0a5648c2a857d855b344cd25b0",
        roots.recovery_settlement_2,
    );
    try expectGoldenDigest(
        "2a7d86767966b6f0e16dfd7ea2c219a33156554448748162f125ec213cb9a991",
        roots.terminal_tree_2,
    );
    try expectGoldenDigest(
        "252693d4a9477fe5b693443595919619367ac88c6c2039bfa4c698ea4472abe1",
        roots.terminal_release_2,
    );
    const leaf_1_goldens = [_][]const u8{
        "57a8a3fca1ab68213592da10e95dd5ac54fe2c4f9f20aa584a624fac51dd4f92",
        "cda1726195497e4bea50fd906b4a077d899693f78971acd20bed125dad881a86",
        "b75a45620e8efa1f7065c68ee03317135d59fa624c2b3e25151de4f3fbce1e15",
    };
    const leaf_2_goldens = [_][]const u8{
        "78455ad07db46835e62d07e60872dd302a20c32265964d9760239947004bc899",
        "5ab5c820b5f3a0633445edf6828457c3e083490f9a8b68cf79c62168a446f4d3",
        "4fc6185bf7dcf3a324d4099e022b6e578a5c960efd551e1f6d6b29b22079954e",
    };
    const call_goldens = [_][]const u8{
        "0c838794dd2ec3409414de2b77364d0e3e31be159948282c60256da5067c8a36",
        "17939f71ddc85d2c1203df2f7ef059ba2a4ebb4fe0ba9253b9e75be5eec10287",
        "28e291e8febb10c0e4bda56cd8dee2d6de5d8a92c749ce83b0416470c559792d",
    };
    const object_goldens = [_][]const u8{
        "185e2d0c5b6dde43d9a214399acaf3b3e0094fa9e670d6af705f36d0715ab03b",
        "5cf3af189dc2b2fd7ebb3d9d76a67626adef09251a9188a4144961570e018431",
        "15d3dddc78c94b60603e95d0598969bd3711d0a27f8c99e92f7a029125d6773c",
    };
    for (
        first_leaves,
        leaf_1_goldens,
    ) |leaf, expected|
        try expectGoldenDigest(
            expected,
            leaseNodeSha256V1(leaf),
        );
    for (
        second_leaves,
        leaf_2_goldens,
    ) |leaf, expected|
        try expectGoldenDigest(
            expected,
            leaseNodeSha256V1(leaf),
        );
    for (calls, call_goldens) |call, expected|
        try expectGoldenDigest(expected, call.call_sha256);
    for (objects, object_goldens) |object, expected|
        try expectGoldenDigest(expected, object.object_sha256);
    try harness.close();
}

test "LeaseTree exact scope ceiling linearizes coordinators after concurrent preflight" {
    const fixture = try makeTestFixture();
    const wave_bytes = fixture.manifest.total_charged_bytes;
    try std.testing.expectEqual(@as(u64, 8_192), wave_bytes);

    var slots = [_]resource.Slot{.{}};
    var roots = [_]resource.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource.LeaseNodeSlot{.{}} ** 7;
    var bank = try resource.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{
            .device_bytes = wave_bytes * 2,
            .queue_slots = 1,
        },
        0x5241_4345_4241_4e4b,
    );
    const parent = try bank.commit(
        try bank.reserve(1, .{ .queue_slots = 1 }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        2,
        3,
        .{ .device_bytes = wave_bytes * 2 },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        4,
        5,
        .{ .device_bytes = wave_bytes },
    );
    var tree = scoped.tree;
    var sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        71,
        test_session_id,
    );

    var fake_objects =
        [_]allocation.FakeObjectSlotV1{.{}} ** 3;
    var backend = try allocation.FakeBackendV1.init(
        fixture.authority,
        &fake_objects,
    );
    var left_objects =
        [_]CoordinatorObjectSlotV1{.{}} ** 3;
    var right_objects =
        [_]CoordinatorObjectSlotV1{.{}} ** 3;
    var left: CoordinatorV1 = .{};
    var right: CoordinatorV1 = .{};
    try left.init(
        6,
        &bank,
        &tree,
        scoped.scope,
        71,
        test_session_id,
        &sequence,
        &left_objects,
    );
    try right.init(
        7,
        &bank,
        &tree,
        scoped.scope,
        71,
        test_session_id,
        &sequence,
        &right_objects,
    );
    const request = try allocation.makeRequestV1(
        71,
        testDigest("concurrent LeaseTree scope owner"),
        fixture.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    var blocking = BlockingQuoteAdapter{
        .inner = backend.adapter(),
    };
    const AdmitWorker = struct {
        coordinator: *CoordinatorV1,
        adapter: allocation.AdapterV1,
        request: allocation.AllocationRequestV1,
        selection: device.DeviceSelectionReceiptV1,
        requirement: device.DeviceRequirementV1,
        inventory: []const device.DeviceInventoryEntryV1,
        parent: resource.Receipt,
        manifest: allocation.AllocationManifestV1,
        entries: []const allocation.AllocationEntryV1,
        admission: ?LeaseTreeAllocationAdmissionV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            self.admission = self.coordinator.admit(
                self.adapter,
                self.request,
                self.selection,
                self.requirement,
                self.inventory,
                self.parent,
                self.manifest,
                self.entries,
            ) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };
    var worker = AdmitWorker{
        .coordinator = &right,
        .adapter = blocking.interface(),
        .request = request,
        .selection = fixture.selection,
        .requirement = fixture.requirement,
        .inventory = &fixture.inventory,
        .parent = parent,
        .manifest = fixture.manifest,
        .entries = &fixture.entries,
    };
    const thread = try std.Thread.spawn(
        .{},
        AdmitWorker.run,
        .{&worker},
    );
    var joined = false;
    defer if (!joined) {
        blocking.proceed.store(true, .release);
        thread.join();
    };
    while (!blocking.entered.load(.acquire))
        std.atomic.spinLoopHint();

    const left_admission = try left.admit(
        backend.adapter(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const left_materialized = try left.materialize(
        left_admission,
        backend.adapter(),
        .{},
    );
    const left_lease = switch (left_materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };

    blocking.proceed.store(true, .release);
    thread.join();
    joined = true;
    try std.testing.expect(worker.admission == null);
    try std.testing.expectEqual(
        @as(?Error, Error.InvalidClaim),
        worker.operation_error,
    );
    const right_snapshot = try right.snapshot();
    try std.testing.expect(right_snapshot.idle);
    try std.testing.expectEqual(@as(usize, 0), right_snapshot.reserved_objects);
    try std.testing.expectEqual(@as(usize, 0), right_snapshot.live_objects);
    var bank_snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(
        wave_bytes,
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        bank_snapshot.live_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        bank_snapshot.lease_allocation_reserves,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        bank_snapshot.lease_allocation_materializations,
    );
    try std.testing.expectEqual(
        @as(u64, 3),
        backend.snapshot().allocate_calls,
    );

    const left_released = try left.release(
        left_lease,
        backend.adapter(),
    );
    _ = switch (left_released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };

    const right_admission = try right.admit(
        blocking.interface(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const right_materialized = try right.materialize(
        right_admission,
        blocking.interface(),
        .{},
    );
    const right_lease = switch (right_materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const right_released = try right.release(
        right_lease,
        blocking.interface(),
    );
    _ = switch (right_released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    bank_snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(u64, 0), bank_snapshot.used.device_bytes);
    try std.testing.expectEqual(
        @as(u64, 2),
        bank_snapshot.lease_allocation_reserves,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        bank_snapshot.lease_allocation_materializations,
    );
    try std.testing.expectEqual(
        @as(u64, 6),
        backend.snapshot().allocate_calls,
    );

    try bank.closePublicationSession(
        parent,
        71,
        test_session_id,
        sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
}

test "LeaseTree device scope release preserves a live sibling scope" {
    const fixture = try makeTestFixture();
    var slots = [_]resource.Slot{.{}};
    var roots = [_]resource.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource.LeaseNodeSlot{.{}} ** 6;
    var bank = try resource.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{ .device_bytes = 9_216, .queue_slots = 1 },
        0x7369_626c_696e_67,
    );
    const parent = try bank.commit(
        try bank.reserve(1, .{ .queue_slots = 1 }),
    );
    const opened = try bank.openLeaseTree(
        parent,
        2,
        3,
        .{ .device_bytes = 9_216 },
    );
    const device_scope = try bank.openLeaseScope(
        opened,
        4,
        5,
        .{ .device_bytes = 8_192 },
    );
    const sibling_scope = try bank.openLeaseScope(
        device_scope.tree,
        6,
        7,
        .{ .device_bytes = 1_024 },
    );
    var tree = sibling_scope.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    var sequence: u64 = 0;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        71,
        session_id,
    );
    const sibling_specs = [_]resource.LeaseAllocationSpecV1{.{
        .scope = sibling_scope.scope,
        .node_key = 8,
        .binding_key = 9,
        .claim = .{ .device_bytes = 1_024 },
    }};
    var sibling_leaves: [1]resource.LeaseNodeV1 = undefined;
    const sibling_reserved = try bank.reserveAllocationsForSession(
        tree,
        71,
        session_id,
        sequence,
        &sibling_specs,
        &sibling_leaves,
    );
    tree = try bank.commitAllocationsAfterAllocate(
        sibling_reserved.batch,
    );

    var fake_objects =
        [_]allocation.FakeObjectSlotV1{.{}} ** 3;
    var backend = try allocation.FakeBackendV1.init(
        fixture.authority,
        &fake_objects,
    );
    var coordinator_objects =
        [_]CoordinatorObjectSlotV1{.{}} ** 3;
    var coordinator: CoordinatorV1 = .{};
    try coordinator.init(
        10,
        &bank,
        &tree,
        device_scope.scope,
        71,
        session_id,
        &sequence,
        &coordinator_objects,
    );
    const request = try allocation.makeRequestV1(
        71,
        testDigest("sibling scope device owner"),
        fixture.authority,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const admission = try coordinator.admit(
        backend.adapter(),
        request,
        fixture.selection,
        fixture.requirement,
        &fixture.inventory,
        parent,
        fixture.manifest,
        &fixture.entries,
    );
    const materialized = try coordinator.materialize(
        admission,
        backend.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const released = try coordinator.release(
        lease,
        backend.adapter(),
    );
    const terminal = switch (released) {
        .terminal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try validateTerminalReceiptV1(terminal);
    try std.testing.expectEqual(
        @as(u64, 1_024),
        terminal.terminal_tree.current.device_bytes,
    );
    try bank.validateLeaseNode(tree, sibling_leaves[0]);
    var bank_snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(
        @as(usize, 1),
        bank_snapshot.live_allocations,
    );
    try std.testing.expectEqual(
        @as(u64, 1_024),
        bank_snapshot.used.device_bytes,
    );

    const retire = try bank.beginRetireSubtreeForSession(
        tree,
        sibling_scope.scope,
        71,
        session_id,
        sequence,
    );
    const authorized = try bank.authorizeFree(retire.ticket);
    tree = try bank.commitFreeAfterAllocatorFree(
        authorized.permit,
    );
    bank_snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        bank_snapshot.used.device_bytes,
    );
    try bank.closePublicationSession(
        parent,
        71,
        session_id,
        sequence,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
}

test "LeaseTree coordinator rejects receipt-funded ownership at init" {
    var slots = [_]resource.Slot{.{}};
    var roots = [_]resource.LeaseTreeRootSlot{.{}};
    var nodes = [_]resource.LeaseNodeSlot{.{}} ** 1;
    var bank = try resource.Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{ .device_bytes = 8_192, .queue_slots = 1 },
        0x6675_6e64_6564,
    );
    const parent = try bank.commit(
        try bank.reserve(
            1,
            .{ .device_bytes = 8_192, .queue_slots = 1 },
        ),
    );
    const opened = try bank.openReceiptFundedLeaseTree(
        parent,
        2,
        3,
        .{ .device_bytes = 8_192 },
    );
    const scoped = try bank.openLeaseScope(
        opened,
        4,
        5,
        .{ .device_bytes = 8_192 },
    );
    var session: u8 = 0;
    var sequence: u64 = 0;
    var tree = scoped.tree;
    try bank.bindPublicationSessionWithLeaseTree(
        tree,
        6,
        @intFromPtr(&session),
    );
    var object_slots = [_]CoordinatorObjectSlotV1{.{}};
    var coordinator: CoordinatorV1 = .{};
    try std.testing.expectError(
        resource.Error.InvalidTransition,
        coordinator.init(
            7,
            &bank,
            &tree,
            scoped.scope,
            6,
            @intFromPtr(&session),
            &sequence,
            &object_slots,
        ),
    );
    try bank.closePublicationSession(
        parent,
        6,
        @intFromPtr(&session),
        0,
    );
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
}

test "LeaseTree dispatch pin intent literal root matches the independent oracle" {
    var intent: DispatchPinIntentV1 = .{
        .abi_version = dispatch_pin_intent_abi,
        .coordinator_epoch = 4_850_182_538_452_880_961,
        .allocation_generation = 2,
        .dispatch_generation = 1,
        .allocation_count = 4,
        .pinned_device_bytes = 8_192,
        .authority_sha256 = try testDigestFromHex(
            "9cb59d992fd5e0ada234f70f8113c1978ca576988144a62c1ccf554c1622820c",
        ),
        .dispatch_authority_sha256 = try testDigestFromHex(
            "7c133b20a126f5c514dfca1284e7bcebd0799adaaeb650d5c19a4d34b92124e6",
        ),
        .queue_authority_sha256 = try testDigestFromHex(
            "e795945fda0ec7122ae67609a1bd156ee628c79911b077d7f687c6818590b8eb",
        ),
        .request_sha256 = try testDigestFromHex(
            "ade7fd932b2d2a3f827b0d3368735f38f65c207dcce035d637669a4a3d72f229",
        ),
        .admission_sha256 = try testDigestFromHex(
            "c12e7846d353e09d42af842ed923b216c468d56eebe8ea0965caca50b45d7414",
        ),
        .lease_sha256 = try testDigestFromHex(
            "3e2f35f71ccda404a2f6d9ebd18a1c7ffa0e88c2deccbcabd0e7557711b2211b",
        ),
        .parent_receipt_sha256 = try testDigestFromHex(
            "2bb3c84cccbab6fd65e803e2dd645b3b825e8f433562ed8767c29dd7f8dd73b0",
        ),
        .allocation_leaf_set_sha256 = try testDigestFromHex(
            "c8716b822035b0fa4c0716719b930c919018b5b72a526fc6f06c75184ddc42d4",
        ),
        .backend_object_set_sha256 = try testDigestFromHex(
            "6c658fa780e2e01102b38508bd2aa4b6f9218450eb6c9f5317a0a58a9ffe7418",
        ),
        .scope_sha256 = try testDigestFromHex(
            "50430f53e717d1c2412b27d10c27142c7599627a5d1837a7d0c9bb5335a470e8",
        ),
        .dispatch_request_sha256 = try testDigestFromHex(
            "f89175ddd5b07db24854c8432a650449a023c9445cedbc86a75459305b2e4486",
        ),
        .publication_binding_sha256 = try testDigestFromHex(
            "1248e6c72b4450976473bff890f6e3eb4a0a5f4ffa42474e84b0d03072080b3f",
        ),
    };
    intent.intent_sha256 = dispatchPinIntentRootV1(intent);

    try expectGoldenDigest(
        "0dcf9b07e0e30fbabf97b5efa7cb9975bba2198e7fdaf82e128d47c7fe93ebaa",
        intent.intent_sha256,
    );
    try validateDispatchPinIntentV1(intent);
}

test "LeaseTree dispatch literal roots match the independent oracle" {
    var harness: TestHarness = .{};
    try harness.initDispatchOne();
    const first_admission = try harness.admit();
    _ = try harness.coordinator.cancelAdmission(
        first_admission,
    );
    const admission = try harness.admit();
    const materialized = try harness.coordinator.materialize(
        admission,
        harness.backend.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var dispatch: TestDispatchAdapter = .{
        .dispatch_authority_sha256 = testDigest("LeaseTree dispatch authority"),
        .queue_authority_sha256 = testDigest("LeaseTree queue authority"),
    };
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("LeaseTree dispatch request"),
    );
    const permit =
        harness.coordinator_dispatches[0].bank_permit.?;
    const pin_slot = harness.pin_slots[0];

    try std.testing.expectEqual(
        @as(u64, 0x1c07_aa9d_c518_8257),
        permit.owner_key,
    );
    try std.testing.expectEqual(
        @as(u64, 0x02b6_7c2b_909c_d08a),
        permit.node_set_digest,
    );
    try std.testing.expectEqual(
        @as(u64, 0x9ceb_6915_a74d_b67d),
        pin_slot.integrity,
    );
    try std.testing.expectEqual(
        @as(u64, 0x596b_83b5_db4c_ac13),
        permit.integrity,
    );
    try expectGoldenDigest(
        "c5564e2a5c384045114415840ebd066f5f02722832a2cd913a76e09c47bf6ffd",
        leasePinPermitSha256V1(permit),
    );
    try std.testing.expectEqual(
        @as(u64, 0x2664_1bdd_5921_1036),
        pin.pinned_tree.state_digest,
    );
    try std.testing.expectEqual(
        @as(u64, 0x534f_1bde_6edc_c150),
        pin.pinned_tree.integrity,
    );
    try expectGoldenDigest(
        "1c1eaf56f228ba78a22fc63efd4c0d907341f6956c53ca2a0a848e73b2752412",
        leaseTreeSha256V1(pin.pinned_tree),
    );
    try expectGoldenDigest(
        "1248e6c72b4450976473bff890f6e3eb4a0a5f4ffa42474e84b0d03072080b3f",
        pin.publication_binding_sha256,
    );
    try expectGoldenDigest(
        "2d9b5c285f548afcc5d94c74c2cd8bb820ef9735a1b3023ac0f43b896ea93dcc",
        pin.pin_sha256,
    );

    const terminal = try makeDispatchTerminalV1(
        pin,
        .succeeded,
        testDigest("LeaseTree dispatch submission"),
        testDigest("LeaseTree dispatch backend completion"),
        testDigest("LeaseTree dispatch output"),
    );
    dispatch.expect(terminal);
    try expectGoldenDigest(
        "d2beeff27770569cd4d3b95cae39431ad092f7a99ba35f75ab5ed7c2073f9e2a",
        terminal.terminal_sha256,
    );
    const completion = try harness.coordinator.completeDispatchPin(
        pin,
        dispatch.interface(),
        terminal,
    );
    try std.testing.expectEqual(
        @as(u64, 0x758b_1f6f_12e2_814b),
        completion.completed_tree.state_digest,
    );
    try std.testing.expectEqual(
        @as(u64, 0x37e1_4048_0069_1921),
        completion.completed_tree.integrity,
    );
    try expectGoldenDigest(
        "cbfe82c46465013a683fd0306e592cb021fc75bad5c1a4c0849824f37b6a58af",
        leaseTreeSha256V1(completion.completed_tree),
    );
    try expectGoldenDigest(
        "c8db4b240da276a4574d5e1086a8174286a74510f7d60e07f8cb12a3f07f0cae",
        completion.bank_completion_sha256,
    );
    try expectGoldenDigest(
        "1248e6c72b4450976473bff890f6e3eb4a0a5f4ffa42474e84b0d03072080b3f",
        completion.completion_publication_binding_sha256,
    );
    try expectGoldenDigest(
        "66c2c7cf87a0a05ec6fd7605179ffc0695b479880340e73381cdb1f048f2205d",
        completion.completion_sha256,
    );

    _ = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    try harness.close();
}

test "LeaseTree adapter-authorized pre-submit rejection consumes exact pin" {
    var harness: TestHarness = .{};
    try harness.initDispatchOne();
    const first_admission = try harness.admit();
    _ = try harness.coordinator.cancelAdmission(
        first_admission,
    );
    const admission = try harness.admit();
    const materialized = try harness.coordinator.materialize(
        admission,
        harness.backend.adapter(),
        .{},
    );
    const lease = switch (materialized) {
        .active => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var dispatch: TestDispatchAdapter = .{
        .dispatch_authority_sha256 = testDigest("LeaseTree dispatch authority"),
        .queue_authority_sha256 = testDigest("LeaseTree queue authority"),
    };
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("LeaseTree dispatch request"),
    );
    try expectGoldenDigest(
        "2d9b5c285f548afcc5d94c74c2cd8bb820ef9735a1b3023ac0f43b896ea93dcc",
        pin.pin_sha256,
    );
    const permit =
        harness.coordinator_dispatches[0].bank_permit.?;
    const terminal = try makeDispatchTerminalV1(
        pin,
        .rejected_before_submit,
        zero_digest,
        zero_digest,
        zero_digest,
    );
    try expectGoldenDigest(
        "da4a5b8a14278caa357a85ebadd79766cca848f60b94924e857321a4a984612a",
        terminal.terminal_sha256,
    );

    // Public hashes are composition evidence only. Until this exact adapter
    // records the terminal, the callback rejects it and the Bank pin remains.
    try std.testing.expectError(
        Error.InvalidDispatchTerminal,
        harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        ),
    );
    try harness.bank.validateLeasePin(permit);
    try std.testing.expectEqual(
        @as(usize, 1),
        (try harness.coordinator.snapshot()).active_dispatches,
    );

    dispatch.expect(terminal);
    dispatch.reject_settlement = true;
    const pinned_tree_generation = harness.tree.generation;
    const pinned_structural_revision =
        harness.tree.structural_revision;
    try std.testing.expectError(
        Error.InvalidDispatchCompletion,
        harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        ),
    );
    try std.testing.expectError(
        resource.Error.StaleReservation,
        harness.bank.validateLeasePin(permit),
    );
    try std.testing.expect(
        harness.tree.generation > pinned_tree_generation,
    );
    try std.testing.expect(
        harness.tree.structural_revision >
            pinned_structural_revision,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        (try harness.coordinator.snapshot()).active_dispatches,
    );
    try std.testing.expectError(
        Error.DispatchInFlight,
        harness.coordinator.release(
            lease,
            harness.backend.adapter(),
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        dispatch.settlement_callback_count,
    );
    const terminal_callbacks_after_bank_release =
        dispatch.callback_count;
    dispatch.reject_settlement = false;
    const completion =
        try harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        );
    try std.testing.expectEqual(
        terminal_callbacks_after_bank_release,
        dispatch.callback_count,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        dispatch.settlement_callback_count,
    );
    try validateDispatchCompletionForPinV1(
        completion,
        pin,
        terminal,
    );
    try expectGoldenDigest(
        "cbfe82c46465013a683fd0306e592cb021fc75bad5c1a4c0849824f37b6a58af",
        leaseTreeSha256V1(completion.completed_tree),
    );
    try expectGoldenDigest(
        "c8db4b240da276a4574d5e1086a8174286a74510f7d60e07f8cb12a3f07f0cae",
        completion.bank_completion_sha256,
    );
    try expectGoldenDigest(
        "30426046c9fc16eb063430173119def8933e3d2a6c3cf43b58e5e237717d25de",
        completion.completion_sha256,
    );
    try std.testing.expectEqual(
        DispatchTerminalOutcomeV1.rejected_before_submit,
        completion.outcome,
    );
    try std.testing.expect(digestIsZero(
        completion.submission_sha256,
    ));
    try std.testing.expect(digestIsZero(
        completion.backend_completion_sha256,
    ));
    try std.testing.expect(digestIsZero(
        completion.output_sha256,
    ));
    try std.testing.expectEqual(
        lease.materialized_bytes,
        (try harness.bank.snapshotV3()).used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try harness.coordinator.snapshot()).active_dispatches,
    );
    try std.testing.expectError(
        Error.InvalidDispatchPin,
        harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        ),
    );

    _ = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    try harness.close();
}

test "LeaseTree dispatch pins fence release and complete out of order" {
    var harness: TestHarness = .{};
    try harness.initDispatch();
    const lease = try materializeTestLease(&harness);
    var dispatch: TestDispatchAdapter = .{};
    const first = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("first dispatch request"),
    );
    try validateDispatchPinV1(first);
    const tree_before_duplicate_request = harness.tree;
    try std.testing.expectError(
        Error.InvalidDispatchPin,
        harness.coordinator.acquireDispatchPin(
            lease,
            dispatch.interface(),
            first.dispatch_request_sha256,
        ),
    );
    try std.testing.expectEqualDeep(
        tree_before_duplicate_request,
        harness.tree,
    );

    var coordinator_snapshot = try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 2),
        coordinator_snapshot.dispatch_capacity,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        coordinator_snapshot.active_dispatches,
    );
    const before_release = harness.backend.snapshot();
    try std.testing.expectError(
        Error.DispatchInFlight,
        harness.coordinator.release(
            lease,
            harness.backend.adapter(),
        ),
    );
    var backend_snapshot = harness.backend.snapshot();
    try std.testing.expectEqual(
        before_release.free_calls,
        backend_snapshot.free_calls,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        backend_snapshot.live_objects,
    );
    var bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        lease.materialized_bytes,
        bank_snapshot.used.device_bytes,
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        bank_snapshot.live_allocations,
    );

    const second = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("second dispatch request"),
    );
    try std.testing.expect(
        second.dispatch_generation > first.dispatch_generation,
    );
    try std.testing.expectError(
        Error.DispatchSlotsExhausted,
        harness.coordinator.acquireDispatchPin(
            lease,
            dispatch.interface(),
            testDigest("third dispatch request"),
        ),
    );
    coordinator_snapshot = try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 2),
        coordinator_snapshot.active_dispatches,
    );

    const second_terminal = try makeDispatchTerminalV1(
        second,
        .succeeded,
        testDigest("second submission"),
        testDigest("second backend completion"),
        testDigest("second output"),
    );
    dispatch.expect(second_terminal);
    const callbacks_before_swap = dispatch.callback_count;
    const first_permit =
        harness.coordinator_dispatches[0].bank_permit.?;
    const second_permit =
        harness.coordinator_dispatches[1].bank_permit.?;
    harness.coordinator_dispatches[0].bank_permit =
        second_permit;
    harness.coordinator_dispatches[1].bank_permit =
        first_permit;
    try std.testing.expectError(
        Error.InvalidDispatchPin,
        harness.coordinator.completeDispatchPin(
            second,
            dispatch.interface(),
            second_terminal,
        ),
    );
    try std.testing.expectEqual(
        callbacks_before_swap,
        dispatch.callback_count,
    );
    try harness.bank.validateLeasePin(first_permit);
    try harness.bank.validateLeasePin(second_permit);
    harness.coordinator_dispatches[0].bank_permit =
        first_permit;
    harness.coordinator_dispatches[1].bank_permit =
        second_permit;
    const second_completion =
        try harness.coordinator.completeDispatchPin(
            second,
            dispatch.interface(),
            second_terminal,
        );
    try validateDispatchCompletionForPinV1(
        second_completion,
        second,
        second_terminal,
    );
    coordinator_snapshot = try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 1),
        coordinator_snapshot.active_dispatches,
    );
    try std.testing.expectError(
        Error.InvalidDispatchPin,
        harness.coordinator.completeDispatchPin(
            second,
            dispatch.interface(),
            second_terminal,
        ),
    );

    const first_terminal = try makeDispatchTerminalV1(
        first,
        .succeeded,
        testDigest("first submission"),
        testDigest("first backend completion"),
        testDigest("first output"),
    );
    dispatch.expect(first_terminal);
    dispatch.reject_terminal = true;
    try std.testing.expectError(
        Error.InvalidDispatchTerminal,
        harness.coordinator.completeDispatchPin(
            first,
            dispatch.interface(),
            first_terminal,
        ),
    );
    coordinator_snapshot = try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 1),
        coordinator_snapshot.active_dispatches,
    );
    dispatch.reject_terminal = false;
    const first_completion =
        try harness.coordinator.completeDispatchPin(
            first,
            dispatch.interface(),
            first_terminal,
        );
    try validateDispatchCompletionForPinV1(
        first_completion,
        first,
        first_terminal,
    );
    coordinator_snapshot = try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 0),
        coordinator_snapshot.active_dispatches,
    );

    const released = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    _ = switch (released) {
        .terminal => |terminal| terminal,
        else => return error.TestUnexpectedResult,
    };
    backend_snapshot = harness.backend.snapshot();
    try std.testing.expectEqual(
        @as(u64, 3),
        backend_snapshot.free_calls,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        backend_snapshot.live_objects,
    );
    bank_snapshot = try harness.bank.snapshotV3();
    try std.testing.expectEqual(
        @as(u64, 0),
        bank_snapshot.used.device_bytes,
    );
    try harness.close();
}

test "LeaseTree dispatch abort callback fences post-reserve source drift" {
    var harness: TestHarness = .{};
    try harness.initDispatch();
    const lease = try materializeTestLease(&harness);

    var reserve_fault_slots = [_]resource.Slot{.{}};
    var reserve_fault_bank = try resource.Bank.init(
        &reserve_fault_slots,
        .{},
        0x5253_565f_4452_4946,
    );
    var abort_fault_slots = [_]resource.Slot{.{}};
    var abort_fault_bank = try resource.Bank.init(
        &abort_fault_slots,
        .{},
        0x4142_545f_4452_4946,
    );
    var dispatch: TestDispatchAdapter = .{
        .coordinator_to_drift = &harness.coordinator,
        .drift_bank = &reserve_fault_bank,
        .abort_drift_bank = &abort_fault_bank,
    };
    const tree_before = harness.tree;
    const bank_before = try harness.bank.snapshotV3();

    try std.testing.expectError(
        Error.InvalidCoordinator,
        harness.coordinator.acquireDispatchPin(
            lease,
            dispatch.interface(),
            testDigest("post-reserve source drift"),
        ),
    );
    try std.testing.expectEqualDeep(tree_before, harness.tree);
    try std.testing.expectEqualDeep(
        bank_before,
        try harness.bank.snapshotV3(),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        dispatch.intent_reserve_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        dispatch.intent_abort_count,
    );
    try std.testing.expectEqual(
        @as(*resource.Bank, &abort_fault_bank),
        harness.coordinator.bank,
    );

    harness.coordinator.bank = &harness.bank;
    const coordinator_snapshot =
        try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 0),
        coordinator_snapshot.active_dispatches,
    );
    _ = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    try harness.close();
}

test "LeaseTree dispatch abort callback fences atomic Bank acquire failure" {
    var harness: TestHarness = .{};
    try harness.initDispatchWithoutBankPins();
    const lease = try materializeTestLease(&harness);

    var abort_fault_slots = [_]resource.Slot{.{}};
    var abort_fault_bank = try resource.Bank.init(
        &abort_fault_slots,
        .{},
        0x4142_545f_4241_4e4b,
    );
    var dispatch: TestDispatchAdapter = .{
        .coordinator_to_drift = &harness.coordinator,
        .abort_drift_bank = &abort_fault_bank,
    };
    const tree_before = harness.tree;
    const bank_before = try harness.bank.snapshotV3();

    try std.testing.expectError(
        Error.InvalidCoordinator,
        harness.coordinator.acquireDispatchPin(
            lease,
            dispatch.interface(),
            testDigest("atomic Bank acquire failure"),
        ),
    );
    try std.testing.expectEqualDeep(tree_before, harness.tree);
    try std.testing.expectEqualDeep(
        bank_before,
        try harness.bank.snapshotV3(),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        dispatch.intent_reserve_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        dispatch.intent_abort_count,
    );
    try std.testing.expectEqual(
        @as(*resource.Bank, &abort_fault_bank),
        harness.coordinator.bank,
    );

    harness.coordinator.bank = &harness.bank;
    const coordinator_snapshot =
        try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 0),
        coordinator_snapshot.active_dispatches,
    );
    _ = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    try harness.close();
}

test "LeaseTree dispatch pin rejects missing authority tamper and callback drift" {
    var no_pins: TestHarness = .{};
    try no_pins.initDispatchWithoutBankPins();
    const no_pins_lease = try materializeTestLease(&no_pins);
    var no_pins_dispatch: TestDispatchAdapter = .{};
    const no_pins_tree = no_pins.tree;
    const no_pins_bank = try no_pins.bank.snapshotV3();
    try std.testing.expectError(
        resource.Error.InvalidConfiguration,
        no_pins.coordinator.acquireDispatchPin(
            no_pins_lease,
            no_pins_dispatch.interface(),
            testDigest("missing Bank pin storage"),
        ),
    );
    try std.testing.expectEqualDeep(no_pins_tree, no_pins.tree);
    try std.testing.expectEqualDeep(
        no_pins_bank,
        try no_pins.bank.snapshotV3(),
    );
    const no_pins_snapshot = try no_pins.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 0),
        no_pins_snapshot.active_dispatches,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        no_pins_dispatch.intent_reserve_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        no_pins_dispatch.intent_abort_count,
    );
    _ = try no_pins.coordinator.release(
        no_pins_lease,
        no_pins.backend.adapter(),
    );
    try no_pins.close();

    var harness: TestHarness = .{};
    try harness.initDispatch();
    const lease = try materializeTestLease(&harness);
    var dispatch: TestDispatchAdapter = .{};
    var fault_slots = [_]resource.Slot{.{}};
    var fault_bank = try resource.Bank.init(
        &fault_slots,
        .{},
        0x4452_4946_5442_414e,
    );
    dispatch.reject_intent = true;
    dispatch.coordinator_to_drift = &harness.coordinator;
    dispatch.drift_bank = &fault_bank;
    const tree_before_rejected_intent = harness.tree;
    try std.testing.expectError(
        Error.InvalidCoordinator,
        harness.coordinator.acquireDispatchPin(
            lease,
            dispatch.interface(),
            testDigest("rejected dispatch intent"),
        ),
    );
    try std.testing.expectEqualDeep(
        tree_before_rejected_intent,
        harness.tree,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        dispatch.intent_reserve_count,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        dispatch.intent_abort_count,
    );
    harness.coordinator.bank = &harness.bank;
    dispatch.coordinator_to_drift = null;
    dispatch.drift_bank = null;
    dispatch.reject_intent = false;
    const pin = try harness.coordinator.acquireDispatchPin(
        lease,
        dispatch.interface(),
        testDigest("adversarial dispatch request"),
    );
    const intent = harness.coordinator_dispatches[0].intent.?;
    try validateDispatchPinForIntentV1(pin, intent);
    var substituted_intent = intent;
    substituted_intent.dispatch_generation += 1;
    substituted_intent.intent_sha256 =
        dispatchPinIntentRootV1(substituted_intent);
    try validateDispatchPinIntentV1(substituted_intent);
    try std.testing.expectError(
        Error.InvalidDispatchPin,
        validateDispatchPinForIntentV1(
            pin,
            substituted_intent,
        ),
    );
    const terminal = try makeDispatchTerminalV1(
        pin,
        .terminal_failure,
        testDigest("failed dispatch submission"),
        testDigest("terminal dispatch failure"),
        zero_digest,
    );
    dispatch.expect(terminal);

    var tampered = terminal;
    tampered.backend_completion_sha256[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidDispatchTerminal,
        harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            tampered,
        ),
    );
    var foreign: TestDispatchAdapter = .{};
    foreign.expect(terminal);
    try std.testing.expectError(
        Error.InvalidDispatchAdapter,
        harness.coordinator.completeDispatchPin(
            pin,
            foreign.interface(),
            terminal,
        ),
    );

    dispatch.coordinator_to_drift = &harness.coordinator;
    dispatch.drift_bank = &fault_bank;
    try std.testing.expectError(
        Error.InvalidCoordinator,
        harness.coordinator.completeDispatchPin(
            pin,
            dispatch.interface(),
            terminal,
        ),
    );
    harness.coordinator.bank = &harness.bank;
    dispatch.coordinator_to_drift = null;
    dispatch.drift_bank = null;
    var coordinator_snapshot = try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 1),
        coordinator_snapshot.active_dispatches,
    );
    try harness.bank.validateLeasePin(
        harness.coordinator_dispatches[0].bank_permit.?,
    );

    const completion = try harness.coordinator.completeDispatchPin(
        pin,
        dispatch.interface(),
        terminal,
    );
    try validateDispatchCompletionForPinV1(
        completion,
        pin,
        terminal,
    );
    var publication_substitution = completion;
    publication_substitution
        .completion_publication_binding_sha256[0] ^= 1;
    publication_substitution.completion_sha256 =
        dispatchCompletionRootV1(publication_substitution);
    try validateDispatchCompletionV1(publication_substitution);
    try std.testing.expectError(
        Error.InvalidDispatchCompletion,
        validateDispatchCompletionForPinV1(
            publication_substitution,
            pin,
            terminal,
        ),
    );
    var authority_substitution = completion;
    authority_substitution.completed_tree.authority_key ^= 1;
    authority_substitution.completed_tree =
        resealTestLeaseTree(authority_substitution.completed_tree);
    authority_substitution.completion_sha256 =
        dispatchCompletionRootV1(authority_substitution);
    try validateDispatchCompletionV1(authority_substitution);
    try std.testing.expectError(
        Error.InvalidDispatchCompletion,
        validateDispatchCompletionForPinV1(
            authority_substitution,
            pin,
            terminal,
        ),
    );
    var ceiling_substitution = completion;
    ceiling_substitution.completed_tree.ceiling.device_bytes += 1;
    ceiling_substitution.completed_tree =
        resealTestLeaseTree(ceiling_substitution.completed_tree);
    ceiling_substitution.completion_sha256 =
        dispatchCompletionRootV1(ceiling_substitution);
    try validateDispatchCompletionV1(ceiling_substitution);
    try std.testing.expectError(
        Error.InvalidDispatchCompletion,
        validateDispatchCompletionForPinV1(
            ceiling_substitution,
            pin,
            terminal,
        ),
    );
    var generation_substitution = completion;
    generation_substitution.completed_tree.generation =
        pin.pinned_tree.generation;
    generation_substitution.completed_tree.structural_revision =
        pin.pinned_tree.structural_revision;
    generation_substitution.completed_tree =
        resealTestLeaseTree(generation_substitution.completed_tree);
    generation_substitution.completion_sha256 =
        dispatchCompletionRootV1(generation_substitution);
    try validateDispatchCompletionV1(generation_substitution);
    try std.testing.expectError(
        Error.InvalidDispatchCompletion,
        validateDispatchCompletionForPinV1(
            generation_substitution,
            pin,
            terminal,
        ),
    );
    var active_nodes_substitution = completion;
    active_nodes_substitution.completed_tree.active_nodes =
        @intCast(pin.allocation_count);
    active_nodes_substitution.completed_tree =
        resealTestLeaseTree(active_nodes_substitution.completed_tree);
    active_nodes_substitution.completion_sha256 =
        dispatchCompletionRootV1(active_nodes_substitution);
    try validateDispatchCompletionV1(active_nodes_substitution);
    try std.testing.expectError(
        Error.InvalidDispatchCompletion,
        validateDispatchCompletionForPinV1(
            active_nodes_substitution,
            pin,
            terminal,
        ),
    );
    coordinator_snapshot = try harness.coordinator.snapshot();
    try std.testing.expectEqual(
        @as(usize, 0),
        coordinator_snapshot.active_dispatches,
    );
    _ = try harness.coordinator.release(
        lease,
        harness.backend.adapter(),
    );
    try harness.close();
}
