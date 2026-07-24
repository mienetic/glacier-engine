//! Canonical external-format evidence for retained generated media.
//!
//! This additive sidecar binds strict PNG, PCM/WAVE, and APNG delivery
//! profiles to an already validated generated-media registry and producer
//! transition. It does not alter either existing V1 wire. The embedded
//! producer plan or manifest lets a verifier reconstruct the format semantics
//! without model execution, callbacks, credentials, or private model state.

const std = @import("std");
const core = @import("core");
const png_apng = @import("png_apng_v1.zig");
const wave_pcm = @import("wave_pcm_v1.zig");

const image = core.generated_image_publication;
const audio = core.generated_audio_playback;
const video = core.generated_video_display;
const registry = core.generated_media_output_registry;
const transition = core.generated_media_producer_transition;

pub const Digest = [32]u8;
pub const abi: u64 = 1;
pub const allowed_flags: u64 = 0;

pub const format_record_bytes: usize = 1_152;
pub const format_record_body_bytes: usize = 1_120;
pub const producer_wire_slot_bytes: usize = 736;
pub const format_batch_header_bytes: usize = 576;
pub const format_batch_body_bytes: usize = 544;
pub const max_format_evidence_bytes: usize =
    format_batch_header_bytes +
    registry.max_entries * format_record_bytes;

const format_record_magic = "GLMFMT1\x00".*;
const format_batch_magic = "GLMFBAT1".*;
const format_record_domain =
    "glacier-generated-media-format-record-v1\x00";
const format_record_table_domain =
    "glacier-generated-media-format-record-table-v1\x00";
const format_batch_domain =
    "glacier-generated-media-format-batch-v1\x00";
const profile_set_domain =
    "glacier-generated-media-format-profile-set-v1\x00";

const zero_digest = [_]u8{0} ** 32;

pub const Error = error{
    InvalidWire,
    InvalidRecord,
    InvalidBatch,
    InvalidBinding,
    InvalidPreviousEvidence,
    UnsupportedProfile,
    ArithmeticOverflow,
    BufferTooSmall,
    BufferAlias,
};

pub const DeliveryProfileV1 = enum(u64) {
    png = 1,
    wave_pcm_s16le = 2,
    apng_two_frame_gray8 = 3,
};

pub const DeliveryV1 = struct {
    profile: DeliveryProfileV1,
    producer_wire: []const u8,
};

pub const FormatRecordInputV1 = struct {
    modality: registry.ModalityV1,
    profile: DeliveryProfileV1,
    registry_ordinal: u64,
    encoding_abi: u64,
    raw_output_bytes: u64,
    encoded_payload_bytes: u64,
    producer_plan_or_manifest_sha256: Digest,
    raw_output_sha256: Digest,
    encoded_payload_sha256: Digest,
    registry_payload_sha256: Digest,
    encoder_implementation_sha256: Digest,
    format_contract_sha256: Digest,
    transition_receipt_sha256: Digest,
    registry_entry_sha256: Digest,
    previous_format_record_sha256: Digest,
    producer_wire: []const u8,
};

pub const FormatRecordV1 = struct {
    modality: registry.ModalityV1,
    profile: DeliveryProfileV1,
    registry_ordinal: u64,
    encoding_abi: u64,
    producer_wire_bytes: u64,
    raw_output_bytes: u64,
    encoded_payload_bytes: u64,
    producer_plan_or_manifest_sha256: Digest,
    raw_output_sha256: Digest,
    encoded_payload_sha256: Digest,
    registry_payload_sha256: Digest,
    encoder_implementation_sha256: Digest,
    format_contract_sha256: Digest,
    transition_receipt_sha256: Digest,
    registry_entry_sha256: Digest,
    previous_format_record_sha256: Digest,
    producer_wire: []const u8,
    record_sha256: Digest,
};

pub const FormatBatchEvidenceV1 = struct {
    request_epoch: u64,
    registry_generation: u64,
    publication_sequence: u64,
    record_count: u64,
    record_table_bytes: u64,
    aggregate_raw_output_bytes: u64,
    aggregate_encoded_payload_bytes: u64,
    modality_mask: u64,
    generation_plan_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    transition_batch_sha256: Digest,
    registry_manifest_sha256: Digest,
    registry_archive_sha256: Digest,
    record_table_sha256: Digest,
    profile_set_sha256: Digest,
    previous_format_batch_sha256: Digest,
    first_record_sha256: Digest,
    terminal_image_sha256: Digest,
    terminal_audio_sha256: Digest,
    terminal_video_sha256: Digest,
    batch_sha256: Digest,
};

pub const DecodedFormatEvidenceV1 = struct {
    batch: FormatBatchEvidenceV1,
    records: []const u8,
    encoded: []const u8,

    fn validatedView(
        self: DecodedFormatEvidenceV1,
    ) Error!DecodedFormatEvidenceV1 {
        const canonical = try decodeFormatEvidenceV1(self.encoded);
        if (!std.meta.eql(self.batch, canonical.batch) or
            !std.mem.eql(u8, self.records, canonical.records) or
            !std.mem.eql(u8, self.encoded, canonical.encoded))
            return Error.InvalidBatch;
        return canonical;
    }

    pub fn record(
        self: DecodedFormatEvidenceV1,
        index: usize,
    ) Error!FormatRecordV1 {
        const canonical = try self.validatedView();
        const count = std.math.cast(
            usize,
            canonical.batch.record_count,
        ) orelse return Error.InvalidBatch;
        if (index >= count) return Error.InvalidBatch;
        const start = std.math.mul(
            usize,
            index,
            format_record_bytes,
        ) catch return Error.ArithmeticOverflow;
        const end = std.math.add(
            usize,
            start,
            format_record_bytes,
        ) catch return Error.ArithmeticOverflow;
        return decodeFormatRecordV1(canonical.records[start..end]);
    }

    pub fn terminal(
        self: DecodedFormatEvidenceV1,
        modality: registry.ModalityV1,
    ) Error!Digest {
        const canonical = try self.validatedView();
        return switch (modality) {
            .image => canonical.batch.terminal_image_sha256,
            .audio => canonical.batch.terminal_audio_sha256,
            .video => canonical.batch.terminal_video_sha256,
        };
    }
};

pub const PreviousGenerationV1 = struct {
    transition_generation: transition.PreviousGenerationV1,
    format_evidence: []const u8,
};

pub const PreparedConformantTransitionV1 = struct {
    evidence: []const u8,
    batch: FormatBatchEvidenceV1,
};

