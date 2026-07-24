//! Subprocess used by generated-media output registry crash conformance.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const output_registry = core.generated_media_output_registry;

const maximum_archive_bytes = 32 * 1024;

const CrashObserver = struct {
    target: checkpoint_file.IoPhaseV1,

    fn after(
        context: *anyopaque,
        phase: checkpoint_file.IoPhaseV1,
    ) checkpoint_file.Error!void {
        const self: *CrashObserver = @ptrCast(@alignCast(context));
        if (phase != self.target) return;
        std.posix.raise(std.posix.SIG.KILL) catch
            return error.StorageIo;
        unreachable;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 5)
        return error.InvalidArguments;
    const storage_epoch = try std.fmt.parseInt(
        u64,
        arguments[2],
        10,
    );
    const phase = std.meta.stringToEnum(
        checkpoint_file.IoPhaseV1,
        arguments[3],
    ) orelse return error.InvalidArguments;

    var first_scratch: [maximum_archive_bytes]u8 = undefined;
    var first_archive: [maximum_archive_bytes]u8 = undefined;
    var second_scratch: [maximum_archive_bytes]u8 = undefined;
    var second_archive: [maximum_archive_bytes]u8 = undefined;
    const references = try output_registry.makeReferenceArchivesV1(
        &first_scratch,
        &first_archive,
        &second_scratch,
        &second_archive,
    );

    var directory = try std.fs.openDirAbsolute(arguments[1], .{});
    defer directory.close();
    const source_pid_wire = try directory.readFileAlloc(
        allocator,
        "source.pid",
        32,
    );
    defer allocator.free(source_pid_wire);
    const source_pid = try std.fmt.parseInt(
        i32,
        source_pid_wire,
        10,
    );
    if (source_pid == std.c.getpid())
        return error.WorkerDidNotRestart;

    const set_wire = try directory.readFileAlloc(
        allocator,
        arguments[4],
        maximum_archive_bytes,
    );
    defer allocator.free(set_wire);
    const decoded_set = try checkpoint_file.decodeSetV1(set_wire);
    if (!std.mem.eql(
        u8,
        &decoded_set.checkpoint_sha256,
        &references.second.set.checkpoint_sha256,
    ))
        return error.UnexpectedPublication;
    const decoded_archive = try output_registry.decodeArchiveV1(
        set_wire,
        references.first_decoded.previous(),
    );
    try validateSuccessorV1(
        decoded_archive,
        references.second_decoded,
    );

    const prepared_set: checkpoint_file.PreparedSetV1 = .{
        .bytes = set_wire,
        .checkpoint_sha256 = decoded_set.checkpoint_sha256,
    };
    var lock_storage: [1]u8 = undefined;
    var active_storage: [maximum_archive_bytes]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        references.first.manifest.challenge_sha256,
        maximum_archive_bytes,
        &lock_storage,
        &active_storage,
    );
    defer lease.close();
    const publication = try checkpoint_file.preparePublicationV1(
        &lease,
        prepared_set,
    );
    var observer: CrashObserver = .{ .target = phase };
    _ = try checkpoint_file.publishObservedV1(
        &lease,
        publication,
        .{
            .context = &observer,
            .after_phase_fn = CrashObserver.after,
        },
    );
    return error.ObserverDidNotTerminate;
}

fn validateSuccessorV1(
    decoded: output_registry.DecodedArchiveV1,
    expected: output_registry.DecodedArchiveV1,
) !void {
    try validateGenerationV1(decoded, expected, 2);
}

