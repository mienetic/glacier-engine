//! Generic deterministic W4a typed-workload lifecycle driver.
//!
//! The runner owns only logical scheduling, resource admission, callback
//! choreography, and semantic evidence. Concrete model, media, provider, and
//! tool adapters remain outside this module and receive no ambient authority.

const std = @import("std");
const contract = @import("typed_workload_contract.zig");
const qos = @import("lane_weave_qos.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = contract.Digest;
pub const zero_digest: Digest = [_]u8{0} ** 32;
pub const absent = contract.absent;

pub const result_abi: u64 = 0x4754_5744_5200_0001;
pub const outcome_abi: u64 = 0x4754_5744_4f00_0001;
pub const trace_abi: u64 = 0x4754_5744_5400_0001;
pub const summary_abi: u64 = 0x4754_5744_5300_0001;

pub const maximum_trace_records: usize = 512;

const outcome_domain = "glacier-typed-workload-driver-outcome-v1\x00";
const outcome_section_domain =
    "glacier-typed-workload-driver-outcome-section-v1\x00";
const trace_record_domain =
    "glacier-typed-workload-driver-trace-record-v1\x00";
const trace_domain = "glacier-typed-workload-driver-trace-v1\x00";
const summary_domain = "glacier-typed-workload-driver-summary-v1\x00";
const result_domain = "glacier-typed-workload-driver-result-v1\x00";

pub const Error = contract.Error || qos.Error || resource_bank.Error || error{
    ArithmeticOverflow,
    BufferTooSmall,
    DriverFailed,
    DriverStepLimitExceeded,
    IncompletePlan,
    InvalidEvidence,
    ServiceLimitExceeded,
    TraceLimitExceeded,
};

pub const OutcomeKindV1 = enum(u64) {
    completed = 1,
    rejected = 2,
    cancelled = 3,
    timed_out = 4,
};

pub const OutcomeV1 = struct {
    ordinal: u64,
    item_sha256: Digest,
    profile_index: u64,
    profile_sha256: Digest,
    kind: OutcomeKindV1,
    rejection_reason: qos.RejectionReason = .none,
    terminal_action: contract.TerminalActionV1 = .none,
    scheduler_slot_index: u64 = absent,
    scheduler_slot_generation: u64 = 0,
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
    item_ordinal: u64,
    profile_index: u64,
    event_kind: qos.EventKind,
    scheduler_event_sequence: u64,
    rejection_reason: qos.RejectionReason,
    terminal_action: contract.TerminalActionV1,
    logical_tick_before: u64,
    logical_tick_after: u64,
    remaining_before: u64,
    remaining_after: u64,
    wait_quanta: u64,
    active_after: u64,
    finished_after: u64,
    scheduler_event_sha256: Digest,
    record_sha256: Digest,
};

pub const SummaryV1 = struct {
    profile_count: u64,
    item_count: u64,
    attempted: u64,
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
    bind_callbacks: u64,
    cancel_callbacks: u64,
    service_callbacks: u64,
    final_service_callbacks: u64,
    retire_callbacks: u64,
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
    plan_sha256: Digest,
    outcome_sha256: Digest,
    trace_sha256: Digest,
    summary_sha256: Digest,
    result_sha256: Digest,
    outcomes: []const OutcomeV1,
    trace: []const TraceRecordV1,
    summary: SummaryV1,
};

pub const SchedulerV1 = qos.Scheduler;
pub const SchedulerAdmissionV1 = qos.Admission;
pub const SchedulerHandleV1 = qos.Handle;
pub const SchedulerServicePermitV1 = qos.ServicePermitV1;
pub const SchedulerEventV1 = qos.EventV1;

/// Family-specific errors remain in caller-owned context. The callback returns
/// `DriverFailed` so the runner can execute generic permit and receipt cleanup.
pub const DriverError = qos.Error || error{DriverFailed};

pub const DriverBindAdmittedV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: contract.ItemV1,
    profile: contract.ProfileV1,
    admission: SchedulerAdmissionV1,
};

pub const DriverCancelV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: contract.ItemV1,
    profile: contract.ProfileV1,
    handle: SchedulerHandleV1,
    terminal_action: contract.TerminalActionV1,
};

pub const DriverCommitServiceV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: contract.ItemV1,
    profile: contract.ProfileV1,
    permit: SchedulerServicePermitV1,
    final_quantum: bool,
};

pub const DriverRetireV1 = struct {
    driver_step: u64,
    item_index: usize,
    item: contract.ItemV1,
    profile: contract.ProfileV1,
    handle: SchedulerHandleV1,
    final_service_event: SchedulerEventV1,
};

/// Additive lifecycle seam over the immutable typed-workload Plan V1.
///
/// The caller owns `context` and all address-sensitive adapter sessions.
/// `bind_admitted_fn` runs after Scheduler/Bank admission but before verifier
/// publication. Cancel, service, and retire callbacks must return the exact
/// current LaneWeave event. A failing service callback may leave its permit
/// unconsumed; the runner aborts it before `cleanup_fn`. If it consumed the
/// permit, its context must retain enough state for cleanup to close the bound
/// session. Rejected items invoke no callback.
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

pub const RuntimeStateV1 = enum {
    pending,
    active,
    terminal,
};

pub const RuntimeItemV1 = struct {
    state: RuntimeStateV1 = .pending,
    handle: qos.Handle = .{},
    admitted_step: u64 = absent,
    first_service_step: u64 = absent,
    terminal_step: u64 = absent,
    served_quanta: u64 = 0,
    fairness_quanta: u64 = 0,
    maximum_wait_quanta: u64 = 0,
    admission_trace_sha256: Digest = zero_digest,
    terminal_trace_sha256: Digest = zero_digest,
    outcome: ?OutcomeKindV1 = null,
    rejection_reason: qos.RejectionReason = .none,
    terminal_action: contract.TerminalActionV1 = .none,
};

pub const StorageV1 = struct {
    bank_slots: []resource_bank.Slot,
    scheduler_slots: []qos.Slot,
    scheduler_projection: []qos.ProjectionSlot,
    verifier_slots: []qos.Slot,
    verifier_projection: []qos.ProjectionSlot,
    runtime_items: []RuntimeItemV1,
    outcomes: []OutcomeV1,
    trace: []TraceRecordV1,
};

