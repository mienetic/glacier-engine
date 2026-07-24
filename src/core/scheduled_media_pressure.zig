//! Scheduler-coupled image, audio, and video execution evidence.
//!
//! The frozen WorkloadPressure V1 scenario/result wires remain unchanged.
//! This additive layer adopts each accepted LaneWeave receipt into one bounded
//! media-runtime session, executes the retained media transaction only on the
//! request's final service quantum, and emits a separately versioned sidecar.
//! Rejected, cancelled, and timed-out work never publishes media output.

const std = @import("std");
const qos = @import("lane_weave_qos.zig");
const resource_bank = @import("resource_bank.zig");
const media = @import("media_contract.zig");
const fixture_api = @import("media_fixture.zig");
const decode_plan = @import("media_decode_plan.zig");
const transform = @import("media_transform.zig");
const runtime = @import("media_runtime_txn.zig");
const workload = @import("workload_pressure.zig");

pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

pub const evidence_abi: u64 = 0x4757_504d_0000_0001;
pub const evidence_magic = [8]u8{ 'G', 'W', 'P', 'M', 'E', '1', 0, 0 };
pub const evidence_header_bytes: usize = 288;
pub const item_record_bytes: usize = 288;
pub const execution_record_bytes: usize = 992;
pub const summary_record_bytes: usize = 160;
pub const evidence_footer_bytes: usize = 32;
pub const allowed_flags: u64 = 0;

const evidence_domain = "glacier-scheduled-media-pressure-evidence-v1\x00";
const item_domain = "glacier-scheduled-media-pressure-item-v1\x00";
const execution_domain =
    "glacier-scheduled-media-pressure-execution-v1\x00";
const summary_domain = "glacier-scheduled-media-pressure-summary-v1\x00";
const record_frame = "record\x00";
const section_frame = "section\x00";
const request_epoch_prefix: u64 = 0x4757_504d_0000_0000;

pub const Error = workload.Error || runtime.Error || media.Error ||
    fixture_api.Error || decode_plan.Error || transform.Error ||
    resource_bank.Error || qos.Error || error{
    ArithmeticOverflow,
    BufferTooSmall,
    DriverFailed,
    EvidenceLimitExceeded,
    InvalidEvidence,
    InvalidExecution,
    MissingExecution,
    UnexpectedExecution,
};

pub const ItemEvidenceV1 = struct {
    ordinal: u64,
    kind: media.MediaKindV1,
    outcome: workload.OutcomeKindV1,
    terminal_action: workload.TerminalActionV1,
    admitted_step: u64,
    terminal_step: u64,
    execution_index: u64,
    resource_bank_epoch: u64 = 0,
    resource_slot_index: u64 = 0,
    resource_generation: u64 = 0,
    resource_owner_key: u64 = 0,
    resource_integrity: u64 = 0,
    item_sha256: Digest,
    admission_trace_sha256: Digest,
    terminal_trace_sha256: Digest,
    resource_receipt_sha256: Digest = zero_digest,
    record_sha256: Digest = zero_digest,
};

pub const ExecutionEvidenceV1 = struct {
    ordinal: u64,
    kind: media.MediaKindV1,
    final_trace_index: u64,
    driver_step: u64,
    service_event_sequence: u64,
    logical_tick_before: u64,
    logical_tick_after: u64,
    remaining_before: u64,
    remaining_after: u64,
    wait_quanta: u64,
    request_epoch: u64,
    output_bytes: u64,
    mapping_count: u64,
    item_sha256: Digest,
    final_trace_sha256: Digest,
    media_state_before_sha256: Digest,
    media_state_after_sha256: Digest,
    output_sha256: Digest,
    receipt: runtime.ExecutionReceiptV1,
    record_sha256: Digest = zero_digest,
};

pub const SummaryV1 = struct {
    item_count: u64,
    execution_count: u64,
    admitted: u64,
    rejected: u64,
    completed: u64,
    cancelled: u64,
    timed_out: u64,
    image_executions: u64,
    audio_executions: u64,
    video_executions: u64,
    logical_units: u64,
    output_bytes: u64,
    publications: u64,
    closed_terminal_sessions: u64,
    maximum_live_receipts: u64,
    zero_orphan_ownership: bool,
    summary_sha256: Digest = zero_digest,
};

pub const EvidenceV1 = struct {
    scenario_sha256: Digest,
    outcome_sha256: Digest,
    trace_sha256: Digest,
    workload_summary_sha256: Digest,
    item_section_sha256: Digest,
    execution_section_sha256: Digest,
    evidence_summary_sha256: Digest,
    items: []const ItemEvidenceV1,
    executions: []const ExecutionEvidenceV1,
    summary: SummaryV1,
    evidence_sha256: Digest,
};

pub const MediaSlotV1 = struct {
    input_storage: runtime.ReferenceInputStorageV1 = .{},
    input: runtime.ReferenceInputV1 = undefined,
    publication_state: media.PublicationStateV1 = undefined,
    session: runtime.Session = .{},
    decoded_source: [fixture_api.maximum_payload_bytes]u8 =
        [_]u8{0} ** fixture_api.maximum_payload_bytes,
    output: [fixture_api.maximum_payload_bytes]u8 =
        [_]u8{0} ** fixture_api.maximum_payload_bytes,
    mappings: [runtime.reference_maximum_mappings]transform.TransformMappingV1 =
        undefined,
    admission_receipt: resource_bank.Receipt = undefined,
    execution_receipt: runtime.ExecutionReceiptV1 = undefined,
    final_service_event: qos.EventV1 = undefined,
    media_state_before_sha256: Digest = zero_digest,
    media_state_after_sha256: Digest = zero_digest,
    admitted: bool = false,
    executed: bool = false,
    closed: bool = false,
};

pub const StorageV1 = struct {
    workload_storage: workload.StorageV1,
    media_slots: []MediaSlotV1,
    item_evidence: []ItemEvidenceV1,
    execution_evidence: []ExecutionEvidenceV1,
};

pub const CampaignV1 = struct {
    workload_result: workload.ResultV1,
    evidence: EvidenceV1,
};

pub const ReferenceStorageV1 = struct {
    workload_storage: workload.ReferenceStorageV1 = .{},
    media_slots: [7]MediaSlotV1 = [_]MediaSlotV1{.{}} ** 7,
    item_evidence: [7]ItemEvidenceV1 = undefined,
    execution_evidence: [7]ExecutionEvidenceV1 = undefined,

    pub fn interface(self: *ReferenceStorageV1) StorageV1 {
        return .{
            .workload_storage = self.workload_storage.interface(),
            .media_slots = &self.media_slots,
            .item_evidence = &self.item_evidence,
            .execution_evidence = &self.execution_evidence,
        };
    }
};

