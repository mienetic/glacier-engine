//! Concrete contiguous-state adapter for width-one AI publication.
//!
//! The portable Lane publication contract commits typed digests. This module
//! derives those digests from one exact KVCache, RNG state, sampling counter,
//! and caller-owned output journal, then changes all four only inside the
//! Scheduler finalizer. A rejected attempt leaves no logical KV row, RNG
//! advance, sampling advance, or visible output token behind.
//!
//! V1 deliberately uses strict full-prefix hashing to detect mutation through
//! the KVCache's public buffers. It is a high-integrity path, not yet the
//! low-overhead Merkle/page adapter planned for sustained production decode.

const std = @import("std");
const core = @import("core");
const lane = core.lane_weave_qos;
const resource_bank = core.resource_bank;
const kv = @import("kv_cache.zig");
const publication = @import("lane_publication_txn.zig");

pub const abi: u64 = 0x474c_434f_0000_0001;
pub const rng_state_abi: u64 = 0x474c_4352_0000_0001;
pub const Digest = publication.Digest;
pub const RngState = [4]u64;

const kv_row_domain = "glacier-contiguous-kv-row-v1\x00";
const rng_domain = "glacier-contiguous-rng-state-v1\x00";
const output_root_domain = "glacier-contiguous-output-root-v1\x00";

pub const Error = error{
    InvalidConfiguration,
    InvalidBinding,
    InvalidState,
    InsufficientResourceClaim,
    InvalidStage,
    StateDrift,
    RecoveryRequired,
};

pub const BindingsV1 = struct {
    cache: *kv.KVCache,
    rng_state: *RngState,
    sampling_calls: *u64,
    output: []u32,
    output_len: *usize,
};

/// One private token candidate. The first output after prefill must omit a KV
/// mark because its logits already exist; every later output owns exactly one
/// fully written row containing the preceding selected token. Forced tokens
/// keep `sampling_calls_after` and `rng_after` unchanged.
pub const StageV1 = struct {
    kv_mark: ?kv.RowTxnMark = null,
    rng_after: RngState,
    sampling_calls_after: u64,
    token_id: u32,
    terminal: bool = false,
};

const Phase = enum(u8) {
    idle,
    ready,
    prepared,
    recovery,
};

const ActiveAttempt = struct {
    transition: publication.TokenTransitionV1,
    rng_after: RngState,
    prepared_kv: ?kv.PreparedRowCommit,
    physical_kv_before_sha256: Digest,
    physical_kv_after_sha256: Digest,
    downstream: publication.SinkV1,
    downstream_prepared: bool = false,
    downstream_proposal: publication.ProposalV1 = .{},
    downstream_ack: publication.PrepareAckV1 = .{},
};

