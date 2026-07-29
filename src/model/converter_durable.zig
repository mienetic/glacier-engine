//! Recoverable durable publication for portable `.glacier` model conversion.
//!
//! The converter owns the container bytes. This POSIX adapter owns the
//! descriptor-relative publication protocol: it pins and preflights the output
//! directory, pins and hashes the source, serializes through one private
//! directory-scoped candidate, synchronizes and strictly validates that exact
//! inode, atomically replaces the target, and commits the directory.
//!
//! Process death before target replacement leaves the previous target
//! authoritative. Process death after replacement may expose only the complete,
//! synchronized successor. A fresh publisher removes bounded candidate debris
//! and deterministically rebuilds from the caller's source and conversion
//! profile. This is host-filesystem/process-death behavior. It is not evidence
//! of physical power-loss persistence, controller-cache behavior, or remote
//! filesystem semantics.

const std = @import("std");
const core = @import("core");
const converter = @import("converter.zig");
const fmt = @import("format.zig");

const durable_directory = core.durable_directory_authority;
const platform_capabilities = core.platform_capabilities;

pub const publication_abi: u64 = 0x474c_4450_0000_0002;
pub const Digest = [32]u8;

const plan_domain = "glacier-conversion-publication-plan-v2\x00";
const reserved_prefix = ".glacier-conversion-";
const directory_lock_name =
    ".glacier-conversion-publication.lock-v1";
const directory_candidate_name =
    ".glacier-conversion-publication.candidate-v1";

pub const PublisherStateV1 = enum(u8) {
    live,
    poisoned,
    closed,
};

/// Stable crash-observation vocabulary. `candidate_page_progress` is emitted
/// exactly once, after the converter completes its first payload page.
pub const PublicationPhaseV1 = enum(u8) {
    stale_candidate_removed,
    candidate_created,
    candidate_page_progress,
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

    fn after(self: ObserverV1, phase: PublicationPhaseV1) !void {
        try self.after_phase_fn(self.context, phase);
    }
};

/// Read-only validation of the exact source descriptor captured by the
/// durable publisher. The callback runs before the publisher borrows its
/// directory authority or mutates any lock, candidate, or target namespace.
pub const SourcePreflightV1 = struct {
    context: *anyopaque,
    validate_fn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        source_file: *std.fs.File,
        source_bytes: u64,
    ) anyerror!void,

    fn validate(
        self: SourcePreflightV1,
        allocator: std.mem.Allocator,
        source_file: *std.fs.File,
        source_bytes: u64,
    ) !void {
        try self.validate_fn(
            self.context,
            allocator,
            source_file,
            source_bytes,
        );
    }
};

pub const PublicationDispositionV1 = enum(u8) {
    published,
    already_current,
};

pub const SourceIdentityV1 = struct {
    source_bytes: u64,
    source_sha256: Digest,
};

pub const ArtifactIdentityV1 = struct {
    container_bytes: u64,
    page_count: u64,
    container_sha256: Digest,
};

