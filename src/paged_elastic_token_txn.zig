//! Aggregate-allocation paged token publication transaction (P2c v2).
//!
//! V2 keeps the immutable request receipt small: its KV charge is the four
//! page maps, while one generation-fenced child lease carries the payload of
//! pages that are actually allocated.  The logical capacity remains explicit
//! and is never confused with either allocator-backed charge. Every proposal
//! binds the exact parent, child generation, logical envelope, per-cache
//! capacity, and current allocation ledger before acquiring one atomic Bank
//! permit. Historical `resident_*` field names mean allocator commitment, not
//! sampled OS or device residency.
//!
//! This is a distinct ABI from PagedTokenTxn v1.  In particular, changing a
//! child lease can never reinterpret a v1 receipt or proposal.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const kv = @import("paged_kv_cache.zig");

pub const abi: u64 = 0x4750_4558_0000_0002;
pub const sink_abi: u64 = 0x4750_4553_0000_0002;
pub const prepare_ack_abi: u64 = 0x4750_4541_0000_0002;
pub const commit_receipt_abi: u64 = 0x4750_4543_0000_0002;
pub const page_transition_abi: u64 = 0x4750_4552_0000_0002;
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
    ResourceCapacityExceeded,
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

pub const RootTransitionV2 = struct {
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
    initial_logical_kv_sha256: Digest = [_]u8{0} ** 32,
    row_payload_sha256: Digest = [_]u8{0} ** 32,
    state_chain_before: Digest = [_]u8{0} ** 32,
    state_chain_after: Digest = [_]u8{0} ** 32,
};

pub const LaneProposalV2 = struct {
    lane_index: u32 = 0,
    step_index: u64 = 0,
    prompt_len: u64 = 0,
    kv_before: u64 = 0,
    kv_after: u64 = 0,
    logical_capacity_bytes: u64 = 0,
    page_map_bytes: u64 = 0,
    resident_payload_bytes: u64 = 0,
    resident_allocation_bytes: u64 = 0,
    allocated_pages: u64 = 0,
    committed_pages: u64 = 0,
    provisional_pages: u64 = 0,
    reusable_pages: u64 = 0,
    has_kv_transition: bool = false,
    kv_transition: RootTransitionV2 = .{},
    output_before: u64 = 0,
    output_after: u64 = 0,
    rng_before: RngState = [_]u64{0} ** 4,
    rng_after: RngState = [_]u64{0} ** 4,
    sampling_calls_before: u64 = 0,
    sampling_calls_after: u64 = 0,
    token_id: u32 = 0,
    terminal: bool = false,
};

pub const ProposalV2 = struct {
    abi_version: u64 = abi,
    resource_bank_abi: u64 = resource_bank.abi,
    resource_child_lease_abi: u64 = resource_bank.child_lease_abi,
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
    logical_kv_capacity_bytes: u64,
    page_map_bytes: u64,
    resident_payload_bytes: u64,
    resident_allocation_bytes: u64,
    parent_receipt: resource_bank.Receipt,
    child_lease: resource_bank.ChildLease,
    lanes: [width]LaneProposalV2 = [_]LaneProposalV2{.{}} ** width,
};

pub const PrepareAckV2 = struct {
    abi_version: u64 = prepare_ack_abi,
    proposal_sha256: Digest = [_]u8{0} ** 32,
    sink_epoch: u64 = 0,
    reservation_id: u64 = 0,
};

pub const CommitReceiptV2 = struct {
    abi_version: u64 = commit_receipt_abi,
    proposal: ProposalV2,
    proposal_sha256: Digest,
    prepare_ack: PrepareAckV2,
    commit_sha256: Digest,
};

/// Trusted in-process synchronous publication callbacks. Proposal/receipt
/// views are callback-lifetime evidence only: copying the embedded lease does
/// not transfer Bank authority, and callbacks must not spawn asynchronous Bank
/// mutations. A future hostile/out-of-process sink requires a capability-
/// isolated transport and atomic session+child teardown ABI.
pub const SinkV2 = struct {
    abi_version: u64 = sink_abi,
    context: *anyopaque,
    prepare: *const fn (
        context: *anyopaque,
        proposal: *const ProposalV2,
        ack: *PrepareAckV2,
    ) SinkPrepareError!void,
    commit: *const fn (
        context: *anyopaque,
        receipt: *const CommitReceiptV2,
    ) void,
    abort: *const fn (
        context: *anyopaque,
        proposal: *const ProposalV2,
        ack: *const PrepareAckV2,
    ) void,
};

fn sinkEql(left: SinkV2, right: SinkV2) bool {
    return left.abi_version == right.abi_version and
        left.context == right.context and
        left.prepare == right.prepare and
        left.commit == right.commit and
        left.abort == right.abort;
}

