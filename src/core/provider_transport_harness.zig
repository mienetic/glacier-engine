//! Credential-free deterministic transport harness for provider adapters.
//!
//! The harness performs no network I/O and stores no prompt, chunk or response
//! bytes. It binds one gateway dispatch intent to a provider-stable request
//! identity, emits deterministic chunk commitments, classifies the terminal
//! transport outcome and bridges that outcome into ExternalTokenGateway.

const std = @import("std");
const gateway = @import("provider_token_gateway.zig");

pub const abi: u64 = 0x4750_5446_0000_0001;
pub const descriptor_abi: u64 = 0x4750_5444_0000_0001;
pub const script_abi: u64 = 0x4750_5453_0000_0001;
pub const handle_abi: u64 = 0x4750_544c_0000_0001;
pub const chunk_abi: u64 = 0x4750_5443_0000_0001;
pub const outcome_abi: u64 = 0x4750_544f_0000_0001;
pub const snapshot_abi: u64 = 0x4750_5450_0000_0001;
pub const cancel_request_abi: u64 = 0x4750_4352_0000_0001;
pub const cancel_ack_abi: u64 = 0x4750_4341_0000_0001;
pub const cancel_outcome_abi: u64 = 0x4750_434f_0000_0001;
pub const cancel_snapshot_abi: u64 = 0x4750_4350_0000_0001;
pub const Digest = gateway.Digest;
pub const zero_digest = gateway.zero_digest;

const descriptor_domain = "glacier-provider-transport-descriptor-v1\x00";
const provider_request_domain = "glacier-provider-request-id-v1\x00";
const script_domain = "glacier-provider-transport-script-v1\x00";
const handle_domain = "glacier-provider-transport-handle-v1\x00";
const initial_response_domain = "glacier-provider-response-chain-v1\x00";
const chunk_payload_domain = "glacier-provider-chunk-payload-v1\x00";
const chunk_chain_domain = "glacier-provider-chunk-chain-v1\x00";
const chunk_evidence_domain = "glacier-provider-chunk-evidence-v1\x00";
const outcome_domain = "glacier-provider-transport-outcome-v1\x00";
const configuration_domain = "glacier-provider-transport-config-v1\x00";
const cancel_request_domain = "glacier-provider-cancel-request-v1\x00";
const cancel_ack_domain = "glacier-provider-cancel-ack-v1\x00";
const cancel_outcome_domain = "glacier-provider-cancel-outcome-v1\x00";

pub const Error = error{
    InvalidConfiguration,
    InvalidDescriptor,
    InvalidScript,
    InvalidHandle,
    InvalidState,
    AttemptConflict,
    CapacityExceeded,
    SequenceExhausted,
    StateDrift,
    InvalidOutcome,
    InvalidCancelRequest,
    InvalidCancelAck,
    InvalidCancelOutcome,
};

pub const capability_streaming: u64 = 1 << 0;
pub const capability_authoritative_usage: u64 = 1 << 1;
pub const capability_retry_classification: u64 = 1 << 2;
pub const capability_idempotency: u64 = 1 << 3;
pub const capability_ambiguous_detection: u64 = 1 << 4;
pub const capability_active_cancellation: u64 = 1 << 5;
pub const required_capabilities: u64 = capability_streaming |
    capability_authoritative_usage |
    capability_retry_classification |
    capability_idempotency |
    capability_ambiguous_detection;
pub const max_supported_chunks: u32 = 4096;

pub const DescriptorV1 = struct {
    abi_version: u64 = descriptor_abi,
    transport_adapter_abi: u64 = 0,
    provider_namespace_sha256: Digest = zero_digest,
    capability_bits: u64 = 0,
    descriptor_sha256: Digest = zero_digest,
};

pub fn makeDescriptorV1(
    transport_adapter_abi: u64,
    provider_namespace_sha256: Digest,
    capability_bits: u64,
) Error!DescriptorV1 {
    var descriptor: DescriptorV1 = .{
        .transport_adapter_abi = transport_adapter_abi,
        .provider_namespace_sha256 = provider_namespace_sha256,
        .capability_bits = capability_bits,
    };
    descriptor.descriptor_sha256 = descriptorSha256(descriptor);
    if (!descriptorValidV1(descriptor)) return Error.InvalidDescriptor;
    return descriptor;
}

pub fn descriptorSha256(descriptor: DescriptorV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(descriptor_domain);
    hashU64(&hash, descriptor.abi_version);
    hashU64(&hash, descriptor.transport_adapter_abi);
    hash.update(&descriptor.provider_namespace_sha256);
    hashU64(&hash, descriptor.capability_bits);
    return finish(&hash);
}

pub fn descriptorValidV1(descriptor: DescriptorV1) bool {
    return descriptor.abi_version == descriptor_abi and
        descriptor.transport_adapter_abi != 0 and
        !isZero(descriptor.provider_namespace_sha256) and
        descriptor.capability_bits & required_capabilities ==
            required_capabilities and std.mem.eql(
        u8,
        &descriptor.descriptor_sha256,
        &descriptorSha256(descriptor),
    );
}

pub const TerminalMode = enum(u8) {
    succeeded,
    retryable_no_charge,
    ambiguous,
};

pub const ScriptV1 = struct {
    abi_version: u64 = script_abi,
    descriptor_sha256: Digest = zero_digest,
    provider_request_sha256: Digest = zero_digest,
    chunk_seed_sha256: Digest = zero_digest,
    chunk_count: u32 = 0,
    terminal_mode: TerminalMode = .succeeded,
    usage: gateway.UsageV1 = .{},
    result_sha256: Digest = zero_digest,
    script_sha256: Digest = zero_digest,
};

pub fn makeScriptV1(
    descriptor: DescriptorV1,
    intent: gateway.DispatchIntentV1,
    chunk_seed_sha256: Digest,
    chunk_count: u32,
    terminal_mode: TerminalMode,
    usage: gateway.UsageV1,
    result_sha256: Digest,
) Error!ScriptV1 {
    if (!descriptorValidV1(descriptor) or
        !gateway.dispatchIntentValidV1(intent))
        return Error.InvalidScript;
    var script: ScriptV1 = .{
        .descriptor_sha256 = descriptor.descriptor_sha256,
        .provider_request_sha256 = providerRequestSha256(
            descriptor,
            intent,
        ),
        .chunk_seed_sha256 = chunk_seed_sha256,
        .chunk_count = chunk_count,
        .terminal_mode = terminal_mode,
        .usage = usage,
        .result_sha256 = result_sha256,
    };
    script.script_sha256 = scriptSha256(script);
    if (!scriptValidV1(script)) return Error.InvalidScript;
    return script;
}

/// Provider idempotency identity intentionally omits attempt generation. A
/// classified retry for the same gateway owner therefore reuses one stable
/// provider request ID instead of manufacturing another billable identity.
pub fn providerRequestSha256(
    descriptor: DescriptorV1,
    intent: gateway.DispatchIntentV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(provider_request_domain);
    hashU64(&hash, descriptor.transport_adapter_abi);
    hash.update(&descriptor.provider_namespace_sha256);
    hashU64(&hash, intent.gateway_epoch);
    hashU32(&hash, intent.owner_slot_index);
    hashU64(&hash, intent.owner_generation);
    hash.update(&intent.request_sha256);
    hash.update(&intent.dispatch_key_sha256);
    return finish(&hash);
}

pub fn scriptSha256(script: ScriptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(script_domain);
    hashU64(&hash, script.abi_version);
    hash.update(&script.descriptor_sha256);
    hash.update(&script.provider_request_sha256);
    hash.update(&script.chunk_seed_sha256);
    hashU32(&hash, script.chunk_count);
    hashU8(&hash, @intFromEnum(script.terminal_mode));
    hashUsage(&hash, script.usage);
    hash.update(&script.result_sha256);
    return finish(&hash);
}

pub fn scriptValidV1(script: ScriptV1) bool {
    if (script.abi_version != script_abi or
        isZero(script.descriptor_sha256) or
        isZero(script.provider_request_sha256) or
        isZero(script.chunk_seed_sha256) or
        !gateway.usageValidV1(script.usage)) return false;
    switch (script.terminal_mode) {
        .succeeded => if (!script.usage.billable_tokens.known or
            isZero(script.result_sha256)) return false,
        .retryable_no_charge => if (!script.usage.billable_tokens.known or
            script.usage.billable_tokens.value != 0 or
            !isZero(script.result_sha256)) return false,
        .ambiguous => if (!isZero(script.result_sha256)) return false,
    }
    return std.mem.eql(
        u8,
        &script.script_sha256,
        &scriptSha256(script),
    );
}

pub const TransportHandleV1 = struct {
    abi_version: u64 = handle_abi,
    harness_epoch: u64 = 0,
    harness_id: usize = 0,
    slot_index: u32 = 0,
    generation: u64 = 0,
    intent_sha256: Digest = zero_digest,
    script_sha256: Digest = zero_digest,
    integrity_sha256: Digest = zero_digest,
};

pub const ChunkV1 = struct {
    abi_version: u64 = chunk_abi,
    intent_sha256: Digest = zero_digest,
    provider_request_sha256: Digest = zero_digest,
    script_sha256: Digest = zero_digest,
    chunk_index: u32 = 0,
    chunk_count: u32 = 0,
    before_chain_sha256: Digest = zero_digest,
    chunk_sha256: Digest = zero_digest,
    after_chain_sha256: Digest = zero_digest,
    evidence_sha256: Digest = zero_digest,
};

pub const OutcomeKind = enum(u8) {
    succeeded,
    retryable_no_charge,
    ambiguous,
};

pub const OutcomeV1 = struct {
    abi_version: u64 = outcome_abi,
    kind: OutcomeKind = .succeeded,
    intent: gateway.DispatchIntentV1 = .{},
    descriptor_sha256: Digest = zero_digest,
    provider_request_sha256: Digest = zero_digest,
    script_sha256: Digest = zero_digest,
    emitted_chunks: u32 = 0,
    response_chain_sha256: Digest = zero_digest,
    usage: gateway.UsageV1 = .{},
    result_sha256: Digest = zero_digest,
    outcome_sha256: Digest = zero_digest,
};

pub const StepV1 = union(enum) {
    chunk: ChunkV1,
    outcome: OutcomeV1,
};

pub const CancelReason = enum(u8) {
    all_consumers_left,
    deadline_expired,
    budget_pressure,
    shutdown,
};

pub const CancelRequestV1 = struct {
    abi_version: u64 = cancel_request_abi,
    intent_sha256: Digest = zero_digest,
    descriptor_sha256: Digest = zero_digest,
    provider_request_sha256: Digest = zero_digest,
    script_sha256: Digest = zero_digest,
    emitted_chunks: u32 = 0,
    response_chain_sha256: Digest = zero_digest,
    reason: CancelReason = .all_consumers_left,
    request_sha256: Digest = zero_digest,
};

pub const CancelAckKind = enum(u8) {
    not_accepted,
    confirmed,
    too_late_succeeded,
    ambiguous,
};

pub const CancelAckV1 = struct {
    abi_version: u64 = cancel_ack_abi,
    cancel_request_sha256: Digest = zero_digest,
    kind: CancelAckKind = .not_accepted,
    usage: gateway.UsageV1 = .{},
    result_sha256: Digest = zero_digest,
    ack_sha256: Digest = zero_digest,
};

pub const CancelOutcomeKind = enum(u8) {
    confirmed,
    too_late_succeeded,
    ambiguous,
};

