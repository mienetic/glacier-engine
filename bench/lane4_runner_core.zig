//! Allocation-free evidence primitives for the grounded Lane4 runner.
//!
//! This module deliberately contains no model loading, JSON, campaign policy,
//! or benchmark statistics. It owns only the two synchronous boundaries that
//! must be correct before a runner may retain measurements:
//!
//! * a bounded, hash-chained journal for the engine's versioned token
//!   publication observer; and
//! * a four-party post-ResourceBank-commit barrier for concurrent M1 calls.
//!
//! Both primitives are caller-owned and become address-stable before an
//! observer is created. They perform no allocation after initialization.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");

const generate_api = engine.generate;
const resource_bank = engine.resource_bank;
const token_txn = engine.token_txn;

pub const width: usize = 4;
pub const max_tokens_per_lane: usize = 64;
pub const max_token_events: usize = width * max_tokens_per_lane;

/// Runner-internal, lane-segmented evidence ABI. This is deliberately not the
/// cross-language event-stream ABI used by the campaign schema.
pub const token_lane_journal_abi: u64 = 0x474c_344c_0000_0001;
pub const b4_token_txn_journal_abi: u64 = 0x4742_3454_0000_0001;
pub const m1_post_commit_barrier_abi: u64 = 0x474d_3142_0000_0001;
pub const monotonic_clock_abi: u64 = 0x474d_4e43_0000_0001;

comptime {
    std.debug.assert(engine.decode_lane4.width == width);
}

pub const ClockError = error{
    Unavailable,
    InvalidTimestamp,
    Overflow,
};

/// Injectable monotonic nanosecond source. Production uses boot-relative OS
/// time; tests use an atomic deterministic source. The callback must be
/// thread-safe. Callers must not substitute wall time.
pub const MonotonicClock = struct {
    abi: u64 = monotonic_clock_abi,
    context: ?*anyopaque = null,
    read_ns: *const fn (context: ?*anyopaque) ClockError!u64,

    pub fn system() MonotonicClock {
        return .{ .read_ns = readSystemMonotonicNs };
    }

    pub fn now(self: MonotonicClock) ClockError!u64 {
        if (self.abi != monotonic_clock_abi) return ClockError.Unavailable;
        return self.read_ns(self.context);
    }

    /// True only for the production OS boot-relative clock implementation.
    /// Observation entrypoints use this identity check so an injected test
    /// clock cannot manufacture publishable-looking throughput receipts.
    pub fn isSystem(self: MonotonicClock) bool {
        const expected = system();
        return self.abi == expected.abi and self.context == null and
            self.read_ns == expected.read_ns;
    }
};

fn readSystemMonotonicNs(_: ?*anyopaque) ClockError!u64 {
    const tag = builtin.os.tag;
    if (comptime tag == .windows or tag == .wasi or tag == .uefi)
        return ClockError.Unavailable;

    const clock_id = if (comptime tag == .macos or tag == .ios or
        tag == .tvos or tag == .watchos or tag == .visionos)
        std.posix.CLOCK.UPTIME_RAW
    else if (comptime tag == .linux)
        std.posix.CLOCK.MONOTONIC_RAW
    else
        std.posix.CLOCK.MONOTONIC;
    const timestamp = std.posix.clock_gettime(clock_id) catch
        return ClockError.Unavailable;
    const seconds = std.math.cast(u64, timestamp.sec) orelse
        return ClockError.InvalidTimestamp;
    const nanoseconds = std.math.cast(u64, timestamp.nsec) orelse
        return ClockError.InvalidTimestamp;
    if (nanoseconds >= std.time.ns_per_s)
        return ClockError.InvalidTimestamp;
    return std.math.add(
        u64,
        std.math.mul(u64, seconds, std.time.ns_per_s) catch
            return ClockError.Overflow,
        nanoseconds,
    ) catch return ClockError.Overflow;
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

fn isZeroDigest(value: [32]u8) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}

