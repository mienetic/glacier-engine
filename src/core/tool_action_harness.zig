//! Fixed-storage, credential-free harness for one deterministic tool action.
//!
//! The only supported effect is `bounded_add` against caller-owned counters.
//! The harness has no allocator and no filesystem, network, process, clock,
//! random-number, environment, or credential authority. All fallible work is
//! completed by a mutex-held LaneWeave transaction precommit. Its finalize
//! callback only publishes already validated facts, refreshes retained
//! integrity, and unlocks; it is bounded, allocation-free, and infallible.

const std = @import("std");
const action = @import("tool_action_contract.zig");
const qos = @import("lane_weave_qos.zig");
const resource_bank = @import("resource_bank.zig");

pub const Digest = action.Digest;
pub const zero_digest = action.zero_digest;

pub const harness_abi: u64 = 0x4754_4148_0000_0001;
pub const prepared_abi: u64 = 0x4754_4152_0000_0001;
pub const armed_abi: u64 = 0x4754_414d_0000_0001;
pub const snapshot_abi: u64 = 0x4754_4153_0000_0001;
pub const maximum_storage_slots: usize = 64;

const configuration_domain = "glacier-tool-harness-configuration-v1\x00";
const candidate_domain = "glacier-tool-harness-candidate-v1\x00";
const prepared_domain = "glacier-tool-harness-prepared-v1\x00";
const armed_domain = "glacier-tool-harness-armed-v1\x00";
const state_domain = "glacier-tool-harness-state-v1\x00";
const retained_integrity_domain =
    "glacier-tool-harness-retained-integrity-v1\x00";
const no_slot: u32 = std.math.maxInt(u32);

pub const Error = action.Error || error{
    AddressChanged,
    AliasedStorage,
    CapacityExceeded,
    InvalidConfiguration,
    InvalidEvent,
    InvalidPermit,
    InvalidState,
    InvalidToken,
    SequenceExhausted,
    StateDrift,
};

pub const ConfigV1 = struct {
    abi_version: u64 = harness_abi,
    harness_epoch: u64 = 0,
    harness_id: u64 = 0,
    challenge_sha256: Digest = zero_digest,
    descriptor: action.DescriptorV1 = .{},
    policy: action.PolicyV1 = .{},
};

pub const LedgerSlotV1 = struct {
    active: bool = false,
    proposal: action.ActionProposalV1 = .{},
    arguments: action.BoundedAddArgumentsV1 = .{},
    authorization: action.AuthorizationReceiptV1 = .{},
    effect: action.EffectReceiptV1 = .{},
};

pub const CounterSlotV1 = struct {
    active: bool = false,
    target_key: u64 = 0,
    value: i64 = 0,
};

pub const CountsV1 = struct {
    executed: u64 = 0,
    reused: u64 = 0,
    conflicts: u64 = 0,
    denied: u64 = 0,
    deliveries: u64 = 0,
};

pub const PreparedV1 = struct {
    abi_version: u64 = prepared_abi,
    harness_epoch: u64 = 0,
    harness_id: u64 = 0,
    generation: u64 = 0,
    configuration_sha256: Digest = zero_digest,
    proposal_sha256: Digest = zero_digest,
    permit_sha256: Digest = zero_digest,
    candidate_sha256: Digest = zero_digest,
    prepared_sha256: Digest = zero_digest,
};

pub const ArmedTokenV1 = struct {
    abi_version: u64 = armed_abi,
    harness_epoch: u64 = 0,
    harness_id: u64 = 0,
    generation: u64 = 0,
    prepared_sha256: Digest = zero_digest,
    intent_sha256: Digest = zero_digest,
    candidate_sha256: Digest = zero_digest,
    armed_sha256: Digest = zero_digest,
};

pub const ArmedCommit = struct {
    token: ArmedTokenV1,
    transaction: qos.ServiceTransactionV1,
};

pub const SnapshotV1 = struct {
    abi_version: u64 = snapshot_abi,
    harness_epoch: u64 = 0,
    harness_id: u64 = 0,
    active_ledger_slots: u64 = 0,
    active_counter_slots: u64 = 0,
    next_execution_sequence: u64 = 0,
    next_prepare_generation: u64 = 0,
    pending: bool = false,
    counts: CountsV1 = .{},
    state_sha256: Digest = zero_digest,
};

const PendingState = enum(u8) {
    free,
    prepared,
    armed,
    precommitted,
    finalized,
};

const PendingV1 = struct {
    state: PendingState = .free,
    prepared: PreparedV1 = .{},
    armed: ArmedTokenV1 = .{},
    permit: qos.ServicePermitV1 = .{},
    intent: qos.ServiceIntentV1 = .{},
    proposal: action.ActionProposalV1 = .{},
    arguments: action.BoundedAddArgumentsV1 = .{},
    gate_authorization: action.AuthorizationReceiptV1 = .{},
    authorization: action.AuthorizationReceiptV1 = .{},
    effect: action.EffectReceiptV1 = .{},
    disposition: action.DeliveryDispositionV1 = .denied,
    ledger_index: u32 = no_slot,
    counter_index: u32 = no_slot,
    counts_after: CountsV1 = .{},
    next_execution_sequence_after: u64 = 0,
    delivery_effect_sha256: Digest = zero_digest,
    delivery_output_sha256: Digest = zero_digest,
    candidate_sha256: Digest = zero_digest,
    final_event_sha256: Digest = zero_digest,
    delivery: action.DeliveryReceiptV1 = .{},
};

pub const StorageV1 = struct {
    ledger: []LedgerSlotV1,
    counters: []CounterSlotV1,
};

