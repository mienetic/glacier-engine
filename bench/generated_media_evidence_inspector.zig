//! Experimental read-only inspector for generated-media registry/evidence pairs.
//!
//! The command validates every supplied byte before writing semantic output.
//! It renders identities, bounds, and lineage only; encoded payload bytes are
//! never copied to stdout and no model or materializer callback is invoked.

const std = @import("std");
const core = @import("core");

const checkpoint_file = core.continuation_checkpoint_file;
const registry = core.generated_media_output_registry;
const transition = core.generated_media_producer_transition;

pub const max_archive_bytes: usize = 16 * 1024 * 1024;
pub const max_evidence_bytes: usize =
    transition.batch_header_bytes +
    registry.max_entries * transition.transition_receipt_bytes;

const schema = "glacier-generated-media-evidence-inspector-v1";

const Options = struct {
    archive_path: []const u8,
    evidence_path: []const u8,
    previous_archive_path: ?[]const u8,
    previous_evidence_path: ?[]const u8,
};

const RenderEntryV1 = struct {
    receipt: transition.TransitionReceiptV1,
    encoding_abi: u64,
    payload_offset: u64,
};

const RenderDocumentV1 = struct {
    successor: bool,
    archive_bytes: usize,
    evidence_bytes: usize,
    manifest: registry.GeneratedMediaOutputRegistryManifestV1,
    batch: transition.BatchEvidenceV1,
    entries: [registry.max_entries]RenderEntryV1,
    entry_count: usize,
};

pub fn main() void {
    run() catch |err| {
        const stderr = std.fs.File.stderr();
        var buffer: [512]u8 = undefined;
        var writer = std.fs.File.Writer.init(stderr, &buffer);
        writer.interface.print(
            "generated-media-evidence-inspector: {s}\n",
            .{@errorName(err)},
        ) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    const options = try parseOptions(arguments);

    const archive = try readBoundedFile(
        allocator,
        options.archive_path,
        max_archive_bytes,
    );
    defer allocator.free(archive);
    const evidence = try readBoundedFile(
        allocator,
        options.evidence_path,
        max_evidence_bytes,
    );
    defer allocator.free(evidence);

    const evidence_shape =
        try transition.decodeBatchEvidenceV1(evidence);
    const successor =
        evidence_shape.batch.registry_generation > 1;
    const has_predecessor =
        options.previous_archive_path != null;
    if (successor and !has_predecessor)
        return error.MissingPredecessor;
    if (!successor and has_predecessor)
        return error.UnexpectedPredecessor;

    var current_archive: registry.DecodedArchiveV1 = undefined;
    var validated_evidence: transition.DecodedBatchEvidenceV1 = undefined;

    if (successor) {
        const previous_archive_path =
            options.previous_archive_path orelse
            return error.MissingPredecessor;
        const previous_evidence_path =
            options.previous_evidence_path orelse
            return error.MissingPredecessor;
        const previous_archive = try readBoundedFile(
            allocator,
            previous_archive_path,
            max_archive_bytes,
        );
        defer allocator.free(previous_archive);
        const previous_evidence = try readBoundedFile(
            allocator,
            previous_evidence_path,
            max_evidence_bytes,
        );
        defer allocator.free(previous_evidence);

        const trusted_predecessor =
            try decodeTrustedArchiveViewV1(previous_archive);
        current_archive = try registry.decodeArchiveV1(
            archive,
            trusted_predecessor.previous(),
        );
        validated_evidence =
            try transition.validateSuccessorArchiveAndEvidenceV1(
                .{
                    .registry_archive = current_archive,
                    .evidence = evidence,
                },
                .{
                    .registry_archive = trusted_predecessor,
                    .evidence = previous_evidence,
                },
            );
    } else {
        current_archive = try registry.decodeArchiveV1(
            archive,
            null,
        );
        validated_evidence =
            try transition.validateArchiveAndEvidenceV1(.{
                .registry_archive = current_archive,
                .evidence = evidence,
            });
    }

    const document = try collectDocumentV1(
        successor,
        current_archive,
        validated_evidence,
    );

    const stdout = std.fs.File.stdout();
    var output_buffer: [4096]u8 = undefined;
    var output = std.fs.File.Writer.init(
        stdout,
        &output_buffer,
    );
    try renderDocumentV1(&output.interface, document);
    try output.interface.flush();
}

fn parseOptions(arguments: []const []const u8) !Options {
    var archive_path: ?[]const u8 = null;
    var evidence_path: ?[]const u8 = null;
    var previous_archive_path: ?[]const u8 = null;
    var previous_evidence_path: ?[]const u8 = null;

    var index: usize = 1;
    while (index < arguments.len) {
        const flag = arguments[index];
        index += 1;
        if (index >= arguments.len)
            return error.InvalidArguments;
        const value = arguments[index];
        index += 1;
        if (std.mem.eql(u8, flag, "--archive")) {
            try setOption(&archive_path, value);
        } else if (std.mem.eql(u8, flag, "--evidence")) {
            try setOption(&evidence_path, value);
        } else if (std.mem.eql(
            u8,
            flag,
            "--previous-archive",
        )) {
            try setOption(&previous_archive_path, value);
        } else if (std.mem.eql(
            u8,
            flag,
            "--previous-evidence",
        )) {
            try setOption(&previous_evidence_path, value);
        } else {
            return error.InvalidArguments;
        }
    }
    if ((previous_archive_path == null) !=
        (previous_evidence_path == null))
        return error.IncompletePredecessor;
    return .{
        .archive_path = archive_path orelse
            return error.InvalidArguments,
        .evidence_path = evidence_path orelse
            return error.InvalidArguments,
        .previous_archive_path = previous_archive_path,
        .previous_evidence_path = previous_evidence_path,
    };
}

fn setOption(
    slot: *?[]const u8,
    value: []const u8,
) !void {
    if (slot.* != null or value.len == 0)
        return error.InvalidArguments;
    slot.* = value;
}

fn readBoundedFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    ceiling: usize,
) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const before = try file.stat();
    if (before.kind != .file) return error.InvalidInputKind;
    if (before.size == 0) return error.EmptyInput;
    const length = std.math.cast(
        usize,
        before.size,
    ) orelse return error.InputTooLarge;
    if (length > ceiling) return error.InputTooLarge;

    const bytes = try allocator.alloc(u8, length);
    errdefer allocator.free(bytes);
    if (try file.readAll(bytes) != bytes.len)
        return error.InputChanged;
    var probe: [1]u8 = undefined;
    if (try file.pread(&probe, before.size) != 0)
        return error.InputChanged;
    const after = try file.stat();
    if (after.kind != .file or after.size != before.size)
        return error.InputChanged;
    return bytes;
}

