//! Exact FP32 paged KV-cache ownership foundation.
//!
//! Each allocator-backed page is one 16-position bundle containing K and V for
//! every layer. The page table is allocated at cache construction, while page
//! payload commitments are materialized only when their first row is reached.
//! These byte ledgers describe allocator-visible commitments; they do not claim
//! that every byte is currently backed by an OS physical page or present in
//! process RSS.
//!
//! Page-map publication is deliberately request-local and single-writer. A row
//! transaction may write private bytes, but the committed root is the sole
//! visibility boundary. There is no lock-free reader reclamation contract in
//! this module; cross-worker immutable roots belong to a later layer.

const std = @import("std");

pub const page_positions: usize = 16;
pub const abi: u64 = 0x4750_4b56_0000_0001;
pub const page_ref_abi: u64 = 0x4750_5246_0000_0001;
pub const page_map_root_abi: u64 = 0x4750_4d52_0000_0001;
pub const row_txn_abi: u64 = 0x4750_5254_0000_0001;
pub const row_allocation_plan_abi: u64 = 0x4750_4150_0000_0001;
pub const retirement_reclaim_plan_abi: u64 = 0x4750_5250_0000_0001;
pub const Digest = [32]u8;

pub const Error = std.mem.Allocator.Error || error{
    CacheFull,
    CacheRetired,
    GenerationExhausted,
    InvalidPageRef,
    InvalidAllocationPlan,
    InvalidRoot,
    InvalidTransaction,
    ShapeMismatch,
    TransactionActive,
    TransactionIncomplete,
};

/// One fixed-capacity page-table entry. The payload length and geometry are
/// cache-wide, so storing a many pointer instead of a slice removes redundant
/// per-page lengths. `ownership_generation == 0` means the resident payload is
/// absent or reusable and is not owned by any published root.
const PageEntry = struct {
    payload: ?[*]align(64) f32 = null,
    ownership_generation: u64 = 0,
};

comptime {
    if (@sizeOf(PageEntry) != 16)
        @compileError("PagedKV v1 requires a 16-byte PageEntry");
}

pub const PageRefV1 = struct {
    abi_version: u64 = page_ref_abi,
    cache_instance: u64,
    logical_page: u64,
    ownership_generation: u64,
};

/// A copied logical root contains no allocator address. The ownership digest
/// commits to the ordered PageRef chain and geometry, not to K/V contents.
pub const PageMapRootV1 = struct {
    abi_version: u64 = page_map_root_abi,
    cache_instance: u64,
    generation: u64,
    committed_len: u64,
    committed_pages: u64,
    ownership_sha256: Digest,
};

/// Exact caller-visible capacity allocation, excluding allocator metadata and
/// padding just as the contiguous KV ledger does.
pub const CapacityLedger = struct {
    page_count_capacity: usize,
    page_elements: usize,
    page_payload_bytes: usize,
    tensor_capacity_bytes: usize,
    page_map_bytes: usize,
    allocation_capacity_bytes: usize,
    contiguous_counterfactual_bytes: usize,
    capacity_reclaimed_bytes: usize,
    capacity_overhead_bytes: usize,
    padded_positions: usize,
};

/// Dynamic allocator-backed page commitment. The historical `ResidentLedger`
/// type and field names remain public for ABI/source compatibility, but these
/// values are not an OS residency/RSS measurement. Aborted and reset bundles
/// retained for reuse remain allocated and are therefore never hidden here.
pub const ResidentLedger = struct {
    page_count_capacity: usize,
    allocated_pages: usize,
    committed_pages: usize,
    provisional_pages: usize,
    reusable_pages: usize,
    page_map_bytes: usize,
    resident_tensor_payload_bytes: usize,
    resident_allocation_bytes: usize,
    committed_tensor_payload_bytes: usize,
};

/// Preferred semantic name for new admission code. This is an alias so all
/// existing public fields remain unchanged.
pub const AllocationCommitmentLedger = ResidentLedger;

/// Immutable precondition for charging the next row's allocator commitment.
/// `allocation_bytes` is exactly zero or one full page payload. A caller may
/// grow an external ResourceBank child lease by this amount, then pass the same
/// value to `beginRowPlanned`; the cache revalidates every cursor and generation
/// before allocating. This does not attest to OS physical residency.
pub const RowAllocationPlanV1 = struct {
    abi_version: u64 = row_allocation_plan_abi,
    cache_id: usize,
    cache_instance: u64,
    base_len: usize,
    logical_page: usize,
    row_in_page: usize,
    root_generation: u64,
    row_txn_generation: u64,
    root_after_generation: u64,
    page_ownership_generation: u64,
    next_page_ownership_generation: u64,
    allocated_pages: usize,
    page_payload_present: bool,
    allocation_bytes: usize,
};

/// Exact, single-use free-before-uncharge plan for a terminal request-local
/// cache. The caller must bind the terminal root/state into its publication
/// receipt before applying this plan. Applying it invalidates every prior root
/// and PageRef, frees every page payload, and retains only the fixed page map.
/// The returned byte count is allocator commitment, not an OS residency claim.
pub const RetirementReclaimPlanV1 = struct {
    abi_version: u64 = retirement_reclaim_plan_abi,
    cache_id: usize,
    cache_instance: u64,
    root: PageMapRootV1,
    committed_len: usize,
    allocated_pages: usize,
    page_payload_bytes: usize,
    payload_bytes_to_free: usize,
    next_root_generation: u64,
};

pub fn deriveCapacityLedger(
    num_layers: usize,
    dim: usize,
    max_seq: usize,
) Error!CapacityLedger {
    if (num_layers == 0 or dim == 0 or max_seq == 0)
        return error.ShapeMismatch;

    const page_count = max_seq / page_positions +
        @intFromBool(max_seq % page_positions != 0);
    const rounded_positions = std.math.mul(
        usize,
        page_count,
        page_positions,
    ) catch return error.ShapeMismatch;
    const layer_page_elements = std.math.mul(
        usize,
        page_positions,
        dim,
    ) catch return error.ShapeMismatch;
    const page_elements = std.math.mul(
        usize,
        std.math.mul(usize, num_layers, 2) catch
            return error.ShapeMismatch,
        layer_page_elements,
    ) catch return error.ShapeMismatch;
    const page_payload_bytes = std.math.mul(
        usize,
        page_elements,
        @sizeOf(f32),
    ) catch return error.ShapeMismatch;
    const tensor_capacity_bytes = std.math.mul(
        usize,
        page_count,
        page_payload_bytes,
    ) catch return error.ShapeMismatch;
    const page_map_bytes = std.math.mul(
        usize,
        page_count,
        @sizeOf(PageEntry),
    ) catch return error.ShapeMismatch;
    const allocation_capacity_bytes = std.math.add(
        usize,
        tensor_capacity_bytes,
        page_map_bytes,
    ) catch return error.ShapeMismatch;

    const contiguous_row_elements = std.math.mul(
        usize,
        max_seq,
        dim,
    ) catch return error.ShapeMismatch;
    const contiguous_tensor_bytes = std.math.mul(
        usize,
        std.math.mul(
            usize,
            std.math.mul(usize, num_layers, 2) catch
                return error.ShapeMismatch,
            contiguous_row_elements,
        ) catch return error.ShapeMismatch,
        @sizeOf(f32),
    ) catch return error.ShapeMismatch;
    const contiguous_descriptor_bytes = std.math.mul(
        usize,
        std.math.mul(usize, num_layers, 2) catch
            return error.ShapeMismatch,
        @sizeOf([]f32),
    ) catch return error.ShapeMismatch;
    const contiguous_counterfactual_bytes = std.math.add(
        usize,
        contiguous_tensor_bytes,
        contiguous_descriptor_bytes,
    ) catch return error.ShapeMismatch;

    return .{
        .page_count_capacity = page_count,
        .page_elements = page_elements,
        .page_payload_bytes = page_payload_bytes,
        .tensor_capacity_bytes = tensor_capacity_bytes,
        .page_map_bytes = page_map_bytes,
        .allocation_capacity_bytes = allocation_capacity_bytes,
        .contiguous_counterfactual_bytes = contiguous_counterfactual_bytes,
        .capacity_reclaimed_bytes = contiguous_counterfactual_bytes -|
            allocation_capacity_bytes,
        .capacity_overhead_bytes = allocation_capacity_bytes -|
            contiguous_counterfactual_bytes,
        .padded_positions = rounded_positions - max_seq,
    };
}

pub const RowTxnMark = struct {
    abi_version: u64 = row_txn_abi,
    cache_id: usize,
    cache_instance: u64,
    generation: u64,
    base_len: usize,
    row_count: usize = 1,
    root_before_generation: u64,
    root_after_generation: u64,
    page_ref: PageRefV1,
};

