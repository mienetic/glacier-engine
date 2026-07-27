//! Build-isolated native Metal fault control.
//!
//! Test artifacts may import this module, but its calls are compile-time
//! disabled unless the artifact links the separate
//! `GLACIER_METAL_TEST_FAULTS=1` shim. It is not exported by the runtime
//! module, installed headers, production shim, CLI, or package consumers.

const std = @import("std");
const engine = @import("engine");
const config = @import("config");

const metal = engine.metal_backend;

pub const enabled: bool = blk: {
    if (@hasDecl(config, "metal_test_faults"))
        break :blk config.metal_test_faults;
    break :blk false;
};

pub const fault_plan_abi: u64 = 0x474d_4650_0000_0001;
pub const completion_facts_abi: u64 =
    0x474d_4643_0000_0001;
pub const completion_facts_v2_abi: u64 =
    0x474d_4643_0000_0002;
pub const retirement_commit_facts_abi: u64 =
    0x474d_5246_0000_0001;
pub const completed_as_command_error: u32 = 1;
pub const real_commit_as_ambiguous: u32 = 2;
pub const completed_as_unknown: u32 = 3;
pub const completed_output_read_rejection: u32 = 4;

pub const Error = error{
    Unavailable,
    InvalidControl,
    PlanAlreadyArmed,
    PlanExhausted,
    FactsUnavailable,
    FactsAmbiguous,
    FactsPending,
    RetirementUnavailable,
    RetirementConflict,
    RetirementCommitFailureAlreadyArmed,
    RetirementCommitFailureUnavailable,
    CallbackHoldUnavailable,
    CallbackHoldTimeout,
    RegisteredWaiterUnavailable,
    RegisteredWaiterTimeout,
    InvalidFacts,
};

pub const FaultPlanV1 = extern struct {
    abi_version: u64 = 0,
    plan_generation: u64 = 0,
    kind: u32 = 0,
    reserved: u32 = 0,
    injected_error_code: i64 = 0,
};

pub const CompletionFactsV1 = extern struct {
    abi_version: u64 = 0,
    plan_generation: u64 = 0,
    kind: u32 = 0,
    fault_applied: u32 = 0,
    injected_error_code: i64 = 0,
    physical: metal.MetalAsyncCompletion = .{},
    published: metal.MetalAsyncCompletion = .{},
};

pub const CompletionFactsV2 = extern struct {
    abi_version: u64 = 0,
    plan_generation: u64 = 0,
    kind: u32 = 0,
    fault_applied: u32 = 0,
    injected_error_code: i64 = 0,
    physical: metal.MetalAsyncCompletion = .{},
    published: metal.MetalAsyncCompletion = .{},
    physical_submission: metal.MetalAsyncSubmission = .{},
    published_submission: metal.MetalAsyncSubmission = .{},
    commit_returned_normally: u32 = 0,
    commit_exception_observed: u32 = 0,
    submission_overlay_applied: u32 = 0,
    callback_snapshot_observed: u32 = 0,
    completion_overlay_applied: u32 = 0,
    output_read_rejection_applied: u32 = 0,
    output_read_rejection_count: u64 = 0,
};

pub const RetirementCommitFactsV1 = extern struct {
    abi_version: u64 = 0,
    commit_attempt_count: u64 = 0,
    injected_failure_count: u64 = 0,
    committed_retirement_count: u64 = 0,
    replay_count: u64 = 0,
    failure_armed: u32 = 0,
    reserved: u32 = 0,
};

comptime {
    if (@sizeOf(FaultPlanV1) != 32 or
        @offsetOf(FaultPlanV1, "injected_error_code") != 24)
        @compileError("Metal test fault-plan ABI layout changed");
    if (@sizeOf(CompletionFactsV1) != 320 or
        @offsetOf(CompletionFactsV1, "physical") != 32 or
        @offsetOf(CompletionFactsV1, "published") != 176)
        @compileError("Metal test completion-facts V1 ABI layout changed");
    if (@sizeOf(CompletionFactsV2) != 528 or
        @offsetOf(CompletionFactsV2, "physical") != 32 or
        @offsetOf(CompletionFactsV2, "published") != 176 or
        @offsetOf(
            CompletionFactsV2,
            "physical_submission",
        ) != 320 or
        @offsetOf(
            CompletionFactsV2,
            "commit_returned_normally",
        ) != 496 or
        @offsetOf(
            CompletionFactsV2,
            "output_read_rejection_count",
        ) != 520)
        @compileError("Metal test completion-facts V2 ABI layout changed");
    if (@sizeOf(RetirementCommitFactsV1) != 48 or
        @offsetOf(RetirementCommitFactsV1, "failure_armed") != 40)
        @compileError(
            "Metal test retirement-commit facts ABI layout changed",
        );
}

