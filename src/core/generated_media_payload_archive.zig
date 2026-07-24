const std = @import("std");
const media = @import("generated_media_checkpoint.zig");
const checkpoint_file = @import("continuation_checkpoint_file.zig");

pub const Digest = [32]u8;

pub const manifest_abi: u64 = 1;
pub const manifest_body_bytes: usize = 832;
pub const manifest_bytes: usize = manifest_body_bytes + 32;
pub const archive_object_count: usize = 8;

pub const manifest_object_ordinal: u64 = 1;
pub const checkpoint_object_ordinal: u64 = 2;
pub const image_member_object_ordinal: u64 = 3;
pub const audio_member_object_ordinal: u64 = 4;
pub const video_member_object_ordinal: u64 = 5;
pub const image_payload_object_ordinal: u64 = 6;
pub const audio_payload_object_ordinal: u64 = 7;
pub const video_payload_object_ordinal: u64 = 8;

const manifest_magic = "GLGMPAY1".*;
const manifest_domain = "glacier.generated-media-payload-manifest.v1";
const payload_domain = "glacier.generated-media-encoded-payload.v1";
const reference_identity_domain =
    "glacier.generated-media-payload-reference-identity.v1";

pub const Error = media.Error || checkpoint_file.Error || error{
    InvalidManifest,
    InvalidManifestRoot,
    InvalidPayload,
    InvalidBinding,
    InvalidArchive,
    UnsafeDestination,
    ArithmeticOverflow,
    BufferTooSmall,
};

pub const EncodedPayloadInputV1 = struct {
    encoding_abi: u64,
    bytes: []const u8,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,
};

pub const GeneratedMediaPayloadManifestV1 = struct {
    request_epoch: u64,
    generation: u64,
    publication_sequence: u64,
    payload_count: u64,
    total_encoded_bytes: u64,
    image_ordinal: u64,
    audio_ordinal: u64,
    video_ordinal: u64,
    image_encoding_abi: u64,
    audio_encoding_abi: u64,
    video_encoding_abi: u64,
    image_source_bytes: u64,
    audio_source_bytes: u64,
    video_source_bytes: u64,
    image_encoded_bytes: u64,
    audio_encoded_bytes: u64,
    video_encoded_bytes: u64,
    checkpoint_sha256: Digest,
    image_member_sha256: Digest,
    audio_member_sha256: Digest,
    video_member_sha256: Digest,
    image_source_output_sha256: Digest,
    audio_source_output_sha256: Digest,
    video_source_output_sha256: Digest,
    image_payload_sha256: Digest,
    audio_payload_sha256: Digest,
    video_payload_sha256: Digest,
    image_encoder_implementation_sha256: Digest,
    audio_encoder_implementation_sha256: Digest,
    video_encoder_implementation_sha256: Digest,
    image_format_sha256: Digest,
    audio_format_sha256: Digest,
    video_format_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    previous_manifest_sha256: Digest,
    manifest_sha256: Digest,
};

pub const PreviousGenerationV1 = struct {
    archive_bytes: []const u8,
};

pub const ArchiveInputV1 = struct {
    previous: ?PreviousGenerationV1,
    image_member: media.GeneratedMediaMemberV1,
    audio_member: media.GeneratedMediaMemberV1,
    video_member: media.GeneratedMediaMemberV1,
    checkpoint: media.GeneratedMediaCheckpointV1,
    image_payload: EncodedPayloadInputV1,
    audio_payload: EncodedPayloadInputV1,
    video_payload: EncodedPayloadInputV1,
};

pub const PreparedArchiveV1 = struct {
    set: checkpoint_file.PreparedSetV1,
    manifest: GeneratedMediaPayloadManifestV1,
};

pub const DecodedArchiveV1 = struct {
    archive_bytes: []const u8,
    archive_sha256: Digest,
    manifest: GeneratedMediaPayloadManifestV1,
    checkpoint: media.GeneratedMediaCheckpointV1,
    image_member: media.GeneratedMediaMemberV1,
    audio_member: media.GeneratedMediaMemberV1,
    video_member: media.GeneratedMediaMemberV1,
    image_payload: []const u8,
    audio_payload: []const u8,
    video_payload: []const u8,

    pub fn previous(self: DecodedArchiveV1) PreviousGenerationV1 {
        return .{
            .archive_bytes = self.archive_bytes,
        };
    }
};

pub fn makeManifestV1(
    input: ArchiveInputV1,
) Error!GeneratedMediaPayloadManifestV1 {
    try validatePayloadInputV1(input.image_payload);
    try validatePayloadInputV1(input.audio_payload);
    try validatePayloadInputV1(input.video_payload);
    try validateTypedGenerationV1(input);
    const previous_manifest_sha256 = if (input.previous) |previous|
        (try validatePreviousGenerationV1(previous))
            .manifest.manifest_sha256
    else
        [_]u8{0} ** 32;
    const image_encoded_bytes = std.math.cast(
        u64,
        input.image_payload.bytes.len,
    ) orelse return Error.ArithmeticOverflow;
    const audio_encoded_bytes = std.math.cast(
        u64,
        input.audio_payload.bytes.len,
    ) orelse return Error.ArithmeticOverflow;
    const video_encoded_bytes = std.math.cast(
        u64,
        input.video_payload.bytes.len,
    ) orelse return Error.ArithmeticOverflow;
    const total_encoded_bytes = try checkedAdd(
        try checkedAdd(image_encoded_bytes, audio_encoded_bytes),
        video_encoded_bytes,
    );
    var manifest: GeneratedMediaPayloadManifestV1 = .{
        .request_epoch = input.checkpoint.request_epoch,
        .generation = input.checkpoint.generation,
        .publication_sequence = input.checkpoint.publication_sequence,
        .payload_count = media.required_member_count,
        .total_encoded_bytes = total_encoded_bytes,
        .image_ordinal = input.image_member.ordinal,
        .audio_ordinal = input.audio_member.ordinal,
        .video_ordinal = input.video_member.ordinal,
        .image_encoding_abi = input.image_payload.encoding_abi,
        .audio_encoding_abi = input.audio_payload.encoding_abi,
        .video_encoding_abi = input.video_payload.encoding_abi,
        .image_source_bytes = input.image_member.byte_count,
        .audio_source_bytes = input.audio_member.byte_count,
        .video_source_bytes = input.video_member.byte_count,
        .image_encoded_bytes = image_encoded_bytes,
        .audio_encoded_bytes = audio_encoded_bytes,
        .video_encoded_bytes = video_encoded_bytes,
        .checkpoint_sha256 = input.checkpoint.checkpoint_sha256,
        .image_member_sha256 = input.image_member.member_sha256,
        .audio_member_sha256 = input.audio_member.member_sha256,
        .video_member_sha256 = input.video_member.member_sha256,
        .image_source_output_sha256 = input.image_member.output_sha256,
        .audio_source_output_sha256 = input.audio_member.output_sha256,
        .video_source_output_sha256 = input.video_member.output_sha256,
        .image_payload_sha256 = payloadRootV1(
            media.image_modality,
            input.image_payload.encoding_abi,
            input.image_payload.bytes,
        ),
        .audio_payload_sha256 = payloadRootV1(
            media.audio_modality,
            input.audio_payload.encoding_abi,
            input.audio_payload.bytes,
        ),
        .video_payload_sha256 = payloadRootV1(
            media.video_modality,
            input.video_payload.encoding_abi,
            input.video_payload.bytes,
        ),
        .image_encoder_implementation_sha256 = input.image_payload.encoder_implementation_sha256,
        .audio_encoder_implementation_sha256 = input.audio_payload.encoder_implementation_sha256,
        .video_encoder_implementation_sha256 = input.video_payload.encoder_implementation_sha256,
        .image_format_sha256 = input.image_payload.format_sha256,
        .audio_format_sha256 = input.audio_payload.format_sha256,
        .video_format_sha256 = input.video_payload.format_sha256,
        .tenant_scope_sha256 = input.checkpoint.tenant_scope_sha256,
        .metadata_policy_sha256 = input.checkpoint.metadata_policy_sha256,
        .challenge_sha256 = input.checkpoint.challenge_sha256,
        .previous_manifest_sha256 = previous_manifest_sha256,
        .manifest_sha256 = [_]u8{0} ** 32,
    };
    manifest.manifest_sha256 = manifestRootV1(manifest);
    try validateManifestBindingsV1(input, manifest);
    return manifest;
}

