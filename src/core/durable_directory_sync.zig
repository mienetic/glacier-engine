//! Descriptor-relative directory synchronization for durable file adapters.
//!
//! A default `std.fs.Dir` may be backed by a path-only descriptor on systems
//! that provide one. Path-only descriptors preserve relative namespace
//! authority but cannot themselves be synchronized. This adapter reopens the
//! same pinned directory with sync-capable access before issuing `fsync`.

const std = @import("std");
const platform_capabilities = @import("platform_capabilities.zig");

pub const SyncError =
    std.fs.Dir.OpenError ||
    error{
        UnsupportedPlatform,
        InvalidDirectoryHandle,
        DirectorySyncUnsupported,
        ReadOnlyFileSystem,
        AccessDenied,
        PermissionDenied,
        InputOutput,
        NoSpaceLeft,
        DiskQuota,
        Unexpected,
    };

/// Synchronizes namespace changes beneath an already-open directory.
///
/// Reopening `"."` is descriptor-relative: it does not resolve the original
/// caller path again and therefore retains the caller's pinned directory
/// authority. The caller must supply a live `std.fs.Dir` that it still owns.
pub fn sync(directory: std.fs.Dir) SyncError!void {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.UnsupportedPlatform;

    var syncable = try directory.openDir(".", .{
        .access_sub_paths = false,
        .iterate = true,
        .no_follow = true,
    });
    defer syncable.close();
    try syncDescriptor(syncable.fd);
}

const SyncAction = enum {
    complete,
    retry,
};

fn classifySyncErrno(value: std.posix.E) SyncError!SyncAction {
    return switch (value) {
        .SUCCESS => .complete,
        .INTR => .retry,
        .BADF => error.InvalidDirectoryHandle,
        .INVAL, .NOSYS, .OPNOTSUPP => error.DirectorySyncUnsupported,
        .ROFS => error.ReadOnlyFileSystem,
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn syncDescriptor(fd: std.posix.fd_t) SyncError!void {
    while (true) {
        switch (try classifySyncErrno(
            std.posix.errno(std.posix.system.fsync(fd)),
        )) {
            .complete => return,
            .retry => continue,
        }
    }
}

test "default directory handles reopen with sync-capable access" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try sync(temporary.dir);
}

test "sync errno classification is explicit" {
    try std.testing.expectEqual(
        SyncAction.complete,
        try classifySyncErrno(.SUCCESS),
    );
    try std.testing.expectEqual(
        SyncAction.retry,
        try classifySyncErrno(.INTR),
    );
    try std.testing.expectError(
        error.InvalidDirectoryHandle,
        classifySyncErrno(.BADF),
    );
    try std.testing.expectError(
        error.DirectorySyncUnsupported,
        classifySyncErrno(.INVAL),
    );
    try std.testing.expectError(
        error.DirectorySyncUnsupported,
        classifySyncErrno(.NOSYS),
    );
    try std.testing.expectError(
        error.DirectorySyncUnsupported,
        classifySyncErrno(.OPNOTSUPP),
    );
    try std.testing.expectError(
        error.ReadOnlyFileSystem,
        classifySyncErrno(.ROFS),
    );
    try std.testing.expectError(
        error.AccessDenied,
        classifySyncErrno(.ACCES),
    );
    try std.testing.expectError(
        error.PermissionDenied,
        classifySyncErrno(.PERM),
    );
    try std.testing.expectError(
        error.InputOutput,
        classifySyncErrno(.IO),
    );
    try std.testing.expectError(
        error.NoSpaceLeft,
        classifySyncErrno(.NOSPC),
    );
    try std.testing.expectError(
        error.DiskQuota,
        classifySyncErrno(.DQUOT),
    );
}

test "bad raw sync descriptors return a typed error" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;

    try std.testing.expectError(
        error.InvalidDirectoryHandle,
        syncDescriptor(-1),
    );
}
