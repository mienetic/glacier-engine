//! Portable, bounded contract for native workload observations.
//!
//! This module records what an observer reported without granting the
//! observer authority to run a workload. Every metric carries an explicit
//! availability state; an unavailable value is never inferred as zero.
//! Portable values are fixed-size, pointer-free, and hashed field-by-field.
//! OS probes, clocks, handles, and callback contexts belong in the runtime
//! runner rather than this contract.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const descriptor_abi: u64 = 0x474e_4f44_0000_0001;
pub const rule_abi: u64 = 0x474e_4f4c_0000_0001;
pub const plan_abi: u64 = 0x474e_4f50_0000_0001;
pub const observation_abi: u64 = 0x474e_4f4f_0000_0001;
pub const bundle_abi: u64 = 0x474e_4f42_0000_0001;

pub const maximum_rules: usize = 16;
pub const maximum_observations: usize = 32;
pub const allowed_metric_bits: u64 =
    (@as(u64, 0x1ffff) << 1) |
    (@as(u64, 0xfff) << 32);

const descriptor_domain =
    "glacier-native-observer-descriptor-v1\x00";
const rule_domain = "glacier-native-observation-rule-v1\x00";
const plan_domain = "glacier-native-observation-plan-v1\x00";
const observation_domain =
    "glacier-native-observation-record-v1\x00";
const observation_section_domain =
    "glacier-native-observation-section-v1\x00";
const bundle_domain = "glacier-native-observation-bundle-v1\x00";
const run_domain = "glacier-native-observation-run-v1\x00";

pub const Error = error{
    ArithmeticOverflow,
    InvalidBundle,
    InvalidDescriptor,
    InvalidObservation,
    InvalidPlan,
    InvalidRule,
    ObservationLimitExceeded,
    RuleLimitExceeded,
};

pub const AvailabilityV1 = enum(u8) {
    unused = 0,
    present = 1,
    missing = 2,
    denied = 3,
    unsupported = 4,
};

pub const PhaseV1 = enum(u8) {
    unused = 0,
    probe = 1,
    pre_run = 2,
    begin = 3,
    in_run = 4,
    end = 5,
    post_run = 6,
};

pub const PlaneV1 = enum(u8) {
    unused = 0,
    host = 1,
    accelerator = 2,
};

pub const ExecutionPlaneV1 = enum(u8) {
    unused = 0,
    host = 1,
    accelerator = 2,
    mixed = 3,
};

pub const UnitV1 = enum(u8) {
    unused = 0,
    count = 1,
    boolean = 2,
    nanoseconds = 3,
    bytes = 4,
    ppm = 5,
    milli_celsius = 6,
    kilo_hertz = 7,
    milli_watts = 8,
    micro_joules = 9,
};

/// IDs stay below 64 so declared and directly observed metrics fit one mask.
pub const MetricIdV1 = enum(u8) {
    unused = 0,
    host_monotonic_time = 1,
    host_logical_cpu_count = 2,
    host_cpu_busy_ppm = 3,
    host_cpu_idle_ppm = 4,
    host_external_cpu_ppm = 5,
    process_cpu_time = 6,
    process_resident_bytes = 7,
    host_available_memory_bytes = 8,
    host_page_activity_count = 9,
    host_swap_used_bytes = 10,
    host_power_source = 11,
    host_low_power_mode = 12,
    host_thermal_constraint = 13,
    host_cpu_temperature = 14,
    host_cpu_frequency = 15,
    host_cpu_power = 16,
    host_cpu_energy = 17,
    accelerator_device_present = 32,
    accelerator_cpu_fallback = 33,
    accelerator_utilization = 34,
    accelerator_allocated_bytes = 35,
    accelerator_committed_bytes = 36,
    accelerator_resident_bytes = 37,
    accelerator_queue_depth = 38,
    accelerator_temperature = 39,
    accelerator_frequency = 40,
    accelerator_power = 41,
    accelerator_energy = 42,
    accelerator_device_time = 43,
};

pub const RuleScopeV1 = enum(u8) {
    unused = 0,
    probe = 1,
    pre_run = 2,
    post_run = 3,
    pre_post = 4,
};

pub const PredicateV1 = enum(u8) {
    unused = 0,
    require_present = 1,
    inclusive_range = 2,
    max_abs_delta = 3,
    require_false = 4,
    same_source = 5,
    same_subject = 6,
};

pub const DescriptorV1 = struct {
    abi_version: u64 = 0,
    implementation_abi: u64 = 0,
    observer_epoch: u64 = 0,
    declared_metric_bits: u64 = 0,
    direct_metric_bits: u64 = 0,
    namespace_sha256: Digest = zero_digest,
    source_schema_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
};

