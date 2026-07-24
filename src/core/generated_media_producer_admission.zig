//! Canonical generated-media producer admission before registry publication.
//!
//! This gateway accepts fixed producer wires and exact raw output bytes,
//! validates their structural bindings, and derives the existing registry V1
//! mapping. It does not prove model execution, encoder correctness, physical
//! playback/display, or producer authorization.

const std = @import("std");
const model = @import("model_contract.zig");
const image = @import("generated_image_publication.zig");
const audio = @import("generated_audio_playback.zig");
const video = @import("generated_video_display.zig");
const checkpoint = @import("generated_media_checkpoint.zig");
const registry = @import("generated_media_output_registry.zig");
const checkpoint_file = @import("continuation_checkpoint_file.zig");
const media = @import("media_contract.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = [32]u8;

pub const Error = registry.Error || error{
    InvalidProducerRecord,
    InvalidProducerBinding,
    InvalidRawOutput,
    InvalidBatch,
    ArithmeticOverflow,
};

pub const ImageProducerRecordV1 = struct {
    plan: []const u8,
    provenance: []const u8,
    result: []const u8,
    raw_output: []const u8,
};

pub const AudioProducerRecordV1 = struct {
    state_after: []const u8,
    plan: []const u8,
    provenance: []const u8,
    result: []const u8,
    acknowledgement: []const u8,
    raw_output: []const u8,
};

pub const VideoProducerRecordV1 = struct {
    state_after: []const u8,
    manifest: []const u8,
    provenance: []const u8,
    result: []const u8,
    acknowledgement: []const u8,
    raw_output: []const u8,
};

pub const ProducerRecordV1 = union(registry.ModalityV1) {
    image: ImageProducerRecordV1,
    audio: AudioProducerRecordV1,
    video: VideoProducerRecordV1,
};

pub const AdmittedOutputV1 = struct {
    producer: ProducerRecordV1,
    encoding_abi: u64,
    encoded_payload: []const u8,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,
};

pub const BatchInputV1 = struct {
    previous: ?registry.DecodedArchiveV1,
    generation_plan_sha256: Digest,
    outputs: []const AdmittedOutputV1,
};

const BatchMetadataV1 = struct {
    request_epoch: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
};

const ProducerAdmissionV1 = struct {
    member: checkpoint.GeneratedMediaProducerProjectionV1,
    state_before_sha256: Digest,
    previous_result_sha256: Digest,
    previous_completion_sha256: Digest,
    requires_completion_lineage: bool,
};

const TerminalV1 = struct {
    ordinal: u64,
    result_sha256: Digest,
    state_after_sha256: Digest,
    completion_sha256: Digest,
    entry_sha256: Digest,
};

const TerminalSetV1 = struct {
    image: ?TerminalV1 = null,
    audio: ?TerminalV1 = null,
    video: ?TerminalV1 = null,

    fn get(
        self: TerminalSetV1,
        modality: registry.ModalityV1,
    ) ?TerminalV1 {
        return switch (modality) {
            .image => self.image,
            .audio => self.audio,
            .video => self.video,
        };
    }

    fn set(
        self: *TerminalSetV1,
        modality: registry.ModalityV1,
        value: TerminalV1,
    ) void {
        switch (modality) {
            .image => self.image = value,
            .audio => self.audio = value,
            .video => self.video = value,
        }
    }
};

const zero_digest = [_]u8{0} ** 32;

pub fn requiredScratchBytesV1(input: BatchInputV1) Error!usize {
    if (input.outputs.len == 0) return Error.InvalidBatch;
    if (input.outputs.len > registry.max_entries)
        return Error.CapacityExceeded;
    var total = std.math.mul(
        usize,
        input.outputs.len,
        registry.entry_bytes,
    ) catch return Error.ArithmeticOverflow;
    for (input.outputs) |output| {
        total = std.math.add(
            usize,
            total,
            output.encoded_payload.len,
        ) catch return Error.ArithmeticOverflow;
    }
    return total;
}

pub fn requiredArchiveBytesV1(input: BatchInputV1) Error!usize {
    var total = std.math.add(
        usize,
        checkpoint_file.set_payload_offset,
        checkpoint_file.set_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(
        usize,
        total,
        registry.manifest_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        total,
        try requiredScratchBytesV1(input),
    ) catch return Error.ArithmeticOverflow;
}

pub fn encodeArchiveV1(
    input: BatchInputV1,
    scratch: []u8,
    destination: []u8,
) Error!registry.PreparedArchiveV1 {
    const required_scratch = try requiredScratchBytesV1(input);
    const required_archive = try requiredArchiveBytesV1(input);
    if (scratch.len < required_scratch or
        destination.len < required_archive)
        return Error.BufferTooSmall;

    var derived_storage: [registry.max_entries]registry.OutputInputV1 = undefined;
    const derived = derived_storage[0..input.outputs.len];
    var terminals = try previousTerminalsV1(input.previous);
    var metadata: ?BatchMetadataV1 = null;
    var payload_offset: u64 = 0;
    var previous_modality: u64 = 0;
    var previous_ordinal: u64 = 0;

    for (input.outputs, 0..) |output, index| {
        const admission = try admitProducerRecordV1(output.producer);
        const member = admission.member;
        const modality = producerModalityV1(output.producer);
        const ordinal = try registryOrdinalV1(modality, member);
        const modality_value = @intFromEnum(modality);
        if (index != 0 and
            (modality_value < previous_modality or
                (modality_value == previous_modality and
                    ordinal <= previous_ordinal)))
            return Error.InvalidBatch;
        previous_modality = modality_value;
        previous_ordinal = ordinal;
        try validateProducerLineageV1(
            modality,
            ordinal,
            admission,
            terminals.get(modality),
        );

        const raw_output = producerRawOutputV1(output.producer);
        const source_bytes = std.math.cast(
            u64,
            raw_output.len,
        ) orelse return Error.ArithmeticOverflow;
        if (source_bytes == 0 or source_bytes != member.byte_count or
            !digestEqual(model.sha256(raw_output), member.output_sha256))
            return Error.InvalidRawOutput;

        const current_metadata: BatchMetadataV1 = .{
            .request_epoch = member.request_epoch,
            .tenant_scope_sha256 = member.tenant_scope_sha256,
            .metadata_policy_sha256 = member.metadata_policy_sha256,
            .challenge_sha256 = member.challenge_sha256,
        };
        if (metadata) |expected| {
            if (!metadataEqual(expected, current_metadata))
                return Error.InvalidBatch;
        } else {
            metadata = current_metadata;
        }

        derived[index] = .{
            .modality = modality,
            .ordinal = ordinal,
            .unit_start = member.unit_start,
            .unit_count = member.unit_count,
            .timeline_start = member.timeline_start,
            .timeline_end = member.timeline_end,
            .source_bytes = source_bytes,
            .encoding_abi = output.encoding_abi,
            .encoded_payload = output.encoded_payload,
            .artifact_sha256 = member.artifact_sha256,
            .provenance_sha256 = member.provenance_sha256,
            .result_sha256 = member.result_sha256,
            .source_output_sha256 = member.output_sha256,
            .media_object_sha256 = member.media_object_sha256,
            .state_after_sha256 = member.state_after_sha256,
            .completion_required = member.completion_required == 1,
            .completed = member.completed == 1,
            .completion_sha256 = member.completion_sha256,
            .encoder_implementation_sha256 = output.encoder_implementation_sha256,
            .format_sha256 = output.format_sha256,
            .previous_entry_sha256 = if (terminals.get(modality)) |terminal|
                terminal.entry_sha256
            else
                zero_digest,
        };
        const entry = registry.deriveEntryV1(
            derived[index],
            payload_offset,
        ) catch |err| return normalizeRegistryError(err);
        terminals.set(modality, .{
            .ordinal = ordinal,
            .result_sha256 = member.result_sha256,
            .state_after_sha256 = member.state_after_sha256,
            .completion_sha256 = member.completion_sha256,
            .entry_sha256 = entry.entry_sha256,
        });
        payload_offset = std.math.add(
            u64,
            payload_offset,
            std.math.cast(
                u64,
                output.encoded_payload.len,
            ) orelse return Error.ArithmeticOverflow,
        ) catch return Error.ArithmeticOverflow;
    }

    const batch_metadata = metadata orelse return Error.InvalidBatch;
    const lineage = try registryLineageV1(input.previous);
    return registry.encodeArchiveV1(
        .{
            .previous = if (input.previous) |value|
                value.previous()
            else
                null,
            .request_epoch = batch_metadata.request_epoch,
            .generation = lineage.generation,
            .publication_sequence = lineage.publication_sequence,
            .generation_plan_sha256 = input.generation_plan_sha256,
            .tenant_scope_sha256 = batch_metadata.tenant_scope_sha256,
            .metadata_policy_sha256 = batch_metadata.metadata_policy_sha256,
            .challenge_sha256 = batch_metadata.challenge_sha256,
            .outputs = derived,
        },
        scratch,
        destination,
    ) catch |err| return normalizeRegistryError(err);
}

fn admitProducerRecordV1(
    producer: ProducerRecordV1,
) Error!ProducerAdmissionV1 {
    return switch (producer) {
        .image => |record| blk: {
            const plan = image.decodeGeneratedImagePlanV1(
                record.plan,
            ) catch return Error.InvalidProducerRecord;
            const provenance =
                image.decodeGeneratedImageProvenanceV1(
                    record.provenance,
                ) catch return Error.InvalidProducerRecord;
            const result = image.decodeGeneratedImageResultV1(
                record.result,
            ) catch return Error.InvalidProducerRecord;
            const member = checkpoint.imageProducerProjectionV1(
                plan,
                provenance,
                result,
            ) catch return Error.InvalidProducerBinding;
            break :blk .{
                .member = member,
                .state_before_sha256 = result.publication_state_before_sha256,
                .previous_result_sha256 = result.previous_result_sha256,
                .previous_completion_sha256 = zero_digest,
                .requires_completion_lineage = false,
            };
        },
        .audio => |record| blk: {
            const state = audio.decodeStateV1(
                record.state_after,
            ) catch return Error.InvalidProducerRecord;
            const plan = audio.decodePlanV1(
                record.plan,
            ) catch return Error.InvalidProducerRecord;
            const provenance = audio.decodeProvenanceV1(
                record.provenance,
            ) catch return Error.InvalidProducerRecord;
            const result = audio.decodeResultV1(
                record.result,
            ) catch return Error.InvalidProducerRecord;
            const acknowledgement =
                audio.decodePlaybackAckResultV1(
                    record.acknowledgement,
                ) catch return Error.InvalidProducerRecord;
            const member = checkpoint.audioProducerProjectionV1(
                state,
                plan,
                provenance,
                result,
                acknowledgement,
            ) catch return Error.InvalidProducerBinding;
            break :blk .{
                .member = member,
                .state_before_sha256 = result.state_before_sha256,
                .previous_result_sha256 = result.previous_publication_result_sha256,
                .previous_completion_sha256 = acknowledgement.previous_ack_result_sha256,
                .requires_completion_lineage = true,
            };
        },
        .video => |record| blk: {
            const state = video.decodeStateV1(
                record.state_after,
            ) catch return Error.InvalidProducerRecord;
            const manifest = video.decodeManifestV1(
                record.manifest,
            ) catch return Error.InvalidProducerRecord;
            const provenance = video.decodeProvenanceV1(
                record.provenance,
            ) catch return Error.InvalidProducerRecord;
            const result = video.decodeResultV1(
                record.result,
            ) catch return Error.InvalidProducerRecord;
            const acknowledgement =
                video.decodeDisplayAckResultV1(
                    record.acknowledgement,
                ) catch return Error.InvalidProducerRecord;
            const member = checkpoint.videoProducerProjectionV1(
                state,
                manifest,
                provenance,
                result,
                acknowledgement,
            ) catch return Error.InvalidProducerBinding;
            break :blk .{
                .member = member,
                .state_before_sha256 = result.state_before_sha256,
                .previous_result_sha256 = result.previous_publication_result_sha256,
                .previous_completion_sha256 = acknowledgement.previous_ack_result_sha256,
                .requires_completion_lineage = true,
            };
        },
    };
}

fn producerModalityV1(
    producer: ProducerRecordV1,
) registry.ModalityV1 {
    return std.meta.activeTag(producer);
}

fn producerRawOutputV1(producer: ProducerRecordV1) []const u8 {
    return switch (producer) {
        .image => |record| record.raw_output,
        .audio => |record| record.raw_output,
        .video => |record| record.raw_output,
    };
}

fn registryOrdinalV1(
    modality: registry.ModalityV1,
    member: checkpoint.GeneratedMediaProducerProjectionV1,
) Error!u64 {
    return switch (modality) {
        .image => {
            const expected_end = std.math.add(
                u64,
                member.unit_start,
                1,
            ) catch return Error.ArithmeticOverflow;
            if (member.ordinal == 0 or member.unit_count != 1 or
                member.ordinal != member.unit_end or
                expected_end != member.unit_end)
                return Error.InvalidProducerBinding;
            return member.ordinal - 1;
        },
        .audio, .video => member.ordinal,
    };
}

fn validateProducerLineageV1(
    modality: registry.ModalityV1,
    ordinal: u64,
    admission: ProducerAdmissionV1,
    previous: ?TerminalV1,
) Error!void {
    if (previous) |value| {
        const expected_ordinal = std.math.add(
            u64,
            value.ordinal,
            1,
        ) catch return Error.ArithmeticOverflow;
        if (ordinal != expected_ordinal or
            !digestEqual(
                admission.previous_result_sha256,
                value.result_sha256,
            ))
            return Error.InvalidProducerBinding;
        if (admission.requires_completion_lineage and
            !digestEqual(
                admission.previous_completion_sha256,
                value.completion_sha256,
            ))
            return Error.InvalidProducerBinding;
        if (!digestEqual(
            admission.state_before_sha256,
            value.state_after_sha256,
        ))
            return Error.InvalidProducerBinding;
        return;
    }
    if (ordinal != 0) return Error.InvalidProducerBinding;
    if (modality != .image and
        (!isZero(admission.previous_result_sha256) or
            !isZero(admission.previous_completion_sha256)))
        return Error.InvalidProducerBinding;
}

const RegistryLineageV1 = struct {
    generation: u64,
    publication_sequence: u64,
};

fn registryLineageV1(
    previous: ?registry.DecodedArchiveV1,
) Error!RegistryLineageV1 {
    if (previous) |value| {
        return .{
            .generation = std.math.add(
                u64,
                value.manifest.generation,
                1,
            ) catch return Error.ArithmeticOverflow,
            .publication_sequence = std.math.add(
                u64,
                value.manifest.publication_sequence,
                1,
            ) catch return Error.ArithmeticOverflow,
        };
    }
    return .{ .generation = 1, .publication_sequence = 1 };
}

fn previousTerminalsV1(
    previous: ?registry.DecodedArchiveV1,
) Error!TerminalSetV1 {
    var terminals: TerminalSetV1 = .{};
    if (previous) |value| {
        inline for ([_]registry.ModalityV1{
            .image,
            .audio,
            .video,
        }) |modality| {
            const terminal = value.terminal(modality) catch |err| switch (err) {
                error.InvalidEntry => null,
                else => return normalizeRegistryError(err),
            };
            if (terminal) |entry|
                terminals.set(modality, .{
                    .ordinal = entry.ordinal,
                    .result_sha256 = entry.result_sha256,
                    .state_after_sha256 = entry.state_after_sha256,
                    .completion_sha256 = entry.completion_sha256,
                    .entry_sha256 = entry.entry_sha256,
                });
        }
    }
    return terminals;
}

fn metadataEqual(
    left: BatchMetadataV1,
    right: BatchMetadataV1,
) bool {
    return left.request_epoch == right.request_epoch and
        digestEqual(
            left.tenant_scope_sha256,
            right.tenant_scope_sha256,
        ) and
        digestEqual(
            left.metadata_policy_sha256,
            right.metadata_policy_sha256,
        ) and
        digestEqual(left.challenge_sha256, right.challenge_sha256);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn normalizeRegistryError(err: registry.Error) Error {
    return switch (err) {
        error.ArithmeticOverflow => Error.ArithmeticOverflow,
        else => err,
    };
}

pub const ReferenceArchivesV1 = struct {
    first: registry.PreparedArchiveV1,
    first_decoded: registry.DecodedArchiveV1,
    second: registry.PreparedArchiveV1,
    second_decoded: registry.DecodedArchiveV1,
};

const ReferenceCommonV1 = struct {
    request_epoch: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
};

const ReferenceImageV1 = struct {
    plan: image.GeneratedImagePlanV1,
    provenance: image.GeneratedImageProvenanceV1,
    result: image.GeneratedImageResultV1,
};

const ReferenceAudioV1 = struct {
    state_after: audio.GeneratedAudioStateV1,
    plan: audio.GeneratedAudioPlanV1,
    provenance: audio.GeneratedAudioProvenanceV1,
    result: audio.GeneratedAudioResultV1,
    acknowledgement: audio.PlaybackAckResultV1,
};

const ReferenceVideoV1 = struct {
    state_after: video.GeneratedVideoStateV1,
    manifest: video.GeneratedVideoManifestV1,
    provenance: video.GeneratedVideoProvenanceV1,
    result: video.GeneratedVideoResultV1,
    acknowledgement: video.DisplayAckResultV1,
};

const ReferenceValuesV1 = struct {
    image: [2]ReferenceImageV1,
    audio: [2]ReferenceAudioV1,
    video: [2]ReferenceVideoV1,
};

const ReferenceWireStorageV1 = struct {
    image_plan: [2][image.plan_bytes]u8,
    image_provenance: [2][image.provenance_bytes]u8,
    image_result: [2][image.result_bytes]u8,
    audio_state: [2][audio.state_bytes]u8,
    audio_plan: [2][audio.plan_bytes]u8,
    audio_provenance: [2][audio.provenance_bytes]u8,
    audio_result: [2][audio.result_bytes]u8,
    audio_acknowledgement: [2][audio.ack_result_bytes]u8,
    video_state: [2][video.state_bytes]u8,
    video_manifest: [2][video.manifest_bytes]u8,
    video_provenance: [2][video.provenance_bytes]u8,
    video_result: [2][video.result_bytes]u8,
    video_acknowledgement: [2][video.ack_result_bytes]u8,
};

const reference_image_raw_1 = "\x15\x1f\x29\x33";
const reference_image_raw_2 = "\x16\x20\x2a\x34";
const reference_audio_raw_1 = "\x00\x01\x00\xff";
const reference_audio_raw_2 = "\x00\x02\x00\xfe";
const reference_video_raw_1 = "\x03\x03\x03\x03\x07\x07\x07\x07";
const reference_video_raw_2 = "\x0b\x0b\x0b\x0b\x0d\x0d\x0d\x0d";

const reference_image_payload_1 =
    "producer-admission-image-0\x00" ++ reference_image_raw_1;
const reference_image_payload_2 =
    "producer-admission-image-1\x00" ++ reference_image_raw_2;
const reference_audio_payload_1 =
    "producer-admission-audio-0\x00" ++ reference_audio_raw_1;
const reference_audio_payload_2 =
    "producer-admission-audio-1\x00" ++ reference_audio_raw_2;
const reference_video_payload_1 =
    "producer-admission-video-0\x00" ++ reference_video_raw_1;
const reference_video_payload_2 =
    "producer-admission-video-1\x00" ++ reference_video_raw_2;

pub fn makeReferenceArchivesV1(
    first_scratch: []u8,
    first_archive: []u8,
    second_scratch: []u8,
    second_archive: []u8,
) Error!ReferenceArchivesV1 {
    const values = makeReferenceValuesV1() catch
        return Error.InvalidProducerBinding;
    var first_wires: ReferenceWireStorageV1 = undefined;
    var second_wires: ReferenceWireStorageV1 = undefined;
    var first_outputs = makeReferenceBatchV1(
        values,
        0,
        &first_wires,
    ) catch return Error.InvalidProducerRecord;
    const first = try encodeArchiveV1(
        .{
            .previous = null,
            .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
            .outputs = &first_outputs,
        },
        first_scratch,
        first_archive,
    );
    const first_decoded = try registry.decodeArchiveV1(
        first.set.bytes,
        null,
    );
    var second_outputs = makeReferenceBatchV1(
        values,
        1,
        &second_wires,
    ) catch return Error.InvalidProducerRecord;
    const second = try encodeArchiveV1(
        .{
            .previous = first_decoded,
            .generation_plan_sha256 = referenceIdentityV1("generation-plan-two"),
            .outputs = &second_outputs,
        },
        second_scratch,
        second_archive,
    );
    const second_decoded = try registry.decodeArchiveV1(
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

fn makeReferenceValuesV1() !ReferenceValuesV1 {
    const common: ReferenceCommonV1 = .{
        .request_epoch = 131_001,
        .tenant_scope_sha256 = referenceIdentityV1("tenant-scope"),
        .metadata_policy_sha256 = referenceIdentityV1("metadata-policy"),
        .challenge_sha256 = referenceIdentityV1("challenge"),
    };
    const image_first = try makeReferenceImageV1(
        1,
        common,
        referenceIdentityV1("image-plan-genesis"),
        referenceIdentityV1("image-result-genesis"),
        referenceIdentityV1("image-state-genesis"),
    );
    const image_second = try makeReferenceImageV1(
        2,
        common,
        image_first.plan.plan_sha256,
        image_first.result.result_sha256,
        image_first.result.publication_state_after_sha256,
    );

    const audio_initial = try audio.makeInitialStateV1(
        common.request_epoch,
        16_000,
        1,
        referenceIdentityV1("audio-artifact"),
        common.tenant_scope_sha256,
        common.metadata_policy_sha256,
        common.challenge_sha256,
    );
    const audio_first = try makeReferenceAudioV1(
        audio_initial,
        0,
    );
    const audio_second = try makeReferenceAudioV1(
        audio_first.state_after,
        1,
    );

    const video_initial = try video.initializeStateV1(
        common.request_epoch,
        2,
        2,
        1,
        referenceIdentityV1("video-artifact"),
        common.tenant_scope_sha256,
        common.metadata_policy_sha256,
        common.challenge_sha256,
    );
    const video_first = try makeReferenceVideoV1(
        video_initial,
        0,
        referenceIdentityV1("video-source-result-genesis"),
    );
    const video_second = try makeReferenceVideoV1(
        video_first.state_after,
        1,
        video_first.result.result_sha256,
    );
    return .{
        .image = .{ image_first, image_second },
        .audio = .{ audio_first, audio_second },
        .video = .{ video_first, video_second },
    };
}

fn makeReferenceImageV1(
    image_index: u64,
    common: ReferenceCommonV1,
    previous_plan_sha256: Digest,
    previous_result_sha256: Digest,
    publication_state_before_sha256: Digest,
) !ReferenceImageV1 {
    const ordinal = image_index - 1;
    const raw_output = referenceImageRawV1(ordinal);
    const terminal_result_label = switch (image_index) {
        1 => "image-terminal-result-1",
        2 => "image-terminal-result-2",
        else => return Error.InvalidBatch,
    };
    const terminal_plan_label = switch (image_index) {
        1 => "image-terminal-plan-1",
        2 => "image-terminal-plan-2",
        else => return Error.InvalidBatch,
    };
    const terminal_output_label = switch (image_index) {
        1 => "image-terminal-output-1",
        2 => "image-terminal-output-2",
        else => return Error.InvalidBatch,
    };
    const terminal_state_label = switch (image_index) {
        1 => "image-terminal-state-1",
        2 => "image-terminal-state-2",
        else => return Error.InvalidBatch,
    };
    const checkpoint_label = switch (image_index) {
        1 => "image-checkpoint-1",
        2 => "image-checkpoint-2",
        else => return Error.InvalidBatch,
    };
    const source_provenance_label = switch (image_index) {
        1 => "image-source-provenance-1",
        2 => "image-source-provenance-2",
        else => return Error.InvalidBatch,
    };
    const media_label = switch (image_index) {
        1 => "image-media-1",
        2 => "image-media-2",
        else => return Error.InvalidBatch,
    };
    var plan: image.GeneratedImagePlanV1 = .{
        .request_epoch = common.request_epoch,
        .generation = image_index,
        .image_index = image_index,
        .source_step = image_index,
        .width = 2,
        .height = 2,
        .channels = 1,
        .row_stride = 2,
        .latent_bytes = 4,
        .pixel_bytes = 4,
        .maximum_output_bytes = 4,
        .decoder_abi = image.reference_decoder_abi,
        .color_model = .gray,
        .transfer_function = .linear,
        .alpha_mode = .none,
        .publication_sequence = image_index,
        .visible_images_before = ordinal,
        .visible_images_after = image_index,
        .logical_units = 1,
        .required_capabilities = 0,
        .artifact_sha256 = referenceIdentityV1("image-artifact"),
        .terminal_result_sha256 = referenceIdentityV1(terminal_result_label),
        .terminal_plan_sha256 = referenceIdentityV1(terminal_plan_label),
        .terminal_output_sha256 = referenceIdentityV1(terminal_output_label),
        .terminal_state_publication_sha256 = referenceIdentityV1(terminal_state_label),
        .stateful_checkpoint_sha256 = referenceIdentityV1(checkpoint_label),
        .decoder_payload_sha256 = referenceIdentityV1("image-decoder-payload"),
        .decoder_implementation_sha256 = referenceIdentityV1("image-decoder-implementation"),
        .tenant_scope_sha256 = common.tenant_scope_sha256,
        .metadata_policy_sha256 = common.metadata_policy_sha256,
        .source_provenance_sha256 = referenceIdentityV1(source_provenance_label),
        .challenge_sha256 = common.challenge_sha256,
        .previous_plan_sha256 = previous_plan_sha256,
        .previous_result_sha256 = previous_result_sha256,
        .media_object_sha256 = referenceIdentityV1(media_label),
        .plan_sha256 = zero_digest,
    };
    plan.plan_sha256 = image.generatedImagePlanRootV1(plan);
    try image.validateGeneratedImagePlanV1(plan);
    const provenance =
        try image.makeGeneratedImageProvenanceV1(
            plan,
            model.sha256(raw_output),
        );
    const resource_label = switch (image_index) {
        1 => "image-resource-1",
        2 => "image-resource-2",
        else => unreachable,
    };
    const event_label = switch (image_index) {
        1 => "image-event-1",
        2 => "image-event-2",
        else => unreachable,
    };
    const commit_label = switch (image_index) {
        1 => "image-commit-1",
        2 => "image-commit-2",
        else => unreachable,
    };
    const state_after_label = switch (image_index) {
        1 => "image-state-after-1",
        2 => "image-state-after-2",
        else => unreachable,
    };
    var result: image.GeneratedImageResultV1 = .{
        .request_epoch = plan.request_epoch,
        .generation = plan.generation,
        .image_index = plan.image_index,
        .source_step = plan.source_step,
        .width = plan.width,
        .height = plan.height,
        .channels = plan.channels,
        .row_stride = plan.row_stride,
        .pixel_bytes = plan.pixel_bytes,
        .publication_sequence = plan.publication_sequence,
        .visible_images_before = plan.visible_images_before,
        .visible_images_after = plan.visible_images_after,
        .logical_units = plan.logical_units,
        .decoder_abi = plan.decoder_abi,
        .plan_sha256 = plan.plan_sha256,
        .provenance_sha256 = provenance.provenance_sha256,
        .artifact_sha256 = plan.artifact_sha256,
        .terminal_result_sha256 = plan.terminal_result_sha256,
        .terminal_output_sha256 = plan.terminal_output_sha256,
        .terminal_state_publication_sha256 = plan.terminal_state_publication_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .output_sha256 = provenance.output_sha256,
        .resource_receipt_sha256 = referenceIdentityV1(resource_label),
        .publication_state_before_sha256 = publication_state_before_sha256,
        .timeline_event_sha256 = referenceIdentityV1(event_label),
        .media_commit_sha256 = referenceIdentityV1(commit_label),
        .publication_state_after_sha256 = referenceIdentityV1(state_after_label),
        .previous_result_sha256 = plan.previous_result_sha256,
        .decoder_implementation_sha256 = plan.decoder_implementation_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .result_sha256 = zero_digest,
    };
    result.result_sha256 =
        image.generatedImageResultRootV1(result);
    try image.validateGeneratedImageResultV1(result);
    return .{
        .plan = plan,
        .provenance = provenance,
        .result = result,
    };
}

fn makeReferenceAudioV1(
    state_before: audio.GeneratedAudioStateV1,
    ordinal: usize,
) !ReferenceAudioV1 {
    const source_output = referenceAudioSourceV1(ordinal);
    const raw_output = referenceAudioRawV1(ordinal);
    var rendered: [4]u8 = undefined;
    try audio.renderReferencePcmV1(source_output, &rendered);
    if (!std.mem.eql(u8, &rendered, raw_output))
        return Error.InvalidProducerBinding;
    var renderer_context: u8 = 1;
    const renderer = audio.referenceRendererV1(
        &renderer_context,
    );
    const source_result_sha256 =
        referenceAudioSourceResultV1(state_before);
    const source_output_sha256 =
        model.sha256(source_output);
    const media_object = try audio.makeAudioMediaObjectV1(
        state_before,
        @intCast(source_output.len),
        model.sha256(raw_output),
        source_result_sha256,
        source_output_sha256,
        renderer.implementation_sha256,
    );
    const media_object_sha256 =
        try referenceMediaObjectRootV1(media_object);
    const plan = try audio.makePlanV1(
        state_before,
        @intCast(source_output.len),
        @intCast(source_output.len),
        audio.maximum_pcm_bytes,
        renderer.required_capabilities,
        renderer.renderer_abi,
        source_result_sha256,
        source_output_sha256,
        model.sha256(audio.reference_renderer_payload),
        renderer.implementation_sha256,
        media_object_sha256,
    );
    const provenance = try audio.makeProvenanceV1(
        plan,
        model.sha256(raw_output),
    );
    const claim = try audio.claimForPlanV1(
        plan,
        audio.reference_renderer_payload.len,
    );
    const receipt = referenceReceiptV1(
        151_001,
        0,
        @intCast(ordinal + 1),
        @intCast(152_001 + ordinal),
        claim,
    );
    const result = try audio.makeResultV1(
        plan,
        provenance,
        receipt,
    );
    var pending = try referenceAudioPendingStateV1(
        state_before,
        plan,
        result,
    );
    const observation = try audio.makePlaybackObservationV1(
        pending,
        referenceIdentityV1("audio-sink"),
        referenceIdentityV1("audio-sink-instance"),
    );
    const acknowledgement_plan =
        try audio.makePlaybackAckPlanV1(
            pending,
            result,
            observation,
        );
    const acknowledgement =
        try audio.acknowledgePlaybackV1(
            &pending,
            result,
            observation,
            acknowledgement_plan,
        );
    return .{
        .state_after = pending,
        .plan = plan,
        .provenance = provenance,
        .result = result,
        .acknowledgement = acknowledgement,
    };
}

fn resealReferenceAudioV1(value: *ReferenceAudioV1) !void {
    value.plan.plan_sha256 = zero_digest;
    value.plan.plan_sha256 = audio.planRootV1(value.plan);

    value.provenance.plan_sha256 = value.plan.plan_sha256;
    value.provenance.provenance_sha256 = zero_digest;
    value.provenance.provenance_sha256 =
        audio.provenanceRootV1(value.provenance);

    value.result.plan_sha256 = value.plan.plan_sha256;
    value.result.provenance_sha256 =
        value.provenance.provenance_sha256;
    value.result.state_before_sha256 =
        value.plan.state_before_sha256;
    value.result.previous_publication_result_sha256 =
        value.plan.previous_publication_result_sha256;
    value.result.result_sha256 = zero_digest;
    value.result.result_sha256 = audio.resultRootV1(value.result);

    var pending = value.state_after;
    pending.generation = value.result.generation;
    pending.acknowledged_chunks =
        value.result.visible_chunks_before;
    pending.acknowledged_frames =
        value.result.visible_frames_before;
    pending.playback_sequence = value.result.chunk_index;
    pending.pending = 1;
    pending.pending_chunk_index = value.result.chunk_index;
    pending.pending_start_frame = value.result.start_frame;
    pending.pending_frame_count = value.result.frame_count;
    pending.previous_publication_result_sha256 =
        value.result.previous_publication_result_sha256;
    pending.previous_ack_result_sha256 =
        value.acknowledgement.previous_ack_result_sha256;
    pending.pending_publication_result_sha256 =
        value.result.result_sha256;
    pending.pending_output_sha256 = value.result.output_sha256;
    pending.state_sha256 = zero_digest;
    pending.state_sha256 = audio.stateRootV1(pending);
    try audio.validateStateV1(pending);
    const observation = try audio.makePlaybackObservationV1(
        pending,
        value.acknowledgement.sink_implementation_sha256,
        value.acknowledgement.sink_instance_sha256,
    );
    const acknowledgement_plan =
        try audio.makePlaybackAckPlanV1(
            pending,
            value.result,
            observation,
        );
    value.acknowledgement =
        try audio.acknowledgePlaybackV1(
            &pending,
            value.result,
            observation,
            acknowledgement_plan,
        );
    value.state_after = pending;
}

fn referenceAudioStateBeforeV1(
    value: ReferenceAudioV1,
) !audio.GeneratedAudioStateV1 {
    var before = value.state_after;
    before.generation = try std.math.sub(
        u64,
        value.result.generation,
        1,
    );
    before.next_chunk_index = value.result.chunk_index;
    before.next_start_frame = value.result.start_frame;
    before.visible_chunks = value.result.visible_chunks_before;
    before.visible_frames = value.result.visible_frames_before;
    before.acknowledged_chunks =
        value.result.visible_chunks_before;
    before.acknowledged_frames =
        value.result.visible_frames_before;
    before.playback_sequence = value.result.chunk_index;
    before.pending = 0;
    before.pending_chunk_index = 0;
    before.pending_start_frame = 0;
    before.pending_frame_count = 0;
    before.previous_publication_result_sha256 =
        value.result.previous_publication_result_sha256;
    before.previous_ack_result_sha256 =
        value.acknowledgement.previous_ack_result_sha256;
    before.pending_publication_result_sha256 = zero_digest;
    before.pending_output_sha256 = zero_digest;
    before.state_sha256 = zero_digest;
    before.state_sha256 = audio.stateRootV1(before);
    try audio.validateStateV1(before);
    return before;
}

fn encodeReferenceAudioWiresV1(
    value: ReferenceAudioV1,
    ordinal: usize,
    wires: *ReferenceWireStorageV1,
) !void {
    _ = try audio.encodeStateV1(
        value.state_after,
        &wires.audio_state[ordinal],
    );
    _ = try audio.encodePlanV1(
        value.plan,
        &wires.audio_plan[ordinal],
    );
    _ = try audio.encodeProvenanceV1(
        value.provenance,
        &wires.audio_provenance[ordinal],
    );
    _ = try audio.encodeResultV1(
        value.result,
        &wires.audio_result[ordinal],
    );
    _ = try audio.encodePlaybackAckResultV1(
        value.acknowledgement,
        &wires.audio_acknowledgement[ordinal],
    );
}

fn encodeReferenceVideoWiresV1(
    value: ReferenceVideoV1,
    ordinal: usize,
    wires: *ReferenceWireStorageV1,
) !void {
    _ = try video.encodeStateV1(
        value.state_after,
        &wires.video_state[ordinal],
    );
    _ = try video.encodeManifestV1(
        value.manifest,
        &wires.video_manifest[ordinal],
    );
    _ = try video.encodeProvenanceV1(
        value.provenance,
        &wires.video_provenance[ordinal],
    );
    _ = try video.encodeResultV1(
        value.result,
        &wires.video_result[ordinal],
    );
    _ = try video.encodeDisplayAckResultV1(
        value.acknowledgement,
        &wires.video_acknowledgement[ordinal],
    );
}

fn makeReferenceVideoV1(
    state_before: video.GeneratedVideoStateV1,
    ordinal: usize,
    source_result_sha256: Digest,
) !ReferenceVideoV1 {
    const source_output = referenceVideoSourceV1(ordinal);
    const raw_output = referenceVideoRawV1(ordinal);
    if (source_output.len != 2 or raw_output.len != 8 or
        !std.mem.allEqual(u8, raw_output[0..4], source_output[0]) or
        !std.mem.allEqual(u8, raw_output[4..8], source_output[1]))
        return Error.InvalidProducerBinding;
    const durations = switch (ordinal) {
        0 => [2]u64{ 2, 3 },
        1 => [2]u64{ 4, 1 },
        else => return Error.InvalidBatch,
    };
    const renderer_implementation_sha256 =
        video.referenceRendererImplementationSha256V1();
    const first_frame_sha256 =
        model.sha256(raw_output[0..4]);
    const second_frame_sha256 =
        model.sha256(raw_output[4..8]);
    const provisional = try video.makeManifestV1(
        state_before,
        durations[0],
        durations[1],
        source_output.len,
        raw_output.len,
        0,
        video.reference_renderer_abi,
        source_result_sha256,
        model.sha256(source_output),
        model.sha256(video.reference_renderer_payload),
        renderer_implementation_sha256,
        model.sha256("generated video placeholder media"),
        first_frame_sha256,
        second_frame_sha256,
    );
    const media_object: media.MediaObjectV1 = .{
        .kind = .video,
        .semantic_abi = video.raw_video_semantic_abi,
        .byte_length = raw_output.len,
        .container_id = video.raw_container_id,
        .codec_id = video.gray8_frame_codec_id,
        .axes = .{ 2, 2, 2 },
        .time_base = .{
            .numerator = 1,
            .denominator = 1_000,
        },
        .tenant_scope_sha256 = state_before.tenant_scope_sha256,
        .content_sha256 = model.sha256(raw_output),
        .metadata_policy_sha256 = state_before.metadata_policy_sha256,
        .provenance_sha256 = video.sourceProvenanceRootV1(provisional),
    };
    const media_object_sha256 =
        try referenceMediaObjectRootV1(media_object);
    const manifest = try video.makeManifestV1(
        state_before,
        durations[0],
        durations[1],
        source_output.len,
        raw_output.len,
        0,
        video.reference_renderer_abi,
        source_result_sha256,
        model.sha256(source_output),
        model.sha256(video.reference_renderer_payload),
        renderer_implementation_sha256,
        media_object_sha256,
        first_frame_sha256,
        second_frame_sha256,
    );
    if (!digestEqual(
        media_object.provenance_sha256,
        video.sourceProvenanceRootV1(manifest),
    )) return Error.InvalidProducerBinding;
    const provenance = try video.makeProvenanceV1(
        manifest,
        model.sha256(raw_output),
    );
    const claim = try video.claimForManifestV1(
        manifest,
        video.reference_renderer_payload.len,
    );
    const receipt = referenceReceiptV1(
        161_001,
        0,
        @intCast(ordinal + 1),
        @intCast(162_001 + ordinal),
        claim,
    );
    const result = try video.makeResultV1(
        manifest,
        provenance,
        receipt,
    );
    var pending = try referenceVideoPendingStateV1(
        state_before,
        manifest,
        result,
    );
    const observation = try video.makeDisplayObservationV1(
        pending,
        referenceIdentityV1("video-sink"),
        referenceIdentityV1("video-sink-instance"),
    );
    const acknowledgement_plan =
        try video.makeDisplayAckPlanV1(
            pending,
            result,
            observation,
        );
    const acknowledgement =
        try video.acknowledgeDisplayV1(
            &pending,
            result,
            observation,
            acknowledgement_plan,
        );
    return .{
        .state_after = pending,
        .manifest = manifest,
        .provenance = provenance,
        .result = result,
        .acknowledgement = acknowledgement,
    };
}

fn referenceAudioPendingStateV1(
    state: audio.GeneratedAudioStateV1,
    plan: audio.GeneratedAudioPlanV1,
    result: audio.GeneratedAudioResultV1,
) !audio.GeneratedAudioStateV1 {
    var next = state;
    next.generation = plan.generation;
    next.next_chunk_index = plan.visible_chunks_after;
    next.next_start_frame = plan.visible_frames_after;
    next.visible_chunks = plan.visible_chunks_after;
    next.visible_frames = plan.visible_frames_after;
    next.pending = 1;
    next.pending_chunk_index = plan.chunk_index;
    next.pending_start_frame = plan.start_frame;
    next.pending_frame_count = plan.frame_count;
    next.pending_publication_result_sha256 =
        result.result_sha256;
    next.pending_output_sha256 = result.output_sha256;
    next.state_sha256 = zero_digest;
    next.state_sha256 = audio.stateRootV1(next);
    try audio.validateStateV1(next);
    return next;
}

fn referenceVideoPendingStateV1(
    state: video.GeneratedVideoStateV1,
    manifest: video.GeneratedVideoManifestV1,
    result: video.GeneratedVideoResultV1,
) !video.GeneratedVideoStateV1 {
    var next = state;
    next.generation = manifest.generation;
    next.next_segment_index = manifest.visible_segments_after;
    next.next_frame_ordinal = manifest.visible_frames_after;
    next.next_start_tick = manifest.end_tick;
    next.visible_segments = manifest.visible_segments_after;
    next.visible_frames = manifest.visible_frames_after;
    next.visible_end_tick = manifest.end_tick;
    next.pending = 1;
    next.pending_segment_index = manifest.segment_index;
    next.pending_first_frame = manifest.first_frame_ordinal;
    next.pending_frame_count = manifest.frame_count;
    next.pending_start_tick = manifest.start_tick;
    next.pending_end_tick = manifest.end_tick;
    next.previous_publication_result_sha256 =
        result.result_sha256;
    next.pending_publication_result_sha256 =
        result.result_sha256;
    next.pending_output_sha256 = result.output_sha256;
    next.state_sha256 = zero_digest;
    next.state_sha256 = video.stateRootV1(next);
    try video.validateStateV1(next);
    return next;
}

fn makeReferenceBatchV1(
    values: ReferenceValuesV1,
    ordinal: usize,
    wires: *ReferenceWireStorageV1,
) ![3]AdmittedOutputV1 {
    if (ordinal > 1) return Error.InvalidBatch;
    const image_value = values.image[ordinal];
    const audio_value = values.audio[ordinal];
    const video_value = values.video[ordinal];
    _ = try image.encodeGeneratedImagePlanV1(
        image_value.plan,
        &wires.image_plan[ordinal],
    );
    _ = try image.encodeGeneratedImageProvenanceV1(
        image_value.provenance,
        &wires.image_provenance[ordinal],
    );
    _ = try image.encodeGeneratedImageResultV1(
        image_value.result,
        &wires.image_result[ordinal],
    );
    _ = try audio.encodeStateV1(
        audio_value.state_after,
        &wires.audio_state[ordinal],
    );
    _ = try audio.encodePlanV1(
        audio_value.plan,
        &wires.audio_plan[ordinal],
    );
    _ = try audio.encodeProvenanceV1(
        audio_value.provenance,
        &wires.audio_provenance[ordinal],
    );
    _ = try audio.encodeResultV1(
        audio_value.result,
        &wires.audio_result[ordinal],
    );
    _ = try audio.encodePlaybackAckResultV1(
        audio_value.acknowledgement,
        &wires.audio_acknowledgement[ordinal],
    );
    _ = try video.encodeStateV1(
        video_value.state_after,
        &wires.video_state[ordinal],
    );
    _ = try video.encodeManifestV1(
        video_value.manifest,
        &wires.video_manifest[ordinal],
    );
    _ = try video.encodeProvenanceV1(
        video_value.provenance,
        &wires.video_provenance[ordinal],
    );
    _ = try video.encodeResultV1(
        video_value.result,
        &wires.video_result[ordinal],
    );
    _ = try video.encodeDisplayAckResultV1(
        video_value.acknowledgement,
        &wires.video_acknowledgement[ordinal],
    );
    return .{
        .{
            .producer = .{ .image = .{
                .plan = &wires.image_plan[ordinal],
                .provenance = &wires.image_provenance[ordinal],
                .result = &wires.image_result[ordinal],
                .raw_output = referenceImageRawV1(ordinal),
            } },
            .encoding_abi = 101,
            .encoded_payload = referenceEncodedPayloadV1(.image, ordinal),
            .encoder_implementation_sha256 = referenceIdentityV1("encoder-image"),
            .format_sha256 = referenceIdentityV1("format-image"),
        },
        .{
            .producer = .{ .audio = .{
                .state_after = &wires.audio_state[ordinal],
                .plan = &wires.audio_plan[ordinal],
                .provenance = &wires.audio_provenance[ordinal],
                .result = &wires.audio_result[ordinal],
                .acknowledgement = &wires.audio_acknowledgement[ordinal],
                .raw_output = referenceAudioRawV1(ordinal),
            } },
            .encoding_abi = 102,
            .encoded_payload = referenceEncodedPayloadV1(.audio, ordinal),
            .encoder_implementation_sha256 = referenceIdentityV1("encoder-audio"),
            .format_sha256 = referenceIdentityV1("format-audio"),
        },
        .{
            .producer = .{ .video = .{
                .state_after = &wires.video_state[ordinal],
                .manifest = &wires.video_manifest[ordinal],
                .provenance = &wires.video_provenance[ordinal],
                .result = &wires.video_result[ordinal],
                .acknowledgement = &wires.video_acknowledgement[ordinal],
                .raw_output = referenceVideoRawV1(ordinal),
            } },
            .encoding_abi = 103,
            .encoded_payload = referenceEncodedPayloadV1(.video, ordinal),
            .encoder_implementation_sha256 = referenceIdentityV1("encoder-video"),
            .format_sha256 = referenceIdentityV1("format-video"),
        },
    };
}

fn referenceIdentityV1(label: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier.generated-media-producer-admission.reference.v1\x00",
    );
    hash.update(label);
    return hash.finalResult();
}

fn referenceMediaObjectRootV1(
    value: media.MediaObjectV1,
) !Digest {
    var storage: [media.descriptor_bytes]u8 = undefined;
    const wire = try media.encodeMediaObjectV1(
        value,
        &storage,
    );
    return media.mediaObjectSha256V1(wire);
}

fn referenceAudioSourceResultV1(
    state: audio.GeneratedAudioStateV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier.generated-audio-test-source-result.v1",
    );
    referenceHashU64V1(&hash, state.next_chunk_index);
    referenceHashU64V1(&hash, state.next_start_frame);
    hash.update(&state.previous_publication_result_sha256);
    return hash.finalResult();
}

fn referenceReceiptV1(
    bank_epoch: u64,
    slot_index: u32,
    generation: u64,
    owner_key: u64,
    claim: resource_bank.Claim,
) resource_bank.Receipt {
    var integrity = referenceMix64V1(
        0x7265_6365_6970_7431 ^ bank_epoch,
    );
    integrity = referenceMix64V1(
        integrity ^ @as(u64, slot_index),
    );
    integrity = referenceMix64V1(integrity ^ generation);
    integrity = referenceMix64V1(integrity ^ owner_key);
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        integrity = referenceMix64V1(
            integrity ^ @field(claim, field.name),
        );
    }
    return .{
        .bank_epoch = bank_epoch,
        .slot_index = slot_index,
        .generation = generation,
        .owner_key = owner_key,
        .claim = claim,
        .integrity = integrity,
    };
}

fn referenceMix64V1(input: u64) u64 {
    var value = input;
    value ^= value >> 30;
    value *%= 0xbf58_476d_1ce4_e5b9;
    value ^= value >> 27;
    value *%= 0x94d0_49bb_1331_11eb;
    value ^= value >> 31;
    return value;
}

fn referenceHashU64V1(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn referenceImageRawV1(ordinal: usize) []const u8 {
    return switch (ordinal) {
        0 => reference_image_raw_1,
        1 => reference_image_raw_2,
        else => &[_]u8{},
    };
}

fn referenceAudioSourceV1(ordinal: usize) []const u8 {
    return switch (ordinal) {
        0 => &[_]u8{ 129, 127 },
        1 => &[_]u8{ 130, 126 },
        else => &[_]u8{},
    };
}

fn referenceAudioRawV1(ordinal: usize) []const u8 {
    return switch (ordinal) {
        0 => reference_audio_raw_1,
        1 => reference_audio_raw_2,
        else => &[_]u8{},
    };
}

fn referenceVideoSourceV1(ordinal: usize) []const u8 {
    return switch (ordinal) {
        0 => &[_]u8{ 3, 7 },
        1 => &[_]u8{ 11, 13 },
        else => &[_]u8{},
    };
}

fn referenceVideoRawV1(ordinal: usize) []const u8 {
    return switch (ordinal) {
        0 => reference_video_raw_1,
        1 => reference_video_raw_2,
        else => &[_]u8{},
    };
}

fn referenceEncodedPayloadV1(
    modality: registry.ModalityV1,
    ordinal: usize,
) []const u8 {
    return switch (modality) {
        .image => switch (ordinal) {
            0 => reference_image_payload_1,
            1 => reference_image_payload_2,
            else => &[_]u8{},
        },
        .audio => switch (ordinal) {
            0 => reference_audio_payload_1,
            1 => reference_audio_payload_2,
            else => &[_]u8{},
        },
        .video => switch (ordinal) {
            0 => reference_video_payload_1,
            1 => reference_video_payload_2,
            else => &[_]u8{},
        },
    };
}

fn digestFromHexV1(hex: []const u8) !Digest {
    if (hex.len != 64) return Error.InvalidBatch;
    var digest: Digest = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch
        return Error.InvalidBatch;
    return digest;
}

test "typed producer admission matches the independent two-generation chain" {
    var first_scratch: [4096]u8 = undefined;
    var first_archive: [4096]u8 = undefined;
    var second_scratch: [4096]u8 = undefined;
    var second_archive: [4096]u8 = undefined;
    const fixture = try makeReferenceArchivesV1(
        &first_scratch,
        &first_archive,
        &second_scratch,
        &second_archive,
    );
    const values = try makeReferenceValuesV1();

    try std.testing.expectEqual(@as(u64, 1), fixture.first.manifest.generation);
    try std.testing.expectEqual(
        @as(u64, 1),
        fixture.first.manifest.publication_sequence,
    );
    try std.testing.expectEqual(@as(u64, 2), fixture.second.manifest.generation);
    try std.testing.expectEqual(
        @as(u64, 2),
        fixture.second.manifest.publication_sequence,
    );
    try std.testing.expectEqual(
        referenceIdentityV1("generation-plan-one"),
        fixture.first.manifest.generation_plan_sha256,
    );
    try std.testing.expectEqual(
        referenceIdentityV1("generation-plan-two"),
        fixture.second.manifest.generation_plan_sha256,
    );
    try std.testing.expectEqual(
        fixture.first_decoded.archive_sha256,
        fixture.second.manifest.previous_archive_sha256,
    );
    try std.testing.expectEqual(
        fixture.first.manifest.manifest_sha256,
        fixture.second.manifest.previous_manifest_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHexV1(
            "d5d8129d2e6076cf541664c19a2e1870cf2c8d6c376d8c7764b9a3f0c8bf171b",
        ),
        fixture.first.manifest.manifest_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHexV1(
            "1ffa14e1decad4edaf192b06528d154540c88007b4c6c3521914daf30532df6d",
        ),
        fixture.first_decoded.archive_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHexV1(
            "b97bada9db18b23213cf7d3fec7a8707f3f58870182d387a419f40977f51778e",
        ),
        fixture.second.manifest.manifest_sha256,
    );
    try std.testing.expectEqual(
        try digestFromHexV1(
            "c921975397d538952a66fac46d6a6980871bfb122595a0ea05d25e5d0f84461e",
        ),
        fixture.second_decoded.archive_sha256,
    );

    const expected_first_entry_roots = [_]Digest{
        try digestFromHexV1(
            "d51b6eaa294c7cbe6ab8fef661bb0f2e81a8c97bc41e7b058a2ed957fa41c849",
        ),
        try digestFromHexV1(
            "185e88048ab586b58d461bba3fbb4b5937d5acf6e852403a85726c882ad4e015",
        ),
        try digestFromHexV1(
            "448dc2b27ab9740ea8cc1f55e6f559c0c3ca70ee43d083112ca2b09fe2b25515",
        ),
    };
    const expected_second_entry_roots = [_]Digest{
        try digestFromHexV1(
            "cba3d86554734b761e040915bb8d665bfa25ffabbeff9f701580fe4e13025670",
        ),
        try digestFromHexV1(
            "9e4e91ada62d1890a6fd51d9953fe57434a103fc82841229c15c81b103918f1f",
        ),
        try digestFromHexV1(
            "7d44b6bd952548b2b1fa035f744936f15e79e6549fdea18d829d397501f0324f",
        ),
    };
    inline for (0..3) |index| {
        const first_entry = try fixture.first_decoded.entry(index);
        const second_entry = try fixture.second_decoded.entry(index);
        try std.testing.expectEqual(
            expected_first_entry_roots[index],
            first_entry.entry_sha256,
        );
        try std.testing.expectEqual(
            expected_second_entry_roots[index],
            second_entry.entry_sha256,
        );
        try std.testing.expectEqual(
            first_entry.entry_sha256,
            second_entry.previous_entry_sha256,
        );
        try std.testing.expectEqualSlices(
            u8,
            referenceEncodedPayloadV1(
                @enumFromInt(index + 1),
                0,
            ),
            try fixture.first_decoded.payload(index),
        );
        try std.testing.expectEqualSlices(
            u8,
            referenceEncodedPayloadV1(
                @enumFromInt(index + 1),
                1,
            ),
            try fixture.second_decoded.payload(index),
        );
    }

    const first_image = try fixture.first_decoded.entry(0);
    const second_image = try fixture.second_decoded.entry(0);
    try expectEntryMappingV1(
        first_image,
        try checkpoint.imageMemberV1(
            values.image[0].plan,
            values.image[0].provenance,
            values.image[0].result,
        ),
        .image,
        0,
        101,
        referenceImageRawV1(0),
        referenceIdentityV1("encoder-image"),
        referenceIdentityV1("format-image"),
    );
    try expectEntryMappingV1(
        second_image,
        try checkpoint.imageMemberV1(
            values.image[1].plan,
            values.image[1].provenance,
            values.image[1].result,
        ),
        .image,
        1,
        101,
        referenceImageRawV1(1),
        referenceIdentityV1("encoder-image"),
        referenceIdentityV1("format-image"),
    );
    try std.testing.expectEqual(@as(u64, 1), values.image[0].plan.image_index);
    try std.testing.expectEqual(@as(u64, 0), first_image.ordinal);
    try std.testing.expectEqual(@as(u64, 2), values.image[1].plan.image_index);
    try std.testing.expectEqual(@as(u64, 1), second_image.ordinal);

    const first_audio = try fixture.first_decoded.entry(1);
    const second_audio = try fixture.second_decoded.entry(1);
    try expectEntryMappingV1(
        first_audio,
        try checkpoint.audioMemberV1(
            values.audio[0].state_after,
            values.audio[0].plan,
            values.audio[0].provenance,
            values.audio[0].result,
            values.audio[0].acknowledgement,
        ),
        .audio,
        0,
        102,
        referenceAudioRawV1(0),
        referenceIdentityV1("encoder-audio"),
        referenceIdentityV1("format-audio"),
    );
    try expectEntryMappingV1(
        second_audio,
        try checkpoint.audioMemberV1(
            values.audio[1].state_after,
            values.audio[1].plan,
            values.audio[1].provenance,
            values.audio[1].result,
            values.audio[1].acknowledgement,
        ),
        .audio,
        1,
        102,
        referenceAudioRawV1(1),
        referenceIdentityV1("encoder-audio"),
        referenceIdentityV1("format-audio"),
    );

    const first_video = try fixture.first_decoded.entry(2);
    const second_video = try fixture.second_decoded.entry(2);
    try expectEntryMappingV1(
        first_video,
        try checkpoint.videoMemberV1(
            values.video[0].state_after,
            values.video[0].manifest,
            values.video[0].provenance,
            values.video[0].result,
            values.video[0].acknowledgement,
        ),
        .video,
        0,
        103,
        referenceVideoRawV1(0),
        referenceIdentityV1("encoder-video"),
        referenceIdentityV1("format-video"),
    );
    try expectEntryMappingV1(
        second_video,
        try checkpoint.videoMemberV1(
            values.video[1].state_after,
            values.video[1].manifest,
            values.video[1].provenance,
            values.video[1].result,
            values.video[1].acknowledgement,
        ),
        .video,
        1,
        103,
        referenceVideoRawV1(1),
        referenceIdentityV1("encoder-video"),
        referenceIdentityV1("format-video"),
    );

    try std.testing.expectEqual(
        values.image[0].result.publication_state_after_sha256,
        values.image[1].result.publication_state_before_sha256,
    );
    try std.testing.expectEqual(
        values.image[0].result.result_sha256,
        values.image[1].result.previous_result_sha256,
    );
    try std.testing.expectEqual(
        values.audio[0].state_after.state_sha256,
        values.audio[1].result.state_before_sha256,
    );
    try std.testing.expectEqual(
        values.audio[0].result.result_sha256,
        values.audio[1].result.previous_publication_result_sha256,
    );
    try std.testing.expectEqual(
        values.audio[0].acknowledgement.result_sha256,
        values.audio[1].acknowledgement.previous_ack_result_sha256,
    );
    try std.testing.expectEqual(
        values.audio[0].result.result_sha256,
        values.audio[1].acknowledgement.previous_publication_result_sha256,
    );
    try std.testing.expectEqual(
        values.video[0].state_after.state_sha256,
        values.video[1].result.state_before_sha256,
    );
    try std.testing.expectEqual(
        values.video[0].result.result_sha256,
        values.video[1].result.previous_publication_result_sha256,
    );
    try std.testing.expectEqual(
        values.video[0].acknowledgement.result_sha256,
        values.video[1].acknowledgement.previous_ack_result_sha256,
    );
    try std.testing.expectEqual(
        values.video[1].result.result_sha256,
        values.video[1].acknowledgement.previous_publication_result_sha256,
    );
}

test "one batch advances two typed producers per modality" {
    const values = try makeReferenceValuesV1();
    var first_wires: ReferenceWireStorageV1 = undefined;
    var second_wires: ReferenceWireStorageV1 = undefined;
    const first_outputs = try makeReferenceBatchV1(
        values,
        0,
        &first_wires,
    );
    const second_outputs = try makeReferenceBatchV1(
        values,
        1,
        &second_wires,
    );
    const outputs = [_]AdmittedOutputV1{
        first_outputs[0],
        second_outputs[0],
        first_outputs[1],
        second_outputs[1],
        first_outputs[2],
        second_outputs[2],
    };
    var scratch: [8192]u8 = undefined;
    var archive: [8192]u8 = undefined;
    const prepared = try encodeArchiveV1(
        .{
            .previous = null,
            .generation_plan_sha256 = referenceIdentityV1("generation-plan-current-batch"),
            .outputs = &outputs,
        },
        &scratch,
        &archive,
    );
    const decoded = try registry.decodeArchiveV1(
        prepared.set.bytes,
        null,
    );
    try std.testing.expectEqual(@as(u64, 1), prepared.manifest.generation);
    try std.testing.expectEqual(@as(u64, 6), prepared.manifest.entry_count);
    try std.testing.expectEqual(@as(u64, 2), prepared.manifest.image_count);
    try std.testing.expectEqual(@as(u64, 2), prepared.manifest.audio_count);
    try std.testing.expectEqual(@as(u64, 2), prepared.manifest.video_count);

    var payload_offset: u64 = 0;
    inline for (0..6) |index| {
        const modality: registry.ModalityV1 =
            @enumFromInt(index / 2 + 1);
        const ordinal = index % 2;
        const entry = try decoded.entry(index);
        const payload = referenceEncodedPayloadV1(modality, ordinal);
        try std.testing.expectEqual(modality, entry.modality);
        try std.testing.expectEqual(@as(u64, ordinal), entry.ordinal);
        try std.testing.expectEqual(payload_offset, entry.payload_offset);
        try std.testing.expectEqualSlices(
            u8,
            payload,
            try decoded.payload(index),
        );
        if (ordinal == 0) {
            try std.testing.expectEqual(zero_digest, entry.previous_entry_sha256);
        } else {
            const predecessor = try decoded.entry(index - 1);
            try std.testing.expectEqual(
                predecessor.entry_sha256,
                entry.previous_entry_sha256,
            );
        }
        payload_offset = try std.math.add(
            u64,
            payload_offset,
            @intCast(payload.len),
        );
    }

    const common: ReferenceCommonV1 = .{
        .request_epoch = 131_001,
        .tenant_scope_sha256 = referenceIdentityV1("tenant-scope"),
        .metadata_policy_sha256 = referenceIdentityV1("metadata-policy"),
        .challenge_sha256 = referenceIdentityV1("challenge"),
    };
    const wrong_second_image = try makeReferenceImageV1(
        2,
        common,
        values.image[0].plan.plan_sha256,
        referenceIdentityV1("wrong-current-image-result"),
        values.image[0].result.publication_state_after_sha256,
    );
    _ = try image.encodeGeneratedImagePlanV1(
        wrong_second_image.plan,
        &second_wires.image_plan[1],
    );
    _ = try image.encodeGeneratedImageProvenanceV1(
        wrong_second_image.provenance,
        &second_wires.image_provenance[1],
    );
    _ = try image.encodeGeneratedImageResultV1(
        wrong_second_image.result,
        &second_wires.image_result[1],
    );
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-current-batch"),
                .outputs = &outputs,
            },
            &scratch,
            &archive,
        ),
    );
}