fn initialTokenLaneSha256(
    root_binding: [32]u8,
    expected_tokens_per_lane: usize,
    logical_request_index: u32,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-runner-internal-token-lane-root-v1\x00");
    hashU64(&hash, token_lane_journal_abi);
    hashU64(&hash, generate_api.token_publication_observer_abi);
    hashU32(&hash, @intCast(width));
    hashU32(&hash, @intCast(expected_tokens_per_lane));
    hashU32(&hash, logical_request_index);
    hash.update(&root_binding);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub const TokenLaneEventV1 = struct {
    abi_version: u64 = token_lane_journal_abi,
    publication_abi: u64 = generate_api.token_publication_observer_abi,
    logical_request_index: u32,
    lane_sequence_index: u32,
    step_index: u64,
    token_id: u32,
    terminal: bool,
    monotonic_ns: u64,
    previous_sha256: [32]u8,
    event_sha256: [32]u8,
};

pub const TokenEventMatrix = [width][max_tokens_per_lane]TokenLaneEventV1;

fn tokenLaneEventSha256(event: TokenLaneEventV1) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-runner-internal-token-lane-event-v1\x00");
    hashU64(&hash, event.abi_version);
    hashU64(&hash, event.publication_abi);
    hashU32(&hash, event.logical_request_index);
    hashU32(&hash, event.lane_sequence_index);
    hashU64(&hash, event.step_index);
    hashU32(&hash, event.token_id);
    hashU8(&hash, @intFromBool(event.terminal));
    hashU64(&hash, event.monotonic_ns);
    hash.update(&event.previous_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub const TokenJournalFailure = enum(u8) {
    none,
    clock_unavailable,
    clock_regression,
    invalid_evidence,
    capacity_exceeded,
    callback_after_seal,
};

pub const TokenJournalError = error{
    InvalidConfiguration,
    ClockUnavailable,
    ClockRegression,
    InvalidEvidence,
    CapacityExceeded,
    Failed,
    Incomplete,
    AlreadySealed,
    NotSealed,
    ReceiptMismatch,
};

pub const TokenLaneTipV1 = struct {
    logical_request_index: u32,
    event_count: u32,
    initial_sha256: [32]u8,
    head_sha256: [32]u8,
    first_monotonic_ns: u64,
    last_monotonic_ns: u64,
};

pub const TokenJournalReceiptV1 = struct {
    abi_version: u64 = token_lane_journal_abi,
    publication_abi: u64 = generate_api.token_publication_observer_abi,
    lane_count: u32 = width,
    expected_tokens_per_lane: u32,
    event_count: u32,
    root_binding: [32]u8,
    lane_tips: [width]TokenLaneTipV1,
};

const RawTokenEvent = struct {
    step_index: u64,
    token_id: u32,
    terminal: bool,
    monotonic_ns: u64,
};

/// A lane owns its mutex, clock, raw hot-path records, and sealed hash chain.
/// Distinct publishing lanes never acquire the same mutex.
const TokenLaneRecorder = struct {
    mutex: std.Thread.Mutex = .{},
    clock: MonotonicClock,
    raw_events: [max_tokens_per_lane]RawTokenEvent = undefined,
    sealed_events: [max_tokens_per_lane]TokenLaneEventV1 = undefined,
    count: usize = 0,
    last_monotonic_ns: u64 = 0,
    has_timestamp: bool = false,
    failure: TokenJournalFailure = .none,

    fn init(clock: MonotonicClock) TokenLaneRecorder {
        return .{ .clock = clock };
    }

    fn failLocked(self: *TokenLaneRecorder, reason: TokenJournalFailure) void {
        if (self.failure == .none) self.failure = reason;
    }
};

/// Fixed-capacity, four-segment event recorder. The token callback performs
/// only lane-local validation, one clock read, and a raw fixed-slot append.
/// Hashing occurs after the timed run in `seal`. `init` may return by value,
/// but the journal address must remain stable after the first `observer` call.
pub const TokenEventJournal = struct {
    expected_tokens_per_lane: usize,
    root_binding: [32]u8,
    lanes: [width]TokenLaneRecorder,
    sealed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    seal_succeeded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    global_failure: std.atomic.Value(u8) =
        std.atomic.Value(u8).init(@intFromEnum(TokenJournalFailure.none)),

    pub fn init(
        clock: MonotonicClock,
        expected_tokens_per_lane: usize,
        root_binding: [32]u8,
    ) TokenJournalError!TokenEventJournal {
        return initWithLaneClocks(
            [_]MonotonicClock{clock} ** width,
            expected_tokens_per_lane,
            root_binding,
        );
    }

    /// This is primarily a verification hook: independent clock contexts make
    /// it explicit that no cross-lane timestamp ordering is required.
    pub fn initWithLaneClocks(
        clocks: [width]MonotonicClock,
        expected_tokens_per_lane: usize,
        root_binding: [32]u8,
    ) TokenJournalError!TokenEventJournal {
        if (expected_tokens_per_lane == 0 or
            expected_tokens_per_lane > max_tokens_per_lane or
            isZeroDigest(root_binding))
            return TokenJournalError.InvalidConfiguration;
        for (clocks) |clock| {
            if (clock.abi != monotonic_clock_abi)
                return TokenJournalError.InvalidConfiguration;
        }
        return .{
            .expected_tokens_per_lane = expected_tokens_per_lane,
            .root_binding = root_binding,
            .lanes = .{
                TokenLaneRecorder.init(clocks[0]),
                TokenLaneRecorder.init(clocks[1]),
                TokenLaneRecorder.init(clocks[2]),
                TokenLaneRecorder.init(clocks[3]),
            },
        };
    }

    /// One shared journal may back all four M1 observers. DecodeLane4 ignores
    /// this logical index and substitutes its actual publishing lane.
    pub fn observer(
        self: *TokenEventJournal,
        logical_request_index: u32,
    ) generate_api.TokenPublicationObserver {
        return .{
            .logical_request_index = logical_request_index,
            .context = self,
            .observe = observeTokenPublication,
        };
    }

    fn failGlobal(self: *TokenEventJournal, reason: TokenJournalFailure) void {
        if (self.global_failure.load(.acquire) ==
            @intFromEnum(TokenJournalFailure.none))
        {
            self.global_failure.store(@intFromEnum(reason), .release);
        }
    }

    fn append(
        self: *TokenEventJournal,
        evidence: *const generate_api.TokenPublicationEvidenceV1,
    ) TokenJournalError!void {
        if (evidence.logical_request_index >= width) {
            self.failGlobal(.invalid_evidence);
            return TokenJournalError.InvalidEvidence;
        }
        const lane_index: usize = evidence.logical_request_index;
        const lane = &self.lanes[lane_index];
        lane.mutex.lock();
        defer lane.mutex.unlock();

        if (self.sealed.load(.acquire)) {
            lane.failLocked(.callback_after_seal);
            return TokenJournalError.InvalidEvidence;
        }
        if (lane.failure != .none) return TokenJournalError.Failed;
        if (evidence.abi != generate_api.token_publication_observer_abi) {
            lane.failLocked(.invalid_evidence);
            return TokenJournalError.InvalidEvidence;
        }
        if (lane.count >= lane.raw_events.len) {
            lane.failLocked(.capacity_exceeded);
            return TokenJournalError.CapacityExceeded;
        }
        const expected_step = lane.count;
        if (evidence.step_index != expected_step or
            expected_step >= self.expected_tokens_per_lane or
            evidence.terminal !=
                (expected_step + 1 == self.expected_tokens_per_lane))
        {
            lane.failLocked(.invalid_evidence);
            return TokenJournalError.InvalidEvidence;
        }

        const now = lane.clock.now() catch {
            lane.failLocked(.clock_unavailable);
            return TokenJournalError.ClockUnavailable;
        };
        if (lane.has_timestamp and now < lane.last_monotonic_ns) {
            lane.failLocked(.clock_regression);
            return TokenJournalError.ClockRegression;
        }
        lane.raw_events[lane.count] = .{
            .step_index = evidence.step_index,
            .token_id = evidence.token_id,
            .terminal = evidence.terminal,
            .monotonic_ns = now,
        };
        lane.count += 1;
        lane.last_monotonic_ns = now;
        lane.has_timestamp = true;
    }

    /// Call only after all decode workers have joined. Concurrent callbacks
    /// are rejected and drained, but a callback started after this function
    /// returns cannot retroactively revoke a receipt already handed out.
    pub fn seal(self: *TokenEventJournal) TokenJournalError!TokenJournalReceiptV1 {
        if (self.sealed.swap(true, .acq_rel))
            return TokenJournalError.AlreadySealed;

        var lane_tips: [width]TokenLaneTipV1 = undefined;
        var failed = self.global_failure.load(.acquire) !=
            @intFromEnum(TokenJournalFailure.none);
        var incomplete = false;
        var event_count: usize = 0;

        // Setting `sealed` before taking these locks rejects queued callbacks.
        // Taking every lock drains callbacks that were already in flight. All
        // SHA-256 work is deliberately confined to this post-timing phase.
        for (&self.lanes, 0..) |*lane, lane_index| {
            lane.mutex.lock();

            if (lane.failure != .none) failed = true;
            if (lane.count != self.expected_tokens_per_lane or
                !lane.has_timestamp)
            {
                incomplete = true;
                lane.mutex.unlock();
                continue;
            }
            const initial = initialTokenLaneSha256(
                self.root_binding,
                self.expected_tokens_per_lane,
                @intCast(lane_index),
            );
            var head = initial;
            for (lane.raw_events[0..lane.count], 0..) |raw, sequence| {
                var event: TokenLaneEventV1 = .{
                    .logical_request_index = @intCast(lane_index),
                    .lane_sequence_index = @intCast(sequence),
                    .step_index = raw.step_index,
                    .token_id = raw.token_id,
                    .terminal = raw.terminal,
                    .monotonic_ns = raw.monotonic_ns,
                    .previous_sha256 = head,
                    .event_sha256 = undefined,
                };
                event.event_sha256 = tokenLaneEventSha256(event);
                lane.sealed_events[sequence] = event;
                head = event.event_sha256;
            }
            lane_tips[lane_index] = .{
                .logical_request_index = @intCast(lane_index),
                .event_count = @intCast(lane.count),
                .initial_sha256 = initial,
                .head_sha256 = head,
                .first_monotonic_ns = lane.raw_events[0].monotonic_ns,
                .last_monotonic_ns = lane.raw_events[lane.count - 1].monotonic_ns,
            };
            event_count += lane.count;
            lane.mutex.unlock();
        }
        if (failed) return TokenJournalError.Failed;
        if (incomplete) return TokenJournalError.Incomplete;

        const expected_total = std.math.mul(
            usize,
            width,
            self.expected_tokens_per_lane,
        ) catch return TokenJournalError.InvalidConfiguration;
        if (event_count != expected_total) return TokenJournalError.Incomplete;
        const receipt: TokenJournalReceiptV1 = .{
            .expected_tokens_per_lane = @intCast(self.expected_tokens_per_lane),
            .event_count = @intCast(event_count),
            .root_binding = self.root_binding,
            .lane_tips = lane_tips,
        };
        self.seal_succeeded.store(true, .release);
        return receipt;
    }

    pub fn copySealedEvents(
        self: *TokenEventJournal,
        destination: *TokenEventMatrix,
    ) TokenJournalError!void {
        if (!self.sealed.load(.acquire)) return TokenJournalError.NotSealed;
        if (!self.seal_succeeded.load(.acquire)) return TokenJournalError.Failed;
        if (self.global_failure.load(.acquire) !=
            @intFromEnum(TokenJournalFailure.none))
            return TokenJournalError.Failed;

        for (&self.lanes, 0..) |*lane, lane_index| {
            lane.mutex.lock();
            if (lane.failure != .none) {
                lane.mutex.unlock();
                return TokenJournalError.Failed;
            }
            @memcpy(
                destination[lane_index][0..lane.count],
                lane.sealed_events[0..lane.count],
            );
            lane.mutex.unlock();
        }
    }

    pub fn failureReason(self: *TokenEventJournal) TokenJournalFailure {
        const global: TokenJournalFailure = @enumFromInt(
            self.global_failure.load(.acquire),
        );
        if (global != .none) return global;
        for (&self.lanes) |*lane| {
            lane.mutex.lock();
            const failure = lane.failure;
            lane.mutex.unlock();
            if (failure != .none) return failure;
        }
        return .none;
    }
};

fn observeTokenPublication(
    raw_context: *anyopaque,
    evidence: *const generate_api.TokenPublicationEvidenceV1,
) generate_api.TokenPublicationObserverError!void {
    const journal: *TokenEventJournal = @ptrCast(@alignCast(raw_context));
    journal.append(evidence) catch |err| return switch (err) {
        TokenJournalError.ClockUnavailable,
        TokenJournalError.ClockRegression,
        => generate_api.TokenPublicationObserverError.Unavailable,
        else => generate_api.TokenPublicationObserverError.InvalidEvidence,
    };
}

pub fn verifyTokenJournal(
    events: *const TokenEventMatrix,
    receipt: TokenJournalReceiptV1,
) TokenJournalError!void {
    if (receipt.abi_version != token_lane_journal_abi or
        receipt.publication_abi != generate_api.token_publication_observer_abi or
        receipt.lane_count != width or
        receipt.expected_tokens_per_lane == 0 or
        receipt.expected_tokens_per_lane > max_tokens_per_lane or
        isZeroDigest(receipt.root_binding))
        return TokenJournalError.ReceiptMismatch;
    const expected_total = std.math.mul(
        usize,
        width,
        receipt.expected_tokens_per_lane,
    ) catch return TokenJournalError.ReceiptMismatch;
    if (receipt.event_count != expected_total)
        return TokenJournalError.Incomplete;

    var total: usize = 0;
    for (receipt.lane_tips, 0..) |tip, lane_index| {
        if (tip.logical_request_index != lane_index or
            tip.event_count != receipt.expected_tokens_per_lane)
            return TokenJournalError.ReceiptMismatch;
        const initial = initialTokenLaneSha256(
            receipt.root_binding,
            receipt.expected_tokens_per_lane,
            @intCast(lane_index),
        );
        if (!std.mem.eql(u8, &initial, &tip.initial_sha256))
            return TokenJournalError.ReceiptMismatch;

        var head = initial;
        var previous_ns: u64 = 0;
        for (events[lane_index][0..tip.event_count], 0..) |event, sequence| {
            if (event.abi_version != token_lane_journal_abi or
                event.publication_abi !=
                    generate_api.token_publication_observer_abi or
                event.logical_request_index != lane_index or
                event.lane_sequence_index != sequence or
                event.step_index != sequence or
                event.terminal !=
                    (sequence + 1 == receipt.expected_tokens_per_lane) or
                !std.mem.eql(u8, &event.previous_sha256, &head))
                return TokenJournalError.InvalidEvidence;
            if (sequence != 0 and event.monotonic_ns < previous_ns)
                return TokenJournalError.ClockRegression;
            const digest = tokenLaneEventSha256(event);
            if (!std.mem.eql(u8, &digest, &event.event_sha256))
                return TokenJournalError.InvalidEvidence;
            head = digest;
            previous_ns = event.monotonic_ns;
        }
        if (tip.first_monotonic_ns != events[lane_index][0].monotonic_ns or
            tip.last_monotonic_ns !=
                events[lane_index][tip.event_count - 1].monotonic_ns or
            !std.mem.eql(u8, &head, &tip.head_sha256))
            return TokenJournalError.ReceiptMismatch;
        total += tip.event_count;
    }
    if (total != receipt.event_count) return TokenJournalError.ReceiptMismatch;
}

/// TokenTxn's commit callback deliberately has no error channel and must not
/// perform fallible I/O. The B4 runner therefore records bounded transaction
/// receipts, but no invented per-commit timestamp. Public timing uses the
/// conservative root start-to-join interval and labels that limitation.
pub const B4TokenTxnWaveReceiptV1 = struct {
    abi_version: u64 = token_txn.commit_receipt_abi,
    proposal_abi: u64 = token_txn.abi,
    sink_abi: u64 = token_txn.sink_abi,
    request_epoch: u64,
    transaction_sequence: u64,
    resource_permit_generation: u64,
    live_mask: u8,
    live_lane_count: u8,
    kv_transition_mask: u8,
    terminal_mask: u8,
    lane_step_indices: [width]u64,
    token_ids: [width]u32,
    resource_receipt_sha256: [32]u8,
    proposal_sha256: [32]u8,
    prepare_ack: token_txn.PrepareAckV1,
    commit_sha256: [32]u8,
};

pub const B4TokenTxnWaveV1 = struct {
    abi_version: u64 = b4_token_txn_journal_abi,
    token_txn_abi: u64 = token_txn.abi,
    token_txn_sink_abi: u64 = token_txn.sink_abi,
    previous_sha256: [32]u8,
    receipt: B4TokenTxnWaveReceiptV1,
    wave_sha256: [32]u8,
};

pub const B4TokenTxnWaveMatrix = [max_tokens_per_lane]B4TokenTxnWaveV1;

pub const B4TokenTxnJournalReceiptV1 = struct {
    abi_version: u64 = b4_token_txn_journal_abi,
    token_txn_abi: u64 = token_txn.abi,
    token_txn_sink_abi: u64 = token_txn.sink_abi,
    token_txn_prepare_ack_abi: u64 = token_txn.prepare_ack_abi,
    token_txn_commit_receipt_abi: u64 = token_txn.commit_receipt_abi,
    resource_bank_abi: u64 = resource_bank.abi,
    request_epoch: u64,
    expected_transaction_count: u32 = max_tokens_per_lane,
    prepare_count: u32,
    commit_count: u32,
    abort_count: u32,
    lane_transition_count: u32,
    kv_transition_count: u32,
    first_sequence: u64,
    last_sequence: u64,
    root_binding: [32]u8,
    resource_receipt: resource_bank.Receipt,
    initial_sha256: [32]u8,
    head_sha256: [32]u8,
    /// False is normative for v1: SinkV1 commit cannot call the fallible
    /// runner clock, so the journal never presents a fabricated visibility
    /// timestamp as evidence.
    commit_timestamps_available: bool = false,
};

pub const B4TokenTxnJournalError = error{
    InvalidConfiguration,
    InvalidProposal,
    CapacityExceeded,
    CommitMismatch,
    Aborted,
    Incomplete,
    AlreadySealed,
    NotSealed,
    ReceiptMismatch,
};

fn initialB4TokenTxnSha256(
    root_binding: [32]u8,
    request_epoch: u64,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-runner-b4-token-txn-root-v1\x00");
    hashU64(&hash, b4_token_txn_journal_abi);
    hashU64(&hash, token_txn.abi);
    hashU64(&hash, token_txn.sink_abi);
    hashU64(&hash, token_txn.prepare_ack_abi);
    hashU64(&hash, token_txn.commit_receipt_abi);
    hashU64(&hash, resource_bank.abi);
    hashU32(&hash, @intCast(width));
    hashU32(&hash, @intCast(max_tokens_per_lane));
    hashU64(&hash, request_epoch);
    hash.update(&root_binding);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn b4TokenTxnWaveSha256(
    previous_sha256: [32]u8,
    receipt: B4TokenTxnWaveReceiptV1,
) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-runner-b4-token-txn-wave-v1\x00");
    hashU64(&hash, b4_token_txn_journal_abi);
    hashU64(&hash, token_txn.abi);
    hashU64(&hash, token_txn.sink_abi);
    hash.update(&previous_sha256);
    hash.update(&receipt.resource_receipt_sha256);
    hash.update(&receipt.proposal_sha256);
    hash.update(&receipt.commit_sha256);
    hashU64(&hash, receipt.request_epoch);
    hashU64(&hash, receipt.transaction_sequence);
    hashU64(&hash, receipt.resource_permit_generation);
    hashU8(&hash, receipt.live_mask);
    hashU8(&hash, receipt.live_lane_count);
    hashU8(&hash, receipt.kv_transition_mask);
    hashU8(&hash, receipt.terminal_mask);
    for (receipt.lane_step_indices, receipt.token_ids) |step, token_id| {
        hashU64(&hash, step);
        hashU32(&hash, token_id);
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn resourceReceiptSha256(receipt: resource_bank.Receipt) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-runner-resource-receipt-v1\x00");
    hashU64(&hash, resource_bank.abi);
    hashU64(&hash, receipt.bank_epoch);
    hashU32(&hash, receipt.slot_index);
    hashU64(&hash, receipt.generation);
    hashU64(&hash, receipt.owner_key);
    inline for (std.meta.fields(resource_bank.Claim)) |field|
        hashU64(&hash, @field(receipt.claim, field.name));
    hashU64(&hash, receipt.integrity);
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn compactB4TokenTxnReceipt(
    receipt: token_txn.CommitReceiptV1,
) B4TokenTxnWaveReceiptV1 {
    var kv_transition_mask: u8 = 0;
    var terminal_mask: u8 = 0;
    var lane_step_indices = [_]u64{0} ** width;
    var token_ids = [_]u32{0} ** width;
    for (receipt.proposal.lanes, 0..) |lane, lane_index| {
        const lane_bit = @as(u8, 1) << @intCast(lane_index);
        kv_transition_mask |= lane_bit * @intFromBool(lane.has_kv_transition);
        terminal_mask |= lane_bit * @intFromBool(lane.terminal);
        lane_step_indices[lane_index] = lane.step_index;
        token_ids[lane_index] = lane.token_id;
    }
    return .{
        .request_epoch = receipt.proposal.request_epoch,
        .transaction_sequence = receipt.proposal.transaction_sequence,
        .resource_permit_generation = receipt.proposal.resource_permit_generation,
        .live_mask = receipt.proposal.live_mask,
        .live_lane_count = receipt.proposal.live_lane_count,
        .kv_transition_mask = kv_transition_mask,
        .terminal_mask = terminal_mask,
        .lane_step_indices = lane_step_indices,
        .token_ids = token_ids,
        .resource_receipt_sha256 = resourceReceiptSha256(
            receipt.proposal.receipt,
        ),
        .proposal_sha256 = receipt.proposal_sha256,
        .prepare_ack = receipt.prepare_ack,
        .commit_sha256 = receipt.commit_sha256,
    };
}

fn validateB4TokenTxnWaveReceipt(
    receipt: B4TokenTxnWaveReceiptV1,
    request_epoch: u64,
    sequence: usize,
    expected_resource_receipt_sha256: [32]u8,
) B4TokenTxnJournalError!void {
    const expected_kv_mask: u8 = if (sequence == 0) 0 else 0b1111;
    const expected_terminal_mask: u8 = if (sequence + 1 ==
        max_tokens_per_lane) 0b1111 else 0;
    if (receipt.abi_version != token_txn.commit_receipt_abi or
        receipt.proposal_abi != token_txn.abi or
        receipt.sink_abi != token_txn.sink_abi or
        receipt.request_epoch != request_epoch or
        receipt.transaction_sequence != sequence or
        receipt.resource_permit_generation == 0 or
        receipt.live_mask != 0b1111 or receipt.live_lane_count != width or
        receipt.kv_transition_mask != expected_kv_mask or
        receipt.terminal_mask != expected_terminal_mask or
        receipt.prepare_ack.abi_version != token_txn.prepare_ack_abi or
        receipt.prepare_ack.sink_epoch !=
            (request_epoch ^ 0x4234_5349_4e4b_0001) or
        receipt.prepare_ack.reservation_id != sequence + 1 or
        !std.mem.eql(
            u8,
            &receipt.resource_receipt_sha256,
            &expected_resource_receipt_sha256,
        ) or !std.mem.eql(
        u8,
        &receipt.proposal_sha256,
        &receipt.prepare_ack.proposal_sha256,
    ) or !std.mem.eql(
        u8,
        &receipt.commit_sha256,
        &token_txn.commitSha256(
            receipt.proposal_sha256,
            receipt.prepare_ack,
        ),
    ))
        return error.ReceiptMismatch;
    for (receipt.lane_step_indices) |step|
        if (step != sequence) return error.ReceiptMismatch;
}

fn validateB4TokenTxnProposal(
    proposal: token_txn.ProposalV1,
    request_epoch: u64,
    sequence: usize,
    expected_receipt: ?resource_bank.Receipt,
) B4TokenTxnJournalError!void {
    if (proposal.abi_version != token_txn.abi or
        proposal.resource_bank_abi != resource_bank.abi or
        proposal.resource_publication_fence_abi !=
            resource_bank.publication_fence_abi or
        proposal.kv_row_txn_abi != engine.kv_cache.row_txn_abi or
        proposal.request_epoch != request_epoch or
        proposal.transaction_sequence != sequence or
        proposal.live_mask != 0b1111 or
        proposal.live_lane_count != width or
        proposal.resource_permit_generation == 0 or
        proposal.receipt.claim.queue_slots != width or
        (expected_receipt != null and
            !std.meta.eql(proposal.receipt, expected_receipt.?)))
        return error.InvalidProposal;

    for (proposal.lanes, 0..) |lane, lane_index| {
        const expected_terminal = sequence + 1 == max_tokens_per_lane;
        const expected_kv_after = std.math.add(
            u64,
            lane.prompt_len,
            @intCast(sequence),
        ) catch return error.InvalidProposal;
        const expected_kv_before = if (sequence == 0)
            expected_kv_after
        else
            expected_kv_after - 1;
        if (lane.lane_index != lane_index or
            lane.step_index != sequence or lane.prompt_len == 0 or
            lane.output_before != sequence or
            lane.output_after != sequence + 1 or
            lane.sampling_calls_before != sequence or
            lane.sampling_calls_after != sequence + 1 or
            lane.has_kv_transition != (sequence != 0) or
            lane.kv_before != expected_kv_before or
            lane.kv_after != expected_kv_after or
            lane.terminal != expected_terminal)
            return error.InvalidProposal;
    }
}

/// Fixed-capacity, address-stable strict-B4 sink. `prepare` only reserves one
/// private slot and returns a commitment acknowledgement; it exposes no token.
/// `commit` copies into that pre-reserved slot, hashes bounded in-memory bytes,
/// and advances the visible count last. It allocates nothing and performs no
/// clock or other fallible I/O.
pub const B4TokenTxnJournal = struct {
    request_epoch: u64,
    root_binding: [32]u8,
    sink_epoch: u64,
    events: B4TokenTxnWaveMatrix = undefined,
    pending: ?token_txn.ProposalV1 = null,
    pending_sha256: [32]u8 = [_]u8{0} ** 32,
    resource_receipt: ?resource_bank.Receipt = null,
    head_sha256: [32]u8,
    prepare_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    lane_transition_count: usize = 0,
    kv_transition_count: usize = 0,
    failed: bool = false,
    sealed: bool = false,

    pub fn init(
        request_epoch: u64,
        root_binding: [32]u8,
    ) B4TokenTxnJournalError!B4TokenTxnJournal {
        if (request_epoch == 0 or isZeroDigest(root_binding))
            return error.InvalidConfiguration;
        const sink_epoch = request_epoch ^ 0x4234_5349_4e4b_0001;
        if (sink_epoch == 0) return error.InvalidConfiguration;
        return .{
            .request_epoch = request_epoch,
            .root_binding = root_binding,
            .sink_epoch = sink_epoch,
            .head_sha256 = initialB4TokenTxnSha256(
                root_binding,
                request_epoch,
            ),
        };
    }

    pub fn sink(self: *B4TokenTxnJournal) token_txn.SinkV1 {
        return .{
            .context = self,
            .prepare = prepare,
            .commit = commit,
            .abort = abort,
        };
    }

    fn prepare(
        raw_context: *anyopaque,
        proposal: *const token_txn.ProposalV1,
        ack: *token_txn.PrepareAckV1,
    ) token_txn.SinkPrepareError!void {
        const self: *B4TokenTxnJournal = @ptrCast(@alignCast(raw_context));
        if (self.sealed or self.failed or self.pending != null)
            return error.InvalidEvidence;
        if (self.prepare_count >= max_tokens_per_lane)
            return error.CapacityExceeded;
        validateB4TokenTxnProposal(
            proposal.*,
            self.request_epoch,
            self.prepare_count,
            self.resource_receipt,
        ) catch return error.InvalidEvidence;
        if (self.resource_receipt == null)
            self.resource_receipt = proposal.receipt;

        const proposal_sha256 = token_txn.proposalSha256(proposal.*);
        self.pending = proposal.*;
        self.pending_sha256 = proposal_sha256;
        self.prepare_count += 1;
        ack.* = .{
            .proposal_sha256 = proposal_sha256,
            .sink_epoch = self.sink_epoch,
            .reservation_id = self.prepare_count,
        };
    }

    fn commit(
        raw_context: *anyopaque,
        receipt: *const token_txn.CommitReceiptV1,
    ) void {
        const self: *B4TokenTxnJournal = @ptrCast(@alignCast(raw_context));
        if (self.pending == null) {
            self.failed = true;
            return;
        }
        const receipt_proposal_sha256 = token_txn.proposalSha256(
            receipt.proposal,
        );
        if (self.sealed or self.failed or
            self.commit_count >= max_tokens_per_lane or
            !std.mem.eql(
                u8,
                &receipt_proposal_sha256,
                &self.pending_sha256,
            ) or
            !std.mem.eql(
                u8,
                &receipt.proposal_sha256,
                &self.pending_sha256,
            ) or
            receipt.prepare_ack.abi_version != token_txn.prepare_ack_abi or
            receipt.prepare_ack.sink_epoch != self.sink_epoch or
            receipt.prepare_ack.reservation_id != self.commit_count + 1 or
            !std.mem.eql(
                u8,
                &receipt.prepare_ack.proposal_sha256,
                &receipt.proposal_sha256,
            ) or
            !std.mem.eql(
                u8,
                &receipt.commit_sha256,
                &token_txn.commitSha256(
                    receipt.proposal_sha256,
                    receipt.prepare_ack,
                ),
            ))
        {
            self.failed = true;
            self.pending = null;
            self.pending_sha256 = [_]u8{0} ** 32;
            return;
        }

        const compact_receipt = compactB4TokenTxnReceipt(receipt.*);
        const wave_sha256 = b4TokenTxnWaveSha256(
            self.head_sha256,
            compact_receipt,
        );
        self.events[self.commit_count] = .{
            .previous_sha256 = self.head_sha256,
            .receipt = compact_receipt,
            .wave_sha256 = wave_sha256,
        };
        self.head_sha256 = wave_sha256;
        self.pending = null;
        self.pending_sha256 = [_]u8{0} ** 32;
        self.lane_transition_count += receipt.proposal.live_lane_count;
        for (receipt.proposal.lanes) |lane|
            self.kv_transition_count += @intFromBool(lane.has_kv_transition);
        self.commit_count += 1;
    }

    fn abort(
        raw_context: *anyopaque,
        proposal: *const token_txn.ProposalV1,
        ack: *const token_txn.PrepareAckV1,
    ) void {
        const self: *B4TokenTxnJournal = @ptrCast(@alignCast(raw_context));
        const proposal_matches = if (self.pending != null)
            std.mem.eql(
                u8,
                &self.pending_sha256,
                &token_txn.proposalSha256(proposal.*),
            )
        else
            false;
        if (!proposal_matches or
            ack.abi_version != token_txn.prepare_ack_abi or
            ack.sink_epoch != self.sink_epoch)
            self.failed = true;
        self.pending = null;
        self.pending_sha256 = [_]u8{0} ** 32;
        self.abort_count += 1;
    }

    pub fn seal(
        self: *B4TokenTxnJournal,
    ) B4TokenTxnJournalError!B4TokenTxnJournalReceiptV1 {
        if (self.sealed) return error.AlreadySealed;
        self.sealed = true;
        if (self.failed) return error.CommitMismatch;
        if (self.abort_count != 0) return error.Aborted;
        if (self.pending != null or
            self.prepare_count != max_tokens_per_lane or
            self.commit_count != max_tokens_per_lane or
            self.lane_transition_count != width * max_tokens_per_lane or
            self.kv_transition_count !=
                width * (max_tokens_per_lane - 1))
            return error.Incomplete;
        const bank_receipt = self.resource_receipt orelse
            return error.Incomplete;
        const result: B4TokenTxnJournalReceiptV1 = .{
            .request_epoch = self.request_epoch,
            .prepare_count = @intCast(self.prepare_count),
            .commit_count = @intCast(self.commit_count),
            .abort_count = @intCast(self.abort_count),
            .lane_transition_count = @intCast(self.lane_transition_count),
            .kv_transition_count = @intCast(self.kv_transition_count),
            .first_sequence = 0,
            .last_sequence = max_tokens_per_lane - 1,
            .root_binding = self.root_binding,
            .resource_receipt = bank_receipt,
            .initial_sha256 = initialB4TokenTxnSha256(
                self.root_binding,
                self.request_epoch,
            ),
            .head_sha256 = self.head_sha256,
        };
        try verifyB4TokenTxnJournal(&self.events, result);
        return result;
    }

    pub fn copySealedEvents(
        self: *const B4TokenTxnJournal,
        destination: *B4TokenTxnWaveMatrix,
    ) B4TokenTxnJournalError!void {
        if (!self.sealed) return error.NotSealed;
        if (self.failed or self.commit_count != max_tokens_per_lane)
            return error.Incomplete;
        destination.* = self.events;
    }
};

pub fn verifyB4TokenTxnJournal(
    events: *const B4TokenTxnWaveMatrix,
    receipt: B4TokenTxnJournalReceiptV1,
) B4TokenTxnJournalError!void {
    if (receipt.abi_version != b4_token_txn_journal_abi or
        receipt.token_txn_abi != token_txn.abi or
        receipt.token_txn_sink_abi != token_txn.sink_abi or
        receipt.token_txn_prepare_ack_abi != token_txn.prepare_ack_abi or
        receipt.token_txn_commit_receipt_abi !=
            token_txn.commit_receipt_abi or
        receipt.resource_bank_abi != resource_bank.abi or
        receipt.request_epoch == 0 or
        receipt.expected_transaction_count != max_tokens_per_lane or
        receipt.prepare_count != max_tokens_per_lane or
        receipt.commit_count != max_tokens_per_lane or
        receipt.abort_count != 0 or
        receipt.lane_transition_count != width * max_tokens_per_lane or
        receipt.kv_transition_count != width * (max_tokens_per_lane - 1) or
        receipt.first_sequence != 0 or
        receipt.last_sequence != max_tokens_per_lane - 1 or
        receipt.commit_timestamps_available or
        isZeroDigest(receipt.root_binding))
        return error.ReceiptMismatch;

    const initial = initialB4TokenTxnSha256(
        receipt.root_binding,
        receipt.request_epoch,
    );
    if (!std.mem.eql(u8, &initial, &receipt.initial_sha256))
        return error.ReceiptMismatch;
    const expected_resource_receipt_sha256 = resourceReceiptSha256(
        receipt.resource_receipt,
    );
    var head = initial;
    for (events, 0..) |event, sequence| {
        if (event.abi_version != b4_token_txn_journal_abi or
            event.token_txn_abi != token_txn.abi or
            event.token_txn_sink_abi != token_txn.sink_abi or
            !std.mem.eql(u8, &event.previous_sha256, &head))
            return error.ReceiptMismatch;
        try validateB4TokenTxnWaveReceipt(
            event.receipt,
            receipt.request_epoch,
            sequence,
            expected_resource_receipt_sha256,
        );
        const wave_sha256 = b4TokenTxnWaveSha256(
            head,
            event.receipt,
        );
        if (!std.mem.eql(u8, &wave_sha256, &event.wave_sha256))
            return error.ReceiptMismatch;
        head = wave_sha256;
    }
    if (!std.mem.eql(u8, &head, &receipt.head_sha256))
        return error.ReceiptMismatch;
}

pub const BarrierFailure = enum(u8) {
    none,
    external_abort,
    timeout,
    clock_unavailable,
    clock_regression,
    invalid_evidence,
    duplicate_arrival,
    committed_snapshot_rejected,
    callback_after_seal,
};

pub const BarrierError = error{
    InvalidConfiguration,
    InvalidLane,
    InvalidEvidence,
    DuplicateArrival,
    ClockUnavailable,
    ClockRegression,
    Timeout,
    Aborted,
    NotReleased,
    Incomplete,
    NoFourWayOverlap,
    AlreadyFinished,
    AlreadySealed,
    SnapshotRejected,
    ReceiptMismatch,
};

pub const LaneIntervalV1 = struct {
    logical_request_index: u32,
    ready_ns: u64,
    start_ns: u64,
    end_ns: u64,
};

const LaneBarrierState = struct {
    arrived: bool = false,
    started: bool = false,
    finished: bool = false,
    ready_ns: u64 = 0,
    start_ns: u64 = 0,
    end_ns: u64 = 0,
    receipt: ?resource_bank.Receipt = null,
};

pub const M1BarrierReceiptV1 = struct {
    abi_version: u64 = m1_post_commit_barrier_abi,
    resource_commit_observer_abi: u64 = generate_api.resource_commit_observer_abi,
    resource_bank_abi: u64 = resource_bank.abi,
    barrier_epoch: u64,
    arrival_count: u32,
    release_count: u32,
    release_ns: u64,
    intervals: [width]LaneIntervalV1,
    receipts: [width]resource_bank.Receipt,
    before_snapshot: resource_bank.Snapshot,
    committed_snapshot: resource_bank.Snapshot,
    released_snapshot: resource_bank.Snapshot,
};

fn addClaims(left: resource_bank.Claim, right: resource_bank.Claim) !resource_bank.Claim {
    var result: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        @field(result, field.name) = std.math.add(
            u64,
            @field(left, field.name),
            @field(right, field.name),
        ) catch return error.Overflow;
    }
    return result;
}

fn limitsEqualClaim(limits: resource_bank.Limits, claim: resource_bank.Claim) bool {
    const host_bytes = claim.hostBytes() catch return false;
    return limits.host_bytes == host_bytes and
        limits.capsule_bytes == claim.capsule_bytes and
        limits.kv_bytes == claim.kv_bytes and
        limits.activation_bytes == claim.activation_bytes and
        limits.partial_bytes == claim.partial_bytes and
        limits.logits_bytes == claim.logits_bytes and
        limits.output_journal_bytes == claim.output_journal_bytes and
        limits.staging_bytes == claim.staging_bytes and
        limits.device_bytes == claim.device_bytes and
        limits.io_bytes == claim.io_bytes and
        limits.queue_slots == claim.queue_slots;
}

pub fn exactLimitsForClaim(claim: resource_bank.Claim) !resource_bank.Limits {
    return .{
        .host_bytes = try claim.hostBytes(),
        .capsule_bytes = claim.capsule_bytes,
        .kv_bytes = claim.kv_bytes,
        .activation_bytes = claim.activation_bytes,
        .partial_bytes = claim.partial_bytes,
        .logits_bytes = claim.logits_bytes,
        .output_journal_bytes = claim.output_journal_bytes,
        .staging_bytes = claim.staging_bytes,
        .device_bytes = claim.device_bytes,
        .io_bytes = claim.io_bytes,
        .queue_slots = claim.queue_slots,
    };
}

fn snapshotIsFresh(snapshot: resource_bank.Snapshot) bool {
    return snapshot.abi_version == resource_bank.abi and
        snapshot.bank_epoch != 0 and snapshot.used.isZero() and
        snapshot.peak.isZero() and snapshot.peak_host_bytes == 0 and
        snapshot.active_reservations == 0 and
        snapshot.committed_receipts == 0 and
        snapshot.successful_reservations == 0 and
        snapshot.successful_commits == 0 and snapshot.cancellations == 0 and
        snapshot.releases == 0 and snapshot.rejected_capacity == 0 and
        snapshot.rejected_slots == 0;
}

fn aggregateReceipts(
    receipts: [width]resource_bank.Receipt,
) BarrierError!resource_bank.Claim {
    var aggregate: resource_bank.Claim = .{};
    var slots = [_]bool{false} ** width;
    var generations = [_]bool{false} ** width;
    for (receipts, 0..) |receipt, lane| {
        if (receipt.bank_epoch == 0 or receipt.owner_key == 0 or
            receipt.integrity == 0 or receipt.claim.queue_slots != 1 or
            (receipt.claim.hostBytes() catch 0) == 0 or
            receipt.slot_index >= width or receipt.generation == 0 or
            receipt.generation > width)
            return BarrierError.InvalidEvidence;
        if (slots[receipt.slot_index] or generations[receipt.generation - 1])
            return BarrierError.InvalidEvidence;
        slots[receipt.slot_index] = true;
        generations[receipt.generation - 1] = true;
        for (receipts[0..lane]) |prior| {
            if (prior.owner_key == receipt.owner_key or
                prior.integrity == receipt.integrity)
                return BarrierError.InvalidEvidence;
        }
        aggregate = addClaims(aggregate, receipt.claim) catch
            return BarrierError.InvalidEvidence;
    }
    return aggregate;
}

fn validateCommittedSnapshot(
    snapshot: resource_bank.Snapshot,
    receipts: [width]resource_bank.Receipt,
) BarrierError!void {
    const aggregate = try aggregateReceipts(receipts);
    const epoch = receipts[0].bank_epoch;
    for (receipts[1..]) |receipt| if (receipt.bank_epoch != epoch)
        return BarrierError.InvalidEvidence;
    if (snapshot.abi_version != resource_bank.abi or
        snapshot.bank_epoch != epoch or
        !limitsEqualClaim(snapshot.limits, aggregate) or
        !std.meta.eql(snapshot.used, aggregate) or
        !std.meta.eql(snapshot.peak, aggregate) or
        snapshot.peak_host_bytes != (aggregate.hostBytes() catch 0) or
        snapshot.active_reservations != 0 or
        snapshot.committed_receipts != width or
        snapshot.successful_reservations != width or
        snapshot.successful_commits != width or
        snapshot.cancellations != 0 or snapshot.releases != 0 or
        snapshot.rejected_capacity != 0 or snapshot.rejected_slots != 0)
        return BarrierError.SnapshotRejected;
}

fn validateReleasedSnapshot(
    snapshot: resource_bank.Snapshot,
    committed: resource_bank.Snapshot,
) BarrierError!void {
    if (snapshot.abi_version != resource_bank.abi or
        snapshot.bank_epoch != committed.bank_epoch or
        !std.meta.eql(snapshot.limits, committed.limits) or
        !snapshot.used.isZero() or
        !std.meta.eql(snapshot.peak, committed.peak) or
        snapshot.peak_host_bytes != committed.peak_host_bytes or
        snapshot.active_reservations != 0 or
        snapshot.committed_receipts != 0 or
        snapshot.successful_reservations != width or
        snapshot.successful_commits != width or
        snapshot.cancellations != 0 or snapshot.releases != width or
        snapshot.rejected_capacity != 0 or snapshot.rejected_slots != 0)
        return BarrierError.SnapshotRejected;
}

/// Four-request evidence barrier. `init` may return by value, but both this
/// value and the Bank must remain address-stable after participants are bound.
pub const M1PostCommitBarrier = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    bank: *resource_bank.Bank,
    clock: MonotonicClock,
    barrier_epoch: u64,
    wait_timeout_ns: u64,
    before_snapshot: resource_bank.Snapshot,
    committed_snapshot: ?resource_bank.Snapshot = null,
    lanes: [width]LaneBarrierState = [_]LaneBarrierState{.{}} ** width,
    arrival_count: usize = 0,
    started_count: usize = 0,
    finished_count: usize = 0,
    release_count: usize = 0,
    release_ns: u64 = 0,
    released: bool = false,
    sealed: bool = false,
    failure: BarrierFailure = .none,

    pub fn init(
        bank: *resource_bank.Bank,
        clock: MonotonicClock,
        barrier_epoch: u64,
        wait_timeout_ns: u64,
    ) BarrierError!M1PostCommitBarrier {
        if (clock.abi != monotonic_clock_abi or barrier_epoch == 0 or
            wait_timeout_ns == 0)
            return BarrierError.InvalidConfiguration;
        const before = bank.snapshot() catch
            return BarrierError.InvalidConfiguration;
        if (!snapshotIsFresh(before)) return BarrierError.InvalidConfiguration;
        return .{
            .bank = bank,
            .clock = clock,
            .barrier_epoch = barrier_epoch,
            .wait_timeout_ns = wait_timeout_ns,
            .before_snapshot = before,
        };
    }

    pub fn participant(
        self: *M1PostCommitBarrier,
        logical_request_index: usize,
    ) BarrierError!M1BarrierParticipant {
        if (logical_request_index >= width) return BarrierError.InvalidLane;
        return .{
            .barrier = self,
            .logical_request_index = @intCast(logical_request_index),
        };
    }

    fn failLocked(self: *M1PostCommitBarrier, failure: BarrierFailure) void {
        if (self.failure == .none) self.failure = failure;
        self.condition.broadcast();
    }

    pub fn abort(self: *M1PostCommitBarrier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.sealed) self.failLocked(.external_abort);
    }

    fn failFromClock(self: *M1PostCommitBarrier) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failLocked(.clock_unavailable);
    }

    fn arrive(
        self: *M1PostCommitBarrier,
        lane_index: u32,
        evidence: *const generate_api.ResourceCommitEvidenceV1,
    ) BarrierError!void {
        const ready_ns = self.clock.now() catch {
            self.failFromClock();
            return BarrierError.ClockUnavailable;
        };
        const deadline = std.math.add(
            u64,
            ready_ns,
            self.wait_timeout_ns,
        ) catch std.math.maxInt(u64);

        self.mutex.lock();
        if (self.sealed) {
            self.failLocked(.callback_after_seal);
            self.mutex.unlock();
            return BarrierError.InvalidEvidence;
        }
        if (self.failure != .none) {
            self.mutex.unlock();
            return BarrierError.Aborted;
        }
        if (lane_index >= width or
            evidence.abi != generate_api.resource_commit_observer_abi or
            evidence.resource_bank_abi != resource_bank.abi)
        {
            self.failLocked(.invalid_evidence);
            self.mutex.unlock();
            return BarrierError.InvalidEvidence;
        }
        const lane: usize = lane_index;
        if (self.lanes[lane].arrived) {
            self.failLocked(.duplicate_arrival);
            self.mutex.unlock();
            return BarrierError.DuplicateArrival;
        }
        const receipt = evidence.receipt;
        if (receipt.bank_epoch != self.before_snapshot.bank_epoch or
            receipt.owner_key == 0 or receipt.integrity == 0 or
            receipt.claim.queue_slots != 1 or
            (receipt.claim.hostBytes() catch 0) == 0)
        {
            self.failLocked(.invalid_evidence);
            self.mutex.unlock();
            return BarrierError.InvalidEvidence;
        }
        for (self.lanes) |state| if (state.receipt) |prior| {
            if (prior.slot_index == receipt.slot_index or
                prior.generation == receipt.generation or
                prior.owner_key == receipt.owner_key or
                prior.integrity == receipt.integrity)
            {
                self.failLocked(.invalid_evidence);
                self.mutex.unlock();
                return BarrierError.InvalidEvidence;
            }
        };
        self.lanes[lane].arrived = true;
        self.lanes[lane].ready_ns = ready_ns;
        self.lanes[lane].receipt = receipt;
        self.arrival_count += 1;

        if (self.arrival_count == width) {
            var receipts: [width]resource_bank.Receipt = undefined;
            for (self.lanes, 0..) |state, index|
                receipts[index] = state.receipt orelse unreachable;
            const snapshot = self.bank.snapshot() catch {
                self.failLocked(.committed_snapshot_rejected);
                self.mutex.unlock();
                return BarrierError.SnapshotRejected;
            };
            validateCommittedSnapshot(snapshot, receipts) catch {
                self.failLocked(.committed_snapshot_rejected);
                self.mutex.unlock();
                return BarrierError.SnapshotRejected;
            };
            const release_ns = self.clock.now() catch {
                self.failLocked(.clock_unavailable);
                self.mutex.unlock();
                return BarrierError.ClockUnavailable;
            };
            var latest_ready: u64 = 0;
            for (self.lanes) |state| latest_ready = @max(latest_ready, state.ready_ns);
            if (release_ns < latest_ready) {
                self.failLocked(.clock_regression);
                self.mutex.unlock();
                return BarrierError.ClockRegression;
            }
            self.committed_snapshot = snapshot;
            self.release_ns = release_ns;
            self.release_count = 1;
            self.released = true;
            self.condition.broadcast();
        } else {
            while (!self.released and self.failure == .none) {
                const now = self.clock.now() catch {
                    self.failLocked(.clock_unavailable);
                    break;
                };
                if (now >= deadline) {
                    self.failLocked(.timeout);
                    break;
                }
                self.condition.timedWait(
                    &self.mutex,
                    deadline - now,
                ) catch {
                    if (!self.released and self.failure == .none)
                        self.failLocked(.timeout);
                };
            }
        }
        if (self.failure != .none) {
            const failure = self.failure;
            self.mutex.unlock();
            return if (failure == .timeout)
                BarrierError.Timeout
            else
                BarrierError.Aborted;
        }
        const release_ns = self.release_ns;
        self.mutex.unlock();

        const start_ns = self.clock.now() catch {
            self.failFromClock();
            return BarrierError.ClockUnavailable;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure != .none) return BarrierError.Aborted;
        if (start_ns < release_ns) {
            self.failLocked(.clock_regression);
            return BarrierError.ClockRegression;
        }
        self.lanes[lane].started = true;
        self.lanes[lane].start_ns = start_ns;
        self.started_count += 1;
    }

    fn finish(self: *M1PostCommitBarrier, lane_index: u32) BarrierError!void {
        const end_ns = self.clock.now() catch {
            self.failFromClock();
            return BarrierError.ClockUnavailable;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failure != .none) return BarrierError.Aborted;
        if (lane_index >= width) return BarrierError.InvalidLane;
        const lane: usize = lane_index;
        if (!self.lanes[lane].started) return BarrierError.NotReleased;
        if (self.lanes[lane].finished) return BarrierError.AlreadyFinished;
        if (end_ns <= self.lanes[lane].start_ns) {
            self.failLocked(.clock_regression);
            return BarrierError.ClockRegression;
        }
        self.lanes[lane].finished = true;
        self.lanes[lane].end_ns = end_ns;
        self.finished_count += 1;
    }

    pub fn arrivalCount(self: *M1PostCommitBarrier) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.arrival_count;
    }

    pub fn startedCount(self: *M1PostCommitBarrier) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.started_count;
    }

    pub fn failureReason(self: *M1PostCommitBarrier) BarrierFailure {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure;
    }

    pub fn seal(self: *M1PostCommitBarrier) BarrierError!M1BarrierReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sealed) return BarrierError.AlreadySealed;
        self.sealed = true;
        if (self.failure != .none) return BarrierError.Aborted;
        if (!self.released or self.release_count != 1)
            return BarrierError.NotReleased;
        if (self.arrival_count != width or self.started_count != width or
            self.finished_count != width or self.committed_snapshot == null)
            return BarrierError.Incomplete;

        var intervals: [width]LaneIntervalV1 = undefined;
        var receipts: [width]resource_bank.Receipt = undefined;
        var latest_start: u64 = 0;
        var earliest_end: u64 = std.math.maxInt(u64);
        for (self.lanes, 0..) |state, lane| {
            if (!state.arrived or !state.started or !state.finished or
                state.ready_ns > self.release_ns or
                state.start_ns < self.release_ns or state.end_ns <= state.start_ns)
                return BarrierError.Incomplete;
            intervals[lane] = .{
                .logical_request_index = @intCast(lane),
                .ready_ns = state.ready_ns,
                .start_ns = state.start_ns,
                .end_ns = state.end_ns,
            };
            receipts[lane] = state.receipt orelse return BarrierError.Incomplete;
            latest_start = @max(latest_start, state.start_ns);
            earliest_end = @min(earliest_end, state.end_ns);
        }
        if (latest_start >= earliest_end) return BarrierError.NoFourWayOverlap;

        const released_snapshot = self.bank.snapshot() catch
            return BarrierError.SnapshotRejected;
        try validateReleasedSnapshot(
            released_snapshot,
            self.committed_snapshot.?,
        );
        const receipt: M1BarrierReceiptV1 = .{
            .barrier_epoch = self.barrier_epoch,
            .arrival_count = width,
            .release_count = 1,
            .release_ns = self.release_ns,
            .intervals = intervals,
            .receipts = receipts,
            .before_snapshot = self.before_snapshot,
            .committed_snapshot = self.committed_snapshot.?,
            .released_snapshot = released_snapshot,
        };
        try verifyM1BarrierReceipt(receipt);
        return receipt;
    }
};

