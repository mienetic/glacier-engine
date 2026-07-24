//! Atomic admission for request-scoped execution resources.
//!
//! ResourceBank is deliberately independent of allocators and backends. A
//! caller derives one complete logical claim, reserves it before request-side
//! mutation, commits the selected execution capsule, and releases the receipt
//! exactly once on success, cancellation, or failure. Fixed caller-owned slot
//! storage keeps admission allocation-free and gives servers a hard bound on
//! the number of concurrent leases.

const std = @import("std");

pub const abi: u64 = 0x4752_424b_0000_0001;
/// Address-stable publication-session fence layered over a committed receipt.
pub const publication_fence_abi: u64 = 0x4752_5055_0000_0001;
/// Optional one-level allocator-backed sublease extension. This is a distinct
/// ABI: parent Receipt claims retain their v1 immutable meaning. Its byte
/// charge is a conservative allocation commitment, not an OS-RSS sample.
pub const child_lease_abi: u64 = 0x4752_434c_0000_0001;
/// Snapshot v2 adds optional child-sidecar activity and mutation counters while
/// Receipt/proposal identity remains on ResourceBank ABI v1.
pub const snapshot_abi: u64 = 0x4752_4253_0000_0002;
/// Optional bounded allocation-ownership tree. This is additive to the flat
/// Receipt ABI and the aggregate ChildLease ABI; a Bank opts into at most one
/// mutable sidecar mode at initialization. V1 is a trusted synchronous,
/// request-local coordinator: its inert pin/reference fields do not authorize
/// asynchronous readers or cross-worker reclamation.
pub const lease_tree_abi: u64 = 0x4752_4c54_0000_0001;
pub const lease_node_abi: u64 = 0x4752_4c4e_0000_0001;
pub const lease_allocation_batch_abi: u64 = 0x4752_4c41_0000_0001;
pub const lease_retire_ticket_abi: u64 = 0x4752_4c52_0000_0001;
pub const lease_free_permit_abi: u64 = 0x4752_4c46_0000_0001;
/// Snapshot v3 adds LeaseTree state and operation counters. Snapshot v1/v2
/// layouts and meanings remain unchanged.
pub const snapshot_v3_abi: u64 = 0x4752_4253_0000_0003;

pub const Error = error{
    InvalidConfiguration,
    InvalidClaim,
    ClaimOverflow,
    CapacityExceeded,
    ReservationSlotsExhausted,
    LeaseNodesExhausted,
    StaleReservation,
    InvalidTransition,
};

/// Non-overlapping logical resource classes. All byte fields except
/// `device_bytes` and `io_bytes` contribute to the aggregate host-byte cap.
/// The caller defines the accounting scope; Glacier generation v1 excludes
/// allocator metadata/padding, stack and OS-thread state, legacy libc-pool
/// internals, external-provider allocations, mapped model pages, and physical
/// OS/device residency unless the caller explicitly adds them to a class.
pub const Claim = struct {
    capsule_bytes: u64 = 0,
    kv_bytes: u64 = 0,
    activation_bytes: u64 = 0,
    partial_bytes: u64 = 0,
    logits_bytes: u64 = 0,
    output_journal_bytes: u64 = 0,
    staging_bytes: u64 = 0,
    device_bytes: u64 = 0,
    io_bytes: u64 = 0,
    queue_slots: u64 = 0,

    pub fn hostBytes(self: Claim) Error!u64 {
        var total: u64 = 0;
        inline for (.{
            self.capsule_bytes,
            self.kv_bytes,
            self.activation_bytes,
            self.partial_bytes,
            self.logits_bytes,
            self.output_journal_bytes,
            self.staging_bytes,
        }) |value| {
            total = std.math.add(u64, total, value) catch
                return Error.ClaimOverflow;
        }
        return total;
    }

    pub fn isZero(self: Claim) bool {
        inline for (std.meta.fields(Claim)) |field| {
            if (@field(self, field.name) != 0) return false;
        }
        return true;
    }
};

/// Aggregate and per-class hard limits. Defaults are unlimited so callers may
/// tighten only the dimensions governed by their deployment policy.
pub const Limits = struct {
    host_bytes: u64 = std.math.maxInt(u64),
    capsule_bytes: u64 = std.math.maxInt(u64),
    kv_bytes: u64 = std.math.maxInt(u64),
    activation_bytes: u64 = std.math.maxInt(u64),
    partial_bytes: u64 = std.math.maxInt(u64),
    logits_bytes: u64 = std.math.maxInt(u64),
    output_journal_bytes: u64 = std.math.maxInt(u64),
    staging_bytes: u64 = std.math.maxInt(u64),
    device_bytes: u64 = std.math.maxInt(u64),
    io_bytes: u64 = std.math.maxInt(u64),
    queue_slots: u64 = std.math.maxInt(u64),

    pub fn fits(self: Limits, claim: Claim) Error!bool {
        return self.fitsWithHost(claim, try claim.hostBytes());
    }

    fn fitsWithHost(self: Limits, claim: Claim, host_bytes: u64) bool {
        return host_bytes <= self.host_bytes and
            claim.capsule_bytes <= self.capsule_bytes and
            claim.kv_bytes <= self.kv_bytes and
            claim.activation_bytes <= self.activation_bytes and
            claim.partial_bytes <= self.partial_bytes and
            claim.logits_bytes <= self.logits_bytes and
            claim.output_journal_bytes <= self.output_journal_bytes and
            claim.staging_bytes <= self.staging_bytes and
            claim.device_bytes <= self.device_bytes and
            claim.io_bytes <= self.io_bytes and
            claim.queue_slots <= self.queue_slots;
    }
};

const SlotState = enum(u8) {
    free,
    reserved,
    committed,
};

const ChildResizeDirection = enum { grow, shrink };

/// Caller-owned fixed storage. Treat slots as private to one Bank and do not
/// inspect or mutate them after `Bank.init`.
pub const Slot = struct {
    state: SlotState = .free,
    generation: u64 = 0,
    owner_key: u64 = 0,
    claim: Claim = .{},
    integrity: u64 = 0,
    publication_request_epoch: u64 = 0,
    publication_session_id: usize = 0,
    publication_next_sequence: u64 = 0,
    publication_permit_generation: u64 = 0,
    publication_active: bool = false,
    publication_permit_integrity: u64 = 0,
};

/// Optional caller-owned storage for the child-lease extension. Keeping this
/// sidecar separate preserves the Receipt-v1 flat-path Slot footprint; only a
/// Bank that opts into mutable child admission pays for child state.
pub const ChildSlot = struct {
    key: u64 = 0,
    generation: u64 = 0,
    ceiling: Claim = .{},
    claim: Claim = .{},
    integrity: u64 = 0,
    active: bool = false,
};

pub const LeaseNodeKind = enum(u8) {
    scope,
    allocation,
};

pub const LeaseNodeState = enum(u8) {
    free,
    live,
    reserved_unmaterialized,
    quiescing,
    free_authorized,
};

const LeasePendingKind = enum(u8) {
    none,
    allocation,
    retire,
    free,
};

/// One tree root per Receipt slot. The root owns aggregate accounting and one
/// single-flight structural operation; payload allocation/free happens outside
/// the Bank mutex while its pending operation remains charged and fenced.
pub const LeaseTreeRootSlot = struct {
    active: bool = false,
    tree_key: u64 = 0,
    authority_key: u64 = 0,
    identity_generation: u64 = 0,
    generation: u64 = 0,
    structural_revision: u64 = 0,
    ceiling: Claim = .{},
    current: Claim = .{},
    active_nodes: u32 = 0,
    state_digest: u64 = 0,
    integrity: u64 = 0,
    pending_kind: LeasePendingKind = .none,
    pending_generation: u64 = 0,
    pending_completion_generation: u64 = 0,
    pending_free_permit_generation: u64 = 0,
    pending_free_completion_generation: u64 = 0,
    pending_scope_index: u32 = no_lease_node,
    pending_count: u32 = 0,
    pending_claim: Claim = .{},
    pending_digest: u64 = 0,
};

/// Shared fixed node pool. Indices, not pointers, form tree edges so public
/// handles remain pointer-free and copied stale handles fail by generation.
pub const LeaseNodeSlot = struct {
    active: bool = false,
    receipt_slot_index: u32 = 0,
    tree_identity_generation: u64 = 0,
    generation: u64 = 0,
    parent_index: u32 = no_lease_node,
    parent_generation: u64 = 0,
    node_key: u64 = 0,
    tenant_key: u64 = 0,
    binding_key: u64 = 0,
    kind: LeaseNodeKind = .scope,
    state: LeaseNodeState = .free,
    ceiling: Claim = .{},
    claim: Claim = .{},
    subtree_claim: Claim = .{},
    pending_generation: u64 = 0,
    /// Reserved for a later bounded pin-set ABI. Stage 1 never increments
    /// these fields and reclamation fails closed if either is nonzero.
    pin_count: u32 = 0,
    published_references: u32 = 0,
    integrity: u64 = 0,
};

pub const LeaseTreeStorage = struct {
    roots: []LeaseTreeRootSlot,
    nodes: []LeaseNodeSlot,
};

pub const LeaseTreeV1 = struct {
    abi_version: u64 = lease_tree_abi,
    parent: Receipt,
    tree_key: u64,
    authority_key: u64,
    identity_generation: u64,
    generation: u64,
    structural_revision: u64,
    ceiling: Claim,
    current: Claim,
    active_nodes: u32,
    state_digest: u64,
    integrity: u64,
};

/// Stable allocation/scope identity. Mutable lifecycle state and subtree sums
/// are deliberately excluded: sibling/tree mutations do not invalidate a
/// page identity, while slot reuse always changes `generation`.
pub const LeaseNodeV1 = struct {
    abi_version: u64 = lease_node_abi,
    parent: Receipt,
    tree_key: u64,
    tree_identity_generation: u64,
    node_index: u32,
    generation: u64,
    parent_index: u32,
    parent_generation: u64,
    node_key: u64,
    tenant_key: u64,
    binding_key: u64,
    kind: LeaseNodeKind,
    ceiling: Claim,
    claim: Claim,
    integrity: u64,
};

pub const LeaseScopeOpenV1 = struct {
    tree: LeaseTreeV1,
    scope: LeaseNodeV1,
};

pub const LeaseAllocationSpecV1 = struct {
    scope: LeaseNodeV1,
    node_key: u64,
    binding_key: u64,
    claim: Claim,
};

pub const LeaseAllocationBatchV1 = struct {
    abi_version: u64 = lease_allocation_batch_abi,
    parent: Receipt,
    tree_key: u64,
    tree_identity_generation: u64,
    tree_generation: u64,
    structural_revision: u64,
    request_epoch: u64,
    session_id: usize,
    sequence: u64,
    generation: u64,
    completion_tree_generation: u64,
    node_count: u32,
    claim: Claim,
    node_set_digest: u64,
    integrity: u64,
};

pub const LeaseAllocationReservationV1 = struct {
    tree: LeaseTreeV1,
    batch: LeaseAllocationBatchV1,
};

pub const LeaseFreePermitV1 = struct {
    abi_version: u64 = lease_free_permit_abi,
    parent: Receipt,
    tree_key: u64,
    tree_identity_generation: u64,
    tree_generation: u64,
    structural_revision: u64,
    request_epoch: u64,
    session_id: usize,
    sequence: u64,
    generation: u64,
    completion_tree_generation: u64,
    scope_index: u32,
    scope_generation: u64,
    node_count: u32,
    claim: Claim,
    node_set_digest: u64,
    integrity: u64,
};

pub const LeaseRetirePreparedV1 = struct {
    tree: LeaseTreeV1,
    ticket: LeaseRetireTicketV1,
};

pub const LeaseRetireTicketV1 = struct {
    abi_version: u64 = lease_retire_ticket_abi,
    parent: Receipt,
    tree_key: u64,
    tree_identity_generation: u64,
    tree_generation: u64,
    structural_revision: u64,
    request_epoch: u64,
    session_id: usize,
    sequence: u64,
    generation: u64,
    decision_tree_generation: u64,
    free_permit_generation: u64,
    free_completion_tree_generation: u64,
    scope_index: u32,
    scope_generation: u64,
    node_count: u32,
    claim: Claim,
    node_set_digest: u64,
    integrity: u64,
};

pub const LeaseFreeAuthorizedV1 = struct {
    tree: LeaseTreeV1,
    permit: LeaseFreePermitV1,
};

const no_lease_node: u32 = std.math.maxInt(u32);

comptime {
    // Slot is caller-owned storage and therefore a resource contract in its
    // own right. P2c child state must never silently inflate the flat path.
    if (@sizeOf(usize) == 8 and @sizeOf(Slot) != 152)
        @compileError("ResourceBank Receipt-v1 Slot footprint changed");
}

pub const Reservation = struct {
    bank_epoch: u64,
    slot_index: u32,
    generation: u64,
    owner_key: u64,
    claim: Claim,
    integrity: u64,
};

pub const Receipt = struct {
    bank_epoch: u64,
    slot_index: u32,
    generation: u64,
    owner_key: u64,
    claim: Claim,
    integrity: u64,
};

/// Recompute the v1 accidental-misuse checksum without consulting live Bank
/// state. This is structural replay validation, not authentication and not
/// proof that the named receipt is still committed.
pub fn receiptIntegrityValidV1(receipt: Receipt) bool {
    return receipt.integrity == tokenIntegrity(
        receipt.bank_epoch,
        receipt.slot_index,
        receipt.generation,
        receipt.owner_key,
        receipt.claim,
        receipt_domain,
    );
}

/// Recompute a pointer-free LeaseTree handle checksum without consulting live
/// Bank state. Like receipt validation, this proves structural consistency,
/// not current ownership or authority.
pub fn leaseTreeIntegrityValidV1(tree: LeaseTreeV1) bool {
    if (tree.abi_version != lease_tree_abi or
        !receiptIntegrityValidV1(tree.parent))
        return false;
    var result = mix64(lease_tree_domain ^ tree.parent.integrity);
    result = mix64(result ^ tree.tree_key);
    result = mix64(result ^ tree.authority_key);
    result = mix64(result ^ tree.identity_generation);
    result = mix64(result ^ tree.generation);
    result = mix64(result ^ tree.structural_revision);
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(tree.ceiling, field.name));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(tree.current, field.name));
    result = mix64(result ^ @as(u64, tree.active_nodes));
    result = mix64(result ^ tree.state_digest);
    return tree.integrity == result;
}

/// Recompute one pointer-free LeaseTree node checksum without consulting live
/// Bank state. Lifecycle state is deliberately excluded from the stable node
/// identity; callers still need a live Bank validation before mutation.
pub fn leaseNodeIntegrityValidV1(node: LeaseNodeV1) bool {
    if (node.abi_version != lease_node_abi or
        !receiptIntegrityValidV1(node.parent))
        return false;
    var result = mix64(lease_node_domain ^ node.parent.integrity);
    result = mix64(result ^ node.tree_key);
    result = mix64(result ^ node.tree_identity_generation);
    result = mix64(result ^ @as(u64, node.node_index));
    result = mix64(result ^ node.generation);
    result = mix64(result ^ @as(u64, node.parent_index));
    result = mix64(result ^ node.parent_generation);
    result = mix64(result ^ node.node_key);
    result = mix64(result ^ node.tenant_key);
    result = mix64(result ^ node.binding_key);
    result = mix64(result ^ @intFromEnum(node.kind));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(node.ceiling, field.name));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(node.claim, field.name));
    return node.integrity == result;
}

/// Generation-fenced mutable allocator-commitment charge anchored to one
/// immutable committed parent Receipt. V1 provides one child channel per
/// parent slot; resize returns a new handle and invalidates every copied prior
/// generation. It does not attest to OS or device physical residency.
pub const ChildLease = struct {
    abi_version: u64 = child_lease_abi,
    parent: Receipt,
    child_key: u64,
    generation: u64,
    /// Immutable model/policy envelope for every later growth generation.
    ceiling: Claim,
    claim: Claim,
    integrity: u64,
};

/// Bank-owned single-flight permit for one publication sequence. It is bound
/// to the exact committed receipt and to the address of one coordinator.
pub const PublicationPermit = struct {
    abi_version: u64 = publication_fence_abi,
    receipt: Receipt,
    request_epoch: u64,
    session_id: usize,
    sequence: u64,
    generation: u64,
    integrity: u64,
};

pub const Snapshot = struct {
    abi_version: u64,
    bank_epoch: u64,
    limits: Limits,
    used: Claim,
    peak: Claim,
    /// True maximum aggregate host charge at one instant. This is distinct
    /// from summing `peak`'s per-class maxima, which may occur at different
    /// instants and therefore form only a conservative upper envelope.
    peak_host_bytes: u64,
    active_reservations: usize,
    committed_receipts: usize,
    successful_reservations: u64,
    successful_commits: u64,
    cancellations: u64,
    releases: u64,
    rejected_capacity: u64,
    rejected_slots: u64,
};

/// Opt-in snapshot of the child-sidecar extension. The legacy `Snapshot` and
/// `snapshot()` layout/ABI remain unchanged for flat and P2b callers.
pub const SnapshotV2 = struct {
    abi_version: u64,
    bank_epoch: u64,
    limits: Limits,
    used: Claim,
    peak: Claim,
    peak_host_bytes: u64,
    active_reservations: usize,
    committed_receipts: usize,
    active_child_leases: usize,
    successful_reservations: u64,
    successful_commits: u64,
    cancellations: u64,
    releases: u64,
    rejected_capacity: u64,
    rejected_slots: u64,
    child_opens: u64,
    child_grows: u64,
    child_shrinks: u64,
    child_closes: u64,
    rejected_child_capacity: u64,
};

/// LeaseTree-aware telemetry. Counts describe allocator commitment and Bank
/// metadata, not sampled OS/device physical residency.
pub const SnapshotV3 = struct {
    abi_version: u64,
    bank_epoch: u64,
    limits: Limits,
    used: Claim,
    peak: Claim,
    peak_host_bytes: u64,
    active_reservations: usize,
    committed_receipts: usize,
    active_child_leases: usize,
    active_lease_trees: usize,
    active_lease_scopes: usize,
    active_lease_nodes: usize,
    /// Fixed caller-owned sidecar metadata. These bytes are reported but are
    /// not implicitly included in `used`; deployments may charge them in the
    /// immutable parent Claim when that is their accounting policy.
    lease_root_pool_bytes: usize,
    lease_node_pool_bytes: usize,
    lease_metadata_bytes: usize,
    reserved_unmaterialized_allocations: usize,
    live_allocations: usize,
    quiescing_allocations: usize,
    free_authorized_allocations: usize,
    successful_reservations: u64,
    successful_commits: u64,
    cancellations: u64,
    releases: u64,
    rejected_capacity: u64,
    rejected_slots: u64,
    child_opens: u64,
    child_grows: u64,
    child_shrinks: u64,
    child_closes: u64,
    rejected_child_capacity: u64,
    lease_tree_opens: u64,
    lease_scope_opens: u64,
    lease_allocation_reserves: u64,
    lease_allocation_materializations: u64,
    lease_allocation_aborts: u64,
    lease_reclaim_prepares: u64,
    lease_reclaim_authorizations: u64,
    lease_reclaim_cancels: u64,
    lease_reclaim_commits: u64,
    lease_tree_closes: u64,
    rejected_lease_capacity: u64,
    rejected_lease_nodes: u64,
};

