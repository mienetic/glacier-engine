//! Crash-atomic archive objects for one image/audio/video stream generation.
//!
//! Three fixed stream checkpoints and one canonical retained-output bundle fit
//! inside the generic immutable checkpoint archive. The generic selector can
//! therefore switch the entire multimodal generation with one atomic rename.

const std = @import("std");
const media = @import("media_contract.zig");
const continuation = @import("media_stream_continuation.zig");
const checkpoint_file = @import("continuation_checkpoint_file.zig");

pub const Digest = [32]u8;
pub const bundle_abi: u64 = 0x474d_5342_0000_0001;
pub const bundle_magic =
    [_]u8{ 'G', 'M', 'S', 'B', 'N', 'D', '1', 0 };
pub const stream_count: usize = 3;
pub const maximum_outputs =
    stream_count * continuation.maximum_retained_outputs;
pub const bundle_header_bytes: usize = 192;
pub const bundle_entry_bytes: usize = 96;
pub const bundle_directory_bytes: usize =
    maximum_outputs * bundle_entry_bytes;
pub const bundle_payload_offset: usize =
    bundle_header_bytes + bundle_directory_bytes;
pub const bundle_footer_bytes: usize = 32;
pub const archive_object_count: usize = stream_count + 1;
pub const checkpoint_object_abi =
    continuation.checkpoint_abi;
pub const bundle_object_abi = bundle_abi;
pub const allowed_flags: u64 = 0;

const bundle_domain =
    "glacier-media-stream-output-bundle-v1\x00";
const checkpoint_object_ordinal_base: u64 = 0;
const bundle_object_ordinal: u64 = stream_count;

comptime {
    if (archive_object_count >
        checkpoint_file.max_objects)
        @compileError("media checkpoint set exceeds archive directory");
}

pub const Error = checkpoint_file.Error ||
    continuation.Error || error{
    InvalidBundle,
    InvalidMediaCheckpointSet,
    InvalidSuccessor,
};

pub const BundleOutputInputV1 = struct {
    chunk_index: u64,
    output: []const u8,
    output_sha256: Digest,
    chunk_receipt_sha256: Digest,
};

pub const BundleStreamInputV1 = struct {
    kind: media.MediaKindV1,
    checkpoint_sha256: Digest,
    outputs: []const BundleOutputInputV1,
};

pub const BundlePlanV1 = struct {
    generation: u64,
    request_epoch: u64,
    challenge_sha256: Digest,
};

pub const OutputViewV1 = struct {
    kind: media.MediaKindV1 = .image,
    chunk_index: u64 = 0,
    output: []const u8 = "",
    output_sha256: Digest = [_]u8{0} ** 32,
    chunk_receipt_sha256: Digest = [_]u8{0} ** 32,
};

pub const DecodedBundleV1 = struct {
    generation: u64,
    request_epoch: u64,
    challenge_sha256: Digest,
    checkpoint_sha256: [stream_count]Digest,
    outputs: [maximum_outputs]OutputViewV1,
    output_count: usize,
    bundle_sha256: Digest,

    pub fn output(
        self: *const DecodedBundleV1,
        kind: media.MediaKindV1,
        chunk_index: u64,
    ) Error!OutputViewV1 {
        for (self.outputs[0..self.output_count]) |entry| {
            if (entry.kind == kind and
                entry.chunk_index == chunk_index)
                return entry;
        }
        return Error.InvalidBundle;
    }
};

pub const StreamInputV1 = struct {
    checkpoint: continuation.CheckpointV1,
    retained_outputs: []const []const u8,
};

pub const PreparedSetV1 = struct {
    archive: checkpoint_file.PreparedSetV1,
};

pub const DecodedSetV1 = struct {
    archive: checkpoint_file.DecodedSetV1,
    checkpoints: [stream_count]continuation.CheckpointV1,
    bundle: DecodedBundleV1,

    pub fn retainedOutput(
        self: *const DecodedSetV1,
        stream_index: usize,
        chunk_index: usize,
    ) Error![]const u8 {
        if (stream_index >= stream_count)
            return Error.InvalidMediaCheckpointSet;
        const checkpoint = self.checkpoints[stream_index];
        if (chunk_index >=
            checkpoint.retained_output_count)
            return Error.InvalidMediaCheckpointSet;
        return (try self.bundle.output(
            checkpoint.kind,
            @intCast(chunk_index),
        )).output;
    }
};