const DriverContextV1 = struct {
    media_slots: []MediaSlotV1,
    failure: ?Error = null,

    fn fromOpaque(context: ?*anyopaque) *DriverContextV1 {
        return @ptrCast(@alignCast(context orelse
            @panic("missing scheduled media driver context")));
    }

    fn fail(self: *DriverContextV1, err: Error) workload.DriverError {
        if (self.failure == null) self.failure = err;
        return error.DriverFailed;
    }

    fn bindAdmitted(
        context: ?*anyopaque,
        scheduler: *workload.SchedulerV1,
        call: workload.DriverBindAdmittedV1,
    ) workload.DriverError!void {
        const self = fromOpaque(context);
        if (call.item_index >= self.media_slots.len)
            return self.fail(Error.BufferTooSmall);
        const slot = &self.media_slots[call.item_index];
        slot.* = .{};
        slot.input = runtime.prepareReferenceInputV1(
            call.item.media_kind,
            &slot.input_storage,
        ) catch |err| {
            _ = scheduler.cancel(call.admission.handle) catch {};
            return self.fail(err);
        };
        const request_epoch = requestEpochV1(call.item.ordinal) catch |err| {
            _ = scheduler.cancel(call.admission.handle) catch {};
            return self.fail(err);
        };
        var previous_commit: Digest = undefined;
        @memset(&previous_commit, @intCast(0xa0 + call.item.ordinal));
        slot.publication_state = media.initializePublicationStateV1(
            request_epoch,
            1,
            slot.input.timeline_base,
            slot.input.fixture.media_object_sha256,
            previous_commit,
        ) catch |err| {
            _ = scheduler.cancel(call.admission.handle) catch {};
            return self.fail(err);
        };
        slot.session.initScheduledV1(
            scheduler,
            call.admission,
            request_epoch,
            &slot.publication_state,
            slot.input.encoded_fixture,
            slot.input.encoded_transform_plan,
        ) catch |err| {
            _ = scheduler.cancel(call.admission.handle) catch {};
            return self.fail(err);
        };
        slot.admission_receipt = call.admission.event.resource_receipt;
        slot.admitted = true;
    }

    fn cancel(
        context: ?*anyopaque,
        scheduler: *workload.SchedulerV1,
        call: workload.DriverCancelV1,
    ) workload.DriverError!workload.SchedulerEventV1 {
        _ = scheduler;
        const self = fromOpaque(context);
        if (call.item_index >= self.media_slots.len)
            return self.fail(Error.BufferTooSmall);
        const slot = &self.media_slots[call.item_index];
        if (!slot.admitted or slot.executed or slot.closed)
            return self.fail(Error.InvalidExecution);
        const event = slot.session.cancelScheduledV1() catch |err|
            return self.fail(err);
        slot.closed = true;
        return event;
    }

    fn commitService(
        context: ?*anyopaque,
        scheduler: *workload.SchedulerV1,
        call: workload.DriverCommitServiceV1,
    ) workload.DriverError!workload.SchedulerEventV1 {
        const self = fromOpaque(context);
        if (!call.final_quantum)
            return scheduler.commitService(call.permit);
        if (call.item_index >= self.media_slots.len)
            return self.fail(Error.BufferTooSmall);
        const slot = &self.media_slots[call.item_index];
        if (!slot.admitted or slot.executed or slot.closed)
            return self.fail(Error.InvalidExecution);

        slot.media_state_before_sha256 = media.publicationStateRootV1(
            slot.publication_state,
        );
        var transaction = slot.session.prepare(
            slot.input.encoded_fixture,
            slot.input.encoded_decode_plan,
            slot.input.encoded_transform_plan,
            &slot.decoded_source,
            &slot.output,
            &slot.mappings,
        ) catch |err| {
            scheduler.abortService(call.permit) catch {};
            return self.fail(err);
        };
        const armed_service = scheduler.armServiceCommit(
            call.permit,
        ) catch |err| {
            transaction.abort() catch {};
            scheduler.abortService(call.permit) catch {};
            return self.fail(err);
        };
        var armed_media = transaction.armServiceV1(
            armed_service.intent,
        ) catch |err| {
            transaction.abort() catch {};
            scheduler.abortArmedService(armed_service.ticket) catch {};
            return self.fail(err);
        };
        const event = scheduler.commitArmedServiceV2(
            armed_service.ticket,
            armed_media.finalizer(),
        ) catch |err| {
            armed_media.abort() catch {};
            scheduler.abortArmedService(armed_service.ticket) catch {};
            return self.fail(err);
        };
        slot.final_service_event = event;
        slot.executed = true;
        slot.execution_receipt = armed_media.executionReceiptV1() catch |err|
            return self.fail(err);
        slot.media_state_after_sha256 = media.publicationStateRootV1(
            slot.publication_state,
        );
        return event;
    }

    fn retire(
        context: ?*anyopaque,
        scheduler: *workload.SchedulerV1,
        call: workload.DriverRetireV1,
    ) workload.DriverError!workload.SchedulerEventV1 {
        _ = scheduler;
        const self = fromOpaque(context);
        if (call.item_index >= self.media_slots.len)
            return self.fail(Error.BufferTooSmall);
        const slot = &self.media_slots[call.item_index];
        if (!slot.admitted or !slot.executed or slot.closed or
            !std.meta.eql(slot.final_service_event, call.final_service_event))
            return self.fail(Error.InvalidExecution);
        const event = slot.session.retireScheduledV1() catch |err|
            return self.fail(err);
        slot.closed = true;
        return event;
    }

    fn cleanup(
        context: ?*anyopaque,
        scheduler: *workload.SchedulerV1,
    ) void {
        _ = scheduler;
        const self = fromOpaque(context);
        for (self.media_slots) |*slot| {
            if (!slot.admitted or slot.closed) continue;
            if (slot.executed) {
                _ = slot.session.retireScheduledV1() catch |err| {
                    if (self.failure == null) self.failure = err;
                    continue;
                };
            } else {
                _ = slot.session.cancelScheduledV1() catch |err| {
                    if (self.failure == null) self.failure = err;
                    continue;
                };
            }
            slot.closed = true;
        }
    }

    fn interface(self: *DriverContextV1) workload.DriverV1 {
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

pub fn requestEpochV1(ordinal: u64) Error!u64 {
    const identity = try checkedAdd(ordinal, 1);
    if (identity > 0xffff_ffff) return Error.InvalidExecution;
    return request_epoch_prefix | identity;
}

pub fn requiredEvidenceBytesV1(
    item_count: usize,
    execution_count: usize,
) Error!usize {
    if (item_count == 0 or item_count > workload.maximum_items or
        execution_count > item_count)
        return Error.EvidenceLimitExceeded;
    var total = evidence_header_bytes;
    total = try checkedAddUsize(
        total,
        try checkedMulUsize(item_count, item_record_bytes),
    );
    total = try checkedAddUsize(
        total,
        try checkedMulUsize(execution_count, execution_record_bytes),
    );
    total = try checkedAddUsize(total, summary_record_bytes);
    return checkedAddUsize(total, evidence_footer_bytes);
}

pub fn runScenarioV1(
    scenario: workload.ScenarioV1,
    storage: StorageV1,
) Error!CampaignV1 {
    try workload.validateScenarioV1(scenario);
    const capacity = std.math.cast(usize, scenario.capacity) orelse
        return Error.InvalidExecution;
    if (storage.workload_storage.bank_slots.len < capacity or
        storage.workload_storage.scheduler_slots.len < capacity or
        storage.workload_storage.scheduler_projection.len < capacity or
        storage.workload_storage.verifier_slots.len < capacity or
        storage.workload_storage.verifier_projection.len < capacity or
        storage.workload_storage.runtime_items.len < scenario.items.len or
        storage.workload_storage.outcomes.len < scenario.items.len or
        storage.workload_storage.trace.len <
            workload.maximum_trace_records or
        storage.media_slots.len < scenario.items.len or
        storage.item_evidence.len < scenario.items.len or
        storage.execution_evidence.len < scenario.items.len)
        return Error.BufferTooSmall;
    const media_slots = storage.media_slots[0..scenario.items.len];
    for (media_slots) |*slot| slot.* = .{};
    errdefer {
        for (media_slots) |*slot| slot.* = .{};
    }

    var driver_context: DriverContextV1 = .{
        .media_slots = media_slots,
    };
    const workload_result = workload.runScenarioWithDriverV1(
        scenario,
        storage.workload_storage,
        driver_context.interface(),
    ) catch |err| {
        if (err == error.DriverFailed)
            return driver_context.failure orelse Error.DriverFailed;
        return err;
    };

    var execution_count: usize = 0;
    for (workload_result.trace, 0..) |trace_record, trace_index| {
        if (trace_record.event_kind != .service or
            trace_record.remaining_after != 0)
            continue;
        const item_index = std.math.cast(
            usize,
            trace_record.item_ordinal,
        ) orelse return Error.InvalidExecution;
        if (item_index >= scenario.items.len or
            execution_count >= storage.execution_evidence.len)
            return Error.InvalidExecution;
        const item = scenario.items[item_index];
        const slot = &storage.media_slots[item_index];
        if (!slot.executed or !slot.closed)
            return Error.MissingExecution;
        const output_bytes = std.math.cast(
            usize,
            slot.input.transform_plan.output_bytes,
        ) orelse return Error.InvalidExecution;
        const execution: ExecutionEvidenceV1 = .{
            .ordinal = item.ordinal,
            .kind = item.media_kind,
            .final_trace_index = @intCast(trace_index),
            .driver_step = trace_record.driver_step,
            .service_event_sequence = slot.final_service_event.event_sequence,
            .logical_tick_before = trace_record.logical_tick_before,
            .logical_tick_after = trace_record.logical_tick_after,
            .remaining_before = trace_record.remaining_before,
            .remaining_after = trace_record.remaining_after,
            .wait_quanta = trace_record.wait_quanta,
            .request_epoch = try requestEpochV1(item.ordinal),
            .output_bytes = slot.input.transform_plan.output_bytes,
            .mapping_count = slot.input.transform_plan.logical_units,
            .item_sha256 = workload.itemSha256V1(item),
            .final_trace_sha256 = trace_record.record_sha256,
            .media_state_before_sha256 = slot.media_state_before_sha256,
            .media_state_after_sha256 = slot.media_state_after_sha256,
            .output_sha256 = runtimeDigest(
                slot.output[0..output_bytes],
            ),
            .receipt = slot.execution_receipt,
        };
        storage.execution_evidence[execution_count] = execution;
        storage.execution_evidence[execution_count].record_sha256 =
            try executionRecordRootV1(
                storage.execution_evidence[execution_count],
            );
        execution_count += 1;
    }
    if (execution_count != workload_result.summary.completed)
        return Error.MissingExecution;

    for (
        scenario.items,
        workload_result.outcomes,
        storage.item_evidence[0..scenario.items.len],
        0..,
    ) |item, outcome, *item_evidence, index| {
        const slot = &storage.media_slots[index];
        const admitted = outcome.kind != .rejected;
        if (admitted != slot.admitted or (admitted and !slot.closed))
            return Error.InvalidExecution;
        const execution_index = findExecutionIndex(
            storage.execution_evidence[0..execution_count],
            item.ordinal,
        );
        if ((outcome.kind == .completed) !=
            (execution_index != workload.absent_item))
            return Error.InvalidExecution;
        item_evidence.* = .{
            .ordinal = item.ordinal,
            .kind = item.media_kind,
            .outcome = outcome.kind,
            .terminal_action = outcome.terminal_action,
            .admitted_step = outcome.admitted_step,
            .terminal_step = outcome.terminal_step,
            .execution_index = execution_index,
            .resource_bank_epoch = if (admitted)
                slot.admission_receipt.bank_epoch
            else
                0,
            .resource_slot_index = if (admitted)
                slot.admission_receipt.slot_index
            else
                0,
            .resource_generation = if (admitted)
                slot.admission_receipt.generation
            else
                0,
            .resource_owner_key = if (admitted)
                slot.admission_receipt.owner_key
            else
                0,
            .resource_integrity = if (admitted)
                slot.admission_receipt.integrity
            else
                0,
            .item_sha256 = workload.itemSha256V1(item),
            .admission_trace_sha256 = outcome.admission_trace_sha256,
            .terminal_trace_sha256 = outcome.terminal_trace_sha256,
            .resource_receipt_sha256 = if (admitted)
                qos.resourceReceiptSha256(slot.admission_receipt)
            else
                zero_digest,
        };
        item_evidence.record_sha256 = itemRecordRootV1(item_evidence.*);
    }

    const items = storage.item_evidence[0..scenario.items.len];
    const executions = storage.execution_evidence[0..execution_count];
    var image_executions: u64 = 0;
    var audio_executions: u64 = 0;
    var video_executions: u64 = 0;
    var logical_units: u64 = 0;
    var output_bytes: u64 = 0;
    for (executions) |execution| {
        switch (execution.kind) {
            .image => image_executions += 1,
            .audio => audio_executions += 1,
            .video => video_executions += 1,
        }
        logical_units = try checkedAdd(
            logical_units,
            execution.receipt.logical_units,
        );
        output_bytes = try checkedAdd(output_bytes, execution.output_bytes);
    }
    var summary: SummaryV1 = .{
        .item_count = @intCast(items.len),
        .execution_count = @intCast(executions.len),
        .admitted = workload_result.summary.admitted,
        .rejected = workload_result.summary.rejected,
        .completed = workload_result.summary.completed,
        .cancelled = workload_result.summary.cancelled,
        .timed_out = workload_result.summary.timed_out,
        .image_executions = image_executions,
        .audio_executions = audio_executions,
        .video_executions = video_executions,
        .logical_units = logical_units,
        .output_bytes = output_bytes,
        .publications = @intCast(executions.len),
        .closed_terminal_sessions = workload_result.summary.admitted,
        .maximum_live_receipts = workload_result.summary.maximum_live_receipts,
        .zero_orphan_ownership = workload_result.summary.zero_orphan_ownership,
    };
    summary.summary_sha256 = summaryRootV1(summary);

    var evidence: EvidenceV1 = .{
        .scenario_sha256 = workload_result.scenario_sha256,
        .outcome_sha256 = workload_result.outcome_sha256,
        .trace_sha256 = workload_result.trace_sha256,
        .workload_summary_sha256 = workload_result.summary_sha256,
        .item_section_sha256 = itemSectionRootV1(items),
        .execution_section_sha256 = executionSectionRootV1(executions),
        .evidence_summary_sha256 = summary.summary_sha256,
        .items = items,
        .executions = executions,
        .summary = summary,
        .evidence_sha256 = zero_digest,
    };
    evidence.evidence_sha256 = try evidenceRootV1(evidence);
    try validateEvidenceAgainstScenarioV1(
        scenario,
        workload_result,
        evidence,
        storage.workload_storage,
    );
    return .{
        .workload_result = workload_result,
        .evidence = evidence,
    };
}

pub fn runReferenceScenarioV1(
    storage: *ReferenceStorageV1,
) Error!CampaignV1 {
    const items = workload.makeReferenceItemsV1();
    return runScenarioV1(
        workload.referenceScenarioV1(&items),
        storage.interface(),
    );
}

pub fn itemRecordRootV1(value: ItemEvidenceV1) Digest {
    var body: [item_record_bytes - 32]u8 = undefined;
    writeItemRecordPrefix(value, &body);
    return framedRoot(item_domain, record_frame, &body);
}

pub fn executionRecordRootV1(value: ExecutionEvidenceV1) Error!Digest {
    var body: [execution_record_bytes - 32]u8 = undefined;
    try writeExecutionRecordPrefix(value, &body);
    return framedRoot(execution_domain, record_frame, &body);
}

pub fn summaryRootV1(value: SummaryV1) Digest {
    var body: [summary_record_bytes - 32]u8 = undefined;
    writeSummaryPrefix(value, &body);
    return framedRoot(summary_domain, record_frame, &body);
}

pub fn itemSectionRootV1(items: []const ItemEvidenceV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(item_domain);
    hash.update(section_frame);
    hashU64(&hash, @intCast(items.len));
    for (items) |item| hash.update(&item.record_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn executionSectionRootV1(
    executions: []const ExecutionEvidenceV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(execution_domain);
    hash.update(section_frame);
    hashU64(&hash, @intCast(executions.len));
    for (executions) |execution| hash.update(&execution.record_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn evidenceRootV1(evidence: EvidenceV1) Error!Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(evidence_domain);
    var header: [evidence_header_bytes]u8 = undefined;
    writeEvidenceHeader(evidence, &header);
    hash.update(&header);
    for (evidence.items) |item| {
        var prefix: [item_record_bytes - 32]u8 = undefined;
        writeItemRecordPrefix(item, &prefix);
        hash.update(&prefix);
        hash.update(&item.record_sha256);
    }
    for (evidence.executions) |execution| {
        var prefix: [execution_record_bytes - 32]u8 = undefined;
        try writeExecutionRecordPrefix(execution, &prefix);
        hash.update(&prefix);
        hash.update(&execution.record_sha256);
    }
    var summary_prefix: [summary_record_bytes - 32]u8 = undefined;
    writeSummaryPrefix(evidence.summary, &summary_prefix);
    hash.update(&summary_prefix);
    hash.update(&evidence.summary.summary_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

pub fn encodeEvidenceV1(
    evidence: EvidenceV1,
    destination: []u8,
) Error![]const u8 {
    try validateEvidenceShapeV1(evidence);
    const required = try requiredEvidenceBytesV1(
        evidence.items.len,
        evidence.executions.len,
    );
    if (destination.len < required) return Error.BufferTooSmall;

    const output = destination[0..required];
    @memset(output, 0);
    var header: [evidence_header_bytes]u8 = undefined;
    writeEvidenceHeader(evidence, &header);
    @memcpy(output[0..evidence_header_bytes], &header);

    var offset = evidence_header_bytes;
    for (evidence.items) |item| {
        var prefix: [item_record_bytes - 32]u8 = undefined;
        writeItemRecordPrefix(item, &prefix);
        @memcpy(output[offset..][0 .. item_record_bytes - 32], &prefix);
        @memcpy(
            output[offset + item_record_bytes - 32 ..][0..32],
            &item.record_sha256,
        );
        offset += item_record_bytes;
    }
    for (evidence.executions) |execution| {
        var prefix: [execution_record_bytes - 32]u8 = undefined;
        try writeExecutionRecordPrefix(execution, &prefix);
        @memcpy(
            output[offset..][0 .. execution_record_bytes - 32],
            &prefix,
        );
        @memcpy(
            output[offset + execution_record_bytes - 32 ..][0..32],
            &execution.record_sha256,
        );
        offset += execution_record_bytes;
    }
    var summary_prefix: [summary_record_bytes - 32]u8 = undefined;
    writeSummaryPrefix(evidence.summary, &summary_prefix);
    @memcpy(
        output[offset..][0 .. summary_record_bytes - 32],
        &summary_prefix,
    );
    @memcpy(
        output[offset + summary_record_bytes - 32 ..][0..32],
        &evidence.summary.summary_sha256,
    );
    offset += summary_record_bytes;
    const root = evidenceBodyRoot(output[0..offset]);
    @memcpy(output[offset..][0..32], &root);
    std.debug.assert(offset + evidence_footer_bytes == required);
    return output;
}

pub fn decodeEvidenceV1(
    encoded: []const u8,
    item_storage: []ItemEvidenceV1,
    execution_storage: []ExecutionEvidenceV1,
) Error!EvidenceV1 {
    if (encoded.len < evidence_header_bytes + summary_record_bytes +
        evidence_footer_bytes)
        return Error.InvalidEvidence;
    if (!std.mem.eql(u8, encoded[0..8], &evidence_magic) or
        readU64(encoded, 8) != evidence_abi or
        readU64(encoded, 16) != allowed_flags or
        !allZero(encoded[264..288]))
        return Error.InvalidEvidence;
    const item_count = std.math.cast(usize, readU64(encoded, 24)) orelse
        return Error.InvalidEvidence;
    const execution_count =
        std.math.cast(usize, readU64(encoded, 32)) orelse
        return Error.InvalidEvidence;
    const required = requiredEvidenceBytesV1(
        item_count,
        execution_count,
    ) catch return Error.InvalidEvidence;
    if (encoded.len != required) return Error.InvalidEvidence;
    if (item_storage.len < item_count or
        execution_storage.len < execution_count)
        return Error.BufferTooSmall;

    var decoded_items: [workload.maximum_items]ItemEvidenceV1 = undefined;
    var decoded_executions: [workload.maximum_items]ExecutionEvidenceV1 = undefined;
    const temporary_items = decoded_items[0..item_count];
    const temporary_executions = decoded_executions[0..execution_count];
    var offset = evidence_header_bytes;
    for (temporary_items) |*item| {
        const record = encoded[offset..][0..item_record_bytes];
        if (!allZero(record[224..256])) return Error.InvalidEvidence;
        item.* = .{
            .ordinal = readU64(record, 0),
            .kind = std.meta.intToEnum(
                media.MediaKindV1,
                readU64(record, 8),
            ) catch return Error.InvalidEvidence,
            .outcome = std.meta.intToEnum(
                workload.OutcomeKindV1,
                readU64(record, 16),
            ) catch return Error.InvalidEvidence,
            .terminal_action = std.meta.intToEnum(
                workload.TerminalActionV1,
                readU64(record, 24),
            ) catch return Error.InvalidEvidence,
            .admitted_step = readU64(record, 32),
            .terminal_step = readU64(record, 40),
            .execution_index = readU64(record, 48),
            .resource_bank_epoch = readU64(record, 56),
            .resource_slot_index = readU64(record, 64),
            .resource_generation = readU64(record, 72),
            .resource_owner_key = readU64(record, 80),
            .resource_integrity = readU64(record, 88),
            .item_sha256 = record[96..128].*,
            .admission_trace_sha256 = record[128..160].*,
            .terminal_trace_sha256 = record[160..192].*,
            .resource_receipt_sha256 = record[192..224].*,
            .record_sha256 = record[256..288].*,
        };
        if (!std.mem.eql(
            u8,
            &item.record_sha256,
            &itemRecordRootV1(item.*),
        )) return Error.InvalidEvidence;
        offset += item_record_bytes;
    }
    for (temporary_executions) |*execution| {
        const record = encoded[offset..][0..execution_record_bytes];
        if (!allZero(record[904..960])) return Error.InvalidEvidence;
        execution.* = .{
            .ordinal = readU64(record, 0),
            .kind = std.meta.intToEnum(
                media.MediaKindV1,
                readU64(record, 8),
            ) catch return Error.InvalidEvidence,
            .final_trace_index = readU64(record, 16),
            .driver_step = readU64(record, 24),
            .service_event_sequence = readU64(record, 32),
            .logical_tick_before = readU64(record, 40),
            .logical_tick_after = readU64(record, 48),
            .remaining_before = readU64(record, 56),
            .remaining_after = readU64(record, 64),
            .wait_quanta = readU64(record, 72),
            .request_epoch = readU64(record, 80),
            .output_bytes = readU64(record, 88),
            .mapping_count = readU64(record, 96),
            .item_sha256 = record[104..136].*,
            .final_trace_sha256 = record[136..168].*,
            .media_state_before_sha256 = record[168..200].*,
            .media_state_after_sha256 = record[200..232].*,
            .output_sha256 = record[232..264].*,
            .receipt = runtime.decodeExecutionReceiptV1(
                record[264..904],
            ) catch return Error.InvalidEvidence,
            .record_sha256 = record[960..992].*,
        };
        const expected = executionRecordRootV1(execution.*) catch
            return Error.InvalidEvidence;
        if (!std.mem.eql(u8, &execution.record_sha256, &expected))
            return Error.InvalidEvidence;
        offset += execution_record_bytes;
    }

    const summary_record = encoded[offset..][0..summary_record_bytes];
    const zero_orphan = readU64(summary_record, 120);
    if (zero_orphan > 1) return Error.InvalidEvidence;
    var summary: SummaryV1 = .{
        .item_count = readU64(summary_record, 0),
        .execution_count = readU64(summary_record, 8),
        .admitted = readU64(summary_record, 16),
        .rejected = readU64(summary_record, 24),
        .completed = readU64(summary_record, 32),
        .cancelled = readU64(summary_record, 40),
        .timed_out = readU64(summary_record, 48),
        .image_executions = readU64(summary_record, 56),
        .audio_executions = readU64(summary_record, 64),
        .video_executions = readU64(summary_record, 72),
        .logical_units = readU64(summary_record, 80),
        .output_bytes = readU64(summary_record, 88),
        .publications = readU64(summary_record, 96),
        .closed_terminal_sessions = readU64(summary_record, 104),
        .maximum_live_receipts = readU64(summary_record, 112),
        .zero_orphan_ownership = zero_orphan == 1,
        .summary_sha256 = summary_record[128..160].*,
    };
    if (!std.mem.eql(u8, &summary.summary_sha256, &summaryRootV1(summary)))
        return Error.InvalidEvidence;
    offset += summary_record_bytes;

    const root = encoded[offset..][0..32].*;
    if (!std.mem.eql(u8, &root, &evidenceBodyRoot(encoded[0..offset])))
        return Error.InvalidEvidence;
    const evidence: EvidenceV1 = .{
        .scenario_sha256 = encoded[40..72].*,
        .outcome_sha256 = encoded[72..104].*,
        .trace_sha256 = encoded[104..136].*,
        .workload_summary_sha256 = encoded[136..168].*,
        .item_section_sha256 = encoded[168..200].*,
        .execution_section_sha256 = encoded[200..232].*,
        .evidence_summary_sha256 = encoded[232..264].*,
        .items = temporary_items,
        .executions = temporary_executions,
        .summary = summary,
        .evidence_sha256 = root,
    };
    try validateEvidenceShapeV1(evidence);
    @memcpy(item_storage[0..item_count], temporary_items);
    @memcpy(
        execution_storage[0..execution_count],
        temporary_executions,
    );
    var result = evidence;
    result.items = item_storage[0..item_count];
    result.executions = execution_storage[0..execution_count];
    return result;
}

pub fn validateEvidenceShapeV1(evidence: EvidenceV1) Error!void {
    if (evidence.items.len == 0 or
        evidence.items.len > workload.maximum_items or
        evidence.executions.len > evidence.items.len or
        isZero(evidence.scenario_sha256) or
        isZero(evidence.outcome_sha256) or
        isZero(evidence.trace_sha256) or
        isZero(evidence.workload_summary_sha256) or
        isZero(evidence.item_section_sha256) or
        isZero(evidence.execution_section_sha256) or
        isZero(evidence.evidence_summary_sha256) or
        isZero(evidence.evidence_sha256))
        return Error.InvalidEvidence;

    var admitted: u64 = 0;
    var rejected: u64 = 0;
    var completed: u64 = 0;
    var cancelled: u64 = 0;
    var timed_out: u64 = 0;
    for (evidence.items, 0..) |item, index| {
        if (item.ordinal != index or
            isZero(item.item_sha256) or
            isZero(item.admission_trace_sha256) or
            isZero(item.terminal_trace_sha256) or
            !std.mem.eql(
                u8,
                &item.record_sha256,
                &itemRecordRootV1(item),
            ))
            return Error.InvalidEvidence;
        const has_receipt = item.resource_bank_epoch != 0 and
            item.resource_generation != 0 and
            item.resource_owner_key != 0 and
            item.resource_integrity != 0 and
            !isZero(item.resource_receipt_sha256);
        switch (item.outcome) {
            .rejected => {
                rejected += 1;
                if (item.admitted_step != workload.absent_step or
                    item.execution_index != workload.absent_item or
                    item.terminal_action != .none or has_receipt or
                    item.resource_bank_epoch != 0 or
                    item.resource_slot_index != 0 or
                    item.resource_generation != 0 or
                    item.resource_owner_key != 0 or
                    item.resource_integrity != 0 or
                    !isZero(item.resource_receipt_sha256))
                    return Error.InvalidEvidence;
            },
            .completed => {
                admitted += 1;
                completed += 1;
                if (!has_receipt or item.terminal_action != .none or
                    item.execution_index >= evidence.executions.len)
                    return Error.InvalidEvidence;
            },
            .cancelled => {
                admitted += 1;
                cancelled += 1;
                if (!has_receipt or item.terminal_action != .cancel or
                    item.execution_index != workload.absent_item)
                    return Error.InvalidEvidence;
            },
            .timed_out => {
                admitted += 1;
                timed_out += 1;
                if (!has_receipt or item.terminal_action != .timeout or
                    item.execution_index != workload.absent_item)
                    return Error.InvalidEvidence;
            },
        }
    }

    var image_executions: u64 = 0;
    var audio_executions: u64 = 0;
    var video_executions: u64 = 0;
    var logical_units: u64 = 0;
    var output_bytes: u64 = 0;
    for (evidence.executions, 0..) |execution, index| {
        if (execution.remaining_before != 1 or
            execution.remaining_after != 0 or
            execution.logical_tick_after !=
                try checkedAdd(execution.logical_tick_before, 1) or
            execution.service_event_sequence !=
                execution.final_trace_index or
            execution.request_epoch != try requestEpochV1(execution.ordinal) or
            execution.output_bytes == 0 or execution.mapping_count == 0 or
            isZero(execution.item_sha256) or
            isZero(execution.final_trace_sha256) or
            isZero(execution.media_state_before_sha256) or
            isZero(execution.media_state_after_sha256) or
            isZero(execution.output_sha256) or
            !std.mem.eql(
                u8,
                &execution.record_sha256,
                &(try executionRecordRootV1(execution)),
            ))
            return Error.InvalidEvidence;
        if (execution.ordinal >= evidence.items.len or
            evidence.items[execution.ordinal].execution_index != index or
            evidence.items[execution.ordinal].kind != execution.kind or
            evidence.items[execution.ordinal].outcome != .completed or
            !std.mem.eql(
                u8,
                &evidence.items[execution.ordinal].item_sha256,
                &execution.item_sha256,
            ) or execution.receipt.request_epoch != execution.request_epoch or
            execution.receipt.output_bytes != execution.output_bytes or
            execution.receipt.mapping_count != execution.mapping_count or
            !std.mem.eql(
                u8,
                &execution.receipt.output_sha256,
                &execution.output_sha256,
            ))
            return Error.InvalidEvidence;
        switch (execution.kind) {
            .image => image_executions += 1,
            .audio => audio_executions += 1,
            .video => video_executions += 1,
        }
        logical_units = try checkedAdd(
            logical_units,
            execution.receipt.logical_units,
        );
        output_bytes = try checkedAdd(output_bytes, execution.output_bytes);
    }

    const summary = evidence.summary;
    if (summary.item_count != evidence.items.len or
        summary.execution_count != evidence.executions.len or
        summary.admitted != admitted or summary.rejected != rejected or
        summary.completed != completed or summary.cancelled != cancelled or
        summary.timed_out != timed_out or
        summary.image_executions != image_executions or
        summary.audio_executions != audio_executions or
        summary.video_executions != video_executions or
        summary.logical_units != logical_units or
        summary.output_bytes != output_bytes or
        summary.publications != evidence.executions.len or
        summary.closed_terminal_sessions != admitted or
        !summary.zero_orphan_ownership or
        !std.mem.eql(
            u8,
            &summary.summary_sha256,
            &summaryRootV1(summary),
        ) or
        !std.mem.eql(
            u8,
            &evidence.item_section_sha256,
            &itemSectionRootV1(evidence.items),
        ) or
        !std.mem.eql(
            u8,
            &evidence.execution_section_sha256,
            &executionSectionRootV1(evidence.executions),
        ) or
        !std.mem.eql(
            u8,
            &evidence.evidence_summary_sha256,
            &summary.summary_sha256,
        ) or
        !std.mem.eql(
            u8,
            &evidence.evidence_sha256,
            &(try evidenceRootV1(evidence)),
        ))
        return Error.InvalidEvidence;

    var encoded: [runtime.receipt_bytes]u8 = undefined;
    for (evidence.executions) |execution| {
        _ = runtime.encodeExecutionReceiptV1(
            execution.receipt,
            &encoded,
        ) catch return Error.InvalidEvidence;
    }
}

pub fn validateEvidenceAgainstScenarioV1(
    scenario: workload.ScenarioV1,
    workload_result: workload.ResultV1,
    evidence: EvidenceV1,
    replay_storage: workload.StorageV1,
) Error!void {
    try workload.validateResultByReplayV1(
        scenario,
        workload_result,
        replay_storage,
    );
    try validateEvidenceShapeV1(evidence);
    if (evidence.items.len != scenario.items.len or
        evidence.items.len != workload_result.outcomes.len or
        !std.mem.eql(
            u8,
            &evidence.scenario_sha256,
            &workload_result.scenario_sha256,
        ) or
        !std.mem.eql(
            u8,
            &evidence.outcome_sha256,
            &workload_result.outcome_sha256,
        ) or
        !std.mem.eql(
            u8,
            &evidence.trace_sha256,
            &workload_result.trace_sha256,
        ) or
        !std.mem.eql(
            u8,
            &evidence.workload_summary_sha256,
            &workload_result.summary_sha256,
        ))
        return Error.InvalidEvidence;
    try validateReceiptReplayV1(
        scenario,
        workload_result,
        evidence,
    );

    for (
        scenario.items,
        workload_result.outcomes,
        evidence.items,
    ) |item, outcome, item_evidence| {
        if (item_evidence.ordinal != item.ordinal or
            item_evidence.kind != item.media_kind or
            item_evidence.outcome != outcome.kind or
            item_evidence.terminal_action != outcome.terminal_action or
            item_evidence.admitted_step != outcome.admitted_step or
            item_evidence.terminal_step != outcome.terminal_step or
            !std.mem.eql(
                u8,
                &item_evidence.item_sha256,
                &workload.itemSha256V1(item),
            ) or
            !std.mem.eql(
                u8,
                &item_evidence.admission_trace_sha256,
                &outcome.admission_trace_sha256,
            ) or
            !std.mem.eql(
                u8,
                &item_evidence.terminal_trace_sha256,
                &outcome.terminal_trace_sha256,
            ))
            return Error.InvalidEvidence;
        if (outcome.kind == .rejected) continue;
        const slot_index = std.math.cast(
            u32,
            item_evidence.resource_slot_index,
        ) orelse return Error.InvalidEvidence;
        const receipt: resource_bank.Receipt = .{
            .bank_epoch = item_evidence.resource_bank_epoch,
            .slot_index = slot_index,
            .generation = item_evidence.resource_generation,
            .owner_key = item_evidence.resource_owner_key,
            .claim = item.claim,
            .integrity = item_evidence.resource_integrity,
        };
        if (receipt.bank_epoch != scenario.bank_epoch or
            receipt.owner_key != item.resource_owner_key or
            !resource_bank.receiptIntegrityValidV1(receipt) or
            !std.mem.eql(
                u8,
                &item_evidence.resource_receipt_sha256,
                &qos.resourceReceiptSha256(receipt),
            ))
            return Error.InvalidEvidence;
    }

    for (evidence.executions) |execution| {
        const item_index = std.math.cast(
            usize,
            execution.ordinal,
        ) orelse return Error.InvalidExecution;
        const trace_index = std.math.cast(
            usize,
            execution.final_trace_index,
        ) orelse return Error.InvalidExecution;
        if (item_index >= scenario.items.len or
            trace_index >= workload_result.trace.len)
            return Error.InvalidExecution;
        const item = scenario.items[item_index];
        const item_evidence = evidence.items[item_index];
        const trace_record = workload_result.trace[trace_index];
        if (trace_record.item_ordinal != execution.ordinal or
            trace_record.event_kind != .service or
            trace_record.remaining_before != 1 or
            trace_record.remaining_after != 0 or
            trace_record.driver_step != execution.driver_step or
            trace_record.logical_tick_before !=
                execution.logical_tick_before or
            trace_record.logical_tick_after !=
                execution.logical_tick_after or
            trace_record.wait_quanta != execution.wait_quanta or
            !std.mem.eql(
                u8,
                &trace_record.record_sha256,
                &execution.final_trace_sha256,
            ) or
            execution.service_event_sequence != trace_index)
            return Error.InvalidExecution;

        const receipt = execution.receipt;
        if (receipt.resource_bank_epoch !=
            item_evidence.resource_bank_epoch or
            receipt.resource_slot_index !=
                item_evidence.resource_slot_index or
            receipt.resource_generation !=
                item_evidence.resource_generation or
            receipt.resource_owner_key !=
                item_evidence.resource_owner_key or
            receipt.resource_integrity !=
                item_evidence.resource_integrity or
            !std.meta.eql(receipt.claim, item.claim) or
            receipt.resource_sequence != 0 or receipt.media_sequence != 1)
            return Error.InvalidExecution;

        var input_storage: runtime.ReferenceInputStorageV1 = .{};
        const input = try runtime.prepareReferenceInputV1(
            item.media_kind,
            &input_storage,
        );
        if (input.transform_plan.kind != execution.kind or
            input.transform_plan.output_bytes != execution.output_bytes or
            input.transform_plan.logical_units != execution.mapping_count)
            return Error.InvalidExecution;
        var execution_storage: runtime.ReferenceExecutionStorageV1 = .{};
        const transform_receipt = try transform.executeV1(
            input.encoded_fixture,
            input.encoded_decode_plan,
            input.encoded_transform_plan,
            &execution_storage.decoded_source,
            &execution_storage.output,
            &execution_storage.mappings,
        );
        const output_bytes = std.math.cast(
            usize,
            input.transform_plan.output_bytes,
        ) orelse return Error.InvalidExecution;
        const mapping_count = std.math.cast(
            usize,
            input.transform_plan.logical_units,
        ) orelse return Error.InvalidExecution;
        const output = execution_storage.output[0..output_bytes];
        const mappings = execution_storage.mappings[0..mapping_count];
        if (!std.mem.eql(u8, output, input.expected_output) or
            !std.mem.eql(
                u8,
                &execution.output_sha256,
                &runtimeDigest(output),
            ))
            return Error.InvalidExecution;

        var previous_commit: Digest = undefined;
        @memset(&previous_commit, @intCast(0xa0 + item.ordinal));
        const state_before = try media.initializePublicationStateV1(
            try requestEpochV1(item.ordinal),
            1,
            input.timeline_base,
            input.fixture.media_object_sha256,
            previous_commit,
        );
        if (!std.mem.eql(
            u8,
            &execution.media_state_before_sha256,
            &media.publicationStateRootV1(state_before),
        )) return Error.InvalidExecution;
        try runtime.verifyExecutionReceiptV1(
            state_before,
            input.encoded_fixture,
            input.encoded_transform_plan,
            transform_receipt,
            output,
            mappings,
            receipt,
        );

        const receipt_identity: resource_bank.Receipt = .{
            .bank_epoch = receipt.resource_bank_epoch,
            .slot_index = receipt.resource_slot_index,
            .generation = receipt.resource_generation,
            .owner_key = receipt.resource_owner_key,
            .claim = receipt.claim,
            .integrity = receipt.resource_integrity,
        };
        const plan_sha256 = try transform.transformPlanSha256V1(
            input.encoded_transform_plan,
        );
        const event = try runtime.timelineEventForPlanV1(
            input.transform_plan,
            input.fixture,
            state_before,
            plan_sha256,
        );
        const publication = try media.preparePublicationV1(
            state_before,
            event,
            transform_receipt.output_sha256,
            runtime.resourceCommitmentV1(
                receipt_identity,
                state_before.request_epoch,
                input.fixture.fixture_sha256,
                plan_sha256,
            ),
        );
        var state_after = state_before;
        try media.commitPublicationV1(&state_after, publication);
        if (!std.mem.eql(
            u8,
            &execution.media_state_after_sha256,
            &media.publicationStateRootV1(state_after),
        )) return Error.InvalidExecution;
    }

    const summary = evidence.summary;
    if (summary.admitted != workload_result.summary.admitted or
        summary.rejected != workload_result.summary.rejected or
        summary.completed != workload_result.summary.completed or
        summary.cancelled != workload_result.summary.cancelled or
        summary.timed_out != workload_result.summary.timed_out or
        summary.maximum_live_receipts !=
            workload_result.summary.maximum_live_receipts or
        summary.zero_orphan_ownership !=
            workload_result.summary.zero_orphan_ownership)
        return Error.InvalidEvidence;
}

fn validateReceiptReplayV1(
    scenario: workload.ScenarioV1,
    workload_result: workload.ResultV1,
    evidence: EvidenceV1,
) Error!void {
    const capacity = std.math.cast(usize, scenario.capacity) orelse
        return Error.InvalidEvidence;
    if (capacity == 0 or capacity > workload.maximum_items)
        return Error.InvalidEvidence;
    var live: [workload.maximum_items]?u64 =
        [_]?u64{null} ** workload.maximum_items;
    var next_generation: u64 = 1;
    for (workload_result.trace) |trace_record| {
        switch (trace_record.event_kind) {
            .admission_accepted => {
                const item_index = std.math.cast(
                    usize,
                    trace_record.item_ordinal,
                ) orelse return Error.InvalidEvidence;
                if (item_index >= scenario.items.len)
                    return Error.InvalidEvidence;
                var free_index: ?usize = null;
                for (live[0..capacity], 0..) |entry, index| {
                    if (entry == null) {
                        free_index = index;
                        break;
                    }
                }
                const slot_index = free_index orelse
                    return Error.InvalidEvidence;
                const item = scenario.items[item_index];
                const record = evidence.items[item_index];
                if (record.outcome == .rejected or
                    record.resource_bank_epoch != scenario.bank_epoch or
                    record.resource_slot_index != slot_index or
                    record.resource_generation != next_generation or
                    record.resource_owner_key != item.resource_owner_key)
                    return Error.InvalidEvidence;
                const receipt: resource_bank.Receipt = .{
                    .bank_epoch = scenario.bank_epoch,
                    .slot_index = @intCast(slot_index),
                    .generation = next_generation,
                    .owner_key = item.resource_owner_key,
                    .claim = item.claim,
                    .integrity = record.resource_integrity,
                };
                if (!resource_bank.receiptIntegrityValidV1(receipt) or
                    !std.mem.eql(
                        u8,
                        &record.resource_receipt_sha256,
                        &qos.resourceReceiptSha256(receipt),
                    ))
                    return Error.InvalidEvidence;
                live[slot_index] = item.ordinal;
                next_generation = try checkedAdd(next_generation, 1);
            },
            .service => {
                var found = false;
                for (live[0..capacity]) |entry| {
                    if (entry != null and
                        entry.? == trace_record.item_ordinal)
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) return Error.InvalidEvidence;
            },
            .cancel, .retire => {
                var found_index: ?usize = null;
                for (live[0..capacity], 0..) |entry, index| {
                    if (entry != null and
                        entry.? == trace_record.item_ordinal)
                    {
                        found_index = index;
                        break;
                    }
                }
                live[found_index orelse return Error.InvalidEvidence] = null;
            },
            .admission_rejected => {
                const item_index = std.math.cast(
                    usize,
                    trace_record.item_ordinal,
                ) orelse return Error.InvalidEvidence;
                if (item_index >= evidence.items.len or
                    evidence.items[item_index].outcome != .rejected)
                    return Error.InvalidEvidence;
            },
            .close => {
                for (live[0..capacity]) |entry| {
                    if (entry != null) return Error.InvalidEvidence;
                }
            },
        }
    }
    for (live[0..capacity]) |entry| {
        if (entry != null) return Error.InvalidEvidence;
    }
}

fn writeEvidenceHeader(
    evidence: EvidenceV1,
    output: *[evidence_header_bytes]u8,
) void {
    @memset(output, 0);
    @memcpy(output[0..8], &evidence_magic);
    writeU64(output, 8, evidence_abi);
    writeU64(output, 16, allowed_flags);
    writeU64(output, 24, @intCast(evidence.items.len));
    writeU64(output, 32, @intCast(evidence.executions.len));
    @memcpy(output[40..72], &evidence.scenario_sha256);
    @memcpy(output[72..104], &evidence.outcome_sha256);
    @memcpy(output[104..136], &evidence.trace_sha256);
    @memcpy(output[136..168], &evidence.workload_summary_sha256);
    @memcpy(output[168..200], &evidence.item_section_sha256);
    @memcpy(output[200..232], &evidence.execution_section_sha256);
    @memcpy(output[232..264], &evidence.evidence_summary_sha256);
}

fn framedRoot(
    comptime domain: []const u8,
    comptime frame: []const u8,
    body: []const u8,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(frame);
    hash.update(body);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn evidenceBodyRoot(body: []const u8) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(evidence_domain);
    hash.update(body);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn writeItemRecordPrefix(
    value: ItemEvidenceV1,
    output: *[item_record_bytes - 32]u8,
) void {
    @memset(output, 0);
    writeU64(output, 0, value.ordinal);
    writeU64(output, 8, @intFromEnum(value.kind));
    writeU64(output, 16, @intFromEnum(value.outcome));
    writeU64(output, 24, @intFromEnum(value.terminal_action));
    writeU64(output, 32, value.admitted_step);
    writeU64(output, 40, value.terminal_step);
    writeU64(output, 48, value.execution_index);
    writeU64(output, 56, value.resource_bank_epoch);
    writeU64(output, 64, value.resource_slot_index);
    writeU64(output, 72, value.resource_generation);
    writeU64(output, 80, value.resource_owner_key);
    writeU64(output, 88, value.resource_integrity);
    @memcpy(output[96..128], &value.item_sha256);
    @memcpy(output[128..160], &value.admission_trace_sha256);
    @memcpy(output[160..192], &value.terminal_trace_sha256);
    @memcpy(output[192..224], &value.resource_receipt_sha256);
}

fn writeExecutionRecordPrefix(
    value: ExecutionEvidenceV1,
    output: *[execution_record_bytes - 32]u8,
) Error!void {
    @memset(output, 0);
    writeU64(output, 0, value.ordinal);
    writeU64(output, 8, @intFromEnum(value.kind));
    writeU64(output, 16, value.final_trace_index);
    writeU64(output, 24, value.driver_step);
    writeU64(output, 32, value.service_event_sequence);
    writeU64(output, 40, value.logical_tick_before);
    writeU64(output, 48, value.logical_tick_after);
    writeU64(output, 56, value.remaining_before);
    writeU64(output, 64, value.remaining_after);
    writeU64(output, 72, value.wait_quanta);
    writeU64(output, 80, value.request_epoch);
    writeU64(output, 88, value.output_bytes);
    writeU64(output, 96, value.mapping_count);
    @memcpy(output[104..136], &value.item_sha256);
    @memcpy(output[136..168], &value.final_trace_sha256);
    @memcpy(output[168..200], &value.media_state_before_sha256);
    @memcpy(output[200..232], &value.media_state_after_sha256);
    @memcpy(output[232..264], &value.output_sha256);
    _ = try runtime.encodeExecutionReceiptV1(
        value.receipt,
        output[264..904],
    );
}

fn writeSummaryPrefix(
    value: SummaryV1,
    output: *[summary_record_bytes - 32]u8,
) void {
    @memset(output, 0);
    const fields = [_]u64{
        value.item_count,
        value.execution_count,
        value.admitted,
        value.rejected,
        value.completed,
        value.cancelled,
        value.timed_out,
        value.image_executions,
        value.audio_executions,
        value.video_executions,
        value.logical_units,
        value.output_bytes,
        value.publications,
        value.closed_terminal_sessions,
        value.maximum_live_receipts,
        @intFromBool(value.zero_orphan_ownership),
    };
    for (fields, 0..) |field, index| writeU64(
        output,
        index * @sizeOf(u64),
        field,
    );
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        return Error.ArithmeticOverflow;
}

fn checkedAddUsize(left: usize, right: usize) Error!usize {
    return std.math.add(usize, left, right) catch
        return Error.ArithmeticOverflow;
}

fn checkedMulUsize(left: usize, right: usize) Error!usize {
    return std.math.mul(usize, left, right) catch
        return Error.ArithmeticOverflow;
}

fn writeU64(output: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, output[offset..][0..8], value, .little);
}

fn readU64(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset..][0..8], .little);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn isZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &zero_digest);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn findExecutionIndex(
    executions: []const ExecutionEvidenceV1,
    ordinal: u64,
) u64 {
    for (executions, 0..) |execution, index| {
        if (execution.ordinal == ordinal) return @intCast(index);
    }
    return workload.absent_item;
}

fn runtimeDigest(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn digestFromHex(comptime encoded: *const [64:0]u8) Digest {
    var result: Digest = undefined;
    _ = std.fmt.hexToBytes(&result, encoded) catch unreachable;
    return result;
}

test "scheduled pressure executes audio video and image on final service only" {
    var storage: ReferenceStorageV1 = .{};
    const campaign = try runReferenceScenarioV1(&storage);
    const evidence = campaign.evidence;

    try std.testing.expectEqual(@as(usize, 7), evidence.items.len);
    try std.testing.expectEqual(@as(usize, 3), evidence.executions.len);
    try std.testing.expectEqual(@as(u64, 5), evidence.summary.admitted);
    try std.testing.expectEqual(@as(u64, 2), evidence.summary.rejected);
    try std.testing.expectEqual(@as(u64, 3), evidence.summary.completed);
    try std.testing.expectEqual(@as(u64, 1), evidence.summary.cancelled);
    try std.testing.expectEqual(@as(u64, 1), evidence.summary.timed_out);
    try std.testing.expectEqual(@as(u64, 1), evidence.summary.image_executions);
    try std.testing.expectEqual(@as(u64, 1), evidence.summary.audio_executions);
    try std.testing.expectEqual(@as(u64, 1), evidence.summary.video_executions);
    try std.testing.expectEqual(@as(u64, 7), evidence.summary.logical_units);
    try std.testing.expectEqual(@as(u64, 20), evidence.summary.output_bytes);
    try std.testing.expect(evidence.summary.zero_orphan_ownership);

    try std.testing.expectEqualSlices(
        u8,
        &digestFromHex(
            "3d55ecbeea1a131ed7f6562ec3d33259c157a6cbc3c194cf4f80b2318c73b4e9",
        ),
        &evidence.item_section_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &digestFromHex(
            "46799e4e2b46c3b0152e7784a35389bc790f43999d01095c4467ed153152dd11",
        ),
        &evidence.execution_section_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &digestFromHex(
            "d832947ba869dec833e983178ce0cc67f725cccd783eeb5fbecfa61b2450b027",
        ),
        &evidence.evidence_summary_sha256,
    );
    try std.testing.expectEqualSlices(
        u8,
        &digestFromHex(
            "f6d17a0d6471379c61bd38a5ac255c88f14dfb7585e150cda85b8d04631b880b",
        ),
        &evidence.evidence_sha256,
    );

    const expected_ordinals = [_]u64{ 1, 2, 6 };
    const expected_kinds = [_]media.MediaKindV1{ .audio, .video, .image };
    const expected_trace_indices = [_]u64{ 25, 29, 31 };
    const expected_sequences = [_]u64{ 25, 29, 31 };
    const expected_outputs = [_][]const u8{
        &[_]u8{ 0x00, 0xc0, 0x55, 0x15 },
        &[_]u8{ 0xff, 0x80, 0x40, 0x00 },
        &[_]u8{
            0x00, 0xff, 0x00, 0x00, 0xff, 0x00,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        },
    };
    const expected_receipt_roots = [_]Digest{
        digestFromHex(
            "f8789e249a80bbe29c462358e726a57f2d3245c73fd07787d7e01aabbd7317a4",
        ),
        digestFromHex(
            "395546634b1e05868919934e5e4899efa8c1932f4cd52238daa78efe99c5fd06",
        ),
        digestFromHex(
            "89ee7b79548b56f675c48df63dc3b07b5fd42ddcf04950b76aafad75de336fae",
        ),
    };
    for (
        evidence.executions,
        expected_ordinals,
        expected_kinds,
        expected_trace_indices,
        expected_sequences,
        expected_outputs,
        expected_receipt_roots,
    ) |execution, ordinal, kind, trace_index, sequence, output, receipt_root| {
        try std.testing.expectEqual(ordinal, execution.ordinal);
        try std.testing.expectEqual(kind, execution.kind);
        try std.testing.expectEqual(trace_index, execution.final_trace_index);
        try std.testing.expectEqual(sequence, execution.service_event_sequence);
        try std.testing.expectEqualSlices(
            u8,
            output,
            storage.media_slots[ordinal].output[0..output.len],
        );
        try std.testing.expectEqualSlices(
            u8,
            &receipt_root,
            &execution.receipt.receipt_sha256,
        );
    }

    for (evidence.items) |item| {
        const has_execution = item.ordinal == 1 or
            item.ordinal == 2 or item.ordinal == 6;
        try std.testing.expectEqual(
            has_execution,
            item.execution_index != workload.absent_item,
        );
    }
}

test "scheduled pressure wire round trips and rejects every byte mutation" {
    var storage: ReferenceStorageV1 = .{};
    const campaign = try runReferenceScenarioV1(&storage);
    const required = try requiredEvidenceBytesV1(7, 3);
    try std.testing.expectEqual(@as(usize, 5472), required);
    var encoded: [5472]u8 = undefined;
    const wire = try encodeEvidenceV1(campaign.evidence, &encoded);

    var decoded_items: [workload.maximum_items]ItemEvidenceV1 = undefined;
    var decoded_executions: [workload.maximum_items]ExecutionEvidenceV1 = undefined;
    const decoded = try decodeEvidenceV1(
        wire,
        &decoded_items,
        &decoded_executions,
    );
    const reference_items = workload.makeReferenceItemsV1();
    const reference_scenario = workload.referenceScenarioV1(&reference_items);
    var replay_storage: workload.ReferenceStorageV1 = .{};
    try validateEvidenceAgainstScenarioV1(
        reference_scenario,
        campaign.workload_result,
        decoded,
        replay_storage.interface(),
    );
    try std.testing.expectEqualSlices(
        u8,
        &campaign.evidence.evidence_sha256,
        &decoded.evidence_sha256,
    );

    for (wire, 0..) |_, index| {
        var mutated = encoded;
        mutated[index] ^= 1;
        var items: [workload.maximum_items]ItemEvidenceV1 = undefined;
        var executions: [workload.maximum_items]ExecutionEvidenceV1 = undefined;
        try std.testing.expectError(
            Error.InvalidEvidence,
            decodeEvidenceV1(&mutated, &items, &executions),
        );
    }

    var protected_items: [workload.maximum_items]ItemEvidenceV1 = undefined;
    var protected_executions: [workload.maximum_items]ExecutionEvidenceV1 = undefined;
    @memset(std.mem.asBytes(&protected_items), 0xa5);
    @memset(std.mem.asBytes(&protected_executions), 0x5a);
    var footer_mutation = encoded;
    footer_mutation[footer_mutation.len - 1] ^= 1;
    try std.testing.expectError(
        Error.InvalidEvidence,
        decodeEvidenceV1(
            &footer_mutation,
            &protected_items,
            &protected_executions,
        ),
    );
    try std.testing.expect(std.mem.allEqual(
        u8,
        std.mem.asBytes(&protected_items),
        0xa5,
    ));
    try std.testing.expect(std.mem.allEqual(
        u8,
        std.mem.asBytes(&protected_executions),
        0x5a,
    ));

    var short: [5471]u8 = [_]u8{0xa5} ** 5471;
    try std.testing.expectError(
        Error.BufferTooSmall,
        encodeEvidenceV1(campaign.evidence, &short),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short, 0xa5));
}

test "resealed workload and receipt contradictions reject semantically" {
    var storage: ReferenceStorageV1 = .{};
    var campaign = try runReferenceScenarioV1(&storage);
    const items = workload.makeReferenceItemsV1();
    const scenario = workload.referenceScenarioV1(&items);

    storage.item_evidence[0].terminal_step += 1;
    storage.item_evidence[0].record_sha256 =
        itemRecordRootV1(storage.item_evidence[0]);
    campaign.evidence.item_section_sha256 =
        itemSectionRootV1(campaign.evidence.items);
    campaign.evidence.evidence_sha256 =
        try evidenceRootV1(campaign.evidence);
    try std.testing.expectError(
        Error.InvalidEvidence,
        validateEvidenceAgainstScenarioV1(
            scenario,
            campaign.workload_result,
            campaign.evidence,
            storage.workload_storage.interface(),
        ),
    );

    var second_storage: ReferenceStorageV1 = .{};
    var second = try runReferenceScenarioV1(&second_storage);
    second_storage.execution_evidence[0].request_epoch += 1;
    second_storage.execution_evidence[0].receipt.request_epoch += 1;
    second_storage.execution_evidence[0].receipt.receipt_sha256 =
        runtime.executionReceiptRootV1(
            second_storage.execution_evidence[0].receipt,
        );
    second_storage.execution_evidence[0].record_sha256 =
        try executionRecordRootV1(second_storage.execution_evidence[0]);
    second.evidence.execution_section_sha256 =
        executionSectionRootV1(second.evidence.executions);
    second.evidence.evidence_sha256 =
        try evidenceRootV1(second.evidence);
    try std.testing.expectError(
        Error.InvalidEvidence,
        validateEvidenceAgainstScenarioV1(
            scenario,
            second.workload_result,
            second.evidence,
            second_storage.workload_storage.interface(),
        ),
    );
}

test "receipt replay rejects a valid but foreign slot generation" {
    var storage: ReferenceStorageV1 = .{};
    var campaign = try runReferenceScenarioV1(&storage);
    const items = workload.makeReferenceItemsV1();
    const scenario = workload.referenceScenarioV1(&items);

    var bank_slots: [2]resource_bank.Slot =
        [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &bank_slots,
        scenario.limits,
        scenario.bank_epoch,
    );
    const dummy_reservation = try bank.reserve(
        0xdead,
        .{ .queue_slots = 1 },
    );
    _ = try bank.commit(dummy_reservation);
    const foreign_reservation = try bank.reserve(
        items[0].resource_owner_key,
        items[0].claim,
    );
    const foreign = try bank.commit(foreign_reservation);
    try std.testing.expectEqual(@as(u32, 1), foreign.slot_index);
    try std.testing.expectEqual(@as(u64, 2), foreign.generation);

    storage.item_evidence[0].resource_slot_index = foreign.slot_index;
    storage.item_evidence[0].resource_generation = foreign.generation;
    storage.item_evidence[0].resource_integrity = foreign.integrity;
    storage.item_evidence[0].resource_receipt_sha256 =
        qos.resourceReceiptSha256(foreign);
    storage.item_evidence[0].record_sha256 =
        itemRecordRootV1(storage.item_evidence[0]);
    campaign.evidence.item_section_sha256 =
        itemSectionRootV1(campaign.evidence.items);
    campaign.evidence.evidence_sha256 =
        try evidenceRootV1(campaign.evidence);
    try std.testing.expectError(
        Error.InvalidEvidence,
        validateEvidenceAgainstScenarioV1(
            scenario,
            campaign.workload_result,
            campaign.evidence,
            storage.workload_storage.interface(),
        ),
    );
}

test "failed campaign scrubs address-fenced media sessions" {
    var storage: ReferenceStorageV1 = .{};
    var items = workload.makeReferenceItemsV1();
    var scenario = workload.referenceScenarioV1(&items);
    scenario.max_driver_steps = 10;
    try std.testing.expectError(
        Error.DriverStepLimitExceeded,
        runScenarioV1(scenario, storage.interface()),
    );
    for (storage.media_slots) |slot| {
        try std.testing.expect(!slot.session.initialized);
        try std.testing.expect(!slot.admitted);
        try std.testing.expect(!slot.executed);
        try std.testing.expect(!slot.closed);
        try std.testing.expect(std.mem.allEqual(
            u8,
            &slot.decoded_source,
            0,
        ));
        try std.testing.expect(std.mem.allEqual(u8, &slot.output, 0));
    }
    for (storage.workload_storage.bank_slots) |slot| {
        try std.testing.expect(std.meta.eql(
            slot,
            resource_bank.Slot{},
        ));
    }
}
