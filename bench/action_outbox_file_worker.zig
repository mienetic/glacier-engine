//! Hard-termination worker for ActionOutbox file recovery conformance.
//!
//! The observer terminates only after the selected filesystem operation has
//! returned. This exercises real process loss and lock release through the host
//! filesystem; it does not emulate a device power cut.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const outbox = core.tool_action_outbox_record;
const conformance = core.tool_action_outbox_conformance;
const outbox_file = core.tool_action_outbox_file;

const Buffers = struct {
    journal: [
        outbox.header_bytes +
            outbox.maximum_supported_records *
                outbox.record_bytes
    ]u8 = undefined,
    records: [outbox.maximum_supported_records]outbox.RecordV1 =
        undefined,
    states: [outbox.maximum_supported_actions]outbox.ActionStateV1 =
        undefined,
};

const CrashObserver = struct {
    target: outbox_file.IoPhaseV1,

    fn after(
        context: *anyopaque,
        phase: outbox_file.IoPhaseV1,
    ) outbox_file.Error!void {
        const self: *CrashObserver = @ptrCast(@alignCast(context));
        if (phase != self.target) return;
        forceTerminateCurrentProcess() catch
            return outbox_file.Error.StorageIo;
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

fn phaseAllowed(
    mode: []const u8,
    phase: outbox_file.IoPhaseV1,
) bool {
    if (std.mem.eql(u8, mode, "create")) {
        return switch (phase) {
            .header_write, .header_sync, .directory_sync => true,
            else => false,
        };
    }
    if (std.mem.eql(u8, mode, "append")) {
        return switch (phase) {
            .body_write, .body_sync, .footer_write, .footer_sync => true,
            else => false,
        };
    }
    if (std.mem.eql(u8, mode, "repair")) {
        return switch (phase) {
            .repair_truncate, .repair_sync => true,
            else => false,
        };
    }
    return false;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const arguments = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, arguments);
    if (arguments.len < 5 or arguments.len > 6)
        return error.InvalidArguments;

    const mode = arguments[1];
    const directory_path = arguments[2];
    const journal_name = arguments[3];
    const phase_text = arguments[arguments.len - 1];
    const phase = std.meta.stringToEnum(
        outbox_file.IoPhaseV1,
        phase_text,
    ) orelse return error.InvalidArguments;
    if (!phaseAllowed(mode, phase))
        return error.InvalidArguments;
    if (std.mem.eql(u8, mode, "append") !=
        (arguments.len == 6))
        return error.InvalidArguments;

    var fixture_storage: conformance.ReferenceStorageV1 = .{};
    _ = try conformance.runReferenceCampaignV1(&fixture_storage);
    const header = try conformance.referenceHeaderV1();
    const max_bytes = try outbox_file.maximumFileBytesV1(header);
    const buffers = try allocator.create(Buffers);
    defer allocator.destroy(buffers);
    var observer: CrashObserver = .{ .target = phase };
    const options: outbox_file.OpenOptionsV1 = .{
        .observer = .{
            .context = &observer,
            .after_phase_fn = CrashObserver.after,
        },
    };
    var directory = try std.fs.openDirAbsolute(directory_path, .{});
    defer directory.close();

    if (std.mem.eql(u8, mode, "create")) {
        var store = try outbox_file.StoreV1.create(
            directory,
            journal_name,
            header,
            options,
            buffers.journal[0..max_bytes],
            buffers.records[0..@intCast(header.maximum_records)],
            buffers.states[0..@intCast(header.maximum_actions)],
        );
        defer store.close();
        return error.ObserverDidNotTerminate;
    }

    var store = try outbox_file.StoreV1.open(
        directory,
        journal_name,
        header,
        options,
        buffers.journal[0..max_bytes],
        buffers.records[0..@intCast(header.maximum_records)],
        buffers.states[0..@intCast(header.maximum_actions)],
    );
    defer store.close();

    if (std.mem.eql(u8, mode, "append")) {
        const record_index = try std.fmt.parseInt(
            usize,
            arguments[4],
            10,
        );
        if (record_index >= conformance.reference_record_count)
            return error.InvalidArguments;
        _ = try store.appendRecord(
            fixture_storage.records[record_index],
        );
        return error.ObserverDidNotTerminate;
    }
    if (std.mem.eql(u8, mode, "repair")) {
        _ = try store.repairIncompleteTail();
        return error.ObserverDidNotTerminate;
    }
    return error.InvalidArguments;
}
