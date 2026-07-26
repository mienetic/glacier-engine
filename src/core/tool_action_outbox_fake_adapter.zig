//! Bounded same-process fake authority for the ActionOutbox adapter contract.
//!
//! The authority serializes dispatch and status calls under one process-local
//! mutex. A negative status result first installs a generation fence; delayed
//! dispatches through that generation are then rejected without application.
//! Terminal results are replayed by stable request identity without applying
//! the fake effect twice.
//!
//! Credential bytes live only in this opaque callback context. They are never
//! hashed into, copied into, or otherwise allowed to influence portable
//! requests or evidence. This demonstrates a narrow same-process API boundary,
//! not an OS sandbox, hostile-process isolation, or production credential
//! security. The fake authority performs no allocation, network or filesystem
//! I/O, clock reads, or randomness.

const std = @import("std");
const action = @import("tool_action_contract.zig");
const outbox = @import("tool_action_outbox_record.zig");
const adapter_contract =
    @import("tool_action_outbox_adapter_contract.zig");

pub const Digest = adapter_contract.Digest;
pub const zero_digest = adapter_contract.zero_digest;
pub const credential_bytes: usize = 32;
pub const maximum_entries: usize =
    outbox.maximum_supported_actions;

const service_event_domain =
    "glacier-action-outbox-fake-service-event-v1\x00";

pub const Error =
    adapter_contract.Error ||
    adapter_contract.CallbackError ||
    error{
        ActionNotFound,
        InvalidCapacity,
        InvalidCredential,
        InvalidPlan,
        InvalidState,
    };

pub const DispatchModeV1 = enum(u8) {
    succeeded = 1,
    terminal_failure = 2,
    pending = 3,
};

/// Deterministic authority behavior for the next newly admitted request.
/// These public roots model service output, never credential material.
pub const DispatchPlanV1 = struct {
    mode: DispatchModeV1,
    service_event_sha256: Digest,
    result_sha256: Digest,
};

pub fn makeDispatchPlanV1(
    mode: DispatchModeV1,
    service_event_sha256: Digest,
    result_sha256: Digest,
) Error!DispatchPlanV1 {
    const result: DispatchPlanV1 = .{
        .mode = mode,
        .service_event_sha256 = service_event_sha256,
        .result_sha256 = result_sha256,
    };
    try validateDispatchPlanV1(result);
    return result;
}

pub fn validateDispatchPlanV1(
    value: DispatchPlanV1,
) Error!void {
    const terminal =
        value.mode == .succeeded or
        value.mode == .terminal_failure;
    if (digestIsZero(value.service_event_sha256) or
        (terminal and digestIsZero(value.result_sha256)) or
        (!terminal and !digestIsZero(value.result_sha256)))
        return Error.InvalidPlan;
}

pub const ServicePhaseV1 = enum(u8) {
    fenced = 1,
    pending = 2,
    succeeded = 3,
    failed = 4,
};

/// Credential-free diagnostic view of one fake service entry.
pub const EntryStateV1 = struct {
    phase: ServicePhaseV1,
    stable_remote_request_sha256: Digest,
    idempotency_key_sha256: Digest,
    action_sha256: Digest,
    fenced_through_generation: u64,
    accepted_generation: u64,
    authority_revision: u64,
    application_count: u64,
    service_event_sha256: Digest,
    result_sha256: Digest,
};

pub const CountersV1 = struct {
    dispatch_calls: u64 = 0,
    status_calls: u64 = 0,
    fence_installations: u64 = 0,
    stale_generation_rejections: u64 = 0,
    duplicate_dispatch_replays: u64 = 0,
    terminal_duplicate_replays: u64 = 0,
    application_count: u64 = 0,
};

pub const AuthorityStateV1 = struct {
    authority_epoch: u64,
    authority_revision: u64,
    entry_count: usize,
    entry_capacity: usize,
    credential_loaded: bool,
    available: bool,
    status_unknown: bool,
    counters: CountersV1,
};

const CredentialContextV1 = struct {
    bytes: [credential_bytes]u8,
    loaded: bool,
};

const EntryV1 = struct {
    occupied: bool = false,
    phase: ServicePhaseV1 = .fenced,
    header_sha256: Digest = zero_digest,
    stable_remote_request_sha256: Digest = zero_digest,
    idempotency_key_sha256: Digest = zero_digest,
    action_sha256: Digest = zero_digest,
    payload_bound: bool = false,
    payload_locator_sha256: Digest = zero_digest,
    payload_bytes: u64 = 0,
    payload_sha256: Digest = zero_digest,
    fenced_through_generation: u64 = 0,
    accepted_generation: u64 = 0,
    accepted_dispatch_request_sha256: Digest = zero_digest,
    accepted_request_sha256: Digest = zero_digest,
    authority_revision: u64 = 0,
    application_count: u64 = 0,
    service_event_sha256: Digest = zero_digest,
    result_sha256: Digest = zero_digest,
    accepted_evidence: ?adapter_contract.DispatchEvidenceV1 = null,
};