pub fn validateManifestV1(
    manifest: GeneratedMediaPayloadManifestV1,
) Error!void {
    const total_encoded_bytes = checkedAdd(
        checkedAdd(
            manifest.image_encoded_bytes,
            manifest.audio_encoded_bytes,
        ) catch return Error.InvalidManifest,
        manifest.video_encoded_bytes,
    ) catch return Error.InvalidManifest;
    const audio_generation = checkedAdd(
        manifest.audio_ordinal,
        1,
    ) catch return Error.InvalidManifest;
    const video_generation = checkedAdd(
        manifest.video_ordinal,
        1,
    ) catch return Error.InvalidManifest;
    if (manifest.request_epoch == 0 or manifest.generation == 0 or
        manifest.publication_sequence == 0 or
        manifest.payload_count != media.required_member_count or
        manifest.total_encoded_bytes != total_encoded_bytes or
        manifest.image_ordinal != manifest.generation or
        audio_generation != manifest.generation or
        video_generation != manifest.generation or
        manifest.image_encoding_abi == 0 or
        manifest.audio_encoding_abi == 0 or
        manifest.video_encoding_abi == 0 or
        manifest.image_source_bytes == 0 or
        manifest.audio_source_bytes == 0 or
        manifest.video_source_bytes == 0 or
        manifest.image_encoded_bytes == 0 or
        manifest.audio_encoded_bytes == 0 or
        manifest.video_encoded_bytes == 0 or
        isZero(manifest.checkpoint_sha256) or
        isZero(manifest.image_member_sha256) or
        isZero(manifest.audio_member_sha256) or
        isZero(manifest.video_member_sha256) or
        isZero(manifest.image_source_output_sha256) or
        isZero(manifest.audio_source_output_sha256) or
        isZero(manifest.video_source_output_sha256) or
        isZero(manifest.image_payload_sha256) or
        isZero(manifest.audio_payload_sha256) or
        isZero(manifest.video_payload_sha256) or
        isZero(manifest.image_encoder_implementation_sha256) or
        isZero(manifest.audio_encoder_implementation_sha256) or
        isZero(manifest.video_encoder_implementation_sha256) or
        isZero(manifest.image_format_sha256) or
        isZero(manifest.audio_format_sha256) or
        isZero(manifest.video_format_sha256) or
        isZero(manifest.tenant_scope_sha256) or
        isZero(manifest.metadata_policy_sha256) or
        isZero(manifest.challenge_sha256) or
        (manifest.generation == 1 and
            !isZero(manifest.previous_manifest_sha256)) or
        (manifest.generation > 1 and
            isZero(manifest.previous_manifest_sha256)))
        return Error.InvalidManifest;
    if (!digestEqual(
        manifest.manifest_sha256,
        manifestRootV1(manifest),
    )) return Error.InvalidManifestRoot;
}

pub fn validateManifestBindingsV1(
    input: ArchiveInputV1,
    manifest: GeneratedMediaPayloadManifestV1,
) Error!void {
    try validateManifestSnapshotBindingsV1(input, manifest);
    try validateTypedGenerationV1(input);
    const expected_previous_manifest = if (input.previous) |previous|
        (try validatePreviousGenerationV1(previous))
            .manifest.manifest_sha256
    else
        [_]u8{0} ** 32;
    if (!digestEqual(
        manifest.previous_manifest_sha256,
        expected_previous_manifest,
    ))
        return Error.InvalidBinding;
}

