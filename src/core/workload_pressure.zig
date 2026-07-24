//! Bounded, model-free mixed-media workload pressure conformance.
//!
//! This module is deliberately not a wall-clock benchmark. It replays one
//! explicit open-loop arrival schedule against LaneWeave and ResourceBank,
//! records logical queue/completion steps, and proves that all flat admission
//! receipts are released. It performs no model execution, media publication,
//! filesystem or network I/O, device work, timing, random generation, heap
//! allocation, or thread creation. The built-in driver retains that boundary.
//! An additive caller-supplied driver may bind external lifecycles to the same
//! scheduler receipts; those effects are outside the default V1 evidence.

const std = @import("std");
const qos = @import("lane_weave_qos.zig");
const resource_bank = @import("resource_bank.zig");
const media = @import("media_contract.zig");
const model = @import("model_contract.zig");
const media_fixture = @import("media_fixture.zig");
const media_decode_plan = @import("media_decode_plan.zig");
const media_transform = @import("media_transform.zig");
const media_runtime = @import("media_runtime_txn.zig");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const scenario_abi: u64 = 0x4757_5053_0000_0001;
pub const result_abi: u64 = 0x4757_5052_0000_0001;
pub const summary_abi: u64 = 0x4757_5059_0000_0001;
pub const trace_abi: u64 = 0x4757_5054_0000_0001;
pub const profile_abi: u64 = 0x4757_5050_0000_0001;

pub const scenario_magic = [8]u8{ 'G', 'W', 'P', 'S', 'C', '1', 0, 0 };
pub const result_magic = [8]u8{ 'G', 'W', 'P', 'R', 'S', '1', 0, 0 };

pub const scenario_header_bytes: usize = 256;
pub const scenario_item_bytes: usize = 272;
pub const scenario_footer_bytes: usize = 32;
pub const result_header_bytes: usize = 544;
pub const outcome_record_bytes: usize = 160;
pub const trace_record_bytes: usize = 112;
pub const result_footer_bytes: usize = 32;

pub const maximum_items: usize = 16;
pub const maximum_trace_records: usize = 64;
pub const maximum_driver_steps: u64 = 512;
pub const maximum_service_quanta: u64 = 256;
pub const absent_step: u64 = std.math.maxInt(u64);
pub const absent_item: u64 = std.math.maxInt(u64);
pub const allowed_flags: u64 = 0;

const scenario_domain = "glacier-workload-pressure-scenario-v1\x00";
const scenario_item_domain = "glacier-workload-pressure-item-v1\x00";
const profile_domain = "glacier-workload-pressure-profile-v1\x00";
const result_domain = "glacier-workload-pressure-result-v1\x00";
const trace_domain = "glacier-workload-pressure-trace-v1\x00";
const trace_record_domain = "glacier-workload-pressure-trace-record-v1\x00";
const outcome_domain = "glacier-workload-pressure-outcomes-v1\x00";
const summary_domain = "glacier-workload-pressure-summary-v1\x00";

pub const Error = qos.Error || resource_bank.Error || error{
    ArithmeticOverflow,
    BufferTooSmall,
    InvalidScenario,
    InvalidEvidence,
    ItemLimitExceeded,
    TraceLimitExceeded,
    DriverStepLimitExceeded,
    ServiceLimitExceeded,
    UnexpectedAdmission,
    UnexpectedTerminalAction,
    MissingWorkItem,
    IncompleteScenario,
    DriverFailed,
};

pub const ModeV1 = enum(u64) {
    explicit_open_loop = 1,
};

pub const TerminalActionV1 = enum(u64) {
    none = 0,
    cancel = 1,
    timeout = 2,
};

pub const OutcomeKindV1 = enum(u64) {
    completed = 1,
    rejected = 2,
    cancelled = 3,
    timed_out = 4,
};

const RuntimeState = enum {
    pending,
    active,
    terminal,
};

/// One model-free logical request. `work_quanta` are scheduler quanta, not
/// model tokens, samples, frames, diffusion steps, or elapsed time.
pub const WorkItemV1 = struct {
    ordinal: u64,
    family: model.ModelFamilyIdV1,
    operation: model.OperationIdV1,
    media_kind: media.MediaKindV1,
    profile_sha256: Digest,
    arrival_step: u64,
    weight: u16,
    work_quanta: u64,
    /// Absolute LaneWeave service tick. Zero means no deadline.
    deadline_tick: u64,
    /// Absolute driver step. `absent_step` means no scheduled action.
    terminal_action_step: u64,
    terminal_action: TerminalActionV1,
    fairness_member: bool,
    tenant_key: u64,
    request_key: u64,
    request_generation: u64,
    resource_owner_key: u64,
    claim: resource_bank.Claim,
};

pub const ScenarioV1 = struct {
    mode: ModeV1 = .explicit_open_loop,
    seed: u64,
    max_driver_steps: u64,
    fairness_start_tick: u64,
    fairness_end_tick: u64,
    bank_epoch: u64,
    scheduler_epoch: u64,
    max_weight: u16,
    max_projection_quanta: u64,
    max_projection_operations: u64,
    capacity: u32,
    limits: resource_bank.Limits,
    challenge: Digest,
    items: []const WorkItemV1,
};

pub const OutcomeV1 = struct {
    ordinal: u64,
    kind: OutcomeKindV1,
    rejection_reason: qos.RejectionReason = .none,
    terminal_action: TerminalActionV1 = .none,
    admitted_step: u64 = absent_step,
    first_service_step: u64 = absent_step,
    terminal_step: u64 = absent_step,
    served_quanta: u64 = 0,
    maximum_wait_quanta: u64 = 0,
    queue_delay_steps: u64 = absent_step,
    completion_delay_steps: u64 = absent_step,
    admission_trace_sha256: Digest = zero_digest,
    terminal_trace_sha256: Digest = zero_digest,
};

pub const TraceRecordV1 = struct {
    driver_step: u64,
    item_ordinal: u64,
    event_kind: qos.EventKind,
    rejection_reason: qos.RejectionReason = .none,
    terminal_action: TerminalActionV1 = .none,
    logical_tick_before: u64,
    logical_tick_after: u64,
    remaining_before: u64,
    remaining_after: u64,
    wait_quanta: u64,
    record_sha256: Digest,
};

pub const SummaryV1 = struct {
    admitted: u64,
    rejected: u64,
    completed: u64,
    cancelled: u64,
    timed_out: u64,
    service_quanta: u64,
    driver_steps: u64,
    final_logical_tick: u64,
    maximum_live_receipts: u64,
    peak_host_bytes: u64,
    peak: resource_bank.Claim,
    maximum_wait_quanta: u64,
    maximum_service_gap: u64,
    fairness_cross_product_error: u64,
    queue_delay_p50_steps: u64,
    queue_delay_p95_steps: u64,
    queue_delay_p99_steps: u64,
    queue_delay_max_steps: u64,
    completion_delay_p50_steps: u64,
    completion_delay_p95_steps: u64,
    completion_delay_p99_steps: u64,
    completion_delay_max_steps: u64,
    final_active: u64,
    final_finished: u64,
    final_active_reservations: u64,
    final_committed_receipts: u64,
    successful_commits: u64,
    releases: u64,
    bank_cancellations: u64,
    bank_rejected_capacity: u64,
    bank_rejected_slots: u64,
    zero_orphan_ownership: bool,
};

pub const ResultV1 = struct {
    mode: ModeV1,
    scenario_sha256: Digest,
    outcome_sha256: Digest,
    trace_sha256: Digest,
    summary_sha256: Digest,
    summary: SummaryV1,
    outcomes: []const OutcomeV1,
    trace: []const TraceRecordV1,
};

pub const SchedulerV1 = qos.Scheduler;
pub const SchedulerAdmissionV1 = qos.Admission;
pub const SchedulerHandleV1 = qos.Handle;
pub const SchedulerServicePermitV1 = qos.ServicePermitV1;
pub const SchedulerEventV1 = qos.EventV1;

/// Driver callbacks may return scheduler errors unchanged. A callback that
/// encounters a family-specific failure stores its precise detail in
/// `DriverV1.context` and returns `DriverFailed`.
pub const DriverError = qos.Error || error{DriverFailed};

pub const DriverBindAdmittedV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: WorkItemV1,
    admission: SchedulerAdmissionV1,
};

pub const DriverCancelV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: WorkItemV1,
    handle: SchedulerHandleV1,
    terminal_action: TerminalActionV1,
};

pub const DriverCommitServiceV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: WorkItemV1,
    permit: SchedulerServicePermitV1,
    final_quantum: bool,
};

pub const DriverRetireV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: WorkItemV1,
    handle: SchedulerHandleV1,
    final_service_event: SchedulerEventV1,
};

/// Additive execution seam over the frozen workload V1 scenario/result wires.
///
/// `bind_admitted_fn` runs immediately after a successful admission while its
/// event is still the scheduler chain head. The remaining callbacks replace
/// the corresponding scheduler operation and must return the exact event
/// emitted by that scheduler. `cleanup_fn` runs only on an error path while
/// the scheduler and Bank are still live, allowing address-fenced extensions
/// to close bound sessions before the runner discards its coordinators. A
/// service callback may return an error with the original permit still
/// unarmed; the runner aborts that permit before cleanup. If the callback arms
/// the permit, it must either consume/abort its ticket before returning or
/// retain enough context for `cleanup_fn` to abort it. The default callbacks
/// only delegate to LaneWeave and therefore preserve the model-free V1
/// behavior.
pub const DriverV1 = struct {
    context: ?*anyopaque = null,
    bind_admitted_fn: *const fn (
        ?*anyopaque,
        *SchedulerV1,
        DriverBindAdmittedV1,
    ) DriverError!void = defaultBindAdmittedV1,
    cancel_fn: *const fn (
        ?*anyopaque,
        *SchedulerV1,
        DriverCancelV1,
    ) DriverError!SchedulerEventV1 = defaultCancelV1,
    commit_service_fn: *const fn (
        ?*anyopaque,
        *SchedulerV1,
        DriverCommitServiceV1,
    ) DriverError!SchedulerEventV1 = defaultCommitServiceV1,
    retire_fn: *const fn (
        ?*anyopaque,
        *SchedulerV1,
        DriverRetireV1,
    ) DriverError!SchedulerEventV1 = defaultRetireV1,
    cleanup_fn: *const fn (
        ?*anyopaque,
        *SchedulerV1,
    ) void = defaultCleanupV1,
};

const RuntimeItem = struct {
    state: RuntimeState = .pending,
    handle: qos.Handle = .{},
    admitted_step: u64 = absent_step,
    first_service_step: u64 = absent_step,
    terminal_step: u64 = absent_step,
    served_quanta: u64 = 0,
    fairness_quanta: u64 = 0,
    maximum_wait_quanta: u64 = 0,
    admission_trace_sha256: Digest = zero_digest,
    terminal_trace_sha256: Digest = zero_digest,
    outcome: ?OutcomeKindV1 = null,
    rejection_reason: qos.RejectionReason = .none,
    terminal_action: TerminalActionV1 = .none,
};

/// All mutable state remains in caller-owned fixed storage.
pub const StorageV1 = struct {
    bank_slots: []resource_bank.Slot,
    scheduler_slots: []qos.Slot,
    scheduler_projection: []qos.ProjectionSlot,
    verifier_slots: []qos.Slot,
    verifier_projection: []qos.ProjectionSlot,
    runtime_items: []RuntimeItem,
    outcomes: []OutcomeV1,
    trace: []TraceRecordV1,
};

pub const ReferenceStorageV1 = struct {
    bank_slots: [4]resource_bank.Slot = [_]resource_bank.Slot{.{}} ** 4,
    scheduler_slots: [4]qos.Slot = [_]qos.Slot{.{}} ** 4,
    scheduler_projection: [4]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** 4,
    verifier_slots: [4]qos.Slot = [_]qos.Slot{.{}} ** 4,
    verifier_projection: [4]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** 4,
    runtime_items: [7]RuntimeItem = [_]RuntimeItem{.{}} ** 7,
    outcomes: [7]OutcomeV1 = undefined,
    trace: [maximum_trace_records]TraceRecordV1 = undefined,

    pub fn interface(self: *ReferenceStorageV1) StorageV1 {
        return .{
            .bank_slots = &self.bank_slots,
            .scheduler_slots = &self.scheduler_slots,
            .scheduler_projection = &self.scheduler_projection,
            .verifier_slots = &self.verifier_slots,
            .verifier_projection = &self.verifier_projection,
            .runtime_items = &self.runtime_items,
            .outcomes = &self.outcomes,
            .trace = &self.trace,
        };
    }
};