pub const M1BarrierParticipant = struct {
    barrier: *M1PostCommitBarrier,
    logical_request_index: u32,

    pub fn observer(self: *M1BarrierParticipant) generate_api.ResourceCommitObserver {
        return .{
            .context = self,
            .observe = observeResourceCommit,
        };
    }

    pub fn markFinished(self: *M1BarrierParticipant) BarrierError!void {
        return self.barrier.finish(self.logical_request_index);
    }
};

fn observeResourceCommit(
    raw_context: *anyopaque,
    evidence: *const generate_api.ResourceCommitEvidenceV1,
) generate_api.ResourceCommitObserverError!void {
    const participant: *M1BarrierParticipant = @ptrCast(@alignCast(raw_context));
    participant.barrier.arrive(
        participant.logical_request_index,
        evidence,
    ) catch |err| return switch (err) {
        BarrierError.InvalidLane,
        BarrierError.InvalidEvidence,
        BarrierError.DuplicateArrival,
        BarrierError.SnapshotRejected,
        => generate_api.ResourceCommitObserverError.InvalidEvidence,
        else => generate_api.ResourceCommitObserverError.Unavailable,
    };
}

pub fn verifyM1BarrierReceipt(receipt: M1BarrierReceiptV1) BarrierError!void {
    if (receipt.abi_version != m1_post_commit_barrier_abi or
        receipt.resource_commit_observer_abi !=
            generate_api.resource_commit_observer_abi or
        receipt.resource_bank_abi != resource_bank.abi or
        receipt.barrier_epoch == 0 or receipt.arrival_count != width or
        receipt.release_count != 1)
        return BarrierError.ReceiptMismatch;
    try validateCommittedSnapshot(
        receipt.committed_snapshot,
        receipt.receipts,
    );
    try validateReleasedSnapshot(
        receipt.released_snapshot,
        receipt.committed_snapshot,
    );
    if (!snapshotIsFresh(receipt.before_snapshot) or
        receipt.before_snapshot.bank_epoch != receipt.committed_snapshot.bank_epoch or
        !std.meta.eql(
            receipt.before_snapshot.limits,
            receipt.committed_snapshot.limits,
        ))
        return BarrierError.ReceiptMismatch;

    var latest_start: u64 = 0;
    var earliest_end: u64 = std.math.maxInt(u64);
    for (receipt.intervals, 0..) |interval, lane| {
        if (interval.logical_request_index != lane or
            interval.ready_ns > receipt.release_ns or
            interval.start_ns < receipt.release_ns or
            interval.end_ns <= interval.start_ns)
            return BarrierError.ReceiptMismatch;
        latest_start = @max(latest_start, interval.start_ns);
        earliest_end = @min(earliest_end, interval.end_ns);
    }
    if (latest_start >= earliest_end) return BarrierError.NoFourWayOverlap;
}