/// Single-owner, fixed-storage fake service authority.
///
/// Once `adapter()` has exposed the context pointer, callers must not copy or
/// move this value. All portable values returned through the adapter remain
/// independent of the credential bytes.
pub const AuthorityV1 = struct {
    descriptor: adapter_contract.DescriptorV1,
    entry_capacity: usize,
    entries: [maximum_entries]EntryV1 =
        [_]EntryV1{.{}} ** maximum_entries,
    entry_count: usize = 0,
    authority_revision: u64 = 1,
    dispatch_plan: DispatchPlanV1,
    credential: CredentialContextV1,
    available: bool = true,
    status_unknown: bool = false,
    counters: CountersV1 = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        descriptor: adapter_contract.DescriptorV1,
        credential: [credential_bytes]u8,
        entry_capacity: usize,
        dispatch_plan: DispatchPlanV1,
    ) Error!AuthorityV1 {
        try adapter_contract.validateDescriptorV1(descriptor);
        try validateDispatchPlanV1(dispatch_plan);
        if (entry_capacity == 0 or
            entry_capacity > maximum_entries)
            return Error.InvalidCapacity;
        if (digestIsZero(credential))
            return Error.InvalidCredential;
        return .{
            .descriptor = descriptor,
            .entry_capacity = entry_capacity,
            .dispatch_plan = dispatch_plan,
            .credential = .{
                .bytes = credential,
                .loaded = true,
            },
        };
    }

    /// Return the generic callback interface defined by the portable contract.
    pub fn adapter(self: *AuthorityV1) adapter_contract.AdapterV1 {
        return .{
            .adapter_context = self,
            .descriptor = self.descriptor,
            .dispatch_fn = dispatchCallback,
            .status_fn = statusCallback,
        };
    }

    /// Zero the process-local credential and reject subsequent callback use.
    pub fn deinit(self: *AuthorityV1) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        @memset(&self.credential.bytes, 0);
        self.credential.loaded = false;
        self.available = false;
    }

    pub fn setDispatchPlan(
        self: *AuthorityV1,
        dispatch_plan: DispatchPlanV1,
    ) Error!void {
        try validateDispatchPlanV1(dispatch_plan);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.dispatch_plan = dispatch_plan;
    }

    /// Force status lookups to return non-authoritative `unknown` evidence.
    /// No entry or generation fence is created while this mode is enabled.
    pub fn setStatusUnknown(
        self: *AuthorityV1,
        enabled: bool,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.status_unknown = enabled;
    }

    pub fn setAvailable(
        self: *AuthorityV1,
        available: bool,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.available = available;
    }

    /// Complete one pending fake application exactly once.
    pub fn completePending(
        self: *AuthorityV1,
        stable_remote_request_sha256: Digest,
        disposition: adapter_contract.StatusDispositionV1,
        service_event_sha256: Digest,
        result_sha256: Digest,
    ) Error!EntryStateV1 {
        if ((disposition != .succeeded and
            disposition != .failed) or
            digestIsZero(service_event_sha256) or
            digestIsZero(result_sha256))
            return Error.InvalidState;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireCallable();
        const index = self.findStable(
            stable_remote_request_sha256,
        ) orelse return Error.ActionNotFound;
        var entry = &self.entries[index];
        const target_phase: ServicePhaseV1 =
            if (disposition == .succeeded)
                .succeeded
            else
                .failed;
        if (entry.phase == target_phase and
            digestEqual(
                entry.service_event_sha256,
                service_event_sha256,
            ) and
            digestEqual(entry.result_sha256, result_sha256))
            return entryView(entry.*);
        if (entry.phase != .pending or
            entry.application_count != 0)
            return Error.InvalidState;
        const revision = try self.nextRevision();
        entry.phase = target_phase;
        entry.authority_revision = revision;
        entry.application_count = 1;
        entry.service_event_sha256 = service_event_sha256;
        entry.result_sha256 = result_sha256;
        entry.accepted_evidence = null;
        self.authority_revision = revision;
        self.counters.application_count +|= 1;
        return entryView(entry.*);
    }

    pub fn state(self: *AuthorityV1) AuthorityStateV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .authority_epoch = self.descriptor.authority_epoch,
            .authority_revision = self.authority_revision,
            .entry_count = self.entry_count,
            .entry_capacity = self.entry_capacity,
            .credential_loaded = self.credential.loaded,
            .available = self.available,
            .status_unknown = self.status_unknown,
            .counters = self.counters,
        };
    }

    pub fn entryState(
        self: *AuthorityV1,
        stable_remote_request_sha256: Digest,
    ) ?EntryStateV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const index = self.findStable(
            stable_remote_request_sha256,
        ) orelse return null;
        return entryView(self.entries[index]);
    }

    fn dispatchCallback(
        context: *anyopaque,
        request: adapter_contract.DispatchRequestV1,
    ) adapter_contract.CallbackError!adapter_contract.DispatchEvidenceV1 {
        const self: *AuthorityV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireCallableCallback();
        if (!digestEqual(
            request.adapter_descriptor_sha256,
            self.descriptor.descriptor_sha256,
        ))
            return adapter_contract.CallbackError.RequestRejected;
        self.counters.dispatch_calls +|= 1;

        if (self.findStable(
            request.stable_remote_request_sha256,
        )) |index| {
            const entry = &self.entries[index];
            if (!bindingMatchesDispatch(entry.*, request))
                return adapter_contract.CallbackError.RequestRejected;
            return self.dispatchExisting(entry, request);
        }
        if (self.hasIdentityConflict(
            request.action_sha256,
            request.idempotency_key_sha256,
        ))
            return adapter_contract.CallbackError.RequestRejected;
        if (request.attempt_generation != 1)
            return adapter_contract.CallbackError.RequestRejected;
        const index = self.freeIndex() orelse
            return adapter_contract.CallbackError.CapacityExceeded;
        const revision = self.nextRevisionCallback() catch |err|
            return err;
        const evidence = self.evidenceForPlan(
            request,
            revision,
            self.dispatch_plan,
        ) catch return adapter_contract.CallbackError.RequestRejected;
        self.entries[index] = entryFromDispatch(
            request,
            revision,
            self.dispatch_plan,
            evidence,
            0,
        );
        self.entry_count += 1;
        self.authority_revision = revision;
        self.commitPlanCounters(self.dispatch_plan);
        return evidence;
    }

    fn statusCallback(
        context: *anyopaque,
        request: adapter_contract.StatusRequestV1,
    ) adapter_contract.CallbackError!adapter_contract.StatusEvidenceV1 {
        const self: *AuthorityV1 =
            @ptrCast(@alignCast(context));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.requireCallableCallback();
        if (!digestEqual(
            request.adapter_descriptor_sha256,
            self.descriptor.descriptor_sha256,
        ))
            return adapter_contract.CallbackError.RequestRejected;
        self.counters.status_calls +|= 1;

        if (self.status_unknown) {
            return self.makeStatusEvidence(
                request,
                self.authority_revision,
                .unknown,
                0,
                fakeServiceEventSha256(
                    self.descriptor,
                    request.request_sha256,
                    self.authority_revision,
                    .status_unknown,
                    request.attempt_generation,
                ),
                zero_digest,
            );
        }

        if (self.findStable(
            request.stable_remote_request_sha256,
        )) |index| {
            const entry = &self.entries[index];
            if (!bindingMatchesStatus(entry.*, request))
                return adapter_contract.CallbackError.RequestRejected;
            return self.statusExisting(entry, request);
        }
        if (self.hasIdentityConflict(
            request.action_sha256,
            request.idempotency_key_sha256,
        ))
            return adapter_contract.CallbackError.RequestRejected;
        const index = self.freeIndex() orelse
            return adapter_contract.CallbackError.CapacityExceeded;
        const revision = self.nextRevisionCallback() catch |err|
            return err;
        const service_event_sha256 = fakeServiceEventSha256(
            self.descriptor,
            request.request_sha256,
            revision,
            .fence_observed,
            request.attempt_generation,
        );
        const evidence = self.makeStatusEvidence(
            request,
            revision,
            .not_applied_fenced,
            request.attempt_generation,
            service_event_sha256,
            zero_digest,
        ) catch return adapter_contract.CallbackError.RequestRejected;
        self.entries[index] = entryFromStatusFence(
            request,
            revision,
        );
        self.entry_count += 1;
        self.authority_revision = revision;
        self.counters.fence_installations +|= 1;
        return evidence;
    }

    fn dispatchExisting(
        self: *AuthorityV1,
        entry: *EntryV1,
        request: adapter_contract.DispatchRequestV1,
    ) adapter_contract.CallbackError!adapter_contract.DispatchEvidenceV1 {
        if (request.attempt_generation <=
            entry.fenced_through_generation)
            return self.rejectStale(entry.*, request);
        switch (entry.phase) {
            .fenced => {
                const expected = std.math.add(
                    u64,
                    entry.fenced_through_generation,
                    1,
                ) catch
                    return adapter_contract.CallbackError
                        .AuthorityUnavailable;
                if (request.attempt_generation != expected)
                    return adapter_contract.CallbackError.RequestRejected;
                const revision =
                    self.nextRevisionCallback() catch |err|
                        return err;
                const evidence = self.evidenceForPlan(
                    request,
                    revision,
                    self.dispatch_plan,
                ) catch
                    return adapter_contract.CallbackError.RequestRejected;
                const fence = entry.fenced_through_generation;
                entry.* = entryFromDispatch(
                    request,
                    revision,
                    self.dispatch_plan,
                    evidence,
                    fence,
                );
                self.authority_revision = revision;
                self.commitPlanCounters(self.dispatch_plan);
                return evidence;
            },
            .pending => {
                if (request.attempt_generation !=
                    entry.accepted_generation or
                    !digestEqual(
                        request.request_sha256,
                        entry.accepted_request_sha256,
                    ))
                    return adapter_contract.CallbackError.RequestRejected;
                const evidence = entry.accepted_evidence orelse
                    return adapter_contract.CallbackError
                        .AuthorityUnavailable;
                self.counters.duplicate_dispatch_replays +|= 1;
                return evidence;
            },
            .succeeded, .failed => {
                if (request.attempt_generation ==
                    entry.accepted_generation and
                    !digestEqual(
                        request.request_sha256,
                        entry.accepted_request_sha256,
                    ))
                    return adapter_contract.CallbackError.RequestRejected;
                self.counters.duplicate_dispatch_replays +|= 1;
                self.counters.terminal_duplicate_replays +|= 1;
                if (digestEqual(
                    request.request_sha256,
                    entry.accepted_request_sha256,
                )) {
                    if (entry.accepted_evidence) |evidence| {
                        if (evidence.disposition == .succeeded or
                            evidence.disposition == .terminal_failure)
                            return evidence;
                    }
                }
                return adapter_contract.makeDispatchEvidenceV1(
                    self.descriptor,
                    request,
                    entry.authority_revision,
                    if (entry.phase == .succeeded)
                        .succeeded
                    else
                        .terminal_failure,
                    entry.service_event_sha256,
                    entry.result_sha256,
                ) catch
                    return adapter_contract.CallbackError.RequestRejected;
            },
        }
    }

    fn statusExisting(
        self: *AuthorityV1,
        entry: *EntryV1,
        request: adapter_contract.StatusRequestV1,
    ) adapter_contract.CallbackError!adapter_contract.StatusEvidenceV1 {
        switch (entry.phase) {
            .fenced => {
                var revision = entry.authority_revision;
                if (request.attempt_generation >
                    entry.fenced_through_generation)
                {
                    const expected = std.math.add(
                        u64,
                        entry.fenced_through_generation,
                        1,
                    ) catch
                        return adapter_contract.CallbackError
                            .AuthorityUnavailable;
                    if (request.attempt_generation != expected)
                        return adapter_contract.CallbackError
                            .RequestRejected;
                    revision =
                        self.nextRevisionCallback() catch |err|
                            return err;
                    entry.fenced_through_generation =
                        request.attempt_generation;
                    entry.authority_revision = revision;
                    self.authority_revision = revision;
                    self.counters.fence_installations +|= 1;
                }
                return self.makeStatusEvidence(
                    request,
                    revision,
                    .not_applied_fenced,
                    request.attempt_generation,
                    fakeServiceEventSha256(
                        self.descriptor,
                        request.request_sha256,
                        revision,
                        .fence_observed,
                        request.attempt_generation,
                    ),
                    zero_digest,
                );
            },
            .pending => {
                if (request.attempt_generation <=
                    entry.fenced_through_generation)
                {
                    return self.makeStatusEvidence(
                        request,
                        entry.authority_revision,
                        .not_applied_fenced,
                        request.attempt_generation,
                        fakeServiceEventSha256(
                            self.descriptor,
                            request.request_sha256,
                            entry.authority_revision,
                            .fence_observed,
                            request.attempt_generation,
                        ),
                        zero_digest,
                    );
                }
                if (request.attempt_generation !=
                    entry.accepted_generation)
                    return adapter_contract.CallbackError.RequestRejected;
                return self.makeStatusEvidence(
                    request,
                    entry.authority_revision,
                    .pending,
                    0,
                    entry.service_event_sha256,
                    zero_digest,
                );
            },
            .succeeded, .failed => {
                return self.makeStatusEvidence(
                    request,
                    entry.authority_revision,
                    if (entry.phase == .succeeded)
                        .succeeded
                    else
                        .failed,
                    0,
                    entry.service_event_sha256,
                    entry.result_sha256,
                );
            },
        }
    }

    fn rejectStale(
        self: *AuthorityV1,
        entry: EntryV1,
        request: adapter_contract.DispatchRequestV1,
    ) adapter_contract.CallbackError!adapter_contract.DispatchEvidenceV1 {
        self.counters.stale_generation_rejections +|= 1;
        return adapter_contract.makeDispatchEvidenceV1(
            self.descriptor,
            request,
            entry.authority_revision,
            .rejected_stale_generation,
            fakeServiceEventSha256(
                self.descriptor,
                request.request_sha256,
                entry.authority_revision,
                .stale_dispatch_rejected,
                request.attempt_generation,
            ),
            zero_digest,
        ) catch return adapter_contract.CallbackError.RequestRejected;
    }

    fn evidenceForPlan(
        self: *AuthorityV1,
        request: adapter_contract.DispatchRequestV1,
        revision: u64,
        plan: DispatchPlanV1,
    ) adapter_contract.Error!adapter_contract.DispatchEvidenceV1 {
        return adapter_contract.makeDispatchEvidenceV1(
            self.descriptor,
            request,
            revision,
            switch (plan.mode) {
                .succeeded => .succeeded,
                .terminal_failure => .terminal_failure,
                .pending => .indeterminate,
            },
            plan.service_event_sha256,
            plan.result_sha256,
        );
    }

    fn makeStatusEvidence(
        self: *AuthorityV1,
        request: adapter_contract.StatusRequestV1,
        revision: u64,
        disposition: adapter_contract.StatusDispositionV1,
        fence_through_generation: u64,
        service_event_sha256: Digest,
        result_sha256: Digest,
    ) adapter_contract.CallbackError!adapter_contract.StatusEvidenceV1 {
        return adapter_contract.makeStatusEvidenceV1(
            self.descriptor,
            request,
            revision,
            disposition,
            fence_through_generation,
            service_event_sha256,
            result_sha256,
        ) catch return adapter_contract.CallbackError.RequestRejected;
    }

    fn commitPlanCounters(
        self: *AuthorityV1,
        plan: DispatchPlanV1,
    ) void {
        if (plan.mode == .succeeded or
            plan.mode == .terminal_failure)
            self.counters.application_count +|= 1;
    }

    fn requireCallable(self: *const AuthorityV1) Error!void {
        if (!self.credential.loaded)
            return adapter_contract.CallbackError.CredentialRejected;
        if (!self.available)
            return adapter_contract.CallbackError
                .AuthorityUnavailable;
    }

    fn requireCallableCallback(
        self: *const AuthorityV1,
    ) adapter_contract.CallbackError!void {
        if (!self.credential.loaded)
            return adapter_contract.CallbackError.CredentialRejected;
        if (!self.available)
            return adapter_contract.CallbackError
                .AuthorityUnavailable;
    }

    fn nextRevision(self: *const AuthorityV1) Error!u64 {
        return std.math.add(
            u64,
            self.authority_revision,
            1,
        ) catch
            return adapter_contract.CallbackError
                .AuthorityUnavailable;
    }

    fn nextRevisionCallback(
        self: *const AuthorityV1,
    ) adapter_contract.CallbackError!u64 {
        return std.math.add(
            u64,
            self.authority_revision,
            1,
        ) catch
            return adapter_contract.CallbackError
                .AuthorityUnavailable;
    }

    fn findStable(
        self: *const AuthorityV1,
        stable_remote_request_sha256: Digest,
    ) ?usize {
        for (self.entries[0..self.entry_capacity], 0..) |
            entry,
            index,
        | {
            if (entry.occupied and digestEqual(
                entry.stable_remote_request_sha256,
                stable_remote_request_sha256,
            ))
                return index;
        }
        return null;
    }

    fn hasIdentityConflict(
        self: *const AuthorityV1,
        action_sha256: Digest,
        idempotency_key_sha256: Digest,
    ) bool {
        for (self.entries[0..self.entry_capacity]) |entry| {
            if (!entry.occupied) continue;
            if (digestEqual(entry.action_sha256, action_sha256) or
                digestEqual(
                    entry.idempotency_key_sha256,
                    idempotency_key_sha256,
                ))
                return true;
        }
        return false;
    }

    fn freeIndex(self: *const AuthorityV1) ?usize {
        for (self.entries[0..self.entry_capacity], 0..) |
            entry,
            index,
        | {
            if (!entry.occupied) return index;
        }
        return null;
    }
};

