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
    PeerResetPollRequiresManagedLifecycle,
    ResponseWriteQuantumRequiresManagedLifecycle,
};

pub const minimum_receive_timeout_ns: u64 = std.time.ns_per_ms;
pub const maximum_receive_timeout_ns: u64 = 60 * std.time.ns_per_s;
pub const minimum_peer_reset_poll_timeout_ns: u64 =
    std.time.ns_per_ms;
pub const maximum_peer_reset_poll_timeout_ns: u64 =
    std.time.ns_per_s;
pub const minimum_response_write_quantum_bytes: u16 =
    cancellable_writer.minimum_max_send_bytes;
pub const maximum_response_write_quantum_bytes: u16 =
    cancellable_writer.maximum_max_send_bytes;

pub const LifecycleError = error{
    InvalidGeneration,
    InvalidTransition,
    ConnectionAlreadyActive,
    NoActiveConnection,
    ConnectionSequenceMismatch,
    ConnectionHandleMismatch,
    ConnectionPhaseMismatch,
    ConnectionInterrupted,
    WorkIdentityMismatch,
    WorkCancellationRecoveryRequired,
    CounterOverflow,
};

pub const ServerConfig = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    stop_after_requests: ?u64 = null,
    /// Absolute monotonic elapsed-time bound from accept through the last
    /// required request byte. Zero disables the bounded receive timer.
    receive_timeout_ns: u64 = 0,
    /// Per-checkpoint event-driven wait for an admitted peer reset. Zero keeps
    /// the production path non-blocking; bounded acceptance fixtures may opt
    /// in when they need reset delivery to precede the next work quantum.
    peer_reset_poll_timeout_ns: u64 = 0,
    /// Upper bound for one managed response send syscall. A drain racing an
    /// already-started syscall may pass at most this many additional bytes.
    response_write_quantum_bytes: u16 =
        maximum_response_write_quantum_bytes,
};

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
};

const ResponseWriteStopStateV1 = enum {
    none,
    requested,
    observed,
};

pub const ManagedSnapshotV1 = struct {
    process_generation: u64,
    state: ManagedStateV1,
    accepted_connections: u64,
    completed_connections: u64,
    failed_connections: u64,
    active_connections: u8,
    drain_signaled_connections: u64,
    receive_timeout_signaled_connections: u64,
    drain_cancelled_work_connections: u64 = 0,
    peer_reset_connections: u64 = 0,
    peer_reset_cancelled_work_connections: u64 = 0,
    drain_cancelled_response_connections: u64 = 0,
    drain_requested_response_write_connections: u64 = 0,
    drain_cancelled_response_write_connections: u64 = 0,
    response_write_transport_failed_connections: u64 = 0,
    active_connection_phase: ManagedConnectionPhaseV1,
    last_drain_signaled_phase: ManagedConnectionPhaseV1,
    last_receive_timeout_signaled_phase: ManagedConnectionPhaseV1,
    last_drain_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_response_write_transport_failed_phase: ManagedConnectionPhaseV1 = .none,
};

const ActiveConnectionV1 = struct {
    process_generation: u64,
    sequence: u64,
    handle: std.net.Stream.Handle,
    phase: ManagedConnectionPhaseV1 = .receiving_head,
    drain_signaled: bool = false,
    receive_timeout_signaled: bool = false,
    receive_retired: bool = false,
    work_identity: ?prepared_http.WorkIdentityV1 = null,
    work_retired: bool = false,
    drain_work_cancelled: bool = false,
    peer_reset_observed: bool = false,
    peer_reset_work_cancelled: bool = false,
    response_retired: bool = false,
    response_cancelled_before_write: bool = false,
    response_write_stop_state: ResponseWriteStopStateV1 = .none,
    response_write_failure: ?cancellable_writer.FailureKindV1 = null,
    response_write_progress_bytes: u64 = 0,
};

