//! Bounded, cancellation-aware socket output for synchronous HTTP serving.
//!
//! `std.Io.Writer` exposes only `error.WriteFailed`; the sticky `failure`
//! field retains the typed reason. The caller owns the socket and the control
//! context for the lifetime of `WriterV1`. On Windows, the first nonempty send
//! leaves the socket in nonblocking mode; the managed server closes that
//! single-owner connection after the response instead of reusing the handle.

const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
const ws2_32 = windows.ws2_32;

pub const minimum_max_send_bytes: u16 = 1;
pub const maximum_max_send_bytes: u16 = 4096;
pub const minimum_poll_interval_ms: u16 = 1;
pub const maximum_poll_interval_ms: u16 = 1000;

pub const ConfigError = error{
    InvalidMaxSendBytes,
    InvalidPollInterval,
};

pub const ConfigV1 = struct {
    /// Upper bound for one kernel send, including already-buffered bytes,
    /// ordinary data slices, and repetitions of the final splat slice.
    max_send_bytes: u16 = maximum_max_send_bytes,
    /// Finite cancellation latency quantum while a nonblocking send is not
    /// writable. The operating system may still add scheduler latency.
    poll_interval_ms: u16 = 25,

    pub fn validateV1(self: ConfigV1) ConfigError!void {
        if (self.max_send_bytes < minimum_max_send_bytes or
            self.max_send_bytes > maximum_max_send_bytes)
        {
            return ConfigError.InvalidMaxSendBytes;
        }
        if (self.poll_interval_ms < minimum_poll_interval_ms or
            self.poll_interval_ms > maximum_poll_interval_ms)
        {
            return ConfigError.InvalidPollInterval;
        }
    }
};

pub const DispositionV1 = enum(u8) {
    proceed,
    cancelled,
};

pub const EventKindV1 = enum(u8) {
    before_send,
    progress,
    would_block,
};

pub const EventV1 = union(EventKindV1) {
    before_send: struct {},
    progress: usize,
    would_block: struct {},
};

pub const ConnectionClosedV1 = enum(u8) {
    send_returned_zero,
    peer_reset,
    connection_aborted,
    not_connected,
    send_shutdown,
    broken_pipe,
    connection_refused,
    poll_hangup,
};

pub const TransportOperationV1 = enum(u8) {
    set_nonblocking,
    send,
    poll,
};

pub const FailureKindV1 = enum(u8) {
    cancelled,
    connection_closed,
    transport,
    control,
};

pub const FailureV1 = union(FailureKindV1) {
    /// Cancellation observed before another byte is submitted to the kernel.
    cancelled: EventV1,
    connection_closed: ConnectionClosedV1,
    transport: TransportOperationV1,
    /// The event callback returned an error. `control_error` retains it.
    control: EventV1,
};

pub const ControlV1 = struct {
    context: *anyopaque,
    event_fn: *const fn (
        context: *anyopaque,
        event: EventV1,
    ) anyerror!DispositionV1,
    /// Called once, after the primary failure becomes sticky. An error from
    /// this callback never replaces that primary failure and is retained in
    /// `failure_callback_error`.
    failure_fn: *const fn (
        context: *anyopaque,
        failure: FailureV1,
    ) anyerror!void,

    fn event(
        self: ControlV1,
        value: EventV1,
    ) anyerror!DispositionV1 {
        return self.event_fn(self.context, value);
    }

    fn failed(
        self: ControlV1,
        value: FailureV1,
    ) anyerror!void {
        return self.failure_fn(self.context, value);
    }
};