pub const PublicationReceiptV1 = struct {
    abi_version: u64 = publication_abi,
    disposition: PublicationDispositionV1,
    publication_plan_sha256: Digest,
    source_identity: SourceIdentityV1,
    artifact_identity: ArtifactIdentityV1,
    conversion: converter.ConvertResult,
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

    /// Acquire a sync-capable descriptor for the exact directory represented by
    /// `anchor`. The caller retains ownership of `anchor` and may close it after
    /// this function returns.
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

    pub fn observation(self: *const PublisherV1) PublisherObservationV1 {
        return .{
            .state = self.state,
            .directory = self.directory_authority.observation(),
        };
    }

    /// Convert one Safetensors source into a portable `.glacier` target beneath
    /// the acquired directory.
    ///
    /// The source path is opened once with no-follow/non-blocking/close-on-exec
    /// semantics. Its descriptor, stat identity, length, and full SHA-256 remain
    /// pinned through conversion. A complete source revalidation runs before
    /// target/candidate admission and repeats at the final publication boundary,
    /// immediately before either idempotent candidate deletion or target
    /// replacement. Sources and admitted targets must be regular, single-link
    /// files that are not group- or world-writable. The lock and candidate are
    /// additionally private (`0600`). The source path itself need not be beneath
    /// the output directory.
    pub fn convertSafetensors(
        self: *PublisherV1,
        allocator: std.mem.Allocator,
        source_path: []const u8,
        target_name: []const u8,
        options: converter.ConvertOptions,
        observer: ?ObserverV1,
    ) !PublicationReceiptV1 {
        return self.convertSafetensorsWithPreflight(
            allocator,
            source_path,
            target_name,
            options,
            null,
            observer,
        );
    }

    pub fn convertSafetensorsWithPreflight(
        self: *PublisherV1,
        allocator: std.mem.Allocator,
        source_path: []const u8,
        target_name: []const u8,
        options: converter.ConvertOptions,
        source_preflight: ?SourcePreflightV1,
        observer: ?ObserverV1,
    ) !PublicationReceiptV1 {
        if (comptime !durableAdapterAvailableV1())
            return error.UnsupportedPlatform;
        if (self.state != .live)
            return error.InvalidPublisherState;
        if (source_path.len == 0)
            return error.InvalidSourcePath;
        try validateTargetNameV1(target_name);
        // The public conversion-profile function is also the converter's
        // side-effect-free option validator. Admit the complete option set
        // before acquiring or creating the stable lock, inspecting/removing a
        // stale candidate, or otherwise mutating the output namespace.
        try validateConversionOptionsBeforeMutationV1(options);

        var source_file = try openSafeSourcePathV1(source_path);
        defer source_file.close();
        const captured_source = try captureStableSourceV1(source_file);
        if (source_preflight) |preflight| {
            try preflight.validate(
                allocator,
                &source_file,
                captured_source.snapshot.view.size,
            );
            try revalidateSourceV1(
                source_file,
                captured_source,
            );
        }
        const source_identity: SourceIdentityV1 = .{
            .source_bytes = captured_source.snapshot.view.size,
            .source_sha256 = captured_source.sha256,
        };
        const publication_plan_sha256 = publicationPlanSha256V1(
            target_name,
            source_identity,
            options,
        );

        const directory = self.directory_authority.borrow() catch
            return error.InvalidPublisherState;
        var lock = try acquireTargetLockV1(
            directory,
            directory_lock_name,
            captured_source.snapshot.view,
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
            directory_lock_name,
            lock,
        );

        // The target/source alias check intentionally precedes any candidate
        // cleanup or creation. A same-path or hard-link invocation therefore
        // cannot delete or truncate its own source.
        const target_before = try existingTargetSnapshotV1(
            allocator,
            directory,
            target_name,
            captured_source.snapshot.view,
        );
        if (captured_source.snapshot.link_count != 1)
            return error.MultipleLinks;

        var namespace_mutated = false;
        errdefer if (namespace_mutated) {
            self.state = .poisoned;
        };

        var stale_candidate_removed = false;
        if (try removeStaleCandidateV1(
            directory,
            directory_candidate_name,
            captured_source.snapshot.view,
        )) {
            namespace_mutated = true;
            self.state = .poisoned;
            try self.directory_authority.commit();
            self.state = .live;
            stale_candidate_removed = true;
            if (observer) |value|
                try value.after(.stale_candidate_removed);
        }

        var conversion: converter.ConvertResult = undefined;
        const initial_candidate_view: FileViewV1 = candidate: {
            const file = try openSafeFileV1(
                directory,
                directory_candidate_name,
                .create,
                .read_write,
            );
            defer file.close();
            namespace_mutated = true;
            const initial_view = try inspectFileV1(
                file,
                directory,
                directory_candidate_name,
                .private,
                null,
            );
            if (initial_view.size != 0)
                return error.NonEmptyCandidate;
            if (observer) |value|
                try value.after(.candidate_created);

            var progress_bridge: ProgressBridgeV1 = .{
                .observer = observer,
            };
            conversion =
                try converter.convertSafetensorsFilesWithObserverV1(
                    allocator,
                    source_file,
                    file,
                    options,
                    progress_bridge.interface(),
                );
            if (!progress_bridge.page_progress_emitted or
                conversion.num_pages == 0)
                return error.MissingConversionProgress;
            if (conversion.source_bytes != source_identity.source_bytes or
                !digestEqlV1(
                    conversion.source_sha256,
                    source_identity.source_sha256,
                ))
                return error.SourceChanged;
            if (observer) |value|
                try value.after(.candidate_encoded);

            try file.sync();
            if (observer) |value|
                try value.after(.candidate_synced);
            const synced_view = try inspectFileV1(
                file,
                directory,
                directory_candidate_name,
                .private,
                null,
            );
            if (!sameObjectV1(initial_view, synced_view))
                return error.StorageIdentityChanged;
            break :candidate initial_view;
        };

        var candidate = try openValidatedArtifactV1(
            allocator,
            directory,
            directory_candidate_name,
            .private,
            null,
            error.InvalidCandidate,
        );
        defer candidate.close();
        if (!sameObjectV1(initial_candidate_view, candidate.view) or
            candidate.view.size != conversion.output_bytes or
            candidate.identity.page_count != conversion.num_pages or
            !digestEqlV1(
                candidate.identity.container_sha256,
                conversion.output_sha256,
            ))
            return error.ConversionIdentityMismatch;
        try revalidateSourceV1(
            source_file,
            captured_source,
        );
        try verifyTargetLockV1(
            directory,
            directory_lock_name,
            lock,
        );
        const target_after = try existingTargetSnapshotV1(
            allocator,
            directory,
            target_name,
            captured_source.snapshot.view,
        );
        if (!optionalTargetSnapshotEqlV1(
            target_before,
            target_after,
        ))
            return error.StorageIdentityChanged;
        try revalidateArtifactIdentityV1(&candidate);
        if (observer) |value|
            try value.after(.candidate_validated);

        if (target_after) |current| {
            if (artifactIdentityEqlV1(
                current.identity,
                candidate.identity,
            )) {
                // This second full stat-and-hash checkpoint is deliberately
                // adjacent to the idempotent publication branch. It closes the
                // interval consumed by target and candidate validation.
                try revalidateSourceV1(
                    source_file,
                    captured_source,
                );
                try directory.deleteFile(directory_candidate_name);
                self.state = .poisoned;
                try self.directory_authority.commit();
                self.state = .live;
                try verifyTargetLockV1(
                    directory,
                    directory_lock_name,
                    lock,
                );
                if (observer) |value|
                    try value.after(.directory_committed);
                return .{
                    .disposition = .already_current,
                    .publication_plan_sha256 = publication_plan_sha256,
                    .source_identity = source_identity,
                    .artifact_identity = candidate.identity,
                    .conversion = conversion,
                    .stale_candidate_removed = stale_candidate_removed,
                    .directory_observation = self.directory_authority.observation(),
                };
            }
        }

        // Repeat the complete source identity check after every target and
        // candidate validation and immediately before namespace replacement.
        try revalidateSourceV1(
            source_file,
            captured_source,
        );
        try directory.rename(
            directory_candidate_name,
            target_name,
        );
        self.state = .poisoned;
        if (observer) |value|
            try value.after(.target_replaced);
        const renamed_view = try inspectFileV1(
            candidate.file,
            directory,
            target_name,
            .private,
            null,
        );
        if (!sameObjectV1(initial_candidate_view, renamed_view) or
            renamed_view.size != candidate.identity.container_bytes)
            return error.StorageIdentityChanged;

        try self.directory_authority.commit();
        self.state = .live;
        try verifyTargetLockV1(
            directory,
            directory_lock_name,
            lock,
        );
        if (observer) |value|
            try value.after(.directory_committed);
        const committed_view = try inspectFileV1(
            candidate.file,
            directory,
            target_name,
            .private,
            null,
        );
        const committed_container =
            try candidate.reader.containerIdentityV1();
        if (!std.meta.eql(renamed_view, committed_view) or
            committed_container.container_bytes !=
                candidate.identity.container_bytes or
            !digestEqlV1(
                committed_container.container_sha256,
                candidate.identity.container_sha256,
            ))
            return error.StorageIdentityChanged;

        return .{
            .disposition = .published,
            .publication_plan_sha256 = publication_plan_sha256,
            .source_identity = source_identity,
            .artifact_identity = candidate.identity,
            .conversion = conversion,
            .stale_candidate_removed = stale_candidate_removed,
            .directory_observation = self.directory_authority.observation(),
        };
    }
};

