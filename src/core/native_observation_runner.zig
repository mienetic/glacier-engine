//! Fail-closed runtime orchestration for native workload observations.
//!
//! The runner validates a portable plan, collects bounded probe/pre/post
//! bundles, and invokes the workload at most once. Policy rejection is
//! retained as report data. Pre-run rejection never starts the workload;
//! post-run contamination preserves the receipt but makes the run
//! nonpublishable. Observer and workload callbacks are process-local and are
//! deliberately excluded from the portable evidence contract.

const std = @import("std");
pub const contract = @import("native_observation_contract.zig");
const perception = @import("typed_perception_workload.zig");
const workload_driver = @import("typed_workload_driver.zig");

pub const Digest = contract.Digest;
pub const zero_digest = contract.zero_digest;

pub const workload_receipt_abi: u64 = 0x474e_4f57_0000_0001;
pub const run_report_abi: u64 = 0x474e_4f52_0000_0001;
pub const reference_report_abi: u64 = 0x474e_4f46_0000_0001;

const workload_receipt_domain =
    "glacier-native-observation-workload-receipt-v1\x00";
const run_report_domain =
    "glacier-native-observation-run-report-v1\x00";
const reference_report_domain =
    "glacier-native-observation-reference-report-v1\x00";

pub const reason_callback_probe: u64 = 1 << 0;
pub const reason_callback_pre_run: u64 = 1 << 1;
pub const reason_callback_begin: u64 = 1 << 2;
pub const reason_callback_workload: u64 = 1 << 3;
pub const reason_callback_end: u64 = 1 << 4;
pub const reason_callback_post_run: u64 = 1 << 5;
pub const reason_invalid_receipt: u64 = 1 << 6;
pub const reason_workload_status: u64 = 1 << 7;
pub const reason_correctness_gate: u64 = 1 << 8;
pub const reason_orphan_gate: u64 = 1 << 9;
pub const reason_accelerator_fallback: u64 = 1 << 10;
pub const reason_clock_regression: u64 = 1 << 11;

pub const Error = contract.Error || perception.Error || error{
    InvalidObserver,
    InvalidReceipt,
    InvalidReport,
};

pub const CallbackError = error{
    ObserverUnavailable,
    PermissionDenied,
    InvalidSample,
    WorkloadUnavailable,
    InjectedFailure,
};

pub const WorkloadStatusV1 = enum(u8) {
    unused = 0,
    succeeded = 1,
    failed = 2,
};

pub const GateStateV1 = enum(u8) {
    unused = 0,
    passed = 1,
    failed = 2,
};

pub const FallbackStateV1 = enum(u8) {
    unused = 0,
    not_applicable = 1,
    not_observed = 2,
    absent = 3,
    present = 4,
};

pub const DecisionV1 = enum(u8) {
    unused = 0,
    publishable = 1,
    rejected_pre_run = 2,
    workload_failed = 3,
    rejected_post_run = 4,
};

