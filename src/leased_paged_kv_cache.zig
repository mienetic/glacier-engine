//! LeaseTree-backed physical-page ownership for `PagedKVCache`.
//!
//! This request-local, single-writer coordinator keeps one caller-owned
//! binding slot per PagedKV physical page slot. A page payload is charged and
//! represented by an exact ResourceBank allocation leaf before PagedKV calls
//! its allocator. Materialization is settled immediately after allocator
//! success; allocation failure rolls the still-conservative reservation back
//! only after PagedKV has established that no payload was retained.
//!
//! Terminal sealing below is intentionally narrower than PagedTokenTxn v3: it
//! atomically fences an exact LeaseTree token through ResourceBank publication
//! and binds the current PagedKV root/logical digest, but it does not make
//! output, RNG, sampling, or an external sink atomic with that publication.
//! Those belong to the later transaction ABI.
//!
//! This layer inherits PagedKV's synchronous request-local reader contract.
//! ResourceBank v1 pin/reference fields are inert placeholders; this module
//! does not authorize asynchronous readers or cross-worker root retention.

const std = @import("std");
const resource_bank = @import("core").resource_bank;
const paged_kv = @import("paged_kv_cache.zig");

pub const abi: u64 = 0x4750_4c43_0000_0002;
pub const binding_abi: u64 = 0x4750_4c42_0000_0001;
pub const row_plan_abi: u64 = 0x4750_4c50_0000_0001;
pub const row_txn_abi: u64 = 0x4750_4c52_0000_0001;
pub const terminal_seal_abi: u64 = 0x4750_4c53_0000_0001;
pub const allocation_set_abi: u64 = 0x4750_4c41_0000_0002;
pub const prepared_token_row_abi: u64 = 0x4750_4c50_0000_0002;
pub const terminal_plan_v3_abi: u64 = 0x4750_4c54_0000_0003;
pub const terminal_seal_v3_abi: u64 = 0x4750_4c53_0000_0003;
pub const freed_payload_abi: u64 = 0x4750_4c46_0000_0001;
pub const reclaim_receipt_abi: u64 = 0x4750_4c43_0000_0002;
pub const Digest = [32]u8;

pub const Error = resource_bank.Error || paged_kv.Error || error{
    InvalidCoordinator,
    InvalidBindingStorage,
    InvalidBinding,
    InvalidLeasedPlan,
    InvalidLeasedTransaction,
    InvalidPreparedTokenRow,
    InvalidTerminalPlan,
    AlreadyTerminal,
    TerminalRequired,
    InvalidTerminalSeal,
    ReclaimPending,
    ReclaimComplete,
    InvalidFreedPayload,
};

pub const BindingState = enum(u8) {
    free,
    live,
    freed_pending_uncharge,
};

/// Caller-owned sidecar entry. It never stores an allocator pointer. The leaf
/// identity binds the cache instance/logical physical slot and exact payload
/// Claim; mutable PagedKV ownership generations remain in PagedKV itself.
pub const PageLeaseBindingV1 = struct {
    abi_version: u64 = binding_abi,
    state: BindingState = .free,
    cache_instance: u64 = 0,
    logical_page: u64 = 0,
    payload_bytes: u64 = 0,
    scope_index: u32 = std.math.maxInt(u32),
    scope_generation: u64 = 0,
    leaf: ?resource_bank.LeaseNodeV1 = null,
    integrity: u64 = 0,
};

pub const BindingSummaryV1 = struct {
    count: u32,
    payload_bytes: u64,
    digest: Digest,
};

/// Canonical ecosystem-facing commitment to every live physical page. Unlike
/// `BindingSummaryV1`, the digest covers the raw binding, stable LeaseNode,
/// Receipt, and Claim fields instead of re-hashing only local 64-bit integrity
/// projections. Bank validation remains the authority; this value is safe to
/// place in a transport or durable publication envelope.
pub const AllocationSetCommitmentV2 = struct {
    abi_version: u64 = allocation_set_abi,
    count: u32,
    payload_bytes: u64,
    sha256: Digest,
};

/// Exact fixed caller-owned sidecar bytes. They are not implicitly added to
/// ResourceBank.used; callers may include them in the immutable parent Claim.
pub fn bindingStorageBytes(page_slot_count: usize) Error!usize {
    if (page_slot_count == 0) return error.InvalidBindingStorage;
    return std.math.mul(
        usize,
        page_slot_count,
        @sizeOf(PageLeaseBindingV1),
    ) catch error.InvalidBindingStorage;
}

pub const LeasedRowPlanV1 = struct {
    abi_version: u64 = row_plan_abi,
    coordinator_instance: u64,
    tree: resource_bank.LeaseTreeV1,
    publication_sequence: u64,
    cache_plan: paged_kv.RowAllocationPlanV1,
    bindings: BindingSummaryV1,
    integrity: u64,
};

pub const LeasedRowTxnV1 = struct {
    abi_version: u64 = row_txn_abi,
    coordinator_instance: u64,
    generation: u64,
    mark: paged_kv.RowTxnMark,
    installed_new_binding: bool,
    bindings_digest: Digest,
    integrity: u64,
};

/// Fallible validation evidence consumed by TokenTxn v3 before its external
/// sink reservation. The later commit is bounded and infallible, and clears
/// the leased coordinator's `active_row` together with the raw PagedKV row.
pub const PreparedTokenRowV1 = struct {
    abi_version: u64 = prepared_token_row_abi,
    coordinator_instance: u64,
    generation: u64,
    txn: ?LeasedRowTxnV1,
    prepared_row: ?paged_kv.PreparedRowCommit,
    root_before: paged_kv.PageMapRootV1,
    root_after: paged_kv.PageMapRootV1,
    has_canonical_after: bool,
    canonical_after_sha256: Digest,
    row_payload_sha256: Digest,
    bindings: BindingSummaryV1,
    allocation_set: AllocationSetCommitmentV2,
    integrity: u64,
};

pub const TerminalReason = enum(u8) {
    eos,
    max_tokens,
    cancelled,
};

/// Local terminal evidence emitted only after exact-tree publication commits.
/// It is not a substitute for the future output/RNG-aware TokenTxn v3.
pub const TerminalSealV1 = struct {
    abi_version: u64 = terminal_seal_abi,
    coordinator_instance: u64,
    cache_id: usize,
    cache_instance: u64,
    scope_index: u32,
    scope_generation: u64,
    tree_identity_generation: u64,
    tree_generation: u64,
    tree_structural_revision: u64,
    tree_state_digest: u64,
    root: paged_kv.PageMapRootV1,
    logical_kv_sha256: Digest,
    bindings: BindingSummaryV1,
    transaction_sequence: u64,
    terminal_reason: TerminalReason,
    terminal_token: u32,
    generation: u64,
    digest: Digest,
};

/// Pure pre-publication terminal plan for one lane inside a whole-cohort v3
/// transaction. Multiple lanes may share one transaction/permit generation.
pub const TerminalPlanV3 = struct {
    abi_version: u64 = terminal_plan_v3_abi,
    coordinator_instance: u64,
    cache_instance: u64,
    scope_index: u32,
    scope_generation: u64,
    prepared_integrity: u64,
    tree_identity_generation: u64,
    tree_generation: u64,
    tree_structural_revision: u64,
    tree_state_digest: u64,
    root: paged_kv.PageMapRootV1,
    logical_kv_sha256: Digest,
    bindings: BindingSummaryV1,
    allocation_set: AllocationSetCommitmentV2,
    transaction_sequence: u64,
    permit_generation: u64,
    terminal_reason: TerminalReason,
    terminal_token: u32,
    rng_after: [4]u64,
    sampling_calls_after: u64,
    output_sha256: Digest,
    generation: u64,
    integrity: u64,
};

/// Commit-linked, pointer-free terminal evidence. It becomes visible only
/// after the whole B4 publication and binds output/RNG plus proposal/commit
/// digests to the exact physical allocation set.
pub const TerminalSealV3 = struct {
    abi_version: u64 = terminal_seal_v3_abi,
    coordinator_instance: u64,
    cache_instance: u64,
    scope_index: u32,
    scope_generation: u64,
    tree_identity_generation: u64,
    tree_generation: u64,
    tree_structural_revision: u64,
    tree_state_digest: u64,
    root: paged_kv.PageMapRootV1,
    logical_kv_sha256: Digest,
    bindings: BindingSummaryV1,
    allocation_set: AllocationSetCommitmentV2,
    transaction_sequence: u64,
    permit_generation: u64,
    terminal_reason: TerminalReason,
    terminal_token: u32,
    rng_after: [4]u64,
    sampling_calls_after: u64,
    output_sha256: Digest,
    proposal_sha256: Digest,
    commit_sha256: Digest,
    generation: u64,
    digest: Digest,
};

pub const LeaseLifecycle = enum(u8) {
    live,
    terminal_retained,
    freed_pending_uncharge,
    reclaimed,
};

/// Coordinator-issued post-free evidence under the trusted in-process
/// contract. Neither the allocator nor ResourceBank independently attests
/// physical release. While the Bank charge and free permit remain live, a
/// copied token can retry Bank completion; a lost or rejected completion
/// therefore leaves safe overcharge, never undercharge.
pub const FreedPayloadV1 = struct {
    abi_version: u64 = freed_payload_abi,
    coordinator_instance: u64,
    generation: u64,
    terminal_seal_digest: Digest,
    permit_generation: u64,
    root_before: paged_kv.PageMapRootV1,
    root_after: paged_kv.PageMapRootV1,
    binding_count: u32,
    payload_bytes: u64,
    bindings_digest: Digest,
    integrity: u64,
};

pub const ReclaimReceiptV1 = struct {
    abi_version: u64 = reclaim_receipt_abi,
    coordinator_instance: u64,
    generation: u64,
    freed: FreedPayloadV1,
    tree_after: resource_bank.LeaseTreeV1,
    integrity: u64,
};

const PendingReclaim = struct {
    freed: FreedPayloadV1,
    permit: resource_bank.LeaseFreePermitV1,
};

var next_coordinator_instance = std.atomic.Value(u64).init(1);

fn reserveCoordinatorInstance() Error!u64 {
    var current = next_coordinator_instance.load(.monotonic);
    while (true) {
        if (current == 0 or current == std.math.maxInt(u64))
            return error.InvalidCoordinator;
        if (next_coordinator_instance.cmpxchgWeak(
            current,
            current + 1,
            .monotonic,
            .monotonic,
        )) |observed| {
            current = observed;
        } else {
            return current;
        }
    }
}

