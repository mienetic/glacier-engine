//! Stable, request-independent model package identity.
//!
//! `ManifestV2` binds portable model provenance, an explicit model profile,
//! the admitted tensor-profile inventory, resolved model geometry, tokenizer
//! behavior, and the license byte count plus SHA-256 identity. It deliberately
//! excludes license payloads, prompts, request epochs, output limits, scheduler
//! identities, and native execution-image bytes, so the same package root can
//! be used across requests and operating-system/architecture-specific
//! preparations.
//!
//! `PreparedRepresentationV1` is the contextual bridge to one exact validated
//! `.glrt` representation. `AdmissionBundleV2` concatenates the stable
//! manifest and one representation receipt for fail-closed runtime admission;
//! another native representation can use another bundle without changing the
//! portable package root.

const std = @import("std");
const core = @import("core");
const model_contract = core.model_contract;
const runtime_image = @import("runtime_image.zig");

pub const Digest = [32]u8;

pub const manifest_abi: u64 = 0x474c_504b_0000_0002;
pub const config_abi: u64 = 0x474c_5043_0000_0001;
pub const prepared_representation_abi: u64 =
    0x474c_5052_0000_0001;
pub const manifest_bytes: usize = 640;
pub const manifest_body_bytes: usize = manifest_bytes - 32;
pub const prepared_representation_bytes: usize = 256;
pub const prepared_representation_body_bytes: usize =
    prepared_representation_bytes - 32;
pub const admission_bundle_bytes: usize =
    manifest_bytes + prepared_representation_bytes;
pub const manifest_flag_model_profile: u64 = 1 << 0;
pub const manifest_allowed_flags: u64 =
    manifest_flag_model_profile;
pub const prepared_representation_allowed_flags: u64 = 0;
pub const model_profile_abi: u64 =
    0x474c_4d50_0000_0001;

pub const manifest_magic =
    [_]u8{ 'G', 'L', 'P', 'K', 'G', '0', '2', 0 };
pub const prepared_representation_magic =
    [_]u8{ 'G', 'L', 'P', 'R', 'E', 'P', '1', 0 };

const manifest_domain =
    "glacier-model-package-manifest-v2\x00";
const config_domain =
    "glacier-model-package-config-v1\x00";
const prepared_representation_domain =
    "glacier-model-prepared-representation-v1\x00";
const model_content_domain =
    "glacier-prepared-provenance-v1\x00";
const profiled_model_content_domain =
    "glacier-model-package-profiled-content-v1\x00";
const model_profile_domain =
    "glacier-model-package-profile-v1\x00";

pub const Error = error{
    InvalidLength,
    InvalidManifest,
    InvalidConfig,
    InvalidPreparedRepresentation,
    UnsafeDestination,
};

pub const SourceFormatV1 = enum(u64) {
    safetensors = 1,
    gguf = 2,
    onnx = 3,
    other = 255,
};

pub const ModelProfileV1 = enum(u64) {
    ordinary_package_v1 = 1,
    _,
};

/// Canonical, architecture-independent resolved model geometry.
pub const ConfigV1 = struct {
    dim: u32,
    hidden_dim: u32,
    layers: u32,
    vocab: u32,
    heads: u32,
    head_dim: u32,
    kv_heads: u32,
    rms_eps: f32,
    rope_theta: f32,
    tie_embeddings: bool,
};

pub const InputV2 = struct {
    family: model_contract.ModelFamilyIdV1,
    source_format: SourceFormatV1,
    portable_format_abi: u64,
    conversion_profile_abi: u64,
    conversion_plan_abi: u64,
    tokenizer_manifest_abi: u64,
    tokenizer_manifest_bytes: u64,
    source_bytes: u64,
    portable_bytes: u64,
    portable_page_count: u64,
    license_bytes: u64,
    model_profile_id: ModelProfileV1,
    tensor_profile_abi: u64,
    tensor_count: u64,
    tensor_inventory_sha256: Digest,
    config: ConfigV1,
    source_sha256: Digest,
    portable_artifact_sha256: Digest,
    conversion_profile_sha256: Digest,
    conversion_plan_sha256: Digest,
    model_content_sha256: Digest,
    tokenizer_config_sha256: Digest,
    tokenizer_domain_sha256: Digest,
    tokenizer_behavior_sha256: Digest,
    license_sha256: Digest,
};

/// Deprecated source alias retained while internal archive APIs migrate. Both
/// names encode only the V2 wire and reject legacy V1 bytes.
pub const InputV1 = InputV2;

pub const ManifestV2 = struct {
    abi_version: u64 = manifest_abi,
    family: model_contract.ModelFamilyIdV1,
    source_format: SourceFormatV1,
    portable_format_abi: u64,
    conversion_profile_abi: u64,
    conversion_plan_abi: u64,
    tokenizer_manifest_abi: u64,
    tokenizer_manifest_bytes: u64,
    source_bytes: u64,
    portable_bytes: u64,
    portable_page_count: u64,
    license_bytes: u64,
    model_profile_abi: u64,
    model_profile_id: ModelProfileV1,
    model_profile_sha256: Digest,
    tensor_profile_abi: u64,
    tensor_count: u64,
    tensor_inventory_sha256: Digest,
    config: ConfigV1,
    source_sha256: Digest,
    portable_artifact_sha256: Digest,
    conversion_profile_sha256: Digest,
    conversion_plan_sha256: Digest,
    resolved_config_sha256: Digest,
    model_content_sha256: Digest,
    tokenizer_config_sha256: Digest,
    tokenizer_domain_sha256: Digest,
    tokenizer_behavior_sha256: Digest,
    license_sha256: Digest,
    package_sha256: Digest,
};

