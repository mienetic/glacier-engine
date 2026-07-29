//! Recoverable durable publication for derived GLRT runtime images.
//!
//! The GLRT codec remains independent from durability. This adapter acquires a
//! sync-capable descriptor for the caller-pinned parent directory before any
//! namespace mutation, serializes into one private directory-scoped candidate,
//! syncs and validates that exact inode, atomically replaces the target, and
//! commits the directory. A stale candidate is bounded crash debris: recovery
//! removes it under the directory lock, commits the cleanup, and deterministically
//! rebuilds from the authoritative source inputs.
//!
//! Process death before rename leaves the previous target authoritative.
//! Process death after rename may leave the complete successor visible; the
//! next attempt rebuilds and compares the exact container identity before
//! committing the directory again. This is host-filesystem/process-recovery
//! behavior, not evidence of physical power-loss persistence.

const std = @import("std");
const core = @import("core");
const runtime_image = @import("runtime_image.zig");

const durable_directory = core.durable_directory_authority;
const platform_capabilities = core.platform_capabilities;

pub const publication_abi: u64 = 0x474c_5250_0000_0001;
pub const Digest = [32]u8;

const plan_domain = "glacier-runtime-image-publication-plan-v1\x00";
const reserved_prefix = ".glacier-glrt-";
const directory_lock_name = ".glacier-glrt-publication.lock-v1";
const directory_candidate_name =
    ".glacier-glrt-publication.candidate-v1";

pub const PublisherStateV1 = enum(u8) {
    live,
    poisoned,
    closed,
};

pub const PublicationPhaseV1 = enum(u8) {
    stale_candidate_removed,
    candidate_created,
    candidate_encoded,
    candidate_synced,
    candidate_validated,
    target_replaced,
    directory_committed,
};

pub const ObserverV1 = struct {
    context: *anyopaque,
    after_phase_fn: *const fn (
        context: *anyopaque,
        phase: PublicationPhaseV1,
    ) anyerror!void,

    fn after(
        self: ObserverV1,
        phase: PublicationPhaseV1,
    ) !void {
        try self.after_phase_fn(self.context, phase);
    }
};

pub const PublicationDispositionV1 = enum(u8) {
    published,
    already_current,
};

pub const PublicationReceiptV1 = struct {
    abi_version: u64 = publication_abi,
    disposition: PublicationDispositionV1,
    publication_plan_sha256: Digest,
    image_identity: runtime_image.ImageIdentityV1,
    stats: runtime_image.WriteStats,
    stale_candidate_removed: bool,
    directory_observation: durable_directory.AuthorityObservationV1,
};

pub const PublisherObservationV1 = struct {
    state: PublisherStateV1,
    directory: durable_directory.AuthorityObservationV1,
};

