//! Bounded synchronous token-publication transaction foundation.
//!
//! TokenTxn v1 joins one fixed-B4 live-lane wave to a committed ResourceBank
//! receipt, generation-fenced KV cursor transitions, full caller-owned RNG
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
const kv = @import("kv_cache.zig");

pub const abi: u64 = 0x4754_584e_0000_0001;
pub const sink_abi: u64 = 0x4754_5853_0000_0001;
pub const prepare_ack_abi: u64 = 0x4754_5841_0000_0001;
pub const commit_receipt_abi: u64 = 0x4754_5843_0000_0001;
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
    cache: *kv.KVCache,
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

pub const LaneProposalV1 = struct {
    lane_index: u32 = 0,
    step_index: u64 = 0,
    prompt_len: u64 = 0,
    kv_before: u64 = 0,
    kv_after: u64 = 0,
    kv_generation: u64 = 0,
    has_kv_transition: bool = false,
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
    kv_row_txn_abi: u64 = kv.row_txn_abi,
    request_epoch: u64,
    transaction_sequence: u64,
    resource_permit_generation: u64,
    live_mask: u8,
    live_lane_count: u8,
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
    cache: *kv.KVCache,
    rng_state: *RngState,
    sampling_calls: *usize,
    output_len: *usize,
    output_ptr: [*]u32,
    output_capacity: usize,

    fn fromStage(stage: LaneStage) BindingIdentity {
        return .{
            .cache = stage.cache,
            .rng_state = stage.rng_state,
            .sampling_calls = stage.sampling_calls,
            .output_len = stage.output_len,
            .output_ptr = stage.output.ptr,
            .output_capacity = stage.output.len,
        };
    }

    fn eql(self: BindingIdentity, other: BindingIdentity) bool {
        return self.cache == other.cache and
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
    initialized: bool = false,
    next_sequence: u64 = 0,
    next_steps: [width]u64 = [_]u64{0} ** width,
    retired: [width]bool = [_]bool{false} ** width,
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
    ) Error!void {
        if (self.initialized) return error.InvalidState;
        if (request_epoch == 0 or receipt.claim.queue_slots != width)
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
            .live_mask = live_mask,
            .live_lane_count = @intCast(live_stages.len),
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
                stage.cache.abortRows(mark) catch {
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
            proposal.kv_row_txn_abi != kv.row_txn_abi or
            proposal.request_epoch != self.session.request_epoch or
            proposal.transaction_sequence != permit.sequence or
            proposal.resource_permit_generation != permit.generation or
            proposal.live_mask != expected_mask or expected_mask == 0 or
            proposal.live_lane_count != @popCount(expected_mask) or
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
    var kv_generation: u64 = 0;
    var kv_before = expected_kv_after;
    if (output_before == 0) {
        if (stage.kv_mark != null or stage.cache.len != expected_kv_after)
            return error.InvalidTransition;
    } else {
        const mark = stage.kv_mark orelse return error.InvalidTransition;
        const validated = stage.cache.prepareCommit(mark) catch
            return error.KvTransactionInvalid;
        if (mark.row_count != 1 or validated.row_count != 1 or
            validated.target_len != expected_kv_after or
            validated.base_len + 1 != expected_kv_after or
            stage.cache.len != validated.base_len)
            return error.InvalidTransition;
        prepared = validated;
        kv_generation = mark.generation;
        kv_before = validated.base_len;
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
            .kv_generation = kv_generation,
            .has_kv_transition = stage.kv_mark != null,
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
        .{ .start = @intFromPtr(stage.cache), .bytes = @sizeOf(kv.KVCache) },
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
    hash.update("glacier-token-txn-proposal-v1\x00");
    hashU64(&hash, proposal.abi_version);
    hashU64(&hash, proposal.resource_bank_abi);
    hashU64(&hash, proposal.resource_publication_fence_abi);
    hashU64(&hash, proposal.kv_row_txn_abi);
    hashU64(&hash, proposal.request_epoch);
    hashU64(&hash, proposal.transaction_sequence);
    hashU64(&hash, proposal.resource_permit_generation);
    hashU8(&hash, proposal.live_mask);
    hashU8(&hash, proposal.live_lane_count);
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
        hashU64(&hash, lane.kv_generation);
        hashU8(&hash, @intFromBool(lane.has_kv_transition));
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
    hash.update("glacier-token-txn-commit-v1\x00");
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
    caches: [width]kv.KVCache,
    rng: [width]RngState,
    sampling_calls: [width]usize = [_]usize{0} ** width,
    outputs: [width][4]u32 = [_][4]u32{[_]u32{0xdead_beef} ** 4} ** width,
    lengths: [width]usize = [_]usize{0} ** width,

    fn init() !TestState {
        var caches: [width]kv.KVCache = undefined;
        var initialized: usize = 0;
        errdefer for (caches[0..initialized]) |*cache| cache.deinit();
        for (&caches, 0..) |*cache, lane| {
            cache.* = try kv.KVCache.init(testing.allocator, 1, 1, 4);
            initialized += 1;
            const key = [_]f32{@floatFromInt(lane + 1)};
            const value = [_]f32{@floatFromInt(lane + 11)};
            _ = try cache.appendRow(0, &key, &value);
            cache.commit();
        }
        var rng: [width]RngState = undefined;
        for (&rng, 0..) |*state, lane|
            state.* = .{ lane + 1, lane + 2, lane + 3, lane + 4 };
        return .{ .caches = caches, .rng = rng };
    }

    fn deinit(self: *TestState) void {
        for (&self.caches) |*cache| cache.deinit();
    }

    fn firstWave(
        self: *TestState,
        terminal_mask: u8,
    ) [width]LaneStage {
        var stages: [width]LaneStage = undefined;
        for (&stages, 0..) |*stage, lane| {
            var after = self.rng[lane];
            after[0] += 100;
            stage.* = .{
                .lane_index = @intCast(lane),
                .prompt_len = 1,
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
        lane_indices: []const u32,
        marks: *[width]?kv.RowTxnMark,
        terminal_mask: u8,
        destination: []LaneStage,
    ) !void {
        testing.expectEqual(lane_indices.len, destination.len) catch
            return error.TestUnexpectedResult;
        for (lane_indices, destination) |lane_u32, *stage| {
            const lane: usize = lane_u32;
            const mark = try self.caches[lane].beginRows(1);
            marks[lane] = mark;
            const key = [_]f32{@floatFromInt(100 + lane)};
            const value = [_]f32{@floatFromInt(200 + lane)};
            _ = try self.caches[lane].appendRowTxn(mark, 0, &key, &value);
            var after = self.rng[lane];
            after[1] += 200;
            stage.* = .{
                .lane_index = lane_u32,
                .prompt_len = 1,
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
    }
};

fn admittedReceipt(
    slots: *[width]resource_bank.Slot,
    bank: *resource_bank.Bank,
    epoch: u64,
) !resource_bank.Receipt {
    bank.* = try resource_bank.Bank.init(
        slots,
        .{ .host_bytes = 1024, .queue_slots = width },
        epoch,
    );
    const reservation = try bank.reserve(
        epoch ^ 0x55aa,
        .{ .kv_bytes = 128, .queue_slots = width },
    );
    return bank.commit(reservation);
}

test "TokenTxn commits two exact four-lane waves through one prepared sink" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 101);
    var session: Session = .{};
    try session.init(&bank, receipt, 101 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var first_stages = state.firstWave(0);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    const first_receipt = try first.commit();
    try testing.expectEqual(@as(u64, 0), first_receipt.proposal.transaction_sequence);
    try testing.expectEqual(@as(u8, 0b1111), first_receipt.proposal.live_mask);
    try testing.expectEqual(first_receipt.commit_sha256, commitSha256(
        first_receipt.proposal_sha256,
        first_receipt.prepare_ack,
    ));
    try testing.expectError(error.InvalidState, first.commit());
    try testing.expectError(error.InvalidState, first.abort());

    var marks = [_]?kv.RowTxnMark{null} ** width;
    var second_stages: [width]LaneStage = undefined;
    try state.nextWave(&.{ 0, 1, 2, 3 }, &marks, 0, &second_stages);
    var second = try Batch.begin(&session, &second_stages);
    try second.prepare(sink.interface());
    const second_receipt = try second.commit();

    try testing.expectEqual(@as(u64, 1), second_receipt.proposal.transaction_sequence);
    try testing.expectEqual(@as(usize, 2), sink.prepare_calls);
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    try testing.expectEqual(@as(usize, 0), sink.abort_calls);
    for (0..width) |lane| {
        try testing.expectEqual(@as(usize, 2), state.caches[lane].len);
        try testing.expectEqual(@as(usize, 2), state.lengths[lane]);
        try testing.expectEqual(@as(u32, @intCast(10 + lane)), state.outputs[lane][0]);
        try testing.expectEqual(@as(u32, @intCast(20 + lane)), state.outputs[lane][1]);
        try testing.expectEqual(@as(usize, 2), state.sampling_calls[lane]);
        try testing.expectEqual(@as(u64, 2), session.next_steps[lane]);
    }
    try bank.validateCommitted(receipt);
    try session.close();
    try bank.release(receipt);
}

test "TokenTxn prepare rejection aborts every KV mark and permits exact retry" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 102);
    var session: Session = .{};
    try session.init(&bank, receipt, 102 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var first_stages = state.firstWave(0);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    _ = try first.commit();

    const rng_before = state.rng;
    const calls_before = state.sampling_calls;
    const outputs_before = state.outputs;
    const lengths_before = state.lengths;
    var rejected_marks = [_]?kv.RowTxnMark{null} ** width;
    var rejected_stages: [width]LaneStage = undefined;
    try state.nextWave(&.{ 0, 1, 2, 3 }, &rejected_marks, 0, &rejected_stages);
    sink.reject = true;
    var rejected = try Batch.begin(&session, &rejected_stages);
    try testing.expectError(error.SinkRejected, rejected.prepare(sink.interface()));
    try testing.expectError(error.InvalidState, rejected.abort());

    try testing.expectEqualDeep(rng_before, state.rng);
    try testing.expectEqualDeep(calls_before, state.sampling_calls);
    try testing.expectEqualDeep(outputs_before, state.outputs);
    try testing.expectEqualDeep(lengths_before, state.lengths);
    for (&state.caches) |*cache| try testing.expectEqual(@as(usize, 1), cache.len);
    try testing.expectEqual(@as(u64, 1), session.next_sequence);
    try testing.expectEqual(SessionPhase.idle, session.phase);

    sink.reject = false;
    var retry_marks = [_]?kv.RowTxnMark{null} ** width;
    var retry_stages: [width]LaneStage = undefined;
    try state.nextWave(&.{ 0, 1, 2, 3 }, &retry_marks, 0, &retry_stages);
    var retry = try Batch.begin(&session, &retry_stages);
    try retry.prepare(sink.interface());
    _ = try retry.commit();
    try testing.expectEqual(@as(usize, 3), sink.prepare_calls);
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    try session.close();
    try bank.release(receipt);
}

test "TokenTxn explicit prepared abort releases sink reservation and KV marks" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 107);
    var session: Session = .{};
    try session.init(&bank, receipt, 107 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var first_stages = state.firstWave(0);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    _ = try first.commit();

    const rng_before = state.rng;
    const calls_before = state.sampling_calls;
    const outputs_before = state.outputs;
    const lengths_before = state.lengths;
    var marks = [_]?kv.RowTxnMark{null} ** width;
    var stages: [width]LaneStage = undefined;
    try state.nextWave(&.{ 0, 1, 2, 3 }, &marks, 0, &stages);
    var batch = try Batch.begin(&session, &stages);
    try batch.prepare(sink.interface());
    try batch.abort();

    try testing.expectEqual(@as(usize, 2), sink.prepare_calls);
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    try testing.expectEqualDeep(rng_before, state.rng);
    try testing.expectEqualDeep(calls_before, state.sampling_calls);
    try testing.expectEqualDeep(outputs_before, state.outputs);
    try testing.expectEqualDeep(lengths_before, state.lengths);
    for (&state.caches) |*cache| try testing.expectEqual(@as(usize, 1), cache.len);
    try testing.expectEqual(@as(u64, 1), session.next_sequence);
    try testing.expectEqual(SessionPhase.idle, session.phase);
    try testing.expectError(error.InvalidState, batch.abort());
    try session.close();
    try bank.release(receipt);
}

test "TokenTxn invalid ack aborts reservation and resource fencing rejects release" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 103);
    var session: Session = .{};
    try session.init(&bank, receipt, 103 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{ .corrupt_ack = true };

    var stages = state.firstWave(0);
    var batch = try Batch.begin(&session, &stages);
    try testing.expectError(
        error.InvalidPrepareAck,
        batch.prepare(sink.interface()),
    );
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    try testing.expectEqual([_]usize{0} ** width, state.lengths);
    try testing.expectEqual(@as(u64, 0), session.next_sequence);

    try testing.expectError(
        resource_bank.Error.InvalidTransition,
        bank.release(receipt),
    );
    try session.close();
    try bank.release(receipt);
    try testing.expectError(
        error.InvalidState,
        Batch.begin(&session, &stages),
    );
}

test "TokenTxn session requires an exact four-slot B4 receipt" {
    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{ .host_bytes = 64, .queue_slots = 1 },
        203,
    );
    const reservation = try bank.reserve(
        9,
        .{ .kv_bytes = 32, .queue_slots = 1 },
    );
    const receipt = try bank.commit(reservation);
    var session: Session = .{};
    try testing.expectError(
        error.InvalidConfiguration,
        session.init(&bank, receipt, 1),
    );
    try bank.release(receipt);
    try testing.expectError(
        error.InvalidConfiguration,
        session.init(&bank, receipt, 1),
    );
}

test "TokenTxn session address fence rejects value copies and pins release" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 204);
    var session: Session = .{};
    try session.init(&bank, receipt, 204 ^ 0xaa55);
    try testing.expectError(
        error.InvalidState,
        session.init(&bank, receipt, 204 ^ 0xaa55),
    );
    try testing.expect(session.initialized);

    var duplicate: Session = .{};
    try testing.expectError(
        error.InvalidState,
        duplicate.init(&bank, receipt, 204 ^ 0xaa55),
    );
    var copied = session;
    var state = try TestState.init();
    defer state.deinit();
    var stages = state.firstWave(0);
    try testing.expectError(
        error.InvalidState,
        Batch.begin(&copied, &stages),
    );
    try testing.expectError(error.InvalidState, copied.close());
    try testing.expectError(
        resource_bank.Error.InvalidTransition,
        bank.release(receipt),
    );

    try session.close();
    try bank.release(receipt);
}