/// Deprecated source alias; this is not a V1 wire decoder.
pub const ManifestV1 = ManifestV2;

pub const PreparedRepresentationV1 = struct {
    abi_version: u64 = prepared_representation_abi,
    format_abi: u64,
    format_version: u64,
    container_bytes: u64,
    package_sha256: Digest,
    resolved_config_sha256: Digest,
    source_fingerprint: Digest,
    abi_fingerprint: Digest,
    container_sha256: Digest,
    representation_sha256: Digest,
};

pub const AdmissionBundleV2 = struct {
    package: ManifestV2,
    representation: PreparedRepresentationV1,
};

/// Deprecated source alias; this is not a V1 wire decoder.
pub const AdmissionBundleV1 = AdmissionBundleV2;

pub const ProfiledModelContentInputV1 = struct {
    family: model_contract.ModelFamilyIdV1,
    source_format: SourceFormatV1,
    portable_format_abi: u64,
    conversion_profile_abi: u64,
    conversion_plan_abi: u64,
    model_profile_id: ModelProfileV1,
    tensor_profile_abi: u64,
    tensor_count: u64,
    config: ConfigV1,
    portable_artifact_sha256: Digest,
    conversion_profile_sha256: Digest,
    conversion_plan_sha256: Digest,
    tensor_inventory_sha256: Digest,
};

pub fn makeV1(input: InputV1) Error!ManifestV1 {
    try validateConfigV1(input.config);
    var value: ManifestV1 = .{
        .family = input.family,
        .source_format = input.source_format,
        .portable_format_abi = input.portable_format_abi,
        .conversion_profile_abi = input.conversion_profile_abi,
        .conversion_plan_abi = input.conversion_plan_abi,
        .tokenizer_manifest_abi = input.tokenizer_manifest_abi,
        .tokenizer_manifest_bytes = input.tokenizer_manifest_bytes,
        .source_bytes = input.source_bytes,
        .portable_bytes = input.portable_bytes,
        .portable_page_count = input.portable_page_count,
        .license_bytes = input.license_bytes,
        .model_profile_abi = model_profile_abi,
        .model_profile_id = input.model_profile_id,
        .model_profile_sha256 = modelProfileRootV1(input.model_profile_id),
        .tensor_profile_abi = input.tensor_profile_abi,
        .tensor_count = input.tensor_count,
        .tensor_inventory_sha256 = input.tensor_inventory_sha256,
        .config = input.config,
        .source_sha256 = input.source_sha256,
        .portable_artifact_sha256 = input.portable_artifact_sha256,
        .conversion_profile_sha256 = input.conversion_profile_sha256,
        .conversion_plan_sha256 = input.conversion_plan_sha256,
        .resolved_config_sha256 = resolvedConfigRootV1(input.config),
        .model_content_sha256 = input.model_content_sha256,
        .tokenizer_config_sha256 = input.tokenizer_config_sha256,
        .tokenizer_domain_sha256 = input.tokenizer_domain_sha256,
        .tokenizer_behavior_sha256 = input.tokenizer_behavior_sha256,
        .license_sha256 = input.license_sha256,
        .package_sha256 = undefined,
    };
    if (!manifestShapeValidV1(value))
        return Error.InvalidManifest;
    var body: [manifest_body_bytes]u8 = undefined;
    writeManifestBodyV1(value, &body);
    value.package_sha256 = manifestRootV1(&body);
    try validateV1(value);
    return value;
}

pub fn validateV1(value: ManifestV1) Error!void {
    if (!manifestShapeValidV1(value))
        return Error.InvalidManifest;
    var body: [manifest_body_bytes]u8 = undefined;
    writeManifestBodyV1(value, &body);
    if (!digestEqual(
        value.package_sha256,
        manifestRootV1(&body),
    ))
        return Error.InvalidManifest;
}