pub const CancelOutcomeV1 = struct {
    abi_version: u64 = cancel_outcome_abi,
    kind: CancelOutcomeKind = .confirmed,
    intent: gateway.DispatchIntentV1 = .{},
    descriptor_sha256: Digest = zero_digest,
    provider_request_sha256: Digest = zero_digest,
    script_sha256: Digest = zero_digest,
    cancel_request_sha256: Digest = zero_digest,
    cancel_ack_sha256: Digest = zero_digest,
    emitted_chunks: u32 = 0,
    response_chain_sha256: Digest = zero_digest,
    usage: gateway.UsageV1 = .{},
    result_sha256: Digest = zero_digest,
    outcome_sha256: Digest = zero_digest,
};

pub const CancelStartKind = enum(u8) {
    requested,
    existing,
};

pub const CancelStartV1 = struct {
    kind: CancelStartKind,
    request: CancelRequestV1,
};

pub const CancelApplyV1 = union(enum) {
    resumed: TransportHandleV1,
    terminal: CancelOutcomeV1,
};

pub const StartKind = enum(u8) {
    started,
    existing,
};

pub const StartV1 = struct {
    kind: StartKind,
    handle: TransportHandleV1,
};

pub const AttemptState = enum(u8) {
    free,
    streaming,
    cancel_pending,
    complete,
};

pub const AttemptSlot = struct {
    generation: u64 = 0,
    state: AttemptState = .free,
    intent: gateway.DispatchIntentV1 = .{},
    script: ScriptV1 = .{},
    emitted_chunks: u32 = 0,
    response_chain_sha256: Digest = zero_digest,
    outcome: OutcomeV1 = .{},
    cancel_request: CancelRequestV1 = .{},
    cancel_ack: CancelAckV1 = .{},
    cancel_outcome: CancelOutcomeV1 = .{},
};

pub const LedgerV1 = struct {
    active_attempts: u64 = 0,
    completed_unacknowledged: u64 = 0,
    started_attempts: u64 = 0,
    emitted_chunks: u64 = 0,
    successful_outcomes: u64 = 0,
    retryable_outcomes: u64 = 0,
    ambiguous_outcomes: u64 = 0,
    acknowledged_attempts: u64 = 0,
};

pub const CancelLedgerV1 = struct {
    pending_cancellations: u64 = 0,
    requested_cancellations: u64 = 0,
    rejected_cancellations: u64 = 0,
    confirmed_cancellations: u64 = 0,
    too_late_successes: u64 = 0,
    ambiguous_cancellations: u64 = 0,
    known_post_cancel_billable_tokens: u64 = 0,
    unknown_post_cancel_usage: u64 = 0,
};

pub const ConfigV1 = struct {
    harness_epoch: u64 = 0,
    challenge: Digest = zero_digest,
    max_chunks_per_attempt: u32 = 0,
    descriptor: DescriptorV1 = .{},
};

pub const SnapshotV1 = struct {
    abi_version: u64 = snapshot_abi,
    harness_epoch: u64,
    slot_capacity: u32,
    max_chunks_per_attempt: u32,
    ledger: LedgerV1,
};

pub const CancelSnapshotV1 = struct {
    abi_version: u64 = cancel_snapshot_abi,
    harness_epoch: u64,
    ledger: CancelLedgerV1,
};