/// Address-stable adapter. Do not move or copy after successful `init`.
pub const Session = struct {
    mutex: std.Thread.Mutex = .{},
    inner: publication.Session = .{},
    scheduler: *lane.Scheduler = undefined,
    bank: *resource_bank.Bank = undefined,
    admission: lane.Admission = undefined,
    request_epoch: u64 = 0,
    bindings: BindingsV1 = undefined,
    physical_kv_sha256: Digest = publication.zero_digest,
    initialized: bool = false,
    phase: Phase = .idle,
    active: ?ActiveAttempt = null,

    pub fn init(
        self: *Session,
        scheduler: *lane.Scheduler,
        bank: *resource_bank.Bank,
        admission: lane.Admission,
        request_epoch: u64,
        bindings: BindingsV1,
    ) (Error || publication.Error || lane.Error)!void {
        if (self.initialized) return Error.InvalidState;
        try validateBindings(admission, bindings);

        const physical_kv_sha256 = logicalKvPrefixSha256(
            bindings.cache,
            bindings.cache.len,
        );
        const initial_state = publication.makeStateCommitmentV1(
            abi,
            @intCast(bindings.cache.len),
            physical_kv_sha256,
            rng_state_abi,
            rngStateSha256(bindings.rng_state.*),
            0,
            0,
            initialOutputStateSha256(),
        );

        self.* = .{
            .scheduler = scheduler,
            .bank = bank,
            .admission = admission,
            .request_epoch = request_epoch,
            .bindings = bindings,
            .physical_kv_sha256 = physical_kv_sha256,
        };
        self.inner.init(
            scheduler,
            bank,
            admission,
            request_epoch,
            abi,
            initial_state,
        ) catch |err| {
            self.* = .{};
            return err;
        };
        self.initialized = true;
    }

    /// Cancel an active bound request and return its atomic Event-v1 terminal
    /// evidence after verifying that no concrete state escaped privately.
    pub fn cancel(
        self: *Session,
    ) (Error || publication.Error || lane.Error)!lane.EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized or self.phase != .idle or self.active != null)
            return Error.InvalidState;
        _ = try self.snapshotVerifiedLocked();
        const event = try self.inner.cancel();
        self.initialized = false;
        return event;
    }

    /// Retire a finished bound request and return its atomic Event-v1 terminal
    /// evidence after re-verifying every concrete state commitment.
    pub fn retire(
        self: *Session,
    ) (Error || publication.Error || lane.Error)!lane.EventV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized or self.phase != .idle or self.active != null)
            return Error.InvalidState;
        _ = try self.snapshotVerifiedLocked();
        const event = try self.inner.retire();
        self.initialized = false;
        return event;
    }

    /// Convenience atomic terminal path for callers that do not retain
    /// Event-v1. The inner Session selects retire versus cancel from its exact
    /// committed publication count.
    pub fn close(
        self: *Session,
    ) (Error || publication.Error || lane.Error)!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized or self.phase != .idle or self.active != null)
            return Error.InvalidState;
        _ = try self.snapshotVerifiedLocked();
        try self.inner.close();
        self.initialized = false;
    }

    /// Return a portable snapshot only after re-hashing every bound physical
    /// state. This is intentionally O(committed KV + output length).
    pub fn snapshotVerified(
        self: *Session,
    ) (Error || publication.Error)!publication.TranscriptSnapshotV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.snapshotVerifiedLocked();
    }

    pub fn publish(
        self: *Session,
        permit: lane.ServicePermitV1,
        stage: StageV1,
        downstream: publication.SinkV1,
    ) (Error || publication.Error || lane.Error || kv.RowTxnError)!publication.CommitReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.initialized) return Error.InvalidState;

        const transition = self.prepareAttempt(stage, downstream) catch |err| {
            self.scheduler.abortService(permit) catch
                return Error.RecoveryRequired;
            return err;
        };

        const receipt = self.inner.publish(
            permit,
            transition,
            self.adapterSink(),
        ) catch |err| {
            if (self.active) |active|
                self.discardActive(!self.baseEvidenceValid(active));
            if (self.phase == .recovery or err == error.RecoveryRequired)
                return Error.RecoveryRequired;
            return err;
        };
        if (self.active != null or self.phase != .idle)
            @panic("contiguous publication returned with an active attempt");
        return receipt;
    }

    fn prepareAttempt(
        self: *Session,
        stage: StageV1,
        downstream: publication.SinkV1,
    ) (Error || publication.Error || kv.RowTxnError)!publication.TokenTransitionV1 {
        if (self.phase != .idle or self.active != null)
            return Error.InvalidState;

        const snapshot = try self.inner.snapshot();
        self.bank.validatePublicationSession(
            self.admission.event.resource_receipt,
            self.request_epoch,
            @intFromPtr(&self.inner),
            snapshot.next_sequence,
        ) catch return Error.InvalidBinding;
        if (snapshot.terminal) return Error.InvalidState;

        const output_before = std.math.cast(
            usize,
            snapshot.state.output_length,
        ) orelse return Error.InvalidState;
        try self.validateActualState(
            snapshot.state,
            snapshot.terminal,
            output_before != 0,
        );
        var prepared_kv: ?kv.PreparedRowCommit = null;
        if (output_before == 0) {
            if (stage.kv_mark != null or self.bindings.cache.rowTxnActive())
                return Error.InvalidStage;
        } else {
            const mark = stage.kv_mark orelse return Error.InvalidStage;
            if (mark.row_count != 1 or mark.base_len != self.bindings.cache.len)
                return Error.InvalidStage;
            prepared_kv = self.bindings.cache.prepareCommit(mark) catch |err| {
                self.bindings.cache.abortRows(mark) catch {
                    if (self.bindings.cache.rowTxnActive()) {
                        self.phase = .recovery;
                        return Error.RecoveryRequired;
                    }
                };
                return err;
            };
        }
        if (downstream.abi_version != publication.sink_abi) {
            if (prepared_kv) |prepared|
                self.bindings.cache.abortPreparedAssumeValid(prepared);
            return Error.InvalidConfiguration;
        }

        const current_calls = self.bindings.sampling_calls.*;
        const maximum_calls = std.math.add(u64, current_calls, 1) catch
            return Error.InvalidStage;
        if (stage.sampling_calls_after < current_calls or
            stage.sampling_calls_after > maximum_calls or
            (stage.sampling_calls_after == current_calls and
                !std.meta.eql(stage.rng_after, self.bindings.rng_state.*)))
        {
            if (prepared_kv) |prepared|
                self.bindings.cache.abortPreparedAssumeValid(prepared);
            return Error.InvalidStage;
        }

        const row_sha256 = if (prepared_kv) |prepared|
            logicalKvRowSha256(self.bindings.cache, prepared)
        else
            publication.zero_digest;
        const physical_after_sha256 = if (prepared_kv != null)
            logicalKvPrefixSha256(
                self.bindings.cache,
                self.bindings.cache.len + 1,
            )
        else
            self.physical_kv_sha256;
        const transition = publication.makeTokenTransitionWithSamplingV1(
            snapshot.state,
            row_sha256,
            rngStateSha256(stage.rng_after),
            stage.sampling_calls_after,
            stage.token_id,
            stage.terminal,
        ) catch |err| {
            if (prepared_kv) |prepared|
                self.bindings.cache.abortPreparedAssumeValid(prepared);
            return err;
        };

        self.active = .{
            .transition = transition,
            .rng_after = stage.rng_after,
            .prepared_kv = prepared_kv,
            .physical_kv_before_sha256 = self.physical_kv_sha256,
            .physical_kv_after_sha256 = physical_after_sha256,
            .downstream = downstream,
        };
        self.phase = .ready;
        return transition;
    }

    fn snapshotVerifiedLocked(
        self: *Session,
    ) (Error || publication.Error)!publication.TranscriptSnapshotV1 {
        if (!self.initialized or self.phase != .idle or self.active != null)
            return Error.InvalidState;
        const snapshot = try self.inner.snapshot();
        try self.validateActualState(snapshot.state, snapshot.terminal, false);
        return snapshot;
    }

    fn validateActualState(
        self: *Session,
        state: publication.StateCommitmentV1,
        terminal: bool,
        allow_private_row: bool,
    ) Error!void {
        if (!allow_private_row and self.bindings.cache.rowTxnActive())
            return Error.StateDrift;
        const kv_position = std.math.cast(
            usize,
            state.kv_position,
        ) orelse return Error.StateDrift;
        const output_length = std.math.cast(
            usize,
            state.output_length,
        ) orelse return Error.StateDrift;
        if (state.execution_abi != abi or state.rng_state_abi != rng_state_abi or
            self.bindings.cache.len != kv_position or
            self.bindings.sampling_calls.* != state.sampling_calls or
            self.bindings.output_len.* != output_length)
            return Error.StateDrift;
        if (!std.mem.eql(
            u8,
            &self.physical_kv_sha256,
            &logicalKvPrefixSha256(
                self.bindings.cache,
                self.bindings.cache.len,
            ),
        ) or !std.mem.eql(
            u8,
            &state.rng_state_sha256,
            &rngStateSha256(self.bindings.rng_state.*),
        )) return Error.StateDrift;
        const output_len = self.bindings.output_len.*;
        if (output_len > self.bindings.output.len or !std.mem.eql(
            u8,
            &state.output_state_sha256,
            &outputStateSha256(
                self.bindings.output[0..output_len],
                terminal,
            ),
        )) return Error.StateDrift;
    }

    fn adapterSink(self: *Session) publication.SinkV1 {
        return .{
            .context = self,
            .prepare = adapterPrepare,
            .commit = adapterCommit,
            .abort = adapterAbort,
        };
    }

    fn adapterPrepare(
        context: *anyopaque,
        proposal: *const publication.ProposalV1,
        ack: *publication.PrepareAckV1,
    ) publication.SinkPrepareError!void {
        const self: *Session = @ptrCast(@alignCast(context));
        if (self.phase != .ready or self.active == null) {
            self.discardActive(true);
            return error.InvalidEvidence;
        }
        if (!std.meta.eql(
            proposal.transition,
            self.active.?.transition,
        ) or !self.activeEvidenceValid()) {
            const base_valid = self.baseEvidenceValid(self.active.?);
            self.discardActive(!base_valid);
            return error.InvalidEvidence;
        }

        const downstream = self.active.?.downstream;
        downstream.prepare(downstream.context, proposal, ack) catch |err| {
            const base_valid = self.baseEvidenceValid(self.active.?);
            self.discardActive(!base_valid);
            return err;
        };
        self.active.?.downstream_prepared = true;
        self.active.?.downstream_proposal = proposal.*;
        self.active.?.downstream_ack = ack.*;

        if (!self.activeEvidenceValid()) {
            const base_valid = self.baseEvidenceValid(self.active.?);
            self.discardActive(!base_valid);
            return error.InvalidEvidence;
        }
        self.phase = .prepared;
    }

    fn adapterCommit(
        context: *anyopaque,
        receipt: *const publication.CommitReceiptV1,
    ) void {
        const self: *Session = @ptrCast(@alignCast(context));
        if (self.phase != .prepared or self.active == null)
            @panic("contiguous publication commit without prepare");
        const active = self.active.?;
        if (active.prepared_kv) |prepared|
            self.bindings.cache.commitPreparedAssumeValid(prepared);
        self.bindings.rng_state.* = active.rng_after;
        self.bindings.sampling_calls.* =
            active.transition.after.sampling_calls;
        const output_index = self.bindings.output_len.*;
        if (output_index >= self.bindings.output.len)
            @panic("prepared contiguous output exceeds capacity");
        self.bindings.output[output_index] = active.transition.token_id;
        self.bindings.output_len.* = output_index + 1;
        self.physical_kv_sha256 = active.physical_kv_after_sha256;
        active.downstream.commit(active.downstream.context, receipt);
        self.active = null;
        self.phase = .idle;
    }

    fn adapterAbort(
        context: *anyopaque,
        _: *const publication.ProposalV1,
        _: *const publication.PrepareAckV1,
    ) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.discardActive(false);
    }

    fn baseEvidenceValid(self: *Session, active: ActiveAttempt) bool {
        const kv_position = std.math.cast(
            usize,
            active.transition.before.kv_position,
        ) orelse return false;
        const output_length = std.math.cast(
            usize,
            active.transition.before.output_length,
        ) orelse return false;
        if (self.bindings.cache.len != kv_position or
            self.bindings.sampling_calls.* !=
                active.transition.before.sampling_calls or
            self.bindings.output_len.* != output_length)
            return false;
        if (!std.mem.eql(
            u8,
            &active.physical_kv_before_sha256,
            &logicalKvPrefixSha256(
                self.bindings.cache,
                self.bindings.cache.len,
            ),
        ) or !std.mem.eql(
            u8,
            &active.transition.before.rng_state_sha256,
            &rngStateSha256(self.bindings.rng_state.*),
        )) return false;
        const output_len = self.bindings.output_len.*;
        return output_len <= self.bindings.output.len and std.mem.eql(
            u8,
            &active.transition.before.output_state_sha256,
            &outputStateSha256(
                self.bindings.output[0..output_len],
                false,
            ),
        );
    }

    fn activeEvidenceValid(self: *Session) bool {
        const active = self.active orelse return false;
        if (!self.baseEvidenceValid(active) or !std.mem.eql(
            u8,
            &active.transition.after.rng_state_sha256,
            &rngStateSha256(active.rng_after),
        )) return false;
        if (active.prepared_kv) |prepared| {
            const expected = self.bindings.cache.prepareCommit(
                markFromPrepared(prepared),
            ) catch return false;
            if (!std.meta.eql(prepared, expected) or !std.mem.eql(
                u8,
                &active.transition.kv_row_sha256,
                &logicalKvRowSha256(self.bindings.cache, prepared),
            ) or !std.mem.eql(
                u8,
                &active.physical_kv_after_sha256,
                &logicalKvPrefixSha256(
                    self.bindings.cache,
                    self.bindings.cache.len + 1,
                ),
            )) return false;
        } else if (self.bindings.cache.rowTxnActive() or
            !std.mem.eql(
                u8,
                &active.physical_kv_before_sha256,
                &active.physical_kv_after_sha256,
            )) return false;
        return true;
    }

    /// Clear a failed attempt. If base state drifted, the Session stays in a
    /// fail-closed recovery phase even when its private KV tail was removable.
    fn discardActive(self: *Session, force_recovery: bool) void {
        const active = self.active orelse {
            if (force_recovery) self.phase = .recovery else self.phase = .idle;
            return;
        };
        if (active.downstream_prepared) active.downstream.abort(
            active.downstream.context,
            &active.downstream_proposal,
            &active.downstream_ack,
        );
        const base_state_recovered = self.baseEvidenceValid(active);
        var recovered_private_kv = true;
        if (active.prepared_kv) |prepared| {
            const current = self.bindings.cache.prepareCommit(
                markFromPrepared(prepared),
            ) catch null;
            if (current) |value| {
                if (std.meta.eql(value, prepared)) {
                    self.bindings.cache.abortPreparedAssumeValid(prepared);
                } else {
                    recovered_private_kv = false;
                }
            } else if (self.bindings.cache.rowTxnActive() or
                self.bindings.cache.len != prepared.base_len)
            {
                recovered_private_kv = false;
            }
        }
        self.active = null;
        self.phase = if (force_recovery or !base_state_recovered or
            !recovered_private_kv)
            .recovery
        else
            .idle;
    }
};