pub fn encodeRetainedBundleV1(
    plan: BundlePlanV1,
    streams: [stream_count]BundleStreamInputV1,
    destination: []u8,
) Error![]const u8 {
    if (plan.generation == 0 or
        plan.request_epoch == 0 or
        isZero(plan.challenge_sha256))
        return Error.InvalidBundle;

    var output_count: usize = 0;
    var total = bundle_payload_offset +
        bundle_footer_bytes;
    for (streams, 0..) |stream, stream_index| {
        if (stream.kind != mediaKindForIndex(stream_index) or
            isZero(stream.checkpoint_sha256) or
            stream.outputs.len == 0 or
            stream.outputs.len >
                continuation.maximum_retained_outputs)
            return Error.InvalidBundle;
        output_count = std.math.add(
            usize,
            output_count,
            stream.outputs.len,
        ) catch return Error.ArithmeticOverflow;
        for (stream.outputs, 0..) |entry, chunk_index| {
            if (entry.chunk_index != chunk_index or
                entry.output.len == 0 or
                isZero(entry.output_sha256) or
                isZero(entry.chunk_receipt_sha256) or
                !std.mem.eql(
                    u8,
                    &sha256(entry.output),
                    &entry.output_sha256,
                ))
                return Error.InvalidBundle;
            total = std.math.add(
                usize,
                total,
                entry.output.len,
            ) catch return Error.ArithmeticOverflow;
        }
    }
    if (output_count == 0 or
        output_count > maximum_outputs or
        destination.len < total)
        return Error.BufferTooSmall;

    const output = destination[0..total];
    for (streams) |stream| {
        for (stream.outputs) |entry| {
            if (slicesOverlap(output, entry.output))
                return Error.UnsafeDestination;
        }
    }
    @memset(output, 0);
    @memcpy(output[0..8], &bundle_magic);
    writeU64(output, 8, bundle_abi);
    writeU64(output, 16, total);
    writeU64(output, 24, plan.generation);
    writeU64(output, 32, plan.request_epoch);
    writeU64(output, 40, stream_count);
    writeU64(output, 48, output_count);
    writeU64(output, 56, allowed_flags);
    @memcpy(output[64..96], &plan.challenge_sha256);
    for (streams, 0..) |stream, index| {
        @memcpy(
            output[96 + index * 32 .. 128 + index * 32],
            &stream.checkpoint_sha256,
        );
    }

    var directory_index: usize = 0;
    var cursor = bundle_payload_offset;
    for (streams) |stream| {
        for (stream.outputs) |entry| {
            const entry_offset = bundle_header_bytes +
                directory_index * bundle_entry_bytes;
            writeU64(
                output,
                entry_offset,
                @intFromEnum(stream.kind),
            );
            writeU64(
                output,
                entry_offset + 8,
                entry.chunk_index,
            );
            writeU64(output, entry_offset + 16, cursor);
            writeU64(
                output,
                entry_offset + 24,
                entry.output.len,
            );
            @memcpy(
                output[entry_offset + 32 .. entry_offset + 64],
                &entry.output_sha256,
            );
            @memcpy(
                output[entry_offset + 64 .. entry_offset + 96],
                &entry.chunk_receipt_sha256,
            );
            const end = cursor + entry.output.len;
            @memcpy(output[cursor..end], entry.output);
            cursor = end;
            directory_index += 1;
        }
    }
    if (directory_index != output_count or
        cursor != output.len - bundle_footer_bytes)
        return Error.InvalidBundle;
    const root = bundleRootV1(
        output[0 .. output.len - bundle_footer_bytes],
    );
    @memcpy(
        output[output.len - bundle_footer_bytes ..],
        &root,
    );
    _ = try decodeRetainedBundleV1(output);
    return output;
}

