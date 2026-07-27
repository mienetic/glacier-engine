//! Portable, allocation-free native workload evidence report.
//!
//! V1 deliberately reports logical concurrency only.  Physical queue depth,
//! residency, power, energy, temperature, frequency and physical parallelism
//! are availability-bearing metrics and are never inferred from logical
//! records.  A sealed report retains warmup records, but every summary value is
//! recomputed exclusively from the measured cohort.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const scenario_abi: u64 = 0x4757_3653_0000_0001;
pub const record_abi: u64 = 0x4757_3652_0000_0001;
pub const summary_abi: u64 = 0x4757_3655_0000_0001;
pub const closure_abi: u64 = 0x4757_3643_0000_0001;
pub const report_abi: u64 = 0x4757_3650_0000_0001;
pub const wire_abi: u64 = 0x4757_3657_0000_0001;

pub const magic = [_]u8{ 'G', 'W', '6', 'R', 'P', 'T', '0', '1' };
pub const max_records: usize = 256;
pub const no_queue_slot: u32 = std.math.maxInt(u32);
pub const wire_flags: u32 = 1;
pub const allowed_wire_flags: u32 = wire_flags;

const scenario_domain = "glacier-native-workload-scenario-v1\x00";
const record_domain = "glacier-native-workload-record-v1\x00";
const summary_domain = "glacier-native-workload-summary-v1\x00";
const closure_domain = "glacier-native-workload-closure-v1\x00";
const report_domain = "glacier-native-workload-report-v1\x00";
const body_domain = "glacier-native-workload-body-wire-v1\x00";
const footer_domain = "glacier-native-workload-footer-wire-v1\x00";
const metric_reason_domain = "glacier-native-workload-metric-unsupported-v1\x00";

pub const event_count: usize = 7;
pub const metric_count: usize = 12;
pub const event_presence_all: u8 = (1 << event_count) - 1;
pub const event_arrival: u8 = 1 << 0;
pub const event_admission: u8 = 1 << 1;
pub const event_first_service: u8 = 1 << 2;
pub const event_submit_return: u8 = 1 << 3;
pub const event_first_output: u8 = 1 << 4;
pub const event_terminal: u8 = 1 << 5;
pub const event_settlement: u8 = 1 << 6;
pub const capacity_rejected_presence: u8 =
    event_arrival | event_terminal | event_settlement;

pub const header_bytes: usize = 40;
pub const scenario_wire_bytes: usize = 484;
pub const record_wire_bytes: usize = 772;
pub const distribution_wire_bytes: usize = 40;
pub const metric_wire_bytes: usize = 120;
pub const summary_wire_bytes: usize = 1856;
pub const closure_wire_bytes: usize = 80;
pub const report_root_wire_bytes: usize = 32;
pub const wire_digest_bytes: usize = 64;
pub const minimum_encoded_bytes: usize = header_bytes +
    scenario_wire_bytes + summary_wire_bytes + closure_wire_bytes +
    report_root_wire_bytes + wire_digest_bytes;
pub const max_encoded_bytes: usize =
    minimum_encoded_bytes + max_records * record_wire_bytes;

pub const Error = error{
    CapacityExceeded,
    ArithmeticOverflow,
    InvalidStorage,
    InvalidMagic,
    InvalidAbi,
    InvalidLength,
    InvalidFlags,
    InvalidReserved,
    InvalidEnum,
    InvalidBoolean,
    InvalidScenario,
    InvalidRecord,
    InvalidEvent,
    InvalidRoot,
    InvalidChain,
    InvalidSummary,
    InvalidMetric,
    InvalidClosure,
    InvalidReport,
    InvalidBodyDigest,
    InvalidFooterDigest,
};

pub const ModeV1 = enum(u8) {
    closed,
    open,
};

pub const EvidenceV1 = enum(u8) {
    synthetic,
    production_native,
};

pub const SummaryAlgorithmV1 = enum(u8) {
    nearest_rank_v1,
};

pub const CohortV1 = enum(u8) {
    warmup,
    measured,
};

pub const OutcomeV1 = enum(u8) {
    completed,
    capacity_rejected,
    failed,
    cancelled,
    timed_out,
};

pub const CorrectnessV1 = enum(u8) {
    not_applicable,
    correct,
    incorrect,
};

pub const AvailabilityV1 = enum(u8) {
    missing,
    denied,
    unsupported,
    present,
};

pub const MetricKindV1 = enum(u8) {
    cpu_time_ns,
    process_rss_bytes,
    device_duration_total_ns,
    current_allocated_size_max_bytes,
    utilization_ppm,
    physical_queue_depth,
    residency_bytes,
    power_microwatts,
    energy_microjoules,
    temperature_millidegrees_c,
    frequency_hz,
    physical_parallelism,
};

pub const ScenarioConfigV1 = struct {
    mode: ModeV1,
    evidence: EvidenceV1,
    warmup_count: u32,
    measured_count: u32,
    max_in_flight: u32,
    queue_count: u32,
    flow_count: u32,
    workload_sha256: Digest,
    profile_sha256: Digest,
    artifact_sha256: Digest,
    build_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    host_source_sha256: Digest,
    host_clock_sha256: Digest,
    device_source_sha256: Digest,
    device_clock_sha256: Digest,
    challenge_sha256: Digest,
};

pub const ScenarioV1 = struct {
    abi_version: u64 = scenario_abi,
    mode: ModeV1 = .closed,
    evidence: EvidenceV1 = .synthetic,
    summary_algorithm: SummaryAlgorithmV1 = .nearest_rank_v1,
    warmup_count: u32 = 0,
    measured_count: u32 = 0,
    max_in_flight: u32 = 0,
    queue_count: u32 = 0,
    flow_count: u32 = 0,
    workload_sha256: Digest = zero_digest,
    profile_sha256: Digest = zero_digest,
    artifact_sha256: Digest = zero_digest,
    build_sha256: Digest = zero_digest,
    machine_sha256: Digest = zero_digest,
    backend_sha256: Digest = zero_digest,
    device_sha256: Digest = zero_digest,
    placement_sha256: Digest = zero_digest,
    host_source_sha256: Digest = zero_digest,
    host_clock_sha256: Digest = zero_digest,
    device_source_sha256: Digest = zero_digest,
    device_clock_sha256: Digest = zero_digest,
    challenge_sha256: Digest = zero_digest,
    scenario_sha256: Digest = zero_digest,
};

pub const EventPointV1 = struct {
    ns: u64 = 0,
    sequence: u64 = 0,
};

pub const HostEventsV1 = struct {
    presence_mask: u8 = 0,
    arrival: EventPointV1 = .{},
    admission: EventPointV1 = .{},
    first_service: EventPointV1 = .{},
    submit_return: EventPointV1 = .{},
    first_output: EventPointV1 = .{},
    terminal: EventPointV1 = .{},
    settlement: EventPointV1 = .{},
};

pub const RootsV1 = struct {
    request_sha256: Digest = zero_digest,
    ticket_sha256: Digest = zero_digest,
    pin_sha256: Digest = zero_digest,
    dispatch_sha256: Digest = zero_digest,
    submission_sha256: Digest = zero_digest,
    output_sha256: Digest = zero_digest,
    oracle_sha256: Digest = zero_digest,
    terminal_sha256: Digest = zero_digest,
    completion_sha256: Digest = zero_digest,
};

pub const DeviceTimingV1 = struct {
    availability: AvailabilityV1 = .missing,
    raw_start_f64_bits: u64 = 0,
    raw_end_f64_bits: u64 = 0,
    duration_ns: u64 = 0,
    source_sha256: Digest = zero_digest,
    clock_sha256: Digest = zero_digest,
    reason_sha256: Digest = zero_digest,
};

pub const AllocatedContextV1 = struct {
    availability: AvailabilityV1 = .missing,
    before_bytes: u64 = 0,
    after_bytes: u64 = 0,
    source_sha256: Digest = zero_digest,
    reason_sha256: Digest = zero_digest,
};

pub const LogicalFactsV1 = struct {
    bank_acquisitions: u32 = 0,
    bank_completions: u32 = 0,
    bank_used_before: u64 = 0,
    bank_used_after_settlement: u64 = 0,
    pin_count_before: u32 = 0,
    pin_count_after_settlement: u32 = 0,
    dispatch_count_before: u32 = 0,
    dispatch_count_after_settlement: u32 = 0,
    native_command_count_before: u32 = 0,
    native_command_count_after_settlement: u32 = 0,
};

pub const RecordV1 = struct {
    abi_version: u64 = record_abi,
    ordinal: u32 = 0,
    cohort: CohortV1 = .warmup,
    outcome: OutcomeV1 = .completed,
    correctness: CorrectnessV1 = .not_applicable,
    fallback: bool = false,
    flow_id: u32 = 0,
    work_units: u64 = 0,
    adapter_queue_slot: u32 = no_queue_slot,
    host: HostEventsV1 = .{},
    roots: RootsV1 = .{},
    maximum_abs_error_f64_bits: u64 = 0,
    device_timing: DeviceTimingV1 = .{},
    allocated_context: AllocatedContextV1 = .{},
    logical: LogicalFactsV1 = .{},
    previous_record_sha256: Digest = zero_digest,
    record_sha256: Digest = zero_digest,
};

pub const DistributionV1 = struct {
    sample_count: u32 = 0,
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
    max_ns: u64 = 0,
};

pub const MetricV1 = struct {
    kind: MetricKindV1 = .cpu_time_ns,
    availability: AvailabilityV1 = .unsupported,
    numerator: u64 = 0,
    denominator: u64 = 0,
    source_sha256: Digest = zero_digest,
    clock_sha256: Digest = zero_digest,
    reason_sha256: Digest = zero_digest,
};

pub const SummaryV1 = struct {
    abi_version: u64 = summary_abi,
    measured_records: u32 = 0,
    admitted_count: u32 = 0,
    completed_count: u32 = 0,
    capacity_rejected_count: u32 = 0,
    failed_count: u32 = 0,
    cancelled_count: u32 = 0,
    timed_out_count: u32 = 0,
    attempted_work_units: u64 = 0,
    completed_work_units: u64 = 0,
    interval_start_ns: u64 = 0,
    interval_end_ns: u64 = 0,
    interval_numerator_ns: u64 = 0,
    interval_denominator: u64 = 1,
    throughput_completed_work_numerator: u64 = 0,
    throughput_interval_denominator_ns: u64 = 0,
    admission: DistributionV1 = .{},
    queue: DistributionV1 = .{},
    first_output: DistributionV1 = .{},
    service: DistributionV1 = .{},
    end_to_end: DistributionV1 = .{},
    device_duration: DistributionV1 = .{},
    logical_in_flight_high_water: u32 = 0,
    flow_completion_min: u32 = 0,
    flow_completion_max: u32 = 0,
    flow_completion_spread: u32 = 0,
    fallback_count: u32 = 0,
    correctness_correct_count: u32 = 0,
    correctness_incorrect_count: u32 = 0,
    allocated_context_max_available: bool = false,
    allocated_context_max_bytes: u64 = 0,
    metrics: [metric_count]MetricV1 = undefined,
    summary_sha256: Digest = zero_digest,
};

pub const ClosureV1 = struct {
    abi_version: u64 = closure_abi,
    bank_count: u32 = 0,
    pin_count: u32 = 0,
    dispatch_count: u32 = 0,
    native_command_count: u32 = 0,
    native_buffer_count: u32 = 0,
    acquisitions: u64 = 0,
    completions: u64 = 0,
    zero_orphan: bool = false,
    closure_sha256: Digest = zero_digest,
};

pub const ReportV1 = struct {
    abi_version: u64 = report_abi,
    scenario: ScenarioV1,
    records: []RecordV1,
    summary: SummaryV1,
    closure: ClosureV1,
    report_sha256: Digest,
};

