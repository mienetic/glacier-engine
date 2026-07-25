//! Canonical model-free deterministic closed-loop workload report.

const std = @import("std");
const core = @import("core");
const closed_loop = core.workload_closed_loop;
const resource_bank = core.resource_bank;

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

    var candidates = closed_loop.makeReferenceCandidatesV1();
    const plan = closed_loop.referencePlanV1(&candidates);
    var storage: closed_loop.MaximumStorageV1 = .{};
    var result: closed_loop.ResultV1 = undefined;
    try closed_loop.runPlanV1(plan, storage.interface(), &result);
    try closed_loop.validateResultStructureV1(plan, result);

    const maximum_plan_wire_bytes =
        closed_loop.plan_header_bytes +
        closed_loop.maximum_candidates * closed_loop.candidate_record_bytes +
        closed_loop.plan_footer_bytes;
    const maximum_result_wire_bytes =
        closed_loop.result_header_bytes +
        closed_loop.maximum_candidates * closed_loop.outcome_record_bytes +
        closed_loop.maximum_trace_records * closed_loop.trace_record_bytes +
        closed_loop.summary_record_bytes +
        closed_loop.result_footer_bytes;
    var plan_wire_storage: [maximum_plan_wire_bytes]u8 = undefined;
    const plan_wire = try closed_loop.encodePlanV1(
        plan,
        &plan_wire_storage,
    );
    var result_wire_storage: [maximum_result_wire_bytes]u8 = undefined;
    const result_wire = try closed_loop.encodeResultV1(
        plan,
        result,
        &result_wire_storage,
    );
    var plan_wire_sha256: closed_loop.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        plan_wire,
        &plan_wire_sha256,
        .{},
    );
    var result_wire_sha256: closed_loop.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        result_wire,
        &result_wire_sha256,
        .{},
    );
    const plan_wire_hex = std.fmt.bytesToHex(
        plan_wire_sha256,
        .lower,
    );
    const result_wire_hex = std.fmt.bytesToHex(
        result_wire_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(result.plan_sha256, .lower);
    const outcome_hex = std.fmt.bytesToHex(
        result.outcome_sha256,
        .lower,
    );
    const trace_hex = std.fmt.bytesToHex(result.trace_sha256, .lower);
    const summary_hex = std.fmt.bytesToHex(
        result.summary_sha256,
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(result.result_sha256, .lower);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.workload-closed-loop/v1\"," ++
            "\"plan_abi\":\"{x:0>16}\"," ++
            "\"result_abi\":\"{x:0>16}\"," ++
            "\"trace_abi\":\"{x:0>16}\"," ++
            "\"summary_abi\":\"{x:0>16}\"," ++
            "\"candidate_abi\":\"{x:0>16}\"," ++
            "\"outcome_abi\":\"{x:0>16}\"," ++
            "\"candidate_count\":{d},\"trace_count\":{d}," ++
            "\"plan_wire_bytes\":{d},\"result_wire_bytes\":{d}," ++
            "\"plan_wire_sha256\":\"{s}\"," ++
            "\"result_wire_sha256\":\"{s}\"," ++
            "\"plan_sha256\":\"{s}\"," ++
            "\"outcome_sha256\":\"{s}\"," ++
            "\"trace_sha256\":\"{s}\"," ++
            "\"summary_sha256\":\"{s}\"," ++
            "\"result_sha256\":\"{s}\",\"summary\":",
        .{
            closed_loop.plan_abi,
            closed_loop.result_abi,
            closed_loop.trace_abi,
            closed_loop.summary_abi,
            closed_loop.candidate_abi,
            closed_loop.outcome_abi,
            result.outcomes.len,
            result.trace.len,
            plan_wire.len,
            result_wire.len,
            &plan_wire_hex,
            &result_wire_hex,
            &plan_hex,
            &outcome_hex,
            &trace_hex,
            &summary_hex,
            &result_hex,
        },
    );
    try writeSummary(writer, result.summary);
    try writer.writeAll(",\"outcomes\":[");
    for (result.outcomes, 0..) |outcome, index| {
        if (index != 0) try writer.writeByte(',');
        try writeOutcome(writer, outcome);
    }
    try writer.writeAll("]}\n");
    try writer.flush();
}

