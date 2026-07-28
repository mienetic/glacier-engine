//! Allocation-free segmented native-workload campaign evidence.
//!
//! One manifest has a fixed target size. A checkpoint publishes a non-empty,
//! contiguous prefix of attempt entries and leaves every remaining entry slot
//! all-zero. The footer commits the complete padded body, so a prefix cannot be
//! extended, shortened, reordered, or filled across a gap without changing the
//! manifest identity.
//!
//! Attempt entries retain two independent predecessor chains: every entry
//! advances `previous_attempt_sha256`, while
//! `previous_verified_report_sha256` advances only through verified inner
//! reports. V1 currently admits only verified report entries. Process-local
//! RSS is bounded from the first observation in each process generation;
//! Metal `currentAllocatedSize` is retained separately as allocation context,
//! never as residency.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const manifest_abi: u64 = 0x4757_434d_0000_0001;
pub const attempt_abi: u64 = 0x4757_4345_0000_0001;
pub const selector_abi: u64 = 0x4757_4353_0000_0001;

pub const manifest_header_bytes: usize = 640;
pub const attempt_wire_bytes: usize = 896;
pub const manifest_footer_bytes: usize = 64;
pub const selector_bytes: usize = 192;
pub const selector_body_bytes: usize = selector_bytes - @sizeOf(Digest);
pub const max_segment_count: usize = 1_024;
pub const running_exit_code_bits: u64 = std.math.maxInt(u64);
pub const allowed_manifest_flags: u64 = 0;
pub const allowed_attempt_flags: u64 = 0;
pub const allowed_selector_flags: u64 = 0;

pub const provenance_native_gpu: u64 = 1 << 0;
pub const provenance_controlled_software: u64 = 1 << 1;
pub const provenance_native_host_observation: u64 = 1 << 2;
pub const provenance_derived_synthetic: u64 = 1 << 3;
pub const provenance_planned_graceful_restart: u64 = 1 << 4;
pub const allowed_provenance_bits: u64 =
    provenance_native_gpu |
    provenance_controlled_software |
    provenance_native_host_observation |
    provenance_derived_synthetic |
    provenance_planned_graceful_restart;
pub const base_segment_provenance: u64 =
    provenance_native_gpu |
    provenance_controlled_software |
    provenance_native_host_observation |
    provenance_derived_synthetic;

const plan_domain =
    "glacier-native-workload-campaign-plan-v1\x00";
const campaign_id_domain =
    "glacier-native-workload-campaign-id-v1\x00";
const scheduled_action_domain =
    "glacier-native-workload-campaign-scheduled-action-v1\x00";
const segment_challenge_domain =
    "glacier-native-workload-campaign-segment-challenge-v1\x00";
const attempt_domain =
    "glacier-native-workload-campaign-attempt-entry-v1\x00";
const manifest_body_domain =
    "glacier-native-workload-campaign-manifest-body-v1\x00";
const manifest_footer_domain =
    "glacier-native-workload-campaign-manifest-footer-v1\x00";
const selector_domain =
    "glacier-native-workload-campaign-selector-v1\x00";
const environment_domain =
    "glacier-native-workload-campaign-environment-v1\x00";
const rss_unavailable_domain =
    "glacier-native-workload-campaign-rss-unavailable-v1\x00";
const device_allocation_unavailable_domain =
    "glacier-native-workload-campaign-device-allocation-unavailable-v1\x00";

comptime {
    if (manifest_header_bytes != 32 * @sizeOf(u64) + 12 * @sizeOf(Digest))
        @compileError("campaign manifest header layout drift");
    if (attempt_wire_bytes != 32 * @sizeOf(u64) + 20 * @sizeOf(Digest))
        @compileError("campaign attempt layout drift");
    if (selector_bytes != 8 * @sizeOf(u64) + 4 * @sizeOf(Digest))
        @compileError("campaign selector layout drift");
}

pub const Error = error{
    ArithmeticOverflow,
    CapacityExceeded,
    InvalidAbi,
    InvalidAttempt,
    InvalidChain,
    InvalidEnum,
    InvalidFlags,
    InvalidIdentity,
    InvalidLength,
    InvalidManifest,
    InvalidObservation,
    InvalidPadding,
    InvalidPlan,
    InvalidSelector,
    InvalidStorage,
    InvalidTotals,
    InvalidBodyDigest,
    InvalidFooterDigest,
};

pub const DispositionV1 = enum(u64) {
    verified_report = 1,
};

pub const ScheduledActionV1 = enum(u64) {
    normal_segment = 1,
    graceful_phase_end = 2,
};

pub const AvailabilityV1 = enum(u64) {
    missing = 0,
    denied = 1,
    unsupported = 2,
    present = 3,
};

pub const ObservationKindV1 = enum(u64) {
    process_rss = 1,
    device_allocation_context = 2,
};

/// All fields needed to derive the campaign identity before the first native
/// report exists. Machine, backend, device, and placement are deliberately not
/// part of this seed.
pub const CampaignSeedV1 = struct {
    segment_count: u64,
    restart_after_segment: u64,
    epochs_per_segment: u64,
    records_per_epoch: u64,
    warmup_epochs_per_segment: u64,
    measured_epochs_per_segment: u64,
    completed_per_epoch: u64,
    cancelled_per_epoch: u64,
    failed_per_epoch: u64,
    capacity_per_epoch: u64,
    pins_per_epoch: u64,
    events_per_epoch: u64,
    cadence_ns: u64,
    min_segment_ns: u64,
    max_segment_ns: u64,
    wire_bytes_per_segment: u64,
    artifact_store_max_bytes: u64,
    rss_growth_bound_bytes: u64,
    device_allocation_growth_bound_bytes: u64,
    authority_challenge_sha256: Digest,
    workload_sha256: Digest,
    profile_sha256: Digest,
    artifact_sha256: Digest,
    build_sha256: Digest,
    runner_sha256: Digest,
    metallib_sha256: Digest,
};

pub const PlanConfigV1 = struct {
    seed: CampaignSeedV1,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
};

/// Canonical 640-byte manifest header.
pub const PlanV1 = struct {
    abi_version: u64 = manifest_abi,
    encoded_bytes: u64,
    flags: u64 = allowed_manifest_flags,
    segment_count: u64,
    restart_after_segment: u64,
    epochs_per_segment: u64,
    records_per_epoch: u64,
    warmup_epochs_per_segment: u64,
    measured_epochs_per_segment: u64,
    completed_per_epoch: u64,
    cancelled_per_epoch: u64,
    failed_per_epoch: u64,
    capacity_per_epoch: u64,
    pins_per_epoch: u64,
    events_per_epoch: u64,
    cadence_ns: u64,
    min_segment_ns: u64,
    max_segment_ns: u64,
    wire_bytes_per_segment: u64,
    artifact_store_max_bytes: u64,
    rss_growth_bound_bytes: u64,
    total_epochs: u64,
    total_records: u64,
    total_warmup_records: u64,
    total_measured_records: u64,
    total_completed: u64,
    total_cancelled: u64,
    total_failed: u64,
    total_capacity_rejected: u64,
    total_pin_acquisitions: u64,
    device_allocation_growth_bound_bytes: u64,
    total_events: u64,

    authority_challenge_sha256: Digest,
    workload_sha256: Digest,
    profile_sha256: Digest,
    artifact_sha256: Digest,
    build_sha256: Digest,
    runner_sha256: Digest,
    metallib_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    campaign_id_sha256: Digest,
};

pub const ObservationInputV1 = struct {
    availability: AvailabilityV1,
    before_bytes: u64 = 0,
    max_bytes: u64 = 0,
    after_bytes: u64 = 0,
    source_sha256: Digest,
};

pub const AttemptConfigV1 = struct {
    ordinal: u64,
    duration_ns: u64,
    wire_sha256: Digest,
    report_sha256: Digest,
    scenario_sha256: Digest,
    closure_sha256: Digest,
    host_source_sha256: Digest,
    host_clock_sha256: Digest,
    rss: ObservationInputV1,
    device_allocation: ObservationInputV1,
};

/// Canonical 896-byte attempt entry.
pub const AttemptV1 = struct {
    abi_version: u64 = attempt_abi,
    ordinal: u64,
    process_generation: u64,
    disposition: DispositionV1 = .verified_report,
    provenance_bits: u64,
    epoch_count: u64,
    record_count: u64,
    warmup_record_count: u64,
    measured_record_count: u64,
    completed_count: u64,
    cancelled_count: u64,
    failed_count: u64,
    capacity_rejected_count: u64,
    pin_acquisitions: u64,
    pin_completions: u64,
    event_count: u64,
    report_wire_bytes: u64,
    duration_ns: u64,
    cumulative_duration_ns: u64,
    cumulative_records: u64,
    cumulative_completed: u64,
    rss_availability: AvailabilityV1,
    rss_before_bytes: u64,
    rss_max_bytes: u64,
    rss_after_bytes: u64,
    device_allocation_availability: AvailabilityV1,
    device_allocation_before_bytes: u64,
    device_allocation_max_bytes: u64,
    device_allocation_after_bytes: u64,
    exit_code_bits: u64,
    termination_signal: u64,
    reserved: u64 = 0,

    scheduled_action_sha256: Digest,
    segment_challenge_sha256: Digest,
    previous_attempt_sha256: Digest,
    previous_verified_report_sha256: Digest,
    wire_sha256: Digest,
    report_sha256: Digest,
    scenario_sha256: Digest,
    closure_sha256: Digest,
    build_sha256: Digest,
    machine_sha256: Digest,
    backend_sha256: Digest,
    device_sha256: Digest,
    placement_sha256: Digest,
    host_source_sha256: Digest,
    host_clock_sha256: Digest,
    rss_source_sha256: Digest,
    rss_reason_sha256: Digest,
    device_allocation_source_sha256: Digest,
    device_allocation_reason_sha256: Digest,
    attempt_sha256: Digest,
};

pub const ManifestV1 = struct {
    plan: PlanV1,
    attempts: []const AttemptV1,

    pub fn complete(self: ManifestV1) bool {
        return self.attempts.len == self.plan.segment_count;
    }
};

pub const EncodedManifestV1 = struct {
    bytes: []const u8,
    manifest_body_sha256: Digest,
    manifest_footer_sha256: Digest,
};

pub const DecodedManifestV1 = struct {
    manifest: ManifestV1,
    encoded: []const u8,
    manifest_body_sha256: Digest,
    manifest_footer_sha256: Digest,
};

pub const SelectorV1 = struct {
    abi_version: u64 = selector_abi,
    bytes: u64 = selector_bytes,
    flags: u64 = allowed_selector_flags,
    generation: u64,
    segment_count: u64,
    total_records: u64,
    total_completed: u64,
    total_events: u64,
    authority_challenge_sha256: Digest,
    /// Root of the complete manifest footer, not the intermediate body root.
    manifest_sha256: Digest,
    environment_sha256: Digest,
    selector_sha256: Digest,
};

pub fn digestV1(bytes: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &result, .{});
    return result;
}