pub const Harness = struct {
    mutex: std.Thread.Mutex = .{},
    config: ConfigV1 = .{},
    configuration_sha256: Digest = zero_digest,
    ledger: []LedgerSlotV1 = &.{},
    counters: []CounterSlotV1 = &.{},
    self_address: usize = 0,
    ledger_storage_address: usize = 0,
    ledger_storage_length: usize = 0,
    counter_storage_address: usize = 0,
    counter_storage_length: usize = 0,
    next_execution_sequence: u64 = 1,
    next_prepare_generation: u64 = 1,
    counts: CountsV1 = .{},
    pending: PendingV1 = .{},
    retained_integrity_sha256: Digest = zero_digest,
    initialized: bool = false,

    pub fn init(
        self: *Harness,
        config: ConfigV1,
        storage: StorageV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.initialized) {
            try self.requireUsableLocked();
            return Error.InvalidState;
        }
        try validateConfigV1(config);
        if (storage.ledger.len == 0 or storage.counters.len == 0 or
            storage.ledger.len > maximum_storage_slots or
            storage.counters.len > maximum_storage_slots)
            return Error.InvalidConfiguration;
        if (storageOverlaps(
            storage.ledger,
            storage.counters,
        ) or sliceOverlapsValue(storage.ledger, self) or
            sliceOverlapsValue(storage.counters, self))
            return Error.AliasedStorage;

        for (storage.ledger) |*slot| slot.* = .{};
        for (storage.counters) |*slot| slot.* = .{};
        self.config = config;
        self.configuration_sha256 = configurationSha256V1(config);
        self.ledger = storage.ledger;
        self.counters = storage.counters;
        self.self_address = @intFromPtr(self);
        self.ledger_storage_address = @intFromPtr(storage.ledger.ptr);
        self.ledger_storage_length = storage.ledger.len;
        self.counter_storage_address = @intFromPtr(storage.counters.ptr);
        self.counter_storage_length = storage.counters.len;
        self.next_execution_sequence = 1;
        self.next_prepare_generation = 1;
        self.counts = .{};
        self.pending = .{};
        self.initialized = true;
        self.retained_integrity_sha256 =
            self.retainedIntegritySha256Locked();
    }

    pub fn prepare(
        self: *Harness,
        proposal: action.ActionProposalV1,
        arguments: action.BoundedAddArgumentsV1,
        permit: qos.ServicePermitV1,
    ) Error!PreparedV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        if (self.pending.state != .free) return Error.InvalidState;
        try action.validateProposalCompositionV1(
            proposal,
            self.config.descriptor,
            arguments,
        );
        // Scheduler tenant keys identify fairness lanes; proposal tenant keys
        // identify the tool-policy authorization domain. The typed workload
        // binds the proposal root to its item, so these domains intentionally
        // remain independent here.
        if (!validFinalPermit(permit))
            return Error.InvalidPermit;
        if (self.next_prepare_generation == 0 or
            self.next_prepare_generation == std.math.maxInt(u64))
            return Error.SequenceExhausted;

        var pending: PendingV1 = .{
            .state = .prepared,
            .permit = permit,
            .proposal = proposal,
            .arguments = arguments,
        };
        const ledger_index = self.findLedger(
            proposal.idempotency_key_sha256,
        );
        if (ledger_index) |index| {
            const prior = self.ledger[index];
            try validateLedgerSlotWithDescriptor(
                prior,
                self.config.descriptor,
                self.config.policy,
            );
            if (digestEqual(
                prior.proposal.proposal_sha256,
                proposal.proposal_sha256,
            )) {
                if (!std.meta.eql(prior.arguments, arguments))
                    return Error.StateDrift;
                pending.ledger_index = @intCast(index);
                pending.gate_authorization = prior.authorization;
                pending.authorization = prior.authorization;
                pending.effect = prior.effect;
                pending.disposition = .reused;
            } else {
                const before = self.valueForTarget(arguments.target_key);
                pending.gate_authorization =
                    try action.authorizeBoundedAddV1(
                        proposal,
                        self.config.descriptor,
                        arguments,
                        self.config.policy,
                        before,
                    );
                pending.authorization = pending.gate_authorization;
                if (pending.gate_authorization.kind == .denied) {
                    pending.disposition = .denied;
                } else {
                    pending.ledger_index = @intCast(index);
                    pending.authorization =
                        try action.denyIdempotencyConflictV1(
                            proposal,
                            self.config.policy,
                            before,
                        );
                    pending.effect = prior.effect;
                    pending.disposition = .conflict;
                }
            }
        } else {
            const counter_index = self.findCounter(arguments.target_key);
            const before = if (counter_index) |index|
                self.counters[index].value
            else
                0;
            pending.gate_authorization =
                try action.authorizeBoundedAddV1(
                    proposal,
                    self.config.descriptor,
                    arguments,
                    self.config.policy,
                    before,
                );
            pending.authorization = pending.gate_authorization;
            if (pending.gate_authorization.kind == .denied) {
                pending.disposition = .denied;
            } else {
                if (self.next_execution_sequence == 0 or
                    self.next_execution_sequence == std.math.maxInt(u64))
                    return Error.SequenceExhausted;
                const free_ledger = self.freeLedger() orelse
                    return Error.CapacityExceeded;
                const selected_counter = counter_index orelse
                    self.freeCounter() orelse
                    return Error.CapacityExceeded;
                pending.ledger_index = @intCast(free_ledger);
                pending.counter_index = @intCast(selected_counter);
                pending.effect = try action.makeEffectReceiptV1(
                    self.next_execution_sequence,
                    proposal,
                    arguments,
                    pending.authorization,
                );
                pending.disposition = .executed;
            }
        }

        pending.counts_after = try countsAfterV1(
            self.counts,
            pending.disposition,
        );
        pending.next_execution_sequence_after =
            if (pending.disposition == .executed)
                try checkedAdd(self.next_execution_sequence, 1)
            else
                self.next_execution_sequence;
        switch (pending.disposition) {
            .executed, .reused => {
                pending.delivery_effect_sha256 =
                    pending.effect.effect_sha256;
                pending.delivery_output_sha256 =
                    pending.effect.output_sha256;
            },
            .denied => {
                pending.delivery_output_sha256 =
                    action.terminalOutputSha256V1(
                        .denied,
                        pending.proposal,
                        pending.authorization,
                        zero_digest,
                    );
            },
            .conflict => {
                pending.delivery_effect_sha256 =
                    pending.effect.effect_sha256;
                pending.delivery_output_sha256 =
                    action.terminalOutputSha256V1(
                        .conflict,
                        pending.proposal,
                        pending.authorization,
                        pending.effect.effect_sha256,
                    );
            },
        }

        pending.candidate_sha256 = candidateSha256V1(pending);
        const generation = self.next_prepare_generation;
        const next_generation = try checkedAdd(generation, 1);
        pending.prepared = makePreparedV1(
            self.config,
            generation,
            proposal.proposal_sha256,
            permit.permit_sha256,
            pending.candidate_sha256,
        );
        self.pending = pending;
        self.next_prepare_generation = next_generation;
        self.refreshIntegrityLocked();
        return pending.prepared;
    }

    pub fn arm(
        self: *Harness,
        prepared: PreparedV1,
        scheduler_arm: qos.ArmedServiceV1,
    ) Error!ArmedCommit {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        if (self.pending.state != .prepared or
            !std.meta.eql(self.pending.prepared, prepared) or
            !preparedValidV1(prepared) or
            !intentMatchesPermit(
                scheduler_arm.intent,
                self.pending.permit,
            ))
            return Error.InvalidToken;
        try self.validatePendingCandidateLocked();

        const token = makeArmedTokenV1(
            self.config,
            prepared,
            scheduler_arm.intent.intent_sha256,
            self.pending.candidate_sha256,
        );
        self.pending.intent = scheduler_arm.intent;
        self.pending.armed = token;
        self.pending.state = .armed;
        self.refreshIntegrityLocked();
        return .{
            .token = token,
            .transaction = .{
                .context = self,
                .precommit = transactionPrecommit,
                .finalize = transactionFinalize,
            },
        };
    }

    pub fn abortPrepared(
        self: *Harness,
        prepared: PreparedV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        if (self.pending.state != .prepared or
            !std.meta.eql(self.pending.prepared, prepared) or
            !preparedValidV1(prepared))
            return Error.InvalidToken;
        self.pending = .{};
        self.refreshIntegrityLocked();
    }

    pub fn abortArmed(
        self: *Harness,
        token: ArmedTokenV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        if (self.pending.state != .armed or
            !std.meta.eql(self.pending.armed, token) or
            !armedTokenValidV1(token))
            return Error.InvalidToken;
        self.pending = .{};
        self.refreshIntegrityLocked();
    }

    pub fn finish(
        self: *Harness,
        token: ArmedTokenV1,
        event: qos.EventV1,
    ) Error!action.DeliveryReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        if (self.pending.state != .finalized or
            !std.meta.eql(self.pending.armed, token) or
            !armedTokenValidV1(token))
            return Error.InvalidToken;
        if (!qos.eventMatchesServiceIntentV1(
            event,
            self.pending.intent,
        ) or !digestEqual(
            event.event_sha256,
            self.pending.final_event_sha256,
        ))
            return Error.InvalidEvent;
        try self.validateFinalizedStateLocked();
        const maybe_effect: ?action.EffectReceiptV1 =
            if (self.pending.disposition == .denied)
                null
            else
                self.pending.effect;
        try action.validateDeliveryCompositionV1(
            self.pending.delivery,
            self.pending.proposal,
            self.pending.authorization,
            maybe_effect,
            event.event_sha256,
        );
        const result = self.pending.delivery;
        self.pending = .{};
        self.refreshIntegrityLocked();
        return result;
    }

    pub fn counterValue(
        self: *Harness,
        target_key: u64,
    ) Error!i64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        if (target_key == 0) return Error.InvalidState;
        return self.valueForTarget(target_key);
    }

    pub fn snapshot(self: *Harness) Error!SnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        return self.snapshotLocked();
    }

    fn snapshotLocked(self: *Harness) SnapshotV1 {
        var result: SnapshotV1 = .{
            .harness_epoch = self.config.harness_epoch,
            .harness_id = self.config.harness_id,
            .next_execution_sequence = self.next_execution_sequence,
            .next_prepare_generation = self.next_prepare_generation,
            .pending = self.pending.state != .free,
            .counts = self.counts,
        };
        for (self.ledger) |slot|
            if (slot.active) {
                result.active_ledger_slots += 1;
            };
        for (self.counters) |slot|
            if (slot.active) {
                result.active_counter_slots += 1;
            };
        result.state_sha256 = self.stateSha256(result);
        return result;
    }

    pub fn close(self: *Harness) Error!SnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsableLocked();
        if (self.pending.state != .free) return Error.InvalidState;
        const result = self.snapshotLocked();
        for (self.ledger) |*slot| slot.* = .{};
        for (self.counters) |*slot| slot.* = .{};
        self.initialized = false;
        self.self_address = 0;
        self.retained_integrity_sha256 = zero_digest;
        return result;
    }

    fn requireStableLocked(self: *Harness) Error!void {
        if (!self.initialized) return Error.InvalidState;
        if (self.self_address != @intFromPtr(self))
            return Error.AddressChanged;
        validateConfigV1(self.config) catch return Error.StateDrift;
        if (!digestEqual(
            self.configuration_sha256,
            configurationSha256V1(self.config),
        ) or self.ledger.len == 0 or self.counters.len == 0 or
            self.ledger.len > maximum_storage_slots or
            self.counters.len > maximum_storage_slots or
            self.ledger_storage_address !=
                @intFromPtr(self.ledger.ptr) or
            self.ledger_storage_length != self.ledger.len or
            self.counter_storage_address !=
                @intFromPtr(self.counters.ptr) or
            self.counter_storage_length != self.counters.len or
            storageOverlaps(self.ledger, self.counters) or
            sliceOverlapsValue(self.ledger, self) or
            sliceOverlapsValue(self.counters, self) or
            !digestEqual(
                self.retained_integrity_sha256,
                self.retainedIntegritySha256Locked(),
            ))
            return Error.StateDrift;
    }

    fn requireUsableLocked(self: *Harness) Error!void {
        try self.requireStableLocked();
        try self.validateGlobalInvariantsLocked();
    }

    fn validateGlobalInvariantsLocked(self: *Harness) Error!void {
        var active_ledger_slots: u64 = 0;
        for (self.ledger, 0..) |slot, index| {
            if (!slot.active) {
                if (!std.meta.eql(slot, LedgerSlotV1{}))
                    return Error.StateDrift;
                continue;
            }
            validateLedgerSlotWithDescriptor(
                slot,
                self.config.descriptor,
                self.config.policy,
            ) catch return Error.StateDrift;
            active_ledger_slots = checkedAdd(
                active_ledger_slots,
                1,
            ) catch return Error.StateDrift;
            if (slot.effect.execution_sequence >=
                self.next_execution_sequence or
                self.findCounter(slot.effect.target_key) == null)
                return Error.StateDrift;
            for (self.ledger[0..index]) |prior| {
                if (!prior.active) continue;
                if (digestEqual(
                    prior.proposal.idempotency_key_sha256,
                    slot.proposal.idempotency_key_sha256,
                ) or prior.effect.execution_sequence ==
                    slot.effect.execution_sequence)
                    return Error.StateDrift;
            }
        }

        for (self.counters, 0..) |slot, index| {
            if (!slot.active) {
                if (!std.meta.eql(slot, CounterSlotV1{}))
                    return Error.StateDrift;
                continue;
            }
            if (slot.target_key == 0) return Error.StateDrift;
            for (self.counters[0..index]) |prior| {
                if (prior.active and prior.target_key == slot.target_key)
                    return Error.StateDrift;
            }
            var latest_sequence: u64 = 0;
            var expected_value: i64 = 0;
            for (self.ledger) |ledger_slot| {
                if (ledger_slot.active and
                    ledger_slot.effect.target_key == slot.target_key and
                    ledger_slot.effect.execution_sequence >
                        latest_sequence)
                {
                    latest_sequence =
                        ledger_slot.effect.execution_sequence;
                    expected_value = ledger_slot.effect.after_value;
                }
            }
            if (latest_sequence == 0 or slot.value != expected_value)
                return Error.StateDrift;
        }

        const expected_next_execution = checkedAdd(
            self.counts.executed,
            1,
        ) catch return Error.StateDrift;
        const terminal_count = countsTotalV1(self.counts) catch
            return Error.StateDrift;
        if (active_ledger_slots != self.counts.executed or
            self.next_execution_sequence != expected_next_execution or
            self.next_prepare_generation == 0 or
            terminal_count != self.counts.deliveries)
            return Error.StateDrift;

        switch (self.pending.state) {
            .free => if (!std.meta.eql(self.pending, PendingV1{}))
                return Error.StateDrift,
            .prepared => {
                if (!preparedValidV1(self.pending.prepared) or
                    !std.meta.eql(
                        self.pending.armed,
                        ArmedTokenV1{},
                    ) or !std.meta.eql(
                    self.pending.intent,
                    qos.ServiceIntentV1{},
                ) or !digestIsZero(
                    self.pending.final_event_sha256,
                ) or !std.meta.eql(
                    self.pending.delivery,
                    action.DeliveryReceiptV1{},
                ))
                    return Error.StateDrift;
                try self.validatePendingCandidateLocked();
            },
            .armed => {
                if (!preparedValidV1(self.pending.prepared) or
                    !armedTokenValidV1(self.pending.armed) or
                    !intentMatchesPermit(
                        self.pending.intent,
                        self.pending.permit,
                    ) or !digestIsZero(
                    self.pending.final_event_sha256,
                ) or !std.meta.eql(
                    self.pending.delivery,
                    action.DeliveryReceiptV1{},
                ))
                    return Error.StateDrift;
                try self.validatePendingCandidateLocked();
            },
            .precommitted => return Error.StateDrift,
            .finalized => try self.validateFinalizedStateLocked(),
        }
    }

    fn validatePendingCandidateLocked(self: *Harness) Error!void {
        const pending = self.pending;
        if (!validFinalPermit(pending.permit) or
            !preparedValidV1(pending.prepared) or
            pending.prepared.harness_epoch !=
                self.config.harness_epoch or
            pending.prepared.harness_id != self.config.harness_id or
            !digestEqual(
                pending.prepared.configuration_sha256,
                self.configuration_sha256,
            ) or !digestEqual(
            pending.prepared.proposal_sha256,
            pending.proposal.proposal_sha256,
        ) or !digestEqual(
            pending.prepared.permit_sha256,
            pending.permit.permit_sha256,
        ) or !digestEqual(
            pending.prepared.candidate_sha256,
            pending.candidate_sha256,
        ))
            return Error.StateDrift;
        if (pending.state == .armed and
            (!armedTokenValidV1(pending.armed) or
                pending.armed.harness_epoch !=
                    self.config.harness_epoch or
                pending.armed.harness_id != self.config.harness_id or
                pending.armed.generation !=
                    pending.prepared.generation or
                !digestEqual(
                    pending.armed.prepared_sha256,
                    pending.prepared.prepared_sha256,
                ) or !digestEqual(
                pending.armed.intent_sha256,
                pending.intent.intent_sha256,
            ) or !digestEqual(
                pending.armed.candidate_sha256,
                pending.candidate_sha256,
            )))
            return Error.StateDrift;
        action.validateProposalCompositionV1(
            pending.proposal,
            self.config.descriptor,
            pending.arguments,
        ) catch return Error.StateDrift;
        action.validateAuthorizationCompositionV1(
            pending.gate_authorization,
            pending.proposal,
            self.config.policy,
        ) catch return Error.StateDrift;
        action.validateAuthorizationCompositionV1(
            pending.authorization,
            pending.proposal,
            self.config.policy,
        ) catch return Error.StateDrift;
        const expected_gate = action.authorizeBoundedAddV1(
            pending.proposal,
            self.config.descriptor,
            pending.arguments,
            self.config.policy,
            pending.gate_authorization.observed_before,
        ) catch return Error.StateDrift;
        if (!std.meta.eql(
            expected_gate,
            pending.gate_authorization,
        ))
            return Error.StateDrift;
        switch (pending.disposition) {
            .executed => {
                if (!std.meta.eql(
                    pending.authorization,
                    pending.gate_authorization,
                ) or pending.gate_authorization.kind != .allowed or
                    pending.ledger_index == no_slot or
                    pending.counter_index == no_slot or
                    self.valueForTarget(pending.arguments.target_key) !=
                        pending.gate_authorization.observed_before)
                    return Error.StateDrift;
                action.validateEffectCompositionV1(
                    pending.effect,
                    pending.proposal,
                    pending.arguments,
                    pending.authorization,
                ) catch return Error.StateDrift;
                const ledger_index = slotIndex(
                    pending.ledger_index,
                    self.ledger.len,
                ) orelse return Error.StateDrift;
                const counter_index = slotIndex(
                    pending.counter_index,
                    self.counters.len,
                ) orelse return Error.StateDrift;
                if (self.ledger[ledger_index].active)
                    return Error.StateDrift;
                const counter = self.counters[counter_index];
                if (counter.active and
                    counter.target_key != pending.arguments.target_key)
                    return Error.StateDrift;
                const current = if (counter.active) counter.value else 0;
                if (current != pending.effect.before_value)
                    return Error.StateDrift;
            },
            .reused => {
                const index = slotIndex(
                    pending.ledger_index,
                    self.ledger.len,
                ) orelse return Error.StateDrift;
                try validateLedgerSlotWithDescriptor(
                    self.ledger[index],
                    self.config.descriptor,
                    self.config.policy,
                );
                if (!std.meta.eql(
                    self.ledger[index].effect,
                    pending.effect,
                ) or !std.meta.eql(
                    self.ledger[index].proposal,
                    pending.proposal,
                ) or !std.meta.eql(
                    self.ledger[index].arguments,
                    pending.arguments,
                ) or !std.meta.eql(
                    self.ledger[index].authorization,
                    pending.authorization,
                ) or !std.meta.eql(
                    pending.authorization,
                    pending.gate_authorization,
                ) or pending.gate_authorization.kind != .allowed or
                    pending.counter_index != no_slot)
                    return Error.StateDrift;
            },
            .conflict => {
                const index = slotIndex(
                    pending.ledger_index,
                    self.ledger.len,
                ) orelse return Error.StateDrift;
                try validateLedgerSlotWithDescriptor(
                    self.ledger[index],
                    self.config.descriptor,
                    self.config.policy,
                );
                const expected_conflict =
                    action.denyIdempotencyConflictV1(
                        pending.proposal,
                        self.config.policy,
                        pending.gate_authorization.observed_before,
                    ) catch return Error.StateDrift;
                if (!std.meta.eql(
                    self.ledger[index].effect,
                    pending.effect,
                ) or digestEqual(
                    self.ledger[index].proposal.proposal_sha256,
                    pending.proposal.proposal_sha256,
                ) or !std.meta.eql(
                    pending.authorization,
                    expected_conflict,
                ) or
                    pending.gate_authorization.kind != .allowed or
                    pending.counter_index != no_slot or
                    self.valueForTarget(pending.arguments.target_key) !=
                        pending.gate_authorization.observed_before)
                    return Error.StateDrift;
            },
            .denied => {
                if (!std.meta.eql(
                    pending.authorization,
                    pending.gate_authorization,
                ) or pending.authorization.kind != .denied or
                    pending.authorization.reason ==
                        .idempotency_conflict or
                    !std.meta.eql(
                        pending.effect,
                        action.EffectReceiptV1{},
                    ) or self.valueForTarget(
                    pending.arguments.target_key,
                ) != pending.gate_authorization.observed_before or
                    pending.ledger_index != no_slot or
                    pending.counter_index != no_slot)
                    return Error.StateDrift;
            },
        }
        const expected_counts = countsAfterV1(
            self.counts,
            pending.disposition,
        ) catch return Error.StateDrift;
        const expected_next_sequence =
            if (pending.disposition == .executed)
                checkedAdd(
                    self.next_execution_sequence,
                    1,
                ) catch return Error.StateDrift
            else
                self.next_execution_sequence;
        const expected_effect_sha256 =
            if (pending.disposition == .denied)
                zero_digest
            else
                pending.effect.effect_sha256;
        const expected_output_sha256: Digest =
            switch (pending.disposition) {
                .executed, .reused => pending.effect.output_sha256,
                .denied => action.terminalOutputSha256V1(
                    .denied,
                    pending.proposal,
                    pending.authorization,
                    zero_digest,
                ),
                .conflict => action.terminalOutputSha256V1(
                    .conflict,
                    pending.proposal,
                    pending.authorization,
                    pending.effect.effect_sha256,
                ),
            };
        if (!std.meta.eql(pending.counts_after, expected_counts) or
            pending.next_execution_sequence_after !=
                expected_next_sequence or
            !digestEqual(
                pending.delivery_effect_sha256,
                expected_effect_sha256,
            ) or !digestEqual(
            pending.delivery_output_sha256,
            expected_output_sha256,
        ) or !digestEqual(
            pending.candidate_sha256,
            candidateSha256V1(pending),
        ) or !digestEqual(
            pending.prepared.candidate_sha256,
            pending.candidate_sha256,
        ))
            return Error.StateDrift;
    }

    fn validateFinalizedStateLocked(self: *Harness) Error!void {
        const pending = self.pending;
        if (pending.state != .finalized or
            !validFinalPermit(pending.permit) or
            !preparedValidV1(pending.prepared) or
            !armedTokenValidV1(pending.armed) or
            !intentMatchesPermit(pending.intent, pending.permit) or
            pending.prepared.harness_epoch !=
                self.config.harness_epoch or
            pending.prepared.harness_id != self.config.harness_id or
            !digestEqual(
                pending.prepared.configuration_sha256,
                self.configuration_sha256,
            ) or !digestEqual(
            pending.prepared.proposal_sha256,
            pending.proposal.proposal_sha256,
        ) or !digestEqual(
            pending.prepared.permit_sha256,
            pending.permit.permit_sha256,
        ) or !digestEqual(
            pending.prepared.candidate_sha256,
            pending.candidate_sha256,
        ) or pending.armed.harness_epoch !=
            self.config.harness_epoch or
            pending.armed.harness_id != self.config.harness_id or
            pending.armed.generation != pending.prepared.generation or
            !digestEqual(
                pending.armed.prepared_sha256,
                pending.prepared.prepared_sha256,
            ) or !digestEqual(
            pending.armed.intent_sha256,
            pending.intent.intent_sha256,
        ) or !digestEqual(
            pending.armed.candidate_sha256,
            pending.candidate_sha256,
        ) or !digestEqual(
            pending.candidate_sha256,
            candidateSha256V1(pending),
        ) or !std.meta.eql(self.counts, pending.counts_after) or
            self.next_execution_sequence !=
                pending.next_execution_sequence_after or
            digestIsZero(pending.final_event_sha256))
            return Error.StateDrift;
        action.validateProposalCompositionV1(
            pending.proposal,
            self.config.descriptor,
            pending.arguments,
        ) catch return Error.StateDrift;
        action.validateAuthorizationCompositionV1(
            pending.authorization,
            pending.proposal,
            self.config.policy,
        ) catch return Error.StateDrift;
        action.validateAuthorizationCompositionV1(
            pending.gate_authorization,
            pending.proposal,
            self.config.policy,
        ) catch return Error.StateDrift;
        const expected_gate = action.authorizeBoundedAddV1(
            pending.proposal,
            self.config.descriptor,
            pending.arguments,
            self.config.policy,
            pending.gate_authorization.observed_before,
        ) catch return Error.StateDrift;
        if (!std.meta.eql(expected_gate, pending.gate_authorization))
            return Error.StateDrift;

        var counts_before = pending.counts_after;
        if (counts_before.deliveries == 0) return Error.StateDrift;
        counts_before.deliveries -= 1;
        switch (pending.disposition) {
            .executed => {
                if (counts_before.executed == 0)
                    return Error.StateDrift;
                counts_before.executed -= 1;
            },
            .reused => {
                if (counts_before.reused == 0)
                    return Error.StateDrift;
                counts_before.reused -= 1;
            },
            .conflict => {
                if (counts_before.conflicts == 0)
                    return Error.StateDrift;
                counts_before.conflicts -= 1;
            },
            .denied => {
                if (counts_before.denied == 0)
                    return Error.StateDrift;
                counts_before.denied -= 1;
            },
        }
        const expected_counts = countsAfterV1(
            counts_before,
            pending.disposition,
        ) catch return Error.StateDrift;
        if (!std.meta.eql(expected_counts, pending.counts_after))
            return Error.StateDrift;

        switch (pending.disposition) {
            .executed => {
                if (!std.meta.eql(
                    pending.authorization,
                    pending.gate_authorization,
                ) or pending.gate_authorization.kind != .allowed or
                    pending.next_execution_sequence_after !=
                        (checkedAdd(
                            pending.effect.execution_sequence,
                            1,
                        ) catch return Error.StateDrift))
                    return Error.StateDrift;
                action.validateEffectCompositionV1(
                    pending.effect,
                    pending.proposal,
                    pending.arguments,
                    pending.authorization,
                ) catch return Error.StateDrift;
                const ledger_index = slotIndex(
                    pending.ledger_index,
                    self.ledger.len,
                ) orelse return Error.StateDrift;
                const counter_index = slotIndex(
                    pending.counter_index,
                    self.counters.len,
                ) orelse return Error.StateDrift;
                if (!std.meta.eql(
                    self.ledger[ledger_index],
                    LedgerSlotV1{
                        .active = true,
                        .proposal = pending.proposal,
                        .arguments = pending.arguments,
                        .authorization = pending.authorization,
                        .effect = pending.effect,
                    },
                ) or !self.counters[counter_index].active or
                    self.counters[counter_index].target_key !=
                        pending.effect.target_key or
                    self.counters[counter_index].value !=
                        pending.effect.after_value)
                    return Error.StateDrift;
            },
            .reused => {
                const index = slotIndex(
                    pending.ledger_index,
                    self.ledger.len,
                ) orelse return Error.StateDrift;
                if (!std.meta.eql(
                    pending.authorization,
                    pending.gate_authorization,
                ) or pending.gate_authorization.kind != .allowed or
                    pending.counter_index != no_slot or
                    !std.meta.eql(
                        self.ledger[index],
                        LedgerSlotV1{
                            .active = true,
                            .proposal = pending.proposal,
                            .arguments = pending.arguments,
                            .authorization = pending.authorization,
                            .effect = pending.effect,
                        },
                    ))
                    return Error.StateDrift;
            },
            .conflict => {
                const index = slotIndex(
                    pending.ledger_index,
                    self.ledger.len,
                ) orelse return Error.StateDrift;
                try validateLedgerSlotWithDescriptor(
                    self.ledger[index],
                    self.config.descriptor,
                    self.config.policy,
                );
                const expected_conflict =
                    action.denyIdempotencyConflictV1(
                        pending.proposal,
                        self.config.policy,
                        pending.gate_authorization.observed_before,
                    ) catch return Error.StateDrift;
                if (!std.meta.eql(
                    pending.authorization,
                    expected_conflict,
                ) or pending.gate_authorization.kind != .allowed or
                    pending.counter_index != no_slot or
                    !std.meta.eql(
                        self.ledger[index].effect,
                        pending.effect,
                    ) or !digestEqual(
                    self.ledger[index]
                        .proposal.idempotency_key_sha256,
                    pending.proposal.idempotency_key_sha256,
                ) or digestEqual(
                    self.ledger[index].proposal.proposal_sha256,
                    pending.proposal.proposal_sha256,
                ) or self.valueForTarget(
                    pending.arguments.target_key,
                ) != pending.gate_authorization.observed_before)
                    return Error.StateDrift;
            },
            .denied => {
                if (!std.meta.eql(
                    pending.effect,
                    action.EffectReceiptV1{},
                ) or !std.meta.eql(
                    pending.authorization,
                    pending.gate_authorization,
                ) or pending.authorization.kind != .denied or
                    pending.authorization.reason ==
                        .idempotency_conflict or
                    pending.ledger_index != no_slot or
                    pending.counter_index != no_slot or
                    self.valueForTarget(
                        pending.arguments.target_key,
                    ) != pending.gate_authorization.observed_before)
                    return Error.StateDrift;
            },
        }

        const expected_effect_sha256: Digest =
            if (pending.disposition == .denied)
                zero_digest
            else
                pending.effect.effect_sha256;
        const expected_output_sha256: Digest =
            switch (pending.disposition) {
                .executed, .reused => pending.effect.output_sha256,
                .denied => action.terminalOutputSha256V1(
                    .denied,
                    pending.proposal,
                    pending.authorization,
                    zero_digest,
                ),
                .conflict => action.terminalOutputSha256V1(
                    .conflict,
                    pending.proposal,
                    pending.authorization,
                    pending.effect.effect_sha256,
                ),
            };
        if (!digestEqual(
            pending.delivery_effect_sha256,
            expected_effect_sha256,
        ) or !digestEqual(
            pending.delivery_output_sha256,
            expected_output_sha256,
        ) or !digestEqual(
            pending.delivery.effect_sha256,
            expected_effect_sha256,
        ) or !digestEqual(
            pending.delivery.output_sha256,
            expected_output_sha256,
        ) or !digestEqual(
            pending.delivery.service_event_sha256,
            pending.final_event_sha256,
        ))
            return Error.StateDrift;
        const maybe_effect: ?action.EffectReceiptV1 =
            if (pending.disposition == .denied)
                null
            else
                pending.effect;
        action.validateDeliveryCompositionV1(
            pending.delivery,
            pending.proposal,
            pending.authorization,
            maybe_effect,
            pending.final_event_sha256,
        ) catch return Error.StateDrift;
    }

    fn findLedger(self: *Harness, key: Digest) ?usize {
        for (self.ledger, 0..) |slot, index| {
            if (slot.active and
                digestEqual(
                    slot.proposal.idempotency_key_sha256,
                    key,
                ))
                return index;
        }
        return null;
    }

    fn freeLedger(self: *Harness) ?usize {
        for (self.ledger, 0..) |slot, index|
            if (!slot.active) return index;
        return null;
    }

    fn findCounter(self: *Harness, target_key: u64) ?usize {
        for (self.counters, 0..) |slot, index|
            if (slot.active and slot.target_key == target_key) return index;
        return null;
    }

    fn freeCounter(self: *Harness) ?usize {
        for (self.counters, 0..) |slot, index|
            if (!slot.active) return index;
        return null;
    }

    fn valueForTarget(self: *Harness, target_key: u64) i64 {
        const index = self.findCounter(target_key) orelse return 0;
        return self.counters[index].value;
    }

    fn refreshIntegrityLocked(self: *Harness) void {
        self.retained_integrity_sha256 =
            self.retainedIntegritySha256Locked();
    }

    /// Process-local integrity fence. Storage addresses deliberately make this
    /// root non-portable, so it never appears in `SnapshotV1` or state roots.
    fn retainedIntegritySha256Locked(self: *Harness) Digest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(retained_integrity_domain);
        hash.update(&self.configuration_sha256);
        const current_configuration =
            configurationSha256V1(self.config);
        hash.update(&current_configuration);
        const current_descriptor =
            action.descriptorSha256V1(self.config.descriptor);
        hash.update(&current_descriptor);
        const current_policy =
            action.policySha256V1(self.config.policy);
        hash.update(&current_policy);
        hashU8(&hash, @intFromBool(self.initialized));
        hashU64(&hash, @intCast(self.self_address));
        hashU64(&hash, @intCast(self.ledger_storage_address));
        hashU64(&hash, @intCast(self.ledger_storage_length));
        hashU64(&hash, @intCast(self.counter_storage_address));
        hashU64(&hash, @intCast(self.counter_storage_length));
        hashU64(&hash, @intCast(@intFromPtr(self.ledger.ptr)));
        hashU64(&hash, @intCast(self.ledger.len));
        hashU64(&hash, @intCast(@intFromPtr(self.counters.ptr)));
        hashU64(&hash, @intCast(self.counters.len));
        hashU64(&hash, self.next_execution_sequence);
        hashU64(&hash, self.next_prepare_generation);
        hashCounts(&hash, self.counts);

        for (self.ledger) |slot| {
            hashU8(&hash, @intFromBool(slot.active));
            hash.update(&slot.proposal.proposal_sha256);
            const proposal_identity =
                action.actionProposalSha256V1(slot.proposal);
            hash.update(&proposal_identity);
            hash.update(&slot.arguments.arguments_sha256);
            const arguments_identity =
                action.boundedAddArgumentsSha256V1(slot.arguments);
            hash.update(&arguments_identity);
            hash.update(&slot.authorization.authorization_sha256);
            const authorization_identity =
                action.authorizationSha256V1(slot.authorization);
            hash.update(&authorization_identity);
            hash.update(&slot.effect.effect_sha256);
            const effect_identity =
                action.effectSha256V1(slot.effect);
            hash.update(&effect_identity);
        }
        for (self.counters) |slot| {
            hashU8(&hash, @intFromBool(slot.active));
            hashU64(&hash, slot.target_key);
            hashI64(&hash, slot.value);
        }

        hashU8(&hash, @intFromEnum(self.pending.state));
        hash.update(&self.pending.prepared.prepared_sha256);
        const prepared_identity =
            preparedSha256V1(self.pending.prepared);
        hash.update(&prepared_identity);
        hash.update(&self.pending.armed.armed_sha256);
        const armed_identity =
            armedTokenSha256V1(self.pending.armed);
        hash.update(&armed_identity);
        hash.update(&self.pending.permit.permit_sha256);
        const permit_identity =
            qos.servicePermitSha256(self.pending.permit);
        hash.update(&permit_identity);
        hash.update(&self.pending.intent.intent_sha256);
        const intent_identity =
            qos.serviceIntentSha256(self.pending.intent);
        hash.update(&intent_identity);
        hash.update(&self.pending.proposal.proposal_sha256);
        const pending_proposal_identity =
            action.actionProposalSha256V1(self.pending.proposal);
        hash.update(&pending_proposal_identity);
        hash.update(&self.pending.arguments.arguments_sha256);
        const pending_arguments_identity =
            action.boundedAddArgumentsSha256V1(
                self.pending.arguments,
            );
        hash.update(&pending_arguments_identity);
        hash.update(
            &self.pending.gate_authorization.authorization_sha256,
        );
        const gate_authorization_identity =
            action.authorizationSha256V1(
                self.pending.gate_authorization,
            );
        hash.update(&gate_authorization_identity);
        hash.update(&self.pending.authorization.authorization_sha256);
        const pending_authorization_identity =
            action.authorizationSha256V1(
                self.pending.authorization,
            );
        hash.update(&pending_authorization_identity);
        hash.update(&self.pending.effect.effect_sha256);
        const pending_effect_identity =
            action.effectSha256V1(self.pending.effect);
        hash.update(&pending_effect_identity);
        hashU8(&hash, @intFromEnum(self.pending.disposition));
        hashU32(&hash, self.pending.ledger_index);
        hashU32(&hash, self.pending.counter_index);
        hashCounts(&hash, self.pending.counts_after);
        hashU64(&hash, self.pending.next_execution_sequence_after);
        hash.update(&self.pending.delivery_effect_sha256);
        hash.update(&self.pending.delivery_output_sha256);
        hash.update(&self.pending.candidate_sha256);
        hash.update(&self.pending.final_event_sha256);
        hash.update(&self.pending.delivery.delivery_sha256);
        const delivery_identity =
            action.deliverySha256V1(self.pending.delivery);
        hash.update(&delivery_identity);
        return finishDigest(&hash);
    }

    fn stateSha256(self: *Harness, snapshot_value: SnapshotV1) Digest {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(state_domain);
        hashU64(&hash, snapshot_value.abi_version);
        hashU64(&hash, snapshot_value.harness_epoch);
        hashU64(&hash, snapshot_value.harness_id);
        hashU64(&hash, snapshot_value.active_ledger_slots);
        hashU64(&hash, snapshot_value.active_counter_slots);
        hashU64(&hash, snapshot_value.next_execution_sequence);
        hashU64(&hash, snapshot_value.next_prepare_generation);
        hashU8(&hash, @intFromBool(snapshot_value.pending));
        hashCounts(&hash, snapshot_value.counts);
        for (self.ledger) |slot| {
            hashU8(&hash, @intFromBool(slot.active));
            hash.update(&slot.effect.effect_sha256);
        }
        for (self.counters) |slot| {
            hashU8(&hash, @intFromBool(slot.active));
            hashU64(&hash, slot.target_key);
            hashI64(&hash, slot.value);
        }
        return finishDigest(&hash);
    }
};

