//! Canonical protocol-only ActionOutbox conformance report.

const std = @import("std");
const core = @import("core");
const conformance = core.tool_action_outbox_conformance;
const record = core.tool_action_outbox_record;

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

    var storage: conformance.ReferenceStorageV1 = .{};
    const report = try conformance.runReferenceCampaignV1(&storage);
    const roots = .{
        std.fmt.bytesToHex(report.header_sha256, .lower),
        std.fmt.bytesToHex(report.primary_proposal_sha256, .lower),
        std.fmt.bytesToHex(
            report.primary_authorization_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.primary_action_sha256, .lower),
        std.fmt.bytesToHex(
            report.compensation_proposal_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.compensation_authorization_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.compensation_action_sha256, .lower),
        std.fmt.bytesToHex(report.record_section_sha256, .lower),
        std.fmt.bytesToHex(report.final_chain_sha256, .lower),
        std.fmt.bytesToHex(report.final_state_sha256, .lower),
        std.fmt.bytesToHex(report.ledger_sha256, .lower),
        std.fmt.bytesToHex(report.closed_anchor_sha256, .lower),
        std.fmt.bytesToHex(report.recovery_matrix_sha256, .lower),
        std.fmt.bytesToHex(report.torn_case_sha256, .lower),
        std.fmt.bytesToHex(report.report_sha256, .lower),
    };

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.action-outbox-conformance/v1\"," ++
            "\"report_abi\":\"{x:0>16}\"," ++
            "\"header_abi\":\"{x:0>16}\"," ++
            "\"identity_abi\":\"{x:0>16}\"," ++
            "\"record_abi\":\"{x:0>16}\"," ++
            "\"closed_anchor_abi\":\"{x:0>16}\"," ++
            "\"header_bytes\":{d}," ++
            "\"record_body_bytes\":{d}," ++
            "\"commit_footer_bytes\":{d}," ++
            "\"record_bytes\":{d}," ++
            "\"journal_bytes\":{d}," ++
            "\"record_count\":{d}," ++
            "\"action_count\":{d}," ++
            "\"recovery_cut_count\":{d}," ++
            "\"header_sha256\":\"{s}\"," ++
            "\"primary_proposal_sha256\":\"{s}\"," ++
            "\"primary_authorization_sha256\":\"{s}\"," ++
            "\"primary_action_sha256\":\"{s}\"," ++
            "\"compensation_proposal_sha256\":\"{s}\"," ++
            "\"compensation_authorization_sha256\":\"{s}\"," ++
            "\"compensation_action_sha256\":\"{s}\"," ++
            "\"record_section_sha256\":\"{s}\"," ++
            "\"final_chain_sha256\":\"{s}\"," ++
            "\"final_state_sha256\":\"{s}\"," ++
            "\"ledger_sha256\":\"{s}\"," ++
            "\"closed_anchor_sha256\":\"{s}\"," ++
            "\"recovery_matrix_sha256\":\"{s}\"," ++
            "\"torn_case_sha256\":\"{s}\"," ++
            "\"report_sha256\":\"{s}\",\"event_kinds\":[",
        .{
            report.abi_version,
            record.header_abi,
            record.identity_abi,
            record.record_abi,
            record.closed_anchor_abi,
            report.header_bytes,
            report.record_body_bytes,
            report.commit_footer_bytes,
            report.record_bytes,
            report.journal_bytes,
            report.record_count,
            report.action_count,
            report.journal_bytes - report.header_bytes + 1,
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
            &roots[11],
            &roots[12],
            &roots[13],
            &roots[14],
        },
    );
    for (report.event_kinds, 0..) |kind, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{@tagName(kind)});
    }
    try writer.writeAll("],\"attempt_generations\":[");
    for (report.attempt_generations, 0..) |generation, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{d}", .{generation});
    }
    const ledger = report.summary;
    try writer.print(
        "],\"ledger\":{{" ++
            "\"committed_records\":{d}," ++
            "\"actions_enqueued\":{d}," ++
            "\"primary_actions\":{d}," ++
            "\"compensation_actions\":{d}," ++
            "\"dispatch_intents\":{d}," ++
            "\"safe_retry_dispatches\":{d}," ++
            "\"ambiguity_observations\":{d}," ++
            "\"acknowledged_successes\":{d}," ++
            "\"acknowledged_failures\":{d}," ++
            "\"reconciled_not_applied\":{d}," ++
            "\"reconciled_successes\":{d}," ++
            "\"reconciled_failures\":{d}," ++
            "\"ready_actions\":{d}," ++
            "\"uncertain_actions\":{d}," ++
            "\"succeeded_actions\":{d}," ++
            "\"failed_actions\":{d}}}}}\n",
        .{
            ledger.committed_records,
            ledger.actions_enqueued,
            ledger.primary_actions,
            ledger.compensation_actions,
            ledger.dispatch_intents,
            ledger.safe_retry_dispatches,
            ledger.ambiguity_observations,
            ledger.acknowledged_successes,
            ledger.acknowledged_failures,
            ledger.reconciled_not_applied,
            ledger.reconciled_successes,
            ledger.reconciled_failures,
            ledger.ready_actions,
            ledger.uncertain_actions,
            ledger.succeeded_actions,
            ledger.failed_actions,
        },
    );
    try writer.flush();
}
