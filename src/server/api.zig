//! Bounded loopback HTTP/1.1 socket adapter.
//!
//! This layer owns only listener and connection framing. Request decoding,
//! service execution, and response encoding remain in
//! `prepared_text_unary_http.zig`.

const std = @import("std");
const builtin = @import("builtin");
const prepared_http = @import("prepared_text_unary_http.zig");
const cancellable_writer =
    @import("cancellable_socket_writer.zig");

pub const Error = error{
    InvalidConfiguration,
    NonLoopbackBind,
    ReceiveTimeoutRequiresManagedLifecycle,
    FullRequestTimeoutRequiresManagedLifecycle,
    PeerResetPollRequiresManagedLifecycle,
    PeerSendClosePolicyRequiresManagedLifecycle,
    ResponseWriteQuantumRequiresManagedLifecycle,
    InvalidConcurrentWorkerCount,
    InvalidConcurrentPendingCapacity,
    ConcurrentStopAfterRequestsUnsupported,
    ConcurrentLifecycleConfigurationMismatch,
    ConcurrentListenerModeUnsupported,
};

pub const minimum_receive_timeout_ns: u64 = std.time.ns_per_ms;
pub const maximum_receive_timeout_ns: u64 = 60 * std.time.ns_per_s;
pub const minimum_full_request_timeout_ns: u64 =
    minimum_receive_timeout_ns;
pub const maximum_full_request_timeout_ns: u64 =
    maximum_receive_timeout_ns;
pub const minimum_peer_reset_poll_timeout_ns: u64 =
    std.time.ns_per_ms;
pub const maximum_peer_reset_poll_timeout_ns: u64 =
    std.time.ns_per_s;
pub const minimum_response_write_quantum_bytes: u16 =
    cancellable_writer.minimum_max_send_bytes;
pub const maximum_response_write_quantum_bytes: u16 =
    cancellable_writer.maximum_max_send_bytes;
pub const minimum_managed_concurrent_workers_v1: u8 = 1;
pub const maximum_managed_concurrent_workers_v1: u8 = 16;
pub const minimum_managed_pending_connections_v1: u8 = 1;
pub const maximum_managed_pending_connections_v1: u8 = 64;
pub const maximum_managed_connection_slots_v1: u8 = 80;
const managed_lifecycle_poll_interval_ms: i32 = 100;

pub const LifecycleError = error{
    InvalidGeneration,
    InvalidTransition,
    InvalidConnectionCapacity,
    ConnectionAlreadyActive,
    NoActiveConnection,
    ConnectionSlotMismatch,
    ConnectionSlotGenerationMismatch,
    ConnectionSequenceMismatch,
    ConnectionHandleMismatch,
    MissingTransportOwner,
    TransportOwnerMismatch,
    ConnectionPhaseMismatch,
    ConnectionInterrupted,
    ConnectionSignalFailed,
    WorkIdentityMismatch,
    WorkCancellationRecoveryRequired,
    DrainReceiptMismatch,
    DrainSettlementMismatch,
    DrainSettlementUnavailable,
    DrainSettlementMemberOutOfRange,
    CounterOverflow,
};

/// Controls whether a received TCP FIN may cancel already-admitted work.
///
/// A FIN only proves that the peer closed its send half; it may still be
/// waiting for the response. The default therefore preserves normal
/// half-closed clients. Hosts may opt in only when their transport contract
/// defines an orderly FIN after request admission as response abandonment.
pub const PeerSendClosePolicyV1 = enum {
    preserve_response,
    abandon_after_complete_request,
};

pub const ServerConfig = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    stop_after_requests: ?u64 = null,
    /// Absolute monotonic elapsed-time bound from accept through the last
    /// required request byte. Zero disables the bounded receive timer.
    receive_timeout_ns: u64 = 0,
    /// Absolute monotonic elapsed-time bound from accept through local
    /// response write completion. Response retirement and observer cleanup
    /// follow without changing that winner. Zero disables the watchdog.
    full_request_timeout_ns: u64 = 0,
    /// Per-checkpoint event-driven wait for an admitted peer transport stop.
    /// Zero keeps the production path non-blocking; bounded acceptance
    /// fixtures may opt in when they need reset or FIN delivery to precede
    /// the next work quantum.
    peer_reset_poll_timeout_ns: u64 = 0,
    /// Keeps TCP send-half-close compatible by default. Opt in only when the
    /// host contract makes orderly FIN authoritative abandonment evidence.
    peer_send_close_policy: PeerSendClosePolicyV1 =
        .preserve_response,
    /// Upper bound for one managed response send syscall. A drain racing an
    /// already-started syscall may pass at most this many additional bytes.
    response_write_quantum_bytes: u16 =
        maximum_response_write_quantum_bytes,
};

const ManagedConcurrentListenerModeV1 = union(enum) {
    posix_flags: usize,

    fn enable(
        handle: std.net.Stream.Handle,
    ) !ManagedConcurrentListenerModeV1 {
        if (builtin.os.tag == .windows)
            return Error.ConcurrentListenerModeUnsupported;

        const original_flags = try std.posix.fcntl(
            handle,
            std.posix.F.GETFL,
            0,
        );
        const nonblocking_mask: usize =
            1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
        if (original_flags & nonblocking_mask == 0) {
            _ = try std.posix.fcntl(
                handle,
                std.posix.F.SETFL,
                original_flags | nonblocking_mask,
            );
        }
        return .{ .posix_flags = original_flags };
    }

    fn restore(
        self: ManagedConcurrentListenerModeV1,
        handle: std.net.Stream.Handle,
    ) !void {
        if (builtin.os.tag == .windows)
            return Error.ConcurrentListenerModeUnsupported;
        switch (self) {
            .posix_flags => |original_flags| {
                _ = try std.posix.fcntl(
                    handle,
                    std.posix.F.SETFL,
                    original_flags,
                );
            },
        }
    }
};

fn setAcceptedSocketBlockingV1(
    handle: std.net.Stream.Handle,
) !void {
    if (builtin.os.tag == .windows)
        return Error.ConcurrentListenerModeUnsupported;

    const current_flags = try std.posix.fcntl(
        handle,
        std.posix.F.GETFL,
        0,
    );
    const nonblocking_mask: usize =
        1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    if (current_flags & nonblocking_mask != 0) {
        _ = try std.posix.fcntl(
            handle,
            std.posix.F.SETFL,
            current_flags & ~nonblocking_mask,
        );
    }
}

pub const ManagedStateV1 = enum(u8) {
    starting = 1,
    ready = 2,
    draining = 3,
    stopped = 4,
    failed = 5,
};

pub const ManagedConnectionPhaseV1 = enum(u8) {
    none = 0,
    receiving_head = 1,
    request_head_received = 2,
    request_received = 3,
    request_admitted = 4,
    response_ready = 5,
    response_writing = 6,
    response_written = 7,
    queued = 8,
};

const HardStopCauseV1 = enum {
    receive_timeout,
    full_request_timeout,
    peer_reset,
    peer_send_close,
    response_transport_failure,
};

const ResponseStopCauseV1 = enum {
    drain,
    full_request_timeout,
    failure,
    peer_send_close,
};

const ResponseWriteStopStateV1 = union(enum) {
    none,
    requested: ResponseStopCauseV1,
    observed: ResponseStopCauseV1,
};

const FailureSignalResultV1 = struct {
    claimed: bool = false,
    signal_failed: bool = false,
};

pub const ManagedSnapshotV1 = struct {
    process_generation: u64,
    state: ManagedStateV1,
    connection_capacity: u8 = 1,
    accepted_connections: u64,
    completed_connections: u64,
    failed_connections: u64,
    active_connections: u8,
    queued_connections: u8 = 0,
    drain_signaled_connections: u64,
    receive_timeout_signaled_connections: u64,
    full_request_timeout_signaled_connections: u64 = 0,
    full_request_timeout_cancelled_work_connections: u64 = 0,
    full_request_timeout_cancelled_response_connections: u64 = 0,
    full_request_timeout_requested_response_write_connections: u64 = 0,
    full_request_timeout_cancelled_response_write_connections: u64 = 0,
    drain_cancelled_work_connections: u64 = 0,
    failure_signaled_connections: u64 = 0,
    failure_cancelled_work_connections: u64 = 0,
    failure_cancelled_response_connections: u64 = 0,
    failure_requested_response_write_connections: u64 = 0,
    failure_cancelled_response_write_connections: u64 = 0,
    peer_reset_connections: u64 = 0,
    peer_reset_cancelled_work_connections: u64 = 0,
    peer_send_closed_connections: u64 = 0,
    peer_send_close_cancelled_work_connections: u64 = 0,
    peer_send_close_cancelled_response_connections: u64 = 0,
    peer_send_close_requested_response_write_connections: u64 = 0,
    peer_send_close_cancelled_response_write_connections: u64 = 0,
    drain_cancelled_response_connections: u64 = 0,
    drain_requested_response_write_connections: u64 = 0,
    drain_cancelled_response_write_connections: u64 = 0,
    response_write_transport_failed_connections: u64 = 0,
    active_connection_phase: ManagedConnectionPhaseV1,
    last_drain_signaled_phase: ManagedConnectionPhaseV1,
    last_receive_timeout_signaled_phase: ManagedConnectionPhaseV1,
    last_full_request_timeout_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_closed_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_response_write_transport_failed_phase: ManagedConnectionPhaseV1 = .none,
    peer_send_close_zero_request_bytes_connections: u64 = 0,
    peer_send_close_partial_request_head_connections: u64 = 0,
    peer_send_close_partial_request_body_connections: u64 = 0,
    last_peer_send_close_receive_phase: ManagedConnectionPhaseV1 = .none,
};

pub const ManagedConnectionLeaseV1 = struct {
    process_generation: u64,
    connection_sequence: u64,
    slot_index: u8,
    slot_generation: u64,
    handle: std.net.Stream.Handle,
};

pub const ManagedConcurrentConfigV1 = struct {
    worker_count: u8 = 2,
    pending_connection_capacity: u8 = 8,
};

pub const ManagedConcurrentEventKindV1 = enum(u8) {
    enqueued = 1,
    backpressure_paused = 2,
    backpressure_resumed = 3,
    dispatched = 4,
    retired = 5,
    queued_receive_timeout = 6,
    queued_full_request_timeout = 7,
    queued_drain = 8,
    queued_failure = 9,
    running_failure = 10,
};

pub const ManagedConcurrentEventV1 = struct {
    ordinal: u64,
    kind: ManagedConcurrentEventKindV1,
    lease: ?ManagedConnectionLeaseV1 = null,
    worker_index: ?u8 = null,
    queued_connections: u8,
    running_connections: u8,
    /// Captured at the same lifecycle-mutex linearization boundary that
    /// assigns `ordinal`. Zero means that this platform clock was unavailable.
    /// Callback invocation can occur later and in a different order.
    linearized_monotonic_ns: u64 = 0,
};

/// Evidence callbacks may execute concurrently on the acceptor, worker,
/// watchdog, or drain-caller thread and may arrive in a different order from
/// their canonical `event.ordinal`. The context must remain valid until the
/// serving call returns and must synchronize every shared access.
pub const ManagedConcurrentObserverV1 = struct {
    context: *anyopaque,
    event_fn: *const fn (
        *anyopaque,
        ManagedConcurrentEventV1,
    ) void,

    fn observe(
        self: ManagedConcurrentObserverV1,
        event: ManagedConcurrentEventV1,
    ) void {
        self.event_fn(self.context, event);
    }
};

/// Optional evidence and work-boundary controls for concurrent serving.
///
/// Work callbacks are a control seam: they can block, fail, and change request
/// timing or outcome. They remain serialized by the HTTP runtime's request
/// mutex. The caller owns both callback contexts and must keep them alive until
/// the serving call returns after every fixed worker and the shared watchdog
/// join. Event callbacks retain the evidence-only, outside-lock semantics
/// documented by the serving entrypoint.
pub const ManagedConcurrentControlsV1 = struct {
    event_observer: ?ManagedConcurrentObserverV1 = null,
    work_control: ?prepared_http.RequestWorkControlV1 = null,
};

pub const ManagedConnectionPhaseCountsV1 = struct {
    queued: u8 = 0,
    receiving_head: u8 = 0,
    request_head_received: u8 = 0,
    request_received: u8 = 0,
    request_admitted: u8 = 0,
    response_ready: u8 = 0,
    response_writing: u8 = 0,
    response_written: u8 = 0,
};

pub const managed_drain_receipt_abi_version_v1: u16 = 1;

/// Host-selected initiation behavior at the managed lifecycle boundary.
///
/// `finish_published` closes new admission but allows exact work published
/// before the drain linearization point, plus already materialized responses,
/// to continue. It does not guarantee successful local write or peer receipt.
pub const ManagedDrainPolicyV1 = enum(u8) {
    cancel_active = 1,
    finish_published = 2,
};

/// Mutually exclusive initiation decisions for the phase snapshot captured in
/// `ManagedDrainInitiationReceiptV1`.
///
/// The five fields sum to the total phase count. `resumable` is always zero in
/// ABI V1 because no committed-progress continuation binding exists yet.
pub const ManagedDrainDecisionCountsV1 = struct {
    abort_selected: u8 = 0,
    finish_selected: u8 = 0,
    reject_unpublished: u8 = 0,
    preexisting_stop: u8 = 0,
    resumable: u8 = 0,
};

/// Evidence returned when a host initiates or revisits managed drain.
///
/// This is a source-level Zig contract, not a C layout or per-connection final
/// settlement. Decision counts describe selection at one lifecycle-mutex
/// boundary; transport failure, timeout, reset, and peer close may still win
/// later. The first receipt opens the separate retained settlement session.
/// The caller-owned, unkeyed value is inspection input, not authentic
/// authority.
pub const ManagedDrainInitiationReceiptV1 = struct {
    receipt_abi_version: u16 =
        managed_drain_receipt_abi_version_v1,
    process_generation: u64,
    requested_policy: ManagedDrainPolicyV1,
    effective_policy: ManagedDrainPolicyV1,
    drain_was_new: bool,
    policy_was_escalated: bool = false,
    /// False for a stopped no-op and for a repeated serial policy revisit
    /// that preserves the legacy response window.
    connection_actions_applied: bool,
    admission_was_open: bool,
    state_before: ManagedStateV1,
    state_at_linearization: ManagedStateV1,
    accepted_connections: u64,
    completed_connections: u64,
    failed_connections: u64,
    phase_counts: ManagedConnectionPhaseCountsV1,
    decisions: ManagedDrainDecisionCountsV1,
    synchronously_retired_connections: u8 = 0,
    pending_settlement_connections: u8,
    active_work: ?prepared_http.WorkIdentityV1 = null,
    active_work_owner: ?prepared_http.TransportOwnerTokenV1 = null,
    work_cancellation: prepared_http.DrainCancellationOutcomeV1 = .none,
    work_cancellation_winner: ?prepared_http.WorkCancellationCauseV1 = null,
    work_cancellation_was_new: bool = false,
};

/// Current aggregate settlement progress for one initiation receipt.
///
/// This compatibility inspection does not attribute each retired connection
/// to a final drain outcome. Use `openManagedDrainSettlementSessionV1` and its
/// member inspections for retained per-connection evidence. Neither surface
/// authenticates its caller-owned source value as external authority.
pub const ManagedDrainInspectionV1 = struct {
    process_generation: u64,
    effective_policy: ManagedDrainPolicyV1,
    state: ManagedStateV1,
    completed_since_linearization: u64,
    failed_since_linearization: u64,
    active_connections: u8,
    queued_connections: u8,
    settled: bool,
};

pub const managed_drain_settlement_abi_version_v1: u16 = 1;

/// Stable identity for the one bounded settlement cohort created by a
/// ready-to-draining transition. The caller-owned value is correlation
/// evidence, not authentication or continuation authority. ABI V1 describes
/// this source-level Zig contract; it is not a stable binary C layout.
pub const ManagedDrainSettlementSessionV1 = struct {
    settlement_abi_version: u16 =
        managed_drain_settlement_abi_version_v1,
    process_generation: u64,
    drain_epoch: u64,
    initial_policy_revision: u16,
    initial_effective_policy: ManagedDrainPolicyV1,
    accepted_connections: u64,
    completed_connections: u64,
    failed_connections: u64,
    cohort_connections: u8,
};

pub const ManagedDrainConnectionDecisionV1 = enum(u8) {
    abort_selected = 1,
    finish_selected = 2,
    reject_unpublished = 3,
    preexisting_stop = 4,
    resumable = 5,
};

pub const ManagedDrainConnectionRetirementStateV1 = enum(u8) {
    active = 1,
    transport_closing = 2,
    settled = 3,
};

/// Lifecycle accounting and the actual terminal cause are deliberately
/// separate. A locally completed HTTP error can still have `drain` as its
/// terminal cause.
pub const ManagedDrainConnectionTerminalStatusV1 = enum(u8) {
    completed = 1,
    failed = 2,
};

pub const ManagedDrainConnectionTerminalCauseV1 = enum(u8) {
    normal_completion = 1,
    drain = 2,
    reject_unpublished = 3,
    receive_timeout = 4,
    full_request_timeout = 5,
    peer_reset = 6,
    peer_send_close = 7,
    response_transport_failure = 8,
    transport_failure = 9,
    lifecycle_failure = 10,
    application_failure = 11,
    preexisting_work_stop = 12,
};

/// Describes how the transport owner proved that its native stream was no
/// longer owned. `forced_after_join` is conservative recovery evidence and
/// never upgrades `evidence_complete`.
pub const ManagedDrainTransportCloseEvidenceV1 = enum(u8) {
    owner_confirmed = 1,
    detached_owner_confirmed = 2,
    forced_after_join = 3,
};

/// Selection retained for one exact member of the first drain cohort.
///
/// The initial fields never change. A finish-to-cancel escalation may update
/// only the latest fields while this member is still active.
pub const ManagedDrainConnectionSelectionV1 = struct {
    member_index: u8,
    owner: prepared_http.TransportOwnerTokenV1,
    phase_at_first_linearization: ManagedConnectionPhaseV1,
    initial_decision: ManagedDrainConnectionDecisionV1,
    initial_effective_policy: ManagedDrainPolicyV1,
    latest_decision: ManagedDrainConnectionDecisionV1,
    latest_effective_policy: ManagedDrainPolicyV1,
    latest_policy_revision: u16,
    work_identity: ?prepared_http.WorkIdentityV1 = null,
    work_cancellation: prepared_http.DrainCancellationOutcomeV1 = .none,
    work_cancellation_winner: ?prepared_http.WorkCancellationCauseV1 = null,
    resumable: bool = false,
};

/// Immutable final receipt for one drain-cohort connection.
///
/// It is published only after logical retirement and an explicit native
/// transport-close confirmation. `local_write_completed` is not peer receipt
/// or peer processing. ABI V1 cannot report resumable work.
pub const ManagedDrainConnectionSettlementReceiptV1 = struct {
    settlement_abi_version: u16 =
        managed_drain_settlement_abi_version_v1,
    process_generation: u64,
    drain_epoch: u64,
    member_index: u8,
    owner: prepared_http.TransportOwnerTokenV1,
    phase_at_first_linearization: ManagedConnectionPhaseV1,
    initial_decision: ManagedDrainConnectionDecisionV1,
    initial_effective_policy: ManagedDrainPolicyV1,
    latest_decision: ManagedDrainConnectionDecisionV1,
    latest_effective_policy: ManagedDrainPolicyV1,
    latest_policy_revision: u16,
    phase_at_logical_retirement: ManagedConnectionPhaseV1,
    /// Cohort-local, one-based order in which logical ownership retired.
    logical_retirement_ordinal: u8,
    /// Cohort-local, one-based order in which native-close evidence finalized.
    settlement_ordinal: u8,
    terminal_status: ManagedDrainConnectionTerminalStatusV1,
    terminal_cause: ManagedDrainConnectionTerminalCauseV1,
    /// Absolute post-increment lifecycle counter; zero for a failed member.
    completed_counter_ordinal: u64,
    /// Absolute post-increment lifecycle counter; zero for a completed member.
    failed_counter_ordinal: u64,
    work_identity: ?prepared_http.WorkIdentityV1 = null,
    work_cancellation: prepared_http.DrainCancellationOutcomeV1 = .none,
    work_cancellation_winner: ?prepared_http.WorkCancellationCauseV1 = null,
    receive_retired: bool,
    full_request_timeout_retired: bool,
    work_retired: bool,
    response_retired: bool,
    response_write_progress_bytes: u64,
    local_write_completed: bool,
    transport_close_confirmed: bool,
    transport_close_evidence: ManagedDrainTransportCloseEvidenceV1,
    evidence_complete: bool,
    resumable: bool = false,
};

pub const ManagedDrainConnectionInspectionV1 = struct {
    selection: ManagedDrainConnectionSelectionV1,
    retirement_state: ManagedDrainConnectionRetirementStateV1,
    settlement: ?ManagedDrainConnectionSettlementReceiptV1 = null,
};

pub const ManagedDrainSettlementsInspectionV1 = struct {
    process_generation: u64,
    drain_epoch: u64,
    current_policy_revision: u16,
    effective_policy: ManagedDrainPolicyV1,
    state: ManagedStateV1,
    cohort_connections: u8,
    active_connections: u8,
    transport_closing_connections: u8,
    settled_connections: u8,
    logically_completed_connections: u8,
    logically_failed_connections: u8,
    resumable_connections: u8,
    settled: bool,
};

const ManagedDrainPolicyResolutionV1 = struct {
    effective_policy: ManagedDrainPolicyV1,
    policy_was_escalated: bool = false,
};

const ManagedDrainBeginResultV1 = struct {
    active_was_present: bool,
    receipt: ManagedDrainInitiationReceiptV1,
};

fn managedDrainPhaseTotalV1(
    counts: ManagedConnectionPhaseCountsV1,
) u16 {
    return @as(u16, counts.queued) +
        @as(u16, counts.receiving_head) +
        @as(u16, counts.request_head_received) +
        @as(u16, counts.request_received) +
        @as(u16, counts.request_admitted) +
        @as(u16, counts.response_ready) +
        @as(u16, counts.response_writing) +
        @as(u16, counts.response_written);
}

fn managedDrainDecisionTotalV1(
    counts: ManagedDrainDecisionCountsV1,
) u16 {
    return @as(u16, counts.abort_selected) +
        @as(u16, counts.finish_selected) +
        @as(u16, counts.reject_unpublished) +
        @as(u16, counts.preexisting_stop) +
        @as(u16, counts.resumable);
}

fn validateManagedDrainReceiptShapeV1(
    receipt: *const ManagedDrainInitiationReceiptV1,
) LifecycleError!void {
    if (receipt.receipt_abi_version !=
        managed_drain_receipt_abi_version_v1)
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    const phase_total = managedDrainPhaseTotalV1(
        receipt.phase_counts,
    );
    if (managedDrainDecisionTotalV1(receipt.decisions) !=
        phase_total or
        receipt.decisions.resumable != 0 or
        @as(u16, receipt.synchronously_retired_connections) +
            @as(u16, receipt.pending_settlement_connections) !=
            phase_total)
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    const accounted_connections =
        @as(u128, receipt.completed_connections) +
        @as(u128, receipt.failed_connections) +
        @as(u128, phase_total);
    if (accounted_connections !=
        @as(u128, receipt.accepted_connections))
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    switch (receipt.state_before) {
        .ready => if (!receipt.drain_was_new or
            receipt.state_at_linearization != .draining or
            !receipt.connection_actions_applied or
            receipt.requested_policy != receipt.effective_policy)
        {
            return LifecycleError.DrainReceiptMismatch;
        },
        .draining => if (receipt.drain_was_new or
            receipt.state_at_linearization != .draining)
        {
            return LifecycleError.DrainReceiptMismatch;
        },
        .stopped => if (receipt.drain_was_new or
            receipt.state_at_linearization != .stopped or
            receipt.connection_actions_applied or
            phase_total != 0)
        {
            return LifecycleError.DrainReceiptMismatch;
        },
        .starting, .failed => return LifecycleError.DrainReceiptMismatch,
    }
    if ((receipt.active_work == null) !=
        (receipt.active_work_owner == null))
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    if (receipt.active_work == null and
        (receipt.work_cancellation != .none or
            receipt.work_cancellation_winner != null or
            receipt.work_cancellation_was_new))
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    if (receipt.work_cancellation == .none and
        receipt.work_cancellation_winner != null)
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    if (receipt.policy_was_escalated and
        (receipt.state_before != .draining or
            !receipt.connection_actions_applied or
            receipt.requested_policy != .cancel_active or
            receipt.effective_policy != .cancel_active))
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    if (receipt.state_before != .stopped and
        receipt.requested_policy == .cancel_active and
        receipt.effective_policy != .cancel_active)
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    if (receipt.work_cancellation_was_new and
        (receipt.active_work == null or
            receipt.effective_policy != .cancel_active or
            receipt.work_cancellation_winner != .drain))
    {
        return LifecycleError.DrainReceiptMismatch;
    }
}

fn validateManagedDrainSettlementSessionShapeV1(
    session: *const ManagedDrainSettlementSessionV1,
) LifecycleError!void {
    if (session.settlement_abi_version !=
        managed_drain_settlement_abi_version_v1 or
        session.process_generation == 0 or
        session.drain_epoch == 0 or
        session.initial_policy_revision != 1 or
        session.cohort_connections >
            maximum_managed_connection_slots_v1)
    {
        return LifecycleError.DrainSettlementMismatch;
    }
    const accounted =
        @as(u128, session.completed_connections) +
        @as(u128, session.failed_connections) +
        @as(u128, session.cohort_connections);
    if (accounted != @as(u128, session.accepted_connections))
        return LifecycleError.DrainSettlementMismatch;
}

fn validateManagedDrainConnectionSettlementReceiptShapeV1(
    receipt: *const ManagedDrainConnectionSettlementReceiptV1,
    session: *const ManagedDrainSettlementSessionV1,
    current_policy_revision: u16,
) LifecycleError!void {
    if (receipt.settlement_abi_version !=
        managed_drain_settlement_abi_version_v1 or
        receipt.process_generation != session.process_generation or
        receipt.drain_epoch != session.drain_epoch or
        receipt.member_index >= session.cohort_connections or
        receipt.latest_policy_revision <
            session.initial_policy_revision or
        receipt.latest_policy_revision >
            current_policy_revision or
        receipt.phase_at_first_linearization == .none or
        receipt.phase_at_logical_retirement == .none or
        receipt.logical_retirement_ordinal == 0 or
        receipt.settlement_ordinal == 0 or
        !receipt.transport_close_confirmed or
        receipt.resumable or
        (receipt.transport_close_evidence ==
            .forced_after_join and receipt.evidence_complete))
    {
        return LifecycleError.DrainSettlementMismatch;
    }
    switch (receipt.terminal_status) {
        .completed => if (receipt.completed_counter_ordinal == 0 or
            receipt.failed_counter_ordinal != 0)
        {
            return LifecycleError.DrainSettlementMismatch;
        },
        .failed => if (receipt.failed_counter_ordinal == 0 or
            receipt.completed_counter_ordinal != 0)
        {
            return LifecycleError.DrainSettlementMismatch;
        },
    }
    if (receipt.work_cancellation == .none and
        receipt.work_cancellation_winner != null)
    {
        return LifecycleError.DrainSettlementMismatch;
    }
    if (receipt.local_write_completed and
        (receipt.phase_at_logical_retirement != .response_written or
            !receipt.response_retired))
    {
        return LifecycleError.DrainSettlementMismatch;
    }
    if (receipt.evidence_complete and
        (!receipt.receive_retired or
            !receipt.full_request_timeout_retired or
            (receipt.work_identity != null and
                !receipt.work_retired) or
            ((receipt.phase_at_logical_retirement ==
                .response_ready or
                receipt.phase_at_logical_retirement ==
                    .response_writing or
                receipt.phase_at_logical_retirement ==
                    .response_written) and
                !receipt.response_retired)))
    {
        return LifecycleError.DrainSettlementMismatch;
    }
}

pub const ManagedConcurrentSnapshotV1 = struct {
    managed: ManagedSnapshotV1,
    worker_count: u8,
    pending_connection_capacity: u8,
    running_connections: u8,
    queue_high_watermark: u8,
    running_high_watermark: u8,
    queue_enqueued_connections: u64,
    queue_dispatched_connections: u64,
    listener_backpressure_activations: u64,
    listener_backpressure_resumptions: u64,
    drain_cancelled_queued_connections: u64,
    failure_cancelled_queued_connections: u64,
    receive_timeout_queued_connections: u64,
    full_request_timeout_queued_connections: u64,
    event_ordinal: u64,
    accept_paused: bool,
    cleanup_failed: bool,
    phase_counts: ManagedConnectionPhaseCountsV1,
};

fn transportOwnerTokenV1(
    lease: ManagedConnectionLeaseV1,
) prepared_http.TransportOwnerTokenV1 {
    return .{
        .process_generation = lease.process_generation,
        .connection_sequence = lease.connection_sequence,
        .slot_index = lease.slot_index,
        .slot_generation = lease.slot_generation,
    };
}

const ActiveConnectionV1 = struct {
    process_generation: u64,
    sequence: u64,
    handle: std.net.Stream.Handle,
    phase: ManagedConnectionPhaseV1 = .receiving_head,
    hard_stop_cause: ?HardStopCauseV1 = null,
    drain_signaled: bool = false,
    receive_timeout_signaled: bool = false,
    receive_retired: bool = false,
    receive_timeout_ns: u64 = 0,
    accept_timer: ?std.time.Timer = null,
    full_request_timeout_ns: u64 = 0,
    full_request_timeout_retired: bool = true,
    full_request_timeout_signaled: bool = false,
    work_identity: ?prepared_http.WorkIdentityV1 = null,
    work_retired: bool = false,
    finish_published_selected: bool = false,
    preexisting_work_stop_selected: bool = false,
    work_stop_outcome: prepared_http.DrainCancellationOutcomeV1 = .none,
    work_stop_winner: ?prepared_http.WorkCancellationCauseV1 = null,
    drain_work_cancelled: bool = false,
    failure_signaled: bool = false,
    failure_work_cancelled: bool = false,
    full_request_timeout_work_cancelled: bool = false,
    peer_reset_observed: bool = false,
    peer_reset_work_cancelled: bool = false,
    peer_send_close_observed: bool = false,
    peer_send_close_observed_phase: ManagedConnectionPhaseV1 = .none,
    peer_send_close_work_cancelled: bool = false,
    response_retired: bool = false,
    response_cancel_before_write_cause: ?ResponseStopCauseV1 = null,
    response_write_stop_state: ResponseWriteStopStateV1 = .none,
    response_write_failure: ?cancellable_writer.FailureKindV1 = null,
    response_write_progress_bytes: u64 = 0,
};

const ManagedDrainLogicalSettlementV1 = struct {
    phase: ManagedConnectionPhaseV1,
    ordinal: u8,
    terminal_status: ManagedDrainConnectionTerminalStatusV1,
    terminal_cause: ManagedDrainConnectionTerminalCauseV1,
    completed_counter_ordinal: u64,
    failed_counter_ordinal: u64,
    work_identity: ?prepared_http.WorkIdentityV1,
    work_cancellation: prepared_http.DrainCancellationOutcomeV1,
    work_cancellation_winner: ?prepared_http.WorkCancellationCauseV1,
    receive_retired: bool,
    full_request_timeout_retired: bool,
    work_retired: bool,
    response_retired: bool,
    response_write_progress_bytes: u64,
    local_write_completed: bool,
    evidence_complete: bool,
};

const ManagedDrainTrackedConnectionV1 = struct {
    selection: ManagedDrainConnectionSelectionV1,
    logical: ?ManagedDrainLogicalSettlementV1 = null,
    transport_close_confirmed: bool = false,
    transport_close_evidence: ?ManagedDrainTransportCloseEvidenceV1 = null,
    settlement: ?ManagedDrainConnectionSettlementReceiptV1 = null,
};

fn managedDrainTerminalCauseForResponseStopV1(
    cause: ResponseStopCauseV1,
) ManagedDrainConnectionTerminalCauseV1 {
    return switch (cause) {
        .drain => .drain,
        .full_request_timeout => .full_request_timeout,
        .failure => .lifecycle_failure,
        .peer_send_close => .peer_send_close,
    };
}

const ManagedConnectionSlotV1 = struct {
    generation: u64 = 0,
    active: ?ActiveConnectionV1 = null,
    drain_member: ?ManagedDrainTrackedConnectionV1 = null,
};

/// Process-lifetime listener state only. Request execution and retained
/// idempotency remain exclusively owned by `prepared_text_unary_service`.
pub const ManagedLifecycleV1 = struct {
    mutex: std.Thread.Mutex = .{},
    process_generation: u64,
    connection_capacity: u8 = 1,
    state: ManagedStateV1 = .starting,
    effective_drain_policy: ?ManagedDrainPolicyV1 = null,
    accepted_connections: u64 = 0,
    completed_connections: u64 = 0,
    failed_connections: u64 = 0,
    active_connections: u8 = 0,
    drain_signaled_connections: u64 = 0,
    receive_timeout_signaled_connections: u64 = 0,
    full_request_timeout_signaled_connections: u64 = 0,
    full_request_timeout_cancelled_work_connections: u64 = 0,
    full_request_timeout_cancelled_response_connections: u64 = 0,
    full_request_timeout_requested_response_write_connections: u64 = 0,
    full_request_timeout_cancelled_response_write_connections: u64 = 0,
    drain_cancelled_work_connections: u64 = 0,
    failure_signaled_connections: u64 = 0,
    failure_cancelled_work_connections: u64 = 0,
    failure_cancelled_response_connections: u64 = 0,
    failure_requested_response_write_connections: u64 = 0,
    failure_cancelled_response_write_connections: u64 = 0,
    peer_reset_connections: u64 = 0,
    peer_reset_cancelled_work_connections: u64 = 0,
    peer_send_closed_connections: u64 = 0,
    peer_send_close_cancelled_work_connections: u64 = 0,
    peer_send_close_cancelled_response_connections: u64 = 0,
    peer_send_close_requested_response_write_connections: u64 = 0,
    peer_send_close_cancelled_response_write_connections: u64 = 0,
    peer_send_close_zero_request_bytes_connections: u64 = 0,
    peer_send_close_partial_request_head_connections: u64 = 0,
    peer_send_close_partial_request_body_connections: u64 = 0,
    drain_cancelled_response_connections: u64 = 0,
    drain_requested_response_write_connections: u64 = 0,
    drain_cancelled_response_write_connections: u64 = 0,
    response_write_transport_failed_connections: u64 = 0,
    drain_settlement_session: ?ManagedDrainSettlementSessionV1 = null,
    drain_opening_receipt: ?ManagedDrainInitiationReceiptV1 = null,
    drain_policy_revision: u16 = 0,
    drain_logical_retirement_count: u8 = 0,
    drain_settlement_count: u8 = 0,
    last_drain_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_receive_timeout_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_full_request_timeout_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_failure_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_closed_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_send_close_receive_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_response_write_transport_failed_phase: ManagedConnectionPhaseV1 = .none,
    connection_slots: [maximum_managed_connection_slots_v1]ManagedConnectionSlotV1 =
        [_]ManagedConnectionSlotV1{.{}} **
        maximum_managed_connection_slots_v1,

    pub fn initV1(
        process_generation: u64,
    ) LifecycleError!ManagedLifecycleV1 {
        return initWithConnectionCapacityV1(process_generation, 1);
    }

    pub fn initWithConnectionCapacityV1(
        process_generation: u64,
        connection_capacity: u8,
    ) LifecycleError!ManagedLifecycleV1 {
        if (process_generation == 0)
            return LifecycleError.InvalidGeneration;
        if (connection_capacity == 0 or
            connection_capacity > maximum_managed_connection_slots_v1)
        {
            return LifecycleError.InvalidConnectionCapacity;
        }
        return .{
            .process_generation = process_generation,
            .connection_capacity = connection_capacity,
        };
    }

    pub fn markReadyV1(
        self: *ManagedLifecycleV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .starting)
            return LifecycleError.InvalidTransition;
        self.state = .ready;
    }

    fn beginConnectionV1(
        self: *ManagedLifecycleV1,
        handle: std.net.Stream.Handle,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        return self.beginConnectionWithFullRequestTimeoutV1(
            handle,
            0,
            0,
            null,
        );
    }

    fn beginConnectionWithFullRequestTimeoutV1(
        self: *ManagedLifecycleV1,
        handle: std.net.Stream.Handle,
        receive_timeout_ns: u64,
        full_request_timeout_ns: u64,
        accept_timer: ?std.time.Timer,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        return self.beginConnectionInPhaseV1(
            handle,
            receive_timeout_ns,
            full_request_timeout_ns,
            accept_timer,
            .receiving_head,
        );
    }

    fn beginQueuedConnectionV1(
        self: *ManagedLifecycleV1,
        handle: std.net.Stream.Handle,
        receive_timeout_ns: u64,
        full_request_timeout_ns: u64,
        accept_timer: ?std.time.Timer,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        return self.beginConnectionInPhaseV1(
            handle,
            receive_timeout_ns,
            full_request_timeout_ns,
            accept_timer,
            .queued,
        );
    }

    fn beginConnectionInPhaseV1(
        self: *ManagedLifecycleV1,
        handle: std.net.Stream.Handle,
        receive_timeout_ns: u64,
        full_request_timeout_ns: u64,
        accept_timer: ?std.time.Timer,
        initial_phase: ManagedConnectionPhaseV1,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.beginConnectionInPhaseLockedV1(
            handle,
            receive_timeout_ns,
            full_request_timeout_ns,
            accept_timer,
            initial_phase,
        );
    }

    fn beginConnectionInPhaseLockedV1(
        self: *ManagedLifecycleV1,
        handle: std.net.Stream.Handle,
        receive_timeout_ns: u64,
        full_request_timeout_ns: u64,
        accept_timer: ?std.time.Timer,
        initial_phase: ManagedConnectionPhaseV1,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        if (self.state != .ready)
            return LifecycleError.InvalidTransition;
        if (initial_phase != .queued and
            initial_phase != .receiving_head)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        if (self.active_connections >= self.connection_capacity)
            return LifecycleError.ConnectionAlreadyActive;
        const slot_index = self.findFreeConnectionSlotLockedV1() orelse
            return LifecycleError.ConnectionAlreadyActive;
        const slot = &self.connection_slots[slot_index];
        if (slot.drain_member != null)
            return LifecycleError.DrainSettlementMismatch;
        const sequence = std.math.add(
            u64,
            self.accepted_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        const slot_generation = std.math.add(
            u64,
            slot.generation,
            1,
        ) catch return LifecycleError.CounterOverflow;
        const next_active_connections = std.math.add(
            u8,
            self.active_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.accepted_connections = sequence;
        self.active_connections = next_active_connections;
        slot.generation = slot_generation;
        slot.active = .{
            .process_generation = self.process_generation,
            .sequence = sequence,
            .handle = handle,
            .phase = initial_phase,
            .receive_timeout_ns = receive_timeout_ns,
            .accept_timer = accept_timer,
            .full_request_timeout_ns = full_request_timeout_ns,
            .full_request_timeout_retired = full_request_timeout_ns == 0,
        };
        return .{
            .process_generation = self.process_generation,
            .connection_sequence = sequence,
            .slot_index = @intCast(slot_index),
            .slot_generation = slot_generation,
            .handle = handle,
        };
    }

    fn findFreeConnectionSlotLockedV1(
        self: *ManagedLifecycleV1,
    ) ?usize {
        for (
            self.connection_slots[0..self.connection_capacity],
            0..,
        ) |slot, index| {
            if (slot.active == null) return index;
        }
        return null;
    }

    fn activeConnectionForLeaseLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!*ActiveConnectionV1 {
        if (lease.process_generation != self.process_generation)
            return LifecycleError.InvalidGeneration;
        if (lease.slot_index >= self.connection_capacity)
            return LifecycleError.ConnectionSlotMismatch;
        const slot = &self.connection_slots[lease.slot_index];
        if (slot.generation != lease.slot_generation)
            return LifecycleError.ConnectionSlotGenerationMismatch;
        const active = if (slot.active) |*connection|
            connection
        else
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != lease.process_generation or
            active.sequence != lease.connection_sequence)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != lease.handle)
            return LifecycleError.ConnectionHandleMismatch;
        return active;
    }

    fn leaseForSlotLockedV1(
        self: *ManagedLifecycleV1,
        slot_index: usize,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        if (slot_index >= self.connection_capacity)
            return LifecycleError.ConnectionSlotMismatch;
        const slot = &self.connection_slots[slot_index];
        const active = slot.active orelse
            return LifecycleError.NoActiveConnection;
        return .{
            .process_generation = active.process_generation,
            .connection_sequence = active.sequence,
            .slot_index = @intCast(slot_index),
            .slot_generation = slot.generation,
            .handle = active.handle,
        };
    }

    fn leaseForTransportOwnerLockedV1(
        self: *ManagedLifecycleV1,
        owner: prepared_http.TransportOwnerTokenV1,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        if (owner.process_generation != self.process_generation)
            return LifecycleError.InvalidGeneration;
        if (owner.slot_index >= self.connection_capacity)
            return LifecycleError.ConnectionSlotMismatch;
        const slot = &self.connection_slots[owner.slot_index];
        if (slot.generation != owner.slot_generation)
            return LifecycleError.ConnectionSlotGenerationMismatch;
        const active = if (slot.active) |*connection|
            connection
        else
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != owner.process_generation or
            active.sequence != owner.connection_sequence)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        // The opaque owner deliberately excludes the native handle. Recover
        // it only from the still-live, generation-fenced slot, then run the
        // complete lease lookup before any work binding or counter mutation.
        const lease: ManagedConnectionLeaseV1 = .{
            .process_generation = owner.process_generation,
            .connection_sequence = owner.connection_sequence,
            .slot_index = owner.slot_index,
            .slot_generation = owner.slot_generation,
            .handle = active.handle,
        };
        _ = try self.activeConnectionForLeaseLockedV1(lease);
        return lease;
    }

    fn leaseForDrainReceiptLockedV1(
        self: *ManagedLifecycleV1,
        owner: ?prepared_http.TransportOwnerTokenV1,
    ) LifecycleError!ManagedConnectionLeaseV1 {
        if (owner) |token|
            return self.leaseForTransportOwnerLockedV1(token);
        if (self.connection_capacity != 1)
            return LifecycleError.MissingTransportOwner;
        return self.leaseForSlotLockedV1(0);
    }

    fn markRequestHeadReceivedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!void {
        return self.markRequestHeadReceivedBeforeDeadlineV1(
            lease,
            null,
            0,
        );
    }

    fn markRequestHeadReceivedBeforeDeadlineV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.transitionActiveConnectionReceiveLockedV1(
            lease,
            .receiving_head,
            .request_head_received,
            false,
            timer,
            timeout_ns,
        );
    }

    fn markRequestReceivedBeforeDeadlineV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.transitionActiveConnectionReceiveLockedV1(
            lease,
            .request_head_received,
            .request_received,
            true,
            timer,
            timeout_ns,
        );
    }

    fn markRequestAdmittedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) !prepared_http.WorkDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (!active.receive_retired or
            active.receive_timeout_signaled or
            active.drain_signaled or
            active.failure_signaled)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        const bound_active = try self.bindActiveWorkLockedV1(
            lease,
            work_identity,
        );
        if (active.hard_stop_cause == .full_request_timeout) {
            return .full_request_timeout;
        }
        return switch (self.state) {
            .ready => .proceed,
            .draining => if (self.effective_drain_policy ==
                .finish_published and
                bound_active.finish_published_selected)
                .proceed
            else
                .draining,
            else => LifecycleError.InvalidTransition,
        };
    }

    fn bindActiveWorkLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!*ActiveConnectionV1 {
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        switch (active.phase) {
            .request_received => {
                if (active.work_identity != null)
                    return LifecycleError.WorkIdentityMismatch;
                active.phase = .request_admitted;
                active.work_identity = work_identity;
            },
            .request_admitted,
            .response_ready,
            .response_writing,
            .response_written,
            => {
                const existing = active.work_identity orelse
                    return LifecycleError.WorkIdentityMismatch;
                if (!std.meta.eql(existing, work_identity))
                    return LifecycleError.WorkIdentityMismatch;
            },
            else => return LifecycleError.ConnectionPhaseMismatch,
        }
        return active;
    }

    fn retireActiveConnectionWorkV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .ready and self.state != .draining)
            return LifecycleError.InvalidTransition;
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        switch (active.phase) {
            .request_admitted,
            .response_ready,
            .response_writing,
            .response_written,
            => {},
            else => return LifecycleError.ConnectionPhaseMismatch,
        }
        const existing = active.work_identity orelse
            return LifecycleError.WorkIdentityMismatch;
        if (!std.meta.eql(existing, work_identity))
            return LifecycleError.WorkIdentityMismatch;
        active.work_retired = true;
    }

    fn recordDrainWorkCancellationLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!void {
        const active = try self.bindActiveWorkLockedV1(
            lease,
            work_identity,
        );
        if (active.drain_work_cancelled) return;
        const next_cancelled = std.math.add(
            u64,
            self.drain_cancelled_work_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.drain_cancelled_work_connections = next_cancelled;
        self.last_drain_cancelled_work_phase = active.phase;
        active.drain_work_cancelled = true;
    }

    fn recordFailureWorkCancellationLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!void {
        const active = try self.bindActiveWorkLockedV1(
            lease,
            work_identity,
        );
        if (active.failure_work_cancelled) return;
        const next_cancelled = std.math.add(
            u64,
            self.failure_cancelled_work_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.failure_cancelled_work_connections = next_cancelled;
        self.last_failure_cancelled_work_phase = active.phase;
        active.failure_work_cancelled = true;
    }

    fn recordPeerResetCancellationV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
        receipt: prepared_http.WorkCancellationReceiptV1,
    ) LifecycleError!void {
        return self.recordWorkCancellationV1(
            lease,
            work_identity,
            receipt,
        );
    }

    fn recordWorkCancellationV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
        receipt: prepared_http.WorkCancellationReceiptV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (receipt.requested_cause != .peer_reset and
            receipt.requested_cause != .peer_send_close and
            receipt.requested_cause != .full_request_timeout and
            receipt.requested_cause != .transport_failure)
        {
            return;
        }
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.phase != .request_admitted)
            return LifecycleError.ConnectionPhaseMismatch;
        const existing = active.work_identity orelse
            return LifecycleError.WorkIdentityMismatch;
        if (!std.meta.eql(existing, work_identity))
            return LifecycleError.WorkIdentityMismatch;
        try retainWorkStopReceiptOnActiveV1(
            active,
            receipt.outcome,
            receipt.winner,
        );

        switch (receipt.requested_cause) {
            .peer_reset => {
                if (receipt.cancellation_was_new and
                    receipt.winner == .peer_reset and
                    !active.peer_reset_work_cancelled)
                {
                    self.peer_reset_cancelled_work_connections =
                        std.math.add(
                            u64,
                            self.peer_reset_cancelled_work_connections,
                            1,
                        ) catch return LifecycleError.CounterOverflow;
                    self.last_peer_reset_cancelled_work_phase =
                        active.phase;
                    active.peer_reset_work_cancelled = true;
                }
            },
            .peer_send_close => {
                if (receipt.cancellation_was_new and
                    receipt.winner == .peer_send_close and
                    !active.peer_send_close_work_cancelled)
                {
                    self.peer_send_close_cancelled_work_connections =
                        std.math.add(
                            u64,
                            self.peer_send_close_cancelled_work_connections,
                            1,
                        ) catch return LifecycleError.CounterOverflow;
                    self.last_peer_send_close_cancelled_work_phase =
                        active.phase;
                    active.peer_send_close_work_cancelled = true;
                }
            },
            .full_request_timeout => {
                if (receipt.cancellation_was_new and
                    receipt.winner == .full_request_timeout and
                    !active.full_request_timeout_work_cancelled)
                {
                    self.full_request_timeout_cancelled_work_connections =
                        std.math.add(
                            u64,
                            self.full_request_timeout_cancelled_work_connections,
                            1,
                        ) catch return LifecycleError.CounterOverflow;
                    self.last_full_request_timeout_cancelled_work_phase =
                        active.phase;
                    active.full_request_timeout_work_cancelled = true;
                }
            },
            .transport_failure => {
                if (receipt.cancellation_was_new and
                    receipt.winner == .transport_failure and
                    !active.failure_work_cancelled)
                {
                    self.failure_cancelled_work_connections =
                        std.math.add(
                            u64,
                            self.failure_cancelled_work_connections,
                            1,
                        ) catch return LifecycleError.CounterOverflow;
                    self.last_failure_cancelled_work_phase =
                        active.phase;
                    active.failure_work_cancelled = true;
                }
            },
            else => unreachable,
        }
    }

    fn validateWorkCheckpointV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!prepared_http.WorkCheckpointDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.phase != .request_admitted)
            return LifecycleError.ConnectionPhaseMismatch;
        const existing = active.work_identity orelse
            return LifecycleError.WorkIdentityMismatch;
        if (!std.meta.eql(existing, work_identity))
            return LifecycleError.WorkIdentityMismatch;
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        const cause = active.hard_stop_cause orelse return .proceed;
        return switch (cause) {
            .full_request_timeout => .full_request_timeout,
            .peer_reset => .peer_reset,
            .peer_send_close => .peer_send_close,
            .receive_timeout, .response_transport_failure => .proceed,
        };
    }

    fn claimPeerResetV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!prepared_http.WorkCheckpointDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.phase != .request_admitted)
            return LifecycleError.ConnectionPhaseMismatch;
        const existing = active.work_identity orelse
            return LifecycleError.WorkIdentityMismatch;
        if (!std.meta.eql(existing, work_identity))
            return LifecycleError.WorkIdentityMismatch;
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.hard_stop_cause) |cause| {
            return switch (cause) {
                .full_request_timeout => .full_request_timeout,
                .peer_reset => .peer_reset,
                .peer_send_close => .peer_send_close,
                .receive_timeout,
                .response_transport_failure,
                => .proceed,
            };
        }
        self.peer_reset_connections = std.math.add(
            u64,
            self.peer_reset_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.last_peer_reset_phase = .request_admitted;
        active.hard_stop_cause = .peer_reset;
        active.peer_reset_observed = true;
        return .peer_reset;
    }

    fn observePeerSendCloseV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        work_identity: prepared_http.WorkIdentityV1,
        cancel_admitted_work: bool,
    ) LifecycleError!prepared_http.WorkCheckpointDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.phase != .request_admitted)
            return LifecycleError.ConnectionPhaseMismatch;
        const existing = active.work_identity orelse
            return LifecycleError.WorkIdentityMismatch;
        if (!std.meta.eql(existing, work_identity))
            return LifecycleError.WorkIdentityMismatch;
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.hard_stop_cause) |cause| {
            return switch (cause) {
                .full_request_timeout => .full_request_timeout,
                .peer_reset => .peer_reset,
                .peer_send_close => .peer_send_close,
                .receive_timeout,
                .response_transport_failure,
                => .proceed,
            };
        }
        if (active.peer_send_close_observed_phase ==
            .receiving_head or
            active.peer_send_close_observed_phase ==
                .request_head_received)
        {
            return .proceed;
        }
        try self.recordPeerSendCloseLockedV1(active);
        if (!cancel_admitted_work) return .proceed;
        active.hard_stop_cause = .peer_send_close;
        return .peer_send_close;
    }

    fn recordPeerSendCloseLockedV1(
        self: *ManagedLifecycleV1,
        active: *ActiveConnectionV1,
    ) LifecycleError!void {
        if (active.peer_send_close_observed) return;
        self.peer_send_closed_connections = std.math.add(
            u64,
            self.peer_send_closed_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.last_peer_send_closed_phase = active.phase;
        active.peer_send_close_observed = true;
        active.peer_send_close_observed_phase = active.phase;
    }

    fn observePeerSendCloseDuringReceiveV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        received_bytes: u64,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) LifecycleError!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.peer_send_close_observed_phase ==
            .receiving_head or
            active.peer_send_close_observed_phase ==
                .request_head_received)
        {
            return true;
        }
        if (active.peer_send_close_observed)
            return LifecycleError.ConnectionInterrupted;
        if (active.phase != .receiving_head and
            active.phase != .request_head_received)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        if (active.receive_retired or active.response_retired)
            return false;
        if (self.state != .ready or
            active.drain_signaled or
            active.receive_timeout_signaled or
            active.failure_signaled or
            active.hard_stop_cause != null)
        {
            return false;
        }
        if (receiveDeadlineExpiredV1(timer, timeout_ns)) {
            _ = try self
                .signalActiveConnectionForReceiveTimeoutLockedV1(
                lease,
            );
            return false;
        }
        if (try self.claimFullRequestTimeoutIfExpiredLockedV1(lease))
            return false;

        const next_closed = std.math.add(
            u64,
            self.peer_send_closed_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        var next_zero_request_bytes =
            self.peer_send_close_zero_request_bytes_connections;
        var next_partial_head =
            self.peer_send_close_partial_request_head_connections;
        var next_partial_body =
            self.peer_send_close_partial_request_body_connections;
        switch (active.phase) {
            .receiving_head => {
                if (received_bytes == 0) {
                    next_zero_request_bytes = std.math.add(
                        u64,
                        next_zero_request_bytes,
                        1,
                    ) catch return LifecycleError.CounterOverflow;
                } else {
                    next_partial_head = std.math.add(
                        u64,
                        next_partial_head,
                        1,
                    ) catch return LifecycleError.CounterOverflow;
                }
            },
            .request_head_received => {
                if (received_bytes == 0)
                    return LifecycleError.ConnectionInterrupted;
                next_partial_body = std.math.add(
                    u64,
                    next_partial_body,
                    1,
                ) catch return LifecycleError.CounterOverflow;
            },
            else => unreachable,
        }

        self.peer_send_closed_connections = next_closed;
        self.peer_send_close_zero_request_bytes_connections =
            next_zero_request_bytes;
        self.peer_send_close_partial_request_head_connections =
            next_partial_head;
        self.peer_send_close_partial_request_body_connections =
            next_partial_body;
        self.last_peer_send_closed_phase = active.phase;
        self.last_peer_send_close_receive_phase = active.phase;
        active.peer_send_close_observed = true;
        active.peer_send_close_observed_phase = active.phase;
        active.receive_retired = true;
        return true;
    }

    fn observePeerSendCloseAtResponseReadyV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        cancel_response: bool,
    ) LifecycleError!prepared_http.ResponseWriteDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_ready or
            active.response_retired)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        if (active.response_cancel_before_write_cause != null)
            return .cancelled;
        if (active.peer_send_close_observed_phase ==
            .receiving_head or
            active.peer_send_close_observed_phase ==
                .request_head_received)
        {
            return .proceed;
        }
        try self.recordPeerSendCloseLockedV1(active);
        if (!cancel_response) return .proceed;
        self.peer_send_close_cancelled_response_connections =
            std.math.add(
                u64,
                self.peer_send_close_cancelled_response_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        self.last_peer_send_close_cancelled_response_phase =
            .response_ready;
        active.hard_stop_cause = .peer_send_close;
        active.response_cancel_before_write_cause =
            .peer_send_close;
        return .cancelled;
    }

    fn observePeerSendCloseAtResponseWritingV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        cancel_response: bool,
    ) LifecycleError!cancellable_writer.DispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_writing or
            active.response_retired)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        const existing =
            try self.observeResponseWriteStopLockedV1(active);
        if (existing == .cancelled) return .cancelled;
        if (active.peer_send_close_observed_phase ==
            .receiving_head or
            active.peer_send_close_observed_phase ==
                .request_head_received)
        {
            return .proceed;
        }
        try self.recordPeerSendCloseLockedV1(active);
        if (!cancel_response) return .proceed;
        if (active.response_write_failure != null or
            active.hard_stop_cause != null)
        {
            return .proceed;
        }
        self.peer_send_close_requested_response_write_connections =
            std.math.add(
                u64,
                self.peer_send_close_requested_response_write_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        self.last_peer_send_close_requested_response_write_phase =
            .response_writing;
        active.hard_stop_cause = .peer_send_close;
        active.response_write_stop_state = .{
            .requested = .peer_send_close,
        };
        return self.observeResponseWriteStopLockedV1(active);
    }

    fn markResponseReadyV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .ready and self.state != .draining)
            return LifecycleError.InvalidTransition;
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (!active.receive_retired or
            active.receive_timeout_signaled or
            active.drain_signaled or
            active.response_retired)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        switch (active.phase) {
            .receiving_head,
            .request_head_received,
            .request_received,
            .request_admitted,
            => active.phase = .response_ready,
            else => return LifecycleError.ConnectionPhaseMismatch,
        }
        if (active.failure_signaled)
            try self.cancelResponseBeforeWriteForFailureLockedV1(
                active,
            )
        else if (active.hard_stop_cause == .full_request_timeout)
            try self.cancelResponseBeforeWriteForFullRequestTimeoutLockedV1(
                active,
            );
    }

    fn markResponseWritingV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!prepared_http.ResponseWriteDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_ready)
            return LifecycleError.ConnectionPhaseMismatch;
        if (active.response_cancel_before_write_cause != null) {
            return .cancelled;
        }
        active.phase = .response_writing;
        return .proceed;
    }

    fn checkResponseWriteV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!prepared_http.ResponseWriteDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_ready)
            return LifecycleError.ConnectionPhaseMismatch;
        return if (active.response_cancel_before_write_cause != null)
            .cancelled
        else
            .proceed;
    }

    fn observeResponseWriteStopV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!cancellable_writer.DispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_writing or
            active.response_retired)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        return self.observeResponseWriteStopLockedV1(active);
    }

    fn observeResponseWriteStopLockedV1(
        self: *ManagedLifecycleV1,
        active: *ActiveConnectionV1,
    ) LifecycleError!cancellable_writer.DispositionV1 {
        return switch (active.response_write_stop_state) {
            .none => .proceed,
            .requested => |cause| blk: {
                switch (cause) {
                    .drain => {
                        self.drain_cancelled_response_write_connections =
                            std.math.add(
                                u64,
                                self.drain_cancelled_response_write_connections,
                                1,
                            ) catch return LifecycleError.CounterOverflow;
                        self.last_drain_cancelled_response_write_phase =
                            .response_writing;
                    },
                    .full_request_timeout => {
                        self.full_request_timeout_cancelled_response_write_connections =
                            std.math.add(
                                u64,
                                self.full_request_timeout_cancelled_response_write_connections,
                                1,
                            ) catch return LifecycleError.CounterOverflow;
                        self.last_full_request_timeout_cancelled_response_write_phase =
                            .response_writing;
                    },
                    .failure => {
                        self.failure_cancelled_response_write_connections =
                            std.math.add(
                                u64,
                                self.failure_cancelled_response_write_connections,
                                1,
                            ) catch return LifecycleError.CounterOverflow;
                        self.last_failure_cancelled_response_write_phase =
                            .response_writing;
                    },
                    .peer_send_close => {
                        self.peer_send_close_cancelled_response_write_connections =
                            std.math.add(
                                u64,
                                self.peer_send_close_cancelled_response_write_connections,
                                1,
                            ) catch return LifecycleError.CounterOverflow;
                        self.last_peer_send_close_cancelled_response_write_phase =
                            .response_writing;
                    },
                }
                active.response_write_stop_state = .{
                    .observed = cause,
                };
                break :blk .cancelled;
            },
            .observed => .cancelled,
        };
    }

    fn recordResponseWriteProgressV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        bytes_sent: usize,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_writing or
            active.response_retired or
            bytes_sent == 0)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        active.response_write_progress_bytes = std.math.add(
            u64,
            active.response_write_progress_bytes,
            @intCast(bytes_sent),
        ) catch return LifecycleError.CounterOverflow;
    }

    fn recordResponseWriteFailureV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        failure: cancellable_writer.FailureV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_writing or
            active.response_retired)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        const failure_kind = std.meta.activeTag(failure);
        if (active.response_write_failure) |existing| {
            if (existing != failure_kind)
                return LifecycleError.ConnectionInterrupted;
            return;
        }
        if (failure_kind == .cancelled and
            std.meta.activeTag(active.response_write_stop_state) !=
                .observed)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        active.response_write_failure = failure_kind;
        if ((failure_kind == .connection_closed or
            failure_kind == .transport) and
            active.hard_stop_cause == null)
        {
            active.hard_stop_cause = .response_transport_failure;
        }
    }

    /// Publishes physical local-writer completion and reports whether the
    /// full-request deadline had not already won the lifecycle outcome.
    fn markResponseWrittenV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        const full_request_timeout_won =
            active.full_request_timeout_signaled or
            try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        if (active.phase != .response_writing or
            active.response_retired)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        if (active.response_write_failure != null)
            return LifecycleError.ConnectionInterrupted;
        // The local writer has no response bytes left, so always retain that
        // physical phase. A deadline that already won remains authoritative
        // for lifecycle success, while the transport outcome stays completed.
        active.phase = .response_written;
        return !full_request_timeout_won;
    }

    fn retireResponseV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        outcome: prepared_http.ResponseWriteOutcomeV1,
        writer_failure: ?cancellable_writer.FailureKindV1,
    ) LifecycleError!prepared_http.ResponseWriteOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.response_retired)
            return LifecycleError.ConnectionInterrupted;
        if (active.response_write_failure != writer_failure)
            return LifecycleError.ConnectionInterrupted;
        _ = try self.claimFullRequestTimeoutIfExpiredLockedV1(lease);
        var effective_outcome = outcome;
        switch (outcome) {
            .write_completed => {
                if (active.phase != .response_writing and
                    active.phase != .response_written)
                {
                    return LifecycleError.ConnectionPhaseMismatch;
                }
                if (writer_failure != null)
                    return LifecycleError.ConnectionInterrupted;
                if (active.phase == .response_writing)
                    active.phase = .response_written;
            },
            .write_failed => {
                if (active.phase != .response_ready and
                    active.phase != .response_writing)
                {
                    return LifecycleError.ConnectionPhaseMismatch;
                }
                if (writer_failure == .cancelled) {
                    if (std.meta.activeTag(
                        active.response_write_stop_state,
                    ) != .observed) {
                        return LifecycleError.ConnectionInterrupted;
                    }
                    effective_outcome = .cancelled_during_write;
                } else if (writer_failure == .connection_closed or
                    writer_failure == .transport)
                {
                    const next_failed = std.math.add(
                        u64,
                        self.response_write_transport_failed_connections,
                        1,
                    ) catch return LifecycleError.CounterOverflow;
                    self.response_write_transport_failed_connections =
                        next_failed;
                    self.last_response_write_transport_failed_phase =
                        active.phase;
                }
            },
            .cancelled_before_write => {
                if (active.phase != .response_ready) {
                    return LifecycleError.ConnectionPhaseMismatch;
                }
            },
            .cancelled_during_write => {
                if (active.phase != .response_writing or
                    writer_failure != .cancelled or
                    std.meta.activeTag(
                        active.response_write_stop_state,
                    ) != .observed)
                {
                    return LifecycleError.ConnectionPhaseMismatch;
                }
            },
        }
        active.response_retired = true;
        active.full_request_timeout_retired = true;
        return effective_outcome;
    }

    fn transitionActiveConnectionReceiveLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        expected_phase: ManagedConnectionPhaseV1,
        next_phase: ManagedConnectionPhaseV1,
        retire_receive: bool,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !void {
        if (self.state != .ready)
            return LifecycleError.InvalidTransition;
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.phase != expected_phase)
            return LifecycleError.ConnectionPhaseMismatch;
        if (active.drain_signaled or
            active.receive_timeout_signaled or
            active.receive_retired)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        if (receiveDeadlineExpiredV1(timer, timeout_ns)) {
            _ = try self.signalActiveConnectionForReceiveTimeoutLockedV1(
                lease,
            );
            return LifecycleError.ConnectionInterrupted;
        }
        if (try self.claimFullRequestTimeoutIfExpiredLockedV1(lease))
            return LifecycleError.ConnectionInterrupted;
        active.phase = next_phase;
        if (retire_receive) active.receive_retired = true;
    }

    fn finishConnectionV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        succeeded: bool,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.finishConnectionLockedV1(lease, succeeded);
    }

    fn finishConnectionLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        succeeded: bool,
    ) LifecycleError!void {
        if (self.active_connections == 0)
            return LifecycleError.NoActiveConnection;
        const active =
            (try self.activeConnectionForLeaseLockedV1(lease)).*;
        if (active.work_identity != null and
            !active.work_retired)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        if ((active.phase == .response_ready or
            active.phase == .response_writing or
            active.phase == .response_written) and
            !active.response_retired)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        if (!active.full_request_timeout_retired)
            return LifecycleError.ConnectionInterrupted;
        const next_completed_connections =
            if (succeeded)
                std.math.add(
                    u64,
                    self.completed_connections,
                    1,
                ) catch return LifecycleError.CounterOverflow
            else
                self.completed_connections;
        const next_failed_connections =
            if (succeeded)
                self.failed_connections
            else
                std.math.add(
                    u64,
                    self.failed_connections,
                    1,
                ) catch return LifecycleError.CounterOverflow;
        const next_active_connections = std.math.sub(
            u8,
            self.active_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        try self.recordDrainLogicalSettlementLockedV1(
            lease,
            &active,
            succeeded,
            if (succeeded) next_completed_connections else 0,
            if (succeeded) 0 else next_failed_connections,
            active.receive_retired and
                active.full_request_timeout_retired and
                (active.work_identity == null or
                    active.work_retired) and
                ((active.phase != .response_ready and
                    active.phase != .response_writing and
                    active.phase != .response_written) or
                    active.response_retired),
            null,
        );
        self.completed_connections = next_completed_connections;
        self.failed_connections = next_failed_connections;
        self.active_connections = next_active_connections;
        self.connection_slots[lease.slot_index].active = null;
    }

    fn forceRetireConnectionForCleanupLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        terminal_cause: ManagedDrainConnectionTerminalCauseV1,
    ) LifecycleError!void {
        const active_ptr =
            try self.activeConnectionForLeaseLockedV1(lease);
        active_ptr.receive_retired = true;
        active_ptr.full_request_timeout_retired = true;
        active_ptr.work_retired = true;
        active_ptr.response_retired = true;
        const active = active_ptr.*;
        const next_failed = std.math.add(
            u64,
            self.failed_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        const next_active = std.math.sub(
            u8,
            self.active_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        try self.recordDrainLogicalSettlementLockedV1(
            lease,
            &active,
            false,
            0,
            next_failed,
            false,
            terminal_cause,
        );
        self.failed_connections = next_failed;
        self.active_connections = next_active;
        self.connection_slots[lease.slot_index].active = null;
    }

    fn markStoppedV1(
        self: *ManagedLifecycleV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .draining or
            self.active_connections != 0 or
            self.hasOccupiedConnectionSlotLockedV1())
        {
            return LifecycleError.InvalidTransition;
        }
        if (self.drain_settlement_session) |*session| {
            const settlement =
                try self.inspectDrainSettlementsLockedV1(session);
            if (settlement.active_connections != 0 or
                settlement.transport_closing_connections != 0 or
                settlement.settled_connections !=
                    settlement.cohort_connections)
            {
                return LifecycleError.DrainSettlementMismatch;
            }
        }
        self.state = .stopped;
    }

    fn markFailedV1(self: *ManagedLifecycleV1) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .stopped) self.state = .failed;
    }

    fn resolveDrainPolicyLockedV1(
        self: *ManagedLifecycleV1,
        requested_policy: ManagedDrainPolicyV1,
    ) ManagedDrainPolicyResolutionV1 {
        const current = self.effective_drain_policy orelse {
            self.effective_drain_policy = requested_policy;
            return .{ .effective_policy = requested_policy };
        };
        if (current == .finish_published and
            requested_policy == .cancel_active)
        {
            self.effective_drain_policy = .cancel_active;
            return .{
                .effective_policy = .cancel_active,
                .policy_was_escalated = true,
            };
        }
        return .{ .effective_policy = current };
    }

    fn phaseCountsLockedV1(
        self: *ManagedLifecycleV1,
    ) ManagedConnectionPhaseCountsV1 {
        var counts: ManagedConnectionPhaseCountsV1 = .{};
        for (self.connection_slots[0..self.connection_capacity]) |slot| {
            const active = slot.active orelse continue;
            switch (active.phase) {
                .queued => counts.queued += 1,
                .receiving_head => counts.receiving_head += 1,
                .request_head_received => counts.request_head_received += 1,
                .request_received => counts.request_received += 1,
                .request_admitted => counts.request_admitted += 1,
                .response_ready => counts.response_ready += 1,
                .response_writing => counts.response_writing += 1,
                .response_written => counts.response_written += 1,
                .none => unreachable,
            }
        }
        std.debug.assert(
            managedDrainPhaseTotalV1(counts) ==
                @as(u16, self.active_connections),
        );
        return counts;
    }

    fn connectionHadStopBeforeDrainLockedV1(
        self: *ManagedLifecycleV1,
        active: *const ActiveConnectionV1,
        work_receipt: prepared_http.DrainReceiptV1,
    ) bool {
        _ = self;
        const receipt_matches_work =
            work_receipt.active_work != null and
            active.work_identity != null and
            std.meta.eql(
                work_receipt.active_work.?,
                active.work_identity.?,
            );
        const current_work_cancellation =
            active.drain_work_cancelled and
            work_receipt.cancellation_was_new and
            work_receipt.cancellation_winner == .drain and
            receipt_matches_work;
        const receipt_has_preexisting_stop =
            receipt_matches_work and
            !current_work_cancellation and
            switch (work_receipt.cancellation) {
                .cancelled,
                .already_cancelled,
                .start_rolled_back,
                => true,
                .none,
                .already_terminal,
                .recovery_required,
                => false,
            };
        if (receipt_has_preexisting_stop) return true;
        if (active.preexisting_work_stop_selected or
            active.hard_stop_cause != null or
            active.drain_signaled or
            active.receive_timeout_signaled or
            active.full_request_timeout_signaled or
            active.failure_signaled or
            active.failure_work_cancelled or
            active.full_request_timeout_work_cancelled or
            active.peer_reset_work_cancelled or
            active.peer_send_close_work_cancelled or
            active.response_cancel_before_write_cause != null or
            std.meta.activeTag(active.response_write_stop_state) != .none or
            active.response_write_failure != null)
        {
            return true;
        }
        return active.drain_work_cancelled and
            !current_work_cancellation;
    }

    fn drainDecisionCountsLockedV1(
        self: *ManagedLifecycleV1,
        policy: ManagedDrainPolicyV1,
        work_receipt: prepared_http.DrainReceiptV1,
    ) ManagedDrainDecisionCountsV1 {
        var decisions: ManagedDrainDecisionCountsV1 = .{};
        for (self.connection_slots[0..self.connection_capacity]) |slot| {
            const active = slot.active orelse continue;
            switch (self.drainDecisionForConnectionLockedV1(
                &active,
                policy,
                work_receipt,
            )) {
                .abort_selected => decisions.abort_selected += 1,
                .finish_selected => decisions.finish_selected += 1,
                .reject_unpublished => decisions.reject_unpublished += 1,
                .preexisting_stop => decisions.preexisting_stop += 1,
                .resumable => decisions.resumable += 1,
            }
        }
        std.debug.assert(decisions.resumable == 0);
        std.debug.assert(
            managedDrainDecisionTotalV1(decisions) ==
                @as(u16, self.active_connections),
        );
        return decisions;
    }

    fn drainDecisionForConnectionLockedV1(
        self: *ManagedLifecycleV1,
        active: *const ActiveConnectionV1,
        policy: ManagedDrainPolicyV1,
        work_receipt: prepared_http.DrainReceiptV1,
    ) ManagedDrainConnectionDecisionV1 {
        if (active.phase == .response_written)
            return .finish_selected;
        if (self.connectionHadStopBeforeDrainLockedV1(
            active,
            work_receipt,
        )) {
            return .preexisting_stop;
        }
        return switch (active.phase) {
            .queued,
            .receiving_head,
            .request_head_received,
            => .abort_selected,
            .request_received => .reject_unpublished,
            .request_admitted => switch (policy) {
                .finish_published => .finish_selected,
                .cancel_active => blk: {
                    const exact_active_work =
                        work_receipt.active_work != null and
                        active.work_identity != null and
                        std.meta.eql(
                            work_receipt.active_work.?,
                            active.work_identity.?,
                        );
                    break :blk if (active.work_retired or
                        (exact_active_work and
                            work_receipt.cancellation ==
                                .already_terminal))
                        .finish_selected
                    else
                        .abort_selected;
                },
            },
            .response_ready, .response_writing => switch (policy) {
                .cancel_active => .abort_selected,
                .finish_published => .finish_selected,
            },
            .response_written, .none => unreachable,
        };
    }

    fn captureDrainSettlementCohortLockedV1(
        self: *ManagedLifecycleV1,
        policy: ManagedDrainPolicyV1,
        work_receipt: prepared_http.DrainReceiptV1,
        phase_counts: ManagedConnectionPhaseCountsV1,
        decisions: ManagedDrainDecisionCountsV1,
    ) LifecycleError!void {
        if (self.drain_settlement_session != null or
            self.drain_opening_receipt != null or
            self.drain_policy_revision != 0 or
            self.drain_logical_retirement_count != 0 or
            self.drain_settlement_count != 0)
        {
            return LifecycleError.DrainSettlementMismatch;
        }
        const cohort_total = managedDrainPhaseTotalV1(phase_counts);
        if (cohort_total != @as(u16, self.active_connections) or
            managedDrainDecisionTotalV1(decisions) != cohort_total or
            decisions.resumable != 0)
        {
            return LifecycleError.DrainSettlementMismatch;
        }
        for (
            self.connection_slots[0..self.connection_capacity],
        ) |slot| {
            if (slot.active != null and slot.drain_member != null)
                return LifecycleError.DrainSettlementMismatch;
        }

        var member_index: u8 = 0;
        for (
            self.connection_slots[0..self.connection_capacity],
            0..,
        ) |*slot, slot_index| {
            const active = if (slot.active) |*connection|
                connection
            else
                continue;
            const decision =
                self.drainDecisionForConnectionLockedV1(
                    active,
                    policy,
                    work_receipt,
                );
            slot.drain_member = .{
                .selection = .{
                    .member_index = member_index,
                    .owner = .{
                        .process_generation = active.process_generation,
                        .connection_sequence = active.sequence,
                        .slot_index = @intCast(slot_index),
                        .slot_generation = slot.generation,
                    },
                    .phase_at_first_linearization = active.phase,
                    .initial_decision = decision,
                    .initial_effective_policy = policy,
                    .latest_decision = decision,
                    .latest_effective_policy = policy,
                    .latest_policy_revision = 1,
                    .work_identity = active.work_identity,
                    .work_cancellation = active.work_stop_outcome,
                    .work_cancellation_winner = active.work_stop_winner,
                },
            };
            member_index += 1;
        }
        if (@as(u16, member_index) != cohort_total)
            return LifecycleError.DrainSettlementMismatch;
        self.drain_settlement_session = .{
            .process_generation = self.process_generation,
            .drain_epoch = 1,
            .initial_policy_revision = 1,
            .initial_effective_policy = policy,
            .accepted_connections = self.accepted_connections,
            .completed_connections = self.completed_connections,
            .failed_connections = self.failed_connections,
            .cohort_connections = member_index,
        };
        self.drain_policy_revision = 1;
    }

    fn reviseDrainSettlementCohortLockedV1(
        self: *ManagedLifecycleV1,
        policy: ManagedDrainPolicyV1,
        work_receipt: prepared_http.DrainReceiptV1,
    ) LifecycleError!void {
        if (policy != .cancel_active)
            return LifecycleError.DrainSettlementMismatch;
        _ = self.drain_settlement_session orelse
            return LifecycleError.DrainSettlementUnavailable;
        const next_revision = std.math.add(
            u16,
            self.drain_policy_revision,
            1,
        ) catch return LifecycleError.CounterOverflow;
        for (
            self.connection_slots[0..self.connection_capacity],
        ) |*slot| {
            const active = if (slot.active) |*connection|
                connection
            else
                continue;
            const member = if (slot.drain_member) |*tracked|
                tracked
            else
                return LifecycleError.DrainSettlementMismatch;
            if (member.logical != null)
                return LifecycleError.DrainSettlementMismatch;
            member.selection.latest_decision =
                self.drainDecisionForConnectionLockedV1(
                    active,
                    policy,
                    work_receipt,
                );
            member.selection.latest_effective_policy = policy;
            member.selection.latest_policy_revision =
                next_revision;
            member.selection.work_cancellation =
                active.work_stop_outcome;
            member.selection.work_cancellation_winner =
                active.work_stop_winner;
        }
        self.drain_policy_revision = next_revision;
    }

    fn terminalCauseForDrainConnectionLockedV1(
        self: *ManagedLifecycleV1,
        active: *const ActiveConnectionV1,
        succeeded: bool,
        decision: ManagedDrainConnectionDecisionV1,
    ) ManagedDrainConnectionTerminalCauseV1 {
        if (active.hard_stop_cause) |cause| {
            return switch (cause) {
                .receive_timeout => .receive_timeout,
                .full_request_timeout => .full_request_timeout,
                .peer_reset => .peer_reset,
                .peer_send_close => .peer_send_close,
                .response_transport_failure => .response_transport_failure,
            };
        }
        if (active.response_cancel_before_write_cause) |cause|
            return managedDrainTerminalCauseForResponseStopV1(cause);
        switch (active.response_write_stop_state) {
            .requested => |cause| return managedDrainTerminalCauseForResponseStopV1(
                cause,
            ),
            .observed => |cause| return managedDrainTerminalCauseForResponseStopV1(
                cause,
            ),
            .none => {},
        }
        if (active.work_stop_winner) |winner| {
            return switch (winner) {
                .drain => .drain,
                .peer_reset => .peer_reset,
                .full_request_timeout => .full_request_timeout,
                .transport_failure => .transport_failure,
                .preexisting => .preexisting_work_stop,
                .peer_send_close => .peer_send_close,
            };
        }
        if (active.drain_signaled or
            active.drain_work_cancelled)
        {
            return .drain;
        }
        if (active.failure_signaled or
            active.failure_work_cancelled)
        {
            return .lifecycle_failure;
        }
        if (active.full_request_timeout_work_cancelled)
            return .full_request_timeout;
        if (active.peer_reset_work_cancelled)
            return .peer_reset;
        if (active.peer_send_close_work_cancelled or
            active.peer_send_close_observed)
        {
            return .peer_send_close;
        }
        if (active.preexisting_work_stop_selected)
            return .preexisting_work_stop;
        if (decision == .reject_unpublished)
            return .reject_unpublished;
        if (decision == .abort_selected)
            return .drain;
        if (succeeded) return .normal_completion;
        if (self.state == .failed) return .lifecycle_failure;
        return .application_failure;
    }

    fn recordDrainLogicalSettlementLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        active: *const ActiveConnectionV1,
        succeeded: bool,
        completed_counter_ordinal: u64,
        failed_counter_ordinal: u64,
        evidence_complete: bool,
        terminal_cause_override: ?ManagedDrainConnectionTerminalCauseV1,
    ) LifecycleError!void {
        if (self.drain_settlement_session == null) return;
        if (lease.slot_index >= self.connection_capacity)
            return LifecycleError.ConnectionSlotMismatch;
        const slot = &self.connection_slots[lease.slot_index];
        if (slot.generation != lease.slot_generation)
            return LifecycleError.ConnectionSlotGenerationMismatch;
        const member = if (slot.drain_member) |*tracked|
            tracked
        else
            return LifecycleError.DrainSettlementMismatch;
        const owner = transportOwnerTokenV1(lease);
        if (!std.meta.eql(owner, member.selection.owner))
            return LifecycleError.DrainSettlementMismatch;
        if (member.logical != null)
            return LifecycleError.DrainSettlementMismatch;
        const next_ordinal = std.math.add(
            u8,
            self.drain_logical_retirement_count,
            1,
        ) catch return LifecycleError.CounterOverflow;
        member.logical = .{
            .phase = active.phase,
            .ordinal = next_ordinal,
            .terminal_status = if (succeeded) .completed else .failed,
            .terminal_cause = terminal_cause_override orelse
                self.terminalCauseForDrainConnectionLockedV1(
                    active,
                    succeeded,
                    member.selection.latest_decision,
                ),
            .completed_counter_ordinal = completed_counter_ordinal,
            .failed_counter_ordinal = failed_counter_ordinal,
            .work_identity = active.work_identity,
            .work_cancellation = active.work_stop_outcome,
            .work_cancellation_winner = active.work_stop_winner,
            .receive_retired = active.receive_retired,
            .full_request_timeout_retired = active.full_request_timeout_retired,
            .work_retired = active.work_retired,
            .response_retired = active.response_retired,
            .response_write_progress_bytes = active.response_write_progress_bytes,
            .local_write_completed = active.phase == .response_written and
                active.response_retired and
                active.response_write_failure == null,
            .evidence_complete = evidence_complete,
        };
        self.drain_logical_retirement_count = next_ordinal;
        if (member.transport_close_confirmed)
            try self.finalizeDrainSettlementMemberLockedV1(member);
    }

    fn finalizeDrainSettlementMemberLockedV1(
        self: *ManagedLifecycleV1,
        member: *ManagedDrainTrackedConnectionV1,
    ) LifecycleError!void {
        if (member.settlement != null) return;
        const session = self.drain_settlement_session orelse
            return LifecycleError.DrainSettlementUnavailable;
        const logical = member.logical orelse return;
        if (!member.transport_close_confirmed) return;
        const close_evidence =
            member.transport_close_evidence orelse
            return LifecycleError.DrainSettlementMismatch;
        const next_ordinal = std.math.add(
            u8,
            self.drain_settlement_count,
            1,
        ) catch return LifecycleError.CounterOverflow;
        member.settlement = .{
            .process_generation = self.process_generation,
            .drain_epoch = session.drain_epoch,
            .member_index = member.selection.member_index,
            .owner = member.selection.owner,
            .phase_at_first_linearization = member.selection.phase_at_first_linearization,
            .initial_decision = member.selection.initial_decision,
            .initial_effective_policy = member.selection.initial_effective_policy,
            .latest_decision = member.selection.latest_decision,
            .latest_effective_policy = member.selection.latest_effective_policy,
            .latest_policy_revision = member.selection.latest_policy_revision,
            .phase_at_logical_retirement = logical.phase,
            .logical_retirement_ordinal = logical.ordinal,
            .settlement_ordinal = next_ordinal,
            .terminal_status = logical.terminal_status,
            .terminal_cause = logical.terminal_cause,
            .completed_counter_ordinal = logical.completed_counter_ordinal,
            .failed_counter_ordinal = logical.failed_counter_ordinal,
            .work_identity = logical.work_identity,
            .work_cancellation = logical.work_cancellation,
            .work_cancellation_winner = logical.work_cancellation_winner,
            .receive_retired = logical.receive_retired,
            .full_request_timeout_retired = logical.full_request_timeout_retired,
            .work_retired = logical.work_retired,
            .response_retired = logical.response_retired,
            .response_write_progress_bytes = logical.response_write_progress_bytes,
            .local_write_completed = logical.local_write_completed,
            .transport_close_confirmed = true,
            .transport_close_evidence = close_evidence,
            .evidence_complete = logical.evidence_complete and
                close_evidence != .forced_after_join,
        };
        self.drain_settlement_count = next_ordinal;
    }

    fn confirmTransportClosedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        evidence: ManagedDrainTransportCloseEvidenceV1,
    ) LifecycleError!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.confirmTransportClosedLockedV1(
            lease,
            evidence,
        );
    }

    fn confirmTransportClosedLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        evidence: ManagedDrainTransportCloseEvidenceV1,
    ) LifecycleError!bool {
        if (self.drain_settlement_session == null) return false;
        if (lease.process_generation != self.process_generation)
            return LifecycleError.InvalidGeneration;
        if (lease.slot_index >= self.connection_capacity)
            return LifecycleError.ConnectionSlotMismatch;
        const slot = &self.connection_slots[lease.slot_index];
        const member = if (slot.drain_member) |*tracked|
            tracked
        else
            return false;
        if (!std.meta.eql(
            transportOwnerTokenV1(lease),
            member.selection.owner,
        )) {
            // A connection may retire before the drain linearizes, then close
            // after the cohort is captured or after its slot is reused. It is
            // not a settlement member and must not poison the retained cohort.
            return false;
        }
        if (member.transport_close_confirmed) return false;
        member.transport_close_confirmed = true;
        member.transport_close_evidence = evidence;
        if (member.logical != null)
            try self.finalizeDrainSettlementMemberLockedV1(member);
        return true;
    }

    fn inspectDrainSettlementsLockedV1(
        self: *ManagedLifecycleV1,
        session: *const ManagedDrainSettlementSessionV1,
    ) LifecycleError!ManagedDrainSettlementsInspectionV1 {
        try validateManagedDrainSettlementSessionShapeV1(session);
        const retained = self.drain_settlement_session orelse
            return LifecycleError.DrainSettlementUnavailable;
        if (!std.meta.eql(retained, session.*))
            return LifecycleError.DrainSettlementMismatch;
        if (self.completed_connections <
            session.completed_connections or
            self.failed_connections < session.failed_connections)
        {
            return LifecycleError.DrainSettlementMismatch;
        }
        var member_count: u8 = 0;
        var active_count: u8 = 0;
        var closing_count: u8 = 0;
        var settled_count: u8 = 0;
        var completed_count: u8 = 0;
        var failed_count: u8 = 0;
        var logical_ordinals =
            [_]bool{false} **
            (maximum_managed_connection_slots_v1 + 1);
        var settlement_ordinals =
            [_]bool{false} **
            (maximum_managed_connection_slots_v1 + 1);
        var completed_counter_ordinals =
            [_]bool{false} **
            (maximum_managed_connection_slots_v1 + 1);
        var failed_counter_ordinals =
            [_]bool{false} **
            (maximum_managed_connection_slots_v1 + 1);
        for (
            self.connection_slots[0..self.connection_capacity],
        ) |slot| {
            const member = slot.drain_member orelse continue;
            if (member.selection.member_index != member_count or
                member.selection.resumable or
                member.selection.initial_effective_policy !=
                    session.initial_effective_policy or
                member.selection.latest_policy_revision <
                    session.initial_policy_revision or
                member.selection.latest_policy_revision >
                    self.drain_policy_revision)
            {
                return LifecycleError.DrainSettlementMismatch;
            }
            member_count += 1;
            if (member.logical) |logical| {
                if (logical.ordinal == 0 or
                    logical.ordinal > session.cohort_connections or
                    logical_ordinals[logical.ordinal])
                {
                    return LifecycleError.DrainSettlementMismatch;
                }
                logical_ordinals[logical.ordinal] = true;
                switch (logical.terminal_status) {
                    .completed => {
                        if (logical.completed_counter_ordinal <=
                            session.completed_connections or
                            logical.completed_counter_ordinal >
                                self.completed_connections or
                            logical.failed_counter_ordinal != 0)
                        {
                            return LifecycleError.DrainSettlementMismatch;
                        }
                        const ordinal = logical.completed_counter_ordinal -
                            session.completed_connections;
                        if (ordinal >
                            maximum_managed_connection_slots_v1 or
                            completed_counter_ordinals[
                                @intCast(ordinal)
                            ])
                        {
                            return LifecycleError.DrainSettlementMismatch;
                        }
                        completed_counter_ordinals[
                            @intCast(ordinal)
                        ] = true;
                        completed_count += 1;
                    },
                    .failed => {
                        if (logical.failed_counter_ordinal <=
                            session.failed_connections or
                            logical.failed_counter_ordinal >
                                self.failed_connections or
                            logical.completed_counter_ordinal != 0)
                        {
                            return LifecycleError.DrainSettlementMismatch;
                        }
                        const ordinal = logical.failed_counter_ordinal -
                            session.failed_connections;
                        if (ordinal >
                            maximum_managed_connection_slots_v1 or
                            failed_counter_ordinals[
                                @intCast(ordinal)
                            ])
                        {
                            return LifecycleError.DrainSettlementMismatch;
                        }
                        failed_counter_ordinals[
                            @intCast(ordinal)
                        ] = true;
                        failed_count += 1;
                    },
                }
                if (member.settlement) |settlement| {
                    if (!member.transport_close_confirmed)
                        return LifecycleError.DrainSettlementMismatch;
                    const close_evidence =
                        member.transport_close_evidence orelse
                        return LifecycleError.DrainSettlementMismatch;
                    try validateManagedDrainConnectionSettlementReceiptShapeV1(
                        &settlement,
                        session,
                        self.drain_policy_revision,
                    );
                    if (settlement.settlement_ordinal >
                        session.cohort_connections or
                        settlement_ordinals[
                            settlement.settlement_ordinal
                        ] or
                        settlement.member_index !=
                            member.selection.member_index or
                        !std.meta.eql(
                            settlement.owner,
                            member.selection.owner,
                        ) or
                        settlement.phase_at_first_linearization !=
                            member.selection.phase_at_first_linearization or
                        settlement.initial_decision !=
                            member.selection.initial_decision or
                        settlement.initial_effective_policy !=
                            member.selection.initial_effective_policy or
                        settlement.latest_decision !=
                            member.selection.latest_decision or
                        settlement.latest_effective_policy !=
                            member.selection.latest_effective_policy or
                        settlement.latest_policy_revision !=
                            member.selection.latest_policy_revision or
                        settlement.phase_at_logical_retirement !=
                            logical.phase or
                        settlement.logical_retirement_ordinal !=
                            logical.ordinal or
                        settlement.terminal_status !=
                            logical.terminal_status or
                        settlement.terminal_cause !=
                            logical.terminal_cause or
                        settlement.completed_counter_ordinal !=
                            logical.completed_counter_ordinal or
                        settlement.failed_counter_ordinal !=
                            logical.failed_counter_ordinal or
                        !std.meta.eql(
                            settlement.work_identity,
                            logical.work_identity,
                        ) or
                        settlement.work_cancellation !=
                            logical.work_cancellation or
                        settlement.work_cancellation_winner !=
                            logical.work_cancellation_winner or
                        settlement.receive_retired !=
                            logical.receive_retired or
                        settlement.full_request_timeout_retired !=
                            logical.full_request_timeout_retired or
                        settlement.work_retired !=
                            logical.work_retired or
                        settlement.response_retired !=
                            logical.response_retired or
                        settlement.response_write_progress_bytes !=
                            logical.response_write_progress_bytes or
                        settlement.local_write_completed !=
                            logical.local_write_completed or
                        settlement.transport_close_evidence !=
                            close_evidence or
                        settlement.evidence_complete !=
                            (logical.evidence_complete and
                                settlement.transport_close_evidence !=
                                    .forced_after_join))
                    {
                        return LifecycleError.DrainSettlementMismatch;
                    }
                    settlement_ordinals[
                        settlement.settlement_ordinal
                    ] = true;
                    settled_count += 1;
                } else {
                    closing_count += 1;
                }
            } else {
                if (member.settlement != null)
                    return LifecycleError.DrainSettlementMismatch;
                active_count += 1;
            }
        }
        if (member_count != session.cohort_connections or
            active_count != self.active_connections or
            @as(u16, active_count) +
                @as(u16, closing_count) +
                @as(u16, settled_count) !=
                @as(u16, member_count) or
            @as(u16, completed_count) +
                @as(u16, failed_count) !=
                @as(u16, closing_count) +
                    @as(u16, settled_count) or
            self.completed_connections -
                session.completed_connections !=
                @as(u64, completed_count) or
            self.failed_connections -
                session.failed_connections !=
                @as(u64, failed_count) or
            self.drain_logical_retirement_count !=
                completed_count + failed_count or
            self.drain_settlement_count != settled_count)
        {
            return LifecycleError.DrainSettlementMismatch;
        }
        return .{
            .process_generation = self.process_generation,
            .drain_epoch = session.drain_epoch,
            .current_policy_revision = self.drain_policy_revision,
            .effective_policy = self.effective_drain_policy orelse
                session.initial_effective_policy,
            .state = self.state,
            .cohort_connections = member_count,
            .active_connections = active_count,
            .transport_closing_connections = closing_count,
            .settled_connections = settled_count,
            .logically_completed_connections = completed_count,
            .logically_failed_connections = failed_count,
            .resumable_connections = 0,
            .settled = active_count == 0 and
                closing_count == 0 and
                settled_count == member_count and
                (self.state == .stopped or
                    self.state == .failed),
        };
    }

    pub fn snapshotV1(
        self: *ManagedLifecycleV1,
    ) ManagedSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snapshotLockedV1();
    }

    fn snapshotLockedV1(
        self: *ManagedLifecycleV1,
    ) ManagedSnapshotV1 {
        var queued_connections: u8 = 0;
        var sole_phase: ManagedConnectionPhaseV1 = .none;
        for (self.connection_slots[0..self.connection_capacity]) |slot| {
            const active = slot.active orelse continue;
            if (active.phase == .queued)
                queued_connections += 1;
            if (self.active_connections == 1)
                sole_phase = active.phase;
        }
        return .{
            .process_generation = self.process_generation,
            .state = self.state,
            .connection_capacity = self.connection_capacity,
            .accepted_connections = self.accepted_connections,
            .completed_connections = self.completed_connections,
            .failed_connections = self.failed_connections,
            .active_connections = self.active_connections,
            .queued_connections = queued_connections,
            .drain_signaled_connections = self.drain_signaled_connections,
            .receive_timeout_signaled_connections = self.receive_timeout_signaled_connections,
            .full_request_timeout_signaled_connections = self.full_request_timeout_signaled_connections,
            .full_request_timeout_cancelled_work_connections = self.full_request_timeout_cancelled_work_connections,
            .full_request_timeout_cancelled_response_connections = self.full_request_timeout_cancelled_response_connections,
            .full_request_timeout_requested_response_write_connections = self.full_request_timeout_requested_response_write_connections,
            .full_request_timeout_cancelled_response_write_connections = self.full_request_timeout_cancelled_response_write_connections,
            .drain_cancelled_work_connections = self.drain_cancelled_work_connections,
            .failure_signaled_connections = self.failure_signaled_connections,
            .failure_cancelled_work_connections = self.failure_cancelled_work_connections,
            .failure_cancelled_response_connections = self.failure_cancelled_response_connections,
            .failure_requested_response_write_connections = self.failure_requested_response_write_connections,
            .failure_cancelled_response_write_connections = self.failure_cancelled_response_write_connections,
            .peer_reset_connections = self.peer_reset_connections,
            .peer_reset_cancelled_work_connections = self.peer_reset_cancelled_work_connections,
            .peer_send_closed_connections = self.peer_send_closed_connections,
            .peer_send_close_cancelled_work_connections = self.peer_send_close_cancelled_work_connections,
            .peer_send_close_cancelled_response_connections = self.peer_send_close_cancelled_response_connections,
            .peer_send_close_requested_response_write_connections = self.peer_send_close_requested_response_write_connections,
            .peer_send_close_cancelled_response_write_connections = self.peer_send_close_cancelled_response_write_connections,
            .drain_cancelled_response_connections = self.drain_cancelled_response_connections,
            .drain_requested_response_write_connections = self.drain_requested_response_write_connections,
            .drain_cancelled_response_write_connections = self.drain_cancelled_response_write_connections,
            .response_write_transport_failed_connections = self.response_write_transport_failed_connections,
            .active_connection_phase = sole_phase,
            .last_drain_signaled_phase = self.last_drain_signaled_phase,
            .last_receive_timeout_signaled_phase = self.last_receive_timeout_signaled_phase,
            .last_full_request_timeout_signaled_phase = self.last_full_request_timeout_signaled_phase,
            .last_full_request_timeout_cancelled_work_phase = self.last_full_request_timeout_cancelled_work_phase,
            .last_full_request_timeout_cancelled_response_phase = self.last_full_request_timeout_cancelled_response_phase,
            .last_full_request_timeout_requested_response_write_phase = self.last_full_request_timeout_requested_response_write_phase,
            .last_full_request_timeout_cancelled_response_write_phase = self.last_full_request_timeout_cancelled_response_write_phase,
            .last_drain_cancelled_work_phase = self.last_drain_cancelled_work_phase,
            .last_failure_signaled_phase = self.last_failure_signaled_phase,
            .last_failure_cancelled_work_phase = self.last_failure_cancelled_work_phase,
            .last_failure_cancelled_response_phase = self.last_failure_cancelled_response_phase,
            .last_failure_requested_response_write_phase = self.last_failure_requested_response_write_phase,
            .last_failure_cancelled_response_write_phase = self.last_failure_cancelled_response_write_phase,
            .last_peer_reset_phase = self.last_peer_reset_phase,
            .last_peer_reset_cancelled_work_phase = self.last_peer_reset_cancelled_work_phase,
            .last_peer_send_closed_phase = self.last_peer_send_closed_phase,
            .last_peer_send_close_cancelled_work_phase = self.last_peer_send_close_cancelled_work_phase,
            .last_peer_send_close_cancelled_response_phase = self.last_peer_send_close_cancelled_response_phase,
            .last_peer_send_close_requested_response_write_phase = self.last_peer_send_close_requested_response_write_phase,
            .last_peer_send_close_cancelled_response_write_phase = self.last_peer_send_close_cancelled_response_write_phase,
            .last_drain_cancelled_response_phase = self.last_drain_cancelled_response_phase,
            .last_drain_requested_response_write_phase = self.last_drain_requested_response_write_phase,
            .last_drain_cancelled_response_write_phase = self.last_drain_cancelled_response_write_phase,
            .last_response_write_transport_failed_phase = self.last_response_write_transport_failed_phase,
            .peer_send_close_zero_request_bytes_connections = self.peer_send_close_zero_request_bytes_connections,
            .peer_send_close_partial_request_head_connections = self.peer_send_close_partial_request_head_connections,
            .peer_send_close_partial_request_body_connections = self.peer_send_close_partial_request_body_connections,
            .last_peer_send_close_receive_phase = self.last_peer_send_close_receive_phase,
        };
    }

    fn hasOccupiedConnectionSlotLockedV1(
        self: *ManagedLifecycleV1,
    ) bool {
        for (self.connection_slots[0..self.connection_capacity]) |slot| {
            if (slot.active != null) return true;
        }
        return false;
    }

    fn signalActiveConnectionForDrainLockedV1(
        self: *ManagedLifecycleV1,
    ) !bool {
        return self.signalActiveConnectionForDrainWithPolicyLockedV1(
            .cancel_active,
        );
    }

    fn signalActiveConnectionForDrainWithPolicyLockedV1(
        self: *ManagedLifecycleV1,
        policy: ManagedDrainPolicyV1,
    ) !bool {
        var signaled_any = false;
        var first_error: ?anyerror = null;
        for (self.connection_slots[0..self.connection_capacity]) |*slot| {
            const active = if (slot.active) |*connection|
                connection
            else
                continue;
            if (active.process_generation != self.process_generation and
                first_error == null)
            {
                first_error = LifecycleError.InvalidGeneration;
            }
            signaled_any = true;
            self.signalConnectionForDrainLockedV1(
                active,
                policy,
            ) catch |err| {
                if (first_error == null) first_error = err;
            };
        }
        if (first_error) |err| return err;
        return signaled_any;
    }

    fn signalConnectionForDrainLockedV1(
        self: *ManagedLifecycleV1,
        active: *ActiveConnectionV1,
        policy: ManagedDrainPolicyV1,
    ) !void {
        if (policy == .finish_published) {
            switch (active.phase) {
                .request_received,
                .request_admitted,
                .response_ready,
                .response_writing,
                .response_written,
                => return,
                .queued,
                .receiving_head,
                .request_head_received,
                => {},
                .none => unreachable,
            }
        }
        if (active.phase == .response_ready) {
            if (active.response_cancel_before_write_cause != null)
                return;
            const next_cancelled = std.math.add(
                u64,
                self.drain_cancelled_response_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            self.drain_cancelled_response_connections = next_cancelled;
            self.last_drain_cancelled_response_phase = active.phase;
            active.response_cancel_before_write_cause = .drain;
            return;
        }
        if (active.phase == .response_writing) {
            if (active.response_write_failure != null or
                std.meta.activeTag(
                    active.response_write_stop_state,
                ) != .none)
            {
                return;
            }
            const next_requested = std.math.add(
                u64,
                self.drain_requested_response_write_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            self.drain_requested_response_write_connections =
                next_requested;
            self.last_drain_requested_response_write_phase =
                .response_writing;
            active.response_write_stop_state = .{
                .requested = .drain,
            };
            return;
        }
        if (active.drain_signaled or
            active.receive_timeout_signaled or
            active.receive_retired)
        {
            return;
        }
        const next_signaled = std.math.add(
            u64,
            self.drain_signaled_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        var signal_failed = false;
        std.posix.shutdown(
            active.handle,
            if (active.phase == .queued) .both else .recv,
        ) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            => {},
            else => signal_failed = true,
        };
        if (signal_failed)
            return LifecycleError.ConnectionSignalFailed;
        self.drain_signaled_connections = next_signaled;
        self.last_drain_signaled_phase = active.phase;
        active.drain_signaled = true;
        active.receive_retired = true;
    }

    fn signalConnectionForFailureLockedV1(
        self: *ManagedLifecycleV1,
        active: *ActiveConnectionV1,
    ) LifecycleError!FailureSignalResultV1 {
        if (active.phase == .queued or
            active.failure_signaled or
            active.drain_signaled or
            active.receive_timeout_signaled or
            active.full_request_timeout_signaled or
            active.hard_stop_cause != null or
            active.response_retired)
        {
            return .{};
        }
        if (active.phase == .response_ready) {
            if (active.response_cancel_before_write_cause != null)
                return .{};
            const next_cancelled = std.math.add(
                u64,
                self.failure_cancelled_response_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            self.failure_cancelled_response_connections =
                next_cancelled;
            self.last_failure_cancelled_response_phase =
                active.phase;
            active.failure_signaled = true;
            active.response_cancel_before_write_cause =
                .failure;
            return .{ .claimed = true };
        }
        if (active.phase == .response_writing) {
            if (active.response_write_failure != null or
                std.meta.activeTag(
                    active.response_write_stop_state,
                ) != .none)
            {
                return .{};
            }
            const next_requested = std.math.add(
                u64,
                self.failure_requested_response_write_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            self.failure_requested_response_write_connections =
                next_requested;
            self.last_failure_requested_response_write_phase =
                .response_writing;
            active.failure_signaled = true;
            active.response_write_stop_state = .{
                .requested = .failure,
            };
            return .{ .claimed = true };
        }
        const next_signaled = std.math.add(
            u64,
            self.failure_signaled_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        var signal_failed = false;
        std.posix.shutdown(
            active.handle,
            if (active.phase == .queued or
                active.phase == .response_written)
                .both
            else
                .recv,
        ) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            => {},
            else => signal_failed = true,
        };
        if (signal_failed)
            return .{ .signal_failed = true };
        self.failure_signaled_connections = next_signaled;
        self.last_failure_signaled_phase = active.phase;
        active.failure_signaled = true;
        active.receive_retired = true;
        return .{
            .claimed = true,
            .signal_failed = signal_failed,
        };
    }

    fn fullRequestDeadlineExpiredLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) bool {
        const active =
            self.activeConnectionForLeaseLockedV1(lease) catch
                return false;
        if (!fullRequestDeadlineEligibleForActiveV1(
            active,
            self.state,
        )) {
            return false;
        }
        if (active.accept_timer) |*timer| {
            return timer.read() >=
                active.full_request_timeout_ns;
        }
        return false;
    }

    fn claimFullRequestTimeoutIfExpiredLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) !bool {
        if (!self.fullRequestDeadlineExpiredLockedV1(lease))
            return false;
        return self.claimFullRequestTimeoutLockedV1(lease);
    }

    fn claimAllFullRequestTimeoutsIfExpiredLockedV1(
        self: *ManagedLifecycleV1,
    ) !void {
        var slot_index: usize = 0;
        while (slot_index < self.connection_capacity) : (slot_index += 1) {
            if (self.connection_slots[slot_index].active == null)
                continue;
            const lease = try self.leaseForSlotLockedV1(slot_index);
            _ = try self.claimFullRequestTimeoutLockedV1(lease);
        }
    }

    pub fn claimFullRequestTimeoutV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.claimFullRequestTimeoutLockedV1(lease);
    }

    fn claimFullRequestTimeoutLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) !bool {
        const deadline_claims_open =
            self.state == .ready or
            (self.state == .draining and
                self.effective_drain_policy == .finish_published);
        if (!deadline_claims_open) return false;
        const active =
            self.activeConnectionForLeaseLockedV1(lease) catch
                return false;
        if (!fullRequestDeadlineEligibleForActiveV1(
            active,
            self.state,
        )) {
            return false;
        }
        if (!self.fullRequestDeadlineExpiredLockedV1(lease))
            return false;

        if (!active.receive_retired and
            active.receive_timeout_ns != 0)
        {
            if (active.accept_timer) |*timer| {
                if (timer.read() >= active.receive_timeout_ns) {
                    _ = try self
                        .signalActiveConnectionForReceiveTimeoutLockedV1(
                        lease,
                    );
                    return false;
                }
            }
        }

        const next_signaled = std.math.add(
            u64,
            self.full_request_timeout_signaled_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        var next_cancelled_response: ?u64 = null;
        var next_requested_response_write: ?u64 = null;
        switch (active.phase) {
            .queued, .receiving_head, .request_head_received => {
                std.posix.shutdown(
                    active.handle,
                    if (active.phase == .queued) .both else .recv,
                ) catch |err| switch (err) {
                    error.ConnectionAborted,
                    error.ConnectionResetByPeer,
                    error.SocketNotConnected,
                    => {},
                    else => return LifecycleError.ConnectionSignalFailed,
                };
            },
            .request_received, .request_admitted => {},
            .response_ready => {
                if (active.response_cancel_before_write_cause == null) {
                    next_cancelled_response = std.math.add(
                        u64,
                        self.full_request_timeout_cancelled_response_connections,
                        1,
                    ) catch return LifecycleError.CounterOverflow;
                }
            },
            .response_writing => {
                if (active.response_write_failure == null and
                    std.meta.activeTag(
                        active.response_write_stop_state,
                    ) == .none)
                {
                    next_requested_response_write = std.math.add(
                        u64,
                        self.full_request_timeout_requested_response_write_connections,
                        1,
                    ) catch return LifecycleError.CounterOverflow;
                }
            },
            .response_written, .none => return false,
        }

        self.full_request_timeout_signaled_connections =
            next_signaled;
        self.last_full_request_timeout_signaled_phase =
            active.phase;
        active.hard_stop_cause = .full_request_timeout;
        active.full_request_timeout_signaled = true;
        active.full_request_timeout_retired = true;
        if (active.phase == .queued or
            active.phase == .receiving_head or
            active.phase == .request_head_received)
        {
            active.receive_retired = true;
        }
        if (next_cancelled_response) |next| {
            self.full_request_timeout_cancelled_response_connections =
                next;
            self.last_full_request_timeout_cancelled_response_phase =
                .response_ready;
            active.response_cancel_before_write_cause =
                .full_request_timeout;
        }
        if (next_requested_response_write) |next| {
            self.full_request_timeout_requested_response_write_connections =
                next;
            self.last_full_request_timeout_requested_response_write_phase =
                .response_writing;
            active.response_write_stop_state = .{
                .requested = .full_request_timeout,
            };
        }
        return true;
    }

    fn cancelResponseBeforeWriteForFullRequestTimeoutLockedV1(
        self: *ManagedLifecycleV1,
        active: *ActiveConnectionV1,
    ) LifecycleError!void {
        if (active.response_cancel_before_write_cause != null)
            return;
        self.full_request_timeout_cancelled_response_connections =
            std.math.add(
                u64,
                self.full_request_timeout_cancelled_response_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        self.last_full_request_timeout_cancelled_response_phase =
            .response_ready;
        active.response_cancel_before_write_cause =
            .full_request_timeout;
    }

    fn cancelResponseBeforeWriteForFailureLockedV1(
        self: *ManagedLifecycleV1,
        active: *ActiveConnectionV1,
    ) LifecycleError!void {
        _ = self;
        if (active.response_cancel_before_write_cause != null)
            return;
        active.response_cancel_before_write_cause =
            .failure;
    }

    fn requestResponseWriteStopForFullRequestTimeoutLockedV1(
        self: *ManagedLifecycleV1,
        active: *ActiveConnectionV1,
    ) LifecycleError!void {
        if (active.response_write_failure != null or
            std.meta.activeTag(
                active.response_write_stop_state,
            ) != .none)
        {
            return;
        }
        self.full_request_timeout_requested_response_write_connections =
            std.math.add(
                u64,
                self.full_request_timeout_requested_response_write_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        self.last_full_request_timeout_requested_response_write_phase =
            .response_writing;
        active.response_write_stop_state = .{
            .requested = .full_request_timeout,
        };
    }

    fn signalActiveConnectionForReceiveTimeoutV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.signalActiveConnectionForReceiveTimeoutLockedV1(lease);
    }

    pub fn claimReceiveTimeoutIfExpiredV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active =
            self.activeConnectionForLeaseLockedV1(lease) catch
                return false;
        if (active.receive_timeout_ns == 0 or
            active.receive_retired or
            active.receive_timeout_signaled)
        {
            return false;
        }
        const timer = if (active.accept_timer) |*value|
            value
        else
            return false;
        if (timer.read() < active.receive_timeout_ns)
            return false;
        return self.signalActiveConnectionForReceiveTimeoutLockedV1(
            lease,
        );
    }

    fn signalActiveConnectionForReceiveTimeoutLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) !bool {
        if (self.state != .ready) return false;
        const active =
            self.activeConnectionForLeaseLockedV1(lease) catch
                return false;
        if (active.phase == .request_received or
            active.phase == .request_admitted or
            active.drain_signaled or
            active.receive_timeout_signaled or
            active.receive_retired or
            active.hard_stop_cause != null)
        {
            return false;
        }
        const next_signaled = std.math.add(
            u64,
            self.receive_timeout_signaled_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        if (active.phase == .queued) {
            std.posix.shutdown(active.handle, .both) catch |err| switch (err) {
                error.ConnectionAborted,
                error.ConnectionResetByPeer,
                error.SocketNotConnected,
                => {},
                else => return LifecycleError.ConnectionSignalFailed,
            };
        }
        self.receive_timeout_signaled_connections = next_signaled;
        self.last_receive_timeout_signaled_phase = active.phase;
        active.hard_stop_cause = .receive_timeout;
        active.receive_timeout_signaled = true;
        active.receive_retired = true;
        return true;
    }

    pub fn retireActiveConnectionReceiveV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.receive_timeout_signaled) return false;
        if (active.receive_retired) return true;
        if (active.drain_signaled or self.state != .ready) {
            active.receive_retired = true;
            return true;
        }
        if (receiveDeadlineExpiredV1(timer, timeout_ns)) {
            _ = try self.signalActiveConnectionForReceiveTimeoutLockedV1(
                lease,
            );
            return false;
        }
        if (try self.claimFullRequestTimeoutIfExpiredLockedV1(lease))
            return false;
        active.receive_retired = true;
        return true;
    }

    pub fn retireFullRequestTimeoutV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = try self.activeConnectionForLeaseLockedV1(lease);
        if (active.full_request_timeout_signaled)
            return false;
        if (active.full_request_timeout_retired)
            return true;
        if (try self.claimFullRequestTimeoutIfExpiredLockedV1(lease))
            return false;
        active.full_request_timeout_retired = true;
        return true;
    }

    /// Emergency convergence used only after a concurrent transport worker
    /// has returned an infrastructure error before normal retirement. Exact
    /// lease validation still fences a reused slot; the caller owns and
    /// closes the corresponding socket outside the lifecycle mutex.
    fn forceFinishConnectionLockedV1(
        self: *ManagedLifecycleV1,
        lease: ManagedConnectionLeaseV1,
    ) LifecycleError!void {
        return self.forceRetireConnectionForCleanupLockedV1(
            lease,
            .lifecycle_failure,
        );
    }
};

const ManagedQueuedConnectionV1 = struct {
    connection: std.net.Server.Connection,
    lease: ManagedConnectionLeaseV1,
};

const ManagedDispatchedConnectionV1 = struct {
    queued: ManagedQueuedConnectionV1,
    accept_timer: ?std.time.Timer,
};

const ManagedConcurrentPendingEventV1 = struct {
    lifecycle: ?*ManagedConcurrentLifecycleV1 = null,
    observer: ?ManagedConcurrentObserverV1,
    event: ManagedConcurrentEventV1,

    fn emit(self: ManagedConcurrentPendingEventV1) void {
        if (self.observer) |observer| {
            defer self.complete();
            observer.observe(self.event);
        }
    }

    fn complete(self: ManagedConcurrentPendingEventV1) void {
        const lifecycle = self.lifecycle orelse return;
        lifecycle.managed.mutex.lock();
        std.debug.assert(lifecycle.observer_in_flight != 0);
        lifecycle.observer_in_flight -= 1;
        lifecycle.settled.broadcast();
        lifecycle.managed.mutex.unlock();
    }
};

fn managedConcurrentMonotonicNsV1() u64 {
    const tag = builtin.os.tag;
    if (comptime tag == .windows or tag == .wasi or tag == .uefi)
        return 0;
    const clock_id = if (comptime tag == .macos or
        tag == .ios or tag == .tvos or tag == .watchos or
        tag == .visionos)
        std.posix.CLOCK.UPTIME_RAW
    else if (comptime tag == .linux)
        std.posix.CLOCK.MONOTONIC_RAW
    else
        std.posix.CLOCK.MONOTONIC;
    const timestamp = std.posix.clock_gettime(clock_id) catch
        return 0;
    const seconds = std.math.cast(
        u64,
        timestamp.sec,
    ) orelse return 0;
    const nanoseconds = std.math.cast(
        u64,
        timestamp.nsec,
    ) orelse return 0;
    if (nanoseconds >= std.time.ns_per_s) return 0;
    return std.math.add(
        u64,
        std.math.mul(
            u64,
            seconds,
            std.time.ns_per_s,
        ) catch return 0,
        nanoseconds,
    ) catch return 0;
}

const maximum_managed_concurrent_batch_events_v1: usize =
    maximum_managed_pending_connections_v1 * 2;

const ManagedConcurrentDetachedConnectionV1 = struct {
    connection: std.net.Server.Connection,
    lease: ManagedConnectionLeaseV1,
};

const ManagedConcurrentDetachedBatchV1 = struct {
    connections: [maximum_managed_pending_connections_v1]?ManagedConcurrentDetachedConnectionV1 =
        [_]?ManagedConcurrentDetachedConnectionV1{null} **
        maximum_managed_pending_connections_v1,
    connection_count: u8 = 0,
    events: [maximum_managed_concurrent_batch_events_v1]?ManagedConcurrentPendingEventV1 =
        [_]?ManagedConcurrentPendingEventV1{null} **
        maximum_managed_concurrent_batch_events_v1,
    event_count: u8 = 0,

    fn appendConnection(
        self: *ManagedConcurrentDetachedBatchV1,
        lifecycle: *ManagedConcurrentLifecycleV1,
        connection: std.net.Server.Connection,
        lease: ManagedConnectionLeaseV1,
    ) void {
        std.debug.assert(
            self.connection_count <
                maximum_managed_pending_connections_v1,
        );
        std.debug.assert(
            lifecycle.detached_close_in_flight <
                maximum_managed_connection_slots_v1,
        );
        self.connections[self.connection_count] = .{
            .connection = connection,
            .lease = lease,
        };
        self.connection_count += 1;
        lifecycle.detached_close_in_flight += 1;
    }

    fn appendEvent(
        self: *ManagedConcurrentDetachedBatchV1,
        pending: ManagedConcurrentPendingEventV1,
    ) void {
        std.debug.assert(
            self.event_count <
                maximum_managed_concurrent_batch_events_v1,
        );
        self.events[self.event_count] = pending;
        self.event_count += 1;
    }

    fn closeConnections(
        self: *ManagedConcurrentDetachedBatchV1,
        lifecycle: *ManagedConcurrentLifecycleV1,
    ) LifecycleError!void {
        var first_error: ?LifecycleError = null;
        var connection_index: usize = 0;
        while (connection_index < self.connection_count) : (connection_index += 1) {
            var detached =
                self.connections[connection_index] orelse
                continue;
            detached.connection.stream.close();
            lifecycle.managed.mutex.lock();
            _ = lifecycle.managed.confirmTransportClosedLockedV1(
                detached.lease,
                .detached_owner_confirmed,
            ) catch |err| blk: {
                if (first_error == null) first_error = err;
                break :blk false;
            };
            std.debug.assert(
                lifecycle.detached_close_in_flight != 0,
            );
            lifecycle.detached_close_in_flight -= 1;
            lifecycle.settled.broadcast();
            lifecycle.managed.mutex.unlock();
            self.connections[connection_index] = null;
        }
        self.connection_count = 0;
        if (first_error) |err| return err;
    }

    fn emitEvents(
        self: *ManagedConcurrentDetachedBatchV1,
    ) void {
        var event_index: usize = 0;
        while (event_index < self.event_count) : (event_index += 1) {
            const pending = self.events[event_index] orelse
                continue;
            pending.emit();
            self.events[event_index] = null;
        }
        self.event_count = 0;
    }

    fn release(
        self: *ManagedConcurrentDetachedBatchV1,
        lifecycle: *ManagedConcurrentLifecycleV1,
    ) LifecycleError!void {
        var close_error: ?LifecycleError = null;
        self.closeConnections(lifecycle) catch |err| {
            close_error = err;
        };
        self.emitEvents();
        if (close_error) |err| return err;
    }
};

const ManagedQueuedRetirementCauseV1 = enum {
    drain,
    failure,
};

/// Fixed-capacity concurrent transport registry. `managed.mutex` is the only
/// state mutex: queue predicates, slot phases, counters, and snapshots all
/// share one linearization point.
pub const ManagedConcurrentLifecycleV1 = struct {
    managed: ManagedLifecycleV1,
    config: ManagedConcurrentConfigV1,
    work_available: std.Thread.Condition = .{},
    queue_capacity_available: std.Thread.Condition = .{},
    deadline_changed: std.Thread.Condition = .{},
    settled: std.Thread.Condition = .{},
    queue: [maximum_managed_pending_connections_v1]?ManagedQueuedConnectionV1 =
        [_]?ManagedQueuedConnectionV1{null} **
        maximum_managed_pending_connections_v1,
    queue_len: u8 = 0,
    queue_high_watermark: u8 = 0,
    running_high_watermark: u8 = 0,
    queue_enqueued_connections: u64 = 0,
    queue_dispatched_connections: u64 = 0,
    listener_backpressure_activations: u64 = 0,
    listener_backpressure_resumptions: u64 = 0,
    drain_cancelled_queued_connections: u64 = 0,
    failure_cancelled_queued_connections: u64 = 0,
    receive_timeout_queued_connections: u64 = 0,
    full_request_timeout_queued_connections: u64 = 0,
    event_ordinal: u64 = 0,
    accept_paused: bool = false,
    serving: bool = false,
    observer: ?ManagedConcurrentObserverV1 = null,
    observer_in_flight: usize = 0,
    detached_close_in_flight: u8 = 0,
    fatal_error: ?anyerror = null,
    cleanup_error: ?anyerror = null,

    pub fn initV1(
        process_generation: u64,
        config: ManagedConcurrentConfigV1,
    ) (Error || LifecycleError)!ManagedConcurrentLifecycleV1 {
        try validateManagedConcurrentConfigV1(config);
        const connection_capacity: u8 = @intCast(
            @as(u16, config.worker_count) +
                @as(u16, config.pending_connection_capacity),
        );
        return .{
            .managed = try ManagedLifecycleV1
                .initWithConnectionCapacityV1(
                process_generation,
                connection_capacity,
            ),
            .config = config,
        };
    }

    pub fn markReadyV1(
        self: *ManagedConcurrentLifecycleV1,
    ) LifecycleError!void {
        return self.managed.markReadyV1();
    }

    pub fn snapshotV1(
        self: *ManagedConcurrentLifecycleV1,
    ) ManagedConcurrentSnapshotV1 {
        self.managed.mutex.lock();
        defer self.managed.mutex.unlock();
        return self.snapshotLockedV1();
    }

    fn snapshotLockedV1(
        self: *ManagedConcurrentLifecycleV1,
    ) ManagedConcurrentSnapshotV1 {
        const managed_snapshot = self.managed.snapshotLockedV1();
        const running_connections =
            self.runningConnectionsLockedV1();
        const phase_counts =
            self.managed.phaseCountsLockedV1();
        std.debug.assert(
            managed_snapshot.active_connections ==
                self.queue_len + running_connections,
        );
        std.debug.assert(
            managed_snapshot.queued_connections ==
                self.queue_len,
        );
        std.debug.assert(
            managedDrainPhaseTotalV1(phase_counts) ==
                @as(u16, managed_snapshot.active_connections),
        );
        std.debug.assert(
            managed_snapshot.accepted_connections ==
                managed_snapshot.completed_connections +
                    managed_snapshot.failed_connections +
                    managed_snapshot.active_connections,
        );
        std.debug.assert(
            self.queue_enqueued_connections ==
                managed_snapshot.accepted_connections,
        );
        std.debug.assert(
            self.queue_enqueued_connections ==
                self.queue_dispatched_connections +
                    self.drain_cancelled_queued_connections +
                    self.failure_cancelled_queued_connections +
                    self.receive_timeout_queued_connections +
                    self.full_request_timeout_queued_connections +
                    self.queue_len,
        );
        std.debug.assert(
            managed_snapshot.failure_signaled_connections +|
                managed_snapshot.failure_cancelled_response_connections +|
                managed_snapshot.failure_requested_response_write_connections <=
                self.queue_dispatched_connections,
        );
        std.debug.assert(
            self.queue_high_watermark <=
                self.config.pending_connection_capacity,
        );
        std.debug.assert(
            self.running_high_watermark <=
                self.config.worker_count,
        );
        return .{
            .managed = managed_snapshot,
            .worker_count = self.config.worker_count,
            .pending_connection_capacity = self.config.pending_connection_capacity,
            .running_connections = running_connections,
            .queue_high_watermark = self.queue_high_watermark,
            .running_high_watermark = self.running_high_watermark,
            .queue_enqueued_connections = self.queue_enqueued_connections,
            .queue_dispatched_connections = self.queue_dispatched_connections,
            .listener_backpressure_activations = self.listener_backpressure_activations,
            .listener_backpressure_resumptions = self.listener_backpressure_resumptions,
            .drain_cancelled_queued_connections = self.drain_cancelled_queued_connections,
            .failure_cancelled_queued_connections = self.failure_cancelled_queued_connections,
            .receive_timeout_queued_connections = self.receive_timeout_queued_connections,
            .full_request_timeout_queued_connections = self.full_request_timeout_queued_connections,
            .event_ordinal = self.event_ordinal,
            .accept_paused = self.accept_paused,
            .cleanup_failed = self.cleanup_error != null,
            .phase_counts = phase_counts,
        };
    }

    fn runningConnectionsLockedV1(
        self: *ManagedConcurrentLifecycleV1,
    ) u8 {
        std.debug.assert(
            self.managed.active_connections >= self.queue_len,
        );
        return self.managed.active_connections - self.queue_len;
    }

    fn makeEventLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        kind: ManagedConcurrentEventKindV1,
        lease: ?ManagedConnectionLeaseV1,
        worker_index: ?u8,
    ) LifecycleError!ManagedConcurrentPendingEventV1 {
        self.event_ordinal = std.math.add(
            u64,
            self.event_ordinal,
            1,
        ) catch return LifecycleError.CounterOverflow;
        return self.captureEventLockedV1(.{
            .ordinal = self.event_ordinal,
            .kind = kind,
            .lease = lease,
            .worker_index = worker_index,
            .queued_connections = self.queue_len,
            .running_connections = self.runningConnectionsLockedV1(),
        });
    }

    fn captureEventLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        event: ManagedConcurrentEventV1,
    ) ManagedConcurrentPendingEventV1 {
        var captured = event;
        if (self.observer != null)
            captured.linearized_monotonic_ns =
                managedConcurrentMonotonicNsV1();
        if (self.observer != null)
            self.observer_in_flight += 1;
        return .{
            .lifecycle = if (self.observer != null) self else null,
            .observer = self.observer,
            .event = captured,
        };
    }

    fn removeQueueAtLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        index: usize,
    ) ManagedQueuedConnectionV1 {
        std.debug.assert(index < self.queue_len);
        const queued = self.queue[index] orelse unreachable;
        var cursor = index;
        while (cursor + 1 < self.queue_len) : (cursor += 1) {
            self.queue[cursor] = self.queue[cursor + 1];
        }
        self.queue[self.queue_len - 1] = null;
        self.queue_len -= 1;
        return queued;
    }

    fn popForWorkerLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        worker_index: u8,
        events: *ManagedConcurrentDetachedBatchV1,
    ) LifecycleError!ManagedDispatchedConnectionV1 {
        const queued = self.queue[0] orelse unreachable;
        const active =
            try self.managed.activeConnectionForLeaseLockedV1(
                queued.lease,
            );
        if (active.phase != .queued)
            return LifecycleError.ConnectionPhaseMismatch;
        const next_dispatched = std.math.add(
            u64,
            self.queue_dispatched_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        const dispatched_ordinal = std.math.add(
            u64,
            self.event_ordinal,
            1,
        ) catch return LifecycleError.CounterOverflow;
        const will_resume = self.managed.state == .ready and
            self.accept_paused and
            self.queue_len - 1 <
                self.config.pending_connection_capacity;
        const resumed_count = if (will_resume)
            std.math.add(
                u64,
                self.listener_backpressure_resumptions,
                1,
            ) catch return LifecycleError.CounterOverflow
        else
            self.listener_backpressure_resumptions;
        const resumed_ordinal = if (will_resume)
            std.math.add(
                u64,
                dispatched_ordinal,
                1,
            ) catch return LifecycleError.CounterOverflow
        else
            dispatched_ordinal;
        _ = self.removeQueueAtLockedV1(0);
        active.phase = .receiving_head;
        self.queue_dispatched_connections = next_dispatched;
        const running_connections =
            self.runningConnectionsLockedV1();
        self.running_high_watermark = @max(
            self.running_high_watermark,
            running_connections,
        );
        self.event_ordinal = dispatched_ordinal;
        events.appendEvent(self.captureEventLockedV1(.{
            .ordinal = dispatched_ordinal,
            .kind = .dispatched,
            .lease = queued.lease,
            .worker_index = worker_index,
            .queued_connections = self.queue_len,
            .running_connections = running_connections,
        }));
        if (will_resume) {
            self.accept_paused = false;
            self.listener_backpressure_resumptions =
                resumed_count;
            self.event_ordinal = resumed_ordinal;
            events.appendEvent(self.captureEventLockedV1(.{
                .ordinal = resumed_ordinal,
                .kind = .backpressure_resumed,
                .queued_connections = self.queue_len,
                .running_connections = running_connections,
            }));
        }
        self.queue_capacity_available.broadcast();
        self.deadline_changed.broadcast();
        return .{
            .queued = queued,
            .accept_timer = active.accept_timer,
        };
    }

    fn detachQueuedForStopLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        cause: ManagedQueuedRetirementCauseV1,
        batch: *ManagedConcurrentDetachedBatchV1,
    ) !void {
        while (self.queue_len != 0) {
            const queued = self.queue[0] orelse unreachable;
            const active =
                try self.managed.activeConnectionForLeaseLockedV1(
                    queued.lease,
                );
            if (active.phase != .queued)
                return LifecycleError.ConnectionPhaseMismatch;
            const next_drain_signaled = switch (cause) {
                .drain => std.math.add(
                    u64,
                    self.managed.drain_signaled_connections,
                    1,
                ) catch return LifecycleError.CounterOverflow,
                .failure => self.managed.drain_signaled_connections,
            };
            const next_cause_count = switch (cause) {
                .drain => std.math.add(
                    u64,
                    self.drain_cancelled_queued_connections,
                    1,
                ) catch return LifecycleError.CounterOverflow,
                .failure => std.math.add(
                    u64,
                    self.failure_cancelled_queued_connections,
                    1,
                ) catch return LifecycleError.CounterOverflow,
            };
            _ = std.math.add(
                u64,
                self.managed.failed_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            const retirement_ordinal = std.math.add(
                u64,
                self.event_ordinal,
                1,
            ) catch return LifecycleError.CounterOverflow;
            _ = self.removeQueueAtLockedV1(0);
            batch.appendConnection(
                self,
                queued.connection,
                queued.lease,
            );
            active.receive_retired = true;
            active.full_request_timeout_retired = true;
            switch (cause) {
                .drain => {
                    std.posix.shutdown(
                        active.handle,
                        .both,
                    ) catch |err| switch (err) {
                        error.ConnectionAborted,
                        error.ConnectionResetByPeer,
                        error.SocketNotConnected,
                        => {},
                        else => {},
                    };
                    self.managed.drain_signaled_connections =
                        next_drain_signaled;
                    self.managed.last_drain_signaled_phase =
                        .queued;
                    active.drain_signaled = true;
                    self.drain_cancelled_queued_connections =
                        next_cause_count;
                },
                .failure => {
                    self.failure_cancelled_queued_connections =
                        next_cause_count;
                },
            }
            try self.managed.finishConnectionLockedV1(
                queued.lease,
                false,
            );
            self.event_ordinal = retirement_ordinal;
            batch.appendEvent(self.captureEventLockedV1(.{
                .ordinal = retirement_ordinal,
                .kind = switch (cause) {
                    .drain => .queued_drain,
                    .failure => .queued_failure,
                },
                .lease = queued.lease,
                .queued_connections = self.queue_len,
                .running_connections = self.runningConnectionsLockedV1(),
            }));
        }
    }

    fn expireQueuedAtLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        index: usize,
        receive_wins: bool,
        batch: *ManagedConcurrentDetachedBatchV1,
    ) !void {
        const queued = self.queue[index] orelse unreachable;
        const active =
            try self.managed.activeConnectionForLeaseLockedV1(
                queued.lease,
            );
        if (active.phase != .queued)
            return LifecycleError.ConnectionPhaseMismatch;
        const next_timeout_count = if (receive_wins)
            std.math.add(
                u64,
                self.receive_timeout_queued_connections,
                1,
            ) catch return LifecycleError.CounterOverflow
        else
            std.math.add(
                u64,
                self.full_request_timeout_queued_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        if (receive_wins) {
            _ = std.math.add(
                u64,
                self.managed.receive_timeout_signaled_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        } else {
            _ = std.math.add(
                u64,
                self.managed.full_request_timeout_signaled_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        }
        _ = std.math.add(
            u64,
            self.managed.failed_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        const timeout_ordinal = std.math.add(
            u64,
            self.event_ordinal,
            1,
        ) catch return LifecycleError.CounterOverflow;
        const will_resume = self.managed.state == .ready and
            self.accept_paused and
            self.queue_len - 1 <
                self.config.pending_connection_capacity;
        const resumed_count = if (will_resume)
            std.math.add(
                u64,
                self.listener_backpressure_resumptions,
                1,
            ) catch return LifecycleError.CounterOverflow
        else
            self.listener_backpressure_resumptions;
        const resumed_ordinal = if (will_resume)
            std.math.add(
                u64,
                timeout_ordinal,
                1,
            ) catch return LifecycleError.CounterOverflow
        else
            timeout_ordinal;
        if (receive_wins) {
            if (!try self.managed
                .signalActiveConnectionForReceiveTimeoutLockedV1(
                queued.lease,
            )) return LifecycleError.ConnectionInterrupted;
            active.full_request_timeout_retired = true;
            self.receive_timeout_queued_connections =
                next_timeout_count;
        } else {
            if (!try self.managed
                .claimFullRequestTimeoutLockedV1(
                queued.lease,
            )) return LifecycleError.ConnectionInterrupted;
            self.full_request_timeout_queued_connections =
                next_timeout_count;
        }
        _ = self.removeQueueAtLockedV1(index);
        batch.appendConnection(
            self,
            queued.connection,
            queued.lease,
        );
        try self.managed.finishConnectionLockedV1(
            queued.lease,
            false,
        );
        self.event_ordinal = timeout_ordinal;
        batch.appendEvent(self.captureEventLockedV1(.{
            .ordinal = timeout_ordinal,
            .kind = if (receive_wins)
                .queued_receive_timeout
            else
                .queued_full_request_timeout,
            .lease = queued.lease,
            .queued_connections = self.queue_len,
            .running_connections = self.runningConnectionsLockedV1(),
        }));
        if (will_resume) {
            self.accept_paused = false;
            self.listener_backpressure_resumptions =
                resumed_count;
            self.event_ordinal = resumed_ordinal;
            batch.appendEvent(self.captureEventLockedV1(.{
                .ordinal = resumed_ordinal,
                .kind = .backpressure_resumed,
                .queued_connections = self.queue_len,
                .running_connections = self.runningConnectionsLockedV1(),
            }));
        }
        self.queue_capacity_available.broadcast();
        self.deadline_changed.broadcast();
        self.settled.broadcast();
    }

    fn signalRunningConnectionsForFailureLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        batch: *ManagedConcurrentDetachedBatchV1,
    ) LifecycleError!void {
        var first_error: ?LifecycleError = null;
        var slot_index: usize = 0;
        while (slot_index <
            self.managed.connection_capacity) : (slot_index += 1)
        {
            const slot =
                &self.managed.connection_slots[slot_index];
            const active = if (slot.active) |*connection|
                connection
            else
                continue;
            if (active.phase == .queued) continue;
            const lease = self.managed
                .leaseForSlotLockedV1(slot_index) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            const signal_result = self.managed
                .signalConnectionForFailureLockedV1(
                active,
            ) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            if (signal_result.signal_failed and
                first_error == null)
            {
                first_error =
                    LifecycleError.ConnectionSignalFailed;
            }
            if (!signal_result.claimed) continue;
            const event = self.makeEventLockedV1(
                .running_failure,
                lease,
                null,
            ) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            batch.appendEvent(event);
        }
        if (first_error) |err| return err;
    }

    fn recordFatalLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        fatal_error: anyerror,
    ) void {
        if (self.fatal_error == null)
            self.fatal_error = fatal_error;
        if (self.managed.state != .stopped)
            self.managed.state = .failed;
        self.accept_paused = false;
        self.work_available.broadcast();
        self.queue_capacity_available.broadcast();
        self.deadline_changed.broadcast();
        self.settled.broadcast();
    }

    fn recordCleanupErrorLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        cleanup_error: anyerror,
    ) void {
        if (self.cleanup_error == null)
            self.cleanup_error = cleanup_error;
    }

    /// Last-resort registry convergence after every worker and the watchdog
    /// have joined. Queued entries still carry the only closeable stream
    /// objects; remaining non-queued slots refer to worker-owned streams that
    /// are already closed, so only their registry ownership is retired here.
    fn forceConvergeAfterJoinLockedV1(
        self: *ManagedConcurrentLifecycleV1,
        batch: *ManagedConcurrentDetachedBatchV1,
    ) LifecycleError!void {
        var first_error: ?LifecycleError = null;
        while (self.queue_len != 0) {
            const queued = self.removeQueueAtLockedV1(0);
            batch.appendConnection(
                self,
                queued.connection,
                queued.lease,
            );
            self.failure_cancelled_queued_connections = std.math.add(
                u64,
                self.failure_cancelled_queued_connections,
                1,
            ) catch blk: {
                if (first_error == null)
                    first_error = LifecycleError.CounterOverflow;
                break :blk self.failure_cancelled_queued_connections;
            };
            self.managed
                .forceRetireConnectionForCleanupLockedV1(
                queued.lease,
                .lifecycle_failure,
            ) catch |err| {
                self.recordCleanupErrorLockedV1(err);
                if (first_error == null) first_error = err;
            };
        }
        for (
            self.managed
                .connection_slots[0..self.managed.connection_capacity],
            0..,
        ) |*slot, slot_index| {
            const active = slot.active orelse continue;
            if (active.phase == .queued) continue;
            const lease =
                self.managed.leaseForSlotLockedV1(
                    slot_index,
                ) catch |err| {
                    self.recordCleanupErrorLockedV1(err);
                    if (first_error == null) first_error = err;
                    continue;
                };
            self.managed
                .forceRetireConnectionForCleanupLockedV1(
                lease,
                .lifecycle_failure,
            ) catch |err| {
                self.recordCleanupErrorLockedV1(err);
                if (first_error == null) first_error = err;
                continue;
            };
            _ = self.managed.confirmTransportClosedLockedV1(
                lease,
                .forced_after_join,
            ) catch |err| blk: {
                self.recordCleanupErrorLockedV1(err);
                if (first_error == null) first_error = err;
                break :blk false;
            };
        }
        self.accept_paused = false;
        self.work_available.broadcast();
        self.queue_capacity_available.broadcast();
        self.deadline_changed.broadcast();
        self.settled.broadcast();
        if (first_error) |err| return err;
    }
};

fn receiveDeadlineExpiredV1(
    timer: ?*std.time.Timer,
    timeout_ns: u64,
) bool {
    if (timeout_ns == 0) return false;
    const active_timer = timer orelse return false;
    return active_timer.read() >= timeout_ns;
}

pub fn run(
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
) !void {
    try validateConfig(config);
    const address = try std.net.Address.parseIp(config.bind, config.port);
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    try serveListenerV1(&listener, config, runtime);
}

pub fn serveListenerV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
) !void {
    try validateConfig(config);
    if (config.receive_timeout_ns != 0)
        return Error.ReceiveTimeoutRequiresManagedLifecycle;
    if (config.full_request_timeout_ns != 0)
        return Error.FullRequestTimeoutRequiresManagedLifecycle;
    if (config.peer_reset_poll_timeout_ns != 0)
        return Error.PeerResetPollRequiresManagedLifecycle;
    if (config.peer_send_close_policy != .preserve_response)
        return Error.PeerSendClosePolicyRequiresManagedLifecycle;
    if (config.response_write_quantum_bytes !=
        maximum_response_write_quantum_bytes)
    {
        return Error.ResponseWriteQuantumRequiresManagedLifecycle;
    }
    if (!isLoopbackAddress(listener.listen_address))
        return Error.NonLoopbackBind;
    if (config.stop_after_requests == 0) return;

    var remaining = config.stop_after_requests;
    while (remaining == null or remaining.? > 0) {
        const connection = try listener.accept();
        if (remaining) |*count| count.* -= 1;
        serveConnectionV1(connection, runtime) catch continue;
    }
}

pub fn serveManagedListenerV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedLifecycleV1,
) !void {
    return serveManagedListenerWithObserversV1(
        listener,
        config,
        runtime,
        lifecycle,
        null,
        null,
    );
}

/// Managed-listener variant with an optional post-admission observer.
///
/// Lifecycle bookkeeping always runs before the observer. The observer is
/// invoked outside lifecycle, HTTP-control, and service locks, so a test or
/// host coordinator can establish a deterministic drain barrier without
/// becoming part of the runtime lock order.
pub fn serveManagedListenerWithWorkObserverV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedLifecycleV1,
    work_observer: ?prepared_http.RequestWorkControlV1,
) !void {
    return serveManagedListenerWithObserversV1(
        listener,
        config,
        runtime,
        lifecycle,
        work_observer,
        null,
    );
}

pub fn serveManagedListenerWithObserversV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedLifecycleV1,
    work_observer: ?prepared_http.RequestWorkControlV1,
    response_observer: ?prepared_http.RequestResponseControlV1,
) !void {
    try validateConfig(config);
    if (!isLoopbackAddress(listener.listen_address))
        return Error.NonLoopbackBind;
    if (lifecycle.snapshotV1().state != .ready)
        return LifecycleError.InvalidTransition;

    var remaining = config.stop_after_requests;
    if (remaining == 0) {
        _ = try beginManagedDrainV1(lifecycle, runtime);
    }

    while (lifecycle.snapshotV1().state == .ready) {
        const connection = listener.accept() catch |err| {
            lifecycle.markFailedV1();
            return err;
        };
        const accept_timer =
            if (config.receive_timeout_ns == 0 and
            config.full_request_timeout_ns == 0)
                null
            else
                std.time.Timer.start() catch |err| {
                    connection.stream.close();
                    lifecycle.markFailedV1();
                    return err;
                };
        const receive_timer = if (config.receive_timeout_ns == 0)
            null
        else
            accept_timer;
        const full_request_timer =
            if (config.full_request_timeout_ns == 0)
                null
            else
                accept_timer;
        const lease =
            lifecycle.beginConnectionWithFullRequestTimeoutV1(
                connection.stream.handle,
                config.receive_timeout_ns,
                config.full_request_timeout_ns,
                accept_timer,
            ) catch |err| {
                connection.stream.close();
                if (err == LifecycleError.InvalidTransition) break;
                lifecycle.markFailedV1();
                return err;
            };

        _ = serveManagedConnectionV1(
            connection,
            runtime,
            lifecycle,
            lease,
            config.receive_timeout_ns,
            config.full_request_timeout_ns,
            config.peer_reset_poll_timeout_ns,
            config.peer_send_close_policy,
            config.response_write_quantum_bytes,
            receive_timer,
            full_request_timer,
            work_observer,
            response_observer,
            .per_connection,
        ) catch |err| {
            _ = lifecycle.confirmTransportClosedV1(
                lease,
                .owner_confirmed,
            ) catch |confirm_error| {
                lifecycle.markFailedV1();
                return confirm_error;
            };
            lifecycle.markFailedV1();
            return err;
        };
        _ = try lifecycle.confirmTransportClosedV1(
            lease,
            .owner_confirmed,
        );
        if (remaining) |*count| count.* -= 1;
        if (remaining == 0) {
            _ = try beginManagedDrainV1(
                lifecycle,
                runtime,
            );
        }
    }

    try lifecycle.markStoppedV1();
}

/// Requests drain and opens one loopback connection to release a listener
/// blocked in `accept`. The wake connection is rechecked against the drain
/// state and never receives a unary admission sequence.
pub fn requestDrainAndWakeV1(
    lifecycle: *ManagedLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    listen_address: std.net.Address,
) !void {
    _ = try requestDrainAndWakeWithPolicyV1(
        lifecycle,
        runtime,
        listen_address,
        .cancel_active,
    );
}

/// Initiates managed drain with an explicit monotonic policy and returns the
/// selection evidence captured at the lifecycle linearization point.
///
/// A later `cancel_active` request may escalate `finish_published`. The reverse
/// request cannot undo cancellation that has already been selected.
pub fn requestDrainAndWakeWithPolicyV1(
    lifecycle: *ManagedLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    listen_address: std.net.Address,
    policy: ManagedDrainPolicyV1,
) !ManagedDrainInitiationReceiptV1 {
    if (!isLoopbackAddress(listen_address))
        return Error.NonLoopbackBind;
    const result = try beginManagedDrainWithPolicyV1(
        lifecycle,
        runtime,
        policy,
    );
    if (result.active_was_present) return result.receipt;
    const wake = std.net.tcpConnectToAddress(
        listen_address,
    ) catch |err| {
        if (lifecycle.snapshotV1().state == .stopped)
            return result.receipt;
        return err;
    };
    wake.close();
    return result.receipt;
}

/// Holds listener lifecycle authority until completion admission is closed.
/// Consequently `draining` is never externally visible while the HTTP
/// runtime can still admit a completion.
fn beginManagedDrainV1(
    lifecycle: *ManagedLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
) !bool {
    const result = try beginManagedDrainWithPolicyV1(
        lifecycle,
        runtime,
        .cancel_active,
    );
    return result.active_was_present;
}

fn beginManagedDrainWithPolicyV1(
    lifecycle: *ManagedLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    requested_policy: ManagedDrainPolicyV1,
) !ManagedDrainBeginResultV1 {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    try lifecycle.claimAllFullRequestTimeoutsIfExpiredLockedV1();
    const state_before = lifecycle.state;
    switch (state_before) {
        .ready, .draining => {},
        else => return LifecycleError.InvalidTransition,
    }
    const policy_resolution =
        lifecycle.resolveDrainPolicyLockedV1(requested_policy);
    const drain_receipt = switch (policy_resolution.effective_policy) {
        .cancel_active => prepared_http.beginDrainV1(runtime) catch |err| {
            lifecycle.state = .failed;
            return err;
        },
        .finish_published => prepared_http.beginDrainPreservingActiveV1(runtime),
    };
    applyDrainWorkReceiptWithPolicyLockedV1(
        lifecycle,
        drain_receipt,
        policy_resolution.effective_policy,
    ) catch |err| {
        lifecycle.state = .failed;
        return err;
    };
    const connection_actions_applied =
        state_before == .ready or
        policy_resolution.policy_was_escalated;
    const decision_policy =
        if (connection_actions_applied)
            policy_resolution.effective_policy
        else
            ManagedDrainPolicyV1.finish_published;
    const phase_counts = lifecycle.phaseCountsLockedV1();
    const decisions = lifecycle.drainDecisionCountsLockedV1(
        decision_policy,
        drain_receipt,
    );
    if (state_before == .ready) {
        lifecycle.captureDrainSettlementCohortLockedV1(
            policy_resolution.effective_policy,
            drain_receipt,
            phase_counts,
            decisions,
        ) catch |err| {
            lifecycle.state = .failed;
            return err;
        };
    } else if (policy_resolution.policy_was_escalated) {
        lifecycle.reviseDrainSettlementCohortLockedV1(
            policy_resolution.effective_policy,
            drain_receipt,
        ) catch |err| {
            lifecycle.state = .failed;
            return err;
        };
    }
    const accepted_connections = lifecycle.accepted_connections;
    const completed_connections = lifecycle.completed_connections;
    const failed_connections = lifecycle.failed_connections;
    const active_was_present =
        managedDrainPhaseTotalV1(phase_counts) != 0;
    if (connection_actions_applied) {
        _ = lifecycle
            .signalActiveConnectionForDrainWithPolicyLockedV1(
            policy_resolution.effective_policy,
        ) catch |err| {
            lifecycle.state = .failed;
            return err;
        };
    }
    lifecycle.state = .draining;
    const receipt: ManagedDrainInitiationReceiptV1 = .{
        .process_generation = lifecycle.process_generation,
        .requested_policy = requested_policy,
        .effective_policy = policy_resolution.effective_policy,
        .drain_was_new = state_before == .ready,
        .policy_was_escalated = policy_resolution.policy_was_escalated,
        .connection_actions_applied = connection_actions_applied,
        .admission_was_open = drain_receipt.admission_was_open,
        .state_before = state_before,
        .state_at_linearization = .draining,
        .accepted_connections = accepted_connections,
        .completed_connections = completed_connections,
        .failed_connections = failed_connections,
        .phase_counts = phase_counts,
        .decisions = decisions,
        .pending_settlement_connections = lifecycle.active_connections,
        .active_work = drain_receipt.active_work,
        .active_work_owner = drain_receipt.transport_owner,
        .work_cancellation = drain_receipt.cancellation,
        .work_cancellation_winner = drain_receipt.cancellation_winner,
        .work_cancellation_was_new = drain_receipt.cancellation_was_new,
    };
    if (state_before == .ready) {
        if (lifecycle.drain_opening_receipt != null)
            return LifecycleError.DrainSettlementMismatch;
        lifecycle.drain_opening_receipt = receipt;
    }
    return .{
        .active_was_present = active_was_present,
        .receipt = receipt,
    };
}

fn applyDrainWorkReceiptLockedV1(
    lifecycle: *ManagedLifecycleV1,
    receipt: prepared_http.DrainReceiptV1,
) LifecycleError!void {
    return applyDrainWorkReceiptWithPolicyLockedV1(
        lifecycle,
        receipt,
        .cancel_active,
    );
}

fn applyDrainWorkReceiptWithPolicyLockedV1(
    lifecycle: *ManagedLifecycleV1,
    receipt: prepared_http.DrainReceiptV1,
    policy: ManagedDrainPolicyV1,
) LifecycleError!void {
    const work_identity = receipt.active_work orelse {
        if (receipt.transport_owner != null)
            return LifecycleError.TransportOwnerMismatch;
        return;
    };
    const lease = try lifecycle.leaseForDrainReceiptLockedV1(
        receipt.transport_owner,
    );
    const active = try lifecycle.bindActiveWorkLockedV1(
        lease,
        work_identity,
    );
    if (receipt.cancellation == .recovery_required)
        return LifecycleError.WorkCancellationRecoveryRequired;
    try retainWorkStopReceiptOnActiveV1(
        active,
        receipt.cancellation,
        receipt.cancellation_winner,
    );
    active.preexisting_work_stop_selected =
        active.preexisting_work_stop_selected or
        drainReceiptSelectsPreexistingWorkStopV1(receipt);
    active.finish_published_selected =
        policy == .finish_published and
        (receipt.cancellation == .none or
            receipt.cancellation == .already_terminal);
    if (receipt.cancellation_was_new and
        receipt.cancellation_winner == .drain)
    {
        try lifecycle.recordDrainWorkCancellationLockedV1(
            lease,
            work_identity,
        );
    }
}

fn drainReceiptSelectsPreexistingWorkStopV1(
    receipt: prepared_http.DrainReceiptV1,
) bool {
    if (receipt.cancellation_was_new and
        receipt.cancellation_winner == .drain)
    {
        return false;
    }
    return switch (receipt.cancellation) {
        .cancelled,
        .already_cancelled,
        .start_rolled_back,
        => true,
        .none,
        .already_terminal,
        .recovery_required,
        => false,
    };
}

fn retainWorkStopReceiptOnActiveV1(
    active: *ActiveConnectionV1,
    outcome: prepared_http.DrainCancellationOutcomeV1,
    winner: ?prepared_http.WorkCancellationCauseV1,
) LifecycleError!void {
    const selects_stop = switch (outcome) {
        .cancelled,
        .already_cancelled,
        .start_rolled_back,
        => true,
        .none,
        .already_terminal,
        .recovery_required,
        => false,
    };
    if (!selects_stop) return;
    if (active.work_stop_outcome == .none) {
        active.work_stop_outcome = outcome;
        active.work_stop_winner = winner;
        return;
    }
    if (active.work_stop_outcome != outcome or
        active.work_stop_winner != winner)
    {
        return LifecycleError.DrainSettlementMismatch;
    }
}

/// Returns current aggregate progress for a managed drain receipt.
///
/// `settled` requires lifecycle convergence to `stopped` or `failed`; zero
/// active connections while the listener is still draining is not final.
pub fn inspectManagedDrainV1(
    lifecycle: *ManagedLifecycleV1,
    receipt: *const ManagedDrainInitiationReceiptV1,
) LifecycleError!ManagedDrainInspectionV1 {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    return inspectManagedDrainLockedV1(lifecycle, receipt);
}

fn inspectManagedDrainLockedV1(
    lifecycle: *ManagedLifecycleV1,
    receipt: *const ManagedDrainInitiationReceiptV1,
) LifecycleError!ManagedDrainInspectionV1 {
    try validateManagedDrainReceiptShapeV1(receipt);
    if (receipt.process_generation != lifecycle.process_generation)
        return LifecycleError.InvalidGeneration;
    if (receipt.accepted_connections !=
        lifecycle.accepted_connections or
        receipt.completed_connections >
            lifecycle.completed_connections or
        receipt.failed_connections > lifecycle.failed_connections)
    {
        return LifecycleError.DrainReceiptMismatch;
    }
    const snapshot = lifecycle.snapshotLockedV1();
    return .{
        .process_generation = lifecycle.process_generation,
        .effective_policy = lifecycle.effective_drain_policy orelse
            receipt.effective_policy,
        .state = lifecycle.state,
        .completed_since_linearization = lifecycle.completed_connections -
            receipt.completed_connections,
        .failed_since_linearization = lifecycle.failed_connections -
            receipt.failed_connections,
        .active_connections = lifecycle.active_connections,
        .queued_connections = snapshot.queued_connections,
        .settled = lifecycle.active_connections == 0 and
            (lifecycle.state == .stopped or
                lifecycle.state == .failed),
    };
}

/// Opens the retained per-connection cohort for the first drain receipt.
///
/// Repeated or escalation receipts cannot replace the original counter
/// baselines. The returned source value is unkeyed correlation evidence.
pub fn openManagedDrainSettlementSessionV1(
    lifecycle: *ManagedLifecycleV1,
    receipt: *const ManagedDrainInitiationReceiptV1,
) LifecycleError!ManagedDrainSettlementSessionV1 {
    try validateManagedDrainReceiptShapeV1(receipt);
    if (!receipt.drain_was_new or
        receipt.state_before != .ready or
        receipt.state_at_linearization != .draining)
    {
        return LifecycleError.DrainSettlementMismatch;
    }
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    if (receipt.process_generation != lifecycle.process_generation)
        return LifecycleError.InvalidGeneration;
    const session = lifecycle.drain_settlement_session orelse
        return LifecycleError.DrainSettlementUnavailable;
    const opening_receipt = lifecycle.drain_opening_receipt orelse
        return LifecycleError.DrainSettlementUnavailable;
    if (!std.meta.eql(opening_receipt, receipt.*))
        return LifecycleError.DrainSettlementMismatch;
    if (session.accepted_connections !=
        receipt.accepted_connections or
        session.completed_connections !=
            receipt.completed_connections or
        session.failed_connections != receipt.failed_connections or
        @as(u16, session.cohort_connections) !=
            managedDrainPhaseTotalV1(receipt.phase_counts) or
        session.initial_effective_policy !=
            receipt.effective_policy)
    {
        return LifecycleError.DrainSettlementMismatch;
    }
    return session;
}

pub fn inspectManagedDrainSettlementsV1(
    lifecycle: *ManagedLifecycleV1,
    session: *const ManagedDrainSettlementSessionV1,
) LifecycleError!ManagedDrainSettlementsInspectionV1 {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    return lifecycle.inspectDrainSettlementsLockedV1(session);
}

pub fn inspectManagedDrainConnectionAtV1(
    lifecycle: *ManagedLifecycleV1,
    session: *const ManagedDrainSettlementSessionV1,
    member_index: u8,
) LifecycleError!ManagedDrainConnectionInspectionV1 {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    _ = try lifecycle.inspectDrainSettlementsLockedV1(session);
    if (member_index >= session.cohort_connections)
        return LifecycleError.DrainSettlementMemberOutOfRange;
    for (
        lifecycle.connection_slots[0..lifecycle.connection_capacity],
    ) |slot| {
        const member = slot.drain_member orelse continue;
        if (member.selection.member_index != member_index)
            continue;
        return .{
            .selection = member.selection,
            .retirement_state = if (member.settlement != null)
                .settled
            else if (member.logical != null)
                .transport_closing
            else
                .active,
            .settlement = member.settlement,
        };
    }
    return LifecycleError.DrainSettlementMismatch;
}

pub fn inspectManagedDrainConnectionByOwnerV1(
    lifecycle: *ManagedLifecycleV1,
    session: *const ManagedDrainSettlementSessionV1,
    owner: prepared_http.TransportOwnerTokenV1,
) LifecycleError!ManagedDrainConnectionInspectionV1 {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    _ = try lifecycle.inspectDrainSettlementsLockedV1(session);
    for (
        lifecycle.connection_slots[0..lifecycle.connection_capacity],
    ) |slot| {
        const member = slot.drain_member orelse continue;
        if (!std.meta.eql(member.selection.owner, owner))
            continue;
        return .{
            .selection = member.selection,
            .retirement_state = if (member.settlement != null)
                .settled
            else if (member.logical != null)
                .transport_closing
            else
                .active,
            .settlement = member.settlement,
        };
    }
    return LifecycleError.DrainSettlementMismatch;
}

const ManagedDeadlineAuthorityV1 = enum {
    per_connection,
    shared_watchdog,
};

const ManagedConcurrentThreadContextV1 = struct {
    lifecycle: *ManagedConcurrentLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    config: ServerConfig,
    work_observer: ?prepared_http.RequestWorkControlV1 = null,
    worker_index: u8 = 0,
};

pub fn serveManagedConcurrentListenerV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedConcurrentLifecycleV1,
) !void {
    return serveManagedConcurrentListenerWithControlsV1(
        listener,
        config,
        runtime,
        lifecycle,
        .{},
    );
}

pub fn serveManagedConcurrentListenerWithObserverV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedConcurrentLifecycleV1,
    observer: ?ManagedConcurrentObserverV1,
) !void {
    return serveManagedConcurrentListenerWithControlsV1(
        listener,
        config,
        runtime,
        lifecycle,
        .{ .event_observer = observer },
    );
}

/// Serves accepted loopback connections through one bounded FIFO and a fixed
/// worker pool. Backpressure is passive: when the accepted FIFO is full the
/// acceptor waits, leaving additional peers in the kernel listen backlog.
///
/// The event observer is evidence-only. Its callback runs outside every
/// lifecycle, runtime, service, and socket-control mutex and cannot change a
/// production winner. Event callbacks may be concurrent and delivered out of
/// ordinal order, so their context must be thread-safe. Work callbacks run
/// only inside the runtime's serialized request section; they are controls and
/// may block, fail, or change a request outcome. All caller-owned callback
/// contexts must remain alive until this call returns after every worker and
/// the watchdog join.
pub fn serveManagedConcurrentListenerWithControlsV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedConcurrentLifecycleV1,
    controls: ManagedConcurrentControlsV1,
) !void {
    try validateConfig(config);
    try validateManagedConcurrentConfigV1(lifecycle.config);
    if (config.stop_after_requests != null)
        return Error.ConcurrentStopAfterRequestsUnsupported;
    if (!isLoopbackAddress(listener.listen_address))
        return Error.NonLoopbackBind;

    const expected_connection_capacity: u8 = @intCast(
        @as(u16, lifecycle.config.worker_count) +
            @as(
                u16,
                lifecycle.config.pending_connection_capacity,
            ),
    );
    lifecycle.managed.mutex.lock();
    if (lifecycle.managed.connection_capacity !=
        expected_connection_capacity)
    {
        lifecycle.managed.mutex.unlock();
        return Error.ConcurrentLifecycleConfigurationMismatch;
    }
    if (lifecycle.managed.state != .ready or
        lifecycle.serving)
    {
        lifecycle.managed.mutex.unlock();
        return LifecycleError.InvalidTransition;
    }
    lifecycle.serving = true;
    lifecycle.observer = controls.event_observer;
    lifecycle.managed.mutex.unlock();

    const listener_mode =
        ManagedConcurrentListenerModeV1.enable(
            listener.stream.handle,
        ) catch |err| {
            lifecycle.managed.mutex.lock();
            lifecycle.serving = false;
            lifecycle.observer = null;
            lifecycle.managed.mutex.unlock();
            return err;
        };
    var listener_mode_active = true;
    defer std.debug.assert(!listener_mode_active);

    var worker_contexts: [maximum_managed_concurrent_workers_v1]ManagedConcurrentThreadContextV1 = undefined;
    var worker_threads: [maximum_managed_concurrent_workers_v1]?std.Thread =
        [_]?std.Thread{null} **
        maximum_managed_concurrent_workers_v1;
    var worker_count: u8 = 0;
    var startup_error: ?anyerror = null;
    while (worker_count < lifecycle.config.worker_count) : (worker_count += 1) {
        worker_contexts[worker_count] = .{
            .lifecycle = lifecycle,
            .runtime = runtime,
            .config = config,
            .work_observer = controls.work_control,
            .worker_index = worker_count,
        };
        worker_threads[worker_count] = std.Thread.spawn(
            .{},
            managedConcurrentWorkerThreadV1,
            .{&worker_contexts[worker_count]},
        ) catch |err| {
            startup_error = err;
            break;
        };
    }

    var watchdog_context: ManagedConcurrentThreadContextV1 = .{
        .lifecycle = lifecycle,
        .runtime = runtime,
        .config = config,
    };
    var watchdog_thread: ?std.Thread = null;
    if (startup_error == null) {
        watchdog_thread = std.Thread.spawn(
            .{},
            managedConcurrentWatchdogThreadV1,
            .{&watchdog_context},
        ) catch |err| blk: {
            startup_error = err;
            break :blk null;
        };
    }

    if (startup_error) |err| {
        failManagedConcurrentV1(
            lifecycle,
            runtime,
            err,
        );
    } else {
        managedConcurrentAcceptLoopV1(
            listener,
            config,
            runtime,
            lifecycle,
        ) catch |err| {
            failManagedConcurrentV1(
                lifecycle,
                runtime,
                err,
            );
        };
    }

    var join_index: usize = 0;
    while (join_index < worker_count) : (join_index += 1) {
        if (worker_threads[join_index]) |thread|
            thread.join();
    }
    if (watchdog_thread) |thread| thread.join();

    var listener_restore_error: ?anyerror = null;
    listener_mode.restore(
        listener.stream.handle,
    ) catch |err| {
        listener_restore_error = err;
    };
    listener_mode_active = false;

    var final_cleanup_batch: ManagedConcurrentDetachedBatchV1 = .{};
    lifecycle.managed.mutex.lock();
    while (lifecycle.detached_close_in_flight != 0) {
        lifecycle.settled.wait(
            &lifecycle.managed.mutex,
        );
    }
    if (listener_restore_error) |err| {
        lifecycle.recordCleanupErrorLockedV1(err);
        lifecycle.recordFatalLockedV1(err);
    }
    if (lifecycle.managed.state == .draining) {
        if (lifecycle.queue_len != 0 or
            lifecycle.managed.active_connections != 0)
        {
            lifecycle.recordFatalLockedV1(
                LifecycleError.InvalidTransition,
            );
        } else {
            var settlement_ready = true;
            if (lifecycle.managed.drain_settlement_session) |*session| {
                const settlement = lifecycle.managed
                    .inspectDrainSettlementsLockedV1(
                    session,
                ) catch |err| blk: {
                    lifecycle.recordCleanupErrorLockedV1(err);
                    break :blk null;
                };
                if (settlement) |inspection| {
                    settlement_ready =
                        inspection.active_connections == 0 and
                        inspection
                            .transport_closing_connections == 0 and
                        inspection.settled_connections ==
                            inspection.cohort_connections;
                } else {
                    settlement_ready = false;
                }
            }
            if (settlement_ready) {
                lifecycle.managed.state = .stopped;
            } else {
                lifecycle.recordFatalLockedV1(
                    LifecycleError.DrainSettlementMismatch,
                );
            }
        }
    } else if (lifecycle.managed.state == .ready) {
        lifecycle.recordFatalLockedV1(
            LifecycleError.InvalidTransition,
        );
    }
    if (lifecycle.managed.state == .failed and
        (lifecycle.queue_len != 0 or
            lifecycle.managed.active_connections != 0))
    {
        lifecycle.forceConvergeAfterJoinLockedV1(
            &final_cleanup_batch,
        ) catch |err| {
            lifecycle.recordCleanupErrorLockedV1(err);
        };
    }
    if (lifecycle.queue_len != 0 or
        lifecycle.managed.active_connections != 0 or
        lifecycle.managed.hasOccupiedConnectionSlotLockedV1())
    {
        lifecycle.recordCleanupErrorLockedV1(
            LifecycleError.InvalidTransition,
        );
    }
    while (lifecycle.observer_in_flight != 0) {
        lifecycle.settled.wait(
            &lifecycle.managed.mutex,
        );
    }
    const fatal_error = lifecycle.fatal_error;
    lifecycle.serving = false;
    lifecycle.observer = null;
    lifecycle.accept_paused = false;
    lifecycle.settled.broadcast();
    lifecycle.managed.mutex.unlock();
    try final_cleanup_batch.release(lifecycle);

    if (fatal_error) |err| return err;
    if (lifecycle.snapshotV1().managed.state != .stopped)
        return LifecycleError.InvalidTransition;
}

/// Keeps listener shutdown bounded without an auxiliary wake connection. The
/// listener is temporarily nonblocking, and the single acceptor polls in a
/// bounded quantum before rechecking lifecycle state.
fn waitForManagedConcurrentAcceptV1(
    listener: *std.net.Server,
    lifecycle: *ManagedConcurrentLifecycleV1,
) !bool {
    return waitForManagedConcurrentAcceptWithBarrierV1(
        listener,
        lifecycle,
        null,
    );
}

fn waitForManagedConcurrentAcceptWithBarrierV1(
    listener: *std.net.Server,
    lifecycle: *ManagedConcurrentLifecycleV1,
    wait_entered: ?*std.Thread.ResetEvent,
) !bool {
    while (true) {
        lifecycle.managed.mutex.lock();
        const ready_before_wait =
            lifecycle.managed.state == .ready;
        lifecycle.managed.mutex.unlock();
        if (!ready_before_wait) return false;

        if (wait_entered) |entered| entered.set();
        if (!try ManagedDeadlineReaderV1.pollReadableOnceV1(
            listener.stream.handle,
            managed_lifecycle_poll_interval_ms,
        )) {
            continue;
        }

        lifecycle.managed.mutex.lock();
        const ready_after_wait =
            lifecycle.managed.state == .ready;
        lifecycle.managed.mutex.unlock();
        return ready_after_wait;
    }
}

fn managedConcurrentAcceptLoopV1(
    listener: *std.net.Server,
    config: ServerConfig,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedConcurrentLifecycleV1,
) !void {
    _ = runtime;
    while (true) {
        var pause_event: ?ManagedConcurrentPendingEventV1 = null;
        lifecycle.managed.mutex.lock();
        if (lifecycle.managed.state != .ready) {
            lifecycle.managed.mutex.unlock();
            return;
        }
        if (lifecycle.queue_len >=
            lifecycle.config.pending_connection_capacity)
        {
            if (!lifecycle.accept_paused) {
                const next_activations = std.math.add(
                    u64,
                    lifecycle.listener_backpressure_activations,
                    1,
                ) catch {
                    lifecycle.managed.mutex.unlock();
                    return LifecycleError.CounterOverflow;
                };
                const next_ordinal = std.math.add(
                    u64,
                    lifecycle.event_ordinal,
                    1,
                ) catch {
                    lifecycle.managed.mutex.unlock();
                    return LifecycleError.CounterOverflow;
                };
                lifecycle.accept_paused = true;
                lifecycle.listener_backpressure_activations =
                    next_activations;
                lifecycle.event_ordinal = next_ordinal;
                pause_event =
                    lifecycle.captureEventLockedV1(.{
                        .ordinal = next_ordinal,
                        .kind = .backpressure_paused,
                        .queued_connections = lifecycle.queue_len,
                        .running_connections = lifecycle
                            .runningConnectionsLockedV1(),
                    });
            }
            lifecycle.managed.mutex.unlock();
            if (pause_event) |pending| pending.emit();

            lifecycle.managed.mutex.lock();
            while (lifecycle.managed.state == .ready and
                lifecycle.queue_len >=
                    lifecycle
                        .config.pending_connection_capacity)
            {
                lifecycle.queue_capacity_available.wait(
                    &lifecycle.managed.mutex,
                );
            }
            lifecycle.managed.mutex.unlock();
            continue;
        }
        lifecycle.managed.mutex.unlock();

        if (!try waitForManagedConcurrentAcceptV1(
            listener,
            lifecycle,
        )) return;
        const connection = listener.accept() catch |err| {
            switch (err) {
                error.WouldBlock,
                error.ConnectionAborted,
                error.ConnectionResetByPeer,
                error.ProtocolFailure,
                => continue,
                else => {},
            }
            lifecycle.managed.mutex.lock();
            const still_ready =
                lifecycle.managed.state == .ready;
            lifecycle.managed.mutex.unlock();
            if (!still_ready) return;
            return err;
        };

        // Start the shared accept-origin budget before any socket
        // normalization so scheduler or fcntl delay cannot extend it.
        const accept_timer =
            if (config.receive_timeout_ns == 0 and
            config.full_request_timeout_ns == 0)
                null
            else
                std.time.Timer.start() catch |err| {
                    var failed_connection = connection;
                    failed_connection.stream.close();
                    lifecycle.managed.mutex.lock();
                    const still_ready =
                        lifecycle.managed.state == .ready;
                    lifecycle.managed.mutex.unlock();
                    if (!still_ready) return;
                    return err;
                };
        setAcceptedSocketBlockingV1(
            connection.stream.handle,
        ) catch |err| {
            var failed_connection = connection;
            failed_connection.stream.close();
            return err;
        };

        lifecycle.managed.mutex.lock();
        const should_accept =
            lifecycle.managed.state == .ready;
        lifecycle.managed.mutex.unlock();
        if (!should_accept) {
            var wake_connection = connection;
            wake_connection.stream.close();
            return;
        }

        var enqueued = false;
        var enqueue_error: ?anyerror = null;
        var enqueued_event: ?ManagedConcurrentPendingEventV1 = null;
        lifecycle.managed.mutex.lock();
        if (lifecycle.managed.state == .ready) {
            const next_enqueued = std.math.add(
                u64,
                lifecycle.queue_enqueued_connections,
                1,
            ) catch |err| blk: {
                enqueue_error = err;
                break :blk 0;
            };
            const next_ordinal = std.math.add(
                u64,
                lifecycle.event_ordinal,
                1,
            ) catch |err| blk: {
                enqueue_error = err;
                break :blk 0;
            };
            if (enqueue_error == null) {
                const lease =
                    lifecycle.managed
                        .beginConnectionInPhaseLockedV1(
                        connection.stream.handle,
                        config.receive_timeout_ns,
                        config.full_request_timeout_ns,
                        accept_timer,
                        .queued,
                    ) catch |err| blk: {
                        enqueue_error = err;
                        break :blk null;
                    };
                if (lease) |accepted_lease| {
                    lifecycle.queue[lifecycle.queue_len] = .{
                        .connection = connection,
                        .lease = accepted_lease,
                    };
                    lifecycle.queue_len += 1;
                    lifecycle.queue_enqueued_connections =
                        next_enqueued;
                    lifecycle.queue_high_watermark = @max(
                        lifecycle.queue_high_watermark,
                        lifecycle.queue_len,
                    );
                    lifecycle.event_ordinal = next_ordinal;
                    enqueued_event =
                        lifecycle.captureEventLockedV1(.{
                            .ordinal = next_ordinal,
                            .kind = .enqueued,
                            .lease = accepted_lease,
                            .queued_connections = lifecycle.queue_len,
                            .running_connections = lifecycle
                                .runningConnectionsLockedV1(),
                        });
                    enqueued = true;
                    lifecycle.work_available.signal();
                    lifecycle.deadline_changed.broadcast();
                }
            }
        }
        lifecycle.managed.mutex.unlock();

        if (!enqueued) {
            var unowned_connection = connection;
            unowned_connection.stream.close();
        }
        if (enqueue_error) |err| return err;
        if (enqueued_event) |pending| pending.emit();
        if (!enqueued) return;
    }
}

fn managedConcurrentWorkerThreadV1(
    context: *ManagedConcurrentThreadContextV1,
) void {
    managedConcurrentWorkerLoopV1(context) catch |err| {
        failManagedConcurrentV1(
            context.lifecycle,
            context.runtime,
            err,
        );
    };
}

fn managedConcurrentWorkerLoopV1(
    context: *ManagedConcurrentThreadContextV1,
) !void {
    const lifecycle = context.lifecycle;
    while (true) {
        var dispatch_events: ManagedConcurrentDetachedBatchV1 = .{};
        lifecycle.managed.mutex.lock();
        while (lifecycle.managed.state == .ready and
            lifecycle.queue_len == 0)
        {
            lifecycle.work_available.wait(
                &lifecycle.managed.mutex,
            );
        }
        if (lifecycle.managed.state != .ready) {
            lifecycle.managed.mutex.unlock();
            return;
        }
        const dispatched =
            lifecycle.popForWorkerLockedV1(
                context.worker_index,
                &dispatch_events,
            ) catch |err| {
                lifecycle.managed.mutex.unlock();
                dispatch_events.release(
                    lifecycle,
                ) catch |release_error| {
                    return release_error;
                };
                return err;
            };
        lifecycle.managed.mutex.unlock();
        try dispatch_events.release(lifecycle);

        const receive_timer =
            if (context.config.receive_timeout_ns == 0)
                null
            else
                dispatched.accept_timer;
        const full_request_timer =
            if (context.config.full_request_timeout_ns == 0)
                null
            else
                dispatched.accept_timer;
        var connection_error: ?anyerror = null;
        const connection_succeeded = serveManagedConnectionV1(
            dispatched.queued.connection,
            context.runtime,
            &lifecycle.managed,
            dispatched.queued.lease,
            context.config.receive_timeout_ns,
            context.config.full_request_timeout_ns,
            context.config.peer_reset_poll_timeout_ns,
            context.config.peer_send_close_policy,
            context.config.response_write_quantum_bytes,
            receive_timer,
            full_request_timer,
            context.work_observer,
            null,
            .shared_watchdog,
        ) catch |err| blk: {
            connection_error = err;
            break :blk false;
        };
        _ = connection_succeeded;

        lifecycle.managed.mutex.lock();
        if (connection_error != null) {
            lifecycle.managed
                .forceFinishConnectionLockedV1(
                dispatched.queued.lease,
            ) catch |err| switch (err) {
                LifecycleError.NoActiveConnection,
                LifecycleError.ConnectionSlotGenerationMismatch,
                => {},
                else => {
                    lifecycle.recordCleanupErrorLockedV1(err);
                },
            };
        }
        _ = lifecycle.managed.confirmTransportClosedLockedV1(
            dispatched.queued.lease,
            .owner_confirmed,
        ) catch |err| blk: {
            if (connection_error == null)
                connection_error = err;
            lifecycle.recordCleanupErrorLockedV1(err);
            break :blk false;
        };
        const retired_event = lifecycle.makeEventLockedV1(
            .retired,
            dispatched.queued.lease,
            context.worker_index,
        ) catch |err| blk: {
            if (connection_error == null)
                connection_error = err;
            break :blk null;
        };
        lifecycle.deadline_changed.broadcast();
        lifecycle.queue_capacity_available.broadcast();
        lifecycle.settled.broadcast();
        lifecycle.managed.mutex.unlock();
        if (retired_event) |pending| pending.emit();
        if (connection_error) |err| return err;
    }
}

fn managedConcurrentWatchdogThreadV1(
    context: *ManagedConcurrentThreadContextV1,
) void {
    managedConcurrentWatchdogLoopV1(
        context.lifecycle,
    ) catch |err| {
        failManagedConcurrentV1(
            context.lifecycle,
            context.runtime,
            err,
        );
    };
}

fn managedConcurrentWatchdogLoopV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
) !void {
    while (true) {
        var timeout_batch: ManagedConcurrentDetachedBatchV1 = .{};
        lifecycle.managed.mutex.lock();
        const finish_drain_has_work =
            lifecycle.managed.state == .draining and
            lifecycle.managed.effective_drain_policy ==
                .finish_published and
            lifecycle.managed.active_connections != 0;
        if (lifecycle.managed.state != .ready and
            !finish_drain_has_work)
        {
            lifecycle.managed.mutex.unlock();
            return;
        }

        var expired_queue_index: ?usize = null;
        var queued_receive_wins = false;
        var queue_index: usize = 0;
        while (queue_index < lifecycle.queue_len) : (queue_index += 1) {
            const queued =
                lifecycle.queue[queue_index] orelse
                unreachable;
            const active = lifecycle.managed
                .activeConnectionForLeaseLockedV1(
                queued.lease,
            ) catch |err| {
                lifecycle.managed.mutex.unlock();
                return err;
            };
            if (active.phase != .queued) {
                lifecycle.managed.mutex.unlock();
                return LifecycleError.ConnectionPhaseMismatch;
            }
            if (queuedDeadlineExpiredV1(
                active,
                lifecycle.managed.state,
            )) |receive_wins| {
                expired_queue_index = queue_index;
                queued_receive_wins = receive_wins;
                break;
            }
        }
        if (expired_queue_index) |index| {
            lifecycle.expireQueuedAtLockedV1(
                index,
                queued_receive_wins,
                &timeout_batch,
            ) catch |err| {
                lifecycle.managed.mutex.unlock();
                timeout_batch.release(
                    lifecycle,
                ) catch |release_error| {
                    return release_error;
                };
                return err;
            };
            lifecycle.managed.mutex.unlock();
            try timeout_batch.release(lifecycle);
            continue;
        }

        var slot_index: usize = 0;
        while (slot_index < lifecycle.managed.connection_capacity) : (slot_index += 1) {
            const slot =
                &lifecycle.managed.connection_slots[slot_index];
            const active = if (slot.active) |*connection|
                connection
            else
                continue;
            if (active.phase == .queued) continue;
            const lease = lifecycle.managed
                .leaseForSlotLockedV1(slot_index) catch |err| {
                lifecycle.managed.mutex.unlock();
                return err;
            };
            if (receiveDeadlineExpiredForActiveV1(active)) {
                _ = lifecycle.managed
                    .signalActiveConnectionForReceiveTimeoutLockedV1(
                    lease,
                ) catch |err| {
                    lifecycle.managed.mutex.unlock();
                    return err;
                };
                continue;
            }
            if (fullRequestDeadlineExpiredForActiveV1(
                active,
                lifecycle.managed.state,
            )) {
                _ = lifecycle.managed
                    .claimFullRequestTimeoutLockedV1(lease) catch |err| {
                    lifecycle.managed.mutex.unlock();
                    return err;
                };
            }
        }

        var earliest_remaining_ns: ?u64 = null;
        for (
            lifecycle.managed
                .connection_slots[0..lifecycle.managed.connection_capacity],
        ) |*slot| {
            const active = if (slot.active) |*connection|
                connection
            else
                continue;
            if (remainingDeadlineNsV1(
                active,
                lifecycle.managed.state,
            )) |remaining_ns| {
                earliest_remaining_ns = if (earliest_remaining_ns) |current|
                    @min(current, remaining_ns)
                else
                    remaining_ns;
            }
        }

        if (earliest_remaining_ns) |remaining_ns| {
            if (remaining_ns == 0) {
                lifecycle.managed.mutex.unlock();
                continue;
            }
            lifecycle.deadline_changed.timedWait(
                &lifecycle.managed.mutex,
                remaining_ns,
            ) catch |err| switch (err) {
                error.Timeout => {},
            };
        } else {
            lifecycle.deadline_changed.wait(
                &lifecycle.managed.mutex,
            );
        }
        lifecycle.managed.mutex.unlock();
    }
}

fn queuedDeadlineExpiredV1(
    active: *ActiveConnectionV1,
    state: ManagedStateV1,
) ?bool {
    if (receiveDeadlineExpiredForActiveV1(active))
        return true;
    if (fullRequestDeadlineExpiredForActiveV1(active, state))
        return false;
    return null;
}

fn receiveDeadlineExpiredForActiveV1(
    active: *ActiveConnectionV1,
) bool {
    if (active.receive_timeout_ns == 0 or
        active.receive_retired or
        active.receive_timeout_signaled or
        active.hard_stop_cause != null)
    {
        return false;
    }
    const timer = if (active.accept_timer) |*value|
        value
    else
        return false;
    return timer.read() >= active.receive_timeout_ns;
}

fn fullRequestDeadlineExpiredForActiveV1(
    active: *ActiveConnectionV1,
    state: ManagedStateV1,
) bool {
    if (!fullRequestDeadlineEligibleForActiveV1(active, state)) {
        return false;
    }
    const timer = if (active.accept_timer) |*value|
        value
    else
        return false;
    return timer.read() >= active.full_request_timeout_ns;
}

fn remainingDeadlineNsV1(
    active: *ActiveConnectionV1,
    state: ManagedStateV1,
) ?u64 {
    const timer = if (active.accept_timer) |*value|
        value
    else
        return null;
    const elapsed_ns = timer.read();
    var remaining_ns: ?u64 = null;
    if (active.receive_timeout_ns != 0 and
        !active.receive_retired and
        !active.receive_timeout_signaled and
        active.hard_stop_cause == null)
    {
        remaining_ns =
            active.receive_timeout_ns -
            @min(active.receive_timeout_ns, elapsed_ns);
    }
    if (fullRequestDeadlineEligibleForActiveV1(active, state)) {
        const full_remaining_ns =
            active.full_request_timeout_ns -
            @min(
                active.full_request_timeout_ns,
                elapsed_ns,
            );
        remaining_ns = if (remaining_ns) |current|
            @min(current, full_remaining_ns)
        else
            full_remaining_ns;
    }
    return remaining_ns;
}

fn fullRequestDeadlineEligibleForActiveV1(
    active: *const ActiveConnectionV1,
    state: ManagedStateV1,
) bool {
    if (active.full_request_timeout_ns == 0 or
        active.full_request_timeout_retired or
        active.full_request_timeout_signaled or
        active.response_retired or
        active.phase == .response_written or
        active.hard_stop_cause != null)
    {
        return false;
    }
    if (state != .draining) return true;
    return !(active.drain_signaled or
        active.failure_signaled or
        active.preexisting_work_stop_selected or
        active.drain_work_cancelled or
        active.failure_work_cancelled or
        active.peer_reset_work_cancelled or
        active.peer_send_close_work_cancelled or
        active.response_cancel_before_write_cause != null or
        std.meta.activeTag(
            active.response_write_stop_state,
        ) != .none or
        active.response_write_failure != null);
}

/// Closes runtime admission and applies the exact active-work receipt while
/// holding the lifecycle mutex. Runtime control never invokes a lifecycle
/// callback while held, so this follows the existing lifecycle -> runtime ->
/// service lock order and fences slot retirement across receipt capture.
fn beginManagedConcurrentDrainV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
) !void {
    _ = try beginManagedConcurrentDrainWithPolicyV1(
        lifecycle,
        runtime,
        .cancel_active,
    );
}

fn beginManagedConcurrentDrainWithPolicyV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    requested_policy: ManagedDrainPolicyV1,
) !ManagedDrainInitiationReceiptV1 {
    var detached_batch: ManagedConcurrentDetachedBatchV1 = .{};
    var drain_error: ?anyerror = null;
    var initiation_receipt: ?ManagedDrainInitiationReceiptV1 = null;

    lifecycle.managed.mutex.lock();
    const state_before = lifecycle.managed.state;
    switch (state_before) {
        .ready, .draining => {},
        .stopped => {
            const effective_policy =
                lifecycle.managed.effective_drain_policy orelse
                requested_policy;
            const admission_was_open =
                prepared_http.acceptingCompletionsV1(runtime);
            const receipt: ManagedDrainInitiationReceiptV1 = .{
                .process_generation = lifecycle.managed.process_generation,
                .requested_policy = requested_policy,
                .effective_policy = effective_policy,
                .drain_was_new = false,
                .connection_actions_applied = false,
                .admission_was_open = admission_was_open,
                .state_before = .stopped,
                .state_at_linearization = .stopped,
                .accepted_connections = lifecycle.managed.accepted_connections,
                .completed_connections = lifecycle.managed.completed_connections,
                .failed_connections = lifecycle.managed.failed_connections,
                .phase_counts = .{},
                .decisions = .{},
                .pending_settlement_connections = 0,
            };
            lifecycle.managed.mutex.unlock();
            return receipt;
        },
        else => {
            lifecycle.managed.mutex.unlock();
            return LifecycleError.InvalidTransition;
        },
    }
    lifecycle.managed
        .claimAllFullRequestTimeoutsIfExpiredLockedV1() catch |err| {
        convergeManagedConcurrentFailureLockedV1(
            lifecycle,
            null,
            err,
            err,
            &detached_batch,
        );
        lifecycle.managed.mutex.unlock();
        releaseManagedConcurrentFailureV1(
            lifecycle,
            &detached_batch,
        );
        return err;
    };
    const policy_resolution =
        lifecycle.managed.resolveDrainPolicyLockedV1(
            requested_policy,
        );
    const drain_receipt = switch (policy_resolution.effective_policy) {
        .cancel_active => prepared_http.beginDrainV1(runtime) catch |err| {
            convergeManagedConcurrentFailureLockedV1(
                lifecycle,
                null,
                err,
                err,
                &detached_batch,
            );
            lifecycle.managed.mutex.unlock();
            releaseManagedConcurrentFailureV1(
                lifecycle,
                &detached_batch,
            );
            return err;
        },
        .finish_published => prepared_http.beginDrainPreservingActiveV1(runtime),
    };
    applyConcurrentDrainWorkReceiptWithPolicyLockedV1(
        lifecycle,
        drain_receipt,
        policy_resolution.effective_policy,
    ) catch |err| {
        drain_error = err;
    };
    const phase_counts =
        lifecycle.managed.phaseCountsLockedV1();
    const decisions =
        lifecycle.managed.drainDecisionCountsLockedV1(
            policy_resolution.effective_policy,
            drain_receipt,
        );
    const accepted_connections =
        lifecycle.managed.accepted_connections;
    const completed_connections =
        lifecycle.managed.completed_connections;
    const failed_connections =
        lifecycle.managed.failed_connections;
    const queued_before = lifecycle.queue_len;
    if (drain_error == null) {
        if (state_before == .ready) {
            lifecycle.managed
                .captureDrainSettlementCohortLockedV1(
                policy_resolution.effective_policy,
                drain_receipt,
                phase_counts,
                decisions,
            ) catch |err| {
                drain_error = err;
            };
        } else if (policy_resolution.policy_was_escalated) {
            lifecycle.managed
                .reviseDrainSettlementCohortLockedV1(
                policy_resolution.effective_policy,
                drain_receipt,
            ) catch |err| {
                drain_error = err;
            };
        }
    }
    if (drain_error == null) {
        lifecycle.detachQueuedForStopLockedV1(
            .drain,
            &detached_batch,
        ) catch |err| {
            drain_error = err;
        };
    }
    if (drain_error == null) {
        _ = lifecycle.managed
            .signalActiveConnectionForDrainWithPolicyLockedV1(
            policy_resolution.effective_policy,
        ) catch |err| blk: {
            drain_error = err;
            break :blk false;
        };
    }
    lifecycle.accept_paused = false;
    if (drain_error) |err| {
        lifecycle.detachQueuedForStopLockedV1(
            .failure,
            &detached_batch,
        ) catch |cleanup_error| {
            lifecycle.recordCleanupErrorLockedV1(
                cleanup_error,
            );
        };
        lifecycle.signalRunningConnectionsForFailureLockedV1(
            &detached_batch,
        ) catch |cleanup_error| {
            lifecycle.recordCleanupErrorLockedV1(
                cleanup_error,
            );
        };
        lifecycle.recordFatalLockedV1(err);
    } else {
        lifecycle.managed.state = .draining;
        lifecycle.work_available.broadcast();
        lifecycle.queue_capacity_available.broadcast();
        lifecycle.deadline_changed.broadcast();
        lifecycle.settled.broadcast();
        const receipt: ManagedDrainInitiationReceiptV1 = .{
            .process_generation = lifecycle.managed.process_generation,
            .requested_policy = requested_policy,
            .effective_policy = policy_resolution.effective_policy,
            .drain_was_new = state_before == .ready,
            .policy_was_escalated = policy_resolution.policy_was_escalated,
            .connection_actions_applied = true,
            .admission_was_open = drain_receipt.admission_was_open,
            .state_before = state_before,
            .state_at_linearization = .draining,
            .accepted_connections = accepted_connections,
            .completed_connections = completed_connections,
            .failed_connections = failed_connections,
            .phase_counts = phase_counts,
            .decisions = decisions,
            .synchronously_retired_connections = queued_before - lifecycle.queue_len,
            .pending_settlement_connections = lifecycle.managed.active_connections,
            .active_work = drain_receipt.active_work,
            .active_work_owner = drain_receipt.transport_owner,
            .work_cancellation = drain_receipt.cancellation,
            .work_cancellation_winner = drain_receipt.cancellation_winner,
            .work_cancellation_was_new = drain_receipt.cancellation_was_new,
        };
        if (state_before == .ready and
            lifecycle.managed.drain_opening_receipt != null)
        {
            drain_error = LifecycleError.DrainSettlementMismatch;
            lifecycle.recordFatalLockedV1(
                LifecycleError.DrainSettlementMismatch,
            );
        } else {
            if (state_before == .ready)
                lifecycle.managed.drain_opening_receipt = receipt;
            initiation_receipt = receipt;
        }
    }
    lifecycle.managed.mutex.unlock();
    var close_error: ?anyerror = null;
    detached_batch.closeConnections(
        lifecycle,
    ) catch |err| {
        close_error = err;
    };
    detached_batch.emitEvents();
    if (drain_error) |err| return err;
    if (close_error) |err| return err;
    return initiation_receipt.?;
}

fn applyConcurrentDrainWorkReceiptLockedV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    receipt: prepared_http.DrainReceiptV1,
) LifecycleError!void {
    return applyConcurrentDrainWorkReceiptWithPolicyLockedV1(
        lifecycle,
        receipt,
        .cancel_active,
    );
}

fn applyConcurrentDrainWorkReceiptWithPolicyLockedV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    receipt: prepared_http.DrainReceiptV1,
    policy: ManagedDrainPolicyV1,
) LifecycleError!void {
    if (receipt.active_work == null) {
        if (receipt.transport_owner != null)
            return LifecycleError.TransportOwnerMismatch;
        return;
    }
    const owner = receipt.transport_owner orelse
        return LifecycleError.MissingTransportOwner;
    _ = try lifecycle.managed
        .leaseForTransportOwnerLockedV1(owner);
    return applyDrainWorkReceiptWithPolicyLockedV1(
        &lifecycle.managed,
        receipt,
        policy,
    );
}

fn applyConcurrentFailureWorkReceiptLockedV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    receipt: prepared_http.DrainReceiptV1,
) LifecycleError!void {
    const work_identity = receipt.active_work orelse {
        if (receipt.transport_owner != null)
            return LifecycleError.TransportOwnerMismatch;
        return;
    };
    const owner = receipt.transport_owner orelse
        return LifecycleError.MissingTransportOwner;
    const lease = try lifecycle.managed
        .leaseForTransportOwnerLockedV1(owner);
    const active = try lifecycle.managed.bindActiveWorkLockedV1(
        lease,
        work_identity,
    );
    if (receipt.cancellation == .recovery_required)
        return LifecycleError.WorkCancellationRecoveryRequired;
    try retainWorkStopReceiptOnActiveV1(
        active,
        receipt.cancellation,
        receipt.cancellation_winner,
    );
    if (receipt.cancellation_was_new and
        receipt.cancellation_winner == .transport_failure)
    {
        try lifecycle.managed
            .recordFailureWorkCancellationLockedV1(
            lease,
            work_identity,
        );
    }
}

pub fn requestManagedConcurrentDrainAndWakeV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    listen_address: std.net.Address,
) !void {
    _ = try requestManagedConcurrentDrainAndWakeWithPolicyV1(
        lifecycle,
        runtime,
        listen_address,
        .cancel_active,
    );
}

/// Initiates concurrent managed drain with an explicit monotonic policy.
pub fn requestManagedConcurrentDrainAndWakeWithPolicyV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    listen_address: std.net.Address,
    policy: ManagedDrainPolicyV1,
) !ManagedDrainInitiationReceiptV1 {
    if (!isLoopbackAddress(listen_address))
        return Error.NonLoopbackBind;
    return beginManagedConcurrentDrainWithPolicyV1(
        lifecycle,
        runtime,
        policy,
    );
}

pub fn inspectManagedConcurrentDrainV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    receipt: *const ManagedDrainInitiationReceiptV1,
) LifecycleError!ManagedDrainInspectionV1 {
    return inspectManagedDrainV1(&lifecycle.managed, receipt);
}

pub fn openManagedConcurrentDrainSettlementSessionV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    receipt: *const ManagedDrainInitiationReceiptV1,
) LifecycleError!ManagedDrainSettlementSessionV1 {
    return openManagedDrainSettlementSessionV1(
        &lifecycle.managed,
        receipt,
    );
}

pub fn inspectManagedConcurrentDrainSettlementsV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    session: *const ManagedDrainSettlementSessionV1,
) LifecycleError!ManagedDrainSettlementsInspectionV1 {
    return inspectManagedDrainSettlementsV1(
        &lifecycle.managed,
        session,
    );
}

pub fn inspectManagedConcurrentDrainConnectionAtV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    session: *const ManagedDrainSettlementSessionV1,
    member_index: u8,
) LifecycleError!ManagedDrainConnectionInspectionV1 {
    return inspectManagedDrainConnectionAtV1(
        &lifecycle.managed,
        session,
        member_index,
    );
}

pub fn inspectManagedConcurrentDrainConnectionByOwnerV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    session: *const ManagedDrainSettlementSessionV1,
    owner: prepared_http.TransportOwnerTokenV1,
) LifecycleError!ManagedDrainConnectionInspectionV1 {
    return inspectManagedDrainConnectionByOwnerV1(
        &lifecycle.managed,
        session,
        owner,
    );
}

fn failManagedConcurrentV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
    fatal_error: anyerror,
) void {
    var detached_batch: ManagedConcurrentDetachedBatchV1 = .{};
    lifecycle.managed.mutex.lock();
    var runtime_stop_error: ?anyerror = null;
    const receipt = prepared_http.beginTransportFailureV1(
        runtime,
    ) catch |err| blk: {
        runtime_stop_error = err;
        break :blk null;
    };
    convergeManagedConcurrentFailureLockedV1(
        lifecycle,
        receipt,
        fatal_error,
        runtime_stop_error,
        &detached_batch,
    );
    lifecycle.managed.mutex.unlock();
    releaseManagedConcurrentFailureV1(
        lifecycle,
        &detached_batch,
    );
}

fn convergeManagedConcurrentFailureLockedV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    receipt: ?prepared_http.DrainReceiptV1,
    fatal_error: anyerror,
    cleanup_error: ?anyerror,
    detached_batch: *ManagedConcurrentDetachedBatchV1,
) void {
    if (lifecycle.fatal_error == null)
        lifecycle.fatal_error = fatal_error;
    if (cleanup_error) |err|
        lifecycle.recordCleanupErrorLockedV1(err);
    if (receipt) |failure_receipt| {
        applyConcurrentFailureWorkReceiptLockedV1(
            lifecycle,
            failure_receipt,
        ) catch |err| {
            lifecycle.recordCleanupErrorLockedV1(err);
        };
    }
    lifecycle.detachQueuedForStopLockedV1(
        .failure,
        detached_batch,
    ) catch |err| {
        lifecycle.recordCleanupErrorLockedV1(err);
    };
    lifecycle.signalRunningConnectionsForFailureLockedV1(
        detached_batch,
    ) catch |err| {
        lifecycle.recordCleanupErrorLockedV1(err);
    };
    lifecycle.recordFatalLockedV1(fatal_error);
}

fn releaseManagedConcurrentFailureV1(
    lifecycle: *ManagedConcurrentLifecycleV1,
    detached_batch: *ManagedConcurrentDetachedBatchV1,
) void {
    detached_batch.closeConnections(
        lifecycle,
    ) catch |err| {
        lifecycle.managed.mutex.lock();
        lifecycle.recordCleanupErrorLockedV1(err);
        lifecycle.managed.mutex.unlock();
    };
    detached_batch.emitEvents();
}

pub fn serveConnectionV1(
    connection: std.net.Server.Connection,
    runtime: *prepared_http.RuntimeV1,
) !void {
    var owned_connection = connection;
    defer owned_connection.stream.close();
    try serveOpenConnectionV1(
        &owned_connection.stream,
        runtime,
        null,
        null,
        null,
    );
}

const ManagedReceiveTimeoutV1 = struct {
    lifecycle: *ManagedLifecycleV1,
    lease: ManagedConnectionLeaseV1,
    timeout_ns: u64,
    full_request_timeout_ns: u64,
    decision_timer: ?std.time.Timer,
    wait_timer: ?std.time.Timer,
    receive_stopped: std.Thread.ResetEvent = .{},
    signaled: bool = false,
    signal_error: ?anyerror = null,
    peer_send_close_error: ?anyerror = null,

    fn run(self: *ManagedReceiveTimeoutV1) void {
        var timer = self.wait_timer orelse unreachable;
        const elapsed_ns = timer.read();
        if (elapsed_ns >= self.timeout_ns) {
            self.signal();
            return;
        }
        self.receive_stopped.timedWait(
            self.timeout_ns - elapsed_ns,
        ) catch |err| switch (err) {
            error.Timeout => self.signal(),
        };
    }

    fn signal(self: *ManagedReceiveTimeoutV1) void {
        self.signaled =
            self.lifecycle
                .signalActiveConnectionForReceiveTimeoutV1(
                self.lease,
            ) catch |signal_error| {
                self.signal_error = signal_error;
                return;
            };
    }

    fn completeOpaque(context: *anyopaque) anyerror!void {
        const self: *ManagedReceiveTimeoutV1 =
            @ptrCast(@alignCast(context));
        defer self.receive_stopped.set();
        try self.lifecycle.markRequestReceivedBeforeDeadlineV1(
            self.lease,
            self.timerPointer(),
            self.timeout_ns,
        );
    }

    fn stopOpaque(context: *anyopaque) anyerror!bool {
        const self: *ManagedReceiveTimeoutV1 =
            @ptrCast(@alignCast(context));
        return self.stop();
    }

    fn stop(self: *ManagedReceiveTimeoutV1) !bool {
        defer self.receive_stopped.set();
        return self.lifecycle.retireActiveConnectionReceiveV1(
            self.lease,
            self.timerPointer(),
            self.timeout_ns,
        );
    }

    fn markHeadReceived(self: *ManagedReceiveTimeoutV1) !void {
        try self.lifecycle.markRequestHeadReceivedBeforeDeadlineV1(
            self.lease,
            self.timerPointer(),
            self.timeout_ns,
        );
    }

    fn interrupted(self: *ManagedReceiveTimeoutV1) bool {
        self.lifecycle.mutex.lock();
        defer self.lifecycle.mutex.unlock();
        const active = self.lifecycle
            .activeConnectionForLeaseLockedV1(
            self.lease,
        ) catch return true;
        return self.lifecycle.state != .ready or
            active.receive_retired or
            active.drain_signaled or
            active.failure_signaled or
            active.receive_timeout_signaled or
            active.full_request_timeout_signaled or
            active.hard_stop_cause != null;
    }

    fn timerPointer(self: *ManagedReceiveTimeoutV1) ?*std.time.Timer {
        if (self.decision_timer) |*timer| return timer;
        return null;
    }

    fn deadlineNs(self: *ManagedReceiveTimeoutV1) u64 {
        if (self.timeout_ns != 0) return self.timeout_ns;
        return self.full_request_timeout_ns;
    }
};

const ManagedFullRequestTimeoutV1 = struct {
    lifecycle: *ManagedLifecycleV1,
    lease: ManagedConnectionLeaseV1,
    timeout_ns: u64,
    wait_timer: ?std.time.Timer,
    request_stopped: std.Thread.ResetEvent = .{},
    signaled: bool = false,
    signal_error: ?anyerror = null,

    fn run(self: *ManagedFullRequestTimeoutV1) void {
        var timer = self.wait_timer orelse unreachable;
        const elapsed_ns = timer.read();
        if (elapsed_ns >= self.timeout_ns) {
            self.signal();
            return;
        }
        self.request_stopped.timedWait(
            self.timeout_ns - elapsed_ns,
        ) catch |err| switch (err) {
            error.Timeout => self.signal(),
        };
    }

    fn signal(self: *ManagedFullRequestTimeoutV1) void {
        self.signaled =
            self.lifecycle.claimFullRequestTimeoutV1(
                self.lease,
            ) catch |signal_error| {
                self.signal_error = signal_error;
                return;
            };
    }

    fn stop(self: *ManagedFullRequestTimeoutV1) !bool {
        defer self.request_stopped.set();
        return self.lifecycle.retireFullRequestTimeoutV1(
            self.lease,
        );
    }
};

/// Managed requests read only after bounded socket-readiness waits. Lifecycle
/// revalidation makes drain and failure convergence independent of a
/// successful cross-thread `shutdown`. When a monotonic budget is active,
/// recomputing it before every read keeps a trickling peer from turning the
/// absolute deadline into an inactivity timeout. The serving thread remains
/// the only socket reader and closer.
const ManagedDeadlineReaderV1 = struct {
    interface: std.Io.Reader,
    stream: std.net.Stream,
    receive_timeout: *ManagedReceiveTimeoutV1,
    received_bytes: u64 = 0,

    fn init(
        stream: std.net.Stream,
        receive_timeout: *ManagedReceiveTimeoutV1,
        buffer: []u8,
    ) ManagedDeadlineReaderV1 {
        return .{
            .interface = .{
                .vtable = &.{ .stream = streamWithinDeadline },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .receive_timeout = receive_timeout,
        };
    }

    fn streamWithinDeadline(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *ManagedDeadlineReaderV1 =
            @alignCast(@fieldParentPtr("interface", reader));
        const destination = limit.slice(
            try writer.writableSliceGreedy(1),
        );
        while (true) {
            self.waitUntilReadable() catch return error.ReadFailed;
            // F1 is POSIX-only. Read nonblocking after poll so stale or
            // consumed readiness cannot strand a blocking accepted socket
            // inside recv and prevent bounded drain/join convergence.
            const flags: u32 =
                if (builtin.os.tag == .windows)
                    0
                else
                    std.posix.MSG.DONTWAIT;
            const read_count = std.posix.recv(
                self.stream.handle,
                destination,
                flags,
            ) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => return error.ReadFailed,
            };
            if (read_count == 0) {
                _ = self.receive_timeout.lifecycle
                    .observePeerSendCloseDuringReceiveV1(
                    self.receive_timeout.lease,
                    self.received_bytes,
                    self.receive_timeout.timerPointer(),
                    self.receive_timeout.timeout_ns,
                ) catch |err| {
                    if (self.receive_timeout.peer_send_close_error == null)
                        self.receive_timeout.peer_send_close_error = err;
                    return error.ReadFailed;
                };
                return error.EndOfStream;
            }
            self.received_bytes = std.math.add(
                u64,
                self.received_bytes,
                @intCast(read_count),
            ) catch return error.ReadFailed;
            writer.advance(read_count);
            return read_count;
        }
    }

    fn waitUntilReadable(self: *ManagedDeadlineReaderV1) !void {
        while (true) {
            if (self.receive_timeout.interrupted())
                return error.ConnectionInterrupted;
            var wait_ms =
                managed_lifecycle_poll_interval_ms;
            if (self.receive_timeout.timerPointer()) |timer| {
                const elapsed_ns = timer.read();
                const deadline_ns =
                    self.receive_timeout.deadlineNs();
                if (elapsed_ns >= deadline_ns)
                    return error.ReceiveDeadlineExceeded;
                const remaining_ns =
                    deadline_ns - elapsed_ns;
                const remaining_ms: i32 = @intCast(
                    std.math.divCeil(
                        u64,
                        remaining_ns,
                        std.time.ns_per_ms,
                    ) catch unreachable,
                );
                wait_ms = @min(wait_ms, remaining_ms);
            }
            if (try pollReadableOnceV1(
                self.stream.handle,
                wait_ms,
            )) {
                if (self.receive_timeout.interrupted())
                    return error.ConnectionInterrupted;
                return;
            }
        }
    }

    fn pollReadableOnceV1(
        handle: std.net.Stream.Handle,
        timeout_ms: i32,
    ) !bool {
        if (builtin.os.tag == .windows) {
            var descriptors = [_]std.posix.pollfd{.{
                .fd = handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            return try std.posix.poll(&descriptors, timeout_ms) != 0;
        }

        var descriptors = [_]std.c.pollfd{.{
            .fd = handle,
            .events = std.c.POLL.IN,
            .revents = 0,
        }};
        const result = std.c.poll(
            &descriptors,
            @intCast(descriptors.len),
            timeout_ms,
        );
        return switch (std.posix.errno(result)) {
            .SUCCESS => result != 0,
            .INTR => false,
            .NOMEM => error.SystemResources,
            else => error.PollFailed,
        };
    }
};

const ManagedRequestWorkControlV1 = struct {
    lifecycle: *ManagedLifecycleV1,
    lease: ManagedConnectionLeaseV1,
    peer_reset_poll_timeout_ms: i32,
    peer_send_close_policy: PeerSendClosePolicyV1 =
        .preserve_response,
    observer: ?prepared_http.RequestWorkControlV1,
    observer_admitted: bool = false,
    retire_error: ?anyerror = null,

    fn admittedOpaque(
        context: *anyopaque,
        work_identity: prepared_http.WorkIdentityV1,
    ) anyerror!prepared_http.WorkDispositionV1 {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        const lifecycle_disposition =
            try self.lifecycle.markRequestAdmittedV1(
                self.lease,
                work_identity,
            );
        if (lifecycle_disposition == .draining)
            return .draining;
        if (lifecycle_disposition == .full_request_timeout)
            return .full_request_timeout;
        if (self.observer) |observer| {
            const observer_disposition = try observer.admitted_fn(
                observer.context,
                work_identity,
            );
            self.observer_admitted = true;
            return switch (observer_disposition) {
                .proceed => .proceed,
                .draining, .full_request_timeout => LifecycleError.InvalidTransition,
            };
        }
        return .proceed;
    }

    fn checkpointOpaque(
        context: *anyopaque,
        work_identity: prepared_http.WorkIdentityV1,
    ) anyerror!prepared_http.WorkCheckpointDispositionV1 {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        const lifecycle_disposition =
            try self.lifecycle.validateWorkCheckpointV1(
                self.lease,
                work_identity,
            );
        if (lifecycle_disposition != .proceed)
            return lifecycle_disposition;
        switch (try peerTransportStopV1(
            self.lease.handle,
            self.peer_reset_poll_timeout_ms,
        )) {
            .none => {},
            .reset => return self.lifecycle.claimPeerResetV1(
                self.lease,
                work_identity,
            ),
            .orderly_fin => {
                const peer_disposition =
                    try self.lifecycle.observePeerSendCloseV1(
                        self.lease,
                        work_identity,
                        self.peer_send_close_policy ==
                            .abandon_after_complete_request,
                    );
                if (peer_disposition != .proceed)
                    return peer_disposition;
            },
        }
        if (self.observer) |observer| {
            const callback = observer.checkpoint_fn orelse
                return .proceed;
            const observed =
                try callback(observer.context, work_identity);
            const post_observer =
                try self.lifecycle.validateWorkCheckpointV1(
                    self.lease,
                    work_identity,
                );
            if (post_observer != .proceed)
                return post_observer;
            return switch (observed) {
                .proceed => .proceed,
                .peer_reset => self.lifecycle.claimPeerResetV1(
                    self.lease,
                    work_identity,
                ),
                .peer_send_close => self.lifecycle.observePeerSendCloseV1(
                    self.lease,
                    work_identity,
                    self.peer_send_close_policy ==
                        .abandon_after_complete_request,
                ),
                .full_request_timeout => LifecycleError.InvalidTransition,
            };
        }
        return .proceed;
    }

    fn cancellationOpaque(
        context: *anyopaque,
        work_identity: prepared_http.WorkIdentityV1,
        receipt: prepared_http.WorkCancellationReceiptV1,
    ) void {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        self.lifecycle.recordWorkCancellationV1(
            self.lease,
            work_identity,
            receipt,
        ) catch |err| {
            self.retire_error = err;
        };
        if (self.observer) |observer| {
            if (!self.observer_admitted) return;
            const callback = observer.cancellation_fn orelse return;
            callback(observer.context, work_identity, receipt);
        }
    }

    fn admissionRejectedOpaque(
        context: *anyopaque,
        rejection: prepared_http.RequestAdmissionRejectionV1,
    ) void {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        const observer = self.observer orelse return;
        const callback =
            observer.admission_rejected_fn orelse return;
        callback(observer.context, .{
            .request_sha256 = rejection.request_sha256,
            .cause = rejection.cause,
            .transport_owner = transportOwnerTokenV1(
                self.lease,
            ),
        });
    }

    fn publishedOpaque(
        context: *anyopaque,
        publication: prepared_http.WorkPublicationV1,
    ) void {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        if (!self.observer_admitted) return;
        const observer = self.observer orelse return;
        const callback = observer.published_fn orelse return;
        callback(observer.context, .{
            .identity = publication.identity,
            .request_sha256 = publication.request_sha256,
            .transport_owner = transportOwnerTokenV1(
                self.lease,
            ),
        });
    }

    fn retiredOpaque(
        context: *anyopaque,
        work_identity: prepared_http.WorkIdentityV1,
    ) void {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        self.lifecycle.retireActiveConnectionWorkV1(
            self.lease,
            work_identity,
        ) catch |err| {
            self.retire_error = err;
        };
        if (self.observer) |observer| {
            if (!self.observer_admitted) return;
            observer.retired_fn(
                observer.context,
                work_identity,
            );
        }
    }

    fn control(self: *ManagedRequestWorkControlV1) prepared_http.RequestWorkControlV1 {
        return .{
            .context = self,
            .admitted_fn = admittedOpaque,
            .retired_fn = retiredOpaque,
            .transport_owner = transportOwnerTokenV1(
                self.lease,
            ),
            .checkpoint_fn = checkpointOpaque,
            .cancellation_fn = cancellationOpaque,
            .admission_rejected_fn = admissionRejectedOpaque,
            .published_fn = publishedOpaque,
        };
    }
};

const PeerTransportStopV1 = enum {
    none,
    reset,
    orderly_fin,
};

fn peerTransportStopV1(
    handle: std.net.Stream.Handle,
    timeout_ms: i32,
) !PeerTransportStopV1 {
    if (!try ManagedDeadlineReaderV1.pollReadableOnceV1(
        handle,
        timeout_ms,
    )) return .none;

    var probe: [1]u8 = undefined;
    const count = std.posix.recv(
        handle,
        &probe,
        std.posix.MSG.PEEK,
    ) catch |err| switch (err) {
        error.ConnectionResetByPeer,
        error.SocketNotConnected,
        => return .reset,
        error.WouldBlock => return .none,
        else => return err,
    };
    return if (count == 0) .orderly_fin else .none;
}

const ManagedRequestResponseControlV1 = struct {
    lifecycle: *ManagedLifecycleV1,
    lease: ManagedConnectionLeaseV1,
    full_request_timeout: *ManagedFullRequestTimeoutV1,
    peer_stop_poll_timeout_ms: i32,
    peer_send_close_policy: PeerSendClosePolicyV1,
    observer: ?prepared_http.RequestResponseControlV1,
    max_send_bytes: u16,
    observer_ready: bool = false,
    response_write_peer_stop_poll_armed: bool = false,
    response_write_peer_stop_poll_consumed: bool = false,
    writer_failure: ?cancellable_writer.FailureKindV1 = null,
    retire_error: ?anyerror = null,

    fn readyOpaque(context: *anyopaque) anyerror!void {
        const self: *ManagedRequestResponseControlV1 =
            @ptrCast(@alignCast(context));
        try self.lifecycle.markResponseReadyV1(
            self.lease,
        );
        if (self.observer) |observer| {
            self.observer_ready = true;
            try observer.ready_fn(observer.context);
        }
    }

    fn writingOpaque(
        context: *anyopaque,
    ) anyerror!prepared_http.ResponseWriteDispositionV1 {
        const self: *ManagedRequestResponseControlV1 =
            @ptrCast(@alignCast(context));
        const lifecycle_disposition =
            try self.lifecycle.checkResponseWriteV1(
                self.lease,
            );
        if (lifecycle_disposition == .cancelled)
            return .cancelled;
        if (self.peer_send_close_policy ==
            .abandon_after_complete_request)
        {
            const peer_disposition = switch (try peerTransportStopV1(
                self.lease.handle,
                self.peer_stop_poll_timeout_ms,
            )) {
                .none, .reset => .proceed,
                .orderly_fin => try self.lifecycle.observePeerSendCloseAtResponseReadyV1(
                    self.lease,
                    true,
                ),
            };
            if (peer_disposition == .cancelled)
                return .cancelled;
        }
        if (self.observer) |observer| {
            const observed = try observer.writing_fn(observer.context);
            if (observed == .cancelled) return .cancelled;
        }
        return self.lifecycle.markResponseWritingV1(
            self.lease,
        );
    }

    fn writerEventOpaque(
        context: *anyopaque,
        event: cancellable_writer.EventV1,
    ) anyerror!cancellable_writer.DispositionV1 {
        const self: *ManagedRequestResponseControlV1 =
            @ptrCast(@alignCast(context));
        return self.writerEvent(event) catch |err| {
            if (self.retire_error == null)
                self.retire_error = err;
            return err;
        };
    }

    fn writerEvent(
        self: *ManagedRequestResponseControlV1,
        event: cancellable_writer.EventV1,
    ) !cancellable_writer.DispositionV1 {
        return switch (event) {
            .before_send => blk: {
                const lifecycle_disposition =
                    try self.lifecycle.observeResponseWriteStopV1(
                        self.lease,
                    );
                if (lifecycle_disposition == .cancelled)
                    break :blk .cancelled;
                if (self.peer_send_close_policy !=
                    .abandon_after_complete_request)
                {
                    break :blk .proceed;
                }
                const poll_timeout_ms =
                    if (self.response_write_peer_stop_poll_armed and
                    !self.response_write_peer_stop_poll_consumed) timeout: {
                        self.response_write_peer_stop_poll_armed = false;
                        self.response_write_peer_stop_poll_consumed = true;
                        break :timeout self.peer_stop_poll_timeout_ms;
                    } else 0;
                break :blk switch (try peerTransportStopV1(
                    self.lease.handle,
                    poll_timeout_ms,
                )) {
                    .none, .reset => .proceed,
                    .orderly_fin => self.lifecycle.observePeerSendCloseAtResponseWritingV1(
                        self.lease,
                        true,
                    ),
                };
            },
            .progress => |bytes_sent| blk: {
                try self.lifecycle.recordResponseWriteProgressV1(
                    self.lease,
                    bytes_sent,
                );
                if (self.peer_send_close_policy ==
                    .abandon_after_complete_request and
                    !self.response_write_peer_stop_poll_consumed)
                {
                    self.response_write_peer_stop_poll_armed = true;
                }
                if (self.observer) |observer| {
                    if (observer.progress_fn) |callback|
                        try callback(observer.context, bytes_sent);
                }
                // A drain requested from the progress barrier is observed by
                // the next before-send checkpoint. If this was the final send,
                // local completion wins instead of becoming a false cancel.
                break :blk .proceed;
            },
            .would_block => blk: {
                if (self.observer) |observer| {
                    if (observer.blocked_fn) |callback|
                        try callback(observer.context);
                }
                break :blk self.lifecycle.observeResponseWriteStopV1(
                    self.lease,
                );
            },
        };
    }

    fn writerFailureOpaque(
        context: *anyopaque,
        failure: cancellable_writer.FailureV1,
    ) anyerror!void {
        const self: *ManagedRequestResponseControlV1 =
            @ptrCast(@alignCast(context));
        const failure_kind = std.meta.activeTag(failure);
        if (self.writer_failure != null)
            return LifecycleError.ConnectionInterrupted;
        self.writer_failure = failure_kind;
        self.lifecycle.recordResponseWriteFailureV1(
            self.lease,
            failure,
        ) catch |err| {
            if (self.retire_error == null)
                self.retire_error = err;
            return err;
        };
    }

    fn retiredOpaque(
        context: *anyopaque,
        outcome: prepared_http.ResponseWriteOutcomeV1,
    ) void {
        const self: *ManagedRequestResponseControlV1 =
            @ptrCast(@alignCast(context));
        const effective_outcome =
            self.lifecycle.retireResponseV1(
                self.lease,
                outcome,
                self.writer_failure,
            ) catch |err| {
                if (self.retire_error == null)
                    self.retire_error = err;
                return;
            };
        self.full_request_timeout.request_stopped.set();
        if (self.observer) |observer| {
            if (!self.observer_ready) return;
            observer.retired_fn(
                observer.context,
                effective_outcome,
            );
        }
    }

    fn writtenOpaque(context: *anyopaque) void {
        const self: *ManagedRequestResponseControlV1 =
            @ptrCast(@alignCast(context));
        _ = self.lifecycle.markResponseWrittenV1(self.lease) catch |err| {
            if (self.retire_error == null)
                self.retire_error = err;
            return;
        };
        if (self.observer) |observer| {
            if (observer.written_fn) |callback|
                callback(observer.context);
        }
    }

    fn control(
        self: *ManagedRequestResponseControlV1,
    ) prepared_http.RequestResponseControlV1 {
        return .{
            .context = self,
            .ready_fn = readyOpaque,
            .writing_fn = writingOpaque,
            .retired_fn = retiredOpaque,
            .written_fn = writtenOpaque,
        };
    }

    fn writerControl(
        self: *ManagedRequestResponseControlV1,
    ) cancellable_writer.ControlV1 {
        return .{
            .context = self,
            .event_fn = writerEventOpaque,
            .failure_fn = writerFailureOpaque,
        };
    }
};

fn serveManagedConnectionV1(
    connection: std.net.Server.Connection,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedLifecycleV1,
    lease: ManagedConnectionLeaseV1,
    receive_timeout_ns: u64,
    full_request_timeout_ns: u64,
    peer_reset_poll_timeout_ns: u64,
    peer_send_close_policy: PeerSendClosePolicyV1,
    response_write_quantum_bytes: u16,
    receive_timer: ?std.time.Timer,
    full_request_timer: ?std.time.Timer,
    work_observer: ?prepared_http.RequestWorkControlV1,
    response_observer: ?prepared_http.RequestResponseControlV1,
    deadline_authority: ManagedDeadlineAuthorityV1,
) !bool {
    var owned_connection = connection;
    defer owned_connection.stream.close();
    var receive_timeout: ManagedReceiveTimeoutV1 = .{
        .lifecycle = lifecycle,
        .lease = lease,
        .timeout_ns = receive_timeout_ns,
        .full_request_timeout_ns = full_request_timeout_ns,
        .decision_timer = receive_timer orelse full_request_timer,
        .wait_timer = receive_timer,
    };
    var full_request_timeout: ManagedFullRequestTimeoutV1 = .{
        .lifecycle = lifecycle,
        .lease = lease,
        .timeout_ns = full_request_timeout_ns,
        .wait_timer = full_request_timer,
    };
    var work_control: ManagedRequestWorkControlV1 = .{
        .lifecycle = lifecycle,
        .lease = lease,
        .peer_reset_poll_timeout_ms = peerResetPollTimeoutMsV1(
            peer_reset_poll_timeout_ns,
        ),
        .peer_send_close_policy = peer_send_close_policy,
        .observer = work_observer,
    };
    var response_control: ManagedRequestResponseControlV1 = .{
        .lifecycle = lifecycle,
        .lease = lease,
        .full_request_timeout = &full_request_timeout,
        .peer_stop_poll_timeout_ms = peerResetPollTimeoutMsV1(
            peer_reset_poll_timeout_ns,
        ),
        .peer_send_close_policy = peer_send_close_policy,
        .observer = response_observer,
        .max_send_bytes = response_write_quantum_bytes,
    };
    const receive_timeout_thread = if (deadline_authority == .shared_watchdog or
        receive_timer == null)
        null
    else
        std.Thread.spawn(
            .{},
            ManagedReceiveTimeoutV1.run,
            .{&receive_timeout},
        ) catch |err| {
            _ = receive_timeout.stop() catch {};
            _ = full_request_timeout.stop() catch {};
            try lifecycle.finishConnectionV1(
                lease,
                false,
            );
            return err;
        };
    const full_request_timeout_thread =
        if (deadline_authority == .shared_watchdog or
        full_request_timer == null)
            null
        else
            std.Thread.spawn(
                .{},
                ManagedFullRequestTimeoutV1.run,
                .{&full_request_timeout},
            ) catch |err| {
                receive_timeout.receive_stopped.set();
                if (receive_timeout_thread) |thread| thread.join();
                _ = receive_timeout.stop() catch {};
                _ = full_request_timeout.stop() catch {};
                try lifecycle.finishConnectionV1(
                    lease,
                    false,
                );
                return err;
            };
    const succeeded = blk: {
        serveOpenConnectionV1(
            &owned_connection.stream,
            runtime,
            &receive_timeout,
            work_control.control(),
            &response_control,
        ) catch break :blk false;
        break :blk true;
    };
    var stop_error: ?anyerror = null;
    const receive_retired = receive_timeout.stop() catch |err| blk: {
        stop_error = err;
        receive_timeout.receive_stopped.set();
        break :blk false;
    };
    const full_request_retired =
        full_request_timeout.stop() catch |err| blk: {
            if (stop_error == null) stop_error = err;
            full_request_timeout.request_stopped.set();
            break :blk false;
        };
    if (receive_timeout_thread) |thread| thread.join();
    if (full_request_timeout_thread) |thread| thread.join();
    const connection_succeeded =
        succeeded and
        receive_retired and
        full_request_retired and
        !receive_timeout.signaled and
        receive_timeout.signal_error == null and
        receive_timeout.peer_send_close_error == null and
        full_request_timeout.signal_error == null and
        stop_error == null and
        work_control.retire_error == null and
        response_control.retire_error == null;
    try lifecycle.finishConnectionV1(
        lease,
        connection_succeeded,
    );
    if (receive_timeout.signal_error) |err| return err;
    if (receive_timeout.peer_send_close_error) |err| return err;
    if (full_request_timeout.signal_error) |err| return err;
    if (stop_error) |err| return err;
    if (work_control.retire_error) |err| return err;
    if (response_control.retire_error) |err| return err;
    return connection_succeeded;
}

fn serveOpenConnectionV1(
    stream: *std.net.Stream,
    runtime: *prepared_http.RuntimeV1,
    receive_timeout: ?*ManagedReceiveTimeoutV1,
    work_control: ?prepared_http.RequestWorkControlV1,
    managed_response_control: ?*ManagedRequestResponseControlV1,
) !void {
    var receive_buffer: [prepared_http.header_max_bytes]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(&receive_buffer);
    var deadline_reader: ManagedDeadlineReaderV1 = undefined;
    const reader = blk: {
        if (receive_timeout) |timeout| {
            deadline_reader = ManagedDeadlineReaderV1.init(
                stream.*,
                timeout,
                &receive_buffer,
            );
            break :blk &deadline_reader.interface;
        }
        break :blk connection_reader.interface();
    };
    var connection_writer = stream.writer(&send_buffer);
    var managed_writer: cancellable_writer.WriterV1 = undefined;
    const writer = if (managed_response_control) |control| blk: {
        managed_writer = try cancellable_writer.WriterV1.init(
            stream.handle,
            &send_buffer,
            .{
                .max_send_bytes = control.max_send_bytes,
                .poll_interval_ms = 25,
            },
            control.writerControl(),
        );
        break :blk &managed_writer.interface;
    } else &connection_writer.interface;
    var server = std.http.Server.init(
        reader,
        writer,
    );
    var request = try server.receiveHead();
    if (receive_timeout) |timeout| {
        try timeout.markHeadReceived();
    }
    var workspace: prepared_http.WorkspaceV1 = undefined;
    const response_control =
        if (managed_response_control) |control|
            control.control()
        else
            null;
    if (receive_timeout) |timeout| {
        try prepared_http.serveRequestWithLifecycleControlsV1(
            runtime,
            &request,
            &workspace,
            .{
                .receive = .{
                    .context = timeout,
                    .complete_fn = ManagedReceiveTimeoutV1.completeOpaque,
                    .stop_fn = ManagedReceiveTimeoutV1.stopOpaque,
                },
                .work = work_control,
                .response = response_control,
            },
        );
    } else {
        try prepared_http.serveRequestWithLifecycleControlsV1(
            runtime,
            &request,
            &workspace,
            .{
                .work = work_control,
                .response = response_control,
            },
        );
    }
}

fn validateConfig(config: ServerConfig) Error!void {
    if (config.bind.len == 0) return Error.InvalidConfiguration;
    if (config.receive_timeout_ns != 0 and
        (config.receive_timeout_ns < minimum_receive_timeout_ns or
            config.receive_timeout_ns > maximum_receive_timeout_ns))
    {
        return Error.InvalidConfiguration;
    }
    if (config.full_request_timeout_ns != 0 and
        (config.full_request_timeout_ns <
            minimum_full_request_timeout_ns or
            config.full_request_timeout_ns >
                maximum_full_request_timeout_ns))
    {
        return Error.InvalidConfiguration;
    }
    if (config.receive_timeout_ns != 0 and
        config.full_request_timeout_ns != 0 and
        config.receive_timeout_ns >=
            config.full_request_timeout_ns)
    {
        return Error.InvalidConfiguration;
    }
    if (config.peer_reset_poll_timeout_ns != 0 and
        (config.peer_reset_poll_timeout_ns <
            minimum_peer_reset_poll_timeout_ns or
            config.peer_reset_poll_timeout_ns >
                maximum_peer_reset_poll_timeout_ns))
    {
        return Error.InvalidConfiguration;
    }
    if (config.response_write_quantum_bytes <
        minimum_response_write_quantum_bytes or
        config.response_write_quantum_bytes >
            maximum_response_write_quantum_bytes)
    {
        return Error.InvalidConfiguration;
    }
    if (!std.mem.eql(u8, config.bind, "127.0.0.1") and
        !std.mem.eql(u8, config.bind, "::1"))
    {
        return Error.NonLoopbackBind;
    }
}

fn validateManagedConcurrentConfigV1(
    config: ManagedConcurrentConfigV1,
) Error!void {
    if (config.worker_count <
        minimum_managed_concurrent_workers_v1 or
        config.worker_count >
            maximum_managed_concurrent_workers_v1)
    {
        return Error.InvalidConcurrentWorkerCount;
    }
    if (config.pending_connection_capacity <
        minimum_managed_pending_connections_v1 or
        config.pending_connection_capacity >
            maximum_managed_pending_connections_v1)
    {
        return Error.InvalidConcurrentPendingCapacity;
    }
    const total_capacity =
        @as(u16, config.worker_count) +
        @as(u16, config.pending_connection_capacity);
    if (total_capacity > maximum_managed_connection_slots_v1)
        return Error.ConcurrentLifecycleConfigurationMismatch;
}

fn peerResetPollTimeoutMsV1(timeout_ns: u64) i32 {
    if (timeout_ns == 0) return 0;
    return @intCast(std.math.divCeil(
        u64,
        timeout_ns,
        std.time.ns_per_ms,
    ) catch unreachable);
}

fn isLoopbackAddress(address: std.net.Address) bool {
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const bytes: *const [4]u8 =
                @ptrCast(&address.in.sa.addr);
            break :blk std.mem.eql(
                u8,
                bytes,
                &.{ 127, 0, 0, 1 },
            );
        },
        std.posix.AF.INET6 => std.mem.eql(
            u8,
            &address.in6.sa.addr,
            &([_]u8{0} ** 15 ++ [_]u8{1}),
        ),
        else => false,
    };
}

fn prepareResponseWritingLifecycleForTestV1(
    lifecycle: *ManagedLifecycleV1,
    handle: std.net.Stream.Handle,
    identity: prepared_http.WorkIdentityV1,
) !ManagedConnectionLeaseV1 {
    try lifecycle.markReadyV1();
    const lease = try lifecycle.beginConnectionV1(handle);
    try lifecycle.markRequestHeadReceivedV1(lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        lease,
        null,
        0,
    );
    _ = try lifecycle.markRequestAdmittedV1(
        lease,
        identity,
    );
    try lifecycle.retireActiveConnectionWorkV1(
        lease,
        identity,
    );
    try lifecycle.markResponseReadyV1(lease);
    _ = try lifecycle.markResponseWritingV1(lease);
    return lease;
}

fn waitForElapsedTimerForTestV1(
    timer: *std.time.Timer,
    deadline_ns: u64,
) void {
    while (timer.read() < deadline_ns)
        std.atomic.spinLoopHint();
}

fn setConnectionPhaseForTestV1(
    lifecycle: *ManagedLifecycleV1,
    lease: ManagedConnectionLeaseV1,
    phase: ManagedConnectionPhaseV1,
    receive_retired: bool,
) !void {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    const active =
        try lifecycle.activeConnectionForLeaseLockedV1(lease);
    active.phase = phase;
    active.receive_retired = receive_retired;
}

fn applyDrainWorkReceiptForTestV1(
    lifecycle: *ManagedLifecycleV1,
    receipt: prepared_http.DrainReceiptV1,
) !void {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    return applyDrainWorkReceiptLockedV1(
        lifecycle,
        receipt,
    );
}

const DetachedBatchObserverTestV1 = struct {
    observed: usize = 0,

    fn observeOpaque(
        context: *anyopaque,
        event: ManagedConcurrentEventV1,
    ) void {
        _ = event;
        const self: *DetachedBatchObserverTestV1 =
            @ptrCast(@alignCast(context));
        self.observed += 1;
    }

    fn observer(
        self: *DetachedBatchObserverTestV1,
    ) ManagedConcurrentObserverV1 {
        return .{
            .context = self,
            .event_fn = observeOpaque,
        };
    }
};

const ManagedAcceptFallbackTestContextV1 = struct {
    lifecycle: *ManagedConcurrentLifecycleV1,
    wait_entered: *std.Thread.ResetEvent,

    fn failAfterWaitEntered(
        self: *ManagedAcceptFallbackTestContextV1,
    ) void {
        self.wait_entered.wait();
        self.lifecycle.managed.mutex.lock();
        self.lifecycle.managed.state = .failed;
        self.lifecycle.managed.mutex.unlock();
    }
};

test "server config rejects non-loopback authority" {
    try std.testing.expectError(
        Error.NonLoopbackBind,
        validateConfig(.{ .bind = "0.0.0.0" }),
    );
    try validateConfig(.{});
    try validateConfig(.{ .bind = "::1" });
    try validateConfig(.{
        .receive_timeout_ns = minimum_receive_timeout_ns,
    });
    try validateConfig(.{
        .receive_timeout_ns = maximum_receive_timeout_ns,
    });
    try validateConfig(.{
        .full_request_timeout_ns = minimum_full_request_timeout_ns,
    });
    try validateConfig(.{
        .full_request_timeout_ns = maximum_full_request_timeout_ns,
    });
    try validateConfig(.{
        .receive_timeout_ns = minimum_receive_timeout_ns,
        .full_request_timeout_ns = minimum_receive_timeout_ns + std.time.ns_per_ms,
    });
    try validateConfig(.{
        .peer_reset_poll_timeout_ns = minimum_peer_reset_poll_timeout_ns,
    });
    try validateConfig(.{
        .peer_reset_poll_timeout_ns = maximum_peer_reset_poll_timeout_ns,
    });
    try validateConfig(.{
        .peer_send_close_policy = .abandon_after_complete_request,
    });
    try validateConfig(.{
        .response_write_quantum_bytes = minimum_response_write_quantum_bytes,
    });
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{ .receive_timeout_ns = 1 }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{
            .receive_timeout_ns = maximum_receive_timeout_ns + 1,
        }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{ .full_request_timeout_ns = 1 }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{
            .full_request_timeout_ns = maximum_full_request_timeout_ns + 1,
        }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{
            .receive_timeout_ns = minimum_receive_timeout_ns,
            .full_request_timeout_ns = minimum_receive_timeout_ns,
        }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{ .response_write_quantum_bytes = 0 }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{
            .response_write_quantum_bytes = maximum_response_write_quantum_bytes + 1,
        }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{
            .peer_reset_poll_timeout_ns = 1,
        }),
    );
    try std.testing.expectError(
        Error.InvalidConfiguration,
        validateConfig(.{
            .peer_reset_poll_timeout_ns = maximum_peer_reset_poll_timeout_ns + 1,
        }),
    );
    try std.testing.expect(isLoopbackAddress(
        try std.net.Address.parseIp("127.0.0.1", 0),
    ));
    try std.testing.expect(isLoopbackAddress(
        try std.net.Address.parseIp("::1", 0),
    ));
    try std.testing.expect(!isLoopbackAddress(
        try std.net.Address.parseIp("0.0.0.0", 0),
    ));

    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try std.testing.expectError(
        Error.ReceiveTimeoutRequiresManagedLifecycle,
        serveListenerV1(
            &listener,
            .{ .receive_timeout_ns = minimum_receive_timeout_ns },
            &runtime,
        ),
    );
    try std.testing.expectError(
        Error.PeerResetPollRequiresManagedLifecycle,
        serveListenerV1(
            &listener,
            .{
                .peer_reset_poll_timeout_ns = minimum_peer_reset_poll_timeout_ns,
            },
            &runtime,
        ),
    );
    try std.testing.expectError(
        Error.PeerSendClosePolicyRequiresManagedLifecycle,
        serveListenerV1(
            &listener,
            .{
                .peer_send_close_policy = .abandon_after_complete_request,
            },
            &runtime,
        ),
    );
    try std.testing.expectError(
        Error.FullRequestTimeoutRequiresManagedLifecycle,
        serveListenerV1(
            &listener,
            .{
                .full_request_timeout_ns = minimum_full_request_timeout_ns,
            },
            &runtime,
        ),
    );
    try std.testing.expectError(
        Error.ResponseWriteQuantumRequiresManagedLifecycle,
        serveListenerV1(
            &listener,
            .{
                .response_write_quantum_bytes = minimum_response_write_quantum_bytes,
            },
            &runtime,
        ),
    );
}

test "managed full request timeout preserves phase-specific evidence" {
    const timeout_ns = minimum_full_request_timeout_ns;
    const admitted_handle: std.net.Stream.Handle = @intCast(151);
    const admitted_identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 1,
        .handle_sha256 = [_]u8{0xa1} ** 32,
    };

    var admitted = try ManagedLifecycleV1.initV1(51);
    try admitted.markReadyV1();
    var admitted_timer = try std.time.Timer.start();
    const admitted_lease =
        try admitted.beginConnectionWithFullRequestTimeoutV1(
            admitted_handle,
            0,
            timeout_ns,
            admitted_timer,
        );
    try setConnectionPhaseForTestV1(
        &admitted,
        admitted_lease,
        .request_received,
        true,
    );
    waitForElapsedTimerForTestV1(
        &admitted_timer,
        timeout_ns,
    );
    try std.testing.expectEqual(
        prepared_http.WorkDispositionV1.full_request_timeout,
        try admitted.markRequestAdmittedV1(
            admitted_lease,
            admitted_identity,
        ),
    );
    try admitted.recordWorkCancellationV1(
        admitted_lease,
        admitted_identity,
        .{
            .requested_cause = .full_request_timeout,
            .winner = .full_request_timeout,
            .outcome = .cancelled,
            .cancellation_was_new = true,
        },
    );
    try admitted.retireActiveConnectionWorkV1(
        admitted_lease,
        admitted_identity,
    );
    try std.testing.expect(
        !try admitted.retireFullRequestTimeoutV1(
            admitted_lease,
        ),
    );
    try admitted.finishConnectionV1(admitted_lease, false);
    const admitted_snapshot = admitted.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        admitted_snapshot.full_request_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        admitted_snapshot.full_request_timeout_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_received,
        admitted_snapshot.last_full_request_timeout_signaled_phase,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        admitted_snapshot.last_full_request_timeout_cancelled_work_phase,
    );

    const ready_handle: std.net.Stream.Handle = @intCast(152);
    var ready = try ManagedLifecycleV1.initV1(52);
    try ready.markReadyV1();
    var ready_timer = try std.time.Timer.start();
    const ready_lease =
        try ready.beginConnectionWithFullRequestTimeoutV1(
            ready_handle,
            0,
            timeout_ns,
            ready_timer,
        );
    try setConnectionPhaseForTestV1(
        &ready,
        ready_lease,
        .request_received,
        true,
    );
    waitForElapsedTimerForTestV1(&ready_timer, timeout_ns);
    try ready.markResponseReadyV1(ready_lease);
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.cancelled,
        try ready.checkResponseWriteV1(ready_lease),
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.cancelled_before_write,
        try ready.retireResponseV1(
            ready_lease,
            .cancelled_before_write,
            null,
        ),
    );
    try ready.finishConnectionV1(ready_lease, false);
    const ready_snapshot = ready.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        ready_snapshot.full_request_timeout_cancelled_response_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_ready,
        ready_snapshot.last_full_request_timeout_cancelled_response_phase,
    );

    const writing_handle: std.net.Stream.Handle = @intCast(153);
    var writing = try ManagedLifecycleV1.initV1(53);
    try writing.markReadyV1();
    var writing_timer = try std.time.Timer.start();
    const writing_timeout_ns =
        100 * std.time.ns_per_ms;
    const writing_lease =
        try writing.beginConnectionWithFullRequestTimeoutV1(
            writing_handle,
            0,
            writing_timeout_ns,
            writing_timer,
        );
    try setConnectionPhaseForTestV1(
        &writing,
        writing_lease,
        .response_ready,
        true,
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.proceed,
        try writing.markResponseWritingV1(writing_lease),
    );
    waitForElapsedTimerForTestV1(
        &writing_timer,
        writing_timeout_ns,
    );
    try std.testing.expectEqual(
        cancellable_writer.DispositionV1.cancelled,
        try writing.observeResponseWriteStopV1(writing_lease),
    );
    try writing.recordResponseWriteFailureV1(
        writing_lease,
        .{ .cancelled = .{ .before_send = .{} } },
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.cancelled_during_write,
        try writing.retireResponseV1(
            writing_lease,
            .write_failed,
            .cancelled,
        ),
    );
    try writing.finishConnectionV1(writing_lease, false);
    const writing_snapshot = writing.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        writing_snapshot.full_request_timeout_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        writing_snapshot.full_request_timeout_cancelled_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        writing_snapshot.drain_cancelled_response_write_connections,
    );

    const late_written_handle: std.net.Stream.Handle =
        @intCast(154);
    var late_written = try ManagedLifecycleV1.initV1(54);
    try late_written.markReadyV1();
    var late_written_timer = try std.time.Timer.start();
    const late_written_lease =
        try late_written.beginConnectionWithFullRequestTimeoutV1(
            late_written_handle,
            0,
            writing_timeout_ns,
            late_written_timer,
        );
    try setConnectionPhaseForTestV1(
        &late_written,
        late_written_lease,
        .response_ready,
        true,
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.proceed,
        try late_written.markResponseWritingV1(
            late_written_lease,
        ),
    );
    waitForElapsedTimerForTestV1(
        &late_written_timer,
        writing_timeout_ns,
    );
    try std.testing.expect(
        !(try late_written.markResponseWrittenV1(
            late_written_lease,
        )),
    );
    const late_written_boundary =
        late_written.snapshotV1();
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_written,
        late_written_boundary.active_connection_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        late_written_boundary
            .full_request_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        late_written_boundary
            .full_request_timeout_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        late_written_boundary
            .full_request_timeout_cancelled_response_write_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_writing,
        late_written_boundary
            .last_full_request_timeout_signaled_phase,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_writing,
        late_written_boundary
            .last_full_request_timeout_requested_response_write_phase,
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.write_completed,
        try late_written.retireResponseV1(
            late_written_lease,
            .write_completed,
            null,
        ),
    );
    try std.testing.expect(
        !(try late_written.retireFullRequestTimeoutV1(
            late_written_lease,
        )),
    );
    try late_written.finishConnectionV1(
        late_written_lease,
        false,
    );
    const late_written_final = late_written.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 0),
        late_written_final.completed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        late_written_final.failed_connections,
    );

    const completed_handle: std.net.Stream.Handle = @intCast(155);
    var completed = try ManagedLifecycleV1.initV1(55);
    try completed.markReadyV1();
    const completed_timer = try std.time.Timer.start();
    const completed_lease =
        try completed.beginConnectionWithFullRequestTimeoutV1(
            completed_handle,
            0,
            writing_timeout_ns,
            completed_timer,
        );
    try setConnectionPhaseForTestV1(
        &completed,
        completed_lease,
        .response_ready,
        true,
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.proceed,
        try completed.markResponseWritingV1(completed_lease),
    );
    try std.testing.expect(
        try completed.markResponseWrittenV1(completed_lease),
    );
    waitForElapsedTimerForTestV1(
        &completed_timer,
        writing_timeout_ns,
    );
    try std.testing.expect(
        !(try completed.claimFullRequestTimeoutV1(
            completed_lease,
        )),
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.write_completed,
        try completed.retireResponseV1(
            completed_lease,
            .write_completed,
            null,
        ),
    );
    try std.testing.expect(
        try completed.retireFullRequestTimeoutV1(
            completed_lease,
        ),
    );
    try completed.finishConnectionV1(completed_lease, true);
    try std.testing.expectEqual(
        @as(u64, 0),
        completed.snapshotV1()
            .full_request_timeout_signaled_connections,
    );
}

test "managed response write drain records its exact winner" {
    const handle: std.net.Stream.Handle = @intCast(131);
    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 1,
        .handle_sha256 = [_]u8{0x81} ** 32,
    };

    var cancelled = try ManagedLifecycleV1.initV1(41);
    const cancelled_lease =
        try prepareResponseWritingLifecycleForTestV1(
            &cancelled,
            handle,
            identity,
        );
    try cancelled.recordResponseWriteProgressV1(
        cancelled_lease,
        1,
    );
    cancelled.mutex.lock();
    const first_drain =
        cancelled.signalActiveConnectionForDrainLockedV1() catch |err| {
            cancelled.mutex.unlock();
            return err;
        };
    const repeated_drain =
        cancelled.signalActiveConnectionForDrainLockedV1() catch |err| {
            cancelled.mutex.unlock();
            return err;
        };
    cancelled.mutex.unlock();
    try std.testing.expect(first_drain);
    try std.testing.expect(repeated_drain);
    try std.testing.expectEqual(
        cancellable_writer.DispositionV1.cancelled,
        try cancelled.observeResponseWriteStopV1(
            cancelled_lease,
        ),
    );
    try std.testing.expectEqual(
        cancellable_writer.DispositionV1.cancelled,
        try cancelled.observeResponseWriteStopV1(
            cancelled_lease,
        ),
    );
    try cancelled.recordResponseWriteFailureV1(
        cancelled_lease,
        .{ .cancelled = .{ .before_send = .{} } },
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.cancelled_during_write,
        try cancelled.retireResponseV1(
            cancelled_lease,
            .write_failed,
            .cancelled,
        ),
    );
    const cancelled_snapshot = cancelled.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        cancelled_snapshot.drain_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        cancelled_snapshot.drain_cancelled_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        cancelled_snapshot.response_write_transport_failed_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_writing,
        cancelled_snapshot.last_drain_requested_response_write_phase,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_writing,
        cancelled_snapshot.last_drain_cancelled_response_write_phase,
    );
    try cancelled.finishConnectionV1(cancelled_lease, false);

    var completed = try ManagedLifecycleV1.initV1(42);
    const completed_lease =
        try prepareResponseWritingLifecycleForTestV1(
            &completed,
            handle,
            identity,
        );
    completed.mutex.lock();
    const requested =
        completed.signalActiveConnectionForDrainLockedV1() catch |err| {
            completed.mutex.unlock();
            return err;
        };
    completed.mutex.unlock();
    try std.testing.expect(requested);
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.write_completed,
        try completed.retireResponseV1(
            completed_lease,
            .write_completed,
            null,
        ),
    );
    const completed_snapshot = completed.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        completed_snapshot.drain_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        completed_snapshot.drain_cancelled_response_write_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_written,
        completed_snapshot.active_connection_phase,
    );
    try completed.finishConnectionV1(completed_lease, true);

    var locally_written = try ManagedLifecycleV1.initV1(44);
    const locally_written_lease =
        try prepareResponseWritingLifecycleForTestV1(
            &locally_written,
            handle,
            identity,
        );
    try std.testing.expect(
        try locally_written.markResponseWrittenV1(
            locally_written_lease,
        ),
    );
    locally_written.mutex.lock();
    const post_write_drain =
        locally_written.signalActiveConnectionForDrainLockedV1() catch |err| {
            locally_written.mutex.unlock();
            return err;
        };
    locally_written.mutex.unlock();
    try std.testing.expect(post_write_drain);
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.write_completed,
        try locally_written.retireResponseV1(
            locally_written_lease,
            .write_completed,
            null,
        ),
    );
    const locally_written_snapshot =
        locally_written.snapshotV1();
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_written,
        locally_written_snapshot.active_connection_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        locally_written_snapshot
            .drain_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        locally_written_snapshot
            .drain_cancelled_response_write_connections,
    );
    try locally_written.finishConnectionV1(
        locally_written_lease,
        true,
    );

    var transport = try ManagedLifecycleV1.initV1(43);
    const transport_lease =
        try prepareResponseWritingLifecycleForTestV1(
            &transport,
            handle,
            identity,
        );
    try transport.recordResponseWriteFailureV1(
        transport_lease,
        .{ .transport = .send },
    );
    transport.mutex.lock();
    const transport_won =
        transport.signalActiveConnectionForDrainLockedV1() catch |err| {
            transport.mutex.unlock();
            return err;
        };
    transport.mutex.unlock();
    try std.testing.expect(transport_won);
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.write_failed,
        try transport.retireResponseV1(
            transport_lease,
            .write_failed,
            .transport,
        ),
    );
    const transport_snapshot = transport.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 0),
        transport_snapshot.drain_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        transport_snapshot.response_write_transport_failed_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.response_writing,
        transport_snapshot.last_response_write_transport_failed_phase,
    );
    try transport.finishConnectionV1(transport_lease, false);
}

test "managed lifecycle has one drain linearization point" {
    try std.testing.expectError(
        LifecycleError.InvalidGeneration,
        ManagedLifecycleV1.initV1(0),
    );
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer peer.close();
    const connection = try listener.accept();
    defer connection.stream.close();

    var lifecycle = try ManagedLifecycleV1.initV1(7);
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try lifecycle.markReadyV1();
    const lease = try lifecycle.beginConnectionV1(
        connection.stream.handle,
    );
    try lifecycle.markRequestHeadReceivedV1(lease);
    try std.testing.expect(
        try beginManagedDrainV1(&lifecycle, &runtime),
    );
    try std.testing.expectError(
        LifecycleError.InvalidTransition,
        lifecycle.beginConnectionV1(connection.stream.handle),
    );
    try std.testing.expect(
        !prepared_http.acceptingCompletionsV1(&runtime),
    );
    try std.testing.expectEqualDeep(
        ManagedSnapshotV1{
            .process_generation = 7,
            .state = .draining,
            .accepted_connections = 1,
            .completed_connections = 0,
            .failed_connections = 0,
            .active_connections = 1,
            .drain_signaled_connections = 1,
            .receive_timeout_signaled_connections = 0,
            .active_connection_phase = .request_head_received,
            .last_drain_signaled_phase = .request_head_received,
            .last_receive_timeout_signaled_phase = .none,
        },
        lifecycle.snapshotV1(),
    );
    try lifecycle.finishConnectionV1(lease, false);
    try lifecycle.markStoppedV1();
    try std.testing.expectEqualDeep(
        ManagedSnapshotV1{
            .process_generation = 7,
            .state = .stopped,
            .accepted_connections = 1,
            .completed_connections = 0,
            .failed_connections = 1,
            .active_connections = 0,
            .drain_signaled_connections = 1,
            .receive_timeout_signaled_connections = 0,
            .active_connection_phase = .none,
            .last_drain_signaled_phase = .request_head_received,
            .last_receive_timeout_signaled_phase = .none,
        },
        lifecycle.snapshotV1(),
    );

    var starting = try ManagedLifecycleV1.initV1(8);
    var starting_runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try std.testing.expectError(
        LifecycleError.InvalidTransition,
        beginManagedDrainV1(&starting, &starting_runtime),
    );
    try std.testing.expect(
        prepared_http.acceptingCompletionsV1(&starting_runtime),
    );
    try starting.markReadyV1();
    try std.testing.expect(
        !(try beginManagedDrainV1(
            &starting,
            &starting_runtime,
        )),
    );
    try std.testing.expect(
        !prepared_http.acceptingCompletionsV1(&starting_runtime),
    );
    try std.testing.expectEqual(
        ManagedStateV1.draining,
        starting.snapshotV1().state,
    );
    try starting.markStoppedV1();
}

test "finish-published drain reconciles the admitted callback race" {
    try std.testing.expectEqual(
        @as(u8, 1),
        @intFromEnum(ManagedDrainPolicyV1.cancel_active),
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        @intFromEnum(ManagedDrainPolicyV1.finish_published),
    );

    var lifecycle = try ManagedLifecycleV1.initV1(81);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(301));
    try lifecycle.markRequestHeadReceivedV1(lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        lease,
        null,
        0,
    );
    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 37,
        .handle_sha256 = [_]u8{0xc1} ** 32,
    };
    const work_receipt: prepared_http.DrainReceiptV1 = .{
        .admission_was_open = true,
        .active_work = identity,
        .transport_owner = transportOwnerTokenV1(lease),
    };

    lifecycle.mutex.lock();
    lifecycle.effective_drain_policy = .finish_published;
    applyDrainWorkReceiptWithPolicyLockedV1(
        &lifecycle,
        work_receipt,
        .finish_published,
    ) catch |err| {
        lifecycle.mutex.unlock();
        return err;
    };
    lifecycle.state = .draining;
    lifecycle.mutex.unlock();

    try std.testing.expectEqual(
        prepared_http.WorkDispositionV1.proceed,
        try lifecycle.markRequestAdmittedV1(lease, identity),
    );
    lifecycle.mutex.lock();
    const finish_was_exact = blk: {
        const active =
            lifecycle.activeConnectionForLeaseLockedV1(
                lease,
            ) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        break :blk active.finish_published_selected and
            active.phase == .request_admitted and
            active.work_identity != null and
            std.meta.eql(active.work_identity.?, identity);
    };
    lifecycle.mutex.unlock();
    try std.testing.expect(finish_was_exact);

    try lifecycle.retireActiveConnectionWorkV1(lease, identity);
    try lifecycle.finishConnectionV1(lease, true);
    try lifecycle.markStoppedV1();
}

test "drain receipt classifies a sticky runtime stop before its callback" {
    var lifecycle = try ManagedLifecycleV1.initV1(87);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(304));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        lease,
        .request_received,
        true,
    );
    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 39,
        .handle_sha256 = [_]u8{0xc3} ** 32,
    };
    const work_receipt: prepared_http.DrainReceiptV1 = .{
        .admission_was_open = true,
        .active_work = identity,
        .transport_owner = transportOwnerTokenV1(lease),
        .cancellation = .cancelled,
        .cancellation_winner = .transport_failure,
    };
    var timer = try std.time.Timer.start();
    while (timer.read() < 1) {}
    lifecycle.mutex.lock();
    applyDrainWorkReceiptWithPolicyLockedV1(
        &lifecycle,
        work_receipt,
        .finish_published,
    ) catch |err| {
        lifecycle.mutex.unlock();
        return err;
    };
    const decisions = lifecycle.drainDecisionCountsLockedV1(
        .finish_published,
        work_receipt,
    );
    const active =
        lifecycle.activeConnectionForLeaseLockedV1(
            lease,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    active.accept_timer = timer;
    active.full_request_timeout_ns = 1;
    active.full_request_timeout_retired = false;
    lifecycle.state = .draining;
    const deadline_is_guarded =
        !fullRequestDeadlineExpiredForActiveV1(
            active,
            lifecycle.state,
        ) and
        remainingDeadlineNsV1(
            active,
            lifecycle.state,
        ) == null;
    const deadline_was_claimed =
        lifecycle.claimFullRequestTimeoutLockedV1(
            lease,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    lifecycle.mutex.unlock();
    try std.testing.expectEqual(
        @as(u8, 1),
        decisions.preexisting_stop,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        decisions.finish_selected,
    );
    try std.testing.expect(deadline_is_guarded);
    try std.testing.expect(!deadline_was_claimed);
    try lifecycle.retireActiveConnectionWorkV1(lease, identity);
    try lifecycle.finishConnectionV1(lease, false);
    try lifecycle.markStoppedV1();
}

test "per-connection drain settlement waits for close confirmation" {
    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(89, 2);
    try lifecycle.markReadyV1();
    const rejected =
        try lifecycle.beginConnectionV1(@intCast(330));
    const written =
        try lifecycle.beginConnectionV1(@intCast(331));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        rejected,
        .request_received,
        true,
    );
    try setConnectionPhaseForTestV1(
        &lifecycle,
        written,
        .response_written,
        true,
    );
    lifecycle.mutex.lock();
    const written_active =
        lifecycle.activeConnectionForLeaseLockedV1(
            written,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    written_active.response_retired = true;
    lifecycle.mutex.unlock();

    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    const initiation = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    const session = try openManagedDrainSettlementSessionV1(
        &lifecycle,
        &initiation,
    );
    var forged_initiation = initiation;
    forged_initiation.phase_counts.request_received -= 1;
    forged_initiation.phase_counts.request_head_received += 1;
    try std.testing.expectError(
        LifecycleError.DrainSettlementMismatch,
        openManagedDrainSettlementSessionV1(
            &lifecycle,
            &forged_initiation,
        ),
    );
    try std.testing.expectEqual(@as(u8, 2), session.cohort_connections);
    var progress = try inspectManagedDrainSettlementsV1(
        &lifecycle,
        &session,
    );
    try std.testing.expectEqual(@as(u8, 2), progress.active_connections);
    try std.testing.expectEqual(
        @as(u8, 0),
        progress.transport_closing_connections,
    );
    const rejected_initial =
        try inspectManagedDrainConnectionAtV1(
            &lifecycle,
            &session,
            0,
        );
    try std.testing.expectEqual(
        ManagedDrainConnectionDecisionV1.reject_unpublished,
        rejected_initial.selection.initial_decision,
    );
    try std.testing.expectEqual(
        ManagedDrainConnectionRetirementStateV1.active,
        rejected_initial.retirement_state,
    );

    try lifecycle.finishConnectionV1(rejected, true);
    progress = try inspectManagedDrainSettlementsV1(
        &lifecycle,
        &session,
    );
    try std.testing.expectEqual(@as(u8, 1), progress.active_connections);
    try std.testing.expectEqual(
        @as(u8, 1),
        progress.transport_closing_connections,
    );
    const rejected_closing =
        try inspectManagedDrainConnectionByOwnerV1(
            &lifecycle,
            &session,
            transportOwnerTokenV1(rejected),
        );
    try std.testing.expectEqual(
        ManagedDrainConnectionRetirementStateV1.transport_closing,
        rejected_closing.retirement_state,
    );
    try std.testing.expect(rejected_closing.settlement == null);
    try std.testing.expect(
        try lifecycle.confirmTransportClosedV1(
            rejected,
            .owner_confirmed,
        ),
    );
    try std.testing.expect(
        !(try lifecycle.confirmTransportClosedV1(
            rejected,
            .owner_confirmed,
        )),
    );

    try lifecycle.finishConnectionV1(written, true);
    _ = try lifecycle.confirmTransportClosedV1(
        written,
        .owner_confirmed,
    );
    try lifecycle.markStoppedV1();
    progress = try inspectManagedDrainSettlementsV1(
        &lifecycle,
        &session,
    );
    try std.testing.expect(progress.settled);
    try std.testing.expectEqual(
        @as(u8, 2),
        progress.settled_connections,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        progress.logically_completed_connections,
    );
    const rejected_final =
        (try inspectManagedDrainConnectionAtV1(
            &lifecycle,
            &session,
            0,
        )).settlement.?;
    try std.testing.expectEqual(
        ManagedDrainConnectionTerminalCauseV1.reject_unpublished,
        rejected_final.terminal_cause,
    );
    try std.testing.expectEqual(
        ManagedDrainConnectionTerminalStatusV1.completed,
        rejected_final.terminal_status,
    );
    const written_final =
        (try inspectManagedDrainConnectionAtV1(
            &lifecycle,
            &session,
            1,
        )).settlement.?;
    try std.testing.expectEqual(
        ManagedDrainConnectionTerminalCauseV1.normal_completion,
        written_final.terminal_cause,
    );
    try std.testing.expect(written_final.local_write_completed);
    try std.testing.expect(written_final.evidence_complete);
    try std.testing.expectError(
        LifecycleError.DrainSettlementMemberOutOfRange,
        inspectManagedDrainConnectionAtV1(
            &lifecycle,
            &session,
            2,
        ),
    );
    var forged = session;
    forged.drain_epoch += 1;
    try std.testing.expectError(
        LifecycleError.DrainSettlementMismatch,
        inspectManagedDrainSettlementsV1(
            &lifecycle,
            &forged,
        ),
    );
}

test "pre-cohort close cannot settle a reused drain member slot" {
    var lifecycle = try ManagedLifecycleV1.initV1(91);
    try lifecycle.markReadyV1();
    const pre_cohort =
        try lifecycle.beginConnectionV1(@intCast(333));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        pre_cohort,
        .request_received,
        true,
    );
    try lifecycle.finishConnectionV1(pre_cohort, true);

    const cohort_member =
        try lifecycle.beginConnectionV1(@intCast(334));
    try std.testing.expectEqual(
        pre_cohort.slot_index,
        cohort_member.slot_index,
    );
    try std.testing.expect(
        pre_cohort.slot_generation !=
            cohort_member.slot_generation,
    );
    try setConnectionPhaseForTestV1(
        &lifecycle,
        cohort_member,
        .request_received,
        true,
    );

    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    const initiation = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    const session = try openManagedDrainSettlementSessionV1(
        &lifecycle,
        &initiation,
    );
    try std.testing.expect(
        !(try lifecycle.confirmTransportClosedV1(
            pre_cohort,
            .owner_confirmed,
        )),
    );
    const active =
        try inspectManagedDrainConnectionByOwnerV1(
            &lifecycle,
            &session,
            transportOwnerTokenV1(cohort_member),
        );
    try std.testing.expectEqual(
        ManagedDrainConnectionRetirementStateV1.active,
        active.retirement_state,
    );
    try std.testing.expect(active.settlement == null);

    try lifecycle.finishConnectionV1(cohort_member, true);
    try std.testing.expect(
        try lifecycle.confirmTransportClosedV1(
            cohort_member,
            .owner_confirmed,
        ),
    );
    try lifecycle.markStoppedV1();
    const settled =
        try inspectManagedDrainConnectionByOwnerV1(
            &lifecycle,
            &session,
            transportOwnerTokenV1(cohort_member),
        );
    try std.testing.expectEqual(
        ManagedDrainConnectionRetirementStateV1.settled,
        settled.retirement_state,
    );
    try std.testing.expect(settled.settlement != null);
}

test "emergency worker retirement stays incomplete lifecycle evidence" {
    var lifecycle = try ManagedLifecycleV1.initV1(94);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(335));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        lease,
        .request_received,
        true,
    );
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    const initiation = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    const session = try openManagedDrainSettlementSessionV1(
        &lifecycle,
        &initiation,
    );

    lifecycle.mutex.lock();
    lifecycle.forceFinishConnectionLockedV1(
        lease,
    ) catch |err| {
        lifecycle.mutex.unlock();
        return err;
    };
    lifecycle.mutex.unlock();
    _ = try lifecycle.confirmTransportClosedV1(
        lease,
        .owner_confirmed,
    );
    try lifecycle.markStoppedV1();

    const settlement =
        (try inspectManagedDrainConnectionAtV1(
            &lifecycle,
            &session,
            0,
        )).settlement.?;
    try std.testing.expectEqual(
        ManagedDrainConnectionTerminalStatusV1.failed,
        settlement.terminal_status,
    );
    try std.testing.expectEqual(
        ManagedDrainConnectionTerminalCauseV1.lifecycle_failure,
        settlement.terminal_cause,
    );
    try std.testing.expectEqual(
        ManagedDrainTransportCloseEvidenceV1.owner_confirmed,
        settlement.transport_close_evidence,
    );
    try std.testing.expect(!settlement.evidence_complete);
}

test "per-connection settlement retains finish to cancel revision" {
    var lifecycle = try ManagedLifecycleV1.initV1(90);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(332));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        lease,
        .response_ready,
        true,
    );
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    const finish = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    const session = try openManagedDrainSettlementSessionV1(
        &lifecycle,
        &finish,
    );
    const escalation = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .cancel_active,
    )).receipt;
    try std.testing.expect(escalation.policy_was_escalated);
    const revised = try inspectManagedDrainConnectionAtV1(
        &lifecycle,
        &session,
        0,
    );
    try std.testing.expectEqual(
        ManagedDrainConnectionDecisionV1.finish_selected,
        revised.selection.initial_decision,
    );
    try std.testing.expectEqual(
        ManagedDrainConnectionDecisionV1.abort_selected,
        revised.selection.latest_decision,
    );
    try std.testing.expectEqual(
        @as(u16, 2),
        revised.selection.latest_policy_revision,
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.cancelled_before_write,
        try lifecycle.retireResponseV1(
            lease,
            .cancelled_before_write,
        ),
    );
    try lifecycle.finishConnectionV1(lease, true);
    _ = try lifecycle.confirmTransportClosedV1(
        lease,
        .owner_confirmed,
    );
    try lifecycle.markStoppedV1();
    const final =
        (try inspectManagedDrainConnectionAtV1(
            &lifecycle,
            &session,
            0,
        )).settlement.?;
    try std.testing.expectEqual(
        ManagedDrainConnectionTerminalCauseV1.drain,
        final.terminal_cause,
    );
    try std.testing.expectEqual(
        ManagedDrainPolicyV1.finish_published,
        final.initial_effective_policy,
    );
    try std.testing.expectEqual(
        ManagedDrainPolicyV1.cancel_active,
        final.latest_effective_policy,
    );
    try std.testing.expectEqual(@as(u16, 2), final.latest_policy_revision);
}

test "managed drain receipt conserves phases and permits escalation" {
    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(82, 3);
    try lifecycle.markReadyV1();
    const request_received =
        try lifecycle.beginConnectionV1(@intCast(311));
    const response_ready =
        try lifecycle.beginConnectionV1(@intCast(312));
    const response_writing =
        try lifecycle.beginConnectionV1(@intCast(313));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        request_received,
        .request_received,
        true,
    );
    try setConnectionPhaseForTestV1(
        &lifecycle,
        response_ready,
        .response_ready,
        true,
    );
    try setConnectionPhaseForTestV1(
        &lifecycle,
        response_writing,
        .response_writing,
        true,
    );
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };

    const preserving = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    try std.testing.expect(preserving.drain_was_new);
    try std.testing.expect(preserving.connection_actions_applied);
    try std.testing.expect(preserving.admission_was_open);
    try std.testing.expectEqual(
        ManagedDrainPolicyV1.finish_published,
        preserving.effective_policy,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        preserving.phase_counts.request_received,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        preserving.phase_counts.response_ready,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        preserving.phase_counts.response_writing,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        preserving.decisions.finish_selected,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        preserving.decisions.reject_unpublished,
    );
    try std.testing.expectEqual(
        managedDrainPhaseTotalV1(preserving.phase_counts),
        managedDrainDecisionTotalV1(preserving.decisions),
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        preserving.decisions.resumable,
    );
    var snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.drain_cancelled_response_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.drain_requested_response_write_connections,
    );

    const escalated = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .cancel_active,
    )).receipt;
    try std.testing.expect(!escalated.drain_was_new);
    try std.testing.expect(escalated.policy_was_escalated);
    try std.testing.expect(escalated.connection_actions_applied);
    try std.testing.expectEqual(
        ManagedDrainPolicyV1.cancel_active,
        escalated.effective_policy,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        escalated.decisions.abort_selected,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        escalated.decisions.reject_unpublished,
    );
    snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.drain_cancelled_response_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.drain_requested_response_write_connections,
    );

    const cannot_downgrade = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    try std.testing.expectEqual(
        ManagedDrainPolicyV1.cancel_active,
        cannot_downgrade.effective_policy,
    );
    try std.testing.expect(!cannot_downgrade.policy_was_escalated);
    try std.testing.expect(
        !cannot_downgrade.connection_actions_applied,
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        cannot_downgrade.decisions.preexisting_stop,
    );

    lifecycle.mutex.lock();
    inline for (.{
        request_received,
        response_ready,
        response_writing,
    }) |lease| {
        const active =
            lifecycle.activeConnectionForLeaseLockedV1(
                lease,
            ) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        active.receive_retired = true;
        active.full_request_timeout_retired = true;
        active.work_retired = true;
        active.response_retired = true;
    }
    lifecycle.mutex.unlock();
    try lifecycle.finishConnectionV1(request_received, true);
    try lifecycle.finishConnectionV1(response_ready, false);
    try lifecycle.finishConnectionV1(response_writing, false);
    try lifecycle.markStoppedV1();

    const inspection =
        try inspectManagedDrainV1(&lifecycle, &escalated);
    try std.testing.expect(inspection.settled);
    try std.testing.expectEqual(
        @as(u64, 1),
        inspection.completed_since_linearization,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        inspection.failed_since_linearization,
    );
    try std.testing.expectEqual(
        ManagedDrainPolicyV1.cancel_active,
        inspection.effective_policy,
    );

    var invalid_receipt = escalated;
    invalid_receipt.receipt_abi_version += 1;
    try std.testing.expectError(
        LifecycleError.DrainReceiptMismatch,
        inspectManagedDrainV1(&lifecycle, &invalid_receipt),
    );
    invalid_receipt = escalated;
    invalid_receipt.decisions.resumable = 1;
    try std.testing.expectError(
        LifecycleError.DrainReceiptMismatch,
        inspectManagedDrainV1(&lifecycle, &invalid_receipt),
    );
    invalid_receipt = escalated;
    invalid_receipt.phase_counts =
        .{ .queued = std.math.maxInt(u8) };
    try std.testing.expectError(
        LifecycleError.DrainReceiptMismatch,
        inspectManagedDrainV1(&lifecycle, &invalid_receipt),
    );
    invalid_receipt = preserving;
    invalid_receipt.policy_was_escalated = true;
    try std.testing.expectError(
        LifecycleError.DrainReceiptMismatch,
        inspectManagedDrainV1(&lifecycle, &invalid_receipt),
    );
    invalid_receipt = cannot_downgrade;
    invalid_receipt.requested_policy = .cancel_active;
    invalid_receipt.effective_policy = .finish_published;
    try std.testing.expectError(
        LifecycleError.DrainReceiptMismatch,
        inspectManagedDrainV1(&lifecycle, &invalid_receipt),
    );
    invalid_receipt = escalated;
    invalid_receipt.active_work = .{
        .sequence = 41,
        .handle_sha256 = [_]u8{0xc2} ** 32,
    };
    try std.testing.expectError(
        LifecycleError.DrainReceiptMismatch,
        inspectManagedDrainV1(&lifecycle, &invalid_receipt),
    );
}

test "repeated serial cancel preserves the legacy response window" {
    var lifecycle = try ManagedLifecycleV1.initV1(84);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(321));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        lease,
        .request_received,
        true,
    );
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };

    const first = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .cancel_active,
    )).receipt;
    try std.testing.expect(first.connection_actions_applied);
    try setConnectionPhaseForTestV1(
        &lifecycle,
        lease,
        .response_ready,
        true,
    );
    const repeated = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .cancel_active,
    )).receipt;
    try std.testing.expect(!repeated.connection_actions_applied);
    try std.testing.expectEqual(
        @as(u8, 1),
        repeated.decisions.finish_selected,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        lifecycle.snapshotV1()
            .drain_cancelled_response_connections,
    );

    lifecycle.mutex.lock();
    const active =
        lifecycle.activeConnectionForLeaseLockedV1(
            lease,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    active.work_retired = true;
    active.response_retired = true;
    lifecycle.mutex.unlock();
    try lifecycle.finishConnectionV1(lease, true);
    try lifecycle.markStoppedV1();
}

test "finish-published drain keeps the full-request deadline live" {
    var lifecycle = try ManagedLifecycleV1.initV1(85);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(322));
    try setConnectionPhaseForTestV1(
        &lifecycle,
        lease,
        .response_ready,
        true,
    );
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    const receipt = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    try std.testing.expectEqual(
        @as(u8, 1),
        receipt.decisions.finish_selected,
    );

    var timer = try std.time.Timer.start();
    while (timer.read() < 1) {}
    lifecycle.mutex.lock();
    const active =
        lifecycle.activeConnectionForLeaseLockedV1(
            lease,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    active.accept_timer = timer;
    active.full_request_timeout_ns = 1;
    active.full_request_timeout_retired = false;
    lifecycle.mutex.unlock();
    try std.testing.expect(
        try lifecycle.claimFullRequestTimeoutV1(lease),
    );
    const snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.full_request_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot
            .full_request_timeout_cancelled_response_connections,
    );

    lifecycle.mutex.lock();
    const retired =
        lifecycle.activeConnectionForLeaseLockedV1(
            lease,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    retired.work_retired = true;
    retired.response_retired = true;
    lifecycle.mutex.unlock();
    try lifecycle.finishConnectionV1(lease, false);
    try lifecycle.markStoppedV1();
}

test "finish drain does not replace a partial-receive abort" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer peer.close();
    const connection = try listener.accept();
    defer connection.stream.close();

    var lifecycle = try ManagedLifecycleV1.initV1(88);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(
            connection.stream.handle,
        );
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    const receipt = (try beginManagedDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    )).receipt;
    try std.testing.expectEqual(
        @as(u8, 1),
        receipt.decisions.abort_selected,
    );

    var timer = try std.time.Timer.start();
    while (timer.read() < 1) {}
    lifecycle.mutex.lock();
    const active =
        lifecycle.activeConnectionForLeaseLockedV1(
            lease,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    active.accept_timer = timer;
    active.full_request_timeout_ns = 1;
    active.full_request_timeout_retired = false;
    const watchdog_would_claim =
        fullRequestDeadlineExpiredForActiveV1(
            active,
            lifecycle.state,
        );
    const watchdog_remaining_ns =
        remainingDeadlineNsV1(
            active,
            lifecycle.state,
        );
    lifecycle.mutex.unlock();
    try std.testing.expect(!watchdog_would_claim);
    try std.testing.expectEqual(
        @as(?u64, null),
        watchdog_remaining_ns,
    );
    try std.testing.expect(
        !(try lifecycle.claimFullRequestTimeoutV1(lease)),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        lifecycle.snapshotV1()
            .full_request_timeout_signaled_connections,
    );

    lifecycle.mutex.lock();
    const retired =
        lifecycle.activeConnectionForLeaseLockedV1(
            lease,
        ) catch |err| {
            lifecycle.mutex.unlock();
            return err;
        };
    retired.full_request_timeout_retired = true;
    lifecycle.mutex.unlock();
    try lifecycle.finishConnectionV1(lease, false);
    try lifecycle.markStoppedV1();
}

test "concurrent drain classifies an expired deadline before finish" {
    var lifecycle = try ManagedConcurrentLifecycleV1.initV1(
        86,
        .{
            .worker_count = 1,
            .pending_connection_capacity = 1,
        },
    );
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.managed.beginConnectionV1(
            @intCast(323),
        );
    try setConnectionPhaseForTestV1(
        &lifecycle.managed,
        lease,
        .response_ready,
        true,
    );
    var timer = try std.time.Timer.start();
    while (timer.read() < 1) {}
    lifecycle.managed.mutex.lock();
    const active = lifecycle.managed
        .activeConnectionForLeaseLockedV1(
        lease,
    ) catch |err| {
        lifecycle.managed.mutex.unlock();
        return err;
    };
    active.accept_timer = timer;
    active.full_request_timeout_ns = 1;
    active.full_request_timeout_retired = false;
    lifecycle.running_high_watermark = 1;
    lifecycle.queue_enqueued_connections = 1;
    lifecycle.queue_dispatched_connections = 1;
    lifecycle.managed.mutex.unlock();
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };

    const receipt =
        try beginManagedConcurrentDrainWithPolicyV1(
            &lifecycle,
            &runtime,
            .finish_published,
        );
    try std.testing.expectEqual(
        @as(u8, 1),
        receipt.decisions.preexisting_stop,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        receipt.decisions.finish_selected,
    );
    const snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot
            .managed.full_request_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot
            .managed
            .full_request_timeout_cancelled_response_connections,
    );

    lifecycle.managed.mutex.lock();
    const retired = lifecycle.managed
        .activeConnectionForLeaseLockedV1(
        lease,
    ) catch |err| {
        lifecycle.managed.mutex.unlock();
        return err;
    };
    retired.work_retired = true;
    retired.response_retired = true;
    lifecycle.managed.mutex.unlock();
    try lifecycle.managed.finishConnectionV1(lease, false);
    try lifecycle.managed.markStoppedV1();
}

test "concurrent stopped drain remains an idempotent no-op receipt" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const running_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer running_peer.close();
    const running_connection = try listener.accept();
    defer running_connection.stream.close();
    const queued_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer queued_peer.close();
    const queued_connection = try listener.accept();

    var lifecycle = try ManagedConcurrentLifecycleV1.initV1(
        83,
        .{
            .worker_count = 1,
            .pending_connection_capacity = 1,
        },
    );
    try lifecycle.markReadyV1();
    const running_lease =
        try lifecycle.managed.beginConnectionV1(
            running_connection.stream.handle,
        );
    try setConnectionPhaseForTestV1(
        &lifecycle.managed,
        running_lease,
        .response_ready,
        true,
    );
    const queued_lease =
        try lifecycle.managed.beginQueuedConnectionV1(
            queued_connection.stream.handle,
            0,
            0,
            null,
        );
    lifecycle.managed.mutex.lock();
    lifecycle.queue[0] = .{
        .connection = queued_connection,
        .lease = queued_lease,
    };
    lifecycle.queue_len = 1;
    lifecycle.queue_high_watermark = 1;
    lifecycle.running_high_watermark = 1;
    lifecycle.queue_enqueued_connections = 2;
    lifecycle.queue_dispatched_connections = 1;
    lifecycle.managed.mutex.unlock();
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };

    const first = try beginManagedConcurrentDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    );
    try std.testing.expect(first.drain_was_new);
    try std.testing.expect(first.connection_actions_applied);
    try std.testing.expectEqual(
        @as(u8, 1),
        first.synchronously_retired_connections,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        first.pending_settlement_connections,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        first.phase_counts.queued,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        first.phase_counts.response_ready,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        first.decisions.abort_selected,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        first.decisions.finish_selected,
    );
    const pending =
        try inspectManagedConcurrentDrainV1(&lifecycle, &first);
    try std.testing.expect(!pending.settled);
    try std.testing.expectEqual(
        @as(u64, 1),
        pending.failed_since_linearization,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        pending.active_connections,
    );

    const escalated =
        try beginManagedConcurrentDrainWithPolicyV1(
            &lifecycle,
            &runtime,
            .cancel_active,
        );
    try std.testing.expect(escalated.policy_was_escalated);
    try std.testing.expect(escalated.connection_actions_applied);
    try std.testing.expectEqual(
        @as(u8, 1),
        escalated.decisions.abort_selected,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        lifecycle.snapshotV1()
            .managed.drain_cancelled_response_connections,
    );

    lifecycle.managed.mutex.lock();
    const active = lifecycle.managed
        .activeConnectionForLeaseLockedV1(
        running_lease,
    ) catch |err| {
        lifecycle.managed.mutex.unlock();
        return err;
    };
    active.work_retired = true;
    active.response_retired = true;
    lifecycle.managed.mutex.unlock();
    try lifecycle.managed.finishConnectionV1(
        running_lease,
        false,
    );
    try lifecycle.managed.markStoppedV1();

    const stopped = try beginManagedConcurrentDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .finish_published,
    );
    try std.testing.expect(!stopped.drain_was_new);
    try std.testing.expect(!stopped.connection_actions_applied);
    try std.testing.expectEqual(
        ManagedStateV1.stopped,
        stopped.state_at_linearization,
    );
    try std.testing.expectEqual(
        ManagedDrainPolicyV1.cancel_active,
        stopped.effective_policy,
    );
    try beginManagedConcurrentDrainV1(&lifecycle, &runtime);
    const inspection =
        try inspectManagedConcurrentDrainV1(&lifecycle, &first);
    try std.testing.expect(inspection.settled);
    try std.testing.expectEqual(
        @as(u64, 2),
        inspection.failed_since_linearization,
    );
}

test "managed admitted work is connection fenced and counted once" {
    const handle: std.net.Stream.Handle = @intCast(91);
    const stale_handle: std.net.Stream.Handle = @intCast(92);
    var lifecycle = try ManagedLifecycleV1.initV1(29);
    try lifecycle.markReadyV1();
    const connection_lease =
        try lifecycle.beginConnectionV1(handle);
    try lifecycle.markRequestHeadReceivedV1(connection_lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        connection_lease,
        null,
        0,
    );

    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 7,
        .handle_sha256 = [_]u8{0x71} ** 32,
    };
    var wrong_process_generation = connection_lease;
    wrong_process_generation.process_generation += 1;
    try std.testing.expectError(
        LifecycleError.InvalidGeneration,
        lifecycle.markRequestAdmittedV1(
            wrong_process_generation,
            identity,
        ),
    );
    var wrong_sequence = connection_lease;
    wrong_sequence.connection_sequence += 1;
    try std.testing.expectError(
        LifecycleError.ConnectionSequenceMismatch,
        lifecycle.markRequestAdmittedV1(
            wrong_sequence,
            identity,
        ),
    );
    var wrong_handle = connection_lease;
    wrong_handle.handle = stale_handle;
    try std.testing.expectError(
        LifecycleError.ConnectionHandleMismatch,
        lifecycle.markRequestAdmittedV1(
            wrong_handle,
            identity,
        ),
    );
    try std.testing.expectEqual(
        prepared_http.WorkDispositionV1.proceed,
        try lifecycle.markRequestAdmittedV1(
            connection_lease,
            identity,
        ),
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        lifecycle.snapshotV1().active_connection_phase,
    );

    var stale_identity = identity;
    stale_identity.sequence += 1;
    try std.testing.expectError(
        LifecycleError.WorkIdentityMismatch,
        lifecycle.markRequestAdmittedV1(
            connection_lease,
            stale_identity,
        ),
    );
    try std.testing.expectError(
        LifecycleError.WorkIdentityMismatch,
        lifecycle.retireActiveConnectionWorkV1(
            connection_lease,
            stale_identity,
        ),
    );

    lifecycle.mutex.lock();
    lifecycle.recordDrainWorkCancellationLockedV1(
        connection_lease,
        identity,
    ) catch |err| {
        lifecycle.mutex.unlock();
        return err;
    };
    lifecycle.recordDrainWorkCancellationLockedV1(
        connection_lease,
        identity,
    ) catch |err| {
        lifecycle.mutex.unlock();
        return err;
    };
    lifecycle.mutex.unlock();
    const cancellation_snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        cancellation_snapshot.drain_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        cancellation_snapshot.last_drain_cancelled_work_phase,
    );

    try lifecycle.retireActiveConnectionWorkV1(
        connection_lease,
        identity,
    );
    try lifecycle.finishConnectionV1(connection_lease, true);

    var recovery = try ManagedLifecycleV1.initV1(31);
    try recovery.markReadyV1();
    const recovery_lease =
        try recovery.beginConnectionV1(handle);
    try recovery.markRequestHeadReceivedV1(recovery_lease);
    try recovery.markRequestReceivedBeforeDeadlineV1(
        recovery_lease,
        null,
        0,
    );
    recovery.mutex.lock();
    const recovery_result = applyDrainWorkReceiptLockedV1(
        &recovery,
        .{
            .admission_was_open = true,
            .active_work = identity,
            .cancellation = .recovery_required,
        },
    );
    recovery.mutex.unlock();
    try std.testing.expectError(
        LifecycleError.WorkCancellationRecoveryRequired,
        recovery_result,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        recovery.snapshotV1().active_connection_phase,
    );
    try std.testing.expectError(
        LifecycleError.ConnectionInterrupted,
        recovery.finishConnectionV1(
            recovery_lease,
            false,
        ),
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        recovery.snapshotV1().active_connections,
    );
}

test "peer send close policy preserves by default and accounts exact cancellation" {
    var lifecycle = try ManagedLifecycleV1.initV1(43);
    try lifecycle.markReadyV1();

    const preserved_lease =
        try lifecycle.beginConnectionV1(@intCast(131));
    try lifecycle.markRequestHeadReceivedV1(preserved_lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        preserved_lease,
        null,
        0,
    );
    const preserved_identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 23,
        .handle_sha256 = [_]u8{0xc1} ** 32,
    };
    try std.testing.expectEqual(
        prepared_http.WorkDispositionV1.proceed,
        try lifecycle.markRequestAdmittedV1(
            preserved_lease,
            preserved_identity,
        ),
    );
    var wrong_identity = preserved_identity;
    wrong_identity.sequence += 1;
    try std.testing.expectError(
        LifecycleError.WorkIdentityMismatch,
        lifecycle.observePeerSendCloseV1(
            preserved_lease,
            wrong_identity,
            false,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        lifecycle.snapshotV1().peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        prepared_http.WorkCheckpointDispositionV1.proceed,
        try lifecycle.observePeerSendCloseV1(
            preserved_lease,
            preserved_identity,
            false,
        ),
    );
    try std.testing.expectEqual(
        prepared_http.WorkCheckpointDispositionV1.proceed,
        try lifecycle.observePeerSendCloseV1(
            preserved_lease,
            preserved_identity,
            false,
        ),
    );
    const preserved = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        preserved.peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        preserved.peer_send_close_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        preserved.last_peer_send_closed_phase,
    );
    try std.testing.expectEqual(
        prepared_http.WorkCheckpointDispositionV1.proceed,
        try lifecycle.validateWorkCheckpointV1(
            preserved_lease,
            preserved_identity,
        ),
    );
    try lifecycle.retireActiveConnectionWorkV1(
        preserved_lease,
        preserved_identity,
    );
    try lifecycle.finishConnectionV1(preserved_lease, true);

    const cancelled_lease =
        try lifecycle.beginConnectionV1(@intCast(137));
    try lifecycle.markRequestHeadReceivedV1(cancelled_lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        cancelled_lease,
        null,
        0,
    );
    const cancelled_identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 29,
        .handle_sha256 = [_]u8{0xc2} ** 32,
    };
    try std.testing.expectEqual(
        prepared_http.WorkDispositionV1.proceed,
        try lifecycle.markRequestAdmittedV1(
            cancelled_lease,
            cancelled_identity,
        ),
    );
    try std.testing.expectEqual(
        prepared_http.WorkCheckpointDispositionV1.peer_send_close,
        try lifecycle.observePeerSendCloseV1(
            cancelled_lease,
            cancelled_identity,
            true,
        ),
    );
    try std.testing.expectEqual(
        prepared_http.WorkCheckpointDispositionV1.peer_send_close,
        try lifecycle.observePeerSendCloseV1(
            cancelled_lease,
            cancelled_identity,
            true,
        ),
    );
    const cancellation: prepared_http.WorkCancellationReceiptV1 = .{
        .requested_cause = .peer_send_close,
        .winner = .peer_send_close,
        .outcome = .cancelled,
        .cancellation_was_new = true,
    };
    try lifecycle.recordWorkCancellationV1(
        cancelled_lease,
        cancelled_identity,
        cancellation,
    );
    try lifecycle.recordWorkCancellationV1(
        cancelled_lease,
        cancelled_identity,
        cancellation,
    );
    const cancelled = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 2),
        cancelled.peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        cancelled.peer_send_close_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        cancelled.last_peer_send_close_cancelled_work_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        cancelled.peer_reset_connections,
    );
    try std.testing.expectEqual(
        prepared_http.WorkCheckpointDispositionV1.peer_send_close,
        try lifecycle.validateWorkCheckpointV1(
            cancelled_lease,
            cancelled_identity,
        ),
    );
    try lifecycle.retireActiveConnectionWorkV1(
        cancelled_lease,
        cancelled_identity,
    );
    try lifecycle.finishConnectionV1(cancelled_lease, false);
    const final = lifecycle.snapshotV1();
    try std.testing.expectEqual(@as(u64, 1), final.completed_connections);
    try std.testing.expectEqual(@as(u64, 1), final.failed_connections);
    try std.testing.expectEqual(@as(u8, 0), final.active_connections);
}

test "peer send close receive classification is exact and cancellation free" {
    var lifecycle = try ManagedLifecycleV1.initV1(44);
    try lifecycle.markReadyV1();

    const zero_lease =
        try lifecycle.beginConnectionV1(@intCast(141));
    _ = try lifecycle.observePeerSendCloseDuringReceiveV1(
        zero_lease,
        0,
        null,
        0,
    );
    _ = try lifecycle.observePeerSendCloseDuringReceiveV1(
        zero_lease,
        0,
        null,
        0,
    );
    try std.testing.expect(
        try lifecycle.retireActiveConnectionReceiveV1(
            zero_lease,
            null,
            0,
        ),
    );
    try lifecycle.finishConnectionV1(zero_lease, false);

    const head_lease =
        try lifecycle.beginConnectionV1(@intCast(142));
    _ = try lifecycle.observePeerSendCloseDuringReceiveV1(
        head_lease,
        17,
        null,
        0,
    );
    try std.testing.expect(
        try lifecycle.retireActiveConnectionReceiveV1(
            head_lease,
            null,
            0,
        ),
    );
    try lifecycle.finishConnectionV1(head_lease, false);

    const body_lease =
        try lifecycle.beginConnectionV1(@intCast(143));
    try lifecycle.markRequestHeadReceivedV1(body_lease);
    _ = try lifecycle.observePeerSendCloseDuringReceiveV1(
        body_lease,
        193,
        null,
        0,
    );
    try lifecycle.markResponseReadyV1(body_lease);
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.proceed,
        try lifecycle.observePeerSendCloseAtResponseReadyV1(
            body_lease,
            true,
        ),
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.proceed,
        try lifecycle.markResponseWritingV1(body_lease),
    );
    try std.testing.expectEqual(
        cancellable_writer.DispositionV1.proceed,
        try lifecycle.observePeerSendCloseAtResponseWritingV1(
            body_lease,
            true,
        ),
    );
    try std.testing.expect(
        try lifecycle.markResponseWrittenV1(body_lease),
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.write_completed,
        try lifecycle.retireResponseV1(
            body_lease,
            .write_completed,
            null,
        ),
    );
    try lifecycle.finishConnectionV1(body_lease, true);

    const snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 3),
        snapshot.peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.peer_send_close_zero_request_bytes_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.peer_send_close_partial_request_head_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.peer_send_close_partial_request_body_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_head_received,
        snapshot.last_peer_send_close_receive_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.peer_send_close_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.peer_send_close_cancelled_response_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.peer_send_close_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        snapshot.peer_send_close_cancelled_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.completed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        snapshot.failed_connections,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        snapshot.active_connections,
    );
}

test "peer send close receive races retain exactly one lifecycle winner" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    const timeout_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer timeout_peer.close();
    const timeout_connection = try listener.accept();
    defer timeout_connection.stream.close();

    const drain_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer drain_peer.close();
    const drain_connection = try listener.accept();
    defer drain_connection.stream.close();

    var receive_timer = try std.time.Timer.start();
    waitForElapsedTimerForTestV1(&receive_timer, 1);
    var receive_timeout = try ManagedLifecycleV1.initV1(45);
    try receive_timeout.markReadyV1();
    const receive_timeout_lease =
        try receive_timeout.beginConnectionV1(
            timeout_connection.stream.handle,
        );
    try std.testing.expect(
        !(try receive_timeout.observePeerSendCloseDuringReceiveV1(
            receive_timeout_lease,
            0,
            &receive_timer,
            1,
        )),
    );
    try std.testing.expect(
        !(try receive_timeout.observePeerSendCloseDuringReceiveV1(
            receive_timeout_lease,
            0,
            &receive_timer,
            1,
        )),
    );
    const receive_timeout_snapshot =
        receive_timeout.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        receive_timeout_snapshot.receive_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.receiving_head,
        receive_timeout_snapshot.last_receive_timeout_signaled_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        receive_timeout_snapshot.peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        receive_timeout_snapshot
            .peer_send_close_zero_request_bytes_connections,
    );
    try receive_timeout.finishConnectionV1(
        receive_timeout_lease,
        false,
    );

    var full_request_timer = try std.time.Timer.start();
    var full_request_timeout = try ManagedLifecycleV1.initV1(46);
    try full_request_timeout.markReadyV1();
    const full_request_timeout_lease =
        try full_request_timeout
            .beginConnectionWithFullRequestTimeoutV1(
            timeout_connection.stream.handle,
            0,
            1,
            full_request_timer,
        );
    try full_request_timeout.markRequestHeadReceivedV1(
        full_request_timeout_lease,
    );
    waitForElapsedTimerForTestV1(&full_request_timer, 1);
    try std.testing.expect(
        !(try full_request_timeout
            .observePeerSendCloseDuringReceiveV1(
            full_request_timeout_lease,
            64,
            null,
            0,
        )),
    );
    try std.testing.expect(
        !(try full_request_timeout
            .observePeerSendCloseDuringReceiveV1(
            full_request_timeout_lease,
            64,
            null,
            0,
        )),
    );
    const full_request_timeout_snapshot =
        full_request_timeout.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        full_request_timeout_snapshot
            .full_request_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_head_received,
        full_request_timeout_snapshot
            .last_full_request_timeout_signaled_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        full_request_timeout_snapshot.peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        full_request_timeout_snapshot
            .peer_send_close_partial_request_body_connections,
    );
    try full_request_timeout.finishConnectionV1(
        full_request_timeout_lease,
        false,
    );

    var fin_timer = try std.time.Timer.start();
    var fin_first = try ManagedLifecycleV1.initV1(47);
    try fin_first.markReadyV1();
    const fin_first_lease =
        try fin_first.beginConnectionWithFullRequestTimeoutV1(
            drain_connection.stream.handle,
            maximum_receive_timeout_ns / 2,
            maximum_full_request_timeout_ns,
            fin_timer,
        );
    try fin_first.markRequestHeadReceivedV1(fin_first_lease);
    try std.testing.expect(
        try fin_first.observePeerSendCloseDuringReceiveV1(
            fin_first_lease,
            64,
            &fin_timer,
            maximum_receive_timeout_ns / 2,
        ),
    );
    try std.testing.expect(
        try fin_first.observePeerSendCloseDuringReceiveV1(
            fin_first_lease,
            64,
            &fin_timer,
            maximum_receive_timeout_ns / 2,
        ),
    );
    try std.testing.expect(
        !(try fin_first.signalActiveConnectionForReceiveTimeoutV1(
            fin_first_lease,
        )),
    );
    try std.testing.expect(
        !(try fin_first.claimFullRequestTimeoutV1(
            fin_first_lease,
        )),
    );
    fin_first.mutex.lock();
    const post_fin_drain =
        fin_first.signalActiveConnectionForDrainLockedV1() catch |err| {
            fin_first.mutex.unlock();
            return err;
        };
    fin_first.mutex.unlock();
    try std.testing.expect(post_fin_drain);
    try fin_first.markResponseReadyV1(fin_first_lease);
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.proceed,
        try fin_first.observePeerSendCloseAtResponseReadyV1(
            fin_first_lease,
            true,
        ),
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteDispositionV1.proceed,
        try fin_first.markResponseWritingV1(fin_first_lease),
    );
    try std.testing.expectEqual(
        cancellable_writer.DispositionV1.proceed,
        try fin_first.observePeerSendCloseAtResponseWritingV1(
            fin_first_lease,
            true,
        ),
    );
    try std.testing.expect(
        try fin_first.markResponseWrittenV1(fin_first_lease),
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.write_completed,
        try fin_first.retireResponseV1(
            fin_first_lease,
            .write_completed,
            null,
        ),
    );
    try fin_first.finishConnectionV1(fin_first_lease, true);
    const fin_first_snapshot = fin_first.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        fin_first_snapshot.peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        fin_first_snapshot
            .peer_send_close_partial_request_body_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fin_first_snapshot.receive_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fin_first_snapshot.full_request_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fin_first_snapshot.drain_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fin_first_snapshot.peer_send_close_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fin_first_snapshot
            .peer_send_close_cancelled_response_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fin_first_snapshot
            .peer_send_close_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        fin_first_snapshot
            .peer_send_close_cancelled_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        fin_first_snapshot.completed_connections,
    );

    var drain_first = try ManagedLifecycleV1.initV1(48);
    try drain_first.markReadyV1();
    const drain_first_lease =
        try drain_first.beginConnectionV1(
            drain_connection.stream.handle,
        );
    try drain_first.markRequestHeadReceivedV1(
        drain_first_lease,
    );
    drain_first.mutex.lock();
    const drain_won =
        drain_first.signalActiveConnectionForDrainLockedV1() catch |err| {
            drain_first.mutex.unlock();
            return err;
        };
    drain_first.mutex.unlock();
    try std.testing.expect(drain_won);
    try std.testing.expect(
        !(try drain_first.observePeerSendCloseDuringReceiveV1(
            drain_first_lease,
            64,
            null,
            0,
        )),
    );
    try std.testing.expect(
        !(try drain_first.observePeerSendCloseDuringReceiveV1(
            drain_first_lease,
            64,
            null,
            0,
        )),
    );
    const drain_first_snapshot = drain_first.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        drain_first_snapshot.drain_signaled_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_head_received,
        drain_first_snapshot.last_drain_signaled_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        drain_first_snapshot.peer_send_closed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        drain_first_snapshot
            .peer_send_close_partial_request_body_connections,
    );
    try drain_first.finishConnectionV1(
        drain_first_lease,
        false,
    );
}

test "managed publication forwards the exact connection owner" {
    const PublicationObserverV1 = struct {
        publication: ?prepared_http.WorkPublicationV1 = null,

        fn admittedOpaque(
            context: *anyopaque,
            identity: prepared_http.WorkIdentityV1,
        ) anyerror!prepared_http.WorkDispositionV1 {
            _ = context;
            _ = identity;
            return .proceed;
        }

        fn publishedOpaque(
            context: *anyopaque,
            publication: prepared_http.WorkPublicationV1,
        ) void {
            const self: *@This() =
                @ptrCast(@alignCast(context));
            self.publication = publication;
        }

        fn retiredOpaque(
            context: *anyopaque,
            identity: prepared_http.WorkIdentityV1,
        ) void {
            _ = context;
            _ = identity;
        }

        fn control(
            self: *@This(),
        ) prepared_http.RequestWorkControlV1 {
            return .{
                .context = self,
                .admitted_fn = admittedOpaque,
                .retired_fn = retiredOpaque,
                .transport_owner = .{
                    .process_generation = 1,
                    .connection_sequence = 2,
                    .slot_index = 3,
                    .slot_generation = 4,
                },
                .published_fn = publishedOpaque,
            };
        }
    };

    var lifecycle = try ManagedLifecycleV1.initV1(37);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(111));
    try lifecycle.markRequestHeadReceivedV1(lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        lease,
        null,
        0,
    );
    var observer: PublicationObserverV1 = .{};
    var work_control: ManagedRequestWorkControlV1 = .{
        .lifecycle = &lifecycle,
        .lease = lease,
        .peer_reset_poll_timeout_ms = 0,
        .observer = observer.control(),
    };
    const control = work_control.control();
    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 19,
        .handle_sha256 = [_]u8{0xa1} ** 32,
    };
    try std.testing.expectEqual(
        prepared_http.WorkDispositionV1.proceed,
        try control.admitted_fn(
            control.context,
            identity,
        ),
    );
    const request_sha256 = [_]u8{0xa2} ** 32;
    control.published_fn.?(
        control.context,
        .{
            .identity = identity,
            .request_sha256 = request_sha256,
            .transport_owner = control.transport_owner,
        },
    );
    try std.testing.expectEqualDeep(
        prepared_http.WorkPublicationV1{
            .identity = identity,
            .request_sha256 = request_sha256,
            .transport_owner = transportOwnerTokenV1(
                lease,
            ),
        },
        observer.publication.?,
    );
    control.retired_fn(control.context, identity);
    try lifecycle.finishConnectionV1(lease, true);
}

test "managed admission rejection forwards exact connection owner" {
    const RejectionObserverV1 = struct {
        rejection: ?prepared_http.RequestAdmissionRejectionV1 =
            null,
        admitted_calls: u8 = 0,
        rejected_calls: u8 = 0,
        retired_calls: u8 = 0,

        fn admittedOpaque(
            context: *anyopaque,
            identity: prepared_http.WorkIdentityV1,
        ) anyerror!prepared_http.WorkDispositionV1 {
            const self: *@This() =
                @ptrCast(@alignCast(context));
            _ = identity;
            self.admitted_calls += 1;
            return .proceed;
        }

        fn rejectedOpaque(
            context: *anyopaque,
            rejection: prepared_http.RequestAdmissionRejectionV1,
        ) void {
            const self: *@This() =
                @ptrCast(@alignCast(context));
            self.rejected_calls += 1;
            self.rejection = rejection;
        }

        fn retiredOpaque(
            context: *anyopaque,
            identity: prepared_http.WorkIdentityV1,
        ) void {
            const self: *@This() =
                @ptrCast(@alignCast(context));
            _ = identity;
            self.retired_calls += 1;
        }

        fn control(
            self: *@This(),
        ) prepared_http.RequestWorkControlV1 {
            return .{
                .context = self,
                .admitted_fn = admittedOpaque,
                .retired_fn = retiredOpaque,
                .transport_owner = .{
                    .process_generation = 1,
                    .connection_sequence = 2,
                    .slot_index = 3,
                    .slot_generation = 4,
                },
                .admission_rejected_fn = rejectedOpaque,
            };
        }
    };

    var lifecycle = try ManagedLifecycleV1.initV1(61);
    try lifecycle.markReadyV1();
    const lease =
        try lifecycle.beginConnectionV1(@intCast(127));
    try lifecycle.markRequestHeadReceivedV1(lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        lease,
        null,
        0,
    );
    var observer: RejectionObserverV1 = .{};
    var work_control: ManagedRequestWorkControlV1 = .{
        .lifecycle = &lifecycle,
        .lease = lease,
        .peer_reset_poll_timeout_ms = 0,
        .observer = observer.control(),
    };
    const control = work_control.control();
    const request_sha256 = [_]u8{0xb2} ** 32;
    const cause: prepared_http.AdmissionRejectionCauseV1 =
        .{ .scheduler = .{
            .event_abi_version = 1,
            .scheduler_epoch = 67,
            .event_sequence = 71,
            .reason = .deadline_infeasible,
            .event_sha256 = [_]u8{0xb3} ** 32,
        } };
    control.admission_rejected_fn.?(
        control.context,
        .{
            .request_sha256 = request_sha256,
            .cause = cause,
            .transport_owner = null,
        },
    );

    try std.testing.expect(!work_control.observer_admitted);
    try std.testing.expectEqual(
        @as(u8, 1),
        observer.rejected_calls,
    );
    try std.testing.expectEqualDeep(
        prepared_http.RequestAdmissionRejectionV1{
            .request_sha256 = request_sha256,
            .cause = cause,
            .transport_owner = transportOwnerTokenV1(
                lease,
            ),
        },
        observer.rejection.?,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        observer.admitted_calls,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        observer.retired_calls,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_received,
        lifecycle.snapshotV1().active_connection_phase,
    );
    try lifecycle.finishConnectionV1(lease, true);
}

test "managed drain routes work to the exact published transport owner" {
    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(32, 2);
    try lifecycle.markReadyV1();
    const first_lease =
        try lifecycle.beginConnectionV1(@intCast(101));
    const second_lease =
        try lifecycle.beginConnectionV1(@intCast(102));
    try lifecycle.markRequestHeadReceivedV1(first_lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        first_lease,
        null,
        0,
    );
    try lifecycle.markRequestHeadReceivedV1(second_lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        second_lease,
        null,
        0,
    );

    var work_control: ManagedRequestWorkControlV1 = .{
        .lifecycle = &lifecycle,
        .lease = second_lease,
        .peer_reset_poll_timeout_ms = 0,
        .observer = null,
    };
    const published_control = work_control.control();
    try std.testing.expectEqualDeep(
        transportOwnerTokenV1(second_lease),
        published_control.transport_owner.?,
    );

    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 17,
        .handle_sha256 = [_]u8{0x91} ** 32,
    };
    const receipt: prepared_http.DrainReceiptV1 = .{
        .admission_was_open = true,
        .active_work = identity,
        .transport_owner = published_control.transport_owner,
        .cancellation = .cancelled,
        .cancellation_winner = .drain,
        .cancellation_was_new = true,
    };
    try applyDrainWorkReceiptForTestV1(
        &lifecycle,
        receipt,
    );
    try applyDrainWorkReceiptForTestV1(
        &lifecycle,
        receipt,
    );

    lifecycle.mutex.lock();
    const routed_exactly = blk: {
        const first =
            lifecycle.activeConnectionForLeaseLockedV1(first_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        const second =
            lifecycle.activeConnectionForLeaseLockedV1(second_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        break :blk first.phase == .request_received and
            first.work_identity == null and
            !first.drain_work_cancelled and
            second.phase == .request_admitted and
            second.work_identity != null and
            std.meta.eql(second.work_identity.?, identity) and
            second.drain_work_cancelled;
    };
    lifecycle.mutex.unlock();
    try std.testing.expect(routed_exactly);

    const snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        snapshot.drain_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        snapshot.last_drain_cancelled_work_phase,
    );

    try lifecycle.retireActiveConnectionWorkV1(
        second_lease,
        identity,
    );
    try lifecycle.finishConnectionV1(first_lease, false);
    try lifecycle.finishConnectionV1(second_lease, false);
}

test "managed drain rejects stale or missing transport owners before mutation" {
    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(33, 2);
    try lifecycle.markReadyV1();
    const first_lease =
        try lifecycle.beginConnectionV1(@intCast(111));
    const second_lease =
        try lifecycle.beginConnectionV1(@intCast(112));
    try lifecycle.markRequestHeadReceivedV1(first_lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        first_lease,
        null,
        0,
    );
    try lifecycle.markRequestHeadReceivedV1(second_lease);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        second_lease,
        null,
        0,
    );

    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 19,
        .handle_sha256 = [_]u8{0x93} ** 32,
    };
    const owner = transportOwnerTokenV1(second_lease);

    try std.testing.expectError(
        LifecycleError.MissingTransportOwner,
        applyDrainWorkReceiptForTestV1(
            &lifecycle,
            .{
                .admission_was_open = true,
                .active_work = identity,
            },
        ),
    );

    var wrong_process_generation = owner;
    wrong_process_generation.process_generation += 1;
    try std.testing.expectError(
        LifecycleError.InvalidGeneration,
        applyDrainWorkReceiptForTestV1(
            &lifecycle,
            .{
                .admission_was_open = true,
                .active_work = identity,
                .transport_owner = wrong_process_generation,
            },
        ),
    );

    var wrong_slot_generation = owner;
    wrong_slot_generation.slot_generation += 1;
    try std.testing.expectError(
        LifecycleError.ConnectionSlotGenerationMismatch,
        applyDrainWorkReceiptForTestV1(
            &lifecycle,
            .{
                .admission_was_open = true,
                .active_work = identity,
                .transport_owner = wrong_slot_generation,
            },
        ),
    );

    var wrong_connection_sequence = owner;
    wrong_connection_sequence.connection_sequence += 1;
    try std.testing.expectError(
        LifecycleError.ConnectionSequenceMismatch,
        applyDrainWorkReceiptForTestV1(
            &lifecycle,
            .{
                .admission_was_open = true,
                .active_work = identity,
                .transport_owner = wrong_connection_sequence,
            },
        ),
    );

    try std.testing.expectError(
        LifecycleError.TransportOwnerMismatch,
        applyDrainWorkReceiptForTestV1(
            &lifecycle,
            .{
                .admission_was_open = true,
                .transport_owner = owner,
            },
        ),
    );

    lifecycle.mutex.lock();
    const remained_unbound = blk: {
        const first =
            lifecycle.activeConnectionForLeaseLockedV1(first_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        const second =
            lifecycle.activeConnectionForLeaseLockedV1(second_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        break :blk first.phase == .request_received and
            first.work_identity == null and
            second.phase == .request_received and
            second.work_identity == null;
    };
    lifecycle.mutex.unlock();
    try std.testing.expect(remained_unbound);
    try std.testing.expectEqual(
        @as(u64, 0),
        lifecycle.snapshotV1().drain_cancelled_work_connections,
    );

    try lifecycle.finishConnectionV1(first_lease, false);
    try lifecycle.finishConnectionV1(second_lease, false);
}

test "managed receive timeout is fenced and drain has one winner" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer peer.close();
    const connection = try listener.accept();
    defer connection.stream.close();

    const stale_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer stale_peer.close();
    const stale_connection = try listener.accept();
    defer stale_connection.stream.close();

    var lifecycle = try ManagedLifecycleV1.initV1(19);
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try lifecycle.markReadyV1();
    const lease = try lifecycle.beginConnectionV1(
        connection.stream.handle,
    );
    var wrong_process_generation = lease;
    wrong_process_generation.process_generation += 1;
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            wrong_process_generation,
        )),
    );
    var wrong_sequence = lease;
    wrong_sequence.connection_sequence += 1;
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            wrong_sequence,
        )),
    );
    var wrong_handle = lease;
    wrong_handle.handle = stale_connection.stream.handle;
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            wrong_handle,
        )),
    );
    try lifecycle.markRequestHeadReceivedV1(lease);
    try std.testing.expect(
        try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            lease,
        ),
    );
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            lease,
        )),
    );
    try std.testing.expect(
        try beginManagedDrainV1(&lifecycle, &runtime),
    );
    try std.testing.expectEqualDeep(
        ManagedSnapshotV1{
            .process_generation = 19,
            .state = .draining,
            .accepted_connections = 1,
            .completed_connections = 0,
            .failed_connections = 0,
            .active_connections = 1,
            .drain_signaled_connections = 0,
            .receive_timeout_signaled_connections = 1,
            .active_connection_phase = .request_head_received,
            .last_drain_signaled_phase = .none,
            .last_receive_timeout_signaled_phase = .request_head_received,
        },
        lifecycle.snapshotV1(),
    );
    try lifecycle.finishConnectionV1(lease, false);
    try lifecycle.markStoppedV1();

    var completed = try ManagedLifecycleV1.initV1(21);
    try completed.markReadyV1();
    const completed_lease = try completed.beginConnectionV1(
        connection.stream.handle,
    );
    try completed.markRequestHeadReceivedV1(completed_lease);
    try completed.markRequestReceivedBeforeDeadlineV1(
        completed_lease,
        null,
        0,
    );
    try std.testing.expect(
        !(try completed.signalActiveConnectionForReceiveTimeoutV1(
            completed_lease,
        )),
    );
    try completed.finishConnectionV1(completed_lease, true);
    const completed_snapshot = completed.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        completed_snapshot.completed_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        completed_snapshot.receive_timeout_signaled_connections,
    );

    var drain_first = try ManagedLifecycleV1.initV1(22);
    var drain_first_runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try drain_first.markReadyV1();
    const drain_first_lease = try drain_first.beginConnectionV1(
        stale_connection.stream.handle,
    );
    try drain_first.markRequestHeadReceivedV1(drain_first_lease);
    try std.testing.expect(
        try beginManagedDrainV1(
            &drain_first,
            &drain_first_runtime,
        ),
    );
    try std.testing.expect(
        !(try drain_first.signalActiveConnectionForReceiveTimeoutV1(
            drain_first_lease,
        )),
    );
    const drain_first_snapshot = drain_first.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        drain_first_snapshot.drain_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        drain_first_snapshot.receive_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.none,
        drain_first_snapshot.last_receive_timeout_signaled_phase,
    );
    try drain_first.finishConnectionV1(drain_first_lease, false);
    try drain_first.markStoppedV1();
}

test "managed receive deadline is absolute across the HTTP head" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    const head_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer head_peer.close();
    const head_connection = try listener.accept();
    defer head_connection.stream.close();

    var head_timer = try std.time.Timer.start();
    std.Thread.sleep(2 * minimum_receive_timeout_ns);
    var head_lifecycle = try ManagedLifecycleV1.initV1(23);
    try head_lifecycle.markReadyV1();
    const head_lease = try head_lifecycle.beginConnectionV1(
        head_connection.stream.handle,
    );
    try std.testing.expectError(
        LifecycleError.ConnectionInterrupted,
        head_lifecycle.markRequestHeadReceivedBeforeDeadlineV1(
            head_lease,
            &head_timer,
            minimum_receive_timeout_ns,
        ),
    );
    const head_snapshot = head_lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        head_snapshot.receive_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.receiving_head,
        head_snapshot.last_receive_timeout_signaled_phase,
    );
    try head_lifecycle.finishConnectionV1(head_lease, false);

    const body_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer body_peer.close();
    const body_connection = try listener.accept();
    defer body_connection.stream.close();

    const body_timeout_ns = std.time.ns_per_s;
    const before_head_ns = 600 * std.time.ns_per_ms;
    const after_head_ns = 500 * std.time.ns_per_ms;
    var body_timer = try std.time.Timer.start();
    var body_lifecycle = try ManagedLifecycleV1.initV1(24);
    try body_lifecycle.markReadyV1();
    const body_lease = try body_lifecycle.beginConnectionV1(
        body_connection.stream.handle,
    );
    std.Thread.sleep(before_head_ns);
    try body_lifecycle.markRequestHeadReceivedBeforeDeadlineV1(
        body_lease,
        &body_timer,
        body_timeout_ns,
    );
    std.Thread.sleep(after_head_ns);
    try std.testing.expectError(
        LifecycleError.ConnectionInterrupted,
        body_lifecycle.markRequestReceivedBeforeDeadlineV1(
            body_lease,
            &body_timer,
            body_timeout_ns,
        ),
    );
    const body_snapshot = body_lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        body_snapshot.receive_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_head_received,
        body_snapshot.last_receive_timeout_signaled_phase,
    );
    try body_lifecycle.finishConnectionV1(body_lease, false);

    const retired_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer retired_peer.close();
    const retired_connection = try listener.accept();
    defer retired_connection.stream.close();

    var retired_timer = try std.time.Timer.start();
    var retired_lifecycle = try ManagedLifecycleV1.initV1(25);
    try retired_lifecycle.markReadyV1();
    const retired_lease = try retired_lifecycle.beginConnectionV1(
        retired_connection.stream.handle,
    );
    try std.testing.expect(
        try retired_lifecycle.retireActiveConnectionReceiveV1(
            retired_lease,
            &retired_timer,
            maximum_receive_timeout_ns,
        ),
    );
    var retired_runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try std.testing.expect(
        try beginManagedDrainV1(
            &retired_lifecycle,
            &retired_runtime,
        ),
    );
    try std.testing.expect(
        !(try retired_lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            retired_lease,
        )),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        retired_lifecycle.snapshotV1().receive_timeout_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        retired_lifecycle.snapshotV1().drain_signaled_connections,
    );
    try retired_lifecycle.finishConnectionV1(retired_lease, false);
    try retired_lifecycle.markStoppedV1();

    const expired_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer expired_peer.close();
    const expired_connection = try listener.accept();
    defer expired_connection.stream.close();

    var expired_timer = try std.time.Timer.start();
    std.Thread.sleep(2 * minimum_receive_timeout_ns);
    var expired_lifecycle = try ManagedLifecycleV1.initV1(26);
    try expired_lifecycle.markReadyV1();
    const expired_lease = try expired_lifecycle.beginConnectionV1(
        expired_connection.stream.handle,
    );
    try std.testing.expect(
        !(try expired_lifecycle.retireActiveConnectionReceiveV1(
            expired_lease,
            &expired_timer,
            minimum_receive_timeout_ns,
        )),
    );
    try std.testing.expect(
        !(try expired_lifecycle.retireActiveConnectionReceiveV1(
            expired_lease,
            &expired_timer,
            minimum_receive_timeout_ns,
        )),
    );
    try std.testing.expect(
        !(try expired_lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            expired_lease,
        )),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        expired_lifecycle.snapshotV1().receive_timeout_signaled_connections,
    );
    try expired_lifecycle.finishConnectionV1(expired_lease, false);
}

test "managed lifecycle tracks two live connection slots independently" {
    try std.testing.expectEqual(
        @as(u8, 8),
        @intFromEnum(ManagedConnectionPhaseV1.queued),
    );

    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(51, 2);
    try lifecycle.markReadyV1();
    const first_lease =
        try lifecycle.beginConnectionV1(@intCast(201));
    const second_lease =
        try lifecycle.beginConnectionV1(@intCast(202));

    try std.testing.expect(
        first_lease.slot_index != second_lease.slot_index,
    );
    try lifecycle.markRequestHeadReceivedV1(first_lease);
    try setConnectionPhaseForTestV1(
        &lifecycle,
        second_lease,
        .queued,
        false,
    );

    const live_snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(@as(u8, 2), live_snapshot.connection_capacity);
    try std.testing.expectEqual(@as(u64, 2), live_snapshot.accepted_connections);
    try std.testing.expectEqual(@as(u8, 2), live_snapshot.active_connections);
    try std.testing.expectEqual(@as(u8, 1), live_snapshot.queued_connections);
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.none,
        live_snapshot.active_connection_phase,
    );

    lifecycle.mutex.lock();
    const first_phase = blk: {
        const first =
            lifecycle.activeConnectionForLeaseLockedV1(first_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        break :blk first.phase;
    };
    const second_phase = blk: {
        const second =
            lifecycle.activeConnectionForLeaseLockedV1(second_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        break :blk second.phase;
    };
    lifecycle.mutex.unlock();
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_head_received,
        first_phase,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.queued,
        second_phase,
    );

    try lifecycle.finishConnectionV1(first_lease, true);
    try lifecycle.finishConnectionV1(second_lease, false);
    const retired_snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(@as(u8, 0), retired_snapshot.active_connections);
    try std.testing.expectEqual(@as(u64, 1), retired_snapshot.completed_connections);
    try std.testing.expectEqual(@as(u64, 1), retired_snapshot.failed_connections);
}

test "managed lifecycle enforces configured fixed slot capacity" {
    try std.testing.expectError(
        LifecycleError.InvalidConnectionCapacity,
        ManagedLifecycleV1.initWithConnectionCapacityV1(52, 0),
    );
    try std.testing.expectError(
        LifecycleError.InvalidConnectionCapacity,
        ManagedLifecycleV1.initWithConnectionCapacityV1(
            52,
            maximum_managed_connection_slots_v1 + 1,
        ),
    );
    var maximum =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(
            52,
            maximum_managed_connection_slots_v1,
        );
    try std.testing.expectEqual(
        maximum_managed_connection_slots_v1,
        maximum.snapshotV1().connection_capacity,
    );

    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(53, 2);
    try lifecycle.markReadyV1();
    const first_lease =
        try lifecycle.beginConnectionV1(@intCast(211));
    const second_lease =
        try lifecycle.beginConnectionV1(@intCast(212));
    try std.testing.expectError(
        LifecycleError.ConnectionAlreadyActive,
        lifecycle.beginConnectionV1(@intCast(213)),
    );

    try lifecycle.finishConnectionV1(first_lease, false);
    const replacement_lease =
        try lifecycle.beginConnectionV1(@intCast(213));
    try std.testing.expectEqual(
        first_lease.slot_index,
        replacement_lease.slot_index,
    );
    try std.testing.expect(
        replacement_lease.slot_generation >
            first_lease.slot_generation,
    );
    try lifecycle.finishConnectionV1(second_lease, false);
    try lifecycle.finishConnectionV1(replacement_lease, false);
}

test "managed lifecycle rejects a stale lease after slot reuse" {
    const reused_handle: std.net.Stream.Handle = @intCast(221);
    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(54, 1);
    try lifecycle.markReadyV1();
    const stale_lease =
        try lifecycle.beginConnectionV1(reused_handle);
    try lifecycle.finishConnectionV1(stale_lease, false);

    const current_lease =
        try lifecycle.beginConnectionV1(reused_handle);
    try std.testing.expectEqual(
        stale_lease.slot_index,
        current_lease.slot_index,
    );
    try std.testing.expectError(
        LifecycleError.ConnectionSlotGenerationMismatch,
        lifecycle.retireFullRequestTimeoutV1(stale_lease),
    );
    try std.testing.expectError(
        LifecycleError.ConnectionSlotGenerationMismatch,
        lifecycle.finishConnectionV1(stale_lease, false),
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        lifecycle.snapshotV1().active_connections,
    );
    try lifecycle.finishConnectionV1(current_lease, true);
}

test "managed drain signals every occupied connection slot" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    const first_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer first_peer.close();
    const first_connection = try listener.accept();
    defer first_connection.stream.close();

    const second_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer second_peer.close();
    const second_connection = try listener.accept();
    defer second_connection.stream.close();

    var lifecycle =
        try ManagedLifecycleV1.initWithConnectionCapacityV1(55, 2);
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try lifecycle.markReadyV1();
    const first_lease = try lifecycle.beginConnectionV1(
        first_connection.stream.handle,
    );
    const second_lease = try lifecycle.beginConnectionV1(
        second_connection.stream.handle,
    );
    try setConnectionPhaseForTestV1(
        &lifecycle,
        second_lease,
        .queued,
        false,
    );

    try std.testing.expect(
        try beginManagedDrainV1(&lifecycle, &runtime),
    );
    const drain_snapshot = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 2),
        drain_snapshot.drain_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        drain_snapshot.queued_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.queued,
        drain_snapshot.last_drain_signaled_phase,
    );

    lifecycle.mutex.lock();
    const both_signaled = blk: {
        const first =
            lifecycle.activeConnectionForLeaseLockedV1(first_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        const second =
            lifecycle.activeConnectionForLeaseLockedV1(second_lease) catch |err| {
                lifecycle.mutex.unlock();
                return err;
            };
        break :blk first.drain_signaled and
            first.receive_retired and
            second.drain_signaled and
            second.receive_retired;
    };
    lifecycle.mutex.unlock();
    try std.testing.expect(both_signaled);

    try lifecycle.finishConnectionV1(first_lease, false);
    try lifecycle.finishConnectionV1(second_lease, false);
    try lifecycle.markStoppedV1();
}

test "detached close errors still release observer ownership" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer peer.close();
    const connection = try listener.accept();

    var lifecycle = try ManagedConcurrentLifecycleV1.initV1(
        92,
        .{
            .worker_count = 1,
            .pending_connection_capacity = 1,
        },
    );
    try lifecycle.markReadyV1();
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    _ = try beginManagedConcurrentDrainWithPolicyV1(
        &lifecycle,
        &runtime,
        .cancel_active,
    );

    var observer: DetachedBatchObserverTestV1 = .{};
    var batch: ManagedConcurrentDetachedBatchV1 = .{};
    lifecycle.managed.mutex.lock();
    lifecycle.observer = observer.observer();
    batch.appendConnection(
        &lifecycle,
        connection,
        .{
            .process_generation = 93,
            .connection_sequence = 1,
            .slot_index = 0,
            .slot_generation = 1,
            .handle = connection.stream.handle,
        },
    );
    batch.appendEvent(lifecycle.captureEventLockedV1(.{
        .ordinal = 1,
        .kind = .queued_failure,
        .queued_connections = 0,
        .running_connections = 0,
    }));
    lifecycle.managed.mutex.unlock();

    try std.testing.expectEqual(
        @as(u8, 1),
        lifecycle.detached_close_in_flight,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        lifecycle.observer_in_flight,
    );
    try std.testing.expectError(
        LifecycleError.InvalidGeneration,
        batch.release(&lifecycle),
    );
    lifecycle.managed.mutex.lock();
    const detached_close_in_flight =
        lifecycle.detached_close_in_flight;
    const observer_in_flight =
        lifecycle.observer_in_flight;
    lifecycle.observer = null;
    lifecycle.managed.mutex.unlock();
    try std.testing.expectEqual(
        @as(u8, 0),
        detached_close_in_flight,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        observer_in_flight,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        observer.observed,
    );
    try lifecycle.managed.markStoppedV1();
}

test "concurrent accept wait is bounded and restores caller listener mode" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(
            Error.ConcurrentListenerModeUnsupported,
            ManagedConcurrentListenerModeV1.enable(
                listener.stream.handle,
            ),
        );
        return;
    }
    const original_flags = if (builtin.os.tag == .windows)
        null
    else
        try std.posix.fcntl(
            listener.stream.handle,
            std.posix.F.GETFL,
            0,
        );
    const listener_mode =
        try ManagedConcurrentListenerModeV1.enable(
            listener.stream.handle,
        );
    var mode_restored = false;
    defer if (!mode_restored)
        listener_mode.restore(
            listener.stream.handle,
        ) catch unreachable;

    var lifecycle = try ManagedConcurrentLifecycleV1.initV1(
        56,
        .{
            .worker_count = 1,
            .pending_connection_capacity = 1,
        },
    );
    try lifecycle.markReadyV1();
    var wait_entered: std.Thread.ResetEvent = .{};
    var context: ManagedAcceptFallbackTestContextV1 = .{
        .lifecycle = &lifecycle,
        .wait_entered = &wait_entered,
    };
    const state_thread = try std.Thread.spawn(
        .{},
        ManagedAcceptFallbackTestContextV1.failAfterWaitEntered,
        .{&context},
    );
    const timer = try std.time.Timer.start();
    try std.testing.expect(
        !(try waitForManagedConcurrentAcceptWithBarrierV1(
            &listener,
            &lifecycle,
            &wait_entered,
        )),
    );
    state_thread.join();
    try std.testing.expect(
        timer.read() < 5 * std.time.ns_per_s,
    );
    try listener_mode.restore(
        listener.stream.handle,
    );
    mode_restored = true;
    if (original_flags) |expected_flags| {
        try std.testing.expectEqual(
            expected_flags,
            try std.posix.fcntl(
                listener.stream.handle,
                std.posix.F.GETFL,
                0,
            ),
        );
    }

    lifecycle.managed.mutex.lock();
    lifecycle.managed.state = .ready;
    lifecycle.managed.mutex.unlock();
    const peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer peer.close();
    const connection = try listener.accept();
    connection.stream.close();
}

test "concurrent drain receipt is exact and stale owners are rejected" {
    var lifecycle = try ManagedConcurrentLifecycleV1.initV1(
        57,
        .{
            .worker_count = 1,
            .pending_connection_capacity = 1,
        },
    );
    try lifecycle.markReadyV1();
    const lease = try lifecycle.managed.beginConnectionV1(
        @intCast(231),
    );
    lifecycle.queue_enqueued_connections = 1;
    lifecycle.queue_dispatched_connections = 1;
    lifecycle.running_high_watermark = 1;
    try lifecycle.managed.markRequestHeadReceivedV1(lease);
    try lifecycle.managed.markRequestReceivedBeforeDeadlineV1(
        lease,
        null,
        0,
    );
    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 31,
        .handle_sha256 = [_]u8{0xA1} ** 32,
    };
    _ = try lifecycle.managed.markRequestAdmittedV1(
        lease,
        identity,
    );
    const receipt: prepared_http.DrainReceiptV1 = .{
        .admission_was_open = true,
        .active_work = identity,
        .transport_owner = transportOwnerTokenV1(lease),
        .cancellation = .cancelled,
        .cancellation_winner = .drain,
        .cancellation_was_new = true,
    };

    lifecycle.managed.mutex.lock();
    try applyConcurrentDrainWorkReceiptLockedV1(
        &lifecycle,
        receipt,
    );
    lifecycle.managed.mutex.unlock();
    const applied = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        applied.managed.drain_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        applied.managed.last_drain_cancelled_work_phase,
    );

    try lifecycle.managed.retireActiveConnectionWorkV1(
        lease,
        identity,
    );
    try lifecycle.managed.finishConnectionV1(lease, false);
    lifecycle.managed.mutex.lock();
    const stale_result =
        applyConcurrentDrainWorkReceiptLockedV1(
            &lifecycle,
            receipt,
        );
    lifecycle.managed.mutex.unlock();
    try std.testing.expectError(
        LifecycleError.NoActiveConnection,
        stale_result,
    );

    const replacement_lease =
        try lifecycle.managed.beginConnectionV1(
            @intCast(231),
        );
    lifecycle.queue_enqueued_connections = 2;
    lifecycle.queue_dispatched_connections = 2;
    lifecycle.managed.mutex.lock();
    const reused_result =
        applyConcurrentDrainWorkReceiptLockedV1(
            &lifecycle,
            receipt,
        );
    lifecycle.managed.mutex.unlock();
    try std.testing.expectError(
        LifecycleError.ConnectionSlotGenerationMismatch,
        reused_result,
    );
    try lifecycle.managed.finishConnectionV1(
        replacement_lease,
        false,
    );
}

test "concurrent fatal convergence has distinct running failure evidence" {
    const bind_address =
        try std.net.Address.parseIp("127.0.0.1", 0);
    var listener = try bind_address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();
    const peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer peer.close();
    const connection = try listener.accept();
    defer connection.stream.close();

    var lifecycle = try ManagedConcurrentLifecycleV1.initV1(
        58,
        .{
            .worker_count = 1,
            .pending_connection_capacity = 1,
        },
    );
    try lifecycle.markReadyV1();
    const lease = try lifecycle.managed.beginConnectionV1(
        connection.stream.handle,
    );
    lifecycle.queue_enqueued_connections = 1;
    lifecycle.queue_dispatched_connections = 1;
    lifecycle.running_high_watermark = 1;
    try lifecycle.managed.markRequestHeadReceivedV1(lease);
    try lifecycle.managed.markRequestReceivedBeforeDeadlineV1(
        lease,
        null,
        0,
    );
    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 32,
        .handle_sha256 = [_]u8{0xA2} ** 32,
    };
    _ = try lifecycle.managed.markRequestAdmittedV1(
        lease,
        identity,
    );
    try lifecycle.managed.recordWorkCancellationV1(
        lease,
        identity,
        .{
            .requested_cause = .transport_failure,
            .winner = .transport_failure,
            .outcome = .cancelled,
            .cancellation_was_new = true,
        },
    );
    try lifecycle.managed.retireActiveConnectionWorkV1(
        lease,
        identity,
    );
    try lifecycle.managed.markResponseReadyV1(lease);

    var first_batch: ManagedConcurrentDetachedBatchV1 = .{};
    lifecycle.managed.mutex.lock();
    convergeManagedConcurrentFailureLockedV1(
        &lifecycle,
        null,
        error.InjectedConcurrentFailure,
        null,
        &first_batch,
    );
    lifecycle.managed.mutex.unlock();
    try std.testing.expectEqual(
        @as(u8, 1),
        first_batch.event_count,
    );
    const first_event = first_batch.events[0].?.event;
    try std.testing.expectEqual(
        ManagedConcurrentEventKindV1.running_failure,
        first_event.kind,
    );
    try std.testing.expectEqualDeep(
        lease,
        first_event.lease.?,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        first_batch.connection_count,
    );
    try first_batch.release(&lifecycle);

    const failed = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        ManagedStateV1.failed,
        failed.managed.state,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        failed.managed.failure_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        ManagedConnectionPhaseV1.request_admitted,
        failed.managed.last_failure_cancelled_work_phase,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        failed.managed.failure_cancelled_response_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        failed.managed.drain_signaled_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        failed.managed.drain_cancelled_work_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        failed.managed.drain_cancelled_response_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        failed.managed.drain_requested_response_write_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        failed.managed.drain_cancelled_response_write_connections,
    );
    try std.testing.expect(!failed.cleanup_failed);

    var repeated_batch: ManagedConcurrentDetachedBatchV1 = .{};
    lifecycle.managed.mutex.lock();
    convergeManagedConcurrentFailureLockedV1(
        &lifecycle,
        null,
        error.SecondInjectedConcurrentFailure,
        null,
        &repeated_batch,
    );
    lifecycle.managed.mutex.unlock();
    try std.testing.expectEqual(
        @as(u8, 0),
        repeated_batch.event_count,
    );
    try repeated_batch.release(&lifecycle);
    try std.testing.expectEqual(
        @as(u64, 1),
        lifecycle.snapshotV1()
            .managed.failure_cancelled_response_connections,
    );

    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.cancelled_before_write,
        try lifecycle.managed.retireResponseV1(
            lease,
            .cancelled_before_write,
            null,
        ),
    );
    try lifecycle.managed.finishConnectionV1(
        lease,
        false,
    );
    const retired = lifecycle.snapshotV1();
    try std.testing.expectEqual(
        @as(u64, 1),
        retired.managed.accepted_connections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        retired.managed.failed_connections,
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        retired.managed.active_connections,
    );
}
