//! Whole-B4 LeaseTree-backed token publication transaction (P2c v3).
//!
//! One Bank publication permit fences every live lane in a decode wave.  The
//! proposal commits the binding summary and exact allocation set of all four
//! registered scopes,
//! including terminal lanes whose pages remain charged until later reclaim.
//! KV roots, RNG, sampler counters, output and terminal evidence become
//! visible as one synchronous sink transaction.

const std = @import("std");
const core = @import("core");
const resource_bank = core.resource_bank;
const kv = @import("paged_kv_cache.zig");
const leased = @import("leased_paged_kv_cache.zig");

pub const abi: u64 = 0x4750_4c58_0000_0004;
pub const sink_abi: u64 = 0x4750_4c53_0000_0004;
pub const prepare_ack_abi: u64 = 0x4750_4c41_0000_0003;
pub const commit_receipt_abi: u64 = 0x4750_4c43_0000_0004;
pub const page_transition_abi: u64 = 0x4750_4c52_0000_0003;
pub const resource_commitment_abi: u64 = 0x4750_4c43_0000_0005;
pub const tree_commitment_abi: u64 = 0x4750_4c54_0000_0003;
pub const width: usize = 4;
pub const RngState = [4]u64;
pub const Digest = [32]u8;

const zero_digest: Digest = [_]u8{0} ** 32;
const zero_root: kv.PageMapRootV1 = .{
    .cache_instance = 0,
    .generation = 0,
    .committed_len = 0,
    .committed_pages = 0,
    .ownership_sha256 = zero_digest,
};
const empty_allocation_set: leased.AllocationSetCommitmentV2 = .{
    .count = 0,
    .payload_bytes = 0,
    .sha256 = zero_digest,
};
const empty_binding_summary: leased.BindingSummaryV1 = .{
    .count = 0,
    .payload_bytes = 0,
    .digest = zero_digest,
};

pub const Error = error{
    InvalidConfiguration,
    InvalidState,
    InvalidLaneSet,
    InvalidBinding,
    InvalidTransition,
    SequenceExhausted,
    ResourceReceiptInvalid,
    ResourceCommitmentInvalid,
    KvTransactionInvalid,
    SinkRejected,
    InvalidPrepareAck,
    TerminalEvidenceInvalid,
    ReclaimInvalid,
};

pub const SinkPrepareError = error{
    Unavailable,
    InvalidEvidence,
    CapacityExceeded,
};

pub const LaneStage = struct {
    lane_index: u32,
    prompt_len: usize,
    coordinator: *leased.LeasedPagedKVCache,
    leased_row_txn: ?leased.LeasedRowTxnV1 = null,
    rng_state: *RngState,
    rng_after: RngState,
    sampling_calls: *usize,
    sampling_calls_after: usize,
    output: []u32,
    output_len: *usize,
    token_id: u32,
    terminal_reason: ?leased.TerminalReason = null,
};

pub const RootTransitionV3 = struct {
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
    root_before_ownership_sha256: Digest = zero_digest,
    root_after_ownership_sha256: Digest = zero_digest,
    logical_page: u64 = 0,
    page_ownership_generation: u64 = 0,
    installs_new_page: bool = false,
    initial_logical_kv_sha256: Digest = zero_digest,
    row_payload_sha256: Digest = zero_digest,
    state_chain_before: Digest = zero_digest,
    state_chain_after: Digest = zero_digest,
};

pub const LaneProposalV3 = struct {
    lane_index: u32 = 0,
    step_index: u64 = 0,
    prompt_len: u64 = 0,
    kv_before: u64 = 0,
    kv_after: u64 = 0,
    has_kv_transition: bool = false,
    kv_transition: RootTransitionV3 = .{},
    output_before: u64 = 0,
    output_after: u64 = 0,
    output_sha256: Digest = zero_digest,
    rng_before: RngState = [_]u64{0} ** 4,
    rng_after: RngState = [_]u64{0} ** 4,
    sampling_calls_before: u64 = 0,
    sampling_calls_after: u64 = 0,
    token_id: u32 = 0,
    terminal_reason: ?leased.TerminalReason = null,
};

/// Redacted projection: the tree authority key is intentionally excluded.
pub const LeaseTreeCommitmentV3 = struct {
    abi_version: u64 = tree_commitment_abi,
    tree_key: u64 = 0,
    identity_generation: u64 = 0,
    generation: u64 = 0,
    structural_revision: u64 = 0,
    ceiling: resource_bank.Claim = .{},
    current: resource_bank.Claim = .{},
    active_nodes: u32 = 0,
    state_digest: u64 = 0,
    token_integrity: u64 = 0,
};

pub const ResourceCommitmentV3 = struct {
    abi_version: u64 = resource_commitment_abi,
    lane_index: u32 = 0,
    lifecycle: leased.LeaseLifecycle = .reclaimed,
    coordinator_instance: u64 = 0,
    cache_instance: u64 = 0,
    scope_index: u32 = 0,
    scope_generation: u64 = 0,
    root: kv.PageMapRootV1 = zero_root,
    kv_state_chain_after: Digest = zero_digest,
    has_canonical_after: bool = false,
    canonical_after_sha256: Digest = zero_digest,
    /// Exact `TerminalPlanV3.generation` for a lane retiring in this wave.
    /// The explicit field avoids inferring coordinator authority from a root
    /// generation or output position.
    has_terminal_generation: bool = false,
    terminal_generation: u64 = 0,
    /// Local seal/reclaim cross-link. `allocation_set` remains the stronger
    /// transport-facing commitment to raw binding, node, receipt and Claim.
    has_binding_summary: bool = false,
    binding_summary: leased.BindingSummaryV1 = empty_binding_summary,
    allocation_set: leased.AllocationSetCommitmentV2 = empty_allocation_set,
};

pub const ProposalV3 = struct {
    abi_version: u64 = abi,
    resource_bank_abi: u64 = resource_bank.abi,
    resource_lease_tree_abi: u64 = resource_bank.lease_tree_abi,
    resource_publication_fence_abi: u64 =
        resource_bank.publication_fence_abi,
    leased_paged_kv_abi: u64 = leased.abi,
    paged_kv_abi: u64 = kv.abi,
    page_transition_abi: u64 = page_transition_abi,
    execution_abi: u64,
    request_epoch: u64,
    transaction_sequence: u64,
    resource_permit_generation: u64,
    live_mask: u8,
    live_lane_count: u8,
    parent_receipt: resource_bank.Receipt,
    tree: LeaseTreeCommitmentV3,
    resources: [width]ResourceCommitmentV3 =
        [_]ResourceCommitmentV3{.{}} ** width,
    lanes: [width]LaneProposalV3 = [_]LaneProposalV3{.{}} ** width,
};

pub const PrepareAckV3 = struct {
    abi_version: u64 = prepare_ack_abi,
    proposal_sha256: Digest = zero_digest,
    sink_epoch: u64 = 0,
    reservation_id: u64 = 0,
};

pub const CommitReceiptV3 = struct {
    abi_version: u64 = commit_receipt_abi,
    proposal: ProposalV3,
    proposal_sha256: Digest,
    prepare_ack: PrepareAckV3,
    commit_sha256: Digest,
    terminal_seals: [width]?leased.TerminalSealV3 =
        [_]?leased.TerminalSealV3{null} ** width,
};

/// Trusted, synchronous in-process sink. A successful prepare reserves an
/// infallible/non-allocating commit; it must expose no proposal side effects.
pub const SinkV3 = struct {
    abi_version: u64 = sink_abi,
    context: *anyopaque,
    prepare: *const fn (
        context: *anyopaque,
        proposal: *const ProposalV3,
        ack: *PrepareAckV3,
    ) SinkPrepareError!void,
    commit: *const fn (
        context: *anyopaque,
        receipt: *const CommitReceiptV3,
    ) void,
    abort: *const fn (
        context: *anyopaque,
        proposal: *const ProposalV3,
        ack: *const PrepareAckV3,
    ) void,
};

fn sinkEql(left: SinkV3, right: SinkV3) bool {
    return left.abi_version == right.abi_version and
        left.context == right.context and left.prepare == right.prepare and
        left.commit == right.commit and left.abort == right.abort;
}

const CohortIdentity = struct {
    coordinator_instance: u64,
    cache_instance: u64,
    scope: resource_bank.LeaseNodeV1,
};