/// Build a read-only view for the caller-designated trust anchor.
///
/// The public exact successor validator revalidates this backing archive,
/// binds its evidence, and then checks the current pair against it. Its own
/// predecessor is deliberately outside this one-hop inspector contract.
fn decodeTrustedArchiveViewV1(
    encoded: []const u8,
) !registry.DecodedArchiveV1 {
    var set = try checkpoint_file.decodeSetV1(encoded);
    if (set.object_count != registry.archive_object_count)
        return error.InvalidPredecessorArchive;
    const manifest_object = try set.object(
        .extension,
        registry.manifest_object_ordinal,
    );
    const entry_table_object = try set.object(
        .extension,
        registry.entry_table_object_ordinal,
    );
    const payload_pack_object = try set.object(
        .extension,
        registry.payload_pack_object_ordinal,
    );
    if (manifest_object.abi_version != registry.manifest_abi or
        entry_table_object.abi_version !=
            registry.entry_table_abi or
        payload_pack_object.abi_version !=
            registry.payload_pack_abi)
        return error.InvalidPredecessorArchive;
    return .{
        .archive_bytes = encoded,
        .archive_sha256 = set.checkpoint_sha256,
        .manifest = try registry.decodeManifestV1(
            manifest_object.bytes,
        ),
        .entry_table = entry_table_object.bytes,
        .payload_pack = payload_pack_object.bytes,
    };
}