/// Process-lifetime listener state only. Request execution and retained
/// idempotency remain exclusively owned by `prepared_text_unary_service`.
pub const ManagedLifecycleV1 = struct {
    mutex: std.Thread.Mutex = .{},
    process_generation: u64,
    state: ManagedStateV1 = .starting,
    accepted_connections: u64 = 0,
    completed_connections: u64 = 0,
    failed_connections: u64 = 0,
    active_connections: u8 = 0,
    drain_signaled_connections: u64 = 0,
    receive_timeout_signaled_connections: u64 = 0,
    drain_cancelled_work_connections: u64 = 0,
    peer_reset_connections: u64 = 0,
    peer_reset_cancelled_work_connections: u64 = 0,
    drain_cancelled_response_connections: u64 = 0,
    drain_requested_response_write_connections: u64 = 0,
    drain_cancelled_response_write_connections: u64 = 0,
    response_write_transport_failed_connections: u64 = 0,
    last_drain_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_receive_timeout_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_phase: ManagedConnectionPhaseV1 = .none,
    last_peer_reset_cancelled_work_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_requested_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_drain_cancelled_response_write_phase: ManagedConnectionPhaseV1 = .none,
    last_response_write_transport_failed_phase: ManagedConnectionPhaseV1 = .none,
    active_connection: ?ActiveConnectionV1 = null,

    pub fn initV1(
        process_generation: u64,
    ) LifecycleError!ManagedLifecycleV1 {
        if (process_generation == 0)
            return LifecycleError.InvalidGeneration;
        return .{ .process_generation = process_generation };
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
    ) LifecycleError!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .ready)
            return LifecycleError.InvalidTransition;
        if (self.active_connections != 0 or
            self.active_connection != null)
        {
            return LifecycleError.ConnectionAlreadyActive;
        }
        const sequence = std.math.add(
            u64,
            self.accepted_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.accepted_connections = sequence;
        self.active_connections = 1;
        self.active_connection = .{
            .process_generation = self.process_generation,
            .sequence = sequence,
            .handle = handle,
        };
        return sequence;
    }

    fn markRequestHeadReceivedV1(
        self: *ManagedLifecycleV1,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
    ) LifecycleError!void {
        return self.markRequestHeadReceivedBeforeDeadlineV1(
            connection_sequence,
            handle,
            null,
            0,
        );
    }

    fn markRequestHeadReceivedBeforeDeadlineV1(
        self: *ManagedLifecycleV1,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.transitionActiveConnectionReceiveLockedV1(
            connection_sequence,
            handle,
            .receiving_head,
            .request_head_received,
            false,
            timer,
            timeout_ns,
        );
    }

    fn markRequestReceivedBeforeDeadlineV1(
        self: *ManagedLifecycleV1,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.transitionActiveConnectionReceiveLockedV1(
            connection_sequence,
            handle,
            .request_head_received,
            .request_received,
            true,
            timer,
            timeout_ns,
        );
    }

    fn markRequestAdmittedV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        work_identity: prepared_http.WorkIdentityV1,
    ) !prepared_http.WorkDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (!active.receive_retired or
            active.receive_timeout_signaled or
            active.drain_signaled)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        try self.bindActiveWorkLockedV1(work_identity);
        return switch (self.state) {
            .ready => .proceed,
            .draining => .draining,
            else => LifecycleError.InvalidTransition,
        };
    }

    fn bindActiveWorkLockedV1(
        self: *ManagedLifecycleV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!void {
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        switch (active.phase) {
            .request_received => {
                if (active.work_identity != null)
                    return LifecycleError.WorkIdentityMismatch;
                self.active_connection.?.phase = .request_admitted;
                self.active_connection.?.work_identity = work_identity;
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
    }

    fn retireActiveConnectionWorkV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .ready and self.state != .draining)
            return LifecycleError.InvalidTransition;
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
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
        self.active_connection.?.work_retired = true;
    }

    fn recordDrainWorkCancellationLockedV1(
        self: *ManagedLifecycleV1,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!void {
        try self.bindActiveWorkLockedV1(work_identity);
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.drain_work_cancelled) return;
        const next_cancelled = std.math.add(
            u64,
            self.drain_cancelled_work_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.drain_cancelled_work_connections = next_cancelled;
        self.last_drain_cancelled_work_phase = active.phase;
        self.active_connection.?.drain_work_cancelled = true;
    }

    fn recordPeerResetCancellationV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        work_identity: prepared_http.WorkIdentityV1,
        receipt: prepared_http.WorkCancellationReceiptV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (receipt.requested_cause != .peer_reset) return;
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.phase != .request_admitted)
            return LifecycleError.ConnectionPhaseMismatch;
        const existing = active.work_identity orelse
            return LifecycleError.WorkIdentityMismatch;
        if (!std.meta.eql(existing, work_identity))
            return LifecycleError.WorkIdentityMismatch;

        if (!active.peer_reset_observed) {
            self.peer_reset_connections = std.math.add(
                u64,
                self.peer_reset_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            self.last_peer_reset_phase = active.phase;
            self.active_connection.?.peer_reset_observed = true;
        }
        if (receipt.cancellation_was_new and
            receipt.winner == .peer_reset and
            !active.peer_reset_work_cancelled)
        {
            self.peer_reset_cancelled_work_connections = std.math.add(
                u64,
                self.peer_reset_cancelled_work_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            self.last_peer_reset_cancelled_work_phase = active.phase;
            self.active_connection.?.peer_reset_work_cancelled = true;
        }
    }

    fn validateWorkCheckpointV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        work_identity: prepared_http.WorkIdentityV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.phase != .request_admitted)
            return LifecycleError.ConnectionPhaseMismatch;
        const existing = active.work_identity orelse
            return LifecycleError.WorkIdentityMismatch;
        if (!std.meta.eql(existing, work_identity))
            return LifecycleError.WorkIdentityMismatch;
    }

    fn markResponseReadyV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .ready and self.state != .draining)
            return LifecycleError.InvalidTransition;
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
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
            => self.active_connection.?.phase = .response_ready,
            else => return LifecycleError.ConnectionPhaseMismatch,
        }
    }

    fn markResponseWritingV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
    ) LifecycleError!prepared_http.ResponseWriteDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.phase != .response_ready)
            return LifecycleError.ConnectionPhaseMismatch;
        if (active.response_cancelled_before_write)
            return .cancelled;
        self.active_connection.?.phase = .response_writing;
        return .proceed;
    }

    fn checkResponseWriteV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
    ) LifecycleError!prepared_http.ResponseWriteDispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.phase != .response_ready)
            return LifecycleError.ConnectionPhaseMismatch;
        return if (active.response_cancelled_before_write)
            .cancelled
        else
            .proceed;
    }

    fn observeResponseWriteStopV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
    ) LifecycleError!cancellable_writer.DispositionV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.phase != .response_writing or
            active.response_retired)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        return switch (active.response_write_stop_state) {
            .none => .proceed,
            .requested => blk: {
                const next_cancelled = std.math.add(
                    u64,
                    self.drain_cancelled_response_write_connections,
                    1,
                ) catch return LifecycleError.CounterOverflow;
                self.drain_cancelled_response_write_connections =
                    next_cancelled;
                self.last_drain_cancelled_response_write_phase =
                    .response_writing;
                self.active_connection.?.response_write_stop_state =
                    .observed;
                break :blk .cancelled;
            },
            .observed => .cancelled,
        };
    }

    fn recordResponseWriteProgressV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        bytes_sent: usize,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.phase != .response_writing or
            active.response_retired or
            bytes_sent == 0)
        {
            return LifecycleError.ConnectionPhaseMismatch;
        }
        self.active_connection.?.response_write_progress_bytes =
            std.math.add(
                u64,
                active.response_write_progress_bytes,
                @intCast(bytes_sent),
            ) catch return LifecycleError.CounterOverflow;
    }

    fn recordResponseWriteFailureV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        failure: cancellable_writer.FailureV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
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
            active.response_write_stop_state != .observed)
        {
            return LifecycleError.ConnectionInterrupted;
        }
        self.active_connection.?.response_write_failure =
            failure_kind;
    }

    fn retireResponseV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        outcome: prepared_http.ResponseWriteOutcomeV1,
        writer_failure: ?cancellable_writer.FailureKindV1,
    ) LifecycleError!prepared_http.ResponseWriteOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.response_retired)
            return LifecycleError.ConnectionInterrupted;
        if (active.response_write_failure != writer_failure)
            return LifecycleError.ConnectionInterrupted;
        var effective_outcome = outcome;
        switch (outcome) {
            .write_completed => {
                if (active.phase != .response_writing)
                    return LifecycleError.ConnectionPhaseMismatch;
                if (writer_failure != null)
                    return LifecycleError.ConnectionInterrupted;
                self.active_connection.?.phase = .response_written;
            },
            .write_failed => {
                if (active.phase != .response_ready and
                    active.phase != .response_writing)
                {
                    return LifecycleError.ConnectionPhaseMismatch;
                }
                if (writer_failure == .cancelled) {
                    if (active.response_write_stop_state != .observed)
                        return LifecycleError.ConnectionInterrupted;
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
                    active.response_write_stop_state != .observed)
                {
                    return LifecycleError.ConnectionPhaseMismatch;
                }
            },
        }
        self.active_connection.?.response_retired = true;
        return effective_outcome;
    }

    fn transitionActiveConnectionReceiveLockedV1(
        self: *ManagedLifecycleV1,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        expected_phase: ManagedConnectionPhaseV1,
        next_phase: ManagedConnectionPhaseV1,
        retire_receive: bool,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !void {
        if (self.state != .ready)
            return LifecycleError.InvalidTransition;
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != self.process_generation or
            active.sequence != connection_sequence)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
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
                self.process_generation,
                connection_sequence,
                handle,
            );
            return LifecycleError.ConnectionInterrupted;
        }
        self.active_connection.?.phase = next_phase;
        if (retire_receive)
            self.active_connection.?.receive_retired = true;
    }

    fn finishConnectionV1(
        self: *ManagedLifecycleV1,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        succeeded: bool,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_connections != 1 or
            self.active_connection == null)
        {
            return LifecycleError.NoActiveConnection;
        }
        const active = self.active_connection.?;
        if (active.process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
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
        if (succeeded) {
            self.completed_connections = std.math.add(
                u64,
                self.completed_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        } else {
            self.failed_connections = std.math.add(
                u64,
                self.failed_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
        }
        self.active_connections = 0;
        self.active_connection = null;
    }

    fn markStoppedV1(
        self: *ManagedLifecycleV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .draining or
            self.active_connections != 0 or
            self.active_connection != null)
        {
            return LifecycleError.InvalidTransition;
        }
        self.state = .stopped;
    }

    fn markFailedV1(self: *ManagedLifecycleV1) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .stopped) self.state = .failed;
    }

    pub fn snapshotV1(
        self: *ManagedLifecycleV1,
    ) ManagedSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .process_generation = self.process_generation,
            .state = self.state,
            .accepted_connections = self.accepted_connections,
            .completed_connections = self.completed_connections,
            .failed_connections = self.failed_connections,
            .active_connections = self.active_connections,
            .drain_signaled_connections = self.drain_signaled_connections,
            .receive_timeout_signaled_connections = self.receive_timeout_signaled_connections,
            .drain_cancelled_work_connections = self.drain_cancelled_work_connections,
            .peer_reset_connections = self.peer_reset_connections,
            .peer_reset_cancelled_work_connections = self.peer_reset_cancelled_work_connections,
            .drain_cancelled_response_connections = self.drain_cancelled_response_connections,
            .drain_requested_response_write_connections = self.drain_requested_response_write_connections,
            .drain_cancelled_response_write_connections = self.drain_cancelled_response_write_connections,
            .response_write_transport_failed_connections = self.response_write_transport_failed_connections,
            .active_connection_phase = if (self.active_connection) |active|
                active.phase
            else
                .none,
            .last_drain_signaled_phase = self.last_drain_signaled_phase,
            .last_receive_timeout_signaled_phase = self.last_receive_timeout_signaled_phase,
            .last_drain_cancelled_work_phase = self.last_drain_cancelled_work_phase,
            .last_peer_reset_phase = self.last_peer_reset_phase,
            .last_peer_reset_cancelled_work_phase = self.last_peer_reset_cancelled_work_phase,
            .last_drain_cancelled_response_phase = self.last_drain_cancelled_response_phase,
            .last_drain_requested_response_write_phase = self.last_drain_requested_response_write_phase,
            .last_drain_cancelled_response_write_phase = self.last_drain_cancelled_response_write_phase,
            .last_response_write_transport_failed_phase = self.last_response_write_transport_failed_phase,
        };
    }

    fn signalActiveConnectionForDrainLockedV1(
        self: *ManagedLifecycleV1,
    ) !bool {
        const active = self.active_connection orelse return false;
        if (active.process_generation != self.process_generation or
            active.sequence != self.accepted_connections or
            self.active_connections != 1)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.phase == .response_ready) {
            if (active.response_cancelled_before_write) return true;
            const next_cancelled = std.math.add(
                u64,
                self.drain_cancelled_response_connections,
                1,
            ) catch return LifecycleError.CounterOverflow;
            self.drain_cancelled_response_connections = next_cancelled;
            self.last_drain_cancelled_response_phase = active.phase;
            self.active_connection.?.response_cancelled_before_write = true;
            return true;
        }
        if (active.phase == .response_writing) {
            if (active.response_write_failure != null or
                active.response_write_stop_state != .none)
            {
                return true;
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
            self.active_connection.?.response_write_stop_state =
                .requested;
            return true;
        }
        if (active.drain_signaled or
            active.receive_timeout_signaled or
            active.receive_retired)
        {
            return true;
        }
        const next_signaled = std.math.add(
            u64,
            self.drain_signaled_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        std.posix.shutdown(active.handle, .recv) catch |err| switch (err) {
            error.ConnectionAborted,
            error.ConnectionResetByPeer,
            error.SocketNotConnected,
            => {},
            else => return err,
        };
        self.drain_signaled_connections = next_signaled;
        self.last_drain_signaled_phase = active.phase;
        self.active_connection.?.drain_signaled = true;
        self.active_connection.?.receive_retired = true;
        return true;
    }

    fn signalActiveConnectionForReceiveTimeoutV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.signalActiveConnectionForReceiveTimeoutLockedV1(
            process_generation,
            connection_sequence,
            handle,
        );
    }

    fn signalActiveConnectionForReceiveTimeoutLockedV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
    ) !bool {
        if (self.state != .ready) return false;
        const active = self.active_connection orelse return false;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections or
            active.handle != handle or
            self.active_connections != 1)
        {
            return false;
        }
        if (active.phase == .request_received or
            active.phase == .request_admitted or
            active.drain_signaled or
            active.receive_timeout_signaled or
            active.receive_retired)
        {
            return false;
        }
        const next_signaled = std.math.add(
            u64,
            self.receive_timeout_signaled_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.receive_timeout_signaled_connections = next_signaled;
        self.last_receive_timeout_signaled_phase = active.phase;
        self.active_connection.?.receive_timeout_signaled = true;
        self.active_connection.?.receive_retired = true;
        return true;
    }

    fn retireActiveConnectionReceiveV1(
        self: *ManagedLifecycleV1,
        process_generation: u64,
        connection_sequence: u64,
        handle: std.net.Stream.Handle,
        timer: ?*std.time.Timer,
        timeout_ns: u64,
    ) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = self.active_connection orelse
            return LifecycleError.NoActiveConnection;
        if (active.process_generation != process_generation or
            process_generation != self.process_generation or
            active.sequence != connection_sequence or
            connection_sequence != self.accepted_connections)
        {
            return LifecycleError.ConnectionSequenceMismatch;
        }
        if (active.handle != handle)
            return LifecycleError.ConnectionHandleMismatch;
        if (active.receive_timeout_signaled) return false;
        if (active.receive_retired) return true;
        if (active.drain_signaled or self.state != .ready) {
            self.active_connection.?.receive_retired = true;
            return true;
        }
        if (receiveDeadlineExpiredV1(timer, timeout_ns)) {
            _ = try self.signalActiveConnectionForReceiveTimeoutLockedV1(
                process_generation,
                connection_sequence,
                handle,
            );
            return false;
        }
        self.active_connection.?.receive_retired = true;
        return true;
    }
};

