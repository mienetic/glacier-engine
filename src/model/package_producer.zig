//! Ordinary user-model package production and admission.
//!
//! The producer consumes a same-process typed durable-conversion receipt,
//! prepares the exact converted artifact, and publishes a fixed admission
//! bundle only after the complete source → portable → prepared chain has been
//! validated. The bundle carries both the request-independent portable
//! manifest and the exact prepared-representation receipt. No digest is
//! accepted from CLI flags or parsed command output.

const std = @import("std");
const core = @import("core");
const bounded_input = @import("../bounded_file_input.zig");
const config = @import("../config.zig");
const tokenizer = @import("../tokenizer.zig");
const converter = @import("converter.zig");
const converter_durable = @import("converter_durable.zig");
const format = @import("format.zig");
const loader = @import("../loader.zig");
const package_manifest = @import("package_manifest.zig");
const runtime_image = @import("runtime_image.zig");

const durable_directory = core.durable_directory_authority;

pub const maximum_license_bytes: u64 = 64 * 1024;
pub const maximum_config_bytes: u64 = 1024 * 1024;
pub const tokenizer_max_input_bytes: u64 = 4096;
const publication_lock_name =
    ".glacier-model-package-publication.lock-v1";

pub const Error = error{
    UnsupportedPackageProfile,
    InvalidModelConfig,
    InvalidConfigInput,
    InvalidLicense,
    ArtifactIdentityMismatch,
    PreparedIdentityMismatch,
    PackageConflict,
    PublicationBusy,
    OutputAlias,
    InvalidOutputPath,
};

pub const PackageDispositionV1 = enum {
    published,
    already_current,
};

pub const OptionsV1 = struct {
    config_path: ?[]const u8 = null,
    conversion: converter.ConvertOptions = .{
        .quantize_int4 = true,
        .quant_group_size = 64,
    },
};

pub const ConfigSourceV1 = enum {
    derived,
    explicit,
};

pub const ConfigInputIdentityV1 = struct {
    bytes: u64,
    sha256: package_manifest.Digest,
};

pub const ReceiptV1 = struct {
    conversion_disposition: converter_durable.PublicationDispositionV1,
    package_disposition: PackageDispositionV1,
    source_identity: converter_durable.SourceIdentityV1,
    portable_identity: converter_durable.ArtifactIdentityV1,
    conversion_profile_sha256: package_manifest.Digest,
    conversion_plan_sha256: package_manifest.Digest,
    package: package_manifest.ManifestV1,
    representation: package_manifest.PreparedRepresentationV1,
    tokenizer_manifest: tokenizer.Utf8ByteManifestV1,
    prepared_identity: runtime_image.ImageIdentityV1,
    prepare_stats: runtime_image.WriteStats,
    config_source: ConfigSourceV1,
    config_input_identity: ?ConfigInputIdentityV1,
};

pub fn configFromLoadedModelV1(
    model_config: loader.ModelConfig,
) Error!package_manifest.ConfigV1 {
    return .{
        .dim = std.math.cast(u32, model_config.dim) orelse
            return Error.InvalidModelConfig,
        .hidden_dim = std.math.cast(
            u32,
            model_config.hidden_dim,
        ) orelse return Error.InvalidModelConfig,
        .layers = std.math.cast(
            u32,
            model_config.num_layers,
        ) orelse return Error.InvalidModelConfig,
        .vocab = std.math.cast(
            u32,
            model_config.vocab_size,
        ) orelse return Error.InvalidModelConfig,
        .heads = std.math.cast(
            u32,
            model_config.num_heads,
        ) orelse return Error.InvalidModelConfig,
        .head_dim = std.math.cast(
            u32,
            model_config.head_dim,
        ) orelse return Error.InvalidModelConfig,
        .kv_heads = std.math.cast(
            u32,
            model_config.num_kv_heads,
        ) orelse return Error.InvalidModelConfig,
        .rms_eps = model_config.rms_eps,
        .rope_theta = model_config.rope_theta,
        .tie_embeddings = model_config.tie_word_embeddings,
    };
}

