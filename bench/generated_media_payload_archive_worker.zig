//! Subprocess used by generated-media payload archive crash conformance.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const checkpoint_file = core.continuation_checkpoint_file;
const payload_archive = core.generated_media_payload_archive;

const maximum_archive_bytes = 8192;

const CrashObserver = struct {
    target: checkpoint_file.IoPhaseV1,

    fn after(
        context: *anyopaque,
        phase: checkpoint_file.IoPhaseV1,
    ) checkpoint_file.Error!void {
        const self: *CrashObserver = @ptrCast(@alignCast(context));
        if (phase != self.target) return;
        forceTerminateCurrentProcess() catch
            return error.StorageIo;
        unreachable;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len != 5)
        return error.InvalidArguments;
    const storage_epoch = try std.fmt.parseInt(
        u64,
        arguments[2],
        10,
    );
    const phase = std.meta.stringToEnum(
        checkpoint_file.IoPhaseV1,
        arguments[3],
    ) orelse return error.InvalidArguments;

    var first_archive: [maximum_archive_bytes]u8 = undefined;
    var second_archive: [maximum_archive_bytes]u8 = undefined;
    const references = try payload_archive.makeReferenceArchivesV1(
        &first_archive,
        &second_archive,
    );

    var directory = try std.fs.openDirAbsolute(arguments[1], .{});
    defer directory.close();
    const source_pid_wire = try directory.readFileAlloc(
        allocator,
        "source.pid",
        32,
    );
    defer allocator.free(source_pid_wire);
    const source_pid = try std.fmt.parseInt(
        u32,
        source_pid_wire,
        10,
    );
    if (source_pid == currentProcessId())
        return error.WorkerDidNotRestart;

    const set_wire = try directory.readFileAlloc(
        allocator,
        arguments[4],
        maximum_archive_bytes,
    );
    defer allocator.free(set_wire);
    const decoded_set = try checkpoint_file.decodeSetV1(set_wire);
    if (!std.mem.eql(
        u8,
        &decoded_set.checkpoint_sha256,
        &references.second.set.checkpoint_sha256,
    ))
        return error.UnexpectedPublication;
    const decoded_archive = try payload_archive.decodeArchiveV1(
        set_wire,
        references.first_decoded.previous(),
    );
    try validateSuccessorV1(decoded_archive);

    const prepared_set: checkpoint_file.PreparedSetV1 = .{
        .bytes = set_wire,
        .checkpoint_sha256 = decoded_set.checkpoint_sha256,
    };
    var lock_storage: [1]u8 = undefined;
    var active_storage: [maximum_archive_bytes]u8 = undefined;
    var lease = try checkpoint_file.LeaseV1.open(
        directory,
        storage_epoch,
        references.first.manifest.challenge_sha256,
        maximum_archive_bytes,
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

fn currentProcessId() u32 {
    if (comptime builtin.os.tag == .windows)
        return std.os.windows.GetCurrentProcessId();
    return @intCast(std.c.getpid());
}

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

fn validateSuccessorV1(
    decoded: payload_archive.DecodedArchiveV1,
) !void {
    if (decoded.manifest.generation != 2 or
        decoded.manifest.payload_count != 3 or
        !std.mem.eql(
            u8,
            decoded.image_payload,
            "image-envelope-generation-two",
        ) or
        !std.mem.eql(
            u8,
            decoded.audio_payload,
            "audio-envelope-generation-two",
        ) or
        !std.mem.eql(
            u8,
            decoded.video_payload,
            "video-envelope-generation-two",
        ))
        return error.InvalidGeneratedMediaSuccessor;
}