const TestClock = struct {
    next: std.atomic.Value(u64),
    step: u64,

    fn init(first: u64, step: u64) TestClock {
        return .{
            .next = std.atomic.Value(u64).init(first),
            .step = step,
        };
    }

    fn clock(self: *TestClock) MonotonicClock {
        return .{
            .context = self,
            .read_ns = read,
        };
    }

    fn read(raw_context: ?*anyopaque) ClockError!u64 {
        const self: *TestClock = @ptrCast(@alignCast(raw_context orelse
            return ClockError.Unavailable));
        return self.next.fetchAdd(self.step, .monotonic);
    }
};

fn testB4TxnProposal(
    sequence: usize,
    receipt: resource_bank.Receipt,
    request_epoch: u64,
) token_txn.ProposalV1 {
    var proposal: token_txn.ProposalV1 = .{
        .request_epoch = request_epoch,
        .transaction_sequence = @intCast(sequence),
        .resource_permit_generation = @intCast(sequence + 1),
        .live_mask = 0b1111,
        .live_lane_count = width,
        .receipt = receipt,
    };
    for (&proposal.lanes, 0..) |*lane, lane_index| {
        const kv_after: u64 = 7 + @as(u64, @intCast(sequence));
        lane.* = .{
            .lane_index = @intCast(lane_index),
            .step_index = @intCast(sequence),
            .prompt_len = 7,
            .kv_before = if (sequence == 0) kv_after else kv_after - 1,
            .kv_after = kv_after,
            .kv_generation = if (sequence == 0) 0 else @intCast(sequence),
            .has_kv_transition = sequence != 0,
            .output_before = @intCast(sequence),
            .output_after = @intCast(sequence + 1),
            .rng_before = [_]u64{@intCast(lane_index + 1)} ** 4,
            .rng_after = [_]u64{@intCast(lane_index + 1)} ** 4,
            .sampling_calls_before = @intCast(sequence),
            .sampling_calls_after = @intCast(sequence + 1),
            .token_id = @intCast(1000 + lane_index * 100 + sequence),
            .terminal = sequence + 1 == max_tokens_per_lane,
        };
    }
    return proposal;
}