const BindingIdentity = struct {
    coordinator: *leased.LeasedPagedKVCache,
    coordinator_instance: u64,
    cache_instance: u64,
    rng_state: *RngState,
    sampling_calls: *usize,
    output_len: *usize,
    output_ptr: [*]u32,
    output_capacity: usize,

    fn fromStage(stage: LaneStage) Error!BindingIdentity {
        const coordinator_instance = stage.coordinator.coordinatorInstance() catch return error.InvalidBinding;
        const cache_instance = stage.coordinator.cacheInstance() catch return error.InvalidBinding;
        return .{
            .coordinator = stage.coordinator,
            .coordinator_instance = coordinator_instance,
            .cache_instance = cache_instance,
            .rng_state = stage.rng_state,
            .sampling_calls = stage.sampling_calls,
            .output_len = stage.output_len,
            .output_ptr = stage.output.ptr,
            .output_capacity = stage.output.len,
        };
    }

    fn eql(self: BindingIdentity, other: BindingIdentity) bool {
        return self.coordinator == other.coordinator and
            self.coordinator_instance == other.coordinator_instance and
            self.cache_instance == other.cache_instance and
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
        left.coordinator == right.coordinator and
        std.meta.eql(left.leased_row_txn, right.leased_row_txn) and
        left.rng_state == right.rng_state and
        std.mem.eql(u64, &left.rng_after, &right.rng_after) and
        left.sampling_calls == right.sampling_calls and
        left.sampling_calls_after == right.sampling_calls_after and
        left.output.ptr == right.output.ptr and
        left.output.len == right.output.len and
        left.output_len == right.output_len and
        left.token_id == right.token_id and
        left.terminal_reason == right.terminal_reason;
}

const SessionPhase = enum(u8) {
    idle,
    active,
    preparing,
    prepared,
    committing,
    aborting,
    closed,
};

pub const Session = struct {
    // Public so coordinators can be initialized in-place before `init` with
    // this exact address and sequence pointer.
    next_sequence: u64 = 0,

    initialized: bool = false,
    self_address: usize = 0,
    bank: *resource_bank.Bank = undefined,
    parent_receipt: resource_bank.Receipt = undefined,
    tree: *resource_bank.LeaseTreeV1 = undefined,
    coordinators: [width]*leased.LeasedPagedKVCache = undefined,
    cohort: [width]CohortIdentity = undefined,
    request_epoch: u64 = 0,
    execution_abi: u64 = 0,
    next_steps: [width]u64 = [_]u64{0} ** width,
    retired: [width]bool = [_]bool{false} ** width,
    reclaimed: [width]bool = [_]bool{false} ** width,
    kv_state_chains: [width]Digest = [_]Digest{zero_digest} ** width,
    chain_initialized: [width]bool = [_]bool{false} ** width,
    bindings: [width]?BindingIdentity = [_]?BindingIdentity{null} ** width,
    terminal_seals: [width]?leased.TerminalSealV3 =
        [_]?leased.TerminalSealV3{null} ** width,
    phase: SessionPhase = .idle,
    next_batch_generation: u64 = 1,
    active_batch_generation: u64 = 0,
    active_permit: ?resource_bank.PublicationPermit = null,
    active_proposal: ?ProposalV3 = null,
    active_proposal_sha256: Digest = zero_digest,
    active_stages: [width]?LaneStage = [_]?LaneStage{null} ** width,
    active_prepared: [width]?leased.PreparedTokenRowV1 =
        [_]?leased.PreparedTokenRowV1{null} ** width,
    active_terminal_plans: [width]?leased.TerminalPlanV3 =
        [_]?leased.TerminalPlanV3{null} ** width,
    active_ack: ?PrepareAckV3 = null,
    active_sink: ?SinkV3 = null,

    pub fn init(
        self: *Session,
        bank: *resource_bank.Bank,
        parent_receipt: resource_bank.Receipt,
        shared_tree: *resource_bank.LeaseTreeV1,
        coordinators: [width]*leased.LeasedPagedKVCache,
        request_epoch: u64,
        execution_abi: u64,
    ) Error!void {
        if (self.initialized or self.self_address != 0 or
            self.next_sequence != 0 or request_epoch == 0 or
            execution_abi == 0 or parent_receipt.claim.queue_slots != width or
            !std.meta.eql(shared_tree.parent, parent_receipt))
            return error.InvalidConfiguration;
        bank.validateLeaseTree(shared_tree.*) catch
            return error.ResourceReceiptInvalid;

        const session_id = @intFromPtr(self);
        var cohort: [width]CohortIdentity = undefined;
        for (coordinators, 0..) |coordinator, lane| {
            coordinator.validateCohortBinding(
                bank,
                shared_tree,
                request_epoch,
                session_id,
                &self.next_sequence,
            ) catch return error.InvalidConfiguration;
            const coordinator_instance = coordinator.coordinatorInstance() catch return error.InvalidConfiguration;
            const cache_instance = coordinator.cacheInstance() catch return error.InvalidConfiguration;
            const scope = coordinator.scopeToken() catch return error.InvalidConfiguration;
            if (coordinator_instance == 0 or cache_instance == 0 or
                scope.kind != .scope or
                !std.meta.eql(scope.parent, parent_receipt))
                return error.InvalidConfiguration;
            for (cohort[0..lane]) |previous| {
                if (previous.coordinator_instance == coordinator_instance or
                    previous.cache_instance == cache_instance or
                    previous.scope.node_index == scope.node_index)
                    return error.InvalidConfiguration;
            }
            for (coordinators[0..lane]) |previous| {
                if (previous == coordinator) return error.InvalidConfiguration;
            }
            cohort[lane] = .{
                .coordinator_instance = coordinator_instance,
                .cache_instance = cache_instance,
                .scope = scope,
            };
        }

        bank.bindPublicationSessionWithTree(
            shared_tree.*,
            request_epoch,
            session_id,
        ) catch return error.ResourceReceiptInvalid;
        self.* = .{
            .next_sequence = 0,
            .initialized = true,
            .self_address = session_id,
            .bank = bank,
            .parent_receipt = parent_receipt,
            .tree = shared_tree,
            .coordinators = coordinators,
            .cohort = cohort,
            .request_epoch = request_epoch,
            .execution_abi = execution_abi,
        };
    }

    pub fn activeMask(self: *const Session) u8 {
        if (!self.initialized or self.self_address != @intFromPtr(self) or
            self.phase == .closed)
            return 0;
        var mask: u8 = 0;
        for (self.retired, 0..) |is_retired, lane| {
            if (!is_retired) mask |= @as(u8, 1) << @intCast(lane);
        }
        return mask;
    }

    pub fn beginLaneReclaim(
        self: *Session,
        lane: usize,
        seal: leased.TerminalSealV3,
    ) Error!leased.FreedPayloadV1 {
        try self.validateIdle();
        if (lane >= width or !self.retired[lane] or self.reclaimed[lane])
            return error.ReclaimInvalid;
        const expected = self.terminal_seals[lane] orelse
            return error.ReclaimInvalid;
        if (!std.meta.eql(expected, seal)) return error.ReclaimInvalid;
        return self.coordinators[lane].beginTerminalReclaimV3(
            seal,
            self.next_sequence,
        ) catch error.ReclaimInvalid;
    }

    pub fn commitLaneReclaimAfterFree(
        self: *Session,
        lane: usize,
        freed: leased.FreedPayloadV1,
    ) Error!leased.ReclaimReceiptV1 {
        try self.validateIdle();
        if (lane >= width or !self.retired[lane] or self.reclaimed[lane])
            return error.ReclaimInvalid;
        const receipt = self.coordinators[lane].commitReclaimAfterFree(freed) catch return error.ReclaimInvalid;
        self.reclaimed[lane] = true;
        return receipt;
    }

    /// Synchronous idle-only failure path for prompt/decode/sink errors before
    /// a terminal publication exists. The coordinator retires the exact scope,
    /// frees payload and completes Bank uncharge before this lane is marked.
    pub fn reclaimLaneForTeardown(self: *Session, lane: usize) Error!void {
        try self.validateIdle();
        if (lane >= width) return error.ReclaimInvalid;
        if (self.reclaimed[lane]) return;
        self.coordinators[lane].reclaimForTeardown(self.next_sequence) catch
            return error.ReclaimInvalid;
        self.retired[lane] = true;
        self.reclaimed[lane] = true;
    }

    pub fn reclaimAllForTeardown(self: *Session) Error!void {
        try self.validateIdle();
        for (0..width) |lane| try self.reclaimLaneForTeardown(lane);
    }

    pub fn close(self: *Session) Error!void {
        try self.validateIdle();
        for (0..width) |lane| {
            if (!self.retired[lane] or !self.reclaimed[lane])
                return error.InvalidState;
            const lifecycle = self.coordinators[lane].lifecycle() catch return error.ReclaimInvalid;
            if (lifecycle != .reclaimed) return error.ReclaimInvalid;
        }
        if (!self.tree.current.isZero()) return error.ResourceCommitmentInvalid;
        self.bank.closePublicationSession(
            self.parent_receipt,
            self.request_epoch,
            @intFromPtr(self),
            self.next_sequence,
        ) catch return error.ResourceReceiptInvalid;
        self.phase = .closed;
        self.initialized = false;
    }

    fn validateIdle(self: *Session) Error!void {
        if (!self.initialized or self.self_address == 0 or
            self.self_address != @intFromPtr(self) or self.phase != .idle or
            self.active_batch_generation != 0 or self.active_permit != null)
            return error.InvalidState;
    }

    fn validateLive(self: *Session) Error!void {
        if (!self.initialized or self.self_address == 0 or
            self.self_address != @intFromPtr(self) or self.phase == .closed)
            return error.InvalidState;
    }
};

const BuiltLane = struct {
    proposal: LaneProposalV3,
    prepared: leased.PreparedTokenRowV1,
};

const ResourceSnapshot = struct {
    tree: resource_bank.LeaseTreeV1,
    commitment: LeaseTreeCommitmentV3,
    resources: [width]ResourceCommitmentV3,
};

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
    hash.update("glacier-paged-lease-token-kv-chain-seed-v3\x00");
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
    hash.update("glacier-paged-lease-token-kv-chain-append-v3\x00");
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

fn outputAfterSha256(stage: LaneStage) Error!Digest {
    const output_before = stage.output_len.*;
    if (output_before >= stage.output.len) return error.InvalidTransition;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-output-token-state-v1\x00");
    hashU64(&hash, @intCast(output_before + 1));
    for (stage.output[0..output_before]) |token| hashU32(&hash, token);
    hashU32(&hash, stage.token_id);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn initialRootTransition(
    prepared: leased.PreparedTokenRowV1,
) Error!RootTransitionV3 {
    const root = prepared.root_after;
    if (prepared.txn != null or prepared.prepared_row != null or
        !std.meta.eql(prepared.root_before, root) or
        root.abi_version != kv.page_map_root_abi or root.cache_instance == 0 or
        !prepared.has_canonical_after)
        return error.KvTransactionInvalid;
    const chain = initialStateChain(prepared.canonical_after_sha256, root);
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
        .initial_logical_kv_sha256 = prepared.canonical_after_sha256,
        .state_chain_before = chain,
        .state_chain_after = chain,
    };
}

fn rootTransition(
    prepared_token: leased.PreparedTokenRowV1,
    chain_before: Digest,
) Error!RootTransitionV3 {
    const prepared = prepared_token.prepared_row orelse
        return error.KvTransactionInvalid;
    const txn = prepared_token.txn orelse return error.KvTransactionInvalid;
    const mark = prepared.mark;
    const before = prepared.root_before;
    const after = prepared.root_after;
    if (!std.meta.eql(mark, txn.mark) or prepared.abi_version != kv.row_txn_abi or
        mark.abi_version != kv.row_txn_abi or mark.row_count != 1 or
        before.abi_version != kv.page_map_root_abi or
        after.abi_version != kv.page_map_root_abi or
        mark.page_ref.abi_version != kv.page_ref_abi or
        mark.cache_instance == 0 or mark.cache_instance != before.cache_instance or
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
            std.mem.eql(u8, &before.ownership_sha256, &after.ownership_sha256)) or
        (!prepared.installs_new_page and
            !std.mem.eql(u8, &before.ownership_sha256, &after.ownership_sha256)))
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
        .row_payload_sha256 = prepared_token.row_payload_sha256,
        .state_chain_before = chain_before,
        .state_chain_after = appendedStateChain(
            chain_before,
            prepared,
            prepared_token.row_payload_sha256,
        ),
    };
}