pub const WriterV1 = struct {
    interface: std.Io.Writer,
    handle: std.net.Stream.Handle,
    config: ConfigV1,
    control: ControlV1,
    /// First terminal output failure. Later writer calls preserve this value.
    failure: ?FailureV1 = null,
    /// Exact error returned by `event_fn` when `failure` is `.control`.
    control_error: ?anyerror = null,
    /// Exact error returned by the one-shot failure notification.
    failure_callback_error: ?anyerror = null,
    /// A cancellation returned from `progress` is deferred until another
    /// nonempty send is required. This lets the final successful kernel send
    /// remain a successful write.
    pending_cancellation: ?EventV1 = null,
    windows_nonblocking_ready: bool =
        builtin.os.tag != .windows,

    /// Initialization is socket-side-effect free. On Windows, `FIONBIO` is
    /// applied lazily immediately before the first nonempty send, after an
    /// initial `before_send` cancellation checkpoint.
    pub fn init(
        handle: std.net.Stream.Handle,
        buffer: []u8,
        config: ConfigV1,
        control: ControlV1,
    ) ConfigError!WriterV1 {
        try config.validateV1();
        return .{
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
            .handle = handle,
            .config = config,
            .control = control,
        };
    }

    pub fn interfaceV1(self: *WriterV1) *std.Io.Writer {
        return &self.interface;
    }

    pub fn getFailureV1(self: *const WriterV1) ?FailureV1 {
        return self.failure;
    }

    fn recordFailureV1(
        self: *WriterV1,
        value: FailureV1,
    ) std.Io.Writer.Error {
        if (self.failure == null) {
            self.failure = value;
            self.control.failed(value) catch |err| {
                self.failure_callback_error = err;
            };
        }
        return error.WriteFailed;
    }

    fn dispatchEventV1(
        self: *WriterV1,
        event: EventV1,
    ) std.Io.Writer.Error!DispositionV1 {
        return self.control.event(event) catch |err| {
            self.control_error = err;
            return self.recordFailureV1(.{ .control = event });
        };
    }

    fn checkEventV1(
        self: *WriterV1,
        event: EventV1,
    ) std.Io.Writer.Error!void {
        if (try self.dispatchEventV1(event) == .cancelled)
            return self.recordFailureV1(.{ .cancelled = event });
    }

    fn reportProgressV1(
        self: *WriterV1,
        bytes_sent: usize,
    ) std.Io.Writer.Error!void {
        const event: EventV1 = .{ .progress = bytes_sent };
        if (try self.dispatchEventV1(event) == .cancelled)
            self.pending_cancellation = event;
    }

    fn surfacePendingCancellationV1(
        self: *WriterV1,
    ) std.Io.Writer.Error!void {
        const event = self.pending_cancellation orelse return;
        return self.recordFailureV1(.{ .cancelled = event });
    }

    fn ensureWindowsNonblockingV1(
        self: *WriterV1,
    ) std.Io.Writer.Error!void {
        if (builtin.os.tag != .windows or
            self.windows_nonblocking_ready)
        {
            return;
        }

        var enabled: u32 = 1;
        if (ws2_32.ioctlsocket(
            self.handle,
            ws2_32.FIONBIO,
            &enabled,
        ) == ws2_32.SOCKET_ERROR) {
            return self.recordFailureV1(
                .{ .transport = .set_nonblocking },
            );
        }
        self.windows_nonblocking_ready = true;
    }

    fn drain(
        io_writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *WriterV1 = @alignCast(
            @fieldParentPtr("interface", io_writer),
        );
        if (self.failure != null) return error.WriteFailed;

        var storage: [maximum_max_send_bytes]u8 = undefined;
        const gathered = gatherV1(
            storage[0..self.config.max_send_bytes],
            io_writer.buffered(),
            data,
            splat,
        );
        if (gathered.len == 0) return 0;

        try self.surfacePendingCancellationV1();

        while (true) {
            try self.checkEventV1(.{ .before_send = .{} });
            try self.ensureWindowsNonblockingV1();

            switch (sendOnceV1(self.handle, gathered)) {
                .progress => |bytes_sent| {
                    const consumed = io_writer.consume(bytes_sent);
                    // Progress is emitted only after the kernel reports a
                    // positive send. A callback error is terminal; a returned
                    // cancellation is deferred until another send is needed.
                    try self.reportProgressV1(bytes_sent);
                    return consumed;
                },
                .would_block => {
                    try self.checkEventV1(
                        .{ .would_block = .{} },
                    );
                    switch (waitWritableV1(
                        self.handle,
                        self.config.poll_interval_ms,
                    )) {
                        .retry => continue,
                        .connection_closed => |reason| {
                            return self.recordFailureV1(.{
                                .connection_closed = reason,
                            });
                        },
                        .transport => {
                            return self.recordFailureV1(
                                .{ .transport = .poll },
                            );
                        },
                    }
                },
                .connection_closed => |reason| {
                    return self.recordFailureV1(.{
                        .connection_closed = reason,
                    });
                },
                .transport => {
                    return self.recordFailureV1(
                        .{ .transport = .send },
                    );
                },
            }
        }
    }
};

