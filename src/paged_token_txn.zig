//! Paged-root synchronous token-publication transaction foundation.
//!
//! PagedTokenTxn P2b v1 joins one fixed-B4 live-lane wave to a committed ResourceBank
//! receipt, generation-fenced immutable page-map root transitions, full caller-owned RNG
//! state, sampling counters and private output journals. A sink first reserves
//! capacity without exposing tokens, then receives one infallible commit after
//! every request-local state transition has completed.
//!
//! This is deliberately an in-process foundation. It does not make arbitrary
//! callbacks transactional, persist state across a process crash, reconcile
//! physical resources, or release the request-wide ResourceBank receipt.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const kv = @import("paged_kv_cache.zig");

pub const abi: u64 = 0x4750_5458_0000_0001;
pub const sink_abi: u64 = 0x4750_5453_0000_0001;
pub const prepare_ack_abi: u64 = 0x4750_5441_0000_0001;
pub const commit_receipt_abi: u64 = 0x4750_5443_0000_0001;
pub const page_transition_abi: u64 = 0x4750_5452_0000_0001;
pub const width: usize = 4;
pub const RngState = [4]u64;
pub const Digest = [32]u8;

pub const Error = error{
    InvalidConfiguration,
    InvalidState,
    InvalidLaneSet,
    InvalidBinding,
    InvalidTransition,
    SequenceExhausted,
    ResourceReceiptInvalid,
    KvTransactionInvalid,
    SinkRejected,
    InvalidPrepareAck,
};

pub const SinkPrepareError = error{
    Unavailable,
    InvalidEvidence,
    CapacityExceeded,
};

pub const LaneStage = struct {
    lane_index: u32,
    prompt_len: usize,
    cache: *kv.PagedKVCache,
    kv_mark: ?kv.RowTxnMark = null,
    rng_state: *RngState,
    rng_after: RngState,
    sampling_calls: *usize,
    sampling_calls_after: usize,
    output: []u32,
    output_len: *usize,
    token_id: u32,
    terminal: bool,
};

/// Pointer-free proof of one private-row page-map transition.  The proposal
/// binds both immutable roots and the exact page ownership generation, so a
/// sink can reject stale/replayed PageRefs without observing allocator
/// addresses. The first no-row wave binds equal committed roots plus the
/// canonical prompt digest; only its row generation/PageRef fields are zero.
pub const RootTransitionV1 = struct {
    abi_version: u64 = page_transition_abi,
    kv_row_txn_abi: u64 = kv.row_txn_abi,
    page_map_root_abi: u64 = kv.page_map_root_abi,
    page_ref_abi: u64 = kv.page_ref_abi,
    cache_instance: u64 = 0,
    row_txn_generation: u64 = 0,
    root_before_generation: u64 = 0,
    root_after_generation: u64 = 0,
    root_before_len: u64 = 0,
    root_after_len: u64 = 0,
    root_before_pages: u64 = 0,
    root_after_pages: u64 = 0,
    root_before_ownership_sha256: Digest = [_]u8{0} ** 32,
    root_after_ownership_sha256: Digest = [_]u8{0} ** 32,
    logical_page: u64 = 0,
    page_ownership_generation: u64 = 0,
    installs_new_page: bool = false,
    /// Full-prefix seed is populated only for the first no-row token wave.
    initial_logical_kv_sha256: Digest = [_]u8{0} ** 32,
    /// O(layers * dim) canonical commitment for the private appended row.
    row_payload_sha256: Digest = [_]u8{0} ** 32,
    /// Incremental content chain closes the gap left by ownership-only roots.
    state_chain_before: Digest = [_]u8{0} ** 32,
    state_chain_after: Digest = [_]u8{0} ** 32,
};

pub const LaneProposalV1 = struct {
    lane_index: u32 = 0,
    step_index: u64 = 0,
    prompt_len: u64 = 0,
    kv_before: u64 = 0,
    kv_after: u64 = 0,
    kv_capacity_bytes: u64 = 0,
    has_kv_transition: bool = false,
    kv_transition: RootTransitionV1 = .{},
    output_before: u64 = 0,
    output_after: u64 = 0,
    rng_before: RngState = [_]u64{0} ** 4,
    rng_after: RngState = [_]u64{0} ** 4,
    sampling_calls_before: u64 = 0,
    sampling_calls_after: u64 = 0,
    token_id: u32 = 0,
    terminal: bool = false,
};

pub const ProposalV1 = struct {
    abi_version: u64 = abi,
    resource_bank_abi: u64 = resource_bank.abi,
    resource_publication_fence_abi: u64 =
        resource_bank.publication_fence_abi,
    paged_kv_abi: u64 = kv.abi,
    page_map_root_abi: u64 = kv.page_map_root_abi,
    page_ref_abi: u64 = kv.page_ref_abi,
    page_transition_abi: u64 = page_transition_abi,
    kv_row_txn_abi: u64 = kv.row_txn_abi,
    execution_abi: u64,
    request_epoch: u64,
    transaction_sequence: u64,
    resource_permit_generation: u64,
    live_mask: u8,
    live_lane_count: u8,
    kv_capacity_bytes: u64,
    receipt: resource_bank.Receipt,
    lanes: [width]LaneProposalV1 = [_]LaneProposalV1{.{}} ** width,
};

pub const PrepareAckV1 = struct {
    abi_version: u64 = prepare_ack_abi,
    proposal_sha256: Digest = [_]u8{0} ** 32,
    sink_epoch: u64 = 0,
    reservation_id: u64 = 0,
};

pub const CommitReceiptV1 = struct {
    abi_version: u64 = commit_receipt_abi,
    proposal: ProposalV1,
    proposal_sha256: Digest,
    prepare_ack: PrepareAckV1,
    commit_sha256: Digest,
};

/// A conforming sink exposes no token from `prepare`. A successful prepare
/// reserves everything needed by `commit`, which must not fail, allocate, or
/// perform fallible I/O. `abort` releases a successful reservation that the
/// engine deliberately abandons before local commit. A failing `prepare` must
/// release any partial reservation before returning its error.
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

fn sinkEql(left: SinkV1, right: SinkV1) bool {
    return left.abi_version == right.abi_version and
        left.context == right.context and
        left.prepare == right.prepare and
        left.commit == right.commit and
        left.abort == right.abort;
}

const BindingIdentity = struct {
    cache: *kv.PagedKVCache,
    cache_instance: u64,
    capacity_bytes: usize,
    rng_state: *RngState,
    sampling_calls: *usize,
    output_len: *usize,
    output_ptr: [*]u32,
    output_capacity: usize,

    fn fromStage(stage: LaneStage) BindingIdentity {
        return .{
            .cache = stage.cache,
            .cache_instance = stage.cache.instance_id,
            .capacity_bytes = stage.cache.capacityLedger().allocation_capacity_bytes,
            .rng_state = stage.rng_state,
            .sampling_calls = stage.sampling_calls,
            .output_len = stage.output_len,
            .output_ptr = stage.output.ptr,
            .output_capacity = stage.output.len,
        };
    }

    fn eql(self: BindingIdentity, other: BindingIdentity) bool {
        return self.cache == other.cache and
            self.cache_instance == other.cache_instance and
            self.capacity_bytes == other.capacity_bytes and
            self.rng_state == other.rng_state and
            self.sampling_calls == other.sampling_calls and
            self.output_len == other.output_len and
            self.output_ptr == other.output_ptr and
            self.output_capacity == other.output_capacity;
    }
};