fn validateManifestSnapshotBindingsV1(
    input: ArchiveInputV1,
    manifest: GeneratedMediaPayloadManifestV1,
) Error!void {
    try validateManifestV1(manifest);
    try validatePayloadInputV1(input.image_payload);
    try validatePayloadInputV1(input.audio_payload);
    try validatePayloadInputV1(input.video_payload);
    try validateCheckpointSnapshotBindingsV1(
        input.image_member,
        input.audio_member,
        input.video_member,
        input.checkpoint,
    );
    const image_encoded_bytes = std.math.cast(
        u64,
        input.image_payload.bytes.len,
    ) orelse return Error.InvalidBinding;
    const audio_encoded_bytes = std.math.cast(
        u64,
        input.audio_payload.bytes.len,
    ) orelse return Error.InvalidBinding;
    const video_encoded_bytes = std.math.cast(
        u64,
        input.video_payload.bytes.len,
    ) orelse return Error.InvalidBinding;
    if (manifest.request_epoch != input.checkpoint.request_epoch or
        manifest.generation != input.checkpoint.generation or
        manifest.publication_sequence !=
            input.checkpoint.publication_sequence or
        manifest.image_ordinal != input.image_member.ordinal or
        manifest.audio_ordinal != input.audio_member.ordinal or
        manifest.video_ordinal != input.video_member.ordinal or
        manifest.image_encoding_abi !=
            input.image_payload.encoding_abi or
        manifest.audio_encoding_abi !=
            input.audio_payload.encoding_abi or
        manifest.video_encoding_abi !=
            input.video_payload.encoding_abi or
        manifest.image_source_bytes != input.image_member.byte_count or
        manifest.audio_source_bytes != input.audio_member.byte_count or
        manifest.video_source_bytes != input.video_member.byte_count or
        manifest.image_encoded_bytes != image_encoded_bytes or
        manifest.audio_encoded_bytes != audio_encoded_bytes or
        manifest.video_encoded_bytes != video_encoded_bytes or
        !digestEqual(
            manifest.checkpoint_sha256,
            input.checkpoint.checkpoint_sha256,
        ) or
        !digestEqual(
            manifest.image_member_sha256,
            input.image_member.member_sha256,
        ) or
        !digestEqual(
            manifest.audio_member_sha256,
            input.audio_member.member_sha256,
        ) or
        !digestEqual(
            manifest.video_member_sha256,
            input.video_member.member_sha256,
        ) or
        !digestEqual(
            manifest.image_source_output_sha256,
            input.image_member.output_sha256,
        ) or
        !digestEqual(
            manifest.audio_source_output_sha256,
            input.audio_member.output_sha256,
        ) or
        !digestEqual(
            manifest.video_source_output_sha256,
            input.video_member.output_sha256,
        ) or
        !digestEqual(
            manifest.image_payload_sha256,
            payloadRootV1(
                media.image_modality,
                input.image_payload.encoding_abi,
                input.image_payload.bytes,
            ),
        ) or
        !digestEqual(
            manifest.audio_payload_sha256,
            payloadRootV1(
                media.audio_modality,
                input.audio_payload.encoding_abi,
                input.audio_payload.bytes,
            ),
        ) or
        !digestEqual(
            manifest.video_payload_sha256,
            payloadRootV1(
                media.video_modality,
                input.video_payload.encoding_abi,
                input.video_payload.bytes,
            ),
        ) or
        !digestEqual(
            manifest.image_encoder_implementation_sha256,
            input.image_payload.encoder_implementation_sha256,
        ) or
        !digestEqual(
            manifest.audio_encoder_implementation_sha256,
            input.audio_payload.encoder_implementation_sha256,
        ) or
        !digestEqual(
            manifest.video_encoder_implementation_sha256,
            input.video_payload.encoder_implementation_sha256,
        ) or
        !digestEqual(
            manifest.image_format_sha256,
            input.image_payload.format_sha256,
        ) or
        !digestEqual(
            manifest.audio_format_sha256,
            input.audio_payload.format_sha256,
        ) or
        !digestEqual(
            manifest.video_format_sha256,
            input.video_payload.format_sha256,
        ) or
        !digestEqual(
            manifest.tenant_scope_sha256,
            input.checkpoint.tenant_scope_sha256,
        ) or
        !digestEqual(
            manifest.metadata_policy_sha256,
            input.checkpoint.metadata_policy_sha256,
        ) or
        !digestEqual(
            manifest.challenge_sha256,
            input.checkpoint.challenge_sha256,
        ))
        return Error.InvalidBinding;
}

pub fn encodeArchiveV1(
    input: ArchiveInputV1,
    destination: []u8,
) Error!PreparedArchiveV1 {
    const manifest = try makeManifestV1(input);
    var manifest_storage: [manifest_bytes]u8 = undefined;
    const manifest_wire = try encodeManifestV1(
        manifest,
        &manifest_storage,
    );
    var checkpoint_storage: [media.checkpoint_bytes]u8 = undefined;
    const checkpoint_wire = try media.encodeCheckpointV1(
        input.checkpoint,
        &checkpoint_storage,
    );
    var image_member_storage: [media.member_bytes]u8 = undefined;
    const image_member_wire = try media.encodeMemberV1(
        input.image_member,
        &image_member_storage,
    );
    var audio_member_storage: [media.member_bytes]u8 = undefined;
    const audio_member_wire = try media.encodeMemberV1(
        input.audio_member,
        &audio_member_storage,
    );
    var video_member_storage: [media.member_bytes]u8 = undefined;
    const video_member_wire = try media.encodeMemberV1(
        input.video_member,
        &video_member_storage,
    );
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = manifest_object_ordinal,
            .abi_version = manifest_abi,
            .bytes = manifest_wire,
        },
        .{
            .kind = .extension,
            .ordinal = checkpoint_object_ordinal,
            .abi_version = media.checkpoint_abi,
            .bytes = checkpoint_wire,
        },
        .{
            .kind = .extension,
            .ordinal = image_member_object_ordinal,
            .abi_version = media.member_abi,
            .bytes = image_member_wire,
        },
        .{
            .kind = .extension,
            .ordinal = audio_member_object_ordinal,
            .abi_version = media.member_abi,
            .bytes = audio_member_wire,
        },
        .{
            .kind = .extension,
            .ordinal = video_member_object_ordinal,
            .abi_version = media.member_abi,
            .bytes = video_member_wire,
        },
        .{
            .kind = .extension,
            .ordinal = image_payload_object_ordinal,
            .abi_version = input.image_payload.encoding_abi,
            .bytes = input.image_payload.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = audio_payload_object_ordinal,
            .abi_version = input.audio_payload.encoding_abi,
            .bytes = input.audio_payload.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = video_payload_object_ordinal,
            .abi_version = input.video_payload.encoding_abi,
            .bytes = input.video_payload.bytes,
        },
    };
    const publication_next_sequence = checkedAdd(
        input.checkpoint.publication_sequence,
        1,
    ) catch return Error.ArithmeticOverflow;
    const parent_archive_sha256 = if (input.previous) |previous|
        (try validatePreviousGenerationV1(previous)).archive_sha256
    else
        [_]u8{0} ** 32;
    const set = try checkpoint_file.encodeSetV1(
        .{
            .generation = input.checkpoint.generation,
            .request_epoch = input.checkpoint.request_epoch,
            .publication_next_sequence = publication_next_sequence,
            .parent_checkpoint_sha256 = parent_archive_sha256,
            .challenge_sha256 = input.checkpoint.challenge_sha256,
        },
        &objects,
        destination,
    );
    return .{
        .set = set,
        .manifest = manifest,
    };
}

