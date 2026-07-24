//! Deterministic generated-media producer transition replay.
//!
//! Host-approved model and materializer callbacks are runtime bindings and are
//! never serialized. The canonical evidence proves that supplied bytes and
//! typed transitions agree with those bindings; it is not device attestation,
//! producer authorization, or proof that an external model previously ran.

const std = @import("std");
const model = @import("model_contract.zig");
const stateless = @import("stateless_model_adapter.zig");
const stateful = @import("stateful_model_adapter.zig");
const latent = @import("latent_step_adapter.zig");
const continuation = @import("stateful_model_continuation.zig");
const resource_bank = @import("resource_bank.zig");
const media = @import("media_contract.zig");
const image = @import("generated_image_publication.zig");
const audio = @import("generated_audio_playback.zig");
const video = @import("generated_video_display.zig");
const registry = @import("generated_media_output_registry.zig");
const checkpoint_file = @import("continuation_checkpoint_file.zig");

pub const Digest = [32]u8;
pub const abi: u64 = 1;
pub const allowed_flags: u64 = 0;

pub const model_publication_bytes: usize = 160;
pub const adapter_descriptor_bytes: usize = 256;
pub const media_publication_bytes: usize = 224;
pub const resource_receipt_bytes: usize = 192;
pub const transition_receipt_bytes: usize = 1728;
pub const transition_receipt_body_bytes: usize = 1696;
pub const transition_receipt_digest_count: usize = 44;
pub const batch_header_bytes: usize = 640;
pub const batch_body_bytes: usize = 608;
pub const batch_digest_count: usize = 12;
pub const max_support_records: usize = 32;

const model_publication_magic = "GLMPUB1\x00".*;
const adapter_descriptor_magic = "GLMADP1\x00".*;
const media_publication_magic = "GLMMPB1\x00".*;
const resource_receipt_magic = "GLMRCP1\x00".*;
const transition_receipt_magic = "GLMXTRN1".*;
const batch_magic = "GLMXBAT1".*;

const adapter_descriptor_domain =
    "glacier-generated-media-producer-transition-adapter-descriptor-v1\x00";
const resource_receipt_domain =
    "glacier-generated-media-producer-transition-resource-receipt-v1\x00";
const support_set_domain =
    "glacier-generated-media-producer-transition-support-set-v1\x00";
const stateless_source_mapping_domain =
    "glacier-generated-media-producer-transition-stateless-source-mapping-v1\x00";
const materializer_execution_domain =
    "glacier-generated-media-producer-transition-materializer-execution-v1\x00";
const producer_projection_domain =
    "glacier-generated-media-producer-transition-producer-projection-v1\x00";
const transition_receipt_domain =
    "glacier-generated-media-producer-transition-receipt-v1\x00";
const receipt_table_domain =
    "glacier-generated-media-producer-transition-receipt-table-v1\x00";
const batch_domain =
    "glacier-generated-media-producer-transition-batch-v1\x00";

const zero_digest = [_]u8{0} ** 32;

pub const Error = registry.Error || error{
    InvalidWire,
    InvalidWrapper,
    InvalidReceipt,
    InvalidBatch,
    InvalidBinding,
    InvalidModelExecution,
    InvalidProducerExecution,
    InvalidPreviousEvidence,
    UnsupportedModelBinding,
    UnsupportedMaterializer,
    ArithmeticOverflow,
    BufferTooSmall,
    BufferAlias,
};

pub const ModelKindV1 = enum(u64) {
    stateless = 1,
    stateful = 2,
};

pub const CompletionKindV1 = enum(u64) {
    none = 0,
    playback = 1,
    display = 2,
};

pub const ResourceReceiptEvidenceV1 = struct {
    receipt: resource_bank.Receipt,
    wire_sha256: Digest,
};

pub const TransitionReceiptV1 = struct {
    modality: registry.ModalityV1,
    model_kind: ModelKindV1,
    completion_kind: CompletionKindV1,
    request_epoch: u64,
    producer_generation: u64,
    producer_ordinal: u64,
    registry_ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    timeline_start: u64,
    timeline_end: u64,
    weights_bytes: u64,
    model_input_bytes: u64,
    model_state_before_bytes: u64,
    model_output_bytes: u64,
    model_state_after_bytes: u64,
    materializer_payload_bytes: u64,
    raw_output_bytes: u64,
    encoded_payload_bytes: u64,
    producer_publication_sequence: u64,
    completion_sequence: u64,
    model_required_capabilities: u64,
    materializer_required_capabilities: u64,
    model_step_before: u64,
    model_step_after: u64,
    producer_state_generation_before: u64,
    producer_state_generation_after_publication: u64,
    producer_state_generation_after_completion: u64,

    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    generation_plan_sha256: Digest,
    artifact_manifest_sha256: Digest,
    adapter_descriptor_sha256: Digest,
    support_set_sha256: Digest,
    model_plan_sha256: Digest,
    model_publication_before_sha256: Digest,
    model_state_publication_before_sha256: Digest,
    weights_sha256: Digest,
    model_input_sha256: Digest,
    model_state_before_sha256: Digest,
    model_output_sha256: Digest,
    model_state_after_sha256: Digest,
    model_transition_or_source_mapping_sha256: Digest,
    model_result_sha256: Digest,
    model_publication_after_sha256: Digest,
    model_state_publication_after_sha256: Digest,
    producer_plan_or_manifest_sha256: Digest,
    producer_state_before_sha256: Digest,
    media_object_sha256: Digest,
    materializer_payload_sha256: Digest,
    materializer_implementation_sha256: Digest,
    materializer_execution_sha256: Digest,
    raw_output_sha256: Digest,
    provenance_sha256: Digest,
    producer_receipt_wire_sha256: Digest,
    producer_resource_sha256: Digest,
    publication_result_sha256: Digest,
    producer_state_after_publication_sha256: Digest,
    completion_observation_sha256: Digest,
    completion_plan_sha256: Digest,
    completion_result_sha256: Digest,
    producer_final_state_sha256: Digest,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,
    encoded_payload_sha256: Digest,
    previous_transition_receipt_sha256: Digest,
    producer_projection_sha256: Digest,
    registry_previous_entry_sha256: Digest,
    registry_entry_sha256: Digest,
    registry_manifest_sha256: Digest,
    registry_archive_sha256: Digest,
    receipt_sha256: Digest,
};

pub const BatchEvidenceV1 = struct {
    request_epoch: u64,
    registry_generation: u64,
    publication_sequence: u64,
    receipt_count: u64,
    receipt_table_bytes: u64,
    aggregate_model_input_bytes: u64,
    aggregate_model_output_bytes: u64,
    aggregate_state_transition_bytes: u64,
    aggregate_materializer_payload_bytes: u64,
    aggregate_raw_output_bytes: u64,
    aggregate_encoded_payload_bytes: u64,
    modality_mask: u64,
    generation_plan_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    receipt_table_sha256: Digest,
    previous_batch_sha256: Digest,
    registry_manifest_sha256: Digest,
    registry_archive_sha256: Digest,
    first_receipt_sha256: Digest,
    terminal_image_sha256: Digest,
    terminal_audio_sha256: Digest,
    terminal_video_sha256: Digest,
    batch_sha256: Digest,
};

pub const DecodedBatchEvidenceV1 = struct {
    batch: BatchEvidenceV1,
    receipts: []const u8,
    encoded: []const u8,

    fn validatedView(
        self: DecodedBatchEvidenceV1,
    ) Error!DecodedBatchEvidenceV1 {
        const canonical = try decodeBatchEvidenceV1(self.encoded);
        if (!std.meta.eql(self.batch, canonical.batch) or
            !std.mem.eql(u8, self.receipts, canonical.receipts) or
            !std.mem.eql(u8, self.encoded, canonical.encoded))
            return Error.InvalidBatch;
        return canonical;
    }

    pub fn receipt(
        self: DecodedBatchEvidenceV1,
        index: usize,
    ) Error!TransitionReceiptV1 {
        const canonical = try self.validatedView();
        const count = std.math.cast(
            usize,
            canonical.batch.receipt_count,
        ) orelse return Error.InvalidBatch;
        if (index >= count) return Error.InvalidBatch;
        const start = std.math.mul(
            usize,
            index,
            transition_receipt_bytes,
        ) catch return Error.InvalidBatch;
        return decodeTransitionReceiptV1(
            canonical.receipts[start .. start + transition_receipt_bytes],
        );
    }

    pub fn terminal(
        self: DecodedBatchEvidenceV1,
        modality: registry.ModalityV1,
    ) Error!?TransitionReceiptV1 {
        const canonical = try self.validatedView();
        const expected = switch (modality) {
            .image => canonical.batch.terminal_image_sha256,
            .audio => canonical.batch.terminal_audio_sha256,
            .video => canonical.batch.terminal_video_sha256,
        };
        if (isZero(expected)) return null;
        const count = std.math.cast(
            usize,
            canonical.batch.receipt_count,
        ) orelse return Error.InvalidBatch;
        var found: ?TransitionReceiptV1 = null;
        for (0..count) |index| {
            const start = index * transition_receipt_bytes;
            const value = try decodeTransitionReceiptV1(
                canonical.receipts[start .. start + transition_receipt_bytes],
            );
            if (value.modality == modality) found = value;
        }
        const value = found orelse return Error.InvalidBatch;
        if (!digestEqual(value.receipt_sha256, expected))
            return Error.InvalidBatch;
        return value;
    }
};

pub fn encodeModelPublicationV1(
    value: model.PublicationStateV1,
    destination: []u8,
) Error![]const u8 {
    const root = model.publicationStateRootV1(value) catch
        return Error.InvalidWrapper;
    if (destination.len < model_publication_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..model_publication_bytes];
    @memset(output, 0);
    @memcpy(output[0..8], &model_publication_magic);
    writeU64(output, 8, abi);
    writeU64(output, 16, model_publication_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, value.request_epoch);
    writeU64(output, 40, value.next_sequence);
    writeU64(output, 48, value.visible_results);
    @memcpy(output[64..96], &value.artifact_sha256);
    @memcpy(output[96..128], &value.previous_result_sha256);
    @memcpy(output[128..160], &root);
    return output;
}

pub fn decodeModelPublicationV1(
    encoded: []const u8,
) Error!model.PublicationStateV1 {
    if (encoded.len != model_publication_bytes or
        !std.mem.eql(u8, encoded[0..8], &model_publication_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 16) != model_publication_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 56) != 0)
        return Error.InvalidWire;
    const value: model.PublicationStateV1 = .{
        .request_epoch = readU64(encoded, 32),
        .next_sequence = readU64(encoded, 40),
        .visible_results = readU64(encoded, 48),
        .artifact_sha256 = encoded[64..96].*,
        .previous_result_sha256 = encoded[96..128].*,
    };
    const root = model.publicationStateRootV1(value) catch
        return Error.InvalidWrapper;
    if (!digestEqual(root, encoded[128..160].*))
        return Error.InvalidWrapper;
    return value;
}

pub fn encodeAdapterDescriptorV1(
    value: stateless.AdapterDescriptorV1,
    destination: []u8,
) Error![]const u8 {
    if (!digestEqual(
        value.adapter_sha256,
        stateless.adapterDescriptorRootV1(value),
    ) or isZero(value.implementation_sha256))
        return Error.InvalidWrapper;
    if (destination.len < adapter_descriptor_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..adapter_descriptor_bytes];
    @memset(output, 0);
    @memcpy(output[0..8], &adapter_descriptor_magic);
    writeU64(output, 8, abi);
    writeU64(output, 16, adapter_descriptor_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, value.adapter_abi);
    writeU64(output, 40, @intFromEnum(value.family));
    writeU64(output, 48, @intFromEnum(value.operation));
    writeU64(output, 56, @intFromEnum(value.input_kind));
    writeU64(output, 64, @intFromEnum(value.output_kind));
    writeU64(output, 72, @intFromEnum(value.numerical_policy));
    writeU64(output, 80, value.max_batch_items);
    writeU64(output, 88, value.max_input_features);
    writeU64(output, 96, value.max_output_dimensions);
    writeU64(output, 104, value.allowed_capabilities);
    @memcpy(output[112..144], &value.implementation_sha256);
    @memcpy(output[144..176], &value.adapter_sha256);
    const root = domainRoot(
        adapter_descriptor_domain,
        output[0..224],
    );
    @memcpy(output[224..256], &root);
    return output;
}

pub fn decodeAdapterDescriptorV1(
    encoded: []const u8,
) Error!stateless.AdapterDescriptorV1 {
    if (encoded.len != adapter_descriptor_bytes or
        !std.mem.eql(u8, encoded[0..8], &adapter_descriptor_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 16) != adapter_descriptor_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[176..224], 0) or
        !digestEqual(
            encoded[224..256].*,
            domainRoot(adapter_descriptor_domain, encoded[0..224]),
        ))
        return Error.InvalidWire;
    const value: stateless.AdapterDescriptorV1 = .{
        .adapter_abi = readU64(encoded, 32),
        .family = std.meta.intToEnum(
            model.ModelFamilyIdV1,
            readU64(encoded, 40),
        ) catch return Error.InvalidWire,
        .operation = std.meta.intToEnum(
            model.OperationIdV1,
            readU64(encoded, 48),
        ) catch return Error.InvalidWire,
        .input_kind = std.meta.intToEnum(
            model.InputKindV1,
            readU64(encoded, 56),
        ) catch return Error.InvalidWire,
        .output_kind = std.meta.intToEnum(
            model.OutputKindV1,
            readU64(encoded, 64),
        ) catch return Error.InvalidWire,
        .numerical_policy = std.meta.intToEnum(
            model.NumericalPolicyV1,
            readU64(encoded, 72),
        ) catch return Error.InvalidWire,
        .max_batch_items = readU64(encoded, 80),
        .max_input_features = readU64(encoded, 88),
        .max_output_dimensions = readU64(encoded, 96),
        .allowed_capabilities = readU64(encoded, 104),
        .implementation_sha256 = encoded[112..144].*,
        .adapter_sha256 = encoded[144..176].*,
    };
    if (isZero(value.implementation_sha256) or
        !digestEqual(
            value.adapter_sha256,
            stateless.adapterDescriptorRootV1(value),
        ))
        return Error.InvalidWrapper;
    return value;
}

pub fn adapterDescriptorWireRootV1(
    encoded: []const u8,
) Error!Digest {
    _ = try decodeAdapterDescriptorV1(encoded);
    return encoded[224..256].*;
}

pub fn encodeMediaPublicationV1(
    value: media.PublicationStateV1,
    destination: []u8,
) Error![]const u8 {
    try validateMediaPublicationV1(value);
    if (destination.len < media_publication_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..media_publication_bytes];
    @memset(output, 0);
    @memcpy(output[0..8], &media_publication_magic);
    writeU64(output, 8, abi);
    writeU64(output, 16, media_publication_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, value.request_epoch);
    writeU64(output, 40, value.next_sequence);
    writeU64(output, 48, value.visible_chunks);
    writeU64(output, 56, value.visible_units);
    writeU64(output, 64, value.timeline_base.numerator);
    writeU64(output, 72, value.timeline_base.denominator);
    @memcpy(output[80..112], &value.media_object_sha256);
    @memcpy(output[112..144], &value.timeline_sha256);
    @memcpy(output[144..176], &value.previous_commit_sha256);
    const root = media.publicationStateRootV1(value);
    @memcpy(output[192..224], &root);
    return output;
}

pub fn decodeMediaPublicationV1(
    encoded: []const u8,
) Error!media.PublicationStateV1 {
    if (encoded.len != media_publication_bytes or
        !std.mem.eql(u8, encoded[0..8], &media_publication_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 16) != media_publication_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[176..192], 0))
        return Error.InvalidWire;
    const value: media.PublicationStateV1 = .{
        .request_epoch = readU64(encoded, 32),
        .next_sequence = readU64(encoded, 40),
        .visible_chunks = readU64(encoded, 48),
        .visible_units = readU64(encoded, 56),
        .timeline_base = .{
            .numerator = readU64(encoded, 64),
            .denominator = readU64(encoded, 72),
        },
        .media_object_sha256 = encoded[80..112].*,
        .timeline_sha256 = encoded[112..144].*,
        .previous_commit_sha256 = encoded[144..176].*,
    };
    try validateMediaPublicationV1(value);
    if (!digestEqual(
        media.publicationStateRootV1(value),
        encoded[192..224].*,
    ))
        return Error.InvalidWrapper;
    return value;
}

pub fn encodeResourceReceiptEvidenceV1(
    receipt: resource_bank.Receipt,
    destination: []u8,
) Error![]const u8 {
    if (!resource_bank.receiptIntegrityValidV1(receipt) or
        receipt.claim.isZero())
        return Error.InvalidReceipt;
    if (destination.len < resource_receipt_bytes)
        return Error.BufferTooSmall;
    const output = destination[0..resource_receipt_bytes];
    @memset(output, 0);
    @memcpy(output[0..8], &resource_receipt_magic);
    writeU64(output, 8, abi);
    writeU64(output, 16, resource_receipt_bytes);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, receipt.bank_epoch);
    writeU64(output, 40, receipt.slot_index);
    writeU64(output, 48, receipt.generation);
    writeU64(output, 56, receipt.owner_key);
    writeClaim(output, 64, receipt.claim);
    writeU64(output, 144, receipt.integrity);
    const root = domainRoot(resource_receipt_domain, output[0..160]);
    @memcpy(output[160..192], &root);
    return output;
}

pub fn decodeResourceReceiptEvidenceV1(
    encoded: []const u8,
) Error!ResourceReceiptEvidenceV1 {
    if (encoded.len != resource_receipt_bytes or
        !std.mem.eql(u8, encoded[0..8], &resource_receipt_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 16) != resource_receipt_bytes or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 152) != 0 or
        !digestEqual(
            encoded[160..192].*,
            domainRoot(resource_receipt_domain, encoded[0..160]),
        ))
        return Error.InvalidWire;
    const slot_index = std.math.cast(
        u32,
        readU64(encoded, 40),
    ) orelse return Error.InvalidReceipt;
    const receipt: resource_bank.Receipt = .{
        .bank_epoch = readU64(encoded, 32),
        .slot_index = slot_index,
        .generation = readU64(encoded, 48),
        .owner_key = readU64(encoded, 56),
        .claim = readClaim(encoded, 64),
        .integrity = readU64(encoded, 144),
    };
    if (!resource_bank.receiptIntegrityValidV1(receipt) or
        receipt.claim.isZero())
        return Error.InvalidReceipt;
    return .{
        .receipt = receipt,
        .wire_sha256 = encoded[160..192].*,
    };
}

fn validateMediaPublicationV1(
    value: media.PublicationStateV1,
) Error!void {
    if (value.request_epoch == 0 or value.next_sequence == 0 or
        value.timeline_base.numerator == 0 or
        value.timeline_base.denominator == 0 or
        isZero(value.media_object_sha256) or
        isZero(value.previous_commit_sha256) or
        (value.visible_chunks == 0 and
            (value.visible_units != 0 or
                !isZero(value.timeline_sha256))) or
        (value.visible_chunks > 0 and
            (value.visible_units == 0 or
                isZero(value.timeline_sha256))))
        return Error.InvalidWrapper;
}

pub fn encodeTransitionReceiptV1(
    value: TransitionReceiptV1,
    destination: []u8,
) Error![]const u8 {
    try validateTransitionReceiptFieldsV1(value);
    if (destination.len < transition_receipt_bytes)
        return Error.BufferTooSmall;
    var encoded: [transition_receipt_bytes]u8 = undefined;
    writeTransitionReceiptBodyV1(
        value,
        encoded[0..transition_receipt_body_bytes],
    );
    const root = domainRoot(
        transition_receipt_domain,
        encoded[0..transition_receipt_body_bytes],
    );
    if (!isZero(value.receipt_sha256) and
        !digestEqual(value.receipt_sha256, root))
        return Error.InvalidReceipt;
    @memcpy(encoded[1696..1728], &root);
    const output = destination[0..transition_receipt_bytes];
    @memcpy(output, &encoded);
    return output;
}

pub fn decodeTransitionReceiptV1(
    encoded: []const u8,
) Error!TransitionReceiptV1 {
    if (encoded.len != transition_receipt_bytes or
        !std.mem.eql(u8, encoded[0..8], &transition_receipt_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 16) != transition_receipt_bytes or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[1664..1696], 0) or
        !digestEqual(
            encoded[1696..1728].*,
            domainRoot(
                transition_receipt_domain,
                encoded[0..transition_receipt_body_bytes],
            ),
        ))
        return Error.InvalidWire;
    var value: TransitionReceiptV1 = .{
        .modality = std.meta.intToEnum(
            registry.ModalityV1,
            readU64(encoded, 32),
        ) catch return Error.InvalidWire,
        .model_kind = std.meta.intToEnum(
            ModelKindV1,
            readU64(encoded, 40),
        ) catch return Error.InvalidWire,
        .completion_kind = std.meta.intToEnum(
            CompletionKindV1,
            readU64(encoded, 48),
        ) catch return Error.InvalidWire,
        .request_epoch = readU64(encoded, 56),
        .producer_generation = readU64(encoded, 64),
        .producer_ordinal = readU64(encoded, 72),
        .registry_ordinal = readU64(encoded, 80),
        .unit_start = readU64(encoded, 88),
        .unit_count = readU64(encoded, 96),
        .timeline_start = readU64(encoded, 104),
        .timeline_end = readU64(encoded, 112),
        .weights_bytes = readU64(encoded, 120),
        .model_input_bytes = readU64(encoded, 128),
        .model_state_before_bytes = readU64(encoded, 136),
        .model_output_bytes = readU64(encoded, 144),
        .model_state_after_bytes = readU64(encoded, 152),
        .materializer_payload_bytes = readU64(encoded, 160),
        .raw_output_bytes = readU64(encoded, 168),
        .encoded_payload_bytes = readU64(encoded, 176),
        .producer_publication_sequence = readU64(encoded, 184),
        .completion_sequence = readU64(encoded, 192),
        .model_required_capabilities = readU64(encoded, 200),
        .materializer_required_capabilities = readU64(encoded, 208),
        .model_step_before = readU64(encoded, 216),
        .model_step_after = readU64(encoded, 224),
        .producer_state_generation_before = readU64(encoded, 232),
        .producer_state_generation_after_publication = readU64(encoded, 240),
        .producer_state_generation_after_completion = readU64(encoded, 248),
        .tenant_scope_sha256 = undefined,
        .metadata_policy_sha256 = undefined,
        .challenge_sha256 = undefined,
        .generation_plan_sha256 = undefined,
        .artifact_manifest_sha256 = undefined,
        .adapter_descriptor_sha256 = undefined,
        .support_set_sha256 = undefined,
        .model_plan_sha256 = undefined,
        .model_publication_before_sha256 = undefined,
        .model_state_publication_before_sha256 = undefined,
        .weights_sha256 = undefined,
        .model_input_sha256 = undefined,
        .model_state_before_sha256 = undefined,
        .model_output_sha256 = undefined,
        .model_state_after_sha256 = undefined,
        .model_transition_or_source_mapping_sha256 = undefined,
        .model_result_sha256 = undefined,
        .model_publication_after_sha256 = undefined,
        .model_state_publication_after_sha256 = undefined,
        .producer_plan_or_manifest_sha256 = undefined,
        .producer_state_before_sha256 = undefined,
        .media_object_sha256 = undefined,
        .materializer_payload_sha256 = undefined,
        .materializer_implementation_sha256 = undefined,
        .materializer_execution_sha256 = undefined,
        .raw_output_sha256 = undefined,
        .provenance_sha256 = undefined,
        .producer_receipt_wire_sha256 = undefined,
        .producer_resource_sha256 = undefined,
        .publication_result_sha256 = undefined,
        .producer_state_after_publication_sha256 = undefined,
        .completion_observation_sha256 = undefined,
        .completion_plan_sha256 = undefined,
        .completion_result_sha256 = undefined,
        .producer_final_state_sha256 = undefined,
        .encoder_implementation_sha256 = undefined,
        .format_sha256 = undefined,
        .encoded_payload_sha256 = undefined,
        .previous_transition_receipt_sha256 = undefined,
        .producer_projection_sha256 = undefined,
        .registry_previous_entry_sha256 = undefined,
        .registry_entry_sha256 = undefined,
        .registry_manifest_sha256 = undefined,
        .registry_archive_sha256 = undefined,
        .receipt_sha256 = encoded[1696..1728].*,
    };
    assignTransitionDigests(&value, encoded);
    try validateTransitionReceiptFieldsV1(value);
    return value;
}

pub fn transitionReceiptRootV1(
    value: TransitionReceiptV1,
) Error!Digest {
    try validateTransitionReceiptFieldsV1(value);
    var body: [transition_receipt_body_bytes]u8 = undefined;
    writeTransitionReceiptBodyV1(value, &body);
    return domainRoot(transition_receipt_domain, &body);
}