pub fn decodeRetainedBundleV1(
    encoded: []const u8,
) Error!DecodedBundleV1 {
    if (encoded.len <
        bundle_payload_offset + bundle_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &bundle_magic) or
        readU64(encoded, 8) != bundle_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 40) != stream_count or
        readU64(encoded, 56) != allowed_flags)
        return Error.InvalidBundle;
    const generation = readU64(encoded, 24);
    const request_epoch = readU64(encoded, 32);
    const output_count = std.math.cast(
        usize,
        readU64(encoded, 48),
    ) orelse return Error.InvalidBundle;
    const challenge_sha256: Digest = encoded[64..96].*;
    var stored_root: Digest = undefined;
    @memcpy(
        &stored_root,
        encoded[encoded.len - bundle_footer_bytes ..],
    );
    if (generation == 0 or request_epoch == 0 or
        output_count < stream_count or
        output_count > maximum_outputs or
        isZero(challenge_sha256) or
        !std.mem.eql(
            u8,
            &stored_root,
            &bundleRootV1(
                encoded[0 .. encoded.len - bundle_footer_bytes],
            ),
        ))
        return Error.InvalidBundle;

    var result: DecodedBundleV1 = .{
        .generation = generation,
        .request_epoch = request_epoch,
        .challenge_sha256 = challenge_sha256,
        .checkpoint_sha256 = undefined,
        .outputs = [_]OutputViewV1{.{}} **
            maximum_outputs,
        .output_count = output_count,
        .bundle_sha256 = stored_root,
    };
    for (&result.checkpoint_sha256, 0..) |*root, index| {
        @memcpy(
            root,
            encoded[96 + index * 32 .. 128 + index * 32],
        );
        if (isZero(root.*)) return Error.InvalidBundle;
    }
    const inactive_start = bundle_header_bytes +
        output_count * bundle_entry_bytes;
    if (!std.mem.allEqual(
        u8,
        encoded[inactive_start..bundle_payload_offset],
        0,
    )) return Error.InvalidBundle;

    var cursor = bundle_payload_offset;
    var previous_kind: ?media.MediaKindV1 = null;
    var previous_chunk_index: u64 = 0;
    var seen_streams: usize = 0;
    for (
        result.outputs[0..output_count],
        0..,
    ) |*entry, index| {
        const entry_offset = bundle_header_bytes +
            index * bundle_entry_bytes;
        const kind = std.meta.intToEnum(
            media.MediaKindV1,
            readU64(encoded, entry_offset),
        ) catch return Error.InvalidBundle;
        const chunk_index =
            readU64(encoded, entry_offset + 8);
        const payload_offset = std.math.cast(
            usize,
            readU64(encoded, entry_offset + 16),
        ) orelse return Error.InvalidBundle;
        const payload_bytes = std.math.cast(
            usize,
            readU64(encoded, entry_offset + 24),
        ) orelse return Error.InvalidBundle;
        var output_sha256: Digest = undefined;
        @memcpy(
            &output_sha256,
            encoded[entry_offset + 32 .. entry_offset + 64],
        );
        var chunk_receipt_sha256: Digest = undefined;
        @memcpy(
            &chunk_receipt_sha256,
            encoded[entry_offset + 64 .. entry_offset + 96],
        );
        if (payload_bytes == 0 or payload_offset != cursor or
            isZero(output_sha256) or
            isZero(chunk_receipt_sha256))
            return Error.InvalidBundle;
        const end = std.math.add(
            usize,
            cursor,
            payload_bytes,
        ) catch return Error.InvalidBundle;
        if (end > encoded.len - bundle_footer_bytes)
            return Error.InvalidBundle;
        if (previous_kind) |prior_kind| {
            const prior_value = @intFromEnum(prior_kind);
            const current_value = @intFromEnum(kind);
            if (current_value < prior_value or
                (current_value == prior_value and
                    chunk_index != previous_chunk_index + 1) or
                (current_value > prior_value and
                    (current_value != prior_value + 1 or
                        chunk_index != 0)))
                return Error.InvalidBundle;
            if (current_value > prior_value)
                seen_streams += 1;
        } else {
            if (kind != .image or chunk_index != 0)
                return Error.InvalidBundle;
            seen_streams = 1;
        }
        const payload = encoded[cursor..end];
        if (!std.mem.eql(
            u8,
            &sha256(payload),
            &output_sha256,
        )) return Error.InvalidBundle;
        entry.* = .{
            .kind = kind,
            .chunk_index = chunk_index,
            .output = payload,
            .output_sha256 = output_sha256,
            .chunk_receipt_sha256 = chunk_receipt_sha256,
        };
        previous_kind = kind;
        previous_chunk_index = chunk_index;
        cursor = end;
    }
    if (seen_streams != stream_count or
        previous_kind.? != .video or
        cursor != encoded.len - bundle_footer_bytes)
        return Error.InvalidBundle;
    return result;
}