pub const RuleV1 = struct {
    abi_version: u64 = 0,
    metric: MetricIdV1 = .unused,
    scope: RuleScopeV1 = .unused,
    predicate: PredicateV1 = .unused,
    lower: i64 = 0,
    upper: i64 = 0,
    rule_sha256: Digest = zero_digest,
};

pub const PlanV1 = struct {
    abi_version: u64 = 0,
    observer_descriptor_sha256: Digest = zero_digest,
    workload_profile_sha256: Digest = zero_digest,
    artifact_sha256: Digest = zero_digest,
    build_sha256: Digest = zero_digest,
    machine_sha256: Digest = zero_digest,
    backend_sha256: Digest = zero_digest,
    device_sha256: Digest = zero_digest,
    placement_sha256: Digest = zero_digest,
    execution_plane: ExecutionPlaneV1 = .unused,
    worker_count: u64 = 0,
    queue_count: u64 = 0,
    rule_count: u64 = 0,
    rules: [maximum_rules]RuleV1 =
        [_]RuleV1{.{}} ** maximum_rules,
    challenge_sha256: Digest = zero_digest,
    run_sha256: Digest = zero_digest,
    plan_sha256: Digest = zero_digest,
};

pub const ObservationV1 = struct {
    abi_version: u64 = 0,
    run_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
    phase: PhaseV1 = .unused,
    sample_sequence: u64 = 0,
    metric: MetricIdV1 = .unused,
    plane: PlaneV1 = .unused,
    availability: AvailabilityV1 = .unused,
    unit: UnitV1 = .unused,
    value: i64 = 0,
    observed_at_ticks: u64 = 0,
    sample_clock_domain_sha256: Digest = zero_digest,
    value_clock_domain_sha256: Digest = zero_digest,
    source_sha256: Digest = zero_digest,
    provenance_sha256: Digest = zero_digest,
    subject_sha256: Digest = zero_digest,
    reason_sha256: Digest = zero_digest,
    observation_sha256: Digest = zero_digest,
};

pub const ObservationBundleV1 = struct {
    abi_version: u64 = 0,
    run_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
    phase: PhaseV1 = .unused,
    record_count: u64 = 0,
    records: [maximum_observations]ObservationV1 =
        [_]ObservationV1{.{}} ** maximum_observations,
    records_sha256: Digest = zero_digest,
    bundle_sha256: Digest = zero_digest,
};

pub fn metricBitV1(metric: MetricIdV1) Error!u64 {
    const shift = @intFromEnum(metric);
    if (shift == 0 or shift >= 64) return Error.InvalidObservation;
    return @as(u64, 1) << @intCast(shift);
}

pub fn metricPlaneV1(metric: MetricIdV1) Error!PlaneV1 {
    return switch (metric) {
        .host_monotonic_time,
        .host_logical_cpu_count,
        .host_cpu_busy_ppm,
        .host_cpu_idle_ppm,
        .host_external_cpu_ppm,
        .process_cpu_time,
        .process_resident_bytes,
        .host_available_memory_bytes,
        .host_page_activity_count,
        .host_swap_used_bytes,
        .host_power_source,
        .host_low_power_mode,
        .host_thermal_constraint,
        .host_cpu_temperature,
        .host_cpu_frequency,
        .host_cpu_power,
        .host_cpu_energy,
        => .host,
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
        => .accelerator,
        .unused => Error.InvalidObservation,
    };
}

pub fn metricUnitV1(metric: MetricIdV1) Error!UnitV1 {
    return switch (metric) {
        .host_monotonic_time,
        .process_cpu_time,
        .accelerator_device_time,
        => .nanoseconds,
        .host_logical_cpu_count,
        .host_page_activity_count,
        .host_power_source,
        .host_thermal_constraint,
        .accelerator_queue_depth,
        => .count,
        .host_low_power_mode,
        .accelerator_device_present,
        .accelerator_cpu_fallback,
        => .boolean,
        .host_cpu_busy_ppm,
        .host_cpu_idle_ppm,
        .host_external_cpu_ppm,
        .accelerator_utilization,
        => .ppm,
        .process_resident_bytes,
        .host_available_memory_bytes,
        .host_swap_used_bytes,
        .accelerator_allocated_bytes,
        .accelerator_committed_bytes,
        .accelerator_resident_bytes,
        => .bytes,
        .host_cpu_temperature,
        .accelerator_temperature,
        => .milli_celsius,
        .host_cpu_frequency,
        .accelerator_frequency,
        => .kilo_hertz,
        .host_cpu_power,
        .accelerator_power,
        => .milli_watts,
        .host_cpu_energy,
        .accelerator_energy,
        => .micro_joules,
        .unused => Error.InvalidObservation,
    };
}

pub fn metricValueInDomainV1(
    metric: MetricIdV1,
    value: i64,
) bool {
    if (metric == .host_logical_cpu_count)
        return value >= 1;
    const unit = metricUnitV1(metric) catch return false;
    return switch (unit) {
        .milli_celsius => value >= -273_150,
        .count,
        .boolean,
        .nanoseconds,
        .bytes,
        .ppm,
        .kilo_hertz,
        .milli_watts,
        .micro_joules,
        => value >= 0,
        .unused => false,
    };
}

