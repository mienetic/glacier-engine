//! Integrated W4b-d same-process dispatch and fenced-status conformance.
//!
//! These tests compose the unchanged ActionOutbox journal, POSIX StoreV1,
//! trusted driver, and bounded fake authority. They exercise deterministic
//! append faults and fresh reopen; they do not claim process-death, service
//! restart, power-loss, network, provider, sandbox, or performance evidence.

const std = @import("std");
const platform = @import("platform_capabilities.zig");
const action = @import("tool_action_contract.zig");
const outbox = @import("tool_action_outbox_record.zig");
const file = @import("tool_action_outbox_file.zig");
const contract =
    @import("tool_action_outbox_adapter_contract.zig");
const fake = @import("tool_action_outbox_fake_adapter.zig");
const driver =
    @import("tool_action_outbox_dispatch_driver.zig");

pub const append_fault_phase_count: usize = 4;
pub const fence_append_fault_phase_count: usize = 4;

const append_fault_phases = [_]file.IoPhaseV1{
    .body_write,
    .body_sync,
    .footer_write,
    .footer_sync,
};

const TestBuffers = struct {
    journal: [8192]u8 = [_]u8{0} ** 8192,
    records: [8]outbox.RecordV1 =
        [_]outbox.RecordV1{.{}} ** 8,
    states: [2]outbox.ActionStateV1 =
        [_]outbox.ActionStateV1{.{}} ** 2,
};

const TestInputs = struct {
    descriptor: contract.DescriptorV1,
    header: outbox.HeaderV1,
    identity: outbox.ActionIdentityV1,
};

fn digest(value: []const u8) outbox.Digest {
    var result: outbox.Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}

fn testInputs() !TestInputs {
    const descriptor = try contract.makeDescriptorV1(
        0x4746_414b_0000_0001,
        11,
        digest("w4bd fake authority namespace"),
        digest("w4bd dispatch request schema"),
        digest("w4bd result schema"),
    );
    const header = try outbox.makeHeaderV1(
        17,
        23,
        41,
        2,
        8,
        4096,
        descriptor.descriptor_sha256,
        digest("w4bd payload store"),
        digest("w4bd header challenge"),
    );
    const tool_descriptor = try action.makeDescriptorV1(
        4,
        digest("w4bd tool namespace"),
        digest("w4bd argument schema"),
        digest("w4bd tool result schema"),
        digest("w4bd tool implementation"),
    );
    const arguments = try action.makeBoundedAddArgumentsV1(88, 2);
    const proposal = try action.makeActionProposalV1(
        41,
        1,
        digest("w4bd agent request"),
        tool_descriptor,
        arguments,
        digest("w4bd idempotency"),
    );
    const policy = try action.makePolicyV1(
        2,
        41,
        true,
        8,
        -10,
        10,
        tool_descriptor,
        digest("w4bd policy"),
    );
    const authorization = try action.authorizeBoundedAddV1(
        proposal,
        tool_descriptor,
        arguments,
        policy,
        1,
    );
    return .{
        .descriptor = descriptor,
        .header = header,
        .identity = try outbox.makeActionIdentityV1(
            header,
            .primary,
            outbox.zero_digest,
            tool_descriptor,
            arguments,
            proposal,
            policy,
            authorization,
            digest("w4bd service event"),
            digest("w4bd payload locator"),
            32,
            digest("w4bd payload"),
        ),
    };
}

fn enqueue(
    store: *file.StoreV1,
    inputs: TestInputs,
) !void {
    _ = try store.appendRecord(
        try outbox.makeEnqueuedRecordV1(
            inputs.header,
            1,
            inputs.header.header_sha256,
            inputs.identity,
        ),
    );
}

fn appendFirstIntent(
    store: *file.StoreV1,
    inputs: TestInputs,
) !outbox.RecordV1 {
    const state = (try store.states())[0];
    const intent = try outbox.makeTransitionRecordV1(
        inputs.header,
        @as(u64, @intCast(store.record_count)) + 1,
        store.final_chain_sha256,
        state,
        .dispatch_intent,
        1,
        outbox.zero_digest,
        outbox.zero_digest,
    );
    _ = try store.appendRecord(intent);
    return intent;
}

fn successPlan() !fake.DispatchPlanV1 {
    return fake.makeDispatchPlanV1(
        .succeeded,
        digest("w4bd remote success event"),
        digest("w4bd remote success result"),
    );
}

