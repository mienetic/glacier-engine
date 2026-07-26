//! Native macOS Metal execution-readiness observation.
//!
//! This adapter binds one real Metal command buffer to the portable W5
//! observation runner. It is deliberately diagnostic: a fixed in-memory INT4
//! matrix-vector operation is checked against the CPU oracle, but no model is
//! loaded and no throughput or latency claim is produced.

const std = @import("std");
const core = @import("core");
const metal = @import("backend.zig");
const cpu_int4 = @import("../cpu/int4_matmul.zig");

pub const contract = core.native_observation_contract;
pub const runner = core.native_observation_runner;
pub const Digest = contract.Digest;

pub const dispatch_receipt_abi: u64 = 0x474d_4450_0000_0001;
pub const diagnostic_report_abi: u64 = 0x474d_4458_0000_0001;
pub const observer_implementation_abi: u64 = 0x474d_4f42_0000_0001;
pub const workload_evidence_abi: u64 = 0x474d_4556_0000_0001;

const dispatch_receipt_domain =
    "glacier-metal-dispatch-receipt-v1\x00";
const diagnostic_report_domain =
    "glacier-metal-readiness-diagnostic-v1\x00";
const output_domain = "glacier-metal-readiness-output-v1\x00";
const oracle_output_domain =
    "glacier-metal-readiness-oracle-output-v1\x00";
const correctness_domain =
    "glacier-metal-readiness-correctness-v1\x00";
const ownership_domain =
    "glacier-metal-readiness-ownership-v1\x00";
const workload_result_domain =
    "glacier-metal-readiness-workload-result-v1\x00";
const device_identity_domain =
    "glacier-metal-device-identity-v1\x00";
const placement_identity_domain =
    "glacier-metal-placement-identity-v1\x00";
const machine_identity_domain =
    "glacier-metal-readiness-machine-v1\x00";
const source_identity_domain =
    "glacier-metal-observer-source-v1\x00";
const provenance_domain =
    "glacier-metal-observation-provenance-v1\x00";
const workload_profile_domain =
    "glacier-metal-readiness-workload-profile-v1\x00";
const fixture_artifact_domain =
    "glacier-metal-readiness-fixture-artifact-v1\x00";
const build_identity_domain =
    "glacier-metal-readiness-build-identity-v1\x00";

pub const in_features: usize = 64;
pub const out_features: usize = 37;
pub const group_size: u32 = 8;
pub const maximum_abs_error: f32 = 0.00002;

pub const DispatchReceiptV1 = struct {
    abi_version: u64 = dispatch_receipt_abi,
    device_registry_id: u64 = 0,
    dispatch_ordinal: u64 = 0,
    host_submit_ticks: u64 = 0,
    host_complete_ticks: u64 = 0,
    current_allocated_before: u64 = 0,
    current_allocated_after: u64 = 0,
    recommended_max_working_set_size: u64 = 0,
    gpu_start_time_bits: u64 = 0,
    gpu_end_time_bits: u64 = 0,
    gpu_duration_nanoseconds: u64 = 0,
    command_status: u64 = 0,
    live_weights_after: u64 = 0,
    output_sha256: Digest = contract.zero_digest,
    receipt_sha256: Digest = contract.zero_digest,
};

pub const DiagnosticReportV1 = struct {
    abi_version: u64 = diagnostic_report_abi,
    claim_class: u64 = 1,
    performance_claim: u64 = 0,
    device_registry_id: u64 = 0,
    logical_cpu_count: u64 = 0,
    queue_count: u64 = 0,
    direct_metric_bits: u64 = 0,
    unsupported_metric_bits: u64 = 0,
    missing_observation_count: u64 = 0,
    unsupported_observation_count: u64 = 0,
    unavailable_reason_count: u64 = 0,
    present_reason_count: u64 = 0,
    descriptor_sha256: Digest = contract.zero_digest,
    plan_sha256: Digest = contract.zero_digest,
    device_sha256: Digest = contract.zero_digest,
    placement_sha256: Digest = contract.zero_digest,
    probe_bundle_sha256: Digest = contract.zero_digest,
    pre_run_bundle_sha256: Digest = contract.zero_digest,
    post_run_bundle_sha256: Digest = contract.zero_digest,
    workload_receipt_sha256: Digest = contract.zero_digest,
    run_report_sha256: Digest = contract.zero_digest,
    dispatch_receipt_sha256: Digest = contract.zero_digest,
    report_sha256: Digest = contract.zero_digest,
};

pub const WorkloadEvidenceV1 = struct {
    abi_version: u64 = workload_evidence_abi,
    gpu_output_bits: [out_features]u32 =
        [_]u32{0} ** out_features,
    oracle_output_sha256: Digest = contract.zero_digest,
    max_abs_error_bits: u32 = 0,
    live_weights_before: u64 = 0,
    live_weights_after: u64 = 0,
    completed_dispatches_before: u64 = 0,
    completed_dispatches_after: u64 = 0,
};

pub const ReadinessArtifactV1 = struct {
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    run: runner.RunArtifactV1,
    device: metal.MetalDeviceInfo,
    workload: WorkloadEvidenceV1,
    dispatch: DispatchReceiptV1,
    diagnostic: DiagnosticReportV1,
};

pub const CanonicalIdentityV1 = struct {
    workload_profile_sha256: Digest,
    artifact_sha256: Digest,
    build_sha256: Digest,
    oracle_output_bits: [out_features]u32,
    oracle_output_sha256: Digest,
};

