//! Fixed-storage control plane for external AI token budgets and exact
//! in-flight request coalescing.
//!
//! This module performs no network I/O and stores no prompt or response bytes.
//! It gives provider adapters one canonical request identity, reserves a
//! conservative billable-token ceiling before dispatch, ensures exact
//! coalesced followers do not dispatch again, lets logical consumers cancel
//! without tearing down shared work, records retry/ambiguous outcomes, and
//! settles authoritative usage into a replayable event chain.

const std = @import("std");

pub const abi: u64 = 0x4750_5447_0000_0002;
pub const request_abi: u64 = 0x4750_5451_0000_0001;
pub const usage_abi: u64 = 0x4750_5455_0000_0001;
pub const handle_abi: u64 = 0x4750_5448_0000_0001;
pub const dispatch_intent_abi: u64 = 0x4750_5449_0000_0001;
pub const dispatch_permit_abi: u64 = 0x4750_5450_0000_0001;
pub const event_abi: u64 = 0x4750_5445_0000_0002;
pub const attempt_receipt_abi: u64 = 0x4750_5452_0000_0001;
pub const snapshot_abi: u64 = 0x4750_5453_0000_0002;
pub const Digest = [32]u8;
pub const zero_digest: Digest = [_]u8{0} ** 32;

const request_domain = "glacier-provider-request-v1\x00";
const dispatch_key_domain = "glacier-provider-dispatch-key-v1\x00";
const usage_domain = "glacier-provider-usage-v1\x00";
const handle_domain = "glacier-provider-handle-v1\x00";
const intent_domain = "glacier-provider-dispatch-intent-v1\x00";
const permit_domain = "glacier-provider-dispatch-permit-v1\x00";
const request_set_domain = "glacier-provider-request-set-v1\x00";
const event_domain = "glacier-provider-token-event-v2\x00";
const chain_domain = "glacier-provider-token-chain-v2\x00";
const receipt_domain = "glacier-provider-attempt-receipt-v1\x00";

pub const Error = error{
    InvalidConfiguration,
    InvalidRequest,
    RequestConflict,
    RequestAlreadyAcknowledged,
    RequestCancelled,
    CapacityExceeded,
    BudgetExceeded,
    InvalidHandle,
    InvalidState,
    InvalidPermit,
    InvalidUsage,
    SequenceExhausted,
    StateDrift,
};

pub const ReusePolicy = enum(u8) {
    none,
    in_flight,
};

pub const RequestV1 = struct {
    abi_version: u64 = request_abi,
    provider_adapter_abi: u64 = 0,
    isolation_key: u64 = 0,
    request_key: u64 = 0,
    request_generation: u64 = 0,
    model_sha256: Digest = zero_digest,
    context_sha256: Digest = zero_digest,
    tool_schema_sha256: Digest = zero_digest,
    policy_sha256: Digest = zero_digest,
    sampling_sha256: Digest = zero_digest,
    input_token_estimate: u64 = 0,
    max_output_tokens: u64 = 0,
    reuse_policy: ReusePolicy = .none,
    request_sha256: Digest = zero_digest,
};

pub fn makeRequestV1(
    provider_adapter_abi: u64,
    isolation_key: u64,
    request_key: u64,
    request_generation: u64,
    model_sha256: Digest,
    context_sha256: Digest,
    tool_schema_sha256: Digest,
    policy_sha256: Digest,
    sampling_sha256: Digest,
    input_token_estimate: u64,
    max_output_tokens: u64,
    reuse_policy: ReusePolicy,
) Error!RequestV1 {
    var request: RequestV1 = .{
        .provider_adapter_abi = provider_adapter_abi,
        .isolation_key = isolation_key,
        .request_key = request_key,
        .request_generation = request_generation,
        .model_sha256 = model_sha256,
        .context_sha256 = context_sha256,
        .tool_schema_sha256 = tool_schema_sha256,
        .policy_sha256 = policy_sha256,
        .sampling_sha256 = sampling_sha256,
        .input_token_estimate = input_token_estimate,
        .max_output_tokens = max_output_tokens,
        .reuse_policy = reuse_policy,
    };
    request.request_sha256 = requestSha256(request);
    if (!requestValidV1(request)) return Error.InvalidRequest;
    return request;
}

pub fn requestSha256(request: RequestV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(request_domain);
    hashU64(&hash, request.abi_version);
    hashU64(&hash, request.provider_adapter_abi);
    hashU64(&hash, request.isolation_key);
    hashU64(&hash, request.request_key);
    hashU64(&hash, request.request_generation);
    hash.update(&request.model_sha256);
    hash.update(&request.context_sha256);
    hash.update(&request.tool_schema_sha256);
    hash.update(&request.policy_sha256);
    hash.update(&request.sampling_sha256);
    hashU64(&hash, request.input_token_estimate);
    hashU64(&hash, request.max_output_tokens);
    hashU8(&hash, @intFromEnum(request.reuse_policy));
    return finish(&hash);
}

pub fn requestValidV1(request: RequestV1) bool {
    return request.abi_version == request_abi and
        request.provider_adapter_abi != 0 and request.isolation_key != 0 and
        request.request_key != 0 and request.request_generation != 0 and
        request.input_token_estimate != 0 and request.max_output_tokens != 0 and
        !isZero(request.model_sha256) and !isZero(request.context_sha256) and
        !isZero(request.tool_schema_sha256) and
        !isZero(request.policy_sha256) and
        !isZero(request.sampling_sha256) and std.mem.eql(
        u8,
        &request.request_sha256,
        &requestSha256(request),
    );
}

/// Identity of provider work. Request/idempotency keys are intentionally
/// omitted so two requests in the same isolation domain can share one exact
/// in-flight dispatch only when every output-affecting field agrees.
pub fn dispatchKeySha256(request: RequestV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(dispatch_key_domain);
    hashU64(&hash, request_abi);
    hashU64(&hash, request.provider_adapter_abi);
    hashU64(&hash, request.isolation_key);
    hash.update(&request.model_sha256);
    hash.update(&request.context_sha256);
    hash.update(&request.tool_schema_sha256);
    hash.update(&request.policy_sha256);
    hash.update(&request.sampling_sha256);
    hashU64(&hash, request.input_token_estimate);
    hashU64(&hash, request.max_output_tokens);
    return finish(&hash);
}

pub const CountV1 = struct {
    known: bool = false,
    value: u64 = 0,
};

pub const UsageV1 = struct {
    abi_version: u64 = usage_abi,
    input_tokens: CountV1 = .{},
    output_tokens: CountV1 = .{},
    cached_input_tokens: CountV1 = .{},
    reasoning_tokens: CountV1 = .{},
    retry_tokens: CountV1 = .{},
    billable_tokens: CountV1 = .{},
    usage_sha256: Digest = zero_digest,
};

pub fn makeUsageV1(
    input_tokens: ?u64,
    output_tokens: ?u64,
    cached_input_tokens: ?u64,
    reasoning_tokens: ?u64,
    retry_tokens: ?u64,
    billable_tokens: ?u64,
) Error!UsageV1 {
    var usage: UsageV1 = .{
        .input_tokens = makeCount(input_tokens),
        .output_tokens = makeCount(output_tokens),
        .cached_input_tokens = makeCount(cached_input_tokens),
        .reasoning_tokens = makeCount(reasoning_tokens),
        .retry_tokens = makeCount(retry_tokens),
        .billable_tokens = makeCount(billable_tokens),
    };
    usage.usage_sha256 = usageSha256(usage);
    if (!usageValidV1(usage)) return Error.InvalidUsage;
    return usage;
}

fn makeCount(value: ?u64) CountV1 {
    return if (value) |exact|
        .{ .known = true, .value = exact }
    else
        .{};
}

pub fn usageSha256(usage: UsageV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(usage_domain);
    hashU64(&hash, usage.abi_version);
    hashCount(&hash, usage.input_tokens);
    hashCount(&hash, usage.output_tokens);
    hashCount(&hash, usage.cached_input_tokens);
    hashCount(&hash, usage.reasoning_tokens);
    hashCount(&hash, usage.retry_tokens);
    hashCount(&hash, usage.billable_tokens);
    return finish(&hash);
}

pub fn usageValidV1(usage: UsageV1) bool {
    if (usage.abi_version != usage_abi or
        !countValid(usage.input_tokens) or
        !countValid(usage.output_tokens) or
        !countValid(usage.cached_input_tokens) or
        !countValid(usage.reasoning_tokens) or
        !countValid(usage.retry_tokens) or
        !countValid(usage.billable_tokens)) return false;
    if (usage.input_tokens.known and usage.cached_input_tokens.known and
        usage.cached_input_tokens.value > usage.input_tokens.value)
        return false;
    return std.mem.eql(
        u8,
        &usage.usage_sha256,
        &usageSha256(usage),
    );
}

fn countValid(count: CountV1) bool {
    return count.known or count.value == 0;
}

pub const LimitsV1 = struct {
    max_reserved_tokens: u64 = 0,
    max_reserved_tokens_per_isolation: u64 = 0,
    max_request_tokens: u64 = 0,
    max_followers_per_owner: u32 = 0,
};

pub const ConfigV1 = struct {
    gateway_epoch: u64 = 0,
    challenge: Digest = zero_digest,
    limits: LimitsV1 = .{},
};

pub const LedgerV2 = struct {
    reserved_tokens: u64 = 0,
    settled_billable_tokens: u64 = 0,
    budget_overrun_tokens: u64 = 0,
    budget_overrun_dispatches: u64 = 0,
    active_handles: u64 = 0,
    ready_owners: u64 = 0,
    dispatched_owners: u64 = 0,
    ambiguous_owners: u64 = 0,
    physical_dispatches: u64 = 0,
    coalesced_requests: u64 = 0,
    retryable_attempts: u64 = 0,
    ambiguous_attempts: u64 = 0,
    successful_dispatches: u64 = 0,
    failed_dispatches: u64 = 0,
    acknowledged_handles: u64 = 0,
    cancelled_handles: u64 = 0,
    cancelled_followers: u64 = 0,
    cancelled_ready_owners: u64 = 0,
};

pub const HandleKind = enum(u8) {
    owner,
    follower,
};

pub const RequestHandleV1 = struct {
    abi_version: u64 = handle_abi,
    gateway_epoch: u64 = 0,
    gateway_id: usize = 0,
    kind: HandleKind = .owner,
    slot_index: u32 = 0,
    generation: u64 = 0,
    owner_slot_index: u32 = 0,
    owner_generation: u64 = 0,
    request_sha256: Digest = zero_digest,
    integrity_sha256: Digest = zero_digest,
};

pub const DispatchIntentV1 = struct {
    abi_version: u64 = dispatch_intent_abi,
    gateway_epoch: u64 = 0,
    owner_slot_index: u32 = 0,
    owner_generation: u64 = 0,
    attempt_generation: u64 = 0,
    request_sha256: Digest = zero_digest,
    dispatch_key_sha256: Digest = zero_digest,
    reserved_tokens: u64 = 0,
    previous_event_chain_sha256: Digest = zero_digest,
    intent_sha256: Digest = zero_digest,
};

pub const DispatchPermitV1 = struct {
    abi_version: u64 = dispatch_permit_abi,
    gateway_id: usize = 0,
    intent: DispatchIntentV1 = .{},
    integrity_sha256: Digest = zero_digest,
};

pub const AttemptOutcome = enum(u8) {
    retryable_no_charge,
    ambiguous,
    succeeded,
    failed,
    resolved_success,
    resolved_failure,
};

pub const AttemptReceiptV1 = struct {
    abi_version: u64 = attempt_receipt_abi,
    outcome: AttemptOutcome = .retryable_no_charge,
    intent: DispatchIntentV1 = .{},
    usage: UsageV1 = .{},
    result_sha256: Digest = zero_digest,
    request_set_count: u32 = 0,
    request_set_sha256: Digest = zero_digest,
    event_sha256: Digest = zero_digest,
    receipt_sha256: Digest = zero_digest,
};

pub const EventKind = enum(u8) {
    owner_admitted,
    follower_coalesced,
    dispatch_started,
    retryable_no_charge,
    ambiguous,
    succeeded,
    failed,
    resolved_success,
    resolved_failure,
    owner_cancelled,
    follower_cancelled,
    acknowledged,
};

