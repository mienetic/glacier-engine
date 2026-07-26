//! Canonical deterministic ActionOutbox storage conformance report.

const std = @import("std");
const core = @import("core");
const conformance =
    core.tool_action_outbox_store_conformance;

pub fn main() !void {
    var argument_allocator =
        std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer argument_allocator.deinit();
    var args = try std.process.argsWithAllocator(
        argument_allocator.allocator(),
    );
    defer args.deinit();
    _ = args.next();
    if (args.next() != null) return error.UnexpectedArgument;

    var storage: conformance.ReferenceStorageV1 = .{};
    const report =
        try conformance.runReferenceCampaignV1(&storage);
    const roots = .{
        std.fmt.bytesToHex(report.header_sha256, .lower),
        std.fmt.bytesToHex(
            report.protocol_report_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.journal_sha256, .lower),
        std.fmt.bytesToHex(
            report.initial_snapshot_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.uncertain_snapshot_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.final_snapshot_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.append_phase_matrix_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.partial_write_matrix_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.repair_tail_matrix_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.repair_fault_matrix_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.final_chain_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(
            report.final_state_sha256,
            .lower,
        ),
        std.fmt.bytesToHex(report.ledger_sha256, .lower),
        std.fmt.bytesToHex(report.report_sha256, .lower),
    };

    var stdout_buffer: [32 * 1024]u8 = undefined;
    var stdout_writer =
        std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.action-outbox-store-conformance/v1\"," ++
            "\"report_abi\":\"{x:0>16}\"," ++
            "\"store_abi\":\"{x:0>16}\"," ++
            "\"protocol_report_abi\":\"{x:0>16}\"," ++
            "\"header_bytes\":{d}," ++
            "\"record_body_bytes\":{d}," ++
            "\"commit_footer_bytes\":{d}," ++
            "\"record_bytes\":{d}," ++
            "\"maximum_file_bytes\":{d}," ++
            "\"journal_bytes\":{d}," ++
            "\"record_count\":{d}," ++
            "\"action_count\":{d}," ++
            "\"append_phase_case_count\":{d}," ++
            "\"partial_write_case_count\":{d}," ++
            "\"repair_tail_case_count\":{d}," ++
            "\"repair_fault_case_count\":{d}," ++
            "\"header_sha256\":\"{s}\"," ++
            "\"protocol_report_sha256\":\"{s}\"," ++
            "\"journal_sha256\":\"{s}\"," ++
            "\"initial_snapshot_sha256\":\"{s}\"," ++
            "\"uncertain_snapshot_sha256\":\"{s}\"," ++
            "\"final_snapshot_sha256\":\"{s}\"," ++
            "\"append_phase_matrix_sha256\":\"{s}\"," ++
            "\"partial_write_matrix_sha256\":\"{s}\"," ++
            "\"repair_tail_matrix_sha256\":\"{s}\"," ++
            "\"repair_fault_matrix_sha256\":\"{s}\"," ++
            "\"final_chain_sha256\":\"{s}\"," ++
            "\"final_state_sha256\":\"{s}\"," ++
            "\"ledger_sha256\":\"{s}\"," ++
            "\"report_sha256\":\"{s}\"," ++
            "\"append_phases\":[",
        .{
            report.abi_version,
            report.store_abi,
            report.protocol_report_abi,
            report.header_bytes,
            report.record_body_bytes,
            report.commit_footer_bytes,
            report.record_bytes,
            report.maximum_file_bytes,
            report.journal_bytes,
            report.record_count,
            report.action_count,
            report.append_phase_case_count,
            report.partial_write_case_count,
            report.repair_tail_case_count,
            report.repair_fault_case_count,
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
        },
    );
    for (report.append_phase_order, 0..) |phase, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{@tagName(phase)});
    }
    try writer.writeAll("],\"repair_phases\":[");
    for (report.repair_phase_order, 0..) |phase, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{@tagName(phase)});
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
