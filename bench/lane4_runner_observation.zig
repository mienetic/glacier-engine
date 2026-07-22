//! Actual-model observation primitives for the grounded Lane4 runner.
//!
//! This module owns one timed execution over an already-loaded immutable
//! model. It deliberately performs no model loading, JSON encoding, campaign
//! scheduling, statistics, or CLI work. M1x4 uses four root threads while B4
//! uses one root thread whose DecodeLane4 call owns its retained worker pool;
//! the calling coordinator only spawns and joins roots during the run.
//! This slice is intentionally thread-cold: every observation constructs new
//! roots (and B4's retained per-run pool). It makes no long-lived worker or
//! campaign-level performance-promotion claim.

const std = @import("std");
const engine = @import("engine");
const runner_core = @import("lane4_runner_core");

const generate_api = engine.generate;
const decode_lane4 = engine.decode_lane4;
const forward = engine.forward;
const resource_bank = engine.resource_bank;

pub const width: usize = runner_core.width;
pub const tokens_per_lane: usize = 64;
pub const observation_abi: u64 = 0x474c_344f_0000_0002;
pub const b4_post_commit_abi: u64 = 0x4742_3443_0000_0001;

comptime {
    std.debug.assert(width == decode_lane4.width);
    std.debug.assert(tokens_per_lane == runner_core.max_tokens_per_lane);
}

pub const RequestBinding = struct {
    /// All four prompts must have equal, non-zero length; token contents may
    /// differ. The prompt contents together with `seed` must identify four
    /// distinct bindings.
    prompt: []const u32,
    seed: u64,
};

pub const M1RunOptions = struct {
    observation_binding: [32]u8,
    bank_epoch: u64,
    barrier_epoch: u64,
    barrier_timeout_ns: u64 = 30 * std.time.ns_per_s,
    /// Public observations require the production OS boot-relative clock.
    /// Injection remains available only to lower-level primitive unit tests.
    clock: runner_core.MonotonicClock = runner_core.MonotonicClock.system(),
};

pub const B4RunOptions = struct {
    observation_binding: [32]u8,
    bank_epoch: u64,
    /// The actual-model runner selects this explicitly. The default preserves
    /// compatibility for callers retaining the materialized v3 head.
    greedy_head_mode: decode_lane4.GreedyHeadMode = .materialized,
    /// Same-binary strict attention arm. The observation re-derives exact
    /// lane/tile counters and refuses retention on an implicit fallback.
    attention_mode: decode_lane4.AttentionMode = .serial,
    /// Same-binary split/single-epoch Pair-down schedule arm. The observation
    /// independently derives every physical epoch/task counter.
    pair_down_mode: decode_lane4.PairDownMode = .split_control,
    /// Public observations require the production OS boot-relative clock.
    clock: runner_core.MonotonicClock = runner_core.MonotonicClock.system(),
};

pub const MonotonicIntervalV1 = struct {
    start_ns: u64,
    end_ns: u64,

    pub fn durationNs(self: MonotonicIntervalV1) u64 {
        std.debug.assert(self.end_ns >= self.start_ns);
        return self.end_ns - self.start_ns;
    }
};

pub const PublicationTimingBasis = enum(u8) {
    /// Legacy observer callbacks read the production monotonic clock at the
    /// exact per-lane publication boundary.
    observer_commit_exact,
    /// TokenTxn SinkV1 commit is infallible and performs no fallible clock I/O.
    /// The retained interval therefore ends at root join and is an explicit,
    /// conservative upper bound rather than an invented commit timestamp.
    root_completion_upper_bound,
};

/// `primary_publish` is the only interval suitable for primary throughput: it
/// starts at the measurement boundary and includes prefill/TTFT through the
/// final publication. Never compute throughput from first-token-to-last-token;
/// that would silently omit prefill. `time_to_first_publish` exposes TTFT,
/// while `postlude_join` isolates state hashing, cleanup, and root joining.
pub const ObservationTimingV1 = struct {
    abi_version: u64 = observation_abi,
    monotonic_clock_abi: u64 = runner_core.monotonic_clock_abi,
    publication_basis: PublicationTimingBasis,
    run: MonotonicIntervalV1,
    time_to_first_publish: MonotonicIntervalV1,
    primary_publish: MonotonicIntervalV1,
    postlude_join: MonotonicIntervalV1,
};

pub const OwnedLaneTokens = struct {
    allocator: std.mem.Allocator,
    storage: [width][]u32,

    pub fn tokens(self: *const OwnedLaneTokens, lane: usize) []const u32 {
        std.debug.assert(lane < width);
        return self.storage[lane];
    }

    pub fn deinit(self: *OwnedLaneTokens) void {
        for (&self.storage) |*journal| {
            self.allocator.free(journal.*);
            journal.* = &.{};
        }
    }
};

pub const B4PostCommitReceiptV1 = struct {
    abi_version: u64 = b4_post_commit_abi,
    resource_commit_observer_abi: u64 = generate_api.resource_commit_observer_abi,
    resource_bank_abi: u64 = resource_bank.abi,
    committed_ns: u64,
    released_snapshot_ns: u64,
    receipt: resource_bank.Receipt,
    before_snapshot: resource_bank.Snapshot,
    committed_snapshot: resource_bank.Snapshot,
    released_snapshot: resource_bank.Snapshot,
};

pub const M1x4Observation = struct {
    workload_binding: [32]u8,
    journal_root_binding: [32]u8,
    timing: ObservationTimingV1,
    outputs: OwnedLaneTokens,
    generation_states: [width]generate_api.GenerationStateTelemetry,
    execution: [width]generate_api.RequestExecutionTelemetry,
    resources: [width]generate_api.RequestResourceTelemetry,
    token_journal: runner_core.TokenJournalReceiptV1,
    token_events: runner_core.TokenEventMatrix,
    barrier: runner_core.M1BarrierReceiptV1,

    pub fn deinit(self: *M1x4Observation) void {
        self.outputs.deinit();
    }
};

pub const B4Observation = struct {
    workload_binding: [32]u8,
    journal_root_binding: [32]u8,
    timing: ObservationTimingV1,
    outputs: OwnedLaneTokens,
    generation_states: [width]generate_api.GenerationStateTelemetry,
    execution: decode_lane4.Telemetry,
    resources: generate_api.RequestResourceTelemetry,
    token_txn_journal: runner_core.B4TokenTxnJournalReceiptV1,
    token_txn_waves: runner_core.B4TokenTxnWaveMatrix,
    post_commit: B4PostCommitReceiptV1,

    pub fn deinit(self: *B4Observation) void {
        self.outputs.deinit();
    }
};

pub const B4CaptureError = error{
    InvalidConfiguration,
    ClockUnavailable,
    InvalidEvidence,
    DuplicateCommit,
    AlreadySealed,
    Incomplete,
    TimestampRegression,
    ReceiptMismatch,
};

pub const Error = generate_api.GenerateError ||
    resource_bank.Error ||
    runner_core.ClockError ||
    runner_core.TokenJournalError ||
    runner_core.B4TokenTxnJournalError ||
    runner_core.BarrierError ||
    B4CaptureError ||
    error{
        InvalidWorkload,
        ProductionClockRequired,
        ClaimOverflow,
        ThreadSpawnFailed,
        WorkerFailed,
        TimestampRegression,
        EvidenceMismatch,
        ResourceNotReleased,
    };

fn isZeroDigest(value: [32]u8) bool {
    return std.mem.eql(u8, &value, &([_]u8{0} ** 32));
}

fn validateWorkload(bindings: [width]RequestBinding) Error!void {
    const prompt_len = bindings[0].prompt.len;
    if (prompt_len == 0) return Error.InvalidWorkload;
    for (bindings) |binding| {
        if (binding.prompt.len != prompt_len) return Error.InvalidWorkload;
    }
    for (bindings, 0..) |binding, lane| {
        for (bindings[0..lane]) |prior| {
            if (binding.seed == prior.seed and
                std.mem.eql(u32, binding.prompt, prior.prompt))
                return Error.InvalidWorkload;
        }
    }
}