fn writeSummary(
    writer: anytype,
    summary: closed_loop.SummaryV1,
) !void {
    try writer.print(
        "{{\"in_flight_target\":{d},\"capacity\":{d}," ++
            "\"candidate_budget\":{d},\"attempted\":{d}," ++
            "\"admitted\":{d},\"rejected\":{d}," ++
            "\"completed\":{d},\"cancelled\":{d}," ++
            "\"timed_out\":{d},\"service_quanta\":{d}," ++
            "\"driver_steps\":{d},\"final_logical_tick\":{d}," ++
            "\"maximum_active\":{d},\"maximum_due_credits\":{d}," ++
            "\"maximum_live_receipts\":{d}," ++
            "\"replacement_attempts\":{d}," ++
            "\"replacements_after_completed\":{d}," ++
            "\"replacements_after_rejected\":{d}," ++
            "\"replacements_after_cancelled\":{d}," ++
            "\"replacements_after_timed_out\":{d}," ++
            "\"credits_sealed\":{d},\"credits_exhausted\":{d}," ++
            "\"lineage_count\":{d}," ++
            "\"maximum_lineage_generation\":{d}," ++
            "\"peak_host_bytes\":{d},\"peak\":",
        .{
            summary.in_flight_target,
            summary.capacity,
            summary.candidate_budget,
            summary.attempted,
            summary.admitted,
            summary.rejected,
            summary.completed,
            summary.cancelled,
            summary.timed_out,
            summary.service_quanta,
            summary.driver_steps,
            summary.final_logical_tick,
            summary.maximum_active,
            summary.maximum_due_credits,
            summary.maximum_live_receipts,
            summary.replacement_attempts,
            summary.replacements_after_completed,
            summary.replacements_after_rejected,
            summary.replacements_after_cancelled,
            summary.replacements_after_timed_out,
            summary.credits_sealed,
            summary.credits_exhausted,
            summary.lineage_count,
            summary.maximum_lineage_generation,
            summary.peak_host_bytes,
        },
    );
    try writeClaim(writer, summary.peak);
    try writer.print(
        ",\"maximum_wait_quanta\":{d}," ++
            "\"maximum_service_gap\":{d}," ++
            "\"fairness_cross_product_error\":{d}," ++
            "\"final_active\":{d},\"final_due_credits\":{d}," ++
            "\"final_finished\":{d}," ++
            "\"final_active_reservations\":{d}," ++
            "\"final_committed_receipts\":{d}," ++
            "\"successful_commits\":{d},\"releases\":{d}," ++
            "\"bank_cancellations\":{d}," ++
            "\"bank_rejected_capacity\":{d}," ++
            "\"bank_rejected_slots\":{d}," ++
            "\"zero_orphan_ownership\":{s}}}",
        .{
            summary.maximum_wait_quanta,
            summary.maximum_service_gap,
            summary.fairness_cross_product_error,
            summary.final_active,
            summary.final_due_credits,
            summary.final_finished,
            summary.final_active_reservations,
            summary.final_committed_receipts,
            summary.successful_commits,
            summary.releases,
            summary.bank_cancellations,
            summary.bank_rejected_capacity,
            summary.bank_rejected_slots,
            boolJson(summary.zero_orphan_ownership),
        },
    );
}