pub fn configurationSha256V1(config: ConfigV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(configuration_domain);
    hashU64(&hash, config.abi_version);
    hashU64(&hash, config.harness_epoch);
    hashU64(&hash, config.harness_id);
    hash.update(&config.challenge_sha256);
    hash.update(&config.descriptor.descriptor_sha256);
    hash.update(&config.policy.policy_sha256);
    return finishDigest(&hash);
}

pub fn validateConfigV1(config: ConfigV1) Error!void {
    try action.validateDescriptorV1(config.descriptor);
    try action.validatePolicyV1(config.policy);
    if (config.abi_version != harness_abi or config.harness_epoch == 0 or
        config.harness_id == 0 or digestIsZero(config.challenge_sha256) or
        !digestEqual(
            config.descriptor.descriptor_sha256,
            config.policy.descriptor_sha256,
        ))
        return Error.InvalidConfiguration;
}

pub fn preparedSha256V1(value: PreparedV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(prepared_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.harness_epoch);
    hashU64(&hash, value.harness_id);
    hashU64(&hash, value.generation);
    hash.update(&value.configuration_sha256);
    hash.update(&value.proposal_sha256);
    hash.update(&value.permit_sha256);
    hash.update(&value.candidate_sha256);
    return finishDigest(&hash);
}