/// Explicit name for integration code that distinguishes the fake authority
/// from future live adapter implementations.
pub const FakeAuthorityV1 = AuthorityV1;

fn entryFromDispatch(
    request: adapter_contract.DispatchRequestV1,
    revision: u64,
    plan: DispatchPlanV1,
    evidence: adapter_contract.DispatchEvidenceV1,
    fenced_through_generation: u64,
) EntryV1 {
    return .{
        .occupied = true,
        .phase = switch (plan.mode) {
            .succeeded => .succeeded,
            .terminal_failure => .failed,
            .pending => .pending,
        },
        .header_sha256 = request.header_sha256,
        .stable_remote_request_sha256 = request.stable_remote_request_sha256,
        .idempotency_key_sha256 = request.idempotency_key_sha256,
        .action_sha256 = request.action_sha256,
        .payload_bound = true,
        .payload_locator_sha256 = request.payload_locator_sha256,
        .payload_bytes = request.payload_bytes,
        .payload_sha256 = request.payload_sha256,
        .fenced_through_generation = fenced_through_generation,
        .accepted_generation = request.attempt_generation,
        .accepted_dispatch_request_sha256 = request.dispatch_request_sha256,
        .accepted_request_sha256 = request.request_sha256,
        .authority_revision = revision,
        .application_count = if (plan.mode == .pending) 0 else 1,
        .service_event_sha256 = plan.service_event_sha256,
        .result_sha256 = plan.result_sha256,
        .accepted_evidence = evidence,
    };
}

