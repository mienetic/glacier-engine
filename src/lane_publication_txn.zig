//! Backend-neutral, width-one AI token publication transactions.
//!
//! One Session binds the exact ResourceBank receipt admitted by LaneWeave to
//! a portable ServiceIntent, typed KV/RNG/sampler/output commitments, an
//! independently verifiable transcript and one private output sink. The sink
//! prepares fallibly without exposing state; LaneWeave then commits its
//! Event-v1 and runs the Bank/state/sink finalizer before another Scheduler
//! operation can observe the logical transition.
//!
//! This v1 contract is synchronous and in-process. It provides no durable
//! decision record, restart-stable authority or recovery after process loss.

const std = @import("std");
const core = @import("core");
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;

pub const abi: u64 = 0x474c_5054_0000_0001;
pub const state_commitment_abi: u64 = 0x474c_5053_0000_0001;
pub const token_transition_abi: u64 = 0x474c_5058_0000_0001;
pub const sink_abi: u64 = 0x474c_504b_0000_0001;
pub const prepare_ack_abi: u64 = 0x474c_5041_0000_0001;
pub const commit_receipt_abi: u64 = 0x474c_5043_0000_0001;
pub const transcript_snapshot_abi: u64 = 0x474c_5056_0000_0001;
pub const width: u8 = 1;
pub const live_mask: u8 = 1;
pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

const state_domain = "glacier-lane-publication-state-v1\x00";
const kv_domain = "glacier-lane-publication-kv-v1\x00";
const output_domain = "glacier-lane-publication-output-v1\x00";
const transition_domain = "glacier-lane-publication-transition-v1\x00";
const root_domain = "glacier-lane-publication-txn-root-v1\x00";
const proposal_domain = "glacier-lane-publication-txn-proposal-v1\x00";
const commit_domain = "glacier-lane-publication-txn-commit-v1\x00";

pub const Error = error{
    InvalidConfiguration,
    InvalidState,
    InvalidBinding,
    InvalidTransition,
    SequenceExhausted,
    ResourceReceiptInvalid,
    SinkRejected,
    InvalidPrepareAck,
    InvalidCommitReceipt,
    TranscriptSequenceMismatch,
    TranscriptChainMismatch,
    RecoveryRequired,
};

pub const SinkPrepareError = error{
    Unavailable,
    InvalidEvidence,
    CapacityExceeded,
};

/// Portable request-local state at one token boundary. Digests let execution
/// adapters choose their own concrete KV and RNG layouts while preserving one
/// common transcript contract.
pub const StateCommitmentV1 = struct {
    abi_version: u64 = state_commitment_abi,
    execution_abi: u64 = 0,
    kv_position: u64 = 0,
    kv_state_sha256: Digest = zero_digest,
    rng_state_abi: u64 = 0,
    rng_state_sha256: Digest = zero_digest,
    sampling_calls: u64 = 0,
    output_length: u64 = 0,
    output_state_sha256: Digest = zero_digest,
    commitment_sha256: Digest = zero_digest,
};

/// Exactly one selected token transition. The generic verifier proves the KV
/// row and output chains and bounded counter increments. A zero KV-row digest
/// is the explicit first-token-after-prefill case: KV position/state stay
/// unchanged. A nonzero digest commits exactly one row. Sampling advances by
/// zero or one; a zero advance requires unchanged RNG state. The execution
/// adapter remains responsible for proving that committed row/RNG digests came
/// from its actual kernel state.
pub const TokenTransitionV1 = struct {
    abi_version: u64 = token_transition_abi,
    before: StateCommitmentV1 = .{},
    after: StateCommitmentV1 = .{},
    kv_row_sha256: Digest = zero_digest,
    token_id: u32 = 0,
    terminal: bool = false,
    transition_sha256: Digest = zero_digest,
};

/// Complete portable proposal for one and only one LaneWeave service.
pub const ProposalV1 = struct {
    abi_version: u64 = abi,
    resource_bank_abi_version: u64 = resource_bank.abi,
    resource_publication_fence_abi: u64 =
        resource_bank.publication_fence_abi,
    lane_weave_abi_version: u64 = lane.abi,
    lane_event_abi_version: u64 = lane.event_abi,
    service_intent_abi_version: u64 = lane.service_intent_abi,
    sink_abi_version: u64 = sink_abi,
    prepare_ack_abi_version: u64 = prepare_ack_abi,
    commit_receipt_abi_version: u64 = commit_receipt_abi,
    execution_abi: u64 = 0,
    request_epoch: u64 = 0,
    transaction_sequence: u64 = 0,
    resource_permit_generation: u64 = 0,
    lane_width: u8 = width,
    live_lane_mask: u8 = live_mask,
    live_lane_count: u8 = 1,
    receipt: resource_bank.Receipt = zeroReceipt(),
    receipt_sha256: Digest = zero_digest,
    previous_transcript_sha256: Digest = zero_digest,
    service_intent: lane.ServiceIntentV1 = .{},
    service_intent_sha256: Digest = zero_digest,
    transition: TokenTransitionV1 = .{},
    transition_sha256: Digest = zero_digest,
};

pub const PrepareAckV1 = struct {
    abi_version: u64 = prepare_ack_abi,
    proposal_sha256: Digest = zero_digest,
    sink_epoch: u64 = 0,
    reservation_id: u64 = 0,
};

/// Self-contained binding receipt. Stateful transcript verification is
/// independent of Session and sink implementation details; replay the full
/// LaneWeave event stream separately to verify global QoS state.
pub const CommitReceiptV1 = struct {
    abi_version: u64 = commit_receipt_abi,
    proposal: ProposalV1,
    proposal_sha256: Digest,
    prepare_ack: PrepareAckV1,
    service_event: lane.EventV1,
    service_event_sha256: Digest,
    transcript_sha256: Digest,
};

/// A conforming sink keeps every proposed state change private during
/// `prepare`. Successful prepare reserves all memory and capacity required by
/// `commit`. No callback may re-enter Session, Scheduler or ResourceBank.
/// Commit/abort are bounded, infallible and allocation-free and may not block
/// or perform I/O.
pub const SinkV1 = struct {
    abi_version: u64 = sink_abi,
    context: *anyopaque,
    prepare: *const fn (
        context: *anyopaque,
        proposal: *const ProposalV1,
        ack: *PrepareAckV1,
    ) SinkPrepareError!void,
    commit: *const fn (
        context: *anyopaque,
        receipt: *const CommitReceiptV1,
    ) void,
    abort: *const fn (
        context: *anyopaque,
        proposal: *const ProposalV1,
        ack: *const PrepareAckV1,
    ) void,
};