extern "C" fn glacier_metal_test_arm_next_completed_as_command_error_v1(
    ctx: *metal.MetalContext,
    out: *FaultPlanV1,
) c_int;
extern "C" fn glacier_metal_test_arm_next_real_commit_as_ambiguous_v1(
    ctx: *metal.MetalContext,
    out: *FaultPlanV1,
) c_int;
extern "C" fn glacier_metal_test_arm_next_completed_as_unknown_v1(
    ctx: *metal.MetalContext,
    out: *FaultPlanV1,
) c_int;
extern "C" fn glacier_metal_test_arm_next_completed_output_read_rejection_v1(
    ctx: *metal.MetalContext,
    out: *FaultPlanV1,
) c_int;

extern "C" fn glacier_metal_test_completion_facts_for_binding_v1(
    ctx: *metal.MetalContext,
    submission_binding: *const [32]u8,
    out: *CompletionFactsV1,
) c_int;
extern "C" fn glacier_metal_test_completion_facts_for_binding_v2(
    ctx: *metal.MetalContext,
    submission_binding: *const [32]u8,
    out: *CompletionFactsV2,
) c_int;

extern "C" fn glacier_metal_test_registered_dispatch_retirement_prepare(
    ctx: *metal.MetalContext,
    submission: *const metal.MetalAsyncSubmission,
    permit: *metal.MetalRegisteredDispatchRetirementPermit,
) c_int;
extern "C" fn glacier_metal_test_arm_next_completion_callback_hold(
    ctx: *metal.MetalContext,
) c_int;
extern "C" fn glacier_metal_test_wait_for_held_completion_callback(
    ctx: *metal.MetalContext,
) c_int;
extern "C" fn glacier_metal_test_wait_for_registered_dispatch_waiter(
    ctx: *metal.MetalContext,
) c_int;
extern "C" fn glacier_metal_test_release_held_completion_callback(
    ctx: *metal.MetalContext,
) c_int;
extern "C" fn glacier_metal_test_arm_next_dispatch_retirement_commit_failure(
    ctx: *metal.MetalContext,
) c_int;
extern "C" fn glacier_metal_test_dispatch_retirement_commit_facts(
    ctx: *metal.MetalContext,
    out: *RetirementCommitFactsV1,
) c_int;

pub fn validateFaultPlanV1(plan: FaultPlanV1) Error!void {
    if (plan.abi_version != fault_plan_abi or
        plan.plan_generation == 0 or
        plan.plan_generation == std.math.maxInt(u64) or
        plan.reserved != 0)
        return Error.InvalidFacts;
    switch (plan.kind) {
        completed_as_command_error => if (plan.injected_error_code == 0)
            return Error.InvalidFacts,
        real_commit_as_ambiguous,
        completed_as_unknown,
        completed_output_read_rejection,
        => if (plan.injected_error_code != 0)
            return Error.InvalidFacts,
        else => return Error.InvalidFacts,
    }
}

fn completionIsAllZero(
    completion: metal.MetalAsyncCompletion,
) bool {
    return std.mem.allEqual(
        u8,
        std.mem.asBytes(&completion),
        0,
    );
}

fn exactPhysicalSuccess(
    completion: metal.MetalAsyncCompletion,
) bool {
    metal.validateMetalAsyncCompletion(
        completion,
    ) catch return false;
    return completion.state == .completed and
        completion.command_status ==
            metal.completed_command_buffer_status and
        completion.error_domain_kind == .none and
        completion.error_present == 0 and
        completion.error_code == 0 and
        completion.callback_fault == 0;
}

