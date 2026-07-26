//! Bounded W4b typed-tool workload with scheduler-coupled publication.
//!
//! The retained workload is intentionally credential-free and process-local.
//! It exercises one fixed `bounded_add` harness; it grants no filesystem,
//! network, process, clock, random-number, or external side-effect authority.

const std = @import("std");
const contract = @import("typed_workload_contract.zig");
const driver = @import("typed_workload_driver.zig");
const model = @import("model_contract.zig");
const qos = @import("lane_weave_qos.zig");
const resource_bank = @import("resource_bank.zig");
const tool = @import("tool_action_contract.zig");
const harness = @import("tool_action_harness.zig");

pub const Digest = contract.Digest;
pub const zero_digest = contract.zero_digest;

pub const evidence_abi: u64 = 0x4754_5457_4500_0001;
pub const item_evidence_abi: u64 = 0x4754_5457_4900_0001;
pub const summary_abi: u64 = 0x4754_5457_5300_0001;
pub const reference_tool_adapter_abi: u64 = 0x4754_5441_0000_0001;

pub const reference_profile_count: usize = 1;
pub const reference_item_count: usize = 8;
pub const reference_capacity: u32 = 3;

const evidence_domain =
    "glacier-typed-tool-workload-evidence-v1\x00";
const item_evidence_domain =
    "glacier-typed-tool-workload-item-evidence-v1\x00";
const item_section_domain =
    "glacier-typed-tool-workload-item-section-v1\x00";
const summary_domain =
    "glacier-typed-tool-workload-summary-v1\x00";
const correctness_domain =
    "glacier-typed-tool-correctness-v1\x00";

pub const Error = driver.Error || tool.Error || harness.Error || error{
    InvalidExecution,
    InvalidEvidence,
    InvalidReference,
    ArithmeticOverflow,
    InjectedFailure,
    NoSpaceLeft,
};

pub const FailureInjectionV1 = enum {
    none,
    after_prepare,
    after_arm,
};

pub const ItemEvidenceV1 = struct {
    ordinal: u64,
    profile_index: u64,
    outcome: driver.OutcomeKindV1,
    terminal_action: contract.TerminalActionV1,
    profile_sha256: Digest,
    item_sha256: Digest,
    arguments: tool.BoundedAddArgumentsV1,
    proposal: tool.ActionProposalV1,
    descriptor_sha256: Digest,
    policy_sha256: Digest,
    resource_receipt_sha256: Digest = zero_digest,
    resource_bank_epoch: u64 = 0,
    resource_slot_index: u64 = 0,
    resource_generation: u64 = 0,
    resource_owner_key: u64 = 0,
    resource_claim: resource_bank.Claim = .{},
    resource_integrity: u64 = 0,
    authorization: ?tool.AuthorizationReceiptV1 = null,
    effect: ?tool.EffectReceiptV1 = null,
    delivery: ?tool.DeliveryReceiptV1 = null,
    final_service_event_sha256: Digest = zero_digest,
    counter_before: i64 = 0,
    counter_after: i64 = 0,
    admission_trace_sha256: Digest,
    terminal_trace_sha256: Digest,
    driver_outcome_sha256: Digest,
    record_sha256: Digest = zero_digest,
};

pub const SummaryV1 = struct {
    profile_count: u64,
    item_count: u64,
    admitted: u64,
    rejected: u64,
    completed: u64,
    cancelled: u64,
    timed_out: u64,
    tool_calls: u64,
    deliveries: u64,
    executed: u64,
    reused: u64,
    denied: u64,
    conflicts: u64,
    effects: u64,
    initial_counter: i64,
    final_counter: i64,
    model_successful_commits: u64,
    model_releases: u64,
    model_final_active_reservations: u64,
    model_final_committed_receipts: u64,
    harness_open: bool,
    pending_prepared: u64,
    pending_armed: u64,
    zero_model_ownership: bool,
    zero_harness_authority: bool,
    zero_orphan_ownership: bool,
    summary_sha256: Digest = zero_digest,
};

pub const EvidenceV1 = struct {
    plan_sha256: Digest,
    driver_result_sha256: Digest,
    driver_outcome_sha256: Digest,
    driver_trace_sha256: Digest,
    driver_summary_sha256: Digest,
    descriptor: tool.DescriptorV1,
    policy: tool.PolicyV1,
    item_section_sha256: Digest,
    evidence_summary_sha256: Digest,
    items: []const ItemEvidenceV1,
    summary: SummaryV1,
    evidence_sha256: Digest,
};

pub const CampaignV1 = struct {
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
    evidence: EvidenceV1,
};

pub const CleanupReportV1 = struct {
    invoked: bool = false,
    admitted_closed: u64 = 0,
    prepared_aborted: u64 = 0,
    armed_aborted: u64 = 0,
    harness_closed: bool = false,
    model_used_zero: bool = false,
    model_active_reservations: u64 = 0,
    model_committed_receipts: u64 = 0,
    pending_prepared: u64 = 0,
    pending_armed: u64 = 0,
    final_counter: i64 = 0,
    effect_count: u64 = 0,
};

const reference_target_key: u64 = 1;
const reference_policy_tenant: u64 = 0x544f_4f4c;
const reference_initial_counter: i64 = 0;
const reference_final_counter: i64 = 8;
const reference_effect_count: u64 = 2;

fn referenceClaimV1() resource_bank.Claim {
    return .{
        .capsule_bytes = 32,
        .activation_bytes = 8,
        .partial_bytes = 32,
        .output_journal_bytes = 32,
        .staging_bytes = 32,
        .queue_slots = 1,
    };
}

pub fn makeReferenceDescriptorV1() Error!tool.DescriptorV1 {
    return tool.makeDescriptorV1(
        reference_tool_adapter_abi,
        digest("glacier typed tool bounded-add namespace v1"),
        digest("glacier typed tool bounded-add argument schema v1"),
        digest("glacier typed tool bounded-add result schema v1"),
        digest("glacier typed tool bounded-add implementation v1"),
    );
}

pub fn makeReferencePolicyV1(
    descriptor: tool.DescriptorV1,
) Error!tool.PolicyV1 {
    return tool.makePolicyV1(
        1,
        reference_policy_tenant,
        true,
        8,
        -32,
        32,
        descriptor,
        digest("glacier typed tool bounded-add policy challenge v1"),
    );
}

pub fn makeReferenceArgumentsV1(
    output: *[reference_item_count]tool.BoundedAddArgumentsV1,
) Error!void {
    const deltas = [_]i64{ 1, 2, 3, 4, 5, 5, 9, 4 };
    for (output, deltas) |*arguments, delta| {
        arguments.* = try tool.makeBoundedAddArgumentsV1(
            reference_target_key,
            delta,
        );
    }
    // Item five is an exact duplicate of item four.
    output[5] = output[4];
}

pub fn makeReferenceProposalsV1(
    descriptor: tool.DescriptorV1,
    arguments: *const [reference_item_count]tool.BoundedAddArgumentsV1,
    output: *[reference_item_count]tool.ActionProposalV1,
) Error!void {
    for (arguments, 0..) |value, index| {
        var request_label: [64]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &request_label,
            "glacier typed tool agent request {d} v1",
            .{index},
        );
        var idempotency_label: [64]u8 = undefined;
        const idempotency = try std.fmt.bufPrint(
            &idempotency_label,
            "glacier typed tool idempotency {d} v1",
            .{if (index == 7) @as(usize, 4) else index},
        );
        output[index] = try tool.makeActionProposalV1(
            reference_policy_tenant,
            @intCast(index),
            digest(request),
            descriptor,
            value,
            digest(idempotency),
        );
    }
    // Item five replays the exact proposal and effect from item four.
    output[5] = output[4];
    // Item seven deliberately occupies item four's idempotency identity with
    // a different, otherwise policy-allowed proposal.
    output[7] = try tool.makeActionProposalV1(
        reference_policy_tenant,
        7,
        digest("glacier typed tool agent request 7 v1"),
        descriptor,
        arguments[7],
        output[4].idempotency_key_sha256,
    );
}