fn writeTransitionReceiptBodyV1(
    value: TransitionReceiptV1,
    output: []u8,
) void {
    std.debug.assert(output.len == transition_receipt_body_bytes);
    @memset(output, 0);
    @memcpy(output[0..8], &transition_receipt_magic);
    writeU64(output, 8, abi);
    writeU64(output, 16, transition_receipt_bytes);
    writeU64(output, 24, allowed_flags);
    inline for (.{
        .{ 32, @intFromEnum(value.modality) },
        .{ 40, @intFromEnum(value.model_kind) },
        .{ 48, @intFromEnum(value.completion_kind) },
        .{ 56, value.request_epoch },
        .{ 64, value.producer_generation },
        .{ 72, value.producer_ordinal },
        .{ 80, value.registry_ordinal },
        .{ 88, value.unit_start },
        .{ 96, value.unit_count },
        .{ 104, value.timeline_start },
        .{ 112, value.timeline_end },
        .{ 120, value.weights_bytes },
        .{ 128, value.model_input_bytes },
        .{ 136, value.model_state_before_bytes },
        .{ 144, value.model_output_bytes },
        .{ 152, value.model_state_after_bytes },
        .{ 160, value.materializer_payload_bytes },
        .{ 168, value.raw_output_bytes },
        .{ 176, value.encoded_payload_bytes },
        .{ 184, value.producer_publication_sequence },
        .{ 192, value.completion_sequence },
        .{ 200, value.model_required_capabilities },
        .{ 208, value.materializer_required_capabilities },
        .{ 216, value.model_step_before },
        .{ 224, value.model_step_after },
        .{ 232, value.producer_state_generation_before },
        .{ 240, value.producer_state_generation_after_publication },
        .{ 248, value.producer_state_generation_after_completion },
    }) |entry| writeU64(output, entry[0], entry[1]);
    const digests = transitionDigests(value);
    inline for (digests, 0..) |digest, index| {
        const offset = 256 + index * 32;
        @memcpy(output[offset .. offset + 32], &digest);
    }
}

fn transitionDigests(
    value: TransitionReceiptV1,
) [transition_receipt_digest_count]Digest {
    return .{
        value.tenant_scope_sha256,
        value.metadata_policy_sha256,
        value.challenge_sha256,
        value.generation_plan_sha256,
        value.artifact_manifest_sha256,
        value.adapter_descriptor_sha256,
        value.support_set_sha256,
        value.model_plan_sha256,
        value.model_publication_before_sha256,
        value.model_state_publication_before_sha256,
        value.weights_sha256,
        value.model_input_sha256,
        value.model_state_before_sha256,
        value.model_output_sha256,
        value.model_state_after_sha256,
        value.model_transition_or_source_mapping_sha256,
        value.model_result_sha256,
        value.model_publication_after_sha256,
        value.model_state_publication_after_sha256,
        value.producer_plan_or_manifest_sha256,
        value.producer_state_before_sha256,
        value.media_object_sha256,
        value.materializer_payload_sha256,
        value.materializer_implementation_sha256,
        value.materializer_execution_sha256,
        value.raw_output_sha256,
        value.provenance_sha256,
        value.producer_receipt_wire_sha256,
        value.producer_resource_sha256,
        value.publication_result_sha256,
        value.producer_state_after_publication_sha256,
        value.completion_observation_sha256,
        value.completion_plan_sha256,
        value.completion_result_sha256,
        value.producer_final_state_sha256,
        value.encoder_implementation_sha256,
        value.format_sha256,
        value.encoded_payload_sha256,
        value.previous_transition_receipt_sha256,
        value.producer_projection_sha256,
        value.registry_previous_entry_sha256,
        value.registry_entry_sha256,
        value.registry_manifest_sha256,
        value.registry_archive_sha256,
    };
}

fn assignTransitionDigests(
    value: *TransitionReceiptV1,
    encoded: []const u8,
) void {
    const digests = encoded[256..1664];
    value.tenant_scope_sha256 = digestAt(digests, 0);
    value.metadata_policy_sha256 = digestAt(digests, 1);
    value.challenge_sha256 = digestAt(digests, 2);
    value.generation_plan_sha256 = digestAt(digests, 3);
    value.artifact_manifest_sha256 = digestAt(digests, 4);
    value.adapter_descriptor_sha256 = digestAt(digests, 5);
    value.support_set_sha256 = digestAt(digests, 6);
    value.model_plan_sha256 = digestAt(digests, 7);
    value.model_publication_before_sha256 = digestAt(digests, 8);
    value.model_state_publication_before_sha256 = digestAt(digests, 9);
    value.weights_sha256 = digestAt(digests, 10);
    value.model_input_sha256 = digestAt(digests, 11);
    value.model_state_before_sha256 = digestAt(digests, 12);
    value.model_output_sha256 = digestAt(digests, 13);
    value.model_state_after_sha256 = digestAt(digests, 14);
    value.model_transition_or_source_mapping_sha256 =
        digestAt(digests, 15);
    value.model_result_sha256 = digestAt(digests, 16);
    value.model_publication_after_sha256 = digestAt(digests, 17);
    value.model_state_publication_after_sha256 = digestAt(digests, 18);
    value.producer_plan_or_manifest_sha256 = digestAt(digests, 19);
    value.producer_state_before_sha256 = digestAt(digests, 20);
    value.media_object_sha256 = digestAt(digests, 21);
    value.materializer_payload_sha256 = digestAt(digests, 22);
    value.materializer_implementation_sha256 = digestAt(digests, 23);
    value.materializer_execution_sha256 = digestAt(digests, 24);
    value.raw_output_sha256 = digestAt(digests, 25);
    value.provenance_sha256 = digestAt(digests, 26);
    value.producer_receipt_wire_sha256 = digestAt(digests, 27);
    value.producer_resource_sha256 = digestAt(digests, 28);
    value.publication_result_sha256 = digestAt(digests, 29);
    value.producer_state_after_publication_sha256 = digestAt(digests, 30);
    value.completion_observation_sha256 = digestAt(digests, 31);
    value.completion_plan_sha256 = digestAt(digests, 32);
    value.completion_result_sha256 = digestAt(digests, 33);
    value.producer_final_state_sha256 = digestAt(digests, 34);
    value.encoder_implementation_sha256 = digestAt(digests, 35);
    value.format_sha256 = digestAt(digests, 36);
    value.encoded_payload_sha256 = digestAt(digests, 37);
    value.previous_transition_receipt_sha256 = digestAt(digests, 38);
    value.producer_projection_sha256 = digestAt(digests, 39);
    value.registry_previous_entry_sha256 = digestAt(digests, 40);
    value.registry_entry_sha256 = digestAt(digests, 41);
    value.registry_manifest_sha256 = digestAt(digests, 42);
    value.registry_archive_sha256 = digestAt(digests, 43);
}

fn validateTransitionReceiptFieldsV1(
    value: TransitionReceiptV1,
) Error!void {
    if (value.request_epoch == 0 or
        value.producer_generation == 0 or
        value.unit_count == 0 or
        value.timeline_end <= value.timeline_start or
        value.weights_bytes == 0 or
        value.model_input_bytes == 0 or
        value.model_output_bytes == 0 or
        value.materializer_payload_bytes == 0 or
        value.raw_output_bytes == 0 or
        value.encoded_payload_bytes == 0 or
        value.model_step_after !=
            (checkedAdd(
                value.model_step_before,
                1,
            ) catch return Error.InvalidReceipt))
        return Error.InvalidReceipt;
    const common = [_]Digest{
        value.tenant_scope_sha256,
        value.metadata_policy_sha256,
        value.challenge_sha256,
        value.generation_plan_sha256,
        value.artifact_manifest_sha256,
        value.adapter_descriptor_sha256,
        value.support_set_sha256,
        value.model_plan_sha256,
        value.model_publication_before_sha256,
        value.weights_sha256,
        value.model_input_sha256,
        value.model_output_sha256,
        value.model_transition_or_source_mapping_sha256,
        value.model_result_sha256,
        value.model_publication_after_sha256,
        value.producer_plan_or_manifest_sha256,
        value.producer_state_before_sha256,
        value.media_object_sha256,
        value.materializer_payload_sha256,
        value.materializer_implementation_sha256,
        value.materializer_execution_sha256,
        value.raw_output_sha256,
        value.provenance_sha256,
        value.producer_receipt_wire_sha256,
        value.producer_resource_sha256,
        value.publication_result_sha256,
        value.producer_state_after_publication_sha256,
        value.producer_final_state_sha256,
        value.encoder_implementation_sha256,
        value.format_sha256,
        value.encoded_payload_sha256,
        value.producer_projection_sha256,
        value.registry_entry_sha256,
        value.registry_manifest_sha256,
        value.registry_archive_sha256,
    };
    for (common) |digest| {
        if (isZero(digest)) return Error.InvalidReceipt;
    }
    if (!digestEqual(
        value.materializer_execution_sha256,
        materializerExecutionRootV1(
            value.modality,
            value.producer_plan_or_manifest_sha256,
            value.model_output_sha256,
            value.materializer_payload_sha256,
            value.materializer_implementation_sha256,
            value.raw_output_sha256,
            value.materializer_required_capabilities,
            value.model_output_bytes,
            std.math.cast(
                usize,
                value.materializer_payload_bytes,
            ) orelse return Error.InvalidReceipt,
            std.math.cast(
                usize,
                value.raw_output_bytes,
            ) orelse return Error.InvalidReceipt,
        ),
    ) or !digestEqual(
        value.producer_projection_sha256,
        producerProjectionFromReceiptV1(value),
    ))
        return Error.InvalidReceipt;
    switch (value.model_kind) {
        .stateless => {
            if (value.model_state_before_bytes != 0 or
                value.model_state_after_bytes != 0 or
                !isZero(value.model_state_publication_before_sha256) or
                !isZero(value.model_state_before_sha256) or
                !isZero(value.model_state_after_sha256) or
                !isZero(value.model_state_publication_after_sha256))
                return Error.InvalidReceipt;
        },
        .stateful => {
            if (value.model_state_before_bytes == 0 or
                value.model_state_after_bytes == 0 or
                value.model_state_before_bytes !=
                    value.model_state_after_bytes or
                isZero(value.model_state_publication_before_sha256) or
                isZero(value.model_state_before_sha256) or
                isZero(value.model_state_after_sha256) or
                isZero(value.model_state_publication_after_sha256))
                return Error.InvalidReceipt;
        },
    }
    switch (value.modality) {
        .image => {
            if (value.model_kind != .stateful or
                value.completion_kind != .none or
                value.producer_ordinal != 1 or
                value.producer_publication_sequence == 0 or
                value.unit_start != value.registry_ordinal or
                value.unit_count != 1 or
                value.timeline_start != value.registry_ordinal or
                value.timeline_end !=
                    (checkedAdd(
                        value.registry_ordinal,
                        1,
                    ) catch return Error.InvalidReceipt) or
                value.completion_sequence != 0 or
                !isZero(value.completion_observation_sha256) or
                !isZero(value.completion_plan_sha256) or
                !isZero(value.completion_result_sha256) or
                !digestEqual(
                    value.producer_state_after_publication_sha256,
                    value.producer_final_state_sha256,
                ))
                return Error.InvalidReceipt;
        },
        .audio => {
            if (value.model_kind != .stateless or
                value.completion_kind != .playback or
                value.producer_ordinal != value.registry_ordinal or
                isZero(value.completion_observation_sha256) or
                isZero(value.completion_plan_sha256) or
                isZero(value.completion_result_sha256))
                return Error.InvalidReceipt;
        },
        .video => {
            if (value.model_kind != .stateless or
                value.completion_kind != .display or
                value.producer_ordinal != value.registry_ordinal or
                isZero(value.completion_observation_sha256) or
                isZero(value.completion_plan_sha256) or
                isZero(value.completion_result_sha256))
                return Error.InvalidReceipt;
        },
    }
    if ((value.registry_ordinal == 0) !=
        isZero(value.registry_previous_entry_sha256) or
        (value.registry_ordinal == 0) !=
            isZero(value.previous_transition_receipt_sha256))
        return Error.InvalidReceipt;
}

pub fn requiredEvidenceBytesV1(
    receipt_count: usize,
) Error!usize {
    if (receipt_count == 0 or receipt_count > registry.max_entries)
        return Error.InvalidBatch;
    return std.math.add(
        usize,
        batch_header_bytes,
        std.math.mul(
            usize,
            receipt_count,
            transition_receipt_bytes,
        ) catch return Error.ArithmeticOverflow,
    ) catch return Error.ArithmeticOverflow;
}

pub fn encodeBatchEvidenceV1(
    value: BatchEvidenceV1,
    receipt_table: []const u8,
    destination: []u8,
) Error![]const u8 {
    const count = std.math.cast(
        usize,
        value.receipt_count,
    ) orelse return Error.InvalidBatch;
    const required = try requiredEvidenceBytesV1(count);
    if (destination.len < required) return Error.BufferTooSmall;
    if (receipt_table.len != required - batch_header_bytes or
        value.receipt_table_bytes != receipt_table.len)
        return Error.InvalidBatch;
    try validateBatchBindingsV1(value, receipt_table);
    const output = destination[0..required];
    const output_table = output[batch_header_bytes..required];
    const same_table = receipt_table.ptr == output_table.ptr and
        receipt_table.len == output_table.len;
    if (!same_table and slicesOverlap(receipt_table, output))
        return Error.BufferAlias;
    var header: [batch_header_bytes]u8 = undefined;
    @memset(&header, 0);
    @memcpy(header[0..8], &batch_magic);
    writeU64(&header, 8, abi);
    writeU64(&header, 16, required);
    writeU64(&header, 24, allowed_flags);
    inline for (.{
        .{ 32, value.request_epoch },
        .{ 40, value.registry_generation },
        .{ 48, value.publication_sequence },
        .{ 56, value.receipt_count },
        .{ 64, value.receipt_table_bytes },
        .{ 72, value.aggregate_model_input_bytes },
        .{ 80, value.aggregate_model_output_bytes },
        .{ 88, value.aggregate_state_transition_bytes },
        .{ 96, value.aggregate_materializer_payload_bytes },
        .{ 104, value.aggregate_raw_output_bytes },
        .{ 112, value.aggregate_encoded_payload_bytes },
        .{ 120, value.modality_mask },
    }) |entry| writeU64(&header, entry[0], entry[1]);
    const digests = batchDigests(value);
    inline for (digests, 0..) |digest, index| {
        const offset = 128 + index * 32;
        @memcpy(header[offset .. offset + 32], &digest);
    }
    const root = domainRoot(
        batch_domain,
        header[0..batch_body_bytes],
    );
    if (!isZero(value.batch_sha256) and
        !digestEqual(value.batch_sha256, root))
        return Error.InvalidBatch;
    @memcpy(header[608..640], &root);
    @memcpy(output[0..batch_header_bytes], &header);
    if (!same_table) @memcpy(output_table, receipt_table);
    return output;
}

pub fn decodeBatchEvidenceV1(
    encoded: []const u8,
) Error!DecodedBatchEvidenceV1 {
    if (encoded.len < batch_header_bytes or
        !std.mem.eql(u8, encoded[0..8], &batch_magic) or
        readU64(encoded, 8) != abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != allowed_flags or
        !std.mem.allEqual(u8, encoded[512..608], 0) or
        !digestEqual(
            encoded[608..640].*,
            domainRoot(batch_domain, encoded[0..batch_body_bytes]),
        ))
        return Error.InvalidWire;
    const receipt_count = readU64(encoded, 56);
    const count = std.math.cast(
        usize,
        receipt_count,
    ) orelse return Error.InvalidBatch;
    const required = try requiredEvidenceBytesV1(count);
    if (required != encoded.len) return Error.InvalidBatch;
    const table_bytes = readU64(encoded, 64);
    if (table_bytes != encoded.len - batch_header_bytes)
        return Error.InvalidBatch;
    const value: BatchEvidenceV1 = .{
        .request_epoch = readU64(encoded, 32),
        .registry_generation = readU64(encoded, 40),
        .publication_sequence = readU64(encoded, 48),
        .receipt_count = receipt_count,
        .receipt_table_bytes = table_bytes,
        .aggregate_model_input_bytes = readU64(encoded, 72),
        .aggregate_model_output_bytes = readU64(encoded, 80),
        .aggregate_state_transition_bytes = readU64(encoded, 88),
        .aggregate_materializer_payload_bytes = readU64(encoded, 96),
        .aggregate_raw_output_bytes = readU64(encoded, 104),
        .aggregate_encoded_payload_bytes = readU64(encoded, 112),
        .modality_mask = readU64(encoded, 120),
        .generation_plan_sha256 = encoded[128..160].*,
        .tenant_scope_sha256 = encoded[160..192].*,
        .metadata_policy_sha256 = encoded[192..224].*,
        .challenge_sha256 = encoded[224..256].*,
        .receipt_table_sha256 = encoded[256..288].*,
        .previous_batch_sha256 = encoded[288..320].*,
        .registry_manifest_sha256 = encoded[320..352].*,
        .registry_archive_sha256 = encoded[352..384].*,
        .first_receipt_sha256 = encoded[384..416].*,
        .terminal_image_sha256 = encoded[416..448].*,
        .terminal_audio_sha256 = encoded[448..480].*,
        .terminal_video_sha256 = encoded[480..512].*,
        .batch_sha256 = encoded[608..640].*,
    };
    const receipts = encoded[640..];
    try validateBatchBindingsV1(value, receipts);
    return .{
        .batch = value,
        .receipts = receipts,
        .encoded = encoded,
    };
}

fn batchDigests(value: BatchEvidenceV1) [batch_digest_count]Digest {
    return .{
        value.generation_plan_sha256,
        value.tenant_scope_sha256,
        value.metadata_policy_sha256,
        value.challenge_sha256,
        value.receipt_table_sha256,
        value.previous_batch_sha256,
        value.registry_manifest_sha256,
        value.registry_archive_sha256,
        value.first_receipt_sha256,
        value.terminal_image_sha256,
        value.terminal_audio_sha256,
        value.terminal_video_sha256,
    };
}

fn validateBatchBindingsV1(
    value: BatchEvidenceV1,
    receipt_table: []const u8,
) Error!void {
    const count = std.math.cast(
        usize,
        value.receipt_count,
    ) orelse return Error.InvalidBatch;
    const expected_table = std.math.mul(
        usize,
        count,
        transition_receipt_bytes,
    ) catch return Error.InvalidBatch;
    if (count == 0 or count > registry.max_entries or
        receipt_table.len != expected_table or
        value.receipt_table_bytes != expected_table or
        value.request_epoch == 0 or value.registry_generation == 0 or
        value.publication_sequence == 0 or
        value.modality_mask == 0 or
        value.modality_mask & ~@as(u64, 0x7) != 0 or
        isZero(value.generation_plan_sha256) or
        isZero(value.tenant_scope_sha256) or
        isZero(value.metadata_policy_sha256) or
        isZero(value.challenge_sha256) or
        isZero(value.registry_manifest_sha256) or
        isZero(value.registry_archive_sha256) or
        isZero(value.first_receipt_sha256) or
        !digestEqual(
            value.receipt_table_sha256,
            domainRoot(receipt_table_domain, receipt_table),
        ))
        return Error.InvalidBatch;
    var aggregate_input: u64 = 0;
    var aggregate_output: u64 = 0;
    var aggregate_state: u64 = 0;
    var aggregate_materializer: u64 = 0;
    var aggregate_raw: u64 = 0;
    var aggregate_encoded: u64 = 0;
    var mask: u64 = 0;
    var first = zero_digest;
    var terminals = [_]Digest{zero_digest} ** 3;
    var counts = [_]u64{0} ** 3;
    var previous_modality: u64 = 0;
    var previous_ordinal: u64 = 0;
    for (0..count) |index| {
        const start = index * transition_receipt_bytes;
        const receipt = try decodeTransitionReceiptV1(
            receipt_table[start .. start + transition_receipt_bytes],
        );
        const modality_value = @intFromEnum(receipt.modality);
        if (index != 0 and
            (modality_value < previous_modality or
                (modality_value == previous_modality and
                    receipt.registry_ordinal <= previous_ordinal)))
            return Error.InvalidBatch;
        previous_modality = modality_value;
        previous_ordinal = receipt.registry_ordinal;
        if (receipt.request_epoch != value.request_epoch or
            !digestEqual(
                receipt.generation_plan_sha256,
                value.generation_plan_sha256,
            ) or
            !digestEqual(
                receipt.tenant_scope_sha256,
                value.tenant_scope_sha256,
            ) or
            !digestEqual(
                receipt.metadata_policy_sha256,
                value.metadata_policy_sha256,
            ) or
            !digestEqual(receipt.challenge_sha256, value.challenge_sha256) or
            !digestEqual(
                receipt.registry_manifest_sha256,
                value.registry_manifest_sha256,
            ) or
            !digestEqual(
                receipt.registry_archive_sha256,
                value.registry_archive_sha256,
            ))
            return Error.InvalidBatch;
        aggregate_input = try checkedAdd(
            aggregate_input,
            receipt.model_input_bytes,
        );
        aggregate_output = try checkedAdd(
            aggregate_output,
            receipt.model_output_bytes,
        );
        aggregate_state = try checkedAdd(
            aggregate_state,
            receipt.model_state_before_bytes,
        );
        aggregate_state = try checkedAdd(
            aggregate_state,
            receipt.model_state_after_bytes,
        );
        aggregate_materializer = try checkedAdd(
            aggregate_materializer,
            receipt.materializer_payload_bytes,
        );
        aggregate_raw = try checkedAdd(
            aggregate_raw,
            receipt.raw_output_bytes,
        );
        aggregate_encoded = try checkedAdd(
            aggregate_encoded,
            receipt.encoded_payload_bytes,
        );
        const slot = modalitySlot(receipt.modality);
        if (counts[slot] != 0 and
            !digestEqual(
                receipt.previous_transition_receipt_sha256,
                terminals[slot],
            ))
            return Error.InvalidBatch;
        counts[slot] = try checkedAdd(counts[slot], 1);
        if (counts[slot] > registry.max_outputs_per_modality)
            return Error.InvalidBatch;
        terminals[slot] = receipt.receipt_sha256;
        mask |= modalityBit(receipt.modality);
        if (index == 0) first = receipt.receipt_sha256;
    }
    if (aggregate_input != value.aggregate_model_input_bytes or
        aggregate_output != value.aggregate_model_output_bytes or
        aggregate_state != value.aggregate_state_transition_bytes or
        aggregate_materializer !=
            value.aggregate_materializer_payload_bytes or
        aggregate_raw != value.aggregate_raw_output_bytes or
        aggregate_encoded != value.aggregate_encoded_payload_bytes or
        mask != value.modality_mask or
        !digestEqual(first, value.first_receipt_sha256) or
        !digestEqual(terminals[0], value.terminal_image_sha256) or
        !digestEqual(terminals[1], value.terminal_audio_sha256) or
        !digestEqual(terminals[2], value.terminal_video_sha256))
        return Error.InvalidBatch;
}

pub const StatelessModelExecutionV1 = struct {
    artifact_manifest: []const u8,
    plan: []const u8,
    publication_before: []const u8,
    publication_after: []const u8,
    adapter_descriptor: []const u8,
    result: []const u8,
    support_records: []const model.SupportRecordV1,
    weights: []const u8,
    input: []const u8,
    output: []const u8,
    adapter: stateless.AdapterV1,
};

pub const StatefulCheckpointEvidenceV1 = struct {
    checkpoint: []const u8,
    previous_result: []const u8,
};

pub const StatefulModelExecutionV1 = struct {
    artifact_manifest: []const u8,
    plan: []const u8,
    publication_before: []const u8,
    publication_after: []const u8,
    state_publication_before: []const u8,
    state_publication_after: []const u8,
    checkpoint_before: StatefulCheckpointEvidenceV1,
    adapter_descriptor: []const u8,
    result: []const u8,
    support_records: []const model.SupportRecordV1,
    weights: []const u8,
    input: []const u8,
    state_before: []const u8,
    output: []const u8,
    state_after: []const u8,
    adapter: stateful.AdapterV1,
};

pub const ModelExecutionV1 = union(ModelKindV1) {
    stateless: StatelessModelExecutionV1,
    stateful: StatefulModelExecutionV1,
};

pub const ImageProducerExecutionV1 = struct {
    publication_before: []const u8,
    publication_after: []const u8,
    plan: []const u8,
    provenance: []const u8,
    result: []const u8,
    media_object: []const u8,
    resource_receipt: []const u8,
    materializer_payload: []const u8,
    raw_output: []const u8,
    decoder: image.DecoderV1,
};

pub const AudioProducerExecutionV1 = struct {
    state_before: []const u8,
    state_after_publication: []const u8,
    state_after_completion: []const u8,
    plan: []const u8,
    provenance: []const u8,
    result: []const u8,
    observation: []const u8,
    acknowledgement_plan: []const u8,
    acknowledgement_result: []const u8,
    media_object: []const u8,
    resource_receipt: []const u8,
    materializer_payload: []const u8,
    raw_output: []const u8,
    renderer: audio.RendererV1,
};

pub const VideoProducerExecutionV1 = struct {
    state_before: []const u8,
    state_after_publication: []const u8,
    state_after_completion: []const u8,
    manifest: []const u8,
    provenance: []const u8,
    result: []const u8,
    observation: []const u8,
    acknowledgement_plan: []const u8,
    acknowledgement_result: []const u8,
    media_object: []const u8,
    resource_receipt: []const u8,
    materializer_payload: []const u8,
    raw_output: []const u8,
    renderer: video.RendererV1,
};

pub const ProducerExecutionV1 = union(registry.ModalityV1) {
    image: ImageProducerExecutionV1,
    audio: AudioProducerExecutionV1,
    video: VideoProducerExecutionV1,
};

pub const OutputTransitionV1 = struct {
    model_execution: ModelExecutionV1,
    producer_execution: ProducerExecutionV1,
    encoding_abi: u64,
    encoded_payload: []const u8,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,
};

pub const PreviousGenerationV1 = struct {
    registry_archive: registry.DecodedArchiveV1,
    evidence: []const u8,
};

pub const BatchInputV1 = struct {
    previous: ?PreviousGenerationV1,
    generation_plan_sha256: Digest,
    outputs: []const OutputTransitionV1,
};

pub const PreparedTransitionV1 = struct {
    registry_archive: registry.PreparedArchiveV1,
    evidence: []const u8,
    batch: BatchEvidenceV1,
};