test "TokenTxn live Session cannot rebind to a different receipt" {
    var slots = [_]resource_bank.Slot{.{}} ** 2;
    var bank = try resource_bank.Bank.init(
        &slots,
        .{ .queue_slots = 8 },
        207,
    );
    const first = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 4 },
    ));
    const second = try bank.commit(try bank.reserve(
        2,
        .{ .queue_slots = 4 },
    ));
    var session: Session = .{};
    try session.init(&bank, first, 300);
    try testing.expectError(
        error.InvalidState,
        session.init(&bank, second, 301),
    );
    try bank.validateCommitted(first);
    try bank.release(second);
    try session.close();
    try bank.release(first);
}

test "TokenTxn copied batches cannot prepare commit or abort twice" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 205);
    var session: Session = .{};
    try session.init(&bank, receipt, 205 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var stages = state.firstWave(0);
    var batch = try Batch.begin(&session, &stages);
    var active_copy = batch;
    try batch.prepare(sink.interface());
    try testing.expectError(
        error.InvalidState,
        active_copy.prepare(sink.interface()),
    );
    try testing.expectEqual(@as(usize, 1), sink.prepare_calls);
    try testing.expectError(
        resource_bank.Error.InvalidTransition,
        bank.release(receipt),
    );
    var prepared_copy = batch;
    _ = try batch.commit();
    try testing.expectError(error.InvalidState, prepared_copy.commit());
    try testing.expectError(error.InvalidState, prepared_copy.abort());
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);

    var marks = [_]?kv.RowTxnMark{null} ** width;
    var next_stages: [width]LaneStage = undefined;
    try state.nextWave(&.{ 0, 1, 2, 3 }, &marks, 0, &next_stages);
    var aborting = try Batch.begin(&session, &next_stages);
    try aborting.prepare(sink.interface());
    var abort_copy = aborting;
    try aborting.abort();
    try testing.expectError(error.InvalidState, abort_copy.abort());
    try testing.expectError(error.InvalidState, abort_copy.commit());
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    for (&state.caches) |*cache|
        try testing.expectEqual(@as(usize, 1), cache.len);

    try session.close();
    try bank.release(receipt);
}