/// Source-level Zig coordinator, not a stable C binary layout. Receipt-v1
/// tokens and the legacy Slot/Snapshot footprints remain their declared ABI;
/// callers embedding `Bank` itself must rebuild from the same source revision.
pub const Bank = struct {
    mutex: std.Thread.Mutex = .{},
    slots: []Slot,
    child_slots: ?[]ChildSlot = null,
    lease_tree_storage: ?LeaseTreeStorage = null,
    limits: Limits,
    used: Claim = .{},
    peak: Claim = .{},
    peak_host_bytes: u64 = 0,
    epoch: u64,
    next_generation: u64 = 1,
    next_child_generation: u64 = 1,
    next_lease_generation: u64 = 1,
    successful_reservations: u64 = 0,
    successful_commits: u64 = 0,
    cancellations: u64 = 0,
    releases: u64 = 0,
    rejected_capacity: u64 = 0,
    rejected_slots: u64 = 0,
    child_opens: u64 = 0,
    child_grows: u64 = 0,
    child_shrinks: u64 = 0,
    child_closes: u64 = 0,
    rejected_child_capacity: u64 = 0,
    lease_tree_opens: u64 = 0,
    lease_scope_opens: u64 = 0,
    lease_allocation_reserves: u64 = 0,
    lease_allocation_materializations: u64 = 0,
    lease_allocation_aborts: u64 = 0,
    lease_reclaim_prepares: u64 = 0,
    lease_reclaim_authorizations: u64 = 0,
    lease_reclaim_cancels: u64 = 0,
    lease_reclaim_commits: u64 = 0,
    lease_tree_closes: u64 = 0,
    rejected_lease_capacity: u64 = 0,
    rejected_lease_nodes: u64 = 0,

    /// The returned value may move until its first method call. Afterwards the
    /// Bank address and caller-owned slot slice must remain stable, and callers
    /// must not mutate public fields directly. `epoch` must be nonzero and must
    /// identify the authority wherever reservations/receipts can be exchanged.
    pub fn init(slots: []Slot, limits: Limits, epoch: u64) Error!Bank {
        return initStorage(slots, null, null, limits, epoch);
    }

    /// Opt into one allocator-commitment child channel per parent Slot without
    /// changing the flat Receipt-v1 Slot footprint. Both caller-owned slices
    /// must have equal length and remain address-stable after the first call.
    pub fn initWithChildSlots(
        slots: []Slot,
        child_slots: []ChildSlot,
        limits: Limits,
        epoch: u64,
    ) Error!Bank {
        if (child_slots.len != slots.len)
            return Error.InvalidConfiguration;
        return initStorage(slots, child_slots, null, limits, epoch);
    }

    /// Opt into a Bank-native bounded ownership tree without changing flat or
    /// ChildLease storage. `roots` is one-to-one with Receipt slots; `nodes`
    /// is a shared fixed pool and both slices remain address-stable. Their
    /// bytes are exposed by SnapshotV3 but are not implicitly added to
    /// `Bank.used`; include them in a parent Claim if policy charges metadata.
    pub fn initWithLeaseTreeStorage(
        slots: []Slot,
        roots: []LeaseTreeRootSlot,
        nodes: []LeaseNodeSlot,
        limits: Limits,
        epoch: u64,
    ) Error!Bank {
        if (roots.len != slots.len or nodes.len == 0 or
            nodes.len > std.math.maxInt(u32))
            return Error.InvalidConfiguration;
        return initStorage(slots, null, .{
            .roots = roots,
            .nodes = nodes,
        }, limits, epoch);
    }

    pub fn initWithLeaseTree(
        slots: []Slot,
        roots: []LeaseTreeRootSlot,
        nodes: []LeaseNodeSlot,
        limits: Limits,
        epoch: u64,
    ) Error!Bank {
        return initWithLeaseTreeStorage(
            slots,
            roots,
            nodes,
            limits,
            epoch,
        );
    }

    fn initStorage(
        slots: []Slot,
        child_slots: ?[]ChildSlot,
        lease_tree_storage: ?LeaseTreeStorage,
        limits: Limits,
        epoch: u64,
    ) Error!Bank {
        if (slots.len == 0 or slots.len > std.math.maxInt(u32) or epoch == 0)
            return Error.InvalidConfiguration;
        for (slots) |*slot| slot.* = .{};
        if (child_slots) |storage| {
            for (storage) |*slot| slot.* = .{};
        }
        if (lease_tree_storage) |storage| {
            if (storage.roots.len != slots.len or storage.nodes.len == 0 or
                storage.nodes.len > std.math.maxInt(u32))
                return Error.InvalidConfiguration;
            for (storage.roots) |*root| root.* = .{};
            for (storage.nodes) |*node| node.* = .{};
        }
        return .{
            .slots = slots,
            .child_slots = child_slots,
            .lease_tree_storage = lease_tree_storage,
            .limits = limits,
            .epoch = epoch,
        };
    }

    pub fn reserve(
        self: *Bank,
        owner_key: u64,
        claim: Claim,
    ) Error!Reservation {
        if (owner_key == 0 or claim.isZero()) return Error.InvalidClaim;

        self.mutex.lock();
        defer self.mutex.unlock();

        const next = addClaims(self.used, claim) catch {
            self.rejected_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        const next_host_bytes = next.hostBytes() catch {
            self.rejected_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        if (!self.limits.fitsWithHost(next, next_host_bytes)) {
            self.rejected_capacity +|= 1;
            return Error.CapacityExceeded;
        }

        var slot_index: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.state == .free) {
                slot_index = index;
                break;
            }
        }
        const index = slot_index orelse {
            self.rejected_slots +|= 1;
            return Error.ReservationSlotsExhausted;
        };
        if (self.next_generation == 0 or
            self.next_generation == std.math.maxInt(u64))
            return Error.InvalidConfiguration;
        const generation = self.next_generation;
        self.next_generation += 1;
        const integrity = tokenIntegrity(
            self.epoch,
            @intCast(index),
            generation,
            owner_key,
            claim,
            reservation_domain,
        );
        self.slots[index] = .{
            .state = .reserved,
            .generation = generation,
            .owner_key = owner_key,
            .claim = claim,
            .integrity = integrity,
        };
        self.used = next;
        self.peak = maxClaims(self.peak, next);
        self.peak_host_bytes = @max(self.peak_host_bytes, next_host_bytes);
        self.successful_reservations +|= 1;
        return .{
            .bank_epoch = self.epoch,
            .slot_index = @intCast(index),
            .generation = generation,
            .owner_key = owner_key,
            .claim = claim,
            .integrity = integrity,
        };
    }

    /// Commit binds an admitted claim to the selected capsule/owner key. The
    /// resources remain charged until the resulting receipt is released.
    pub fn commit(
        self: *Bank,
        reservation: Reservation,
    ) Error!Receipt {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReservation(reservation);
        if (slot.state != .reserved) return Error.InvalidTransition;
        const receipt_integrity = tokenIntegrity(
            self.epoch,
            reservation.slot_index,
            reservation.generation,
            reservation.owner_key,
            reservation.claim,
            receipt_domain,
        );
        slot.state = .committed;
        slot.integrity = receipt_integrity;
        self.successful_commits +|= 1;
        return .{
            .bank_epoch = self.epoch,
            .slot_index = reservation.slot_index,
            .generation = reservation.generation,
            .owner_key = reservation.owner_key,
            .claim = reservation.claim,
            .integrity = receipt_integrity,
        };
    }

    /// Roll back a reservation that never committed. A copied or stale token
    /// cannot subtract usage twice because slot generation/state are checked.
    pub fn cancel(
        self: *Bank,
        reservation: Reservation,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReservation(reservation);
        if (slot.state != .reserved) return Error.InvalidTransition;
        self.used = try subtractClaims(self.used, reservation.claim);
        slot.* = .{};
        self.cancellations +|= 1;
    }

    /// Validate that `receipt` still names the exact committed lease in this
    /// Bank. This is a read-only fencing operation: counters, usage and slot
    /// state are unchanged. Request-local transaction coordinators use it to
    /// bind work to a live admission authority without manufacturing a second
    /// receipt or extending the lease lifetime.
    pub fn validateCommitted(
        self: *Bank,
        receipt: Receipt,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReceipt(receipt);
        if (slot.state != .committed) return Error.InvalidTransition;
    }

    /// Open the sole mutable allocation charge beneath an immutable committed
    /// parent. A zero initial claim is valid so admission can precede the
    /// first allocator-backed payload. Opening is allowed only before the
    /// parent has ever entered a publication namespace.
    pub fn openChild(
        self: *Bank,
        receipt: Receipt,
        child_key: u64,
        ceiling: Claim,
        initial_claim: Claim,
    ) Error!ChildLease {
        if (child_key == 0 or ceiling.isZero() or
            !claimWithin(initial_claim, ceiling))
            return Error.InvalidClaim;
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReceipt(receipt);
        const child_slot = try self.childSlot(receipt.slot_index);
        if (slot.state != .committed or child_slot.active or
            slot.publication_request_epoch != 0 or
            slot.publication_session_id != 0 or slot.publication_active)
            return Error.InvalidTransition;

        const next = addClaims(self.used, initial_claim) catch {
            self.rejected_child_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        const next_host_bytes = next.hostBytes() catch {
            self.rejected_child_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        if (!self.limits.fitsWithHost(next, next_host_bytes)) {
            self.rejected_child_capacity +|= 1;
            return Error.CapacityExceeded;
        }
        const generation = try self.takeChildGeneration();
        const integrity = childLeaseIntegrity(
            receipt,
            child_key,
            generation,
            ceiling,
            initial_claim,
        );
        child_slot.* = .{
            .key = child_key,
            .generation = generation,
            .ceiling = ceiling,
            .claim = initial_claim,
            .integrity = integrity,
            .active = true,
        };
        self.used = next;
        self.peak = maxClaims(self.peak, next);
        self.peak_host_bytes = @max(self.peak_host_bytes, next_host_bytes);
        self.child_opens +|= 1;
        return .{
            .parent = receipt,
            .child_key = child_key,
            .generation = generation,
            .ceiling = ceiling,
            .claim = initial_claim,
            .integrity = integrity,
        };
    }

    /// Atomically replace one child charge. On overflow/capacity rejection the
    /// old handle, generation, claim, and aggregate usage remain unchanged.
    /// A successful resize returns the only current handle.
    pub fn growChild(
        self: *Bank,
        lease: ChildLease,
        new_claim: Claim,
    ) Error!ChildLease {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateChildLease(lease);
        if (slot.state != .committed or slot.publication_active or
            slot.publication_session_id != 0 or
            slot.publication_request_epoch != 0 or
            !claimWithin(lease.claim, new_claim))
            return Error.InvalidTransition;
        return self.resizeChildLocked(lease, new_claim, .grow);
    }

    /// Grow between publication waves using the exact bound coordinator and
    /// Bank-owned next sequence. The returned charge must be acquired before
    /// any corresponding allocator call.
    pub fn growChildForSession(
        self: *Bank,
        lease: ChildLease,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
        new_claim: Claim,
    ) Error!ChildLease {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateChildLease(lease);
        if (slot.state != .committed or slot.publication_active or
            slot.publication_request_epoch != request_epoch or
            slot.publication_session_id != session_id or
            slot.publication_next_sequence != expected_sequence or
            !claimWithin(lease.claim, new_claim))
            return Error.InvalidTransition;
        return self.resizeChildLocked(lease, new_claim, .grow);
    }

    /// Drop a bound-session allocation charge only after the caller has freed
    /// the covered payload. The exact coordinator and Bank-owned next sequence
    /// fence reclaim between publication waves; a live permit or stale copied
    /// generation cannot uncharge current memory. Failure leaves the old
    /// conservative charge and handle unchanged.
    pub fn shrinkChildForSessionAfterFree(
        self: *Bank,
        lease: ChildLease,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
        new_claim: Claim,
    ) Error!ChildLease {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateChildLease(lease);
        if (slot.state != .committed or slot.publication_active or
            slot.publication_request_epoch != request_epoch or
            slot.publication_session_id != session_id or
            slot.publication_next_sequence != expected_sequence or
            !claimWithin(new_claim, lease.claim))
            return Error.InvalidTransition;
        return self.resizeChildLocked(lease, new_claim, .shrink);
    }

    /// Drop a charge only after the caller has freed the corresponding
    /// allocator-backed payload and after publication is unbound. A failed
    /// shrink intentionally leaves the old overcharge and handle live.
    pub fn shrinkChildAfterFree(
        self: *Bank,
        lease: ChildLease,
        new_claim: Claim,
    ) Error!ChildLease {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateChildLease(lease);
        if (slot.state != .committed or slot.publication_active or
            slot.publication_session_id != 0 or
            !claimWithin(new_claim, lease.claim))
            return Error.InvalidTransition;
        return self.resizeChildLocked(lease, new_claim, .shrink);
    }

    /// Read-only generation and integrity fence for a child handle.
    pub fn validateChild(self: *Bank, lease: ChildLease) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.validateChildLease(lease);
    }

    /// Release a child only after publication has been unbound and its
    /// backing allocation has been freed. The Bank cannot prove allocator
    /// lifetime or physical residency, so callers must preserve that ordering
    /// contract.
    pub fn closeChild(self: *Bank, lease: ChildLease) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateChildLease(lease);
        if (slot.state != .committed or slot.publication_session_id != 0 or
            slot.publication_active)
            return Error.InvalidTransition;
        self.used = try subtractClaims(self.used, lease.claim);
        (try self.childSlot(lease.parent.slot_index)).* = .{};
        self.child_closes +|= 1;
    }

    fn resizeChildLocked(
        self: *Bank,
        lease: ChildLease,
        new_claim: Claim,
        direction: ChildResizeDirection,
    ) Error!ChildLease {
        if (!claimWithin(new_claim, lease.ceiling))
            return Error.InvalidClaim;
        if (std.meta.eql(lease.claim, new_claim)) return lease;

        const without_old = try subtractClaims(self.used, lease.claim);
        const next = addClaims(without_old, new_claim) catch {
            self.rejected_child_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        const next_host_bytes = next.hostBytes() catch {
            self.rejected_child_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        if (!self.limits.fitsWithHost(next, next_host_bytes)) {
            self.rejected_child_capacity +|= 1;
            return Error.CapacityExceeded;
        }
        const generation = try self.takeChildGeneration();
        const integrity = childLeaseIntegrity(
            lease.parent,
            lease.child_key,
            generation,
            lease.ceiling,
            new_claim,
        );
        const child_slot = try self.childSlot(lease.parent.slot_index);
        child_slot.generation = generation;
        child_slot.claim = new_claim;
        child_slot.integrity = integrity;
        self.used = next;
        self.peak = maxClaims(self.peak, next);
        self.peak_host_bytes = @max(self.peak_host_bytes, next_host_bytes);
        switch (direction) {
            .grow => self.child_grows +|= 1,
            .shrink => self.child_shrinks +|= 1,
        }
        return .{
            .parent = lease.parent,
            .child_key = lease.child_key,
            .generation = generation,
            .ceiling = lease.ceiling,
            .claim = new_claim,
            .integrity = integrity,
        };
    }

    /// Open an empty bounded ownership tree beneath a committed parent. Tree
    /// payload charges are additive to the immutable Receipt claim and remain
    /// zero until an allocation batch is reserved.
    pub fn openLeaseTree(
        self: *Bank,
        receipt: Receipt,
        tree_key: u64,
        authority_key: u64,
        ceiling: Claim,
    ) Error!LeaseTreeV1 {
        if (tree_key == 0 or authority_key == 0 or ceiling.isZero())
            return Error.InvalidClaim;
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReceipt(receipt);
        const storage = try self.leaseTreeStorage();
        const root = &storage.roots[receipt.slot_index];
        if (slot.state != .committed or root.active or
            slot.publication_request_epoch != 0 or
            slot.publication_session_id != 0 or slot.publication_active)
            return Error.InvalidTransition;

        const generations = try self.reserveLeaseGenerations(2);
        root.* = .{
            .active = true,
            .tree_key = tree_key,
            .authority_key = authority_key,
            .identity_generation = generations,
            .generation = generations + 1,
            .structural_revision = 1,
            .ceiling = ceiling,
        };
        self.refreshLeaseTreeRootLocked(receipt, root);
        self.lease_tree_opens +|= 1;
        return makeLeaseTree(receipt, root.*);
    }

    /// Add one immutable zero-charge scope, normally one decode lane. Scope
    /// topology is fixed before publication binding in LeaseTree v1.
    pub fn openLeaseScope(
        self: *Bank,
        tree: LeaseTreeV1,
        scope_key: u64,
        tenant_key: u64,
        ceiling: Claim,
    ) Error!LeaseScopeOpenV1 {
        if (scope_key == 0 or tenant_key == 0 or ceiling.isZero())
            return Error.InvalidClaim;
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseTreeLocked(tree);
        const parent_slot = try self.validateReceipt(tree.parent);
        if (root.pending_kind != .none or parent_slot.publication_active or
            parent_slot.publication_request_epoch != 0 or
            parent_slot.publication_session_id != 0 or
            !claimWithin(ceiling, root.ceiling))
            return Error.InvalidTransition;
        const storage = try self.leaseTreeStorage();
        var free_index: ?usize = null;
        for (storage.nodes, 0..) |node, index| {
            if (node.active and
                node.receipt_slot_index == tree.parent.slot_index and
                node.tree_identity_generation == tree.identity_generation and
                node.kind == .scope and node.node_key == scope_key)
                return Error.InvalidTransition;
            if (!node.active and free_index == null) free_index = index;
        }
        const index = free_index orelse {
            self.rejected_lease_nodes +|= 1;
            return Error.LeaseNodesExhausted;
        };
        if (root.structural_revision == std.math.maxInt(u64) or
            root.active_nodes == std.math.maxInt(u32))
            return Error.InvalidConfiguration;
        const generations = try self.reserveLeaseGenerations(2);
        var node: LeaseNodeSlot = .{
            .active = true,
            .receipt_slot_index = tree.parent.slot_index,
            .tree_identity_generation = tree.identity_generation,
            .generation = generations,
            .parent_index = no_lease_node,
            .parent_generation = tree.identity_generation,
            .node_key = scope_key,
            .tenant_key = tenant_key,
            .kind = .scope,
            .state = .live,
            .ceiling = ceiling,
        };
        node.integrity = leaseNodeIntegrity(tree.parent, tree.tree_key, @intCast(index), node);
        storage.nodes[index] = node;
        root.active_nodes += 1;
        root.generation = generations + 1;
        root.structural_revision += 1;
        self.refreshLeaseTreeRootLocked(tree.parent, root);
        self.lease_scope_opens +|= 1;
        return .{
            .tree = makeLeaseTree(tree.parent, root.*),
            .scope = makeLeaseNode(tree.parent, tree.tree_key, @intCast(index), node),
        };
    }

    pub fn openScope(
        self: *Bank,
        tree: LeaseTreeV1,
        scope_key: u64,
        tenant_key: u64,
        ceiling: Claim,
    ) Error!LeaseScopeOpenV1 {
        return self.openLeaseScope(
            tree,
            scope_key,
            tenant_key,
            ceiling,
        );
    }

    /// Reserve and charge a whole allocator wave atomically before any page
    /// allocation. `out_nodes` receives stable identities for every reserved
    /// leaf in `specs` order. Only one structural operation may be pending.
    pub fn reserveAllocationsForSession(
        self: *Bank,
        tree: LeaseTreeV1,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
        specs: []const LeaseAllocationSpecV1,
        out_nodes: []LeaseNodeV1,
    ) Error!LeaseAllocationReservationV1 {
        if (request_epoch == 0 or session_id == 0 or specs.len == 0 or
            specs.len > std.math.maxInt(u32) or out_nodes.len < specs.len)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseTreeLocked(tree);
        const parent_slot = try self.validateReceipt(tree.parent);
        if (root.pending_kind != .none or parent_slot.publication_active or
            parent_slot.publication_request_epoch != request_epoch or
            parent_slot.publication_session_id != session_id or
            parent_slot.publication_next_sequence != expected_sequence or
            root.structural_revision > std.math.maxInt(u64) - 2)
            return Error.InvalidTransition;
        const storage = try self.leaseTreeStorage();

        var free_nodes: usize = 0;
        for (storage.nodes) |node| if (!node.active) {
            free_nodes += 1;
        };
        if (free_nodes < specs.len) {
            self.rejected_lease_nodes +|= 1;
            return Error.LeaseNodesExhausted;
        }
        if (@as(u64, root.active_nodes) + specs.len > std.math.maxInt(u32))
            return Error.InvalidConfiguration;

        var aggregate: Claim = .{};
        for (specs, 0..) |spec, spec_index| {
            if (spec.node_key == 0 or spec.binding_key == 0 or
                spec.claim.isZero())
                return Error.InvalidClaim;
            const scope_slot = try self.validateLeaseNodeLocked(tree, spec.scope);
            if (scope_slot.kind != .scope or scope_slot.state != .live)
                return Error.InvalidTransition;
            aggregate = try addClaims(aggregate, spec.claim);

            for (storage.nodes) |node| {
                if (!node.active or node.receipt_slot_index != tree.parent.slot_index or
                    node.tree_identity_generation != tree.identity_generation or
                    node.kind != .allocation)
                    continue;
                if ((node.parent_index == spec.scope.node_index and
                    node.node_key == spec.node_key) or
                    node.binding_key == spec.binding_key)
                    return Error.InvalidTransition;
            }
            for (specs[0..spec_index]) |prior| {
                if ((prior.scope.node_index == spec.scope.node_index and
                    prior.node_key == spec.node_key) or
                    prior.binding_key == spec.binding_key)
                    return Error.InvalidTransition;
            }

            var scope_addition: Claim = .{};
            for (specs) |candidate| {
                if (candidate.scope.node_index == spec.scope.node_index)
                    scope_addition = try addClaims(scope_addition, candidate.claim);
            }
            const scope_next = try addClaims(scope_slot.subtree_claim, scope_addition);
            if (!claimWithin(scope_next, scope_slot.ceiling))
                return Error.InvalidClaim;
        }

        const next_tree_claim = try addClaims(root.current, aggregate);
        if (!claimWithin(next_tree_claim, root.ceiling))
            return Error.InvalidClaim;
        const next_used = addClaims(self.used, aggregate) catch {
            self.rejected_lease_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        const next_host_bytes = next_used.hostBytes() catch {
            self.rejected_lease_capacity +|= 1;
            return Error.ClaimOverflow;
        };
        if (!self.limits.fitsWithHost(next_used, next_host_bytes)) {
            self.rejected_lease_capacity +|= 1;
            return Error.CapacityExceeded;
        }

        // Batch, each node, reserve-tree, and settle/abort-tree generations
        // are preallocated before caller-side allocation can begin.
        const generation_count = std.math.add(u64, @intCast(specs.len), 3) catch
            return Error.InvalidConfiguration;
        const generation_start = try self.reserveLeaseGenerations(generation_count);
        const batch_generation = generation_start;
        const reserve_tree_generation = generation_start + 1 + specs.len;
        const completion_tree_generation = reserve_tree_generation + 1;

        var search_index: usize = 0;
        for (specs, 0..) |spec, spec_index| {
            while (storage.nodes[search_index].active) search_index += 1;
            const node_index = search_index;
            search_index += 1;
            var node: LeaseNodeSlot = .{
                .active = true,
                .receipt_slot_index = tree.parent.slot_index,
                .tree_identity_generation = tree.identity_generation,
                .generation = generation_start + 1 + spec_index,
                .parent_index = spec.scope.node_index,
                .parent_generation = spec.scope.generation,
                .node_key = spec.node_key,
                .tenant_key = spec.scope.tenant_key,
                .binding_key = spec.binding_key,
                .kind = .allocation,
                .state = .reserved_unmaterialized,
                .ceiling = spec.claim,
                .claim = spec.claim,
                .subtree_claim = spec.claim,
                .pending_generation = batch_generation,
            };
            node.integrity = leaseNodeIntegrity(
                tree.parent,
                tree.tree_key,
                @intCast(node_index),
                node,
            );
            storage.nodes[node_index] = node;
            const scope_slot = &storage.nodes[spec.scope.node_index];
            scope_slot.subtree_claim = addClaims(
                scope_slot.subtree_claim,
                spec.claim,
            ) catch @panic("validated LeaseTree scope addition overflowed");
            out_nodes[spec_index] = makeLeaseNode(
                tree.parent,
                tree.tree_key,
                @intCast(node_index),
                node,
            );
        }

        root.current = next_tree_claim;
        root.active_nodes += @intCast(specs.len);
        root.pending_kind = .allocation;
        root.pending_generation = batch_generation;
        root.pending_completion_generation = completion_tree_generation;
        root.pending_count = @intCast(specs.len);
        root.pending_claim = aggregate;
        root.pending_digest = leasePendingNodeDigest(
            storage.nodes,
            tree.parent.slot_index,
            tree.identity_generation,
            batch_generation,
            .reserved_unmaterialized,
        );
        root.generation = reserve_tree_generation;
        root.structural_revision += 1;
        self.used = next_used;
        self.peak = maxClaims(self.peak, next_used);
        self.peak_host_bytes = @max(self.peak_host_bytes, next_host_bytes);
        self.refreshLeaseTreeRootLocked(tree.parent, root);

        var batch: LeaseAllocationBatchV1 = .{
            .parent = tree.parent,
            .tree_key = tree.tree_key,
            .tree_identity_generation = tree.identity_generation,
            .tree_generation = root.generation,
            .structural_revision = root.structural_revision,
            .request_epoch = request_epoch,
            .session_id = session_id,
            .sequence = expected_sequence,
            .generation = batch_generation,
            .completion_tree_generation = completion_tree_generation,
            .node_count = @intCast(specs.len),
            .claim = aggregate,
            .node_set_digest = root.pending_digest,
            .integrity = 0,
        };
        batch.integrity = leaseAllocationBatchIntegrity(batch);
        self.lease_allocation_reserves +|= 1;
        return .{
            .tree = makeLeaseTree(tree.parent, root.*),
            .batch = batch,
        };
    }

    /// Settle a fully allocated batch. This changes lifecycle evidence but not
    /// accounting; reserved pages were already charged before allocation. The
    /// synchronous coordinator owns the single outcome decision. Racing copied
    /// commit/abort tokens is linearized by the Bank but remains caller misuse.
    pub fn commitAllocationsAfterAllocate(
        self: *Bank,
        batch: LeaseAllocationBatchV1,
    ) Error!LeaseTreeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseAllocationBatchLocked(batch);
        const storage = try self.leaseTreeStorage();
        for (storage.nodes) |*node| {
            if (node.active and
                node.receipt_slot_index == batch.parent.slot_index and
                node.tree_identity_generation == batch.tree_identity_generation and
                node.pending_generation == batch.generation)
            {
                if (node.state != .reserved_unmaterialized)
                    return Error.InvalidTransition;
                node.state = .live;
                node.pending_generation = 0;
            }
        }
        clearLeasePending(root);
        root.generation = batch.completion_tree_generation;
        root.structural_revision += 1;
        self.refreshLeaseTreeRootLocked(batch.parent, root);
        self.lease_allocation_materializations +|= 1;
        return makeLeaseTree(batch.parent, root.*);
    }

    /// Cancel a reserved batch only after every successful caller-side
    /// allocation has been freed. Invalid/stale batches retain a safe charge.
    /// This external ordering is trusted; the Bank cannot observe allocators.
    pub fn abortAllocationsAfterFree(
        self: *Bank,
        batch: LeaseAllocationBatchV1,
    ) Error!LeaseTreeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseAllocationBatchLocked(batch);
        const storage = try self.leaseTreeStorage();
        const next_tree_claim = try subtractClaims(root.current, batch.claim);
        const next_used = try subtractClaims(self.used, batch.claim);
        for (storage.nodes) |*node| {
            if (!node.active or node.receipt_slot_index != batch.parent.slot_index or
                node.tree_identity_generation != batch.tree_identity_generation or
                node.pending_generation != batch.generation)
                continue;
            if (node.state != .reserved_unmaterialized)
                return Error.InvalidTransition;
            const scope = &storage.nodes[node.parent_index];
            scope.subtree_claim = subtractClaims(
                scope.subtree_claim,
                node.claim,
            ) catch @panic("validated LeaseTree scope subtraction underflowed");
            node.* = .{};
        }
        root.current = next_tree_claim;
        root.active_nodes -= batch.node_count;
        clearLeasePending(root);
        root.generation = batch.completion_tree_generation;
        root.structural_revision += 1;
        self.used = next_used;
        self.refreshLeaseTreeRootLocked(batch.parent, root);
        self.lease_allocation_aborts +|= 1;
        return makeLeaseTree(batch.parent, root.*);
    }

    /// Quiesce every live allocation directly beneath `scope`. The returned
    /// ticket is cancellable but is not allocator-free authority. Charge,
    /// subtree sums, and Bank usage remain unchanged.
    pub fn beginRetireSubtreeForSession(
        self: *Bank,
        tree: LeaseTreeV1,
        scope: LeaseNodeV1,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
    ) Error!LeaseRetirePreparedV1 {
        if (request_epoch == 0 or session_id == 0)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseTreeLocked(tree);
        const scope_slot = try self.validateLeaseNodeLocked(tree, scope);
        const parent_slot = try self.validateReceipt(tree.parent);
        if (scope_slot.kind != .scope or scope_slot.state != .live or
            root.pending_kind != .none or parent_slot.publication_active or
            parent_slot.publication_request_epoch != request_epoch or
            parent_slot.publication_session_id != session_id or
            parent_slot.publication_next_sequence != expected_sequence or
            root.structural_revision > std.math.maxInt(u64) - 3)
            return Error.InvalidTransition;

        const storage = try self.leaseTreeStorage();
        var count: u32 = 0;
        var claim: Claim = .{};
        for (storage.nodes) |node| {
            if (!node.active or node.receipt_slot_index != tree.parent.slot_index or
                node.tree_identity_generation != tree.identity_generation or
                node.kind != .allocation or node.parent_index != scope.node_index)
                continue;
            if (node.state != .live or node.pin_count != 0 or
                node.published_references != 0)
                return Error.InvalidTransition;
            if (count == std.math.maxInt(u32))
                return Error.InvalidConfiguration;
            count += 1;
            claim = try addClaims(claim, node.claim);
        }
        if (count == 0 or claim.isZero() or
            !std.meta.eql(claim, scope_slot.subtree_claim))
            return Error.InvalidTransition;

        // Ticket, begin-tree, cancel/authorize-tree, irreversible free permit,
        // and free-completion-tree generations are reserved before quiescing.
        const generations = try self.reserveLeaseGenerations(5);
        const ticket_generation = generations;
        const begin_tree_generation = generations + 1;
        const decision_tree_generation = generations + 2;
        const free_permit_generation = generations + 3;
        const free_completion_tree_generation = generations + 4;
        for (storage.nodes) |*node| {
            if (node.active and node.receipt_slot_index == tree.parent.slot_index and
                node.tree_identity_generation == tree.identity_generation and
                node.kind == .allocation and node.parent_index == scope.node_index)
            {
                node.state = .quiescing;
                node.pending_generation = ticket_generation;
            }
        }
        root.pending_kind = .retire;
        root.pending_generation = ticket_generation;
        root.pending_completion_generation = decision_tree_generation;
        root.pending_free_permit_generation = free_permit_generation;
        root.pending_free_completion_generation = free_completion_tree_generation;
        root.pending_scope_index = scope.node_index;
        root.pending_count = count;
        root.pending_claim = claim;
        root.pending_digest = leasePendingNodeDigest(
            storage.nodes,
            tree.parent.slot_index,
            tree.identity_generation,
            ticket_generation,
            .quiescing,
        );
        root.generation = begin_tree_generation;
        root.structural_revision += 1;
        self.refreshLeaseTreeRootLocked(tree.parent, root);

        var ticket: LeaseRetireTicketV1 = .{
            .parent = tree.parent,
            .tree_key = tree.tree_key,
            .tree_identity_generation = tree.identity_generation,
            .tree_generation = root.generation,
            .structural_revision = root.structural_revision,
            .request_epoch = request_epoch,
            .session_id = session_id,
            .sequence = expected_sequence,
            .generation = ticket_generation,
            .decision_tree_generation = decision_tree_generation,
            .free_permit_generation = free_permit_generation,
            .free_completion_tree_generation = free_completion_tree_generation,
            .scope_index = scope.node_index,
            .scope_generation = scope.generation,
            .node_count = count,
            .claim = claim,
            .node_set_digest = root.pending_digest,
            .integrity = 0,
        };
        ticket.integrity = leaseRetireTicketIntegrity(ticket);
        self.lease_reclaim_prepares +|= 1;
        return .{
            .tree = makeLeaseTree(tree.parent, root.*),
            .ticket = ticket,
        };
    }

    /// Cancel only a quiescing ticket. Once `authorizeFree` succeeds this
    /// ticket becomes stale and no cancellation API accepts the FreePermit.
    pub fn cancelRetire(
        self: *Bank,
        ticket: LeaseRetireTicketV1,
    ) Error!LeaseTreeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseRetireTicketLocked(ticket);
        const storage = try self.leaseTreeStorage();
        for (storage.nodes) |*node| {
            if (node.active and
                node.receipt_slot_index == ticket.parent.slot_index and
                node.tree_identity_generation == ticket.tree_identity_generation and
                node.pending_generation == ticket.generation)
            {
                if (node.state != .quiescing)
                    return Error.InvalidTransition;
                node.state = .live;
                node.pending_generation = 0;
            }
        }
        clearLeasePending(root);
        root.generation = ticket.decision_tree_generation;
        root.structural_revision += 1;
        self.refreshLeaseTreeRootLocked(ticket.parent, root);
        self.lease_reclaim_cancels +|= 1;
        return makeLeaseTree(ticket.parent, root.*);
    }

    /// Irreversibly convert a quiescing ticket into allocator-free authority.
    /// All fallible caller validation must precede this call. If authorize wins
    /// a copied-ticket race, every cancel attempt observes the ticket as stale.
    pub fn authorizeFree(
        self: *Bank,
        ticket: LeaseRetireTicketV1,
    ) Error!LeaseFreeAuthorizedV1 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseRetireTicketLocked(ticket);
        const storage = try self.leaseTreeStorage();
        for (storage.nodes) |*node| {
            if (node.active and
                node.receipt_slot_index == ticket.parent.slot_index and
                node.tree_identity_generation == ticket.tree_identity_generation and
                node.pending_generation == ticket.generation)
            {
                if (node.state != .quiescing)
                    return Error.InvalidTransition;
                node.state = .free_authorized;
                node.pending_generation = ticket.free_permit_generation;
            }
        }
        root.pending_kind = .free;
        root.pending_generation = ticket.free_permit_generation;
        root.pending_completion_generation = ticket.free_completion_tree_generation;
        root.pending_free_permit_generation = 0;
        root.pending_free_completion_generation = 0;
        root.pending_digest = leasePendingNodeDigest(
            storage.nodes,
            ticket.parent.slot_index,
            ticket.tree_identity_generation,
            ticket.free_permit_generation,
            .free_authorized,
        );
        root.generation = ticket.decision_tree_generation;
        root.structural_revision += 1;
        self.refreshLeaseTreeRootLocked(ticket.parent, root);

        var permit: LeaseFreePermitV1 = .{
            .parent = ticket.parent,
            .tree_key = ticket.tree_key,
            .tree_identity_generation = ticket.tree_identity_generation,
            .tree_generation = root.generation,
            .structural_revision = root.structural_revision,
            .request_epoch = ticket.request_epoch,
            .session_id = ticket.session_id,
            .sequence = ticket.sequence,
            .generation = ticket.free_permit_generation,
            .completion_tree_generation = ticket.free_completion_tree_generation,
            .scope_index = ticket.scope_index,
            .scope_generation = ticket.scope_generation,
            .node_count = ticket.node_count,
            .claim = ticket.claim,
            .node_set_digest = root.pending_digest,
            .integrity = 0,
        };
        permit.integrity = leaseFreePermitIntegrity(permit);
        self.lease_reclaim_authorizations +|= 1;
        return .{
            .tree = makeLeaseTree(ticket.parent, root.*),
            .permit = permit,
        };
    }

    /// Uncharge a prepared subtree only after the caller has freed every
    /// allocator payload named by `permit`. Stale failure preserves overcharge.
    pub fn commitFreeAfterAllocatorFree(
        self: *Bank,
        permit: LeaseFreePermitV1,
    ) Error!LeaseTreeV1 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseFreePermitLocked(permit);
        const storage = try self.leaseTreeStorage();
        const next_tree_claim = try subtractClaims(root.current, permit.claim);
        const next_used = try subtractClaims(self.used, permit.claim);
        const scope = &storage.nodes[permit.scope_index];
        const next_scope_claim = try subtractClaims(
            scope.subtree_claim,
            permit.claim,
        );
        for (storage.nodes) |*node| {
            if (!node.active or node.receipt_slot_index != permit.parent.slot_index or
                node.tree_identity_generation != permit.tree_identity_generation or
                node.pending_generation != permit.generation)
                continue;
            if (node.state != .free_authorized)
                return Error.InvalidTransition;
            node.* = .{};
        }
        scope.subtree_claim = next_scope_claim;
        root.current = next_tree_claim;
        root.active_nodes -= permit.node_count;
        clearLeasePending(root);
        root.generation = permit.completion_tree_generation;
        root.structural_revision += 1;
        self.used = next_used;
        self.refreshLeaseTreeRootLocked(permit.parent, root);
        self.lease_reclaim_commits +|= 1;
        return makeLeaseTree(permit.parent, root.*);
    }

    pub fn validateLeaseTree(
        self: *Bank,
        tree: LeaseTreeV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.validateLeaseTreeLocked(tree);
    }

    pub fn validateLeaseNode(
        self: *Bank,
        tree: LeaseTreeV1,
        node: LeaseNodeV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.validateLeaseNodeLocked(tree, node);
    }

    /// Remove an empty tree and all of its zero-charge scopes. Publication
    /// must already be unbound; payload-bearing or pinned nodes reject close.
    pub fn closeLeaseTree(
        self: *Bank,
        tree: LeaseTreeV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseTreeLocked(tree);
        const parent_slot = try self.validateReceipt(tree.parent);
        if (root.pending_kind != .none or !root.current.isZero() or
            parent_slot.publication_active or
            parent_slot.publication_session_id != 0)
            return Error.InvalidTransition;
        const storage = try self.leaseTreeStorage();
        var node_count: u32 = 0;
        for (storage.nodes) |node| {
            if (!node.active or node.receipt_slot_index != tree.parent.slot_index or
                node.tree_identity_generation != tree.identity_generation)
                continue;
            if (node.kind != .scope or !node.claim.isZero() or
                !node.subtree_claim.isZero() or node.pin_count != 0 or
                node.published_references != 0)
                return Error.InvalidTransition;
            node_count += 1;
        }
        if (node_count != root.active_nodes)
            return Error.InvalidTransition;
        for (storage.nodes) |*node| {
            if (node.active and node.receipt_slot_index == tree.parent.slot_index and
                node.tree_identity_generation == tree.identity_generation)
                node.* = .{};
        }
        root.* = .{};
        self.lease_tree_closes +|= 1;
    }

    /// Bind a never-before-published committed lease to one address-stable
    /// coordinator. While bound, `release` is rejected. Closing is terminal
    /// for this receipt, so its request/sequence namespace cannot replay.
    pub fn bindPublicationSession(
        self: *Bank,
        receipt: Receipt,
        request_epoch: u64,
        session_id: usize,
    ) Error!void {
        if (request_epoch == 0 or session_id == 0)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = try self.validateReceipt(receipt);
        if (try self.hasActiveLeaseTreeLocked(receipt.slot_index))
            return Error.InvalidTransition;
        return self.bindPublicationSessionLocked(
            receipt,
            request_epoch,
            session_id,
        );
    }

    /// Atomically validate the exact child generation and bind its parent to
    /// one publication coordinator. If a copied child handle grows or closes
    /// first, binding observes it as stale; if binding wins, both mutations
    /// are rejected until the session closes.
    pub fn bindPublicationSessionWithChild(
        self: *Bank,
        lease: ChildLease,
        request_epoch: u64,
        session_id: usize,
    ) Error!void {
        if (request_epoch == 0 or session_id == 0)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = try self.validateChildLease(lease);
        return self.bindPublicationSessionLocked(
            lease.parent,
            request_epoch,
            session_id,
        );
    }

    /// Bind only after atomically validating the exact current tree token.
    /// Generic Receipt-only binding is rejected while a tree is active.
    pub fn bindPublicationSessionWithLeaseTree(
        self: *Bank,
        tree: LeaseTreeV1,
        request_epoch: u64,
        session_id: usize,
    ) Error!void {
        if (request_epoch == 0 or session_id == 0)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseTreeLocked(tree);
        if (root.pending_kind != .none)
            return Error.InvalidTransition;
        return self.bindPublicationSessionLocked(
            tree.parent,
            request_epoch,
            session_id,
        );
    }

    /// Bind a freshly reacquired tree at the exact next sequence recorded by a
    /// durable checkpoint. This is a restore-only authority boundary: the
    /// source epoch must be nonzero and different from this Bank, and the
    /// target receipt/tree must never have carried a publication session.
    pub fn bindRestoredPublicationSessionWithLeaseTree(
        self: *Bank,
        tree: LeaseTreeV1,
        source_bank_epoch: u64,
        request_epoch: u64,
        session_id: usize,
        restored_next_sequence: u64,
    ) Error!void {
        if (source_bank_epoch == 0 or source_bank_epoch == self.epoch or
            request_epoch == 0 or session_id == 0 or
            restored_next_sequence == 0)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseTreeLocked(tree);
        const slot = try self.validateReceipt(tree.parent);
        if (root.pending_kind != .none or slot.state != .committed or
            slot.publication_session_id != 0 or
            slot.publication_request_epoch != 0 or
            slot.publication_active)
            return Error.InvalidTransition;
        slot.publication_request_epoch = request_epoch;
        slot.publication_session_id = session_id;
        slot.publication_next_sequence = restored_next_sequence;
        slot.publication_active = false;
        slot.publication_permit_integrity = 0;
    }

    pub fn bindPublicationSessionWithTree(
        self: *Bank,
        tree: LeaseTreeV1,
        request_epoch: u64,
        session_id: usize,
    ) Error!void {
        return self.bindPublicationSessionWithLeaseTree(
            tree,
            request_epoch,
            session_id,
        );
    }

    fn bindPublicationSessionLocked(
        self: *Bank,
        receipt: Receipt,
        request_epoch: u64,
        session_id: usize,
    ) Error!void {
        const slot = try self.validateReceipt(receipt);
        if (slot.state != .committed or slot.publication_session_id != 0 or
            slot.publication_request_epoch != 0)
            return Error.InvalidTransition;
        slot.publication_request_epoch = request_epoch;
        slot.publication_session_id = session_id;
        slot.publication_next_sequence = 0;
        slot.publication_active = false;
        slot.publication_permit_integrity = 0;
    }

    /// Acquire the sole publication permit for `expected_sequence`. Aborting
    /// preserves the sequence for retry; committing advances it exactly once.
    pub fn beginPublication(
        self: *Bank,
        receipt: Receipt,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
    ) Error!PublicationPermit {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = try self.validateReceipt(receipt);
        if (try self.hasActiveLeaseTreeLocked(receipt.slot_index))
            return Error.InvalidTransition;
        return self.beginPublicationLocked(
            receipt,
            request_epoch,
            session_id,
            expected_sequence,
        );
    }

    /// Atomically validate the exact current allocator child generation and
    /// acquire the publication permit. This closes the validate-then-begin
    /// race for transaction ABIs whose proposal binds allocation commitment.
    pub fn beginPublicationWithChild(
        self: *Bank,
        lease: ChildLease,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
    ) Error!PublicationPermit {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = try self.validateChildLease(lease);
        return self.beginPublicationLocked(
            lease.parent,
            request_epoch,
            session_id,
            expected_sequence,
        );
    }

    /// Atomically validate exact aggregate claim, structural revision and
    /// allocation-state digest before acquiring the existing publication
    /// sequence permit. Pending/unmaterialized/free-authorized trees reject.
    pub fn beginPublicationWithLeaseTree(
        self: *Bank,
        tree: LeaseTreeV1,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
    ) Error!PublicationPermit {
        self.mutex.lock();
        defer self.mutex.unlock();

        const root = try self.validateLeaseTreeLocked(tree);
        if (root.pending_kind != .none)
            return Error.InvalidTransition;
        return self.beginPublicationLocked(
            tree.parent,
            request_epoch,
            session_id,
            expected_sequence,
        );
    }

    pub fn beginPublicationWithTree(
        self: *Bank,
        tree: LeaseTreeV1,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
    ) Error!PublicationPermit {
        return self.beginPublicationWithLeaseTree(
            tree,
            request_epoch,
            session_id,
            expected_sequence,
        );
    }

    fn beginPublicationLocked(
        self: *Bank,
        receipt: Receipt,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
    ) Error!PublicationPermit {
        const slot = try self.validateReceipt(receipt);
        if (try self.hasPendingLeaseTreeLocked(receipt.slot_index))
            return Error.InvalidTransition;
        if (slot.state != .committed or
            slot.publication_request_epoch != request_epoch or
            slot.publication_session_id != session_id or
            slot.publication_active or
            slot.publication_next_sequence != expected_sequence)
            return Error.InvalidTransition;
        if (slot.publication_permit_generation == std.math.maxInt(u64))
            return Error.InvalidConfiguration;

        slot.publication_permit_generation += 1;
        const permit: PublicationPermit = .{
            .receipt = receipt,
            .request_epoch = request_epoch,
            .session_id = session_id,
            .sequence = expected_sequence,
            .generation = slot.publication_permit_generation,
            .integrity = publicationPermitIntegrity(
                receipt,
                request_epoch,
                session_id,
                expected_sequence,
                slot.publication_permit_generation,
            ),
        };
        slot.publication_active = true;
        slot.publication_permit_integrity = permit.integrity;
        return permit;
    }

    pub fn validatePublication(
        self: *Bank,
        permit: PublicationPermit,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = try self.validatePublicationPermit(permit);
    }

    /// Read-only address/sequence fence for a coordinator that must validate
    /// its identity before adopting private executor state. The later
    /// `beginPublication` remains the atomic single-flight authority.
    pub fn validatePublicationSession(
        self: *Bank,
        receipt: Receipt,
        request_epoch: u64,
        session_id: usize,
        expected_sequence: u64,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReceipt(receipt);
        if (try self.hasPendingLeaseTreeLocked(receipt.slot_index))
            return Error.InvalidTransition;
        if (slot.state != .committed or
            slot.publication_request_epoch != request_epoch or
            slot.publication_session_id != session_id or
            slot.publication_active or
            slot.publication_next_sequence != expected_sequence)
            return Error.InvalidTransition;
    }

    /// Finish a permit after all prevalidated request-local state changes.
    /// Invalid use traps in every optimization mode instead of silently
    /// publishing a sequence whose Bank fence did not advance.
    pub fn commitPublicationAssumeValid(
        self: *Bank,
        permit: PublicationPermit,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.validatePublicationPermit(permit) catch
            @panic("invalid prepared ResourceBank publication permit");
        if (permit.sequence == std.math.maxInt(u64))
            @panic("exhausted ResourceBank publication sequence");
        slot.publication_active = false;
        slot.publication_permit_integrity = 0;
        slot.publication_next_sequence = permit.sequence + 1;
    }

    pub fn abortPublication(
        self: *Bank,
        permit: PublicationPermit,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = try self.validatePublicationPermit(permit);
        slot.publication_active = false;
        slot.publication_permit_integrity = 0;
    }

    /// Unbind only an idle session at its exact Bank-owned next sequence.
    /// The request epoch/sequence remain as a tombstone until receipt release.
    pub fn closePublicationSession(
        self: *Bank,
        receipt: Receipt,
        request_epoch: u64,
        session_id: usize,
        expected_next_sequence: u64,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReceipt(receipt);
        if (try self.leaseTreeBlocksSessionCloseLocked(receipt.slot_index))
            return Error.InvalidTransition;
        if (slot.state != .committed or
            slot.publication_request_epoch != request_epoch or
            slot.publication_session_id != session_id or
            slot.publication_active or
            slot.publication_next_sequence != expected_next_sequence)
            return Error.InvalidTransition;
        slot.publication_request_epoch = request_epoch;
        slot.publication_session_id = 0;
        slot.publication_permit_integrity = 0;
    }

    /// Atomically close one exact publication-session namespace and release
    /// its committed receipt. External coordinators use this terminal path so
    /// no observer can interleave between clearing the session fence and
    /// returning the charged capacity.
    pub fn closePublicationSessionAndRelease(
        self: *Bank,
        receipt: Receipt,
        request_epoch: u64,
        session_id: usize,
        expected_next_sequence: u64,
    ) Error!void {
        if (request_epoch == 0 or session_id == 0)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReceipt(receipt);
        const child_active = if (self.child_slots) |storage|
            storage[receipt.slot_index].active
        else
            false;
        const lease_tree_active = try self.hasActiveLeaseTreeLocked(
            receipt.slot_index,
        );
        if (slot.state != .committed or
            slot.publication_request_epoch != request_epoch or
            slot.publication_session_id != session_id or
            slot.publication_active or
            slot.publication_next_sequence != expected_next_sequence or
            child_active or lease_tree_active)
            return Error.InvalidTransition;
        const next_used = try subtractClaims(self.used, receipt.claim);
        self.used = next_used;
        slot.* = .{};
        self.releases +|= 1;
    }

    /// Release one committed receipt exactly once.
    pub fn release(self: *Bank, receipt: Receipt) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const slot = try self.validateReceipt(receipt);
        const child_active = if (self.child_slots) |storage|
            storage[receipt.slot_index].active
        else
            false;
        const lease_tree_active = try self.hasActiveLeaseTreeLocked(
            receipt.slot_index,
        );
        if (slot.state != .committed or slot.publication_session_id != 0 or
            slot.publication_active or child_active or lease_tree_active)
            return Error.InvalidTransition;
        self.used = try subtractClaims(self.used, receipt.claim);
        slot.* = .{};
        self.releases +|= 1;
    }

    pub fn snapshot(self: *Bank) Error!Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const extended = try self.snapshotV2Locked();
        return .{
            .abi_version = abi,
            .bank_epoch = extended.bank_epoch,
            .limits = extended.limits,
            .used = extended.used,
            .peak = extended.peak,
            .peak_host_bytes = extended.peak_host_bytes,
            .active_reservations = extended.active_reservations,
            .committed_receipts = extended.committed_receipts,
            .successful_reservations = extended.successful_reservations,
            .successful_commits = extended.successful_commits,
            .cancellations = extended.cancellations,
            .releases = extended.releases,
            .rejected_capacity = extended.rejected_capacity,
            .rejected_slots = extended.rejected_slots,
        };
    }

    /// Child-aware telemetry. Receipt/permit validation remains on ABI v1;
    /// consumers that inspect child counters must explicitly select v2.
    pub fn snapshotV2(self: *Bank) Error!SnapshotV2 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.snapshotV2Locked();
    }

    pub fn snapshotV3(self: *Bank) Error!SnapshotV3 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const base = try self.snapshotV2Locked();
        var derived_used: Claim = .{};
        for (self.slots) |slot| {
            if (slot.state != .free)
                derived_used = try addClaims(derived_used, slot.claim);
        }
        if (self.child_slots) |children| for (children, 0..) |child, index| {
            if (!child.active) continue;
            if (self.slots[index].state != .committed)
                return Error.InvalidTransition;
            derived_used = try addClaims(derived_used, child.claim);
        };

        var active_trees: usize = 0;
        var active_scopes: usize = 0;
        var active_nodes: usize = 0;
        var reserved_allocations: usize = 0;
        var live_allocations: usize = 0;
        var quiescing_allocations: usize = 0;
        var free_authorized_allocations: usize = 0;
        var root_pool_bytes: usize = 0;
        var node_pool_bytes: usize = 0;
        if (self.lease_tree_storage) |storage| {
            root_pool_bytes = std.math.mul(
                usize,
                storage.roots.len,
                @sizeOf(LeaseTreeRootSlot),
            ) catch return Error.ClaimOverflow;
            node_pool_bytes = std.math.mul(
                usize,
                storage.nodes.len,
                @sizeOf(LeaseNodeSlot),
            ) catch return Error.ClaimOverflow;
            for (storage.roots, 0..) |root_value, root_index| {
                if (!root_value.active) continue;
                if (self.slots[root_index].state != .committed)
                    return Error.InvalidTransition;
                const receipt = receiptFromSlot(
                    self.epoch,
                    @intCast(root_index),
                    self.slots[root_index],
                );
                _ = try self.validateLeaseTreeLocked(makeLeaseTree(
                    receipt,
                    root_value,
                ));
                active_trees += 1;
                var node_count: u32 = 0;
                var tree_claim: Claim = .{};
                for (storage.nodes, 0..) |node, node_index| {
                    if (!node.active or node.receipt_slot_index != root_index or
                        node.tree_identity_generation != root_value.identity_generation)
                        continue;
                    node_count += 1;
                    active_nodes += 1;
                    if (node.integrity != leaseNodeIntegrity(
                        receipt,
                        root_value.tree_key,
                        @intCast(node_index),
                        node,
                    )) return Error.InvalidTransition;
                    switch (node.kind) {
                        .scope => {
                            if (node.state != .live or !node.claim.isZero() or
                                node.binding_key != 0 or
                                node.parent_index != no_lease_node or
                                node.parent_generation != root_value.identity_generation)
                                return Error.InvalidTransition;
                            var children_claim: Claim = .{};
                            for (storage.nodes) |child| {
                                if (child.active and
                                    child.receipt_slot_index == root_index and
                                    child.tree_identity_generation == root_value.identity_generation and
                                    child.kind == .allocation and
                                    child.parent_index == node_index)
                                    children_claim = try addClaims(children_claim, child.claim);
                            }
                            if (!std.meta.eql(children_claim, node.subtree_claim) or
                                !claimWithin(node.subtree_claim, node.ceiling))
                                return Error.InvalidTransition;
                            active_scopes += 1;
                        },
                        .allocation => {
                            if (node.claim.isZero() or
                                !std.meta.eql(node.claim, node.ceiling) or
                                !std.meta.eql(node.claim, node.subtree_claim) or
                                node.parent_index >= storage.nodes.len)
                                return Error.InvalidTransition;
                            const scope = storage.nodes[node.parent_index];
                            if (!scope.active or scope.kind != .scope or
                                scope.receipt_slot_index != root_index or
                                scope.tree_identity_generation != root_value.identity_generation or
                                scope.generation != node.parent_generation or
                                scope.tenant_key != node.tenant_key)
                                return Error.InvalidTransition;
                            tree_claim = try addClaims(tree_claim, node.claim);
                            switch (node.state) {
                                .reserved_unmaterialized => reserved_allocations += 1,
                                .live => live_allocations += 1,
                                .quiescing => quiescing_allocations += 1,
                                .free_authorized => free_authorized_allocations += 1,
                                .free => return Error.InvalidTransition,
                            }
                        },
                    }
                }
                if (node_count != root_value.active_nodes or
                    !std.meta.eql(tree_claim, root_value.current) or
                    !claimWithin(root_value.current, root_value.ceiling))
                    return Error.InvalidTransition;
                try validateLeasePendingState(storage.nodes, @intCast(root_index), root_value);
                derived_used = try addClaims(derived_used, root_value.current);
            }
            for (storage.nodes) |node| {
                if (!node.active) continue;
                if (node.receipt_slot_index >= storage.roots.len)
                    return Error.InvalidTransition;
                const root = storage.roots[node.receipt_slot_index];
                if (!root.active or
                    root.identity_generation != node.tree_identity_generation)
                    return Error.InvalidTransition;
            }
        }
        if (!std.meta.eql(derived_used, self.used))
            return Error.InvalidTransition;
        _ = try derived_used.hostBytes();
        const metadata_bytes = std.math.add(
            usize,
            root_pool_bytes,
            node_pool_bytes,
        ) catch return Error.ClaimOverflow;

        return .{
            .abi_version = snapshot_v3_abi,
            .bank_epoch = base.bank_epoch,
            .limits = base.limits,
            .used = base.used,
            .peak = base.peak,
            .peak_host_bytes = base.peak_host_bytes,
            .active_reservations = base.active_reservations,
            .committed_receipts = base.committed_receipts,
            .active_child_leases = base.active_child_leases,
            .active_lease_trees = active_trees,
            .active_lease_scopes = active_scopes,
            .active_lease_nodes = active_nodes,
            .lease_root_pool_bytes = root_pool_bytes,
            .lease_node_pool_bytes = node_pool_bytes,
            .lease_metadata_bytes = metadata_bytes,
            .reserved_unmaterialized_allocations = reserved_allocations,
            .live_allocations = live_allocations,
            .quiescing_allocations = quiescing_allocations,
            .free_authorized_allocations = free_authorized_allocations,
            .successful_reservations = base.successful_reservations,
            .successful_commits = base.successful_commits,
            .cancellations = base.cancellations,
            .releases = base.releases,
            .rejected_capacity = base.rejected_capacity,
            .rejected_slots = base.rejected_slots,
            .child_opens = base.child_opens,
            .child_grows = base.child_grows,
            .child_shrinks = base.child_shrinks,
            .child_closes = base.child_closes,
            .rejected_child_capacity = base.rejected_child_capacity,
            .lease_tree_opens = self.lease_tree_opens,
            .lease_scope_opens = self.lease_scope_opens,
            .lease_allocation_reserves = self.lease_allocation_reserves,
            .lease_allocation_materializations = self.lease_allocation_materializations,
            .lease_allocation_aborts = self.lease_allocation_aborts,
            .lease_reclaim_prepares = self.lease_reclaim_prepares,
            .lease_reclaim_authorizations = self.lease_reclaim_authorizations,
            .lease_reclaim_cancels = self.lease_reclaim_cancels,
            .lease_reclaim_commits = self.lease_reclaim_commits,
            .lease_tree_closes = self.lease_tree_closes,
            .rejected_lease_capacity = self.rejected_lease_capacity,
            .rejected_lease_nodes = self.rejected_lease_nodes,
        };
    }

    fn snapshotV2Locked(self: *Bank) Error!SnapshotV2 {
        var active: usize = 0;
        var committed: usize = 0;
        var children: usize = 0;
        for (self.slots) |slot| switch (slot.state) {
            .free => {},
            .reserved => active += 1,
            .committed => committed += 1,
        };
        if (self.child_slots) |storage| for (storage, 0..) |child, index| {
            if (!child.active) continue;
            if (self.slots[index].state != .committed)
                return Error.InvalidTransition;
            children += 1;
        };
        // Re-evaluate live aggregate usage so corruption cannot be hidden in a
        // telemetry path. Per-class peaks need not have occurred together;
        // their sum is therefore not a valid aggregate-overflow invariant.
        _ = try self.used.hostBytes();
        return .{
            .abi_version = snapshot_abi,
            .bank_epoch = self.epoch,
            .limits = self.limits,
            .used = self.used,
            .peak = self.peak,
            .peak_host_bytes = self.peak_host_bytes,
            .active_reservations = active,
            .committed_receipts = committed,
            .active_child_leases = children,
            .successful_reservations = self.successful_reservations,
            .successful_commits = self.successful_commits,
            .cancellations = self.cancellations,
            .releases = self.releases,
            .rejected_capacity = self.rejected_capacity,
            .rejected_slots = self.rejected_slots,
            .child_opens = self.child_opens,
            .child_grows = self.child_grows,
            .child_shrinks = self.child_shrinks,
            .child_closes = self.child_closes,
            .rejected_child_capacity = self.rejected_child_capacity,
        };
    }

    fn leaseTreeStorage(self: *Bank) Error!LeaseTreeStorage {
        const storage = self.lease_tree_storage orelse
            return Error.InvalidConfiguration;
        if (storage.roots.len != self.slots.len or storage.nodes.len == 0 or
            storage.nodes.len > std.math.maxInt(u32))
            return Error.InvalidConfiguration;
        return storage;
    }

    fn hasActiveLeaseTreeLocked(
        self: *Bank,
        slot_index: u32,
    ) Error!bool {
        const storage = self.lease_tree_storage orelse return false;
        if (storage.roots.len != self.slots.len or slot_index >= storage.roots.len)
            return Error.InvalidConfiguration;
        return storage.roots[slot_index].active;
    }

    fn hasPendingLeaseTreeLocked(
        self: *Bank,
        slot_index: u32,
    ) Error!bool {
        const storage = self.lease_tree_storage orelse return false;
        if (storage.roots.len != self.slots.len or slot_index >= storage.roots.len)
            return Error.InvalidConfiguration;
        const root = storage.roots[slot_index];
        return root.active and root.pending_kind != .none;
    }

    fn leaseTreeBlocksSessionCloseLocked(
        self: *Bank,
        slot_index: u32,
    ) Error!bool {
        const storage = self.lease_tree_storage orelse return false;
        if (storage.roots.len != self.slots.len or slot_index >= storage.roots.len)
            return Error.InvalidConfiguration;
        const root = storage.roots[slot_index];
        return root.active and
            (root.pending_kind != .none or !root.current.isZero());
    }

    fn reserveLeaseGenerations(self: *Bank, count: u64) Error!u64 {
        if (count == 0 or self.next_lease_generation == 0 or
            self.next_lease_generation == std.math.maxInt(u64) or
            count >= std.math.maxInt(u64) - self.next_lease_generation)
            return Error.InvalidConfiguration;
        const first = self.next_lease_generation;
        self.next_lease_generation += count;
        return first;
    }

    fn refreshLeaseTreeRootLocked(
        self: *Bank,
        receipt: Receipt,
        root: *LeaseTreeRootSlot,
    ) void {
        const storage = self.lease_tree_storage orelse
            @panic("LeaseTree storage disappeared");
        root.state_digest = leaseTreeStateDigest(
            storage.nodes,
            receipt.slot_index,
            root.*,
        );
        root.integrity = leaseTreeIntegrity(receipt, root.*);
    }

    fn validateLeaseTreeLocked(
        self: *Bank,
        tree: LeaseTreeV1,
    ) Error!*LeaseTreeRootSlot {
        if (tree.abi_version != lease_tree_abi)
            return Error.StaleReservation;
        const parent_slot = try self.validateReceipt(tree.parent);
        if (parent_slot.state != .committed)
            return Error.InvalidTransition;
        const storage = try self.leaseTreeStorage();
        const root = &storage.roots[tree.parent.slot_index];
        if (!root.active or root.tree_key != tree.tree_key or
            root.authority_key != tree.authority_key or
            root.identity_generation != tree.identity_generation or
            root.generation != tree.generation or
            root.structural_revision != tree.structural_revision or
            !std.meta.eql(root.ceiling, tree.ceiling) or
            !std.meta.eql(root.current, tree.current) or
            root.active_nodes != tree.active_nodes or
            root.state_digest != tree.state_digest or
            root.integrity != tree.integrity or
            root.state_digest != leaseTreeStateDigest(
                storage.nodes,
                tree.parent.slot_index,
                root.*,
            ) or
            root.integrity != leaseTreeIntegrity(tree.parent, root.*) or
            tree.integrity != leaseTreeIntegrity(tree.parent, root.*))
            return Error.StaleReservation;
        try validateLeaseTreeAccounting(
            storage.nodes,
            tree.parent,
            root.*,
        );
        return root;
    }

    fn validateLeaseNodeLocked(
        self: *Bank,
        tree: LeaseTreeV1,
        node: LeaseNodeV1,
    ) Error!*LeaseNodeSlot {
        _ = try self.validateLeaseTreeLocked(tree);
        if (node.abi_version != lease_node_abi or
            !std.meta.eql(node.parent, tree.parent) or
            node.tree_key != tree.tree_key or
            node.tree_identity_generation != tree.identity_generation)
            return Error.StaleReservation;
        const storage = try self.leaseTreeStorage();
        if (node.node_index >= storage.nodes.len)
            return Error.StaleReservation;
        const slot = &storage.nodes[node.node_index];
        if (!slot.active or
            slot.receipt_slot_index != tree.parent.slot_index or
            slot.tree_identity_generation != tree.identity_generation or
            slot.generation != node.generation or
            slot.parent_index != node.parent_index or
            slot.parent_generation != node.parent_generation or
            slot.node_key != node.node_key or
            slot.tenant_key != node.tenant_key or
            slot.binding_key != node.binding_key or
            slot.kind != node.kind or
            !std.meta.eql(slot.ceiling, node.ceiling) or
            !std.meta.eql(slot.claim, node.claim) or
            slot.integrity != node.integrity or
            node.integrity != leaseNodeIntegrity(
                tree.parent,
                tree.tree_key,
                node.node_index,
                slot.*,
            ))
            return Error.StaleReservation;
        return slot;
    }

    fn validateLeaseAllocationBatchLocked(
        self: *Bank,
        batch: LeaseAllocationBatchV1,
    ) Error!*LeaseTreeRootSlot {
        if (batch.abi_version != lease_allocation_batch_abi or
            batch.node_count == 0 or batch.claim.isZero() or
            batch.integrity != leaseAllocationBatchIntegrity(batch))
            return Error.StaleReservation;
        const parent_slot = try self.validateReceipt(batch.parent);
        const storage = try self.leaseTreeStorage();
        const root = &storage.roots[batch.parent.slot_index];
        if (parent_slot.state != .committed or parent_slot.publication_active or
            parent_slot.publication_request_epoch != batch.request_epoch or
            parent_slot.publication_session_id != batch.session_id or
            parent_slot.publication_next_sequence != batch.sequence or
            !root.active or root.tree_key != batch.tree_key or
            root.identity_generation != batch.tree_identity_generation or
            root.generation != batch.tree_generation or
            root.structural_revision != batch.structural_revision or
            root.pending_kind != .allocation or
            root.pending_generation != batch.generation or
            root.pending_completion_generation != batch.completion_tree_generation or
            root.pending_free_permit_generation != 0 or
            root.pending_free_completion_generation != 0 or
            root.pending_count != batch.node_count or
            !std.meta.eql(root.pending_claim, batch.claim) or
            root.pending_digest != batch.node_set_digest or
            root.pending_scope_index != no_lease_node or
            root.state_digest != leaseTreeStateDigest(
                storage.nodes,
                batch.parent.slot_index,
                root.*,
            ) or root.integrity != leaseTreeIntegrity(batch.parent, root.*))
            return Error.InvalidTransition;
        try validateLeasePendingState(
            storage.nodes,
            batch.parent.slot_index,
            root.*,
        );
        return root;
    }

    fn validateLeaseRetireTicketLocked(
        self: *Bank,
        ticket: LeaseRetireTicketV1,
    ) Error!*LeaseTreeRootSlot {
        if (ticket.abi_version != lease_retire_ticket_abi or
            ticket.node_count == 0 or ticket.claim.isZero() or
            ticket.integrity != leaseRetireTicketIntegrity(ticket))
            return Error.StaleReservation;
        const parent_slot = try self.validateReceipt(ticket.parent);
        const storage = try self.leaseTreeStorage();
        if (ticket.scope_index >= storage.nodes.len)
            return Error.StaleReservation;
        const root = &storage.roots[ticket.parent.slot_index];
        const scope = storage.nodes[ticket.scope_index];
        if (parent_slot.state != .committed or parent_slot.publication_active or
            parent_slot.publication_request_epoch != ticket.request_epoch or
            parent_slot.publication_session_id != ticket.session_id or
            parent_slot.publication_next_sequence != ticket.sequence or
            !root.active or root.tree_key != ticket.tree_key or
            root.identity_generation != ticket.tree_identity_generation or
            root.generation != ticket.tree_generation or
            root.structural_revision != ticket.structural_revision or
            root.pending_kind != .retire or
            root.pending_generation != ticket.generation or
            root.pending_completion_generation != ticket.decision_tree_generation or
            root.pending_free_permit_generation != ticket.free_permit_generation or
            root.pending_free_completion_generation != ticket.free_completion_tree_generation or
            root.pending_scope_index != ticket.scope_index or
            root.pending_count != ticket.node_count or
            !std.meta.eql(root.pending_claim, ticket.claim) or
            root.pending_digest != ticket.node_set_digest or
            !scope.active or scope.kind != .scope or
            scope.generation != ticket.scope_generation or
            scope.receipt_slot_index != ticket.parent.slot_index or
            scope.tree_identity_generation != ticket.tree_identity_generation or
            root.state_digest != leaseTreeStateDigest(
                storage.nodes,
                ticket.parent.slot_index,
                root.*,
            ) or root.integrity != leaseTreeIntegrity(ticket.parent, root.*))
            return Error.InvalidTransition;
        try validateLeasePendingState(
            storage.nodes,
            ticket.parent.slot_index,
            root.*,
        );
        return root;
    }

    fn validateLeaseFreePermitLocked(
        self: *Bank,
        permit: LeaseFreePermitV1,
    ) Error!*LeaseTreeRootSlot {
        if (permit.abi_version != lease_free_permit_abi or
            permit.node_count == 0 or permit.claim.isZero() or
            permit.integrity != leaseFreePermitIntegrity(permit))
            return Error.StaleReservation;
        const parent_slot = try self.validateReceipt(permit.parent);
        const storage = try self.leaseTreeStorage();
        if (permit.scope_index >= storage.nodes.len)
            return Error.StaleReservation;
        const root = &storage.roots[permit.parent.slot_index];
        const scope = storage.nodes[permit.scope_index];
        if (parent_slot.state != .committed or parent_slot.publication_active or
            parent_slot.publication_request_epoch != permit.request_epoch or
            parent_slot.publication_session_id != permit.session_id or
            parent_slot.publication_next_sequence != permit.sequence or
            !root.active or root.tree_key != permit.tree_key or
            root.identity_generation != permit.tree_identity_generation or
            root.generation != permit.tree_generation or
            root.structural_revision != permit.structural_revision or
            root.pending_kind != .free or
            root.pending_generation != permit.generation or
            root.pending_completion_generation != permit.completion_tree_generation or
            root.pending_free_permit_generation != 0 or
            root.pending_free_completion_generation != 0 or
            root.pending_scope_index != permit.scope_index or
            root.pending_count != permit.node_count or
            !std.meta.eql(root.pending_claim, permit.claim) or
            root.pending_digest != permit.node_set_digest or
            !scope.active or scope.kind != .scope or
            scope.generation != permit.scope_generation or
            scope.receipt_slot_index != permit.parent.slot_index or
            scope.tree_identity_generation != permit.tree_identity_generation or
            root.state_digest != leaseTreeStateDigest(
                storage.nodes,
                permit.parent.slot_index,
                root.*,
            ) or root.integrity != leaseTreeIntegrity(permit.parent, root.*))
            return Error.InvalidTransition;
        try validateLeasePendingState(
            storage.nodes,
            permit.parent.slot_index,
            root.*,
        );
        return root;
    }

    fn takeChildGeneration(self: *Bank) Error!u64 {
        if (self.next_child_generation == 0 or
            self.next_child_generation == std.math.maxInt(u64))
            return Error.InvalidConfiguration;
        const generation = self.next_child_generation;
        self.next_child_generation += 1;
        return generation;
    }

    fn childSlot(self: *Bank, slot_index: u32) Error!*ChildSlot {
        const storage = self.child_slots orelse
            return Error.InvalidConfiguration;
        const index: usize = slot_index;
        if (storage.len != self.slots.len or index >= storage.len)
            return Error.InvalidConfiguration;
        return &storage[index];
    }

    fn validateReservation(
        self: *Bank,
        reservation: Reservation,
    ) Error!*Slot {
        if (reservation.bank_epoch != self.epoch or
            reservation.slot_index >= self.slots.len)
            return Error.StaleReservation;
        const slot = &self.slots[reservation.slot_index];
        if (slot.state == .free or slot.generation != reservation.generation or
            slot.owner_key != reservation.owner_key or
            !std.meta.eql(slot.claim, reservation.claim) or
            slot.integrity != reservation.integrity or
            reservation.integrity != tokenIntegrity(
                self.epoch,
                reservation.slot_index,
                reservation.generation,
                reservation.owner_key,
                reservation.claim,
                reservation_domain,
            ))
            return Error.StaleReservation;
        return slot;
    }

    fn validateReceipt(
        self: *Bank,
        receipt: Receipt,
    ) Error!*Slot {
        if (receipt.bank_epoch != self.epoch or
            receipt.slot_index >= self.slots.len)
            return Error.StaleReservation;
        const slot = &self.slots[receipt.slot_index];
        if (slot.state == .free or slot.generation != receipt.generation or
            slot.owner_key != receipt.owner_key or
            !std.meta.eql(slot.claim, receipt.claim) or
            slot.integrity != receipt.integrity or
            receipt.integrity != tokenIntegrity(
                self.epoch,
                receipt.slot_index,
                receipt.generation,
                receipt.owner_key,
                receipt.claim,
                receipt_domain,
            ))
            return Error.StaleReservation;
        return slot;
    }

    fn validateChildLease(
        self: *Bank,
        lease: ChildLease,
    ) Error!*Slot {
        if (lease.abi_version != child_lease_abi)
            return Error.StaleReservation;
        const slot = try self.validateReceipt(lease.parent);
        const child_slot = try self.childSlot(lease.parent.slot_index);
        if (slot.state != .committed or !child_slot.active or
            child_slot.key != lease.child_key or
            child_slot.generation != lease.generation or
            !std.meta.eql(child_slot.ceiling, lease.ceiling) or
            !std.meta.eql(child_slot.claim, lease.claim) or
            child_slot.integrity != lease.integrity or
            lease.integrity != childLeaseIntegrity(
                lease.parent,
                lease.child_key,
                lease.generation,
                lease.ceiling,
                lease.claim,
            ))
            return Error.StaleReservation;
        return slot;
    }

    fn validatePublicationPermit(
        self: *Bank,
        permit: PublicationPermit,
    ) Error!*Slot {
        if (permit.abi_version != publication_fence_abi)
            return Error.StaleReservation;
        const slot = try self.validateReceipt(permit.receipt);
        if (slot.state != .committed or
            slot.publication_request_epoch != permit.request_epoch or
            slot.publication_session_id != permit.session_id or
            !slot.publication_active or
            slot.publication_next_sequence != permit.sequence or
            slot.publication_permit_generation != permit.generation or
            slot.publication_permit_integrity != permit.integrity or
            permit.integrity != publicationPermitIntegrity(
                permit.receipt,
                permit.request_epoch,
                permit.session_id,
                permit.sequence,
                permit.generation,
            ))
            return Error.InvalidTransition;
        return slot;
    }
};

