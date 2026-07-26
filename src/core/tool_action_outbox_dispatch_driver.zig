//! Trusted ordering bridge from a durable ActionOutbox to an adapter.
//!
//! The driver commits `dispatch_intent` through `StoreV1` before invoking the
//! adapter. Callback errors and invalid evidence therefore leave a recoverable
//! uncertain action. Direct responses can acknowledge their exact attempt; a
//! separate status call can return an action to ready only through validated
//! `not_applied_fenced` evidence.

const std = @import("std");
const action = @import("tool_action_contract.zig");
const outbox = @import("tool_action_outbox_record.zig");
const file = @import("tool_action_outbox_file.zig");
const adapter_contract =
    @import("tool_action_outbox_adapter_contract.zig");

pub const Digest = outbox.Digest;
pub const zero_digest = outbox.zero_digest;

pub const Error =
    file.Error ||
    adapter_contract.RuntimeError ||
    error{
        ActionNotFound,
        ActionNotReady,
        ActionNotUncertain,
    };

pub const DispatchOutcomeV1 = struct {
    request: adapter_contract.DispatchRequestV1,
    evidence: adapter_contract.DispatchEvidenceV1,
    record: outbox.RecordV1,
    receipt: file.DurableAppendReceiptV1,
};

pub const ReconcileOutcomeV1 = struct {
    request: adapter_contract.StatusRequestV1,
    evidence: adapter_contract.StatusEvidenceV1,
    transition: ?adapter_contract.TransitionSpecV1,
    record: ?outbox.RecordV1,
    receipt: ?file.DurableAppendReceiptV1,
};

/// Commits an exact next-generation intent before the first adapter callback.
/// If the callback or final append fails, no retry authority is inferred.
pub fn dispatchReadyV1(
    store: *file.StoreV1,
    adapter: adapter_contract.AdapterV1,
    action_sha256: Digest,
) Error!DispatchOutcomeV1 {
    try adapter_contract.validateAdapterV1(adapter);
    try adapter_contract.validateDescriptorHeaderBindingV1(
        adapter.descriptor,
        store.header,
    );
    const states_before = try store.states();
    const before = findStateV1(
        states_before,
        action_sha256,
    ) orelse return Error.ActionNotFound;
    if (before.phase != .ready) return Error.ActionNotReady;
    // Protect one future reconciliation slot for every already-uncertain
    // action, then require intent, immediate observation, and one slot for the
    // newly uncertain action. Driver-only admission therefore cannot wedge an
    // earlier action by overcommitting the bounded journal.
    try requireUncertainReserveV1(store, states_before, 3);

    const attempt_generation = std.math.add(
        u64,
        before.attempt_generation,
        1,
    ) catch return Error.ArithmeticOverflow;
    const intent = try outbox.makeTransitionRecordV1(
        store.header,
        nextSequence(store),
        store.final_chain_sha256,
        before,
        .dispatch_intent,
        attempt_generation,
        zero_digest,
        zero_digest,
    );

    // This durable append is the linearization point granting callback
    // invocation authority. No adapter code runs before it returns.
    _ = try store.appendRecord(intent);
    const request = try adapter_contract.makeDispatchRequestV1(
        adapter.descriptor,
        store.header,
        intent,
    );
    const evidence = try adapter_contract.dispatchV1(
        adapter,
        request,
    );
    const transition =
        try adapter_contract.transitionFromDispatchV1(
            adapter.descriptor,
            request,
            evidence,
        );
    const current = findStateV1(
        try store.states(),
        action_sha256,
    ) orelse return Error.ActionNotFound;
    if (current.phase != .uncertain)
        return Error.ActionNotUncertain;
    const record = try makeTransitionRecordV1(
        store,
        current,
        transition,
    );
    const receipt = try store.appendRecord(record);
    return .{
        .request = request,
        .evidence = evidence,
        .record = record,
        .receipt = receipt,
    };
}