pub const WorkloadReceiptV1 = struct {
    abi_version: u64 = 0,
    run_sha256: Digest = zero_digest,
    execution_plane: contract.ExecutionPlaneV1 = .unused,
    status: WorkloadStatusV1 = .unused,
    correctness: GateStateV1 = .unused,
    zero_orphans: GateStateV1 = .unused,
    fallback: FallbackStateV1 = .unused,
    profile_count: u64 = 0,
    item_count: u64 = 0,
    backend_sha256: Digest = zero_digest,
    device_sha256: Digest = zero_digest,
    placement_sha256: Digest = zero_digest,
    result_sha256: Digest = zero_digest,
    correctness_sha256: Digest = zero_digest,
    ownership_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

pub const RunReportV1 = struct {
    abi_version: u64 = 0,
    descriptor_sha256: Digest = zero_digest,
    plan_sha256: Digest = zero_digest,
    probe_bundle_sha256: Digest = zero_digest,
    pre_run_bundle_sha256: Digest = zero_digest,
    post_run_bundle_sha256: Digest = zero_digest,
    workload_receipt_sha256: Digest = zero_digest,
    decision: DecisionV1 = .unused,
    last_phase: contract.PhaseV1 = .unused,
    workload_invocations: u64 = 0,
    begin_invocations: u64 = 0,
    end_invocations: u64 = 0,
    callback_failure_bits: u64 = 0,
    missing_metric_bits: u64 = 0,
    denied_metric_bits: u64 = 0,
    unsupported_metric_bits: u64 = 0,
    threshold_metric_bits: u64 = 0,
    source_mismatch_bits: u64 = 0,
    subject_mismatch_bits: u64 = 0,
    reason_bits: u64 = 0,
    elapsed_nanoseconds: u64 = 0,
    report_sha256: Digest = zero_digest,
};

pub const RunArtifactV1 = struct {
    probe: contract.ObservationBundleV1 = .{},
    pre_run: contract.ObservationBundleV1 = .{},
    post_run: contract.ObservationBundleV1 = .{},
    receipt: WorkloadReceiptV1 = .{},
    report: RunReportV1 = .{},
};

pub const ObserverV1 = struct {
    context: *anyopaque,
    descriptor: contract.DescriptorV1,
    collect_fn: *const fn (
        context: *anyopaque,
        descriptor: *const contract.DescriptorV1,
        plan: *const contract.PlanV1,
        phase: contract.PhaseV1,
        records: *[contract.maximum_observations]contract.ObservationV1,
    ) CallbackError!usize,
    transition_fn: *const fn (
        context: *anyopaque,
        phase: contract.PhaseV1,
    ) CallbackError!void,
};

pub const WorkloadV1 = struct {
    context: *anyopaque,
    run_fn: *const fn (
        context: *anyopaque,
        plan: *const contract.PlanV1,
    ) CallbackError!WorkloadReceiptV1,
};

const EvaluationV1 = struct {
    missing_metric_bits: u64 = 0,
    denied_metric_bits: u64 = 0,
    unsupported_metric_bits: u64 = 0,
    threshold_metric_bits: u64 = 0,
    source_mismatch_bits: u64 = 0,
    subject_mismatch_bits: u64 = 0,

    fn rejected(self: EvaluationV1) bool {
        return self.missing_metric_bits != 0 or
            self.denied_metric_bits != 0 or
            self.unsupported_metric_bits != 0 or
            self.threshold_metric_bits != 0 or
            self.source_mismatch_bits != 0 or
            self.subject_mismatch_bits != 0;
    }

    fn merge(self: *EvaluationV1, other: EvaluationV1) void {
        self.missing_metric_bits |= other.missing_metric_bits;
        self.denied_metric_bits |= other.denied_metric_bits;
        self.unsupported_metric_bits |= other.unsupported_metric_bits;
        self.threshold_metric_bits |= other.threshold_metric_bits;
        self.source_mismatch_bits |= other.source_mismatch_bits;
        self.subject_mismatch_bits |= other.subject_mismatch_bits;
    }
};

pub fn makeWorkloadReceiptV1(
    plan: contract.PlanV1,
    status: WorkloadStatusV1,
    correctness: GateStateV1,
    zero_orphans: GateStateV1,
    fallback: FallbackStateV1,
    profile_count: u64,
    item_count: u64,
    result_sha256: Digest,
    correctness_sha256: Digest,
    ownership_sha256: Digest,
) Error!WorkloadReceiptV1 {
    var result: WorkloadReceiptV1 = .{
        .abi_version = workload_receipt_abi,
        .run_sha256 = plan.run_sha256,
        .execution_plane = plan.execution_plane,
        .status = status,
        .correctness = correctness,
        .zero_orphans = zero_orphans,
        .fallback = fallback,
        .profile_count = profile_count,
        .item_count = item_count,
        .backend_sha256 = plan.backend_sha256,
        .device_sha256 = plan.device_sha256,
        .placement_sha256 = plan.placement_sha256,
        .result_sha256 = result_sha256,
        .correctness_sha256 = correctness_sha256,
        .ownership_sha256 = ownership_sha256,
    };
    result.receipt_sha256 = workloadReceiptSha256V1(result);
    try validateWorkloadReceiptV1(plan, result);
    return result;
}

pub fn workloadReceiptSha256V1(value: WorkloadReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(workload_receipt_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.run_sha256);
    hashU64(&hash, @intFromEnum(value.execution_plane));
    hashU64(&hash, @intFromEnum(value.status));
    hashU64(&hash, @intFromEnum(value.correctness));
    hashU64(&hash, @intFromEnum(value.zero_orphans));
    hashU64(&hash, @intFromEnum(value.fallback));
    hashU64(&hash, value.profile_count);
    hashU64(&hash, value.item_count);
    hash.update(&value.backend_sha256);
    hash.update(&value.device_sha256);
    hash.update(&value.placement_sha256);
    hash.update(&value.result_sha256);
    hash.update(&value.correctness_sha256);
    hash.update(&value.ownership_sha256);
    return finish(&hash);
}

pub fn validateWorkloadReceiptV1(
    plan: contract.PlanV1,
    value: WorkloadReceiptV1,
) Error!void {
    if (value.abi_version != workload_receipt_abi or
        !contract.digestEqual(value.run_sha256, plan.run_sha256) or
        value.execution_plane != plan.execution_plane or
        value.status == .unused or
        value.correctness == .unused or
        value.zero_orphans == .unused or
        value.fallback == .unused or
        value.profile_count == 0 or value.item_count == 0 or
        !contract.digestEqual(
            value.backend_sha256,
            plan.backend_sha256,
        ) or
        !contract.digestEqual(
            value.device_sha256,
            plan.device_sha256,
        ) or
        !contract.digestEqual(
            value.placement_sha256,
            plan.placement_sha256,
        ) or
        contract.digestIsZero(value.result_sha256) or
        contract.digestIsZero(value.correctness_sha256) or
        contract.digestIsZero(value.ownership_sha256) or
        !contract.digestEqual(
            value.receipt_sha256,
            workloadReceiptSha256V1(value),
        ))
        return Error.InvalidReceipt;
    switch (plan.execution_plane) {
        .host => if (value.fallback != .not_applicable)
            return Error.InvalidReceipt,
        .accelerator, .mixed => if (value.fallback == .not_applicable)
            return Error.InvalidReceipt,
        .unused => return Error.InvalidReceipt,
    }
}

pub fn runReportSha256V1(value: RunReportV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(run_report_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.plan_sha256);
    hash.update(&value.probe_bundle_sha256);
    hash.update(&value.pre_run_bundle_sha256);
    hash.update(&value.post_run_bundle_sha256);
    hash.update(&value.workload_receipt_sha256);
    hashU64(&hash, @intFromEnum(value.decision));
    hashU64(&hash, @intFromEnum(value.last_phase));
    hashU64(&hash, value.workload_invocations);
    hashU64(&hash, value.begin_invocations);
    hashU64(&hash, value.end_invocations);
    hashU64(&hash, value.callback_failure_bits);
    hashU64(&hash, value.missing_metric_bits);
    hashU64(&hash, value.denied_metric_bits);
    hashU64(&hash, value.unsupported_metric_bits);
    hashU64(&hash, value.threshold_metric_bits);
    hashU64(&hash, value.source_mismatch_bits);
    hashU64(&hash, value.subject_mismatch_bits);
    hashU64(&hash, value.reason_bits);
    hashU64(&hash, value.elapsed_nanoseconds);
    return finish(&hash);
}

/// Validates the self-contained shape and digest of a report. Use
/// `validateRunArtifactV1` when the referenced observation evidence is
/// available.
pub fn validateRunReportV1(value: RunReportV1) Error!void {
    if (value.abi_version != run_report_abi or
        contract.digestIsZero(value.descriptor_sha256) or
        contract.digestIsZero(value.plan_sha256) or
        (contract.digestIsZero(value.probe_bundle_sha256) and
            !(value.decision == .rejected_pre_run and
                value.callback_failure_bits &
                    reason_callback_probe != 0)) or
        value.decision == .unused or value.last_phase == .unused or
        value.workload_invocations > 1 or
        value.begin_invocations > 1 or value.end_invocations > 1 or
        value.end_invocations > value.begin_invocations or
        (value.workload_invocations > value.begin_invocations) or
        !contract.digestEqual(
            value.report_sha256,
            runReportSha256V1(value),
        ))
        return Error.InvalidReport;

    switch (value.decision) {
        .publishable => {
            if (value.workload_invocations != 1 or
                value.begin_invocations != 1 or
                value.end_invocations != 1 or
                contract.digestIsZero(value.pre_run_bundle_sha256) or
                contract.digestIsZero(value.post_run_bundle_sha256) or
                contract.digestIsZero(value.workload_receipt_sha256) or
                value.callback_failure_bits != 0 or
                value.missing_metric_bits != 0 or
                value.denied_metric_bits != 0 or
                value.unsupported_metric_bits != 0 or
                value.threshold_metric_bits != 0 or
                value.source_mismatch_bits != 0 or
                value.subject_mismatch_bits != 0 or
                value.reason_bits != 0)
                return Error.InvalidReport;
        },
        .rejected_pre_run => {
            if (value.workload_invocations != 0 or
                !contract.digestIsZero(value.workload_receipt_sha256))
                return Error.InvalidReport;
        },
        .workload_failed, .rejected_post_run => {
            if (value.workload_invocations != 1 or
                value.begin_invocations != 1 or
                value.end_invocations != 1)
                return Error.InvalidReport;
        },
        .unused => return Error.InvalidReport,
    }
}

/// Validates a retained run as one composed evidence object: descriptor,
/// plan, phase bundles, workload receipt, evaluation masks, lifecycle, and
/// final decision must all agree with the report roots.
pub fn validateRunArtifactV1(
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    artifact: RunArtifactV1,
) Error!void {
    try contract.validateDescriptorV1(descriptor);
    try contract.validatePlanV1(descriptor, plan);
    try validateRunReportV1(artifact.report);

    if (!contract.digestEqual(
        artifact.report.descriptor_sha256,
        descriptor.descriptor_sha256,
    ) or
        !contract.digestEqual(
            artifact.report.plan_sha256,
            plan.plan_sha256,
        ) or
        !contract.digestEqual(
            artifact.report.probe_bundle_sha256,
            artifact.probe.bundle_sha256,
        ) or
        !contract.digestEqual(
            artifact.report.pre_run_bundle_sha256,
            artifact.pre_run.bundle_sha256,
        ) or
        !contract.digestEqual(
            artifact.report.post_run_bundle_sha256,
            artifact.post_run.bundle_sha256,
        ) or
        !contract.digestEqual(
            artifact.report.workload_receipt_sha256,
            artifact.receipt.receipt_sha256,
        ))
        return Error.InvalidReport;

    const probe_present = try validateOptionalBundleV1(
        descriptor,
        plan,
        artifact.probe,
        .probe,
    );
    const pre_present = try validateOptionalBundleV1(
        descriptor,
        plan,
        artifact.pre_run,
        .pre_run,
    );
    const post_present = try validateOptionalBundleV1(
        descriptor,
        plan,
        artifact.post_run,
        .post_run,
    );
    const receipt_present = if (contract.digestIsZero(
        artifact.receipt.receipt_sha256,
    )) blk: {
        if (!std.meta.eql(artifact.receipt, WorkloadReceiptV1{}))
            return Error.InvalidReport;
        break :blk false;
    } else blk: {
        try validateWorkloadReceiptV1(plan, artifact.receipt);
        break :blk true;
    };

    var admission_evaluation: EvaluationV1 = .{};
    if (probe_present) {
        admission_evaluation.merge(evaluatePhaseV1(
            plan,
            artifact.probe,
            null,
            .probe,
        ));
    }
    if (pre_present) {
        admission_evaluation.merge(evaluatePhaseV1(
            plan,
            artifact.pre_run,
            null,
            .pre_run,
        ));
    }
    var expected_evaluation = admission_evaluation;
    if (post_present) {
        if (!pre_present) return Error.InvalidReport;
        expected_evaluation.merge(evaluatePhaseV1(
            plan,
            artifact.post_run,
            artifact.pre_run,
            .post_run,
        ));
    }
    if (!evaluationMatchesReportV1(
        expected_evaluation,
        artifact.report,
    ))
        return Error.InvalidReport;

    const callback_mask =
        reason_callback_probe |
        reason_callback_pre_run |
        reason_callback_begin |
        reason_callback_workload |
        reason_callback_end |
        reason_callback_post_run;
    const reason_mask =
        reason_invalid_receipt |
        reason_workload_status |
        reason_correctness_gate |
        reason_orphan_gate |
        reason_accelerator_fallback |
        reason_clock_regression;
    if (artifact.report.callback_failure_bits & ~callback_mask != 0 or
        artifact.report.reason_bits & ~reason_mask != 0)
        return Error.InvalidReport;

    if (artifact.report.workload_invocations == 0) {
        if (post_present or receipt_present or
            artifact.report.end_invocations != 0 or
            artifact.report.reason_bits != 0 or
            artifact.report.elapsed_nanoseconds != 0)
            return Error.InvalidReport;
        switch (artifact.report.last_phase) {
            .probe => {
                if (pre_present or artifact.report.begin_invocations != 0)
                    return Error.InvalidReport;
                if (probe_present) {
                    if (artifact.report.callback_failure_bits != 0 or
                        !expected_evaluation.rejected())
                        return Error.InvalidReport;
                } else if (artifact.report.callback_failure_bits !=
                    reason_callback_probe)
                    return Error.InvalidReport;
            },
            .pre_run => {
                if (!probe_present or
                    artifact.report.begin_invocations != 0)
                    return Error.InvalidReport;
                if (pre_present) {
                    if (artifact.report.callback_failure_bits != 0 or
                        !expected_evaluation.rejected())
                        return Error.InvalidReport;
                } else if (artifact.report.callback_failure_bits !=
                    reason_callback_pre_run or
                    expected_evaluation.rejected())
                    return Error.InvalidReport;
            },
            .begin => {
                if (!probe_present or !pre_present or
                    artifact.report.begin_invocations != 1 or
                    artifact.report.callback_failure_bits !=
                        reason_callback_begin or
                    expected_evaluation.rejected())
                    return Error.InvalidReport;
            },
            else => return Error.InvalidReport,
        }
        if (artifact.report.decision != .rejected_pre_run)
            return Error.InvalidReport;
        return;
    }

    if (artifact.report.workload_invocations != 1 or
        artifact.report.begin_invocations != 1 or
        artifact.report.end_invocations != 1 or
        artifact.report.last_phase != .post_run or
        !probe_present or !pre_present or
        admission_evaluation.rejected() or
        artifact.report.callback_failure_bits &
            (reason_callback_probe |
                reason_callback_pre_run |
                reason_callback_begin) != 0)
        return Error.InvalidReport;
    if (post_present ==
        (artifact.report.callback_failure_bits &
            reason_callback_post_run != 0))
        return Error.InvalidReport;

    const workload_callback =
        artifact.report.callback_failure_bits &
        reason_callback_workload != 0;
    const invalid_receipt =
        artifact.report.reason_bits & reason_invalid_receipt != 0;
    if (receipt_present) {
        if (workload_callback or invalid_receipt)
            return Error.InvalidReport;
    } else if (workload_callback == invalid_receipt) {
        return Error.InvalidReport;
    }

    var expected_reason_bits: u64 = 0;
    if (invalid_receipt) expected_reason_bits |= reason_invalid_receipt;
    if (receipt_present) {
        if (artifact.receipt.status != .succeeded)
            expected_reason_bits |= reason_workload_status;
        if (artifact.receipt.correctness != .passed)
            expected_reason_bits |= reason_correctness_gate;
        if (artifact.receipt.zero_orphans != .passed)
            expected_reason_bits |= reason_orphan_gate;
        if ((plan.execution_plane == .accelerator or
            plan.execution_plane == .mixed) and
            artifact.receipt.fallback != .absent)
            expected_reason_bits |= reason_accelerator_fallback;
    }
    if (post_present) {
        expected_reason_bits |= clockRegressionReasonV1(
            artifact.pre_run,
            artifact.post_run,
        );
    }
    if (artifact.report.reason_bits != expected_reason_bits or
        artifact.report.elapsed_nanoseconds !=
            elapsedNanosecondsV1(
                artifact.pre_run,
                artifact.post_run,
            ))
        return Error.InvalidReport;

    const workload_failed =
        workload_callback or
        expected_reason_bits & (reason_invalid_receipt |
            reason_workload_status |
            reason_correctness_gate |
            reason_orphan_gate) != 0;
    const post_rejected =
        expected_evaluation.rejected() or
        artifact.report.callback_failure_bits &
            (reason_callback_end | reason_callback_post_run) != 0 or
        expected_reason_bits &
            (reason_accelerator_fallback |
                reason_clock_regression) != 0;
    const expected_decision: DecisionV1 = if (workload_failed)
        .workload_failed
    else if (post_rejected)
        .rejected_post_run
    else
        .publishable;
    if (artifact.report.decision != expected_decision)
        return Error.InvalidReport;
}

pub fn runObservedV1(
    plan: contract.PlanV1,
    observer: ObserverV1,
    workload: WorkloadV1,
) Error!RunArtifactV1 {
    try contract.validateDescriptorV1(observer.descriptor);
    try contract.validatePlanV1(observer.descriptor, plan);

    var artifact: RunArtifactV1 = .{};
    var evaluation: EvaluationV1 = .{};
    var callback_failure_bits: u64 = 0;
    var reason_bits: u64 = 0;
    var begin_invocations: u64 = 0;
    var end_invocations: u64 = 0;
    var workload_invocations: u64 = 0;
    var last_phase: contract.PhaseV1 = .probe;

    artifact.probe = collectBundleV1(
        observer,
        plan,
        .probe,
    ) catch {
        callback_failure_bits |= reason_callback_probe;
        artifact.report = try finishReportV1(
            observer.descriptor,
            plan,
            artifact,
            .rejected_pre_run,
            last_phase,
            workload_invocations,
            begin_invocations,
            end_invocations,
            callback_failure_bits,
            evaluation,
            reason_bits,
        );
        return artifact;
    };
    evaluation.merge(evaluatePhaseV1(
        plan,
        artifact.probe,
        null,
        .probe,
    ));
    if (evaluation.rejected()) {
        artifact.report = try finishReportV1(
            observer.descriptor,
            plan,
            artifact,
            .rejected_pre_run,
            last_phase,
            workload_invocations,
            begin_invocations,
            end_invocations,
            callback_failure_bits,
            evaluation,
            reason_bits,
        );
        return artifact;
    }

    last_phase = .pre_run;
    artifact.pre_run = collectBundleV1(
        observer,
        plan,
        .pre_run,
    ) catch {
        callback_failure_bits |= reason_callback_pre_run;
        artifact.report = try finishReportV1(
            observer.descriptor,
            plan,
            artifact,
            .rejected_pre_run,
            last_phase,
            workload_invocations,
            begin_invocations,
            end_invocations,
            callback_failure_bits,
            evaluation,
            reason_bits,
        );
        return artifact;
    };
    evaluation.merge(evaluatePhaseV1(
        plan,
        artifact.pre_run,
        null,
        .pre_run,
    ));
    if (evaluation.rejected()) {
        artifact.report = try finishReportV1(
            observer.descriptor,
            plan,
            artifact,
            .rejected_pre_run,
            last_phase,
            workload_invocations,
            begin_invocations,
            end_invocations,
            callback_failure_bits,
            evaluation,
            reason_bits,
        );
        return artifact;
    }

    last_phase = .begin;
    begin_invocations += 1;
    observer.transition_fn(observer.context, .begin) catch {
        callback_failure_bits |= reason_callback_begin;
        artifact.report = try finishReportV1(
            observer.descriptor,
            plan,
            artifact,
            .rejected_pre_run,
            last_phase,
            workload_invocations,
            begin_invocations,
            end_invocations,
            callback_failure_bits,
            evaluation,
            reason_bits,
        );
        return artifact;
    };

    last_phase = .in_run;
    workload_invocations += 1;
    artifact.receipt = workload.run_fn(
        workload.context,
        &plan,
    ) catch blk: {
        callback_failure_bits |= reason_callback_workload;
        break :blk WorkloadReceiptV1{};
    };
    if (callback_failure_bits & reason_callback_workload == 0) {
        validateWorkloadReceiptV1(
            plan,
            artifact.receipt,
        ) catch {
            reason_bits |= reason_invalid_receipt;
            artifact.receipt = .{};
        };
    }

    last_phase = .end;
    end_invocations += 1;
    observer.transition_fn(observer.context, .end) catch {
        callback_failure_bits |= reason_callback_end;
    };

    if (artifact.receipt.abi_version == workload_receipt_abi) {
        if (artifact.receipt.status != .succeeded)
            reason_bits |= reason_workload_status;
        if (artifact.receipt.correctness != .passed)
            reason_bits |= reason_correctness_gate;
        if (artifact.receipt.zero_orphans != .passed)
            reason_bits |= reason_orphan_gate;
        if ((plan.execution_plane == .accelerator or
            plan.execution_plane == .mixed) and
            artifact.receipt.fallback != .absent)
            reason_bits |= reason_accelerator_fallback;
    }
    const workload_failed =
        callback_failure_bits & reason_callback_workload != 0 or
        reason_bits & (reason_invalid_receipt |
            reason_workload_status |
            reason_correctness_gate |
            reason_orphan_gate) != 0;

    last_phase = .post_run;
    artifact.post_run = collectBundleV1(
        observer,
        plan,
        .post_run,
    ) catch {
        callback_failure_bits |= reason_callback_post_run;
        artifact.report = try finishReportV1(
            observer.descriptor,
            plan,
            artifact,
            if (workload_failed)
                .workload_failed
            else
                .rejected_post_run,
            last_phase,
            workload_invocations,
            begin_invocations,
            end_invocations,
            callback_failure_bits,
            evaluation,
            reason_bits,
        );
        return artifact;
    };
    evaluation.merge(evaluatePhaseV1(
        plan,
        artifact.post_run,
        artifact.pre_run,
        .post_run,
    ));

    reason_bits |= clockRegressionReasonV1(
        artifact.pre_run,
        artifact.post_run,
    );

    const post_rejected =
        evaluation.rejected() or
        callback_failure_bits &
            (reason_callback_end | reason_callback_post_run) != 0 or
        reason_bits &
            (reason_accelerator_fallback |
                reason_clock_regression) != 0;
    const decision: DecisionV1 = if (workload_failed)
        .workload_failed
    else if (post_rejected)
        .rejected_post_run
    else
        .publishable;
    artifact.report = try finishReportV1(
        observer.descriptor,
        plan,
        artifact,
        decision,
        last_phase,
        workload_invocations,
        begin_invocations,
        end_invocations,
        callback_failure_bits,
        evaluation,
        reason_bits,
    );
    return artifact;
}

fn collectBundleV1(
    observer: ObserverV1,
    plan: contract.PlanV1,
    phase: contract.PhaseV1,
) (contract.Error || CallbackError)!contract.ObservationBundleV1 {
    var records =
        [_]contract.ObservationV1{.{}} **
        contract.maximum_observations;
    const count = try observer.collect_fn(
        observer.context,
        &observer.descriptor,
        &plan,
        phase,
        &records,
    );
    if (count == 0 or count > contract.maximum_observations)
        return contract.Error.ObservationLimitExceeded;
    return contract.makeBundleV1(
        observer.descriptor,
        plan,
        phase,
        records[0..count],
    );
}

fn validateOptionalBundleV1(
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    bundle: contract.ObservationBundleV1,
    expected_phase: contract.PhaseV1,
) Error!bool {
    if (contract.digestIsZero(bundle.bundle_sha256)) {
        if (!std.meta.eql(bundle, contract.ObservationBundleV1{}))
            return Error.InvalidReport;
        return false;
    }
    try contract.validateBundleV1(descriptor, plan, bundle);
    if (bundle.phase != expected_phase)
        return Error.InvalidReport;
    return true;
}

fn evaluationMatchesReportV1(
    value: EvaluationV1,
    report: RunReportV1,
) bool {
    return value.missing_metric_bits == report.missing_metric_bits and
        value.denied_metric_bits == report.denied_metric_bits and
        value.unsupported_metric_bits ==
            report.unsupported_metric_bits and
        value.threshold_metric_bits == report.threshold_metric_bits and
        value.source_mismatch_bits == report.source_mismatch_bits and
        value.subject_mismatch_bits == report.subject_mismatch_bits;
}

fn evaluatePhaseV1(
    plan: contract.PlanV1,
    current: contract.ObservationBundleV1,
    previous: ?contract.ObservationBundleV1,
    phase: contract.PhaseV1,
) EvaluationV1 {
    var result: EvaluationV1 = .{};
    const rule_count = std.math.cast(usize, plan.rule_count) orelse
        return result;
    if (rule_count > contract.maximum_rules) return result;
    for (plan.rules[0..rule_count]) |rule| {
        const applies = switch (phase) {
            .probe => rule.scope == .probe,
            .pre_run => rule.scope == .pre_run or
                rule.scope == .pre_post,
            .post_run => rule.scope == .post_run or
                rule.scope == .pre_post,
            else => false,
        };
        if (!applies) continue;
        const bit = contract.metricBitV1(rule.metric) catch continue;
        const record = contract.findObservationV1(
            current,
            rule.metric,
        ) orelse {
            result.missing_metric_bits |= bit;
            continue;
        };
        if (!recordPresentV1(record, bit, &result)) continue;

        switch (rule.predicate) {
            .require_present => {},
            .inclusive_range => {
                if (record.value < rule.lower or
                    record.value > rule.upper)
                    result.threshold_metric_bits |= bit;
            },
            .require_false => {
                if (record.value != 0)
                    result.threshold_metric_bits |= bit;
            },
            .max_abs_delta, .same_source, .same_subject => {
                if (phase == .pre_run) continue;
                const prior_bundle = previous orelse {
                    result.missing_metric_bits |= bit;
                    continue;
                };
                const prior = contract.findObservationV1(
                    prior_bundle,
                    rule.metric,
                ) orelse {
                    result.missing_metric_bits |= bit;
                    continue;
                };
                if (!recordPresentV1(prior, bit, &result)) continue;
                switch (rule.predicate) {
                    .max_abs_delta => {
                        const delta =
                            @as(i128, record.value) -
                            @as(i128, prior.value);
                        const absolute = if (delta < 0) -delta else delta;
                        if (absolute > @as(i128, rule.upper))
                            result.threshold_metric_bits |= bit;
                    },
                    .same_source => {
                        if (!contract.digestEqual(
                            record.source_sha256,
                            prior.source_sha256,
                        ))
                            result.source_mismatch_bits |= bit;
                    },
                    .same_subject => {
                        if (!contract.digestEqual(
                            record.subject_sha256,
                            prior.subject_sha256,
                        ))
                            result.subject_mismatch_bits |= bit;
                    },
                    else => unreachable,
                }
            },
            .unused => unreachable,
        }
    }
    return result;
}

fn recordPresentV1(
    record: contract.ObservationV1,
    bit: u64,
    result: *EvaluationV1,
) bool {
    switch (record.availability) {
        .present => return true,
        .missing => result.missing_metric_bits |= bit,
        .denied => result.denied_metric_bits |= bit,
        .unsupported => result.unsupported_metric_bits |= bit,
        .unused => result.missing_metric_bits |= bit,
    }
    return false;
}

fn clockRegressionReasonV1(
    before: contract.ObservationBundleV1,
    after: contract.ObservationBundleV1,
) u64 {
    const pre = contract.findObservationV1(
        before,
        .host_monotonic_time,
    ) orelse return 0;
    const post = contract.findObservationV1(
        after,
        .host_monotonic_time,
    ) orelse return 0;
    if (pre.availability != .present or post.availability != .present)
        return 0;
    if (!contract.digestEqual(
        pre.value_clock_domain_sha256,
        post.value_clock_domain_sha256,
    ) or post.value < pre.value)
        return reason_clock_regression;
    return 0;
}

fn elapsedNanosecondsV1(
    before: contract.ObservationBundleV1,
    after: contract.ObservationBundleV1,
) u64 {
    const pre = contract.findObservationV1(
        before,
        .host_monotonic_time,
    ) orelse return 0;
    const post = contract.findObservationV1(
        after,
        .host_monotonic_time,
    ) orelse return 0;
    if (pre.availability != .present or
        post.availability != .present or
        !contract.digestEqual(
            pre.value_clock_domain_sha256,
            post.value_clock_domain_sha256,
        ) or post.value < pre.value)
        return 0;
    const delta = @as(i128, post.value) - @as(i128, pre.value);
    return std.math.cast(u64, delta) orelse 0;
}

fn finishReportV1(
    descriptor: contract.DescriptorV1,
    plan: contract.PlanV1,
    artifact: RunArtifactV1,
    decision: DecisionV1,
    last_phase: contract.PhaseV1,
    workload_invocations: u64,
    begin_invocations: u64,
    end_invocations: u64,
    callback_failure_bits: u64,
    evaluation: EvaluationV1,
    reason_bits: u64,
) Error!RunReportV1 {
    var result: RunReportV1 = .{
        .abi_version = run_report_abi,
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .plan_sha256 = plan.plan_sha256,
        .probe_bundle_sha256 = artifact.probe.bundle_sha256,
        .pre_run_bundle_sha256 = artifact.pre_run.bundle_sha256,
        .post_run_bundle_sha256 = artifact.post_run.bundle_sha256,
        .workload_receipt_sha256 = artifact.receipt.receipt_sha256,
        .decision = decision,
        .last_phase = last_phase,
        .workload_invocations = workload_invocations,
        .begin_invocations = begin_invocations,
        .end_invocations = end_invocations,
        .callback_failure_bits = callback_failure_bits,
        .missing_metric_bits = evaluation.missing_metric_bits,
        .denied_metric_bits = evaluation.denied_metric_bits,
        .unsupported_metric_bits = evaluation.unsupported_metric_bits,
        .threshold_metric_bits = evaluation.threshold_metric_bits,
        .source_mismatch_bits = evaluation.source_mismatch_bits,
        .subject_mismatch_bits = evaluation.subject_mismatch_bits,
        .reason_bits = reason_bits,
        .elapsed_nanoseconds = elapsedNanosecondsV1(
            artifact.pre_run,
            artifact.post_run,
        ),
    };
    result.report_sha256 = runReportSha256V1(result);
    try validateRunReportV1(result);
    var retained = artifact;
    retained.report = result;
    try validateRunArtifactV1(descriptor, plan, retained);
    return result;
}

const ReferenceObserverV1 = struct {
    transitions: [2]contract.PhaseV1 = .{ .unused, .unused },
    transition_count: usize = 0,
    external_cpu_post_ppm: i64 = 120_000,
    fallback_post: i64 = 0,

    fn interface(
        self: *ReferenceObserverV1,
        descriptor: contract.DescriptorV1,
    ) ObserverV1 {
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
    ) CallbackError!usize {
        const self: *ReferenceObserverV1 = @ptrCast(
            @alignCast(context_ptr),
        );
        const host_clock = contract.digestV1("reference host clock");
        const host_source = contract.digestV1(
            "reference host observer source",
        );
        const host_provenance_label: []const u8 = switch (phase) {
            .probe => "reference host probe provenance",
            .pre_run => "reference host pre-run provenance",
            .post_run => "reference host post-run provenance",
            else => return CallbackError.InvalidSample,
        };
        const host_provenance = contract.digestV1(
            host_provenance_label,
        );
        const host_subject = contract.digestV1(
            "reference host subject",
        );
        const time: i64 = switch (phase) {
            .probe => 900,
            .pre_run => 1_000,
            .post_run => 2_600,
            else => return CallbackError.InvalidSample,
        };
        const observed_at = std.math.cast(u64, time) orelse
            return CallbackError.InvalidSample;
        var count: usize = 0;
        output[count] = contract.makeObservationV1(
            descriptor.*,
            plan.*,
            phase,
            count + 1,
            .host_monotonic_time,
            .present,
            time,
            observed_at,
            host_clock,
            host_clock,
            host_source,
            host_provenance,
            host_subject,
            zero_digest,
        ) catch return CallbackError.InvalidSample;
        count += 1;
        output[count] = contract.makeObservationV1(
            descriptor.*,
            plan.*,
            phase,
            count + 1,
            .host_logical_cpu_count,
            .present,
            8,
            observed_at,
            host_clock,
            zero_digest,
            host_source,
            host_provenance,
            host_subject,
            zero_digest,
        ) catch return CallbackError.InvalidSample;
        count += 1;
        if (phase == .probe) return count;

        output[count] = contract.makeObservationV1(
            descriptor.*,
            plan.*,
            phase,
            count + 1,
            .host_external_cpu_ppm,
            .present,
            if (phase == .pre_run)
                100_000
            else
                self.external_cpu_post_ppm,
            observed_at,
            host_clock,
            zero_digest,
            host_source,
            host_provenance,
            host_subject,
            zero_digest,
        ) catch return CallbackError.InvalidSample;
        count += 1;
        output[count] = contract.makeObservationV1(
            descriptor.*,
            plan.*,
            phase,
            count + 1,
            .process_resident_bytes,
            .present,
            if (phase == .pre_run) 4_194_304 else 4_456_448,
            observed_at,
            host_clock,
            zero_digest,
            host_source,
            host_provenance,
            host_subject,
            zero_digest,
        ) catch return CallbackError.InvalidSample;
        count += 1;
        output[count] = contract.makeObservationV1(
            descriptor.*,
            plan.*,
            phase,
            count + 1,
            .host_available_memory_bytes,
            .present,
            if (phase == .pre_run)
                17_179_869_184
            else
                17_175_674_880,
            observed_at,
            host_clock,
            zero_digest,
            host_source,
            host_provenance,
            host_subject,
            zero_digest,
        ) catch return CallbackError.InvalidSample;
        count += 1;
        output[count] = contract.makeObservationV1(
            descriptor.*,
            plan.*,
            phase,
            count + 1,
            .host_cpu_temperature,
            .denied,
            0,
            observed_at,
            host_clock,
            zero_digest,
            host_source,
            host_provenance,
            host_subject,
            contract.digestV1(
                "reference host temperature permission denied",
            ),
        ) catch return CallbackError.InvalidSample;
        count += 1;
        output[count] = contract.makeObservationV1(
            descriptor.*,
            plan.*,
            phase,
            count + 1,
            .host_cpu_power,
            .unsupported,
            0,
            observed_at,
            host_clock,
            zero_digest,
            host_source,
            host_provenance,
            host_subject,
            contract.digestV1(
                "reference host power unsupported",
            ),
        ) catch return CallbackError.InvalidSample;
        count += 1;

        if (plan.execution_plane == .accelerator or
            plan.execution_plane == .mixed)
        {
            const device_subject = contract.digestV1(
                "reference accelerator subject",
            );
            const accelerator_source = contract.digestV1(
                "reference accelerator observer source",
            );
            const accelerator_provenance_label: []const u8 =
                if (phase == .pre_run)
                    "reference accelerator pre-run provenance"
                else
                    "reference accelerator post-run provenance";
            const accelerator_provenance = contract.digestV1(
                accelerator_provenance_label,
            );
            output[count] = contract.makeObservationV1(
                descriptor.*,
                plan.*,
                phase,
                count + 1,
                .accelerator_device_present,
                .present,
                1,
                observed_at,
                host_clock,
                zero_digest,
                accelerator_source,
                accelerator_provenance,
                device_subject,
                zero_digest,
            ) catch return CallbackError.InvalidSample;
            count += 1;
            output[count] = contract.makeObservationV1(
                descriptor.*,
                plan.*,
                phase,
                count + 1,
                .accelerator_cpu_fallback,
                .present,
                if (phase == .post_run)
                    self.fallback_post
                else
                    0,
                observed_at,
                host_clock,
                zero_digest,
                accelerator_source,
                accelerator_provenance,
                device_subject,
                zero_digest,
            ) catch return CallbackError.InvalidSample;
            count += 1;
            output[count] = contract.makeObservationV1(
                descriptor.*,
                plan.*,
                phase,
                count + 1,
                .accelerator_device_time,
                .present,
                if (phase == .pre_run) 50_000 else 51_600,
                observed_at,
                host_clock,
                contract.digestV1(
                    "reference accelerator clock",
                ),
                accelerator_source,
                accelerator_provenance,
                device_subject,
                zero_digest,
            ) catch return CallbackError.InvalidSample;
            count += 1;
        }
        return count;
    }

    fn transition(
        context_ptr: *anyopaque,
        phase: contract.PhaseV1,
    ) CallbackError!void {
        const self: *ReferenceObserverV1 = @ptrCast(
            @alignCast(context_ptr),
        );
        if ((phase != .begin and phase != .end) or
            self.transition_count >= self.transitions.len)
            return CallbackError.InvalidSample;
        self.transitions[self.transition_count] = phase;
        self.transition_count += 1;
    }
};

const ReferenceWorkloadV1 = struct {
    storage: perception.ReferenceStorageV1,
    invocations: u64 = 0,
    fallback: FallbackStateV1 = .not_applicable,

    fn init() !ReferenceWorkloadV1 {
        return .{
            .storage = try perception.ReferenceStorageV1.init(),
        };
    }

    fn interface(self: *ReferenceWorkloadV1) WorkloadV1 {
        return .{
            .context = self,
            .run_fn = run,
        };
    }

    fn run(
        context_ptr: *anyopaque,
        plan: *const contract.PlanV1,
    ) CallbackError!WorkloadReceiptV1 {
        const self: *ReferenceWorkloadV1 = @ptrCast(
            @alignCast(context_ptr),
        );
        self.invocations += 1;
        const campaign = perception.runReferenceCampaignV1(
            &self.storage,
        ) catch return CallbackError.WorkloadUnavailable;
        var replay_storage: workload_driver.MaximumStorageV1 = .{};
        perception.validateEvidenceByReplayV1(
            campaign.plan,
            campaign.driver_result,
            campaign.evidence,
            replay_storage.interface(),
        ) catch return CallbackError.WorkloadUnavailable;
        return makeWorkloadReceiptV1(
            plan.*,
            .succeeded,
            if (campaign.evidence.summary.publications == 3)
                .passed
            else
                .failed,
            if (campaign.evidence.summary.zero_orphan_ownership)
                .passed
            else
                .failed,
            self.fallback,
            campaign.plan.profiles.len,
            campaign.plan.items.len,
            campaign.evidence.evidence_sha256,
            campaign.evidence.evidence_summary_sha256,
            campaign.driver_result.summary_sha256,
        ) catch return CallbackError.WorkloadUnavailable;
    }
};

pub const ReferenceReportV1 = struct {
    abi_version: u64 = reference_report_abi,
    descriptor_sha256: Digest = zero_digest,
    plan_sha256: Digest = zero_digest,
    probe_bundle_sha256: Digest = zero_digest,
    pre_run_bundle_sha256: Digest = zero_digest,
    post_run_bundle_sha256: Digest = zero_digest,
    workload_receipt_sha256: Digest = zero_digest,
    run_report_sha256: Digest = zero_digest,
    workload_result_sha256: Digest = zero_digest,
    decision: DecisionV1 = .unused,
    profile_count: u64 = 0,
    item_count: u64 = 0,
    elapsed_nanoseconds: u64 = 0,
    report_sha256: Digest = zero_digest,
};

pub fn referenceReportV1() Error!ReferenceReportV1 {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{};
    var workload = try ReferenceWorkloadV1.init();
    const artifact = try runObservedV1(
        plan,
        observer.interface(descriptor),
        workload.interface(),
    );
    var result: ReferenceReportV1 = .{
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .plan_sha256 = plan.plan_sha256,
        .probe_bundle_sha256 = artifact.probe.bundle_sha256,
        .pre_run_bundle_sha256 = artifact.pre_run.bundle_sha256,
        .post_run_bundle_sha256 = artifact.post_run.bundle_sha256,
        .workload_receipt_sha256 = artifact.receipt.receipt_sha256,
        .run_report_sha256 = artifact.report.report_sha256,
        .workload_result_sha256 = artifact.receipt.result_sha256,
        .decision = artifact.report.decision,
        .profile_count = artifact.receipt.profile_count,
        .item_count = artifact.receipt.item_count,
        .elapsed_nanoseconds = artifact.report.elapsed_nanoseconds,
    };
    result.report_sha256 = referenceReportSha256V1(result);
    try validateReferenceReportV1(result);
    return result;
}

pub fn referenceReportSha256V1(
    value: ReferenceReportV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(reference_report_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.descriptor_sha256);
    hash.update(&value.plan_sha256);
    hash.update(&value.probe_bundle_sha256);
    hash.update(&value.pre_run_bundle_sha256);
    hash.update(&value.post_run_bundle_sha256);
    hash.update(&value.workload_receipt_sha256);
    hash.update(&value.run_report_sha256);
    hash.update(&value.workload_result_sha256);
    hashU64(&hash, @intFromEnum(value.decision));
    hashU64(&hash, value.profile_count);
    hashU64(&hash, value.item_count);
    hashU64(&hash, value.elapsed_nanoseconds);
    return finish(&hash);
}

pub fn validateReferenceReportV1(
    value: ReferenceReportV1,
) Error!void {
    if (value.abi_version != reference_report_abi or
        value.decision != .publishable or
        value.profile_count != perception.reference_profile_count or
        value.item_count != perception.reference_item_count or
        value.elapsed_nanoseconds == 0 or
        contract.digestIsZero(value.descriptor_sha256) or
        contract.digestIsZero(value.plan_sha256) or
        contract.digestIsZero(value.probe_bundle_sha256) or
        contract.digestIsZero(value.pre_run_bundle_sha256) or
        contract.digestIsZero(value.post_run_bundle_sha256) or
        contract.digestIsZero(value.workload_receipt_sha256) or
        contract.digestIsZero(value.run_report_sha256) or
        contract.digestIsZero(value.workload_result_sha256) or
        !contract.digestEqual(
            value.report_sha256,
            referenceReportSha256V1(value),
        ))
        return Error.InvalidReport;
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn acceleratedPlanV1(
    descriptor: contract.DescriptorV1,
) !contract.PlanV1 {
    const rules = [_]contract.RuleV1{
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
            .host_external_cpu_ppm,
            .pre_run,
            .inclusive_range,
            0,
            250_000,
        ),
        try contract.makeRuleV1(
            .host_external_cpu_ppm,
            .post_run,
            .inclusive_range,
            0,
            250_000,
        ),
        try contract.makeRuleV1(
            .accelerator_device_present,
            .pre_run,
            .inclusive_range,
            1,
            1,
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
    };
    return contract.makePlanV1(
        descriptor,
        contract.digestV1("typed perception 3 profiles 6 items"),
        contract.digestV1("download-free retained fixture"),
        contract.digestV1("reference build"),
        contract.digestV1("reference machine"),
        contract.digestV1("reference accelerator backend"),
        contract.digestV1("reference accelerator device"),
        contract.digestV1("reference accelerator placement"),
        .accelerator,
        4,
        3,
        &rules,
        contract.digestV1("accelerator observation challenge"),
    );
}

fn sourceIdentityPlanV1(
    descriptor: contract.DescriptorV1,
) !contract.PlanV1 {
    const rules = [_]contract.RuleV1{
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
            .host_external_cpu_ppm,
            .pre_run,
            .inclusive_range,
            0,
            250_000,
        ),
        try contract.makeRuleV1(
            .host_external_cpu_ppm,
            .post_run,
            .inclusive_range,
            0,
            250_000,
        ),
    };
    return contract.makePlanV1(
        descriptor,
        contract.digestV1("typed perception 3 profiles 6 items"),
        contract.digestV1("download-free retained fixture"),
        contract.digestV1("reference build"),
        contract.digestV1("reference machine"),
        contract.digestV1("reference accelerator backend"),
        contract.digestV1("reference accelerator device"),
        contract.digestV1("reference accelerator placement"),
        .host,
        4,
        3,
        &rules,
        contract.digestV1("source identity observation challenge"),
    );
}

test "reference runner binds three-family workload to native observation" {
    const report = try referenceReportV1();
    try std.testing.expectEqual(DecisionV1.publishable, report.decision);
    try std.testing.expectEqual(@as(u64, 3), report.profile_count);
    try std.testing.expectEqual(@as(u64, 6), report.item_count);
    try std.testing.expectEqual(@as(u64, 1_600), report.elapsed_nanoseconds);
}

test "same source uses stable identity rather than event provenance" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try sourceIdentityPlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{};
    var workload = try ReferenceWorkloadV1.init();
    const accepted = try runObservedV1(
        plan,
        observer.interface(descriptor),
        workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.publishable,
        accepted.report.decision,
    );
    const pre = contract.findObservationV1(
        accepted.pre_run,
        .host_logical_cpu_count,
    ).?;
    const post = contract.findObservationV1(
        accepted.post_run,
        .host_logical_cpu_count,
    ).?;
    try std.testing.expect(contract.digestEqual(
        pre.source_sha256,
        post.source_sha256,
    ));
    try std.testing.expect(!contract.digestEqual(
        pre.provenance_sha256,
        post.provenance_sha256,
    ));

    const ChangedSourceObserver = struct {
        fn collect(
            context_ptr: *anyopaque,
            desc: *const contract.DescriptorV1,
            active_plan: *const contract.PlanV1,
            phase: contract.PhaseV1,
            output: *[contract.maximum_observations]contract.ObservationV1,
        ) CallbackError!usize {
            const count = try ReferenceObserverV1.collect(
                context_ptr,
                desc,
                active_plan,
                phase,
                output,
            );
            if (phase == .post_run) {
                for (output[0..count]) |*record| {
                    if (record.metric == .host_logical_cpu_count) {
                        record.source_sha256 = contract.digestV1(
                            "substituted observer source",
                        );
                        record.observation_sha256 =
                            contract.observationSha256V1(record.*);
                    }
                }
            }
            return count;
        }
    };
    var changed_observer: ReferenceObserverV1 = .{};
    var changed_workload = try ReferenceWorkloadV1.init();
    const rejected = try runObservedV1(
        plan,
        .{
            .context = &changed_observer,
            .descriptor = descriptor,
            .collect_fn = ChangedSourceObserver.collect,
            .transition_fn = ReferenceObserverV1.transition,
        },
        changed_workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.rejected_post_run,
        rejected.report.decision,
    );
    try std.testing.expect(
        rejected.report.source_mismatch_bits &
            (try contract.metricBitV1(
                .host_logical_cpu_count,
            )) != 0,
    );
}

