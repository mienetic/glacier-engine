//! Model-free, resource-governed scheduling for independently admitted work.
//!
//! LaneWeave QoS v1 is a bounded control-plane kernel. It uses deterministic
//! interleaved weighted round-robin (IWRR), projects logical deadlines before
//! ResourceBank mutation, retains finished requests until explicit retirement,
//! and emits a challenge-bound hash chain for every committed policy decision.
//! A generation-fenced single-flight service permit lets external work run
//! without holding the scheduler mutex; abort restores the same logical state.
//! One service quantum is a logical committed-work unit, not wall-clock time,
//! token publication, or proof that an inference kernel ran.

const std = @import("std");
const resource_bank = @import("resource_bank.zig");

/// Semantic state/snapshot ABI. `Scheduler` is a source-level Zig coordinator;
/// its in-memory struct layout is deliberately not a stable binary ABI.
pub const abi: u64 = 0x474c_5751_0000_0001;
pub const event_abi: u64 = 0x474c_5745_0000_0001;
pub const service_permit_abi: u64 = 0x474c_5750_0000_0001;
pub const service_intent_abi: u64 = 0x474c_5749_0000_0001;
pub const service_commit_ticket_abi: u64 = 0x474c_5743_0000_0001;
pub const service_finalizer_abi: u64 = 0x474c_5746_0000_0001;
pub const service_finalizer_v2_abi: u64 = 0x474c_5746_0000_0002;
pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

const initial_root_domain = "glacier-lane-weave-qos-root-v1\x00";
const event_domain = "glacier-lane-weave-qos-event-v1\x00";
const service_permit_domain = "glacier-lane-weave-qos-service-permit-v1\x00";
const service_intent_domain = "glacier-lane-weave-qos-service-intent-v1\x00";
const service_commit_ticket_domain =
    "glacier-lane-weave-qos-service-commit-ticket-v1\x00";
const receipt_domain = "glacier-lane-weave-qos-resource-receipt-v1\x00";

pub const Error = error{
    InvalidConfiguration,
    InvalidRequest,
    ClaimOverflow,
    TickOverflow,
    SequenceOverflow,
    GenerationOverflow,
    ServiceOverflow,
    NoRunnableRequest,
    ServiceInFlight,
    StaleServicePermit,
    StaleServiceCommitTicket,
    StaleHandle,
    InvalidTransition,
    BankDrift,
    InvariantViolation,
    SchedulerPoisoned,
    SchedulerClosed,
    IncompleteDrain,
    InvalidEvent,
};

/// Immutable scheduler identity and bounded policy envelope.
pub const Config = struct {
    scheduler_epoch: u64,
    challenge: Digest,
    max_weight: u16 = 64,
    /// Maximum logical quanta simulated by one deadline projection.
    max_projection_quanta: u64 = 1_000_000,
    /// Maximum deterministic slot/scan operations performed while deciding one
    /// deadline projection. Admission still has separate O(capacity) hashing,
    /// duplicate and resource-ledger passes while holding the mutex.
    max_projection_operations: u64 = 1_000_000,
};

/// One finite logical request admitted under a dedicated ResourceBank receipt.
pub const RequestSpec = struct {
    tenant_key: u64 = 0,
    request_key: u64 = 0,
    request_generation: u64 = 0,
    resource_owner_key: u64 = 0,
    weight: u16 = 0,
    work_quanta: u64 = 0,
    /// Absolute logical service tick. Zero means no logical deadline.
    deadline_tick: u64 = 0,
    claim: resource_bank.Claim = .{},
};

/// Generation-fenced identity for cancellation and terminal retirement.
pub const Handle = struct {
    scheduler_epoch: u64 = 0,
    slot_index: u32 = 0,
    slot_generation: u64 = 0,
    tenant_key: u64 = 0,
    request_key: u64 = 0,
    request_generation: u64 = 0,
};

/// Generation-fenced selection frozen at a caller-owned quiescent boundary.
/// The permit is bound to one process-local Scheduler lifetime and address. It
/// is a logical scheduling capability only and does not attest that external
/// work ran or that token/KV/RNG/output publication committed.
pub const ServicePermitV1 = struct {
    abi_version: u64 = service_permit_abi,
    scheduler_epoch: u64 = 0,
    coordinator_id: u64 = 0,
    coordinator_address: u64 = 0,
    permit_generation: u64 = 0,
    event_sequence: u64 = 0,
    handle: Handle = .{},
    logical_tick_before: u64 = 0,
    cursor_before: u32 = 0,
    level_before: u16 = 0,
    cursor_after: u32 = 0,
    level_after: u16 = 0,
    remaining_before: u64 = 0,
    wait_quanta: u64 = 0,
    maximum_service_gap: u64 = 0,
    state_before_sha256: Digest = zero_digest,
    chain_head_before_sha256: Digest = zero_digest,
    resource_receipt: resource_bank.Receipt = zeroReceipt(),
    resource_receipt_sha256: Digest = zero_digest,
    permit_sha256: Digest = zero_digest,
};

/// Canonical pointer-free description of one selected logical service. The
/// digest intentionally omits process address, coordinator identity, permit
/// generation and permit digest, so abort/retry over unchanged logical state
/// yields the same idempotent intent. It is evidence, not live authority.
pub const ServiceIntentV1 = struct {
    abi_version: u64 = service_intent_abi,
    lane_weave_abi: u64 = abi,
    event_abi_version: u64 = event_abi,
    source_permit_abi: u64 = service_permit_abi,
    resource_bank_abi_version: u64 = resource_bank.abi,
    scheduler_epoch: u64 = 0,
    event_sequence: u64 = 0,
    handle: Handle = .{},
    spec: RequestSpec = .{},
    logical_tick_before: u64 = 0,
    cursor_before: u32 = 0,
    level_before: u16 = 0,
    cursor_after: u32 = 0,
    level_after: u16 = 0,
    remaining_before: u64 = 0,
    wait_quanta: u64 = 0,
    maximum_service_gap: u64 = 0,
    state_before_sha256: Digest = zero_digest,
    chain_head_before_sha256: Digest = zero_digest,
    resource_receipt: resource_bank.Receipt = zeroReceipt(),
    resource_receipt_sha256: Digest = zero_digest,
    intent_sha256: Digest = zero_digest,
};

/// Address-bound authority that arms one prepared permit for an infallible
/// publication finalizer. The ticket is operational process state, not a
/// portable receipt. Copies are first-winner-only.
pub const ServiceCommitTicketV1 = struct {
    abi_version: u64 = service_commit_ticket_abi,
    scheduler_epoch: u64 = 0,
    coordinator_id: u64 = 0,
    coordinator_address: u64 = 0,
    permit_generation: u64 = 0,
    permit_sha256: Digest = zero_digest,
    commit_generation: u64 = 0,
    ticket_sha256: Digest = zero_digest,
};

/// Result of atomically converting a live permit into finalizer-only authority.
pub const ArmedServiceV1 = struct {
    ticket: ServiceCommitTicketV1,
    intent: ServiceIntentV1,
};

/// Trusted in-process finalization hook. It runs exactly once after Event-v1
/// is committed but before the Scheduler mutex is released. Implementations
/// must be bounded and infallible, must not allocate, block or perform I/O,
/// and must not re-enter this Scheduler. A finalizer may enter ResourceBank
/// only in Scheduler -> Bank lock order; callbacks it invokes must not re-enter
/// either coordinator. A panic is a process-fatal contract breach.
pub const ServiceFinalizerV1 = struct {
    abi_version: u64 = service_finalizer_abi,
    context: *anyopaque,
    finalize: *const fn (
        context: *anyopaque,
        event: *const EventV1,
    ) void,
};

/// Additive bound-publication finalizer. V2 retains the V1 callback contract
/// and adds the exact process-local session authority registered on the lane.
/// These authority fields are operational only and never enter Event-v1.
pub const ServiceFinalizerV2 = struct {
    abi_version: u64 = service_finalizer_v2_abi,
    publication_request_epoch: u64,
    publication_session_id: usize,
    context: *anyopaque,
    finalize: *const fn (
        context: *anyopaque,
        event: *const EventV1,
    ) void,
};

/// Selects which services of a bound lane both allow and require V2
/// publication authority. Unprotected quanta retain only legacy raw/V1
/// service paths. This is process-local policy, not portable Event-v1 state.
pub const PublicationServicePolicy = enum(u8) {
    none,
    every_service,
    final_service,
};

/// Lifecycle state retained in caller-owned storage.
pub const SlotState = enum(u8) {
    free,
    active,
    finished,
};

/// Caller-owned fixed storage. Callers must not inspect or mutate a slot after
/// passing the slice to `Scheduler.init`.
pub const Slot = struct {
    state: SlotState = .free,
    generation: u64 = 0,
    spec: RequestSpec = .{},
    remaining_quanta: u64 = 0,
    admitted_tick: u64 = 0,
    last_service_tick: u64 = 0,
    service_count: u64 = 0,
    receipt: resource_bank.Receipt = zeroReceipt(),
    receipt_sha256: Digest = zero_digest,
    /// Process-local fence only. These fields intentionally remain outside
    /// the V1 semantic state hash so binding preserves every legacy Event-v1
    /// byte while still constraining live Scheduler methods.
    publication_request_epoch: u64 = 0,
    publication_session_id: usize = 0,
    publication_service_policy: PublicationServicePolicy = .none,
};

/// Scratch state for fail-before-reserve deadline projection.
pub const ProjectionSlot = struct {
    active: bool = false,
    weight: u16 = 0,
    remaining_quanta: u64 = 0,
    deadline_tick: u64 = 0,
};

/// Address-stable scheduler and projection storage.
pub const Storage = struct {
    slots: []Slot,
    projection: []ProjectionSlot,
};

/// Policy rejection emitted without ResourceBank mutation.
pub const RejectionReason = enum(u8) {
    none,
    no_slot,
    duplicate_tenant,
    resource_limit,
    projection_limit,
    deadline_infeasible,
};

/// Lifecycle operation committed to the receipt chain.
pub const EventKind = enum(u8) {
    admission_accepted,
    admission_rejected,
    service,
    cancel,
    retire,
    close,
};

/// Fixed-width logical event. Hashing is field-by-field little endian; raw
/// struct bytes and padding are never part of the wire contract.
pub const EventV1 = struct {
    abi_version: u64 = event_abi,
    scheduler_epoch: u64,
    event_sequence: u64,
    kind: EventKind,
    rejection_reason: RejectionReason = .none,
    previous_sha256: Digest,
    event_sha256: Digest = zero_digest,
    state_before_sha256: Digest,
    state_after_sha256: Digest,
    logical_tick_before: u64,
    logical_tick_after: u64,
    cursor_before: u32,
    cursor_after: u32,
    level_before: u16,
    level_after: u16,
    handle: Handle = .{},
    spec: RequestSpec = .{},
    resource_receipt: resource_bank.Receipt = zeroReceipt(),
    resource_receipt_sha256: Digest = zero_digest,
    remaining_before: u64 = 0,
    remaining_after: u64 = 0,
    wait_quanta: u64 = 0,
    maximum_service_gap: u64,
    active_before: u32,
    active_after: u32,
    finished_before: u32,
    finished_after: u32,
    bank_used_before: resource_bank.Claim,
    bank_used_after: resource_bank.Claim,
};

/// Successful admission handle and its chained event.
pub const Admission = struct {
    handle: Handle,
    event: EventV1,
};

/// Expected policy outcome; malformed requests remain hard errors.
pub const AdmissionDecision = union(enum) {
    admitted: Admission,
    rejected: EventV1,
};

/// Read-only logical scheduler snapshot.
pub const SnapshotV1 = struct {
    abi_version: u64 = abi,
    scheduler_epoch: u64,
    logical_tick: u64,
    next_event_sequence: u64,
    cursor: u32,
    level: u16,
    active: u32,
    finished: u32,
    used: resource_bank.Claim,
    maximum_service_gap: u64,
    chain_head_sha256: Digest,
    poisoned: bool,
    closed: bool,
};

const Selection = struct {
    slot_index: usize,
    cursor_after: u32,
    level_after: u16,
};

const PendingService = struct {
    permit: ServicePermitV1,
    commit_ticket: ?ServiceCommitTicketV1 = null,
};

const ServiceCommitContext = struct {
    selection: Selection,
    index: usize,
    after_tick: u64,
    wait_quanta: u64,
};

const ProjectionOutcome = enum {
    feasible,
    projection_limit,
    deadline_infeasible,
};

const ProjectionBudget = struct {
    remaining: u64,
    exhausted: bool = false,

    fn spend(self: *ProjectionBudget, amount: usize) bool {
        const cost = std.math.cast(u64, amount) orelse {
            self.exhausted = true;
            return false;
        };
        if (cost > self.remaining) {
            self.exhausted = true;
            return false;
        }
        self.remaining -= cost;
        return true;
    }
};

const Counts = struct {
    active: u32,
    finished: u32,
};

var service_coordinator_id_mutex: std.Thread.Mutex = .{};
var next_service_coordinator_id: u64 = 1;

fn reserveServiceCoordinatorId() Error!u64 {
    service_coordinator_id_mutex.lock();
    defer service_coordinator_id_mutex.unlock();
    if (next_service_coordinator_id == 0 or
        next_service_coordinator_id == std.math.maxInt(u64))
        return Error.GenerationOverflow;
    const result = next_service_coordinator_id;
    next_service_coordinator_id += 1;
    return result;
}