pub const PublisherV1 = struct {
    directory_authority: durable_directory.AuthorityV1,
    state: PublisherStateV1 = .live,

    /// Acquire and preflight a sync-capable descriptor for the exact directory
    /// currently named by `anchor`. The caller retains ownership of `anchor`
    /// and may close it immediately after this function returns.
    pub fn init(anchor: std.fs.Dir) !PublisherV1 {
        if (comptime !durableAdapterAvailableV1())
            return error.UnsupportedPlatform;
        return .{
            .directory_authority = try durable_directory.AuthorityV1.acquire(anchor),
        };
    }

    pub fn close(self: *PublisherV1) void {
        if (self.state == .closed) return;
        self.state = .closed;
        self.directory_authority.close();
    }

    pub fn observation(
        self: *const PublisherV1,
    ) PublisherObservationV1 {
        return .{
            .state = self.state,
            .directory = self.directory_authority.observation(),
        };
    }

    /// Publish one GLRT image beneath the acquired directory.
    ///
    /// The lock and candidate are directory-scoped so filesystem aliases
    /// cannot bypass serialization. Every cooperating runtime-image writer in
    /// this directory must use this adapter. If `provider` is supplied, its
    /// bytes must be deterministic and fully bound by `source_fingerprint`;
    /// recovery rebuilds from that provider rather than trusting crash debris.
    pub fn writeWithProvider(
        self: *PublisherV1,
        allocator: std.mem.Allocator,
        target_name: []const u8,
        options: runtime_image.WriteOptions,
        input_records: []const runtime_image.WriteRecord,
        provider: ?runtime_image.WriteRecordProvider,
        observer: ?ObserverV1,
    ) !PublicationReceiptV1 {
        if (comptime !durableAdapterAvailableV1())
            return error.UnsupportedPlatform;
        if (self.state != .live)
            return error.InvalidPublisherState;
        if (!options.sync)
            return error.DurabilityDisabled;
        try validateTargetNameV1(target_name);
        try runtime_image.validateWriteInputsV1(
            options,
            input_records,
        );

        const directory = self.directory_authority.borrow() catch
            return error.InvalidPublisherState;
        const lock_name = directory_lock_name;
        const candidate_name = directory_candidate_name;
        const publication_plan_sha256 = publicationPlanSha256V1(
            target_name,
            options,
            input_records,
        );

        var lock = try acquireTargetLockV1(
            directory,
            lock_name,
        );
        defer lock.file.close();
        if (lock.created) {
            self.state = .poisoned;
            try lock.file.sync();
            try self.directory_authority.commit();
            self.state = .live;
        }
        try verifyTargetLockV1(
            directory,
            lock_name,
            lock,
        );

        var namespace_mutated = false;
        errdefer if (namespace_mutated) {
            self.state = .poisoned;
        };

        var stale_candidate_removed = false;
        if (try removeStaleCandidateV1(
            directory,
            candidate_name,
        )) {
            namespace_mutated = true;
            self.state = .poisoned;
            try self.directory_authority.commit();
            self.state = .live;
            stale_candidate_removed = true;
            if (observer) |value|
                try value.after(.stale_candidate_removed);
        }
        const target_before = try existingTargetSnapshotV1(
            directory,
            target_name,
        );

        var write_stats: runtime_image.WriteStats = .{};
        const initial_candidate_view: FileViewV1 = candidate: {
            const file = try openSafeFileV1(
                directory,
                candidate_name,
                .create,
                .read_write,
            );
            defer file.close();
            namespace_mutated = true;
            const initial_view = try inspectFileV1(
                file,
                directory,
                candidate_name,
                .private,
            );
            if (observer) |value|
                try value.after(.candidate_created);
            write_stats =
                try runtime_image.writeUnpublishedFileWithProviderV1(
                    allocator,
                    file,
                    options,
                    input_records,
                    provider,
                );
            if (observer) |value|
                try value.after(.candidate_encoded);
            try file.sync();
            if (observer) |value|
                try value.after(.candidate_synced);
            const synced_view = try inspectFileV1(
                file,
                directory,
                candidate_name,
                .private,
            );
            if (!sameObjectV1(initial_view, synced_view))
                return error.StorageIdentityChanged;
            break :candidate initial_view;
        };

        const candidate_file = try openSafeFileV1(
            directory,
            candidate_name,
            .existing,
            .read_only,
        );
        const reopened_view = inspectFileV1(
            candidate_file,
            directory,
            candidate_name,
            .private,
        ) catch |err| {
            candidate_file.close();
            return err;
        };
        if (!sameObjectV1(initial_candidate_view, reopened_view)) {
            candidate_file.close();
            return error.StorageIdentityChanged;
        }
        var candidate_image =
            try runtime_image.MappedImage.openOwnedFileWithOptionsV1(
                candidate_file,
                .{
                    .allow_v1 = false,
                    .expected_source_fingerprint = options.source_fingerprint,
                    .expected_abi_fingerprint = options.abi_fingerprint,
                    .expected_v1_abi_fingerprint = null,
                },
            );
        defer candidate_image.close();
        try validatePlannedImageV1(
            &candidate_image,
            options,
            input_records,
        );
        const candidate_view = try inspectFileV1(
            candidate_image.file,
            directory,
            candidate_name,
            .private,
        );
        if (!sameObjectV1(initial_candidate_view, candidate_view))
            return error.StorageIdentityChanged;
        const identity = candidate_image.identityV1();
        if (identity.container_bytes != candidate_view.size)
            return error.StorageIdentityChanged;
        if (observer) |value|
            try value.after(.candidate_validated);

        try verifyTargetLockV1(
            directory,
            lock_name,
            lock,
        );
        const target_after = try existingTargetSnapshotV1(
            directory,
            target_name,
        );
        if (!optionalTargetSnapshotEqlV1(
            target_before,
            target_after,
        ))
            return error.StorageIdentityChanged;
        if (target_after) |current| {
            if (imageIdentityEqlV1(current.identity, identity)) {
                try directory.deleteFile(candidate_name);
                self.state = .poisoned;
                try self.directory_authority.commit();
                self.state = .live;
                try verifyTargetLockV1(
                    directory,
                    lock_name,
                    lock,
                );
                if (observer) |value|
                    try value.after(.directory_committed);
                return .{
                    .disposition = .already_current,
                    .publication_plan_sha256 = publication_plan_sha256,
                    .image_identity = identity,
                    .stats = write_stats,
                    .stale_candidate_removed = stale_candidate_removed,
                    .directory_observation = self.directory_authority.observation(),
                };
            }
        }

        try directory.rename(candidate_name, target_name);
        self.state = .poisoned;
        if (observer) |value|
            try value.after(.target_replaced);
        const renamed_view = try inspectFileV1(
            candidate_image.file,
            directory,
            target_name,
            .private,
        );
        if (!sameObjectV1(initial_candidate_view, renamed_view) or
            renamed_view.size != identity.container_bytes)
            return error.StorageIdentityChanged;

        try self.directory_authority.commit();
        self.state = .live;
        try verifyTargetLockV1(
            directory,
            lock_name,
            lock,
        );
        if (observer) |value|
            try value.after(.directory_committed);
        const committed_view = try inspectFileV1(
            candidate_image.file,
            directory,
            target_name,
            .private,
        );
        if (!std.meta.eql(renamed_view, committed_view) or
            !imageIdentityEqlV1(
                candidate_image.identityV1(),
                identity,
            ))
            return error.StorageIdentityChanged;

        return .{
            .disposition = .published,
            .publication_plan_sha256 = publication_plan_sha256,
            .image_identity = identity,
            .stats = write_stats,
            .stale_candidate_removed = stale_candidate_removed,
            .directory_observation = self.directory_authority.observation(),
        };
    }
};