fn entryFromStatusFence(
    request: adapter_contract.StatusRequestV1,
    revision: u64,
) EntryV1 {
    return .{
        .occupied = true,
        .phase = .fenced,
        .header_sha256 = request.header_sha256,
        .stable_remote_request_sha256 = request.stable_remote_request_sha256,
        .idempotency_key_sha256 = request.idempotency_key_sha256,
        .action_sha256 = request.action_sha256,
        .fenced_through_generation = request.attempt_generation,
        .authority_revision = revision,
    };
}

fn bindingMatchesDispatch(
    entry: EntryV1,
    request: adapter_contract.DispatchRequestV1,
) bool {
    return digestEqual(entry.header_sha256, request.header_sha256) and
        digestEqual(
            entry.stable_remote_request_sha256,
            request.stable_remote_request_sha256,
        ) and
        digestEqual(
            entry.idempotency_key_sha256,
            request.idempotency_key_sha256,
        ) and
        digestEqual(entry.action_sha256, request.action_sha256) and
        (!entry.payload_bound or
            (digestEqual(
                entry.payload_locator_sha256,
                request.payload_locator_sha256,
            ) and
                entry.payload_bytes == request.payload_bytes and
                digestEqual(
                    entry.payload_sha256,
                    request.payload_sha256,
                )));
}

