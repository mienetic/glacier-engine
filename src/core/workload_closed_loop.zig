//! Bounded deterministic closed-loop workload conformance.
//!
//! W3 is a separately versioned logical state machine. It performs no ambient
//! timing, random-system access, model execution, filesystem or network I/O,
//! device work, heap allocation, or thread creation.

const std = @import("std");
const media = @import("media_contract.zig");
const model = @import("model_contract.zig");
const qos = @import("lane_weave_qos.zig");
const resource_bank = @import("resource_bank.zig");
const workload = @import("workload_pressure.zig");

pub const Digest = workload.Digest;
pub const zero_digest = workload.zero_digest;

pub const plan_abi: u64 = 0x4757_434c_5000_0001;
pub const result_abi: u64 = 0x4757_434c_5200_0001;
pub const trace_abi: u64 = 0x4757_434c_5400_0001;
pub const summary_abi: u64 = 0x4757_434c_5300_0001;
pub const candidate_abi: u64 = 0x4757_434c_4300_0001;
pub const outcome_abi: u64 = 0x4757_434c_4f00_0001;

pub const plan_magic = [8]u8{ 'G', 'W', 'C', 'L', 'P', '1', 0, 0 };
pub const result_magic = [8]u8{ 'G', 'W', 'C', 'L', 'R', '1', 0, 0 };
pub const plan_header_bytes: usize = 320;
pub const candidate_record_bytes: usize = 256;
pub const plan_footer_bytes: usize = 32;
pub const result_header_bytes: usize = 256;
pub const outcome_record_bytes: usize = 328;
pub const trace_record_bytes: usize = 200;
pub const summary_record_bytes: usize = 424;
pub const result_footer_bytes: usize = 32;
pub const allowed_flags: u64 = 0;
pub const maximum_plan_bytes: usize =
    plan_header_bytes +
    maximum_candidates * candidate_record_bytes +
    plan_footer_bytes;
pub const maximum_result_bytes: usize =
    result_header_bytes +
    maximum_candidates * outcome_record_bytes +
    maximum_trace_records * trace_record_bytes +
    summary_record_bytes +
    result_footer_bytes;

pub const maximum_candidates: usize = workload.maximum_items;
pub const maximum_driver_steps: u64 = workload.maximum_driver_steps;
pub const maximum_service_quanta: u64 = workload.maximum_service_quanta;
pub const maximum_trace_records: usize = 384;
pub const absent = std.math.maxInt(u64);

const plan_domain = "glacier-workload-closed-loop-plan-v1\x00";
const plan_wire_domain = "glacier-workload-closed-loop-plan-wire-v1\x00";
const candidate_domain = "glacier-workload-closed-loop-candidate-v1\x00";
const outcome_domain = "glacier-workload-closed-loop-outcome-v1\x00";
const outcome_section_domain =
    "glacier-workload-closed-loop-outcome-section-v1\x00";
const trace_record_domain =
    "glacier-workload-closed-loop-trace-record-v1\x00";
const trace_domain = "glacier-workload-closed-loop-trace-v1\x00";
const summary_domain = "glacier-workload-closed-loop-summary-v1\x00";
const result_domain = "glacier-workload-closed-loop-result-v1\x00";
const result_wire_domain = "glacier-workload-closed-loop-result-wire-v1\x00";

pub const Error = qos.Error || resource_bank.Error || error{
    ArithmeticOverflow,
    BufferTooSmall,
    CandidateLimitExceeded,
    DriverStepLimitExceeded,
    IncompleteCampaign,
    InvalidEvidence,
    InvalidPlan,
    InvariantViolation,
    ServiceLimitExceeded,
    TraceLimitExceeded,
};

pub const PhaseV1 = enum(u64) {
    admit_due = 1,
    apply_actions = 2,
    service_retire = 3,
    seal_step = 4,
    close = 5,
};

pub const EventKindV1 = enum(u64) {
    admission_accepted = 0,
    admission_rejected = 1,
    service = 2,
    cancel = 3,
    retire = 4,
    close = 5,
    credit_sealed = 6,
    credit_exhausted = 7,
};

pub const TriggerKindV1 = enum(u64) {
    initial = 0,
    completed = 1,
    rejected = 2,
    cancelled = 3,
    timed_out = 4,
};

pub const CandidateV1 = struct {
    ordinal: u64,
    family: model.ModelFamilyIdV1,
    operation: model.OperationIdV1,
    media_kind: media.MediaKindV1,
    profile_sha256: Digest,
    weight: u16,
    work_quanta: u64,
    /// Relative to the scheduler logical tick at admission. Zero disables it.
    deadline_budget_quanta: u64 = 0,
    /// Relative to the submission driver step. `absent` means no action.
    terminal_action_after_steps: u64 = absent,
    terminal_action: workload.TerminalActionV1 = .none,
    fairness_member: bool = true,
    tenant_key: u64,
    request_key: u64,
    request_generation: u64,
    resource_owner_key: u64,
    claim: resource_bank.Claim,
};

pub const CandidatePlanV1 = struct {
    media_kind: media.MediaKindV1,
    weight: u16,
    work_quanta: u64,
    deadline_budget_quanta: u64 = 0,
    terminal_action_after_steps: u64 = absent,
    terminal_action: workload.TerminalActionV1 = .none,
    fairness_member: bool = true,
    identity: workload.WorkItemIdentityV1,
};

pub fn makeCandidateV1(
    ordinal: u64,
    candidate_plan: CandidatePlanV1,
) CandidateV1 {
    const profile = workload.profileForKindV1(candidate_plan.media_kind);
    return .{
        .ordinal = ordinal,
        .family = profile.family,
        .operation = profile.operation,
        .media_kind = candidate_plan.media_kind,
        .profile_sha256 = profile.sha256,
        .weight = candidate_plan.weight,
        .work_quanta = candidate_plan.work_quanta,
        .deadline_budget_quanta = candidate_plan.deadline_budget_quanta,
        .terminal_action_after_steps = candidate_plan.terminal_action_after_steps,
        .terminal_action = candidate_plan.terminal_action,
        .fairness_member = candidate_plan.fairness_member,
        .tenant_key = candidate_plan.identity.tenant_key,
        .request_key = candidate_plan.identity.request_key,
        .request_generation = candidate_plan.identity.request_generation,
        .resource_owner_key = candidate_plan.identity.resource_owner_key,
        .claim = profile.claim,
    };
}

pub const PlanV1 = struct {
    seed: u64,
    in_flight_target: u32,
    capacity: u32,
    max_driver_steps: u64,
    max_service_quanta: u64,
    fairness_start_tick: u64,
    fairness_end_tick: u64,
    bank_epoch: u64,
    scheduler_epoch: u64,
    max_weight: u16,
    max_projection_quanta: u64,
    max_projection_operations: u64,
    limits: resource_bank.Limits,
    challenge: Digest,
    candidates: []const CandidateV1,
};

pub const OutcomeV1 = struct {
    ordinal: u64,
    candidate_sha256: Digest,
    lineage_index: u64,
    lineage_generation: u64,
    predecessor_ordinal: u64 = absent,
    trigger_kind: TriggerKindV1 = .initial,
    trigger_terminal_step: u64 = absent,
    trigger_trace_sha256: Digest = zero_digest,
    trigger_credit_sha256: Digest = zero_digest,
    submission_step: u64,
    scheduler_slot_index: u64 = absent,
    scheduler_slot_generation: u64 = 0,
    kind: workload.OutcomeKindV1,
    rejection_reason: qos.RejectionReason = .none,
    terminal_action: workload.TerminalActionV1 = .none,
    admitted_step: u64 = absent,
    first_service_step: u64 = absent,
    terminal_step: u64,
    served_quanta: u64 = 0,
    maximum_wait_quanta: u64 = 0,
    admission_trace_sha256: Digest,
    terminal_trace_sha256: Digest,
    record_sha256: Digest,
};

pub const TraceRecordV1 = struct {
    sequence: u64,
    driver_step: u64,
    phase: PhaseV1,
    event_kind: EventKindV1,
    candidate_ordinal: u64,
    predecessor_ordinal: u64,
    lineage_index: u64,
    lineage_generation: u64,
    scheduler_event_sequence: u64,
    rejection_reason: qos.RejectionReason,
    terminal_action: workload.TerminalActionV1,
    logical_tick_before: u64,
    logical_tick_after: u64,
    remaining_before: u64,
    remaining_after: u64,
    wait_quanta: u64,
    active_before: u64,
    active_after: u64,
    due_before: u64,
    due_after: u64,
    candidate_cursor_after: u64,
    record_sha256: Digest,
};

pub const SummaryV1 = struct {
    in_flight_target: u64,
    capacity: u64,
    candidate_budget: u64,
    attempted: u64,
    admitted: u64,
    rejected: u64,
    completed: u64,
    cancelled: u64,
    timed_out: u64,
    service_quanta: u64,
    driver_steps: u64,
    final_logical_tick: u64,
    maximum_active: u64,
    maximum_due_credits: u64,
    maximum_live_receipts: u64,
    replacement_attempts: u64,
    replacements_after_completed: u64,
    replacements_after_rejected: u64,
    replacements_after_cancelled: u64,
    replacements_after_timed_out: u64,
    credits_sealed: u64,
    credits_exhausted: u64,
    lineage_count: u64,
    maximum_lineage_generation: u64,
    peak_host_bytes: u64,
    peak: resource_bank.Claim,
    maximum_wait_quanta: u64,
    maximum_service_gap: u64,
    fairness_cross_product_error: u64,
    final_active: u64,
    final_due_credits: u64,
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
    plan_sha256: Digest,
    outcome_sha256: Digest,
    trace_sha256: Digest,
    summary_sha256: Digest,
    result_sha256: Digest,
    outcomes: []const OutcomeV1,
    trace: []const TraceRecordV1,
    summary: SummaryV1,
};

const RuntimeState = enum {
    pending,
    active,
    terminal,
};

const RuntimeCandidate = struct {
    state: RuntimeState = .pending,
    handle: qos.Handle = .{},
    lineage_index: u64 = absent,
    lineage_generation: u64 = 0,
    predecessor_ordinal: u64 = absent,
    trigger_kind: TriggerKindV1 = .initial,
    trigger_terminal_step: u64 = absent,
    trigger_trace_sha256: Digest = zero_digest,
    trigger_credit_sha256: Digest = zero_digest,
    submission_step: u64 = absent,
    admitted_step: u64 = absent,
    first_service_step: u64 = absent,
    terminal_step: u64 = absent,
    served_quanta: u64 = 0,
    fairness_quanta: u64 = 0,
    maximum_wait_quanta: u64 = 0,
    admission_trace_sha256: Digest = zero_digest,
    terminal_trace_sha256: Digest = zero_digest,
    outcome: ?workload.OutcomeKindV1 = null,
    rejection_reason: qos.RejectionReason = .none,
    terminal_action: workload.TerminalActionV1 = .none,
};

const CreditV1 = struct {
    predecessor_ordinal: u64,
    trigger_kind: TriggerKindV1,
    terminal_step: u64,
    terminal_trace_sha256: Digest,
    credit_trace_sha256: Digest = zero_digest,
    lineage_index: u64,
    lineage_generation: u64,
};

pub const StorageV1 = struct {
    bank_slots: []resource_bank.Slot,
    scheduler_slots: []qos.Slot,
    scheduler_projection: []qos.ProjectionSlot,
    verifier_slots: []qos.Slot,
    verifier_projection: []qos.ProjectionSlot,
    runtime_candidates: []RuntimeCandidate,
    outcomes: []OutcomeV1,
    trace: []TraceRecordV1,
    due_credits: []CreditV1,
    step_credits: []CreditV1,
};

