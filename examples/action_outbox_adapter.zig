//! Canonical W4b-d adapter-contract reference report.

const std = @import("std");
const core = @import("core");
const contract = core.tool_action_outbox_adapter_contract;

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

    const report = try contract.referenceReportV1();
    const roots = .{
        std.fmt.bytesToHex(report.descriptor_sha256, .lower),
        std.fmt.bytesToHex(report.header_sha256, .lower),
        std.fmt.bytesToHex(report.action_sha256, .lower),
        std.fmt.bytesToHex(
            report.stable_remote_request_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.intent_record_sha256, .lower),
        std.fmt.bytesToHex(
            report.outbox_dispatch_request_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.adapter_dispatch_request_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.status_request_sha256, .lower),
        std.fmt.bytesToHex(report.dispatch_evidence_sha256, .lower),
        std.fmt.bytesToHex(report.status_evidence_sha256, .lower),
        std.fmt.bytesToHex(report.report_sha256, .lower),
    };

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.action-outbox-adapter-reference/v1\"," ++
            "\"reference_report_abi\":\"{x:0>16}\"," ++
            "\"descriptor_abi\":\"{x:0>16}\"," ++
            "\"dispatch_request_abi\":\"{x:0>16}\"," ++
            "\"dispatch_evidence_abi\":\"{x:0>16}\"," ++
            "\"status_request_abi\":\"{x:0>16}\"," ++
            "\"status_evidence_abi\":\"{x:0>16}\"," ++
            "\"descriptor_sha256\":\"{s}\"," ++
            "\"header_sha256\":\"{s}\"," ++
            "\"action_sha256\":\"{s}\"," ++
            "\"stable_remote_request_sha256\":\"{s}\"," ++
            "\"intent_record_sha256\":\"{s}\"," ++
            "\"outbox_dispatch_request_sha256\":\"{s}\"," ++
            "\"adapter_dispatch_request_sha256\":\"{s}\"," ++
            "\"status_request_sha256\":\"{s}\"," ++
            "\"dispatch_evidence_sha256\":\"{s}\"," ++
            "\"status_evidence_sha256\":\"{s}\"," ++
            "\"report_sha256\":\"{s}\"}}\n",
        .{
            report.abi_version,
            contract.descriptor_abi,
            contract.dispatch_request_abi,
            contract.dispatch_evidence_abi,
            contract.status_request_abi,
            contract.status_evidence_abi,
            &roots[0],
            &roots[1],
            &roots[2],
            &roots[3],
            &roots[4],
            &roots[5],
            &roots[6],
            &roots[7],
            &roots[8],
            &roots[9],
            &roots[10],
        },
    );
    try writer.flush();
}