fn validateModelTokens(
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
) Error!void {
    try validateWorkload(bindings);
    if (model.config.vocab_size == 0 or isZeroDigest(model.source_fingerprint))
        return Error.InvalidWorkload;
    for (bindings) |binding| for (binding.prompt) |token| {
        if (token >= model.config.vocab_size) return Error.InvalidWorkload;
    };
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

const Mode = enum(u8) { m1x4 = 1, b4 = 2 };

fn deriveWorkloadBinding(
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
) Error![32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-runner-workload-binding-v1\x00");
    hashU64(&hash, observation_abi);
    hashU64(&hash, decode_lane4.abi);
    hashU64(&hash, engine.token_txn.abi);
    hashU64(&hash, engine.token_txn.sink_abi);
    hashU32(&hash, @intCast(width));
    hashU32(&hash, @intCast(tokens_per_lane));
    hash.update(&model.source_fingerprint);
    for (bindings, 0..) |binding, lane| {
        hashU32(&hash, @intCast(lane));
        hashU64(&hash, @intCast(binding.prompt.len));
        for (binding.prompt) |token| hashU32(&hash, token);
        hashU64(&hash, binding.seed);
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    if (isZeroDigest(result)) return Error.InvalidWorkload;
    return result;
}

fn deriveJournalRootBinding(
    mode: Mode,
    observation_binding: [32]u8,
    workload_binding: [32]u8,
) Error![32]u8 {
    if (isZeroDigest(observation_binding) or isZeroDigest(workload_binding))
        return Error.InvalidWorkload;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("glacier-lane4-runner-observation-binding-v1\x00");
    hashU64(&hash, observation_abi);
    hashU64(&hash, engine.token_txn.abi);
    hashU64(&hash, engine.token_txn.sink_abi);
    hashU8(&hash, @intFromEnum(mode));
    hash.update(&observation_binding);
    hash.update(&workload_binding);
    var result: [32]u8 = undefined;
    hash.final(&result);
    if (isZeroDigest(result)) return Error.InvalidWorkload;
    return result;
}

fn deriveB4TokenTxnRequestEpoch(bank_epoch: u64) Error!u64 {
    if (bank_epoch == 0) return Error.InvalidWorkload;
    const request_epoch = bank_epoch ^ 0x5458_4e31_4234_0001;
    if (request_epoch == 0) return Error.InvalidWorkload;
    return request_epoch;
}

fn addClaims(
    left: resource_bank.Claim,
    right: resource_bank.Claim,
) Error!resource_bank.Claim {
    var result: resource_bank.Claim = .{};
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        @field(result, field.name) = std.math.add(
            u64,
            @field(left, field.name),
            @field(right, field.name),
        ) catch return Error.ClaimOverflow;
    }
    return result;
}

fn m1GenerateOptions(binding: RequestBinding) generate_api.GenerateOptions {
    return .{
        .max_new_tokens = tokens_per_lane,
        .eos_token = std.math.maxInt(u32),
        .sampler = .{ .temperature = 0 },
        .seed = binding.seed,
        .num_threads = 1,
        .int4_activation = .q8,
        .use_persistent_executor = true,
        .mlp_representation = .pair_nibble_required,
        .decode_frame_mode = .compact_pair_required,
        .parallel_attention_min_context = null,
        .use_batch_prefill = false,
        .require_batch_prefill = false,
        .forced_tokens = &.{},
    };
}

fn b4Requests(bindings: [width]RequestBinding) [width]decode_lane4.Request {
    var requests: [width]decode_lane4.Request = undefined;
    for (&requests, bindings) |*request, binding| {
        request.* = .{
            .prompt = binding.prompt,
            .max_new_tokens = tokens_per_lane,
            .eos_token = std.math.maxInt(u32),
            .sampler = .{ .temperature = 0 },
            .seed = binding.seed,
            .forced_tokens = &.{},
        };
    }
    return requests;
}

fn freshSnapshot(snapshot: resource_bank.Snapshot) bool {
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

fn validateB4CommittedSnapshot(
    snapshot: resource_bank.Snapshot,
    before: resource_bank.Snapshot,
    receipt: resource_bank.Receipt,
) B4CaptureError!void {
    const claim = receipt.claim;
    const limits = runner_core.exactLimitsForClaim(claim) catch
        return B4CaptureError.InvalidEvidence;
    if (claim.queue_slots != width or (claim.hostBytes() catch 0) == 0 or
        receipt.bank_epoch != before.bank_epoch or receipt.slot_index != 0 or
        receipt.generation != 1 or receipt.owner_key == 0 or
        receipt.integrity == 0 or snapshot.abi_version != resource_bank.abi or
        snapshot.bank_epoch != before.bank_epoch or
        !std.meta.eql(snapshot.limits, limits) or
        !std.meta.eql(snapshot.used, claim) or
        !std.meta.eql(snapshot.peak, claim) or
        snapshot.peak_host_bytes != (claim.hostBytes() catch 0) or
        snapshot.active_reservations != 0 or
        snapshot.committed_receipts != 1 or
        snapshot.successful_reservations != 1 or
        snapshot.successful_commits != 1 or snapshot.cancellations != 0 or
        snapshot.releases != 0 or snapshot.rejected_capacity != 0 or
        snapshot.rejected_slots != 0)
        return B4CaptureError.InvalidEvidence;
}

fn validateB4ReleasedSnapshot(
    snapshot: resource_bank.Snapshot,
    committed: resource_bank.Snapshot,
) B4CaptureError!void {
    if (snapshot.abi_version != resource_bank.abi or
        snapshot.bank_epoch != committed.bank_epoch or
        !std.meta.eql(snapshot.limits, committed.limits) or
        !snapshot.used.isZero() or
        !std.meta.eql(snapshot.peak, committed.peak) or
        snapshot.peak_host_bytes != committed.peak_host_bytes or
        snapshot.active_reservations != 0 or
        snapshot.committed_receipts != 0 or
        snapshot.successful_reservations != 1 or
        snapshot.successful_commits != 1 or snapshot.cancellations != 0 or
        snapshot.releases != 1 or snapshot.rejected_capacity != 0 or
        snapshot.rejected_slots != 0)
        return B4CaptureError.InvalidEvidence;
}

pub const B4PostCommitCapture = struct {
    mutex: std.Thread.Mutex = .{},
    bank: *resource_bank.Bank,
    clock: runner_core.MonotonicClock,
    before_snapshot: resource_bank.Snapshot,
    committed_snapshot: ?resource_bank.Snapshot = null,
    receipt: ?resource_bank.Receipt = null,
    committed_ns: u64 = 0,
    failed: bool = false,
    sealed: bool = false,

    pub fn init(
        bank: *resource_bank.Bank,
        clock: runner_core.MonotonicClock,
    ) B4CaptureError!B4PostCommitCapture {
        if (clock.abi != runner_core.monotonic_clock_abi)
            return B4CaptureError.InvalidConfiguration;
        const before = bank.snapshot() catch
            return B4CaptureError.InvalidConfiguration;
        if (!freshSnapshot(before)) return B4CaptureError.InvalidConfiguration;
        return .{
            .bank = bank,
            .clock = clock,
            .before_snapshot = before,
        };
    }

    pub fn observer(self: *B4PostCommitCapture) generate_api.ResourceCommitObserver {
        return .{
            .context = self,
            .observe = observeB4PostCommit,
        };
    }

    fn capture(
        self: *B4PostCommitCapture,
        evidence: *const generate_api.ResourceCommitEvidenceV1,
    ) B4CaptureError!void {
        const committed_ns = self.clock.now() catch {
            self.mutex.lock();
            self.failed = true;
            self.mutex.unlock();
            return B4CaptureError.ClockUnavailable;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.failed or self.sealed) return B4CaptureError.InvalidEvidence;
        if (self.receipt != null) {
            self.failed = true;
            return B4CaptureError.DuplicateCommit;
        }
        if (evidence.abi != generate_api.resource_commit_observer_abi or
            evidence.resource_bank_abi != resource_bank.abi)
        {
            self.failed = true;
            return B4CaptureError.InvalidEvidence;
        }
        const snapshot = self.bank.snapshot() catch {
            self.failed = true;
            return B4CaptureError.InvalidEvidence;
        };
        validateB4CommittedSnapshot(
            snapshot,
            self.before_snapshot,
            evidence.receipt,
        ) catch |err| {
            self.failed = true;
            return err;
        };
        self.committed_ns = committed_ns;
        self.receipt = evidence.receipt;
        self.committed_snapshot = snapshot;
    }

    pub fn seal(self: *B4PostCommitCapture) B4CaptureError!B4PostCommitReceiptV1 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.sealed) return B4CaptureError.AlreadySealed;
        self.sealed = true;
        if (self.failed) return B4CaptureError.InvalidEvidence;
        const receipt = self.receipt orelse return B4CaptureError.Incomplete;
        const committed = self.committed_snapshot orelse
            return B4CaptureError.Incomplete;
        const released = self.bank.snapshot() catch
            return B4CaptureError.InvalidEvidence;
        try validateB4ReleasedSnapshot(released, committed);
        const released_ns = self.clock.now() catch
            return B4CaptureError.ClockUnavailable;
        if (released_ns < self.committed_ns)
            return B4CaptureError.TimestampRegression;
        const result: B4PostCommitReceiptV1 = .{
            .committed_ns = self.committed_ns,
            .released_snapshot_ns = released_ns,
            .receipt = receipt,
            .before_snapshot = self.before_snapshot,
            .committed_snapshot = committed,
            .released_snapshot = released,
        };
        try verifyB4PostCommitReceipt(result);
        return result;
    }
};

fn observeB4PostCommit(
    raw_context: *anyopaque,
    evidence: *const generate_api.ResourceCommitEvidenceV1,
) generate_api.ResourceCommitObserverError!void {
    const capture: *B4PostCommitCapture = @ptrCast(@alignCast(raw_context));
    capture.capture(evidence) catch |err| return switch (err) {
        B4CaptureError.ClockUnavailable => generate_api.ResourceCommitObserverError.Unavailable,
        else => generate_api.ResourceCommitObserverError.InvalidEvidence,
    };
}

pub fn verifyB4PostCommitReceipt(
    receipt: B4PostCommitReceiptV1,
) B4CaptureError!void {
    if (receipt.abi_version != b4_post_commit_abi or
        receipt.resource_commit_observer_abi !=
            generate_api.resource_commit_observer_abi or
        receipt.resource_bank_abi != resource_bank.abi or
        !freshSnapshot(receipt.before_snapshot) or
        receipt.committed_ns > receipt.released_snapshot_ns)
        return B4CaptureError.ReceiptMismatch;
    try validateB4CommittedSnapshot(
        receipt.committed_snapshot,
        receipt.before_snapshot,
        receipt.receipt,
    );
    try validateB4ReleasedSnapshot(
        receipt.released_snapshot,
        receipt.committed_snapshot,
    );
}