/// `tree` is deliberately shared by pointer. Every lane in one cohort must
/// reference the same address-stable token so a sibling's structural mutation
/// is observed instead of turning another lane's cached tree copy stale.
pub const LeasedPagedKVCache = struct {
    initialized: bool = false,
    self_address: usize = 0,
    bank: *resource_bank.Bank = undefined,
    tree: *resource_bank.LeaseTreeV1 = undefined,
    scope: resource_bank.LeaseNodeV1 = undefined,
    cache: *paged_kv.PagedKVCache = undefined,
    bindings: []PageLeaseBindingV1 = undefined,
    request_epoch: u64 = 0,
    session_id: usize = 0,
    publication_sequence: *u64 = undefined,
    instance_id: u64 = 0,
    next_generation: u64 = 1,
    active_row: ?LeasedRowTxnV1 = null,
    terminal_seal: ?TerminalSealV1 = null,
    terminal_seal_v3: ?TerminalSealV3 = null,
    pending_reclaim: ?PendingReclaim = null,
    reclaimed: bool = false,

    pub fn init(
        self: *LeasedPagedKVCache,
        bank: *resource_bank.Bank,
        shared_tree: *resource_bank.LeaseTreeV1,
        scope: resource_bank.LeaseNodeV1,
        cache: *paged_kv.PagedKVCache,
        bindings: []PageLeaseBindingV1,
        request_epoch: u64,
        session_id: usize,
        shared_publication_sequence: *u64,
    ) Error!void {
        // Initialization is deliberately in-place: every later operation is
        // fenced to this exact address, so copying or moving the coordinator
        // cannot duplicate its single-writer transaction state.
        if (self.initialized or self.self_address != 0)
            return error.InvalidCoordinator;
        if (request_epoch == 0 or session_id == 0 or
            scope.kind != .scope or scope.binding_key != 0)
            return error.InvalidCoordinator;
        const capacity = cache.capacityLedger();
        if (bindings.len != capacity.page_count_capacity)
            return error.InvalidBindingStorage;
        const ledger = try cache.allocationCommitmentLedger();
        const root = cache.root();
        if (cache.isRetired() or ledger.allocated_pages != 0 or
            root.committed_len != 0 or root.committed_pages != 0)
            return error.InvalidCoordinator;
        try bank.validateLeaseNode(shared_tree.*, scope);
        const instance_id = try reserveCoordinatorInstance();
        const self_address = @intFromPtr(self);
        if (!cache.claimLeasedCoordinator(instance_id, self_address))
            return error.InvalidCoordinator;
        for (bindings) |*binding| binding.* = .{};
        self.* = .{
            .initialized = true,
            .self_address = self_address,
            .bank = bank,
            .tree = shared_tree,
            .scope = scope,
            .cache = cache,
            .bindings = bindings,
            .request_epoch = request_epoch,
            .session_id = session_id,
            .publication_sequence = shared_publication_sequence,
            .instance_id = instance_id,
        };
    }

    pub fn bindingSummary(self: *LeasedPagedKVCache) Error!BindingSummaryV1 {
        try self.validateAddress();
        return self.bindingSummaryForState(.live);
    }

    pub fn allocationSetCommitment(
        self: *LeasedPagedKVCache,
    ) Error!AllocationSetCommitmentV2 {
        try self.validateAddress();
        return self.allocationSetCommitmentForState(.live);
    }

    pub fn coordinatorInstance(self: *LeasedPagedKVCache) Error!u64 {
        try self.validateAddress();
        return self.instance_id;
    }

    pub fn cacheInstance(self: *LeasedPagedKVCache) Error!u64 {
        try self.validateAddress();
        return self.cache.root().cache_instance;
    }

    /// Read-only scheduler evidence at a quiescent row boundary.  Reusable
    /// pages are deliberately included: they still own allocator payload and
    /// therefore remain charged in the LeaseTree.
    pub fn allocationCommitmentLedger(
        self: *LeasedPagedKVCache,
    ) Error!paged_kv.AllocationCommitmentLedger {
        try self.validateAddress();
        if (self.active_row != null) return error.InvalidLeasedTransaction;
        return self.cache.allocationCommitmentLedger();
    }

    pub fn rootToken(
        self: *LeasedPagedKVCache,
    ) Error!paged_kv.PageMapRootV1 {
        try self.validateAddress();
        if (self.active_row != null) return error.InvalidLeasedTransaction;
        return self.cache.root();
    }

    pub fn publicationSequence(self: *LeasedPagedKVCache) Error!u64 {
        try self.validateAddress();
        if (self.active_row != null) return error.InvalidLeasedTransaction;
        return self.publication_sequence.*;
    }

    pub fn scopeToken(
        self: *LeasedPagedKVCache,
    ) Error!resource_bank.LeaseNodeV1 {
        try self.validateAddress();
        if (self.reclaimed) return error.ReclaimComplete;
        try self.bank.validateLeaseNode(self.tree.*, self.scope);
        return self.scope;
    }

    pub fn treeToken(
        self: *LeasedPagedKVCache,
    ) Error!resource_bank.LeaseTreeV1 {
        try self.validateAddress();
        try self.bank.validateLeaseTree(self.tree.*);
        return self.tree.*;
    }

    pub fn lifecycle(self: *LeasedPagedKVCache) Error!LeaseLifecycle {
        try self.validateAddress();
        if (self.reclaimed) return .reclaimed;
        if (self.pending_reclaim != null) return .freed_pending_uncharge;
        if (self.terminal_seal != null or self.terminal_seal_v3 != null)
            return .terminal_retained;
        return .live;
    }

    /// Prove that a v3 lane belongs to the exact address-stable cohort
    /// coordinator. The tree pointer and publication sequence pointer are
    /// intentionally compared by identity; copied sibling state is rejected.
    pub fn validateCohortBinding(
        self: *LeasedPagedKVCache,
        bank: *resource_bank.Bank,
        shared_tree: *resource_bank.LeaseTreeV1,
        request_epoch: u64,
        session_id: usize,
        shared_publication_sequence: *u64,
    ) Error!void {
        try self.validateAddress();
        if (self.bank != bank or self.tree != shared_tree or
            self.request_epoch != request_epoch or self.session_id != session_id or
            self.publication_sequence != shared_publication_sequence)
            return error.InvalidCoordinator;
        try bank.validateLeaseTree(shared_tree.*);
        if (!self.reclaimed)
            try bank.validateLeaseNode(shared_tree.*, self.scope);
    }

    pub fn planNextRow(self: *LeasedPagedKVCache) Error!LeasedRowPlanV1 {
        try self.validateAddress();
        try self.validateMutable();
        if (self.active_row != null) return error.InvalidLeasedTransaction;
        const bindings = try self.bindingSummaryForState(.live);
        const cache_plan = try self.cache.planNextRowAllocation();
        if (cache_plan.logical_page >= self.bindings.len)
            return error.InvalidBindingStorage;
        const binding = self.bindings[cache_plan.logical_page];
        if ((cache_plan.allocation_bytes == 0 and
            cache_plan.page_payload_present and binding.state != .live) or
            (cache_plan.allocation_bytes != 0 and
                (cache_plan.page_payload_present or binding.state != .free)))
            return error.InvalidBinding;
        var plan: LeasedRowPlanV1 = .{
            .coordinator_instance = self.instance_id,
            .tree = self.tree.*,
            .publication_sequence = self.publication_sequence.*,
            .cache_plan = cache_plan,
            .bindings = bindings,
            .integrity = 0,
        };
        plan.integrity = leasedRowPlanIntegrity(plan);
        return plan;
    }

    /// Reserve the exact leaf before `PagedKV.beginRowPlanned`. Allocation
    /// failure observes an unchanged cache and aborts the still-charged batch.
    /// A successful allocator call is immediately settled before return.
    pub fn beginRowPlanned(
        self: *LeasedPagedKVCache,
        plan: LeasedRowPlanV1,
    ) Error!LeasedRowTxnV1 {
        try self.validateAddress();
        const expected = try self.planNextRow();
        if (plan.abi_version != row_plan_abi or
            plan.integrity != leasedRowPlanIntegrity(plan) or
            !std.meta.eql(plan, expected))
            return error.InvalidLeasedPlan;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return error.InvalidCoordinator;

        var installed_new_binding = false;
        var mark: paged_kv.RowTxnMark = undefined;
        if (plan.cache_plan.allocation_bytes != 0) {
            const logical_page: u64 = @intCast(plan.cache_plan.logical_page);
            const payload_bytes: u64 = @intCast(plan.cache_plan.allocation_bytes);
            if (logical_page == std.math.maxInt(u64))
                return error.InvalidBinding;
            var leaves: [1]resource_bank.LeaseNodeV1 = undefined;
            const specs = [_]resource_bank.LeaseAllocationSpecV1{.{
                .scope = self.scope,
                .node_key = logical_page + 1,
                .binding_key = pageBindingKey(
                    plan.cache_plan.cache_instance,
                    logical_page,
                ),
                .claim = kvPayloadClaim(payload_bytes),
            }};
            const reservation = try self.bank.reserveAllocationsForSession(
                self.tree.*,
                self.request_epoch,
                self.session_id,
                plan.publication_sequence,
                &specs,
                &leaves,
            );
            self.tree.* = reservation.tree;
            mark = self.cache.beginRowPlanned(plan.cache_plan) catch |err| {
                self.tree.* = self.bank.abortAllocationsAfterFree(
                    reservation.batch,
                ) catch @panic("valid failed PagedKV allocation batch could not abort");
                return err;
            };
            self.tree.* = self.bank.commitAllocationsAfterAllocate(
                reservation.batch,
            ) catch @panic("valid allocated PagedKV lease batch could not settle");
            const binding_index = plan.cache_plan.logical_page;
            var binding: PageLeaseBindingV1 = .{
                .state = .live,
                .cache_instance = plan.cache_plan.cache_instance,
                .logical_page = logical_page,
                .payload_bytes = payload_bytes,
                .scope_index = self.scope.node_index,
                .scope_generation = self.scope.generation,
                .leaf = leaves[0],
            };
            binding.integrity = pageBindingIntegrity(binding);
            self.bindings[binding_index] = binding;
            installed_new_binding = true;
        } else {
            mark = try self.cache.beginRowPlanned(plan.cache_plan);
        }

        // From this point onward PagedKV owns an active row and any new page
        // is already charged. Keep the remainder deterministic and
        // non-fallible so no returned error can strand that state while
        // `active_row` is null.
        const bindings_after = self.bindingSummaryAssumeValid(.live);
        var txn: LeasedRowTxnV1 = .{
            .coordinator_instance = self.instance_id,
            .generation = self.next_generation,
            .mark = mark,
            .installed_new_binding = installed_new_binding,
            .bindings_digest = bindings_after.digest,
            .integrity = 0,
        };
        txn.integrity = leasedRowTxnIntegrity(txn);
        self.next_generation += 1;
        self.active_row = txn;
        return txn;
    }

    pub fn appendRowTxn(
        self: *LeasedPagedKVCache,
        txn: LeasedRowTxnV1,
        layer: usize,
        k_row: []const f32,
        v_row: []const f32,
    ) Error!usize {
        try self.validateAddress();
        try self.validateActiveRow(txn);
        return self.cache.appendRowTxn(txn.mark, layer, k_row, v_row);
    }

    pub fn prepareTokenRow(
        self: *LeasedPagedKVCache,
        txn: ?LeasedRowTxnV1,
        require_canonical_after: bool,
    ) Error!PreparedTokenRowV1 {
        try self.validateAddress();
        try self.validateMutable();

        var prepared_row: ?paged_kv.PreparedRowCommit = null;
        var root_before = self.cache.root();
        var root_after = root_before;
        var row_payload_sha256 = [_]u8{0} ** 32;
        var canonical_after_sha256 = [_]u8{0} ** 32;
        const generation: u64 = if (txn) |row_txn| blk: {
            try self.validateActiveRow(row_txn);
            const raw_prepared = try self.cache.prepareCommit(row_txn.mark);
            prepared_row = raw_prepared;
            root_before = raw_prepared.root_before;
            root_after = raw_prepared.root_after;
            row_payload_sha256 = try self.cache.logicalRowTxnSha256(
                row_txn.mark,
            );
            if (require_canonical_after)
                canonical_after_sha256 = try self.cache.logicalKvTxnSha256(
                    row_txn.mark,
                );
            break :blk row_txn.generation;
        } else blk: {
            if (self.active_row != null)
                return error.InvalidLeasedTransaction;
            if (require_canonical_after)
                canonical_after_sha256 = try self.cache.logicalKvSha256();
            break :blk self.next_generation;
        };

        const bindings = try self.bindingSummaryForState(.live);
        const allocation_set = try self.allocationSetCommitmentForState(.live);
        var prepared: PreparedTokenRowV1 = .{
            .coordinator_instance = self.instance_id,
            .generation = generation,
            .txn = txn,
            .prepared_row = prepared_row,
            .root_before = root_before,
            .root_after = root_after,
            .has_canonical_after = require_canonical_after,
            .canonical_after_sha256 = canonical_after_sha256,
            .row_payload_sha256 = row_payload_sha256,
            .bindings = bindings,
            .allocation_set = allocation_set,
            .integrity = 0,
        };
        prepared.integrity = preparedTokenRowIntegrity(prepared);
        return prepared;
    }

    pub fn revalidatePreparedTokenRow(
        self: *LeasedPagedKVCache,
        prepared: PreparedTokenRowV1,
    ) Error!void {
        try self.validateAddress();
        if (prepared.abi_version != prepared_token_row_abi or
            prepared.coordinator_instance != self.instance_id or
            prepared.integrity != preparedTokenRowIntegrity(prepared))
            return error.InvalidPreparedTokenRow;
        const expected = self.prepareTokenRow(
            prepared.txn,
            prepared.has_canonical_after,
        ) catch return error.InvalidPreparedTokenRow;
        if (!std.meta.eql(prepared, expected))
            return error.InvalidPreparedTokenRow;
    }

    /// TokenTxn v3 calls this only after every fallible validation and sink
    /// reservation. A panic indicates a violated in-process single-writer
    /// contract, never a retryable publication result.
    pub fn commitPreparedTokenRowAssumeValid(
        self: *LeasedPagedKVCache,
        prepared: PreparedTokenRowV1,
    ) void {
        self.revalidatePreparedTokenRow(prepared) catch
            @panic("invalid prepared leased PagedKV token row");
        if (prepared.prepared_row) |raw_prepared| {
            self.cache.commitPreparedAssumeValid(raw_prepared);
            self.active_row = null;
        }
    }

    pub fn commitRowTxn(
        self: *LeasedPagedKVCache,
        txn: LeasedRowTxnV1,
    ) Error!paged_kv.PageMapRootV1 {
        try self.validateAddress();
        try self.validateActiveRow(txn);
        const prepared = try self.cache.prepareCommit(txn.mark);
        self.cache.commitPreparedAssumeValid(prepared);
        self.active_row = null;
        return self.cache.root();
    }

    pub fn abortRowTxn(
        self: *LeasedPagedKVCache,
        txn: LeasedRowTxnV1,
    ) Error!void {
        try self.validateAddress();
        try self.validateActiveRow(txn);
        try self.cache.abortRow(txn.mark);
        self.active_row = null;
    }

    /// Seal the exact committed root and logical KV hash, then acquire and
    /// commit ResourceBank's exact-tree publication permit. No output/RNG sink
    /// participates in this Stage-2 local seal.
    pub fn sealTerminalForPublication(
        self: *LeasedPagedKVCache,
        expected_root: paged_kv.PageMapRootV1,
        expected_logical_kv_sha256: Digest,
        transaction_sequence: u64,
        terminal_reason: TerminalReason,
        terminal_token: u32,
    ) Error!TerminalSealV1 {
        try self.validateAddress();
        try self.validateMutable();
        if (self.active_row != null) return error.InvalidLeasedTransaction;
        if (self.terminal_seal != null) return error.AlreadyTerminal;
        if (transaction_sequence == std.math.maxInt(u64))
            return error.InvalidTerminalSeal;
        if (transaction_sequence != self.publication_sequence.*)
            return error.InvalidTerminalSeal;
        try self.cache.validateCurrentRoot(expected_root);
        const logical_digest = try self.cache.logicalKvSha256();
        if (!std.mem.eql(
            u8,
            &logical_digest,
            &expected_logical_kv_sha256,
        )) return error.InvalidTerminalSeal;
        const bindings = try self.bindingSummaryForState(.live);
        const ledger = try self.cache.allocationCommitmentLedger();
        if (ledger.allocated_pages != bindings.count or
            ledger.resident_tensor_payload_bytes != bindings.payload_bytes)
            return error.InvalidBinding;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return error.InvalidCoordinator;

        var seal: TerminalSealV1 = .{
            .coordinator_instance = self.instance_id,
            .cache_id = @intFromPtr(self.cache),
            .cache_instance = expected_root.cache_instance,
            .scope_index = self.scope.node_index,
            .scope_generation = self.scope.generation,
            .tree_identity_generation = self.tree.identity_generation,
            .tree_generation = self.tree.generation,
            .tree_structural_revision = self.tree.structural_revision,
            .tree_state_digest = self.tree.state_digest,
            .root = expected_root,
            .logical_kv_sha256 = logical_digest,
            .bindings = bindings,
            .transaction_sequence = transaction_sequence,
            .terminal_reason = terminal_reason,
            .terminal_token = terminal_token,
            .generation = self.next_generation,
            .digest = undefined,
        };
        seal.digest = terminalSealDigest(seal);
        const permit = try self.bank.beginPublicationWithTree(
            self.tree.*,
            self.request_epoch,
            self.session_id,
            transaction_sequence,
        );
        self.bank.commitPublicationAssumeValid(permit);
        self.publication_sequence.* = transaction_sequence + 1;
        self.next_generation += 1;
        self.terminal_seal = seal;
        return seal;
    }

    /// Build terminal evidence without acquiring or committing a Bank permit.
    /// TokenTxn v3 owns the one whole-wave permit and later calls
    /// `finalizeTerminalAssumePublished` for every lane that retired in it.
    pub fn planTerminalForTokenTxn(
        self: *LeasedPagedKVCache,
        prepared: PreparedTokenRowV1,
        transaction_sequence: u64,
        permit_generation: u64,
        terminal_reason: TerminalReason,
        terminal_token: u32,
        rng_after: [4]u64,
        sampling_calls_after: u64,
        output_sha256: Digest,
    ) Error!TerminalPlanV3 {
        try self.validateAddress();
        try self.validateMutable();
        try self.revalidatePreparedTokenRow(prepared);
        if (!prepared.has_canonical_after or permit_generation == 0 or
            transaction_sequence == std.math.maxInt(u64) or
            transaction_sequence != self.publication_sequence.*)
            return error.InvalidTerminalPlan;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return error.InvalidCoordinator;
        const tree = self.tree.*;
        try self.bank.validateLeaseTree(tree);
        var plan: TerminalPlanV3 = .{
            .coordinator_instance = self.instance_id,
            .cache_instance = prepared.root_after.cache_instance,
            .scope_index = self.scope.node_index,
            .scope_generation = self.scope.generation,
            .prepared_integrity = prepared.integrity,
            .tree_identity_generation = tree.identity_generation,
            .tree_generation = tree.generation,
            .tree_structural_revision = tree.structural_revision,
            .tree_state_digest = tree.state_digest,
            .root = prepared.root_after,
            .logical_kv_sha256 = prepared.canonical_after_sha256,
            .bindings = prepared.bindings,
            .allocation_set = prepared.allocation_set,
            .transaction_sequence = transaction_sequence,
            .permit_generation = permit_generation,
            .terminal_reason = terminal_reason,
            .terminal_token = terminal_token,
            .rng_after = rng_after,
            .sampling_calls_after = sampling_calls_after,
            .output_sha256 = output_sha256,
            .generation = self.next_generation,
            .integrity = 0,
        };
        plan.integrity = terminalPlanV3Integrity(plan);
        return plan;
    }

    pub fn finalizeTerminalAssumePublished(
        self: *LeasedPagedKVCache,
        plan: TerminalPlanV3,
        proposal_sha256: Digest,
        commit_sha256: Digest,
    ) TerminalSealV3 {
        self.validateTerminalPlanAfterPublication(plan) catch
            @panic("invalid published leased PagedKV terminal plan");
        var seal: TerminalSealV3 = .{
            .coordinator_instance = plan.coordinator_instance,
            .cache_instance = plan.cache_instance,
            .scope_index = plan.scope_index,
            .scope_generation = plan.scope_generation,
            .tree_identity_generation = plan.tree_identity_generation,
            .tree_generation = plan.tree_generation,
            .tree_structural_revision = plan.tree_structural_revision,
            .tree_state_digest = plan.tree_state_digest,
            .root = plan.root,
            .logical_kv_sha256 = plan.logical_kv_sha256,
            .bindings = plan.bindings,
            .allocation_set = plan.allocation_set,
            .transaction_sequence = plan.transaction_sequence,
            .permit_generation = plan.permit_generation,
            .terminal_reason = plan.terminal_reason,
            .terminal_token = plan.terminal_token,
            .rng_after = plan.rng_after,
            .sampling_calls_after = plan.sampling_calls_after,
            .output_sha256 = plan.output_sha256,
            .proposal_sha256 = proposal_sha256,
            .commit_sha256 = commit_sha256,
            .generation = plan.generation,
            .digest = undefined,
        };
        seal.digest = terminalSealV3Digest(seal);
        self.next_generation += 1;
        self.terminal_seal_v3 = seal;
        return seal;
    }

    /// Prepare Bank retirement, validate exact leaf count/bytes, then free all
    /// PagedKV payloads. Bank remains charged/free-authorized until the copied
    /// `FreedPayloadV1` is successfully completed.
    pub fn beginTerminalReclaim(
        self: *LeasedPagedKVCache,
        seal: TerminalSealV1,
        expected_sequence: u64,
    ) Error!FreedPayloadV1 {
        try self.validateAddress();
        try self.validateTerminalSeal(seal);
        return self.beginReclaimExact(
            seal.digest,
            seal.root,
            seal.logical_kv_sha256,
            seal.bindings,
            seal.transaction_sequence,
            expected_sequence,
        );
    }

    pub fn beginTerminalReclaimV3(
        self: *LeasedPagedKVCache,
        seal: TerminalSealV3,
        expected_sequence: u64,
    ) Error!FreedPayloadV1 {
        try self.validateAddress();
        try self.validateTerminalSealV3(seal);
        const allocation_set = try self.allocationSetCommitmentForState(.live);
        if (!std.meta.eql(allocation_set, seal.allocation_set))
            return error.InvalidBinding;
        return self.beginReclaimExact(
            seal.digest,
            seal.root,
            seal.logical_kv_sha256,
            seal.bindings,
            seal.transaction_sequence,
            expected_sequence,
        );
    }

    /// Synchronous error/teardown path used before closing the shared session
    /// or parent Receipt. It aborts a private row, retires every retained page,
    /// frees allocator payload, and completes Bank uncharge. An injected Bank
    /// completion failure leaves an exact retryable pending token and safe
    /// overcharge; callers must retry instead of deinitializing the cache.
    pub fn reclaimForTeardown(
        self: *LeasedPagedKVCache,
        expected_sequence: u64,
    ) Error!void {
        try self.validateAddress();
        if (self.reclaimed) return;
        if (self.pending_reclaim) |pending| {
            _ = try self.commitReclaimAfterFree(pending.freed);
            return;
        }
        if (self.active_row) |txn| try self.abortRowTxn(txn);
        if (expected_sequence != self.publication_sequence.*)
            return error.InvalidTerminalSeal;
        const root = self.cache.root();
        const logical_digest = try self.cache.logicalKvSha256();
        const bindings = try self.bindingSummaryForState(.live);
        if (bindings.count == 0) {
            const cache_plan = try self.cache.planRetirementReclaim();
            if (!std.meta.eql(cache_plan.root, root) or
                cache_plan.allocated_pages != 0 or
                cache_plan.payload_bytes_to_free != 0)
                return error.InvalidBinding;
            const freed_bytes = try self.cache.reclaimRetiredAfterCommit(
                cache_plan,
            );
            if (freed_bytes != 0) return error.InvalidBinding;
            for (self.bindings) |*binding| binding.* = .{};
            self.reclaimed = true;
            return;
        }
        const seal_digest = teardownSealDigest(
            self.instance_id,
            expected_sequence,
            root,
            logical_digest,
            bindings,
        );
        const freed = try self.beginReclaimExact(
            seal_digest,
            root,
            logical_digest,
            bindings,
            null,
            expected_sequence,
        );
        _ = try self.commitReclaimAfterFree(freed);
    }

    fn beginReclaimExact(
        self: *LeasedPagedKVCache,
        terminal_seal_digest: Digest,
        expected_root: paged_kv.PageMapRootV1,
        expected_logical_kv_sha256: Digest,
        expected_bindings: BindingSummaryV1,
        terminal_sequence: ?u64,
        expected_sequence: u64,
    ) Error!FreedPayloadV1 {
        if (self.pending_reclaim != null) return error.ReclaimPending;
        if (self.reclaimed) return error.ReclaimComplete;
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return error.InvalidCoordinator;
        // Reclaim is allowed after sibling lanes have published. It must use
        // the cohort's current sequence and be strictly later than this
        // lane's terminal publication, rather than assuming adjacency.
        if (expected_sequence != self.publication_sequence.* or
            (terminal_sequence != null and
                expected_sequence <= terminal_sequence.?))
            return error.InvalidTerminalSeal;
        const root_before = self.cache.root();
        try self.cache.validateCurrentRoot(expected_root);
        const logical_digest = try self.cache.logicalKvSha256();
        if (!std.mem.eql(
            u8,
            &logical_digest,
            &expected_logical_kv_sha256,
        ))
            return error.InvalidTerminalSeal;
        const bindings = try self.bindingSummaryForState(.live);
        if (!std.meta.eql(bindings, expected_bindings))
            return error.InvalidBinding;
        const cache_plan = try self.cache.planRetirementReclaim();
        if (!std.meta.eql(cache_plan.root, expected_root) or
            cache_plan.allocated_pages != bindings.count or
            cache_plan.payload_bytes_to_free != bindings.payload_bytes)
            return error.InvalidBinding;

        const prepared = try self.bank.beginRetireSubtreeForSession(
            self.tree.*,
            self.scope,
            self.request_epoch,
            self.session_id,
            expected_sequence,
        );
        self.tree.* = prepared.tree;
        const quiesced_bindings = self.bindingSummaryForState(.live) catch |err| {
            self.tree.* = self.bank.cancelRetire(prepared.ticket) catch
                @panic("valid quiescing PagedKV ticket could not cancel");
            return err;
        };
        if (!std.meta.eql(quiesced_bindings, bindings) or
            prepared.ticket.node_count != bindings.count or
            !claimIsExactKv(prepared.ticket.claim, bindings.payload_bytes))
        {
            self.tree.* = try self.bank.cancelRetire(prepared.ticket);
            return error.InvalidBinding;
        }
        const authorized = try self.bank.authorizeFree(prepared.ticket);
        self.tree.* = authorized.tree;

        const freed_bytes = self.cache.reclaimRetiredAfterCommit(
            cache_plan,
        ) catch @panic("prevalidated PagedKV retirement failed after free authorization");
        if (freed_bytes != bindings.payload_bytes)
            @panic("prevalidated PagedKV reclaim returned wrong byte count");
        for (self.bindings) |*binding| {
            if (binding.state != .live) continue;
            binding.state = .freed_pending_uncharge;
            binding.integrity = pageBindingIntegrity(binding.*);
        }
        const pending_bindings = self.bindingSummaryForState(
            .freed_pending_uncharge,
        ) catch @panic("prevalidated bindings changed during allocator free");
        var freed: FreedPayloadV1 = .{
            .coordinator_instance = self.instance_id,
            .generation = self.next_generation,
            .terminal_seal_digest = terminal_seal_digest,
            .permit_generation = authorized.permit.generation,
            .root_before = root_before,
            .root_after = self.cache.root(),
            .binding_count = bindings.count,
            .payload_bytes = bindings.payload_bytes,
            .bindings_digest = pending_bindings.digest,
            .integrity = 0,
        };
        freed.integrity = freedPayloadIntegrity(freed);
        self.next_generation += 1;
        self.pending_reclaim = .{
            .freed = freed,
            .permit = authorized.permit,
        };
        return freed;
    }

    /// Complete Bank uncharge after the allocator free. Any failure leaves the
    /// pending permit and binding evidence intact so the exact token can retry.
    pub fn commitReclaimAfterFree(
        self: *LeasedPagedKVCache,
        freed: FreedPayloadV1,
    ) Error!ReclaimReceiptV1 {
        try self.validateAddress();
        const pending = self.pending_reclaim orelse {
            if (self.reclaimed) return error.ReclaimComplete;
            return error.InvalidFreedPayload;
        };
        if (freed.abi_version != freed_payload_abi or
            freed.integrity != freedPayloadIntegrity(freed) or
            !std.meta.eql(freed, pending.freed))
            return error.InvalidFreedPayload;
        const summary = try self.bindingSummaryForState(
            .freed_pending_uncharge,
        );
        if (summary.count != freed.binding_count or
            summary.payload_bytes != freed.payload_bytes or
            !std.mem.eql(u8, &summary.digest, &freed.bindings_digest))
            return error.InvalidBinding;

        const tree_after = try self.bank.commitFreeAfterAllocatorFree(
            pending.permit,
        );
        self.tree.* = tree_after;
        for (self.bindings) |*binding| binding.* = .{};
        self.pending_reclaim = null;
        self.reclaimed = true;
        var receipt: ReclaimReceiptV1 = .{
            .coordinator_instance = self.instance_id,
            .generation = freed.generation,
            .freed = freed,
            .tree_after = tree_after,
            .integrity = 0,
        };
        receipt.integrity = reclaimReceiptIntegrity(receipt);
        return receipt;
    }

    fn validateAddress(self: *const LeasedPagedKVCache) Error!void {
        if (!self.initialized or self.self_address == 0 or
            self.self_address != @intFromPtr(self) or
            !self.cache.isLeasedCoordinator(
                self.instance_id,
                self.self_address,
            ))
            return error.InvalidCoordinator;
    }

    fn validateMutable(self: *LeasedPagedKVCache) Error!void {
        try self.validateAddress();
        if (self.reclaimed) return error.ReclaimComplete;
        if (self.pending_reclaim != null) return error.ReclaimPending;
        if (self.terminal_seal != null or self.terminal_seal_v3 != null)
            return error.AlreadyTerminal;
        try self.bank.validateLeaseNode(self.tree.*, self.scope);
        if (self.scope.kind != .scope) return error.InvalidCoordinator;
    }

    fn validateActiveRow(
        self: *LeasedPagedKVCache,
        txn: LeasedRowTxnV1,
    ) Error!void {
        try self.validateAddress();
        const active = self.active_row orelse
            return error.InvalidLeasedTransaction;
        if (txn.abi_version != row_txn_abi or
            txn.integrity != leasedRowTxnIntegrity(txn) or
            !std.meta.eql(txn, active))
            return error.InvalidLeasedTransaction;
    }

    fn validateTerminalSeal(
        self: *LeasedPagedKVCache,
        seal: TerminalSealV1,
    ) Error!void {
        try self.validateAddress();
        const stored = self.terminal_seal orelse
            return error.TerminalRequired;
        if (seal.abi_version != terminal_seal_abi or
            !std.mem.eql(u8, &seal.digest, &terminalSealDigest(seal)) or
            !std.meta.eql(seal, stored) or
            seal.coordinator_instance != self.instance_id or
            seal.cache_id != @intFromPtr(self.cache) or
            seal.scope_index != self.scope.node_index or
            seal.scope_generation != self.scope.generation)
            return error.InvalidTerminalSeal;
    }

    fn validateTerminalSealV3(
        self: *LeasedPagedKVCache,
        seal: TerminalSealV3,
    ) Error!void {
        try self.validateAddress();
        const stored = self.terminal_seal_v3 orelse
            return error.TerminalRequired;
        if (seal.abi_version != terminal_seal_v3_abi or
            !std.mem.eql(u8, &seal.digest, &terminalSealV3Digest(seal)) or
            !std.meta.eql(seal, stored) or
            seal.coordinator_instance != self.instance_id or
            seal.cache_instance != self.cache.root().cache_instance or
            seal.scope_index != self.scope.node_index or
            seal.scope_generation != self.scope.generation)
            return error.InvalidTerminalSeal;
    }

    fn validateTerminalPlanAfterPublication(
        self: *LeasedPagedKVCache,
        plan: TerminalPlanV3,
    ) Error!void {
        try self.validateAddress();
        if (self.reclaimed or self.pending_reclaim != null or
            self.terminal_seal != null or self.terminal_seal_v3 != null or
            self.active_row != null)
            return error.InvalidTerminalPlan;
        if (plan.abi_version != terminal_plan_v3_abi or
            plan.integrity != terminalPlanV3Integrity(plan) or
            plan.coordinator_instance != self.instance_id or
            plan.cache_instance != self.cache.root().cache_instance or
            plan.scope_index != self.scope.node_index or
            plan.scope_generation != self.scope.generation or
            plan.generation != self.next_generation or
            plan.transaction_sequence == std.math.maxInt(u64) or
            self.publication_sequence.* != plan.transaction_sequence + 1)
            return error.InvalidTerminalPlan;
        const tree = self.tree.*;
        try self.bank.validateLeaseTree(tree);
        if (plan.tree_identity_generation != tree.identity_generation or
            plan.tree_generation != tree.generation or
            plan.tree_structural_revision != tree.structural_revision or
            plan.tree_state_digest != tree.state_digest)
            return error.InvalidTerminalPlan;
        try self.cache.validateCurrentRoot(plan.root);
        const logical_digest = try self.cache.logicalKvSha256();
        if (!std.mem.eql(u8, &logical_digest, &plan.logical_kv_sha256))
            return error.InvalidTerminalPlan;
        const bindings = try self.bindingSummaryForState(.live);
        const allocation_set = try self.allocationSetCommitmentForState(.live);
        if (!std.meta.eql(bindings, plan.bindings) or
            !std.meta.eql(allocation_set, plan.allocation_set))
            return error.InvalidTerminalPlan;
    }

    fn bindingSummaryForState(
        self: *LeasedPagedKVCache,
        expected_state: BindingState,
    ) Error!BindingSummaryV1 {
        try self.validateAddress();
        try self.bank.validateLeaseNode(self.tree.*, self.scope);
        const root = self.cache.root();
        var count: u32 = 0;
        var payload_bytes: u64 = 0;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("glacier-paged-lease-bindings-v1\x00");
        hashU64(&hash, self.instance_id);
        hashU64(&hash, root.cache_instance);
        hashU32(&hash, self.scope.node_index);
        hashU64(&hash, self.scope.generation);
        for (self.bindings, 0..) |binding, index| {
            if (binding.state == .free) {
                if (!std.meta.eql(binding, PageLeaseBindingV1{}))
                    return error.InvalidBinding;
                continue;
            }
            if (binding.state != expected_state or
                binding.abi_version != binding_abi or
                binding.cache_instance != root.cache_instance or
                binding.logical_page != index or binding.payload_bytes == 0 or
                binding.scope_index != self.scope.node_index or
                binding.scope_generation != self.scope.generation or
                binding.integrity != pageBindingIntegrity(binding))
                return error.InvalidBinding;
            const leaf = binding.leaf orelse return error.InvalidBinding;
            if (leaf.kind != .allocation or
                leaf.parent_index != self.scope.node_index or
                leaf.parent_generation != self.scope.generation or
                leaf.tenant_key != self.scope.tenant_key or
                binding.logical_page == std.math.maxInt(u64) or
                leaf.node_key != binding.logical_page + 1 or
                leaf.binding_key != pageBindingKey(
                    binding.cache_instance,
                    binding.logical_page,
                ) or !claimIsExactKv(leaf.claim, binding.payload_bytes))
                return error.InvalidBinding;
            try self.bank.validateLeaseNode(self.tree.*, leaf);
            if (count == std.math.maxInt(u32)) return error.InvalidBinding;
            count += 1;
            payload_bytes = std.math.add(
                u64,
                payload_bytes,
                binding.payload_bytes,
            ) catch return error.InvalidBinding;
            hashU64(&hash, @intCast(index));
            hashU64(&hash, binding.integrity);
            hashU64(&hash, leaf.integrity);
            hashU64(&hash, leaf.generation);
            hashU32(&hash, leaf.node_index);
        }
        if (expected_state == .live) {
            const ledger = try self.cache.allocationCommitmentLedger();
            if (ledger.allocated_pages != count or
                ledger.resident_tensor_payload_bytes != payload_bytes)
                return error.InvalidBinding;
        }
        var digest: Digest = undefined;
        hash.final(&digest);
        return .{
            .count = count,
            .payload_bytes = payload_bytes,
            .digest = digest,
        };
    }

    fn allocationSetCommitmentForState(
        self: *LeasedPagedKVCache,
        expected_state: BindingState,
    ) Error!AllocationSetCommitmentV2 {
        const summary = try self.bindingSummaryForState(expected_state);
        const root = self.cache.root();
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("glacier-paged-lease-allocation-set-v2\x00");
        hashU64(&hash, allocation_set_abi);
        hashU64(&hash, self.instance_id);
        hashU64(&hash, root.cache_instance);
        hashU64(&hash, @intCast(self.bindings.len));
        hashLeaseNode(&hash, self.scope);
        for (self.bindings, 0..) |binding, index| {
            if (binding.state == .free) continue;
            if (binding.state != expected_state or
                binding.integrity != pageBindingIntegrity(binding))
                return error.InvalidBinding;
            const leaf = binding.leaf orelse return error.InvalidBinding;
            try self.bank.validateLeaseNode(self.tree.*, leaf);
            hashU64(&hash, @intCast(index));
            hashU64(&hash, binding.abi_version);
            hash.update(&.{@intFromEnum(binding.state)});
            hashU64(&hash, binding.cache_instance);
            hashU64(&hash, binding.logical_page);
            hashU64(&hash, binding.payload_bytes);
            hashU32(&hash, binding.scope_index);
            hashU64(&hash, binding.scope_generation);
            hashU64(&hash, binding.integrity);
            hashLeaseNode(&hash, leaf);
        }
        var digest: Digest = undefined;
        hash.final(&digest);
        return .{
            .count = summary.count,
            .payload_bytes = summary.payload_bytes,
            .sha256 = digest,
        };
    }

    /// Local post-settle summary. All entries were validated by the exact
    /// leased plan immediately before mutation, and the only possible change
    /// is the coordinator-installed binding above. Consequently this helper
    /// performs no Bank/PagedKV calls and cannot return an error.
    fn bindingSummaryAssumeValid(
        self: *LeasedPagedKVCache,
        expected_state: BindingState,
    ) BindingSummaryV1 {
        self.validateAddress() catch
            @panic("LeasedPagedKV coordinator moved during row begin");
        const root = self.cache.root();
        var count: u32 = 0;
        var payload_bytes: u64 = 0;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("glacier-paged-lease-bindings-v1\x00");
        hashU64(&hash, self.instance_id);
        hashU64(&hash, root.cache_instance);
        hashU32(&hash, self.scope.node_index);
        hashU64(&hash, self.scope.generation);
        for (self.bindings, 0..) |binding, index| {
            if (binding.state == .free) continue;
            if (binding.state != expected_state)
                @panic("leased binding changed after PagedKV row begin");
            const leaf = binding.leaf orelse
                @panic("leased binding lost leaf after PagedKV row begin");
            count = std.math.add(u32, count, 1) catch
                @panic("leased binding count overflow after PagedKV row begin");
            payload_bytes = std.math.add(
                u64,
                payload_bytes,
                binding.payload_bytes,
            ) catch @panic("leased payload overflow after PagedKV row begin");
            hashU64(&hash, @intCast(index));
            hashU64(&hash, binding.integrity);
            hashU64(&hash, leaf.integrity);
            hashU64(&hash, leaf.generation);
            hashU32(&hash, leaf.node_index);
        }
        var digest: Digest = undefined;
        hash.final(&digest);
        return .{
            .count = count,
            .payload_bytes = payload_bytes,
            .digest = digest,
        };
    }
};

