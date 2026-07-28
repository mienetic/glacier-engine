//! Fresh-process verifier for Native Workload Store Fault Report V1.

const std = @import("std");
const fault_report = @import("native_workload_store_fault_report");

const maximum_report_bytes =
    fault_report.report_fixed_bytes +
    fault_report.max_case_count * fault_report.case_bytes;

fn renderReceiptV1(
    writer: *std.Io.Writer,
    case_count: u64,
    generation_before: u64,
    generation_after: u64,
    report_sha256: fault_report.Digest,
) !void {
    try writer.print(
        "verified=true cases={d} generation={d}->{d} report_sha256={x}\n",
        .{
            case_count,
            generation_before,
            generation_after,
            report_sha256,
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
        before.size < fault_report.report_fixed_bytes +
            fault_report.case_bytes or
        before.size > maximum_report_bytes)
        return error.InvalidReportFile;

    var encoded: [maximum_report_bytes]u8 = undefined;
    const encoded_length = std.math.cast(usize, before.size) orelse
        return error.InvalidReportFile;
    if (try file.readAll(encoded[0..encoded_length]) != encoded_length)
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

    var cases: [fault_report.max_case_count]fault_report.FaultCaseV1 = undefined;
    const decoded = try fault_report.decodeReportV1(
        encoded[0..encoded_length],
        &cases,
    );

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    try renderReceiptV1(
        &stdout_writer.interface,
        decoded.report.header.case_count,
        decoded.report.header.generation_before,
        decoded.report.header.generation_after,
        decoded.report.report_footer_sha256,
    );
    try stdout_writer.interface.flush();
}

test "verifier receipt keeps the campaign stdout protocol" {
    const digest: fault_report.Digest = [_]u8{0xab} ** 32;
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try renderReceiptV1(&writer, 81, 1, 2, digest);
    try std.testing.expectEqualStrings(
        "verified=true cases=81 generation=1->2 report_sha256=" ++
            "abababababababababababababababab" ++
            "abababababababababababababababab\n",
        writer.buffered(),
    );
}
