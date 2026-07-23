//! Real two-process stateful VFR video continuation demonstration.

const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(
        allocator,
    );
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
        "\"committed_segments\":1",
        "\"visible_links\":1",
        "\"next_frame_ordinal\":2",
        "\"declared_discontinuity_ticks\":5",
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
        "\"schema\":\"glacier.video-model-live-restart/demo-v1\"",
        "\"phase\":\"resume\"",
        "\"process_restart\":true",
        "\"restored_segment\":1",
        "\"resumed_segment\":2",
        "\"frame_ordinals\":\"0,1,2,3\"",
        "\"frame_durations\":\"8,12,10,15\"",
        "\"declared_discontinuity_ticks\":5",
        "\"next_start_tick\":25",
        "\"next_end_tick\":50",
        "\"vfr_exact\":true",
        "\"checkpoint_gap_bound\":true",
        "\"timeline_action\":\"retain_distinct\"",
        "\"visible_results\":2",
        "\"visible_segments\":2",
        "\"visible_links\":2",
        "\"duplicate_segments\":0",
        "\"charge_before_materialize\":true",
        "\"predecessor_state_released\":true",
        "\"final_bank_host_bytes\":0",
        "\"final_live_allocations\":0",
        "\"model_execution\":true",
        "\"production_model\":false",
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