pub const EventV2 = struct {
    abi_version: u64 = event_abi,
    gateway_epoch: u64 = 0,
    sequence: u64 = 0,
    kind: EventKind = .owner_admitted,
    owner_slot_index: u32 = 0,
    owner_generation: u64 = 0,
    attempt_generation: u64 = 0,
    request_sha256: Digest = zero_digest,
    dispatch_key_sha256: Digest = zero_digest,
    intent_sha256: Digest = zero_digest,
    usage_sha256: Digest = zero_digest,
    result_sha256: Digest = zero_digest,
    request_set_count: u32 = 0,
    request_set_sha256: Digest = zero_digest,
    reservation_tokens: u64 = 0,
    billable_tokens: u64 = 0,
    before: LedgerV2 = .{},
    after: LedgerV2 = .{},
    previous_chain_sha256: Digest = zero_digest,
    event_sha256: Digest = zero_digest,
};

pub const OwnerState = enum(u8) {
    free,
    ready,
    dispatched,
    ambiguous,
    succeeded,
    failed,
};

pub const OwnerSlot = struct {
    generation: u64 = 0,
    state: OwnerState = .free,
    request: RequestV1 = .{},
    dispatch_key_sha256: Digest = zero_digest,
    reserved_tokens: u64 = 0,
    next_attempt_generation: u64 = 1,
    active_intent: DispatchIntentV1 = .{},
    active_permit_sha256: Digest = zero_digest,
    request_set_count: u32 = 0,
    request_set_sha256: Digest = zero_digest,
    follower_count: u32 = 0,
    live_follower_handles: u32 = 0,
    pending_acknowledgements: u32 = 0,
    owner_acknowledged: bool = false,
    last_receipt: AttemptReceiptV1 = .{},
};

pub const FollowerSlot = struct {
    generation: u64 = 0,
    active: bool = false,
    acknowledged: bool = false,
    cancelled: bool = false,
    owner_slot_index: u32 = 0,
    owner_generation: u64 = 0,
    request: RequestV1 = .{},
};

pub const AdmissionKind = enum(u8) {
    owner,
    coalesced,
    existing,
};

pub const AdmissionV2 = struct {
    kind: AdmissionKind,
    handle: RequestHandleV1,
    dispatch_key_sha256: Digest,
    event: ?EventV2,
};

pub const DispatchStartV2 = struct {
    intent: DispatchIntentV1,
    permit: DispatchPermitV1,
    event: EventV2,
};

pub const AttemptResultV2 = struct {
    receipt: AttemptReceiptV1,
    event: EventV2,
};

pub const PendingV2 = struct {
    owner_state: OwnerState,
    next_attempt_generation: u64,
};

pub const StatusV2 = union(enum) {
    pending: PendingV2,
    ambiguous: AttemptReceiptV1,
    succeeded: AttemptReceiptV1,
    failed: AttemptReceiptV1,
};

pub const SnapshotV2 = struct {
    abi_version: u64 = snapshot_abi,
    gateway_epoch: u64,
    limits: LimitsV1,
    owner_capacity: u32,
    follower_capacity: u32,
    next_event_sequence: u64,
    ledger: LedgerV2,
    event_chain_sha256: Digest,
};

