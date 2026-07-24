//! Process-death restart proof for atomically selected generated-media output registries.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const output_registry = core.generated_media_output_registry;

const maximum_archive_bytes = 32 * 1024;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 2)
        return error.MissingWorkerPath;
    const worker = arguments[1];

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

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var process_deaths: u64 = 0;
    var selected_previous: u64 = 0;
    var selected_successor: u64 = 0;
    var recovered_applied: u64 = 0;
    var recovered_already_applied: u64 = 0;

    for ([_]checkpoint_file.IoPhaseV1{
        .archive_write,
        .archive_sync,
        .archive_directory_sync,
        .selector_write,
        .selector_sync,
        .selector_rename,
        .selector_directory_sync,
    }, 0..) |phase, phase_index| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const phase_allocator = arena.allocator();

        var directory_name_storage: [64]u8 = undefined;
        const directory_name = try std.fmt.bufPrint(
            &directory_name_storage,
            "generated-registry-death-{d}",
            .{phase_index},
        );
        try temporary.dir.makeDir(directory_name);
        var directory = try temporary.dir.openDir(
            directory_name,
            .{},
        );
        defer directory.close();
        var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
        const absolute_directory = try directory.realpath(
            ".",
            &absolute_storage,
        );
        try writeSyncedV1(
            &directory,
            "successor.set",
            references.second.set.bytes,
        );
        var pid_storage: [32]u8 = undefined;
        const source_pid = try std.fmt.bufPrint(
            &pid_storage,
            "{d}",
            .{currentProcessId()},
        );
        try writeSyncedV1(
            &directory,
            "source.pid",
            source_pid,
        );
        try std.posix.fsync(directory.fd);

        const initial_selector =
            try checkpoint_file.prepareInitialSelectorV1(
                references.first.set,
            );
        const storage_epoch: u64 = 29_000 + phase_index;
        var lock_storage: [1]u8 = undefined;
        var active_storage: [maximum_archive_bytes]u8 = undefined;
        var lease = try checkpoint_file.LeaseV1.create(
            directory,
            storage_epoch,
            references.first.manifest.challenge_sha256,
            references.first.set,
            initial_selector,
            maximum_archive_bytes,
            &lock_storage,
            &active_storage,
        );
        const prepared = try checkpoint_file.preparePublicationV1(
            &lease,
            references.second.set,
        );
        lease.close();

        var epoch_storage: [32]u8 = undefined;
        const epoch_text = try std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{storage_epoch},
        );
        try expectKilledV1(phase_allocator, &.{
            worker,
            absolute_directory,
            epoch_text,
            @tagName(phase),
            "successor.set",
        });
        process_deaths += 1;

        var reopened_lock: [1]u8 = undefined;
        var reopened_storage: [maximum_archive_bytes]u8 = undefined;
        var reopened = try checkpoint_file.LeaseV1.open(
            directory,
            storage_epoch,
            references.first.manifest.challenge_sha256,
            maximum_archive_bytes,
            &reopened_lock,
            &reopened_storage,
        );
        const active = try reopened.activeSet();
        if (std.mem.eql(
            u8,
            &active.checkpoint_sha256,
            &references.first.set.checkpoint_sha256,
        )) {
            if (phase_index >= 5)
                return error.UnexpectedPhaseSelection;
            const decoded = try output_registry.decodeArchiveV1(
                reopened.stream(),
                null,
            );
            try validateGenerationV1(
                decoded,
                references.first_decoded,
                1,
            );
            selected_previous += 1;
        } else if (std.mem.eql(
            u8,
            &active.checkpoint_sha256,
            &references.second.set.checkpoint_sha256,
        )) {
            if (phase_index < 5)
                return error.UnexpectedPhaseSelection;
            const decoded = try output_registry.decodeArchiveV1(
                reopened.stream(),
                references.first_decoded.previous(),
            );
            try validateGenerationV1(
                decoded,
                references.second_decoded,
                2,
            );
            selected_successor += 1;
        } else {
            return error.MixedOrUnknownGeneration;
        }

        const recovered = try checkpoint_file.recoverV1(
            &reopened,
            prepared,
        );
        switch (recovered.disposition) {
            .applied => recovered_applied += 1,
            .already_applied => recovered_already_applied += 1,
        }
        const repeated = try checkpoint_file.recoverV1(
            &reopened,
            prepared,
        );
        if (repeated.disposition != .already_applied)
            return error.NonIdempotentRecovery;
        const repaired = try output_registry.decodeArchiveV1(
            reopened.stream(),
            references.first_decoded.previous(),
        );
        try validateGenerationV1(
            repaired,
            references.second_decoded,
            2,
        );
        reopened.close();
    }

    if (process_deaths != 7 or
        selected_previous != 5 or
        selected_successor != 2 or
        recovered_applied != 5 or
        recovered_already_applied != 2)
        return error.InvalidPhaseAccounting;

    const archive_hex = std.fmt.bytesToHex(
        references.second.set.checkpoint_sha256,
        .lower,
    );
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-media-output-registry/demo-v1\"," ++
            "\"modalities\":3,\"first_outputs\":7," ++
            "\"successor_outputs\":7,\"max_outputs_per_modality\":4," ++
            "\"max_total_outputs\":12,\"generations\":2," ++
            "\"process_deaths\":7,\"archive_phase_deaths\":3," ++
            "\"selector_phase_deaths\":4," ++
            "\"selected_previous_generation\":5," ++
            "\"selected_successor_generation\":2," ++
            "\"canonical_modality_ordinal_order\":true," ++
            "\"continuity_validated\":true," ++
            "\"single_outer_selector\":true," ++
            "\"exact_previous_or_successor\":true," ++
            "\"mixed_generation_observed\":false," ++
            "\"exact_encoded_payloads\":true," ++
            "\"recovery_idempotent\":true," ++
            "\"filesystem_authority\":true," ++
            "\"model_execution\":false," ++
            "\"power_loss_emulated\":false," ++
            "\"archive_sha256\":\"{s}\"," ++
            "\"verified\":true}}\n",
        .{&archive_hex},
    );
    try stdout.flush();
}

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