/// Performs a distinct authoritative lookup for one uncertain action.
/// Pending and unknown evidence are returned to the caller without appending a
/// duplicate ambiguity record. Only a fenced negative maps back to ready.
pub fn reconcileUncertainV1(
    store: *file.StoreV1,
    adapter: adapter_contract.AdapterV1,
    action_sha256: Digest,
    query_ordinal: u64,
) Error!ReconcileOutcomeV1 {
    try adapter_contract.validateAdapterV1(adapter);
    try adapter_contract.validateDescriptorHeaderBindingV1(
        adapter.descriptor,
        store.header,
    );
    const states_before = try store.states();
    const current = findStateV1(
        states_before,
        action_sha256,
    ) orelse return Error.ActionNotFound;
    if (current.phase != .uncertain)
        return Error.ActionNotUncertain;
    // Status may atomically install a remote generation fence. Preserve one
    // local transition slot for every uncertain action before any callback;
    // resolving one action consumes one slot and removes one obligation.
    try requireUncertainReserveV1(store, states_before, 0);
    const request = try adapter_contract.makeStatusRequestV1(
        adapter.descriptor,
        store.header,
        current,
        query_ordinal,
    );
    const evidence = try adapter_contract.statusV1(
        adapter,
        request,
    );
    const transition =
        try adapter_contract.transitionFromStatusV1(
            adapter.descriptor,
            request,
            evidence,
        );
    if (transition == null) {
        return .{
            .request = request,
            .evidence = evidence,
            .transition = null,
            .record = null,
            .receipt = null,
        };
    }

    const record = try makeTransitionRecordV1(
        store,
        current,
        transition.?,
    );
    const receipt = try store.appendRecord(record);
    return .{
        .request = request,
        .evidence = evidence,
        .transition = transition,
        .record = record,
        .receipt = receipt,
    };
}

pub fn findStateV1(
    states: []const outbox.ActionStateV1,
    action_sha256: Digest,
) ?outbox.ActionStateV1 {
    for (states) |state| {
        if (state.occupied and std.mem.eql(
            u8,
            &state.identity.action_sha256,
            &action_sha256,
        ))
            return state;
    }
    return null;
}

fn requireRecordReserveV1(
    store: *const file.StoreV1,
    required_records: usize,
) Error!void {
    const maximum_records: usize =
        @intCast(store.header.maximum_records);
    if (required_records == 0 or
        store.record_count > maximum_records or
        required_records > maximum_records - store.record_count)
        return file.Error.CapacityExceeded;
}

fn requireUncertainReserveV1(
    store: *const file.StoreV1,
    states: []const outbox.ActionStateV1,
    additional_records: usize,
) Error!void {
    const uncertain_count = countUncertainV1(states);
    const required_records = std.math.add(
        usize,
        uncertain_count,
        additional_records,
    ) catch return Error.ArithmeticOverflow;
    try requireRecordReserveV1(store, required_records);
}

fn countUncertainV1(
    states: []const outbox.ActionStateV1,
) usize {
    var uncertain_count: usize = 0;
    for (states) |state| {
        if (state.occupied and state.phase == .uncertain)
            uncertain_count += 1;
    }
    return uncertain_count;
}

fn makeTransitionRecordV1(
    store: *const file.StoreV1,
    state: outbox.ActionStateV1,
    transition: adapter_contract.TransitionSpecV1,
) Error!outbox.RecordV1 {
    return outbox.makeTransitionRecordV1(
        store.header,
        nextSequence(store),
        store.final_chain_sha256,
        state,
        transition.kind,
        transition.attempt_generation,
        transition.observation_sha256,
        transition.result_sha256,
    );
}

fn nextSequence(store: *const file.StoreV1) u64 {
    return @as(u64, @intCast(store.record_count)) + 1;
}

fn digest(value: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}

const TestBuffers = struct {
    journal: [8192]u8 = [_]u8{0} ** 8192,
    records: [8]outbox.RecordV1 =
        [_]outbox.RecordV1{.{}} ** 8,
    states: [2]outbox.ActionStateV1 =
        [_]outbox.ActionStateV1{.{}} ** 2,
};

const TestActionV1 = struct {
    header: outbox.HeaderV1,
    identity: outbox.ActionIdentityV1,
};