test "pre-run contamination fails closed before workload invocation" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{
        .external_cpu_post_ppm = 120_000,
    };
    var workload = try ReferenceWorkloadV1.init();

    const RejectingObserver = struct {
        fn collect(
            context_ptr: *anyopaque,
            desc: *const contract.DescriptorV1,
            active_plan: *const contract.PlanV1,
            phase: contract.PhaseV1,
            output: *[contract.maximum_observations]contract.ObservationV1,
        ) CallbackError!usize {
            const base: *ReferenceObserverV1 = @ptrCast(
                @alignCast(context_ptr),
            );
            const count = try ReferenceObserverV1.collect(
                context_ptr,
                desc,
                active_plan,
                phase,
                output,
            );
            if (phase == .pre_run) {
                for (output[0..count]) |*record| {
                    if (record.metric == .host_external_cpu_ppm) {
                        record.value = 900_000;
                        record.observation_sha256 =
                            contract.observationSha256V1(record.*);
                    }
                }
            }
            _ = base;
            return count;
        }
    };
    const interface = ObserverV1{
        .context = &observer,
        .descriptor = descriptor,
        .collect_fn = RejectingObserver.collect,
        .transition_fn = ReferenceObserverV1.transition,
    };
    const artifact = try runObservedV1(
        plan,
        interface,
        workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.rejected_pre_run,
        artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 0), workload.invocations);
    try std.testing.expectEqual(@as(u64, 0), artifact.report.begin_invocations);
    try std.testing.expect(
        artifact.report.threshold_metric_bits &
            (try contract.metricBitV1(.host_external_cpu_ppm)) != 0,
    );
}

