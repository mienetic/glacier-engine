//! Real two-process image/audio/video stream continuation demonstration.

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
    var absolute_storage: [std.fs.max_path_bytes]u8 =
        undefined;
    const absolute_directory =
        try temporary.dir.realpath(
            ".",
            &absolute_storage,
        );

    const checkpoint = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            worker_path,
            "checkpoint",
            absolute_directory,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(checkpoint.stdout);
    defer allocator.free(checkpoint.stderr);
    try expectSuccessV1(checkpoint.term);
    inline for (.{
        "\"phase\":\"checkpoint\"",
        "\"portable_checkpoints\":3",
        "\"source_ownership_releases\":3",
        "\"file_sync\":true",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(
            u8,
            checkpoint.stdout,
            required,
        ) == null)
            return error.InvalidCheckpointEvidence;
    }

    const resumed = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            worker_path,
            "resume",
            absolute_directory,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(resumed.stdout);
    defer allocator.free(resumed.stderr);
    try expectSuccessV1(resumed.term);
    inline for (.{
        "\"schema\":\"glacier.media-stream-live-restart/demo-v1\"",
        "\"phase\":\"resume\"",
        "\"process_restart\":true",
        "\"modalities\":3",
        "\"restored_outputs\":3",
        "\"resumed_chunks\":3",
        "\"duplicate_publications\":0",
        "\"charge_before_materialize\":true",
        "\"final_bank_host_bytes\":0",
        "\"final_live_allocations\":0",
        "\"crash_atomic_checkpoint_set\":false",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(
            u8,
            resumed.stdout,
            required,
        ) == null)
            return error.InvalidResumeEvidence;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(resumed.stdout);
    try stdout.flush();
}

fn expectSuccessV1(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code != 0)
            return error.WorkerFailed,
        else => return error.WorkerFailed,
    }
}
