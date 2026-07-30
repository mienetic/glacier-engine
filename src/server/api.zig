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

pub const ServerConfig = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    stop_after_requests: ?u64 = null,
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
