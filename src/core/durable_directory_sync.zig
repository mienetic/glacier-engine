//! Acquired descriptor-relative directory authority for durable file adapters.
//!
//! A default `std.fs.Dir` may be backed by a path-only descriptor on systems
//! that provide one. Path-only descriptors preserve relative namespace
//! authority but cannot themselves be synchronized. This adapter reopens the
//! same pinned directory once with sync-capable, subpath-capable access,
//! preflights synchronization before namespace mutation, and owns that exact
//! descriptor until close.

const std = @import("std");
const platform_capabilities = @import("platform_capabilities.zig");

pub const AuthorityStateV1 = enum(u8) {
    live,
    poisoned,
    closed,
};

pub const BorrowError = error{
    InvalidAuthorityState,
};

pub const SyncError = error{
    UnsupportedPlatform,
    InvalidAuthorityState,
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

pub const AcquireError = std.fs.Dir.OpenError || SyncError;

pub const AuthorityObservationV1 = struct {
    state: AuthorityStateV1,
    preflight_sync_completed: bool,
    commit_attempt_count: u64,
    commit_success_count: u64,
};

const SyncFn = *const fn (std.posix.fd_t) SyncError!void;

/// Owns one sync-capable descriptor for a caller-pinned directory.
///
/// `borrow` returns a non-owning `std.fs.Dir` alias. Callers may use that alias
/// for descriptor-relative namespace operations but must never close it or
/// retain it beyond this authority's lifetime. `AuthorityV1` is likewise an
/// owning handle and must not be bitwise-copied.
pub const AuthorityV1 = struct {
    directory: std.fs.Dir,
    state: AuthorityStateV1,
    preflight_sync_completed: bool,
    commit_attempt_count: u64,
    commit_success_count: u64,

    /// Reopens `"."` relative to `anchor`, then performs a real directory
    /// synchronization before returning namespace-mutation authority.
    ///
    /// The original caller path is never resolved again. The caller must
    /// supply a live `std.fs.Dir` that it still owns.
    pub fn acquire(anchor: std.fs.Dir) AcquireError!AuthorityV1 {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1
            .posix_durable_file_adapter)
            return error.UnsupportedPlatform;
        return acquireWithSyncFn(anchor, syncDescriptor);
    }

    pub fn borrow(self: *const AuthorityV1) BorrowError!std.fs.Dir {
        if (self.state != .live) return error.InvalidAuthorityState;
        return self.directory;
    }

    /// Synchronizes namespace changes made through the borrowed directory.
    ///
    /// A failed synchronization leaves the authority poisoned because the
    /// durability boundary is uncertain. Checked borrow and commit operations
    /// reject afterward; observation and idempotent close remain available.
    pub fn commit(self: *AuthorityV1) SyncError!void {
        if (comptime !platform_capabilities
            .current_adapter_availability_v1
            .posix_durable_file_adapter)
            return error.UnsupportedPlatform;
        return self.commitWithSyncFn(syncDescriptor);
    }

    fn commitWithSyncFn(
        self: *AuthorityV1,
        sync_fn: SyncFn,
    ) SyncError!void {
        if (self.state != .live) return error.InvalidAuthorityState;
        self.state = .poisoned;
        self.commit_attempt_count +|= 1;
        try sync_fn(self.directory.fd);
        self.commit_success_count +|= 1;
        self.state = .live;
    }

    pub fn close(self: *AuthorityV1) void {
        if (self.state == .closed) return;
        self.state = .closed;
        self.directory.close();
    }

    pub fn observation(
        self: *const AuthorityV1,
    ) AuthorityObservationV1 {
        return .{
            .state = self.state,
            .preflight_sync_completed = self.preflight_sync_completed,
            .commit_attempt_count = self.commit_attempt_count,
            .commit_success_count = self.commit_success_count,
        };
    }
};

fn acquireWithSyncFn(
    anchor: std.fs.Dir,
    sync_fn: SyncFn,
) AcquireError!AuthorityV1 {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.UnsupportedPlatform;

    const syncable = try anchor.openDir(".", .{
        .access_sub_paths = true,
        .iterate = true,
        .no_follow = true,
    });
    var authority: AuthorityV1 = .{
        .directory = syncable,
        .state = .poisoned,
        .preflight_sync_completed = false,
        .commit_attempt_count = 0,
        .commit_success_count = 0,
    };
    errdefer authority.close();
    try sync_fn(syncable.fd);
    authority.preflight_sync_completed = true;
    authority.state = .live;
    return authority;
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

test "authority preflights commits and rejects use after close" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var authority = try AuthorityV1.acquire(temporary.dir);
    defer authority.close();
    const acquired = authority.observation();
    try std.testing.expectEqual(
        AuthorityStateV1.live,
        acquired.state,
    );
    try std.testing.expect(acquired.preflight_sync_completed);
    try std.testing.expectEqual(@as(u64, 0), acquired.commit_attempt_count);
    try std.testing.expectEqual(@as(u64, 0), acquired.commit_success_count);

    const directory = try authority.borrow();
    const file = try directory.createFile("committed", .{
        .read = true,
        .exclusive = true,
        .mode = 0o600,
    });
    try file.writeAll("authority");
    try file.sync();
    file.close();
    try authority.commit();
    const committed = authority.observation();
    try std.testing.expectEqual(
        AuthorityStateV1.live,
        committed.state,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        committed.commit_attempt_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        committed.commit_success_count,
    );

    authority.close();
    authority.close();
    try std.testing.expectEqual(
        AuthorityStateV1.closed,
        authority.observation().state,
    );
    try std.testing.expectError(
        error.InvalidAuthorityState,
        authority.borrow(),
    );
    try std.testing.expectError(
        error.InvalidAuthorityState,
        authority.commit(),
    );
}

test "authority remains pinned across rename and path replacement" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("original");
    var anchor = try temporary.dir.openDir("original", .{});
    var authority = try AuthorityV1.acquire(anchor);
    defer authority.close();
    anchor.close();

    try temporary.dir.rename("original", "renamed");
    try temporary.dir.makeDir("original");
    const pinned = try authority.borrow();
    const file = try pinned.createFile("pinned", .{
        .read = true,
        .exclusive = true,
        .mode = 0o600,
    });
    try file.writeAll("same-directory");
    try file.sync();
    file.close();
    try authority.commit();

    var renamed = try temporary.dir.openDir("renamed", .{});
    defer renamed.close();
    const visible = try renamed.openFile("pinned", .{});
    visible.close();
    var replacement = try temporary.dir.openDir("original", .{});
    defer replacement.close();
    try std.testing.expectError(
        error.FileNotFound,
        replacement.openFile("pinned", .{}),
    );
}

fn failSyncForTest(_: std.posix.fd_t) SyncError!void {
    return error.InputOutput;
}

test "preflight failure closes acquisition and commit failure poisons" {
    if (comptime !platform_capabilities
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try std.testing.expectError(
        error.InputOutput,
        acquireWithSyncFn(temporary.dir, failSyncForTest),
    );

    var authority = try AuthorityV1.acquire(temporary.dir);
    defer authority.close();
    try std.testing.expectError(
        error.InputOutput,
        authority.commitWithSyncFn(failSyncForTest),
    );
    const failed = authority.observation();
    try std.testing.expectEqual(
        AuthorityStateV1.poisoned,
        failed.state,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        failed.commit_attempt_count,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        failed.commit_success_count,
    );
    try std.testing.expectError(
        error.InvalidAuthorityState,
        authority.borrow(),
    );
    try std.testing.expectError(
        error.InvalidAuthorityState,
        authority.commit(),
    );
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