fn markFromPrepared(prepared: kv.PreparedRowCommit) kv.RowTxnMark {
    return .{
        .cache_id = prepared.cache_id,
        .cache_instance = prepared.cache_instance,
        .generation = prepared.generation,
        .base_len = prepared.base_len,
        .row_count = prepared.row_count,
    };
}

pub fn initialOutputStateSha256() Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(output_root_domain);
    hashU64(&hash, abi);
    return finish(&hash);
}

pub fn outputStateSha256(tokens: []const u32, terminal: bool) Digest {
    var digest = initialOutputStateSha256();
    for (tokens, 0..) |token, index| digest = publication.nextOutputStateSha256(
        digest,
        @intCast(index),
        token,
        terminal and index + 1 == tokens.len,
    );
    return digest;
}

pub fn rngStateSha256(state: RngState) Digest {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(rng_domain);
    hashU64(&hash, rng_state_abi);
    for (state) |word| hashU64(&hash, word);
    return finish(&hash);
}

/// Exact domain shared with generation-state telemetry. `positions` may name
/// one fully written private row beyond `cache.len`, but never allocation
/// slack or a partial layer set.
pub fn logicalKvPrefixSha256(
    cache: *kv.KVCache,
    positions: usize,
) Digest {
    std.debug.assert(positions <= cache.max_seq);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-logical-kv-state-v1\x00");
    hashU64(&hash, @intCast(cache.num_layers));
    hashU64(&hash, @intCast(cache.dim));
    hashU64(&hash, @intCast(positions));
    for (0..cache.num_layers) |layer| {
        for (cache.keysSliceCount(layer, positions)) |value|
            hashU32(&hash, @bitCast(value));
        for (cache.valuesSliceCount(layer, positions)) |value|
            hashU32(&hash, @bitCast(value));
    }
    return finish(&hash);
}