const reservation_domain: u64 = 0x7265_7365_7276_6531;
const receipt_domain: u64 = 0x7265_6365_6970_7431;
const publication_permit_domain: u64 = 0x7075_626c_6973_6831;
const child_lease_domain: u64 = 0x6368_696c_646c_7331;
const lease_tree_domain: u64 = 0x6c65_6173_6574_7231;
const lease_tree_state_domain: u64 = 0x6c65_6173_6573_7431;
const lease_node_domain: u64 = 0x6c65_6173_656e_6431;
const lease_pending_domain: u64 = 0x6c65_6173_6570_6431;
const lease_batch_domain: u64 = 0x6c65_6173_6562_6131;
const lease_retire_domain: u64 = 0x6c65_6173_6572_7431;
const lease_free_domain: u64 = 0x6c65_6173_6566_7231;

fn clearLeasePending(root: *LeaseTreeRootSlot) void {
    root.pending_kind = .none;
    root.pending_generation = 0;
    root.pending_completion_generation = 0;
    root.pending_free_permit_generation = 0;
    root.pending_free_completion_generation = 0;
    root.pending_scope_index = no_lease_node;
    root.pending_count = 0;
    root.pending_claim = .{};
    root.pending_digest = 0;
}

fn receiptFromSlot(epoch: u64, slot_index: u32, slot: Slot) Receipt {
    return .{
        .bank_epoch = epoch,
        .slot_index = slot_index,
        .generation = slot.generation,
        .owner_key = slot.owner_key,
        .claim = slot.claim,
        .integrity = slot.integrity,
    };
}