const ModelAdmissionV1 = struct {
    kind: ModelKindV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    result: model.ResultEnvelopeV1,
    publication_before: model.PublicationStateV1,
    publication_after: model.PublicationStateV1,
    state_publication_before: ?stateful.StatePublicationV1,
    state_publication_after: ?stateful.StatePublicationV1,
    checkpoint_before: ?continuation.CheckpointV1,
    adapter_descriptor_wire_sha256: Digest,
    support_set_sha256: Digest,
    transition_or_mapping_sha256: Digest,
    weights_sha256: Digest,
    input_sha256: Digest,
    state_before_sha256: Digest,
    output_sha256: Digest,
    state_after_sha256: Digest,
    output: []const u8,
    weights_bytes: u64,
    input_bytes: u64,
    state_before_bytes: u64,
    output_bytes: u64,
    state_after_bytes: u64,
    step_before: u64,
    step_after: u64,
};

fn replayModelExecutionV1(
    execution: ModelExecutionV1,
    callback_scratch: []u8,
) Error!ModelAdmissionV1 {
    return switch (execution) {
        .stateless => |value| replayStatelessModelV1(
            value,
            callback_scratch,
        ),
        .stateful => |value| replayStatefulModelV1(
            value,
            callback_scratch,
        ),
    };
}

fn replayStatelessModelV1(
    value: StatelessModelExecutionV1,
    callback_scratch: []u8,
) Error!ModelAdmissionV1 {
    const manifest = model.decodeArtifactManifestV1(
        value.artifact_manifest,
    ) catch return Error.InvalidModelExecution;
    const plan = model.decodeExecutionPlanV1(
        value.plan,
    ) catch return Error.InvalidModelExecution;
    const publication_before = try decodeModelPublicationV1(
        value.publication_before,
    );
    const publication_after = try decodeModelPublicationV1(
        value.publication_after,
    );
    const descriptor = try decodeAdapterDescriptorV1(
        value.adapter_descriptor,
    );
    const result = model.decodeResultEnvelopeV1(
        value.result,
    ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(descriptor, value.adapter.descriptor))
        return Error.InvalidModelExecution;
    stateless.validateAdapterForPlanV1(
        value.adapter,
        manifest,
        plan,
        value.support_records,
    ) catch return Error.InvalidModelExecution;
    const support_root = try supportSetRootV1(value.support_records);
    const output_len = std.math.cast(
        usize,
        plan.output_bytes,
    ) orelse return Error.InvalidModelExecution;
    if (value.weights.len != manifest.weight_bytes or
        value.weights.len != plan.weight_bytes or
        value.input.len != plan.input_bytes or
        value.output.len != output_len or
        callback_scratch.len < output_len or
        !digestEqual(model.sha256(value.weights), manifest.weights_sha256) or
        !digestEqual(model.sha256(value.weights), plan.weights_sha256))
        return Error.InvalidModelExecution;
    const candidate = callback_scratch[0..output_len];
    @memset(candidate, 0);
    defer @memset(candidate, 0);
    value.adapter.execute_fn(
        value.adapter.context,
        &plan,
        value.weights,
        value.input,
        candidate,
    ) catch return Error.InvalidModelExecution;
    value.adapter.validate_candidate_fn(
        value.adapter.context,
        &plan,
        candidate,
    ) catch return Error.InvalidModelExecution;
    if (!std.mem.eql(u8, candidate, value.output))
        return Error.InvalidModelExecution;
    const output_sha256 = model.sha256(value.output);
    const input_sha256 = model.sha256(value.input);
    const weights_sha256 = model.sha256(value.weights);
    const source_mapping = statelessSourceMappingRootV1(
        plan,
        weights_sha256,
        input_sha256,
        output_sha256,
        descriptor.adapter_sha256,
        value.weights.len,
        value.input.len,
        value.output.len,
    );
    const receipt = try receiptFromModelResultV1(result, plan);
    const expected_result = model.prepareResultEnvelopeV1(
        publication_before,
        plan,
        receipt,
        output_sha256,
        source_mapping,
        descriptor.adapter_sha256,
    ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(expected_result, result))
        return Error.InvalidModelExecution;
    var expected_after = publication_before;
    model.commitResultV1(
        &expected_after,
        expected_result,
    ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(expected_after, publication_after))
        return Error.InvalidModelExecution;
    return .{
        .kind = .stateless,
        .manifest = manifest,
        .plan = plan,
        .result = result,
        .publication_before = publication_before,
        .publication_after = publication_after,
        .state_publication_before = null,
        .state_publication_after = null,
        .checkpoint_before = null,
        .adapter_descriptor_wire_sha256 = try adapterDescriptorWireRootV1(value.adapter_descriptor),
        .support_set_sha256 = support_root,
        .transition_or_mapping_sha256 = source_mapping,
        .weights_sha256 = weights_sha256,
        .input_sha256 = input_sha256,
        .state_before_sha256 = zero_digest,
        .output_sha256 = output_sha256,
        .state_after_sha256 = zero_digest,
        .output = value.output,
        .weights_bytes = try usizeToU64(value.weights.len),
        .input_bytes = try usizeToU64(value.input.len),
        .state_before_bytes = 0,
        .output_bytes = try usizeToU64(value.output.len),
        .state_after_bytes = 0,
        .step_before = std.math.sub(
            u64,
            plan.generation,
            1,
        ) catch return Error.InvalidModelExecution,
        .step_after = plan.generation,
    };
}

fn replayStatefulModelV1(
    value: StatefulModelExecutionV1,
    callback_scratch: []u8,
) Error!ModelAdmissionV1 {
    const manifest = model.decodeArtifactManifestV1(
        value.artifact_manifest,
    ) catch return Error.InvalidModelExecution;
    const plan = model.decodeExecutionPlanV1(
        value.plan,
    ) catch return Error.InvalidModelExecution;
    const publication_before = try decodeModelPublicationV1(
        value.publication_before,
    );
    const publication_after = try decodeModelPublicationV1(
        value.publication_after,
    );
    const state_before = stateful.decodeStatePublicationV1(
        value.state_publication_before,
    ) catch return Error.InvalidModelExecution;
    const state_after = stateful.decodeStatePublicationV1(
        value.state_publication_after,
    ) catch return Error.InvalidModelExecution;
    const checkpoint = continuation.decodeCheckpointV1(
        value.checkpoint_before.checkpoint,
    ) catch return Error.InvalidModelExecution;
    const checkpoint_result = model.decodeResultEnvelopeV1(
        value.checkpoint_before.previous_result,
    ) catch return Error.InvalidModelExecution;
    const descriptor = try decodeAdapterDescriptorV1(
        value.adapter_descriptor,
    );
    const result = model.decodeResultEnvelopeV1(
        value.result,
    ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(descriptor, value.adapter.descriptor))
        return Error.InvalidModelExecution;
    stateful.validateAdapterForPlanV1(
        value.adapter,
        manifest,
        plan,
        value.support_records,
    ) catch return Error.InvalidModelExecution;
    const reconstructed_publication =
        continuation.reconstructModelPublicationV1(
            checkpoint,
            state_before,
        ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(
        reconstructed_publication,
        publication_before,
    ))
        return Error.InvalidModelExecution;
    const restore_plan: continuation.RestorePlanV1 = .{
        .restore_bank_epoch = checkpoint.restore_bank_epoch,
        .restore_owner_key = checkpoint.restore_owner_key,
        .restore_tree_key = checkpoint.restore_tree_key,
        .restore_authority_key = checkpoint.restore_authority_key,
        .tenant_key = checkpoint.tenant_key,
        .scope_key = checkpoint.scope_key,
        .allocation_key = checkpoint.allocation_key,
        .binding_key = checkpoint.binding_key,
    };
    const reconstructed_checkpoint = continuation.makeCheckpointV1(
        checkpoint.source_bank_epoch,
        restore_plan,
        publication_before,
        state_before,
        checkpoint_result,
    ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(reconstructed_checkpoint, checkpoint))
        return Error.InvalidModelExecution;
    const support_root = try supportSetRootV1(value.support_records);
    const output_len = std.math.cast(
        usize,
        plan.output_bytes,
    ) orelse return Error.InvalidModelExecution;
    const state_len = std.math.cast(
        usize,
        state_before.state_bytes,
    ) orelse return Error.InvalidModelExecution;
    const callback_bytes = std.math.add(
        usize,
        output_len,
        state_len,
    ) catch return Error.ArithmeticOverflow;
    if (value.weights.len != manifest.weight_bytes or
        value.weights.len != plan.weight_bytes or
        value.input.len != plan.input_bytes or
        value.state_before.len != state_len or
        value.output.len != output_len or
        value.state_after.len != state_len or
        callback_scratch.len < callback_bytes or
        !digestEqual(model.sha256(value.weights), manifest.weights_sha256) or
        !digestEqual(model.sha256(value.weights), plan.weights_sha256) or
        !digestEqual(
            model.sha256(value.state_before),
            state_before.current_state_sha256,
        ))
        return Error.InvalidModelExecution;
    const candidate_output = callback_scratch[0..output_len];
    const candidate_state =
        callback_scratch[output_len..callback_bytes];
    @memset(callback_scratch[0..callback_bytes], 0);
    defer @memset(callback_scratch[0..callback_bytes], 0);
    value.adapter.execute_fn(
        value.adapter.context,
        &plan,
        value.weights,
        value.input,
        value.state_before,
        candidate_output,
        candidate_state,
    ) catch return Error.InvalidModelExecution;
    value.adapter.validate_candidate_fn(
        value.adapter.context,
        &plan,
        value.state_before,
        candidate_output,
        candidate_state,
    ) catch return Error.InvalidModelExecution;
    if (!std.mem.eql(u8, candidate_output, value.output) or
        !std.mem.eql(u8, candidate_state, value.state_after))
        return Error.InvalidModelExecution;
    const output_sha256 = model.sha256(value.output);
    const next_state_sha256 = model.sha256(value.state_after);
    const transition = stateful.stateTransitionRootV1(
        state_before,
        plan,
        output_sha256,
        next_state_sha256,
        descriptor.adapter_sha256,
    ) catch return Error.InvalidModelExecution;
    const receipt = try receiptFromModelResultV1(result, plan);
    const expected_result = model.prepareResultEnvelopeV1(
        publication_before,
        plan,
        receipt,
        output_sha256,
        transition,
        descriptor.adapter_sha256,
    ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(expected_result, result))
        return Error.InvalidModelExecution;
    var expected_publication_after = publication_before;
    model.commitResultV1(
        &expected_publication_after,
        result,
    ) catch return Error.InvalidModelExecution;
    var expected_state_after = state_before;
    expected_state_after.current_step = std.math.add(
        u64,
        expected_state_after.current_step,
        1,
    ) catch return Error.InvalidModelExecution;
    expected_state_after.current_state_sha256 = next_state_sha256;
    expected_state_after.previous_result_sha256 = result.result_sha256;
    expected_state_after.publication_sha256 =
        stateful.statePublicationRootV1(expected_state_after);
    stateful.validateStatePublicationV1(
        expected_state_after,
    ) catch return Error.InvalidModelExecution;
    if (!std.meta.eql(
        expected_publication_after,
        publication_after,
    ) or !std.meta.eql(expected_state_after, state_after))
        return Error.InvalidModelExecution;
    return .{
        .kind = .stateful,
        .manifest = manifest,
        .plan = plan,
        .result = result,
        .publication_before = publication_before,
        .publication_after = publication_after,
        .state_publication_before = state_before,
        .state_publication_after = state_after,
        .checkpoint_before = checkpoint,
        .adapter_descriptor_wire_sha256 = try adapterDescriptorWireRootV1(value.adapter_descriptor),
        .support_set_sha256 = support_root,
        .transition_or_mapping_sha256 = transition,
        .weights_sha256 = model.sha256(value.weights),
        .input_sha256 = model.sha256(value.input),
        .state_before_sha256 = model.sha256(value.state_before),
        .output_sha256 = output_sha256,
        .state_after_sha256 = next_state_sha256,
        .output = value.output,
        .weights_bytes = try usizeToU64(value.weights.len),
        .input_bytes = try usizeToU64(value.input.len),
        .state_before_bytes = try usizeToU64(value.state_before.len),
        .output_bytes = try usizeToU64(value.output.len),
        .state_after_bytes = try usizeToU64(value.state_after.len),
        .step_before = state_before.current_step,
        .step_after = state_after.current_step,
    };
}

fn receiptFromModelResultV1(
    result: model.ResultEnvelopeV1,
    plan: model.ExecutionPlanV1,
) Error!resource_bank.Receipt {
    const receipt: resource_bank.Receipt = .{
        .bank_epoch = result.resource_bank_epoch,
        .slot_index = std.math.cast(
            u32,
            result.resource_slot_index,
        ) orelse return Error.InvalidModelExecution,
        .generation = result.resource_generation,
        .owner_key = result.resource_owner_key,
        .claim = result.claim,
        .integrity = result.resource_integrity,
    };
    if (!resource_bank.receiptIntegrityValidV1(receipt) or
        !std.meta.eql(receipt.claim, plan.claim))
        return Error.InvalidModelExecution;
    return receipt;
}

fn supportSetRootV1(
    records: []const model.SupportRecordV1,
) Error!Digest {
    if (records.len == 0 or records.len > max_support_records)
        return Error.InvalidModelExecution;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(support_set_domain);
    hashU64(&hash, try usizeToU64(records.len));
    var previous: ?model.SupportRecordV1 = null;
    for (records) |record| {
        if (previous) |prior| {
            if (!supportLessThan(prior, record))
                return Error.InvalidModelExecution;
        }
        inline for (.{
            @intFromEnum(record.family),
            @intFromEnum(record.operation),
            @intFromEnum(record.input_kind),
            @intFromEnum(record.output_kind),
            @intFromEnum(record.numerical_policy),
            record.max_batch_items,
            record.max_input_features,
            record.max_output_dimensions,
            record.allowed_capabilities,
        }) |scalar| hashU64(&hash, scalar);
        previous = record;
    }
    return hash.finalResult();
}

fn supportLessThan(
    left: model.SupportRecordV1,
    right: model.SupportRecordV1,
) bool {
    const left_values = [_]u64{
        @intFromEnum(left.family),
        @intFromEnum(left.operation),
        @intFromEnum(left.input_kind),
        @intFromEnum(left.output_kind),
        @intFromEnum(left.numerical_policy),
        left.max_batch_items,
        left.max_input_features,
        left.max_output_dimensions,
        left.allowed_capabilities,
    };
    const right_values = [_]u64{
        @intFromEnum(right.family),
        @intFromEnum(right.operation),
        @intFromEnum(right.input_kind),
        @intFromEnum(right.output_kind),
        @intFromEnum(right.numerical_policy),
        right.max_batch_items,
        right.max_input_features,
        right.max_output_dimensions,
        right.allowed_capabilities,
    };
    for (left_values, right_values) |lhs, rhs| {
        if (lhs != rhs) return lhs < rhs;
    }
    return false;
}

fn statelessSourceMappingRootV1(
    plan: model.ExecutionPlanV1,
    weights_sha256: Digest,
    input_sha256: Digest,
    output_sha256: Digest,
    adapter_sha256: Digest,
    weights_bytes_value: usize,
    input_bytes_value: usize,
    output_bytes_value: usize,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(stateless_source_mapping_domain);
    inline for (.{
        plan.plan_sha256,
        weights_sha256,
        input_sha256,
        output_sha256,
        adapter_sha256,
        plan.challenge_sha256,
    }) |digest| hash.update(&digest);
    hashU64(&hash, @intCast(weights_bytes_value));
    hashU64(&hash, @intCast(input_bytes_value));
    hashU64(&hash, @intCast(output_bytes_value));
    return hash.finalResult();
}

const ProducerAdmissionV1 = struct {
    modality: registry.ModalityV1,
    completion_kind: CompletionKindV1,
    request_epoch: u64,
    producer_generation: u64,
    producer_ordinal: u64,
    producer_publication_sequence: u64,
    completion_sequence: u64,
    unit_start: u64,
    unit_count: u64,
    timeline_start: u64,
    timeline_end: u64,
    state_generation_before: u64,
    state_generation_after_publication: u64,
    state_generation_after_completion: u64,
    artifact_sha256: Digest,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    plan_or_manifest_sha256: Digest,
    state_before_sha256: Digest,
    media_object_sha256: Digest,
    materializer_payload_sha256: Digest,
    materializer_implementation_sha256: Digest,
    materializer_execution_sha256: Digest,
    raw_output_sha256: Digest,
    provenance_sha256: Digest,
    producer_receipt_wire_sha256: Digest,
    producer_resource_sha256: Digest,
    publication_result_sha256: Digest,
    state_after_publication_sha256: Digest,
    completion_observation_sha256: Digest,
    completion_plan_sha256: Digest,
    completion_result_sha256: Digest,
    final_state_sha256: Digest,
    previous_plan_sha256: Digest,
    previous_result_sha256: Digest,
    previous_completion_sha256: Digest,
    required_capabilities: u64,
    materializer_payload_bytes: u64,
    raw_output_bytes: u64,
};

fn replayProducerExecutionV1(
    execution: ProducerExecutionV1,
    source: ModelAdmissionV1,
    callback_scratch: []u8,
) Error!ProducerAdmissionV1 {
    return switch (execution) {
        .image => |value| replayImageProducerV1(
            value,
            source,
            callback_scratch,
        ),
        .audio => |value| replayAudioProducerV1(
            value,
            source,
            callback_scratch,
        ),
        .video => |value| replayVideoProducerV1(
            value,
            source,
            callback_scratch,
        ),
    };
}

fn replayImageProducerV1(
    value: ImageProducerExecutionV1,
    source: ModelAdmissionV1,
    callback_scratch: []u8,
) Error!ProducerAdmissionV1 {
    if (source.kind != .stateful)
        return Error.InvalidProducerExecution;
    const checkpoint = source.checkpoint_before orelse
        return Error.InvalidProducerExecution;
    const state_publication = source.state_publication_after orelse
        return Error.InvalidProducerExecution;
    const publication_before = try decodeMediaPublicationV1(
        value.publication_before,
    );
    const publication_after = try decodeMediaPublicationV1(
        value.publication_after,
    );
    const plan = image.decodeGeneratedImagePlanV1(
        value.plan,
    ) catch return Error.InvalidProducerExecution;
    const provenance = image.decodeGeneratedImageProvenanceV1(
        value.provenance,
    ) catch return Error.InvalidProducerExecution;
    const result = image.decodeGeneratedImageResultV1(
        value.result,
    ) catch return Error.InvalidProducerExecution;
    const media_object = media.decodeMediaObjectV1(
        value.media_object,
    ) catch return Error.InvalidProducerExecution;
    const resource = try decodeResourceReceiptEvidenceV1(
        value.resource_receipt,
    );
    const expected_plan = image.makeGeneratedImagePlanV1(
        source.manifest,
        checkpoint,
        source.plan,
        source.result,
        state_publication,
        media_object,
        value.materializer_payload,
        value.decoder,
        publication_before,
        plan.previous_plan_sha256,
        plan.previous_result_sha256,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_plan, plan) or
        plan.image_index != 1 or
        plan.visible_images_before != 0 or
        plan.visible_images_after != 1 or
        !digestEqual(plan.terminal_result_sha256, source.result.result_sha256) or
        !digestEqual(plan.terminal_plan_sha256, source.plan.plan_sha256) or
        !digestEqual(
            plan.terminal_output_sha256,
            source.output_sha256,
        ) or
        !digestEqual(
            plan.terminal_state_publication_sha256,
            state_publication.publication_sha256,
        ))
        return Error.InvalidProducerExecution;
    const expected_claim = image.claimForPlanV1(
        plan,
        try usizeToU64(value.materializer_payload.len),
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(resource.receipt.claim, expected_claim))
        return Error.InvalidProducerExecution;
    const raw_len = std.math.cast(
        usize,
        plan.pixel_bytes,
    ) orelse return Error.InvalidProducerExecution;
    if (value.raw_output.len != raw_len or
        callback_scratch.len < raw_len)
        return Error.InvalidProducerExecution;
    const candidate = callback_scratch[0..raw_len];
    @memset(candidate, 0);
    defer @memset(candidate, 0);
    value.decoder.execute(
        value.decoder.context,
        &plan,
        source.output,
        value.materializer_payload,
        candidate,
    ) catch return Error.InvalidProducerExecution;
    value.decoder.validate(
        value.decoder.context,
        &plan,
        source.output,
        value.materializer_payload,
        candidate,
    ) catch return Error.InvalidProducerExecution;
    if (!std.mem.eql(u8, candidate, value.raw_output))
        return Error.InvalidProducerExecution;
    const raw_root = model.sha256(value.raw_output);
    if (!digestEqual(media_object.content_sha256, raw_root))
        return Error.InvalidProducerExecution;
    const expected_provenance =
        image.makeGeneratedImageProvenanceV1(
            plan,
            raw_root,
        ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_provenance, provenance))
        return Error.InvalidProducerExecution;
    image.validateGeneratedImageProvenanceBindingsV1(
        plan,
        provenance,
        media_object,
    ) catch return Error.InvalidProducerExecution;
    const event = image.timelineEventForPlanV1(
        plan,
        publication_before,
    ) catch return Error.InvalidProducerExecution;
    const resource_root = image.resourceReceiptRootV1(
        resource.receipt,
        plan.request_epoch,
        plan.plan_sha256,
        plan.decoder_implementation_sha256,
    );
    const prepared = media.preparePublicationV1(
        publication_before,
        event,
        raw_root,
        resource_root,
    ) catch return Error.InvalidProducerExecution;
    var expected_publication_after = publication_before;
    media.commitPublicationV1(
        &expected_publication_after,
        prepared,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(
        expected_publication_after,
        publication_after,
    ))
        return Error.InvalidProducerExecution;
    const expected_result = image.makeGeneratedImageResultV1(
        plan,
        provenance,
        media_object,
        resource.receipt,
        publication_before,
        event,
        prepared,
        publication_after,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_result, result))
        return Error.InvalidProducerExecution;
    return .{
        .modality = .image,
        .completion_kind = .none,
        .request_epoch = plan.request_epoch,
        .producer_generation = plan.generation,
        .producer_ordinal = plan.image_index,
        .producer_publication_sequence = plan.publication_sequence,
        .completion_sequence = 0,
        .unit_start = 0,
        .unit_count = 1,
        .timeline_start = 0,
        .timeline_end = 1,
        .state_generation_before = publication_before.visible_chunks,
        .state_generation_after_publication = publication_after.visible_chunks,
        .state_generation_after_completion = publication_after.visible_chunks,
        .artifact_sha256 = plan.artifact_sha256,
        .tenant_scope_sha256 = plan.tenant_scope_sha256,
        .metadata_policy_sha256 = plan.metadata_policy_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .plan_or_manifest_sha256 = plan.plan_sha256,
        .state_before_sha256 = media.publicationStateRootV1(publication_before),
        .media_object_sha256 = plan.media_object_sha256,
        .materializer_payload_sha256 = model.sha256(value.materializer_payload),
        .materializer_implementation_sha256 = plan.decoder_implementation_sha256,
        .materializer_execution_sha256 = materializerExecutionRootV1(
            .image,
            plan.plan_sha256,
            source.output_sha256,
            model.sha256(value.materializer_payload),
            plan.decoder_implementation_sha256,
            raw_root,
            plan.required_capabilities,
            source.output_bytes,
            value.materializer_payload.len,
            value.raw_output.len,
        ),
        .raw_output_sha256 = raw_root,
        .provenance_sha256 = provenance.provenance_sha256,
        .producer_receipt_wire_sha256 = resource.wire_sha256,
        .producer_resource_sha256 = resource_root,
        .publication_result_sha256 = result.result_sha256,
        .state_after_publication_sha256 = media.publicationStateRootV1(publication_after),
        .completion_observation_sha256 = zero_digest,
        .completion_plan_sha256 = zero_digest,
        .completion_result_sha256 = zero_digest,
        .final_state_sha256 = media.publicationStateRootV1(publication_after),
        .previous_plan_sha256 = plan.previous_plan_sha256,
        .previous_result_sha256 = plan.previous_result_sha256,
        .previous_completion_sha256 = zero_digest,
        .required_capabilities = plan.required_capabilities,
        .materializer_payload_bytes = try usizeToU64(value.materializer_payload.len),
        .raw_output_bytes = try usizeToU64(value.raw_output.len),
    };
}