fn logicalKvRowSha256(
    cache: *kv.KVCache,
    prepared: kv.PreparedRowCommit,
) Digest {
    std.debug.assert(prepared.row_count == 1);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(kv_row_domain);
    hashU64(&hash, abi);
    hashU64(&hash, @intCast(cache.num_layers));
    hashU64(&hash, @intCast(cache.dim));
    hashU64(&hash, @intCast(prepared.base_len));
    const start = prepared.base_len * cache.dim;
    const end = start + cache.dim;
    for (0..cache.num_layers) |layer| {
        for (cache.keys[layer][start..end]) |value|
            hashU32(&hash, @bitCast(value));
        for (cache.values[layer][start..end]) |value|
            hashU32(&hash, @bitCast(value));
    }
    return finish(&hash);
}

fn validateBindings(
    admission: lane.Admission,
    bindings: BindingsV1,
) Error!void {
    const cache = bindings.cache;
    if (admission.event.spec.work_quanta == 0 or
        admission.event.spec.claim.queue_slots != publication.width or
        bindings.output_len.* != 0 or bindings.sampling_calls.* != 0 or
        cache.rowTxnActive() or !cacheShapeValid(cache) or
        bindingsOverlap(bindings))
        return Error.InvalidConfiguration;

    const work_quanta = std.math.cast(
        usize,
        admission.event.spec.work_quanta,
    ) orelse return Error.InvalidConfiguration;
    if (bindings.output.len < work_quanta) return Error.InvalidConfiguration;
    const required_rows = work_quanta - 1;
    if (cache.len > cache.max_seq or required_rows > cache.max_seq - cache.len)
        return Error.InvalidConfiguration;

    const kv_bytes = std.math.cast(
        u64,
        cache.logicalLedger().allocation_payload_bytes,
    ) orelse return Error.InvalidConfiguration;
    const output_bytes_usize = std.math.mul(
        usize,
        bindings.output.len,
        @sizeOf(u32),
    ) catch return Error.InvalidConfiguration;
    const output_bytes = std.math.cast(u64, output_bytes_usize) orelse
        return Error.InvalidConfiguration;
    const claim = admission.event.resource_receipt.claim;
    if (claim.kv_bytes < kv_bytes or
        claim.output_journal_bytes < output_bytes)
        return Error.InsufficientResourceClaim;
}