/// Original completion-only fault-facts ABI. V1 remains fixed at 320 bytes
/// and intentionally accepts only the completed-as-command-error campaign.
pub fn validateCompletionFactsV1(
    facts: CompletionFactsV1,
    expected_binding: [32]u8,
) Error!void {
    if (facts.abi_version != completion_facts_abi or
        facts.plan_generation == 0 or
        facts.plan_generation == std.math.maxInt(u64) or
        facts.kind != completed_as_command_error or
        facts.fault_applied > 1 or
        facts.injected_error_code == 0)
        return Error.InvalidFacts;
    metal.validateMetalAsyncCompletion(
        facts.physical,
    ) catch return Error.InvalidFacts;
    metal.validateMetalAsyncCompletion(
        facts.published,
    ) catch return Error.InvalidFacts;
    if (!std.meta.eql(
        facts.physical.token,
        facts.published.token,
    ) or
        !std.mem.eql(
            u8,
            &facts.physical.submission_binding,
            &expected_binding,
        ) or
        !std.mem.eql(
            u8,
            &facts.published.submission_binding,
            &expected_binding,
        ))
        return Error.InvalidFacts;

    if (facts.fault_applied == 0) {
        if (!std.meta.eql(
            facts.physical,
            facts.published,
        ))
            return Error.InvalidFacts;
        return;
    }

    if (facts.physical.state != .completed or
        facts.physical.command_status !=
            metal.completed_command_buffer_status or
        facts.physical.error_domain_kind != .none or
        facts.physical.error_present != 0 or
        facts.physical.callback_fault != 0 or
        facts.published.state != .@"error" or
        facts.published.command_status !=
            metal.error_command_buffer_status or
        facts.published.error_domain_kind !=
            .command_buffer or
        facts.published.error_present != 1 or
        facts.published.callback_fault != 0 or
        facts.published.error_code !=
            facts.injected_error_code or
        facts.physical.current_allocated_before !=
            facts.published.current_allocated_before or
        facts.physical.current_allocated_after !=
            facts.published.current_allocated_after or
        @as(u64, @bitCast(facts.physical.gpu_start_time)) !=
            @as(u64, @bitCast(
                facts.published.gpu_start_time,
            )) or
        @as(u64, @bitCast(facts.physical.gpu_end_time)) !=
            @as(u64, @bitCast(
                facts.published.gpu_end_time,
            )))
        return Error.InvalidFacts;
}