pub fn preparedValidV1(value: PreparedV1) bool {
    return value.abi_version == prepared_abi and
        value.harness_epoch != 0 and value.harness_id != 0 and
        value.generation != 0 and
        !digestIsZero(value.configuration_sha256) and
        !digestIsZero(value.proposal_sha256) and
        !digestIsZero(value.permit_sha256) and
        !digestIsZero(value.candidate_sha256) and
        digestEqual(value.prepared_sha256, preparedSha256V1(value));
}

pub fn armedTokenSha256V1(value: ArmedTokenV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(armed_domain);
    hashU64(&hash, value.abi_version);
    hashU64(&hash, value.harness_epoch);
    hashU64(&hash, value.harness_id);
    hashU64(&hash, value.generation);
    hash.update(&value.prepared_sha256);
    hash.update(&value.intent_sha256);
    hash.update(&value.candidate_sha256);
    return finishDigest(&hash);
}

pub fn armedTokenValidV1(value: ArmedTokenV1) bool {
    return value.abi_version == armed_abi and
        value.harness_epoch != 0 and value.harness_id != 0 and
        value.generation != 0 and
        !digestIsZero(value.prepared_sha256) and
        !digestIsZero(value.intent_sha256) and
        !digestIsZero(value.candidate_sha256) and
        digestEqual(value.armed_sha256, armedTokenSha256V1(value));
}

