//! Process-death restart proof for atomically selected generated-media payloads.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const payload_archive = core.generated_media_payload_archive;

const maximum_archive_bytes = 8192;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 2)
        return error.MissingWorkerPath;
    const worker = arguments[1];

    var first_archive: [maximum_archive_bytes]u8 = undefined;
    var second_archive: [maximum_archive_bytes]u8 = undefined;
    const references = try payload_archive.makeReferenceArchivesV1(
        &first_archive,
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
            "generated-payload-death-{d}",
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
        const storage_epoch: u64 = 27_000 + phase_index;
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
            const decoded = try payload_archive.decodeArchiveV1(
                reopened.stream(),
                null,
            );
            try validateGenerationV1(decoded, 1);
            selected_previous += 1;
        } else if (std.mem.eql(
            u8,
            &active.checkpoint_sha256,
            &references.second.set.checkpoint_sha256,
        )) {
            const decoded = try payload_archive.decodeArchiveV1(
                reopened.stream(),
                references.first_decoded.previous(),
            );
            try validateGenerationV1(decoded, 2);
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
        const repaired = try payload_archive.decodeArchiveV1(
            reopened.stream(),
            references.first_decoded.previous(),
        );
        try validateGenerationV1(repaired, 2);
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
    var stdout_buffer: [1536]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-media-payload-archive/demo-v1\"," ++
            "\"modalities\":3,\"encoded_payloads\":3,\"generations\":2," ++
            "\"process_deaths\":7,\"archive_phase_deaths\":3," ++
            "\"selector_phase_deaths\":4," ++
            "\"selected_previous_generation\":5," ++
            "\"selected_successor_generation\":2," ++
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
    decoded: payload_archive.DecodedArchiveV1,
    generation: u64,
) !void {
    const suffix = switch (generation) {
        1 => "one",
        2 => "two",
        else => return error.InvalidGeneration,
    };
    var image_storage: [64]u8 = undefined;
    const expected_image = try std.fmt.bufPrint(
        &image_storage,
        "image-envelope-generation-{s}",
        .{suffix},
    );
    var audio_storage: [64]u8 = undefined;
    const expected_audio = try std.fmt.bufPrint(
        &audio_storage,
        "audio-envelope-generation-{s}",
        .{suffix},
    );
    var video_storage: [64]u8 = undefined;
    const expected_video = try std.fmt.bufPrint(
        &video_storage,
        "video-envelope-generation-{s}",
        .{suffix},
    );
    if (decoded.manifest.generation != generation or
        decoded.manifest.payload_count != 3 or
        !std.mem.eql(u8, decoded.image_payload, expected_image) or
        !std.mem.eql(u8, decoded.audio_payload, expected_audio) or
        !std.mem.eql(u8, decoded.video_payload, expected_video))
        return error.InvalidGeneratedMediaGeneration;
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