pub fn decodeArchiveV1(
    encoded: []const u8,
    previous: ?PreviousGenerationV1,
) Error!DecodedArchiveV1 {
    const decoded = try decodeArchiveSnapshotV1(encoded);
    const input: ArchiveInputV1 = .{
        .previous = previous,
        .image_member = decoded.image_member,
        .audio_member = decoded.audio_member,
        .video_member = decoded.video_member,
        .checkpoint = decoded.checkpoint,
        .image_payload = .{
            .encoding_abi = decoded.manifest.image_encoding_abi,
            .bytes = decoded.image_payload,
            .encoder_implementation_sha256 = decoded.manifest
                .image_encoder_implementation_sha256,
            .format_sha256 = decoded.manifest.image_format_sha256,
        },
        .audio_payload = .{
            .encoding_abi = decoded.manifest.audio_encoding_abi,
            .bytes = decoded.audio_payload,
            .encoder_implementation_sha256 = decoded.manifest
                .audio_encoder_implementation_sha256,
            .format_sha256 = decoded.manifest.audio_format_sha256,
        },
        .video_payload = .{
            .encoding_abi = decoded.manifest.video_encoding_abi,
            .bytes = decoded.video_payload,
            .encoder_implementation_sha256 = decoded.manifest
                .video_encoder_implementation_sha256,
            .format_sha256 = decoded.manifest.video_format_sha256,
        },
    };
    validateManifestBindingsV1(input, decoded.manifest) catch
        return Error.InvalidArchive;
    const set = checkpoint_file.decodeSetV1(encoded) catch
        return Error.InvalidArchive;
    const expected_parent = if (previous) |value|
        (validatePreviousGenerationV1(value) catch
            return Error.InvalidArchive).archive_sha256
    else
        [_]u8{0} ** 32;
    if (!digestEqual(
        set.metadata.parent_checkpoint_sha256,
        expected_parent,
    ))
        return Error.InvalidArchive;
    return decoded;
}

fn decodeArchiveSnapshotV1(
    encoded: []const u8,
) Error!DecodedArchiveV1 {
    const set = checkpoint_file.decodeSetV1(encoded) catch
        return Error.InvalidArchive;
    if (set.object_count != archive_object_count)
        return Error.InvalidArchive;
    const manifest_object = try exactObjectV1(
        set,
        manifest_object_ordinal,
        manifest_abi,
    );
    const checkpoint_object = try exactObjectV1(
        set,
        checkpoint_object_ordinal,
        media.checkpoint_abi,
    );
    const image_member_object = try exactObjectV1(
        set,
        image_member_object_ordinal,
        media.member_abi,
    );
    const audio_member_object = try exactObjectV1(
        set,
        audio_member_object_ordinal,
        media.member_abi,
    );
    const video_member_object = try exactObjectV1(
        set,
        video_member_object_ordinal,
        media.member_abi,
    );
    const image_payload_object = try objectV1(
        set,
        image_payload_object_ordinal,
    );
    const audio_payload_object = try objectV1(
        set,
        audio_payload_object_ordinal,
    );
    const video_payload_object = try objectV1(
        set,
        video_payload_object_ordinal,
    );
    const manifest = decodeManifestV1(manifest_object.bytes) catch
        return Error.InvalidArchive;
    const checkpoint = media.decodeCheckpointV1(
        checkpoint_object.bytes,
    ) catch return Error.InvalidArchive;
    const image_member = media.decodeMemberV1(
        image_member_object.bytes,
    ) catch return Error.InvalidArchive;
    const audio_member = media.decodeMemberV1(
        audio_member_object.bytes,
    ) catch return Error.InvalidArchive;
    const video_member = media.decodeMemberV1(
        video_member_object.bytes,
    ) catch return Error.InvalidArchive;
    if (image_payload_object.abi_version !=
        manifest.image_encoding_abi or
        audio_payload_object.abi_version !=
            manifest.audio_encoding_abi or
        video_payload_object.abi_version !=
            manifest.video_encoding_abi or
        image_payload_object.bytes.len !=
            manifest.image_encoded_bytes or
        audio_payload_object.bytes.len !=
            manifest.audio_encoded_bytes or
        video_payload_object.bytes.len !=
            manifest.video_encoded_bytes)
        return Error.InvalidArchive;
    const input: ArchiveInputV1 = .{
        .previous = null,
        .image_member = image_member,
        .audio_member = audio_member,
        .video_member = video_member,
        .checkpoint = checkpoint,
        .image_payload = .{
            .encoding_abi = manifest.image_encoding_abi,
            .bytes = image_payload_object.bytes,
            .encoder_implementation_sha256 = manifest.image_encoder_implementation_sha256,
            .format_sha256 = manifest.image_format_sha256,
        },
        .audio_payload = .{
            .encoding_abi = manifest.audio_encoding_abi,
            .bytes = audio_payload_object.bytes,
            .encoder_implementation_sha256 = manifest.audio_encoder_implementation_sha256,
            .format_sha256 = manifest.audio_format_sha256,
        },
        .video_payload = .{
            .encoding_abi = manifest.video_encoding_abi,
            .bytes = video_payload_object.bytes,
            .encoder_implementation_sha256 = manifest.video_encoder_implementation_sha256,
            .format_sha256 = manifest.video_format_sha256,
        },
    };
    validateManifestSnapshotBindingsV1(input, manifest) catch
        return Error.InvalidArchive;
    const publication_next_sequence = checkedAdd(
        manifest.publication_sequence,
        1,
    ) catch return Error.InvalidArchive;
    if (set.metadata.generation != manifest.generation or
        set.metadata.request_epoch != manifest.request_epoch or
        set.metadata.publication_next_sequence !=
            publication_next_sequence or
        !digestEqual(
            set.metadata.challenge_sha256,
            manifest.challenge_sha256,
        ))
        return Error.InvalidArchive;
    return .{
        .archive_bytes = encoded,
        .archive_sha256 = set.checkpoint_sha256,
        .manifest = manifest,
        .checkpoint = checkpoint,
        .image_member = image_member,
        .audio_member = audio_member,
        .video_member = video_member,
        .image_payload = image_payload_object.bytes,
        .audio_payload = audio_payload_object.bytes,
        .video_payload = video_payload_object.bytes,
    };
}

pub fn encodeManifestV1(
    manifest: GeneratedMediaPayloadManifestV1,
    output: []u8,
) Error![]const u8 {
    validateManifestV1(manifest) catch
        return Error.InvalidManifest;
    if (output.len < manifest_bytes) return Error.BufferTooSmall;
    writeManifestBodyV1(
        manifest,
        output[0..manifest_body_bytes],
    );
    @memcpy(
        output[manifest_body_bytes..manifest_bytes],
        &manifest.manifest_sha256,
    );
    return output[0..manifest_bytes];
}