fn stageDescriptorEql(left: LaneStage, right: LaneStage) bool {
    return left.lane_index == right.lane_index and
        left.prompt_len == right.prompt_len and
        left.cache == right.cache and
        std.meta.eql(left.kv_mark, right.kv_mark) and
        left.rng_state == right.rng_state and
        std.mem.eql(u64, &left.rng_after, &right.rng_after) and
        left.sampling_calls == right.sampling_calls and
        left.sampling_calls_after == right.sampling_calls_after and
        left.output.ptr == right.output.ptr and
        left.output.len == right.output.len and
        left.output_len == right.output_len and
        left.token_id == right.token_id and
        left.terminal == right.terminal;
}

const SessionPhase = enum(u8) {
    idle,
    active,
    preparing,
    prepared,
    committing,
    aborting,
};

/// One address-stable Session owns exactly four initial lanes. Terminal lanes
/// retire permanently; every later transaction contains all and only live
/// lanes. Default-initialize in place (`var session: Session = .{}`), then call
/// `close` before releasing its receipt. Moving/copying a live Session fails
/// closed because the Bank fence remains bound to the original address.
pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    receipt: resource_bank.Receipt = undefined,
    request_epoch: u64 = 0,
    execution_abi: u64 = 0,
    expected_kv_capacity: u64 = 0,
    initialized: bool = false,
    next_sequence: u64 = 0,
    next_steps: [width]u64 = [_]u64{0} ** width,
    retired: [width]bool = [_]bool{false} ** width,
    kv_state_chains: [width]Digest =
        [_]Digest{[_]u8{0} ** 32} ** width,
    chain_initialized: [width]bool = [_]bool{false} ** width,
    bindings: [width]?BindingIdentity = [_]?BindingIdentity{null} ** width,
    phase: SessionPhase = .idle,
    next_batch_generation: u64 = 1,
    active_batch_generation: u64 = 0,
    active_permit: ?resource_bank.PublicationPermit = null,
    active_proposal: ?ProposalV1 = null,
    active_proposal_sha256: Digest = [_]u8{0} ** 32,
    active_stages: [width]?LaneStage = [_]?LaneStage{null} ** width,
    active_prepared_kv: [width]?kv.PreparedRowCommit =
        [_]?kv.PreparedRowCommit{null} ** width,
    active_ack: ?PrepareAckV1 = null,
    active_sink: ?SinkV1 = null,

    pub fn init(
        self: *Session,
        bank: *resource_bank.Bank,
        receipt: resource_bank.Receipt,
        request_epoch: u64,
        execution_abi: u64,
        expected_kv_capacity: u64,
    ) Error!void {
        if (self.initialized) return error.InvalidState;
        if (request_epoch == 0 or execution_abi == 0 or
            expected_kv_capacity == 0 or
            receipt.claim.queue_slots != width or
            receipt.claim.kv_bytes != expected_kv_capacity)
            return error.InvalidConfiguration;
        bank.validateCommitted(receipt) catch
            return error.ResourceReceiptInvalid;
        bank.bindPublicationSession(
            receipt,
            request_epoch,
            @intFromPtr(self),
        ) catch return error.InvalidState;
        self.* = .{
            .bank = bank,
            .receipt = receipt,
            .request_epoch = request_epoch,
            .execution_abi = execution_abi,
            .expected_kv_capacity = expected_kv_capacity,
            .initialized = true,
        };
    }

    pub fn close(self: *Session) Error!void {
        if (!self.initialized or self.phase != .idle or
            self.active_batch_generation != 0 or self.active_permit != null)
            return error.InvalidState;
        self.bank.closePublicationSession(
            self.receipt,
            self.request_epoch,
            @intFromPtr(self),
            self.next_sequence,
        ) catch |err| switch (err) {
            error.StaleReservation => return error.ResourceReceiptInvalid,
            else => return error.InvalidState,
        };
        self.initialized = false;
    }

    pub fn activeMask(self: *const Session) u8 {
        var mask: u8 = 0;
        for (self.retired, 0..) |retired, lane| {
            if (!retired) mask |= @as(u8, 1) << @intCast(lane);
        }
        return mask;
    }
};

const BatchState = enum(u8) {
    active,
    prepared,
    committed,
    aborted,
};