fn validateAndBuildLane(session: *Session, stage: LaneStage) Error!BuiltLane {
    const lane: usize = stage.lane_index;
    if (lane >= width or stage.prompt_len == 0 or stage.output.len == 0 or
        stage.coordinator != session.coordinators[lane])
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
    const require_canonical = output_before == 0 or
        stage.terminal_reason != null;
    const prepared = stage.coordinator.prepareTokenRow(
        stage.leased_row_txn,
        require_canonical,
    ) catch return error.KvTransactionInvalid;

    var transition: RootTransitionV3 = undefined;
    var kv_before = expected_kv_after;
    if (output_before == 0) {
        if (stage.leased_row_txn != null or session.chain_initialized[lane])
            return error.InvalidTransition;
        transition = try initialRootTransition(prepared);
        if (transition.root_after_len != expected_kv_after)
            return error.InvalidTransition;
    } else {
        if (stage.leased_row_txn == null or !session.chain_initialized[lane])
            return error.InvalidTransition;
        transition = try rootTransition(
            prepared,
            session.kv_state_chains[lane],
        );
        const raw = prepared.prepared_row orelse
            return error.KvTransactionInvalid;
        if (transition.root_after_len != expected_kv_after or
            transition.root_before_len + 1 != expected_kv_after)
            return error.InvalidTransition;
        kv_before = raw.mark.base_len;
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
            .has_kv_transition = stage.leased_row_txn != null,
            .kv_transition = transition,
            .output_before = @intCast(output_before),
            .output_after = @intCast(output_after),
            .output_sha256 = try outputAfterSha256(stage),
            .rng_before = stage.rng_state.*,
            .rng_after = stage.rng_after,
            .sampling_calls_before = @intCast(calls_before),
            .sampling_calls_after = @intCast(stage.sampling_calls_after),
            .token_id = stage.token_id,
            .terminal_reason = stage.terminal_reason,
        },
        .prepared = prepared,
    };
}

fn claimOnlyKv(claim: resource_bank.Claim) bool {
    return claim.capsule_bytes == 0 and claim.activation_bytes == 0 and
        claim.partial_bytes == 0 and claim.logits_bytes == 0 and
        claim.output_journal_bytes == 0 and claim.staging_bytes == 0 and
        claim.device_bytes == 0 and claim.io_bytes == 0 and
        claim.queue_slots == 0;
}

fn treeCommitment(tree: resource_bank.LeaseTreeV1) LeaseTreeCommitmentV3 {
    return .{
        .tree_key = tree.tree_key,
        .identity_generation = tree.identity_generation,
        .generation = tree.generation,
        .structural_revision = tree.structural_revision,
        .ceiling = tree.ceiling,
        .current = tree.current,
        .active_nodes = tree.active_nodes,
        .state_digest = tree.state_digest,
        .token_integrity = tree.integrity,
    };
}