fn receiveDeadlineExpiredV1(
    timer: ?*std.time.Timer,
    timeout_ns: u64,
) bool {
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
    if (config.peer_reset_poll_timeout_ns != 0)
        return Error.PeerResetPollRequiresManagedLifecycle;
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
        const receive_timer = if (config.receive_timeout_ns == 0)
            null
        else
            std.time.Timer.start() catch |err| {
                connection.stream.close();
                lifecycle.markFailedV1();
                return err;
            };
        const sequence = lifecycle.beginConnectionV1(
            connection.stream.handle,
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
            sequence,
            config.receive_timeout_ns,
            config.peer_reset_poll_timeout_ns,
            config.response_write_quantum_bytes,
            receive_timer,
            work_observer,
            response_observer,
        ) catch |err| {
            lifecycle.markFailedV1();
            return err;
        };
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
    if (!isLoopbackAddress(listen_address))
        return Error.NonLoopbackBind;
    const active_was_signaled =
        try beginManagedDrainV1(lifecycle, runtime);
    if (active_was_signaled) return;
    const wake = std.net.tcpConnectToAddress(
        listen_address,
    ) catch |err| {
        if (lifecycle.snapshotV1().state == .stopped) return;
        return err;
    };
    wake.close();
}

/// Holds listener lifecycle authority until completion admission is closed.
/// Consequently `draining` is never externally visible while the HTTP
/// runtime can still admit a completion.
fn beginManagedDrainV1(
    lifecycle: *ManagedLifecycleV1,
    runtime: *prepared_http.RuntimeV1,
) !bool {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    return switch (lifecycle.state) {
        .ready => blk: {
            const drain_receipt =
                prepared_http.beginDrainV1(runtime) catch |err| {
                    lifecycle.state = .failed;
                    return err;
                };
            applyDrainWorkReceiptLockedV1(
                lifecycle,
                drain_receipt,
            ) catch |err| {
                lifecycle.state = .failed;
                return err;
            };
            const active_was_signaled =
                lifecycle.signalActiveConnectionForDrainLockedV1() catch |err|
                    {
                        lifecycle.state = .failed;
                        return err;
                    };
            lifecycle.state = .draining;
            break :blk active_was_signaled;
        },
        .draining => blk: {
            const drain_receipt =
                prepared_http.beginDrainV1(runtime) catch |err| {
                    lifecycle.state = .failed;
                    return err;
                };
            applyDrainWorkReceiptLockedV1(
                lifecycle,
                drain_receipt,
            ) catch |err| {
                lifecycle.state = .failed;
                return err;
            };
            break :blk lifecycle.active_connection != null;
        },
        else => LifecycleError.InvalidTransition,
    };
}