fn deriveObservationTiming(
    run_start_ns: u64,
    roots_joined_ns: u64,
    events: *const runner_core.TokenEventMatrix,
    receipt: runner_core.TokenJournalReceiptV1,
) Error!ObservationTimingV1 {
    if (roots_joined_ns < run_start_ns) return Error.TimestampRegression;
    try runner_core.verifyTokenJournal(events, receipt);
    if (receipt.expected_tokens_per_lane != tokens_per_lane or
        receipt.event_count != width * tokens_per_lane)
        return Error.EvidenceMismatch;

    var first_publish_ns: u64 = std.math.maxInt(u64);
    var last_publish_ns: u64 = 0;
    for (receipt.lane_tips, 0..) |tip, lane| {
        if (tip.logical_request_index != lane or
            tip.event_count != tokens_per_lane)
            return Error.EvidenceMismatch;
        first_publish_ns = @min(first_publish_ns, tip.first_monotonic_ns);
        last_publish_ns = @max(last_publish_ns, tip.last_monotonic_ns);
        for (events[lane][0..tokens_per_lane]) |event| {
            if (event.monotonic_ns < run_start_ns or
                event.monotonic_ns > roots_joined_ns)
                return Error.TimestampRegression;
        }
    }
    if (first_publish_ns < run_start_ns or
        last_publish_ns < first_publish_ns or
        last_publish_ns > roots_joined_ns)
        return Error.TimestampRegression;
    return .{
        .publication_basis = .observer_commit_exact,
        .run = .{ .start_ns = run_start_ns, .end_ns = roots_joined_ns },
        .time_to_first_publish = .{
            .start_ns = run_start_ns,
            .end_ns = first_publish_ns,
        },
        .primary_publish = .{
            .start_ns = run_start_ns,
            .end_ns = last_publish_ns,
        },
        .postlude_join = .{
            .start_ns = last_publish_ns,
            .end_ns = roots_joined_ns,
        },
    };
}

fn deriveB4TokenTxnTiming(
    run_start_ns: u64,
    roots_joined_ns: u64,
    waves: *const runner_core.B4TokenTxnWaveMatrix,
    receipt: runner_core.B4TokenTxnJournalReceiptV1,
) Error!ObservationTimingV1 {
    if (roots_joined_ns < run_start_ns) return Error.TimestampRegression;
    try runner_core.verifyB4TokenTxnJournal(waves, receipt);
    // SinkV1::commit has no error channel. Reading MonotonicClock there would
    // add fallible I/O to the supposedly infallible visibility boundary. Use
    // root completion as an honest upper bound for both TTFT and full publish.
    return .{
        .publication_basis = .root_completion_upper_bound,
        .run = .{ .start_ns = run_start_ns, .end_ns = roots_joined_ns },
        .time_to_first_publish = .{
            .start_ns = run_start_ns,
            .end_ns = roots_joined_ns,
        },
        .primary_publish = .{
            .start_ns = run_start_ns,
            .end_ns = roots_joined_ns,
        },
        .postlude_join = .{
            .start_ns = roots_joined_ns,
            .end_ns = roots_joined_ns,
        },
    };
}

fn validatePublishedTokens(
    storage: [width][]u32,
    events: *const runner_core.TokenEventMatrix,
) Error!void {
    for (storage, 0..) |tokens, lane| {
        if (tokens.len != tokens_per_lane) return Error.EvidenceMismatch;
        for (tokens, 0..) |token, step| {
            const event = events[lane][step];
            if (event.logical_request_index != lane or
                event.lane_sequence_index != step or
                event.step_index != step or event.token_id != token or
                event.terminal != (step + 1 == tokens_per_lane))
                return Error.EvidenceMismatch;
        }
    }
}

fn validateB4TokenTxnPublishedTokens(
    storage: [width][]u32,
    waves: *const runner_core.B4TokenTxnWaveMatrix,
) Error!void {
    for (storage, 0..) |tokens, lane| {
        if (tokens.len != tokens_per_lane) return Error.EvidenceMismatch;
        for (tokens, 0..) |token, sequence| {
            const receipt = waves[sequence].receipt;
            const lane_bit = @as(u8, 1) << @intCast(lane);
            if (receipt.transaction_sequence != sequence or
                receipt.live_mask != 0b1111 or
                receipt.lane_step_indices[lane] != sequence or
                receipt.token_ids[lane] != token or
                (receipt.terminal_mask & lane_bit != 0) !=
                    (sequence + 1 == tokens_per_lane))
                return Error.EvidenceMismatch;
        }
    }
}

fn validateGenerationStates(
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
    storage: [width][]u32,
    states: [width]generate_api.GenerationStateTelemetry,
) Error!void {
    for (states, 0..) |state, lane| {
        const expected_positions = std.math.add(
            usize,
            bindings[lane].prompt.len,
            tokens_per_lane - 1,
        ) catch return Error.EvidenceMismatch;
        const initial_prng = std.Random.DefaultPrng.init(bindings[lane].seed);
        const output_sha256 = generate_api.tokenSequenceSha256(storage[lane]);
        if (state.abi_version != generate_api.generation_state_abi or
            state.rng_abi != generate_api.generation_rng_abi or
            !state.complete or state.kv_positions != expected_positions or
            state.published_tokens != tokens_per_lane or
            state.sampling_calls != tokens_per_lane or
            isZeroDigest(state.kv_sha256) or isZeroDigest(state.output_sha256) or
            !std.mem.eql(u8, &state.output_sha256, &output_sha256) or
            !std.mem.eql(u64, &state.rng_state, &initial_prng.s))
            return Error.EvidenceMismatch;
        if (model.config.num_layers == 0) return Error.EvidenceMismatch;
    }
}

fn validateM1Execution(
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
    execution: [width]generate_api.RequestExecutionTelemetry,
) Error!void {
    for (execution, 0..) |actual, lane| {
        const token_graphs = std.math.add(
            usize,
            bindings[lane].prompt.len,
            tokens_per_lane - 1,
        ) catch return Error.EvidenceMismatch;
        const layer_graphs = std.math.mul(
            usize,
            token_graphs,
            model.config.num_layers,
        ) catch return Error.EvidenceMismatch;
        const projection_dispatches = std.math.mul(
            usize,
            layer_graphs,
            5,
        ) catch return Error.EvidenceMismatch;
        const qkv_projection_dispatches = std.math.mul(
            usize,
            layer_graphs,
            3,
        ) catch return Error.EvidenceMismatch;
        if (actual.abi_version != generate_api.request_execution_telemetry_abi or
            !actual.complete or actual.admitted_requests != 1 or
            actual.thread_participants != 1 or
            actual.prompt_token_graphs != bindings[lane].prompt.len or
            actual.decode_token_graphs != tokens_per_lane - 1 or
            actual.token_graphs != token_graphs or
            actual.layer_graphs != layer_graphs or
            actual.projection_dispatches != projection_dispatches or
            actual.qkv_projection_dispatches != qkv_projection_dispatches or
            actual.pair_dispatches != layer_graphs or
            actual.lm_head_dispatches != tokens_per_lane or
            actual.active_lane_steps != token_graphs)
            return Error.EvidenceMismatch;
    }
}

fn claimTelemetryMatches(
    telemetry: generate_api.RequestResourceTelemetry,
    claim: resource_bank.Claim,
) bool {
    return telemetry.host_claim_bytes == (claim.hostBytes() catch return false) and
        telemetry.capsule_bytes == claim.capsule_bytes and
        telemetry.kv_bytes == claim.kv_bytes and
        telemetry.activation_bytes == claim.activation_bytes and
        telemetry.partial_bytes == claim.partial_bytes and
        telemetry.logits_bytes == claim.logits_bytes and
        telemetry.output_journal_bytes == claim.output_journal_bytes and
        telemetry.staging_bytes == claim.staging_bytes and
        telemetry.device_bytes == claim.device_bytes and
        telemetry.io_bytes == claim.io_bytes and
        telemetry.queue_slots == claim.queue_slots;
}

fn validateM1Resources(
    aggregate: resource_bank.Claim,
    claims: [width]resource_bank.Claim,
    resources: [width]generate_api.RequestResourceTelemetry,
    barrier: runner_core.M1BarrierReceiptV1,
) Error!void {
    const aggregate_host = aggregate.hostBytes() catch
        return Error.EvidenceMismatch;
    for (resources, 0..) |telemetry, lane| {
        const receipt = barrier.receipts[lane];
        const committed_receipts = std.math.cast(
            u64,
            telemetry.committed_receipts,
        ) orelse return Error.EvidenceMismatch;
        const released_and_committed = std.math.add(
            u64,
            telemetry.releases,
            committed_receipts,
        ) catch return Error.EvidenceMismatch;
        if (!claimTelemetryMatches(telemetry, claims[lane]) or
            !std.meta.eql(receipt.claim, claims[lane]) or
            telemetry.owner_key != receipt.owner_key or
            telemetry.bank_epoch != receipt.bank_epoch or
            telemetry.receipt_slot_index != receipt.slot_index or
            telemetry.receipt_generation != receipt.generation or
            telemetry.receipt_integrity != receipt.integrity or
            telemetry.host_limit_bytes != aggregate_host or
            telemetry.peak_host_bytes != aggregate_host or
            telemetry.reservations != width or telemetry.commits != width or
            telemetry.cancellations != 0 or telemetry.releases == 0 or
            telemetry.releases > width or telemetry.capacity_rejects != 0 or
            telemetry.slot_rejects != 0 or telemetry.active_reservations != 0 or
            released_and_committed != width or
            telemetry.derive_rejects != 0 or telemetry.release_failures != 0)
            return Error.EvidenceMismatch;
    }
}