/// Resolve and acquire the output parent once, then durably convert one source
/// into the basename beneath that pinned descriptor. Callers that already own a
/// directory trust boundary should use `PublisherV1`.
pub fn convertSafetensorsDurableV1(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    output_path: []const u8,
    options: converter.ConvertOptions,
    observer: ?ObserverV1,
) !PublicationReceiptV1 {
    return convertSafetensorsDurableWithPreflightV1(
        allocator,
        source_path,
        output_path,
        options,
        null,
        observer,
    );
}

pub fn convertSafetensorsDurableWithPreflightV1(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    output_path: []const u8,
    options: converter.ConvertOptions,
    source_preflight: ?SourcePreflightV1,
    observer: ?ObserverV1,
) !PublicationReceiptV1 {
    if (comptime !durableAdapterAvailableV1())
        return error.UnsupportedPlatform;
    if (output_path.len == 0 or
        std.fs.path.isSep(output_path[output_path.len - 1]))
        return error.InvalidTargetName;
    const target_name = std.fs.path.basename(output_path);
    try validateTargetNameV1(target_name);

    if (std.fs.path.dirname(output_path)) |parent_path| {
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
        return publisher.convertSafetensorsWithPreflight(
            allocator,
            source_path,
            target_name,
            options,
            source_preflight,
            observer,
        );
    }

    var publisher = try PublisherV1.init(std.fs.cwd());
    defer publisher.close();
    return publisher.convertSafetensorsWithPreflight(
        allocator,
        source_path,
        target_name,
        options,
        source_preflight,
        observer,
    );
}

fn durableAdapterAvailableV1() bool {
    return platform_capabilities.current_adapter_availability_v1
        .posix_durable_file_adapter;
}

const ProgressBridgeV1 = struct {
    observer: ?ObserverV1,
    page_progress_emitted: bool = false,

    fn after(
        context: *anyopaque,
        progress: converter.ConversionProgressV1,
    ) anyerror!void {
        const self: *ProgressBridgeV1 =
            @ptrCast(@alignCast(context));
        if (progress.phase != .payload_page_completed or
            self.page_progress_emitted)
            return;
        if (progress.completed_pages != 1 or
            progress.total_pages == 0)
            return error.InvalidConversionProgress;
        self.page_progress_emitted = true;
        if (self.observer) |value|
            try value.after(.candidate_page_progress);
    }

    fn interface(
        self: *ProgressBridgeV1,
    ) converter.ConversionProgressObserverV1 {
        return .{
            .context = self,
            .observe_fn = after,
        };
    }
};

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

const RawFileViewV1 = struct {
    device: u64,
    inode: u64,
    size: u64,
    link_count: u64,
    mode: u32,
};

const FileViewV1 = struct {
    device: u64,
    inode: u64,
    size: u64,
};

const SourceSnapshotV1 = struct {
    view: FileViewV1,
    link_count: u64,
    mode: u32,
    mtime: i128,
    ctime: i128,
};

const CapturedSourceV1 = struct {
    snapshot: SourceSnapshotV1,
    sha256: Digest,
};

const TargetLockV1 = struct {
    file: std.fs.File,
    created: bool,
    view: FileViewV1,
};

const TargetSnapshotV1 = struct {
    view: FileViewV1,
    identity: ArtifactIdentityV1,
};

const ValidatedArtifactV1 = struct {
    file: std.fs.File,
    reader: fmt.FileReader,
    view: FileViewV1,
    identity: ArtifactIdentityV1,

    fn close(self: *ValidatedArtifactV1) void {
        self.reader.close();
        self.file.close();
        self.* = undefined;
    }
};

fn openSafeSourcePathV1(path: []const u8) !std.fs.File {
    if (comptime !durableAdapterAvailableV1())
        return error.UnsupportedPlatform;
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW") or
        !@hasField(std.posix.O, "NONBLOCK"))
        return error.UnsupportedPlatform;
    var flags: std.posix.O = .{ .ACCMODE = .RDONLY };
    flags.CLOEXEC = true;
    flags.NOFOLLOW = true;
    flags.NONBLOCK = true;
    if (@hasField(std.posix.O, "NOCTTY"))
        flags.NOCTTY = true;
    const fd = try std.posix.open(path, flags, 0);
    return .{ .handle = fd };
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

fn rawStatV1(stat: std.posix.Stat) !RawFileViewV1 {
    return .{
        .device = std.math.cast(u64, stat.dev) orelse
            return error.UnsafeStorage,
        .inode = std.math.cast(u64, stat.ino) orelse
            return error.UnsafeStorage,
        .size = std.math.cast(u64, stat.size) orelse
            return error.UnsafeStorage,
        .link_count = std.math.cast(u64, stat.nlink) orelse
            return error.UnsafeStorage,
        .mode = std.math.cast(u32, stat.mode) orelse
            return error.UnsafeStorage,
    };
}

fn checkedViewV1(
    raw: RawFileViewV1,
    permission_policy: PermissionPolicyV1,
) !FileViewV1 {
    if ((raw.mode & std.posix.S.IFMT) != std.posix.S.IFREG)
        return error.UnsafeStorage;
    if (raw.link_count != 1)
        return error.MultipleLinks;
    switch (permission_policy) {
        .private => if ((raw.mode & 0o077) != 0)
            return error.UnsafePermissions,
        .public_read_only => if ((raw.mode & 0o022) != 0)
            return error.UnsafePermissions,
    }
    return .{
        .device = raw.device,
        .inode = raw.inode,
        .size = raw.size,
    };
}

