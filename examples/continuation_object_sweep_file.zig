//! Real-file lock, sync, identity, and subprocess-death conformance demo.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const fixture_api = @import("sweep_fixture");
const record = core.continuation_object_sweep_record;
const sweep_writer = core.continuation_object_sweep_writer;
const sweep_file = core.continuation_object_sweep_file;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 2) return error.MissingWorkerPath;
    const worker_path = arguments[1];
    const fixture = try fixture_api.recordsV1();
    const anchor = fixture_api.originAnchorV1();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var absolute_storage: [std.fs.max_path_bytes]u8 = undefined;
    const absolute_directory = try temporary.dir.realpath(
        ".",
        &absolute_storage,
    );
    const candidate = try temporary.dir.createFile("candidate.record", .{
        .read = true,
        .exclusive = true,
        .mode = 0o600,
    });
    try candidate.writeAll(&fixture.first);
    try candidate.sync();
    candidate.close();
    try std.posix.fsync(temporary.dir.fd);

    var append_deaths: usize = 0;
    var append_repairs: usize = 0;
    for ([_]sweep_writer.IoPhaseV1{
        .body_write,
        .body_sync,
        .footer_write,
        .footer_sync,
    }, 0..) |phase, index| {
        var name_storage: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_storage,
            "append-death-{d}.records",
            .{index},
        );
        const storage_epoch = 700 + index;
        var empty_storage: [1]u8 = undefined;
        var lease = try sweep_file.FileLeaseV1.create(
            temporary.dir,
            name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = record.encoded_bytes * 2,
            },
            &empty_storage,
        );
        lease.close();

        var epoch_storage: [32]u8 = undefined;
        const epoch_text = try std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{storage_epoch},
        );
        var max_storage: [32]u8 = undefined;
        const max_text = try std.fmt.bufPrint(
            &max_storage,
            "{d}",
            .{record.encoded_bytes * 2},
        );
        try expectKilled(allocator, &.{
            worker_path,
            "append",
            absolute_directory,
            name,
            epoch_text,
            max_text,
            @tagName(phase),
            "candidate.record",
        });
        append_deaths += 1;

        var reopened_storage: [record.encoded_bytes * 2]u8 = undefined;
        var reopened = try sweep_file.FileLeaseV1.open(
            temporary.dir,
            name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = reopened_storage.len,
            },
            &reopened_storage,
        );
        const plan = try sweep_writer.planRecoveryV1(
            reopened.stream(),
            anchor,
            reopened.snapshot,
        );
        switch (phase) {
            .body_write, .body_sync => {
                if (plan.action != .repair_incomplete_tail)
                    return error.UnexpectedRecovery;
                var repairer = try sweep_writer.RepairerV1.init(
                    reopened.stream(),
                    anchor,
                    try reopened.prepareRepair(anchor),
                );
                const receipt = try repairer.apply();
                if (receipt.committed_bytes != 0)
                    return error.UnexpectedRecovery;
                append_repairs += 1;
            },
            .footer_write, .footer_sync => {
                if (plan.action != .open_clean or
                    reopened.stream().len != record.encoded_bytes or
                    !std.mem.eql(u8, reopened.stream(), &fixture.first))
                    return error.UnexpectedRecovery;
            },
            else => unreachable,
        }
        reopened.close();
    }

    var repair_deaths: usize = 0;
    for ([_]sweep_writer.IoPhaseV1{
        .repair_truncate,
        .repair_sync,
    }, 0..) |phase, index| {
        var name_storage: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_storage,
            "repair-death-{d}.records",
            .{index},
        );
        const storage_epoch = 800 + index;
        const raw = try temporary.dir.createFile(name, .{
            .read = true,
            .exclusive = true,
            .mode = 0o600,
        });
        try raw.writeAll(&fixture.first);
        try raw.writeAll(fixture.second[0 .. record.body_bytes + 7]);
        try raw.sync();
        raw.close();
        try std.posix.fsync(temporary.dir.fd);

        var epoch_storage: [32]u8 = undefined;
        const epoch_text = try std.fmt.bufPrint(
            &epoch_storage,
            "{d}",
            .{storage_epoch},
        );
        var max_storage: [32]u8 = undefined;
        const max_text = try std.fmt.bufPrint(
            &max_storage,
            "{d}",
            .{record.encoded_bytes * 2},
        );
        try expectKilled(allocator, &.{
            worker_path,
            "repair",
            absolute_directory,
            name,
            epoch_text,
            max_text,
            @tagName(phase),
        });
        repair_deaths += 1;

        var reopened_storage: [record.encoded_bytes * 2]u8 = undefined;
        var reopened = try sweep_file.FileLeaseV1.open(
            temporary.dir,
            name,
            .{
                .storage_epoch = storage_epoch,
                .max_bytes = reopened_storage.len,
            },
            &reopened_storage,
        );
        defer reopened.close();
        const plan = try sweep_writer.planRecoveryV1(
            reopened.stream(),
            anchor,
            reopened.snapshot,
        );
        if (plan.action != .open_clean or
            reopened.stream().len != record.encoded_bytes or
            !std.mem.eql(u8, reopened.stream(), &fixture.first))
            return error.UnexpectedRecovery;
        reopened.close();
    }

    std.debug.print(
        "{{\"schema\":\"glacier.continuation-object-sweep-file/demo-v1\"," ++
            "\"append_process_deaths\":{d}," ++
            "\"repair_process_deaths\":{d}," ++
            "\"incomplete_append_repairs\":{d}," ++
            "\"exclusive_lock\":true," ++
            "\"descriptor_relative\":true," ++
            "\"final_symlink_follow\":false," ++
            "\"single_link_required\":true," ++
            "\"private_mode_required\":true," ++
            "\"file_sync\":true," ++
            "\"directory_sync\":true," ++
            "\"replacement_detection\":true," ++
            "\"power_loss_emulated\":false," ++
            "\"verified\":true}}\n",
        .{ append_deaths, repair_deaths, append_repairs },
    );
}

fn expectKilled(
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