fn makePreparedV1(
    config: ConfigV1,
    generation: u64,
    proposal_sha256: Digest,
    permit_sha256: Digest,
    candidate_sha256: Digest,
) PreparedV1 {
    var result: PreparedV1 = .{
        .harness_epoch = config.harness_epoch,
        .harness_id = config.harness_id,
        .generation = generation,
        .configuration_sha256 = configurationSha256V1(config),
        .proposal_sha256 = proposal_sha256,
        .permit_sha256 = permit_sha256,
        .candidate_sha256 = candidate_sha256,
    };
    result.prepared_sha256 = preparedSha256V1(result);
    return result;
}

fn makeArmedTokenV1(
    config: ConfigV1,
    prepared: PreparedV1,
    intent_sha256: Digest,
    candidate_sha256: Digest,
) ArmedTokenV1 {
    var result: ArmedTokenV1 = .{
        .harness_epoch = config.harness_epoch,
        .harness_id = config.harness_id,
        .generation = prepared.generation,
        .prepared_sha256 = prepared.prepared_sha256,
        .intent_sha256 = intent_sha256,
        .candidate_sha256 = candidate_sha256,
    };
    result.armed_sha256 = armedTokenSha256V1(result);
    return result;
}

fn candidateSha256V1(value: PendingV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(candidate_domain);
    hashU8(&hash, @intFromEnum(value.disposition));
    hash.update(&value.permit.permit_sha256);
    hash.update(&value.proposal.proposal_sha256);
    hash.update(&value.arguments.arguments_sha256);
    hash.update(&value.gate_authorization.authorization_sha256);
    hash.update(&value.authorization.authorization_sha256);
    hash.update(&value.effect.effect_sha256);
    hashU32(&hash, value.ledger_index);
    hashU32(&hash, value.counter_index);
    hashCounts(&hash, value.counts_after);
    hashU64(&hash, value.next_execution_sequence_after);
    hash.update(&value.delivery_effect_sha256);
    hash.update(&value.delivery_output_sha256);
    return finishDigest(&hash);
}

