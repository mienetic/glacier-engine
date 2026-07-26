//! Pure composition tests for the native Metal readiness artifact.
//!
//! The hard gate's only real GPU dispatch belongs to the independently
//! verified CLI. These tests exercise mutation and composition semantics with
//! synthetic, fully hashed evidence and must never initialize Metal.

const std = @import("std");
const engine = @import("engine");

const testing = std.testing;
const contract = engine.native_observation_contract;
const runner = engine.native_observation_runner;
const native = engine.metal_native_observer;

const SyntheticObserver = struct {
    device: engine.metal_backend.MetalDeviceInfo,
    dispatch: native.DispatchReceiptV1,
    transition_count: usize = 0,

    fn interface(
        self: *SyntheticObserver,
        descriptor: contract.DescriptorV1,
    ) runner.ObserverV1 {
        return .{
            .context = self,
            .descriptor = descriptor,
            .collect_fn = collect,
            .transition_fn = transition,
        };
    }

    fn collect(
        context_ptr: *anyopaque,
        descriptor: *const contract.DescriptorV1,
        plan: *const contract.PlanV1,
        phase: contract.PhaseV1,
        output: *[contract.maximum_observations]contract.ObservationV1,
    ) runner.CallbackError!usize {
        const self: *SyntheticObserver = @ptrCast(
            @alignCast(context_ptr),
        );
        const observed_at: u64 = switch (phase) {
            .probe => 100,
            .pre_run => 200,
            .post_run => 300,
            else => return runner.CallbackError.InvalidSample,
        };
        const host_clock = contract.digestV1(
            "std.time.Timer monotonic ticks/v1",
        );
        const host_source = contract.digestV1(
            "std.Thread.getCpuCount+std.time.Timer/v1",
        );
        const metal_source = native.sourceIdentityV1();
        var observed_device = self.device;
        observed_device.current_allocated_size = 4096;
        const phase_provenance =
            native.observationProvenanceV1(
                phase,
                observed_at,
                observed_device,
                if (phase == .post_run)
                    self.dispatch.receipt_sha256
                else
                    contract.zero_digest,
            );
        const host_provenance = native.hostProvenanceV1(
            phase,
            observed_at,
            8,
        );
        var count: usize = 0;
        add(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .host_monotonic_time,
            .present,
            @intCast(observed_at),
            observed_at,
            host_clock,
            host_clock,
            host_source,
            host_provenance,
            plan.machine_sha256,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        add(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .host_logical_cpu_count,
            .present,
            8,
            observed_at,
            host_clock,
            contract.zero_digest,
            host_source,
            host_provenance,
            plan.machine_sha256,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        addMetal(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .accelerator_device_present,
            .present,
            1,
            observed_at,
            host_clock,
            metal_source,
            phase_provenance,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        addMetal(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .accelerator_cpu_fallback,
            .present,
            0,
            observed_at,
            host_clock,
            metal_source,
            phase_provenance,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        inline for ([_]struct {
            metric: contract.MetricIdV1,
            reason: []const u8,
        }{
            .{
                .metric = .accelerator_utilization,
                .reason = "Metal utilization has no direct adapter/v1",
            },
        }) |unavailable| {
            addUnsupported(
                output,
                &count,
                descriptor.*,
                plan.*,
                phase,
                unavailable.metric,
                unavailable.reason,
                observed_at,
                host_clock,
                metal_source,
                phase_provenance,
            ) catch return runner.CallbackError.InvalidSample;
        }
        addMetal(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .accelerator_allocated_bytes,
            .present,
            4096,
            observed_at,
            host_clock,
            metal_source,
            phase_provenance,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        inline for ([_]struct {
            metric: contract.MetricIdV1,
            reason: []const u8,
        }{
            .{
                .metric = .accelerator_committed_bytes,
                .reason = "Metal committed memory has no direct adapter/v1",
            },
            .{
                .metric = .accelerator_resident_bytes,
                .reason = "Metal residency has no direct adapter/v1",
            },
            .{
                .metric = .accelerator_queue_depth,
                .reason = "Metal queue occupancy has no direct adapter/v1",
            },
            .{
                .metric = .accelerator_temperature,
                .reason = "Metal temperature has no direct adapter/v1",
            },
            .{
                .metric = .accelerator_frequency,
                .reason = "Metal frequency has no direct adapter/v1",
            },
            .{
                .metric = .accelerator_power,
                .reason = "Metal power has no direct adapter/v1",
            },
            .{
                .metric = .accelerator_energy,
                .reason = "Metal energy has no direct adapter/v1",
            },
        }) |unavailable| {
            addUnsupported(
                output,
                &count,
                descriptor.*,
                plan.*,
                phase,
                unavailable.metric,
                unavailable.reason,
                observed_at,
                host_clock,
                metal_source,
                phase_provenance,
            ) catch return runner.CallbackError.InvalidSample;
        }
        if (phase == .post_run) {
            add(
                output,
                &count,
                descriptor.*,
                plan.*,
                phase,
                .accelerator_device_time,
                .present,
                @intCast(self.dispatch.gpu_duration_nanoseconds),
                observed_at,
                host_clock,
                contract.digestV1(
                    "Metal MTLCommandBuffer GPUStartTime GPUEndTime host time/v1",
                ),
                metal_source,
                self.dispatch.receipt_sha256,
                plan.device_sha256,
                contract.zero_digest,
            ) catch return runner.CallbackError.InvalidSample;
        } else {
            addMetal(
                output,
                &count,
                descriptor.*,
                plan.*,
                phase,
                .accelerator_device_time,
                .missing,
                0,
                observed_at,
                host_clock,
                metal_source,
                phase_provenance,
                contract.digestV1(
                    "No completed Metal command buffer in this phase/v1",
                ),
            ) catch return runner.CallbackError.InvalidSample;
        }
        return count;
    }

    fn transition(
        context_ptr: *anyopaque,
        phase: contract.PhaseV1,
    ) runner.CallbackError!void {
        const self: *SyntheticObserver = @ptrCast(
            @alignCast(context_ptr),
        );
        const expected: contract.PhaseV1 =
            if (self.transition_count == 0) .begin else .end;
        if (self.transition_count >= 2 or phase != expected)
            return runner.CallbackError.InvalidSample;
        self.transition_count += 1;
    }
};

const SyntheticWorkload = struct {
    dispatch: native.DispatchReceiptV1,
    evidence: native.WorkloadEvidenceV1,
    invocations: usize = 0,

    fn interface(self: *SyntheticWorkload) runner.WorkloadV1 {
        return .{
            .context = self,
            .run_fn = run,
        };
    }

    fn run(
        context_ptr: *anyopaque,
        plan: *const contract.PlanV1,
    ) runner.CallbackError!runner.WorkloadReceiptV1 {
        const self: *SyntheticWorkload = @ptrCast(
            @alignCast(context_ptr),
        );
        if (self.invocations != 0)
            return runner.CallbackError.InjectedFailure;
        self.invocations = 1;
        return runner.makeWorkloadReceiptV1(
            plan.*,
            .succeeded,
            .passed,
            .passed,
            .absent,
            1,
            1,
            native.workloadResultIdentityV1(
                self.dispatch.output_sha256,
                self.dispatch.receipt_sha256,
            ),
            native.correctnessIdentityV1(
                self.evidence,
                self.dispatch.output_sha256,
            ),
            native.ownershipIdentityV1(self.evidence),
        ) catch return runner.CallbackError.InjectedFailure;
    }
};

test "synthetic Metal readiness artifact composes fail closed" {
    const artifact = try syntheticArtifact();
    try native.validateReadinessArtifactV1(artifact);
}

test "cross-root substitution is rejected after local rehash" {
    var artifact = try syntheticArtifact();
    artifact.diagnostic.dispatch_receipt_sha256 =
        contract.digestV1("substituted dispatch receipt/v1");
    artifact.diagnostic.report_sha256 =
        native.diagnosticReportSha256V1(artifact.diagnostic);
    try testing.expectError(
        error.InvalidReadinessArtifact,
        native.validateReadinessArtifactV1(artifact),
    );
}

test "raw dynamic device allocation substitution is rejected" {
    var artifact = try syntheticArtifact();
    const stable_identity = native.deviceIdentityV1(artifact.device);
    artifact.device.current_allocated_size += 1;
    try testing.expect(contract.digestEqual(
        stable_identity,
        native.deviceIdentityV1(artifact.device),
    ));
    try testing.expectError(
        error.InvalidReadinessArtifact,
        native.validateReadinessArtifactV1(artifact),
    );
}

test "correctness evidence tampering fails after outer rehash" {
    var artifact = try syntheticArtifact();
    artifact.workload.max_abs_error_bits =
        @bitCast(@as(f32, 0.00001));
    artifact.run.receipt.correctness_sha256 =
        native.correctnessIdentityV1(
            artifact.workload,
            artifact.dispatch.output_sha256,
        );
    rehashReceiptOuter(&artifact);
    try testing.expectError(
        error.InvalidReadinessArtifact,
        native.validateReadinessArtifactV1(artifact),
    );
}

test "ownership evidence tampering fails after outer rehash" {
    var artifact = try syntheticArtifact();
    artifact.workload.live_weights_after = 1;
    artifact.run.receipt.ownership_sha256 =
        native.ownershipIdentityV1(artifact.workload);
    rehashReceiptOuter(&artifact);
    try testing.expectError(
        error.InvalidReadinessArtifact,
        native.validateReadinessArtifactV1(artifact),
    );
}

test "weakened canonical rule fails after outer rehash" {
    var artifact = try syntheticArtifact();
    artifact.plan.rules[12] = try contract.makeRuleV1(
        .accelerator_device_time,
        .post_run,
        .require_present,
        0,
        0,
    );
    rehashPlanOuter(&artifact);
    try testing.expectError(
        error.InvalidReadinessArtifact,
        native.validateReadinessArtifactV1(artifact),
    );
}

test "replaced canonical rule fails after outer rehash" {
    var artifact = try syntheticArtifact();
    artifact.plan.rules[2] = try contract.makeRuleV1(
        .host_logical_cpu_count,
        .pre_run,
        .inclusive_range,
        1,
        8192,
    );
    rehashPlanOuter(&artifact);
    try testing.expectError(
        error.InvalidReadinessArtifact,
        native.validateReadinessArtifactV1(artifact),
    );
}

test "reordered canonical rules fail after outer rehash" {
    var artifact = try syntheticArtifact();
    std.mem.swap(
        contract.RuleV1,
        &artifact.plan.rules[10],
        &artifact.plan.rules[11],
    );
    rehashPlanOuter(&artifact);
    try testing.expectError(
        error.InvalidPlan,
        native.validateReadinessArtifactV1(artifact),
    );
}

test "dispatch receipt mutations fail closed without Metal" {
    const artifact = try syntheticArtifact();

    var zero_duration = artifact.dispatch;
    zero_duration.gpu_duration_nanoseconds = 0;
    zero_duration.receipt_sha256 =
        native.dispatchReceiptSha256V1(zero_duration);
    try testing.expectError(
        error.InvalidDispatchReceipt,
        native.validateDispatchReceiptV1(zero_duration),
    );

    var reversed = artifact.dispatch;
    reversed.gpu_end_time_bits = reversed.gpu_start_time_bits;
    reversed.receipt_sha256 =
        native.dispatchReceiptSha256V1(reversed);
    try testing.expectError(
        error.InvalidDispatchReceipt,
        native.validateDispatchReceiptV1(reversed),
    );

    var duration_overflow = artifact.dispatch;
    const overflow_start: f64 = 1;
    const overflow_end = overflow_start +
        @as(f64, @floatFromInt(std.math.maxInt(u64))) /
            1_000_000_000.0;
    duration_overflow.gpu_start_time_bits = @bitCast(overflow_start);
    duration_overflow.gpu_end_time_bits = @bitCast(overflow_end);
    duration_overflow.gpu_duration_nanoseconds = std.math.maxInt(u64);
    duration_overflow.receipt_sha256 =
        native.dispatchReceiptSha256V1(duration_overflow);
    try testing.expectError(
        error.InvalidDispatchReceipt,
        native.validateDispatchReceiptV1(duration_overflow),
    );

    var no_live_allocation = artifact.dispatch;
    no_live_allocation.current_allocated_before = 0;
    no_live_allocation.receipt_sha256 =
        native.dispatchReceiptSha256V1(no_live_allocation);
    try testing.expectError(
        error.InvalidDispatchReceipt,
        native.validateDispatchReceiptV1(no_live_allocation),
    );
}

fn rehashReceiptOuter(
    artifact: *native.ReadinessArtifactV1,
) void {
    artifact.run.receipt.receipt_sha256 =
        runner.workloadReceiptSha256V1(artifact.run.receipt);
    artifact.run.report.workload_receipt_sha256 =
        artifact.run.receipt.receipt_sha256;
    artifact.run.report.report_sha256 =
        runner.runReportSha256V1(artifact.run.report);
    artifact.diagnostic.workload_receipt_sha256 =
        artifact.run.receipt.receipt_sha256;
    artifact.diagnostic.run_report_sha256 =
        artifact.run.report.report_sha256;
    artifact.diagnostic.report_sha256 =
        native.diagnosticReportSha256V1(artifact.diagnostic);
}

fn rehashPlanOuter(
    artifact: *native.ReadinessArtifactV1,
) void {
    artifact.plan.plan_sha256 =
        contract.planSha256V1(artifact.plan);
    artifact.run.report.plan_sha256 =
        artifact.plan.plan_sha256;
    artifact.run.report.report_sha256 =
        runner.runReportSha256V1(artifact.run.report);
    artifact.diagnostic.plan_sha256 =
        artifact.plan.plan_sha256;
    artifact.diagnostic.run_report_sha256 =
        artifact.run.report.report_sha256;
    artifact.diagnostic.report_sha256 =
        native.diagnosticReportSha256V1(artifact.diagnostic);
}

fn syntheticArtifact() !native.ReadinessArtifactV1 {
    const device: engine.metal_backend.MetalDeviceInfo = .{
        .abi_version = engine.metal_backend.device_info_abi,
        .registry_id = 17,
        .current_allocated_size = 4096,
        .recommended_max_working_set_size = 1 << 30,
        .location = 1,
        .location_number = 0,
        .max_threads_x = 1024,
        .max_threads_y = 1024,
        .max_threads_z = 64,
        .low_power = 1,
        .headless = 0,
        .removable = 0,
        .unified_memory = 1,
    };
    const canonical = try native.canonicalIdentityV1(
        testing.allocator,
    );
    const evidence: native.WorkloadEvidenceV1 = .{
        .gpu_output_bits = canonical.oracle_output_bits,
        .oracle_output_sha256 = canonical.oracle_output_sha256,
        .max_abs_error_bits = @bitCast(@as(f32, 0)),
        .live_weights_before = 0,
        .live_weights_after = 0,
        .completed_dispatches_before = 0,
        .completed_dispatches_after = 1,
    };
    var dispatch: native.DispatchReceiptV1 = .{
        .device_registry_id = device.registry_id,
        .dispatch_ordinal = 1,
        .host_submit_ticks = 225,
        .host_complete_ticks = 275,
        .current_allocated_before = 8192,
        .current_allocated_after = 8192,
        .recommended_max_working_set_size = device.recommended_max_working_set_size,
        .gpu_start_time_bits = @bitCast(@as(f64, 1234.0)),
        .gpu_end_time_bits = @bitCast(@as(f64, 1234.000002)),
        .gpu_duration_nanoseconds = durationNanoseconds(
            1234.0,
            1234.000002,
        ),
        .command_status = engine.metal_backend.completed_command_buffer_status,
        .live_weights_after = 0,
        .output_sha256 = native.outputIdentityV1(
            evidence.gpu_output_bits,
        ),
    };
    dispatch.receipt_sha256 = native.dispatchReceiptSha256V1(
        dispatch,
    );
    try native.validateDispatchReceiptV1(dispatch);

    const descriptor = try native.descriptorV1();
    const plan = try native.makeCanonicalPlanV1(
        descriptor,
        canonical,
        8,
        device,
    );
    var observer: SyntheticObserver = .{
        .device = device,
        .dispatch = dispatch,
    };
    var workload: SyntheticWorkload = .{
        .dispatch = dispatch,
        .evidence = evidence,
    };
    const run = try runner.runObservedV1(
        plan,
        observer.interface(descriptor),
        workload.interface(),
    );
    var diagnostic: native.DiagnosticReportV1 = .{
        .device_registry_id = dispatch.device_registry_id,
        .logical_cpu_count = 8,
        .queue_count = plan.queue_count,
        .direct_metric_bits = descriptor.direct_metric_bits,
        .unsupported_metric_bits = unsupportedMetricBits(),
        .missing_observation_count = 2,
        .unsupported_observation_count = 24,
        .unavailable_reason_count = 26,
        .present_reason_count = 0,
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .plan_sha256 = plan.plan_sha256,
        .device_sha256 = plan.device_sha256,
        .placement_sha256 = plan.placement_sha256,
        .probe_bundle_sha256 = run.probe.bundle_sha256,
        .pre_run_bundle_sha256 = run.pre_run.bundle_sha256,
        .post_run_bundle_sha256 = run.post_run.bundle_sha256,
        .workload_receipt_sha256 = run.receipt.receipt_sha256,
        .run_report_sha256 = run.report.report_sha256,
        .dispatch_receipt_sha256 = dispatch.receipt_sha256,
    };
    diagnostic.report_sha256 =
        native.diagnosticReportSha256V1(diagnostic);
    return .{
        .descriptor = descriptor,
        .plan = plan,
        .run = run,
        .device = device,
        .workload = evidence,
        .dispatch = dispatch,
        .diagnostic = diagnostic,
    };
}

fn addMetal(
    output: *[contract.maximum_observations]contract.ObservationV1,
    count: *usize,
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    phase: contract.PhaseV1,
    metric: contract.MetricIdV1,
    availability: contract.AvailabilityV1,
    value: i64,
    observed_at: u64,
    sample_clock: contract.Digest,
    source: contract.Digest,
    provenance: contract.Digest,
    reason: contract.Digest,
) !void {
    try add(
        output,
        count,
        descriptor,
        plan,
        phase,
        metric,
        availability,
        value,
        observed_at,
        sample_clock,
        contract.zero_digest,
        source,
        provenance,
        plan.device_sha256,
        reason,
    );
}

fn addUnsupported(
    output: *[contract.maximum_observations]contract.ObservationV1,
    count: *usize,
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    phase: contract.PhaseV1,
    metric: contract.MetricIdV1,
    reason: []const u8,
    observed_at: u64,
    sample_clock: contract.Digest,
    source: contract.Digest,
    provenance: contract.Digest,
) !void {
    try addMetal(
        output,
        count,
        descriptor,
        plan,
        phase,
        metric,
        .unsupported,
        0,
        observed_at,
        sample_clock,
        source,
        provenance,
        contract.digestV1(reason),
    );
}

fn add(
    output: *[contract.maximum_observations]contract.ObservationV1,
    count: *usize,
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    phase: contract.PhaseV1,
    metric: contract.MetricIdV1,
    availability: contract.AvailabilityV1,
    value: i64,
    observed_at: u64,
    sample_clock: contract.Digest,
    value_clock: contract.Digest,
    source: contract.Digest,
    provenance: contract.Digest,
    subject: contract.Digest,
    reason: contract.Digest,
) !void {
    output[count.*] = try contract.makeObservationV1(
        descriptor,
        plan,
        phase,
        count.* + 1,
        metric,
        availability,
        value,
        observed_at,
        sample_clock,
        value_clock,
        source,
        provenance,
        subject,
        reason,
    );
    count.* += 1;
}

fn unsupportedMetricBits() u64 {
    var result: u64 = 0;
    inline for ([_]contract.MetricIdV1{
        .accelerator_utilization,
        .accelerator_committed_bytes,
        .accelerator_resident_bytes,
        .accelerator_queue_depth,
        .accelerator_temperature,
        .accelerator_frequency,
        .accelerator_power,
        .accelerator_energy,
    }) |metric| {
        result |= contract.metricBitV1(metric) catch unreachable;
    }
    return result;
}

fn durationNanoseconds(start: f64, end: f64) u64 {
    return @intFromFloat((end - start) * 1_000_000_000.0);
}