fn kvPayloadClaim(bytes: u64) resource_bank.Claim {
    return .{ .kv_bytes = bytes };
}

fn claimIsExactKv(claim: resource_bank.Claim, bytes: u64) bool {
    return claim.kv_bytes == bytes and claim.capsule_bytes == 0 and
        claim.activation_bytes == 0 and claim.partial_bytes == 0 and
        claim.logits_bytes == 0 and claim.output_journal_bytes == 0 and
        claim.staging_bytes == 0 and claim.device_bytes == 0 and
        claim.io_bytes == 0 and claim.queue_slots == 0;
}

fn pageBindingKey(cache_instance: u64, logical_page: u64) u64 {
    const value = mix64(0x7061_6765_6c65_6166 ^ cache_instance ^
        mix64(logical_page +% 1));
    return if (value == 0) 1 else value;
}

fn mix64(value: u64) u64 {
    var mixed = value;
    mixed ^= mixed >> 30;
    mixed *%= 0xbf58_476d_1ce4_e5b9;
    mixed ^= mixed >> 27;
    mixed *%= 0x94d0_49bb_1331_11eb;
    mixed ^= mixed >> 31;
    return mixed;
}

fn pageBindingIntegrity(binding: PageLeaseBindingV1) u64 {
    var result = mix64(binding_abi ^ @intFromEnum(binding.state));
    result = mix64(result ^ binding.cache_instance);
    result = mix64(result ^ binding.logical_page);
    result = mix64(result ^ binding.payload_bytes);
    result = mix64(result ^ @as(u64, binding.scope_index));
    result = mix64(result ^ binding.scope_generation);
    if (binding.leaf) |leaf| {
        result = mix64(result ^ leaf.integrity);
        result = mix64(result ^ leaf.generation);
        result = mix64(result ^ @as(u64, leaf.node_index));
    }
    return result;
}