/// Durable path wrapper for callers that already have eager record payloads.
pub fn writeDurableV1(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: runtime_image.WriteOptions,
    input_records: []const runtime_image.WriteRecord,
) !PublicationReceiptV1 {
    return writeDurableWithProviderV1(
        allocator,
        path,
        options,
        input_records,
        null,
        null,
    );
}

/// Resolve the parent once, acquire it, then publish one basename beneath the
/// pinned descriptor. Relative path resolution follows normal host semantics;
/// callers that need a pre-pinned trust boundary should use `PublisherV1`.
/// Provider bytes must satisfy the deterministic source-binding precondition
/// documented by `PublisherV1.writeWithProvider`.
pub fn writeDurableWithProviderV1(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: runtime_image.WriteOptions,
    input_records: []const runtime_image.WriteRecord,
    provider: ?runtime_image.WriteRecordProvider,
    observer: ?ObserverV1,
) !PublicationReceiptV1 {
    if (comptime !durableAdapterAvailableV1())
        return error.UnsupportedPlatform;
    if (path.len == 0 or
        std.fs.path.isSep(path[path.len - 1]))
        return error.InvalidTargetName;
    const target_name = std.fs.path.basename(path);
    try validateTargetNameV1(target_name);

    if (std.fs.path.dirname(path)) |parent_path| {
        var parent = if (std.fs.path.isAbsolute(parent_path))
            try std.fs.openDirAbsolute(parent_path, .{
                .access_sub_paths = true,
                .iterate = false,
                .no_follow = true,
            })
        else
            try std.fs.cwd().openDir(parent_path, .{
                .access_sub_paths = true,
                .iterate = false,
                .no_follow = true,
            });
        defer parent.close();
        var publisher = try PublisherV1.init(parent);
        defer publisher.close();
        return publisher.writeWithProvider(
            allocator,
            target_name,
            options,
            input_records,
            provider,
            observer,
        );
    }

    var publisher = try PublisherV1.init(std.fs.cwd());
    defer publisher.close();
    return publisher.writeWithProvider(
        allocator,
        target_name,
        options,
        input_records,
        provider,
        observer,
    );
}

fn durableAdapterAvailableV1() bool {
    return platform_capabilities.current_adapter_availability_v1
        .posix_durable_file_adapter;
}

const OpenKindV1 = enum {
    create,
    existing,
};

const AccessV1 = enum {
    read_only,
    read_write,
};

const PermissionPolicyV1 = enum {
    private,
    public_read_only,
};

const FileViewV1 = struct {
    device: u64,
    inode: u64,
    size: u64,
};

const TargetLockV1 = struct {
    file: std.fs.File,
    created: bool,
    view: FileViewV1,
};

const TargetSnapshotV1 = struct {
    view: FileViewV1,
    identity: runtime_image.ImageIdentityV1,
};

fn acquireTargetLockV1(
    directory: std.fs.Dir,
    name: []const u8,
) !TargetLockV1 {
    var created = true;
    const file = openSafeFileV1(
        directory,
        name,
        .create,
        .read_write,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => existing: {
            created = false;
            break :existing try openSafeFileV1(
                directory,
                name,
                .existing,
                .read_write,
            );
        },
        else => return err,
    };
    errdefer file.close();
    const view = try inspectFileV1(
        file,
        directory,
        name,
        .private,
    );
    std.posix.flock(
        file.handle,
        std.posix.LOCK.EX | std.posix.LOCK.NB,
    ) catch |err| switch (err) {
        error.WouldBlock => return error.PublicationBusy,
        else => return err,
    };
    return .{
        .file = file,
        .created = created,
        .view = view,
    };
}

fn verifyTargetLockV1(
    directory: std.fs.Dir,
    name: []const u8,
    lock: TargetLockV1,
) !void {
    const current = try inspectFileV1(
        lock.file,
        directory,
        name,
        .private,
    );
    if (!std.meta.eql(current, lock.view))
        return error.StorageIdentityChanged;
}

fn removeStaleCandidateV1(
    directory: std.fs.Dir,
    name: []const u8,
) !bool {
    const file = openSafeFileV1(
        directory,
        name,
        .existing,
        .read_write,
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    _ = try inspectFileV1(
        file,
        directory,
        name,
        .private,
    );
    try directory.deleteFile(name);
    return true;
}

fn existingTargetSnapshotV1(
    directory: std.fs.Dir,
    name: []const u8,
) !?TargetSnapshotV1 {
    const file = openSafeFileV1(
        directory,
        name,
        .existing,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const initial_view = inspectFileV1(
        file,
        directory,
        name,
        .public_read_only,
    ) catch |err| {
        file.close();
        return err;
    };
    var image = runtime_image.MappedImage.openOwnedFileWithOptionsV1(
        file,
        .{
            .expected_source_fingerprint = null,
            .expected_abi_fingerprint = null,
            .expected_v1_abi_fingerprint = null,
        },
    ) catch return error.InvalidExistingTarget;
    defer image.close();
    const final_view = try inspectFileV1(
        image.file,
        directory,
        name,
        .public_read_only,
    );
    if (!std.meta.eql(initial_view, final_view))
        return error.StorageIdentityChanged;
    return .{
        .view = final_view,
        .identity = image.identityV1(),
    };
}

fn optionalTargetSnapshotEqlV1(
    left: ?TargetSnapshotV1,
    right: ?TargetSnapshotV1,
) bool {
    if (left == null or right == null)
        return left == null and right == null;
    return std.meta.eql(left.?.view, right.?.view) and
        imageIdentityEqlV1(
            left.?.identity,
            right.?.identity,
        );
}

fn openSafeFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    kind: OpenKindV1,
    access: AccessV1,
) !std.fs.File {
    if (comptime !durableAdapterAvailableV1())
        return error.UnsupportedPlatform;
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW") or
        !@hasField(std.posix.O, "NONBLOCK"))
        return error.UnsupportedPlatform;
    var flags: std.posix.O = .{
        .ACCMODE = if (access == .read_only) .RDONLY else .RDWR,
    };
    flags.CLOEXEC = true;
    flags.NOFOLLOW = true;
    // An existing FIFO must not block publication before its type is checked.
    // O_NONBLOCK has no behavioral effect on the regular files admitted below.
    flags.NONBLOCK = true;
    if (@hasField(std.posix.O, "NOCTTY"))
        flags.NOCTTY = true;
    if (kind == .create) {
        flags.CREAT = true;
        flags.EXCL = true;
    }
    const fd = try std.posix.openat(
        directory.fd,
        name,
        flags,
        if (kind == .create) 0o600 else 0,
    );
    return .{ .handle = fd };
}