fn replayAudioProducerV1(
    value: AudioProducerExecutionV1,
    source: ModelAdmissionV1,
    callback_scratch: []u8,
) Error!ProducerAdmissionV1 {
    if (source.kind != .stateless)
        return Error.InvalidProducerExecution;
    const before = audio.decodeStateV1(
        value.state_before,
    ) catch return Error.InvalidProducerExecution;
    const after_publication = audio.decodeStateV1(
        value.state_after_publication,
    ) catch return Error.InvalidProducerExecution;
    const after_completion = audio.decodeStateV1(
        value.state_after_completion,
    ) catch return Error.InvalidProducerExecution;
    const plan = audio.decodePlanV1(
        value.plan,
    ) catch return Error.InvalidProducerExecution;
    const provenance = audio.decodeProvenanceV1(
        value.provenance,
    ) catch return Error.InvalidProducerExecution;
    const result = audio.decodeResultV1(
        value.result,
    ) catch return Error.InvalidProducerExecution;
    const observation = audio.decodePlaybackObservationV1(
        value.observation,
    ) catch return Error.InvalidProducerExecution;
    const acknowledgement_plan = audio.decodePlaybackAckPlanV1(
        value.acknowledgement_plan,
    ) catch return Error.InvalidProducerExecution;
    const acknowledgement_result = audio.decodePlaybackAckResultV1(
        value.acknowledgement_result,
    ) catch return Error.InvalidProducerExecution;
    const media_object = media.decodeMediaObjectV1(
        value.media_object,
    ) catch return Error.InvalidProducerExecution;
    const resource = try decodeResourceReceiptEvidenceV1(
        value.resource_receipt,
    );
    if (!digestEqual(plan.source_result_sha256, source.result.result_sha256) or
        !digestEqual(plan.source_output_sha256, source.output_sha256) or
        plan.source_output_bytes != source.output_bytes)
        return Error.InvalidProducerExecution;
    const expected_plan = audio.makePlanV1(
        before,
        plan.frame_count,
        plan.source_output_bytes,
        plan.maximum_output_bytes,
        plan.required_capabilities,
        plan.renderer_abi,
        source.result.result_sha256,
        source.output_sha256,
        model.sha256(value.materializer_payload),
        value.renderer.implementation_sha256,
        plan.media_object_sha256,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_plan, plan))
        return Error.InvalidProducerExecution;
    audio.validatePublicationBindingsV1(
        plan,
        before,
        media_object,
        value.materializer_payload,
        value.renderer,
    ) catch return Error.InvalidProducerExecution;
    const expected_claim = audio.claimForPlanV1(
        plan,
        try usizeToU64(value.materializer_payload.len),
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(resource.receipt.claim, expected_claim))
        return Error.InvalidProducerExecution;
    const raw_len = std.math.cast(
        usize,
        plan.pcm_bytes,
    ) orelse return Error.InvalidProducerExecution;
    if (value.raw_output.len != raw_len or
        callback_scratch.len < raw_len)
        return Error.InvalidProducerExecution;
    const candidate = callback_scratch[0..raw_len];
    @memset(candidate, 0);
    defer @memset(candidate, 0);
    value.renderer.execute(
        value.renderer.context,
        &plan,
        source.output,
        value.materializer_payload,
        candidate,
    ) catch return Error.InvalidProducerExecution;
    value.renderer.validate(
        value.renderer.context,
        &plan,
        source.output,
        value.materializer_payload,
        candidate,
    ) catch return Error.InvalidProducerExecution;
    if (!std.mem.eql(u8, candidate, value.raw_output))
        return Error.InvalidProducerExecution;
    const raw_root = model.sha256(value.raw_output);
    const expected_media = audio.makeAudioMediaObjectV1(
        before,
        plan.frame_count,
        raw_root,
        source.result.result_sha256,
        source.output_sha256,
        plan.renderer_implementation_sha256,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_media, media_object))
        return Error.InvalidProducerExecution;
    const expected_provenance = audio.makeProvenanceV1(
        plan,
        raw_root,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_provenance, provenance))
        return Error.InvalidProducerExecution;
    const expected_result = audio.makeResultV1(
        plan,
        provenance,
        resource.receipt,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_result, result))
        return Error.InvalidProducerExecution;
    const expected_pending = audio.stateAfterPublicationV1(
        before,
        plan,
        result,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_pending, after_publication))
        return Error.InvalidProducerExecution;
    const expected_observation = audio.makePlaybackObservationV1(
        after_publication,
        observation.sink_implementation_sha256,
        observation.sink_instance_sha256,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_observation, observation))
        return Error.InvalidProducerExecution;
    const expected_ack_plan = audio.makePlaybackAckPlanV1(
        after_publication,
        result,
        observation,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_ack_plan, acknowledgement_plan))
        return Error.InvalidProducerExecution;
    var expected_final = after_publication;
    const expected_ack_result = audio.acknowledgePlaybackV1(
        &expected_final,
        result,
        observation,
        acknowledgement_plan,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_ack_result, acknowledgement_result) or
        !std.meta.eql(expected_final, after_completion))
        return Error.InvalidProducerExecution;
    const resource_root = audio.resourceReceiptRootV1(
        resource.receipt,
        plan.request_epoch,
        plan.plan_sha256,
        plan.renderer_implementation_sha256,
    );
    return .{
        .modality = .audio,
        .completion_kind = .playback,
        .request_epoch = plan.request_epoch,
        .producer_generation = plan.generation,
        .producer_ordinal = plan.chunk_index,
        .producer_publication_sequence = plan.publication_sequence,
        .completion_sequence = acknowledgement_result.playback_sequence,
        .unit_start = plan.start_frame,
        .unit_count = plan.frame_count,
        .timeline_start = plan.start_frame,
        .timeline_end = plan.visible_frames_after,
        .state_generation_before = before.generation,
        .state_generation_after_publication = after_publication.generation,
        .state_generation_after_completion = after_completion.generation,
        .artifact_sha256 = plan.artifact_sha256,
        .tenant_scope_sha256 = plan.tenant_scope_sha256,
        .metadata_policy_sha256 = plan.metadata_policy_sha256,
        .challenge_sha256 = plan.challenge_sha256,
        .plan_or_manifest_sha256 = plan.plan_sha256,
        .state_before_sha256 = before.state_sha256,
        .media_object_sha256 = plan.media_object_sha256,
        .materializer_payload_sha256 = model.sha256(value.materializer_payload),
        .materializer_implementation_sha256 = plan.renderer_implementation_sha256,
        .materializer_execution_sha256 = materializerExecutionRootV1(
            .audio,
            plan.plan_sha256,
            source.output_sha256,
            model.sha256(value.materializer_payload),
            plan.renderer_implementation_sha256,
            raw_root,
            plan.required_capabilities,
            source.output_bytes,
            value.materializer_payload.len,
            value.raw_output.len,
        ),
        .raw_output_sha256 = raw_root,
        .provenance_sha256 = provenance.provenance_sha256,
        .producer_receipt_wire_sha256 = resource.wire_sha256,
        .producer_resource_sha256 = resource_root,
        .publication_result_sha256 = result.result_sha256,
        .state_after_publication_sha256 = after_publication.state_sha256,
        .completion_observation_sha256 = observation.observation_sha256,
        .completion_plan_sha256 = acknowledgement_plan.plan_sha256,
        .completion_result_sha256 = acknowledgement_result.result_sha256,
        .final_state_sha256 = after_completion.state_sha256,
        .previous_plan_sha256 = zero_digest,
        .previous_result_sha256 = plan.previous_publication_result_sha256,
        .previous_completion_sha256 = acknowledgement_result.previous_ack_result_sha256,
        .required_capabilities = plan.required_capabilities,
        .materializer_payload_bytes = try usizeToU64(value.materializer_payload.len),
        .raw_output_bytes = try usizeToU64(value.raw_output.len),
    };
}

fn replayVideoProducerV1(
    value: VideoProducerExecutionV1,
    source: ModelAdmissionV1,
    callback_scratch: []u8,
) Error!ProducerAdmissionV1 {
    if (source.kind != .stateless)
        return Error.InvalidProducerExecution;
    const before = video.decodeStateV1(
        value.state_before,
    ) catch return Error.InvalidProducerExecution;
    const after_publication = video.decodeStateV1(
        value.state_after_publication,
    ) catch return Error.InvalidProducerExecution;
    const after_completion = video.decodeStateV1(
        value.state_after_completion,
    ) catch return Error.InvalidProducerExecution;
    const manifest = video.decodeManifestV1(
        value.manifest,
    ) catch return Error.InvalidProducerExecution;
    const provenance = video.decodeProvenanceV1(
        value.provenance,
    ) catch return Error.InvalidProducerExecution;
    const result = video.decodeResultV1(
        value.result,
    ) catch return Error.InvalidProducerExecution;
    const observation = video.decodeDisplayObservationV1(
        value.observation,
    ) catch return Error.InvalidProducerExecution;
    const acknowledgement_plan = video.decodeDisplayAckPlanV1(
        value.acknowledgement_plan,
    ) catch return Error.InvalidProducerExecution;
    const acknowledgement_result = video.decodeDisplayAckResultV1(
        value.acknowledgement_result,
    ) catch return Error.InvalidProducerExecution;
    const media_object = media.decodeMediaObjectV1(
        value.media_object,
    ) catch return Error.InvalidProducerExecution;
    const resource = try decodeResourceReceiptEvidenceV1(
        value.resource_receipt,
    );
    if (!digestEqual(
        manifest.source_result_sha256,
        source.result.result_sha256,
    ) or
        !digestEqual(manifest.source_output_sha256, source.output_sha256) or
        manifest.source_output_bytes != source.output_bytes)
        return Error.InvalidProducerExecution;
    const expected_manifest = video.makeManifestV1(
        before,
        manifest.first_duration_ticks,
        manifest.second_duration_ticks,
        manifest.source_output_bytes,
        manifest.maximum_output_bytes,
        manifest.required_capabilities,
        manifest.renderer_abi,
        source.result.result_sha256,
        source.output_sha256,
        model.sha256(value.materializer_payload),
        value.renderer.implementation_sha256,
        manifest.media_object_sha256,
        manifest.first_frame_sha256,
        manifest.second_frame_sha256,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_manifest, manifest))
        return Error.InvalidProducerExecution;
    video.validatePublicationBindingsV1(
        manifest,
        before,
        media_object,
        value.materializer_payload,
        value.renderer,
    ) catch return Error.InvalidProducerExecution;
    const expected_claim = video.claimForManifestV1(
        manifest,
        try usizeToU64(value.materializer_payload.len),
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(resource.receipt.claim, expected_claim))
        return Error.InvalidProducerExecution;
    const raw_len = std.math.cast(
        usize,
        manifest.total_output_bytes,
    ) orelse return Error.InvalidProducerExecution;
    if (value.raw_output.len != raw_len or
        callback_scratch.len < raw_len)
        return Error.InvalidProducerExecution;
    const candidate = callback_scratch[0..raw_len];
    @memset(candidate, 0);
    defer @memset(candidate, 0);
    value.renderer.execute(
        value.renderer.context,
        &manifest,
        source.output,
        value.materializer_payload,
        candidate,
    ) catch return Error.InvalidProducerExecution;
    value.renderer.validate(
        value.renderer.context,
        &manifest,
        source.output,
        value.materializer_payload,
        candidate,
    ) catch return Error.InvalidProducerExecution;
    if (!std.mem.eql(u8, candidate, value.raw_output))
        return Error.InvalidProducerExecution;
    const raw_root = model.sha256(value.raw_output);
    if (!digestEqual(media_object.content_sha256, raw_root))
        return Error.InvalidProducerExecution;
    const expected_provenance = video.makeProvenanceV1(
        manifest,
        raw_root,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_provenance, provenance))
        return Error.InvalidProducerExecution;
    const expected_result = video.makeResultV1(
        manifest,
        provenance,
        resource.receipt,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_result, result))
        return Error.InvalidProducerExecution;
    const expected_pending = video.stateAfterPublicationV1(
        before,
        manifest,
        result,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_pending, after_publication))
        return Error.InvalidProducerExecution;
    const expected_observation = video.makeDisplayObservationV1(
        after_publication,
        observation.sink_implementation_sha256,
        observation.sink_instance_sha256,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_observation, observation))
        return Error.InvalidProducerExecution;
    const expected_ack_plan = video.makeDisplayAckPlanV1(
        after_publication,
        result,
        observation,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_ack_plan, acknowledgement_plan))
        return Error.InvalidProducerExecution;
    var expected_final = after_publication;
    const expected_ack_result = video.acknowledgeDisplayV1(
        &expected_final,
        result,
        observation,
        acknowledgement_plan,
    ) catch return Error.InvalidProducerExecution;
    if (!std.meta.eql(expected_ack_result, acknowledgement_result) or
        !std.meta.eql(expected_final, after_completion))
        return Error.InvalidProducerExecution;
    const resource_root = video.resourceReceiptRootV1(
        resource.receipt,
        manifest.request_epoch,
        manifest.manifest_sha256,
        manifest.renderer_implementation_sha256,
    );
    return .{
        .modality = .video,
        .completion_kind = .display,
        .request_epoch = manifest.request_epoch,
        .producer_generation = manifest.generation,
        .producer_ordinal = manifest.segment_index,
        .producer_publication_sequence = manifest.publication_sequence,
        .completion_sequence = acknowledgement_result.display_sequence,
        .unit_start = manifest.first_frame_ordinal,
        .unit_count = manifest.frame_count,
        .timeline_start = manifest.start_tick,
        .timeline_end = manifest.end_tick,
        .state_generation_before = before.generation,
        .state_generation_after_publication = after_publication.generation,
        .state_generation_after_completion = after_completion.generation,
        .artifact_sha256 = manifest.artifact_sha256,
        .tenant_scope_sha256 = manifest.tenant_scope_sha256,
        .metadata_policy_sha256 = manifest.metadata_policy_sha256,
        .challenge_sha256 = manifest.challenge_sha256,
        .plan_or_manifest_sha256 = manifest.manifest_sha256,
        .state_before_sha256 = before.state_sha256,
        .media_object_sha256 = manifest.media_object_sha256,
        .materializer_payload_sha256 = model.sha256(value.materializer_payload),
        .materializer_implementation_sha256 = manifest.renderer_implementation_sha256,
        .materializer_execution_sha256 = materializerExecutionRootV1(
            .video,
            manifest.manifest_sha256,
            source.output_sha256,
            model.sha256(value.materializer_payload),
            manifest.renderer_implementation_sha256,
            raw_root,
            manifest.required_capabilities,
            source.output_bytes,
            value.materializer_payload.len,
            value.raw_output.len,
        ),
        .raw_output_sha256 = raw_root,
        .provenance_sha256 = provenance.provenance_sha256,
        .producer_receipt_wire_sha256 = resource.wire_sha256,
        .producer_resource_sha256 = resource_root,
        .publication_result_sha256 = result.result_sha256,
        .state_after_publication_sha256 = after_publication.state_sha256,
        .completion_observation_sha256 = observation.observation_sha256,
        .completion_plan_sha256 = acknowledgement_plan.plan_sha256,
        .completion_result_sha256 = acknowledgement_result.result_sha256,
        .final_state_sha256 = after_completion.state_sha256,
        .previous_plan_sha256 = zero_digest,
        .previous_result_sha256 = manifest.previous_publication_result_sha256,
        .previous_completion_sha256 = acknowledgement_result.previous_ack_result_sha256,
        .required_capabilities = manifest.required_capabilities,
        .materializer_payload_bytes = try usizeToU64(value.materializer_payload.len),
        .raw_output_bytes = try usizeToU64(value.raw_output.len),
    };
}

fn materializerExecutionRootV1(
    modality: registry.ModalityV1,
    producer_plan_sha256: Digest,
    model_output_sha256: Digest,
    payload_sha256: Digest,
    implementation_sha256: Digest,
    raw_output_sha256: Digest,
    required_capabilities: u64,
    model_output_bytes_value: u64,
    payload_bytes_value: usize,
    raw_bytes_value: usize,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(materializer_execution_domain);
    hashU64(&hash, @intFromEnum(modality));
    inline for (.{
        producer_plan_sha256,
        model_output_sha256,
        payload_sha256,
        implementation_sha256,
        raw_output_sha256,
    }) |digest| hash.update(&digest);
    hashU64(&hash, required_capabilities);
    hashU64(&hash, model_output_bytes_value);
    hashU64(&hash, @intCast(payload_bytes_value));
    hashU64(&hash, @intCast(raw_bytes_value));
    return hash.finalResult();
}

const TerminalV1 = struct {
    receipt: TransitionReceiptV1,
    entry: registry.GeneratedMediaOutputEntryV1,
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

pub fn requiredScratchBytesV1(
    input: BatchInputV1,
) Error!usize {
    try validateBatchShapeV1(input);
    var registry_scratch = std.math.mul(
        usize,
        input.outputs.len,
        registry.entry_bytes,
    ) catch return Error.ArithmeticOverflow;
    var callback_scratch: usize = 0;
    for (input.outputs) |output| {
        registry_scratch = std.math.add(
            usize,
            registry_scratch,
            output.encoded_payload.len,
        ) catch return Error.ArithmeticOverflow;
        const model_bytes = switch (output.model_execution) {
            .stateless => |value| value.output.len,
            .stateful => |value| std.math.add(
                usize,
                value.output.len,
                value.state_after.len,
            ) catch return Error.ArithmeticOverflow,
        };
        const raw_bytes = producerRawOutput(output.producer_execution).len;
        callback_scratch = @max(
            callback_scratch,
            @max(model_bytes, raw_bytes),
        );
    }
    return @max(callback_scratch, registry_scratch);
}

pub fn requiredArchiveBytesV1(
    input: BatchInputV1,
) Error!usize {
    try validateBatchShapeV1(input);
    var registry_scratch = std.math.mul(
        usize,
        input.outputs.len,
        registry.entry_bytes,
    ) catch return Error.ArithmeticOverflow;
    for (input.outputs) |output| {
        registry_scratch = std.math.add(
            usize,
            registry_scratch,
            output.encoded_payload.len,
        ) catch return Error.ArithmeticOverflow;
    }
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
        registry_scratch,
    ) catch return Error.ArithmeticOverflow;
}

pub fn encodeArchiveAndEvidenceV1(
    input: BatchInputV1,
    scratch: []u8,
    archive_destination: []u8,
    evidence_destination: []u8,
) Error!PreparedTransitionV1 {
    try validateBatchShapeV1(input);
    const scratch_bytes = try requiredScratchBytesV1(input);
    const archive_bytes = try requiredArchiveBytesV1(input);
    const evidence_bytes = try requiredEvidenceBytesV1(
        input.outputs.len,
    );
    if (scratch.len < scratch_bytes or
        archive_destination.len < archive_bytes or
        evidence_destination.len < evidence_bytes)
        return Error.BufferTooSmall;
    const scratch_output = scratch[0..scratch_bytes];
    const archive_output = archive_destination[0..archive_bytes];
    const evidence_output = evidence_destination[0..evidence_bytes];
    if (slicesOverlap(scratch_output, archive_output) or
        slicesOverlap(scratch_output, evidence_output) or
        slicesOverlap(archive_output, evidence_output))
        return Error.BufferAlias;
    try validateMutableAliasesV1(
        input,
        scratch_output,
        archive_output,
        evidence_output,
    );

    var previous_evidence: ?DecodedBatchEvidenceV1 = null;
    var terminals: TerminalSetV1 = .{};
    var registry_generation: u64 = 1;
    var publication_sequence: u64 = 1;
    if (input.previous) |previous| {
        const decoded = try validateArchiveAndEvidenceV1(previous);
        previous_evidence = decoded;
        terminals = try previousTerminalsV1(
            previous.registry_archive,
            decoded,
        );
        registry_generation = try checkedAdd(
            previous.registry_archive.manifest.generation,
            1,
        );
        publication_sequence = try checkedAdd(
            previous.registry_archive.manifest.publication_sequence,
            1,
        );
    }

    var callback_scratch_bytes: usize = 0;
    for (input.outputs) |output| {
        const model_bytes = switch (output.model_execution) {
            .stateless => |value| value.output.len,
            .stateful => |value| std.math.add(
                usize,
                value.output.len,
                value.state_after.len,
            ) catch return Error.ArithmeticOverflow,
        };
        callback_scratch_bytes = @max(
            callback_scratch_bytes,
            @max(
                model_bytes,
                producerRawOutput(output.producer_execution).len,
            ),
        );
    }
    const callback_scratch =
        scratch_output[0..callback_scratch_bytes];
    const registry_scratch = scratch_output;
    @memset(scratch_output, 0);
    defer @memset(scratch_output, 0);

    var normalized_storage: [registry.max_entries]registry.OutputInputV1 = undefined;
    const normalized = normalized_storage[0..input.outputs.len];
    var receipt_storage: [registry.max_entries]TransitionReceiptV1 = undefined;
    const receipts = receipt_storage[0..input.outputs.len];
    var payload_offset: u64 = 0;
    const MetadataV1 = struct {
        request_epoch: u64,
        tenant: Digest,
        policy: Digest,
        challenge: Digest,
    };
    var metadata: ?MetadataV1 = null;
    var previous_modality: u64 = 0;

    for (input.outputs, 0..) |output, index| {
        const modality = std.meta.activeTag(output.producer_execution);
        const modality_value = @intFromEnum(modality);
        if (index != 0 and modality_value < previous_modality)
            return Error.InvalidBatch;
        previous_modality = modality_value;
        const source = try replayModelExecutionV1(
            output.model_execution,
            callback_scratch,
        );
        const producer = try replayProducerExecutionV1(
            output.producer_execution,
            source,
            callback_scratch,
        );
        if (producer.modality != modality or
            !digestEqual(
                producer.artifact_sha256,
                source.manifest.artifact_sha256,
            ) or
            !digestEqual(
                producer.challenge_sha256,
                source.plan.challenge_sha256,
            ) or
            output.encoding_abi == 0 or
            output.encoded_payload.len == 0 or
            isZero(output.encoder_implementation_sha256) or
            isZero(output.format_sha256))
            return Error.InvalidBinding;
        const prior = terminals.get(modality);
        const registry_ordinal = if (prior) |value|
            try checkedAdd(value.receipt.registry_ordinal, 1)
        else
            0;
        try validateProducerPredecessorV1(
            producer,
            registry_ordinal,
            prior,
        );
        const unit_start = if (modality == .image)
            registry_ordinal
        else
            producer.unit_start;
        const unit_count = if (modality == .image)
            1
        else
            producer.unit_count;
        const timeline_start = if (modality == .image)
            registry_ordinal
        else
            producer.timeline_start;
        const timeline_end = if (modality == .image)
            try checkedAdd(registry_ordinal, 1)
        else
            producer.timeline_end;
        const previous_entry_sha256 = if (prior) |value|
            value.entry.entry_sha256
        else
            zero_digest;
        normalized[index] = .{
            .modality = modality,
            .ordinal = registry_ordinal,
            .unit_start = unit_start,
            .unit_count = unit_count,
            .timeline_start = timeline_start,
            .timeline_end = timeline_end,
            .source_bytes = producer.raw_output_bytes,
            .encoding_abi = output.encoding_abi,
            .encoded_payload = output.encoded_payload,
            .artifact_sha256 = producer.artifact_sha256,
            .provenance_sha256 = producer.provenance_sha256,
            .result_sha256 = producer.publication_result_sha256,
            .source_output_sha256 = producer.raw_output_sha256,
            .media_object_sha256 = producer.media_object_sha256,
            .state_after_sha256 = producer.final_state_sha256,
            .completion_required = producer.completion_kind != .none,
            .completed = true,
            .completion_sha256 = producer.completion_result_sha256,
            .encoder_implementation_sha256 = output.encoder_implementation_sha256,
            .format_sha256 = output.format_sha256,
            .previous_entry_sha256 = previous_entry_sha256,
        };
        const predicted_entry = registry.deriveEntryV1(
            normalized[index],
            payload_offset,
        ) catch |err| return normalizeRegistryError(err);
        const projection_root = producerProjectionRootV1(
            producer,
            registry_ordinal,
            unit_start,
            unit_count,
            timeline_start,
            timeline_end,
        );
        receipts[index] = makeTransitionReceiptV1(
            source,
            producer,
            input.generation_plan_sha256,
            registry_ordinal,
            unit_start,
            unit_count,
            timeline_start,
            timeline_end,
            output,
            if (prior) |value| value.receipt.receipt_sha256 else zero_digest,
            projection_root,
            previous_entry_sha256,
            predicted_entry.entry_sha256,
        );
        terminals.set(modality, .{
            .receipt = receipts[index],
            .entry = predicted_entry,
        });
        payload_offset = try checkedAdd(
            payload_offset,
            try usizeToU64(output.encoded_payload.len),
        );
        const current_metadata: MetadataV1 = .{
            .request_epoch = producer.request_epoch,
            .tenant = producer.tenant_scope_sha256,
            .policy = producer.metadata_policy_sha256,
            .challenge = producer.challenge_sha256,
        };
        if (current_metadata.request_epoch != source.plan.request_epoch or
            current_metadata.request_epoch != source.result.request_epoch)
            return Error.InvalidBinding;
        if (metadata) |expected| {
            if (expected.request_epoch != current_metadata.request_epoch or
                !digestEqual(expected.tenant, current_metadata.tenant) or
                !digestEqual(expected.policy, current_metadata.policy) or
                !digestEqual(
                    expected.challenge,
                    current_metadata.challenge,
                ))
                return Error.InvalidBatch;
        } else {
            metadata = current_metadata;
        }
    }
    const envelope = metadata orelse return Error.InvalidBatch;
    const prepared = registry.encodeArchiveV1(
        .{
            .previous = if (input.previous) |previous|
                previous.registry_archive.previous()
            else
                null,
            .request_epoch = envelope.request_epoch,
            .generation = registry_generation,
            .publication_sequence = publication_sequence,
            .generation_plan_sha256 = input.generation_plan_sha256,
            .tenant_scope_sha256 = envelope.tenant,
            .metadata_policy_sha256 = envelope.policy,
            .challenge_sha256 = envelope.challenge,
            .outputs = normalized,
        },
        registry_scratch,
        archive_output,
    ) catch |err| return normalizeRegistryError(err);
    const decoded_registry = registry.decodeArchiveV1(
        prepared.set.bytes,
        if (input.previous) |previous|
            previous.registry_archive.previous()
        else
            null,
    ) catch |err| return normalizeRegistryError(err);
    if (!digestEqual(
        prepared.manifest.manifest_sha256,
        decoded_registry.manifest.manifest_sha256,
    ))
        return Error.InvalidBinding;

    var predecessor_receipt_terminals =
        [_]Digest{zero_digest} ** 3;
    if (previous_evidence) |previous| {
        predecessor_receipt_terminals[0] =
            previous.batch.terminal_image_sha256;
        predecessor_receipt_terminals[1] =
            previous.batch.terminal_audio_sha256;
        predecessor_receipt_terminals[2] =
            previous.batch.terminal_video_sha256;
    }
    var current_receipt_terminals =
        [_]Digest{zero_digest} ** 3;
    const receipt_table = evidence_output[640..];
    for (receipts, 0..) |*receipt, index| {
        const actual_entry = decoded_registry.entry(index) catch |err|
            return normalizeRegistryError(err);
        if (!digestEqual(
            actual_entry.entry_sha256,
            receipt.registry_entry_sha256,
        ))
            return Error.InvalidBinding;
        const slot = modalitySlot(receipt.modality);
        receipt.previous_transition_receipt_sha256 =
            predecessor_receipt_terminals[slot];
        receipt.registry_manifest_sha256 =
            decoded_registry.manifest.manifest_sha256;
        receipt.registry_archive_sha256 =
            decoded_registry.archive_sha256;
        const start = index * transition_receipt_bytes;
        const encoded_receipt = try encodeTransitionReceiptV1(
            receipt.*,
            receipt_table[start .. start + transition_receipt_bytes],
        );
        receipt.receipt_sha256 = encoded_receipt[1696..1728].*;
        predecessor_receipt_terminals[slot] =
            receipt.receipt_sha256;
        current_receipt_terminals[slot] =
            receipt.receipt_sha256;
    }
    const table_root = domainRoot(receipt_table_domain, receipt_table);
    var batch = BatchEvidenceV1{
        .request_epoch = envelope.request_epoch,
        .registry_generation = registry_generation,
        .publication_sequence = publication_sequence,
        .receipt_count = try usizeToU64(receipts.len),
        .receipt_table_bytes = try usizeToU64(receipt_table.len),
        .aggregate_model_input_bytes = 0,
        .aggregate_model_output_bytes = 0,
        .aggregate_state_transition_bytes = 0,
        .aggregate_materializer_payload_bytes = 0,
        .aggregate_raw_output_bytes = 0,
        .aggregate_encoded_payload_bytes = 0,
        .modality_mask = 0,
        .generation_plan_sha256 = input.generation_plan_sha256,
        .tenant_scope_sha256 = envelope.tenant,
        .metadata_policy_sha256 = envelope.policy,
        .challenge_sha256 = envelope.challenge,
        .receipt_table_sha256 = table_root,
        .previous_batch_sha256 = if (previous_evidence) |previous|
            previous.batch.batch_sha256
        else
            zero_digest,
        .registry_manifest_sha256 = decoded_registry.manifest.manifest_sha256,
        .registry_archive_sha256 = decoded_registry.archive_sha256,
        .first_receipt_sha256 = receipts[0].receipt_sha256,
        .terminal_image_sha256 = current_receipt_terminals[0],
        .terminal_audio_sha256 = current_receipt_terminals[1],
        .terminal_video_sha256 = current_receipt_terminals[2],
        .batch_sha256 = zero_digest,
    };
    for (receipts) |receipt| {
        batch.aggregate_model_input_bytes = try checkedAdd(
            batch.aggregate_model_input_bytes,
            receipt.model_input_bytes,
        );
        batch.aggregate_model_output_bytes = try checkedAdd(
            batch.aggregate_model_output_bytes,
            receipt.model_output_bytes,
        );
        batch.aggregate_state_transition_bytes = try checkedAdd(
            batch.aggregate_state_transition_bytes,
            receipt.model_state_before_bytes,
        );
        batch.aggregate_state_transition_bytes = try checkedAdd(
            batch.aggregate_state_transition_bytes,
            receipt.model_state_after_bytes,
        );
        batch.aggregate_materializer_payload_bytes = try checkedAdd(
            batch.aggregate_materializer_payload_bytes,
            receipt.materializer_payload_bytes,
        );
        batch.aggregate_raw_output_bytes = try checkedAdd(
            batch.aggregate_raw_output_bytes,
            receipt.raw_output_bytes,
        );
        batch.aggregate_encoded_payload_bytes = try checkedAdd(
            batch.aggregate_encoded_payload_bytes,
            receipt.encoded_payload_bytes,
        );
        batch.modality_mask |= modalityBit(receipt.modality);
    }
    const encoded_evidence = try encodeBatchEvidenceV1(
        batch,
        receipt_table,
        evidence_output,
    );
    const decoded_evidence = try decodeBatchEvidenceV1(encoded_evidence);
    batch = decoded_evidence.batch;
    return .{
        .registry_archive = prepared,
        .evidence = encoded_evidence,
        .batch = batch,
    };
}