test "B4 TokenTxn sink seals exact 64-wave all-live ledger" {
    const request_epoch: u64 = 0x4234_5458_4e54_0001;
    var root_binding = [_]u8{0xa5} ** 32;
    root_binding[0] = 1;
    const bank_receipt: resource_bank.Receipt = .{
        .bank_epoch = 0x4234_4241_4e4b_0001,
        .slot_index = 0,
        .generation = 1,
        .owner_key = 0x1234,
        .claim = .{ .activation_bytes = 4096, .queue_slots = width },
        .integrity = 0x5678,
    };
    var journal = try B4TokenTxnJournal.init(request_epoch, root_binding);
    const sink = journal.sink();
    for (0..max_tokens_per_lane) |sequence| {
        const proposal = testB4TxnProposal(
            sequence,
            bank_receipt,
            request_epoch,
        );
        var ack: token_txn.PrepareAckV1 = .{};
        try sink.prepare(sink.context, &proposal, &ack);
        // Prepare reserves private fixed capacity but does not advance the
        // committed event count or expose a transaction wave.
        try std.testing.expectEqual(sequence + 1, journal.prepare_count);
        try std.testing.expectEqual(sequence, journal.commit_count);
        const proposal_sha256 = token_txn.proposalSha256(proposal);
        const commit_receipt: token_txn.CommitReceiptV1 = .{
            .proposal = proposal,
            .proposal_sha256 = proposal_sha256,
            .prepare_ack = ack,
            .commit_sha256 = token_txn.commitSha256(proposal_sha256, ack),
        };
        sink.commit(sink.context, &commit_receipt);
    }

    const receipt = try journal.seal();
    var events: B4TokenTxnWaveMatrix = undefined;
    try journal.copySealedEvents(&events);
    try verifyB4TokenTxnJournal(&events, receipt);
    try std.testing.expectEqual(@as(u32, 64), receipt.prepare_count);
    try std.testing.expectEqual(@as(u32, 64), receipt.commit_count);
    try std.testing.expectEqual(@as(u32, 0), receipt.abort_count);
    try std.testing.expectEqual(@as(u32, 256), receipt.lane_transition_count);
    try std.testing.expectEqual(@as(u32, 252), receipt.kv_transition_count);
    try std.testing.expectEqual(@as(u64, 0), receipt.first_sequence);
    try std.testing.expectEqual(@as(u64, 63), receipt.last_sequence);
    try std.testing.expect(!receipt.commit_timestamps_available);
    for (events, 0..) |event, sequence| {
        try std.testing.expectEqual(
            @as(u64, @intCast(sequence)),
            event.receipt.transaction_sequence,
        );
        try std.testing.expectEqual(
            @as(u8, 0b1111),
            event.receipt.live_mask,
        );
        try std.testing.expectEqual(
            @as(u8, if (sequence == 0) 0 else 0b1111),
            event.receipt.kv_transition_mask,
        );
        try std.testing.expectEqual(
            @as(
                u8,
                if (sequence == max_tokens_per_lane - 1) 0b1111 else 0,
            ),
            event.receipt.terminal_mask,
        );
    }

    var receipt_mutation = receipt;
    receipt_mutation.token_txn_abi +%= 1;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&events, receipt_mutation),
    );
    receipt_mutation = receipt;
    receipt_mutation.token_txn_sink_abi +%= 1;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&events, receipt_mutation),
    );
    receipt_mutation = receipt;
    receipt_mutation.commit_count -= 1;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&events, receipt_mutation),
    );
    receipt_mutation = receipt;
    receipt_mutation.resource_receipt.owner_key +%= 1;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&events, receipt_mutation),
    );

    var event_mutation = events;
    event_mutation[7].receipt.transaction_sequence +%= 1;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&event_mutation, receipt),
    );
    event_mutation = events;
    event_mutation[7].receipt.live_mask = 0b0111;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&event_mutation, receipt),
    );
    event_mutation = events;
    event_mutation[7].receipt.kv_transition_mask = 0b1011;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&event_mutation, receipt),
    );
    event_mutation = events;
    event_mutation[7].receipt.terminal_mask = 0b0100;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&event_mutation, receipt),
    );
    event_mutation = events;
    event_mutation[7].receipt.proposal_sha256[0] ^= 1;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&event_mutation, receipt),
    );
    event_mutation = events;
    event_mutation[7].wave_sha256[0] ^= 1;
    try std.testing.expectError(
        error.ReceiptMismatch,
        verifyB4TokenTxnJournal(&event_mutation, receipt),
    );
}