pub const Batch = struct {
    session: *Session,
    batch_generation: u64,
    state: BatchState = .active,
    stages: [width]?LaneStage = [_]?LaneStage{null} ** width,
    prepared_kv: [width]?kv.PreparedRowCommit =
        [_]?kv.PreparedRowCommit{null} ** width,
    proposal: ProposalV1,
    proposal_sha256: Digest,
    ack: PrepareAckV1 = .{},
    sink: ?SinkV1 = null,

    pub fn begin(
        session: *Session,
        live_stages: []const LaneStage,
    ) Error!Batch {
        if (!session.initialized or session.phase != .idle or
            session.active_batch_generation != 0 or
            session.active_permit != null)
            return error.InvalidState;
        if (session.next_sequence == std.math.maxInt(u64) or
            session.next_batch_generation == std.math.maxInt(u64))
            return error.SequenceExhausted;

        const expected_mask = session.activeMask();
        if (expected_mask == 0 or live_stages.len == 0 or
            live_stages.len > width or
            live_stages.len != @popCount(expected_mask))
            return error.InvalidLaneSet;

        var stages: [width]?LaneStage = [_]?LaneStage{null} ** width;
        var prepared: [width]?kv.PreparedRowCommit =
            [_]?kv.PreparedRowCommit{null} ** width;
        var lanes = [_]LaneProposalV1{.{}} ** width;
        var proposed_bindings = session.bindings;
        var live_mask: u8 = 0;
        var previous_lane: ?u32 = null;

        for (live_stages) |stage| {
            if (stage.lane_index >= width or
                (previous_lane != null and stage.lane_index <= previous_lane.?) or
                session.retired[stage.lane_index])
                return error.InvalidLaneSet;
            previous_lane = stage.lane_index;
            const lane: usize = stage.lane_index;
            const lane_bit = @as(u8, 1) << @intCast(lane);
            if (live_mask & lane_bit != 0) return error.InvalidLaneSet;
            live_mask |= lane_bit;

            const identity = BindingIdentity.fromStage(stage);
            if (stageHasInternalAlias(stage)) return error.InvalidBinding;
            if (proposed_bindings[lane]) |bound| {
                if (!bound.eql(identity)) return error.InvalidBinding;
            } else {
                proposed_bindings[lane] = identity;
            }
            for (live_stages) |other| {
                if (other.lane_index >= stage.lane_index) break;
                if (bindingsAlias(stage, other)) return error.InvalidBinding;
            }

            const built = try validateAndBuildLane(session, stage);
            stages[lane] = stage;
            prepared[lane] = built.prepared;
            lanes[lane] = built.proposal;
        }
        if (live_mask != expected_mask) return error.InvalidLaneSet;

        var actual_kv_capacity: u64 = 0;
        for (session.bindings, proposed_bindings, 0..) |existing, proposed, lane| {
            const binding = proposed orelse {
                // All four bindings are established by the first complete
                // wave and remain pinned after lane retirement.
                if (session.next_sequence == 0)
                    return error.InvalidBinding;
                continue;
            };
            if (existing) |bound| {
                if (!bound.eql(binding)) return error.InvalidBinding;
            }
            const lane_capacity = std.math.cast(
                u64,
                binding.capacity_bytes,
            ) orelse return error.InvalidConfiguration;
            actual_kv_capacity = std.math.add(
                u64,
                actual_kv_capacity,
                lane_capacity,
            ) catch return error.InvalidConfiguration;
            for (proposed_bindings[0..lane]) |maybe_previous| {
                const previous = maybe_previous orelse continue;
                if (previous.cache_instance == binding.cache_instance)
                    return error.InvalidBinding;
            }
        }
        if (actual_kv_capacity != session.expected_kv_capacity)
            return error.InvalidConfiguration;

        const permit = session.bank.beginPublication(
            session.receipt,
            session.request_epoch,
            @intFromPtr(session),
            session.next_sequence,
        ) catch |err| switch (err) {
            error.StaleReservation => return error.ResourceReceiptInvalid,
            else => return error.InvalidState,
        };
        const batch_generation = session.next_batch_generation;
        const proposal: ProposalV1 = .{
            .request_epoch = session.request_epoch,
            .transaction_sequence = session.next_sequence,
            .resource_permit_generation = permit.generation,
            .execution_abi = session.execution_abi,
            .live_mask = live_mask,
            .live_lane_count = @intCast(live_stages.len),
            .kv_capacity_bytes = actual_kv_capacity,
            .receipt = session.receipt,
            .lanes = lanes,
        };
        const proposal_digest = proposalSha256(proposal);
        session.bindings = proposed_bindings;
        session.next_batch_generation += 1;
        session.active_batch_generation = batch_generation;
        session.active_permit = permit;
        session.active_proposal = proposal;
        session.active_proposal_sha256 = proposal_digest;
        session.active_stages = stages;
        session.active_prepared_kv = prepared;
        session.phase = .active;
        return .{
            .session = session,
            .batch_generation = batch_generation,
            .stages = stages,
            .prepared_kv = prepared,
            .proposal = proposal,
            .proposal_sha256 = proposal_digest,
        };
    }

    /// Revalidate all caller-owned state immediately before the sink sees the
    /// proposal. Any rejection automatically aborts every KV mark and returns
    /// the Session to its prior sequence.
    pub fn prepare(self: *Batch, sink: SinkV1) Error!void {
        if (self.state != .active or !self.owns(.active))
            return error.InvalidState;
        if (sink.abi_version != sink_abi) {
            try self.rollback(.active, false, null, .{});
            return error.InvalidConfiguration;
        }
        const permit = self.session.active_permit.?;
        self.session.phase = .preparing;
        self.session.bank.validatePublication(permit) catch {
            try self.rollback(.preparing, false, null, .{});
            return error.ResourceReceiptInvalid;
        };
        self.revalidateStages() catch |err| {
            try self.rollback(.preparing, false, null, .{});
            return err;
        };

        var ack: PrepareAckV1 = .{};
        const authoritative_proposal = &self.session.active_proposal.?;
        sink.prepare(sink.context, authoritative_proposal, &ack) catch {
            try self.rollback(.preparing, false, null, .{});
            return error.SinkRejected;
        };
        if (ack.abi_version != prepare_ack_abi or ack.sink_epoch == 0 or
            ack.reservation_id == 0 or
            !std.mem.eql(
                u8,
                &ack.proposal_sha256,
                &self.session.active_proposal_sha256,
            ))
        {
            try self.rollback(.preparing, true, sink, ack);
            return error.InvalidPrepareAck;
        }
        self.revalidateStages() catch |err| {
            try self.rollback(.preparing, true, sink, ack);
            return err;
        };
        self.session.bank.validatePublication(permit) catch {
            try self.rollback(.preparing, true, sink, ack);
            return error.ResourceReceiptInvalid;
        };

        self.ack = ack;
        self.sink = sink;
        self.session.active_ack = ack;
        self.session.active_sink = sink;
        self.state = .prepared;
        self.session.phase = .prepared;
    }

    /// Commit all request-local state, close the Session sequence and then
    /// expose one batch receipt through the pre-reserved infallible sink.
    pub fn commit(self: *Batch) Error!CommitReceiptV1 {
        if (self.state != .prepared or !self.owns(.prepared))
            return error.InvalidState;
        const permit = self.session.active_permit.?;
        const proposal = self.session.active_proposal orelse
            return error.InvalidState;
        const proposal_digest = self.session.active_proposal_sha256;
        const sink = self.session.active_sink orelse return error.InvalidState;
        const ack = self.session.active_ack orelse return error.InvalidState;
        self.session.phase = .committing;
        self.session.bank.validatePublication(permit) catch {
            try self.rollback(.committing, true, sink, ack);
            return error.ResourceReceiptInvalid;
        };
        self.revalidateStages() catch |err| {
            try self.rollback(.committing, true, sink, ack);
            return err;
        };

        // Every operation below is bounded and infallible for the state that
        // `commit` just revalidated. Request-local state has no concurrent
        // reader; the sink is the first visibility boundary.
        for (0..width) |lane| {
            if (self.session.active_prepared_kv[lane]) |prepared|
                self.session.active_stages[lane].?.cache
                    .commitPreparedAssumeValid(prepared);
        }
        for (0..width) |lane| {
            const stage = self.session.active_stages[lane] orelse continue;
            const lane_proposal = proposal.lanes[lane];
            stage.rng_state.* = lane_proposal.rng_after;
            stage.sampling_calls.* = @intCast(
                lane_proposal.sampling_calls_after,
            );
            stage.output[@intCast(lane_proposal.output_before)] =
                lane_proposal.token_id;
            stage.output_len.* = @intCast(lane_proposal.output_after);
        }
        for (0..width) |lane| {
            if (self.session.active_stages[lane] == null) continue;
            self.session.next_steps[lane] += 1;
            self.session.kv_state_chains[lane] =
                proposal.lanes[lane].kv_transition.state_chain_after;
            self.session.chain_initialized[lane] = true;
            if (proposal.lanes[lane].terminal)
                self.session.retired[lane] = true;
        }
        self.session.bank.commitPublicationAssumeValid(permit);
        self.session.next_sequence = permit.sequence + 1;
        self.clearActiveSession();
        self.state = .committed;

        const receipt: CommitReceiptV1 = .{
            .proposal = proposal,
            .proposal_sha256 = proposal_digest,
            .prepare_ack = ack,
            .commit_sha256 = commitSha256(
                proposal_digest,
                ack,
            ),
        };
        sink.commit(sink.context, &receipt);
        return receipt;
    }

    pub fn abort(self: *Batch) Error!void {
        return switch (self.state) {
            .active => self.rollback(.active, false, null, .{}),
            .prepared => self.rollback(
                .prepared,
                true,
                self.session.active_sink,
                self.session.active_ack orelse .{},
            ),
            else => error.InvalidState,
        };
    }

    fn rollback(
        self: *Batch,
        expected_phase: SessionPhase,
        notify_sink: bool,
        maybe_sink: ?SinkV1,
        ack: PrepareAckV1,
    ) Error!void {
        if (!self.owns(expected_phase)) return error.InvalidState;
        if (notify_sink and maybe_sink == null) return error.InvalidState;
        self.session.phase = .aborting;
        if (notify_sink) {
            const sink = maybe_sink orelse return error.InvalidState;
            const proposal = &self.session.active_proposal.?;
            sink.abort(sink.context, proposal, &ack);
        }

        var kv_failed = false;
        for (0..width) |lane| {
            const stage = self.session.active_stages[lane] orelse continue;
            if (stage.kv_mark) |mark|
                stage.cache.abortRow(mark) catch {
                    kv_failed = true;
                };
        }
        const permit = self.session.active_permit orelse
            return error.ResourceReceiptInvalid;
        self.session.bank.abortPublication(permit) catch
            return error.ResourceReceiptInvalid;
        self.clearActiveSession();
        self.state = .aborted;
        if (kv_failed) return error.KvTransactionInvalid;
    }

    fn owns(self: *const Batch, phase: SessionPhase) bool {
        if (!self.session.initialized or self.session.phase != phase or
            self.session.active_batch_generation != self.batch_generation)
            return false;
        return self.session.active_permit != null;
    }

    fn clearActiveSession(self: *Batch) void {
        self.session.active_batch_generation = 0;
        self.session.active_permit = null;
        self.session.active_proposal = null;
        self.session.active_proposal_sha256 = [_]u8{0} ** 32;
        self.session.active_stages = [_]?LaneStage{null} ** width;
        self.session.active_prepared_kv =
            [_]?kv.PreparedRowCommit{null} ** width;
        self.session.active_ack = null;
        self.session.active_sink = null;
        self.session.phase = .idle;
    }

    fn revalidateStages(self: *Batch) Error!void {
        const permit = self.session.active_permit orelse
            return error.InvalidState;
        const proposal = self.session.active_proposal orelse
            return error.InvalidState;
        const digest = self.session.active_proposal_sha256;
        const expected_mask = self.session.activeMask();
        if (proposal.abi_version != abi or
            proposal.resource_bank_abi != resource_bank.abi or
            proposal.resource_publication_fence_abi !=
                resource_bank.publication_fence_abi or
            proposal.paged_kv_abi != kv.abi or
            proposal.page_map_root_abi != kv.page_map_root_abi or
            proposal.page_ref_abi != kv.page_ref_abi or
            proposal.page_transition_abi != page_transition_abi or
            proposal.kv_row_txn_abi != kv.row_txn_abi or
            proposal.execution_abi != self.session.execution_abi or
            proposal.request_epoch != self.session.request_epoch or
            proposal.transaction_sequence != permit.sequence or
            proposal.resource_permit_generation != permit.generation or
            proposal.live_mask != expected_mask or expected_mask == 0 or
            proposal.live_lane_count != @popCount(expected_mask) or
            proposal.kv_capacity_bytes != self.session.expected_kv_capacity or
            !std.meta.eql(proposal.receipt, self.session.receipt) or
            !std.meta.eql(proposal, self.proposal) or
            !std.mem.eql(u8, &digest, &self.proposal_sha256) or
            !std.mem.eql(u8, &digest, &proposalSha256(proposal)))
            return error.InvalidState;
        if (self.session.active_ack) |ack| {
            const sink = self.session.active_sink orelse
                return error.InvalidState;
            if (sink.abi_version != sink_abi or
                ack.abi_version != prepare_ack_abi or ack.sink_epoch == 0 or
                ack.reservation_id == 0 or
                !std.mem.eql(u8, &ack.proposal_sha256, &digest))
                return error.InvalidState;
            const local_sink = self.sink orelse return error.InvalidState;
            if (!std.meta.eql(self.ack, ack) or
                !sinkEql(local_sink, sink))
                return error.InvalidState;
        } else if (self.session.active_sink != null or
            self.session.phase == .prepared or
            self.session.phase == .committing)
            return error.InvalidState;

        for (0..width) |lane| {
            const live = expected_mask &
                (@as(u8, 1) << @intCast(lane)) != 0;
            if (!live) {
                if (self.session.active_stages[lane] != null or
                    self.session.active_prepared_kv[lane] != null or
                    self.stages[lane] != null or
                    self.prepared_kv[lane] != null or
                    !std.meta.eql(proposal.lanes[lane], LaneProposalV1{}))
                    return error.InvalidLaneSet;
                continue;
            }
            const stage = self.session.active_stages[lane] orelse
                return error.InvalidLaneSet;
            const local_stage = self.stages[lane] orelse
                return error.InvalidLaneSet;
            if (!stageDescriptorEql(stage, local_stage) or
                !std.meta.eql(
                    self.session.active_prepared_kv[lane],
                    self.prepared_kv[lane],
                ))
                return error.InvalidState;
            if (stage.lane_index != @as(u32, @intCast(lane)) or
                stageHasInternalAlias(stage))
                return error.InvalidBinding;
            const bound = self.session.bindings[lane] orelse
                return error.InvalidBinding;
            if (!bound.eql(BindingIdentity.fromStage(stage)))
                return error.InvalidBinding;
            for (0..lane) |previous_lane| {
                const previous = self.session.active_stages[previous_lane] orelse
                    continue;
                if (bindingsAlias(stage, previous))
                    return error.InvalidBinding;
            }

            const rebuilt = validateAndBuildLane(self.session, stage) catch |err|
                switch (err) {
                    error.KvTransactionInvalid => return error.KvTransactionInvalid,
                    else => return error.InvalidState,
                };
            if (!std.meta.eql(rebuilt.proposal, proposal.lanes[lane]))
                return error.InvalidTransition;
            if (!std.meta.eql(
                rebuilt.prepared,
                self.session.active_prepared_kv[lane],
            ))
                return error.KvTransactionInvalid;
        }
    }
};