fn makeTransitionReceiptV1(
    source: ModelAdmissionV1,
    producer: ProducerAdmissionV1,
    generation_plan_sha256: Digest,
    registry_ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    timeline_start: u64,
    timeline_end: u64,
    output: OutputTransitionV1,
    previous_transition_sha256: Digest,
    projection_sha256: Digest,
    previous_entry_sha256: Digest,
    entry_sha256: Digest,
) TransitionReceiptV1 {
    return .{
        .modality = producer.modality,
        .model_kind = source.kind,
        .completion_kind = producer.completion_kind,
        .request_epoch = source.plan.request_epoch,
        .producer_generation = producer.producer_generation,
        .producer_ordinal = producer.producer_ordinal,
        .registry_ordinal = registry_ordinal,
        .unit_start = unit_start,
        .unit_count = unit_count,
        .timeline_start = timeline_start,
        .timeline_end = timeline_end,
        .weights_bytes = source.weights_bytes,
        .model_input_bytes = source.input_bytes,
        .model_state_before_bytes = source.state_before_bytes,
        .model_output_bytes = source.output_bytes,
        .model_state_after_bytes = source.state_after_bytes,
        .materializer_payload_bytes = producer.materializer_payload_bytes,
        .raw_output_bytes = producer.raw_output_bytes,
        .encoded_payload_bytes = @intCast(output.encoded_payload.len),
        .producer_publication_sequence = producer.producer_publication_sequence,
        .completion_sequence = producer.completion_sequence,
        .model_required_capabilities = source.plan.required_capabilities,
        .materializer_required_capabilities = producer.required_capabilities,
        .model_step_before = source.step_before,
        .model_step_after = source.step_after,
        .producer_state_generation_before = producer.state_generation_before,
        .producer_state_generation_after_publication = producer.state_generation_after_publication,
        .producer_state_generation_after_completion = producer.state_generation_after_completion,
        .tenant_scope_sha256 = producer.tenant_scope_sha256,
        .metadata_policy_sha256 = producer.metadata_policy_sha256,
        .challenge_sha256 = producer.challenge_sha256,
        .generation_plan_sha256 = generation_plan_sha256,
        .artifact_manifest_sha256 = source.manifest.artifact_sha256,
        .adapter_descriptor_sha256 = source.adapter_descriptor_wire_sha256,
        .support_set_sha256 = source.support_set_sha256,
        .model_plan_sha256 = source.plan.plan_sha256,
        .model_publication_before_sha256 = model.publicationStateRootV1(
            source.publication_before,
        ) catch unreachable,
        .model_state_publication_before_sha256 = if (source.state_publication_before) |state|
            state.publication_sha256
        else
            zero_digest,
        .weights_sha256 = source.weights_sha256,
        .model_input_sha256 = source.input_sha256,
        .model_state_before_sha256 = source.state_before_sha256,
        .model_output_sha256 = source.output_sha256,
        .model_state_after_sha256 = source.state_after_sha256,
        .model_transition_or_source_mapping_sha256 = source.transition_or_mapping_sha256,
        .model_result_sha256 = source.result.result_sha256,
        .model_publication_after_sha256 = model.publicationStateRootV1(
            source.publication_after,
        ) catch unreachable,
        .model_state_publication_after_sha256 = if (source.state_publication_after) |state|
            state.publication_sha256
        else
            zero_digest,
        .producer_plan_or_manifest_sha256 = producer.plan_or_manifest_sha256,
        .producer_state_before_sha256 = producer.state_before_sha256,
        .media_object_sha256 = producer.media_object_sha256,
        .materializer_payload_sha256 = producer.materializer_payload_sha256,
        .materializer_implementation_sha256 = producer.materializer_implementation_sha256,
        .materializer_execution_sha256 = producer.materializer_execution_sha256,
        .raw_output_sha256 = producer.raw_output_sha256,
        .provenance_sha256 = producer.provenance_sha256,
        .producer_receipt_wire_sha256 = producer.producer_receipt_wire_sha256,
        .producer_resource_sha256 = producer.producer_resource_sha256,
        .publication_result_sha256 = producer.publication_result_sha256,
        .producer_state_after_publication_sha256 = producer.state_after_publication_sha256,
        .completion_observation_sha256 = producer.completion_observation_sha256,
        .completion_plan_sha256 = producer.completion_plan_sha256,
        .completion_result_sha256 = producer.completion_result_sha256,
        .producer_final_state_sha256 = producer.final_state_sha256,
        .encoder_implementation_sha256 = output.encoder_implementation_sha256,
        .format_sha256 = output.format_sha256,
        .encoded_payload_sha256 = model.sha256(
            output.encoded_payload,
        ),
        .previous_transition_receipt_sha256 = previous_transition_sha256,
        .producer_projection_sha256 = projection_sha256,
        .registry_previous_entry_sha256 = previous_entry_sha256,
        .registry_entry_sha256 = entry_sha256,
        .registry_manifest_sha256 = zero_digest,
        .registry_archive_sha256 = zero_digest,
        .receipt_sha256 = zero_digest,
    };
}

fn validateBatchShapeV1(input: BatchInputV1) Error!void {
    if (input.outputs.len == 0 or
        input.outputs.len > registry.max_entries or
        isZero(input.generation_plan_sha256))
        return Error.InvalidBatch;
    var counts = [_]u64{0} ** 3;
    var previous_modality: u64 = 0;
    var modality_mask: u64 = 0;
    for (input.outputs, 0..) |output, index| {
        const modality = std.meta.activeTag(output.producer_execution);
        const model_kind = std.meta.activeTag(output.model_execution);
        const support_count = switch (output.model_execution) {
            .stateless => |value| value.support_records.len,
            .stateful => |value| value.support_records.len,
        };
        if (support_count == 0 or
            support_count > max_support_records)
            return Error.InvalidModelExecution;
        if (switch (modality) {
            .image => model_kind != .stateful,
            .audio, .video => model_kind != .stateless,
        }) return Error.InvalidBatch;
        if (output.encoding_abi == 0 or
            output.encoded_payload.len == 0 or
            isZero(output.encoder_implementation_sha256) or
            isZero(output.format_sha256))
            return Error.InvalidBinding;
        const value = @intFromEnum(modality);
        if (index != 0 and value < previous_modality)
            return Error.InvalidBatch;
        previous_modality = value;
        const slot = modalitySlot(modality);
        counts[slot] += 1;
        if (counts[slot] > registry.max_outputs_per_modality)
            return Error.InvalidBatch;
        modality_mask |= modalityBit(modality);
    }
    if (input.previous) |previous| {
        if (previous.registry_archive.manifest.modality_mask !=
            modality_mask)
            return Error.InvalidBatch;
    }
}

pub fn validateArchiveAndEvidenceV1(
    previous: PreviousGenerationV1,
) Error!DecodedBatchEvidenceV1 {
    const evidence = try decodeBatchEvidenceV1(previous.evidence);
    const manifest = previous.registry_archive.manifest;
    const genesis = manifest.generation == 1;
    if (genesis != isZero(evidence.batch.previous_batch_sha256) or
        genesis != isZero(manifest.previous_manifest_sha256) or
        genesis != isZero(manifest.previous_archive_sha256) or
        evidence.batch.request_epoch != manifest.request_epoch or
        evidence.batch.registry_generation != manifest.generation or
        evidence.batch.publication_sequence !=
            manifest.publication_sequence or
        evidence.batch.receipt_count != manifest.entry_count or
        evidence.batch.modality_mask != manifest.modality_mask or
        !digestEqual(
            evidence.batch.generation_plan_sha256,
            manifest.generation_plan_sha256,
        ) or
        !digestEqual(
            evidence.batch.tenant_scope_sha256,
            manifest.tenant_scope_sha256,
        ) or
        !digestEqual(
            evidence.batch.metadata_policy_sha256,
            manifest.metadata_policy_sha256,
        ) or
        !digestEqual(
            evidence.batch.challenge_sha256,
            manifest.challenge_sha256,
        ) or
        !digestEqual(
            evidence.batch.registry_manifest_sha256,
            manifest.manifest_sha256,
        ) or
        !digestEqual(
            evidence.batch.registry_archive_sha256,
            previous.registry_archive.archive_sha256,
        ))
        return Error.InvalidPreviousEvidence;
    const count = std.math.cast(
        usize,
        manifest.entry_count,
    ) orelse return Error.InvalidPreviousEvidence;
    for (0..count) |index| {
        const receipt = try evidence.receipt(index);
        const entry = previous.registry_archive.entry(index) catch
            return Error.InvalidPreviousEvidence;
        const payload = previous.registry_archive.payload(index) catch
            return Error.InvalidPreviousEvidence;
        if (receipt.modality != entry.modality or
            receipt.registry_ordinal != entry.ordinal or
            receipt.unit_start != entry.unit_start or
            receipt.unit_count != entry.unit_count or
            (checkedAdd(
                receipt.unit_start,
                receipt.unit_count,
            ) catch return Error.InvalidPreviousEvidence) !=
                entry.unit_end or
            receipt.timeline_start != entry.timeline_start or
            receipt.timeline_end != entry.timeline_end or
            receipt.raw_output_bytes != entry.source_bytes or
            receipt.encoded_payload_bytes != entry.payload_bytes or
            (usizeToU64(payload.len) catch
                return Error.InvalidPreviousEvidence) !=
                receipt.encoded_payload_bytes or
            entry.completion_required !=
                (receipt.completion_kind != .none) or
            !entry.completed or
            !digestEqual(
                receipt.artifact_manifest_sha256,
                entry.artifact_sha256,
            ) or
            !digestEqual(
                receipt.provenance_sha256,
                entry.provenance_sha256,
            ) or
            !digestEqual(
                receipt.registry_previous_entry_sha256,
                entry.previous_entry_sha256,
            ) or
            !digestEqual(
                receipt.registry_entry_sha256,
                entry.entry_sha256,
            ) or
            !digestEqual(
                receipt.registry_manifest_sha256,
                manifest.manifest_sha256,
            ) or
            !digestEqual(
                receipt.registry_archive_sha256,
                previous.registry_archive.archive_sha256,
            ) or
            !digestEqual(
                receipt.publication_result_sha256,
                entry.result_sha256,
            ) or
            !digestEqual(
                receipt.raw_output_sha256,
                entry.source_output_sha256,
            ) or
            !digestEqual(
                receipt.media_object_sha256,
                entry.media_object_sha256,
            ) or
            !digestEqual(
                receipt.producer_final_state_sha256,
                entry.state_after_sha256,
            ) or
            !digestEqual(
                receipt.completion_result_sha256,
                entry.completion_sha256,
            ) or
            !digestEqual(
                receipt.encoder_implementation_sha256,
                entry.encoder_implementation_sha256,
            ) or
            !digestEqual(
                receipt.format_sha256,
                entry.format_sha256,
            ) or
            !digestEqual(
                receipt.encoded_payload_sha256,
                model.sha256(payload),
            ))
            return Error.InvalidPreviousEvidence;
    }
    return evidence;
}

/// Validate a current retained pair against its exact trusted predecessor.
///
/// `validateArchiveAndEvidenceV1` authenticates one self-contained pair and
/// enforces genesis/non-genesis shape. This API additionally anchors the
/// non-genesis predecessor roots and each modality's first receipt.
pub fn validateSuccessorArchiveAndEvidenceV1(
    current: PreviousGenerationV1,
    predecessor: PreviousGenerationV1,
) Error!DecodedBatchEvidenceV1 {
    const previous_evidence =
        try validateArchiveAndEvidenceV1(predecessor);
    const current_evidence =
        try validateArchiveAndEvidenceV1(current);
    const linked_registry = registry.decodeArchiveV1(
        current.registry_archive.archive_bytes,
        predecessor.registry_archive.previous(),
    ) catch return Error.InvalidPreviousEvidence;
    if (!digestEqual(
        linked_registry.archive_sha256,
        current.registry_archive.archive_sha256,
    ) or !std.meta.eql(
        linked_registry.manifest,
        current.registry_archive.manifest,
    ) or !std.mem.eql(
        u8,
        linked_registry.entry_table,
        current.registry_archive.entry_table,
    ) or !std.mem.eql(
        u8,
        linked_registry.payload_pack,
        current.registry_archive.payload_pack,
    ) or !digestEqual(
        current_evidence.batch.previous_batch_sha256,
        previous_evidence.batch.batch_sha256,
    ))
        return Error.InvalidPreviousEvidence;
    var prior = [_]Digest{
        previous_evidence.batch.terminal_image_sha256,
        previous_evidence.batch.terminal_audio_sha256,
        previous_evidence.batch.terminal_video_sha256,
    };
    const count = std.math.cast(
        usize,
        current_evidence.batch.receipt_count,
    ) orelse return Error.InvalidPreviousEvidence;
    for (0..count) |index| {
        const receipt = try current_evidence.receipt(index);
        const slot = modalitySlot(receipt.modality);
        if (!digestEqual(
            receipt.previous_transition_receipt_sha256,
            prior[slot],
        ))
            return Error.InvalidPreviousEvidence;
        prior[slot] = receipt.receipt_sha256;
    }
    return current_evidence;
}

fn previousTerminalsV1(
    previous_registry: registry.DecodedArchiveV1,
    previous_evidence: DecodedBatchEvidenceV1,
) Error!TerminalSetV1 {
    var terminals: TerminalSetV1 = .{};
    for ([_]registry.ModalityV1{
        .image,
        .audio,
        .video,
    }) |modality| {
        const receipt = (try previous_evidence.terminal(modality)) orelse
            continue;
        const entry = previous_registry.terminal(modality) catch
            return Error.InvalidPreviousEvidence;
        if (!digestEqual(receipt.registry_entry_sha256, entry.entry_sha256))
            return Error.InvalidPreviousEvidence;
        terminals.set(modality, .{
            .receipt = receipt,
            .entry = entry,
        });
    }
    return terminals;
}

fn validateProducerPredecessorV1(
    producer: ProducerAdmissionV1,
    registry_ordinal: u64,
    previous: ?TerminalV1,
) Error!void {
    if (producer.modality != .image and
        producer.producer_ordinal != registry_ordinal)
        return Error.InvalidBinding;
    if (previous) |value| {
        if (!digestEqual(
            producer.previous_result_sha256,
            value.receipt.publication_result_sha256,
        ))
            return Error.InvalidBinding;
        switch (producer.modality) {
            .image => {
                if (!digestEqual(
                    producer.previous_plan_sha256,
                    value.receipt.producer_plan_or_manifest_sha256,
                ))
                    return Error.InvalidBinding;
            },
            .audio, .video => {
                if (!digestEqual(
                    producer.previous_completion_sha256,
                    value.receipt.completion_result_sha256,
                ) or !digestEqual(
                    producer.state_before_sha256,
                    value.receipt.producer_final_state_sha256,
                ))
                    return Error.InvalidBinding;
            },
        }
    } else {
        if (registry_ordinal != 0)
            return Error.InvalidBinding;
        if (producer.modality != .image and
            (!isZero(producer.previous_result_sha256) or
                !isZero(producer.previous_completion_sha256)))
            return Error.InvalidBinding;
    }
}

fn producerProjectionRootV1(
    producer: ProducerAdmissionV1,
    registry_ordinal: u64,
    unit_start: u64,
    unit_count: u64,
    timeline_start: u64,
    timeline_end: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(producer_projection_domain);
    inline for (.{
        @intFromEnum(producer.modality),
        producer.producer_generation,
        producer.producer_ordinal,
        registry_ordinal,
        unit_start,
        unit_count,
        timeline_start,
        timeline_end,
        producer.raw_output_bytes,
        @intFromEnum(producer.completion_kind),
    }) |scalar| hashU64(&hash, scalar);
    inline for (.{
        producer.artifact_sha256,
        producer.plan_or_manifest_sha256,
        producer.provenance_sha256,
        producer.publication_result_sha256,
        producer.raw_output_sha256,
        producer.state_before_sha256,
        producer.state_after_publication_sha256,
        producer.completion_observation_sha256,
        producer.completion_plan_sha256,
        producer.completion_result_sha256,
        producer.final_state_sha256,
        producer.tenant_scope_sha256,
        producer.metadata_policy_sha256,
        producer.challenge_sha256,
    }) |digest| hash.update(&digest);
    return hash.finalResult();
}

fn producerProjectionFromReceiptV1(
    value: TransitionReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(producer_projection_domain);
    inline for (.{
        @intFromEnum(value.modality),
        value.producer_generation,
        value.producer_ordinal,
        value.registry_ordinal,
        value.unit_start,
        value.unit_count,
        value.timeline_start,
        value.timeline_end,
        value.raw_output_bytes,
        @intFromEnum(value.completion_kind),
    }) |scalar| hashU64(&hash, scalar);
    inline for (.{
        value.artifact_manifest_sha256,
        value.producer_plan_or_manifest_sha256,
        value.provenance_sha256,
        value.publication_result_sha256,
        value.raw_output_sha256,
        value.producer_state_before_sha256,
        value.producer_state_after_publication_sha256,
        value.completion_observation_sha256,
        value.completion_plan_sha256,
        value.completion_result_sha256,
        value.producer_final_state_sha256,
        value.tenant_scope_sha256,
        value.metadata_policy_sha256,
        value.challenge_sha256,
    }) |digest| hash.update(&digest);
    return hash.finalResult();
}

fn validateMutableAliasesV1(
    input: BatchInputV1,
    scratch: []u8,
    archive: []u8,
    evidence: []u8,
) Error!void {
    const mutable = [_][]u8{ scratch, archive, evidence };
    try rejectMutableOverlap(
        std.mem.sliceAsBytes(input.outputs),
        &mutable,
    );
    if (input.previous) |previous| {
        try rejectMutableOverlap(
            previous.registry_archive.archive_bytes,
            &mutable,
        );
        try rejectMutableOverlap(previous.evidence, &mutable);
    }
    for (input.outputs) |output| {
        switch (output.model_execution) {
            .stateless => |value| {
                if (value.support_records.len == 0 or
                    value.support_records.len > max_support_records)
                    return Error.InvalidModelExecution;
                inline for (.{
                    value.artifact_manifest,
                    value.plan,
                    value.publication_before,
                    value.publication_after,
                    value.adapter_descriptor,
                    value.result,
                    value.weights,
                    value.input,
                    value.output,
                    std.mem.sliceAsBytes(value.support_records),
                }) |slice| try rejectMutableOverlap(slice, &mutable);
            },
            .stateful => |value| {
                if (value.support_records.len == 0 or
                    value.support_records.len > max_support_records)
                    return Error.InvalidModelExecution;
                inline for (.{
                    value.artifact_manifest,
                    value.plan,
                    value.publication_before,
                    value.publication_after,
                    value.state_publication_before,
                    value.state_publication_after,
                    value.checkpoint_before.checkpoint,
                    value.checkpoint_before.previous_result,
                    value.adapter_descriptor,
                    value.result,
                    value.weights,
                    value.input,
                    value.state_before,
                    value.output,
                    value.state_after,
                    std.mem.sliceAsBytes(value.support_records),
                }) |slice| try rejectMutableOverlap(slice, &mutable);
            },
        }
        switch (output.producer_execution) {
            .image => |value| {
                inline for (.{
                    value.publication_before,
                    value.publication_after,
                    value.plan,
                    value.provenance,
                    value.result,
                    value.media_object,
                    value.resource_receipt,
                    value.materializer_payload,
                    value.raw_output,
                }) |slice| try rejectMutableOverlap(slice, &mutable);
            },
            .audio => |value| {
                inline for (.{
                    value.state_before,
                    value.state_after_publication,
                    value.state_after_completion,
                    value.plan,
                    value.provenance,
                    value.result,
                    value.observation,
                    value.acknowledgement_plan,
                    value.acknowledgement_result,
                    value.media_object,
                    value.resource_receipt,
                    value.materializer_payload,
                    value.raw_output,
                }) |slice| try rejectMutableOverlap(slice, &mutable);
            },
            .video => |value| {
                inline for (.{
                    value.state_before,
                    value.state_after_publication,
                    value.state_after_completion,
                    value.manifest,
                    value.provenance,
                    value.result,
                    value.observation,
                    value.acknowledgement_plan,
                    value.acknowledgement_result,
                    value.media_object,
                    value.resource_receipt,
                    value.materializer_payload,
                    value.raw_output,
                }) |slice| try rejectMutableOverlap(slice, &mutable);
            },
        }
        try rejectMutableOverlap(output.encoded_payload, &mutable);
    }
}

fn rejectMutableOverlap(
    immutable: []const u8,
    mutable: []const []u8,
) Error!void {
    for (mutable) |candidate| {
        if (slicesOverlap(immutable, candidate))
            return Error.BufferAlias;
    }
}

fn producerRawOutput(
    producer: ProducerExecutionV1,
) []const u8 {
    return switch (producer) {
        .image => |value| value.raw_output,
        .audio => |value| value.raw_output,
        .video => |value| value.raw_output,
    };
}

fn modalitySlot(modality: registry.ModalityV1) usize {
    return switch (modality) {
        .image => 0,
        .audio => 1,
        .video => 2,
    };
}

fn modalityBit(modality: registry.ModalityV1) u64 {
    return @as(u64, 1) << @intCast(@intFromEnum(modality) - 1);
}

fn normalizeRegistryError(err: registry.Error) Error {
    return switch (err) {
        error.ArithmeticOverflow => Error.ArithmeticOverflow,
        else => err,
    };
}

fn writeClaim(
    output: []u8,
    offset: usize,
    claim: resource_bank.Claim,
) void {
    writeU64(output, offset, claim.capsule_bytes);
    writeU64(output, offset + 8, claim.kv_bytes);
    writeU64(output, offset + 16, claim.activation_bytes);
    writeU64(output, offset + 24, claim.partial_bytes);
    writeU64(output, offset + 32, claim.logits_bytes);
    writeU64(output, offset + 40, claim.output_journal_bytes);
    writeU64(output, offset + 48, claim.staging_bytes);
    writeU64(output, offset + 56, claim.device_bytes);
    writeU64(output, offset + 64, claim.io_bytes);
    writeU64(output, offset + 72, claim.queue_slots);
}

