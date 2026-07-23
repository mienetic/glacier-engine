//! Real process-restart generated-image publication demonstration.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(
        allocator,
    );
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 3)
        return error.MissingWorkerPaths;
    const checkpoint_worker_path = arguments[1];
    const generated_worker_path = arguments[2];
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
            checkpoint_worker_path,
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
        "\"committed_steps\":1",
        "\"visible_results\":1",
        "\"source_ownership_released\":true",
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
    const published = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            generated_worker_path,
            "resume",
            absolute_directory,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(published.stdout);
    defer allocator.free(published.stderr);
    try expectSuccessV1(published.term);
    inline for (.{
        "\"schema\":\"glacier.generated-image-live-restart/demo-v1\"",
        "\"phase\":\"publish\"",
        "\"process_restart\":true",
        "\"restored_step\":1",
        "\"terminal_step\":2",
        "\"terminal_latent\":\"6,12,18,24\"",
        "\"generated_pixels\":\"24,36,36,24\"",
        "\"width\":2",
        "\"height\":2",
        "\"channels\":1",
        "\"visible_images\":1",
        "\"duplicate_visible_images\":0",
        "\"cancelled_publications\":1",
        "\"cancellation_preserved_visibility\":true",
        "\"atomic_visibility\":true",
        "\"provenance_bound\":true",
        "\"terminal_latent_bound\":true",
        "\"charge_before_materialize\":true",
        "\"final_bank_host_bytes\":0",
        "\"final_live_allocations\":0",
        "\"display_authority\":false",
        "\"production_model\":false",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(
            u8,
            published.stdout,
            required,
        ) == null)
            return error.InvalidPublicationEvidence;
    }
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(published.stdout);
    try stdout.flush();
}

fn expectSuccessV1(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code != 0)
            return error.WorkerFailed,
        else => return error.WorkerFailed,
    }
}