pub const MacOSMetalObserverV1 = struct {
    backend: *metal.MetalBackend,
    timer: std.time.Timer,
    initial_device: metal.MetalDeviceInfo,
    logical_cpu_count: u64,
    machine_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    host_source_sha256: Digest,
    metal_source_sha256: Digest,
    transition_count: usize = 0,
    transitions: [2]contract.PhaseV1 = .{ .unused, .unused },
    dispatch: ?DispatchReceiptV1 = null,

    pub fn init(
        backend: *metal.MetalBackend,
    ) !MacOSMetalObserverV1 {
        const initial_device = try backend.deviceInfo();
        const cpu_count_usize = try std.Thread.getCpuCount();
        const logical_cpu_count = std.math.cast(
            u64,
            cpu_count_usize,
        ) orelse return error.InvalidCpuCount;
        if (logical_cpu_count == 0) return error.InvalidCpuCount;
        const device_sha256 = deviceIdentityV1(initial_device);
        const placement_sha256 = placementIdentityV1(initial_device);
        const machine_sha256 = machineIdentityV1(
            logical_cpu_count,
            device_sha256,
        );
        return .{
            .backend = backend,
            .timer = try std.time.Timer.start(),
            .initial_device = initial_device,
            .logical_cpu_count = logical_cpu_count,
            .machine_sha256 = machine_sha256,
            .device_sha256 = device_sha256,
            .placement_sha256 = placement_sha256,
            .host_source_sha256 = contract.digestV1(
                "std.Thread.getCpuCount+std.time.Timer/v1",
            ),
            .metal_source_sha256 = sourceIdentityV1(),
        };
    }

    pub fn interface(
        self: *MacOSMetalObserverV1,
        descriptor: contract.DescriptorV1,
    ) runner.ObserverV1 {
        return .{
            .context = self,
            .descriptor = descriptor,
            .collect_fn = collect,
            .transition_fn = transition,
        };
    }

    pub fn makePlan(
        self: MacOSMetalObserverV1,
        descriptor: contract.DescriptorV1,
        canonical: CanonicalIdentityV1,
    ) !contract.PlanV1 {
        return makeCanonicalPlanV1(
            descriptor,
            canonical,
            self.logical_cpu_count,
            self.initial_device,
        );
    }

    fn nextTick(self: *MacOSMetalObserverV1) u64 {
        return @max(@as(u64, 1), self.timer.read());
    }

    fn collect(
        context_ptr: *anyopaque,
        descriptor: *const contract.DescriptorV1,
        plan: *const contract.PlanV1,
        phase: contract.PhaseV1,
        output: *[contract.maximum_observations]contract.ObservationV1,
    ) runner.CallbackError!usize {
        const self: *MacOSMetalObserverV1 = @ptrCast(
            @alignCast(context_ptr),
        );
        if (phase != .probe and
            phase != .pre_run and
            phase != .post_run)
            return runner.CallbackError.InvalidSample;
        const info = self.backend.deviceInfo() catch
            return runner.CallbackError.ObserverUnavailable;
        const observed_at = self.nextTick();
        const time_value = std.math.cast(
            i64,
            observed_at,
        ) orelse return runner.CallbackError.InvalidSample;
        const cpu_value = std.math.cast(
            i64,
            self.logical_cpu_count,
        ) orelse return runner.CallbackError.InvalidSample;
        const allocated_value = std.math.cast(
            i64,
            info.current_allocated_size,
        ) orelse return runner.CallbackError.InvalidSample;
        const current_device_sha256 = deviceIdentityV1(info);
        const current_source_sha256 = self.metal_source_sha256;
        const phase_provenance = observationProvenanceV1(
            phase,
            observed_at,
            info,
            if (self.dispatch) |value|
                value.receipt_sha256
            else
                contract.zero_digest,
        );
        const host_provenance = hostProvenanceV1(
            phase,
            observed_at,
            self.logical_cpu_count,
        );
        const host_clock = contract.digestV1(
            "std.time.Timer monotonic ticks/v1",
        );
        const metal_value_clock = contract.digestV1(
            "Metal MTLCommandBuffer GPUStartTime GPUEndTime host time/v1",
        );
        var count: usize = 0;
        append(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .host_monotonic_time,
            .present,
            time_value,
            observed_at,
            host_clock,
            host_clock,
            self.host_source_sha256,
            host_provenance,
            self.machine_sha256,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        append(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .host_logical_cpu_count,
            .present,
            cpu_value,
            observed_at,
            host_clock,
            contract.zero_digest,
            self.host_source_sha256,
            host_provenance,
            self.machine_sha256,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        append(
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
            contract.zero_digest,
            current_source_sha256,
            phase_provenance,
            current_device_sha256,
            contract.zero_digest,
        ) catch return runner.CallbackError.InvalidSample;
        const fallback_available = phase != .post_run or
            self.dispatch != null;
        append(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .accelerator_cpu_fallback,
            if (fallback_available) .present else .missing,
            0,
            observed_at,
            host_clock,
            contract.zero_digest,
            current_source_sha256,
            phase_provenance,
            current_device_sha256,
            if (fallback_available)
                contract.zero_digest
            else
                contract.digestV1(
                    "Metal dispatch completion unavailable/v1",
                ),
        ) catch return runner.CallbackError.InvalidSample;
        appendUnavailable(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .accelerator_utilization,
            observed_at,
            host_clock,
            current_source_sha256,
            phase_provenance,
            current_device_sha256,
            "Metal utilization has no direct adapter/v1",
        ) catch return runner.CallbackError.InvalidSample;
        append(
            output,
            &count,
            descriptor.*,
            plan.*,
            phase,
            .accelerator_allocated_bytes,
            .present,
            allocated_value,
            observed_at,
            host_clock,
            contract.zero_digest,
            current_source_sha256,
            phase_provenance,
            current_device_sha256,
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
            appendUnavailable(
                output,
                &count,
                descriptor.*,
                plan.*,
                phase,
                unavailable.metric,
                observed_at,
                host_clock,
                current_source_sha256,
                phase_provenance,
                current_device_sha256,
                unavailable.reason,
            ) catch return runner.CallbackError.InvalidSample;
        }
        if (phase == .post_run and self.dispatch != null) {
            const dispatch = self.dispatch.?;
            const duration = std.math.cast(
                i64,
                dispatch.gpu_duration_nanoseconds,
            ) orelse return runner.CallbackError.InvalidSample;
            append(
                output,
                &count,
                descriptor.*,
                plan.*,
                phase,
                .accelerator_device_time,
                .present,
                duration,
                observed_at,
                host_clock,
                metal_value_clock,
                current_source_sha256,
                dispatch.receipt_sha256,
                current_device_sha256,
                contract.zero_digest,
            ) catch return runner.CallbackError.InvalidSample;
        } else {
            append(
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
                contract.zero_digest,
                current_source_sha256,
                phase_provenance,
                current_device_sha256,
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
        const self: *MacOSMetalObserverV1 = @ptrCast(
            @alignCast(context_ptr),
        );
        if (self.transition_count >= self.transitions.len)
            return runner.CallbackError.InvalidSample;
        const expected: contract.PhaseV1 =
            if (self.transition_count == 0) .begin else .end;
        if (phase != expected)
            return runner.CallbackError.InvalidSample;
        self.transitions[self.transition_count] = phase;
        self.transition_count += 1;
    }
};

pub const ReadinessWorkloadV1 = struct {
    allocator: std.mem.Allocator,
    backend: *metal.MetalBackend,
    observer: *MacOSMetalObserverV1,
    packed_weights: []const u8,
    scales: []const f32,
    input: *const [in_features]f32,
    invocations: u64 = 0,
    evidence: ?WorkloadEvidenceV1 = null,

    pub fn interface(self: *ReadinessWorkloadV1) runner.WorkloadV1 {
        return .{
            .context = self,
            .run_fn = run,
        };
    }

    fn run(
        context_ptr: *anyopaque,
        plan: *const contract.PlanV1,
    ) runner.CallbackError!runner.WorkloadReceiptV1 {
        const self: *ReadinessWorkloadV1 = @ptrCast(
            @alignCast(context_ptr),
        );
        if (self.invocations != 0 or
            self.observer.transition_count != 1 or
            self.observer.transitions[0] != .begin)
            return runner.CallbackError.InjectedFailure;
        self.invocations = 1;
        return self.runOnce(plan) catch
            runner.CallbackError.WorkloadUnavailable;
    }

    fn runOnce(
        self: *ReadinessWorkloadV1,
        plan: *const contract.PlanV1,
    ) !runner.WorkloadReceiptV1 {
        var input_tensor = try core.tensor.fromF32(
            self.allocator,
            &.{ 1, in_features },
            self.input,
        );
        defer input_tensor.deinit();
        var cpu_output = try core.tensor.zerosF32(
            self.allocator,
            &.{ 1, out_features },
        );
        defer cpu_output.deinit();
        try cpu_int4.linearInt4OnTheFly(
            input_tensor,
            self.packed_weights,
            self.scales,
            &.{},
            cpu_output,
            out_features,
            in_features,
            group_size,
        );

        const live_weights_before = self.backend.liveWeightCount();
        const completed_before =
            self.backend.completedDispatchCount();
        var gpu_output: [out_features]f32 = undefined;
        var telemetry: metal.MetalDispatchTelemetry = undefined;
        var host_submit_ticks: u64 = 0;
        var host_complete_ticks: u64 = 0;
        {
            const weight = try self.backend.createInt4Weight(
                self.packed_weights,
                self.scales,
                group_size,
                in_features,
                out_features,
            );
            defer self.backend.destroyInt4Weight(weight);
            host_submit_ticks = self.observer.nextTick();
            telemetry = try self.backend.matvecInt4Observed(
                weight,
                self.input,
                &gpu_output,
            );
            host_complete_ticks = self.observer.nextTick();
        }
        if (host_complete_ticks <= host_submit_ticks or
            self.backend.liveWeightCount() != live_weights_before or
            self.backend.completedDispatchCount() !=
                completed_before + 1)
            return error.InvalidOwnership;

        var max_abs_error: f32 = 0;
        for (cpu_output.asF32(), gpu_output) |expected, actual| {
            if (!std.math.isFinite(expected) or
                !std.math.isFinite(actual))
                return error.InvalidOutput;
            max_abs_error = @max(
                max_abs_error,
                @abs(expected - actual),
            );
        }
        const correctness_passed =
            max_abs_error <= maximum_abs_error;
        var gpu_output_bits: [out_features]u32 = undefined;
        var oracle_output_bits: [out_features]u32 = undefined;
        for (
            gpu_output,
            cpu_output.asF32(),
            &gpu_output_bits,
            &oracle_output_bits,
        ) |actual, expected, *actual_bits, *expected_bits| {
            actual_bits.* = @bitCast(actual);
            expected_bits.* = @bitCast(expected);
        }
        const output_sha256 = outputIdentityV1(gpu_output_bits);
        var dispatch: DispatchReceiptV1 = .{
            .device_registry_id = self.observer.initial_device.registry_id,
            .dispatch_ordinal = completed_before + 1,
            .host_submit_ticks = host_submit_ticks,
            .host_complete_ticks = host_complete_ticks,
            .current_allocated_before = telemetry.current_allocated_before,
            .current_allocated_after = telemetry.current_allocated_after,
            .recommended_max_working_set_size = self.observer.initial_device
                .recommended_max_working_set_size,
            .gpu_start_time_bits = telemetry.gpu_start_time_bits,
            .gpu_end_time_bits = telemetry.gpu_end_time_bits,
            .gpu_duration_nanoseconds = telemetry.gpu_duration_nanoseconds,
            .command_status = telemetry.command_status,
            .live_weights_after = self.backend.liveWeightCount(),
            .output_sha256 = output_sha256,
        };
        dispatch.receipt_sha256 = dispatchReceiptSha256V1(
            dispatch,
        );
        try validateDispatchReceiptV1(dispatch);
        self.observer.dispatch = dispatch;

        const evidence: WorkloadEvidenceV1 = .{
            .gpu_output_bits = gpu_output_bits,
            .oracle_output_sha256 = oracleOutputIdentityV1(
                oracle_output_bits,
            ),
            .max_abs_error_bits = @bitCast(max_abs_error),
            .live_weights_before = live_weights_before,
            .live_weights_after = self.backend.liveWeightCount(),
            .completed_dispatches_before = completed_before,
            .completed_dispatches_after = self.backend.completedDispatchCount(),
        };
        self.evidence = evidence;
        const correctness_sha256 = correctnessIdentityV1(
            evidence,
            output_sha256,
        );
        const ownership_sha256 = ownershipIdentityV1(evidence);
        const result_sha256 = workloadResultIdentityV1(
            output_sha256,
            dispatch.receipt_sha256,
        );
        return runner.makeWorkloadReceiptV1(
            plan.*,
            .succeeded,
            if (correctness_passed) .passed else .failed,
            if (self.backend.liveWeightCount() ==
                live_weights_before)
                .passed
            else
                .failed,
            .absent,
            1,
            1,
            result_sha256,
            correctness_sha256,
            ownership_sha256,
        );
    }
};

pub fn descriptorV1() !contract.DescriptorV1 {
    return contract.makeDescriptorV1(
        observer_implementation_abi,
        1,
        try declaredMetricBits(),
        try directMetricBits(),
        contract.digestV1(
            "glacier native macos Metal readiness observer/v1",
        ),
        contract.digestV1(
            "Metal.framework device+command-buffer observation/v1",
        ),
    );
}

pub fn makeCanonicalPlanV1(
    descriptor: contract.DescriptorV1,
    canonical: CanonicalIdentityV1,
    logical_cpu_count: u64,
    device: metal.MetalDeviceInfo,
) !contract.PlanV1 {
    const device_sha256 = deviceIdentityV1(device);
    const rules = try canonicalRulesV1();
    return contract.makePlanV1(
        descriptor,
        canonical.workload_profile_sha256,
        canonical.artifact_sha256,
        canonical.build_sha256,
        machineIdentityV1(logical_cpu_count, device_sha256),
        contract.digestV1("Metal.framework backend/v1"),
        device_sha256,
        placementIdentityV1(device),
        .accelerator,
        1,
        1,
        &rules,
        contract.digestV1(
            "native macos metal readiness challenge/v1",
        ),
    );
}

fn canonicalRulesV1() ![13]contract.RuleV1 {
    return .{
        try contract.makeRuleV1(
            .host_monotonic_time,
            .pre_run,
            .require_present,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .host_monotonic_time,
            .post_run,
            .require_present,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .host_logical_cpu_count,
            .pre_run,
            .inclusive_range,
            1,
            4096,
        ),
        try contract.makeRuleV1(
            .host_logical_cpu_count,
            .pre_post,
            .max_abs_delta,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .host_logical_cpu_count,
            .pre_post,
            .same_source,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .accelerator_device_present,
            .pre_run,
            .inclusive_range,
            1,
            1,
        ),
        try contract.makeRuleV1(
            .accelerator_device_present,
            .pre_post,
            .same_source,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .accelerator_device_present,
            .pre_post,
            .same_subject,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .accelerator_cpu_fallback,
            .pre_run,
            .require_false,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .accelerator_cpu_fallback,
            .post_run,
            .require_false,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .accelerator_allocated_bytes,
            .pre_run,
            .require_present,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .accelerator_allocated_bytes,
            .post_run,
            .require_present,
            0,
            0,
        ),
        try contract.makeRuleV1(
            .accelerator_device_time,
            .post_run,
            .inclusive_range,
            1,
            std.math.maxInt(i64),
        ),
    };
}

pub fn runReadinessV1(
    allocator: std.mem.Allocator,
    backend: *metal.MetalBackend,
) !ReadinessArtifactV1 {
    if (backend.liveWeightCount() != 0 or
        backend.completedDispatchCount() != 0)
        return error.DirtyMetalBackend;
    var weights: [in_features * out_features]f32 = undefined;
    var input: [in_features]f32 = undefined;
    fillCanonicalFixture(&weights, &input);
    const quantized = try core.quant.quantize(
        f32,
        allocator,
        &weights,
        .int4,
        group_size,
    );
    defer {
        allocator.free(quantized.packed_bytes);
        allocator.free(quantized.scales);
    }
    const descriptor = try descriptorV1();
    var observer = try MacOSMetalObserverV1.init(backend);
    const canonical = try canonicalIdentityV1(allocator);
    if (!contract.digestEqual(
        canonical.workload_profile_sha256,
        workloadProfileIdentity(&input),
    ) or
        !contract.digestEqual(
            canonical.artifact_sha256,
            fixtureArtifactIdentity(
                quantized.packed_bytes,
                quantized.scales,
            ),
        ))
        return error.NonCanonicalFixture;
    const plan = try observer.makePlan(descriptor, canonical);
    var workload: ReadinessWorkloadV1 = .{
        .allocator = allocator,
        .backend = backend,
        .observer = &observer,
        .packed_weights = quantized.packed_bytes,
        .scales = quantized.scales,
        .input = &input,
    };
    const run = try runner.runObservedV1(
        plan,
        observer.interface(descriptor),
        workload.interface(),
    );
    if (observer.dispatch == null)
        return error.MissingDispatchReceipt;
    if (workload.evidence == null)
        return error.MissingWorkloadEvidence;
    const dispatch = observer.dispatch.?;
    const workload_evidence = workload.evidence.?;
    var diagnostic = try makeDiagnosticReportV1(
        observer,
        descriptor,
        plan,
        run,
        dispatch,
    );
    diagnostic.report_sha256 = diagnosticReportSha256V1(
        diagnostic,
    );
    const artifact: ReadinessArtifactV1 = .{
        .descriptor = descriptor,
        .plan = plan,
        .run = run,
        .device = observer.initial_device,
        .workload = workload_evidence,
        .dispatch = dispatch,
        .diagnostic = diagnostic,
    };
    try validateReadinessArtifactV1(artifact);
    return artifact;
}

pub fn dispatchReceiptSha256V1(
    value: DispatchReceiptV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_receipt_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.device_registry_id);
    hashU64(&hash, value.dispatch_ordinal);
    hashU64(&hash, value.host_submit_ticks);
    hashU64(&hash, value.host_complete_ticks);
    hashU64(&hash, value.current_allocated_before);
    hashU64(&hash, value.current_allocated_after);
    hashU64(
        &hash,
        value.recommended_max_working_set_size,
    );
    hashU64(&hash, value.gpu_start_time_bits);
    hashU64(&hash, value.gpu_end_time_bits);
    hashU64(&hash, value.gpu_duration_nanoseconds);
    hashU64(&hash, value.command_status);
    hashU64(&hash, value.live_weights_after);
    hash.update(&value.output_sha256);
    return finish(&hash);
}

pub fn validateDispatchReceiptV1(
    value: DispatchReceiptV1,
) !void {
    const start: f64 = @bitCast(value.gpu_start_time_bits);
    const end: f64 = @bitCast(value.gpu_end_time_bits);
    if (value.abi_version != dispatch_receipt_abi or
        value.device_registry_id == 0 or
        value.dispatch_ordinal != 1 or
        value.host_submit_ticks == 0 or
        value.host_complete_ticks <= value.host_submit_ticks or
        value.current_allocated_before == 0 or
        value.current_allocated_after == 0 or
        value.gpu_duration_nanoseconds == 0 or
        value.command_status !=
            metal.completed_command_buffer_status or
        value.live_weights_after != 0 or
        contract.digestIsZero(value.output_sha256) or
        !std.math.isFinite(start) or
        !std.math.isFinite(end) or
        start <= 0 or end <= start or
        !contract.digestEqual(
            value.receipt_sha256,
            dispatchReceiptSha256V1(value),
        ))
        return error.InvalidDispatchReceipt;
    const duration = durationNanoseconds(start, end) orelse
        return error.InvalidDispatchReceipt;
    if (duration != value.gpu_duration_nanoseconds)
        return error.InvalidDispatchReceipt;
}

pub fn diagnosticReportSha256V1(
    value: DiagnosticReportV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(diagnostic_report_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.claim_class);
    hashU64(&hash, value.performance_claim);
    hashU64(&hash, value.device_registry_id);
    hashU64(&hash, value.logical_cpu_count);
    hashU64(&hash, value.queue_count);
    hashU64(&hash, value.direct_metric_bits);
    hashU64(&hash, value.unsupported_metric_bits);
    hashU64(&hash, value.missing_observation_count);
    hashU64(&hash, value.unsupported_observation_count);
    hashU64(&hash, value.unavailable_reason_count);
    hashU64(&hash, value.present_reason_count);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.plan_sha256);
    hash.update(&value.device_sha256);
    hash.update(&value.placement_sha256);
    hash.update(&value.probe_bundle_sha256);
    hash.update(&value.pre_run_bundle_sha256);
    hash.update(&value.post_run_bundle_sha256);
    hash.update(&value.workload_receipt_sha256);
    hash.update(&value.run_report_sha256);
    hash.update(&value.dispatch_receipt_sha256);
    return finish(&hash);
}

pub fn validateDiagnosticReportV1(
    value: DiagnosticReportV1,
) !void {
    if (value.abi_version != diagnostic_report_abi or
        value.claim_class != 1 or
        value.performance_claim != 0 or
        value.device_registry_id == 0 or
        value.logical_cpu_count == 0 or
        value.queue_count != 1 or
        value.direct_metric_bits != try directMetricBits() or
        value.unsupported_metric_bits !=
            try unsupportedMetricBits() or
        value.missing_observation_count != 2 or
        value.unsupported_observation_count != 24 or
        value.unavailable_reason_count != 26 or
        value.present_reason_count != 0 or
        contract.digestIsZero(value.descriptor_sha256) or
        contract.digestIsZero(value.plan_sha256) or
        contract.digestIsZero(value.device_sha256) or
        contract.digestIsZero(value.placement_sha256) or
        contract.digestIsZero(value.probe_bundle_sha256) or
        contract.digestIsZero(value.pre_run_bundle_sha256) or
        contract.digestIsZero(value.post_run_bundle_sha256) or
        contract.digestIsZero(value.workload_receipt_sha256) or
        contract.digestIsZero(value.run_report_sha256) or
        contract.digestIsZero(value.dispatch_receipt_sha256) or
        !contract.digestEqual(
            value.report_sha256,
            diagnosticReportSha256V1(value),
        ))
        return error.InvalidDiagnosticReport;
}

/// Validate the readiness result as one composed evidence object. Individual
/// self-hashes are insufficient: every retained root and the live dispatch
/// facts must agree with the descriptor, plan, runner artifact, observations,
/// workload receipt, and diagnostic summary.
pub fn validateReadinessArtifactV1(
    artifact: ReadinessArtifactV1,
) !void {
    try runner.validateRunArtifactV1(
        artifact.descriptor,
        artifact.plan,
        artifact.run,
    );
    try validateDispatchReceiptV1(artifact.dispatch);
    try validateDiagnosticReportV1(artifact.diagnostic);

    const expected_descriptor = try descriptorV1();
    var identity_storage: [16 * 1024]u8 = undefined;
    var identity_allocator = std.heap.FixedBufferAllocator.init(
        &identity_storage,
    );
    const canonical = try canonicalIdentityV1(
        identity_allocator.allocator(),
    );
    const expected_plan = try makeCanonicalPlanV1(
        artifact.descriptor,
        canonical,
        artifact.diagnostic.logical_cpu_count,
        artifact.device,
    );
    const expected_output_sha256 = outputIdentityV1(
        artifact.workload.gpu_output_bits,
    );
    const expected_max_abs_error_bits = try maximumAbsErrorBitsV1(
        canonical.oracle_output_bits,
        artifact.workload.gpu_output_bits,
    );
    const maximum_error: f32 = @bitCast(
        artifact.workload.max_abs_error_bits,
    );
    if (artifact.device.abi_version != metal.device_info_abi or
        artifact.device.registry_id == 0 or
        artifact.device.max_threads_x == 0 or
        artifact.device.max_threads_y == 0 or
        artifact.device.max_threads_z == 0 or
        artifact.device.low_power > 1 or
        artifact.device.headless > 1 or
        artifact.device.removable > 1 or
        artifact.device.unified_memory > 1)
        return error.InvalidReadinessArtifact;
    if (!std.meta.eql(artifact.descriptor, expected_descriptor) or
        !std.meta.eql(artifact.plan, expected_plan) or
        !contract.digestEqual(
            artifact.plan.workload_profile_sha256,
            canonical.workload_profile_sha256,
        ) or
        !contract.digestEqual(
            artifact.plan.artifact_sha256,
            canonical.artifact_sha256,
        ) or
        !contract.digestEqual(
            artifact.plan.build_sha256,
            canonical.build_sha256,
        ) or
        !contract.digestEqual(
            artifact.plan.backend_sha256,
            contract.digestV1("Metal.framework backend/v1"),
        ) or
        !contract.digestEqual(
            artifact.plan.challenge_sha256,
            contract.digestV1(
                "native macos metal readiness challenge/v1",
            ),
        ) or
        !contract.digestEqual(
            artifact.plan.device_sha256,
            deviceIdentityV1(artifact.device),
        ) or
        !contract.digestEqual(
            artifact.plan.placement_sha256,
            placementIdentityV1(artifact.device),
        ) or
        artifact.plan.execution_plane != .accelerator or
        artifact.plan.worker_count != 1 or
        artifact.plan.queue_count != 1 or
        artifact.run.report.decision != .publishable or
        artifact.run.report.last_phase != .post_run or
        artifact.run.report.workload_invocations != 1 or
        artifact.run.report.begin_invocations != 1 or
        artifact.run.report.end_invocations != 1 or
        artifact.run.receipt.status != .succeeded or
        artifact.run.receipt.correctness != .passed or
        artifact.run.receipt.zero_orphans != .passed or
        artifact.run.receipt.fallback != .absent or
        artifact.run.receipt.profile_count != 1 or
        artifact.run.receipt.item_count != 1 or
        artifact.workload.abi_version != workload_evidence_abi or
        artifact.workload.max_abs_error_bits !=
            expected_max_abs_error_bits or
        !std.math.isFinite(maximum_error) or
        maximum_error < 0 or
        maximum_error > maximum_abs_error or
        !contract.digestEqual(
            artifact.workload.oracle_output_sha256,
            canonical.oracle_output_sha256,
        ) or
        !contract.digestEqual(
            artifact.dispatch.output_sha256,
            expected_output_sha256,
        ) or
        !contract.digestEqual(
            artifact.run.receipt.correctness_sha256,
            correctnessIdentityV1(
                artifact.workload,
                expected_output_sha256,
            ),
        ) or
        !contract.digestEqual(
            artifact.run.receipt.ownership_sha256,
            ownershipIdentityV1(artifact.workload),
        ) or
        artifact.workload.live_weights_before != 0 or
        artifact.workload.live_weights_after != 0 or
        artifact.workload.completed_dispatches_before != 0 or
        artifact.workload.completed_dispatches_after != 1 or
        artifact.dispatch.dispatch_ordinal !=
            artifact.workload.completed_dispatches_after or
        artifact.dispatch.live_weights_after !=
            artifact.workload.live_weights_after or
        artifact.dispatch.device_registry_id !=
            artifact.device.registry_id or
        artifact.dispatch.device_registry_id !=
            artifact.diagnostic.device_registry_id or
        artifact.dispatch.recommended_max_working_set_size !=
            artifact.device.recommended_max_working_set_size or
        artifact.diagnostic.logical_cpu_count == 0 or
        artifact.diagnostic.queue_count != artifact.plan.queue_count or
        artifact.diagnostic.direct_metric_bits !=
            artifact.descriptor.direct_metric_bits or
        !contract.digestEqual(
            artifact.plan.machine_sha256,
            machineIdentityV1(
                artifact.diagnostic.logical_cpu_count,
                artifact.plan.device_sha256,
            ),
        ) or
        !contract.digestEqual(
            artifact.run.receipt.result_sha256,
            workloadResultIdentityV1(
                artifact.dispatch.output_sha256,
                artifact.dispatch.receipt_sha256,
            ),
        ))
        return error.InvalidReadinessArtifact;

    if (!contract.digestEqual(
        artifact.diagnostic.descriptor_sha256,
        artifact.descriptor.descriptor_sha256,
    ) or
        !contract.digestEqual(
            artifact.diagnostic.plan_sha256,
            artifact.plan.plan_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.device_sha256,
            artifact.plan.device_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.placement_sha256,
            artifact.plan.placement_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.probe_bundle_sha256,
            artifact.run.probe.bundle_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.pre_run_bundle_sha256,
            artifact.run.pre_run.bundle_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.post_run_bundle_sha256,
            artifact.run.post_run.bundle_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.workload_receipt_sha256,
            artifact.run.receipt.receipt_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.run_report_sha256,
            artifact.run.report.report_sha256,
        ) or
        !contract.digestEqual(
            artifact.diagnostic.dispatch_receipt_sha256,
            artifact.dispatch.receipt_sha256,
        ))
        return error.InvalidReadinessArtifact;

    try validateReadinessBundleV1(
        artifact,
        artifact.run.probe,
        .probe,
    );
    try validateReadinessBundleV1(
        artifact,
        artifact.run.pre_run,
        .pre_run,
    );
    try validateReadinessBundleV1(
        artifact,
        artifact.run.post_run,
        .post_run,
    );

    const probe_device = contract.findObservationV1(
        artifact.run.probe,
        .accelerator_device_present,
    ) orelse return error.InvalidReadinessArtifact;
    const probe_allocated = contract.findObservationV1(
        artifact.run.probe,
        .accelerator_allocated_bytes,
    ) orelse return error.InvalidReadinessArtifact;
    const pre_device = contract.findObservationV1(
        artifact.run.pre_run,
        .accelerator_device_present,
    ) orelse return error.InvalidReadinessArtifact;
    const post_device = contract.findObservationV1(
        artifact.run.post_run,
        .accelerator_device_present,
    ) orelse return error.InvalidReadinessArtifact;
    const post_device_time = contract.findObservationV1(
        artifact.run.post_run,
        .accelerator_device_time,
    ) orelse return error.InvalidReadinessArtifact;
    const expected_device_time = std.math.cast(
        i64,
        artifact.dispatch.gpu_duration_nanoseconds,
    ) orelse return error.InvalidReadinessArtifact;
    const initial_allocated = std.math.cast(
        i64,
        artifact.device.current_allocated_size,
    ) orelse return error.InvalidReadinessArtifact;
    if (probe_allocated.availability != .present or
        probe_allocated.value != initial_allocated or
        !contract.digestEqual(
            probe_device.source_sha256,
            sourceIdentityV1(),
        ) or
        !contract.digestEqual(
            probe_device.source_sha256,
            pre_device.source_sha256,
        ) or
        !contract.digestEqual(
            pre_device.source_sha256,
            post_device.source_sha256,
        ) or
        !contract.digestEqual(
            post_device.source_sha256,
            post_device_time.source_sha256,
        ) or
        !contract.digestEqual(
            probe_device.subject_sha256,
            artifact.plan.device_sha256,
        ) or
        !contract.digestEqual(
            pre_device.subject_sha256,
            post_device.subject_sha256,
        ) or
        !contract.digestEqual(
            post_device.subject_sha256,
            post_device_time.subject_sha256,
        ) or
        contract.digestEqual(
            pre_device.provenance_sha256,
            post_device.provenance_sha256,
        ) or
        post_device_time.value != expected_device_time or
        !contract.digestEqual(
            post_device_time.value_clock_domain_sha256,
            contract.digestV1(
                "Metal MTLCommandBuffer GPUStartTime GPUEndTime host time/v1",
            ),
        ) or
        !contract.digestEqual(
            post_device_time.provenance_sha256,
            artifact.dispatch.receipt_sha256,
        ))
        return error.InvalidReadinessArtifact;
}

fn validateReadinessBundleV1(
    artifact: ReadinessArtifactV1,
    bundle: contract.ObservationBundleV1,
    phase: contract.PhaseV1,
) !void {
    if (bundle.phase != phase or bundle.record_count != 14)
        return error.InvalidReadinessArtifact;
    const host_time = contract.findObservationV1(
        bundle,
        .host_monotonic_time,
    ) orelse return error.InvalidReadinessArtifact;
    const host_cpu = contract.findObservationV1(
        bundle,
        .host_logical_cpu_count,
    ) orelse return error.InvalidReadinessArtifact;
    const device = contract.findObservationV1(
        bundle,
        .accelerator_device_present,
    ) orelse return error.InvalidReadinessArtifact;
    const fallback = contract.findObservationV1(
        bundle,
        .accelerator_cpu_fallback,
    ) orelse return error.InvalidReadinessArtifact;
    const allocated = contract.findObservationV1(
        bundle,
        .accelerator_allocated_bytes,
    ) orelse return error.InvalidReadinessArtifact;
    const host_source = contract.digestV1(
        "std.Thread.getCpuCount+std.time.Timer/v1",
    );
    const host_clock = contract.digestV1(
        "std.time.Timer monotonic ticks/v1",
    );
    const expected_host_time = std.math.cast(
        i64,
        host_time.observed_at_ticks,
    ) orelse return error.InvalidReadinessArtifact;
    const expected_cpu_count = std.math.cast(
        i64,
        artifact.diagnostic.logical_cpu_count,
    ) orelse return error.InvalidReadinessArtifact;
    const expected_host_provenance = hostProvenanceV1(
        phase,
        host_time.observed_at_ticks,
        artifact.diagnostic.logical_cpu_count,
    );
    var observed_device = artifact.device;
    observed_device.current_allocated_size = std.math.cast(
        u64,
        allocated.value,
    ) orelse return error.InvalidReadinessArtifact;
    const phase_dispatch_sha256 = if (phase == .post_run)
        artifact.dispatch.receipt_sha256
    else
        contract.zero_digest;
    const expected_phase_provenance = observationProvenanceV1(
        phase,
        allocated.observed_at_ticks,
        observed_device,
        phase_dispatch_sha256,
    );
    if (host_time.availability != .present or
        host_time.value != expected_host_time or
        host_cpu.availability != .present or
        host_cpu.value != expected_cpu_count or
        !contract.digestEqual(host_time.source_sha256, host_source) or
        !contract.digestEqual(host_cpu.source_sha256, host_source) or
        host_cpu.observed_at_ticks != host_time.observed_at_ticks or
        !contract.digestEqual(
            host_time.provenance_sha256,
            expected_host_provenance,
        ) or
        !contract.digestEqual(
            host_cpu.provenance_sha256,
            expected_host_provenance,
        ) or
        !contract.digestEqual(
            host_time.sample_clock_domain_sha256,
            host_clock,
        ) or
        !contract.digestEqual(
            host_cpu.sample_clock_domain_sha256,
            host_clock,
        ) or
        !contract.digestEqual(
            host_time.subject_sha256,
            artifact.plan.machine_sha256,
        ) or
        !contract.digestEqual(
            host_cpu.subject_sha256,
            artifact.plan.machine_sha256,
        ) or
        device.availability != .present or device.value != 1 or
        fallback.availability != .present or fallback.value != 0 or
        allocated.availability != .present or allocated.value < 0)
        return error.InvalidReadinessArtifact;

    inline for ([_]contract.MetricIdV1{
        .accelerator_device_present,
        .accelerator_cpu_fallback,
        .accelerator_utilization,
        .accelerator_allocated_bytes,
        .accelerator_committed_bytes,
        .accelerator_resident_bytes,
        .accelerator_queue_depth,
        .accelerator_temperature,
        .accelerator_frequency,
        .accelerator_power,
        .accelerator_energy,
        .accelerator_device_time,
    }) |metric| {
        const record = contract.findObservationV1(
            bundle,
            metric,
        ) orelse return error.InvalidReadinessArtifact;
        if (!contract.digestEqual(
            record.source_sha256,
            sourceIdentityV1(),
        ) or
            !contract.digestEqual(
                record.subject_sha256,
                artifact.plan.device_sha256,
            ) or
            !contract.digestEqual(
                record.sample_clock_domain_sha256,
                host_clock,
            ) or
            record.observed_at_ticks != allocated.observed_at_ticks or
            (metric != .accelerator_device_time or
                phase != .post_run) and
                !contract.digestEqual(
                    record.provenance_sha256,
                    expected_phase_provenance,
                ))
            return error.InvalidReadinessArtifact;
    }

    inline for ([_]struct {
        metric: contract.MetricIdV1,
        reason: []const u8,
    }{
        .{
            .metric = .accelerator_utilization,
            .reason = "Metal utilization has no direct adapter/v1",
        },
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
        const record = contract.findObservationV1(
            bundle,
            unavailable.metric,
        ) orelse return error.InvalidReadinessArtifact;
        if (record.availability != .unsupported or
            record.value != 0 or
            !contract.digestEqual(
                record.reason_sha256,
                contract.digestV1(unavailable.reason),
            ))
            return error.InvalidReadinessArtifact;
    }

    const device_time = contract.findObservationV1(
        bundle,
        .accelerator_device_time,
    ) orelse return error.InvalidReadinessArtifact;
    if (phase == .post_run) {
        if (device_time.availability != .present or
            device_time.value <= 0)
            return error.InvalidReadinessArtifact;
    } else if (device_time.availability != .missing or
        device_time.value != 0 or
        !contract.digestEqual(
            device_time.reason_sha256,
            contract.digestV1(
                "No completed Metal command buffer in this phase/v1",
            ),
        ))
        return error.InvalidReadinessArtifact;
}

fn makeDiagnosticReportV1(
    observer: MacOSMetalObserverV1,
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    run: runner.RunArtifactV1,
    dispatch: DispatchReceiptV1,
) !DiagnosticReportV1 {
    var missing_count: u64 = 0;
    var unsupported_count: u64 = 0;
    var unavailable_reason_count: u64 = 0;
    var present_reason_count: u64 = 0;
    const bundles = [_]contract.ObservationBundleV1{
        run.probe,
        run.pre_run,
        run.post_run,
    };
    for (bundles) |bundle| {
        const count = std.math.cast(
            usize,
            bundle.record_count,
        ) orelse return error.InvalidObservationCount;
        if (count > contract.maximum_observations)
            return error.InvalidObservationCount;
        for (bundle.records[0..count]) |record| {
            switch (record.availability) {
                .missing => missing_count = try std.math.add(
                    u64,
                    missing_count,
                    1,
                ),
                .unsupported => unsupported_count = try std.math.add(
                    u64,
                    unsupported_count,
                    1,
                ),
                else => {},
            }
            if (record.availability == .present) {
                if (!contract.digestIsZero(record.reason_sha256))
                    present_reason_count = try std.math.add(
                        u64,
                        present_reason_count,
                        1,
                    );
            } else if (!contract.digestIsZero(
                record.reason_sha256,
            )) {
                unavailable_reason_count = try std.math.add(
                    u64,
                    unavailable_reason_count,
                    1,
                );
            }
        }
    }
    return .{
        .device_registry_id = observer.initial_device.registry_id,
        .logical_cpu_count = observer.logical_cpu_count,
        .queue_count = plan.queue_count,
        .direct_metric_bits = descriptor.direct_metric_bits,
        .unsupported_metric_bits = try unsupportedMetricBits(),
        .missing_observation_count = missing_count,
        .unsupported_observation_count = unsupported_count,
        .unavailable_reason_count = unavailable_reason_count,
        .present_reason_count = present_reason_count,
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
}

fn append(
    output: *[contract.maximum_observations]contract.ObservationV1,
    count: *usize,
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    phase: contract.PhaseV1,
    metric: contract.MetricIdV1,
    availability: contract.AvailabilityV1,
    value: i64,
    observed_at: u64,
    sample_clock: Digest,
    value_clock: Digest,
    source: Digest,
    provenance: Digest,
    subject: Digest,
    reason: Digest,
) !void {
    if (count.* >= output.len)
        return error.ObservationLimitExceeded;
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

fn appendUnavailable(
    output: *[contract.maximum_observations]contract.ObservationV1,
    count: *usize,
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    phase: contract.PhaseV1,
    metric: contract.MetricIdV1,
    observed_at: u64,
    sample_clock: Digest,
    source: Digest,
    provenance: Digest,
    subject: Digest,
    reason: []const u8,
) !void {
    try append(
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
        contract.zero_digest,
        source,
        provenance,
        subject,
        contract.digestV1(reason),
    );
}

fn declaredMetricBits() !u64 {
    var bits: u64 = 0;
    inline for ([_]contract.MetricIdV1{
        .host_monotonic_time,
        .host_logical_cpu_count,
        .accelerator_device_present,
        .accelerator_cpu_fallback,
        .accelerator_utilization,
        .accelerator_allocated_bytes,
        .accelerator_committed_bytes,
        .accelerator_resident_bytes,
        .accelerator_queue_depth,
        .accelerator_temperature,
        .accelerator_frequency,
        .accelerator_power,
        .accelerator_energy,
        .accelerator_device_time,
    }) |metric| {
        bits |= try contract.metricBitV1(metric);
    }
    return bits;
}

fn directMetricBits() !u64 {
    var bits: u64 = 0;
    inline for ([_]contract.MetricIdV1{
        .host_monotonic_time,
        .host_logical_cpu_count,
        .accelerator_device_present,
        .accelerator_cpu_fallback,
        .accelerator_allocated_bytes,
        .accelerator_device_time,
    }) |metric| {
        bits |= try contract.metricBitV1(metric);
    }
    return bits;
}

fn unsupportedMetricBits() !u64 {
    var bits: u64 = 0;
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
        bits |= try contract.metricBitV1(metric);
    }
    return bits;
}

pub fn deviceIdentityV1(info: metal.MetalDeviceInfo) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(device_identity_domain);
    hashDeviceInfo(&hash, info);
    return finish(&hash);
}

pub fn placementIdentityV1(info: metal.MetalDeviceInfo) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(placement_identity_domain);
    hashU64(&hash, info.registry_id);
    hashU64(&hash, info.location);
    hashU64(&hash, info.location_number);
    hashU64(&hash, info.low_power);
    hashU64(&hash, info.headless);
    hashU64(&hash, info.removable);
    hashU64(&hash, info.unified_memory);
    return finish(&hash);
}

pub fn machineIdentityV1(
    logical_cpu_count: u64,
    device_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(machine_identity_domain);
    hashU64(&hash, logical_cpu_count);
    hash.update(&device_sha256);
    return finish(&hash);
}

pub fn sourceIdentityV1() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(source_identity_domain);
    hashU64(&hash, observer_implementation_abi);
    hash.update(
        "Metal.framework MTLDevice+MTLCommandBuffer direct adapter/v1",
    );
    return finish(&hash);
}

pub fn observationProvenanceV1(
    phase: contract.PhaseV1,
    observed_at: u64,
    info: metal.MetalDeviceInfo,
    dispatch_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(provenance_domain);
    hashU64(&hash, @intFromEnum(phase));
    hashU64(&hash, observed_at);
    hashU64(&hash, info.registry_id);
    hashU64(&hash, info.current_allocated_size);
    hash.update(&dispatch_sha256);
    return finish(&hash);
}

pub fn hostProvenanceV1(
    phase: contract.PhaseV1,
    observed_at: u64,
    logical_cpu_count: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-host-readiness-provenance-v1\x00");
    hashU64(&hash, @intFromEnum(phase));
    hashU64(&hash, observed_at);
    hashU64(&hash, logical_cpu_count);
    return finish(&hash);
}

fn hashDeviceInfo(
    hash: *std.crypto.hash.sha2.Sha256,
    info: metal.MetalDeviceInfo,
) void {
    hashU64(hash, info.abi_version);
    hashU64(hash, info.registry_id);
    hashU64(hash, info.recommended_max_working_set_size);
    hashU64(hash, info.location);
    hashU64(hash, info.location_number);
    hashU64(hash, info.max_threads_x);
    hashU64(hash, info.max_threads_y);
    hashU64(hash, info.max_threads_z);
    hashU64(hash, info.low_power);
    hashU64(hash, info.headless);
    hashU64(hash, info.removable);
    hashU64(hash, info.unified_memory);
}

pub fn outputIdentityV1(
    output_bits: [out_features]u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(output_domain);
    hashU64(&hash, output_bits.len);
    for (output_bits) |bits| hashU64(&hash, bits);
    return finish(&hash);
}

pub fn oracleOutputIdentityV1(
    output_bits: [out_features]u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(oracle_output_domain);
    hashU64(&hash, output_bits.len);
    for (output_bits) |bits| hashU64(&hash, bits);
    return finish(&hash);
}

pub fn maximumAbsErrorBitsV1(
    oracle_output_bits: [out_features]u32,
    gpu_output_bits: [out_features]u32,
) !u32 {
    var maximum: f32 = 0;
    for (oracle_output_bits, gpu_output_bits) |expected_bits, actual_bits| {
        const expected: f32 = @bitCast(expected_bits);
        const actual: f32 = @bitCast(actual_bits);
        if (!std.math.isFinite(expected) or
            !std.math.isFinite(actual))
            return error.InvalidOutput;
        maximum = @max(maximum, @abs(expected - actual));
    }
    return @bitCast(maximum);
}

pub fn correctnessIdentityV1(
    evidence: WorkloadEvidenceV1,
    output_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(correctness_domain);
    hashU64(&hash, evidence.abi_version);
    hashU64(&hash, evidence.max_abs_error_bits);
    const maximum: f32 = @bitCast(evidence.max_abs_error_bits);
    hashU64(
        &hash,
        @intFromBool(
            std.math.isFinite(maximum) and
                maximum >= 0 and
                maximum <= maximum_abs_error,
        ),
    );
    hashU64(&hash, in_features);
    hashU64(&hash, out_features);
    hashU64(&hash, group_size);
    hash.update(&evidence.oracle_output_sha256);
    hash.update(&output_sha256);
    return finish(&hash);
}

pub fn ownershipIdentityV1(
    evidence: WorkloadEvidenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(ownership_domain);
    hashU64(&hash, evidence.abi_version);
    hashU64(&hash, evidence.live_weights_before);
    hashU64(&hash, evidence.live_weights_after);
    hashU64(&hash, evidence.completed_dispatches_before);
    hashU64(&hash, evidence.completed_dispatches_after);
    return finish(&hash);
}

pub fn workloadResultIdentityV1(
    output_sha256: Digest,
    dispatch_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(workload_result_domain);
    hash.update(&output_sha256);
    hash.update(&dispatch_sha256);
    return finish(&hash);
}

fn fillCanonicalFixture(
    weights: *[in_features * out_features]f32,
    input: *[in_features]f32,
) void {
    for (weights, 0..) |*value, index| {
        value.* =
            @as(f32, @floatFromInt((index * 29 + 7) % 101)) /
            127.0 - 0.4;
    }
    for (input, 0..) |*value, index| {
        value.* =
            @as(f32, @floatFromInt((index * 13 + 3) % 47)) /
            31.0 - 0.7;
    }
}

fn workloadProfileIdentity(
    input: *const [in_features]f32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(workload_profile_domain);
    hashU64(&hash, in_features);
    hashU64(&hash, out_features);
    hashU64(&hash, group_size);
    hashU64(
        &hash,
        @as(u64, @bitCast(@as(f64, maximum_abs_error))),
    );
    hash.update(std.mem.sliceAsBytes(input[0..]));
    return finish(&hash);
}

fn fixtureArtifactIdentity(
    packed_weights: []const u8,
    scales: []const f32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(fixture_artifact_domain);
    hashU64(&hash, packed_weights.len);
    hash.update(packed_weights);
    hashU64(&hash, scales.len);
    hash.update(std.mem.sliceAsBytes(scales));
    return finish(&hash);
}

fn readinessBuildIdentity() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(build_identity_domain);
    hashU64(&hash, observer_implementation_abi);
    hashU64(&hash, dispatch_receipt_abi);
    hashU64(&hash, diagnostic_report_abi);
    hash.update("native macos Metal readiness implementation/v1");
    return finish(&hash);
}

