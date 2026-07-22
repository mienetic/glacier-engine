//! Prefix / KV cache store (STUB).
//!
//! Out of MVP scope. Sketched so the rest of the engine compiles.
//! See docs/DESIGN.md §2 — eventually content-addressed KV cache that
//! can be reused across sessions for repeated system prompts / RAG.

const std = @import("std");

pub const PrefixStore = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PrefixStore {
        return .{ .allocator = allocator };
    }
    pub fn deinit(_: *PrefixStore) void {}

    /// MVP: always reports a miss. Real impl hashes the prompt prefix and
    /// returns cached KV tensors if present.
    pub fn lookup(_: *PrefixStore, prefix_tokens: []const u32) ?[]const u8 {
        _ = prefix_tokens;
        return null;
    }
};