pub fn decodeManifestV1(
    input: []const u8,
) Error!GeneratedMediaPayloadManifestV1 {
    if (input.len != manifest_bytes or
        !std.mem.eql(u8, input[0..8], &manifest_magic) or
        readU64(input, 8) != manifest_abi or
        readU64(input, 16) != manifest_bytes or
        readU64(input, 24) != 0)
        return Error.InvalidManifest;
    var manifest: GeneratedMediaPayloadManifestV1 = undefined;
    var offset: usize = 32;
    const fields = std.meta.fields(GeneratedMediaPayloadManifestV1);
    inline for (fields[0 .. fields.len - 1]) |field| {
        if (field.type == u64) {
            @field(manifest, field.name) = readU64(input, offset);
            offset += 8;
        } else if (field.type == Digest) {
            @memcpy(
                &@field(manifest, field.name),
                input[offset .. offset + 32],
            );
            offset += 32;
        } else {
            @compileError("unsupported payload manifest field");
        }
    }
    for (input[offset..manifest_body_bytes]) |byte| {
        if (byte != 0) return Error.InvalidManifest;
    }
    @memcpy(
        &manifest.manifest_sha256,
        input[manifest_body_bytes..manifest_bytes],
    );
    validateManifestV1(manifest) catch
        return Error.InvalidManifest;
    return manifest;
}

pub fn manifestRootV1(
    manifest: GeneratedMediaPayloadManifestV1,
) Digest {
    var body: [manifest_body_bytes]u8 = undefined;
    writeManifestBodyV1(manifest, &body);
    return domainRoot(manifest_domain, &body);
}

pub fn payloadRootV1(
    modality: u64,
    encoding_abi: u64,
    bytes: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(payload_domain);
    hashU64(&hash, modality);
    hashU64(&hash, encoding_abi);
    hashU64(&hash, bytes.len);
    hash.update(bytes);
    return hash.finalResult();
}

fn validateTypedGenerationV1(input: ArchiveInputV1) Error!void {
    const previous_checkpoint: ?media.GeneratedMediaCheckpointV1 =
        if (input.previous) |previous|
            (try validatePreviousGenerationV1(previous)).checkpoint
        else
            null;
    media.validateCheckpointBindingsV1(
        previous_checkpoint,
        input.image_member,
        input.audio_member,
        input.video_member,
        input.checkpoint,
    ) catch return Error.InvalidBinding;
}

fn validatePreviousGenerationV1(
    previous: PreviousGenerationV1,
) Error!DecodedArchiveV1 {
    return decodeArchiveSnapshotV1(previous.archive_bytes) catch
        return Error.InvalidBinding;
}

fn validateCheckpointSnapshotBindingsV1(
    image: media.GeneratedMediaMemberV1,
    audio: media.GeneratedMediaMemberV1,
    video: media.GeneratedMediaMemberV1,
    checkpoint: media.GeneratedMediaCheckpointV1,
) Error!void {
    media.validateMemberV1(image) catch return Error.InvalidBinding;
    media.validateMemberV1(audio) catch return Error.InvalidBinding;
    media.validateMemberV1(video) catch return Error.InvalidBinding;
    media.validateCheckpointV1(checkpoint) catch
        return Error.InvalidBinding;
    const total_bytes = checkedAdd(
        checkedAdd(
            image.byte_count,
            audio.byte_count,
        ) catch return Error.InvalidBinding,
        video.byte_count,
    ) catch return Error.InvalidBinding;
    const total_units = checkedAdd(
        checkedAdd(
            image.unit_count,
            audio.unit_count,
        ) catch return Error.InvalidBinding,
        video.unit_count,
    ) catch return Error.InvalidBinding;
    const audio_generation = checkedAdd(
        audio.ordinal,
        1,
    ) catch return Error.InvalidBinding;
    const video_generation = checkedAdd(
        video.ordinal,
        1,
    ) catch return Error.InvalidBinding;
    if (image.modality != media.image_modality or
        audio.modality != media.audio_modality or
        video.modality != media.video_modality or
        image.request_epoch != audio.request_epoch or
        image.request_epoch != video.request_epoch or
        !digestEqual(
            image.tenant_scope_sha256,
            audio.tenant_scope_sha256,
        ) or
        !digestEqual(
            image.tenant_scope_sha256,
            video.tenant_scope_sha256,
        ) or
        !digestEqual(
            image.metadata_policy_sha256,
            audio.metadata_policy_sha256,
        ) or
        !digestEqual(
            image.metadata_policy_sha256,
            video.metadata_policy_sha256,
        ) or
        !digestEqual(
            image.challenge_sha256,
            audio.challenge_sha256,
        ) or
        !digestEqual(
            image.challenge_sha256,
            video.challenge_sha256,
        ) or
        checkpoint.request_epoch != image.request_epoch or
        checkpoint.generation != image.ordinal or
        audio_generation != checkpoint.generation or
        video_generation != checkpoint.generation or
        checkpoint.total_bytes != total_bytes or
        checkpoint.total_units != total_units or
        checkpoint.image_ordinal != image.ordinal or
        checkpoint.audio_ordinal != audio.ordinal or
        checkpoint.video_ordinal != video.ordinal or
        checkpoint.image_unit_end != image.unit_end or
        checkpoint.audio_unit_end != audio.unit_end or
        checkpoint.video_unit_end != video.unit_end or
        checkpoint.video_timeline_end != video.timeline_end or
        checkpoint.image_bytes != image.byte_count or
        checkpoint.audio_bytes != audio.byte_count or
        checkpoint.video_bytes != video.byte_count or
        checkpoint.image_units != image.unit_count or
        checkpoint.audio_units != audio.unit_count or
        checkpoint.video_units != video.unit_count or
        !digestEqual(
            checkpoint.tenant_scope_sha256,
            image.tenant_scope_sha256,
        ) or
        !digestEqual(
            checkpoint.metadata_policy_sha256,
            image.metadata_policy_sha256,
        ) or
        !digestEqual(
            checkpoint.challenge_sha256,
            image.challenge_sha256,
        ) or
        !digestEqual(
            checkpoint.image_member_sha256,
            image.member_sha256,
        ) or
        !digestEqual(
            checkpoint.audio_member_sha256,
            audio.member_sha256,
        ) or
        !digestEqual(
            checkpoint.video_member_sha256,
            video.member_sha256,
        ) or
        !digestEqual(
            checkpoint.image_result_sha256,
            image.result_sha256,
        ) or
        !digestEqual(
            checkpoint.audio_result_sha256,
            audio.result_sha256,
        ) or
        !digestEqual(
            checkpoint.video_result_sha256,
            video.result_sha256,
        ) or
        !digestEqual(
            checkpoint.image_output_sha256,
            image.output_sha256,
        ) or
        !digestEqual(
            checkpoint.audio_output_sha256,
            audio.output_sha256,
        ) or
        !digestEqual(
            checkpoint.video_output_sha256,
            video.output_sha256,
        ) or
        !digestEqual(
            checkpoint.image_state_sha256,
            image.state_after_sha256,
        ) or
        !digestEqual(
            checkpoint.audio_state_sha256,
            audio.state_after_sha256,
        ) or
        !digestEqual(
            checkpoint.video_state_sha256,
            video.state_after_sha256,
        ) or
        !digestEqual(
            checkpoint.audio_completion_sha256,
            audio.completion_sha256,
        ) or
        !digestEqual(
            checkpoint.video_completion_sha256,
            video.completion_sha256,
        ) or
        (checkpoint.generation == 1 and
            (image.unit_start != 0 or audio.unit_start != 0 or
                video.unit_start != 0 or video.timeline_start != 0)))
        return Error.InvalidBinding;
}