pub fn encodeSetV1(
    streams: [stream_count]StreamInputV1,
    parent_archive_sha256: Digest,
    bundle_storage: []u8,
    set_storage: []u8,
) Error!PreparedSetV1 {
    var checkpoint_storage: [stream_count][continuation.checkpoint_bytes]u8 =
        undefined;
    var bundle_outputs: [stream_count][continuation.maximum_retained_outputs]BundleOutputInputV1 = undefined;
    var bundle_streams: [stream_count]BundleStreamInputV1 =
        undefined;
    const first = streams[0].checkpoint;
    for (streams, 0..) |stream, stream_index| {
        const checkpoint = stream.checkpoint;
        if (checkpoint.kind !=
            mediaKindForIndex(stream_index) or
            checkpoint.checkpoint_generation !=
                first.checkpoint_generation or
            checkpoint.request_epoch != first.request_epoch or
            checkpoint.next_sequence != first.next_sequence or
            !std.mem.eql(
                u8,
                &checkpoint.challenge_sha256,
                &first.challenge_sha256,
            ))
            return Error.InvalidMediaCheckpointSet;
        for (streams[0..stream_index]) |prior| {
            if (checkpoint.stream_key ==
                prior.checkpoint.stream_key or
                checkpoint.restore_bank_epoch ==
                    prior.checkpoint.restore_bank_epoch)
                return Error.InvalidMediaCheckpointSet;
        }
        _ = try continuation.encodeCheckpointV1(
            checkpoint,
            &checkpoint_storage[stream_index],
        );
        try continuation.verifyMaterializedOutputsV1(
            checkpoint,
            stream.retained_outputs,
        );
        for (
            stream.retained_outputs,
            0..,
        ) |output, chunk_index| {
            const entry = checkpoint.entries[chunk_index];
            bundle_outputs[stream_index][chunk_index] = .{
                .chunk_index = @intCast(chunk_index),
                .output = output,
                .output_sha256 = entry.output_sha256,
                .chunk_receipt_sha256 = entry.chunk_receipt_sha256,
            };
        }
        bundle_streams[stream_index] = .{
            .kind = checkpoint.kind,
            .checkpoint_sha256 = checkpoint.checkpoint_sha256,
            .outputs = bundle_outputs[stream_index][0..stream.retained_outputs.len],
        };
    }
    if ((first.checkpoint_generation == 1 and
        !isZero(parent_archive_sha256)) or
        (first.checkpoint_generation != 1 and
            isZero(parent_archive_sha256)))
        return Error.InvalidMediaCheckpointSet;

    const bundle = try encodeRetainedBundleV1(
        .{
            .generation = first.checkpoint_generation,
            .request_epoch = first.request_epoch,
            .challenge_sha256 = first.challenge_sha256,
        },
        bundle_streams,
        bundle_storage,
    );
    const objects = [_]checkpoint_file.ObjectInputV1{
        .{
            .kind = .extension,
            .ordinal = checkpoint_object_ordinal_base,
            .abi_version = checkpoint_object_abi,
            .bytes = &checkpoint_storage[0],
        },
        .{
            .kind = .extension,
            .ordinal = checkpoint_object_ordinal_base + 1,
            .abi_version = checkpoint_object_abi,
            .bytes = &checkpoint_storage[1],
        },
        .{
            .kind = .extension,
            .ordinal = checkpoint_object_ordinal_base + 2,
            .abi_version = checkpoint_object_abi,
            .bytes = &checkpoint_storage[2],
        },
        .{
            .kind = .extension,
            .ordinal = bundle_object_ordinal,
            .abi_version = bundle_object_abi,
            .bytes = bundle,
        },
    };
    const archive = try checkpoint_file.encodeSetV1(
        .{
            .generation = first.checkpoint_generation,
            .request_epoch = first.request_epoch,
            .publication_next_sequence = first.next_sequence,
            .parent_checkpoint_sha256 = parent_archive_sha256,
            .challenge_sha256 = first.challenge_sha256,
        },
        &objects,
        set_storage,
    );
    _ = try decodeSetV1(archive.bytes);
    return .{ .archive = archive };
}