fn bindingMatchesStatus(
    entry: EntryV1,
    request: adapter_contract.StatusRequestV1,
) bool {
    return digestEqual(entry.header_sha256, request.header_sha256) and
        digestEqual(
            entry.stable_remote_request_sha256,
            request.stable_remote_request_sha256,
        ) and
        digestEqual(
            entry.idempotency_key_sha256,
            request.idempotency_key_sha256,
        ) and
        digestEqual(entry.action_sha256, request.action_sha256);
}

fn entryView(entry: EntryV1) EntryStateV1 {
    return .{
        .phase = entry.phase,
        .stable_remote_request_sha256 = entry.stable_remote_request_sha256,
        .idempotency_key_sha256 = entry.idempotency_key_sha256,
        .action_sha256 = entry.action_sha256,
        .fenced_through_generation = entry.fenced_through_generation,
        .accepted_generation = entry.accepted_generation,
        .authority_revision = entry.authority_revision,
        .application_count = entry.application_count,
        .service_event_sha256 = entry.service_event_sha256,
        .result_sha256 = entry.result_sha256,
    };
}

const FakeEventKindV1 = enum(u8) {
    fence_observed = 1,
    stale_dispatch_rejected = 2,
    status_unknown = 3,
};

fn fakeServiceEventSha256(
    descriptor: adapter_contract.DescriptorV1,
    request_sha256: Digest,
    authority_revision: u64,
    kind: FakeEventKindV1,
    attempt_generation: u64,
) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(service_event_domain);
    hash.update(&descriptor.descriptor_sha256);
    hashU64(&hash, descriptor.authority_epoch);
    hash.update(&request_sha256);
    hashU64(&hash, authority_revision);
    hashU8(&hash, @intFromEnum(kind));
    hashU64(&hash, attempt_generation);
    return finish(&hash);
}

fn hashU8(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u8,
) void {
    hash.update(&.{value});
}

fn hashU64(
    hash: *std.crypto.hash.sha2.Sha256,
    value: u64,
) void {
    var encoded: [8]u8 = undefined;
    std.mem.writeInt(u64, &encoded, value, .little);
    hash.update(&encoded);
}

fn finish(hash: *std.crypto.hash.sha2.Sha256) Digest {
    var result: Digest = undefined;
    hash.final(&result);
    return result;
}

fn digest(label: []const u8) Digest {
    var result: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(label, &result, .{});
    return result;
}

fn digestIsZero(value: Digest) bool {
    return digestEqual(value, zero_digest);
}

fn digestEqual(left: Digest, right: Digest) bool {
    return std.mem.eql(u8, &left, &right);
}