fn leasedRowPlanIntegrity(plan: LeasedRowPlanV1) u64 {
    var result = mix64(row_plan_abi ^ plan.coordinator_instance);
    result = mix64(result ^ plan.tree.integrity);
    result = mix64(result ^ plan.tree.generation);
    result = mix64(result ^ plan.tree.structural_revision);
    result = mix64(result ^ plan.publication_sequence);
    result = mix64(result ^ plan.cache_plan.cache_instance);
    result = mix64(result ^ @as(u64, @intCast(plan.cache_plan.logical_page)));
    result = mix64(result ^ @as(u64, @intCast(plan.cache_plan.base_len)));
    result = mix64(result ^ @as(u64, @intCast(plan.cache_plan.allocation_bytes)));
    result = mix64(result ^ @as(u64, plan.bindings.count));
    result = mix64(result ^ plan.bindings.payload_bytes);
    for (plan.bindings.digest) |byte| result = mix64(result ^ byte);
    return result;
}

fn leasedRowTxnIntegrity(txn: LeasedRowTxnV1) u64 {
    var result = mix64(row_txn_abi ^ txn.coordinator_instance);
    result = mix64(result ^ txn.generation);
    result = mix64(result ^ txn.mark.cache_instance);
    result = mix64(result ^ txn.mark.generation);
    result = mix64(result ^ txn.mark.root_after_generation);
    result = mix64(result ^ @intFromBool(txn.installed_new_binding));
    for (txn.bindings_digest) |byte| result = mix64(result ^ byte);
    return result;
}