/// Admit the one package profile implemented by the current ordinary-model
/// producer. The tokenizer payload is reconstructed rather than trusted from a
/// sidecar and every stored root must match it.
pub fn validateSupportedPackageV1(
    package: package_manifest.ManifestV1,
) !tokenizer.Utf8ByteManifestV1 {
    try package_manifest.validateV1(package);
    if (package.family != .autoregressive or
        package.source_format != .safetensors or
        package.portable_format_abi != format.format_abi or
        package.conversion_profile_abi !=
            converter.conversion_profile_abi or
        package.conversion_plan_abi !=
            converter.conversion_plan_abi or
        package.tokenizer_manifest_abi !=
            tokenizer.utf8_byte_manifest_abi or
        package.tokenizer_manifest_bytes !=
            tokenizer.utf8_byte_manifest_bytes)
        return Error.UnsupportedPackageProfile;

    const expected_content = try package_manifest.modelContentRootV1(
        package.portable_artifact_sha256,
        package.config,
    );
    if (!digestEqual(
        expected_content,
        package.model_content_sha256,
    ))
        return Error.UnsupportedPackageProfile;

    const manifest = tokenizer.makeUtf8ByteManifestV1(
        package.config.vocab,
        tokenizer_max_input_bytes,
    ) catch return Error.UnsupportedPackageProfile;
    if (!digestEqual(
        manifest.config_sha256,
        package.tokenizer_config_sha256,
    ) or
        !digestEqual(
            manifest.domain_sha256,
            package.tokenizer_domain_sha256,
        ) or
        !digestEqual(
            manifest.behavior_sha256,
            package.tokenizer_behavior_sha256,
        ))
        return Error.UnsupportedPackageProfile;
    return manifest;
}

/// Derive, rather than accept, the representation identity for one loaded
/// prepared model and require its complete geometry and execution layout to
/// match the portable package.
pub fn preparedRepresentationForModelV1(
    package: package_manifest.ManifestV1,
    model: *const loader.LoadedModel,
) !package_manifest.PreparedRepresentationV1 {
    _ = try validateSupportedPackageV1(package);
    return derivePreparedRepresentationV1(package, model);
}

fn derivePreparedRepresentationV1(
    package: package_manifest.ManifestV1,
    model: *const loader.LoadedModel,
) !package_manifest.PreparedRepresentationV1 {
    const actual_config = try configFromLoadedModelV1(model.config);
    if (!std.meta.eql(package.config, actual_config) or
        model.prepared_mlp_layout != .separate)
        return Error.PreparedIdentityMismatch;
    const image = model.prepared_image orelse
        return Error.PreparedIdentityMismatch;
    if (image.header.version != .v2)
        return Error.UnsupportedPackageProfile;
    const identity = model.prepared_image_identity_cache orelse
        image.identityV1();
    if (!digestEqual(
        identity.source_fingerprint,
        package.model_content_sha256,
    ))
        return Error.PreparedIdentityMismatch;
    return package_manifest.makePreparedRepresentationV1(
        package,
        runtime_image.formatAbiForVersion(image.header.version),
        @intFromEnum(image.header.version),
        identity,
    );
}