test "TokenTxn copied prepared descriptor mutations roll back authority" {
    const Mutation = enum {
        token,
        rng_after,
        terminal,
        output_binding,
        prepare_ack,
        sink_binding,
        proposal,
        kv_mark,
    };
    const mutations = [_]Mutation{
        .token,
        .rng_after,
        .terminal,
        .output_binding,
        .prepare_ack,
        .sink_binding,
        .proposal,
        .kv_mark,
    };

    for (mutations) |mutation| {
        var slots: [width]resource_bank.Slot = undefined;
        var bank: resource_bank.Bank = undefined;
        const epoch: u64 = 400 + @as(u64, @intFromEnum(mutation));
        const receipt = try admittedReceipt(&slots, &bank, epoch);
        var session: Session = .{};
        try session.init(&bank, receipt, epoch ^ 0xaa55);
        var state = try TestState.init();
        defer state.deinit();
        var sink: TestSink = .{};
        var wrong_sink: TestSink = .{};

        var first_stages = state.firstWave(0);
        var first = try Batch.begin(&session, &first_stages);
        try first.prepare(sink.interface());
        _ = try first.commit();

        var marks = [_]?kv.RowTxnMark{null} ** width;
        var stages: [width]LaneStage = undefined;
        try state.nextWave(&.{ 0, 1, 2, 3 }, &marks, 0, &stages);
        var prepared = try Batch.begin(&session, &stages);
        try prepared.prepare(sink.interface());
        var tampered = prepared;
        switch (mutation) {
            .token => tampered.stages[0].?.token_id ^= 1,
            .rng_after => tampered.stages[0].?.rng_after[0] ^= 1,
            .terminal => tampered.stages[0].?.terminal = true,
            .output_binding => tampered.stages[0].?.output = &state.outputs[1],
            .prepare_ack => tampered.ack.reservation_id += 1,
            .sink_binding => tampered.sink.?.context = &wrong_sink,
            .proposal => tampered.proposal.lanes[0].token_id ^= 1,
            .kv_mark => tampered.stages[0].?.kv_mark = marks[1],
        }
        try testing.expectError(error.InvalidState, tampered.commit());
        try testing.expectError(error.InvalidState, prepared.commit());
        try testing.expectEqual(@as(usize, 1), sink.abort_calls);
        try testing.expectEqual(@as(usize, 1), sink.commit_calls);
        try testing.expectEqual(@as(usize, 0), wrong_sink.abort_calls);
        try testing.expectEqual(@as(u64, 1), session.next_sequence);

        var retry_marks = [_]?kv.RowTxnMark{null} ** width;
        var retry_stages: [width]LaneStage = undefined;
        try state.nextWave(
            &.{ 0, 1, 2, 3 },
            &retry_marks,
            0,
            &retry_stages,
        );
        var retry = try Batch.begin(&session, &retry_stages);
        try retry.prepare(sink.interface());
        _ = try retry.commit();
        try testing.expectEqual(@as(usize, 2), sink.commit_calls);
        for (&state.caches) |*cache|
            try testing.expectEqual(@as(usize, 2), cache.len);

        try session.close();
        try bank.release(receipt);
    }
}

