//! Bounded loopback HTTP/1.1 socket adapter.
//!
//! This layer owns only listener and connection framing. Request decoding,
//! service execution, and response encoding remain in
//! `prepared_text_unary_http.zig`.

const std = @import("std");
const prepared_http = @import("prepared_text_unary_http.zig");

pub const Error = error{
    InvalidConfiguration,
    NonLoopbackBind,
};

pub const LifecycleError = error{
    InvalidGeneration,
    InvalidTransition,
    ConnectionAlreadyActive,
    NoActiveConnection,
    ConnectionSequenceMismatch,
    CounterOverflow,
};

pub const ServerConfig = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    stop_after_requests: ?u64 = null,
};

pub const ManagedStateV1 = enum(u8) {
    starting = 1,
    ready = 2,
    draining = 3,
    stopped = 4,
    failed = 5,
};

pub const ManagedSnapshotV1 = struct {
    process_generation: u64,
    state: ManagedStateV1,
    accepted_connections: u64,
    completed_connections: u64,
    failed_connections: u64,
    active_connections: u8,
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

    /// Publishes that listener admission is draining. The managed adapter
    /// closes runtime completion admission before making this state visible.
    fn requestDrainV1(
        self: *ManagedLifecycleV1,
    ) LifecycleError!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.state) {
            .ready => blk: {
                self.state = .draining;
                break :blk true;
            },
            .draining => false,
            else => LifecycleError.InvalidTransition,
        };
    }

    pub fn beginConnectionV1(
        self: *ManagedLifecycleV1,
    ) LifecycleError!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .ready)
            return LifecycleError.InvalidTransition;
        if (self.active_connections != 0)
            return LifecycleError.ConnectionAlreadyActive;
        self.accepted_connections = std.math.add(
            u64,
            self.accepted_connections,
            1,
        ) catch return LifecycleError.CounterOverflow;
        self.active_connections = 1;
        return self.accepted_connections;
    }

    pub fn finishConnectionV1(
        self: *ManagedLifecycleV1,
        connection_sequence: u64,
        succeeded: bool,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_connections != 1)
            return LifecycleError.NoActiveConnection;
        if (connection_sequence != self.accepted_connections)
            return LifecycleError.ConnectionSequenceMismatch;
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
    }

    pub fn markStoppedV1(
        self: *ManagedLifecycleV1,
    ) LifecycleError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .draining or
            self.active_connections != 0)
        {
            return LifecycleError.InvalidTransition;
        }
        self.state = .stopped;
    }

    pub fn markFailedV1(self: *ManagedLifecycleV1) void {
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
        };
    }
};

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
        const sequence = lifecycle.beginConnectionV1() catch |err| {
            connection.stream.close();
            if (err == LifecycleError.InvalidTransition) break;
            lifecycle.markFailedV1();
            return err;
        };

        serveConnectionV1(connection, runtime) catch {
            lifecycle.finishConnectionV1(sequence, false) catch |err| {
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
            continue;
        };
        lifecycle.finishConnectionV1(sequence, true) catch |err| {
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
    _ = try beginManagedDrainV1(lifecycle, runtime);
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
) LifecycleError!bool {
    lifecycle.mutex.lock();
    defer lifecycle.mutex.unlock();
    return switch (lifecycle.state) {
        .ready => blk: {
            _ = prepared_http.beginDrainV1(runtime);
            lifecycle.state = .draining;
            break :blk true;
        },
        .draining => blk: {
            _ = prepared_http.beginDrainV1(runtime);
            break :blk false;
        },
        else => LifecycleError.InvalidTransition,
    };
}

pub fn serveConnectionV1(
    connection: std.net.Server.Connection,
    runtime: *prepared_http.RuntimeV1,
) !void {
    defer connection.stream.close();

    var receive_buffer: [prepared_http.header_max_bytes]u8 = undefined;
    var send_buffer: [4096]u8 = undefined;
    var connection_reader = connection.stream.reader(&receive_buffer);
    var connection_writer = connection.stream.writer(&send_buffer);
    var server = std.http.Server.init(
        connection_reader.interface(),
        &connection_writer.interface,
    );
    var request = try server.receiveHead();
    var workspace: prepared_http.WorkspaceV1 = undefined;
    try prepared_http.serveRequestV1(runtime, &request, &workspace);
}

fn validateConfig(config: ServerConfig) Error!void {
    if (config.bind.len == 0) return Error.InvalidConfiguration;
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
    try std.testing.expect(isLoopbackAddress(
        try std.net.Address.parseIp("127.0.0.1", 0),
    ));
    try std.testing.expect(isLoopbackAddress(
        try std.net.Address.parseIp("::1", 0),
    ));
    try std.testing.expect(!isLoopbackAddress(
        try std.net.Address.parseIp("0.0.0.0", 0),
    ));
}

test "managed lifecycle has one drain linearization point" {
    try std.testing.expectError(
        LifecycleError.InvalidGeneration,
        ManagedLifecycleV1.initV1(0),
    );
    var lifecycle = try ManagedLifecycleV1.initV1(7);
    try lifecycle.markReadyV1();
    const sequence = try lifecycle.beginConnectionV1();
    try std.testing.expect(try lifecycle.requestDrainV1());
    try std.testing.expect(!(try lifecycle.requestDrainV1()));
    try std.testing.expectError(
        LifecycleError.InvalidTransition,
        lifecycle.beginConnectionV1(),
    );
    try lifecycle.finishConnectionV1(sequence, true);
    try lifecycle.markStoppedV1();
    try std.testing.expectEqualDeep(
        ManagedSnapshotV1{
            .process_generation = 7,
            .state = .stopped,
            .accepted_connections = 1,
            .completed_connections = 1,
            .failed_connections = 0,
            .active_connections = 0,
        },
        lifecycle.snapshotV1(),
    );

    var starting = try ManagedLifecycleV1.initV1(8);
    var runtime: prepared_http.RuntimeV1 = .{
        .service = undefined,
        .model_binding_sha256 = [_]u8{0} ** 32,
        .model_id = undefined,
    };
    try std.testing.expectError(
        LifecycleError.InvalidTransition,
        beginManagedDrainV1(&starting, &runtime),
    );
    try std.testing.expect(
        prepared_http.acceptingCompletionsV1(&runtime),
    );
    try starting.markReadyV1();
    try std.testing.expect(
        try beginManagedDrainV1(&starting, &runtime),
    );
    try std.testing.expect(
        !prepared_http.acceptingCompletionsV1(&runtime),
    );
    try std.testing.expectEqual(
        ManagedStateV1.draining,
        starting.snapshotV1().state,
    );
}