pub const Gateway = struct {
    mutex: std.Thread.Mutex = .{},
    config: ConfigV1 = .{},
    owners: []OwnerSlot = &.{},
    followers: []FollowerSlot = &.{},
    gateway_id: usize = 0,
    owner_storage_id: usize = 0,
    follower_storage_id: usize = 0,
    owner_capacity: u32 = 0,
    follower_capacity: u32 = 0,
    configuration_sha256: Digest = zero_digest,
    initialized: bool = false,
    next_event_sequence: u64 = 0,
    ledger: LedgerV2 = .{},
    event_chain_sha256: Digest = zero_digest,

    pub fn init(
        self: *Gateway,
        owners: []OwnerSlot,
        followers: []FollowerSlot,
        config: ConfigV1,
    ) Error!void {
        if (self.initialized or !configValid(config) or owners.len == 0 or
            owners.len > std.math.maxInt(u32) or
            followers.len > std.math.maxInt(u32) or
            storageOverlaps(self, owners, followers))
            return Error.InvalidConfiguration;
        for (owners) |*slot| slot.* = .{};
        for (followers) |*slot| slot.* = .{};
        self.* = .{
            .config = config,
            .owners = owners,
            .followers = followers,
            .gateway_id = @intFromPtr(self),
            .owner_storage_id = @intFromPtr(owners.ptr),
            .follower_storage_id = @intFromPtr(followers.ptr),
            .owner_capacity = @intCast(owners.len),
            .follower_capacity = @intCast(followers.len),
            .configuration_sha256 = initialChainSha256(
                config,
                @intCast(owners.len),
                @intCast(followers.len),
            ),
            .initialized = true,
            .event_chain_sha256 = initialChainSha256(
                config,
                @intCast(owners.len),
                @intCast(followers.len),
            ),
        };
    }

    pub fn admit(self: *Gateway, request: RequestV1) Error!AdmissionV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        if (!requestValidV1(request)) return Error.InvalidRequest;

        for (self.owners, 0..) |*owner, index| {
            if (owner.state == .free or
                !sameLogicalRequest(owner.request, request)) continue;
            if (!std.mem.eql(
                u8,
                &owner.request.request_sha256,
                &request.request_sha256,
            )) return Error.RequestConflict;
            if (owner.owner_acknowledged)
                return Error.RequestAlreadyAcknowledged;
            return .{
                .kind = .existing,
                .handle = self.ownerHandle(@intCast(index), owner.*),
                .dispatch_key_sha256 = owner.dispatch_key_sha256,
                .event = null,
            };
        }
        for (self.followers, 0..) |*follower, index| {
            if ((!follower.active and !follower.acknowledged and
                !follower.cancelled) or
                !sameLogicalRequest(follower.request, request)) continue;
            if (!std.mem.eql(
                u8,
                &follower.request.request_sha256,
                &request.request_sha256,
            )) return Error.RequestConflict;
            if (follower.acknowledged)
                return Error.RequestAlreadyAcknowledged;
            if (follower.cancelled) return Error.RequestCancelled;
            return .{
                .kind = .existing,
                .handle = self.followerHandle(@intCast(index), follower.*),
                .dispatch_key_sha256 = dispatchKeySha256(request),
                .event = null,
            };
        }

        const dispatch_key = dispatchKeySha256(request);
        if (request.reuse_policy == .in_flight) {
            for (self.owners, 0..) |*owner, owner_index| {
                if ((owner.state != .ready and owner.state != .dispatched) or
                    owner.request.reuse_policy != .in_flight or
                    !std.mem.eql(
                        u8,
                        &owner.dispatch_key_sha256,
                        &dispatch_key,
                    )) continue;
                if (owner.follower_count >=
                    self.config.limits.max_followers_per_owner)
                    return Error.CapacityExceeded;
                const follower_index = self.freeFollowerIndex() orelse
                    return Error.CapacityExceeded;
                const follower = &self.followers[follower_index];
                const generation = try nextGeneration(follower.generation);
                const request_set_count = std.math.add(
                    u32,
                    owner.request_set_count,
                    1,
                ) catch return Error.SequenceExhausted;
                const request_set_sha256 = appendRequestSetSha256(
                    owner.request_set_sha256,
                    owner.request_set_count,
                    request.request_sha256,
                );
                var after = self.ledger;
                after.active_handles = try addU64(after.active_handles, 1);
                after.coalesced_requests = try addU64(
                    after.coalesced_requests,
                    1,
                );
                const event = try self.buildEvent(.{
                    .kind = .follower_coalesced,
                    .owner_slot_index = @intCast(owner_index),
                    .owner_generation = owner.generation,
                    .request_sha256 = request.request_sha256,
                    .dispatch_key_sha256 = dispatch_key,
                    .request_set_count = request_set_count,
                    .request_set_sha256 = request_set_sha256,
                    .reservation_tokens = owner.reserved_tokens,
                    .after = after,
                });

                follower.* = .{
                    .generation = generation,
                    .active = true,
                    .owner_slot_index = @intCast(owner_index),
                    .owner_generation = owner.generation,
                    .request = request,
                };
                owner.follower_count += 1;
                owner.live_follower_handles += 1;
                owner.request_set_count = request_set_count;
                owner.request_set_sha256 = request_set_sha256;
                self.commitEvent(event);
                return .{
                    .kind = .coalesced,
                    .handle = self.followerHandle(
                        @intCast(follower_index),
                        follower.*,
                    ),
                    .dispatch_key_sha256 = dispatch_key,
                    .event = event,
                };
            }
        }

        const reserved_tokens = std.math.add(
            u64,
            request.input_token_estimate,
            request.max_output_tokens,
        ) catch return Error.BudgetExceeded;
        if (reserved_tokens > self.config.limits.max_request_tokens)
            return Error.BudgetExceeded;
        const global_reserved = std.math.add(
            u64,
            self.ledger.reserved_tokens,
            reserved_tokens,
        ) catch return Error.BudgetExceeded;
        if (global_reserved > self.config.limits.max_reserved_tokens)
            return Error.BudgetExceeded;
        const isolation_reserved = std.math.add(
            u64,
            self.reservedForIsolation(request.isolation_key),
            reserved_tokens,
        ) catch return Error.BudgetExceeded;
        if (isolation_reserved >
            self.config.limits.max_reserved_tokens_per_isolation)
            return Error.BudgetExceeded;
        const owner_index = self.freeOwnerIndex() orelse
            return Error.CapacityExceeded;
        const owner = &self.owners[owner_index];
        const generation = try nextGeneration(owner.generation);
        const request_set_sha256 = appendRequestSetSha256(
            zero_digest,
            0,
            request.request_sha256,
        );
        var after = self.ledger;
        after.reserved_tokens = global_reserved;
        after.active_handles = try addU64(after.active_handles, 1);
        after.ready_owners = try addU64(after.ready_owners, 1);
        const event = try self.buildEvent(.{
            .kind = .owner_admitted,
            .owner_slot_index = @intCast(owner_index),
            .owner_generation = generation,
            .request_sha256 = request.request_sha256,
            .dispatch_key_sha256 = dispatch_key,
            .request_set_count = 1,
            .request_set_sha256 = request_set_sha256,
            .reservation_tokens = reserved_tokens,
            .after = after,
        });

        owner.* = .{
            .generation = generation,
            .state = .ready,
            .request = request,
            .dispatch_key_sha256 = dispatch_key,
            .reserved_tokens = reserved_tokens,
            .request_set_count = 1,
            .request_set_sha256 = request_set_sha256,
        };
        self.commitEvent(event);
        return .{
            .kind = .owner,
            .handle = self.ownerHandle(@intCast(owner_index), owner.*),
            .dispatch_key_sha256 = dispatch_key,
            .event = event,
        };
    }

    pub fn beginDispatch(
        self: *Gateway,
        handle: RequestHandleV1,
    ) Error!DispatchStartV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const owner = try self.validateOwnerHandle(handle);
        if (owner.state != .ready) return Error.InvalidState;
        const attempt_generation = owner.next_attempt_generation;
        if (attempt_generation == 0 or
            attempt_generation == std.math.maxInt(u64))
            return Error.SequenceExhausted;
        var intent: DispatchIntentV1 = .{
            .gateway_epoch = self.config.gateway_epoch,
            .owner_slot_index = handle.owner_slot_index,
            .owner_generation = handle.owner_generation,
            .attempt_generation = attempt_generation,
            .request_sha256 = owner.request.request_sha256,
            .dispatch_key_sha256 = owner.dispatch_key_sha256,
            .reserved_tokens = owner.reserved_tokens,
            .previous_event_chain_sha256 = self.event_chain_sha256,
        };
        intent.intent_sha256 = dispatchIntentSha256(intent);
        var permit: DispatchPermitV1 = .{
            .gateway_id = @intFromPtr(self),
            .intent = intent,
        };
        permit.integrity_sha256 = dispatchPermitSha256(
            permit,
            self.config.challenge,
        );
        var after = self.ledger;
        after.ready_owners = try subU64(after.ready_owners, 1);
        after.dispatched_owners = try addU64(after.dispatched_owners, 1);
        after.physical_dispatches = try addU64(
            after.physical_dispatches,
            1,
        );
        const event = try self.buildEvent(.{
            .kind = .dispatch_started,
            .owner_slot_index = handle.owner_slot_index,
            .owner_generation = handle.owner_generation,
            .attempt_generation = attempt_generation,
            .request_sha256 = owner.request.request_sha256,
            .dispatch_key_sha256 = owner.dispatch_key_sha256,
            .intent_sha256 = intent.intent_sha256,
            .request_set_count = owner.request_set_count,
            .request_set_sha256 = owner.request_set_sha256,
            .reservation_tokens = owner.reserved_tokens,
            .after = after,
        });

        owner.state = .dispatched;
        owner.active_intent = intent;
        owner.active_permit_sha256 = permit.integrity_sha256;
        owner.next_attempt_generation += 1;
        self.commitEvent(event);
        return .{ .intent = intent, .permit = permit, .event = event };
    }

    pub fn retryNoCharge(
        self: *Gateway,
        permit: DispatchPermitV1,
        usage: UsageV1,
    ) Error!AttemptResultV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const owner = try self.validatePermit(permit, .dispatched);
        if (!usageValidV1(usage) or !usage.billable_tokens.known or
            usage.billable_tokens.value != 0)
            return Error.InvalidUsage;
        var after = self.ledger;
        after.dispatched_owners = try subU64(after.dispatched_owners, 1);
        after.ready_owners = try addU64(after.ready_owners, 1);
        after.retryable_attempts = try addU64(after.retryable_attempts, 1);
        const result = try self.buildAttemptResult(
            owner,
            .retryable_no_charge,
            usage,
            zero_digest,
            .retryable_no_charge,
            after,
        );
        owner.state = .ready;
        owner.active_intent = .{};
        owner.active_permit_sha256 = zero_digest;
        owner.last_receipt = result.receipt;
        self.commitEvent(result.event);
        return result;
    }

    pub fn markAmbiguous(
        self: *Gateway,
        permit: DispatchPermitV1,
        usage: UsageV1,
    ) Error!AttemptResultV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const owner = try self.validatePermit(permit, .dispatched);
        if (!usageValidV1(usage))
            return Error.InvalidUsage;
        var after = self.ledger;
        after.dispatched_owners = try subU64(after.dispatched_owners, 1);
        after.ambiguous_owners = try addU64(after.ambiguous_owners, 1);
        after.ambiguous_attempts = try addU64(after.ambiguous_attempts, 1);
        const result = try self.buildAttemptResult(
            owner,
            .ambiguous,
            usage,
            zero_digest,
            .ambiguous,
            after,
        );
        owner.state = .ambiguous;
        owner.last_receipt = result.receipt;
        self.commitEvent(result.event);
        return result;
    }

    pub fn settleSuccess(
        self: *Gateway,
        permit: DispatchPermitV1,
        usage: UsageV1,
        result_sha256: Digest,
    ) Error!AttemptResultV2 {
        return self.settleTerminal(
            permit,
            usage,
            result_sha256,
            .dispatched,
            .succeeded,
            .succeeded,
        );
    }

    pub fn settleFailure(
        self: *Gateway,
        permit: DispatchPermitV1,
        usage: UsageV1,
    ) Error!AttemptResultV2 {
        return self.settleTerminal(
            permit,
            usage,
            zero_digest,
            .dispatched,
            .failed,
            .failed,
        );
    }

    pub fn resolveAmbiguousSuccess(
        self: *Gateway,
        permit: DispatchPermitV1,
        usage: UsageV1,
        result_sha256: Digest,
    ) Error!AttemptResultV2 {
        return self.settleTerminal(
            permit,
            usage,
            result_sha256,
            .ambiguous,
            .resolved_success,
            .succeeded,
        );
    }

    pub fn resolveAmbiguousFailure(
        self: *Gateway,
        permit: DispatchPermitV1,
        usage: UsageV1,
    ) Error!AttemptResultV2 {
        return self.settleTerminal(
            permit,
            usage,
            zero_digest,
            .ambiguous,
            .resolved_failure,
            .failed,
        );
    }

    pub fn poll(self: *Gateway, handle: RequestHandleV1) Error!StatusV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const owner = try self.ownerForHandle(handle);
        return switch (owner.state) {
            .free => Error.InvalidHandle,
            .ready, .dispatched => .{ .pending = .{
                .owner_state = owner.state,
                .next_attempt_generation = owner.next_attempt_generation,
            } },
            .ambiguous => .{ .ambiguous = owner.last_receipt },
            .succeeded => .{ .succeeded = owner.last_receipt },
            .failed => .{ .failed = owner.last_receipt },
        };
    }

    /// Cancels one logical consumer. A follower never cancels shared physical
    /// work. The owner may cancel only while ready and after every follower has
    /// independently cancelled, which guarantees that no active dispatch or
    /// remaining consumer loses work.
    pub fn cancel(
        self: *Gateway,
        handle: RequestHandleV1,
    ) Error!EventV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const owner = try self.ownerForHandle(handle);

        if (handle.kind == .owner) {
            if (owner.state != .ready or owner.live_follower_handles != 0)
                return Error.InvalidState;
            var after = self.ledger;
            after.reserved_tokens = try subU64(
                after.reserved_tokens,
                owner.reserved_tokens,
            );
            after.active_handles = try subU64(after.active_handles, 1);
            after.ready_owners = try subU64(after.ready_owners, 1);
            after.cancelled_handles = try addU64(
                after.cancelled_handles,
                1,
            );
            after.cancelled_ready_owners = try addU64(
                after.cancelled_ready_owners,
                1,
            );
            const event = try self.buildEvent(.{
                .kind = .owner_cancelled,
                .owner_slot_index = handle.owner_slot_index,
                .owner_generation = handle.owner_generation,
                .request_sha256 = handle.request_sha256,
                .dispatch_key_sha256 = owner.dispatch_key_sha256,
                .request_set_count = owner.request_set_count,
                .request_set_sha256 = owner.request_set_sha256,
                .reservation_tokens = owner.reserved_tokens,
                .after = after,
            });
            self.clearOwnerGroup(
                handle.owner_slot_index,
                handle.owner_generation,
            );
            self.commitEvent(event);
            return event;
        }

        var after = self.ledger;
        after.active_handles = try subU64(after.active_handles, 1);
        after.cancelled_handles = try addU64(after.cancelled_handles, 1);
        after.cancelled_followers = try addU64(
            after.cancelled_followers,
            1,
        );
        const has_active_intent = dispatchIntentValidV1(owner.active_intent);
        const event = try self.buildEvent(.{
            .kind = .follower_cancelled,
            .owner_slot_index = handle.owner_slot_index,
            .owner_generation = handle.owner_generation,
            .attempt_generation = if (has_active_intent)
                owner.active_intent.attempt_generation
            else
                0,
            .request_sha256 = handle.request_sha256,
            .dispatch_key_sha256 = owner.dispatch_key_sha256,
            .intent_sha256 = if (has_active_intent)
                owner.active_intent.intent_sha256
            else
                zero_digest,
            .request_set_count = owner.request_set_count,
            .request_set_sha256 = owner.request_set_sha256,
            .reservation_tokens = owner.reserved_tokens,
            .after = after,
        });

        const follower = &self.followers[handle.slot_index];
        follower.active = false;
        follower.cancelled = true;
        owner.live_follower_handles -= 1;
        if (owner.state == .succeeded or owner.state == .failed) {
            owner.pending_acknowledgements -= 1;
            if (owner.pending_acknowledgements == 0)
                self.clearOwnerGroup(
                    handle.owner_slot_index,
                    handle.owner_generation,
                );
        }
        self.commitEvent(event);
        return event;
    }

    pub fn acknowledge(
        self: *Gateway,
        handle: RequestHandleV1,
    ) Error!EventV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const owner = try self.ownerForHandle(handle);
        if (owner.state != .succeeded and owner.state != .failed)
            return Error.InvalidState;
        if (handle.kind == .owner and owner.owner_acknowledged)
            return Error.RequestAlreadyAcknowledged;
        var after = self.ledger;
        after.active_handles = try subU64(after.active_handles, 1);
        after.acknowledged_handles = try addU64(
            after.acknowledged_handles,
            1,
        );
        const event = try self.buildEvent(.{
            .kind = .acknowledged,
            .owner_slot_index = handle.owner_slot_index,
            .owner_generation = handle.owner_generation,
            .attempt_generation = owner.last_receipt.intent.attempt_generation,
            .request_sha256 = handle.request_sha256,
            .dispatch_key_sha256 = owner.dispatch_key_sha256,
            .intent_sha256 = owner.last_receipt.intent.intent_sha256,
            .usage_sha256 = owner.last_receipt.usage.usage_sha256,
            .result_sha256 = owner.last_receipt.result_sha256,
            .request_set_count = owner.request_set_count,
            .request_set_sha256 = owner.request_set_sha256,
            .reservation_tokens = owner.reserved_tokens,
            .billable_tokens = owner.last_receipt.usage.billable_tokens.value,
            .after = after,
        });

        owner.pending_acknowledgements -= 1;
        if (handle.kind == .owner) {
            owner.owner_acknowledged = true;
        } else {
            const follower = &self.followers[handle.slot_index];
            follower.active = false;
            follower.acknowledged = true;
            owner.live_follower_handles -= 1;
        }
        if (owner.pending_acknowledgements == 0) {
            self.clearOwnerGroup(
                handle.owner_slot_index,
                handle.owner_generation,
            );
        }
        self.commitEvent(event);
        return event;
    }

    pub fn snapshot(self: *Gateway) Error!SnapshotV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        return self.snapshotLocked();
    }

    pub fn close(self: *Gateway) Error!SnapshotV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        if (self.ledger.active_handles != 0 or
            self.ledger.reserved_tokens != 0 or
            self.ledger.ready_owners != 0 or
            self.ledger.dispatched_owners != 0 or
            self.ledger.ambiguous_owners != 0)
            return Error.InvalidState;
        for (self.owners) |owner|
            if (owner.state != .free) return Error.StateDrift;
        for (self.followers) |follower|
            if (follower.active or follower.acknowledged or
                follower.cancelled)
                return Error.StateDrift;
        const final_snapshot = self.snapshotLocked();
        self.initialized = false;
        return final_snapshot;
    }

    fn settleTerminal(
        self: *Gateway,
        permit: DispatchPermitV1,
        usage: UsageV1,
        result_sha256: Digest,
        source_state: OwnerState,
        outcome: AttemptOutcome,
        terminal_state: OwnerState,
    ) Error!AttemptResultV2 {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireOpenAndValid();
        const owner = try self.validatePermit(permit, source_state);
        if (!usageValidV1(usage) or !usage.billable_tokens.known or
            ((terminal_state == .succeeded) == isZero(result_sha256)))
            return Error.InvalidUsage;
        const pending_acknowledgements = std.math.add(
            u32,
            owner.live_follower_handles,
            1,
        ) catch return Error.SequenceExhausted;
        var after = self.ledger;
        after.reserved_tokens = try subU64(
            after.reserved_tokens,
            owner.reserved_tokens,
        );
        after.settled_billable_tokens = try addU64(
            after.settled_billable_tokens,
            usage.billable_tokens.value,
        );
        if (usage.billable_tokens.value > owner.reserved_tokens) {
            after.budget_overrun_tokens = try addU64(
                after.budget_overrun_tokens,
                usage.billable_tokens.value - owner.reserved_tokens,
            );
            after.budget_overrun_dispatches = try addU64(
                after.budget_overrun_dispatches,
                1,
            );
        }
        switch (source_state) {
            .dispatched => after.dispatched_owners = try subU64(
                after.dispatched_owners,
                1,
            ),
            .ambiguous => after.ambiguous_owners = try subU64(
                after.ambiguous_owners,
                1,
            ),
            else => return Error.InvalidState,
        }
        if (terminal_state == .succeeded) {
            after.successful_dispatches = try addU64(
                after.successful_dispatches,
                1,
            );
        } else {
            after.failed_dispatches = try addU64(
                after.failed_dispatches,
                1,
            );
        }
        const result = try self.buildAttemptResult(
            owner,
            outcome,
            usage,
            result_sha256,
            eventKindForOutcome(outcome),
            after,
        );
        owner.state = terminal_state;
        owner.pending_acknowledgements = pending_acknowledgements;
        owner.active_permit_sha256 = zero_digest;
        owner.last_receipt = result.receipt;
        self.commitEvent(result.event);
        return result;
    }

    fn buildAttemptResult(
        self: *Gateway,
        owner: *OwnerSlot,
        outcome: AttemptOutcome,
        usage: UsageV1,
        result_sha256: Digest,
        event_kind: EventKind,
        after: LedgerV2,
    ) Error!AttemptResultV2 {
        const event = try self.buildEvent(.{
            .kind = event_kind,
            .owner_slot_index = owner.active_intent.owner_slot_index,
            .owner_generation = owner.generation,
            .attempt_generation = owner.active_intent.attempt_generation,
            .request_sha256 = owner.request.request_sha256,
            .dispatch_key_sha256 = owner.dispatch_key_sha256,
            .intent_sha256 = owner.active_intent.intent_sha256,
            .usage_sha256 = usage.usage_sha256,
            .result_sha256 = result_sha256,
            .request_set_count = owner.request_set_count,
            .request_set_sha256 = owner.request_set_sha256,
            .reservation_tokens = owner.reserved_tokens,
            .billable_tokens = if (usage.billable_tokens.known)
                usage.billable_tokens.value
            else
                0,
            .after = after,
        });
        var receipt: AttemptReceiptV1 = .{
            .outcome = outcome,
            .intent = owner.active_intent,
            .usage = usage,
            .result_sha256 = result_sha256,
            .request_set_count = owner.request_set_count,
            .request_set_sha256 = owner.request_set_sha256,
            .event_sha256 = event.event_sha256,
        };
        receipt.receipt_sha256 = attemptReceiptSha256(receipt);
        return .{ .receipt = receipt, .event = event };
    }

    fn requireOpenAndValid(self: *Gateway) Error!void {
        if (!self.initialized) return Error.InvalidState;
        if (self.gateway_id != @intFromPtr(self)) return Error.StateDrift;
        try self.validateInternal();
    }

    fn validateInternal(self: *Gateway) Error!void {
        if (!configValid(self.config) or self.owner_capacity == 0 or
            self.owners.len != @as(usize, self.owner_capacity) or
            self.followers.len != @as(usize, self.follower_capacity) or
            self.owner_storage_id != @intFromPtr(self.owners.ptr) or
            self.follower_storage_id != @intFromPtr(self.followers.ptr) or
            storageOverlaps(self, self.owners, self.followers) or
            !std.mem.eql(
                u8,
                &self.configuration_sha256,
                &initialChainSha256(
                    self.config,
                    self.owner_capacity,
                    self.follower_capacity,
                ),
            ) or isZero(self.event_chain_sha256)) return Error.StateDrift;

        var derived_reserved: u64 = 0;
        var derived_active_handles: u64 = 0;
        var derived_ready: u64 = 0;
        var derived_dispatched: u64 = 0;
        var derived_ambiguous: u64 = 0;
        for (self.owners, 0..) |*owner, owner_index| {
            if (owner.state == .free) {
                const generation = owner.generation;
                if (!std.meta.eql(owner.*, OwnerSlot{
                    .generation = generation,
                })) return Error.StateDrift;
                continue;
            }
            const expected_reservation = std.math.add(
                u64,
                owner.request.input_token_estimate,
                owner.request.max_output_tokens,
            ) catch return Error.StateDrift;
            const expected_request_count = std.math.add(
                u32,
                owner.follower_count,
                1,
            ) catch return Error.StateDrift;
            if (!requestValidV1(owner.request) or
                !std.mem.eql(
                    u8,
                    &owner.dispatch_key_sha256,
                    &dispatchKeySha256(owner.request),
                ) or owner.generation == 0 or owner.request_set_count == 0 or
                isZero(owner.request_set_sha256) or
                owner.reserved_tokens != expected_reservation or
                owner.reserved_tokens > self.config.limits.max_request_tokens or
                owner.request_set_count != expected_request_count or
                owner.follower_count >
                    self.config.limits.max_followers_per_owner or
                owner.live_follower_handles > owner.follower_count)
                return Error.StateDrift;

            var derived_live_followers: u32 = 0;
            var derived_total_followers: u32 = 0;
            for (self.followers) |follower| {
                if ((follower.active or follower.acknowledged or
                    follower.cancelled) and
                    follower.owner_slot_index == owner_index and
                    follower.owner_generation == owner.generation)
                {
                    derived_total_followers = std.math.add(
                        u32,
                        derived_total_followers,
                        1,
                    ) catch return Error.StateDrift;
                    if (follower.active)
                        derived_live_followers = std.math.add(
                            u32,
                            derived_live_followers,
                            1,
                        ) catch return Error.StateDrift;
                }
            }
            if (derived_live_followers != owner.live_follower_handles or
                derived_total_followers != owner.follower_count)
                return Error.StateDrift;
            if (!owner.owner_acknowledged)
                derived_active_handles = try addU64(derived_active_handles, 1);
            switch (owner.state) {
                .free => unreachable,
                .ready => {
                    if (owner.pending_acknowledgements != 0 or
                        owner.owner_acknowledged or
                        !std.meta.eql(
                            owner.active_intent,
                            DispatchIntentV1{},
                        ) or !isZero(owner.active_permit_sha256) or
                        (owner.next_attempt_generation == 1 and
                            !std.meta.eql(
                                owner.last_receipt,
                                AttemptReceiptV1{},
                            )) or
                        (owner.next_attempt_generation > 1 and
                            (!attemptReceiptValidV1(owner.last_receipt) or
                                owner.last_receipt.outcome !=
                                    .retryable_no_charge)))
                        return Error.StateDrift;
                    derived_ready = try addU64(derived_ready, 1);
                    derived_reserved = try addU64(
                        derived_reserved,
                        owner.reserved_tokens,
                    );
                },
                .dispatched => {
                    const next_attempt = std.math.add(
                        u64,
                        owner.active_intent.attempt_generation,
                        1,
                    ) catch return Error.StateDrift;
                    if (owner.pending_acknowledgements != 0 or
                        owner.owner_acknowledged or
                        next_attempt != owner.next_attempt_generation)
                        return Error.StateDrift;
                    derived_dispatched = try addU64(derived_dispatched, 1);
                    derived_reserved = try addU64(
                        derived_reserved,
                        owner.reserved_tokens,
                    );
                    if (!dispatchIntentValidV1(owner.active_intent) or
                        isZero(owner.active_permit_sha256))
                        return Error.StateDrift;
                },
                .ambiguous => {
                    if (owner.pending_acknowledgements != 0 or
                        owner.owner_acknowledged or
                        isZero(owner.active_permit_sha256))
                        return Error.StateDrift;
                    derived_ambiguous = try addU64(derived_ambiguous, 1);
                    derived_reserved = try addU64(
                        derived_reserved,
                        owner.reserved_tokens,
                    );
                    if (!attemptReceiptValidV1(owner.last_receipt) or
                        owner.last_receipt.outcome != .ambiguous or
                        !std.meta.eql(
                            owner.last_receipt.intent,
                            owner.active_intent,
                        ))
                        return Error.StateDrift;
                },
                .succeeded, .failed => {
                    const expected_pending = std.math.add(
                        u32,
                        owner.live_follower_handles,
                        @as(u32, @intFromBool(!owner.owner_acknowledged)),
                    ) catch return Error.StateDrift;
                    if (!attemptReceiptValidV1(owner.last_receipt) or
                        owner.pending_acknowledgements == 0 or
                        owner.pending_acknowledgements != expected_pending or
                        !isZero(owner.active_permit_sha256) or
                        !std.meta.eql(
                            owner.last_receipt.intent,
                            owner.active_intent,
                        ) or
                        (owner.state == .succeeded and
                            owner.last_receipt.outcome != .succeeded and
                            owner.last_receipt.outcome != .resolved_success) or
                        (owner.state == .failed and
                            owner.last_receipt.outcome != .failed and
                            owner.last_receipt.outcome != .resolved_failure))
                        return Error.StateDrift;
                },
            }
            if ((owner.state == .ready or owner.state == .dispatched or
                owner.state == .ambiguous) and
                self.reservedForIsolation(owner.request.isolation_key) >
                    self.config.limits.max_reserved_tokens_per_isolation)
                return Error.StateDrift;
        }
        for (self.followers) |follower| {
            const disposition_count: u2 =
                @as(u2, @intFromBool(follower.active)) +
                @as(u2, @intFromBool(follower.acknowledged)) +
                @as(u2, @intFromBool(follower.cancelled));
            if (disposition_count > 1) return Error.StateDrift;
            if (disposition_count == 0) {
                const generation = follower.generation;
                if (!std.meta.eql(follower, FollowerSlot{
                    .generation = generation,
                })) return Error.StateDrift;
                continue;
            }
            if (!requestValidV1(follower.request) or
                follower.owner_slot_index >= self.owners.len)
                return Error.StateDrift;
            const owner = self.owners[follower.owner_slot_index];
            if (owner.state == .free or
                owner.generation != follower.owner_generation or
                (follower.acknowledged and
                    owner.state != .succeeded and owner.state != .failed) or
                follower.request.reuse_policy != .in_flight or
                !std.mem.eql(
                    u8,
                    &dispatchKeySha256(follower.request),
                    &owner.dispatch_key_sha256,
                ))
                return Error.StateDrift;
            if (follower.active)
                derived_active_handles = try addU64(
                    derived_active_handles,
                    1,
                );
        }
        if (derived_reserved != self.ledger.reserved_tokens or
            derived_active_handles != self.ledger.active_handles or
            derived_ready != self.ledger.ready_owners or
            derived_dispatched != self.ledger.dispatched_owners or
            derived_ambiguous != self.ledger.ambiguous_owners)
            return Error.StateDrift;
    }

    fn validateOwnerHandle(
        self: *Gateway,
        handle: RequestHandleV1,
    ) Error!*OwnerSlot {
        if (handle.kind != .owner or !self.handleIntegrityValid(handle) or
            handle.slot_index != handle.owner_slot_index or
            handle.slot_index >= self.owners.len)
            return Error.InvalidHandle;
        const owner = &self.owners[handle.slot_index];
        if (owner.state == .free or owner.generation != handle.generation or
            owner.generation != handle.owner_generation or
            !std.mem.eql(
                u8,
                &owner.request.request_sha256,
                &handle.request_sha256,
            )) return Error.InvalidHandle;
        return owner;
    }

    fn ownerForHandle(
        self: *Gateway,
        handle: RequestHandleV1,
    ) Error!*OwnerSlot {
        if (!self.handleIntegrityValid(handle) or
            handle.owner_slot_index >= self.owners.len)
            return Error.InvalidHandle;
        if (handle.kind == .owner) return self.validateOwnerHandle(handle);
        if (handle.slot_index >= self.followers.len)
            return Error.InvalidHandle;
        const follower = &self.followers[handle.slot_index];
        if (!follower.active or follower.generation != handle.generation or
            follower.owner_slot_index != handle.owner_slot_index or
            follower.owner_generation != handle.owner_generation or
            !std.mem.eql(
                u8,
                &follower.request.request_sha256,
                &handle.request_sha256,
            )) return Error.InvalidHandle;
        const owner = &self.owners[handle.owner_slot_index];
        if (owner.state == .free or
            owner.generation != handle.owner_generation)
            return Error.InvalidHandle;
        return owner;
    }

    fn validatePermit(
        self: *Gateway,
        permit: DispatchPermitV1,
        expected_state: OwnerState,
    ) Error!*OwnerSlot {
        if (permit.abi_version != dispatch_permit_abi or
            permit.gateway_id != @intFromPtr(self) or
            !dispatchIntentValidV1(permit.intent) or
            permit.intent.gateway_epoch != self.config.gateway_epoch or
            permit.intent.owner_slot_index >= self.owners.len or
            !std.mem.eql(
                u8,
                &permit.integrity_sha256,
                &dispatchPermitSha256(permit, self.config.challenge),
            )) return Error.InvalidPermit;
        const owner = &self.owners[permit.intent.owner_slot_index];
        if (owner.state != expected_state or
            owner.generation != permit.intent.owner_generation or
            !std.meta.eql(owner.active_intent, permit.intent) or
            !std.mem.eql(
                u8,
                &owner.active_permit_sha256,
                &permit.integrity_sha256,
            )) return Error.InvalidPermit;
        return owner;
    }

    fn ownerHandle(
        self: *Gateway,
        index: u32,
        owner: OwnerSlot,
    ) RequestHandleV1 {
        var handle: RequestHandleV1 = .{
            .gateway_epoch = self.config.gateway_epoch,
            .gateway_id = @intFromPtr(self),
            .kind = .owner,
            .slot_index = index,
            .generation = owner.generation,
            .owner_slot_index = index,
            .owner_generation = owner.generation,
            .request_sha256 = owner.request.request_sha256,
        };
        handle.integrity_sha256 = handleSha256(handle, self.config.challenge);
        return handle;
    }

    fn followerHandle(
        self: *Gateway,
        index: u32,
        follower: FollowerSlot,
    ) RequestHandleV1 {
        var handle: RequestHandleV1 = .{
            .gateway_epoch = self.config.gateway_epoch,
            .gateway_id = @intFromPtr(self),
            .kind = .follower,
            .slot_index = index,
            .generation = follower.generation,
            .owner_slot_index = follower.owner_slot_index,
            .owner_generation = follower.owner_generation,
            .request_sha256 = follower.request.request_sha256,
        };
        handle.integrity_sha256 = handleSha256(handle, self.config.challenge);
        return handle;
    }

    fn handleIntegrityValid(
        self: *Gateway,
        handle: RequestHandleV1,
    ) bool {
        return handle.abi_version == handle_abi and
            handle.gateway_epoch == self.config.gateway_epoch and
            handle.gateway_id == @intFromPtr(self) and handle.generation != 0 and
            handle.owner_generation != 0 and !isZero(handle.request_sha256) and
            std.mem.eql(
                u8,
                &handle.integrity_sha256,
                &handleSha256(handle, self.config.challenge),
            );
    }

    fn freeOwnerIndex(self: *Gateway) ?usize {
        for (self.owners, 0..) |owner, index|
            if (owner.state == .free) return index;
        return null;
    }

    fn clearOwnerGroup(
        self: *Gateway,
        owner_slot_index: u32,
        owner_generation: u64,
    ) void {
        for (self.followers) |*follower| {
            if (follower.owner_slot_index != owner_slot_index or
                follower.owner_generation != owner_generation)
                continue;
            if (follower.active)
                @panic("cannot clear provider-token owner with live follower");
            const follower_generation = follower.generation;
            follower.* = .{ .generation = follower_generation };
        }
        const owner = &self.owners[owner_slot_index];
        const generation = owner.generation;
        owner.* = .{ .generation = generation };
    }

    fn freeFollowerIndex(self: *Gateway) ?usize {
        for (self.followers, 0..) |follower, index|
            if (!follower.active and !follower.acknowledged and
                !follower.cancelled) return index;
        return null;
    }

    fn reservedForIsolation(self: *Gateway, isolation_key: u64) u64 {
        var total: u64 = 0;
        for (self.owners) |owner| {
            if ((owner.state == .ready or owner.state == .dispatched or
                owner.state == .ambiguous) and
                owner.request.isolation_key == isolation_key)
                total = std.math.add(u64, total, owner.reserved_tokens) catch
                    return std.math.maxInt(u64);
        }
        return total;
    }

    fn snapshotLocked(self: *Gateway) SnapshotV2 {
        return .{
            .gateway_epoch = self.config.gateway_epoch,
            .limits = self.config.limits,
            .owner_capacity = self.owner_capacity,
            .follower_capacity = self.follower_capacity,
            .next_event_sequence = self.next_event_sequence,
            .ledger = self.ledger,
            .event_chain_sha256 = self.event_chain_sha256,
        };
    }

    const EventInput = struct {
        kind: EventKind,
        owner_slot_index: u32,
        owner_generation: u64,
        attempt_generation: u64 = 0,
        request_sha256: Digest,
        dispatch_key_sha256: Digest,
        intent_sha256: Digest = zero_digest,
        usage_sha256: Digest = zero_digest,
        result_sha256: Digest = zero_digest,
        request_set_count: u32,
        request_set_sha256: Digest,
        reservation_tokens: u64,
        billable_tokens: u64 = 0,
        after: LedgerV2,
    };

    fn buildEvent(self: *Gateway, input: EventInput) Error!EventV2 {
        if (self.next_event_sequence == std.math.maxInt(u64))
            return Error.SequenceExhausted;
        var event: EventV2 = .{
            .gateway_epoch = self.config.gateway_epoch,
            .sequence = self.next_event_sequence,
            .kind = input.kind,
            .owner_slot_index = input.owner_slot_index,
            .owner_generation = input.owner_generation,
            .attempt_generation = input.attempt_generation,
            .request_sha256 = input.request_sha256,
            .dispatch_key_sha256 = input.dispatch_key_sha256,
            .intent_sha256 = input.intent_sha256,
            .usage_sha256 = input.usage_sha256,
            .result_sha256 = input.result_sha256,
            .request_set_count = input.request_set_count,
            .request_set_sha256 = input.request_set_sha256,
            .reservation_tokens = input.reservation_tokens,
            .billable_tokens = input.billable_tokens,
            .before = self.ledger,
            .after = input.after,
            .previous_chain_sha256 = self.event_chain_sha256,
        };
        event.event_sha256 = eventSha256(event);
        if (!eventValidV2(event)) return Error.InvalidState;
        return event;
    }

    fn commitEvent(self: *Gateway, event: EventV2) void {
        if (!std.meta.eql(self.ledger, event.before) or
            self.next_event_sequence != event.sequence or
            !std.mem.eql(
                u8,
                &self.event_chain_sha256,
                &event.previous_chain_sha256,
            )) @panic("invalid prepared provider-token event");
        self.ledger = event.after;
        self.next_event_sequence += 1;
        self.event_chain_sha256 = event.event_sha256;
    }
};