fn validateGenerationV1(
    decoded: output_registry.DecodedArchiveV1,
    expected: output_registry.DecodedArchiveV1,
    generation: u64,
) !void {
    const first_modalities = [_]output_registry.ModalityV1{
        .image,
        .image,
        .audio,
        .audio,
        .audio,
        .video,
        .video,
    };
    const second_modalities = [_]output_registry.ModalityV1{
        .image,
        .image,
        .audio,
        .audio,
        .video,
        .video,
        .video,
    };
    const first_source_bytes = [_]u64{
        101,
        102,
        201,
        202,
        203,
        301,
        302,
    };
    const second_source_bytes = [_]u64{
        103,
        104,
        204,
        205,
        303,
        304,
        305,
    };
    const modalities = switch (generation) {
        1 => first_modalities[0..],
        2 => second_modalities[0..],
        else => return error.InvalidGeneration,
    };
    const source_bytes = switch (generation) {
        1 => first_source_bytes[0..],
        2 => second_source_bytes[0..],
        else => unreachable,
    };
    const expected_counts = switch (generation) {
        1 => .{ @as(u64, 2), @as(u64, 3), @as(u64, 2) },
        2 => .{ @as(u64, 2), @as(u64, 2), @as(u64, 3) },
        else => unreachable,
    };
    if (decoded.manifest.generation != generation or
        decoded.manifest.entry_count != modalities.len or
        decoded.manifest.image_count != expected_counts[0] or
        decoded.manifest.audio_count != expected_counts[1] or
        decoded.manifest.video_count != expected_counts[2])
        return error.InvalidGeneratedMediaOutputRegistry;

    for (modalities, 0..) |modality, index| {
        const entry = try decoded.entry(index);
        const expected_entry = try expected.entry(index);
        const payload = try decoded.payload(index);
        const expected_payload = expectedPayloadV1(
            generation,
            modality,
            entry.ordinal,
        );
        const ordinal = expectedOrdinalV1(
            generation,
            modalities,
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
            entry.source_bytes != source_bytes[index] or
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
            return error.InvalidGeneratedMediaOutputRegistry;
    }
}

fn expectedOrdinalV1(
    generation: u64,
    modalities: []const output_registry.ModalityV1,
    index: usize,
) u64 {
    var ordinal: u64 = if (generation == 1)
        0
    else switch (modalities[index]) {
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

fn expectedPayloadV1(
    generation: u64,
    modality: output_registry.ModalityV1,
    ordinal: u64,
) []const u8 {
    if (generation == 1) {
        return switch (modality) {
            .image => switch (ordinal) {
                0 => "image-0-generation-one",
                1 => "image-1-generation-one",
                else => unreachable,
            },
            .audio => switch (ordinal) {
                0 => "audio-0-generation-one",
                1 => "audio-1-generation-one",
                2 => "audio-2-generation-one",
                else => unreachable,
            },
            .video => switch (ordinal) {
                0 => "video-0-generation-one",
                1 => "video-1-generation-one",
                else => unreachable,
            },
        };
    }
    return switch (modality) {
        .image => switch (ordinal) {
            2 => "image-2-generation-two",
            3 => "image-3-generation-two",
            else => unreachable,
        },
        .audio => switch (ordinal) {
            3 => "audio-3-generation-two",
            4 => "audio-4-generation-two",
            else => unreachable,
        },
        .video => switch (ordinal) {
            2 => "video-2-generation-two",
            3 => "video-3-generation-two",
            4 => "video-4-generation-two",
            else => unreachable,
        },
    };
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
            0 => .{
                .unit_start = 0,
                .unit_end = 1,
                .timeline_start = 0,
                .timeline_end = 100,
            },
            1 => .{
                .unit_start = 1,
                .unit_end = 3,
                .timeline_start = 100,
                .timeline_end = 260,
            },
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
            0 => .{
                .unit_start = 0,
                .unit_end = 160,
                .timeline_start = 0,
                .timeline_end = 160,
            },
            1 => .{
                .unit_start = 160,
                .unit_end = 400,
                .timeline_start = 160,
                .timeline_end = 400,
            },
            2 => .{
                .unit_start = 400,
                .unit_end = 480,
                .timeline_start = 400,
                .timeline_end = 480,
            },
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
            0 => .{
                .unit_start = 0,
                .unit_end = 1,
                .timeline_start = 0,
                .timeline_end = 33,
            },
            1 => .{
                .unit_start = 1,
                .unit_end = 3,
                .timeline_start = 33,
                .timeline_end = 99,
            },
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

fn isZeroV1(value: [32]u8) bool {
    for (value) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn writeSyncedV1(
    directory: *std.fs.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    var file = try directory.createFile(name, .{
        .read = true,
        .truncate = true,
        .mode = 0o600,
    });
    defer file.close();
    try file.writeAll(bytes);
    try file.sync();
}

fn expectKilledV1(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = arguments,
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!wasForceTerminated(result.term))
        return error.UnexpectedWorkerTermination;
}

fn wasForceTerminated(term: std.process.Child.Term) bool {
    if (comptime builtin.os.tag == .windows) {
        return switch (term) {
            .Exited => |code| code == 137,
            else => false,
        };
    }
    return switch (term) {
        .Signal => |signal| signal == std.posix.SIG.KILL,
        else => false,
    };
}