fn validFinalPermit(permit: qos.ServicePermitV1) bool {
    return permit.abi_version == qos.service_permit_abi and
        permit.remaining_before == 1 and
        permit.handle.tenant_key != 0 and
        !digestIsZero(permit.resource_receipt_sha256) and
        digestEqual(permit.permit_sha256, qos.servicePermitSha256(permit));
}

fn intentMatchesPermit(
    intent: qos.ServiceIntentV1,
    permit: qos.ServicePermitV1,
) bool {
    return qos.serviceIntentValidV1(intent) and validFinalPermit(permit) and
        intent.source_permit_abi == permit.abi_version and
        intent.scheduler_epoch == permit.scheduler_epoch and
        intent.event_sequence == permit.event_sequence and
        std.meta.eql(intent.handle, permit.handle) and
        intent.logical_tick_before == permit.logical_tick_before and
        intent.cursor_before == permit.cursor_before and
        intent.level_before == permit.level_before and
        intent.cursor_after == permit.cursor_after and
        intent.level_after == permit.level_after and
        intent.remaining_before == permit.remaining_before and
        intent.wait_quanta == permit.wait_quanta and
        intent.maximum_service_gap == permit.maximum_service_gap and
        digestEqual(
            intent.state_before_sha256,
            permit.state_before_sha256,
        ) and digestEqual(
        intent.chain_head_before_sha256,
        permit.chain_head_before_sha256,
    ) and std.meta.eql(
        intent.resource_receipt,
        permit.resource_receipt,
    ) and digestEqual(
        intent.resource_receipt_sha256,
        permit.resource_receipt_sha256,
    );
}

fn checkedAdd(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch
        Error.SequenceExhausted;
}

fn countsTotalV1(value: CountsV1) Error!u64 {
    var result = try checkedAdd(value.executed, value.reused);
    result = try checkedAdd(result, value.conflicts);
    return checkedAdd(result, value.denied);
}

fn countsAfterV1(
    before: CountsV1,
    disposition: action.DeliveryDispositionV1,
) Error!CountsV1 {
    var result = before;
    switch (disposition) {
        .executed => result.executed =
            try checkedAdd(result.executed, 1),
        .reused => result.reused =
            try checkedAdd(result.reused, 1),
        .conflict => result.conflicts =
            try checkedAdd(result.conflicts, 1),
        .denied => result.denied =
            try checkedAdd(result.denied, 1),
    }
    result.deliveries = try checkedAdd(result.deliveries, 1);
    return result;
}

fn transactionPrecommit(
    context: *anyopaque,
    intent: *const qos.ServiceIntentV1,
) bool {
    const self: *Harness = @ptrCast(@alignCast(context));
    self.mutex.lock();
    precommitLocked(self, intent.*) catch {
        self.mutex.unlock();
        return false;
    };
    return true;
}

fn precommitLocked(
    self: *Harness,
    intent: qos.ServiceIntentV1,
) Error!void {
    try self.requireUsableLocked();
    if (self.pending.state != .armed or
        !armedTokenValidV1(self.pending.armed) or
        !std.meta.eql(intent, self.pending.intent) or
        !digestEqual(
            self.pending.armed.intent_sha256,
            intent.intent_sha256,
        ))
        return Error.InvalidEvent;
    try self.validatePendingCandidateLocked();

    const maybe_effect: ?action.EffectReceiptV1 =
        if (self.pending.disposition == .denied)
            null
        else
            self.pending.effect;
    const delivery_proof = try action.makeDeliveryReceiptV1(
        self.pending.disposition,
        self.pending.proposal,
        self.pending.authorization,
        maybe_effect,
        intent.intent_sha256,
    );
    if (!digestEqual(
        delivery_proof.effect_sha256,
        self.pending.delivery_effect_sha256,
    ) or !digestEqual(
        delivery_proof.output_sha256,
        self.pending.delivery_output_sha256,
    ))
        return Error.StateDrift;

    self.pending.state = .precommitted;
    self.refreshIntegrityLocked();
}

/// The Scheduler calls this only after `precommitLocked` returns true and
/// while both coordinator locks remain held. Every index, digest, count, and
/// delivery field below was prevalidated, so publication cannot fail.
fn transactionFinalize(
    context: *anyopaque,
    event: *const qos.EventV1,
) void {
    const self: *Harness = @ptrCast(@alignCast(context));
    switch (self.pending.disposition) {
        .executed => {
            const ledger_index: usize =
                @intCast(self.pending.ledger_index);
            const counter_index: usize =
                @intCast(self.pending.counter_index);
            self.counters[counter_index] = .{
                .active = true,
                .target_key = self.pending.effect.target_key,
                .value = self.pending.effect.after_value,
            };
            self.ledger[ledger_index] = .{
                .active = true,
                .proposal = self.pending.proposal,
                .arguments = self.pending.arguments,
                .authorization = self.pending.authorization,
                .effect = self.pending.effect,
            };
        },
        .reused, .conflict, .denied => {},
    }
    self.counts = self.pending.counts_after;
    self.next_execution_sequence =
        self.pending.next_execution_sequence_after;
    var delivery: action.DeliveryReceiptV1 = .{
        .disposition = self.pending.disposition,
        .proposal_sha256 = self.pending.proposal.proposal_sha256,
        .authorization_sha256 = self.pending.authorization.authorization_sha256,
        .idempotency_key_sha256 = self.pending.proposal.idempotency_key_sha256,
        .effect_sha256 = self.pending.delivery_effect_sha256,
        .service_event_sha256 = event.event_sha256,
        .output_sha256 = self.pending.delivery_output_sha256,
    };
    delivery.delivery_sha256 = action.deliverySha256V1(delivery);
    self.pending.final_event_sha256 = event.event_sha256;
    self.pending.delivery = delivery;
    self.pending.state = .finalized;
    self.refreshIntegrityLocked();
    self.mutex.unlock();
}

fn validateLedgerSlotWithDescriptor(
    slot: LedgerSlotV1,
    descriptor: action.DescriptorV1,
    policy: action.PolicyV1,
) Error!void {
    if (!slot.active) return Error.StateDrift;
    try action.validateProposalCompositionV1(
        slot.proposal,
        descriptor,
        slot.arguments,
    );
    try action.validateAuthorizationCompositionV1(
        slot.authorization,
        slot.proposal,
        policy,
    );
    try action.validateEffectCompositionV1(
        slot.effect,
        slot.proposal,
        slot.arguments,
        slot.authorization,
    );
}

fn slotIndex(value: u32, length: usize) ?usize {
    if (value == no_slot) return null;
    const result: usize = @intCast(value);
    return if (result < length) result else null;
}

fn storageOverlaps(
    left: []LedgerSlotV1,
    right: []CounterSlotV1,
) bool {
    return spansOverlap(span(left), span(right));
}

fn sliceOverlapsValue(slice: anytype, value: anytype) bool {
    return spansOverlap(span(slice), .{
        .start = @intFromPtr(value),
        .end = std.math.add(
            usize,
            @intFromPtr(value),
            @sizeOf(@TypeOf(value.*)),
        ) catch return true,
    });
}

const Span = struct {
    start: usize,
    end: usize,
};

fn span(slice: anytype) Span {
    const start = @intFromPtr(slice.ptr);
    const bytes = std.math.mul(
        usize,
        slice.len,
        @sizeOf(std.meta.Child(@TypeOf(slice))),
    ) catch return .{ .start = start, .end = std.math.maxInt(usize) };
    return .{
        .start = start,
        .end = std.math.add(usize, start, bytes) catch
            std.math.maxInt(usize),
    };
}

fn spansOverlap(left: Span, right: Span) bool {
    return left.start < right.end and right.start < left.end;
}

fn hashCounts(hash: anytype, value: CountsV1) void {
    hashU64(hash, value.executed);
    hashU64(hash, value.reused);
    hashU64(hash, value.conflicts);
    hashU64(hash, value.denied);
    hashU64(hash, value.deliveries);
}