pub const TranscriptSnapshotV1 = struct {
    abi_version: u64 = transcript_snapshot_abi,
    request_epoch: u64,
    execution_abi: u64,
    next_sequence: u64,
    last_resource_permit_generation: u64,
    terminal: bool,
    state: StateCommitmentV1,
    transcript_sha256: Digest,
};

/// Address-stable single-request coordinator. Initialize immediately after
/// admission, before another Scheduler event. Every selected service for this
/// request must then publish through this Session. Call `close` before LaneWeave
/// cancel/retire releases the receipt.
pub const Session = struct {
    mutex: std.Thread.Mutex = .{},
    scheduler: *lane.Scheduler = undefined,
    bank: *resource_bank.Bank = undefined,
    admission: lane.Admission = undefined,
    request_epoch: u64 = 0,
    execution_abi: u64 = 0,
    initialized: bool = false,
    next_sequence: u64 = 0,
    last_resource_permit_generation: u64 = 0,
    terminal: bool = false,
    state: StateCommitmentV1 = .{},
    transcript_sha256: Digest = zero_digest,

    pub fn init(
        self: *Session,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        admission: lane.Admission,
        request_epoch: u64,
        execution_abi: u64,
        initial_state: StateCommitmentV1,
    ) (Error || lane.Error)!void {
        if (self.initialized) return Error.InvalidState;
        if (request_epoch == 0 or execution_abi == 0 or
            scheduler.bank != bank or
            admission.event.spec.claim.queue_slots != width or
            initial_state.execution_abi != execution_abi or
            initial_state.output_length != 0 or
            initial_state.sampling_calls != 0 or
            !stateCommitmentValidV1(initial_state))
            return Error.InvalidConfiguration;

        try scheduler.bindPublicationSession(
            admission,
            request_epoch,
            @intFromPtr(self),
        );
        self.* = .{
            .scheduler = scheduler,
            .bank = bank,
            .admission = admission,
            .request_epoch = request_epoch,
            .execution_abi = execution_abi,
            .initialized = true,
            .state = initial_state,
            .transcript_sha256 = initialTranscriptSha256(
                execution_abi,
                request_epoch,
                admission.event.resource_receipt,
                initial_state,
            ),
        };
    }

    pub fn close(self: *Session) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized) return Error.InvalidState;
        self.bank.closePublicationSession(
            self.admission.event.resource_receipt,
            self.request_epoch,
            @intFromPtr(self),
            self.next_sequence,
        ) catch |err| switch (err) {
            error.StaleReservation => return Error.ResourceReceiptInvalid,
            else => return Error.InvalidState,
        };
        self.initialized = false;
    }

    pub fn snapshot(self: *Session) Error!TranscriptSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized) return Error.InvalidState;
        return .{
            .request_epoch = self.request_epoch,
            .execution_abi = self.execution_abi,
            .next_sequence = self.next_sequence,
            .last_resource_permit_generation = self.last_resource_permit_generation,
            .terminal = self.terminal,
            .state = self.state,
            .transcript_sha256 = self.transcript_sha256,
        };
    }

    /// Consume `permit` exactly once. All failures after arming either restore
    /// the Bank/sink/scheduler attempt for retry or return RecoveryRequired
    /// while the coordinator remains fail-closed.
    pub fn publish(
        self: *Session,
        permit: lane.ServicePermitV1,
        transition: TokenTransitionV1,
        sink: SinkV1,
    ) (Error || lane.Error)!CommitReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized) return Error.InvalidState;

        const armed = try self.scheduler.armServiceCommit(permit);
        if (sink.abi_version != sink_abi) {
            try self.abortArmedOnly(armed.ticket);
            return Error.InvalidConfiguration;
        }
        self.validateAttempt(armed.intent, transition) catch |err| {
            try self.abortArmedOnly(armed.ticket);
            return err;
        };

        const publication_permit = self.bank.beginPublication(
            self.admission.event.resource_receipt,
            self.request_epoch,
            @intFromPtr(self),
            self.next_sequence,
        ) catch |err| {
            try self.abortArmedOnly(armed.ticket);
            return mapBankError(err);
        };

        const proposal: ProposalV1 = .{
            .execution_abi = self.execution_abi,
            .request_epoch = self.request_epoch,
            .transaction_sequence = self.next_sequence,
            .resource_permit_generation = publication_permit.generation,
            .receipt = self.admission.event.resource_receipt,
            .receipt_sha256 = lane.resourceReceiptSha256(
                self.admission.event.resource_receipt,
            ),
            .previous_transcript_sha256 = self.transcript_sha256,
            .service_intent = armed.intent,
            .service_intent_sha256 = armed.intent.intent_sha256,
            .transition = transition,
            .transition_sha256 = transition.transition_sha256,
        };
        const proposal_sha256 = proposalSha256(proposal);
        if (!proposalValidV1(proposal)) {
            try self.rollbackAttempt(
                armed.ticket,
                publication_permit,
                null,
                proposal,
                .{},
            );
            return Error.InvalidState;
        }

        var ack: PrepareAckV1 = .{};
        sink.prepare(sink.context, &proposal, &ack) catch {
            try self.rollbackAttempt(
                armed.ticket,
                publication_permit,
                null,
                proposal,
                ack,
            );
            return Error.SinkRejected;
        };
        if (!prepareAckValidV1(ack, proposal_sha256)) {
            try self.rollbackAttempt(
                armed.ticket,
                publication_permit,
                sink,
                proposal,
                ack,
            );
            return Error.InvalidPrepareAck;
        }
        self.bank.validatePublication(publication_permit) catch {
            try self.rollbackAttempt(
                armed.ticket,
                publication_permit,
                sink,
                proposal,
                ack,
            );
            return Error.ResourceReceiptInvalid;
        };

        var finalizer_context: FinalizerContext = .{
            .session = self,
            .publication_permit = publication_permit,
            .proposal = proposal,
            .proposal_sha256 = proposal_sha256,
            .ack = ack,
            .sink = sink,
        };
        _ = self.scheduler.commitArmedService(armed.ticket, .{
            .context = &finalizer_context,
            .finalize = FinalizerContext.finalize,
        }) catch |err| {
            try self.rollbackAttempt(
                armed.ticket,
                publication_permit,
                sink,
                proposal,
                ack,
            );
            return err;
        };
        return finalizer_context.receipt orelse
            @panic("Lane publication finalizer returned without a receipt");
    }

    fn validateAttempt(
        self: *const Session,
        intent: lane.ServiceIntentV1,
        transition: TokenTransitionV1,
    ) Error!void {
        if (self.terminal) return Error.InvalidState;
        if (self.next_sequence == std.math.maxInt(u64))
            return Error.SequenceExhausted;
        if (!lane.serviceIntentValidV1(intent) or
            !std.meta.eql(intent.handle, self.admission.handle) or
            !std.meta.eql(intent.spec, self.admission.event.spec) or
            !std.meta.eql(
                intent.resource_receipt,
                self.admission.event.resource_receipt,
            )) return Error.InvalidBinding;
        const completed = std.math.sub(
            u64,
            intent.spec.work_quanta,
            intent.remaining_before,
        ) catch return Error.InvalidTransition;
        if (completed != self.next_sequence or
            !tokenTransitionValidV1(transition) or
            !std.meta.eql(transition.before, self.state) or
            transition.before.execution_abi != self.execution_abi or
            transition.before.output_length != self.next_sequence)
            return Error.InvalidTransition;
    }

    fn abortArmedOnly(
        self: *Session,
        ticket: lane.ServiceCommitTicketV1,
    ) Error!void {
        self.scheduler.abortArmedService(ticket) catch
            return Error.RecoveryRequired;
    }

    fn rollbackAttempt(
        self: *Session,
        ticket: lane.ServiceCommitTicketV1,
        permit: resource_bank.PublicationPermit,
        maybe_sink: ?SinkV1,
        proposal: ProposalV1,
        ack: PrepareAckV1,
    ) Error!void {
        if (maybe_sink) |sink|
            sink.abort(sink.context, &proposal, &ack);
        self.bank.abortPublication(permit) catch
            return Error.RecoveryRequired;
        self.scheduler.abortArmedService(ticket) catch
            return Error.RecoveryRequired;
    }
};