pub const MaximumStorageV1 = struct {
    bank_slots: [contract.maximum_items]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** contract.maximum_items,
    scheduler_slots: [contract.maximum_items]qos.Slot =
        [_]qos.Slot{.{}} ** contract.maximum_items,
    scheduler_projection: [contract.maximum_items]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** contract.maximum_items,
    verifier_slots: [contract.maximum_items]qos.Slot =
        [_]qos.Slot{.{}} ** contract.maximum_items,
    verifier_projection: [contract.maximum_items]qos.ProjectionSlot =
        [_]qos.ProjectionSlot{.{}} ** contract.maximum_items,
    runtime_items: [contract.maximum_items]RuntimeItemV1 =
        [_]RuntimeItemV1{.{}} ** contract.maximum_items,
    outcomes: [contract.maximum_items]OutcomeV1 = undefined,
    trace: [maximum_trace_records]TraceRecordV1 = undefined,

    pub fn interface(self: *MaximumStorageV1) StorageV1 {
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

const DriverCounts = struct {
    binds: u64 = 0,
    cancels: u64 = 0,
    services: u64 = 0,
    final_services: u64 = 0,
    retires: u64 = 0,
};

pub fn requiredTraceRecordsV1(plan: contract.PlanV1) Error!usize {
    try contract.validatePlanV1(plan);
    var count = try checkedAdd(
        @intCast(plan.items.len),
        @intCast(plan.items.len),
    );
    count = try checkedAdd(count, plan.max_service_quanta);
    count = try checkedAdd(count, 1);
    if (count > maximum_trace_records) return Error.TraceLimitExceeded;
    return @intCast(count);
}

pub fn runPlanV1(
    plan: contract.PlanV1,
    storage: StorageV1,
    output: *ResultV1,
) Error!void {
    return runPlanWithDriverV1(plan, storage, .{}, output);
}

pub fn runPlanWithDriverV1(
    plan: contract.PlanV1,
    storage: StorageV1,
    driver: DriverV1,
    output: *ResultV1,
) Error!void {
    try contract.validatePlanV1(plan);
    const capacity: usize = @intCast(plan.capacity);
    const trace_requirement = try requiredTraceRecordsV1(plan);
    if (storage.bank_slots.len < capacity or
        storage.scheduler_slots.len < capacity or
        storage.scheduler_projection.len < capacity or
        storage.verifier_slots.len < capacity or
        storage.verifier_projection.len < capacity or
        storage.runtime_items.len < plan.items.len or
        storage.outcomes.len < plan.items.len or
        storage.trace.len < trace_requirement)
        return Error.BufferTooSmall;

    const runtime_items = storage.runtime_items[0..plan.items.len];
    for (runtime_items) |*runtime_item| runtime_item.* = .{};
    var bank = try resource_bank.Bank.init(
        storage.bank_slots[0..capacity],
        plan.limits,
        plan.bank_epoch,
    );
    var scheduler = try qos.Scheduler.init(
        &bank,
        .{
            .slots = storage.scheduler_slots[0..capacity],
            .projection = storage.scheduler_projection[0..capacity],
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
            .slots = storage.verifier_slots[0..capacity],
            .projection = storage.verifier_projection[0..capacity],
        },
        scheduler.config,
        scheduler.bank_epoch,
        scheduler.limits,
    );
    var outstanding_permit: ?SchedulerServicePermitV1 = null;
    errdefer {
        if (outstanding_permit) |permit|
            _ = scheduler.abortService(permit) catch {};
        driver.cleanup_fn(driver.context, &scheduler);
        for (runtime_items) |runtime_item| {
            if (runtime_item.state != .active) continue;
            if (scheduler.cancel(runtime_item.handle)) |_| {} else |_| {
                _ = scheduler.retire(runtime_item.handle) catch {};
            }
        }
    }

    var trace_count: usize = 0;
    var maximum_live_receipts: u64 = 0;
    var driver_steps: u64 = 0;
    var service_quanta: u64 = 0;
    var driver_counts: DriverCounts = .{};
    var completed = false;
    var step: u64 = 0;
    while (step < plan.max_driver_steps) : (step += 1) {
        for (plan.items, 0..) |item, index| {
            if (item.arrival_step != step) continue;
            if (runtime_items[index].state != .pending)
                return Error.InvalidEvidence;
            const profile = try profileForItemV1(plan, item);
            const decision = try scheduler.admit(requestSpecV1(item));
            switch (decision) {
                .admitted => |admission| {
                    const runtime_item = &runtime_items[index];
                    runtime_item.state = .active;
                    runtime_item.handle = admission.handle;
                    runtime_item.admitted_step = step;
                    try driver.bind_admitted_fn(
                        driver.context,
                        &scheduler,
                        .{
                            .driver_step = step,
                            .item_index = index,
                            .item = item,
                            .profile = profile,
                            .admission = admission,
                        },
                    );
                    try requireCurrentDriverEventV1(
                        &scheduler,
                        admission.event,
                    );
                    driver_counts.binds = try checkedAdd(
                        driver_counts.binds,
                        1,
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
                    runtime_item.admission_trace_sha256 = try appendTrace(
                        storage.trace,
                        &trace_count,
                        step,
                        item.ordinal,
                        item.profile_index,
                        .none,
                        admission.event,
                    );
                },
                .rejected => |event| {
                    const runtime_item = &runtime_items[index];
                    runtime_item.state = .terminal;
                    runtime_item.outcome = .rejected;
                    runtime_item.rejection_reason = event.rejection_reason;
                    runtime_item.terminal_step = step;
                    try verifier.apply(event);
                    const root = try appendTrace(
                        storage.trace,
                        &trace_count,
                        step,
                        item.ordinal,
                        item.profile_index,
                        .none,
                        event,
                    );
                    runtime_item.admission_trace_sha256 = root;
                    runtime_item.terminal_trace_sha256 = root;
                },
            }
        }

        for (plan.items, 0..) |item, index| {
            if (item.terminal_action_step != step) continue;
            const runtime_item = &runtime_items[index];
            // Admission rejection or earlier natural completion supersedes a
            // later planned terminal action without invoking adapter code.
            if (runtime_item.state == .terminal) continue;
            if (runtime_item.state != .active or
                item.terminal_action == .none)
                return Error.InvalidEvidence;
            const profile = try profileForItemV1(plan, item);
            const event = try driver.cancel_fn(
                driver.context,
                &scheduler,
                .{
                    .driver_step = step,
                    .item_index = index,
                    .item = item,
                    .profile = profile,
                    .handle = runtime_item.handle,
                    .terminal_action = item.terminal_action,
                },
            );
            if (event.kind != .cancel or
                !std.meta.eql(event.handle, runtime_item.handle))
                return Error.DriverFailed;
            try requireCurrentDriverEventV1(&scheduler, event);
            driver_counts.cancels = try checkedAdd(driver_counts.cancels, 1);
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
                item.profile_index,
                item.terminal_action,
                event,
            );
        }

        const before_service = try scheduler.snapshot();
        if (before_service.active != 0) {
            if (service_quanta >= plan.max_service_quanta)
                return Error.ServiceLimitExceeded;
            const permit = try scheduler.prepareService();
            outstanding_permit = permit;
            const item_index = try findItemByHandleV1(
                runtime_items,
                permit.handle,
            );
            const item = plan.items[item_index];
            const profile = try profileForItemV1(plan, item);
            const final_quantum = permit.remaining_before == 1;
            const event = try driver.commit_service_fn(
                driver.context,
                &scheduler,
                .{
                    .driver_step = step,
                    .item_index = item_index,
                    .item = item,
                    .profile = profile,
                    .permit = permit,
                    .final_quantum = final_quantum,
                },
            );
            if (event.kind != .service or
                !std.meta.eql(event.handle, permit.handle) or
                event.remaining_before != permit.remaining_before or
                (event.remaining_after == 0) != final_quantum)
                return Error.DriverFailed;
            try requireCurrentDriverEventV1(&scheduler, event);
            outstanding_permit = null;
            service_quanta = try checkedAdd(service_quanta, 1);
            driver_counts.services = try checkedAdd(
                driver_counts.services,
                1,
            );
            if (final_quantum)
                driver_counts.final_services = try checkedAdd(
                    driver_counts.final_services,
                    1,
                );
            const runtime_item = &runtime_items[item_index];
            if (runtime_item.first_service_step == absent)
                runtime_item.first_service_step = step;
            runtime_item.served_quanta = try checkedAdd(
                runtime_item.served_quanta,
                1,
            );
            runtime_item.maximum_wait_quanta = @max(
                runtime_item.maximum_wait_quanta,
                event.wait_quanta,
            );
            if (item.fairness_member and
                event.logical_tick_after > plan.fairness_start_tick and
                event.logical_tick_after <= plan.fairness_end_tick)
                runtime_item.fairness_quanta = try checkedAdd(
                    runtime_item.fairness_quanta,
                    1,
                );
            try verifier.apply(event);
            _ = try appendTrace(
                storage.trace,
                &trace_count,
                step,
                item.ordinal,
                item.profile_index,
                .none,
                event,
            );
            if (event.remaining_after == 0) {
                const retire_event = try driver.retire_fn(
                    driver.context,
                    &scheduler,
                    .{
                        .driver_step = step,
                        .item_index = item_index,
                        .item = item,
                        .profile = profile,
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
                driver_counts.retires = try checkedAdd(
                    driver_counts.retires,
                    1,
                );
                runtime_item.state = .terminal;
                runtime_item.outcome = .completed;
                runtime_item.terminal_step = step;
                try verifier.apply(retire_event);
                runtime_item.terminal_trace_sha256 = try appendTrace(
                    storage.trace,
                    &trace_count,
                    step,
                    item.ordinal,
                    item.profile_index,
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
        if (allTerminalV1(runtime_items)) {
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
        absent,
        absent,
        .none,
        close_event,
    );
    _ = try verifier.finish(close_event.event_sha256);
    const scheduler_final = try scheduler.snapshot();
    const bank_final = try bank.snapshot();

    for (
        plan.items,
        runtime_items,
        storage.outcomes[0..plan.items.len],
    ) |item, runtime_item, *outcome| {
        const kind = runtime_item.outcome orelse
            return Error.IncompletePlan;
        outcome.* = .{
            .ordinal = item.ordinal,
            .item_sha256 = item.item_sha256,
            .profile_index = item.profile_index,
            .profile_sha256 = item.profile_sha256,
            .kind = kind,
            .rejection_reason = runtime_item.rejection_reason,
            .terminal_action = runtime_item.terminal_action,
            .scheduler_slot_index = if (kind == .rejected)
                absent
            else
                @intCast(runtime_item.handle.slot_index),
            .scheduler_slot_generation = if (kind == .rejected)
                0
            else
                runtime_item.handle.slot_generation,
            .admitted_step = runtime_item.admitted_step,
            .first_service_step = runtime_item.first_service_step,
            .terminal_step = runtime_item.terminal_step,
            .served_quanta = runtime_item.served_quanta,
            .maximum_wait_quanta = runtime_item.maximum_wait_quanta,
            .admission_trace_sha256 = runtime_item.admission_trace_sha256,
            .terminal_trace_sha256 = runtime_item.terminal_trace_sha256,
            .record_sha256 = zero_digest,
        };
        outcome.record_sha256 = outcomeRecordSha256V1(outcome.*);
    }

    const outcomes = storage.outcomes[0..plan.items.len];
    const trace = storage.trace[0..trace_count];
    const summary = try summarizeV1(
        plan,
        runtime_items,
        outcomes,
        trace,
        driver_steps,
        maximum_live_receipts,
        scheduler_final,
        bank_final,
        driver_counts,
    );
    const plan_root = contract.planSha256V1(plan);
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
        !std.mem.eql(u8, &event.event_sha256, &qos.eventSha256(event)) or
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

fn profileForItemV1(
    plan: contract.PlanV1,
    item: contract.ItemV1,
) Error!contract.ProfileV1 {
    const index = std.math.cast(usize, item.profile_index) orelse
        return Error.InvalidEvidence;
    if (index >= plan.profiles.len) return Error.InvalidEvidence;
    const profile = plan.profiles[index];
    if (profile.index != item.profile_index or
        !std.mem.eql(u8, &profile.profile_sha256, &item.profile_sha256))
        return Error.InvalidEvidence;
    return profile;
}

fn requestSpecV1(item: contract.ItemV1) qos.RequestSpec {
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

fn findItemByHandleV1(
    runtime_items: []const RuntimeItemV1,
    handle: qos.Handle,
) Error!usize {
    for (runtime_items, 0..) |runtime_item, index| {
        if (runtime_item.state == .active and
            runtime_item.handle.scheduler_epoch ==
                handle.scheduler_epoch and
            runtime_item.handle.slot_index == handle.slot_index and
            runtime_item.handle.slot_generation ==
                handle.slot_generation and
            runtime_item.handle.tenant_key == handle.tenant_key and
            runtime_item.handle.request_key == handle.request_key and
            runtime_item.handle.request_generation ==
                handle.request_generation)
            return index;
    }
    return Error.InvalidEvidence;
}

fn allTerminalV1(runtime_items: []const RuntimeItemV1) bool {
    for (runtime_items) |runtime_item| {
        if (runtime_item.state != .terminal) return false;
    }
    return true;
}

fn appendTrace(
    storage: []TraceRecordV1,
    count: *usize,
    driver_step: u64,
    item_ordinal: u64,
    profile_index: u64,
    terminal_action: contract.TerminalActionV1,
    event: qos.EventV1,
) Error!Digest {
    if (count.* >= storage.len or count.* >= maximum_trace_records)
        return Error.TraceLimitExceeded;
    var record: TraceRecordV1 = .{
        .sequence = @intCast(count.*),
        .driver_step = driver_step,
        .item_ordinal = item_ordinal,
        .profile_index = profile_index,
        .event_kind = event.kind,
        .scheduler_event_sequence = event.event_sequence,
        .rejection_reason = event.rejection_reason,
        .terminal_action = terminal_action,
        .logical_tick_before = event.logical_tick_before,
        .logical_tick_after = event.logical_tick_after,
        .remaining_before = event.remaining_before,
        .remaining_after = event.remaining_after,
        .wait_quanta = event.wait_quanta,
        .active_after = event.active_after,
        .finished_after = event.finished_after,
        .scheduler_event_sha256 = event.event_sha256,
        .record_sha256 = zero_digest,
    };
    record.record_sha256 = traceRecordSha256V1(record);
    storage[count.*] = record;
    count.* += 1;
    return record.record_sha256;
}

fn summarizeV1(
    plan: contract.PlanV1,
    runtime_items: []const RuntimeItemV1,
    outcomes: []const OutcomeV1,
    trace: []const TraceRecordV1,
    driver_steps: u64,
    maximum_live_receipts: u64,
    scheduler_final: qos.SnapshotV1,
    bank_final: resource_bank.Snapshot,
    driver_counts: DriverCounts,
) Error!SummaryV1 {
    var admitted: u64 = 0;
    var rejected: u64 = 0;
    var completed: u64 = 0;
    var cancelled: u64 = 0;
    var timed_out: u64 = 0;
    var service_quanta: u64 = 0;
    var maximum_wait: u64 = 0;
    for (outcomes) |outcome| {
        service_quanta = try checkedAdd(
            service_quanta,
            outcome.served_quanta,
        );
        maximum_wait = @max(
            maximum_wait,
            outcome.maximum_wait_quanta,
        );
        switch (outcome.kind) {
            .rejected => rejected = try checkedAdd(rejected, 1),
            .completed => {
                admitted = try checkedAdd(admitted, 1);
                completed = try checkedAdd(completed, 1);
            },
            .cancelled => {
                admitted = try checkedAdd(admitted, 1);
                cancelled = try checkedAdd(cancelled, 1);
            },
            .timed_out => {
                admitted = try checkedAdd(admitted, 1);
                timed_out = try checkedAdd(timed_out, 1);
            },
        }
    }

    var fairness_error: u64 = 0;
    for (plan.items, runtime_items, 0..) |
        left,
        left_runtime,
        left_index,
    | {
        if (!left.fairness_member) continue;
        for (
            plan.items[left_index + 1 ..],
            runtime_items[left_index + 1 ..],
        ) |right, right_runtime| {
            if (!right.fairness_member) continue;
            const left_scaled = std.math.mul(
                u64,
                left_runtime.fairness_quanta,
                @as(u64, right.weight),
            ) catch return Error.ArithmeticOverflow;
            const right_scaled = std.math.mul(
                u64,
                right_runtime.fairness_quanta,
                @as(u64, left.weight),
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
        if (record.event_kind == .service)
            trace_service_count = try checkedAdd(trace_service_count, 1);
    }
    if (trace_service_count != service_quanta or
        service_quanta != driver_counts.services)
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
        .profile_count = @intCast(plan.profiles.len),
        .item_count = @intCast(plan.items.len),
        .attempted = @intCast(plan.items.len),
        .admitted = admitted,
        .rejected = rejected,
        .completed = completed,
        .cancelled = cancelled,
        .timed_out = timed_out,
        .service_quanta = service_quanta,
        .driver_steps = driver_steps,
        .final_logical_tick = scheduler_final.logical_tick,
        .maximum_live_receipts = maximum_live_receipts,
        .peak_host_bytes = bank_final.peak_host_bytes,
        .peak = bank_final.peak,
        .maximum_wait_quanta = maximum_wait,
        .maximum_service_gap = scheduler_final.maximum_service_gap,
        .fairness_cross_product_error = fairness_error,
        .bind_callbacks = driver_counts.binds,
        .cancel_callbacks = driver_counts.cancels,
        .service_callbacks = driver_counts.services,
        .final_service_callbacks = driver_counts.final_services,
        .retire_callbacks = driver_counts.retires,
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

/// Checks semantic shape and all self-authenticating roots without executing
/// adapter code. Use `validateResultByReplayV1` when canonical equivalence to
/// the deterministic built-in driver is required.
pub fn validateResultStructureV1(
    plan: contract.PlanV1,
    result: ResultV1,
) Error!void {
    try contract.validatePlanV1(plan);
    if (result.outcomes.len != plan.items.len or
        result.trace.len == 0 or
        result.trace.len > maximum_trace_records or
        !std.mem.eql(
            u8,
            &result.plan_sha256,
            &contract.planSha256V1(plan),
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
        ))
        return Error.InvalidEvidence;

    const summary = result.summary;
    const cancelled_or_timed_out = try checkedAdd(
        summary.cancelled,
        summary.timed_out,
    );
    const admitted_from_terminal = try checkedAdd(
        summary.completed,
        cancelled_or_timed_out,
    );
    const attempted_from_admission = try checkedAdd(
        summary.admitted,
        summary.rejected,
    );
    const peak_host_envelope = try summary.peak.hostBytes();
    if (summary.profile_count != plan.profiles.len or
        summary.item_count != plan.items.len or
        summary.attempted != plan.items.len or
        summary.attempted != attempted_from_admission or
        summary.admitted != admitted_from_terminal or
        summary.bind_callbacks != summary.admitted or
        summary.cancel_callbacks != cancelled_or_timed_out or
        summary.service_callbacks != summary.service_quanta or
        summary.final_service_callbacks != summary.completed or
        summary.retire_callbacks != summary.completed or
        summary.final_logical_tick != summary.service_quanta or
        summary.maximum_live_receipts > plan.capacity or
        summary.maximum_wait_quanta > summary.maximum_service_gap or
        summary.peak_host_bytes > peak_host_envelope or
        summary.successful_commits != summary.admitted or
        summary.releases != summary.admitted or
        summary.bank_cancellations != 0 or
        summary.bank_rejected_capacity != 0 or
        summary.bank_rejected_slots != 0 or
        !summary.zero_orphan_ownership or
        summary.final_active != 0 or
        summary.final_finished != 0 or
        summary.final_active_reservations != 0 or
        summary.final_committed_receipts != 0)
        return Error.InvalidEvidence;

    var counted_admitted: u64 = 0;
    var counted_rejected: u64 = 0;
    var counted_completed: u64 = 0;
    var counted_cancelled: u64 = 0;
    var counted_timed_out: u64 = 0;
    var counted_service: u64 = 0;
    var counted_maximum_wait: u64 = 0;
    for (plan.items, result.outcomes) |item, outcome| {
        if (outcome.ordinal != item.ordinal or
            outcome.profile_index != item.profile_index or
            !std.mem.eql(
                u8,
                &outcome.item_sha256,
                &item.item_sha256,
            ) or
            !std.mem.eql(
                u8,
                &outcome.profile_sha256,
                &item.profile_sha256,
            ) or
            !std.mem.eql(
                u8,
                &outcome.record_sha256,
                &outcomeRecordSha256V1(outcome),
            ) or
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
        counted_service = try checkedAdd(
            counted_service,
            outcome.served_quanta,
        );
        counted_maximum_wait = @max(
            counted_maximum_wait,
            outcome.maximum_wait_quanta,
        );
        switch (outcome.kind) {
            .rejected => {
                counted_rejected = try checkedAdd(counted_rejected, 1);
                if (outcome.rejection_reason == .none or
                    outcome.terminal_action != .none or
                    outcome.scheduler_slot_index != absent or
                    outcome.scheduler_slot_generation != 0 or
                    outcome.admitted_step != absent or
                    outcome.first_service_step != absent or
                    outcome.terminal_step != item.arrival_step or
                    outcome.served_quanta != 0 or
                    !std.mem.eql(
                        u8,
                        &outcome.admission_trace_sha256,
                        &outcome.terminal_trace_sha256,
                    ))
                    return Error.InvalidEvidence;
            },
            .completed => {
                counted_admitted = try checkedAdd(counted_admitted, 1);
                counted_completed = try checkedAdd(counted_completed, 1);
                if (outcome.rejection_reason != .none or
                    outcome.terminal_action != .none or
                    outcome.scheduler_slot_index == absent or
                    outcome.admitted_step != item.arrival_step or
                    outcome.first_service_step == absent or
                    outcome.served_quanta != item.work_quanta)
                    return Error.InvalidEvidence;
            },
            .cancelled => {
                counted_admitted = try checkedAdd(counted_admitted, 1);
                counted_cancelled = try checkedAdd(counted_cancelled, 1);
                if (outcome.rejection_reason != .none or
                    outcome.terminal_action != .cancel or
                    outcome.scheduler_slot_index == absent or
                    outcome.admitted_step != item.arrival_step or
                    outcome.terminal_step !=
                        item.terminal_action_step)
                    return Error.InvalidEvidence;
            },
            .timed_out => {
                counted_admitted = try checkedAdd(counted_admitted, 1);
                counted_timed_out = try checkedAdd(counted_timed_out, 1);
                if (outcome.rejection_reason != .none or
                    outcome.terminal_action != .timeout or
                    outcome.scheduler_slot_index == absent or
                    outcome.admitted_step != item.arrival_step or
                    outcome.terminal_step !=
                        item.terminal_action_step)
                    return Error.InvalidEvidence;
            },
        }
    }
    if (counted_admitted != summary.admitted or
        counted_rejected != summary.rejected or
        counted_completed != summary.completed or
        counted_cancelled != summary.cancelled or
        counted_timed_out != summary.timed_out or
        counted_service != summary.service_quanta or
        counted_maximum_wait != summary.maximum_wait_quanta)
        return Error.InvalidEvidence;

    var service_records: u64 = 0;
    var maximum_wait: u64 = 0;
    var maximum_receipts: u64 = 0;
    for (result.trace, 0..) |record, index| {
        if (record.sequence != index or
            record.scheduler_event_sequence != index or
            !std.mem.eql(
                u8,
                &record.record_sha256,
                &traceRecordSha256V1(record),
            ) or
            std.mem.eql(
                u8,
                &record.scheduler_event_sha256,
                &zero_digest,
            ) or
            (index != 0 and
                record.driver_step <
                    result.trace[index - 1].driver_step) or
            (index != 0 and
                record.logical_tick_before !=
                    result.trace[index - 1].logical_tick_after))
            return Error.InvalidEvidence;
        maximum_receipts = @max(
            maximum_receipts,
            try checkedAdd(record.active_after, record.finished_after),
        );
        if (record.event_kind == .close) {
            if (index != result.trace.len - 1 or
                record.item_ordinal != absent or
                record.profile_index != absent or
                record.driver_step != summary.driver_steps or
                record.active_after != 0 or
                record.finished_after != 0)
                return Error.InvalidEvidence;
            continue;
        }
        const item_index = itemIndexForOrdinalV1(
            plan,
            record.item_ordinal,
        ) orelse return Error.InvalidEvidence;
        const item = plan.items[item_index];
        if (record.profile_index != item.profile_index)
            return Error.InvalidEvidence;
        if (record.event_kind == .service) {
            service_records = try checkedAdd(service_records, 1);
            maximum_wait = @max(maximum_wait, record.wait_quanta);
        }
    }
    const terminal = result.trace[result.trace.len - 1];
    if (terminal.event_kind != .close or
        terminal.logical_tick_after != summary.final_logical_tick or
        service_records != summary.service_quanta or
        maximum_wait != summary.maximum_wait_quanta or
        maximum_receipts != summary.maximum_live_receipts)
        return Error.InvalidEvidence;
    try validateOutcomeTraceReferencesV1(plan, result);
}

fn validateOutcomeTraceReferencesV1(
    plan: contract.PlanV1,
    result: ResultV1,
) Error!void {
    for (plan.items, result.outcomes) |item, outcome| {
        var admission_root: ?Digest = null;
        var terminal_root: ?Digest = null;
        var service_count: u64 = 0;
        for (result.trace) |record| {
            if (record.item_ordinal != item.ordinal) continue;
            switch (record.event_kind) {
                .admission_accepted => {
                    if (admission_root != null or
                        record.driver_step != item.arrival_step)
                        return Error.InvalidEvidence;
                    admission_root = record.record_sha256;
                },
                .admission_rejected => {
                    if (admission_root != null or
                        terminal_root != null or
                        record.driver_step != item.arrival_step)
                        return Error.InvalidEvidence;
                    admission_root = record.record_sha256;
                    terminal_root = record.record_sha256;
                },
                .service => {
                    service_count = try checkedAdd(service_count, 1);
                },
                .cancel => {
                    if (terminal_root != null or
                        record.driver_step != outcome.terminal_step or
                        record.terminal_action !=
                            outcome.terminal_action)
                        return Error.InvalidEvidence;
                    terminal_root = record.record_sha256;
                },
                .retire => {
                    if (terminal_root != null or
                        record.driver_step != outcome.terminal_step)
                        return Error.InvalidEvidence;
                    terminal_root = record.record_sha256;
                },
                .close => return Error.InvalidEvidence,
            }
        }
        if (admission_root == null or terminal_root == null or
            service_count != outcome.served_quanta or
            !std.mem.eql(
                u8,
                &admission_root.?,
                &outcome.admission_trace_sha256,
            ) or
            !std.mem.eql(
                u8,
                &terminal_root.?,
                &outcome.terminal_trace_sha256,
            ))
            return Error.InvalidEvidence;
    }
}

/// Re-executes the plan with the built-in synthetic scheduler driver and
/// requires exact equality for every semantic field and root. Input evidence
/// is copied first, so replay storage may alias the original result storage.
pub fn validateResultByReplayV1(
    plan: contract.PlanV1,
    result: ResultV1,
    storage: StorageV1,
) Error!void {
    try validateResultStructureV1(plan, result);

    const actual_plan_root = result.plan_sha256;
    const actual_outcome_root = result.outcome_sha256;
    const actual_trace_root = result.trace_sha256;
    const actual_summary_root = result.summary_sha256;
    const actual_result_root = result.result_sha256;
    const actual_summary = result.summary;
    var actual_outcomes: [contract.maximum_items]OutcomeV1 = undefined;
    var actual_trace: [maximum_trace_records]TraceRecordV1 = undefined;
    @memcpy(actual_outcomes[0..result.outcomes.len], result.outcomes);
    @memcpy(actual_trace[0..result.trace.len], result.trace);
    const actual_outcome_count = result.outcomes.len;
    const actual_trace_count = result.trace.len;

    var expected: ResultV1 = undefined;
    try runPlanV1(plan, storage, &expected);
    if (!std.mem.eql(
        u8,
        &actual_plan_root,
        &expected.plan_sha256,
    ) or
        !std.mem.eql(
            u8,
            &actual_outcome_root,
            &expected.outcome_sha256,
        ) or
        !std.mem.eql(
            u8,
            &actual_trace_root,
            &expected.trace_sha256,
        ) or
        !std.mem.eql(
            u8,
            &actual_summary_root,
            &expected.summary_sha256,
        ) or
        !std.mem.eql(
            u8,
            &actual_result_root,
            &expected.result_sha256,
        ) or
        !std.meta.eql(actual_summary, expected.summary) or
        actual_outcome_count != expected.outcomes.len or
        actual_trace_count != expected.trace.len)
        return Error.InvalidEvidence;
    for (
        actual_outcomes[0..actual_outcome_count],
        expected.outcomes,
    ) |actual, canonical| {
        if (!std.meta.eql(actual, canonical))
            return Error.InvalidEvidence;
    }
    for (
        actual_trace[0..actual_trace_count],
        expected.trace,
    ) |actual, canonical| {
        if (!std.meta.eql(actual, canonical))
            return Error.InvalidEvidence;
    }
}

pub fn outcomeRecordSha256V1(outcome: OutcomeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(outcome_domain);
    hashU64(&hash, outcome_abi);
    hashU64(&hash, outcome.ordinal);
    hash.update(&outcome.item_sha256);
    hashU64(&hash, outcome.profile_index);
    hash.update(&outcome.profile_sha256);
    hashU64(&hash, @intFromEnum(outcome.kind));
    hashU64(&hash, @intFromEnum(outcome.rejection_reason));
    hashU64(&hash, @intFromEnum(outcome.terminal_action));
    hashU64(&hash, outcome.scheduler_slot_index);
    hashU64(&hash, outcome.scheduler_slot_generation);
    hashU64(&hash, outcome.admitted_step);
    hashU64(&hash, outcome.first_service_step);
    hashU64(&hash, outcome.terminal_step);
    hashU64(&hash, outcome.served_quanta);
    hashU64(&hash, outcome.maximum_wait_quanta);
    hash.update(&outcome.admission_trace_sha256);
    hash.update(&outcome.terminal_trace_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn outcomeSha256V1(outcomes: []const OutcomeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(outcome_section_domain);
    hashU64(&hash, outcome_abi);
    hashU64(&hash, outcomes.len);
    for (outcomes) |outcome| hash.update(&outcome.record_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn traceRecordSha256V1(record: TraceRecordV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(trace_record_domain);
    hashU64(&hash, trace_abi);
    hashU64(&hash, record.sequence);
    hashU64(&hash, record.driver_step);
    hashU64(&hash, record.item_ordinal);
    hashU64(&hash, record.profile_index);
    hashU64(&hash, @intFromEnum(record.event_kind));
    hashU64(&hash, record.scheduler_event_sequence);
    hashU64(&hash, @intFromEnum(record.rejection_reason));
    hashU64(&hash, @intFromEnum(record.terminal_action));
    hashU64(&hash, record.logical_tick_before);
    hashU64(&hash, record.logical_tick_after);
    hashU64(&hash, record.remaining_before);
    hashU64(&hash, record.remaining_after);
    hashU64(&hash, record.wait_quanta);
    hashU64(&hash, record.active_after);
    hashU64(&hash, record.finished_after);
    hash.update(&record.scheduler_event_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn traceSha256V1(trace: []const TraceRecordV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(trace_domain);
    hashU64(&hash, trace_abi);
    hashU64(&hash, trace.len);
    for (trace) |record| hash.update(&record.record_sha256);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

pub fn summarySha256V1(summary: SummaryV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(summary_domain);
    hashU64(&hash, summary_abi);
    inline for (.{
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
        @intFromBool(summary.zero_orphan_ownership),
    }) |value| hashU64(&hash, value);
    hashClaim(&hash, summary.peak);
    var root: Digest = undefined;
    hash.final(&root);
    return root;
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
    var root: Digest = undefined;
    hash.final(&root);
    return root;
}

fn itemIndexForOrdinalV1(
    plan: contract.PlanV1,
    ordinal: u64,
) ?usize {
    for (plan.items, 0..) |item, index| {
        if (item.ordinal == ordinal) return index;
    }
    return null;
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: anytype,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, @intCast(value), .little);
    hash.update(&encoded);
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn testDigest(value: u8) Digest {
    return [_]u8{value} ** 32;
}

fn testProfile(index: usize) contract.ProfileV1 {
    var profile: contract.ProfileV1 = .{
        .index = index,
        .family = switch (index) {
            0 => .vision_understanding,
            1 => .audio_understanding,
            else => .video_understanding,
        },
        .operation = .encode,
        .input_kind = switch (index) {
            0 => .image_feature_u8,
            1 => .audio_feature_i16,
            else => .video_feature_u8,
        },
        .output_kind = .embedding_i32,
        .numerical_policy = .exact_integer,
        .adapter_abi = 0x4757_3454_0000_0001 + index,
        .lifecycle = if (index == 1) .stateful else .stateless,
        .execution_unit = switch (index) {
            0 => .operation,
            1 => .sample,
            else => .frame,
        },
        .cancellation_boundary = .between_units,
        .publication_policy = .final_only,
        .correctness_gate = .exact,
        .claim = switch (index) {
            0 => .{
                .capsule_bytes = 64,
                .activation_bytes = 128,
                .device_bytes = 256,
                .queue_slots = 1,
            },
            1 => .{
                .capsule_bytes = 48,
                .partial_bytes = 96,
                .device_bytes = 128,
                .queue_slots = 1,
            },
            else => .{
                .capsule_bytes = 80,
                .activation_bytes = 160,
                .staging_bytes = 64,
                .device_bytes = 320,
                .queue_slots = 1,
            },
        },
        .support_sha256 = testDigest(@intCast(0x10 + index)),
        .artifact_sha256 = testDigest(@intCast(0x20 + index)),
        .execution_plan_sha256 = testDigest(@intCast(0x30 + index)),
        .adapter_implementation_sha256 = testDigest(@intCast(0x40 + index)),
        .correctness_sha256 = testDigest(@intCast(0x50 + index)),
        .profile_sha256 = zero_digest,
    };
    profile.profile_sha256 = contract.profileSha256V1(profile);
    return profile;
}

fn testItem(
    ordinal: usize,
    profile: contract.ProfileV1,
    work_quanta: u64,
    action_step: u64,
    action: contract.TerminalActionV1,
    fairness_member: bool,
) contract.ItemV1 {
    const identity: u64 = @intCast(ordinal + 1);
    var item: contract.ItemV1 = .{
        .ordinal = ordinal,
        .profile_index = profile.index,
        .profile_sha256 = profile.profile_sha256,
        .arrival_step = 0,
        .weight = if (profile.index == 0) 2 else 1,
        .work_quanta = work_quanta,
        .deadline_tick = 32,
        .terminal_action_step = action_step,
        .terminal_action = action,
        .fairness_member = fairness_member,
        .tenant_key = 0x1000 + identity,
        .request_key = 0x2000 + identity,
        .request_generation = 1,
        .resource_owner_key = 0x3000 + identity,
        .claim = profile.claim,
        .input_binding_sha256 = testDigest(@intCast(0x60 + ordinal)),
        .item_sha256 = zero_digest,
    };
    item.item_sha256 = contract.itemSha256V1(item);
    return item;
}

fn testProfiles() [3]contract.ProfileV1 {
    return .{
        testProfile(0),
        testProfile(1),
        testProfile(2),
    };
}

fn testItems(
    profiles: *const [3]contract.ProfileV1,
) [5]contract.ItemV1 {
    return .{
        testItem(0, profiles[0], 2, absent, .none, true),
        testItem(1, profiles[1], 3, absent, .none, true),
        testItem(2, profiles[2], 6, 2, .cancel, false),
        testItem(3, profiles[0], 6, 3, .timeout, false),
        testItem(4, profiles[1], 1, absent, .none, false),
    };
}

fn testPlan(
    profiles: []const contract.ProfileV1,
    items: []const contract.ItemV1,
) contract.PlanV1 {
    return .{
        .seed = 0x4757_3454_2026_0001,
        .capacity = 4,
        .max_driver_steps = 32,
        .max_service_quanta = 32,
        .fairness_start_tick = 0,
        .fairness_end_tick = 16,
        .bank_epoch = 0x4757_3442_0000_0001,
        .scheduler_epoch = 0x4757_3453_0000_0001,
        .max_weight = 4,
        .max_projection_quanta = 128,
        .max_projection_operations = 4096,
        .limits = .{
            .host_bytes = 4096,
            .capsule_bytes = 1024,
            .kv_bytes = 1024,
            .activation_bytes = 2048,
            .partial_bytes = 1024,
            .logits_bytes = 1024,
            .output_journal_bytes = 1024,
            .staging_bytes = 1024,
            .device_bytes = 4096,
            .io_bytes = 1024,
            .queue_slots = 4,
        },
        .challenge = testDigest(0x71),
        .profiles = profiles,
        .items = items,
    };
}

const ProbeState = enum {
    pending,
    bound,
    final_service,
    cancelled,
    retired,
};

const DriverProbe = struct {
    states: [contract.maximum_items]ProbeState =
        [_]ProbeState{.pending} ** contract.maximum_items,
    handles: [contract.maximum_items]qos.Handle =
        [_]qos.Handle{.{}} ** contract.maximum_items,
    binds: u64 = 0,
    cancels: u64 = 0,
    services: u64 = 0,
    final_services: u64 = 0,
    retires: u64 = 0,
    failed: bool = false,
    forge_next_service_event: bool = false,

    fn interface(self: *DriverProbe) DriverV1 {
        return .{
            .context = self,
            .bind_admitted_fn = bind,
            .cancel_fn = cancel,
            .commit_service_fn = service,
            .retire_fn = retire,
        };
    }

    fn fromContext(context: ?*anyopaque) *DriverProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn bind(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverBindAdmittedV1,
    ) DriverError!void {
        _ = scheduler;
        const self = fromContext(context);
        const index = input.item_index;
        if (index >= self.states.len or
            self.states[index] != .pending or
            input.admission.event.kind != .admission_accepted or
            !std.meta.eql(
                input.admission.handle,
                input.admission.event.handle,
            ) or
            input.item.profile_index != input.profile.index or
            !std.mem.eql(
                u8,
                &input.item.profile_sha256,
                &input.profile.profile_sha256,
            ) or
            !std.mem.eql(
                u8,
                &input.admission.event.resource_receipt_sha256,
                &qos.resourceReceiptSha256(
                    input.admission.event.resource_receipt,
                ),
            ))
        {
            self.failed = true;
            return error.DriverFailed;
        }
        self.states[index] = .bound;
        self.handles[index] = input.admission.handle;
        self.binds += 1;
    }

    fn cancel(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCancelV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        const index = input.item_index;
        if (self.states[index] != .bound or
            !std.meta.eql(self.handles[index], input.handle) or
            input.terminal_action == .none)
        {
            self.failed = true;
            return error.DriverFailed;
        }
        const event = try scheduler.cancel(input.handle);
        self.states[index] = .cancelled;
        self.cancels += 1;
        return event;
    }

    fn service(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCommitServiceV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        const index = input.item_index;
        if (self.states[index] != .bound or
            !std.meta.eql(self.handles[index], input.permit.handle) or
            input.final_quantum !=
                (input.permit.remaining_before == 1))
        {
            self.failed = true;
            return error.DriverFailed;
        }
        var event = try scheduler.commitService(input.permit);
        self.services += 1;
        if (input.final_quantum) {
            self.states[index] = .final_service;
            self.final_services += 1;
        }
        if (self.forge_next_service_event) {
            self.forge_next_service_event = false;
            event.event_sha256[0] ^= 0x01;
        }
        return event;
    }

    fn retire(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverRetireV1,
    ) DriverError!SchedulerEventV1 {
        const self = fromContext(context);
        const index = input.item_index;
        if (self.states[index] != .final_service or
            !std.meta.eql(self.handles[index], input.handle) or
            input.final_service_event.kind != .service or
            input.final_service_event.remaining_after != 0)
        {
            self.failed = true;
            return error.DriverFailed;
        }
        const event = try scheduler.retire(input.handle);
        self.states[index] = .retired;
        self.retires += 1;
        return event;
    }
};

const FailingDriverProbe = struct {
    handles: [contract.maximum_items]qos.Handle =
        [_]qos.Handle{.{}} ** contract.maximum_items,
    bound: [contract.maximum_items]bool =
        [_]bool{false} ** contract.maximum_items,
    cleanup_calls: u64 = 0,
    cleanup_zero: bool = false,

    fn interface(self: *FailingDriverProbe) DriverV1 {
        return .{
            .context = self,
            .bind_admitted_fn = bind,
            .commit_service_fn = failService,
            .cleanup_fn = cleanup,
        };
    }

    fn fromContext(context: ?*anyopaque) *FailingDriverProbe {
        return @ptrCast(@alignCast(context.?));
    }

    fn bind(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverBindAdmittedV1,
    ) DriverError!void {
        _ = scheduler;
        const self = fromContext(context);
        self.bound[input.item_index] = true;
        self.handles[input.item_index] = input.admission.handle;
    }

    fn failService(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
        input: DriverCommitServiceV1,
    ) DriverError!SchedulerEventV1 {
        _ = context;
        _ = scheduler;
        _ = input;
        return error.DriverFailed;
    }

    fn cleanup(
        context: ?*anyopaque,
        scheduler: *SchedulerV1,
    ) void {
        const self = fromContext(context);
        self.cleanup_calls += 1;
        for (self.bound, self.handles, 0..) |
            is_bound,
            handle,
            index,
        | {
            if (!is_bound) continue;
            _ = scheduler.cancel(handle) catch continue;
            self.bound[index] = false;
        }
        const scheduler_snapshot = scheduler.snapshot() catch return;
        const bank_snapshot = scheduler.bank.snapshot() catch return;
        self.cleanup_zero = scheduler_snapshot.active == 0 and
            scheduler_snapshot.finished == 0 and
            scheduler_snapshot.used.isZero() and
            bank_snapshot.used.isZero() and
            bank_snapshot.active_reservations == 0 and
            bank_snapshot.committed_receipts == 0;
    }
};

test "typed runner covers complete cancel timeout reject and replay" {
    var profiles = testProfiles();
    var items = testItems(&profiles);
    const plan = testPlan(&profiles, &items);
    try contract.validatePlanV1(plan);

    var storage: MaximumStorageV1 = .{};
    var result: ResultV1 = undefined;
    try runPlanV1(plan, storage.interface(), &result);
    try std.testing.expectEqual(@as(u64, 4), result.summary.admitted);
    try std.testing.expectEqual(@as(u64, 1), result.summary.rejected);
    try std.testing.expectEqual(@as(u64, 2), result.summary.completed);
    try std.testing.expectEqual(@as(u64, 1), result.summary.cancelled);
    try std.testing.expectEqual(@as(u64, 1), result.summary.timed_out);
    try std.testing.expectEqual(
        qos.RejectionReason.no_slot,
        result.outcomes[4].rejection_reason,
    );
    try std.testing.expect(result.summary.zero_orphan_ownership);
    try std.testing.expect(!std.mem.eql(
        u8,
        &result.result_sha256,
        &zero_digest,
    ));
    var expected_result_root: Digest = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_result_root,
        "cc04cf1864a1030d9465a1dfc5eae19269a4eb0ba7f82b9904d0d7ce4e5d008e",
    );
    try std.testing.expectEqualSlices(
        u8,
        &expected_result_root,
        &result.result_sha256,
    );

    var replay_storage: MaximumStorageV1 = .{};
    try validateResultByReplayV1(
        plan,
        result,
        replay_storage.interface(),
    );

    const original = storage.outcomes[0];
    storage.outcomes[0].served_quanta += 1;
    try std.testing.expectError(
        Error.InvalidEvidence,
        validateResultStructureV1(plan, result),
    );
    storage.outcomes[0] = original;
}

test "typed runner driver seam preserves exact deterministic evidence" {
    var profiles = testProfiles();
    var items = testItems(&profiles);
    const plan = testPlan(&profiles, &items);

    var canonical_storage: MaximumStorageV1 = .{};
    var canonical: ResultV1 = undefined;
    try runPlanV1(plan, canonical_storage.interface(), &canonical);

    var probe: DriverProbe = .{};
    var driven_storage: MaximumStorageV1 = .{};
    var driven: ResultV1 = undefined;
    try runPlanWithDriverV1(
        plan,
        driven_storage.interface(),
        probe.interface(),
        &driven,
    );
    try std.testing.expect(!probe.failed);
    try std.testing.expectEqual(driven.summary.admitted, probe.binds);
    try std.testing.expectEqual(
        driven.summary.cancelled + driven.summary.timed_out,
        probe.cancels,
    );
    try std.testing.expectEqual(
        driven.summary.service_quanta,
        probe.services,
    );
    try std.testing.expectEqual(
        driven.summary.completed,
        probe.final_services,
    );
    try std.testing.expectEqual(
        driven.summary.completed,
        probe.retires,
    );
    try std.testing.expectEqual(ProbeState.pending, probe.states[4]);
    try std.testing.expectEqualSlices(
        u8,
        &canonical.result_sha256,
        &driven.result_sha256,
    );
    try std.testing.expectEqualDeep(canonical.summary, driven.summary);
    try std.testing.expectEqualDeep(canonical.outcomes, driven.outcomes);
    try std.testing.expectEqualDeep(canonical.trace, driven.trace);
}

test "typed runner aborts permit cleans ownership and preserves output" {
    var profiles = testProfiles();
    var items = testItems(&profiles);
    const plan = testPlan(&profiles, &items);

    var baseline_storage: MaximumStorageV1 = .{};
    var destination: ResultV1 = undefined;
    try runPlanV1(
        plan,
        baseline_storage.interface(),
        &destination,
    );
    const before_plan_root = destination.plan_sha256;
    const before_result_root = destination.result_sha256;
    const before_summary = destination.summary;
    const before_outcomes = destination.outcomes;
    const before_trace = destination.trace;

    var probe: FailingDriverProbe = .{};
    var failed_storage: MaximumStorageV1 = .{};
    try std.testing.expectError(
        Error.DriverFailed,
        runPlanWithDriverV1(
            plan,
            failed_storage.interface(),
            probe.interface(),
            &destination,
        ),
    );
    try std.testing.expectEqual(@as(u64, 1), probe.cleanup_calls);
    try std.testing.expect(probe.cleanup_zero);
    try std.testing.expectEqualSlices(
        u8,
        &before_plan_root,
        &destination.plan_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &before_result_root,
        &destination.result_sha256,
    );
    try std.testing.expectEqualDeep(before_summary, destination.summary);
    try std.testing.expectEqual(before_outcomes.ptr, destination.outcomes.ptr);
    try std.testing.expectEqual(before_trace.ptr, destination.trace.ptr);
}

test "typed runner rejects a consumed but forged current event atomically" {
    var profiles = testProfiles();
    var items = testItems(&profiles);
    const plan = testPlan(&profiles, &items);

    var baseline_storage: MaximumStorageV1 = .{};
    var destination: ResultV1 = undefined;
    try runPlanV1(
        plan,
        baseline_storage.interface(),
        &destination,
    );
    const before_result_root = destination.result_sha256;
    const before_summary = destination.summary;

    var probe: DriverProbe = .{
        .forge_next_service_event = true,
    };
    var failed_storage: MaximumStorageV1 = .{};
    try std.testing.expectError(
        Error.DriverFailed,
        runPlanWithDriverV1(
            plan,
            failed_storage.interface(),
            probe.interface(),
            &destination,
        ),
    );
    try std.testing.expectEqualSlices(
        u8,
        &before_result_root,
        &destination.result_sha256,
    );
    try std.testing.expectEqualDeep(before_summary, destination.summary);
}