pub fn canonicalIdentityV1(
    allocator: std.mem.Allocator,
) !CanonicalIdentityV1 {
    var weights: [in_features * out_features]f32 = undefined;
    var input: [in_features]f32 = undefined;
    fillCanonicalFixture(&weights, &input);
    const quantized = try core.quant.quantize(
        f32,
        allocator,
        &weights,
        .int4,
        group_size,
    );
    defer {
        allocator.free(quantized.packed_bytes);
        allocator.free(quantized.scales);
    }
    var input_tensor = try core.tensor.fromF32(
        allocator,
        &.{ 1, in_features },
        &input,
    );
    defer input_tensor.deinit();
    var oracle_output = try core.tensor.zerosF32(
        allocator,
        &.{ 1, out_features },
    );
    defer oracle_output.deinit();
    try cpu_int4.linearInt4OnTheFly(
        input_tensor,
        quantized.packed_bytes,
        quantized.scales,
        &.{},
        oracle_output,
        out_features,
        in_features,
        group_size,
    );
    var oracle_output_bits: [out_features]u32 = undefined;
    for (oracle_output.asF32(), &oracle_output_bits) |value, *bits| {
        if (!std.math.isFinite(value))
            return error.InvalidCanonicalOracle;
        bits.* = @bitCast(value);
    }
    return .{
        .workload_profile_sha256 = workloadProfileIdentity(&input),
        .artifact_sha256 = fixtureArtifactIdentity(
            quantized.packed_bytes,
            quantized.scales,
        ),
        .build_sha256 = readinessBuildIdentity(),
        .oracle_output_bits = oracle_output_bits,
        .oracle_output_sha256 = oracleOutputIdentityV1(
            oracle_output_bits,
        ),
    };
}

fn durationNanoseconds(start: f64, end: f64) ?u64 {
    if (!std.math.isFinite(start) or
        !std.math.isFinite(end) or
        start <= 0 or end <= start)
        return null;
    const value = (end - start) * 1_000_000_000.0;
    if (!std.math.isFinite(value) or
        value < 1 or
        value >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
        return null;
    return @intFromFloat(value);
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    const normalized: u64 = switch (@TypeOf(value)) {
        u1, u8, u16, u32, u64, usize, comptime_int => @intCast(value),
        else => @compileError("hashU64 requires an unsigned integer"),
    };
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, normalized, .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}