fn makeLeaseTree(receipt: Receipt, root: LeaseTreeRootSlot) LeaseTreeV1 {
    return .{
        .parent = receipt,
        .tree_key = root.tree_key,
        .authority_key = root.authority_key,
        .identity_generation = root.identity_generation,
        .generation = root.generation,
        .structural_revision = root.structural_revision,
        .ceiling = root.ceiling,
        .current = root.current,
        .active_nodes = root.active_nodes,
        .state_digest = root.state_digest,
        .integrity = root.integrity,
    };
}

fn makeLeaseNode(
    receipt: Receipt,
    tree_key: u64,
    node_index: u32,
    node: LeaseNodeSlot,
) LeaseNodeV1 {
    return .{
        .parent = receipt,
        .tree_key = tree_key,
        .tree_identity_generation = node.tree_identity_generation,
        .node_index = node_index,
        .generation = node.generation,
        .parent_index = node.parent_index,
        .parent_generation = node.parent_generation,
        .node_key = node.node_key,
        .tenant_key = node.tenant_key,
        .binding_key = node.binding_key,
        .kind = node.kind,
        .ceiling = node.ceiling,
        .claim = node.claim,
        .integrity = node.integrity,
    };
}

fn leaseTreeIntegrity(receipt: Receipt, root: LeaseTreeRootSlot) u64 {
    var result = mix64(lease_tree_domain ^ receipt.integrity);
    result = mix64(result ^ root.tree_key);
    result = mix64(result ^ root.authority_key);
    result = mix64(result ^ root.identity_generation);
    result = mix64(result ^ root.generation);
    result = mix64(result ^ root.structural_revision);
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(root.ceiling, field.name));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(root.current, field.name));
    result = mix64(result ^ @as(u64, root.active_nodes));
    result = mix64(result ^ root.state_digest);
    return result;
}