test "denied required metric and begin failure never invoke workload" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);

    const DeniedObserver = struct {
        fn collect(
            context_ptr: *anyopaque,
            desc: *const contract.DescriptorV1,
            active_plan: *const contract.PlanV1,
            phase: contract.PhaseV1,
            output: *[contract.maximum_observations]contract.ObservationV1,
        ) CallbackError!usize {
            const count = try ReferenceObserverV1.collect(
                context_ptr,
                desc,
                active_plan,
                phase,
                output,
            );
            if (phase == .pre_run) {
                for (output[0..count]) |*record| {
                    if (record.metric == .host_logical_cpu_count) {
                        record.availability = .denied;
                        record.value = 0;
                        record.reason_sha256 = contract.digestV1(
                            "logical CPU observation denied",
                        );
                        record.observation_sha256 =
                            contract.observationSha256V1(record.*);
                    }
                }
            }
            return count;
        }
    };
    var denied_observer: ReferenceObserverV1 = .{};
    var denied_workload = try ReferenceWorkloadV1.init();
    const denied_artifact = try runObservedV1(
        plan,
        .{
            .context = &denied_observer,
            .descriptor = descriptor,
            .collect_fn = DeniedObserver.collect,
            .transition_fn = ReferenceObserverV1.transition,
        },
        denied_workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.rejected_pre_run,
        denied_artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 0), denied_workload.invocations);
    try std.testing.expect(
        denied_artifact.report.denied_metric_bits &
            (try contract.metricBitV1(
                .host_logical_cpu_count,
            )) != 0,
    );

    const BeginFailureObserver = struct {
        fn transition(
            _: *anyopaque,
            phase: contract.PhaseV1,
        ) CallbackError!void {
            if (phase == .begin)
                return CallbackError.InjectedFailure;
        }
    };
    var begin_observer: ReferenceObserverV1 = .{};
    var begin_workload = try ReferenceWorkloadV1.init();
    const begin_artifact = try runObservedV1(
        plan,
        .{
            .context = &begin_observer,
            .descriptor = descriptor,
            .collect_fn = ReferenceObserverV1.collect,
            .transition_fn = BeginFailureObserver.transition,
        },
        begin_workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.rejected_pre_run,
        begin_artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 0), begin_workload.invocations);
    try std.testing.expectEqual(
        @as(u64, 1),
        begin_artifact.report.begin_invocations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        begin_artifact.report.end_invocations,
    );
}