fn inspectFileV1(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    permission_policy: PermissionPolicyV1,
) !FileViewV1 {
    const file_stat = try std.posix.fstat(file.handle);
    const entry_stat = try std.posix.fstatat(
        directory.fd,
        name,
        std.posix.AT.SYMLINK_NOFOLLOW,
    );
    const file_view = try inspectStatV1(
        file_stat,
        permission_policy,
    );
    const entry_view = try inspectStatV1(
        entry_stat,
        permission_policy,
    );
    if (!std.meta.eql(file_view, entry_view))
        return error.StorageIdentityChanged;
    return file_view;
}

fn inspectStatV1(
    stat: std.posix.Stat,
    permission_policy: PermissionPolicyV1,
) !FileViewV1 {
    if ((stat.mode & std.posix.S.IFMT) != std.posix.S.IFREG)
        return error.UnsafeStorage;
    if (stat.nlink != 1)
        return error.MultipleLinks;
    switch (permission_policy) {
        .private => if ((stat.mode & 0o077) != 0)
            return error.UnsafePermissions,
        .public_read_only => if ((stat.mode & 0o022) != 0)
            return error.UnsafePermissions,
    }
    return .{
        .device = std.math.cast(u64, stat.dev) orelse
            return error.UnsafeStorage,
        .inode = std.math.cast(u64, stat.ino) orelse
            return error.UnsafeStorage,
        .size = std.math.cast(u64, stat.size) orelse
            return error.UnsafeStorage,
    };
}

fn sameObjectV1(
    left: FileViewV1,
    right: FileViewV1,
) bool {
    return left.device == right.device and
        left.inode == right.inode;
}

fn validateTargetNameV1(name: []const u8) !void {
    if (name.len == 0 or name.len > std.fs.max_name_bytes or
        std.mem.eql(u8, name, ".") or
        std.mem.eql(u8, name, ".."))
        return error.InvalidTargetName;
    for (name) |byte| {
        if (byte == 0 or byte == '/' or byte == '\\')
            return error.InvalidTargetName;
    }
    if (std.ascii.startsWithIgnoreCase(name, reserved_prefix))
        return error.InvalidTargetName;
}

/// Commit the target, configuration, and planned record descriptors.
///
/// This is a plan identity, not a content digest. Exact materialized bytes are
/// bound only by the validated `ImageIdentityV1` returned in the receipt.
pub fn publicationPlanSha256V1(
    target_name: []const u8,
    options: runtime_image.WriteOptions,
    input_records: []const runtime_image.WriteRecord,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, publication_abi);
    hashU64(&hash, target_name.len);
    hash.update(target_name);
    hashU64(&hash, runtime_image.VERSION);
    hash.update(&options.source_fingerprint);
    hash.update(&options.abi_fingerprint);
    hashConfigV1(&hash, options.config);
    hashU64(&hash, input_records.len);
    for (input_records) |record|
        hashWriteRecordPlanV1(&hash, record);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn hashConfigV1(
    hash: *std.crypto.hash.sha2.Sha256,
    config: runtime_image.ConfigSnapshot,
) void {
    hashU32(hash, config.dim);
    hashU32(hash, config.hidden_dim);
    hashU32(hash, config.layers);
    hashU32(hash, config.vocab);
    hashU32(hash, config.heads);
    hashU32(hash, config.head_dim);
    hashU32(hash, config.kv_heads);
    hashU32(hash, @bitCast(config.rms_eps));
    hashU32(hash, @bitCast(config.rope_theta));
    hashU8(hash, @intFromBool(config.tie_embeddings));
}

fn hashWriteRecordPlanV1(
    hash: *std.crypto.hash.sha2.Sha256,
    record: runtime_image.WriteRecord,
) void {
    hashU32(hash, record.key.layer_idx);
    hashU32(hash, @intFromEnum(record.key.kind));
    hashU16(hash, @intFromEnum(record.role));
    hashU16(hash, @intFromEnum(record.encoding));
    hashU16(hash, @intFromEnum(record.packed_layout));
    hashU16(hash, @intFromEnum(record.pair_nibble_layout));
    hashU32(hash, record.group_size);
    hashU32(hash, record.out_f);
    hashU32(hash, record.in_f);
    hashU64(hash, record.num_elements);
    hashU32(hash, record.flags);
    inline for (.{
        runtime_image.Stream.packed_weights,
        runtime_image.Stream.scales_f32,
        runtime_image.Stream.scales_f16,
        runtime_image.Stream.scales_f16_rows4,
        runtime_image.Stream.raw,
    }) |stream|
        hashU64(hash, record.bytes(stream).len);
}