pub fn validateCompletionFactsV2(
    facts: CompletionFactsV2,
    expected_binding: [32]u8,
) Error!void {
    if (facts.abi_version != completion_facts_v2_abi or
        facts.plan_generation == 0 or
        facts.plan_generation == std.math.maxInt(u64) or
        facts.fault_applied > 1 or
        facts.commit_returned_normally > 1 or
        facts.commit_exception_observed > 1 or
        facts.submission_overlay_applied > 1 or
        facts.callback_snapshot_observed > 1 or
        facts.completion_overlay_applied > 1 or
        facts.output_read_rejection_applied > 1)
        return Error.InvalidFacts;
    validateFaultPlanV1(.{
        .abi_version = fault_plan_abi,
        .plan_generation = facts.plan_generation,
        .kind = facts.kind,
        .injected_error_code = facts.injected_error_code,
    }) catch return Error.InvalidFacts;
    metal.validateMetalAsyncSubmission(
        facts.physical_submission,
    ) catch return Error.InvalidFacts;
    metal.validateMetalAsyncSubmission(
        facts.published_submission,
    ) catch return Error.InvalidFacts;
    if (facts.commit_returned_normally +
        facts.commit_exception_observed != 1)
        return Error.InvalidFacts;
    if ((facts.commit_returned_normally == 1 and
        facts.physical_submission.disposition != .submitted) or
        (facts.commit_exception_observed == 1 and
            facts.physical_submission.disposition !=
                .submitted_or_ambiguous) or
        !std.meta.eql(
            facts.physical_submission.token,
            facts.published_submission.token,
        ) or
        !std.mem.eql(
            u8,
            &facts.physical_submission.submission_binding,
            &expected_binding,
        ) or
        !std.mem.eql(
            u8,
            &facts.published_submission.submission_binding,
            &expected_binding,
        ))
        return Error.InvalidFacts;

    const expected_submission_overlay: u32 =
        if (facts.kind == real_commit_as_ambiguous and
        facts.commit_returned_normally == 1 and
        facts.physical_submission.disposition == .submitted)
            1
        else
            0;
    if (facts.submission_overlay_applied !=
        expected_submission_overlay)
        return Error.InvalidFacts;
    if (facts.submission_overlay_applied == 1) {
        var expected_published_submission =
            facts.physical_submission;
        expected_published_submission.disposition =
            .submitted_or_ambiguous;
        if (facts.kind != real_commit_as_ambiguous or
            facts.commit_returned_normally != 1 or
            facts.physical_submission.disposition != .submitted or
            !std.meta.eql(
                facts.published_submission,
                expected_published_submission,
            ))
            return Error.InvalidFacts;
    } else if (!std.meta.eql(
        facts.physical_submission,
        facts.published_submission,
    )) return Error.InvalidFacts;

    if (facts.callback_snapshot_observed == 0) {
        if (!completionIsAllZero(facts.physical) or
            !completionIsAllZero(facts.published) or
            facts.completion_overlay_applied != 0 or
            facts.output_read_rejection_applied != 0 or
            facts.output_read_rejection_count != 0 or
            facts.fault_applied !=
                facts.submission_overlay_applied)
            return Error.InvalidFacts;
        return;
    }

    metal.validateMetalAsyncCompletion(
        facts.physical,
    ) catch return Error.InvalidFacts;
    metal.validateMetalAsyncCompletion(
        facts.published,
    ) catch return Error.InvalidFacts;
    if (!std.meta.eql(
        facts.physical.token,
        facts.published.token,
    ) or
        !std.mem.eql(
            u8,
            &facts.physical.submission_binding,
            &expected_binding,
        ) or
        !std.mem.eql(
            u8,
            &facts.published.submission_binding,
            &expected_binding,
        ) or
        !std.meta.eql(
            facts.physical.token,
            facts.physical_submission.token,
        ) or
        !std.meta.eql(
            facts.published.token,
            facts.published_submission.token,
        ))
        return Error.InvalidFacts;

    const physical_success =
        exactPhysicalSuccess(facts.physical);
    const expected_completion_overlay: u32 =
        if ((facts.kind == completed_as_command_error or
            facts.kind == completed_as_unknown) and
        physical_success)
            1
        else
            0;
    if (facts.completion_overlay_applied !=
        expected_completion_overlay)
        return Error.InvalidFacts;
    switch (facts.kind) {
        completed_as_command_error => {
            if (facts.completion_overlay_applied == 0) {
                if (!std.meta.eql(
                    facts.physical,
                    facts.published,
                ))
                    return Error.InvalidFacts;
            } else {
                var expected_published = facts.physical;
                expected_published.state = .@"error";
                expected_published.command_status =
                    metal.error_command_buffer_status;
                expected_published.error_code =
                    facts.injected_error_code;
                expected_published.error_domain_kind =
                    .command_buffer;
                expected_published.error_present = 1;
                expected_published.callback_fault = 0;
                if (!physical_success or
                    !std.meta.eql(
                        facts.published,
                        expected_published,
                    ))
                    return Error.InvalidFacts;
            }
        },
        real_commit_as_ambiguous => {
            if (facts.completion_overlay_applied != 0 or
                !std.meta.eql(
                    facts.physical,
                    facts.published,
                ))
                return Error.InvalidFacts;
        },
        completed_as_unknown => {
            if (facts.completion_overlay_applied == 0) {
                if (!std.meta.eql(
                    facts.physical,
                    facts.published,
                ))
                    return Error.InvalidFacts;
            } else {
                var expected_published = facts.physical;
                expected_published.state = .unknown;
                expected_published.callback_fault = 1;
                if (!physical_success or
                    !std.meta.eql(
                        facts.published,
                        expected_published,
                    ))
                    return Error.InvalidFacts;
            }
        },
        completed_output_read_rejection => {
            if (facts.completion_overlay_applied != 0 or
                !std.meta.eql(
                    facts.physical,
                    facts.published,
                ))
                return Error.InvalidFacts;
            if (facts.output_read_rejection_applied == 1) {
                if (facts.output_read_rejection_count == 0 or
                    !physical_success)
                    return Error.InvalidFacts;
            } else if (facts.output_read_rejection_count != 0) {
                return Error.InvalidFacts;
            }
        },
        else => return Error.InvalidFacts,
    }

    if (facts.kind !=
        completed_output_read_rejection and
        (facts.output_read_rejection_applied != 0 or
            facts.output_read_rejection_count != 0))
        return Error.InvalidFacts;
    const expected_fault_applied: u32 =
        if (facts.submission_overlay_applied == 1 or
        facts.completion_overlay_applied == 1 or
        facts.output_read_rejection_applied == 1)
            1
        else
            0;
    if (facts.fault_applied != expected_fault_applied)
        return Error.InvalidFacts;
}

