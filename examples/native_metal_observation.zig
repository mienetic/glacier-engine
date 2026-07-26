//! Print one native macOS Metal readiness diagnostic.

const std = @import("std");
const engine = @import("engine");

pub fn main() !void {
    if (!engine.metal_enabled)
        return error.MetalReadinessRequiresNativeMetal;

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

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer {
        if (gpa.deinit() == .leak)
            @panic("native Metal readiness leaked allocator ownership");
    }
    var backend = try engine.MetalBackend.init(
        "zig-out/metal/shaders.metallib",
    );
    defer backend.deinit();
    const artifact = try engine.metal_native_observer.runReadinessV1(
        gpa.allocator(),
        &backend,
    );
    try engine.metal_native_observer.validateReadinessArtifactV1(
        artifact,
    );

    const descriptor_hex = std.fmt.bytesToHex(
        artifact.descriptor.descriptor_sha256,
        .lower,
    );
    const plan_descriptor_hex = std.fmt.bytesToHex(
        artifact.plan.observer_descriptor_sha256,
        .lower,
    );
    const report_descriptor_hex = std.fmt.bytesToHex(
        artifact.run.report.descriptor_sha256,
        .lower,
    );
    const diagnostic_descriptor_hex = std.fmt.bytesToHex(
        artifact.diagnostic.descriptor_sha256,
        .lower,
    );
    const workload_profile_hex = std.fmt.bytesToHex(
        artifact.plan.workload_profile_sha256,
        .lower,
    );
    const artifact_hex = std.fmt.bytesToHex(
        artifact.plan.artifact_sha256,
        .lower,
    );
    const build_hex = std.fmt.bytesToHex(
        artifact.plan.build_sha256,
        .lower,
    );
    const backend_hex = std.fmt.bytesToHex(
        artifact.plan.backend_sha256,
        .lower,
    );
    const machine_hex = std.fmt.bytesToHex(
        artifact.plan.machine_sha256,
        .lower,
    );
    const challenge_hex = std.fmt.bytesToHex(
        artifact.plan.challenge_sha256,
        .lower,
    );
    const plan_hex = std.fmt.bytesToHex(
        artifact.plan.plan_sha256,
        .lower,
    );
    const report_plan_hex = std.fmt.bytesToHex(
        artifact.run.report.plan_sha256,
        .lower,
    );
    const diagnostic_plan_hex = std.fmt.bytesToHex(
        artifact.diagnostic.plan_sha256,
        .lower,
    );
    const plan_device_hex = std.fmt.bytesToHex(
        artifact.plan.device_sha256,
        .lower,
    );
    const receipt_device_hex = std.fmt.bytesToHex(
        artifact.run.receipt.device_sha256,
        .lower,
    );
    const diagnostic_device_hex = std.fmt.bytesToHex(
        artifact.diagnostic.device_sha256,
        .lower,
    );
    const plan_placement_hex = std.fmt.bytesToHex(
        artifact.plan.placement_sha256,
        .lower,
    );
    const receipt_placement_hex = std.fmt.bytesToHex(
        artifact.run.receipt.placement_sha256,
        .lower,
    );
    const diagnostic_placement_hex = std.fmt.bytesToHex(
        artifact.diagnostic.placement_sha256,
        .lower,
    );
    const probe_hex = std.fmt.bytesToHex(
        artifact.run.probe.bundle_sha256,
        .lower,
    );
    const diagnostic_probe_hex = std.fmt.bytesToHex(
        artifact.diagnostic.probe_bundle_sha256,
        .lower,
    );
    const pre_run_hex = std.fmt.bytesToHex(
        artifact.run.pre_run.bundle_sha256,
        .lower,
    );
    const diagnostic_pre_run_hex = std.fmt.bytesToHex(
        artifact.diagnostic.pre_run_bundle_sha256,
        .lower,
    );
    const post_run_hex = std.fmt.bytesToHex(
        artifact.run.post_run.bundle_sha256,
        .lower,
    );
    const diagnostic_post_run_hex = std.fmt.bytesToHex(
        artifact.diagnostic.post_run_bundle_sha256,
        .lower,
    );
    const workload_receipt_hex = std.fmt.bytesToHex(
        artifact.run.receipt.receipt_sha256,
        .lower,
    );
    const report_workload_receipt_hex = std.fmt.bytesToHex(
        artifact.run.report.workload_receipt_sha256,
        .lower,
    );
    const diagnostic_workload_receipt_hex = std.fmt.bytesToHex(
        artifact.diagnostic.workload_receipt_sha256,
        .lower,
    );
    const run_report_hex = std.fmt.bytesToHex(
        artifact.run.report.report_sha256,
        .lower,
    );
    const diagnostic_run_report_hex = std.fmt.bytesToHex(
        artifact.diagnostic.run_report_sha256,
        .lower,
    );
    const dispatch_receipt_hex = std.fmt.bytesToHex(
        artifact.dispatch.receipt_sha256,
        .lower,
    );
    const diagnostic_dispatch_receipt_hex = std.fmt.bytesToHex(
        artifact.diagnostic.dispatch_receipt_sha256,
        .lower,
    );
    const output_hex = std.fmt.bytesToHex(
        artifact.dispatch.output_sha256,
        .lower,
    );
    const oracle_output_hex = std.fmt.bytesToHex(
        artifact.workload.oracle_output_sha256,
        .lower,
    );
    const correctness_hex = std.fmt.bytesToHex(
        artifact.run.receipt.correctness_sha256,
        .lower,
    );
    const ownership_hex = std.fmt.bytesToHex(
        artifact.run.receipt.ownership_sha256,
        .lower,
    );
    const diagnostic_report_hex = std.fmt.bytesToHex(
        artifact.diagnostic.report_sha256,
        .lower,
    );

    const device = artifact.device;
    const dispatch = artifact.dispatch;
    const diagnostic = artifact.diagnostic;
    const receipt = artifact.run.receipt;
    const report = artifact.run.report;

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(
        &stdout_buffer,
    );
    const writer = &stdout_writer.interface;
    try writer.print(
        "{{\"schema\":\"glacier.native-metal-readiness/macos-v1\"," ++
            "\"claim_class\":\"diagnostic\"," ++
            "\"performance_claim\":false," ++
            "\"decision\":\"{s}\"," ++
            "\"workload_status\":\"{s}\"," ++
            "\"correctness\":\"{s}\"," ++
            "\"zero_orphans\":\"{s}\"," ++
            "\"fallback\":\"{s}\"," ++
            "\"device_info_abi\":{d}," ++
            "\"device_registry_id\":{d}," ++
            "\"dispatch_device_registry_id\":{d}," ++
            "\"diagnostic_device_registry_id\":{d}," ++
            "\"recommended_max_working_set_size\":{d}," ++
            "\"device_location\":{d}," ++
            "\"device_location_number\":{d}," ++
            "\"device_max_threads_x\":{d}," ++
            "\"device_max_threads_y\":{d}," ++
            "\"device_max_threads_z\":{d}," ++
            "\"device_low_power\":{d}," ++
            "\"device_headless\":{d}," ++
            "\"device_removable\":{d}," ++
            "\"device_unified_memory\":{d},",
        .{
            @tagName(report.decision),
            @tagName(receipt.status),
            @tagName(receipt.correctness),
            @tagName(receipt.zero_orphans),
            @tagName(receipt.fallback),
            device.abi_version,
            device.registry_id,
            dispatch.device_registry_id,
            diagnostic.device_registry_id,
            device.recommended_max_working_set_size,
            device.location,
            device.location_number,
            device.max_threads_x,
            device.max_threads_y,
            device.max_threads_z,
            device.low_power,
            device.headless,
            device.removable,
            device.unified_memory,
        },
    );
    try writer.print(
        "\"logical_cpu_count\":{d}," ++
            "\"queue_count\":{d}," ++
            "\"direct_metric_bits\":{d}," ++
            "\"unsupported_metric_bits\":{d}," ++
            "\"missing_observation_count\":{d}," ++
            "\"unsupported_observation_count\":{d}," ++
            "\"unavailable_reason_count\":{d}," ++
            "\"present_reason_count\":{d}," ++
            "\"dispatch_ordinal\":{d}," ++
            "\"host_submit_ticks\":{d}," ++
            "\"host_complete_ticks\":{d}," ++
            "\"current_allocated_before\":{d}," ++
            "\"current_allocated_after\":{d}," ++
            "\"gpu_start_time_bits\":{d}," ++
            "\"gpu_end_time_bits\":{d}," ++
            "\"gpu_duration_nanoseconds\":{d}," ++
            "\"command_status\":{d}," ++
            "\"live_weights_after\":{d}," ++
            "\"workload_evidence_abi\":{d}," ++
            "\"max_abs_error_bits\":{d}," ++
            "\"live_weights_before\":{d}," ++
            "\"workload_live_weights_after\":{d}," ++
            "\"completed_dispatches_before\":{d}," ++
            "\"completed_dispatches_after\":{d}," ++
            "\"workload_invocations\":{d}," ++
            "\"profile_count\":{d}," ++
            "\"item_count\":{d},",
        .{
            diagnostic.logical_cpu_count,
            diagnostic.queue_count,
            diagnostic.direct_metric_bits,
            diagnostic.unsupported_metric_bits,
            diagnostic.missing_observation_count,
            diagnostic.unsupported_observation_count,
            diagnostic.unavailable_reason_count,
            diagnostic.present_reason_count,
            dispatch.dispatch_ordinal,
            dispatch.host_submit_ticks,
            dispatch.host_complete_ticks,
            dispatch.current_allocated_before,
            dispatch.current_allocated_after,
            dispatch.gpu_start_time_bits,
            dispatch.gpu_end_time_bits,
            dispatch.gpu_duration_nanoseconds,
            dispatch.command_status,
            dispatch.live_weights_after,
            artifact.workload.abi_version,
            artifact.workload.max_abs_error_bits,
            artifact.workload.live_weights_before,
            artifact.workload.live_weights_after,
            artifact.workload.completed_dispatches_before,
            artifact.workload.completed_dispatches_after,
            report.workload_invocations,
            receipt.profile_count,
            receipt.item_count,
        },
    );
    try writer.print(
        "\"unsupported_metrics\":[" ++
            "\"accelerator_utilization\"," ++
            "\"accelerator_committed_bytes\"," ++
            "\"accelerator_resident_bytes\"," ++
            "\"accelerator_queue_depth\"," ++
            "\"accelerator_temperature\"," ++
            "\"accelerator_frequency\"," ++
            "\"accelerator_power\"," ++
            "\"accelerator_energy\"]," ++
            "\"output_sha256\":\"{s}\"," ++
            "\"descriptor_sha256\":\"{s}\"," ++
            "\"plan_descriptor_sha256\":\"{s}\"," ++
            "\"report_descriptor_sha256\":\"{s}\"," ++
            "\"diagnostic_descriptor_sha256\":\"{s}\"," ++
            "\"workload_profile_sha256\":\"{s}\"," ++
            "\"artifact_sha256\":\"{s}\"," ++
            "\"build_sha256\":\"{s}\"," ++
            "\"backend_sha256\":\"{s}\"," ++
            "\"machine_sha256\":\"{s}\"," ++
            "\"challenge_sha256\":\"{s}\",",
        .{
            &output_hex,
            &descriptor_hex,
            &plan_descriptor_hex,
            &report_descriptor_hex,
            &diagnostic_descriptor_hex,
            &workload_profile_hex,
            &artifact_hex,
            &build_hex,
            &backend_hex,
            &machine_hex,
            &challenge_hex,
        },
    );
    try writer.print(
        "\"plan_sha256\":\"{s}\"," ++
            "\"report_plan_sha256\":\"{s}\"," ++
            "\"diagnostic_plan_sha256\":\"{s}\"," ++
            "\"plan_device_sha256\":\"{s}\"," ++
            "\"receipt_device_sha256\":\"{s}\"," ++
            "\"diagnostic_device_sha256\":\"{s}\"," ++
            "\"plan_placement_sha256\":\"{s}\"," ++
            "\"receipt_placement_sha256\":\"{s}\"," ++
            "\"diagnostic_placement_sha256\":\"{s}\"," ++
            "\"probe_bundle_sha256\":\"{s}\"," ++
            "\"diagnostic_probe_bundle_sha256\":\"{s}\"," ++
            "\"pre_run_bundle_sha256\":\"{s}\"," ++
            "\"diagnostic_pre_run_bundle_sha256\":\"{s}\"," ++
            "\"post_run_bundle_sha256\":\"{s}\"," ++
            "\"diagnostic_post_run_bundle_sha256\":\"{s}\",",
        .{
            &plan_hex,
            &report_plan_hex,
            &diagnostic_plan_hex,
            &plan_device_hex,
            &receipt_device_hex,
            &diagnostic_device_hex,
            &plan_placement_hex,
            &receipt_placement_hex,
            &diagnostic_placement_hex,
            &probe_hex,
            &diagnostic_probe_hex,
            &pre_run_hex,
            &diagnostic_pre_run_hex,
            &post_run_hex,
            &diagnostic_post_run_hex,
        },
    );
    try writer.print(
        "\"workload_receipt_sha256\":\"{s}\"," ++
            "\"report_workload_receipt_sha256\":\"{s}\"," ++
            "\"diagnostic_workload_receipt_sha256\":\"{s}\"," ++
            "\"run_report_sha256\":\"{s}\"," ++
            "\"diagnostic_run_report_sha256\":\"{s}\"," ++
            "\"dispatch_receipt_sha256\":\"{s}\"," ++
            "\"diagnostic_dispatch_receipt_sha256\":\"{s}\"," ++
            "\"oracle_output_sha256\":\"{s}\"," ++
            "\"correctness_sha256\":\"{s}\"," ++
            "\"ownership_sha256\":\"{s}\"," ++
            "\"report_sha256\":\"{s}\"}}\n",
        .{
            &workload_receipt_hex,
            &report_workload_receipt_hex,
            &diagnostic_workload_receipt_hex,
            &run_report_hex,
            &diagnostic_run_report_hex,
            &dispatch_receipt_hex,
            &diagnostic_dispatch_receipt_hex,
            &oracle_output_hex,
            &correctness_hex,
            &ownership_hex,
            &diagnostic_report_hex,
        },
    );
    try writer.flush();
}