fn hashU8(hash: anytype, value: u8) void {
    hash.update(&.{value});
}

fn hashU32(hash: anytype, value: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashU64(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}

fn hashI64(hash: anytype, value: i64) void {
    hashU64(hash, @bitCast(value));
}

fn finishDigest(hash: anytype) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digestIsZero(value: Digest) bool {
    return std.mem.eql(u8, &value, &zero_digest);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

fn testDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

const TestRuntime = struct {
    bank_slots: [4]resource_bank.Slot = [_]resource_bank.Slot{.{}} ** 4,
    scheduler_slots: [4]qos.Slot = [_]qos.Slot{.{}} ** 4,
    projection: [4]qos.ProjectionSlot = [_]qos.ProjectionSlot{.{}} ** 4,
    bank: resource_bank.Bank = undefined,
    scheduler: qos.Scheduler = undefined,

    fn init(self: *@This()) !void {
        self.bank = try resource_bank.Bank.init(
            &self.bank_slots,
            .{
                .host_bytes = 1 << 20,
                .output_journal_bytes = 1 << 20,
                .staging_bytes = 1 << 20,
                .queue_slots = 4,
            },
            0x4241_4e4b,
        );
        self.scheduler = try qos.Scheduler.init(
            &self.bank,
            .{
                .slots = &self.scheduler_slots,
                .projection = &self.projection,
            },
            .{
                .scheduler_epoch = 0x5343_4844,
                .challenge = testDigest(0xa1),
                .max_weight = 8,
                .max_projection_quanta = 128,
                .max_projection_operations = 4096,
            },
        );
    }

    fn invoke(
        self: *@This(),
        harness: *Harness,
        request_key: u64,
        proposal: action.ActionProposalV1,
        arguments: action.BoundedAddArgumentsV1,
    ) !action.DeliveryReceiptV1 {
        return self.invokeWithSchedulerTenant(
            harness,
            request_key,
            proposal.tenant_key,
            proposal,
            arguments,
        );
    }

    fn invokeWithSchedulerTenant(
        self: *@This(),
        harness: *Harness,
        request_key: u64,
        scheduler_tenant_key: u64,
        proposal: action.ActionProposalV1,
        arguments: action.BoundedAddArgumentsV1,
    ) !action.DeliveryReceiptV1 {
        const decision = try self.scheduler.admit(.{
            .tenant_key = scheduler_tenant_key,
            .request_key = request_key,
            .request_generation = 1,
            .resource_owner_key = 10_000 + request_key,
            .weight = 1,
            .work_quanta = 1,
            .claim = .{
                .output_journal_bytes = 512,
                .staging_bytes = 512,
                .queue_slots = 1,
            },
        });
        const admission = switch (decision) {
            .admitted => |value| value,
            .rejected => return Error.CapacityExceeded,
        };
        const permit = try self.scheduler.prepareService();
        const prepared = try harness.prepare(proposal, arguments, permit);
        const scheduler_arm = try self.scheduler.armServiceCommit(permit);
        const tool_arm = try harness.arm(prepared, scheduler_arm);
        const event = try self.scheduler.commitArmedServiceTransaction(
            scheduler_arm.ticket,
            tool_arm.transaction,
        );
        const delivery = try harness.finish(tool_arm.token, event);
        _ = try self.scheduler.retire(admission.handle);
        return delivery;
    }
};

fn testConfig(
    allow: bool,
    maximum_delta: u64,
) !ConfigV1 {
    const descriptor = try action.makeDescriptorV1(
        0x544f_4f4c,
        testDigest(0x11),
        testDigest(0x12),
        testDigest(0x13),
        testDigest(0x14),
    );
    return .{
        .harness_epoch = 0x4841_524e,
        .harness_id = 0x4944,
        .challenge_sha256 = testDigest(0x15),
        .descriptor = descriptor,
        .policy = try action.makePolicyV1(
            1,
            41,
            allow,
            maximum_delta,
            -100,
            100,
            descriptor,
            testDigest(0x16),
        ),
    };
}

fn testProposal(
    config: ConfigV1,
    ordinal: u64,
    arguments: action.BoundedAddArgumentsV1,
    idempotency_byte: u8,
) !action.ActionProposalV1 {
    return action.makeActionProposalV1(
        41,
        ordinal,
        testDigest(0x20),
        config.descriptor,
        arguments,
        testDigest(idempotency_byte),
    );
}

test "tool harness executes reuses conflicts and denies without ambient IO" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 4;
    var counters = [_]CounterSlotV1{.{}} ** 2;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    const add_four = try action.makeBoundedAddArgumentsV1(7, 4);
    const first = try testProposal(config, 0, add_four, 0x31);
    const executed = try runtime.invoke(
        &harness,
        1,
        first,
        add_four,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.executed,
        executed.disposition,
    );
    try testing.expectEqual(@as(i64, 4), try harness.counterValue(7));

    const reused = try runtime.invoke(
        &harness,
        2,
        first,
        add_four,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.reused,
        reused.disposition,
    );
    try testing.expectEqual(executed.effect_sha256, reused.effect_sha256);
    try testing.expectEqual(@as(i64, 4), try harness.counterValue(7));

    const add_three = try action.makeBoundedAddArgumentsV1(7, 3);
    const conflicting = try testProposal(
        config,
        1,
        add_three,
        0x31,
    );
    const conflict = try runtime.invoke(
        &harness,
        3,
        conflicting,
        add_three,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.conflict,
        conflict.disposition,
    );
    try testing.expectEqual(executed.effect_sha256, conflict.effect_sha256);
    try testing.expectEqual(@as(i64, 4), try harness.counterValue(7));

    const add_five = try action.makeBoundedAddArgumentsV1(7, 5);
    const denied_proposal = try testProposal(
        config,
        2,
        add_five,
        0x31,
    );
    const denied = try runtime.invoke(
        &harness,
        4,
        denied_proposal,
        add_five,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.denied,
        denied.disposition,
    );
    try testing.expect(digestIsZero(denied.effect_sha256));
    try testing.expectEqual(@as(i64, 4), try harness.counterValue(7));

    const snapshot_value = try harness.snapshot();
    try testing.expectEqual(@as(u64, 1), snapshot_value.counts.executed);
    try testing.expectEqual(@as(u64, 1), snapshot_value.counts.reused);
    try testing.expectEqual(@as(u64, 1), snapshot_value.counts.conflicts);
    try testing.expectEqual(@as(u64, 1), snapshot_value.counts.denied);
    try testing.expectEqual(@as(u64, 4), snapshot_value.counts.deliveries);
    try testing.expectEqual(@as(u64, 1), snapshot_value.active_ledger_slots);
    try testing.expectEqual(@as(u64, 1), snapshot_value.active_counter_slots);
    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "tool harness rejects copied stale and prepared candidate drift" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 2;
    var counters = [_]CounterSlotV1{.{}} ** 1;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    var copied = harness;
    try testing.expectError(Error.AddressChanged, copied.snapshot());

    const arguments = try action.makeBoundedAddArgumentsV1(9, 2);
    const proposal = try testProposal(config, 0, arguments, 0x41);
    const decision = try runtime.scheduler.admit(.{
        .tenant_key = 41,
        .request_key = 1,
        .request_generation = 1,
        .resource_owner_key = 101,
        .weight = 1,
        .work_quanta = 1,
        .claim = .{ .staging_bytes = 64, .queue_slots = 1 },
    });
    const admission = switch (decision) {
        .admitted => |value| value,
        .rejected => unreachable,
    };
    const permit = try runtime.scheduler.prepareService();
    const stale = try harness.prepare(proposal, arguments, permit);
    try harness.abortPrepared(stale);
    const fresh = try harness.prepare(proposal, arguments, permit);
    const scheduler_arm = try runtime.scheduler.armServiceCommit(permit);
    try testing.expectError(
        Error.InvalidToken,
        harness.arm(stale, scheduler_arm),
    );

    const original_tenant = harness.pending.permit.handle.tenant_key;
    harness.pending.permit.handle.tenant_key += 1;
    try testing.expectError(
        Error.StateDrift,
        harness.arm(fresh, scheduler_arm),
    );
    harness.pending.permit.handle.tenant_key = original_tenant;

    const original_after = harness.pending.effect.after_value;
    harness.pending.effect.after_value += 1;
    try testing.expectError(
        Error.StateDrift,
        harness.arm(fresh, scheduler_arm),
    );
    harness.pending.effect.after_value = original_after;
    try harness.abortPrepared(fresh);
    try runtime.scheduler.abortArmedService(scheduler_arm.ticket);
    _ = try runtime.scheduler.cancel(admission.handle);
    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "tool harness detects direct storage drift and accepts exact restore" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 2;
    var counters = [_]CounterSlotV1{.{}} ** 2;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    const arguments = try action.makeBoundedAddArgumentsV1(17, 2);
    const proposal = try testProposal(config, 0, arguments, 0x51);
    _ = try runtime.invoke(&harness, 1, proposal, arguments);
    const stable = try harness.snapshot();

    const original_counter = counters[0];
    counters[0].value += 1;
    try testing.expectError(Error.StateDrift, harness.snapshot());
    counters[0] = original_counter;
    try testing.expectEqualDeep(stable, try harness.snapshot());

    const original_authorization = ledger[0].authorization;
    ledger[0].authorization.observed_before += 1;
    try testing.expectError(Error.StateDrift, harness.snapshot());
    ledger[0].authorization = original_authorization;
    try testing.expectEqualDeep(stable, try harness.snapshot());

    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "tool harness rejects duplicate active idempotency and target keys" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 3;
    var counters = [_]CounterSlotV1{.{}} ** 3;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    const arguments = try action.makeBoundedAddArgumentsV1(19, 2);
    const proposal = try testProposal(config, 0, arguments, 0x52);
    _ = try runtime.invoke(&harness, 1, proposal, arguments);
    const stable = try harness.snapshot();

    ledger[1] = ledger[0];
    harness.refreshIntegrityLocked();
    try testing.expectError(Error.StateDrift, harness.snapshot());
    ledger[1] = .{};
    harness.refreshIntegrityLocked();
    try testing.expectEqualDeep(stable, try harness.snapshot());

    counters[1] = counters[0];
    harness.refreshIntegrityLocked();
    try testing.expectError(Error.StateDrift, harness.snapshot());
    counters[1] = .{};
    harness.refreshIntegrityLocked();
    try testing.expectEqualDeep(stable, try harness.snapshot());

    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "foreign tenant duplicate proposal is policy denial not conflict" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 3;
    var counters = [_]CounterSlotV1{.{}} ** 2;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    const arguments = try action.makeBoundedAddArgumentsV1(21, 2);
    const original = try testProposal(config, 0, arguments, 0x53);
    const executed = try runtime.invoke(
        &harness,
        1,
        original,
        arguments,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.executed,
        executed.disposition,
    );
    const foreign = try action.makeActionProposalV1(
        99,
        1,
        testDigest(0x20),
        config.descriptor,
        arguments,
        original.idempotency_key_sha256,
    );
    const denied = try runtime.invoke(
        &harness,
        2,
        foreign,
        arguments,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.denied,
        denied.disposition,
    );
    try testing.expect(digestIsZero(denied.effect_sha256));
    try testing.expectEqual(@as(i64, 2), try harness.counterValue(21));
    const snapshot_value = try harness.snapshot();
    try testing.expectEqual(@as(u64, 0), snapshot_value.counts.conflicts);
    try testing.expectEqual(@as(u64, 1), snapshot_value.counts.denied);

    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "scheduler and authorization tenants are independent domains" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 2;
    var counters = [_]CounterSlotV1{.{}} ** 2;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    const arguments = try action.makeBoundedAddArgumentsV1(23, 2);
    const proposal = try testProposal(config, 0, arguments, 0x54);
    const delivery = try runtime.invokeWithSchedulerTenant(
        &harness,
        1,
        9_001,
        proposal,
        arguments,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.executed,
        delivery.disposition,
    );
    try testing.expectEqual(@as(i64, 2), try harness.counterValue(23));

    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "exact replay survives a later policy range boundary" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 4;
    var counters = [_]CounterSlotV1{.{}} ** 1;
    var harness: Harness = .{};
    const config = try testConfig(true, 100);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    const add_sixty = try action.makeBoundedAddArgumentsV1(25, 60);
    const first = try testProposal(config, 0, add_sixty, 0x55);
    const add_forty = try action.makeBoundedAddArgumentsV1(25, 40);
    const second = try testProposal(config, 1, add_forty, 0x56);
    const first_delivery = try runtime.invoke(
        &harness,
        1,
        first,
        add_sixty,
    );
    _ = try runtime.invoke(&harness, 2, second, add_forty);
    try testing.expectEqual(@as(i64, 100), try harness.counterValue(25));

    const replay = try runtime.invoke(
        &harness,
        3,
        first,
        add_sixty,
    );
    try testing.expectEqual(
        action.DeliveryDispositionV1.reused,
        replay.disposition,
    );
    try testing.expectEqual(
        first_delivery.effect_sha256,
        replay.effect_sha256,
    );
    try testing.expectEqual(@as(i64, 100), try harness.counterValue(25));

    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "post-arm drift rejects service transaction without either commit" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 2;
    var counters = [_]CounterSlotV1{.{}} ** 2;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();

    const arguments = try action.makeBoundedAddArgumentsV1(27, 2);
    const proposal = try testProposal(config, 0, arguments, 0x57);
    const decision = try runtime.scheduler.admit(.{
        .tenant_key = 707,
        .request_key = 1,
        .request_generation = 1,
        .resource_owner_key = 708,
        .weight = 1,
        .work_quanta = 1,
        .claim = .{ .staging_bytes = 64, .queue_slots = 1 },
    });
    const admission = switch (decision) {
        .admitted => |value| value,
        .rejected => unreachable,
    };
    const permit = try runtime.scheduler.prepareService();
    const prepared = try harness.prepare(proposal, arguments, permit);
    const scheduler_arm = try runtime.scheduler.armServiceCommit(permit);
    const tool_arm = try harness.arm(prepared, scheduler_arm);
    const scheduler_before = try runtime.scheduler.snapshot();
    const harness_before = try harness.snapshot();

    const original_after = harness.pending.effect.after_value;
    harness.pending.effect.after_value += 1;
    try testing.expectError(
        qos.Error.ServicePrecommitRejected,
        runtime.scheduler.commitArmedServiceTransaction(
            scheduler_arm.ticket,
            tool_arm.transaction,
        ),
    );
    harness.pending.effect.after_value = original_after;

    try testing.expectEqualDeep(
        scheduler_before,
        try runtime.scheduler.snapshot(),
    );
    try testing.expectEqualDeep(harness_before, try harness.snapshot());
    try testing.expect(!ledger[0].active);
    try testing.expect(!counters[0].active);
    try testing.expectEqual(@as(u64, 0), harness.counts.deliveries);

    try harness.abortArmed(tool_arm.token);
    try runtime.scheduler.abortArmedService(scheduler_arm.ticket);
    _ = try runtime.scheduler.cancel(admission.handle);
    _ = try runtime.scheduler.close();
    _ = try harness.close();
}

test "concurrent public readers preserve harness state and integrity" {
    const testing = std.testing;
    const Reader = struct {
        harness: *Harness,
        start: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),
        expected: SnapshotV1,
        target_key: u64,
        expected_value: i64,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire))
                std.atomic.spinLoopHint();
            var iteration: usize = 0;
            while (iteration < 256) : (iteration += 1) {
                const snapshot_value =
                    self.harness.snapshot() catch {
                        self.failed.store(true, .release);
                        return;
                    };
                if (!std.meta.eql(snapshot_value, self.expected)) {
                    self.failed.store(true, .release);
                    return;
                }
                const counter_value = self.harness.counterValue(
                    self.target_key,
                ) catch {
                    self.failed.store(true, .release);
                    return;
                };
                if (counter_value != self.expected_value) {
                    self.failed.store(true, .release);
                    return;
                }
            }
        }
    };

    var ledger = [_]LedgerSlotV1{.{}} ** 2;
    var counters = [_]CounterSlotV1{.{}} ** 2;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    var runtime: TestRuntime = .{};
    try runtime.init();
    const arguments = try action.makeBoundedAddArgumentsV1(31, 2);
    const proposal = try testProposal(config, 0, arguments, 0x59);
    _ = try runtime.invoke(&harness, 1, proposal, arguments);
    _ = try runtime.scheduler.close();

    const expected = try harness.snapshot();
    const integrity_before = harness.retained_integrity_sha256;
    var start = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var first: Reader = .{
        .harness = &harness,
        .start = &start,
        .failed = &failed,
        .expected = expected,
        .target_key = 31,
        .expected_value = 2,
    };
    var second = first;
    const first_thread = try std.Thread.spawn(
        .{},
        Reader.run,
        .{&first},
    );
    const second_thread = std.Thread.spawn(
        .{},
        Reader.run,
        .{&second},
    ) catch |err| {
        start.store(true, .release);
        first_thread.join();
        return err;
    };
    start.store(true, .release);
    first_thread.join();
    second_thread.join();

    try testing.expect(!failed.load(.acquire));
    try testing.expectEqualDeep(expected, try harness.snapshot());
    try testing.expect(digestEqual(
        integrity_before,
        harness.retained_integrity_sha256,
    ));
    _ = try harness.close();
}