fn collectResourceSnapshot(
    session: *Session,
    prepared: [width]?leased.PreparedTokenRowV1,
    lanes: [width]LaneProposalV3,
) Error!ResourceSnapshot {
    const tree = session.tree.*;
    session.bank.validateLeaseTree(tree) catch
        return error.ResourceCommitmentInvalid;
    if (!std.meta.eql(tree.parent, session.parent_receipt) or
        !claimOnlyKv(tree.ceiling) or !claimOnlyKv(tree.current))
        return error.ResourceCommitmentInvalid;

    var resources: [width]ResourceCommitmentV3 = undefined;
    var total_payload_bytes: u64 = 0;
    for (session.coordinators, 0..) |coordinator, lane| {
        coordinator.validateCohortBinding(
            session.bank,
            session.tree,
            session.request_epoch,
            @intFromPtr(session),
            &session.next_sequence,
        ) catch return error.ResourceCommitmentInvalid;
        const coordinator_tree = coordinator.treeToken() catch return error.ResourceCommitmentInvalid;
        if (!std.meta.eql(coordinator_tree, tree))
            return error.ResourceCommitmentInvalid;
        const lifecycle = coordinator.lifecycle() catch return error.ResourceCommitmentInvalid;
        const identity = session.cohort[lane];
        var resource: ResourceCommitmentV3 = .{
            .lane_index = @intCast(lane),
            .lifecycle = lifecycle,
            .coordinator_instance = identity.coordinator_instance,
            .cache_instance = identity.cache_instance,
            .scope_index = identity.scope.node_index,
            .scope_generation = identity.scope.generation,
        };

        if (!session.retired[lane]) {
            if (lifecycle != .live or session.reclaimed[lane])
                return error.ResourceCommitmentInvalid;
            const row = prepared[lane] orelse
                return error.ResourceCommitmentInvalid;
            const binding_summary = coordinator.bindingSummary() catch
                return error.ResourceCommitmentInvalid;
            if (row.coordinator_instance != identity.coordinator_instance or
                row.root_after.cache_instance != identity.cache_instance or
                !std.meta.eql(row.bindings, binding_summary) or
                !std.meta.eql(row.allocation_set, coordinator.allocationSetCommitment() catch
                    return error.ResourceCommitmentInvalid))
                return error.ResourceCommitmentInvalid;
            resource.root = row.root_after;
            resource.kv_state_chain_after =
                lanes[lane].kv_transition.state_chain_after;
            resource.has_canonical_after = row.has_canonical_after;
            resource.canonical_after_sha256 = row.canonical_after_sha256;
            resource.has_terminal_generation =
                lanes[lane].terminal_reason != null;
            if (resource.has_terminal_generation) {
                resource.terminal_generation = std.math.add(
                    u64,
                    row.generation,
                    @as(u64, @intFromBool(row.txn != null)),
                ) catch return error.ResourceCommitmentInvalid;
            }
            resource.has_binding_summary = true;
            resource.binding_summary = row.bindings;
            resource.allocation_set = row.allocation_set;
        } else if (!session.reclaimed[lane]) {
            if (lifecycle != .terminal_retained or prepared[lane] != null)
                return error.ResourceCommitmentInvalid;
            const seal = session.terminal_seals[lane] orelse
                return error.ResourceCommitmentInvalid;
            const binding_summary = coordinator.bindingSummary() catch
                return error.ResourceCommitmentInvalid;
            const allocation_set = coordinator.allocationSetCommitment() catch return error.ResourceCommitmentInvalid;
            if (!std.meta.eql(binding_summary, seal.bindings) or
                !std.meta.eql(allocation_set, seal.allocation_set))
                return error.ResourceCommitmentInvalid;
            resource.root = seal.root;
            resource.kv_state_chain_after = session.kv_state_chains[lane];
            resource.has_canonical_after = true;
            resource.canonical_after_sha256 = seal.logical_kv_sha256;
            resource.has_terminal_generation = false;
            resource.terminal_generation = 0;
            resource.has_binding_summary = true;
            resource.binding_summary = binding_summary;
            resource.allocation_set = allocation_set;
        } else {
            if (lifecycle != .reclaimed or prepared[lane] != null)
                return error.ResourceCommitmentInvalid;
            if (session.terminal_seals[lane]) |seal| resource.root = seal.root;
            resource.kv_state_chain_after = session.kv_state_chains[lane];
            resource.has_terminal_generation = false;
            resource.terminal_generation = 0;
            resource.has_binding_summary = false;
            resource.binding_summary = empty_binding_summary;
            resource.allocation_set = empty_allocation_set;
        }

        if (resource.allocation_set.abi_version != leased.allocation_set_abi or
            resource.has_terminal_generation !=
                (lanes[lane].terminal_reason != null) or
            (resource.has_terminal_generation ==
                (resource.terminal_generation == 0)) or
            resource.has_binding_summary !=
                (resource.allocation_set.count != 0) or
            (resource.has_binding_summary and
                (resource.binding_summary.count !=
                    resource.allocation_set.count or
                    resource.binding_summary.payload_bytes !=
                        resource.allocation_set.payload_bytes or
                    std.mem.eql(
                        u8,
                        &resource.binding_summary.digest,
                        &zero_digest,
                    ))) or
            (!resource.has_binding_summary and
                !std.meta.eql(resource.binding_summary, empty_binding_summary)))
            return error.ResourceCommitmentInvalid;
        total_payload_bytes = std.math.add(
            u64,
            total_payload_bytes,
            resource.allocation_set.payload_bytes,
        ) catch return error.ResourceCommitmentInvalid;
        resources[lane] = resource;
    }
    if (total_payload_bytes != tree.current.kv_bytes)
        return error.ResourceCommitmentInvalid;
    return .{
        .tree = tree,
        .commitment = treeCommitment(tree),
        .resources = resources,
    };
}

const MutableRegion = struct { start: usize, bytes: usize };

fn mutableRegions(stage: LaneStage) [5]MutableRegion {
    return .{
        .{
            .start = @intFromPtr(stage.coordinator),
            .bytes = @sizeOf(leased.LeasedPagedKVCache),
        },
        .{ .start = @intFromPtr(stage.rng_state), .bytes = @sizeOf(RngState) },
        .{
            .start = @intFromPtr(stage.sampling_calls),
            .bytes = @sizeOf(usize),
        },
        .{ .start = @intFromPtr(stage.output_len), .bytes = @sizeOf(usize) },
        .{
            .start = @intFromPtr(stage.output.ptr),
            .bytes = std.math.mul(usize, stage.output.len, @sizeOf(u32)) catch
                std.math.maxInt(usize),
        },
    };
}

fn regionsOverlap(left: MutableRegion, right: MutableRegion) bool {
    const left_end = std.math.add(usize, left.start, left.bytes) catch
        return true;
    const right_end = std.math.add(usize, right.start, right.bytes) catch
        return true;
    return left.start < right_end and right.start < left_end;
}

fn stageHasInternalAlias(stage: LaneStage) bool {
    const regions = mutableRegions(stage);
    for (regions, 0..) |left, left_index|
        for (regions[left_index + 1 ..]) |right|
            if (regionsOverlap(left, right)) return true;
    return false;
}