pub fn produceSafetensorsV1(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    portable_path: []const u8,
    prepared_path: []const u8,
    package_path: []const u8,
    license_path: []const u8,
    options: OptionsV1,
) !ReceiptV1 {
    if (!options.conversion.quantize_int4)
        return Error.UnsupportedPackageProfile;
    try rejectOutputAliasesV1(
        allocator,
        source_path,
        license_path,
        options.config_path,
        portable_path,
        prepared_path,
        package_path,
    );

    const license_bytes = try bounded_input.readAllocV1(
        allocator,
        license_path,
        maximum_license_bytes,
    );
    defer allocator.free(license_bytes);
    if (license_bytes.len == 0)
        return Error.InvalidLicense;
    const license_byte_count = std.math.cast(
        u64,
        license_bytes.len,
    ) orelse return Error.InvalidLicense;
    const license_sha256 = sha256(license_bytes);

    var config_bytes: ?[]u8 = null;
    defer if (config_bytes) |bytes| allocator.free(bytes);
    var config_override: config.ModelConfigOverride = .{};
    if (options.config_path) |config_path| {
        const admitted = try bounded_input.readAllocV1(
            allocator,
            config_path,
            maximum_config_bytes,
        );
        config_bytes = admitted;
        config_override = try parseConfigOverrideV1(
            allocator,
            admitted,
        );
    }
    const config_input_identity: ?ConfigInputIdentityV1 =
        if (config_bytes) |bytes|
            .{
                .bytes = std.math.cast(u64, bytes.len) orelse
                    return Error.InvalidConfigInput,
                .sha256 = sha256(bytes),
            }
        else
            null;

    const conversion = try converter_durable
        .convertSafetensorsDurableV1(
        allocator,
        source_path,
        portable_path,
        options.conversion,
        null,
    );

    var portable = try format.FileReader.open(
        allocator,
        portable_path,
    );
    defer portable.close();
    var stream_buffer: [format.STREAM_BUFFER_SIZE]u8 = undefined;
    try portable.validateAllPageCrcsWithBufferV1(&stream_buffer);
    const portable_identity =
        try portable.containerIdentityWithBufferV1(&stream_buffer);
    if (portable_identity.container_bytes !=
        conversion.artifact_identity.container_bytes or
        portable.header.num_pages !=
            conversion.artifact_identity.page_count or
        !digestEqual(
            portable_identity.container_sha256,
            conversion.artifact_identity.container_sha256,
        ) or
        conversion.conversion.output_bytes !=
            conversion.artifact_identity.container_bytes or
        conversion.conversion.num_pages !=
            conversion.artifact_identity.page_count or
        !digestEqual(
            conversion.conversion.output_sha256,
            conversion.artifact_identity.container_sha256,
        ))
        return Error.ArtifactIdentityMismatch;

    var model = try loader.loadWithOptions(
        allocator,
        &portable,
        config_override,
        .{
            .compact_int4 = true,
            .int8_mlp_cache = false,
            .fp16_scale_cache = true,
        },
    );
    defer model.deinit();
    const package_config = try configFromLoadedModelV1(model.config);
    const model_content_sha256 =
        try package_manifest.modelContentRootV1(
            portable_identity.container_sha256,
            package_config,
        );
    const tokenizer_manifest =
        try tokenizer.makeUtf8ByteManifestV1(
            package_config.vocab,
            tokenizer_max_input_bytes,
        );
    const package = try package_manifest.makeV1(.{
        .family = .autoregressive,
        .source_format = .safetensors,
        .portable_format_abi = format.format_abi,
        .conversion_profile_abi = converter.conversion_profile_abi,
        .conversion_plan_abi = converter.conversion_plan_abi,
        .tokenizer_manifest_abi = tokenizer.utf8_byte_manifest_abi,
        .tokenizer_manifest_bytes = tokenizer.utf8_byte_manifest_bytes,
        .source_bytes = conversion.source_identity.source_bytes,
        .portable_bytes = conversion.artifact_identity.container_bytes,
        .portable_page_count = conversion.artifact_identity.page_count,
        .license_bytes = license_byte_count,
        .config = package_config,
        .source_sha256 = conversion.source_identity.source_sha256,
        .portable_artifact_sha256 = conversion.artifact_identity.container_sha256,
        .conversion_profile_sha256 = conversion.conversion.conversion_profile_sha256,
        .conversion_plan_sha256 = conversion.conversion.conversion_plan_sha256,
        .model_content_sha256 = model_content_sha256,
        .tokenizer_config_sha256 = tokenizer_manifest.config_sha256,
        .tokenizer_domain_sha256 = tokenizer_manifest.domain_sha256,
        .tokenizer_behavior_sha256 = tokenizer_manifest.behavior_sha256,
        .license_sha256 = license_sha256,
    });
    _ = try validateSupportedPackageV1(package);

    const prepare_stats =
        try loader.writePreparedWithOptionsAndStats(
            allocator,
            &model,
            prepared_path,
            model_content_sha256,
            .{ .mlp_layout = .separate },
        );

    var prepared_model = try loader.loadPreparedWithOptions(
        allocator,
        prepared_path,
        .{
            .expected_source_fingerprint = model_content_sha256,
            .mlp_layout = .separate_required,
        },
    );
    defer prepared_model.deinit();
    const prepared_identity =
        try prepared_model.preparedImageIdentityV1();
    const representation = try preparedRepresentationForModelV1(
        package,
        &prepared_model,
    );

    try revalidatePortablePathV1(
        allocator,
        portable_path,
        conversion.artifact_identity,
    );
    const license_after = try bounded_input.readAllocV1(
        allocator,
        license_path,
        maximum_license_bytes,
    );
    defer allocator.free(license_after);
    if (!std.mem.eql(u8, license_bytes, license_after))
        return bounded_input.Error.InputChanged;
    if (options.config_path) |config_path| {
        const config_after = try bounded_input.readAllocV1(
            allocator,
            config_path,
            maximum_config_bytes,
        );
        defer allocator.free(config_after);
        if (!std.mem.eql(
            u8,
            config_bytes orelse return Error.InvalidConfigInput,
            config_after,
        ))
            return bounded_input.Error.InputChanged;
    }

    var package_wire: [package_manifest.admission_bundle_bytes]u8 =
        undefined;
    _ = try package_manifest.encodeAdmissionBundleV1(
        package,
        representation,
        &package_wire,
    );
    const package_disposition = try publishPackageV1(
        package_path,
        &package_wire,
    );

    return .{
        .conversion_disposition = conversion.disposition,
        .package_disposition = package_disposition,
        .source_identity = conversion.source_identity,
        .portable_identity = conversion.artifact_identity,
        .conversion_profile_sha256 = conversion.conversion.conversion_profile_sha256,
        .conversion_plan_sha256 = conversion.conversion.conversion_plan_sha256,
        .package = package,
        .representation = representation,
        .tokenizer_manifest = tokenizer_manifest,
        .prepared_identity = prepared_identity,
        .prepare_stats = prepare_stats,
        .config_source = if (options.config_path == null)
            .derived
        else
            .explicit,
        .config_input_identity = config_input_identity,
    };
}