pub const MaximumStorageV1 = struct {
    bank_slots: [maximum_candidates]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** maximum_candidates,
    scheduler_slots: [maximum_candidates]qos.Slot =
        [_]qos.Slot{.{}} ** maximum_candidates,
    scheduler_projection: [maximum_candidates]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** maximum_candidates,
    verifier_slots: [maximum_candidates]qos.Slot =
        [_]qos.Slot{.{}} ** maximum_candidates,
    verifier_projection: [maximum_candidates]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** maximum_candidates,
    runtime_candidates: [maximum_candidates]RuntimeCandidate =
        [_]RuntimeCandidate{.{}} ** maximum_candidates,
    outcomes: [maximum_candidates]OutcomeV1 = undefined,
    trace: [maximum_trace_records]TraceRecordV1 = undefined,
    due_credits: [maximum_candidates]CreditV1 = undefined,
    step_credits: [maximum_candidates]CreditV1 = undefined,

    pub fn interface(self: *MaximumStorageV1) StorageV1 {
        return .{
            .bank_slots = &self.bank_slots,
            .scheduler_slots = &self.scheduler_slots,
            .scheduler_projection = &self.scheduler_projection,
            .verifier_slots = &self.verifier_slots,
            .verifier_projection = &self.verifier_projection,
            .runtime_candidates = &self.runtime_candidates,
            .outcomes = &self.outcomes,
            .trace = &self.trace,
            .due_credits = &self.due_credits,
            .step_credits = &self.step_credits,
        };
    }
};

pub fn makeReferenceCandidatesV1() [10]CandidateV1 {
    var candidates: [10]CandidateV1 = undefined;
    const kinds = [_]media.MediaKindV1{
        .image,
        .audio,
        .video,
        .audio,
        .image,
        .video,
        .image,
        .image,
        .image,
        .audio,
    };
    const weights = [_]u16{ 1, 2, 4, 1, 2, 4, 1, 2, 4, 1 };
    const work = [_]u64{ 4, 4, 1, 3, 3, 1, 1, 2, 2, 9 };
    for (0..candidates.len) |index| {
        const identity: u64 = @intCast(index + 1);
        candidates[index] = makeCandidateV1(@intCast(index), .{
            .media_kind = kinds[index],
            .weight = weights[index],
            .work_quanta = work[index],
            .identity = .{
                .tenant_key = 0x4100_0000_0000_0000 | identity,
                .request_key = 0x4200_0000_0000_0000 | identity,
                .request_generation = 1,
                .resource_owner_key = 0x4300_0000_0000_0000 | identity,
            },
        });
    }
    candidates[0].terminal_action = .cancel;
    candidates[0].terminal_action_after_steps = 1;
    candidates[1].terminal_action = .timeout;
    candidates[1].terminal_action_after_steps = 1;
    candidates[3].deadline_budget_quanta = 1;
    candidates[4].terminal_action = .cancel;
    candidates[4].terminal_action_after_steps = 0;
    candidates[9].deadline_budget_quanta = 8;
    return candidates;
}

pub fn referencePlanV1(
    candidates: *const [10]CandidateV1,
) PlanV1 {
    return .{
        .seed = 0x4757_434c_2026_0001,
        .in_flight_target = 3,
        .capacity = 4,
        .max_driver_steps = 64,
        .max_service_quanta = 64,
        .fairness_start_tick = 0,
        .fairness_end_tick = 16,
        .bank_epoch = 0x4757_434c_4241_0001,
        .scheduler_epoch = 0x4757_434c_5153_0001,
        .max_weight = 4,
        .max_projection_quanta = 8,
        .max_projection_operations = 4096,
        .limits = .{
            .host_bytes = 4148,
            .queue_slots = 4,
        },
        .challenge = [_]u8{
            0x57, 0x33, 0x2d, 0x63, 0x6c, 0x6f, 0x73, 0x65,
            0x64, 0x2d, 0x6c, 0x6f, 0x6f, 0x70, 0x2d, 0x72,
            0x65, 0x66, 0x65, 0x72, 0x65, 0x6e, 0x63, 0x65,
            0x2d, 0x76, 0x31, 0x00, 0x00, 0x00, 0x00, 0x01,
        },
        .candidates = candidates,
    };
}

pub fn validatePlanV1(plan: PlanV1) Error!void {
    if (plan.seed == 0 or
        plan.in_flight_target == 0 or
        plan.capacity == 0 or
        plan.in_flight_target > plan.capacity or
        plan.capacity > maximum_candidates or
        plan.max_driver_steps == 0 or
        plan.max_driver_steps > maximum_driver_steps or
        plan.max_service_quanta == 0 or
        plan.max_service_quanta > maximum_service_quanta or
        plan.fairness_end_tick <= plan.fairness_start_tick or
        plan.bank_epoch == 0 or
        plan.scheduler_epoch == 0 or
        plan.max_weight == 0 or
        plan.max_projection_quanta == 0 or
        plan.max_projection_operations == 0 or
        plan.candidates.len < plan.in_flight_target or
        plan.candidates.len < 2 or
        plan.candidates.len > maximum_candidates or
        std.mem.eql(u8, &plan.challenge, &zero_digest) or
        plan.limits.queue_slots < plan.capacity)
        return Error.InvalidPlan;

    var total_work: u64 = 0;
    var fairness_members: usize = 0;
    for (plan.candidates, 0..) |candidate, index| {
        if (candidate.ordinal != index or
            candidate.weight == 0 or
            candidate.weight > plan.max_weight or
            candidate.work_quanta == 0 or
            candidate.deadline_budget_quanta >
                plan.max_projection_quanta or
            candidate.tenant_key == 0 or
            candidate.request_key == 0 or
            candidate.request_generation == 0 or
            candidate.resource_owner_key == 0 or
            (candidate.terminal_action == .none and
                candidate.terminal_action_after_steps != absent) or
            (candidate.terminal_action != .none and
                candidate.terminal_action_after_steps >=
                    plan.max_driver_steps))
            return Error.InvalidPlan;
        const profile = workload.profileForKindV1(candidate.media_kind);
        if (candidate.family != profile.family or
            candidate.operation != profile.operation or
            !std.mem.eql(
                u8,
                &candidate.profile_sha256,
                &profile.sha256,
            ) or
            !std.meta.eql(candidate.claim, profile.claim))
            return Error.InvalidPlan;
        total_work = checkedAdd(total_work, candidate.work_quanta) catch
            return Error.ArithmeticOverflow;
        if (candidate.fairness_member) fairness_members += 1;
        for (plan.candidates[0..index]) |prior| {
            if (prior.tenant_key == candidate.tenant_key or
                prior.request_key == candidate.request_key or
                prior.resource_owner_key == candidate.resource_owner_key)
                return Error.InvalidPlan;
        }
    }
    const maximum_records = checkedAdd(
        checkedAdd(
            plan.max_service_quanta,
            std.math.mul(
                u64,
                @intCast(plan.candidates.len),
                4,
            ) catch return Error.ArithmeticOverflow,
        ) catch return Error.ArithmeticOverflow,
        1,
    ) catch return Error.ArithmeticOverflow;
    if (total_work > plan.max_service_quanta or
        fairness_members < 2 or
        maximum_records > maximum_trace_records)
        return Error.InvalidPlan;
}

const RunContext = struct {
    plan: PlanV1,
    storage: StorageV1,
    scheduler: *qos.Scheduler,
    verifier: *qos.Verifier,
    trace_count: usize = 0,
    due_count: usize = 0,
    step_credit_count: usize = 0,
    candidate_cursor: usize = 0,
    active_count: u64 = 0,
    maximum_active: u64 = 0,
    maximum_due: u64 = 0,
    maximum_live_receipts: u64 = 0,
    service_quanta: u64 = 0,
    credits_sealed: u64 = 0,
    credits_exhausted: u64 = 0,

    fn appendSchedulerTrace(
        self: *RunContext,
        step: u64,
        phase: PhaseV1,
        kind: EventKindV1,
        candidate_index: usize,
        active_before: u64,
        due_before: u64,
        event: qos.EventV1,
    ) Error!Digest {
        const runtime = self.storage.runtime_candidates[candidate_index];
        return self.appendTrace(.{
            .sequence = @intCast(self.trace_count),
            .driver_step = step,
            .phase = phase,
            .event_kind = kind,
            .candidate_ordinal = self.plan.candidates[candidate_index].ordinal,
            .predecessor_ordinal = runtime.predecessor_ordinal,
            .lineage_index = runtime.lineage_index,
            .lineage_generation = runtime.lineage_generation,
            .scheduler_event_sequence = event.event_sequence,
            .rejection_reason = event.rejection_reason,
            .terminal_action = runtime.terminal_action,
            .logical_tick_before = event.logical_tick_before,
            .logical_tick_after = event.logical_tick_after,
            .remaining_before = event.remaining_before,
            .remaining_after = event.remaining_after,
            .wait_quanta = event.wait_quanta,
            .active_before = active_before,
            .active_after = self.active_count,
            .due_before = due_before,
            .due_after = self.due_count,
            .candidate_cursor_after = self.candidate_cursor,
            .record_sha256 = zero_digest,
        });
    }

    fn appendSyntheticTrace(
        self: *RunContext,
        step: u64,
        kind: EventKindV1,
        credit: CreditV1,
        due_before: u64,
    ) Error!Digest {
        const snapshot = try self.scheduler.snapshot();
        return self.appendTrace(.{
            .sequence = @intCast(self.trace_count),
            .driver_step = step,
            .phase = if (kind == .credit_sealed)
                .seal_step
            else
                .admit_due,
            .event_kind = kind,
            .candidate_ordinal = credit.predecessor_ordinal,
            .predecessor_ordinal = credit.predecessor_ordinal,
            .lineage_index = credit.lineage_index,
            .lineage_generation = credit.lineage_generation,
            .scheduler_event_sequence = absent,
            .rejection_reason = .none,
            .terminal_action = .none,
            .logical_tick_before = snapshot.logical_tick,
            .logical_tick_after = snapshot.logical_tick,
            .remaining_before = 0,
            .remaining_after = 0,
            .wait_quanta = 0,
            .active_before = self.active_count,
            .active_after = self.active_count,
            .due_before = due_before,
            .due_after = self.due_count,
            .candidate_cursor_after = self.candidate_cursor,
            .record_sha256 = zero_digest,
        });
    }

    fn appendTrace(
        self: *RunContext,
        record_input: TraceRecordV1,
    ) Error!Digest {
        if (self.trace_count >= self.storage.trace.len)
            return Error.TraceLimitExceeded;
        var record = record_input;
        record.record_sha256 = traceRecordSha256V1(record);
        self.storage.trace[self.trace_count] = record;
        self.trace_count += 1;
        return record.record_sha256;
    }

    fn addStepCredit(
        self: *RunContext,
        candidate_index: usize,
        terminal_trace_sha256: Digest,
    ) Error!void {
        if (self.step_credit_count >= self.storage.step_credits.len)
            return Error.CandidateLimitExceeded;
        const runtime = self.storage.runtime_candidates[candidate_index];
        self.storage.step_credits[self.step_credit_count] = .{
            .predecessor_ordinal = self.plan.candidates[candidate_index].ordinal,
            .trigger_kind = triggerFromOutcome(runtime.outcome.?),
            .terminal_step = runtime.terminal_step,
            .terminal_trace_sha256 = terminal_trace_sha256,
            .lineage_index = runtime.lineage_index,
            .lineage_generation = runtime.lineage_generation,
        };
        self.step_credit_count += 1;
    }

    fn attemptCandidate(
        self: *RunContext,
        candidate_index: usize,
        step: u64,
        lineage_index: u64,
        lineage_generation: u64,
        predecessor: ?CreditV1,
    ) Error!void {
        const candidate = self.plan.candidates[candidate_index];
        var runtime = &self.storage.runtime_candidates[candidate_index];
        runtime.* = .{
            .lineage_index = lineage_index,
            .lineage_generation = lineage_generation,
            .predecessor_ordinal = if (predecessor) |credit|
                credit.predecessor_ordinal
            else
                absent,
            .trigger_kind = if (predecessor) |credit|
                credit.trigger_kind
            else
                .initial,
            .trigger_terminal_step = if (predecessor) |credit|
                credit.terminal_step
            else
                absent,
            .trigger_trace_sha256 = if (predecessor) |credit|
                credit.terminal_trace_sha256
            else
                zero_digest,
            .trigger_credit_sha256 = if (predecessor) |credit|
                credit.credit_trace_sha256
            else
                zero_digest,
            .submission_step = step,
        };
        const scheduler_before = try self.scheduler.snapshot();
        const deadline_tick = if (candidate.deadline_budget_quanta == 0)
            0
        else
            try checkedAdd(
                scheduler_before.logical_tick,
                candidate.deadline_budget_quanta,
            );
        const due_before: u64 = @intCast(self.due_count);
        if (predecessor != null) {
            if (self.due_count == 0) return Error.InvariantViolation;
            self.due_count -= 1;
        }
        const active_before = self.active_count;
        const decision = try self.scheduler.admit(.{
            .tenant_key = candidate.tenant_key,
            .request_key = candidate.request_key,
            .request_generation = candidate.request_generation,
            .resource_owner_key = candidate.resource_owner_key,
            .weight = candidate.weight,
            .work_quanta = candidate.work_quanta,
            .deadline_tick = deadline_tick,
            .claim = candidate.claim,
        });
        self.candidate_cursor += 1;
        switch (decision) {
            .admitted => |admission| {
                runtime.state = .active;
                runtime.handle = admission.handle;
                runtime.admitted_step = step;
                self.active_count += 1;
                self.maximum_active = @max(
                    self.maximum_active,
                    self.active_count,
                );
                if (self.active_count > self.plan.in_flight_target)
                    return Error.InvariantViolation;
                try self.verifier.apply(admission.event);
                runtime.admission_trace_sha256 =
                    try self.appendSchedulerTrace(
                        step,
                        .admit_due,
                        .admission_accepted,
                        candidate_index,
                        active_before,
                        due_before,
                        admission.event,
                    );
                const bank_snapshot = try self.scheduler.bank.snapshot();
                self.maximum_live_receipts = @max(
                    self.maximum_live_receipts,
                    @as(
                        u64,
                        @intCast(bank_snapshot.committed_receipts),
                    ),
                );
            },
            .rejected => |event| {
                if (event.rejection_reason == .no_slot or
                    event.rejection_reason == .duplicate_tenant)
                    return Error.InvariantViolation;
                runtime.state = .terminal;
                runtime.outcome = .rejected;
                runtime.rejection_reason = event.rejection_reason;
                runtime.terminal_step = step;
                try self.verifier.apply(event);
                const trace_root = try self.appendSchedulerTrace(
                    step,
                    .admit_due,
                    .admission_rejected,
                    candidate_index,
                    active_before,
                    due_before,
                    event,
                );
                runtime.admission_trace_sha256 = trace_root;
                runtime.terminal_trace_sha256 = trace_root;
                try self.addStepCredit(candidate_index, trace_root);
            },
        }
    }

    fn findActiveByHandle(
        self: *RunContext,
        handle: qos.Handle,
    ) Error!usize {
        for (
            self.storage.runtime_candidates[0..self.candidate_cursor],
            0..,
        ) |runtime, index| {
            if (runtime.state == .active and
                std.meta.eql(runtime.handle, handle))
                return index;
        }
        return Error.InvariantViolation;
    }
};