fn writeClaim(
    writer: anytype,
    claim: resource_bank.Claim,
) !void {
    try writer.print(
        "{{\"capsule_bytes\":{d},\"kv_bytes\":{d}," ++
            "\"activation_bytes\":{d},\"partial_bytes\":{d}," ++
            "\"logits_bytes\":{d},\"output_journal_bytes\":{d}," ++
            "\"staging_bytes\":{d},\"device_bytes\":{d}," ++
            "\"io_bytes\":{d},\"queue_slots\":{d}}}",
        .{
            claim.capsule_bytes,
            claim.kv_bytes,
            claim.activation_bytes,
            claim.partial_bytes,
            claim.logits_bytes,
            claim.output_journal_bytes,
            claim.staging_bytes,
            claim.device_bytes,
            claim.io_bytes,
            claim.queue_slots,
        },
    );
}

fn writeOutcome(
    writer: anytype,
    outcome: closed_loop.OutcomeV1,
) !void {
    const candidate_hex = std.fmt.bytesToHex(
        outcome.candidate_sha256,
        .lower,
    );
    const record_hex = std.fmt.bytesToHex(
        outcome.record_sha256,
        .lower,
    );
    const trigger_trace_hex = std.fmt.bytesToHex(
        outcome.trigger_trace_sha256,
        .lower,
    );
    const trigger_credit_hex = std.fmt.bytesToHex(
        outcome.trigger_credit_sha256,
        .lower,
    );
    const admission_trace_hex = std.fmt.bytesToHex(
        outcome.admission_trace_sha256,
        .lower,
    );
    const terminal_trace_hex = std.fmt.bytesToHex(
        outcome.terminal_trace_sha256,
        .lower,
    );
    try writer.print(
        "{{\"ordinal\":{d},\"candidate_sha256\":\"{s}\"," ++
            "\"lineage_index\":{d},\"lineage_generation\":{d}," ++
            "\"predecessor_ordinal\":",
        .{
            outcome.ordinal,
            &candidate_hex,
            outcome.lineage_index,
            outcome.lineage_generation,
        },
    );
    try writeOptionalU64(writer, outcome.predecessor_ordinal);
    try writer.print(
        ",\"trigger_kind\":\"{s}\",\"trigger_terminal_step\":",
        .{@tagName(outcome.trigger_kind)},
    );
    try writeOptionalU64(writer, outcome.trigger_terminal_step);
    try writer.print(
        ",\"trigger_trace_sha256\":\"{s}\"," ++
            "\"trigger_credit_sha256\":\"{s}\"," ++
            "\"submission_step\":{d},\"scheduler_slot_index\":",
        .{
            &trigger_trace_hex,
            &trigger_credit_hex,
            outcome.submission_step,
        },
    );
    try writeOptionalU64(writer, outcome.scheduler_slot_index);
    try writer.print(
        ",\"scheduler_slot_generation\":{d}," ++
            "\"kind\":\"{s}\",\"rejection_reason\":\"{s}\"," ++
            "\"terminal_action\":\"{s}\",\"admitted_step\":",
        .{
            outcome.scheduler_slot_generation,
            @tagName(outcome.kind),
            @tagName(outcome.rejection_reason),
            @tagName(outcome.terminal_action),
        },
    );
    try writeOptionalU64(writer, outcome.admitted_step);
    try writer.writeAll(",\"first_service_step\":");
    try writeOptionalU64(writer, outcome.first_service_step);
    try writer.print(
        ",\"terminal_step\":{d},\"served_quanta\":{d}," ++
            "\"maximum_wait_quanta\":{d}," ++
            "\"admission_trace_sha256\":\"{s}\"," ++
            "\"terminal_trace_sha256\":\"{s}\"," ++
            "\"record_sha256\":\"{s}\"}}",
        .{
            outcome.terminal_step,
            outcome.served_quanta,
            outcome.maximum_wait_quanta,
            &admission_trace_hex,
            &terminal_trace_hex,
            &record_hex,
        },
    );
}

fn writeOptionalU64(writer: anytype, value: u64) !void {
    if (value == closed_loop.absent) {
        try writer.writeAll("null");
    } else {
        try writer.print("{d}", .{value});
    }
}

fn boolJson(value: bool) []const u8 {
    return if (value) "true" else "false";
}