fn validateGenerationV1(
    decoded: output_registry.DecodedArchiveV1,
    expected: output_registry.DecodedArchiveV1,
    generation: u64,
) !void {
    const expected_modalities = [_]output_registry.ModalityV1{
        .image,
        .image,
        .audio,
        .audio,
        .video,
        .video,
        .video,
    };
    const expected_source_bytes = [_]u64{
        103,
        104,
        204,
        205,
        303,
        304,
        305,
    };
    if (generation != 2 or
        decoded.manifest.generation != generation or
        decoded.manifest.entry_count != expected_modalities.len or
        decoded.manifest.image_count != 2 or
        decoded.manifest.audio_count != 2 or
        decoded.manifest.video_count != 3)
        return error.InvalidGeneratedMediaRegistrySuccessor;

    for (expected_modalities, 0..) |modality, index| {
        const entry = try decoded.entry(index);
        const expected_entry = try expected.entry(index);
        const payload = try decoded.payload(index);
        const expected_payload = expectedPayloadV1(index);
        const ordinal = expectedOrdinalV1(
            expected_modalities[0..],
            index,
        );
        const range = expectedRangeV1(modality, ordinal);
        if (entry.modality != modality or
            entry.ordinal != ordinal or
            entry.unit_start != range.unit_start or
            entry.unit_count != range.unit_end - range.unit_start or
            entry.unit_end != range.unit_end or
            entry.timeline_start != range.timeline_start or
            entry.timeline_end != range.timeline_end or
            entry.source_bytes != expected_source_bytes[index] or
            entry.encoding_abi != @intFromEnum(modality) or
            entry.payload_bytes != @as(
                u64,
                @intCast(expected_payload.len),
            ) or
            entry.unit_start != expected_entry.unit_start or
            entry.unit_end != expected_entry.unit_end or
            entry.timeline_start != expected_entry.timeline_start or
            entry.timeline_end != expected_entry.timeline_end or
            isZeroV1(entry.previous_entry_sha256) != (ordinal == 0) or
            !std.mem.eql(
                u8,
                &entry.previous_entry_sha256,
                &expected_entry.previous_entry_sha256,
            ) or
            !std.mem.eql(u8, payload, expected_payload))
            return error.InvalidGeneratedMediaRegistrySuccessor;
    }
}

fn expectedOrdinalV1(
    modalities: []const output_registry.ModalityV1,
    index: usize,
) u64 {
    var ordinal: u64 = switch (modalities[index]) {
        .image => 2,
        .audio => 3,
        .video => 2,
    };
    for (modalities[0..index]) |modality| {
        if (modality == modalities[index])
            ordinal += 1;
    }
    return ordinal;
}

fn expectedPayloadV1(index: usize) []const u8 {
    return switch (index) {
        0 => "image-2-generation-two",
        1 => "image-3-generation-two",
        2 => "audio-3-generation-two",
        3 => "audio-4-generation-two",
        4 => "video-2-generation-two",
        5 => "video-3-generation-two",
        6 => "video-4-generation-two",
        else => unreachable,
    };
}

fn isZeroV1(value: [32]u8) bool {
    for (value) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn expectedRangeV1(
    modality: output_registry.ModalityV1,
    ordinal: u64,
) struct {
    unit_start: u64,
    unit_end: u64,
    timeline_start: u64,
    timeline_end: u64,
} {
    return switch (modality) {
        .image => switch (ordinal) {
            2 => .{
                .unit_start = 3,
                .unit_end = 5,
                .timeline_start = 260,
                .timeline_end = 450,
            },
            3 => .{
                .unit_start = 5,
                .unit_end = 6,
                .timeline_start = 450,
                .timeline_end = 600,
            },
            else => unreachable,
        },
        .audio => switch (ordinal) {
            3 => .{
                .unit_start = 480,
                .unit_end = 600,
                .timeline_start = 480,
                .timeline_end = 600,
            },
            4 => .{
                .unit_start = 600,
                .unit_end = 800,
                .timeline_start = 600,
                .timeline_end = 800,
            },
            else => unreachable,
        },
        .video => switch (ordinal) {
            2 => .{
                .unit_start = 3,
                .unit_end = 4,
                .timeline_start = 99,
                .timeline_end = 132,
            },
            3 => .{
                .unit_start = 4,
                .unit_end = 5,
                .timeline_start = 132,
                .timeline_end = 165,
            },
            4 => .{
                .unit_start = 5,
                .unit_end = 7,
                .timeline_start = 165,
                .timeline_end = 231,
            },
            else => unreachable,
        },
    };
}
