//! Real process-restart generated-video and display-ack demonstration.

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
    var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_directory = try temporary.dir.realpath(
        ".",
        &absolute_storage,
    );
    const source = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            worker_path,
            "source",
            absolute_directory,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(source.stdout);
    defer allocator.free(source.stderr);
    try expectSuccessV1(source.term);
    inline for (.{
        "\"schema\":\"glacier.generated-video-live-restart/demo-v1\"",
        "\"phase\":\"source\"",
        "\"published_segments\":1",
        "\"published_frames\":2",
        "\"displayed_segments\":0",
        "\"pending_segments\":1",
        "\"source_ownership_released\":true",
        "\"file_sync\":true",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(u8, source.stdout, required) == null)
            return error.InvalidSourceEvidence;
    }
    const target = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            worker_path,
            "target",
            absolute_directory,
        },
        .max_output_bytes = 16 * 1024,
    });
    defer allocator.free(target.stdout);
    defer allocator.free(target.stderr);
    try expectSuccessV1(target.term);
    inline for (.{
        "\"schema\":\"glacier.generated-video-live-restart/demo-v1\"",
        "\"phase\":\"target\"",
        "\"process_restart\":true",
        "\"width\":2",
        "\"height\":2",
        "\"channels\":1",
        "\"pixel_format\":\"gray8-frame-major\"",
        "\"first_frames\":\"3,7\"",
        "\"second_frames\":\"11,13\"",
        "\"frame_durations\":\"2,3,4,1\"",
        "\"visible_segments\":2",
        "\"visible_frames\":4",
        "\"visible_end_tick\":10",
        "\"displayed_segments\":2",
        "\"displayed_frames\":4",
        "\"displayed_end_tick\":10",
        "\"pending_segments\":0",
        "\"duplicate_segments\":0",
        "\"duplicate_acknowledgements\":0",
        "\"blocked_before_ack\":true",
        "\"partial_ack_rejected\":true",
        "\"rejected_ack_preserved_state\":true",
        "\"cancelled_publications\":1",
        "\"cancellation_preserved_visibility\":true",
        "\"atomic_visibility\":true",
        "\"state_validated_before_admission\":true",
        "\"application_display_acknowledgement\":true",
        "\"physical_display_proven\":false",
        "\"final_bank_host_bytes\":0",
        "\"final_live_allocations\":0",
        "\"final_active_lease_trees\":0",
        "\"network_authority\":false",
        "\"device_authority\":false",
        "\"display_device_authority\":false",
        "\"production_model\":false",
        "\"verified\":true",
    }) |required| {
        if (std.mem.indexOf(u8, target.stdout, required) == null)
            return error.InvalidTargetEvidence;
    }
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(target.stdout);
    try stdout.flush();
}

fn expectSuccessV1(term: std.process.Child.Term) !void {
    switch (term) {
        .Exited => |code| if (code != 0)
            return error.WorkerFailed,
        else => return error.WorkerFailed,
    }
}
