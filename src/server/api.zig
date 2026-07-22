//! OpenAI-compatible HTTP server (STUB).
//!
//! Out of MVP scope. Once inference works we expose it as
//! POST /v1/chat/completions so anything that speaks OpenAI can drive it.

const std = @import("std");

pub const ServerConfig = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

/// Not implemented yet.
pub fn run(_: ServerConfig) !void {
    return error.NotImplemented;
}
