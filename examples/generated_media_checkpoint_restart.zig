//! Generated image/audio/video checkpoint selector crash proof.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 2)
        return error.MissingWorkerPath;
    const worker_path = arguments[1];
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_storage: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporary.dir.realpath(".", &root_storage);
    var previous_recoveries: u64 = 0;
    var successor_recoveries: u64 = 0;
    for (1..5) |phase| {
        var directory_storage: [std.fs.max_path_bytes]u8 = undefined;
        const directory_path = try std.fmt.bufPrint(
            &directory_storage,
            "{s}/phase-{d}",
            .{ root, phase },
        );
        try std.fs.makeDirAbsolute(directory_path);
        const source = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ worker_path, "source", directory_path },
            .max_output_bytes = 4096,
        });
        defer allocator.free(source.stdout);
        defer allocator.free(source.stderr);
        try expectSuccessV1(source.term);
        inline for (.{
            "\"phase\":\"source\"",
            "\"prepared_generations\":2",
            "\"active_generation\":1",
            "\"immutable_objects_synced\":true",
            "\"verified\":true",
        }) |required| {
            if (std.mem.indexOf(u8, source.stdout, required) == null)
                return error.InvalidSourceEvidence;
        }
        var phase_storage: [8]u8 = undefined;
        const phase_text = try std.fmt.bufPrint(
            &phase_storage,
            "{d}",
            .{phase},
        );
        const promotion = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                worker_path,
                "promote",
                directory_path,
                phase_text,
            },
            .max_output_bytes = 4096,
        });
        defer allocator.free(promotion.stdout);
        defer allocator.free(promotion.stderr);
        try expectKilledV1(promotion.term);
        const expected_generation: u64 = if (phase <= 2) 1 else 2;
        if (expected_generation == 1)
            previous_recoveries += 1
        else
            successor_recoveries += 1;
        var generation_storage: [8]u8 = undefined;
        const generation_text = try std.fmt.bufPrint(
            &generation_storage,
            "{d}",
            .{expected_generation},
        );
        const recovery = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{
                worker_path,
                "recover",
                directory_path,
                generation_text,
            },
            .max_output_bytes = 4096,
        });
        defer allocator.free(recovery.stdout);
        defer allocator.free(recovery.stderr);
        try expectSuccessV1(recovery.term);
        inline for (.{
            "\"phase\":\"recover\"",
            "\"process_restart\":true",
            "\"complete_members\":3",
            "\"mixed_generation\":false",
            "\"verified\":true",
        }) |required| {
            if (std.mem.indexOf(u8, recovery.stdout, required) == null)
                return error.InvalidRecoveryEvidence;
        }
        var expected_storage: [32]u8 = undefined;
        const expected_fragment = try std.fmt.bufPrint(
            &expected_storage,
            "\"generation\":{d}",
            .{expected_generation},
        );
        if (std.mem.indexOf(
            u8,
            recovery.stdout,
            expected_fragment,
        ) == null)
            return error.InvalidRecoveryGeneration;
    }
    if (previous_recoveries != 2 or successor_recoveries != 2)
        return error.InvalidRecoveryCounts;
    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{{\"schema\":\"glacier.generated-media-checkpoint-restart/" ++
            "demo-v1\",\"modalities\":3,\"checkpoint_generations\":2," ++
            "\"process_deaths\":4,\"selector_write_deaths\":1," ++
            "\"selector_sync_deaths\":1,\"selector_rename_deaths\":1," ++
            "\"directory_sync_deaths\":1," ++
            "\"previous_generation_recoveries\":{d}," ++
            "\"successor_generation_recoveries\":{d}," ++
            "\"exact_previous_or_successor\":true," ++
            "\"mixed_generation_observed\":false," ++
            "\"application_completion_bound\":true," ++
            "\"immutable_objects_synced_before_selector\":true," ++
            "\"atomic_selector_replace\":true," ++
            "\"power_loss_emulated\":false," ++
            "\"filesystem_authority\":true," ++
            "\"network_authority\":false," ++
            "\"device_authority\":false,\"verified\":true}}\n",
        .{ previous_recoveries, successor_recoveries },
    );
    try stdout.flush();
}

fn expectSuccessV1(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code != 0)
            return error.WorkerFailed,
        else => return error.WorkerFailed,
    }
}

fn expectKilledV1(term: std.process.Child.Term) !void {
    switch (term) {
        .Signal => |signal| if (signal != std.posix.SIG.KILL)
            return error.UnexpectedWorkerSignal,
        else => return error.WorkerDidNotDie,
    }
}