fn cacheShapeValid(cache: *kv.KVCache) bool {
    if (cache.num_layers == 0 or cache.dim == 0 or cache.max_seq == 0 or
        cache.len > cache.max_seq or cache.keys.len != cache.num_layers or
        cache.values.len != cache.num_layers)
        return false;
    const row_elements = std.math.mul(
        usize,
        cache.max_seq,
        cache.dim,
    ) catch return false;
    const expected = kv.deriveLogicalLedger(
        cache.num_layers,
        cache.dim,
        cache.max_seq,
    ) catch return false;
    if (!std.meta.eql(expected, cache.logicalLedger())) return false;
    for (0..cache.num_layers) |layer|
        if (cache.keys[layer].len != row_elements or
            cache.values[layer].len != row_elements)
            return false;
    const count = 3 + 2 * cache.num_layers;
    for (0..count) |left_index| {
        const left = cacheSpan(cache, left_index) orelse return false;
        for (left_index + 1..count) |right_index| {
            const right = cacheSpan(cache, right_index) orelse return false;
            if (overlaps(left, right)) return false;
        }
    }
    return true;
}

const Span = struct { start: usize, end: usize };

fn bindingsOverlap(bindings: BindingsV1) bool {
    const external = [_]?Span{
        span(@intFromPtr(bindings.rng_state), @sizeOf(RngState)),
        span(@intFromPtr(bindings.sampling_calls), @sizeOf(u64)),
        span(@intFromPtr(bindings.output.ptr), std.math.mul(usize, bindings.output.len, @sizeOf(u32)) catch
            return true),
        span(@intFromPtr(bindings.output_len), @sizeOf(usize)),
    };
    for (external, 0..) |maybe_left, left_index| {
        const left = maybe_left orelse return true;
        for (external[left_index + 1 ..]) |maybe_right| {
            const right = maybe_right orelse return true;
            if (overlaps(left, right)) return true;
        }
        const cache_count = 3 + 2 * bindings.cache.num_layers;
        for (0..cache_count) |cache_index| {
            const cache_memory = cacheSpan(
                bindings.cache,
                cache_index,
            ) orelse return true;
            if (overlaps(left, cache_memory)) return true;
        }
    }
    return false;
}

fn cacheSpan(cache: *kv.KVCache, index: usize) ?Span {
    if (index == 0) return span(@intFromPtr(cache), @sizeOf(kv.KVCache));
    if (index == 1) return span(
        @intFromPtr(cache.keys.ptr),
        std.math.mul(usize, cache.keys.len, @sizeOf([]f32)) catch return null,
    );
    if (index == 2) return span(
        @intFromPtr(cache.values.ptr),
        std.math.mul(usize, cache.values.len, @sizeOf([]f32)) catch return null,
    );
    const payload_index = index - 3;
    const layer = payload_index / 2;
    if (layer >= cache.num_layers) return null;
    const values = payload_index % 2 == 1;
    const payload = if (values) cache.values[layer] else cache.keys[layer];
    return span(
        @intFromPtr(payload.ptr),
        std.math.mul(usize, payload.len, @sizeOf(f32)) catch return null,
    );
}

fn span(start: usize, byte_len: usize) ?Span {
    if (byte_len == 0) return .{ .start = start, .end = start };
    const end = std.math.add(usize, start, byte_len) catch return null;
    return .{ .start = start, .end = end };
}