pub fn runPlanV1(
    plan: PlanV1,
    storage: StorageV1,
    output: *ResultV1,
) Error!void {
    try validatePlanV1(plan);
    const capacity: usize = @intCast(plan.capacity);
    if (storage.bank_slots.len < capacity or
        storage.scheduler_slots.len < capacity or
        storage.scheduler_projection.len < capacity or
        storage.verifier_slots.len < capacity or
        storage.verifier_projection.len < capacity or
        storage.runtime_candidates.len < plan.candidates.len or
        storage.outcomes.len < plan.candidates.len or
        storage.trace.len < maximum_trace_records or
        storage.due_credits.len < plan.candidates.len or
        storage.step_credits.len < plan.candidates.len)
        return Error.BufferTooSmall;

    const bank_slots = storage.bank_slots[0..capacity];
    const scheduler_slots = storage.scheduler_slots[0..capacity];
    const scheduler_projection = storage.scheduler_projection[0..capacity];
    const verifier_slots = storage.verifier_slots[0..capacity];
    const verifier_projection = storage.verifier_projection[0..capacity];
    for (storage.runtime_candidates[0..plan.candidates.len]) |*runtime|
        runtime.* = .{};

    var bank = try resource_bank.Bank.init(
        bank_slots,
        plan.limits,
        plan.bank_epoch,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = scheduler_slots,
            .projection = scheduler_projection,
        },
        .{
            .scheduler_epoch = plan.scheduler_epoch,
            .challenge = plan.challenge,
            .max_weight = plan.max_weight,
            .max_projection_quanta = plan.max_projection_quanta,
            .max_projection_operations = plan.max_projection_operations,
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
    var context: RunContext = .{
        .plan = plan,
        .storage = storage,
        .scheduler = &scheduler,
        .verifier = &verifier,
    };
    errdefer {
        for (
            storage.runtime_candidates[0..context.candidate_cursor],
        ) |runtime| {
            if (runtime.state == .active)
                _ = scheduler.cancel(runtime.handle) catch {};
        }
    }

    var completed = false;
    var driver_steps: u64 = 0;
    var step: u64 = 0;
    while (step < plan.max_driver_steps) : (step += 1) {
        context.step_credit_count = 0;

        if (step == 0) {
            const initial_count: usize = @intCast(plan.in_flight_target);
            for (0..initial_count) |index| {
                try context.attemptCandidate(
                    index,
                    step,
                    @intCast(index),
                    1,
                    null,
                );
            }
        } else {
            const due_at_start = context.due_count;
            for (storage.due_credits[0..due_at_start]) |credit| {
                const due_before: u64 = @intCast(context.due_count);
                if (context.candidate_cursor < plan.candidates.len) {
                    const candidate_index = context.candidate_cursor;
                    try context.attemptCandidate(
                        candidate_index,
                        step,
                        credit.lineage_index,
                        try checkedAdd(credit.lineage_generation, 1),
                        credit,
                    );
                } else {
                    context.due_count -= 1;
                    _ = try context.appendSyntheticTrace(
                        step,
                        .credit_exhausted,
                        credit,
                        due_before,
                    );
                    context.credits_exhausted += 1;
                    continue;
                }
            }
            if (context.due_count != 0)
                return Error.InvariantViolation;
        }

        for (
            plan.candidates[0..context.candidate_cursor],
            0..,
        ) |candidate, index| {
            const runtime = &storage.runtime_candidates[index];
            if (runtime.state != .active or
                candidate.terminal_action == .none)
                continue;
            const action_step = try checkedAdd(
                runtime.submission_step,
                candidate.terminal_action_after_steps,
            );
            if (action_step != step) continue;
            const active_before = context.active_count;
            const event = try scheduler.cancel(runtime.handle);
            context.active_count -= 1;
            runtime.state = .terminal;
            runtime.terminal_step = step;
            runtime.terminal_action = candidate.terminal_action;
            runtime.outcome = switch (candidate.terminal_action) {
                .cancel => .cancelled,
                .timeout => .timed_out,
                .none => unreachable,
            };
            try verifier.apply(event);
            const root = try context.appendSchedulerTrace(
                step,
                .apply_actions,
                .cancel,
                index,
                active_before,
                @intCast(context.due_count),
                event,
            );
            runtime.terminal_trace_sha256 = root;
            try context.addStepCredit(index, root);
        }

        if (context.active_count != 0) {
            const active_before = context.active_count;
            const permit = try scheduler.prepareService();
            const index = try context.findActiveByHandle(permit.handle);
            const event = try scheduler.commitService(permit);
            const runtime = &storage.runtime_candidates[index];
            if (runtime.first_service_step == absent)
                runtime.first_service_step = step;
            runtime.served_quanta = try checkedAdd(
                runtime.served_quanta,
                1,
            );
            runtime.maximum_wait_quanta = @max(
                runtime.maximum_wait_quanta,
                event.wait_quanta,
            );
            if (plan.candidates[index].fairness_member and
                event.logical_tick_after > plan.fairness_start_tick and
                event.logical_tick_after <= plan.fairness_end_tick)
                runtime.fairness_quanta = try checkedAdd(
                    runtime.fairness_quanta,
                    1,
                );
            context.service_quanta += 1;
            if (context.service_quanta > plan.max_service_quanta)
                return Error.ServiceLimitExceeded;
            try verifier.apply(event);
            _ = try context.appendSchedulerTrace(
                step,
                .service_retire,
                .service,
                index,
                active_before,
                @intCast(context.due_count),
                event,
            );
            if (event.remaining_after == 0) {
                const retire_event = try scheduler.retire(runtime.handle);
                context.active_count -= 1;
                runtime.state = .terminal;
                runtime.outcome = .completed;
                runtime.terminal_step = step;
                try verifier.apply(retire_event);
                const root = try context.appendSchedulerTrace(
                    step,
                    .service_retire,
                    .retire,
                    index,
                    active_before,
                    @intCast(context.due_count),
                    retire_event,
                );
                runtime.terminal_trace_sha256 = root;
                try context.addStepCredit(index, root);
            }
        }

        for (
            storage.step_credits[0..context.step_credit_count],
        ) |credit_input| {
            if (context.due_count >= storage.due_credits.len)
                return Error.CandidateLimitExceeded;
            var credit = credit_input;
            const due_before: u64 = @intCast(context.due_count);
            context.due_count += 1;
            credit.credit_trace_sha256 =
                try context.appendSyntheticTrace(
                    step,
                    .credit_sealed,
                    credit,
                    due_before,
                );
            storage.due_credits[context.due_count - 1] = credit;
            context.credits_sealed += 1;
        }
        context.maximum_due = @max(
            context.maximum_due,
            @as(u64, @intCast(context.due_count)),
        );

        if (context.active_count > plan.in_flight_target)
            return Error.InvariantViolation;
        if (context.candidate_cursor == plan.candidates.len and
            context.active_count == 0 and
            context.due_count == 0)
        {
            driver_steps = step + 1;
            completed = true;
            break;
        }
    }
    if (!completed) return Error.DriverStepLimitExceeded;

    const scheduler_before_close = try scheduler.snapshot();
    const close_event = try scheduler.close();
    try verifier.apply(close_event);
    const close_record: TraceRecordV1 = .{
        .sequence = @intCast(context.trace_count),
        .driver_step = driver_steps,
        .phase = .close,
        .event_kind = .close,
        .candidate_ordinal = absent,
        .predecessor_ordinal = absent,
        .lineage_index = absent,
        .lineage_generation = 0,
        .scheduler_event_sequence = close_event.event_sequence,
        .rejection_reason = .none,
        .terminal_action = .none,
        .logical_tick_before = close_event.logical_tick_before,
        .logical_tick_after = close_event.logical_tick_after,
        .remaining_before = 0,
        .remaining_after = 0,
        .wait_quanta = 0,
        .active_before = context.active_count,
        .active_after = context.active_count,
        .due_before = context.due_count,
        .due_after = context.due_count,
        .candidate_cursor_after = context.candidate_cursor,
        .record_sha256 = zero_digest,
    };
    _ = try context.appendTrace(close_record);
    _ = try verifier.finish(close_event.event_sha256);
    const scheduler_final = try scheduler.snapshot();
    const bank_final = try bank.snapshot();
    if (scheduler_before_close.active != 0 or
        scheduler_before_close.finished != 0)
        return Error.InvariantViolation;

    for (
        plan.candidates,
        storage.runtime_candidates[0..plan.candidates.len],
        storage.outcomes[0..plan.candidates.len],
    ) |candidate, runtime, *outcome| {
        const kind = runtime.outcome orelse
            return Error.IncompleteCampaign;
        var value: OutcomeV1 = .{
            .ordinal = candidate.ordinal,
            .candidate_sha256 = candidateSha256V1(candidate),
            .lineage_index = runtime.lineage_index,
            .lineage_generation = runtime.lineage_generation,
            .predecessor_ordinal = runtime.predecessor_ordinal,
            .trigger_kind = runtime.trigger_kind,
            .trigger_terminal_step = runtime.trigger_terminal_step,
            .trigger_trace_sha256 = runtime.trigger_trace_sha256,
            .trigger_credit_sha256 = runtime.trigger_credit_sha256,
            .submission_step = runtime.submission_step,
            .scheduler_slot_index = if (kind == .rejected)
                absent
            else
                runtime.handle.slot_index,
            .scheduler_slot_generation = if (kind == .rejected)
                0
            else
                runtime.handle.slot_generation,
            .kind = kind,
            .rejection_reason = runtime.rejection_reason,
            .terminal_action = runtime.terminal_action,
            .admitted_step = runtime.admitted_step,
            .first_service_step = runtime.first_service_step,
            .terminal_step = runtime.terminal_step,
            .served_quanta = runtime.served_quanta,
            .maximum_wait_quanta = runtime.maximum_wait_quanta,
            .admission_trace_sha256 = runtime.admission_trace_sha256,
            .terminal_trace_sha256 = runtime.terminal_trace_sha256,
            .record_sha256 = zero_digest,
        };
        value.record_sha256 = outcomeRecordSha256V1(value);
        outcome.* = value;
    }

    const outcomes = storage.outcomes[0..plan.candidates.len];
    const trace = storage.trace[0..context.trace_count];
    const summary = try summarizeV1(
        plan,
        storage.runtime_candidates[0..plan.candidates.len],
        outcomes,
        driver_steps,
        context,
        scheduler_final,
        bank_final,
    );
    const plan_root = planSha256V1(plan);
    const outcome_root = outcomeSha256V1(outcomes);
    const trace_root = traceSha256V1(trace);
    const summary_root = summarySha256V1(summary);
    const result_root = resultSha256V1(
        plan_root,
        outcome_root,
        trace_root,
        summary_root,
    );
    const result: ResultV1 = .{
        .plan_sha256 = plan_root,
        .outcome_sha256 = outcome_root,
        .trace_sha256 = trace_root,
        .summary_sha256 = summary_root,
        .result_sha256 = result_root,
        .outcomes = outcomes,
        .trace = trace,
        .summary = summary,
    };
    try validateResultStructureV1(plan, result);
    output.* = result;
}

fn summarizeV1(
    plan: PlanV1,
    runtime: []const RuntimeCandidate,
    outcomes: []const OutcomeV1,
    driver_steps: u64,
    context: RunContext,
    scheduler_final: qos.SnapshotV1,
    bank_final: resource_bank.Snapshot,
) Error!SummaryV1 {
    var admitted: u64 = 0;
    var rejected: u64 = 0;
    var completed: u64 = 0;
    var cancelled: u64 = 0;
    var timed_out: u64 = 0;
    var maximum_wait: u64 = 0;
    var maximum_generation: u64 = 0;
    var after_completed: u64 = 0;
    var after_rejected: u64 = 0;
    var after_cancelled: u64 = 0;
    var after_timed_out: u64 = 0;
    for (outcomes) |outcome| {
        maximum_wait = @max(
            maximum_wait,
            outcome.maximum_wait_quanta,
        );
        maximum_generation = @max(
            maximum_generation,
            outcome.lineage_generation,
        );
        switch (outcome.kind) {
            .completed => {
                admitted += 1;
                completed += 1;
            },
            .rejected => rejected += 1,
            .cancelled => {
                admitted += 1;
                cancelled += 1;
            },
            .timed_out => {
                admitted += 1;
                timed_out += 1;
            },
        }
        switch (outcome.trigger_kind) {
            .initial => {},
            .completed => after_completed += 1,
            .rejected => after_rejected += 1,
            .cancelled => after_cancelled += 1,
            .timed_out => after_timed_out += 1,
        }
    }
    var fairness_error: u64 = 0;
    for (plan.candidates, runtime, 0..) |left, left_runtime, left_index| {
        if (!left.fairness_member) continue;
        for (
            plan.candidates[left_index + 1 ..],
            runtime[left_index + 1 ..],
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
            fairness_error = @max(
                fairness_error,
                if (left_scaled >= right_scaled)
                    left_scaled - right_scaled
                else
                    right_scaled - left_scaled,
            );
        }
    }
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
        .in_flight_target = plan.in_flight_target,
        .capacity = plan.capacity,
        .candidate_budget = @intCast(plan.candidates.len),
        .attempted = @intCast(plan.candidates.len),
        .admitted = admitted,
        .rejected = rejected,
        .completed = completed,
        .cancelled = cancelled,
        .timed_out = timed_out,
        .service_quanta = context.service_quanta,
        .driver_steps = driver_steps,
        .final_logical_tick = scheduler_final.logical_tick,
        .maximum_active = context.maximum_active,
        .maximum_due_credits = context.maximum_due,
        .maximum_live_receipts = context.maximum_live_receipts,
        .replacement_attempts = plan.candidates.len - plan.in_flight_target,
        .replacements_after_completed = after_completed,
        .replacements_after_rejected = after_rejected,
        .replacements_after_cancelled = after_cancelled,
        .replacements_after_timed_out = after_timed_out,
        .credits_sealed = context.credits_sealed,
        .credits_exhausted = context.credits_exhausted,
        .lineage_count = plan.in_flight_target,
        .maximum_lineage_generation = maximum_generation,
        .peak_host_bytes = bank_final.peak_host_bytes,
        .peak = bank_final.peak,
        .maximum_wait_quanta = maximum_wait,
        .maximum_service_gap = scheduler_final.maximum_service_gap,
        .fairness_cross_product_error = fairness_error,
        .final_active = scheduler_final.active,
        .final_due_credits = context.due_count,
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

pub fn validateResultStructureV1(
    plan: PlanV1,
    result: ResultV1,
) Error!void {
    try validatePlanV1(plan);
    if (result.outcomes.len != plan.candidates.len or
        result.trace.len == 0 or
        result.trace.len > maximum_trace_records or
        !std.mem.eql(
            u8,
            &result.plan_sha256,
            &planSha256V1(plan),
        ) or
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
        !std.mem.eql(
            u8,
            &result.result_sha256,
            &resultSha256V1(
                result.plan_sha256,
                result.outcome_sha256,
                result.trace_sha256,
                result.summary_sha256,
            ),
        ) or
        result.summary.attempted != plan.candidates.len or
        result.summary.maximum_active > plan.in_flight_target or
        result.summary.final_active != 0 or
        result.summary.final_due_credits != 0 or
        !result.summary.zero_orphan_ownership)
        return Error.InvalidEvidence;
    for (result.outcomes, 0..) |outcome, index| {
        if (outcome.ordinal != index or
            !std.mem.eql(
                u8,
                &outcome.candidate_sha256,
                &candidateSha256V1(plan.candidates[index]),
            ) or
            !std.mem.eql(
                u8,
                &outcome.record_sha256,
                &outcomeRecordSha256V1(outcome),
            ))
            return Error.InvalidEvidence;
        if (index < plan.in_flight_target) {
            if (outcome.trigger_kind != .initial or
                outcome.predecessor_ordinal != absent or
                outcome.submission_step != 0 or
                outcome.lineage_generation != 1)
                return Error.InvalidEvidence;
        } else if (outcome.trigger_kind == .initial or
            outcome.predecessor_ordinal == absent or
            outcome.submission_step !=
                outcome.trigger_terminal_step + 1)
            return Error.InvalidEvidence;
    }
    for (result.trace, 0..) |record, index| {
        if (record.sequence != index or
            !std.mem.eql(
                u8,
                &record.record_sha256,
                &traceRecordSha256V1(record),
            ))
            return Error.InvalidEvidence;
    }
}

pub fn validateResultByReplayV1(
    plan: PlanV1,
    result: ResultV1,
    storage: StorageV1,
) Error!void {
    try validateResultStructureV1(plan, result);
    var expected: ResultV1 = undefined;
    try runPlanV1(plan, storage, &expected);
    if (!std.mem.eql(
        u8,
        &expected.result_sha256,
        &result.result_sha256,
    ) or !std.meta.eql(expected.summary, result.summary))
        return Error.InvalidEvidence;
    for (expected.outcomes, result.outcomes) |actual, supplied| {
        if (!std.meta.eql(actual, supplied))
            return Error.InvalidEvidence;
    }
    for (expected.trace, result.trace) |actual, supplied| {
        if (!std.meta.eql(actual, supplied))
            return Error.InvalidEvidence;
    }
}

pub fn candidateSha256V1(candidate: CandidateV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(candidate_domain);
    hashU64(&hash, candidate_abi);
    hashU64(&hash, candidate.ordinal);
    hashU64(&hash, @intFromEnum(candidate.family));
    hashU64(&hash, @intFromEnum(candidate.operation));
    hashU64(&hash, @intFromEnum(candidate.media_kind));
    hash.update(&candidate.profile_sha256);
    hashU64(&hash, candidate.weight);
    hashU64(&hash, candidate.work_quanta);
    hashU64(&hash, candidate.deadline_budget_quanta);
    hashU64(&hash, candidate.terminal_action_after_steps);
    hashU64(&hash, @intFromEnum(candidate.terminal_action));
    hashU64(&hash, @intFromBool(candidate.fairness_member));
    hashU64(&hash, candidate.tenant_key);
    hashU64(&hash, candidate.request_key);
    hashU64(&hash, candidate.request_generation);
    hashU64(&hash, candidate.resource_owner_key);
    hashClaim(&hash, candidate.claim);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn planSha256V1(plan: PlanV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(plan_domain);
    hashU64(&hash, plan_abi);
    hashU64(&hash, plan.seed);
    hashU64(&hash, plan.in_flight_target);
    hashU64(&hash, plan.capacity);
    hashU64(&hash, plan.max_driver_steps);
    hashU64(&hash, plan.max_service_quanta);
    hashU64(&hash, plan.fairness_start_tick);
    hashU64(&hash, plan.fairness_end_tick);
    hashU64(&hash, plan.bank_epoch);
    hashU64(&hash, plan.scheduler_epoch);
    hashU64(&hash, plan.max_weight);
    hashU64(&hash, plan.max_projection_quanta);
    hashU64(&hash, plan.max_projection_operations);
    hashLimits(&hash, plan.limits);
    hash.update(&plan.challenge);
    hashU64(&hash, plan.candidates.len);
    for (plan.candidates) |candidate| {
        const root = candidateSha256V1(candidate);
        hash.update(&root);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn outcomeRecordSha256V1(outcome: OutcomeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(outcome_domain);
    hashU64(&hash, outcome_abi);
    hashU64(&hash, outcome.ordinal);
    hash.update(&outcome.candidate_sha256);
    hashU64(&hash, outcome.lineage_index);
    hashU64(&hash, outcome.lineage_generation);
    hashU64(&hash, outcome.predecessor_ordinal);
    hashU64(&hash, @intFromEnum(outcome.trigger_kind));
    hashU64(&hash, outcome.trigger_terminal_step);
    hash.update(&outcome.trigger_trace_sha256);
    hash.update(&outcome.trigger_credit_sha256);
    hashU64(&hash, outcome.submission_step);
    hashU64(&hash, outcome.scheduler_slot_index);
    hashU64(&hash, outcome.scheduler_slot_generation);
    hashU64(&hash, @intFromEnum(outcome.kind));
    hashU64(&hash, @intFromEnum(outcome.rejection_reason));
    hashU64(&hash, @intFromEnum(outcome.terminal_action));
    hashU64(&hash, outcome.admitted_step);
    hashU64(&hash, outcome.first_service_step);
    hashU64(&hash, outcome.terminal_step);
    hashU64(&hash, outcome.served_quanta);
    hashU64(&hash, outcome.maximum_wait_quanta);
    hash.update(&outcome.admission_trace_sha256);
    hash.update(&outcome.terminal_trace_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn outcomeSha256V1(outcomes: []const OutcomeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(outcome_section_domain);
    hashU64(&hash, outcome_abi);
    hashU64(&hash, outcomes.len);
    for (outcomes) |outcome| {
        const root = outcomeRecordSha256V1(outcome);
        hash.update(&root);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn traceRecordSha256V1(record: TraceRecordV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(trace_record_domain);
    hashU64(&hash, trace_abi);
    hashU64(&hash, record.sequence);
    hashU64(&hash, record.driver_step);
    hashU64(&hash, @intFromEnum(record.phase));
    hashU64(&hash, @intFromEnum(record.event_kind));
    hashU64(&hash, record.candidate_ordinal);
    hashU64(&hash, record.predecessor_ordinal);
    hashU64(&hash, record.lineage_index);
    hashU64(&hash, record.lineage_generation);
    hashU64(&hash, record.scheduler_event_sequence);
    hashU64(&hash, @intFromEnum(record.rejection_reason));
    hashU64(&hash, @intFromEnum(record.terminal_action));
    hashU64(&hash, record.logical_tick_before);
    hashU64(&hash, record.logical_tick_after);
    hashU64(&hash, record.remaining_before);
    hashU64(&hash, record.remaining_after);
    hashU64(&hash, record.wait_quanta);
    hashU64(&hash, record.active_before);
    hashU64(&hash, record.active_after);
    hashU64(&hash, record.due_before);
    hashU64(&hash, record.due_after);
    hashU64(&hash, record.candidate_cursor_after);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn traceSha256V1(trace: []const TraceRecordV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(trace_domain);
    hashU64(&hash, trace_abi);
    hashU64(&hash, trace.len);
    for (trace) |record| {
        const root = traceRecordSha256V1(record);
        hash.update(&root);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn summarySha256V1(summary: SummaryV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(summary_domain);
    hashU64(&hash, summary_abi);
    inline for (std.meta.fields(SummaryV1)) |field| {
        if (field.type == resource_bank.Claim) {
            hashClaim(&hash, @field(summary, field.name));
        } else if (field.type == bool) {
            hashU64(&hash, @intFromBool(@field(summary, field.name)));
        } else {
            hashU64(&hash, @field(summary, field.name));
        }
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn resultSha256V1(
    plan_sha256: Digest,
    outcome_sha256: Digest,
    trace_sha256: Digest,
    summary_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(result_domain);
    hashU64(&hash, result_abi);
    hash.update(&plan_sha256);
    hash.update(&outcome_sha256);
    hash.update(&trace_sha256);
    hash.update(&summary_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn requiredPlanBytesV1(candidate_count: usize) Error!usize {
    if (candidate_count == 0 or candidate_count > maximum_candidates)
        return Error.CandidateLimitExceeded;
    const records = checkedMulUsize(
        candidate_count,
        candidate_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    const body = checkedAddUsize(
        plan_header_bytes,
        records,
    ) catch return Error.ArithmeticOverflow;
    return checkedAddUsize(
        body,
        plan_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn requiredResultBytesV1(
    outcome_count: usize,
    trace_count: usize,
) Error!usize {
    if (outcome_count == 0 or outcome_count > maximum_candidates)
        return Error.CandidateLimitExceeded;
    if (trace_count == 0 or trace_count > maximum_trace_records)
        return Error.TraceLimitExceeded;
    const outcomes_bytes = checkedMulUsize(
        outcome_count,
        outcome_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    const traces_bytes = checkedMulUsize(
        trace_count,
        trace_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    var total = checkedAddUsize(
        result_header_bytes,
        outcomes_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = checkedAddUsize(
        total,
        traces_bytes,
    ) catch return Error.ArithmeticOverflow;
    total = checkedAddUsize(
        total,
        summary_record_bytes,
    ) catch return Error.ArithmeticOverflow;
    return checkedAddUsize(
        total,
        result_footer_bytes,
    ) catch return Error.ArithmeticOverflow;
}

pub fn encodePlanV1(
    plan: PlanV1,
    destination: []u8,
) Error![]const u8 {
    try validatePlanV1(plan);
    const needed = try requiredPlanBytesV1(plan.candidates.len);
    if (destination.len < needed) return Error.BufferTooSmall;
    const output = destination[0..needed];
    @memset(output, 0);
    @memcpy(output[0..8], &plan_magic);
    writeU64(output, 8, plan_abi);
    writeU64(output, 16, needed);
    writeU64(output, 24, plan_header_bytes);
    writeU64(output, 32, candidate_record_bytes);
    writeU64(output, 40, plan_footer_bytes);
    writeU64(output, 48, allowed_flags);
    writeU64(output, 56, plan.candidates.len);
    writeU64(output, 64, plan.seed);
    writeU64(output, 72, plan.in_flight_target);
    writeU64(output, 80, plan.capacity);
    writeU64(output, 88, plan.max_driver_steps);
    writeU64(output, 96, plan.max_service_quanta);
    writeU64(output, 104, plan.fairness_start_tick);
    writeU64(output, 112, plan.fairness_end_tick);
    writeU64(output, 120, plan.bank_epoch);
    writeU64(output, 128, plan.scheduler_epoch);
    writeU64(output, 136, plan.max_weight);
    writeU64(output, 144, plan.max_projection_quanta);
    writeU64(output, 152, plan.max_projection_operations);
    writeLimits(output, 160, plan.limits);
    @memcpy(output[248..280], &plan.challenge);
    const semantic_root = planSha256V1(plan);
    @memcpy(output[280..312], &semantic_root);

    for (plan.candidates, 0..) |candidate, index| {
        const offset = plan_header_bytes +
            index * candidate_record_bytes;
        writeCandidateRecordV1(
            output[offset..][0..candidate_record_bytes],
            candidate,
        );
    }
    const footer = wireSha256(
        plan_wire_domain,
        output[0 .. needed - plan_footer_bytes],
    );
    @memcpy(output[needed - plan_footer_bytes ..], &footer);
    return output;
}

pub fn decodePlanV1(
    encoded: []const u8,
    candidate_storage: []CandidateV1,
) Error!PlanV1 {
    if (encoded.len < plan_header_bytes + plan_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &plan_magic) or
        readU64(encoded, 8) != plan_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != plan_header_bytes or
        readU64(encoded, 32) != candidate_record_bytes or
        readU64(encoded, 40) != plan_footer_bytes or
        readU64(encoded, 48) != allowed_flags or
        readU64(encoded, 312) != 0)
        return Error.InvalidEvidence;
    const candidate_count = std.math.cast(
        usize,
        readU64(encoded, 56),
    ) orelse return Error.InvalidEvidence;
    const expected = requiredPlanBytesV1(candidate_count) catch
        return Error.InvalidEvidence;
    if (encoded.len != expected) return Error.InvalidEvidence;
    if (candidate_storage.len < candidate_count)
        return Error.BufferTooSmall;

    var footer: Digest = undefined;
    @memcpy(&footer, encoded[encoded.len - plan_footer_bytes ..]);
    const expected_footer = wireSha256(
        plan_wire_domain,
        encoded[0 .. encoded.len - plan_footer_bytes],
    );
    if (!std.mem.eql(u8, &footer, &expected_footer))
        return Error.InvalidEvidence;

    var temporary: [maximum_candidates]CandidateV1 = undefined;
    for (0..candidate_count) |index| {
        const offset = plan_header_bytes +
            index * candidate_record_bytes;
        temporary[index] = decodeCandidateRecordV1(
            encoded[offset..][0..candidate_record_bytes],
        ) catch return Error.InvalidEvidence;
    }
    const target = std.math.cast(u32, readU64(encoded, 72)) orelse
        return Error.InvalidEvidence;
    const capacity = std.math.cast(u32, readU64(encoded, 80)) orelse
        return Error.InvalidEvidence;
    const max_weight = std.math.cast(u16, readU64(encoded, 136)) orelse
        return Error.InvalidEvidence;
    var challenge: Digest = undefined;
    var retained_root: Digest = undefined;
    @memcpy(&challenge, encoded[248..280]);
    @memcpy(&retained_root, encoded[280..312]);
    const temporary_plan: PlanV1 = .{
        .seed = readU64(encoded, 64),
        .in_flight_target = target,
        .capacity = capacity,
        .max_driver_steps = readU64(encoded, 88),
        .max_service_quanta = readU64(encoded, 96),
        .fairness_start_tick = readU64(encoded, 104),
        .fairness_end_tick = readU64(encoded, 112),
        .bank_epoch = readU64(encoded, 120),
        .scheduler_epoch = readU64(encoded, 128),
        .max_weight = max_weight,
        .max_projection_quanta = readU64(encoded, 144),
        .max_projection_operations = readU64(encoded, 152),
        .limits = readLimits(encoded, 160),
        .challenge = challenge,
        .candidates = temporary[0..candidate_count],
    };
    validatePlanV1(temporary_plan) catch return Error.InvalidEvidence;
    if (!std.mem.eql(
        u8,
        &retained_root,
        &planSha256V1(temporary_plan),
    )) return Error.InvalidEvidence;

    @memcpy(
        candidate_storage[0..candidate_count],
        temporary[0..candidate_count],
    );
    return .{
        .seed = temporary_plan.seed,
        .in_flight_target = temporary_plan.in_flight_target,
        .capacity = temporary_plan.capacity,
        .max_driver_steps = temporary_plan.max_driver_steps,
        .max_service_quanta = temporary_plan.max_service_quanta,
        .fairness_start_tick = temporary_plan.fairness_start_tick,
        .fairness_end_tick = temporary_plan.fairness_end_tick,
        .bank_epoch = temporary_plan.bank_epoch,
        .scheduler_epoch = temporary_plan.scheduler_epoch,
        .max_weight = temporary_plan.max_weight,
        .max_projection_quanta = temporary_plan.max_projection_quanta,
        .max_projection_operations = temporary_plan.max_projection_operations,
        .limits = temporary_plan.limits,
        .challenge = temporary_plan.challenge,
        .candidates = candidate_storage[0..candidate_count],
    };
}

pub fn encodeResultV1(
    plan: PlanV1,
    result: ResultV1,
    destination: []u8,
) Error![]const u8 {
    var replay_storage: MaximumStorageV1 = .{};
    try validateResultByReplayV1(
        plan,
        result,
        replay_storage.interface(),
    );
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
    writeU64(output, 24, result_header_bytes);
    writeU64(output, 32, outcome_record_bytes);
    writeU64(output, 40, trace_record_bytes);
    writeU64(output, 48, summary_record_bytes);
    writeU64(output, 56, result_footer_bytes);
    writeU64(output, 64, allowed_flags);
    writeU64(output, 72, result.outcomes.len);
    writeU64(output, 80, result.trace.len);
    @memcpy(output[96..128], &result.plan_sha256);
    @memcpy(output[128..160], &result.outcome_sha256);
    @memcpy(output[160..192], &result.trace_sha256);
    @memcpy(output[192..224], &result.summary_sha256);
    @memcpy(output[224..256], &result.result_sha256);

    var offset = result_header_bytes;
    for (result.outcomes) |outcome| {
        writeOutcomeRecordV1(
            output[offset..][0..outcome_record_bytes],
            outcome,
        );
        offset += outcome_record_bytes;
    }
    for (result.trace) |record| {
        writeTraceRecordV1(
            output[offset..][0..trace_record_bytes],
            record,
        );
        offset += trace_record_bytes;
    }
    writeSummaryRecordV1(
        output[offset..][0..summary_record_bytes],
        result.summary,
    );
    offset += summary_record_bytes;
    const footer = wireSha256(
        result_wire_domain,
        output[0..offset],
    );
    @memcpy(output[offset .. offset + result_footer_bytes], &footer);
    return output;
}

pub fn decodeResultV1(
    plan: PlanV1,
    encoded: []const u8,
    outcome_storage: []OutcomeV1,
    trace_storage: []TraceRecordV1,
) Error!ResultV1 {
    if (encoded.len <
        result_header_bytes + summary_record_bytes + result_footer_bytes or
        !std.mem.eql(u8, encoded[0..8], &result_magic) or
        readU64(encoded, 8) != result_abi or
        readU64(encoded, 16) != encoded.len or
        readU64(encoded, 24) != result_header_bytes or
        readU64(encoded, 32) != outcome_record_bytes or
        readU64(encoded, 40) != trace_record_bytes or
        readU64(encoded, 48) != summary_record_bytes or
        readU64(encoded, 56) != result_footer_bytes or
        readU64(encoded, 64) != allowed_flags or
        readU64(encoded, 88) != 0)
        return Error.InvalidEvidence;
    const outcome_count = std.math.cast(
        usize,
        readU64(encoded, 72),
    ) orelse return Error.InvalidEvidence;
    const trace_count = std.math.cast(
        usize,
        readU64(encoded, 80),
    ) orelse return Error.InvalidEvidence;
    const expected = requiredResultBytesV1(
        outcome_count,
        trace_count,
    ) catch return Error.InvalidEvidence;
    if (encoded.len != expected) return Error.InvalidEvidence;
    if (outcome_storage.len < outcome_count or
        trace_storage.len < trace_count)
        return Error.BufferTooSmall;

    var footer: Digest = undefined;
    @memcpy(&footer, encoded[encoded.len - result_footer_bytes ..]);
    const expected_footer = wireSha256(
        result_wire_domain,
        encoded[0 .. encoded.len - result_footer_bytes],
    );
    if (!std.mem.eql(u8, &footer, &expected_footer))
        return Error.InvalidEvidence;

    var temporary_outcomes: [maximum_candidates]OutcomeV1 = undefined;
    var temporary_trace: [maximum_trace_records]TraceRecordV1 = undefined;
    var offset = result_header_bytes;
    for (0..outcome_count) |index| {
        temporary_outcomes[index] = decodeOutcomeRecordV1(
            encoded[offset..][0..outcome_record_bytes],
        ) catch return Error.InvalidEvidence;
        offset += outcome_record_bytes;
    }
    for (0..trace_count) |index| {
        temporary_trace[index] = decodeTraceRecordV1(
            encoded[offset..][0..trace_record_bytes],
        ) catch return Error.InvalidEvidence;
        offset += trace_record_bytes;
    }
    const summary_record =
        encoded[offset..][0..summary_record_bytes];
    const summary = decodeSummaryRecordV1(summary_record) catch
        return Error.InvalidEvidence;
    var retained_summary_root: Digest = undefined;
    @memcpy(&retained_summary_root, summary_record[392..424]);

    var plan_root: Digest = undefined;
    var outcome_root: Digest = undefined;
    var trace_root: Digest = undefined;
    var summary_root: Digest = undefined;
    var result_root: Digest = undefined;
    @memcpy(&plan_root, encoded[96..128]);
    @memcpy(&outcome_root, encoded[128..160]);
    @memcpy(&trace_root, encoded[160..192]);
    @memcpy(&summary_root, encoded[192..224]);
    @memcpy(&result_root, encoded[224..256]);
    if (!std.mem.eql(
        u8,
        &summary_root,
        &retained_summary_root,
    )) return Error.InvalidEvidence;

    const temporary_result: ResultV1 = .{
        .plan_sha256 = plan_root,
        .outcome_sha256 = outcome_root,
        .trace_sha256 = trace_root,
        .summary_sha256 = summary_root,
        .result_sha256 = result_root,
        .outcomes = temporary_outcomes[0..outcome_count],
        .trace = temporary_trace[0..trace_count],
        .summary = summary,
    };
    var replay_storage: MaximumStorageV1 = .{};
    validateResultByReplayV1(
        plan,
        temporary_result,
        replay_storage.interface(),
    ) catch return Error.InvalidEvidence;

    @memcpy(
        outcome_storage[0..outcome_count],
        temporary_outcomes[0..outcome_count],
    );
    @memcpy(
        trace_storage[0..trace_count],
        temporary_trace[0..trace_count],
    );
    return .{
        .plan_sha256 = temporary_result.plan_sha256,
        .outcome_sha256 = temporary_result.outcome_sha256,
        .trace_sha256 = temporary_result.trace_sha256,
        .summary_sha256 = temporary_result.summary_sha256,
        .result_sha256 = temporary_result.result_sha256,
        .outcomes = outcome_storage[0..outcome_count],
        .trace = trace_storage[0..trace_count],
        .summary = temporary_result.summary,
    };
}

fn writeCandidateRecordV1(
    output: []u8,
    candidate: CandidateV1,
) void {
    writeU64(output, 0, candidate.ordinal);
    writeU64(output, 8, @intFromEnum(candidate.family));
    writeU64(output, 16, @intFromEnum(candidate.operation));
    writeU64(output, 24, @intFromEnum(candidate.media_kind));
    @memcpy(output[32..64], &candidate.profile_sha256);
    writeU64(output, 64, candidate.weight);
    writeU64(output, 72, candidate.work_quanta);
    writeU64(output, 80, candidate.deadline_budget_quanta);
    writeU64(output, 88, candidate.terminal_action_after_steps);
    writeU64(output, 96, @intFromEnum(candidate.terminal_action));
    writeU64(output, 104, @intFromBool(candidate.fairness_member));
    writeU64(output, 112, candidate.tenant_key);
    writeU64(output, 120, candidate.request_key);
    writeU64(output, 128, candidate.request_generation);
    writeU64(output, 136, candidate.resource_owner_key);
    writeClaim(output, 144, candidate.claim);
    const root = candidateSha256V1(candidate);
    @memcpy(output[224..256], &root);
}

fn decodeCandidateRecordV1(input: []const u8) Error!CandidateV1 {
    const family = std.meta.intToEnum(
        model.ModelFamilyIdV1,
        readU64(input, 8),
    ) catch return Error.InvalidEvidence;
    const operation = std.meta.intToEnum(
        model.OperationIdV1,
        readU64(input, 16),
    ) catch return Error.InvalidEvidence;
    const media_kind = std.meta.intToEnum(
        media.MediaKindV1,
        readU64(input, 24),
    ) catch return Error.InvalidEvidence;
    const action = std.meta.intToEnum(
        workload.TerminalActionV1,
        readU64(input, 96),
    ) catch return Error.InvalidEvidence;
    const weight = std.math.cast(u16, readU64(input, 64)) orelse
        return Error.InvalidEvidence;
    const fairness = readU64(input, 104);
    if (fairness > 1) return Error.InvalidEvidence;
    var profile_root: Digest = undefined;
    var retained_root: Digest = undefined;
    @memcpy(&profile_root, input[32..64]);
    @memcpy(&retained_root, input[224..256]);
    const candidate: CandidateV1 = .{
        .ordinal = readU64(input, 0),
        .family = family,
        .operation = operation,
        .media_kind = media_kind,
        .profile_sha256 = profile_root,
        .weight = weight,
        .work_quanta = readU64(input, 72),
        .deadline_budget_quanta = readU64(input, 80),
        .terminal_action_after_steps = readU64(input, 88),
        .terminal_action = action,
        .fairness_member = fairness == 1,
        .tenant_key = readU64(input, 112),
        .request_key = readU64(input, 120),
        .request_generation = readU64(input, 128),
        .resource_owner_key = readU64(input, 136),
        .claim = readClaim(input, 144),
    };
    if (!std.mem.eql(
        u8,
        &retained_root,
        &candidateSha256V1(candidate),
    )) return Error.InvalidEvidence;
    return candidate;
}

fn writeOutcomeRecordV1(
    output: []u8,
    outcome: OutcomeV1,
) void {
    writeU64(output, 0, outcome.ordinal);
    @memcpy(output[8..40], &outcome.candidate_sha256);
    writeU64(output, 40, outcome.lineage_index);
    writeU64(output, 48, outcome.lineage_generation);
    writeU64(output, 56, outcome.predecessor_ordinal);
    writeU64(output, 64, @intFromEnum(outcome.trigger_kind));
    writeU64(output, 72, outcome.trigger_terminal_step);
    @memcpy(output[80..112], &outcome.trigger_trace_sha256);
    @memcpy(output[112..144], &outcome.trigger_credit_sha256);
    writeU64(output, 144, outcome.submission_step);
    writeU64(output, 152, outcome.scheduler_slot_index);
    writeU64(output, 160, outcome.scheduler_slot_generation);
    writeU64(output, 168, @intFromEnum(outcome.kind));
    writeU64(output, 176, @intFromEnum(outcome.rejection_reason));
    writeU64(output, 184, @intFromEnum(outcome.terminal_action));
    writeU64(output, 192, outcome.admitted_step);
    writeU64(output, 200, outcome.first_service_step);
    writeU64(output, 208, outcome.terminal_step);
    writeU64(output, 216, outcome.served_quanta);
    writeU64(output, 224, outcome.maximum_wait_quanta);
    @memcpy(output[232..264], &outcome.admission_trace_sha256);
    @memcpy(output[264..296], &outcome.terminal_trace_sha256);
    @memcpy(output[296..328], &outcome.record_sha256);
}

fn decodeOutcomeRecordV1(input: []const u8) Error!OutcomeV1 {
    const trigger = std.meta.intToEnum(
        TriggerKindV1,
        readU64(input, 64),
    ) catch return Error.InvalidEvidence;
    const kind = std.meta.intToEnum(
        workload.OutcomeKindV1,
        readU64(input, 168),
    ) catch return Error.InvalidEvidence;
    const rejection = std.meta.intToEnum(
        qos.RejectionReason,
        std.math.cast(u8, readU64(input, 176)) orelse
            return Error.InvalidEvidence,
    ) catch return Error.InvalidEvidence;
    const action = std.meta.intToEnum(
        workload.TerminalActionV1,
        readU64(input, 184),
    ) catch return Error.InvalidEvidence;
    var candidate_root: Digest = undefined;
    var trigger_trace_root: Digest = undefined;
    var trigger_credit_root: Digest = undefined;
    var admission_root: Digest = undefined;
    var terminal_root: Digest = undefined;
    var record_root: Digest = undefined;
    @memcpy(&candidate_root, input[8..40]);
    @memcpy(&trigger_trace_root, input[80..112]);
    @memcpy(&trigger_credit_root, input[112..144]);
    @memcpy(&admission_root, input[232..264]);
    @memcpy(&terminal_root, input[264..296]);
    @memcpy(&record_root, input[296..328]);
    const outcome: OutcomeV1 = .{
        .ordinal = readU64(input, 0),
        .candidate_sha256 = candidate_root,
        .lineage_index = readU64(input, 40),
        .lineage_generation = readU64(input, 48),
        .predecessor_ordinal = readU64(input, 56),
        .trigger_kind = trigger,
        .trigger_terminal_step = readU64(input, 72),
        .trigger_trace_sha256 = trigger_trace_root,
        .trigger_credit_sha256 = trigger_credit_root,
        .submission_step = readU64(input, 144),
        .scheduler_slot_index = readU64(input, 152),
        .scheduler_slot_generation = readU64(input, 160),
        .kind = kind,
        .rejection_reason = rejection,
        .terminal_action = action,
        .admitted_step = readU64(input, 192),
        .first_service_step = readU64(input, 200),
        .terminal_step = readU64(input, 208),
        .served_quanta = readU64(input, 216),
        .maximum_wait_quanta = readU64(input, 224),
        .admission_trace_sha256 = admission_root,
        .terminal_trace_sha256 = terminal_root,
        .record_sha256 = record_root,
    };
    if (!std.mem.eql(
        u8,
        &record_root,
        &outcomeRecordSha256V1(outcome),
    )) return Error.InvalidEvidence;
    return outcome;
}

fn writeTraceRecordV1(
    output: []u8,
    record: TraceRecordV1,
) void {
    writeU64(output, 0, record.sequence);
    writeU64(output, 8, record.driver_step);
    writeU64(output, 16, @intFromEnum(record.phase));
    writeU64(output, 24, @intFromEnum(record.event_kind));
    writeU64(output, 32, record.candidate_ordinal);
    writeU64(output, 40, record.predecessor_ordinal);
    writeU64(output, 48, record.lineage_index);
    writeU64(output, 56, record.lineage_generation);
    writeU64(output, 64, record.scheduler_event_sequence);
    writeU64(output, 72, @intFromEnum(record.rejection_reason));
    writeU64(output, 80, @intFromEnum(record.terminal_action));
    writeU64(output, 88, record.logical_tick_before);
    writeU64(output, 96, record.logical_tick_after);
    writeU64(output, 104, record.remaining_before);
    writeU64(output, 112, record.remaining_after);
    writeU64(output, 120, record.wait_quanta);
    writeU64(output, 128, record.active_before);
    writeU64(output, 136, record.active_after);
    writeU64(output, 144, record.due_before);
    writeU64(output, 152, record.due_after);
    writeU64(output, 160, record.candidate_cursor_after);
    @memcpy(output[168..200], &record.record_sha256);
}

fn decodeTraceRecordV1(input: []const u8) Error!TraceRecordV1 {
    const phase = std.meta.intToEnum(
        PhaseV1,
        readU64(input, 16),
    ) catch return Error.InvalidEvidence;
    const event_kind = std.meta.intToEnum(
        EventKindV1,
        readU64(input, 24),
    ) catch return Error.InvalidEvidence;
    const rejection = std.meta.intToEnum(
        qos.RejectionReason,
        std.math.cast(u8, readU64(input, 72)) orelse
            return Error.InvalidEvidence,
    ) catch return Error.InvalidEvidence;
    const action = std.meta.intToEnum(
        workload.TerminalActionV1,
        readU64(input, 80),
    ) catch return Error.InvalidEvidence;
    var record_root: Digest = undefined;
    @memcpy(&record_root, input[168..200]);
    const record: TraceRecordV1 = .{
        .sequence = readU64(input, 0),
        .driver_step = readU64(input, 8),
        .phase = phase,
        .event_kind = event_kind,
        .candidate_ordinal = readU64(input, 32),
        .predecessor_ordinal = readU64(input, 40),
        .lineage_index = readU64(input, 48),
        .lineage_generation = readU64(input, 56),
        .scheduler_event_sequence = readU64(input, 64),
        .rejection_reason = rejection,
        .terminal_action = action,
        .logical_tick_before = readU64(input, 88),
        .logical_tick_after = readU64(input, 96),
        .remaining_before = readU64(input, 104),
        .remaining_after = readU64(input, 112),
        .wait_quanta = readU64(input, 120),
        .active_before = readU64(input, 128),
        .active_after = readU64(input, 136),
        .due_before = readU64(input, 144),
        .due_after = readU64(input, 152),
        .candidate_cursor_after = readU64(input, 160),
        .record_sha256 = record_root,
    };
    if (!std.mem.eql(
        u8,
        &record_root,
        &traceRecordSha256V1(record),
    )) return Error.InvalidEvidence;
    return record;
}

fn writeSummaryRecordV1(
    output: []u8,
    summary: SummaryV1,
) void {
    const prefix = [_]u64{
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
    };
    for (prefix, 0..) |value, index|
        writeU64(output, index * 8, value);
    writeClaim(output, 200, summary.peak);
    const suffix = [_]u64{
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
        @intFromBool(summary.zero_orphan_ownership),
    };
    for (suffix, 0..) |value, index|
        writeU64(output, 280 + index * 8, value);
    const root = summarySha256V1(summary);
    @memcpy(output[392..424], &root);
}

fn decodeSummaryRecordV1(input: []const u8) Error!SummaryV1 {
    const zero_orphan = readU64(input, 384);
    if (zero_orphan > 1) return Error.InvalidEvidence;
    const summary: SummaryV1 = .{
        .in_flight_target = readU64(input, 0),
        .capacity = readU64(input, 8),
        .candidate_budget = readU64(input, 16),
        .attempted = readU64(input, 24),
        .admitted = readU64(input, 32),
        .rejected = readU64(input, 40),
        .completed = readU64(input, 48),
        .cancelled = readU64(input, 56),
        .timed_out = readU64(input, 64),
        .service_quanta = readU64(input, 72),
        .driver_steps = readU64(input, 80),
        .final_logical_tick = readU64(input, 88),
        .maximum_active = readU64(input, 96),
        .maximum_due_credits = readU64(input, 104),
        .maximum_live_receipts = readU64(input, 112),
        .replacement_attempts = readU64(input, 120),
        .replacements_after_completed = readU64(input, 128),
        .replacements_after_rejected = readU64(input, 136),
        .replacements_after_cancelled = readU64(input, 144),
        .replacements_after_timed_out = readU64(input, 152),
        .credits_sealed = readU64(input, 160),
        .credits_exhausted = readU64(input, 168),
        .lineage_count = readU64(input, 176),
        .maximum_lineage_generation = readU64(input, 184),
        .peak_host_bytes = readU64(input, 192),
        .peak = readClaim(input, 200),
        .maximum_wait_quanta = readU64(input, 280),
        .maximum_service_gap = readU64(input, 288),
        .fairness_cross_product_error = readU64(input, 296),
        .final_active = readU64(input, 304),
        .final_due_credits = readU64(input, 312),
        .final_finished = readU64(input, 320),
        .final_active_reservations = readU64(input, 328),
        .final_committed_receipts = readU64(input, 336),
        .successful_commits = readU64(input, 344),
        .releases = readU64(input, 352),
        .bank_cancellations = readU64(input, 360),
        .bank_rejected_capacity = readU64(input, 368),
        .bank_rejected_slots = readU64(input, 376),
        .zero_orphan_ownership = zero_orphan == 1,
    };
    var retained_root: Digest = undefined;
    @memcpy(&retained_root, input[392..424]);
    if (!std.mem.eql(
        u8,
        &retained_root,
        &summarySha256V1(summary),
    )) return Error.InvalidEvidence;
    return summary;
}

fn wireSha256(
    domain: []const u8,
    body: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(body);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn writeClaim(
    output: []u8,
    offset: usize,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        writeU64(output, offset + index * 8, @field(claim, field.name));
}

fn readClaim(
    input: []const u8,
    offset: usize,
) resource_bank.Claim {
    var claim: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim), 0..) |field, index|
        @field(claim, field.name) =
            readU64(input, offset + index * 8);
    return claim;
}

fn writeLimits(
    output: []u8,
    offset: usize,
    limits: resource_bank.Limits,
) void {
    inline for (std.meta.fields(resource_bank.Limits), 0..) |field, index|
        writeU64(output, offset + index * 8, @field(limits, field.name));
}

fn readLimits(
    input: []const u8,
    offset: usize,
) resource_bank.Limits {
    var limits: resource_bank.Limits = .{};
    inline for (std.meta.fields(resource_bank.Limits), 0..) |field, index|
        @field(limits, field.name) =
            readU64(input, offset + index * 8);
    return limits;
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

fn digestFromHex(hex: *const [64]u8) !Digest {
    var digest: Digest = undefined;
    _ = try std.fmt.hexToBytes(&digest, hex);
    return digest;
}

fn checkedAddUsize(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right);
}

fn checkedMulUsize(left: usize, right: usize) !usize {
    return std.math.mul(usize, left, right);
}

fn triggerFromOutcome(
    outcome: workload.OutcomeKindV1,
) TriggerKindV1 {
    return switch (outcome) {
        .completed => .completed,
        .rejected => .rejected,
        .cancelled => .cancelled,
        .timed_out => .timed_out,
    };
}

fn checkedAdd(left: u64, right: anytype) Error!u64 {
    return std.math.add(u64, left, @intCast(right)) catch
        return Error.ArithmeticOverflow;
}

fn hashClaim(hash: anytype, claim: resource_bank.Claim) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashLimits(hash: anytype, limits: resource_bank.Limits) void {
    inline for (std.meta.fields(resource_bank.Limits)) |field|
        hashU64(hash, @field(limits, field.name));
}

fn hashU64(hash: anytype, value: anytype) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

test "reference W3 is FIFO next-step bounded and closes ownership" {
    var candidates = makeReferenceCandidatesV1();
    const plan = referencePlanV1(&candidates);
    var storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, storage.interface(), &result);
    try std.testing.expectEqual(
        @as(u64, candidates.len),
        result.summary.attempted,
    );
    try std.testing.expectEqual(
        @as(u64, plan.in_flight_target),
        result.summary.maximum_active,
    );
    try std.testing.expect(
        result.summary.rejected >= 1,
    );
    try std.testing.expect(
        result.summary.cancelled >= 2,
    );
    try std.testing.expect(
        result.summary.completed >= 1,
    );
    try std.testing.expectEqual(
        qos.RejectionReason.resource_limit,
        result.outcomes[8].rejection_reason,
    );
    try std.testing.expectEqual(
        qos.RejectionReason.projection_limit,
        result.outcomes[9].rejection_reason,
    );
    try std.testing.expectEqual(
        qos.RejectionReason.deadline_infeasible,
        result.outcomes[3].rejection_reason,
    );
    try std.testing.expect(
        result.summary.credits_exhausted >= 1,
    );
    try std.testing.expect(result.summary.zero_orphan_ownership);
    try std.testing.expectEqual(
        result.summary.successful_commits,
        result.summary.releases,
    );
    for (result.outcomes[plan.in_flight_target..]) |outcome| {
        try std.testing.expectEqual(
            outcome.trigger_terminal_step + 1,
            outcome.submission_step,
        );
        try std.testing.expect(outcome.trigger_kind != .initial);
    }
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "3641114db6e5a286888b6c17c5fe5dfda80e5b2218eeb98624c5762c9e58dfe0",
        ),
        result.plan_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "4a2380bd7350afcd167a92cbf746487d26c884cd72cfd1b64e0587e8d49ba6f1",
        ),
        result.outcome_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "ad0ea0a930993f6c219c622db2129cb0cb2932e14ecc2cc7d0ff032ba6bb3bda",
        ),
        result.trace_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "d670d8ae7ca6a6e6673cfdd39f6f883d7b95f64885f8fce9438e4d498c531d3c",
        ),
        result.summary_sha256,
    );
    try std.testing.expectEqualDeep(
        try digestFromHex(
            "1086ce5e2ac75090acb0e40efd92792bb51238192923ecb1a9a71f3b4f250f41",
        ),
        result.result_sha256,
    );
    try std.testing.expectEqual(@as(usize, 37), result.trace.len);
    try std.testing.expectEqual(@as(u64, 7), result.summary.admitted);
    try std.testing.expectEqual(@as(u64, 3), result.summary.rejected);
    try std.testing.expectEqual(@as(u64, 4), result.summary.completed);
    try std.testing.expectEqual(@as(u64, 2), result.summary.cancelled);
    try std.testing.expectEqual(@as(u64, 1), result.summary.timed_out);
    try std.testing.expectEqual(@as(u64, 7), result.summary.replacement_attempts);
    try std.testing.expectEqual(
        @as(u64, 2),
        result.summary.replacements_after_completed,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        result.summary.replacements_after_rejected,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        result.summary.replacements_after_cancelled,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        result.summary.replacements_after_timed_out,
    );
    try std.testing.expectEqual(@as(u64, 6), result.summary.service_quanta);
    try std.testing.expectEqual(@as(u64, 7), result.summary.driver_steps);
    try std.testing.expectEqual(@as(u64, 10), result.summary.credits_sealed);
    try std.testing.expectEqual(@as(u64, 3), result.summary.credits_exhausted);

    const expected_predecessors = [_]u64{
        absent,
        absent,
        absent,
        0,
        1,
        2,
        3,
        4,
        5,
        8,
    };
    for (result.outcomes, expected_predecessors) |outcome, predecessor|
        try std.testing.expectEqual(predecessor, outcome.predecessor_ordinal);

    var replacement_admissions: u64 = 0;
    var sealed_credits: u64 = 0;
    var exhausted_credits: u64 = 0;
    for (result.trace) |record| {
        switch (record.event_kind) {
            .admission_accepted, .admission_rejected => {
                if (record.driver_step != 0) {
                    replacement_admissions += 1;
                    try std.testing.expectEqual(
                        record.due_before,
                        record.due_after + 1,
                    );
                }
            },
            .credit_sealed => sealed_credits += 1,
            .credit_exhausted => {
                exhausted_credits += 1;
                try std.testing.expectEqual(
                    record.due_before,
                    record.due_after + 1,
                );
            },
            else => {},
        }
    }
    try std.testing.expectEqual(
        result.summary.replacement_attempts,
        replacement_admissions,
    );
    try std.testing.expectEqual(result.summary.credits_sealed, sealed_credits);
    try std.testing.expectEqual(
        result.summary.credits_exhausted,
        exhausted_credits,
    );
}

test "target one turns over without exceeding the logical target" {
    var candidates = makeReferenceCandidatesV1();
    for (&candidates) |*candidate| {
        candidate.work_quanta = 1;
        candidate.deadline_budget_quanta = 0;
        candidate.terminal_action = .none;
        candidate.terminal_action_after_steps = absent;
    }
    var plan = referencePlanV1(&candidates);
    plan.in_flight_target = 1;
    plan.capacity = 4;
    plan.limits.host_bytes = std.math.maxInt(u64);
    var storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, storage.interface(), &result);
    try std.testing.expectEqual(@as(u64, 1), result.summary.maximum_active);
    try std.testing.expectEqual(
        @as(u64, candidates.len),
        result.summary.completed,
    );
    try std.testing.expectEqual(
        @as(u64, candidates.len),
        result.summary.maximum_lineage_generation,
    );
    try std.testing.expect(result.summary.zero_orphan_ownership);
}

test "replay rejects a resealed lineage contradiction" {
    var candidates = makeReferenceCandidatesV1();
    const plan = referencePlanV1(&candidates);
    var storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, storage.interface(), &result);

    var outcomes = storage.outcomes;
    outcomes[3].predecessor_ordinal = 1;
    outcomes[3].record_sha256 = outcomeRecordSha256V1(outcomes[3]);
    var forged = result;
    forged.outcomes = outcomes[0..result.outcomes.len];
    forged.outcome_sha256 = outcomeSha256V1(forged.outcomes);
    forged.result_sha256 = resultSha256V1(
        forged.plan_sha256,
        forged.outcome_sha256,
        forged.trace_sha256,
        forged.summary_sha256,
    );
    var replay_storage: MaximumStorageV1 = .{};
    try std.testing.expectError(
        Error.InvalidEvidence,
        validateResultByReplayV1(
            plan,
            forged,
            replay_storage.interface(),
        ),
    );
}

test "failure leaves the caller result untouched" {
    var candidates = makeReferenceCandidatesV1();
    var plan = referencePlanV1(&candidates);
    var storage: MaximumStorageV1 = .{};
    var sentinel: ResultV1 = undefined;
    try runPlanV1(plan, storage.interface(), &sentinel);
    const root_before = sentinel.result_sha256;
    plan.max_driver_steps = 2;
    try std.testing.expectError(
        Error.DriverStepLimitExceeded,
        runPlanV1(plan, storage.interface(), &sentinel),
    );
    try std.testing.expectEqualDeep(root_before, sentinel.result_sha256);
}

test "canonical W3 plan and result wires round trip exactly" {
    var candidates = makeReferenceCandidatesV1();
    const plan = referencePlanV1(&candidates);
    var plan_bytes: [maximum_plan_bytes]u8 = undefined;
    const encoded_plan = try encodePlanV1(plan, &plan_bytes);
    try std.testing.expectEqual(
        plan_header_bytes +
            candidates.len * candidate_record_bytes +
            plan_footer_bytes,
        encoded_plan.len,
    );
    try std.testing.expectEqual(@as(usize, 2912), encoded_plan.len);
    var decoded_candidates: [maximum_candidates]CandidateV1 = undefined;
    const decoded_plan = try decodePlanV1(
        encoded_plan,
        &decoded_candidates,
    );
    try std.testing.expectEqualDeep(
        planSha256V1(plan),
        planSha256V1(decoded_plan),
    );
    for (plan.candidates, decoded_plan.candidates) |expected, actual|
        try std.testing.expect(std.meta.eql(expected, actual));

    var run_storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, run_storage.interface(), &result);
    var result_bytes: [maximum_result_bytes]u8 = undefined;
    const encoded_result = try encodeResultV1(
        plan,
        result,
        &result_bytes,
    );
    try std.testing.expectEqual(
        try requiredResultBytesV1(
            result.outcomes.len,
            result.trace.len,
        ),
        encoded_result.len,
    );
    try std.testing.expectEqual(@as(usize, 11392), encoded_result.len);
    var decoded_outcomes: [maximum_candidates]OutcomeV1 = undefined;
    var decoded_trace: [maximum_trace_records]TraceRecordV1 = undefined;
    const decoded_result = try decodeResultV1(
        plan,
        encoded_result,
        &decoded_outcomes,
        &decoded_trace,
    );
    try std.testing.expectEqualDeep(
        result.result_sha256,
        decoded_result.result_sha256,
    );
    try std.testing.expect(std.meta.eql(
        result.summary,
        decoded_result.summary,
    ));
    for (result.outcomes, decoded_result.outcomes) |expected, actual|
        try std.testing.expect(std.meta.eql(expected, actual));
    for (result.trace, decoded_result.trace) |expected, actual|
        try std.testing.expect(std.meta.eql(expected, actual));
    var replay_storage: MaximumStorageV1 = .{};
    try validateResultByReplayV1(
        decoded_plan,
        decoded_result,
        replay_storage.interface(),
    );
}

test "every W3 plan wire byte mutation and strict truncation rejects" {
    var candidates = makeReferenceCandidatesV1();
    const plan = referencePlanV1(&candidates);
    var encoded_storage: [maximum_plan_bytes]u8 = undefined;
    const encoded_const = try encodePlanV1(plan, &encoded_storage);
    const encoded_len = encoded_const.len;
    var decoded_candidates: [maximum_candidates]CandidateV1 = undefined;

    for (0..encoded_len) |index| {
        encoded_storage[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidEvidence,
            decodePlanV1(
                encoded_storage[0..encoded_len],
                &decoded_candidates,
            ),
        );
        encoded_storage[index] ^= 1;
    }
    for (0..encoded_len) |length| {
        try std.testing.expectError(
            Error.InvalidEvidence,
            decodePlanV1(
                encoded_storage[0..length],
                &decoded_candidates,
            ),
        );
    }
    encoded_storage[encoded_len] = 0;
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodePlanV1(
            encoded_storage[0 .. encoded_len + 1],
            &decoded_candidates,
        ),
    );
}

test "every W3 result wire byte mutation and strict truncation rejects" {
    var candidates = makeReferenceCandidatesV1();
    const plan = referencePlanV1(&candidates);
    var run_storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, run_storage.interface(), &result);
    var encoded_storage: [maximum_result_bytes]u8 = undefined;
    const encoded_const = try encodeResultV1(
        plan,
        result,
        &encoded_storage,
    );
    const encoded_len = encoded_const.len;
    var decoded_outcomes: [maximum_candidates]OutcomeV1 = undefined;
    var decoded_trace: [maximum_trace_records]TraceRecordV1 = undefined;

    for (0..encoded_len) |index| {
        encoded_storage[index] ^= 1;
        try std.testing.expectError(
            Error.InvalidEvidence,
            decodeResultV1(
                plan,
                encoded_storage[0..encoded_len],
                &decoded_outcomes,
                &decoded_trace,
            ),
        );
        encoded_storage[index] ^= 1;
    }
    for (0..encoded_len) |length| {
        try std.testing.expectError(
            Error.InvalidEvidence,
            decodeResultV1(
                plan,
                encoded_storage[0..length],
                &decoded_outcomes,
                &decoded_trace,
            ),
        );
    }
    encoded_storage[encoded_len] = 0;
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodeResultV1(
            plan,
            encoded_storage[0 .. encoded_len + 1],
            &decoded_outcomes,
            &decoded_trace,
        ),
    );
}

test "resealed W3 result wire lineage contradiction rejects by replay" {
    var candidates = makeReferenceCandidatesV1();
    const plan = referencePlanV1(&candidates);
    var run_storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, run_storage.interface(), &result);
    var encoded_storage: [maximum_result_bytes]u8 = undefined;
    const encoded_const = try encodeResultV1(
        plan,
        result,
        &encoded_storage,
    );
    const encoded_len = encoded_const.len;

    var forged_outcomes = run_storage.outcomes;
    forged_outcomes[3].predecessor_ordinal = 1;
    forged_outcomes[3].record_sha256 =
        outcomeRecordSha256V1(forged_outcomes[3]);
    const forged_outcome_root = outcomeSha256V1(
        forged_outcomes[0..result.outcomes.len],
    );
    const forged_result_root = resultSha256V1(
        result.plan_sha256,
        forged_outcome_root,
        result.trace_sha256,
        result.summary_sha256,
    );
    const outcome_offset = result_header_bytes +
        3 * outcome_record_bytes;
    writeOutcomeRecordV1(
        encoded_storage[outcome_offset..][0..outcome_record_bytes],
        forged_outcomes[3],
    );
    @memcpy(encoded_storage[128..160], &forged_outcome_root);
    @memcpy(encoded_storage[224..256], &forged_result_root);
    const footer = wireSha256(
        result_wire_domain,
        encoded_storage[0 .. encoded_len - result_footer_bytes],
    );
    @memcpy(
        encoded_storage[encoded_len - result_footer_bytes .. encoded_len],
        &footer,
    );

    var decoded_outcomes: [maximum_candidates]OutcomeV1 = undefined;
    var decoded_trace: [maximum_trace_records]TraceRecordV1 = undefined;
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodeResultV1(
            plan,
            encoded_storage[0..encoded_len],
            &decoded_outcomes,
            &decoded_trace,
        ),
    );
}

test "W3 wire failures preserve destination and decode storage" {
    var candidates = makeReferenceCandidatesV1();
    const plan = referencePlanV1(&candidates);
    var plan_destination: [maximum_plan_bytes]u8 =
        [_]u8{0xa5} ** maximum_plan_bytes;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodePlanV1(
            plan,
            plan_destination[0 .. plan_header_bytes - 1],
        ),
    );
    for (plan_destination[0 .. plan_header_bytes - 1]) |byte|
        try std.testing.expectEqual(@as(u8, 0xa5), byte);

    const encoded_plan = try encodePlanV1(plan, &plan_destination);
    var candidate_output = candidates;
    const candidate_before = candidate_output;
    plan_destination[encoded_plan.len - 1] ^= 1;
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodePlanV1(
            plan_destination[0..encoded_plan.len],
            &candidate_output,
        ),
    );
    for (candidate_before, candidate_output) |before, after|
        try std.testing.expect(std.meta.eql(before, after));
    plan_destination[encoded_plan.len - 1] ^= 1;

    var run_storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, run_storage.interface(), &result);
    var result_destination: [maximum_result_bytes]u8 =
        [_]u8{0x5a} ** maximum_result_bytes;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeResultV1(
            plan,
            result,
            result_destination[0 .. result_header_bytes - 1],
        ),
    );
    for (result_destination[0 .. result_header_bytes - 1]) |byte|
        try std.testing.expectEqual(@as(u8, 0x5a), byte);

    const encoded_result = try encodeResultV1(
        plan,
        result,
        &result_destination,
    );
    var outcome_output = run_storage.outcomes;
    var trace_output = run_storage.trace;
    const outcome_before = outcome_output;
    const trace_before = trace_output;
    result_destination[encoded_result.len - 1] ^= 1;
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodeResultV1(
            plan,
            result_destination[0..encoded_result.len],
            &outcome_output,
            &trace_output,
        ),
    );
    for (
        outcome_before[0..result.outcomes.len],
        outcome_output[0..result.outcomes.len],
    ) |before, after|
        try std.testing.expect(std.meta.eql(before, after));
    for (
        trace_before[0..result.trace.len],
        trace_output[0..result.trace.len],
    ) |before, after|
        try std.testing.expect(std.meta.eql(before, after));
}