fn leaseNodeIntegrity(
    receipt: Receipt,
    tree_key: u64,
    node_index: u32,
    node: LeaseNodeSlot,
) u64 {
    var result = mix64(lease_node_domain ^ receipt.integrity);
    result = mix64(result ^ tree_key);
    result = mix64(result ^ node.tree_identity_generation);
    result = mix64(result ^ @as(u64, node_index));
    result = mix64(result ^ node.generation);
    result = mix64(result ^ @as(u64, node.parent_index));
    result = mix64(result ^ node.parent_generation);
    result = mix64(result ^ node.node_key);
    result = mix64(result ^ node.tenant_key);
    result = mix64(result ^ node.binding_key);
    result = mix64(result ^ @intFromEnum(node.kind));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(node.ceiling, field.name));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(node.claim, field.name));
    return result;
}

fn leaseTreeStateDigest(
    nodes: []const LeaseNodeSlot,
    receipt_slot_index: u32,
    root: LeaseTreeRootSlot,
) u64 {
    var result = mix64(lease_tree_state_domain ^ root.tree_key);
    result = mix64(result ^ root.identity_generation);
    result = mix64(result ^ root.structural_revision);
    result = mix64(result ^ @as(u64, root.active_nodes));
    result = mix64(result ^ @intFromEnum(root.pending_kind));
    result = mix64(result ^ root.pending_generation);
    result = mix64(result ^ root.pending_completion_generation);
    result = mix64(result ^ root.pending_free_permit_generation);
    result = mix64(result ^ root.pending_free_completion_generation);
    result = mix64(result ^ @as(u64, root.pending_scope_index));
    result = mix64(result ^ @as(u64, root.pending_count));
    inline for (std.meta.fields(Claim)) |field| {
        result = mix64(result ^ @field(root.current, field.name));
        result = mix64(result ^ @field(root.pending_claim, field.name));
    }
    result = mix64(result ^ root.pending_digest);
    for (nodes, 0..) |node, index| {
        if (!node.active or node.receipt_slot_index != receipt_slot_index or
            node.tree_identity_generation != root.identity_generation)
            continue;
        result = mix64(result ^ @as(u64, @intCast(index)));
        result = mix64(result ^ node.integrity);
        result = mix64(result ^ @intFromEnum(node.state));
        result = mix64(result ^ node.pending_generation);
        result = mix64(result ^ @as(u64, node.pin_count));
        result = mix64(result ^ @as(u64, node.published_references));
        inline for (std.meta.fields(Claim)) |field|
            result = mix64(result ^ @field(node.subtree_claim, field.name));
    }
    return result;
}

fn leasePendingNodeDigest(
    nodes: []const LeaseNodeSlot,
    receipt_slot_index: u32,
    tree_identity_generation: u64,
    pending_generation: u64,
    state: LeaseNodeState,
) u64 {
    var result = mix64(lease_pending_domain ^ tree_identity_generation);
    result = mix64(result ^ pending_generation);
    result = mix64(result ^ @intFromEnum(state));
    for (nodes, 0..) |node, index| {
        if (!node.active or node.receipt_slot_index != receipt_slot_index or
            node.tree_identity_generation != tree_identity_generation or
            node.pending_generation != pending_generation)
            continue;
        result = mix64(result ^ @as(u64, @intCast(index)));
        result = mix64(result ^ node.integrity);
        inline for (std.meta.fields(Claim)) |field|
            result = mix64(result ^ @field(node.claim, field.name));
    }
    return result;
}