fn validateB4ScheduleTelemetry(
    expected_attention_mode: decode_lane4.AttentionMode,
    expected_pair_down_mode: decode_lane4.PairDownMode,
    qkv_projection_dispatches: usize,
    qkv_projection_waves: usize,
    qkv_projection_joins_elided: usize,
    expected_shared_lane_dispatches: usize,
    expected_shared_tiles: usize,
    expected_pair_down_single_epochs: usize,
    expected_pair_down_split_epochs: usize,
    expected_pair_down_joins_elided: usize,
    expected_pair_down_worker_tasks: usize,
    expected_pair_down_background_enqueues: usize,
    telemetry: decode_lane4.Telemetry,
) Error!void {
    if (telemetry.projection_wave_abi_version !=
        decode_lane4.projection_wave_abi or
        telemetry.shared_kv_attention_abi_version !=
            decode_lane4.shared_kv_attention_abi or
        telemetry.pair_down_wave_abi_version !=
            decode_lane4.pair_down_wave_abi or
        telemetry.attention_mode != expected_attention_mode or
        telemetry.pair_down_mode != expected_pair_down_mode or
        telemetry.qkv_projection_dispatches != qkv_projection_dispatches or
        telemetry.qkv_projection_waves != qkv_projection_waves or
        telemetry.qkv_projection_joins_elided !=
            qkv_projection_joins_elided or
        telemetry.shared_kv_attention_lane_dispatches !=
            expected_shared_lane_dispatches or
        telemetry.shared_kv_attention_tiles != expected_shared_tiles or
        telemetry.pair_down_single_epochs !=
            expected_pair_down_single_epochs or
        telemetry.pair_down_split_worker_epochs !=
            expected_pair_down_split_epochs or
        telemetry.pair_down_joins_elided !=
            expected_pair_down_joins_elided or
        telemetry.pair_down_worker_tasks != expected_pair_down_worker_tasks or
        telemetry.pair_down_background_enqueues !=
            expected_pair_down_background_enqueues or
        telemetry.pair_down_enqueue_rejects != 0)
        return Error.EvidenceMismatch;
}

fn validateB4Execution(
    model: engine.loader.LoadedModel,
    prompt_len: usize,
    expected_token_txn_request_epoch: u64,
    expected_greedy_head_mode: decode_lane4.GreedyHeadMode,
    expected_attention_mode: decode_lane4.AttentionMode,
    expected_pair_down_mode: decode_lane4.PairDownMode,
    telemetry: decode_lane4.Telemetry,
) Error!void {
    try validateB4TokenTxnTelemetry(
        expected_token_txn_request_epoch,
        telemetry,
    );
    if (model.config.dim == 0 or model.config.head_dim == 0 or
        model.config.num_heads == 0 or model.config.num_kv_heads == 0 or
        model.config.num_heads % model.config.num_kv_heads != 0)
        return Error.EvidenceMismatch;
    const kv_dim = std.math.mul(
        usize,
        model.config.num_kv_heads,
        model.config.head_dim,
    ) catch return Error.EvidenceMismatch;
    const token_graphs = std.math.add(
        usize,
        prompt_len,
        tokens_per_lane - 1,
    ) catch return Error.EvidenceMismatch;
    const layer_graphs = std.math.mul(
        usize,
        token_graphs,
        model.config.num_layers,
    ) catch return Error.EvidenceMismatch;
    const projection_dispatches = std.math.mul(
        usize,
        layer_graphs,
        5,
    ) catch return Error.EvidenceMismatch;
    const qkv_projection_dispatches = std.math.mul(
        usize,
        layer_graphs,
        3,
    ) catch return Error.EvidenceMismatch;
    var qkv_waves_per_token_graph: usize = 0;
    var qkv_joins_per_token_graph: usize = 0;
    for (model.layers) |layer| {
        const q_group = (layer.wq_int4 orelse
            return Error.EvidenceMismatch).group_size;
        const k_group = (layer.wk_int4 orelse
            return Error.EvidenceMismatch).group_size;
        const v_group = (layer.wv_int4 orelse
            return Error.EvidenceMismatch).group_size;
        if ((q_group != 8 and q_group != 16) or
            (k_group != 8 and k_group != 16) or
            (v_group != 8 and v_group != 16))
            return Error.EvidenceMismatch;
        const groups = [3]u32{ q_group, k_group, v_group };
        const output_features = [3]usize{
            model.config.dim,
            kv_dim,
            kv_dim,
        };
        for ([_]u32{ 8, 16 }) |group| {
            var found = false;
            var independent_worker_epochs: usize = 0;
            var max_out_f: usize = 0;
            for (groups, output_features) |member_group, out_f| {
                if (member_group != group) continue;
                found = true;
                max_out_f = @max(max_out_f, out_f);
                independent_worker_epochs += @intFromBool(
                    engine.int4_matmul.preparedBatchProjectionUsesWorkerEpoch(
                        out_f,
                        width,
                    ),
                );
            }
            if (!found) continue;
            qkv_waves_per_token_graph = std.math.add(
                usize,
                qkv_waves_per_token_graph,
                1,
            ) catch return Error.EvidenceMismatch;
            const wave_worker_epochs: usize = @intFromBool(
                engine.int4_matmul.preparedBatchProjectionUsesWorkerEpoch(
                    max_out_f,
                    width,
                ),
            );
            if (wave_worker_epochs > independent_worker_epochs)
                return Error.EvidenceMismatch;
            qkv_joins_per_token_graph = std.math.add(
                usize,
                qkv_joins_per_token_graph,
                independent_worker_epochs - wave_worker_epochs,
            ) catch return Error.EvidenceMismatch;
        }
    }
    const qkv_projection_waves = std.math.mul(
        usize,
        token_graphs,
        qkv_waves_per_token_graph,
    ) catch return Error.EvidenceMismatch;
    const qkv_projection_joins_elided = std.math.mul(
        usize,
        token_graphs,
        qkv_joins_per_token_graph,
    ) catch return Error.EvidenceMismatch;
    const active_lane_steps = std.math.mul(
        usize,
        token_graphs,
        width,
    ) catch return Error.EvidenceMismatch;
    const expected_shared_lane_dispatches = switch (expected_attention_mode) {
        .serial => 0,
        .shared_kv_required => std.math.mul(
            usize,
            layer_graphs,
            width,
        ) catch return Error.EvidenceMismatch,
    };
    const expected_shared_tiles = switch (expected_attention_mode) {
        .serial => 0,
        .shared_kv_required => blk: {
            const group_size = model.config.num_heads /
                model.config.num_kv_heads;
            if (group_size <= 1) return Error.EvidenceMismatch;
            const tiles_per_kv = group_size /
                forward.max_shared_kv_tile_width +
                @intFromBool(
                    group_size % forward.max_shared_kv_tile_width != 0,
                );
            const tiles_per_lane = std.math.mul(
                usize,
                model.config.num_kv_heads,
                tiles_per_kv,
            ) catch return Error.EvidenceMismatch;
            break :blk std.math.mul(
                usize,
                expected_shared_lane_dispatches,
                tiles_per_lane,
            ) catch return Error.EvidenceMismatch;
        },
    };
    if (model.config.dim % 4 != 0 or model.config.hidden_dim == 0)
        return Error.EvidenceMismatch;
    const down_task_count = @min(
        @min(width, model.config.dim / 4),
        engine.int4_matmul.prepared_batch_projection_max_tasks,
    );
    const pair_tile_rows: usize = if (model.config.hidden_dim >= 64) 64 else 32;
    const producer_shards = model.config.hidden_dim / pair_tile_rows +
        @as(usize, @intFromBool(model.config.hidden_dim % pair_tile_rows != 0));
    const producer_task_count = @min(width, producer_shards);
    const pair_down_participants = @max(
        producer_task_count,
        down_task_count,
    );
    if (pair_down_participants == 0) return Error.EvidenceMismatch;
    const split_epochs_per_layer: usize = 1 +
        @as(usize, @intFromBool(down_task_count >= 2));
    const expected_pair_down_split_epochs = std.math.mul(
        usize,
        layer_graphs,
        split_epochs_per_layer,
    ) catch return Error.EvidenceMismatch;
    const PairDownExpected = struct {
        single_epochs: usize,
        joins_elided: usize,
        worker_tasks: usize,
        background_enqueues: usize,
    };
    const expected_pair_down: PairDownExpected = switch (expected_pair_down_mode) {
        .split_control => .{
            .single_epochs = @as(usize, 0),
            .joins_elided = @as(usize, 0),
            .worker_tasks = @as(usize, 0),
            .background_enqueues = @as(usize, 0),
        },
        .single_epoch_required => .{
            .single_epochs = layer_graphs,
            .joins_elided = std.math.mul(
                usize,
                layer_graphs,
                split_epochs_per_layer - 1,
            ) catch return Error.EvidenceMismatch,
            .worker_tasks = std.math.mul(
                usize,
                layer_graphs,
                pair_down_participants,
            ) catch return Error.EvidenceMismatch,
            .background_enqueues = std.math.mul(
                usize,
                layer_graphs,
                pair_down_participants - 1,
            ) catch return Error.EvidenceMismatch,
        },
    };
    try validateB4ScheduleTelemetry(
        expected_attention_mode,
        expected_pair_down_mode,
        qkv_projection_dispatches,
        qkv_projection_waves,
        qkv_projection_joins_elided,
        expected_shared_lane_dispatches,
        expected_shared_tiles,
        expected_pair_down.single_epochs,
        expected_pair_down_split_epochs,
        expected_pair_down.joins_elided,
        expected_pair_down.worker_tasks,
        expected_pair_down.background_enqueues,
        telemetry,
    );
    if (telemetry.abi_version != decode_lane4.abi or
        telemetry.admitted_cohorts != 1 or telemetry.cohort_width != width or
        telemetry.thread_participants != width or
        telemetry.frame_payload_bytes == 0 or
        telemetry.token_graphs != token_graphs or
        telemetry.layer_m4_graphs != layer_graphs or
        telemetry.projection_m4_dispatches != projection_dispatches or
        telemetry.pair_m4_dispatches != layer_graphs or
        telemetry.lm_head_m4_dispatches != tokens_per_lane or
        telemetry.active_lane_steps != active_lane_steps or
        telemetry.padded_lane_steps != 0 or telemetry.fallbacks != 0 or
        telemetry.lane_attention_enqueue_rejects != 0 or
        telemetry.state_hash_parallel_dispatches != 1 or
        telemetry.state_hash_tasks != width or
        telemetry.state_hash_enqueue_rejects != 0)
        return Error.EvidenceMismatch;
    try validateB4GreedyHeadExecution(
        model.config.vocab_size,
        expected_greedy_head_mode,
        telemetry,
    );
}