pub fn makeDescriptorV1(
    implementation_abi: u64,
    observer_epoch: u64,
    declared_metric_bits: u64,
    direct_metric_bits: u64,
    namespace_sha256: Digest,
    source_schema_sha256: Digest,
) Error!DescriptorV1 {
    var result: DescriptorV1 = .{
        .abi_version = descriptor_abi,
        .implementation_abi = implementation_abi,
        .observer_epoch = observer_epoch,
        .declared_metric_bits = declared_metric_bits,
        .direct_metric_bits = direct_metric_bits,
        .namespace_sha256 = namespace_sha256,
        .source_schema_sha256 = source_schema_sha256,
    };
    result.descriptor_sha256 = descriptorSha256V1(result);
    try validateDescriptorV1(result);
    return result;
}

pub fn descriptorSha256V1(value: DescriptorV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(descriptor_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.implementation_abi);
    hashU64(&hash, value.observer_epoch);
    hashU64(&hash, value.declared_metric_bits);
    hashU64(&hash, value.direct_metric_bits);
    hash.update(&value.namespace_sha256);
    hash.update(&value.source_schema_sha256);
    return finish(&hash);
}

pub fn validateDescriptorV1(value: DescriptorV1) Error!void {
    if (value.abi_version != descriptor_abi or
        value.implementation_abi == 0 or
        value.observer_epoch == 0 or
        value.declared_metric_bits == 0 or
        value.declared_metric_bits & ~allowed_metric_bits != 0 or
        value.direct_metric_bits & ~value.declared_metric_bits != 0 or
        digestIsZero(value.namespace_sha256) or
        digestIsZero(value.source_schema_sha256) or
        !digestEqual(
            value.descriptor_sha256,
            descriptorSha256V1(value),
        ))
        return Error.InvalidDescriptor;
}

pub fn makeRuleV1(
    metric: MetricIdV1,
    scope: RuleScopeV1,
    predicate: PredicateV1,
    lower: i64,
    upper: i64,
) Error!RuleV1 {
    var result: RuleV1 = .{
        .abi_version = rule_abi,
        .metric = metric,
        .scope = scope,
        .predicate = predicate,
        .lower = lower,
        .upper = upper,
    };
    result.rule_sha256 = ruleSha256V1(result);
    try validateRuleV1(result);
    return result;
}

pub fn ruleSha256V1(value: RuleV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(rule_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, @intFromEnum(value.metric));
    hashU64(&hash, @intFromEnum(value.scope));
    hashU64(&hash, @intFromEnum(value.predicate));
    hashI64(&hash, value.lower);
    hashI64(&hash, value.upper);
    return finish(&hash);
}

pub fn validateRuleV1(value: RuleV1) Error!void {
    _ = metricBitV1(value.metric) catch return Error.InvalidRule;
    if (value.abi_version != rule_abi or
        value.scope == .unused or
        value.predicate == .unused or
        !digestEqual(value.rule_sha256, ruleSha256V1(value)))
        return Error.InvalidRule;

    switch (value.predicate) {
        .require_present, .require_false, .same_source, .same_subject => {
            if (value.lower != 0 or value.upper != 0)
                return Error.InvalidRule;
        },
        .inclusive_range => {
            if (value.lower > value.upper) return Error.InvalidRule;
        },
        .max_abs_delta => {
            if (value.scope != .pre_post or
                value.lower != 0 or value.upper < 0)
                return Error.InvalidRule;
        },
        .unused => return Error.InvalidRule,
    }
    if ((value.predicate == .same_source or
        value.predicate == .same_subject) and
        value.scope != .pre_post)
        return Error.InvalidRule;
    if (value.scope == .pre_post and
        value.predicate != .max_abs_delta and
        value.predicate != .same_source and
        value.predicate != .same_subject)
        return Error.InvalidRule;
}

pub fn makePlanV1(
    descriptor: DescriptorV1,
    workload_profile_sha256: Digest,
    artifact_sha256: Digest,
    build_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    execution_plane: ExecutionPlaneV1,
    worker_count: u64,
    queue_count: u64,
    rules: []const RuleV1,
    challenge_sha256: Digest,
) Error!PlanV1 {
    if (rules.len == 0 or rules.len > maximum_rules)
        return Error.RuleLimitExceeded;
    try validateDescriptorV1(descriptor);
    var result: PlanV1 = .{
        .abi_version = plan_abi,
        .observer_descriptor_sha256 = descriptor.descriptor_sha256,
        .workload_profile_sha256 = workload_profile_sha256,
        .artifact_sha256 = artifact_sha256,
        .build_sha256 = build_sha256,
        .machine_sha256 = machine_sha256,
        .backend_sha256 = backend_sha256,
        .device_sha256 = device_sha256,
        .placement_sha256 = placement_sha256,
        .execution_plane = execution_plane,
        .worker_count = worker_count,
        .queue_count = queue_count,
        .rule_count = rules.len,
        .challenge_sha256 = challenge_sha256,
    };
    @memcpy(result.rules[0..rules.len], rules);
    result.run_sha256 = runSha256V1(result);
    result.plan_sha256 = planSha256V1(result);
    try validatePlanV1(descriptor, result);
    return result;
}