pub fn decodeSetV1(
    encoded: []const u8,
) Error!DecodedSetV1 {
    const archive = try checkpoint_file.decodeSetV1(
        encoded,
    );
    if (archive.object_count != archive_object_count)
        return Error.InvalidMediaCheckpointSet;
    var checkpoints: [stream_count]continuation.CheckpointV1 =
        undefined;
    for (&checkpoints, 0..) |*checkpoint, index| {
        const object = archive.objects[index];
        if (object.kind != .extension or
            object.ordinal !=
                checkpoint_object_ordinal_base + index or
            object.abi_version != checkpoint_object_abi)
            return Error.InvalidMediaCheckpointSet;
        checkpoint.* =
            try continuation.decodeCheckpointV1(
                object.bytes,
            );
        if (checkpoint.kind != mediaKindForIndex(index) or
            checkpoint.checkpoint_generation !=
                archive.metadata.generation or
            checkpoint.request_epoch !=
                archive.metadata.request_epoch or
            checkpoint.next_sequence !=
                archive.metadata.publication_next_sequence or
            !std.mem.eql(
                u8,
                &checkpoint.challenge_sha256,
                &archive.metadata.challenge_sha256,
            ))
            return Error.InvalidMediaCheckpointSet;
        for (checkpoints[0..index]) |prior| {
            if (checkpoint.stream_key ==
                prior.stream_key or
                checkpoint.restore_bank_epoch ==
                    prior.restore_bank_epoch)
                return Error.InvalidMediaCheckpointSet;
        }
    }
    const bundle_object =
        archive.objects[stream_count];
    if (bundle_object.kind != .extension or
        bundle_object.ordinal != bundle_object_ordinal or
        bundle_object.abi_version != bundle_object_abi)
        return Error.InvalidMediaCheckpointSet;
    const bundle = try decodeRetainedBundleV1(
        bundle_object.bytes,
    );
    if (bundle.generation !=
        archive.metadata.generation or
        bundle.request_epoch !=
            archive.metadata.request_epoch or
        !std.mem.eql(
            u8,
            &bundle.challenge_sha256,
            &archive.metadata.challenge_sha256,
        ))
        return Error.InvalidMediaCheckpointSet;

    var expected_outputs: usize = 0;
    for (checkpoints, 0..) |checkpoint, stream_index| {
        if (!std.mem.eql(
            u8,
            &bundle.checkpoint_sha256[stream_index],
            &checkpoint.checkpoint_sha256,
        ))
            return Error.InvalidMediaCheckpointSet;
        expected_outputs +=
            checkpoint.retained_output_count;
        for (
            checkpoint.entries[0..checkpoint.retained_output_count],
        ) |entry| {
            const output = try bundle.output(
                checkpoint.kind,
                entry.chunk_index,
            );
            if (output.output.len != entry.output_bytes or
                !std.mem.eql(
                    u8,
                    &output.output_sha256,
                    &entry.output_sha256,
                ) or
                !std.mem.eql(
                    u8,
                    &output.chunk_receipt_sha256,
                    &entry.chunk_receipt_sha256,
                ))
                return Error.InvalidMediaCheckpointSet;
        }
    }
    if (bundle.output_count != expected_outputs or
        (archive.metadata.generation == 1 and
            !isZero(
                archive.metadata.parent_checkpoint_sha256,
            )) or
        (archive.metadata.generation != 1 and
            isZero(
                archive.metadata.parent_checkpoint_sha256,
            )))
        return Error.InvalidMediaCheckpointSet;
    return .{
        .archive = archive,
        .checkpoints = checkpoints,
        .bundle = bundle,
    };
}