pub const Harness = struct {
    mutex: std.Thread.Mutex = .{},
    config: ConfigV1 = .{},
    slots: []AttemptSlot = &.{},
    harness_id: usize = 0,
    storage_id: usize = 0,
    slot_capacity: u32 = 0,
    configuration_sha256: Digest = zero_digest,
    initialized: bool = false,
    ledger: LedgerV1 = .{},
    cancel_ledger: CancelLedgerV1 = .{},

    pub fn init(
        self: *Harness,
        slots: []AttemptSlot,
        config: ConfigV1,
    ) Error!void {
        if (self.initialized or !configValid(config) or slots.len == 0 or
            slots.len > std.math.maxInt(u32) or
            storageOverlaps(self, slots)) return Error.InvalidConfiguration;
        for (slots) |*slot| slot.* = .{};
        self.* = .{
            .config = config,
            .slots = slots,
            .harness_id = @intFromPtr(self),
            .storage_id = @intFromPtr(slots.ptr),
            .slot_capacity = @intCast(slots.len),
            .configuration_sha256 = configurationSha256(
                config,
                @intCast(slots.len),
            ),
            .initialized = true,
        };
    }

    pub fn start(
        self: *Harness,
        permit: gateway.DispatchPermitV1,
        script: ScriptV1,
    ) Error!StartV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        if (!permitStructurallyValid(permit) or !scriptValidV1(script) or
            script.chunk_count > self.config.max_chunks_per_attempt or
            !std.mem.eql(
                u8,
                &script.descriptor_sha256,
                &self.config.descriptor.descriptor_sha256,
            ) or !std.mem.eql(
            u8,
            &script.provider_request_sha256,
            &providerRequestSha256(
                self.config.descriptor,
                permit.intent,
            ),
        )) return Error.InvalidScript;

        for (self.slots, 0..) |slot, index| {
            if (slot.state == .free) continue;
            if (std.mem.eql(
                u8,
                &slot.intent.intent_sha256,
                &permit.intent.intent_sha256,
            )) {
                if (!std.mem.eql(
                    u8,
                    &slot.script.script_sha256,
                    &script.script_sha256,
                )) return Error.AttemptConflict;
                return .{
                    .kind = .existing,
                    .handle = self.makeHandle(@intCast(index), slot),
                };
            }
            if (std.mem.eql(
                u8,
                &slot.script.provider_request_sha256,
                &script.provider_request_sha256,
            )) return Error.AttemptConflict;
        }

        const index = self.freeSlotIndex() orelse
            return Error.CapacityExceeded;
        const slot = &self.slots[index];
        const generation = try nextGeneration(slot.generation);
        const active_after = try addU64(
            self.ledger.active_attempts,
            1,
        );
        const started_after = try addU64(
            self.ledger.started_attempts,
            1,
        );
        slot.* = .{
            .generation = generation,
            .state = .streaming,
            .intent = permit.intent,
            .script = script,
            .response_chain_sha256 = initialResponseChainSha256(script),
        };
        self.ledger.active_attempts = active_after;
        self.ledger.started_attempts = started_after;
        return .{
            .kind = .started,
            .handle = self.makeHandle(@intCast(index), slot.*),
        };
    }

    pub fn step(
        self: *Harness,
        handle: TransportHandleV1,
    ) Error!StepV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const slot = try self.validateHandle(handle);
        if (slot.state != .streaming) return Error.InvalidState;
        if (slot.emitted_chunks < slot.script.chunk_count) {
            const chunk = makeChunk(
                slot.intent,
                slot.script,
                slot.emitted_chunks,
                slot.response_chain_sha256,
            );
            if (!chunkMatchesScriptV1(chunk, slot.intent, slot.script))
                return Error.StateDrift;
            const emitted_after = try addU64(
                self.ledger.emitted_chunks,
                1,
            );
            slot.emitted_chunks += 1;
            slot.response_chain_sha256 = chunk.after_chain_sha256;
            self.ledger.emitted_chunks = emitted_after;
            return .{ .chunk = chunk };
        }

        const terminal_outcome = makeOutcome(slot.*);
        if (!outcomeValidV1(terminal_outcome)) return Error.StateDrift;
        var ledger_after = self.ledger;
        ledger_after.active_attempts = try subU64(
            ledger_after.active_attempts,
            1,
        );
        ledger_after.completed_unacknowledged = try addU64(
            ledger_after.completed_unacknowledged,
            1,
        );
        switch (terminal_outcome.kind) {
            .succeeded => ledger_after.successful_outcomes = try addU64(
                ledger_after.successful_outcomes,
                1,
            ),
            .retryable_no_charge => ledger_after.retryable_outcomes =
                try addU64(ledger_after.retryable_outcomes, 1),
            .ambiguous => ledger_after.ambiguous_outcomes = try addU64(
                ledger_after.ambiguous_outcomes,
                1,
            ),
        }
        slot.state = .complete;
        slot.outcome = terminal_outcome;
        self.ledger = ledger_after;
        return .{ .outcome = terminal_outcome };
    }

    /// Requests cancellation at the exact response-chain position currently
    /// held by the attempt. Repeating the same request is idempotent; changing
    /// its reason while an acknowledgement is pending fails closed.
    pub fn requestCancel(
        self: *Harness,
        handle: TransportHandleV1,
        reason: CancelReason,
    ) Error!CancelStartV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const slot = try self.validateHandle(handle);
        if (slot.state == .cancel_pending) {
            if (slot.cancel_request.reason != reason)
                return Error.AttemptConflict;
            return .{
                .kind = .existing,
                .request = slot.cancel_request,
            };
        }
        if (slot.state != .streaming) return Error.InvalidState;
        if (self.config.descriptor.capability_bits &
            capability_active_cancellation == 0)
            return Error.InvalidCancelRequest;

        const request = makeCancelRequest(slot.*, reason);
        if (!cancelRequestMatchesAttemptV1(
            request,
            self.config.descriptor,
            slot.intent,
            slot.script,
        )) return Error.StateDrift;
        var cancel_after = self.cancel_ledger;
        cancel_after.pending_cancellations = try addU64(
            cancel_after.pending_cancellations,
            1,
        );
        cancel_after.requested_cancellations = try addU64(
            cancel_after.requested_cancellations,
            1,
        );
        slot.state = .cancel_pending;
        slot.cancel_request = request;
        self.cancel_ledger = cancel_after;
        return .{ .kind = .requested, .request = request };
    }

    /// Applies one provider acknowledgement. A rejected cancellation resumes
    /// the same attempt and handle. Every other acknowledgement creates a
    /// terminal portable outcome; no normal stream step can win afterwards.
    pub fn applyCancelAck(
        self: *Harness,
        handle: TransportHandleV1,
        ack: CancelAckV1,
    ) Error!CancelApplyV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const slot = try self.validateHandle(handle);
        if (slot.state != .cancel_pending) return Error.InvalidState;
        if (!cancelAckMatchesRequestV1(ack, slot.cancel_request))
            return Error.InvalidCancelAck;

        var cancel_after = self.cancel_ledger;
        cancel_after.pending_cancellations = try subU64(
            cancel_after.pending_cancellations,
            1,
        );
        if (ack.kind == .not_accepted) {
            cancel_after.rejected_cancellations = try addU64(
                cancel_after.rejected_cancellations,
                1,
            );
            slot.state = .streaming;
            slot.cancel_request = .{};
            self.cancel_ledger = cancel_after;
            return .{ .resumed = self.makeHandle(
                handle.slot_index,
                slot.*,
            ) };
        }

        const terminal_outcome = makeCancelOutcome(slot.*, ack);
        if (!cancelOutcomeMatchesAttemptV1(
            terminal_outcome,
            self.config.descriptor,
            slot.intent,
            slot.script,
            slot.cancel_request,
            ack,
        )) return Error.StateDrift;
        var ledger_after = self.ledger;
        ledger_after.active_attempts = try subU64(
            ledger_after.active_attempts,
            1,
        );
        ledger_after.completed_unacknowledged = try addU64(
            ledger_after.completed_unacknowledged,
            1,
        );
        switch (terminal_outcome.kind) {
            .confirmed => cancel_after.confirmed_cancellations = try addU64(
                cancel_after.confirmed_cancellations,
                1,
            ),
            .too_late_succeeded => cancel_after.too_late_successes =
                try addU64(cancel_after.too_late_successes, 1),
            .ambiguous => cancel_after.ambiguous_cancellations = try addU64(
                cancel_after.ambiguous_cancellations,
                1,
            ),
        }
        if (terminal_outcome.usage.billable_tokens.known) {
            cancel_after.known_post_cancel_billable_tokens = try addU64(
                cancel_after.known_post_cancel_billable_tokens,
                terminal_outcome.usage.billable_tokens.value,
            );
        } else {
            cancel_after.unknown_post_cancel_usage = try addU64(
                cancel_after.unknown_post_cancel_usage,
                1,
            );
        }
        slot.state = .complete;
        slot.cancel_ack = ack;
        slot.cancel_outcome = terminal_outcome;
        self.ledger = ledger_after;
        self.cancel_ledger = cancel_after;
        return .{ .terminal = terminal_outcome };
    }

    pub fn outcome(
        self: *Harness,
        handle: TransportHandleV1,
    ) Error!OutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const slot = try self.validateHandle(handle);
        if (slot.state != .complete or !outcomeValidV1(slot.outcome))
            return Error.InvalidState;
        return slot.outcome;
    }

    pub fn cancelOutcome(
        self: *Harness,
        handle: TransportHandleV1,
    ) Error!CancelOutcomeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const slot = try self.validateHandle(handle);
        if (slot.state != .complete or
            !cancelOutcomeMatchesAttemptV1(
                slot.cancel_outcome,
                self.config.descriptor,
                slot.intent,
                slot.script,
                slot.cancel_request,
                slot.cancel_ack,
            )) return Error.InvalidState;
        return slot.cancel_outcome;
    }

    pub fn acknowledge(
        self: *Harness,
        handle: TransportHandleV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const slot = try self.validateHandle(handle);
        if (slot.state != .complete) return Error.InvalidState;
        const complete_after = try subU64(
            self.ledger.completed_unacknowledged,
            1,
        );
        const acknowledged_after = try addU64(
            self.ledger.acknowledged_attempts,
            1,
        );
        const generation = slot.generation;
        slot.* = .{ .generation = generation };
        self.ledger.completed_unacknowledged = complete_after;
        self.ledger.acknowledged_attempts = acknowledged_after;
    }

    pub fn snapshot(self: *Harness) Error!SnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        return self.snapshotLocked();
    }

    pub fn cancelSnapshot(self: *Harness) Error!CancelSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        return .{
            .harness_epoch = self.config.harness_epoch,
            .ledger = self.cancel_ledger,
        };
    }

    pub fn close(self: *Harness) Error!SnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        if (self.ledger.active_attempts != 0 or
            self.ledger.completed_unacknowledged != 0)
            return Error.InvalidState;
        for (self.slots) |slot|
            if (slot.state != .free) return Error.StateDrift;
        const final_snapshot = self.snapshotLocked();
        self.initialized = false;
        return final_snapshot;
    }

    fn requireOpenAndValid(self: *Harness) Error!void {
        if (!self.initialized) return Error.InvalidState;
        if (self.harness_id != @intFromPtr(self)) return Error.StateDrift;
        try self.validateInternal();
    }

    fn validateInternal(self: *Harness) Error!void {
        if (!configValid(self.config) or self.slot_capacity == 0 or
            self.slots.len != @as(usize, self.slot_capacity) or
            self.storage_id != @intFromPtr(self.slots.ptr) or
            storageOverlaps(self, self.slots) or
            !std.mem.eql(
                u8,
                &self.configuration_sha256,
                &configurationSha256(self.config, self.slot_capacity),
            )) return Error.StateDrift;
        var active: u64 = 0;
        var complete: u64 = 0;
        var pending_cancellations: u64 = 0;
        var retained_normal_successes: u64 = 0;
        var retained_normal_retries: u64 = 0;
        var retained_normal_ambiguities: u64 = 0;
        var retained_confirmed_cancellations: u64 = 0;
        var retained_too_late_successes: u64 = 0;
        var retained_ambiguous_cancellations: u64 = 0;
        var retained_known_post_cancel_tokens: u64 = 0;
        var retained_unknown_post_cancel_usage: u64 = 0;
        var retained_emitted_chunks: u64 = 0;
        for (self.slots, 0..) |slot, left_index| {
            if (slot.state == .free) {
                if (!std.meta.eql(slot, AttemptSlot{
                    .generation = slot.generation,
                })) return Error.StateDrift;
                continue;
            }
            if (slot.generation == 0 or
                !gateway.dispatchIntentValidV1(slot.intent) or
                !scriptValidV1(slot.script) or
                slot.script.chunk_count >
                    self.config.max_chunks_per_attempt or
                !std.mem.eql(
                    u8,
                    &slot.script.descriptor_sha256,
                    &self.config.descriptor.descriptor_sha256,
                ) or !std.mem.eql(
                u8,
                &slot.script.provider_request_sha256,
                &providerRequestSha256(
                    self.config.descriptor,
                    slot.intent,
                ),
            ) or slot.emitted_chunks > slot.script.chunk_count or
                !std.mem.eql(
                    u8,
                    &slot.response_chain_sha256,
                    &responseChainSha256(slot.script, slot.emitted_chunks),
                )) return Error.StateDrift;
            retained_emitted_chunks = try addU64(
                retained_emitted_chunks,
                slot.emitted_chunks,
            );
            switch (slot.state) {
                .free => unreachable,
                .streaming => {
                    if (!std.meta.eql(slot.outcome, OutcomeV1{}) or
                        !std.meta.eql(
                            slot.cancel_request,
                            CancelRequestV1{},
                        ) or !std.meta.eql(slot.cancel_ack, CancelAckV1{}) or
                        !std.meta.eql(
                            slot.cancel_outcome,
                            CancelOutcomeV1{},
                        ))
                        return Error.StateDrift;
                    active = try addU64(active, 1);
                },
                .cancel_pending => {
                    if (!std.meta.eql(slot.outcome, OutcomeV1{}) or
                        !std.meta.eql(slot.cancel_ack, CancelAckV1{}) or
                        !std.meta.eql(
                            slot.cancel_outcome,
                            CancelOutcomeV1{},
                        ) or !cancelRequestMatchesAttemptV1(
                        slot.cancel_request,
                        self.config.descriptor,
                        slot.intent,
                        slot.script,
                    )) return Error.StateDrift;
                    active = try addU64(active, 1);
                    pending_cancellations = try addU64(
                        pending_cancellations,
                        1,
                    );
                },
                .complete => {
                    const normal_valid =
                        slot.emitted_chunks == slot.script.chunk_count and
                        outcomeMatchesScriptV1(
                            slot.outcome,
                            self.config.descriptor,
                            slot.script,
                        ) and std.meta.eql(
                            slot.outcome.intent,
                            slot.intent,
                        ) and std.meta.eql(
                            slot.cancel_request,
                            CancelRequestV1{},
                        ) and std.meta.eql(slot.cancel_ack, CancelAckV1{}) and
                        std.meta.eql(
                            slot.cancel_outcome,
                            CancelOutcomeV1{},
                        );
                    const cancel_valid =
                        std.meta.eql(slot.outcome, OutcomeV1{}) and
                        cancelOutcomeMatchesAttemptV1(
                            slot.cancel_outcome,
                            self.config.descriptor,
                            slot.intent,
                            slot.script,
                            slot.cancel_request,
                            slot.cancel_ack,
                        );
                    if (normal_valid == cancel_valid) return Error.StateDrift;
                    if (normal_valid) {
                        switch (slot.outcome.kind) {
                            .succeeded => retained_normal_successes =
                                try addU64(retained_normal_successes, 1),
                            .retryable_no_charge => retained_normal_retries =
                                try addU64(retained_normal_retries, 1),
                            .ambiguous => retained_normal_ambiguities =
                                try addU64(retained_normal_ambiguities, 1),
                        }
                    } else {
                        switch (slot.cancel_outcome.kind) {
                            .confirmed => retained_confirmed_cancellations =
                                try addU64(
                                    retained_confirmed_cancellations,
                                    1,
                                ),
                            .too_late_succeeded => retained_too_late_successes =
                                try addU64(retained_too_late_successes, 1),
                            .ambiguous => retained_ambiguous_cancellations =
                                try addU64(
                                    retained_ambiguous_cancellations,
                                    1,
                                ),
                        }
                        if (slot.cancel_outcome.usage.billable_tokens.known) {
                            retained_known_post_cancel_tokens = try addU64(
                                retained_known_post_cancel_tokens,
                                slot.cancel_outcome.usage.billable_tokens.value,
                            );
                        } else {
                            retained_unknown_post_cancel_usage = try addU64(
                                retained_unknown_post_cancel_usage,
                                1,
                            );
                        }
                    }
                    complete = try addU64(complete, 1);
                },
            }
            for (self.slots[left_index + 1 ..]) |right| {
                if (right.state == .free) continue;
                if (std.mem.eql(
                    u8,
                    &slot.intent.intent_sha256,
                    &right.intent.intent_sha256,
                ) or std.mem.eql(
                    u8,
                    &slot.script.provider_request_sha256,
                    &right.script.provider_request_sha256,
                )) return Error.StateDrift;
            }
        }
        const occupied = std.math.add(u64, active, complete) catch
            return Error.StateDrift;
        const terminal_outcomes = std.math.add(
            u64,
            self.ledger.successful_outcomes,
            self.ledger.retryable_outcomes,
        ) catch return Error.StateDrift;
        const all_terminal_outcomes = std.math.add(
            u64,
            terminal_outcomes,
            self.ledger.ambiguous_outcomes,
        ) catch return Error.StateDrift;
        const partial_cancel_outcomes = std.math.add(
            u64,
            self.cancel_ledger.confirmed_cancellations,
            self.cancel_ledger.too_late_successes,
        ) catch return Error.StateDrift;
        const all_cancel_outcomes = std.math.add(
            u64,
            partial_cancel_outcomes,
            self.cancel_ledger.ambiguous_cancellations,
        ) catch return Error.StateDrift;
        const every_terminal_outcome = std.math.add(
            u64,
            all_terminal_outcomes,
            all_cancel_outcomes,
        ) catch return Error.StateDrift;
        const expected_terminal_outcomes = std.math.add(
            u64,
            complete,
            self.ledger.acknowledged_attempts,
        ) catch return Error.StateDrift;
        const expected_started_attempts = std.math.add(
            u64,
            active,
            expected_terminal_outcomes,
        ) catch return Error.StateDrift;
        const maximum_emitted_chunks = std.math.mul(
            u64,
            self.ledger.started_attempts,
            self.config.max_chunks_per_attempt,
        ) catch return Error.StateDrift;
        const decided_cancel_requests = std.math.add(
            u64,
            self.cancel_ledger.rejected_cancellations,
            all_cancel_outcomes,
        ) catch return Error.StateDrift;
        const expected_cancel_requests = std.math.add(
            u64,
            decided_cancel_requests,
            pending_cancellations,
        ) catch return Error.StateDrift;
        if (active != self.ledger.active_attempts or
            complete != self.ledger.completed_unacknowledged or
            occupied > self.slot_capacity or
            every_terminal_outcome != expected_terminal_outcomes or
            self.ledger.started_attempts != expected_started_attempts or
            pending_cancellations !=
                self.cancel_ledger.pending_cancellations or
            self.cancel_ledger.requested_cancellations !=
                expected_cancel_requests or
            self.ledger.successful_outcomes < retained_normal_successes or
            self.ledger.retryable_outcomes < retained_normal_retries or
            self.ledger.ambiguous_outcomes < retained_normal_ambiguities or
            self.cancel_ledger.confirmed_cancellations <
                retained_confirmed_cancellations or
            self.cancel_ledger.too_late_successes <
                retained_too_late_successes or
            self.cancel_ledger.ambiguous_cancellations <
                retained_ambiguous_cancellations or
            self.cancel_ledger.known_post_cancel_billable_tokens <
                retained_known_post_cancel_tokens or
            self.cancel_ledger.unknown_post_cancel_usage <
                retained_unknown_post_cancel_usage or
            self.cancel_ledger.unknown_post_cancel_usage >
                self.cancel_ledger.ambiguous_cancellations or
            self.ledger.emitted_chunks < retained_emitted_chunks or
            self.ledger.emitted_chunks > maximum_emitted_chunks or
            (self.ledger.acknowledged_attempts == 0 and
                (self.ledger.emitted_chunks != retained_emitted_chunks or
                    self.cancel_ledger.known_post_cancel_billable_tokens !=
                        retained_known_post_cancel_tokens or
                    self.cancel_ledger.unknown_post_cancel_usage !=
                        retained_unknown_post_cancel_usage)))
            return Error.StateDrift;
    }

    fn validateHandle(
        self: *Harness,
        handle: TransportHandleV1,
    ) Error!*AttemptSlot {
        if (!self.handleValid(handle) or handle.slot_index >= self.slots.len)
            return Error.InvalidHandle;
        const slot = &self.slots[handle.slot_index];
        if (slot.state == .free or slot.generation != handle.generation or
            !std.mem.eql(
                u8,
                &slot.intent.intent_sha256,
                &handle.intent_sha256,
            ) or !std.mem.eql(
            u8,
            &slot.script.script_sha256,
            &handle.script_sha256,
        )) return Error.InvalidHandle;
        return slot;
    }

    fn handleValid(self: *Harness, handle: TransportHandleV1) bool {
        return handle.abi_version == handle_abi and
            handle.harness_epoch == self.config.harness_epoch and
            handle.harness_id == @intFromPtr(self) and
            handle.generation != 0 and !isZero(handle.intent_sha256) and
            !isZero(handle.script_sha256) and std.mem.eql(
            u8,
            &handle.integrity_sha256,
            &handleSha256(handle, self.config.challenge),
        );
    }

    fn makeHandle(
        self: *Harness,
        slot_index: u32,
        slot: AttemptSlot,
    ) TransportHandleV1 {
        var handle: TransportHandleV1 = .{
            .harness_epoch = self.config.harness_epoch,
            .harness_id = @intFromPtr(self),
            .slot_index = slot_index,
            .generation = slot.generation,
            .intent_sha256 = slot.intent.intent_sha256,
            .script_sha256 = slot.script.script_sha256,
        };
        handle.integrity_sha256 = handleSha256(
            handle,
            self.config.challenge,
        );
        return handle;
    }

    fn freeSlotIndex(self: *Harness) ?usize {
        for (self.slots, 0..) |slot, index|
            if (slot.state == .free) return index;
        return null;
    }

    fn snapshotLocked(self: *Harness) SnapshotV1 {
        return .{
            .harness_epoch = self.config.harness_epoch,
            .slot_capacity = self.slot_capacity,
            .max_chunks_per_attempt = self.config.max_chunks_per_attempt,
            .ledger = self.ledger,
        };
    }
};