/// Address-stable synchronous coordinator. The Bank address and caller-owned
/// storage must already be stable when passed to `init`. The returned Scheduler
/// may move until its first public method call; its address must then remain
/// stable until `close` succeeds. Never copy a live Scheduler or concurrently
/// inspect or mutate its public fields. The mutex serializes public methods on
/// one exact instance; it cannot make copied values or external field writes
/// safe.
pub const Scheduler = struct {
    mutex: std.Thread.Mutex = .{},
    bank: *resource_bank.Bank,
    slots: []Slot,
    projection: []ProjectionSlot,
    config: Config,
    service_coordinator_id: u64,
    bank_epoch: u64,
    limits: resource_bank.Limits,
    used: resource_bank.Claim = .{},
    logical_tick: u64 = 0,
    next_event_sequence: u64 = 0,
    next_slot_generation: u64 = 1,
    next_service_permit_generation: u64 = 1,
    next_service_commit_generation: u64 = 1,
    pending_service: ?PendingService = null,
    cursor: u32 = 0,
    level: u16 = 1,
    maximum_service_gap: u64,
    chain_head_sha256: Digest,
    poisoned: bool = false,
    closed: bool = false,

    /// Initialize against a fresh, flat, address-stable Bank dedicated to this
    /// scheduler and address-stable storage slices. The returned value may
    /// move before its first public method call; from that call through
    /// successful `close`, its address remains stable and the value must never
    /// be copied.
    pub fn init(
        bank: *resource_bank.Bank,
        storage: Storage,
        config: Config,
    ) Error!Scheduler {
        if (storage.slots.len == 0 or
            storage.slots.len != storage.projection.len or
            storage.slots.len > std.math.maxInt(u32) or
            bank.slots.len != storage.slots.len or bank.child_slots != null or
            bank.lease_tree_storage != null or
            config.scheduler_epoch == 0 or
            config.max_weight == 0 or
            config.max_projection_quanta == 0 or
            config.max_projection_operations == 0 or
            std.mem.eql(u8, &config.challenge, &zero_digest))
            return Error.InvalidConfiguration;

        const cap_minus_one = storage.slots.len - 1;
        const weighted = std.math.mul(
            u64,
            @intCast(cap_minus_one),
            config.max_weight,
        ) catch return Error.InvalidConfiguration;
        const maximum_service_gap = std.math.add(u64, weighted, 1) catch
            return Error.InvalidConfiguration;

        const bank_snapshot = bank.snapshot() catch
            return Error.InvalidConfiguration;
        if (!bank_snapshot.used.isZero() or
            bank_snapshot.active_reservations != 0 or
            bank_snapshot.committed_receipts != 0 or
            bank_snapshot.successful_reservations != 0 or
            bank_snapshot.successful_commits != 0 or
            bank_snapshot.cancellations != 0 or
            bank_snapshot.releases != 0 or
            bank_snapshot.rejected_capacity != 0 or
            bank_snapshot.rejected_slots != 0)
            return Error.InvalidConfiguration;
        const service_coordinator_id = try reserveServiceCoordinatorId();

        for (storage.slots) |*slot| slot.* = .{};
        for (storage.projection) |*slot| slot.* = .{};

        return .{
            .bank = bank,
            .slots = storage.slots,
            .projection = storage.projection,
            .config = config,
            .service_coordinator_id = service_coordinator_id,
            .bank_epoch = bank_snapshot.bank_epoch,
            .limits = bank_snapshot.limits,
            .maximum_service_gap = maximum_service_gap,
            .chain_head_sha256 = initialRoot(
                config,
                @intCast(storage.slots.len),
                bank_snapshot.bank_epoch,
                bank_snapshot.limits,
                maximum_service_gap,
            ),
        };
    }

    /// Validate policy and deadline feasibility, then reserve and commit the
    /// exact request claim. Expected rejection still emits a chained event.
    pub fn admit(self: *Scheduler, spec: RequestSpec) Error!AdmissionDecision {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        try self.requireNoService();
        try self.validateBank();
        try self.validateSpec(spec);
        try self.preflightEvent();

        const before_state = self.stateSha256();
        const before_counts = self.counts();
        const before_used = self.used;
        const before_cursor = self.cursor;
        const before_level = self.level;
        const before_tick = self.logical_tick;

        var free_index: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.state != .free and slot.spec.tenant_key == spec.tenant_key)
                return .{ .rejected = self.emitRejection(
                    spec,
                    .duplicate_tenant,
                    before_state,
                    before_counts,
                    before_used,
                    before_cursor,
                    before_level,
                    before_tick,
                ) };
            if (slot.state == .free and free_index == null) free_index = index;
        }
        const index = free_index orelse return .{ .rejected = self.emitRejection(
            spec,
            .no_slot,
            before_state,
            before_counts,
            before_used,
            before_cursor,
            before_level,
            before_tick,
        ) };

        const next_used = addClaims(self.used, spec.claim) catch
            return .{ .rejected = self.emitRejection(
                spec,
                .resource_limit,
                before_state,
                before_counts,
                before_used,
                before_cursor,
                before_level,
                before_tick,
            ) };
        const fits = self.limits.fits(next_used) catch false;
        if (!fits) return .{ .rejected = self.emitRejection(
            spec,
            .resource_limit,
            before_state,
            before_counts,
            before_used,
            before_cursor,
            before_level,
            before_tick,
        ) };

        switch (self.projectAdmission(index, spec)) {
            .projection_limit => return .{ .rejected = self.emitRejection(
                spec,
                .projection_limit,
                before_state,
                before_counts,
                before_used,
                before_cursor,
                before_level,
                before_tick,
            ) },
            .deadline_infeasible => return .{ .rejected = self.emitRejection(
                spec,
                .deadline_infeasible,
                before_state,
                before_counts,
                before_used,
                before_cursor,
                before_level,
                before_tick,
            ) },
            .feasible => {},
        }

        if (self.next_slot_generation == 0 or
            self.next_slot_generation == std.math.maxInt(u64))
            return Error.GenerationOverflow;
        const slot_generation = self.next_slot_generation;

        const reservation = self.bank.reserve(
            spec.resource_owner_key,
            spec.claim,
        ) catch return self.poisonBank();
        const receipt = self.bank.commit(reservation) catch {
            self.bank.cancel(reservation) catch return self.poisonBank();
            return self.poisonBank();
        };
        if (receipt.slot_index != index or receipt.generation != slot_generation or
            !resource_bank.receiptIntegrityValidV1(receipt))
        {
            self.bank.release(receipt) catch {};
            return self.poisonBank();
        }

        self.next_slot_generation += 1;
        const receipt_sha256 = resourceReceiptSha256(receipt);
        self.slots[index] = .{
            .state = .active,
            .generation = slot_generation,
            .spec = spec,
            .remaining_quanta = spec.work_quanta,
            .admitted_tick = self.logical_tick,
            .last_service_tick = self.logical_tick,
            .receipt = receipt,
            .receipt_sha256 = receipt_sha256,
        };
        self.used = next_used;

        const handle = self.handleFor(index);
        const event = self.emitCurrent(.{
            .kind = .admission_accepted,
            .state_before_sha256 = before_state,
            .logical_tick_before = before_tick,
            .cursor_before = before_cursor,
            .level_before = before_level,
            .handle = handle,
            .spec = spec,
            .resource_receipt = receipt,
            .resource_receipt_sha256 = receipt_sha256,
            .remaining_after = spec.work_quanta,
            .active_before = before_counts.active,
            .finished_before = before_counts.finished,
            .bank_used_before = before_used,
        });
        return .{ .admitted = .{ .handle = handle, .event = event } };
    }

    /// Bind every service of the exact just-admitted request to an
    /// address-stable publication coordinator. This retains the original
    /// three-argument source API; protected services require a V2 finalizer.
    pub fn bindPublicationSession(
        self: *Scheduler,
        admission: Admission,
        request_epoch: u64,
        session_id: usize,
    ) Error!void {
        return self.bindPublicationSessionWithPolicy(
            admission,
            request_epoch,
            session_id,
            .every_service,
        );
    }

    /// Bind only the final service of the exact just-admitted request. Earlier
    /// services retain the legacy raw/V1 commit paths; the final service
    /// requires a V2 finalizer with this session's exact authority.
    pub fn bindFinalPublicationSession(
        self: *Scheduler,
        admission: Admission,
        request_epoch: u64,
        session_id: usize,
    ) Error!void {
        return self.bindPublicationSessionWithPolicy(
            admission,
            request_epoch,
            session_id,
            .final_service,
        );
    }

    /// Requiring the admission Event-v1 to remain the current chain head
    /// closes the validate-then-bind gap: no service, cancellation, retirement
    /// or later admission may interleave first.
    fn bindPublicationSessionWithPolicy(
        self: *Scheduler,
        admission: Admission,
        request_epoch: u64,
        session_id: usize,
        service_policy: PublicationServicePolicy,
    ) Error!void {
        if (request_epoch == 0 or session_id == 0 or
            service_policy == .none)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        try self.requireNoService();
        try self.validateBank();

        const event = admission.event;
        if (event.abi_version != event_abi or
            event.kind != .admission_accepted or
            event.rejection_reason != .none or
            event.scheduler_epoch != self.config.scheduler_epoch or
            event.event_sequence == std.math.maxInt(u64) or
            event.event_sequence + 1 != self.next_event_sequence or
            !std.mem.eql(u8, &event.event_sha256, &eventSha256(event)) or
            !std.mem.eql(u8, &event.event_sha256, &self.chain_head_sha256) or
            !std.mem.eql(u8, &event.state_after_sha256, &self.stateSha256()) or
            event.logical_tick_after != self.logical_tick or
            event.cursor_after != self.cursor or event.level_after != self.level or
            !std.meta.eql(admission.handle, event.handle))
            return Error.InvalidTransition;

        const index = self.validateHandle(admission.handle, .active) catch
            return Error.StaleHandle;
        const slot = &self.slots[index];
        const lane_counts = self.counts();
        if (slotPublicationBound(slot.*) or
            !std.meta.eql(event.spec, slot.spec) or
            !std.meta.eql(event.resource_receipt, slot.receipt) or
            !std.mem.eql(
                u8,
                &event.resource_receipt_sha256,
                &slot.receipt_sha256,
            ) or event.remaining_before != 0 or
            event.remaining_after != slot.remaining_quanta or
            event.remaining_after != slot.spec.work_quanta or
            event.active_after != lane_counts.active or
            event.finished_after != lane_counts.finished or
            !std.meta.eql(event.bank_used_after, self.used))
            return Error.InvalidTransition;

        self.bank.bindPublicationSession(
            slot.receipt,
            request_epoch,
            session_id,
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            error.StaleReservation => return Error.StaleHandle,
            error.InvalidTransition => return Error.InvalidTransition,
            else => return self.poisonBank(),
        };
        slot.publication_request_epoch = request_epoch;
        slot.publication_session_id = session_id;
        slot.publication_service_policy = service_policy;
    }

    /// Freeze the next deterministic service selection without advancing the
    /// logical tick, cursor, request work, Bank charge, or event chain. The
    /// caller may execute privately after this method releases the mutex, then
    /// must consume the permit exactly once through `commitService` or
    /// `abortService`.
    pub fn prepareService(self: *Scheduler) Error!ServicePermitV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        try self.requireNoService();
        try self.validateBank();
        try self.preflightEvent();
        if (self.logical_tick == std.math.maxInt(u64))
            return Error.TickOverflow;
        if (self.next_service_permit_generation == 0 or
            self.next_service_permit_generation == std.math.maxInt(u64))
            return Error.GenerationOverflow;

        const selection = selectIWRR(
            self.slots,
            self.cursor,
            self.level,
            self.config.max_weight,
        ) orelse return Error.NoRunnableRequest;
        const slot = &self.slots[selection.slot_index];
        self.bank.validateCommitted(slot.receipt) catch
            return self.poisonBank();
        if (slot.service_count == std.math.maxInt(u64))
            return Error.ServiceOverflow;

        const after_tick = self.logical_tick + 1;
        if (!selectionPreservesDeadlines(
            self.slots,
            selection.slot_index,
            after_tick,
        )) return self.poisonInvariant();
        const wait_quanta = after_tick - slot.last_service_tick;
        if (wait_quanta > self.maximum_service_gap)
            return self.poisonInvariant();

        var permit: ServicePermitV1 = .{
            .scheduler_epoch = self.config.scheduler_epoch,
            .coordinator_id = self.service_coordinator_id,
            .coordinator_address = @intCast(@intFromPtr(self)),
            .permit_generation = self.next_service_permit_generation,
            .event_sequence = self.next_event_sequence,
            .handle = self.handleFor(selection.slot_index),
            .logical_tick_before = self.logical_tick,
            .cursor_before = self.cursor,
            .level_before = self.level,
            .cursor_after = selection.cursor_after,
            .level_after = selection.level_after,
            .remaining_before = slot.remaining_quanta,
            .wait_quanta = wait_quanta,
            .maximum_service_gap = self.maximum_service_gap,
            .state_before_sha256 = self.stateSha256(),
            .chain_head_before_sha256 = self.chain_head_sha256,
            .resource_receipt = slot.receipt,
            .resource_receipt_sha256 = slot.receipt_sha256,
        };
        permit.permit_sha256 = servicePermitSha256(permit);
        self.next_service_permit_generation += 1;
        self.pending_service = .{ .permit = permit };
        return permit;
    }

    /// Commit one logical unit selected by deterministic IWRR. The request's
    /// Bank receipt remains charged when the final quantum completes; callers
    /// must explicitly `retire` after downstream state is durably finished.
    pub fn serveOne(self: *Scheduler) Error!EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        try self.requireNoService();
        try self.validateBank();
        try self.preflightEvent();
        if (self.logical_tick == std.math.maxInt(u64)) return Error.TickOverflow;

        const selection = selectIWRR(
            self.slots,
            self.cursor,
            self.level,
            self.config.max_weight,
        ) orelse return Error.NoRunnableRequest;
        const slot = &self.slots[selection.slot_index];
        self.bank.validateCommitted(slot.receipt) catch return self.poisonBank();
        if (serviceRequiresBoundFinalizerV2(slot.*))
            return Error.InvalidTransition;

        const before_state = self.stateSha256();
        const before_counts = self.counts();
        const before_used = self.used;
        const before_tick = self.logical_tick;
        const before_cursor = self.cursor;
        const before_level = self.level;
        const before_remaining = slot.remaining_quanta;
        const handle = self.handleFor(selection.slot_index);
        const spec = slot.spec;
        const receipt = slot.receipt;
        const receipt_sha256 = slot.receipt_sha256;

        if (slot.service_count == std.math.maxInt(u64))
            return Error.ServiceOverflow;
        const after_tick = before_tick + 1;
        if (!selectionPreservesDeadlines(
            self.slots,
            selection.slot_index,
            after_tick,
        ))
            return self.poisonInvariant();
        const wait_quanta = after_tick - slot.last_service_tick;
        if (wait_quanta > self.maximum_service_gap)
            return self.poisonInvariant();

        slot.remaining_quanta -= 1;
        slot.last_service_tick = after_tick;
        slot.service_count += 1;
        if (slot.remaining_quanta == 0) slot.state = .finished;
        self.logical_tick = after_tick;
        self.cursor = selection.cursor_after;
        self.level = selection.level_after;

        return self.emitCurrent(.{
            .kind = .service,
            .state_before_sha256 = before_state,
            .logical_tick_before = before_tick,
            .cursor_before = before_cursor,
            .level_before = before_level,
            .handle = handle,
            .spec = spec,
            .resource_receipt = receipt,
            .resource_receipt_sha256 = receipt_sha256,
            .remaining_before = before_remaining,
            .remaining_after = slot.remaining_quanta,
            .wait_quanta = wait_quanta,
            .active_before = before_counts.active,
            .finished_before = before_counts.finished,
            .bank_used_before = before_used,
        });
    }

    /// Consume one unarmed prepared selection exactly once. External execution
    /// remains outside this contract; this method commits only the logical
    /// scheduler transition and its existing Event-v1 receipt.
    pub fn commitService(
        self: *Scheduler,
        permit: ServicePermitV1,
    ) Error!EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        const pending = try self.validatePendingService(permit);
        if (pending.commit_ticket != null) return Error.ServiceInFlight;
        const context = try self.validateServiceCommitLocked(permit);
        if (serviceRequiresBoundFinalizerV2(self.slots[context.index]))
            return Error.InvalidTransition;
        return self.commitServiceLocked(permit, context, null);
    }

    /// Atomically claim the pending permit for finalizer-only completion and
    /// issue its canonical pointer-free intent. Once armed, raw permit commit
    /// and abort reject; only the returned ticket may finish or abort it.
    pub fn armServiceCommit(
        self: *Scheduler,
        permit: ServicePermitV1,
    ) Error!ArmedServiceV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        const pending = try self.validatePendingService(permit);
        if (pending.commit_ticket != null) return Error.ServiceInFlight;
        if (self.next_service_commit_generation == 0 or
            self.next_service_commit_generation == std.math.maxInt(u64))
            return Error.GenerationOverflow;
        const context = try self.validateServiceCommitLocked(permit);

        var ticket: ServiceCommitTicketV1 = .{
            .scheduler_epoch = self.config.scheduler_epoch,
            .coordinator_id = self.service_coordinator_id,
            .coordinator_address = @intCast(@intFromPtr(self)),
            .permit_generation = permit.permit_generation,
            .permit_sha256 = permit.permit_sha256,
            .commit_generation = self.next_service_commit_generation,
        };
        ticket.ticket_sha256 = serviceCommitTicketSha256(ticket);
        self.next_service_commit_generation += 1;
        self.pending_service.?.commit_ticket = ticket;
        return .{
            .ticket = ticket,
            .intent = self.serviceIntentFor(permit, context.index),
        };
    }

    /// Commit one armed service and invoke an infallible finalizer before any
    /// other Scheduler method can observe or advance beyond the Event-v1.
    pub fn commitArmedService(
        self: *Scheduler,
        ticket: ServiceCommitTicketV1,
        finalizer: ServiceFinalizerV1,
    ) Error!EventV1 {
        if (finalizer.abi_version != service_finalizer_abi)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        const pending = try self.validateServiceCommitTicket(ticket);
        const context = try self.validateServiceCommitLocked(pending.permit);
        if (serviceRequiresBoundFinalizerV2(self.slots[context.index]))
            return Error.InvalidTransition;
        return self.commitServiceLocked(
            pending.permit,
            context,
            finalizer,
        );
    }

    /// Commit one protected service with exact bound publication authority.
    /// V2 is accepted only on quanta selected by the lane's binding policy;
    /// V1 remains layout- and behavior-compatible for unbound or unprotected
    /// services.
    pub fn commitArmedServiceV2(
        self: *Scheduler,
        ticket: ServiceCommitTicketV1,
        finalizer: ServiceFinalizerV2,
    ) Error!EventV1 {
        if (finalizer.abi_version != service_finalizer_v2_abi or
            finalizer.publication_request_epoch == 0 or
            finalizer.publication_session_id == 0)
            return Error.InvalidConfiguration;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        const pending = try self.validateServiceCommitTicket(ticket);
        const context = try self.validateServiceCommitLocked(pending.permit);
        const slot = self.slots[context.index];
        if (!slotPublicationBindingValid(slot) or
            !serviceRequiresBoundFinalizerV2(slot) or
            finalizer.publication_request_epoch !=
                slot.publication_request_epoch or
            finalizer.publication_session_id !=
                slot.publication_session_id)
            return Error.InvalidTransition;
        return self.commitServiceLocked(
            pending.permit,
            context,
            .{
                .context = finalizer.context,
                .finalize = finalizer.finalize,
            },
        );
    }

    /// Abort an armed service without emitting an Event-v1 or changing logical
    /// scheduler, request, Bank-charge or receipt-chain state.
    pub fn abortArmedService(
        self: *Scheduler,
        ticket: ServiceCommitTicketV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        const pending = try self.validateServiceCommitTicket(ticket);
        try self.validateBank();
        try self.validateServiceBeforeState(pending.permit);
        self.pending_service = null;
    }

    /// Consume one prepared selection without a logical service transition.
    /// The caller remains responsible for keeping executor outputs private and
    /// rolling them back before calling this method.
    pub fn abortService(
        self: *Scheduler,
        permit: ServicePermitV1,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        const pending = try self.validatePendingService(permit);
        if (pending.commit_ticket != null) return Error.ServiceInFlight;
        try self.validateBank();
        try self.validateServiceBeforeState(permit);
        self.pending_service = null;
    }

    /// Release an active request without claiming its remaining work ran.
    pub fn cancel(self: *Scheduler, handle: Handle) Error!EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.finishHandle(handle, .cancel, .active);
    }

    /// Cancel an active lane whose scheduler-owned receipt is bound to one
    /// publication session. Closing the session and releasing its receipt is
    /// one Bank transition.
    pub fn cancelBoundPublication(
        self: *Scheduler,
        handle: Handle,
        request_epoch: u64,
        session_id: usize,
        expected_next_sequence: u64,
    ) Error!EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.finishBoundPublication(
            handle,
            .cancel,
            .active,
            request_epoch,
            session_id,
            expected_next_sequence,
        );
    }

    /// Release a finished request after downstream state is safe to discard.
    pub fn retire(self: *Scheduler, handle: Handle) Error!EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.finishHandle(handle, .retire, .finished);
    }

    /// Retire a finished lane and atomically close/release its bound
    /// publication session.
    pub fn retireBoundPublication(
        self: *Scheduler,
        handle: Handle,
        request_epoch: u64,
        session_id: usize,
        expected_next_sequence: u64,
    ) Error!EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.finishBoundPublication(
            handle,
            .retire,
            .finished,
            request_epoch,
            session_id,
            expected_next_sequence,
        );
    }

    /// Return a Bank-reconciled logical snapshot without advancing the chain.
    /// Pending service state is intentionally omitted, so prepare and abort are
    /// snapshot-invisible. Callers must retain the only permit authority until
    /// they consume it; losing every copy leaves logical mutators fail-closed.
    pub fn snapshot(self: *Scheduler) Error!SnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireUsable();
        try self.validateBank();
        const lane_counts = self.counts();
        return .{
            .scheduler_epoch = self.config.scheduler_epoch,
            .logical_tick = self.logical_tick,
            .next_event_sequence = self.next_event_sequence,
            .cursor = self.cursor,
            .level = self.level,
            .active = lane_counts.active,
            .finished = lane_counts.finished,
            .used = self.used,
            .maximum_service_gap = self.maximum_service_gap,
            .chain_head_sha256 = self.chain_head_sha256,
            .poisoned = self.poisoned,
            .closed = self.closed,
        };
    }

    /// Seal a fully drained scheduler with a terminal chain event.
    pub fn close(self: *Scheduler) Error!EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpen();
        try self.requireNoService();
        try self.validateBank();
        try self.preflightEvent();
        const lane_counts = self.counts();
        if (lane_counts.active != 0 or lane_counts.finished != 0 or
            !self.used.isZero())
            return Error.IncompleteDrain;

        const before_state = self.stateSha256();
        const before_used = self.used;
        const before_tick = self.logical_tick;
        const before_cursor = self.cursor;
        const before_level = self.level;
        self.closed = true;
        return self.emitCurrent(.{
            .kind = .close,
            .state_before_sha256 = before_state,
            .logical_tick_before = before_tick,
            .cursor_before = before_cursor,
            .level_before = before_level,
            .active_before = 0,
            .finished_before = 0,
            .bank_used_before = before_used,
        });
    }

    fn finishHandle(
        self: *Scheduler,
        handle: Handle,
        kind: EventKind,
        required_state: SlotState,
    ) Error!EventV1 {
        try self.requireOpen();
        try self.requireNoService();
        try self.validateBank();
        try self.preflightEvent();
        const index = try self.validateHandle(handle, required_state);
        const slot = &self.slots[index];
        if (slotPublicationBound(slot.*)) return Error.InvalidTransition;
        self.bank.validateCommitted(slot.receipt) catch return self.poisonBank();

        const before_state = self.stateSha256();
        const before_counts = self.counts();
        const before_used = self.used;
        const before_tick = self.logical_tick;
        const before_cursor = self.cursor;
        const before_level = self.level;
        const spec = slot.spec;
        const receipt = slot.receipt;
        const receipt_sha256 = slot.receipt_sha256;
        const remaining = slot.remaining_quanta;

        // Removing a runnable lane cannot make any survivor complete later;
        // the exhaustive cancellation property test freezes that IWRR rule.
        // Cancellation therefore avoids replaying an already-proved deadline
        // schedule while holding the mutex.
        self.bank.release(receipt) catch return self.poisonBank();
        self.used = subtractClaims(self.used, spec.claim) catch
            return self.poisonBank();
        slot.* = .{};

        return self.emitCurrent(.{
            .kind = kind,
            .state_before_sha256 = before_state,
            .logical_tick_before = before_tick,
            .cursor_before = before_cursor,
            .level_before = before_level,
            .handle = handle,
            .spec = spec,
            .resource_receipt = receipt,
            .resource_receipt_sha256 = receipt_sha256,
            .remaining_before = remaining,
            .active_before = before_counts.active,
            .finished_before = before_counts.finished,
            .bank_used_before = before_used,
        });
    }

    fn finishBoundPublication(
        self: *Scheduler,
        handle: Handle,
        kind: EventKind,
        required_state: SlotState,
        request_epoch: u64,
        session_id: usize,
        expected_next_sequence: u64,
    ) Error!EventV1 {
        if (request_epoch == 0 or session_id == 0)
            return Error.InvalidConfiguration;
        try self.requireOpen();
        try self.requireNoService();
        try self.validateBank();
        try self.preflightEvent();
        const index = try self.validateHandle(handle, required_state);
        const slot = &self.slots[index];
        if (!slotPublicationBindingValid(slot.*) or
            slot.publication_request_epoch != request_epoch or
            slot.publication_session_id != session_id)
            return Error.InvalidTransition;
        self.bank.validateCommitted(slot.receipt) catch
            return self.poisonBank();

        const before_state = self.stateSha256();
        const before_counts = self.counts();
        const before_used = self.used;
        const before_tick = self.logical_tick;
        const before_cursor = self.cursor;
        const before_level = self.level;
        const spec = slot.spec;
        const receipt = slot.receipt;
        const receipt_sha256 = slot.receipt_sha256;
        const remaining = slot.remaining_quanta;
        const next_used = subtractClaims(self.used, spec.claim) catch
            return self.poisonBank();

        self.bank.closePublicationSessionAndRelease(
            receipt,
            request_epoch,
            session_id,
            expected_next_sequence,
        ) catch |err| switch (err) {
            error.InvalidConfiguration => return Error.InvalidConfiguration,
            error.InvalidTransition => return Error.InvalidTransition,
            else => return self.poisonBank(),
        };
        self.used = next_used;
        slot.* = .{};

        return self.emitCurrent(.{
            .kind = kind,
            .state_before_sha256 = before_state,
            .logical_tick_before = before_tick,
            .cursor_before = before_cursor,
            .level_before = before_level,
            .handle = handle,
            .spec = spec,
            .resource_receipt = receipt,
            .resource_receipt_sha256 = receipt_sha256,
            .remaining_before = remaining,
            .active_before = before_counts.active,
            .finished_before = before_counts.finished,
            .bank_used_before = before_used,
        });
    }

    fn emitRejection(
        self: *Scheduler,
        spec: RequestSpec,
        reason: RejectionReason,
        before_state: Digest,
        before_counts: Counts,
        before_used: resource_bank.Claim,
        before_cursor: u32,
        before_level: u16,
        before_tick: u64,
    ) EventV1 {
        return self.emitCurrent(.{
            .kind = .admission_rejected,
            .rejection_reason = reason,
            .state_before_sha256 = before_state,
            .logical_tick_before = before_tick,
            .cursor_before = before_cursor,
            .level_before = before_level,
            .spec = spec,
            .active_before = before_counts.active,
            .finished_before = before_counts.finished,
            .bank_used_before = before_used,
        });
    }

    const EventSeed = struct {
        kind: EventKind,
        rejection_reason: RejectionReason = .none,
        state_before_sha256: Digest,
        logical_tick_before: u64,
        cursor_before: u32,
        level_before: u16,
        handle: Handle = .{},
        spec: RequestSpec = .{},
        resource_receipt: resource_bank.Receipt = zeroReceipt(),
        resource_receipt_sha256: Digest = zero_digest,
        remaining_before: u64 = 0,
        remaining_after: u64 = 0,
        wait_quanta: u64 = 0,
        active_before: u32,
        finished_before: u32,
        bank_used_before: resource_bank.Claim,
    };

    fn emitCurrent(self: *Scheduler, seed: EventSeed) EventV1 {
        const sequence = self.next_event_sequence;
        self.next_event_sequence += 1;
        const after_counts = self.counts();
        var event: EventV1 = .{
            .scheduler_epoch = self.config.scheduler_epoch,
            .event_sequence = sequence,
            .kind = seed.kind,
            .rejection_reason = seed.rejection_reason,
            .previous_sha256 = self.chain_head_sha256,
            .state_before_sha256 = seed.state_before_sha256,
            .state_after_sha256 = self.stateSha256(),
            .logical_tick_before = seed.logical_tick_before,
            .logical_tick_after = self.logical_tick,
            .cursor_before = seed.cursor_before,
            .cursor_after = self.cursor,
            .level_before = seed.level_before,
            .level_after = self.level,
            .handle = seed.handle,
            .spec = seed.spec,
            .resource_receipt = seed.resource_receipt,
            .resource_receipt_sha256 = seed.resource_receipt_sha256,
            .remaining_before = seed.remaining_before,
            .remaining_after = seed.remaining_after,
            .wait_quanta = seed.wait_quanta,
            .maximum_service_gap = self.maximum_service_gap,
            .active_before = seed.active_before,
            .active_after = after_counts.active,
            .finished_before = seed.finished_before,
            .finished_after = after_counts.finished,
            .bank_used_before = seed.bank_used_before,
            .bank_used_after = self.used,
        };
        event.event_sha256 = eventSha256(event);
        self.chain_head_sha256 = event.event_sha256;
        return event;
    }

    fn projectAdmission(
        self: *Scheduler,
        candidate_index: usize,
        candidate: RequestSpec,
    ) ProjectionOutcome {
        return projectAdmissionState(
            self.slots,
            self.projection,
            candidate_index,
            candidate,
            self.logical_tick,
            self.cursor,
            self.level,
            self.config,
        );
    }

    fn validateSpec(self: *const Scheduler, spec: RequestSpec) Error!void {
        return validateRequestSpec(self.config, self.logical_tick, spec);
    }

    fn validateHandle(
        self: *const Scheduler,
        handle: Handle,
        state: SlotState,
    ) Error!usize {
        if (handle.scheduler_epoch != self.config.scheduler_epoch or
            handle.slot_index >= self.slots.len)
            return Error.StaleHandle;
        const index: usize = handle.slot_index;
        const slot = self.slots[index];
        if (slot.state != state or slot.generation != handle.slot_generation or
            slot.spec.tenant_key != handle.tenant_key or
            slot.spec.request_key != handle.request_key or
            slot.spec.request_generation != handle.request_generation)
            return Error.StaleHandle;
        return index;
    }

    fn validatePendingService(
        self: *Scheduler,
        permit: ServicePermitV1,
    ) Error!PendingService {
        const pending = self.pending_service orelse
            return Error.StaleServicePermit;
        if (!std.mem.eql(
            u8,
            &pending.permit.permit_sha256,
            &servicePermitSha256(pending.permit),
        )) return self.poisonInvariant();
        if (permit.abi_version != service_permit_abi or
            permit.scheduler_epoch != self.config.scheduler_epoch or
            permit.coordinator_id != self.service_coordinator_id or
            permit.coordinator_address !=
                @as(u64, @intCast(@intFromPtr(self))) or
            permit.permit_generation == 0 or
            !std.mem.eql(
                u8,
                &permit.permit_sha256,
                &servicePermitSha256(permit),
            ) or !std.meta.eql(permit, pending.permit))
            return Error.StaleServicePermit;
        return pending;
    }

    fn validateServiceCommitTicket(
        self: *Scheduler,
        ticket: ServiceCommitTicketV1,
    ) Error!PendingService {
        const pending = self.pending_service orelse
            return Error.StaleServiceCommitTicket;
        if (!std.mem.eql(
            u8,
            &pending.permit.permit_sha256,
            &servicePermitSha256(pending.permit),
        )) return self.poisonInvariant();
        const authoritative = pending.commit_ticket orelse
            return Error.StaleServiceCommitTicket;
        if (!std.mem.eql(
            u8,
            &authoritative.ticket_sha256,
            &serviceCommitTicketSha256(authoritative),
        )) return self.poisonInvariant();
        if (ticket.abi_version != service_commit_ticket_abi or
            ticket.scheduler_epoch != self.config.scheduler_epoch or
            ticket.coordinator_id != self.service_coordinator_id or
            ticket.coordinator_address !=
                @as(u64, @intCast(@intFromPtr(self))) or
            ticket.permit_generation != pending.permit.permit_generation or
            !std.mem.eql(
                u8,
                &ticket.permit_sha256,
                &pending.permit.permit_sha256,
            ) or ticket.commit_generation == 0 or
            !std.mem.eql(
                u8,
                &ticket.ticket_sha256,
                &serviceCommitTicketSha256(ticket),
            ) or !std.meta.eql(ticket, authoritative))
            return Error.StaleServiceCommitTicket;
        return pending;
    }

    fn validateServiceBeforeState(
        self: *Scheduler,
        permit: ServicePermitV1,
    ) Error!void {
        if (!std.mem.eql(
            u8,
            &permit.state_before_sha256,
            &self.stateSha256(),
        ) or permit.event_sequence != self.next_event_sequence or
            permit.logical_tick_before != self.logical_tick or
            !std.mem.eql(
                u8,
                &permit.chain_head_before_sha256,
                &self.chain_head_sha256,
            )) return self.poisonInvariant();
    }

    fn validateServiceCommitLocked(
        self: *Scheduler,
        permit: ServicePermitV1,
    ) Error!ServiceCommitContext {
        try self.validateBank();
        try self.preflightEvent();
        try self.validateServiceBeforeState(permit);

        const selection = selectIWRR(
            self.slots,
            self.cursor,
            self.level,
            self.config.max_weight,
        ) orelse return self.poisonInvariant();
        if (selection.slot_index != permit.handle.slot_index or
            selection.cursor_after != permit.cursor_after or
            selection.level_after != permit.level_after)
            return self.poisonInvariant();
        const index = self.validateHandle(permit.handle, .active) catch
            return self.poisonInvariant();
        const slot = &self.slots[index];
        if (!std.meta.eql(slot.receipt, permit.resource_receipt) or
            !std.mem.eql(
                u8,
                &slot.receipt_sha256,
                &permit.resource_receipt_sha256,
            ) or slot.remaining_quanta != permit.remaining_before)
            return self.poisonInvariant();
        self.bank.validateCommitted(slot.receipt) catch
            return self.poisonBank();
        if (slot.service_count == std.math.maxInt(u64) or
            self.logical_tick == std.math.maxInt(u64))
            return self.poisonInvariant();

        const after_tick = self.logical_tick + 1;
        const wait_quanta = after_tick - slot.last_service_tick;
        if (!selectionPreservesDeadlines(self.slots, index, after_tick) or
            wait_quanta != permit.wait_quanta or
            wait_quanta > self.maximum_service_gap)
            return self.poisonInvariant();
        return .{
            .selection = selection,
            .index = index,
            .after_tick = after_tick,
            .wait_quanta = wait_quanta,
        };
    }

    fn serviceIntentFor(
        self: *const Scheduler,
        permit: ServicePermitV1,
        index: usize,
    ) ServiceIntentV1 {
        var intent: ServiceIntentV1 = .{
            .scheduler_epoch = permit.scheduler_epoch,
            .event_sequence = permit.event_sequence,
            .handle = permit.handle,
            .spec = self.slots[index].spec,
            .logical_tick_before = permit.logical_tick_before,
            .cursor_before = permit.cursor_before,
            .level_before = permit.level_before,
            .cursor_after = permit.cursor_after,
            .level_after = permit.level_after,
            .remaining_before = permit.remaining_before,
            .wait_quanta = permit.wait_quanta,
            .maximum_service_gap = permit.maximum_service_gap,
            .state_before_sha256 = permit.state_before_sha256,
            .chain_head_before_sha256 = permit.chain_head_before_sha256,
            .resource_receipt = permit.resource_receipt,
            .resource_receipt_sha256 = permit.resource_receipt_sha256,
        };
        intent.intent_sha256 = serviceIntentSha256(intent);
        return intent;
    }

    fn commitServiceLocked(
        self: *Scheduler,
        permit: ServicePermitV1,
        context: ServiceCommitContext,
        finalizer: ?ServiceFinalizerV1,
    ) EventV1 {
        const slot = &self.slots[context.index];
        const before_state = self.stateSha256();
        const before_counts = self.counts();
        const before_used = self.used;
        const before_tick = self.logical_tick;
        const before_cursor = self.cursor;
        const before_level = self.level;
        const handle = self.handleFor(context.index);
        const spec = slot.spec;
        const receipt = slot.receipt;
        const receipt_sha256 = slot.receipt_sha256;

        self.pending_service = null;
        slot.remaining_quanta -= 1;
        slot.last_service_tick = context.after_tick;
        slot.service_count += 1;
        if (slot.remaining_quanta == 0) slot.state = .finished;
        self.logical_tick = context.after_tick;
        self.cursor = context.selection.cursor_after;
        self.level = context.selection.level_after;

        const event = self.emitCurrent(.{
            .kind = .service,
            .state_before_sha256 = before_state,
            .logical_tick_before = before_tick,
            .cursor_before = before_cursor,
            .level_before = before_level,
            .handle = handle,
            .spec = spec,
            .resource_receipt = receipt,
            .resource_receipt_sha256 = receipt_sha256,
            .remaining_before = permit.remaining_before,
            .remaining_after = slot.remaining_quanta,
            .wait_quanta = context.wait_quanta,
            .active_before = before_counts.active,
            .finished_before = before_counts.finished,
            .bank_used_before = before_used,
        });
        if (finalizer) |value| value.finalize(value.context, &event);
        return event;
    }

    fn handleFor(self: *const Scheduler, index: usize) Handle {
        const slot = self.slots[index];
        return .{
            .scheduler_epoch = self.config.scheduler_epoch,
            .slot_index = @intCast(index),
            .slot_generation = slot.generation,
            .tenant_key = slot.spec.tenant_key,
            .request_key = slot.spec.request_key,
            .request_generation = slot.spec.request_generation,
        };
    }

    fn validateBank(self: *Scheduler) Error!void {
        const bank_snapshot = self.bank.snapshot() catch return self.poisonBank();
        const occupied = self.counts();
        const expected_receipts = std.math.add(
            u32,
            occupied.active,
            occupied.finished,
        ) catch return self.poisonBank();
        if (bank_snapshot.bank_epoch != self.bank_epoch or
            !std.meta.eql(bank_snapshot.limits, self.limits) or
            !std.meta.eql(bank_snapshot.used, self.used) or
            bank_snapshot.active_reservations != 0 or
            bank_snapshot.committed_receipts != expected_receipts)
            return self.poisonBank();
    }

    fn poisonBank(self: *Scheduler) Error {
        self.poisoned = true;
        return Error.BankDrift;
    }

    fn poisonInvariant(self: *Scheduler) Error {
        self.poisoned = true;
        return Error.InvariantViolation;
    }

    fn requireUsable(self: *const Scheduler) Error!void {
        if (self.poisoned) return Error.SchedulerPoisoned;
    }

    fn requireOpen(self: *const Scheduler) Error!void {
        try self.requireUsable();
        if (self.closed) return Error.SchedulerClosed;
    }

    fn requireNoService(self: *const Scheduler) Error!void {
        if (self.pending_service != null) return Error.ServiceInFlight;
    }

    fn preflightEvent(self: *const Scheduler) Error!void {
        if (self.next_event_sequence == std.math.maxInt(u64))
            return Error.SequenceOverflow;
    }

    fn counts(self: *const Scheduler) Counts {
        return countSlots(self.slots);
    }

    fn stateSha256(self: *const Scheduler) Digest {
        return schedulerStateSha256(
            self.config,
            self.logical_tick,
            self.next_event_sequence,
            self.next_slot_generation,
            self.cursor,
            self.level,
            self.poisoned,
            self.closed,
            self.used,
            self.slots,
        );
    }
};