fn preparedTokenRowIntegrity(prepared: PreparedTokenRowV1) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-prepared-token-row-v1\x00");
    hashU64(&hash, prepared_token_row_abi);
    hashU64(&hash, prepared.coordinator_instance);
    hashU64(&hash, prepared.generation);
    if (prepared.txn) |txn| {
        hash.update(&.{1});
        hashLeasedRowTxn(&hash, txn);
    } else hash.update(&.{0});
    if (prepared.prepared_row) |row| {
        hash.update(&.{1});
        hashPreparedRowCommit(&hash, row);
    } else hash.update(&.{0});
    hashPageRoot(&hash, prepared.root_before);
    hashPageRoot(&hash, prepared.root_after);
    hash.update(&.{@intFromBool(prepared.has_canonical_after)});
    hash.update(&prepared.canonical_after_sha256);
    hash.update(&prepared.row_payload_sha256);
    hashBindingSummary(&hash, prepared.bindings);
    hashAllocationSet(&hash, prepared.allocation_set);
    return finishIntegrity(&hash);
}

fn terminalPlanV3Integrity(plan: TerminalPlanV3) u64 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-terminal-plan-v3\x00");
    hashU64(&hash, terminal_plan_v3_abi);
    hashU64(&hash, plan.coordinator_instance);
    hashU64(&hash, plan.cache_instance);
    hashU32(&hash, plan.scope_index);
    hashU64(&hash, plan.scope_generation);
    hashU64(&hash, plan.prepared_integrity);
    hashU64(&hash, plan.tree_identity_generation);
    hashU64(&hash, plan.tree_generation);
    hashU64(&hash, plan.tree_structural_revision);
    hashU64(&hash, plan.tree_state_digest);
    hashPageRoot(&hash, plan.root);
    hash.update(&plan.logical_kv_sha256);
    hashBindingSummary(&hash, plan.bindings);
    hashAllocationSet(&hash, plan.allocation_set);
    hashU64(&hash, plan.transaction_sequence);
    hashU64(&hash, plan.permit_generation);
    hash.update(&.{@intFromEnum(plan.terminal_reason)});
    hashU32(&hash, plan.terminal_token);
    for (plan.rng_after) |word| hashU64(&hash, word);
    hashU64(&hash, plan.sampling_calls_after);
    hash.update(&plan.output_sha256);
    hashU64(&hash, plan.generation);
    return finishIntegrity(&hash);
}