fn pendingPlan() !fake.DispatchPlanV1 {
    return fake.makeDispatchPlanV1(
        .pending,
        digest("w4bd remote pending event"),
        outbox.zero_digest,
    );
}

const credential =
    [_]u8{0xa7} ** fake.credential_bytes;

test "fenced status rejects delayed G and durable G plus one applies once" {
    if (comptime !platform.current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    const inputs = try testInputs();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffers: TestBuffers = .{};
    var store = try file.StoreV1.create(
        temporary.dir,
        "fenced.outbox",
        inputs.header,
        .{},
        &buffers.journal,
        &buffers.records,
        &buffers.states,
    );
    defer store.close();
    try enqueue(&store, inputs);
    const first_intent = try appendFirstIntent(&store, inputs);
    const first_request = try contract.makeDispatchRequestV1(
        inputs.descriptor,
        inputs.header,
        first_intent,
    );
    var authority = try fake.AuthorityV1.init(
        inputs.descriptor,
        credential,
        2,
        try successPlan(),
    );
    defer authority.deinit();

    const fenced = try driver.reconcileUncertainV1(
        &store,
        authority.adapter(),
        inputs.identity.action_sha256,
        1,
    );
    try std.testing.expectEqual(
        outbox.EventKindV1.reconciled_not_applied,
        fenced.record.?.kind,
    );
    const stale = try contract.dispatchV1(
        authority.adapter(),
        first_request,
    );
    try std.testing.expectEqual(
        contract.DispatchDispositionV1.rejected_stale_generation,
        stale.disposition,
    );

    const applied = try driver.dispatchReadyV1(
        &store,
        authority.adapter(),
        inputs.identity.action_sha256,
    );
    try std.testing.expectEqual(@as(u64, 2), applied.request.attempt_generation);
    try std.testing.expect(std.mem.eql(
        u8,
        &first_request.stable_remote_request_sha256,
        &applied.request.stable_remote_request_sha256,
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &first_request.dispatch_request_sha256,
        &applied.request.dispatch_request_sha256,
    ));
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.succeeded,
        (try store.states())[0].phase,
    );
    const late_stale = try contract.dispatchV1(
        authority.adapter(),
        first_request,
    );
    try std.testing.expectEqual(
        contract.DispatchDispositionV1.rejected_stale_generation,
        late_stale.disposition,
    );
    const service = authority.state();
    try std.testing.expectEqual(@as(u64, 1), service.counters.application_count);
    try std.testing.expectEqual(
        @as(u64, 2),
        service.counters.stale_generation_rejections,
    );
}

test "pending and unknown status never append retry authority" {
    if (comptime !platform.current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    const inputs = try testInputs();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var buffers: TestBuffers = .{};
    var store = try file.StoreV1.create(
        temporary.dir,
        "pending.outbox",
        inputs.header,
        .{},
        &buffers.journal,
        &buffers.records,
        &buffers.states,
    );
    defer store.close();
    try enqueue(&store, inputs);
    var authority = try fake.AuthorityV1.init(
        inputs.descriptor,
        credential,
        2,
        try pendingPlan(),
    );
    defer authority.deinit();

    const dispatch = try driver.dispatchReadyV1(
        &store,
        authority.adapter(),
        inputs.identity.action_sha256,
    );
    try std.testing.expectEqual(
        outbox.EventKindV1.ambiguity_observed,
        dispatch.record.kind,
    );
    const before_status_records = store.record_count;
    const pending = try driver.reconcileUncertainV1(
        &store,
        authority.adapter(),
        inputs.identity.action_sha256,
        1,
    );
    try std.testing.expect(pending.record == null);
    try std.testing.expectEqual(before_status_records, store.record_count);
    authority.setStatusUnknown(true);
    const unknown = try driver.reconcileUncertainV1(
        &store,
        authority.adapter(),
        inputs.identity.action_sha256,
        2,
    );
    try std.testing.expect(unknown.record == null);
    try std.testing.expectEqual(before_status_records, store.record_count);
    authority.setStatusUnknown(false);

    _ = try authority.completePending(
        dispatch.request.stable_remote_request_sha256,
        .succeeded,
        digest("w4bd completed pending event"),
        digest("w4bd completed pending result"),
    );
    const terminal = try driver.reconcileUncertainV1(
        &store,
        authority.adapter(),
        inputs.identity.action_sha256,
        3,
    );
    try std.testing.expectEqual(
        outbox.EventKindV1.reconciled_success,
        terminal.record.?.kind,
    );
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.succeeded,
        (try store.states())[0].phase,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.application_count,
    );
}