fn readClaim(input: []const u8, offset: usize) resource_bank.Claim {
    return .{
        .capsule_bytes = readU64(input, offset),
        .kv_bytes = readU64(input, offset + 8),
        .activation_bytes = readU64(input, offset + 16),
        .partial_bytes = readU64(input, offset + 24),
        .logits_bytes = readU64(input, offset + 32),
        .output_journal_bytes = readU64(input, offset + 40),
        .staging_bytes = readU64(input, offset + 48),
        .device_bytes = readU64(input, offset + 56),
        .io_bytes = readU64(input, offset + 64),
        .queue_slots = readU64(input, offset + 72),
    };
}

fn digestAt(input: []const u8, index: usize) Digest {
    const start = index * 32;
    return input[start..][0..32].*;
}

fn domainRoot(domain: []const u8, bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(bytes);
    return hash.finalResult();
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, output[offset..][0..8], value, .little);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset..][0..8], .little);
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn usizeToU64(value: usize) Error!u64 {
    return std.math.cast(u64, value) orelse
        return Error.ArithmeticOverflow;
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
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

test "canonical transition wrappers and evidence reject mutation" {
    const publication = try model.initializePublicationStateV1(
        9,
        model.sha256("artifact"),
    );
    var model_wire: [model_publication_bytes]u8 = undefined;
    const encoded_model = try encodeModelPublicationV1(
        publication,
        &model_wire,
    );
    try std.testing.expectEqual(
        publication,
        try decodeModelPublicationV1(encoded_model),
    );

    var descriptor: stateless.AdapterDescriptorV1 = .{
        .adapter_abi = 7,
        .family = .audio_generation,
        .operation = .synthesize,
        .input_kind = .token_ids,
        .output_kind = .media_chunk,
        .numerical_policy = .exact_integer,
        .max_batch_items = 1,
        .max_input_features = 8,
        .max_output_dimensions = 8,
        .allowed_capabilities = 0,
        .implementation_sha256 = model.sha256("adapter"),
        .adapter_sha256 = zero_digest,
    };
    descriptor.adapter_sha256 =
        stateless.adapterDescriptorRootV1(descriptor);
    var descriptor_wire: [adapter_descriptor_bytes]u8 = undefined;
    const encoded_descriptor = try encodeAdapterDescriptorV1(
        descriptor,
        &descriptor_wire,
    );
    try std.testing.expectEqual(
        descriptor,
        try decodeAdapterDescriptorV1(encoded_descriptor),
    );

    const media_state = try media.initializePublicationStateV1(
        9,
        1,
        .{ .numerator = 1, .denominator = 1 },
        model.sha256("media object"),
        model.sha256("previous commit"),
    );
    var media_wire: [media_publication_bytes]u8 = undefined;
    const encoded_media = try encodeMediaPublicationV1(
        media_state,
        &media_wire,
    );
    try std.testing.expectEqual(
        media_state,
        try decodeMediaPublicationV1(encoded_media),
    );

    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var bank = try resource_bank.Bank.init(&slots, .{}, 19);
    const receipt = try bank.commit(
        try bank.reserve(21, .{ .queue_slots = 1 }),
    );
    var resource_wire: [resource_receipt_bytes]u8 = undefined;
    const encoded_resource = try encodeResourceReceiptEvidenceV1(
        receipt,
        &resource_wire,
    );
    try std.testing.expectEqual(
        receipt,
        (try decodeResourceReceiptEvidenceV1(
            encoded_resource,
        )).receipt,
    );
    try bank.release(receipt);

    var transition = syntheticTransitionReceiptV1(0);
    var transition_wire: [transition_receipt_bytes]u8 = undefined;
    const encoded_transition = try encodeTransitionReceiptV1(
        transition,
        &transition_wire,
    );
    transition.receipt_sha256 = encoded_transition[1696..1728].*;
    try std.testing.expectEqual(
        transition,
        try decodeTransitionReceiptV1(encoded_transition),
    );
    var rejected_transition = transition;
    rejected_transition.receipt_sha256 =
        model.sha256("foreign supplied transition root");
    var untouched_transition =
        [_]u8{0xa5} ** transition_receipt_bytes;
    try std.testing.expectError(
        Error.InvalidReceipt,
        encodeTransitionReceiptV1(
            rejected_transition,
            &untouched_transition,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &untouched_transition,
        0xa5,
    ));
    for ([_]usize{ 24, 39 }) |digest_index| {
        var contradiction = transition_wire;
        const digest_offset = 256 + digest_index * 32;
        const foreign = model.sha256("foreign derived root");
        @memcpy(
            contradiction[digest_offset .. digest_offset + 32],
            &foreign,
        );
        const resealed = domainRoot(
            transition_receipt_domain,
            contradiction[0..transition_receipt_body_bytes],
        );
        @memcpy(
            contradiction[transition_receipt_body_bytes..],
            &resealed,
        );
        try std.testing.expectError(
            Error.InvalidReceipt,
            decodeTransitionReceiptV1(&contradiction),
        );
    }
    for (0..transition_receipt_bytes) |offset| {
        var mutated = transition_wire;
        mutated[offset] ^= 1;
        try std.testing.expectError(
            Error.InvalidWire,
            decodeTransitionReceiptV1(&mutated),
        );
    }

    const table_root = domainRoot(
        receipt_table_domain,
        &transition_wire,
    );
    var batch: BatchEvidenceV1 = .{
        .request_epoch = transition.request_epoch,
        .registry_generation = 1,
        .publication_sequence = 1,
        .receipt_count = 1,
        .receipt_table_bytes = transition_receipt_bytes,
        .aggregate_model_input_bytes = transition.model_input_bytes,
        .aggregate_model_output_bytes = transition.model_output_bytes,
        .aggregate_state_transition_bytes = transition.model_state_before_bytes +
            transition.model_state_after_bytes,
        .aggregate_materializer_payload_bytes = transition.materializer_payload_bytes,
        .aggregate_raw_output_bytes = transition.raw_output_bytes,
        .aggregate_encoded_payload_bytes = transition.encoded_payload_bytes,
        .modality_mask = modalityBit(.image),
        .generation_plan_sha256 = transition.generation_plan_sha256,
        .tenant_scope_sha256 = transition.tenant_scope_sha256,
        .metadata_policy_sha256 = transition.metadata_policy_sha256,
        .challenge_sha256 = transition.challenge_sha256,
        .receipt_table_sha256 = table_root,
        .previous_batch_sha256 = zero_digest,
        .registry_manifest_sha256 = transition.registry_manifest_sha256,
        .registry_archive_sha256 = transition.registry_archive_sha256,
        .first_receipt_sha256 = transition.receipt_sha256,
        .terminal_image_sha256 = transition.receipt_sha256,
        .terminal_audio_sha256 = zero_digest,
        .terminal_video_sha256 = zero_digest,
        .batch_sha256 = zero_digest,
    };
    var evidence: [batch_header_bytes + transition_receipt_bytes]u8 = undefined;
    const encoded_batch = try encodeBatchEvidenceV1(
        batch,
        &transition_wire,
        &evidence,
    );
    batch.batch_sha256 = encoded_batch[608..640].*;
    try std.testing.expectEqual(
        batch,
        (try decodeBatchEvidenceV1(encoded_batch)).batch,
    );
    var rejected_batch = batch;
    rejected_batch.batch_sha256 =
        model.sha256("foreign supplied batch root");
    var untouched_evidence =
        [_]u8{0xb6} ** (batch_header_bytes +
            transition_receipt_bytes);
    try std.testing.expectError(
        Error.InvalidBatch,
        encodeBatchEvidenceV1(
            rejected_batch,
            &transition_wire,
            &untouched_evidence,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        &untouched_evidence,
        0xb6,
    ));
    var forged_view = try decodeBatchEvidenceV1(encoded_batch);
    forged_view.receipts = forged_view.receipts[0..1];
    try std.testing.expectError(
        Error.InvalidBatch,
        forged_view.receipt(0),
    );
    var mutated_backing = evidence;
    var stale_view = try decodeBatchEvidenceV1(&mutated_backing);
    mutated_backing[
        transition_receipt_body_bytes +
            batch_header_bytes
    ] ^= 1;
    try std.testing.expectError(
        Error.InvalidBatch,
        stale_view.receipt(0),
    );
    stale_view.encoded = stale_view.encoded[0..1];
    try std.testing.expectError(
        Error.InvalidWire,
        stale_view.terminal(.image),
    );
    for (0..batch_header_bytes) |offset| {
        var mutated = evidence;
        mutated[offset] ^= 1;
        try std.testing.expectError(
            Error.InvalidWire,
            decodeBatchEvidenceV1(&mutated),
        );
    }
}

test "transition gateway rejects empty batch before mutation" {
    const input: BatchInputV1 = .{
        .previous = null,
        .generation_plan_sha256 = model.sha256("generation plan"),
        .outputs = &.{},
    };
    var scratch: [1]u8 = .{0xaa};
    var archive: [1]u8 = .{0xbb};
    var evidence: [1]u8 = .{0xcc};
    try std.testing.expectError(
        Error.InvalidBatch,
        encodeArchiveAndEvidenceV1(
            input,
            &scratch,
            &archive,
            &evidence,
        ),
    );
    try std.testing.expectEqual(@as(u8, 0xaa), scratch[0]);
    try std.testing.expectEqual(@as(u8, 0xbb), archive[0]);
    try std.testing.expectEqual(@as(u8, 0xcc), evidence[0]);
}

test "batch receipt lineage rejects a resealed foreign predecessor" {
    var first = syntheticTransitionReceiptV1(0);
    var first_wire: [transition_receipt_bytes]u8 = undefined;
    const encoded_first = try encodeTransitionReceiptV1(
        first,
        &first_wire,
    );
    first.receipt_sha256 = encoded_first[1696..1728].*;
    var second = syntheticTransitionReceiptV1(1);
    second.previous_transition_receipt_sha256 =
        first.receipt_sha256;
    second.registry_previous_entry_sha256 =
        first.registry_entry_sha256;
    var second_wire: [transition_receipt_bytes]u8 = undefined;
    const encoded_second = try encodeTransitionReceiptV1(
        second,
        &second_wire,
    );
    second.receipt_sha256 = encoded_second[1696..1728].*;
    var table: [2 * transition_receipt_bytes]u8 = undefined;
    @memcpy(table[0..transition_receipt_bytes], &first_wire);
    @memcpy(table[transition_receipt_bytes..], &second_wire);
    var batch: BatchEvidenceV1 = .{
        .request_epoch = first.request_epoch,
        .registry_generation = 1,
        .publication_sequence = 1,
        .receipt_count = 2,
        .receipt_table_bytes = table.len,
        .aggregate_model_input_bytes = first.model_input_bytes + second.model_input_bytes,
        .aggregate_model_output_bytes = first.model_output_bytes + second.model_output_bytes,
        .aggregate_state_transition_bytes = first.model_state_before_bytes +
            first.model_state_after_bytes +
            second.model_state_before_bytes +
            second.model_state_after_bytes,
        .aggregate_materializer_payload_bytes = first.materializer_payload_bytes +
            second.materializer_payload_bytes,
        .aggregate_raw_output_bytes = first.raw_output_bytes + second.raw_output_bytes,
        .aggregate_encoded_payload_bytes = first.encoded_payload_bytes +
            second.encoded_payload_bytes,
        .modality_mask = modalityBit(.image),
        .generation_plan_sha256 = first.generation_plan_sha256,
        .tenant_scope_sha256 = first.tenant_scope_sha256,
        .metadata_policy_sha256 = first.metadata_policy_sha256,
        .challenge_sha256 = first.challenge_sha256,
        .receipt_table_sha256 = domainRoot(receipt_table_domain, &table),
        .previous_batch_sha256 = zero_digest,
        .registry_manifest_sha256 = first.registry_manifest_sha256,
        .registry_archive_sha256 = first.registry_archive_sha256,
        .first_receipt_sha256 = first.receipt_sha256,
        .terminal_image_sha256 = second.receipt_sha256,
        .terminal_audio_sha256 = zero_digest,
        .terminal_video_sha256 = zero_digest,
        .batch_sha256 = zero_digest,
    };
    var evidence: [
        batch_header_bytes +
            2 * transition_receipt_bytes
    ]u8 = undefined;
    _ = try encodeBatchEvidenceV1(batch, &table, &evidence);

    second.previous_transition_receipt_sha256 =
        model.sha256("foreign predecessor");
    second.receipt_sha256 = zero_digest;
    const forged_second = try encodeTransitionReceiptV1(
        second,
        &second_wire,
    );
    @memcpy(table[transition_receipt_bytes..], forged_second);
    batch.receipt_table_sha256 =
        domainRoot(receipt_table_domain, &table);
    batch.terminal_image_sha256 =
        forged_second[1696..1728].*;
    try std.testing.expectError(
        Error.InvalidBatch,
        encodeBatchEvidenceV1(batch, &table, &evidence),
    );
}

test "reference replay spans every producer and two generations" {
    const request_epoch: u64 = 701_001;
    const tenant = referenceIdentityV1("tenant");
    const policy = referenceIdentityV1("metadata-policy");
    const challenge = referenceIdentityV1("challenge");
    var image1 = try makeReferenceImageV1(
        "image-one",
        request_epoch,
        tenant,
        policy,
        challenge,
        0,
        null,
        null,
    );
    var image2 = try makeReferenceImageV1(
        "image-two",
        request_epoch,
        tenant,
        policy,
        challenge,
        1,
        image1.producer_plan.plan_sha256,
        image1.producer_result.result_sha256,
    );
    var audio1 = try makeReferenceAudioV1(
        "audio-one",
        request_epoch,
        tenant,
        policy,
        challenge,
        .{ 129, 127 },
        null,
    );
    var video1 = try makeReferenceVideoV1(
        "video-one",
        request_epoch,
        tenant,
        policy,
        challenge,
        .{ 3, 7 },
        null,
    );
    var outputs1 = [_]OutputTransitionV1{
        image1.output(),
        image2.output(),
        audio1.output(),
        video1.output(),
    };
    const input1: BatchInputV1 = .{
        .previous = null,
        .generation_plan_sha256 = referenceIdentityV1("generation-plan-one"),
        .outputs = &outputs1,
    };
    const scratch1_len = try requiredScratchBytesV1(input1);
    const archive1_len = try requiredArchiveBytesV1(input1);
    const evidence1_len = try requiredEvidenceBytesV1(
        outputs1.len,
    );
    try std.testing.expectEqual(
        @as(usize, 7_552),
        evidence1_len,
    );
    var scratch1: [16 * 1024]u8 = undefined;
    var archive1: [16 * 1024]u8 = undefined;
    var evidence1: [
        batch_header_bytes +
            4 * transition_receipt_bytes
    ]u8 = undefined;
    const prepared1 = try encodeArchiveAndEvidenceV1(
        input1,
        scratch1[0..scratch1_len],
        archive1[0..archive1_len],
        evidence1[0..evidence1_len],
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        scratch1[0..scratch1_len],
        0,
    ));
    const decoded_registry1 = try registry.decodeArchiveV1(
        prepared1.registry_archive.set.bytes,
        null,
    );
    _ = try validateArchiveAndEvidenceV1(.{
        .registry_archive = decoded_registry1,
        .evidence = prepared1.evidence,
    });
    var preflight_scratch: [16 * 1024]u8 = undefined;
    var preflight_archive: [16 * 1024]u8 = undefined;
    var preflight_evidence: [
        batch_header_bytes +
            4 * transition_receipt_bytes
    ]u8 = undefined;
    @memset(preflight_scratch[0..scratch1_len], 0xd1);
    @memset(preflight_archive[0..archive1_len], 0xd2);
    @memset(preflight_evidence[0..evidence1_len], 0xd3);

    var mismatched_callback_count: u8 = 0;
    var mismatched_output = image1.output();
    mismatched_output.model_execution =
        audio1.model_storage.execution();
    mismatched_output.model_execution.stateless.adapter.context =
        &mismatched_callback_count;
    mismatched_output.model_execution.stateless.adapter.execute_fn =
        unexpectedStatelessExecuteV1;
    var mismatched_outputs = outputs1;
    mismatched_outputs[0] = mismatched_output;
    try std.testing.expectError(
        Error.InvalidBatch,
        encodeArchiveAndEvidenceV1(
            .{
                .previous = null,
                .generation_plan_sha256 = input1.generation_plan_sha256,
                .outputs = &mismatched_outputs,
            },
            preflight_scratch[0..scratch1_len],
            preflight_archive[0..archive1_len],
            preflight_evidence[0..evidence1_len],
        ),
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        mismatched_callback_count,
    );

    var oversized_callback_count: u8 = 0;
    var oversized_support_output = audio1.output();
    const support_pointer: [*]const model.SupportRecordV1 =
        @ptrCast(&audio1.model_storage.support[0]);
    oversized_support_output.model_execution.stateless.support_records =
        support_pointer[0..std.math.maxInt(usize)];
    oversized_support_output.model_execution.stateless.adapter.context =
        &oversized_callback_count;
    oversized_support_output.model_execution.stateless.adapter.execute_fn =
        unexpectedStatelessExecuteV1;
    var oversized_support_outputs = outputs1;
    oversized_support_outputs[2] = oversized_support_output;
    try std.testing.expectError(
        Error.InvalidModelExecution,
        encodeArchiveAndEvidenceV1(
            .{
                .previous = null,
                .generation_plan_sha256 = input1.generation_plan_sha256,
                .outputs = &oversized_support_outputs,
            },
            preflight_scratch[0..scratch1_len],
            preflight_archive[0..archive1_len],
            preflight_evidence[0..evidence1_len],
        ),
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        oversized_callback_count,
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        preflight_scratch[0..scratch1_len],
        0xd1,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        preflight_archive[0..archive1_len],
        0xd2,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        preflight_evidence[0..evidence1_len],
        0xd3,
    ));
    const expected_first_batch = try digestFromHexV1(
        "378f2f3bd09244959394bdcc57002561796b852950cdaf20a9704ac69a9c4a04",
    );
    const expected_first_archive = try digestFromHexV1(
        "9d2e61b94d8ab277e9b791e743d7021a89056cbd4e2d315beadad90bfd690451",
    );
    const first_evidence =
        try decodeBatchEvidenceV1(prepared1.evidence);
    try std.testing.expectEqual(
        expected_first_batch,
        prepared1.batch.batch_sha256,
    );
    try std.testing.expectEqual(
        expected_first_archive,
        decoded_registry1.archive_sha256,
    );
    const first_image = try first_evidence.receipt(0);
    const second_image = try first_evidence.receipt(1);
    try std.testing.expectEqual(@as(u64, 1), first_image.producer_ordinal);
    try std.testing.expectEqual(@as(u64, 0), first_image.registry_ordinal);
    try std.testing.expectEqual(@as(u64, 1), second_image.producer_ordinal);
    try std.testing.expectEqual(@as(u64, 1), second_image.registry_ordinal);
    try std.testing.expectEqual(
        first_image.receipt_sha256,
        second_image.previous_transition_receipt_sha256,
    );
    var forged_genesis = evidence1;
    const foreign_genesis_parent =
        model.sha256("foreign genesis parent");
    @memcpy(
        forged_genesis[288..320],
        &foreign_genesis_parent,
    );
    const forged_genesis_root = domainRoot(
        batch_domain,
        forged_genesis[0..batch_body_bytes],
    );
    @memcpy(
        forged_genesis[batch_body_bytes..batch_header_bytes],
        &forged_genesis_root,
    );
    try std.testing.expectError(
        Error.InvalidPreviousEvidence,
        validateArchiveAndEvidenceV1(.{
            .registry_archive = decoded_registry1,
            .evidence = &forged_genesis,
        }),
    );

    var image3 = try makeReferenceImageV1(
        "image-three",
        request_epoch,
        tenant,
        policy,
        challenge,
        2,
        image2.producer_plan.plan_sha256,
        image2.producer_result.result_sha256,
    );
    var audio2 = try makeReferenceAudioV1(
        "audio-two",
        request_epoch,
        tenant,
        policy,
        challenge,
        .{ 130, 126 },
        &audio1,
    );
    var video2 = try makeReferenceVideoV1(
        "video-two",
        request_epoch,
        tenant,
        policy,
        challenge,
        .{ 11, 13 },
        &video1,
    );
    var outputs2 = [_]OutputTransitionV1{
        image3.output(),
        audio2.output(),
        video2.output(),
    };
    const input2: BatchInputV1 = .{
        .previous = .{
            .registry_archive = decoded_registry1,
            .evidence = prepared1.evidence,
        },
        .generation_plan_sha256 = referenceIdentityV1("generation-plan-two"),
        .outputs = &outputs2,
    };
    const scratch2_len = try requiredScratchBytesV1(input2);
    const archive2_len = try requiredArchiveBytesV1(input2);
    const evidence2_len = try requiredEvidenceBytesV1(
        outputs2.len,
    );
    var scratch2: [16 * 1024]u8 = undefined;
    var archive2: [16 * 1024]u8 = undefined;
    var evidence2: [
        batch_header_bytes +
            3 * transition_receipt_bytes
    ]u8 = undefined;
    const prepared2 = try encodeArchiveAndEvidenceV1(
        input2,
        scratch2[0..scratch2_len],
        archive2[0..archive2_len],
        evidence2[0..evidence2_len],
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        scratch2[0..scratch2_len],
        0,
    ));
    const decoded_registry2 = try registry.decodeArchiveV1(
        prepared2.registry_archive.set.bytes,
        decoded_registry1.previous(),
    );
    _ = try validateArchiveAndEvidenceV1(.{
        .registry_archive = decoded_registry2,
        .evidence = prepared2.evidence,
    });
    var sparse_callback_count: u8 = 0;
    var sparse_audio_output = audio2.output();
    sparse_audio_output.model_execution.stateless.adapter.context =
        &sparse_callback_count;
    sparse_audio_output.model_execution.stateless.adapter.execute_fn =
        unexpectedStatelessExecuteV1;
    var sparse_successor_outputs = [_]OutputTransitionV1{
        sparse_audio_output,
        video2.output(),
    };
    @memset(preflight_scratch[0..scratch2_len], 0xe1);
    @memset(preflight_archive[0..archive2_len], 0xe2);
    @memset(preflight_evidence[0..evidence2_len], 0xe3);
    try std.testing.expectError(
        Error.InvalidBatch,
        encodeArchiveAndEvidenceV1(
            .{
                .previous = .{
                    .registry_archive = decoded_registry1,
                    .evidence = prepared1.evidence,
                },
                .generation_plan_sha256 = input2.generation_plan_sha256,
                .outputs = &sparse_successor_outputs,
            },
            preflight_scratch[0..scratch2_len],
            preflight_archive[0..archive2_len],
            preflight_evidence[0..evidence2_len],
        ),
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        sparse_callback_count,
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        preflight_scratch[0..scratch2_len],
        0xe1,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        preflight_archive[0..archive2_len],
        0xe2,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        preflight_evidence[0..evidence2_len],
        0xe3,
    ));
    const expected_second_batch = try digestFromHexV1(
        "eb61927cf2de6bb3ffa3749c632de86e8d3cffe2e19d3b88a9014570f9b81a9a",
    );
    const expected_second_archive = try digestFromHexV1(
        "01daaf273535e7aa3a40dc87e771aeeaacd5408bcc54bcb9d5904ff7eaf80374",
    );
    try std.testing.expectEqual(
        expected_second_batch,
        prepared2.batch.batch_sha256,
    );
    try std.testing.expectEqual(
        expected_second_archive,
        decoded_registry2.archive_sha256,
    );
    try std.testing.expectEqual(
        prepared1.batch.batch_sha256,
        prepared2.batch.previous_batch_sha256,
    );
    _ = try validateSuccessorArchiveAndEvidenceV1(
        .{
            .registry_archive = decoded_registry2,
            .evidence = prepared2.evidence,
        },
        .{
            .registry_archive = decoded_registry1,
            .evidence = prepared1.evidence,
        },
    );
    var forged_link = evidence2;
    const foreign_batch = model.sha256("foreign batch anchor");
    @memcpy(forged_link[288..320], &foreign_batch);
    const forged_batch_root = domainRoot(
        batch_domain,
        forged_link[0..batch_body_bytes],
    );
    @memcpy(
        forged_link[batch_body_bytes..batch_header_bytes],
        &forged_batch_root,
    );
    _ = try validateArchiveAndEvidenceV1(.{
        .registry_archive = decoded_registry2,
        .evidence = &forged_link,
    });
    try std.testing.expectError(
        Error.InvalidPreviousEvidence,
        validateSuccessorArchiveAndEvidenceV1(
            .{
                .registry_archive = decoded_registry2,
                .evidence = &forged_link,
            },
            .{
                .registry_archive = decoded_registry1,
                .evidence = prepared1.evidence,
            },
        ),
    );

    @memset(scratch1[0..scratch1_len], 0xa5);
    @memset(archive1[0..archive1_len], 0xb6);
    @memset(evidence1[0..evidence1_len], 0xc7);
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeArchiveAndEvidenceV1(
            input1,
            scratch1[0 .. scratch1_len - 1],
            archive1[0..archive1_len],
            evidence1[0..evidence1_len],
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        scratch1[0..scratch1_len],
        0xa5,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        archive1[0..archive1_len],
        0xb6,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        evidence1[0..evidence1_len],
        0xc7,
    ));
    var aliased: [16 * 1024]u8 = undefined;
    try std.testing.expectError(
        Error.BufferAlias,
        encodeArchiveAndEvidenceV1(
            input1,
            aliased[0..scratch1_len],
            aliased[0..archive1_len],
            evidence1[0..evidence1_len],
        ),
    );

    audio1.model_storage.output[0] ^= 1;
    outputs1[2] = audio1.output();
    try std.testing.expectError(
        Error.InvalidModelExecution,
        encodeArchiveAndEvidenceV1(
            input1,
            scratch1[0..scratch1_len],
            archive1[0..archive1_len],
            evidence1[0..evidence1_len],
        ),
    );
    audio1.model_storage.output[0] ^= 1;
    outputs1[2] = audio1.output();
    var foreign_payload_output = audio1.output();
    foreign_payload_output.producer_execution.audio
        .materializer_payload = "foreign renderer payload";
    outputs1[2] = foreign_payload_output;
    try std.testing.expectError(
        Error.InvalidProducerExecution,
        encodeArchiveAndEvidenceV1(
            input1,
            scratch1[0..scratch1_len],
            archive1[0..archive1_len],
            evidence1[0..evidence1_len],
        ),
    );
    outputs1[2] = audio1.output();
    image1.model_storage.state_before[0] ^= 1;
    outputs1[0] = image1.output();
    try std.testing.expectError(
        Error.InvalidModelExecution,
        encodeArchiveAndEvidenceV1(
            input1,
            scratch1[0..scratch1_len],
            archive1[0..archive1_len],
            evidence1[0..evidence1_len],
        ),
    );
    image1.model_storage.state_before[0] ^= 1;
    outputs1[0] = image1.output();
    const original_ack_wire =
        audio1.acknowledgement_result_wire;
    var foreign_ack = try audio.decodePlaybackAckResultV1(
        &audio1.acknowledgement_result_wire,
    );
    foreign_ack.previous_ack_result_sha256 =
        model.sha256("foreign acknowledgement");
    foreign_ack.result_sha256 =
        audio.ackResultRootV1(foreign_ack);
    _ = try audio.encodePlaybackAckResultV1(
        foreign_ack,
        &audio1.acknowledgement_result_wire,
    );
    outputs1[2] = audio1.output();
    try std.testing.expectError(
        Error.InvalidProducerExecution,
        encodeArchiveAndEvidenceV1(
            input1,
            scratch1[0..scratch1_len],
            archive1[0..archive1_len],
            evidence1[0..evidence1_len],
        ),
    );
    audio1.acknowledgement_result_wire = original_ack_wire;
    outputs1[2] = audio1.output();
    image1.raw_output[0] ^= 1;
    outputs1[0] = image1.output();
    try std.testing.expectError(
        Error.InvalidProducerExecution,
        encodeArchiveAndEvidenceV1(
            input1,
            scratch1[0..scratch1_len],
            archive1[0..archive1_len],
            evidence1[0..evidence1_len],
        ),
    );
}