const SendResultV1 = union(enum) {
    progress: usize,
    would_block,
    connection_closed: ConnectionClosedV1,
    transport,
};

fn sendOnceV1(
    handle: std.net.Stream.Handle,
    bytes: []const u8,
) SendResultV1 {
    if (builtin.os.tag == .windows) {
        const result = ws2_32.send(
            handle,
            bytes.ptr,
            @intCast(bytes.len),
            0,
        );
        if (result == ws2_32.SOCKET_ERROR) {
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEWOULDBLOCK => .would_block,
                .WSAECONNRESET, .WSAENETRESET => .{
                    .connection_closed = .peer_reset,
                },
                .WSAECONNABORTED => .{
                    .connection_closed = .connection_aborted,
                },
                .WSAENOTCONN => .{
                    .connection_closed = .not_connected,
                },
                // Unlike std.net.Writer, a concurrent send shutdown is a
                // recoverable transport outcome rather than unreachable.
                .WSAESHUTDOWN => .{
                    .connection_closed = .send_shutdown,
                },
                else => .transport,
            };
        }
        if (result == 0) return .{
            .connection_closed = .send_returned_zero,
        };
        return .{ .progress = @intCast(result) };
    }

    const flags: u32 =
        std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL;
    const count = std.posix.sendto(
        handle,
        bytes,
        flags,
        null,
        0,
    ) catch |err| {
        if (err == error.WouldBlock) return .would_block;
        if (err == error.ConnectionResetByPeer) return .{
            .connection_closed = .peer_reset,
        };
        if (err == error.SocketNotConnected) return .{
            .connection_closed = .not_connected,
        };
        if (err == error.BrokenPipe) return .{
            .connection_closed = .broken_pipe,
        };
        if (err == error.ConnectionRefused) return .{
            .connection_closed = .connection_refused,
        };
        return .transport;
    };
    if (count == 0) return .{
        .connection_closed = .send_returned_zero,
    };
    return .{ .progress = count };
}

const WaitResultV1 = union(enum) {
    retry,
    connection_closed: ConnectionClosedV1,
    transport,
};