fn collectDocumentV1(
    successor: bool,
    archive: registry.DecodedArchiveV1,
    evidence: transition.DecodedBatchEvidenceV1,
) !RenderDocumentV1 {
    const count = std.math.cast(
        usize,
        evidence.batch.receipt_count,
    ) orelse return error.InvalidEntryCount;
    if (count == 0 or count > registry.max_entries)
        return error.InvalidEntryCount;
    var document: RenderDocumentV1 = .{
        .successor = successor,
        .archive_bytes = archive.archive_bytes.len,
        .evidence_bytes = evidence.encoded.len,
        .manifest = archive.manifest,
        .batch = evidence.batch,
        .entries = undefined,
        .entry_count = count,
    };
    for (0..count) |index| {
        const receipt = try evidence.receipt(index);
        const entry = try archive.entry(index);
        document.entries[index] = .{
            .receipt = receipt,
            .encoding_abi = entry.encoding_abi,
            .payload_offset = entry.payload_offset,
        };
    }
    return document;
}

fn renderDocumentV1(
    writer: *std.Io.Writer,
    document: RenderDocumentV1,
) !void {
    const batch = document.batch;
    try writer.print(
        "{{\"schema\":\"{s}\",\"verified\":true," ++
            "\"lineage\":\"{s}\",\"request_epoch\":{d}," ++
            "\"registry_generation\":{d}," ++
            "\"publication_sequence\":{d}," ++
            "\"modality_mask\":{d},\"receipt_count\":{d}," ++
            "\"receipt_table_bytes\":{d}," ++
            "\"registry_archive_bytes\":{d}," ++
            "\"evidence_bytes\":{d}",
        .{
            schema,
            if (document.successor) "successor" else "genesis",
            batch.request_epoch,
            batch.registry_generation,
            batch.publication_sequence,
            batch.modality_mask,
            batch.receipt_count,
            batch.receipt_table_bytes,
            document.archive_bytes,
            document.evidence_bytes,
        },
    );
    try writeDigestField(
        writer,
        "generation_plan_sha256",
        batch.generation_plan_sha256,
    );
    try writeDigestField(
        writer,
        "tenant_scope_sha256",
        batch.tenant_scope_sha256,
    );
    try writeDigestField(
        writer,
        "metadata_policy_sha256",
        batch.metadata_policy_sha256,
    );
    try writeDigestField(
        writer,
        "challenge_sha256",
        batch.challenge_sha256,
    );
    try writeDigestField(
        writer,
        "receipt_table_sha256",
        batch.receipt_table_sha256,
    );
    try writeDigestField(
        writer,
        "previous_batch_sha256",
        batch.previous_batch_sha256,
    );
    try writeDigestField(
        writer,
        "registry_manifest_sha256",
        batch.registry_manifest_sha256,
    );
    try writeDigestField(
        writer,
        "registry_archive_sha256",
        batch.registry_archive_sha256,
    );
    try writeDigestField(
        writer,
        "batch_sha256",
        batch.batch_sha256,
    );
    try writer.writeAll(",\"entries\":[");
    for (document.entries[0..document.entry_count], 0..) |
        entry,
        index,
    | {
        if (index != 0) try writer.writeByte(',');
        try renderEntryV1(writer, index, entry);
    }
    try writer.writeAll("]}\n");
}