fn revalidatePortablePathV1(
    allocator: std.mem.Allocator,
    portable_path: []const u8,
    expected: converter_durable.ArtifactIdentityV1,
) !void {
    var portable = try format.FileReader.open(
        allocator,
        portable_path,
    );
    defer portable.close();
    var stream_buffer: [format.STREAM_BUFFER_SIZE]u8 = undefined;
    try portable.validateAllPageCrcsWithBufferV1(&stream_buffer);
    const identity =
        try portable.containerIdentityWithBufferV1(&stream_buffer);
    if (identity.container_bytes != expected.container_bytes or
        portable.header.num_pages != expected.page_count or
        !digestEqual(
            identity.container_sha256,
            expected.container_sha256,
        ))
        return Error.ArtifactIdentityMismatch;
}

fn publishPackageV1(
    path: []const u8,
    wire: *const [package_manifest.admission_bundle_bytes]u8,
) !PackageDispositionV1 {
    if (path.len == 0 or
        std.fs.path.isSep(path[path.len - 1]))
        return Error.InvalidOutputPath;
    if (comptime !bounded_input.availableV1())
        return error.UnsupportedPlatform;

    const parent_path = std.fs.path.dirname(path) orelse ".";
    const target_name = std.fs.path.basename(path);
    if (target_name.len == 0 or
        std.mem.eql(u8, target_name, ".") or
        std.mem.eql(u8, target_name, "..") or
        std.mem.eql(u8, target_name, publication_lock_name))
        return Error.InvalidOutputPath;

    var anchor = if (std.fs.path.isAbsolute(parent_path))
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
    defer anchor.close();
    var authority = try durable_directory.AuthorityV1.acquire(anchor);
    defer authority.close();
    const directory = try authority.borrow();

    var lock = try acquirePackagePublicationLockV1(directory);
    defer lock.file.close();
    if (lock.created) {
        try lock.file.sync();
        try authority.commit();
    }
    try verifyPackagePublicationLockV1(directory, lock);

    if (try existingPackageDispositionV1(
        directory,
        target_name,
        wire,
    )) |disposition|
        return disposition;

    var write_buffer: [4096]u8 = undefined;
    var atomic = try directory.atomicFile(target_name, .{
        .mode = 0o600,
        .write_buffer = &write_buffer,
    });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(wire);
    try atomic.file_writer.interface.flush();
    try atomic.file_writer.file.sync();
    const candidate_stat = try atomic.file_writer.file.stat();
    if (candidate_stat.kind != .file or
        candidate_stat.size !=
            package_manifest.admission_bundle_bytes)
        return Error.PackageConflict;

    try verifyPackagePublicationLockV1(directory, lock);
    if (try existingPackageDispositionV1(
        directory,
        target_name,
        wire,
    )) |disposition|
        return disposition;

    try atomic.renameIntoPlace();
    const published = (try existingPackageDispositionV1(
        directory,
        target_name,
        wire,
    )) orelse return Error.PackageConflict;
    if (published != .already_current)
        return Error.PackageConflict;
    try authority.commit();
    return .published;
}

