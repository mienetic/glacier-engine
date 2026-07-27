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
pub const retirement_commit_facts_abi: u64 =
    0x474d_5246_0000_0001;
pub const completed_as_command_error: u32 = 1;

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
        @compileError("Metal test completion-facts ABI layout changed");
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

extern "C" fn glacier_metal_test_completion_facts_for_binding_v1(
    ctx: *metal.MetalContext,
    submission_binding: *const [32]u8,
    out: *CompletionFactsV1,
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
        plan.kind != completed_as_command_error or
        plan.reserved != 0 or
        plan.injected_error_code == 0)
        return Error.InvalidFacts;
}

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

pub fn armNextCompletedAsCommandErrorV1(
    backend: *engine.MetalBackend,
) Error!FaultPlanV1 {
    if (comptime !enabled) return Error.Unavailable;
    var plan: FaultPlanV1 = .{};
    const result =
        glacier_metal_test_arm_next_completed_as_command_error_v1(
            backend.ctx,
            &plan,
        );
    switch (result) {
        0 => {},
        1 => return Error.InvalidControl,
        2 => return Error.PlanAlreadyArmed,
        3 => return Error.PlanExhausted,
        else => return Error.InvalidControl,
    }
    try validateFaultPlanV1(plan);
    return plan;
}

pub fn completionFactsForBindingV1(
    backend: *engine.MetalBackend,
    submission_binding: [32]u8,
) Error!CompletionFactsV1 {
    if (comptime !enabled) return Error.Unavailable;
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