fn validatePayloadInputV1(
    payload: EncodedPayloadInputV1,
) Error!void {
    if (payload.encoding_abi == 0 or payload.bytes.len == 0 or
        isZero(payload.encoder_implementation_sha256) or
        isZero(payload.format_sha256))
        return Error.InvalidPayload;
}

fn exactObjectV1(
    set: checkpoint_file.DecodedSetV1,
    ordinal: u64,
    abi_version: u64,
) Error!checkpoint_file.ObjectViewV1 {
    const object = set.object(.extension, ordinal) catch
        return Error.InvalidArchive;
    if (object.abi_version != abi_version)
        return Error.InvalidArchive;
    return object;
}

fn objectV1(
    set: checkpoint_file.DecodedSetV1,
    ordinal: u64,
) Error!checkpoint_file.ObjectViewV1 {
    return set.object(.extension, ordinal) catch
        return Error.InvalidArchive;
}

fn writeManifestBodyV1(
    manifest: GeneratedMediaPayloadManifestV1,
    output: []u8,
) void {
    std.debug.assert(output.len == manifest_body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &manifest_magic);
    writeU64(output, 8, manifest_abi);
    writeU64(output, 16, manifest_bytes);
    writeU64(output, 24, 0);
    var offset: usize = 32;
    const fields = std.meta.fields(GeneratedMediaPayloadManifestV1);
    inline for (fields[0 .. fields.len - 1]) |field| {
        if (field.type == u64) {
            writeU64(output, offset, @field(manifest, field.name));
            offset += 8;
        } else if (field.type == Digest) {
            @memcpy(
                output[offset .. offset + 32],
                &@field(manifest, field.name),
            );
            offset += 32;
        } else {
            @compileError("unsupported payload manifest field");
        }
    }
    std.debug.assert(offset <= manifest_body_bytes);
}

fn domainRoot(domain: []const u8, bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(bytes);
    return hash.finalResult();
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(digest: Digest) bool {
    return digestEqual(digest, [_]u8{0} ** 32);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    const cast = std.math.cast(u64, value) orelse unreachable;
    var storage: [8]u8 = undefined;
    std.mem.writeInt(u64, &storage, cast, .little);
    hash.update(&storage);
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    const cast = std.math.cast(u64, value) orelse unreachable;
    std.mem.writeInt(
        u64,
        output[offset .. offset + 8][0..8],
        cast,
        .little,
    );
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

pub const ReferenceArchivesV1 = struct {
    first: PreparedArchiveV1,
    first_decoded: DecodedArchiveV1,
    second: PreparedArchiveV1,
    second_decoded: DecodedArchiveV1,
};

pub fn makeReferenceArchivesV1(
    first_archive: []u8,
    second_archive: []u8,
) Error!ReferenceArchivesV1 {
    if (slicesOverlap(first_archive, second_archive))
        return Error.UnsafeDestination;
    const fixture = try media.referenceFixtureV1();
    const first = try encodeArchiveV1(
        .{
            .previous = null,
            .image_member = fixture.image1,
            .audio_member = fixture.audio1,
            .video_member = fixture.video1,
            .checkpoint = fixture.checkpoint1,
            .image_payload = .{
                .encoding_abi = 1,
                .bytes = "image-envelope-generation-one",
                .encoder_implementation_sha256 = referenceIdentityRootV1(
                    "image-encoder-v1",
                ),
                .format_sha256 = referenceIdentityRootV1(
                    "image-format-v1",
                ),
            },
            .audio_payload = .{
                .encoding_abi = 2,
                .bytes = "audio-envelope-generation-one",
                .encoder_implementation_sha256 = referenceIdentityRootV1(
                    "audio-encoder-v1",
                ),
                .format_sha256 = referenceIdentityRootV1(
                    "audio-format-v1",
                ),
            },
            .video_payload = .{
                .encoding_abi = 3,
                .bytes = "video-envelope-generation-one",
                .encoder_implementation_sha256 = referenceIdentityRootV1(
                    "video-encoder-v1",
                ),
                .format_sha256 = referenceIdentityRootV1(
                    "video-format-v1",
                ),
            },
        },
        first_archive,
    );
    const first_decoded = try decodeArchiveV1(first.set.bytes, null);
    const second = try encodeArchiveV1(
        .{
            .previous = first_decoded.previous(),
            .image_member = fixture.image2,
            .audio_member = fixture.audio2,
            .video_member = fixture.video2,
            .checkpoint = fixture.checkpoint2,
            .image_payload = .{
                .encoding_abi = 1,
                .bytes = "image-envelope-generation-two",
                .encoder_implementation_sha256 = referenceIdentityRootV1(
                    "image-encoder-v1",
                ),
                .format_sha256 = referenceIdentityRootV1(
                    "image-format-v1",
                ),
            },
            .audio_payload = .{
                .encoding_abi = 2,
                .bytes = "audio-envelope-generation-two",
                .encoder_implementation_sha256 = referenceIdentityRootV1(
                    "audio-encoder-v1",
                ),
                .format_sha256 = referenceIdentityRootV1(
                    "audio-format-v1",
                ),
            },
            .video_payload = .{
                .encoding_abi = 3,
                .bytes = "video-envelope-generation-two",
                .encoder_implementation_sha256 = referenceIdentityRootV1(
                    "video-encoder-v1",
                ),
                .format_sha256 = referenceIdentityRootV1(
                    "video-format-v1",
                ),
            },
        },
        second_archive,
    );
    const second_decoded = try decodeArchiveV1(
        second.set.bytes,
        first_decoded.previous(),
    );
    return .{
        .first = first,
        .first_decoded = first_decoded,
        .second = second,
        .second_decoded = second_decoded,
    };
}

fn referenceIdentityRootV1(label: []const u8) Digest {
    return domainRoot(reference_identity_domain, label);
}

fn slicesOverlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left.len,
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right.len,
    ) catch return true;
    return left_start < right_end and right_start < left_end;
}