test "probe callback failure returns a retained pre-run rejection" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{};
    var workload = try ReferenceWorkloadV1.init();
    const ProbeFailureObserver = struct {
        fn collect(
            _: *anyopaque,
            _: *const contract.DescriptorV1,
            _: *const contract.PlanV1,
            _: contract.PhaseV1,
            _: *[contract.maximum_observations]contract.ObservationV1,
        ) CallbackError!usize {
            return CallbackError.ObserverUnavailable;
        }
    };
    const artifact = try runObservedV1(
        plan,
        .{
            .context = &observer,
            .descriptor = descriptor,
            .collect_fn = ProbeFailureObserver.collect,
            .transition_fn = ReferenceObserverV1.transition,
        },
        workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.rejected_pre_run,
        artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 0), workload.invocations);
    try std.testing.expect(
        artifact.report.callback_failure_bits &
            reason_callback_probe != 0,
    );
    try std.testing.expect(
        contract.digestIsZero(artifact.probe.bundle_sha256),
    );
}

test "post-run contamination is retained but nonpublishable" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{
        .external_cpu_post_ppm = 900_000,
    };
    var workload = try ReferenceWorkloadV1.init();
    const artifact = try runObservedV1(
        plan,
        observer.interface(descriptor),
        workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.rejected_post_run,
        artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 1), workload.invocations);
    try std.testing.expect(!contract.digestIsZero(
        artifact.receipt.receipt_sha256,
    ));
    try std.testing.expect(!contract.digestIsZero(
        artifact.post_run.bundle_sha256,
    ));
}