fn digestFromHexV1(encoded: []const u8) !Digest {
    if (encoded.len != 64) return Error.InvalidWire;
    var value: Digest = undefined;
    _ = try std.fmt.hexToBytes(&value, encoded);
    return value;
}

fn syntheticTransitionReceiptV1(
    registry_ordinal: u64,
) TransitionReceiptV1 {
    const one = model.sha256("one");
    const previous = if (registry_ordinal == 0)
        zero_digest
    else
        model.sha256("previous");
    var value: TransitionReceiptV1 = .{
        .modality = .image,
        .model_kind = .stateful,
        .completion_kind = .none,
        .request_epoch = 9,
        .producer_generation = 1,
        .producer_ordinal = 1,
        .registry_ordinal = registry_ordinal,
        .unit_start = registry_ordinal,
        .unit_count = 1,
        .timeline_start = registry_ordinal,
        .timeline_end = registry_ordinal + 1,
        .weights_bytes = 1,
        .model_input_bytes = 1,
        .model_state_before_bytes = 1,
        .model_output_bytes = 1,
        .model_state_after_bytes = 1,
        .materializer_payload_bytes = 1,
        .raw_output_bytes = 1,
        .encoded_payload_bytes = 1,
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
        .producer_plan_or_manifest_sha256 = one,
        .producer_state_before_sha256 = one,
        .media_object_sha256 = one,
        .materializer_payload_sha256 = one,
        .materializer_implementation_sha256 = one,
        .materializer_execution_sha256 = one,
        .raw_output_sha256 = one,
        .provenance_sha256 = one,
        .producer_receipt_wire_sha256 = one,
        .producer_resource_sha256 = one,
        .publication_result_sha256 = one,
        .producer_state_after_publication_sha256 = one,
        .completion_observation_sha256 = zero_digest,
        .completion_plan_sha256 = zero_digest,
        .completion_result_sha256 = zero_digest,
        .producer_final_state_sha256 = one,
        .encoder_implementation_sha256 = one,
        .format_sha256 = one,
        .encoded_payload_sha256 = one,
        .previous_transition_receipt_sha256 = previous,
        .producer_projection_sha256 = one,
        .registry_previous_entry_sha256 = previous,
        .registry_entry_sha256 = one,
        .registry_manifest_sha256 = one,
        .registry_archive_sha256 = one,
        .receipt_sha256 = zero_digest,
    };
    value.materializer_execution_sha256 =
        materializerExecutionRootV1(
            value.modality,
            value.producer_plan_or_manifest_sha256,
            value.model_output_sha256,
            value.materializer_payload_sha256,
            value.materializer_implementation_sha256,
            value.raw_output_sha256,
            value.materializer_required_capabilities,
            value.model_output_bytes,
            @intCast(value.materializer_payload_bytes),
            @intCast(value.raw_output_bytes),
        );
    value.producer_projection_sha256 =
        producerProjectionFromReceiptV1(value);
    return value;
}

const reference_fixture_domain =
    "glacier-generated-media-producer-transition-reference-v1\x00";
const reference_delivery_abi: u64 = 0x454e_4300_0000_0001;
const reference_adapter_abi: u64 = 0x474d_5452_4e00_0001;

const ReferenceModelStorageV1 = struct {
    kind: ModelKindV1,
    manifest: model.ArtifactManifestV1,
    plan: model.ExecutionPlanV1,
    result: model.ResultEnvelopeV1,
    publication_before: model.PublicationStateV1,
    publication_after: model.PublicationStateV1,
    state_publication_before: stateful.StatePublicationV1 = undefined,
    state_publication_after: stateful.StatePublicationV1 = undefined,
    checkpoint_before: continuation.CheckpointV1 = undefined,
    descriptor: stateless.AdapterDescriptorV1,
    support: [1]model.SupportRecordV1,
    weights: [4]u8 = [_]u8{0} ** 4,
    weights_len: usize,
    input: [4]u8 = [_]u8{0} ** 4,
    input_len: usize,
    state_before: [4]u8 = [_]u8{0} ** 4,
    state_before_len: usize = 0,
    output: [4]u8 = [_]u8{0} ** 4,
    output_len: usize,
    state_after: [4]u8 = [_]u8{0} ** 4,
    state_after_len: usize = 0,
    manifest_wire: [model.artifact_manifest_bytes]u8 = undefined,
    plan_wire: [model.execution_plan_bytes]u8 = undefined,
    result_wire: [model.result_envelope_bytes]u8 = undefined,
    publication_before_wire: [model_publication_bytes]u8 = undefined,
    publication_after_wire: [model_publication_bytes]u8 = undefined,
    descriptor_wire: [adapter_descriptor_bytes]u8 = undefined,
    state_publication_before_wire: [stateful.state_publication_bytes]u8 =
        undefined,
    state_publication_after_wire: [stateful.state_publication_bytes]u8 =
        undefined,
    checkpoint_wire: [continuation.checkpoint_bytes]u8 = undefined,
    checkpoint_result_wire: [model.result_envelope_bytes]u8 = undefined,
    context: u8 = 1,

    fn execution(
        self: *ReferenceModelStorageV1,
    ) ModelExecutionV1 {
        return switch (self.kind) {
            .stateless => .{ .stateless = .{
                .artifact_manifest = &self.manifest_wire,
                .plan = &self.plan_wire,
                .publication_before = &self.publication_before_wire,
                .publication_after = &self.publication_after_wire,
                .adapter_descriptor = &self.descriptor_wire,
                .result = &self.result_wire,
                .support_records = &self.support,
                .weights = self.weights[0..self.weights_len],
                .input = self.input[0..self.input_len],
                .output = self.output[0..self.output_len],
                .adapter = .{
                    .context = &self.context,
                    .descriptor = self.descriptor,
                    .execute_fn = referenceStatelessExecuteV1,
                    .validate_candidate_fn = referenceStatelessValidateV1,
                },
            } },
            .stateful => .{ .stateful = .{
                .artifact_manifest = &self.manifest_wire,
                .plan = &self.plan_wire,
                .publication_before = &self.publication_before_wire,
                .publication_after = &self.publication_after_wire,
                .state_publication_before = &self.state_publication_before_wire,
                .state_publication_after = &self.state_publication_after_wire,
                .checkpoint_before = .{
                    .checkpoint = &self.checkpoint_wire,
                    .previous_result = &self.checkpoint_result_wire,
                },
                .adapter_descriptor = &self.descriptor_wire,
                .result = &self.result_wire,
                .support_records = &self.support,
                .weights = self.weights[0..self.weights_len],
                .input = self.input[0..self.input_len],
                .state_before = self.state_before[0..self.state_before_len],
                .output = self.output[0..self.output_len],
                .state_after = self.state_after[0..self.state_after_len],
                .adapter = .{
                    .context = &self.context,
                    .descriptor = self.descriptor,
                    .execute_fn = latent.referenceExecuteV1,
                    .validate_candidate_fn = latent.validateCandidateV1,
                },
            } },
        };
    }
};

fn sealReferenceModelStorageV1(
    value: *ReferenceModelStorageV1,
    checkpoint_result: ?model.ResultEnvelopeV1,
) !void {
    try model.encodeArtifactManifestV1(
        value.manifest,
        &value.manifest_wire,
    );
    try model.encodeExecutionPlanV1(value.plan, &value.plan_wire);
    try model.encodeResultEnvelopeV1(value.result, &value.result_wire);
    _ = try encodeModelPublicationV1(
        value.publication_before,
        &value.publication_before_wire,
    );
    _ = try encodeModelPublicationV1(
        value.publication_after,
        &value.publication_after_wire,
    );
    _ = try encodeAdapterDescriptorV1(
        value.descriptor,
        &value.descriptor_wire,
    );
    if (value.kind == .stateful) {
        _ = try stateful.encodeStatePublicationV1(
            value.state_publication_before,
            &value.state_publication_before_wire,
        );
        _ = try stateful.encodeStatePublicationV1(
            value.state_publication_after,
            &value.state_publication_after_wire,
        );
        _ = try continuation.encodeCheckpointV1(
            value.checkpoint_before,
            &value.checkpoint_wire,
        );
        try model.encodeResultEnvelopeV1(
            checkpoint_result orelse return Error.InvalidModelExecution,
            &value.checkpoint_result_wire,
        );
    }
}

fn referenceIdentityV1(label: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(reference_fixture_domain);
    hash.update(label);
    return hash.finalResult();
}

fn referenceIdentityPartsV1(
    prefix: []const u8,
    label: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(reference_fixture_domain);
    hash.update(prefix);
    hash.update(label);
    return hash.finalResult();
}

fn referenceModelClaimV1(
    weight_bytes: u64,
    input_bytes: u64,
    output_bytes: u64,
) resource_bank.Claim {
    return .{
        .capsule_bytes = weight_bytes,
        .activation_bytes = input_bytes,
        .partial_bytes = output_bytes,
        .output_journal_bytes = output_bytes,
        .staging_bytes = output_bytes,
        .queue_slots = 1,
    };
}

fn referenceSupportV1(
    descriptor: stateless.AdapterDescriptorV1,
) [1]model.SupportRecordV1 {
    return .{.{
        .family = descriptor.family,
        .operation = descriptor.operation,
        .input_kind = descriptor.input_kind,
        .output_kind = descriptor.output_kind,
        .numerical_policy = descriptor.numerical_policy,
        .max_batch_items = descriptor.max_batch_items,
        .max_input_features = descriptor.max_input_features,
        .max_output_dimensions = descriptor.max_output_dimensions,
        .allowed_capabilities = descriptor.allowed_capabilities,
    }};
}

fn referenceReceiptV1(
    bank_epoch: u64,
    slot_index: u32,
    generation: u64,
    owner_key: u64,
    claim: resource_bank.Claim,
) resource_bank.Receipt {
    var value: resource_bank.Receipt = .{
        .bank_epoch = bank_epoch,
        .slot_index = slot_index,
        .generation = generation,
        .owner_key = owner_key,
        .claim = claim,
        .integrity = 0,
    };
    value.integrity = referenceReceiptIntegrityV1(value);
    return value;
}

fn referenceReceiptIntegrityV1(
    value: resource_bank.Receipt,
) u64 {
    var result = referenceMix64V1(
        0x7265_6365_6970_7431 ^ value.bank_epoch,
    );
    result = referenceMix64V1(result ^ value.slot_index);
    result = referenceMix64V1(result ^ value.generation);
    result = referenceMix64V1(result ^ value.owner_key);
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        result = referenceMix64V1(
            result ^ @field(value.claim, field.name),
        );
    return result;
}

fn referenceMix64V1(value: u64) u64 {
    var mixed = value;
    mixed ^= mixed >> 30;
    mixed *%= 0xbf58_476d_1ce4_e5b9;
    mixed ^= mixed >> 27;
    mixed *%= 0x94d0_49bb_1331_11eb;
    mixed ^= mixed >> 31;
    return mixed;
}

fn referenceStatelessExecuteV1(
    _: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    weights: []const u8,
    input: []const u8,
    candidate: []u8,
) anyerror!void {
    const features = std.math.cast(
        usize,
        plan.input_features,
    ) orelse return Error.InvalidModelExecution;
    const dimensions = std.math.cast(
        usize,
        plan.output_dimensions,
    ) orelse return Error.InvalidModelExecution;
    if (plan.input_element_bytes != 1 or
        plan.output_element_bytes != 1 or
        input.len != features or
        weights.len != features * dimensions or
        candidate.len != dimensions)
        return Error.InvalidModelExecution;
    for (0..dimensions) |dimension| {
        var accumulator: u64 = 0;
        for (0..features) |feature| {
            accumulator +=
                @as(u64, input[feature]) *
                @as(u64, weights[dimension * features + feature]);
        }
        if (accumulator > plan.maximum_absolute_output or
            accumulator > std.math.maxInt(u8))
            return Error.InvalidModelExecution;
        candidate[dimension] = @intCast(accumulator);
    }
}

fn unexpectedStatelessExecuteV1(
    context: *anyopaque,
    _: *const model.ExecutionPlanV1,
    _: []const u8,
    _: []const u8,
    _: []u8,
) anyerror!void {
    const call_count: *u8 = @ptrCast(context);
    call_count.* +%= 1;
    return error.UnexpectedCallback;
}

fn referenceStatelessValidateV1(
    _: *anyopaque,
    plan: *const model.ExecutionPlanV1,
    candidate: []const u8,
) anyerror!void {
    if (candidate.len != plan.output_bytes)
        return Error.InvalidModelExecution;
    for (candidate) |value| {
        if (value > plan.maximum_absolute_output)
            return Error.InvalidModelExecution;
    }
}

fn makeReferenceStatelessModelV1(
    label: []const u8,
    family: model.ModelFamilyIdV1,
    request_epoch: u64,
    challenge_sha256: Digest,
    model_input: [2]u8,
    previous: ?*const ReferenceModelStorageV1,
) !ReferenceModelStorageV1 {
    const weights = [_]u8{
        1, 0,
        0, 1,
    };
    const manifest = if (previous) |prior|
        prior.manifest
    else
        try model.makeArtifactManifestV1(
            family,
            0x5354_4154_4500_0001,
            .latent_tensor,
            .media_chunk,
            .exact_integer,
            1,
            model_input.len,
            model_input.len,
            1,
            1,
            1,
            &weights,
            referenceIdentityPartsV1("metadata:", label),
            referenceIdentityPartsV1("license:", label),
        );
    const publication_before = if (previous) |prior|
        prior.publication_after
    else
        try model.initializePublicationStateV1(
            request_epoch,
            manifest.artifact_sha256,
        );
    const generation = if (previous) |prior|
        try checkedAdd(prior.plan.generation, 1)
    else
        1;
    const previous_plan_sha256 = if (previous) |prior|
        prior.plan.plan_sha256
    else
        referenceIdentityPartsV1(
            "model-plan-genesis:",
            label,
        );
    const plan = try model.makeExecutionPlanV1(
        manifest,
        .synthesize,
        .{
            .request_epoch = request_epoch,
            .generation = generation,
            .batch_items = 1,
            .publication_next_sequence = publication_before.next_sequence,
            .maximum_absolute_output = 255,
            .claim = referenceModelClaimV1(
                weights.len,
                model_input.len,
                model_input.len,
            ),
            .media_object_sha256 = referenceIdentityPartsV1("model-media:", label),
            .processor_state_sha256 = referenceIdentityPartsV1(
                "stateless-processor:",
                label,
            ),
            .processor_bundle_sha256 = referenceIdentityPartsV1(
                "processor-bundle:",
                label,
            ),
            .cache_bundle_sha256 = referenceIdentityPartsV1(
                "cache-bundle:",
                label,
            ),
            .cache_payload_sha256 = referenceIdentityPartsV1(
                "stateless-cache:",
                label,
            ),
            .ownership_sha256 = referenceIdentityPartsV1("ownership:", label),
            .challenge_sha256 = challenge_sha256,
            .previous_plan_sha256 = previous_plan_sha256,
            .input_schema_sha256 = referenceIdentityPartsV1(
                "input-schema:",
                label,
            ),
            .output_schema_sha256 = referenceIdentityPartsV1(
                "output-schema:",
                label,
            ),
            .scratch_bytes = model_input.len,
        },
    );
    const implementation_sha256 = referenceIdentityPartsV1(
        "stateless-u8-projection:",
        label,
    );
    const descriptor = try stateless.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .synthesize,
        0,
        implementation_sha256,
    );
    var context: u8 = 1;
    var output: [2]u8 = undefined;
    try referenceStatelessExecuteV1(
        &context,
        &plan,
        &weights,
        &model_input,
        &output,
    );
    const mapping_sha256 = statelessSourceMappingRootV1(
        plan,
        model.sha256(&weights),
        model.sha256(&model_input),
        model.sha256(&output),
        descriptor.adapter_sha256,
        weights.len,
        model_input.len,
        output.len,
    );
    const family_value = @intFromEnum(family);
    const receipt = referenceReceiptV1(
        try checkedAdd(710_000, family_value),
        std.math.cast(
            u32,
            generation - 1,
        ) orelse return Error.ArithmeticOverflow,
        generation,
        try checkedAdd(
            try checkedAdd(
                720_000,
                try std.math.mul(u64, family_value, 10),
            ),
            generation,
        ),
        plan.claim,
    );
    const result = try model.prepareResultEnvelopeV1(
        publication_before,
        plan,
        receipt,
        model.sha256(&output),
        mapping_sha256,
        descriptor.adapter_sha256,
    );
    var publication_after = publication_before;
    try model.commitResultV1(&publication_after, result);
    var storage: ReferenceModelStorageV1 = .{
        .kind = .stateless,
        .manifest = manifest,
        .plan = plan,
        .result = result,
        .publication_before = publication_before,
        .publication_after = publication_after,
        .descriptor = descriptor,
        .support = referenceSupportV1(descriptor),
        .weights_len = weights.len,
        .input_len = model_input.len,
        .output_len = output.len,
    };
    @memcpy(storage.weights[0..weights.len], &weights);
    @memcpy(storage.input[0..model_input.len], &model_input);
    @memcpy(storage.output[0..output.len], &output);
    try sealReferenceModelStorageV1(&storage, null);
    return storage;
}