const FinalizerContext = struct {
    session: *Session,
    publication_permit: resource_bank.PublicationPermit,
    proposal: ProposalV1,
    proposal_sha256: Digest,
    ack: PrepareAckV1,
    sink: SinkV1,
    receipt: ?CommitReceiptV1 = null,

    fn finalize(context: *anyopaque, event: *const lane.EventV1) void {
        const self: *FinalizerContext = @ptrCast(@alignCast(context));
        if (!lane.eventMatchesServiceIntentV1(
            event.*,
            self.proposal.service_intent,
        )) @panic("Lane service event does not match armed intent");
        const event_sha256 = lane.eventSha256(event.*);
        const transcript_sha256 = commitSha256(
            self.proposal.previous_transcript_sha256,
            self.proposal_sha256,
            self.ack,
            event_sha256,
        );
        const receipt: CommitReceiptV1 = .{
            .proposal = self.proposal,
            .proposal_sha256 = self.proposal_sha256,
            .prepare_ack = self.ack,
            .service_event = event.*,
            .service_event_sha256 = event_sha256,
            .transcript_sha256 = transcript_sha256,
        };
        if (!commitReceiptValidV1(receipt))
            @panic("invalid internally generated Lane publication receipt");

        self.session.bank.commitPublicationAssumeValid(
            self.publication_permit,
        );
        self.session.next_sequence = self.publication_permit.sequence + 1;
        self.session.last_resource_permit_generation =
            self.publication_permit.generation;
        self.session.terminal = self.proposal.transition.terminal;
        self.session.state = self.proposal.transition.after;
        self.session.transcript_sha256 = transcript_sha256;
        self.receipt = receipt;
        self.sink.commit(self.sink.context, &self.receipt.?);
    }
};

/// Stateful standalone transcript verifier. It has no Scheduler, Bank, sink or
/// execution-state pointers and therefore can run in a separate verifier tool.
pub const TranscriptVerifierV1 = struct {
    receipt: resource_bank.Receipt,
    request_epoch: u64,
    execution_abi: u64,
    next_sequence: u64 = 0,
    last_resource_permit_generation: u64 = 0,
    terminal: bool = false,
    state: StateCommitmentV1,
    transcript_sha256: Digest,

    pub fn init(
        receipt: resource_bank.Receipt,
        request_epoch: u64,
        execution_abi: u64,
        initial_state: StateCommitmentV1,
    ) Error!TranscriptVerifierV1 {
        if (request_epoch == 0 or execution_abi == 0 or
            receipt.claim.queue_slots != width or
            initial_state.execution_abi != execution_abi or
            initial_state.output_length != 0 or
            initial_state.sampling_calls != 0 or
            !resource_bank.receiptIntegrityValidV1(receipt) or
            !stateCommitmentValidV1(initial_state))
            return Error.InvalidConfiguration;
        return .{
            .receipt = receipt,
            .request_epoch = request_epoch,
            .execution_abi = execution_abi,
            .state = initial_state,
            .transcript_sha256 = initialTranscriptSha256(
                execution_abi,
                request_epoch,
                receipt,
                initial_state,
            ),
        };
    }

    pub fn apply(
        self: *TranscriptVerifierV1,
        receipt: CommitReceiptV1,
    ) Error!void {
        if (!commitReceiptValidV1(receipt))
            return Error.InvalidCommitReceipt;
        const proposal = receipt.proposal;
        if (proposal.request_epoch != self.request_epoch or
            proposal.execution_abi != self.execution_abi or
            !std.meta.eql(proposal.receipt, self.receipt))
            return Error.InvalidBinding;
        if (proposal.transaction_sequence != self.next_sequence)
            return Error.TranscriptSequenceMismatch;
        if (!std.mem.eql(
            u8,
            &proposal.previous_transcript_sha256,
            &self.transcript_sha256,
        )) return Error.TranscriptChainMismatch;
        if (self.terminal) return Error.InvalidState;
        if (!std.meta.eql(proposal.transition.before, self.state))
            return Error.InvalidBinding;
        if (proposal.resource_permit_generation <=
            self.last_resource_permit_generation)
            return Error.InvalidCommitReceipt;

        self.next_sequence += 1;
        self.last_resource_permit_generation =
            proposal.resource_permit_generation;
        self.terminal = proposal.transition.terminal;
        self.state = proposal.transition.after;
        self.transcript_sha256 = receipt.transcript_sha256;
    }

    pub fn snapshot(self: TranscriptVerifierV1) TranscriptSnapshotV1 {
        return .{
            .request_epoch = self.request_epoch,
            .execution_abi = self.execution_abi,
            .next_sequence = self.next_sequence,
            .last_resource_permit_generation = self.last_resource_permit_generation,
            .terminal = self.terminal,
            .state = self.state,
            .transcript_sha256 = self.transcript_sha256,
        };
    }

    /// Compare replay against an externally trusted final checkpoint. A
    /// transcript cannot prove its own completeness; callers must supply this
    /// expected sequence/state/root from the enclosing session or artifact.
    pub fn requireFinal(
        self: TranscriptVerifierV1,
        expected_next_sequence: u64,
        expected_terminal: bool,
        expected_state: StateCommitmentV1,
        expected_transcript_sha256: Digest,
    ) Error!void {
        if (self.next_sequence != expected_next_sequence)
            return Error.TranscriptSequenceMismatch;
        if (self.terminal != expected_terminal or
            !std.meta.eql(self.state, expected_state))
            return Error.InvalidBinding;
        if (!std.mem.eql(
            u8,
            &self.transcript_sha256,
            &expected_transcript_sha256,
        )) return Error.TranscriptChainMismatch;
    }
};