fn validatePlannedImageV1(
    image: *const runtime_image.MappedImage,
    options: runtime_image.WriteOptions,
    input_records: []const runtime_image.WriteRecord,
) !void {
    if (image.header.version != .v2 or
        !std.meta.eql(image.header.config, options.config) or
        image.recordCount() != input_records.len)
        return error.PublicationPlanMismatch;
    for (input_records, 0..) |planned, index| {
        const actual = try image.recordAt(index);
        if (actual.key.layer_idx != planned.key.layer_idx or
            actual.key.kind != planned.key.kind or
            actual.role != planned.role or
            actual.encoding != planned.encoding or
            actual.packed_layout != planned.packed_layout or
            actual.pair_nibble_layout !=
                planned.pair_nibble_layout or
            actual.group_size != planned.group_size or
            actual.out_f != planned.out_f or
            actual.in_f != planned.in_f or
            actual.num_elements != planned.num_elements or
            actual.flags != planned.flags)
            return error.PublicationPlanMismatch;
        inline for (.{
            runtime_image.Stream.packed_weights,
            runtime_image.Stream.scales_f32,
            runtime_image.Stream.scales_f16,
            runtime_image.Stream.scales_f16_rows4,
            runtime_image.Stream.raw,
        }) |stream| {
            if (actual.range(stream).len !=
                planned.bytes(stream).len)
                return error.PublicationPlanMismatch;
        }
    }
}

fn imageIdentityEqlV1(
    left: runtime_image.ImageIdentityV1,
    right: runtime_image.ImageIdentityV1,
) bool {
    return left.container_bytes == right.container_bytes and
        std.mem.eql(
            u8,
            &left.source_fingerprint,
            &right.source_fingerprint,
        ) and
        std.mem.eql(
            u8,
            &left.abi_fingerprint,
            &right.abi_fingerprint,
        ) and
        std.mem.eql(
            u8,
            &left.container_sha256,
            &right.container_sha256,
        );
}

fn hashU8(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&.{value});
}

fn hashU16(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u16,
) void {
    var encoded: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU32(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u32,
) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

// --------------------------------------------------------------------------
// Focused durable-publication tests
// --------------------------------------------------------------------------

const testing = std.testing;

const test_old_first = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
const test_old_second = [_]f32{ 5.0, 6.0, 7.0, 8.0 };
const test_new_first = [_]f32{ 9.0, 10.0, 11.0, 12.0 };
const test_new_second = [_]f32{ 13.0, 14.0, 15.0, 16.0 };

fn testConfigV1() runtime_image.ConfigSnapshot {
    return .{
        .dim = 16,
        .hidden_dim = 32,
        .layers = 2,
        .vocab = 64,
        .heads = 2,
        .head_dim = 8,
        .kv_heads = 1,
        .rms_eps = 1e-6,
        .rope_theta = 10_000,
        .tie_embeddings = true,
    };
}

fn testOptionsV1(source: []const u8) runtime_image.WriteOptions {
    return .{
        .config = testConfigV1(),
        .source_fingerprint = runtime_image.fingerprint(source),
    };
}

fn testRecordsV1(new: bool) [2]runtime_image.WriteRecord {
    const first = if (new) &test_new_first else &test_old_first;
    const second = if (new) &test_new_second else &test_old_second;
    return .{
        .{
            .key = .{
                .layer_idx = 0,
                .kind = .final_norm,
            },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = first.len,
            .num_elements = first.len,
            .raw = std.mem.sliceAsBytes(first),
        },
        .{
            .key = .{
                .layer_idx = 0,
                .kind = .input_norm,
            },
            .encoding = .raw_f32,
            .packed_layout = .none,
            .group_size = 0,
            .out_f = 1,
            .in_f = second.len,
            .num_elements = second.len,
            .raw = std.mem.sliceAsBytes(second),
        },
    };
}

fn readIdentityV1(
    directory: std.fs.Dir,
    name: []const u8,
) !runtime_image.ImageIdentityV1 {
    var image = try runtime_image.MappedImage.openWithOptionsAt(
        directory,
        name,
        .{
            .expected_source_fingerprint = null,
            .expected_abi_fingerprint = null,
            .expected_v1_abi_fingerprint = null,
        },
    );
    defer image.close();
    return image.identityV1();
}

fn expectCandidateMissingV1(
    directory: std.fs.Dir,
    _: []const u8,
) !void {
    try testing.expectError(
        error.FileNotFound,
        directory.openFile(directory_candidate_name, .{}),
    );
}

test "durable runtime image pins its directory and is idempotent" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.makeDir("original");
    var anchor = try temporary.dir.openDir("original", .{
        .iterate = false,
        .no_follow = true,
    });
    var publisher = try PublisherV1.init(anchor);
    anchor.close();
    defer publisher.close();

    try temporary.dir.rename("original", "pinned");
    try temporary.dir.makeDir("original");
    const records = testRecordsV1(false);
    const first = try publisher.writeWithProvider(
        testing.allocator,
        "model.glrt",
        testOptionsV1("durable-pinned"),
        &records,
        null,
        null,
    );
    try testing.expectEqual(
        PublicationDispositionV1.published,
        first.disposition,
    );
    try testing.expectEqual(
        PublisherStateV1.live,
        publisher.observation().state,
    );
    try testing.expect(
        first.directory_observation.preflight_sync_completed,
    );
    try testing.expectEqual(
        @as(u64, 2),
        first.directory_observation.commit_success_count,
    );

    var pinned = try temporary.dir.openDir("pinned", .{});
    defer pinned.close();
    const visible = try readIdentityV1(pinned, "model.glrt");
    try testing.expect(imageIdentityEqlV1(
        visible,
        first.image_identity,
    ));
    var replacement = try temporary.dir.openDir("original", .{});
    defer replacement.close();
    try testing.expectError(
        error.FileNotFound,
        replacement.openFile("model.glrt", .{}),
    );

    const second = try publisher.writeWithProvider(
        testing.allocator,
        "model.glrt",
        testOptionsV1("durable-pinned"),
        &records,
        null,
        null,
    );
    try testing.expectEqual(
        PublicationDispositionV1.already_current,
        second.disposition,
    );
    try testing.expect(imageIdentityEqlV1(
        first.image_identity,
        second.image_identity,
    ));
    try testing.expectEqual(
        @as(u64, 3),
        second.directory_observation.commit_success_count,
    );
    try expectCandidateMissingV1(pinned, "model.glrt");
}