fn validateB4TokenTxnTelemetry(
    expected_request_epoch: u64,
    telemetry: decode_lane4.Telemetry,
) Error!void {
    if (expected_request_epoch == 0 or
        telemetry.token_txn_abi_version != engine.token_txn.abi or
        telemetry.token_txn_sink_abi_version != engine.token_txn.sink_abi or
        telemetry.publication_mode != .token_txn_required or
        telemetry.token_txn_request_epoch != expected_request_epoch or
        telemetry.token_txn_commits != tokens_per_lane or
        telemetry.token_txn_lane_commits != width * tokens_per_lane or
        telemetry.token_txn_first_token_commits != 1 or
        telemetry.token_txn_kv_row_commits !=
            width * (tokens_per_lane - 1) or
        telemetry.token_txn_aborts != 0 or
        telemetry.token_txn_provisional_aborts != 0 or
        telemetry.token_txn_sink_rejects != 0 or
        telemetry.token_txn_last_sequence != tokens_per_lane - 1)
        return Error.EvidenceMismatch;
}

fn materializedLogitsBytes(vocab_size: usize) Error!usize {
    const rows = std.math.mul(usize, width, vocab_size) catch
        return Error.EvidenceMismatch;
    const payload = std.math.mul(usize, rows, @sizeOf(f32)) catch
        return Error.EvidenceMismatch;
    return std.math.add(usize, payload, 2 * @sizeOf(usize)) catch
        return Error.EvidenceMismatch;
}

/// Re-derive the strict head ledger without trusting the implementation's
/// counters. This remains separate from the broader graph validation so unit
/// tests can mutation-check both modes without constructing a model fixture.
fn validateB4GreedyHeadExecution(
    vocab_size: usize,
    expected_mode: decode_lane4.GreedyHeadMode,
    telemetry: decode_lane4.Telemetry,
) Error!void {
    if (vocab_size == 0 or
        telemetry.greedy_head_abi_version != decode_lane4.greedy_head_abi or
        telemetry.greedy_head_mode != expected_mode or
        telemetry.streaming_greedy_head_rejects != 0 or
        telemetry.streaming_greedy_head_enqueue_rejects != 0)
        return Error.EvidenceMismatch;

    switch (expected_mode) {
        .materialized => {
            if (telemetry.materialized_lm_head_m4_dispatches !=
                tokens_per_lane or
                telemetry.streaming_greedy_head_m4_dispatches != 0 or
                telemetry.streaming_greedy_head_tiles != 0 or
                telemetry.streaming_greedy_head_tasks != 0 or
                telemetry.streaming_greedy_head_shards != 0 or
                telemetry.streaming_greedy_head_lane_candidates != 0 or
                telemetry.streaming_greedy_head_tile_scratch_bytes != 0 or
                telemetry.materialized_logits_reclaimed_bytes != 0)
                return Error.EvidenceMismatch;
        },
        .streaming_required => {
            if (vocab_size % 4 != 0) return Error.EvidenceMismatch;
            const tasks_per_graph = @min(width, vocab_size / 4);
            const expected_tasks = std.math.mul(
                usize,
                tokens_per_lane,
                tasks_per_graph,
            ) catch return Error.EvidenceMismatch;
            const expected_candidates = std.math.mul(
                usize,
                expected_tasks,
                width,
            ) catch return Error.EvidenceMismatch;
            if (telemetry.materialized_lm_head_m4_dispatches != 0 or
                telemetry.streaming_greedy_head_m4_dispatches !=
                    tokens_per_lane or
                telemetry.streaming_greedy_head_tiles != 0 or
                telemetry.streaming_greedy_head_tasks != expected_tasks or
                telemetry.streaming_greedy_head_shards != expected_tasks or
                telemetry.streaming_greedy_head_lane_candidates !=
                    expected_candidates or
                telemetry.streaming_greedy_head_tile_scratch_bytes != 0 or
                telemetry.materialized_logits_reclaimed_bytes !=
                    try materializedLogitsBytes(vocab_size))
                return Error.EvidenceMismatch;
        },
    }
}

fn validateB4Resources(
    claim: resource_bank.Claim,
    telemetry: generate_api.RequestResourceTelemetry,
    receipt: B4PostCommitReceiptV1,
) Error!void {
    const host = claim.hostBytes() catch return Error.EvidenceMismatch;
    if (!claimTelemetryMatches(telemetry, claim) or
        !std.meta.eql(receipt.receipt.claim, claim) or
        telemetry.owner_key != receipt.receipt.owner_key or
        telemetry.bank_epoch != receipt.receipt.bank_epoch or
        telemetry.receipt_slot_index != receipt.receipt.slot_index or
        telemetry.receipt_generation != receipt.receipt.generation or
        telemetry.receipt_integrity != receipt.receipt.integrity or
        telemetry.host_limit_bytes != host or telemetry.peak_host_bytes != host or
        telemetry.reservations != 1 or telemetry.commits != 1 or
        telemetry.cancellations != 0 or telemetry.releases != 1 or
        telemetry.capacity_rejects != 0 or telemetry.slot_rejects != 0 or
        telemetry.active_reservations != 0 or
        telemetry.committed_receipts != 0 or telemetry.derive_rejects != 0 or
        telemetry.release_failures != 0)
        return Error.EvidenceMismatch;
}

fn expectBankReleased(bank: *resource_bank.Bank) Error!void {
    const snapshot = try bank.snapshot();
    if (!snapshot.used.isZero() or snapshot.active_reservations != 0 or
        snapshot.committed_receipts != 0)
        return Error.ResourceNotReleased;
}

const M1WorkerError = generate_api.GenerateError || runner_core.BarrierError;

const M1Worker = struct {
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    binding: RequestBinding,
    bank: *resource_bank.Bank,
    participant: *runner_core.M1BarrierParticipant,
    journal: *runner_core.TokenEventJournal,
    lane: usize,
    state: generate_api.GenerationStateTelemetry = .{},
    execution: generate_api.RequestExecutionTelemetry = .{},
    resources: generate_api.RequestResourceTelemetry = .{},
    output: ?[]u32 = null,
    failure: ?M1WorkerError = null,

    fn run(self: *@This()) void {
        var options = m1GenerateOptions(self.binding);
        options.request_resource_bank = self.bank;
        options.request_resource_telemetry = &self.resources;
        options.resource_commit_observer = self.participant.observer();
        options.generation_state_telemetry = &self.state;
        options.request_execution_telemetry = &self.execution;
        options.token_publication_observer =
            self.journal.observer(@intCast(self.lane));
        const output = generate_api.generate(
            self.allocator,
            self.model,
            self.binding.prompt,
            options,
        ) catch |err| {
            self.failure = err;
            self.participant.barrier.abort();
            return;
        };
        self.participant.markFinished() catch |err| {
            self.allocator.free(output);
            self.failure = err;
            self.participant.barrier.abort();
            return;
        };
        self.output = output;
    }
};

const B4Worker = struct {
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    requests: [width]decode_lane4.Request,
    bank: *resource_bank.Bank,
    capture: *B4PostCommitCapture,
    journal: *runner_core.B4TokenTxnJournal,
    token_txn_request_epoch: u64,
    greedy_head_mode: decode_lane4.GreedyHeadMode,
    attention_mode: decode_lane4.AttentionMode,
    pair_down_mode: decode_lane4.PairDownMode,
    telemetry: decode_lane4.Telemetry = .{},
    resources: generate_api.RequestResourceTelemetry = .{},
    result: ?decode_lane4.Result = null,
    failure: ?generate_api.GenerateError = null,

    fn run(self: *@This()) void {
        self.result = decode_lane4.generate(
            self.allocator,
            self.model,
            self.requests,
            .{
                .num_threads = width,
                .request_resource_bank = self.bank,
                .resource_telemetry = &self.resources,
                .resource_commit_observer = self.capture.observer(),
                .token_txn_publication = .{
                    .request_epoch = self.token_txn_request_epoch,
                    .sink = self.journal.sink(),
                },
                .greedy_head_mode = self.greedy_head_mode,
                .attention_mode = self.attention_mode,
                .pair_down_mode = self.pair_down_mode,
                .telemetry = &self.telemetry,
            },
        ) catch |err| {
            self.failure = err;
            return;
        };
    }
};