pub fn makeStateCommitmentV1(
    execution_abi: u64,
    kv_position: u64,
    kv_state_sha256: Digest,
    rng_state_abi: u64,
    rng_state_sha256: Digest,
    sampling_calls: u64,
    output_length: u64,
    output_state_sha256: Digest,
) StateCommitmentV1 {
    var state: StateCommitmentV1 = .{
        .execution_abi = execution_abi,
        .kv_position = kv_position,
        .kv_state_sha256 = kv_state_sha256,
        .rng_state_abi = rng_state_abi,
        .rng_state_sha256 = rng_state_sha256,
        .sampling_calls = sampling_calls,
        .output_length = output_length,
        .output_state_sha256 = output_state_sha256,
    };
    state.commitment_sha256 = stateCommitmentSha256(state);
    return state;
}

pub fn makeTokenTransitionV1(
    before: StateCommitmentV1,
    kv_row_sha256: Digest,
    rng_after_sha256: Digest,
    token_id: u32,
    terminal: bool,
) Error!TokenTransitionV1 {
    const calls_after = std.math.add(u64, before.sampling_calls, 1) catch
        return Error.SequenceExhausted;
    return makeTokenTransitionWithSamplingV1(
        before,
        kv_row_sha256,
        rng_after_sha256,
        calls_after,
        token_id,
        terminal,
    );
}

/// Build a transition for concrete executors whose selected token may be
/// forced without consuming RNG/sampler state. `sampling_calls_after` must be
/// exactly the current count or the current count plus one.
pub fn makeTokenTransitionWithSamplingV1(
    before: StateCommitmentV1,
    kv_row_sha256: Digest,
    rng_after_sha256: Digest,
    sampling_calls_after: u64,
    token_id: u32,
    terminal: bool,
) Error!TokenTransitionV1 {
    if (!stateCommitmentValidV1(before) or isZero(rng_after_sha256))
        return Error.InvalidTransition;
    const calls_upper = std.math.add(u64, before.sampling_calls, 1) catch
        return Error.SequenceExhausted;
    if (sampling_calls_after < before.sampling_calls or
        sampling_calls_after > calls_upper or
        (sampling_calls_after == before.sampling_calls and
            !std.mem.eql(
                u8,
                &rng_after_sha256,
                &before.rng_state_sha256,
            ))) return Error.InvalidTransition;
    const has_kv_transition = !isZero(kv_row_sha256);
    const kv_after = if (has_kv_transition)
        std.math.add(u64, before.kv_position, 1) catch
            return Error.SequenceExhausted
    else
        before.kv_position;
    const output_after = std.math.add(u64, before.output_length, 1) catch
        return Error.SequenceExhausted;
    const after = makeStateCommitmentV1(
        before.execution_abi,
        kv_after,
        if (has_kv_transition)
            nextKvStateSha256(
                before.kv_state_sha256,
                before.kv_position,
                kv_row_sha256,
            )
        else
            before.kv_state_sha256,
        before.rng_state_abi,
        rng_after_sha256,
        sampling_calls_after,
        output_after,
        nextOutputStateSha256(
            before.output_state_sha256,
            before.output_length,
            token_id,
            terminal,
        ),
    );
    var transition: TokenTransitionV1 = .{
        .before = before,
        .after = after,
        .kv_row_sha256 = kv_row_sha256,
        .token_id = token_id,
        .terminal = terminal,
    };
    transition.transition_sha256 = tokenTransitionSha256(transition);
    return transition;
}

pub fn stateCommitmentSha256(state: StateCommitmentV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(state_domain);
    hashU64(&hash, state.abi_version);
    hashU64(&hash, state.execution_abi);
    hashU64(&hash, state.kv_position);
    hash.update(&state.kv_state_sha256);
    hashU64(&hash, state.rng_state_abi);
    hash.update(&state.rng_state_sha256);
    hashU64(&hash, state.sampling_calls);
    hashU64(&hash, state.output_length);
    hash.update(&state.output_state_sha256);
    return finish(&hash);
}

pub fn stateCommitmentValidV1(state: StateCommitmentV1) bool {
    return state.abi_version == state_commitment_abi and
        state.execution_abi != 0 and state.rng_state_abi != 0 and
        !isZero(state.kv_state_sha256) and
        !isZero(state.rng_state_sha256) and
        !isZero(state.output_state_sha256) and
        std.mem.eql(
            u8,
            &state.commitment_sha256,
            &stateCommitmentSha256(state),
        );
}

pub fn nextKvStateSha256(
    before_sha256: Digest,
    position_before: u64,
    row_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(kv_domain);
    hashU64(&hash, state_commitment_abi);
    hash.update(&before_sha256);
    hashU64(&hash, position_before);
    hash.update(&row_sha256);
    return finish(&hash);
}

pub fn nextOutputStateSha256(
    before_sha256: Digest,
    output_length_before: u64,
    token_id: u32,
    terminal: bool,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(output_domain);
    hashU64(&hash, state_commitment_abi);
    hash.update(&before_sha256);
    hashU64(&hash, output_length_before);
    hashU32(&hash, token_id);
    hashBool(&hash, terminal);
    return finish(&hash);
}

pub fn tokenTransitionSha256(transition: TokenTransitionV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(transition_domain);
    hashU64(&hash, transition.abi_version);
    hashState(&hash, transition.before);
    hashState(&hash, transition.after);
    hash.update(&transition.kv_row_sha256);
    hashU32(&hash, transition.token_id);
    hashBool(&hash, transition.terminal);
    return finish(&hash);
}