test "durable runtime image uses one directory-scoped publication lock" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var first = try PublisherV1.init(temporary.dir);
    defer first.close();
    var second = try PublisherV1.init(temporary.dir);
    defer second.close();
    const first_directory = try first.directory_authority.borrow();
    var held = try acquireTargetLockV1(
        first_directory,
        directory_lock_name,
    );
    defer held.file.close();
    try testing.expectError(
        error.PublicationBusy,
        acquireTargetLockV1(
            try second.directory_authority.borrow(),
            directory_lock_name,
        ),
    );
}

test "durable runtime image path wrapper rejects directory-form paths before mutation" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const absolute = try temporary.dir.realpathAlloc(
        testing.allocator,
        ".",
    );
    defer testing.allocator.free(absolute);
    const invalid_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/would-be-target/",
        .{absolute},
    );
    defer testing.allocator.free(invalid_path);
    const records = testRecordsV1(false);
    try testing.expectError(
        error.InvalidTargetName,
        writeDurableV1(
            testing.allocator,
            invalid_path,
            testOptionsV1("directory-form-path"),
            &records,
        ),
    );
    var scan = try temporary.dir.openDir(".", .{
        .iterate = true,
        .no_follow = true,
    });
    defer scan.close();
    var iterator = scan.iterate();
    try testing.expect((try iterator.next()) == null);
}

test "durable runtime image rejects nondurable and unsafe names before mutation" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var publisher = try PublisherV1.init(temporary.dir);
    defer publisher.close();
    const records = testRecordsV1(false);
    var nondurable = testOptionsV1("nondurable");
    nondurable.sync = false;
    try testing.expectError(
        error.DurabilityDisabled,
        publisher.writeWithProvider(
            testing.allocator,
            "model.glrt",
            nondurable,
            &records,
            null,
            null,
        ),
    );
    for ([_][]const u8{
        "",
        ".",
        "..",
        "nested/model.glrt",
        "nested\\model.glrt",
        ".glacier-glrt-reserved",
        ".GLACIER-GLRT-reserved",
    }) |name| {
        try testing.expectError(
            error.InvalidTargetName,
            publisher.writeWithProvider(
                testing.allocator,
                name,
                testOptionsV1("invalid-name"),
                &records,
                null,
                null,
            ),
        );
    }
    try testing.expectError(
        error.NoRecords,
        publisher.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("invalid-empty-plan"),
            &.{},
            null,
            null,
        ),
    );
    var scan = try temporary.dir.openDir(".", .{
        .iterate = true,
        .no_follow = true,
    });
    defer scan.close();
    var iterator = scan.iterate();
    try testing.expect((try iterator.next()) == null);
}

const FailSecondProviderV1 = struct {
    fn materialize(
        _: *anyopaque,
        index: usize,
        planned: runtime_image.WriteRecord,
    ) anyerror!runtime_image.MaterializedWriteRecord {
        if (index == 1) return error.InjectedProviderFailure;
        return .{ .record = planned };
    }
};