pub fn validateSuccessorV1(
    previous: *const DecodedSetV1,
    successor: *const DecodedSetV1,
) Error!void {
    const expected_generation = std.math.add(
        u64,
        previous.archive.metadata.generation,
        1,
    ) catch return Error.InvalidSuccessor;
    const expected_sequence = std.math.add(
        u64,
        previous.archive.metadata
            .publication_next_sequence,
        1,
    ) catch return Error.InvalidSuccessor;
    if (successor.archive.metadata.generation !=
        expected_generation or
        successor.archive.metadata.request_epoch !=
            previous.archive.metadata.request_epoch or
        successor.archive.metadata
            .publication_next_sequence != expected_sequence or
        !std.mem.eql(
            u8,
            &successor.archive.metadata
                .parent_checkpoint_sha256,
            &previous.archive.checkpoint_sha256,
        ) or
        !std.mem.eql(
            u8,
            &successor.archive.metadata.challenge_sha256,
            &previous.archive.metadata.challenge_sha256,
        ))
        return Error.InvalidSuccessor;

    for (
        previous.checkpoints,
        successor.checkpoints,
        0..,
    ) |prior, next, stream_index| {
        if (next.kind != prior.kind or
            next.stream_key != prior.stream_key or
            next.request_epoch != prior.request_epoch or
            next.chunk_limit != prior.chunk_limit or
            next.tenant_key != prior.tenant_key or
            next.committed_chunks !=
                prior.committed_chunks + 1 or
            next.visible_chunks !=
                prior.visible_chunks + 1 or
            next.next_sequence != prior.next_sequence + 1 or
            next.visible_units <= prior.visible_units or
            !std.meta.eql(
                next.timeline_base,
                prior.timeline_base,
            ) or
            !std.mem.eql(
                u8,
                &next.media_object_sha256,
                &prior.media_object_sha256,
            ) or
            std.mem.eql(
                u8,
                &next.timeline_sha256,
                &prior.timeline_sha256,
            ) or
            std.mem.eql(
                u8,
                &next.previous_commit_sha256,
                &prior.previous_commit_sha256,
            ) or
            !std.mem.eql(
                u8,
                &next.previous_checkpoint_sha256,
                &prior.checkpoint_sha256,
            ))
            return Error.InvalidSuccessor;
        for (
            prior.entries[0..prior.retained_output_count],
            0..,
        ) |prior_entry, chunk_index| {
            const next_entry = next.entries[chunk_index];
            if (next_entry.chunk_index !=
                prior_entry.chunk_index or
                next_entry.publication_sequence !=
                    prior_entry.publication_sequence or
                next_entry.output_bytes !=
                    prior_entry.output_bytes or
                !std.mem.eql(
                    u8,
                    &next_entry.output_sha256,
                    &prior_entry.output_sha256,
                ) or
                !std.mem.eql(
                    u8,
                    &next_entry.chunk_receipt_sha256,
                    &prior_entry.chunk_receipt_sha256,
                ) or
                !std.mem.eql(
                    u8,
                    try previous.retainedOutput(
                        stream_index,
                        chunk_index,
                    ),
                    try successor.retainedOutput(
                        stream_index,
                        chunk_index,
                    ),
                ))
                return Error.InvalidSuccessor;
        }
    }
}