const PackagePublicationFileViewV1 = struct {
    device: u64,
    inode: u64,
    size: u64,
    link_count: u64,
    mode: u32,
};

const PackagePublicationLockV1 = struct {
    file: std.fs.File,
    created: bool,
    view: PackagePublicationFileViewV1,
};

fn openPackagePublicationFileV1(
    directory: std.fs.Dir,
    name: []const u8,
    create: bool,
    read_write: bool,
) !std.fs.File {
    if (!@hasField(std.posix.O, "CLOEXEC") or
        !@hasField(std.posix.O, "NOFOLLOW") or
        !@hasField(std.posix.O, "NONBLOCK"))
        return error.UnsupportedPlatform;
    var flags: std.posix.O = .{
        .ACCMODE = if (read_write) .RDWR else .RDONLY,
    };
    flags.CLOEXEC = true;
    flags.NOFOLLOW = true;
    flags.NONBLOCK = true;
    if (@hasField(std.posix.O, "NOCTTY"))
        flags.NOCTTY = true;
    if (create) {
        flags.CREAT = true;
        flags.EXCL = true;
    }
    const descriptor = try std.posix.openat(
        directory.fd,
        name,
        flags,
        if (create) 0o600 else 0,
    );
    return .{ .handle = descriptor };
}

fn packagePublicationViewFromStatV1(
    stat: std.posix.Stat,
) !PackagePublicationFileViewV1 {
    return .{
        .device = std.math.cast(u64, stat.dev) orelse
            return Error.PackageConflict,
        .inode = std.math.cast(u64, stat.ino) orelse
            return Error.PackageConflict,
        .size = std.math.cast(u64, stat.size) orelse
            return Error.PackageConflict,
        .link_count = std.math.cast(u64, stat.nlink) orelse
            return Error.PackageConflict,
        .mode = std.math.cast(u32, stat.mode) orelse
            return Error.PackageConflict,
    };
}

fn inspectPackagePublicationFileV1(
    file: std.fs.File,
    directory: std.fs.Dir,
    name: []const u8,
    private: bool,
) !PackagePublicationFileViewV1 {
    const descriptor = try packagePublicationViewFromStatV1(
        try std.posix.fstat(file.handle),
    );
    const entry = try packagePublicationViewFromStatV1(
        try std.posix.fstatat(
            directory.fd,
            name,
            std.posix.AT.SYMLINK_NOFOLLOW,
        ),
    );
    if (!std.meta.eql(descriptor, entry) or
        (descriptor.mode & std.posix.S.IFMT) !=
            std.posix.S.IFREG or
        descriptor.link_count != 1 or
        (private and (descriptor.mode & 0o077) != 0) or
        (!private and (descriptor.mode & 0o022) != 0))
        return Error.PackageConflict;
    return descriptor;
}

fn acquirePackagePublicationLockV1(
    directory: std.fs.Dir,
) !PackagePublicationLockV1 {
    var created = true;
    const file = openPackagePublicationFileV1(
        directory,
        publication_lock_name,
        true,
        true,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => existing: {
            created = false;
            break :existing openPackagePublicationFileV1(
                directory,
                publication_lock_name,
                false,
                true,
            ) catch return Error.PackageConflict;
        },
        else => return err,
    };
    errdefer file.close();
    const view = try inspectPackagePublicationFileV1(
        file,
        directory,
        publication_lock_name,
        true,
    );
    std.posix.flock(
        file.handle,
        std.posix.LOCK.EX | std.posix.LOCK.NB,
    ) catch |err| switch (err) {
        error.WouldBlock => return Error.PublicationBusy,
        else => return err,
    };
    return .{
        .file = file,
        .created = created,
        .view = view,
    };
}

fn verifyPackagePublicationLockV1(
    directory: std.fs.Dir,
    lock: PackagePublicationLockV1,
) !void {
    const current = try inspectPackagePublicationFileV1(
        lock.file,
        directory,
        publication_lock_name,
        true,
    );
    if (!std.meta.eql(current, lock.view))
        return Error.PackageConflict;
}