fn leaseAllocationBatchIntegrity(batch: LeaseAllocationBatchV1) u64 {
    var result = mix64(lease_batch_domain ^ batch.parent.integrity);
    result = mix64(result ^ batch.tree_key);
    result = mix64(result ^ batch.tree_identity_generation);
    result = mix64(result ^ batch.tree_generation);
    result = mix64(result ^ batch.structural_revision);
    result = mix64(result ^ batch.request_epoch);
    result = mix64(result ^ @as(u64, @intCast(batch.session_id)));
    result = mix64(result ^ batch.sequence);
    result = mix64(result ^ batch.generation);
    result = mix64(result ^ batch.completion_tree_generation);
    result = mix64(result ^ @as(u64, batch.node_count));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(batch.claim, field.name));
    result = mix64(result ^ batch.node_set_digest);
    return result;
}

fn leaseRetireTicketIntegrity(ticket: LeaseRetireTicketV1) u64 {
    var result = mix64(lease_retire_domain ^ ticket.parent.integrity);
    result = mix64(result ^ ticket.tree_key);
    result = mix64(result ^ ticket.tree_identity_generation);
    result = mix64(result ^ ticket.tree_generation);
    result = mix64(result ^ ticket.structural_revision);
    result = mix64(result ^ ticket.request_epoch);
    result = mix64(result ^ @as(u64, @intCast(ticket.session_id)));
    result = mix64(result ^ ticket.sequence);
    result = mix64(result ^ ticket.generation);
    result = mix64(result ^ ticket.decision_tree_generation);
    result = mix64(result ^ ticket.free_permit_generation);
    result = mix64(result ^ ticket.free_completion_tree_generation);
    result = mix64(result ^ @as(u64, ticket.scope_index));
    result = mix64(result ^ ticket.scope_generation);
    result = mix64(result ^ @as(u64, ticket.node_count));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(ticket.claim, field.name));
    result = mix64(result ^ ticket.node_set_digest);
    return result;
}

fn leaseFreePermitIntegrity(permit: LeaseFreePermitV1) u64 {
    var result = mix64(lease_free_domain ^ permit.parent.integrity);
    result = mix64(result ^ permit.tree_key);
    result = mix64(result ^ permit.tree_identity_generation);
    result = mix64(result ^ permit.tree_generation);
    result = mix64(result ^ permit.structural_revision);
    result = mix64(result ^ permit.request_epoch);
    result = mix64(result ^ @as(u64, @intCast(permit.session_id)));
    result = mix64(result ^ permit.sequence);
    result = mix64(result ^ permit.generation);
    result = mix64(result ^ permit.completion_tree_generation);
    result = mix64(result ^ @as(u64, permit.scope_index));
    result = mix64(result ^ permit.scope_generation);
    result = mix64(result ^ @as(u64, permit.node_count));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(permit.claim, field.name));
    result = mix64(result ^ permit.node_set_digest);
    return result;
}

fn validateLeaseTreeAccounting(
    nodes: []const LeaseNodeSlot,
    receipt: Receipt,
    root: LeaseTreeRootSlot,
) Error!void {
    var node_count: u32 = 0;
    var tree_claim: Claim = .{};
    for (nodes, 0..) |node, node_index| {
        if (!node.active or node.receipt_slot_index != receipt.slot_index)
            continue;
        if (node.tree_identity_generation != root.identity_generation or
            node.integrity != leaseNodeIntegrity(
                receipt,
                root.tree_key,
                @intCast(node_index),
                node,
            ))
            return Error.InvalidTransition;
        if (node_count == std.math.maxInt(u32))
            return Error.InvalidTransition;
        node_count += 1;
        switch (node.kind) {
            .scope => {
                if (node.state != .live or !node.claim.isZero() or
                    node.binding_key != 0 or
                    node.parent_index != no_lease_node or
                    node.parent_generation != root.identity_generation)
                    return Error.InvalidTransition;
                var scope_claim: Claim = .{};
                for (nodes) |child| {
                    if (child.active and
                        child.receipt_slot_index == receipt.slot_index and
                        child.tree_identity_generation == root.identity_generation and
                        child.kind == .allocation and
                        child.parent_index == node_index)
                        scope_claim = try addClaims(scope_claim, child.claim);
                }
                if (!std.meta.eql(scope_claim, node.subtree_claim) or
                    !claimWithin(node.subtree_claim, node.ceiling))
                    return Error.InvalidTransition;
            },
            .allocation => {
                if (node.state == .free or node.claim.isZero() or
                    !std.meta.eql(node.claim, node.ceiling) or
                    !std.meta.eql(node.claim, node.subtree_claim) or
                    node.parent_index >= nodes.len)
                    return Error.InvalidTransition;
                const scope = nodes[node.parent_index];
                if (!scope.active or scope.kind != .scope or
                    scope.receipt_slot_index != receipt.slot_index or
                    scope.tree_identity_generation != root.identity_generation or
                    scope.generation != node.parent_generation or
                    scope.tenant_key != node.tenant_key)
                    return Error.InvalidTransition;
                tree_claim = try addClaims(tree_claim, node.claim);
            },
        }
    }
    if (node_count != root.active_nodes or
        !std.meta.eql(tree_claim, root.current) or
        !claimWithin(root.current, root.ceiling))
        return Error.InvalidTransition;
    try validateLeasePendingState(nodes, receipt.slot_index, root);
}

fn validateLeasePendingState(
    nodes: []const LeaseNodeSlot,
    receipt_slot_index: u32,
    root: LeaseTreeRootSlot,
) Error!void {
    if (root.pending_kind == .none) {
        if (root.pending_generation != 0 or
            root.pending_completion_generation != 0 or
            root.pending_free_permit_generation != 0 or
            root.pending_free_completion_generation != 0 or
            root.pending_scope_index != no_lease_node or
            root.pending_count != 0 or !root.pending_claim.isZero() or
            root.pending_digest != 0)
            return Error.InvalidTransition;
    } else if (root.pending_generation == 0 or
        root.pending_completion_generation == 0 or root.pending_count == 0 or
        root.pending_claim.isZero())
        return Error.InvalidTransition;

    const expected_state: ?LeaseNodeState = switch (root.pending_kind) {
        .none => null,
        .allocation => .reserved_unmaterialized,
        .retire => .quiescing,
        .free => .free_authorized,
    };
    var count: u32 = 0;
    var claim: Claim = .{};
    for (nodes) |node| {
        if (!node.active or node.receipt_slot_index != receipt_slot_index or
            node.tree_identity_generation != root.identity_generation or
            node.kind != .allocation)
            continue;
        const pending_state = node.state == .reserved_unmaterialized or
            node.state == .quiescing or
            node.state == .free_authorized;
        if (node.pending_generation == root.pending_generation and
            root.pending_kind != .none)
        {
            if (node.state != expected_state.?)
                return Error.InvalidTransition;
            count += 1;
            claim = try addClaims(claim, node.claim);
        } else if (node.pending_generation != 0 or pending_state) {
            return Error.InvalidTransition;
        }
    }
    if (root.pending_kind == .none) {
        if (count != 0) return Error.InvalidTransition;
        return;
    }
    if (count != root.pending_count or
        !std.meta.eql(claim, root.pending_claim) or
        root.pending_digest != leasePendingNodeDigest(
            nodes,
            receipt_slot_index,
            root.identity_generation,
            root.pending_generation,
            expected_state.?,
        )) return Error.InvalidTransition;
    switch (root.pending_kind) {
        .none => unreachable,
        .allocation => if (root.pending_scope_index != no_lease_node or
            root.pending_free_permit_generation != 0 or
            root.pending_free_completion_generation != 0)
            return Error.InvalidTransition,
        .retire => if (root.pending_scope_index == no_lease_node or
            root.pending_free_permit_generation == 0 or
            root.pending_free_completion_generation == 0)
            return Error.InvalidTransition,
        .free => if (root.pending_scope_index == no_lease_node)
            return Error.InvalidTransition
        else if (root.pending_free_permit_generation != 0 or
            root.pending_free_completion_generation != 0)
            return Error.InvalidTransition,
    }
}

fn addClaims(left: Claim, right: Claim) Error!Claim {
    var result: Claim = .{};
    inline for (std.meta.fields(Claim)) |field| {
        @field(result, field.name) = std.math.add(
            u64,
            @field(left, field.name),
            @field(right, field.name),
        ) catch return Error.ClaimOverflow;
    }
    return result;
}

fn subtractClaims(total: Claim, amount: Claim) Error!Claim {
    var result: Claim = .{};
    inline for (std.meta.fields(Claim)) |field| {
        @field(result, field.name) = std.math.sub(
            u64,
            @field(total, field.name),
            @field(amount, field.name),
        ) catch return Error.StaleReservation;
    }
    return result;
}

fn maxClaims(left: Claim, right: Claim) Claim {
    var result: Claim = .{};
    inline for (std.meta.fields(Claim)) |field| {
        @field(result, field.name) = @max(
            @field(left, field.name),
            @field(right, field.name),
        );
    }
    return result;
}

fn claimWithin(value: Claim, ceiling: Claim) bool {
    inline for (std.meta.fields(Claim)) |field| {
        if (@field(value, field.name) > @field(ceiling, field.name))
            return false;
    }
    return true;
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

/// Accidental-misuse integrity, not a cryptographic authorization primitive.
fn tokenIntegrity(
    epoch: u64,
    slot_index: u32,
    generation: u64,
    owner_key: u64,
    claim: Claim,
    domain: u64,
) u64 {
    var result = mix64(domain ^ epoch);
    result = mix64(result ^ @as(u64, slot_index));
    result = mix64(result ^ generation);
    result = mix64(result ^ owner_key);
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(claim, field.name));
    return result;
}

fn publicationPermitIntegrity(
    receipt: Receipt,
    request_epoch: u64,
    session_id: usize,
    sequence: u64,
    generation: u64,
) u64 {
    var result = mix64(publication_permit_domain ^ receipt.integrity);
    result = mix64(result ^ request_epoch);
    result = mix64(result ^ @as(u64, @intCast(session_id)));
    result = mix64(result ^ sequence);
    result = mix64(result ^ generation);
    result = mix64(result ^ receipt.bank_epoch);
    result = mix64(result ^ @as(u64, receipt.slot_index));
    result = mix64(result ^ receipt.generation);
    result = mix64(result ^ receipt.owner_key);
    return result;
}

fn childLeaseIntegrity(
    parent: Receipt,
    child_key: u64,
    generation: u64,
    ceiling: Claim,
    claim: Claim,
) u64 {
    var result = mix64(child_lease_domain ^ parent.integrity);
    result = mix64(result ^ parent.bank_epoch);
    result = mix64(result ^ @as(u64, parent.slot_index));
    result = mix64(result ^ parent.generation);
    result = mix64(result ^ parent.owner_key);
    result = mix64(result ^ child_key);
    result = mix64(result ^ generation);
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(ceiling, field.name));
    inline for (std.meta.fields(Claim)) |field|
        result = mix64(result ^ @field(claim, field.name));
    return result;
}

test "reserve commit release preserves exact usage and peak" {
    var slots = [_]Slot{.{}} ** 2;
    var bank = try Bank.init(&slots, .{
        .host_bytes = 1_000,
        .kv_bytes = 600,
        .queue_slots = 2,
    }, 17);
    const claim: Claim = .{
        .kv_bytes = 400,
        .activation_bytes = 100,
        .output_journal_bytes = 16,
        .queue_slots = 1,
    };
    const reservation = try bank.reserve(0xabc, claim);
    var snapshot = try bank.snapshot();
    try std.testing.expectEqual(@as(usize, 1), snapshot.active_reservations);
    try std.testing.expectEqual(@as(u64, 516), try snapshot.used.hostBytes());
    const receipt = try bank.commit(reservation);
    snapshot = try bank.snapshot();
    try std.testing.expectEqual(@as(usize, 0), snapshot.active_reservations);
    try std.testing.expectEqual(@as(usize, 1), snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, 1), snapshot.successful_commits);
    try bank.release(receipt);
    snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 516), try snapshot.peak.hostBytes());
    try std.testing.expectEqual(@as(u64, 516), snapshot.peak_host_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
    try std.testing.expectError(Error.StaleReservation, bank.release(receipt));
}

test "validateCommitted is read only and fences forged or released receipts" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{ .host_bytes = 128 }, 19);
    const reservation = try bank.reserve(7, .{ .kv_bytes = 64 });

    const reservation_as_receipt: Receipt = .{
        .bank_epoch = reservation.bank_epoch,
        .slot_index = reservation.slot_index,
        .generation = reservation.generation,
        .owner_key = reservation.owner_key,
        .claim = reservation.claim,
        .integrity = reservation.integrity,
    };
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateCommitted(reservation_as_receipt),
    );

    const receipt = try bank.commit(reservation);
    const before = try bank.snapshot();
    try bank.validateCommitted(receipt);
    try std.testing.expectEqualDeep(before, try bank.snapshot());

    var forged = receipt;
    forged.claim.kv_bytes += 1;
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateCommitted(forged),
    );
    forged = receipt;
    forged.integrity ^= 1;
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateCommitted(forged),
    );

    try bank.release(receipt);
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateCommitted(receipt),
    );
}

test "publication session fence pins receipt and serializes exact sequences" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{ .queue_slots = 4 }, 21);
    const reservation = try bank.reserve(7, .{ .queue_slots = 4 });
    const receipt = try bank.commit(reservation);
    const request_epoch: u64 = 99;
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);

    try bank.bindPublicationSession(receipt, request_epoch, session_id);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.bindPublicationSession(receipt, request_epoch, session_id),
    );
    try std.testing.expectError(Error.InvalidTransition, bank.release(receipt));

    const first = try bank.beginPublication(
        receipt,
        request_epoch,
        session_id,
        0,
    );
    try bank.validatePublication(first);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.beginPublication(receipt, request_epoch, session_id, 0),
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.closePublicationSession(receipt, request_epoch, session_id, 0),
    );
    try bank.abortPublication(first);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.abortPublication(first),
    );

    const retry = try bank.beginPublication(
        receipt,
        request_epoch,
        session_id,
        0,
    );
    try std.testing.expect(retry.generation != first.generation);
    bank.commitPublicationAssumeValid(retry);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.beginPublication(receipt, request_epoch, session_id, 0),
    );
    const second = try bank.beginPublication(
        receipt,
        request_epoch,
        session_id,
        1,
    );
    try bank.abortPublication(second);
    try bank.closePublicationSession(receipt, request_epoch, session_id, 1);
    try bank.release(receipt);
}

test "publication close and release is one failure-atomic transition" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(
        &slots,
        .{ .host_bytes = 64, .queue_slots = 1 },
        23,
    );
    const claim: Claim = .{
        .activation_bytes = 64,
        .queue_slots = 1,
    };
    const receipt = try bank.commit(try bank.reserve(8, claim));
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSession(receipt, 100, session_id);
    const permit = try bank.beginPublication(
        receipt,
        100,
        session_id,
        0,
    );
    bank.commitPublicationAssumeValid(permit);

    const before = try bank.snapshot();
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.closePublicationSessionAndRelease(
            receipt,
            100,
            session_id,
            0,
        ),
    );
    try std.testing.expectEqualDeep(before, try bank.snapshot());
    try bank.validateCommitted(receipt);

    try bank.closePublicationSessionAndRelease(
        receipt,
        100,
        session_id,
        1,
    );
    const after = try bank.snapshot();
    try std.testing.expect(after.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), after.committed_receipts);
    try std.testing.expectEqual(@as(u64, 1), after.releases);
    try std.testing.expectError(
        Error.StaleReservation,
        bank.closePublicationSessionAndRelease(
            receipt,
            100,
            session_id,
            1,
        ),
    );
}

test "publication permit rejects wrong coordinator and forged identity" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{}, 22);
    const receipt = try bank.commit(try bank.reserve(8, .{ .queue_slots = 4 }));
    var first_coordinator: u8 = 0;
    var second_coordinator: u8 = 0;
    const first_id = @intFromPtr(&first_coordinator);
    const second_id = @intFromPtr(&second_coordinator);
    try bank.bindPublicationSession(receipt, 100, first_id);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.beginPublication(receipt, 100, second_id, 0),
    );
    const permit = try bank.beginPublication(receipt, 100, first_id, 0);
    var forged = permit;
    forged.session_id = second_id;
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.validatePublication(forged),
    );
    forged = permit;
    forged.integrity ^= 1;
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.validatePublication(forged),
    );
    try bank.abortPublication(permit);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.closePublicationSession(receipt, 100, second_id, 0),
    );
    try bank.closePublicationSession(receipt, 100, first_id, 0);
    try bank.release(receipt);
}

test "publication close is terminal for one receipt and prevents replay ABA" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{}, 24);
    const receipt = try bank.commit(try bank.reserve(9, .{ .queue_slots = 4 }));
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);

    try bank.bindPublicationSession(receipt, 101, session_id);
    const stale = try bank.beginPublication(receipt, 101, session_id, 0);
    try bank.abortPublication(stale);
    try bank.closePublicationSession(receipt, 101, session_id, 0);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.bindPublicationSession(receipt, 101, session_id),
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.validatePublication(stale),
    );
    try bank.release(receipt);

    const next_receipt = try bank.commit(try bank.reserve(
        10,
        .{ .queue_slots = 4 },
    ));
    try bank.bindPublicationSession(next_receipt, 101, session_id);
    const current = try bank.beginPublication(
        next_receipt,
        101,
        session_id,
        0,
    );
    try std.testing.expect(current.receipt.generation != stale.receipt.generation);
    try std.testing.expectError(
        Error.StaleReservation,
        bank.abortPublication(stale),
    );
    try bank.validatePublication(current);
    try bank.abortPublication(current);
    try bank.closePublicationSession(next_receipt, 101, session_id, 0);
    try bank.release(next_receipt);
}

test "capacity rejection and cancellation never leak a charge" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{
        .host_bytes = 128,
        .kv_bytes = 96,
        .queue_slots = 1,
    }, 23);
    try std.testing.expectError(
        Error.CapacityExceeded,
        bank.reserve(1, .{ .kv_bytes = 97, .queue_slots = 1 }),
    );
    var snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_capacity);

    const reservation = try bank.reserve(2, .{
        .kv_bytes = 80,
        .activation_bytes = 32,
        .queue_slots = 1,
    });
    try bank.cancel(reservation);
    snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), snapshot.cancellations);
    try std.testing.expectError(
        Error.StaleReservation,
        bank.cancel(reservation),
    );
}

test "flat bank preserves Receipt-v1 slot footprint and has no implicit child" {
    if (@sizeOf(usize) == 8)
        try std.testing.expectEqual(@as(usize, 152), @sizeOf(Slot));
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{ .kv_bytes = 64 }, 38);
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    try std.testing.expectError(
        Error.InvalidConfiguration,
        bank.openChild(
            receipt,
            2,
            .{ .kv_bytes = 64 },
            .{},
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        (try bank.snapshotV2()).active_child_leases,
    );
    try bank.release(receipt);
}