/// Stateful model-free verifier. The challenge, Bank epoch and limits are
/// trusted out-of-band inputs; events are never allowed to choose them.
pub const Verifier = struct {
    slots: []Slot,
    projection: []ProjectionSlot,
    config: Config,
    bank_epoch: u64,
    limits: resource_bank.Limits,
    used: resource_bank.Claim = .{},
    logical_tick: u64 = 0,
    next_event_sequence: u64 = 0,
    next_slot_generation: u64 = 1,
    cursor: u32 = 0,
    level: u16 = 1,
    maximum_service_gap: u64,
    chain_head_sha256: Digest,
    poisoned: bool = false,
    closed: bool = false,

    pub fn init(
        storage: Storage,
        config: Config,
        bank_epoch: u64,
        limits: resource_bank.Limits,
    ) Error!Verifier {
        if (storage.slots.len == 0 or
            storage.slots.len != storage.projection.len or
            storage.slots.len > std.math.maxInt(u32) or bank_epoch == 0 or
            config.scheduler_epoch == 0 or config.max_weight == 0 or
            config.max_projection_quanta == 0 or
            config.max_projection_operations == 0 or
            std.mem.eql(u8, &config.challenge, &zero_digest))
            return Error.InvalidConfiguration;
        const weighted = std.math.mul(
            u64,
            @intCast(storage.slots.len - 1),
            config.max_weight,
        ) catch return Error.InvalidConfiguration;
        const gap = std.math.add(u64, weighted, 1) catch
            return Error.InvalidConfiguration;
        for (storage.slots) |*slot| slot.* = .{};
        for (storage.projection) |*slot| slot.* = .{};
        return .{
            .slots = storage.slots,
            .projection = storage.projection,
            .config = config,
            .bank_epoch = bank_epoch,
            .limits = limits,
            .maximum_service_gap = gap,
            .chain_head_sha256 = initialRoot(
                config,
                @intCast(storage.slots.len),
                bank_epoch,
                limits,
                gap,
            ),
        };
    }

    /// Apply one event and deterministically reconstruct the scheduler state
    /// in a second instance using the same versioned policy contract.
    /// Any rejection poisons this verifier instance; discard it after error.
    pub fn apply(self: *Verifier, event: EventV1) Error!void {
        if (self.poisoned or self.closed) return Error.InvalidEvent;
        if (event.abi_version != event_abi or
            event.scheduler_epoch != self.config.scheduler_epoch or
            event.event_sequence != self.next_event_sequence or
            event.maximum_service_gap != self.maximum_service_gap or
            !std.mem.eql(u8, &event.previous_sha256, &self.chain_head_sha256) or
            !std.mem.eql(u8, &event.event_sha256, &eventSha256(event)))
            return self.rejectEvent();

        const before_state = self.stateSha256();
        const before_counts = countSlots(self.slots);
        if (!std.mem.eql(u8, &event.state_before_sha256, &before_state) or
            event.logical_tick_before != self.logical_tick or
            event.cursor_before != self.cursor or event.level_before != self.level or
            event.active_before != before_counts.active or
            event.finished_before != before_counts.finished or
            !std.meta.eql(event.bank_used_before, self.used))
            return self.rejectEvent();

        switch (event.kind) {
            .admission_accepted => try self.applyAdmission(event, true),
            .admission_rejected => try self.applyAdmission(event, false),
            .service => try self.applyService(event),
            .cancel => try self.applyFinish(event, .active),
            .retire => try self.applyFinish(event, .finished),
            .close => try self.applyClose(event),
        }

        self.next_event_sequence = std.math.add(
            u64,
            self.next_event_sequence,
            1,
        ) catch return self.rejectEvent();
        const after_counts = countSlots(self.slots);
        const after_state = self.stateSha256();
        if (event.logical_tick_after != self.logical_tick or
            event.cursor_after != self.cursor or event.level_after != self.level or
            event.active_after != after_counts.active or
            event.finished_after != after_counts.finished or
            !std.meta.eql(event.bank_used_after, self.used) or
            !std.mem.eql(u8, &event.state_after_sha256, &after_state))
            return self.rejectEvent();

        self.chain_head_sha256 = event.event_sha256;
    }

    /// Require the terminal close record and optionally an externally retained
    /// final chain head. This rejects a valid but truncated prefix.
    pub fn finish(self: *Verifier, expected_head: ?Digest) Error!Digest {
        if (self.poisoned or !self.closed or !self.used.isZero() or
            countSlots(self.slots).active != 0 or
            countSlots(self.slots).finished != 0)
            return Error.InvalidEvent;
        if (expected_head) |head| {
            if (!std.mem.eql(u8, &head, &self.chain_head_sha256))
                return Error.InvalidEvent;
        }
        return self.chain_head_sha256;
    }

    fn applyAdmission(
        self: *Verifier,
        event: EventV1,
        accepted: bool,
    ) Error!void {
        validateRequestSpec(self.config, self.logical_tick, event.spec) catch
            return self.rejectEvent();
        const outcome = self.admissionOutcome(event.spec);
        if (accepted) {
            if (outcome.reason != .none or event.rejection_reason != .none or
                event.remaining_before != 0 or
                event.remaining_after != event.spec.work_quanta or
                event.wait_quanta != 0 or
                self.next_slot_generation == std.math.maxInt(u64))
                return self.rejectEvent();
            const index = outcome.slot_index.?;
            const expected_handle: Handle = .{
                .scheduler_epoch = self.config.scheduler_epoch,
                .slot_index = @intCast(index),
                .slot_generation = self.next_slot_generation,
                .tenant_key = event.spec.tenant_key,
                .request_key = event.spec.request_key,
                .request_generation = event.spec.request_generation,
            };
            if (!std.meta.eql(event.handle, expected_handle) or
                event.resource_receipt.bank_epoch != self.bank_epoch or
                event.resource_receipt.slot_index != index or
                event.resource_receipt.generation != self.next_slot_generation or
                event.resource_receipt.owner_key != event.spec.resource_owner_key or
                !std.meta.eql(event.resource_receipt.claim, event.spec.claim) or
                !resource_bank.receiptIntegrityValidV1(event.resource_receipt) or
                !std.mem.eql(
                    u8,
                    &event.resource_receipt_sha256,
                    &resourceReceiptSha256(event.resource_receipt),
                ))
                return self.rejectEvent();
            self.slots[index] = .{
                .state = .active,
                .generation = self.next_slot_generation,
                .spec = event.spec,
                .remaining_quanta = event.spec.work_quanta,
                .admitted_tick = self.logical_tick,
                .last_service_tick = self.logical_tick,
                .receipt = event.resource_receipt,
                .receipt_sha256 = event.resource_receipt_sha256,
            };
            self.next_slot_generation += 1;
            self.used = outcome.next_used;
        } else {
            if (outcome.reason == .none or event.rejection_reason != outcome.reason or
                !std.meta.eql(event.handle, Handle{}) or
                !std.meta.eql(event.resource_receipt, zeroReceipt()) or
                !std.mem.eql(u8, &event.resource_receipt_sha256, &zero_digest) or
                event.remaining_before != 0 or event.remaining_after != 0 or
                event.wait_quanta != 0)
                return self.rejectEvent();
        }
    }

    const AdmissionOutcome = struct {
        reason: RejectionReason,
        slot_index: ?usize = null,
        next_used: resource_bank.Claim = .{},
    };

    fn admissionOutcome(
        self: *Verifier,
        spec: RequestSpec,
    ) AdmissionOutcome {
        var free_index: ?usize = null;
        for (self.slots, 0..) |slot, index| {
            if (slot.state != .free and slot.spec.tenant_key == spec.tenant_key)
                return .{ .reason = .duplicate_tenant };
            if (slot.state == .free and free_index == null) free_index = index;
        }
        const index = free_index orelse return .{ .reason = .no_slot };
        const next_used = addClaims(self.used, spec.claim) catch
            return .{ .reason = .resource_limit };
        const fits = self.limits.fits(next_used) catch false;
        if (!fits) return .{ .reason = .resource_limit };
        const projection = projectAdmissionState(
            self.slots,
            self.projection,
            index,
            spec,
            self.logical_tick,
            self.cursor,
            self.level,
            self.config,
        );
        return switch (projection) {
            .feasible => .{
                .reason = .none,
                .slot_index = index,
                .next_used = next_used,
            },
            .projection_limit => .{ .reason = .projection_limit },
            .deadline_infeasible => .{ .reason = .deadline_infeasible },
        };
    }

    fn applyService(self: *Verifier, event: EventV1) Error!void {
        const selection = selectIWRR(
            self.slots,
            self.cursor,
            self.level,
            self.config.max_weight,
        ) orelse return self.rejectEvent();
        const slot = &self.slots[selection.slot_index];
        const expected_handle = handleFromSlot(
            self.config.scheduler_epoch,
            selection.slot_index,
            slot.*,
        );
        const after_tick = std.math.add(u64, self.logical_tick, 1) catch
            return self.rejectEvent();
        const wait = after_tick - slot.last_service_tick;
        if (!selectionPreservesDeadlines(
            self.slots,
            selection.slot_index,
            after_tick,
        )) return self.rejectEvent();
        if (event.rejection_reason != .none or
            !std.meta.eql(event.handle, expected_handle) or
            !std.meta.eql(event.spec, slot.spec) or
            !std.meta.eql(event.resource_receipt, slot.receipt) or
            !std.mem.eql(u8, &event.resource_receipt_sha256, &slot.receipt_sha256) or
            event.remaining_before != slot.remaining_quanta or
            event.remaining_after != slot.remaining_quanta - 1 or
            event.wait_quanta != wait or wait > self.maximum_service_gap)
            return self.rejectEvent();
        slot.remaining_quanta -= 1;
        slot.last_service_tick = after_tick;
        slot.service_count = std.math.add(u64, slot.service_count, 1) catch
            return self.rejectEvent();
        if (slot.remaining_quanta == 0) slot.state = .finished;
        self.logical_tick = after_tick;
        self.cursor = selection.cursor_after;
        self.level = selection.level_after;
    }

    fn applyFinish(
        self: *Verifier,
        event: EventV1,
        required_state: SlotState,
    ) Error!void {
        if (event.handle.scheduler_epoch != self.config.scheduler_epoch or
            event.handle.slot_index >= self.slots.len)
            return self.rejectEvent();
        const index: usize = event.handle.slot_index;
        const slot = &self.slots[index];
        const expected_handle = handleFromSlot(
            self.config.scheduler_epoch,
            index,
            slot.*,
        );
        if (slot.state != required_state or event.rejection_reason != .none or
            !std.meta.eql(event.handle, expected_handle) or
            !std.meta.eql(event.spec, slot.spec) or
            !std.meta.eql(event.resource_receipt, slot.receipt) or
            !std.mem.eql(u8, &event.resource_receipt_sha256, &slot.receipt_sha256) or
            event.remaining_before != slot.remaining_quanta or
            event.remaining_after != 0 or event.wait_quanta != 0)
            return self.rejectEvent();
        self.used = subtractClaims(self.used, slot.spec.claim) catch
            return self.rejectEvent();
        slot.* = .{};
    }

    fn applyClose(self: *Verifier, event: EventV1) Error!void {
        const counts = countSlots(self.slots);
        if (counts.active != 0 or counts.finished != 0 or !self.used.isZero() or
            event.rejection_reason != .none or
            !std.meta.eql(event.handle, Handle{}) or
            !std.meta.eql(event.spec, RequestSpec{}) or
            !std.meta.eql(event.resource_receipt, zeroReceipt()) or
            !std.mem.eql(u8, &event.resource_receipt_sha256, &zero_digest) or
            event.remaining_before != 0 or event.remaining_after != 0 or
            event.wait_quanta != 0)
            return self.rejectEvent();
        self.closed = true;
    }

    fn rejectEvent(self: *Verifier) Error {
        self.poisoned = true;
        return Error.InvalidEvent;
    }

    fn stateSha256(self: *const Verifier) Digest {
        return schedulerStateSha256(
            self.config,
            self.logical_tick,
            self.next_event_sequence,
            self.next_slot_generation,
            self.cursor,
            self.level,
            self.poisoned,
            self.closed,
            self.used,
            self.slots,
        );
    }
};