fn bindingsAlias(left: LaneStage, right: LaneStage) bool {
    if (left.coordinator == right.coordinator) return true;
    const left_regions = mutableRegions(left);
    const right_regions = mutableRegions(right);
    for (left_regions) |left_region|
        for (right_regions) |right_region|
            if (regionsOverlap(left_region, right_region)) return true;
    return false;
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

fn hashAllocationSet(
    hash: *std.crypto.hash.sha2.Sha256,
    set: leased.AllocationSetCommitmentV2,
) void {
    hashU64(hash, set.abi_version);
    hashU32(hash, set.count);
    hashU64(hash, set.payload_bytes);
    hash.update(&set.sha256);
}

fn hashBindingSummary(
    hash: *std.crypto.hash.sha2.Sha256,
    summary: leased.BindingSummaryV1,
) void {
    hashU32(hash, summary.count);
    hashU64(hash, summary.payload_bytes);
    hash.update(&summary.digest);
}

fn hashTransition(
    hash: *std.crypto.hash.sha2.Sha256,
    transition: RootTransitionV3,
) void {
    hashU64(hash, transition.abi_version);
    hashU64(hash, transition.kv_row_txn_abi);
    hashU64(hash, transition.page_map_root_abi);
    hashU64(hash, transition.page_ref_abi);
    hashU64(hash, transition.cache_instance);
    hashU64(hash, transition.row_txn_generation);
    hashU64(hash, transition.root_before_generation);
    hashU64(hash, transition.root_after_generation);
    hashU64(hash, transition.root_before_len);
    hashU64(hash, transition.root_after_len);
    hashU64(hash, transition.root_before_pages);
    hashU64(hash, transition.root_after_pages);
    hash.update(&transition.root_before_ownership_sha256);
    hash.update(&transition.root_after_ownership_sha256);
    hashU64(hash, transition.logical_page);
    hashU64(hash, transition.page_ownership_generation);
    hashU8(hash, @intFromBool(transition.installs_new_page));
    hash.update(&transition.initial_logical_kv_sha256);
    hash.update(&transition.row_payload_sha256);
    hash.update(&transition.state_chain_before);
    hash.update(&transition.state_chain_after);
}

pub fn proposalSha256(proposal: ProposalV3) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-token-txn-proposal-v3\x00");
    hashU64(&hash, proposal.abi_version);
    hashU64(&hash, proposal.resource_bank_abi);
    hashU64(&hash, proposal.resource_lease_tree_abi);
    hashU64(&hash, proposal.resource_publication_fence_abi);
    hashU64(&hash, proposal.leased_paged_kv_abi);
    hashU64(&hash, proposal.paged_kv_abi);
    hashU64(&hash, proposal.page_transition_abi);
    hashU64(&hash, proposal.execution_abi);
    hashU64(&hash, proposal.request_epoch);
    hashU64(&hash, proposal.transaction_sequence);
    hashU64(&hash, proposal.resource_permit_generation);
    hashU8(&hash, proposal.live_mask);
    hashU8(&hash, proposal.live_lane_count);
    hashReceipt(&hash, proposal.parent_receipt);
    hashU64(&hash, proposal.tree.abi_version);
    hashU64(&hash, proposal.tree.tree_key);
    hashU64(&hash, proposal.tree.identity_generation);
    hashU64(&hash, proposal.tree.generation);
    hashU64(&hash, proposal.tree.structural_revision);
    hashClaim(&hash, proposal.tree.ceiling);
    hashClaim(&hash, proposal.tree.current);
    hashU32(&hash, proposal.tree.active_nodes);
    hashU64(&hash, proposal.tree.state_digest);
    hashU64(&hash, proposal.tree.token_integrity);
    for (proposal.resources) |resource| {
        hashU64(&hash, resource.abi_version);
        hashU32(&hash, resource.lane_index);
        hashU8(&hash, @intFromEnum(resource.lifecycle));
        hashU64(&hash, resource.coordinator_instance);
        hashU64(&hash, resource.cache_instance);
        hashU32(&hash, resource.scope_index);
        hashU64(&hash, resource.scope_generation);
        hashRoot(&hash, resource.root);
        hash.update(&resource.kv_state_chain_after);
        hashU8(&hash, @intFromBool(resource.has_canonical_after));
        hash.update(&resource.canonical_after_sha256);
        hashU8(&hash, @intFromBool(resource.has_terminal_generation));
        hashU64(&hash, resource.terminal_generation);
        hashU8(&hash, @intFromBool(resource.has_binding_summary));
        hashBindingSummary(&hash, resource.binding_summary);
        hashAllocationSet(&hash, resource.allocation_set);
    }
    for (proposal.lanes) |lane| {
        hashU32(&hash, lane.lane_index);
        hashU64(&hash, lane.step_index);
        hashU64(&hash, lane.prompt_len);
        hashU64(&hash, lane.kv_before);
        hashU64(&hash, lane.kv_after);
        hashU8(&hash, @intFromBool(lane.has_kv_transition));
        hashTransition(&hash, lane.kv_transition);
        hashU64(&hash, lane.output_before);
        hashU64(&hash, lane.output_after);
        hash.update(&lane.output_sha256);
        for (lane.rng_before) |word| hashU64(&hash, word);
        for (lane.rng_after) |word| hashU64(&hash, word);
        hashU64(&hash, lane.sampling_calls_before);
        hashU64(&hash, lane.sampling_calls_after);
        hashU32(&hash, lane.token_id);
        hashU8(&hash, if (lane.terminal_reason) |reason|
            @intFromEnum(reason) + 1
        else
            0);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

pub fn commitSha256(proposal_sha256: Digest, ack: PrepareAckV3) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-token-txn-commit-v3\x00");
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

const BatchState = enum(u8) {
    active,
    prepared,
    committed,
    aborted,
};

pub const Batch = struct {
    session: *Session,
    batch_generation: u64,
    stages: [width]?LaneStage,
    prepared: [width]?leased.PreparedTokenRowV1,
    terminal_plans: [width]?leased.TerminalPlanV3,
    proposal: ProposalV3,
    proposal_sha256: Digest,
    ack: PrepareAckV3 = .{},
    sink: ?SinkV3 = null,
    state: BatchState = .active,

    pub fn begin(
        session: *Session,
        live_stages: []const LaneStage,
    ) Error!Batch {
        try session.validateIdle();
        if (session.next_sequence == std.math.maxInt(u64) or
            session.next_batch_generation == std.math.maxInt(u64))
            return error.SequenceExhausted;
        const expected_mask = session.activeMask();
        if (expected_mask == 0 or live_stages.len == 0 or
            live_stages.len > width or
            live_stages.len != @popCount(expected_mask))
            return error.InvalidLaneSet;

        var stages = [_]?LaneStage{null} ** width;
        var prepared = [_]?leased.PreparedTokenRowV1{null} ** width;
        var terminal_plans = [_]?leased.TerminalPlanV3{null} ** width;
        var lanes = [_]LaneProposalV3{.{}} ** width;
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

            if (stageHasInternalAlias(stage)) return error.InvalidBinding;
            const identity = try BindingIdentity.fromStage(stage);
            if (identity.coordinator != session.coordinators[lane] or
                identity.coordinator_instance !=
                    session.cohort[lane].coordinator_instance or
                identity.cache_instance != session.cohort[lane].cache_instance)
                return error.InvalidBinding;
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

        // From this point Batch.begin has validated every supplied row and
        // owns their failure cleanup, even if exact-tree permit acquisition or
        // terminal planning later rejects.
        errdefer for (stages) |maybe_stage| {
            const stage = maybe_stage orelse continue;
            if (stage.leased_row_txn) |txn|
                stage.coordinator.abortRowTxn(txn) catch
                    @panic("validated leased row failed begin rollback");
        };

        const snapshot = try collectResourceSnapshot(session, prepared, lanes);
        const permit = session.bank.beginPublicationWithTree(
            snapshot.tree,
            session.request_epoch,
            @intFromPtr(session),
            session.next_sequence,
        ) catch return error.ResourceReceiptInvalid;
        errdefer {
            session.bank.abortPublication(permit) catch
                @panic("valid v3 publication permit failed begin rollback");
        }

        const proposal: ProposalV3 = .{
            .execution_abi = session.execution_abi,
            .request_epoch = session.request_epoch,
            .transaction_sequence = session.next_sequence,
            .resource_permit_generation = permit.generation,
            .live_mask = live_mask,
            .live_lane_count = @intCast(live_stages.len),
            .parent_receipt = session.parent_receipt,
            .tree = snapshot.commitment,
            .resources = snapshot.resources,
            .lanes = lanes,
        };
        const proposal_digest = proposalSha256(proposal);
        for (0..width) |lane| {
            const stage = stages[lane] orelse continue;
            const reason = stage.terminal_reason orelse continue;
            const terminal_plan = stage.coordinator
                .planTerminalForTokenTxn(
                prepared[lane].?,
                permit.sequence,
                permit.generation,
                reason,
                stage.token_id,
                stage.rng_after,
                @intCast(stage.sampling_calls_after),
                lanes[lane].output_sha256,
            ) catch return error.TerminalEvidenceInvalid;
            if (!proposal.resources[lane].has_terminal_generation or
                proposal.resources[lane].terminal_generation !=
                    terminal_plan.generation)
                return error.TerminalEvidenceInvalid;
            terminal_plans[lane] = terminal_plan;
        }

        const batch_generation = session.next_batch_generation;
        session.bindings = proposed_bindings;
        session.next_batch_generation += 1;
        session.active_batch_generation = batch_generation;
        session.active_permit = permit;
        session.active_proposal = proposal;
        session.active_proposal_sha256 = proposal_digest;
        session.active_stages = stages;
        session.active_prepared = prepared;
        session.active_terminal_plans = terminal_plans;
        session.phase = .active;
        return .{
            .session = session,
            .batch_generation = batch_generation,
            .stages = stages,
            .prepared = prepared,
            .terminal_plans = terminal_plans,
            .proposal = proposal,
            .proposal_sha256 = proposal_digest,
        };
    }

    pub fn prepare(self: *Batch, sink: SinkV3) Error!void {
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

        var ack: PrepareAckV3 = .{};
        const authoritative = &self.session.active_proposal.?;
        sink.prepare(sink.context, authoritative, &ack) catch {
            try self.rollback(.preparing, false, null, .{});
            return error.SinkRejected;
        };
        if (ack.abi_version != prepare_ack_abi or ack.sink_epoch == 0 or
            ack.reservation_id == 0 or
            !std.mem.eql(u8, &ack.proposal_sha256, &self.session.active_proposal_sha256))
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

    pub fn commit(self: *Batch) Error!CommitReceiptV3 {
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
        const commit_digest = commitSha256(proposal_digest, ack);

        // Everything below is bounded and infallible under the validated
        // single-writer contract.
        for (0..width) |lane| {
            const prepared_row = self.session.active_prepared[lane] orelse
                continue;
            self.session.coordinators[lane]
                .commitPreparedTokenRowAssumeValid(prepared_row);
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
            if (proposal.lanes[lane].terminal_reason != null)
                self.session.retired[lane] = true;
        }
        self.session.bank.commitPublicationAssumeValid(permit);
        self.session.next_sequence = permit.sequence + 1;

        var terminal_seals = [_]?leased.TerminalSealV3{null} ** width;
        for (0..width) |lane| {
            const plan = self.session.active_terminal_plans[lane] orelse
                continue;
            const seal = self.session.coordinators[lane]
                .finalizeTerminalAssumePublished(
                plan,
                proposal_digest,
                commit_digest,
            );
            self.session.terminal_seals[lane] = seal;
            terminal_seals[lane] = seal;
        }

        const receipt: CommitReceiptV3 = .{
            .proposal = proposal,
            .proposal_sha256 = proposal_digest,
            .prepare_ack = ack,
            .commit_sha256 = commit_digest,
            .terminal_seals = terminal_seals,
        };
        self.clearActiveSession();
        self.state = .committed;
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
        maybe_sink: ?SinkV3,
        ack: PrepareAckV3,
    ) Error!void {
        if (!self.owns(expected_phase) or (notify_sink and maybe_sink == null))
            return error.InvalidState;
        self.session.phase = .aborting;
        if (notify_sink) {
            const sink = maybe_sink.?;
            sink.abort(
                sink.context,
                &self.session.active_proposal.?,
                &ack,
            );
        }
        var kv_failed = false;
        for (self.session.active_stages) |maybe_stage| {
            const stage = maybe_stage orelse continue;
            if (stage.leased_row_txn) |txn|
                stage.coordinator.abortRowTxn(txn) catch {
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
        if (!self.session.initialized or
            self.session.self_address != @intFromPtr(self.session) or
            self.session.phase != phase or
            self.session.active_batch_generation != self.batch_generation)
            return false;
        return self.session.active_permit != null;
    }

    fn clearActiveSession(self: *Batch) void {
        self.session.active_batch_generation = 0;
        self.session.active_permit = null;
        self.session.active_proposal = null;
        self.session.active_proposal_sha256 = zero_digest;
        self.session.active_stages = [_]?LaneStage{null} ** width;
        self.session.active_prepared =
            [_]?leased.PreparedTokenRowV1{null} ** width;
        self.session.active_terminal_plans =
            [_]?leased.TerminalPlanV3{null} ** width;
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
            proposal.resource_lease_tree_abi != resource_bank.lease_tree_abi or
            proposal.resource_publication_fence_abi !=
                resource_bank.publication_fence_abi or
            proposal.leased_paged_kv_abi != leased.abi or
            proposal.paged_kv_abi != kv.abi or
            proposal.page_transition_abi != page_transition_abi or
            proposal.execution_abi != self.session.execution_abi or
            proposal.request_epoch != self.session.request_epoch or
            proposal.transaction_sequence != permit.sequence or
            proposal.resource_permit_generation != permit.generation or
            proposal.live_mask != expected_mask or expected_mask == 0 or
            proposal.live_lane_count != @popCount(expected_mask) or
            !std.meta.eql(proposal.parent_receipt, self.session.parent_receipt) or
            !std.meta.eql(proposal, self.proposal) or
            !std.mem.eql(u8, &digest, &self.proposal_sha256) or
            !std.mem.eql(u8, &digest, &proposalSha256(proposal)))
            return error.InvalidState;

        if (self.session.active_ack) |ack| {
            const sink = self.session.active_sink orelse
                return error.InvalidState;
            const local_sink = self.sink orelse return error.InvalidState;
            if (sink.abi_version != sink_abi or
                ack.abi_version != prepare_ack_abi or ack.sink_epoch == 0 or
                ack.reservation_id == 0 or
                !std.mem.eql(u8, &ack.proposal_sha256, &digest) or
                !std.meta.eql(ack, self.ack) or !sinkEql(sink, local_sink))
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
                    self.session.active_prepared[lane] != null or
                    self.session.active_terminal_plans[lane] != null or
                    self.stages[lane] != null or self.prepared[lane] != null or
                    self.terminal_plans[lane] != null or
                    !std.meta.eql(proposal.lanes[lane], LaneProposalV3{}))
                    return error.InvalidLaneSet;
                continue;
            }
            const stage = self.session.active_stages[lane] orelse
                return error.InvalidLaneSet;
            const local_stage = self.stages[lane] orelse
                return error.InvalidLaneSet;
            if (!stageDescriptorEql(stage, local_stage) or
                !std.meta.eql(self.session.active_prepared[lane], self.prepared[lane]) or
                !std.meta.eql(self.session.active_terminal_plans[lane], self.terminal_plans[lane]))
                return error.InvalidState;
            if (stage.lane_index != @as(u32, @intCast(lane)) or
                stageHasInternalAlias(stage))
                return error.InvalidBinding;
            const bound = self.session.bindings[lane] orelse
                return error.InvalidBinding;
            if (!bound.eql(try BindingIdentity.fromStage(stage)))
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
                    else => return error.InvalidTransition,
                };
            if (!std.meta.eql(rebuilt.proposal, proposal.lanes[lane]))
                return error.InvalidTransition;
            const active_prepared = self.session.active_prepared[lane] orelse
                return error.KvTransactionInvalid;
            if (!std.meta.eql(rebuilt.prepared, active_prepared))
                return error.KvTransactionInvalid;
            stage.coordinator.revalidatePreparedTokenRow(active_prepared) catch
                return error.KvTransactionInvalid;

            if (stage.terminal_reason) |reason| {
                const expected_plan = stage.coordinator
                    .planTerminalForTokenTxn(
                    active_prepared,
                    permit.sequence,
                    permit.generation,
                    reason,
                    stage.token_id,
                    stage.rng_after,
                    @intCast(stage.sampling_calls_after),
                    proposal.lanes[lane].output_sha256,
                ) catch return error.TerminalEvidenceInvalid;
                const active_plan =
                    self.session.active_terminal_plans[lane] orelse
                    return error.TerminalEvidenceInvalid;
                if (!std.meta.eql(expected_plan, active_plan))
                    return error.TerminalEvidenceInvalid;
                if (!proposal.resources[lane].has_terminal_generation or
                    proposal.resources[lane].terminal_generation !=
                        expected_plan.generation)
                    return error.TerminalEvidenceInvalid;
            } else if (self.session.active_terminal_plans[lane] != null) {
                return error.TerminalEvidenceInvalid;
            }
        }

        const snapshot = try collectResourceSnapshot(
            self.session,
            self.session.active_prepared,
            proposal.lanes,
        );
        if (!std.meta.eql(snapshot.tree, self.session.tree.*) or
            !std.meta.eql(snapshot.commitment, proposal.tree) or
            !std.meta.eql(snapshot.resources, proposal.resources))
            return error.ResourceCommitmentInvalid;
    }
};

// ---------------------------------------------------------------------------
// Focused module tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_execution_abi: u64 = 0x504c_5458_5445_5354;

const TestFixture = struct {
    slots: [1]resource_bank.Slot = [_]resource_bank.Slot{.{}} ** 1,
    roots: [1]resource_bank.LeaseTreeRootSlot =
        [_]resource_bank.LeaseTreeRootSlot{.{}} ** 1,
    nodes: [8]resource_bank.LeaseNodeSlot =
        [_]resource_bank.LeaseNodeSlot{.{}} ** 8,
    bank: resource_bank.Bank = undefined,
    parent: resource_bank.Receipt = undefined,
    tree: resource_bank.LeaseTreeV1 = undefined,
    scopes: [width]resource_bank.LeaseNodeV1 = undefined,
    caches: [width]kv.PagedKVCache = undefined,
    bindings: [width][1]leased.PageLeaseBindingV1 = undefined,
    coordinators: [width]leased.LeasedPagedKVCache =
        [_]leased.LeasedPagedKVCache{.{}} ** width,
    session: Session = .{},
    rng: [width]RngState = [_]RngState{.{ 11, 22, 33, 44 }} ** width,
    sampling_calls: [width]usize = [_]usize{0} ** width,
    output: [width][8]u32 = [_][8]u32{[_]u32{0} ** 8} ** width,
    output_len: [width]usize = [_]usize{0} ** width,
    cache_count: usize = 0,
    parent_live: bool = false,
    tree_live: bool = false,

    fn init(self: *TestFixture) !void {
        self.* = .{};
        const ledger = try kv.deriveCapacityLedger(1, 1, 16);
        const page_bytes: u64 = @intCast(ledger.page_payload_bytes);
        self.bank = try resource_bank.Bank.initWithLeaseTree(
            &self.slots,
            &self.roots,
            &self.nodes,
            .{ .kv_bytes = page_bytes * width, .queue_slots = width },
            0x504c_5458,
        );
        self.parent = try self.bank.commit(try self.bank.reserve(
            0x1001,
            .{ .queue_slots = width },
        ));
        self.parent_live = true;
        self.tree = try self.bank.openLeaseTree(
            self.parent,
            0x2001,
            0x3001,
            .{ .kv_bytes = page_bytes * width },
        );
        self.tree_live = true;
        for (0..width) |lane| {
            const opened = try self.bank.openScope(
                self.tree,
                0x4001 + lane,
                0x5001 + lane,
                .{ .kv_bytes = page_bytes },
            );
            self.tree = opened.tree;
            self.scopes[lane] = opened.scope;
        }
        for (0..width) |lane| {
            self.caches[lane] = try kv.PagedKVCache.init(
                testing.allocator,
                1,
                1,
                16,
            );
            self.cache_count += 1;
        }
        var coordinator_ptrs: [width]*leased.LeasedPagedKVCache = undefined;
        for (0..width) |lane| {
            try self.coordinators[lane].init(
                &self.bank,
                &self.tree,
                self.scopes[lane],
                &self.caches[lane],
                self.bindings[lane][0..],
                0x6001,
                @intFromPtr(&self.session),
                &self.session.next_sequence,
            );
            coordinator_ptrs[lane] = &self.coordinators[lane];
        }
        try self.session.init(
            &self.bank,
            self.parent,
            &self.tree,
            coordinator_ptrs,
            0x6001,
            test_execution_abi,
        );

        // One committed prompt row establishes v2-compatible first-token
        // semantics: step zero publishes no private KV row.
        for (0..width) |lane| {
            const plan = try self.coordinators[lane].planNextRow();
            const txn = try self.coordinators[lane].beginRowPlanned(plan);
            const key = [_]f32{@floatFromInt(lane + 1)};
            const value = [_]f32{-@as(f32, @floatFromInt(lane + 1))};
            _ = try self.coordinators[lane].appendRowTxn(
                txn,
                0,
                &key,
                &value,
            );
            _ = try self.coordinators[lane].commitRowTxn(txn);
        }
    }

    fn deinit(self: *TestFixture) void {
        if (self.session.initialized) {
            self.session.reclaimAllForTeardown() catch
                @panic("test fixture teardown reclaim failed");
            self.session.close() catch
                @panic("test fixture publication close failed");
        }
        if (self.tree_live) {
            self.bank.closeLeaseTree(self.tree) catch
                @panic("test fixture LeaseTree close failed");
            self.tree_live = false;
        }
        if (self.parent_live) {
            self.bank.release(self.parent) catch
                @panic("test fixture parent release failed");
            self.parent_live = false;
        }
        const snapshot = self.bank.snapshotV3() catch
            @panic("test fixture snapshot failed");
        if (!snapshot.used.isZero()) @panic("test fixture leaked Bank charge");
        for (0..self.cache_count) |lane| self.caches[lane].deinit();
        self.cache_count = 0;
    }
};

const StageBundle = struct {
    storage: [width]LaneStage = undefined,
    len: usize = 0,

    fn slice(self: *const StageBundle) []const LaneStage {
        return self.storage[0..self.len];
    }
};

fn buildTestStages(
    fixture: *TestFixture,
    terminal_mask: u8,
    token_base: u32,
) !StageBundle {
    var result: StageBundle = .{};
    const live_mask = fixture.session.activeMask();
    for (0..width) |lane| {
        const bit = @as(u8, 1) << @intCast(lane);
        if (live_mask & bit == 0) continue;
        var txn: ?leased.LeasedRowTxnV1 = null;
        if (fixture.output_len[lane] != 0) {
            const plan = try fixture.coordinators[lane].planNextRow();
            const active = try fixture.coordinators[lane]
                .beginRowPlanned(plan);
            const key = [_]f32{@floatFromInt(token_base + @as(u32, @intCast(lane)))};
            const value = [_]f32{-@as(f32, @floatFromInt(
                token_base + @as(u32, @intCast(lane)),
            ))};
            _ = try fixture.coordinators[lane].appendRowTxn(
                active,
                0,
                &key,
                &value,
            );
            txn = active;
        }
        var rng_after = fixture.rng[lane];
        rng_after[0] +%= token_base + lane + 1;
        result.storage[result.len] = .{
            .lane_index = @intCast(lane),
            .prompt_len = 1,
            .coordinator = &fixture.coordinators[lane],
            .leased_row_txn = txn,
            .rng_state = &fixture.rng[lane],
            .rng_after = rng_after,
            .sampling_calls = &fixture.sampling_calls[lane],
            .sampling_calls_after = fixture.sampling_calls[lane] + 1,
            .output = fixture.output[lane][0..],
            .output_len = &fixture.output_len[lane],
            .token_id = token_base + @as(u32, @intCast(lane)),
            .terminal_reason = if (terminal_mask & bit != 0) .eos else null,
        };
        result.len += 1;
    }
    return result;
}

const TxnTestSink = struct {
    reject: bool = false,
    fixture: ?*TestFixture = null,
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,
    prepare_saw_hidden: bool = true,
    commit_saw_visible: bool = true,
    receipt: ?CommitReceiptV3 = null,

    fn api(self: *TxnTestSink) SinkV3 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const ProposalV3,
        ack: *PrepareAckV3,
    ) SinkPrepareError!void {
        const self: *TxnTestSink = @ptrCast(@alignCast(context));
        self.prepare_calls += 1;
        if (self.fixture) |fixture| {
            for (proposal.lanes, 0..) |lane, lane_index| {
                const bit = @as(u8, 1) << @intCast(lane_index);
                if (proposal.live_mask & bit == 0) continue;
                if (fixture.output_len[lane_index] != lane.output_before or
                    !std.mem.eql(u64, &fixture.rng[lane_index], &lane.rng_before) or
                    fixture.sampling_calls[lane_index] !=
                        lane.sampling_calls_before)
                    self.prepare_saw_hidden = false;
            }
        }
        if (self.reject) return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = proposalSha256(proposal.*),
            .sink_epoch = 7,
            .reservation_id = self.prepare_calls,
        };
    }

    fn commit(context: *anyopaque, receipt: *const CommitReceiptV3) void {
        const self: *TxnTestSink = @ptrCast(@alignCast(context));
        self.commit_calls += 1;
        if (self.fixture) |fixture| {
            for (receipt.proposal.lanes, 0..) |lane, lane_index| {
                const bit = @as(u8, 1) << @intCast(lane_index);
                if (receipt.proposal.live_mask & bit == 0) continue;
                if (fixture.output_len[lane_index] != lane.output_after or
                    fixture.output[lane_index][lane.output_before] !=
                        lane.token_id or
                    !std.mem.eql(u64, &fixture.rng[lane_index], &lane.rng_after) or
                    fixture.sampling_calls[lane_index] !=
                        lane.sampling_calls_after)
                    self.commit_saw_visible = false;
            }
        }
        self.receipt = receipt.*;
    }

    fn abort(
        context: *anyopaque,
        _: *const ProposalV3,
        _: *const PrepareAckV3,
    ) void {
        const self: *TxnTestSink = @ptrCast(@alignCast(context));
        self.abort_calls += 1;
    }
};