test "accelerator fallback and device clock stay explicit" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try acceleratedPlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{
        .fallback_post = 1,
    };
    var workload = try ReferenceWorkloadV1.init();
    workload.fallback = .present;
    const artifact = try runObservedV1(
        plan,
        observer.interface(descriptor),
        workload.interface(),
    );
    try std.testing.expectEqual(
        DecisionV1.rejected_post_run,
        artifact.report.decision,
    );
    try std.testing.expect(
        artifact.report.reason_bits & reason_accelerator_fallback != 0,
    );
    const host_time = contract.findObservationV1(
        artifact.post_run,
        .host_monotonic_time,
    ).?;
    const device_time = contract.findObservationV1(
        artifact.post_run,
        .accelerator_device_time,
    ).?;
    try std.testing.expect(!contract.digestEqual(
        host_time.value_clock_domain_sha256,
        device_time.value_clock_domain_sha256,
    ));
}

test "workload callback failure still closes observer and samples post-run" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{};
    var invocation_count: u64 = 0;
    const FailingWorkload = struct {
        fn run(
            context_ptr: *anyopaque,
            _: *const contract.PlanV1,
        ) CallbackError!WorkloadReceiptV1 {
            const count: *u64 = @ptrCast(@alignCast(context_ptr));
            count.* += 1;
            return CallbackError.InjectedFailure;
        }
    };
    const artifact = try runObservedV1(
        plan,
        observer.interface(descriptor),
        .{
            .context = &invocation_count,
            .run_fn = FailingWorkload.run,
        },
    );
    try std.testing.expectEqual(
        DecisionV1.workload_failed,
        artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 1), invocation_count);
    try std.testing.expectEqual(@as(u64, 1), artifact.report.end_invocations);
    try std.testing.expect(!contract.digestIsZero(
        artifact.post_run.bundle_sha256,
    ));
}

