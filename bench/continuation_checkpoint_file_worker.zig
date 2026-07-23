//! Subprocess used by whole-checkpoint root-switch crash conformance.

const std = @import("std");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;

const challenge_sha256 = [_]u8{0x72} ** 32;

const CrashObserver = struct {
    target: checkpoint_file.IoPhaseV1,

    fn after(
        context: *anyopaque,
        phase: checkpoint_file.IoPhaseV1,
    ) checkpoint_file.Error!void {
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
    if (arguments.len != 5) return error.InvalidArguments;
    const storage_epoch = try std.fmt.parseInt(
        u64,
        arguments[2],
        10,
    );
    const phase = std.meta.stringToEnum(
        checkpoint_file.IoPhaseV1,
        arguments[3],
    ) orelse return error.InvalidArguments;
    var directory = try std.fs.openDirAbsolute(arguments[1], .{});
    defer directory.close();
    const set_wire = try directory.readFileAlloc(
        allocator,
        arguments[4],
        8192,
    );
    defer allocator.free(set_wire);
    const decoded = try checkpoint_file.decodeSetV1(set_wire);
    const prepared_set: checkpoint_file.PreparedSetV1 = .{
        .bytes = set_wire,
        .checkpoint_sha256 = decoded.checkpoint_sha256,
    };
    var lock_storage: [1]u8 = undefined;
    var active_storage: [8192]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        challenge_sha256,
        active_storage.len,
        &lock_storage,
        &active_storage,
    );
    defer lease.close();
    const publication = try checkpoint_file.preparePublicationV1(
        &lease,
        prepared_set,
    );
    var observer: CrashObserver = .{ .target = phase };
    _ = try checkpoint_file.publishObservedV1(
        &lease,
        publication,
        .{
            .context = &observer,
            .after_phase_fn = CrashObserver.after,
        },
    );
    return error.ObserverDidNotTerminate;
}