test "producer source generation is independent from registry ordinal" {
    const values = try makeReferenceValuesV1();
    var wires: ReferenceWireStorageV1 = undefined;
    const reference_outputs = try makeReferenceBatchV1(
        values,
        0,
        &wires,
    );
    var scratch: [4096]u8 = undefined;
    var archive: [4096]u8 = undefined;

    var image_value = values.image[0];
    image_value.plan.generation = 2;
    image_value.plan.plan_sha256 = zero_digest;
    image_value.plan.plan_sha256 =
        image.generatedImagePlanRootV1(image_value.plan);
    image_value.provenance.generation = 2;
    image_value.provenance.plan_sha256 =
        image_value.plan.plan_sha256;
    image_value.provenance.provenance_sha256 = zero_digest;
    image_value.provenance.provenance_sha256 =
        image.generatedImageProvenanceRootV1(
            image_value.provenance,
        );
    image_value.result.generation = 2;
    image_value.result.plan_sha256 =
        image_value.plan.plan_sha256;
    image_value.result.provenance_sha256 =
        image_value.provenance.provenance_sha256;
    image_value.result.result_sha256 = zero_digest;
    image_value.result.result_sha256 =
        image.generatedImageResultRootV1(image_value.result);
    const image_projection =
        try checkpoint.imageProducerProjectionV1(
            image_value.plan,
            image_value.provenance,
            image_value.result,
        );
    try std.testing.expectEqual(@as(u64, 1), image_projection.ordinal);
    try std.testing.expectError(
        checkpoint.Error.InvalidMember,
        checkpoint.imageMemberV1(
            image_value.plan,
            image_value.provenance,
            image_value.result,
        ),
    );
    _ = try image.encodeGeneratedImagePlanV1(
        image_value.plan,
        &wires.image_plan[0],
    );
    _ = try image.encodeGeneratedImageProvenanceV1(
        image_value.provenance,
        &wires.image_provenance[0],
    );
    _ = try image.encodeGeneratedImageResultV1(
        image_value.result,
        &wires.image_result[0],
    );
    const image_outputs = [_]AdmittedOutputV1{
        reference_outputs[0],
    };
    const admitted_image = try encodeArchiveV1(
        .{
            .previous = null,
            .generation_plan_sha256 = referenceIdentityV1("independent-image-generation"),
            .outputs = &image_outputs,
        },
        &scratch,
        &archive,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        admitted_image.manifest.entry_count,
    );

    var audio_value = values.audio[0];
    audio_value.plan.generation = 2;
    audio_value.provenance.generation = 2;
    audio_value.result.generation = 2;
    audio_value.acknowledgement.generation = 3;
    audio_value.state_after.generation = 3;
    const audio_state_before =
        try referenceAudioStateBeforeV1(audio_value);
    audio_value.plan.state_before_sha256 =
        audio_state_before.state_sha256;
    try resealReferenceAudioV1(&audio_value);
    const audio_projection =
        try checkpoint.audioProducerProjectionV1(
            audio_value.state_after,
            audio_value.plan,
            audio_value.provenance,
            audio_value.result,
            audio_value.acknowledgement,
        );
    try std.testing.expectEqual(@as(u64, 0), audio_projection.ordinal);
    try std.testing.expectError(
        checkpoint.Error.InvalidMember,
        checkpoint.audioMemberV1(
            audio_value.state_after,
            audio_value.plan,
            audio_value.provenance,
            audio_value.result,
            audio_value.acknowledgement,
        ),
    );
    try encodeReferenceAudioWiresV1(
        audio_value,
        0,
        &wires,
    );
    const audio_outputs = [_]AdmittedOutputV1{
        reference_outputs[1],
    };
    const admitted_audio = try encodeArchiveV1(
        .{
            .previous = null,
            .generation_plan_sha256 = referenceIdentityV1("independent-audio-generation"),
            .outputs = &audio_outputs,
        },
        &scratch,
        &archive,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        admitted_audio.manifest.entry_count,
    );
}