/// Canonical digest for pointer-free terminal evidence. Exposed so independent
/// synchronous sinks and retained evidence runners can reject a self-consistent
/// proposal/commit hash that carries a forged terminal-seal payload.
pub fn terminalSealV3Digest(seal: TerminalSealV3) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-terminal-seal-v3\x00");
    hashU64(&hash, terminal_seal_v3_abi);
    hashU64(&hash, seal.coordinator_instance);
    hashU64(&hash, seal.cache_instance);
    hashU32(&hash, seal.scope_index);
    hashU64(&hash, seal.scope_generation);
    hashU64(&hash, seal.tree_identity_generation);
    hashU64(&hash, seal.tree_generation);
    hashU64(&hash, seal.tree_structural_revision);
    hashU64(&hash, seal.tree_state_digest);
    hashPageRoot(&hash, seal.root);
    hash.update(&seal.logical_kv_sha256);
    hashBindingSummary(&hash, seal.bindings);
    hashAllocationSet(&hash, seal.allocation_set);
    hashU64(&hash, seal.transaction_sequence);
    hashU64(&hash, seal.permit_generation);
    hash.update(&.{@intFromEnum(seal.terminal_reason)});
    hashU32(&hash, seal.terminal_token);
    for (seal.rng_after) |word| hashU64(&hash, word);
    hashU64(&hash, seal.sampling_calls_after);
    hash.update(&seal.output_sha256);
    hash.update(&seal.proposal_sha256);
    hash.update(&seal.commit_sha256);
    hashU64(&hash, seal.generation);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn teardownSealDigest(
    coordinator_instance: u64,
    sequence: u64,
    root: paged_kv.PageMapRootV1,
    logical_kv_sha256: Digest,
    bindings: BindingSummaryV1,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-teardown-v1\x00");
    hashU64(&hash, coordinator_instance);
    hashU64(&hash, sequence);
    hashPageRoot(&hash, root);
    hash.update(&logical_kv_sha256);
    hashBindingSummary(&hash, bindings);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn hashLeasedRowTxn(
    hash: *std.crypto.hash.sha2.Sha256,
    txn: LeasedRowTxnV1,
) void {
    hashU64(hash, txn.abi_version);
    hashU64(hash, txn.coordinator_instance);
    hashU64(hash, txn.generation);
    hashRowTxnMark(hash, txn.mark);
    hash.update(&.{@intFromBool(txn.installed_new_binding)});
    hash.update(&txn.bindings_digest);
    hashU64(hash, txn.integrity);
}

fn hashPreparedRowCommit(
    hash: *std.crypto.hash.sha2.Sha256,
    prepared: paged_kv.PreparedRowCommit,
) void {
    hashU64(hash, prepared.abi_version);
    hashRowTxnMark(hash, prepared.mark);
    hashPageRoot(hash, prepared.root_before);
    hashPageRoot(hash, prepared.root_after);
    hash.update(&.{@intFromBool(prepared.installs_new_page)});
}

fn hashRowTxnMark(
    hash: *std.crypto.hash.sha2.Sha256,
    mark: paged_kv.RowTxnMark,
) void {
    hashU64(hash, mark.abi_version);
    hashU64(hash, @intCast(mark.cache_id));
    hashU64(hash, mark.cache_instance);
    hashU64(hash, mark.generation);
    hashU64(hash, @intCast(mark.base_len));
    hashU64(hash, @intCast(mark.row_count));
    hashU64(hash, mark.root_before_generation);
    hashU64(hash, mark.root_after_generation);
    hashU64(hash, mark.page_ref.abi_version);
    hashU64(hash, mark.page_ref.cache_instance);
    hashU64(hash, mark.page_ref.logical_page);
    hashU64(hash, mark.page_ref.ownership_generation);
}

fn hashBindingSummary(
    hash: *std.crypto.hash.sha2.Sha256,
    summary: BindingSummaryV1,
) void {
    hashU32(hash, summary.count);
    hashU64(hash, summary.payload_bytes);
    hash.update(&summary.digest);
}

fn hashAllocationSet(
    hash: *std.crypto.hash.sha2.Sha256,
    set: AllocationSetCommitmentV2,
) void {
    hashU64(hash, set.abi_version);
    hashU32(hash, set.count);
    hashU64(hash, set.payload_bytes);
    hash.update(&set.sha256);
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

fn hashLeaseNode(
    hash: *std.crypto.hash.sha2.Sha256,
    node: resource_bank.LeaseNodeV1,
) void {
    hashU64(hash, node.abi_version);
    hashReceipt(hash, node.parent);
    hashU64(hash, node.tree_key);
    hashU64(hash, node.tree_identity_generation);
    hashU32(hash, node.node_index);
    hashU64(hash, node.generation);
    hashU32(hash, node.parent_index);
    hashU64(hash, node.parent_generation);
    hashU64(hash, node.node_key);
    hashU64(hash, node.tenant_key);
    hashU64(hash, node.binding_key);
    hash.update(&.{@intFromEnum(node.kind)});
    hashClaim(hash, node.ceiling);
    hashClaim(hash, node.claim);
    hashU64(hash, node.integrity);
}

fn finishIntegrity(hash: *std.crypto.hash.sha2.Sha256) u64 {
    var digest: Digest = undefined;
    hash.final(&digest);
    const result = std.mem.readInt(u64, digest[0..8], .little);
    return if (result == 0) 1 else result;
}

fn terminalSealDigest(seal: TerminalSealV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-lease-terminal-seal-v1\x00");
    hashU64(&hash, seal.coordinator_instance);
    hashU64(&hash, @intCast(seal.cache_id));
    hashU64(&hash, seal.cache_instance);
    hashU32(&hash, seal.scope_index);
    hashU64(&hash, seal.scope_generation);
    hashU64(&hash, seal.tree_identity_generation);
    hashU64(&hash, seal.tree_generation);
    hashU64(&hash, seal.tree_structural_revision);
    hashU64(&hash, seal.tree_state_digest);
    hashPageRoot(&hash, seal.root);
    hash.update(&seal.logical_kv_sha256);
    hashU32(&hash, seal.bindings.count);
    hashU64(&hash, seal.bindings.payload_bytes);
    hash.update(&seal.bindings.digest);
    hashU64(&hash, seal.transaction_sequence);
    hash.update(&.{@intFromEnum(seal.terminal_reason)});
    hashU32(&hash, seal.terminal_token);
    hashU64(&hash, seal.generation);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn freedPayloadIntegrity(freed: FreedPayloadV1) u64 {
    var result = mix64(freed_payload_abi ^ freed.coordinator_instance);
    result = mix64(result ^ freed.generation);
    result = mix64(result ^ freed.permit_generation);
    result = mix64(result ^ freed.root_before.generation);
    result = mix64(result ^ freed.root_after.generation);
    result = mix64(result ^ @as(u64, freed.binding_count));
    result = mix64(result ^ freed.payload_bytes);
    for (freed.terminal_seal_digest) |byte| result = mix64(result ^ byte);
    for (freed.bindings_digest) |byte| result = mix64(result ^ byte);
    return result;
}

fn reclaimReceiptIntegrity(receipt: ReclaimReceiptV1) u64 {
    var result = mix64(reclaim_receipt_abi ^ receipt.coordinator_instance);
    result = mix64(result ^ receipt.generation);
    result = mix64(result ^ receipt.freed.integrity);
    result = mix64(result ^ receipt.tree_after.integrity);
    return result;
}

fn hashPageRoot(
    hash: *std.crypto.hash.sha2.Sha256,
    root: paged_kv.PageMapRootV1,
) void {
    hashU64(hash, root.abi_version);
    hashU64(hash, root.cache_instance);
    hashU64(hash, root.generation);
    hashU64(hash, root.committed_len);
    hashU64(hash, root.committed_pages);
    hash.update(&root.ownership_sha256);
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

fn appendScalarTestRow(
    leased: *LeasedPagedKVCache,
    value: f32,
) Error!LeasedRowTxnV1 {
    const plan = try leased.planNextRow();
    const txn = try leased.beginRowPlanned(plan);
    const key = [_]f32{value};
    const val = [_]f32{-value};
    _ = try leased.appendRowTxn(txn, 0, &key, &val);
    _ = try leased.commitRowTxn(txn);
    return txn;
}

test "two leased lanes share current tree and reclaim exact physical pages" {
    const testing = std.testing;
    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 8;
    var bank = try resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 512, .queue_slots = 1 },
        0x4c50_4341,
    );
    const parent = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    var shared_tree = try bank.openLeaseTree(
        parent,
        0x7472_6565,
        0x6175_7468,
        .{ .kv_bytes = 512 },
    );
    const left_scope_open = try bank.openScope(
        shared_tree,
        10,
        100,
        .{ .kv_bytes = 256 },
    );
    shared_tree = left_scope_open.tree;
    const right_scope_open = try bank.openScope(
        shared_tree,
        11,
        101,
        .{ .kv_bytes = 256 },
    );
    shared_tree = right_scope_open.tree;
    var coordinator_byte: u8 = 0;
    const session_id = @intFromPtr(&coordinator_byte);
    const request_epoch: u64 = 0x4c50_4342;
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithTree(
        shared_tree,
        request_epoch,
        session_id,
    );

    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    var left_cache = try paged_kv.PagedKVCache.init(
        tracking.allocator(),
        1,
        1,
        33,
    );
    var right_cache = try paged_kv.PagedKVCache.init(
        tracking.allocator(),
        1,
        1,
        17,
    );
    var caches_live = true;
    defer if (caches_live) {
        left_cache.deinit();
        right_cache.deinit();
    };
    const map_outstanding = tracking.allocated_bytes - tracking.freed_bytes;
    var left_bindings = [_]PageLeaseBindingV1{.{}} ** 3;
    var right_bindings = [_]PageLeaseBindingV1{.{}} ** 2;
    var duplicate_left_bindings = [_]PageLeaseBindingV1{.{}} ** 3;
    try testing.expectEqual(
        @sizeOf(@TypeOf(left_bindings)),
        try bindingStorageBytes(left_bindings.len),
    );
    var left: LeasedPagedKVCache = .{};
    try left.init(
        &bank,
        &shared_tree,
        left_scope_open.scope,
        &left_cache,
        &left_bindings,
        request_epoch,
        session_id,
        &publication_sequence,
    );
    // A fresh address-stable coordinator with independent sidecar storage
    // cannot acquire the same cache: exclusive ownership lives in PagedKV,
    // not merely in the coordinator object's self-address fence.
    var duplicate_left: LeasedPagedKVCache = .{};
    try testing.expectError(
        error.InvalidCoordinator,
        duplicate_left.init(
            &bank,
            &shared_tree,
            left_scope_open.scope,
            &left_cache,
            &duplicate_left_bindings,
            request_epoch,
            session_id,
            &publication_sequence,
        ),
    );
    var right: LeasedPagedKVCache = .{};
    try right.init(
        &bank,
        &shared_tree,
        right_scope_open.scope,
        &right_cache,
        &right_bindings,
        request_epoch,
        session_id,
        &publication_sequence,
    );
    // The coordinator is an address-bound single-writer capability. A
    // by-value copy made before terminal sealing must be inert forever.
    var copied_left = left;
    try testing.expectError(
        error.InvalidCoordinator,
        copied_left.planNextRow(),
    );

    const stale_left_plan = try left.planNextRow();
    const right_txn = try appendScalarTestRow(&right, 2);
    try testing.expectError(
        error.InvalidLeasedPlan,
        left.beginRowPlanned(stale_left_plan),
    );
    const left_empty_root = left_cache.root();
    const first_left_plan = try left.planNextRow();
    const left_txn = try left.beginRowPlanned(first_left_plan);
    const first_key = [_]f32{1};
    const first_value = [_]f32{-1};
    try testing.expectError(
        error.InvalidCoordinator,
        copied_left.appendRowTxn(
            left_txn,
            0,
            &first_key,
            &first_value,
        ),
    );
    _ = try left.appendRowTxn(left_txn, 0, &first_key, &first_value);
    _ = try left.commitRowTxn(left_txn);
    try testing.expectError(
        error.InvalidLeasedTransaction,
        left.commitRowTxn(left_txn),
    );
    var second_left_page_ref: paged_kv.PageRefV1 = undefined;
    for (1..17) |row_index| {
        const row_value: f32 = @floatFromInt(row_index + 1);
        const row_txn = try appendScalarTestRow(&left, row_value);
        if (row_index == 16) second_left_page_ref = row_txn.mark.page_ref;
    }
    const left_root = left_cache.root();
    const left_page_ref = left_txn.mark.page_ref;
    const page_bytes: u64 = @intCast(left_cache.capacityLedger().page_payload_bytes);
    try testing.expectEqual(@as(u64, 3 * page_bytes), shared_tree.current.kv_bytes);
    try testing.expectEqual(@as(u32, 2), (try left.bindingSummary()).count);
    try testing.expectEqual(@as(u32, 1), (try right.bindingSummary()).count);
    try testing.expectEqual(
        map_outstanding + 3 * page_bytes,
        tracking.allocated_bytes - tracking.freed_bytes,
    );

    // Membership is exact, not merely a digest of whichever entries happen
    // to be present: order, omission, and an extra forged slot all fail.
    std.mem.swap(
        PageLeaseBindingV1,
        &left_bindings[0],
        &left_bindings[1],
    );
    try testing.expectError(error.InvalidBinding, left.bindingSummary());
    std.mem.swap(
        PageLeaseBindingV1,
        &left_bindings[0],
        &left_bindings[1],
    );
    const saved_second_binding = left_bindings[1];
    left_bindings[1] = .{};
    try testing.expectError(error.InvalidBinding, left.bindingSummary());
    left_bindings[1] = saved_second_binding;
    var extra_binding = saved_second_binding;
    extra_binding.logical_page = 2;
    extra_binding.integrity = pageBindingIntegrity(extra_binding);
    left_bindings[2] = extra_binding;
    try testing.expectError(error.InvalidBinding, left.bindingSummary());
    left_bindings[2] = .{};

    // A mutation after planning is rejected before either PagedKV or Bank can
    // acquire new state; restoring the binding leaves the original usable.
    const mutation_plan = try left.planNextRow();
    const root_before_mutation_rejection = left_cache.root();
    const used_before_mutation_rejection = (try bank.snapshotV3()).used;
    left_bindings[1] = .{};
    try testing.expectError(
        error.InvalidBinding,
        left.beginRowPlanned(mutation_plan),
    );
    left_bindings[1] = saved_second_binding;
    try testing.expectEqualDeep(
        root_before_mutation_rejection,
        left_cache.root(),
    );
    try testing.expectEqualDeep(
        used_before_mutation_rejection,
        (try bank.snapshotV3()).used,
    );

    const left_digest = try left_cache.logicalKvSha256();
    try testing.expectError(
        error.InvalidRoot,
        left.sealTerminalForPublication(
            left_empty_root,
            left_digest,
            0,
            .eos,
            9,
        ),
    );
    try testing.expectError(
        error.InvalidCoordinator,
        copied_left.sealTerminalForPublication(
            left_root,
            left_digest,
            0,
            .eos,
            9,
        ),
    );
    const wrong_digest = [_]u8{0} ** 32;
    try testing.expectError(
        error.InvalidTerminalSeal,
        left.sealTerminalForPublication(
            left_root,
            wrong_digest,
            0,
            .eos,
            9,
        ),
    );
    const left_seal = try left.sealTerminalForPublication(
        left_root,
        left_digest,
        0,
        .eos,
        9,
    );
    try testing.expectEqual(@as(u32, 2), left_seal.bindings.count);
    try testing.expectEqual(2 * page_bytes, left_seal.bindings.payload_bytes);
    try testing.expectEqual(@as(u64, 1), publication_sequence);
    try testing.expectError(
        error.TerminalRequired,
        right.beginTerminalReclaim(left_seal, 1),
    );
    var wrong_scope_seal = left_seal;
    wrong_scope_seal.scope_index = right_scope_open.scope.node_index;
    wrong_scope_seal.digest = terminalSealDigest(wrong_scope_seal);
    try testing.expectError(
        error.InvalidTerminalSeal,
        left.beginTerminalReclaim(wrong_scope_seal, 1),
    );

    const right_root = right_cache.root();
    const right_digest = try right_cache.logicalKvSha256();
    const right_seal = try right.sealTerminalForPublication(
        right_root,
        right_digest,
        1,
        .max_tokens,
        10,
    );
    try testing.expectEqual(@as(u32, 1), right_seal.bindings.count);
    try testing.expectEqual(page_bytes, right_seal.bindings.payload_bytes);
    try testing.expectEqual(@as(u64, 2), publication_sequence);
    try testing.expectError(
        error.InvalidCoordinator,
        copied_left.beginTerminalReclaim(left_seal, 2),
    );

    // Left published first, but retirement deliberately waits until the
    // sibling has published too; reclaim consumes the current cohort sequence.
    const left_freed = try left.beginTerminalReclaim(left_seal, 2);
    try testing.expectError(
        error.InvalidRoot,
        left_cache.validateCurrentRoot(left_root),
    );
    try testing.expectError(
        error.InvalidPageRef,
        left_cache.validateCommittedPageRef(left_page_ref),
    );
    try testing.expectError(
        error.InvalidPageRef,
        left_cache.validateCommittedPageRef(second_left_page_ref),
    );
    try testing.expect(left_cache.isRetired());
    try testing.expectEqual(
        map_outstanding + page_bytes,
        tracking.allocated_bytes - tracking.freed_bytes,
    );
    var snapshot = try bank.snapshotV3();
    try testing.expectEqual(@as(u64, 3 * page_bytes), snapshot.used.kv_bytes);
    try testing.expectEqual(@as(usize, 2), snapshot.free_authorized_allocations);

    var forged_freed = left_freed;
    forged_freed.payload_bytes += 1;
    forged_freed.integrity = freedPayloadIntegrity(forged_freed);
    try testing.expectError(
        error.InvalidFreedPayload,
        left.commitReclaimAfterFree(forged_freed),
    );
    try testing.expectEqual(@as(u64, 3 * page_bytes), (try bank.snapshotV3()).used.kv_bytes);
    _ = try left.commitReclaimAfterFree(left_freed);
    try testing.expectError(
        error.ReclaimComplete,
        left.commitReclaimAfterFree(left_freed),
    );
    snapshot = try bank.snapshotV3();
    try testing.expectEqual(page_bytes, snapshot.used.kv_bytes);
    try testing.expectEqual(@as(usize, 1), snapshot.live_allocations);

    try testing.expectError(
        error.InvalidTerminalSeal,
        left.beginTerminalReclaim(right_seal, 2),
    );
    const right_freed = try right.beginTerminalReclaim(right_seal, 2);
    try testing.expectEqual(
        map_outstanding,
        tracking.allocated_bytes - tracking.freed_bytes,
    );
    _ = try right.commitReclaimAfterFree(right_freed);
    try testing.expectEqual(@as(u64, 0), shared_tree.current.kv_bytes);
    try bank.closePublicationSession(
        parent,
        request_epoch,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(shared_tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshotV3()).used.isZero());

    left_cache.deinit();
    right_cache.deinit();
    caches_live = false;
    try testing.expectEqual(
        tracking.allocated_bytes,
        tracking.freed_bytes,
    );
    _ = right_txn;
}

test "leased allocation OOM aborts Bank reservation and can retry" {
    const testing = std.testing;
    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 3;
    var bank = try resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 256, .queue_slots = 1 },
        0x4c50_4343,
    );
    const parent = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    var shared_tree = try bank.openLeaseTree(
        parent,
        1,
        2,
        .{ .kv_bytes = 256 },
    );
    const scope_open = try bank.openScope(
        shared_tree,
        3,
        4,
        .{ .kv_bytes = 256 },
    );
    shared_tree = scope_open.tree;
    var coordinator_byte: u8 = 0;
    const session_id = @intFromPtr(&coordinator_byte);
    const request_epoch: u64 = 5;
    var publication_sequence: u64 = 0;
    try bank.bindPublicationSessionWithTree(
        shared_tree,
        request_epoch,
        session_id,
    );

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var cache = try paged_kv.PagedKVCache.init(
        failing.allocator(),
        1,
        1,
        16,
    );
    defer cache.deinit();
    const map_outstanding = failing.allocated_bytes - failing.freed_bytes;
    var bindings = [_]PageLeaseBindingV1{.{}} ** 1;
    var leased: LeasedPagedKVCache = .{};
    try leased.init(
        &bank,
        &shared_tree,
        scope_open.scope,
        &cache,
        &bindings,
        request_epoch,
        session_id,
        &publication_sequence,
    );
    const failed_plan = try leased.planNextRow();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        leased.beginRowPlanned(failed_plan),
    );
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(map_outstanding, failing.allocated_bytes - failing.freed_bytes);
    try testing.expectEqual(@as(u32, 0), (try leased.bindingSummary()).count);
    try testing.expectEqual(@as(usize, 0), (try cache.allocationCommitmentLedger()).allocated_pages);
    var snapshot = try bank.snapshotV3();
    try testing.expectEqual(@as(u64, 0), snapshot.used.kv_bytes);
    try testing.expectEqual(@as(u64, 1), snapshot.lease_allocation_reserves);
    try testing.expectEqual(@as(u64, 1), snapshot.lease_allocation_aborts);
    try testing.expectError(
        error.InvalidLeasedPlan,
        leased.beginRowPlanned(failed_plan),
    );

    failing.fail_index = std.math.maxInt(usize);
    const page_bytes: u64 = @intCast(cache.capacityLedger().page_payload_bytes);
    const retry_plan = try leased.planNextRow();
    const aborted = try leased.beginRowPlanned(retry_plan);
    const allocation_index_after_page = failing.alloc_index;
    try leased.abortRowTxn(aborted);
    try testing.expectEqual(@as(u32, 1), (try leased.bindingSummary()).count);
    try testing.expectEqual(page_bytes, (try bank.snapshotV3()).used.kv_bytes);
    try testing.expectError(
        error.InvalidPageRef,
        cache.validateCommittedPageRef(aborted.mark.page_ref),
    );
    const reuse_plan = try leased.planNextRow();
    try testing.expectEqual(@as(usize, 0), reuse_plan.cache_plan.allocation_bytes);
    const txn = try appendScalarTestRow(&leased, 7);
    try testing.expectEqual(allocation_index_after_page, failing.alloc_index);
    try testing.expectEqual(map_outstanding + page_bytes, failing.allocated_bytes - failing.freed_bytes);
    const root = cache.root();
    const digest = try cache.logicalKvSha256();
    const seal = try leased.sealTerminalForPublication(
        root,
        digest,
        0,
        .cancelled,
        0,
    );
    const freed = try leased.beginTerminalReclaim(seal, 1);
    try testing.expectEqual(map_outstanding, failing.allocated_bytes - failing.freed_bytes);
    snapshot = try bank.snapshotV3();
    try testing.expectEqual(page_bytes, snapshot.used.kv_bytes);
    _ = try leased.commitReclaimAfterFree(freed);
    try bank.closePublicationSession(
        parent,
        request_epoch,
        session_id,
        publication_sequence,
    );
    try bank.closeLeaseTree(shared_tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshotV3()).used.isZero());
    _ = txn;
}

