//! Subprocess used by the real-file crash conformance demo.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const record = core.continuation_object_sweep_record;
const sweep_writer = core.continuation_object_sweep_writer;
const sweep_file = core.continuation_object_sweep_file;

const CrashObserver = struct {
    target: sweep_writer.IoPhaseV1,

    fn after(
        context: *anyopaque,
        phase: sweep_writer.IoPhaseV1,
    ) sweep_writer.Error!void {
        const self: *CrashObserver = @ptrCast(@alignCast(context));
        if (phase != self.target) return;
        forceTerminateCurrentProcess() catch
            return error.StorageIo;
        unreachable;
    }
};

fn forceTerminateCurrentProcess() !void {
    if (comptime builtin.os.tag == .windows) {
        try std.os.windows.TerminateProcess(
            std.os.windows.GetCurrentProcess(),
            137,
        );
        std.process.exit(137);
    }
    try std.posix.raise(std.posix.SIG.KILL);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len < 7) return error.InvalidArguments;

    const mode = arguments[1];
    const directory_path = arguments[2];
    const file_name = arguments[3];
    const storage_epoch = try std.fmt.parseInt(u64, arguments[4], 10);
    const max_bytes = try std.fmt.parseInt(usize, arguments[5], 10);
    const phase = std.meta.stringToEnum(
        sweep_writer.IoPhaseV1,
        arguments[6],
    ) orelse return error.InvalidArguments;
    var observer: CrashObserver = .{ .target = phase };
    var directory = try std.fs.openDirAbsolute(directory_path, .{});
    defer directory.close();
    var stream_storage: [record.encoded_bytes * 2]u8 = undefined;
    var lease = try sweep_file.FileLeaseV1.open(
        directory,
        file_name,
        .{
            .storage_epoch = storage_epoch,
            .max_bytes = max_bytes,
            .observer = .{
                .context = &observer,
                .after_phase_fn = CrashObserver.after,
            },
        },
        &stream_storage,
    );
    defer lease.close();
    const anchor: record.RecoveryAnchorV1 = .{
        .record_epoch = 0x5357_4545_5000_0001,
        .next_sequence = 1,
        .previous_record_sha256 = [_]u8{0} ** @sizeOf(record.Digest),
    };

    if (std.mem.eql(u8, mode, "append")) {
        if (arguments.len != 8) return error.InvalidArguments;
        const record_name = arguments[7];
        const candidate = try directory.openFile(record_name, .{});
        defer candidate.close();
        var encoded: [record.encoded_bytes]u8 = undefined;
        if (try candidate.readAll(&encoded) != encoded.len)
            return error.InvalidArguments;
        var publication = try sweep_writer.WriterV1.openClean(
            lease.stream(),
            anchor,
            try lease.appendCapability(),
        );
        _ = try publication.appendRecord(&encoded);
        return error.ObserverDidNotTerminate;
    }
    if (std.mem.eql(u8, mode, "repair")) {
        if (arguments.len != 7) return error.InvalidArguments;
        var repairer = try sweep_writer.RepairerV1.init(
            lease.stream(),
            anchor,
            try lease.prepareRepair(anchor),
        );
        _ = try repairer.apply();
        return error.ObserverDidNotTerminate;
    }
    return error.InvalidArguments;
}