pub fn chunkSha256(
    script: ScriptV1,
    chunk_index: u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(chunk_payload_domain);
    hash.update(&script.chunk_seed_sha256);
    hash.update(&script.provider_request_sha256);
    hashU32(&hash, chunk_index);
    hashU32(&hash, script.chunk_count);
    return finish(&hash);
}

pub fn chunkEvidenceSha256(chunk: ChunkV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(chunk_evidence_domain);
    hashU64(&hash, chunk.abi_version);
    hash.update(&chunk.intent_sha256);
    hash.update(&chunk.provider_request_sha256);
    hash.update(&chunk.script_sha256);
    hashU32(&hash, chunk.chunk_index);
    hashU32(&hash, chunk.chunk_count);
    hash.update(&chunk.before_chain_sha256);
    hash.update(&chunk.chunk_sha256);
    hash.update(&chunk.after_chain_sha256);
    return finish(&hash);
}

pub fn chunkValidV1(chunk: ChunkV1) bool {
    if (chunk.abi_version != chunk_abi or
        chunk.chunk_count == 0 or chunk.chunk_index >= chunk.chunk_count or
        isZero(chunk.intent_sha256) or
        isZero(chunk.provider_request_sha256) or
        isZero(chunk.script_sha256) or isZero(chunk.before_chain_sha256) or
        isZero(chunk.chunk_sha256) or isZero(chunk.after_chain_sha256))
        return false;
    return std.mem.eql(
        u8,
        &chunk.after_chain_sha256,
        &appendResponseChainSha256(
            chunk.before_chain_sha256,
            chunk.chunk_index,
            chunk.chunk_sha256,
        ),
    ) and std.mem.eql(
        u8,
        &chunk.evidence_sha256,
        &chunkEvidenceSha256(chunk),
    );
}

pub fn chunkMatchesScriptV1(
    chunk: ChunkV1,
    intent: gateway.DispatchIntentV1,
    script: ScriptV1,
) bool {
    return chunkValidV1(chunk) and
        gateway.dispatchIntentValidV1(intent) and scriptValidV1(script) and
        std.mem.eql(
            u8,
            &chunk.intent_sha256,
            &intent.intent_sha256,
        ) and std.mem.eql(
        u8,
        &chunk.provider_request_sha256,
        &script.provider_request_sha256,
    ) and std.mem.eql(
        u8,
        &chunk.script_sha256,
        &script.script_sha256,
    ) and chunk.chunk_count == script.chunk_count and
        std.mem.eql(
            u8,
            &chunk.before_chain_sha256,
            &responseChainSha256(script, chunk.chunk_index),
        ) and std.mem.eql(
        u8,
        &chunk.chunk_sha256,
        &chunkSha256(script, chunk.chunk_index),
    );
}

pub fn outcomeSha256(outcome: OutcomeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(outcome_domain);
    hashU64(&hash, outcome.abi_version);
    hashU8(&hash, @intFromEnum(outcome.kind));
    hashIntent(&hash, outcome.intent);
    hash.update(&outcome.descriptor_sha256);
    hash.update(&outcome.provider_request_sha256);
    hash.update(&outcome.script_sha256);
    hashU32(&hash, outcome.emitted_chunks);
    hash.update(&outcome.response_chain_sha256);
    hashUsage(&hash, outcome.usage);
    hash.update(&outcome.result_sha256);
    return finish(&hash);
}

pub fn outcomeValidV1(outcome: OutcomeV1) bool {
    if (outcome.abi_version != outcome_abi or
        !gateway.dispatchIntentValidV1(outcome.intent) or
        isZero(outcome.descriptor_sha256) or
        isZero(outcome.provider_request_sha256) or
        isZero(outcome.script_sha256) or
        isZero(outcome.response_chain_sha256) or
        !gateway.usageValidV1(outcome.usage)) return false;
    switch (outcome.kind) {
        .succeeded => if (!outcome.usage.billable_tokens.known or
            isZero(outcome.result_sha256)) return false,
        .retryable_no_charge => if (!outcome.usage.billable_tokens.known or
            outcome.usage.billable_tokens.value != 0 or
            !isZero(outcome.result_sha256)) return false,
        .ambiguous => if (!isZero(outcome.result_sha256)) return false,
    }
    return std.mem.eql(
        u8,
        &outcome.outcome_sha256,
        &outcomeSha256(outcome),
    );
}

pub fn outcomeMatchesScriptV1(
    outcome: OutcomeV1,
    descriptor: DescriptorV1,
    script: ScriptV1,
) bool {
    if (!outcomeValidV1(outcome) or !descriptorValidV1(descriptor) or
        !scriptValidV1(script)) return false;
    const expected_kind: OutcomeKind = switch (script.terminal_mode) {
        .succeeded => .succeeded,
        .retryable_no_charge => .retryable_no_charge,
        .ambiguous => .ambiguous,
    };
    return outcome.kind == expected_kind and
        std.mem.eql(
            u8,
            &outcome.descriptor_sha256,
            &descriptor.descriptor_sha256,
        ) and std.mem.eql(
        u8,
        &script.descriptor_sha256,
        &descriptor.descriptor_sha256,
    ) and std.mem.eql(
        u8,
        &outcome.provider_request_sha256,
        &providerRequestSha256(descriptor, outcome.intent),
    ) and std.mem.eql(
        u8,
        &outcome.provider_request_sha256,
        &script.provider_request_sha256,
    ) and std.mem.eql(
        u8,
        &outcome.script_sha256,
        &script.script_sha256,
    ) and outcome.emitted_chunks == script.chunk_count and
        std.mem.eql(
            u8,
            &outcome.response_chain_sha256,
            &responseChainSha256(script, script.chunk_count),
        ) and std.meta.eql(outcome.usage, script.usage) and
        std.mem.eql(u8, &outcome.result_sha256, &script.result_sha256);
}

/// Applies a verified transport classification to the address-bound gateway
/// permit. Re-applying the same portable outcome fails at the gateway because
/// the first application consumes or transitions the permit state.
pub fn applyOutcome(
    target: *gateway.Gateway,
    permit: gateway.DispatchPermitV1,
    descriptor: DescriptorV1,
    script: ScriptV1,
    outcome: OutcomeV1,
) !gateway.AttemptResultV2 {
    if (!permitStructurallyValid(permit) or
        !outcomeMatchesScriptV1(outcome, descriptor, script) or
        !std.meta.eql(permit.intent, outcome.intent))
        return Error.InvalidOutcome;
    return switch (outcome.kind) {
        .succeeded => target.settleSuccess(
            permit,
            outcome.usage,
            outcome.result_sha256,
        ),
        .retryable_no_charge => target.retryNoCharge(
            permit,
            outcome.usage,
        ),
        .ambiguous => target.markAmbiguous(permit, outcome.usage),
    };
}

pub fn cancelRequestSha256(request: CancelRequestV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(cancel_request_domain);
    hashU64(&hash, request.abi_version);
    hash.update(&request.intent_sha256);
    hash.update(&request.descriptor_sha256);
    hash.update(&request.provider_request_sha256);
    hash.update(&request.script_sha256);
    hashU32(&hash, request.emitted_chunks);
    hash.update(&request.response_chain_sha256);
    hashU8(&hash, @intFromEnum(request.reason));
    return finish(&hash);
}

pub fn cancelRequestValidV1(request: CancelRequestV1) bool {
    return request.abi_version == cancel_request_abi and
        !isZero(request.intent_sha256) and
        !isZero(request.descriptor_sha256) and
        !isZero(request.provider_request_sha256) and
        !isZero(request.script_sha256) and
        !isZero(request.response_chain_sha256) and std.mem.eql(
        u8,
        &request.request_sha256,
        &cancelRequestSha256(request),
    );
}