pub fn encodeV1(
    value: ManifestV1,
    destination: []u8,
) Error![]u8 {
    if (destination.len != manifest_bytes)
        return Error.InvalidLength;
    try validateV1(value);
    var local: [manifest_bytes]u8 = undefined;
    writeManifestBodyV1(
        value,
        local[0..manifest_body_bytes],
    );
    @memcpy(
        local[manifest_body_bytes..],
        &value.package_sha256,
    );
    if (slicesOverlap(destination, &local))
        return Error.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

pub fn decodeV1(encoded: []const u8) Error!ManifestV1 {
    if (encoded.len != manifest_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(u8, encoded[0..8], &manifest_magic) or
        readU64(encoded, 8) != manifest_abi or
        readU64(encoded, 16) != manifest_bytes or
        readU64(encoded, 24) != manifest_allowed_flags or
        readU64(encoded, 120) != config_abi or
        readU32(encoded, 168) != 0 or
        readU32(encoded, 172) != 0 or
        !allZero(encoded[592..manifest_body_bytes]))
        return Error.InvalidManifest;
    const family = std.meta.intToEnum(
        model_contract.ModelFamilyIdV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidManifest;
    const source_format = std.meta.intToEnum(
        SourceFormatV1,
        readU64(encoded, 40),
    ) catch return Error.InvalidManifest;
    const model_profile_id: ModelProfileV1 =
        @enumFromInt(readU64(encoded, 504));
    const config: ConfigV1 = .{
        .dim = readU32(encoded, 128),
        .hidden_dim = readU32(encoded, 132),
        .layers = readU32(encoded, 136),
        .vocab = readU32(encoded, 140),
        .heads = readU32(encoded, 144),
        .head_dim = readU32(encoded, 148),
        .kv_heads = readU32(encoded, 152),
        .tie_embeddings = switch (readU32(encoded, 156)) {
            0 => false,
            1 => true,
            else => return Error.InvalidConfig,
        },
        .rms_eps = @bitCast(readU32(encoded, 160)),
        .rope_theta = @bitCast(readU32(encoded, 164)),
    };
    const value: ManifestV1 = .{
        .family = family,
        .source_format = source_format,
        .portable_format_abi = readU64(encoded, 48),
        .conversion_profile_abi = readU64(encoded, 56),
        .conversion_plan_abi = readU64(encoded, 64),
        .tokenizer_manifest_abi = readU64(encoded, 72),
        .tokenizer_manifest_bytes = readU64(encoded, 80),
        .source_bytes = readU64(encoded, 88),
        .portable_bytes = readU64(encoded, 96),
        .portable_page_count = readU64(encoded, 104),
        .license_bytes = readU64(encoded, 112),
        .model_profile_abi = readU64(encoded, 496),
        .model_profile_id = model_profile_id,
        .model_profile_sha256 = encoded[512..544].*,
        .tensor_profile_abi = readU64(encoded, 544),
        .tensor_count = readU64(encoded, 552),
        .tensor_inventory_sha256 = encoded[560..592].*,
        .config = config,
        .source_sha256 = encoded[176..208].*,
        .portable_artifact_sha256 = encoded[208..240].*,
        .conversion_profile_sha256 = encoded[240..272].*,
        .conversion_plan_sha256 = encoded[272..304].*,
        .resolved_config_sha256 = encoded[304..336].*,
        .model_content_sha256 = encoded[336..368].*,
        .tokenizer_config_sha256 = encoded[368..400].*,
        .tokenizer_domain_sha256 = encoded[400..432].*,
        .tokenizer_behavior_sha256 = encoded[432..464].*,
        .license_sha256 = encoded[464..496].*,
        .package_sha256 = encoded[manifest_body_bytes..][0..32].*,
    };
    try validateV1(value);
    return value;
}

pub fn makeV2(input: InputV2) Error!ManifestV2 {
    return makeV1(input);
}

pub fn validateV2(value: ManifestV2) Error!void {
    return validateV1(value);
}

pub fn encodeV2(
    value: ManifestV2,
    destination: []u8,
) Error![]u8 {
    return encodeV1(value, destination);
}

pub fn decodeV2(encoded: []const u8) Error!ManifestV2 {
    return decodeV1(encoded);
}

pub fn modelProfileRootV1(
    profile: ModelProfileV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(model_profile_domain);
    hashU64(&hash, model_profile_abi);
    hashU64(&hash, @intFromEnum(profile));
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn resolvedConfigRootV1(config: ConfigV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(config_domain);
    hashU64(&hash, config_abi);
    hashU32(&hash, config.dim);
    hashU32(&hash, config.hidden_dim);
    hashU32(&hash, config.layers);
    hashU32(&hash, config.vocab);
    hashU32(&hash, config.heads);
    hashU32(&hash, config.head_dim);
    hashU32(&hash, config.kv_heads);
    hashU32(&hash, @intFromBool(config.tie_embeddings));
    hashU32(&hash, @bitCast(config.rms_eps));
    hashU32(&hash, @bitCast(config.rope_theta));
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Bind one portable artifact to the resolved geometry used by preparation.
///
/// The resulting platform-independent root is stored as the prepared image's
/// source fingerprint. Keeping the algorithm here lets preparation, package
/// production, and request admission share one exact identity rule.
pub fn modelContentRootV1(
    portable_artifact_sha256: Digest,
    config: ConfigV1,
) Error!Digest {
    try validateConfigV1(config);
    if (isZero(portable_artifact_sha256))
        return Error.InvalidManifest;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(model_content_domain);
    hash.update(&portable_artifact_sha256);
    hashU64(&hash, config.dim);
    hashU64(&hash, config.hidden_dim);
    hashU64(&hash, config.layers);
    hashU64(&hash, config.vocab);
    hashU64(&hash, config.heads);
    hashU64(&hash, config.head_dim);
    hashU64(&hash, config.kv_heads);
    hashU32(&hash, @bitCast(config.rms_eps));
    hashU32(&hash, @bitCast(config.rope_theta));
    const tie_embeddings = [_]u8{
        @intFromBool(config.tie_embeddings),
    };
    hash.update(&tie_embeddings);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Bind prepared model bytes to the exact package profile and source tensor
/// semantics that produced them. This prevents a structurally valid package
/// rewrite from relabeling an existing prepared image with another admitted
/// conversion or tensor profile.
pub fn profiledModelContentRootV1(
    input: ProfiledModelContentInputV1,
) Error!Digest {
    try validateConfigV1(input.config);
    if (@intFromEnum(input.family) == 0 or
        @intFromEnum(input.source_format) == 0 or
        input.portable_format_abi == 0 or
        input.conversion_profile_abi == 0 or
        input.conversion_plan_abi == 0 or
        @intFromEnum(input.model_profile_id) == 0 or
        input.tensor_profile_abi == 0 or
        input.tensor_count == 0 or
        isZero(input.portable_artifact_sha256) or
        isZero(input.conversion_profile_sha256) or
        isZero(input.conversion_plan_sha256) or
        isZero(input.tensor_inventory_sha256))
        return Error.InvalidManifest;

    const model_profile_sha256 =
        modelProfileRootV1(input.model_profile_id);
    const resolved_config_sha256 =
        resolvedConfigRootV1(input.config);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(profiled_model_content_domain);
    hashU64(&hash, @intFromEnum(input.family));
    hashU64(&hash, @intFromEnum(input.source_format));
    hashU64(&hash, input.portable_format_abi);
    hash.update(&input.portable_artifact_sha256);
    hashU64(&hash, input.conversion_profile_abi);
    hash.update(&input.conversion_profile_sha256);
    hashU64(&hash, input.conversion_plan_abi);
    hash.update(&input.conversion_plan_sha256);
    hashU64(&hash, model_profile_abi);
    hashU64(&hash, @intFromEnum(input.model_profile_id));
    hash.update(&model_profile_sha256);
    hashU64(&hash, input.tensor_profile_abi);
    hashU64(&hash, input.tensor_count);
    hash.update(&input.tensor_inventory_sha256);
    hash.update(&resolved_config_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn makePreparedRepresentationV1(
    package: ManifestV1,
    format_abi: u64,
    format_version: u64,
    identity: runtime_image.ImageIdentityV1,
) Error!PreparedRepresentationV1 {
    try validateV1(package);
    var value: PreparedRepresentationV1 = .{
        .format_abi = format_abi,
        .format_version = format_version,
        .container_bytes = identity.container_bytes,
        .package_sha256 = package.package_sha256,
        .resolved_config_sha256 = package.resolved_config_sha256,
        .source_fingerprint = identity.source_fingerprint,
        .abi_fingerprint = identity.abi_fingerprint,
        .container_sha256 = identity.container_sha256,
        .representation_sha256 = undefined,
    };
    if (!preparedRepresentationShapeValidV1(value) or
        !digestEqual(
            value.source_fingerprint,
            package.model_content_sha256,
        ))
        return Error.InvalidPreparedRepresentation;
    var body: [prepared_representation_body_bytes]u8 =
        undefined;
    writePreparedRepresentationBodyV1(value, &body);
    value.representation_sha256 =
        preparedRepresentationRootV1(&body);
    try validatePreparedRepresentationV1(package, value);
    return value;
}

pub fn validatePreparedRepresentationV1(
    package: ManifestV1,
    value: PreparedRepresentationV1,
) Error!void {
    try validateV1(package);
    if (!preparedRepresentationShapeValidV1(value) or
        !digestEqual(
            value.package_sha256,
            package.package_sha256,
        ) or !digestEqual(
        value.resolved_config_sha256,
        package.resolved_config_sha256,
    ) or !digestEqual(
        value.source_fingerprint,
        package.model_content_sha256,
    ))
        return Error.InvalidPreparedRepresentation;
    var body: [prepared_representation_body_bytes]u8 =
        undefined;
    writePreparedRepresentationBodyV1(value, &body);
    if (!digestEqual(
        value.representation_sha256,
        preparedRepresentationRootV1(&body),
    ))
        return Error.InvalidPreparedRepresentation;
}

pub fn encodePreparedRepresentationV1(
    value: PreparedRepresentationV1,
    destination: []u8,
) Error![]u8 {
    if (destination.len != prepared_representation_bytes)
        return Error.InvalidLength;
    if (!preparedRepresentationShapeValidV1(value))
        return Error.InvalidPreparedRepresentation;
    var body: [prepared_representation_body_bytes]u8 =
        undefined;
    writePreparedRepresentationBodyV1(value, &body);
    if (!digestEqual(
        value.representation_sha256,
        preparedRepresentationRootV1(&body),
    ))
        return Error.InvalidPreparedRepresentation;
    var local: [prepared_representation_bytes]u8 = undefined;
    @memcpy(
        local[0..prepared_representation_body_bytes],
        &body,
    );
    @memcpy(
        local[prepared_representation_body_bytes..],
        &value.representation_sha256,
    );
    if (slicesOverlap(destination, &local))
        return Error.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

pub fn decodePreparedRepresentationV1(
    encoded: []const u8,
) Error!PreparedRepresentationV1 {
    if (encoded.len != prepared_representation_bytes)
        return Error.InvalidLength;
    if (!std.mem.eql(
        u8,
        encoded[0..8],
        &prepared_representation_magic,
    ) or readU64(encoded, 8) !=
        prepared_representation_abi or
        readU64(encoded, 16) !=
            prepared_representation_bytes or
        readU64(encoded, 24) !=
            prepared_representation_allowed_flags or
        readU64(encoded, 56) != 0)
        return Error.InvalidPreparedRepresentation;
    const value: PreparedRepresentationV1 = .{
        .format_abi = readU64(encoded, 32),
        .format_version = readU64(encoded, 40),
        .container_bytes = readU64(encoded, 48),
        .package_sha256 = encoded[64..96].*,
        .resolved_config_sha256 = encoded[96..128].*,
        .source_fingerprint = encoded[128..160].*,
        .abi_fingerprint = encoded[160..192].*,
        .container_sha256 = encoded[192..224].*,
        .representation_sha256 = encoded[prepared_representation_body_bytes..][0..32].*,
    };
    if (!preparedRepresentationShapeValidV1(value) or
        !digestEqual(
            value.representation_sha256,
            preparedRepresentationRootV1(
                encoded[0..prepared_representation_body_bytes],
            ),
        ))
        return Error.InvalidPreparedRepresentation;
    return value;
}

/// Encode the portable package identity and one exact prepared representation
/// as the fixed `.glpkg` runtime-admission artifact.
pub fn encodeAdmissionBundleV1(
    package: ManifestV1,
    representation: PreparedRepresentationV1,
    destination: []u8,
) Error![]u8 {
    if (destination.len != admission_bundle_bytes)
        return Error.InvalidLength;
    try validatePreparedRepresentationV1(
        package,
        representation,
    );
    var local: [admission_bundle_bytes]u8 = undefined;
    _ = try encodeV1(
        package,
        local[0..manifest_bytes],
    );
    _ = try encodePreparedRepresentationV1(
        representation,
        local[manifest_bytes..],
    );
    if (slicesOverlap(destination, &local))
        return Error.UnsafeDestination;
    @memcpy(destination, &local);
    return destination;
}

/// Decode and authenticate both fixed components, then require the
/// representation receipt to name the exact package root and configuration.
pub fn decodeAdmissionBundleV1(
    encoded: []const u8,
) Error!AdmissionBundleV1 {
    if (encoded.len != admission_bundle_bytes)
        return Error.InvalidLength;
    const package = try decodeV1(
        encoded[0..manifest_bytes],
    );
    const representation =
        try decodePreparedRepresentationV1(
            encoded[manifest_bytes..],
        );
    try validatePreparedRepresentationV1(
        package,
        representation,
    );
    return .{
        .package = package,
        .representation = representation,
    };
}

pub fn encodeAdmissionBundleV2(
    package: ManifestV2,
    representation: PreparedRepresentationV1,
    destination: []u8,
) Error![]u8 {
    return encodeAdmissionBundleV1(
        package,
        representation,
        destination,
    );
}

pub fn decodeAdmissionBundleV2(
    encoded: []const u8,
) Error!AdmissionBundleV2 {
    return decodeAdmissionBundleV1(encoded);
}

fn validateConfigV1(config: ConfigV1) Error!void {
    if (config.dim == 0 or
        config.hidden_dim == 0 or
        config.layers == 0 or
        config.vocab == 0 or
        config.heads == 0 or
        config.head_dim == 0 or
        config.kv_heads == 0 or
        config.kv_heads > config.heads or
        config.heads % config.kv_heads != 0 or
        config.dim !=
            @as(u64, config.heads) * config.head_dim or
        !std.math.isFinite(config.rms_eps) or
        config.rms_eps <= 0 or
        !std.math.isFinite(config.rope_theta) or
        config.rope_theta <= 0)
        return Error.InvalidConfig;
}

fn manifestShapeValidV1(value: ManifestV1) bool {
    validateConfigV1(value.config) catch return false;
    return value.abi_version == manifest_abi and
        value.portable_format_abi != 0 and
        value.conversion_profile_abi != 0 and
        value.conversion_plan_abi != 0 and
        value.tokenizer_manifest_abi != 0 and
        value.tokenizer_manifest_bytes != 0 and
        value.source_bytes != 0 and
        value.portable_bytes != 0 and
        value.portable_page_count != 0 and
        value.license_bytes != 0 and
        value.model_profile_abi == model_profile_abi and
        @intFromEnum(value.model_profile_id) != 0 and
        digestEqual(
            value.model_profile_sha256,
            modelProfileRootV1(value.model_profile_id),
        ) and
        value.tensor_profile_abi != 0 and
        value.tensor_count != 0 and
        !isZero(value.tensor_inventory_sha256) and
        digestEqual(
            value.resolved_config_sha256,
            resolvedConfigRootV1(value.config),
        ) and
        !isZero(value.source_sha256) and
        !isZero(value.portable_artifact_sha256) and
        !isZero(value.conversion_profile_sha256) and
        !isZero(value.conversion_plan_sha256) and
        !isZero(value.model_content_sha256) and
        !isZero(value.tokenizer_config_sha256) and
        !isZero(value.tokenizer_domain_sha256) and
        !isZero(value.tokenizer_behavior_sha256) and
        !isZero(value.license_sha256);
}

fn preparedRepresentationShapeValidV1(
    value: PreparedRepresentationV1,
) bool {
    return value.abi_version ==
        prepared_representation_abi and
        value.format_abi != 0 and
        value.format_version != 0 and
        value.container_bytes != 0 and
        !isZero(value.package_sha256) and
        !isZero(value.resolved_config_sha256) and
        !isZero(value.source_fingerprint) and
        !isZero(value.abi_fingerprint) and
        !isZero(value.container_sha256);
}

fn writeManifestBodyV1(
    value: ManifestV1,
    destination: []u8,
) void {
    std.debug.assert(destination.len == manifest_body_bytes);
    @memset(destination, 0);
    @memcpy(destination[0..8], &manifest_magic);
    writeU64(destination, 8, manifest_abi);
    writeU64(destination, 16, manifest_bytes);
    writeU64(
        destination,
        24,
        manifest_allowed_flags,
    );
    writeU64(destination, 32, @intFromEnum(value.family));
    writeU64(
        destination,
        40,
        @intFromEnum(value.source_format),
    );
    writeU64(destination, 48, value.portable_format_abi);
    writeU64(destination, 56, value.conversion_profile_abi);
    writeU64(destination, 64, value.conversion_plan_abi);
    writeU64(destination, 72, value.tokenizer_manifest_abi);
    writeU64(destination, 80, value.tokenizer_manifest_bytes);
    writeU64(destination, 88, value.source_bytes);
    writeU64(destination, 96, value.portable_bytes);
    writeU64(destination, 104, value.portable_page_count);
    writeU64(destination, 112, value.license_bytes);
    writeU64(destination, 120, config_abi);
    writeU32(destination, 128, value.config.dim);
    writeU32(destination, 132, value.config.hidden_dim);
    writeU32(destination, 136, value.config.layers);
    writeU32(destination, 140, value.config.vocab);
    writeU32(destination, 144, value.config.heads);
    writeU32(destination, 148, value.config.head_dim);
    writeU32(destination, 152, value.config.kv_heads);
    writeU32(
        destination,
        156,
        @intFromBool(value.config.tie_embeddings),
    );
    writeU32(
        destination,
        160,
        @bitCast(value.config.rms_eps),
    );
    writeU32(
        destination,
        164,
        @bitCast(value.config.rope_theta),
    );
    @memcpy(destination[176..208], &value.source_sha256);
    @memcpy(
        destination[208..240],
        &value.portable_artifact_sha256,
    );
    @memcpy(
        destination[240..272],
        &value.conversion_profile_sha256,
    );
    @memcpy(
        destination[272..304],
        &value.conversion_plan_sha256,
    );
    @memcpy(
        destination[304..336],
        &value.resolved_config_sha256,
    );
    @memcpy(
        destination[336..368],
        &value.model_content_sha256,
    );
    @memcpy(
        destination[368..400],
        &value.tokenizer_config_sha256,
    );
    @memcpy(
        destination[400..432],
        &value.tokenizer_domain_sha256,
    );
    @memcpy(
        destination[432..464],
        &value.tokenizer_behavior_sha256,
    );
    @memcpy(destination[464..496], &value.license_sha256);
    writeU64(
        destination,
        496,
        value.model_profile_abi,
    );
    writeU64(
        destination,
        504,
        @intFromEnum(value.model_profile_id),
    );
    @memcpy(
        destination[512..544],
        &value.model_profile_sha256,
    );
    writeU64(
        destination,
        544,
        value.tensor_profile_abi,
    );
    writeU64(destination, 552, value.tensor_count);
    @memcpy(
        destination[560..592],
        &value.tensor_inventory_sha256,
    );
}

fn writePreparedRepresentationBodyV1(
    value: PreparedRepresentationV1,
    destination: []u8,
) void {
    std.debug.assert(
        destination.len == prepared_representation_body_bytes,
    );
    @memset(destination, 0);
    @memcpy(
        destination[0..8],
        &prepared_representation_magic,
    );
    writeU64(destination, 8, prepared_representation_abi);
    writeU64(
        destination,
        16,
        prepared_representation_bytes,
    );
    writeU64(
        destination,
        24,
        prepared_representation_allowed_flags,
    );
    writeU64(destination, 32, value.format_abi);
    writeU64(destination, 40, value.format_version);
    writeU64(destination, 48, value.container_bytes);
    @memcpy(destination[64..96], &value.package_sha256);
    @memcpy(
        destination[96..128],
        &value.resolved_config_sha256,
    );
    @memcpy(
        destination[128..160],
        &value.source_fingerprint,
    );
    @memcpy(
        destination[160..192],
        &value.abi_fingerprint,
    );
    @memcpy(destination[192..224], &value.container_sha256);
}

fn manifestRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(manifest_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn preparedRepresentationRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prepared_representation_domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn writeU32(
    destination: []u8,
    offset: usize,
    value: u32,
) void {
    std.mem.writeInt(
        u32,
        destination[offset..][0..4],
        value,
        .little,
    );
}

fn writeU64(
    destination: []u8,
    offset: usize,
    value: u64,
) void {
    std.mem.writeInt(
        u64,
        destination[offset..][0..8],
        value,
        .little,
    );
}

fn readU32(source: []const u8, offset: usize) u32 {
    return std.mem.readInt(
        u32,
        source[offset..][0..4],
        .little,
    );
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        source[offset..][0..8],
        .little,
    );
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
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = left_start + left.len;
    const right_end = right_start + right.len;
    return left_start < right_end and
        right_start < left_end;
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn testManifestV1() !ManifestV1 {
    return makeV1(.{
        .family = .autoregressive,
        .source_format = .safetensors,
        .portable_format_abi = 0x474c_4143_0000_0001,
        .conversion_profile_abi = 0x474c_4350_0000_0001,
        .conversion_plan_abi = 0x474c_434e_0000_0001,
        .tokenizer_manifest_abi = 0x4754_4f4b_0000_0001,
        .tokenizer_manifest_bytes = 192,
        .source_bytes = 1000,
        .portable_bytes = 700,
        .portable_page_count = 4,
        .license_bytes = 21,
        .model_profile_id = .ordinary_package_v1,
        .tensor_profile_abi = 0x474c_5450_0000_0001,
        .tensor_count = 21,
        .tensor_inventory_sha256 = filledDigest(0xaa),
        .config = .{
            .dim = 64,
            .hidden_dim = 128,
            .layers = 2,
            .vocab = 256,
            .heads = 1,
            .head_dim = 64,
            .kv_heads = 1,
            .rms_eps = 1e-5,
            .rope_theta = 10000,
            .tie_embeddings = false,
        },
        .source_sha256 = filledDigest(0x11),
        .portable_artifact_sha256 = filledDigest(0x22),
        .conversion_profile_sha256 = filledDigest(0x33),
        .conversion_plan_sha256 = filledDigest(0x44),
        .model_content_sha256 = filledDigest(0x55),
        .tokenizer_config_sha256 = filledDigest(0x66),
        .tokenizer_domain_sha256 = filledDigest(0x77),
        .tokenizer_behavior_sha256 = filledDigest(0x88),
        .license_sha256 = filledDigest(0x99),
    });
}

test "stable package manifest round trips without request state" {
    const value = try testManifestV1();
    var wire: [manifest_bytes]u8 = undefined;
    _ = try encodeV1(value, &wire);
    const decoded = try decodeV1(&wire);
    try std.testing.expectEqualDeep(value, decoded);

    var changed_representation: runtime_image.ImageIdentityV1 = .{
        .source_fingerprint = value.model_content_sha256,
        .abi_fingerprint = filledDigest(0xa1),
        .container_bytes = 901,
        .container_sha256 = filledDigest(0xa2),
    };
    const first = try makePreparedRepresentationV1(
        value,
        0x474c_5254_0000_0002,
        2,
        changed_representation,
    );
    changed_representation.abi_fingerprint =
        filledDigest(0xb1);
    changed_representation.container_sha256 =
        filledDigest(0xb2);
    const second = try makePreparedRepresentationV1(
        value,
        0x474c_5254_0000_0002,
        2,
        changed_representation,
    );
    try std.testing.expectEqual(
        first.package_sha256,
        second.package_sha256,
    );
    try std.testing.expect(!digestEqual(
        first.representation_sha256,
        second.representation_sha256,
    ));
}

test "model profile and tensor inventory are manifest bound" {
    const value = try testManifestV1();
    try std.testing.expectEqual(
        model_profile_abi,
        value.model_profile_abi,
    );
    try std.testing.expectEqual(
        ModelProfileV1.ordinary_package_v1,
        value.model_profile_id,
    );
    try std.testing.expectEqual(
        modelProfileRootV1(.ordinary_package_v1),
        value.model_profile_sha256,
    );

    var alternate = value;
    alternate.model_profile_id = @enumFromInt(2);
    alternate.model_profile_sha256 =
        modelProfileRootV1(alternate.model_profile_id);
    var alternate_body: [manifest_body_bytes]u8 =
        undefined;
    writeManifestBodyV1(alternate, &alternate_body);
    alternate.package_sha256 =
        manifestRootV1(&alternate_body);
    var alternate_wire: [manifest_bytes]u8 = undefined;
    _ = try encodeV1(alternate, &alternate_wire);
    const decoded = try decodeV1(&alternate_wire);
    try std.testing.expectEqualDeep(alternate, decoded);
    try std.testing.expect(!digestEqual(
        value.package_sha256,
        alternate.package_sha256,
    ));

    var invalid = value;
    invalid.tensor_count = 0;
    var destination: [manifest_bytes]u8 = undefined;
    try std.testing.expectError(
        Error.InvalidManifest,
        encodeV1(invalid, &destination),
    );
    invalid = value;
    invalid.tensor_inventory_sha256 =
        [_]u8{0} ** @sizeOf(Digest);
    try std.testing.expectError(
        Error.InvalidManifest,
        encodeV1(invalid, &destination),
    );
}

test "prepared representation is package and byte exact" {
    const package = try testManifestV1();
    const identity: runtime_image.ImageIdentityV1 = .{
        .source_fingerprint = package.model_content_sha256,
        .abi_fingerprint = filledDigest(0xa1),
        .container_bytes = 901,
        .container_sha256 = filledDigest(0xa2),
    };
    const value = try makePreparedRepresentationV1(
        package,
        0x474c_5254_0000_0002,
        2,
        identity,
    );
    var wire: [prepared_representation_bytes]u8 =
        undefined;
    _ = try encodePreparedRepresentationV1(value, &wire);
    const decoded =
        try decodePreparedRepresentationV1(&wire);
    try std.testing.expectEqualDeep(value, decoded);
    try validatePreparedRepresentationV1(package, decoded);

    var foreign = package;
    foreign.model_content_sha256 = filledDigest(0xfe);
    var foreign_body: [manifest_body_bytes]u8 = undefined;
    writeManifestBodyV1(foreign, &foreign_body);
    foreign.package_sha256 = manifestRootV1(&foreign_body);
    try std.testing.expectError(
        Error.InvalidPreparedRepresentation,
        validatePreparedRepresentationV1(foreign, decoded),
    );
}

test "admission bundle pins one exact prepared representation" {
    const package = try testManifestV1();
    const representation = try makePreparedRepresentationV1(
        package,
        0x474c_5254_0000_0002,
        2,
        .{
            .source_fingerprint = package.model_content_sha256,
            .abi_fingerprint = filledDigest(0xa1),
            .container_bytes = 901,
            .container_sha256 = filledDigest(0xa2),
        },
    );
    var wire: [admission_bundle_bytes]u8 = undefined;
    _ = try encodeAdmissionBundleV1(
        package,
        representation,
        &wire,
    );
    const decoded = try decodeAdmissionBundleV1(&wire);
    try std.testing.expectEqualDeep(package, decoded.package);
    try std.testing.expectEqualDeep(
        representation,
        decoded.representation,
    );

    var substituted = representation;
    substituted.container_sha256 = filledDigest(0xb2);
    var body: [prepared_representation_body_bytes]u8 =
        undefined;
    writePreparedRepresentationBodyV1(substituted, &body);
    substituted.representation_sha256 =
        preparedRepresentationRootV1(&body);
    var substituted_wire: [admission_bundle_bytes]u8 =
        undefined;
    _ = try encodeAdmissionBundleV1(
        package,
        substituted,
        &substituted_wire,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &wire,
        &substituted_wire,
    ));

    var foreign = package;
    foreign.source_sha256 = filledDigest(0xfe);
    var foreign_body: [manifest_body_bytes]u8 = undefined;
    writeManifestBodyV1(foreign, &foreign_body);
    foreign.package_sha256 = manifestRootV1(&foreign_body);
    try std.testing.expectError(
        Error.InvalidPreparedRepresentation,
        encodeAdmissionBundleV1(
            foreign,
            representation,
            wire[0..admission_bundle_bytes],
        ),
    );
}

test "package codecs reject mutations and preserve destinations" {
    const value = try testManifestV1();
    var wire: [manifest_bytes]u8 = undefined;
    _ = try encodeV1(value, &wire);

    var corrupted = wire;
    corrupted[208] ^= 1;
    try std.testing.expectError(
        Error.InvalidManifest,
        decodeV1(&corrupted),
    );
    corrupted = wire;
    corrupted[600] = 1;
    try std.testing.expectError(
        Error.InvalidManifest,
        decodeV1(&corrupted),
    );

    corrupted = wire;
    writeU64(
        corrupted[0..manifest_body_bytes],
        24,
        0,
    );
    const missing_flag_root = manifestRootV1(
        corrupted[0..manifest_body_bytes],
    );
    @memcpy(
        corrupted[manifest_body_bytes..],
        &missing_flag_root,
    );
    try std.testing.expectError(
        Error.InvalidManifest,
        decodeV1(&corrupted),
    );

    corrupted = wire;
    @memcpy(
        corrupted[0..8],
        &[_]u8{ 'G', 'L', 'P', 'K', 'G', '0', '1', 0 },
    );
    writeU64(
        corrupted[0..manifest_body_bytes],
        8,
        0x474c_504b_0000_0001,
    );
    writeU64(
        corrupted[0..manifest_body_bytes],
        24,
        0,
    );
    try std.testing.expectError(
        Error.InvalidManifest,
        decodeV2(&corrupted),
    );

    var invalid = value;
    invalid.source_bytes = 0;
    var destination = [_]u8{0x6d} ** manifest_bytes;
    const before = destination;
    try std.testing.expectError(
        Error.InvalidManifest,
        encodeV1(invalid, &destination),
    );
    try std.testing.expectEqualSlices(
        u8,
        &before,
        &destination,
    );
}
