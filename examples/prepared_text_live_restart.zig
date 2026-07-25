const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 2) return error.MissingWorkerPath;
    const worker_path = arguments[1];

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_directory = try temporary.dir.realpath(
        ".",
        &absolute_storage,
    );

    const baseline = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ worker_path, "baseline", absolute_directory },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(baseline.stdout);
    defer allocator.free(baseline.stderr);
    try expectSuccessV1(baseline.term, baseline.stderr);
    if (baseline.stderr.len != 0) return error.BaselineWorkerStderr;
    inline for (.{
        "\"schema\":\"glacier.prepared-text-live-restart/baseline-v1\"",
        "\"phase\":\"baseline\"",
        "\"terminal_semantic\":true",
        "\"bank_zero\":true",
        "\"scheduler_zero\":true",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(u8, baseline.stdout, required) == null)
            return error.InvalidBaselineWorkerEvidence;
    }

    const source = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ worker_path, "source", absolute_directory },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(source.stdout);
    defer allocator.free(source.stderr);
    try expectSuccessV1(source.term, source.stderr);
    if (source.stderr.len != 0) return error.SourceWorkerStderr;
    inline for (.{
        "\"schema\":\"glacier.prepared-text-live-restart/source-v1\"",
        "\"phase\":\"source\"",
        "\"source_bank_zero\":true",
        "\"source_scheduler_zero\":true",
        "\"source_tree_zero\":true",
        "\"selector_generation\":2",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(u8, source.stdout, required) == null)
            return error.InvalidSourceWorkerEvidence;
    }
    const source_pid = try processIdV1(source.stdout);
    const restart_manifest_sha256 = try stringFieldV1(
        source.stdout,
        "restart_manifest_sha256",
    );
    if (restart_manifest_sha256.len != 64)
        return error.InvalidRestartManifestRoot;

    const target = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            worker_path,
            "target",
            absolute_directory,
            restart_manifest_sha256,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(target.stdout);
    defer allocator.free(target.stderr);
    try expectSuccessV1(target.term, target.stderr);
    if (target.stderr.len != 0) return error.TargetWorkerStderr;
    inline for (.{
        "\"schema\":\"glacier.prepared-text-live-restart/demo-v1\"",
        "\"phase\":\"target\"",
        "\"process_restart\":true",
        "\"exclusive_lease\":true",
        "\"sequence_base\":1",
        "\"terminal_next_sequence\":4",
        "\"duplicate_sequences\":0",
        "\"source_resurrection\":false",
        "\"selector_generation\":3",
        "\"terminal_semantic_equal\":true",
        "\"target_bank_zero\":true",
        "\"target_scheduler_zero\":true",
        "\"target_tree_zero\":true",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(u8, target.stdout, required) == null)
            return error.InvalidTargetWorkerEvidence;
    }
    const target_pid = try processIdV1(target.stdout);
    if (source_pid == target_pid) return error.ProcessDidNotRestart;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(target.stdout);
    try stdout.flush();
}

fn stringFieldV1(
    encoded: []const u8,
    field: []const u8,
) ![]const u8 {
    var prefix_storage: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(
        &prefix_storage,
        "\"{s}\":\"",
        .{field},
    );
    const start = std.mem.indexOf(u8, encoded, prefix) orelse
        return error.MissingStringField;
    const value_start = start + prefix.len;
    const relative_end = std.mem.indexOfScalar(
        u8,
        encoded[value_start..],
        '"',
    ) orelse return error.InvalidStringField;
    return encoded[value_start .. value_start + relative_end];
}

fn processIdV1(encoded: []const u8) !u32 {
    const prefix = "\"pid\":";
    const start = std.mem.indexOf(u8, encoded, prefix) orelse
        return error.MissingProcessId;
    const digits_start = start + prefix.len;
    var digits_end = digits_start;
    while (digits_end < encoded.len and
        std.ascii.isDigit(encoded[digits_end]))
    {
        digits_end += 1;
    }
    if (digits_end == digits_start) return error.InvalidProcessId;
    return std.fmt.parseInt(
        u32,
        encoded[digits_start..digits_end],
        10,
    );
}

fn expectSuccessV1(
    term: std.process.Child.Term,
    worker_stderr: []const u8,
) !void {
    switch (term) {
        .Exited => |code| if (code != 0) {
            if (worker_stderr.len != 0)
                std.debug.print("{s}", .{worker_stderr});
            return error.WorkerFailed;
        },
        else => {
            std.debug.print(
                "worker terminated unexpectedly: {any}\n{s}",
                .{ term, worker_stderr },
            );
            return error.WorkerFailed;
        },
    }
}