comptime {
    if (media_decode_plan.plan_bytes + media_transform.transform_plan_bytes != 928)
        @compileError("reference media capsule claim changed");
    if (media_runtime.mapping_accounting_bytes != 128)
        @compileError("reference media mapping accounting changed");
    if (media_fixture.fixture_header_bytes + media_fixture.image_payload.len +
        media_fixture.fixture_footer_bytes != 364)
        @compileError("reference image fixture size changed");
    if (media_fixture.fixture_header_bytes + media_fixture.audio_payload.len +
        media_fixture.fixture_footer_bytes != 384)
        @compileError("reference audio fixture size changed");
    if (media_fixture.fixture_header_bytes + media_fixture.video_payload.len +
        media_fixture.fixture_footer_bytes != 360)
        @compileError("reference video fixture size changed");
}

pub fn imageClaimV1() resource_bank.Claim {
    return .{
        .capsule_bytes = 928,
        .activation_bytes = 12,
        .output_journal_bytes = 12,
        .staging_bytes = 512,
        .io_bytes = 364,
        .queue_slots = 1,
    };
}

pub fn audioClaimV1() resource_bank.Claim {
    return .{
        .capsule_bytes = 928,
        .activation_bytes = 32,
        .output_journal_bytes = 4,
        .staging_bytes = 256,
        .io_bytes = 384,
        .queue_slots = 1,
    };
}

pub fn videoClaimV1() resource_bank.Claim {
    return .{
        .capsule_bytes = 928,
        .activation_bytes = 8,
        .output_journal_bytes = 4,
        .staging_bytes = 128,
        .io_bytes = 360,
        .queue_slots = 1,
    };
}

fn profileForKindV1(kind: media.MediaKindV1) struct {
    family: model.ModelFamilyIdV1,
    operation: model.OperationIdV1,
    claim: resource_bank.Claim,
    sha256: Digest,
} {
    const family: model.ModelFamilyIdV1 = switch (kind) {
        .image => .vision_understanding,
        .audio => .audio_understanding,
        .video => .video_understanding,
    };
    const operation: model.OperationIdV1 = .encode;
    const claim = switch (kind) {
        .image => imageClaimV1(),
        .audio => audioClaimV1(),
        .video => videoClaimV1(),
    };
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(profile_domain);
    hashU64(&hash, profile_abi);
    hashU64(&hash, @intFromEnum(kind));
    hashU64(&hash, @intFromEnum(family));
    hashU64(&hash, @intFromEnum(operation));
    hashClaim(&hash, claim);
    var root: Digest = undefined;
    hash.final(&root);
    return .{
        .family = family,
        .operation = operation,
        .claim = claim,
        .sha256 = root,
    };
}

fn referenceItem(
    ordinal: u64,
    kind: media.MediaKindV1,
    arrival_step: u64,
    weight: u16,
    work_quanta: u64,
    deadline_tick: u64,
    action_step: u64,
    action: TerminalActionV1,
    fairness_member: bool,
) WorkItemV1 {
    const profile = profileForKindV1(kind);
    const identity = ordinal + 1;
    return .{
        .ordinal = ordinal,
        .family = profile.family,
        .operation = profile.operation,
        .media_kind = kind,
        .profile_sha256 = profile.sha256,
        .arrival_step = arrival_step,
        .weight = weight,
        .work_quanta = work_quanta,
        .deadline_tick = deadline_tick,
        .terminal_action_step = action_step,
        .terminal_action = action,
        .fairness_member = fairness_member,
        .tenant_key = 0x1000 + identity,
        .request_key = 0x2000 + identity,
        .request_generation = 1,
        .resource_owner_key = 0x3000 + identity,
        .claim = profile.claim,
    };
}

/// Retained seven-item image/audio/video pressure schedule.
pub fn makeReferenceItemsV1() [7]WorkItemV1 {
    return .{
        referenceItem(0, .image, 0, 1, 8, 64, 7, .cancel, true),
        referenceItem(1, .audio, 0, 2, 6, 64, absent_step, .none, true),
        referenceItem(2, .video, 0, 4, 12, 64, absent_step, .none, true),
        referenceItem(3, .audio, 0, 1, 8, 0, 3, .timeout, false),
        referenceItem(4, .video, 0, 2, 2, 0, absent_step, .none, false),
        referenceItem(5, .image, 4, 1, 2, 0, absent_step, .none, false),
        referenceItem(6, .image, 8, 1, 2, 64, absent_step, .none, false),
    };
}

pub fn referenceScenarioV1(items: []const WorkItemV1) ScenarioV1 {
    return .{
        .seed = 0x4757_5053_2026_0001,
        .max_driver_steps = 64,
        .fairness_start_tick = 0,
        .fairness_end_tick = 7,
        .bank_epoch = 0x4757_5042_0000_0001,
        .scheduler_epoch = 0x4757_5051_0000_0001,
        .max_weight = 4,
        .max_projection_quanta = 256,
        .max_projection_operations = 4096,
        .capacity = 4,
        .limits = .{
            .host_bytes = 4972,
            .queue_slots = 4,
        },
        .challenge = [_]u8{0x57} ** 32,
        .items = items,
    };
}