const ReferenceDeliveryV1 = struct {
    bytes: [128]u8 = [_]u8{0} ** 128,
    len: usize,
    encoder_implementation_sha256: Digest,
    format_sha256: Digest,

    fn slice(self: *const ReferenceDeliveryV1) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn makeReferenceDeliveryV1(
    label: []const u8,
    raw: []const u8,
) !ReferenceDeliveryV1 {
    var value: ReferenceDeliveryV1 = .{
        .len = 0,
        .encoder_implementation_sha256 = referenceIdentityPartsV1("encoder:", label),
        .format_sha256 = referenceIdentityPartsV1("format:", label),
    };
    const prefix = "transition-fixture:";
    const required = std.math.add(
        usize,
        prefix.len + label.len + 1,
        raw.len,
    ) catch return Error.ArithmeticOverflow;
    if (required > value.bytes.len) return Error.BufferTooSmall;
    var offset: usize = 0;
    @memcpy(value.bytes[offset .. offset + prefix.len], prefix);
    offset += prefix.len;
    @memcpy(value.bytes[offset .. offset + label.len], label);
    offset += label.len;
    value.bytes[offset] = ':';
    offset += 1;
    @memcpy(value.bytes[offset .. offset + raw.len], raw);
    value.len = required;
    return value;
}

const ReferenceImageStorageV1 = struct {
    model_storage: ReferenceModelStorageV1,
    producer_plan: image.GeneratedImagePlanV1,
    producer_result: image.GeneratedImageResultV1,
    publication_before_wire: [media_publication_bytes]u8 =
        undefined,
    publication_after_wire: [media_publication_bytes]u8 =
        undefined,
    plan_wire: [image.plan_bytes]u8 = undefined,
    provenance_wire: [image.provenance_bytes]u8 = undefined,
    result_wire: [image.result_bytes]u8 = undefined,
    media_object_wire: [media.descriptor_bytes]u8 = undefined,
    resource_receipt_wire: [resource_receipt_bytes]u8 = undefined,
    raw_output: [4]u8,
    delivery: ReferenceDeliveryV1,
    decoder_context: u8 = 1,

    fn output(
        self: *ReferenceImageStorageV1,
    ) OutputTransitionV1 {
        return .{
            .model_execution = self.model_storage.execution(),
            .producer_execution = .{ .image = .{
                .publication_before = &self.publication_before_wire,
                .publication_after = &self.publication_after_wire,
                .plan = &self.plan_wire,
                .provenance = &self.provenance_wire,
                .result = &self.result_wire,
                .media_object = &self.media_object_wire,
                .resource_receipt = &self.resource_receipt_wire,
                .materializer_payload = &image.reference_decoder_payload,
                .raw_output = &self.raw_output,
                .decoder = image.referenceDecoderV1(
                    &self.decoder_context,
                ),
            } },
            .encoding_abi = reference_delivery_abi,
            .encoded_payload = self.delivery.slice(),
            .encoder_implementation_sha256 = self.delivery.encoder_implementation_sha256,
            .format_sha256 = self.delivery.format_sha256,
        };
    }
};

const ReferenceAudioStorageV1 = struct {
    model_storage: ReferenceModelStorageV1,
    final_state: audio.GeneratedAudioStateV1,
    state_before_wire: [audio.state_bytes]u8 = undefined,
    state_after_publication_wire: [audio.state_bytes]u8 = undefined,
    state_after_completion_wire: [audio.state_bytes]u8 = undefined,
    plan_wire: [audio.plan_bytes]u8 = undefined,
    provenance_wire: [audio.provenance_bytes]u8 = undefined,
    result_wire: [audio.result_bytes]u8 = undefined,
    observation_wire: [audio.observation_bytes]u8 = undefined,
    acknowledgement_plan_wire: [audio.ack_plan_bytes]u8 = undefined,
    acknowledgement_result_wire: [audio.ack_result_bytes]u8 =
        undefined,
    media_object_wire: [media.descriptor_bytes]u8 = undefined,
    resource_receipt_wire: [resource_receipt_bytes]u8 = undefined,
    raw_output: [4]u8,
    delivery: ReferenceDeliveryV1,
    renderer_context: u8 = 1,

    fn output(
        self: *ReferenceAudioStorageV1,
    ) OutputTransitionV1 {
        return .{
            .model_execution = self.model_storage.execution(),
            .producer_execution = .{ .audio = .{
                .state_before = &self.state_before_wire,
                .state_after_publication = &self.state_after_publication_wire,
                .state_after_completion = &self.state_after_completion_wire,
                .plan = &self.plan_wire,
                .provenance = &self.provenance_wire,
                .result = &self.result_wire,
                .observation = &self.observation_wire,
                .acknowledgement_plan = &self.acknowledgement_plan_wire,
                .acknowledgement_result = &self.acknowledgement_result_wire,
                .media_object = &self.media_object_wire,
                .resource_receipt = &self.resource_receipt_wire,
                .materializer_payload = audio.reference_renderer_payload,
                .raw_output = &self.raw_output,
                .renderer = audio.referenceRendererV1(
                    &self.renderer_context,
                ),
            } },
            .encoding_abi = reference_delivery_abi,
            .encoded_payload = self.delivery.slice(),
            .encoder_implementation_sha256 = self.delivery.encoder_implementation_sha256,
            .format_sha256 = self.delivery.format_sha256,
        };
    }
};

const ReferenceVideoStorageV1 = struct {
    model_storage: ReferenceModelStorageV1,
    final_state: video.GeneratedVideoStateV1,
    state_before_wire: [video.state_bytes]u8 = undefined,
    state_after_publication_wire: [video.state_bytes]u8 = undefined,
    state_after_completion_wire: [video.state_bytes]u8 = undefined,
    manifest_wire: [video.manifest_bytes]u8 = undefined,
    provenance_wire: [video.provenance_bytes]u8 = undefined,
    result_wire: [video.result_bytes]u8 = undefined,
    observation_wire: [video.observation_bytes]u8 = undefined,
    acknowledgement_plan_wire: [video.ack_plan_bytes]u8 = undefined,
    acknowledgement_result_wire: [video.ack_result_bytes]u8 =
        undefined,
    media_object_wire: [media.descriptor_bytes]u8 = undefined,
    resource_receipt_wire: [resource_receipt_bytes]u8 = undefined,
    raw_output: [8]u8,
    delivery: ReferenceDeliveryV1,
    renderer_context: u8 = 1,

    fn output(
        self: *ReferenceVideoStorageV1,
    ) OutputTransitionV1 {
        return .{
            .model_execution = self.model_storage.execution(),
            .producer_execution = .{ .video = .{
                .state_before = &self.state_before_wire,
                .state_after_publication = &self.state_after_publication_wire,
                .state_after_completion = &self.state_after_completion_wire,
                .manifest = &self.manifest_wire,
                .provenance = &self.provenance_wire,
                .result = &self.result_wire,
                .observation = &self.observation_wire,
                .acknowledgement_plan = &self.acknowledgement_plan_wire,
                .acknowledgement_result = &self.acknowledgement_result_wire,
                .media_object = &self.media_object_wire,
                .resource_receipt = &self.resource_receipt_wire,
                .materializer_payload = video.reference_renderer_payload,
                .raw_output = &self.raw_output,
                .renderer = video.referenceRendererV1(
                    &self.renderer_context,
                ),
            } },
            .encoding_abi = reference_delivery_abi,
            .encoded_payload = self.delivery.slice(),
            .encoder_implementation_sha256 = self.delivery.encoder_implementation_sha256,
            .format_sha256 = self.delivery.format_sha256,
        };
    }
};

fn referenceStateAfterV1(
    before: stateful.StatePublicationV1,
    result: model.ResultEnvelopeV1,
    next_state: []const u8,
) !stateful.StatePublicationV1 {
    var value = before;
    value.current_step = try checkedAdd(value.current_step, 1);
    value.current_state_sha256 = model.sha256(next_state);
    value.previous_result_sha256 = result.result_sha256;
    value.publication_sha256 =
        stateful.statePublicationRootV1(value);
    try stateful.validateStatePublicationV1(value);
    return value;
}

fn makeReferenceLatentPlanV1(
    manifest: model.ArtifactManifestV1,
    state_publication: stateful.StatePublicationV1,
    request_epoch: u64,
    publication_next_sequence: u64,
    previous_plan_sha256: Digest,
    challenge_sha256: Digest,
    label: []const u8,
) !model.ExecutionPlanV1 {
    return model.makeExecutionPlanV1(
        manifest,
        .diffuse_step,
        .{
            .request_epoch = request_epoch,
            .generation = try checkedAdd(state_publication.current_step, 1),
            .batch_items = 1,
            .publication_next_sequence = publication_next_sequence,
            .maximum_absolute_output = 255,
            .claim = referenceModelClaimV1(1, 4, 4),
            .media_object_sha256 = referenceIdentityPartsV1("model-media:", label),
            .processor_state_sha256 = state_publication.publication_sha256,
            .processor_bundle_sha256 = referenceIdentityPartsV1(
                "processor-bundle:",
                label,
            ),
            .cache_bundle_sha256 = referenceIdentityPartsV1(
                "cache-bundle:",
                label,
            ),
            .cache_payload_sha256 = state_publication.current_state_sha256,
            .ownership_sha256 = referenceIdentityPartsV1("ownership:", label),
            .challenge_sha256 = challenge_sha256,
            .previous_plan_sha256 = previous_plan_sha256,
            .input_schema_sha256 = referenceIdentityPartsV1(
                "input-schema:",
                label,
            ),
            .output_schema_sha256 = referenceIdentityPartsV1(
                "output-schema:",
                label,
            ),
            .scratch_bytes = 4,
        },
    );
}

fn makeReferenceImageV1(
    label: []const u8,
    request_epoch: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    seed_offset: u8,
    previous_plan_sha256: ?Digest,
    previous_result_sha256: ?Digest,
) !ReferenceImageStorageV1 {
    const weights = [_]u8{1};
    const conditioning = [_]u8{ 1, 2, 3, 4 };
    const initial_state = [_]u8{
        10 + seed_offset,
        20 + seed_offset,
        30 + seed_offset,
        40 + seed_offset,
    };
    const manifest = try model.makeArtifactManifestV1(
        .image_generation,
        0x4c41_5445_4e54_0001,
        .latent_tensor,
        .media_chunk,
        .exact_integer,
        1,
        4,
        4,
        1,
        1,
        1,
        &weights,
        referenceIdentityPartsV1(
            "image-model-metadata:",
            label,
        ),
        referenceIdentityPartsV1(
            "image-model-license:",
            label,
        ),
    );
    const state0 = try stateful.initializeStatePublicationV1(
        request_epoch,
        2,
        4,
        manifest.artifact_sha256,
        model.sha256(&initial_state),
        challenge_sha256,
    );
    const implementation_sha256 =
        referenceIdentityV1("stateful-latent-step");
    const descriptor = try stateful.makeAdapterDescriptorV1(
        reference_adapter_abi,
        manifest,
        .diffuse_step,
        0,
        implementation_sha256,
    );
    const model_publication0 =
        try model.initializePublicationStateV1(
            request_epoch,
            manifest.artifact_sha256,
        );
    var first_label_buffer: [64]u8 = undefined;
    const first_label = try std.fmt.bufPrint(
        &first_label_buffer,
        "{s}:first",
        .{label},
    );
    const first_plan = try makeReferenceLatentPlanV1(
        manifest,
        state0,
        request_epoch,
        0,
        referenceIdentityPartsV1("latent-genesis:", label),
        challenge_sha256,
        first_label,
    );
    var callback_context: u8 = 1;
    var first_output: [4]u8 = undefined;
    var first_state: [4]u8 = undefined;
    try latent.referenceExecuteV1(
        &callback_context,
        &first_plan,
        &weights,
        &conditioning,
        &initial_state,
        &first_output,
        &first_state,
    );
    const first_transition = try stateful.stateTransitionRootV1(
        state0,
        first_plan,
        model.sha256(&first_output),
        model.sha256(&first_state),
        descriptor.adapter_sha256,
    );
    const seed_offset_u64: u64 = seed_offset;
    const first_receipt = referenceReceiptV1(
        try checkedAdd(
            730_001,
            try std.math.mul(u64, seed_offset_u64, 10),
        ),
        0,
        1,
        try checkedAdd(
            731_001,
            try std.math.mul(u64, seed_offset_u64, 10),
        ),
        first_plan.claim,
    );
    const first_result = try model.prepareResultEnvelopeV1(
        model_publication0,
        first_plan,
        first_receipt,
        model.sha256(&first_output),
        first_transition,
        descriptor.adapter_sha256,
    );
    const state1 = try referenceStateAfterV1(
        state0,
        first_result,
        &first_state,
    );
    var model_publication1 = model_publication0;
    try model.commitResultV1(
        &model_publication1,
        first_result,
    );
    const restore_bank_epoch = try checkedAdd(
        740_001,
        try std.math.mul(u64, seed_offset_u64, 10),
    );
    const checkpoint = try continuation.makeCheckpointV1(
        first_receipt.bank_epoch,
        .{
            .restore_bank_epoch = restore_bank_epoch,
            .restore_owner_key = try checkedAdd(
                741_001,
                try std.math.mul(
                    u64,
                    seed_offset_u64,
                    10,
                ),
            ),
            .restore_tree_key = try checkedAdd(
                742_001,
                try std.math.mul(
                    u64,
                    seed_offset_u64,
                    10,
                ),
            ),
            .restore_authority_key = try checkedAdd(
                743_001,
                try std.math.mul(
                    u64,
                    seed_offset_u64,
                    10,
                ),
            ),
            .tenant_key = try checkedAdd(
                744_001,
                try std.math.mul(
                    u64,
                    seed_offset_u64,
                    10,
                ),
            ),
            .scope_key = try checkedAdd(
                745_001,
                try std.math.mul(
                    u64,
                    seed_offset_u64,
                    10,
                ),
            ),
            .allocation_key = try checkedAdd(
                746_001,
                try std.math.mul(
                    u64,
                    seed_offset_u64,
                    10,
                ),
            ),
            .binding_key = try checkedAdd(
                747_001,
                try std.math.mul(
                    u64,
                    seed_offset_u64,
                    10,
                ),
            ),
        },
        model_publication1,
        state1,
        first_result,
    );
    var terminal_label_buffer: [64]u8 = undefined;
    const terminal_label = try std.fmt.bufPrint(
        &terminal_label_buffer,
        "{s}:terminal",
        .{label},
    );
    const terminal_plan = try makeReferenceLatentPlanV1(
        manifest,
        state1,
        request_epoch,
        model_publication1.next_sequence,
        checkpoint.last_plan_sha256,
        challenge_sha256,
        terminal_label,
    );
    var terminal_output: [4]u8 = undefined;
    var terminal_state: [4]u8 = undefined;
    try latent.referenceExecuteV1(
        &callback_context,
        &terminal_plan,
        &weights,
        &conditioning,
        &first_state,
        &terminal_output,
        &terminal_state,
    );
    const terminal_transition =
        try stateful.stateTransitionRootV1(
            state1,
            terminal_plan,
            model.sha256(&terminal_output),
            model.sha256(&terminal_state),
            descriptor.adapter_sha256,
        );
    const terminal_receipt = referenceReceiptV1(
        restore_bank_epoch,
        1,
        2,
        try checkedAdd(
            748_001,
            try std.math.mul(u64, seed_offset_u64, 10),
        ),
        terminal_plan.claim,
    );
    const terminal_result = try model.prepareResultEnvelopeV1(
        model_publication1,
        terminal_plan,
        terminal_receipt,
        model.sha256(&terminal_output),
        terminal_transition,
        descriptor.adapter_sha256,
    );
    const state2 = try referenceStateAfterV1(
        state1,
        terminal_result,
        &terminal_state,
    );
    var model_publication2 = model_publication1;
    try model.commitResultV1(
        &model_publication2,
        terminal_result,
    );
    var pixels: [4]u8 = undefined;
    var decoder_context: u8 = 1;
    const decoder = image.referenceDecoderV1(&decoder_context);
    const provisional_source_provenance =
        image.sourceProvenanceRootV1(
            manifest,
            checkpoint,
            terminal_plan,
            terminal_result,
            state2,
            model.sha256(&image.reference_decoder_payload),
            decoder.implementation_sha256,
            tenant_scope_sha256,
            metadata_policy_sha256,
            challenge_sha256,
        );
    for (
        terminal_output,
        image.reference_decoder_payload,
        &pixels,
    ) |latent_value, weight, *pixel| {
        pixel.* = try std.math.mul(u8, latent_value, weight);
    }
    const exact_media_object: media.MediaObjectV1 = .{
        .kind = .image,
        .semantic_abi = image.raw_image_semantic_abi,
        .byte_length = pixels.len,
        .container_id = image.raw_container_id,
        .codec_id = image.interleaved_u8_codec_id,
        .axes = .{ 2, 2, 1 },
        .time_base = .{ .numerator = 0, .denominator = 1 },
        .tenant_scope_sha256 = tenant_scope_sha256,
        .content_sha256 = model.sha256(&pixels),
        .metadata_policy_sha256 = metadata_policy_sha256,
        .provenance_sha256 = provisional_source_provenance,
    };
    var provisional_media_wire: [media.descriptor_bytes]u8 =
        undefined;
    _ = try media.encodeMediaObjectV1(
        exact_media_object,
        &provisional_media_wire,
    );
    const media_root =
        try media.mediaObjectSha256V1(&provisional_media_wire);
    const publication_before =
        try media.initializePublicationStateV1(
            request_epoch,
            1,
            .{ .numerator = 1, .denominator = 1 },
            media_root,
            referenceIdentityPartsV1(
                "image-publication-genesis:",
                label,
            ),
        );
    const producer_plan = try image.makeGeneratedImagePlanV1(
        manifest,
        checkpoint,
        terminal_plan,
        terminal_result,
        state2,
        exact_media_object,
        &image.reference_decoder_payload,
        decoder,
        publication_before,
        previous_plan_sha256 orelse
            referenceIdentityPartsV1(
                "image-producer-plan-genesis:",
                label,
            ),
        previous_result_sha256 orelse
            referenceIdentityPartsV1(
                "image-producer-result-genesis:",
                label,
            ),
    );
    const provenance =
        try image.makeGeneratedImageProvenanceV1(
            producer_plan,
            model.sha256(&pixels),
        );
    const producer_receipt = referenceReceiptV1(
        try checkedAdd(
            750_001,
            try std.math.mul(u64, seed_offset_u64, 10),
        ),
        0,
        3,
        try checkedAdd(
            751_001,
            try std.math.mul(u64, seed_offset_u64, 10),
        ),
        try image.claimForPlanV1(
            producer_plan,
            image.reference_decoder_payload.len,
        ),
    );
    const event = try image.timelineEventForPlanV1(
        producer_plan,
        publication_before,
    );
    const resource_root = image.resourceReceiptRootV1(
        producer_receipt,
        producer_plan.request_epoch,
        producer_plan.plan_sha256,
        producer_plan.decoder_implementation_sha256,
    );
    const prepared_publication =
        try media.preparePublicationV1(
            publication_before,
            event,
            provenance.output_sha256,
            resource_root,
        );
    var publication_after = publication_before;
    try media.commitPublicationV1(
        &publication_after,
        prepared_publication,
    );
    const producer_result =
        try image.makeGeneratedImageResultV1(
            producer_plan,
            provenance,
            exact_media_object,
            producer_receipt,
            publication_before,
            event,
            prepared_publication,
            publication_after,
        );
    var model_storage: ReferenceModelStorageV1 = .{
        .kind = .stateful,
        .manifest = manifest,
        .plan = terminal_plan,
        .result = terminal_result,
        .publication_before = model_publication1,
        .publication_after = model_publication2,
        .state_publication_before = state1,
        .state_publication_after = state2,
        .checkpoint_before = checkpoint,
        .descriptor = descriptor,
        .support = referenceSupportV1(descriptor),
        .weights_len = weights.len,
        .input_len = conditioning.len,
        .state_before_len = first_state.len,
        .output_len = terminal_output.len,
        .state_after_len = terminal_state.len,
    };
    @memcpy(model_storage.weights[0..weights.len], &weights);
    @memcpy(
        model_storage.input[0..conditioning.len],
        &conditioning,
    );
    @memcpy(
        model_storage.state_before[0..first_state.len],
        &first_state,
    );
    @memcpy(
        model_storage.output[0..terminal_output.len],
        &terminal_output,
    );
    @memcpy(
        model_storage.state_after[0..terminal_state.len],
        &terminal_state,
    );
    try sealReferenceModelStorageV1(
        &model_storage,
        first_result,
    );
    var storage: ReferenceImageStorageV1 = .{
        .model_storage = model_storage,
        .producer_plan = producer_plan,
        .producer_result = producer_result,
        .raw_output = pixels,
        .delivery = try makeReferenceDeliveryV1(
            label,
            &pixels,
        ),
    };
    _ = try encodeMediaPublicationV1(
        publication_before,
        &storage.publication_before_wire,
    );
    _ = try encodeMediaPublicationV1(
        publication_after,
        &storage.publication_after_wire,
    );
    _ = try image.encodeGeneratedImagePlanV1(
        producer_plan,
        &storage.plan_wire,
    );
    _ = try image.encodeGeneratedImageProvenanceV1(
        provenance,
        &storage.provenance_wire,
    );
    _ = try image.encodeGeneratedImageResultV1(
        producer_result,
        &storage.result_wire,
    );
    _ = try media.encodeMediaObjectV1(
        exact_media_object,
        &storage.media_object_wire,
    );
    _ = try encodeResourceReceiptEvidenceV1(
        producer_receipt,
        &storage.resource_receipt_wire,
    );
    return storage;
}

fn makeReferenceAudioV1(
    label: []const u8,
    request_epoch: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    model_input: [2]u8,
    previous: ?*const ReferenceAudioStorageV1,
) !ReferenceAudioStorageV1 {
    var model_storage = try makeReferenceStatelessModelV1(
        "audio-model",
        .audio_generation,
        request_epoch,
        challenge_sha256,
        model_input,
        if (previous) |prior|
            &prior.model_storage
        else
            null,
    );
    const before = if (previous) |prior|
        prior.final_state
    else
        try audio.makeInitialStateV1(
            request_epoch,
            16_000,
            1,
            model_storage.manifest.artifact_sha256,
            tenant_scope_sha256,
            metadata_policy_sha256,
            challenge_sha256,
        );
    var renderer_context: u8 = 1;
    const renderer = audio.referenceRendererV1(
        &renderer_context,
    );
    var raw_output: [4]u8 = undefined;
    try audio.renderReferencePcmV1(
        model_storage.output[0..model_storage.output_len],
        &raw_output,
    );
    const media_object = try audio.makeAudioMediaObjectV1(
        before,
        model_storage.output_len,
        model.sha256(&raw_output),
        model_storage.result.result_sha256,
        model.sha256(
            model_storage.output[0..model_storage.output_len],
        ),
        renderer.implementation_sha256,
    );
    var media_object_wire: [media.descriptor_bytes]u8 =
        undefined;
    _ = try media.encodeMediaObjectV1(
        media_object,
        &media_object_wire,
    );
    const media_root =
        try media.mediaObjectSha256V1(&media_object_wire);
    const plan = try audio.makePlanV1(
        before,
        model_storage.output_len,
        model_storage.output_len,
        audio.maximum_pcm_bytes,
        0,
        renderer.renderer_abi,
        model_storage.result.result_sha256,
        model.sha256(
            model_storage.output[0..model_storage.output_len],
        ),
        model.sha256(audio.reference_renderer_payload),
        renderer.implementation_sha256,
        media_root,
    );
    const receipt = referenceReceiptV1(
        760_001,
        std.math.cast(
            u32,
            plan.chunk_index,
        ) orelse return Error.ArithmeticOverflow,
        plan.generation,
        try checkedAdd(761_001, plan.chunk_index),
        try audio.claimForPlanV1(
            plan,
            audio.reference_renderer_payload.len,
        ),
    );
    const provenance = try audio.makeProvenanceV1(
        plan,
        model.sha256(&raw_output),
    );
    const result = try audio.makeResultV1(
        plan,
        provenance,
        receipt,
    );
    const after_publication =
        try audio.stateAfterPublicationV1(
            before,
            plan,
            result,
        );
    const observation =
        try audio.makePlaybackObservationV1(
            after_publication,
            referenceIdentityV1("audio-sink"),
            referenceIdentityV1("audio-sink-instance"),
        );
    const acknowledgement_plan =
        try audio.makePlaybackAckPlanV1(
            after_publication,
            result,
            observation,
        );
    var final_state = after_publication;
    const acknowledgement_result =
        try audio.acknowledgePlaybackV1(
            &final_state,
            result,
            observation,
            acknowledgement_plan,
        );
    var storage: ReferenceAudioStorageV1 = .{
        .model_storage = model_storage,
        .final_state = final_state,
        .raw_output = raw_output,
        .delivery = try makeReferenceDeliveryV1(
            label,
            &raw_output,
        ),
    };
    _ = try audio.encodeStateV1(
        before,
        &storage.state_before_wire,
    );
    _ = try audio.encodeStateV1(
        after_publication,
        &storage.state_after_publication_wire,
    );
    _ = try audio.encodeStateV1(
        final_state,
        &storage.state_after_completion_wire,
    );
    _ = try audio.encodePlanV1(plan, &storage.plan_wire);
    _ = try audio.encodeProvenanceV1(
        provenance,
        &storage.provenance_wire,
    );
    _ = try audio.encodeResultV1(
        result,
        &storage.result_wire,
    );
    _ = try audio.encodePlaybackObservationV1(
        observation,
        &storage.observation_wire,
    );
    _ = try audio.encodePlaybackAckPlanV1(
        acknowledgement_plan,
        &storage.acknowledgement_plan_wire,
    );
    _ = try audio.encodePlaybackAckResultV1(
        acknowledgement_result,
        &storage.acknowledgement_result_wire,
    );
    @memcpy(&storage.media_object_wire, &media_object_wire);
    _ = try encodeResourceReceiptEvidenceV1(
        receipt,
        &storage.resource_receipt_wire,
    );
    return storage;
}

fn makeReferenceVideoV1(
    label: []const u8,
    request_epoch: u64,
    tenant_scope_sha256: Digest,
    metadata_policy_sha256: Digest,
    challenge_sha256: Digest,
    model_input: [2]u8,
    previous: ?*const ReferenceVideoStorageV1,
) !ReferenceVideoStorageV1 {
    var model_storage = try makeReferenceStatelessModelV1(
        "video-model",
        .video_generation,
        request_epoch,
        challenge_sha256,
        model_input,
        if (previous) |prior|
            &prior.model_storage
        else
            null,
    );
    const before = if (previous) |prior|
        prior.final_state
    else
        try video.initializeStateV1(
            request_epoch,
            2,
            2,
            1,
            model_storage.manifest.artifact_sha256,
            tenant_scope_sha256,
            metadata_policy_sha256,
            challenge_sha256,
        );
    var renderer_context: u8 = 1;
    const renderer = video.referenceRendererV1(
        &renderer_context,
    );
    const source =
        model_storage.output[0..model_storage.output_len];
    var raw_output: [8]u8 = undefined;
    @memset(raw_output[0..4], source[0]);
    @memset(raw_output[4..8], source[1]);
    const first_duration = try checkedAdd(
        2,
        before.next_segment_index,
    );
    const second_duration = try checkedAdd(
        3,
        before.next_segment_index,
    );
    const first_root = model.sha256(raw_output[0..4]);
    const second_root = model.sha256(raw_output[4..8]);
    const provisional_manifest = try video.makeManifestV1(
        before,
        first_duration,
        second_duration,
        source.len,
        raw_output.len,
        0,
        renderer.renderer_abi,
        model_storage.result.result_sha256,
        model.sha256(source),
        model.sha256(video.reference_renderer_payload),
        renderer.implementation_sha256,
        referenceIdentityV1("video-media-placeholder"),
        first_root,
        second_root,
    );
    const media_object: media.MediaObjectV1 = .{
        .kind = .video,
        .semantic_abi = video.raw_video_semantic_abi,
        .byte_length = raw_output.len,
        .container_id = video.raw_container_id,
        .codec_id = video.gray8_frame_codec_id,
        .axes = .{ 2, 2, 2 },
        .time_base = .{ .numerator = 1, .denominator = 1_000 },
        .tenant_scope_sha256 = tenant_scope_sha256,
        .content_sha256 = model.sha256(&raw_output),
        .metadata_policy_sha256 = metadata_policy_sha256,
        .provenance_sha256 = video.sourceProvenanceRootV1(
            provisional_manifest,
        ),
    };
    var media_object_wire: [media.descriptor_bytes]u8 =
        undefined;
    _ = try media.encodeMediaObjectV1(
        media_object,
        &media_object_wire,
    );
    const media_root =
        try media.mediaObjectSha256V1(&media_object_wire);
    const manifest = try video.makeManifestV1(
        before,
        first_duration,
        second_duration,
        source.len,
        raw_output.len,
        0,
        renderer.renderer_abi,
        model_storage.result.result_sha256,
        model.sha256(source),
        model.sha256(video.reference_renderer_payload),
        renderer.implementation_sha256,
        media_root,
        first_root,
        second_root,
    );
    const receipt = referenceReceiptV1(
        770_001,
        std.math.cast(
            u32,
            manifest.segment_index,
        ) orelse return Error.ArithmeticOverflow,
        manifest.generation,
        try checkedAdd(
            771_001,
            manifest.segment_index,
        ),
        try video.claimForManifestV1(
            manifest,
            video.reference_renderer_payload.len,
        ),
    );
    const provenance = try video.makeProvenanceV1(
        manifest,
        model.sha256(&raw_output),
    );
    const result = try video.makeResultV1(
        manifest,
        provenance,
        receipt,
    );
    const after_publication =
        try video.stateAfterPublicationV1(
            before,
            manifest,
            result,
        );
    const observation =
        try video.makeDisplayObservationV1(
            after_publication,
            referenceIdentityV1("video-sink"),
            referenceIdentityV1("video-sink-instance"),
        );
    const acknowledgement_plan =
        try video.makeDisplayAckPlanV1(
            after_publication,
            result,
            observation,
        );
    var final_state = after_publication;
    const acknowledgement_result =
        try video.acknowledgeDisplayV1(
            &final_state,
            result,
            observation,
            acknowledgement_plan,
        );
    var storage: ReferenceVideoStorageV1 = .{
        .model_storage = model_storage,
        .final_state = final_state,
        .raw_output = raw_output,
        .delivery = try makeReferenceDeliveryV1(
            label,
            &raw_output,
        ),
    };
    _ = try video.encodeStateV1(
        before,
        &storage.state_before_wire,
    );
    _ = try video.encodeStateV1(
        after_publication,
        &storage.state_after_publication_wire,
    );
    _ = try video.encodeStateV1(
        final_state,
        &storage.state_after_completion_wire,
    );
    _ = try video.encodeManifestV1(
        manifest,
        &storage.manifest_wire,
    );
    _ = try video.encodeProvenanceV1(
        provenance,
        &storage.provenance_wire,
    );
    _ = try video.encodeResultV1(
        result,
        &storage.result_wire,
    );
    _ = try video.encodeDisplayObservationV1(
        observation,
        &storage.observation_wire,
    );
    _ = try video.encodeDisplayAckPlanV1(
        acknowledgement_plan,
        &storage.acknowledgement_plan_wire,
    );
    _ = try video.encodeDisplayAckResultV1(
        acknowledgement_result,
        &storage.acknowledgement_result_wire,
    );
    @memcpy(&storage.media_object_wire, &media_object_wire);
    _ = try encodeResourceReceiptEvidenceV1(
        receipt,
        &storage.resource_receipt_wire,
    );
    return storage;
}