fn inspectFileV1(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    permission_policy: PermissionPolicyV1,
    forbidden_alias: ?FileViewV1,
) !FileViewV1 {
    const file_raw = try rawStatV1(try std.posix.fstat(file.handle));
    const entry_raw = try rawStatV1(try std.posix.fstatat(
        directory.fd,
        name,
        std.posix.AT.SYMLINK_NOFOLLOW,
    ));
    if (!std.meta.eql(file_raw, entry_raw))
        return error.StorageIdentityChanged;
    if (forbidden_alias) |source| {
        if (rawSameObjectV1(file_raw, source))
            return error.SourceOutputAlias;
    }
    return checkedViewV1(file_raw, permission_policy);
}

fn inspectSourceV1(file: std.fs.File) !SourceSnapshotV1 {
    const raw = try rawStatV1(try std.posix.fstat(file.handle));
    if ((raw.mode & std.posix.S.IFMT) != std.posix.S.IFREG)
        return error.UnsafeStorage;
    if ((raw.mode & 0o022) != 0)
        return error.UnsafePermissions;
    const stat = try file.stat();
    if (stat.kind != .file or
        stat.inode != raw.inode or
        stat.size != raw.size)
        return error.StorageIdentityChanged;
    return .{
        .view = .{
            .device = raw.device,
            .inode = raw.inode,
            .size = raw.size,
        },
        .link_count = raw.link_count,
        .mode = raw.mode,
        .mtime = stat.mtime,
        .ctime = stat.ctime,
    };
}

fn captureStableSourceV1(
    file: std.fs.File,
) !CapturedSourceV1 {
    const before = try inspectSourceV1(file);
    const digest = hashFileV1(file, before.view.size) catch
        return error.SourceChanged;
    const after = try inspectSourceV1(file);
    if (!std.meta.eql(before, after))
        return error.SourceChanged;
    return .{
        .snapshot = after,
        .sha256 = digest,
    };
}

fn revalidateSourceV1(
    file: std.fs.File,
    captured: CapturedSourceV1,
) !void {
    const before = try inspectSourceV1(file);
    if (!std.meta.eql(before, captured.snapshot))
        return error.SourceChanged;
    const digest = hashFileV1(file, before.view.size) catch
        return error.SourceChanged;
    const after = try inspectSourceV1(file);
    if (!std.meta.eql(after, captured.snapshot) or
        !digestEqlV1(digest, captured.sha256))
        return error.SourceChanged;
}

fn hashFileV1(
    file: std.fs.File,
    file_size: u64,
) !Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [fmt.STREAM_BUFFER_SIZE]u8 = undefined;
    var offset: u64 = 0;
    while (offset < file_size) {
        const chunk_len: usize = @intCast(@min(
            file_size - offset,
            @as(u64, @intCast(buffer.len)),
        ));
        const chunk = buffer[0..chunk_len];
        if (try file.preadAll(chunk, offset) != chunk.len)
            return error.UnexpectedEndOfFile;
        hash.update(chunk);
        offset = std.math.add(
            u64,
            offset,
            chunk.len,
        ) catch return error.FileTooLarge;
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn acquireTargetLockV1(
    directory: std.fs.Dir,
    name: []const u8,
    source: FileViewV1,
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
    const view = inspectFileV1(
        file,
        directory,
        name,
        .private,
        source,
    ) catch |err| switch (err) {
        error.SourceOutputAlias => return error.SourceReservedAlias,
        else => return err,
    };
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
        null,
    );
    if (!std.meta.eql(current, lock.view))
        return error.StorageIdentityChanged;
}

fn removeStaleCandidateV1(
    directory: std.fs.Dir,
    name: []const u8,
    source: FileViewV1,
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
    _ = inspectFileV1(
        file,
        directory,
        name,
        .private,
        source,
    ) catch |err| switch (err) {
        error.SourceOutputAlias => return error.SourceReservedAlias,
        else => return err,
    };
    try directory.deleteFile(name);
    return true;
}

fn existingTargetSnapshotV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    name: []const u8,
    source: FileViewV1,
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
    var artifact = openValidatedArtifactFromFileV1(
        allocator,
        file,
        directory,
        name,
        .public_read_only,
        source,
        error.InvalidExistingTarget,
    ) catch |err| {
        file.close();
        return err;
    };
    defer artifact.close();
    return .{
        .view = artifact.view,
        .identity = artifact.identity,
    };
}

fn openValidatedArtifactV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    name: []const u8,
    permission_policy: PermissionPolicyV1,
    forbidden_alias: ?FileViewV1,
    comptime invalid_error: anyerror,
) !ValidatedArtifactV1 {
    const file = try openSafeFileV1(
        directory,
        name,
        .existing,
        .read_only,
    );
    return openValidatedArtifactFromFileV1(
        allocator,
        file,
        directory,
        name,
        permission_policy,
        forbidden_alias,
        invalid_error,
    ) catch |err| {
        file.close();
        return err;
    };
}

fn openValidatedArtifactFromFileV1(
    allocator: std.mem.Allocator,
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    permission_policy: PermissionPolicyV1,
    forbidden_alias: ?FileViewV1,
    comptime invalid_error: anyerror,
) !ValidatedArtifactV1 {
    const initial_view = try inspectFileV1(
        file,
        directory,
        name,
        permission_policy,
        forbidden_alias,
    );
    var reader = fmt.FileReader.openBorrowedFile(
        allocator,
        file,
    ) catch return invalid_error;
    errdefer reader.close();
    reader.validateAllPageCrcs() catch return invalid_error;
    const container = reader.containerIdentityV1() catch
        return invalid_error;
    const page_count = std.math.cast(
        u64,
        reader.pages.len,
    ) orelse return invalid_error;
    const final_view = try inspectFileV1(
        file,
        directory,
        name,
        permission_policy,
        forbidden_alias,
    );
    if (!std.meta.eql(initial_view, final_view) or
        container.container_bytes != final_view.size)
        return error.StorageIdentityChanged;
    return .{
        .file = file,
        .reader = reader,
        .view = final_view,
        .identity = .{
            .container_bytes = container.container_bytes,
            .page_count = page_count,
            .container_sha256 = container.container_sha256,
        },
    };
}