fn testIdentityV1(
    header: outbox.HeaderV1,
    action_ordinal: u64,
) !outbox.ActionIdentityV1 {
    const first = action_ordinal == 1;
    const tool_descriptor = try action.makeDescriptorV1(
        4,
        digest("tool namespace"),
        digest("argument schema"),
        digest("result schema"),
        digest("implementation"),
    );
    const arguments = try action.makeBoundedAddArgumentsV1(
        if (first) 88 else 89,
        2,
    );
    const proposal = try action.makeActionProposalV1(
        41,
        action_ordinal,
        digest(if (first) "agent request" else "second agent request"),
        tool_descriptor,
        arguments,
        digest(if (first) "idempotency" else "second idempotency"),
    );
    const policy = try action.makePolicyV1(
        2,
        41,
        true,
        8,
        -10,
        10,
        tool_descriptor,
        digest("policy"),
    );
    const authorization = try action.authorizeBoundedAddV1(
        proposal,
        tool_descriptor,
        arguments,
        policy,
        1,
    );
    return outbox.makeActionIdentityV1(
        header,
        .primary,
        zero_digest,
        tool_descriptor,
        arguments,
        proposal,
        policy,
        authorization,
        digest(if (first) "service event" else "second service event"),
        digest(if (first) "payload locator" else "second payload locator"),
        32,
        digest(if (first) "payload" else "second payload"),
    );
}

fn testActionV1(
    descriptor: adapter_contract.DescriptorV1,
    maximum_records: u64,
) !TestActionV1 {
    const header = try outbox.makeHeaderV1(
        17,
        23,
        41,
        2,
        maximum_records,
        4096,
        descriptor.descriptor_sha256,
        digest("payload store"),
        digest("header challenge"),
    );
    return .{
        .header = header,
        .identity = try testIdentityV1(header, 1),
    };
}

const TestAdapterContext = struct {
    descriptor: adapter_contract.DescriptorV1,
    store: *file.StoreV1,
    dispatch_calls: u64 = 0,
    status_calls: u64 = 0,
    dispatch_disposition: adapter_contract.DispatchDispositionV1 = .succeeded,
    status_disposition: adapter_contract.StatusDispositionV1 =
        .not_applied_fenced,

    fn adapter(self: *TestAdapterContext) adapter_contract.AdapterV1 {
        return .{
            .adapter_context = self,
            .descriptor = self.descriptor,
            .dispatch_fn = dispatchCallback,
            .status_fn = statusCallback,
        };
    }
};

fn dispatchCallback(
    opaque_context: *anyopaque,
    request: adapter_contract.DispatchRequestV1,
) adapter_contract.CallbackError!adapter_contract.DispatchEvidenceV1 {
    const context: *TestAdapterContext =
        @ptrCast(@alignCast(opaque_context));
    context.dispatch_calls += 1;
    const state = findStateV1(
        context.store.states() catch
            return error.RequestRejected,
        request.action_sha256,
    ) orelse return error.RequestRejected;
    if (state.phase != .uncertain or
        state.attempt_generation != request.attempt_generation)
        return error.RequestRejected;
    const result_sha256 =
        if (context.dispatch_disposition == .succeeded or
        context.dispatch_disposition == .terminal_failure)
            digest("adapter result")
        else
            zero_digest;
    return adapter_contract.makeDispatchEvidenceV1(
        context.descriptor,
        request,
        context.dispatch_calls,
        context.dispatch_disposition,
        digest("dispatch service event"),
        result_sha256,
    ) catch return error.RequestRejected;
}

fn statusCallback(
    opaque_context: *anyopaque,
    request: adapter_contract.StatusRequestV1,
) adapter_contract.CallbackError!adapter_contract.StatusEvidenceV1 {
    const context: *TestAdapterContext =
        @ptrCast(@alignCast(opaque_context));
    context.status_calls += 1;
    const result_sha256 =
        if (context.status_disposition == .succeeded or
        context.status_disposition == .failed)
            digest("status result")
        else
            zero_digest;
    const fence =
        if (context.status_disposition == .not_applied_fenced)
            request.attempt_generation
        else
            0;
    return adapter_contract.makeStatusEvidenceV1(
        context.descriptor,
        request,
        context.status_calls,
        context.status_disposition,
        fence,
        digest("status service event"),
        result_sha256,
    ) catch return error.RequestRejected;
}