test "successful callback with zero receipt is retained as invalid" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{};
    var invocation_count: u64 = 0;
    const ZeroReceiptWorkload = struct {
        fn run(
            context_ptr: *anyopaque,
            _: *const contract.PlanV1,
        ) CallbackError!WorkloadReceiptV1 {
            const count: *u64 = @ptrCast(@alignCast(context_ptr));
            count.* += 1;
            return .{};
        }
    };
    const artifact = try runObservedV1(
        plan,
        observer.interface(descriptor),
        .{
            .context = &invocation_count,
            .run_fn = ZeroReceiptWorkload.run,
        },
    );
    try std.testing.expectEqual(
        DecisionV1.workload_failed,
        artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 1), invocation_count);
    try std.testing.expect(
        artifact.report.reason_bits & reason_invalid_receipt != 0,
    );
    try std.testing.expect(
        contract.digestIsZero(artifact.receipt.receipt_sha256),
    );
    try std.testing.expect(!contract.digestIsZero(
        artifact.post_run.bundle_sha256,
    ));
}

test "workload failure keeps precedence when post-run collection also fails" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{};
    var invocation_count: u64 = 0;
    const CombinedFailure = struct {
        fn collect(
            context_ptr: *anyopaque,
            desc: *const contract.DescriptorV1,
            active_plan: *const contract.PlanV1,
            phase: contract.PhaseV1,
            output: *[contract.maximum_observations]contract.ObservationV1,
        ) CallbackError!usize {
            if (phase == .post_run)
                return CallbackError.ObserverUnavailable;
            return ReferenceObserverV1.collect(
                context_ptr,
                desc,
                active_plan,
                phase,
                output,
            );
        }

        fn run(
            context_ptr: *anyopaque,
            _: *const contract.PlanV1,
        ) CallbackError!WorkloadReceiptV1 {
            const count: *u64 = @ptrCast(@alignCast(context_ptr));
            count.* += 1;
            return CallbackError.InjectedFailure;
        }
    };
    const artifact = try runObservedV1(
        plan,
        .{
            .context = &observer,
            .descriptor = descriptor,
            .collect_fn = CombinedFailure.collect,
            .transition_fn = ReferenceObserverV1.transition,
        },
        .{
            .context = &invocation_count,
            .run_fn = CombinedFailure.run,
        },
    );
    try std.testing.expectEqual(
        DecisionV1.workload_failed,
        artifact.report.decision,
    );
    try std.testing.expectEqual(@as(u64, 1), invocation_count);
    try std.testing.expect(
        artifact.report.callback_failure_bits &
            reason_callback_workload != 0,
    );
    try std.testing.expect(
        artifact.report.callback_failure_bits &
            reason_callback_post_run != 0,
    );
    try std.testing.expect(
        contract.digestIsZero(artifact.post_run.bundle_sha256),
    );
}

test "artifact validation rejects a structurally valid substituted root" {
    const descriptor = try contract.referenceDescriptorV1();
    const plan = try contract.referencePlanV1(descriptor);
    var observer: ReferenceObserverV1 = .{};
    var workload = try ReferenceWorkloadV1.init();
    var artifact = try runObservedV1(
        plan,
        observer.interface(descriptor),
        workload.interface(),
    );
    try validateRunArtifactV1(descriptor, plan, artifact);

    artifact.report.pre_run_bundle_sha256 =
        contract.digestV1("substituted pre-run bundle");
    artifact.report.report_sha256 = runReportSha256V1(artifact.report);
    try validateRunReportV1(artifact.report);
    try std.testing.expectError(
        Error.InvalidReport,
        validateRunArtifactV1(descriptor, plan, artifact),
    );
}