pub fn requiredFormatEvidenceBytesV1(
    record_count: usize,
) Error!usize {
    if (record_count == 0 or record_count > registry.max_entries)
        return Error.InvalidBatch;
    const table_bytes = std.math.mul(
        usize,
        record_count,
        format_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        format_batch_header_bytes,
        table_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn formatContractSha256V1(
    profile: DeliveryProfileV1,
) Digest {
    return switch (profile) {
        .png => png_apng.pngFormatContractSha256V1(),
        .wave_pcm_s16le => wave_pcm.waveFormatContractSha256V1(),
        .apng_two_frame_gray8 => png_apng.apngFormatContractSha256V1(),
    };
}

pub fn profileSetSha256V1() Digest {
    var roots: [3 * 32]u8 = undefined;
    @memcpy(roots[0..32], &formatContractSha256V1(.png));
    @memcpy(
        roots[32..64],
        &formatContractSha256V1(.wave_pcm_s16le),
    );
    @memcpy(
        roots[64..96],
        &formatContractSha256V1(.apng_two_frame_gray8),
    );
    return domainRoot(profile_set_domain, &roots);
}

pub fn encodingAbiV1(profile: DeliveryProfileV1) u64 {
    return switch (profile) {
        .png => png_apng.png_encoding_abi,
        .wave_pcm_s16le => wave_pcm.wave_encoding_abi,
        .apng_two_frame_gray8 => png_apng.apng_encoding_abi,
    };
}

pub fn encodeFormatRecordV1(
    value: FormatRecordInputV1,
    destination: []u8,
) Error![]const u8 {
    try validateFormatRecordInputV1(value);
    if (destination.len < format_record_bytes)
        return Error.BufferTooSmall;
    if (slicesOverlap(
        value.producer_wire,
        destination[0..format_record_bytes],
    )) return Error.BufferAlias;

    var encoded: [format_record_bytes]u8 = undefined;
    @memset(&encoded, 0);
    @memcpy(encoded[0..8], &format_record_magic);
    writeU64(&encoded, 8, abi);
    writeU64(&encoded, 16, format_record_bytes);
    writeU64(&encoded, 24, allowed_flags);
    writeU64(&encoded, 32, @intFromEnum(value.modality));
    writeU64(&encoded, 40, @intFromEnum(value.profile));
    writeU64(&encoded, 48, value.registry_ordinal);
    writeU64(&encoded, 56, value.encoding_abi);
    writeU64(
        &encoded,
        64,
        try usizeToU64(value.producer_wire.len),
    );
    writeU64(&encoded, 72, value.raw_output_bytes);
    writeU64(&encoded, 80, value.encoded_payload_bytes);
    @memcpy(
        encoded[96..128],
        &value.producer_plan_or_manifest_sha256,
    );
    @memcpy(encoded[128..160], &value.raw_output_sha256);
    @memcpy(encoded[160..192], &value.encoded_payload_sha256);
    @memcpy(encoded[192..224], &value.registry_payload_sha256);
    @memcpy(
        encoded[224..256],
        &value.encoder_implementation_sha256,
    );
    @memcpy(encoded[256..288], &value.format_contract_sha256);
    @memcpy(encoded[288..320], &value.transition_receipt_sha256);
    @memcpy(encoded[320..352], &value.registry_entry_sha256);
    @memcpy(
        encoded[352..384],
        &value.previous_format_record_sha256,
    );
    @memcpy(
        encoded[384 .. 384 + value.producer_wire.len],
        value.producer_wire,
    );
    const root = domainRoot(
        format_record_domain,
        encoded[0..format_record_body_bytes],
    );
    @memcpy(encoded[format_record_body_bytes..], &root);
    @memcpy(destination[0..format_record_bytes], &encoded);
    return destination[0..format_record_bytes];
}

pub fn decodeFormatRecordV1(
    encoded: []const u8,
) Error!FormatRecordV1 {
    if (encoded.len != format_record_bytes or
        !std.mem.eql(u8, encoded[0..8], &format_record_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 16) != format_record_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 88) != 0)
        return Error.InvalidRecord;
    const expected_root = domainRoot(
        format_record_domain,
        encoded[0..format_record_body_bytes],
    );
    if (!digestEqual(
        expected_root,
        encoded[format_record_body_bytes..format_record_bytes].*,
    )) return Error.InvalidRecord;

    const modality = std.meta.intToEnum(
        registry.ModalityV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidRecord;
    const profile = std.meta.intToEnum(
        DeliveryProfileV1,
        readU64(encoded, 40),
    ) catch return Error.UnsupportedProfile;
    const wire_bytes = std.math.cast(
        usize,
        readU64(encoded, 64),
    ) orelse return Error.InvalidRecord;
    if (wire_bytes > producer_wire_slot_bytes)
        return Error.InvalidRecord;
    for (encoded[384 + wire_bytes .. format_record_body_bytes]) |byte| {
        if (byte != 0) return Error.InvalidRecord;
    }

    const value: FormatRecordV1 = .{
        .modality = modality,
        .profile = profile,
        .registry_ordinal = readU64(encoded, 48),
        .encoding_abi = readU64(encoded, 56),
        .producer_wire_bytes = readU64(encoded, 64),
        .raw_output_bytes = readU64(encoded, 72),
        .encoded_payload_bytes = readU64(encoded, 80),
        .producer_plan_or_manifest_sha256 = encoded[96..128].*,
        .raw_output_sha256 = encoded[128..160].*,
        .encoded_payload_sha256 = encoded[160..192].*,
        .registry_payload_sha256 = encoded[192..224].*,
        .encoder_implementation_sha256 = encoded[224..256].*,
        .format_contract_sha256 = encoded[256..288].*,
        .transition_receipt_sha256 = encoded[288..320].*,
        .registry_entry_sha256 = encoded[320..352].*,
        .previous_format_record_sha256 = encoded[352..384].*,
        .producer_wire = encoded[384 .. 384 + wire_bytes],
        .record_sha256 = encoded[format_record_body_bytes..format_record_bytes].*,
    };
    try validateDecodedFormatRecordV1(value);
    return value;
}

fn validateFormatRecordInputV1(
    value: FormatRecordInputV1,
) Error!void {
    try validateRecordShapeV1(
        value.modality,
        value.profile,
        value.encoding_abi,
        value.raw_output_bytes,
        value.encoded_payload_bytes,
        value.producer_wire,
    );
    if (isZero(value.producer_plan_or_manifest_sha256) or
        isZero(value.raw_output_sha256) or
        isZero(value.encoded_payload_sha256) or
        isZero(value.registry_payload_sha256) or
        isZero(value.encoder_implementation_sha256) or
        isZero(value.format_contract_sha256) or
        isZero(value.transition_receipt_sha256) or
        isZero(value.registry_entry_sha256) or
        !digestEqual(
            value.format_contract_sha256,
            formatContractSha256V1(value.profile),
        ) or
        !digestEqual(
            value.producer_plan_or_manifest_sha256,
            try producerWireRootV1(
                value.modality,
                value.producer_wire,
            ),
        ))
        return Error.InvalidRecord;
}

fn validateDecodedFormatRecordV1(
    value: FormatRecordV1,
) Error!void {
    if (value.producer_wire_bytes !=
        try usizeToU64(value.producer_wire.len))
        return Error.InvalidRecord;
    try validateRecordShapeV1(
        value.modality,
        value.profile,
        value.encoding_abi,
        value.raw_output_bytes,
        value.encoded_payload_bytes,
        value.producer_wire,
    );
    if (isZero(value.producer_plan_or_manifest_sha256) or
        isZero(value.raw_output_sha256) or
        isZero(value.encoded_payload_sha256) or
        isZero(value.registry_payload_sha256) or
        isZero(value.encoder_implementation_sha256) or
        isZero(value.format_contract_sha256) or
        isZero(value.transition_receipt_sha256) or
        isZero(value.registry_entry_sha256) or
        isZero(value.record_sha256) or
        !digestEqual(
            value.format_contract_sha256,
            formatContractSha256V1(value.profile),
        ) or
        !digestEqual(
            value.producer_plan_or_manifest_sha256,
            try producerWireRootV1(
                value.modality,
                value.producer_wire,
            ),
        ))
        return Error.InvalidRecord;
}

fn producerWireRootV1(
    modality: registry.ModalityV1,
    producer_wire: []const u8,
) Error!Digest {
    return switch (modality) {
        .image => (image.decodeGeneratedImagePlanV1(
            producer_wire,
        ) catch return Error.InvalidRecord).plan_sha256,
        .audio => (audio.decodePlanV1(
            producer_wire,
        ) catch return Error.InvalidRecord).plan_sha256,
        .video => (video.decodeManifestV1(
            producer_wire,
        ) catch return Error.InvalidRecord).manifest_sha256,
    };
}

fn validateRecordShapeV1(
    modality: registry.ModalityV1,
    profile: DeliveryProfileV1,
    encoding_abi: u64,
    raw_output_bytes: u64,
    encoded_payload_bytes: u64,
    producer_wire: []const u8,
) Error!void {
    if (encoding_abi != encodingAbiV1(profile) or
        raw_output_bytes == 0 or
        encoded_payload_bytes == 0)
        return Error.InvalidRecord;
    const expected_wire_bytes: usize = switch (modality) {
        .image => image.plan_bytes,
        .audio => audio.plan_bytes,
        .video => video.manifest_bytes,
    };
    if (producer_wire.len != expected_wire_bytes or
        switch (modality) {
            .image => profile != .png,
            .audio => profile != .wave_pcm_s16le,
            .video => profile != .apng_two_frame_gray8,
        })
        return Error.UnsupportedProfile;
}

pub fn decodeFormatEvidenceV1(
    encoded: []const u8,
) Error!DecodedFormatEvidenceV1 {
    if (encoded.len < format_batch_header_bytes or
        !std.mem.eql(u8, encoded[0..8], &format_batch_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidWire;
    const declared_length = std.math.cast(
        usize,
        readU64(encoded, 16),
    ) orelse return Error.InvalidWire;
    if (declared_length != encoded.len)
        return Error.InvalidWire;
    const count = std.math.cast(
        usize,
        readU64(encoded, 56),
    ) orelse return Error.InvalidBatch;
    const required = try requiredFormatEvidenceBytesV1(count);
    const table_bytes = std.math.mul(
        usize,
        count,
        format_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    if (required != encoded.len or
        readU64(encoded, 64) != try usizeToU64(table_bytes))
        return Error.InvalidBatch;
    const expected_batch_root = domainRoot(
        format_batch_domain,
        encoded[0..format_batch_body_bytes],
    );
    if (!digestEqual(
        expected_batch_root,
        encoded[format_batch_body_bytes..format_batch_header_bytes].*,
    )) return Error.InvalidBatch;
    const records = encoded[format_batch_header_bytes..];
    const expected_table_root = domainRoot(
        format_record_table_domain,
        records,
    );
    if (!digestEqual(expected_table_root, encoded[320..352].*))
        return Error.InvalidBatch;

    const batch: FormatBatchEvidenceV1 = .{
        .request_epoch = readU64(encoded, 32),
        .registry_generation = readU64(encoded, 40),
        .publication_sequence = readU64(encoded, 48),
        .record_count = readU64(encoded, 56),
        .record_table_bytes = readU64(encoded, 64),
        .aggregate_raw_output_bytes = readU64(encoded, 72),
        .aggregate_encoded_payload_bytes = readU64(encoded, 80),
        .modality_mask = readU64(encoded, 88),
        .generation_plan_sha256 = encoded[96..128].*,
        .tenant_scope_sha256 = encoded[128..160].*,
        .metadata_policy_sha256 = encoded[160..192].*,
        .challenge_sha256 = encoded[192..224].*,
        .transition_batch_sha256 = encoded[224..256].*,
        .registry_manifest_sha256 = encoded[256..288].*,
        .registry_archive_sha256 = encoded[288..320].*,
        .record_table_sha256 = encoded[320..352].*,
        .profile_set_sha256 = encoded[352..384].*,
        .previous_format_batch_sha256 = encoded[384..416].*,
        .first_record_sha256 = encoded[416..448].*,
        .terminal_image_sha256 = encoded[448..480].*,
        .terminal_audio_sha256 = encoded[480..512].*,
        .terminal_video_sha256 = encoded[512..544].*,
        .batch_sha256 = encoded[format_batch_body_bytes..format_batch_header_bytes].*,
    };
    try validateBatchShapeV1(batch, records);
    return .{
        .batch = batch,
        .records = records,
        .encoded = encoded,
    };
}

fn validateBatchShapeV1(
    batch: FormatBatchEvidenceV1,
    records: []const u8,
) Error!void {
    if (batch.request_epoch == 0 or
        batch.registry_generation == 0 or
        batch.publication_sequence == 0 or
        batch.record_count == 0 or
        batch.record_count > registry.max_entries or
        batch.record_table_bytes != try usizeToU64(records.len) or
        batch.aggregate_raw_output_bytes == 0 or
        batch.aggregate_encoded_payload_bytes == 0 or
        batch.modality_mask == 0 or
        batch.modality_mask & ~@as(u64, 0x7) != 0 or
        isZero(batch.generation_plan_sha256) or
        isZero(batch.tenant_scope_sha256) or
        isZero(batch.metadata_policy_sha256) or
        isZero(batch.challenge_sha256) or
        isZero(batch.transition_batch_sha256) or
        isZero(batch.registry_manifest_sha256) or
        isZero(batch.registry_archive_sha256) or
        isZero(batch.record_table_sha256) or
        isZero(batch.profile_set_sha256) or
        isZero(batch.first_record_sha256) or
        isZero(batch.batch_sha256) or
        !digestEqual(batch.profile_set_sha256, profileSetSha256V1()) or
        (batch.registry_generation == 1) !=
            isZero(batch.previous_format_batch_sha256))
        return Error.InvalidBatch;

    var aggregate_raw: u64 = 0;
    var aggregate_encoded: u64 = 0;
    var mask: u64 = 0;
    var first = zero_digest;
    var terminals = [_]Digest{zero_digest} ** 3;
    var seen = [_]bool{false} ** 3;
    var previous_modality: u64 = 0;
    const count = std.math.cast(
        usize,
        batch.record_count,
    ) orelse return Error.InvalidBatch;
    for (0..count) |index| {
        const start = std.math.mul(
            usize,
            index,
            format_record_bytes,
        ) catch return Error.ArithmeticOverflow;
        const end = std.math.add(
            usize,
            start,
            format_record_bytes,
        ) catch return Error.ArithmeticOverflow;
        const record = try decodeFormatRecordV1(records[start..end]);
        const modality_value = @intFromEnum(record.modality);
        if (index != 0 and modality_value < previous_modality)
            return Error.InvalidBatch;
        previous_modality = modality_value;
        const slot = modalitySlot(record.modality);
        if (seen[slot]) {
            if (!digestEqual(
                record.previous_format_record_sha256,
                terminals[slot],
            )) return Error.InvalidBatch;
        } else {
            if ((batch.registry_generation == 1) !=
                isZero(record.previous_format_record_sha256))
                return Error.InvalidBatch;
            seen[slot] = true;
        }
        if (index == 0) first = record.record_sha256;
        terminals[slot] = record.record_sha256;
        mask |= modalityBit(record.modality);
        aggregate_raw = checkedAdd(
            aggregate_raw,
            record.raw_output_bytes,
        ) catch return Error.ArithmeticOverflow;
        aggregate_encoded = checkedAdd(
            aggregate_encoded,
            record.encoded_payload_bytes,
        ) catch return Error.ArithmeticOverflow;
    }
    if (aggregate_raw != batch.aggregate_raw_output_bytes or
        aggregate_encoded != batch.aggregate_encoded_payload_bytes or
        mask != batch.modality_mask or
        !digestEqual(first, batch.first_record_sha256) or
        !digestEqual(terminals[0], batch.terminal_image_sha256) or
        !digestEqual(terminals[1], batch.terminal_audio_sha256) or
        !digestEqual(terminals[2], batch.terminal_video_sha256))
        return Error.InvalidBatch;
}

fn writeBatchHeaderV1(
    batch: FormatBatchEvidenceV1,
    destination: []u8,
) Error!void {
    if (destination.len != format_batch_header_bytes)
        return Error.BufferTooSmall;
    @memset(destination, 0);
    @memcpy(destination[0..8], &format_batch_magic);
    writeU64(destination, 8, abi);
    const total = checkedAdd(
        format_batch_header_bytes,
        try u64ToUsize(batch.record_table_bytes),
    ) catch return Error.ArithmeticOverflow;
    writeU64(destination, 16, try usizeToU64(total));
    writeU64(destination, 24, allowed_flags);
    writeU64(destination, 32, batch.request_epoch);
    writeU64(destination, 40, batch.registry_generation);
    writeU64(destination, 48, batch.publication_sequence);
    writeU64(destination, 56, batch.record_count);
    writeU64(destination, 64, batch.record_table_bytes);
    writeU64(destination, 72, batch.aggregate_raw_output_bytes);
    writeU64(
        destination,
        80,
        batch.aggregate_encoded_payload_bytes,
    );
    writeU64(destination, 88, batch.modality_mask);
    @memcpy(destination[96..128], &batch.generation_plan_sha256);
    @memcpy(destination[128..160], &batch.tenant_scope_sha256);
    @memcpy(destination[160..192], &batch.metadata_policy_sha256);
    @memcpy(destination[192..224], &batch.challenge_sha256);
    @memcpy(destination[224..256], &batch.transition_batch_sha256);
    @memcpy(destination[256..288], &batch.registry_manifest_sha256);
    @memcpy(destination[288..320], &batch.registry_archive_sha256);
    @memcpy(destination[320..352], &batch.record_table_sha256);
    @memcpy(destination[352..384], &batch.profile_set_sha256);
    @memcpy(
        destination[384..416],
        &batch.previous_format_batch_sha256,
    );
    @memcpy(destination[416..448], &batch.first_record_sha256);
    @memcpy(destination[448..480], &batch.terminal_image_sha256);
    @memcpy(destination[480..512], &batch.terminal_audio_sha256);
    @memcpy(destination[512..544], &batch.terminal_video_sha256);
    const root = domainRoot(
        format_batch_domain,
        destination[0..format_batch_body_bytes],
    );
    @memcpy(destination[format_batch_body_bytes..], &root);
}

pub fn encodeConformantArchiveAndEvidenceV1(
    current: transition.PreviousGenerationV1,
    predecessor: ?PreviousGenerationV1,
    deliveries: []const DeliveryV1,
    destination: []u8,
) Error!PreparedConformantTransitionV1 {
    const manifest = current.registry_archive.manifest;
    const previous_decoded = if (predecessor) |value|
        validateArchiveTransitionAndFormatEvidenceV1(value) catch
            return Error.InvalidPreviousEvidence
    else
        null;
    const transition_evidence = if (predecessor) |value|
        transition.validateSuccessorArchiveAndEvidenceV1(
            current,
            value.transition_generation,
        ) catch return Error.InvalidPreviousEvidence
    else
        transition.validateArchiveAndEvidenceV1(current) catch
            return Error.InvalidBinding;
    const manifest_count = std.math.cast(
        usize,
        manifest.entry_count,
    ) orelse return Error.InvalidBatch;
    if ((manifest.generation == 1) != (predecessor == null) or
        deliveries.len == 0 or
        deliveries.len > registry.max_entries or
        deliveries.len != manifest_count)
        return Error.InvalidPreviousEvidence;

    const required = try requiredFormatEvidenceBytesV1(deliveries.len);
    if (destination.len < required) return Error.BufferTooSmall;
    const output = destination[0..required];
    try rejectGenerationOutputAliasV1(current, output);
    if (predecessor) |value| {
        try rejectGenerationOutputAliasV1(
            value.transition_generation,
            output,
        );
        if (slicesOverlap(value.format_evidence, output))
            return Error.BufferAlias;
    }
    for (deliveries) |delivery| {
        if (slicesOverlap(delivery.producer_wire, output))
            return Error.BufferAlias;
    }
    var staging: [max_format_evidence_bytes]u8 = undefined;
    @memset(staging[0..required], 0);
    const record_table = staging[format_batch_header_bytes..required];

    var previous_terminals = [_]Digest{zero_digest} ** 3;
    var previous_batch_sha256 = zero_digest;
    if (previous_decoded) |value| {
        previous_terminals = .{
            value.batch.terminal_image_sha256,
            value.batch.terminal_audio_sha256,
            value.batch.terminal_video_sha256,
        };
        previous_batch_sha256 = value.batch.batch_sha256;
    }
    var terminals = [_]Digest{zero_digest} ** 3;
    var aggregate_raw: u64 = 0;
    var aggregate_encoded: u64 = 0;
    var modality_mask: u64 = 0;
    var first_record = zero_digest;

    for (deliveries, 0..) |delivery, index| {
        const receipt = transition_evidence.receipt(index) catch
            return Error.InvalidBinding;
        const entry = current.registry_archive.entry(index) catch
            return Error.InvalidBinding;
        const payload = current.registry_archive.payload(index) catch
            return Error.InvalidBinding;
        const profile_binding = try validateProfileBindingV1(
            delivery.profile,
            delivery.producer_wire,
            payload,
        );
        const slot = modalitySlot(receipt.modality);
        const input: FormatRecordInputV1 = .{
            .modality = receipt.modality,
            .profile = delivery.profile,
            .registry_ordinal = receipt.registry_ordinal,
            .encoding_abi = entry.encoding_abi,
            .raw_output_bytes = profile_binding.raw_bytes,
            .encoded_payload_bytes = try usizeToU64(payload.len),
            .producer_plan_or_manifest_sha256 = profile_binding.producer_root,
            .raw_output_sha256 = profile_binding.raw_sha256,
            .encoded_payload_sha256 = sha256(payload),
            .registry_payload_sha256 = entry.payload_sha256,
            .encoder_implementation_sha256 = entry.encoder_implementation_sha256,
            .format_contract_sha256 = formatContractSha256V1(delivery.profile),
            .transition_receipt_sha256 = receipt.receipt_sha256,
            .registry_entry_sha256 = entry.entry_sha256,
            .previous_format_record_sha256 = previous_terminals[slot],
            .producer_wire = delivery.producer_wire,
        };
        try validateRecordBindingsV1(
            input,
            receipt,
            entry,
            payload,
        );
        const start = std.math.mul(
            usize,
            index,
            format_record_bytes,
        ) catch return Error.ArithmeticOverflow;
        const end = std.math.add(
            usize,
            start,
            format_record_bytes,
        ) catch return Error.ArithmeticOverflow;
        const encoded_record = try encodeFormatRecordV1(
            input,
            record_table[start..end],
        );
        const record_root =
            encoded_record[format_record_body_bytes..format_record_bytes].*;
        if (index == 0) first_record = record_root;
        previous_terminals[slot] = record_root;
        terminals[slot] = record_root;
        aggregate_raw = checkedAdd(
            aggregate_raw,
            input.raw_output_bytes,
        ) catch return Error.ArithmeticOverflow;
        aggregate_encoded = checkedAdd(
            aggregate_encoded,
            input.encoded_payload_bytes,
        ) catch return Error.ArithmeticOverflow;
        modality_mask |= modalityBit(input.modality);
    }

    const transition_batch = transition_evidence.batch;
    const batch: FormatBatchEvidenceV1 = .{
        .request_epoch = manifest.request_epoch,
        .registry_generation = manifest.generation,
        .publication_sequence = manifest.publication_sequence,
        .record_count = try usizeToU64(deliveries.len),
        .record_table_bytes = try usizeToU64(record_table.len),
        .aggregate_raw_output_bytes = aggregate_raw,
        .aggregate_encoded_payload_bytes = aggregate_encoded,
        .modality_mask = modality_mask,
        .generation_plan_sha256 = manifest.generation_plan_sha256,
        .tenant_scope_sha256 = manifest.tenant_scope_sha256,
        .metadata_policy_sha256 = manifest.metadata_policy_sha256,
        .challenge_sha256 = manifest.challenge_sha256,
        .transition_batch_sha256 = transition_batch.batch_sha256,
        .registry_manifest_sha256 = manifest.manifest_sha256,
        .registry_archive_sha256 = current.registry_archive.archive_sha256,
        .record_table_sha256 = domainRoot(
            format_record_table_domain,
            record_table,
        ),
        .profile_set_sha256 = profileSetSha256V1(),
        .previous_format_batch_sha256 = previous_batch_sha256,
        .first_record_sha256 = first_record,
        .terminal_image_sha256 = terminals[0],
        .terminal_audio_sha256 = terminals[1],
        .terminal_video_sha256 = terminals[2],
        .batch_sha256 = zero_digest,
    };
    try writeBatchHeaderV1(
        batch,
        staging[0..format_batch_header_bytes],
    );
    const decoded = try decodeFormatEvidenceV1(staging[0..required]);
    if (previous_decoded) |value| {
        try validateExactFormatPredecessorV1(decoded, value);
    }
    @memcpy(destination[0..required], staging[0..required]);
    return .{
        .evidence = destination[0..required],
        .batch = decoded.batch,
    };
}

fn rejectGenerationOutputAliasV1(
    generation: transition.PreviousGenerationV1,
    output: []u8,
) Error!void {
    if (slicesOverlap(
        generation.registry_archive.archive_bytes,
        output,
    ) or slicesOverlap(generation.evidence, output))
        return Error.BufferAlias;
}

pub fn validateArchiveTransitionAndFormatEvidenceV1(
    current: PreviousGenerationV1,
) Error!DecodedFormatEvidenceV1 {
    const transition_evidence =
        transition.validateArchiveAndEvidenceV1(
            current.transition_generation,
        ) catch return Error.InvalidBinding;
    const format_evidence = try decodeFormatEvidenceV1(
        current.format_evidence,
    );
    try validateFormatBindingsV1(
        current.transition_generation,
        transition_evidence,
        format_evidence,
    );
    return format_evidence;
}

pub fn validateSuccessorArchiveTransitionAndFormatEvidenceV1(
    current: PreviousGenerationV1,
    predecessor: PreviousGenerationV1,
) Error!DecodedFormatEvidenceV1 {
    const previous_format =
        validateArchiveTransitionAndFormatEvidenceV1(predecessor) catch
            return Error.InvalidPreviousEvidence;
    const current_format =
        validateArchiveTransitionAndFormatEvidenceV1(current) catch
            return Error.InvalidPreviousEvidence;
    _ = transition.validateSuccessorArchiveAndEvidenceV1(
        current.transition_generation,
        predecessor.transition_generation,
    ) catch return Error.InvalidPreviousEvidence;
    try validateExactFormatPredecessorV1(
        current_format,
        previous_format,
    );
    return current_format;
}

const ProfileBindingV1 = struct {
    producer_root: Digest,
    raw_bytes: u64,
    raw_sha256: Digest,
};

fn validateProfileBindingV1(
    profile: DeliveryProfileV1,
    producer_wire: []const u8,
    payload: []const u8,
) Error!ProfileBindingV1 {
    switch (profile) {
        .png => {
            const plan = image.decodeGeneratedImagePlanV1(
                producer_wire,
            ) catch return Error.InvalidBinding;
            const inspection = png_apng.inspectPngV1(payload) catch
                return Error.InvalidBinding;
            if (inspection.width != plan.width or
                inspection.height != plan.height or
                inspection.channels != plan.channels or
                inspection.color_model !=
                    switch (plan.color_model) {
                        .gray => png_apng.ColorModelV1.gray,
                        .rgb => png_apng.ColorModelV1.rgb,
                    } or
                inspection.transfer_function !=
                    switch (plan.transfer_function) {
                        .linear => png_apng.TransferFunctionV1.linear,
                        .srgb => png_apng.TransferFunctionV1.srgb,
                    } or
                inspection.alpha_mode != switch (plan.alpha_mode) {
                    .none => png_apng.AlphaModeV1.none,
                    .straight => png_apng.AlphaModeV1.straight,
                } or
                inspection.raw_bytes != plan.pixel_bytes)
                return Error.InvalidBinding;
            return .{
                .producer_root = plan.plan_sha256,
                .raw_bytes = inspection.raw_bytes,
                .raw_sha256 = inspection.raw_sha256,
            };
        },
        .wave_pcm_s16le => {
            const plan = audio.decodePlanV1(producer_wire) catch
                return Error.InvalidBinding;
            const inspection = wave_pcm.inspectWaveV1(payload) catch
                return Error.InvalidBinding;
            if (inspection.sample_rate != plan.sample_rate or
                inspection.channels != plan.channels or
                inspection.bytes_per_sample != plan.bytes_per_sample or
                inspection.frame_count != plan.frame_count or
                inspection.raw_bytes != plan.pcm_bytes)
                return Error.InvalidBinding;
            return .{
                .producer_root = plan.plan_sha256,
                .raw_bytes = inspection.raw_bytes,
                .raw_sha256 = inspection.raw_sha256,
            };
        },
        .apng_two_frame_gray8 => {
            const manifest = video.decodeManifestV1(
                producer_wire,
            ) catch return Error.InvalidBinding;
            const inspection = png_apng.inspectApngV1(payload) catch
                return Error.InvalidBinding;
            const first_delay = try reducedDelayV1(
                manifest.first_duration_ticks,
                manifest.time_base_numerator,
                manifest.time_base_denominator,
            );
            const second_delay = try reducedDelayV1(
                manifest.second_duration_ticks,
                manifest.time_base_numerator,
                manifest.time_base_denominator,
            );
            if (inspection.width != manifest.width or
                inspection.height != manifest.height or
                inspection.channels != manifest.channels or
                inspection.bytes_per_channel !=
                    manifest.bytes_per_channel or
                inspection.frame_count != manifest.frame_count or
                inspection.frame_bytes != manifest.frame_bytes or
                inspection.raw_bytes != manifest.total_output_bytes or
                inspection.delay_numerators[0] != first_delay[0] or
                inspection.delay_denominators[0] != first_delay[1] or
                inspection.delay_numerators[1] != second_delay[0] or
                inspection.delay_denominators[1] != second_delay[1] or
                !digestEqual(
                    inspection.frame_sha256[0],
                    manifest.first_frame_sha256,
                ) or
                !digestEqual(
                    inspection.frame_sha256[1],
                    manifest.second_frame_sha256,
                ))
                return Error.InvalidBinding;
            return .{
                .producer_root = manifest.manifest_sha256,
                .raw_bytes = inspection.raw_bytes,
                .raw_sha256 = inspection.raw_sha256,
            };
        },
    }
}

fn reducedDelayV1(
    duration_ticks: u64,
    time_base_numerator: u64,
    time_base_denominator: u64,
) Error![2]u16 {
    if (duration_ticks == 0 or
        time_base_numerator == 0 or
        time_base_denominator == 0)
        return Error.InvalidBinding;
    var numerator = std.math.mul(
        u64,
        duration_ticks,
        time_base_numerator,
    ) catch return Error.ArithmeticOverflow;
    var denominator = time_base_denominator;
    const divisor = std.math.gcd(numerator, denominator);
    numerator /= divisor;
    denominator /= divisor;
    return .{
        std.math.cast(u16, numerator) orelse
            return Error.InvalidBinding,
        std.math.cast(u16, denominator) orelse
            return Error.InvalidBinding,
    };
}

fn validateRecordBindingsV1(
    value: FormatRecordInputV1,
    receipt: transition.TransitionReceiptV1,
    entry: registry.GeneratedMediaOutputEntryV1,
    payload: []const u8,
) Error!void {
    const payload_bytes = try usizeToU64(payload.len);
    const payload_sha256 = sha256(payload);
    if (value.modality != receipt.modality or
        value.modality != entry.modality or
        value.registry_ordinal != receipt.registry_ordinal or
        value.registry_ordinal != entry.ordinal or
        value.encoding_abi != entry.encoding_abi or
        value.raw_output_bytes != receipt.raw_output_bytes or
        value.raw_output_bytes != entry.source_bytes or
        value.encoded_payload_bytes !=
            receipt.encoded_payload_bytes or
        value.encoded_payload_bytes != entry.payload_bytes or
        value.encoded_payload_bytes != payload_bytes or
        !digestEqual(
            value.producer_plan_or_manifest_sha256,
            receipt.producer_plan_or_manifest_sha256,
        ) or
        !digestEqual(
            value.raw_output_sha256,
            receipt.raw_output_sha256,
        ) or
        !digestEqual(
            value.raw_output_sha256,
            entry.source_output_sha256,
        ) or
        !digestEqual(value.encoded_payload_sha256, payload_sha256) or
        !digestEqual(
            value.encoded_payload_sha256,
            receipt.encoded_payload_sha256,
        ) or
        !digestEqual(
            value.registry_payload_sha256,
            entry.payload_sha256,
        ) or
        !digestEqual(
            value.encoder_implementation_sha256,
            receipt.encoder_implementation_sha256,
        ) or
        !digestEqual(
            value.encoder_implementation_sha256,
            entry.encoder_implementation_sha256,
        ) or
        !digestEqual(
            value.format_contract_sha256,
            receipt.format_sha256,
        ) or
        !digestEqual(
            value.format_contract_sha256,
            entry.format_sha256,
        ) or
        !digestEqual(
            value.transition_receipt_sha256,
            receipt.receipt_sha256,
        ) or
        !digestEqual(
            value.registry_entry_sha256,
            entry.entry_sha256,
        ))
        return Error.InvalidBinding;
}

fn validateFormatBindingsV1(
    generation: transition.PreviousGenerationV1,
    transition_evidence: transition.DecodedBatchEvidenceV1,
    format_evidence: DecodedFormatEvidenceV1,
) Error!void {
    const manifest = generation.registry_archive.manifest;
    const batch = format_evidence.batch;
    const transition_batch = transition_evidence.batch;
    if (batch.request_epoch != manifest.request_epoch or
        batch.registry_generation != manifest.generation or
        batch.publication_sequence != manifest.publication_sequence or
        batch.record_count != manifest.entry_count or
        batch.record_count != transition_batch.receipt_count or
        batch.aggregate_raw_output_bytes !=
            transition_batch.aggregate_raw_output_bytes or
        batch.aggregate_encoded_payload_bytes !=
            transition_batch.aggregate_encoded_payload_bytes or
        batch.modality_mask != manifest.modality_mask or
        !digestEqual(
            batch.generation_plan_sha256,
            manifest.generation_plan_sha256,
        ) or
        !digestEqual(
            batch.tenant_scope_sha256,
            manifest.tenant_scope_sha256,
        ) or
        !digestEqual(
            batch.metadata_policy_sha256,
            manifest.metadata_policy_sha256,
        ) or
        !digestEqual(
            batch.challenge_sha256,
            manifest.challenge_sha256,
        ) or
        !digestEqual(
            batch.transition_batch_sha256,
            transition_batch.batch_sha256,
        ) or
        !digestEqual(
            batch.registry_manifest_sha256,
            manifest.manifest_sha256,
        ) or
        !digestEqual(
            batch.registry_archive_sha256,
            generation.registry_archive.archive_sha256,
        ))
        return Error.InvalidBinding;

    const count = std.math.cast(
        usize,
        batch.record_count,
    ) orelse return Error.InvalidBatch;
    for (0..count) |index| {
        const record = format_evidence.record(index) catch
            return Error.InvalidRecord;
        const receipt = transition_evidence.receipt(index) catch
            return Error.InvalidBinding;
        const entry = generation.registry_archive.entry(index) catch
            return Error.InvalidBinding;
        const payload = generation.registry_archive.payload(index) catch
            return Error.InvalidBinding;
        const profile_binding = try validateProfileBindingV1(
            record.profile,
            record.producer_wire,
            payload,
        );
        const input: FormatRecordInputV1 = .{
            .modality = record.modality,
            .profile = record.profile,
            .registry_ordinal = record.registry_ordinal,
            .encoding_abi = record.encoding_abi,
            .raw_output_bytes = record.raw_output_bytes,
            .encoded_payload_bytes = record.encoded_payload_bytes,
            .producer_plan_or_manifest_sha256 = record.producer_plan_or_manifest_sha256,
            .raw_output_sha256 = record.raw_output_sha256,
            .encoded_payload_sha256 = record.encoded_payload_sha256,
            .registry_payload_sha256 = record.registry_payload_sha256,
            .encoder_implementation_sha256 = record.encoder_implementation_sha256,
            .format_contract_sha256 = record.format_contract_sha256,
            .transition_receipt_sha256 = record.transition_receipt_sha256,
            .registry_entry_sha256 = record.registry_entry_sha256,
            .previous_format_record_sha256 = record.previous_format_record_sha256,
            .producer_wire = record.producer_wire,
        };
        if (!digestEqual(
            profile_binding.producer_root,
            record.producer_plan_or_manifest_sha256,
        ) or
            profile_binding.raw_bytes != record.raw_output_bytes or
            !digestEqual(
                profile_binding.raw_sha256,
                record.raw_output_sha256,
            ))
            return Error.InvalidBinding;
        try validateRecordBindingsV1(
            input,
            receipt,
            entry,
            payload,
        );
    }
}

fn validateExactFormatPredecessorV1(
    current: DecodedFormatEvidenceV1,
    predecessor: DecodedFormatEvidenceV1,
) Error!void {
    if (!digestEqual(
        current.batch.previous_format_batch_sha256,
        predecessor.batch.batch_sha256,
    )) return Error.InvalidPreviousEvidence;
    var expected = [_]Digest{
        predecessor.batch.terminal_image_sha256,
        predecessor.batch.terminal_audio_sha256,
        predecessor.batch.terminal_video_sha256,
    };
    var seen = [_]bool{false} ** 3;
    const count = std.math.cast(
        usize,
        current.batch.record_count,
    ) orelse return Error.InvalidPreviousEvidence;
    for (0..count) |index| {
        const record = current.record(index) catch
            return Error.InvalidPreviousEvidence;
        const slot = modalitySlot(record.modality);
        if (!seen[slot]) {
            if (!digestEqual(
                record.previous_format_record_sha256,
                expected[slot],
            )) return Error.InvalidPreviousEvidence;
            seen[slot] = true;
        }
        expected[slot] = record.record_sha256;
    }
}

fn sha256(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

fn domainRoot(
    domain: []const u8,
    bytes: []const u8,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(domain);
    hasher.update(bytes);
    var result: Digest = undefined;
    hasher.final(&result);
    return result;
}

fn modalitySlot(modality: registry.ModalityV1) usize {
    return switch (modality) {
        .image => 0,
        .audio => 1,
        .video => 2,
    };
}

fn modalityBit(modality: registry.ModalityV1) u64 {
    return @as(u64, 1) << @intCast(modalitySlot(modality));
}

fn checkedAdd(a: anytype, b: @TypeOf(a)) !@TypeOf(a) {
    return std.math.add(@TypeOf(a), a, b) catch
        return Error.ArithmeticOverflow;
}

fn usizeToU64(value: usize) Error!u64 {
    return std.math.cast(u64, value) orelse
        return Error.ArithmeticOverflow;
}

fn u64ToUsize(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse
        return Error.ArithmeticOverflow;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn slicesOverlap(
    immutable: []const u8,
    mutable: []u8,
) bool {
    if (immutable.len == 0 or mutable.len == 0) return false;
    const immutable_start = @intFromPtr(immutable.ptr);
    const mutable_start = @intFromPtr(mutable.ptr);
    const immutable_end = std.math.add(
        usize,
        immutable_start,
        immutable.len,
    ) catch return true;
    const mutable_end = std.math.add(
        usize,
        mutable_start,
        mutable.len,
    ) catch return true;
    return immutable_start < mutable_end and
        mutable_start < immutable_end;
}

fn isZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn writeU64(destination: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(
        u64,
        destination[offset .. offset + 8][0..8],
        value,
        .little,
    );
}

fn readU64(source: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        source[offset .. offset + 8][0..8],
        .little,
    );
}

fn testDigest(label: []const u8) Digest {
    return sha256(label);
}

fn testRecordInput(
    modality: registry.ModalityV1,
    profile: DeliveryProfileV1,
    ordinal: u64,
    previous: Digest,
    producer_wire: []const u8,
) FormatRecordInputV1 {
    return .{
        .modality = modality,
        .profile = profile,
        .registry_ordinal = ordinal,
        .encoding_abi = encodingAbiV1(profile),
        .raw_output_bytes = 4,
        .encoded_payload_bytes = 48,
        .producer_plan_or_manifest_sha256 = producerWireRootV1(
            modality,
            producer_wire,
        ) catch unreachable,
        .raw_output_sha256 = testDigest("raw"),
        .encoded_payload_sha256 = testDigest("payload"),
        .registry_payload_sha256 = testDigest("payload"),
        .encoder_implementation_sha256 = testDigest("encoder"),
        .format_contract_sha256 = formatContractSha256V1(profile),
        .transition_receipt_sha256 = testDigest("transition"),
        .registry_entry_sha256 = testDigest("entry"),
        .previous_format_record_sha256 = previous,
        .producer_wire = producer_wire,
    };
}

fn makeTestImagePlanWire(
    storage: *[image.plan_bytes]u8,
) ![]const u8 {
    const one = testDigest("test-image-plan");
    var plan: image.GeneratedImagePlanV1 = .{
        .request_epoch = 1,
        .generation = 1,
        .image_index = 1,
        .source_step = 1,
        .width = 2,
        .height = 2,
        .channels = 1,
        .row_stride = 2,
        .latent_bytes = 1,
        .pixel_bytes = 4,
        .maximum_output_bytes = 4,
        .decoder_abi = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
        .publication_sequence = 1,
        .visible_images_before = 0,
        .visible_images_after = 1,
        .logical_units = 1,
        .required_capabilities = 0,
        .artifact_sha256 = one,
        .terminal_result_sha256 = one,
        .terminal_plan_sha256 = one,
        .terminal_output_sha256 = one,
        .terminal_state_publication_sha256 = one,
        .stateful_checkpoint_sha256 = one,
        .decoder_payload_sha256 = one,
        .decoder_implementation_sha256 = one,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .source_provenance_sha256 = one,
        .challenge_sha256 = one,
        .previous_plan_sha256 = one,
        .previous_result_sha256 = one,
        .media_object_sha256 = one,
        .plan_sha256 = zero_digest,
    };
    plan.plan_sha256 = image.generatedImagePlanRootV1(plan);
    return image.encodeGeneratedImagePlanV1(plan, storage);
}

test "format record is canonical and failed preflight leaves destination unchanged" {
    var producer_wire_storage: [image.plan_bytes]u8 = undefined;
    const producer_wire = try makeTestImagePlanWire(
        &producer_wire_storage,
    );
    const input = testRecordInput(
        .image,
        .png,
        0,
        zero_digest,
        producer_wire,
    );
    var destination = [_]u8{0xa5} ** format_record_bytes;
    const encoded = try encodeFormatRecordV1(input, &destination);
    const decoded = try decodeFormatRecordV1(encoded);
    try std.testing.expectEqual(registry.ModalityV1.image, decoded.modality);
    try std.testing.expectEqual(DeliveryProfileV1.png, decoded.profile);
    try std.testing.expectEqual(@as(u64, 0), decoded.registry_ordinal);
    try std.testing.expectEqualSlices(
        u8,
        producer_wire,
        decoded.producer_wire,
    );

    var invalid = input;
    invalid.encoding_abi = 0;
    @memset(&destination, 0xb6);
    try std.testing.expectError(
        Error.InvalidRecord,
        encodeFormatRecordV1(invalid, &destination),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &destination,
        0xb6,
    ));

    var aliased = [_]u8{0} ** format_record_bytes;
    @memcpy(aliased[0..image.plan_bytes], producer_wire);
    const aliased_before = aliased;
    const aliased_input = testRecordInput(
        .image,
        .png,
        0,
        zero_digest,
        aliased[0..image.plan_bytes],
    );
    try std.testing.expectError(
        Error.BufferAlias,
        encodeFormatRecordV1(aliased_input, &aliased),
    );
    try std.testing.expectEqualSlices(
        u8,
        &aliased_before,
        &aliased,
    );
}

test "format evidence binds sorted records and every byte is covered" {
    var image_wire_storage: [image.plan_bytes]u8 = undefined;
    const image_wire = try makeTestImagePlanWire(
        &image_wire_storage,
    );
    const required = try requiredFormatEvidenceBytesV1(3);
    var encoded: [
        format_batch_header_bytes + 3 * format_record_bytes
    ]u8 = undefined;
    try std.testing.expectEqual(required, encoded.len);
    @memset(&encoded, 0);
    const records = encoded[format_batch_header_bytes..];
    var terminals = [_]Digest{zero_digest} ** 3;
    var previous = zero_digest;
    var first = zero_digest;
    for (0..3) |index| {
        const input = testRecordInput(
            .image,
            .png,
            index,
            previous,
            image_wire,
        );
        const start = index * format_record_bytes;
        const end = start + format_record_bytes;
        const record = try encodeFormatRecordV1(
            input,
            records[start..end],
        );
        previous =
            record[format_record_body_bytes..format_record_bytes].*;
        if (index == 0) first = previous;
        terminals[modalitySlot(input.modality)] = previous;
    }
    const batch: FormatBatchEvidenceV1 = .{
        .request_epoch = 17,
        .registry_generation = 1,
        .publication_sequence = 9,
        .record_count = 3,
        .record_table_bytes = records.len,
        .aggregate_raw_output_bytes = 12,
        .aggregate_encoded_payload_bytes = 144,
        .modality_mask = 0x1,
        .generation_plan_sha256 = testDigest("generation"),
        .tenant_scope_sha256 = testDigest("tenant"),
        .metadata_policy_sha256 = testDigest("policy"),
        .challenge_sha256 = testDigest("challenge"),
        .transition_batch_sha256 = testDigest("transition-batch"),
        .registry_manifest_sha256 = testDigest("manifest"),
        .registry_archive_sha256 = testDigest("archive"),
        .record_table_sha256 = domainRoot(
            format_record_table_domain,
            records,
        ),
        .profile_set_sha256 = profileSetSha256V1(),
        .previous_format_batch_sha256 = zero_digest,
        .first_record_sha256 = first,
        .terminal_image_sha256 = terminals[0],
        .terminal_audio_sha256 = terminals[1],
        .terminal_video_sha256 = terminals[2],
        .batch_sha256 = zero_digest,
    };
    try writeBatchHeaderV1(
        batch,
        encoded[0..format_batch_header_bytes],
    );
    const decoded = try decodeFormatEvidenceV1(&encoded);
    try std.testing.expectEqual(@as(u64, 3), decoded.batch.record_count);
    try std.testing.expectEqual(
        DeliveryProfileV1.png,
        (try decoded.record(2)).profile,
    );

    for (0..encoded.len) |offset| {
        var mutated = encoded;
        mutated[offset] ^= 1;
        if (decodeFormatEvidenceV1(&mutated)) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
    for (0..encoded.len) |length| {
        if (decodeFormatEvidenceV1(encoded[0..length])) |_| {
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "audio and video producer wires bind canonical WAVE and APNG payloads" {
    const one = testDigest("producer-profile-binding");
    const audio_raw = [_]u8{ 0x00, 0x01, 0x00, 0xff };
    var audio_plan: audio.GeneratedAudioPlanV1 = .{
        .request_epoch = 1,
        .generation = 1,
        .chunk_index = 1,
        .start_frame = 0,
        .frame_count = 2,
        .sample_rate = 16_000,
        .channels = 1,
        .bytes_per_sample = 2,
        .source_output_bytes = 1,
        .pcm_bytes = audio_raw.len,
        .maximum_output_bytes = audio_raw.len,
        .publication_sequence = 1,
        .visible_chunks_before = 1,
        .visible_chunks_after = 2,
        .visible_frames_before = 0,
        .visible_frames_after = 2,
        .logical_units = 2,
        .required_capabilities = 0,
        .renderer_abi = 1,
        .artifact_sha256 = one,
        .source_result_sha256 = one,
        .source_output_sha256 = one,
        .renderer_payload_sha256 = one,
        .renderer_implementation_sha256 = one,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .challenge_sha256 = one,
        .previous_publication_result_sha256 = one,
        .media_object_sha256 = one,
        .state_before_sha256 = one,
        .plan_sha256 = zero_digest,
    };
    audio_plan.plan_sha256 = audio.planRootV1(audio_plan);
    var audio_plan_storage: [audio.plan_bytes]u8 = undefined;
    const audio_plan_wire = try audio.encodePlanV1(
        audio_plan,
        &audio_plan_storage,
    );
    var wave_storage: [128]u8 = undefined;
    const wave_bytes = try wave_pcm.encodeWaveV1(
        .{
            .sample_rate = 16_000,
            .channels = 1,
            .frame_count = 2,
        },
        &audio_raw,
        &wave_storage,
    );
    const audio_binding = try validateProfileBindingV1(
        .wave_pcm_s16le,
        audio_plan_wire,
        wave_bytes,
    );
    try std.testing.expectEqual(
        audio.planRootV1(audio_plan),
        audio_binding.producer_root,
    );
    try std.testing.expectEqual(
        sha256(&audio_raw),
        audio_binding.raw_sha256,
    );

    const first_frame = [_]u8{3} ** 4;
    const second_frame = [_]u8{7} ** 4;
    const video_raw = first_frame ++ second_frame;
    var video_manifest: video.GeneratedVideoManifestV1 = .{
        .request_epoch = 1,
        .generation = 1,
        .segment_index = 0,
        .first_frame_ordinal = 0,
        .frame_count = 2,
        .width = 2,
        .height = 2,
        .channels = 1,
        .bytes_per_channel = 1,
        .row_stride = 2,
        .frame_bytes = 4,
        .total_output_bytes = video_raw.len,
        .time_base_numerator = 1,
        .time_base_denominator = 1_000,
        .start_tick = 0,
        .first_duration_ticks = 2,
        .second_duration_ticks = 3,
        .end_tick = 5,
        .source_output_bytes = 1,
        .maximum_output_bytes = video_raw.len,
        .publication_sequence = 0,
        .visible_segments_before = 0,
        .visible_segments_after = 1,
        .visible_frames_before = 0,
        .visible_frames_after = 2,
        .visible_end_tick_before = 0,
        .visible_end_tick_after = 5,
        .logical_units = 8,
        .required_capabilities = 0,
        .renderer_abi = 1,
        .artifact_sha256 = one,
        .source_result_sha256 = one,
        .source_output_sha256 = one,
        .renderer_payload_sha256 = one,
        .renderer_implementation_sha256 = one,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .challenge_sha256 = one,
        .previous_publication_result_sha256 = zero_digest,
        .media_object_sha256 = one,
        .state_before_sha256 = one,
        .first_frame_sha256 = sha256(&first_frame),
        .second_frame_sha256 = sha256(&second_frame),
        .manifest_sha256 = zero_digest,
    };
    video_manifest.manifest_sha256 =
        video.manifestRootV1(video_manifest);
    var video_manifest_storage: [video.manifest_bytes]u8 = undefined;
    const video_manifest_wire = try video.encodeManifestV1(
        video_manifest,
        &video_manifest_storage,
    );
    var apng_storage: [512]u8 = undefined;
    const apng_bytes = try png_apng.encodeApngV1(
        .{
            .width = 2,
            .height = 2,
            .time_base_numerator = 1,
            .time_base_denominator = 1_000,
            .first_duration_ticks = 2,
            .second_duration_ticks = 3,
        },
        &video_raw,
        &apng_storage,
    );
    const video_binding = try validateProfileBindingV1(
        .apng_two_frame_gray8,
        video_manifest_wire,
        apng_bytes,
    );
    try std.testing.expectEqual(
        video.manifestRootV1(video_manifest),
        video_binding.producer_root,
    );
    try std.testing.expectEqual(
        sha256(&video_raw),
        video_binding.raw_sha256,
    );
}

fn testHashU64(
    hasher: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hasher.update(&encoded);
}

fn testMaterializerExecutionRoot(
    receipt: transition.TransitionReceiptV1,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(
        "glacier-generated-media-producer-transition-" ++
            "materializer-execution-v1\x00",
    );
    testHashU64(&hasher, @intFromEnum(receipt.modality));
    inline for (.{
        receipt.producer_plan_or_manifest_sha256,
        receipt.model_output_sha256,
        receipt.materializer_payload_sha256,
        receipt.materializer_implementation_sha256,
        receipt.raw_output_sha256,
    }) |digest| hasher.update(&digest);
    testHashU64(
        &hasher,
        receipt.materializer_required_capabilities,
    );
    testHashU64(&hasher, receipt.model_output_bytes);
    testHashU64(&hasher, receipt.materializer_payload_bytes);
    testHashU64(&hasher, receipt.raw_output_bytes);
    return hasher.finalResult();
}

fn testProducerProjectionRoot(
    receipt: transition.TransitionReceiptV1,
) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(
        "glacier-generated-media-producer-transition-" ++
            "producer-projection-v1\x00",
    );
    inline for (.{
        @intFromEnum(receipt.modality),
        receipt.producer_generation,
        receipt.producer_ordinal,
        receipt.registry_ordinal,
        receipt.unit_start,
        receipt.unit_count,
        receipt.timeline_start,
        receipt.timeline_end,
        receipt.raw_output_bytes,
        @intFromEnum(receipt.completion_kind),
    }) |scalar| testHashU64(&hasher, scalar);
    inline for (.{
        receipt.artifact_manifest_sha256,
        receipt.producer_plan_or_manifest_sha256,
        receipt.provenance_sha256,
        receipt.publication_result_sha256,
        receipt.raw_output_sha256,
        receipt.producer_state_before_sha256,
        receipt.producer_state_after_publication_sha256,
        receipt.completion_observation_sha256,
        receipt.completion_plan_sha256,
        receipt.completion_result_sha256,
        receipt.producer_final_state_sha256,
        receipt.tenant_scope_sha256,
        receipt.metadata_policy_sha256,
        receipt.challenge_sha256,
    }) |digest| hasher.update(&digest);
    return hasher.finalResult();
}

fn testTransitionTableRoot(bytes: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(
        "glacier-generated-media-producer-transition-" ++
            "receipt-table-v1\x00",
    );
    hasher.update(bytes);
    return hasher.finalResult();
}

test "conformance sidecar validates a real registry and transition pair" {
    const one = testDigest("one");
    const raw = [_]u8{ 0x20, 0x30, 0x30, 0x20 };
    const raw_sha256 = sha256(&raw);
    const image_spec: png_apng.ImageSpecV1 = .{
        .width = 2,
        .height = 2,
        .channels = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
    };
    var png_storage: [256]u8 = undefined;
    const png_bytes = try png_apng.encodePngV1(
        image_spec,
        &raw,
        &png_storage,
    );
    const encoded_sha256 = sha256(png_bytes);

    var image_plan: image.GeneratedImagePlanV1 = .{
        .request_epoch = 9,
        .generation = 1,
        .image_index = 1,
        .source_step = 1,
        .width = 2,
        .height = 2,
        .channels = 1,
        .row_stride = 2,
        .latent_bytes = 1,
        .pixel_bytes = raw.len,
        .maximum_output_bytes = raw.len,
        .decoder_abi = 1,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
        .publication_sequence = 1,
        .visible_images_before = 0,
        .visible_images_after = 1,
        .logical_units = 1,
        .required_capabilities = 0,
        .artifact_sha256 = one,
        .terminal_result_sha256 = one,
        .terminal_plan_sha256 = one,
        .terminal_output_sha256 = one,
        .terminal_state_publication_sha256 = one,
        .stateful_checkpoint_sha256 = one,
        .decoder_payload_sha256 = one,
        .decoder_implementation_sha256 = one,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .source_provenance_sha256 = one,
        .challenge_sha256 = one,
        .previous_plan_sha256 = one,
        .previous_result_sha256 = one,
        .media_object_sha256 = one,
        .plan_sha256 = zero_digest,
    };
    image_plan.plan_sha256 =
        image.generatedImagePlanRootV1(image_plan);
    var plan_storage: [image.plan_bytes]u8 = undefined;
    const plan_wire = try image.encodeGeneratedImagePlanV1(
        image_plan,
        &plan_storage,
    );

    const encoder_sha256 = testDigest("png-encoder");
    const format_sha256 = formatContractSha256V1(.png);
    const registry_outputs = [_]registry.OutputInputV1{.{
        .modality = .image,
        .ordinal = 0,
        .unit_start = 0,
        .unit_count = 1,
        .timeline_start = 0,
        .timeline_end = 1,
        .source_bytes = raw.len,
        .encoding_abi = png_apng.png_encoding_abi,
        .encoded_payload = png_bytes,
        .artifact_sha256 = one,
        .provenance_sha256 = one,
        .result_sha256 = one,
        .source_output_sha256 = raw_sha256,
        .media_object_sha256 = one,
        .state_after_sha256 = one,
        .completion_required = false,
        .completed = true,
        .completion_sha256 = zero_digest,
        .encoder_implementation_sha256 = encoder_sha256,
        .format_sha256 = format_sha256,
        .previous_entry_sha256 = zero_digest,
    }};
    const registry_input: registry.RegistryInputV1 = .{
        .previous = null,
        .request_epoch = 9,
        .generation = 1,
        .publication_sequence = 1,
        .generation_plan_sha256 = one,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .challenge_sha256 = one,
        .outputs = &registry_outputs,
    };
    const registry_scratch_bytes =
        try registry.requiredScratchBytesV1(&registry_outputs);
    var registry_scratch: [4 * 1024]u8 = undefined;
    var registry_archive_storage: [16 * 1024]u8 = undefined;
    const prepared_registry = try registry.encodeArchiveV1(
        registry_input,
        registry_scratch[0..registry_scratch_bytes],
        &registry_archive_storage,
    );
    const decoded_registry = try registry.decodeArchiveV1(
        prepared_registry.set.bytes,
        null,
    );
    const entry = try decoded_registry.entry(0);

    var receipt: transition.TransitionReceiptV1 = .{
        .modality = .image,
        .model_kind = .stateful,
        .completion_kind = .none,
        .request_epoch = 9,
        .producer_generation = 1,
        .producer_ordinal = 1,
        .registry_ordinal = 0,
        .unit_start = 0,
        .unit_count = 1,
        .timeline_start = 0,
        .timeline_end = 1,
        .weights_bytes = 1,
        .model_input_bytes = 1,
        .model_state_before_bytes = 1,
        .model_output_bytes = 1,
        .model_state_after_bytes = 1,
        .materializer_payload_bytes = 1,
        .raw_output_bytes = raw.len,
        .encoded_payload_bytes = png_bytes.len,
        .producer_publication_sequence = 1,
        .completion_sequence = 0,
        .model_required_capabilities = 0,
        .materializer_required_capabilities = 0,
        .model_step_before = 0,
        .model_step_after = 1,
        .producer_state_generation_before = 0,
        .producer_state_generation_after_publication = 1,
        .producer_state_generation_after_completion = 1,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .challenge_sha256 = one,
        .generation_plan_sha256 = one,
        .artifact_manifest_sha256 = one,
        .adapter_descriptor_sha256 = one,
        .support_set_sha256 = one,
        .model_plan_sha256 = one,
        .model_publication_before_sha256 = one,
        .model_state_publication_before_sha256 = one,
        .weights_sha256 = one,
        .model_input_sha256 = one,
        .model_state_before_sha256 = one,
        .model_output_sha256 = one,
        .model_state_after_sha256 = one,
        .model_transition_or_source_mapping_sha256 = one,
        .model_result_sha256 = one,
        .model_publication_after_sha256 = one,
        .model_state_publication_after_sha256 = one,
        .producer_plan_or_manifest_sha256 = image_plan.plan_sha256,
        .producer_state_before_sha256 = one,
        .media_object_sha256 = one,
        .materializer_payload_sha256 = one,
        .materializer_implementation_sha256 = one,
        .materializer_execution_sha256 = zero_digest,
        .raw_output_sha256 = raw_sha256,
        .provenance_sha256 = one,
        .producer_receipt_wire_sha256 = one,
        .producer_resource_sha256 = one,
        .publication_result_sha256 = one,
        .producer_state_after_publication_sha256 = one,
        .completion_observation_sha256 = zero_digest,
        .completion_plan_sha256 = zero_digest,
        .completion_result_sha256 = zero_digest,
        .producer_final_state_sha256 = one,
        .encoder_implementation_sha256 = encoder_sha256,
        .format_sha256 = format_sha256,
        .encoded_payload_sha256 = encoded_sha256,
        .previous_transition_receipt_sha256 = zero_digest,
        .producer_projection_sha256 = zero_digest,
        .registry_previous_entry_sha256 = zero_digest,
        .registry_entry_sha256 = entry.entry_sha256,
        .registry_manifest_sha256 = decoded_registry.manifest.manifest_sha256,
        .registry_archive_sha256 = decoded_registry.archive_sha256,
        .receipt_sha256 = zero_digest,
    };
    receipt.materializer_execution_sha256 =
        testMaterializerExecutionRoot(receipt);
    receipt.producer_projection_sha256 =
        testProducerProjectionRoot(receipt);
    var receipt_storage: [
        transition.transition_receipt_bytes
    ]u8 = undefined;
    const receipt_wire = try transition.encodeTransitionReceiptV1(
        receipt,
        &receipt_storage,
    );
    receipt = try transition.decodeTransitionReceiptV1(receipt_wire);

    const transition_batch: transition.BatchEvidenceV1 = .{
        .request_epoch = 9,
        .registry_generation = 1,
        .publication_sequence = 1,
        .receipt_count = 1,
        .receipt_table_bytes = receipt_wire.len,
        .aggregate_model_input_bytes = 1,
        .aggregate_model_output_bytes = 1,
        .aggregate_state_transition_bytes = 2,
        .aggregate_materializer_payload_bytes = 1,
        .aggregate_raw_output_bytes = raw.len,
        .aggregate_encoded_payload_bytes = png_bytes.len,
        .modality_mask = 1,
        .generation_plan_sha256 = one,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .challenge_sha256 = one,
        .receipt_table_sha256 = testTransitionTableRoot(receipt_wire),
        .previous_batch_sha256 = zero_digest,
        .registry_manifest_sha256 = decoded_registry.manifest.manifest_sha256,
        .registry_archive_sha256 = decoded_registry.archive_sha256,
        .first_receipt_sha256 = receipt.receipt_sha256,
        .terminal_image_sha256 = receipt.receipt_sha256,
        .terminal_audio_sha256 = zero_digest,
        .terminal_video_sha256 = zero_digest,
        .batch_sha256 = zero_digest,
    };
    var transition_evidence_storage: [
        transition.batch_header_bytes +
            transition.transition_receipt_bytes
    ]u8 = undefined;
    const transition_evidence =
        try transition.encodeBatchEvidenceV1(
            transition_batch,
            receipt_wire,
            &transition_evidence_storage,
        );
    const transition_generation: transition.PreviousGenerationV1 = .{
        .registry_archive = decoded_registry,
        .evidence = transition_evidence,
    };
    _ = try transition.validateArchiveAndEvidenceV1(
        transition_generation,
    );

    const deliveries = [_]DeliveryV1{.{
        .profile = .png,
        .producer_wire = plan_wire,
    }};
    var format_evidence_storage: [
        format_batch_header_bytes + format_record_bytes
    ]u8 = undefined;
    const prepared = try encodeConformantArchiveAndEvidenceV1(
        transition_generation,
        null,
        &deliveries,
        &format_evidence_storage,
    );
    const validated =
        try validateArchiveTransitionAndFormatEvidenceV1(.{
            .transition_generation = transition_generation,
            .format_evidence = prepared.evidence,
        });
    const format_record = try validated.record(0);
    try std.testing.expectEqual(
        entry.payload_sha256,
        format_record.registry_payload_sha256,
    );
    try std.testing.expectEqual(
        encoded_sha256,
        format_record.encoded_payload_sha256,
    );
    try std.testing.expect(!digestEqual(
        format_record.registry_payload_sha256,
        format_record.encoded_payload_sha256,
    ));

    var rejected_destination = [_]u8{0xdc} **
        (format_batch_header_bytes + format_record_bytes);
    const wrong_delivery = [_]DeliveryV1{.{
        .profile = .wave_pcm_s16le,
        .producer_wire = plan_wire,
    }};
    try std.testing.expectError(
        Error.InvalidBinding,
        encodeConformantArchiveAndEvidenceV1(
            transition_generation,
            null,
            &wrong_delivery,
            &rejected_destination,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &rejected_destination,
        0xdc,
    ));

    const generation_two = testDigest("generation-two");
    const raw_two = [_]u8{ 0x21, 0x31, 0x31, 0x21 };
    const raw_two_sha256 = sha256(&raw_two);
    var png_two_storage: [256]u8 = undefined;
    const png_two = try png_apng.encodePngV1(
        image_spec,
        &raw_two,
        &png_two_storage,
    );
    const encoded_two_sha256 = sha256(png_two);
    var image_plan_two = image_plan;
    image_plan_two.generation = 2;
    image_plan_two.image_index = 2;
    image_plan_two.source_step = 2;
    image_plan_two.publication_sequence = 2;
    image_plan_two.visible_images_before = 1;
    image_plan_two.visible_images_after = 2;
    image_plan_two.previous_plan_sha256 = image_plan.plan_sha256;
    image_plan_two.plan_sha256 = zero_digest;
    image_plan_two.plan_sha256 =
        image.generatedImagePlanRootV1(image_plan_two);
    var plan_two_storage: [image.plan_bytes]u8 = undefined;
    const plan_two_wire = try image.encodeGeneratedImagePlanV1(
        image_plan_two,
        &plan_two_storage,
    );
    const registry_outputs_two = [_]registry.OutputInputV1{.{
        .modality = .image,
        .ordinal = 1,
        .unit_start = 1,
        .unit_count = 1,
        .timeline_start = 1,
        .timeline_end = 2,
        .source_bytes = raw_two.len,
        .encoding_abi = png_apng.png_encoding_abi,
        .encoded_payload = png_two,
        .artifact_sha256 = one,
        .provenance_sha256 = one,
        .result_sha256 = one,
        .source_output_sha256 = raw_two_sha256,
        .media_object_sha256 = one,
        .state_after_sha256 = one,
        .completion_required = false,
        .completed = true,
        .completion_sha256 = zero_digest,
        .encoder_implementation_sha256 = encoder_sha256,
        .format_sha256 = format_sha256,
        .previous_entry_sha256 = entry.entry_sha256,
    }};
    const registry_input_two: registry.RegistryInputV1 = .{
        .previous = decoded_registry.previous(),
        .request_epoch = 9,
        .generation = 2,
        .publication_sequence = 2,
        .generation_plan_sha256 = generation_two,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .challenge_sha256 = one,
        .outputs = &registry_outputs_two,
    };
    const registry_two_scratch_bytes =
        try registry.requiredScratchBytesV1(&registry_outputs_two);
    var registry_two_scratch: [4 * 1024]u8 = undefined;
    var registry_two_archive_storage: [16 * 1024]u8 = undefined;
    const prepared_registry_two = try registry.encodeArchiveV1(
        registry_input_two,
        registry_two_scratch[0..registry_two_scratch_bytes],
        &registry_two_archive_storage,
    );
    const decoded_registry_two = try registry.decodeArchiveV1(
        prepared_registry_two.set.bytes,
        decoded_registry.previous(),
    );
    const entry_two = try decoded_registry_two.entry(0);

    var receipt_two = receipt;
    receipt_two.producer_generation = 2;
    receipt_two.registry_ordinal = 1;
    receipt_two.unit_start = 1;
    receipt_two.timeline_start = 1;
    receipt_two.timeline_end = 2;
    receipt_two.raw_output_bytes = raw_two.len;
    receipt_two.encoded_payload_bytes = png_two.len;
    receipt_two.producer_publication_sequence = 2;
    receipt_two.generation_plan_sha256 = generation_two;
    receipt_two.producer_plan_or_manifest_sha256 =
        image_plan_two.plan_sha256;
    receipt_two.raw_output_sha256 = raw_two_sha256;
    receipt_two.encoded_payload_sha256 = encoded_two_sha256;
    receipt_two.previous_transition_receipt_sha256 =
        receipt.receipt_sha256;
    receipt_two.registry_previous_entry_sha256 = entry.entry_sha256;
    receipt_two.registry_entry_sha256 = entry_two.entry_sha256;
    receipt_two.registry_manifest_sha256 =
        decoded_registry_two.manifest.manifest_sha256;
    receipt_two.registry_archive_sha256 =
        decoded_registry_two.archive_sha256;
    receipt_two.receipt_sha256 = zero_digest;
    receipt_two.materializer_execution_sha256 =
        testMaterializerExecutionRoot(receipt_two);
    receipt_two.producer_projection_sha256 =
        testProducerProjectionRoot(receipt_two);
    var receipt_two_storage: [
        transition.transition_receipt_bytes
    ]u8 = undefined;
    const receipt_two_wire =
        try transition.encodeTransitionReceiptV1(
            receipt_two,
            &receipt_two_storage,
        );
    receipt_two = try transition.decodeTransitionReceiptV1(
        receipt_two_wire,
    );
    const decoded_transition =
        try transition.decodeBatchEvidenceV1(transition_evidence);
    const transition_batch_two: transition.BatchEvidenceV1 = .{
        .request_epoch = 9,
        .registry_generation = 2,
        .publication_sequence = 2,
        .receipt_count = 1,
        .receipt_table_bytes = receipt_two_wire.len,
        .aggregate_model_input_bytes = 1,
        .aggregate_model_output_bytes = 1,
        .aggregate_state_transition_bytes = 2,
        .aggregate_materializer_payload_bytes = 1,
        .aggregate_raw_output_bytes = raw_two.len,
        .aggregate_encoded_payload_bytes = png_two.len,
        .modality_mask = 1,
        .generation_plan_sha256 = generation_two,
        .tenant_scope_sha256 = one,
        .metadata_policy_sha256 = one,
        .challenge_sha256 = one,
        .receipt_table_sha256 = testTransitionTableRoot(receipt_two_wire),
        .previous_batch_sha256 = decoded_transition.batch.batch_sha256,
        .registry_manifest_sha256 = decoded_registry_two.manifest.manifest_sha256,
        .registry_archive_sha256 = decoded_registry_two.archive_sha256,
        .first_receipt_sha256 = receipt_two.receipt_sha256,
        .terminal_image_sha256 = receipt_two.receipt_sha256,
        .terminal_audio_sha256 = zero_digest,
        .terminal_video_sha256 = zero_digest,
        .batch_sha256 = zero_digest,
    };
    var transition_two_evidence_storage: [
        transition.batch_header_bytes +
            transition.transition_receipt_bytes
    ]u8 = undefined;
    const transition_two_evidence =
        try transition.encodeBatchEvidenceV1(
            transition_batch_two,
            receipt_two_wire,
            &transition_two_evidence_storage,
        );
    const transition_generation_two: transition.PreviousGenerationV1 = .{
        .registry_archive = decoded_registry_two,
        .evidence = transition_two_evidence,
    };
    _ = try transition.validateSuccessorArchiveAndEvidenceV1(
        transition_generation_two,
        transition_generation,
    );

    const deliveries_two = [_]DeliveryV1{.{
        .profile = .png,
        .producer_wire = plan_two_wire,
    }};
    const previous_generation: PreviousGenerationV1 = .{
        .transition_generation = transition_generation,
        .format_evidence = prepared.evidence,
    };
    var format_two_evidence_storage: [
        format_batch_header_bytes + format_record_bytes
    ]u8 = undefined;
    const prepared_two = try encodeConformantArchiveAndEvidenceV1(
        transition_generation_two,
        previous_generation,
        &deliveries_two,
        &format_two_evidence_storage,
    );
    const current_generation: PreviousGenerationV1 = .{
        .transition_generation = transition_generation_two,
        .format_evidence = prepared_two.evidence,
    };
    const validated_two =
        try validateSuccessorArchiveTransitionAndFormatEvidenceV1(
            current_generation,
            previous_generation,
        );
    try std.testing.expectEqual(
        prepared.batch.batch_sha256,
        validated_two.batch.previous_format_batch_sha256,
    );
    try std.testing.expectEqual(
        validated.batch.terminal_image_sha256,
        (try validated_two.record(0))
            .previous_format_record_sha256,
    );
    try std.testing.expectError(
        Error.InvalidPreviousEvidence,
        validateSuccessorArchiveTransitionAndFormatEvidenceV1(
            current_generation,
            current_generation,
        ),
    );

    @memset(&rejected_destination, 0xed);
    try std.testing.expectError(
        Error.InvalidPreviousEvidence,
        encodeConformantArchiveAndEvidenceV1(
            transition_generation_two,
            null,
            &deliveries_two,
            &rejected_destination,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &rejected_destination,
        0xed,
    ));
}