pub fn digestV1(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn makeScenarioV1(config: ScenarioConfigV1) Error!ScenarioV1 {
    var value: ScenarioV1 = .{
        .mode = config.mode,
        .evidence = config.evidence,
        .warmup_count = config.warmup_count,
        .measured_count = config.measured_count,
        .max_in_flight = config.max_in_flight,
        .queue_count = config.queue_count,
        .flow_count = config.flow_count,
        .workload_sha256 = config.workload_sha256,
        .profile_sha256 = config.profile_sha256,
        .artifact_sha256 = config.artifact_sha256,
        .build_sha256 = config.build_sha256,
        .machine_sha256 = config.machine_sha256,
        .backend_sha256 = config.backend_sha256,
        .device_sha256 = config.device_sha256,
        .placement_sha256 = config.placement_sha256,
        .host_source_sha256 = config.host_source_sha256,
        .host_clock_sha256 = config.host_clock_sha256,
        .device_source_sha256 = config.device_source_sha256,
        .device_clock_sha256 = config.device_clock_sha256,
        .challenge_sha256 = config.challenge_sha256,
    };
    value.scenario_sha256 = scenarioSha256V1(value);
    if (!scenarioValidV1(value)) return Error.InvalidScenario;
    return value;
}

pub fn makeRecordV1(value: RecordV1) Error!RecordV1 {
    var result = value;
    result.previous_record_sha256 = zero_digest;
    result.record_sha256 = zero_digest;
    if (!recordFieldsValidV1(result, null)) return Error.InvalidRecord;
    return result;
}

pub fn makeClosureV1(acquisitions: u64, completions: u64) Error!ClosureV1 {
    var value: ClosureV1 = .{
        .acquisitions = acquisitions,
        .completions = completions,
        .zero_orphan = true,
    };
    value.closure_sha256 = closureSha256V1(value);
    if (!closureValidV1(value)) return Error.InvalidClosure;
    return value;
}

pub fn sealClosureV1(value: ClosureV1) Error!ClosureV1 {
    var result = value;
    result.closure_sha256 = closureSha256V1(result);
    if (!closureValidV1(result)) return Error.InvalidClosure;
    return result;
}

pub fn sealV1(
    scenario: ScenarioV1,
    records: []RecordV1,
    closure_input: ClosureV1,
) Error!ReportV1 {
    if (!scenarioValidV1(scenario)) return Error.InvalidScenario;
    if (records.len > max_records or records.len !=
        @as(usize, scenario.warmup_count) + scenario.measured_count)
        return Error.InvalidRecord;

    var previous = scenario.scenario_sha256;
    for (records, 0..) |*record, index| {
        record.previous_record_sha256 = previous;
        record.record_sha256 = recordSha256V1(scenario.scenario_sha256, record.*);
        if (!recordValidV1(scenario, record.*, index))
            return Error.InvalidRecord;
        previous = record.record_sha256;
    }
    if (!globalSequencesValid(records)) return Error.InvalidEvent;
    if (!campaignEventsValid(scenario, records))
        return Error.InvalidEvent;

    const summary = try recomputeSummaryV1(scenario, records);
    const closure = try sealClosureV1(closure_input);
    var report: ReportV1 = .{
        .scenario = scenario,
        .records = records,
        .summary = summary,
        .closure = closure,
        .report_sha256 = zero_digest,
    };
    report.report_sha256 = reportSha256V1(report);
    try validateV1(report);
    return report;
}

pub const sealReportV1 = sealV1;
pub const makeReportV1 = sealV1;
pub const makeV1 = sealV1;

pub fn validateV1(report: ReportV1) Error!void {
    if (report.abi_version != report_abi) return Error.InvalidAbi;
    if (!scenarioValidV1(report.scenario)) return Error.InvalidScenario;
    if (report.records.len > max_records or report.records.len !=
        @as(usize, report.scenario.warmup_count) +
            report.scenario.measured_count)
        return Error.InvalidRecord;

    var previous = report.scenario.scenario_sha256;
    for (report.records, 0..) |record, index| {
        if (!digestEqual(record.previous_record_sha256, previous) or
            !recordValidV1(report.scenario, record, index))
            return Error.InvalidChain;
        previous = record.record_sha256;
    }
    if (!globalSequencesValid(report.records)) return Error.InvalidEvent;
    if (!campaignEventsValid(report.scenario, report.records))
        return Error.InvalidEvent;
    const expected_summary =
        try recomputeSummaryV1(report.scenario, report.records);
    if (!std.meta.eql(report.summary, expected_summary))
        return Error.InvalidSummary;
    if (!closureValidV1(report.closure) or
        !reportClosureMatchesRecords(report))
        return Error.InvalidClosure;
    if (!digestEqual(report.report_sha256, reportSha256V1(report)))
        return Error.InvalidReport;
}

pub const validateReportV1 = validateV1;

pub fn reportValidV1(report: ReportV1) bool {
    validateV1(report) catch return false;
    return true;
}

pub fn scenarioValidV1(value: ScenarioV1) bool {
    if (value.abi_version != scenario_abi or
        value.summary_algorithm != .nearest_rank_v1 or
        value.measured_count == 0 or value.max_in_flight == 0 or
        value.queue_count == 0 or value.flow_count == 0 or
        value.flow_count > max_records or
        @as(u64, value.warmup_count) + value.measured_count > max_records)
        return false;
    inline for (scenarioDigests(value)) |digest| {
        if (digestIsZero(digest)) return false;
    }
    return digestEqual(value.scenario_sha256, scenarioSha256V1(value));
}

pub fn closureValidV1(value: ClosureV1) bool {
    return value.abi_version == closure_abi and value.bank_count == 0 and
        value.pin_count == 0 and value.dispatch_count == 0 and
        value.native_command_count == 0 and value.native_buffer_count == 0 and
        value.acquisitions == value.completions and value.zero_orphan and
        digestEqual(value.closure_sha256, closureSha256V1(value));
}

pub fn encodedLengthV1(record_count_value: usize) Error!usize {
    if (record_count_value > max_records) return Error.CapacityExceeded;
    const records_bytes = std.math.mul(
        usize,
        record_count_value,
        record_wire_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        minimum_encoded_bytes,
        records_bytes,
    ) catch return Error.ArithmeticOverflow;
}

fn recordFieldsValidV1(record: RecordV1, scenario: ?ScenarioV1) bool {
    if (record.abi_version != record_abi or record.work_units == 0)
        return false;
    if (scenario) |bound| {
        if (record.flow_id >= bound.flow_count) return false;
    }
    if (!hostEventsValid(record.host)) return false;

    const has_admission =
        record.host.presence_mask & event_admission != 0;
    const has_service =
        record.host.presence_mask & event_first_service != 0;
    const has_submit =
        record.host.presence_mask & event_submit_return != 0;
    const has_output =
        record.host.presence_mask & event_first_output != 0;
    if ((has_service and !has_admission) or
        (has_submit and !has_service) or
        (has_output and !has_submit))
        return false;
    if (record.fallback and !has_admission) return false;
    if ((record.device_timing.availability == .present and !has_submit) or
        (record.allocated_context.availability == .present and
            !has_admission))
        return false;
    if ((record.logical.pin_count_before != 0 and !has_admission) or
        ((record.logical.dispatch_count_before != 0 or
            record.logical.native_command_count_before != 0) and
            !has_submit))
        return false;
    if (has_admission != (record.logical.bank_acquisitions != 0))
        return false;

    switch (record.outcome) {
        .completed => {
            if (record.host.presence_mask != event_presence_all or
                record.adapter_queue_slot == no_queue_slot or
                record.correctness == .not_applicable or
                !rootsCompleted(record.roots) or
                !finiteNonnegativeBits(record.maximum_abs_error_f64_bits))
                return false;
        },
        .capacity_rejected => {
            if (record.host.presence_mask != capacity_rejected_presence or
                record.adapter_queue_slot != no_queue_slot or
                record.fallback or
                record.correctness != .not_applicable or
                record.maximum_abs_error_f64_bits != 0 or
                !rootsRejected(record.roots) or
                !std.meta.eql(record.logical, LogicalFactsV1{}))
                return false;
        },
        .failed, .cancelled, .timed_out => {
            if (record.host.presence_mask &
                capacity_rejected_presence != capacity_rejected_presence or
                record.maximum_abs_error_f64_bits != 0 or
                !rootPresent(record.roots.request_sha256) or
                !rootPresent(record.roots.terminal_sha256) or
                !rootPresent(record.roots.completion_sha256))
                return false;
            if (has_admission != rootPresent(record.roots.pin_sha256) or
                has_submit != rootPresent(record.roots.ticket_sha256) or
                has_submit != rootPresent(record.roots.dispatch_sha256) or
                has_submit != rootPresent(record.roots.submission_sha256) or
                has_output != rootPresent(record.roots.output_sha256) or
                has_output != rootPresent(record.roots.oracle_sha256))
                return false;
            if (has_output !=
                (record.correctness != .not_applicable)) return false;
        },
    }

    if (has_admission) {
        if (record.adapter_queue_slot == no_queue_slot) return false;
        if (scenario) |bound| {
            if (record.adapter_queue_slot >= bound.queue_count) return false;
        }
    } else if (record.adapter_queue_slot != no_queue_slot) return false;

    if (!deviceTimingValid(record.device_timing, scenario) or
        !allocatedContextValid(record.allocated_context, scenario) or
        !logicalFactsValid(record.logical))
        return false;
    return true;
}

fn recordValidV1(
    scenario: ScenarioV1,
    record: RecordV1,
    index: usize,
) bool {
    if (!recordFieldsValidV1(record, scenario) or record.ordinal != index)
        return false;
    const expected_cohort: CohortV1 =
        if (index < scenario.warmup_count) .warmup else .measured;
    if (record.cohort != expected_cohort) return false;
    return digestEqual(
        record.record_sha256,
        recordSha256V1(scenario.scenario_sha256, record),
    );
}

fn hostEventsValid(host: HostEventsV1) bool {
    if (host.presence_mask & ~event_presence_all != 0) return false;
    const points = hostPoints(host);
    var previous_ns: u64 = 0;
    var previous_sequence: u64 = 0;
    var have_previous = false;
    for (points, 0..) |point, index| {
        const present = host.presence_mask & eventBit(index) != 0;
        if (!present) {
            if (point.ns != 0 or point.sequence != 0) return false;
            continue;
        }
        if (point.sequence == 0) return false;
        if (have_previous and
            (point.ns < previous_ns or point.sequence <= previous_sequence))
            return false;
        previous_ns = point.ns;
        previous_sequence = point.sequence;
        have_previous = true;
    }
    return true;
}

fn globalSequencesValid(records: []const RecordV1) bool {
    for (records, 0..) |left_record, left_record_index| {
        const left = hostPoints(left_record.host);
        for (left, 0..) |left_point, left_event_index| {
            if (left_record.host.presence_mask &
                eventBit(left_event_index) == 0) continue;
            for (records[left_record_index..], left_record_index..) |
                right_record,
                right_record_index,
            | {
                const right = hostPoints(right_record.host);
                for (right, 0..) |right_point, right_event_index| {
                    if (right_record.host.presence_mask &
                        eventBit(right_event_index) == 0) continue;
                    if (left_record_index == right_record_index and
                        left_event_index >= right_event_index) continue;
                    if (left_point.sequence == right_point.sequence or
                        (left_point.sequence < right_point.sequence and
                            left_point.ns > right_point.ns) or
                        (left_point.sequence > right_point.sequence and
                            left_point.ns < right_point.ns))
                        return false;
                }
            }
        }
    }
    return true;
}

fn campaignEventsValid(
    scenario: ScenarioV1,
    records: []const RecordV1,
) bool {
    for (records[1..], records[0 .. records.len - 1]) |
        current,
        previous,
    | {
        if (previous.host.arrival.sequence >=
            current.host.arrival.sequence)
            return false;
    }

    if (scenario.warmup_count != 0) {
        var final_warmup_settlement: u64 = 0;
        for (records[0..scenario.warmup_count]) |record| {
            final_warmup_settlement = @max(
                final_warmup_settlement,
                record.host.settlement.sequence,
            );
        }
        var first_measured_arrival: u64 = std.math.maxInt(u64);
        for (records[scenario.warmup_count..]) |record| {
            first_measured_arrival = @min(
                first_measured_arrival,
                record.host.arrival.sequence,
            );
        }
        if (final_warmup_settlement >= first_measured_arrival)
            return false;
    }

    if (logicalHighWater(records, null) > scenario.max_in_flight)
        return false;

    for (records, 0..) |left, left_index| {
        if (left.host.presence_mask & event_admission == 0) continue;
        for (records[left_index + 1 ..]) |right| {
            if (right.host.presence_mask & event_admission == 0 or
                left.adapter_queue_slot != right.adapter_queue_slot)
                continue;
            const overlaps =
                left.host.admission.sequence <
                right.host.settlement.sequence and
                right.host.admission.sequence <
                    left.host.settlement.sequence;
            if (overlaps) return false;
        }
    }
    return true;
}

fn deviceTimingValid(
    value: DeviceTimingV1,
    scenario: ?ScenarioV1,
) bool {
    switch (value.availability) {
        .present => {
            if (!finiteNonnegativeBits(value.raw_start_f64_bits) or
                !finiteNonnegativeBits(value.raw_end_f64_bits) or
                deviceDurationNsV1(
                    value.raw_start_f64_bits,
                    value.raw_end_f64_bits,
                ) != value.duration_ns or
                digestIsZero(value.source_sha256) or
                digestIsZero(value.clock_sha256) or
                !digestIsZero(value.reason_sha256))
                return false;
            if (scenario) |bound| {
                if (!digestEqual(
                    value.source_sha256,
                    bound.device_source_sha256,
                ) or !digestEqual(
                    value.clock_sha256,
                    bound.device_clock_sha256,
                )) return false;
            }
        },
        .missing, .denied, .unsupported => {
            if (value.raw_start_f64_bits != 0 or
                value.raw_end_f64_bits != 0 or value.duration_ns != 0 or
                digestIsZero(value.source_sha256) or
                digestIsZero(value.clock_sha256) or
                digestIsZero(value.reason_sha256))
                return false;
            if (scenario) |bound| {
                if (!digestEqual(
                    value.source_sha256,
                    bound.device_source_sha256,
                ) or !digestEqual(
                    value.clock_sha256,
                    bound.device_clock_sha256,
                )) return false;
            }
        },
    }
    return true;
}

fn allocatedContextValid(
    value: AllocatedContextV1,
    scenario: ?ScenarioV1,
) bool {
    switch (value.availability) {
        .present => {
            if (digestIsZero(value.source_sha256) or
                !digestIsZero(value.reason_sha256))
                return false;
            if (scenario) |bound| {
                if (!digestEqual(
                    value.source_sha256,
                    bound.device_source_sha256,
                )) return false;
            }
        },
        .missing, .denied, .unsupported => {
            if (value.before_bytes != 0 or value.after_bytes != 0 or
                digestIsZero(value.source_sha256) or
                digestIsZero(value.reason_sha256))
                return false;
            if (scenario) |bound| {
                if (!digestEqual(
                    value.source_sha256,
                    bound.device_source_sha256,
                )) return false;
            }
        },
    }
    return true;
}

fn logicalFactsValid(value: LogicalFactsV1) bool {
    return value.bank_acquisitions == value.bank_completions and
        value.bank_used_after_settlement == value.bank_used_before and
        value.pin_count_after_settlement == 0 and
        value.dispatch_count_after_settlement == 0 and
        value.native_command_count_after_settlement == 0;
}

fn rootsCompleted(value: RootsV1) bool {
    inline for (rootDigests(value)) |digest| {
        if (digestIsZero(digest)) return false;
    }
    return true;
}

fn rootsRejected(value: RootsV1) bool {
    return rootPresent(value.request_sha256) and
        !rootPresent(value.ticket_sha256) and
        !rootPresent(value.pin_sha256) and
        !rootPresent(value.dispatch_sha256) and
        !rootPresent(value.submission_sha256) and
        !rootPresent(value.output_sha256) and
        !rootPresent(value.oracle_sha256) and
        rootPresent(value.terminal_sha256) and
        rootPresent(value.completion_sha256);
}

fn rootPresent(value: Digest) bool {
    return !digestIsZero(value);
}

fn finiteNonnegativeBits(bits: u64) bool {
    const value: f64 = @bitCast(bits);
    return std.math.isFinite(value) and value >= 0;
}

pub fn deviceDurationNsV1(start_bits: u64, end_bits: u64) ?u64 {
    if (!finiteNonnegativeBits(start_bits) or
        !finiteNonnegativeBits(end_bits))
        return null;
    const start: f64 = @bitCast(start_bits);
    const end: f64 = @bitCast(end_bits);
    if (end <= start) return null;
    const duration = (end - start) * 1_000_000_000.0;
    if (!std.math.isFinite(duration) or duration < 1.0 or
        duration >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
        return null;
    const result: u64 = @intFromFloat(duration);
    if (result == 0) return null;
    return result;
}

const LatencyKind = enum {
    admission,
    queue,
    first_output,
    service,
    end_to_end,
    device_duration,
};

pub fn recomputeSummaryV1(
    scenario: ScenarioV1,
    records: []const RecordV1,
) Error!SummaryV1 {
    if (!scenarioValidV1(scenario) or records.len !=
        @as(usize, scenario.warmup_count) + scenario.measured_count)
        return Error.InvalidScenario;
    for (records, 0..) |record, index| {
        if (!recordValidV1(scenario, record, index))
            return Error.InvalidRecord;
    }
    if (!globalSequencesValid(records) or
        !campaignEventsValid(scenario, records))
        return Error.InvalidEvent;

    var summary: SummaryV1 = .{};
    summary.measured_records = scenario.measured_count;
    var interval_initialized = false;
    var device_total: u64 = 0;
    const device_availability = aggregateAvailability(
        records,
        .device_timing,
    );
    const allocation_availability = aggregateAvailability(
        records,
        .allocated_context,
    );

    for (records) |record| {
        if (record.cohort != .measured) continue;
        summary.attempted_work_units = try addU64(
            summary.attempted_work_units,
            record.work_units,
        );
        if (record.host.presence_mask & event_admission != 0)
            summary.admitted_count += 1;
        switch (record.outcome) {
            .completed => {
                summary.completed_count += 1;
                summary.completed_work_units = try addU64(
                    summary.completed_work_units,
                    record.work_units,
                );
            },
            .capacity_rejected => summary.capacity_rejected_count += 1,
            .failed => summary.failed_count += 1,
            .cancelled => summary.cancelled_count += 1,
            .timed_out => summary.timed_out_count += 1,
        }
        if (record.fallback) summary.fallback_count += 1;
        switch (record.correctness) {
            .correct => summary.correctness_correct_count += 1,
            .incorrect => summary.correctness_incorrect_count += 1,
            .not_applicable => {},
        }
        if (!interval_initialized) {
            summary.interval_start_ns = record.host.arrival.ns;
            summary.interval_end_ns = record.host.settlement.ns;
            interval_initialized = true;
        } else {
            summary.interval_start_ns =
                @min(summary.interval_start_ns, record.host.arrival.ns);
            summary.interval_end_ns =
                @max(summary.interval_end_ns, record.host.settlement.ns);
        }
        if (device_availability.availability == .present and
            planeEligible(record, .device_timing) and
            record.device_timing.availability == .present)
        {
            device_total = try addU64(
                device_total,
                record.device_timing.duration_ns,
            );
        }
        if (allocation_availability.availability == .present and
            planeEligible(record, .allocated_context) and
            record.allocated_context.availability == .present)
        {
            summary.allocated_context_max_bytes = @max(
                summary.allocated_context_max_bytes,
                @max(
                    record.allocated_context.before_bytes,
                    record.allocated_context.after_bytes,
                ),
            );
        }
    }
    if (!interval_initialized or
        summary.interval_end_ns <= summary.interval_start_ns)
        return Error.InvalidSummary;
    summary.interval_numerator_ns =
        summary.interval_end_ns - summary.interval_start_ns;
    summary.interval_denominator = 1;
    summary.throughput_completed_work_numerator =
        summary.completed_work_units;
    summary.throughput_interval_denominator_ns =
        summary.interval_numerator_ns;
    summary.allocated_context_max_available =
        allocation_availability.availability == .present;
    if (!summary.allocated_context_max_available)
        summary.allocated_context_max_bytes = 0;

    summary.admission = distributionFor(records, .admission);
    summary.queue = distributionFor(records, .queue);
    summary.first_output = distributionFor(records, .first_output);
    summary.service = distributionFor(records, .service);
    summary.end_to_end = distributionFor(records, .end_to_end);
    summary.device_duration =
        distributionFor(records, .device_duration);
    summary.logical_in_flight_high_water =
        logicalHighWater(records, .measured);
    if (summary.logical_in_flight_high_water > scenario.max_in_flight)
        return Error.InvalidSummary;
    const flow = flowCompletionRange(scenario.flow_count, records);
    summary.flow_completion_min = flow.min;
    summary.flow_completion_max = flow.max;
    summary.flow_completion_spread = flow.max - flow.min;

    for (&summary.metrics, 0..) |*metric, index| {
        const kind: MetricKindV1 = @enumFromInt(index);
        metric.* = unsupportedMetric(scenario, kind);
    }
    const device_metric_index =
        @intFromEnum(MetricKindV1.device_duration_total_ns);
    summary.metrics[device_metric_index] =
        if (device_availability.availability == .present)
            presentMetric(
                .device_duration_total_ns,
                device_total,
                scenario.device_source_sha256,
                scenario.device_clock_sha256,
            )
        else
            unavailableMetric(
                scenario,
                .device_duration_total_ns,
                device_availability.availability,
                device_availability.reason_sha256,
            );
    const allocation_metric_index =
        @intFromEnum(
            MetricKindV1.current_allocated_size_max_bytes,
        );
    summary.metrics[allocation_metric_index] =
        if (allocation_availability.availability == .present)
            presentMetric(
                .current_allocated_size_max_bytes,
                summary.allocated_context_max_bytes,
                scenario.device_source_sha256,
                scenario.host_clock_sha256,
            )
        else
            unavailableMetric(
                scenario,
                .current_allocated_size_max_bytes,
                allocation_availability.availability,
                allocation_availability.reason_sha256,
            );
    summary.summary_sha256 = summarySha256V1(summary);
    if (!summaryFieldsValidV1(scenario, summary))
        return Error.InvalidSummary;
    return summary;
}

fn distributionFor(
    records: []const RecordV1,
    kind: LatencyKind,
) DistributionV1 {
    var result: DistributionV1 = .{};
    for (records) |record| {
        if (record.cohort == .measured and
            latencyValue(record, kind) != null)
            result.sample_count += 1;
    }
    if (result.sample_count == 0) return result;
    result.p50_ns = nearestRank(records, kind, 50, result.sample_count);
    result.p95_ns = nearestRank(records, kind, 95, result.sample_count);
    result.p99_ns = nearestRank(records, kind, 99, result.sample_count);
    result.max_ns = nearestRank(records, kind, 100, result.sample_count);
    return result;
}

fn nearestRank(
    records: []const RecordV1,
    kind: LatencyKind,
    percentile: u32,
    count: u32,
) u64 {
    const rank: u32 = @intCast(
        (@as(u64, percentile) * count + 99) / 100,
    );
    for (records) |candidate_record| {
        if (candidate_record.cohort != .measured) continue;
        const candidate = latencyValue(candidate_record, kind) orelse continue;
        var less: u32 = 0;
        var equal: u32 = 0;
        for (records) |other_record| {
            if (other_record.cohort != .measured) continue;
            const other = latencyValue(other_record, kind) orelse continue;
            if (other < candidate) less += 1;
            if (other == candidate) equal += 1;
        }
        if (less < rank and rank <= less + equal) return candidate;
    }
    unreachable;
}

fn latencyValue(record: RecordV1, kind: LatencyKind) ?u64 {
    const mask = record.host.presence_mask;
    return switch (kind) {
        .admission => if (mask & event_admission != 0)
            record.host.admission.ns - record.host.arrival.ns
        else
            null,
        .queue => if (mask & event_first_service != 0)
            record.host.first_service.ns - record.host.admission.ns
        else
            null,
        .first_output => if (mask & event_first_output != 0)
            record.host.first_output.ns - record.host.arrival.ns
        else
            null,
        .service => if (mask & event_first_service != 0)
            record.host.terminal.ns - record.host.first_service.ns
        else
            null,
        .end_to_end => record.host.settlement.ns - record.host.arrival.ns,
        .device_duration => if (record.device_timing.availability == .present)
            record.device_timing.duration_ns
        else
            null,
    };
}

fn logicalHighWater(
    records: []const RecordV1,
    cohort: ?CohortV1,
) u32 {
    var high_water: u32 = 0;
    for (records) |candidate| {
        if ((cohort != null and candidate.cohort != cohort.?) or
            candidate.host.presence_mask & event_admission == 0) continue;
        const sequence = candidate.host.admission.sequence;
        var active: u32 = 0;
        for (records) |record| {
            if ((cohort != null and record.cohort != cohort.?) or
                record.host.presence_mask & event_admission == 0) continue;
            if (record.host.admission.sequence <= sequence and
                sequence < record.host.settlement.sequence)
                active += 1;
        }
        high_water = @max(high_water, active);
    }
    return high_water;
}

const FlowRange = struct { min: u32, max: u32 };

fn flowCompletionRange(
    flow_count_value: u32,
    records: []const RecordV1,
) FlowRange {
    var result: FlowRange = .{
        .min = std.math.maxInt(u32),
        .max = 0,
    };
    var flow: u32 = 0;
    while (flow < flow_count_value) : (flow += 1) {
        var count: u32 = 0;
        for (records) |record| {
            if (record.cohort == .measured and
                record.flow_id == flow and record.outcome == .completed)
                count += 1;
        }
        result.min = @min(result.min, count);
        result.max = @max(result.max, count);
    }
    return result;
}

const AvailabilityPlane = enum {
    device_timing,
    allocated_context,
};

const AvailabilityAggregate = struct {
    availability: AvailabilityV1,
    reason_sha256: Digest,
};

fn planeEligible(
    record: RecordV1,
    plane: AvailabilityPlane,
) bool {
    return switch (plane) {
        .device_timing => record.host.presence_mask & event_submit_return != 0,
        .allocated_context => record.host.presence_mask & event_admission != 0,
    };
}

fn aggregateAvailability(
    records: []const RecordV1,
    plane: AvailabilityPlane,
) AvailabilityAggregate {
    var eligible: u32 = 0;
    var present: u32 = 0;
    var first_unavailable: ?AvailabilityV1 = null;
    var first_reason = zero_digest;
    var homogeneous = true;
    for (records) |record| {
        if (record.cohort != .measured or
            !planeEligible(record, plane))
            continue;
        eligible += 1;
        const availability: AvailabilityV1 = switch (plane) {
            .device_timing => record.device_timing.availability,
            .allocated_context => record.allocated_context.availability,
        };
        const reason: Digest = switch (plane) {
            .device_timing => record.device_timing.reason_sha256,
            .allocated_context => record.allocated_context.reason_sha256,
        };
        if (availability == .present) {
            present += 1;
            continue;
        }
        if (first_unavailable) |first| {
            if (first != availability or
                !digestEqual(first_reason, reason))
                homogeneous = false;
        } else {
            first_unavailable = availability;
            first_reason = reason;
        }
    }
    const kind: MetricKindV1 = switch (plane) {
        .device_timing => .device_duration_total_ns,
        .allocated_context => .current_allocated_size_max_bytes,
    };
    if (eligible == 0) return .{
        .availability = .missing,
        .reason_sha256 = metricAggregateReasonV1(
            kind,
            .no_eligible_samples,
        ),
    };
    if (present == eligible) return .{
        .availability = .present,
        .reason_sha256 = zero_digest,
    };
    if (present == 0 and homogeneous) return .{
        .availability = first_unavailable.?,
        .reason_sha256 = first_reason,
    };
    return .{
        .availability = .missing,
        .reason_sha256 = metricAggregateReasonV1(
            kind,
            .incomplete_samples,
        ),
    };
}

const AggregateReasonV1 = enum(u8) {
    no_eligible_samples = 1,
    incomplete_samples = 2,
};

fn metricAggregateReasonV1(
    kind: MetricKindV1,
    reason: AggregateReasonV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(
        "glacier-native-workload-metric-aggregate-reason-v1\x00",
    );
    hashU8(&hash, @intFromEnum(kind));
    hashU8(&hash, @intFromEnum(reason));
    return finishHash(&hash);
}

fn unsupportedMetric(
    scenario: ScenarioV1,
    kind: MetricKindV1,
) MetricV1 {
    return unavailableMetric(
        scenario,
        kind,
        .unsupported,
        metricUnsupportedReasonV1(kind),
    );
}

fn unavailableMetric(
    scenario: ScenarioV1,
    kind: MetricKindV1,
    availability: AvailabilityV1,
    reason_sha256: Digest,
) MetricV1 {
    std.debug.assert(availability != .present);
    const domains = metricDomains(scenario, kind);
    return .{
        .kind = kind,
        .availability = availability,
        .source_sha256 = domains.source,
        .clock_sha256 = domains.clock,
        .reason_sha256 = reason_sha256,
    };
}

const MetricDomains = struct {
    source: Digest,
    clock: Digest,
};

fn metricDomains(
    scenario: ScenarioV1,
    kind: MetricKindV1,
) MetricDomains {
    return switch (kind) {
        .cpu_time_ns, .process_rss_bytes => .{
            .source = scenario.host_source_sha256,
            .clock = scenario.host_clock_sha256,
        },
        .current_allocated_size_max_bytes => .{
            .source = scenario.device_source_sha256,
            .clock = scenario.host_clock_sha256,
        },
        else => .{
            .source = scenario.device_source_sha256,
            .clock = scenario.device_clock_sha256,
        },
    };
}

fn presentMetric(
    kind: MetricKindV1,
    numerator: u64,
    source: Digest,
    clock: Digest,
) MetricV1 {
    return .{
        .kind = kind,
        .availability = .present,
        .numerator = numerator,
        .denominator = 1,
        .source_sha256 = source,
        .clock_sha256 = clock,
    };
}

pub fn metricUnsupportedReasonV1(kind: MetricKindV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(metric_reason_domain);
    hashU8(&hash, @intFromEnum(kind));
    return finishHash(&hash);
}

fn summaryFieldsValidV1(
    scenario: ScenarioV1,
    summary: SummaryV1,
) bool {
    if (summary.abi_version != summary_abi or
        summary.measured_records != scenario.measured_count or
        @as(u64, summary.completed_count) +
            summary.capacity_rejected_count + summary.failed_count +
            summary.cancelled_count + summary.timed_out_count !=
            summary.measured_records or
        summary.interval_end_ns <= summary.interval_start_ns or
        summary.interval_numerator_ns !=
            summary.interval_end_ns - summary.interval_start_ns or
        summary.interval_denominator != 1 or
        summary.throughput_completed_work_numerator !=
            summary.completed_work_units or
        summary.throughput_interval_denominator_ns !=
            summary.interval_numerator_ns or
        summary.throughput_interval_denominator_ns == 0 or
        summary.logical_in_flight_high_water > scenario.max_in_flight or
        summary.flow_completion_max < summary.flow_completion_min or
        summary.flow_completion_spread !=
            summary.flow_completion_max - summary.flow_completion_min or
        (!summary.allocated_context_max_available and
            summary.allocated_context_max_bytes != 0))
        return false;
    inline for (std.meta.fields(MetricKindV1), 0..) |_, index| {
        if (!metricValid(
            summary.metrics[index],
            @enumFromInt(index),
        )) return false;
    }
    return digestEqual(
        summary.summary_sha256,
        summarySha256V1(summary),
    );
}

fn metricValid(value: MetricV1, expected: MetricKindV1) bool {
    if (value.kind != expected) return false;
    switch (value.availability) {
        .present => return value.denominator != 0 and
            !digestIsZero(value.source_sha256) and
            !digestIsZero(value.clock_sha256) and
            digestIsZero(value.reason_sha256),
        .missing, .denied, .unsupported => return value.numerator == 0 and
            value.denominator == 0 and
            !digestIsZero(value.source_sha256) and
            !digestIsZero(value.clock_sha256) and
            !digestIsZero(value.reason_sha256),
    }
}

fn reportClosureMatchesRecords(report: ReportV1) bool {
    var acquisitions: u64 = 0;
    var completions: u64 = 0;
    for (report.records) |record| {
        acquisitions = std.math.add(
            u64,
            acquisitions,
            record.logical.bank_acquisitions,
        ) catch return false;
        completions = std.math.add(
            u64,
            completions,
            record.logical.bank_completions,
        ) catch return false;
    }
    return acquisitions == report.closure.acquisitions and
        completions == report.closure.completions;
}

fn addU64(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn hostPoints(host: HostEventsV1) [event_count]EventPointV1 {
    return .{
        host.arrival,
        host.admission,
        host.first_service,
        host.submit_return,
        host.first_output,
        host.terminal,
        host.settlement,
    };
}

fn eventBit(index: usize) u8 {
    return @as(u8, 1) << @intCast(index);
}

fn scenarioDigests(value: ScenarioV1) [13]Digest {
    return .{
        value.workload_sha256,
        value.profile_sha256,
        value.artifact_sha256,
        value.build_sha256,
        value.machine_sha256,
        value.backend_sha256,
        value.device_sha256,
        value.placement_sha256,
        value.host_source_sha256,
        value.host_clock_sha256,
        value.device_source_sha256,
        value.device_clock_sha256,
        value.challenge_sha256,
    };
}

fn rootDigests(value: RootsV1) [9]Digest {
    return .{
        value.request_sha256,
        value.ticket_sha256,
        value.pin_sha256,
        value.dispatch_sha256,
        value.submission_sha256,
        value.output_sha256,
        value.oracle_sha256,
        value.terminal_sha256,
        value.completion_sha256,
    };
}

fn digestIsZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

pub fn scenarioSha256V1(value: ScenarioV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(scenario_domain);
    hashU64(&hash, value.abi_version);
    hashU8(&hash, @intFromEnum(value.mode));
    hashU8(&hash, @intFromEnum(value.evidence));
    hashU8(&hash, @intFromEnum(value.summary_algorithm));
    hashU32(&hash, value.warmup_count);
    hashU32(&hash, value.measured_count);
    hashU32(&hash, value.max_in_flight);
    hashU32(&hash, value.queue_count);
    hashU32(&hash, value.flow_count);
    for (scenarioDigests(value)) |digest| hash.update(&digest);
    return finishHash(&hash);
}

pub fn recordSha256V1(
    scenario_sha256: Digest,
    value: RecordV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(record_domain);
    hash.update(&scenario_sha256);
    hashU64(&hash, value.abi_version);
    hashU32(&hash, value.ordinal);
    hashU8(&hash, @intFromEnum(value.cohort));
    hashU8(&hash, @intFromEnum(value.outcome));
    hashU8(&hash, @intFromEnum(value.correctness));
    hashBool(&hash, value.fallback);
    hashU32(&hash, value.flow_id);
    hashU64(&hash, value.work_units);
    hashU32(&hash, value.adapter_queue_slot);
    hashU8(&hash, value.host.presence_mask);
    for (hostPoints(value.host)) |point| {
        hashU64(&hash, point.ns);
        hashU64(&hash, point.sequence);
    }
    for (rootDigests(value.roots)) |digest| hash.update(&digest);
    hashU64(&hash, value.maximum_abs_error_f64_bits);
    hashU8(&hash, @intFromEnum(value.device_timing.availability));
    hashU64(&hash, value.device_timing.raw_start_f64_bits);
    hashU64(&hash, value.device_timing.raw_end_f64_bits);
    hashU64(&hash, value.device_timing.duration_ns);
    hash.update(&value.device_timing.source_sha256);
    hash.update(&value.device_timing.clock_sha256);
    hash.update(&value.device_timing.reason_sha256);
    hashU8(&hash, @intFromEnum(value.allocated_context.availability));
    hashU64(&hash, value.allocated_context.before_bytes);
    hashU64(&hash, value.allocated_context.after_bytes);
    hash.update(&value.allocated_context.source_sha256);
    hash.update(&value.allocated_context.reason_sha256);
    hashU32(&hash, value.logical.bank_acquisitions);
    hashU32(&hash, value.logical.bank_completions);
    hashU64(&hash, value.logical.bank_used_before);
    hashU64(&hash, value.logical.bank_used_after_settlement);
    hashU32(&hash, value.logical.pin_count_before);
    hashU32(&hash, value.logical.pin_count_after_settlement);
    hashU32(&hash, value.logical.dispatch_count_before);
    hashU32(&hash, value.logical.dispatch_count_after_settlement);
    hashU32(&hash, value.logical.native_command_count_before);
    hashU32(&hash, value.logical.native_command_count_after_settlement);
    hash.update(&value.previous_record_sha256);
    return finishHash(&hash);
}

pub fn summarySha256V1(value: SummaryV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(summary_domain);
    hashU64(&hash, value.abi_version);
    hashU32(&hash, value.measured_records);
    hashU32(&hash, value.admitted_count);
    hashU32(&hash, value.completed_count);
    hashU32(&hash, value.capacity_rejected_count);
    hashU32(&hash, value.failed_count);
    hashU32(&hash, value.cancelled_count);
    hashU32(&hash, value.timed_out_count);
    hashU64(&hash, value.attempted_work_units);
    hashU64(&hash, value.completed_work_units);
    hashU64(&hash, value.interval_start_ns);
    hashU64(&hash, value.interval_end_ns);
    hashU64(&hash, value.interval_numerator_ns);
    hashU64(&hash, value.interval_denominator);
    hashU64(&hash, value.throughput_completed_work_numerator);
    hashU64(&hash, value.throughput_interval_denominator_ns);
    hashDistribution(&hash, value.admission);
    hashDistribution(&hash, value.queue);
    hashDistribution(&hash, value.first_output);
    hashDistribution(&hash, value.service);
    hashDistribution(&hash, value.end_to_end);
    hashDistribution(&hash, value.device_duration);
    hashU32(&hash, value.logical_in_flight_high_water);
    hashU32(&hash, value.flow_completion_min);
    hashU32(&hash, value.flow_completion_max);
    hashU32(&hash, value.flow_completion_spread);
    hashU32(&hash, value.fallback_count);
    hashU32(&hash, value.correctness_correct_count);
    hashU32(&hash, value.correctness_incorrect_count);
    hashBool(&hash, value.allocated_context_max_available);
    hashU64(&hash, value.allocated_context_max_bytes);
    for (value.metrics) |metric| hashMetric(&hash, metric);
    return finishHash(&hash);
}

pub fn closureSha256V1(value: ClosureV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(closure_domain);
    hashU64(&hash, value.abi_version);
    hashU32(&hash, value.bank_count);
    hashU32(&hash, value.pin_count);
    hashU32(&hash, value.dispatch_count);
    hashU32(&hash, value.native_command_count);
    hashU32(&hash, value.native_buffer_count);
    hashU64(&hash, value.acquisitions);
    hashU64(&hash, value.completions);
    hashBool(&hash, value.zero_orphan);
    return finishHash(&hash);
}

pub fn reportSha256V1(value: ReportV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(report_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.scenario.scenario_sha256);
    hashU32(&hash, @intCast(value.records.len));
    if (value.records.len == 0) {
        hash.update(&value.scenario.scenario_sha256);
    } else {
        hash.update(&value.records[value.records.len - 1].record_sha256);
    }
    hash.update(&value.summary.summary_sha256);
    hash.update(&value.closure.closure_sha256);
    return finishHash(&hash);
}

fn hashDistribution(
    hash: *std.crypto.hash.sha2.Sha256,
    value: DistributionV1,
) void {
    hashU32(hash, value.sample_count);
    hashU64(hash, value.p50_ns);
    hashU64(hash, value.p95_ns);
    hashU64(hash, value.p99_ns);
    hashU64(hash, value.max_ns);
}

fn hashMetric(
    hash: *std.crypto.hash.sha2.Sha256,
    value: MetricV1,
) void {
    hashU8(hash, @intFromEnum(value.kind));
    hashU8(hash, @intFromEnum(value.availability));
    hashU64(hash, value.numerator);
    hashU64(hash, value.denominator);
    hash.update(&value.source_sha256);
    hash.update(&value.clock_sha256);
    hash.update(&value.reason_sha256);
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&.{value});
}

fn hashBool(hash: *std.crypto.hash.sha2.Sha256, value: bool) void {
    hashU8(hash, @intFromBool(value));
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finishHash(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var value: Digest = undefined;
    hash.final(&value);
    return value;
}

pub fn encodeV1(
    report: ReportV1,
    destination: []u8,
) Error![]const u8 {
    try validateV1(report);
    const length = try encodedLengthV1(report.records.len);
    if (destination.len < length) return Error.CapacityExceeded;
    const output = destination[0..length];
    if (slicesOverlap(u8, output, RecordV1, report.records))
        return Error.InvalidStorage;
    @memset(output, 0);
    errdefer @memset(output, 0);

    var writer: Writer = .{ .bytes = output };
    try writer.writeBytes(&magic);
    try writer.writeU64(wire_abi);
    try writer.writeU64(length);
    try writer.writeU32(wire_flags);
    try writer.writeU32(0);
    try writer.writeU32(@intCast(report.records.len));
    try writer.writeU32(0);
    if (writer.position != header_bytes) return Error.InvalidLength;

    const body_start = writer.position;
    try writeScenario(&writer, report.scenario);
    for (report.records) |record| try writeRecord(&writer, record);
    try writeSummary(&writer, report.summary);
    try writeClosure(&writer, report.closure);
    try writer.writeDigest(report.report_sha256);
    const body_end = writer.position;
    if (body_end + wire_digest_bytes != length)
        return Error.InvalidLength;
    try writer.writeDigest(domainHash(
        body_domain,
        output[body_start..body_end],
    ));
    try writer.writeDigest(domainHash(
        footer_domain,
        output[0..writer.position],
    ));
    if (writer.position != length) return Error.InvalidLength;
    return output;
}

pub const encodeReportV1 = encodeV1;

pub fn decodeV1(
    encoded: []const u8,
    record_storage: []RecordV1,
) Error!ReportV1 {
    if (encoded.len < minimum_encoded_bytes)
        return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    if (!std.mem.eql(
        u8,
        try reader.readBytes(magic.len),
        &magic,
    )) return Error.InvalidMagic;
    if (try reader.readU64() != wire_abi) return Error.InvalidAbi;
    const declared_length = try reader.readU64();
    if (declared_length != encoded.len) return Error.InvalidLength;
    const flags = try reader.readU32();
    if (flags != wire_flags or flags & ~allowed_wire_flags != 0)
        return Error.InvalidFlags;
    if (try reader.readU32() != 0) return Error.InvalidReserved;
    const record_count_value = try reader.readU32();
    if (record_count_value > max_records)
        return Error.CapacityExceeded;
    if (try reader.readU32() != 0) return Error.InvalidReserved;
    if (reader.position != header_bytes or
        encoded.len != try encodedLengthV1(record_count_value))
        return Error.InvalidLength;
    if (record_storage.len < record_count_value)
        return Error.CapacityExceeded;
    const records = record_storage[0..record_count_value];
    if (slicesOverlap(u8, encoded, RecordV1, records))
        return Error.InvalidStorage;

    const body_end = encoded.len - wire_digest_bytes;
    const stored_body = readDigestAt(encoded, body_end);
    const stored_footer = readDigestAt(encoded, body_end + 32);
    if (!digestEqual(
        stored_body,
        domainHash(body_domain, encoded[header_bytes..body_end]),
    )) return Error.InvalidBodyDigest;
    if (!digestEqual(
        stored_footer,
        domainHash(footer_domain, encoded[0 .. body_end + 32]),
    )) return Error.InvalidFooterDigest;

    const scenario = try readScenario(&reader);
    for (records) |*record| record.* = try readRecord(&reader);
    const summary = try readSummary(&reader);
    const closure = try readClosure(&reader);
    const report_root = try reader.readDigest();
    if (reader.position != body_end) return Error.InvalidLength;

    const report: ReportV1 = .{
        .scenario = scenario,
        .records = records,
        .summary = summary,
        .closure = closure,
        .report_sha256 = report_root,
    };
    try validateV1(report);
    return report;
}

pub const decodeReportV1 = decodeV1;

fn writeScenario(writer: *Writer, value: ScenarioV1) Error!void {
    const start = writer.position;
    try writer.writeU64(value.abi_version);
    try writer.writeU8(@intFromEnum(value.mode));
    try writer.writeU8(@intFromEnum(value.evidence));
    try writer.writeU8(@intFromEnum(value.summary_algorithm));
    try writer.writeU8(0);
    try writer.writeU32(value.warmup_count);
    try writer.writeU32(value.measured_count);
    try writer.writeU32(value.max_in_flight);
    try writer.writeU32(value.queue_count);
    try writer.writeU32(value.flow_count);
    try writer.writeU32(0);
    for (scenarioDigests(value)) |digest|
        try writer.writeDigest(digest);
    try writer.writeDigest(value.scenario_sha256);
    if (writer.position - start != scenario_wire_bytes)
        return Error.InvalidLength;
}

fn readScenario(reader: *Reader) Error!ScenarioV1 {
    const start = reader.position;
    var value: ScenarioV1 = .{};
    value.abi_version = try reader.readU64();
    value.mode = try reader.readEnum(ModeV1);
    value.evidence = try reader.readEnum(EvidenceV1);
    value.summary_algorithm =
        try reader.readEnum(SummaryAlgorithmV1);
    try reader.readReserved(1);
    value.warmup_count = try reader.readU32();
    value.measured_count = try reader.readU32();
    value.max_in_flight = try reader.readU32();
    value.queue_count = try reader.readU32();
    value.flow_count = try reader.readU32();
    try reader.readReserved(4);
    value.workload_sha256 = try reader.readDigest();
    value.profile_sha256 = try reader.readDigest();
    value.artifact_sha256 = try reader.readDigest();
    value.build_sha256 = try reader.readDigest();
    value.machine_sha256 = try reader.readDigest();
    value.backend_sha256 = try reader.readDigest();
    value.device_sha256 = try reader.readDigest();
    value.placement_sha256 = try reader.readDigest();
    value.host_source_sha256 = try reader.readDigest();
    value.host_clock_sha256 = try reader.readDigest();
    value.device_source_sha256 = try reader.readDigest();
    value.device_clock_sha256 = try reader.readDigest();
    value.challenge_sha256 = try reader.readDigest();
    value.scenario_sha256 = try reader.readDigest();
    if (reader.position - start != scenario_wire_bytes)
        return Error.InvalidLength;
    return value;
}

fn writeRecord(writer: *Writer, value: RecordV1) Error!void {
    const start = writer.position;
    try writer.writeU64(value.abi_version);
    try writer.writeU32(value.ordinal);
    try writer.writeU8(@intFromEnum(value.cohort));
    try writer.writeU8(@intFromEnum(value.outcome));
    try writer.writeU8(@intFromEnum(value.correctness));
    try writer.writeBool(value.fallback);
    try writer.writeU32(value.flow_id);
    try writer.writeU64(value.work_units);
    try writer.writeU32(value.adapter_queue_slot);
    try writer.writeU8(value.host.presence_mask);
    try writer.writeReserved(3);
    for (hostPoints(value.host)) |point| {
        try writer.writeU64(point.ns);
        try writer.writeU64(point.sequence);
    }
    for (rootDigests(value.roots)) |digest|
        try writer.writeDigest(digest);
    try writer.writeU64(value.maximum_abs_error_f64_bits);
    try writer.writeU8(@intFromEnum(value.device_timing.availability));
    try writer.writeReserved(7);
    try writer.writeU64(value.device_timing.raw_start_f64_bits);
    try writer.writeU64(value.device_timing.raw_end_f64_bits);
    try writer.writeU64(value.device_timing.duration_ns);
    try writer.writeDigest(value.device_timing.source_sha256);
    try writer.writeDigest(value.device_timing.clock_sha256);
    try writer.writeDigest(value.device_timing.reason_sha256);
    try writer.writeU8(@intFromEnum(
        value.allocated_context.availability,
    ));
    try writer.writeReserved(7);
    try writer.writeU64(value.allocated_context.before_bytes);
    try writer.writeU64(value.allocated_context.after_bytes);
    try writer.writeDigest(value.allocated_context.source_sha256);
    try writer.writeDigest(value.allocated_context.reason_sha256);
    try writer.writeU32(value.logical.bank_acquisitions);
    try writer.writeU32(value.logical.bank_completions);
    try writer.writeU64(value.logical.bank_used_before);
    try writer.writeU64(value.logical.bank_used_after_settlement);
    try writer.writeU32(value.logical.pin_count_before);
    try writer.writeU32(value.logical.pin_count_after_settlement);
    try writer.writeU32(value.logical.dispatch_count_before);
    try writer.writeU32(value.logical.dispatch_count_after_settlement);
    try writer.writeU32(value.logical.native_command_count_before);
    try writer.writeU32(
        value.logical.native_command_count_after_settlement,
    );
    try writer.writeDigest(value.previous_record_sha256);
    try writer.writeDigest(value.record_sha256);
    if (writer.position - start != record_wire_bytes)
        return Error.InvalidLength;
}

fn readRecord(reader: *Reader) Error!RecordV1 {
    const start = reader.position;
    var value: RecordV1 = .{};
    value.abi_version = try reader.readU64();
    value.ordinal = try reader.readU32();
    value.cohort = try reader.readEnum(CohortV1);
    value.outcome = try reader.readEnum(OutcomeV1);
    value.correctness = try reader.readEnum(CorrectnessV1);
    value.fallback = try reader.readBool();
    value.flow_id = try reader.readU32();
    value.work_units = try reader.readU64();
    value.adapter_queue_slot = try reader.readU32();
    value.host.presence_mask = try reader.readU8();
    try reader.readReserved(3);
    const points = [_]*EventPointV1{
        &value.host.arrival,
        &value.host.admission,
        &value.host.first_service,
        &value.host.submit_return,
        &value.host.first_output,
        &value.host.terminal,
        &value.host.settlement,
    };
    for (points) |point| {
        point.ns = try reader.readU64();
        point.sequence = try reader.readU64();
    }
    value.roots.request_sha256 = try reader.readDigest();
    value.roots.ticket_sha256 = try reader.readDigest();
    value.roots.pin_sha256 = try reader.readDigest();
    value.roots.dispatch_sha256 = try reader.readDigest();
    value.roots.submission_sha256 = try reader.readDigest();
    value.roots.output_sha256 = try reader.readDigest();
    value.roots.oracle_sha256 = try reader.readDigest();
    value.roots.terminal_sha256 = try reader.readDigest();
    value.roots.completion_sha256 = try reader.readDigest();
    value.maximum_abs_error_f64_bits = try reader.readU64();
    value.device_timing.availability =
        try reader.readEnum(AvailabilityV1);
    try reader.readReserved(7);
    value.device_timing.raw_start_f64_bits = try reader.readU64();
    value.device_timing.raw_end_f64_bits = try reader.readU64();
    value.device_timing.duration_ns = try reader.readU64();
    value.device_timing.source_sha256 = try reader.readDigest();
    value.device_timing.clock_sha256 = try reader.readDigest();
    value.device_timing.reason_sha256 = try reader.readDigest();
    value.allocated_context.availability =
        try reader.readEnum(AvailabilityV1);
    try reader.readReserved(7);
    value.allocated_context.before_bytes = try reader.readU64();
    value.allocated_context.after_bytes = try reader.readU64();
    value.allocated_context.source_sha256 = try reader.readDigest();
    value.allocated_context.reason_sha256 = try reader.readDigest();
    value.logical.bank_acquisitions = try reader.readU32();
    value.logical.bank_completions = try reader.readU32();
    value.logical.bank_used_before = try reader.readU64();
    value.logical.bank_used_after_settlement = try reader.readU64();
    value.logical.pin_count_before = try reader.readU32();
    value.logical.pin_count_after_settlement = try reader.readU32();
    value.logical.dispatch_count_before = try reader.readU32();
    value.logical.dispatch_count_after_settlement =
        try reader.readU32();
    value.logical.native_command_count_before = try reader.readU32();
    value.logical.native_command_count_after_settlement =
        try reader.readU32();
    value.previous_record_sha256 = try reader.readDigest();
    value.record_sha256 = try reader.readDigest();
    if (reader.position - start != record_wire_bytes)
        return Error.InvalidLength;
    return value;
}

fn writeDistribution(
    writer: *Writer,
    value: DistributionV1,
) Error!void {
    try writer.writeU32(value.sample_count);
    try writer.writeU32(0);
    try writer.writeU64(value.p50_ns);
    try writer.writeU64(value.p95_ns);
    try writer.writeU64(value.p99_ns);
    try writer.writeU64(value.max_ns);
}

fn readDistribution(reader: *Reader) Error!DistributionV1 {
    var value: DistributionV1 = .{};
    value.sample_count = try reader.readU32();
    try reader.readReserved(4);
    value.p50_ns = try reader.readU64();
    value.p95_ns = try reader.readU64();
    value.p99_ns = try reader.readU64();
    value.max_ns = try reader.readU64();
    return value;
}

fn writeMetric(writer: *Writer, value: MetricV1) Error!void {
    try writer.writeU8(@intFromEnum(value.kind));
    try writer.writeU8(@intFromEnum(value.availability));
    try writer.writeReserved(6);
    try writer.writeU64(value.numerator);
    try writer.writeU64(value.denominator);
    try writer.writeDigest(value.source_sha256);
    try writer.writeDigest(value.clock_sha256);
    try writer.writeDigest(value.reason_sha256);
}

fn readMetric(reader: *Reader) Error!MetricV1 {
    var value: MetricV1 = .{};
    value.kind = try reader.readEnum(MetricKindV1);
    value.availability = try reader.readEnum(AvailabilityV1);
    try reader.readReserved(6);
    value.numerator = try reader.readU64();
    value.denominator = try reader.readU64();
    value.source_sha256 = try reader.readDigest();
    value.clock_sha256 = try reader.readDigest();
    value.reason_sha256 = try reader.readDigest();
    return value;
}

fn writeSummary(writer: *Writer, value: SummaryV1) Error!void {
    const start = writer.position;
    try writer.writeU64(value.abi_version);
    try writer.writeU32(value.measured_records);
    try writer.writeU32(value.admitted_count);
    try writer.writeU32(value.completed_count);
    try writer.writeU32(value.capacity_rejected_count);
    try writer.writeU32(value.failed_count);
    try writer.writeU32(value.cancelled_count);
    try writer.writeU32(value.timed_out_count);
    try writer.writeU64(value.attempted_work_units);
    try writer.writeU64(value.completed_work_units);
    try writer.writeU64(value.interval_start_ns);
    try writer.writeU64(value.interval_end_ns);
    try writer.writeU64(value.interval_numerator_ns);
    try writer.writeU64(value.interval_denominator);
    try writer.writeU64(
        value.throughput_completed_work_numerator,
    );
    try writer.writeU64(value.throughput_interval_denominator_ns);
    try writeDistribution(writer, value.admission);
    try writeDistribution(writer, value.queue);
    try writeDistribution(writer, value.first_output);
    try writeDistribution(writer, value.service);
    try writeDistribution(writer, value.end_to_end);
    try writeDistribution(writer, value.device_duration);
    try writer.writeU32(value.logical_in_flight_high_water);
    try writer.writeU32(value.flow_completion_min);
    try writer.writeU32(value.flow_completion_max);
    try writer.writeU32(value.flow_completion_spread);
    try writer.writeU32(value.fallback_count);
    try writer.writeU32(value.correctness_correct_count);
    try writer.writeU32(value.correctness_incorrect_count);
    try writer.writeBool(value.allocated_context_max_available);
    try writer.writeReserved(7);
    try writer.writeU64(value.allocated_context_max_bytes);
    for (value.metrics) |metric| try writeMetric(writer, metric);
    try writer.writeDigest(value.summary_sha256);
    if (writer.position - start != summary_wire_bytes)
        return Error.InvalidLength;
}

fn readSummary(reader: *Reader) Error!SummaryV1 {
    const start = reader.position;
    var value: SummaryV1 = .{};
    value.abi_version = try reader.readU64();
    value.measured_records = try reader.readU32();
    value.admitted_count = try reader.readU32();
    value.completed_count = try reader.readU32();
    value.capacity_rejected_count = try reader.readU32();
    value.failed_count = try reader.readU32();
    value.cancelled_count = try reader.readU32();
    value.timed_out_count = try reader.readU32();
    value.attempted_work_units = try reader.readU64();
    value.completed_work_units = try reader.readU64();
    value.interval_start_ns = try reader.readU64();
    value.interval_end_ns = try reader.readU64();
    value.interval_numerator_ns = try reader.readU64();
    value.interval_denominator = try reader.readU64();
    value.throughput_completed_work_numerator =
        try reader.readU64();
    value.throughput_interval_denominator_ns =
        try reader.readU64();
    value.admission = try readDistribution(reader);
    value.queue = try readDistribution(reader);
    value.first_output = try readDistribution(reader);
    value.service = try readDistribution(reader);
    value.end_to_end = try readDistribution(reader);
    value.device_duration = try readDistribution(reader);
    value.logical_in_flight_high_water = try reader.readU32();
    value.flow_completion_min = try reader.readU32();
    value.flow_completion_max = try reader.readU32();
    value.flow_completion_spread = try reader.readU32();
    value.fallback_count = try reader.readU32();
    value.correctness_correct_count = try reader.readU32();
    value.correctness_incorrect_count = try reader.readU32();
    value.allocated_context_max_available = try reader.readBool();
    try reader.readReserved(7);
    value.allocated_context_max_bytes = try reader.readU64();
    for (&value.metrics) |*metric| metric.* = try readMetric(reader);
    value.summary_sha256 = try reader.readDigest();
    if (reader.position - start != summary_wire_bytes)
        return Error.InvalidLength;
    return value;
}

fn writeClosure(writer: *Writer, value: ClosureV1) Error!void {
    const start = writer.position;
    try writer.writeU64(value.abi_version);
    try writer.writeU32(value.bank_count);
    try writer.writeU32(value.pin_count);
    try writer.writeU32(value.dispatch_count);
    try writer.writeU32(value.native_command_count);
    try writer.writeU32(value.native_buffer_count);
    try writer.writeU64(value.acquisitions);
    try writer.writeU64(value.completions);
    try writer.writeBool(value.zero_orphan);
    try writer.writeReserved(3);
    try writer.writeDigest(value.closure_sha256);
    if (writer.position - start != closure_wire_bytes)
        return Error.InvalidLength;
}

fn readClosure(reader: *Reader) Error!ClosureV1 {
    const start = reader.position;
    var value: ClosureV1 = .{};
    value.abi_version = try reader.readU64();
    value.bank_count = try reader.readU32();
    value.pin_count = try reader.readU32();
    value.dispatch_count = try reader.readU32();
    value.native_command_count = try reader.readU32();
    value.native_buffer_count = try reader.readU32();
    value.acquisitions = try reader.readU64();
    value.completions = try reader.readU64();
    value.zero_orphan = try reader.readBool();
    try reader.readReserved(3);
    value.closure_sha256 = try reader.readDigest();
    if (reader.position - start != closure_wire_bytes)
        return Error.InvalidLength;
    return value;
}

fn domainHash(domain: []const u8, bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(bytes);
    return finishHash(&hash);
}

fn readDigestAt(bytes: []const u8, offset: usize) Digest {
    var result: Digest = undefined;
    @memcpy(&result, bytes[offset .. offset + 32]);
    return result;
}

fn slicesOverlap(
    comptime A: type,
    left: []const A,
    comptime B: type,
    right: []const B,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = left_start + left.len * @sizeOf(A);
    const right_end = right_start + right.len * @sizeOf(B);
    return left_start < right_end and right_start < left_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeBytes(self: *Writer, value: []const u8) Error!void {
        if (self.position > self.bytes.len or
            value.len > self.bytes.len - self.position)
            return Error.InvalidLength;
        @memcpy(
            self.bytes[self.position .. self.position + value.len],
            value,
        );
        self.position += value.len;
    }

    fn writeU8(self: *Writer, value: u8) Error!void {
        try self.writeBytes(&.{value});
    }

    fn writeBool(self: *Writer, value: bool) Error!void {
        try self.writeU8(@intFromBool(value));
    }

    fn writeReserved(self: *Writer, count: usize) Error!void {
        if (self.position > self.bytes.len or
            count > self.bytes.len - self.position)
            return Error.InvalidLength;
        @memset(self.bytes[self.position .. self.position + count], 0);
        self.position += count;
    }

    fn writeU32(self: *Writer, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeU64(self: *Writer, value: u64) Error!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.writeBytes(&bytes);
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        try self.writeBytes(&value);
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readBytes(self: *Reader, length: usize) Error![]const u8 {
        if (self.position > self.bytes.len or
            length > self.bytes.len - self.position)
            return Error.InvalidLength;
        const value = self.bytes[self.position .. self.position + length];
        self.position += length;
        return value;
    }

    fn readU8(self: *Reader) Error!u8 {
        return (try self.readBytes(1))[0];
    }

    fn readBool(self: *Reader) Error!bool {
        return switch (try self.readU8()) {
            0 => false,
            1 => true,
            else => Error.InvalidBoolean,
        };
    }

    fn readEnum(self: *Reader, comptime E: type) Error!E {
        return std.meta.intToEnum(E, try self.readU8()) catch
            return Error.InvalidEnum;
    }

    fn readReserved(self: *Reader, length: usize) Error!void {
        if (!std.mem.allEqual(
            u8,
            try self.readBytes(length),
            0,
        )) return Error.InvalidReserved;
    }

    fn readU32(self: *Reader) Error!u32 {
        var bytes: [4]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(4));
        return std.mem.readInt(u32, &bytes, .little);
    }

    fn readU64(self: *Reader) Error!u64 {
        var bytes: [8]u8 = undefined;
        @memcpy(&bytes, try self.readBytes(8));
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn readDigest(self: *Reader) Error!Digest {
        var value: Digest = undefined;
        @memcpy(&value, try self.readBytes(32));
        return value;
    }
};

const test_record_count: usize = 6;
const test_wire_bytes: usize =
    minimum_encoded_bytes + test_record_count * record_wire_bytes;

fn testDigest(tag: u8, ordinal: u32) Digest {
    var bytes: [5]u8 = undefined;
    bytes[0] = tag;
    std.mem.writeInt(u32, bytes[1..5], ordinal, .little);
    return digestV1(&bytes);
}

fn testScenarioV1() !ScenarioV1 {
    return makeScenarioV1(.{
        .mode = .closed,
        .evidence = .synthetic,
        .warmup_count = 2,
        .measured_count = 4,
        .max_in_flight = 2,
        .queue_count = 2,
        .flow_count = 2,
        .workload_sha256 = testDigest(1, 0),
        .profile_sha256 = testDigest(2, 0),
        .artifact_sha256 = testDigest(3, 0),
        .build_sha256 = testDigest(4, 0),
        .machine_sha256 = testDigest(5, 0),
        .backend_sha256 = testDigest(6, 0),
        .device_sha256 = testDigest(7, 0),
        .placement_sha256 = testDigest(8, 0),
        .host_source_sha256 = testDigest(9, 0),
        .host_clock_sha256 = testDigest(10, 0),
        .device_source_sha256 = testDigest(11, 0),
        .device_clock_sha256 = testDigest(12, 0),
        .challenge_sha256 = testDigest(13, 0),
    });
}

fn completeHost(
    timestamps: [event_count]u64,
    sequences: [event_count]u64,
) HostEventsV1 {
    return .{
        .presence_mask = event_presence_all,
        .arrival = .{ .ns = timestamps[0], .sequence = sequences[0] },
        .admission = .{ .ns = timestamps[1], .sequence = sequences[1] },
        .first_service = .{ .ns = timestamps[2], .sequence = sequences[2] },
        .submit_return = .{ .ns = timestamps[3], .sequence = sequences[3] },
        .first_output = .{ .ns = timestamps[4], .sequence = sequences[4] },
        .terminal = .{ .ns = timestamps[5], .sequence = sequences[5] },
        .settlement = .{ .ns = timestamps[6], .sequence = sequences[6] },
    };
}

fn completedTestRecord(
    scenario: ScenarioV1,
    ordinal: u32,
    cohort: CohortV1,
    flow_id: u32,
    timestamps: [event_count]u64,
    sequences: [event_count]u64,
) !RecordV1 {
    const start = 10.0 + @as(f64, @floatFromInt(ordinal));
    const end = start + 0.000001;
    const start_bits: u64 = @bitCast(start);
    const end_bits: u64 = @bitCast(end);
    return makeRecordV1(.{
        .ordinal = ordinal,
        .cohort = cohort,
        .outcome = .completed,
        .correctness = .correct,
        .flow_id = flow_id,
        .work_units = 10,
        .adapter_queue_slot = flow_id,
        .host = completeHost(timestamps, sequences),
        .roots = .{
            .request_sha256 = testDigest(20, ordinal),
            .ticket_sha256 = testDigest(21, ordinal),
            .pin_sha256 = testDigest(22, ordinal),
            .dispatch_sha256 = testDigest(23, ordinal),
            .submission_sha256 = testDigest(24, ordinal),
            .output_sha256 = testDigest(25, ordinal),
            .oracle_sha256 = testDigest(26, ordinal),
            .terminal_sha256 = testDigest(27, ordinal),
            .completion_sha256 = testDigest(28, ordinal),
        },
        .maximum_abs_error_f64_bits = @bitCast(@as(f64, 0.001)),
        .device_timing = .{
            .availability = .present,
            .raw_start_f64_bits = start_bits,
            .raw_end_f64_bits = end_bits,
            .duration_ns = deviceDurationNsV1(
                start_bits,
                end_bits,
            ).?,
            .source_sha256 = scenario.device_source_sha256,
            .clock_sha256 = scenario.device_clock_sha256,
        },
        .allocated_context = .{
            .availability = .present,
            .before_bytes = 4_096 + ordinal,
            .after_bytes = 4_112 + ordinal,
            .source_sha256 = scenario.device_source_sha256,
        },
        .logical = .{
            .bank_acquisitions = 1,
            .bank_completions = 1,
            .bank_used_before = 100,
            .bank_used_after_settlement = 100,
            .pin_count_before = 1,
            .pin_count_after_settlement = 0,
            .dispatch_count_before = 1,
            .dispatch_count_after_settlement = 0,
            .native_command_count_before = 1,
            .native_command_count_after_settlement = 0,
        },
    });
}

fn unavailableTiming(
    scenario: ScenarioV1,
    ordinal: u32,
) DeviceTimingV1 {
    return .{
        .availability = .unsupported,
        .source_sha256 = scenario.device_source_sha256,
        .clock_sha256 = scenario.device_clock_sha256,
        .reason_sha256 = testDigest(30, ordinal),
    };
}

fn unavailableAllocation(
    scenario: ScenarioV1,
    ordinal: u32,
) AllocatedContextV1 {
    return .{
        .availability = .unsupported,
        .source_sha256 = scenario.device_source_sha256,
        .reason_sha256 = testDigest(31, ordinal),
    };
}

fn rejectedTestRecord(
    scenario: ScenarioV1,
    ordinal: u32,
) !RecordV1 {
    return makeRecordV1(.{
        .ordinal = ordinal,
        .cohort = .measured,
        .outcome = .capacity_rejected,
        .work_units = 10,
        .host = .{
            .presence_mask = capacity_rejected_presence,
            .arrival = .{ .ns = 1_030, .sequence = 38 },
            .terminal = .{ .ns = 1_031, .sequence = 39 },
            .settlement = .{ .ns = 1_031, .sequence = 40 },
        },
        .roots = .{
            .request_sha256 = testDigest(20, ordinal),
            .terminal_sha256 = testDigest(27, ordinal),
            .completion_sha256 = testDigest(28, ordinal),
        },
        .device_timing = unavailableTiming(scenario, ordinal),
        .allocated_context = unavailableAllocation(scenario, ordinal),
    });
}

fn timedOutTestRecord(
    scenario: ScenarioV1,
    ordinal: u32,
) !RecordV1 {
    return makeRecordV1(.{
        .ordinal = ordinal,
        .cohort = .measured,
        .outcome = .timed_out,
        .work_units = 10,
        .adapter_queue_slot = 0,
        .host = .{
            .presence_mask = event_presence_all & ~event_first_output,
            .arrival = .{ .ns = 1_040, .sequence = 41 },
            .admission = .{ .ns = 1_041, .sequence = 42 },
            .first_service = .{ .ns = 1_042, .sequence = 43 },
            .submit_return = .{ .ns = 1_043, .sequence = 44 },
            .terminal = .{ .ns = 1_045, .sequence = 45 },
            .settlement = .{ .ns = 1_046, .sequence = 46 },
        },
        .roots = .{
            .request_sha256 = testDigest(20, ordinal),
            .ticket_sha256 = testDigest(21, ordinal),
            .pin_sha256 = testDigest(22, ordinal),
            .dispatch_sha256 = testDigest(23, ordinal),
            .submission_sha256 = testDigest(24, ordinal),
            .terminal_sha256 = testDigest(27, ordinal),
            .completion_sha256 = testDigest(28, ordinal),
        },
        .device_timing = unavailableTiming(scenario, ordinal),
        .allocated_context = unavailableAllocation(scenario, ordinal),
        .logical = .{
            .bank_acquisitions = 1,
            .bank_completions = 1,
            .bank_used_before = 100,
            .bank_used_after_settlement = 100,
            .pin_count_before = 1,
            .pin_count_after_settlement = 0,
            .dispatch_count_before = 1,
            .dispatch_count_after_settlement = 0,
            .native_command_count_before = 1,
            .native_command_count_after_settlement = 0,
        },
    });
}

fn fillTestRecords(
    scenario: ScenarioV1,
    records: *[test_record_count]RecordV1,
) !void {
    records[0] = try completedTestRecord(
        scenario,
        0,
        .warmup,
        0,
        [_]u64{100} ** event_count,
        .{ 1, 2, 3, 4, 5, 6, 7 },
    );
    records[1] = try completedTestRecord(
        scenario,
        1,
        .warmup,
        1,
        .{ 200, 201, 202, 203, 204, 205, 206 },
        .{ 8, 9, 10, 11, 12, 13, 14 },
    );
    records[2] = try completedTestRecord(
        scenario,
        2,
        .measured,
        0,
        .{ 1_000, 1_001, 1_002, 1_003, 1_010, 1_012, 1_016 },
        .{ 20, 21, 22, 23, 30, 32, 36 },
    );
    records[3] = try completedTestRecord(
        scenario,
        3,
        .measured,
        1,
        .{ 1_004, 1_005, 1_006, 1_007, 1_011, 1_013, 1_017 },
        .{ 24, 25, 26, 27, 31, 33, 37 },
    );
    records[4] = try rejectedTestRecord(scenario, 4);
    records[5] = try timedOutTestRecord(scenario, 5);
}

fn resealTestWire(encoded: []u8) void {
    const body_end = encoded.len - wire_digest_bytes;
    const body = domainHash(
        body_domain,
        encoded[header_bytes..body_end],
    );
    @memcpy(encoded[body_end..][0..32], &body);
    const footer = domainHash(
        footer_domain,
        encoded[0 .. body_end + 32],
    );
    @memcpy(encoded[body_end + 32 ..][0..32], &footer);
}

test "native workload report wire round-trips measured-only summary" {
    const testing = std.testing;
    const scenario = try testScenarioV1();
    var records: [test_record_count]RecordV1 = undefined;
    try fillTestRecords(scenario, &records);
    const closure = try makeClosureV1(5, 5);
    const report = try sealV1(scenario, &records, closure);

    try testing.expectEqual(@as(u32, 4), report.summary.measured_records);
    try testing.expectEqual(@as(u32, 3), report.summary.admitted_count);
    try testing.expectEqual(@as(u32, 2), report.summary.completed_count);
    try testing.expectEqual(
        @as(u32, 1),
        report.summary.capacity_rejected_count,
    );
    try testing.expectEqual(@as(u32, 1), report.summary.timed_out_count);
    try testing.expectEqual(
        @as(u64, 40),
        report.summary.attempted_work_units,
    );
    try testing.expectEqual(
        @as(u64, 20),
        report.summary.completed_work_units,
    );
    try testing.expectEqual(
        @as(u32, 2),
        report.summary.logical_in_flight_high_water,
    );
    try testing.expectEqual(
        @as(u32, 2),
        report.summary.device_duration.sample_count,
    );
    const device_metric = report.summary.metrics[
        @intFromEnum(MetricKindV1.device_duration_total_ns)
    ];
    try testing.expectEqual(
        AvailabilityV1.missing,
        device_metric.availability,
    );
    try testing.expectEqual(
        scenario.device_source_sha256,
        device_metric.source_sha256,
    );
    try testing.expectEqual(
        scenario.device_clock_sha256,
        device_metric.clock_sha256,
    );
    try testing.expect(!digestIsZero(device_metric.reason_sha256));
    try testing.expect(
        !report.summary.allocated_context_max_available,
    );
    try testing.expectEqual(
        @as(u64, 0),
        report.summary.allocated_context_max_bytes,
    );
    try testing.expectEqual(
        AvailabilityV1.unsupported,
        report.summary.metrics[
            @intFromEnum(MetricKindV1.physical_parallelism)
        ].availability,
    );

    var encoded: [test_wire_bytes]u8 = undefined;
    const wire = try encodeV1(report, &encoded);
    try testing.expectEqual(test_wire_bytes, wire.len);
    var decoded_records: [test_record_count]RecordV1 = undefined;
    const decoded = try decodeV1(wire, &decoded_records);
    try testing.expectEqualDeep(report.scenario, decoded.scenario);
    try testing.expectEqualDeep(report.summary, decoded.summary);
    try testing.expectEqualDeep(report.closure, decoded.closure);
    try testing.expectEqualDeep(report.records, decoded.records);
    try testing.expectEqual(
        report.report_sha256,
        decoded.report_sha256,
    );
    try validateV1(decoded);
}

test "native workload report rejects wire and semantic mutations" {
    const testing = std.testing;
    const scenario = try testScenarioV1();
    var records: [test_record_count]RecordV1 = undefined;
    try fillTestRecords(scenario, &records);
    const report = try sealV1(
        scenario,
        &records,
        try makeClosureV1(5, 5),
    );
    var encoded: [test_wire_bytes]u8 = undefined;
    const wire = try encodeV1(report, &encoded);

    var scratch: [test_record_count]RecordV1 = undefined;
    try testing.expectError(
        Error.InvalidLength,
        decodeV1(wire[0 .. wire.len - 1], &scratch),
    );
    var extended: [test_wire_bytes + 1]u8 = undefined;
    @memcpy(extended[0..test_wire_bytes], wire);
    extended[test_wire_bytes] = 0;
    try testing.expectError(
        Error.InvalidLength,
        decodeV1(&extended, &scratch),
    );

    for (0..wire.len) |index| {
        var mutated = encoded;
        mutated[index] ^= 1;
        const accepted =
            if (decodeV1(&mutated, &scratch)) |_| true else |_| false;
        try testing.expect(!accepted);
    }

    const first_record = header_bytes + scenario_wire_bytes;
    var reordered = encoded;
    std.mem.swap(
        [record_wire_bytes]u8,
        @ptrCast(reordered[first_record..][0..record_wire_bytes]),
        @ptrCast(
            reordered[first_record + record_wire_bytes ..][0..record_wire_bytes],
        ),
    );
    resealTestWire(&reordered);
    const reordered_accepted =
        if (decodeV1(&reordered, &scratch)) |_| true else |_| false;
    try testing.expect(!reordered_accepted);

    var duplicate_records = records;
    duplicate_records[3].ordinal = duplicate_records[2].ordinal;
    var duplicate_report = report;
    duplicate_report.records = &duplicate_records;
    try testing.expectError(
        Error.InvalidChain,
        validateV1(duplicate_report),
    );

    var forged_summary = report;
    forged_summary.summary.completed_count += 1;
    forged_summary.summary.summary_sha256 =
        summarySha256V1(forged_summary.summary);
    forged_summary.report_sha256 = reportSha256V1(forged_summary);
    try testing.expectError(
        Error.InvalidSummary,
        validateV1(forged_summary),
    );

    var forged_physical = report;
    const physical_index =
        @intFromEnum(MetricKindV1.physical_parallelism);
    forged_physical.summary.metrics[physical_index] = .{
        .kind = .physical_parallelism,
        .availability = .present,
        .numerator = 2,
        .denominator = 1,
        .source_sha256 = scenario.device_source_sha256,
        .clock_sha256 = scenario.device_clock_sha256,
    };
    forged_physical.summary.summary_sha256 =
        summarySha256V1(forged_physical.summary);
    forged_physical.report_sha256 =
        reportSha256V1(forged_physical);
    try testing.expectError(
        Error.InvalidSummary,
        validateV1(forged_physical),
    );

    var invalid_duration = records[2];
    invalid_duration.record_sha256 = zero_digest;
    invalid_duration.previous_record_sha256 = zero_digest;
    invalid_duration.device_timing.duration_ns += 1;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(invalid_duration),
    );

    var incomplete_bank = records[2];
    incomplete_bank.record_sha256 = zero_digest;
    incomplete_bank.previous_record_sha256 = zero_digest;
    incomplete_bank.logical.bank_completions = 0;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(incomplete_bank),
    );

    var changed_bank_usage = records[2];
    changed_bank_usage.record_sha256 = zero_digest;
    changed_bank_usage.previous_record_sha256 = zero_digest;
    changed_bank_usage.logical.bank_used_after_settlement += 1;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(changed_bank_usage),
    );

    var retained_pin = records[2];
    retained_pin.record_sha256 = zero_digest;
    retained_pin.previous_record_sha256 = zero_digest;
    retained_pin.logical.pin_count_after_settlement = 1;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(retained_pin),
    );

    var retained_dispatch = records[2];
    retained_dispatch.record_sha256 = zero_digest;
    retained_dispatch.previous_record_sha256 = zero_digest;
    retained_dispatch.logical.dispatch_count_after_settlement = 1;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(retained_dispatch),
    );

    var retained_command = records[2];
    retained_command.record_sha256 = zero_digest;
    retained_command.previous_record_sha256 = zero_digest;
    retained_command.logical.native_command_count_after_settlement = 1;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(retained_command),
    );

    var no_bank_admission = records[2];
    no_bank_admission.record_sha256 = zero_digest;
    no_bank_admission.previous_record_sha256 = zero_digest;
    no_bank_admission.logical = .{};
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(no_bank_admission),
    );

    var rejected_fallback = records[4];
    rejected_fallback.record_sha256 = zero_digest;
    rejected_fallback.previous_record_sha256 = zero_digest;
    rejected_fallback.fallback = true;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(rejected_fallback),
    );

    var rejected_device_timing = records[4];
    rejected_device_timing.record_sha256 = zero_digest;
    rejected_device_timing.previous_record_sha256 = zero_digest;
    rejected_device_timing.device_timing =
        records[2].device_timing;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(rejected_device_timing),
    );

    var rejected_allocation = records[4];
    rejected_allocation.record_sha256 = zero_digest;
    rejected_allocation.previous_record_sha256 = zero_digest;
    rejected_allocation.allocated_context =
        records[2].allocated_context;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(rejected_allocation),
    );

    var unadmitted_pin = records[4];
    unadmitted_pin.record_sha256 = zero_digest;
    unadmitted_pin.previous_record_sha256 = zero_digest;
    unadmitted_pin.outcome = .failed;
    unadmitted_pin.logical.pin_count_before = 1;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(unadmitted_pin),
    );

    var unsubmitted_dispatch = records[5];
    unsubmitted_dispatch.record_sha256 = zero_digest;
    unsubmitted_dispatch.previous_record_sha256 = zero_digest;
    unsubmitted_dispatch.host.presence_mask &=
        ~event_submit_return;
    unsubmitted_dispatch.host.submit_return = .{};
    unsubmitted_dispatch.roots.ticket_sha256 = zero_digest;
    unsubmitted_dispatch.roots.dispatch_sha256 = zero_digest;
    unsubmitted_dispatch.roots.submission_sha256 = zero_digest;
    try testing.expectError(
        Error.InvalidRecord,
        makeRecordV1(unsubmitted_dispatch),
    );

    var incoherent_clock_records = records;
    incoherent_clock_records[3].host.arrival.ns = 999;
    try testing.expectError(
        Error.InvalidEvent,
        sealV1(
            scenario,
            &incoherent_clock_records,
            try makeClosureV1(5, 5),
        ),
    );

    var out_of_order_arrival_records = records;
    out_of_order_arrival_records[3].host.arrival = .{
        .ns = 999,
        .sequence = 19,
    };
    try testing.expectError(
        Error.InvalidEvent,
        sealV1(
            scenario,
            &out_of_order_arrival_records,
            try makeClosureV1(5, 5),
        ),
    );

    var overlapping_warmup_records = records;
    overlapping_warmup_records[1].host.settlement = .{
        .ns = 1_047,
        .sequence = 47,
    };
    try testing.expectError(
        Error.InvalidEvent,
        sealV1(
            scenario,
            &overlapping_warmup_records,
            try makeClosureV1(5, 5),
        ),
    );

    var overlapping_slot_records = records;
    overlapping_slot_records[3].adapter_queue_slot = 0;
    try testing.expectError(
        Error.InvalidEvent,
        sealV1(
            scenario,
            &overlapping_slot_records,
            try makeClosureV1(5, 5),
        ),
    );

    var partial_overflow_records = records;
    const large_device_end_bits: u64 =
        @bitCast(@as(f64, 10_000_000_000.0));
    const large_device_duration = deviceDurationNsV1(
        @bitCast(@as(f64, 0.0)),
        large_device_end_bits,
    ).?;
    for (partial_overflow_records[2..4]) |*record| {
        record.device_timing.raw_start_f64_bits =
            @bitCast(@as(f64, 0.0));
        record.device_timing.raw_end_f64_bits =
            large_device_end_bits;
        record.device_timing.duration_ns =
            large_device_duration;
    }
    const partial_overflow_report = try sealV1(
        scenario,
        &partial_overflow_records,
        try makeClosureV1(5, 5),
    );
    try testing.expectEqual(
        AvailabilityV1.missing,
        partial_overflow_report.summary.metrics[
            @intFromEnum(MetricKindV1.device_duration_total_ns)
        ].availability,
    );
}

