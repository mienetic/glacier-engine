//! Subprocess used by durable payload promotion crash conformance.

const std = @import("std");
const core = @import("core");
const payload_file = core.continuation_object_payload_file;
const sweep_file = core.continuation_object_sweep_file;
const sweep_record = core.continuation_object_sweep_record;

const CrashObserver = struct {
    target: payload_file.IoPhaseV1,

    fn after(
        context: *anyopaque,
        phase: payload_file.IoPhaseV1,
    ) sweep_file.Error!void {
        const self: *CrashObserver = @ptrCast(@alignCast(context));
        if (phase != self.target) return;
        std.posix.raise(std.posix.SIG.KILL) catch
            return error.StorageIo;
        unreachable;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 8) return error.InvalidArguments;

    const directory_path = arguments[1];
    const storage_epoch = try std.fmt.parseInt(u64, arguments[2], 10);
    const max_bytes = try std.fmt.parseInt(usize, arguments[3], 10);
    var tenant_scope_sha256: payload_file.Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &tenant_scope_sha256,
        arguments[4],
    );
    const sweep_name = arguments[5];
    const reclaim_name = arguments[6];
    const phase = std.meta.stringToEnum(
        payload_file.IoPhaseV1,
        arguments[7],
    ) orelse return error.InvalidArguments;

    var directory = try std.fs.openDirAbsolute(directory_path, .{});
    defer directory.close();
    const sweep_source = try directory.openFile(sweep_name, .{});
    defer sweep_source.close();
    var sweep_bytes: [sweep_record.encoded_bytes]u8 = undefined;
    if (try sweep_source.readAll(&sweep_bytes) != sweep_bytes.len)
        return error.InvalidArguments;
    const sweep_decoded = try sweep_record.decodeV1(&sweep_bytes);
    const prepared_sweep: sweep_file.PreparedCommitRecordV1 = .{
        .bytes = sweep_bytes,
        .record_sha256 = sweep_decoded.record_sha256,
    };
    const reclaim_source = try directory.openFile(reclaim_name, .{});
    defer reclaim_source.close();
    var reclaim_bytes: [payload_file.reclaim_record_bytes]u8 = undefined;
    if (try reclaim_source.readAll(&reclaim_bytes) != reclaim_bytes.len)
        return error.InvalidArguments;
    const prepared_reclaim: payload_file.PreparedReclaimRecordV1 = .{
        .bytes = reclaim_bytes,
        .record_sha256 = reclaim_bytes[payload_file.reclaim_record_bytes - 32 ..].*,
    };
    var lock_storage: [1]u8 = undefined;
    var active_storage: [4096]u8 = undefined;
    if (max_bytes > active_storage.len) return error.InvalidArguments;
    var lease = try payload_file.LeaseV1.open(
        directory,
        storage_epoch,
        tenant_scope_sha256,
        max_bytes,
        &lock_storage,
        &active_storage,
    );
    defer lease.close();
    var candidate_storage: [4096]u8 = undefined;
    var observer: CrashObserver = .{ .target = phase };
    const observed: payload_file.ObserverV1 = .{
        .context = &observer,
        .after_phase_fn = CrashObserver.after,
    };
    switch (phase) {
        .plan_write, .plan_sync, .plan_directory_sync => {
            try payload_file.publishReclaimRecordObservedV1(
                &lease,
                prepared_reclaim,
                observed,
            );
            return error.ObserverDidNotTerminate;
        },
        else => {},
    }
    _ = try payload_file.recoverFromPublishedFilesV1(
        &lease,
        prepared_sweep,
        &sweep_bytes,
        .{
            .record_epoch = 0x5357_4545_5000_0001,
            .next_sequence = 1,
            .previous_record_sha256 = [_]u8{0} **
                @sizeOf(sweep_record.Digest),
        },
        prepared_reclaim,
        candidate_storage[0..max_bytes],
        observed,
    );
    return error.ObserverDidNotTerminate;
}