const TestJournalV1 = struct {
    descriptor: adapter_contract.DescriptorV1,
    header: outbox.HeaderV1,
    states: [4]outbox.ActionStateV1 =
        [_]outbox.ActionStateV1{.{}} ** 4,
    ledger: outbox.LedgerV1 = .{},
    previous_journal_sha256: Digest,
    sequence: u64 = 0,
    action_sha256: Digest,

    fn init() !TestJournalV1 {
        const descriptor =
            try adapter_contract.makeDescriptorV1(
                0x4641_4b45_0000_0001,
                17,
                digest("fake authority namespace"),
                digest("fake request schema"),
                digest("fake result schema"),
            );
        const header = try outbox.makeHeaderV1(
            7,
            9,
            41,
            4,
            32,
            4096,
            descriptor.descriptor_sha256,
            digest("payload store"),
            digest("outbox challenge"),
        );
        const tool_descriptor = try action.makeDescriptorV1(
            3,
            digest("tool namespace"),
            digest("arguments schema"),
            digest("result schema"),
            digest("tool implementation"),
        );
        const arguments =
            try action.makeBoundedAddArgumentsV1(88, 3);
        const proposal = try action.makeActionProposalV1(
            41,
            1,
            digest("agent request"),
            tool_descriptor,
            arguments,
            digest("idempotency key"),
        );
        const policy = try action.makePolicyV1(
            5,
            41,
            true,
            16,
            -100,
            100,
            tool_descriptor,
            digest("policy challenge"),
        );
        const authorization =
            try action.authorizeBoundedAddV1(
                proposal,
                tool_descriptor,
                arguments,
                policy,
                0,
            );
        const identity = try outbox.makeActionIdentityV1(
            header,
            .primary,
            zero_digest,
            tool_descriptor,
            arguments,
            proposal,
            policy,
            authorization,
            digest("authorization service event"),
            digest("payload locator"),
            32,
            digest("payload"),
        );
        var result: TestJournalV1 = .{
            .descriptor = descriptor,
            .header = header,
            .previous_journal_sha256 = header.header_sha256,
            .action_sha256 = identity.action_sha256,
        };
        const enqueued = try outbox.makeEnqueuedRecordV1(
            header,
            1,
            header.header_sha256,
            identity,
        );
        try outbox.applyRecordV1(
            header,
            enqueued,
            &result.states,
            &result.ledger,
        );
        result.sequence = 1;
        result.previous_journal_sha256 =
            enqueued.record_sha256;
        return result;
    }

    fn state(self: *const TestJournalV1) outbox.ActionStateV1 {
        return self.states[0];
    }

    fn dispatchIntent(
        self: *TestJournalV1,
    ) !outbox.RecordV1 {
        const current = self.state();
        const generation = try std.math.add(
            u64,
            current.attempt_generation,
            1,
        );
        const record = try outbox.makeTransitionRecordV1(
            self.header,
            self.sequence + 1,
            self.previous_journal_sha256,
            current,
            .dispatch_intent,
            generation,
            zero_digest,
            zero_digest,
        );
        try self.apply(record);
        return record;
    }

    fn applyTransition(
        self: *TestJournalV1,
        transition: adapter_contract.TransitionSpecV1,
    ) !outbox.RecordV1 {
        const record = try outbox.makeTransitionRecordV1(
            self.header,
            self.sequence + 1,
            self.previous_journal_sha256,
            self.state(),
            transition.kind,
            transition.attempt_generation,
            transition.observation_sha256,
            transition.result_sha256,
        );
        try self.apply(record);
        return record;
    }

    fn apply(
        self: *TestJournalV1,
        record: outbox.RecordV1,
    ) !void {
        try outbox.applyRecordV1(
            self.header,
            record,
            &self.states,
            &self.ledger,
        );
        self.sequence = record.sequence;
        self.previous_journal_sha256 =
            record.record_sha256;
    }
};

fn successPlan() !DispatchPlanV1 {
    return makeDispatchPlanV1(
        .succeeded,
        digest("fake success service event"),
        digest("fake success result"),
    );
}

fn failurePlan() !DispatchPlanV1 {
    return makeDispatchPlanV1(
        .terminal_failure,
        digest("fake failure service event"),
        digest("fake failure result"),
    );
}

fn pendingPlan() !DispatchPlanV1 {
    return makeDispatchPlanV1(
        .pending,
        digest("fake pending service event"),
        zero_digest,
    );
}

const credential_a = [_]u8{0xa5} ** credential_bytes;
const credential_b = [_]u8{0x5a} ** credential_bytes;

test "opaque credential never influences portable evidence" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    var first = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );
    defer first.deinit();
    var second = try AuthorityV1.init(
        journal.descriptor,
        credential_b,
        4,
        try successPlan(),
    );
    defer second.deinit();

    const first_evidence =
        try adapter_contract.dispatchV1(
            first.adapter(),
            request,
        );
    const second_evidence =
        try adapter_contract.dispatchV1(
            second.adapter(),
            request,
        );
    try std.testing.expectEqualDeep(
        first_evidence,
        second_evidence,
    );
    try std.testing.expect(
        std.mem.indexOf(
            u8,
            std.mem.asBytes(&first_evidence),
            &credential_a,
        ) == null,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        first.state().counters.application_count,
    );
}

test "terminal dispatch duplicate replays exactly once" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );
    defer authority.deinit();

    const first = try adapter_contract.dispatchV1(
        authority.adapter(),
        request,
    );
    const duplicate = try adapter_contract.dispatchV1(
        authority.adapter(),
        request,
    );
    try std.testing.expectEqualDeep(first, duplicate);
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1.succeeded,
        first.disposition,
    );
    const state = authority.state();
    try std.testing.expectEqual(
        @as(u64, 1),
        state.counters.application_count,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        state.counters.terminal_duplicate_replays,
    );
    var resealed = request;
    resealed.intent_record_sha256 = digest("resealed terminal intent");
    resealed.request_sha256 =
        adapter_contract.dispatchRequestSha256V1(resealed);
    try std.testing.expectError(
        adapter_contract.CallbackError.RequestRejected,
        adapter_contract.dispatchV1(
            authority.adapter(),
            resealed,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.terminal_duplicate_replays,
    );
    const entry = authority.entryState(
        request.stable_remote_request_sha256,
    ).?;
    try std.testing.expectEqual(@as(u64, 1), entry.application_count);
}