test "child growth is exact generation fenced and failed growth is atomic" {
    var slots = [_]Slot{.{}} ** 1;
    var child_slots = [_]ChildSlot{.{}} ** slots.len;
    var bank = try Bank.initWithChildSlots(&slots, &child_slots, .{
        .host_bytes = 160,
        .kv_bytes = 128,
        .activation_bytes = 32,
        .queue_slots = 1,
    }, 25);
    const receipt = try bank.commit(try bank.reserve(7, .{
        .activation_bytes = 32,
        .queue_slots = 1,
    }));
    const empty = try bank.openChild(
        receipt,
        0x6b76,
        .{ .kv_bytes = 256 },
        .{},
    );
    var snapshot = try bank.snapshotV2();
    try std.testing.expectEqual(@as(usize, 1), snapshot.active_child_leases);
    try std.testing.expectEqual(@as(u64, 32), try snapshot.used.hostBytes());

    const exact = try bank.growChild(empty, .{ .kv_bytes = 128 });
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateChild(empty),
    );
    try bank.validateChild(exact);
    snapshot = try bank.snapshotV2();
    try std.testing.expectEqual(@as(u64, 160), try snapshot.used.hostBytes());
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_grows);

    const before_reject_used = snapshot.used;
    try std.testing.expectError(
        Error.CapacityExceeded,
        bank.growChild(exact, .{ .kv_bytes = 129 }),
    );
    try bank.validateChild(exact);
    snapshot = try bank.snapshotV2();
    try std.testing.expectEqualDeep(before_reject_used, snapshot.used);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_child_capacity);

    const shrunk = try bank.shrinkChildAfterFree(
        exact,
        .{ .kv_bytes = 64 },
    );
    try std.testing.expectError(
        Error.StaleReservation,
        bank.closeChild(exact),
    );
    try bank.closeChild(shrunk);
    try bank.release(receipt);
    snapshot = try bank.snapshotV2();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_opens);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_shrinks);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_closes);
}

test "child ceiling and publication session authority fail closed" {
    var slots = [_]Slot{.{}} ** 1;
    var child_slots = [_]ChildSlot{.{}} ** slots.len;
    var bank = try Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{ .kv_bytes = 256 },
        26,
    );
    const receipt = try bank.commit(try bank.reserve(
        9,
        .{ .activation_bytes = 1 },
    ));
    try std.testing.expectError(
        Error.InvalidClaim,
        bank.openChild(
            receipt,
            1,
            .{ .kv_bytes = 64 },
            .{ .kv_bytes = 65 },
        ),
    );
    var lease = try bank.openChild(
        receipt,
        2,
        .{ .kv_bytes = 128 },
        .{ .kv_bytes = 32 },
    );
    try std.testing.expectError(
        Error.InvalidClaim,
        bank.growChild(lease, .{ .kv_bytes = 129 }),
    );
    try bank.validateChild(lease);
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSession(receipt, 77, session_id);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.growChild(lease, .{ .kv_bytes = 64 }),
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.growChildForSession(
            lease,
            78,
            session_id,
            0,
            .{ .kv_bytes = 64 },
        ),
    );
    lease = try bank.growChildForSession(
        lease,
        77,
        session_id,
        0,
        .{ .kv_bytes = 64 },
    );
    const permit = try bank.beginPublicationWithChild(
        lease,
        77,
        session_id,
        0,
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.growChildForSession(
            lease,
            77,
            session_id,
            0,
            .{ .kv_bytes = 96 },
        ),
    );
    try std.testing.expectError(Error.InvalidTransition, bank.closeChild(lease));
    try std.testing.expectError(Error.InvalidTransition, bank.release(receipt));
    try bank.abortPublication(permit);
    try bank.closePublicationSession(receipt, 77, session_id, 0);
    try bank.closeChild(lease);
    try bank.release(receipt);
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "concurrent child growth grants exactly one generation at a hard cap" {
    const Contender = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        lease: ChildLease,
        grown: ?ChildLease = null,
        admission_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.grown = self.bank.growChild(
                self.lease,
                .{ .kv_bytes = 64 },
            ) catch |err| {
                self.admission_error = err;
                return;
            };
        }
    };

    var slots = [_]Slot{.{}} ** 2;
    var child_slots = [_]ChildSlot{.{}} ** slots.len;
    var bank = try Bank.initWithChildSlots(&slots, &child_slots, .{
        .host_bytes = 64,
        .kv_bytes = 64,
        .queue_slots = 2,
    }, 28);
    const left_receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    const right_receipt = try bank.commit(try bank.reserve(
        2,
        .{ .queue_slots = 1 },
    ));
    const left_lease = try bank.openChild(
        left_receipt,
        1,
        .{ .kv_bytes = 64 },
        .{},
    );
    const right_lease = try bank.openChild(
        right_receipt,
        2,
        .{ .kv_bytes = 64 },
        .{},
    );
    var start = std.atomic.Value(bool).init(false);
    var left: Contender = .{
        .bank = &bank,
        .start = &start,
        .lease = left_lease,
    };
    var right: Contender = .{
        .bank = &bank,
        .start = &start,
        .lease = right_lease,
    };
    const left_thread = try std.Thread.spawn(.{}, Contender.run, .{&left});
    const right_thread = std.Thread.spawn(.{}, Contender.run, .{&right}) catch |err| {
        start.store(true, .release);
        left_thread.join();
        return err;
    };
    start.store(true, .release);
    left_thread.join();
    right_thread.join();

    try std.testing.expect((left.grown == null) != (right.grown == null));
    try std.testing.expectEqual(
        Error.CapacityExceeded,
        if (left.admission_error) |err| err else right.admission_error.?,
    );
    const snapshot = try bank.snapshotV2();
    try std.testing.expectEqual(@as(u64, 64), snapshot.used.kv_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.child_grows);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_child_capacity);

    if (left.grown) |lease| {
        try bank.closeChild(lease);
        try bank.closeChild(right_lease);
    } else {
        try bank.closeChild(left_lease);
        try bank.closeChild(right.grown.?);
    }
    try bank.release(left_receipt);
    try bank.release(right_receipt);
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "copied child handle linearizes one concurrent mutation" {
    const Contender = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        lease: ChildLease,
        target: u64,
        grown: ?ChildLease = null,
        mutation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.grown = self.bank.growChild(
                self.lease,
                .{ .kv_bytes = self.target },
            ) catch |err| {
                self.mutation_error = err;
                return;
            };
        }
    };

    var slots = [_]Slot{.{}} ** 1;
    var child_slots = [_]ChildSlot{.{}} ** slots.len;
    var bank = try Bank.initWithChildSlots(
        &slots,
        &child_slots,
        .{ .kv_bytes = 128 },
        32,
    );
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    const lease = try bank.openChild(
        receipt,
        9,
        .{ .kv_bytes = 128 },
        .{},
    );
    var start = std.atomic.Value(bool).init(false);
    var left: Contender = .{
        .bank = &bank,
        .start = &start,
        .lease = lease,
        .target = 64,
    };
    var right: Contender = .{
        .bank = &bank,
        .start = &start,
        .lease = lease,
        .target = 96,
    };
    const left_thread = try std.Thread.spawn(.{}, Contender.run, .{&left});
    const right_thread = std.Thread.spawn(.{}, Contender.run, .{&right}) catch |err| {
        start.store(true, .release);
        left_thread.join();
        return err;
    };
    start.store(true, .release);
    left_thread.join();
    right_thread.join();

    try std.testing.expect((left.grown == null) != (right.grown == null));
    try std.testing.expectEqual(
        Error.StaleReservation,
        if (left.mutation_error) |err| err else right.mutation_error.?,
    );
    const current = left.grown orelse right.grown.?;
    try std.testing.expectEqual(current.claim.kv_bytes, (try bank.snapshot()).used.kv_bytes);
    try bank.closeChild(current);
    try bank.release(receipt);
    try std.testing.expect((try bank.snapshot()).used.isZero());
}

test "child session bind linearizes against copied grow and close" {
    const Mutation = enum { grow, close };
    const Binder = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        lease: ChildLease,
        request_epoch: u64,
        session_id: usize,
        bound: bool = false,
        bind_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.bank.bindPublicationSessionWithChild(
                self.lease,
                self.request_epoch,
                self.session_id,
            ) catch |err| {
                self.bind_error = err;
                return;
            };
            self.bound = true;
        }
    };
    const Mutator = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        lease: ChildLease,
        mutation: Mutation,
        succeeded: bool = false,
        grown: ?ChildLease = null,
        mutation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            switch (self.mutation) {
                .grow => self.grown = self.bank.growChild(
                    self.lease,
                    .{ .kv_bytes = 64 },
                ) catch |err| {
                    self.mutation_error = err;
                    return;
                },
                .close => self.bank.closeChild(self.lease) catch |err| {
                    self.mutation_error = err;
                    return;
                },
            }
            self.succeeded = true;
        }
    };

    inline for (.{ Mutation.grow, Mutation.close }, 0..) |mutation, index| {
        var slots = [_]Slot{.{}} ** 1;
        var child_slots = [_]ChildSlot{.{}} ** slots.len;
        var bank = try Bank.initWithChildSlots(
            &slots,
            &child_slots,
            .{ .kv_bytes = 128, .queue_slots = 1 },
            0x5032_4300 + index,
        );
        const receipt = try bank.commit(try bank.reserve(
            1,
            .{ .queue_slots = 1 },
        ));
        const lease = try bank.openChild(
            receipt,
            9,
            .{ .kv_bytes = 128 },
            .{},
        );
        var coordinator: u8 = 0;
        const session_id = @intFromPtr(&coordinator);
        const request_epoch: u64 = 0x5032_4301 + index;
        var start = std.atomic.Value(bool).init(false);
        var binder: Binder = .{
            .bank = &bank,
            .start = &start,
            .lease = lease,
            .request_epoch = request_epoch,
            .session_id = session_id,
        };
        var mutator: Mutator = .{
            .bank = &bank,
            .start = &start,
            .lease = lease,
            .mutation = mutation,
        };
        const bind_thread = try std.Thread.spawn(.{}, Binder.run, .{&binder});
        const mutation_thread = std.Thread.spawn(
            .{},
            Mutator.run,
            .{&mutator},
        ) catch |err| {
            start.store(true, .release);
            bind_thread.join();
            return err;
        };
        start.store(true, .release);
        bind_thread.join();
        mutation_thread.join();

        try std.testing.expect(binder.bound != mutator.succeeded);
        if (binder.bound) {
            try std.testing.expectEqual(Error.InvalidTransition, mutator.mutation_error.?);
            try bank.closePublicationSession(
                receipt,
                request_epoch,
                session_id,
                0,
            );
            try bank.closeChild(lease);
        } else {
            try std.testing.expectEqual(Error.StaleReservation, binder.bind_error.?);
            if (mutation == .grow) try bank.closeChild(mutator.grown.?);
        }
        try bank.release(receipt);
        try std.testing.expect((try bank.snapshot()).used.isZero());
    }
}

test "aggregate host peak is temporal not the sum of class peaks" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{}, 27);

    const kv_reservation = try bank.reserve(1, .{ .kv_bytes = 100 });
    const kv_receipt = try bank.commit(kv_reservation);
    try bank.release(kv_receipt);
    const activation_reservation = try bank.reserve(
        2,
        .{ .activation_bytes = 200 },
    );
    const activation_receipt = try bank.commit(activation_reservation);
    try bank.release(activation_receipt);

    const snapshot = try bank.snapshot();
    try std.testing.expectEqual(@as(u64, 200), snapshot.peak_host_bytes);
    try std.testing.expectEqual(@as(u64, 300), try snapshot.peak.hostBytes());
    try std.testing.expect(snapshot.used.isZero());
}

test "fixed slots bound concurrent leases independently of byte budget" {
    var slots = [_]Slot{.{}} ** 1;
    var bank = try Bank.init(&slots, .{}, 29);
    const first = try bank.reserve(1, .{ .queue_slots = 1 });
    try std.testing.expectError(
        Error.ReservationSlotsExhausted,
        bank.reserve(2, .{ .queue_slots = 1 }),
    );
    const snapshot = try bank.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_slots);
    try bank.cancel(first);
}

test "concurrent admission grants exactly one receipt at a hard cap" {
    const Contender = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        owner_key: u64,
        receipt: ?Receipt = null,
        admission_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            const reservation = self.bank.reserve(
                self.owner_key,
                .{ .activation_bytes = 64, .queue_slots = 1 },
            ) catch |err| {
                self.admission_error = err;
                return;
            };
            self.receipt = self.bank.commit(reservation) catch |err| {
                self.admission_error = err;
                self.bank.cancel(reservation) catch {};
                return;
            };
        }
    };

    var slots = [_]Slot{.{}} ** 2;
    var bank = try Bank.init(&slots, .{
        .host_bytes = 64,
        .activation_bytes = 64,
        .queue_slots = 1,
    }, 30);
    var start = std.atomic.Value(bool).init(false);
    var left: Contender = .{
        .bank = &bank,
        .start = &start,
        .owner_key = 1,
    };
    var right: Contender = .{
        .bank = &bank,
        .start = &start,
        .owner_key = 2,
    };
    const left_thread = try std.Thread.spawn(.{}, Contender.run, .{&left});
    const right_thread = std.Thread.spawn(.{}, Contender.run, .{&right}) catch |err| {
        start.store(true, .release);
        left_thread.join();
        return err;
    };
    start.store(true, .release);
    left_thread.join();
    right_thread.join();

    try std.testing.expect((left.receipt == null) != (right.receipt == null));
    const winning_receipt = left.receipt orelse right.receipt.?;
    try std.testing.expectEqual(
        Error.CapacityExceeded,
        if (left.admission_error) |err| err else right.admission_error.?,
    );
    var snapshot = try bank.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.successful_reservations);
    try std.testing.expectEqual(@as(u64, 1), snapshot.successful_commits);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_capacity);
    try std.testing.expectEqual(@as(usize, 1), snapshot.committed_receipts);
    try std.testing.expectEqual(@as(u64, 64), try snapshot.used.hostBytes());

    try bank.release(winning_receipt);
    snapshot = try bank.snapshot();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), snapshot.releases);
}

test "forged token and arithmetic overflow fail closed" {
    var no_slots = [_]Slot{};
    try std.testing.expectError(
        Error.InvalidConfiguration,
        Bank.init(&no_slots, .{}, 1),
    );
    var slots = [_]Slot{.{}} ** 1;
    try std.testing.expectError(
        Error.InvalidConfiguration,
        Bank.init(&slots, .{}, 0),
    );
    var bank = try Bank.init(&slots, .{}, 31);
    try std.testing.expectError(
        Error.InvalidClaim,
        bank.reserve(0, .{ .activation_bytes = 1 }),
    );
    try std.testing.expectError(Error.InvalidClaim, bank.reserve(1, .{}));
    const reservation = try bank.reserve(7, .{ .activation_bytes = 64 });
    var forged = reservation;
    forged.claim.activation_bytes = 63;
    try std.testing.expectError(
        Error.StaleReservation,
        bank.commit(forged),
    );
    try bank.cancel(reservation);

    var overflow_bank = try Bank.init(&slots, .{}, 37);
    try std.testing.expectError(
        Error.ClaimOverflow,
        overflow_bank.reserve(1, .{
            .capsule_bytes = std.math.maxInt(u64),
            .kv_bytes = 1,
        }),
    );
}

test "LeaseTree reserve materialize publish and free preserves exact sums" {
    var slots = [_]Slot{.{}} ** 1;
    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]LeaseNodeSlot{.{}} ** 8;
    var bank = try Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{
            .host_bytes = 160,
            .kv_bytes = 128,
            .activation_bytes = 32,
            .queue_slots = 1,
        },
        0x5032_4342,
    );
    const receipt = try bank.commit(try bank.reserve(1, .{
        .activation_bytes = 16,
        .queue_slots = 1,
    }));
    const opened = try bank.openLeaseTree(
        receipt,
        0x7472_6565,
        0x6175_7468,
        .{ .kv_bytes = 128 },
    );
    try std.testing.expectError(Error.InvalidTransition, bank.release(receipt));
    const lane_open = try bank.openLeaseScope(
        opened,
        0x6c61_6e65,
        0x7465_6e61_6e74,
        .{ .kv_bytes = 128 },
    );
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateLeaseTree(opened),
    );
    try std.testing.expectError(
        Error.StaleReservation,
        bank.bindPublicationSessionWithTree(opened, 71, 1),
    );

    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.bindPublicationSession(receipt, 71, session_id),
    );
    try bank.bindPublicationSessionWithTree(lane_open.tree, 71, session_id);

    const specs = [_]LeaseAllocationSpecV1{
        .{
            .scope = lane_open.scope,
            .node_key = 10,
            .binding_key = 100,
            .claim = .{ .kv_bytes = 32 },
        },
        .{
            .scope = lane_open.scope,
            .node_key = 11,
            .binding_key = 101,
            .claim = .{ .kv_bytes = 32 },
        },
    };
    var leaves: [specs.len]LeaseNodeV1 = undefined;
    const reservation = try bank.reserveAllocationsForSession(
        lane_open.tree,
        71,
        session_id,
        0,
        &specs,
        &leaves,
    );
    var snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(usize, 2), snapshot.reserved_unmaterialized_allocations);
    try std.testing.expectEqual(@as(u64, 64), snapshot.used.kv_bytes);
    try std.testing.expectEqual(@as(u64, 80), try snapshot.used.hostBytes());
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.beginPublicationWithTree(
            reservation.tree,
            71,
            session_id,
            0,
        ),
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.closePublicationSession(receipt, 71, session_id, 0),
    );

    var tree = try bank.commitAllocationsAfterAllocate(reservation.batch);
    try std.testing.expect(leaseTreeIntegrityValidV1(tree));
    try std.testing.expect(leaseNodeIntegrityValidV1(lane_open.scope));
    try std.testing.expect(leaseNodeIntegrityValidV1(leaves[0]));
    var forged_leaf = leaves[0];
    forged_leaf.binding_key ^= 1;
    try std.testing.expect(!leaseNodeIntegrityValidV1(forged_leaf));
    try std.testing.expectError(
        Error.StaleReservation,
        bank.beginPublicationWithTree(
            reservation.tree,
            71,
            session_id,
            0,
        ),
    );
    try bank.validateLeaseNode(tree, leaves[0]);
    try bank.validateLeaseNode(tree, leaves[1]);
    snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(usize, 0), snapshot.reserved_unmaterialized_allocations);
    try std.testing.expectEqual(@as(usize, 2), snapshot.live_allocations);
    try std.testing.expectEqual(@as(u64, 64), tree.current.kv_bytes);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.closePublicationSession(receipt, 71, session_id, 0),
    );

    const publication = try bank.beginPublicationWithTree(
        tree,
        71,
        session_id,
        0,
    );
    bank.commitPublicationAssumeValid(publication);
    const retire = try bank.beginRetireSubtreeForSession(
        tree,
        lane_open.scope,
        71,
        session_id,
        1,
    );
    snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(usize, 2), snapshot.quiescing_allocations);
    try std.testing.expectEqual(@as(u64, 64), snapshot.used.kv_bytes);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.beginPublicationWithTree(
            retire.tree,
            71,
            session_id,
            1,
        ),
    );
    try std.testing.expectError(Error.InvalidTransition, bank.closeLeaseTree(retire.tree));
    const authorized = try bank.authorizeFree(retire.ticket);
    tree = authorized.tree;
    snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(usize, 0), snapshot.quiescing_allocations);
    try std.testing.expectEqual(@as(usize, 2), snapshot.free_authorized_allocations);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.cancelRetire(retire.ticket),
    );

    // Models the caller's already-completed allocator frees.
    tree = try bank.commitFreeAfterAllocatorFree(authorized.permit);
    snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(usize, 0), snapshot.free_authorized_allocations);
    try std.testing.expectEqual(@as(u64, 0), snapshot.used.kv_bytes);
    try std.testing.expectEqual(@as(u64, 16), try snapshot.used.hostBytes());
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateLeaseNode(tree, leaves[0]),
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.commitFreeAfterAllocatorFree(authorized.permit),
    );

    const resource_publication = try bank.beginPublicationWithTree(
        tree,
        71,
        session_id,
        1,
    );
    bank.commitPublicationAssumeValid(resource_publication);
    try std.testing.expectError(Error.InvalidTransition, bank.closeLeaseTree(tree));
    try bank.closePublicationSession(receipt, 71, session_id, 2);
    try bank.closeLeaseTree(tree);
    try bank.release(receipt);
    snapshot = try bank.snapshotV3();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_tree_opens);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_scope_opens);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_allocation_reserves);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_allocation_materializations);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_reclaim_prepares);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_reclaim_authorizations);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_reclaim_commits);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_tree_closes);
}