pub fn makeProfileV1(
    descriptor: tool.DescriptorV1,
    policy: tool.PolicyV1,
) contract.ProfileV1 {
    const support: model.SupportRecordV1 = .{
        .family = .tool_executor,
        .operation = .execute_action,
        .input_kind = .typed_record,
        .output_kind = .tool_result,
        .numerical_policy = .exact_integer,
        .max_batch_items = 1,
        .max_input_features = 1,
        .max_output_dimensions = 1,
        .allowed_capabilities = tool.allowed_capabilities,
    };
    var profile: contract.ProfileV1 = .{
        .index = 0,
        .family = support.family,
        .operation = support.operation,
        .input_kind = support.input_kind,
        .output_kind = support.output_kind,
        .numerical_policy = support.numerical_policy,
        .adapter_abi = descriptor.tool_adapter_abi,
        .lifecycle = .stateless,
        .execution_unit = .tool_call,
        .cancellation_boundary = .before_start,
        .publication_policy = .final_only,
        .correctness_gate = .exact,
        .claim = referenceClaimV1(),
        .support_sha256 = contract.supportRecordSha256V1(support),
        .artifact_sha256 = digest(
            "glacier typed tool bounded-add artifact v1",
        ),
        .execution_plan_sha256 = digest(
            "glacier typed tool bounded-add execution plan v1",
        ),
        .adapter_implementation_sha256 = descriptor.implementation_sha256,
        .correctness_sha256 = correctnessSha256V1(
            descriptor,
            policy,
        ),
        .profile_sha256 = zero_digest,
    };
    profile.profile_sha256 = contract.profileSha256V1(profile);
    return profile;
}

pub fn inputBindingSha256V1(
    descriptor: tool.DescriptorV1,
    policy: tool.PolicyV1,
    arguments: tool.BoundedAddArgumentsV1,
    proposal: tool.ActionProposalV1,
) Digest {
    _ = descriptor;
    _ = policy;
    _ = arguments;
    return proposal.proposal_sha256;
}

pub fn makeItemV1(
    ordinal: usize,
    profile: contract.ProfileV1,
    descriptor: tool.DescriptorV1,
    policy: tool.PolicyV1,
    arguments: tool.BoundedAddArgumentsV1,
    proposal: tool.ActionProposalV1,
    arrival_step: u64,
    work_quanta: u64,
    terminal_action_step: u64,
    terminal_action: contract.TerminalActionV1,
) contract.ItemV1 {
    const identity: u64 = @intCast(ordinal + 1);
    var item: contract.ItemV1 = .{
        .ordinal = @intCast(ordinal),
        .profile_index = profile.index,
        .profile_sha256 = profile.profile_sha256,
        .arrival_step = arrival_step,
        .weight = 1,
        .work_quanta = work_quanta,
        .deadline_tick = 0,
        .terminal_action_step = terminal_action_step,
        .terminal_action = terminal_action,
        .fairness_member = true,
        .tenant_key = 0x8100 + identity,
        .request_key = 0x8200 + identity,
        .request_generation = 1,
        .resource_owner_key = 0x8300 + identity,
        .claim = profile.claim,
        .input_binding_sha256 = inputBindingSha256V1(
            descriptor,
            policy,
            arguments,
            proposal,
        ),
        .item_sha256 = zero_digest,
    };
    item.item_sha256 = contract.itemSha256V1(item);
    return item;
}

pub fn makeReferenceItemsV1(
    profile: contract.ProfileV1,
    descriptor: tool.DescriptorV1,
    policy: tool.PolicyV1,
    arguments: *const [reference_item_count]tool.BoundedAddArgumentsV1,
    proposals: *const [reference_item_count]tool.ActionProposalV1,
    output: *[reference_item_count]contract.ItemV1,
) void {
    const specs = [_]struct {
        arrival: u64,
        work: u64,
        action_step: u64,
        action: contract.TerminalActionV1,
    }{
        .{ .arrival = 0, .work = 8, .action_step = 1, .action = .cancel },
        .{ .arrival = 0, .work = 8, .action_step = 2, .action = .timeout },
        .{ .arrival = 0, .work = 1, .action_step = contract.absent, .action = .none },
        .{ .arrival = 1, .work = 1, .action_step = contract.absent, .action = .none },
        .{ .arrival = 2, .work = 1, .action_step = contract.absent, .action = .none },
        .{ .arrival = 3, .work = 1, .action_step = contract.absent, .action = .none },
        .{ .arrival = 4, .work = 1, .action_step = contract.absent, .action = .none },
        .{ .arrival = 5, .work = 1, .action_step = contract.absent, .action = .none },
    };
    for (output, arguments, proposals, specs, 0..) |
        *item,
        item_arguments,
        proposal,
        spec,
        index,
    | {
        item.* = makeItemV1(
            index,
            profile,
            descriptor,
            policy,
            item_arguments,
            proposal,
            spec.arrival,
            spec.work,
            spec.action_step,
            spec.action,
        );
    }
}

pub fn referencePlanV1(
    profiles: *const [reference_profile_count]contract.ProfileV1,
    items: *const [reference_item_count]contract.ItemV1,
) contract.PlanV1 {
    return .{
        .seed = 0x4754_5457_0000_0001,
        .capacity = reference_capacity,
        .max_driver_steps = 32,
        .max_service_quanta = 32,
        .fairness_start_tick = 0,
        .fairness_end_tick = 16,
        .bank_epoch = 0x4754_5457_424b_0001,
        .scheduler_epoch = 0x4754_5457_5343_0001,
        .max_weight = 1,
        .max_projection_quanta = 64,
        .max_projection_operations = 256,
        .limits = .{
            .host_bytes = 1024 * 1024,
            .capsule_bytes = 1024 * 1024,
            .kv_bytes = 1024 * 1024,
            .activation_bytes = 1024 * 1024,
            .partial_bytes = 1024 * 1024,
            .logits_bytes = 1024 * 1024,
            .output_journal_bytes = 1024 * 1024,
            .staging_bytes = 1024 * 1024,
            .device_bytes = 1024 * 1024,
            .io_bytes = 1024 * 1024,
            .queue_slots = reference_capacity,
        },
        .challenge = digest("glacier typed tool reference campaign v1"),
        .profiles = profiles,
        .items = items,
    };
}