const FaultContext = struct {
    armed: bool = false,
    phase: file.IoPhaseV1 = .body_write,

    fn observer(self: *FaultContext) file.PhaseObserverV1 {
        return .{
            .context = self,
            .after_phase_fn = observe,
        };
    }
};

fn observe(
    opaque_context: *anyopaque,
    phase: file.IoPhaseV1,
) file.Error!void {
    const context: *FaultContext =
        @ptrCast(@alignCast(opaque_context));
    if (context.armed and phase == context.phase)
        return file.Error.InjectedFault;
}

test "driver durably commits intent before invoking adapter" {
    if (comptime !@import("platform_capabilities.zig")
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const descriptor = try adapter_contract.makeDescriptorV1(
        19,
        3,
        digest("authority"),
        digest("request schema"),
        digest("result schema"),
    );
    const fixture = try testActionV1(descriptor, 8);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffers: TestBuffers = .{};
    var store = try file.StoreV1.create(
        temp.dir,
        "driver.outbox",
        fixture.header,
        .{},
        &buffers.journal,
        &buffers.records,
        &buffers.states,
    );
    defer store.close();
    _ = try store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            fixture.header,
            1,
            fixture.header.header_sha256,
            fixture.identity,
        ),
    );
    var context: TestAdapterContext = .{
        .descriptor = descriptor,
        .store = &store,
    };
    const outcome = try dispatchReadyV1(
        &store,
        context.adapter(),
        fixture.identity.action_sha256,
    );
    try std.testing.expectEqual(@as(u64, 1), context.dispatch_calls);
    try std.testing.expectEqual(
        outbox.EventKindV1.acknowledged_success,
        outcome.record.kind,
    );
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.succeeded,
        (try store.states())[0].phase,
    );
}

test "intent append fault prevents every adapter call" {
    if (comptime !@import("platform_capabilities.zig")
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const descriptor = try adapter_contract.makeDescriptorV1(
        19,
        3,
        digest("authority"),
        digest("request schema"),
        digest("result schema"),
    );
    const fixture = try testActionV1(descriptor, 8);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffers: TestBuffers = .{};
    var store = try file.StoreV1.create(
        temp.dir,
        "fault.outbox",
        fixture.header,
        .{},
        &buffers.journal,
        &buffers.records,
        &buffers.states,
    );
    defer store.close();
    _ = try store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            fixture.header,
            1,
            fixture.header.header_sha256,
            fixture.identity,
        ),
    );
    var fault: FaultContext = .{ .armed = true };
    store.observer = fault.observer();
    var context: TestAdapterContext = .{
        .descriptor = descriptor,
        .store = &store,
    };
    try std.testing.expectError(
        file.Error.InjectedFault,
        dispatchReadyV1(
            &store,
            context.adapter(),
            fixture.identity.action_sha256,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), context.dispatch_calls);
}

test "pending status leaves uncertain and fenced status alone returns ready" {
    if (comptime !@import("platform_capabilities.zig")
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const descriptor = try adapter_contract.makeDescriptorV1(
        19,
        3,
        digest("authority"),
        digest("request schema"),
        digest("result schema"),
    );
    const fixture = try testActionV1(descriptor, 8);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var buffers: TestBuffers = .{};
    var store = try file.StoreV1.create(
        temp.dir,
        "status.outbox",
        fixture.header,
        .{},
        &buffers.journal,
        &buffers.records,
        &buffers.states,
    );
    defer store.close();
    _ = try store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            fixture.header,
            1,
            fixture.header.header_sha256,
            fixture.identity,
        ),
    );
    const ready = (try store.states())[0];
    _ = try store.appendRecord(
        try outbox.makeTransitionRecordV1(
            fixture.header,
            2,
            store.final_chain_sha256,
            ready,
            .dispatch_intent,
            1,
            zero_digest,
            zero_digest,
        ),
    );
    var context: TestAdapterContext = .{
        .descriptor = descriptor,
        .store = &store,
        .status_disposition = .pending,
    };
    const pending = try reconcileUncertainV1(
        &store,
        context.adapter(),
        fixture.identity.action_sha256,
        1,
    );
    try std.testing.expect(pending.record == null);
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.uncertain,
        (try store.states())[0].phase,
    );
    context.status_disposition = .not_applied_fenced;
    const fenced = try reconcileUncertainV1(
        &store,
        context.adapter(),
        fixture.identity.action_sha256,
        2,
    );
    try std.testing.expectEqual(
        outbox.EventKindV1.reconciled_not_applied,
        fenced.record.?.kind,
    );
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.ready,
        (try store.states())[0].phase,
    );
}