fn existingPackageDispositionV1(
    directory: std.fs.Dir,
    target_name: []const u8,
    expected: *const [package_manifest.admission_bundle_bytes]u8,
) !?PackageDispositionV1 {
    const file = openPackagePublicationFileV1(
        directory,
        target_name,
        false,
        false,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return Error.PackageConflict,
    };
    defer file.close();
    const before = try inspectPackagePublicationFileV1(
        file,
        directory,
        target_name,
        false,
    );
    if (before.size != package_manifest.admission_bundle_bytes)
        return Error.PackageConflict;
    var encoded: [package_manifest.admission_bundle_bytes]u8 =
        undefined;
    if (try file.preadAll(&encoded, 0) != encoded.len)
        return Error.PackageConflict;
    const after = try inspectPackagePublicationFileV1(
        file,
        directory,
        target_name,
        false,
    );
    if (!std.meta.eql(before, after) or
        !std.mem.eql(u8, &encoded, expected))
        return Error.PackageConflict;
    _ = package_manifest.decodeAdmissionBundleV1(&encoded) catch
        return Error.PackageConflict;
    return .already_current;
}

fn rejectOutputAliasesV1(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    license_path: []const u8,
    config_path: ?[]const u8,
    portable_path: []const u8,
    prepared_path: []const u8,
    package_path: []const u8,
) !void {
    const inputs = [_][]const u8{
        source_path,
        license_path,
    };
    const outputs = [_][]const u8{
        portable_path,
        prepared_path,
        package_path,
    };
    for (outputs, 0..) |output, output_index| {
        for (inputs) |input| {
            if (try pathsAliasV1(allocator, output, input))
                return Error.OutputAlias;
        }
        if (config_path) |input| {
            if (try pathsAliasV1(allocator, output, input))
                return Error.OutputAlias;
        }
        for (outputs[0..output_index]) |other| {
            if (try pathsAliasV1(allocator, output, other))
                return Error.OutputAlias;
        }
    }
}

fn parseConfigOverrideV1(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !config.ModelConfigOverride {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        bytes,
        .{ .duplicate_field_behavior = .@"error" },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Error.InvalidConfigInput,
    };
    if (parsed != .object)
        return Error.InvalidConfigInput;

    const object = parsed.object;
    var recognized_fields: usize = 0;
    var result: config.ModelConfigOverride = .{};
    result.dim = try optionalAliasedPositiveUsizeV1(
        object,
        "dim",
        "hidden_size",
        &recognized_fields,
    );
    result.hidden_dim = try optionalAliasedPositiveUsizeV1(
        object,
        "hidden_dim",
        "intermediate_size",
        &recognized_fields,
    );
    result.num_layers = try optionalAliasedPositiveUsizeV1(
        object,
        "num_layers",
        "num_hidden_layers",
        &recognized_fields,
    );
    result.vocab_size = try optionalPositiveUsizeV1(
        object,
        "vocab_size",
        &recognized_fields,
    );
    result.num_heads = try optionalAliasedPositiveUsizeV1(
        object,
        "num_heads",
        "num_attention_heads",
        &recognized_fields,
    );
    result.head_dim = try optionalPositiveUsizeV1(
        object,
        "head_dim",
        &recognized_fields,
    );
    result.num_kv_heads = try optionalAliasedPositiveUsizeV1(
        object,
        "num_kv_heads",
        "num_key_value_heads",
        &recognized_fields,
    );
    result.rms_eps = try optionalAliasedPositiveF32V1(
        object,
        "rms_eps",
        "rms_norm_eps",
        &recognized_fields,
    );
    result.rope_theta = try optionalPositiveF32V1(
        object,
        "rope_theta",
        &recognized_fields,
    );
    result.tie_word_embeddings = try optionalBoolV1(
        object,
        "tie_word_embeddings",
        &recognized_fields,
    );
    if (recognized_fields == 0)
        return Error.InvalidConfigInput;
    if (result.dim == null or
        result.hidden_dim == null or
        result.num_layers == null or
        result.vocab_size == null or
        result.num_heads == null or
        result.num_kv_heads == null or
        result.rms_eps == null or
        result.rope_theta == null or
        result.tie_word_embeddings == null)
        return Error.InvalidConfigInput;

    const dim = result.dim.?;
    const heads = result.num_heads.?;
    if (result.head_dim == null) {
        if (dim % heads != 0)
            return Error.InvalidConfigInput;
        result.head_dim = dim / heads;
    } else {
        const represented = std.math.mul(
            usize,
            heads,
            result.head_dim.?,
        ) catch return Error.InvalidConfigInput;
        if (represented != dim)
            return Error.InvalidConfigInput;
    }
    const kv_heads = result.num_kv_heads.?;
    if (kv_heads > heads or heads % kv_heads != 0)
        return Error.InvalidConfigInput;
    return result;
}