test "status fence rejects stale dispatch then permits exact next generation" {
    var journal = try TestJournalV1.init();
    const first_intent = try journal.dispatchIntent();
    const first_request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            first_intent,
        );
    const status_request =
        try adapter_contract.makeStatusRequestV1(
            journal.descriptor,
            journal.header,
            journal.state(),
            1,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );
    defer authority.deinit();

    const fenced = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    try std.testing.expectEqual(
        adapter_contract.StatusDispositionV1.not_applied_fenced,
        fenced.disposition,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        fenced.fence_through_generation,
    );
    const transition =
        (try adapter_contract.transitionFromStatusV1(
            journal.descriptor,
            status_request,
            fenced,
        )).?;
    try std.testing.expectEqual(
        outbox.EventKindV1.reconciled_not_applied,
        transition.kind,
    );

    const stale = try adapter_contract.dispatchV1(
        authority.adapter(),
        first_request,
    );
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1
            .rejected_stale_generation,
        stale.disposition,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        authority.state().counters.application_count,
    );

    _ = try journal.applyTransition(transition);
    const second_intent = try journal.dispatchIntent();
    const second_request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            second_intent,
        );
    try std.testing.expect(digestEqual(
        first_request.stable_remote_request_sha256,
        second_request.stable_remote_request_sha256,
    ));
    try std.testing.expect(!digestEqual(
        first_request.dispatch_request_sha256,
        second_request.dispatch_request_sha256,
    ));
    const applied = try adapter_contract.dispatchV1(
        authority.adapter(),
        second_request,
    );
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1.succeeded,
        applied.disposition,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.application_count,
    );
    const late_stale = try adapter_contract.dispatchV1(
        authority.adapter(),
        first_request,
    );
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1
            .rejected_stale_generation,
        late_stale.disposition,
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        authority.state().counters.stale_generation_rejections,
    );
}

test "repeated fenced status is idempotent and skipped dispatch rejects" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    const status_request =
        try adapter_contract.makeStatusRequestV1(
            journal.descriptor,
            journal.header,
            journal.state(),
            1,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );
    defer authority.deinit();

    const first = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    const duplicate = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    try std.testing.expectEqualDeep(first, duplicate);
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.fence_installations,
    );

    var skipped = request;
    skipped.attempt_generation = 3;
    skipped.dispatch_request_sha256 = digest("skipped dispatch");
    skipped.intent_record_sha256 = digest("skipped intent");
    skipped.request_sha256 =
        adapter_contract.dispatchRequestSha256V1(skipped);
    try std.testing.expectError(
        adapter_contract.CallbackError.RequestRejected,
        adapter_contract.dispatchV1(
            authority.adapter(),
            skipped,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        authority.state().counters.application_count,
    );
}

test "dispatch pending stays uncertain until exact completion" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const dispatch_request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    const status_request =
        try adapter_contract.makeStatusRequestV1(
            journal.descriptor,
            journal.header,
            journal.state(),
            1,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try pendingPlan(),
    );
    defer authority.deinit();

    const dispatch_evidence =
        try adapter_contract.dispatchV1(
            authority.adapter(),
            dispatch_request,
        );
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1.indeterminate,
        dispatch_evidence.disposition,
    );
    const pending = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    try std.testing.expectEqual(
        adapter_contract.StatusDispositionV1.pending,
        pending.disposition,
    );
    try std.testing.expect(
        (try adapter_contract.transitionFromStatusV1(
            journal.descriptor,
            status_request,
            pending,
        )) == null,
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        authority.state().counters.application_count,
    );

    _ = try authority.completePending(
        dispatch_request.stable_remote_request_sha256,
        .succeeded,
        digest("completed pending service event"),
        digest("completed pending result"),
    );
    const terminal = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    try std.testing.expectEqual(
        adapter_contract.StatusDispositionV1.succeeded,
        terminal.disposition,
    );
    const replay = try adapter_contract.dispatchV1(
        authority.adapter(),
        dispatch_request,
    );
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1.succeeded,
        replay.disposition,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.application_count,
    );
}

test "unknown status never installs a retry fence" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const dispatch_request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    const status_request =
        try adapter_contract.makeStatusRequestV1(
            journal.descriptor,
            journal.header,
            journal.state(),
            1,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );
    defer authority.deinit();
    authority.setStatusUnknown(true);

    const unknown = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    try std.testing.expectEqual(
        adapter_contract.StatusDispositionV1.unknown,
        unknown.disposition,
    );
    try std.testing.expect(
        (try adapter_contract.transitionFromStatusV1(
            journal.descriptor,
            status_request,
            unknown,
        )) == null,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        authority.state().entry_count,
    );

    authority.setStatusUnknown(false);
    const applied = try adapter_contract.dispatchV1(
        authority.adapter(),
        dispatch_request,
    );
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1.succeeded,
        applied.disposition,
    );
}

test "dispatch first wins status order without installing a fence" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const dispatch_request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    const status_request =
        try adapter_contract.makeStatusRequestV1(
            journal.descriptor,
            journal.header,
            journal.state(),
            1,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );
    defer authority.deinit();

    _ = try adapter_contract.dispatchV1(
        authority.adapter(),
        dispatch_request,
    );
    const status = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    try std.testing.expectEqual(
        adapter_contract.StatusDispositionV1.succeeded,
        status.disposition,
    );
    const state = authority.state();
    try std.testing.expectEqual(
        @as(u64, 0),
        state.counters.fence_installations,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        state.counters.application_count,
    );
}