pub const PreparedRowCommit = struct {
    abi_version: u64 = row_txn_abi,
    mark: RowTxnMark,
    root_before: PageMapRootV1,
    root_after: PageMapRootV1,
    installs_new_page: bool,
};

const ActiveRowTxn = struct {
    mark: RowTxnMark,
    root_before: PageMapRootV1,
    root_after: PageMapRootV1,
    page_index: usize,
    row_in_page: usize,
    installs_new_page: bool,
    next_layer: usize = 0,
};

const NextRowState = struct {
    page_index: usize,
    row_in_page: usize,
    installs_new_page: bool,
};

var next_cache_instance = std.atomic.Value(u64).init(1);

fn reserveCacheInstance() Error!u64 {
    var current = next_cache_instance.load(.monotonic);
    while (true) {
        if (current == 0 or current == std.math.maxInt(u64))
            return error.GenerationExhausted;
        if (next_cache_instance.cmpxchgWeak(
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

fn emptyOwnershipDigest(
    cache_instance: u64,
    num_layers: usize,
    dim: usize,
    max_seq: usize,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-kv-ownership-v1\x00");
    hashU64(&hash, cache_instance);
    hashU64(&hash, @intCast(num_layers));
    hashU64(&hash, @intCast(dim));
    hashU64(&hash, @intCast(max_seq));
    hashU64(&hash, page_positions);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn appendOwnershipDigest(before: Digest, page_ref: PageRefV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-paged-kv-root-append-v1\x00");
    hash.update(&before);
    hashU64(&hash, page_ref.abi_version);
    hashU64(&hash, page_ref.cache_instance);
    hashU64(&hash, page_ref.logical_page);
    hashU64(&hash, page_ref.ownership_generation);
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

/// Borrowed page-local rows. A span is valid only until the next mutation of
/// its cache; it must not be retained across begin/append/commit/abort/reset or
/// deinit. Cross-worker retention requires a future pinned-root/reclamation ABI.
pub const PageSpan = struct {
    logical_start: usize,
    row_count: usize,
    page_ref: PageRefV1,
    keys: []const f32,
    values: []const f32,
};

pub const LayerPrefix = struct {
    abi_version: u64 = abi,
    cache: *const PagedKVCache,
    cache_id: usize,
    cache_instance: u64,
    root_generation: u64,
    txn_generation: u64,
    layer: usize,
    positions: usize,
    page_count: usize,

    pub fn iterator(self: LayerPrefix) Error!PageSpanIterator {
        try self.validate();
        return .{ .prefix = self };
    }

    pub fn keyRow(self: LayerPrefix, position: usize) Error![]const f32 {
        return self.row(.key, position);
    }

    pub fn valueRow(self: LayerPrefix, position: usize) Error![]const f32 {
        return self.row(.value, position);
    }

    fn row(
        self: LayerPrefix,
        kind: enum { key, value },
        position: usize,
    ) Error![]const f32 {
        try self.validate();
        if (position >= self.positions) return error.ShapeMismatch;
        const page_index = position / page_positions;
        const row_in_page = position % page_positions;
        const entry = try self.cache.entryForPrefix(self, page_index);
        const start = try self.cache.payloadOffset(
            self.layer,
            kind == .value,
            row_in_page,
        );
        return entry.payload.?[start .. start + self.cache.dim];
    }

    fn validate(self: LayerPrefix) Error!void {
        if (self.abi_version != abi or
            self.cache_id != @intFromPtr(self.cache) or
            self.cache_instance != self.cache.instance_id or
            self.cache.retired or
            self.layer >= self.cache.num_layers or
            self.positions > self.cache.max_seq or
            self.page_count > self.cache.entries.len)
            return error.InvalidTransaction;

        if (self.txn_generation == 0) {
            const root = self.cache.committed_root;
            if (root.generation != self.root_generation or
                root.committed_len != self.positions or
                root.committed_pages != self.page_count)
                return error.InvalidRoot;
            return;
        }

        const active = try self.cache.validateRowTxnGeneration(
            self.txn_generation,
        );
        if (active.root_after.generation != self.root_generation or
            active.root_after.committed_len != self.positions or
            active.root_after.committed_pages != self.page_count or
            self.layer >= active.next_layer)
            return error.InvalidTransaction;
    }
};

pub const PageSpanIterator = struct {
    prefix: LayerPrefix,
    next_position: usize = 0,

    pub fn next(self: *PageSpanIterator) Error!?PageSpan {
        try self.prefix.validate();
        if (self.next_position == self.prefix.positions) return null;
        if (self.next_position > self.prefix.positions)
            return error.InvalidTransaction;

        const logical_start = self.next_position;
        const page_index = logical_start / page_positions;
        const row_in_page = logical_start % page_positions;
        const rows = @min(
            page_positions - row_in_page,
            self.prefix.positions - logical_start,
        );
        const entry = try self.prefix.cache.entryForPrefix(
            self.prefix,
            page_index,
        );
        const key_start = try self.prefix.cache.payloadOffset(
            self.prefix.layer,
            false,
            row_in_page,
        );
        const value_start = try self.prefix.cache.payloadOffset(
            self.prefix.layer,
            true,
            row_in_page,
        );
        const element_count = std.math.mul(
            usize,
            rows,
            self.prefix.cache.dim,
        ) catch return error.ShapeMismatch;
        self.next_position += rows;
        return .{
            .logical_start = logical_start,
            .row_count = rows,
            .page_ref = self.prefix.cache.pageRef(page_index),
            .keys = entry.payload.?[key_start .. key_start + element_count],
            .values = entry.payload.?[value_start .. value_start + element_count],
        };
    }
};

pub const PagedKVCache = struct {
    allocator: std.mem.Allocator,
    num_layers: usize,
    dim: usize,
    max_seq: usize,
    entries: []PageEntry,
    capacity_ledger: CapacityLedger,
    instance_id: u64,
    committed_root: PageMapRootV1,
    len: usize = 0,
    allocated_pages: usize = 0,
    next_row_txn_generation: u64 = 1,
    next_root_generation: u64 = 2,
    next_page_generation: u64 = 1,
    active_row_txn: ?ActiveRowTxn = null,
    retired: bool = false,
    leased_coordinator_instance: u64 = 0,
    leased_coordinator_address: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        num_layers: usize,
        dim: usize,
        max_seq: usize,
    ) Error!PagedKVCache {
        const ledger = try deriveCapacityLedger(num_layers, dim, max_seq);
        const instance_id = try reserveCacheInstance();
        const entries = try allocator.alloc(
            PageEntry,
            ledger.page_count_capacity,
        );
        @memset(entries, .{});
        return .{
            .allocator = allocator,
            .num_layers = num_layers,
            .dim = dim,
            .max_seq = max_seq,
            .entries = entries,
            .capacity_ledger = ledger,
            .instance_id = instance_id,
            .committed_root = .{
                .cache_instance = instance_id,
                .generation = 1,
                .committed_len = 0,
                .committed_pages = 0,
                .ownership_sha256 = emptyOwnershipDigest(
                    instance_id,
                    num_layers,
                    dim,
                    max_seq,
                ),
            },
        };
    }

    pub fn deinit(self: *PagedKVCache) void {
        for (self.entries) |entry| {
            if (entry.payload) |payload|
                self.allocator.free(payload[0..self.capacity_ledger.page_elements]);
        }
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn capacityLedger(self: *const PagedKVCache) CapacityLedger {
        return self.capacity_ledger;
    }

    pub fn allocationCommitmentLedger(
        self: *const PagedKVCache,
    ) Error!AllocationCommitmentLedger {
        const provisional_pages: usize = if (self.active_row_txn) |active|
            @intFromBool(active.installs_new_page)
        else
            0;
        const committed_pages: usize = @intCast(
            self.committed_root.committed_pages,
        );
        if (committed_pages + provisional_pages > self.allocated_pages)
            return error.InvalidRoot;
        const reusable_pages = self.allocated_pages -
            committed_pages - provisional_pages;
        const resident_tensor_payload_bytes = std.math.mul(
            usize,
            self.allocated_pages,
            self.capacity_ledger.page_payload_bytes,
        ) catch return error.ShapeMismatch;
        const resident_allocation_bytes = std.math.add(
            usize,
            self.capacity_ledger.page_map_bytes,
            resident_tensor_payload_bytes,
        ) catch return error.ShapeMismatch;
        const committed_row_elements = std.math.mul(
            usize,
            self.len,
            self.dim,
        ) catch return error.ShapeMismatch;
        const committed_tensor_payload_bytes = std.math.mul(
            usize,
            std.math.mul(
                usize,
                std.math.mul(usize, self.num_layers, 2) catch
                    return error.ShapeMismatch,
                committed_row_elements,
            ) catch return error.ShapeMismatch,
            @sizeOf(f32),
        ) catch return error.ShapeMismatch;
        return .{
            .page_count_capacity = self.entries.len,
            .allocated_pages = self.allocated_pages,
            .committed_pages = committed_pages,
            .provisional_pages = provisional_pages,
            .reusable_pages = reusable_pages,
            .page_map_bytes = self.capacity_ledger.page_map_bytes,
            .resident_tensor_payload_bytes = resident_tensor_payload_bytes,
            .resident_allocation_bytes = resident_allocation_bytes,
            .committed_tensor_payload_bytes = committed_tensor_payload_bytes,
        };
    }

    /// Compatibility spelling. Values report allocator-backed commitment, not
    /// observed OS physical residency or process RSS.
    pub fn residentLedger(self: *const PagedKVCache) Error!ResidentLedger {
        return self.allocationCommitmentLedger();
    }

    pub fn root(self: *const PagedKVCache) PageMapRootV1 {
        return self.committed_root;
    }

    pub fn isRetired(self: *const PagedKVCache) bool {
        return self.retired;
    }

    /// Bind the cache to one address-stable leased owner. This is deliberately
    /// a one-way lifetime claim: a retired cache is never reusable, and moving
    /// or losing the owner fails closed instead of allowing a replacement to
    /// inherit allocator authority.
    pub fn claimLeasedCoordinator(
        self: *PagedKVCache,
        coordinator_instance: u64,
        coordinator_address: usize,
    ) bool {
        if (coordinator_instance == 0 or coordinator_address == 0 or
            self.retired or self.leased_coordinator_instance != 0 or
            self.leased_coordinator_address != 0)
            return false;
        self.leased_coordinator_instance = coordinator_instance;
        self.leased_coordinator_address = coordinator_address;
        return true;
    }

    pub fn isLeasedCoordinator(
        self: *const PagedKVCache,
        coordinator_instance: u64,
        coordinator_address: usize,
    ) bool {
        return coordinator_instance != 0 and coordinator_address != 0 and
            self.leased_coordinator_instance == coordinator_instance and
            self.leased_coordinator_address == coordinator_address;
    }

    pub fn validateCurrentRoot(
        self: *const PagedKVCache,
        root_value: PageMapRootV1,
    ) Error!void {
        if (root_value.abi_version != page_map_root_abi or
            !std.meta.eql(root_value, self.committed_root))
            return error.InvalidRoot;
        if (self.retired) return error.CacheRetired;
    }

    pub fn validateCommittedPageRef(
        self: *const PagedKVCache,
        page_ref: PageRefV1,
    ) Error!void {
        if (page_ref.abi_version != page_ref_abi or
            page_ref.cache_instance != self.instance_id or
            page_ref.logical_page >= self.committed_root.committed_pages or
            page_ref.logical_page >= self.entries.len)
            return error.InvalidPageRef;
        const entry = self.entries[@intCast(page_ref.logical_page)];
        if (entry.payload == null or entry.ownership_generation == 0 or
            entry.ownership_generation != page_ref.ownership_generation)
            return error.InvalidPageRef;
    }

    /// Derive the exact allocator commitment required by the next row without
    /// mutating the cache. The plan is intentionally single-use state: any
    /// intervening begin/commit/abort/reset transition makes it stale.
    pub fn planNextRowAllocation(
        self: *const PagedKVCache,
    ) Error!RowAllocationPlanV1 {
        if (self.retired) return error.CacheRetired;
        const next = try self.validateNextRowState();
        const entry = self.entries[next.page_index];
        const page_payload_present = entry.payload != null;
        return .{
            .cache_id = @intFromPtr(self),
            .cache_instance = self.instance_id,
            .base_len = self.len,
            .logical_page = next.page_index,
            .row_in_page = next.row_in_page,
            .root_generation = self.committed_root.generation,
            .row_txn_generation = self.next_row_txn_generation,
            .root_after_generation = self.next_root_generation,
            .page_ownership_generation = entry.ownership_generation,
            .next_page_ownership_generation = self.next_page_generation,
            .allocated_pages = self.allocated_pages,
            .page_payload_present = page_payload_present,
            .allocation_bytes = if (next.installs_new_page and
                !page_payload_present)
                self.capacity_ledger.page_payload_bytes
            else
                0,
        };
    }

    /// Consume a previously charged allocation plan. Validation happens before
    /// allocator state, generations, roots, or counters can change.
    pub fn beginRowPlanned(
        self: *PagedKVCache,
        plan: RowAllocationPlanV1,
    ) Error!RowTxnMark {
        const expected = try self.planNextRowAllocation();
        if (plan.abi_version != row_allocation_plan_abi or
            !std.meta.eql(plan, expected))
            return error.InvalidAllocationPlan;
        return self.beginRowInternal();
    }

    /// Start one private row spanning every layer. Allocation may occur here,
    /// before any caller-provided row is copied or any root becomes visible.
    /// This compatibility entry point retains the original unplanned behavior.
    pub fn beginRow(self: *PagedKVCache) Error!RowTxnMark {
        if (self.retired) return error.CacheRetired;
        return self.beginRowInternal();
    }

    fn beginRowInternal(self: *PagedKVCache) Error!RowTxnMark {
        const next = try self.validateNextRowState();
        const page_index = next.page_index;
        const row_in_page = next.row_in_page;
        const installs_new_page = next.installs_new_page;

        if (installs_new_page and self.entries[page_index].payload == null) {
            const payload = try self.allocator.alignedAlloc(
                f32,
                .@"64",
                self.capacity_ledger.page_elements,
            );
            self.entries[page_index].payload = payload.ptr;
            self.allocated_pages += 1;
        }

        var page_ref = self.pageRef(page_index);
        if (installs_new_page) {
            const ownership_generation = self.next_page_generation;
            self.next_page_generation += 1;
            self.entries[page_index].ownership_generation =
                ownership_generation;
            page_ref = self.pageRef(page_index);
        } else if (self.entries[page_index].payload == null or
            self.entries[page_index].ownership_generation == 0)
        {
            return error.InvalidRoot;
        }

        const root_before = self.committed_root;
        const root_after: PageMapRootV1 = .{
            .cache_instance = self.instance_id,
            .generation = self.next_root_generation,
            .committed_len = @intCast(self.len + 1),
            .committed_pages = root_before.committed_pages +
                @intFromBool(installs_new_page),
            .ownership_sha256 = if (installs_new_page)
                appendOwnershipDigest(root_before.ownership_sha256, page_ref)
            else
                root_before.ownership_sha256,
        };
        self.next_root_generation += 1;
        const mark: RowTxnMark = .{
            .cache_id = @intFromPtr(self),
            .cache_instance = self.instance_id,
            .generation = self.next_row_txn_generation,
            .base_len = self.len,
            .root_before_generation = root_before.generation,
            .root_after_generation = root_after.generation,
            .page_ref = page_ref,
        };
        self.next_row_txn_generation += 1;
        self.active_row_txn = .{
            .mark = mark,
            .root_before = root_before,
            .root_after = root_after,
            .page_index = page_index,
            .row_in_page = row_in_page,
            .installs_new_page = installs_new_page,
        };
        return mark;
    }

    pub fn appendRowTxn(
        self: *PagedKVCache,
        mark: RowTxnMark,
        layer: usize,
        k_row: []const f32,
        v_row: []const f32,
    ) Error!usize {
        _ = try self.validateRowTxn(mark);
        const active = if (self.active_row_txn) |*value| value else unreachable;
        if (layer != active.next_layer or layer >= self.num_layers)
            return error.InvalidTransaction;
        if (k_row.len != self.dim or v_row.len != self.dim)
            return error.ShapeMismatch;
        const key_start = try self.payloadOffset(
            layer,
            false,
            active.row_in_page,
        );
        const value_start = try self.payloadOffset(
            layer,
            true,
            active.row_in_page,
        );
        const entry = &self.entries[active.page_index];
        const payload = entry.payload orelse return error.InvalidTransaction;
        @memcpy(payload[key_start .. key_start + self.dim], k_row);
        @memcpy(payload[value_start .. value_start + self.dim], v_row);
        active.next_layer += 1;
        return mark.base_len;
    }

    pub fn prepareCommit(
        self: *const PagedKVCache,
        mark: RowTxnMark,
    ) Error!PreparedRowCommit {
        const active = try self.validateRowTxnConst(mark);
        if (active.next_layer != self.num_layers)
            return error.TransactionIncomplete;
        return .{
            .mark = mark,
            .root_before = active.root_before,
            .root_after = active.root_after,
            .installs_new_page = active.installs_new_page,
        };
    }

    /// Infallible publication after `prepareCommit`. The cache is request-local;
    /// callers must not introduce concurrent readers around this assignment.
    pub fn commitPreparedAssumeValid(
        self: *PagedKVCache,
        prepared: PreparedRowCommit,
    ) void {
        const expected = self.prepareCommit(prepared.mark) catch
            @panic("invalid prepared paged KV row transaction");
        if (prepared.abi_version != row_txn_abi or
            !std.meta.eql(prepared, expected) or
            !std.meta.eql(self.committed_root, prepared.root_before) or
            prepared.root_after.committed_len != self.len + 1)
            @panic("invalid prepared paged KV row transaction");
        self.committed_root = prepared.root_after;
        self.len += 1;
        self.active_row_txn = null;
    }

    pub fn commitRowTxn(
        self: *PagedKVCache,
        mark: RowTxnMark,
    ) Error!void {
        const prepared = try self.prepareCommit(mark);
        self.commitPreparedAssumeValid(prepared);
    }

    pub fn abortRow(
        self: *PagedKVCache,
        mark: RowTxnMark,
    ) Error!void {
        const active = try self.validateRowTxn(mark);
        if (active.installs_new_page) {
            const entry = &self.entries[active.page_index];
            if (entry.ownership_generation !=
                active.mark.page_ref.ownership_generation)
                return error.InvalidPageRef;
            entry.ownership_generation = 0;
        }
        self.active_row_txn = null;
    }

    /// Reset invalidates every published root and PageRef but retains all page
    /// payloads as counted reusable resident allocation.
    pub fn reset(self: *PagedKVCache) Error!void {
        if (self.retired) return error.CacheRetired;
        if (self.active_row_txn != null) return error.TransactionActive;
        if (!generationAvailable(self.next_root_generation))
            return error.GenerationExhausted;
        for (self.entries) |*entry| entry.ownership_generation = 0;
        self.committed_root = .{
            .cache_instance = self.instance_id,
            .generation = self.next_root_generation,
            .committed_len = 0,
            .committed_pages = 0,
            .ownership_sha256 = emptyOwnershipDigest(
                self.instance_id,
                self.num_layers,
                self.dim,
                self.max_seq,
            ),
        };
        self.next_root_generation += 1;
        self.len = 0;
    }

    /// Prepare an exact terminal-cache reclamation without mutation. Plans are
    /// invalidated by every row/root transition and by a prior reclaim.
    pub fn planRetirementReclaim(
        self: *const PagedKVCache,
    ) Error!RetirementReclaimPlanV1 {
        if (self.retired) return error.CacheRetired;
        if (self.active_row_txn != null) return error.TransactionActive;
        if (!generationAvailable(self.next_root_generation))
            return error.GenerationExhausted;
        try self.validateRetirementCommitment();
        const payload_bytes = std.math.mul(
            usize,
            self.allocated_pages,
            self.capacity_ledger.page_payload_bytes,
        ) catch return error.ShapeMismatch;
        return .{
            .cache_id = @intFromPtr(self),
            .cache_instance = self.instance_id,
            .root = self.committed_root,
            .committed_len = self.len,
            .allocated_pages = self.allocated_pages,
            .page_payload_bytes = self.capacity_ledger.page_payload_bytes,
            .payload_bytes_to_free = payload_bytes,
            .next_root_generation = self.next_root_generation,
        };
    }

    /// Apply a prevalidated terminal plan. All fallible validation and root
    /// construction occur before the first allocator free; afterwards the
    /// operation is infallible and the caller may shrink its external charge
    /// by exactly `payload_bytes_to_free`.
    pub fn reclaimRetiredAfterCommit(
        self: *PagedKVCache,
        plan: RetirementReclaimPlanV1,
    ) Error!usize {
        const expected = try self.planRetirementReclaim();
        if (plan.abi_version != retirement_reclaim_plan_abi or
            !std.meta.eql(plan, expected))
            return error.InvalidTransaction;
        const next_root: PageMapRootV1 = .{
            .cache_instance = self.instance_id,
            .generation = plan.next_root_generation,
            .committed_len = 0,
            .committed_pages = 0,
            .ownership_sha256 = emptyOwnershipDigest(
                self.instance_id,
                self.num_layers,
                self.dim,
                self.max_seq,
            ),
        };

        for (self.entries) |*entry| {
            if (entry.payload) |payload| {
                self.allocator.free(
                    payload[0..self.capacity_ledger.page_elements],
                );
                entry.payload = null;
            }
            entry.ownership_generation = 0;
        }
        self.allocated_pages = 0;
        self.committed_root = next_root;
        self.next_root_generation += 1;
        self.len = 0;
        self.retired = true;
        return plan.payload_bytes_to_free;
    }

    /// Recompute the complete allocator/root ledger before a byte count can
    /// authorize external uncharge. Reusable payloads are counted even though
    /// they have no current ownership generation; committed pages must have
    /// both payload and exact ownership evidence, while every later entry must
    /// be unowned. This scan is intentionally on the cold terminal path.
    fn validateRetirementCommitment(self: *const PagedKVCache) Error!void {
        if (self.committed_root.abi_version != page_map_root_abi or
            self.committed_root.cache_instance != self.instance_id or
            !generationAvailable(self.committed_root.generation) or
            self.committed_root.generation >= self.next_root_generation or
            self.committed_root.committed_len != self.len or
            self.len > self.max_seq or self.allocated_pages > self.entries.len)
            return error.InvalidRoot;
        const committed_pages = std.math.cast(
            usize,
            self.committed_root.committed_pages,
        ) orelse return error.InvalidRoot;
        const expected_committed_pages = self.len / page_positions +
            @intFromBool(self.len % page_positions != 0);
        if (committed_pages != expected_committed_pages or
            committed_pages > self.entries.len)
            return error.InvalidRoot;

        var materialized_pages: usize = 0;
        var ownership = emptyOwnershipDigest(
            self.instance_id,
            self.num_layers,
            self.dim,
            self.max_seq,
        );
        for (self.entries, 0..) |entry, page_index| {
            if (entry.payload != null) materialized_pages += 1;
            if (page_index < committed_pages) {
                if (entry.payload == null or entry.ownership_generation == 0)
                    return error.InvalidRoot;
                ownership = appendOwnershipDigest(ownership, .{
                    .cache_instance = self.instance_id,
                    .logical_page = @intCast(page_index),
                    .ownership_generation = entry.ownership_generation,
                });
            } else if (entry.ownership_generation != 0) {
                return error.InvalidRoot;
            }
        }
        if (materialized_pages != self.allocated_pages or
            !std.mem.eql(
                u8,
                &ownership,
                &self.committed_root.ownership_sha256,
            ))
            return error.InvalidRoot;
    }

    pub fn committedPrefix(
        self: *const PagedKVCache,
        layer: usize,
    ) Error!LayerPrefix {
        if (self.retired) return error.CacheRetired;
        if (layer >= self.num_layers) return error.ShapeMismatch;
        return .{
            .cache = self,
            .cache_id = @intFromPtr(self),
            .cache_instance = self.instance_id,
            .root_generation = self.committed_root.generation,
            .txn_generation = 0,
            .layer = layer,
            .positions = self.len,
            .page_count = @intCast(self.committed_root.committed_pages),
        };
    }

    /// Expose a fully written layer including the private row. Earlier layers
    /// remain readable; the current/future layer is rejected until appended.
    pub fn txnPrefix(
        self: *const PagedKVCache,
        mark: RowTxnMark,
        layer: usize,
    ) Error!LayerPrefix {
        const active = try self.validateRowTxnConst(mark);
        if (layer >= active.next_layer or layer >= self.num_layers)
            return error.TransactionIncomplete;
        return .{
            .cache = self,
            .cache_id = @intFromPtr(self),
            .cache_instance = self.instance_id,
            .root_generation = active.root_after.generation,
            .txn_generation = mark.generation,
            .layer = layer,
            .positions = mark.base_len + 1,
            .page_count = @intCast(active.root_after.committed_pages),
        };
    }

    pub fn logicalKvSha256(self: *const PagedKVCache) Error!Digest {
        if (self.retired) return error.CacheRetired;
        return hashLogicalPrefix(self, null);
    }

    /// Hash a fully written private row in canonical layer/K-then-V order
    /// without publishing its page-map root.
    pub fn logicalKvTxnSha256(
        self: *const PagedKVCache,
        mark: RowTxnMark,
    ) Error!Digest {
        _ = try self.prepareCommit(mark);
        return hashLogicalPrefix(self, mark);
    }

    /// Hash only the fully written private row in canonical layer/K-then-V
    /// order.  PagedTokenTxn uses this O(layers * dim) payload commitment to
    /// extend a state chain without re-hashing the complete growing prefix on
    /// every decode step.
    pub fn logicalRowTxnSha256(
        self: *const PagedKVCache,
        mark: RowTxnMark,
    ) Error!Digest {
        _ = try self.prepareCommit(mark);
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("glacier-paged-kv-row-v1\x00");
        hashU64(&hash, @intCast(self.num_layers));
        hashU64(&hash, @intCast(self.dim));
        hashU64(&hash, @intCast(mark.base_len));
        for (0..self.num_layers) |layer| {
            const prefix = try self.txnPrefix(mark, layer);
            hashStateF32(&hash, try prefix.keyRow(mark.base_len));
            hashStateF32(&hash, try prefix.valueRow(mark.base_len));
        }
        var digest: Digest = undefined;
        hash.final(&digest);
        return digest;
    }

    fn validateNextRowState(self: *const PagedKVCache) Error!NextRowState {
        if (self.active_row_txn != null) return error.TransactionActive;
        if (self.len >= self.max_seq) return error.CacheFull;
        if (!generationAvailable(self.next_row_txn_generation) or
            !generationAvailable(self.next_root_generation))
            return error.GenerationExhausted;
        if (self.committed_root.committed_len != self.len or
            self.committed_root.cache_instance != self.instance_id)
            return error.InvalidRoot;

        const page_index = self.len / page_positions;
        const row_in_page = self.len % page_positions;
        const installs_new_page = row_in_page == 0;
        if (page_index >= self.entries.len) return error.CacheFull;
        if (installs_new_page and
            !generationAvailable(self.next_page_generation))
            return error.GenerationExhausted;
        const expected_committed_pages = page_index +
            @intFromBool(row_in_page != 0);
        if (self.committed_root.committed_pages != expected_committed_pages)
            return error.InvalidRoot;

        const entry = self.entries[page_index];
        if (installs_new_page) {
            if (entry.ownership_generation != 0) return error.InvalidRoot;
        } else if (entry.payload == null or entry.ownership_generation == 0) {
            return error.InvalidRoot;
        }
        return .{
            .page_index = page_index,
            .row_in_page = row_in_page,
            .installs_new_page = installs_new_page,
        };
    }

    fn payloadOffset(
        self: *const PagedKVCache,
        layer: usize,
        value: bool,
        row_in_page: usize,
    ) Error!usize {
        if (layer >= self.num_layers or row_in_page >= page_positions)
            return error.ShapeMismatch;
        const kind_index = layer * 2 + @intFromBool(value);
        const kind_rows = std.math.mul(
            usize,
            kind_index,
            page_positions,
        ) catch return error.ShapeMismatch;
        const row = std.math.add(
            usize,
            kind_rows,
            row_in_page,
        ) catch return error.ShapeMismatch;
        return std.math.mul(usize, row, self.dim) catch
            return error.ShapeMismatch;
    }

    fn pageRef(self: *const PagedKVCache, page_index: usize) PageRefV1 {
        return .{
            .cache_instance = self.instance_id,
            .logical_page = @intCast(page_index),
            .ownership_generation = self.entries[page_index]
                .ownership_generation,
        };
    }

    fn entryForPrefix(
        self: *const PagedKVCache,
        prefix: LayerPrefix,
        page_index: usize,
    ) Error!*const PageEntry {
        if (page_index >= prefix.page_count or page_index >= self.entries.len)
            return error.InvalidPageRef;
        const entry = &self.entries[page_index];
        if (entry.payload == null or entry.ownership_generation == 0)
            return error.InvalidPageRef;
        return entry;
    }

    fn validateRowTxn(
        self: *PagedKVCache,
        mark: RowTxnMark,
    ) Error!*ActiveRowTxn {
        const active = if (self.active_row_txn) |*value| value else return error.InvalidTransaction;
        try self.validateMark(active, mark);
        return active;
    }

    fn validateRowTxnConst(
        self: *const PagedKVCache,
        mark: RowTxnMark,
    ) Error!*const ActiveRowTxn {
        const active = if (self.active_row_txn) |*value| value else return error.InvalidTransaction;
        try self.validateMark(active, mark);
        return active;
    }

    fn validateRowTxnGeneration(
        self: *const PagedKVCache,
        generation: u64,
    ) Error!*const ActiveRowTxn {
        const active = if (self.active_row_txn) |*value| value else return error.InvalidTransaction;
        if (generation == 0 or active.mark.generation != generation)
            return error.InvalidTransaction;
        try self.validateMark(active, active.mark);
        return active;
    }

    fn validateMark(
        self: *const PagedKVCache,
        active: *const ActiveRowTxn,
        mark: RowTxnMark,
    ) Error!void {
        if (mark.abi_version != row_txn_abi or
            mark.cache_id != @intFromPtr(self) or
            mark.cache_instance != self.instance_id or
            mark.row_count != 1 or
            mark.base_len != self.len or
            mark.root_before_generation != self.committed_root.generation or
            !std.meta.eql(mark, active.mark) or
            !std.meta.eql(self.committed_root, active.root_before) or
            mark.root_after_generation != active.root_after.generation or
            active.page_index >= self.entries.len)
            return error.InvalidTransaction;
        const entry = self.entries[active.page_index];
        if (entry.payload == null or
            entry.ownership_generation != mark.page_ref.ownership_generation or
            mark.page_ref.abi_version != page_ref_abi or
            mark.page_ref.cache_instance != self.instance_id or
            mark.page_ref.logical_page != active.page_index)
            return error.InvalidPageRef;
    }
};

fn generationAvailable(generation: u64) bool {
    return generation != 0 and generation != std.math.maxInt(u64);
}

fn hashStateF32(
    hash: *std.crypto.hash.sha2.Sha256,
    values: []const f32,
) void {
    for (values) |value| hashU32(hash, @bitCast(value));
}

fn hashLogicalPrefix(
    cache: *const PagedKVCache,
    maybe_mark: ?RowTxnMark,
) Error!Digest {
    const positions = if (maybe_mark) |mark| mark.base_len + 1 else cache.len;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-logical-kv-state-v1\x00");
    hashU64(&hash, @intCast(cache.num_layers));
    hashU64(&hash, @intCast(cache.dim));
    hashU64(&hash, @intCast(positions));
    for (0..cache.num_layers) |layer| {
        const prefix = if (maybe_mark) |mark|
            try cache.txnPrefix(mark, layer)
        else
            try cache.committedPrefix(layer);
        var key_pages = try prefix.iterator();
        while (try key_pages.next()) |span| hashStateF32(&hash, span.keys);
        var value_pages = try prefix.iterator();
        while (try value_pages.next()) |span| hashStateF32(&hash, span.values);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const resource_bank = @import("core").resource_bank;

test "paged KV capacity ledger is exact for Qwen 128 and 512" {
    const short = try deriveCapacityLedger(24, 128, 128);
    try testing.expectEqual(@as(usize, 8), short.page_count_capacity);
    try testing.expectEqual(@as(usize, 393_216), short.page_payload_bytes);
    try testing.expectEqual(@as(usize, 3_145_728), short.tensor_capacity_bytes);
    try testing.expectEqual(@as(usize, 128), short.page_map_bytes);
    try testing.expectEqual(@as(usize, 3_145_856), short.allocation_capacity_bytes);
    try testing.expectEqual(@as(usize, 3_146_496), short.contiguous_counterfactual_bytes);
    try testing.expectEqual(@as(usize, 640), short.capacity_reclaimed_bytes);
    try testing.expectEqual(@as(usize, 0), short.capacity_overhead_bytes);
    try testing.expectEqual(@as(usize, 0), short.padded_positions);

    const long = try deriveCapacityLedger(24, 128, 512);
    try testing.expectEqual(@as(usize, 32), long.page_count_capacity);
    try testing.expectEqual(@as(usize, 512), long.page_map_bytes);
    try testing.expectEqual(@as(usize, 12_583_424), long.allocation_capacity_bytes);
    try testing.expectEqual(@as(usize, 12_583_680), long.contiguous_counterfactual_bytes);
    try testing.expectEqual(@as(usize, 256), long.capacity_reclaimed_bytes);

    const padded = try deriveCapacityLedger(24, 128, 129);
    try testing.expectEqual(@as(usize, 15), padded.padded_positions);
    try testing.expect(padded.capacity_overhead_bytes > 0);
    try testing.expectEqual(@as(usize, 0), padded.capacity_reclaimed_bytes);
}

test "paged KV ledger rejects zero and overflow geometry" {
    try testing.expectError(
        error.ShapeMismatch,
        deriveCapacityLedger(0, 128, 128),
    );
    try testing.expectError(
        error.ShapeMismatch,
        deriveCapacityLedger(2, std.math.maxInt(usize), 16),
    );
    try testing.expectError(
        error.ShapeMismatch,
        deriveCapacityLedger(1, 1, std.math.maxInt(usize)),
    );
}

test "paged KV capacity ledger composes with exact ResourceBank admission" {
    const ledger = try deriveCapacityLedger(24, 128, 128);
    const capacity: u64 = @intCast(ledger.allocation_capacity_bytes);
    var exact_slots = [_]resource_bank.Slot{.{}} ** 1;
    var exact_bank = try resource_bank.Bank.init(
        &exact_slots,
        .{ .host_bytes = capacity, .kv_bytes = capacity },
        0x504b_5642_0000_0001,
    );
    const receipt = try exact_bank.commit(try exact_bank.reserve(
        1,
        .{ .kv_bytes = capacity },
    ));
    try exact_bank.release(receipt);

    var short_slots = [_]resource_bank.Slot{.{}} ** 1;
    var short_bank = try resource_bank.Bank.init(
        &short_slots,
        .{ .host_bytes = capacity - 1, .kv_bytes = capacity - 1 },
        0x504b_5642_0000_0002,
    );
    try testing.expectError(
        resource_bank.Error.CapacityExceeded,
        short_bank.reserve(1, .{ .kv_bytes = capacity }),
    );
}

fn finishTestRow(
    cache: *PagedKVCache,
    mark: RowTxnMark,
    position: usize,
) !void {
    for (0..cache.num_layers) |layer| {
        var k_row: [4]f32 = undefined;
        var v_row: [4]f32 = undefined;
        if (cache.dim > k_row.len) return error.ShapeMismatch;
        for (0..cache.dim) |channel| {
            k_row[channel] = @floatFromInt(position * 100 + layer * 10 + channel);
            v_row[channel] = -k_row[channel] - 0.5;
        }
        _ = try cache.appendRowTxn(
            mark,
            layer,
            k_row[0..cache.dim],
            v_row[0..cache.dim],
        );
    }
    try cache.commitRowTxn(mark);
}

fn appendTestRow(cache: *PagedKVCache, position: usize) !void {
    try finishTestRow(cache, try cache.beginRow(), position);
}

fn allocationFailureProbe(allocator: std.mem.Allocator) !void {
    var cache = try PagedKVCache.init(allocator, 2, 2, 17);
    defer cache.deinit();
    const mark = try cache.beginRow();
    const k = [_]f32{ 1, 2 };
    const v = [_]f32{ 3, 4 };
    _ = try cache.appendRowTxn(mark, 0, &k, &v);
    _ = try cache.appendRowTxn(mark, 1, &k, &v);
    try cache.commitRowTxn(mark);
}

test "paged KV releases every partial initialization and page allocation" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        allocationFailureProbe,
        .{},
    );
}

test "paged KV materializes exact bundles lazily across 15 16 17" {
    var cache = try PagedKVCache.init(testing.allocator, 2, 3, 17);
    defer cache.deinit();

    const initial = try cache.residentLedger();
    try testing.expectEqual(@as(usize, 0), initial.allocated_pages);
    try testing.expectEqual(cache.capacity_ledger.page_map_bytes, initial.resident_allocation_bytes);

    try appendTestRow(&cache, 0);
    var resident = try cache.residentLedger();
    try testing.expectEqual(@as(usize, 1), resident.allocated_pages);
    try testing.expectEqual(@as(usize, 1), resident.committed_pages);
    const first_resident_bytes = resident.resident_allocation_bytes;

    for (1..16) |position| try appendTestRow(&cache, position);
    resident = try cache.residentLedger();
    try testing.expectEqual(@as(usize, 1), resident.allocated_pages);
    try testing.expectEqual(first_resident_bytes, resident.resident_allocation_bytes);

    try appendTestRow(&cache, 16);
    resident = try cache.residentLedger();
    try testing.expectEqual(@as(usize, 2), resident.allocated_pages);
    try testing.expectEqual(@as(usize, 2), resident.committed_pages);
    try testing.expectEqual(
        first_resident_bytes + cache.capacity_ledger.page_payload_bytes,
        resident.resident_allocation_bytes,
    );
    try testing.expectEqual(@as(usize, 17), cache.len);
    try testing.expectError(error.CacheFull, cache.beginRow());
}

test "terminal reclaim frees payload before external uncharge and fences roots" {
    var tracking = testing.FailingAllocator.init(testing.allocator, .{});
    {
        var cache = try PagedKVCache.init(
            tracking.allocator(),
            1,
            2,
            32,
        );
        defer cache.deinit();
        for (0..17) |position| try appendTestRow(&cache, position);

        const terminal_root = cache.root();
        const terminal_digest = try cache.logicalKvSha256();
        const first_ref = cache.pageRef(0);
        try cache.validateCommittedPageRef(first_ref);
        const active = try cache.beginRow();
        try testing.expectError(
            error.TransactionActive,
            cache.planRetirementReclaim(),
        );
        try cache.abortRow(active);

        cache.allocated_pages -= 1;
        try testing.expectError(
            error.InvalidRoot,
            cache.planRetirementReclaim(),
        );
        cache.allocated_pages += 1;
        const valid_root = cache.committed_root;
        cache.committed_root.abi_version ^= 1;
        try testing.expectError(
            error.InvalidRoot,
            cache.planRetirementReclaim(),
        );
        cache.committed_root = valid_root;
        cache.committed_root.generation = 0;
        try testing.expectError(
            error.InvalidRoot,
            cache.planRetirementReclaim(),
        );
        cache.committed_root = valid_root;
        cache.committed_root.generation = cache.next_root_generation;
        try testing.expectError(
            error.InvalidRoot,
            cache.planRetirementReclaim(),
        );
        cache.committed_root = valid_root;
        const plan = try cache.planRetirementReclaim();
        try testing.expectEqual(
            retirement_reclaim_plan_abi,
            plan.abi_version,
        );
        try testing.expectEqual(@as(usize, 2), plan.allocated_pages);
        try testing.expectEqual(
            2 * cache.capacity_ledger.page_payload_bytes,
            plan.payload_bytes_to_free,
        );
        var forged = plan;
        forged.allocated_pages -= 1;
        try testing.expectError(
            error.InvalidTransaction,
            cache.reclaimRetiredAfterCommit(forged),
        );
        try testing.expectEqualDeep(
            terminal_root,
            cache.root(),
        );
        try testing.expectEqualDeep(
            terminal_digest,
            try cache.logicalKvSha256(),
        );

        const freed_before = tracking.freed_bytes;
        try testing.expectEqual(
            plan.payload_bytes_to_free,
            try cache.reclaimRetiredAfterCommit(plan),
        );
        try testing.expectEqual(
            plan.payload_bytes_to_free,
            tracking.freed_bytes - freed_before,
        );
        try testing.expect(cache.isRetired());
        const ledger = try cache.allocationCommitmentLedger();
        try testing.expectEqual(@as(usize, 0), ledger.allocated_pages);
        try testing.expectEqual(@as(usize, 0), ledger.committed_pages);
        try testing.expectEqual(@as(usize, 0), ledger.reusable_pages);
        try testing.expectEqual(
            cache.capacity_ledger.page_map_bytes,
            ledger.resident_allocation_bytes,
        );
        try testing.expectError(
            error.InvalidRoot,
            cache.validateCurrentRoot(terminal_root),
        );
        try testing.expectError(
            error.CacheRetired,
            cache.validateCurrentRoot(cache.root()),
        );
        try testing.expectError(
            error.InvalidPageRef,
            cache.validateCommittedPageRef(first_ref),
        );
        try testing.expectError(error.CacheRetired, cache.beginRow());
        try testing.expectError(
            error.CacheRetired,
            cache.planNextRowAllocation(),
        );
        try testing.expectError(
            error.CacheRetired,
            cache.planRetirementReclaim(),
        );
        try testing.expectError(error.CacheRetired, cache.reset());
        try testing.expectError(error.CacheRetired, cache.logicalKvSha256());
        try testing.expectError(
            error.CacheRetired,
            cache.committedPrefix(0),
        );
    }
    try testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
    try testing.expectEqual(tracking.allocations, tracking.deallocations);
}

test "row allocation plans charge exactly at first and page boundaries" {
    var cache = try PagedKVCache.init(testing.allocator, 2, 3, 17);
    defer cache.deinit();

    const first = try cache.planNextRowAllocation();
    try testing.expectEqual(row_allocation_plan_abi, first.abi_version);
    try testing.expectEqual(@intFromPtr(&cache), first.cache_id);
    try testing.expectEqual(cache.instance_id, first.cache_instance);
    try testing.expectEqual(@as(usize, 0), first.base_len);
    try testing.expectEqual(@as(usize, 0), first.logical_page);
    try testing.expectEqual(@as(usize, 0), first.row_in_page);
    try testing.expect(!first.page_payload_present);
    try testing.expectEqual(
        cache.capacity_ledger.page_payload_bytes,
        first.allocation_bytes,
    );

    var forged = first;
    forged.allocation_bytes = 0;
    try testing.expectError(
        error.InvalidAllocationPlan,
        cache.beginRowPlanned(forged),
    );
    try testing.expectEqual(@as(usize, 0), cache.allocated_pages);
    try testing.expectEqualDeep(first, try cache.planNextRowAllocation());

    try finishTestRow(&cache, try cache.beginRowPlanned(first), 0);
    const interior = try cache.planNextRowAllocation();
    try testing.expectEqual(@as(usize, 0), interior.logical_page);
    try testing.expectEqual(@as(usize, 1), interior.row_in_page);
    try testing.expect(interior.page_payload_present);
    try testing.expectEqual(@as(usize, 0), interior.allocation_bytes);
    try finishTestRow(&cache, try cache.beginRowPlanned(interior), 1);
    for (2..16) |position| try appendTestRow(&cache, position);

    const boundary = try cache.planNextRowAllocation();
    try testing.expectEqual(@as(usize, 16), boundary.base_len);
    try testing.expectEqual(@as(usize, 1), boundary.logical_page);
    try testing.expectEqual(@as(usize, 0), boundary.row_in_page);
    try testing.expect(!boundary.page_payload_present);
    try testing.expectEqual(
        cache.capacity_ledger.page_payload_bytes,
        boundary.allocation_bytes,
    );
}

test "stale row plans fail closed and aborted page reuse needs zero charge" {
    var cache = try PagedKVCache.init(testing.allocator, 1, 2, 32);
    defer cache.deinit();

    const charged = try cache.planNextRowAllocation();
    const first = try cache.beginRowPlanned(charged);
    const payload = cache.entries[0].payload.?;
    try cache.abortRow(first);

    try testing.expectError(
        error.InvalidAllocationPlan,
        cache.beginRowPlanned(charged),
    );
    const retry = try cache.planNextRowAllocation();
    try testing.expectEqual(@as(usize, 0), retry.logical_page);
    try testing.expectEqual(@as(usize, 0), retry.row_in_page);
    try testing.expect(retry.page_payload_present);
    try testing.expectEqual(@as(usize, 0), retry.allocation_bytes);
    try testing.expect(retry.row_txn_generation != charged.row_txn_generation);
    const allocated_before = cache.allocated_pages;
    try finishTestRow(&cache, try cache.beginRowPlanned(retry), 0);
    try testing.expectEqual(payload, cache.entries[0].payload.?);
    try testing.expectEqual(allocated_before, cache.allocated_pages);

    try testing.expectError(
        error.InvalidAllocationPlan,
        cache.beginRowPlanned(retry),
    );
    const before_mutation = try cache.planNextRowAllocation();
    try appendTestRow(&cache, 1);
    try testing.expectError(
        error.InvalidAllocationPlan,
        cache.beginRowPlanned(before_mutation),
    );
}

test "paged KV enforces canonical layers and keeps prepare private" {
    var cache = try PagedKVCache.init(testing.allocator, 2, 2, 4);
    defer cache.deinit();
    const root_before = cache.root();
    const mark = try cache.beginRow();
    const k = [_]f32{ 1, 2 };
    const v = [_]f32{ 3, 4 };

    try testing.expectError(error.TransactionActive, cache.beginRow());

    try testing.expectError(
        error.InvalidTransaction,
        cache.appendRowTxn(mark, 1, &k, &v),
    );
    _ = try cache.appendRowTxn(mark, 0, &k, &v);
    try testing.expectError(
        error.InvalidTransaction,
        cache.appendRowTxn(mark, 0, &k, &v),
    );
    try testing.expectError(error.TransactionIncomplete, cache.prepareCommit(mark));
    try testing.expectEqualDeep(root_before, cache.root());
    try testing.expectEqual(@as(usize, 0), cache.len);

    _ = try cache.appendRowTxn(mark, 1, &k, &v);
    const prepared = try cache.prepareCommit(mark);
    try testing.expectEqualDeep(root_before, cache.root());
    try testing.expectEqual(@as(usize, 0), cache.len);
    cache.commitPreparedAssumeValid(prepared);
    try testing.expectEqual(@as(usize, 1), cache.len);
    try testing.expectEqualDeep(prepared.root_after, cache.root());
    try testing.expectError(error.InvalidRoot, cache.validateCurrentRoot(root_before));
}

test "boundary abort reuses payload with fresh ownership and rejects ABA" {
    var cache = try PagedKVCache.init(testing.allocator, 1, 2, 2);
    defer cache.deinit();
    const root_before = cache.root();
    const first = try cache.beginRow();
    const payload = cache.entries[0].payload.?;
    const k = [_]f32{ 5, 6 };
    const v = [_]f32{ 7, 8 };
    _ = try cache.appendRowTxn(first, 0, &k, &v);
    try cache.abortRow(first);

    try testing.expectEqualDeep(root_before, cache.root());
    try testing.expectEqual(@as(usize, 0), cache.len);
    var resident = try cache.residentLedger();
    try testing.expectEqual(@as(usize, 1), resident.allocated_pages);
    try testing.expectEqual(@as(usize, 1), resident.reusable_pages);
    try testing.expectError(error.InvalidTransaction, cache.abortRow(first));
    try testing.expectError(
        error.InvalidPageRef,
        cache.validateCommittedPageRef(first.page_ref),
    );

    const retry = try cache.beginRow();
    try testing.expectEqual(payload, cache.entries[0].payload.?);
    try testing.expect(retry.page_ref.ownership_generation !=
        first.page_ref.ownership_generation);
    try testing.expectError(
        error.InvalidTransaction,
        cache.appendRowTxn(first, 0, &k, &v),
    );
    _ = try cache.appendRowTxn(retry, 0, &k, &v);
    try cache.commitRowTxn(retry);
    try cache.validateCommittedPageRef(retry.page_ref);
    try testing.expectError(
        error.InvalidPageRef,
        cache.validateCommittedPageRef(first.page_ref),
    );
    resident = try cache.residentLedger();
    try testing.expectEqual(@as(usize, 0), resident.reusable_pages);
}

test "reset invalidates roots and page refs while retaining resident pages" {
    var cache = try PagedKVCache.init(testing.allocator, 1, 1, 17);
    defer cache.deinit();
    for (0..17) |position| try appendTestRow(&cache, position);
    const old_root = cache.root();
    const old_ref = cache.pageRef(0);
    const before = try cache.residentLedger();
    try cache.reset();

    try testing.expectEqual(@as(usize, 0), cache.len);
    try testing.expectError(error.InvalidRoot, cache.validateCurrentRoot(old_root));
    try testing.expectError(
        error.InvalidPageRef,
        cache.validateCommittedPageRef(old_ref),
    );
    const after = try cache.residentLedger();
    try testing.expectEqual(before.allocated_pages, after.allocated_pages);
    try testing.expectEqual(before.resident_allocation_bytes, after.resident_allocation_bytes);
    try testing.expectEqual(before.allocated_pages, after.reusable_pages);

    const mark = try cache.beginRow();
    try testing.expect(mark.page_ref.ownership_generation !=
        old_ref.ownership_generation);
    const k = [_]f32{9};
    const v = [_]f32{10};
    _ = try cache.appendRowTxn(mark, 0, &k, &v);
    try cache.commitRowTxn(mark);
}

test "cache instance fences marks roots and pages across address reuse" {
    var cache = try PagedKVCache.init(testing.allocator, 1, 1, 1);
    const mark = try cache.beginRow();
    const k = [_]f32{1};
    const v = [_]f32{2};
    _ = try cache.appendRowTxn(mark, 0, &k, &v);
    try cache.commitRowTxn(mark);
    const old_root = cache.root();
    const old_ref = cache.pageRef(0);
    const old_instance = cache.instance_id;
    cache.deinit();

    cache = try PagedKVCache.init(testing.allocator, 1, 1, 1);
    defer cache.deinit();
    try testing.expect(cache.instance_id != old_instance);
    try testing.expectError(error.InvalidRoot, cache.validateCurrentRoot(old_root));
    try testing.expectError(
        error.InvalidPageRef,
        cache.validateCommittedPageRef(old_ref),
    );
    try testing.expectError(
        error.InvalidTransaction,
        cache.appendRowTxn(mark, 0, &k, &v),
    );
}

test "page iterator exposes ordered page-local slices and provisional row" {
    var cache = try PagedKVCache.init(testing.allocator, 2, 3, 17);
    defer cache.deinit();
    for (0..16) |position| try appendTestRow(&cache, position);

    const mark = try cache.beginRow();
    const k0 = [_]f32{ 1600, 1601, 1602 };
    const v0 = [_]f32{ -1600.5, -1601.5, -1602.5 };
    _ = try cache.appendRowTxn(mark, 0, &k0, &v0);
    const prefix = try cache.txnPrefix(mark, 0);
    var it = try prefix.iterator();
    const first = (try it.next()).?;
    try testing.expectEqual(@as(usize, 0), first.logical_start);
    try testing.expectEqual(@as(usize, 16), first.row_count);
    try testing.expectEqual(@as(usize, 48), first.keys.len);
    const second = (try it.next()).?;
    try testing.expectEqual(@as(usize, 16), second.logical_start);
    try testing.expectEqual(@as(usize, 1), second.row_count);
    try testing.expectEqualSlices(f32, &k0, second.keys);
    try testing.expectEqualSlices(f32, &v0, second.values);
    try testing.expect((try it.next()) == null);
    try testing.expectEqualSlices(f32, &k0, try prefix.keyRow(16));
    try testing.expectEqualSlices(f32, &v0, try prefix.valueRow(16));
    try testing.expectError(
        error.TransactionIncomplete,
        cache.txnPrefix(mark, 1),
    );

    const k1 = [_]f32{ 1610, 1611, 1612 };
    const v1 = [_]f32{ -1610.5, -1611.5, -1612.5 };
    _ = try cache.appendRowTxn(mark, 1, &k1, &v1);
    try cache.abortRow(mark);
    try testing.expectError(error.InvalidTransaction, prefix.iterator());
    const committed = try cache.committedPrefix(0);
    try testing.expectEqual(@as(usize, 16), committed.positions);
    try testing.expectError(error.ShapeMismatch, committed.keyRow(16));
}

fn flatOracleDigest(
    num_layers: usize,
    dim: usize,
    max_seq: usize,
    positions: usize,
    keys: []const f32,
    values: []const f32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-logical-kv-state-v1\x00");
    hashU64(&hash, @intCast(num_layers));
    hashU64(&hash, @intCast(dim));
    hashU64(&hash, @intCast(positions));
    for (0..num_layers) |layer| {
        const base = layer * max_seq * dim;
        hashStateF32(&hash, keys[base .. base + positions * dim]);
        hashStateF32(&hash, values[base .. base + positions * dim]);
    }
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

test "paged logical hash matches flat canonical order including private row" {
    const layers = 2;
    const dim = 3;
    const max_seq = 17;
    var cache = try PagedKVCache.init(testing.allocator, layers, dim, max_seq);
    defer cache.deinit();
    var keys: [layers * max_seq * dim]f32 = undefined;
    var values: [layers * max_seq * dim]f32 = undefined;

    for (0..16) |position| {
        const mark = try cache.beginRow();
        for (0..layers) |layer| {
            var k: [dim]f32 = undefined;
            var v: [dim]f32 = undefined;
            for (0..dim) |channel| {
                const value: f32 = @floatFromInt(
                    position * 100 + layer * 10 + channel,
                );
                k[channel] = value;
                v[channel] = -value - 0.25;
                const index = layer * max_seq * dim + position * dim + channel;
                keys[index] = k[channel];
                values[index] = v[channel];
            }
            _ = try cache.appendRowTxn(mark, layer, &k, &v);
        }
        try cache.commitRowTxn(mark);
    }
    try testing.expectEqualSlices(
        u8,
        &flatOracleDigest(layers, dim, max_seq, 16, &keys, &values),
        &try cache.logicalKvSha256(),
    );

    const mark = try cache.beginRow();
    for (0..layers) |layer| {
        var k: [dim]f32 = undefined;
        var v: [dim]f32 = undefined;
        for (0..dim) |channel| {
            const value: f32 = @floatFromInt(1600 + layer * 10 + channel);
            k[channel] = value;
            v[channel] = -value - 0.25;
            const index = layer * max_seq * dim + 16 * dim + channel;
            keys[index] = k[channel];
            values[index] = v[channel];
        }
        _ = try cache.appendRowTxn(mark, layer, &k, &v);
    }
    const committed_before = try cache.logicalKvSha256();
    const private_digest = try cache.logicalKvTxnSha256(mark);
    try testing.expectEqualSlices(
        u8,
        &flatOracleDigest(layers, dim, max_seq, 17, &keys, &values),
        &private_digest,
    );
    try testing.expect(!std.mem.eql(u8, &committed_before, &private_digest));
    try cache.abortRow(mark);
    try testing.expectEqualSlices(
        u8,
        &committed_before,
        &try cache.logicalKvSha256(),
    );
}

test "second-page OOM leaves committed root cursor and resident ledger unchanged" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var cache = try PagedKVCache.init(failing.allocator(), 1, 2, 32);
    defer cache.deinit();
    for (0..16) |position| try appendTestRow(&cache, position);
    const root_before = cache.root();
    const resident_before = try cache.residentLedger();
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, cache.beginRow());
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqualDeep(root_before, cache.root());
    try testing.expectEqual(@as(usize, 16), cache.len);
    try testing.expectEqualDeep(resident_before, try cache.residentLedger());
    try testing.expect(cache.active_row_txn == null);
}

test "planned allocation OOM leaves entry root generations and count unchanged" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var cache = try PagedKVCache.init(failing.allocator(), 1, 2, 17);
    defer cache.deinit();

    const plan = try cache.planNextRowAllocation();
    const entry_before = cache.entries[0];
    const root_before = cache.root();
    const allocated_before = cache.allocated_pages;
    const row_generation_before = cache.next_row_txn_generation;
    const root_generation_before = cache.next_root_generation;
    const page_generation_before = cache.next_page_generation;
    failing.fail_index = failing.alloc_index;

    try testing.expectError(
        error.OutOfMemory,
        cache.beginRowPlanned(plan),
    );
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqualDeep(entry_before, cache.entries[0]);
    try testing.expectEqualDeep(root_before, cache.root());
    try testing.expectEqual(allocated_before, cache.allocated_pages);
    try testing.expectEqual(row_generation_before, cache.next_row_txn_generation);
    try testing.expectEqual(root_generation_before, cache.next_root_generation);
    try testing.expectEqual(page_generation_before, cache.next_page_generation);
    try testing.expect(cache.active_row_txn == null);
    try testing.expectEqualDeep(plan, try cache.planNextRowAllocation());
}

test "ten thousand commit abort reset transitions preserve root invariants" {
    var cache = try PagedKVCache.init(testing.allocator, 2, 3, 64);
    defer cache.deinit();
    var state: u64 = 0x1234_5678_9abc_def0;
    var committed: usize = 0;

    for (0..10_000) |step| {
        if (committed == cache.max_seq) {
            const stale_root = cache.root();
            try cache.reset();
            try testing.expectError(
                error.InvalidRoot,
                cache.validateCurrentRoot(stale_root),
            );
            committed = 0;
        }
        const root_before = cache.root();
        const mark = try cache.beginRow();
        for (0..cache.num_layers) |layer| {
            const k = [_]f32{
                @floatFromInt(step),
                @floatFromInt(layer),
                @floatFromInt(committed),
            };
            const v = [_]f32{ -k[0], -k[1], -k[2] };
            _ = try cache.appendRowTxn(mark, layer, &k, &v);
        }
        state = state *% 6364136223846793005 +% 1442695040888963407;
        if (state & 3 == 0) {
            try cache.abortRow(mark);
            try testing.expectEqualDeep(root_before, cache.root());
            try testing.expectEqual(committed, cache.len);
            try testing.expectError(
                error.InvalidTransaction,
                cache.prepareCommit(mark),
            );
        } else {
            const prepared = try cache.prepareCommit(mark);
            try testing.expectEqualDeep(root_before, cache.root());
            cache.commitPreparedAssumeValid(prepared);
            committed += 1;
            try testing.expectEqual(committed, cache.len);
            try testing.expectEqual(@as(u64, @intCast(committed)), cache.root().committed_len);
        }
        const resident = try cache.residentLedger();
        try testing.expect(resident.resident_allocation_bytes <=
            cache.capacity_ledger.allocation_capacity_bytes);
        try testing.expectEqual(
            cache.len / page_positions +
                @intFromBool(cache.len % page_positions != 0),
            resident.committed_pages,
        );
    }
}