test "admission sizing is exact and all mutable buffers remain disjoint" {
    const values = try makeReferenceValuesV1();
    var wires: ReferenceWireStorageV1 = undefined;
    const outputs = try makeReferenceBatchV1(
        values,
        0,
        &wires,
    );
    const input: BatchInputV1 = .{
        .previous = null,
        .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
        .outputs = &outputs,
    };
    const expected_scratch = 3 * registry.entry_bytes +
        reference_image_payload_1.len +
        reference_audio_payload_1.len +
        reference_video_payload_1.len;
    const expected_archive =
        checkpoint_file.set_payload_offset +
        checkpoint_file.set_footer_bytes +
        registry.manifest_bytes +
        expected_scratch;
    const required_scratch =
        try requiredScratchBytesV1(input);
    const required_archive =
        try requiredArchiveBytesV1(input);
    try std.testing.expectEqual(
        expected_scratch,
        required_scratch,
    );
    try std.testing.expectEqual(
        expected_archive,
        required_archive,
    );

    var scratch: [4096]u8 = undefined;
    var archive: [4096]u8 = undefined;
    const prepared = try encodeArchiveV1(
        input,
        scratch[0..required_scratch],
        archive[0..required_archive],
    );
    try std.testing.expectEqual(
        required_archive,
        prepared.set.bytes.len,
    );
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeArchiveV1(
            input,
            scratch[0 .. required_scratch - 1],
            archive[0..required_archive],
        ),
    );
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeArchiveV1(
            input,
            scratch[0..required_scratch],
            archive[0 .. required_archive - 1],
        ),
    );

    var shared: [4096]u8 = undefined;
    try std.testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            input,
            shared[0..required_scratch],
            shared[0..required_archive],
        ),
    );
    var payload_alias_outputs = outputs;
    payload_alias_outputs[0].encoded_payload =
        archive[32..64];
    const payload_alias_input: BatchInputV1 = .{
        .previous = null,
        .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
        .outputs = &payload_alias_outputs,
    };
    try std.testing.expectError(
        Error.UnsafeDestination,
        encodeArchiveV1(
            payload_alias_input,
            &scratch,
            &archive,
        ),
    );

    const empty_outputs = [_]AdmittedOutputV1{};
    const empty_input: BatchInputV1 = .{
        .previous = null,
        .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
        .outputs = &empty_outputs,
    };
    try std.testing.expectError(
        Error.InvalidBatch,
        requiredScratchBytesV1(empty_input),
    );
    try std.testing.expectError(
        Error.InvalidBatch,
        requiredArchiveBytesV1(empty_input),
    );
    var excessive_outputs: [registry.max_entries + 1]AdmittedOutputV1 = undefined;
    @memset(&excessive_outputs, outputs[0]);
    const excessive_input: BatchInputV1 = .{
        .previous = null,
        .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
        .outputs = &excessive_outputs,
    };
    try std.testing.expectError(
        Error.CapacityExceeded,
        requiredScratchBytesV1(excessive_input),
    );
    try std.testing.expectError(
        Error.CapacityExceeded,
        encodeArchiveV1(
            excessive_input,
            &scratch,
            &archive,
        ),
    );
}