/// Run four strict serial PairNibble requests as four root threads. The caller
/// coordinates only root creation/join; request execution begins only after
/// all four exact one-slot receipts reach the post-commit barrier. `allocator`
/// must support concurrent use by four independent generation roots.
pub fn runM1x4(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
    options: M1RunOptions,
) Error!M1x4Observation {
    if (!options.clock.isSystem()) return Error.ProductionClockRequired;
    try validateModelTokens(model, bindings);
    const workload_binding = try deriveWorkloadBinding(model, bindings);
    const journal_root = try deriveJournalRootBinding(
        .m1x4,
        options.observation_binding,
        workload_binding,
    );

    var claims: [width]resource_bank.Claim = undefined;
    var aggregate: resource_bank.Claim = .{};
    for (&claims, bindings) |*claim, binding| {
        claim.* = try generate_api.deriveResourceClaim(
            model,
            binding.prompt,
            m1GenerateOptions(binding),
        );
        if (claim.queue_slots != 1) return Error.EvidenceMismatch;
        aggregate = try addClaims(aggregate, claim.*);
    }
    if (aggregate.queue_slots != width) return Error.EvidenceMismatch;

    var slots = [_]resource_bank.Slot{.{}} ** width;
    var bank = try resource_bank.Bank.init(
        &slots,
        try runner_core.exactLimitsForClaim(aggregate),
        options.bank_epoch,
    );
    var barrier = try runner_core.M1PostCommitBarrier.init(
        &bank,
        options.clock,
        options.barrier_epoch,
        options.barrier_timeout_ns,
    );
    var journal = try runner_core.TokenEventJournal.init(
        options.clock,
        tokens_per_lane,
        journal_root,
    );
    var participants: [width]runner_core.M1BarrierParticipant = undefined;
    for (&participants, 0..) |*participant, lane|
        participant.* = try barrier.participant(lane);

    var workers: [width]M1Worker = undefined;
    for (&workers, 0..) |*worker, lane| {
        worker.* = .{
            .allocator = allocator,
            .model = model,
            .binding = bindings[lane],
            .bank = &bank,
            .participant = &participants[lane],
            .journal = &journal,
            .lane = lane,
        };
    }
    defer for (&workers) |*worker| if (worker.output) |output| {
        allocator.free(output);
        worker.output = null;
    };

    const run_start_ns = try options.clock.now();
    var threads: [width]std.Thread = undefined;
    var started: usize = 0;
    defer if (started != 0) {
        barrier.abort();
        for (threads[0..started]) |thread| thread.join();
    };
    for (&workers, 0..) |*worker, lane| {
        threads[lane] = std.Thread.spawn(.{}, M1Worker.run, .{worker}) catch {
            barrier.abort();
            for (threads[0..started]) |thread| thread.join();
            started = 0;
            try expectBankReleased(&bank);
            return Error.ThreadSpawnFailed;
        };
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    started = 0;
    const roots_joined_ns = try options.clock.now();
    if (roots_joined_ns < run_start_ns) return Error.TimestampRegression;

    for (workers) |worker| if (worker.failure) |failure| {
        try expectBankReleased(&bank);
        return failure;
    };
    try expectBankReleased(&bank);

    // Every root has joined before either evidence primitive seals. SHA-256
    // journal work is consequently outside both publish and join intervals.
    const barrier_receipt = try barrier.seal();
    try runner_core.verifyM1BarrierReceipt(barrier_receipt);
    const journal_receipt = try journal.seal();
    var token_events: runner_core.TokenEventMatrix = undefined;
    try journal.copySealedEvents(&token_events);
    const timing = try deriveObservationTiming(
        run_start_ns,
        roots_joined_ns,
        &token_events,
        journal_receipt,
    );

    var outputs: OwnedLaneTokens = .{
        .allocator = allocator,
        .storage = undefined,
    };
    var generation_states: [width]generate_api.GenerationStateTelemetry = undefined;
    var execution: [width]generate_api.RequestExecutionTelemetry = undefined;
    var resources: [width]generate_api.RequestResourceTelemetry = undefined;
    var moved_outputs: usize = 0;
    errdefer for (outputs.storage[0..moved_outputs]) |output| allocator.free(output);
    for (&workers, 0..) |*worker, lane| {
        outputs.storage[lane] = worker.output orelse return Error.WorkerFailed;
        worker.output = null;
        moved_outputs += 1;
        generation_states[lane] = worker.state;
        execution[lane] = worker.execution;
        resources[lane] = worker.resources;
    }

    try validatePublishedTokens(outputs.storage, &token_events);
    try validateGenerationStates(model, bindings, outputs.storage, generation_states);
    try validateM1Execution(model, bindings, execution);
    try validateM1Resources(aggregate, claims, resources, barrier_receipt);
    for (barrier_receipt.intervals, 0..) |interval, lane| {
        if (interval.ready_ns < timing.run.start_ns or
            interval.start_ns < timing.run.start_ns or
            interval.end_ns > timing.run.end_ns)
            return Error.TimestampRegression;
        for (token_events[lane][0..tokens_per_lane]) |event| {
            if (event.monotonic_ns < interval.start_ns or
                event.monotonic_ns > interval.end_ns)
                return Error.TimestampRegression;
        }
    }

    return .{
        .workload_binding = workload_binding,
        .journal_root_binding = journal_root,
        .timing = timing,
        .outputs = outputs,
        .generation_states = generation_states,
        .execution = execution,
        .resources = resources,
        .token_journal = journal_receipt,
        .token_events = token_events,
        .barrier = barrier_receipt,
    };
}

/// Run one DecodeLane4 root with exactly four participants. The coordinator
/// never enters the cohort pool and waits only for that root to finish.
pub fn runB4(
    allocator: std.mem.Allocator,
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
    options: B4RunOptions,
) Error!B4Observation {
    if (!options.clock.isSystem()) return Error.ProductionClockRequired;
    try validateModelTokens(model, bindings);
    const workload_binding = try deriveWorkloadBinding(model, bindings);
    const journal_root = try deriveJournalRootBinding(
        .b4,
        options.observation_binding,
        workload_binding,
    );
    const token_txn_request_epoch = try deriveB4TokenTxnRequestEpoch(
        options.bank_epoch,
    );
    const requests = b4Requests(bindings);
    const claim = try decode_lane4.deriveResourceClaim(
        model,
        requests,
        .{
            .num_threads = width,
            .greedy_head_mode = options.greedy_head_mode,
            .attention_mode = options.attention_mode,
            .pair_down_mode = options.pair_down_mode,
        },
    );
    if (claim.queue_slots != width) return Error.EvidenceMismatch;

    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var bank = try resource_bank.Bank.init(
        &slots,
        try runner_core.exactLimitsForClaim(claim),
        options.bank_epoch,
    );
    var capture = try B4PostCommitCapture.init(&bank, options.clock);
    var journal = try runner_core.B4TokenTxnJournal.init(
        token_txn_request_epoch,
        journal_root,
    );
    var worker: B4Worker = .{
        .allocator = allocator,
        .model = model,
        .requests = requests,
        .bank = &bank,
        .capture = &capture,
        .journal = &journal,
        .token_txn_request_epoch = token_txn_request_epoch,
        .greedy_head_mode = options.greedy_head_mode,
        .attention_mode = options.attention_mode,
        .pair_down_mode = options.pair_down_mode,
    };
    defer if (worker.result) |*result| {
        result.deinit();
        worker.result = null;
    };

    const run_start_ns = try options.clock.now();
    var thread = std.Thread.spawn(.{}, B4Worker.run, .{&worker}) catch {
        try expectBankReleased(&bank);
        return Error.ThreadSpawnFailed;
    };
    var root_started = true;
    defer if (root_started) thread.join();
    thread.join();
    root_started = false;
    const roots_joined_ns = try options.clock.now();
    if (roots_joined_ns < run_start_ns) return Error.TimestampRegression;
    if (worker.failure) |failure| {
        try expectBankReleased(&bank);
        return failure;
    }
    try expectBankReleased(&bank);

    // The released snapshot and token hashes are post-run evidence work.
    const post_commit = try capture.seal();
    const journal_receipt = try journal.seal();
    var token_txn_waves: runner_core.B4TokenTxnWaveMatrix = undefined;
    try journal.copySealedEvents(&token_txn_waves);
    const timing = try deriveB4TokenTxnTiming(
        run_start_ns,
        roots_joined_ns,
        &token_txn_waves,
        journal_receipt,
    );
    if (post_commit.committed_ns < timing.run.start_ns or
        post_commit.committed_ns > timing.run.end_ns or
        post_commit.released_snapshot_ns < timing.run.end_ns)
        return Error.TimestampRegression;
    if (!std.meta.eql(
        post_commit.receipt,
        journal_receipt.resource_receipt,
    )) return Error.EvidenceMismatch;

    const result = worker.result orelse return Error.WorkerFailed;
    worker.result = null;
    var outputs: OwnedLaneTokens = .{
        .allocator = allocator,
        .storage = result.storage,
    };
    errdefer outputs.deinit();
    for (result.lengths) |length| if (length != tokens_per_lane)
        return Error.EvidenceMismatch;
    const generation_states = worker.telemetry.lane_states;
    try validateB4TokenTxnPublishedTokens(outputs.storage, &token_txn_waves);
    try validateGenerationStates(model, bindings, outputs.storage, generation_states);
    try validateB4Execution(
        model,
        bindings[0].prompt.len,
        token_txn_request_epoch,
        options.greedy_head_mode,
        options.attention_mode,
        options.pair_down_mode,
        worker.telemetry,
    );
    try validateB4Resources(claim, worker.resources, post_commit);

    return .{
        .workload_binding = workload_binding,
        .journal_root_binding = journal_root,
        .timing = timing,
        .outputs = outputs,
        .generation_states = generation_states,
        .execution = worker.telemetry,
        .resources = worker.resources,
        .token_txn_journal = journal_receipt,
        .token_txn_waves = token_txn_waves,
        .post_commit = post_commit,
    };
}

/// Revalidate a retained M1x4 observation against its immutable model,
/// workload, and caller-owned observation binding. This deliberately derives
/// claims and all expected graph counters again so mutation of the public
/// observation fields cannot bypass the campaign's final retention gate.
pub fn verifyM1x4Observation(
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
    observation_binding: [32]u8,
    expected_bank_epoch: u64,
    expected_barrier_epoch: u64,
    retained: *const M1x4Observation,
) Error!void {
    try validateModelTokens(model, bindings);
    const workload_binding = try deriveWorkloadBinding(model, bindings);
    const journal_root = try deriveJournalRootBinding(
        .m1x4,
        observation_binding,
        workload_binding,
    );
    if (expected_bank_epoch == 0 or expected_barrier_epoch == 0 or
        retained.barrier.barrier_epoch != expected_barrier_epoch or
        retained.barrier.before_snapshot.bank_epoch != expected_bank_epoch or
        !std.mem.eql(u8, &retained.workload_binding, &workload_binding) or
        !std.mem.eql(u8, &retained.journal_root_binding, &journal_root) or
        !std.mem.eql(
            u8,
            &retained.journal_root_binding,
            &retained.token_journal.root_binding,
        ))
        return Error.EvidenceMismatch;

    try runner_core.verifyM1BarrierReceipt(retained.barrier);
    try runner_core.verifyTokenJournal(
        &retained.token_events,
        retained.token_journal,
    );
    const timing = try deriveObservationTiming(
        retained.timing.run.start_ns,
        retained.timing.run.end_ns,
        &retained.token_events,
        retained.token_journal,
    );
    if (!std.meta.eql(timing, retained.timing)) return Error.EvidenceMismatch;
    try validatePublishedTokens(retained.outputs.storage, &retained.token_events);
    try validateGenerationStates(
        model,
        bindings,
        retained.outputs.storage,
        retained.generation_states,
    );
    try validateM1Execution(model, bindings, retained.execution);

    var claims: [width]resource_bank.Claim = undefined;
    var aggregate: resource_bank.Claim = .{};
    for (&claims, bindings) |*claim, binding| {
        claim.* = try generate_api.deriveResourceClaim(
            model,
            binding.prompt,
            m1GenerateOptions(binding),
        );
        aggregate = try addClaims(aggregate, claim.*);
    }
    try validateM1Resources(
        aggregate,
        claims,
        retained.resources,
        retained.barrier,
    );
    for (retained.barrier.intervals, 0..) |interval, lane| {
        if (interval.ready_ns < timing.run.start_ns or
            interval.start_ns < timing.run.start_ns or
            interval.end_ns > timing.run.end_ns)
            return Error.TimestampRegression;
        for (retained.token_events[lane][0..tokens_per_lane]) |event| {
            if (event.monotonic_ns < interval.start_ns or
                event.monotonic_ns > interval.end_ns)
                return Error.TimestampRegression;
        }
    }
}

/// Revalidate a retained B4 observation against the same external identity
/// inputs used at execution time.
pub fn verifyB4Observation(
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
    observation_binding: [32]u8,
    expected_bank_epoch: u64,
    expected_greedy_head_mode: decode_lane4.GreedyHeadMode,
    expected_attention_mode: decode_lane4.AttentionMode,
    expected_pair_down_mode: decode_lane4.PairDownMode,
    retained: *const B4Observation,
) Error!void {
    try validateModelTokens(model, bindings);
    const workload_binding = try deriveWorkloadBinding(model, bindings);
    const journal_root = try deriveJournalRootBinding(
        .b4,
        observation_binding,
        workload_binding,
    );
    const token_txn_request_epoch = try deriveB4TokenTxnRequestEpoch(
        expected_bank_epoch,
    );
    if (expected_bank_epoch == 0 or
        retained.post_commit.before_snapshot.bank_epoch != expected_bank_epoch or
        retained.token_txn_journal.request_epoch != token_txn_request_epoch or
        !std.mem.eql(u8, &retained.workload_binding, &workload_binding) or
        !std.mem.eql(u8, &retained.journal_root_binding, &journal_root) or
        !std.mem.eql(
            u8,
            &retained.journal_root_binding,
            &retained.token_txn_journal.root_binding,
        ))
        return Error.EvidenceMismatch;

    try verifyB4PostCommitReceipt(retained.post_commit);
    try runner_core.verifyB4TokenTxnJournal(
        &retained.token_txn_waves,
        retained.token_txn_journal,
    );
    const timing = try deriveB4TokenTxnTiming(
        retained.timing.run.start_ns,
        retained.timing.run.end_ns,
        &retained.token_txn_waves,
        retained.token_txn_journal,
    );
    if (!std.meta.eql(timing, retained.timing) or
        retained.post_commit.committed_ns < timing.run.start_ns or
        retained.post_commit.committed_ns > timing.run.end_ns or
        retained.post_commit.released_snapshot_ns < timing.run.end_ns or
        !std.meta.eql(
            retained.post_commit.receipt,
            retained.token_txn_journal.resource_receipt,
        ))
        return Error.EvidenceMismatch;
    try validateB4TokenTxnPublishedTokens(
        retained.outputs.storage,
        &retained.token_txn_waves,
    );
    try validateGenerationStates(
        model,
        bindings,
        retained.outputs.storage,
        retained.generation_states,
    );
    try validateB4Execution(
        model,
        bindings[0].prompt.len,
        token_txn_request_epoch,
        expected_greedy_head_mode,
        expected_attention_mode,
        expected_pair_down_mode,
        retained.execution,
    );
    const requests = b4Requests(bindings);
    const claim = try decode_lane4.deriveResourceClaim(
        model,
        requests,
        .{
            .num_threads = width,
            .greedy_head_mode = expected_greedy_head_mode,
            .attention_mode = expected_attention_mode,
            .pair_down_mode = expected_pair_down_mode,
        },
    );
    try validateB4Resources(claim, retained.resources, retained.post_commit);
}

/// Revalidate both arms, then require exact semantic equality. Every token and
/// every GenerationStateTelemetry field is compared, including KV/output
/// SHA-256, full Xoshiro state, and completion counters. Campaign code must
/// call this before retaining a paired observation.
pub fn verifyCrossArmEquivalence(
    model: engine.loader.LoadedModel,
    bindings: [width]RequestBinding,
    observation_binding: [32]u8,
    m1_bank_epoch: u64,
    m1_barrier_epoch: u64,
    b4_bank_epoch: u64,
    expected_b4_greedy_head_mode: decode_lane4.GreedyHeadMode,
    expected_b4_attention_mode: decode_lane4.AttentionMode,
    expected_b4_pair_down_mode: decode_lane4.PairDownMode,
    m1: *const M1x4Observation,
    b4: *const B4Observation,
) Error!void {
    try verifyM1x4Observation(
        model,
        bindings,
        observation_binding,
        m1_bank_epoch,
        m1_barrier_epoch,
        m1,
    );
    try verifyB4Observation(
        model,
        bindings,
        observation_binding,
        b4_bank_epoch,
        expected_b4_greedy_head_mode,
        expected_b4_attention_mode,
        expected_b4_pair_down_mode,
        b4,
    );
    if (isZeroDigest(m1.workload_binding) or
        !std.mem.eql(u8, &m1.workload_binding, &b4.workload_binding))
        return Error.EvidenceMismatch;

    for (0..width) |lane| {
        if (!std.mem.eql(u32, m1.outputs.tokens(lane), b4.outputs.tokens(lane)) or
            !std.meta.eql(m1.generation_states[lane], b4.generation_states[lane]) or
            isZeroDigest(m1.generation_states[lane].kv_sha256) or
            isZeroDigest(m1.generation_states[lane].output_sha256))
            return Error.EvidenceMismatch;
    }
}

test "workload requires equal nonempty and distinct prompt-seed bindings" {
    const prompts = [width][2]u32{
        .{ 1, 2 },
        .{ 3, 4 },
        .{ 5, 6 },
        .{ 7, 8 },
    };
    const valid = [width]RequestBinding{
        .{ .prompt = &prompts[0], .seed = 1 },
        .{ .prompt = &prompts[1], .seed = 2 },
        .{ .prompt = &prompts[2], .seed = 3 },
        .{ .prompt = &prompts[3], .seed = 4 },
    };
    try validateWorkload(valid);

    var duplicate = valid;
    duplicate[3] = duplicate[0];
    try std.testing.expectError(Error.InvalidWorkload, validateWorkload(duplicate));

    var empty = valid;
    empty[0].prompt = &.{};
    try std.testing.expectError(Error.InvalidWorkload, validateWorkload(empty));

    var uneven = valid;
    uneven[3].prompt = prompts[3][0..1];
    try std.testing.expectError(Error.InvalidWorkload, validateWorkload(uneven));
}

test "claim aggregation preserves every resource dimension" {
    const left: resource_bank.Claim = .{
        .capsule_bytes = 1,
        .kv_bytes = 2,
        .activation_bytes = 3,
        .partial_bytes = 4,
        .logits_bytes = 5,
        .output_journal_bytes = 6,
        .staging_bytes = 7,
        .device_bytes = 8,
        .io_bytes = 9,
        .queue_slots = 1,
    };
    const sum = try addClaims(left, left);
    inline for (std.meta.fields(resource_bank.Claim)) |field| {
        try std.testing.expectEqual(
            @field(left, field.name) * 2,
            @field(sum, field.name),
        );
    }
}

test "B4 TokenTxn telemetry rejects provisional abort mutation" {
    const request_epoch: u64 = 0x4234_5458_4e54_0001;
    var telemetry: decode_lane4.Telemetry = .{
        .publication_mode = .token_txn_required,
        .token_txn_request_epoch = request_epoch,
        .token_txn_commits = tokens_per_lane,
        .token_txn_lane_commits = width * tokens_per_lane,
        .token_txn_first_token_commits = 1,
        .token_txn_kv_row_commits = width * (tokens_per_lane - 1),
        .token_txn_last_sequence = tokens_per_lane - 1,
    };
    try validateB4TokenTxnTelemetry(request_epoch, telemetry);
    telemetry.token_txn_provisional_aborts = 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4TokenTxnTelemetry(request_epoch, telemetry),
    );
}