pub fn cancelRequestMatchesAttemptV1(
    request: CancelRequestV1,
    descriptor: DescriptorV1,
    intent: gateway.DispatchIntentV1,
    script: ScriptV1,
) bool {
    return cancelRequestValidV1(request) and
        descriptorValidV1(descriptor) and
        descriptor.capability_bits & capability_active_cancellation != 0 and
        gateway.dispatchIntentValidV1(intent) and scriptValidV1(script) and
        request.emitted_chunks <= script.chunk_count and std.mem.eql(
        u8,
        &request.intent_sha256,
        &intent.intent_sha256,
    ) and std.mem.eql(
        u8,
        &request.descriptor_sha256,
        &descriptor.descriptor_sha256,
    ) and std.mem.eql(
        u8,
        &script.descriptor_sha256,
        &descriptor.descriptor_sha256,
    ) and std.mem.eql(
        u8,
        &request.provider_request_sha256,
        &providerRequestSha256(descriptor, intent),
    ) and std.mem.eql(
        u8,
        &request.provider_request_sha256,
        &script.provider_request_sha256,
    ) and std.mem.eql(
        u8,
        &request.script_sha256,
        &script.script_sha256,
    ) and std.mem.eql(
        u8,
        &request.response_chain_sha256,
        &responseChainSha256(script, request.emitted_chunks),
    );
}

pub fn makeCancelAckV1(
    request: CancelRequestV1,
    kind: CancelAckKind,
    usage: gateway.UsageV1,
    result_sha256: Digest,
) Error!CancelAckV1 {
    if (!cancelRequestValidV1(request)) return Error.InvalidCancelAck;
    var ack: CancelAckV1 = .{
        .cancel_request_sha256 = request.request_sha256,
        .kind = kind,
        .usage = usage,
        .result_sha256 = result_sha256,
    };
    ack.ack_sha256 = cancelAckSha256(ack);
    if (!cancelAckValidV1(ack)) return Error.InvalidCancelAck;
    return ack;
}

pub fn cancelAckSha256(ack: CancelAckV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(cancel_ack_domain);
    hashU64(&hash, ack.abi_version);
    hash.update(&ack.cancel_request_sha256);
    hashU8(&hash, @intFromEnum(ack.kind));
    hashUsage(&hash, ack.usage);
    hash.update(&ack.result_sha256);
    return finish(&hash);
}

pub fn cancelAckValidV1(ack: CancelAckV1) bool {
    if (ack.abi_version != cancel_ack_abi or
        isZero(ack.cancel_request_sha256) or
        !gateway.usageValidV1(ack.usage)) return false;
    switch (ack.kind) {
        .not_accepted => if (!ack.usage.billable_tokens.known or
            ack.usage.billable_tokens.value != 0 or
            usageHasKnownNonZero(ack.usage) or
            !isZero(ack.result_sha256)) return false,
        .confirmed => if (!ack.usage.billable_tokens.known or
            !isZero(ack.result_sha256)) return false,
        .too_late_succeeded => if (!ack.usage.billable_tokens.known or
            isZero(ack.result_sha256)) return false,
        .ambiguous => if (!isZero(ack.result_sha256)) return false,
    }
    return std.mem.eql(u8, &ack.ack_sha256, &cancelAckSha256(ack));
}

pub fn cancelAckMatchesRequestV1(
    ack: CancelAckV1,
    request: CancelRequestV1,
) bool {
    return cancelAckValidV1(ack) and cancelRequestValidV1(request) and
        std.mem.eql(
            u8,
            &ack.cancel_request_sha256,
            &request.request_sha256,
        );
}

pub fn cancelOutcomeSha256(outcome: CancelOutcomeV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(cancel_outcome_domain);
    hashU64(&hash, outcome.abi_version);
    hashU8(&hash, @intFromEnum(outcome.kind));
    hashIntent(&hash, outcome.intent);
    hash.update(&outcome.descriptor_sha256);
    hash.update(&outcome.provider_request_sha256);
    hash.update(&outcome.script_sha256);
    hash.update(&outcome.cancel_request_sha256);
    hash.update(&outcome.cancel_ack_sha256);
    hashU32(&hash, outcome.emitted_chunks);
    hash.update(&outcome.response_chain_sha256);
    hashUsage(&hash, outcome.usage);
    hash.update(&outcome.result_sha256);
    return finish(&hash);
}

pub fn cancelOutcomeValidV1(outcome: CancelOutcomeV1) bool {
    if (outcome.abi_version != cancel_outcome_abi or
        !gateway.dispatchIntentValidV1(outcome.intent) or
        isZero(outcome.descriptor_sha256) or
        isZero(outcome.provider_request_sha256) or
        isZero(outcome.script_sha256) or
        isZero(outcome.cancel_request_sha256) or
        isZero(outcome.cancel_ack_sha256) or
        isZero(outcome.response_chain_sha256) or
        !gateway.usageValidV1(outcome.usage)) return false;
    switch (outcome.kind) {
        .confirmed => if (!outcome.usage.billable_tokens.known or
            !isZero(outcome.result_sha256)) return false,
        .too_late_succeeded => if (!outcome.usage.billable_tokens.known or
            isZero(outcome.result_sha256)) return false,
        .ambiguous => if (!isZero(outcome.result_sha256)) return false,
    }
    return std.mem.eql(
        u8,
        &outcome.outcome_sha256,
        &cancelOutcomeSha256(outcome),
    );
}

pub fn cancelOutcomeMatchesAttemptV1(
    outcome: CancelOutcomeV1,
    descriptor: DescriptorV1,
    intent: gateway.DispatchIntentV1,
    script: ScriptV1,
    request: CancelRequestV1,
    ack: CancelAckV1,
) bool {
    if (!cancelOutcomeValidV1(outcome) or
        !cancelRequestMatchesAttemptV1(
            request,
            descriptor,
            intent,
            script,
        ) or !cancelAckMatchesRequestV1(ack, request) or
        ack.kind == .not_accepted) return false;
    const expected_kind: CancelOutcomeKind = switch (ack.kind) {
        .not_accepted => unreachable,
        .confirmed => .confirmed,
        .too_late_succeeded => .too_late_succeeded,
        .ambiguous => .ambiguous,
    };
    return outcome.kind == expected_kind and
        std.meta.eql(outcome.intent, intent) and std.mem.eql(
        u8,
        &outcome.descriptor_sha256,
        &descriptor.descriptor_sha256,
    ) and std.mem.eql(
        u8,
        &outcome.provider_request_sha256,
        &script.provider_request_sha256,
    ) and std.mem.eql(
        u8,
        &outcome.script_sha256,
        &script.script_sha256,
    ) and std.mem.eql(
        u8,
        &outcome.cancel_request_sha256,
        &request.request_sha256,
    ) and std.mem.eql(
        u8,
        &outcome.cancel_ack_sha256,
        &ack.ack_sha256,
    ) and outcome.emitted_chunks == request.emitted_chunks and std.mem.eql(
        u8,
        &outcome.response_chain_sha256,
        &request.response_chain_sha256,
    ) and std.meta.eql(outcome.usage, ack.usage) and
        std.mem.eql(u8, &outcome.result_sha256, &ack.result_sha256);
}

/// Bridges verified cancellation evidence into the original Gateway permit.
/// A confirmed stop becomes a terminal failure with authoritative partial
/// usage, a too-late success publishes its result, and uncertainty retains the
/// reservation through the Gateway ambiguous state.
pub fn applyCancelOutcome(
    target: *gateway.Gateway,
    permit: gateway.DispatchPermitV1,
    descriptor: DescriptorV1,
    script: ScriptV1,
    request: CancelRequestV1,
    ack: CancelAckV1,
    outcome: CancelOutcomeV1,
) !gateway.AttemptResultV2 {
    if (!permitStructurallyValid(permit) or
        !cancelOutcomeMatchesAttemptV1(
            outcome,
            descriptor,
            permit.intent,
            script,
            request,
            ack,
        )) return Error.InvalidCancelOutcome;
    return switch (outcome.kind) {
        .confirmed => target.settleFailure(permit, outcome.usage),
        .too_late_succeeded => target.settleSuccess(
            permit,
            outcome.usage,
            outcome.result_sha256,
        ),
        .ambiguous => target.markAmbiguous(permit, outcome.usage),
    };
}

fn makeChunk(
    intent: gateway.DispatchIntentV1,
    script: ScriptV1,
    chunk_index: u32,
    before_chain_sha256: Digest,
) ChunkV1 {
    const chunk_sha256 = chunkSha256(script, chunk_index);
    var chunk: ChunkV1 = .{
        .intent_sha256 = intent.intent_sha256,
        .provider_request_sha256 = script.provider_request_sha256,
        .script_sha256 = script.script_sha256,
        .chunk_index = chunk_index,
        .chunk_count = script.chunk_count,
        .before_chain_sha256 = before_chain_sha256,
        .chunk_sha256 = chunk_sha256,
        .after_chain_sha256 = appendResponseChainSha256(
            before_chain_sha256,
            chunk_index,
            chunk_sha256,
        ),
    };
    chunk.evidence_sha256 = chunkEvidenceSha256(chunk);
    return chunk;
}

fn makeCancelRequest(
    slot: AttemptSlot,
    reason: CancelReason,
) CancelRequestV1 {
    var request: CancelRequestV1 = .{
        .intent_sha256 = slot.intent.intent_sha256,
        .descriptor_sha256 = slot.script.descriptor_sha256,
        .provider_request_sha256 = slot.script.provider_request_sha256,
        .script_sha256 = slot.script.script_sha256,
        .emitted_chunks = slot.emitted_chunks,
        .response_chain_sha256 = slot.response_chain_sha256,
        .reason = reason,
    };
    request.request_sha256 = cancelRequestSha256(request);
    return request;
}

fn makeCancelOutcome(
    slot: AttemptSlot,
    ack: CancelAckV1,
) CancelOutcomeV1 {
    var outcome: CancelOutcomeV1 = .{
        .kind = switch (ack.kind) {
            .not_accepted => unreachable,
            .confirmed => .confirmed,
            .too_late_succeeded => .too_late_succeeded,
            .ambiguous => .ambiguous,
        },
        .intent = slot.intent,
        .descriptor_sha256 = slot.script.descriptor_sha256,
        .provider_request_sha256 = slot.script.provider_request_sha256,
        .script_sha256 = slot.script.script_sha256,
        .cancel_request_sha256 = slot.cancel_request.request_sha256,
        .cancel_ack_sha256 = ack.ack_sha256,
        .emitted_chunks = slot.emitted_chunks,
        .response_chain_sha256 = slot.response_chain_sha256,
        .usage = ack.usage,
        .result_sha256 = ack.result_sha256,
    };
    outcome.outcome_sha256 = cancelOutcomeSha256(outcome);
    return outcome;
}

fn makeOutcome(slot: AttemptSlot) OutcomeV1 {
    var outcome: OutcomeV1 = .{
        .kind = switch (slot.script.terminal_mode) {
            .succeeded => .succeeded,
            .retryable_no_charge => .retryable_no_charge,
            .ambiguous => .ambiguous,
        },
        .intent = slot.intent,
        .descriptor_sha256 = slot.script.descriptor_sha256,
        .provider_request_sha256 = slot.script.provider_request_sha256,
        .script_sha256 = slot.script.script_sha256,
        .emitted_chunks = slot.emitted_chunks,
        .response_chain_sha256 = slot.response_chain_sha256,
        .usage = slot.script.usage,
        .result_sha256 = slot.script.result_sha256,
    };
    outcome.outcome_sha256 = outcomeSha256(outcome);
    return outcome;
}