pub const VerifierV2 = struct {
    config: ConfigV1,
    owner_capacity: u32,
    follower_capacity: u32,
    next_event_sequence: u64 = 0,
    ledger: LedgerV2 = .{},
    event_chain_sha256: Digest,

    pub fn init(
        config: ConfigV1,
        owner_capacity: u32,
        follower_capacity: u32,
    ) Error!VerifierV2 {
        if (!configValid(config) or owner_capacity == 0)
            return Error.InvalidConfiguration;
        return .{
            .config = config,
            .owner_capacity = owner_capacity,
            .follower_capacity = follower_capacity,
            .event_chain_sha256 = initialChainSha256(
                config,
                owner_capacity,
                follower_capacity,
            ),
        };
    }

    pub fn apply(self: *VerifierV2, event: EventV2) Error!void {
        const total_capacity = std.math.add(
            u64,
            self.owner_capacity,
            self.follower_capacity,
        ) catch return Error.StateDrift;
        const live_owner_states = addChecked(
            event.after.ready_owners,
            event.after.dispatched_owners,
        ) orelse return Error.StateDrift;
        const live_owner_states_with_ambiguous = addChecked(
            live_owner_states,
            event.after.ambiguous_owners,
        ) orelse return Error.StateDrift;
        const maximum_request_set_count: u64 =
            @as(u64, self.config.limits.max_followers_per_owner) + 1;
        if (!eventValidV2(event) or
            event.gateway_epoch != self.config.gateway_epoch or
            event.owner_slot_index >= self.owner_capacity or
            event.reservation_tokens > self.config.limits.max_request_tokens or
            event.request_set_count > maximum_request_set_count or
            event.after.reserved_tokens >
                self.config.limits.max_reserved_tokens or
            event.after.active_handles > total_capacity or
            live_owner_states_with_ambiguous > self.owner_capacity or
            event.sequence != self.next_event_sequence or
            !std.meta.eql(event.before, self.ledger) or
            !std.mem.eql(
                u8,
                &event.previous_chain_sha256,
                &self.event_chain_sha256,
            )) return Error.StateDrift;
        if (self.next_event_sequence == std.math.maxInt(u64))
            return Error.SequenceExhausted;
        self.ledger = event.after;
        self.event_chain_sha256 = event.event_sha256;
        self.next_event_sequence += 1;
    }

    pub fn snapshot(self: *const VerifierV2) SnapshotV2 {
        return .{
            .gateway_epoch = self.config.gateway_epoch,
            .limits = self.config.limits,
            .owner_capacity = self.owner_capacity,
            .follower_capacity = self.follower_capacity,
            .next_event_sequence = self.next_event_sequence,
            .ledger = self.ledger,
            .event_chain_sha256 = self.event_chain_sha256,
        };
    }

    pub fn requireFinal(
        self: *const VerifierV2,
        expected_events: u64,
        expected_ledger: LedgerV2,
        expected_chain_sha256: Digest,
    ) Error!void {
        if (self.next_event_sequence != expected_events or
            !std.meta.eql(self.ledger, expected_ledger) or
            !std.mem.eql(
                u8,
                &self.event_chain_sha256,
                &expected_chain_sha256,
            )) return Error.StateDrift;
    }
};