test "durable runtime image provider interruption preserves predecessor and rebuilds debris" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const old_records = testRecordsV1(false);
    var initial = try PublisherV1.init(temporary.dir);
    const old_receipt = try initial.writeWithProvider(
        testing.allocator,
        "model.glrt",
        testOptionsV1("old-provider-state"),
        &old_records,
        null,
        null,
    );
    initial.close();

    const new_records = testRecordsV1(true);
    var context: u8 = 0;
    var interrupted = try PublisherV1.init(temporary.dir);
    try testing.expectError(
        error.InjectedProviderFailure,
        interrupted.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("new-provider-state"),
            &new_records,
            .{
                .context = &context,
                .materialize = FailSecondProviderV1.materialize,
            },
            null,
        ),
    );
    try testing.expectEqual(
        PublisherStateV1.poisoned,
        interrupted.observation().state,
    );
    const retained = try readIdentityV1(
        temporary.dir,
        "model.glrt",
    );
    try testing.expect(imageIdentityEqlV1(
        retained,
        old_receipt.image_identity,
    ));
    interrupted.close();

    var recovered = try PublisherV1.init(temporary.dir);
    defer recovered.close();
    const new_receipt = try recovered.writeWithProvider(
        testing.allocator,
        "model.glrt",
        testOptionsV1("new-provider-state"),
        &new_records,
        null,
        null,
    );
    try testing.expectEqual(
        PublicationDispositionV1.published,
        new_receipt.disposition,
    );
    try testing.expect(new_receipt.stale_candidate_removed);
    try testing.expect(
        !imageIdentityEqlV1(
            old_receipt.image_identity,
            new_receipt.image_identity,
        ),
    );
    try expectCandidateMissingV1(
        temporary.dir,
        "model.glrt",
    );
}

const FaultObserverV1 = struct {
    selected: PublicationPhaseV1,

    fn after(
        context: *anyopaque,
        phase: PublicationPhaseV1,
    ) anyerror!void {
        const self: *FaultObserverV1 =
            @ptrCast(@alignCast(context));
        if (phase == self.selected)
            return error.InjectedPostPhaseFault;
    }

    fn interface(self: *FaultObserverV1) ObserverV1 {
        return .{
            .context = self,
            .after_phase_fn = after,
        };
    }
};

test "durable runtime image post-phase interruptions converge from predecessor or successor" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    const phases = [_]PublicationPhaseV1{
        .candidate_created,
        .candidate_encoded,
        .candidate_synced,
        .candidate_validated,
        .target_replaced,
        .directory_committed,
    };
    for (phases) |phase| {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        const old_records = testRecordsV1(false);
        var initial = try PublisherV1.init(temporary.dir);
        const old_receipt = try initial.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("phase-old"),
            &old_records,
            null,
            null,
        );
        initial.close();

        const new_records = testRecordsV1(true);
        var observer: FaultObserverV1 = .{
            .selected = phase,
        };
        var interrupted = try PublisherV1.init(temporary.dir);
        try testing.expectError(
            error.InjectedPostPhaseFault,
            interrupted.writeWithProvider(
                testing.allocator,
                "model.glrt",
                testOptionsV1("phase-new"),
                &new_records,
                null,
                observer.interface(),
            ),
        );
        try testing.expectEqual(
            PublisherStateV1.poisoned,
            interrupted.observation().state,
        );
        interrupted.close();

        const after_fault = try readIdentityV1(
            temporary.dir,
            "model.glrt",
        );
        const successor_visible =
            phase == .target_replaced or
            phase == .directory_committed;
        if (successor_visible) {
            try testing.expect(
                !imageIdentityEqlV1(
                    after_fault,
                    old_receipt.image_identity,
                ),
            );
        } else {
            try testing.expect(imageIdentityEqlV1(
                after_fault,
                old_receipt.image_identity,
            ));
        }

        var recovered = try PublisherV1.init(temporary.dir);
        defer recovered.close();
        const new_receipt = try recovered.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("phase-new"),
            &new_records,
            null,
            null,
        );
        try testing.expectEqual(
            if (successor_visible)
                PublicationDispositionV1.already_current
            else
                PublicationDispositionV1.published,
            new_receipt.disposition,
        );
        const final_identity = try readIdentityV1(
            temporary.dir,
            "model.glrt",
        );
        try testing.expect(imageIdentityEqlV1(
            final_identity,
            new_receipt.image_identity,
        ));
        try expectCandidateMissingV1(
            temporary.dir,
            "model.glrt",
        );
    }
}

test "durable runtime image stale-candidate cleanup interruption leaves predecessor" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const old_records = testRecordsV1(false);
    var initial = try PublisherV1.init(temporary.dir);
    const old_receipt = try initial.writeWithProvider(
        testing.allocator,
        "model.glrt",
        testOptionsV1("cleanup-old"),
        &old_records,
        null,
        null,
    );
    initial.close();

    const new_records = testRecordsV1(true);
    var create_fault: FaultObserverV1 = .{
        .selected = .candidate_created,
    };
    var seeded = try PublisherV1.init(temporary.dir);
    try testing.expectError(
        error.InjectedPostPhaseFault,
        seeded.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("cleanup-new"),
            &new_records,
            null,
            create_fault.interface(),
        ),
    );
    seeded.close();

    var cleanup_fault: FaultObserverV1 = .{
        .selected = .stale_candidate_removed,
    };
    var interrupted = try PublisherV1.init(temporary.dir);
    try testing.expectError(
        error.InjectedPostPhaseFault,
        interrupted.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("cleanup-new"),
            &new_records,
            null,
            cleanup_fault.interface(),
        ),
    );
    interrupted.close();
    const retained = try readIdentityV1(
        temporary.dir,
        "model.glrt",
    );
    try testing.expect(imageIdentityEqlV1(
        retained,
        old_receipt.image_identity,
    ));
    try expectCandidateMissingV1(
        temporary.dir,
        "model.glrt",
    );

    var recovered = try PublisherV1.init(temporary.dir);
    defer recovered.close();
    const receipt = try recovered.writeWithProvider(
        testing.allocator,
        "model.glrt",
        testOptionsV1("cleanup-new"),
        &new_records,
        null,
        null,
    );
    try testing.expectEqual(
        PublicationDispositionV1.published,
        receipt.disposition,
    );
}

