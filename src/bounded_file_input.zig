//! Bounded, stable regular-file input for user-facing runtime commands.
//!
//! POSIX `O_NONBLOCK|O_NOFOLLOW` prevents a FIFO or symlink from turning a
//! bounded read into an ambient blocking or path-redirection authority. The
//! descriptor is classified before allocation and re-statted after positional
//! reads so callers never accept a mixed snapshot.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    UnsupportedPlatform,
    InvalidPath,
    NotRegularFile,
    FileTooLarge,
    InputChanged,
    UnexpectedEndOfFile,
    OutOfMemory,
};

pub fn availableV1() bool {
    return switch (builtin.os.tag) {
        .macos, .linux, .freebsd => true,
        else => false,
    };
}

/// Open one regular file without following the final symlink or waiting on a
/// FIFO. The caller owns the returned descriptor.
pub fn openRegularV1(path: []const u8) !std.fs.File {
    if (path.len == 0) return Error.InvalidPath;
    if (comptime !availableV1())
        return Error.UnsupportedPlatform;
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW") or
        !@hasField(std.posix.O, "NONBLOCK"))
        return Error.UnsupportedPlatform;

    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.CLOEXEC = true;
    flags.NOFOLLOW = true;
    flags.NONBLOCK = true;
    if (@hasField(std.posix.O, "NOCTTY"))
        flags.NOCTTY = true;
    const descriptor = try std.posix.open(path, flags, 0);
    const file: std.fs.File = .{ .handle = descriptor };
    errdefer file.close();
    const stat = try file.stat();
    if (stat.kind != .file)
        return Error.NotRegularFile;
    return file;
}

pub fn readAllocV1(
    allocator: std.mem.Allocator,
    path: []const u8,
    maximum_bytes: u64,
) ![]u8 {
    const file = try openRegularV1(path);
    defer file.close();

    const before = try file.stat();
    if (before.size > maximum_bytes)
        return Error.FileTooLarge;
    const byte_count = std.math.cast(usize, before.size) orelse
        return Error.FileTooLarge;
    const bytes = allocator.alloc(u8, byte_count) catch
        return Error.OutOfMemory;
    errdefer allocator.free(bytes);

    var offset: usize = 0;
    while (offset < bytes.len) {
        const read_count = try file.pread(
            bytes[offset..],
            @intCast(offset),
        );
        if (read_count == 0)
            return Error.UnexpectedEndOfFile;
        offset += read_count;
    }

    const after = try file.stat();
    if (before.kind != after.kind or
        before.inode != after.inode or
        before.size != after.size or
        before.mtime != after.mtime or
        before.ctime != after.ctime)
        return Error.InputChanged;
    return bytes;
}

test "bounded input rejects nonregular files before reading" {
    if (comptime !availableV1()) return;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("directory");
    const absolute = try temporary.dir.realpathAlloc(
        std.testing.allocator,
        "directory",
    );
    defer std.testing.allocator.free(absolute);
    try std.testing.expectError(
        Error.NotRegularFile,
        readAllocV1(
            std.testing.allocator,
            absolute,
            16,
        ),
    );
}