pub fn validateRestoredSuccessorV1(
    previous: *const DecodedSetV1,
    successor: *const DecodedSetV1,
) Error!void {
    validateSuccessorV1(
        previous,
        successor,
    ) catch return Error.InvalidSuccessor;
    for (
        previous.checkpoints,
        successor.checkpoints,
    ) |prior, next| {
        continuation.validateRestoredSuccessorCheckpointV1(
            prior,
            next,
        ) catch return Error.InvalidSuccessor;
    }
}

pub fn bundleRootV1(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bundle_domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn mediaKindForIndex(index: usize) media.MediaKindV1 {
    return switch (index) {
        0 => .image,
        1 => .audio,
        2 => .video,
        else => unreachable,
    };
}

fn sha256(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        bytes,
        &digest,
        .{},
    );
    return digest;
}

fn writeU64(
    output: []u8,
    offset: usize,
    value: anytype,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(
        u64,
        &bytes,
        @intCast(value),
        .little,
    );
    @memcpy(output[offset .. offset + 8], &bytes);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(
        u64,
        input[offset .. offset + 8][0..8],
        .little,
    );
}

fn isZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn slicesOverlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const a_end = std.math.add(
        usize,
        a_start,
        a.len,
    ) catch return true;
    const b_end = std.math.add(
        usize,
        b_start,
        b.len,
    ) catch return true;
    return a_start < b_end and b_start < a_end;
}

test "retained output bundle is canonical and mutation complete" {
    const image_zero = "image-0";
    const image_one = "image-1";
    const audio_zero = "audio-0";
    const video_zero = "video-0";
    const image_outputs = [_]BundleOutputInputV1{
        .{
            .chunk_index = 0,
            .output = image_zero,
            .output_sha256 = sha256(image_zero),
            .chunk_receipt_sha256 = [_]u8{0x31} ** 32,
        },
        .{
            .chunk_index = 1,
            .output = image_one,
            .output_sha256 = sha256(image_one),
            .chunk_receipt_sha256 = [_]u8{0x32} ** 32,
        },
    };
    const audio_outputs = [_]BundleOutputInputV1{.{
        .chunk_index = 0,
        .output = audio_zero,
        .output_sha256 = sha256(audio_zero),
        .chunk_receipt_sha256 = [_]u8{0x41} ** 32,
    }};
    const video_outputs = [_]BundleOutputInputV1{.{
        .chunk_index = 0,
        .output = video_zero,
        .output_sha256 = sha256(video_zero),
        .chunk_receipt_sha256 = [_]u8{0x51} ** 32,
    }};
    const streams = [_]BundleStreamInputV1{
        .{
            .kind = .image,
            .checkpoint_sha256 = [_]u8{0x11} ** 32,
            .outputs = &image_outputs,
        },
        .{
            .kind = .audio,
            .checkpoint_sha256 = [_]u8{0x12} ** 32,
            .outputs = &audio_outputs,
        },
        .{
            .kind = .video,
            .checkpoint_sha256 = [_]u8{0x13} ** 32,
            .outputs = &video_outputs,
        },
    };
    var storage: [2048]u8 = undefined;
    const encoded = try encodeRetainedBundleV1(
        .{
            .generation = 2,
            .request_epoch = 7000,
            .challenge_sha256 = [_]u8{0xc7} ** 32,
        },
        streams,
        &storage,
    );
    const decoded = try decodeRetainedBundleV1(encoded);
    try std.testing.expectEqual(@as(usize, 4), decoded.output_count);
    try std.testing.expectEqualStrings(
        image_one,
        (try decoded.output(.image, 1)).output,
    );
    var expected_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_root,
        "3a2aa313d1afdbcd650c68e42700ed9e" ++
            "baa2032208459334d3a145edb7911314",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_root,
        &decoded.bundle_sha256,
    );

    var corrupted: [2048]u8 = undefined;
    @memcpy(corrupted[0..encoded.len], encoded);
    for (0..encoded.len) |index| {
        corrupted[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidBundle,
            decodeRetainedBundleV1(
                corrupted[0..encoded.len],
            ),
        );
        corrupted[index] ^= 1;
    }
}