fn optionalTargetSnapshotEqlV1(
    left: ?TargetSnapshotV1,
    right: ?TargetSnapshotV1,
) bool {
    if (left == null or right == null)
        return left == null and right == null;
    return std.meta.eql(left.?.view, right.?.view) and
        artifactIdentityEqlV1(
            left.?.identity,
            right.?.identity,
        );
}

fn revalidateArtifactIdentityV1(
    artifact: *const ValidatedArtifactV1,
) !void {
    artifact.reader.validateAllPageCrcs() catch
        return error.StorageIdentityChanged;
    const current = artifact.reader.containerIdentityV1() catch
        return error.StorageIdentityChanged;
    if (current.container_bytes != artifact.identity.container_bytes or
        !digestEqlV1(
            current.container_sha256,
            artifact.identity.container_sha256,
        ))
        return error.StorageIdentityChanged;
}

fn rawSameObjectV1(
    left: RawFileViewV1,
    right: FileViewV1,
) bool {
    return left.device == right.device and
        left.inode == right.inode;
}

fn sameObjectV1(left: FileViewV1, right: FileViewV1) bool {
    return left.device == right.device and
        left.inode == right.inode;
}

fn artifactIdentityEqlV1(
    left: ArtifactIdentityV1,
    right: ArtifactIdentityV1,
) bool {
    return left.container_bytes == right.container_bytes and
        left.page_count == right.page_count and
        digestEqlV1(
            left.container_sha256,
            right.container_sha256,
        );
}

fn digestEqlV1(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
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

/// V2 publication intent binds the converter contract ABIs and canonical
/// effective output settings. Deprecated verification input, disabled
/// quantization settings, redundant/order-only overrides, and overrides for
/// tensor kinds that the converter always stores losslessly are excluded.
pub fn publicationPlanSha256V1(
    target_name: []const u8,
    source: SourceIdentityV1,
    options: converter.ConvertOptions,
) Digest {
    return publicationPlanSha256WithContractsV1(
        target_name,
        source,
        options,
        converter.conversion_profile_abi,
        converter.conversion_plan_abi,
    );
}

// Only these tensor classes can reach the converter's quantized path. Norms
// and projection biases remain lossless even when INT4 conversion is enabled.
// `.other` is the canonical base entry; deviations for the remaining kinds are
// serialized in this fixed order.
const effective_quantized_kinds_v1 = [_]fmt.TensorKind{
    .embedding,
    .attn_q,
    .attn_k,
    .attn_v,
    .attn_o,
    .mlp_up,
    .mlp_down,
    .mlp_gate,
    .lm_head,
    .other,
};

fn validateConversionOptionsBeforeMutationV1(
    options: converter.ConvertOptions,
) !void {
    _ = try converter.conversionProfileSha256V1(options);
    if (!options.quantize_int4)
        return;

    // The converter performs this geometry check while planning each observed
    // quantizable tensor. Check every effective quantizable class up front so
    // no source-dependent InvalidOptions path can be reached after candidate
    // creation.
    const elements_per_page =
        options.page_size_bytes / @sizeOf(f32);
    for (effective_quantized_kinds_v1) |kind| {
        const group_size = effectiveQuantGroupV1(
            options,
            kind,
        );
        const group_size_u64: u64 = group_size;
        if (elements_per_page < group_size_u64 or
            elements_per_page % group_size_u64 != 0)
            return error.InvalidOptions;
    }
}

fn effectiveQuantGroupV1(
    options: converter.ConvertOptions,
    kind: fmt.TensorKind,
) u32 {
    for (options.quant_group_overrides) |item| {
        if (item.kind == kind)
            return item.group_size;
    }
    return options.quant_group_size;
}

fn publicationPlanSha256WithContractsV1(
    target_name: []const u8,
    source: SourceIdentityV1,
    options: converter.ConvertOptions,
    conversion_profile_abi: u64,
    conversion_plan_abi: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, publication_abi);
    hashU64(&hash, conversion_profile_abi);
    hashU64(&hash, conversion_plan_abi);
    hashU64(&hash, target_name.len);
    hash.update(target_name);
    hashU16(&hash, fmt.VERSION);
    hashU64(&hash, source.source_bytes);
    hash.update(&source.source_sha256);
    hashU64(&hash, options.page_size_bytes);
    hashU64(&hash, options.architecture.len);
    hash.update(options.architecture);
    hashU8(&hash, @intFromBool(options.quantize_int4));

    // Quantization settings have no conversion effect while INT4 is disabled.
    // When enabled, encode the effective quantizable-kind mapping rather than
    // caller ordering, redundant overrides, or settings for always-raw kinds.
    if (!options.quantize_int4) {
        var result: Digest = undefined;
        hash.final(&result);
        return result;
    }
    const canonical_group = effectiveQuantGroupV1(
        options,
        .other,
    );
    hashU32(&hash, canonical_group);
    var effective_override_count: u64 = 0;
    for (effective_quantized_kinds_v1[0 .. effective_quantized_kinds_v1.len - 1]) |kind| {
        if (effectiveQuantGroupV1(options, kind) != canonical_group)
            effective_override_count += 1;
    }
    hashU64(&hash, effective_override_count);
    for (effective_quantized_kinds_v1[0 .. effective_quantized_kinds_v1.len - 1]) |kind| {
        const group_size = effectiveQuantGroupV1(options, kind);
        if (group_size == canonical_group)
            continue;
        hashU32(&hash, @intFromEnum(kind));
        hashU32(&hash, group_size);
    }
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&.{value});
}