fn configValid(config: ConfigV1) bool {
    return config.gateway_epoch != 0 and !isZero(config.challenge) and
        config.limits.max_reserved_tokens != 0 and
        config.limits.max_reserved_tokens_per_isolation != 0 and
        config.limits.max_request_tokens != 0 and
        config.limits.max_request_tokens <=
            config.limits.max_reserved_tokens_per_isolation and
        config.limits.max_reserved_tokens_per_isolation <=
            config.limits.max_reserved_tokens;
}

fn sameLogicalRequest(left: RequestV1, right: RequestV1) bool {
    return left.isolation_key == right.isolation_key and
        left.request_key == right.request_key and
        left.request_generation == right.request_generation;
}

fn nextGeneration(current: u64) Error!u64 {
    if (current == std.math.maxInt(u64)) return Error.SequenceExhausted;
    const next = current + 1;
    if (next == 0) return Error.SequenceExhausted;
    return next;
}

fn addU64(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch Error.SequenceExhausted;
}

fn subU64(left: u64, right: u64) Error!u64 {
    return std.math.sub(u64, left, right) catch Error.StateDrift;
}

fn appendRequestSetSha256(
    before_sha256: Digest,
    count_before: u32,
    request_sha256: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(request_set_domain);
    hashU64(&hash, request_abi);
    hash.update(&before_sha256);
    hashU32(&hash, count_before);
    hash.update(&request_sha256);
    return finish(&hash);
}

pub fn dispatchIntentSha256(intent: DispatchIntentV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(intent_domain);
    hashIntent(&hash, intent, false);
    return finish(&hash);
}

pub fn dispatchIntentValidV1(intent: DispatchIntentV1) bool {
    return intent.abi_version == dispatch_intent_abi and
        intent.gateway_epoch != 0 and intent.owner_generation != 0 and
        intent.attempt_generation != 0 and intent.reserved_tokens != 0 and
        !isZero(intent.request_sha256) and
        !isZero(intent.dispatch_key_sha256) and
        !isZero(intent.previous_event_chain_sha256) and std.mem.eql(
        u8,
        &intent.intent_sha256,
        &dispatchIntentSha256(intent),
    );
}

fn dispatchPermitSha256(
    permit: DispatchPermitV1,
    challenge: Digest,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(permit_domain);
    hashU64(&hash, permit.abi_version);
    hashU64(&hash, @intCast(permit.gateway_id));
    hashIntent(&hash, permit.intent, true);
    hash.update(&challenge);
    return finish(&hash);
}

fn handleSha256(handle: RequestHandleV1, challenge: Digest) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(handle_domain);
    hashU64(&hash, handle.abi_version);
    hashU64(&hash, handle.gateway_epoch);
    hashU64(&hash, @intCast(handle.gateway_id));
    hashU8(&hash, @intFromEnum(handle.kind));
    hashU32(&hash, handle.slot_index);
    hashU64(&hash, handle.generation);
    hashU32(&hash, handle.owner_slot_index);
    hashU64(&hash, handle.owner_generation);
    hash.update(&handle.request_sha256);
    hash.update(&challenge);
    return finish(&hash);
}

fn hashIntent(
    hash: *std.crypto.hash.sha2.Sha256,
    intent: DispatchIntentV1,
    include_digest: bool,
) void {
    hashU64(hash, intent.abi_version);
    hashU64(hash, intent.gateway_epoch);
    hashU32(hash, intent.owner_slot_index);
    hashU64(hash, intent.owner_generation);
    hashU64(hash, intent.attempt_generation);
    hash.update(&intent.request_sha256);
    hash.update(&intent.dispatch_key_sha256);
    hashU64(hash, intent.reserved_tokens);
    hash.update(&intent.previous_event_chain_sha256);
    if (include_digest) hash.update(&intent.intent_sha256);
}

pub fn attemptReceiptSha256(receipt: AttemptReceiptV1) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(receipt_domain);
    hashU64(&hash, receipt.abi_version);
    hashU8(&hash, @intFromEnum(receipt.outcome));
    hashIntent(&hash, receipt.intent, true);
    hashUsage(&hash, receipt.usage, true);
    hash.update(&receipt.result_sha256);
    hashU32(&hash, receipt.request_set_count);
    hash.update(&receipt.request_set_sha256);
    hash.update(&receipt.event_sha256);
    return finish(&hash);
}

pub fn attemptReceiptValidV1(receipt: AttemptReceiptV1) bool {
    if (receipt.abi_version != attempt_receipt_abi or
        !dispatchIntentValidV1(receipt.intent) or
        !usageValidV1(receipt.usage) or receipt.request_set_count == 0 or
        isZero(receipt.request_set_sha256) or isZero(receipt.event_sha256))
        return false;
    switch (receipt.outcome) {
        .retryable_no_charge => if (!receipt.usage.billable_tokens.known or
            receipt.usage.billable_tokens.value != 0 or
            !isZero(receipt.result_sha256)) return false,
        .ambiguous => if (!isZero(receipt.result_sha256)) return false,
        .succeeded, .resolved_success => if (!receipt.usage.billable_tokens.known or
            isZero(receipt.result_sha256)) return false,
        .failed, .resolved_failure => if (!receipt.usage.billable_tokens.known or
            !isZero(receipt.result_sha256)) return false,
    }
    return std.mem.eql(
        u8,
        &receipt.receipt_sha256,
        &attemptReceiptSha256(receipt),
    );
}