fn overlaps(left: Span, right: Span) bool {
    if (left.start == left.end or right.start == right.end) return false;
    return left.start < right.end and right.start < left.end;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestFixture = struct {
    bank_slots: [1]resource_bank.Slot = undefined,
    lane_slots: [1]lane.Slot = undefined,
    projection: [1]lane.ProjectionSlot = undefined,
    bank: resource_bank.Bank = undefined,
    scheduler: lane.Scheduler = undefined,
    admission: lane.Admission = undefined,

    fn init(
        self: *TestFixture,
        work_quanta: u64,
        claim: resource_bank.Claim,
    ) !void {
        self.bank = try resource_bank.Bank.init(
            &self.bank_slots,
            .{
                .host_bytes = 1 << 20,
                .kv_bytes = 1 << 20,
                .output_journal_bytes = 1 << 20,
                .queue_slots = 1,
            },
            0x434f_4241,
        );
        self.scheduler = try lane.Scheduler.init(
            &self.bank,
            .{ .slots = &self.lane_slots, .projection = &self.projection },
            .{
                .scheduler_epoch = 0x434f_5343,
                .challenge = [_]u8{0xc1} ** 32,
                .max_weight = 8,
            },
        );
        var exact_claim = claim;
        exact_claim.queue_slots = 1;
        const decision = try self.scheduler.admit(.{
            .tenant_key = 41,
            .request_key = 42,
            .request_generation = 1,
            .resource_owner_key = 43,
            .weight = 1,
            .work_quanta = work_quanta,
            .claim = exact_claim,
        });
        self.admission = switch (decision) {
            .admitted => |value| value,
            .rejected => return Error.InvalidState,
        };
    }

    fn finishRequest(self: *TestFixture, session: *Session) !void {
        _ = try session.retire();
        const snapshot = try self.bank.snapshot();
        try testing.expect(snapshot.used.isZero());
        _ = try self.scheduler.close();
    }
};

const Mutation = enum {
    none,
    private_row,
    committed_prefix,
};

const TestSink = struct {
    cache: ?*kv.KVCache = null,
    reject: bool = false,
    corrupt_ack: bool = false,
    mutation: Mutation = .none,
    prepare_calls: usize = 0,
    commit_calls: usize = 0,
    abort_calls: usize = 0,
    receipts: [4]publication.CommitReceiptV1 = undefined,

    fn interface(self: *TestSink) publication.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        context: *anyopaque,
        proposal: *const publication.ProposalV1,
        ack: *publication.PrepareAckV1,
    ) publication.SinkPrepareError!void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.prepare_calls += 1;
        if (self.reject) return error.Unavailable;
        ack.* = .{
            .proposal_sha256 = publication.proposalSha256(proposal.*),
            .sink_epoch = 0x434f_5349,
            .reservation_id = self.prepare_calls,
        };
        if (self.corrupt_ack) ack.proposal_sha256[0] ^= 1;
        if (self.cache) |cache| switch (self.mutation) {
            .none => {},
            .private_row => cache.keys[0][cache.len * cache.dim] += 1,
            .committed_prefix => cache.keys[0][0] += 1,
        };
    }

    fn commit(
        context: *anyopaque,
        receipt: *const publication.CommitReceiptV1,
    ) void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.receipts[self.commit_calls] = receipt.*;
        self.commit_calls += 1;
    }

    fn abort(
        context: *anyopaque,
        _: *const publication.ProposalV1,
        _: *const publication.PrepareAckV1,
    ) void {
        const self: *TestSink = @ptrCast(@alignCast(context));
        self.abort_calls += 1;
    }
};

fn testClaim(cache: *kv.KVCache, output_len: usize) resource_bank.Claim {
    return .{
        .kv_bytes = @intCast(cache.logicalLedger().allocation_payload_bytes),
        .output_journal_bytes = @intCast(output_len * @sizeOf(u32)),
        .queue_slots = 1,
    };
}

fn prefillTestCache(cache: *kv.KVCache) !void {
    _ = try cache.appendRow(0, &.{ 1, 2 }, &.{ 3, 4 });
    _ = try cache.appendRow(1, &.{ 5, 6 }, &.{ 7, 8 });
    cache.commit();
}

fn appendTestRow(cache: *kv.KVCache, seed: f32) !kv.RowTxnMark {
    const mark = try cache.beginRows(1);
    _ = try cache.appendRowTxn(
        mark,
        0,
        &.{ seed, seed + 1 },
        &.{ seed + 2, seed + 3 },
    );
    _ = try cache.appendRowTxn(
        mark,
        1,
        &.{ seed + 4, seed + 5 },
        &.{ seed + 6, seed + 7 },
    );
    return mark;
}