pub fn runSha256V1(value: PlanV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(run_domain);
    hash.update(&value.observer_descriptor_sha256);
    hash.update(&value.workload_profile_sha256);
    hash.update(&value.artifact_sha256);
    hash.update(&value.build_sha256);
    hash.update(&value.machine_sha256);
    hash.update(&value.backend_sha256);
    hash.update(&value.device_sha256);
    hash.update(&value.placement_sha256);
    hashU64(&hash, @intFromEnum(value.execution_plane));
    hashU64(&hash, value.worker_count);
    hashU64(&hash, value.queue_count);
    hash.update(&value.challenge_sha256);
    return finish(&hash);
}

pub fn planSha256V1(value: PlanV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.observer_descriptor_sha256);
    hash.update(&value.workload_profile_sha256);
    hash.update(&value.artifact_sha256);
    hash.update(&value.build_sha256);
    hash.update(&value.machine_sha256);
    hash.update(&value.backend_sha256);
    hash.update(&value.device_sha256);
    hash.update(&value.placement_sha256);
    hashU64(&hash, @intFromEnum(value.execution_plane));
    hashU64(&hash, value.worker_count);
    hashU64(&hash, value.queue_count);
    hashU64(&hash, value.rule_count);
    const count = std.math.cast(usize, value.rule_count) orelse 0;
    if (count <= maximum_rules) {
        for (value.rules[0..count]) |rule| {
            hash.update(&rule.rule_sha256);
        }
    }
    hash.update(&value.challenge_sha256);
    hash.update(&value.run_sha256);
    return finish(&hash);
}