fn initialResponseChainSha256(script: ScriptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(initial_response_domain);
    hash.update(&script.descriptor_sha256);
    hash.update(&script.provider_request_sha256);
    hash.update(&script.script_sha256);
    return finish(&hash);
}

fn appendResponseChainSha256(
    before_sha256: Digest,
    chunk_index: u32,
    chunk_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(chunk_chain_domain);
    hash.update(&before_sha256);
    hashU32(&hash, chunk_index);
    hash.update(&chunk_sha256);
    return finish(&hash);
}

fn responseChainSha256(script: ScriptV1, emitted_chunks: u32) Digest {
    var chain = initialResponseChainSha256(script);
    var index: u32 = 0;
    while (index < emitted_chunks) : (index += 1) {
        chain = appendResponseChainSha256(
            chain,
            index,
            chunkSha256(script, index),
        );
    }
    return chain;
}

fn permitStructurallyValid(permit: gateway.DispatchPermitV1) bool {
    return permit.abi_version == gateway.dispatch_permit_abi and
        permit.gateway_id != 0 and
        gateway.dispatchIntentValidV1(permit.intent) and
        !isZero(permit.integrity_sha256);
}

fn configValid(config: ConfigV1) bool {
    return config.harness_epoch != 0 and !isZero(config.challenge) and
        config.max_chunks_per_attempt != 0 and
        config.max_chunks_per_attempt <= max_supported_chunks and
        descriptorValidV1(config.descriptor);
}

fn configurationSha256(config: ConfigV1, slot_capacity: u32) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(configuration_domain);
    hashU64(&hash, abi);
    hashU64(&hash, descriptor_abi);
    hashU64(&hash, script_abi);
    hashU64(&hash, handle_abi);
    hashU64(&hash, chunk_abi);
    hashU64(&hash, outcome_abi);
    hashU64(&hash, snapshot_abi);
    hashU64(&hash, config.harness_epoch);
    hash.update(&config.challenge);
    hashU32(&hash, config.max_chunks_per_attempt);
    hash.update(&config.descriptor.descriptor_sha256);
    hashU32(&hash, slot_capacity);
    return finish(&hash);
}

fn handleSha256(handle: TransportHandleV1, challenge: Digest) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(handle_domain);
    hashU64(&hash, handle.abi_version);
    hashU64(&hash, handle.harness_epoch);
    hashU64(&hash, @intCast(handle.harness_id));
    hashU32(&hash, handle.slot_index);
    hashU64(&hash, handle.generation);
    hash.update(&handle.intent_sha256);
    hash.update(&handle.script_sha256);
    hash.update(&challenge);
    return finish(&hash);
}

fn nextGeneration(current: u64) Error!u64 {
    if (current == std.math.maxInt(u64)) return Error.SequenceExhausted;
    const next = current + 1;
    if (next == 0) return Error.SequenceExhausted;
    return next;
}

fn addU64(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch Error.SequenceExhausted;
}

fn subU64(left: u64, right: u64) Error!u64 {
    return std.math.sub(u64, left, right) catch Error.StateDrift;
}

fn storageOverlaps(self: *Harness, slots: []AttemptSlot) bool {
    const self_start = @intFromPtr(self);
    const self_end = std.math.add(usize, self_start, @sizeOf(Harness)) catch
        return true;
    const slot_start = @intFromPtr(slots.ptr);
    const slot_bytes = std.math.mul(
        usize,
        slots.len,
        @sizeOf(AttemptSlot),
    ) catch return true;
    const slot_end = std.math.add(usize, slot_start, slot_bytes) catch
        return true;
    return self_start < slot_end and slot_start < self_end;
}

fn hashIntent(
    hash: *std.crypto.hash.sha2.Sha256,
    intent: gateway.DispatchIntentV1,
) void {
    hashU64(hash, intent.abi_version);
    hashU64(hash, intent.gateway_epoch);
    hashU32(hash, intent.owner_slot_index);
    hashU64(hash, intent.owner_generation);
    hashU64(hash, intent.attempt_generation);
    hash.update(&intent.request_sha256);
    hash.update(&intent.dispatch_key_sha256);
    hashU64(hash, intent.reserved_tokens);
    hash.update(&intent.previous_event_chain_sha256);
    hash.update(&intent.intent_sha256);
}

fn hashUsage(
    hash: *std.crypto.hash.sha2.Sha256,
    usage: gateway.UsageV1,
) void {
    hashU64(hash, usage.abi_version);
    inline for (.{
        usage.input_tokens,
        usage.output_tokens,
        usage.cached_input_tokens,
        usage.reasoning_tokens,
        usage.retry_tokens,
        usage.billable_tokens,
    }) |count| {
        hashU8(hash, @intFromBool(count.known));
        hashU64(hash, count.value);
    }
    hash.update(&usage.usage_sha256);
}

fn usageHasKnownNonZero(usage: gateway.UsageV1) bool {
    inline for (.{
        usage.input_tokens,
        usage.output_tokens,
        usage.cached_input_tokens,
        usage.reasoning_tokens,
        usage.retry_tokens,
        usage.billable_tokens,
    }) |count| if (count.known and count.value != 0) return true;
    return false;
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&.{value});
}

fn hashU32(hash: *std.crypto.hash.sha2.Sha256, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn isZero(digest: Digest) bool {
    return std.mem.eql(u8, &digest, &zero_digest);
}

fn testDigest(seed: u8) Digest {
    var digest: Digest = undefined;
    @memset(&digest, seed);
    return digest;
}

fn testDescriptor() !DescriptorV1 {
    return makeDescriptorV1(
        0x5445_5354_4144_5001,
        testDigest(0x91),
        required_capabilities,
    );
}

fn testCancelDescriptor() !DescriptorV1 {
    return makeDescriptorV1(
        0x5445_5354_4144_5001,
        testDigest(0x91),
        required_capabilities | capability_active_cancellation,
    );
}

fn testGatewayConfig() gateway.ConfigV1 {
    return .{
        .gateway_epoch = 0x5452_414e_5350_0001,
        .challenge = testDigest(0xa1),
        .limits = .{
            .max_reserved_tokens = 1_000,
            .max_reserved_tokens_per_isolation = 1_000,
            .max_request_tokens = 500,
            .max_followers_per_owner = 2,
        },
    };
}

fn testHarnessConfig(descriptor: DescriptorV1) ConfigV1 {
    return .{
        .harness_epoch = 0x5452_414e_5350_0002,
        .challenge = testDigest(0xa2),
        .max_chunks_per_attempt = 16,
        .descriptor = descriptor,
    };
}

fn testRequest(request_key: u64) !gateway.RequestV1 {
    return gateway.makeRequestV1(
        0x5445_5354_4144_5001,
        77,
        request_key,
        1,
        testDigest(0x11),
        testDigest(0x22),
        testDigest(0x33),
        testDigest(0x44),
        testDigest(0x55),
        100,
        50,
        .in_flight,
    );
}

const StartWorker = struct {
    harness: *Harness,
    permit: gateway.DispatchPermitV1,
    script: ScriptV1,
    result: ?StartV1 = null,
    failure: ?Error = null,

    fn run(self: *@This()) void {
        self.result = self.harness.start(
            self.permit,
            self.script,
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const CancelRequestWorker = struct {
    harness: *Harness,
    handle: TransportHandleV1,
    reason: CancelReason,
    result: ?CancelStartV1 = null,
    failure: ?Error = null,

    fn run(self: *@This()) void {
        self.result = self.harness.requestCancel(
            self.handle,
            self.reason,
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const StepWorker = struct {
    harness: *Harness,
    handle: TransportHandleV1,
    result: ?StepV1 = null,
    failure: ?Error = null,

    fn run(self: *@This()) void {
        self.result = self.harness.step(self.handle) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "deterministic chunks settle one successful gateway dispatch" {
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(1));
    const dispatch = try token_gateway.beginDispatch(admission.handle);

    const descriptor = try testDescriptor();
    var attempt_slots: [2]AttemptSlot = [_]AttemptSlot{.{}} ** 2;
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );
    const usage = try gateway.makeUsageV1(100, 20, 40, 8, 0, 80);
    const script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x61),
        3,
        .succeeded,
        usage,
        testDigest(0x71),
    );
    const started = try harness.start(dispatch.permit, script);
    try std.testing.expectEqual(StartKind.started, started.kind);
    try std.testing.expectError(
        Error.InvalidCancelRequest,
        harness.requestCancel(started.handle, .deadline_expired),
    );
    const existing = try harness.start(dispatch.permit, script);
    try std.testing.expectEqual(StartKind.existing, existing.kind);
    try std.testing.expectEqual(started.handle, existing.handle);

    var previous_chain = initialResponseChainSha256(script);
    var index: u32 = 0;
    while (index < script.chunk_count) : (index += 1) {
        const chunk = switch (try harness.step(started.handle)) {
            .chunk => |value| value,
            .outcome => return error.UnexpectedOutcome,
        };
        try std.testing.expect(chunkValidV1(chunk));
        try std.testing.expect(chunkMatchesScriptV1(
            chunk,
            dispatch.intent,
            script,
        ));
        try std.testing.expectEqual(index, chunk.chunk_index);
        try std.testing.expectEqualSlices(
            u8,
            &previous_chain,
            &chunk.before_chain_sha256,
        );
        previous_chain = chunk.after_chain_sha256;
    }
    const outcome = switch (try harness.step(started.handle)) {
        .chunk => return error.UnexpectedChunk,
        .outcome => |value| value,
    };
    try std.testing.expect(outcomeValidV1(outcome));
    try std.testing.expect(outcomeMatchesScriptV1(
        outcome,
        descriptor,
        script,
    ));
    try std.testing.expectEqualSlices(
        u8,
        &previous_chain,
        &outcome.response_chain_sha256,
    );
    try std.testing.expectEqual(outcome, try harness.outcome(started.handle));

    const settlement = try applyOutcome(
        &token_gateway,
        dispatch.permit,
        descriptor,
        script,
        outcome,
    );
    try std.testing.expectEqual(
        gateway.AttemptOutcome.succeeded,
        settlement.receipt.outcome,
    );
    try std.testing.expectError(
        gateway.Error.InvalidPermit,
        applyOutcome(
            &token_gateway,
            dispatch.permit,
            descriptor,
            script,
            outcome,
        ),
    );
    try harness.acknowledge(started.handle);
    _ = try token_gateway.acknowledge(admission.handle);
    const harness_final = try harness.close();
    const gateway_final = try token_gateway.close();
    try std.testing.expectEqual(@as(u64, 1), harness_final.ledger.started_attempts);
    try std.testing.expectEqual(@as(u64, 3), harness_final.ledger.emitted_chunks);
    try std.testing.expectEqual(@as(u64, 1), harness_final.ledger.successful_outcomes);
    try std.testing.expectEqual(@as(u64, 80), gateway_final.ledger.settled_billable_tokens);
}

test "retry reuses provider identity and ambiguity holds gateway reservation" {
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(2));
    const first_dispatch = try token_gateway.beginDispatch(admission.handle);
    const descriptor = try testDescriptor();
    var attempt_slots: [1]AttemptSlot = .{.{}};
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );

    const retry_script = try makeScriptV1(
        descriptor,
        first_dispatch.intent,
        testDigest(0x62),
        0,
        .retryable_no_charge,
        try gateway.makeUsageV1(null, null, null, null, 0, 0),
        zero_digest,
    );
    const retry_start = try harness.start(
        first_dispatch.permit,
        retry_script,
    );
    const retry_outcome = switch (try harness.step(retry_start.handle)) {
        .chunk => return error.UnexpectedChunk,
        .outcome => |value| value,
    };
    _ = try applyOutcome(
        &token_gateway,
        first_dispatch.permit,
        descriptor,
        retry_script,
        retry_outcome,
    );
    try harness.acknowledge(retry_start.handle);

    const second_dispatch = try token_gateway.beginDispatch(admission.handle);
    const ambiguous_script = try makeScriptV1(
        descriptor,
        second_dispatch.intent,
        testDigest(0x63),
        1,
        .ambiguous,
        try gateway.makeUsageV1(null, null, null, null, null, null),
        zero_digest,
    );
    try std.testing.expectEqualSlices(
        u8,
        &retry_script.provider_request_sha256,
        &ambiguous_script.provider_request_sha256,
    );
    const ambiguous_start = try harness.start(
        second_dispatch.permit,
        ambiguous_script,
    );
    _ = switch (try harness.step(ambiguous_start.handle)) {
        .chunk => |value| value,
        .outcome => return error.UnexpectedOutcome,
    };
    const ambiguous_outcome = switch (try harness.step(
        ambiguous_start.handle,
    )) {
        .chunk => return error.UnexpectedChunk,
        .outcome => |value| value,
    };
    _ = try applyOutcome(
        &token_gateway,
        second_dispatch.permit,
        descriptor,
        ambiguous_script,
        ambiguous_outcome,
    );
    const pending = try token_gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 150), pending.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 1), pending.ledger.ambiguous_owners);
    try harness.acknowledge(ambiguous_start.handle);
    _ = try token_gateway.resolveAmbiguousFailure(
        second_dispatch.permit,
        try gateway.makeUsageV1(100, 0, 0, 0, 0, 100),
    );
    _ = try token_gateway.acknowledge(admission.handle);
    const harness_final = try harness.close();
    const gateway_final = try token_gateway.close();
    try std.testing.expectEqual(@as(u64, 1), harness_final.ledger.retryable_outcomes);
    try std.testing.expectEqual(@as(u64, 1), harness_final.ledger.ambiguous_outcomes);
    try std.testing.expectEqual(@as(u64, 2), gateway_final.ledger.physical_dispatches);
}