test "contiguous publication commits actual first-token and next-row state" {
    var cache = try kv.KVCache.init(testing.allocator, 2, 2, 4);
    defer cache.deinit();
    try prefillTestCache(&cache);
    var output: [2]u32 = undefined;
    var output_len: usize = 0;
    var rng: RngState = .{ 11, 12, 13, 14 };
    var sampling_calls: u64 = 0;
    const bindings: BindingsV1 = .{
        .cache = &cache,
        .rng_state = &rng,
        .sampling_calls = &sampling_calls,
        .output = &output,
        .output_len = &output_len,
    };
    var fixture: TestFixture = .{};
    try fixture.init(2, testClaim(&cache, output.len));
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x434f_5251,
        bindings,
    );
    const initial = try session.snapshotVerified();
    var verifier = try publication.TranscriptVerifierV1.init(
        fixture.admission.event.resource_receipt,
        0x434f_5251,
        abi,
        initial.state,
    );
    var sink: TestSink = .{};

    const first = try session.publish(
        try fixture.scheduler.prepareService(),
        .{
            .rng_after = rng,
            .sampling_calls_after = 0,
            .token_id = 101,
        },
        sink.interface(),
    );
    try verifier.apply(first);
    try testing.expectEqual(@as(usize, 1), cache.len);
    try testing.expectEqual(@as(u64, 0), sampling_calls);
    try testing.expectEqualSlices(u32, &.{101}, output[0..output_len]);
    try testing.expect(std.mem.eql(
        u8,
        &first.proposal.transition.before.kv_state_sha256,
        &first.proposal.transition.after.kv_state_sha256,
    ));

    const mark = try appendTestRow(&cache, 20);
    const rng_after: RngState = .{ 21, 22, 23, 24 };
    const second = try session.publish(
        try fixture.scheduler.prepareService(),
        .{
            .kv_mark = mark,
            .rng_after = rng_after,
            .sampling_calls_after = 1,
            .token_id = 102,
            .terminal = true,
        },
        sink.interface(),
    );
    try verifier.apply(second);
    try verifier.requireFinal(
        2,
        true,
        second.proposal.transition.after,
        second.transcript_sha256,
    );
    try testing.expectEqual(@as(usize, 2), cache.len);
    try testing.expectEqualDeep(rng_after, rng);
    try testing.expectEqual(@as(u64, 1), sampling_calls);
    try testing.expectEqualSlices(u32, &.{ 101, 102 }, output[0..output_len]);
    try testing.expectEqual(@as(usize, 2), sink.commit_calls);
    try testing.expectEqualDeep(
        verifier.snapshot(),
        try session.snapshotVerified(),
    );
    try fixture.finishRequest(&session);
}

test "contiguous publication rejection rolls back private row and retries" {
    var cache = try kv.KVCache.init(testing.allocator, 2, 2, 4);
    defer cache.deinit();
    try prefillTestCache(&cache);
    var output: [2]u32 = undefined;
    var output_len: usize = 0;
    var rng: RngState = .{ 1, 2, 3, 4 };
    var sampling_calls: u64 = 0;
    var fixture: TestFixture = .{};
    try fixture.init(2, testClaim(&cache, output.len));
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x434f_5252,
        .{
            .cache = &cache,
            .rng_state = &rng,
            .sampling_calls = &sampling_calls,
            .output = &output,
            .output_len = &output_len,
        },
    );
    var sink: TestSink = .{};
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        .{
            .rng_after = rng,
            .sampling_calls_after = 0,
            .token_id = 201,
        },
        sink.interface(),
    );
    const before = try session.snapshotVerified();
    const incomplete = try cache.beginRows(1);
    _ = try cache.appendRowTxn(
        incomplete,
        0,
        &.{ 9, 10 },
        &.{ 11, 12 },
    );
    try testing.expectError(
        error.TransactionIncomplete,
        session.publish(
            try fixture.scheduler.prepareService(),
            .{
                .kv_mark = incomplete,
                .rng_after = .{ 5, 6, 7, 8 },
                .sampling_calls_after = 1,
                .token_id = 202,
                .terminal = true,
            },
            sink.interface(),
        ),
    );
    try testing.expect(!cache.rowTxnActive());
    try testing.expectEqualDeep(before, try session.snapshotVerified());

    const row = try appendTestRow(&cache, 30);
    sink.reject = true;
    try testing.expectError(
        error.SinkRejected,
        session.publish(
            try fixture.scheduler.prepareService(),
            .{
                .kv_mark = row,
                .rng_after = .{ 5, 6, 7, 8 },
                .sampling_calls_after = 1,
                .token_id = 202,
                .terminal = true,
            },
            sink.interface(),
        ),
    );
    try testing.expect(!cache.rowTxnActive());
    try testing.expectEqual(@as(usize, 1), cache.len);
    try testing.expectEqualDeep(before, try session.snapshotVerified());
    try testing.expectEqual(@as(usize, 1), output_len);
    try testing.expectEqual(@as(u64, 0), sampling_calls);

    sink.reject = false;
    const retry_row = try appendTestRow(&cache, 40);
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        .{
            .kv_mark = retry_row,
            .rng_after = .{ 5, 6, 7, 8 },
            .sampling_calls_after = 1,
            .token_id = 202,
            .terminal = true,
        },
        sink.interface(),
    );
    try testing.expectEqual(@as(usize, 2), cache.len);
    try testing.expectEqualSlices(u32, &.{ 201, 202 }, output[0..output_len]);
    try fixture.finishRequest(&session);
}