test "maximum prepare generation rejects before harness mutation" {
    const testing = std.testing;
    var ledger = [_]LedgerSlotV1{.{}} ** 2;
    var counters = [_]CounterSlotV1{.{}} ** 2;
    var harness: Harness = .{};
    const config = try testConfig(true, 4);
    try harness.init(config, .{
        .ledger = &ledger,
        .counters = &counters,
    });
    harness.next_prepare_generation = std.math.maxInt(u64);
    harness.refreshIntegrityLocked();
    const harness_before = try harness.snapshot();

    var runtime: TestRuntime = .{};
    try runtime.init();
    const arguments = try action.makeBoundedAddArgumentsV1(29, 2);
    const proposal = try testProposal(config, 0, arguments, 0x58);
    const decision = try runtime.scheduler.admit(.{
        .tenant_key = 41,
        .request_key = 1,
        .request_generation = 1,
        .resource_owner_key = 710,
        .weight = 1,
        .work_quanta = 1,
        .claim = .{ .staging_bytes = 64, .queue_slots = 1 },
    });
    const admission = switch (decision) {
        .admitted => |value| value,
        .rejected => unreachable,
    };
    const permit = try runtime.scheduler.prepareService();
    try testing.expectError(
        Error.SequenceExhausted,
        harness.prepare(proposal, arguments, permit),
    );
    try testing.expectEqualDeep(harness_before, try harness.snapshot());

    try runtime.scheduler.abortService(permit);
    _ = try runtime.scheduler.cancel(admission.handle);
    _ = try runtime.scheduler.close();
    _ = try harness.close();
}