fn commitTestWave(
    fixture: *TestFixture,
    bundle: *const StageBundle,
    sink: *TxnTestSink,
) !CommitReceiptV3 {
    var batch = try Batch.begin(&fixture.session, bundle.slice());
    try batch.prepare(sink.api());
    return batch.commit();
}

test "sink reject rolls back whole leased B4 wave" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var first_sink: TxnTestSink = .{ .fixture = &fixture };
    var first = try buildTestStages(&fixture, 0, 100);
    _ = try commitTestWave(&fixture, &first, &first_sink);

    var second = try buildTestStages(&fixture, 0, 200);
    var roots_before: [width]kv.PageMapRootV1 = undefined;
    for (0..width) |lane| roots_before[lane] = fixture.caches[lane].root();
    const rng_before = fixture.rng;
    const sampling_before = fixture.sampling_calls;
    const output_before = fixture.output;
    const output_len_before = fixture.output_len;
    const sequence_before = fixture.session.next_sequence;
    const tree_before = fixture.tree;

    var batch = try Batch.begin(&fixture.session, second.slice());
    var rejecting: TxnTestSink = .{
        .reject = true,
        .fixture = &fixture,
    };
    try testing.expectError(error.SinkRejected, batch.prepare(rejecting.api()));
    try testing.expect(rejecting.prepare_saw_hidden);
    try testing.expectEqual(@as(usize, 0), rejecting.commit_calls);
    try testing.expectEqual(@as(usize, 0), rejecting.abort_calls);
    try testing.expectEqual(sequence_before, fixture.session.next_sequence);
    try testing.expectEqualDeep(rng_before, fixture.rng);
    try testing.expectEqualDeep(sampling_before, fixture.sampling_calls);
    try testing.expectEqualDeep(output_before, fixture.output);
    try testing.expectEqualDeep(output_len_before, fixture.output_len);
    try testing.expectEqualDeep(tree_before, fixture.tree);
    for (0..width) |lane| {
        try testing.expectEqualDeep(roots_before[lane], fixture.caches[lane].root());
        const retry = try fixture.coordinators[lane].planNextRow();
        try testing.expectEqual(@as(usize, 0), retry.cache_plan.allocation_bytes);
    }
}