fn hashU16(hash: *std.crypto.hash.sha2.Sha256, value: u16) void {
    var encoded: [2]u8 = undefined;
    std.mem.writeInt(u16, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

// --------------------------------------------------------------------------
// Focused durable-conversion tests
// --------------------------------------------------------------------------

const testing = std.testing;

fn testPathV1(
    allocator: std.mem.Allocator,
    directory: std.fs.Dir,
    name: []const u8,
) ![]u8 {
    const root = try directory.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, name });
}

fn writeTestSafetensorsV1(
    path: []const u8,
    seed: u8,
) !void {
    const json =
        \\{"weights":{"dtype":"F32","shape":[16],"data_offsets":[0,64]}}
    ;
    const file = try std.fs.cwd().createFile(path, .{
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    var header_len: [8]u8 = undefined;
    std.mem.writeInt(u64, &header_len, json.len, .little);
    try file.writeAll(&header_len);
    try file.writeAll(json);
    var payload: [64]u8 = undefined;
    for (&payload, 0..) |*byte, index|
        byte.* = seed +% @as(u8, @intCast(index));
    try file.writeAll(&payload);
    try file.sync();
}

fn testOptionsV1() converter.ConvertOptions {
    return .{
        .page_size_bytes = fmt.PAGE_SIZE_BYTES,
        .verify_on_write = true,
        .quantize_int4 = false,
    };
}

fn expectCandidateMissingV1(directory: std.fs.Dir) !void {
    try testing.expectError(
        error.FileNotFound,
        directory.openFile(directory_candidate_name, .{}),
    );
}

test "publication plan binds both converter algorithm contracts" {
    const source: SourceIdentityV1 = .{
        .source_bytes = 4096,
        .source_sha256 = [_]u8{0x5a} ** 32,
    };
    const options = testOptionsV1();
    const baseline = publicationPlanSha256V1(
        "model.glacier",
        source,
        options,
    );
    const changed_profile = publicationPlanSha256WithContractsV1(
        "model.glacier",
        source,
        options,
        converter.conversion_profile_abi +% 1,
        converter.conversion_plan_abi,
    );
    const changed_plan = publicationPlanSha256WithContractsV1(
        "model.glacier",
        source,
        options,
        converter.conversion_profile_abi,
        converter.conversion_plan_abi +% 1,
    );
    try testing.expect(!digestEqlV1(baseline, changed_profile));
    try testing.expect(!digestEqlV1(baseline, changed_plan));
}

test "publication plan canonicalizes effective conversion options" {
    const source: SourceIdentityV1 = .{
        .source_bytes = 8192,
        .source_sha256 = [_]u8{0xa5} ** 32,
    };
    const baseline_options = testOptionsV1();
    const baseline = publicationPlanSha256V1(
        "model.glacier",
        source,
        baseline_options,
    );

    var changed_verification = baseline_options;
    changed_verification.verify_on_write = false;
    try testing.expect(digestEqlV1(
        baseline,
        publicationPlanSha256V1(
            "model.glacier",
            source,
            changed_verification,
        ),
    ));

    const raw_only_overrides = [_]converter.QuantGroupOverride{
        .{ .kind = .attn_q, .group_size = 16 },
        .{ .kind = .input_norm, .group_size = 8 },
    };
    var changed_inactive_quant = baseline_options;
    changed_inactive_quant.quant_group_size = 32;
    changed_inactive_quant.quant_group_overrides =
        &raw_only_overrides;
    try testing.expect(digestEqlV1(
        baseline,
        publicationPlanSha256V1(
            "model.glacier",
            source,
            changed_inactive_quant,
        ),
    ));

    const overrides_a = [_]converter.QuantGroupOverride{
        .{ .kind = .attn_q, .group_size = 32 },
        .{ .kind = .input_norm, .group_size = 8 },
        .{ .kind = .mlp_down, .group_size = 16 },
    };
    const overrides_b = [_]converter.QuantGroupOverride{
        .{ .kind = .mlp_down, .group_size = 16 },
        .{ .kind = .attn_q, .group_size = 32 },
    };
    var quant_a = baseline_options;
    quant_a.quantize_int4 = true;
    quant_a.quant_group_overrides = &overrides_a;
    var quant_b = baseline_options;
    quant_b.quantize_int4 = true;
    quant_b.quant_group_overrides = &overrides_b;
    try testing.expect(digestEqlV1(
        publicationPlanSha256V1(
            "model.glacier",
            source,
            quant_a,
        ),
        publicationPlanSha256V1(
            "model.glacier",
            source,
            quant_b,
        ),
    ));

    const redundant_override = [_]converter.QuantGroupOverride{
        .{ .kind = .attn_q, .group_size = 64 },
    };
    var quant_redundant = baseline_options;
    quant_redundant.quantize_int4 = true;
    quant_redundant.quant_group_overrides =
        &redundant_override;
    var quant_default = baseline_options;
    quant_default.quantize_int4 = true;
    try testing.expect(digestEqlV1(
        publicationPlanSha256V1(
            "model.glacier",
            source,
            quant_default,
        ),
        publicationPlanSha256V1(
            "model.glacier",
            source,
            quant_redundant,
        ),
    ));

    var changed_effective_quant = quant_default;
    changed_effective_quant.quant_group_size = 32;
    try testing.expect(!digestEqlV1(
        publicationPlanSha256V1(
            "model.glacier",
            source,
            quant_default,
        ),
        publicationPlanSha256V1(
            "model.glacier",
            source,
            changed_effective_quant,
        ),
    ));
}

test "invalid converter options cannot mutate publication namespace" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "source.safetensors",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 29);
    const sentinel = "retained-stale-candidate";
    const stale = try temporary.dir.createFile(
        directory_candidate_name,
        .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        },
    );
    try stale.writeAll(sentinel);
    try stale.sync();
    stale.close();

    var invalid_options = testOptionsV1();
    invalid_options.page_size_bytes = @sizeOf(f32);
    invalid_options.quantize_int4 = true;
    invalid_options.quant_group_size = 64;
    var publisher = try PublisherV1.init(temporary.dir);
    defer publisher.close();
    try testing.expectError(
        error.InvalidOptions,
        publisher.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            invalid_options,
            null,
        ),
    );
    try testing.expectEqual(
        PublisherStateV1.live,
        publisher.observation().state,
    );
    try testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(directory_lock_name, .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile("model.glacier", .{}),
    );
    const retained = try temporary.dir.readFileAlloc(
        testing.allocator,
        directory_candidate_name,
        1024,
    );
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings(sentinel, retained);
}