pub fn eventSha256(event: EventV2) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(event_domain);
    hashU64(&hash, event.abi_version);
    hashU64(&hash, event.gateway_epoch);
    hashU64(&hash, event.sequence);
    hashU8(&hash, @intFromEnum(event.kind));
    hashU32(&hash, event.owner_slot_index);
    hashU64(&hash, event.owner_generation);
    hashU64(&hash, event.attempt_generation);
    hash.update(&event.request_sha256);
    hash.update(&event.dispatch_key_sha256);
    hash.update(&event.intent_sha256);
    hash.update(&event.usage_sha256);
    hash.update(&event.result_sha256);
    hashU32(&hash, event.request_set_count);
    hash.update(&event.request_set_sha256);
    hashU64(&hash, event.reservation_tokens);
    hashU64(&hash, event.billable_tokens);
    hashLedger(&hash, event.before);
    hashLedger(&hash, event.after);
    hash.update(&event.previous_chain_sha256);
    return finish(&hash);
}

pub fn eventValidV2(event: EventV2) bool {
    if (event.abi_version != event_abi or event.gateway_epoch == 0 or
        event.owner_generation == 0 or event.reservation_tokens == 0 or
        event.request_set_count == 0 or isZero(event.request_sha256) or
        isZero(event.dispatch_key_sha256) or
        isZero(event.request_set_sha256) or
        isZero(event.previous_chain_sha256)) return false;
    const requires_no_attempt = event.kind == .owner_admitted or
        event.kind == .follower_coalesced or
        event.kind == .owner_cancelled;
    const optional_attempt = event.kind == .follower_cancelled;
    if (requires_no_attempt) {
        if (event.attempt_generation != 0 or !isZero(event.intent_sha256) or
            !isZero(event.usage_sha256) or !isZero(event.result_sha256) or
            event.billable_tokens != 0) return false;
    } else if (optional_attempt) {
        if ((event.attempt_generation == 0) !=
            isZero(event.intent_sha256) or
            !isZero(event.usage_sha256) or !isZero(event.result_sha256) or
            event.billable_tokens != 0) return false;
    } else if (event.attempt_generation == 0 or
        isZero(event.intent_sha256)) return false;
    switch (event.kind) {
        .owner_admitted => if (event.request_set_count != 1)
            return false,
        .follower_coalesced => if (event.request_set_count < 2)
            return false,
        .owner_cancelled => {},
        .follower_cancelled => if (event.request_set_count < 2)
            return false,
        .dispatch_started => if (event.billable_tokens != 0)
            return false,
        .retryable_no_charge => if (event.billable_tokens != 0)
            return false,
        .succeeded,
        .failed,
        .resolved_success,
        .resolved_failure,
        .acknowledged,
        => {},
        .ambiguous => {},
    }
    const has_usage = switch (event.kind) {
        .retryable_no_charge,
        .ambiguous,
        .succeeded,
        .failed,
        .resolved_success,
        .resolved_failure,
        .acknowledged,
        => true,
        else => false,
    };
    if (has_usage != !isZero(event.usage_sha256)) return false;
    const has_result = event.kind == .succeeded or
        event.kind == .resolved_success or
        event.kind == .acknowledged and !isZero(event.result_sha256);
    if (has_result != !isZero(event.result_sha256)) return false;
    if (!ledgerTransitionValid(event)) return false;
    return std.mem.eql(
        u8,
        &event.event_sha256,
        &eventSha256(event),
    );
}

fn ledgerTransitionValid(event: EventV2) bool {
    var expected = event.before;
    switch (event.kind) {
        .owner_admitted => {
            expected.reserved_tokens = addChecked(
                expected.reserved_tokens,
                event.reservation_tokens,
            ) orelse return false;
            expected.active_handles = addChecked(
                expected.active_handles,
                1,
            ) orelse return false;
            expected.ready_owners = addChecked(
                expected.ready_owners,
                1,
            ) orelse return false;
        },
        .follower_coalesced => {
            expected.active_handles = addChecked(
                expected.active_handles,
                1,
            ) orelse return false;
            expected.coalesced_requests = addChecked(
                expected.coalesced_requests,
                1,
            ) orelse return false;
        },
        .owner_cancelled => {
            expected.reserved_tokens = subChecked(
                expected.reserved_tokens,
                event.reservation_tokens,
            ) orelse return false;
            expected.active_handles = subChecked(
                expected.active_handles,
                1,
            ) orelse return false;
            expected.ready_owners = subChecked(
                expected.ready_owners,
                1,
            ) orelse return false;
            expected.cancelled_handles = addChecked(
                expected.cancelled_handles,
                1,
            ) orelse return false;
            expected.cancelled_ready_owners = addChecked(
                expected.cancelled_ready_owners,
                1,
            ) orelse return false;
        },
        .follower_cancelled => {
            expected.active_handles = subChecked(
                expected.active_handles,
                1,
            ) orelse return false;
            expected.cancelled_handles = addChecked(
                expected.cancelled_handles,
                1,
            ) orelse return false;
            expected.cancelled_followers = addChecked(
                expected.cancelled_followers,
                1,
            ) orelse return false;
        },
        .dispatch_started => {
            expected.ready_owners = subChecked(
                expected.ready_owners,
                1,
            ) orelse return false;
            expected.dispatched_owners = addChecked(
                expected.dispatched_owners,
                1,
            ) orelse return false;
            expected.physical_dispatches = addChecked(
                expected.physical_dispatches,
                1,
            ) orelse return false;
        },
        .retryable_no_charge => {
            if (event.billable_tokens != 0) return false;
            expected.dispatched_owners = subChecked(
                expected.dispatched_owners,
                1,
            ) orelse return false;
            expected.ready_owners = addChecked(
                expected.ready_owners,
                1,
            ) orelse return false;
            expected.retryable_attempts = addChecked(
                expected.retryable_attempts,
                1,
            ) orelse return false;
        },
        .ambiguous => {
            expected.dispatched_owners = subChecked(
                expected.dispatched_owners,
                1,
            ) orelse return false;
            expected.ambiguous_owners = addChecked(
                expected.ambiguous_owners,
                1,
            ) orelse return false;
            expected.ambiguous_attempts = addChecked(
                expected.ambiguous_attempts,
                1,
            ) orelse return false;
        },
        .succeeded, .failed, .resolved_success, .resolved_failure => {
            expected.reserved_tokens = subChecked(
                expected.reserved_tokens,
                event.reservation_tokens,
            ) orelse return false;
            expected.settled_billable_tokens = addChecked(
                expected.settled_billable_tokens,
                event.billable_tokens,
            ) orelse return false;
            if (event.billable_tokens > event.reservation_tokens) {
                expected.budget_overrun_tokens = addChecked(
                    expected.budget_overrun_tokens,
                    event.billable_tokens - event.reservation_tokens,
                ) orelse return false;
                expected.budget_overrun_dispatches = addChecked(
                    expected.budget_overrun_dispatches,
                    1,
                ) orelse return false;
            }
            if (event.kind == .succeeded or event.kind == .failed) {
                expected.dispatched_owners = subChecked(
                    expected.dispatched_owners,
                    1,
                ) orelse return false;
            } else {
                expected.ambiguous_owners = subChecked(
                    expected.ambiguous_owners,
                    1,
                ) orelse return false;
            }
            if (event.kind == .succeeded or
                event.kind == .resolved_success)
            {
                expected.successful_dispatches = addChecked(
                    expected.successful_dispatches,
                    1,
                ) orelse return false;
            } else {
                expected.failed_dispatches = addChecked(
                    expected.failed_dispatches,
                    1,
                ) orelse return false;
            }
        },
        .acknowledged => {
            expected.active_handles = subChecked(
                expected.active_handles,
                1,
            ) orelse return false;
            expected.acknowledged_handles = addChecked(
                expected.acknowledged_handles,
                1,
            ) orelse return false;
        },
    }
    return std.meta.eql(expected, event.after);
}

fn eventKindForOutcome(outcome: AttemptOutcome) EventKind {
    return switch (outcome) {
        .retryable_no_charge => .retryable_no_charge,
        .ambiguous => .ambiguous,
        .succeeded => .succeeded,
        .failed => .failed,
        .resolved_success => .resolved_success,
        .resolved_failure => .resolved_failure,
    };
}

fn initialChainSha256(
    config: ConfigV1,
    owner_capacity: u32,
    follower_capacity: u32,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(chain_domain);
    hashU64(&hash, abi);
    hashU64(&hash, request_abi);
    hashU64(&hash, usage_abi);
    hashU64(&hash, handle_abi);
    hashU64(&hash, dispatch_intent_abi);
    hashU64(&hash, dispatch_permit_abi);
    hashU64(&hash, event_abi);
    hashU64(&hash, attempt_receipt_abi);
    hashU64(&hash, snapshot_abi);
    hashU64(&hash, config.gateway_epoch);
    hash.update(&config.challenge);
    hashLimits(&hash, config.limits);
    hashU32(&hash, owner_capacity);
    hashU32(&hash, follower_capacity);
    return finish(&hash);
}

fn addChecked(left: u64, right: u64) ?u64 {
    return std.math.add(u64, left, right) catch null;
}

fn subChecked(left: u64, right: u64) ?u64 {
    return std.math.sub(u64, left, right) catch null;
}

const Span = struct { start: usize, end: usize };

fn storageOverlaps(
    self: *Gateway,
    owners: []OwnerSlot,
    followers: []FollowerSlot,
) bool {
    const self_span = span(@intFromPtr(self), @sizeOf(Gateway)) orelse
        return true;
    const owner_bytes = std.math.mul(
        usize,
        owners.len,
        @sizeOf(OwnerSlot),
    ) catch return true;
    const follower_bytes = std.math.mul(
        usize,
        followers.len,
        @sizeOf(FollowerSlot),
    ) catch return true;
    const owner_span = span(@intFromPtr(owners.ptr), owner_bytes) orelse
        return true;
    const follower_span = span(
        @intFromPtr(followers.ptr),
        follower_bytes,
    ) orelse return true;
    return spansOverlap(self_span, owner_span) or
        spansOverlap(self_span, follower_span) or
        spansOverlap(owner_span, follower_span);
}

fn span(start: usize, byte_len: usize) ?Span {
    if (byte_len == 0) return .{ .start = start, .end = start };
    const end = std.math.add(usize, start, byte_len) catch return null;
    return .{ .start = start, .end = end };
}

fn spansOverlap(left: Span, right: Span) bool {
    if (left.start == left.end or right.start == right.end) return false;
    return left.start < right.end and right.start < left.end;
}

fn hashUsage(
    hash: *std.crypto.hash.sha2.Sha256,
    usage: UsageV1,
    include_digest: bool,
) void {
    hashU64(hash, usage.abi_version);
    hashCount(hash, usage.input_tokens);
    hashCount(hash, usage.output_tokens);
    hashCount(hash, usage.cached_input_tokens);
    hashCount(hash, usage.reasoning_tokens);
    hashCount(hash, usage.retry_tokens);
    hashCount(hash, usage.billable_tokens);
    if (include_digest) hash.update(&usage.usage_sha256);
}

fn hashCount(hash: *std.crypto.hash.sha2.Sha256, count: CountV1) void {
    hashU8(hash, @intFromBool(count.known));
    hashU64(hash, count.value);
}

fn hashLedger(hash: *std.crypto.hash.sha2.Sha256, ledger: LedgerV2) void {
    inline for (std.meta.fields(LedgerV2)) |field|
        hashU64(hash, @field(ledger, field.name));
}

fn hashLimits(hash: *std.crypto.hash.sha2.Sha256, limits: LimitsV1) void {
    hashU64(hash, limits.max_reserved_tokens);
    hashU64(hash, limits.max_reserved_tokens_per_isolation);
    hashU64(hash, limits.max_request_tokens);
    hashU32(hash, limits.max_followers_per_owner);
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

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var digest: Digest = undefined;
    hash.final(&digest);
    return digest;
}

fn isZero(digest: Digest) bool {
    return std.mem.eql(u8, &digest, &zero_digest);
}

fn testDigest(seed: u8) Digest {
    var digest: Digest = undefined;
    @memset(&digest, seed);
    return digest;
}