test "record reserve fails before dispatch or fence callback authority" {
    if (comptime !@import("platform_capabilities.zig")
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const descriptor = try adapter_contract.makeDescriptorV1(
        19,
        3,
        digest("authority"),
        digest("request schema"),
        digest("result schema"),
    );
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    // Two free records cannot safely cover intent, possible ambiguity, and a
    // later reconciliation, so dispatch must not invoke the adapter.
    const dispatch_fixture = try testActionV1(descriptor, 3);
    var dispatch_buffers: TestBuffers = .{};
    var dispatch_store = try file.StoreV1.create(
        temporary.dir,
        "dispatch-capacity.outbox",
        dispatch_fixture.header,
        .{},
        &dispatch_buffers.journal,
        &dispatch_buffers.records,
        &dispatch_buffers.states,
    );
    defer dispatch_store.close();
    _ = try dispatch_store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            dispatch_fixture.header,
            1,
            dispatch_fixture.header.header_sha256,
            dispatch_fixture.identity,
        ),
    );
    var dispatch_context: TestAdapterContext = .{
        .descriptor = descriptor,
        .store = &dispatch_store,
    };
    try std.testing.expectError(
        file.Error.CapacityExceeded,
        dispatchReadyV1(
            &dispatch_store,
            dispatch_context.adapter(),
            dispatch_fixture.identity.action_sha256,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        dispatch_context.dispatch_calls,
    );
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.ready,
        (try dispatch_store.states())[0].phase,
    );

    // A full uncertain journal cannot call status because a successful
    // remote fence could not be represented locally.
    const status_fixture = try testActionV1(descriptor, 2);
    var status_buffers: TestBuffers = .{};
    var status_store = try file.StoreV1.create(
        temporary.dir,
        "status-capacity.outbox",
        status_fixture.header,
        .{},
        &status_buffers.journal,
        &status_buffers.records,
        &status_buffers.states,
    );
    defer status_store.close();
    _ = try status_store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            status_fixture.header,
            1,
            status_fixture.header.header_sha256,
            status_fixture.identity,
        ),
    );
    _ = try status_store.appendRecord(
        try outbox.makeTransitionRecordV1(
            status_fixture.header,
            2,
            status_store.final_chain_sha256,
            (try status_store.states())[0],
            .dispatch_intent,
            1,
            zero_digest,
            zero_digest,
        ),
    );
    var status_context: TestAdapterContext = .{
        .descriptor = descriptor,
        .store = &status_store,
    };
    try std.testing.expectError(
        file.Error.CapacityExceeded,
        reconcileUncertainV1(
            &status_store,
            status_context.adapter(),
            status_fixture.identity.action_sha256,
            1,
        ),
    );
    try std.testing.expectEqual(@as(u64, 0), status_context.status_calls);
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.uncertain,
        (try status_store.states())[0].phase,
    );
}