test "token journal records four independent concurrent lane chains" {
    var test_clocks = [width]TestClock{
        TestClock.init(4_000, 1),
        TestClock.init(1_000, 1),
        TestClock.init(3_000, 1),
        TestClock.init(2_000, 1),
    };
    var clocks: [width]MonotonicClock = undefined;
    for (&clocks, 0..) |*clock, lane| clock.* = test_clocks[lane].clock();
    var root_binding = [_]u8{0x5a} ** 32;
    root_binding[0] = 1;
    const tokens_per_lane: usize = 8;
    var journal = try TokenEventJournal.initWithLaneClocks(
        clocks,
        tokens_per_lane,
        root_binding,
    );
    const Worker = struct {
        observer_value: generate_api.TokenPublicationObserver,
        lane: usize,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            for (0..tokens_per_lane) |step| {
                generate_api.runTokenPublicationObserver(
                    self.observer_value,
                    step,
                    @intCast(self.lane * 100 + step),
                    step + 1 == tokens_per_lane,
                ) catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var workers: [width]Worker = undefined;
    var threads: [width]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&workers, 0..) |*worker, lane| {
        worker.* = .{
            .observer_value = journal.observer(@intCast(lane)),
            .lane = lane,
        };
        threads[lane] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    for (workers) |worker| try std.testing.expect(worker.failure == null);

    const receipt = try journal.seal();
    var events: TokenEventMatrix = undefined;
    try journal.copySealedEvents(&events);
    try std.testing.expectEqual(
        @as(u32, width * tokens_per_lane),
        receipt.event_count,
    );
    try verifyTokenJournal(&events, receipt);
    for (receipt.lane_tips, 0..) |tip, lane| {
        try std.testing.expectEqual(@as(u32, @intCast(lane)), tip.logical_request_index);
        try std.testing.expectEqual(@as(u32, tokens_per_lane), tip.event_count);
        try std.testing.expect(!std.mem.eql(
            u8,
            &tip.initial_sha256,
            &tip.head_sha256,
        ));
        for (events[lane][0..tokens_per_lane], 0..) |event, sequence| {
            try std.testing.expectEqual(
                @as(u32, @intCast(sequence)),
                event.lane_sequence_index,
            );
            try std.testing.expectEqual(
                @as(u64, @intCast(sequence)),
                event.step_index,
            );
        }
    }
    // Lane clocks may use unrelated epochs. Verification is lane-local and
    // therefore accepts this intentional cross-lane timestamp inversion.
    try std.testing.expect(
        events[0][0].monotonic_ns >
            events[1][tokens_per_lane - 1].monotonic_ns,
    );

    events[2][4].token_id +%= 1;
    try std.testing.expectError(
        TokenJournalError.InvalidEvidence,
        verifyTokenJournal(&events, receipt),
    );
}

test "production clock identity rejects injected timestamp sources" {
    try std.testing.expect(MonotonicClock.system().isSystem());
    var test_clock = TestClock.init(1, 1);
    try std.testing.expect(!test_clock.clock().isSystem());
}

test "token journal rejects a gap and never seals partial evidence" {
    var test_clock = TestClock.init(10, 1);
    var journal = try TokenEventJournal.init(
        test_clock.clock(),
        2,
        [_]u8{0x7b} ** 32,
    );
    const observer = journal.observer(0);
    try std.testing.expectError(
        generate_api.GenerateError.TokenPublicationObserverRejected,
        generate_api.runTokenPublicationObserver(observer, 1, 7, false),
    );
    try std.testing.expectEqual(
        TokenJournalFailure.invalid_evidence,
        journal.failureReason(),
    );
    try std.testing.expectError(TokenJournalError.Failed, journal.seal());
    var events: TokenEventMatrix = undefined;
    try std.testing.expectError(
        TokenJournalError.Failed,
        journal.copySealedEvents(&events),
    );
}

fn aggregateTestClaims(claims: [width]resource_bank.Claim) !resource_bank.Claim {
    var aggregate: resource_bank.Claim = .{};
    for (claims) |claim| aggregate = try addClaims(aggregate, claim);
    return aggregate;
}

fn waitForBarrierCount(
    barrier: *M1PostCommitBarrier,
    comptime started: bool,
    expected: usize,
) !void {
    var attempts: usize = 0;
    while (attempts < 100_000) : (attempts += 1) {
        const count = if (started)
            barrier.startedCount()
        else
            barrier.arrivalCount();
        if (count == expected) return;
        std.Thread.yield() catch {};
    }
    return error.TestExpectedEqual;
}

test "M1 post-commit barrier proves exact fresh-bank overlap and release" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const claims = [width]resource_bank.Claim{
        .{ .activation_bytes = 100, .output_journal_bytes = 8, .queue_slots = 1 },
        .{ .activation_bytes = 110, .output_journal_bytes = 8, .queue_slots = 1 },
        .{ .activation_bytes = 120, .output_journal_bytes = 8, .queue_slots = 1 },
        .{ .activation_bytes = 130, .output_journal_bytes = 8, .queue_slots = 1 },
    };
    const aggregate = try aggregateTestClaims(claims);
    var slots = [_]resource_bank.Slot{.{}} ** width;
    var bank = try resource_bank.Bank.init(
        &slots,
        try exactLimitsForClaim(aggregate),
        0x4d31_4241_4e4b_0001,
    );
    var test_clock = TestClock.init(10_000, 10);
    var barrier = try M1PostCommitBarrier.init(
        &bank,
        test_clock.clock(),
        0x4d31_4241_5252_0001,
        2 * std.time.ns_per_s,
    );
    var participants: [width]M1BarrierParticipant = undefined;
    for (&participants, 0..) |*participant, lane|
        participant.* = try barrier.participant(lane);

    var allow_finish = std.atomic.Value(bool).init(false);
    const Worker = struct {
        bank: *resource_bank.Bank,
        participant: *M1BarrierParticipant,
        claim: resource_bank.Claim,
        owner_key: u64,
        allow_finish: *std.atomic.Value(bool),
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            const reservation = self.bank.reserve(
                self.owner_key,
                self.claim,
            ) catch |err| {
                self.failure = err;
                self.participant.barrier.abort();
                return;
            };
            const receipt = self.bank.commit(reservation) catch |err| {
                self.failure = err;
                self.bank.cancel(reservation) catch {};
                self.participant.barrier.abort();
                return;
            };
            defer self.bank.release(receipt) catch |err| {
                self.failure = err;
            };
            generate_api.runResourceCommitObserver(
                self.participant.observer(),
                receipt,
            ) catch |err| {
                self.failure = err;
                return;
            };
            while (!self.allow_finish.load(.acquire))
                std.atomic.spinLoopHint();
            self.participant.markFinished() catch |err| {
                self.failure = err;
            };
        }
    };
    var workers: [width]Worker = undefined;
    var threads: [width]std.Thread = undefined;
    var started_threads: usize = 0;
    defer for (threads[0..started_threads]) |thread| thread.join();
    for (&workers, 0..) |*worker, lane| {
        worker.* = .{
            .bank = &bank,
            .participant = &participants[lane],
            .claim = claims[lane],
            .owner_key = @intCast(0x100 + lane),
            .allow_finish = &allow_finish,
        };
        threads[lane] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started_threads += 1;
    }
    try waitForBarrierCount(&barrier, true, width);
    allow_finish.store(true, .release);
    for (threads[0..started_threads]) |thread| thread.join();
    started_threads = 0;
    for (workers) |worker| try std.testing.expect(worker.failure == null);

    const receipt = try barrier.seal();
    try verifyM1BarrierReceipt(receipt);
    try std.testing.expectEqual(@as(u32, width), receipt.arrival_count);
    try std.testing.expectEqual(@as(u32, 1), receipt.release_count);
    try std.testing.expectEqual(@as(usize, 0), receipt.released_snapshot.committed_receipts);
    try std.testing.expect(receipt.released_snapshot.used.isZero());
}