test "native workload report enforces the whole-campaign in-flight bound" {
    const testing = std.testing;
    var scenario = try testScenarioV1();
    scenario.measured_count = 1;
    scenario.max_in_flight = 1;
    scenario.scenario_sha256 = scenarioSha256V1(scenario);
    try testing.expect(scenarioValidV1(scenario));

    var records: [3]RecordV1 = undefined;
    records[0] = try completedTestRecord(
        scenario,
        0,
        .warmup,
        0,
        .{ 100, 101, 102, 103, 104, 105, 115 },
        .{ 1, 2, 3, 4, 5, 6, 15 },
    );
    records[1] = try completedTestRecord(
        scenario,
        1,
        .warmup,
        1,
        .{ 108, 109, 110, 111, 112, 113, 114 },
        .{ 8, 9, 10, 11, 12, 13, 14 },
    );
    records[2] = try completedTestRecord(
        scenario,
        2,
        .measured,
        0,
        .{ 116, 117, 118, 119, 120, 121, 122 },
        .{ 16, 17, 18, 19, 20, 21, 22 },
    );

    try testing.expectEqual(
        @as(u32, 1),
        logicalHighWater(&records, .measured),
    );
    try testing.expectEqual(
        @as(u32, 2),
        logicalHighWater(&records, null),
    );
    try testing.expectError(
        Error.InvalidEvent,
        sealV1(
            scenario,
            &records,
            try makeClosureV1(3, 3),
        ),
    );
}