fn armNextFaultPlanV1(
    backend: *engine.MetalBackend,
    expected_kind: u32,
    comptime arm_fn: anytype,
) Error!FaultPlanV1 {
    if (comptime !enabled) return Error.Unavailable;
    backend.allocation_mutex.lock();
    defer backend.allocation_mutex.unlock();
    var plan: FaultPlanV1 = .{};
    const result = arm_fn(backend.ctx, &plan);
    switch (result) {
        0 => {},
        1 => return Error.InvalidControl,
        2 => return Error.PlanAlreadyArmed,
        3 => return Error.PlanExhausted,
        else => return Error.InvalidControl,
    }
    try validateFaultPlanV1(plan);
    if (plan.kind != expected_kind)
        return Error.InvalidFacts;
    return plan;
}

pub fn armNextCompletedAsCommandErrorV1(
    backend: *engine.MetalBackend,
) Error!FaultPlanV1 {
    return armNextFaultPlanV1(
        backend,
        completed_as_command_error,
        glacier_metal_test_arm_next_completed_as_command_error_v1,
    );
}

pub fn armNextRealCommitAsAmbiguousV1(
    backend: *engine.MetalBackend,
) Error!FaultPlanV1 {
    return armNextFaultPlanV1(
        backend,
        real_commit_as_ambiguous,
        glacier_metal_test_arm_next_real_commit_as_ambiguous_v1,
    );
}

pub fn armNextCompletedAsUnknownV1(
    backend: *engine.MetalBackend,
) Error!FaultPlanV1 {
    return armNextFaultPlanV1(
        backend,
        completed_as_unknown,
        glacier_metal_test_arm_next_completed_as_unknown_v1,
    );
}

pub fn armNextCompletedOutputReadRejectionV1(
    backend: *engine.MetalBackend,
) Error!FaultPlanV1 {
    return armNextFaultPlanV1(
        backend,
        completed_output_read_rejection,
        glacier_metal_test_arm_next_completed_output_read_rejection_v1,
    );
}

pub fn completionFactsForBindingV1(
    backend: *engine.MetalBackend,
    submission_binding: [32]u8,
) Error!CompletionFactsV1 {
    if (comptime !enabled) return Error.Unavailable;
    backend.allocation_mutex.lock();
    defer backend.allocation_mutex.unlock();
    var facts: CompletionFactsV1 = .{};
    const result =
        glacier_metal_test_completion_facts_for_binding_v1(
            backend.ctx,
            &submission_binding,
            &facts,
        );
    switch (result) {
        0 => {},
        1 => return Error.InvalidControl,
        2 => return Error.FactsUnavailable,
        3 => return Error.FactsAmbiguous,
        4 => return Error.FactsPending,
        else => return Error.InvalidControl,
    }
    try validateCompletionFactsV1(
        facts,
        submission_binding,
    );
    return facts;
}

pub fn completionFactsForBindingV2(
    backend: *engine.MetalBackend,
    submission_binding: [32]u8,
) Error!CompletionFactsV2 {
    if (comptime !enabled) return Error.Unavailable;
    backend.allocation_mutex.lock();
    defer backend.allocation_mutex.unlock();
    var facts: CompletionFactsV2 = .{};
    const result =
        glacier_metal_test_completion_facts_for_binding_v2(
            backend.ctx,
            &submission_binding,
            &facts,
        );
    switch (result) {
        0 => {},
        1 => return Error.InvalidControl,
        2 => return Error.FactsUnavailable,
        3 => return Error.FactsAmbiguous,
        4 => return Error.FactsPending,
        else => return Error.InvalidControl,
    }
    try validateCompletionFactsV2(
        facts,
        submission_binding,
    );
    return facts;
}