fn correctnessSha256V1(
    descriptor: tool.DescriptorV1,
    policy: tool.PolicyV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(correctness_domain);
    hash.update(&descriptor.descriptor_sha256);
    hash.update(&policy.policy_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digest(value: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &result, .{});
    return result;
}

fn hashU64(hash: anytype, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn hashI64(hash: anytype, value: i64) void {
    hashU64(hash, @bitCast(value));
}

fn hashClaim(hash: anytype, claim: resource_bank.Claim) void {
    hashU64(hash, claim.capsule_bytes);
    hashU64(hash, claim.kv_bytes);
    hashU64(hash, claim.activation_bytes);
    hashU64(hash, claim.partial_bytes);
    hashU64(hash, claim.logits_bytes);
    hashU64(hash, claim.output_journal_bytes);
    hashU64(hash, claim.staging_bytes);
    hashU64(hash, claim.device_bytes);
    hashU64(hash, claim.io_bytes);
    hashU64(hash, claim.queue_slots);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

const ItemStateV1 = struct {
    admitted: bool = false,
    delivered: bool = false,
    closed: bool = false,
    handle: qos.Handle = .{},
    receipt: resource_bank.Receipt = undefined,
    resource_receipt_sha256: Digest = zero_digest,
    final_service_event: qos.EventV1 = undefined,
    authorization: ?tool.AuthorizationReceiptV1 = null,
    effect: ?tool.EffectReceiptV1 = null,
    delivery: ?tool.DeliveryReceiptV1 = null,
    counter_before: i64 = 0,
    counter_after: i64 = 0,
};

pub const ReferenceStorageV1 = struct {
    driver_storage: driver.MaximumStorageV1 = .{},
    replay_storage: driver.MaximumStorageV1 = .{},
    descriptor: tool.DescriptorV1 = undefined,
    policy: tool.PolicyV1 = undefined,
    arguments: [reference_item_count]tool.BoundedAddArgumentsV1 =
        undefined,
    proposals: [reference_item_count]tool.ActionProposalV1 = undefined,
    profiles: [reference_profile_count]contract.ProfileV1 = undefined,
    items: [reference_item_count]contract.ItemV1 = undefined,
    harness_ledger: [reference_item_count]harness.LedgerSlotV1 =
        [_]harness.LedgerSlotV1{.{}} ** reference_item_count,
    harness_counters: [reference_item_count]harness.CounterSlotV1 =
        [_]harness.CounterSlotV1{.{}} ** reference_item_count,
    tool_harness: harness.Harness = .{},
    states: [reference_item_count]ItemStateV1 =
        [_]ItemStateV1{.{}} ** reference_item_count,
    item_evidence: [reference_item_count]ItemEvidenceV1 = undefined,
    harness_snapshot: harness.SnapshotV1 = .{},
    cleanup_report: CleanupReportV1 = .{},
    prepared: bool = false,
    completed: bool = false,
    prepared_address: usize = 0,

    /// `init` deliberately installs no process-local pointers. Call
    /// `prepareV1` only after this value reaches its final address.
    pub fn init() Error!ReferenceStorageV1 {
        return .{};
    }

    pub fn prepareV1(self: *ReferenceStorageV1) Error!void {
        if (self.prepared or self.completed)
            return Error.InvalidExecution;
        self.descriptor = try makeReferenceDescriptorV1();
        self.policy = try makeReferencePolicyV1(self.descriptor);
        try makeReferenceArgumentsV1(&self.arguments);
        try makeReferenceProposalsV1(
            self.descriptor,
            &self.arguments,
            &self.proposals,
        );
        self.profiles[0] = makeProfileV1(
            self.descriptor,
            self.policy,
        );
        makeReferenceItemsV1(
            self.profiles[0],
            self.descriptor,
            self.policy,
            &self.arguments,
            &self.proposals,
            &self.items,
        );
        try contract.validatePlanV1(self.planV1());
        try self.tool_harness.init(
            .{
                .harness_epoch = 0x4754_5457_4845_0001,
                .harness_id = 0x4754_5457_4849_0001,
                .challenge_sha256 = digest(
                    "glacier typed tool harness campaign v1",
                ),
                .descriptor = self.descriptor,
                .policy = self.policy,
            },
            .{
                .ledger = &self.harness_ledger,
                .counters = &self.harness_counters,
            },
        );
        self.prepared = true;
        self.prepared_address = @intFromPtr(self);
        try validateReferenceSealV1(self);
    }

    pub fn planV1(self: *const ReferenceStorageV1) contract.PlanV1 {
        return referencePlanV1(&self.profiles, &self.items);
    }
};

const ExpectedTransactionV1 = struct {
    disposition: tool.DeliveryDispositionV1,
    authorization: tool.AuthorizationReceiptV1,
    effect: ?tool.EffectReceiptV1,
    counter_before: i64,
    counter_after: i64,
};

fn expectedTransactionV1(
    storage: *ReferenceStorageV1,
    item_index: usize,
) Error!ExpectedTransactionV1 {
    const arguments = storage.arguments[item_index];
    const proposal = storage.proposals[item_index];
    const before = try storage.tool_harness.counterValue(
        arguments.target_key,
    );
    for (
        storage.states,
        storage.proposals,
        0..,
    ) |state, prior_proposal, prior_index| {
        if (!state.delivered) continue;
        if (!digestEqual(
            prior_proposal.idempotency_key_sha256,
            proposal.idempotency_key_sha256,
        )) continue;
        const prior_effect = state.effect orelse
            return Error.InvalidExecution;
        if (digestEqual(
            prior_proposal.proposal_sha256,
            proposal.proposal_sha256,
        )) {
            if (prior_index == item_index or
                state.authorization == null)
                return Error.InvalidExecution;
            return .{
                .disposition = .reused,
                .authorization = state.authorization.?,
                .effect = prior_effect,
                .counter_before = before,
                .counter_after = before,
            };
        }
        return .{
            .disposition = .conflict,
            .authorization = try tool.denyIdempotencyConflictV1(
                proposal,
                storage.policy,
                before,
            ),
            .effect = prior_effect,
            .counter_before = before,
            .counter_after = before,
        };
    }

    const authorization = try tool.authorizeBoundedAddV1(
        proposal,
        storage.descriptor,
        arguments,
        storage.policy,
        before,
    );
    if (authorization.kind == .denied) {
        return .{
            .disposition = .denied,
            .authorization = authorization,
            .effect = null,
            .counter_before = before,
            .counter_after = before,
        };
    }
    const snapshot = try storage.tool_harness.snapshot();
    const effect = try tool.makeEffectReceiptV1(
        snapshot.next_execution_sequence,
        proposal,
        arguments,
        authorization,
    );
    return .{
        .disposition = .executed,
        .authorization = authorization,
        .effect = effect,
        .counter_before = before,
        .counter_after = effect.after_value,
    };
}

const PendingKindV1 = enum {
    none,
    prepared,
    armed,
    finalized,
};

const DriverContextV1 = struct {
    storage: *ReferenceStorageV1,
    injection: FailureInjectionV1,
    injection_consumed: bool = false,
    failure: ?Error = null,
    prepared_aborted: u64 = 0,
    armed_aborted: u64 = 0,
    pending_kind: PendingKindV1 = .none,
    pending_prepared: harness.PreparedV1 = .{},
    pending_token: harness.ArmedTokenV1 = .{},
    pending_ticket: qos.ServiceCommitTicketV1 = .{},
    pending_event: qos.EventV1 = undefined,

    fn fromOpaque(context: ?*anyopaque) *DriverContextV1 {
        return @ptrCast(@alignCast(context orelse
            @panic("missing typed tool driver context")));
    }

    fn fail(self: *DriverContextV1, err: Error) driver.DriverError {
        if (self.failure == null) self.failure = err;
        return error.DriverFailed;
    }

    fn bindAdmitted(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverBindAdmittedV1,
    ) driver.DriverError!void {
        _ = scheduler;
        const self = fromOpaque(context);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const state = &self.storage.states[call.item_index];
        const expected_item = self.storage.items[call.item_index];
        const expected_profile = self.storage.profiles[
            std.math.cast(
                usize,
                expected_item.profile_index,
            ) orelse return self.fail(Error.InvalidExecution)
        ];
        const receipt = call.admission.event.resource_receipt;
        if (state.admitted or state.closed or state.delivered or
            !std.meta.eql(call.item, expected_item) or
            !std.meta.eql(call.profile, expected_profile) or
            call.admission.event.kind != .admission_accepted or
            !std.meta.eql(
                call.admission.event.handle,
                call.admission.handle,
            ) or !resource_bank.receiptIntegrityValidV1(receipt) or
            receipt.bank_epoch != self.storage.planV1().bank_epoch or
            receipt.slot_index != call.admission.handle.slot_index or
            receipt.generation !=
                call.admission.handle.slot_generation or
            receipt.owner_key != expected_item.resource_owner_key or
            !std.meta.eql(receipt.claim, expected_item.claim) or
            !digestEqual(
                call.admission.event.resource_receipt_sha256,
                qos.resourceReceiptSha256(receipt),
            ) or !digestEqual(
            expected_item.input_binding_sha256,
            self.storage.proposals[call.item_index].proposal_sha256,
        ))
            return self.fail(Error.InvalidExecution);
        state.admitted = true;
        state.handle = call.admission.handle;
        state.receipt = receipt;
        state.resource_receipt_sha256 =
            call.admission.event.resource_receipt_sha256;
    }

    fn cancel(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverCancelV1,
    ) driver.DriverError!driver.SchedulerEventV1 {
        const self = fromOpaque(context);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const state = &self.storage.states[call.item_index];
        if (!state.admitted or state.closed or state.delivered or
            state.authorization != null or state.effect != null or
            state.delivery != null or
            !std.meta.eql(state.handle, call.handle))
            return self.fail(Error.InvalidExecution);
        const event = scheduler.cancel(call.handle) catch |err|
            return self.fail(err);
        state.closed = true;
        return event;
    }

    fn commitService(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverCommitServiceV1,
    ) driver.DriverError!driver.SchedulerEventV1 {
        const self = fromOpaque(context);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const state = &self.storage.states[call.item_index];
        if (!state.admitted or state.closed or state.delivered or
            !std.meta.eql(state.handle, call.permit.handle))
            return self.fail(Error.InvalidExecution);
        if (!call.final_quantum) {
            if (state.authorization != null or state.effect != null or
                state.delivery != null)
                return self.fail(Error.InvalidExecution);
            return scheduler.commitService(call.permit);
        }

        const injection = if (!self.injection_consumed and
            self.injection != .none and call.item_index == 2)
            self.injection
        else
            FailureInjectionV1.none;
        if (injection != .none) self.injection_consumed = true;

        const expected = expectedTransactionV1(
            self.storage,
            call.item_index,
        ) catch |err| return self.fail(err);
        const prepared = self.storage.tool_harness.prepare(
            self.storage.proposals[call.item_index],
            self.storage.arguments[call.item_index],
            call.permit,
        ) catch |err| return self.fail(err);
        self.pending_prepared = prepared;
        self.pending_kind = .prepared;
        if (injection == .after_prepare) {
            self.storage.tool_harness.abortPrepared(prepared) catch |err|
                return self.fail(err);
            self.prepared_aborted += 1;
            self.pending_kind = .none;
            scheduler.abortService(call.permit) catch |err|
                return self.fail(err);
            return self.fail(Error.InjectedFailure);
        }

        const scheduler_arm = scheduler.armServiceCommit(
            call.permit,
        ) catch |err| {
            self.storage.tool_harness.abortPrepared(prepared) catch {};
            self.prepared_aborted += 1;
            self.pending_kind = .none;
            scheduler.abortService(call.permit) catch {};
            return self.fail(err);
        };
        self.pending_ticket = scheduler_arm.ticket;
        const armed = self.storage.tool_harness.arm(
            prepared,
            scheduler_arm,
        ) catch |err| {
            scheduler.abortArmedService(scheduler_arm.ticket) catch {};
            self.storage.tool_harness.abortPrepared(prepared) catch {};
            self.prepared_aborted += 1;
            self.pending_kind = .none;
            return self.fail(err);
        };
        self.pending_token = armed.token;
        self.pending_kind = .armed;
        if (injection == .after_arm) {
            self.storage.tool_harness.abortArmed(armed.token) catch |err|
                return self.fail(err);
            self.armed_aborted += 1;
            scheduler.abortArmedService(scheduler_arm.ticket) catch |err|
                return self.fail(err);
            self.pending_kind = .none;
            return self.fail(Error.InjectedFailure);
        }

        const event = scheduler.commitArmedServiceTransaction(
            scheduler_arm.ticket,
            armed.transaction,
        ) catch |err| {
            self.storage.tool_harness.abortArmed(armed.token) catch {};
            self.armed_aborted += 1;
            scheduler.abortArmedService(scheduler_arm.ticket) catch {};
            self.pending_kind = .none;
            return self.fail(err);
        };
        self.pending_event = event;
        self.pending_kind = .finalized;
        const delivery = self.storage.tool_harness.finish(
            armed.token,
            event,
        ) catch |err| return self.fail(err);
        self.pending_kind = .none;

        const expected_delivery = tool.makeDeliveryReceiptV1(
            expected.disposition,
            self.storage.proposals[call.item_index],
            expected.authorization,
            expected.effect,
            event.event_sha256,
        ) catch |err| return self.fail(err);
        const after = self.storage.tool_harness.counterValue(
            self.storage.arguments[call.item_index].target_key,
        ) catch |err| return self.fail(err);
        if (!std.meta.eql(delivery, expected_delivery) or
            after != expected.counter_after)
            return self.fail(Error.InvalidExecution);

        // Delivery is exposed only after transactional precommit, scheduler
        // commit, infallible publication, and harness finish have all bound
        // the exact event.
        state.authorization = expected.authorization;
        state.effect = expected.effect;
        state.delivery = delivery;
        state.counter_before = expected.counter_before;
        state.counter_after = after;
        state.final_service_event = event;
        state.delivered = true;
        return event;
    }

    fn retire(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
        call: driver.DriverRetireV1,
    ) driver.DriverError!driver.SchedulerEventV1 {
        const self = fromOpaque(context);
        if (call.item_index >= reference_item_count)
            return self.fail(Error.InvalidExecution);
        const state = &self.storage.states[call.item_index];
        const delivery = state.delivery orelse
            return self.fail(Error.InvalidExecution);
        if (!state.admitted or !state.delivered or state.closed or
            !std.meta.eql(state.handle, call.handle) or
            !std.meta.eql(
                state.final_service_event,
                call.final_service_event,
            ) or !digestEqual(
            delivery.service_event_sha256,
            call.final_service_event.event_sha256,
        ))
            return self.fail(Error.InvalidExecution);
        const event = scheduler.retire(call.handle) catch |err|
            return self.fail(err);
        state.closed = true;
        return event;
    }

    fn cleanup(
        context: ?*anyopaque,
        scheduler: *driver.SchedulerV1,
    ) void {
        const self = fromOpaque(context);
        var report: CleanupReportV1 = .{
            .invoked = true,
            .prepared_aborted = self.prepared_aborted,
            .armed_aborted = self.armed_aborted,
        };
        switch (self.pending_kind) {
            .none => {},
            .prepared => {
                self.storage.tool_harness.abortPrepared(
                    self.pending_prepared,
                ) catch |err| {
                    if (self.failure == null) self.failure = err;
                };
                report.prepared_aborted += 1;
            },
            .armed => {
                self.storage.tool_harness.abortArmed(
                    self.pending_token,
                ) catch |err| {
                    if (self.failure == null) self.failure = err;
                };
                scheduler.abortArmedService(
                    self.pending_ticket,
                ) catch {};
                report.armed_aborted += 1;
            },
            .finalized => {
                _ = self.storage.tool_harness.finish(
                    self.pending_token,
                    self.pending_event,
                ) catch |err| {
                    if (self.failure == null) self.failure = err;
                };
            },
        }
        self.pending_kind = .none;

        for (&self.storage.states) |*state| {
            if (!state.admitted or state.closed) continue;
            if (scheduler.cancel(state.handle)) |_| {
                state.closed = true;
                report.admitted_closed += 1;
            } else |_| {
                if (scheduler.retire(state.handle)) |_| {
                    state.closed = true;
                    report.admitted_closed += 1;
                } else |_| {}
            }
        }
        closeHarnessForReportV1(
            self.storage,
            &report,
        ) catch |err| {
            if (self.failure == null) self.failure = err;
        };
        if (scheduler.bank.snapshot()) |snapshot| {
            report.model_used_zero = snapshot.used.isZero();
            report.model_active_reservations =
                @intCast(snapshot.active_reservations);
            report.model_committed_receipts =
                @intCast(snapshot.committed_receipts);
        } else |_| {}
        self.storage.cleanup_report = report;
    }

    fn interface(self: *DriverContextV1) driver.DriverV1 {
        return .{
            .context = self,
            .bind_admitted_fn = bindAdmitted,
            .cancel_fn = cancel,
            .commit_service_fn = commitService,
            .retire_fn = retire,
            .cleanup_fn = cleanup,
        };
    }
};

fn closeHarnessForReportV1(
    storage: *ReferenceStorageV1,
    report: *CleanupReportV1,
) Error!void {
    if (storage.tool_harness.initialized) {
        const final_counter = try storage.tool_harness.counterValue(
            reference_target_key,
        );
        storage.harness_snapshot = try storage.tool_harness.close();
        report.harness_closed = true;
        report.pending_prepared =
            @intFromBool(storage.harness_snapshot.pending);
        report.pending_armed = 0;
        report.final_counter = final_counter;
        report.effect_count =
            storage.harness_snapshot.counts.executed;
    }
}

fn toolStorageZeroV1(storage: *const ReferenceStorageV1) bool {
    for (storage.harness_ledger) |slot|
        if (!std.meta.eql(slot, harness.LedgerSlotV1{}))
            return false;
    for (storage.harness_counters) |slot|
        if (!std.meta.eql(slot, harness.CounterSlotV1{}))
            return false;
    return true;
}

pub fn runReferenceCampaignV1(
    storage: *ReferenceStorageV1,
) Error!CampaignV1 {
    return runReferenceCampaignWithFailureV1(storage, .none);
}

pub fn runReferenceCampaignWithFailureV1(
    storage: *ReferenceStorageV1,
    injection: FailureInjectionV1,
) Error!CampaignV1 {
    if (!storage.prepared) try storage.prepareV1();
    if (storage.completed) return Error.InvalidExecution;
    try validateReferenceSealV1(storage);
    storage.cleanup_report = .{};
    storage.states = [_]ItemStateV1{.{}} ** reference_item_count;

    const plan = storage.planV1();
    var context: DriverContextV1 = .{
        .storage = storage,
        .injection = injection,
    };
    var driver_result: driver.ResultV1 = undefined;
    driver.runPlanWithDriverV1(
        plan,
        storage.driver_storage.interface(),
        context.interface(),
        &driver_result,
    ) catch |err| {
        if (err == error.DriverFailed)
            return context.failure orelse Error.DriverFailed;
        return err;
    };
    if (injection != .none and !context.injection_consumed)
        return Error.InvalidExecution;

    var report: CleanupReportV1 = .{};
    try closeHarnessForReportV1(storage, &report);
    report.model_used_zero =
        driver_result.summary.zero_orphan_ownership;
    report.model_active_reservations =
        driver_result.summary.final_active_reservations;
    report.model_committed_receipts =
        driver_result.summary.final_committed_receipts;
    for (storage.states) |state| {
        if (state.admitted and state.closed)
            report.admitted_closed += 1;
    }
    storage.cleanup_report = report;
    storage.completed = true;

    const evidence = try buildEvidenceV1(
        storage,
        plan,
        driver_result,
    );
    return .{
        .plan = plan,
        .driver_result = driver_result,
        .evidence = evidence,
    };
}

fn validateReferenceSealV1(
    storage: *ReferenceStorageV1,
) Error!void {
    if (!storage.prepared or storage.completed or
        storage.prepared_address != @intFromPtr(storage))
        return Error.InvalidExecution;
    const descriptor = try makeReferenceDescriptorV1();
    const policy = try makeReferencePolicyV1(descriptor);
    var arguments: [reference_item_count]tool.BoundedAddArgumentsV1 =
        undefined;
    var proposals: [reference_item_count]tool.ActionProposalV1 =
        undefined;
    try makeReferenceArgumentsV1(&arguments);
    try makeReferenceProposalsV1(
        descriptor,
        &arguments,
        &proposals,
    );
    const profile = makeProfileV1(descriptor, policy);
    var items: [reference_item_count]contract.ItemV1 = undefined;
    makeReferenceItemsV1(
        profile,
        descriptor,
        policy,
        &arguments,
        &proposals,
        &items,
    );
    if (!std.meta.eql(storage.descriptor, descriptor) or
        !std.meta.eql(storage.policy, policy) or
        !std.meta.eql(storage.arguments, arguments) or
        !std.meta.eql(storage.proposals, proposals) or
        !std.meta.eql(storage.profiles[0], profile) or
        !std.meta.eql(storage.items, items))
        return Error.InvalidExecution;
    for (storage.states) |state| {
        if (state.admitted or state.delivered or state.closed or
            state.authorization != null or state.effect != null or
            state.delivery != null)
            return Error.InvalidExecution;
    }
    const snapshot = try storage.tool_harness.snapshot();
    if (snapshot.pending or snapshot.active_ledger_slots != 0 or
        snapshot.active_counter_slots != 0 or
        snapshot.counts.executed != 0 or
        snapshot.counts.reused != 0 or
        snapshot.counts.denied != 0 or
        snapshot.counts.conflicts != 0 or
        snapshot.counts.deliveries != 0)
        return Error.InvalidExecution;
    try contract.validatePlanV1(storage.planV1());
}

fn buildEvidenceV1(
    storage: *ReferenceStorageV1,
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
) Error!EvidenceV1 {
    for (
        plan.items,
        driver_result.outcomes,
        &storage.states,
        &storage.arguments,
        &storage.proposals,
        &storage.item_evidence,
    ) |
        item,
        outcome,
        state,
        arguments,
        proposal,
        *evidence_item,
    | {
        const admitted = outcome.kind != .rejected;
        const completed = outcome.kind == .completed;
        if ((admitted and (!state.admitted or !state.closed)) or
            (!admitted and state.admitted) or
            (completed != state.delivered))
            return Error.InvalidExecution;
        if (completed and
            (state.authorization == null or state.delivery == null))
            return Error.InvalidExecution;
        if (!completed and
            (state.authorization != null or state.effect != null or
                state.delivery != null))
            return Error.InvalidExecution;

        evidence_item.* = .{
            .ordinal = item.ordinal,
            .profile_index = item.profile_index,
            .outcome = outcome.kind,
            .terminal_action = outcome.terminal_action,
            .profile_sha256 = item.profile_sha256,
            .item_sha256 = item.item_sha256,
            .arguments = arguments,
            .proposal = proposal,
            .descriptor_sha256 = storage.descriptor.descriptor_sha256,
            .policy_sha256 = storage.policy.policy_sha256,
            .resource_receipt_sha256 = if (admitted)
                state.resource_receipt_sha256
            else
                zero_digest,
            .resource_bank_epoch = if (admitted)
                state.receipt.bank_epoch
            else
                0,
            .resource_slot_index = if (admitted)
                state.receipt.slot_index
            else
                0,
            .resource_generation = if (admitted)
                state.receipt.generation
            else
                0,
            .resource_owner_key = if (admitted)
                state.receipt.owner_key
            else
                0,
            .resource_claim = if (admitted)
                state.receipt.claim
            else
                .{},
            .resource_integrity = if (admitted)
                state.receipt.integrity
            else
                0,
            .authorization = state.authorization,
            .effect = state.effect,
            .delivery = state.delivery,
            .final_service_event_sha256 = if (completed)
                state.final_service_event.event_sha256
            else
                zero_digest,
            .counter_before = if (completed)
                state.counter_before
            else
                0,
            .counter_after = if (completed)
                state.counter_after
            else
                0,
            .admission_trace_sha256 = outcome.admission_trace_sha256,
            .terminal_trace_sha256 = outcome.terminal_trace_sha256,
            .driver_outcome_sha256 = outcome.record_sha256,
        };
        evidence_item.record_sha256 =
            itemEvidenceSha256V1(evidence_item.*);
    }

    const harness_snapshot = storage.harness_snapshot;
    const model_zero =
        driver_result.summary.zero_orphan_ownership and
        driver_result.summary.final_active_reservations == 0 and
        driver_result.summary.final_committed_receipts == 0;
    const harness_zero = !storage.tool_harness.initialized and
        !harness_snapshot.pending and toolStorageZeroV1(storage);
    var summary: SummaryV1 = .{
        .profile_count = @intCast(plan.profiles.len),
        .item_count = @intCast(plan.items.len),
        .admitted = driver_result.summary.admitted,
        .rejected = driver_result.summary.rejected,
        .completed = driver_result.summary.completed,
        .cancelled = driver_result.summary.cancelled,
        .timed_out = driver_result.summary.timed_out,
        .tool_calls = driver_result.summary.final_service_callbacks,
        .deliveries = harness_snapshot.counts.deliveries,
        .executed = harness_snapshot.counts.executed,
        .reused = harness_snapshot.counts.reused,
        .denied = harness_snapshot.counts.denied,
        .conflicts = harness_snapshot.counts.conflicts,
        .effects = harness_snapshot.counts.executed,
        .initial_counter = reference_initial_counter,
        .final_counter = storage.cleanup_report.final_counter,
        .model_successful_commits = driver_result.summary.successful_commits,
        .model_releases = driver_result.summary.releases,
        .model_final_active_reservations = driver_result.summary.final_active_reservations,
        .model_final_committed_receipts = driver_result.summary.final_committed_receipts,
        .harness_open = storage.tool_harness.initialized,
        .pending_prepared = 0,
        .pending_armed = 0,
        .zero_model_ownership = model_zero,
        .zero_harness_authority = harness_zero,
        .zero_orphan_ownership = model_zero and harness_zero,
    };
    summary.summary_sha256 = summarySha256V1(summary);

    const items = storage.item_evidence[0..reference_item_count];
    var evidence: EvidenceV1 = .{
        .plan_sha256 = driver_result.plan_sha256,
        .driver_result_sha256 = driver_result.result_sha256,
        .driver_outcome_sha256 = driver_result.outcome_sha256,
        .driver_trace_sha256 = driver_result.trace_sha256,
        .driver_summary_sha256 = driver_result.summary_sha256,
        .descriptor = storage.descriptor,
        .policy = storage.policy,
        .item_section_sha256 = itemSectionSha256V1(items),
        .evidence_summary_sha256 = summary.summary_sha256,
        .items = items,
        .summary = summary,
        .evidence_sha256 = zero_digest,
    };
    evidence.evidence_sha256 = evidenceSha256V1(evidence);
    try validateEvidenceByReplayV1(
        plan,
        driver_result,
        evidence,
        storage.replay_storage.interface(),
    );
    return evidence;
}

pub fn itemEvidenceSha256V1(item: ItemEvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item_evidence_domain);
    hashU64(&hash, item_evidence_abi);
    hashU64(&hash, item.ordinal);
    hashU64(&hash, item.profile_index);
    hashU64(&hash, @intFromEnum(item.outcome));
    hashU64(&hash, @intFromEnum(item.terminal_action));
    hash.update(&item.profile_sha256);
    hash.update(&item.item_sha256);
    hash.update(&item.arguments.arguments_sha256);
    hash.update(&item.proposal.proposal_sha256);
    hash.update(&item.descriptor_sha256);
    hash.update(&item.policy_sha256);
    hash.update(&item.resource_receipt_sha256);
    hashU64(&hash, item.resource_bank_epoch);
    hashU64(&hash, item.resource_slot_index);
    hashU64(&hash, item.resource_generation);
    hashU64(&hash, item.resource_owner_key);
    hashClaim(&hash, item.resource_claim);
    hashU64(&hash, item.resource_integrity);
    hashOptionalAuthorizationV1(&hash, item.authorization);
    hashOptionalEffectV1(&hash, item.effect);
    hashOptionalDeliveryV1(&hash, item.delivery);
    hash.update(&item.final_service_event_sha256);
    hashI64(&hash, item.counter_before);
    hashI64(&hash, item.counter_after);
    hash.update(&item.admission_trace_sha256);
    hash.update(&item.terminal_trace_sha256);
    hash.update(&item.driver_outcome_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn hashOptionalAuthorizationV1(
    hash: anytype,
    value: ?tool.AuthorizationReceiptV1,
) void {
    hashU64(hash, @intFromBool(value != null));
    hash.update(if (value) |receipt|
        &receipt.authorization_sha256
    else
        &zero_digest);
}

fn hashOptionalEffectV1(
    hash: anytype,
    value: ?tool.EffectReceiptV1,
) void {
    hashU64(hash, @intFromBool(value != null));
    hash.update(if (value) |receipt|
        &receipt.effect_sha256
    else
        &zero_digest);
}

fn hashOptionalDeliveryV1(
    hash: anytype,
    value: ?tool.DeliveryReceiptV1,
) void {
    hashU64(hash, @intFromBool(value != null));
    hash.update(if (value) |receipt|
        &receipt.delivery_sha256
    else
        &zero_digest);
}

pub fn itemSectionSha256V1(
    items: []const ItemEvidenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item_section_domain);
    hashU64(&hash, items.len);
    for (items) |item| hash.update(&item.record_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn summarySha256V1(summary: SummaryV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(summary_domain);
    hashU64(&hash, summary_abi);
    hashU64(&hash, summary.profile_count);
    hashU64(&hash, summary.item_count);
    hashU64(&hash, summary.admitted);
    hashU64(&hash, summary.rejected);
    hashU64(&hash, summary.completed);
    hashU64(&hash, summary.cancelled);
    hashU64(&hash, summary.timed_out);
    hashU64(&hash, summary.tool_calls);
    hashU64(&hash, summary.deliveries);
    hashU64(&hash, summary.executed);
    hashU64(&hash, summary.reused);
    hashU64(&hash, summary.denied);
    hashU64(&hash, summary.conflicts);
    hashU64(&hash, summary.effects);
    hashI64(&hash, summary.initial_counter);
    hashI64(&hash, summary.final_counter);
    hashU64(&hash, summary.model_successful_commits);
    hashU64(&hash, summary.model_releases);
    hashU64(&hash, summary.model_final_active_reservations);
    hashU64(&hash, summary.model_final_committed_receipts);
    hashU64(&hash, @intFromBool(summary.harness_open));
    hashU64(&hash, summary.pending_prepared);
    hashU64(&hash, summary.pending_armed);
    hashU64(&hash, @intFromBool(summary.zero_model_ownership));
    hashU64(&hash, @intFromBool(summary.zero_harness_authority));
    hashU64(&hash, @intFromBool(summary.zero_orphan_ownership));
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn evidenceSha256V1(evidence: EvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(evidence_domain);
    hashU64(&hash, evidence_abi);
    hash.update(&evidence.plan_sha256);
    hash.update(&evidence.driver_result_sha256);
    hash.update(&evidence.driver_outcome_sha256);
    hash.update(&evidence.driver_trace_sha256);
    hash.update(&evidence.driver_summary_sha256);
    hash.update(&evidence.descriptor.descriptor_sha256);
    hash.update(&evidence.policy.policy_sha256);
    hash.update(&evidence.item_section_sha256);
    hash.update(&evidence.evidence_summary_sha256);
    hashU64(&hash, evidence.items.len);
    for (evidence.items) |item| hash.update(&item.record_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Authoritative handoff validation composes the generic deterministic
/// scheduler replay with the tool transaction's semantic replay.
pub fn validateEvidenceByReplayV1(
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
    evidence: EvidenceV1,
    replay_storage: driver.StorageV1,
) Error!void {
    try driver.validateResultByReplayV1(
        plan,
        driver_result,
        replay_storage,
    );
    try validateEvidenceV1(plan, driver_result, evidence);
}

const SemanticLedgerV1 = struct {
    proposal: tool.ActionProposalV1,
    authorization: tool.AuthorizationReceiptV1,
    effect: tool.EffectReceiptV1,
};

/// Structural validation for callers that already authenticated the generic
/// driver result. Trust boundaries should use `validateEvidenceByReplayV1`.
pub fn validateEvidenceV1(
    plan: contract.PlanV1,
    driver_result: driver.ResultV1,
    evidence: EvidenceV1,
) Error!void {
    try contract.validatePlanV1(plan);
    try driver.validateResultStructureV1(plan, driver_result);
    const descriptor = try makeReferenceDescriptorV1();
    const policy = try makeReferencePolicyV1(descriptor);
    var arguments: [reference_item_count]tool.BoundedAddArgumentsV1 =
        undefined;
    var proposals: [reference_item_count]tool.ActionProposalV1 =
        undefined;
    try makeReferenceArgumentsV1(&arguments);
    try makeReferenceProposalsV1(
        descriptor,
        &arguments,
        &proposals,
    );
    const profile = makeProfileV1(descriptor, policy);
    var expected_items: [reference_item_count]contract.ItemV1 =
        undefined;
    makeReferenceItemsV1(
        profile,
        descriptor,
        policy,
        &arguments,
        &proposals,
        &expected_items,
    );
    const expected_profiles =
        [reference_profile_count]contract.ProfileV1{profile};
    const expected_plan = referencePlanV1(
        &expected_profiles,
        &expected_items,
    );

    if (plan.profiles.len != reference_profile_count or
        plan.items.len != reference_item_count or
        evidence.items.len != reference_item_count or
        !std.meta.eql(evidence.descriptor, descriptor) or
        !std.meta.eql(evidence.policy, policy) or
        !digestEqual(
            contract.planSha256V1(plan),
            contract.planSha256V1(expected_plan),
        ) or !digestEqual(
        evidence.plan_sha256,
        driver_result.plan_sha256,
    ) or !digestEqual(
        evidence.plan_sha256,
        contract.planSha256V1(plan),
    ) or !digestEqual(
        evidence.driver_result_sha256,
        driver_result.result_sha256,
    ) or !digestEqual(
        evidence.driver_outcome_sha256,
        driver_result.outcome_sha256,
    ) or !digestEqual(
        evidence.driver_trace_sha256,
        driver_result.trace_sha256,
    ) or !digestEqual(
        evidence.driver_summary_sha256,
        driver_result.summary_sha256,
    ) or !digestEqual(
        evidence.item_section_sha256,
        itemSectionSha256V1(evidence.items),
    ) or !digestEqual(
        evidence.evidence_summary_sha256,
        summarySha256V1(evidence.summary),
    ) or !digestEqual(
        evidence.summary.summary_sha256,
        evidence.evidence_summary_sha256,
    ) or !digestEqual(
        evidence.evidence_sha256,
        evidenceSha256V1(evidence),
    ))
        return Error.InvalidEvidence;

    var semantic_ledger: [reference_item_count]SemanticLedgerV1 = undefined;
    var semantic_ledger_count: usize = 0;
    var counter: i64 = reference_initial_counter;
    var execution_sequence: u64 = 0;
    var executed: u64 = 0;
    var reused: u64 = 0;
    var denied: u64 = 0;
    var conflicts: u64 = 0;
    var deliveries: u64 = 0;
    for (
        plan.items,
        driver_result.outcomes,
        evidence.items,
        arguments,
        proposals,
        expected_items,
    ) |
        item,
        outcome,
        evidence_item,
        item_arguments,
        proposal,
        expected_item,
    | {
        if (!std.meta.eql(item, expected_item) or
            outcome.ordinal != item.ordinal or
            evidence_item.ordinal != item.ordinal or
            evidence_item.profile_index != item.profile_index or
            evidence_item.outcome != outcome.kind or
            evidence_item.terminal_action != outcome.terminal_action or
            !digestEqual(
                evidence_item.profile_sha256,
                profile.profile_sha256,
            ) or !digestEqual(
            evidence_item.item_sha256,
            item.item_sha256,
        ) or !std.meta.eql(
            evidence_item.arguments,
            item_arguments,
        ) or !std.meta.eql(
            evidence_item.proposal,
            proposal,
        ) or !digestEqual(
            evidence_item.descriptor_sha256,
            descriptor.descriptor_sha256,
        ) or !digestEqual(
            evidence_item.policy_sha256,
            policy.policy_sha256,
        ) or !digestEqual(
            item.input_binding_sha256,
            proposal.proposal_sha256,
        ) or !digestEqual(
            evidence_item.admission_trace_sha256,
            outcome.admission_trace_sha256,
        ) or !digestEqual(
            evidence_item.terminal_trace_sha256,
            outcome.terminal_trace_sha256,
        ) or !digestEqual(
            evidence_item.driver_outcome_sha256,
            outcome.record_sha256,
        ) or !digestEqual(
            evidence_item.record_sha256,
            itemEvidenceSha256V1(evidence_item),
        ))
            return Error.InvalidEvidence;

        const admitted = outcome.kind != .rejected;
        const completed = outcome.kind == .completed;
        if (admitted) {
            const receipt = try evidenceReceiptV1(evidence_item);
            if (!resource_bank.receiptIntegrityValidV1(receipt) or
                receipt.bank_epoch != plan.bank_epoch or
                receipt.owner_key != item.resource_owner_key or
                !std.meta.eql(receipt.claim, item.claim) or
                receipt.slot_index != outcome.scheduler_slot_index or
                receipt.generation !=
                    outcome.scheduler_slot_generation or
                !digestEqual(
                    evidence_item.resource_receipt_sha256,
                    qos.resourceReceiptSha256(receipt),
                ))
                return Error.InvalidEvidence;
        } else if (!receiptEvidenceIsZeroV1(evidence_item)) {
            return Error.InvalidEvidence;
        }

        const service_root = try finalServiceRootV1(
            driver_result,
            item.ordinal,
        );
        if (!completed) {
            if (service_root != null or
                evidence_item.authorization != null or
                evidence_item.effect != null or
                evidence_item.delivery != null or
                !digestIsZero(
                    evidence_item.final_service_event_sha256,
                ) or evidence_item.counter_before != 0 or
                evidence_item.counter_after != 0)
                return Error.InvalidEvidence;
            continue;
        }
        const final_root = service_root orelse
            return Error.InvalidEvidence;
        if (!digestEqual(
            evidence_item.final_service_event_sha256,
            final_root,
        )) return Error.InvalidEvidence;

        const before = counter;
        var expected_authorization: tool.AuthorizationReceiptV1 = undefined;
        var expected_effect: ?tool.EffectReceiptV1 = null;
        var disposition: tool.DeliveryDispositionV1 = undefined;
        var existing: ?SemanticLedgerV1 = null;
        for (semantic_ledger[0..semantic_ledger_count]) |entry| {
            if (digestEqual(
                entry.proposal.idempotency_key_sha256,
                proposal.idempotency_key_sha256,
            )) {
                existing = entry;
                break;
            }
        }
        if (existing) |entry| {
            expected_effect = entry.effect;
            if (digestEqual(
                entry.proposal.proposal_sha256,
                proposal.proposal_sha256,
            )) {
                disposition = .reused;
                expected_authorization = entry.authorization;
                reused += 1;
            } else {
                disposition = .conflict;
                expected_authorization =
                    try tool.denyIdempotencyConflictV1(
                        proposal,
                        policy,
                        counter,
                    );
                conflicts += 1;
            }
        } else {
            expected_authorization =
                try tool.authorizeBoundedAddV1(
                    proposal,
                    descriptor,
                    item_arguments,
                    policy,
                    counter,
                );
            if (expected_authorization.kind == .denied) {
                disposition = .denied;
                denied += 1;
            } else {
                disposition = .executed;
                execution_sequence += 1;
                const effect = try tool.makeEffectReceiptV1(
                    execution_sequence,
                    proposal,
                    item_arguments,
                    expected_authorization,
                );
                expected_effect = effect;
                counter = effect.after_value;
                semantic_ledger[semantic_ledger_count] = .{
                    .proposal = proposal,
                    .authorization = expected_authorization,
                    .effect = effect,
                };
                semantic_ledger_count += 1;
                executed += 1;
            }
        }
        const expected_delivery = try tool.makeDeliveryReceiptV1(
            disposition,
            proposal,
            expected_authorization,
            expected_effect,
            final_root,
        );
        if (evidence_item.authorization == null or
            !std.meta.eql(
                evidence_item.authorization.?,
                expected_authorization,
            ) or !std.meta.eql(
            evidence_item.effect,
            expected_effect,
        ) or evidence_item.delivery == null or
            !std.meta.eql(
                evidence_item.delivery.?,
                expected_delivery,
            ) or evidence_item.counter_before != before or
            evidence_item.counter_after != counter)
            return Error.InvalidEvidence;
        deliveries += 1;
    }

    const summary = evidence.summary;
    const model_zero =
        driver_result.summary.zero_orphan_ownership and
        driver_result.summary.final_active_reservations == 0 and
        driver_result.summary.final_committed_receipts == 0;
    if (counter != reference_final_counter or
        execution_sequence != reference_effect_count or
        semantic_ledger_count != reference_effect_count or
        summary.profile_count != reference_profile_count or
        summary.item_count != reference_item_count or
        summary.admitted != driver_result.summary.admitted or
        summary.rejected != driver_result.summary.rejected or
        summary.completed != driver_result.summary.completed or
        summary.cancelled != driver_result.summary.cancelled or
        summary.timed_out != driver_result.summary.timed_out or
        summary.tool_calls !=
            driver_result.summary.final_service_callbacks or
        summary.deliveries != deliveries or
        summary.executed != executed or
        summary.reused != reused or
        summary.denied != denied or
        summary.conflicts != conflicts or
        summary.effects != execution_sequence or
        summary.initial_counter != reference_initial_counter or
        summary.final_counter != reference_final_counter or
        summary.model_successful_commits !=
            driver_result.summary.successful_commits or
        summary.model_releases != driver_result.summary.releases or
        summary.model_final_active_reservations != 0 or
        summary.model_final_committed_receipts != 0 or
        summary.harness_open or summary.pending_prepared != 0 or
        summary.pending_armed != 0 or
        summary.zero_model_ownership != model_zero or
        !summary.zero_model_ownership or
        !summary.zero_harness_authority or
        !summary.zero_orphan_ownership)
        return Error.InvalidEvidence;
}

fn evidenceReceiptV1(
    item: ItemEvidenceV1,
) Error!resource_bank.Receipt {
    return .{
        .bank_epoch = item.resource_bank_epoch,
        .slot_index = std.math.cast(
            u32,
            item.resource_slot_index,
        ) orelse return Error.InvalidEvidence,
        .generation = item.resource_generation,
        .owner_key = item.resource_owner_key,
        .claim = item.resource_claim,
        .integrity = item.resource_integrity,
    };
}

fn receiptEvidenceIsZeroV1(item: ItemEvidenceV1) bool {
    return digestIsZero(item.resource_receipt_sha256) and
        item.resource_bank_epoch == 0 and
        item.resource_slot_index == 0 and
        item.resource_generation == 0 and
        item.resource_owner_key == 0 and
        item.resource_claim.isZero() and
        item.resource_integrity == 0;
}

fn finalServiceRootV1(
    result: driver.ResultV1,
    ordinal: u64,
) Error!?Digest {
    var found: ?Digest = null;
    for (result.trace) |record| {
        if (record.event_kind != .service or
            record.item_ordinal != ordinal or
            record.remaining_after != 0)
            continue;
        if (found != null) return Error.InvalidEvidence;
        found = record.scheduler_event_sha256;
    }
    return found;
}

fn digestFromHexV1(value: []const u8) Digest {
    var result: Digest = undefined;
    _ = std.fmt.hexToBytes(&result, value) catch unreachable;
    return result;
}

test "reference typed tool campaign is atomic and replayable" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);

    try std.testing.expectEqual(
        digestFromHexV1(
            "b3a98a6b6ae1e15f61f576b003df9d60" ++
                "e8d43fcc74e16d9dddd6e2cbd04b221b",
        ),
        campaign.evidence.descriptor.descriptor_sha256,
    );
    try std.testing.expectEqual(
        digestFromHexV1(
            "f0c364387aa04f87ca7181f01c9358a2" ++
                "9438d4b446bd3906fb34515b77b903e4",
        ),
        campaign.evidence.policy.policy_sha256,
    );
    try std.testing.expectEqual(
        digestFromHexV1(
            "f845c402673987817d2345942dc492727" ++
                "3b717bb2d90c62fc57d01a7e5c149ff",
        ),
        campaign.plan.profiles[0].profile_sha256,
    );
    try std.testing.expectEqual(
        digestFromHexV1(
            "70f9a93231f0f8250dda77ca04664bec" ++
                "620fd1422445298ea7bf3aeca1dfadae",
        ),
        campaign.driver_result.plan_sha256,
    );
    try std.testing.expectEqual(
        digestFromHexV1(
            "12b71a866ecaf09b1b6982ae15625be6" ++
                "d6af5424b435beb641da1d0ab5b17741",
        ),
        campaign.driver_result.outcome_sha256,
    );
    try std.testing.expectEqual(
        digestFromHexV1(
            "26486838c786ef79e4439ade1ffce3c4" ++
                "853a610c7186a830ea15d5cf0b3a0d87",
        ),
        campaign.driver_result.trace_sha256,
    );
    try std.testing.expectEqual(
        digestFromHexV1(
            "fc0ef6eaad6dfd6e93df34f1505e3d7" ++
                "725fc70b66997916f4cfdee4defb249d9",
        ),
        campaign.driver_result.summary_sha256,
    );
    try std.testing.expectEqual(
        digestFromHexV1(
            "1ce13ab97d950b3fbc36aa4f3a060bc" ++
                "dee3a966537fcf382091216fe1860cab8",
        ),
        campaign.driver_result.result_sha256,
    );
    const expected_outcomes = [_]driver.OutcomeKindV1{
        .cancelled,
        .timed_out,
        .completed,
        .rejected,
        .completed,
        .completed,
        .completed,
        .completed,
    };
    for (
        campaign.driver_result.outcomes,
        expected_outcomes,
    ) |actual, expected| {
        try std.testing.expectEqual(expected, actual.kind);
    }
    const expected_dispositions =
        [_]?tool.DeliveryDispositionV1{
            null,
            null,
            .executed,
            null,
            .executed,
            .reused,
            .denied,
            .conflict,
        };
    for (
        campaign.evidence.items,
        expected_dispositions,
    ) |item, expected| {
        if (expected) |disposition| {
            try std.testing.expectEqual(
                disposition,
                item.delivery.?.disposition,
            );
        } else {
            try std.testing.expect(item.authorization == null);
            try std.testing.expect(item.effect == null);
            try std.testing.expect(item.delivery == null);
            try std.testing.expect(
                digestIsZero(item.final_service_event_sha256),
            );
        }
    }
    try std.testing.expectEqual(
        @as(i64, reference_final_counter),
        campaign.evidence.summary.final_counter,
    );
    try std.testing.expectEqual(
        @as(u64, reference_effect_count),
        campaign.evidence.summary.effects,
    );
    try std.testing.expect(
        campaign.evidence.summary.zero_orphan_ownership,
    );
    try std.testing.expect(toolStorageZeroV1(&storage));
    var replay_storage: driver.MaximumStorageV1 = .{};
    try validateEvidenceByReplayV1(
        campaign.plan,
        campaign.driver_result,
        campaign.evidence,
        replay_storage.interface(),
    );
}

test "noncompleted tool work exposes no authority or result" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);
    const expected_receipts = [_]?Digest{
        digestFromHexV1(
            "0d1b7c725fda11ad0f4252675aea4cf2" ++
                "a47cf3195ff699f0d09e00b2c43bc50b",
        ),
        digestFromHexV1(
            "377cef29f47713ab11b0d21ec929a791" ++
                "62e5bd189eba5832e592f21030cd1bca",
        ),
        digestFromHexV1(
            "434274e5e5b9e61e8cdb9186869b4fd" ++
                "9ab7db7e5ca38c05ca5b0d755b036cadb",
        ),
        null,
        digestFromHexV1(
            "e2e2a0659dd6b29366f6030518b8763" ++
                "06631de523eaafdb8251510d9e3adb1e4",
        ),
        digestFromHexV1(
            "190091b80d4370db60c6876f872019c3" ++
                "b550ab3b46359e45b963486c2ad84010",
        ),
        digestFromHexV1(
            "224309644fc2d4bda04c3943a19cf7c" ++
                "79141ec92cce8145cd3fe6e143e386bf8",
        ),
        digestFromHexV1(
            "605a658ca4cb917d7d094338682e85ae" ++
                "c02f67e4ea0e779844c0c5f18fb7f33b",
        ),
    };
    for (
        campaign.evidence.items,
        expected_receipts,
    ) |item, expected_receipt| {
        if (expected_receipt) |root| {
            try std.testing.expectEqual(
                root,
                item.resource_receipt_sha256,
            );
        } else {
            try std.testing.expect(
                receiptEvidenceIsZeroV1(item),
            );
        }
        if (item.outcome == .completed) continue;
        try std.testing.expect(item.authorization == null);
        try std.testing.expect(item.effect == null);
        try std.testing.expect(item.delivery == null);
        try std.testing.expect(
            digestIsZero(item.final_service_event_sha256),
        );
        try std.testing.expectEqual(@as(i64, 0), item.counter_before);
        try std.testing.expectEqual(@as(i64, 0), item.counter_after);
    }
}

test "semantic evidence rejects resealed authority substitutions" {
    inline for ([_]u8{ 0, 1, 2 }) |mutation| {
        var storage = try ReferenceStorageV1.init();
        const campaign = try runReferenceCampaignV1(&storage);
        var items: [reference_item_count]ItemEvidenceV1 = undefined;
        @memcpy(&items, campaign.evidence.items);
        switch (mutation) {
            0 => {
                items[0].authorization = items[2].authorization;
            },
            1 => {
                const wrong_root =
                    items[2].final_service_event_sha256;
                items[4].final_service_event_sha256 = wrong_root;
                items[4].delivery =
                    try tool.makeDeliveryReceiptV1(
                        items[4].delivery.?.disposition,
                        items[4].proposal,
                        items[4].authorization.?,
                        items[4].effect,
                        wrong_root,
                    );
            },
            2 => {
                items[7].counter_after += 1;
            },
            else => unreachable,
        }
        const index: usize = switch (mutation) {
            0 => 0,
            1 => 4,
            2 => 7,
            else => unreachable,
        };
        items[index].record_sha256 =
            itemEvidenceSha256V1(items[index]);
        var evidence = campaign.evidence;
        evidence.items = &items;
        evidence.item_section_sha256 =
            itemSectionSha256V1(evidence.items);
        evidence.evidence_sha256 = evidenceSha256V1(evidence);
        try std.testing.expectError(
            error.InvalidEvidence,
            validateEvidenceV1(
                campaign.plan,
                campaign.driver_result,
                evidence,
            ),
        );
    }
}

test "reference storage is address fenced sealed and single use" {
    {
        var original = try ReferenceStorageV1.init();
        try original.prepareV1();
        var moved = original;
        try std.testing.expectError(
            error.InvalidExecution,
            runReferenceCampaignV1(&moved),
        );
        const snapshot = try original.tool_harness.snapshot();
        try std.testing.expect(!snapshot.pending);
        try std.testing.expectEqual(
            @as(u64, 0),
            snapshot.counts.deliveries,
        );
        _ = try original.tool_harness.close();
    }
    {
        var storage = try ReferenceStorageV1.init();
        try storage.prepareV1();
        storage.proposals[0].action_ordinal += 1;
        storage.proposals[0].proposal_sha256 =
            tool.actionProposalSha256V1(storage.proposals[0]);
        storage.items[0].input_binding_sha256 =
            storage.proposals[0].proposal_sha256;
        storage.items[0].item_sha256 =
            contract.itemSha256V1(storage.items[0]);
        try std.testing.expectError(
            error.InvalidExecution,
            runReferenceCampaignV1(&storage),
        );
        const snapshot = try storage.tool_harness.snapshot();
        try std.testing.expect(!snapshot.pending);
        try std.testing.expectEqual(
            @as(u64, 0),
            snapshot.counts.deliveries,
        );
        _ = try storage.tool_harness.close();
    }
    {
        var storage = try ReferenceStorageV1.init();
        _ = try runReferenceCampaignV1(&storage);
        try std.testing.expectError(
            error.InvalidExecution,
            runReferenceCampaignV1(&storage),
        );
    }
}

test "injected prepare and arm failures leave zero authority" {
    inline for ([_]FailureInjectionV1{
        .after_prepare,
        .after_arm,
    }) |injection| {
        var storage = try ReferenceStorageV1.init();
        try std.testing.expectError(
            error.InjectedFailure,
            runReferenceCampaignWithFailureV1(
                &storage,
                injection,
            ),
        );
        const report = storage.cleanup_report;
        try std.testing.expect(report.invoked);
        try std.testing.expect(report.harness_closed);
        try std.testing.expect(report.model_used_zero);
        try std.testing.expectEqual(
            @as(u64, 0),
            report.model_active_reservations,
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            report.model_committed_receipts,
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            report.pending_prepared,
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            report.pending_armed,
        );
        try std.testing.expectEqual(
            @as(i64, reference_initial_counter),
            report.final_counter,
        );
        try std.testing.expectEqual(
            @as(u64, 0),
            report.effect_count,
        );
        switch (injection) {
            .after_prepare => try std.testing.expectEqual(
                @as(u64, 1),
                report.prepared_aborted,
            ),
            .after_arm => try std.testing.expectEqual(
                @as(u64, 1),
                report.armed_aborted,
            ),
            .none => unreachable,
        }
        try std.testing.expect(toolStorageZeroV1(&storage));
        for (storage.states) |state| {
            if (state.admitted)
                try std.testing.expect(state.closed);
            try std.testing.expect(!state.delivered);
            try std.testing.expect(state.authorization == null);
            try std.testing.expect(state.effect == null);
            try std.testing.expect(state.delivery == null);
        }
    }
}

test "authoritative validation rejects a resealed driver result" {
    var storage = try ReferenceStorageV1.init();
    const campaign = try runReferenceCampaignV1(&storage);
    var driver_result = campaign.driver_result;
    driver_result.summary.fairness_cross_product_error += 1;
    driver_result.summary_sha256 =
        driver.summarySha256V1(driver_result.summary);
    driver_result.result_sha256 = driver.resultSha256V1(
        driver_result.plan_sha256,
        driver_result.outcome_sha256,
        driver_result.trace_sha256,
        driver_result.summary_sha256,
    );
    var evidence = campaign.evidence;
    evidence.driver_result_sha256 = driver_result.result_sha256;
    evidence.driver_summary_sha256 = driver_result.summary_sha256;
    evidence.evidence_sha256 = evidenceSha256V1(evidence);

    try validateEvidenceV1(
        campaign.plan,
        driver_result,
        evidence,
    );
    var replay_storage: driver.MaximumStorageV1 = .{};
    try std.testing.expectError(
        error.InvalidEvidence,
        validateEvidenceByReplayV1(
            campaign.plan,
            driver_result,
            evidence,
            replay_storage.interface(),
        ),
    );
}