test "multiple terminal leased lanes share one sequence and permit" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var bundle = try buildTestStages(&fixture, 0b1111, 300);
    var sink: TxnTestSink = .{ .fixture = &fixture };
    const receipt = try commitTestWave(&fixture, &bundle, &sink);
    const first = receipt.terminal_seals[0] orelse
        return error.TestExpectedEqual;
    for (receipt.terminal_seals, 0..) |maybe_seal, lane| {
        const seal = maybe_seal orelse return error.TestExpectedEqual;
        const resource = receipt.proposal.resources[lane];
        try testing.expectEqual(@as(u64, 0), seal.transaction_sequence);
        try testing.expectEqual(
            first.transaction_sequence,
            seal.transaction_sequence,
        );
        try testing.expectEqual(first.permit_generation, seal.permit_generation);
        try testing.expectEqual(@as(u32, 300 + @as(u32, @intCast(lane))), seal.terminal_token);
        try testing.expect(resource.has_terminal_generation);
        try testing.expectEqual(resource.terminal_generation, seal.generation);
        try testing.expectEqualDeep(resource.binding_summary, seal.bindings);
    }
    try testing.expectEqual(@as(u64, 1), fixture.session.next_sequence);
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    try testing.expect(sink.commit_saw_visible);
}

test "proposal digest binds binding summary and terminal generation" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var bundle = try buildTestStages(&fixture, 0b0001, 350);
    var batch = try Batch.begin(&fixture.session, bundle.slice());
    const baseline = proposalSha256(batch.proposal);

    var changed = batch.proposal;
    changed.resources[0].binding_summary.digest[0] ^= 1;
    try testing.expect(!std.mem.eql(
        u8,
        &baseline,
        &proposalSha256(changed),
    ));
    changed = batch.proposal;
    changed.resources[0].has_binding_summary = false;
    try testing.expect(!std.mem.eql(
        u8,
        &baseline,
        &proposalSha256(changed),
    ));
    changed = batch.proposal;
    changed.resources[0].terminal_generation += 1;
    try testing.expect(!std.mem.eql(
        u8,
        &baseline,
        &proposalSha256(changed),
    ));
    try batch.abort();
}