pub fn manifestEncodedBytesV1(segment_count: u64) Error!usize {
    if (segment_count == 0 or segment_count > max_segment_count)
        return Error.CapacityExceeded;
    const count = std.math.cast(usize, segment_count) orelse
        return Error.ArithmeticOverflow;
    const entries_bytes = std.math.mul(
        usize,
        count,
        attempt_wire_bytes,
    ) catch return Error.ArithmeticOverflow;
    const body_bytes = std.math.add(
        usize,
        manifest_header_bytes,
        entries_bytes,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        body_bytes,
        manifest_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn campaignIdV1(seed: CampaignSeedV1) Error!Digest {
    const plan = try derivePlanV1(.{
        .seed = seed,
        .machine_sha256 = zero_digest,
        .backend_sha256 = zero_digest,
        .device_sha256 = zero_digest,
        .placement_sha256 = zero_digest,
    }, false);
    return campaignIdForPlanV1(plan);
}

pub fn makePlanV1(config: PlanConfigV1) Error!PlanV1 {
    return derivePlanV1(config, true);
}

pub fn validatePlanV1(plan: PlanV1) Error!void {
    const expected = try derivePlanV1(.{
        .seed = seedFromPlanV1(plan),
        .machine_sha256 = plan.machine_sha256,
        .backend_sha256 = plan.backend_sha256,
        .device_sha256 = plan.device_sha256,
        .placement_sha256 = plan.placement_sha256,
    }, true);
    if (!std.meta.eql(plan, expected)) return Error.InvalidPlan;
}

fn derivePlanV1(
    config: PlanConfigV1,
    require_dynamic_identities: bool,
) Error!PlanV1 {
    const seed = config.seed;
    if (seed.segment_count == 0 or
        seed.segment_count > max_segment_count or
        (seed.restart_after_segment != 0 and
            seed.restart_after_segment >= seed.segment_count) or
        seed.epochs_per_segment == 0 or
        seed.records_per_epoch == 0 or
        seed.measured_epochs_per_segment == 0 or
        try addU64(
            seed.warmup_epochs_per_segment,
            seed.measured_epochs_per_segment,
        ) != seed.epochs_per_segment or
        seed.completed_per_epoch == 0 or
        try addU64(
            try addU64(
                seed.completed_per_epoch,
                seed.cancelled_per_epoch,
            ),
            try addU64(
                seed.failed_per_epoch,
                seed.capacity_per_epoch,
            ),
        ) != seed.records_per_epoch or
        seed.pins_per_epoch == 0 or
        seed.events_per_epoch == 0 or
        seed.cadence_ns == 0 or
        seed.min_segment_ns == 0 or
        seed.max_segment_ns < seed.min_segment_ns or
        try mulU64(
            seed.epochs_per_segment,
            seed.cadence_ns,
        ) != seed.min_segment_ns or
        seed.wire_bytes_per_segment == 0 or
        seed.artifact_store_max_bytes == 0 or
        seed.rss_growth_bound_bytes == 0 or
        seed.device_allocation_growth_bound_bytes == 0)
        return Error.InvalidPlan;

    inline for (immutableSeedDigests(seed)) |value| {
        if (digestIsZero(value)) return Error.InvalidIdentity;
    }
    if (require_dynamic_identities) {
        inline for ([_]Digest{
            config.machine_sha256,
            config.backend_sha256,
            config.device_sha256,
            config.placement_sha256,
        }) |value| {
            if (digestIsZero(value)) return Error.InvalidIdentity;
        }
    }

    const encoded_bytes = try manifestEncodedBytesV1(seed.segment_count);
    const total_epochs =
        try mulU64(seed.segment_count, seed.epochs_per_segment);
    const records_per_segment =
        try mulU64(seed.epochs_per_segment, seed.records_per_epoch);
    const total_records =
        try mulU64(seed.segment_count, records_per_segment);
    const warmup_per_segment = try mulU64(
        seed.warmup_epochs_per_segment,
        seed.records_per_epoch,
    );
    const measured_per_segment = try mulU64(
        seed.measured_epochs_per_segment,
        seed.records_per_epoch,
    );
    const total_warmup =
        try mulU64(seed.segment_count, warmup_per_segment);
    const total_measured =
        try mulU64(seed.segment_count, measured_per_segment);
    if (try addU64(total_warmup, total_measured) != total_records)
        return Error.InvalidTotals;

    const total_completed = try mulU64(
        total_epochs,
        seed.completed_per_epoch,
    );
    const total_cancelled = try mulU64(
        total_epochs,
        seed.cancelled_per_epoch,
    );
    const total_failed =
        try mulU64(total_epochs, seed.failed_per_epoch);
    const total_capacity =
        try mulU64(total_epochs, seed.capacity_per_epoch);
    if (try addU64(
        try addU64(total_completed, total_cancelled),
        try addU64(total_failed, total_capacity),
    ) != total_records) return Error.InvalidTotals;
    const total_pins =
        try mulU64(total_epochs, seed.pins_per_epoch);
    const total_events =
        try mulU64(total_epochs, seed.events_per_epoch);

    const retained_wire_bytes = try mulU64(
        seed.segment_count,
        seed.wire_bytes_per_segment,
    );
    const minimum_store_bytes = try addU64(
        retained_wire_bytes,
        try addU64(
            std.math.cast(u64, encoded_bytes) orelse
                return Error.ArithmeticOverflow,
            selector_bytes,
        ),
    );
    if (seed.artifact_store_max_bytes < minimum_store_bytes)
        return Error.InvalidPlan;

    var plan: PlanV1 = .{
        .encoded_bytes = std.math.cast(u64, encoded_bytes) orelse
            return Error.ArithmeticOverflow,
        .segment_count = seed.segment_count,
        .restart_after_segment = seed.restart_after_segment,
        .epochs_per_segment = seed.epochs_per_segment,
        .records_per_epoch = seed.records_per_epoch,
        .warmup_epochs_per_segment = seed.warmup_epochs_per_segment,
        .measured_epochs_per_segment = seed.measured_epochs_per_segment,
        .completed_per_epoch = seed.completed_per_epoch,
        .cancelled_per_epoch = seed.cancelled_per_epoch,
        .failed_per_epoch = seed.failed_per_epoch,
        .capacity_per_epoch = seed.capacity_per_epoch,
        .pins_per_epoch = seed.pins_per_epoch,
        .events_per_epoch = seed.events_per_epoch,
        .cadence_ns = seed.cadence_ns,
        .min_segment_ns = seed.min_segment_ns,
        .max_segment_ns = seed.max_segment_ns,
        .wire_bytes_per_segment = seed.wire_bytes_per_segment,
        .artifact_store_max_bytes = seed.artifact_store_max_bytes,
        .rss_growth_bound_bytes = seed.rss_growth_bound_bytes,
        .total_epochs = total_epochs,
        .total_records = total_records,
        .total_warmup_records = total_warmup,
        .total_measured_records = total_measured,
        .total_completed = total_completed,
        .total_cancelled = total_cancelled,
        .total_failed = total_failed,
        .total_capacity_rejected = total_capacity,
        .total_pin_acquisitions = total_pins,
        .device_allocation_growth_bound_bytes = seed.device_allocation_growth_bound_bytes,
        .total_events = total_events,
        .authority_challenge_sha256 = seed.authority_challenge_sha256,
        .workload_sha256 = seed.workload_sha256,
        .profile_sha256 = seed.profile_sha256,
        .artifact_sha256 = seed.artifact_sha256,
        .build_sha256 = seed.build_sha256,
        .runner_sha256 = seed.runner_sha256,
        .metallib_sha256 = seed.metallib_sha256,
        .machine_sha256 = config.machine_sha256,
        .backend_sha256 = config.backend_sha256,
        .device_sha256 = config.device_sha256,
        .placement_sha256 = config.placement_sha256,
        .campaign_id_sha256 = zero_digest,
    };
    plan.campaign_id_sha256 = campaignIdForPlanV1(plan);
    return plan;
}

fn seedFromPlanV1(plan: PlanV1) CampaignSeedV1 {
    return .{
        .segment_count = plan.segment_count,
        .restart_after_segment = plan.restart_after_segment,
        .epochs_per_segment = plan.epochs_per_segment,
        .records_per_epoch = plan.records_per_epoch,
        .warmup_epochs_per_segment = plan.warmup_epochs_per_segment,
        .measured_epochs_per_segment = plan.measured_epochs_per_segment,
        .completed_per_epoch = plan.completed_per_epoch,
        .cancelled_per_epoch = plan.cancelled_per_epoch,
        .failed_per_epoch = plan.failed_per_epoch,
        .capacity_per_epoch = plan.capacity_per_epoch,
        .pins_per_epoch = plan.pins_per_epoch,
        .events_per_epoch = plan.events_per_epoch,
        .cadence_ns = plan.cadence_ns,
        .min_segment_ns = plan.min_segment_ns,
        .max_segment_ns = plan.max_segment_ns,
        .wire_bytes_per_segment = plan.wire_bytes_per_segment,
        .artifact_store_max_bytes = plan.artifact_store_max_bytes,
        .rss_growth_bound_bytes = plan.rss_growth_bound_bytes,
        .device_allocation_growth_bound_bytes = plan.device_allocation_growth_bound_bytes,
        .authority_challenge_sha256 = plan.authority_challenge_sha256,
        .workload_sha256 = plan.workload_sha256,
        .profile_sha256 = plan.profile_sha256,
        .artifact_sha256 = plan.artifact_sha256,
        .build_sha256 = plan.build_sha256,
        .runner_sha256 = plan.runner_sha256,
        .metallib_sha256 = plan.metallib_sha256,
    };
}

fn immutableSeedDigests(seed: CampaignSeedV1) [7]Digest {
    return .{
        seed.authority_challenge_sha256,
        seed.workload_sha256,
        seed.profile_sha256,
        seed.artifact_sha256,
        seed.build_sha256,
        seed.runner_sha256,
        seed.metallib_sha256,
    };
}

fn campaignIdForPlanV1(plan: PlanV1) Digest {
    var plan_hash = std.crypto.hash.sha2.Sha256.init(.{});
    plan_hash.update(plan_domain);
    for (planScalarsV1(plan)) |value| hashU64(&plan_hash, value);
    const digests = planDigestsV1(plan);
    for (digests[0..7]) |value| plan_hash.update(&value);
    const plan_root = finishHash(&plan_hash);

    var campaign_hash = std.crypto.hash.sha2.Sha256.init(.{});
    campaign_hash.update(campaign_id_domain);
    campaign_hash.update(&plan_root);
    return finishHash(&campaign_hash);
}

pub fn scheduledActionSha256V1(
    plan: PlanV1,
    ordinal: u64,
    process_generation: u64,
    rss_source_sha256: Digest,
) Error!Digest {
    try validatePlanV1(plan);
    if (ordinal >= plan.segment_count or process_generation == 0 or
        digestIsZero(rss_source_sha256))
        return Error.InvalidAttempt;
    const action = scheduledActionV1(plan, ordinal);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(scheduled_action_domain);
    hash.update(&plan.campaign_id_sha256);
    hash.update(&plan.profile_sha256);
    hashU64(&hash, ordinal);
    hashU64(&hash, process_generation);
    hashU64(&hash, @intFromEnum(action));
    hash.update(&rss_source_sha256);
    return finishHash(&hash);
}

pub fn segmentChallengeSha256V1(
    campaign_id_sha256: Digest,
    ordinal: u64,
    process_generation: u64,
    previous_attempt_sha256: Digest,
    previous_verified_report_sha256: Digest,
    scheduled_action_sha256: Digest,
) Error!Digest {
    if (digestIsZero(campaign_id_sha256) or
        process_generation == 0 or
        digestIsZero(scheduled_action_sha256))
        return Error.InvalidIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(segment_challenge_domain);
    hash.update(&campaign_id_sha256);
    hashU64(&hash, ordinal);
    hashU64(&hash, process_generation);
    hash.update(&previous_attempt_sha256);
    hash.update(&previous_verified_report_sha256);
    hash.update(&scheduled_action_sha256);
    return finishHash(&hash);
}

pub fn unavailableReasonSha256V1(
    kind: ObservationKindV1,
    campaign_id_sha256: Digest,
    ordinal: u64,
    availability: AvailabilityV1,
    source_sha256: Digest,
) Error!Digest {
    if (availability == .present or
        digestIsZero(campaign_id_sha256) or
        digestIsZero(source_sha256))
        return Error.InvalidObservation;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(switch (kind) {
        .process_rss => rss_unavailable_domain,
        .device_allocation_context => device_allocation_unavailable_domain,
    });
    hash.update(&campaign_id_sha256);
    hashU64(&hash, ordinal);
    hashU64(&hash, @intFromEnum(availability));
    hash.update(&source_sha256);
    return finishHash(&hash);
}

pub fn makeAttemptV1(
    plan: PlanV1,
    previous: ?*const AttemptV1,
    config: AttemptConfigV1,
) Error!AttemptV1 {
    try validatePlanV1(plan);
    if (config.ordinal >= plan.segment_count or
        config.duration_ns < plan.min_segment_ns or
        config.duration_ns > plan.max_segment_ns)
        return Error.InvalidAttempt;
    inline for ([_]Digest{
        config.wire_sha256,
        config.report_sha256,
        config.scenario_sha256,
        config.closure_sha256,
        config.host_source_sha256,
        config.host_clock_sha256,
    }) |value| {
        if (digestIsZero(value)) return Error.InvalidIdentity;
    }
    try validateObservationInputV1(.process_rss, config.rss);
    try validateObservationInputV1(
        .device_allocation_context,
        config.device_allocation,
    );

    const previous_attempt = if (previous) |value| blk: {
        if (config.ordinal == 0 or
            value.ordinal + 1 != config.ordinal)
            return Error.InvalidChain;
        break :blk value.attempt_sha256;
    } else blk: {
        if (config.ordinal != 0) return Error.InvalidChain;
        break :blk zero_digest;
    };
    const previous_report = if (previous) |value|
        value.report_sha256
    else
        zero_digest;
    const process_generation = processGenerationV1(
        plan,
        config.ordinal,
    );
    const phase_end = isPhaseEndV1(plan, config.ordinal);
    const actual_restart =
        phase_end and config.ordinal + 1 < plan.segment_count;
    const provenance = base_segment_provenance |
        (if (actual_restart)
            provenance_planned_graceful_restart
        else
            0);
    const record_count =
        try mulU64(plan.epochs_per_segment, plan.records_per_epoch);
    const warmup_count = try mulU64(
        plan.warmup_epochs_per_segment,
        plan.records_per_epoch,
    );
    const measured_count = try mulU64(
        plan.measured_epochs_per_segment,
        plan.records_per_epoch,
    );
    const completed_count =
        try mulU64(plan.epochs_per_segment, plan.completed_per_epoch);
    const cancelled_count =
        try mulU64(plan.epochs_per_segment, plan.cancelled_per_epoch);
    const failed_count =
        try mulU64(plan.epochs_per_segment, plan.failed_per_epoch);
    const capacity_count =
        try mulU64(plan.epochs_per_segment, plan.capacity_per_epoch);
    const pins =
        try mulU64(plan.epochs_per_segment, plan.pins_per_epoch);
    const events =
        try mulU64(plan.epochs_per_segment, plan.events_per_epoch);

    const cumulative_duration = if (previous) |value|
        try addU64(value.cumulative_duration_ns, config.duration_ns)
    else
        config.duration_ns;
    const cumulative_records = if (previous) |value|
        try addU64(value.cumulative_records, record_count)
    else
        record_count;
    const cumulative_completed = if (previous) |value|
        try addU64(value.cumulative_completed, completed_count)
    else
        completed_count;

    const scheduled_action = try scheduledActionSha256V1(
        plan,
        config.ordinal,
        process_generation,
        config.rss.source_sha256,
    );
    const challenge = try segmentChallengeSha256V1(
        plan.campaign_id_sha256,
        config.ordinal,
        process_generation,
        previous_attempt,
        previous_report,
        scheduled_action,
    );
    var result: AttemptV1 = .{
        .ordinal = config.ordinal,
        .process_generation = process_generation,
        .provenance_bits = provenance,
        .epoch_count = plan.epochs_per_segment,
        .record_count = record_count,
        .warmup_record_count = warmup_count,
        .measured_record_count = measured_count,
        .completed_count = completed_count,
        .cancelled_count = cancelled_count,
        .failed_count = failed_count,
        .capacity_rejected_count = capacity_count,
        .pin_acquisitions = pins,
        .pin_completions = pins,
        .event_count = events,
        .report_wire_bytes = plan.wire_bytes_per_segment,
        .duration_ns = config.duration_ns,
        .cumulative_duration_ns = cumulative_duration,
        .cumulative_records = cumulative_records,
        .cumulative_completed = cumulative_completed,
        .rss_availability = config.rss.availability,
        .rss_before_bytes = config.rss.before_bytes,
        .rss_max_bytes = config.rss.max_bytes,
        .rss_after_bytes = config.rss.after_bytes,
        .device_allocation_availability = config.device_allocation.availability,
        .device_allocation_before_bytes = config.device_allocation.before_bytes,
        .device_allocation_max_bytes = config.device_allocation.max_bytes,
        .device_allocation_after_bytes = config.device_allocation.after_bytes,
        .exit_code_bits = if (phase_end) 0 else running_exit_code_bits,
        .termination_signal = 0,
        .scheduled_action_sha256 = scheduled_action,
        .segment_challenge_sha256 = challenge,
        .previous_attempt_sha256 = previous_attempt,
        .previous_verified_report_sha256 = previous_report,
        .wire_sha256 = config.wire_sha256,
        .report_sha256 = config.report_sha256,
        .scenario_sha256 = config.scenario_sha256,
        .closure_sha256 = config.closure_sha256,
        .build_sha256 = plan.build_sha256,
        .machine_sha256 = plan.machine_sha256,
        .backend_sha256 = plan.backend_sha256,
        .device_sha256 = plan.device_sha256,
        .placement_sha256 = plan.placement_sha256,
        .host_source_sha256 = config.host_source_sha256,
        .host_clock_sha256 = config.host_clock_sha256,
        .rss_source_sha256 = config.rss.source_sha256,
        .rss_reason_sha256 = try observationReasonV1(
            .process_rss,
            plan.campaign_id_sha256,
            config.ordinal,
            config.rss,
        ),
        .device_allocation_source_sha256 = config.device_allocation.source_sha256,
        .device_allocation_reason_sha256 = try observationReasonV1(
            .device_allocation_context,
            plan.campaign_id_sha256,
            config.ordinal,
            config.device_allocation,
        ),
        .attempt_sha256 = zero_digest,
    };
    result.attempt_sha256 = try attemptSha256V1(
        plan.campaign_id_sha256,
        result,
    );
    return result;
}

pub fn validateAttemptV1(
    plan: PlanV1,
    previous: ?*const AttemptV1,
    value: AttemptV1,
) Error!void {
    const expected = try makeAttemptV1(plan, previous, .{
        .ordinal = value.ordinal,
        .duration_ns = value.duration_ns,
        .wire_sha256 = value.wire_sha256,
        .report_sha256 = value.report_sha256,
        .scenario_sha256 = value.scenario_sha256,
        .closure_sha256 = value.closure_sha256,
        .host_source_sha256 = value.host_source_sha256,
        .host_clock_sha256 = value.host_clock_sha256,
        .rss = .{
            .availability = value.rss_availability,
            .before_bytes = value.rss_before_bytes,
            .max_bytes = value.rss_max_bytes,
            .after_bytes = value.rss_after_bytes,
            .source_sha256 = value.rss_source_sha256,
        },
        .device_allocation = .{
            .availability = value.device_allocation_availability,
            .before_bytes = value.device_allocation_before_bytes,
            .max_bytes = value.device_allocation_max_bytes,
            .after_bytes = value.device_allocation_after_bytes,
            .source_sha256 = value.device_allocation_source_sha256,
        },
    });
    if (!std.meta.eql(value, expected)) return Error.InvalidAttempt;
}

fn validateObservationInputV1(
    kind: ObservationKindV1,
    value: ObservationInputV1,
) Error!void {
    _ = kind;
    if (digestIsZero(value.source_sha256))
        return Error.InvalidObservation;
    switch (value.availability) {
        .present => {
            if (value.before_bytes == 0 or value.max_bytes == 0 or
                value.after_bytes == 0 or
                value.max_bytes < value.before_bytes or
                value.max_bytes < value.after_bytes)
                return Error.InvalidObservation;
        },
        .missing, .denied, .unsupported => {
            if (value.before_bytes != 0 or value.max_bytes != 0 or
                value.after_bytes != 0)
                return Error.InvalidObservation;
        },
    }
}

fn observationReasonV1(
    kind: ObservationKindV1,
    campaign_id_sha256: Digest,
    ordinal: u64,
    value: ObservationInputV1,
) Error!Digest {
    try validateObservationInputV1(kind, value);
    return if (value.availability == .present)
        zero_digest
    else
        try unavailableReasonSha256V1(
            kind,
            campaign_id_sha256,
            ordinal,
            value.availability,
            value.source_sha256,
        );
}

fn scheduledActionV1(
    plan: PlanV1,
    ordinal: u64,
) ScheduledActionV1 {
    return if (isPhaseEndV1(plan, ordinal))
        .graceful_phase_end
    else
        .normal_segment;
}

fn isPhaseEndV1(plan: PlanV1, ordinal: u64) bool {
    return isRestartBoundaryV1(plan, ordinal) or
        ordinal + 1 == plan.segment_count;
}

fn isRestartBoundaryV1(plan: PlanV1, ordinal: u64) bool {
    return plan.restart_after_segment != 0 and
        ordinal + 1 == plan.restart_after_segment;
}

fn processGenerationV1(plan: PlanV1, ordinal: u64) u64 {
    return if (plan.restart_after_segment == 0 or
        ordinal < plan.restart_after_segment)
        1
    else
        2;
}

pub fn attemptSha256V1(
    campaign_id_sha256: Digest,
    value: AttemptV1,
) Error!Digest {
    if (digestIsZero(campaign_id_sha256))
        return Error.InvalidIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(attempt_domain);
    hash.update(&campaign_id_sha256);
    for (attemptScalarsV1(value)) |field| hashU64(&hash, field);
    const digests = attemptDigestsV1(value);
    for (digests[0..19]) |field| hash.update(&field);
    return finishHash(&hash);
}

pub fn makeManifestV1(
    plan: PlanV1,
    attempts: []const AttemptV1,
) Error!ManifestV1 {
    const value: ManifestV1 = .{
        .plan = plan,
        .attempts = attempts,
    };
    try validateManifestV1(value);
    return value;
}

pub fn validateManifestV1(value: ManifestV1) Error!void {
    try validatePlanV1(value.plan);
    if (value.attempts.len == 0 or
        value.attempts.len > value.plan.segment_count)
        return Error.InvalidManifest;

    var total_cancelled: u64 = 0;
    var total_failed: u64 = 0;
    var total_capacity: u64 = 0;
    var total_pins_acquired: u64 = 0;
    var total_pins_completed: u64 = 0;
    var total_events: u64 = 0;
    var phase_rss_baseline: u64 = 0;
    var phase_device_baseline: u64 = 0;
    var phase_rss_source: Digest = zero_digest;
    var first_host_source: Digest = zero_digest;
    var first_host_clock: Digest = zero_digest;
    var first_device_source: Digest = zero_digest;
    var previous: ?*const AttemptV1 = null;

    for (value.attempts, 0..) |*attempt, index| {
        try validateAttemptV1(value.plan, previous, attempt.*);
        if (attempt.ordinal != index) return Error.InvalidChain;
        for (value.attempts[0..index]) |prior| {
            if (digestEqual(
                attempt.scheduled_action_sha256,
                prior.scheduled_action_sha256,
            ) or digestEqual(
                attempt.segment_challenge_sha256,
                prior.segment_challenge_sha256,
            ) or digestEqual(
                attempt.wire_sha256,
                prior.wire_sha256,
            ) or digestEqual(
                attempt.report_sha256,
                prior.report_sha256,
            ) or digestEqual(
                attempt.scenario_sha256,
                prior.scenario_sha256,
            ) or digestEqual(
                attempt.attempt_sha256,
                prior.attempt_sha256,
            )) return Error.InvalidIdentity;
        }
        if (index == 0) {
            first_host_source = attempt.host_source_sha256;
            first_host_clock = attempt.host_clock_sha256;
            first_device_source =
                attempt.device_allocation_source_sha256;
        } else if (!digestEqual(
            attempt.host_source_sha256,
            first_host_source,
        ) or !digestEqual(
            attempt.host_clock_sha256,
            first_host_clock,
        ) or !digestEqual(
            attempt.device_allocation_source_sha256,
            first_device_source,
        )) return Error.InvalidIdentity;

        const phase_start = index == 0 or
            (value.plan.restart_after_segment != 0 and
                attempt.ordinal == value.plan.restart_after_segment);
        if (phase_start) {
            if (!digestIsZero(phase_rss_source) and digestEqual(
                phase_rss_source,
                attempt.rss_source_sha256,
            )) return Error.InvalidIdentity;
            phase_rss_source = attempt.rss_source_sha256;
            phase_rss_baseline = 0;
            phase_device_baseline = 0;
        } else if (!digestEqual(
            phase_rss_source,
            attempt.rss_source_sha256,
        )) return Error.InvalidIdentity;

        if (attempt.rss_availability == .present and
            phase_rss_baseline == 0)
            phase_rss_baseline = attempt.rss_before_bytes;
        if (attempt.device_allocation_availability == .present and
            phase_device_baseline == 0)
            phase_device_baseline =
                attempt.device_allocation_before_bytes;
        try validatePhaseBoundV1(
            attempt.rss_availability,
            phase_rss_baseline,
            value.plan.rss_growth_bound_bytes,
            attempt.rss_before_bytes,
            attempt.rss_max_bytes,
            attempt.rss_after_bytes,
        );
        try validatePhaseBoundV1(
            attempt.device_allocation_availability,
            phase_device_baseline,
            value.plan.device_allocation_growth_bound_bytes,
            attempt.device_allocation_before_bytes,
            attempt.device_allocation_max_bytes,
            attempt.device_allocation_after_bytes,
        );

        total_cancelled =
            try addU64(total_cancelled, attempt.cancelled_count);
        total_failed = try addU64(total_failed, attempt.failed_count);
        total_capacity = try addU64(
            total_capacity,
            attempt.capacity_rejected_count,
        );
        total_pins_acquired = try addU64(
            total_pins_acquired,
            attempt.pin_acquisitions,
        );
        total_pins_completed = try addU64(
            total_pins_completed,
            attempt.pin_completions,
        );
        total_events = try addU64(total_events, attempt.event_count);
        previous = attempt;
    }

    if (total_pins_acquired != total_pins_completed)
        return Error.InvalidTotals;
    const count: u64 = @intCast(value.attempts.len);
    const expected_epochs =
        try mulU64(count, value.plan.epochs_per_segment);
    if (value.attempts[value.attempts.len - 1].cumulative_records !=
        try mulU64(expected_epochs, value.plan.records_per_epoch) or
        value.attempts[value.attempts.len - 1].cumulative_completed !=
            try mulU64(expected_epochs, value.plan.completed_per_epoch) or
        total_cancelled !=
            try mulU64(expected_epochs, value.plan.cancelled_per_epoch) or
        total_failed !=
            try mulU64(expected_epochs, value.plan.failed_per_epoch) or
        total_capacity !=
            try mulU64(expected_epochs, value.plan.capacity_per_epoch) or
        total_pins_acquired !=
            try mulU64(expected_epochs, value.plan.pins_per_epoch) or
        total_events !=
            try mulU64(expected_epochs, value.plan.events_per_epoch))
        return Error.InvalidTotals;

    if (value.complete() and
        (value.attempts[value.attempts.len - 1].cumulative_records !=
            value.plan.total_records or
            value.attempts[value.attempts.len - 1].cumulative_completed !=
                value.plan.total_completed or
            total_cancelled != value.plan.total_cancelled or
            total_failed != value.plan.total_failed or
            total_capacity != value.plan.total_capacity_rejected or
            total_pins_acquired != value.plan.total_pin_acquisitions or
            total_events != value.plan.total_events))
        return Error.InvalidTotals;
}

fn validatePhaseBoundV1(
    availability: AvailabilityV1,
    baseline: u64,
    growth_bound: u64,
    before: u64,
    maximum: u64,
    after: u64,
) Error!void {
    if (availability != .present) {
        if (before != 0 or maximum != 0 or after != 0)
            return Error.InvalidObservation;
        return;
    }
    if (baseline == 0) return Error.InvalidObservation;
    const ceiling = try addU64(baseline, growth_bound);
    if (before > ceiling or maximum > ceiling or after > ceiling)
        return Error.InvalidObservation;
}

pub fn encodeManifestV1(
    value: ManifestV1,
    destination: []u8,
) Error!EncodedManifestV1 {
    try validateManifestV1(value);
    const required = std.math.cast(
        usize,
        value.plan.encoded_bytes,
    ) orelse return Error.ArithmeticOverflow;
    if (destination.len < required) return Error.CapacityExceeded;
    const output = destination[0..required];
    if (slicesOverlap(
        u8,
        output,
        AttemptV1,
        value.attempts,
    )) return Error.InvalidStorage;

    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    try writePlanV1(&writer, value.plan);
    if (writer.position != manifest_header_bytes)
        return Error.InvalidLength;
    for (value.attempts) |attempt| {
        try writeAttemptV1(&writer, attempt);
    }
    const body_end = output.len - manifest_footer_bytes;
    if (writer.position > body_end) return Error.InvalidLength;
    // The untouched suffix is the canonical zero-padded future entry table.
    writer.position = body_end;
    const body_root = domainHash(
        manifest_body_domain,
        output[0..body_end],
    );
    try writer.writeDigest(body_root);
    const footer_root = domainHash(
        manifest_footer_domain,
        output[0..writer.position],
    );
    try writer.writeDigest(footer_root);
    if (writer.position != output.len) return Error.InvalidLength;
    return .{
        .bytes = output,
        .manifest_body_sha256 = body_root,
        .manifest_footer_sha256 = footer_root,
    };
}

pub fn decodeManifestV1(
    encoded: []const u8,
    attempt_storage: []AttemptV1,
) Error!DecodedManifestV1 {
    if (encoded.len < manifest_header_bytes + attempt_wire_bytes +
        manifest_footer_bytes)
        return Error.InvalidLength;
    const entry_area_bytes =
        encoded.len - manifest_header_bytes - manifest_footer_bytes;
    if (entry_area_bytes % attempt_wire_bytes != 0)
        return Error.InvalidLength;
    const slot_count = entry_area_bytes / attempt_wire_bytes;
    if (slot_count == 0 or slot_count > max_segment_count)
        return Error.InvalidLength;
    if (attempt_storage.len < slot_count)
        return Error.CapacityExceeded;
    if (slicesOverlap(
        u8,
        encoded,
        AttemptV1,
        attempt_storage,
    )) return Error.InvalidStorage;

    const body_end = encoded.len - manifest_footer_bytes;
    const stored_body = readDigestAt(encoded, body_end);
    const stored_footer = readDigestAt(encoded, body_end + 32);
    if (!digestEqual(
        stored_body,
        domainHash(manifest_body_domain, encoded[0..body_end]),
    )) return Error.InvalidBodyDigest;
    if (!digestEqual(
        stored_footer,
        domainHash(
            manifest_footer_domain,
            encoded[0 .. body_end + 32],
        ),
    )) return Error.InvalidFooterDigest;

    var reader: Reader = .{ .bytes = encoded };
    const plan = try readPlanV1(&reader);
    if (plan.encoded_bytes != encoded.len or
        plan.segment_count != slot_count)
        return Error.InvalidLength;
    try validatePlanV1(plan);
    if (reader.position != manifest_header_bytes)
        return Error.InvalidLength;

    var prefix_count: usize = 0;
    var found_padding = false;
    for (0..slot_count) |index| {
        const start = manifest_header_bytes + index * attempt_wire_bytes;
        const slot = encoded[start .. start + attempt_wire_bytes];
        if (std.mem.allEqual(u8, slot, 0)) {
            found_padding = true;
            reader.position += attempt_wire_bytes;
            continue;
        }
        if (found_padding) return Error.InvalidPadding;
        attempt_storage[prefix_count] = try readAttemptV1(&reader);
        prefix_count += 1;
    }
    if (prefix_count == 0 or reader.position != body_end)
        return Error.InvalidPadding;
    const manifest: ManifestV1 = .{
        .plan = plan,
        .attempts = attempt_storage[0..prefix_count],
    };
    try validateManifestV1(manifest);
    return .{
        .manifest = manifest,
        .encoded = encoded,
        .manifest_body_sha256 = stored_body,
        .manifest_footer_sha256 = stored_footer,
    };
}

pub fn environmentSha256V1(
    campaign_id_sha256: Digest,
    generation: u64,
    before_snapshot_sha256: Digest,
    after_snapshot_sha256: Digest,
) Error!Digest {
    if (digestIsZero(campaign_id_sha256) or generation == 0 or
        digestIsZero(before_snapshot_sha256))
        return Error.InvalidIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(environment_domain);
    hash.update(&campaign_id_sha256);
    hashU64(&hash, generation);
    hash.update(&before_snapshot_sha256);
    hash.update(&after_snapshot_sha256);
    return finishHash(&hash);
}

pub fn makeSelectorV1(
    manifest: ManifestV1,
    manifest_sha256: Digest,
    environment_sha256: Digest,
) Error!SelectorV1 {
    try validateManifestV1(manifest);
    if (digestIsZero(manifest_sha256) or
        digestIsZero(environment_sha256))
        return Error.InvalidIdentity;
    var total_events: u64 = 0;
    for (manifest.attempts) |attempt| {
        total_events = try addU64(total_events, attempt.event_count);
    }
    const last = manifest.attempts[manifest.attempts.len - 1];
    var selector: SelectorV1 = .{
        .generation = @intCast(manifest.attempts.len),
        .segment_count = manifest.plan.segment_count,
        .total_records = last.cumulative_records,
        .total_completed = last.cumulative_completed,
        .total_events = total_events,
        .authority_challenge_sha256 = manifest.plan.authority_challenge_sha256,
        .manifest_sha256 = manifest_sha256,
        .environment_sha256 = environment_sha256,
        .selector_sha256 = zero_digest,
    };
    selector.selector_sha256 = selectorSha256V1(selector);
    try validateSelectorV1(selector);
    return selector;
}

pub fn makeSelectorWithEnvironmentV1(
    manifest: ManifestV1,
    manifest_sha256: Digest,
    before_snapshot_sha256: Digest,
    after_snapshot_sha256: Digest,
) Error!SelectorV1 {
    if (manifest.complete()) {
        if (digestIsZero(after_snapshot_sha256))
            return Error.InvalidIdentity;
    } else if (!digestIsZero(after_snapshot_sha256)) {
        return Error.InvalidIdentity;
    }
    const environment = try environmentSha256V1(
        manifest.plan.campaign_id_sha256,
        @intCast(manifest.attempts.len),
        before_snapshot_sha256,
        after_snapshot_sha256,
    );
    return makeSelectorV1(
        manifest,
        manifest_sha256,
        environment,
    );
}

pub fn selectorSha256V1(value: SelectorV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(selector_domain);
    for (selectorScalarsV1(value)) |field| hashU64(&hash, field);
    const digests = selectorDigestsV1(value);
    for (digests[0..3]) |field| hash.update(&field);
    return finishHash(&hash);
}

pub fn validateSelectorV1(value: SelectorV1) Error!void {
    if (value.abi_version != selector_abi or
        value.bytes != selector_bytes or
        value.flags != allowed_selector_flags)
        return Error.InvalidSelector;
    if (value.generation == 0 or
        value.segment_count == 0 or
        value.generation > value.segment_count or
        value.segment_count > max_segment_count or
        value.total_records == 0 or
        value.total_completed == 0 or
        value.total_events == 0)
        return Error.InvalidSelector;
    inline for (selectorDigestsV1(value)) |field| {
        if (digestIsZero(field)) return Error.InvalidIdentity;
    }
    if (!digestEqual(
        value.selector_sha256,
        selectorSha256V1(value),
    )) return Error.InvalidSelector;
}

pub fn validateSelectorForManifestV1(
    value: SelectorV1,
    manifest: ManifestV1,
    manifest_sha256: Digest,
) Error!void {
    try validateSelectorV1(value);
    try validateManifestV1(manifest);
    if (value.generation != manifest.attempts.len or
        value.segment_count != manifest.plan.segment_count or
        !digestEqual(
            value.authority_challenge_sha256,
            manifest.plan.authority_challenge_sha256,
        ) or
        !digestEqual(
            value.manifest_sha256,
            manifest_sha256,
        ))
        return Error.InvalidSelector;
    var events: u64 = 0;
    for (manifest.attempts) |attempt|
        events = try addU64(events, attempt.event_count);
    const last = manifest.attempts[manifest.attempts.len - 1];
    if (value.total_records != last.cumulative_records or
        value.total_completed != last.cumulative_completed or
        value.total_events != events)
        return Error.InvalidSelector;
}

pub fn encodeSelectorV1(
    value: SelectorV1,
    destination: []u8,
) Error![]const u8 {
    try validateSelectorV1(value);
    if (destination.len < selector_bytes) return Error.CapacityExceeded;
    const output = destination[0..selector_bytes];
    @memset(output, 0);
    errdefer @memset(output, 0);
    var writer: Writer = .{ .bytes = output };
    for (selectorScalarsV1(value)) |field| try writer.writeU64(field);
    for (selectorDigestsV1(value)) |field|
        try writer.writeDigest(field);
    if (writer.position != selector_bytes) return Error.InvalidLength;
    return output;
}

pub fn decodeSelectorV1(encoded: []const u8) Error!SelectorV1 {
    if (encoded.len != selector_bytes) return Error.InvalidLength;
    var reader: Reader = .{ .bytes = encoded };
    var scalars: [8]u64 = undefined;
    for (&scalars) |*field| field.* = try reader.readU64();
    var digests: [4]Digest = undefined;
    for (&digests) |*field| field.* = try reader.readDigest();
    if (reader.position != encoded.len) return Error.InvalidLength;
    const value: SelectorV1 = .{
        .abi_version = scalars[0],
        .bytes = scalars[1],
        .flags = scalars[2],
        .generation = scalars[3],
        .segment_count = scalars[4],
        .total_records = scalars[5],
        .total_completed = scalars[6],
        .total_events = scalars[7],
        .authority_challenge_sha256 = digests[0],
        .manifest_sha256 = digests[1],
        .environment_sha256 = digests[2],
        .selector_sha256 = digests[3],
    };
    try validateSelectorV1(value);
    return value;
}

fn writePlanV1(writer: *Writer, value: PlanV1) Error!void {
    const start = writer.position;
    for (planScalarsV1(value)) |field| try writer.writeU64(field);
    for (planDigestsV1(value)) |field| try writer.writeDigest(field);
    if (writer.position - start != manifest_header_bytes)
        return Error.InvalidLength;
}

fn readPlanV1(reader: *Reader) Error!PlanV1 {
    const start = reader.position;
    var scalars: [32]u64 = undefined;
    for (&scalars) |*field| field.* = try reader.readU64();
    var digests: [12]Digest = undefined;
    for (&digests) |*field| field.* = try reader.readDigest();
    if (reader.position - start != manifest_header_bytes)
        return Error.InvalidLength;
    return .{
        .abi_version = scalars[0],
        .encoded_bytes = scalars[1],
        .flags = scalars[2],
        .segment_count = scalars[3],
        .restart_after_segment = scalars[4],
        .epochs_per_segment = scalars[5],
        .records_per_epoch = scalars[6],
        .warmup_epochs_per_segment = scalars[7],
        .measured_epochs_per_segment = scalars[8],
        .completed_per_epoch = scalars[9],
        .cancelled_per_epoch = scalars[10],
        .failed_per_epoch = scalars[11],
        .capacity_per_epoch = scalars[12],
        .pins_per_epoch = scalars[13],
        .events_per_epoch = scalars[14],
        .cadence_ns = scalars[15],
        .min_segment_ns = scalars[16],
        .max_segment_ns = scalars[17],
        .wire_bytes_per_segment = scalars[18],
        .artifact_store_max_bytes = scalars[19],
        .rss_growth_bound_bytes = scalars[20],
        .total_epochs = scalars[21],
        .total_records = scalars[22],
        .total_warmup_records = scalars[23],
        .total_measured_records = scalars[24],
        .total_completed = scalars[25],
        .total_cancelled = scalars[26],
        .total_failed = scalars[27],
        .total_capacity_rejected = scalars[28],
        .total_pin_acquisitions = scalars[29],
        .device_allocation_growth_bound_bytes = scalars[30],
        .total_events = scalars[31],
        .authority_challenge_sha256 = digests[0],
        .workload_sha256 = digests[1],
        .profile_sha256 = digests[2],
        .artifact_sha256 = digests[3],
        .build_sha256 = digests[4],
        .runner_sha256 = digests[5],
        .metallib_sha256 = digests[6],
        .machine_sha256 = digests[7],
        .backend_sha256 = digests[8],
        .device_sha256 = digests[9],
        .placement_sha256 = digests[10],
        .campaign_id_sha256 = digests[11],
    };
}

fn writeAttemptV1(writer: *Writer, value: AttemptV1) Error!void {
    const start = writer.position;
    for (attemptScalarsV1(value)) |field| try writer.writeU64(field);
    for (attemptDigestsV1(value)) |field| try writer.writeDigest(field);
    if (writer.position - start != attempt_wire_bytes)
        return Error.InvalidLength;
}

fn readAttemptV1(reader: *Reader) Error!AttemptV1 {
    const start = reader.position;
    var scalars: [32]u64 = undefined;
    for (&scalars) |*field| field.* = try reader.readU64();
    var digests: [20]Digest = undefined;
    for (&digests) |*field| field.* = try reader.readDigest();
    if (reader.position - start != attempt_wire_bytes)
        return Error.InvalidLength;
    const disposition: DispositionV1 = switch (scalars[3]) {
        1 => .verified_report,
        else => return Error.InvalidEnum,
    };
    const rss_availability = try availabilityFromIntV1(scalars[21]);
    const device_availability =
        try availabilityFromIntV1(scalars[25]);
    return .{
        .abi_version = scalars[0],
        .ordinal = scalars[1],
        .process_generation = scalars[2],
        .disposition = disposition,
        .provenance_bits = scalars[4],
        .epoch_count = scalars[5],
        .record_count = scalars[6],
        .warmup_record_count = scalars[7],
        .measured_record_count = scalars[8],
        .completed_count = scalars[9],
        .cancelled_count = scalars[10],
        .failed_count = scalars[11],
        .capacity_rejected_count = scalars[12],
        .pin_acquisitions = scalars[13],
        .pin_completions = scalars[14],
        .event_count = scalars[15],
        .report_wire_bytes = scalars[16],
        .duration_ns = scalars[17],
        .cumulative_duration_ns = scalars[18],
        .cumulative_records = scalars[19],
        .cumulative_completed = scalars[20],
        .rss_availability = rss_availability,
        .rss_before_bytes = scalars[22],
        .rss_max_bytes = scalars[23],
        .rss_after_bytes = scalars[24],
        .device_allocation_availability = device_availability,
        .device_allocation_before_bytes = scalars[26],
        .device_allocation_max_bytes = scalars[27],
        .device_allocation_after_bytes = scalars[28],
        .exit_code_bits = scalars[29],
        .termination_signal = scalars[30],
        .reserved = scalars[31],
        .scheduled_action_sha256 = digests[0],
        .segment_challenge_sha256 = digests[1],
        .previous_attempt_sha256 = digests[2],
        .previous_verified_report_sha256 = digests[3],
        .wire_sha256 = digests[4],
        .report_sha256 = digests[5],
        .scenario_sha256 = digests[6],
        .closure_sha256 = digests[7],
        .build_sha256 = digests[8],
        .machine_sha256 = digests[9],
        .backend_sha256 = digests[10],
        .device_sha256 = digests[11],
        .placement_sha256 = digests[12],
        .host_source_sha256 = digests[13],
        .host_clock_sha256 = digests[14],
        .rss_source_sha256 = digests[15],
        .rss_reason_sha256 = digests[16],
        .device_allocation_source_sha256 = digests[17],
        .device_allocation_reason_sha256 = digests[18],
        .attempt_sha256 = digests[19],
    };
}

fn availabilityFromIntV1(value: u64) Error!AvailabilityV1 {
    return switch (value) {
        0 => .missing,
        1 => .denied,
        2 => .unsupported,
        3 => .present,
        else => Error.InvalidEnum,
    };
}

pub fn planScalarsV1(value: PlanV1) [32]u64 {
    return .{
        value.abi_version,
        value.encoded_bytes,
        value.flags,
        value.segment_count,
        value.restart_after_segment,
        value.epochs_per_segment,
        value.records_per_epoch,
        value.warmup_epochs_per_segment,
        value.measured_epochs_per_segment,
        value.completed_per_epoch,
        value.cancelled_per_epoch,
        value.failed_per_epoch,
        value.capacity_per_epoch,
        value.pins_per_epoch,
        value.events_per_epoch,
        value.cadence_ns,
        value.min_segment_ns,
        value.max_segment_ns,
        value.wire_bytes_per_segment,
        value.artifact_store_max_bytes,
        value.rss_growth_bound_bytes,
        value.total_epochs,
        value.total_records,
        value.total_warmup_records,
        value.total_measured_records,
        value.total_completed,
        value.total_cancelled,
        value.total_failed,
        value.total_capacity_rejected,
        value.total_pin_acquisitions,
        value.device_allocation_growth_bound_bytes,
        value.total_events,
    };
}

pub fn planDigestsV1(value: PlanV1) [12]Digest {
    return .{
        value.authority_challenge_sha256,
        value.workload_sha256,
        value.profile_sha256,
        value.artifact_sha256,
        value.build_sha256,
        value.runner_sha256,
        value.metallib_sha256,
        value.machine_sha256,
        value.backend_sha256,
        value.device_sha256,
        value.placement_sha256,
        value.campaign_id_sha256,
    };
}

pub fn attemptScalarsV1(value: AttemptV1) [32]u64 {
    return .{
        value.abi_version,
        value.ordinal,
        value.process_generation,
        @intFromEnum(value.disposition),
        value.provenance_bits,
        value.epoch_count,
        value.record_count,
        value.warmup_record_count,
        value.measured_record_count,
        value.completed_count,
        value.cancelled_count,
        value.failed_count,
        value.capacity_rejected_count,
        value.pin_acquisitions,
        value.pin_completions,
        value.event_count,
        value.report_wire_bytes,
        value.duration_ns,
        value.cumulative_duration_ns,
        value.cumulative_records,
        value.cumulative_completed,
        @intFromEnum(value.rss_availability),
        value.rss_before_bytes,
        value.rss_max_bytes,
        value.rss_after_bytes,
        @intFromEnum(value.device_allocation_availability),
        value.device_allocation_before_bytes,
        value.device_allocation_max_bytes,
        value.device_allocation_after_bytes,
        value.exit_code_bits,
        value.termination_signal,
        value.reserved,
    };
}

pub fn attemptDigestsV1(value: AttemptV1) [20]Digest {
    return .{
        value.scheduled_action_sha256,
        value.segment_challenge_sha256,
        value.previous_attempt_sha256,
        value.previous_verified_report_sha256,
        value.wire_sha256,
        value.report_sha256,
        value.scenario_sha256,
        value.closure_sha256,
        value.build_sha256,
        value.machine_sha256,
        value.backend_sha256,
        value.device_sha256,
        value.placement_sha256,
        value.host_source_sha256,
        value.host_clock_sha256,
        value.rss_source_sha256,
        value.rss_reason_sha256,
        value.device_allocation_source_sha256,
        value.device_allocation_reason_sha256,
        value.attempt_sha256,
    };
}

pub fn selectorScalarsV1(value: SelectorV1) [8]u64 {
    return .{
        value.abi_version,
        value.bytes,
        value.flags,
        value.generation,
        value.segment_count,
        value.total_records,
        value.total_completed,
        value.total_events,
    };
}

pub fn selectorDigestsV1(value: SelectorV1) [4]Digest {
    return .{
        value.authority_challenge_sha256,
        value.manifest_sha256,
        value.environment_sha256,
        value.selector_sha256,
    };
}

fn addU64(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn mulU64(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn digestIsZero(value: Digest) bool {
    return std.mem.allEqual(u8, &value, 0);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn domainHash(domain: []const u8, bytes: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(bytes);
    return finishHash(&hash);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finishHash(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn readDigestAt(bytes: []const u8, offset: usize) Digest {
    var value: Digest = undefined;
    @memcpy(&value, bytes[offset .. offset + value.len]);
    return value;
}

fn slicesOverlap(
    comptime A: type,
    left: []const A,
    comptime B: type,
    right: []const B,
) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_bytes = std.math.mul(
        usize,
        left.len,
        @sizeOf(A),
    ) catch return true;
    const right_bytes = std.math.mul(
        usize,
        right.len,
        @sizeOf(B),
    ) catch return true;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(
        usize,
        left_start,
        left_bytes,
    ) catch return true;
    const right_end = std.math.add(
        usize,
        right_start,
        right_bytes,
    ) catch return true;
    return left_start < right_end and right_start < left_end;
}

const Writer = struct {
    bytes: []u8,
    position: usize = 0,

    fn writeU64(self: *Writer, value: u64) Error!void {
        const end = std.math.add(
            usize,
            self.position,
            @sizeOf(u64),
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.CapacityExceeded;
        std.mem.writeInt(
            u64,
            self.bytes[self.position..end][0..8],
            value,
            .little,
        );
        self.position = end;
    }

    fn writeDigest(self: *Writer, value: Digest) Error!void {
        const end = std.math.add(
            usize,
            self.position,
            value.len,
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.CapacityExceeded;
        @memcpy(self.bytes[self.position..end], &value);
        self.position = end;
    }
};

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn readU64(self: *Reader) Error!u64 {
        const end = std.math.add(
            usize,
            self.position,
            @sizeOf(u64),
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.InvalidLength;
        const value = std.mem.readInt(
            u64,
            self.bytes[self.position..end][0..8],
            .little,
        );
        self.position = end;
        return value;
    }

    fn readDigest(self: *Reader) Error!Digest {
        const end = std.math.add(
            usize,
            self.position,
            @sizeOf(Digest),
        ) catch return Error.ArithmeticOverflow;
        if (end > self.bytes.len) return Error.InvalidLength;
        var value: Digest = undefined;
        @memcpy(&value, self.bytes[self.position..end]);
        self.position = end;
        return value;
    }
};

const test_segment_count: usize = 12;
const test_manifest_bytes: usize =
    manifest_header_bytes +
    test_segment_count * attempt_wire_bytes +
    manifest_footer_bytes;

fn testDigest(tag: u64, ordinal: u64) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-native-workload-campaign-test-v1\x00");
    hashU64(&hash, tag);
    hashU64(&hash, ordinal);
    return finishHash(&hash);
}

fn goldenDigest(label: []const u8) Digest {
    return digestV1(label);
}

fn goldenOrdinalDigest(
    prefix: []const u8,
    ordinal: usize,
) !Digest {
    var storage: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(
        &storage,
        "{s}-{d}",
        .{ prefix, ordinal },
    );
    return goldenDigest(label);
}

fn goldenPlanConfig() PlanConfigV1 {
    const mib: u64 = 1024 * 1024;
    return .{
        .seed = .{
            .segment_count = test_segment_count,
            .restart_after_segment = 6,
            .epochs_per_segment = 50,
            .records_per_epoch = 5,
            .warmup_epochs_per_segment = 2,
            .measured_epochs_per_segment = 48,
            .completed_per_epoch = 2,
            .cancelled_per_epoch = 1,
            .failed_per_epoch = 1,
            .capacity_per_epoch = 1,
            .pins_per_epoch = 4,
            .events_per_epoch = 25,
            .cadence_ns = 100_000_000,
            .min_segment_ns = 5_000_000_000,
            .max_segment_ns = 15_000_000_000,
            .wire_bytes_per_segment = 195_556,
            .artifact_store_max_bytes = 8 * mib,
            .rss_growth_bound_bytes = 64 * mib,
            .device_allocation_growth_bound_bytes = 64 * mib,
            .authority_challenge_sha256 = goldenDigest("authority"),
            .workload_sha256 = goldenDigest("workload"),
            .profile_sha256 = goldenDigest("schedule"),
            .artifact_sha256 = goldenDigest("artifact"),
            .build_sha256 = goldenDigest("build"),
            .runner_sha256 = goldenDigest("runner"),
            .metallib_sha256 = goldenDigest("metallib"),
        },
        .machine_sha256 = goldenDigest("machine"),
        .backend_sha256 = goldenDigest("backend"),
        .device_sha256 = goldenDigest("device"),
        .placement_sha256 = goldenDigest("placement"),
    };
}

fn goldenAttemptConfig(
    ordinal: usize,
) !AttemptConfigV1 {
    const mib: u64 = 1024 * 1024;
    const generation: u64 = @intCast(ordinal / 6 + 1);
    const phase_ordinal: u64 = @intCast(ordinal % 6);
    const rss_before =
        (100 + generation * 20) * mib + phase_ordinal * 256 * 1024;
    const device_before =
        (40 + generation * 4) * mib + phase_ordinal * 128 * 1024;
    return .{
        .ordinal = @intCast(ordinal),
        .duration_ns = 5_000_000_000 +
            @as(u64, @intCast(ordinal)) * 1_000_000,
        .wire_sha256 = try goldenOrdinalDigest("wire", ordinal),
        .report_sha256 = try goldenOrdinalDigest("report", ordinal),
        .scenario_sha256 = try goldenOrdinalDigest("scenario", ordinal),
        .closure_sha256 = goldenDigest("closure"),
        .host_source_sha256 = goldenDigest("host-source"),
        .host_clock_sha256 = goldenDigest("host-clock"),
        .rss = .{
            .availability = .present,
            .before_bytes = rss_before,
            .max_bytes = rss_before + 128 * 1024,
            .after_bytes = rss_before + 64 * 1024,
            .source_sha256 = try goldenOrdinalDigest(
                "rss-source",
                @intCast(generation),
            ),
        },
        .device_allocation = .{
            .availability = .present,
            .before_bytes = device_before,
            .max_bytes = device_before + 64 * 1024,
            .after_bytes = device_before + 32 * 1024,
            .source_sha256 = goldenDigest(
                "device-allocation-source",
            ),
        },
    };
}

fn expectDigestHex(
    expected: []const u8,
    actual: Digest,
) !void {
    const actual_hex = std.fmt.bytesToHex(actual, .lower);
    try std.testing.expectEqualStrings(expected, &actual_hex);
}

fn testPlanConfig() PlanConfigV1 {
    return .{
        .seed = .{
            .segment_count = test_segment_count,
            .restart_after_segment = 6,
            .epochs_per_segment = 50,
            .records_per_epoch = 5,
            .warmup_epochs_per_segment = 2,
            .measured_epochs_per_segment = 48,
            .completed_per_epoch = 2,
            .cancelled_per_epoch = 1,
            .failed_per_epoch = 1,
            .capacity_per_epoch = 1,
            .pins_per_epoch = 4,
            .events_per_epoch = 25,
            .cadence_ns = 100_000_000,
            .min_segment_ns = 5_000_000_000,
            .max_segment_ns = 15_000_000_000,
            .wire_bytes_per_segment = 195_556,
            .artifact_store_max_bytes = 3 * 1024 * 1024,
            .rss_growth_bound_bytes = 100,
            .device_allocation_growth_bound_bytes = 200,
            .authority_challenge_sha256 = testDigest(1, 0),
            .workload_sha256 = testDigest(2, 0),
            .profile_sha256 = testDigest(3, 0),
            .artifact_sha256 = testDigest(4, 0),
            .build_sha256 = testDigest(5, 0),
            .runner_sha256 = testDigest(6, 0),
            .metallib_sha256 = testDigest(7, 0),
        },
        .machine_sha256 = testDigest(8, 0),
        .backend_sha256 = testDigest(9, 0),
        .device_sha256 = testDigest(10, 0),
        .placement_sha256 = testDigest(11, 0),
    };
}

fn testAttemptConfig(
    plan: PlanV1,
    ordinal: usize,
) AttemptConfigV1 {
    const restart: usize = @intCast(plan.restart_after_segment);
    const generation: usize =
        if (restart != 0 and ordinal >= restart) 1 else 0;
    const phase_ordinal =
        if (generation == 0) ordinal else ordinal - restart;
    const rss_base: u64 = 1_000 + @as(u64, @intCast(generation)) * 1_000;
    const rss_step: u64 = @as(u64, @intCast(phase_ordinal)) * 10;
    const device_base: u64 = 5_000 + @as(u64, @intCast(ordinal)) * 5;
    return .{
        .ordinal = @intCast(ordinal),
        .duration_ns = 5_000_000_000 + @as(u64, @intCast(ordinal)) * 100_000_000,
        .wire_sha256 = testDigest(20, @intCast(ordinal)),
        .report_sha256 = testDigest(21, @intCast(ordinal)),
        .scenario_sha256 = testDigest(22, @intCast(ordinal)),
        .closure_sha256 = testDigest(23, @intCast(ordinal)),
        .host_source_sha256 = testDigest(24, 0),
        .host_clock_sha256 = testDigest(25, 0),
        .rss = .{
            .availability = .present,
            .before_bytes = rss_base + rss_step,
            .max_bytes = rss_base + rss_step + 3,
            .after_bytes = rss_base + rss_step + 2,
            .source_sha256 = testDigest(26, @intCast(generation)),
        },
        .device_allocation = .{
            .availability = .present,
            .before_bytes = device_base,
            .max_bytes = device_base + 3,
            .after_bytes = device_base + 2,
            .source_sha256 = testDigest(27, 0),
        },
    };
}

fn fillTestAttempts(
    plan: PlanV1,
    storage: *[test_segment_count]AttemptV1,
) !void {
    for (storage, 0..) |*attempt, index| {
        attempt.* = try makeAttemptV1(
            plan,
            if (index == 0) null else &storage[index - 1],
            testAttemptConfig(plan, index),
        );
    }
}

fn resealManifestForTest(encoded: []u8) void {
    const body_end = encoded.len - manifest_footer_bytes;
    const body_root = domainHash(
        manifest_body_domain,
        encoded[0..body_end],
    );
    @memcpy(encoded[body_end .. body_end + 32], &body_root);
    const footer_root = domainHash(
        manifest_footer_domain,
        encoded[0 .. body_end + 32],
    );
    @memcpy(encoded[body_end + 32 ..], &footer_root);
}

test "wire codec matches the independent Python golden fixture" {
    const testing = std.testing;
    const plan = try makePlanV1(goldenPlanConfig());
    try expectDigestHex(
        "5105081b9bf8388df21c66b48f8184c3912fba42ff5bb75f660e4b4c01584dbe",
        plan.campaign_id_sha256,
    );

    var attempts: [test_segment_count]AttemptV1 = undefined;
    for (&attempts, 0..) |*attempt, ordinal| {
        attempt.* = try makeAttemptV1(
            plan,
            if (ordinal == 0) null else &attempts[ordinal - 1],
            try goldenAttemptConfig(ordinal),
        );
    }
    try expectDigestHex(
        "1208b589a289090d833905f0e61b59f485f60494920e1eb3c9b173ed4ca65174",
        attempts[0].scheduled_action_sha256,
    );
    try expectDigestHex(
        "19a9f634f4af2a902cb4c39871587cd4d3df89726e9a8d5d6663b07a224b9542",
        attempts[0].segment_challenge_sha256,
    );
    try expectDigestHex(
        "2ace52591bb5bc8303a2da0b365f5828ad86d35588f1f22f5044684141377109",
        try unavailableReasonSha256V1(
            .process_rss,
            plan.campaign_id_sha256,
            0,
            .unsupported,
            goldenDigest("rss-source-1"),
        ),
    );
    try expectDigestHex(
        "1f2c8031bef3e1fc7a462f8f2e6bbe2896b5778933a34ce79ba96d62df64a466",
        try unavailableReasonSha256V1(
            .device_allocation_context,
            plan.campaign_id_sha256,
            0,
            .denied,
            goldenDigest("device-allocation-source"),
        ),
    );
    try expectDigestHex(
        "b66833a889da51e892a65939299d2c23df00ad4737c6508da4c8b725b19204f0",
        attempts[0].attempt_sha256,
    );

    const manifest = try makeManifestV1(plan, &attempts);
    var wire: [test_manifest_bytes]u8 = undefined;
    const encoded = try encodeManifestV1(manifest, &wire);
    try expectDigestHex(
        "226dd248e1effcbc2abecbd44df0243035b5fec3cd552a950f0c6fa9946afeb6",
        encoded.manifest_body_sha256,
    );
    try expectDigestHex(
        "447cf61a1035e88557fda9591d60fa2e5e55ed55ed9258aa3d1ec0e2823a92eb",
        encoded.manifest_footer_sha256,
    );
    try expectDigestHex(
        "135b6fa000e02b870bdebba8da1c3e95b254861ddd733b3f8b85d35069ef46fc",
        digestV1(encoded.bytes),
    );

    const selector = try makeSelectorWithEnvironmentV1(
        manifest,
        encoded.manifest_footer_sha256,
        goldenDigest("environment-before"),
        goldenDigest("environment-after"),
    );
    try expectDigestHex(
        "d3ca4b9cb32eec8060315547cb1256e73555d77cfa4828248c42fe6d94381ce2",
        selector.selector_sha256,
    );
    try testing.expectEqual(@as(u64, 12), selector.generation);
    try testing.expectEqual(@as(u64, 3_000), selector.total_records);
    try testing.expectEqual(@as(u64, 1_200), selector.total_completed);
    try testing.expectEqual(@as(u64, 15_000), selector.total_events);
}

test "campaign plan locks fixed W7 geometry and excludes dynamic identity from campaign id" {
    const testing = std.testing;
    const config = testPlanConfig();
    const plan = try makePlanV1(config);
    try testing.expectEqual(@as(u64, test_manifest_bytes), plan.encoded_bytes);
    try testing.expectEqual(@as(u64, 600), plan.total_epochs);
    try testing.expectEqual(@as(u64, 3_000), plan.total_records);
    try testing.expectEqual(@as(u64, 120), plan.total_warmup_records);
    try testing.expectEqual(@as(u64, 2_880), plan.total_measured_records);
    try testing.expectEqual(@as(u64, 1_200), plan.total_completed);
    try testing.expectEqual(@as(u64, 600), plan.total_cancelled);
    try testing.expectEqual(@as(u64, 600), plan.total_failed);
    try testing.expectEqual(@as(u64, 600), plan.total_capacity_rejected);
    try testing.expectEqual(@as(u64, 2_400), plan.total_pin_acquisitions);
    try testing.expectEqual(@as(u64, 15_000), plan.total_events);
    try testing.expectEqual(
        try campaignIdV1(config.seed),
        plan.campaign_id_sha256,
    );

    var different = config;
    different.machine_sha256 = testDigest(80, 1);
    different.backend_sha256 = testDigest(80, 2);
    different.device_sha256 = testDigest(80, 3);
    different.placement_sha256 = testDigest(80, 4);
    const different_plan = try makePlanV1(different);
    try testing.expectEqual(
        plan.campaign_id_sha256,
        different_plan.campaign_id_sha256,
    );
    try testing.expect(!std.meta.eql(plan, different_plan));
}

test "plan supports no restart or one nonperiodic restart boundary" {
    const testing = std.testing;
    _ = try manifestEncodedBytesV1(max_segment_count);
    try testing.expectError(
        Error.CapacityExceeded,
        manifestEncodedBytesV1(max_segment_count + 1),
    );

    var no_restart_config = testPlanConfig();
    no_restart_config.seed.segment_count = 3;
    no_restart_config.seed.restart_after_segment = 0;
    const no_restart_plan = try makePlanV1(no_restart_config);
    var no_restart_attempts: [3]AttemptV1 = undefined;
    for (&no_restart_attempts, 0..) |*attempt, ordinal| {
        attempt.* = try makeAttemptV1(
            no_restart_plan,
            if (ordinal == 0)
                null
            else
                &no_restart_attempts[ordinal - 1],
            testAttemptConfig(no_restart_plan, ordinal),
        );
    }
    _ = try makeManifestV1(no_restart_plan, &no_restart_attempts);
    try testing.expectEqual(@as(u64, 1), no_restart_attempts[2].process_generation);
    try testing.expectEqual(
        running_exit_code_bits,
        no_restart_attempts[1].exit_code_bits,
    );
    try testing.expectEqual(@as(u64, 0), no_restart_attempts[2].exit_code_bits);
    try testing.expectEqual(
        base_segment_provenance,
        no_restart_attempts[2].provenance_bits,
    );

    var one_restart_config = testPlanConfig();
    one_restart_config.seed.segment_count = 8;
    one_restart_config.seed.restart_after_segment = 3;
    const one_restart_plan = try makePlanV1(one_restart_config);
    var one_restart_attempts: [8]AttemptV1 = undefined;
    for (&one_restart_attempts, 0..) |*attempt, ordinal| {
        attempt.* = try makeAttemptV1(
            one_restart_plan,
            if (ordinal == 0)
                null
            else
                &one_restart_attempts[ordinal - 1],
            testAttemptConfig(one_restart_plan, ordinal),
        );
    }
    _ = try makeManifestV1(one_restart_plan, &one_restart_attempts);
    try testing.expectEqual(@as(u64, 0), one_restart_attempts[2].exit_code_bits);
    try testing.expectEqual(
        running_exit_code_bits,
        one_restart_attempts[5].exit_code_bits,
    );
    try testing.expectEqual(@as(u64, 2), one_restart_attempts[7].process_generation);
    try testing.expectEqual(
        base_segment_provenance |
            provenance_planned_graceful_restart,
        one_restart_attempts[2].provenance_bits,
    );
    try testing.expectEqual(
        base_segment_provenance,
        one_restart_attempts[5].provenance_bits,
    );

    var invalid_restart = testPlanConfig();
    invalid_restart.seed.restart_after_segment =
        invalid_restart.seed.segment_count;
    try testing.expectError(
        Error.InvalidPlan,
        makePlanV1(invalid_restart),
    );
    var invalid_pacing = testPlanConfig();
    invalid_pacing.seed.min_segment_ns -= 1;
    try testing.expectError(
        Error.InvalidPlan,
        makePlanV1(invalid_pacing),
    );
    var zero_warmup = testPlanConfig();
    zero_warmup.seed.warmup_epochs_per_segment = 0;
    zero_warmup.seed.measured_epochs_per_segment =
        zero_warmup.seed.epochs_per_segment;
    _ = try makePlanV1(zero_warmup);
}

test "partial manifest round trips fixed zero padding and selector" {
    const testing = std.testing;
    const plan = try makePlanV1(testPlanConfig());
    var attempts: [test_segment_count]AttemptV1 = undefined;
    try fillTestAttempts(plan, &attempts);
    const manifest = try makeManifestV1(plan, attempts[0..3]);
    var encoded_storage: [test_manifest_bytes]u8 = undefined;
    const encoded = try encodeManifestV1(manifest, &encoded_storage);
    try testing.expectEqual(@as(usize, test_manifest_bytes), encoded.bytes.len);
    const padding_start =
        manifest_header_bytes + manifest.attempts.len * attempt_wire_bytes;
    const body_end = encoded.bytes.len - manifest_footer_bytes;
    try testing.expect(std.mem.allEqual(
        u8,
        encoded.bytes[padding_start..body_end],
        0,
    ));

    var decoded_storage: [test_segment_count]AttemptV1 = undefined;
    const decoded = try decodeManifestV1(
        encoded.bytes,
        &decoded_storage,
    );
    try testing.expectEqual(@as(usize, 3), decoded.manifest.attempts.len);
    try testing.expectEqualDeep(plan, decoded.manifest.plan);
    try testing.expectEqualDeep(
        attempts[0..3],
        decoded.manifest.attempts,
    );

    const before = testDigest(90, 0);
    const selector = try makeSelectorWithEnvironmentV1(
        decoded.manifest,
        decoded.manifest_footer_sha256,
        before,
        zero_digest,
    );
    try testing.expectEqual(@as(u64, 3), selector.generation);
    try testing.expectEqual(@as(u64, 750), selector.total_records);
    try testing.expectEqual(@as(u64, 300), selector.total_completed);
    try testing.expectEqual(@as(u64, 3_750), selector.total_events);
    try validateSelectorForManifestV1(
        selector,
        decoded.manifest,
        decoded.manifest_footer_sha256,
    );
    var selector_storage: [selector_bytes]u8 = undefined;
    const selector_wire = try encodeSelectorV1(
        selector,
        &selector_storage,
    );
    try testing.expectEqualDeep(
        selector,
        try decodeSelectorV1(selector_wire),
    );
    try testing.expectError(
        Error.InvalidIdentity,
        makeSelectorWithEnvironmentV1(
            decoded.manifest,
            decoded.manifest_footer_sha256,
            before,
            testDigest(90, 1),
        ),
    );
}

test "full manifest requires post environment and exact terminal totals" {
    const testing = std.testing;
    const plan = try makePlanV1(testPlanConfig());
    var attempts: [test_segment_count]AttemptV1 = undefined;
    try fillTestAttempts(plan, &attempts);
    const manifest = try makeManifestV1(plan, &attempts);
    try testing.expect(manifest.complete());
    try testing.expectEqual(
        running_exit_code_bits,
        attempts[4].exit_code_bits,
    );
    try testing.expectEqual(@as(u64, 0), attempts[5].exit_code_bits);
    try testing.expectEqual(@as(u64, 0), attempts[11].exit_code_bits);
    try testing.expectEqual(
        base_segment_provenance |
            provenance_planned_graceful_restart,
        attempts[5].provenance_bits,
    );
    try testing.expectEqual(
        base_segment_provenance,
        attempts[11].provenance_bits,
    );
    var wire: [test_manifest_bytes]u8 = undefined;
    const encoded = try encodeManifestV1(manifest, &wire);
    try testing.expectError(
        Error.InvalidIdentity,
        makeSelectorWithEnvironmentV1(
            manifest,
            encoded.manifest_footer_sha256,
            testDigest(91, 0),
            zero_digest,
        ),
    );
    const selector = try makeSelectorWithEnvironmentV1(
        manifest,
        encoded.manifest_footer_sha256,
        testDigest(91, 0),
        testDigest(91, 1),
    );
    try testing.expectEqual(@as(u64, 12), selector.generation);
    try testing.expectEqual(plan.total_records, selector.total_records);
    try testing.expectEqual(plan.total_completed, selector.total_completed);
    try testing.expectEqual(plan.total_events, selector.total_events);
}

test "decoder rejects gaps corruption truncation and extension" {
    const testing = std.testing;
    const plan = try makePlanV1(testPlanConfig());
    var attempts: [test_segment_count]AttemptV1 = undefined;
    try fillTestAttempts(plan, &attempts);
    const manifest = try makeManifestV1(plan, &attempts);
    var wire: [test_manifest_bytes]u8 = undefined;
    _ = try encodeManifestV1(manifest, &wire);
    var decoded_storage: [test_segment_count]AttemptV1 = undefined;

    var gap = wire;
    const gap_start = manifest_header_bytes + attempt_wire_bytes;
    @memset(gap[gap_start .. gap_start + attempt_wire_bytes], 0);
    resealManifestForTest(&gap);
    try testing.expectError(
        Error.InvalidPadding,
        decodeManifestV1(&gap, &decoded_storage),
    );

    var corrupt = wire;
    corrupt[manifest_header_bytes + 17] ^= 1;
    try testing.expectError(
        Error.InvalidBodyDigest,
        decodeManifestV1(&corrupt, &decoded_storage),
    );
    try testing.expectError(
        Error.InvalidLength,
        decodeManifestV1(
            wire[0 .. wire.len - 1],
            &decoded_storage,
        ),
    );
    var extended: [test_manifest_bytes + 1]u8 = undefined;
    @memcpy(extended[0..wire.len], &wire);
    extended[wire.len] = 0;
    try testing.expectError(
        Error.InvalidLength,
        decodeManifestV1(&extended, &decoded_storage),
    );
}

test "dual predecessor chains reject coherent substitution" {
    const testing = std.testing;
    const plan = try makePlanV1(testPlanConfig());
    var attempts: [test_segment_count]AttemptV1 = undefined;
    try fillTestAttempts(plan, &attempts);

    var wrong_entry = attempts;
    wrong_entry[1].previous_attempt_sha256 = testDigest(100, 1);
    wrong_entry[1].attempt_sha256 = try attemptSha256V1(
        plan.campaign_id_sha256,
        wrong_entry[1],
    );
    try testing.expectError(
        Error.InvalidAttempt,
        makeManifestV1(plan, wrong_entry[0..2]),
    );

    var wrong_report = attempts;
    wrong_report[1].previous_verified_report_sha256 =
        testDigest(100, 2);
    wrong_report[1].attempt_sha256 = try attemptSha256V1(
        plan.campaign_id_sha256,
        wrong_report[1],
    );
    try testing.expectError(
        Error.InvalidAttempt,
        makeManifestV1(plan, wrong_report[0..2]),
    );
}

test "unavailable observations require zero values and exact reasons" {
    const testing = std.testing;
    const plan = try makePlanV1(testPlanConfig());
    var config = testAttemptConfig(plan, 0);
    config.rss = .{
        .availability = .unsupported,
        .source_sha256 = testDigest(110, 0),
    };
    config.device_allocation = .{
        .availability = .denied,
        .source_sha256 = testDigest(111, 0),
    };
    var attempt = try makeAttemptV1(plan, null, config);
    try testing.expectEqual(
        try unavailableReasonSha256V1(
            .process_rss,
            plan.campaign_id_sha256,
            attempt.ordinal,
            .unsupported,
            attempt.rss_source_sha256,
        ),
        attempt.rss_reason_sha256,
    );
    try testing.expectEqual(
        try unavailableReasonSha256V1(
            .device_allocation_context,
            plan.campaign_id_sha256,
            attempt.ordinal,
            .denied,
            attempt.device_allocation_source_sha256,
        ),
        attempt.device_allocation_reason_sha256,
    );
    _ = try makeManifestV1(plan, @as(*[1]AttemptV1, &attempt)[0..]);

    attempt.rss_reason_sha256 = zero_digest;
    attempt.attempt_sha256 = try attemptSha256V1(
        plan.campaign_id_sha256,
        attempt,
    );
    try testing.expectError(
        Error.InvalidAttempt,
        makeManifestV1(plan, @as(*[1]AttemptV1, &attempt)[0..]),
    );

    config.rss.before_bytes = 1;
    try testing.expectError(
        Error.InvalidObservation,
        makeAttemptV1(plan, null, config),
    );
}

test "observation availability may recover or disappear within one process" {
    const plan = try makePlanV1(testPlanConfig());

    var recovering: [2]AttemptV1 = undefined;
    var unavailable_first = testAttemptConfig(plan, 0);
    unavailable_first.rss = .{
        .availability = .unsupported,
        .source_sha256 = testDigest(26, 0),
    };
    recovering[0] = try makeAttemptV1(
        plan,
        null,
        unavailable_first,
    );
    recovering[1] = try makeAttemptV1(
        plan,
        &recovering[0],
        testAttemptConfig(plan, 1),
    );
    _ = try makeManifestV1(plan, &recovering);

    var disappearing: [2]AttemptV1 = undefined;
    disappearing[0] = try makeAttemptV1(
        plan,
        null,
        testAttemptConfig(plan, 0),
    );
    var unavailable_second = testAttemptConfig(plan, 1);
    unavailable_second.rss = .{
        .availability = .missing,
        .source_sha256 = testDigest(26, 0),
    };
    disappearing[1] = try makeAttemptV1(
        plan,
        &disappearing[0],
        unavailable_second,
    );
    _ = try makeManifestV1(plan, &disappearing);
}

test "phase baseline rejects cumulative RSS creep and resets only at restart" {
    const testing = std.testing;
    var config = testPlanConfig();
    config.seed.rss_growth_bound_bytes = 20;
    const plan = try makePlanV1(config);
    var attempts: [3]AttemptV1 = undefined;
    for (&attempts, 0..) |*attempt, index| {
        var attempt_config = testAttemptConfig(plan, index);
        attempt_config.rss.before_bytes = 100 + @as(u64, @intCast(index)) * 5;
        attempt_config.rss.max_bytes = 105 + @as(u64, @intCast(index)) * 10;
        attempt_config.rss.after_bytes = 104 + @as(u64, @intCast(index)) * 5;
        attempt_config.rss.source_sha256 = testDigest(120, 0);
        attempt.* = try makeAttemptV1(
            plan,
            if (index == 0) null else &attempts[index - 1],
            attempt_config,
        );
    }
    // Entry two is locally close to entry one, but exceeds generation one's
    // original 100-byte baseline plus the 20-byte campaign ceiling.
    try testing.expectError(
        Error.InvalidObservation,
        makeManifestV1(plan, &attempts),
    );

    var full: [test_segment_count]AttemptV1 = undefined;
    try fillTestAttempts(
        try makePlanV1(testPlanConfig()),
        &full,
    );
    _ = try makeManifestV1(
        try makePlanV1(testPlanConfig()),
        &full,
    );
    try testing.expect(!digestEqual(
        full[5].rss_source_sha256,
        full[6].rss_source_sha256,
    ));
}

test "device allocation context has an independent phase growth ceiling" {
    const testing = std.testing;
    var config = testPlanConfig();
    config.seed.device_allocation_growth_bound_bytes = 10;
    const plan = try makePlanV1(config);
    var attempts: [3]AttemptV1 = undefined;
    for (&attempts, 0..) |*attempt, index| {
        var attempt_config = testAttemptConfig(plan, index);
        attempt_config.device_allocation.before_bytes =
            1_000 + @as(u64, @intCast(index)) * 4;
        attempt_config.device_allocation.max_bytes =
            1_005 + @as(u64, @intCast(index)) * 4;
        attempt_config.device_allocation.after_bytes =
            1_004 + @as(u64, @intCast(index)) * 4;
        attempt.* = try makeAttemptV1(
            plan,
            if (index == 0) null else &attempts[index - 1],
            attempt_config,
        );
    }
    try testing.expectError(
        Error.InvalidObservation,
        makeManifestV1(plan, &attempts),
    );
}

test "RSS source is stable inside a process generation and fresh after restart" {
    const testing = std.testing;
    const plan = try makePlanV1(testPlanConfig());
    var attempts: [test_segment_count]AttemptV1 = undefined;
    try fillTestAttempts(plan, &attempts);

    var changed = testAttemptConfig(plan, 1);
    changed.rss.source_sha256 = testDigest(130, 1);
    attempts[1] = try makeAttemptV1(plan, &attempts[0], changed);
    try testing.expectError(
        Error.InvalidIdentity,
        makeManifestV1(plan, attempts[0..2]),
    );

    try fillTestAttempts(plan, &attempts);
    var stale_restart = testAttemptConfig(plan, 6);
    stale_restart.rss.source_sha256 = attempts[5].rss_source_sha256;
    attempts[6] = try makeAttemptV1(plan, &attempts[5], stale_restart);
    try testing.expectError(
        Error.InvalidIdentity,
        makeManifestV1(plan, attempts[0..7]),
    );
}

test "resume advances selector generation and rejects stale selector pairing" {
    const testing = std.testing;
    const plan = try makePlanV1(testPlanConfig());
    var attempts: [test_segment_count]AttemptV1 = undefined;
    try fillTestAttempts(plan, &attempts);
    var wire_three: [test_manifest_bytes]u8 = undefined;
    const manifest_three = try makeManifestV1(plan, attempts[0..3]);
    const encoded_three = try encodeManifestV1(
        manifest_three,
        &wire_three,
    );
    const selector_three = try makeSelectorWithEnvironmentV1(
        manifest_three,
        encoded_three.manifest_footer_sha256,
        testDigest(140, 0),
        zero_digest,
    );

    var wire_four: [test_manifest_bytes]u8 = undefined;
    const manifest_four = try makeManifestV1(plan, attempts[0..4]);
    const encoded_four = try encodeManifestV1(
        manifest_four,
        &wire_four,
    );
    const selector_four = try makeSelectorWithEnvironmentV1(
        manifest_four,
        encoded_four.manifest_footer_sha256,
        testDigest(140, 0),
        zero_digest,
    );
    try testing.expectEqual(@as(u64, 3), selector_three.generation);
    try testing.expectEqual(@as(u64, 4), selector_four.generation);
    try testing.expect(!digestEqual(
        selector_three.manifest_sha256,
        selector_four.manifest_sha256,
    ));
    try testing.expectError(
        Error.InvalidSelector,
        validateSelectorForManifestV1(
            selector_three,
            manifest_four,
            encoded_four.manifest_footer_sha256,
        ),
    );
    try validateSelectorForManifestV1(
        selector_four,
        manifest_four,
        encoded_four.manifest_footer_sha256,
    );
}