test "generated media payload archives are canonical and mutation complete" {
    var first_archive: [8192]u8 = undefined;
    var second_archive: [8192]u8 = undefined;
    const archives = try makeReferenceArchivesV1(
        &first_archive,
        &second_archive,
    );
    var manifest_wire: [manifest_bytes]u8 = undefined;
    const encoded_manifest = try encodeManifestV1(
        archives.first.manifest,
        &manifest_wire,
    );
    for (0..encoded_manifest.len) |index| {
        var mutated: [manifest_bytes]u8 = undefined;
        @memcpy(&mutated, encoded_manifest);
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidManifest,
            decodeManifestV1(&mutated),
        );
    }
    for (0..archives.first.set.bytes.len) |index| {
        var mutated: [8192]u8 = undefined;
        @memcpy(
            mutated[0..archives.first.set.bytes.len],
            archives.first.set.bytes,
        );
        mutated[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidArchive,
            decodeArchiveV1(
                mutated[0..archives.first.set.bytes.len],
                null,
            ),
        );
    }
}

test "encoded payload substitution and mixed lineage fail closed" {
    var first_archive: [8192]u8 = undefined;
    var second_archive: [8192]u8 = undefined;
    const archives = try makeReferenceArchivesV1(
        &first_archive,
        &second_archive,
    );
    const fixture = try media.referenceFixtureV1();
    var foreign_manifest = archives.second.manifest;
    foreign_manifest.audio_payload_sha256 =
        archives.first.manifest.audio_payload_sha256;
    foreign_manifest.manifest_sha256 = manifestRootV1(foreign_manifest);
    try validateManifestV1(foreign_manifest);
    const input: ArchiveInputV1 = .{
        .previous = archives.first_decoded.previous(),
        .image_member = fixture.image2,
        .audio_member = fixture.audio2,
        .video_member = fixture.video2,
        .checkpoint = fixture.checkpoint2,
        .image_payload = .{
            .encoding_abi = 1,
            .bytes = archives.second_decoded.image_payload,
            .encoder_implementation_sha256 = archives.second.manifest
                .image_encoder_implementation_sha256,
            .format_sha256 = archives.second.manifest.image_format_sha256,
        },
        .audio_payload = .{
            .encoding_abi = 2,
            .bytes = archives.second_decoded.audio_payload,
            .encoder_implementation_sha256 = archives.second.manifest
                .audio_encoder_implementation_sha256,
            .format_sha256 = archives.second.manifest.audio_format_sha256,
        },
        .video_payload = .{
            .encoding_abi = 3,
            .bytes = archives.second_decoded.video_payload,
            .encoder_implementation_sha256 = archives.second.manifest
                .video_encoder_implementation_sha256,
            .format_sha256 = archives.second.manifest.video_format_sha256,
        },
    };
    try std.testing.expectError(
        Error.InvalidBinding,
        validateManifestBindingsV1(input, foreign_manifest),
    );
    var mixed = input;
    mixed.audio_member = fixture.audio1;
    try std.testing.expectError(
        Error.InvalidBinding,
        makeManifestV1(mixed),
    );
}

test "payload archive exposes exact slices and predecessor" {
    var first_archive: [8192]u8 = undefined;
    var second_archive: [8192]u8 = undefined;
    const archives = try makeReferenceArchivesV1(
        &first_archive,
        &second_archive,
    );
    try std.testing.expectEqualStrings(
        "image-envelope-generation-two",
        archives.second_decoded.image_payload,
    );
    try std.testing.expectEqualStrings(
        "audio-envelope-generation-two",
        archives.second_decoded.audio_payload,
    );
    try std.testing.expectEqualStrings(
        "video-envelope-generation-two",
        archives.second_decoded.video_payload,
    );
    try std.testing.expectEqual(
        archives.first.manifest.manifest_sha256,
        archives.second_decoded
            .manifest.previous_manifest_sha256,
    );
}

test "payload archive roots match the independent reference chain" {
    var first_archive: [8192]u8 = undefined;
    var second_archive: [8192]u8 = undefined;
    const archives = try makeReferenceArchivesV1(
        &first_archive,
        &second_archive,
    );
    var expected_first_manifest: Digest = undefined;
    var expected_first_archive: Digest = undefined;
    var expected_second_manifest: Digest = undefined;
    var expected_second_archive: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_first_manifest,
        "8c9c6294745a061d0da7c41268546db29" ++
            "063e92dba671c22e2ef79e90731d3dd",
    );
    _ = try std.fmt.hexToBytes(
        &expected_first_archive,
        "61f28f9e079827f2014d98b923f4334e" ++
            "c5f7c538ccf1c64c4afcf78f8362ab95",
    );
    _ = try std.fmt.hexToBytes(
        &expected_second_manifest,
        "4035107bbe18c3310ca5977234dc88388" ++
            "41fc7f09cc1f8c18965a05de3ad2dec",
    );
    _ = try std.fmt.hexToBytes(
        &expected_second_archive,
        "d34d628564228dfdea53fd3f489691a2" ++
            "a1a29afe9dac44f1c6cf5df0a9cfd907",
    );
    try std.testing.expectEqual(
        expected_first_manifest,
        archives.first.manifest.manifest_sha256,
    );
    try std.testing.expectEqual(
        expected_first_archive,
        archives.first.set.checkpoint_sha256,
    );
    try std.testing.expectEqual(
        expected_second_manifest,
        archives.second.manifest.manifest_sha256,
    );
    try std.testing.expectEqual(
        expected_second_archive,
        archives.second.set.checkpoint_sha256,
    );
}