test "TokenTxn commit revalidates mutations made after sink prepare" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 206);
    var session: Session = .{};
    try session.init(&bank, receipt, 206 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var stages = state.firstWave(0);
    var batch = try Batch.begin(&session, &stages);
    try batch.prepare(sink.interface());
    state.lengths[2] = 1;
    try testing.expectError(error.InvalidState, batch.commit());
    try testing.expectEqual(@as(usize, 0), sink.commit_calls);
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    try testing.expectEqual(@as(u64, 0), session.next_sequence);
    try testing.expectEqual(SessionPhase.idle, session.phase);

    state.lengths[2] = 0;
    var retry_stages = state.firstWave(0);
    var retry = try Batch.begin(&session, &retry_stages);
    try retry.prepare(sink.interface());
    _ = try retry.commit();
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    try session.close();
    try bank.release(receipt);
}

test "TokenTxn enforces canonical complete live sets bindings and transitions" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 104);
    var session: Session = .{};
    try session.init(&bank, receipt, 104 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();

    var stages = state.firstWave(0);
    try testing.expectError(
        error.InvalidLaneSet,
        Batch.begin(&session, stages[0..3]),
    );
    std.mem.swap(LaneStage, &stages[0], &stages[1]);
    try testing.expectError(
        error.InvalidLaneSet,
        Batch.begin(&session, &stages),
    );
    std.mem.swap(LaneStage, &stages[0], &stages[1]);

    var aliased = stages;
    aliased[1].output = aliased[0].output;
    try testing.expectError(
        error.InvalidBinding,
        Batch.begin(&session, &aliased),
    );
    var skipped_call = stages;
    skipped_call[2].sampling_calls_after = 2;
    try testing.expectError(
        error.InvalidTransition,
        Batch.begin(&session, &skipped_call),
    );
    var hidden_rng = stages;
    hidden_rng[3].sampling_calls_after = 0;
    try testing.expectError(
        error.InvalidTransition,
        Batch.begin(&session, &hidden_rng),
    );
    try session.close();
    try bank.release(receipt);
}