pub fn tokenTransitionValidV1(transition: TokenTransitionV1) bool {
    if (transition.abi_version != token_transition_abi or
        !stateCommitmentValidV1(transition.before) or
        !stateCommitmentValidV1(transition.after) or
        transition.before.execution_abi != transition.after.execution_abi or
        transition.before.rng_state_abi != transition.after.rng_state_abi)
        return false;
    const has_kv_transition = !isZero(transition.kv_row_sha256);
    const kv_after = if (has_kv_transition)
        std.math.add(
            u64,
            transition.before.kv_position,
            1,
        ) catch return false
    else
        transition.before.kv_position;
    const calls_upper = std.math.add(
        u64,
        transition.before.sampling_calls,
        1,
    ) catch return false;
    const output_after = std.math.add(
        u64,
        transition.before.output_length,
        1,
    ) catch return false;
    return transition.after.kv_position == kv_after and
        transition.after.sampling_calls >= transition.before.sampling_calls and
        transition.after.sampling_calls <= calls_upper and
        (transition.after.sampling_calls !=
            transition.before.sampling_calls or
            std.mem.eql(
                u8,
                &transition.after.rng_state_sha256,
                &transition.before.rng_state_sha256,
            )) and
        transition.after.output_length == output_after and
        (if (has_kv_transition)
            std.mem.eql(
                u8,
                &transition.after.kv_state_sha256,
                &nextKvStateSha256(
                    transition.before.kv_state_sha256,
                    transition.before.kv_position,
                    transition.kv_row_sha256,
                ),
            )
        else
            std.mem.eql(
                u8,
                &transition.after.kv_state_sha256,
                &transition.before.kv_state_sha256,
            )) and std.mem.eql(
        u8,
        &transition.after.output_state_sha256,
        &nextOutputStateSha256(
            transition.before.output_state_sha256,
            transition.before.output_length,
            transition.token_id,
            transition.terminal,
        ),
    ) and std.mem.eql(
        u8,
        &transition.transition_sha256,
        &tokenTransitionSha256(transition),
    );
}

pub fn initialTranscriptSha256(
    execution_abi: u64,
    request_epoch: u64,
    receipt: resource_bank.Receipt,
    initial_state: StateCommitmentV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(root_domain);
    hashU64(&hash, abi);
    hashU64(&hash, state_commitment_abi);
    hashU64(&hash, token_transition_abi);
    hashU64(&hash, sink_abi);
    hashU64(&hash, prepare_ack_abi);
    hashU64(&hash, commit_receipt_abi);
    hashU64(&hash, resource_bank.abi);
    hashU64(&hash, resource_bank.publication_fence_abi);
    hashU64(&hash, lane.abi);
    hashU64(&hash, lane.event_abi);
    hashU64(&hash, lane.service_intent_abi);
    hashU64(&hash, execution_abi);
    hashU64(&hash, request_epoch);
    hashReceipt(&hash, receipt);
    hash.update(&initial_state.commitment_sha256);
    return finish(&hash);
}

pub fn proposalSha256(proposal: ProposalV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(proposal_domain);
    hashU64(&hash, proposal.abi_version);
    hashU64(&hash, proposal.resource_bank_abi_version);
    hashU64(&hash, proposal.resource_publication_fence_abi);
    hashU64(&hash, proposal.lane_weave_abi_version);
    hashU64(&hash, proposal.lane_event_abi_version);
    hashU64(&hash, proposal.service_intent_abi_version);
    hashU64(&hash, proposal.sink_abi_version);
    hashU64(&hash, proposal.prepare_ack_abi_version);
    hashU64(&hash, proposal.commit_receipt_abi_version);
    hashU64(&hash, proposal.execution_abi);
    hashU64(&hash, proposal.request_epoch);
    hashU64(&hash, proposal.transaction_sequence);
    hashU64(&hash, proposal.resource_permit_generation);
    hashU8(&hash, proposal.lane_width);
    hashU8(&hash, proposal.live_lane_mask);
    hashU8(&hash, proposal.live_lane_count);
    hashReceipt(&hash, proposal.receipt);
    hash.update(&proposal.receipt_sha256);
    hash.update(&proposal.previous_transcript_sha256);
    hashServiceIntent(&hash, proposal.service_intent);
    hash.update(&proposal.service_intent_sha256);
    hashTransition(&hash, proposal.transition);
    hash.update(&proposal.transition_sha256);
    return finish(&hash);
}

pub fn proposalValidV1(proposal: ProposalV1) bool {
    if (proposal.abi_version != abi or
        proposal.resource_bank_abi_version != resource_bank.abi or
        proposal.resource_publication_fence_abi !=
            resource_bank.publication_fence_abi or
        proposal.lane_weave_abi_version != lane.abi or
        proposal.lane_event_abi_version != lane.event_abi or
        proposal.service_intent_abi_version != lane.service_intent_abi or
        proposal.sink_abi_version != sink_abi or
        proposal.prepare_ack_abi_version != prepare_ack_abi or
        proposal.commit_receipt_abi_version != commit_receipt_abi or
        proposal.execution_abi == 0 or proposal.request_epoch == 0 or
        proposal.transaction_sequence == std.math.maxInt(u64) or
        proposal.resource_permit_generation == 0 or
        proposal.lane_width != width or
        proposal.live_lane_mask != live_mask or
        proposal.live_lane_count != 1 or
        proposal.receipt.claim.queue_slots != width or
        !resource_bank.receiptIntegrityValidV1(proposal.receipt) or
        isZero(proposal.previous_transcript_sha256) or
        !std.mem.eql(
            u8,
            &proposal.receipt_sha256,
            &lane.resourceReceiptSha256(proposal.receipt),
        ) or !lane.serviceIntentValidV1(proposal.service_intent) or
        !std.meta.eql(
            proposal.service_intent.resource_receipt,
            proposal.receipt,
        ) or !std.mem.eql(
        u8,
        &proposal.service_intent_sha256,
        &proposal.service_intent.intent_sha256,
    ) or !std.mem.eql(
        u8,
        &proposal.service_intent_sha256,
        &lane.serviceIntentSha256(proposal.service_intent),
    ) or !tokenTransitionValidV1(proposal.transition) or
        proposal.transition.before.execution_abi != proposal.execution_abi or
        proposal.transition.before.output_length !=
            proposal.transaction_sequence or
        !std.mem.eql(
            u8,
            &proposal.transition_sha256,
            &proposal.transition.transition_sha256,
        )) return false;
    const completed = std.math.sub(
        u64,
        proposal.service_intent.spec.work_quanta,
        proposal.service_intent.remaining_before,
    ) catch return false;
    return completed == proposal.transaction_sequence;
}

pub fn prepareAckValidV1(
    ack: PrepareAckV1,
    proposal_sha256: Digest,
) bool {
    return ack.abi_version == prepare_ack_abi and ack.sink_epoch != 0 and
        ack.reservation_id != 0 and std.mem.eql(
        u8,
        &ack.proposal_sha256,
        &proposal_sha256,
    );
}

pub fn commitSha256(
    previous_transcript_sha256: Digest,
    proposal_sha256: Digest,
    ack: PrepareAckV1,
    service_event_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(commit_domain);
    hashU64(&hash, commit_receipt_abi);
    hash.update(&previous_transcript_sha256);
    hash.update(&proposal_sha256);
    hashU64(&hash, ack.abi_version);
    hash.update(&ack.proposal_sha256);
    hashU64(&hash, ack.sink_epoch);
    hashU64(&hash, ack.reservation_id);
    hash.update(&service_event_sha256);
    return finish(&hash);
}