test "native workload report decoder rejects typed outer-resealed mutations" {
    const testing = std.testing;
    const scenario = try testScenarioV1();
    var records: [test_record_count]RecordV1 = undefined;
    try fillTestRecords(scenario, &records);
    const report = try sealV1(
        scenario,
        &records,
        try makeClosureV1(5, 5),
    );
    var encoded: [test_wire_bytes]u8 = undefined;
    _ = try encodeV1(report, &encoded);
    var scratch: [test_record_count]RecordV1 = undefined;

    var mutated = encoded;
    mutated[28] = 1;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidReserved,
        decodeV1(&mutated, &scratch),
    );

    mutated = encoded;
    mutated[header_bytes + 11] = 1;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidReserved,
        decodeV1(&mutated, &scratch),
    );

    mutated = encoded;
    mutated[header_bytes + 8] = 0xff;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidEnum,
        decodeV1(&mutated, &scratch),
    );

    const first_record = header_bytes + scenario_wire_bytes;
    mutated = encoded;
    mutated[first_record + 12] = 0xff;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidEnum,
        decodeV1(&mutated, &scratch),
    );

    mutated = encoded;
    mutated[first_record + 15] = 2;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidBoolean,
        decodeV1(&mutated, &scratch),
    );

    mutated = encoded;
    mutated[first_record + 33] = 1;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidReserved,
        decodeV1(&mutated, &scratch),
    );

    const summary_start =
        first_record + test_record_count * record_wire_bytes;
    mutated = encoded;
    mutated[summary_start + 368] = 2;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidBoolean,
        decodeV1(&mutated, &scratch),
    );

    mutated = encoded;
    mutated[summary_start + 384] = 0xff;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidEnum,
        decodeV1(&mutated, &scratch),
    );

    const closure_start = summary_start + summary_wire_bytes;
    mutated = encoded;
    mutated[closure_start + 44] = 2;
    resealTestWire(&mutated);
    try testing.expectError(
        Error.InvalidBoolean,
        decodeV1(&mutated, &scratch),
    );
}