test "B4 greedy head ledger rejects mode and counter mutation" {
    var materialized: decode_lane4.Telemetry = .{
        .greedy_head_mode = .materialized,
        .lm_head_m4_dispatches = tokens_per_lane,
        .materialized_lm_head_m4_dispatches = tokens_per_lane,
    };
    try validateB4GreedyHeadExecution(257, .materialized, materialized);
    materialized.greedy_head_abi_version +%= 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4GreedyHeadExecution(257, .materialized, materialized),
    );

    const task_count = @min(width, 256 / 4);
    var streaming: decode_lane4.Telemetry = .{
        .greedy_head_mode = .streaming_required,
        .lm_head_m4_dispatches = tokens_per_lane,
        .streaming_greedy_head_m4_dispatches = tokens_per_lane,
        .streaming_greedy_head_tasks = tokens_per_lane * task_count,
        .streaming_greedy_head_shards = tokens_per_lane * task_count,
        .streaming_greedy_head_lane_candidates = tokens_per_lane * task_count * width,
        .materialized_logits_reclaimed_bytes = width * 257 * @sizeOf(f32) + 2 * @sizeOf(usize),
    };
    // The production rows4 head requires a vocabulary divisible by four.
    streaming.materialized_logits_reclaimed_bytes = width * 256 * @sizeOf(f32) + 2 * @sizeOf(usize);
    try validateB4GreedyHeadExecution(256, .streaming_required, streaming);
    streaming.streaming_greedy_head_tasks -= 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4GreedyHeadExecution(256, .streaming_required, streaming),
    );
    streaming.streaming_greedy_head_tasks += 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4GreedyHeadExecution(256, .materialized, streaming),
    );
}