fn renderEntryV1(
    writer: *std.Io.Writer,
    index: usize,
    entry: RenderEntryV1,
) !void {
    const receipt = entry.receipt;
    try writer.print(
        "{{\"index\":{d},\"modality\":\"{s}\"," ++
            "\"model_kind\":\"{s}\"," ++
            "\"completion_kind\":\"{s}\"," ++
            "\"producer_generation\":{d}," ++
            "\"producer_ordinal\":{d}," ++
            "\"registry_ordinal\":{d}," ++
            "\"unit_start\":{d},\"unit_count\":{d}," ++
            "\"timeline_start\":{d},\"timeline_end\":{d}," ++
            "\"weights_bytes\":{d}," ++
            "\"model_input_bytes\":{d}," ++
            "\"model_state_before_bytes\":{d}," ++
            "\"model_output_bytes\":{d}," ++
            "\"model_state_after_bytes\":{d}," ++
            "\"materializer_payload_bytes\":{d}," ++
            "\"raw_output_bytes\":{d}," ++
            "\"encoded_payload_bytes\":{d}," ++
            "\"encoding_abi\":{d},\"payload_offset\":{d}," ++
            "\"producer_publication_sequence\":{d}," ++
            "\"completion_sequence\":{d}",
        .{
            index,
            modalityName(receipt.modality),
            modelKindName(receipt.model_kind),
            completionKindName(receipt.completion_kind),
            receipt.producer_generation,
            receipt.producer_ordinal,
            receipt.registry_ordinal,
            receipt.unit_start,
            receipt.unit_count,
            receipt.timeline_start,
            receipt.timeline_end,
            receipt.weights_bytes,
            receipt.model_input_bytes,
            receipt.model_state_before_bytes,
            receipt.model_output_bytes,
            receipt.model_state_after_bytes,
            receipt.materializer_payload_bytes,
            receipt.raw_output_bytes,
            receipt.encoded_payload_bytes,
            entry.encoding_abi,
            entry.payload_offset,
            receipt.producer_publication_sequence,
            receipt.completion_sequence,
        },
    );
    inline for (.{
        .{
            "artifact_manifest_sha256",
            receipt.artifact_manifest_sha256,
        },
        .{
            "adapter_descriptor_sha256",
            receipt.adapter_descriptor_sha256,
        },
        .{
            "support_set_sha256",
            receipt.support_set_sha256,
        },
        .{
            "model_plan_sha256",
            receipt.model_plan_sha256,
        },
        .{
            "model_output_sha256",
            receipt.model_output_sha256,
        },
        .{
            "model_transition_or_source_mapping_sha256",
            receipt.model_transition_or_source_mapping_sha256,
        },
        .{
            "model_result_sha256",
            receipt.model_result_sha256,
        },
        .{
            "producer_plan_or_manifest_sha256",
            receipt.producer_plan_or_manifest_sha256,
        },
        .{
            "media_object_sha256",
            receipt.media_object_sha256,
        },
        .{
            "materializer_implementation_sha256",
            receipt.materializer_implementation_sha256,
        },
        .{
            "materializer_execution_sha256",
            receipt.materializer_execution_sha256,
        },
        .{
            "raw_output_sha256",
            receipt.raw_output_sha256,
        },
        .{
            "provenance_sha256",
            receipt.provenance_sha256,
        },
        .{
            "publication_result_sha256",
            receipt.publication_result_sha256,
        },
        .{
            "producer_final_state_sha256",
            receipt.producer_final_state_sha256,
        },
        .{
            "completion_result_sha256",
            receipt.completion_result_sha256,
        },
        .{
            "encoder_implementation_sha256",
            receipt.encoder_implementation_sha256,
        },
        .{
            "format_sha256",
            receipt.format_sha256,
        },
        .{
            "encoded_payload_sha256",
            receipt.encoded_payload_sha256,
        },
        .{
            "previous_transition_receipt_sha256",
            receipt.previous_transition_receipt_sha256,
        },
        .{
            "producer_projection_sha256",
            receipt.producer_projection_sha256,
        },
        .{
            "registry_previous_entry_sha256",
            receipt.registry_previous_entry_sha256,
        },
        .{
            "registry_entry_sha256",
            receipt.registry_entry_sha256,
        },
        .{
            "transition_receipt_sha256",
            receipt.receipt_sha256,
        },
    }) |field| {
        try writeDigestField(writer, field[0], field[1]);
    }
    try writer.writeByte('}');
}

fn writeDigestField(
    writer: *std.Io.Writer,
    name: []const u8,
    digest: transition.Digest,
) !void {
    const encoded = std.fmt.bytesToHex(digest, .lower);
    try writer.print(",\"{s}\":\"", .{name});
    try writer.writeAll(&encoded);
    try writer.writeByte('"');
}

fn modalityName(value: registry.ModalityV1) []const u8 {
    return switch (value) {
        .image => "image",
        .audio => "audio",
        .video => "video",
    };
}

fn modelKindName(value: transition.ModelKindV1) []const u8 {
    return switch (value) {
        .stateless => "stateless",
        .stateful => "stateful",
    };
}

fn completionKindName(
    value: transition.CompletionKindV1,
) []const u8 {
    return switch (value) {
        .none => "none",
        .playback => "playback",
        .display => "display",
    };
}