test "LeaseTree storage is explicit and leaves legacy ABIs unchanged" {
    if (@sizeOf(usize) == 8)
        try std.testing.expectEqual(@as(usize, 152), @sizeOf(Slot));
    var slots = [_]Slot{.{}} ** 1;
    var flat = try Bank.init(&slots, .{}, 0x5032_4347);
    const flat_receipt = try flat.commit(try flat.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    try std.testing.expectError(
        Error.InvalidConfiguration,
        flat.openLeaseTree(
            flat_receipt,
            1,
            2,
            .{ .kv_bytes = 1 },
        ),
    );
    try std.testing.expectEqual(abi, (try flat.snapshot()).abi_version);
    try std.testing.expectEqual(snapshot_abi, (try flat.snapshotV2()).abi_version);
    const flat_v3 = try flat.snapshotV3();
    try std.testing.expectEqual(snapshot_v3_abi, flat_v3.abi_version);
    try std.testing.expectEqual(@as(usize, 0), flat_v3.lease_metadata_bytes);
    try flat.release(flat_receipt);

    var wrong_roots = [_]LeaseTreeRootSlot{.{}} ** 2;
    var no_nodes = [_]LeaseNodeSlot{};
    try std.testing.expectError(
        Error.InvalidConfiguration,
        Bank.initWithLeaseTreeStorage(
            &slots,
            &wrong_roots,
            &no_nodes,
            .{},
            0x5032_4348,
        ),
    );

    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]LeaseNodeSlot{.{}} ** 1;
    var tree_bank = try Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{},
        0x5032_4349,
    );
    const tree_receipt = try tree_bank.commit(try tree_bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    try std.testing.expectError(
        Error.InvalidConfiguration,
        tree_bank.openChild(
            tree_receipt,
            1,
            .{ .kv_bytes = 1 },
            .{},
        ),
    );
    const tree = try tree_bank.openLeaseTree(
        tree_receipt,
        1,
        2,
        .{ .kv_bytes = 1 },
    );
    const tree_v3 = try tree_bank.snapshotV3();
    try std.testing.expectEqual(@sizeOf(LeaseTreeRootSlot), tree_v3.lease_root_pool_bytes);
    try std.testing.expectEqual(@sizeOf(LeaseNodeSlot), tree_v3.lease_node_pool_bytes);
    try std.testing.expectEqual(
        @sizeOf(LeaseTreeRootSlot) + @sizeOf(LeaseNodeSlot),
        tree_v3.lease_metadata_bytes,
    );
    try std.testing.expectEqual(@as(usize, 0), tree_v3.active_lease_nodes);
    try std.testing.expectEqual(@as(u64, 0), tree_v3.used.kv_bytes);
    try tree_bank.closeLeaseTree(tree);
    try tree_bank.release(tree_receipt);
}

test "LeaseTree aborted reservation stays charged until abort-after-free" {
    var slots = [_]Slot{.{}} ** 1;
    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]LeaseNodeSlot{.{}} ** 3;
    var bank = try Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 128 },
        0x5032_4343,
    );
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    const opened = try bank.openLeaseTree(
        receipt,
        1,
        2,
        .{ .kv_bytes = 128 },
    );
    const lane = try bank.openLeaseScope(
        opened,
        3,
        4,
        .{ .kv_bytes = 128 },
    );
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSessionWithTree(lane.tree, 5, session_id);
    const specs = [_]LeaseAllocationSpecV1{.{
        .scope = lane.scope,
        .node_key = 6,
        .binding_key = 7,
        .claim = .{ .kv_bytes = 64 },
    }};
    var leaves: [1]LeaseNodeV1 = undefined;
    const pending = try bank.reserveAllocationsForSession(
        lane.tree,
        5,
        session_id,
        0,
        &specs,
        &leaves,
    );
    var forged = pending.batch;
    forged.claim.kv_bytes -= 1;
    try std.testing.expectError(
        Error.StaleReservation,
        bank.abortAllocationsAfterFree(forged),
    );
    try std.testing.expectEqual(@as(u64, 64), (try bank.snapshotV3()).used.kv_bytes);

    var tree = try bank.abortAllocationsAfterFree(pending.batch);
    try std.testing.expectEqual(@as(u64, 0), tree.current.kv_bytes);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.abortAllocationsAfterFree(pending.batch),
    );
    try std.testing.expectError(
        Error.StaleReservation,
        bank.validateLeaseNode(tree, leaves[0]),
    );

    const second_specs = [_]LeaseAllocationSpecV1{.{
        .scope = lane.scope,
        .node_key = 8,
        .binding_key = 9,
        .claim = .{ .kv_bytes = 32 },
    }};
    var second_leaves: [1]LeaseNodeV1 = undefined;
    const second = try bank.reserveAllocationsForSession(
        tree,
        5,
        session_id,
        0,
        &second_specs,
        &second_leaves,
    );
    try std.testing.expect(second_leaves[0].generation != leaves[0].generation);
    tree = try bank.abortAllocationsAfterFree(second.batch);
    try bank.closePublicationSession(receipt, 5, session_id, 0);
    try bank.closeLeaseTree(tree);
    try bank.release(receipt);
    const snapshot = try bank.snapshotV3();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 2), snapshot.lease_allocation_aborts);
}

test "LeaseTree capacity and node exhaustion are atomic and distinct" {
    var slots = [_]Slot{.{}} ** 1;
    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    // The scope consumes one node, leaving exactly one allocation leaf.
    var nodes = [_]LeaseNodeSlot{.{}} ** 2;
    var bank = try Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 64 },
        0x5032_4344,
    );
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    const opened = try bank.openLeaseTree(
        receipt,
        1,
        2,
        .{ .kv_bytes = 128 },
    );
    const lane = try bank.openLeaseScope(
        opened,
        3,
        4,
        .{ .kv_bytes = 128 },
    );
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSessionWithTree(lane.tree, 5, session_id);
    const too_many = [_]LeaseAllocationSpecV1{
        .{ .scope = lane.scope, .node_key = 6, .binding_key = 7, .claim = .{ .kv_bytes = 16 } },
        .{ .scope = lane.scope, .node_key = 8, .binding_key = 9, .claim = .{ .kv_bytes = 16 } },
    };
    var two_leaves: [2]LeaseNodeV1 = undefined;
    try std.testing.expectError(
        Error.LeaseNodesExhausted,
        bank.reserveAllocationsForSession(
            lane.tree,
            5,
            session_id,
            0,
            &too_many,
            &two_leaves,
        ),
    );
    try bank.validateLeaseTree(lane.tree);
    var snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(u64, 0), snapshot.used.kv_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_lease_nodes);

    const too_large = [_]LeaseAllocationSpecV1{.{
        .scope = lane.scope,
        .node_key = 10,
        .binding_key = 11,
        .claim = .{ .kv_bytes = 65 },
    }};
    var one_leaf: [1]LeaseNodeV1 = undefined;
    try std.testing.expectError(
        Error.CapacityExceeded,
        bank.reserveAllocationsForSession(
            lane.tree,
            5,
            session_id,
            0,
            &too_large,
            &one_leaf,
        ),
    );
    try bank.validateLeaseTree(lane.tree);
    snapshot = try bank.snapshotV3();
    try std.testing.expectEqual(@as(u64, 0), snapshot.used.kv_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_lease_capacity);
    try bank.closePublicationSession(receipt, 5, session_id, 0);
    try bank.closeLeaseTree(lane.tree);
    try bank.release(receipt);
}

test "LeaseTree retire cancel invalidates copied permit without uncharge" {
    var slots = [_]Slot{.{}} ** 1;
    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]LeaseNodeSlot{.{}} ** 3;
    var bank = try Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 64 },
        0x5032_4345,
    );
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    const opened = try bank.openLeaseTree(
        receipt,
        1,
        2,
        .{ .kv_bytes = 64 },
    );
    const lane = try bank.openLeaseScope(
        opened,
        3,
        4,
        .{ .kv_bytes = 64 },
    );
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSessionWithTree(lane.tree, 5, session_id);
    const specs = [_]LeaseAllocationSpecV1{.{
        .scope = lane.scope,
        .node_key = 6,
        .binding_key = 7,
        .claim = .{ .kv_bytes = 64 },
    }};
    var leaf: [1]LeaseNodeV1 = undefined;
    const batch = try bank.reserveAllocationsForSession(
        lane.tree,
        5,
        session_id,
        0,
        &specs,
        &leaf,
    );
    var tree = try bank.commitAllocationsAfterAllocate(batch.batch);
    const first = try bank.beginRetireSubtreeForSession(
        tree,
        lane.scope,
        5,
        session_id,
        0,
    );
    tree = try bank.cancelRetire(first.ticket);
    try std.testing.expectEqual(@as(u64, 64), (try bank.snapshotV3()).used.kv_bytes);
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.authorizeFree(first.ticket),
    );
    const second = try bank.beginRetireSubtreeForSession(
        tree,
        lane.scope,
        5,
        session_id,
        0,
    );
    const authorized = try bank.authorizeFree(second.ticket);
    tree = authorized.tree;
    try std.testing.expectError(
        Error.InvalidTransition,
        bank.cancelRetire(second.ticket),
    );
    var forged = authorized.permit;
    forged.node_set_digest ^= 1;
    try std.testing.expectError(
        Error.StaleReservation,
        bank.commitFreeAfterAllocatorFree(forged),
    );
    try std.testing.expectEqual(@as(u64, 64), (try bank.snapshotV3()).used.kv_bytes);
    tree = try bank.commitFreeAfterAllocatorFree(authorized.permit);
    try bank.closePublicationSession(receipt, 5, session_id, 0);
    try bank.closeLeaseTree(tree);
    try bank.release(receipt);
    const snapshot = try bank.snapshotV3();
    try std.testing.expect(snapshot.used.isZero());
    try std.testing.expectEqual(@as(u64, 2), snapshot.lease_reclaim_prepares);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_reclaim_authorizations);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_reclaim_cancels);
    try std.testing.expectEqual(@as(u64, 1), snapshot.lease_reclaim_commits);
}

test "LeaseTree publication and retire linearize on one exact tree token" {
    const Publisher = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        tree: LeaseTreeV1,
        request_epoch: u64,
        session_id: usize,
        permit: ?PublicationPermit = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.permit = self.bank.beginPublicationWithTree(
                self.tree,
                self.request_epoch,
                self.session_id,
                0,
            ) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };
    const Reclaimer = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        tree: LeaseTreeV1,
        scope: LeaseNodeV1,
        request_epoch: u64,
        session_id: usize,
        prepared: ?LeaseRetirePreparedV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.prepared = self.bank.beginRetireSubtreeForSession(
                self.tree,
                self.scope,
                self.request_epoch,
                self.session_id,
                0,
            ) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };

    var slots = [_]Slot{.{}} ** 1;
    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]LeaseNodeSlot{.{}} ** 3;
    var bank = try Bank.initWithLeaseTreeStorage(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 64 },
        0x5032_4346,
    );
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    const opened = try bank.openLeaseTree(
        receipt,
        1,
        2,
        .{ .kv_bytes = 64 },
    );
    const lane = try bank.openLeaseScope(
        opened,
        3,
        4,
        .{ .kv_bytes = 64 },
    );
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSessionWithTree(lane.tree, 5, session_id);
    const specs = [_]LeaseAllocationSpecV1{.{
        .scope = lane.scope,
        .node_key = 6,
        .binding_key = 7,
        .claim = .{ .kv_bytes = 64 },
    }};
    var leaf: [1]LeaseNodeV1 = undefined;
    const batch = try bank.reserveAllocationsForSession(
        lane.tree,
        5,
        session_id,
        0,
        &specs,
        &leaf,
    );
    const tree = try bank.commitAllocationsAfterAllocate(batch.batch);

    var start = std.atomic.Value(bool).init(false);
    var publisher: Publisher = .{
        .bank = &bank,
        .start = &start,
        .tree = tree,
        .request_epoch = 5,
        .session_id = session_id,
    };
    var reclaimer: Reclaimer = .{
        .bank = &bank,
        .start = &start,
        .tree = tree,
        .scope = lane.scope,
        .request_epoch = 5,
        .session_id = session_id,
    };
    const publication_thread = try std.Thread.spawn(
        .{},
        Publisher.run,
        .{&publisher},
    );
    const reclaim_thread = std.Thread.spawn(
        .{},
        Reclaimer.run,
        .{&reclaimer},
    ) catch |err| {
        start.store(true, .release);
        publication_thread.join();
        return err;
    };
    start.store(true, .release);
    publication_thread.join();
    reclaim_thread.join();

    try std.testing.expect((publisher.permit == null) != (reclaimer.prepared == null));
    var final_tree: LeaseTreeV1 = undefined;
    if (publisher.permit) |permit| {
        try std.testing.expectEqual(Error.InvalidTransition, reclaimer.operation_error.?);
        try bank.abortPublication(permit);
        const prepared = try bank.beginRetireSubtreeForSession(
            tree,
            lane.scope,
            5,
            session_id,
            0,
        );
        const authorized = try bank.authorizeFree(prepared.ticket);
        final_tree = try bank.commitFreeAfterAllocatorFree(authorized.permit);
    } else {
        try std.testing.expect(
            publisher.operation_error.? == Error.StaleReservation or
                publisher.operation_error.? == Error.InvalidTransition,
        );
        const authorized = try bank.authorizeFree(reclaimer.prepared.?.ticket);
        final_tree = try bank.commitFreeAfterAllocatorFree(authorized.permit);
    }
    try std.testing.expectEqual(@as(u64, 0), (try bank.snapshotV3()).used.kv_bytes);
    try bank.closePublicationSession(receipt, 5, session_id, 0);
    try bank.closeLeaseTree(final_tree);
    try bank.release(receipt);
}

test "LeaseTree copied retire ticket cancel and authorize linearize irreversibly" {
    const Canceller = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        ticket: LeaseRetireTicketV1,
        tree: ?LeaseTreeV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.tree = self.bank.cancelRetire(self.ticket) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };
    const Authorizer = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        ticket: LeaseRetireTicketV1,
        authorized: ?LeaseFreeAuthorizedV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.authorized = self.bank.authorizeFree(self.ticket) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };

    var slots = [_]Slot{.{}} ** 1;
    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]LeaseNodeSlot{.{}} ** 2;
    var bank = try Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 64 },
        0x5032_434a,
    );
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    var tree = try bank.openLeaseTree(
        receipt,
        1,
        2,
        .{ .kv_bytes = 64 },
    );
    const lane = try bank.openScope(
        tree,
        3,
        4,
        .{ .kv_bytes = 64 },
    );
    tree = lane.tree;
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSessionWithTree(tree, 5, session_id);
    const specs = [_]LeaseAllocationSpecV1{.{
        .scope = lane.scope,
        .node_key = 6,
        .binding_key = 7,
        .claim = .{ .kv_bytes = 64 },
    }};
    var leaf: [1]LeaseNodeV1 = undefined;
    const batch = try bank.reserveAllocationsForSession(
        tree,
        5,
        session_id,
        0,
        &specs,
        &leaf,
    );
    tree = try bank.commitAllocationsAfterAllocate(batch.batch);
    const prepared = try bank.beginRetireSubtreeForSession(
        tree,
        lane.scope,
        5,
        session_id,
        0,
    );

    var start = std.atomic.Value(bool).init(false);
    var canceller: Canceller = .{
        .bank = &bank,
        .start = &start,
        .ticket = prepared.ticket,
    };
    var authorizer: Authorizer = .{
        .bank = &bank,
        .start = &start,
        .ticket = prepared.ticket,
    };
    const cancel_thread = try std.Thread.spawn(.{}, Canceller.run, .{&canceller});
    const authorize_thread = std.Thread.spawn(
        .{},
        Authorizer.run,
        .{&authorizer},
    ) catch |err| {
        start.store(true, .release);
        cancel_thread.join();
        return err;
    };
    start.store(true, .release);
    cancel_thread.join();
    authorize_thread.join();

    try std.testing.expect((canceller.tree == null) != (authorizer.authorized == null));
    if (authorizer.authorized) |authorized| {
        try std.testing.expectEqual(Error.InvalidTransition, canceller.operation_error.?);
        try std.testing.expectError(
            Error.InvalidTransition,
            bank.cancelRetire(prepared.ticket),
        );
        tree = try bank.commitFreeAfterAllocatorFree(authorized.permit);
    } else {
        try std.testing.expectEqual(Error.InvalidTransition, authorizer.operation_error.?);
        tree = canceller.tree.?;
        const retry = try bank.beginRetireSubtreeForSession(
            tree,
            lane.scope,
            5,
            session_id,
            0,
        );
        const authorized = try bank.authorizeFree(retry.ticket);
        try std.testing.expectError(
            Error.InvalidTransition,
            bank.cancelRetire(retry.ticket),
        );
        tree = try bank.commitFreeAfterAllocatorFree(authorized.permit);
    }
    try std.testing.expectEqual(@as(u64, 0), (try bank.snapshotV3()).used.kv_bytes);
    try bank.closePublicationSession(receipt, 5, session_id, 0);
    try bank.closeLeaseTree(tree);
    try bank.release(receipt);
}

test "LeaseTree copied allocation batch decision linearizes one trusted outcome" {
    const Settler = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        batch: LeaseAllocationBatchV1,
        tree: ?LeaseTreeV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.tree = self.bank.commitAllocationsAfterAllocate(self.batch) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };
    const Aborter = struct {
        bank: *Bank,
        start: *std.atomic.Value(bool),
        batch: LeaseAllocationBatchV1,
        tree: ?LeaseTreeV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            // Test models the trusted coordinator's already-satisfied
            // abort-after-free precondition; the Bank cannot observe it.
            self.tree = self.bank.abortAllocationsAfterFree(self.batch) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };

    var slots = [_]Slot{.{}} ** 1;
    var roots = [_]LeaseTreeRootSlot{.{}} ** slots.len;
    var nodes = [_]LeaseNodeSlot{.{}} ** 2;
    var bank = try Bank.initWithLeaseTree(
        &slots,
        &roots,
        &nodes,
        .{ .kv_bytes = 64 },
        0x5032_434b,
    );
    const receipt = try bank.commit(try bank.reserve(
        1,
        .{ .queue_slots = 1 },
    ));
    var tree = try bank.openLeaseTree(
        receipt,
        1,
        2,
        .{ .kv_bytes = 64 },
    );
    const lane = try bank.openScope(
        tree,
        3,
        4,
        .{ .kv_bytes = 64 },
    );
    tree = lane.tree;
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    try bank.bindPublicationSessionWithTree(tree, 5, session_id);
    const specs = [_]LeaseAllocationSpecV1{.{
        .scope = lane.scope,
        .node_key = 6,
        .binding_key = 7,
        .claim = .{ .kv_bytes = 64 },
    }};
    var leaf: [1]LeaseNodeV1 = undefined;
    const reserved = try bank.reserveAllocationsForSession(
        tree,
        5,
        session_id,
        0,
        &specs,
        &leaf,
    );
    var start = std.atomic.Value(bool).init(false);
    var settler: Settler = .{
        .bank = &bank,
        .start = &start,
        .batch = reserved.batch,
    };
    var aborter: Aborter = .{
        .bank = &bank,
        .start = &start,
        .batch = reserved.batch,
    };
    const settle_thread = try std.Thread.spawn(.{}, Settler.run, .{&settler});
    const abort_thread = std.Thread.spawn(.{}, Aborter.run, .{&aborter}) catch |err| {
        start.store(true, .release);
        settle_thread.join();
        return err;
    };
    start.store(true, .release);
    settle_thread.join();
    abort_thread.join();

    try std.testing.expect((settler.tree == null) != (aborter.tree == null));
    if (settler.tree) |settled_tree| {
        try std.testing.expectEqual(Error.InvalidTransition, aborter.operation_error.?);
        const prepared = try bank.beginRetireSubtreeForSession(
            settled_tree,
            lane.scope,
            5,
            session_id,
            0,
        );
        const authorized = try bank.authorizeFree(prepared.ticket);
        tree = try bank.commitFreeAfterAllocatorFree(authorized.permit);
    } else {
        try std.testing.expectEqual(Error.InvalidTransition, settler.operation_error.?);
        tree = aborter.tree.?;
    }
    try std.testing.expectEqual(@as(u64, 0), (try bank.snapshotV3()).used.kv_bytes);
    try bank.closePublicationSession(receipt, 5, session_id, 0);
    try bank.closeLeaseTree(tree);
    try bank.release(receipt);
}