test "prepared token row and terminal v3 bind one exact publication" {
    const testing = std.testing;
    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 1;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 3;
    var bank = try resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 256, .queue_slots = 1 },
        0x4c50_4350,
    );
    const parent = try bank.commit(try bank.reserve(
        21,
        .{ .queue_slots = 1 },
    ));
    var tree = try bank.openLeaseTree(
        parent,
        22,
        23,
        .{ .kv_bytes = 256 },
    );
    const opened = try bank.openScope(
        tree,
        24,
        25,
        .{ .kv_bytes = 256 },
    );
    tree = opened.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    const request_epoch: u64 = 26;
    var sequence: u64 = 0;
    try bank.bindPublicationSessionWithTree(tree, request_epoch, session_id);

    var cache = try paged_kv.PagedKVCache.init(testing.allocator, 1, 1, 16);
    defer cache.deinit();
    var bindings = [_]PageLeaseBindingV1{.{}} ** 1;
    var leased: LeasedPagedKVCache = .{};
    try leased.init(
        &bank,
        &tree,
        opened.scope,
        &cache,
        &bindings,
        request_epoch,
        session_id,
        &sequence,
    );
    const row_plan = try leased.planNextRow();
    const row_txn = try leased.beginRowPlanned(row_plan);
    const key = [_]f32{3};
    const value = [_]f32{-3};
    _ = try leased.appendRowTxn(row_txn, 0, &key, &value);
    const prepared = try leased.prepareTokenRow(row_txn, true);
    try leased.revalidatePreparedTokenRow(prepared);
    try testing.expectEqual(@as(u32, 1), prepared.allocation_set.count);
    try testing.expectEqual(
        prepared.bindings.payload_bytes,
        prepared.allocation_set.payload_bytes,
    );

    var forged = prepared;
    forged.canonical_after_sha256[0] ^= 1;
    forged.integrity = preparedTokenRowIntegrity(forged);
    try testing.expectError(
        error.InvalidPreparedTokenRow,
        leased.revalidatePreparedTokenRow(forged),
    );

    const permit = try bank.beginPublicationWithTree(
        tree,
        request_epoch,
        session_id,
        sequence,
    );
    const output_digest = [_]u8{7} ** 32;
    const terminal_plan = try leased.planTerminalForTokenTxn(
        prepared,
        sequence,
        permit.generation,
        .eos,
        0,
        .{ 1, 2, 3, 4 },
        9,
        output_digest,
    );
    leased.commitPreparedTokenRowAssumeValid(prepared);
    bank.commitPublicationAssumeValid(permit);
    sequence += 1;
    const proposal_digest = [_]u8{8} ** 32;
    const commit_digest = [_]u8{9} ** 32;
    const seal = leased.finalizeTerminalAssumePublished(
        terminal_plan,
        proposal_digest,
        commit_digest,
    );
    try testing.expectEqual(LeaseLifecycle.terminal_retained, try leased.lifecycle());
    try testing.expectEqual(@as(u64, 0), seal.transaction_sequence);
    try testing.expectEqual(permit.generation, seal.permit_generation);
    try testing.expectEqualDeep(output_digest, seal.output_sha256);
    try testing.expectEqualDeep(proposal_digest, seal.proposal_sha256);
    try testing.expectEqualDeep(commit_digest, seal.commit_sha256);

    var forged_seal = seal;
    forged_seal.allocation_set.sha256[0] ^= 1;
    forged_seal.digest = terminalSealV3Digest(forged_seal);
    try testing.expectError(
        error.InvalidTerminalSeal,
        leased.beginTerminalReclaimV3(forged_seal, sequence),
    );
    const freed = try leased.beginTerminalReclaimV3(seal, sequence);
    try testing.expectEqual(@as(u32, 1), freed.binding_count);
    _ = try leased.commitReclaimAfterFree(freed);
    try testing.expectEqual(LeaseLifecycle.reclaimed, try leased.lifecycle());

    try bank.closePublicationSession(parent, request_epoch, session_id, sequence);
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshotV3()).used.isZero());
}

