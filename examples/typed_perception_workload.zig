//! Canonical download-free mixed typed-perception workload report.

const std = @import("std");
const core = @import("core");
const contract = core.typed_workload_contract;
const driver = core.typed_workload_driver;
const perception = core.typed_perception_workload;

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

    var storage = try perception.ReferenceStorageV1.init();
    const campaign = try perception.runReferenceCampaignV1(&storage);
    var replay_storage: driver.MaximumStorageV1 = .{};
    try perception.validateEvidenceByReplayV1(
        campaign.plan,
        campaign.driver_result,
        campaign.evidence,
        replay_storage.interface(),
    );

    var plan_storage: [contract.maximum_plan_bytes]u8 = undefined;
    const plan_wire = try contract.encodePlanV1(
        campaign.plan,
        &plan_storage,
    );
    var plan_wire_sha256: contract.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(
        plan_wire,
        &plan_wire_sha256,
        .{},
    );

    const plan_wire_hex = std.fmt.bytesToHex(
        plan_wire_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(
        campaign.driver_result.plan_sha256,
        .lower,
    );
    const outcome_hex = std.fmt.bytesToHex(
        campaign.driver_result.outcome_sha256,
        .lower,
    );
    const trace_hex = std.fmt.bytesToHex(
        campaign.driver_result.trace_sha256,
        .lower,
    );
    const driver_summary_hex = std.fmt.bytesToHex(
        campaign.driver_result.summary_sha256,
        .lower,
    );
    const result_hex = std.fmt.bytesToHex(
        campaign.driver_result.result_sha256,
        .lower,
    );
    const item_section_hex = std.fmt.bytesToHex(
        campaign.evidence.item_section_sha256,
        .lower,
    );
    const evidence_summary_hex = std.fmt.bytesToHex(
        campaign.evidence.evidence_summary_sha256,
        .lower,
    );
    const evidence_hex = std.fmt.bytesToHex(
        campaign.evidence.evidence_sha256,
        .lower,
    );

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.typed-workload-conformance/v1\"," ++
            "\"plan_abi\":\"{x:0>16}\"," ++
            "\"profile_abi\":\"{x:0>16}\"," ++
            "\"item_abi\":\"{x:0>16}\"," ++
            "\"driver_result_abi\":\"{x:0>16}\"," ++
            "\"driver_outcome_abi\":\"{x:0>16}\"," ++
            "\"driver_trace_abi\":\"{x:0>16}\"," ++
            "\"driver_summary_abi\":\"{x:0>16}\"," ++
            "\"evidence_abi\":\"{x:0>16}\"," ++
            "\"item_evidence_abi\":\"{x:0>16}\"," ++
            "\"evidence_summary_abi\":\"{x:0>16}\"," ++
            "\"profile_count\":{d},\"item_count\":{d}," ++
            "\"trace_count\":{d},\"plan_wire_bytes\":{d}," ++
            "\"plan_wire_sha256\":\"{s}\"," ++
            "\"plan_sha256\":\"{s}\"," ++
            "\"outcome_sha256\":\"{s}\"," ++
            "\"trace_sha256\":\"{s}\"," ++
            "\"summary_sha256\":\"{s}\"," ++
            "\"result_sha256\":\"{s}\"," ++
            "\"item_section_sha256\":\"{s}\"," ++
            "\"evidence_summary_sha256\":\"{s}\"," ++
            "\"evidence_sha256\":\"{s}\",\"outcomes\":[",
        .{
            contract.plan_abi,
            contract.profile_abi,
            contract.item_abi,
            driver.result_abi,
            driver.outcome_abi,
            driver.trace_abi,
            driver.summary_abi,
            perception.evidence_abi,
            perception.item_evidence_abi,
            perception.summary_abi,
            campaign.plan.profiles.len,
            campaign.plan.items.len,
            campaign.driver_result.trace.len,
            plan_wire.len,
            &plan_wire_hex,
            &plan_hex,
            &outcome_hex,
            &trace_hex,
            &driver_summary_hex,
            &result_hex,
            &item_section_hex,
            &evidence_summary_hex,
            &evidence_hex,
        },
    );
    for (campaign.driver_result.outcomes, 0..) |outcome, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("\"{s}\"", .{@tagName(outcome.kind)});
    }
    try writer.writeAll("],\"driver_summary\":");
    try writeDriverSummary(writer, campaign.driver_result.summary);
    try writer.writeAll(",\"evidence_summary\":");
    try writeEvidenceSummary(writer, campaign.evidence.summary);
    try writer.writeAll("}\n");
    try writer.flush();
}