test "admission rejects raw drift wire substitution order and missing lineage" {
    const values = try makeReferenceValuesV1();
    var first_wires: ReferenceWireStorageV1 = undefined;
    var second_wires: ReferenceWireStorageV1 = undefined;
    const first_outputs = try makeReferenceBatchV1(
        values,
        0,
        &first_wires,
    );
    const second_outputs = try makeReferenceBatchV1(
        values,
        1,
        &second_wires,
    );
    const first_input: BatchInputV1 = .{
        .previous = null,
        .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
        .outputs = &first_outputs,
    };
    var scratch: [4096]u8 = undefined;
    var archive: [4096]u8 = undefined;

    var drifted_raw = [4]u8{ 21, 31, 41, 50 };
    var raw_drift_outputs = first_outputs;
    raw_drift_outputs[0].producer.image.raw_output =
        &drifted_raw;
    try std.testing.expectError(
        Error.InvalidRawOutput,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
                .outputs = &raw_drift_outputs,
            },
            &scratch,
            &archive,
        ),
    );
    raw_drift_outputs[0].producer.image.raw_output =
        drifted_raw[0..3];
    try std.testing.expectError(
        Error.InvalidRawOutput,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
                .outputs = &raw_drift_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    var truncated_outputs = first_outputs;
    truncated_outputs[0].producer.image.plan =
        first_wires.image_plan[0][0 .. image.plan_bytes - 1];
    try std.testing.expectError(
        Error.InvalidProducerRecord,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
                .outputs = &truncated_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    var substituted_outputs = first_outputs;
    substituted_outputs[1].producer.audio.result =
        &second_wires.audio_result[1];
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
                .outputs = &substituted_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    const reordered_outputs = [_]AdmittedOutputV1{
        first_outputs[1],
        first_outputs[0],
        first_outputs[2],
    };
    try std.testing.expectError(
        Error.InvalidBatch,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
                .outputs = &reordered_outputs,
            },
            &scratch,
            &archive,
        ),
    );
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-two"),
                .outputs = &second_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    var empty_payload_outputs = first_outputs;
    empty_payload_outputs[0].encoded_payload = &[_]u8{};
    try std.testing.expectError(
        Error.InvalidEntry,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
                .outputs = &empty_payload_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    const valid = try encodeArchiveV1(
        first_input,
        &scratch,
        &archive,
    );
    const decoded = try registry.decodeArchiveV1(
        valid.set.bytes,
        null,
    );

    var wrong_audio_shape = values.audio[0];
    wrong_audio_shape.state_after.sample_rate = 48_000;
    wrong_audio_shape.state_after.state_sha256 = zero_digest;
    wrong_audio_shape.state_after.state_sha256 =
        audio.stateRootV1(wrong_audio_shape.state_after);
    try encodeReferenceAudioWiresV1(
        wrong_audio_shape,
        0,
        &first_wires,
    );
    const audio_only_outputs = [_]AdmittedOutputV1{
        first_outputs[1],
    };
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-audio-shape"),
                .outputs = &audio_only_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    var wrong_audio_ack = values.audio[0];
    wrong_audio_ack.acknowledgement.plan_sha256 =
        referenceIdentityV1("wrong-audio-ack-plan");
    wrong_audio_ack.acknowledgement.result_sha256 = zero_digest;
    wrong_audio_ack.acknowledgement.result_sha256 =
        audio.ackResultRootV1(
            wrong_audio_ack.acknowledgement,
        );
    wrong_audio_ack.state_after.previous_ack_result_sha256 =
        wrong_audio_ack.acknowledgement.result_sha256;
    wrong_audio_ack.state_after.state_sha256 = zero_digest;
    wrong_audio_ack.state_after.state_sha256 =
        audio.stateRootV1(wrong_audio_ack.state_after);
    try encodeReferenceAudioWiresV1(
        wrong_audio_ack,
        0,
        &first_wires,
    );
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-audio-ack"),
                .outputs = &audio_only_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    var wrong_video_shape = values.video[0];
    wrong_video_shape.state_after.width = 3;
    wrong_video_shape.state_after.state_sha256 = zero_digest;
    wrong_video_shape.state_after.state_sha256 =
        video.stateRootV1(wrong_video_shape.state_after);
    try encodeReferenceVideoWiresV1(
        wrong_video_shape,
        0,
        &first_wires,
    );
    const video_only_outputs = [_]AdmittedOutputV1{
        first_outputs[2],
    };
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-video-shape"),
                .outputs = &video_only_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    var wrong_video_ack = values.video[0];
    wrong_video_ack.acknowledgement.plan_sha256 =
        referenceIdentityV1("wrong-video-ack-plan");
    wrong_video_ack.acknowledgement.result_sha256 = zero_digest;
    wrong_video_ack.acknowledgement.result_sha256 =
        video.ackResultRootV1(
            wrong_video_ack.acknowledgement,
        );
    wrong_video_ack.state_after.previous_ack_result_sha256 =
        wrong_video_ack.acknowledgement.result_sha256;
    wrong_video_ack.state_after.state_sha256 = zero_digest;
    wrong_video_ack.state_after.state_sha256 =
        video.stateRootV1(wrong_video_ack.state_after);
    try encodeReferenceVideoWiresV1(
        wrong_video_ack,
        0,
        &first_wires,
    );
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = null,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-video-ack"),
                .outputs = &video_only_outputs,
            },
            &scratch,
            &archive,
        ),
    );

    var successor_scratch: [4096]u8 = undefined;
    var successor_archive: [4096]u8 = undefined;

    var wrong_state = values.audio[1];
    wrong_state.plan.generation = 5;
    wrong_state.provenance.generation = 5;
    wrong_state.result.generation = 5;
    wrong_state.acknowledgement.generation = 6;
    wrong_state.state_after.generation = 6;
    const wrong_state_before =
        try referenceAudioStateBeforeV1(wrong_state);
    wrong_state.plan.state_before_sha256 =
        wrong_state_before.state_sha256;
    try resealReferenceAudioV1(&wrong_state);
    _ = try checkpoint.audioProducerProjectionV1(
        wrong_state.state_after,
        wrong_state.plan,
        wrong_state.provenance,
        wrong_state.result,
        wrong_state.acknowledgement,
    );
    try encodeReferenceAudioWiresV1(
        wrong_state,
        1,
        &second_wires,
    );
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = decoded,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-two"),
                .outputs = &second_outputs,
            },
            &successor_scratch,
            &successor_archive,
        ),
    );

    var wrong_result = values.audio[1];
    wrong_result.plan.previous_publication_result_sha256 =
        referenceIdentityV1("wrong-audio-result-predecessor");
    wrong_result.result.previous_publication_result_sha256 =
        wrong_result.plan.previous_publication_result_sha256;
    const wrong_result_before =
        try referenceAudioStateBeforeV1(wrong_result);
    wrong_result.plan.state_before_sha256 =
        wrong_result_before.state_sha256;
    try resealReferenceAudioV1(&wrong_result);
    _ = try checkpoint.audioProducerProjectionV1(
        wrong_result.state_after,
        wrong_result.plan,
        wrong_result.provenance,
        wrong_result.result,
        wrong_result.acknowledgement,
    );
    try encodeReferenceAudioWiresV1(
        wrong_result,
        1,
        &second_wires,
    );
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = decoded,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-two"),
                .outputs = &second_outputs,
            },
            &successor_scratch,
            &successor_archive,
        ),
    );

    var wrong_completion = values.audio[1];
    wrong_completion.acknowledgement.previous_ack_result_sha256 =
        referenceIdentityV1("wrong-audio-completion-predecessor");
    const wrong_completion_before =
        try referenceAudioStateBeforeV1(wrong_completion);
    wrong_completion.plan.state_before_sha256 =
        wrong_completion_before.state_sha256;
    try resealReferenceAudioV1(&wrong_completion);
    _ = try checkpoint.audioProducerProjectionV1(
        wrong_completion.state_after,
        wrong_completion.plan,
        wrong_completion.provenance,
        wrong_completion.result,
        wrong_completion.acknowledgement,
    );
    try encodeReferenceAudioWiresV1(
        wrong_completion,
        1,
        &second_wires,
    );
    try std.testing.expectError(
        Error.InvalidProducerBinding,
        encodeArchiveV1(
            .{
                .previous = decoded,
                .generation_plan_sha256 = referenceIdentityV1("generation-plan-two"),
                .outputs = &second_outputs,
            },
            &successor_scratch,
            &successor_archive,
        ),
    );
}