test "script, handle, outcome mutation and copied harness reject" {
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(3));
    const dispatch = try token_gateway.beginDispatch(admission.handle);
    const descriptor = try testDescriptor();
    var attempt_slots: [1]AttemptSlot = .{.{}};
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );
    const usage = try gateway.makeUsageV1(100, 10, 0, 0, 0, 110);
    const script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x64),
        1,
        .succeeded,
        usage,
        testDigest(0x74),
    );
    const started = try harness.start(dispatch.permit, script);

    var conflicting_script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x65),
        1,
        .succeeded,
        usage,
        testDigest(0x74),
    );
    try std.testing.expectError(
        Error.AttemptConflict,
        harness.start(dispatch.permit, conflicting_script),
    );
    conflicting_script.chunk_count += 1;
    try std.testing.expect(!scriptValidV1(conflicting_script));
    try std.testing.expectError(
        Error.InvalidScript,
        harness.start(dispatch.permit, conflicting_script),
    );

    var bad_handle = started.handle;
    bad_handle.generation += 1;
    try std.testing.expectError(Error.InvalidHandle, harness.step(bad_handle));
    var copied_harness = harness;
    try std.testing.expectError(Error.StateDrift, copied_harness.snapshot());

    const original_script = attempt_slots[0].script;
    attempt_slots[0].script.provider_request_sha256[0] ^= 0xff;
    attempt_slots[0].script.script_sha256 = scriptSha256(
        attempt_slots[0].script,
    );
    try std.testing.expectError(Error.StateDrift, harness.snapshot());
    attempt_slots[0].script = original_script;

    harness.ledger.started_attempts += 1;
    try std.testing.expectError(Error.StateDrift, harness.snapshot());
    harness.ledger.started_attempts -= 1;
    harness.ledger.emitted_chunks += 1;
    try std.testing.expectError(Error.StateDrift, harness.snapshot());
    harness.ledger.emitted_chunks -= 1;

    var forged_chunk = switch (try harness.step(started.handle)) {
        .chunk => |value| value,
        .outcome => return error.UnexpectedOutcome,
    };
    forged_chunk.chunk_sha256[0] ^= 0xff;
    forged_chunk.after_chain_sha256 = appendResponseChainSha256(
        forged_chunk.before_chain_sha256,
        forged_chunk.chunk_index,
        forged_chunk.chunk_sha256,
    );
    forged_chunk.evidence_sha256 = chunkEvidenceSha256(forged_chunk);
    try std.testing.expect(chunkValidV1(forged_chunk));
    try std.testing.expect(!chunkMatchesScriptV1(
        forged_chunk,
        dispatch.intent,
        script,
    ));
    var outcome = switch (try harness.step(started.handle)) {
        .chunk => return error.UnexpectedChunk,
        .outcome => |value| value,
    };
    outcome.response_chain_sha256[0] ^= 0xff;
    try std.testing.expect(!outcomeValidV1(outcome));
    try std.testing.expectError(
        Error.InvalidOutcome,
        applyOutcome(
            &token_gateway,
            dispatch.permit,
            descriptor,
            script,
            outcome,
        ),
    );
    const valid_outcome = try harness.outcome(started.handle);
    const foreign_descriptor = try makeDescriptorV1(
        descriptor.transport_adapter_abi,
        testDigest(0x92),
        required_capabilities,
    );
    const foreign_script = try makeScriptV1(
        foreign_descriptor,
        dispatch.intent,
        script.chunk_seed_sha256,
        script.chunk_count,
        script.terminal_mode,
        script.usage,
        script.result_sha256,
    );
    try std.testing.expectError(
        Error.InvalidOutcome,
        applyOutcome(
            &token_gateway,
            dispatch.permit,
            foreign_descriptor,
            foreign_script,
            valid_outcome,
        ),
    );
    _ = try applyOutcome(
        &token_gateway,
        dispatch.permit,
        descriptor,
        script,
        valid_outcome,
    );
    try harness.acknowledge(started.handle);
    _ = try token_gateway.acknowledge(admission.handle);
    _ = try harness.close();
    _ = try token_gateway.close();
}

test "concurrent identical starts create one transport attempt" {
    const worker_count = 8;
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(4));
    const dispatch = try token_gateway.beginDispatch(admission.handle);
    const descriptor = try testDescriptor();
    var attempt_slots: [2]AttemptSlot = [_]AttemptSlot{.{}} ** 2;
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );
    const script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x66),
        0,
        .succeeded,
        try gateway.makeUsageV1(100, 10, 0, 0, 0, 110),
        testDigest(0x76),
    );
    var workers: [worker_count]StartWorker = undefined;
    var threads: [worker_count]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| {
        worker.* = .{
            .harness = &harness,
            .permit = dispatch.permit,
            .script = script,
        };
        threads[index] = std.Thread.spawn(.{}, StartWorker.run, .{
            worker,
        }) catch |err| {
            for (threads[0..index]) |thread| thread.join();
            return err;
        };
    }
    for (threads) |thread| thread.join();
    var started_count: usize = 0;
    var expected_handle: ?TransportHandleV1 = null;
    for (workers) |worker| {
        try std.testing.expect(worker.failure == null);
        const result = worker.result orelse return error.MissingStart;
        if (result.kind == .started) started_count += 1;
        if (expected_handle) |handle|
            try std.testing.expectEqual(handle, result.handle)
        else
            expected_handle = result.handle;
    }
    try std.testing.expectEqual(@as(usize, 1), started_count);
    const snapshot = try harness.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.ledger.started_attempts);
    try std.testing.expectEqual(@as(u64, 1), snapshot.ledger.active_attempts);
    const outcome = switch (try harness.step(expected_handle.?)) {
        .chunk => return error.UnexpectedChunk,
        .outcome => |value| value,
    };
    _ = try applyOutcome(
        &token_gateway,
        dispatch.permit,
        descriptor,
        script,
        outcome,
    );
    try harness.acknowledge(expected_handle.?);
    _ = try token_gateway.acknowledge(admission.handle);
    _ = try harness.close();
    _ = try token_gateway.close();
}

test "confirmed partial-stream cancellation settles authoritative usage" {
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(5));
    const dispatch = try token_gateway.beginDispatch(admission.handle);
    const descriptor = try testCancelDescriptor();
    var attempt_slots: [1]AttemptSlot = .{.{}};
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );
    const script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x67),
        5,
        .succeeded,
        try gateway.makeUsageV1(100, 50, 0, 0, 0, 150),
        testDigest(0x77),
    );
    const started = try harness.start(dispatch.permit, script);
    for (0..2) |_| {
        _ = switch (try harness.step(started.handle)) {
            .chunk => |value| value,
            .outcome => return error.UnexpectedOutcome,
        };
    }

    const requested = try harness.requestCancel(
        started.handle,
        .deadline_expired,
    );
    try std.testing.expectEqual(CancelStartKind.requested, requested.kind);
    try std.testing.expect(cancelRequestMatchesAttemptV1(
        requested.request,
        descriptor,
        dispatch.intent,
        script,
    ));
    try std.testing.expectEqual(@as(u32, 2), requested.request.emitted_chunks);
    const repeated = try harness.requestCancel(
        started.handle,
        .deadline_expired,
    );
    try std.testing.expectEqual(CancelStartKind.existing, repeated.kind);
    try std.testing.expectEqual(requested.request, repeated.request);
    try std.testing.expectError(
        Error.AttemptConflict,
        harness.requestCancel(started.handle, .budget_pressure),
    );
    try std.testing.expectError(
        Error.InvalidState,
        harness.step(started.handle),
    );

    const usage = try gateway.makeUsageV1(100, 5, 81, 0, 0, 24);
    const ack = try makeCancelAckV1(
        requested.request,
        .confirmed,
        usage,
        zero_digest,
    );
    var foreign_ack = ack;
    foreign_ack.cancel_request_sha256[0] ^= 0xff;
    foreign_ack.ack_sha256 = cancelAckSha256(foreign_ack);
    try std.testing.expect(cancelAckValidV1(foreign_ack));
    try std.testing.expectError(
        Error.InvalidCancelAck,
        harness.applyCancelAck(started.handle, foreign_ack),
    );
    var cancel_outcome = switch (try harness.applyCancelAck(
        started.handle,
        ack,
    )) {
        .resumed => return error.UnexpectedResume,
        .terminal => |value| value,
    };
    try std.testing.expect(cancelOutcomeMatchesAttemptV1(
        cancel_outcome,
        descriptor,
        dispatch.intent,
        script,
        requested.request,
        ack,
    ));
    try std.testing.expectEqual(
        cancel_outcome,
        try harness.cancelOutcome(started.handle),
    );
    try std.testing.expectError(
        Error.InvalidState,
        harness.applyCancelAck(started.handle, ack),
    );
    cancel_outcome.response_chain_sha256[0] ^= 0xff;
    cancel_outcome.outcome_sha256 = cancelOutcomeSha256(cancel_outcome);
    try std.testing.expect(cancelOutcomeValidV1(cancel_outcome));
    try std.testing.expectError(
        Error.InvalidCancelOutcome,
        applyCancelOutcome(
            &token_gateway,
            dispatch.permit,
            descriptor,
            script,
            requested.request,
            ack,
            cancel_outcome,
        ),
    );
    const valid_outcome = try harness.cancelOutcome(started.handle);
    const settlement = try applyCancelOutcome(
        &token_gateway,
        dispatch.permit,
        descriptor,
        script,
        requested.request,
        ack,
        valid_outcome,
    );
    try std.testing.expectEqual(
        gateway.AttemptOutcome.failed,
        settlement.receipt.outcome,
    );
    try std.testing.expectError(
        gateway.Error.InvalidPermit,
        applyCancelOutcome(
            &token_gateway,
            dispatch.permit,
            descriptor,
            script,
            requested.request,
            ack,
            valid_outcome,
        ),
    );
    harness.cancel_ledger.requested_cancellations += 1;
    try std.testing.expectError(Error.StateDrift, harness.cancelSnapshot());
    harness.cancel_ledger.requested_cancellations -= 1;
    harness.cancel_ledger.known_post_cancel_billable_tokens += 1;
    try std.testing.expectError(Error.StateDrift, harness.cancelSnapshot());
    harness.cancel_ledger.known_post_cancel_billable_tokens -= 1;
    const cancel_snapshot = try harness.cancelSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        cancel_snapshot.ledger.confirmed_cancellations,
    );
    try std.testing.expectEqual(
        @as(u64, 24),
        cancel_snapshot.ledger.known_post_cancel_billable_tokens,
    );
    try harness.acknowledge(started.handle);
    _ = try token_gateway.acknowledge(admission.handle);
    const harness_final = try harness.close();
    const gateway_final = try token_gateway.close();
    try std.testing.expectEqual(@as(u64, 2), harness_final.ledger.emitted_chunks);
    try std.testing.expectEqual(@as(u64, 1), harness_final.ledger.acknowledged_attempts);
    try std.testing.expectEqual(@as(u64, 1), gateway_final.ledger.failed_dispatches);
    try std.testing.expectEqual(@as(u64, 24), gateway_final.ledger.settled_billable_tokens);
}