fn writeDriverSummary(
    writer: anytype,
    summary: driver.SummaryV1,
) !void {
    try writer.print(
        "{{\"profile_count\":{d},\"item_count\":{d}," ++
            "\"attempted\":{d},\"admitted\":{d}," ++
            "\"rejected\":{d},\"completed\":{d}," ++
            "\"cancelled\":{d},\"timed_out\":{d}," ++
            "\"service_quanta\":{d},\"driver_steps\":{d}," ++
            "\"final_logical_tick\":{d}," ++
            "\"maximum_live_receipts\":{d}," ++
            "\"peak_host_bytes\":{d},\"peak\":",
        .{
            summary.profile_count,
            summary.item_count,
            summary.attempted,
            summary.admitted,
            summary.rejected,
            summary.completed,
            summary.cancelled,
            summary.timed_out,
            summary.service_quanta,
            summary.driver_steps,
            summary.final_logical_tick,
            summary.maximum_live_receipts,
            summary.peak_host_bytes,
        },
    );
    try writeClaim(writer, summary.peak);
    try writer.print(
        ",\"maximum_wait_quanta\":{d}," ++
            "\"maximum_service_gap\":{d}," ++
            "\"fairness_cross_product_error\":{d}," ++
            "\"bind_callbacks\":{d},\"cancel_callbacks\":{d}," ++
            "\"service_callbacks\":{d}," ++
            "\"final_service_callbacks\":{d}," ++
            "\"retire_callbacks\":{d},\"final_active\":{d}," ++
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
            summary.bind_callbacks,
            summary.cancel_callbacks,
            summary.service_callbacks,
            summary.final_service_callbacks,
            summary.retire_callbacks,
            summary.final_active,
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

fn writeEvidenceSummary(
    writer: anytype,
    summary: perception.SummaryV1,
) !void {
    try writer.print(
        "{{\"profile_count\":{d},\"item_count\":{d}," ++
            "\"admitted\":{d},\"rejected\":{d}," ++
            "\"completed\":{d},\"cancelled\":{d}," ++
            "\"timed_out\":{d},\"vision_completed\":{d}," ++
            "\"audio_window_completed\":{d}," ++
            "\"temporal_video_completed\":{d}," ++
            "\"publications\":{d}," ++
            "\"nonpublished_terminal_items\":{d}," ++
            "\"cache_restores\":{d},\"cache_closures\":{d}," ++
            "\"cache_successful_commits\":{d}," ++
            "\"cache_releases\":{d}," ++
            "\"cache_live_allocations\":{d}," ++
            "\"model_successful_commits\":{d}," ++
            "\"model_releases\":{d}," ++
            "\"model_final_active_reservations\":{d}," ++
            "\"model_final_committed_receipts\":{d}," ++
            "\"zero_model_ownership\":{s}," ++
            "\"zero_cache_ownership\":{s}," ++
            "\"zero_orphan_ownership\":{s}}}",
        .{
            summary.profile_count,
            summary.item_count,
            summary.admitted,
            summary.rejected,
            summary.completed,
            summary.cancelled,
            summary.timed_out,
            summary.vision_completed,
            summary.audio_window_completed,
            summary.temporal_video_completed,
            summary.publications,
            summary.nonpublished_terminal_items,
            summary.cache_restores,
            summary.cache_closures,
            summary.cache_successful_commits,
            summary.cache_releases,
            summary.cache_live_allocations,
            summary.model_successful_commits,
            summary.model_releases,
            summary.model_final_active_reservations,
            summary.model_final_committed_receipts,
            boolJson(summary.zero_model_ownership),
            boolJson(summary.zero_cache_ownership),
            boolJson(summary.zero_orphan_ownership),
        },
    );
}

fn writeClaim(
    writer: anytype,
    claim: core.resource_bank.Claim,
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

fn boolJson(value: bool) []const u8 {
    return if (value) "true" else "false";
}