fn testConfig(
    max_reserved_tokens: u64,
    max_reserved_tokens_per_isolation: u64,
    max_request_tokens: u64,
    max_followers_per_owner: u32,
) ConfigV1 {
    return .{
        .gateway_epoch = 0x4757_5445_5354_0001,
        .challenge = testDigest(0xa5),
        .limits = .{
            .max_reserved_tokens = max_reserved_tokens,
            .max_reserved_tokens_per_isolation = max_reserved_tokens_per_isolation,
            .max_request_tokens = max_request_tokens,
            .max_followers_per_owner = max_followers_per_owner,
        },
    };
}

fn testRequest(
    isolation_key: u64,
    request_key: u64,
    context_seed: u8,
    input_tokens: u64,
    max_output_tokens: u64,
    reuse_policy: ReusePolicy,
) Error!RequestV1 {
    return makeRequestV1(
        0x4144_4150_5445_5201,
        isolation_key,
        request_key,
        1,
        testDigest(0x11),
        testDigest(context_seed),
        testDigest(0x33),
        testDigest(0x44),
        testDigest(0x55),
        input_tokens,
        max_output_tokens,
        reuse_policy,
    );
}

fn expectSnapshotEqual(expected: SnapshotV2, actual: SnapshotV2) !void {
    try std.testing.expectEqual(expected.abi_version, actual.abi_version);
    try std.testing.expectEqual(expected.gateway_epoch, actual.gateway_epoch);
    try std.testing.expectEqual(expected.limits, actual.limits);
    try std.testing.expectEqual(expected.owner_capacity, actual.owner_capacity);
    try std.testing.expectEqual(
        expected.follower_capacity,
        actual.follower_capacity,
    );
    try std.testing.expectEqual(
        expected.next_event_sequence,
        actual.next_event_sequence,
    );
    try std.testing.expectEqual(expected.ledger, actual.ledger);
    try std.testing.expectEqualSlices(
        u8,
        &expected.event_chain_sha256,
        &actual.event_chain_sha256,
    );
}

const ConcurrentAdmission = struct {
    gateway: *Gateway,
    request: RequestV1,
    result: ?AdmissionV2 = null,
    failure: ?Error = null,

    fn run(self: *@This()) void {
        self.result = self.gateway.admit(self.request) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const CancelWorker = struct {
    gateway: *Gateway,
    handle: RequestHandleV1,
    event: ?EventV2 = null,
    failure: ?Error = null,

    fn run(self: *@This()) void {
        self.event = self.gateway.cancel(self.handle) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const DispatchWorker = struct {
    gateway: *Gateway,
    handle: RequestHandleV1,
    result: ?DispatchStartV2 = null,
    failure: ?Error = null,

    fn run(self: *@This()) void {
        self.result = self.gateway.beginDispatch(self.handle) catch |err| {
            self.failure = err;
            return;
        };
    }
};

const SettlementWorker = struct {
    gateway: *Gateway,
    permit: DispatchPermitV1,
    usage: UsageV1,
    result_sha256: Digest,
    result: ?AttemptResultV2 = null,
    failure: ?Error = null,

    fn run(self: *@This()) void {
        self.result = self.gateway.settleSuccess(
            self.permit,
            self.usage,
            self.result_sha256,
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

test "exact in-flight requests share one dispatch and one settlement" {
    var owners: [2]OwnerSlot = [_]OwnerSlot{.{}} ** 2;
    var followers: [3]FollowerSlot = [_]FollowerSlot{.{}} ** 3;
    var gateway: Gateway = .{};
    const config = testConfig(1_000, 800, 500, 3);
    try gateway.init(&owners, &followers, config);
    var verifier = try VerifierV2.init(config, owners.len, followers.len);

    const first = try gateway.admit(try testRequest(
        7,
        101,
        0x22,
        100,
        50,
        .in_flight,
    ));
    try std.testing.expectEqual(AdmissionKind.owner, first.kind);
    try verifier.apply(first.event.?);

    const second = try gateway.admit(try testRequest(
        7,
        102,
        0x22,
        100,
        50,
        .in_flight,
    ));
    try std.testing.expectEqual(AdmissionKind.coalesced, second.kind);
    try verifier.apply(second.event.?);
    try std.testing.expectEqualSlices(
        u8,
        &first.dispatch_key_sha256,
        &second.dispatch_key_sha256,
    );

    const duplicate = try gateway.admit(try testRequest(
        7,
        102,
        0x22,
        100,
        50,
        .in_flight,
    ));
    try std.testing.expectEqual(AdmissionKind.existing, duplicate.kind);
    try std.testing.expect(duplicate.event == null);
    try std.testing.expectEqual(second.handle, duplicate.handle);

    const start = try gateway.beginDispatch(first.handle);
    try verifier.apply(start.event);
    const before_settlement = try gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 150), before_settlement.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 2), before_settlement.ledger.active_handles);
    try std.testing.expectEqual(@as(u64, 1), before_settlement.ledger.physical_dispatches);
    try std.testing.expectEqual(@as(u64, 1), before_settlement.ledger.coalesced_requests);

    const usage = try makeUsageV1(100, 20, 40, 8, 0, 80);
    const settled = try gateway.settleSuccess(
        start.permit,
        usage,
        testDigest(0x77),
    );
    try verifier.apply(settled.event);
    try std.testing.expect(attemptReceiptValidV1(settled.receipt));
    try std.testing.expectEqual(@as(u32, 2), settled.receipt.request_set_count);

    const owner_status = try gateway.poll(first.handle);
    const owner_receipt = switch (owner_status) {
        .succeeded => |receipt| receipt,
        else => return error.UnexpectedStatus,
    };
    const follower_status = try gateway.poll(second.handle);
    const follower_receipt = switch (follower_status) {
        .succeeded => |receipt| receipt,
        else => return error.UnexpectedStatus,
    };
    try std.testing.expectEqual(owner_receipt, follower_receipt);
    try std.testing.expectEqual(settled.receipt, owner_receipt);

    try verifier.apply(try gateway.acknowledge(second.handle));
    try std.testing.expectError(Error.InvalidHandle, gateway.poll(second.handle));
    try std.testing.expectError(
        Error.RequestAlreadyAcknowledged,
        gateway.admit(try testRequest(
            7,
            102,
            0x22,
            100,
            50,
            .in_flight,
        )),
    );
    try verifier.apply(try gateway.acknowledge(first.handle));

    const final_snapshot = try gateway.close();
    try expectSnapshotEqual(final_snapshot, verifier.snapshot());
    try verifier.requireFinal(
        6,
        final_snapshot.ledger,
        final_snapshot.event_chain_sha256,
    );
    try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.active_handles);
    try std.testing.expectEqual(@as(u64, 80), final_snapshot.ledger.settled_billable_tokens);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.physical_dispatches);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.coalesced_requests);
    try std.testing.expectEqual(@as(u64, 2), final_snapshot.ledger.acknowledged_handles);
}

test "isolation, identity, budget, and follower bounds fail closed" {
    var owners: [3]OwnerSlot = [_]OwnerSlot{.{}} ** 3;
    var followers: [2]FollowerSlot = [_]FollowerSlot{.{}} ** 2;
    var gateway: Gateway = .{};
    try gateway.init(&owners, &followers, testConfig(400, 200, 150, 1));

    const first_request = try testRequest(1, 1, 0x21, 100, 50, .in_flight);
    const first = try gateway.admit(first_request);
    try std.testing.expectEqual(AdmissionKind.owner, first.kind);

    const conflict = try testRequest(1, 1, 0x22, 100, 50, .in_flight);
    try std.testing.expectError(Error.RequestConflict, gateway.admit(conflict));

    const isolated = try gateway.admit(try testRequest(
        2,
        2,
        0x21,
        100,
        50,
        .in_flight,
    ));
    try std.testing.expectEqual(AdmissionKind.owner, isolated.kind);

    const follower = try gateway.admit(try testRequest(
        1,
        3,
        0x21,
        100,
        50,
        .in_flight,
    ));
    try std.testing.expectEqual(AdmissionKind.coalesced, follower.kind);
    try std.testing.expectError(
        Error.CapacityExceeded,
        gateway.admit(try testRequest(1, 4, 0x21, 100, 50, .in_flight)),
    );
    try std.testing.expectError(
        Error.BudgetExceeded,
        gateway.admit(try testRequest(1, 5, 0x29, 50, 40, .none)),
    );
    try std.testing.expectError(
        Error.BudgetExceeded,
        gateway.admit(try testRequest(3, 6, 0x31, 120, 50, .none)),
    );

    const snapshot = try gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 300), snapshot.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 3), snapshot.ledger.active_handles);
    try std.testing.expectEqual(@as(u64, 1), snapshot.ledger.coalesced_requests);
}

test "retryable no-charge attempt preserves budget and rejects stale permit" {
    var owners: [1]OwnerSlot = .{.{}};
    var followers: [1]FollowerSlot = .{.{}};
    var gateway: Gateway = .{};
    try gateway.init(&owners, &followers, testConfig(500, 500, 500, 1));
    const admission = try gateway.admit(try testRequest(
        9,
        90,
        0x61,
        100,
        50,
        .in_flight,
    ));

    const first_start = try gateway.beginDispatch(admission.handle);
    const retry = try gateway.retryNoCharge(
        first_start.permit,
        try makeUsageV1(null, null, null, null, 0, 0),
    );
    try std.testing.expectEqual(
        AttemptOutcome.retryable_no_charge,
        retry.receipt.outcome,
    );
    try std.testing.expectError(
        Error.InvalidPermit,
        gateway.settleFailure(
            first_start.permit,
            try makeUsageV1(100, 0, 0, 0, 0, 100),
        ),
    );

    const second_start = try gateway.beginDispatch(admission.handle);
    try std.testing.expectEqual(@as(u64, 2), second_start.intent.attempt_generation);
    _ = try gateway.settleSuccess(
        second_start.permit,
        try makeUsageV1(100, 10, 25, 0, 0, 85),
        testDigest(0x91),
    );
    _ = try gateway.acknowledge(admission.handle);
    const final_snapshot = try gateway.close();
    try std.testing.expectEqual(@as(u64, 2), final_snapshot.ledger.physical_dispatches);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.retryable_attempts);
    try std.testing.expectEqual(@as(u64, 85), final_snapshot.ledger.settled_billable_tokens);
}

test "ambiguous attempt holds reservation until authoritative resolution" {
    var owners: [1]OwnerSlot = .{.{}};
    var followers: [1]FollowerSlot = .{.{}};
    var gateway: Gateway = .{};
    try gateway.init(&owners, &followers, testConfig(500, 500, 500, 1));
    const admission = try gateway.admit(try testRequest(
        5,
        50,
        0x71,
        100,
        50,
        .in_flight,
    ));
    const start = try gateway.beginDispatch(admission.handle);
    const ambiguous = try gateway.markAmbiguous(
        start.permit,
        try makeUsageV1(null, null, null, null, null, null),
    );
    try std.testing.expectEqual(AttemptOutcome.ambiguous, ambiguous.receipt.outcome);
    const pending_snapshot = try gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 150), pending_snapshot.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 1), pending_snapshot.ledger.ambiguous_owners);
    try std.testing.expectError(
        Error.InvalidState,
        gateway.beginDispatch(admission.handle),
    );
    const resolved = try gateway.resolveAmbiguousSuccess(
        start.permit,
        try makeUsageV1(100, 60, 0, 0, 0, 160),
        testDigest(0x81),
    );
    try std.testing.expectEqual(
        AttemptOutcome.resolved_success,
        resolved.receipt.outcome,
    );
    _ = try gateway.acknowledge(admission.handle);
    const final_snapshot = try gateway.close();
    try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.ambiguous_attempts);
    try std.testing.expectEqual(@as(u64, 160), final_snapshot.ledger.settled_billable_tokens);
    try std.testing.expectEqual(@as(u64, 10), final_snapshot.ledger.budget_overrun_tokens);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.budget_overrun_dispatches);
}