const NthPhaseFault = struct {
    phase: file.IoPhaseV1,
    occurrence: u64 = 0,
    fail_at: u64 = 2,

    fn observer(self: *NthPhaseFault) file.PhaseObserverV1 {
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
    const fault: *NthPhaseFault =
        @ptrCast(@alignCast(opaque_context));
    if (phase != fault.phase) return;
    fault.occurrence += 1;
    if (fault.occurrence == fault.fail_at)
        return file.Error.InjectedFault;
}

test "every terminal append phase reopens to terminal or reconciles once" {
    if (comptime !platform.current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    const inputs = try testInputs();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    for (append_fault_phases, 0..) |phase, index| {
        const names = [_][]const u8{
            "terminal-body-write.outbox",
            "terminal-body-sync.outbox",
            "terminal-footer-write.outbox",
            "terminal-footer-sync.outbox",
        };
        var initial_buffers: TestBuffers = .{};
        var store = try file.StoreV1.create(
            temporary.dir,
            names[index],
            inputs.header,
            .{},
            &initial_buffers.journal,
            &initial_buffers.records,
            &initial_buffers.states,
        );
        try enqueue(&store, inputs);
        var fault: NthPhaseFault = .{ .phase = phase };
        store.observer = fault.observer();
        var authority = try fake.AuthorityV1.init(
            inputs.descriptor,
            credential,
            2,
            try successPlan(),
        );
        defer authority.deinit();
        try std.testing.expectError(
            file.Error.InjectedFault,
            driver.dispatchReadyV1(
                &store,
                authority.adapter(),
                inputs.identity.action_sha256,
            ),
        );
        try std.testing.expectEqual(
            @as(u64, 1),
            authority.state().counters.application_count,
        );
        store.close();

        var recovery_buffers: TestBuffers = .{};
        var reopened = try file.StoreV1.open(
            temporary.dir,
            names[index],
            inputs.header,
            .{},
            &recovery_buffers.journal,
            &recovery_buffers.records,
            &recovery_buffers.states,
        );
        switch (phase) {
            .body_write, .body_sync => {
                try std.testing.expectEqual(
                    file.StoreStateV1.repair_required,
                    reopened.state,
                );
                try std.testing.expectEqual(
                    outbox.ActionPhaseV1.uncertain,
                    (try reopened.states())[0].phase,
                );
                const repair = try reopened.repairIncompleteTail();
                try std.testing.expectEqual(
                    outbox.record_body_bytes,
                    repair.discarded_tail_bytes,
                );
                reopened.close();

                var final_buffers: TestBuffers = .{};
                var final_store = try file.StoreV1.open(
                    temporary.dir,
                    names[index],
                    inputs.header,
                    .{},
                    &final_buffers.journal,
                    &final_buffers.records,
                    &final_buffers.states,
                );
                const reconciled = try driver.reconcileUncertainV1(
                    &final_store,
                    authority.adapter(),
                    inputs.identity.action_sha256,
                    1,
                );
                try std.testing.expectEqual(
                    outbox.EventKindV1.reconciled_success,
                    reconciled.record.?.kind,
                );
                try std.testing.expectEqual(
                    outbox.ActionPhaseV1.succeeded,
                    (try final_store.states())[0].phase,
                );
                final_store.close();
            },
            .footer_write, .footer_sync => {
                try std.testing.expectEqual(
                    file.StoreStateV1.ready,
                    reopened.state,
                );
                try std.testing.expectEqual(
                    outbox.ActionPhaseV1.succeeded,
                    (try reopened.states())[0].phase,
                );
                reopened.close();
            },
            else => unreachable,
        }
        try std.testing.expectEqual(
            @as(u64, 1),
            authority.state().counters.application_count,
        );
    }
}

fn finishFencedAppendRecovery(
    store: *file.StoreV1,
    authority: *fake.AuthorityV1,
    inputs: TestInputs,
    first_request: contract.DispatchRequestV1,
) !void {
    const recovered = (try store.states())[0];
    if (recovered.phase == .uncertain) {
        const reconciled = try driver.reconcileUncertainV1(
            store,
            authority.adapter(),
            inputs.identity.action_sha256,
            2,
        );
        try std.testing.expectEqual(
            outbox.EventKindV1.reconciled_not_applied,
            reconciled.record.?.kind,
        );
    }
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.ready,
        (try store.states())[0].phase,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.fence_installations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        authority.state().counters.application_count,
    );

    const stale = try contract.dispatchV1(
        authority.adapter(),
        first_request,
    );
    try std.testing.expectEqual(
        contract.DispatchDispositionV1.rejected_stale_generation,
        stale.disposition,
    );
    const applied = try driver.dispatchReadyV1(
        store,
        authority.adapter(),
        inputs.identity.action_sha256,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        applied.request.attempt_generation,
    );
    try std.testing.expect(std.mem.eql(
        u8,
        &first_request.stable_remote_request_sha256,
        &applied.request.stable_remote_request_sha256,
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &first_request.dispatch_request_sha256,
        &applied.request.dispatch_request_sha256,
    ));
    try std.testing.expectEqual(
        outbox.ActionPhaseV1.succeeded,
        (try store.states())[0].phase,
    );
    const service = authority.state();
    try std.testing.expectEqual(
        @as(u64, 1),
        service.counters.stale_generation_rejections,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        service.counters.application_count,
    );
}

test "every fenced transition append phase reopens before safe G plus one" {
    if (comptime !platform.current_adapter_availability_v1
        .posix_durable_file_adapter)
        return error.SkipZigTest;
    const inputs = try testInputs();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    for (append_fault_phases, 0..) |phase, index| {
        const names = [_][]const u8{
            "fence-body-write.outbox",
            "fence-body-sync.outbox",
            "fence-footer-write.outbox",
            "fence-footer-sync.outbox",
        };
        var initial_buffers: TestBuffers = .{};
        var store = try file.StoreV1.create(
            temporary.dir,
            names[index],
            inputs.header,
            .{},
            &initial_buffers.journal,
            &initial_buffers.records,
            &initial_buffers.states,
        );
        try enqueue(&store, inputs);
        const first_intent = try appendFirstIntent(&store, inputs);
        const first_request = try contract.makeDispatchRequestV1(
            inputs.descriptor,
            inputs.header,
            first_intent,
        );
        var authority = try fake.AuthorityV1.init(
            inputs.descriptor,
            credential,
            2,
            try successPlan(),
        );
        defer authority.deinit();
        var fault: NthPhaseFault = .{
            .phase = phase,
            .fail_at = 1,
        };
        store.observer = fault.observer();
        try std.testing.expectError(
            file.Error.InjectedFault,
            driver.reconcileUncertainV1(
                &store,
                authority.adapter(),
                inputs.identity.action_sha256,
                1,
            ),
        );
        const fenced = authority.state();
        try std.testing.expectEqual(
            @as(u64, 1),
            fenced.counters.fence_installations,
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            fenced.counters.application_count,
        );
        store.close();

        var recovery_buffers: TestBuffers = .{};
        var reopened = try file.StoreV1.open(
            temporary.dir,
            names[index],
            inputs.header,
            .{},
            &recovery_buffers.journal,
            &recovery_buffers.records,
            &recovery_buffers.states,
        );
        switch (phase) {
            .body_write, .body_sync => {
                try std.testing.expectEqual(
                    file.StoreStateV1.repair_required,
                    reopened.state,
                );
                try std.testing.expectEqual(
                    outbox.ActionPhaseV1.uncertain,
                    (try reopened.states())[0].phase,
                );
                const repair = try reopened.repairIncompleteTail();
                try std.testing.expectEqual(
                    outbox.record_body_bytes,
                    repair.discarded_tail_bytes,
                );
                reopened.close();

                var final_buffers: TestBuffers = .{};
                var final_store = try file.StoreV1.open(
                    temporary.dir,
                    names[index],
                    inputs.header,
                    .{},
                    &final_buffers.journal,
                    &final_buffers.records,
                    &final_buffers.states,
                );
                try finishFencedAppendRecovery(
                    &final_store,
                    &authority,
                    inputs,
                    first_request,
                );
                final_store.close();
            },
            .footer_write, .footer_sync => {
                try std.testing.expectEqual(
                    file.StoreStateV1.ready,
                    reopened.state,
                );
                try finishFencedAppendRecovery(
                    &reopened,
                    &authority,
                    inputs,
                    first_request,
                );
                reopened.close();
            },
            else => unreachable,
        }
    }
}