pub fn commitReceiptValidV1(receipt: CommitReceiptV1) bool {
    return receipt.abi_version == commit_receipt_abi and
        proposalValidV1(receipt.proposal) and
        std.mem.eql(
            u8,
            &receipt.proposal_sha256,
            &proposalSha256(receipt.proposal),
        ) and prepareAckValidV1(
        receipt.prepare_ack,
        receipt.proposal_sha256,
    ) and std.mem.eql(
        u8,
        &receipt.service_event_sha256,
        &receipt.service_event.event_sha256,
    ) and std.mem.eql(
        u8,
        &receipt.service_event_sha256,
        &lane.eventSha256(receipt.service_event),
    ) and lane.eventMatchesServiceIntentV1(
        receipt.service_event,
        receipt.proposal.service_intent,
    ) and std.mem.eql(
        u8,
        &receipt.transcript_sha256,
        &commitSha256(
            receipt.proposal.previous_transcript_sha256,
            receipt.proposal_sha256,
            receipt.prepare_ack,
            receipt.service_event_sha256,
        ),
    );
}

fn mapBankError(err: resource_bank.Error) Error {
    return switch (err) {
        error.StaleReservation => Error.ResourceReceiptInvalid,
        error.InvalidConfiguration => Error.SequenceExhausted,
        else => Error.InvalidState,
    };
}

fn hashState(
    hash: *std.crypto.hash.sha2.Sha256,
    state: StateCommitmentV1,
) void {
    hashU64(hash, state.abi_version);
    hashU64(hash, state.execution_abi);
    hashU64(hash, state.kv_position);
    hash.update(&state.kv_state_sha256);
    hashU64(hash, state.rng_state_abi);
    hash.update(&state.rng_state_sha256);
    hashU64(hash, state.sampling_calls);
    hashU64(hash, state.output_length);
    hash.update(&state.output_state_sha256);
    hash.update(&state.commitment_sha256);
}

fn hashTransition(
    hash: *std.crypto.hash.sha2.Sha256,
    transition: TokenTransitionV1,
) void {
    hashU64(hash, transition.abi_version);
    hashState(hash, transition.before);
    hashState(hash, transition.after);
    hash.update(&transition.kv_row_sha256);
    hashU32(hash, transition.token_id);
    hashBool(hash, transition.terminal);
    hash.update(&transition.transition_sha256);
}

fn hashServiceIntent(
    hash: *std.crypto.hash.sha2.Sha256,
    intent: lane.ServiceIntentV1,
) void {
    hashU64(hash, intent.abi_version);
    hashU64(hash, intent.lane_weave_abi);
    hashU64(hash, intent.event_abi_version);
    hashU64(hash, intent.source_permit_abi);
    hashU64(hash, intent.resource_bank_abi_version);
    hashU64(hash, intent.scheduler_epoch);
    hashU64(hash, intent.event_sequence);
    hashHandle(hash, intent.handle);
    hashSpec(hash, intent.spec);
    hashU64(hash, intent.logical_tick_before);
    hashU32(hash, intent.cursor_before);
    hashU16(hash, intent.level_before);
    hashU32(hash, intent.cursor_after);
    hashU16(hash, intent.level_after);
    hashU64(hash, intent.remaining_before);
    hashU64(hash, intent.wait_quanta);
    hashU64(hash, intent.maximum_service_gap);
    hash.update(&intent.state_before_sha256);
    hash.update(&intent.chain_head_before_sha256);
    hashReceipt(hash, intent.resource_receipt);
    hash.update(&intent.resource_receipt_sha256);
    hash.update(&intent.intent_sha256);
}

fn hashHandle(hash: *std.crypto.hash.sha2.Sha256, handle: lane.Handle) void {
    hashU64(hash, handle.scheduler_epoch);
    hashU32(hash, handle.slot_index);
    hashU64(hash, handle.slot_generation);
    hashU64(hash, handle.tenant_key);
    hashU64(hash, handle.request_key);
    hashU64(hash, handle.request_generation);
}

fn hashSpec(hash: *std.crypto.hash.sha2.Sha256, spec: lane.RequestSpec) void {
    hashU64(hash, spec.tenant_key);
    hashU64(hash, spec.request_key);
    hashU64(hash, spec.request_generation);
    hashU64(hash, spec.resource_owner_key);
    hashU16(hash, spec.weight);
    hashU64(hash, spec.work_quanta);
    hashU64(hash, spec.deadline_tick);
    hashClaim(hash, spec.claim);
}

fn hashReceipt(
    hash: *std.crypto.hash.sha2.Sha256,
    receipt: resource_bank.Receipt,
) void {
    hashU64(hash, receipt.bank_epoch);
    hashU32(hash, receipt.slot_index);
    hashU64(hash, receipt.generation);
    hashU64(hash, receipt.owner_key);
    hashClaim(hash, receipt.claim);
    hashU64(hash, receipt.integrity);
}

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashBool(hash: *std.crypto.hash.sha2.Sha256, value: bool) void {
    hashU8(hash, @intFromBool(value));
}

fn hashU8(hash: *std.crypto.hash.sha2.Sha256, value: u8) void {
    hash.update(&.{value});
}

fn hashU16(hash: *std.crypto.hash.sha2.Sha256, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    hash.update(&bytes);
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

fn zeroReceipt() resource_bank.Receipt {
    return .{
        .bank_epoch = 0,
        .slot_index = 0,
        .generation = 0,
        .owner_key = 0,
        .claim = .{},
        .integrity = 0,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_execution_abi: u64 = 0x5445_5354_4558_0001;
const test_rng_abi: u64 = 0x5445_5354_524e_0001;

const TestFixture = struct {
    bank_slots: [1]resource_bank.Slot = undefined,
    lane_slots: [1]lane.Slot = undefined,
    projection: [1]lane.ProjectionSlot = undefined,
    bank: resource_bank.Bank = undefined,
    scheduler: lane.Scheduler = undefined,
    admission: lane.Admission = undefined,

    fn init(self: *TestFixture, work_quanta: u64) !void {
        self.bank = try resource_bank.Bank.init(
            &self.bank_slots,
            .{
                .host_bytes = 1 << 20,
                .kv_bytes = 1 << 20,
                .output_journal_bytes = 1 << 20,
                .queue_slots = 1,
            },
            0x4241_4e4b,
        );
        self.scheduler = try lane.Scheduler.init(
            &self.bank,
            .{ .slots = &self.lane_slots, .projection = &self.projection },
            .{
                .scheduler_epoch = 0x5343_4845,
                .challenge = filledDigest(0xa1),
                .max_weight = 8,
            },
        );
        const decision = try self.scheduler.admit(.{
            .tenant_key = 11,
            .request_key = 22,
            .request_generation = 1,
            .resource_owner_key = 33,
            .weight = 1,
            .work_quanta = work_quanta,
            .claim = .{
                .kv_bytes = 4096,
                .output_journal_bytes = 1024,
                .queue_slots = 1,
            },
        });
        self.admission = switch (decision) {
            .admitted => |value| value,
            .rejected => return Error.InvalidState,
        };
    }
};

const TestSink = struct {
    reject: bool = false,
    corrupt_ack: bool = false,
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,
    proposals: [8]ProposalV1 = undefined,
    receipts: [8]CommitReceiptV1 = undefined,
    visible_state: ?StateCommitmentV1 = null,

    fn interface(self: *TestSink) SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const ProposalV1,
        ack: *PrepareAckV1,
    ) SinkPrepareError!void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.proposals[self.prepare_calls] = proposal.*;
        self.prepare_calls += 1;
        if (self.reject) return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = proposalSha256(proposal.*),
            .sink_epoch = 0x5349_4e4b,
            .reservation_id = self.prepare_calls,
        };
        if (self.corrupt_ack) ack.proposal_sha256[0] ^= 1;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const CommitReceiptV1,
    ) void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.receipts[self.commit_calls] = receipt.*;
        self.visible_state = receipt.proposal.transition.after;
        self.commit_calls += 1;
    }

    fn abort(
        context: *anyopaque,
        _: *const ProposalV1,
        _: *const PrepareAckV1,
    ) void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.abort_calls += 1;
    }
};