test "mutation, replay, reorder, and copied gateway are rejected" {
    var owners: [1]OwnerSlot = .{.{}};
    var followers: [1]FollowerSlot = .{.{}};
    var gateway: Gateway = .{};
    const config = testConfig(500, 500, 500, 1);
    try gateway.init(&owners, &followers, config);
    const request = try testRequest(3, 30, 0x41, 100, 50, .in_flight);
    const admission = try gateway.admit(request);
    const start = try gateway.beginDispatch(admission.handle);

    var verifier = try VerifierV2.init(config, owners.len, followers.len);
    try verifier.apply(admission.event.?);
    try std.testing.expectError(Error.StateDrift, verifier.apply(admission.event.?));
    var reordered = try VerifierV2.init(config, owners.len, followers.len);
    try std.testing.expectError(Error.StateDrift, reordered.apply(start.event));

    var forged = admission.event.?;
    forged.after.active_handles += 1;
    forged.event_sha256 = eventSha256(forged);
    try std.testing.expect(!eventValidV2(forged));
    var forged_verifier = try VerifierV2.init(config, owners.len, followers.len);
    try std.testing.expectError(Error.StateDrift, forged_verifier.apply(forged));

    var mutated_request = request;
    mutated_request.context_sha256[0] ^= 0xff;
    try std.testing.expect(!requestValidV1(mutated_request));
    var usage = try makeUsageV1(100, 10, 5, 0, 0, 105);
    usage.output_tokens.value += 1;
    try std.testing.expect(!usageValidV1(usage));

    var copied_gateway = gateway;
    try std.testing.expectError(Error.StateDrift, copied_gateway.snapshot());

    owners[0].live_follower_handles = 1;
    try std.testing.expectError(Error.StateDrift, gateway.snapshot());
    owners[0].live_follower_handles = 0;
    _ = try gateway.settleSuccess(
        start.permit,
        try makeUsageV1(100, 10, 5, 0, 0, 105),
        testDigest(0x51),
    );
    _ = try gateway.acknowledge(admission.handle);
    _ = try gateway.close();
}

test "concurrent exact admissions elect one physical-dispatch owner" {
    const admission_count = 8;
    var owners: [admission_count]OwnerSlot =
        [_]OwnerSlot{.{}} ** admission_count;
    var followers: [admission_count - 1]FollowerSlot =
        [_]FollowerSlot{.{}} ** (admission_count - 1);
    var gateway: Gateway = .{};
    try gateway.init(
        &owners,
        &followers,
        testConfig(2_000, 2_000, 500, admission_count - 1),
    );

    var workers: [admission_count]ConcurrentAdmission = undefined;
    var threads: [admission_count]std.Thread = undefined;
    for (&workers, 0..) |*worker, index| {
        worker.* = .{
            .gateway = &gateway,
            .request = try testRequest(
                13,
                @intCast(index + 1),
                0x65,
                100,
                50,
                .in_flight,
            ),
        };
        threads[index] = std.Thread.spawn(.{}, ConcurrentAdmission.run, .{
            worker,
        }) catch |err| {
            for (threads[0..index]) |thread| thread.join();
            return err;
        };
    }
    for (threads) |thread| thread.join();

    var owner_count: usize = 0;
    var follower_count: usize = 0;
    var owner_handle: RequestHandleV1 = undefined;
    for (workers) |worker| {
        try std.testing.expect(worker.failure == null);
        const admission = worker.result orelse return error.MissingAdmission;
        switch (admission.kind) {
            .owner => {
                owner_count += 1;
                owner_handle = admission.handle;
            },
            .coalesced => follower_count += 1,
            .existing => return error.UnexpectedExistingAdmission,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), owner_count);
    try std.testing.expectEqual(
        @as(usize, admission_count - 1),
        follower_count,
    );
    const after_admission = try gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 150), after_admission.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, admission_count), after_admission.ledger.active_handles);
    try std.testing.expectEqual(@as(u64, admission_count - 1), after_admission.ledger.coalesced_requests);

    const start = try gateway.beginDispatch(owner_handle);
    _ = try gateway.settleSuccess(
        start.permit,
        try makeUsageV1(100, 10, 25, 0, 0, 85),
        testDigest(0x92),
    );
    for (workers) |worker|
        _ = try gateway.acknowledge(worker.result.?.handle);
    const final_snapshot = try gateway.close();
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.physical_dispatches);
    try std.testing.expectEqual(@as(u64, admission_count - 1), final_snapshot.ledger.coalesced_requests);
}

test "ready owner releases reservation only after every follower cancels" {
    var owners: [1]OwnerSlot = .{.{}};
    var followers: [2]FollowerSlot = [_]FollowerSlot{.{}} ** 2;
    var gateway: Gateway = .{};
    const config = testConfig(500, 500, 500, 2);
    try gateway.init(&owners, &followers, config);
    var verifier = try VerifierV2.init(config, owners.len, followers.len);

    const owner = try gateway.admit(try testRequest(
        21,
        1,
        0x31,
        100,
        50,
        .in_flight,
    ));
    try verifier.apply(owner.event.?);
    const follower = try gateway.admit(try testRequest(
        21,
        2,
        0x31,
        100,
        50,
        .in_flight,
    ));
    try verifier.apply(follower.event.?);
    try std.testing.expectError(Error.InvalidState, gateway.cancel(owner.handle));

    const follower_cancel = try gateway.cancel(follower.handle);
    try std.testing.expectEqual(EventKind.follower_cancelled, follower_cancel.kind);
    try std.testing.expectEqual(@as(u64, 0), follower_cancel.attempt_generation);
    try verifier.apply(follower_cancel);
    try std.testing.expectError(Error.InvalidHandle, gateway.cancel(follower.handle));
    try std.testing.expectError(Error.InvalidHandle, gateway.poll(follower.handle));
    try std.testing.expectError(
        Error.RequestCancelled,
        gateway.admit(try testRequest(
            21,
            2,
            0x31,
            100,
            50,
            .in_flight,
        )),
    );
    const after_follower = try gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 150), after_follower.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 1), after_follower.ledger.active_handles);

    const owner_cancel = try gateway.cancel(owner.handle);
    try std.testing.expectEqual(EventKind.owner_cancelled, owner_cancel.kind);
    try verifier.apply(owner_cancel);
    const final_snapshot = try gateway.close();
    try expectSnapshotEqual(final_snapshot, verifier.snapshot());
    try verifier.requireFinal(
        4,
        final_snapshot.ledger,
        final_snapshot.event_chain_sha256,
    );
    try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.reserved_tokens);
    try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.physical_dispatches);
    try std.testing.expectEqual(@as(u64, 2), final_snapshot.ledger.cancelled_handles);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.cancelled_followers);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.cancelled_ready_owners);
}

test "follower cancel and owner settlement race preserve one shared outcome" {
    var owners: [1]OwnerSlot = .{.{}};
    var followers: [1]FollowerSlot = .{.{}};
    var gateway: Gateway = .{};
    try gateway.init(&owners, &followers, testConfig(500, 500, 500, 1));
    const owner = try gateway.admit(try testRequest(
        22,
        1,
        0x32,
        100,
        50,
        .in_flight,
    ));
    const follower = try gateway.admit(try testRequest(
        22,
        2,
        0x32,
        100,
        50,
        .in_flight,
    ));
    const start = try gateway.beginDispatch(owner.handle);
    var canceller: CancelWorker = .{
        .gateway = &gateway,
        .handle = follower.handle,
    };
    var settler: SettlementWorker = .{
        .gateway = &gateway,
        .permit = start.permit,
        .usage = try makeUsageV1(100, 10, 25, 0, 0, 85),
        .result_sha256 = testDigest(0xb1),
    };
    const cancel_thread = try std.Thread.spawn(.{}, CancelWorker.run, .{
        &canceller,
    });
    const settle_thread = std.Thread.spawn(.{}, SettlementWorker.run, .{
        &settler,
    }) catch |err| {
        cancel_thread.join();
        return err;
    };
    cancel_thread.join();
    settle_thread.join();

    try std.testing.expect(canceller.failure == null);
    try std.testing.expect(settler.failure == null);
    try std.testing.expectEqual(EventKind.follower_cancelled, canceller.event.?.kind);
    try std.testing.expectEqual(AttemptOutcome.succeeded, settler.result.?.receipt.outcome);
    try std.testing.expectEqual(@as(u32, 2), settler.result.?.receipt.request_set_count);
    try std.testing.expectError(Error.InvalidHandle, gateway.poll(follower.handle));
    const owner_status = try gateway.poll(owner.handle);
    switch (owner_status) {
        .succeeded => {},
        else => return error.UnexpectedStatus,
    }
    const snapshot = try gateway.snapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.ledger.active_handles);
    try std.testing.expectEqual(@as(u64, 1), snapshot.ledger.cancelled_followers);
    try std.testing.expectEqual(@as(u64, 1), snapshot.ledger.successful_dispatches);
    _ = try gateway.acknowledge(owner.handle);
    _ = try gateway.close();
}

test "terminal follower cancellation retires a group after owner acknowledgement" {
    var owners: [1]OwnerSlot = .{.{}};
    var followers: [1]FollowerSlot = .{.{}};
    var gateway: Gateway = .{};
    const config = testConfig(500, 500, 500, 1);
    try gateway.init(&owners, &followers, config);
    var verifier = try VerifierV2.init(config, owners.len, followers.len);
    const owner = try gateway.admit(try testRequest(
        24,
        1,
        0x34,
        100,
        50,
        .in_flight,
    ));
    try verifier.apply(owner.event.?);
    const follower = try gateway.admit(try testRequest(
        24,
        2,
        0x34,
        100,
        50,
        .in_flight,
    ));
    try verifier.apply(follower.event.?);
    const start = try gateway.beginDispatch(owner.handle);
    try verifier.apply(start.event);
    const settlement = try gateway.settleSuccess(
        start.permit,
        try makeUsageV1(100, 10, 25, 0, 0, 85),
        testDigest(0xb3),
    );
    try verifier.apply(settlement.event);
    try verifier.apply(try gateway.acknowledge(owner.handle));
    const cancellation = try gateway.cancel(follower.handle);
    try std.testing.expectEqual(EventKind.follower_cancelled, cancellation.kind);
    try std.testing.expectEqual(@as(u64, 1), cancellation.attempt_generation);
    try verifier.apply(cancellation);
    const final_snapshot = try gateway.close();
    try expectSnapshotEqual(final_snapshot, verifier.snapshot());
    try verifier.requireFinal(
        6,
        final_snapshot.ledger,
        final_snapshot.event_chain_sha256,
    );
    try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.active_handles);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.acknowledged_handles);
    try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.cancelled_followers);
}

test "ready cancellation and dispatch issuance have exactly one winner" {
    var owners: [1]OwnerSlot = .{.{}};
    var followers: [1]FollowerSlot = .{.{}};
    var gateway: Gateway = .{};
    try gateway.init(&owners, &followers, testConfig(500, 500, 500, 1));
    const owner = try gateway.admit(try testRequest(
        23,
        1,
        0x33,
        100,
        50,
        .in_flight,
    ));
    var canceller: CancelWorker = .{
        .gateway = &gateway,
        .handle = owner.handle,
    };
    var dispatcher: DispatchWorker = .{
        .gateway = &gateway,
        .handle = owner.handle,
    };
    const cancel_thread = try std.Thread.spawn(.{}, CancelWorker.run, .{
        &canceller,
    });
    const dispatch_thread = std.Thread.spawn(.{}, DispatchWorker.run, .{
        &dispatcher,
    }) catch |err| {
        cancel_thread.join();
        return err;
    };
    cancel_thread.join();
    dispatch_thread.join();

    const cancel_won = canceller.event != null;
    const dispatch_won = dispatcher.result != null;
    try std.testing.expect(cancel_won != dispatch_won);
    if (cancel_won) {
        try std.testing.expect(canceller.failure == null);
        try std.testing.expectEqual(Error.InvalidHandle, dispatcher.failure.?);
        const final_snapshot = try gateway.close();
        try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.physical_dispatches);
        try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.cancelled_ready_owners);
    } else {
        try std.testing.expect(dispatcher.failure == null);
        try std.testing.expectEqual(Error.InvalidState, canceller.failure.?);
        _ = try gateway.settleSuccess(
            dispatcher.result.?.permit,
            try makeUsageV1(100, 10, 25, 0, 0, 85),
            testDigest(0xb2),
        );
        _ = try gateway.acknowledge(owner.handle);
        const final_snapshot = try gateway.close();
        try std.testing.expectEqual(@as(u64, 1), final_snapshot.ledger.physical_dispatches);
        try std.testing.expectEqual(@as(u64, 0), final_snapshot.ledger.cancelled_ready_owners);
    }
}

test "portable gateway evidence types remain pointer-free and bounded" {
    try std.testing.expect(@sizeOf(DispatchIntentV1) <= 192);
    try std.testing.expect(@sizeOf(AttemptReceiptV1) <= 512);
    try std.testing.expect(@sizeOf(EventV2) <= 768);
    inline for (std.meta.fields(DispatchIntentV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(UsageV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(AttemptReceiptV1)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
    inline for (std.meta.fields(EventV2)) |field|
        try std.testing.expect(@typeInfo(field.type) != .pointer);
}