test "B4 projection shared-KV and PairDown schedule ledger rejects mutation" {
    var telemetry: decode_lane4.Telemetry = .{
        .attention_mode = .shared_kv_required,
        .qkv_projection_dispatches = 9,
        .qkv_projection_waves = 3,
        .qkv_projection_joins_elided = 6,
        .shared_kv_attention_lane_dispatches = 12,
        .shared_kv_attention_tiles = 48,
        .pair_down_split_worker_epochs = 2,
    };
    try validateB4ScheduleTelemetry(
        .shared_kv_required,
        .split_control,
        9,
        3,
        6,
        12,
        48,
        0,
        2,
        0,
        0,
        0,
        telemetry,
    );

    telemetry.projection_wave_abi_version +%= 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4ScheduleTelemetry(
            .shared_kv_required,
            .split_control,
            9,
            3,
            6,
            12,
            48,
            0,
            2,
            0,
            0,
            0,
            telemetry,
        ),
    );
    telemetry.projection_wave_abi_version = decode_lane4.projection_wave_abi;
    telemetry.shared_kv_attention_abi_version +%= 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4ScheduleTelemetry(
            .shared_kv_required,
            .split_control,
            9,
            3,
            6,
            12,
            48,
            0,
            2,
            0,
            0,
            0,
            telemetry,
        ),
    );
    telemetry.shared_kv_attention_abi_version =
        decode_lane4.shared_kv_attention_abi;
    telemetry.attention_mode = .serial;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4ScheduleTelemetry(
            .shared_kv_required,
            .split_control,
            9,
            3,
            6,
            12,
            48,
            0,
            2,
            0,
            0,
            0,
            telemetry,
        ),
    );
    telemetry.attention_mode = .shared_kv_required;
    telemetry.qkv_projection_waves -= 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4ScheduleTelemetry(
            .shared_kv_required,
            .split_control,
            9,
            3,
            6,
            12,
            48,
            0,
            2,
            0,
            0,
            0,
            telemetry,
        ),
    );
    telemetry.qkv_projection_waves += 1;
    telemetry.shared_kv_attention_tiles -= 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4ScheduleTelemetry(
            .shared_kv_required,
            .split_control,
            9,
            3,
            6,
            12,
            48,
            0,
            2,
            0,
            0,
            0,
            telemetry,
        ),
    );
    telemetry.shared_kv_attention_tiles += 1;
    telemetry.pair_down_wave_abi_version +%= 1;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4ScheduleTelemetry(
            .shared_kv_required,
            .split_control,
            9,
            3,
            6,
            12,
            48,
            0,
            2,
            0,
            0,
            0,
            telemetry,
        ),
    );
    telemetry.pair_down_wave_abi_version = decode_lane4.pair_down_wave_abi;
    telemetry.pair_down_mode = .single_epoch_required;
    try std.testing.expectError(
        Error.EvidenceMismatch,
        validateB4ScheduleTelemetry(
            .shared_kv_required,
            .split_control,
            9,
            3,
            6,
            12,
            48,
            0,
            2,
            0,
            0,
            0,
            telemetry,
        ),
    );
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

    fn clock(self: *TestClock) runner_core.MonotonicClock {
        return .{ .context = self, .read_ns = read };
    }

    fn read(raw_context: ?*anyopaque) runner_core.ClockError!u64 {
        const self: *TestClock = @ptrCast(@alignCast(raw_context orelse
            return runner_core.ClockError.Unavailable));
        return self.next.fetchAdd(self.step, .monotonic);
    }
};

test "primary publish timing includes prefill and keeps TTFT separate" {
    var test_clock = TestClock.init(1_000, 10);
    var journal = try runner_core.TokenEventJournal.init(
        test_clock.clock(),
        tokens_per_lane,
        [_]u8{0x4a} ** 32,
    );
    const run_start_ns = try test_clock.clock().now();
    for (0..width) |lane| {
        const observer = journal.observer(@intCast(lane));
        for (0..tokens_per_lane) |step| {
            try generate_api.runTokenPublicationObserver(
                observer,
                step,
                @intCast(lane * tokens_per_lane + step),
                step + 1 == tokens_per_lane,
            );
        }
    }
    const roots_joined_ns = try test_clock.clock().now();
    const receipt = try journal.seal();
    var events: runner_core.TokenEventMatrix = undefined;
    try journal.copySealedEvents(&events);
    const timing = try deriveObservationTiming(
        run_start_ns,
        roots_joined_ns,
        &events,
        receipt,
    );
    try std.testing.expectEqual(run_start_ns, timing.primary_publish.start_ns);
    try std.testing.expectEqual(run_start_ns, timing.time_to_first_publish.start_ns);
    try std.testing.expectEqual(
        timing.time_to_first_publish.end_ns,
        timing.run.start_ns + 10,
    );
    try std.testing.expectEqual(
        timing.primary_publish.end_ns,
        timing.postlude_join.start_ns,
    );
    try std.testing.expectEqual(roots_joined_ns, timing.postlude_join.end_ns);
}

test "B4 post-commit capture proves exact one-slot lifecycle" {
    const claim: resource_bank.Claim = .{
        .kv_bytes = 128,
        .activation_bytes = 64,
        .output_journal_bytes = tokens_per_lane * width * @sizeOf(u32),
        .queue_slots = width,
    };
    var slots = [_]resource_bank.Slot{.{}} ** 1;
    var bank = try resource_bank.Bank.init(
        &slots,
        try runner_core.exactLimitsForClaim(claim),
        0x4234_4341_5054_0001,
    );
    var test_clock = TestClock.init(2_000, 10);
    var capture = try B4PostCommitCapture.init(&bank, test_clock.clock());
    const reservation = try bank.reserve(0x1234, claim);
    const committed = try bank.commit(reservation);
    try generate_api.runResourceCommitObserver(capture.observer(), committed);
    try bank.release(committed);
    const receipt = try capture.seal();
    try verifyB4PostCommitReceipt(receipt);
    try std.testing.expectEqual(@as(u64, 1), receipt.released_snapshot.releases);
    try std.testing.expect(receipt.released_snapshot.used.isZero());
    try std.testing.expectError(B4CaptureError.AlreadySealed, capture.seal());
}

test "public observation entrypoints typecheck" {
    std.testing.refAllDecls(@This());
}