fn initialTestState() StateCommitmentV1 {
    return makeStateCommitmentV1(
        test_execution_abi,
        16,
        filledDigest(0x11),
        test_rng_abi,
        filledDigest(0x22),
        0,
        0,
        filledDigest(0x33),
    );
}

fn nextTestTransition(
    before: StateCommitmentV1,
    token_id: u32,
    terminal: bool,
) !TokenTransitionV1 {
    return makeTokenTransitionV1(
        before,
        filledDigest(@truncate(token_id +% 0x41)),
        filledDigest(@truncate(token_id +% 0x71)),
        token_id,
        terminal,
    );
}

fn filledDigest(byte: u8) Digest {
    return [_]u8{byte} ** 32;
}

fn containsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |info| containsPointer(info.child),
        .optional => |info| containsPointer(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field|
                if (containsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

test "Lane publication pointer-free evidence and Session stay bounded" {
    try testing.expect(@sizeOf(Session) <= 1280);
    try testing.expect(@sizeOf(ProposalV1) <= 1536);
    try testing.expect(@sizeOf(CommitReceiptV1) <= 2560);
    try testing.expect(!containsPointer(ProposalV1));
    try testing.expect(!containsPointer(CommitReceiptV1));
}

test "Lane publication models first-token KV and forced-token RNG honestly" {
    const initial = initialTestState();
    const forced = try makeTokenTransitionWithSamplingV1(
        initial,
        zero_digest,
        initial.rng_state_sha256,
        initial.sampling_calls,
        91,
        false,
    );
    try testing.expect(tokenTransitionValidV1(forced));
    try testing.expectEqual(initial.kv_position, forced.after.kv_position);
    try testing.expectEqual(
        initial.sampling_calls,
        forced.after.sampling_calls,
    );
    try testing.expect(std.mem.eql(
        u8,
        &initial.kv_state_sha256,
        &forced.after.kv_state_sha256,
    ));
    try testing.expect(std.mem.eql(
        u8,
        &initial.rng_state_sha256,
        &forced.after.rng_state_sha256,
    ));

    try testing.expectError(
        Error.InvalidTransition,
        makeTokenTransitionWithSamplingV1(
            initial,
            zero_digest,
            filledDigest(0xe1),
            initial.sampling_calls,
            91,
            false,
        ),
    );
    var forged = forced;
    forged.after.sampling_calls += 2;
    forged.after.commitment_sha256 = stateCommitmentSha256(forged.after);
    forged.transition_sha256 = tokenTransitionSha256(forged);
    try testing.expect(!tokenTransitionValidV1(forged));
}

test "Lane publication commits exact width-one AI state and verifies offline" {
    var fixture: TestFixture = .{};
    try fixture.init(2);
    const initial_state = initialTestState();
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x5251_4550,
        test_execution_abi,
        initial_state,
    );
    var verifier = try TranscriptVerifierV1.init(
        fixture.admission.event.resource_receipt,
        0x5251_4550,
        test_execution_abi,
        initial_state,
    );
    var sink: TestSink = .{};

    const first_transition = try nextTestTransition(initial_state, 101, false);
    const first = try session.publish(
        try fixture.scheduler.prepareService(),
        first_transition,
        sink.interface(),
    );
    try testing.expect(commitReceiptValidV1(first));
    try verifier.apply(first);
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    try testing.expectEqualDeep(first_transition.after, sink.visible_state.?);

    const second_transition = try nextTestTransition(
        first_transition.after,
        102,
        true,
    );
    const second = try session.publish(
        try fixture.scheduler.prepareService(),
        second_transition,
        sink.interface(),
    );
    try verifier.apply(second);
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    try testing.expectEqualDeep(
        verifier.snapshot(),
        try session.snapshot(),
    );
    try testing.expectEqualDeep(second, sink.receipts[1]);
    try verifier.requireFinal(
        2,
        true,
        second_transition.after,
        second.transcript_sha256,
    );
    var truncated = try TranscriptVerifierV1.init(
        fixture.admission.event.resource_receipt,
        0x5251_4550,
        test_execution_abi,
        initial_state,
    );
    try truncated.apply(first);
    try testing.expectError(
        Error.TranscriptSequenceMismatch,
        truncated.requireFinal(
            2,
            true,
            second_transition.after,
            second.transcript_sha256,
        ),
    );

    try session.close();
    _ = try fixture.scheduler.retire(fixture.admission.handle);
    const bank_snapshot = try fixture.bank.snapshot();
    try testing.expect(bank_snapshot.used.isZero());
    try testing.expectEqual(@as(usize, 0), bank_snapshot.committed_receipts);
    _ = try fixture.scheduler.close();
}

test "Lane publication rejection is private and retry keeps logical intent" {
    var fixture: TestFixture = .{};
    try fixture.init(1);
    const initial_state = initialTestState();
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x5251_4551,
        test_execution_abi,
        initial_state,
    );
    var sink: TestSink = .{ .reject = true };
    const transition = try nextTestTransition(initial_state, 201, true);
    const before = try fixture.scheduler.snapshot();
    try testing.expectError(
        Error.SinkRejected,
        session.publish(
            try fixture.scheduler.prepareService(),
            transition,
            sink.interface(),
        ),
    );
    try testing.expectEqualDeep(before, try fixture.scheduler.snapshot());
    try testing.expectEqualDeep(initial_state, (try session.snapshot()).state);
    try testing.expectEqual(@as(usize, 0), sink.commit_calls);
    try testing.expectEqual(@as(usize, 0), sink.abort_calls);

    sink.reject = false;
    const committed = try session.publish(
        try fixture.scheduler.prepareService(),
        transition,
        sink.interface(),
    );
    try testing.expectEqualDeep(
        sink.proposals[0].service_intent,
        sink.proposals[1].service_intent,
    );
    try testing.expect(
        sink.proposals[1].resource_permit_generation >
            sink.proposals[0].resource_permit_generation,
    );
    try testing.expect(!std.mem.eql(
        u8,
        &proposalSha256(sink.proposals[0]),
        &proposalSha256(sink.proposals[1]),
    ));
    try testing.expect(commitReceiptValidV1(committed));

    try session.close();
    _ = try fixture.scheduler.retire(fixture.admission.handle);
    _ = try fixture.scheduler.close();
}