pub fn validatePlanV1(
    descriptor: DescriptorV1,
    value: PlanV1,
) Error!void {
    try validateDescriptorV1(descriptor);
    const count = std.math.cast(
        usize,
        value.rule_count,
    ) orelse return Error.InvalidPlan;
    if (value.abi_version != plan_abi or
        !digestEqual(
            value.observer_descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        value.execution_plane == .unused or
        value.worker_count == 0 or value.queue_count == 0 or
        count == 0 or count > maximum_rules or
        digestIsZero(value.workload_profile_sha256) or
        digestIsZero(value.artifact_sha256) or
        digestIsZero(value.build_sha256) or
        digestIsZero(value.machine_sha256) or
        digestIsZero(value.backend_sha256) or
        digestIsZero(value.device_sha256) or
        digestIsZero(value.placement_sha256) or
        digestIsZero(value.challenge_sha256) or
        !digestEqual(value.run_sha256, runSha256V1(value)) or
        !digestEqual(value.plan_sha256, planSha256V1(value)))
        return Error.InvalidPlan;

    var previous_key: u32 = 0;
    var host_time_pre_gate = false;
    var host_time_post_gate = false;
    var host_cpu_pre_gate = false;
    var host_cpu_stability_gate = false;
    var accelerator_present_gate = false;
    var accelerator_pre_fallback_gate = false;
    var accelerator_post_fallback_gate = false;
    for (value.rules[0..count]) |rule| {
        try validateRuleV1(rule);
        const bit = metricBitV1(rule.metric) catch
            return Error.InvalidPlan;
        if (descriptor.declared_metric_bits & bit == 0)
            return Error.InvalidPlan;
        const key =
            (@as(u32, @intFromEnum(rule.metric)) << 16) |
            (@as(u32, @intFromEnum(rule.scope)) << 8) |
            @as(u32, @intFromEnum(rule.predicate));
        if (key <= previous_key) return Error.InvalidPlan;
        previous_key = key;
        if (rule.metric == .host_monotonic_time and
            rule.predicate == .require_present)
        {
            if (rule.scope == .pre_run) host_time_pre_gate = true;
            if (rule.scope == .post_run) host_time_post_gate = true;
        }
        if (rule.metric == .host_logical_cpu_count and
            rule.scope == .pre_run and
            rule.predicate == .inclusive_range and
            rule.lower >= 1)
            host_cpu_pre_gate = true;
        if (rule.metric == .host_logical_cpu_count and
            rule.scope == .pre_post and
            rule.predicate == .max_abs_delta and
            rule.upper == 0)
            host_cpu_stability_gate = true;
        if (rule.metric == .accelerator_device_present and
            rule.scope == .pre_run and
            rule.predicate == .inclusive_range and
            rule.lower == 1 and rule.upper == 1)
            accelerator_present_gate = true;
        if (rule.metric == .accelerator_cpu_fallback and
            rule.predicate == .require_false)
        {
            if (rule.scope == .pre_run)
                accelerator_pre_fallback_gate = true;
            if (rule.scope == .post_run)
                accelerator_post_fallback_gate = true;
        }
    }
    for (value.rules[count..]) |rule| {
        if (!std.meta.eql(rule, RuleV1{}))
            return Error.InvalidPlan;
    }
    const baseline_bits =
        (metricBitV1(.host_monotonic_time) catch
            return Error.InvalidPlan) |
        (metricBitV1(.host_logical_cpu_count) catch
            return Error.InvalidPlan);
    if (descriptor.direct_metric_bits & baseline_bits != baseline_bits or
        !host_time_pre_gate or !host_time_post_gate or
        !host_cpu_pre_gate or !host_cpu_stability_gate)
        return Error.InvalidPlan;
    if (value.execution_plane == .accelerator or
        value.execution_plane == .mixed)
    {
        const accelerator_bits =
            (metricBitV1(.accelerator_device_present) catch
                return Error.InvalidPlan) |
            (metricBitV1(.accelerator_cpu_fallback) catch
                return Error.InvalidPlan);
        if (descriptor.direct_metric_bits & accelerator_bits !=
            accelerator_bits or
            !accelerator_present_gate or
            !accelerator_pre_fallback_gate or
            !accelerator_post_fallback_gate)
            return Error.InvalidPlan;
    }
}

pub fn makeObservationV1(
    descriptor: DescriptorV1,
    plan: PlanV1,
    phase: PhaseV1,
    sample_sequence: u64,
    metric: MetricIdV1,
    availability: AvailabilityV1,
    value: i64,
    observed_at_ticks: u64,
    sample_clock_domain_sha256: Digest,
    value_clock_domain_sha256: Digest,
    source_sha256: Digest,
    provenance_sha256: Digest,
    subject_sha256: Digest,
    reason_sha256: Digest,
) Error!ObservationV1 {
    var result: ObservationV1 = .{
        .abi_version = observation_abi,
        .run_sha256 = plan.run_sha256,
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .phase = phase,
        .sample_sequence = sample_sequence,
        .metric = metric,
        .plane = try metricPlaneV1(metric),
        .availability = availability,
        .unit = try metricUnitV1(metric),
        .value = value,
        .observed_at_ticks = observed_at_ticks,
        .sample_clock_domain_sha256 = sample_clock_domain_sha256,
        .value_clock_domain_sha256 = value_clock_domain_sha256,
        .source_sha256 = source_sha256,
        .provenance_sha256 = provenance_sha256,
        .subject_sha256 = subject_sha256,
        .reason_sha256 = reason_sha256,
    };
    result.observation_sha256 = observationSha256V1(result);
    try validateObservationV1(descriptor, plan, result);
    return result;
}

pub fn observationSha256V1(value: ObservationV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(observation_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.run_sha256);
    hash.update(&value.descriptor_sha256);
    hashU64(&hash, @intFromEnum(value.phase));
    hashU64(&hash, value.sample_sequence);
    hashU64(&hash, @intFromEnum(value.metric));
    hashU64(&hash, @intFromEnum(value.plane));
    hashU64(&hash, @intFromEnum(value.availability));
    hashU64(&hash, @intFromEnum(value.unit));
    hashI64(&hash, value.value);
    hashU64(&hash, value.observed_at_ticks);
    hash.update(&value.sample_clock_domain_sha256);
    hash.update(&value.value_clock_domain_sha256);
    hash.update(&value.source_sha256);
    hash.update(&value.provenance_sha256);
    hash.update(&value.subject_sha256);
    hash.update(&value.reason_sha256);
    return finish(&hash);
}

pub fn validateObservationV1(
    descriptor: DescriptorV1,
    plan: PlanV1,
    value: ObservationV1,
) Error!void {
    try validatePlanV1(descriptor, plan);
    const bit = metricBitV1(value.metric) catch
        return Error.InvalidObservation;
    const expected_plane = metricPlaneV1(value.metric) catch
        return Error.InvalidObservation;
    const expected_unit = metricUnitV1(value.metric) catch
        return Error.InvalidObservation;
    if (value.abi_version != observation_abi or
        !digestEqual(value.run_sha256, plan.run_sha256) or
        !digestEqual(
            value.descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        value.phase == .unused or
        value.sample_sequence == 0 or
        value.plane != expected_plane or
        value.availability == .unused or
        value.unit != expected_unit or
        descriptor.declared_metric_bits & bit == 0 or
        (value.availability != .present and value.value != 0) or
        (value.availability == .present and
            !metricValueInDomainV1(value.metric, value.value)) or
        value.observed_at_ticks == 0 or
        digestIsZero(value.sample_clock_domain_sha256) or
        digestIsZero(value.source_sha256) or
        digestIsZero(value.provenance_sha256) or
        digestIsZero(value.subject_sha256) or
        (value.availability == .present and
            !digestIsZero(value.reason_sha256)) or
        (value.availability != .present and
            digestIsZero(value.reason_sha256)) or
        !digestEqual(
            value.observation_sha256,
            observationSha256V1(value),
        ))
        return Error.InvalidObservation;
    if (value.unit == .nanoseconds) {
        if (value.availability == .present and
            digestIsZero(value.value_clock_domain_sha256))
            return Error.InvalidObservation;
        if (value.availability != .present and
            !digestIsZero(value.value_clock_domain_sha256))
            return Error.InvalidObservation;
    } else if (!digestIsZero(value.value_clock_domain_sha256)) {
        return Error.InvalidObservation;
    }
    if (value.availability == .present and
        descriptor.direct_metric_bits & bit == 0)
        return Error.InvalidObservation;
    if (value.unit == .boolean and value.availability == .present and
        value.value != 0 and value.value != 1)
        return Error.InvalidObservation;
    if (value.unit == .ppm and value.availability == .present and
        (value.value < 0 or value.value > 1_000_000))
        return Error.InvalidObservation;
}

pub fn makeBundleV1(
    descriptor: DescriptorV1,
    plan: PlanV1,
    phase: PhaseV1,
    records: []const ObservationV1,
) Error!ObservationBundleV1 {
    if (records.len == 0 or records.len > maximum_observations)
        return Error.ObservationLimitExceeded;
    var result: ObservationBundleV1 = .{
        .abi_version = bundle_abi,
        .run_sha256 = plan.run_sha256,
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .phase = phase,
        .record_count = records.len,
    };
    @memcpy(result.records[0..records.len], records);
    result.records_sha256 = observationSectionSha256V1(
        result.records[0..records.len],
    );
    result.bundle_sha256 = bundleSha256V1(result);
    try validateBundleV1(descriptor, plan, result);
    return result;
}

pub fn observationSectionSha256V1(
    records: []const ObservationV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(observation_section_domain);
    hashU64(&hash, records.len);
    for (records) |record| {
        hash.update(&record.observation_sha256);
    }
    return finish(&hash);
}

pub fn bundleSha256V1(value: ObservationBundleV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bundle_domain);
    hashU64(&hash, value.abi_version);
    hash.update(&value.run_sha256);
    hash.update(&value.descriptor_sha256);
    hashU64(&hash, @intFromEnum(value.phase));
    hashU64(&hash, value.record_count);
    hash.update(&value.records_sha256);
    return finish(&hash);
}

pub fn validateBundleV1(
    descriptor: DescriptorV1,
    plan: PlanV1,
    value: ObservationBundleV1,
) Error!void {
    try validatePlanV1(descriptor, plan);
    const count = std.math.cast(
        usize,
        value.record_count,
    ) orelse return Error.InvalidBundle;
    if (value.abi_version != bundle_abi or
        !digestEqual(value.run_sha256, plan.run_sha256) or
        !digestEqual(
            value.descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or
        value.phase == .unused or
        count == 0 or count > maximum_observations)
        return Error.InvalidBundle;

    var previous_metric: u8 = 0;
    for (value.records[0..count], 0..) |record, index| {
        try validateObservationV1(descriptor, plan, record);
        const metric = @intFromEnum(record.metric);
        if (record.phase != value.phase or
            record.sample_sequence != index + 1 or
            metric <= previous_metric)
            return Error.InvalidBundle;
        previous_metric = metric;
    }
    for (value.records[count..]) |record| {
        if (!std.meta.eql(record, ObservationV1{}))
            return Error.InvalidBundle;
    }
    const expected_section = observationSectionSha256V1(
        value.records[0..count],
    );
    if (!digestEqual(value.records_sha256, expected_section) or
        !digestEqual(value.bundle_sha256, bundleSha256V1(value)))
        return Error.InvalidBundle;
}

pub fn findObservationV1(
    bundle: ObservationBundleV1,
    metric: MetricIdV1,
) ?ObservationV1 {
    const count = std.math.cast(usize, bundle.record_count) orelse
        return null;
    if (count > maximum_observations) return null;
    for (bundle.records[0..count]) |record| {
        if (record.metric == metric) return record;
    }
    return null;
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashI64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: i64,
) void {
    hashU64(hash, @bitCast(value));
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn digestV1(value: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}

pub fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

pub fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn portableTypeHasPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| portableTypeHasPointer(info.child),
        .optional => |info| portableTypeHasPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (portableTypeHasPointer(field.type))
                    break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn referenceDescriptorV1() !DescriptorV1 {
    const metrics = [_]MetricIdV1{
        .host_monotonic_time,
        .host_logical_cpu_count,
        .host_external_cpu_ppm,
        .process_resident_bytes,
        .host_available_memory_bytes,
        .host_cpu_power,
        .host_cpu_temperature,
        .accelerator_device_present,
        .accelerator_cpu_fallback,
        .accelerator_utilization,
        .accelerator_resident_bytes,
        .accelerator_power,
        .accelerator_temperature,
        .accelerator_device_time,
    };
    var declared: u64 = 0;
    for (metrics) |metric| declared |= try metricBitV1(metric);
    const direct = declared &
        ~(try metricBitV1(.host_cpu_power)) &
        ~(try metricBitV1(.host_cpu_temperature)) &
        ~(try metricBitV1(.accelerator_utilization)) &
        ~(try metricBitV1(.accelerator_resident_bytes)) &
        ~(try metricBitV1(.accelerator_power)) &
        ~(try metricBitV1(.accelerator_temperature));
    return makeDescriptorV1(
        0x474e_4f52_0000_0001,
        7,
        declared,
        direct,
        digestV1("reference observer namespace"),
        digestV1("reference observer schema"),
    );
}

pub fn referencePlanV1(descriptor: DescriptorV1) !PlanV1 {
    const rules = [_]RuleV1{
        try makeRuleV1(
            .host_monotonic_time,
            .pre_run,
            .require_present,
            0,
            0,
        ),
        try makeRuleV1(
            .host_monotonic_time,
            .post_run,
            .require_present,
            0,
            0,
        ),
        try makeRuleV1(
            .host_logical_cpu_count,
            .pre_run,
            .inclusive_range,
            1,
            4096,
        ),
        try makeRuleV1(
            .host_logical_cpu_count,
            .pre_post,
            .max_abs_delta,
            0,
            0,
        ),
        try makeRuleV1(
            .host_external_cpu_ppm,
            .pre_run,
            .inclusive_range,
            0,
            250_000,
        ),
        try makeRuleV1(
            .host_external_cpu_ppm,
            .post_run,
            .inclusive_range,
            0,
            250_000,
        ),
    };
    return makePlanV1(
        descriptor,
        digestV1("typed perception 3 profiles 6 items"),
        digestV1("download-free retained fixture"),
        digestV1("reference build"),
        digestV1("reference machine"),
        digestV1("reference accelerator backend"),
        digestV1("reference accelerator device"),
        digestV1("reference accelerator placement"),
        .host,
        4,
        3,
        &rules,
        digestV1("reference observation challenge"),
    );
}

test "portable observation values contain no pointers" {
    try std.testing.expect(!portableTypeHasPointer(DescriptorV1));
    try std.testing.expect(!portableTypeHasPointer(RuleV1));
    try std.testing.expect(!portableTypeHasPointer(PlanV1));
    try std.testing.expect(!portableTypeHasPointer(ObservationV1));
    try std.testing.expect(!portableTypeHasPointer(ObservationBundleV1));
}

test "all four availability states are explicit and unavailable is not zero" {
    const descriptor = try referenceDescriptorV1();
    const plan = try referencePlanV1(descriptor);
    const clock = digestV1("host monotonic clock");
    const source = digestV1("observer source");
    const provenance = digestV1("observation provenance");
    const subject = digestV1("host subject");
    const unavailable_reason = digestV1("unavailable reason");
    inline for ([_]AvailabilityV1{
        .present,
        .missing,
        .denied,
        .unsupported,
    }) |availability| {
        const value: i64 = if (availability == .present) 8 else 0;
        const reason = if (availability == .present)
            zero_digest
        else
            unavailable_reason;
        const record = try makeObservationV1(
            descriptor,
            plan,
            .pre_run,
            1,
            .host_logical_cpu_count,
            availability,
            value,
            100,
            clock,
            zero_digest,
            source,
            provenance,
            subject,
            reason,
        );
        try std.testing.expectEqual(availability, record.availability);
    }
    try std.testing.expectError(
        Error.InvalidObservation,
        makeObservationV1(
            descriptor,
            plan,
            .pre_run,
            1,
            .host_logical_cpu_count,
            .missing,
            8,
            100,
            clock,
            zero_digest,
            source,
            provenance,
            subject,
            unavailable_reason,
        ),
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        makeObservationV1(
            descriptor,
            plan,
            .pre_run,
            1,
            .host_monotonic_time,
            .present,
            -1,
            100,
            clock,
            clock,
            source,
            provenance,
            subject,
            zero_digest,
        ),
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        makeObservationV1(
            descriptor,
            plan,
            .pre_run,
            1,
            .host_logical_cpu_count,
            .present,
            0,
            100,
            clock,
            zero_digest,
            source,
            provenance,
            subject,
            zero_digest,
        ),
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        makeObservationV1(
            descriptor,
            plan,
            .pre_run,
            1,
            .host_logical_cpu_count,
            .missing,
            0,
            100,
            clock,
            zero_digest,
            source,
            provenance,
            subject,
            zero_digest,
        ),
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        makeObservationV1(
            descriptor,
            plan,
            .pre_run,
            1,
            .host_logical_cpu_count,
            .present,
            8,
            100,
            clock,
            zero_digest,
            source,
            provenance,
            subject,
            unavailable_reason,
        ),
    );
}

test "metric domains permit physical negative temperature only" {
    const base = try referenceDescriptorV1();
    const descriptor = try makeDescriptorV1(
        base.implementation_abi,
        base.observer_epoch,
        base.declared_metric_bits,
        base.direct_metric_bits |
            (try metricBitV1(.host_cpu_temperature)),
        base.namespace_sha256,
        base.source_schema_sha256,
    );
    const plan = try referencePlanV1(descriptor);
    const clock = digestV1("host clock");
    const source = digestV1("temperature source");
    const provenance = digestV1("temperature provenance");
    const subject = digestV1("host subject");
    _ = try makeObservationV1(
        descriptor,
        plan,
        .pre_run,
        1,
        .host_cpu_temperature,
        .present,
        -10_000,
        100,
        clock,
        zero_digest,
        source,
        provenance,
        subject,
        zero_digest,
    );
    try std.testing.expectError(
        Error.InvalidObservation,
        makeObservationV1(
            descriptor,
            plan,
            .pre_run,
            1,
            .host_cpu_temperature,
            .present,
            -273_151,
            100,
            clock,
            zero_digest,
            source,
            provenance,
            subject,
            zero_digest,
        ),
    );
}

test "bundle rejects semantic substitution and noncanonical tails" {
    const descriptor = try referenceDescriptorV1();
    const plan = try referencePlanV1(descriptor);
    const record = try makeObservationV1(
        descriptor,
        plan,
        .pre_run,
        1,
        .host_monotonic_time,
        .present,
        100,
        100,
        digestV1("host clock"),
        digestV1("host clock"),
        digestV1("host source"),
        digestV1("host provenance"),
        digestV1("host subject"),
        zero_digest,
    );
    var bundle = try makeBundleV1(
        descriptor,
        plan,
        .pre_run,
        &.{record},
    );
    bundle.records[0].subject_sha256 = digestV1("foreign host");
    try std.testing.expectError(
        Error.InvalidObservation,
        validateBundleV1(descriptor, plan, bundle),
    );

    bundle = try makeBundleV1(
        descriptor,
        plan,
        .pre_run,
        &.{record},
    );
    bundle.records[1].abi_version = observation_abi;
    bundle.bundle_sha256 = bundleSha256V1(bundle);
    try std.testing.expectError(
        Error.InvalidBundle,
        validateBundleV1(descriptor, plan, bundle),
    );
}

test "plan rejects reordered rules and unknown metric coverage" {
    const descriptor = try referenceDescriptorV1();
    var invalid_descriptor = descriptor;
    invalid_descriptor.declared_metric_bits |= @as(u64, 1) << 63;
    invalid_descriptor.descriptor_sha256 = descriptorSha256V1(
        invalid_descriptor,
    );
    try std.testing.expectError(
        Error.InvalidDescriptor,
        validateDescriptorV1(invalid_descriptor),
    );

    var plan = try referencePlanV1(descriptor);
    const temporary = plan.rules[0];
    plan.rules[0] = plan.rules[1];
    plan.rules[1] = temporary;
    plan.plan_sha256 = planSha256V1(plan);
    try std.testing.expectError(
        Error.InvalidPlan,
        validatePlanV1(descriptor, plan),
    );

    plan = try referencePlanV1(descriptor);
    plan.rules[2] = try makeRuleV1(
        .host_logical_cpu_count,
        .pre_run,
        .require_present,
        0,
        0,
    );
    plan.plan_sha256 = planSha256V1(plan);
    try std.testing.expectError(
        Error.InvalidPlan,
        validatePlanV1(descriptor, plan),
    );

    var narrowed = descriptor;
    narrowed.declared_metric_bits &=
        ~(try metricBitV1(.accelerator_cpu_fallback));
    narrowed.direct_metric_bits &= narrowed.declared_metric_bits;
    narrowed.descriptor_sha256 = descriptorSha256V1(narrowed);
    try std.testing.expectError(
        Error.InvalidPlan,
        validatePlanV1(narrowed, plan),
    );

    plan = try referencePlanV1(descriptor);
    plan.execution_plane = .accelerator;
    plan.run_sha256 = runSha256V1(plan);
    plan.plan_sha256 = planSha256V1(plan);
    try std.testing.expectError(
        Error.InvalidPlan,
        validatePlanV1(descriptor, plan),
    );
}