test "terminal failure replays without a second application" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const dispatch_request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    const status_request =
        try adapter_contract.makeStatusRequestV1(
            journal.descriptor,
            journal.header,
            journal.state(),
            1,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try failurePlan(),
    );
    defer authority.deinit();

    const first = try adapter_contract.dispatchV1(
        authority.adapter(),
        dispatch_request,
    );
    const second = try adapter_contract.dispatchV1(
        authority.adapter(),
        dispatch_request,
    );
    try std.testing.expectEqualDeep(first, second);
    try std.testing.expectEqual(
        adapter_contract.DispatchDispositionV1.terminal_failure,
        first.disposition,
    );
    const status = try adapter_contract.statusV1(
        authority.adapter(),
        status_request,
    );
    try std.testing.expectEqual(
        adapter_contract.StatusDispositionV1.failed,
        status.disposition,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.application_count,
    );
}

test "stable request binding rejects identity and payload substitution" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );
    defer authority.deinit();
    _ = try adapter_contract.dispatchV1(
        authority.adapter(),
        request,
    );

    var changed_action = request;
    changed_action.action_sha256 = digest("foreign action");
    changed_action.request_sha256 =
        adapter_contract.dispatchRequestSha256V1(
            changed_action,
        );
    try std.testing.expectError(
        adapter_contract.CallbackError.RequestRejected,
        adapter_contract.dispatchV1(
            authority.adapter(),
            changed_action,
        ),
    );

    var changed_payload = request;
    changed_payload.payload_sha256 = digest("foreign payload");
    changed_payload.request_sha256 =
        adapter_contract.dispatchRequestSha256V1(
            changed_payload,
        );
    try std.testing.expectError(
        adapter_contract.CallbackError.RequestRejected,
        adapter_contract.dispatchV1(
            authority.adapter(),
            changed_payload,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        authority.state().counters.application_count,
    );
}

test "identity conflict and bounded capacity fail without mutation" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        1,
        try successPlan(),
    );
    defer authority.deinit();
    _ = try adapter_contract.dispatchV1(
        authority.adapter(),
        request,
    );

    var identity_conflict = request;
    identity_conflict.stable_remote_request_sha256 =
        digest("foreign stable request");
    identity_conflict.dispatch_request_sha256 =
        digest("foreign dispatch request");
    identity_conflict.intent_record_sha256 =
        digest("foreign intent");
    identity_conflict.request_sha256 =
        adapter_contract.dispatchRequestSha256V1(
            identity_conflict,
        );
    try std.testing.expectError(
        adapter_contract.CallbackError.RequestRejected,
        adapter_contract.dispatchV1(
            authority.adapter(),
            identity_conflict,
        ),
    );

    var capacity = identity_conflict;
    capacity.action_sha256 = digest("second action");
    capacity.idempotency_key_sha256 = digest("second idempotency");
    capacity.stable_remote_request_sha256 =
        digest("second stable request");
    capacity.dispatch_request_sha256 =
        digest("second dispatch request");
    capacity.intent_record_sha256 = digest("second intent");
    capacity.payload_locator_sha256 =
        digest("second payload locator");
    capacity.payload_sha256 = digest("second payload");
    capacity.request_sha256 =
        adapter_contract.dispatchRequestSha256V1(capacity);
    try std.testing.expectError(
        adapter_contract.CallbackError.CapacityExceeded,
        adapter_contract.dispatchV1(
            authority.adapter(),
            capacity,
        ),
    );
    const state = authority.state();
    try std.testing.expectEqual(@as(usize, 1), state.entry_count);
    try std.testing.expectEqual(
        @as(u64, 1),
        state.counters.application_count,
    );
}

test "descriptor epoch and credential availability remain fail closed" {
    var journal = try TestJournalV1.init();
    const intent = try journal.dispatchIntent();
    const request =
        try adapter_contract.makeDispatchRequestV1(
            journal.descriptor,
            journal.header,
            intent,
        );
    var authority = try AuthorityV1.init(
        journal.descriptor,
        credential_a,
        4,
        try successPlan(),
    );

    var foreign = request;
    foreign.adapter_descriptor_sha256 =
        digest("foreign adapter descriptor");
    foreign.request_sha256 =
        adapter_contract.dispatchRequestSha256V1(foreign);
    try std.testing.expectError(
        adapter_contract.Error.InvalidBinding,
        adapter_contract.dispatchV1(
            authority.adapter(),
            foreign,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        authority.state().counters.dispatch_calls,
    );

    authority.setAvailable(false);
    try std.testing.expectError(
        adapter_contract.CallbackError.AuthorityUnavailable,
        adapter_contract.dispatchV1(
            authority.adapter(),
            request,
        ),
    );
    authority.setAvailable(true);
    authority.deinit();
    try std.testing.expectError(
        adapter_contract.CallbackError.CredentialRejected,
        adapter_contract.dispatchV1(
            authority.adapter(),
            request,
        ),
    );
    try std.testing.expect(
        !authority.state().credential_loaded,
    );
}

test "authority storage is bounded and entry state has no pointers" {
    try std.testing.expect(maximum_entries > 0);
    try std.testing.expect(
        !typeHasPointer(EntryV1),
    );
    try std.testing.expect(
        !typeHasPointer(EntryStateV1),
    );
    try std.testing.expectError(
        Error.InvalidCapacity,
        AuthorityV1.init(
            (try TestJournalV1.init()).descriptor,
            credential_a,
            0,
            try successPlan(),
        ),
    );
    try std.testing.expectError(
        Error.InvalidCredential,
        AuthorityV1.init(
            (try TestJournalV1.init()).descriptor,
            [_]u8{0} ** credential_bytes,
            1,
            try successPlan(),
        ),
    );
}

fn typeHasPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |optional| typeHasPointer(optional.child),
        .array => |array| typeHasPointer(array.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (typeHasPointer(field.type)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}