fn applyDrainWorkReceiptLockedV1(
    lifecycle: *ManagedLifecycleV1,
    receipt: prepared_http.DrainReceiptV1,
) LifecycleError!void {
    const work_identity = receipt.active_work orelse return;
    try lifecycle.bindActiveWorkLockedV1(work_identity);
    if (receipt.cancellation == .recovery_required)
        return LifecycleError.WorkCancellationRecoveryRequired;
    if (receipt.cancellation_was_new and
        receipt.cancellation_winner == .drain)
    {
        try lifecycle.recordDrainWorkCancellationLockedV1(
            work_identity,
        );
    }
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
    process_generation: u64,
    connection_sequence: u64,
    handle: std.net.Stream.Handle,
    timeout_ns: u64,
    decision_timer: ?std.time.Timer,
    wait_timer: ?std.time.Timer,
    receive_stopped: std.Thread.ResetEvent = .{},
    signaled: bool = false,
    signal_error: ?anyerror = null,

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
                self.process_generation,
                self.connection_sequence,
                self.handle,
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
            self.connection_sequence,
            self.handle,
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
            self.process_generation,
            self.connection_sequence,
            self.handle,
            self.timerPointer(),
            self.timeout_ns,
        );
    }

    fn markHeadReceived(self: *ManagedReceiveTimeoutV1) !void {
        try self.lifecycle.markRequestHeadReceivedBeforeDeadlineV1(
            self.connection_sequence,
            self.handle,
            self.timerPointer(),
            self.timeout_ns,
        );
    }

    fn timerPointer(self: *ManagedReceiveTimeoutV1) ?*std.time.Timer {
        if (self.decision_timer) |*timer| return timer;
        return null;
    }
};