const BindingIdentity = struct {
    cache: *kv.PagedKVCache,
    cache_instance: u64,
    logical_capacity_bytes: usize,
    page_map_bytes: usize,
    page_payload_bytes: usize,
    rng_state: *RngState,
    sampling_calls: *usize,
    output_len: *usize,
    output_ptr: [*]u32,
    output_capacity: usize,

    fn fromStage(stage: LaneStage) BindingIdentity {
        const capacity = stage.cache.capacityLedger();
        return .{
            .cache = stage.cache,
            .cache_instance = stage.cache.instance_id,
            .logical_capacity_bytes = capacity.allocation_capacity_bytes,
            .page_map_bytes = capacity.page_map_bytes,
            .page_payload_bytes = capacity.page_payload_bytes,
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
            self.logical_capacity_bytes == other.logical_capacity_bytes and
            self.page_map_bytes == other.page_map_bytes and
            self.page_payload_bytes == other.page_payload_bytes and
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

pub const Session = struct {
    bank: *resource_bank.Bank = undefined,
    parent_receipt: resource_bank.Receipt = undefined,
    child_lease: resource_bank.ChildLease = undefined,
    request_epoch: u64 = 0,
    execution_abi: u64 = 0,
    logical_kv_capacity: u64 = 0,
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
    active_proposal: ?ProposalV2 = null,
    active_proposal_sha256: Digest = [_]u8{0} ** 32,
    active_stages: [width]?LaneStage = [_]?LaneStage{null} ** width,
    active_prepared_kv: [width]?kv.PreparedRowCommit =
        [_]?kv.PreparedRowCommit{null} ** width,
    active_ack: ?PrepareAckV2 = null,
    active_sink: ?SinkV2 = null,

    pub fn init(
        self: *Session,
        bank: *resource_bank.Bank,
        parent_receipt: resource_bank.Receipt,
        child_lease: resource_bank.ChildLease,
        request_epoch: u64,
        execution_abi: u64,
        logical_kv_capacity: u64,
    ) Error!void {
        if (self.initialized or request_epoch == 0 or execution_abi == 0 or
            logical_kv_capacity == 0 or
            parent_receipt.claim.queue_slots != width or
            child_lease.abi_version != resource_bank.child_lease_abi or
            !std.meta.eql(child_lease.parent, parent_receipt) or
            !onlyKv(child_lease.ceiling) or !onlyKv(child_lease.claim))
            return error.InvalidConfiguration;
        const envelope = std.math.add(
            u64,
            parent_receipt.claim.kv_bytes,
            child_lease.ceiling.kv_bytes,
        ) catch return error.InvalidConfiguration;
        if (envelope != logical_kv_capacity or
            child_lease.claim.kv_bytes > child_lease.ceiling.kv_bytes)
            return error.InvalidConfiguration;
        bank.bindPublicationSessionWithChild(
            child_lease,
            request_epoch,
            @intFromPtr(self),
        ) catch |err| switch (err) {
            error.StaleReservation => return error.ResourceReceiptInvalid,
            else => return error.InvalidState,
        };
        self.* = .{
            .bank = bank,
            .parent_receipt = parent_receipt,
            .child_lease = child_lease,
            .request_epoch = request_epoch,
            .execution_abi = execution_abi,
            .logical_kv_capacity = logical_kv_capacity,
            .initialized = true,
        };
    }

    /// Acquire additional allocator-backed payload before allocation is called.
    /// The exact sequence and coordinator address authorize the update; a
    /// copied/stale lease is never accepted and a live permit blocks growth.
    pub fn growResidentPayload(
        self: *Session,
        expected_sequence: u64,
        resident_payload_bytes: u64,
    ) Error!resource_bank.ChildLease {
        if (!self.initialized or self.phase != .idle or
            self.active_batch_generation != 0 or self.active_permit != null or
            expected_sequence != self.next_sequence or
            resident_payload_bytes < self.child_lease.claim.kv_bytes)
            return error.InvalidState;
        const grown = self.bank.growChildForSession(
            self.child_lease,
            self.request_epoch,
            @intFromPtr(self),
            expected_sequence,
            .{ .kv_bytes = resident_payload_bytes },
        ) catch |err| switch (err) {
            error.StaleReservation => return error.ResourceReceiptInvalid,
            error.CapacityExceeded, error.ClaimOverflow => return error.ResourceCapacityExceeded,
            error.InvalidClaim => return error.InvalidConfiguration,
            else => return error.InvalidState,
        };
        self.child_lease = grown;
        return grown;
    }

    /// Reduce allocator commitment after terminal/reusable payload has already
    /// been freed. Reclaim is legal only between publication waves at the
    /// Bank-owned next sequence. A failed shrink deliberately preserves the
    /// old overcharge and exact child handle.
    pub fn shrinkResidentPayloadAfterFree(
        self: *Session,
        expected_sequence: u64,
        resident_payload_bytes: u64,
    ) Error!resource_bank.ChildLease {
        if (!self.initialized or self.phase != .idle or
            self.active_batch_generation != 0 or self.active_permit != null or
            expected_sequence != self.next_sequence or
            resident_payload_bytes > self.child_lease.claim.kv_bytes)
            return error.InvalidState;
        const shrunk = self.bank.shrinkChildForSessionAfterFree(
            self.child_lease,
            self.request_epoch,
            @intFromPtr(self),
            expected_sequence,
            .{ .kv_bytes = resident_payload_bytes },
        ) catch |err| switch (err) {
            error.StaleReservation => return error.ResourceReceiptInvalid,
            error.InvalidClaim => return error.InvalidConfiguration,
            else => return error.InvalidState,
        };
        self.child_lease = shrunk;
        return shrunk;
    }

    /// Unbind after every allocator-backed object covered by `child_lease` has
    /// been freed. Keeping the fence bound through teardown prevents a sink
    /// that retained a copied handle from closing/uncharging the child early;
    /// only then may the caller close the child and release the parent.
    pub fn close(self: *Session) Error!void {
        if (!self.initialized or self.phase != .idle or
            self.active_batch_generation != 0 or self.active_permit != null)
            return error.InvalidState;
        self.bank.closePublicationSession(
            self.parent_receipt,
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

const BatchState = enum(u8) { active, prepared, committed, aborted };

const AggregateLedger = struct {
    logical_capacity_bytes: u64 = 0,
    page_map_bytes: u64 = 0,
    resident_payload_bytes: u64 = 0,
    resident_allocation_bytes: u64 = 0,
};

pub const Batch = struct {
    session: *Session,
    batch_generation: u64,
    state: BatchState = .active,
    stages: [width]?LaneStage = [_]?LaneStage{null} ** width,
    prepared_kv: [width]?kv.PreparedRowCommit =
        [_]?kv.PreparedRowCommit{null} ** width,
    proposal: ProposalV2,
    proposal_sha256: Digest,
    ack: PrepareAckV2 = .{},
    sink: ?SinkV2 = null,

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
        var lanes = [_]LaneProposalV2{.{}} ** width;
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

        const ledger = try aggregateLedgers(
            session,
            proposed_bindings,
            session.next_sequence == 0,
        );
        try validateEnvelope(session, ledger);

        const permit = session.bank.beginPublicationWithChild(
            session.child_lease,
            session.request_epoch,
            @intFromPtr(session),
            session.next_sequence,
        ) catch |err| switch (err) {
            error.StaleReservation => return error.ResourceReceiptInvalid,
            else => return error.InvalidState,
        };
        const batch_generation = session.next_batch_generation;
        const proposal: ProposalV2 = .{
            .request_epoch = session.request_epoch,
            .transaction_sequence = session.next_sequence,
            .resource_permit_generation = permit.generation,
            .execution_abi = session.execution_abi,
            .live_mask = live_mask,
            .live_lane_count = @intCast(live_stages.len),
            .logical_kv_capacity_bytes = ledger.logical_capacity_bytes,
            .page_map_bytes = ledger.page_map_bytes,
            .resident_payload_bytes = ledger.resident_payload_bytes,
            .resident_allocation_bytes = ledger.resident_allocation_bytes,
            .parent_receipt = session.parent_receipt,
            .child_lease = session.child_lease,
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

    pub fn prepare(self: *Batch, sink: SinkV2) Error!void {
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

        var ack: PrepareAckV2 = .{};
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

    pub fn commit(self: *Batch) Error!CommitReceiptV2 {
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

        for (0..width) |lane| {
            if (self.session.active_prepared_kv[lane]) |prepared_row|
                self.session.active_stages[lane].?.cache
                    .commitPreparedAssumeValid(prepared_row);
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

        const receipt: CommitReceiptV2 = .{
            .proposal = proposal,
            .proposal_sha256 = proposal_digest,
            .prepare_ack = ack,
            .commit_sha256 = commitSha256(proposal_digest, ack),
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
        maybe_sink: ?SinkV2,
        ack: PrepareAckV2,
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
        const ledger = try aggregateLedgers(
            self.session,
            self.session.bindings,
            false,
        );
        try validateEnvelope(self.session, ledger);
        if (proposal.abi_version != abi or
            proposal.resource_bank_abi != resource_bank.abi or
            proposal.resource_child_lease_abi !=
                resource_bank.child_lease_abi or
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
            proposal.logical_kv_capacity_bytes != ledger.logical_capacity_bytes or
            proposal.page_map_bytes != ledger.page_map_bytes or
            proposal.resident_payload_bytes != ledger.resident_payload_bytes or
            proposal.resident_allocation_bytes != ledger.resident_allocation_bytes or
            !std.meta.eql(proposal.parent_receipt, self.session.parent_receipt) or
            !std.meta.eql(proposal.child_lease, self.session.child_lease) or
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
            if (!std.meta.eql(self.ack, ack) or !sinkEql(local_sink, sink))
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
                    !std.meta.eql(proposal.lanes[lane], LaneProposalV2{}))
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

fn onlyKv(claim: resource_bank.Claim) bool {
    return claim.capsule_bytes == 0 and claim.activation_bytes == 0 and
        claim.partial_bytes == 0 and claim.logits_bytes == 0 and
        claim.output_journal_bytes == 0 and claim.staging_bytes == 0 and
        claim.device_bytes == 0 and claim.io_bytes == 0 and
        claim.queue_slots == 0;
}

fn addU64(total: *u64, value: usize) Error!void {
    const cast = std.math.cast(u64, value) orelse
        return error.InvalidConfiguration;
    total.* = std.math.add(u64, total.*, cast) catch
        return error.InvalidConfiguration;
}

fn aggregateLedgers(
    session: *const Session,
    bindings: [width]?BindingIdentity,
    require_first_complete: bool,
) Error!AggregateLedger {
    var aggregate: AggregateLedger = .{};
    for (session.bindings, bindings, 0..) |existing, proposed, lane| {
        const binding = proposed orelse {
            if (require_first_complete) return error.InvalidBinding;
            continue;
        };
        if (existing) |bound| {
            if (!bound.eql(binding)) return error.InvalidBinding;
        }
        for (bindings[0..lane]) |maybe_previous| {
            const previous = maybe_previous orelse continue;
            if (previous.cache_instance == binding.cache_instance)
                return error.InvalidBinding;
        }
        const capacity = binding.cache.capacityLedger();
        if (capacity.allocation_capacity_bytes !=
            binding.logical_capacity_bytes or
            capacity.page_map_bytes != binding.page_map_bytes or
            capacity.page_payload_bytes != binding.page_payload_bytes)
            return error.InvalidBinding;
        const resident = binding.cache.residentLedger() catch
            return error.KvTransactionInvalid;
        if (resident.page_map_bytes != binding.page_map_bytes or
            resident.resident_allocation_bytes !=
                resident.page_map_bytes + resident.resident_tensor_payload_bytes)
            return error.KvTransactionInvalid;
        try addU64(
            &aggregate.logical_capacity_bytes,
            capacity.allocation_capacity_bytes,
        );
        try addU64(&aggregate.page_map_bytes, resident.page_map_bytes);
        try addU64(
            &aggregate.resident_payload_bytes,
            resident.resident_tensor_payload_bytes,
        );
        try addU64(
            &aggregate.resident_allocation_bytes,
            resident.resident_allocation_bytes,
        );
    }
    return aggregate;
}

fn validateEnvelope(session: *const Session, ledger: AggregateLedger) Error!void {
    const child = session.child_lease;
    if (child.abi_version != resource_bank.child_lease_abi or
        !std.meta.eql(child.parent, session.parent_receipt) or
        !onlyKv(child.ceiling) or !onlyKv(child.claim) or
        ledger.logical_capacity_bytes != session.logical_kv_capacity or
        ledger.page_map_bytes != session.parent_receipt.claim.kv_bytes or
        ledger.resident_payload_bytes != child.claim.kv_bytes or
        ledger.resident_allocation_bytes !=
            ledger.page_map_bytes + ledger.resident_payload_bytes)
        return error.InvalidConfiguration;
    const envelope = std.math.add(
        u64,
        ledger.page_map_bytes,
        child.ceiling.kv_bytes,
    ) catch return error.InvalidConfiguration;
    if (envelope != session.logical_kv_capacity or
        child.claim.kv_bytes > child.ceiling.kv_bytes)
        return error.InvalidConfiguration;
}

const BuiltLane = struct {
    proposal: LaneProposalV2,
    prepared: ?kv.PreparedRowCommit,
};

fn hashRoot(hash: *std.crypto.hash.sha2.Sha256, root: kv.PageMapRootV1) void {
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
    hash.update("glacier-paged-elastic-token-kv-chain-seed-v2\x00");
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
    hash.update("glacier-paged-elastic-token-kv-chain-append-v2\x00");
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
) Error!RootTransitionV2 {
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
) Error!RootTransitionV2 {
    const mark = prepared.mark;
    const before = prepared.root_before;
    const after = prepared.root_after;
    if (prepared.abi_version != kv.row_txn_abi or
        mark.abi_version != kv.row_txn_abi or mark.row_count != 1 or
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

fn validateAndBuildLane(session: *Session, stage: LaneStage) Error!BuiltLane {
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
    var transition: RootTransitionV2 = .{};
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

    const capacity = stage.cache.capacityLedger();
    const resident = stage.cache.residentLedger() catch
        return error.KvTransactionInvalid;
    return .{
        .proposal = .{
            .lane_index = stage.lane_index,
            .step_index = @intCast(output_before),
            .prompt_len = @intCast(stage.prompt_len),
            .kv_before = @intCast(kv_before),
            .kv_after = @intCast(expected_kv_after),
            .logical_capacity_bytes = @intCast(
                capacity.allocation_capacity_bytes,
            ),
            .page_map_bytes = @intCast(resident.page_map_bytes),
            .resident_payload_bytes = @intCast(
                resident.resident_tensor_payload_bytes,
            ),
            .resident_allocation_bytes = @intCast(
                resident.resident_allocation_bytes,
            ),
            .allocated_pages = @intCast(resident.allocated_pages),
            .committed_pages = @intCast(resident.committed_pages),
            .provisional_pages = @intCast(resident.provisional_pages),
            .reusable_pages = @intCast(resident.reusable_pages),
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

const MutableRegion = struct { start: usize, bytes: usize };

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

fn hashChildLease(
    hash: *std.crypto.hash.sha2.Sha256,
    lease: resource_bank.ChildLease,
) void {
    hashU64(hash, lease.abi_version);
    hashReceipt(hash, lease.parent);
    hashU64(hash, lease.child_key);
    hashU64(hash, lease.generation);
    hashClaim(hash, lease.ceiling);
    hashClaim(hash, lease.claim);
    hashU64(hash, lease.integrity);
}

pub fn proposalSha256(proposal: ProposalV2) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-elastic-token-txn-proposal-v2\x00");
    hashU64(&hash, proposal.abi_version);
    hashU64(&hash, proposal.resource_bank_abi);
    hashU64(&hash, proposal.resource_child_lease_abi);
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
    hashU64(&hash, proposal.logical_kv_capacity_bytes);
    hashU64(&hash, proposal.page_map_bytes);
    hashU64(&hash, proposal.resident_payload_bytes);
    hashU64(&hash, proposal.resident_allocation_bytes);
    hashReceipt(&hash, proposal.parent_receipt);
    hashChildLease(&hash, proposal.child_lease);
    for (proposal.lanes) |lane| {
        hashU32(&hash, lane.lane_index);
        hashU64(&hash, lane.step_index);
        hashU64(&hash, lane.prompt_len);
        hashU64(&hash, lane.kv_before);
        hashU64(&hash, lane.kv_after);
        hashU64(&hash, lane.logical_capacity_bytes);
        hashU64(&hash, lane.page_map_bytes);
        hashU64(&hash, lane.resident_payload_bytes);
        hashU64(&hash, lane.resident_allocation_bytes);
        hashU64(&hash, lane.allocated_pages);
        hashU64(&hash, lane.committed_pages);
        hashU64(&hash, lane.provisional_pages);
        hashU64(&hash, lane.reusable_pages);
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

pub fn commitSha256(proposal_sha256: Digest, ack: PrepareAckV2) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-elastic-token-txn-commit-v2\x00");
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
const test_execution_abi: u64 = 0x5043_5445_5354_0002;

const TestSink = struct {
    reject: bool = false,
    corrupt_ack: bool = false,
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,
    receipts: [8]CommitReceiptV2 = undefined,

    fn interface(self: *TestSink) SinkV2 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const ProposalV2,
        ack: *PrepareAckV2,
    ) SinkPrepareError!void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.prepare_calls += 1;
        if (self.reject) return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = proposalSha256(proposal.*),
            .sink_epoch = 0x5043_5349,
            .reservation_id = self.prepare_calls,
        };
        if (self.corrupt_ack) ack.proposal_sha256[0] ^= 1;
    }

    fn commit(
        context: *anyopaque,
        receipt: *const CommitReceiptV2,
    ) void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        std.debug.assert(self.commit_calls < self.receipts.len);
        self.receipts[self.commit_calls] = receipt.*;
        self.commit_calls += 1;
    }

    fn abort(
        context: *anyopaque,
        _: *const ProposalV2,
        _: *const PrepareAckV2,
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

    fn planNextRows(
        self: *TestState,
    ) ![width]kv.RowAllocationPlanV1 {
        var plans: [width]kv.RowAllocationPlanV1 = undefined;
        for (&self.caches, 0..) |*cache, lane|
            plans[lane] = try cache.planNextRowAllocation();
        return plans;
    }

    fn nextWavePlanned(
        self: *TestState,
        plans: [width]kv.RowAllocationPlanV1,
        marks: *[width]?kv.RowTxnMark,
        terminal_mask: u8,
    ) ![width]LaneStage {
        var stages: [width]LaneStage = undefined;
        for (&stages, 0..) |*stage, lane| {
            const mark = try self.caches[lane].beginRowPlanned(plans[lane]);
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

const TestAdmission = struct {
    receipt: resource_bank.Receipt,
    child: resource_bank.ChildLease,
    logical_capacity: u64,
    page_maps: u64,
    resident_payload: u64,
};

fn stateLedger(state: *const TestState) !AggregateLedger {
    var result: AggregateLedger = .{};
    for (&state.caches) |*cache| {
        const capacity = cache.capacityLedger();
        const resident = try cache.residentLedger();
        try addU64(&result.logical_capacity_bytes, capacity.allocation_capacity_bytes);
        try addU64(&result.page_map_bytes, resident.page_map_bytes);
        try addU64(
            &result.resident_payload_bytes,
            resident.resident_tensor_payload_bytes,
        );
        try addU64(
            &result.resident_allocation_bytes,
            resident.resident_allocation_bytes,
        );
    }
    return result;
}

fn admitState(
    slots: *[width]resource_bank.Slot,
    child_slots: *[width]resource_bank.ChildSlot,
    bank: *resource_bank.Bank,
    state: *const TestState,
    epoch: u64,
    initial_payload_override: ?u64,
) !TestAdmission {
    const ledger = try stateLedger(state);
    bank.* = try resource_bank.Bank.initWithChildSlots(
        slots,
        child_slots,
        .{ .host_bytes = 8192, .kv_bytes = 8192, .queue_slots = width },
        epoch,
    );
    const receipt = try bank.commit(try bank.reserve(
        epoch ^ 0x55aa,
        .{ .kv_bytes = ledger.page_map_bytes, .queue_slots = width },
    ));
    const ceiling_payload = ledger.logical_capacity_bytes -
        ledger.page_map_bytes;
    const child = try bank.openChild(
        receipt,
        epoch ^ 0xaa55,
        .{ .kv_bytes = ceiling_payload },
        .{ .kv_bytes = initial_payload_override orelse
            ledger.resident_payload_bytes },
    );
    return .{
        .receipt = receipt,
        .child = child,
        .logical_capacity = ledger.logical_capacity_bytes,
        .page_maps = ledger.page_map_bytes,
        .resident_payload = ledger.resident_payload_bytes,
    };
}

test "PagedElasticTokenTxn commits allocator-backed ledger through child fence" {
    var state = try TestState.initWithCommittedRows(1);
    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank: resource_bank.Bank = undefined;
    const admission = try admitState(
        &slots,
        &child_slots,
        &bank,
        &state,
        801,
        null,
    );
    var session: Session = .{};
    try session.init(
        &bank,
        admission.receipt,
        admission.child,
        0x8010,
        test_execution_abi,
        admission.logical_capacity,
    );
    var sink: TestSink = .{};
    var stages = state.firstWave(0b1111);
    var batch = try Batch.begin(&session, &stages);
    try testing.expectEqual(
        admission.page_maps,
        batch.proposal.page_map_bytes,
    );
    try testing.expectEqual(
        admission.resident_payload,
        batch.proposal.resident_payload_bytes,
    );
    try testing.expectEqualDeep(admission.child, batch.proposal.child_lease);
    try testing.expectError(
        error.InvalidTransition,
        bank.growChildForSession(
            session.child_lease,
            session.request_epoch,
            @intFromPtr(&session),
            session.next_sequence,
            .{ .kv_bytes = session.child_lease.claim.kv_bytes + 1 },
        ),
    );
    try batch.prepare(sink.interface());
    const committed = try batch.commit();
    try testing.expectEqual(
        committed.commit_sha256,
        commitSha256(committed.proposal_sha256, committed.prepare_ack),
    );
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    state.deinit();
    try session.close();
    try bank.closeChild(session.child_lease);
    try bank.release(admission.receipt);
}

test "PagedElasticTokenTxn rejects stale child generation atomically" {
    var state = try TestState.initWithCommittedRows(1);
    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank: resource_bank.Bank = undefined;
    const admission = try admitState(
        &slots,
        &child_slots,
        &bank,
        &state,
        802,
        null,
    );
    var session: Session = .{};
    try session.init(
        &bank,
        admission.receipt,
        admission.child,
        0x8020,
        test_execution_abi,
        admission.logical_capacity,
    );
    const current = try bank.growChildForSession(
        admission.child,
        session.request_epoch,
        @intFromPtr(&session),
        0,
        .{ .kv_bytes = admission.resident_payload + 1 },
    );
    var stages = state.firstWave(0);
    try testing.expectError(
        error.ResourceReceiptInvalid,
        Batch.begin(&session, &stages),
    );
    try testing.expectEqual(@as(u64, 0), session.next_sequence);
    state.deinit();
    try session.close();
    try bank.closeChild(current);
    try bank.release(admission.receipt);
}

test "PagedElasticTokenTxn rejects one-byte resident under and overcharge" {
    inline for (.{ -1, 1 }) |delta| {
        var state = try TestState.initWithCommittedRows(1);
        const exact = (try stateLedger(&state)).resident_payload_bytes;
        const claimed: u64 = if (delta < 0) exact - 1 else exact + 1;
        var slots: [width]resource_bank.Slot = undefined;
        var child_slots: [width]resource_bank.ChildSlot = undefined;
        var bank: resource_bank.Bank = undefined;
        const admission = try admitState(
            &slots,
            &child_slots,
            &bank,
            &state,
            if (delta < 0) 803 else 804,
            claimed,
        );
        var session: Session = .{};
        try session.init(
            &bank,
            admission.receipt,
            admission.child,
            if (delta < 0) 0x8030 else 0x8040,
            test_execution_abi,
            admission.logical_capacity,
        );
        var stages = state.firstWave(0);
        try testing.expectError(
            error.InvalidConfiguration,
            Batch.begin(&session, &stages),
        );
        state.deinit();
        try session.close();
        try bank.closeChild(session.child_lease);
        try bank.release(admission.receipt);
    }
}

test "PagedElasticTokenTxn reports child budget rejection without mutation" {
    var state = try TestState.initWithCommittedRows(16);
    const ledger = try stateLedger(&state);
    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank = try resource_bank.Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{
            .host_bytes = ledger.resident_allocation_bytes,
            .kv_bytes = ledger.logical_capacity_bytes,
            .queue_slots = width,
        },
        806,
    );
    const receipt = try bank.commit(try bank.reserve(
        0x8061,
        .{ .kv_bytes = ledger.page_map_bytes, .queue_slots = width },
    ));
    const child = try bank.openChild(
        receipt,
        0x8062,
        .{ .kv_bytes = ledger.logical_capacity_bytes - ledger.page_map_bytes },
        .{ .kv_bytes = ledger.resident_payload_bytes },
    );
    var session: Session = .{};
    try session.init(
        &bank,
        receipt,
        child,
        0x8060,
        test_execution_abi,
        ledger.logical_capacity_bytes,
    );
    try testing.expectError(
        error.ResourceCapacityExceeded,
        session.growResidentPayload(
            0,
            child.claim.kv_bytes + state.caches[0].capacityLedger().page_payload_bytes,
        ),
    );
    try testing.expectEqualDeep(child, session.child_lease);
    try bank.validateChild(child);
    state.deinit();
    try session.close();
    try bank.closeChild(child);
    try bank.release(receipt);
}

test "PagedElasticTokenTxn shrinks freed payload only at exact session sequence" {
    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank = try resource_bank.Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{ .kv_bytes = 129, .queue_slots = width },
        0x8065,
    );
    const receipt = try bank.commit(try bank.reserve(
        0x8066,
        .{ .kv_bytes = 1, .queue_slots = width },
    ));
    const child = try bank.openChild(
        receipt,
        0x8067,
        .{ .kv_bytes = 128 },
        .{ .kv_bytes = 64 },
    );
    var session: Session = .{};
    try session.init(
        &bank,
        receipt,
        child,
        0x8068,
        test_execution_abi,
        129,
    );
    try testing.expectError(
        error.InvalidState,
        session.shrinkResidentPayloadAfterFree(1, 32),
    );
    try testing.expectEqualDeep(child, session.child_lease);
    const shrunk = try session.shrinkResidentPayloadAfterFree(0, 32);
    try testing.expectEqualDeep(shrunk, session.child_lease);
    try testing.expectEqual(@as(u64, 32), shrunk.claim.kv_bytes);
    try testing.expectError(
        error.StaleReservation,
        bank.validateChild(child),
    );
    try testing.expectError(
        error.InvalidState,
        session.shrinkResidentPayloadAfterFree(0, 64),
    );
    const snapshot = try bank.snapshotV2();
    try testing.expectEqual(@as(u64, 33), snapshot.used.kv_bytes);
    try testing.expectEqual(@as(u64, 1), snapshot.child_shrinks);
    try session.close();
    try bank.closeChild(shrunk);
    try bank.release(receipt);
    try testing.expect((try bank.snapshot()).used.isZero());
}

test "terminal lane frees payload before uncharge and opens KV byte headroom" {
    const capacity = try kv.deriveCapacityLedger(1, 2, 32);
    const page_bytes: u64 = @intCast(capacity.page_payload_bytes);
    const page_maps: u64 = @intCast(capacity.page_map_bytes * width);
    const payload_ceiling: u64 = @intCast(
        capacity.tensor_capacity_bytes * width,
    );
    const logical_capacity = std.math.add(
        u64,
        page_maps,
        payload_ceiling,
    ) catch unreachable;
    const initial_pages: u64 = 7;
    const bank_limit = page_maps + initial_pages * page_bytes;

    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank = try resource_bank.Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{ .host_bytes = bank_limit, .kv_bytes = bank_limit, .queue_slots = width },
        0x8069,
    );
    const parent = try bank.commit(try bank.reserve(
        0x806a,
        .{ .kv_bytes = page_maps, .queue_slots = width },
    ));
    const child = try bank.openChild(
        parent,
        0x806b,
        .{ .kv_bytes = payload_ceiling },
        .{},
    );
    var session: Session = .{};
    try session.init(
        &bank,
        parent,
        child,
        0x806c,
        test_execution_abi,
        logical_capacity,
    );

    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    var caches: [width]kv.PagedKVCache = undefined;
    var initialized: usize = 0;
    errdefer for (caches[0..initialized]) |*cache| cache.deinit();
    for (&caches) |*cache| {
        cache.* = try kv.PagedKVCache.init(
            tracking.allocator(),
            1,
            2,
            32,
        );
        initialized += 1;
    }

    const row_counts = [_]usize{ 1, 17, 17, 17 };
    for (&caches, row_counts, 0..) |*cache, row_count, lane| {
        for (0..row_count) |row| {
            const plan = try cache.planNextRowAllocation();
            if (plan.allocation_bytes != 0) {
                _ = try session.growResidentPayload(
                    0,
                    session.child_lease.claim.kv_bytes +
                        @as(u64, @intCast(plan.allocation_bytes)),
                );
            }
            const mark = try cache.beginRowPlanned(plan);
            const key = [_]f32{
                @floatFromInt(lane * 1000 + row * 10 + 1),
                @floatFromInt(lane * 1000 + row * 10 + 2),
            };
            const value = [_]f32{
                @floatFromInt(lane * 1000 + row * 10 + 3),
                @floatFromInt(lane * 1000 + row * 10 + 4),
            };
            _ = try cache.appendRowTxn(mark, 0, &key, &value);
            try cache.commitRowTxn(mark);
        }
    }
    try testing.expectEqual(
        initial_pages * page_bytes,
        session.child_lease.claim.kv_bytes,
    );

    var rng = [_]RngState{.{ 1, 2, 3, 4 }} ** width;
    var sampling_calls = [_]usize{0} ** width;
    var outputs = [_][2]u32{.{ 0, 0 }} ** width;
    var output_lengths = [_]usize{0} ** width;
    var first_wave: [width]LaneStage = undefined;
    for (&first_wave, 0..) |*stage, lane| {
        var rng_after = rng[lane];
        rng_after[0] += lane + 1;
        stage.* = .{
            .lane_index = @intCast(lane),
            .prompt_len = row_counts[lane],
            .cache = &caches[lane],
            .rng_state = &rng[lane],
            .rng_after = rng_after,
            .sampling_calls = &sampling_calls[lane],
            .sampling_calls_after = 1,
            .output = &outputs[lane],
            .output_len = &output_lengths[lane],
            .token_id = @intCast(100 + lane),
            .terminal = lane == 0,
        };
    }
    var sink: TestSink = .{};
    var first = try Batch.begin(&session, &first_wave);
    try first.prepare(sink.interface());
    const first_receipt = try first.commit();
    try testing.expectEqual(@as(u64, 1), session.next_sequence);

    try testing.expectError(
        error.CapacityExceeded,
        bank.reserve(0x806d, .{ .kv_bytes = page_bytes }),
    );
    const lane_zero_plan = try caches[0].planRetirementReclaim();
    const sealed_lane = first_receipt.proposal.lanes[0];
    try testing.expect(sealed_lane.terminal);
    try testing.expectEqual(
        lane_zero_plan.root.generation,
        sealed_lane.kv_transition.root_after_generation,
    );
    try testing.expectEqual(
        lane_zero_plan.root.committed_len,
        sealed_lane.kv_transition.root_after_len,
    );
    try testing.expectEqual(
        lane_zero_plan.root.committed_pages,
        sealed_lane.kv_transition.root_after_pages,
    );
    try testing.expectEqualSlices(
        u8,
        &lane_zero_plan.root.ownership_sha256,
        &sealed_lane.kv_transition.root_after_ownership_sha256,
    );
    try testing.expectEqual(page_bytes, lane_zero_plan.payload_bytes_to_free);
    const freed_before = tracking.freed_bytes;
    try testing.expectEqual(
        lane_zero_plan.payload_bytes_to_free,
        try caches[0].reclaimRetiredAfterCommit(lane_zero_plan),
    );
    try testing.expectEqual(
        lane_zero_plan.payload_bytes_to_free,
        tracking.freed_bytes - freed_before,
    );
    const used_while_still_charged = (try bank.snapshot()).used.kv_bytes;
    try testing.expectEqual(bank_limit, used_while_still_charged);
    _ = try session.shrinkResidentPayloadAfterFree(
        1,
        session.child_lease.claim.kv_bytes - page_bytes,
    );
    // This probe deliberately claims only the newly available KV-byte budget;
    // it is not a runnable decode request or a concurrency-density result.
    const byte_probe = try bank.commit(try bank.reserve(
        0x806d,
        .{ .kv_bytes = page_bytes },
    ));
    try testing.expectEqual(
        bank_limit,
        (try bank.snapshot()).used.kv_bytes,
    );
    try bank.release(byte_probe);

    var terminal_wave: [width - 1]LaneStage = undefined;
    var terminal_marks: [width - 1]kv.RowTxnMark = undefined;
    for (&terminal_wave, &terminal_marks, 1..) |*stage, *mark, lane| {
        const plan = try caches[lane].planNextRowAllocation();
        try testing.expectEqual(@as(usize, 0), plan.allocation_bytes);
        mark.* = try caches[lane].beginRowPlanned(plan);
        const key = [_]f32{
            @floatFromInt(lane * 1000 + 901),
            @floatFromInt(lane * 1000 + 902),
        };
        const value = [_]f32{
            @floatFromInt(lane * 1000 + 903),
            @floatFromInt(lane * 1000 + 904),
        };
        _ = try caches[lane].appendRowTxn(mark.*, 0, &key, &value);
        var rng_after = rng[lane];
        rng_after[1] += lane + 1;
        stage.* = .{
            .lane_index = @intCast(lane),
            .prompt_len = row_counts[lane],
            .cache = &caches[lane],
            .kv_mark = mark.*,
            .rng_state = &rng[lane],
            .rng_after = rng_after,
            .sampling_calls = &sampling_calls[lane],
            .sampling_calls_after = 2,
            .output = &outputs[lane],
            .output_len = &output_lengths[lane],
            .token_id = @intCast(200 + lane),
            .terminal = true,
        };
    }
    var terminal = try Batch.begin(&session, &terminal_wave);
    try terminal.prepare(sink.interface());
    _ = try terminal.commit();
    try testing.expectEqual(@as(u8, 0), session.activeMask());
    try testing.expectEqual(@as(u64, 2), session.next_sequence);

    for (caches[1..]) |*cache| {
        const plan = try cache.planRetirementReclaim();
        const before = tracking.freed_bytes;
        const freed = try cache.reclaimRetiredAfterCommit(plan);
        try testing.expectEqual(plan.payload_bytes_to_free, freed);
        try testing.expectEqual(freed, tracking.freed_bytes - before);
        _ = try session.shrinkResidentPayloadAfterFree(
            2,
            session.child_lease.claim.kv_bytes - @as(u64, @intCast(freed)),
        );
    }
    try testing.expect(session.child_lease.claim.isZero());
    const empty_child = session.child_lease;
    try session.close();
    try bank.closeChild(empty_child);
    for (&caches) |*cache| cache.deinit();
    initialized = 0;
    try bank.release(parent);
    const final = try bank.snapshotV2();
    try testing.expect(final.used.isZero());
    try testing.expectEqual(@as(u64, 4), final.child_shrinks);
    try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    try testing.expectEqual(tracking.allocations, tracking.deallocations);
}

test "PagedElasticTokenTxn maps aggregate claim overflow to capacity rejection" {
    var slots: [2]resource_bank.Slot = undefined;
    var child_slots: [2]resource_bank.ChildSlot = undefined;
    var bank = try resource_bank.Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{ .kv_bytes = std.math.maxInt(u64), .queue_slots = width },
        807,
    );
    const ballast = try bank.commit(try bank.reserve(
        0x8071,
        .{ .kv_bytes = std.math.maxInt(u64) - 2 },
    ));
    const receipt = try bank.commit(try bank.reserve(
        0x8072,
        .{ .kv_bytes = 1, .queue_slots = width },
    ));
    const child = try bank.openChild(
        receipt,
        0x8073,
        .{ .kv_bytes = 2 },
        .{},
    );
    var session: Session = .{};
    try session.init(
        &bank,
        receipt,
        child,
        0x8070,
        test_execution_abi,
        3,
    );
    const before = try bank.snapshotV2();
    try testing.expectError(
        error.ResourceCapacityExceeded,
        session.growResidentPayload(0, 2),
    );
    try bank.validateChild(child);
    const after = try bank.snapshotV2();
    try testing.expectEqualDeep(before.used, after.used);
    try testing.expectEqual(@as(u64, 1), after.rejected_child_capacity);
    try session.close();
    try bank.closeChild(child);
    try bank.release(receipt);
    try bank.release(ballast);
    try testing.expect((try bank.snapshot()).used.isZero());
}

test "PagedElasticTokenTxn boundary reject retains charge and retries" {
    var state = try TestState.initWithCommittedRows(16);
    var slots: [width]resource_bank.Slot = undefined;
    var child_slots: [width]resource_bank.ChildSlot = undefined;
    var bank: resource_bank.Bank = undefined;
    const admission = try admitState(
        &slots,
        &child_slots,
        &bank,
        &state,
        805,
        null,
    );
    var session: Session = .{};
    try session.init(
        &bank,
        admission.receipt,
        admission.child,
        0x8050,
        test_execution_abi,
        admission.logical_capacity,
    );
    var sink: TestSink = .{};
    var first_stages = state.firstWave(0);
    var first = try Batch.begin(&session, &first_stages);
    try first.prepare(sink.interface());
    _ = try first.commit();

    const plans = try state.planNextRows();
    var additional: u64 = 0;
    for (plans) |plan| try addU64(&additional, plan.allocation_bytes);
    try testing.expect(additional > 0);
    _ = try session.growResidentPayload(
        session.next_sequence,
        session.child_lease.claim.kv_bytes + additional,
    );
    var roots_before: [width]kv.PageMapRootV1 = undefined;
    for (&state.caches, 0..) |*cache, lane|
        roots_before[lane] = cache.root();
    const rng_before = state.rng;
    const outputs_before = state.outputs;
    const lengths_before = state.lengths;
    var rejected_marks = [_]?kv.RowTxnMark{null} ** width;
    var rejected_stages = try state.nextWavePlanned(
        plans,
        &rejected_marks,
        0,
    );
    sink.reject = true;
    var rejected = try Batch.begin(&session, &rejected_stages);
    try testing.expectError(
        error.SinkRejected,
        rejected.prepare(sink.interface()),
    );
    const charged_after_reject = session.child_lease.claim.kv_bytes;
    try testing.expectEqualDeep(rng_before, state.rng);
    try testing.expectEqualDeep(outputs_before, state.outputs);
    try testing.expectEqualDeep(lengths_before, state.lengths);
    for (&state.caches, 0..) |*cache, lane| {
        try testing.expectEqualDeep(roots_before[lane], cache.root());
        const resident = try cache.residentLedger();
        try testing.expectEqual(@as(usize, 1), resident.reusable_pages);
        try testing.expectEqual(@as(usize, 2), resident.allocated_pages);
    }

    sink.reject = false;
    const retry_plans = try state.planNextRows();
    for (retry_plans) |plan|
        try testing.expectEqual(@as(usize, 0), plan.allocation_bytes);
    var retry_marks = [_]?kv.RowTxnMark{null} ** width;
    var retry_stages = try state.nextWavePlanned(
        retry_plans,
        &retry_marks,
        0b1111,
    );
    var retry = try Batch.begin(&session, &retry_stages);
    try testing.expectEqual(
        charged_after_reject,
        retry.proposal.resident_payload_bytes,
    );
    try retry.prepare(sink.interface());
    _ = try retry.commit();
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    state.deinit();
    try session.close();
    try bank.closeChild(session.child_lease);
    try bank.release(admission.receipt);
}