fn validateRequestSpec(
    config: Config,
    logical_tick: u64,
    spec: RequestSpec,
) Error!void {
    if (spec.tenant_key == 0 or spec.request_key == 0 or
        spec.request_generation == 0 or spec.resource_owner_key == 0 or
        spec.weight == 0 or spec.weight > config.max_weight or
        spec.work_quanta == 0 or spec.claim.isZero() or
        spec.claim.queue_slots != 1 or
        (spec.deadline_tick != 0 and spec.deadline_tick <= logical_tick))
        return Error.InvalidRequest;
    _ = spec.claim.hostBytes() catch return Error.InvalidRequest;
}

fn projectAdmissionState(
    slots: []const Slot,
    projection: []ProjectionSlot,
    candidate_index: usize,
    candidate: RequestSpec,
    logical_tick: u64,
    initial_cursor: u32,
    initial_level: u16,
    config: Config,
) ProjectionOutcome {
    var budget: ProjectionBudget = .{
        .remaining = config.max_projection_operations,
    };
    if (candidate.deadline_tick != 0 and
        candidate.work_quanta > config.max_projection_quanta)
        return .projection_limit;
    if (candidate.deadline_tick == 0) {
        if (!budget.spend(slots.len)) return .projection_limit;
        var has_existing_deadline = false;
        for (slots) |slot| {
            if (slot.state == .active and slot.spec.deadline_tick != 0) {
                has_existing_deadline = true;
                break;
            }
        }
        if (!has_existing_deadline) return .feasible;
    }
    if (!budget.spend(slots.len)) return .projection_limit;
    var deadline_count: usize = 0;
    var minimum_deadline_quanta: u64 = 0;
    for (slots, 0..) |slot, index| {
        const projected = &projection[index];
        if (slot.state == .active) {
            projected.* = .{
                .active = true,
                .weight = slot.spec.weight,
                .remaining_quanta = slot.remaining_quanta,
                .deadline_tick = slot.spec.deadline_tick,
            };
            if (slot.spec.deadline_tick != 0) {
                deadline_count += 1;
                minimum_deadline_quanta = std.math.add(
                    u64,
                    minimum_deadline_quanta,
                    slot.remaining_quanta,
                ) catch return .projection_limit;
            }
        } else {
            projected.* = .{};
        }
    }
    projection[candidate_index] = .{
        .active = true,
        .weight = candidate.weight,
        .remaining_quanta = candidate.work_quanta,
        .deadline_tick = candidate.deadline_tick,
    };
    if (candidate.deadline_tick != 0) {
        deadline_count += 1;
        minimum_deadline_quanta = std.math.add(
            u64,
            minimum_deadline_quanta,
            candidate.work_quanta,
        ) catch return .projection_limit;
    }
    if (minimum_deadline_quanta > config.max_projection_quanta)
        return .projection_limit;

    return projectPreparedState(
        projection,
        deadline_count,
        logical_tick,
        initial_cursor,
        initial_level,
        config,
        &budget,
    );
}

fn projectPreparedState(
    projection: []ProjectionSlot,
    initial_deadline_count: usize,
    logical_tick: u64,
    initial_cursor: u32,
    initial_level: u16,
    config: Config,
    budget: *ProjectionBudget,
) ProjectionOutcome {
    if (initial_deadline_count == 0) return .feasible;

    var tick = logical_tick;
    var cursor = initial_cursor;
    var level = initial_level;
    var projected_quanta: u64 = 0;
    var deadline_count = initial_deadline_count;
    while (deadline_count != 0) {
        if (projected_quanta >= config.max_projection_quanta)
            return .projection_limit;
        if (!budget.spend(projection.len)) return .projection_limit;
        for (projection) |slot| {
            if (slot.active and slot.deadline_tick != 0 and
                tick >= slot.deadline_tick)
                return .deadline_infeasible;
        }
        const selection = selectIWRRWithBudget(
            projection,
            cursor,
            level,
            config.max_weight,
            budget,
        ) orelse return if (budget.exhausted)
            .projection_limit
        else
            .deadline_infeasible;
        const projected = &projection[selection.slot_index];
        projected.remaining_quanta -= 1;
        tick = std.math.add(u64, tick, 1) catch
            return .deadline_infeasible;
        projected_quanta += 1;
        if (projected.remaining_quanta == 0) {
            if (projected.deadline_tick != 0 and tick > projected.deadline_tick)
                return .deadline_infeasible;
            if (projected.deadline_tick != 0) deadline_count -= 1;
            projected.active = false;
        }
        cursor = selection.cursor_after;
        level = selection.level_after;
    }
    return .feasible;
}

fn projectAfterRemoval(
    slots: []const Slot,
    projection: []ProjectionSlot,
    removed_index: usize,
    logical_tick: u64,
    initial_cursor: u32,
    initial_level: u16,
    config: Config,
) ProjectionOutcome {
    var budget: ProjectionBudget = .{
        .remaining = config.max_projection_operations,
    };
    if (!budget.spend(slots.len)) return .projection_limit;
    var deadline_count: usize = 0;
    var minimum_deadline_quanta: u64 = 0;
    for (slots, 0..) |slot, index| {
        const projected = &projection[index];
        if (index != removed_index and slot.state == .active) {
            projected.* = .{
                .active = true,
                .weight = slot.spec.weight,
                .remaining_quanta = slot.remaining_quanta,
                .deadline_tick = slot.spec.deadline_tick,
            };
            if (slot.spec.deadline_tick != 0) {
                deadline_count += 1;
                minimum_deadline_quanta = std.math.add(
                    u64,
                    minimum_deadline_quanta,
                    slot.remaining_quanta,
                ) catch return .projection_limit;
            }
        } else {
            projected.* = .{};
        }
    }
    if (minimum_deadline_quanta > config.max_projection_quanta)
        return .projection_limit;
    return projectPreparedState(
        projection,
        deadline_count,
        logical_tick,
        initial_cursor,
        initial_level,
        config,
        &budget,
    );
}

fn selectionPreservesDeadlines(
    slots: []const Slot,
    selected_index: usize,
    logical_tick_after: u64,
) bool {
    for (slots, 0..) |slot, index| {
        if (slot.state != .active or slot.spec.deadline_tick == 0) continue;
        const completes = index == selected_index and slot.remaining_quanta == 1;
        if (completes) {
            if (logical_tick_after > slot.spec.deadline_tick) return false;
        } else if (logical_tick_after >= slot.spec.deadline_tick) {
            return false;
        }
    }
    return true;
}

fn countSlots(slots: []const Slot) Counts {
    var result: Counts = .{ .active = 0, .finished = 0 };
    for (slots) |slot| switch (slot.state) {
        .free => {},
        .active => result.active += 1,
        .finished => result.finished += 1,
    };
    return result;
}

fn handleFromSlot(scheduler_epoch: u64, index: usize, slot: Slot) Handle {
    return .{
        .scheduler_epoch = scheduler_epoch,
        .slot_index = @intCast(index),
        .slot_generation = slot.generation,
        .tenant_key = slot.spec.tenant_key,
        .request_key = slot.spec.request_key,
        .request_generation = slot.spec.request_generation,
    };
}

fn slotPublicationBound(slot: Slot) bool {
    return slot.publication_request_epoch != 0 or
        slot.publication_session_id != 0 or
        slot.publication_service_policy != .none;
}

fn slotPublicationBindingValid(slot: Slot) bool {
    return slot.publication_request_epoch != 0 and
        slot.publication_session_id != 0 and
        slot.publication_service_policy != .none;
}

fn serviceRequiresBoundFinalizerV2(slot: Slot) bool {
    if (!slotPublicationBound(slot)) return false;
    return switch (slot.publication_service_policy) {
        .none => true,
        .every_service => true,
        .final_service => slot.remaining_quanta == 1,
    };
}

fn schedulerStateSha256(
    config: Config,
    logical_tick: u64,
    next_event_sequence: u64,
    next_slot_generation: u64,
    cursor: u32,
    level: u16,
    poisoned: bool,
    closed: bool,
    used: resource_bank.Claim,
    slots: []const Slot,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane-weave-qos-state-v1\x00");
    hashU64(&hash, config.scheduler_epoch);
    hashU64(&hash, logical_tick);
    hashU64(&hash, next_event_sequence);
    hashU64(&hash, next_slot_generation);
    hashU32(&hash, cursor);
    hashU16(&hash, level);
    hashBool(&hash, poisoned);
    hashBool(&hash, closed);
    hashClaim(&hash, used);
    hashU32(&hash, @intCast(slots.len));
    for (slots) |slot| hashSlot(&hash, slot);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn selectIWRR(
    slots: anytype,
    initial_cursor: u32,
    initial_level: u16,
    configured_max_weight: u16,
) ?Selection {
    return selectIWRRWithBudget(
        slots,
        initial_cursor,
        initial_level,
        configured_max_weight,
        null,
    );
}

fn selectIWRRWithBudget(
    slots: anytype,
    initial_cursor: u32,
    initial_level: u16,
    configured_max_weight: u16,
    budget: ?*ProjectionBudget,
) ?Selection {
    if (slots.len == 0) return null;
    if (budget) |projection_budget|
        if (!projection_budget.spend(slots.len)) return null;
    var max_active_weight: u16 = 0;
    for (slots) |slot| {
        if (slotActive(slot))
            max_active_weight = @max(max_active_weight, slotWeight(slot));
    }
    if (max_active_weight == 0) return null;

    var cursor: usize = @min(@as(usize, initial_cursor), slots.len);
    var level = if (initial_level == 0) @as(u16, 1) else initial_level;
    if (level > max_active_weight or level > configured_max_weight) {
        // The previous level ceased to exist when a heavier lane completed or
        // was cancelled. This is a new IWRR round, so both axes restart. Keeping
        // the old cursor would skip low-weight slots and invalidate the service
        // gap and any deadline projection made before the lifecycle change.
        level = 1;
        cursor = 0;
    }

    const scan_limit = iwrrScanLimit(
        slots.len,
        configured_max_weight,
    ) orelse return null;
    var scanned: u64 = 0;
    while (scanned < scan_limit) : (scanned += 1) {
        if (budget) |projection_budget|
            if (!projection_budget.spend(1)) return null;
        if (cursor >= slots.len) {
            cursor = 0;
            level = if (level >= max_active_weight) 1 else level + 1;
        }
        const index = cursor;
        cursor += 1;
        const slot = slots[index];
        if (slotActive(slot) and slotWeight(slot) >= level) {
            return .{
                .slot_index = index,
                .cursor_after = @intCast(cursor),
                .level_after = level,
            };
        }
    }
    return null;
}

fn iwrrScanLimit(slot_count: usize, configured_max_weight: u16) ?u64 {
    const count = std.math.cast(u64, slot_count) orelse return null;
    return std.math.mul(u64, count, configured_max_weight) catch null;
}

fn slotActive(slot: anytype) bool {
    const T = @TypeOf(slot);
    if (@hasField(T, "state")) return slot.state == .active;
    return slot.active;
}

fn slotWeight(slot: anytype) u16 {
    const T = @TypeOf(slot);
    if (@hasField(T, "state")) return slot.spec.weight;
    return slot.weight;
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

fn addClaims(a: resource_bank.Claim, b: resource_bank.Claim) Error!resource_bank.Claim {
    var result: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        @field(result, field.name) = std.math.add(
            u64,
            @field(a, field.name),
            @field(b, field.name),
        ) catch return Error.ClaimOverflow;
    }
    return result;
}

fn subtractClaims(
    a: resource_bank.Claim,
    b: resource_bank.Claim,
) Error!resource_bank.Claim {
    var result: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        @field(result, field.name) = std.math.sub(
            u64,
            @field(a, field.name),
            @field(b, field.name),
        ) catch return Error.BankDrift;
    }
    return result;
}