/// Managed requests read only after waiting for socket readiness within the
/// remaining monotonic budget. Recomputing that budget before every read keeps
/// a trickling peer from turning the absolute deadline into an inactivity
/// timeout. The serving thread remains the only socket reader and closer.
const ManagedDeadlineReaderV1 = struct {
    interface: std.Io.Reader,
    stream: std.net.Stream,
    receive_timeout: *ManagedReceiveTimeoutV1,

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
        self.waitUntilReadable() catch return error.ReadFailed;
        const destination = limit.slice(
            try writer.writableSliceGreedy(1),
        );
        const read_count = std.posix.recv(
            self.stream.handle,
            destination,
            0,
        ) catch
            return error.ReadFailed;
        if (read_count == 0) return error.EndOfStream;
        writer.advance(read_count);
        return read_count;
    }

    fn waitUntilReadable(self: *ManagedDeadlineReaderV1) !void {
        const timer =
            self.receive_timeout.timerPointer() orelse unreachable;
        while (true) {
            const elapsed_ns = timer.read();
            if (elapsed_ns >= self.receive_timeout.timeout_ns)
                return error.ReceiveDeadlineExceeded;
            const remaining_ns =
                self.receive_timeout.timeout_ns - elapsed_ns;
            const remaining_ms: i32 = @intCast(
                std.math.divCeil(
                    u64,
                    remaining_ns,
                    std.time.ns_per_ms,
                ) catch unreachable,
            );
            if (try pollReadableOnceV1(
                self.stream.handle,
                remaining_ms,
            ))
                return;
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
    process_generation: u64,
    connection_sequence: u64,
    handle: std.net.Stream.Handle,
    peer_reset_poll_timeout_ms: i32,
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
                self.process_generation,
                self.connection_sequence,
                self.handle,
                work_identity,
            );
        if (lifecycle_disposition == .draining)
            return .draining;
        if (self.observer) |observer| {
            const observer_disposition = try observer.admitted_fn(
                observer.context,
                work_identity,
            );
            self.observer_admitted = true;
            return observer_disposition;
        }
        return .proceed;
    }

    fn checkpointOpaque(
        context: *anyopaque,
        work_identity: prepared_http.WorkIdentityV1,
    ) anyerror!prepared_http.WorkCheckpointDispositionV1 {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        try self.lifecycle.validateWorkCheckpointV1(
            self.process_generation,
            self.connection_sequence,
            self.handle,
            work_identity,
        );
        if (try peerResetDetectedV1(
            self.handle,
            self.peer_reset_poll_timeout_ms,
        )) {
            try self.lifecycle.validateWorkCheckpointV1(
                self.process_generation,
                self.connection_sequence,
                self.handle,
                work_identity,
            );
            return .peer_reset;
        }
        if (self.observer) |observer| {
            const callback = observer.checkpoint_fn orelse
                return .proceed;
            return callback(observer.context, work_identity);
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
        self.lifecycle.recordPeerResetCancellationV1(
            self.process_generation,
            self.connection_sequence,
            self.handle,
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

    fn retiredOpaque(
        context: *anyopaque,
        work_identity: prepared_http.WorkIdentityV1,
    ) void {
        const self: *ManagedRequestWorkControlV1 =
            @ptrCast(@alignCast(context));
        self.lifecycle.retireActiveConnectionWorkV1(
            self.process_generation,
            self.connection_sequence,
            self.handle,
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
            .checkpoint_fn = checkpointOpaque,
            .cancellation_fn = cancellationOpaque,
        };
    }
};

fn peerResetDetectedV1(
    handle: std.net.Stream.Handle,
    timeout_ms: i32,
) !bool {
    if (!try ManagedDeadlineReaderV1.pollReadableOnceV1(
        handle,
        timeout_ms,
    )) return false;

    var probe: [1]u8 = undefined;
    const count = std.posix.recv(
        handle,
        &probe,
        std.posix.MSG.PEEK,
    ) catch |err| switch (err) {
        error.ConnectionResetByPeer,
        error.SocketNotConnected,
        => return true,
        error.WouldBlock => return false,
        else => return err,
    };
    // Zero is only a peer send-half-close. It is not proof that the peer
    // abandoned the response, so E1 deliberately does not cancel on FIN.
    _ = count;
    return false;
}

const ManagedRequestResponseControlV1 = struct {
    lifecycle: *ManagedLifecycleV1,
    process_generation: u64,
    connection_sequence: u64,
    handle: std.net.Stream.Handle,
    observer: ?prepared_http.RequestResponseControlV1,
    max_send_bytes: u16,
    observer_ready: bool = false,
    writer_failure: ?cancellable_writer.FailureKindV1 = null,
    retire_error: ?anyerror = null,

    fn readyOpaque(context: *anyopaque) anyerror!void {
        const self: *ManagedRequestResponseControlV1 =
            @ptrCast(@alignCast(context));
        try self.lifecycle.markResponseReadyV1(
            self.process_generation,
            self.connection_sequence,
            self.handle,
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
                self.process_generation,
                self.connection_sequence,
                self.handle,
            );
        if (lifecycle_disposition == .cancelled)
            return .cancelled;
        if (self.observer) |observer| {
            const observed = try observer.writing_fn(observer.context);
            if (observed == .cancelled) return .cancelled;
        }
        return self.lifecycle.markResponseWritingV1(
            self.process_generation,
            self.connection_sequence,
            self.handle,
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
            .before_send => self.lifecycle.observeResponseWriteStopV1(
                self.process_generation,
                self.connection_sequence,
                self.handle,
            ),
            .progress => |bytes_sent| blk: {
                try self.lifecycle.recordResponseWriteProgressV1(
                    self.process_generation,
                    self.connection_sequence,
                    self.handle,
                    bytes_sent,
                );
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
                    self.process_generation,
                    self.connection_sequence,
                    self.handle,
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
            self.process_generation,
            self.connection_sequence,
            self.handle,
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
                self.process_generation,
                self.connection_sequence,
                self.handle,
                outcome,
                self.writer_failure,
            ) catch |err| {
                if (self.retire_error == null)
                    self.retire_error = err;
                return;
            };
        if (self.observer) |observer| {
            if (!self.observer_ready) return;
            observer.retired_fn(
                observer.context,
                effective_outcome,
            );
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
    sequence: u64,
    receive_timeout_ns: u64,
    peer_reset_poll_timeout_ns: u64,
    response_write_quantum_bytes: u16,
    receive_timer: ?std.time.Timer,
    work_observer: ?prepared_http.RequestWorkControlV1,
    response_observer: ?prepared_http.RequestResponseControlV1,
) !bool {
    var owned_connection = connection;
    defer owned_connection.stream.close();
    var receive_timeout: ManagedReceiveTimeoutV1 = .{
        .lifecycle = lifecycle,
        .process_generation = lifecycle.process_generation,
        .connection_sequence = sequence,
        .handle = owned_connection.stream.handle,
        .timeout_ns = receive_timeout_ns,
        .decision_timer = receive_timer,
        .wait_timer = receive_timer,
    };
    var work_control: ManagedRequestWorkControlV1 = .{
        .lifecycle = lifecycle,
        .process_generation = lifecycle.process_generation,
        .connection_sequence = sequence,
        .handle = owned_connection.stream.handle,
        .peer_reset_poll_timeout_ms = peerResetPollTimeoutMsV1(
            peer_reset_poll_timeout_ns,
        ),
        .observer = work_observer,
    };
    var response_control: ManagedRequestResponseControlV1 = .{
        .lifecycle = lifecycle,
        .process_generation = lifecycle.process_generation,
        .connection_sequence = sequence,
        .handle = owned_connection.stream.handle,
        .observer = response_observer,
        .max_send_bytes = response_write_quantum_bytes,
    };
    const timeout_thread = if (receive_timer == null)
        null
    else
        std.Thread.spawn(
            .{},
            ManagedReceiveTimeoutV1.run,
            .{&receive_timeout},
        ) catch |err| {
            try lifecycle.finishConnectionV1(
                sequence,
                owned_connection.stream.handle,
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
    if (timeout_thread) |thread| thread.join();
    const connection_succeeded =
        succeeded and
        receive_retired and
        !receive_timeout.signaled and
        receive_timeout.signal_error == null and
        stop_error == null and
        work_control.retire_error == null and
        response_control.retire_error == null;
    try lifecycle.finishConnectionV1(
        sequence,
        owned_connection.stream.handle,
        connection_succeeded,
    );
    if (receive_timeout.signal_error) |err| return err;
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
            if (timeout.timerPointer() != null) {
                deadline_reader = ManagedDeadlineReaderV1.init(
                    stream.*,
                    timeout,
                    &receive_buffer,
                );
                break :blk &deadline_reader.interface;
            }
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
    generation: u64,
    handle: std.net.Stream.Handle,
    identity: prepared_http.WorkIdentityV1,
) !u64 {
    try lifecycle.markReadyV1();
    const sequence = try lifecycle.beginConnectionV1(handle);
    try lifecycle.markRequestHeadReceivedV1(sequence, handle);
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        sequence,
        handle,
        null,
        0,
    );
    _ = try lifecycle.markRequestAdmittedV1(
        generation,
        sequence,
        handle,
        identity,
    );
    try lifecycle.retireActiveConnectionWorkV1(
        generation,
        sequence,
        handle,
        identity,
    );
    try lifecycle.markResponseReadyV1(
        generation,
        sequence,
        handle,
    );
    _ = try lifecycle.markResponseWritingV1(
        generation,
        sequence,
        handle,
    );
    return sequence;
}

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
        .peer_reset_poll_timeout_ns = minimum_peer_reset_poll_timeout_ns,
    });
    try validateConfig(.{
        .peer_reset_poll_timeout_ns = maximum_peer_reset_poll_timeout_ns,
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

test "managed response write drain records its exact winner" {
    const handle: std.net.Stream.Handle = @intCast(131);
    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 1,
        .handle_sha256 = [_]u8{0x81} ** 32,
    };

    var cancelled = try ManagedLifecycleV1.initV1(41);
    const cancelled_sequence =
        try prepareResponseWritingLifecycleForTestV1(
            &cancelled,
            41,
            handle,
            identity,
        );
    try cancelled.recordResponseWriteProgressV1(
        41,
        cancelled_sequence,
        handle,
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
            41,
            cancelled_sequence,
            handle,
        ),
    );
    try std.testing.expectEqual(
        cancellable_writer.DispositionV1.cancelled,
        try cancelled.observeResponseWriteStopV1(
            41,
            cancelled_sequence,
            handle,
        ),
    );
    try cancelled.recordResponseWriteFailureV1(
        41,
        cancelled_sequence,
        handle,
        .{ .cancelled = .{ .before_send = .{} } },
    );
    try std.testing.expectEqual(
        prepared_http.ResponseWriteOutcomeV1.cancelled_during_write,
        try cancelled.retireResponseV1(
            41,
            cancelled_sequence,
            handle,
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
    try cancelled.finishConnectionV1(
        cancelled_sequence,
        handle,
        false,
    );

    var completed = try ManagedLifecycleV1.initV1(42);
    const completed_sequence =
        try prepareResponseWritingLifecycleForTestV1(
            &completed,
            42,
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
            42,
            completed_sequence,
            handle,
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
    try completed.finishConnectionV1(
        completed_sequence,
        handle,
        true,
    );

    var transport = try ManagedLifecycleV1.initV1(43);
    const transport_sequence =
        try prepareResponseWritingLifecycleForTestV1(
            &transport,
            43,
            handle,
            identity,
        );
    try transport.recordResponseWriteFailureV1(
        43,
        transport_sequence,
        handle,
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
            43,
            transport_sequence,
            handle,
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
    try transport.finishConnectionV1(
        transport_sequence,
        handle,
        false,
    );
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
    const sequence = try lifecycle.beginConnectionV1(
        connection.stream.handle,
    );
    try lifecycle.markRequestHeadReceivedV1(
        sequence,
        connection.stream.handle,
    );
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
    try lifecycle.finishConnectionV1(
        sequence,
        connection.stream.handle,
        false,
    );
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

test "managed admitted work is connection fenced and counted once" {
    const handle: std.net.Stream.Handle = @intCast(91);
    const stale_handle: std.net.Stream.Handle = @intCast(92);
    var lifecycle = try ManagedLifecycleV1.initV1(29);
    try lifecycle.markReadyV1();
    const connection_sequence =
        try lifecycle.beginConnectionV1(handle);
    try lifecycle.markRequestHeadReceivedV1(
        connection_sequence,
        handle,
    );
    try lifecycle.markRequestReceivedBeforeDeadlineV1(
        connection_sequence,
        handle,
        null,
        0,
    );

    const identity: prepared_http.WorkIdentityV1 = .{
        .sequence = 7,
        .handle_sha256 = [_]u8{0x71} ** 32,
    };
    try std.testing.expectError(
        LifecycleError.ConnectionSequenceMismatch,
        lifecycle.markRequestAdmittedV1(
            30,
            connection_sequence,
            handle,
            identity,
        ),
    );
    try std.testing.expectError(
        LifecycleError.ConnectionSequenceMismatch,
        lifecycle.markRequestAdmittedV1(
            29,
            connection_sequence + 1,
            handle,
            identity,
        ),
    );
    try std.testing.expectError(
        LifecycleError.ConnectionHandleMismatch,
        lifecycle.markRequestAdmittedV1(
            29,
            connection_sequence,
            stale_handle,
            identity,
        ),
    );
    try std.testing.expectEqual(
        prepared_http.WorkDispositionV1.proceed,
        try lifecycle.markRequestAdmittedV1(
            29,
            connection_sequence,
            handle,
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
            29,
            connection_sequence,
            handle,
            stale_identity,
        ),
    );
    try std.testing.expectError(
        LifecycleError.WorkIdentityMismatch,
        lifecycle.retireActiveConnectionWorkV1(
            29,
            connection_sequence,
            handle,
            stale_identity,
        ),
    );

    lifecycle.mutex.lock();
    lifecycle.recordDrainWorkCancellationLockedV1(
        identity,
    ) catch |err| {
        lifecycle.mutex.unlock();
        return err;
    };
    lifecycle.recordDrainWorkCancellationLockedV1(
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
        29,
        connection_sequence,
        handle,
        identity,
    );
    try lifecycle.finishConnectionV1(
        connection_sequence,
        handle,
        true,
    );

    var recovery = try ManagedLifecycleV1.initV1(31);
    try recovery.markReadyV1();
    const recovery_sequence =
        try recovery.beginConnectionV1(handle);
    try recovery.markRequestHeadReceivedV1(
        recovery_sequence,
        handle,
    );
    try recovery.markRequestReceivedBeforeDeadlineV1(
        recovery_sequence,
        handle,
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
            recovery_sequence,
            handle,
            false,
        ),
    );
    try std.testing.expectEqual(
        @as(u8, 1),
        recovery.snapshotV1().active_connections,
    );
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
    const sequence = try lifecycle.beginConnectionV1(
        connection.stream.handle,
    );
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            20,
            sequence,
            connection.stream.handle,
        )),
    );
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            19,
            sequence + 1,
            connection.stream.handle,
        )),
    );
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            19,
            sequence,
            stale_connection.stream.handle,
        )),
    );
    try lifecycle.markRequestHeadReceivedV1(
        sequence,
        connection.stream.handle,
    );
    try std.testing.expect(
        try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            19,
            sequence,
            connection.stream.handle,
        ),
    );
    try std.testing.expect(
        !(try lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            19,
            sequence,
            connection.stream.handle,
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
    try lifecycle.finishConnectionV1(
        sequence,
        connection.stream.handle,
        false,
    );
    try lifecycle.markStoppedV1();

    var completed = try ManagedLifecycleV1.initV1(21);
    try completed.markReadyV1();
    const completed_sequence = try completed.beginConnectionV1(
        connection.stream.handle,
    );
    try completed.markRequestHeadReceivedV1(
        completed_sequence,
        connection.stream.handle,
    );
    try completed.markRequestReceivedBeforeDeadlineV1(
        completed_sequence,
        connection.stream.handle,
        null,
        0,
    );
    try std.testing.expect(
        !(try completed.signalActiveConnectionForReceiveTimeoutV1(
            21,
            completed_sequence,
            connection.stream.handle,
        )),
    );
    try completed.finishConnectionV1(
        completed_sequence,
        connection.stream.handle,
        true,
    );
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
    const drain_first_sequence = try drain_first.beginConnectionV1(
        stale_connection.stream.handle,
    );
    try drain_first.markRequestHeadReceivedV1(
        drain_first_sequence,
        stale_connection.stream.handle,
    );
    try std.testing.expect(
        try beginManagedDrainV1(
            &drain_first,
            &drain_first_runtime,
        ),
    );
    try std.testing.expect(
        !(try drain_first.signalActiveConnectionForReceiveTimeoutV1(
            22,
            drain_first_sequence,
            stale_connection.stream.handle,
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
    try drain_first.finishConnectionV1(
        drain_first_sequence,
        stale_connection.stream.handle,
        false,
    );
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
    const head_sequence = try head_lifecycle.beginConnectionV1(
        head_connection.stream.handle,
    );
    try std.testing.expectError(
        LifecycleError.ConnectionInterrupted,
        head_lifecycle.markRequestHeadReceivedBeforeDeadlineV1(
            head_sequence,
            head_connection.stream.handle,
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
    try head_lifecycle.finishConnectionV1(
        head_sequence,
        head_connection.stream.handle,
        false,
    );

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
    const body_sequence = try body_lifecycle.beginConnectionV1(
        body_connection.stream.handle,
    );
    std.Thread.sleep(before_head_ns);
    try body_lifecycle.markRequestHeadReceivedBeforeDeadlineV1(
        body_sequence,
        body_connection.stream.handle,
        &body_timer,
        body_timeout_ns,
    );
    std.Thread.sleep(after_head_ns);
    try std.testing.expectError(
        LifecycleError.ConnectionInterrupted,
        body_lifecycle.markRequestReceivedBeforeDeadlineV1(
            body_sequence,
            body_connection.stream.handle,
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
    try body_lifecycle.finishConnectionV1(
        body_sequence,
        body_connection.stream.handle,
        false,
    );

    const retired_peer = try std.net.tcpConnectToAddress(
        listener.listen_address,
    );
    defer retired_peer.close();
    const retired_connection = try listener.accept();
    defer retired_connection.stream.close();

    var retired_timer = try std.time.Timer.start();
    var retired_lifecycle = try ManagedLifecycleV1.initV1(25);
    try retired_lifecycle.markReadyV1();
    const retired_sequence = try retired_lifecycle.beginConnectionV1(
        retired_connection.stream.handle,
    );
    try std.testing.expect(
        try retired_lifecycle.retireActiveConnectionReceiveV1(
            25,
            retired_sequence,
            retired_connection.stream.handle,
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
            25,
            retired_sequence,
            retired_connection.stream.handle,
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
    try retired_lifecycle.finishConnectionV1(
        retired_sequence,
        retired_connection.stream.handle,
        false,
    );
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
    const expired_sequence = try expired_lifecycle.beginConnectionV1(
        expired_connection.stream.handle,
    );
    try std.testing.expect(
        !(try expired_lifecycle.retireActiveConnectionReceiveV1(
            26,
            expired_sequence,
            expired_connection.stream.handle,
            &expired_timer,
            minimum_receive_timeout_ns,
        )),
    );
    try std.testing.expect(
        !(try expired_lifecycle.retireActiveConnectionReceiveV1(
            26,
            expired_sequence,
            expired_connection.stream.handle,
            &expired_timer,
            minimum_receive_timeout_ns,
        )),
    );
    try std.testing.expect(
        !(try expired_lifecycle.signalActiveConnectionForReceiveTimeoutV1(
            26,
            expired_sequence,
            expired_connection.stream.handle,
        )),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        expired_lifecycle.snapshotV1().receive_timeout_signaled_connections,
    );
    try expired_lifecycle.finishConnectionV1(
        expired_sequence,
        expired_connection.stream.handle,
        false,
    );
}