test "teardown reclaims active reusable and empty leased scopes" {
    const testing = std.testing;
    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var roots = [_]resource_bank.LeaseTreeRootSlot{.{}} ** 1;
    var nodes = [_]resource_bank.LeaseNodeSlot{.{}} ** 5;
    var bank = try resource_bank.Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 512, .queue_slots = 1 },
        0x4c50_4351,
    );
    const parent = try bank.commit(try bank.reserve(
        31,
        .{ .queue_slots = 1 },
    ));
    var tree = try bank.openLeaseTree(
        parent,
        32,
        33,
        .{ .kv_bytes = 512 },
    );
    const live_open = try bank.openScope(
        tree,
        34,
        35,
        .{ .kv_bytes = 256 },
    );
    tree = live_open.tree;
    const empty_open = try bank.openScope(
        tree,
        36,
        37,
        .{ .kv_bytes = 256 },
    );
    tree = empty_open.tree;
    var session_byte: u8 = 0;
    const session_id = @intFromPtr(&session_byte);
    const request_epoch: u64 = 38;
    var sequence: u64 = 0;
    try bank.bindPublicationSessionWithTree(tree, request_epoch, session_id);

    var live_cache = try paged_kv.PagedKVCache.init(testing.allocator, 1, 1, 16);
    defer live_cache.deinit();
    var empty_cache = try paged_kv.PagedKVCache.init(testing.allocator, 1, 1, 16);
    defer empty_cache.deinit();
    var live_bindings = [_]PageLeaseBindingV1{.{}} ** 1;
    var empty_bindings = [_]PageLeaseBindingV1{.{}} ** 1;
    var live: LeasedPagedKVCache = .{};
    var empty: LeasedPagedKVCache = .{};
    try live.init(
        &bank,
        &tree,
        live_open.scope,
        &live_cache,
        &live_bindings,
        request_epoch,
        session_id,
        &sequence,
    );
    try empty.init(
        &bank,
        &tree,
        empty_open.scope,
        &empty_cache,
        &empty_bindings,
        request_epoch,
        session_id,
        &sequence,
    );
    const plan = try live.planNextRow();
    const txn = try live.beginRowPlanned(plan);
    const key = [_]f32{5};
    const value = [_]f32{-5};
    _ = try live.appendRowTxn(txn, 0, &key, &value);
    try testing.expect((try bank.snapshotV3()).used.kv_bytes != 0);

    try live.reclaimForTeardown(sequence);
    try empty.reclaimForTeardown(sequence);
    try testing.expect(live_cache.isRetired());
    try testing.expect(empty_cache.isRetired());
    try testing.expectEqual(@as(u64, 0), tree.current.kv_bytes);
    try bank.closePublicationSession(parent, request_epoch, session_id, sequence);
    try bank.closeLeaseTree(tree);
    try bank.release(parent);
    try testing.expect((try bank.snapshotV3()).used.isZero());
}