/// Recompute the process-local service capability digest. A monotonic lifetime
/// identity fences same-address reinitialization while the coordinator address
/// rejects a moved or copied live Scheduler. This digest is an integrity fence,
/// not authentication or durable evidence.
pub fn servicePermitSha256(permit: ServicePermitV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(service_permit_domain);
    hashU64(&hash, permit.abi_version);
    hashU64(&hash, permit.scheduler_epoch);
    hashU64(&hash, permit.coordinator_id);
    hashU64(&hash, permit.coordinator_address);
    hashU64(&hash, permit.permit_generation);
    hashU64(&hash, permit.event_sequence);
    hashHandle(&hash, permit.handle);
    hashU64(&hash, permit.logical_tick_before);
    hashU32(&hash, permit.cursor_before);
    hashU16(&hash, permit.level_before);
    hashU32(&hash, permit.cursor_after);
    hashU16(&hash, permit.level_after);
    hashU64(&hash, permit.remaining_before);
    hashU64(&hash, permit.wait_quanta);
    hashU64(&hash, permit.maximum_service_gap);
    hash.update(&permit.state_before_sha256);
    hash.update(&permit.chain_head_before_sha256);
    hashReceipt(&hash, permit.resource_receipt);
    hash.update(&permit.resource_receipt_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Recompute the portable, idempotent logical-service intent digest.
pub fn serviceIntentSha256(intent: ServiceIntentV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(service_intent_domain);
    hashU64(&hash, intent.abi_version);
    hashU64(&hash, intent.lane_weave_abi);
    hashU64(&hash, intent.event_abi_version);
    hashU64(&hash, intent.source_permit_abi);
    hashU64(&hash, intent.resource_bank_abi_version);
    hashU64(&hash, intent.scheduler_epoch);
    hashU64(&hash, intent.event_sequence);
    hashHandle(&hash, intent.handle);
    hashSpec(&hash, intent.spec);
    hashU64(&hash, intent.logical_tick_before);
    hashU32(&hash, intent.cursor_before);
    hashU16(&hash, intent.level_before);
    hashU32(&hash, intent.cursor_after);
    hashU16(&hash, intent.level_after);
    hashU64(&hash, intent.remaining_before);
    hashU64(&hash, intent.wait_quanta);
    hashU64(&hash, intent.maximum_service_gap);
    hash.update(&intent.state_before_sha256);
    hash.update(&intent.chain_head_before_sha256);
    hashReceipt(&hash, intent.resource_receipt);
    hash.update(&intent.resource_receipt_sha256);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Validate the portable intent's canonical shape without consulting live
/// Scheduler or Bank state.
pub fn serviceIntentValidV1(intent: ServiceIntentV1) bool {
    _ = intent.spec.claim.hostBytes() catch return false;
    return intent.abi_version == service_intent_abi and
        intent.lane_weave_abi == abi and
        intent.event_abi_version == event_abi and
        intent.source_permit_abi == service_permit_abi and
        intent.resource_bank_abi_version == resource_bank.abi and
        intent.scheduler_epoch != 0 and
        intent.event_sequence != std.math.maxInt(u64) and
        intent.handle.scheduler_epoch == intent.scheduler_epoch and
        intent.handle.slot_generation != 0 and
        intent.handle.tenant_key != 0 and
        intent.handle.request_key != 0 and
        intent.handle.request_generation != 0 and
        intent.handle.tenant_key == intent.spec.tenant_key and
        intent.handle.request_key == intent.spec.request_key and
        intent.handle.request_generation == intent.spec.request_generation and
        intent.spec.resource_owner_key != 0 and
        intent.spec.resource_owner_key == intent.resource_receipt.owner_key and
        std.meta.eql(intent.spec.claim, intent.resource_receipt.claim) and
        intent.spec.weight != 0 and intent.spec.work_quanta != 0 and
        intent.spec.claim.queue_slots == 1 and
        (intent.spec.deadline_tick == 0 or
            intent.spec.deadline_tick > intent.logical_tick_before) and
        intent.remaining_before != 0 and
        intent.remaining_before <= intent.spec.work_quanta and
        intent.logical_tick_before != std.math.maxInt(u64) and
        intent.level_before != 0 and intent.level_after != 0 and
        intent.wait_quanta != 0 and
        intent.maximum_service_gap != 0 and
        intent.wait_quanta <= intent.maximum_service_gap and
        intent.resource_receipt.bank_epoch != 0 and
        intent.resource_receipt.generation != 0 and
        intent.resource_receipt.owner_key != 0 and
        !std.mem.eql(u8, &intent.state_before_sha256, &zero_digest) and
        !std.mem.eql(u8, &intent.chain_head_before_sha256, &zero_digest) and
        resource_bank.receiptIntegrityValidV1(intent.resource_receipt) and
        std.mem.eql(
            u8,
            &intent.resource_receipt_sha256,
            &resourceReceiptSha256(intent.resource_receipt),
        ) and std.mem.eql(
        u8,
        &intent.intent_sha256,
        &serviceIntentSha256(intent),
    );
}

/// Verify that an Event-v1 is the exact logical commit named by an intent.
/// Stateful LaneWeave replay remains responsible for the surrounding trace.
pub fn eventMatchesServiceIntentV1(
    event: EventV1,
    intent: ServiceIntentV1,
) bool {
    if (!serviceIntentValidV1(intent) or event.kind != .service or
        event.rejection_reason != .none or event.abi_version != event_abi or
        event.scheduler_epoch != intent.scheduler_epoch or
        event.event_sequence != intent.event_sequence or
        !std.mem.eql(
            u8,
            &event.previous_sha256,
            &intent.chain_head_before_sha256,
        ) or !std.mem.eql(
        u8,
        &event.state_before_sha256,
        &intent.state_before_sha256,
    ) or event.logical_tick_before != intent.logical_tick_before or
        event.cursor_before != intent.cursor_before or
        event.level_before != intent.level_before or
        event.cursor_after != intent.cursor_after or
        event.level_after != intent.level_after or
        !std.meta.eql(event.handle, intent.handle) or
        !std.meta.eql(event.spec, intent.spec) or
        !std.meta.eql(event.resource_receipt, intent.resource_receipt) or
        !std.mem.eql(
            u8,
            &event.resource_receipt_sha256,
            &intent.resource_receipt_sha256,
        ) or event.remaining_before != intent.remaining_before or
        event.wait_quanta != intent.wait_quanta or
        event.maximum_service_gap != intent.maximum_service_gap or
        !std.mem.eql(u8, &event.event_sha256, &eventSha256(event)))
        return false;
    const tick_after = std.math.add(
        u64,
        intent.logical_tick_before,
        1,
    ) catch return false;
    const remaining_after = std.math.sub(
        u64,
        intent.remaining_before,
        1,
    ) catch return false;
    if (event.logical_tick_after != tick_after or
        event.remaining_after != remaining_after or
        (intent.spec.deadline_tick != 0 and
            tick_after > intent.spec.deadline_tick) or
        !std.meta.eql(event.bank_used_before, event.bank_used_after) or
        std.mem.eql(u8, &event.state_after_sha256, &zero_digest))
        return false;
    if (intent.remaining_before == 1) {
        const active_after = std.math.sub(
            u32,
            event.active_before,
            1,
        ) catch return false;
        const finished_after = std.math.add(
            u32,
            event.finished_before,
            1,
        ) catch return false;
        return event.active_after == active_after and
            event.finished_after == finished_after;
    }
    return event.active_after == event.active_before and
        event.finished_after == event.finished_before;
}

/// Recompute one address-bound armed-completion ticket digest.
pub fn serviceCommitTicketSha256(ticket: ServiceCommitTicketV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(service_commit_ticket_domain);
    hashU64(&hash, ticket.abi_version);
    hashU64(&hash, ticket.scheduler_epoch);
    hashU64(&hash, ticket.coordinator_id);
    hashU64(&hash, ticket.coordinator_address);
    hashU64(&hash, ticket.permit_generation);
    hash.update(&ticket.permit_sha256);
    hashU64(&hash, ticket.commit_generation);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Canonically bind the complete ResourceBank receipt without raw padding.
pub fn resourceReceiptSha256(receipt: resource_bank.Receipt) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hashReceipt(&hash, receipt);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

/// Recompute one domain-separated event digest.
pub fn eventSha256(event: EventV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(event_domain);
    hashU64(&hash, event.abi_version);
    hashU64(&hash, event.scheduler_epoch);
    hashU64(&hash, event.event_sequence);
    hashU8(&hash, @intFromEnum(event.kind));
    hashU8(&hash, @intFromEnum(event.rejection_reason));
    hash.update(&event.previous_sha256);
    hash.update(&event.state_before_sha256);
    hash.update(&event.state_after_sha256);
    hashU64(&hash, event.logical_tick_before);
    hashU64(&hash, event.logical_tick_after);
    hashU32(&hash, event.cursor_before);
    hashU32(&hash, event.cursor_after);
    hashU16(&hash, event.level_before);
    hashU16(&hash, event.level_after);
    hashHandle(&hash, event.handle);
    hashSpec(&hash, event.spec);
    hashReceipt(&hash, event.resource_receipt);
    hash.update(&event.resource_receipt_sha256);
    hashU64(&hash, event.remaining_before);
    hashU64(&hash, event.remaining_after);
    hashU64(&hash, event.wait_quanta);
    hashU64(&hash, event.maximum_service_gap);
    hashU32(&hash, event.active_before);
    hashU32(&hash, event.active_after);
    hashU32(&hash, event.finished_before);
    hashU32(&hash, event.finished_after);
    hashClaim(&hash, event.bank_used_before);
    hashClaim(&hash, event.bank_used_after);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn initialRoot(
    config: Config,
    capacity: u32,
    bank_epoch: u64,
    limits: resource_bank.Limits,
    maximum_service_gap: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(initial_root_domain);
    hashU64(&hash, abi);
    hashU64(&hash, event_abi);
    hashU64(&hash, resource_bank.abi);
    hashU64(&hash, config.scheduler_epoch);
    hash.update(&config.challenge);
    hashU16(&hash, config.max_weight);
    hashU64(&hash, config.max_projection_quanta);
    hashU64(&hash, config.max_projection_operations);
    hashU32(&hash, capacity);
    hashU64(&hash, bank_epoch);
    hashLimits(&hash, limits);
    hashU64(&hash, maximum_service_gap);
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn hashSlot(hash: *std.crypto.hash.sha2.Sha256, slot: Slot) void {
    hashU8(hash, @intFromEnum(slot.state));
    hashU64(hash, slot.generation);
    hashSpec(hash, slot.spec);
    hashU64(hash, slot.remaining_quanta);
    hashU64(hash, slot.admitted_tick);
    hashU64(hash, slot.last_service_tick);
    hashU64(hash, slot.service_count);
    hashReceipt(hash, slot.receipt);
    hash.update(&slot.receipt_sha256);
}

fn hashSpec(hash: *std.crypto.hash.sha2.Sha256, spec: RequestSpec) void {
    hashU64(hash, spec.tenant_key);
    hashU64(hash, spec.request_key);
    hashU64(hash, spec.request_generation);
    hashU64(hash, spec.resource_owner_key);
    hashU16(hash, spec.weight);
    hashU64(hash, spec.work_quanta);
    hashU64(hash, spec.deadline_tick);
    hashClaim(hash, spec.claim);
}

fn hashHandle(hash: *std.crypto.hash.sha2.Sha256, handle: Handle) void {
    hashU64(hash, handle.scheduler_epoch);
    hashU32(hash, handle.slot_index);
    hashU64(hash, handle.slot_generation);
    hashU64(hash, handle.tenant_key);
    hashU64(hash, handle.request_key);
    hashU64(hash, handle.request_generation);
}

fn hashReceipt(hash: *std.crypto.hash.sha2.Sha256, receipt: resource_bank.Receipt) void {
    hashU64(hash, receipt.bank_epoch);
    hashU32(hash, receipt.slot_index);
    hashU64(hash, receipt.generation);
    hashU64(hash, receipt.owner_key);
    hashClaim(hash, receipt.claim);
    hashU64(hash, receipt.integrity);
}

fn hashClaim(hash: *std.crypto.hash.sha2.Sha256, claim: resource_bank.Claim) void {
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(hash, @field(claim, field.name));
}

fn hashLimits(hash: *std.crypto.hash.sha2.Sha256, limits: resource_bank.Limits) void {
    inline for (std.meta.fields(resource_bank.Limits)) |field|
        hashU64(hash, @field(limits, field.name));
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

const TestFixture = struct {
    bank_slots: [8]resource_bank.Slot = [_]resource_bank.Slot{.{}} ** 8,
    lane_slots: [8]Slot = [_]Slot{.{}} ** 8,
    projection: [8]ProjectionSlot = [_]ProjectionSlot{.{}} ** 8,
    bank: resource_bank.Bank = undefined,
    scheduler: Scheduler = undefined,

    fn init(self: *@This(), capacity: usize, max_weight: u16) !void {
        return self.initWithProjectionLimits(
            capacity,
            max_weight,
            10_000,
            1_000_000,
        );
    }

    fn initWithProjectionLimits(
        self: *@This(),
        capacity: usize,
        max_weight: u16,
        max_projection_quanta: u64,
        max_projection_operations: u64,
    ) !void {
        self.bank = try resource_bank.Bank.init(
            self.bank_slots[0..capacity],
            .{
                .host_bytes = 1 << 20,
                .kv_bytes = 1 << 20,
                .queue_slots = capacity,
            },
            0x4241_4e4b,
        );
        var challenge = zero_digest;
        challenge[0] = 0xa5;
        self.scheduler = try Scheduler.init(
            &self.bank,
            .{
                .slots = self.lane_slots[0..capacity],
                .projection = self.projection[0..capacity],
            },
            .{
                .scheduler_epoch = 0x5153_4553,
                .challenge = challenge,
                .max_weight = max_weight,
                .max_projection_quanta = max_projection_quanta,
                .max_projection_operations = max_projection_operations,
            },
        );
    }
};

fn testSpec(key: u64, weight: u16, work: u64, deadline: u64) RequestSpec {
    return .{
        .tenant_key = key,
        .request_key = key * 10,
        .request_generation = 1,
        .resource_owner_key = key * 100,
        .weight = weight,
        .work_quanta = work,
        .deadline_tick = deadline,
        .claim = .{ .kv_bytes = 64, .queue_slots = 1 },
    };
}

fn expectAdmitted(decision: AdmissionDecision) !Admission {
    return switch (decision) {
        .admitted => |value| value,
        .rejected => error.TestUnexpectedResult,
    };
}

const BoundFinalizerCapture = struct {
    calls: usize = 0,
    event: ?EventV1 = null,

    fn run(context: *anyopaque, event: *const EventV1) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.event = event.*;
    }

    fn interface(
        self: *@This(),
        request_epoch: u64,
        session_id: usize,
    ) ServiceFinalizerV2 {
        return .{
            .publication_request_epoch = request_epoch,
            .publication_session_id = session_id,
            .context = self,
            .finalize = run,
        };
    }

    fn interfaceV1(self: *@This()) ServiceFinalizerV1 {
        return .{
            .context = self,
            .finalize = run,
        };
    }
};

test "LaneWeave ServiceFinalizer-v1 layout and source literal stay stable" {
    const fields = std.meta.fields(ServiceFinalizerV1);
    try std.testing.expectEqual(
        @as(u64, 0x474c_5746_0000_0001),
        service_finalizer_abi,
    );
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("abi_version", fields[0].name);
    try std.testing.expectEqualStrings("context", fields[1].name);
    try std.testing.expectEqualStrings("finalize", fields[2].name);
    try std.testing.expectEqual(
        @as(usize, 0),
        @offsetOf(ServiceFinalizerV1, "abi_version"),
    );
    try std.testing.expectEqual(
        @sizeOf(u64),
        @offsetOf(ServiceFinalizerV1, "context"),
    );
    try std.testing.expectEqual(
        @sizeOf(u64) + @sizeOf(usize),
        @offsetOf(ServiceFinalizerV1, "finalize"),
    );
    try std.testing.expectEqual(
        @sizeOf(u64) + (2 * @sizeOf(usize)),
        @sizeOf(ServiceFinalizerV1),
    );
    var capture: BoundFinalizerCapture = .{};
    const finalizer = capture.interfaceV1();
    try std.testing.expectEqual(service_finalizer_abi, finalizer.abi_version);
}

test "LaneWeave IWRR golden order is interleaved and bounded" {
    var fixture: TestFixture = .{};
    try fixture.init(3, 4);
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(1, 1, 2, 0)));
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(2, 2, 4, 0)));
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(3, 4, 8, 0)));

    const expected = [_]u64{ 1, 2, 3, 2, 3, 3, 3, 1, 2, 3, 2, 3, 3, 3 };
    for (expected) |key| {
        const event = try fixture.scheduler.serveOne();
        try std.testing.expectEqual(EventKind.service, event.kind);
        try std.testing.expectEqual(key, event.handle.tenant_key);
        try std.testing.expect(event.wait_quanta <= event.maximum_service_gap);
        try std.testing.expect(std.mem.eql(
            u8,
            &event.event_sha256,
            &eventSha256(event),
        ));
    }

    const handles = [_]Handle{
        fixture.scheduler.handleFor(0),
        fixture.scheduler.handleFor(1),
        fixture.scheduler.handleFor(2),
    };
    for (handles) |handle| _ = try fixture.scheduler.retire(handle);
    const final = try fixture.scheduler.close();
    try std.testing.expectEqual(EventKind.close, final.kind);
    const final_hex = std.fmt.bytesToHex(final.event_sha256, .lower);
    // This freezes the event-v1 field order, domains and endianness. A change
    // requires an explicit event ABI bump rather than silent receipt drift.
    try std.testing.expectEqualStrings(
        "9cffc54d7a146c3a69cebb386a189dd1d3efffec3fba25c8ecadef8ab3c96785",
        &final_hex,
    );
    const bank = try fixture.bank.snapshot();
    try std.testing.expect(bank.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), bank.committed_receipts);
}