const BuiltLane = struct {
    proposal: LaneProposalV1,
    prepared: ?kv.PreparedRowCommit,
};

fn hashRoot(
    hash: *std.crypto.hash.sha2.Sha256,
    root: kv.PageMapRootV1,
) void {
    hashU64(hash, root.abi_version);
    hashU64(hash, root.cache_instance);
    hashU64(hash, root.generation);
    hashU64(hash, root.committed_len);
    hashU64(hash, root.committed_pages);
    hash.update(&root.ownership_sha256);
}

fn initialStateChain(
    logical_kv_sha256: Digest,
    root: kv.PageMapRootV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-token-kv-chain-seed-v1\x00");
    hash.update(&logical_kv_sha256);
    hashRoot(&hash, root);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn appendedStateChain(
    chain_before: Digest,
    prepared: kv.PreparedRowCommit,
    row_payload_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-token-kv-chain-append-v1\x00");
    hash.update(&chain_before);
    hashRoot(&hash, prepared.root_before);
    hashRoot(&hash, prepared.root_after);
    hashU64(&hash, prepared.mark.page_ref.abi_version);
    hashU64(&hash, prepared.mark.page_ref.cache_instance);
    hashU64(&hash, prepared.mark.page_ref.logical_page);
    hashU64(&hash, prepared.mark.page_ref.ownership_generation);
    hashU64(&hash, prepared.mark.generation);
    hash.update(&row_payload_sha256);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn initialRootTransition(
    cache: *const kv.PagedKVCache,
) Error!RootTransitionV1 {
    const root = cache.root();
    cache.validateCurrentRoot(root) catch
        return error.KvTransactionInvalid;
    if (root.abi_version != kv.page_map_root_abi or
        root.cache_instance == 0 or root.committed_len != cache.len)
        return error.KvTransactionInvalid;
    const initial_digest = cache.logicalKvSha256() catch
        return error.KvTransactionInvalid;
    const chain = initialStateChain(initial_digest, root);
    return .{
        .cache_instance = root.cache_instance,
        .root_before_generation = root.generation,
        .root_after_generation = root.generation,
        .root_before_len = root.committed_len,
        .root_after_len = root.committed_len,
        .root_before_pages = root.committed_pages,
        .root_after_pages = root.committed_pages,
        .root_before_ownership_sha256 = root.ownership_sha256,
        .root_after_ownership_sha256 = root.ownership_sha256,
        .initial_logical_kv_sha256 = initial_digest,
        .state_chain_before = chain,
        .state_chain_after = chain,
    };
}

fn rootTransition(
    prepared: kv.PreparedRowCommit,
    chain_before: Digest,
    row_payload_sha256: Digest,
) Error!RootTransitionV1 {
    const mark = prepared.mark;
    const before = prepared.root_before;
    const after = prepared.root_after;
    if (prepared.abi_version != kv.row_txn_abi or
        mark.abi_version != kv.row_txn_abi or
        mark.row_count != 1 or
        before.abi_version != kv.page_map_root_abi or
        after.abi_version != kv.page_map_root_abi or
        mark.page_ref.abi_version != kv.page_ref_abi or
        mark.cache_instance == 0 or
        mark.cache_instance != before.cache_instance or
        mark.cache_instance != after.cache_instance or
        mark.cache_instance != mark.page_ref.cache_instance or
        mark.root_before_generation != before.generation or
        mark.root_after_generation != after.generation or
        before.committed_len != mark.base_len or
        after.committed_len != mark.base_len + 1 or
        after.generation <= before.generation or
        mark.page_ref.logical_page != mark.base_len / kv.page_positions or
        mark.page_ref.ownership_generation == 0)
        return error.KvTransactionInvalid;
    const expected_pages = before.committed_pages +
        @intFromBool(prepared.installs_new_page);
    if (after.committed_pages != expected_pages or
        (prepared.installs_new_page and
            std.mem.eql(
                u8,
                &before.ownership_sha256,
                &after.ownership_sha256,
            )) or
        (!prepared.installs_new_page and
            !std.mem.eql(
                u8,
                &before.ownership_sha256,
                &after.ownership_sha256,
            )))
        return error.KvTransactionInvalid;
    return .{
        .cache_instance = mark.cache_instance,
        .row_txn_generation = mark.generation,
        .root_before_generation = before.generation,
        .root_after_generation = after.generation,
        .root_before_len = before.committed_len,
        .root_after_len = after.committed_len,
        .root_before_pages = before.committed_pages,
        .root_after_pages = after.committed_pages,
        .root_before_ownership_sha256 = before.ownership_sha256,
        .root_after_ownership_sha256 = after.ownership_sha256,
        .logical_page = mark.page_ref.logical_page,
        .page_ownership_generation = mark.page_ref.ownership_generation,
        .installs_new_page = prepared.installs_new_page,
        .row_payload_sha256 = row_payload_sha256,
        .state_chain_before = chain_before,
        .state_chain_after = appendedStateChain(
            chain_before,
            prepared,
            row_payload_sha256,
        ),
    };
}

fn validateAndBuildLane(
    session: *Session,
    stage: LaneStage,
) Error!BuiltLane {
    const lane: usize = stage.lane_index;
    if (stage.prompt_len == 0 or stage.output.len == 0)
        return error.InvalidTransition;
    const output_before = stage.output_len.*;
    if (output_before >= stage.output.len or
        std.math.cast(u64, output_before) == null or
        @as(u64, @intCast(output_before)) != session.next_steps[lane])
        return error.InvalidTransition;
    const output_after = std.math.add(usize, output_before, 1) catch
        return error.InvalidTransition;
    const expected_kv_after = std.math.add(
        usize,
        stage.prompt_len,
        output_before,
    ) catch return error.InvalidTransition;

    var prepared: ?kv.PreparedRowCommit = null;
    var transition: RootTransitionV1 = .{};
    var kv_before = expected_kv_after;
    if (output_before == 0) {
        if (stage.kv_mark != null or stage.cache.len != expected_kv_after or
            session.chain_initialized[lane])
            return error.InvalidTransition;
        transition = try initialRootTransition(stage.cache);
        if (transition.root_after_len != expected_kv_after)
            return error.InvalidTransition;
    } else {
        const mark = stage.kv_mark orelse return error.InvalidTransition;
        const validated = stage.cache.prepareCommit(mark) catch
            return error.KvTransactionInvalid;
        if (!session.chain_initialized[lane])
            return error.InvalidTransition;
        const row_digest = stage.cache.logicalRowTxnSha256(mark) catch
            return error.KvTransactionInvalid;
        transition = try rootTransition(
            validated,
            session.kv_state_chains[lane],
            row_digest,
        );
        if (!std.meta.eql(mark, validated.mark) or
            transition.root_after_len != expected_kv_after or
            transition.root_before_len + 1 != expected_kv_after or
            stage.cache.len != mark.base_len)
            return error.InvalidTransition;
        stage.cache.validateCurrentRoot(validated.root_before) catch
            return error.KvTransactionInvalid;
        prepared = validated;
        kv_before = mark.base_len;
    }

    const calls_before = stage.sampling_calls.*;
    const calls_upper = std.math.add(usize, calls_before, 1) catch
        return error.InvalidTransition;
    if (stage.sampling_calls_after < calls_before or
        stage.sampling_calls_after > calls_upper)
        return error.InvalidTransition;
    if (stage.sampling_calls_after == calls_before and
        !std.mem.eql(u64, stage.rng_state, &stage.rng_after))
        return error.InvalidTransition;

    return .{
        .proposal = .{
            .lane_index = stage.lane_index,
            .step_index = @intCast(output_before),
            .prompt_len = @intCast(stage.prompt_len),
            .kv_before = @intCast(kv_before),
            .kv_after = @intCast(expected_kv_after),
            .kv_capacity_bytes = @intCast(
                stage.cache.capacityLedger().allocation_capacity_bytes,
            ),
            .has_kv_transition = stage.kv_mark != null,
            .kv_transition = transition,
            .output_before = @intCast(output_before),
            .output_after = @intCast(output_after),
            .rng_before = stage.rng_state.*,
            .rng_after = stage.rng_after,
            .sampling_calls_before = @intCast(calls_before),
            .sampling_calls_after = @intCast(stage.sampling_calls_after),
            .token_id = stage.token_id,
            .terminal = stage.terminal,
        },
        .prepared = prepared,
    };
}

fn bindingsAlias(left: LaneStage, right: LaneStage) bool {
    if (left.cache.instance_id == right.cache.instance_id) return true;
    const left_regions = mutableRegions(left);
    const right_regions = mutableRegions(right);
    for (left_regions) |left_region|
        for (right_regions) |right_region|
            if (regionsOverlap(left_region, right_region)) return true;
    return false;
}

const MutableRegion = struct {
    start: usize,
    bytes: usize,
};

fn mutableRegions(stage: LaneStage) [5]MutableRegion {
    return .{
        .{ .start = @intFromPtr(stage.cache), .bytes = @sizeOf(kv.PagedKVCache) },
        .{ .start = @intFromPtr(stage.rng_state), .bytes = @sizeOf(RngState) },
        .{ .start = @intFromPtr(stage.sampling_calls), .bytes = @sizeOf(usize) },
        .{ .start = @intFromPtr(stage.output_len), .bytes = @sizeOf(usize) },
        .{
            .start = @intFromPtr(stage.output.ptr),
            .bytes = std.math.mul(
                usize,
                stage.output.len,
                @sizeOf(u32),
            ) catch std.math.maxInt(usize),
        },
    };
}

fn stageHasInternalAlias(stage: LaneStage) bool {
    const regions = mutableRegions(stage);
    for (regions, 0..) |left, left_index|
        for (regions[left_index + 1 ..]) |right|
            if (regionsOverlap(left, right)) return true;
    return false;
}

fn regionsOverlap(left: MutableRegion, right: MutableRegion) bool {
    const left_end = std.math.add(usize, left.start, left.bytes) catch
        return true;
    const right_end = std.math.add(usize, right.start, right.bytes) catch
        return true;
    return left.start < right_end and right.start < left_end;
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

fn hashClaim(
    hash: *std.crypto.hash.sha2.Sha256,
    claim: resource_bank.Claim,
) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

pub fn proposalSha256(proposal: ProposalV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-token-txn-proposal-v1\x00");
    hashU64(&hash, proposal.abi_version);
    hashU64(&hash, proposal.resource_bank_abi);
    hashU64(&hash, proposal.resource_publication_fence_abi);
    hashU64(&hash, proposal.paged_kv_abi);
    hashU64(&hash, proposal.page_map_root_abi);
    hashU64(&hash, proposal.page_ref_abi);
    hashU64(&hash, proposal.page_transition_abi);
    hashU64(&hash, proposal.kv_row_txn_abi);
    hashU64(&hash, proposal.execution_abi);
    hashU64(&hash, proposal.request_epoch);
    hashU64(&hash, proposal.transaction_sequence);
    hashU64(&hash, proposal.resource_permit_generation);
    hashU8(&hash, proposal.live_mask);
    hashU8(&hash, proposal.live_lane_count);
    hashU64(&hash, proposal.kv_capacity_bytes);
    hashU64(&hash, proposal.receipt.bank_epoch);
    hashU32(&hash, proposal.receipt.slot_index);
    hashU64(&hash, proposal.receipt.generation);
    hashU64(&hash, proposal.receipt.owner_key);
    hashClaim(&hash, proposal.receipt.claim);
    hashU64(&hash, proposal.receipt.integrity);
    for (proposal.lanes) |lane| {
        hashU32(&hash, lane.lane_index);
        hashU64(&hash, lane.step_index);
        hashU64(&hash, lane.prompt_len);
        hashU64(&hash, lane.kv_before);
        hashU64(&hash, lane.kv_after);
        hashU64(&hash, lane.kv_capacity_bytes);
        hashU8(&hash, @intFromBool(lane.has_kv_transition));
        const transition = lane.kv_transition;
        hashU64(&hash, transition.abi_version);
        hashU64(&hash, transition.kv_row_txn_abi);
        hashU64(&hash, transition.page_map_root_abi);
        hashU64(&hash, transition.page_ref_abi);
        hashU64(&hash, transition.cache_instance);
        hashU64(&hash, transition.row_txn_generation);
        hashU64(&hash, transition.root_before_generation);
        hashU64(&hash, transition.root_after_generation);
        hashU64(&hash, transition.root_before_len);
        hashU64(&hash, transition.root_after_len);
        hashU64(&hash, transition.root_before_pages);
        hashU64(&hash, transition.root_after_pages);
        hash.update(&transition.root_before_ownership_sha256);
        hash.update(&transition.root_after_ownership_sha256);
        hashU64(&hash, transition.logical_page);
        hashU64(&hash, transition.page_ownership_generation);
        hashU8(&hash, @intFromBool(transition.installs_new_page));
        hash.update(&transition.initial_logical_kv_sha256);
        hash.update(&transition.row_payload_sha256);
        hash.update(&transition.state_chain_before);
        hash.update(&transition.state_chain_after);
        hashU64(&hash, lane.output_before);
        hashU64(&hash, lane.output_after);
        for (lane.rng_before) |word| hashU64(&hash, word);
        for (lane.rng_after) |word| hashU64(&hash, word);
        hashU64(&hash, lane.sampling_calls_before);
        hashU64(&hash, lane.sampling_calls_after);
        hashU32(&hash, lane.token_id);
        hashU8(&hash, @intFromBool(lane.terminal));
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn commitSha256(
    proposal_sha256: Digest,
    ack: PrepareAckV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-token-txn-commit-v1\x00");
    hashU64(&hash, commit_receipt_abi);
    hash.update(&proposal_sha256);
    hashU64(&hash, ack.abi_version);
    hash.update(&ack.proposal_sha256);
    hashU64(&hash, ack.sink_epoch);
    hashU64(&hash, ack.reservation_id);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_execution_abi: u64 = 0x5042_5445_5354_0001;
const test_kv_capacity: u64 = 4 * 544;

const TestSink = struct {
    reject: bool = false,
    corrupt_ack: bool = false,
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,
    receipts: [8]CommitReceiptV1 = undefined,

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
        self.prepare_calls += 1;
        if (self.reject) return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = proposalSha256(proposal.*),
            .sink_epoch = 0x5041_4745,
            .reservation_id = self.prepare_calls,
        };
        if (self.corrupt_ack) ack.proposal_sha256[0] ^= 1;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const CommitReceiptV1,
    ) void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        std.debug.assert(self.commit_calls < self.receipts.len);
        self.receipts[self.commit_calls] = receipt.*;
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

const TestState = struct {
    caches: [width]kv.PagedKVCache,
    rng: [width]RngState,
    sampling_calls: [width]usize = [_]usize{0} ** width,
    outputs: [width][4]u32 =
        [_][4]u32{[_]u32{0xdead_beef} ** 4} ** width,
    lengths: [width]usize = [_]usize{0} ** width,

    fn init() !TestState {
        return initWithCommittedRows(1);
    }

    fn initWithCommittedRows(row_count: usize) !TestState {
        if (row_count == 0 or row_count > 17)
            return error.InvalidConfiguration;
        var caches: [width]kv.PagedKVCache = undefined;
        var initialized: usize = 0;
        errdefer for (caches[0..initialized]) |*cache| cache.deinit();
        for (&caches, 0..) |*cache, lane| {
            cache.* = try kv.PagedKVCache.init(testing.allocator, 2, 1, 17);
            initialized += 1;
            for (0..row_count) |row| {
                const mark = try cache.beginRow();
                inline for (0..2) |layer| {
                    const key = [_]f32{@floatFromInt(
                        row * 100 + lane + layer + 1,
                    )};
                    const value = [_]f32{@floatFromInt(
                        row * 100 + lane + layer + 11,
                    )};
                    _ = try cache.appendRowTxn(mark, layer, &key, &value);
                }
                try cache.commitRowTxn(mark);
            }
        }
        var rng: [width]RngState = undefined;
        for (&rng, 0..) |*state, lane|
            state.* = .{ lane + 1, lane + 2, lane + 3, lane + 4 };
        return .{ .caches = caches, .rng = rng };
    }

    fn deinit(self: *TestState) void {
        for (&self.caches) |*cache| cache.deinit();
    }

    fn firstWave(self: *TestState, terminal_mask: u8) [width]LaneStage {
        var stages: [width]LaneStage = undefined;
        for (&stages, 0..) |*stage, lane| {
            var after = self.rng[lane];
            after[0] += 100;
            stage.* = .{
                .lane_index = @intCast(lane),
                .prompt_len = self.caches[lane].len,
                .cache = &self.caches[lane],
                .rng_state = &self.rng[lane],
                .rng_after = after,
                .sampling_calls = &self.sampling_calls[lane],
                .sampling_calls_after = 1,
                .output = &self.outputs[lane],
                .output_len = &self.lengths[lane],
                .token_id = @intCast(10 + lane),
                .terminal = terminal_mask &
                    (@as(u8, 1) << @intCast(lane)) != 0,
            };
        }
        return stages;
    }

    fn nextWave(
        self: *TestState,
        marks: *[width]?kv.RowTxnMark,
        terminal_mask: u8,
    ) ![width]LaneStage {
        var stages: [width]LaneStage = undefined;
        for (&stages, 0..) |*stage, lane| {
            const mark = try self.caches[lane].beginRow();
            marks[lane] = mark;
            inline for (0..2) |layer| {
                const key = [_]f32{@floatFromInt(100 + lane + layer)};
                const value = [_]f32{@floatFromInt(200 + lane + layer)};
                _ = try self.caches[lane].appendRowTxn(
                    mark,
                    layer,
                    &key,
                    &value,
                );
            }
            var after = self.rng[lane];
            after[1] += 200;
            stage.* = .{
                .lane_index = @intCast(lane),
                .prompt_len = mark.base_len,
                .cache = &self.caches[lane],
                .kv_mark = mark,
                .rng_state = &self.rng[lane],
                .rng_after = after,
                .sampling_calls = &self.sampling_calls[lane],
                .sampling_calls_after = self.sampling_calls[lane] + 1,
                .output = &self.outputs[lane],
                .output_len = &self.lengths[lane],
                .token_id = @intCast(20 + lane),
                .terminal = terminal_mask &
                    (@as(u8, 1) << @intCast(lane)) != 0,
            };
        }
        return stages;
    }
};

fn admittedReceipt(
    slots: *[width]resource_bank.Slot,
    bank: *resource_bank.Bank,
    epoch: u64,
) !resource_bank.Receipt {
    bank.* = try resource_bank.Bank.init(
        slots,
        .{ .host_bytes = 4096, .kv_bytes = 4096, .queue_slots = width },
        epoch,
    );
    return bank.commit(try bank.reserve(
        epoch ^ 0x55aa,
        .{ .kv_bytes = test_kv_capacity, .queue_slots = width },
    ));
}

test "PagedTokenTxn commits exact root transitions through one batch fence" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 701);
    var session: Session = .{};
    try session.init(
        &bank,
        receipt,
        0x7010,
        test_execution_abi,
        test_kv_capacity,
    );
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var first_stages = state.firstWave(0);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    _ = try first.commit();

    var marks = [_]?kv.RowTxnMark{null} ** width;
    var second_stages = try state.nextWave(&marks, 0b1111);
    var roots_before: [width]kv.PageMapRootV1 = undefined;
    for (&state.caches, 0..) |*cache, lane|
        roots_before[lane] = cache.root();
    var second = try Batch.begin(&session, &second_stages);
    for (0..width) |lane| {
        const proposal = second.proposal.lanes[lane];
        try testing.expect(proposal.has_kv_transition);
        try testing.expectEqual(
            roots_before[lane].generation,
            proposal.kv_transition.root_before_generation,
        );
        try testing.expectEqual(
            roots_before[lane].committed_len + 1,
            proposal.kv_transition.root_after_len,
        );
        try testing.expectEqual(
            marks[lane].?.page_ref.ownership_generation,
            proposal.kv_transition.page_ownership_generation,
        );
    }
    try second.prepare(sink.interface());
    const committed = try second.commit();
    try testing.expectEqual(
        committed.commit_sha256,
        commitSha256(committed.proposal_sha256, committed.prepare_ack),
    );
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    for (&state.caches) |*cache| try testing.expectEqual(@as(usize, 2), cache.len);
    try testing.expectEqual(@as(u8, 0), session.activeMask());
    try session.close();
    try bank.release(receipt);
}

test "PagedTokenTxn sink rejection restores roots and permits generation-fenced retry" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 702);
    var session: Session = .{};
    try session.init(
        &bank,
        receipt,
        0x7020,
        test_execution_abi,
        test_kv_capacity,
    );
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var first_stages = state.firstWave(0);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    _ = try first.commit();

    var roots_before: [width]kv.PageMapRootV1 = undefined;
    for (&state.caches, 0..) |*cache, lane|
        roots_before[lane] = cache.root();
    const rng_before = state.rng;
    const outputs_before = state.outputs;
    var rejected_marks = [_]?kv.RowTxnMark{null} ** width;
    var rejected_stages = try state.nextWave(&rejected_marks, 0);
    sink.reject = true;
    var rejected = try Batch.begin(&session, &rejected_stages);
    try testing.expectError(
        error.SinkRejected,
        rejected.prepare(sink.interface()),
    );
    for (&state.caches, 0..) |*cache, lane| {
        try testing.expectEqualDeep(roots_before[lane], cache.root());
        try testing.expectEqual(@as(usize, 1), cache.len);
        try testing.expectError(
            error.InvalidTransaction,
            cache.prepareCommit(rejected_marks[lane].?),
        );
    }
    try testing.expectEqualDeep(rng_before, state.rng);
    try testing.expectEqualDeep(outputs_before, state.outputs);
    try testing.expectEqual(@as(u64, 1), session.next_sequence);

    sink.reject = false;
    var retry_marks = [_]?kv.RowTxnMark{null} ** width;
    var retry_stages = try state.nextWave(&retry_marks, 0b1111);
    for (0..width) |lane|
        try testing.expect(
            retry_marks[lane].?.generation > rejected_marks[lane].?.generation,
        );
    var retry = try Batch.begin(&session, &retry_stages);
    try retry.prepare(sink.interface());
    _ = try retry.commit();
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    try testing.expectEqual(@as(usize, 0), sink.abort_calls);
    try session.close();
    try bank.release(receipt);
}

test "PagedTokenTxn rejects one-byte KV underclaim and duplicate cache ownership" {
    var state = try TestState.init();
    defer state.deinit();

    {
        var slots: [width]resource_bank.Slot = undefined;
        var bank = try resource_bank.Bank.init(
            &slots,
            .{ .host_bytes = 4096, .kv_bytes = 4096, .queue_slots = width },
            703,
        );
        const underclaim = test_kv_capacity - 1;
        const receipt = try bank.commit(try bank.reserve(
            0x7030,
            .{ .kv_bytes = underclaim, .queue_slots = width },
        ));
        var session: Session = .{};
        try session.init(
            &bank,
            receipt,
            0x7031,
            test_execution_abi,
            underclaim,
        );
        var stages = state.firstWave(0);
        try testing.expectError(
            error.InvalidConfiguration,
            Batch.begin(&session, &stages),
        );
        try testing.expectEqual(@as(u64, 0), session.next_sequence);
        try session.close();
        try bank.release(receipt);
    }

    {
        var slots: [width]resource_bank.Slot = undefined;
        var bank: resource_bank.Bank = undefined;
        const receipt = try admittedReceipt(&slots, &bank, 704);
        var session: Session = .{};
        try session.init(
            &bank,
            receipt,
            0x7040,
            test_execution_abi,
            test_kv_capacity,
        );
        var stages = state.firstWave(0);
        stages[1].cache = stages[0].cache;
        try testing.expectError(
            error.InvalidBinding,
            Batch.begin(&session, &stages),
        );
        try testing.expectEqual(@as(u64, 0), session.next_sequence);
        try session.close();
        try bank.release(receipt);
    }
}

test "PagedTokenTxn page-boundary ack rejection reuses allocation with fresh ownership" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 705);
    var session: Session = .{};
    try session.init(
        &bank,
        receipt,
        0x7050,
        test_execution_abi,
        test_kv_capacity,
    );
    var state = try TestState.initWithCommittedRows(16);
    defer state.deinit();
    var sink: TestSink = .{};

    var first_stages = state.firstWave(0);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    _ = try first.commit();

    var roots_before: [width]kv.PageMapRootV1 = undefined;
    for (&state.caches, 0..) |*cache, lane| {
        roots_before[lane] = cache.root();
        const resident = try cache.residentLedger();
        try testing.expectEqual(@as(usize, 1), resident.allocated_pages);
        try testing.expectEqual(@as(usize, 1), resident.committed_pages);
        try testing.expectEqual(@as(usize, 0), resident.reusable_pages);
    }
    const rng_before = state.rng;
    const outputs_before = state.outputs;

    var rejected_marks = [_]?kv.RowTxnMark{null} ** width;
    var rejected_stages = try state.nextWave(&rejected_marks, 0);
    for (&state.caches) |*cache| {
        const provisional = try cache.residentLedger();
        try testing.expectEqual(@as(usize, 2), provisional.allocated_pages);
        try testing.expectEqual(@as(usize, 1), provisional.provisional_pages);
    }
    sink.corrupt_ack = true;
    var rejected = try Batch.begin(&session, &rejected_stages);
    try testing.expectError(
        error.InvalidPrepareAck,
        rejected.prepare(sink.interface()),
    );
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    for (&state.caches, 0..) |*cache, lane| {
        try testing.expectEqualDeep(roots_before[lane], cache.root());
        try testing.expectEqual(@as(usize, 16), cache.len);
        const resident = try cache.residentLedger();
        try testing.expectEqual(@as(usize, 2), resident.allocated_pages);
        try testing.expectEqual(@as(usize, 1), resident.committed_pages);
        try testing.expectEqual(@as(usize, 1), resident.reusable_pages);
        try testing.expectError(
            error.InvalidTransaction,
            cache.prepareCommit(rejected_marks[lane].?),
        );
    }
    try testing.expectEqualDeep(rng_before, state.rng);
    try testing.expectEqualDeep(outputs_before, state.outputs);
    try testing.expectEqual(@as(u64, 1), session.next_sequence);

    sink.corrupt_ack = false;
    var retry_marks = [_]?kv.RowTxnMark{null} ** width;
    var retry_stages = try state.nextWave(&retry_marks, 0b1111);
    for (&state.caches, 0..) |*cache, lane| {
        try testing.expect(
            retry_marks[lane].?.page_ref.ownership_generation >
                rejected_marks[lane].?.page_ref.ownership_generation,
        );
        const provisional = try cache.residentLedger();
        try testing.expectEqual(@as(usize, 2), provisional.allocated_pages);
        try testing.expectEqual(@as(usize, 1), provisional.provisional_pages);
        try testing.expectEqual(@as(usize, 0), provisional.reusable_pages);
    }
    var retry = try Batch.begin(&session, &retry_stages);
    for (0..width) |lane| {
        try testing.expect(retry.proposal.lanes[lane].has_kv_transition);
        try testing.expect(
            retry.proposal.lanes[lane].kv_transition.installs_new_page,
        );
        try testing.expectEqual(
            @as(u64, 1),
            retry.proposal.lanes[lane].kv_transition.logical_page,
        );
    }
    try retry.prepare(sink.interface());
    _ = try retry.commit();
    for (&state.caches) |*cache| {
        try testing.expectEqual(@as(usize, 17), cache.len);
        const resident = try cache.residentLedger();
        try testing.expectEqual(@as(usize, 2), resident.committed_pages);
        try testing.expectEqual(@as(usize, 0), resident.reusable_pages);
    }
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    try session.close();
    try bank.release(receipt);
}