/// Test-build-only authority for exercising the callback-safe retirement
/// protocol without manufacturing a production lifecycle event. The
/// production shim does not export the referenced symbol.
pub fn prepareRegisteredDispatchRetirementForTest(
    backend: *engine.MetalBackend,
    submission: metal.MetalAsyncSubmission,
) Error!metal.MetalRegisteredDispatchRetirementPermit {
    if (comptime !enabled) return Error.Unavailable;
    metal.validateMetalAsyncSubmission(
        submission,
    ) catch return Error.InvalidControl;

    backend.allocation_mutex.lock();
    defer backend.allocation_mutex.unlock();
    var permit =
        std.mem.zeroes(
            metal.MetalRegisteredDispatchRetirementPermit,
        );
    permit.abi_version = metal.dispatch_retirement_permit_abi;
    const result =
        glacier_metal_test_registered_dispatch_retirement_prepare(
            backend.ctx,
            &submission,
            &permit,
        );
    switch (result) {
        0 => {},
        1 => return Error.InvalidControl,
        2 => return Error.RetirementUnavailable,
        3 => return Error.RetirementConflict,
        4 => return Error.RetirementUnavailable,
        else => return Error.InvalidControl,
    }
    metal.validateMetalRegisteredDispatchRetirementPermitForSubmission(
        permit,
        submission,
    ) catch return Error.InvalidFacts;
    if (permit.authorization_kind != .synthetic_test)
        return Error.InvalidFacts;
    return permit;
}

pub fn armNextCompletionCallbackHold(
    backend: *engine.MetalBackend,
) Error!void {
    if (comptime !enabled) return Error.Unavailable;
    return switch (glacier_metal_test_arm_next_completion_callback_hold(
        backend.ctx,
    )) {
        0 => {},
        2 => Error.PlanAlreadyArmed,
        else => Error.InvalidControl,
    };
}

pub fn waitForHeldCompletionCallback(
    backend: *engine.MetalBackend,
) Error!void {
    if (comptime !enabled) return Error.Unavailable;
    return switch (glacier_metal_test_wait_for_held_completion_callback(
        backend.ctx,
    )) {
        0 => {},
        2 => Error.CallbackHoldUnavailable,
        3 => Error.CallbackHoldTimeout,
        else => Error.InvalidControl,
    };
}

pub fn releaseHeldCompletionCallback(
    backend: *engine.MetalBackend,
) Error!void {
    if (comptime !enabled) return Error.Unavailable;
    return switch (glacier_metal_test_release_held_completion_callback(
        backend.ctx,
    )) {
        0 => {},
        2 => Error.CallbackHoldUnavailable,
        3 => Error.CallbackHoldTimeout,
        else => Error.InvalidControl,
    };
}

pub fn waitForRegisteredDispatchWaiter(
    backend: *engine.MetalBackend,
) Error!void {
    if (comptime !enabled) return Error.Unavailable;
    return switch (glacier_metal_test_wait_for_registered_dispatch_waiter(
        backend.ctx,
    )) {
        0 => {},
        2 => Error.RegisteredWaiterUnavailable,
        3 => Error.RegisteredWaiterTimeout,
        else => Error.InvalidControl,
    };
}

/// Arm exactly one failure at the final pre-unlink native retirement commit
/// boundary. The command record, four command-held allocation references, and
/// callback-detached permit remain live and exact for a retry.
pub fn armNextDispatchRetirementCommitFailure(
    backend: *engine.MetalBackend,
) Error!void {
    if (comptime !enabled) return Error.Unavailable;
    return switch (glacier_metal_test_arm_next_dispatch_retirement_commit_failure(
        backend.ctx,
    )) {
        0 => {},
        2 => Error.RetirementCommitFailureAlreadyArmed,
        3 => Error.RetirementCommitFailureUnavailable,
        else => Error.InvalidControl,
    };
}

pub fn dispatchRetirementCommitFacts(
    backend: *engine.MetalBackend,
) Error!RetirementCommitFactsV1 {
    if (comptime !enabled) return Error.Unavailable;
    var facts: RetirementCommitFactsV1 = .{};
    if (glacier_metal_test_dispatch_retirement_commit_facts(
        backend.ctx,
        &facts,
    ) != 0)
        return Error.InvalidControl;
    if (facts.abi_version != retirement_commit_facts_abi or
        facts.failure_armed > 1 or
        facts.reserved != 0 or
        facts.injected_failure_count > facts.commit_attempt_count or
        facts.committed_retirement_count > facts.commit_attempt_count or
        facts.replay_count > facts.commit_attempt_count)
        return Error.InvalidFacts;
    return facts;
}