test "contiguous publication rejects private mutation and stays retryable" {
    var cache = try kv.KVCache.init(testing.allocator, 2, 2, 4);
    defer cache.deinit();
    try prefillTestCache(&cache);
    var output: [2]u32 = undefined;
    var output_len: usize = 0;
    var rng: RngState = .{ 1, 2, 3, 4 };
    var sampling_calls: u64 = 0;
    var fixture: TestFixture = .{};
    try fixture.init(2, testClaim(&cache, output.len));
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x434f_5253,
        .{
            .cache = &cache,
            .rng_state = &rng,
            .sampling_calls = &sampling_calls,
            .output = &output,
            .output_len = &output_len,
        },
    );
    var sink: TestSink = .{};
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        .{
            .rng_after = rng,
            .sampling_calls_after = 0,
            .token_id = 301,
        },
        sink.interface(),
    );
    const before = try session.snapshotVerified();
    sink.cache = &cache;
    sink.mutation = .private_row;
    try testing.expectError(
        error.SinkRejected,
        session.publish(
            try fixture.scheduler.prepareService(),
            .{
                .kv_mark = try appendTestRow(&cache, 50),
                .rng_after = .{ 5, 6, 7, 8 },
                .sampling_calls_after = 1,
                .token_id = 302,
                .terminal = true,
            },
            sink.interface(),
        ),
    );
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    try testing.expect(!cache.rowTxnActive());
    try testing.expectEqualDeep(before, try session.snapshotVerified());

    sink.mutation = .none;
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        .{
            .kv_mark = try appendTestRow(&cache, 60),
            .rng_after = .{ 5, 6, 7, 8 },
            .sampling_calls_after = 1,
            .token_id = 302,
            .terminal = true,
        },
        sink.interface(),
    );
    try fixture.finishRequest(&session);
}

test "contiguous publication fails closed on committed-prefix mutation" {
    var cache = try kv.KVCache.init(testing.allocator, 2, 2, 3);
    defer cache.deinit();
    try prefillTestCache(&cache);
    var output: [1]u32 = undefined;
    var output_len: usize = 0;
    var rng: RngState = .{ 1, 2, 3, 4 };
    var sampling_calls: u64 = 0;
    var fixture: TestFixture = .{};
    try fixture.init(1, testClaim(&cache, output.len));
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x434f_5254,
        .{
            .cache = &cache,
            .rng_state = &rng,
            .sampling_calls = &sampling_calls,
            .output = &output,
            .output_len = &output_len,
        },
    );
    var sink: TestSink = .{ .cache = &cache, .mutation = .committed_prefix };
    try testing.expectError(
        Error.RecoveryRequired,
        session.publish(
            try fixture.scheduler.prepareService(),
            .{
                .rng_after = rng,
                .sampling_calls_after = 0,
                .token_id = 401,
                .terminal = true,
            },
            sink.interface(),
        ),
    );
    try testing.expectEqual(@as(usize, 1), sink.abort_calls);
    try testing.expectEqual(@as(usize, 0), output_len);
    try testing.expectError(Error.InvalidState, session.snapshotVerified());
}

test "contiguous publication checks claims aliases and address binding" {
    var cache = try kv.KVCache.init(testing.allocator, 2, 2, 3);
    defer cache.deinit();
    try prefillTestCache(&cache);
    var output: [1]u32 = undefined;
    var output_len: usize = 0;
    var rng: RngState = .{ 0, 2, 3, 4 };
    var sampling_calls: u64 = 0;

    var underclaimed: TestFixture = .{};
    try underclaimed.init(1, .{
        .kv_bytes = 1,
        .output_journal_bytes = @sizeOf(u32),
    });
    var rejected: Session = .{};
    try testing.expectError(
        Error.InsufficientResourceClaim,
        rejected.init(
            &underclaimed.scheduler,
            &underclaimed.bank,
            underclaimed.admission,
            0x434f_5255,
            .{
                .cache = &cache,
                .rng_state = &rng,
                .sampling_calls = &sampling_calls,
                .output = &output,
                .output_len = &output_len,
            },
        ),
    );
    _ = try underclaimed.scheduler.cancel(underclaimed.admission.handle);
    _ = try underclaimed.scheduler.close();

    var alias_fixture: TestFixture = .{};
    try alias_fixture.init(1, testClaim(&cache, output.len));
    var aliased: Session = .{};
    try testing.expectError(
        Error.InvalidConfiguration,
        aliased.init(
            &alias_fixture.scheduler,
            &alias_fixture.bank,
            alias_fixture.admission,
            0x434f_5256,
            .{
                .cache = &cache,
                .rng_state = &rng,
                .sampling_calls = &rng[0],
                .output = &output,
                .output_len = &output_len,
            },
        ),
    );
    _ = try alias_fixture.scheduler.cancel(alias_fixture.admission.handle);
    _ = try alias_fixture.scheduler.close();

    var fixture: TestFixture = .{};
    try fixture.init(1, testClaim(&cache, output.len));
    var session: Session = .{};
    try session.init(
        &fixture.scheduler,
        &fixture.bank,
        fixture.admission,
        0x434f_5257,
        .{
            .cache = &cache,
            .rng_state = &rng,
            .sampling_calls = &sampling_calls,
            .output = &output,
            .output_len = &output_len,
        },
    );
    var copied = session;
    var sink: TestSink = .{};
    try testing.expectError(
        Error.InvalidBinding,
        copied.publish(
            try fixture.scheduler.prepareService(),
            .{
                .rng_after = rng,
                .sampling_calls_after = 0,
                .token_id = 501,
                .terminal = true,
            },
            sink.interface(),
        ),
    );
    try testing.expectEqual(@as(usize, 0), output_len);
    _ = try session.publish(
        try fixture.scheduler.prepareService(),
        .{
            .rng_after = rng,
            .sampling_calls_after = 0,
            .token_id = 501,
            .terminal = true,
        },
        sink.interface(),
    );
    try fixture.finishRequest(&session);
}

test "contiguous publication footprint stays bounded" {
    try testing.expect(@sizeOf(Session) <= 4096);
    try testing.expect(@sizeOf(StageV1) <= 128);
}