test "rehash cannot split archive manifest checkpoint or previous bytes" {
    var first_archive: [8192]u8 = undefined;
    var second_archive: [8192]u8 = undefined;
    const archives = try makeReferenceArchivesV1(
        &first_archive,
        &second_archive,
    );
    const original = try checkpoint_file.decodeSetV1(
        archives.first.set.bytes,
    );
    const checkpoint_object = try objectV1(
        original,
        checkpoint_object_ordinal,
    );
    const image_member_object = try objectV1(
        original,
        image_member_object_ordinal,
    );
    const audio_member_object = try objectV1(
        original,
        audio_member_object_ordinal,
    );
    const video_member_object = try objectV1(
        original,
        video_member_object_ordinal,
    );
    const image_payload_object = try objectV1(
        original,
        image_payload_object_ordinal,
    );
    const audio_payload_object = try objectV1(
        original,
        audio_payload_object_ordinal,
    );
    const video_payload_object = try objectV1(
        original,
        video_payload_object_ordinal,
    );

    var split_manifest = archives.first.manifest;
    split_manifest.image_source_bytes += 1;
    split_manifest.manifest_sha256 = manifestRootV1(split_manifest);
    var split_manifest_storage: [manifest_bytes]u8 = undefined;
    const split_manifest_wire = try encodeManifestV1(
        split_manifest,
        &split_manifest_storage,
    );
    var objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = manifest_object_ordinal,
            .abi_version = manifest_abi,
            .bytes = split_manifest_wire,
        },
        .{
            .kind = .extension,
            .ordinal = checkpoint_object_ordinal,
            .abi_version = checkpoint_object.abi_version,
            .bytes = checkpoint_object.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = image_member_object_ordinal,
            .abi_version = image_member_object.abi_version,
            .bytes = image_member_object.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = audio_member_object_ordinal,
            .abi_version = audio_member_object.abi_version,
            .bytes = audio_member_object.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = video_member_object_ordinal,
            .abi_version = video_member_object.abi_version,
            .bytes = video_member_object.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = image_payload_object_ordinal,
            .abi_version = image_payload_object.abi_version,
            .bytes = image_payload_object.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = audio_payload_object_ordinal,
            .abi_version = audio_payload_object.abi_version,
            .bytes = audio_payload_object.bytes,
        },
        .{
            .kind = .extension,
            .ordinal = video_payload_object_ordinal,
            .abi_version = video_payload_object.abi_version,
            .bytes = video_payload_object.bytes,
        },
    };
    var forged_archive_storage: [8192]u8 = undefined;
    const forged_manifest_archive = try checkpoint_file.encodeSetV1(
        original.metadata,
        &objects,
        &forged_archive_storage,
    );
    try std.testing.expectError(
        Error.InvalidArchive,
        decodeArchiveV1(forged_manifest_archive.bytes, null),
    );

    var split_checkpoint = archives.first_decoded.checkpoint;
    split_checkpoint.tenant_scope_sha256 = referenceIdentityRootV1(
        "foreign-tenant",
    );
    split_checkpoint.checkpoint_sha256 = media.checkpointRootV1(
        split_checkpoint,
    );
    try media.validateCheckpointV1(split_checkpoint);
    var split_checkpoint_storage: [media.checkpoint_bytes]u8 = undefined;
    const split_checkpoint_wire = try media.encodeCheckpointV1(
        split_checkpoint,
        &split_checkpoint_storage,
    );
    split_manifest = archives.first.manifest;
    split_manifest.checkpoint_sha256 =
        split_checkpoint.checkpoint_sha256;
    split_manifest.tenant_scope_sha256 =
        split_checkpoint.tenant_scope_sha256;
    split_manifest.manifest_sha256 = manifestRootV1(split_manifest);
    const split_scope_manifest_wire = try encodeManifestV1(
        split_manifest,
        &split_manifest_storage,
    );
    objects[0].bytes = split_scope_manifest_wire;
    objects[1].bytes = split_checkpoint_wire;
    const forged_checkpoint_archive = try checkpoint_file.encodeSetV1(
        original.metadata,
        &objects,
        &forged_archive_storage,
    );
    try std.testing.expectError(
        Error.InvalidArchive,
        decodeArchiveV1(forged_checkpoint_archive.bytes, null),
    );

    var corrupt_previous_storage: [8192]u8 = undefined;
    @memcpy(
        corrupt_previous_storage[0..archives.first.set.bytes.len],
        archives.first.set.bytes,
    );
    corrupt_previous_storage[0] ^= 1;
    try std.testing.expectError(
        Error.InvalidArchive,
        decodeArchiveV1(
            archives.second.set.bytes,
            .{
                .archive_bytes = corrupt_previous_storage[0..archives.first.set.bytes.len],
            },
        ),
    );

    var alternate_archive_storage: [8192]u8 = undefined;
    const alternate = try encodeArchiveV1(
        .{
            .previous = null,
            .image_member = archives.first_decoded.image_member,
            .audio_member = archives.first_decoded.audio_member,
            .video_member = archives.first_decoded.video_member,
            .checkpoint = archives.first_decoded.checkpoint,
            .image_payload = .{
                .encoding_abi = archives.first.manifest.image_encoding_abi,
                .bytes = "alternate-image-envelope-generation-one",
                .encoder_implementation_sha256 = archives.first.manifest
                    .image_encoder_implementation_sha256,
                .format_sha256 = archives.first.manifest
                    .image_format_sha256,
            },
            .audio_payload = .{
                .encoding_abi = archives.first.manifest.audio_encoding_abi,
                .bytes = archives.first_decoded.audio_payload,
                .encoder_implementation_sha256 = archives.first.manifest
                    .audio_encoder_implementation_sha256,
                .format_sha256 = archives.first.manifest
                    .audio_format_sha256,
            },
            .video_payload = .{
                .encoding_abi = archives.first.manifest.video_encoding_abi,
                .bytes = archives.first_decoded.video_payload,
                .encoder_implementation_sha256 = archives.first.manifest
                    .video_encoder_implementation_sha256,
                .format_sha256 = archives.first.manifest
                    .video_format_sha256,
            },
        },
        &alternate_archive_storage,
    );
    const alternate_decoded = try decodeArchiveV1(
        alternate.set.bytes,
        null,
    );
    try std.testing.expectError(
        Error.InvalidArchive,
        decodeArchiveV1(
            archives.second.set.bytes,
            alternate_decoded.previous(),
        ),
    );
}

test "reference archive storage must remain distinct" {
    var storage: [16_384]u8 = undefined;
    try std.testing.expectError(
        Error.UnsafeDestination,
        makeReferenceArchivesV1(
            storage[0..8192],
            storage[4096..12_288],
        ),
    );
}