fn optionalAliasedPositiveUsizeV1(
    object: std.json.ObjectMap,
    canonical_name: []const u8,
    alias_name: []const u8,
    recognized_fields: *usize,
) Error!?usize {
    const canonical = try optionalPositiveUsizeV1(
        object,
        canonical_name,
        recognized_fields,
    );
    const alias = try optionalPositiveUsizeV1(
        object,
        alias_name,
        recognized_fields,
    );
    if (canonical != null and alias != null and
        canonical.? != alias.?)
        return Error.InvalidConfigInput;
    return canonical orelse alias;
}

fn optionalPositiveUsizeV1(
    object: std.json.ObjectMap,
    name: []const u8,
    recognized_fields: *usize,
) Error!?usize {
    const value = object.get(name) orelse return null;
    recognized_fields.* += 1;
    if (value != .integer or value.integer <= 0 or
        value.integer > @as(i64, std.math.maxInt(u32)))
        return Error.InvalidConfigInput;
    return std.math.cast(usize, value.integer) orelse
        Error.InvalidConfigInput;
}

fn optionalAliasedPositiveF32V1(
    object: std.json.ObjectMap,
    canonical_name: []const u8,
    alias_name: []const u8,
    recognized_fields: *usize,
) Error!?f32 {
    const canonical = try optionalPositiveF32V1(
        object,
        canonical_name,
        recognized_fields,
    );
    const alias = try optionalPositiveF32V1(
        object,
        alias_name,
        recognized_fields,
    );
    if (canonical != null and alias != null and
        canonical.? != alias.?)
        return Error.InvalidConfigInput;
    return canonical orelse alias;
}

fn optionalPositiveF32V1(
    object: std.json.ObjectMap,
    name: []const u8,
    recognized_fields: *usize,
) Error!?f32 {
    const value = object.get(name) orelse return null;
    recognized_fields.* += 1;
    const wide: f64 = switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return Error.InvalidConfigInput,
    };
    if (!std.math.isFinite(wide) or wide <= 0 or
        wide > std.math.floatMax(f32))
        return Error.InvalidConfigInput;
    const narrowed: f32 = @floatCast(wide);
    if (!std.math.isFinite(narrowed) or narrowed <= 0)
        return Error.InvalidConfigInput;
    return narrowed;
}

fn optionalBoolV1(
    object: std.json.ObjectMap,
    name: []const u8,
    recognized_fields: *usize,
) Error!?bool {
    const value = object.get(name) orelse return null;
    recognized_fields.* += 1;
    if (value != .bool)
        return Error.InvalidConfigInput;
    return value.bool;
}

fn pathsAliasV1(
    allocator: std.mem.Allocator,
    left: []const u8,
    right: []const u8,
) !bool {
    const left_resolved = try resolvedPathV1(allocator, left);
    defer allocator.free(left_resolved);
    const right_resolved = try resolvedPathV1(allocator, right);
    defer allocator.free(right_resolved);
    if (std.mem.eql(u8, left_resolved, right_resolved))
        return true;

    const left_stat = std.fs.cwd().statFile(left) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const right_stat = std.fs.cwd().statFile(right) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return left_stat.kind == .file and
        right_stat.kind == .file and
        left_stat.inode == right_stat.inode;
}

fn resolvedPathV1(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    if (path.len == 0)
        return Error.InvalidOutputPath;
    return std.fs.cwd().realpathAlloc(
        allocator,
        path,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            const parent_path =
                std.fs.path.dirname(path) orelse ".";
            const parent = try std.fs.cwd().realpathAlloc(
                allocator,
                parent_path,
            );
            defer allocator.free(parent);
            return std.fs.path.join(
                allocator,
                &.{ parent, std.fs.path.basename(path) },
            );
        },
        else => return err,
    };
}

fn sha256(bytes: []const u8) package_manifest.Digest {
    var digest: package_manifest.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn digestEqual(
    left: package_manifest.Digest,
    right: package_manifest.Digest,
) bool {
    return std.mem.eql(u8, &left, &right);
}