test "TokenTxn retirement freezes lanes and shrinks only to the exact live set" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const bank_receipt = try admittedReceipt(&slots, &bank, 105);
    var session: Session = .{};
    try session.init(&bank, bank_receipt, 105 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var sink: TestSink = .{};

    var first_stages = state.firstWave(0b0001);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    _ = try first.commit();
    try testing.expectEqual(@as(u8, 0b1110), session.activeMask());

    var marks = [_]?kv.RowTxnMark{null} ** width;
    var next_stages: [3]LaneStage = undefined;
    try state.nextWave(&.{ 1, 2, 3 }, &marks, 0b0010, &next_stages);
    var with_retired: [4]LaneStage = undefined;
    with_retired[0] = first_stages[0];
    @memcpy(with_retired[1..], &next_stages);
    try testing.expectError(
        error.InvalidLaneSet,
        Batch.begin(&session, &with_retired),
    );

    var next = try Batch.begin(&session, &next_stages);
    try next.prepare(sink.interface());
    const receipt = try next.commit();
    try testing.expectEqual(@as(u8, 0b1110), receipt.proposal.live_mask);
    try testing.expectEqual(@as(u8, 3), receipt.proposal.live_lane_count);
    try testing.expectEqual(@as(usize, 1), state.lengths[0]);
    try testing.expectEqual(@as(usize, 1), state.caches[0].len);
    try testing.expectEqual(@as(usize, 1), state.sampling_calls[0]);
    try testing.expectEqual(@as(u8, 0b1100), session.activeMask());

    var third_marks = [_]?kv.RowTxnMark{null} ** width;
    var third_stages: [2]LaneStage = undefined;
    try state.nextWave(&.{ 2, 3 }, &third_marks, 0b0100, &third_stages);
    var third = try Batch.begin(&session, &third_stages);
    try third.prepare(sink.interface());
    const third_receipt = try third.commit();
    try testing.expectEqual(@as(u8, 0b1100), third_receipt.proposal.live_mask);
    try testing.expectEqual(@as(u8, 2), third_receipt.proposal.live_lane_count);
    try testing.expectEqual(@as(u8, 0b1000), session.activeMask());

    var fourth_marks = [_]?kv.RowTxnMark{null} ** width;
    var fourth_stages: [1]LaneStage = undefined;
    try state.nextWave(&.{3}, &fourth_marks, 0b1000, &fourth_stages);
    var fourth = try Batch.begin(&session, &fourth_stages);
    try fourth.prepare(sink.interface());
    const fourth_receipt = try fourth.commit();
    try testing.expectEqual(@as(u8, 0b1000), fourth_receipt.proposal.live_mask);
    try testing.expectEqual(@as(u8, 1), fourth_receipt.proposal.live_lane_count);
    try testing.expectEqual(@as(u8, 0), session.activeMask());
    try testing.expectEqual(@as(usize, 4), sink.commit_calls);
    try testing.expectError(
        error.InvalidLaneSet,
        Batch.begin(&session, &.{}),
    );
    try session.close();
    try bank.release(bank_receipt);
}

test "TokenTxn proposal and commit digests bind every lane and sink ack" {
    var slots: [width]resource_bank.Slot = undefined;
    var bank: resource_bank.Bank = undefined;
    const receipt = try admittedReceipt(&slots, &bank, 106);
    var session: Session = .{};
    try session.init(&bank, receipt, 106 ^ 0xaa55);
    var state = try TestState.init();
    defer state.deinit();
    var stages = state.firstWave(0);
    var batch = try Batch.begin(&session, &stages);

    const exact = proposalSha256(batch.proposal);
    try testing.expectEqual(exact, batch.proposal_sha256);
    var changed = batch.proposal;
    changed.lanes[2].token_id ^= 1;
    try testing.expect(!std.mem.eql(
        u8,
        &exact,
        &proposalSha256(changed),
    ));
    const ack: PrepareAckV1 = .{
        .proposal_sha256 = exact,
        .sink_epoch = 1,
        .reservation_id = 2,
    };
    var changed_ack = ack;
    changed_ack.reservation_id = 3;
    try testing.expect(!std.mem.eql(
        u8,
        &commitSha256(exact, ack),
        &commitSha256(exact, changed_ack),
    ));
    try batch.abort();
    try session.close();
    try bank.release(receipt);
}