test "durable runtime image reserved candidate rejects link substitution" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    const substitutions = [_]enum {
        symlink,
        hard_link,
    }{ .symlink, .hard_link };
    for (substitutions) |substitution| {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        const candidate_name = directory_candidate_name;
        const foreign = try temporary.dir.createFile(
            "foreign",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        foreign.close();
        switch (substitution) {
            .symlink => try temporary.dir.symLink(
                "foreign",
                candidate_name,
                .{},
            ),
            .hard_link => try std.posix.linkat(
                temporary.dir.fd,
                "foreign",
                temporary.dir.fd,
                candidate_name,
                0,
            ),
        }

        var publisher = try PublisherV1.init(temporary.dir);
        defer publisher.close();
        const records = testRecordsV1(false);
        if (substitution == .hard_link) {
            try testing.expectError(
                error.MultipleLinks,
                publisher.writeWithProvider(
                    testing.allocator,
                    "model.glrt",
                    testOptionsV1("unsafe-candidate"),
                    &records,
                    null,
                    null,
                ),
            );
        } else {
            _ = publisher.writeWithProvider(
                testing.allocator,
                "model.glrt",
                testOptionsV1("unsafe-candidate"),
                &records,
                null,
                null,
            ) catch {};
            const target = temporary.dir.openFile(
                "model.glrt",
                .{},
            );
            try testing.expectError(
                error.FileNotFound,
                target,
            );
        }
        const foreign_stat = try temporary.dir.statFile("foreign");
        try testing.expectEqual(@as(u64, 0), foreign_stat.size);
    }
}

test "durable runtime image target rejects link substitution before candidate creation" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    const substitutions = [_]enum {
        symlink,
        hard_link,
    }{ .symlink, .hard_link };
    for (substitutions) |substitution| {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        const foreign = try temporary.dir.createFile(
            "foreign",
            .{
                .read = true,
                .exclusive = true,
                .mode = 0o600,
            },
        );
        try foreign.writeAll("foreign-target");
        foreign.close();
        switch (substitution) {
            .symlink => try temporary.dir.symLink(
                "foreign",
                "model.glrt",
                .{},
            ),
            .hard_link => try std.posix.linkat(
                temporary.dir.fd,
                "foreign",
                temporary.dir.fd,
                "model.glrt",
                0,
            ),
        }

        var publisher = try PublisherV1.init(temporary.dir);
        defer publisher.close();
        const records = testRecordsV1(false);
        if (substitution == .hard_link) {
            try testing.expectError(
                error.MultipleLinks,
                publisher.writeWithProvider(
                    testing.allocator,
                    "model.glrt",
                    testOptionsV1("unsafe-target"),
                    &records,
                    null,
                    null,
                ),
            );
        } else {
            try testing.expectError(
                error.SymLinkLoop,
                publisher.writeWithProvider(
                    testing.allocator,
                    "model.glrt",
                    testOptionsV1("unsafe-target"),
                    &records,
                    null,
                    null,
                ),
            );
        }
        try expectCandidateMissingV1(
            temporary.dir,
            "model.glrt",
        );
        const foreign_bytes = try temporary.dir.readFileAlloc(
            testing.allocator,
            "foreign",
            1024,
        );
        defer testing.allocator.free(foreign_bytes);
        try testing.expectEqualStrings(
            "foreign-target",
            foreign_bytes,
        );
    }
}

test "durable runtime image target rejects a FIFO without blocking" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    const posix_fixture = struct {
        extern "c" fn mkfifoat(
            directory_fd: std.posix.fd_t,
            path: [*:0]const u8,
            mode: std.posix.mode_t,
        ) c_int;
    };
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    if (posix_fixture.mkfifoat(
        temporary.dir.fd,
        "model.glrt",
        0o600,
    ) != 0)
        return error.Unexpected;

    var publisher = try PublisherV1.init(temporary.dir);
    defer publisher.close();
    const records = testRecordsV1(false);
    try testing.expectError(
        error.UnsafeStorage,
        publisher.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("unsafe-fifo-target"),
            &records,
            null,
            null,
        ),
    );
    try expectCandidateMissingV1(
        temporary.dir,
        "model.glrt",
    );
}

test "durable runtime image corrupt existing target fails closed unchanged" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const corrupt = "not-a-runtime-image";
    const target = try temporary.dir.createFile(
        "model.glrt",
        .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        },
    );
    try target.writeAll(corrupt);
    try target.sync();
    target.close();

    var publisher = try PublisherV1.init(temporary.dir);
    const records = testRecordsV1(false);
    try testing.expectError(
        error.InvalidExistingTarget,
        publisher.writeWithProvider(
            testing.allocator,
            "model.glrt",
            testOptionsV1("corrupt-target"),
            &records,
            null,
            null,
        ),
    );
    try testing.expectEqual(
        PublisherStateV1.live,
        publisher.observation().state,
    );
    publisher.close();
    const retained = try temporary.dir.readFileAlloc(
        testing.allocator,
        "model.glrt",
        1024,
    );
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings(corrupt, retained);
    try expectCandidateMissingV1(
        temporary.dir,
        "model.glrt",
    );
}