test "LaneWeave rejects an infeasible deadline before Bank mutation" {
    var fixture: TestFixture = .{};
    try fixture.init(2, 2);
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(1, 1, 2, 2)));
    const bank_before = try fixture.bank.snapshot();
    const decision = try fixture.scheduler.admit(testSpec(2, 1, 1, 1));
    const rejected = switch (decision) {
        .rejected => |event| event,
        .admitted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        RejectionReason.deadline_infeasible,
        rejected.rejection_reason,
    );
    const bank_after = try fixture.bank.snapshot();
    try std.testing.expectEqualDeep(bank_before, bank_after);
}

test "LaneWeave projection budgets reject before Bank mutation" {
    var quantum_fixture: TestFixture = .{};
    try quantum_fixture.initWithProjectionLimits(1, 1, 2, 100);
    const quantum_before = try quantum_fixture.bank.snapshot();
    const quantum_decision = try quantum_fixture.scheduler.admit(
        testSpec(1, 1, 3, 10),
    );
    const quantum_rejected = switch (quantum_decision) {
        .rejected => |event| event,
        .admitted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        RejectionReason.projection_limit,
        quantum_rejected.rejection_reason,
    );
    try std.testing.expectEqualDeep(
        quantum_before,
        try quantum_fixture.bank.snapshot(),
    );

    var operation_fixture: TestFixture = .{};
    try operation_fixture.initWithProjectionLimits(8, 8, 100, 32);
    const operation_before = try operation_fixture.bank.snapshot();
    const operation_decision = try operation_fixture.scheduler.admit(
        testSpec(1, 1, 4, 20),
    );
    const operation_rejected = switch (operation_decision) {
        .rejected => |event| event,
        .admitted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        RejectionReason.projection_limit,
        operation_rejected.rejection_reason,
    );
    try std.testing.expectEqualDeep(
        operation_before,
        try operation_fixture.bank.snapshot(),
    );

    var scan_fixture: TestFixture = .{};
    try scan_fixture.initWithProjectionLimits(8, 8, 100, 1);
    const scan_before = try scan_fixture.bank.snapshot();
    const scan_decision = try scan_fixture.scheduler.admit(
        testSpec(1, 1, 1, 0),
    );
    const scan_rejected = switch (scan_decision) {
        .rejected => |event| event,
        .admitted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        RejectionReason.projection_limit,
        scan_rejected.rejection_reason,
    );
    try std.testing.expectEqualDeep(
        scan_before,
        try scan_fixture.bank.snapshot(),
    );
}

test "LaneWeave rejects resource capacity without touching Bank counters" {
    var fixture: TestFixture = .{};
    try fixture.init(2, 2);
    var oversized = testSpec(1, 1, 1, 0);
    oversized.claim.kv_bytes = (1 << 20) + 1;
    const before = try fixture.bank.snapshot();
    const decision = try fixture.scheduler.admit(oversized);
    const rejected = switch (decision) {
        .rejected => |event| event,
        .admitted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(RejectionReason.resource_limit, rejected.rejection_reason);
    const after = try fixture.bank.snapshot();
    try std.testing.expectEqualDeep(before, after);
}

test "LaneWeave stale handles cannot cancel a reused slot" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    const first = try expectAdmitted(try fixture.scheduler.admit(testSpec(1, 1, 1, 0)));
    _ = try fixture.scheduler.cancel(first.handle);
    const second = try expectAdmitted(try fixture.scheduler.admit(testSpec(2, 1, 1, 0)));
    try std.testing.expect(second.handle.slot_generation != first.handle.slot_generation);
    try std.testing.expectError(
        Error.StaleHandle,
        fixture.scheduler.cancel(first.handle),
    );
    _ = try fixture.scheduler.cancel(second.handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave bound terminal release preserves legacy Event-v1 bytes" {
    var legacy: TestFixture = .{};
    var bound: TestFixture = .{};
    try legacy.init(1, 1);
    try bound.init(1, 1);
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);

    const legacy_cancel = try expectAdmitted(
        try legacy.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const bound_cancel = try expectAdmitted(
        try bound.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    try bound.scheduler.bindPublicationSession(
        bound_cancel,
        77,
        session_id,
    );
    const legacy_cancel_event =
        try legacy.scheduler.cancel(legacy_cancel.handle);
    const bound_cancel_event =
        try bound.scheduler.cancelBoundPublication(
            bound_cancel.handle,
            77,
            session_id,
            0,
        );
    try std.testing.expectEqualDeep(
        legacy_cancel_event,
        bound_cancel_event,
    );

    const legacy_retire = try expectAdmitted(
        try legacy.scheduler.admit(testSpec(2, 1, 1, 0)),
    );
    const bound_retire = try expectAdmitted(
        try bound.scheduler.admit(testSpec(2, 1, 1, 0)),
    );
    try bound.scheduler.bindPublicationSession(
        bound_retire,
        78,
        session_id,
    );
    const legacy_service_event = try legacy.scheduler.serveOne();
    const bound_permit = try bound.scheduler.prepareService();
    const bound_armed = try bound.scheduler.armServiceCommit(bound_permit);
    var capture: BoundFinalizerCapture = .{};
    const bound_service_event = try bound.scheduler.commitArmedServiceV2(
        bound_armed.ticket,
        capture.interface(78, session_id),
    );
    try std.testing.expectEqualDeep(
        legacy_service_event,
        bound_service_event,
    );
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(bound_service_event, capture.event.?);
    const legacy_retire_event =
        try legacy.scheduler.retire(legacy_retire.handle);
    const bound_retire_event =
        try bound.scheduler.retireBoundPublication(
            bound_retire.handle,
            78,
            session_id,
            0,
        );
    try std.testing.expectEqualDeep(
        legacy_retire_event,
        bound_retire_event,
    );
    try std.testing.expectEqualDeep(
        try legacy.scheduler.close(),
        try bound.scheduler.close(),
    );
    try std.testing.expectEqualDeep(
        try legacy.bank.snapshot(),
        try bound.bank.snapshot(),
    );
}

test "LaneWeave every-service binding requires V2 from the first quantum" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    try fixture.scheduler.bindPublicationSession(
        admission,
        89,
        session_id,
    );
    const before = try fixture.scheduler.snapshot();

    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.serveOne(),
    );
    const raw_permit = try fixture.scheduler.prepareService();
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitService(raw_permit),
    );
    try fixture.scheduler.abortService(raw_permit);

    const v1_permit = try fixture.scheduler.prepareService();
    const v1_armed = try fixture.scheduler.armServiceCommit(v1_permit);
    var capture: BoundFinalizerCapture = .{};
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitArmedService(
            v1_armed.ticket,
            capture.interfaceV1(),
        ),
    );
    try fixture.scheduler.abortArmedService(v1_armed.ticket);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqualDeep(before, try fixture.scheduler.snapshot());

    inline for (0..2) |index| {
        const permit = try fixture.scheduler.prepareService();
        const armed = try fixture.scheduler.armServiceCommit(permit);
        const event = try fixture.scheduler.commitArmedServiceV2(
            armed.ticket,
            capture.interface(89, session_id),
        );
        try std.testing.expectEqual(
            @as(u64, 1 - index),
            event.remaining_after,
        );
    }
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    _ = try fixture.scheduler.retireBoundPublication(
        admission.handle,
        89,
        session_id,
        0,
    );
    _ = try fixture.scheduler.close();
    try std.testing.expect((try fixture.bank.snapshot()).used.isZero());
}

test "LaneWeave partial binding metadata rejects terminal without poison" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    try fixture.scheduler.bindPublicationSession(
        admission,
        93,
        session_id,
    );
    const before = try fixture.scheduler.snapshot();
    const bank_before = try fixture.bank.snapshot();
    const index: usize = @intCast(admission.handle.slot_index);
    try std.testing.expectEqual(
        PublicationServicePolicy.every_service,
        fixture.lane_slots[index].publication_service_policy,
    );

    fixture.lane_slots[index].publication_service_policy = .none;
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.cancelBoundPublication(
            admission.handle,
            93,
            session_id,
            0,
        ),
    );
    try std.testing.expectEqualDeep(before, try fixture.scheduler.snapshot());
    try std.testing.expectEqualDeep(bank_before, try fixture.bank.snapshot());
    try std.testing.expect(!(try fixture.scheduler.snapshot()).poisoned);

    fixture.lane_slots[index].publication_service_policy = .every_service;
    _ = try fixture.scheduler.cancelBoundPublication(
        admission.handle,
        93,
        session_id,
        0,
    );
    _ = try fixture.scheduler.close();
    try std.testing.expect((try fixture.bank.snapshot()).used.isZero());
}

test "LaneWeave final-service binding preserves legacy non-final commits" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 4, 0)),
    );
    try fixture.scheduler.bindFinalPublicationSession(
        admission,
        90,
        session_id,
    );

    const before_non_final_v2 = try fixture.scheduler.snapshot();
    const non_final_v2_permit = try fixture.scheduler.prepareService();
    const non_final_v2_armed =
        try fixture.scheduler.armServiceCommit(non_final_v2_permit);
    var policy_capture: BoundFinalizerCapture = .{};
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitArmedServiceV2(
            non_final_v2_armed.ticket,
            policy_capture.interface(90, session_id),
        ),
    );
    try fixture.scheduler.abortArmedService(non_final_v2_armed.ticket);
    try std.testing.expectEqualDeep(
        before_non_final_v2,
        try fixture.scheduler.snapshot(),
    );
    try std.testing.expectEqual(@as(usize, 0), policy_capture.calls);

    const first = try fixture.scheduler.serveOne();
    try std.testing.expectEqual(@as(u64, 3), first.remaining_after);
    const non_final_permit = try fixture.scheduler.prepareService();
    const second = try fixture.scheduler.commitService(non_final_permit);
    try std.testing.expectEqual(@as(u64, 2), second.remaining_after);
    const v1_non_final_permit = try fixture.scheduler.prepareService();
    const v1_non_final_armed =
        try fixture.scheduler.armServiceCommit(v1_non_final_permit);
    var non_final_capture: BoundFinalizerCapture = .{};
    const third = try fixture.scheduler.commitArmedService(
        v1_non_final_armed.ticket,
        non_final_capture.interfaceV1(),
    );
    try std.testing.expectEqual(@as(u64, 1), third.remaining_after);
    try std.testing.expectEqual(@as(usize, 1), non_final_capture.calls);

    const before_final = try fixture.scheduler.snapshot();
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.serveOne(),
    );
    const raw_final_permit = try fixture.scheduler.prepareService();
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitService(raw_final_permit),
    );
    try fixture.scheduler.abortService(raw_final_permit);

    const v1_final_permit = try fixture.scheduler.prepareService();
    const v1_final_armed =
        try fixture.scheduler.armServiceCommit(v1_final_permit);
    var capture: BoundFinalizerCapture = .{};
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitArmedService(
            v1_final_armed.ticket,
            capture.interfaceV1(),
        ),
    );
    try fixture.scheduler.abortArmedService(v1_final_armed.ticket);
    try std.testing.expectEqualDeep(
        before_final,
        try fixture.scheduler.snapshot(),
    );
    try std.testing.expectEqual(@as(usize, 0), capture.calls);

    const final_permit = try fixture.scheduler.prepareService();
    const final_armed = try fixture.scheduler.armServiceCommit(final_permit);
    const final_event = try fixture.scheduler.commitArmedServiceV2(
        final_armed.ticket,
        capture.interface(90, session_id),
    );
    try std.testing.expectEqual(@as(u64, 0), final_event.remaining_after);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    _ = try fixture.scheduler.retireBoundPublication(
        admission.handle,
        90,
        session_id,
        0,
    );
    _ = try fixture.scheduler.close();
    try std.testing.expect((try fixture.bank.snapshot()).used.isZero());
}

test "LaneWeave bound publication rejects legacy final and terminal paths without poison" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    var coordinator: u8 = 0;
    var foreign_coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    try fixture.scheduler.bindPublicationSession(
        admission,
        91,
        session_id,
    );
    const scheduler_before = try fixture.scheduler.snapshot();
    const bank_before = try fixture.bank.snapshot();

    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.serveOne(),
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.cancel(admission.handle),
    );
    try std.testing.expectEqualDeep(
        scheduler_before,
        try fixture.scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(bank_before, try fixture.bank.snapshot());

    const raw_permit = try fixture.scheduler.prepareService();
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitService(raw_permit),
    );
    try fixture.scheduler.abortService(raw_permit);
    try std.testing.expectEqualDeep(
        scheduler_before,
        try fixture.scheduler.snapshot(),
    );

    const wrong_permit = try fixture.scheduler.prepareService();
    const wrong_armed = try fixture.scheduler.armServiceCommit(wrong_permit);
    var wrong_capture: BoundFinalizerCapture = .{};
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitArmedServiceV2(
            wrong_armed.ticket,
            wrong_capture.interface(
                91,
                @intFromPtr(&foreign_coordinator),
            ),
        ),
    );
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.commitArmedServiceV2(
            wrong_armed.ticket,
            wrong_capture.interface(90, session_id),
        ),
    );
    var bad_abi = wrong_capture.interface(91, session_id);
    bad_abi.abi_version = service_finalizer_abi;
    try std.testing.expectError(
        Error.InvalidConfiguration,
        fixture.scheduler.commitArmedServiceV2(
            wrong_armed.ticket,
            bad_abi,
        ),
    );
    var zero_epoch = wrong_capture.interface(91, session_id);
    zero_epoch.publication_request_epoch = 0;
    try std.testing.expectError(
        Error.InvalidConfiguration,
        fixture.scheduler.commitArmedServiceV2(
            wrong_armed.ticket,
            zero_epoch,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), wrong_capture.calls);
    const event = try fixture.scheduler.commitArmedServiceV2(
        wrong_armed.ticket,
        wrong_capture.interface(91, session_id),
    );
    try std.testing.expectEqual(@as(u64, 0), event.remaining_after);
    try std.testing.expectEqual(@as(usize, 1), wrong_capture.calls);
    const finished_before = try fixture.scheduler.snapshot();
    const finished_bank_before = try fixture.bank.snapshot();
    try std.testing.expectError(
        Error.InvalidTransition,
        fixture.scheduler.retire(admission.handle),
    );
    try std.testing.expectEqualDeep(
        finished_before,
        try fixture.scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(
        finished_bank_before,
        try fixture.bank.snapshot(),
    );
    try std.testing.expect(!finished_before.poisoned);

    _ = try fixture.scheduler.retireBoundPublication(
        admission.handle,
        91,
        session_id,
        0,
    );
    _ = try fixture.scheduler.close();
    const final = try fixture.bank.snapshot();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), final.committed_receipts);
}

test "LaneWeave concurrent legacy final service cannot bypass bound finalizer" {
    const LegacyWorker = struct {
        scheduler: *Scheduler,
        start: *std.atomic.Value(bool),
        event: ?EventV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.event = self.scheduler.serveOne() catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };
    const BoundWorker = struct {
        scheduler: *Scheduler,
        start: *std.atomic.Value(bool),
        request_epoch: u64,
        session_id: usize,
        capture: BoundFinalizerCapture = .{},
        event: ?EventV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            const permit = self.scheduler.prepareService() catch |err| {
                self.operation_error = err;
                return;
            };
            const armed = self.scheduler.armServiceCommit(permit) catch |err| {
                self.scheduler.abortService(permit) catch {};
                self.operation_error = err;
                return;
            };
            self.event = self.scheduler.commitArmedServiceV2(
                armed.ticket,
                self.capture.interface(
                    self.request_epoch,
                    self.session_id,
                ),
            ) catch |err| {
                self.scheduler.abortArmedService(armed.ticket) catch {};
                self.operation_error = err;
                return;
            };
        }
    };

    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    var coordinator: u8 = 0;
    const session_id = @intFromPtr(&coordinator);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    try fixture.scheduler.bindPublicationSession(
        admission,
        92,
        session_id,
    );

    var start = std.atomic.Value(bool).init(false);
    var legacy: LegacyWorker = .{
        .scheduler = &fixture.scheduler,
        .start = &start,
    };
    var bound: BoundWorker = .{
        .scheduler = &fixture.scheduler,
        .start = &start,
        .request_epoch = 92,
        .session_id = session_id,
    };
    const legacy_thread = try std.Thread.spawn(
        .{},
        LegacyWorker.run,
        .{&legacy},
    );
    const bound_thread = std.Thread.spawn(
        .{},
        BoundWorker.run,
        .{&bound},
    ) catch |err| {
        start.store(true, .release);
        legacy_thread.join();
        return err;
    };
    start.store(true, .release);
    legacy_thread.join();
    bound_thread.join();

    try std.testing.expectEqual(@as(?EventV1, null), legacy.event);
    const legacy_error = legacy.operation_error orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(
        legacy_error == Error.InvalidTransition or
            legacy_error == Error.ServiceInFlight or
            legacy_error == Error.NoRunnableRequest,
    );
    try std.testing.expectEqual(@as(?Error, null), bound.operation_error);
    const bound_event = bound.event orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), bound_event.remaining_after);
    try std.testing.expectEqual(@as(usize, 1), bound.capture.calls);
    try std.testing.expect(!(try fixture.scheduler.snapshot()).poisoned);

    _ = try fixture.scheduler.retireBoundPublication(
        admission.handle,
        92,
        session_id,
        0,
    );
    _ = try fixture.scheduler.close();
    const final = try fixture.bank.snapshot();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), final.committed_receipts);
}