fn waitWritableV1(
    handle: std.net.Stream.Handle,
    poll_interval_ms: u16,
) WaitResultV1 {
    if (builtin.os.tag == .windows) {
        var descriptors = [1]ws2_32.WSAPOLLFD{.{
            .fd = handle,
            .events = ws2_32.POLL.OUT,
            .revents = 0,
        }};
        const result = ws2_32.WSAPoll(
            &descriptors,
            descriptors.len,
            @intCast(poll_interval_ms),
        );
        if (result == ws2_32.SOCKET_ERROR) return .transport;
        if (result == 0) return .retry;
        const events = descriptors[0].revents;
        if ((events & ws2_32.POLL.OUT) != 0) return .retry;
        if ((events & ws2_32.POLL.HUP) != 0) return .{
            .connection_closed = .poll_hangup,
        };
        if ((events & (ws2_32.POLL.ERR |
            ws2_32.POLL.NVAL)) != 0)
        {
            return .transport;
        }
        return .retry;
    }

    var descriptors = [1]std.posix.pollfd{.{
        .fd = handle,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};
    const result = std.posix.poll(
        &descriptors,
        @intCast(poll_interval_ms),
    ) catch return .transport;
    if (result == 0) return .retry;
    const events = descriptors[0].revents;
    if ((events & std.posix.POLL.OUT) != 0) return .retry;
    if ((events & std.posix.POLL.HUP) != 0) return .{
        .connection_closed = .poll_hangup,
    };
    if ((events & (std.posix.POLL.ERR |
        std.posix.POLL.NVAL)) != 0)
    {
        return .transport;
    }
    return .retry;
}

fn gatherV1(
    destination: []u8,
    buffered: []const u8,
    data: []const []const u8,
    splat: usize,
) []const u8 {
    var end: usize = 0;
    appendPrefixV1(destination, &end, buffered);
    if (end == destination.len or data.len == 0)
        return destination[0..end];

    for (data[0 .. data.len - 1]) |bytes| {
        appendPrefixV1(destination, &end, bytes);
        if (end == destination.len) return destination;
    }

    const pattern = data[data.len - 1];
    if (pattern.len == 0 or splat == 0)
        return destination[0..end];
    var remaining = splat;
    while (remaining != 0 and end != destination.len) : (remaining -= 1) {
        appendPrefixV1(destination, &end, pattern);
    }
    return destination[0..end];
}

fn appendPrefixV1(
    destination: []u8,
    end: *usize,
    source: []const u8,
) void {
    const count = @min(destination.len - end.*, source.len);
    @memcpy(destination[end.*..][0..count], source[0..count]);
    end.* += count;
}

test "ConfigV1 bounds send and poll quanta" {
    try (ConfigV1{
        .max_send_bytes = minimum_max_send_bytes,
        .poll_interval_ms = minimum_poll_interval_ms,
    }).validateV1();
    try (ConfigV1{
        .max_send_bytes = maximum_max_send_bytes,
        .poll_interval_ms = maximum_poll_interval_ms,
    }).validateV1();
    try std.testing.expectError(
        ConfigError.InvalidMaxSendBytes,
        (ConfigV1{ .max_send_bytes = 0 }).validateV1(),
    );
    try std.testing.expectError(
        ConfigError.InvalidMaxSendBytes,
        (ConfigV1{
            .max_send_bytes = maximum_max_send_bytes + 1,
        }).validateV1(),
    );
    try std.testing.expectError(
        ConfigError.InvalidPollInterval,
        (ConfigV1{ .poll_interval_ms = 0 }).validateV1(),
    );
    try std.testing.expectError(
        ConfigError.InvalidPollInterval,
        (ConfigV1{
            .poll_interval_ms = maximum_poll_interval_ms + 1,
        }).validateV1(),
    );
}

test "gatherV1 caps buffered data slices and splats together" {
    var storage: [7]u8 = undefined;
    const gathered = gatherV1(
        &storage,
        "ab",
        &.{ "cd", "xy" },
        3,
    );
    try std.testing.expectEqualStrings("abcdxyx", gathered);

    var complete_storage: [16]u8 = undefined;
    const complete = gatherV1(
        &complete_storage,
        "ab",
        &.{ "cd", "xy" },
        3,
    );
    try std.testing.expectEqualStrings("abcdxyxyxy", complete);

    var buffered_only_storage: [3]u8 = undefined;
    const buffered_only = gatherV1(
        &buffered_only_storage,
        "abcdef",
        &.{"ignored"},
        1,
    );
    try std.testing.expectEqualStrings(
        "abc",
        buffered_only,
    );
}

const TestControlV1 = struct {
    cancel_kind: ?EventKindV1 = null,
    cancel_would_block_after: usize = 0,
    event_error_kind: ?EventKindV1 = null,
    event_count: usize = 0,
    progress_bytes: usize = 0,
    would_block_count: usize = 0,
    failure_count: usize = 0,
    failure: ?FailureV1 = null,
    fail_failure_callback: bool = false,

    fn eventOpaque(
        context: *anyopaque,
        event: EventV1,
    ) anyerror!DispositionV1 {
        const self: *TestControlV1 =
            @ptrCast(@alignCast(context));
        self.event_count += 1;
        const kind = std.meta.activeTag(event);
        if (kind == .progress) self.progress_bytes += event.progress;
        if (kind == .would_block) {
            self.would_block_count += 1;
            if (self.cancel_would_block_after != 0 and
                self.would_block_count >=
                    self.cancel_would_block_after)
            {
                return .cancelled;
            }
        }
        if (self.event_error_kind == kind)
            return error.InjectedControlFailure;
        if (self.cancel_kind == kind) return .cancelled;
        return .proceed;
    }

    fn failureOpaque(
        context: *anyopaque,
        failure: FailureV1,
    ) anyerror!void {
        const self: *TestControlV1 =
            @ptrCast(@alignCast(context));
        self.failure_count += 1;
        self.failure = failure;
        if (self.fail_failure_callback)
            return error.InjectedFailureCallbackFailure;
    }

    fn control(self: *TestControlV1) ControlV1 {
        return .{
            .context = self,
            .event_fn = eventOpaque,
            .failure_fn = failureOpaque,
        };
    }
};

test "control cancellation is sticky and failure callback is one shot" {
    var state: TestControlV1 = .{
        .cancel_kind = .before_send,
    };
    var buffer: [0]u8 = .{};
    var writer = try WriterV1.init(
        undefined,
        &buffer,
        .{},
        state.control(),
    );

    try std.testing.expectError(
        error.WriteFailed,
        writer.checkEventV1(.{ .before_send = .{} }),
    );
    try std.testing.expectError(
        error.WriteFailed,
        writer.checkEventV1(.{ .before_send = .{} }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.failure_count);
    try std.testing.expect(
        std.meta.activeTag(writer.failure.?) == .cancelled,
    );
    try std.testing.expect(
        std.meta.activeTag(writer.failure.?.cancelled) ==
            .before_send,
    );
}

test "progress cancellation waits for another send" {
    var state: TestControlV1 = .{
        .cancel_kind = .progress,
    };
    var buffer: [0]u8 = .{};
    var writer = try WriterV1.init(
        undefined,
        &buffer,
        .{},
        state.control(),
    );

    try writer.reportProgressV1(9);
    try std.testing.expectEqual(@as(usize, 9), state.progress_bytes);
    try std.testing.expect(writer.failure == null);
    try std.testing.expect(writer.pending_cancellation != null);
    try std.testing.expectError(
        error.WriteFailed,
        writer.surfacePendingCancellationV1(),
    );
    try std.testing.expect(
        std.meta.activeTag(writer.failure.?) == .cancelled,
    );
    try std.testing.expect(
        std.meta.activeTag(writer.failure.?.cancelled) ==
            .progress,
    );
}

test "control and failure callback errors retain separate evidence" {
    var state: TestControlV1 = .{
        .event_error_kind = .would_block,
        .fail_failure_callback = true,
    };
    var buffer: [0]u8 = .{};
    var writer = try WriterV1.init(
        undefined,
        &buffer,
        .{},
        state.control(),
    );

    try std.testing.expectError(
        error.WriteFailed,
        writer.checkEventV1(.{ .would_block = .{} }),
    );
    try std.testing.expect(
        std.meta.activeTag(writer.failure.?) == .control,
    );
    try std.testing.expect(
        std.meta.activeTag(writer.failure.?.control) ==
            .would_block,
    );
    try std.testing.expectEqual(
        error.InjectedControlFailure,
        writer.control_error.?,
    );
    try std.testing.expectEqual(
        error.InjectedFailureCallbackFailure,
        writer.failure_callback_error.?,
    );
}

test "real loopback saturation reaches would-block cancellation" {
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

    const socket_buffer_bytes: c_int = 4096;
    try std.posix.setsockopt(
        connection.stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        std.mem.asBytes(&socket_buffer_bytes),
    );
    try std.posix.setsockopt(
        peer.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVBUF,
        std.mem.asBytes(&socket_buffer_bytes),
    );

    var state: TestControlV1 = .{
        // The first WouldBlock enters one finite poll interval. With the peer
        // intentionally not reading, the retry reaches a second WouldBlock
        // and cancellation, covering the bounded poll-timeout path.
        .cancel_would_block_after = 2,
    };
    var writer_buffer: [0]u8 = .{};
    var writer = try WriterV1.init(
        connection.stream.handle,
        &writer_buffer,
        .{
            .max_send_bytes = maximum_max_send_bytes,
            .poll_interval_ms = minimum_poll_interval_ms,
        },
        state.control(),
    );
    const payload = [_]u8{0x5a} ** maximum_max_send_bytes;
    var cancelled = false;
    for (0..16 * 1024) |_| {
        writer.interface.writeAll(&payload) catch |err| {
            try std.testing.expectEqual(error.WriteFailed, err);
            cancelled = true;
            break;
        };
    }

    try std.testing.expect(cancelled);
    try std.testing.expect(state.progress_bytes != 0);
    try std.testing.expectEqual(
        @as(usize, 2),
        state.would_block_count,
    );
    try std.testing.expectEqual(@as(usize, 1), state.failure_count);
    try std.testing.expect(writer.failure.? == .cancelled);
    try std.testing.expect(
        writer.failure.?.cancelled == .would_block,
    );
}