const RejectingSourcePreflightV1 = struct {
    calls: usize = 0,
    observed_source_bytes: u64 = 0,

    fn validate(
        context: *anyopaque,
        _: std.mem.Allocator,
        source_file: *std.fs.File,
        source_bytes: u64,
    ) anyerror!void {
        const self: *RejectingSourcePreflightV1 =
            @ptrCast(@alignCast(context));
        self.calls += 1;
        self.observed_source_bytes = source_bytes;
        var prefix: [8]u8 = undefined;
        const read = try source_file.preadAll(&prefix, 0);
        if (read != prefix.len)
            return error.TestSourcePreflightShortRead;
        return error.TestSourcePreflightRejected;
    }

    fn interface(
        self: *RejectingSourcePreflightV1,
    ) SourcePreflightV1 {
        return .{
            .context = self,
            .validate_fn = validate,
        };
    }
};

test "source preflight rejects before publication namespace mutation" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "source.safetensors",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 31);
    const sentinel = "retained-preflight-candidate";
    const stale = try temporary.dir.createFile(
        directory_candidate_name,
        .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        },
    );
    try stale.writeAll(sentinel);
    try stale.sync();
    stale.close();

    var preflight: RejectingSourcePreflightV1 = .{};
    var publisher = try PublisherV1.init(temporary.dir);
    defer publisher.close();
    try testing.expectError(
        error.TestSourcePreflightRejected,
        publisher.convertSafetensorsWithPreflight(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
            preflight.interface(),
            null,
        ),
    );
    try testing.expectEqual(@as(usize, 1), preflight.calls);
    try testing.expect(preflight.observed_source_bytes > 8);
    try testing.expectEqual(
        PublisherStateV1.live,
        publisher.observation().state,
    );
    try testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile(directory_lock_name, .{}),
    );
    try testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile("model.glacier", .{}),
    );
    const retained = try temporary.dir.readFileAlloc(
        testing.allocator,
        directory_candidate_name,
        1024,
    );
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings(sentinel, retained);
}

test "durable conversion pins its directory and is idempotent" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "source.safetensors",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 7);
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

    const first = try publisher.convertSafetensors(
        testing.allocator,
        source_path,
        "model.glacier",
        testOptionsV1(),
        null,
    );
    try testing.expectEqual(
        PublicationDispositionV1.published,
        first.disposition,
    );
    try testing.expect(first.directory_observation
        .preflight_sync_completed);
    var pinned = try temporary.dir.openDir("pinned", .{});
    defer pinned.close();
    const visible = try pinned.openFile("model.glacier", .{});
    visible.close();
    var replacement = try temporary.dir.openDir("original", .{});
    defer replacement.close();
    try testing.expectError(
        error.FileNotFound,
        replacement.openFile("model.glacier", .{}),
    );

    const second = try publisher.convertSafetensors(
        testing.allocator,
        source_path,
        "model.glacier",
        testOptionsV1(),
        null,
    );
    try testing.expectEqual(
        PublicationDispositionV1.already_current,
        second.disposition,
    );
    try testing.expect(artifactIdentityEqlV1(
        first.artifact_identity,
        second.artifact_identity,
    ));
    try expectCandidateMissingV1(pinned);
}

test "durable conversion rejects a source-output alias before candidate mutation" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "model.glacier",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 11);
    const source_size = (try std.fs.cwd().statFile(source_path)).size;
    var publisher = try PublisherV1.init(temporary.dir);
    defer publisher.close();
    try testing.expectError(
        error.SourceOutputAlias,
        publisher.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
            null,
        ),
    );
    try expectCandidateMissingV1(temporary.dir);
    const source = try temporary.dir.openFile(
        "model.glacier",
        .{},
    );
    defer source.close();
    try testing.expectEqual(
        (try source.stat()).size,
        source_size,
    );
}

test "durable conversion rejects a hard-linked source-output alias" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "source.safetensors",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 13);
    try std.posix.linkat(
        temporary.dir.fd,
        "source.safetensors",
        temporary.dir.fd,
        "model.glacier",
        0,
    );
    const source_size = (try temporary.dir.statFile(
        "source.safetensors",
    )).size;

    var publisher = try PublisherV1.init(temporary.dir);
    defer publisher.close();
    try testing.expectError(
        error.SourceOutputAlias,
        publisher.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
            null,
        ),
    );
    try expectCandidateMissingV1(temporary.dir);
    try testing.expectEqual(
        source_size,
        (try temporary.dir.statFile("source.safetensors")).size,
    );
    try testing.expectEqual(
        source_size,
        (try temporary.dir.statFile("model.glacier")).size,
    );
}

test "durable conversion uses one directory-scoped lock" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "source.safetensors",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 3);
    const source_file = try openSafeSourcePathV1(source_path);
    defer source_file.close();
    const source = try captureStableSourceV1(source_file);
    var first = try PublisherV1.init(temporary.dir);
    defer first.close();
    var second = try PublisherV1.init(temporary.dir);
    defer second.close();
    var held = try acquireTargetLockV1(
        try first.directory_authority.borrow(),
        directory_lock_name,
        source.snapshot.view,
    );
    defer held.file.close();
    try testing.expectError(
        error.PublicationBusy,
        acquireTargetLockV1(
            try second.directory_authority.borrow(),
            directory_lock_name,
            source.snapshot.view,
        ),
    );
}

