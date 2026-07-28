//! Fresh-process verifier for one fixed W7b-b5 supervisor/recovery death wire.
//!
//! A successful receipt verifies canonical encoded claims and their internal
//! joins. It is not an independent observation of OS signals, GPU commands,
//! CPU oracles, or durable store operations.

const std = @import("std");
const death_report =
    @import("native_metal_supervisor_recovery_death_report");

fn renderReceiptV1(
    writer: *std.Io.Writer,
    value: death_report.NativeMetalSupervisorRecoveryDeathReportV1,
) !void {
    try writer.print(
        "wire_verified=true claims_only=true generation={d}->{d} " ++
            "recovery_lock_ack={d} claimed_sigkills={d} " ++
            "claimed_commands={d} " ++
            "claimed_cpu_oracles={d} report_sha256={x}\n",
        .{
            value.header.supervisor_generation,
            value.header.candidate_generation,
            value.recovery_ready
                .controller_lock_contention_acknowledged,
            value.header.total_sigkill_count,
            value.header.total_completed,
            value.header.total_completed,
            value.footer.report_sha256,
        },
    );
}

pub fn main() !void {
    var argument_storage: [4096]u8 = undefined;
    var argument_allocator = std.heap.FixedBufferAllocator.init(
        &argument_storage,
    );
    var arguments = try std.process.argsWithAllocator(
        argument_allocator.allocator(),
    );
    defer arguments.deinit();
    _ = arguments.next();
    const report_path = arguments.next() orelse
        return error.MissingReportPath;
    if (report_path.len == 0 or arguments.next() != null)
        return error.UnexpectedArgument;

    var file = if (std.fs.path.isAbsolute(report_path))
        try std.fs.openFileAbsolute(report_path, .{})
    else
        try std.fs.cwd().openFile(report_path, .{});
    defer file.close();

    const before = try file.stat();
    if (before.kind != .file or
        before.size != death_report.report_encoded_bytes)
        return error.InvalidReportFile;

    var encoded: [death_report.report_encoded_bytes]u8 = undefined;
    if (try file.readAll(&encoded) != encoded.len)
        return error.ReportFileChanged;
    var extension_probe: [1]u8 = undefined;
    if (try file.pread(&extension_probe, before.size) != 0)
        return error.ReportFileChanged;
    const after = try file.stat();
    if (before.kind != after.kind or
        before.inode != after.inode or
        before.size != after.size or
        before.mode != after.mode or
        before.mtime != after.mtime or
        before.ctime != after.ctime)
        return error.ReportFileChanged;

    const decoded = try death_report.decodeReportV1(&encoded);
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try renderReceiptV1(&stdout_writer.interface, decoded);
    try stdout_writer.interface.flush();
}

test "verifier receipt exposes exact completed native and oracle counts" {
    const digest: death_report.Digest = [_]u8{0xab} ** 32;
    var value: death_report.NativeMetalSupervisorRecoveryDeathReportV1 =
        undefined;
    value.header.supervisor_generation = 6;
    value.header.candidate_generation = 12;
    value.header.total_sigkill_count = 2;
    value.header.total_completed = 1_200;
    value.recovery_ready.controller_lock_contention_acknowledged = 1;
    value.footer.report_sha256 = digest;

    var storage: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try renderReceiptV1(&writer, value);
    try std.testing.expectEqualStrings(
        "wire_verified=true claims_only=true generation=6->12 " ++
            "recovery_lock_ack=1 claimed_sigkills=2 " ++
            "claimed_commands=1200 " ++
            "claimed_cpu_oracles=1200 report_sha256=" ++
            "abababababababababababababababab" ++
            "abababababababababababababababab\n",
        writer.buffered(),
    );
}
