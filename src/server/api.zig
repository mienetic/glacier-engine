//! Bounded loopback HTTP/1.1 socket adapter.
//!
//! This layer owns only listener and connection framing. Request decoding,
//! service execution, and response encoding remain in
//! `prepared_text_unary_http.zig`.

const std = @import("std");
const builtin = @import("builtin");
const prepared_http = @import("prepared_text_unary_http.zig");

pub const Error = error{
    InvalidConfiguration,
    NonLoopbackBind,
    ReceiveTimeoutRequiresManagedLifecycle,
};

pub const minimum_receive_timeout_ns: u64 = std.time.ns_per_ms;
pub const maximum_receive_timeout_ns: u64 = 60 * std.time.ns_per_s;

pub const LifecycleError = error{
    InvalidGeneration,
    InvalidTransition,
    ConnectionAlreadyActive,
    NoActiveConnection,
    ConnectionSequenceMismatch,
    ConnectionHandleMismatch,
    ConnectionPhaseMismatch,
    ConnectionInterrupted,
    CounterOverflow,
};

pub const ServerConfig = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    stop_after_requests: ?u64 = null,
    /// Absolute monotonic elapsed-time bound from accept through the last
    /// required request byte. Zero disables the bounded receive timer.
    receive_timeout_ns: u64 = 0,
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
    active_connection_phase: ManagedConnectionPhaseV1,
    last_drain_signaled_phase: ManagedConnectionPhaseV1,
    last_receive_timeout_signaled_phase: ManagedConnectionPhaseV1,
};

const ActiveConnectionV1 = struct {
    process_generation: u64,
    sequence: u64,
    handle: std.net.Stream.Handle,
    phase: ManagedConnectionPhaseV1 = .receiving_head,
    drain_signaled: bool = false,
    receive_timeout_signaled: bool = false,
    receive_retired: bool = false,
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
    last_drain_signaled_phase: ManagedConnectionPhaseV1 = .none,
    last_receive_timeout_signaled_phase: ManagedConnectionPhaseV1 = .none,
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
            .active_connection_phase = if (self.active_connection) |active|
                active.phase
            else
                .none,
            .last_drain_signaled_phase = self.last_drain_signaled_phase,
            .last_receive_timeout_signaled_phase = self.last_receive_timeout_signaled_phase,
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
            receive_timer,
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
            _ = prepared_http.beginDrainV1(runtime);
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
            _ = prepared_http.beginDrainV1(runtime);
            break :blk lifecycle.active_connection != null;
        },
        else => LifecycleError.InvalidTransition,
    };
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

fn serveManagedConnectionV1(
    connection: std.net.Server.Connection,
    runtime: *prepared_http.RuntimeV1,
    lifecycle: *ManagedLifecycleV1,
    sequence: u64,
    receive_timeout_ns: u64,
    receive_timer: ?std.time.Timer,
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
        stop_error == null;
    try lifecycle.finishConnectionV1(
        sequence,
        owned_connection.stream.handle,
        connection_succeeded,
    );
    if (receive_timeout.signal_error) |err| return err;
    if (stop_error) |err| return err;
    return connection_succeeded;
}

fn serveOpenConnectionV1(
    stream: *std.net.Stream,
    runtime: *prepared_http.RuntimeV1,
    receive_timeout: ?*ManagedReceiveTimeoutV1,
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
    var server = std.http.Server.init(
        reader,
        &connection_writer.interface,
    );
    var request = try server.receiveHead();
    if (receive_timeout) |timeout| {
        try timeout.markHeadReceived();
    }
    var workspace: prepared_http.WorkspaceV1 = undefined;
    if (receive_timeout) |timeout| {
        try prepared_http.serveRequestWithReceiveControlV1(
            runtime,
            &request,
            &workspace,
            .{
                .context = timeout,
                .complete_fn = ManagedReceiveTimeoutV1.completeOpaque,
                .stop_fn = ManagedReceiveTimeoutV1.stopOpaque,
            },
        );
    } else {
        try prepared_http.serveRequestV1(
            runtime,
            &request,
            &workspace,
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
    if (!std.mem.eql(u8, config.bind, "127.0.0.1") and
        !std.mem.eql(u8, config.bind, "::1"))
    {
        return Error.NonLoopbackBind;
    }
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