test "stale sink ABI is rejected before callback dispatch" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var bundle = try buildTestStages(&fixture, 0, 375);
    var batch = try Batch.begin(&fixture.session, bundle.slice());
    var sink: TxnTestSink = .{ .fixture = &fixture };
    var stale = sink.api();
    stale.abi_version -= 1;
    try testing.expectError(error.InvalidConfiguration, batch.prepare(stale));
    try testing.expectEqual(@as(usize, 0), sink.prepare_calls);
}

test "proposal commits all four exact resources including terminal retained" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var first = try buildTestStages(&fixture, 0b0001, 400);
    var sink: TxnTestSink = .{ .fixture = &fixture };
    _ = try commitTestWave(&fixture, &first, &sink);
    try testing.expectEqual(@as(u8, 0b1110), fixture.session.activeMask());

    var second = try buildTestStages(&fixture, 0, 500);
    var batch = try Batch.begin(&fixture.session, second.slice());
    try testing.expectEqual(@as(u8, 0b1110), batch.proposal.live_mask);
    try testing.expectEqual(
        leased.LeaseLifecycle.terminal_retained,
        batch.proposal.resources[0].lifecycle,
    );
    var total_payload_bytes: u64 = 0;
    for (batch.proposal.resources, 0..) |resource, lane| {
        try testing.expectEqual(@as(u32, @intCast(lane)), resource.lane_index);
        try testing.expect(resource.has_binding_summary);
        try testing.expectEqual(
            resource.allocation_set.count,
            resource.binding_summary.count,
        );
        try testing.expectEqual(
            resource.allocation_set.payload_bytes,
            resource.binding_summary.payload_bytes,
        );
        try testing.expectEqual(leased.allocation_set_abi, resource.allocation_set.abi_version);
        try testing.expectEqual(@as(u32, 1), resource.allocation_set.count);
        total_payload_bytes += resource.allocation_set.payload_bytes;
    }
    try testing.expectEqual(fixture.tree.current.kv_bytes, total_payload_bytes);
    try testing.expectEqualDeep(
        treeCommitment(fixture.tree),
        batch.proposal.tree,
    );
    try batch.abort();
}

test "session coordinator and batch copies or mutation are inert" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var bundle = try buildTestStages(&fixture, 0, 600);
    var copied_coordinator = fixture.coordinators[0];
    var forged_bundle = bundle;
    forged_bundle.storage[0].coordinator = &copied_coordinator;
    try testing.expectError(
        error.InvalidBinding,
        Batch.begin(&fixture.session, forged_bundle.slice()),
    );

    var copied_session = fixture.session;
    try testing.expectError(
        error.InvalidState,
        Batch.begin(&copied_session, bundle.slice()),
    );

    var batch = try Batch.begin(&fixture.session, bundle.slice());
    var copied_batch = batch;
    copied_batch.proposal.lanes[0].token_id ^= 1;
    var sink: TxnTestSink = .{ .fixture = &fixture };
    try testing.expectError(error.InvalidState, copied_batch.prepare(sink.api()));
    try testing.expectEqual(@as(usize, 0), sink.prepare_calls);
    try testing.expectEqual(@as(u64, 0), fixture.session.next_sequence);
    try testing.expectError(error.InvalidState, batch.abort());
}

test "RNG sampler and output stay hidden through sink prepare" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    var bundle = try buildTestStages(&fixture, 0, 700);
    const rng_before = fixture.rng;
    const sampling_before = fixture.sampling_calls;
    const output_before = fixture.output;
    const output_len_before = fixture.output_len;
    var batch = try Batch.begin(&fixture.session, bundle.slice());
    try testing.expectEqualDeep(rng_before, fixture.rng);
    try testing.expectEqualDeep(sampling_before, fixture.sampling_calls);
    try testing.expectEqualDeep(output_before, fixture.output);
    try testing.expectEqualDeep(output_len_before, fixture.output_len);

    var sink: TxnTestSink = .{ .fixture = &fixture };
    try batch.prepare(sink.api());
    try testing.expect(sink.prepare_saw_hidden);
    try testing.expectEqualDeep(rng_before, fixture.rng);
    try testing.expectEqualDeep(sampling_before, fixture.sampling_calls);
    try testing.expectEqualDeep(output_before, fixture.output);
    try testing.expectEqualDeep(output_len_before, fixture.output_len);

    _ = try batch.commit();
    try testing.expectEqual(@as(usize, 1), sink.commit_calls);
    try testing.expect(sink.commit_saw_visible);
    try testing.expect(!std.meta.eql(rng_before, fixture.rng));
    try testing.expect(!std.meta.eql(sampling_before, fixture.sampling_calls));
    try testing.expect(!std.meta.eql(output_len_before, fixture.output_len));
}

test "idle teardown reclaims pre-terminal cohort and permits close" {
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();

    try fixture.session.reclaimAllForTeardown();
    try testing.expectEqual(@as(u8, 0), fixture.session.activeMask());
    try testing.expect(fixture.tree.current.isZero());
    for (0..width) |lane| {
        try testing.expect(fixture.session.retired[lane]);
        try testing.expect(fixture.session.reclaimed[lane]);
        try testing.expectEqual(
            leased.LeaseLifecycle.reclaimed,
            try fixture.coordinators[lane].lifecycle(),
        );
        // Idempotent lane-level retry is required by Decode error cleanup.
        try fixture.session.reclaimLaneForTeardown(lane);
    }
}