test "durable conversion rejects corrupt target and unsafe candidate" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "source.safetensors",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 5);
    const corrupt = "not-a-glacier-container";
    const target = try temporary.dir.createFile(
        "model.glacier",
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
    try testing.expectError(
        error.InvalidExistingTarget,
        publisher.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
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
        "model.glacier",
        1024,
    );
    defer testing.allocator.free(retained);
    try testing.expectEqualStrings(corrupt, retained);
    try expectCandidateMissingV1(temporary.dir);

    try temporary.dir.deleteFile("model.glacier");
    const foreign = try temporary.dir.createFile(
        "foreign",
        .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        },
    );
    foreign.close();
    try temporary.dir.symLink(
        "foreign",
        directory_candidate_name,
        .{},
    );
    var unsafe = try PublisherV1.init(temporary.dir);
    defer unsafe.close();
    try testing.expectError(
        error.SymLinkLoop,
        unsafe.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
            null,
        ),
    );
    const foreign_stat = try temporary.dir.statFile("foreign");
    try testing.expectEqual(@as(u64, 0), foreign_stat.size);
    try testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile("model.glacier", .{}),
    );

    try temporary.dir.deleteFile(directory_candidate_name);
    try std.posix.linkat(
        temporary.dir.fd,
        "foreign",
        temporary.dir.fd,
        directory_candidate_name,
        0,
    );
    try testing.expectError(
        error.MultipleLinks,
        unsafe.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
            null,
        ),
    );
    try testing.expectEqual(
        @as(u64, 0),
        (try temporary.dir.statFile("foreign")).size,
    );
    try testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile("model.glacier", .{}),
    );
}

const SourceDriftObserverV1 = struct {
    path: []const u8,
    trigger_phase: PublicationPhaseV1 = .candidate_encoded,

    fn after(
        context: *anyopaque,
        phase: PublicationPhaseV1,
    ) anyerror!void {
        const self: *SourceDriftObserverV1 =
            @ptrCast(@alignCast(context));
        if (phase != self.trigger_phase) return;
        const file = try std.fs.cwd().openFile(
            self.path,
            .{ .mode = .read_write },
        );
        defer file.close();
        _ = try file.pwrite(&.{0xff}, 8);
        try file.sync();
    }

    fn interface(self: *SourceDriftObserverV1) ObserverV1 {
        return .{
            .context = self,
            .after_phase_fn = after,
        };
    }
};

test "durable conversion detects source drift before replacement" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const source_path = try testPathV1(
        testing.allocator,
        temporary.dir,
        "source.safetensors",
    );
    defer testing.allocator.free(source_path);
    try writeTestSafetensorsV1(source_path, 19);
    var observer: SourceDriftObserverV1 = .{
        .path = source_path,
    };
    var publisher = try PublisherV1.init(temporary.dir);
    try testing.expectError(
        error.SourceChanged,
        publisher.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
            observer.interface(),
        ),
    );
    try testing.expectEqual(
        PublisherStateV1.poisoned,
        publisher.observation().state,
    );
    publisher.close();
    try testing.expectError(
        error.FileNotFound,
        temporary.dir.openFile("model.glacier", .{}),
    );
    const debris = try temporary.dir.openFile(
        directory_candidate_name,
        .{},
    );
    debris.close();
}

test "durable conversion repeats source hashing at both publication branches" {
    if (comptime !durableAdapterAvailableV1())
        return error.SkipZigTest;

    // Replacement branch: the first source checkpoint has already completed
    // when candidate_validated is observed. The repeated checkpoint must stop
    // replacement and retain only bounded candidate debris.
    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        const source_path = try testPathV1(
            testing.allocator,
            temporary.dir,
            "source.safetensors",
        );
        defer testing.allocator.free(source_path);
        try writeTestSafetensorsV1(source_path, 31);
        var observer: SourceDriftObserverV1 = .{
            .path = source_path,
            .trigger_phase = .candidate_validated,
        };
        var publisher = try PublisherV1.init(temporary.dir);
        try testing.expectError(
            error.SourceChanged,
            publisher.convertSafetensors(
                testing.allocator,
                source_path,
                "model.glacier",
                testOptionsV1(),
                observer.interface(),
            ),
        );
        try testing.expectEqual(
            PublisherStateV1.poisoned,
            publisher.observation().state,
        );
        publisher.close();
        try testing.expectError(
            error.FileNotFound,
            temporary.dir.openFile("model.glacier", .{}),
        );
        const candidate = try temporary.dir.openFile(
            directory_candidate_name,
            .{},
        );
        candidate.close();
    }

    // Idempotent branch: retain the authoritative target and do not delete the
    // candidate if the source changes after target/candidate admission.
    {
        var temporary = testing.tmpDir(.{});
        defer temporary.cleanup();
        const source_path = try testPathV1(
            testing.allocator,
            temporary.dir,
            "source.safetensors",
        );
        defer testing.allocator.free(source_path);
        try writeTestSafetensorsV1(source_path, 37);
        var publisher = try PublisherV1.init(temporary.dir);
        const baseline = try publisher.convertSafetensors(
            testing.allocator,
            source_path,
            "model.glacier",
            testOptionsV1(),
            null,
        );
        var observer: SourceDriftObserverV1 = .{
            .path = source_path,
            .trigger_phase = .candidate_validated,
        };
        try testing.expectError(
            error.SourceChanged,
            publisher.convertSafetensors(
                testing.allocator,
                source_path,
                "model.glacier",
                testOptionsV1(),
                observer.interface(),
            ),
        );
        try testing.expectEqual(
            PublisherStateV1.poisoned,
            publisher.observation().state,
        );
        publisher.close();

        var retained = try openValidatedArtifactV1(
            testing.allocator,
            temporary.dir,
            "model.glacier",
            .private,
            null,
            error.InvalidExistingTarget,
        );
        defer retained.close();
        try testing.expect(artifactIdentityEqlV1(
            baseline.artifact_identity,
            retained.identity,
        ));
        const candidate = try temporary.dir.openFile(
            directory_candidate_name,
            .{},
        );
        candidate.close();
    }
}