test "Lane publication terminal token closes the Session output chain" {
    var fixture: TestFixture = .{};
    try fixture.init(2);
    const initial_state = initialTestState();
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x5251_4556,
        test_execution_abi,
        initial_state,
    );
    var sink: TestSink = .{};
    const terminal_transition = try nextTestTransition(
        initial_state,
        205,
        true,
    );
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        terminal_transition,
        sink.interface(),
    );
    const after_terminal = try nextTestTransition(
        terminal_transition.after,
        206,
        false,
    );
    try testing.expectError(
        Error.InvalidState,
        session.publish(
            try fixture.scheduler.prepareService(),
            after_terminal,
            sink.interface(),
        ),
    );
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    try testing.expectEqual(@as(u64, 1), (try session.snapshot()).next_sequence);

    try session.close();
    _ = try fixture.scheduler.cancel(fixture.admission.handle);
    _ = try fixture.scheduler.close();
}

test "Lane publication corrupt acknowledgment aborts reservation and retries" {
    var fixture: TestFixture = .{};
    try fixture.init(1);
    const initial_state = initialTestState();
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x5251_4552,
        test_execution_abi,
        initial_state,
    );
    var sink: TestSink = .{ .corrupt_ack = true };
    const transition = try nextTestTransition(initial_state, 211, true);
    const before = try fixture.scheduler.snapshot();
    try testing.expectError(
        Error.InvalidPrepareAck,
        session.publish(
            try fixture.scheduler.prepareService(),
            transition,
            sink.interface(),
        ),
    );
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    try testing.expectEqualDeep(before, try fixture.scheduler.snapshot());
    try testing.expectEqual(@as(u64, 0), (try session.snapshot()).next_sequence);

    sink.corrupt_ack = false;
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        transition,
        sink.interface(),
    );
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    try session.close();
    _ = try fixture.scheduler.retire(fixture.admission.handle);
    _ = try fixture.scheduler.close();
}

test "Lane publication verifier rejects nested mutation and replay" {
    var fixture: TestFixture = .{};
    try fixture.init(1);
    const initial_state = initialTestState();
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x5251_4553,
        test_execution_abi,
        initial_state,
    );
    var sink: TestSink = .{};
    const committed = try session.publish(
        try fixture.scheduler.prepareService(),
        try nextTestTransition(initial_state, 221, true),
        sink.interface(),
    );

    var mutations: [9]CommitReceiptV1 = [_]CommitReceiptV1{committed} ** 9;
    mutations[0].abi_version +%= 1;
    mutations[1].proposal.execution_abi +%= 1;
    mutations[2].proposal.service_intent.handle.request_key +%= 1;
    mutations[3].proposal.transition.before.kv_position +%= 1;
    mutations[4].proposal.transition.after.rng_state_sha256[0] ^= 1;
    mutations[5].proposal.transition.token_id +%= 1;
    mutations[6].prepare_ack.reservation_id +%= 1;
    mutations[7].service_event.logical_tick_after +%= 1;
    mutations[8].transcript_sha256[0] ^= 1;
    for (mutations) |mutation|
        try testing.expect(!commitReceiptValidV1(mutation));

    var verifier = try TranscriptVerifierV1.init(
        fixture.admission.event.resource_receipt,
        0x5251_4553,
        test_execution_abi,
        initial_state,
    );
    try verifier.apply(committed);
    try testing.expectError(
        Error.TranscriptSequenceMismatch,
        verifier.apply(committed),
    );

    var substituted = committed;
    substituted.proposal.previous_transcript_sha256[0] ^= 1;
    substituted.proposal_sha256 = proposalSha256(substituted.proposal);
    substituted.prepare_ack.proposal_sha256 = substituted.proposal_sha256;
    substituted.transcript_sha256 = commitSha256(
        substituted.proposal.previous_transcript_sha256,
        substituted.proposal_sha256,
        substituted.prepare_ack,
        substituted.service_event_sha256,
    );
    try testing.expect(commitReceiptValidV1(substituted));
    var fresh_verifier = try TranscriptVerifierV1.init(
        fixture.admission.event.resource_receipt,
        0x5251_4553,
        test_execution_abi,
        initial_state,
    );
    try testing.expectError(
        Error.TranscriptChainMismatch,
        fresh_verifier.apply(substituted),
    );

    try session.close();
    _ = try fixture.scheduler.retire(fixture.admission.handle);
    _ = try fixture.scheduler.close();
}

test "Lane publication binding rejects an intervening scheduler event" {
    var fixture: TestFixture = .{};
    try fixture.init(1);
    _ = try fixture.scheduler.admit(.{
        .tenant_key = 44,
        .request_key = 55,
        .request_generation = 1,
        .resource_owner_key = 66,
        .weight = 1,
        .work_quanta = 1,
        .claim = .{ .queue_slots = 1 },
    });

    var session: Session = .{};
    try testing.expectError(
        lane.Error.InvalidTransition,
        session.init(
            &fixture.scheduler,
            &fixture.bank,
            fixture.admission,
            0x5251_4555,
            test_execution_abi,
            initialTestState(),
        ),
    );
    _ = try fixture.scheduler.cancel(fixture.admission.handle);
    _ = try fixture.scheduler.close();
}

test "Lane publication copied Session fails closed at the Bank address fence" {
    var fixture: TestFixture = .{};
    try fixture.init(1);
    const initial_state = initialTestState();
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x5251_4554,
        test_execution_abi,
        initial_state,
    );
    var copied = session;
    var sink: TestSink = .{};
    const transition = try nextTestTransition(initial_state, 231, true);
    try testing.expectError(
        Error.InvalidState,
        copied.publish(
            try fixture.scheduler.prepareService(),
            transition,
            sink.interface(),
        ),
    );
    try testing.expectEqual(@as(u64, 0), (try session.snapshot()).next_sequence);
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        transition,
        sink.interface(),
    );

    try session.close();
    _ = try fixture.scheduler.retire(fixture.admission.handle);
    _ = try fixture.scheduler.close();
}