test "multi-action capacity guard preserves every uncertain obligation" {
    if (comptime !@import("platform_capabilities.zig")
        .current_adapter_availability_v1.posix_durable_file_adapter)
        return error.SkipZigTest;
    const descriptor = try adapter_contract.makeDescriptorV1(
        19,
        3,
        digest("multi authority"),
        digest("multi request schema"),
        digest("multi result schema"),
    );
    const fixture = try testActionV1(descriptor, 7);
    const second_identity = try testIdentityV1(
        fixture.header,
        2,
    );
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    // With seven total records, the first indeterminate dispatch leaves three
    // slots and one uncertain obligation. A second dispatch would need four
    // slots (the existing obligation plus its own intent/observation/future
    // reconciliation), so it must fail before callback authority.
    var dispatch_buffers: TestBuffers = .{};
    var dispatch_store = try file.StoreV1.create(
        temporary.dir,
        "multi-dispatch-capacity.outbox",
        fixture.header,
        .{},
        &dispatch_buffers.journal,
        &dispatch_buffers.records,
        &dispatch_buffers.states,
    );
    defer dispatch_store.close();
    _ = try dispatch_store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            fixture.header,
            1,
            fixture.header.header_sha256,
            fixture.identity,
        ),
    );
    _ = try dispatch_store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            fixture.header,
            2,
            dispatch_store.final_chain_sha256,
            second_identity,
        ),
    );
    var dispatch_context: TestAdapterContext = .{
        .descriptor = descriptor,
        .store = &dispatch_store,
        .dispatch_disposition = .indeterminate,
    };
    const first = try dispatchReadyV1(
        &dispatch_store,
        dispatch_context.adapter(),
        fixture.identity.action_sha256,
    );
    try std.testing.expectEqual(
        outbox.EventKindV1.ambiguity_observed,
        first.record.kind,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countUncertainV1(try dispatch_store.states()),
    );
    try std.testing.expectError(
        file.Error.CapacityExceeded,
        dispatchReadyV1(
            &dispatch_store,
            dispatch_context.adapter(),
            second_identity.action_sha256,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        dispatch_context.dispatch_calls,
    );
    const reconciled = try reconcileUncertainV1(
        &dispatch_store,
        dispatch_context.adapter(),
        fixture.identity.action_sha256,
        1,
    );
    try std.testing.expectEqual(
        outbox.EventKindV1.reconciled_not_applied,
        reconciled.record.?.kind,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countUncertainV1(try dispatch_store.states()),
    );
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.ready,
        findStateV1(
            try dispatch_store.states(),
            second_identity.action_sha256,
        ).?.phase,
    );

    // A caller can append directly and violate driver admission discipline.
    // Even then, status must not install a remote fence when one free record
    // cannot represent both outstanding local reconciliation obligations.
    var status_buffers: TestBuffers = .{};
    var status_store = try file.StoreV1.create(
        temporary.dir,
        "multi-status-capacity.outbox",
        fixture.header,
        .{},
        &status_buffers.journal,
        &status_buffers.records,
        &status_buffers.states,
    );
    defer status_store.close();
    _ = try status_store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            fixture.header,
            1,
            fixture.header.header_sha256,
            fixture.identity,
        ),
    );
    _ = try status_store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            fixture.header,
            2,
            status_store.final_chain_sha256,
            second_identity,
        ),
    );
    const first_ready = findStateV1(
        try status_store.states(),
        fixture.identity.action_sha256,
    ).?;
    _ = try status_store.appendRecord(
        try outbox.makeTransitionRecordV1(
            fixture.header,
            3,
            status_store.final_chain_sha256,
            first_ready,
            .dispatch_intent,
            1,
            zero_digest,
            zero_digest,
        ),
    );
    _ = try status_store.appendRecord(
        try outbox.makeTransitionRecordV1(
            fixture.header,
            4,
            status_store.final_chain_sha256,
            findStateV1(
                try status_store.states(),
                fixture.identity.action_sha256,
            ).?,
            .ambiguity_observed,
            1,
            digest("first ambiguity"),
            zero_digest,
        ),
    );
    const second_ready = findStateV1(
        try status_store.states(),
        second_identity.action_sha256,
    ).?;
    _ = try status_store.appendRecord(
        try outbox.makeTransitionRecordV1(
            fixture.header,
            5,
            status_store.final_chain_sha256,
            second_ready,
            .dispatch_intent,
            1,
            zero_digest,
            zero_digest,
        ),
    );
    _ = try status_store.appendRecord(
        try outbox.makeTransitionRecordV1(
            fixture.header,
            6,
            status_store.final_chain_sha256,
            findStateV1(
                try status_store.states(),
                second_identity.action_sha256,
            ).?,
            .ambiguity_observed,
            1,
            digest("second ambiguity"),
            zero_digest,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countUncertainV1(try status_store.states()),
    );
    var status_context: TestAdapterContext = .{
        .descriptor = descriptor,
        .store = &status_store,
    };
    try std.testing.expectError(
        file.Error.CapacityExceeded,
        reconcileUncertainV1(
            &status_store,
            status_context.adapter(),
            fixture.identity.action_sha256,
            1,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        status_context.status_calls,
    );
}