test "native workload report rejects overlapping and undersized storage" {
    const testing = std.testing;
    const scenario = try testScenarioV1();
    var records: [test_record_count]RecordV1 = undefined;
    try fillTestRecords(scenario, &records);
    const report = try sealV1(
        scenario,
        &records,
        try makeClosureV1(5, 5),
    );
    var encoded: [test_wire_bytes]u8 = undefined;
    _ = try encodeV1(report, &encoded);

    try testing.expectError(
        Error.CapacityExceeded,
        encodedLengthV1(max_records + 1),
    );
    var undersized: [test_record_count - 1]RecordV1 = undefined;
    try testing.expectError(
        Error.CapacityExceeded,
        decodeV1(&encoded, &undersized),
    );

    comptime std.debug.assert(
        @sizeOf([test_record_count]RecordV1) <= test_wire_bytes,
    );
    var encode_alias: [test_wire_bytes]u8 align(@alignOf(RecordV1)) = undefined;
    const encode_alias_records: *[test_record_count]RecordV1 =
        @ptrCast(&encode_alias);
    encode_alias_records.* = records;
    var aliased_report = report;
    aliased_report.records = encode_alias_records;
    try testing.expectError(
        Error.InvalidStorage,
        encodeV1(aliased_report, &encode_alias),
    );

    var decode_alias: [test_wire_bytes]u8 align(@alignOf(RecordV1)) = encoded;
    const decode_alias_records: *[test_record_count]RecordV1 =
        @ptrCast(&decode_alias);
    try testing.expectError(
        Error.InvalidStorage,
        decodeV1(&decode_alias, decode_alias_records),
    );
}

test "native workload report fixed layout is padding independent" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), header_bytes);
    try testing.expectEqual(@as(usize, 484), scenario_wire_bytes);
    try testing.expectEqual(@as(usize, 772), record_wire_bytes);
    try testing.expectEqual(@as(usize, 40), distribution_wire_bytes);
    try testing.expectEqual(@as(usize, 120), metric_wire_bytes);
    try testing.expectEqual(@as(usize, 1_856), summary_wire_bytes);
    try testing.expectEqual(@as(usize, 80), closure_wire_bytes);
    try testing.expectEqual(
        test_wire_bytes,
        try encodedLengthV1(test_record_count),
    );
    try testing.expectEqual(
        max_encoded_bytes,
        try encodedLengthV1(max_records),
    );
}