fn expectEntryMappingV1(
    entry: registry.GeneratedMediaOutputEntryV1,
    member: checkpoint.GeneratedMediaMemberV1,
    modality: registry.ModalityV1,
    ordinal: u64,
    encoding_abi: u64,
    raw_output: []const u8,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,
) !void {
    try std.testing.expectEqual(modality, entry.modality);
    try std.testing.expectEqual(ordinal, entry.ordinal);
    try std.testing.expectEqual(member.unit_start, entry.unit_start);
    try std.testing.expectEqual(member.unit_count, entry.unit_count);
    try std.testing.expectEqual(member.unit_end, entry.unit_end);
    try std.testing.expectEqual(
        member.timeline_start,
        entry.timeline_start,
    );
    try std.testing.expectEqual(
        member.timeline_end,
        entry.timeline_end,
    );
    try std.testing.expectEqual(
        @as(u64, @intCast(raw_output.len)),
        entry.source_bytes,
    );
    try std.testing.expectEqual(encoding_abi, entry.encoding_abi);
    try std.testing.expectEqual(
        member.artifact_sha256,
        entry.artifact_sha256,
    );
    try std.testing.expectEqual(
        member.provenance_sha256,
        entry.provenance_sha256,
    );
    try std.testing.expectEqual(
        member.result_sha256,
        entry.result_sha256,
    );
    try std.testing.expectEqual(
        model.sha256(raw_output),
        entry.source_output_sha256,
    );
    try std.testing.expectEqual(
        member.output_sha256,
        entry.source_output_sha256,
    );
    try std.testing.expectEqual(
        member.media_object_sha256,
        entry.media_object_sha256,
    );
    try std.testing.expectEqual(
        member.state_after_sha256,
        entry.state_after_sha256,
    );
    try std.testing.expectEqual(
        member.completion_required == 1,
        entry.completion_required,
    );
    try std.testing.expectEqual(
        member.completed == 1,
        entry.completed,
    );
    try std.testing.expectEqual(
        member.completion_sha256,
        entry.completion_sha256,
    );
    try std.testing.expectEqual(
        encoder_implementation_sha256,
        entry.encoder_implementation_sha256,
    );
    try std.testing.expectEqual(
        format_sha256,
        entry.format_sha256,
    );
}

test {
    std.testing.refAllDecls(@This());
}
