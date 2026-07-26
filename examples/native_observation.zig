//! Canonical download-free native-observation reference report.

const std = @import("std");
const core = @import("core");
const contract = core.native_observation_contract;
const runner = core.native_observation_runner;

pub fn main() !void {
    var argument_storage: [4096]u8 = undefined;
    var argument_allocator = std.heap.FixedBufferAllocator.init(
        &argument_storage,
    );
    var args = try std.process.argsWithAllocator(
        argument_allocator.allocator(),
    );
    defer args.deinit();
    _ = args.next();
    if (args.next() != null) return error.UnexpectedArgument;

    const report = try runner.referenceReportV1();
    const roots = .{
        std.fmt.bytesToHex(report.descriptor_sha256, .lower),
        std.fmt.bytesToHex(report.plan_sha256, .lower),
        std.fmt.bytesToHex(report.probe_bundle_sha256, .lower),
        std.fmt.bytesToHex(report.pre_run_bundle_sha256, .lower),
        std.fmt.bytesToHex(report.post_run_bundle_sha256, .lower),
        std.fmt.bytesToHex(
            report.workload_receipt_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.run_report_sha256, .lower),
        std.fmt.bytesToHex(
            report.workload_result_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.report_sha256, .lower),
    };

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.native-observation-reference/v1\"," ++
            "\"descriptor_abi\":\"{x:0>16}\"," ++
            "\"rule_abi\":\"{x:0>16}\"," ++
            "\"plan_abi\":\"{x:0>16}\"," ++
            "\"observation_abi\":\"{x:0>16}\"," ++
            "\"bundle_abi\":\"{x:0>16}\"," ++
            "\"workload_receipt_abi\":\"{x:0>16}\"," ++
            "\"run_report_abi\":\"{x:0>16}\"," ++
            "\"reference_report_abi\":\"{x:0>16}\"," ++
            "\"availability\":[\"present\",\"missing\"," ++
            "\"denied\",\"unsupported\"]," ++
            "\"decision\":\"{s}\"," ++
            "\"profile_count\":{d},\"item_count\":{d}," ++
            "\"elapsed_nanoseconds\":{d}," ++
            "\"descriptor_sha256\":\"{s}\"," ++
            "\"plan_sha256\":\"{s}\"," ++
            "\"probe_bundle_sha256\":\"{s}\"," ++
            "\"pre_run_bundle_sha256\":\"{s}\"," ++
            "\"post_run_bundle_sha256\":\"{s}\"," ++
            "\"workload_receipt_sha256\":\"{s}\"," ++
            "\"run_report_sha256\":\"{s}\"," ++
            "\"workload_result_sha256\":\"{s}\"," ++
            "\"report_sha256\":\"{s}\"}}\n",
        .{
            contract.descriptor_abi,
            contract.rule_abi,
            contract.plan_abi,
            contract.observation_abi,
            contract.bundle_abi,
            runner.workload_receipt_abi,
            runner.run_report_abi,
            runner.reference_report_abi,
            @tagName(report.decision),
            report.profile_count,
            report.item_count,
            report.elapsed_nanoseconds,
            &roots[0],
            &roots[1],
            &roots[2],
            &roots[3],
            &roots[4],
            &roots[5],
            &roots[6],
            &roots[7],
            &roots[8],
        },
    );
    try writer.flush();
}