test "LaneWeave service abort preserves exact logical and Bank state" {
    var fixture: TestFixture = .{};
    try fixture.init(2, 2);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 2, 3, 0)),
    );
    const logical_before = try fixture.scheduler.snapshot();
    const bank_before = try fixture.bank.snapshot();
    const slot_before = fixture.lane_slots[admission.handle.slot_index];
    const state_before = fixture.scheduler.stateSha256();

    const first = try fixture.scheduler.prepareService();
    try std.testing.expectEqualDeep(
        logical_before,
        try fixture.scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(bank_before, try fixture.bank.snapshot());
    try std.testing.expectEqualDeep(
        slot_before,
        fixture.lane_slots[admission.handle.slot_index],
    );
    try std.testing.expect(std.mem.eql(
        u8,
        &state_before,
        &fixture.scheduler.stateSha256(),
    ));
    try fixture.scheduler.abortService(first);
    try std.testing.expectEqualDeep(
        logical_before,
        try fixture.scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(bank_before, try fixture.bank.snapshot());
    try std.testing.expectEqualDeep(
        slot_before,
        fixture.lane_slots[admission.handle.slot_index],
    );

    const second = try fixture.scheduler.prepareService();
    try std.testing.expect(second.permit_generation > first.permit_generation);
    try std.testing.expect(!std.mem.eql(
        u8,
        &second.permit_sha256,
        &first.permit_sha256,
    ));
    try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.commitService(first),
    );
    try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.abortService(first),
    );
    try fixture.scheduler.abortService(second);
    _ = try fixture.scheduler.cancel(admission.handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave coordinator lifetime rejects same-address stale permits" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    const first_admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    const stale = try fixture.scheduler.prepareService();
    try fixture.scheduler.abortService(stale);
    _ = try fixture.scheduler.cancel(first_admission.handle);
    _ = try fixture.scheduler.close();

    const scheduler_address = @intFromPtr(&fixture.scheduler);
    try fixture.init(1, 1);
    try std.testing.expectEqual(
        scheduler_address,
        @intFromPtr(&fixture.scheduler),
    );
    const second_admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    const fresh = try fixture.scheduler.prepareService();
    try std.testing.expectEqual(
        stale.coordinator_address,
        fresh.coordinator_address,
    );
    try std.testing.expect(stale.coordinator_id != fresh.coordinator_id);
    try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.commitService(stale),
    );
    try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.abortService(stale),
    );

    _ = try fixture.scheduler.commitService(fresh);
    _ = try fixture.scheduler.retire(second_admission.handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave prepared commit is byte-identical to legacy service" {
    var legacy: TestFixture = .{};
    var prepared: TestFixture = .{};
    try legacy.init(2, 2);
    try prepared.init(2, 2);
    const legacy_admission = try expectAdmitted(
        try legacy.scheduler.admit(testSpec(1, 2, 2, 0)),
    );
    const prepared_admission = try expectAdmitted(
        try prepared.scheduler.admit(testSpec(1, 2, 2, 0)),
    );
    try std.testing.expectEqualDeep(
        legacy_admission.event,
        prepared_admission.event,
    );

    const legacy_event = try legacy.scheduler.serveOne();
    const permit = try prepared.scheduler.prepareService();
    const prepared_event = try prepared.scheduler.commitService(permit);
    try std.testing.expectEqualDeep(legacy_event, prepared_event);
    try std.testing.expectEqualDeep(
        try legacy.scheduler.snapshot(),
        try prepared.scheduler.snapshot(),
    );

    _ = try legacy.scheduler.cancel(legacy_admission.handle);
    _ = try prepared.scheduler.cancel(prepared_admission.handle);
    _ = try legacy.scheduler.close();
    _ = try prepared.scheduler.close();
}

test "LaneWeave armed service intent is idempotent and ticket fenced" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const before = try fixture.scheduler.snapshot();
    const first_permit = try fixture.scheduler.prepareService();
    const first = try fixture.scheduler.armServiceCommit(first_permit);
    try std.testing.expect(serviceIntentValidV1(first.intent));
    try std.testing.expectError(
        Error.ServiceInFlight,
        fixture.scheduler.commitService(first_permit),
    );
    try std.testing.expectError(
        Error.ServiceInFlight,
        fixture.scheduler.abortService(first_permit),
    );
    try std.testing.expectEqualDeep(before, try fixture.scheduler.snapshot());

    var mutations: [8]ServiceCommitTicketV1 =
        [_]ServiceCommitTicketV1{first.ticket} ** 8;
    mutations[0].abi_version +%= 1;
    mutations[1].scheduler_epoch +%= 1;
    mutations[2].coordinator_id +%= 1;
    mutations[3].coordinator_address +%= 1;
    mutations[4].permit_generation +%= 1;
    mutations[5].permit_sha256[0] ^= 0xff;
    mutations[6].commit_generation +%= 1;
    mutations[7].ticket_sha256[0] ^= 0xff;
    for (mutations) |mutation| try std.testing.expectError(
        Error.StaleServiceCommitTicket,
        fixture.scheduler.abortArmedService(mutation),
    );
    var self_consistent = first.ticket;
    self_consistent.commit_generation += 1;
    self_consistent.ticket_sha256 = serviceCommitTicketSha256(self_consistent);
    try std.testing.expectError(
        Error.StaleServiceCommitTicket,
        fixture.scheduler.abortArmedService(self_consistent),
    );
    try fixture.scheduler.abortArmedService(first.ticket);
    try std.testing.expectError(
        Error.StaleServiceCommitTicket,
        fixture.scheduler.abortArmedService(first.ticket),
    );
    try std.testing.expectEqualDeep(before, try fixture.scheduler.snapshot());

    const retry_permit = try fixture.scheduler.prepareService();
    const retry = try fixture.scheduler.armServiceCommit(retry_permit);
    try std.testing.expectEqualDeep(first.intent, retry.intent);
    try std.testing.expect(
        first.ticket.commit_generation != retry.ticket.commit_generation,
    );
    try fixture.scheduler.abortArmedService(retry.ticket);
    _ = try fixture.scheduler.cancel(admission.handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave armed finalizer preserves legacy Event-v1 bytes" {
    const Capture = struct {
        calls: usize = 0,
        event: ?EventV1 = null,

        fn run(context: *anyopaque, event: *const EventV1) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            self.event = event.*;
        }

        fn interface(self: *@This()) ServiceFinalizerV1 {
            return .{ .context = self, .finalize = run };
        }
    };

    var legacy: TestFixture = .{};
    var armed: TestFixture = .{};
    try legacy.init(1, 1);
    try armed.init(1, 1);
    const legacy_admission = try expectAdmitted(
        try legacy.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    const armed_admission = try expectAdmitted(
        try armed.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    try std.testing.expectEqualDeep(
        legacy_admission.event,
        armed_admission.event,
    );
    const legacy_event = try legacy.scheduler.serveOne();
    const permit = try armed.scheduler.prepareService();
    const prepared = try armed.scheduler.armServiceCommit(permit);
    var capture: Capture = .{};
    const armed_event = try armed.scheduler.commitArmedService(
        prepared.ticket,
        capture.interface(),
    );
    try std.testing.expectEqualDeep(legacy_event, armed_event);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqualDeep(armed_event, capture.event.?);
    try std.testing.expect(eventMatchesServiceIntentV1(
        armed_event,
        prepared.intent,
    ));
    try std.testing.expectError(
        Error.StaleServiceCommitTicket,
        armed.scheduler.commitArmedService(
            prepared.ticket,
            capture.interface(),
        ),
    );

    _ = try legacy.scheduler.retire(legacy_admission.handle);
    _ = try armed.scheduler.retire(armed_admission.handle);
    _ = try legacy.scheduler.close();
    _ = try armed.scheduler.close();
}

test "LaneWeave armed finalizer is ordered before the next service" {
    // This test-only hook deliberately blocks to make the mutex boundary
    // observable. Production finalizers are required to remain bounded and
    // nonblocking.
    const BlockingFinalizer = struct {
        entered: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),

        fn run(context: *anyopaque, _: *const EventV1) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.atomic.spinLoopHint();
        }
    };
    const ArmedWorker = struct {
        scheduler: *Scheduler,
        ticket: ServiceCommitTicketV1,
        finalizer: ServiceFinalizerV1,
        event: ?EventV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            self.event = self.scheduler.commitArmedService(
                self.ticket,
                self.finalizer,
            ) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };
    const ServiceWorker = struct {
        scheduler: *Scheduler,
        started: *std.atomic.Value(bool),
        finished: *std.atomic.Value(bool),
        event: ?EventV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            self.started.store(true, .release);
            self.event = self.scheduler.serveOne() catch |err| {
                self.operation_error = err;
                self.finished.store(true, .release);
                return;
            };
            self.finished.store(true, .release);
        }
    };

    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const permit = try fixture.scheduler.prepareService();
    const armed = try fixture.scheduler.armServiceCommit(permit);
    var entered = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var blocking: BlockingFinalizer = .{
        .entered = &entered,
        .release = &release,
    };
    var first: ArmedWorker = .{
        .scheduler = &fixture.scheduler,
        .ticket = armed.ticket,
        .finalizer = .{ .context = &blocking, .finalize = BlockingFinalizer.run },
    };
    const first_thread = try std.Thread.spawn(.{}, ArmedWorker.run, .{&first});
    while (!entered.load(.acquire)) std.atomic.spinLoopHint();

    var second_started = std.atomic.Value(bool).init(false);
    var second_finished = std.atomic.Value(bool).init(false);
    var second: ServiceWorker = .{
        .scheduler = &fixture.scheduler,
        .started = &second_started,
        .finished = &second_finished,
    };
    const second_thread = std.Thread.spawn(.{}, ServiceWorker.run, .{&second}) catch |err| {
        release.store(true, .release);
        first_thread.join();
        return err;
    };
    while (!second_started.load(.acquire)) std.atomic.spinLoopHint();
    for (0..10_000) |_| std.atomic.spinLoopHint();
    try std.testing.expect(!second_finished.load(.acquire));
    release.store(true, .release);
    first_thread.join();
    second_thread.join();

    try std.testing.expectEqual(@as(?Error, null), first.operation_error);
    try std.testing.expectEqual(@as(?Error, null), second.operation_error);
    try std.testing.expectEqual(
        first.event.?.event_sequence + 1,
        second.event.?.event_sequence,
    );
    try std.testing.expectEqual(@as(u64, 2), second.event.?.logical_tick_after);
    _ = try fixture.scheduler.retire(admission.handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave pending service blocks every logical mutator" {
    var fixture: TestFixture = .{};
    try fixture.init(2, 2);
    const selected = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const other = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(2, 2, 2, 0)),
    );
    const permit = try fixture.scheduler.prepareService();
    const logical_before = try fixture.scheduler.snapshot();
    const bank_before = try fixture.bank.snapshot();

    try std.testing.expectError(
        Error.ServiceInFlight,
        fixture.scheduler.prepareService(),
    );
    try std.testing.expectError(Error.ServiceInFlight, fixture.scheduler.serveOne());
    try std.testing.expectError(
        Error.ServiceInFlight,
        fixture.scheduler.admit(testSpec(3, 1, 1, 0)),
    );
    try std.testing.expectError(
        Error.ServiceInFlight,
        fixture.scheduler.cancel(selected.handle),
    );
    try std.testing.expectError(
        Error.ServiceInFlight,
        fixture.scheduler.cancel(other.handle),
    );
    try std.testing.expectError(
        Error.ServiceInFlight,
        fixture.scheduler.retire(selected.handle),
    );
    try std.testing.expectError(Error.ServiceInFlight, fixture.scheduler.close());
    try std.testing.expectEqualDeep(
        logical_before,
        try fixture.scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(bank_before, try fixture.bank.snapshot());

    try fixture.scheduler.abortService(permit);
    _ = try fixture.scheduler.cancel(selected.handle);
    _ = try fixture.scheduler.cancel(other.handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave mutated and foreign permits reject without consumption" {
    var fixture: TestFixture = .{};
    var foreign: TestFixture = .{};
    try fixture.init(1, 1);
    try foreign.init(1, 1);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    _ = try expectAdmitted(
        try foreign.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const permit = try fixture.scheduler.prepareService();

    var mutations: [20]ServicePermitV1 = [_]ServicePermitV1{permit} ** 20;
    mutations[0].abi_version +%= 1;
    mutations[1].scheduler_epoch +%= 1;
    mutations[2].coordinator_id +%= 1;
    mutations[3].coordinator_address +%= 1;
    mutations[4].permit_generation +%= 1;
    mutations[5].event_sequence +%= 1;
    mutations[6].handle.request_key +%= 1;
    mutations[7].logical_tick_before +%= 1;
    mutations[8].cursor_before +%= 1;
    mutations[9].level_before +%= 1;
    mutations[10].cursor_after +%= 1;
    mutations[11].level_after +%= 1;
    mutations[12].remaining_before +%= 1;
    mutations[13].wait_quanta +%= 1;
    mutations[14].maximum_service_gap +%= 1;
    mutations[15].state_before_sha256[0] ^= 0xff;
    mutations[16].chain_head_before_sha256[0] ^= 0xff;
    mutations[17].resource_receipt.owner_key +%= 1;
    mutations[18].resource_receipt_sha256[0] ^= 0xff;
    mutations[19].permit_sha256[0] ^= 0xff;
    for (mutations) |mutation| try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.commitService(mutation),
    );

    var self_consistent = permit;
    self_consistent.remaining_before += 1;
    self_consistent.permit_sha256 = servicePermitSha256(self_consistent);
    try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.abortService(self_consistent),
    );
    try std.testing.expectError(
        Error.StaleServicePermit,
        foreign.scheduler.commitService(permit),
    );

    _ = try fixture.scheduler.commitService(permit);
    try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.commitService(permit),
    );
    try std.testing.expectError(
        Error.StaleServicePermit,
        fixture.scheduler.abortService(permit),
    );
    _ = try fixture.scheduler.cancel(admission.handle);
    _ = try fixture.scheduler.close();

    const foreign_permit = try foreign.scheduler.prepareService();
    try foreign.scheduler.abortService(foreign_permit);
    _ = try foreign.scheduler.cancel(foreign.scheduler.handleFor(0));
    _ = try foreign.scheduler.close();
}

test "LaneWeave serializes two concurrent admissions into distinct live receipts" {
    const AdmissionWorker = struct {
        scheduler: *Scheduler,
        start: *std.atomic.Value(bool),
        spec: RequestSpec,
        admission: ?Admission = null,
        admission_error: ?Error = null,
        rejection: ?RejectionReason = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            const decision = self.scheduler.admit(self.spec) catch |err| {
                self.admission_error = err;
                return;
            };
            switch (decision) {
                .admitted => |admission| self.admission = admission,
                .rejected => |event| self.rejection = event.rejection_reason,
            }
        }
    };

    var fixture: TestFixture = .{};
    try fixture.init(2, 2);
    var start = std.atomic.Value(bool).init(false);
    var left: AdmissionWorker = .{
        .scheduler = &fixture.scheduler,
        .start = &start,
        .spec = testSpec(1, 1, 4, 0),
    };
    var right: AdmissionWorker = .{
        .scheduler = &fixture.scheduler,
        .start = &start,
        .spec = testSpec(2, 2, 4, 0),
    };
    const left_thread = try std.Thread.spawn(.{}, AdmissionWorker.run, .{&left});
    const right_thread = std.Thread.spawn(.{}, AdmissionWorker.run, .{&right}) catch |err| {
        start.store(true, .release);
        left_thread.join();
        return err;
    };
    start.store(true, .release);
    left_thread.join();
    right_thread.join();

    try std.testing.expectEqual(@as(?Error, null), left.admission_error);
    try std.testing.expectEqual(@as(?Error, null), right.admission_error);
    try std.testing.expectEqual(@as(?RejectionReason, null), left.rejection);
    try std.testing.expectEqual(@as(?RejectionReason, null), right.rejection);
    const left_admission = left.admission orelse return error.TestUnexpectedResult;
    const right_admission = right.admission orelse return error.TestUnexpectedResult;
    const left_receipt = left_admission.event.resource_receipt;
    const right_receipt = right_admission.event.resource_receipt;
    try std.testing.expect(left_receipt.slot_index != right_receipt.slot_index);
    try std.testing.expect(left_receipt.generation != right_receipt.generation);
    try std.testing.expect(!std.mem.eql(
        u8,
        &left_admission.event.resource_receipt_sha256,
        &right_admission.event.resource_receipt_sha256,
    ));
    try fixture.bank.validateCommitted(left_receipt);
    try fixture.bank.validateCommitted(right_receipt);
    const live = try fixture.bank.snapshot();
    try std.testing.expectEqual(@as(usize, 2), live.committed_receipts);
    try std.testing.expectEqual(@as(u64, 2), live.used.queue_slots);
    try std.testing.expectEqual(@as(u64, 128), live.used.kv_bytes);

    _ = try fixture.scheduler.cancel(left_admission.handle);
    _ = try fixture.scheduler.cancel(right_admission.handle);
    _ = try fixture.scheduler.close();
    const final = try fixture.bank.snapshot();
    try std.testing.expect(final.used.isZero());
    try std.testing.expectEqual(@as(usize, 0), final.committed_receipts);
}