pub fn requiredScenarioBytesV1(item_count: usize) Error!usize {
    if (item_count == 0 or item_count > maximum_items)
        return Error.ItemLimitExceeded;
    const records = std.math.mul(
        usize,
        item_count,
        scenario_item_bytes,
    ) catch return Error.ArithmeticOverflow;
    const with_header = std.math.add(
        usize,
        scenario_header_bytes,
        records,
    ) catch return Error.ArithmeticOverflow;
    return std.math.add(
        usize,
        with_header,
        scenario_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn requiredResultBytesV1(
    item_count: usize,
    trace_count: usize,
) Error!usize {
    if (item_count == 0 or item_count > maximum_items)
        return Error.ItemLimitExceeded;
    if (trace_count == 0 or trace_count > maximum_trace_records)
        return Error.TraceLimitExceeded;
    const outcomes_bytes = std.math.mul(
        usize,
        item_count,
        outcome_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    const traces_bytes = std.math.mul(
        usize,
        trace_count,
        trace_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    var total = std.math.add(
        usize,
        result_header_bytes,
        outcomes_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = std.math.add(usize, total, traces_bytes) catch
        return Error.ArithmeticOverflow;
    return std.math.add(usize, total, result_footer_bytes) catch
        return Error.ArithmeticOverflow;
}

pub fn scenarioSha256V1(scenario: ScenarioV1) Error!Digest {
    try validateScenarioV1(scenario);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(scenario_domain);
    hashU64(&hash, scenario_abi);
    hashU64(&hash, @intFromEnum(scenario.mode));
    hashU64(&hash, scenario.seed);
    hashU64(&hash, scenario.max_driver_steps);
    hashU64(&hash, scenario.fairness_start_tick);
    hashU64(&hash, scenario.fairness_end_tick);
    hashU64(&hash, scenario.bank_epoch);
    hashU64(&hash, scenario.scheduler_epoch);
    hashU64(&hash, scenario.max_weight);
    hashU64(&hash, scenario.max_projection_quanta);
    hashU64(&hash, scenario.max_projection_operations);
    hashU64(&hash, scenario.capacity);
    hashLimits(&hash, scenario.limits);
    hash.update(&scenario.challenge);
    hashU64(&hash, scenario.items.len);
    for (scenario.items) |item| {
        const item_root = itemSha256V1(item);
        hash.update(&item_root);
    }
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn encodeScenarioV1(
    scenario: ScenarioV1,
    destination: []u8,
) Error![]const u8 {
    try validateScenarioV1(scenario);
    const needed = try requiredScenarioBytesV1(scenario.items.len);
    if (destination.len < needed) return Error.BufferTooSmall;
    const output = destination[0..needed];
    @memset(output, 0);
    @memcpy(output[0..8], &scenario_magic);
    writeU64(output, 8, scenario_abi);
    writeU64(output, 16, needed);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(scenario.mode));
    writeU64(output, 40, scenario.seed);
    writeU64(output, 48, scenario.max_driver_steps);
    writeU64(output, 56, scenario.fairness_start_tick);
    writeU64(output, 64, scenario.fairness_end_tick);
    writeU64(output, 72, scenario.bank_epoch);
    writeU64(output, 80, scenario.scheduler_epoch);
    writeU64(output, 88, scenario.max_weight);
    writeU64(output, 96, scenario.max_projection_quanta);
    writeU64(output, 104, scenario.max_projection_operations);
    writeU64(output, 112, scenario.capacity);
    writeU64(output, 120, scenario.items.len);
    writeLimits(output, 128, scenario.limits);
    @memcpy(output[216..248], &scenario.challenge);

    for (scenario.items, 0..) |item, index| {
        const offset = scenario_header_bytes + index * scenario_item_bytes;
        writeScenarioItem(output[offset..][0..scenario_item_bytes], item);
    }
    const root = try scenarioSha256V1(scenario);
    @memcpy(output[needed - scenario_footer_bytes ..], &root);
    return output;
}

pub fn decodeScenarioV1(
    encoded: []const u8,
    item_storage: []WorkItemV1,
) Error!ScenarioV1 {
    if (encoded.len < scenario_header_bytes + scenario_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &scenario_magic) or
        readU64(encoded, 8) != scenario_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != allowed_flags or
        readU64(encoded, 248) != 0)
        return Error.InvalidEvidence;
    const item_count = std.math.cast(usize, readU64(encoded, 120)) orelse
        return Error.InvalidEvidence;
    const expected_bytes = requiredScenarioBytesV1(item_count) catch
        return Error.InvalidEvidence;
    if (encoded.len != expected_bytes or item_storage.len < item_count)
        return Error.InvalidEvidence;

    var footer: Digest = undefined;
    @memcpy(&footer, encoded[encoded.len - scenario_footer_bytes ..]);

    var temporary: [maximum_items]WorkItemV1 = undefined;
    for (0..item_count) |index| {
        const offset = scenario_header_bytes + index * scenario_item_bytes;
        temporary[index] = decodeScenarioItem(
            encoded[offset..][0..scenario_item_bytes],
        ) catch return Error.InvalidEvidence;
    }
    const mode = std.meta.intToEnum(
        ModeV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidEvidence;
    const max_weight = std.math.cast(u16, readU64(encoded, 88)) orelse
        return Error.InvalidEvidence;
    const capacity = std.math.cast(u32, readU64(encoded, 112)) orelse
        return Error.InvalidEvidence;
    var challenge: Digest = undefined;
    @memcpy(&challenge, encoded[216..248]);
    const temporary_scenario: ScenarioV1 = .{
        .mode = mode,
        .seed = readU64(encoded, 40),
        .max_driver_steps = readU64(encoded, 48),
        .fairness_start_tick = readU64(encoded, 56),
        .fairness_end_tick = readU64(encoded, 64),
        .bank_epoch = readU64(encoded, 72),
        .scheduler_epoch = readU64(encoded, 80),
        .max_weight = max_weight,
        .max_projection_quanta = readU64(encoded, 96),
        .max_projection_operations = readU64(encoded, 104),
        .capacity = capacity,
        .limits = readLimits(encoded, 128),
        .challenge = challenge,
        .items = temporary[0..item_count],
    };
    validateScenarioV1(temporary_scenario) catch
        return Error.InvalidEvidence;
    const semantic_root = scenarioSha256V1(temporary_scenario) catch
        return Error.InvalidEvidence;
    if (!std.mem.eql(u8, &footer, &semantic_root))
        return Error.InvalidEvidence;
    @memcpy(item_storage[0..item_count], temporary[0..item_count]);
    return .{
        .mode = temporary_scenario.mode,
        .seed = temporary_scenario.seed,
        .max_driver_steps = temporary_scenario.max_driver_steps,
        .fairness_start_tick = temporary_scenario.fairness_start_tick,
        .fairness_end_tick = temporary_scenario.fairness_end_tick,
        .bank_epoch = temporary_scenario.bank_epoch,
        .scheduler_epoch = temporary_scenario.scheduler_epoch,
        .max_weight = temporary_scenario.max_weight,
        .max_projection_quanta = temporary_scenario.max_projection_quanta,
        .max_projection_operations = temporary_scenario.max_projection_operations,
        .capacity = temporary_scenario.capacity,
        .limits = temporary_scenario.limits,
        .challenge = temporary_scenario.challenge,
        .items = item_storage[0..item_count],
    };
}

fn defaultBindAdmittedV1(
    context: ?*anyopaque,
    scheduler: *SchedulerV1,
    input: DriverBindAdmittedV1,
) DriverError!void {
    _ = context;
    _ = scheduler;
    _ = input;
}

fn defaultCancelV1(
    context: ?*anyopaque,
    scheduler: *SchedulerV1,
    input: DriverCancelV1,
) DriverError!SchedulerEventV1 {
    _ = context;
    return scheduler.cancel(input.handle);
}

fn defaultCommitServiceV1(
    context: ?*anyopaque,
    scheduler: *SchedulerV1,
    input: DriverCommitServiceV1,
) DriverError!SchedulerEventV1 {
    _ = context;
    return scheduler.commitService(input.permit);
}

fn defaultRetireV1(
    context: ?*anyopaque,
    scheduler: *SchedulerV1,
    input: DriverRetireV1,
) DriverError!SchedulerEventV1 {
    _ = context;
    return scheduler.retire(input.handle);
}

fn defaultCleanupV1(
    context: ?*anyopaque,
    scheduler: *SchedulerV1,
) void {
    _ = context;
    _ = scheduler;
}

fn requireCurrentDriverEventV1(
    scheduler: *SchedulerV1,
    event: SchedulerEventV1,
) Error!void {
    const snapshot = try scheduler.snapshot();
    if (event.event_sequence == std.math.maxInt(u64) or
        event.scheduler_epoch != snapshot.scheduler_epoch or
        event.event_sequence + 1 != snapshot.next_event_sequence or
        !std.mem.eql(
            u8,
            &event.event_sha256,
            &qos.eventSha256(event),
        ) or
        !std.mem.eql(
            u8,
            &event.event_sha256,
            &snapshot.chain_head_sha256,
        ) or
        event.logical_tick_after != snapshot.logical_tick or
        event.cursor_after != snapshot.cursor or
        event.level_after != snapshot.level or
        event.active_after != snapshot.active or
        event.finished_after != snapshot.finished or
        !std.meta.eql(event.bank_used_after, snapshot.used) or
        event.maximum_service_gap != snapshot.maximum_service_gap or
        snapshot.poisoned or snapshot.closed)
        return Error.DriverFailed;
}

/// Runs the frozen model-free campaign through the built-in LaneWeave driver.
/// This compatibility entry point preserves the exact V1 result roots.
pub fn runScenarioV1(
    scenario: ScenarioV1,
    storage: StorageV1,
) Error!ResultV1 {
    return runScenarioWithDriverV1(scenario, storage, .{});
}

/// Runs a V1 scenario while allowing a caller-owned lifecycle driver to bind
/// and finalize the exact scheduler receipts. The scenario/result formats and
/// logical summary rules are unchanged; driver-specific evidence belongs in a
/// separate additive contract.
pub fn runScenarioWithDriverV1(
    scenario: ScenarioV1,
    storage: StorageV1,
    driver: DriverV1,
) Error!ResultV1 {
    try validateScenarioV1(scenario);
    const capacity: usize = @intCast(scenario.capacity);
    if (storage.bank_slots.len < capacity or
        storage.scheduler_slots.len < capacity or
        storage.scheduler_projection.len < capacity or
        storage.verifier_slots.len < capacity or
        storage.verifier_projection.len < capacity or
        storage.runtime_items.len < scenario.items.len or
        storage.outcomes.len < scenario.items.len or
        storage.trace.len < maximum_trace_records)
        return Error.BufferTooSmall;

    const bank_slots = storage.bank_slots[0..capacity];
    const scheduler_slots = storage.scheduler_slots[0..capacity];
    const scheduler_projection = storage.scheduler_projection[0..capacity];
    const verifier_slots = storage.verifier_slots[0..capacity];
    const verifier_projection = storage.verifier_projection[0..capacity];
    const runtime_items = storage.runtime_items[0..scenario.items.len];
    for (runtime_items) |*runtime_item| runtime_item.* = .{};

    var bank = try resource_bank.Bank.init(
        bank_slots,
        scenario.limits,
        scenario.bank_epoch,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = scheduler_slots,
            .projection = scheduler_projection,
        },
        .{
            .scheduler_epoch = scenario.scheduler_epoch,
            .challenge = scenario.challenge,
            .max_weight = scenario.max_weight,
            .max_projection_quanta = scenario.max_projection_quanta,
            .max_projection_operations = scenario.max_projection_operations,
        },
    );
    var verifier = try qos.Verifier.init(
        .{
            .slots = verifier_slots,
            .projection = verifier_projection,
        },
        scheduler.config,
        scheduler.bank_epoch,
        scheduler.limits,
    );
    var driver_service_permit: ?SchedulerServicePermitV1 = null;
    errdefer {
        if (driver_service_permit) |permit|
            _ = scheduler.abortService(permit) catch {};
        driver.cleanup_fn(driver.context, &scheduler);
        for (runtime_items) |runtime_item| {
            if (runtime_item.state != .active) continue;
            if (scheduler.cancel(runtime_item.handle)) |_| {} else |_| {
                // A driver can commit the final service quantum and then fail
                // before returning its event. In that case the runner still
                // records the item as active while LaneWeave records it as
                // finished, so cancellation is inapplicable and retirement
                // is the only valid unbound cleanup.
                _ = scheduler.retire(runtime_item.handle) catch {};
            }
        }
    }

    var trace_count: usize = 0;
    var maximum_live_receipts: u64 = 0;
    var driver_steps: u64 = 0;
    var completed = false;
    var step: u64 = 0;
    while (step < scenario.max_driver_steps) : (step += 1) {
        for (scenario.items, 0..) |item, index| {
            if (item.arrival_step != step) continue;
            if (runtime_items[index].state != .pending)
                return Error.InvalidScenario;
            const decision = try scheduler.admit(requestSpecV1(item));
            switch (decision) {
                .admitted => |admission| {
                    // Stage ownership before the extension callback. If the
                    // callback fails, error cleanup must still see and release
                    // this already-committed Scheduler/Bank admission.
                    runtime_items[index].state = .active;
                    runtime_items[index].handle = admission.handle;
                    runtime_items[index].admitted_step = step;
                    try driver.bind_admitted_fn(
                        driver.context,
                        &scheduler,
                        .{
                            .driver_step = step,
                            .item_index = index,
                            .item = item,
                            .admission = admission,
                        },
                    );
                    try requireCurrentDriverEventV1(
                        &scheduler,
                        admission.event,
                    );
                    const admission_snapshot = try bank.snapshot();
                    maximum_live_receipts = @max(
                        maximum_live_receipts,
                        @as(
                            u64,
                            @intCast(admission_snapshot.committed_receipts),
                        ),
                    );
                    try verifier.apply(admission.event);
                    runtime_items[index].admission_trace_sha256 =
                        try appendTrace(
                            storage.trace,
                            &trace_count,
                            step,
                            item.ordinal,
                            .none,
                            admission.event,
                        );
                },
                .rejected => |event| {
                    runtime_items[index].state = .terminal;
                    runtime_items[index].outcome = .rejected;
                    runtime_items[index].rejection_reason =
                        event.rejection_reason;
                    runtime_items[index].terminal_step = step;
                    try verifier.apply(event);
                    const trace_root = try appendTrace(
                        storage.trace,
                        &trace_count,
                        step,
                        item.ordinal,
                        .none,
                        event,
                    );
                    runtime_items[index].admission_trace_sha256 = trace_root;
                    runtime_items[index].terminal_trace_sha256 = trace_root;
                },
            }
        }

        for (scenario.items, 0..) |item, index| {
            if (item.terminal_action_step != step) continue;
            const runtime_item = &runtime_items[index];
            if (runtime_item.state != .active or
                item.terminal_action == .none)
                return Error.UnexpectedTerminalAction;
            const event = try driver.cancel_fn(
                driver.context,
                &scheduler,
                .{
                    .driver_step = step,
                    .item_index = index,
                    .item = item,
                    .handle = runtime_item.handle,
                    .terminal_action = item.terminal_action,
                },
            );
            if (event.kind != .cancel or
                !std.meta.eql(event.handle, runtime_item.handle))
                return Error.DriverFailed;
            try requireCurrentDriverEventV1(&scheduler, event);
            runtime_item.state = .terminal;
            runtime_item.terminal_step = step;
            runtime_item.terminal_action = item.terminal_action;
            runtime_item.outcome = switch (item.terminal_action) {
                .cancel => .cancelled,
                .timeout => .timed_out,
                .none => unreachable,
            };
            try verifier.apply(event);
            runtime_item.terminal_trace_sha256 = try appendTrace(
                storage.trace,
                &trace_count,
                step,
                item.ordinal,
                item.terminal_action,
                event,
            );
        }

        const before_service = try scheduler.snapshot();
        if (before_service.active != 0) {
            const permit = try scheduler.prepareService();
            driver_service_permit = permit;
            const permit_index = try findItemByHandle(
                scenario.items,
                runtime_items,
                permit.handle,
            );
            const event = try driver.commit_service_fn(
                driver.context,
                &scheduler,
                .{
                    .driver_step = step,
                    .item_index = permit_index,
                    .item = scenario.items[permit_index],
                    .permit = permit,
                    .final_quantum = permit.remaining_before == 1,
                },
            );
            if (event.kind != .service or
                !std.meta.eql(event.handle, permit.handle) or
                event.remaining_before != permit.remaining_before or
                (event.remaining_after == 0) !=
                    (permit.remaining_before == 1))
                return Error.DriverFailed;
            try requireCurrentDriverEventV1(&scheduler, event);
            driver_service_permit = null;
            const index = permit_index;
            const runtime_item = &runtime_items[index];
            if (runtime_item.first_service_step == absent_step)
                runtime_item.first_service_step = step;
            runtime_item.served_quanta = try checkedAdd(
                runtime_item.served_quanta,
                1,
            );
            runtime_item.maximum_wait_quanta = @max(
                runtime_item.maximum_wait_quanta,
                event.wait_quanta,
            );
            if (scenario.items[index].fairness_member and
                event.logical_tick_after > scenario.fairness_start_tick and
                event.logical_tick_after <= scenario.fairness_end_tick)
                runtime_item.fairness_quanta = try checkedAdd(
                    runtime_item.fairness_quanta,
                    1,
                );
            try verifier.apply(event);
            _ = try appendTrace(
                storage.trace,
                &trace_count,
                step,
                scenario.items[index].ordinal,
                .none,
                event,
            );
            if (event.remaining_after == 0) {
                const retire_event = try driver.retire_fn(
                    driver.context,
                    &scheduler,
                    .{
                        .driver_step = step,
                        .item_index = index,
                        .item = scenario.items[index],
                        .handle = runtime_item.handle,
                        .final_service_event = event,
                    },
                );
                if (retire_event.kind != .retire or
                    !std.meta.eql(
                        retire_event.handle,
                        runtime_item.handle,
                    ))
                    return Error.DriverFailed;
                try requireCurrentDriverEventV1(
                    &scheduler,
                    retire_event,
                );
                runtime_item.state = .terminal;
                runtime_item.outcome = .completed;
                runtime_item.terminal_step = step;
                try verifier.apply(retire_event);
                runtime_item.terminal_trace_sha256 = try appendTrace(
                    storage.trace,
                    &trace_count,
                    step,
                    scenario.items[index].ordinal,
                    .none,
                    retire_event,
                );
            }
        }

        const snapshot = try bank.snapshot();
        maximum_live_receipts = @max(
            maximum_live_receipts,
            @as(u64, @intCast(snapshot.committed_receipts)),
        );
        if (allTerminal(runtime_items)) {
            driver_steps = step + 1;
            completed = true;
            break;
        }
    }
    if (!completed) return Error.DriverStepLimitExceeded;

    const close_event = try scheduler.close();
    try verifier.apply(close_event);
    _ = try appendTrace(
        storage.trace,
        &trace_count,
        driver_steps,
        absent_item,
        .none,
        close_event,
    );
    _ = try verifier.finish(
        close_event.event_sha256,
    );
    const scheduler_final = try scheduler.snapshot();
    const bank_final = try bank.snapshot();

    for (scenario.items, runtime_items, storage.outcomes[0..scenario.items.len]) |
        item,
        runtime_item,
        *outcome,
    | {
        const kind = runtime_item.outcome orelse
            return Error.IncompleteScenario;
        outcome.* = .{
            .ordinal = item.ordinal,
            .kind = kind,
            .rejection_reason = runtime_item.rejection_reason,
            .terminal_action = runtime_item.terminal_action,
            .admitted_step = runtime_item.admitted_step,
            .first_service_step = runtime_item.first_service_step,
            .terminal_step = runtime_item.terminal_step,
            .served_quanta = runtime_item.served_quanta,
            .maximum_wait_quanta = runtime_item.maximum_wait_quanta,
            .queue_delay_steps = if (runtime_item.first_service_step != absent_step)
                runtime_item.first_service_step - item.arrival_step
            else
                absent_step,
            .completion_delay_steps = if (kind == .completed)
                runtime_item.terminal_step - item.arrival_step
            else
                absent_step,
            .admission_trace_sha256 = runtime_item.admission_trace_sha256,
            .terminal_trace_sha256 = runtime_item.terminal_trace_sha256,
        };
    }

    const outcomes = storage.outcomes[0..scenario.items.len];
    const trace = storage.trace[0..trace_count];
    const summary = try summarizeV1(
        scenario,
        runtime_items,
        outcomes,
        trace,
        driver_steps,
        maximum_live_receipts,
        scheduler.maximum_service_gap,
        scheduler_final,
        bank_final,
    );
    const trace_sha256 = traceSha256V1(trace);
    const outcome_sha256 = outcomeSha256V1(outcomes);
    const summary_sha256 = summarySha256V1(summary);
    const result: ResultV1 = .{
        .mode = scenario.mode,
        .scenario_sha256 = try scenarioSha256V1(scenario),
        .outcome_sha256 = outcome_sha256,
        .trace_sha256 = trace_sha256,
        .summary_sha256 = summary_sha256,
        .summary = summary,
        .outcomes = outcomes,
        .trace = trace,
    };
    try validateResultAgainstScenarioV1(scenario, result);
    return result;
}

pub fn encodeResultV1(
    result: ResultV1,
    destination: []u8,
) Error![]const u8 {
    try validateResultStructureV1(result);
    const needed = try requiredResultBytesV1(
        result.outcomes.len,
        result.trace.len,
    );
    if (destination.len < needed) return Error.BufferTooSmall;
    const output = destination[0..needed];
    @memset(output, 0);
    @memcpy(output[0..8], &result_magic);
    writeU64(output, 8, result_abi);
    writeU64(output, 16, needed);
    writeU64(output, 24, allowed_flags);
    writeU64(output, 32, @intFromEnum(result.mode));
    writeU64(output, 40, result.outcomes.len);
    writeU64(output, 48, result.trace.len);
    writeSummaryHeader(output, result.summary);
    @memcpy(output[312..344], &result.scenario_sha256);
    @memcpy(output[344..376], &result.outcome_sha256);
    @memcpy(output[376..408], &result.trace_sha256);
    @memcpy(output[408..440], &result.summary_sha256);
    writeClaim(output, 440, result.summary.peak);

    var offset = result_header_bytes;
    for (result.outcomes) |outcome| {
        writeOutcomeRecord(
            output[offset..][0..outcome_record_bytes],
            outcome,
        );
        offset += outcome_record_bytes;
    }
    for (result.trace) |record| {
        writeTraceRecord(
            output[offset..][0..trace_record_bytes],
            record,
        );
        offset += trace_record_bytes;
    }
    const root = resultBodySha256(output[0 .. needed - 32]);
    @memcpy(output[needed - 32 ..], &root);
    return output;
}

pub fn decodeResultV1(
    encoded: []const u8,
    outcome_storage: []OutcomeV1,
    trace_storage: []TraceRecordV1,
) Error!ResultV1 {
    if (encoded.len < result_header_bytes + result_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &result_magic) or
        readU64(encoded, 8) != result_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != allowed_flags)
        return Error.InvalidEvidence;
    for (304..312) |index| {
        if (encoded[index] != 0) return Error.InvalidEvidence;
    }
    for (520..result_header_bytes) |index| {
        if (encoded[index] != 0) return Error.InvalidEvidence;
    }
    const outcome_count = std.math.cast(usize, readU64(encoded, 40)) orelse
        return Error.InvalidEvidence;
    const trace_count = std.math.cast(usize, readU64(encoded, 48)) orelse
        return Error.InvalidEvidence;
    const expected = requiredResultBytesV1(
        outcome_count,
        trace_count,
    ) catch return Error.InvalidEvidence;
    if (encoded.len != expected or
        outcome_storage.len < outcome_count or
        trace_storage.len < trace_count)
        return Error.InvalidEvidence;
    var footer: Digest = undefined;
    @memcpy(&footer, encoded[encoded.len - 32 ..]);
    const expected_footer = resultBodySha256(encoded[0 .. encoded.len - 32]);
    if (!std.mem.eql(u8, &footer, &expected_footer))
        return Error.InvalidEvidence;

    var temporary_outcomes: [maximum_items]OutcomeV1 = undefined;
    var temporary_trace: [maximum_trace_records]TraceRecordV1 = undefined;
    var offset = result_header_bytes;
    for (0..outcome_count) |index| {
        temporary_outcomes[index] = decodeOutcomeRecord(
            encoded[offset..][0..outcome_record_bytes],
        ) catch return Error.InvalidEvidence;
        offset += outcome_record_bytes;
    }
    for (0..trace_count) |index| {
        temporary_trace[index] = decodeTraceRecord(
            encoded[offset..][0..trace_record_bytes],
        ) catch return Error.InvalidEvidence;
        offset += trace_record_bytes;
    }
    const mode = std.meta.intToEnum(
        ModeV1,
        readU64(encoded, 32),
    ) catch return Error.InvalidEvidence;
    var scenario_root: Digest = undefined;
    var outcome_root: Digest = undefined;
    var trace_root: Digest = undefined;
    var summary_root: Digest = undefined;
    @memcpy(&scenario_root, encoded[312..344]);
    @memcpy(&outcome_root, encoded[344..376]);
    @memcpy(&trace_root, encoded[376..408]);
    @memcpy(&summary_root, encoded[408..440]);
    const summary = readSummaryHeader(encoded);
    if (!std.mem.eql(
        u8,
        &outcome_root,
        &outcomeSha256V1(temporary_outcomes[0..outcome_count]),
    ) or !std.mem.eql(
        u8,
        &trace_root,
        &traceSha256V1(temporary_trace[0..trace_count]),
    ) or !std.mem.eql(
        u8,
        &summary_root,
        &summarySha256V1(summary),
    )) return Error.InvalidEvidence;

    const temporary_result: ResultV1 = .{
        .mode = mode,
        .scenario_sha256 = scenario_root,
        .outcome_sha256 = outcome_root,
        .trace_sha256 = trace_root,
        .summary_sha256 = summary_root,
        .summary = summary,
        .outcomes = temporary_outcomes[0..outcome_count],
        .trace = temporary_trace[0..trace_count],
    };
    validateResultStructureV1(temporary_result) catch
        return Error.InvalidEvidence;
    @memcpy(
        outcome_storage[0..outcome_count],
        temporary_outcomes[0..outcome_count],
    );
    @memcpy(
        trace_storage[0..trace_count],
        temporary_trace[0..trace_count],
    );
    return .{
        .mode = temporary_result.mode,
        .scenario_sha256 = temporary_result.scenario_sha256,
        .outcome_sha256 = temporary_result.outcome_sha256,
        .trace_sha256 = temporary_result.trace_sha256,
        .summary_sha256 = temporary_result.summary_sha256,
        .summary = temporary_result.summary,
        .outcomes = outcome_storage[0..outcome_count],
        .trace = trace_storage[0..trace_count],
    };
}

/// Validates the result wire's canonical roots and scenario-derived aggregate
/// projection. Use `validateResultByReplayV1` when exact trace identity is
/// required.
pub fn validateResultAgainstScenarioV1(
    scenario: ScenarioV1,
    result: ResultV1,
) Error!void {
    try validateScenarioV1(scenario);
    try validateResultStructureV1(result);
    const scenario_root = try scenarioSha256V1(scenario);
    if (!std.mem.eql(u8, &scenario_root, &result.scenario_sha256) or
        result.mode != scenario.mode or
        result.outcomes.len != scenario.items.len)
        return Error.InvalidEvidence;

    var admitted: u64 = 0;
    var rejected: u64 = 0;
    var completed_count: u64 = 0;
    var cancelled: u64 = 0;
    var timed_out: u64 = 0;
    var service_quanta: u64 = 0;
    var queue_values: [maximum_items]u64 = undefined;
    var queue_count: usize = 0;
    var completion_values: [maximum_items]u64 = undefined;
    var completion_count: usize = 0;
    var maximum_wait: u64 = 0;
    for (scenario.items, result.outcomes, 0..) |item, outcome, index| {
        if (outcome.ordinal != item.ordinal or item.ordinal != index)
            return Error.InvalidEvidence;
        service_quanta = checkedAdd(
            service_quanta,
            outcome.served_quanta,
        ) catch return Error.InvalidEvidence;
        maximum_wait = @max(maximum_wait, outcome.maximum_wait_quanta);
        switch (outcome.kind) {
            .rejected => {
                rejected += 1;
                if (outcome.admitted_step != absent_step or
                    outcome.first_service_step != absent_step or
                    outcome.queue_delay_steps != absent_step or
                    outcome.completion_delay_steps != absent_step or
                    outcome.rejection_reason == .none or
                    outcome.terminal_action != .none or
                    outcome.served_quanta != 0)
                    return Error.InvalidEvidence;
            },
            .completed => {
                admitted += 1;
                completed_count += 1;
                if (outcome.rejection_reason != .none or
                    outcome.terminal_action != .none or
                    outcome.admitted_step != item.arrival_step or
                    outcome.first_service_step == absent_step or
                    outcome.completion_delay_steps ==
                        absent_step)
                    return Error.InvalidEvidence;
                completion_values[completion_count] =
                    outcome.completion_delay_steps;
                completion_count += 1;
            },
            .cancelled => {
                admitted += 1;
                cancelled += 1;
                if (outcome.terminal_action != .cancel or
                    item.terminal_action != .cancel or
                    outcome.rejection_reason != .none)
                    return Error.InvalidEvidence;
            },
            .timed_out => {
                admitted += 1;
                timed_out += 1;
                if (outcome.terminal_action != .timeout or
                    item.terminal_action != .timeout or
                    outcome.rejection_reason != .none)
                    return Error.InvalidEvidence;
            },
        }
        if (outcome.first_service_step != absent_step) {
            if (outcome.first_service_step < item.arrival_step or
                outcome.queue_delay_steps !=
                    outcome.first_service_step - item.arrival_step)
                return Error.InvalidEvidence;
            queue_values[queue_count] = outcome.queue_delay_steps;
            queue_count += 1;
        }
        if (outcome.terminal_step < item.arrival_step)
            return Error.InvalidEvidence;
        var admission_trace_root: ?Digest = null;
        var terminal_trace_root: ?Digest = null;
        for (result.trace) |record| {
            if (record.item_ordinal != item.ordinal) continue;
            switch (record.event_kind) {
                .admission_accepted => {
                    if (admission_trace_root != null)
                        return Error.InvalidEvidence;
                    admission_trace_root = record.record_sha256;
                },
                .admission_rejected => {
                    if (admission_trace_root != null or
                        terminal_trace_root != null)
                        return Error.InvalidEvidence;
                    admission_trace_root = record.record_sha256;
                    terminal_trace_root = record.record_sha256;
                },
                .cancel, .retire => {
                    if (terminal_trace_root != null)
                        return Error.InvalidEvidence;
                    terminal_trace_root = record.record_sha256;
                },
                .service => {},
                .close => return Error.InvalidEvidence,
            }
        }
        if (admission_trace_root == null or terminal_trace_root == null or
            !std.mem.eql(
                u8,
                &admission_trace_root.?,
                &outcome.admission_trace_sha256,
            ) or
            !std.mem.eql(
                u8,
                &terminal_trace_root.?,
                &outcome.terminal_trace_sha256,
            ))
            return Error.InvalidEvidence;
    }
    var trace_services: u64 = 0;
    for (result.trace) |record| {
        if (record.event_kind == .service) trace_services += 1;
    }
    if (trace_services != service_quanta or
        result.summary.admitted != admitted or
        result.summary.rejected != rejected or
        result.summary.completed != completed_count or
        result.summary.cancelled != cancelled or
        result.summary.timed_out != timed_out or
        result.summary.service_quanta != service_quanta or
        result.summary.maximum_wait_quanta != maximum_wait or
        result.summary.queue_delay_p50_steps !=
            nearestRank(queue_values[0..queue_count], 50) or
        result.summary.queue_delay_p95_steps !=
            nearestRank(queue_values[0..queue_count], 95) or
        result.summary.queue_delay_p99_steps !=
            nearestRank(queue_values[0..queue_count], 99) or
        result.summary.queue_delay_max_steps !=
            maximumValue(queue_values[0..queue_count]) or
        result.summary.completion_delay_p50_steps !=
            nearestRank(completion_values[0..completion_count], 50) or
        result.summary.completion_delay_p95_steps !=
            nearestRank(completion_values[0..completion_count], 95) or
        result.summary.completion_delay_p99_steps !=
            nearestRank(completion_values[0..completion_count], 99) or
        result.summary.completion_delay_max_steps !=
            maximumValue(completion_values[0..completion_count]))
        return Error.InvalidEvidence;
}

/// Replays the scenario into caller-owned scratch storage and requires exact
/// equality for every outcome, trace record, aggregate, and canonical root.
/// The bounded snapshots make this safe even when `storage` aliases `result`.
pub fn validateResultByReplayV1(
    scenario: ScenarioV1,
    result: ResultV1,
    storage: StorageV1,
) Error!void {
    try validateResultAgainstScenarioV1(scenario, result);

    const actual_mode = result.mode;
    const actual_scenario_sha256 = result.scenario_sha256;
    const actual_outcome_sha256 = result.outcome_sha256;
    const actual_trace_sha256 = result.trace_sha256;
    const actual_summary_sha256 = result.summary_sha256;
    const actual_summary = result.summary;
    var actual_outcomes: [maximum_items]OutcomeV1 = undefined;
    var actual_trace: [maximum_trace_records]TraceRecordV1 = undefined;
    @memcpy(
        actual_outcomes[0..result.outcomes.len],
        result.outcomes,
    );
    @memcpy(
        actual_trace[0..result.trace.len],
        result.trace,
    );
    const actual_outcome_count = result.outcomes.len;
    const actual_trace_count = result.trace.len;

    const expected = try runScenarioV1(scenario, storage);
    if (actual_mode != expected.mode or
        !std.mem.eql(
            u8,
            &actual_scenario_sha256,
            &expected.scenario_sha256,
        ) or
        !std.mem.eql(
            u8,
            &actual_outcome_sha256,
            &expected.outcome_sha256,
        ) or
        !std.mem.eql(
            u8,
            &actual_trace_sha256,
            &expected.trace_sha256,
        ) or
        !std.mem.eql(
            u8,
            &actual_summary_sha256,
            &expected.summary_sha256,
        ) or
        !std.meta.eql(actual_summary, expected.summary) or
        actual_outcome_count != expected.outcomes.len or
        actual_trace_count != expected.trace.len)
        return Error.InvalidEvidence;

    for (
        actual_outcomes[0..actual_outcome_count],
        expected.outcomes,
    ) |actual, expected_outcome| {
        if (!std.meta.eql(actual, expected_outcome))
            return Error.InvalidEvidence;
    }
    for (
        actual_trace[0..actual_trace_count],
        expected.trace,
    ) |actual, expected_record| {
        if (!std.meta.eql(actual, expected_record))
            return Error.InvalidEvidence;
    }
}

pub fn validateScenarioV1(scenario: ScenarioV1) Error!void {
    if (scenario.mode != .explicit_open_loop or
        scenario.seed == 0 or
        scenario.max_driver_steps == 0 or
        scenario.max_driver_steps > maximum_driver_steps or
        scenario.fairness_end_tick <= scenario.fairness_start_tick or
        scenario.bank_epoch == 0 or scenario.scheduler_epoch == 0 or
        scenario.max_weight == 0 or
        scenario.max_projection_quanta == 0 or
        scenario.max_projection_operations == 0 or
        scenario.capacity == 0 or
        scenario.capacity > maximum_items or
        scenario.items.len == 0 or
        scenario.items.len > maximum_items or
        std.mem.eql(u8, &scenario.challenge, &zero_digest))
        return Error.InvalidScenario;
    if (scenario.limits.queue_slots < scenario.capacity)
        return Error.InvalidScenario;
    var total_quanta: u64 = 0;
    var previous_arrival: u64 = 0;
    var fairness_members: usize = 0;
    for (scenario.items, 0..) |item, index| {
        if (item.ordinal != index or
            item.arrival_step >= scenario.max_driver_steps or
            (item.terminal_action != .none and
                item.terminal_action_step >= scenario.max_driver_steps) or
            (index != 0 and item.arrival_step < previous_arrival))
            return Error.InvalidScenario;
        previous_arrival = item.arrival_step;
        try validateWorkItemV1(item, scenario.max_weight);
        total_quanta = try checkedAdd(total_quanta, item.work_quanta);
        if (item.fairness_member) fairness_members += 1;
        for (scenario.items[0..index]) |prior| {
            if (prior.tenant_key == item.tenant_key or
                prior.request_key == item.request_key or
                prior.resource_owner_key == item.resource_owner_key)
                return Error.InvalidScenario;
        }
    }
    const maximum_item_events = std.math.mul(
        u64,
        @as(u64, @intCast(scenario.items.len)),
        2,
    ) catch return Error.ArithmeticOverflow;
    const maximum_evidence_records = try checkedAdd(
        try checkedAdd(total_quanta, maximum_item_events),
        1,
    );
    if (total_quanta > maximum_service_quanta or
        maximum_evidence_records > maximum_trace_records or
        fairness_members < 2)
        return Error.InvalidScenario;
}

fn validateWorkItemV1(item: WorkItemV1, max_weight: u16) Error!void {
    if (item.weight == 0 or item.weight > max_weight or
        item.work_quanta == 0 or
        item.tenant_key == 0 or item.request_key == 0 or
        item.request_generation == 0 or item.resource_owner_key == 0 or
        item.claim.isZero() or item.claim.queue_slots != 1)
        return Error.InvalidScenario;
    if ((item.terminal_action == .none) !=
        (item.terminal_action_step == absent_step))
        return Error.InvalidScenario;
    if (item.terminal_action != .none and
        item.terminal_action_step < item.arrival_step)
        return Error.InvalidScenario;
    const profile = profileForKindV1(item.media_kind);
    if (item.family != profile.family or
        item.operation != profile.operation or
        !std.meta.eql(item.claim, profile.claim) or
        !std.mem.eql(u8, &item.profile_sha256, &profile.sha256))
        return Error.InvalidScenario;
}

fn requestSpecV1(item: WorkItemV1) qos.RequestSpec {
    return .{
        .tenant_key = item.tenant_key,
        .request_key = item.request_key,
        .request_generation = item.request_generation,
        .resource_owner_key = item.resource_owner_key,
        .weight = item.weight,
        .work_quanta = item.work_quanta,
        .deadline_tick = item.deadline_tick,
        .claim = item.claim,
    };
}

fn findItemByHandle(
    items: []const WorkItemV1,
    runtime_items: []const RuntimeItem,
    handle: qos.Handle,
) Error!usize {
    for (items, runtime_items, 0..) |item, runtime_item, index| {
        if (runtime_item.state == .active and
            item.tenant_key == handle.tenant_key and
            item.request_key == handle.request_key and
            item.request_generation == handle.request_generation and
            runtime_item.handle.slot_index == handle.slot_index and
            runtime_item.handle.slot_generation == handle.slot_generation)
            return index;
    }
    return Error.MissingWorkItem;
}

fn allTerminal(items: []const RuntimeItem) bool {
    for (items) |item| {
        if (item.state != .terminal) return false;
    }
    return true;
}

fn appendTrace(
    storage: []TraceRecordV1,
    count: *usize,
    driver_step: u64,
    item_ordinal: u64,
    terminal_action: TerminalActionV1,
    event: qos.EventV1,
) Error!Digest {
    if (count.* >= storage.len or count.* >= maximum_trace_records)
        return Error.TraceLimitExceeded;
    var record: TraceRecordV1 = .{
        .driver_step = driver_step,
        .item_ordinal = item_ordinal,
        .event_kind = event.kind,
        .rejection_reason = event.rejection_reason,
        .terminal_action = terminal_action,
        .logical_tick_before = event.logical_tick_before,
        .logical_tick_after = event.logical_tick_after,
        .remaining_before = event.remaining_before,
        .remaining_after = event.remaining_after,
        .wait_quanta = event.wait_quanta,
        .record_sha256 = zero_digest,
    };
    record.record_sha256 = traceRecordSha256V1(record);
    storage[count.*] = record;
    count.* += 1;
    return record.record_sha256;
}

fn summarizeV1(
    scenario: ScenarioV1,
    runtime_items: []const RuntimeItem,
    outcomes: []const OutcomeV1,
    trace: []const TraceRecordV1,
    driver_steps: u64,
    maximum_live_receipts: u64,
    maximum_service_gap: u64,
    scheduler_final: qos.SnapshotV1,
    bank_final: resource_bank.Snapshot,
) Error!SummaryV1 {
    var admitted: u64 = 0;
    var rejected: u64 = 0;
    var completed_count: u64 = 0;
    var cancelled: u64 = 0;
    var timed_out: u64 = 0;
    var service_quanta: u64 = 0;
    var maximum_wait: u64 = 0;
    var queue_values: [maximum_items]u64 = undefined;
    var queue_count: usize = 0;
    var completion_values: [maximum_items]u64 = undefined;
    var completion_count: usize = 0;
    for (outcomes) |outcome| {
        service_quanta = try checkedAdd(
            service_quanta,
            outcome.served_quanta,
        );
        maximum_wait = @max(maximum_wait, outcome.maximum_wait_quanta);
        switch (outcome.kind) {
            .rejected => rejected += 1,
            .completed => {
                admitted += 1;
                completed_count += 1;
                completion_values[completion_count] =
                    outcome.completion_delay_steps;
                completion_count += 1;
            },
            .cancelled => {
                admitted += 1;
                cancelled += 1;
            },
            .timed_out => {
                admitted += 1;
                timed_out += 1;
            },
        }
        if (outcome.first_service_step != absent_step) {
            queue_values[queue_count] = outcome.queue_delay_steps;
            queue_count += 1;
        }
    }
    var fairness_error: u64 = 0;
    for (scenario.items, runtime_items, 0..) |left, left_runtime, left_index| {
        if (!left.fairness_member) continue;
        for (
            scenario.items[left_index + 1 ..],
            runtime_items[left_index + 1 ..],
        ) |right, right_runtime| {
            if (!right.fairness_member) continue;
            const left_scaled = std.math.mul(
                u64,
                left_runtime.fairness_quanta,
                right.weight,
            ) catch return Error.ArithmeticOverflow;
            const right_scaled = std.math.mul(
                u64,
                right_runtime.fairness_quanta,
                left.weight,
            ) catch return Error.ArithmeticOverflow;
            const difference = if (left_scaled >= right_scaled)
                left_scaled - right_scaled
            else
                right_scaled - left_scaled;
            fairness_error = @max(fairness_error, difference);
        }
    }
    var trace_service_count: u64 = 0;
    for (trace) |record| {
        if (record.event_kind == .service) trace_service_count += 1;
    }
    if (trace_service_count != service_quanta)
        return Error.InvalidEvidence;
    const active_reservations: u64 =
        @intCast(bank_final.active_reservations);
    const committed_receipts: u64 =
        @intCast(bank_final.committed_receipts);
    const zero_orphan = scheduler_final.active == 0 and
        scheduler_final.finished == 0 and
        scheduler_final.used.isZero() and
        bank_final.used.isZero() and
        active_reservations == 0 and
        committed_receipts == 0 and
        bank_final.successful_commits == bank_final.releases and
        scheduler_final.closed;
    return .{
        .admitted = admitted,
        .rejected = rejected,
        .completed = completed_count,
        .cancelled = cancelled,
        .timed_out = timed_out,
        .service_quanta = service_quanta,
        .driver_steps = driver_steps,
        .final_logical_tick = scheduler_final.logical_tick,
        .maximum_live_receipts = maximum_live_receipts,
        .peak_host_bytes = bank_final.peak_host_bytes,
        .peak = bank_final.peak,
        .maximum_wait_quanta = maximum_wait,
        .maximum_service_gap = maximum_service_gap,
        .fairness_cross_product_error = fairness_error,
        .queue_delay_p50_steps = nearestRank(
            queue_values[0..queue_count],
            50,
        ),
        .queue_delay_p95_steps = nearestRank(
            queue_values[0..queue_count],
            95,
        ),
        .queue_delay_p99_steps = nearestRank(
            queue_values[0..queue_count],
            99,
        ),
        .queue_delay_max_steps = maximumValue(
            queue_values[0..queue_count],
        ),
        .completion_delay_p50_steps = nearestRank(
            completion_values[0..completion_count],
            50,
        ),
        .completion_delay_p95_steps = nearestRank(
            completion_values[0..completion_count],
            95,
        ),
        .completion_delay_p99_steps = nearestRank(
            completion_values[0..completion_count],
            99,
        ),
        .completion_delay_max_steps = maximumValue(
            completion_values[0..completion_count],
        ),
        .final_active = scheduler_final.active,
        .final_finished = scheduler_final.finished,
        .final_active_reservations = active_reservations,
        .final_committed_receipts = committed_receipts,
        .successful_commits = bank_final.successful_commits,
        .releases = bank_final.releases,
        .bank_cancellations = bank_final.cancellations,
        .bank_rejected_capacity = bank_final.rejected_capacity,
        .bank_rejected_slots = bank_final.rejected_slots,
        .zero_orphan_ownership = zero_orphan,
    };
}

fn validateResultStructureV1(result: ResultV1) Error!void {
    if (result.mode != .explicit_open_loop or
        result.outcomes.len == 0 or
        result.outcomes.len > maximum_items or
        result.trace.len == 0 or
        result.trace.len > maximum_trace_records or
        std.mem.eql(u8, &result.scenario_sha256, &zero_digest) or
        !std.mem.eql(
            u8,
            &result.outcome_sha256,
            &outcomeSha256V1(result.outcomes),
        ) or
        !std.mem.eql(
            u8,
            &result.trace_sha256,
            &traceSha256V1(result.trace),
        ) or
        !std.mem.eql(
            u8,
            &result.summary_sha256,
            &summarySha256V1(result.summary),
        ) or
        !result.summary.zero_orphan_ownership or
        result.summary.final_active != 0 or
        result.summary.final_finished != 0 or
        result.summary.final_active_reservations != 0 or
        result.summary.final_committed_receipts != 0 or
        result.summary.maximum_wait_quanta >
            result.summary.maximum_service_gap)
        return Error.InvalidEvidence;
    for (result.outcomes, 0..) |outcome, index| {
        if (outcome.ordinal != index or
            std.mem.eql(
                u8,
                &outcome.admission_trace_sha256,
                &zero_digest,
            ) or
            std.mem.eql(
                u8,
                &outcome.terminal_trace_sha256,
                &zero_digest,
            ))
            return Error.InvalidEvidence;
    }
    for (result.trace, 0..) |record, index| {
        if (!std.mem.eql(
            u8,
            &record.record_sha256,
            &traceRecordSha256V1(record),
        ) or
            (index != 0 and
                record.driver_step < result.trace[index - 1].driver_step) or
            (record.event_kind == .close and
                (index != result.trace.len - 1 or
                    record.item_ordinal != absent_item)) or
            (record.event_kind != .close and
                record.item_ordinal >= result.outcomes.len))
            return Error.InvalidEvidence;
    }
    const terminal = result.trace[result.trace.len - 1];
    if (terminal.event_kind != .close or
        terminal.item_ordinal != absent_item)
        return Error.InvalidEvidence;
    try validateOutcomeTraceReferencesV1(result);
}

fn validateOutcomeTraceReferencesV1(result: ResultV1) Error!void {
    for (result.outcomes) |outcome| {
        var admission_trace_root: ?Digest = null;
        var terminal_trace_root: ?Digest = null;
        for (result.trace) |record| {
            if (record.item_ordinal != outcome.ordinal) continue;
            switch (record.event_kind) {
                .admission_accepted => {
                    if (admission_trace_root != null)
                        return Error.InvalidEvidence;
                    admission_trace_root = record.record_sha256;
                },
                .admission_rejected => {
                    if (admission_trace_root != null or
                        terminal_trace_root != null)
                        return Error.InvalidEvidence;
                    admission_trace_root = record.record_sha256;
                    terminal_trace_root = record.record_sha256;
                },
                .cancel, .retire => {
                    if (terminal_trace_root != null)
                        return Error.InvalidEvidence;
                    terminal_trace_root = record.record_sha256;
                },
                .service => {},
                .close => return Error.InvalidEvidence,
            }
        }
        if (admission_trace_root == null or terminal_trace_root == null or
            !std.mem.eql(
                u8,
                &admission_trace_root.?,
                &outcome.admission_trace_sha256,
            ) or
            !std.mem.eql(
                u8,
                &terminal_trace_root.?,
                &outcome.terminal_trace_sha256,
            ))
            return Error.InvalidEvidence;
    }
}

fn nearestRank(values: []const u64, percentile: u64) u64 {
    if (values.len == 0) return 0;
    var sorted: [maximum_items]u64 = undefined;
    @memcpy(sorted[0..values.len], values);
    std.mem.sort(u64, sorted[0..values.len], {}, std.sort.asc(u64));
    const numerator = percentile * values.len;
    const rank = (numerator + 99) / 100;
    return sorted[@max(rank, 1) - 1];
}

fn maximumValue(values: []const u64) u64 {
    var result: u64 = 0;
    for (values) |value| result = @max(result, value);
    return result;
}

/// Canonical semantic identity used by the frozen scenario item wire.
pub fn itemSha256V1(item: WorkItemV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(scenario_item_domain);
    hashU64(&hash, item.ordinal);
    hashU64(&hash, @intFromEnum(item.family));
    hashU64(&hash, @intFromEnum(item.operation));
    hashU64(&hash, @intFromEnum(item.media_kind));
    hashU64(&hash, item.arrival_step);
    hashU64(&hash, item.weight);
    hashU64(&hash, item.work_quanta);
    hashU64(&hash, item.deadline_tick);
    hashU64(&hash, item.terminal_action_step);
    hashU64(&hash, @intFromEnum(item.terminal_action));
    hashU64(&hash, @intFromBool(item.fairness_member));
    hashU64(&hash, item.tenant_key);
    hashU64(&hash, item.request_key);
    hashU64(&hash, item.request_generation);
    hashU64(&hash, item.resource_owner_key);
    hashClaim(&hash, item.claim);
    hash.update(&item.profile_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn traceSha256V1(trace: []const TraceRecordV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(trace_domain);
    hashU64(&hash, trace_abi);
    hashU64(&hash, trace.len);
    for (trace) |record| {
        hashU64(&hash, record.driver_step);
        hashU64(&hash, record.item_ordinal);
        hashU64(&hash, @intFromEnum(record.event_kind));
        hashU64(&hash, @intFromEnum(record.rejection_reason));
        hashU64(&hash, @intFromEnum(record.terminal_action));
        hashU64(&hash, record.logical_tick_before);
        hashU64(&hash, record.logical_tick_after);
        hashU64(&hash, record.remaining_before);
        hashU64(&hash, record.remaining_after);
        hashU64(&hash, record.wait_quanta);
        hash.update(&record.record_sha256);
    }
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn traceRecordSha256V1(record: TraceRecordV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(trace_record_domain);
    hashU64(&hash, trace_abi);
    hashU64(&hash, record.driver_step);
    hashU64(&hash, record.item_ordinal);
    hashU64(&hash, @intFromEnum(record.event_kind));
    hashU64(&hash, @intFromEnum(record.rejection_reason));
    hashU64(&hash, @intFromEnum(record.terminal_action));
    hashU64(&hash, record.logical_tick_before);
    hashU64(&hash, record.logical_tick_after);
    hashU64(&hash, record.remaining_before);
    hashU64(&hash, record.remaining_after);
    hashU64(&hash, record.wait_quanta);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn outcomeSha256V1(outcomes: []const OutcomeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(outcome_domain);
    hashU64(&hash, result_abi);
    hashU64(&hash, outcomes.len);
    for (outcomes) |outcome| {
        hashU64(&hash, outcome.ordinal);
        hashU64(&hash, @intFromEnum(outcome.kind));
        hashU64(&hash, @intFromEnum(outcome.rejection_reason));
        hashU64(&hash, @intFromEnum(outcome.terminal_action));
        hashU64(&hash, outcome.admitted_step);
        hashU64(&hash, outcome.first_service_step);
        hashU64(&hash, outcome.terminal_step);
        hashU64(&hash, outcome.served_quanta);
        hashU64(&hash, outcome.maximum_wait_quanta);
        hashU64(&hash, outcome.queue_delay_steps);
        hashU64(&hash, outcome.completion_delay_steps);
        hash.update(&outcome.admission_trace_sha256);
        hash.update(&outcome.terminal_trace_sha256);
    }
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn summarySha256V1(summary: SummaryV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(summary_domain);
    hashU64(&hash, summary_abi);
    inline for (.{
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
        summary.maximum_wait_quanta,
        summary.maximum_service_gap,
        summary.fairness_cross_product_error,
        summary.queue_delay_p50_steps,
        summary.queue_delay_p95_steps,
        summary.queue_delay_p99_steps,
        summary.queue_delay_max_steps,
        summary.completion_delay_p50_steps,
        summary.completion_delay_p95_steps,
        summary.completion_delay_p99_steps,
        summary.completion_delay_max_steps,
        summary.final_active,
        summary.final_finished,
        summary.final_active_reservations,
        summary.final_committed_receipts,
        summary.successful_commits,
        summary.releases,
        summary.bank_cancellations,
        summary.bank_rejected_capacity,
        summary.bank_rejected_slots,
        @intFromBool(summary.zero_orphan_ownership),
    }) |value| hashU64(&hash, value);
    hashClaim(&hash, summary.peak);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn writeScenarioItem(output: []u8, item: WorkItemV1) void {
    writeU64(output, 0, item.ordinal);
    writeU64(output, 8, @intFromEnum(item.family));
    writeU64(output, 16, @intFromEnum(item.operation));
    writeU64(output, 24, @intFromEnum(item.media_kind));
    writeU64(output, 32, item.arrival_step);
    writeU64(output, 40, item.weight);
    writeU64(output, 48, item.work_quanta);
    writeU64(output, 56, item.deadline_tick);
    writeU64(output, 64, item.terminal_action_step);
    writeU64(output, 72, @intFromEnum(item.terminal_action));
    writeU64(output, 80, @intFromBool(item.fairness_member));
    writeU64(output, 88, item.tenant_key);
    writeU64(output, 96, item.request_key);
    writeU64(output, 104, item.request_generation);
    writeU64(output, 112, item.resource_owner_key);
    writeClaim(output, 120, item.claim);
    @memcpy(output[200..232], &item.profile_sha256);
    const root = itemSha256V1(item);
    @memcpy(output[232..264], &root);
}

fn decodeScenarioItem(input: []const u8) Error!WorkItemV1 {
    if (readU64(input, 264) != 0) return Error.InvalidEvidence;
    const family = std.meta.intToEnum(
        model.ModelFamilyIdV1,
        readU64(input, 8),
    ) catch return Error.InvalidEvidence;
    const operation = std.meta.intToEnum(
        model.OperationIdV1,
        readU64(input, 16),
    ) catch return Error.InvalidEvidence;
    const kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(input, 24),
    ) catch return Error.InvalidEvidence;
    const action = std.meta.intToEnum(
        TerminalActionV1,
        readU64(input, 72),
    ) catch return Error.InvalidEvidence;
    const weight = std.math.cast(u16, readU64(input, 40)) orelse
        return Error.InvalidEvidence;
    const fairness_raw = readU64(input, 80);
    if (fairness_raw > 1) return Error.InvalidEvidence;
    var profile_root: Digest = undefined;
    var item_root: Digest = undefined;
    @memcpy(&profile_root, input[200..232]);
    @memcpy(&item_root, input[232..264]);
    const item: WorkItemV1 = .{
        .ordinal = readU64(input, 0),
        .family = family,
        .operation = operation,
        .media_kind = kind,
        .profile_sha256 = profile_root,
        .arrival_step = readU64(input, 32),
        .weight = weight,
        .work_quanta = readU64(input, 48),
        .deadline_tick = readU64(input, 56),
        .terminal_action_step = readU64(input, 64),
        .terminal_action = action,
        .fairness_member = fairness_raw == 1,
        .tenant_key = readU64(input, 88),
        .request_key = readU64(input, 96),
        .request_generation = readU64(input, 104),
        .resource_owner_key = readU64(input, 112),
        .claim = readClaim(input, 120),
    };
    if (!std.mem.eql(u8, &item_root, &itemSha256V1(item)))
        return Error.InvalidEvidence;
    return item;
}

fn writeOutcomeRecord(output: []u8, outcome: OutcomeV1) void {
    writeU64(output, 0, outcome.ordinal);
    writeU64(output, 8, @intFromEnum(outcome.kind));
    writeU64(output, 16, @intFromEnum(outcome.rejection_reason));
    writeU64(output, 24, @intFromEnum(outcome.terminal_action));
    writeU64(output, 32, outcome.admitted_step);
    writeU64(output, 40, outcome.first_service_step);
    writeU64(output, 48, outcome.terminal_step);
    writeU64(output, 56, outcome.served_quanta);
    writeU64(output, 64, outcome.maximum_wait_quanta);
    writeU64(output, 72, outcome.queue_delay_steps);
    writeU64(output, 80, outcome.completion_delay_steps);
    @memcpy(output[88..120], &outcome.admission_trace_sha256);
    @memcpy(output[120..152], &outcome.terminal_trace_sha256);
}

fn decodeOutcomeRecord(input: []const u8) Error!OutcomeV1 {
    if (readU64(input, 152) != 0) return Error.InvalidEvidence;
    const kind = std.meta.intToEnum(
        OutcomeKindV1,
        readU64(input, 8),
    ) catch return Error.InvalidEvidence;
    const rejection = std.meta.intToEnum(
        qos.RejectionReason,
        std.math.cast(u8, readU64(input, 16)) orelse
            return Error.InvalidEvidence,
    ) catch return Error.InvalidEvidence;
    const action = std.meta.intToEnum(
        TerminalActionV1,
        readU64(input, 24),
    ) catch return Error.InvalidEvidence;
    var admission_root: Digest = undefined;
    var terminal_root: Digest = undefined;
    @memcpy(&admission_root, input[88..120]);
    @memcpy(&terminal_root, input[120..152]);
    return .{
        .ordinal = readU64(input, 0),
        .kind = kind,
        .rejection_reason = rejection,
        .terminal_action = action,
        .admitted_step = readU64(input, 32),
        .first_service_step = readU64(input, 40),
        .terminal_step = readU64(input, 48),
        .served_quanta = readU64(input, 56),
        .maximum_wait_quanta = readU64(input, 64),
        .queue_delay_steps = readU64(input, 72),
        .completion_delay_steps = readU64(input, 80),
        .admission_trace_sha256 = admission_root,
        .terminal_trace_sha256 = terminal_root,
    };
}

fn writeTraceRecord(output: []u8, record: TraceRecordV1) void {
    writeU64(output, 0, record.driver_step);
    writeU64(output, 8, record.item_ordinal);
    writeU64(output, 16, @intFromEnum(record.event_kind));
    writeU64(output, 24, @intFromEnum(record.rejection_reason));
    writeU64(output, 32, @intFromEnum(record.terminal_action));
    writeU64(output, 40, record.logical_tick_before);
    writeU64(output, 48, record.logical_tick_after);
    writeU64(output, 56, record.remaining_before);
    writeU64(output, 64, record.remaining_after);
    writeU64(output, 72, record.wait_quanta);
    @memcpy(output[80..112], &record.record_sha256);
}

fn decodeTraceRecord(input: []const u8) Error!TraceRecordV1 {
    const event_kind = std.meta.intToEnum(
        qos.EventKind,
        std.math.cast(u8, readU64(input, 16)) orelse
            return Error.InvalidEvidence,
    ) catch return Error.InvalidEvidence;
    const rejection = std.meta.intToEnum(
        qos.RejectionReason,
        std.math.cast(u8, readU64(input, 24)) orelse
            return Error.InvalidEvidence,
    ) catch return Error.InvalidEvidence;
    const action = std.meta.intToEnum(
        TerminalActionV1,
        readU64(input, 32),
    ) catch return Error.InvalidEvidence;
    var event_root: Digest = undefined;
    @memcpy(&event_root, input[80..112]);
    return .{
        .driver_step = readU64(input, 0),
        .item_ordinal = readU64(input, 8),
        .event_kind = event_kind,
        .rejection_reason = rejection,
        .terminal_action = action,
        .logical_tick_before = readU64(input, 40),
        .logical_tick_after = readU64(input, 48),
        .remaining_before = readU64(input, 56),
        .remaining_after = readU64(input, 64),
        .wait_quanta = readU64(input, 72),
        .record_sha256 = event_root,
    };
}

fn writeSummaryHeader(output: []u8, summary: SummaryV1) void {
    const values = [_]u64{
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
        summary.maximum_wait_quanta,
        summary.maximum_service_gap,
        summary.fairness_cross_product_error,
        summary.queue_delay_p50_steps,
        summary.queue_delay_p95_steps,
        summary.queue_delay_p99_steps,
        summary.queue_delay_max_steps,
        summary.completion_delay_p50_steps,
        summary.completion_delay_p95_steps,
        summary.completion_delay_p99_steps,
        summary.completion_delay_max_steps,
        summary.final_active,
        summary.final_finished,
        summary.final_active_reservations,
        summary.final_committed_receipts,
        summary.successful_commits,
        summary.releases,
        summary.bank_cancellations,
        summary.bank_rejected_capacity,
        summary.bank_rejected_slots,
        @intFromBool(summary.zero_orphan_ownership),
    };
    for (values, 0..) |value, index| writeU64(
        output,
        56 + index * 8,
        value,
    );
}

fn readSummaryHeader(input: []const u8) SummaryV1 {
    return .{
        .admitted = readU64(input, 56),
        .rejected = readU64(input, 64),
        .completed = readU64(input, 72),
        .cancelled = readU64(input, 80),
        .timed_out = readU64(input, 88),
        .service_quanta = readU64(input, 96),
        .driver_steps = readU64(input, 104),
        .final_logical_tick = readU64(input, 112),
        .maximum_live_receipts = readU64(input, 120),
        .peak_host_bytes = readU64(input, 128),
        .maximum_wait_quanta = readU64(input, 136),
        .maximum_service_gap = readU64(input, 144),
        .fairness_cross_product_error = readU64(input, 152),
        .queue_delay_p50_steps = readU64(input, 160),
        .queue_delay_p95_steps = readU64(input, 168),
        .queue_delay_p99_steps = readU64(input, 176),
        .queue_delay_max_steps = readU64(input, 184),
        .completion_delay_p50_steps = readU64(input, 192),
        .completion_delay_p95_steps = readU64(input, 200),
        .completion_delay_p99_steps = readU64(input, 208),
        .completion_delay_max_steps = readU64(input, 216),
        .final_active = readU64(input, 224),
        .final_finished = readU64(input, 232),
        .final_active_reservations = readU64(input, 240),
        .final_committed_receipts = readU64(input, 248),
        .successful_commits = readU64(input, 256),
        .releases = readU64(input, 264),
        .bank_cancellations = readU64(input, 272),
        .bank_rejected_capacity = readU64(input, 280),
        .bank_rejected_slots = readU64(input, 288),
        .zero_orphan_ownership = readU64(input, 296) == 1,
        .peak = readClaim(input, 440),
    };
}

fn scenarioBodySha256(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(scenario_domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn resultBodySha256(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(result_domain);
    hash.update(body);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashLimits(
    hash: *std.crypto.hash.sha2.Sha256,
    limits: resource_bank.Limits,
) void {
    inline for (std.meta.fields(resource_bank.Limits)) |field|
        hashU64(hash, @field(limits, field.name));
}

fn writeClaim(output: []u8, offset: usize, claim: resource_bank.Claim) void {
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        writeU64(output, offset + index * 8, @field(claim, field.name));
}

fn readClaim(input: []const u8, offset: usize) resource_bank.Claim {
    var claim: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        @field(claim, field.name) = readU64(input, offset + index * 8);
    return claim;
}

fn writeLimits(output: []u8, offset: usize, limits: resource_bank.Limits) void {
    inline for (std.meta.fields(resource_bank.Limits), 0..) |field, index|
        writeU64(output, offset + index * 8, @field(limits, field.name));
}

fn readLimits(input: []const u8, offset: usize) resource_bank.Limits {
    var limits: resource_bank.Limits = .{};
    inline for (std.meta.fields(resource_bank.Limits), 0..) |field, index|
        @field(limits, field.name) = readU64(input, offset + index * 8);
    return limits;
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

fn writeU64(output: []u8, offset: usize, value: anytype) void {
    std.mem.writeInt(
        u64,
        output[offset..][0..8],
        @intCast(value),
        .little,
    );
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset..][0..8], .little);
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

const DriverProbeState = enum {
    pending,
    bound,
    final_service,
    cancelled,
    retired,
};

const DriverProbe = struct {
    states: [maximum_items]DriverProbeState =
        [_]DriverProbeState{.pending} ** maximum_items,
    binds: u64 = 0,
    cancels: u64 = 0,
    services: u64 = 0,
    final_services: u64 = 0,
    retires: u64 = 0,
    failed_item_ordinal: ?u64 = null,

    fn fromContext(context: ?*anyopaque) *DriverProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn fail(
        self: *DriverProbe,
        item: WorkItemV1,
    ) DriverError {
        self.failed_item_ordinal = item.ordinal;
        return error.DriverFailed;
    }

    fn bindAdmitted(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverBindAdmittedV1,
    ) DriverError!void {
        _ = scheduler;
        const self = fromContext(context);
        if (input.item_index >= self.states.len or
            self.states[input.item_index] != .pending)
            return self.fail(input.item);
        self.states[input.item_index] = .bound;
        self.binds += 1;
    }

    fn cancel(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCancelV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        if (input.item_index >= self.states.len or
            self.states[input.item_index] != .bound)
            return self.fail(input.item);
        self.states[input.item_index] = .cancelled;
        self.cancels += 1;
        return defaultCancelV1(null, scheduler, input);
    }

    fn commitService(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCommitServiceV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        if (input.item_index >= self.states.len or
            self.states[input.item_index] != .bound)
            return self.fail(input.item);
        self.services += 1;
        if (input.final_quantum) {
            self.states[input.item_index] = .final_service;
            self.final_services += 1;
        }
        return defaultCommitServiceV1(null, scheduler, input);
    }

    fn retire(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverRetireV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        if (input.item_index >= self.states.len or
            self.states[input.item_index] != .final_service or
            input.final_service_event.remaining_after != 0)
            return self.fail(input.item);
        self.states[input.item_index] = .retired;
        self.retires += 1;
        return defaultRetireV1(null, scheduler, input);
    }

    fn interface(self: *DriverProbe) DriverV1 {
        return .{
            .context = self,
            .bind_admitted_fn = bindAdmitted,
            .cancel_fn = cancel,
            .commit_service_fn = commitService,
            .retire_fn = retire,
        };
    }
};

const ForgedDriverTarget = enum {
    cancel,
    service,
    final_service,
    retire,
};

const ForgedDriver = struct {
    target: ForgedDriverTarget,
    mutations: u64 = 0,

    fn fromContext(context: ?*anyopaque) *ForgedDriver {
        return @ptrCast(@alignCast(context.?));
    }

    fn forge(
        self: *ForgedDriver,
        event: SchedulerEventV1,
    ) SchedulerEventV1 {
        var changed = event;
        changed.logical_tick_after += 1;
        changed.event_sha256 = qos.eventSha256(changed);
        self.mutations += 1;
        return changed;
    }

    fn cancel(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCancelV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        const event = try defaultCancelV1(null, scheduler, input);
        return if (self.target == .cancel)
            self.forge(event)
        else
            event;
    }

    fn commitService(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCommitServiceV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        const event = try defaultCommitServiceV1(null, scheduler, input);
        return if (self.target == .service or
            (self.target == .final_service and input.final_quantum))
            self.forge(event)
        else
            event;
    }

    fn retire(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverRetireV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        const event = try defaultRetireV1(null, scheduler, input);
        return if (self.target == .retire)
            self.forge(event)
        else
            event;
    }

    fn interface(self: *ForgedDriver) DriverV1 {
        return .{
            .context = self,
            .cancel_fn = cancel,
            .commit_service_fn = commitService,
            .retire_fn = retire,
        };
    }
};

const UnconsumedServiceDriver = struct {
    calls: u64 = 0,

    fn commitService(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCommitServiceV1,
    ) DriverError!SchedulerEventV1 {
        _ = scheduler;
        _ = input;
        const self: *UnconsumedServiceDriver =
            @ptrCast(@alignCast(context.?));
        self.calls += 1;
        return error.DriverFailed;
    }

    fn interface(self: *UnconsumedServiceDriver) DriverV1 {
        return .{
            .context = self,
            .commit_service_fn = commitService,
        };
    }
};

test "reference mixed-media pressure is exact and leaves zero ownership" {
    var items = makeReferenceItemsV1();
    const scenario = referenceScenarioV1(&items);
    const expected_scenario_root = try digestFromHex(
        "e6fc0e1b3d676c5ea89a2e54434bef0ac51e30f8b1ab85944bfc43e0cd34407b",
    );
    try std.testing.expectEqualDeep(
        expected_scenario_root,
        try scenarioSha256V1(scenario),
    );
    var storage_value: ReferenceStorageV1 = .{};
    const result = try runScenarioV1(
        scenario,
        storage_value.interface(),
    );
    try std.testing.expectEqual(@as(u64, 5), result.summary.admitted);
    try std.testing.expectEqual(@as(u64, 2), result.summary.rejected);
    try std.testing.expectEqual(@as(u64, 3), result.summary.completed);
    try std.testing.expectEqual(@as(u64, 1), result.summary.cancelled);
    try std.testing.expectEqual(@as(u64, 1), result.summary.timed_out);
    try std.testing.expectEqual(@as(u64, 21), result.summary.service_quanta);
    try std.testing.expectEqual(@as(u64, 4972), result.summary.peak_host_bytes);
    try std.testing.expectEqual(@as(u64, 4), result.summary.maximum_live_receipts);
    try std.testing.expectEqual(
        @as(u64, 0),
        result.summary.fairness_cross_product_error,
    );
    try std.testing.expectEqual(@as(u64, 1), result.summary.queue_delay_p50_steps);
    try std.testing.expectEqual(@as(u64, 5), result.summary.queue_delay_p95_steps);
    try std.testing.expectEqual(
        @as(u64, 16),
        result.summary.completion_delay_p50_steps,
    );
    try std.testing.expectEqual(
        @as(u64, 19),
        result.summary.completion_delay_p95_steps,
    );
    try std.testing.expect(result.summary.zero_orphan_ownership);
    try std.testing.expectEqual(@as(usize, 34), result.trace.len);
    try std.testing.expectEqual(
        qos.RejectionReason.no_slot,
        result.outcomes[4].rejection_reason,
    );
    try std.testing.expectEqual(
        qos.RejectionReason.resource_limit,
        result.outcomes[5].rejection_reason,
    );
}

test "driver hooks preserve roots and run once in lifecycle order" {
    var items = makeReferenceItemsV1();
    const scenario = referenceScenarioV1(&items);
    var default_storage: ReferenceStorageV1 = .{};
    const expected = try runScenarioV1(
        scenario,
        default_storage.interface(),
    );
    var probe: DriverProbe = .{};
    var driven_storage: ReferenceStorageV1 = .{};
    const actual = try runScenarioWithDriverV1(
        scenario,
        driven_storage.interface(),
        probe.interface(),
    );

    try std.testing.expectEqualDeep(
        expected.scenario_sha256,
        actual.scenario_sha256,
    );
    try std.testing.expectEqualDeep(
        expected.outcome_sha256,
        actual.outcome_sha256,
    );
    try std.testing.expectEqualDeep(
        expected.trace_sha256,
        actual.trace_sha256,
    );
    try std.testing.expectEqualDeep(
        expected.summary_sha256,
        actual.summary_sha256,
    );
    try std.testing.expectEqualDeep(expected.summary, actual.summary);
    try std.testing.expectEqualDeep(expected.outcomes, actual.outcomes);
    try std.testing.expectEqualDeep(expected.trace, actual.trace);
    try std.testing.expectEqual(actual.summary.admitted, probe.binds);
    try std.testing.expectEqual(
        actual.summary.cancelled + actual.summary.timed_out,
        probe.cancels,
    );
    try std.testing.expectEqual(actual.summary.service_quanta, probe.services);
    try std.testing.expectEqual(actual.summary.completed, probe.final_services);
    try std.testing.expectEqual(actual.summary.completed, probe.retires);
    try std.testing.expectEqual(@as(?u64, null), probe.failed_item_ordinal);
    for (actual.outcomes, 0..) |outcome, index| {
        switch (outcome.kind) {
            .completed => try std.testing.expectEqual(
                DriverProbeState.retired,
                probe.states[index],
            ),
            .cancelled, .timed_out => try std.testing.expectEqual(
                DriverProbeState.cancelled,
                probe.states[index],
            ),
            .rejected => try std.testing.expectEqual(
                DriverProbeState.pending,
                probe.states[index],
            ),
        }
    }
}

test "driver failure preserves caller context detail" {
    var items = makeReferenceItemsV1();
    const scenario = referenceScenarioV1(&items);
    var probe: DriverProbe = .{};
    var storage_value: ReferenceStorageV1 = .{};
    probe.states[0] = .bound;
    try std.testing.expectError(
        Error.DriverFailed,
        runScenarioWithDriverV1(
            scenario,
            storage_value.interface(),
            .{
                .context = &probe,
                .bind_admitted_fn = DriverProbe.bindAdmitted,
            },
        ),
    );
    try std.testing.expectEqual(
        scenario.items[0].ordinal,
        probe.failed_item_ordinal.?,
    );
    for (storage_value.bank_slots) |slot|
        try std.testing.expect(std.meta.eql(slot, resource_bank.Slot{}));
    for (storage_value.scheduler_slots) |slot|
        try std.testing.expect(std.meta.eql(slot, qos.Slot{}));
}

test "service driver failure aborts its unconsumed permit before cleanup" {
    var items = makeReferenceItemsV1();
    const scenario = referenceScenarioV1(&items);
    var storage_value: ReferenceStorageV1 = .{};
    var driver: UnconsumedServiceDriver = .{};
    try std.testing.expectError(
        Error.DriverFailed,
        runScenarioWithDriverV1(
            scenario,
            storage_value.interface(),
            driver.interface(),
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), driver.calls);
    for (storage_value.bank_slots) |slot|
        try std.testing.expect(std.meta.eql(slot, resource_bank.Slot{}));
    for (storage_value.scheduler_slots) |slot|
        try std.testing.expect(std.meta.eql(slot, qos.Slot{}));
}

test "driver callbacks reject resealed events that are not the chain head" {
    const targets = [_]ForgedDriverTarget{
        .cancel,
        .service,
        .final_service,
        .retire,
    };
    for (targets) |target| {
        var items = makeReferenceItemsV1();
        const scenario = referenceScenarioV1(&items);
        var storage_value: ReferenceStorageV1 = .{};
        var driver: ForgedDriver = .{ .target = target };
        try std.testing.expectError(
            Error.DriverFailed,
            runScenarioWithDriverV1(
                scenario,
                storage_value.interface(),
                driver.interface(),
            ),
        );
        try std.testing.expectEqual(@as(u64, 1), driver.mutations);
        for (storage_value.bank_slots) |slot| {
            try std.testing.expect(std.meta.eql(
                slot,
                resource_bank.Slot{},
            ));
        }
    }
}

fn digestFromHex(hex: *const [64]u8) !Digest {
    var digest: Digest = undefined;
    _ = try std.fmt.hexToBytes(&digest, hex);
    return digest;
}

test "scenario and result wires round trip and bind semantic summaries" {
    var items = makeReferenceItemsV1();
    const scenario = referenceScenarioV1(&items);
    var scenario_bytes: [
        scenario_header_bytes +
            7 * scenario_item_bytes + scenario_footer_bytes
    ]u8 = undefined;
    const encoded_scenario = try encodeScenarioV1(
        scenario,
        &scenario_bytes,
    );
    var decoded_items: [7]WorkItemV1 = undefined;
    const decoded_scenario = try decodeScenarioV1(
        encoded_scenario,
        &decoded_items,
    );
    try std.testing.expectEqualDeep(
        try scenarioSha256V1(scenario),
        try scenarioSha256V1(decoded_scenario),
    );

    var storage_value: ReferenceStorageV1 = .{};
    const result = try runScenarioV1(
        decoded_scenario,
        storage_value.interface(),
    );
    const expected_outcome_root = try digestFromHex(
        "9eb52f76c2c68098d59f13bc6d5b456b2efd7297b936731543c33a2d9934596f",
    );
    const expected_trace_root = try digestFromHex(
        "0868ce16006aa777bbc13d2454935607f375f5446e4c18cf78a958c2bee92169",
    );
    const expected_summary_root = try digestFromHex(
        "1c7d104f1d12627503c6d472f01bb0b07f41f200a8d1ecad23738d06dff80b0d",
    );
    try std.testing.expectEqualDeep(
        expected_outcome_root,
        result.outcome_sha256,
    );
    try std.testing.expectEqualDeep(
        expected_trace_root,
        result.trace_sha256,
    );
    try std.testing.expectEqualDeep(
        expected_summary_root,
        result.summary_sha256,
    );
    var result_bytes: [
        result_header_bytes +
            7 * outcome_record_bytes +
            maximum_trace_records * trace_record_bytes +
            result_footer_bytes
    ]u8 = undefined;
    const encoded_result = try encodeResultV1(result, &result_bytes);
    const expected_result_root = try digestFromHex(
        "1f5509316a967fe410b90ac0970af3ce77e0d63c1e1ab4f81012a23accea5fb0",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_result_root,
        encoded_result[encoded_result.len - result_footer_bytes ..],
    );
    var outcomes: [7]OutcomeV1 = undefined;
    var trace: [maximum_trace_records]TraceRecordV1 = undefined;
    const decoded_result = try decodeResultV1(
        encoded_result,
        &outcomes,
        &trace,
    );
    try validateResultAgainstScenarioV1(
        decoded_scenario,
        decoded_result,
    );
    var replay_storage: ReferenceStorageV1 = .{};
    try validateResultByReplayV1(
        decoded_scenario,
        decoded_result,
        replay_storage.interface(),
    );
    try std.testing.expectEqualDeep(result.summary, decoded_result.summary);
}

test "every result byte mutation truncation and semantic drift rejects" {
    var items = makeReferenceItemsV1();
    const scenario = referenceScenarioV1(&items);
    var storage_value: ReferenceStorageV1 = .{};
    const result = try runScenarioV1(
        scenario,
        storage_value.interface(),
    );
    var encoded_storage: [
        result_header_bytes +
            7 * outcome_record_bytes +
            maximum_trace_records * trace_record_bytes +
            result_footer_bytes
    ]u8 = undefined;
    const encoded = try encodeResultV1(result, &encoded_storage);
    var mutated_storage: [encoded_storage.len]u8 = undefined;
    var outcomes: [7]OutcomeV1 = undefined;
    var trace: [maximum_trace_records]TraceRecordV1 = undefined;
    for (encoded, 0..) |_, index| {
        @memcpy(mutated_storage[0..encoded.len], encoded);
        mutated_storage[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidEvidence,
            decodeResultV1(
                mutated_storage[0..encoded.len],
                &outcomes,
                &trace,
            ),
        );
    }
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodeResultV1(
            encoded[0 .. encoded.len - 1],
            &outcomes,
            &trace,
        ),
    );

    @memcpy(mutated_storage[0..encoded.len], encoded);
    const first_admission_offset = result_header_bytes + 88;
    @memset(
        mutated_storage[first_admission_offset .. first_admission_offset + 32],
        0,
    );
    var forged_outcomes: [7]OutcomeV1 = undefined;
    @memcpy(&forged_outcomes, result.outcomes);
    forged_outcomes[0].admission_trace_sha256 = zero_digest;
    const forged_outcome_root = outcomeSha256V1(&forged_outcomes);
    @memcpy(mutated_storage[344..376], &forged_outcome_root);
    const forged_footer = resultBodySha256(
        mutated_storage[0 .. encoded.len - result_footer_bytes],
    );
    @memcpy(
        mutated_storage[encoded.len - result_footer_bytes .. encoded.len],
        &forged_footer,
    );
    var atomic_outcomes: [7]OutcomeV1 = undefined;
    @memcpy(&atomic_outcomes, result.outcomes);
    const outcomes_before_failure = atomic_outcomes;
    var atomic_trace: [maximum_trace_records]TraceRecordV1 = undefined;
    for (&atomic_trace) |*record| record.* = result.trace[0];
    const trace_before_failure = atomic_trace;
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodeResultV1(
            mutated_storage[0..encoded.len],
            &atomic_outcomes,
            &atomic_trace,
        ),
    );
    try std.testing.expectEqualDeep(
        outcomes_before_failure,
        atomic_outcomes,
    );
    try std.testing.expectEqualDeep(
        trace_before_failure,
        atomic_trace,
    );

    var contradictory = result;
    contradictory.summary.completed += 1;
    contradictory.summary_sha256 = summarySha256V1(contradictory.summary);
    var contradictory_bytes: [encoded_storage.len]u8 = undefined;
    const rehashed = try encodeResultV1(
        contradictory,
        &contradictory_bytes,
    );
    const decoded = try decodeResultV1(rehashed, &outcomes, &trace);
    try std.testing.expectError(
        Error.InvalidEvidence,
        validateResultAgainstScenarioV1(scenario, decoded),
    );

    var forged_fairness = result;
    forged_fairness.summary.fairness_cross_product_error += 1;
    forged_fairness.summary_sha256 =
        summarySha256V1(forged_fairness.summary);
    const rehashed_fairness = try encodeResultV1(
        forged_fairness,
        &contradictory_bytes,
    );
    const decoded_fairness = try decodeResultV1(
        rehashed_fairness,
        &outcomes,
        &trace,
    );
    var replay_storage: ReferenceStorageV1 = .{};
    try std.testing.expectError(
        Error.InvalidEvidence,
        validateResultByReplayV1(
            scenario,
            decoded_fairness,
            replay_storage.interface(),
        ),
    );

    storage_value.outcomes[0].admission_trace_sha256 =
        storage_value.outcomes[1].admission_trace_sha256;
    var substituted = result;
    substituted.outcome_sha256 = outcomeSha256V1(substituted.outcomes);
    try std.testing.expectError(
        Error.InvalidEvidence,
        encodeResultV1(substituted, &contradictory_bytes),
    );
}

test "projection operation exhaustion has an exact rejection reason" {
    var items = makeReferenceItemsV1();
    items[0].terminal_action = .none;
    items[0].terminal_action_step = absent_step;
    var scenario = referenceScenarioV1(items[0..2]);
    scenario.capacity = 2;
    scenario.max_projection_operations = 1;

    var storage_value: ReferenceStorageV1 = .{};
    const result = try runScenarioV1(
        scenario,
        storage_value.interface(),
    );
    try std.testing.expectEqual(@as(u64, 0), result.summary.admitted);
    try std.testing.expectEqual(@as(u64, 2), result.summary.rejected);
    for (result.outcomes) |outcome| {
        try std.testing.expectEqual(
            qos.RejectionReason.projection_limit,
            outcome.rejection_reason,
        );
    }
}

test "same-step cancel and retire retain the true receipt high-water" {
    var items = makeReferenceItemsV1();
    items[0].terminal_action_step = 0;
    items[1].arrival_step = 1;
    items[1].work_quanta = 1;
    var scenario = referenceScenarioV1(items[0..2]);
    scenario.capacity = 1;
    scenario.limits = .{
        .host_bytes = 1464,
        .queue_slots = 1,
    };

    var storage_value: ReferenceStorageV1 = .{};
    const result = try runScenarioV1(
        scenario,
        storage_value.interface(),
    );
    try std.testing.expectEqual(@as(u64, 2), result.summary.admitted);
    try std.testing.expectEqual(@as(u64, 1), result.summary.completed);
    try std.testing.expectEqual(@as(u64, 1), result.summary.cancelled);
    try std.testing.expectEqual(
        @as(u64, 1),
        result.summary.maximum_live_receipts,
    );
    try std.testing.expectEqual(@as(u64, 0), result.summary.final_active);
    try std.testing.expect(result.summary.zero_orphan_ownership);
}

test "short destination failures do not mutate caller bytes" {
    var items = makeReferenceItemsV1();
    const scenario = referenceScenarioV1(&items);
    var scenario_output: [64]u8 = [_]u8{0xa5} ** 64;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeScenarioV1(scenario, &scenario_output),
    );
    try std.testing.expect(std.mem.allEqual(u8, &scenario_output, 0xa5));

    var storage_value: ReferenceStorageV1 = .{};
    const result = try runScenarioV1(
        scenario,
        storage_value.interface(),
    );
    var result_output: [64]u8 = [_]u8{0x5a} ** 64;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeResultV1(result, &result_output),
    );
    try std.testing.expect(std.mem.allEqual(u8, &result_output, 0x5a));
}