test "M1 post-commit barrier external abort drains waiting observers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const claims = [width]resource_bank.Claim{
        .{ .activation_bytes = 32, .queue_slots = 1 },
        .{ .activation_bytes = 33, .queue_slots = 1 },
        .{ .activation_bytes = 34, .queue_slots = 1 },
        .{ .activation_bytes = 35, .queue_slots = 1 },
    };
    var slots = [_]resource_bank.Slot{.{}} ** width;
    var bank = try resource_bank.Bank.init(
        &slots,
        try exactLimitsForClaim(try aggregateTestClaims(claims)),
        0x4d31_4142_4f52_5401,
    );
    var test_clock = TestClock.init(20_000, 10);
    var barrier = try M1PostCommitBarrier.init(
        &bank,
        test_clock.clock(),
        0x4d31_4142_4f52_5402,
        2 * std.time.ns_per_s,
    );
    var participants: [width]M1BarrierParticipant = undefined;
    for (&participants, 0..) |*participant, lane|
        participant.* = try barrier.participant(lane);

    const Worker = struct {
        bank: *resource_bank.Bank,
        participant: *M1BarrierParticipant,
        claim: resource_bank.Claim,
        owner_key: u64,
        rejected: bool = false,

        fn run(self: *@This()) void {
            const reservation = self.bank.reserve(
                self.owner_key,
                self.claim,
            ) catch return;
            const receipt = self.bank.commit(reservation) catch {
                self.bank.cancel(reservation) catch {};
                return;
            };
            defer self.bank.release(receipt) catch {};
            generate_api.runResourceCommitObserver(
                self.participant.observer(),
                receipt,
            ) catch {
                self.rejected = true;
                return;
            };
        }
    };
    var workers: [width - 1]Worker = undefined;
    var threads: [width - 1]std.Thread = undefined;
    var started_threads: usize = 0;
    defer for (threads[0..started_threads]) |thread| thread.join();
    for (&workers, 0..) |*worker, lane| {
        worker.* = .{
            .bank = &bank,
            .participant = &participants[lane],
            .claim = claims[lane],
            .owner_key = @intCast(0x200 + lane),
        };
        threads[lane] = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started_threads += 1;
    }
    try waitForBarrierCount(&barrier, false, width - 1);
    barrier.abort();
    for (threads[0..started_threads]) |thread| thread.join();
    started_threads = 0;
    for (workers) |worker| try std.testing.expect(worker.rejected);
    try std.testing.expectEqual(BarrierFailure.external_abort, barrier.failureReason());
    try std.testing.expectError(BarrierError.Aborted, barrier.seal());
    try std.testing.expect((try bank.snapshot()).used.isZero());
}