test "LaneWeave copied service permits linearize commit and abort races" {
    const CommitWorker = struct {
        scheduler: *Scheduler,
        start: *std.atomic.Value(bool),
        permit: ServicePermitV1,
        event: ?EventV1 = null,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.event = self.scheduler.commitService(self.permit) catch |err| {
                self.operation_error = err;
                return;
            };
        }
    };
    const AbortWorker = struct {
        scheduler: *Scheduler,
        start: *std.atomic.Value(bool),
        permit: ServicePermitV1,
        succeeded: bool = false,
        operation_error: ?Error = null,

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            self.scheduler.abortService(self.permit) catch |err| {
                self.operation_error = err;
                return;
            };
            self.succeeded = true;
        }
    };

    var commits: TestFixture = .{};
    try commits.init(1, 1);
    const committed_request = try expectAdmitted(
        try commits.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const commit_permit = try commits.scheduler.prepareService();
    var commit_start = std.atomic.Value(bool).init(false);
    var first_commit: CommitWorker = .{
        .scheduler = &commits.scheduler,
        .start = &commit_start,
        .permit = commit_permit,
    };
    var second_commit = first_commit;
    const first_thread = try std.Thread.spawn(.{}, CommitWorker.run, .{&first_commit});
    const second_thread = std.Thread.spawn(.{}, CommitWorker.run, .{&second_commit}) catch |err| {
        commit_start.store(true, .release);
        first_thread.join();
        return err;
    };
    commit_start.store(true, .release);
    first_thread.join();
    second_thread.join();
    const committed_count = @intFromBool(first_commit.event != null) +
        @intFromBool(second_commit.event != null);
    try std.testing.expectEqual(@as(u2, 1), committed_count);
    const losing_commit_error = if (first_commit.event == null)
        first_commit.operation_error
    else
        second_commit.operation_error;
    try std.testing.expectEqual(
        @as(?Error, Error.StaleServicePermit),
        losing_commit_error,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        (try commits.scheduler.snapshot()).logical_tick,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        commits.lane_slots[committed_request.handle.slot_index].remaining_quanta,
    );
    _ = try commits.scheduler.cancel(committed_request.handle);
    _ = try commits.scheduler.close();

    var mixed: TestFixture = .{};
    try mixed.init(1, 1);
    const mixed_request = try expectAdmitted(
        try mixed.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const mixed_permit = try mixed.scheduler.prepareService();
    var mixed_start = std.atomic.Value(bool).init(false);
    var commit_worker: CommitWorker = .{
        .scheduler = &mixed.scheduler,
        .start = &mixed_start,
        .permit = mixed_permit,
    };
    var abort_worker: AbortWorker = .{
        .scheduler = &mixed.scheduler,
        .start = &mixed_start,
        .permit = mixed_permit,
    };
    const commit_thread = try std.Thread.spawn(.{}, CommitWorker.run, .{&commit_worker});
    const abort_thread = std.Thread.spawn(.{}, AbortWorker.run, .{&abort_worker}) catch |err| {
        mixed_start.store(true, .release);
        commit_thread.join();
        return err;
    };
    mixed_start.store(true, .release);
    commit_thread.join();
    abort_thread.join();
    try std.testing.expect((commit_worker.event != null) != abort_worker.succeeded);
    const mixed_tick = (try mixed.scheduler.snapshot()).logical_tick;
    if (commit_worker.event != null) {
        try std.testing.expectEqual(@as(u64, 1), mixed_tick);
        try std.testing.expectEqual(
            @as(?Error, Error.StaleServicePermit),
            abort_worker.operation_error,
        );
    } else {
        try std.testing.expectEqual(@as(u64, 0), mixed_tick);
        try std.testing.expectEqual(
            @as(?Error, Error.StaleServicePermit),
            commit_worker.operation_error,
        );
    }
    _ = try mixed.scheduler.cancel(mixed_request.handle);
    _ = try mixed.scheduler.close();

    var aborts: TestFixture = .{};
    try aborts.init(1, 1);
    const aborted_request = try expectAdmitted(
        try aborts.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    const abort_permit = try aborts.scheduler.prepareService();
    var abort_start = std.atomic.Value(bool).init(false);
    var first_abort: AbortWorker = .{
        .scheduler = &aborts.scheduler,
        .start = &abort_start,
        .permit = abort_permit,
    };
    var second_abort = first_abort;
    const first_abort_thread = try std.Thread.spawn(.{}, AbortWorker.run, .{&first_abort});
    const second_abort_thread = std.Thread.spawn(.{}, AbortWorker.run, .{&second_abort}) catch |err| {
        abort_start.store(true, .release);
        first_abort_thread.join();
        return err;
    };
    abort_start.store(true, .release);
    first_abort_thread.join();
    second_abort_thread.join();
    try std.testing.expect(first_abort.succeeded != second_abort.succeeded);
    const losing_abort_error = if (first_abort.succeeded)
        second_abort.operation_error
    else
        first_abort.operation_error;
    try std.testing.expectEqual(
        @as(?Error, Error.StaleServicePermit),
        losing_abort_error,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        (try aborts.scheduler.snapshot()).logical_tick,
    );
    _ = try aborts.scheduler.cancel(aborted_request.handle);
    _ = try aborts.scheduler.close();
}

test "LaneWeave challenge and trace determine the chain root" {
    var a: TestFixture = .{};
    var b: TestFixture = .{};
    try a.init(2, 3);
    try b.init(2, 3);

    const a1 = try expectAdmitted(try a.scheduler.admit(testSpec(1, 1, 2, 0)));
    const b1 = try expectAdmitted(try b.scheduler.admit(testSpec(1, 1, 2, 0)));
    try std.testing.expectEqualDeep(a1.event, b1.event);
    const a2 = try expectAdmitted(try a.scheduler.admit(testSpec(2, 3, 2, 0)));
    const b2 = try expectAdmitted(try b.scheduler.admit(testSpec(2, 3, 2, 0)));
    try std.testing.expectEqualDeep(a2.event, b2.event);
    while ((try a.scheduler.snapshot()).active != 0) {
        const ea = try a.scheduler.serveOne();
        const eb = try b.scheduler.serveOne();
        try std.testing.expectEqualDeep(ea, eb);
    }
    _ = try a.scheduler.retire(a1.handle);
    _ = try a.scheduler.retire(a2.handle);
    _ = try b.scheduler.retire(b1.handle);
    _ = try b.scheduler.retire(b2.handle);
    const ca = try a.scheduler.close();
    const cb = try b.scheduler.close();
    try std.testing.expectEqualDeep(ca, cb);
}

test "LaneWeave malformed event mutation changes its digest" {
    var fixture: TestFixture = .{};
    try fixture.init(1, 1);
    const admission = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    var changed = admission.event;
    changed.spec.work_quanta += 1;
    try std.testing.expect(!std.mem.eql(
        u8,
        &admission.event.event_sha256,
        &eventSha256(changed),
    ));
}

test "LaneWeave verifier reconstructs accepted rejected service and final zero" {
    var fixture: TestFixture = .{};
    try fixture.init(3, 4);
    var verify_slots: [3]Slot = [_]Slot{.{}} ** 3;
    var verify_projection: [3]ProjectionSlot = [_]ProjectionSlot{.{}} ** 3;
    var verifier = try Verifier.init(
        .{ .slots = &verify_slots, .projection = &verify_projection },
        fixture.scheduler.config,
        fixture.scheduler.bank_epoch,
        fixture.scheduler.limits,
    );

    const first = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    try verifier.apply(first.event);
    const duplicate = try fixture.scheduler.admit(testSpec(1, 1, 1, 0));
    const rejected = switch (duplicate) {
        .rejected => |event| event,
        .admitted => return error.TestUnexpectedResult,
    };
    try verifier.apply(rejected);
    const second = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(2, 2, 2, 0)),
    );
    try verifier.apply(second.event);

    while ((try fixture.scheduler.snapshot()).active != 0) {
        try verifier.apply(try fixture.scheduler.serveOne());
    }
    try verifier.apply(try fixture.scheduler.retire(first.handle));
    try verifier.apply(try fixture.scheduler.retire(second.handle));
    const close_event = try fixture.scheduler.close();
    try verifier.apply(close_event);
    const head = try verifier.finish(close_event.event_sha256);
    try std.testing.expect(std.mem.eql(u8, &head, &close_event.event_sha256));
}

test "LaneWeave aborted attempts are invisible to committed replay" {
    var legacy: TestFixture = .{};
    var permitted: TestFixture = .{};
    try legacy.init(3, 4);
    try permitted.init(3, 4);
    var legacy_handles: [3]Handle = undefined;
    var permitted_handles: [3]Handle = undefined;
    var verify_slots: [3]Slot = [_]Slot{.{}} ** 3;
    var verify_projection: [3]ProjectionSlot = [_]ProjectionSlot{.{}} ** 3;
    var verifier = try Verifier.init(
        .{ .slots = &verify_slots, .projection = &verify_projection },
        permitted.scheduler.config,
        permitted.scheduler.bank_epoch,
        permitted.scheduler.limits,
    );

    const weights = [_]u16{ 1, 2, 4 };
    const common_deadline: u64 = 14;
    for (weights, 0..) |weight, index| {
        const key: u64 = @intCast(index + 1);
        const left = try expectAdmitted(
            try legacy.scheduler.admit(
                testSpec(key, weight, weight * 2, common_deadline),
            ),
        );
        const right = try expectAdmitted(
            try permitted.scheduler.admit(
                testSpec(key, weight, weight * 2, common_deadline),
            ),
        );
        try std.testing.expectEqualDeep(left.event, right.event);
        try verifier.apply(right.event);
        legacy_handles[index] = left.handle;
        permitted_handles[index] = right.handle;
    }

    for (0..14) |step| {
        const legacy_event = try legacy.scheduler.serveOne();
        for (0..step % 4) |_| {
            const abandoned = try permitted.scheduler.prepareService();
            try permitted.scheduler.abortService(abandoned);
        }
        const permit = try permitted.scheduler.prepareService();
        const committed = try permitted.scheduler.commitService(permit);
        try std.testing.expectEqualDeep(legacy_event, committed);
        try verifier.apply(committed);
    }
    try std.testing.expectEqualDeep(
        try legacy.scheduler.snapshot(),
        try permitted.scheduler.snapshot(),
    );

    for (legacy_handles, permitted_handles) |left, right| {
        const left_event = try legacy.scheduler.retire(left);
        const right_event = try permitted.scheduler.retire(right);
        try std.testing.expectEqualDeep(left_event, right_event);
        try verifier.apply(right_event);
    }
    const legacy_close = try legacy.scheduler.close();
    const permitted_close = try permitted.scheduler.close();
    try std.testing.expectEqualDeep(legacy_close, permitted_close);
    try verifier.apply(permitted_close);
    _ = try verifier.finish(permitted_close.event_sha256);
}

test "LaneWeave permit overflow and Bank drift fail before service mutation" {
    var generation: TestFixture = .{};
    try generation.init(1, 1);
    _ = try expectAdmitted(
        try generation.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    generation.scheduler.next_service_permit_generation =
        std.math.maxInt(u64);
    const generation_before = try generation.scheduler.snapshot();
    const generation_bank = try generation.bank.snapshot();
    try std.testing.expectError(
        Error.GenerationOverflow,
        generation.scheduler.prepareService(),
    );
    try std.testing.expectEqualDeep(
        generation_before,
        try generation.scheduler.snapshot(),
    );
    try std.testing.expectEqualDeep(
        generation_bank,
        try generation.bank.snapshot(),
    );

    var sequence: TestFixture = .{};
    try sequence.init(1, 1);
    _ = try expectAdmitted(
        try sequence.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    sequence.scheduler.next_event_sequence = std.math.maxInt(u64);
    try std.testing.expectError(
        Error.SequenceOverflow,
        sequence.scheduler.prepareService(),
    );
    try std.testing.expect(sequence.scheduler.pending_service == null);

    var tick: TestFixture = .{};
    try tick.init(1, 1);
    _ = try expectAdmitted(try tick.scheduler.admit(testSpec(1, 1, 1, 0)));
    tick.scheduler.logical_tick = std.math.maxInt(u64);
    try std.testing.expectError(Error.TickOverflow, tick.scheduler.prepareService());
    try std.testing.expect(tick.scheduler.pending_service == null);

    var service: TestFixture = .{};
    try service.init(1, 1);
    _ = try expectAdmitted(
        try service.scheduler.admit(testSpec(1, 1, 1, 0)),
    );
    service.lane_slots[0].service_count = std.math.maxInt(u64);
    try std.testing.expectError(
        Error.ServiceOverflow,
        service.scheduler.prepareService(),
    );
    try std.testing.expect(service.scheduler.pending_service == null);

    var drift: TestFixture = .{};
    try drift.init(2, 1);
    _ = try expectAdmitted(
        try drift.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const drift_permit = try drift.scheduler.prepareService();
    const outside = try drift.bank.reserve(
        0xfeed,
        .{ .kv_bytes = 1, .queue_slots = 1 },
    );
    try std.testing.expectError(
        Error.BankDrift,
        drift.scheduler.commitService(drift_permit),
    );
    try std.testing.expect(drift.scheduler.poisoned);
    try std.testing.expectEqual(@as(u64, 0), drift.scheduler.logical_tick);
    try std.testing.expectEqual(@as(u64, 2), drift.lane_slots[0].remaining_quanta);
    try drift.bank.cancel(outside);
}

test "LaneWeave verifier rejects mutation reorder duplicate truncation and challenge replay" {
    var fixture: TestFixture = .{};
    try fixture.init(2, 2);
    const first = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 0)),
    );
    const second = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(2, 2, 2, 0)),
    );

    var slots_a: [2]Slot = [_]Slot{.{}} ** 2;
    var projection_a: [2]ProjectionSlot = [_]ProjectionSlot{.{}} ** 2;
    var mutation = try Verifier.init(
        .{ .slots = &slots_a, .projection = &projection_a },
        fixture.scheduler.config,
        fixture.scheduler.bank_epoch,
        fixture.scheduler.limits,
    );
    var changed = first.event;
    changed.spec.work_quanta += 1;
    changed.event_sha256 = eventSha256(changed);
    try std.testing.expectError(Error.InvalidEvent, mutation.apply(changed));

    var slots_b: [2]Slot = [_]Slot{.{}} ** 2;
    var projection_b: [2]ProjectionSlot = [_]ProjectionSlot{.{}} ** 2;
    var reordered = try Verifier.init(
        .{ .slots = &slots_b, .projection = &projection_b },
        fixture.scheduler.config,
        fixture.scheduler.bank_epoch,
        fixture.scheduler.limits,
    );
    try std.testing.expectError(Error.InvalidEvent, reordered.apply(second.event));

    var slots_c: [2]Slot = [_]Slot{.{}} ** 2;
    var projection_c: [2]ProjectionSlot = [_]ProjectionSlot{.{}} ** 2;
    var duplicated = try Verifier.init(
        .{ .slots = &slots_c, .projection = &projection_c },
        fixture.scheduler.config,
        fixture.scheduler.bank_epoch,
        fixture.scheduler.limits,
    );
    try duplicated.apply(first.event);
    try std.testing.expectError(Error.InvalidEvent, duplicated.apply(first.event));

    var slots_d: [2]Slot = [_]Slot{.{}} ** 2;
    var projection_d: [2]ProjectionSlot = [_]ProjectionSlot{.{}} ** 2;
    var truncated = try Verifier.init(
        .{ .slots = &slots_d, .projection = &projection_d },
        fixture.scheduler.config,
        fixture.scheduler.bank_epoch,
        fixture.scheduler.limits,
    );
    try truncated.apply(first.event);
    try std.testing.expectError(Error.InvalidEvent, truncated.finish(null));

    var wrong_config = fixture.scheduler.config;
    wrong_config.challenge[0] ^= 0xff;
    var slots_e: [2]Slot = [_]Slot{.{}} ** 2;
    var projection_e: [2]ProjectionSlot = [_]ProjectionSlot{.{}} ** 2;
    var replayed = try Verifier.init(
        .{ .slots = &slots_e, .projection = &projection_e },
        wrong_config,
        fixture.scheduler.bank_epoch,
        fixture.scheduler.limits,
    );
    try std.testing.expectError(Error.InvalidEvent, replayed.apply(first.event));
}

test "LaneWeave admission rejects a new undated request that breaks an existing deadline" {
    var fixture: TestFixture = .{};
    try fixture.init(2, 1);
    const first = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 2)),
    );
    const before = try fixture.bank.snapshot();
    const decision = try fixture.scheduler.admit(testSpec(2, 1, 8, 0));
    const rejected = switch (decision) {
        .rejected => |event| event,
        .admitted => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(
        RejectionReason.deadline_infeasible,
        rejected.rejection_reason,
    );
    try std.testing.expectEqualDeep(before, try fixture.bank.snapshot());
    _ = try fixture.scheduler.cancel(first.handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave service gap bound holds across ten thousand weighted quanta" {
    var fixture: TestFixture = .{};
    try fixture.init(8, 8);
    var handles: [8]Handle = undefined;
    for (&handles, 0..) |*handle, index| {
        const admission = try expectAdmitted(try fixture.scheduler.admit(testSpec(
            @intCast(index + 1),
            @intCast(index + 1),
            20_000,
            0,
        )));
        handle.* = admission.handle;
    }
    for (0..10_000) |_| {
        const event = try fixture.scheduler.serveOne();
        try std.testing.expect(event.wait_quanta <= event.maximum_service_gap);
    }
    for (handles) |handle| _ = try fixture.scheduler.cancel(handle);
    _ = try fixture.scheduler.close();
}

test "LaneWeave restarts both IWRR axes when the maximum live weight drops" {
    var fixture: TestFixture = .{};
    try fixture.init(3, 3);
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(1, 1, 2, 0)));
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(2, 3, 3, 0)));
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(3, 2, 4, 0)));

    const expected = [_]u64{ 1, 2, 3, 2, 3, 2, 1, 3, 3 };
    for (expected) |tenant| {
        const event = try fixture.scheduler.serveOne();
        try std.testing.expectEqual(tenant, event.handle.tenant_key);
        try std.testing.expect(event.wait_quanta <= event.maximum_service_gap);
    }
}

test "LaneWeave cancellation cannot invalidate a previously admitted deadline" {
    var fixture: TestFixture = .{};
    try fixture.init(3, 2);
    const deadline = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(1, 1, 2, 5)),
    );
    const heavy = try expectAdmitted(
        try fixture.scheduler.admit(testSpec(2, 2, 3, 0)),
    );
    _ = try expectAdmitted(try fixture.scheduler.admit(testSpec(3, 1, 2, 0)));

    for (0..4) |_| _ = try fixture.scheduler.serveOne();
    _ = try fixture.scheduler.cancel(heavy.handle);
    const terminal = try fixture.scheduler.serveOne();
    try std.testing.expectEqual(deadline.handle.tenant_key, terminal.handle.tenant_key);
    try std.testing.expectEqual(@as(u64, 5), terminal.logical_tick_after);
    try std.testing.expectEqual(@as(u64, 0), terminal.remaining_after);
}

test "LaneWeave cancellation projection is monotonic for small exhaustive states" {
    const capacity = 3;
    const max_weight = 3;
    const config: Config = .{
        .scheduler_epoch = 1,
        .challenge = zero_digest,
        .max_weight = max_weight,
        .max_projection_quanta = 32,
    };

    // Three lanes, each with weight and work in 1...3, all cursor positions and
    // all IWRR levels: 26,244 removal projections. Deadlines are pinned to the
    // original exact completion tick, so any delayed survivor fails.
    for (0..729) |encoded| {
        var code = encoded;
        var weights: [capacity]u16 = undefined;
        var work: [capacity]u64 = undefined;
        for (&weights) |*weight| {
            weight.* = @intCast(code % 3 + 1);
            code /= 3;
        }
        for (&work) |*quanta| {
            quanta.* = @intCast(code % 3 + 1);
            code /= 3;
        }

        for (0..capacity + 1) |initial_cursor| {
            for (1..max_weight + 1) |initial_level| {
                var slots: [capacity]Slot = [_]Slot{.{}} ** capacity;
                var simulated: [capacity]ProjectionSlot = undefined;
                for (0..capacity) |index| {
                    slots[index] = .{
                        .state = .active,
                        .spec = .{ .weight = weights[index] },
                        .remaining_quanta = work[index],
                    };
                    simulated[index] = .{
                        .active = true,
                        .weight = weights[index],
                        .remaining_quanta = work[index],
                    };
                }

                var tick: u64 = 0;
                var cursor: u32 = @intCast(initial_cursor);
                var level: u16 = @intCast(initial_level);
                var completed: usize = 0;
                while (completed < capacity) {
                    const selection = selectIWRR(
                        &simulated,
                        cursor,
                        level,
                        max_weight,
                    ).?;
                    const selected = &simulated[selection.slot_index];
                    selected.remaining_quanta -= 1;
                    tick += 1;
                    if (selected.remaining_quanta == 0) {
                        selected.active = false;
                        slots[selection.slot_index].spec.deadline_tick = tick;
                        completed += 1;
                    }
                    cursor = selection.cursor_after;
                    level = selection.level_after;
                }

                for (0..capacity) |removed_index| {
                    var scratch: [capacity]ProjectionSlot = undefined;
                    try std.testing.expectEqual(
                        ProjectionOutcome.feasible,
                        projectAfterRemoval(
                            &slots,
                            &scratch,
                            removed_index,
                            0,
                            @intCast(initial_cursor),
                            @intCast(initial_level),
                            config,
                        ),
                    );
                }
            }
        }
    }
}

test "LaneWeave maximum u16 weight wraps levels without integer overflow" {
    const max_weight = std.math.maxInt(u16);
    const slots = [_]ProjectionSlot{.{
        .active = true,
        .weight = max_weight,
        .remaining_quanta = 2,
    }};
    const selection = selectIWRR(&slots, 1, max_weight, max_weight).?;
    try std.testing.expectEqual(@as(usize, 0), selection.slot_index);
    try std.testing.expectEqual(@as(u16, 1), selection.level_after);
}

test "LaneWeave IWRR scan budget crosses the 32-bit usize boundary in u64" {
    const slot_count: usize = std.math.maxInt(u32);
    const max_weight = std.math.maxInt(u16);
    const scan_limit = iwrrScanLimit(slot_count, max_weight).?;
    const expected = @as(u64, std.math.maxInt(u32)) *
        @as(u64, std.math.maxInt(u16));
    try std.testing.expectEqual(expected, scan_limit);
    try std.testing.expect(scan_limit > std.math.maxInt(u32));
}