test "rejected cancellation resumes the exact response chain" {
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(6));
    const dispatch = try token_gateway.beginDispatch(admission.handle);
    const descriptor = try testCancelDescriptor();
    var attempt_slots: [1]AttemptSlot = .{.{}};
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );
    const usage = try gateway.makeUsageV1(100, 20, 0, 0, 0, 120);
    const script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x68),
        3,
        .succeeded,
        usage,
        testDigest(0x78),
    );
    const started = try harness.start(dispatch.permit, script);
    const first_chunk = switch (try harness.step(started.handle)) {
        .chunk => |value| value,
        .outcome => return error.UnexpectedOutcome,
    };
    const requested = try harness.requestCancel(
        started.handle,
        .budget_pressure,
    );
    try std.testing.expectEqualSlices(
        u8,
        &first_chunk.after_chain_sha256,
        &requested.request.response_chain_sha256,
    );
    try std.testing.expectError(
        Error.InvalidCancelAck,
        makeCancelAckV1(
            requested.request,
            .not_accepted,
            try gateway.makeUsageV1(1, 0, 0, 0, 0, 0),
            zero_digest,
        ),
    );
    const rejected_ack = try makeCancelAckV1(
        requested.request,
        .not_accepted,
        try gateway.makeUsageV1(null, null, null, null, 0, 0),
        zero_digest,
    );
    const resumed_handle = switch (try harness.applyCancelAck(
        started.handle,
        rejected_ack,
    )) {
        .resumed => |value| value,
        .terminal => return error.UnexpectedOutcome,
    };
    try std.testing.expectEqual(started.handle, resumed_handle);
    var previous_chain = first_chunk.after_chain_sha256;
    var index: u32 = 1;
    while (index < script.chunk_count) : (index += 1) {
        const chunk = switch (try harness.step(resumed_handle)) {
            .chunk => |value| value,
            .outcome => return error.UnexpectedOutcome,
        };
        try std.testing.expectEqualSlices(
            u8,
            &previous_chain,
            &chunk.before_chain_sha256,
        );
        previous_chain = chunk.after_chain_sha256;
    }
    const outcome = switch (try harness.step(resumed_handle)) {
        .chunk => return error.UnexpectedChunk,
        .outcome => |value| value,
    };
    try std.testing.expectEqualSlices(
        u8,
        &previous_chain,
        &outcome.response_chain_sha256,
    );
    _ = try applyOutcome(
        &token_gateway,
        dispatch.permit,
        descriptor,
        script,
        outcome,
    );
    const cancel_snapshot = try harness.cancelSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        cancel_snapshot.ledger.requested_cancellations,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        cancel_snapshot.ledger.rejected_cancellations,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        cancel_snapshot.ledger.pending_cancellations,
    );
    try harness.acknowledge(resumed_handle);
    _ = try token_gateway.acknowledge(admission.handle);
    _ = try harness.close();
    _ = try token_gateway.close();
}

test "ambiguous cancellation retains reservation until exact resolution" {
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(7));
    const dispatch = try token_gateway.beginDispatch(admission.handle);
    const descriptor = try testCancelDescriptor();
    var attempt_slots: [1]AttemptSlot = .{.{}};
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );
    const script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x69),
        4,
        .succeeded,
        try gateway.makeUsageV1(100, 50, 0, 0, 0, 150),
        testDigest(0x79),
    );
    const started = try harness.start(dispatch.permit, script);
    _ = switch (try harness.step(started.handle)) {
        .chunk => |value| value,
        .outcome => return error.UnexpectedOutcome,
    };
    const requested = try harness.requestCancel(
        started.handle,
        .shutdown,
    );
    const ack = try makeCancelAckV1(
        requested.request,
        .ambiguous,
        try gateway.makeUsageV1(null, null, null, null, null, null),
        zero_digest,
    );
    const outcome = switch (try harness.applyCancelAck(
        started.handle,
        ack,
    )) {
        .resumed => return error.UnexpectedResume,
        .terminal => |value| value,
    };
    _ = try applyCancelOutcome(
        &token_gateway,
        dispatch.permit,
        descriptor,
        script,
        requested.request,
        ack,
        outcome,
    );
    const held = try token_gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 150), held.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 1), held.ledger.ambiguous_owners);
    const cancel_snapshot = try harness.cancelSnapshot();
    try std.testing.expectEqual(
        @as(u64, 1),
        cancel_snapshot.ledger.ambiguous_cancellations,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        cancel_snapshot.ledger.unknown_post_cancel_usage,
    );
    try harness.acknowledge(started.handle);
    _ = try token_gateway.resolveAmbiguousFailure(
        dispatch.permit,
        try gateway.makeUsageV1(100, 0, 0, 0, 0, 100),
    );
    _ = try token_gateway.acknowledge(admission.handle);
    _ = try harness.close();
    const gateway_final = try token_gateway.close();
    try std.testing.expectEqual(@as(u64, 0), gateway_final.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 100), gateway_final.ledger.settled_billable_tokens);
}

test "normal completion and active cancellation have exactly one winner" {
    var owner_slots: [1]gateway.OwnerSlot = .{.{}};
    var follower_slots: [1]gateway.FollowerSlot = .{.{}};
    var token_gateway: gateway.Gateway = .{};
    try token_gateway.init(
        &owner_slots,
        &follower_slots,
        testGatewayConfig(),
    );
    const admission = try token_gateway.admit(try testRequest(8));
    const dispatch = try token_gateway.beginDispatch(admission.handle);
    const descriptor = try testCancelDescriptor();
    var attempt_slots: [1]AttemptSlot = .{.{}};
    var harness: Harness = .{};
    try harness.init(
        &attempt_slots,
        testHarnessConfig(descriptor),
    );
    const usage = try gateway.makeUsageV1(100, 10, 0, 0, 0, 110);
    const result_sha256 = testDigest(0x7a);
    const script = try makeScriptV1(
        descriptor,
        dispatch.intent,
        testDigest(0x6a),
        0,
        .succeeded,
        usage,
        result_sha256,
    );
    const started = try harness.start(dispatch.permit, script);
    var canceller: CancelRequestWorker = .{
        .harness = &harness,
        .handle = started.handle,
        .reason = .deadline_expired,
    };
    var stepper: StepWorker = .{
        .harness = &harness,
        .handle = started.handle,
    };
    const cancel_thread = try std.Thread.spawn(
        .{},
        CancelRequestWorker.run,
        .{&canceller},
    );
    const step_thread = std.Thread.spawn(
        .{},
        StepWorker.run,
        .{&stepper},
    ) catch |err| {
        cancel_thread.join();
        return err;
    };
    cancel_thread.join();
    step_thread.join();
    const cancel_won = canceller.result != null;
    const step_won = stepper.result != null;
    try std.testing.expect(cancel_won != step_won);
    if (cancel_won) {
        try std.testing.expect(canceller.failure == null);
        try std.testing.expectEqual(Error.InvalidState, stepper.failure.?);
        const request = canceller.result.?.request;
        const ack = try makeCancelAckV1(
            request,
            .too_late_succeeded,
            usage,
            result_sha256,
        );
        const outcome = switch (try harness.applyCancelAck(
            started.handle,
            ack,
        )) {
            .resumed => return error.UnexpectedResume,
            .terminal => |value| value,
        };
        _ = try applyCancelOutcome(
            &token_gateway,
            dispatch.permit,
            descriptor,
            script,
            request,
            ack,
            outcome,
        );
        const cancel_snapshot = try harness.cancelSnapshot();
        try std.testing.expectEqual(
            @as(u64, 1),
            cancel_snapshot.ledger.too_late_successes,
        );
    } else {
        try std.testing.expect(stepper.failure == null);
        try std.testing.expectEqual(Error.InvalidState, canceller.failure.?);
        const outcome = switch (stepper.result.?) {
            .chunk => return error.UnexpectedChunk,
            .outcome => |value| value,
        };
        _ = try applyOutcome(
            &token_gateway,
            dispatch.permit,
            descriptor,
            script,
            outcome,
        );
    }
    const status = try token_gateway.poll(admission.handle);
    const receipt = switch (status) {
        .succeeded => |value| value,
        else => return error.UnexpectedStatus,
    };
    try std.testing.expectEqualSlices(
        u8,
        &result_sha256,
        &receipt.result_sha256,
    );
    try harness.acknowledge(started.handle);
    _ = try token_gateway.acknowledge(admission.handle);
    _ = try harness.close();
    _ = try token_gateway.close();
}

test "portable transport evidence remains pointer-free and bounded" {
    try std.testing.expect(@sizeOf(DescriptorV1) <= 96);
    try std.testing.expect(@sizeOf(ScriptV1) <= 320);
    try std.testing.expect(@sizeOf(ChunkV1) <= 320);
    try std.testing.expect(@sizeOf(OutcomeV1) <= 640);
    try std.testing.expect(@sizeOf(CancelRequestV1) <= 256);
    try std.testing.expect(@sizeOf(CancelAckV1) <= 320);
    try std.testing.expect(@sizeOf(CancelOutcomeV1) <= 768);
    try std.testing.expect(@sizeOf(CancelSnapshotV1) <= 128);
    try std.testing.expect(@sizeOf(AttemptSlot) <= 2304);
    inline for (std.meta.fields(DescriptorV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(ScriptV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(ChunkV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(OutcomeV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(CancelRequestV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(CancelAckV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(CancelOutcomeV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(CancelSnapshotV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
}
